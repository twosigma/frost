/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * parcel_fill_engine -- the stage-2 front end's serve-side instruction walk
 * (PARCEL_QUEUE_DESIGN.md sections 2.1 / 2.1.1 / 2.1.2 / 2.6).  Landing steps
 * B1/B2/B3a: the 2-wide, self-aligned relocation of today's ask-side machinery,
 * with a 32-bit slot-1 allowed to lead an in-window bundle (B3a).  Enqueues up
 * to two pq_entry_t per served window (slot-1 + a contiguous slot-2) into the
 * parcel_queue; the misaligned 32+32 straddle carry (B3b) is deferred to the
 * integration phase.
 *
 * ASK CHAIN (derived from RTL, design 2.1.1):
 *   - `ask_q` is the leading ask presented last cycle (today's `o_pc` role);
 *     `o_ask_pc` / `o_lookup_pc` present this cycle's ask combinationally.
 *   - The provider serves the ask presented last cycle one cycle later, tagged
 *     with `i_win_served_addr` (today's `o_pc_reg` role, but supplied by the
 *     provider so the frame is SELF-ALIGNED: the served window's low word is
 *     word(served_addr) by construction -- no bank_sel/pc_reg[2] parity, and
 *     the F-vs-W disambiguation ceases to exist).
 *   - SEQUENTIAL advance uses the served bundle's size, decoded from the
 *     arriving window's sideband (SERVE time).
 *   - A predicted-TAKEN slot-1 branch is the only ask-time redirect: the BTB
 *     result looked up at `ask_q` (ask time) rides `bind_q` one cycle and, when
 *     that branch is served, redirects the next ask to the target (zero bubble).
 *
 * SLOT-2 (design 2.1.2 / 2.6): a contiguous slot-2 at `served_addr +
 * size(slot-1)` is decoded from the same window (positions CURRENT_HI /
 * NEXT_LO / NEXT_HI by byte offset 2/4/6) and enqueued as `e1` iff
 * `e0.allows_slot2_after && e1.slot2_start_ok && !e0.predicted_taken`.  B3a
 * lets a 32-bit slot-1 lead a bundle (gate `s1_can_lead`); a NEXT_HI 32-bit
 * slot-2 straddles a third word and is suppressed (the straddle carry, B3b, is
 * deferred to integration).  Its BTB/DIR lookup is WALK-time (at `served_addr +
 * size(slot-1)`, combinational this cycle) and binds e1 the same cycle.  A
 * taken slot-2 is a REGISTERED redirect (kept
 * off the ask path): the sequential `served_addr + bundle` ask still goes out
 * this cycle, e0+e1 enqueue, and a one-shot `slot2_redir_pending` fires next
 * cycle -- ask <- slot-2 target, `o_core_redirect` pulse, NO flush, the
 * in-flight wrong-path window rejected (one-cycle bubble, absorbed by the
 * queue; reproduces HEAD's o_slot2_redirect_q NOP).
 *
 * BINDING (pc-tagged, design 2.1.1): `bind_q` carries the ask-time slot-1
 * lookup {pc, btb/dir result} forward one cycle.  At enqueue e0 binds that
 * result IFF `bind_q.pc == e0.pc`; else zeroed not-taken metadata.
 *
 * WINDOW ACCEPTANCE (tag-checked, design 7.1): a window is enqueued only when
 * valid, its served word matches the outstanding ask, no redirect (external or
 * slot-2) is landing this cycle, and the queue is not backpressuring.
 *
 * REDIRECT (design 2.5): `i_redirect_valid` resteers the ask, pulses
 * `o_core_redirect`, and flushes the queue -- full (backend / trap / MRET /
 * FENCE.I / PD) or partial (`i_redirect_partial`, the RAS dequeue-fire).  It
 * dominates the same-cycle enqueue and the slot-2 redirect.
 */
module parcel_fill_engine #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,

    // ---- Core redirect in (backend branch / trap / MRET / FENCE.I / PD /
    //      RAS consume).  One consolidated resteer port; the §2.5 priority
    //      resolution happens upstream in the core.  i_redirect_partial marks
    //      the RAS dequeue-fire (queue keeps its head return entry); every
    //      other redirect is a full flush. ----
    input logic            i_redirect_valid,
    input logic [XLEN-1:1] i_redirect_target,
    input logic            i_redirect_partial,

    // ---- Provider window in (serve side; §7.1 stage-2 seam) ----
    input logic i_win_valid,  // o_instr_valid
    input logic [XLEN-1:0] i_win_served_addr,  // o_served_addr
    input logic [63:0] i_win_instr,  // {word(sa)+1, word(sa)}
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_win_sideband,

    // ---- Slot-1 BTB / DIR lookup (ask-time, at the leading ask address) ----
    output logic [                   XLEN-1:1] o_lookup_pc,
    input  logic                               i_btb_hit,
    input  logic                               i_btb_taken,
    input  logic [                   XLEN-1:1] i_btb_target,
    input  logic                               i_dir_taken,
    input  logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_idx,

    // ---- Slot-2 BTB / DIR lookup (walk-time, at served_addr + 2) ----
    output logic [                   XLEN-1:1] o_lookup_pc_2,
    input  logic                               i_btb_hit_2,
    input  logic                               i_btb_taken_2,
    input  logic [                   XLEN-1:1] i_btb_target_2,
    input  logic                               i_dir_taken_2,
    input  logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_idx_2,

    // ---- Provider ask out (fetch side) ----
    output logic [XLEN-1:1] o_ask_pc,
    output logic            o_core_redirect, // resteer pulse to the provider seam

    // ---- Queue enqueue out ----
    output logic                 [1:0] o_enq_valid,     // [1] implies [0]
    output riscv_pkg::pq_entry_t       o_enq_entry0,
    output riscv_pkg::pq_entry_t       o_enq_entry1,
    output logic                       o_flush_full,
    output logic                       o_flush_partial,

    // ---- Queue backpressure in ----
    input logic i_queue_backpressure
);

  localparam int unsigned SbWidth = riscv_pkg::ImemSidebandWidth;

  // ===========================================================================
  // Ask register + slot-1 binding pipe
  // ===========================================================================
  // ask_q  : the ask presented last cycle == the served word expected now.
  // bind_q : the slot-1 lookup done last cycle at ask_q, held for pc-tagged
  //          binding when that address is served this cycle.
  logic [                   XLEN-1:0] ask_q;
  logic                               bind_valid_q;
  logic [                   XLEN-1:1] bind_pc_q;
  logic                               bind_btb_hit_q;
  logic                               bind_btb_taken_q;
  logic [                   XLEN-1:1] bind_btb_target_q;
  logic                               bind_dir_taken_q;
  logic [riscv_pkg::BpDirIdxBits-1:0] bind_dir_idx_q;

  // Registered slot-2-taken redirect (one-shot; kept off the ask path).
  logic                               slot2_redir_pending_q;
  logic [                   XLEN-1:1] slot2_redir_target_q;

  // ===========================================================================
  // Window words + sidebands (self-aligned: low word is word(ask_q)).
  // ===========================================================================
  logic [                   XLEN-1:0] served_addr;
  logic                               served_hw;  // halfword within the low word (bit 1)
  assign served_addr = ask_q;
  assign served_hw   = ask_q[1];

  logic [31:0] low_word, high_word;
  assign low_word  = i_win_instr[31:0];
  assign high_word = i_win_instr[63:32];

  logic [SbWidth-1:0] sb_lo, sb_hi;
  assign sb_lo = i_win_sideband[SbWidth-1:0];
  assign sb_hi = i_win_sideband[2*SbWidth-1:SbWidth];

  // served_addr / s2_pc bit 0 are always 0 (2-byte alignment); sink them so
  // lint stays clean (every other bit is consumed by slot-1/slot-2 decode).
  wire  _unused = &{1'b0, i_win_served_addr[0], s2_pc[0]};

  // ===========================================================================
  // Slot-1 decode (the served instruction at ask_q)
  // ===========================================================================
  logic s1_is_compressed;
  logic s1_allows_after_sb;  // sideband AllowsSlot2After (compressed slot-1 only)
  logic s1_slot2_start_ok;  // sideband Slot2StartValid
  logic s1_can_lead;  // B3 §2.6: this entry may lead a 2-wide bundle
  assign s1_is_compressed = served_hw ? sb_lo[riscv_pkg::ImemSbIsCompressedHi]
                                      : sb_lo[riscv_pkg::ImemSbIsCompressedLo];
  assign s1_allows_after_sb = served_hw ? sb_lo[riscv_pkg::ImemSbAllowsSlot2AfterHi]
                                        : sb_lo[riscv_pkg::ImemSbAllowsSlot2AfterLo];
  assign s1_slot2_start_ok = served_hw ? sb_lo[riscv_pkg::ImemSbSlot2StartValidHi]
                                       : sb_lo[riscv_pkg::ImemSbSlot2StartValidLo];

  logic [15:0] s1_parcel;
  logic [31:0] s1_bytes;
  assign s1_parcel = served_hw ? low_word[31:16] : low_word[15:0];
  always_comb begin
    if (s1_is_compressed) s1_bytes = {16'h0000, s1_parcel};
    else if (!served_hw) s1_bytes = low_word;
    else s1_bytes = {high_word[15:0], low_word[31:16]};  // spanning at halfword
  end

  // A 32-bit branch/JAL/JALR in slot-1 terminates the bundle.  Dispatch rejects
  // a slot-2 whenever slot-1 is is_branch_or_jump (decision #1); the fill must
  // match, or the unfireable branch+slot-2 bundle wedges dispatch forever (it
  // stalls waiting for a re-present that never resolves).  The predecode
  // sideband only flags COMPRESSED control flow (folded into AllowsSlot2After) --
  // native control flow has no sideband bit, so decode the opcode here.
  logic s1_is_native_control;
  assign s1_is_native_control =
      !s1_is_compressed && ((s1_bytes[6:0] == riscv_pkg::OPC_BRANCH) ||
                            (s1_bytes[6:0] == riscv_pkg::OPC_JAL) ||
                            (s1_bytes[6:0] == riscv_pkg::OPC_JALR));

  // A compressed slot-1 leads iff not a compressed control op (AllowsSlot2After);
  // a 32-bit slot-1 leads iff not serialize/FP (Slot2StartValid) and not a
  // native branch/jump.
  assign s1_can_lead = (s1_is_compressed ? s1_allows_after_sb : s1_slot2_start_ok) &&
                       !s1_is_native_control;

  logic [XLEN-1:0] s1_size;
  assign s1_size = s1_is_compressed ? riscv_pkg::PcIncrementCompressed
                                    : riscv_pkg::PcIncrement32bit;

  // ===========================================================================
  // Slot-2 decode (contiguous instruction at served_addr + size(slot-1))
  // ===========================================================================
  // The slot-2 byte offset in the window = served offset (0/2) + slot-1 size,
  // giving three positions (design §2.6): CURRENT_HI (2), NEXT_LO (4),
  // NEXT_HI (6).  A NEXT_HI 32-bit slot-2 straddles into word W+2 and is
  // suppressed (B3a); the straddle carry (B3b) is deferred to integration.
  logic [XLEN-1:0] s2_pc;
  assign s2_pc = served_addr + s1_size;

  logic [2:0] served_off, s2_off;
  assign served_off = served_hw ? 3'd2 : 3'd0;
  assign s2_off = served_off + (s1_is_compressed ? 3'd2 : 3'd4);  // 2, 4, or 6

  localparam logic [1:0] Slot2CurHi = 2'd0, Slot2NextLo = 2'd1, Slot2NextHi = 2'd2;
  logic [1:0] s2_pos;
  always_comb begin
    unique case (s2_off)
      3'd2:    s2_pos = Slot2CurHi;
      3'd4:    s2_pos = Slot2NextLo;
      default: s2_pos = Slot2NextHi;  // 3'd6
    endcase
  end

  logic        s2_is_compressed;
  logic        s2_allows_after_sb;
  logic        s2_start_ok;
  logic [15:0] s2_parcel;
  always_comb begin
    unique case (s2_pos)
      Slot2CurHi: begin
        s2_is_compressed   = sb_lo[riscv_pkg::ImemSbIsCompressedHi];
        s2_allows_after_sb = sb_lo[riscv_pkg::ImemSbAllowsSlot2AfterHi];
        s2_start_ok        = sb_lo[riscv_pkg::ImemSbSlot2StartValidHi];
        s2_parcel          = low_word[31:16];
      end
      Slot2NextLo: begin
        s2_is_compressed   = sb_hi[riscv_pkg::ImemSbIsCompressedLo];
        s2_allows_after_sb = sb_hi[riscv_pkg::ImemSbAllowsSlot2AfterLo];
        s2_start_ok        = sb_hi[riscv_pkg::ImemSbSlot2StartValidLo];
        s2_parcel          = high_word[15:0];
      end
      default: begin  // Slot2NextHi
        s2_is_compressed   = sb_hi[riscv_pkg::ImemSbIsCompressedHi];
        s2_allows_after_sb = sb_hi[riscv_pkg::ImemSbAllowsSlot2AfterHi];
        s2_start_ok        = sb_hi[riscv_pkg::ImemSbSlot2StartValidHi];
        s2_parcel          = high_word[31:16];
      end
    endcase
  end

  // NEXT_HI 32-bit slot-2 reaches a third word -> suppress pairing (B3a).
  logic s2_straddle;
  assign s2_straddle = (s2_pos == Slot2NextHi) && !s2_is_compressed;

  logic [31:0] s2_bytes;
  always_comb begin
    if (s2_is_compressed) begin
      s2_bytes = {16'h0000, s2_parcel};
    end else begin
      unique case (s2_pos)
        Slot2CurHi:  s2_bytes = {high_word[15:0], low_word[31:16]};  // span lo->hi
        Slot2NextLo: s2_bytes = high_word;
        default:     s2_bytes = 32'h0000_0000;  // NEXT_HI 32b straddles (suppressed)
      endcase
    end
  end

  logic [XLEN-1:0] s2_size;
  assign s2_size = s2_is_compressed ? riscv_pkg::PcIncrementCompressed
                                    : riscv_pkg::PcIncrement32bit;

  // Whether this slot-2 entry may itself LEAD a bundle once it later becomes a
  // queue head (carried as e1.allows_slot2_after).  Same rule as s1_can_lead: a
  // 32-bit branch/JAL/JALR must NOT lead (dispatch rejects a slot-2 after any
  // is_branch_or_jump).  The sideband only flags compressed control flow, so
  // decode the native opcode here too -- omitting this lets a branch enqueued in
  // slot-2 wrongly advertise allows_slot2_after and wedge dispatch when the
  // consume pairs a younger entry behind it.
  logic s2_is_native_control;
  assign s2_is_native_control =
      !s2_is_compressed && ((s2_bytes[6:0] == riscv_pkg::OPC_BRANCH) ||
                            (s2_bytes[6:0] == riscv_pkg::OPC_JAL) ||
                            (s2_bytes[6:0] == riscv_pkg::OPC_JALR));
  logic s2_can_lead;
  assign s2_can_lead = (s2_is_compressed ? s2_allows_after_sb : s2_start_ok) &&
                       !s2_is_native_control;

  // ===========================================================================
  // Window acceptance (tag-checked) + slot-1 pc-tagged binding
  // ===========================================================================
  logic slot2_redir_fire;
  assign slot2_redir_fire = slot2_redir_pending_q;

  logic served_tag_ok;
  logic accept;
  // Only a FULL redirect (flush) gates acceptance.  A PARTIAL (RAS-return)
  // redirect must NOT gate the enqueue: o_ras_redirect_valid is computed on the
  // consume side from dequeue-fire, which -- on an FWFT return into an empty
  // queue -- rides this cycle's incoming enqueue.  Gating accept on it closes a
  // combinational loop (accept -> o_enq_valid -> queue FWFT head -> consume
  // dequeue_fire -> ras redirect -> accept) that oscillates and fails Verilator
  // convergence.  The queue's partial flush already discards any same-cycle
  // wrong-path enqueue (flush dominates the write), so the gate is redundant.
  logic full_redirect;
  assign full_redirect = i_redirect_valid && !i_redirect_partial;
  assign served_tag_ok = (i_win_served_addr[XLEN-1:1] == ask_q[XLEN-1:1]);
  assign accept = i_win_valid && served_tag_ok && !full_redirect &&
                  !i_queue_backpressure && !slot2_redir_fire;

  logic bind_match;
  assign bind_match = bind_valid_q && (bind_pc_q == ask_q[XLEN-1:1]);

  // Slot-1 taken branch: ask-time (registered) redirect, zero bubble.
  logic slot1_taken;
  assign slot1_taken = accept && bind_match && bind_btb_taken_q;

  // ===========================================================================
  // Bundle formation (design 2.1.2)
  // ===========================================================================
  logic slot2_present;
  assign slot2_present = accept && s1_can_lead && s2_start_ok && !slot1_taken && !s2_straddle;

  // Slot-2 taken branch: walk-time result -> registered redirect next cycle.
  logic slot2_taken;
  assign slot2_taken = slot2_present && i_btb_taken_2;

  // ===========================================================================
  // Enqueue entries
  // ===========================================================================
  riscv_pkg::pq_entry_t e0, e1;
  always_comb begin
    e0                    = '0;
    e0.pc                 = served_addr[XLEN-1:1];
    e0.instr_bytes        = riscv_pkg::instr_t'(s1_bytes);
    e0.is_compressed      = s1_is_compressed;
    e0.allows_slot2_after = s1_can_lead;
    e0.slot2_start_ok     = s1_slot2_start_ok;
    e0.btb_hit            = bind_match ? bind_btb_hit_q : 1'b0;
    e0.predicted_taken    = bind_match ? bind_btb_taken_q : 1'b0;
    e0.predicted_target   = bind_match ? bind_btb_target_q : '0;
    e0.dir_taken          = bind_match ? bind_dir_taken_q : 1'b0;
    e0.dir_idx            = bind_match ? bind_dir_idx_q : '0;
  end

  // Slot-2 binding is walk-time (this cycle's lookup at s2_pc), bound directly.
  always_comb begin
    e1                    = '0;
    e1.pc                 = s2_pc[XLEN-1:1];
    e1.instr_bytes        = riscv_pkg::instr_t'(s2_bytes);
    e1.is_compressed      = s2_is_compressed;
    e1.allows_slot2_after = s2_can_lead;
    e1.slot2_start_ok     = s2_start_ok;
    e1.btb_hit            = i_btb_hit_2;
    e1.predicted_taken    = i_btb_taken_2;
    e1.predicted_target   = i_btb_target_2;
    e1.dir_taken          = i_dir_taken_2;
    e1.dir_idx            = i_dir_idx_2;
  end

  assign o_enq_valid  = {slot2_present, accept};  // slot2_present implies accept
  assign o_enq_entry0 = e0;
  assign o_enq_entry1 = e1;

  // ===========================================================================
  // Next ask (design 2.5 priority): external redirect > slot-2 fire >
  // slot-1 taken > accept (bundle / single sequential) > hold.
  // ===========================================================================
  logic [XLEN-1:0] ask_d;
  always_comb begin
    if (i_redirect_valid) ask_d = {i_redirect_target, 1'b0};
    else if (slot2_redir_fire) ask_d = {slot2_redir_target_q, 1'b0};
    else if (slot1_taken) ask_d = {bind_btb_target_q, 1'b0};
    else if (accept)
      // Advance past the served bundle.  On a taken slot-2 this is the
      // wrong-path sequential ask, issued anyway and killed by next cycle's
      // registered slot-2 redirect (§2.1.2).
      ask_d = slot2_present ? (s2_pc + s2_size) : (served_addr + s1_size);
    else ask_d = ask_q;  // hold the ask (freeze / backpressure / stale window)
  end

  assign o_ask_pc        = ask_d[XLEN-1:1];
  assign o_lookup_pc     = ask_d[XLEN-1:1];  // slot-1 ask-time lookup
  assign o_lookup_pc_2   = s2_pc[XLEN-1:1];  // slot-2 walk-time lookup

  // ===========================================================================
  // Queue flush + provider retarget pulse
  // ===========================================================================
  // The slot-2 redirect is a resteer with NO flush (e0/e1 are valid, in-order).
  assign o_flush_full    = i_redirect_valid && !i_redirect_partial;
  assign o_flush_partial = i_redirect_valid && i_redirect_partial;
  assign o_core_redirect = i_redirect_valid || slot2_redir_fire;

  // ===========================================================================
  // State update
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ask_q                 <= '0;  // reset vector 0 (core overrides via a redirect)
      bind_valid_q          <= 1'b0;
      slot2_redir_pending_q <= 1'b0;
    end else begin
      ask_q                 <= ask_d;
      // Capture this cycle's slot-1 ask-time lookup for next-cycle binding.
      bind_valid_q          <= 1'b1;
      bind_pc_q             <= ask_d[XLEN-1:1];
      bind_btb_hit_q        <= i_btb_hit;
      bind_btb_taken_q      <= i_btb_taken;
      bind_btb_target_q     <= i_btb_target;
      bind_dir_taken_q      <= i_dir_taken;
      bind_dir_idx_q        <= i_dir_idx;
      // Arm the one-shot slot-2 redirect for next cycle.  An external redirect
      // dominates and clears it; slot2_taken is false on a fire cycle (accept
      // gated), so the pending bit self-clears after firing.
      slot2_redir_pending_q <= !i_redirect_valid && slot2_taken;
      if (slot2_taken) slot2_redir_target_q <= i_btb_target_2;
    end
  end

`ifndef SYNTHESIS
  // The slot-1 pc-tag makes a bound prediction's address provably e0's address.
  always_ff @(posedge i_clk) begin
    if (!i_rst && o_enq_valid[0] && e0.predicted_taken) begin
      p_bound_taken_pc_matches :
      assert (bind_pc_q == e0.pc)
      else $error("parcel_fill_engine: taken binding pc-tag mismatch");
    end
  end
  // Slot-2 is contiguous with slot-1, and a fire cycle enqueues nothing.
  always_ff @(posedge i_clk) begin
    if (!i_rst && o_enq_valid[1]) begin
      p_slot2_implies_slot1 : assert (o_enq_valid[0]);
      // Downstream invariant: slot-2 PC = slot-1 PC + size(slot-1) (in [31:1]
      // units, a compressed slot-1 advances the word-pc by 1, a 32-bit by 2).
      p_slot2_contiguous : assert (e1.pc == (e0.pc + (s1_is_compressed ? 31'd1 : 31'd2)));
    end
    if (!i_rst && slot2_redir_fire) begin
      p_fire_bubbles : assert (o_enq_valid == 2'b00);
    end
  end
`endif

endmodule : parcel_fill_engine
