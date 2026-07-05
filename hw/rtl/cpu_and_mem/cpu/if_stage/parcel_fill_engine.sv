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
 * (PARCEL_QUEUE_DESIGN.md sections 2.1 / 2.1.1).  Landing step B1: the 1-wide,
 * self-aligned relocation of today's ask-side machinery.  Enqueues one
 * pq_entry_t per served instruction into the parcel_queue; the 2-wide bundle
 * (slot-2 lookup + straddle carry) is deferred to B2/B3.
 *
 * ASK CHAIN (derived from RTL, design 2.1.1):
 *   - `ask_q` is the leading ask presented last cycle (today's `o_pc` role);
 *     `o_ask_pc` / `o_lookup_pc` present this cycle's ask combinationally.
 *   - The provider serves the ask presented last cycle one cycle later, tagged
 *     with `i_win_served_addr` (today's `o_pc_reg` role, but supplied by the
 *     provider so the frame is SELF-ALIGNED: the served window's low word is
 *     word(served_addr) by construction -- no bank_sel/pc_reg[2] parity, and
 *     the F-vs-W disambiguation ceases to exist).
 *   - SEQUENTIAL advance uses the served instruction's size, decoded from the
 *     arriving window's sideband (SERVE time).  The ask's own bytes have not
 *     returned, so its size cannot drive its own advance.
 *   - A predicted-TAKEN slot-1 branch is the only ask-time input: the BTB
 *     result looked up at `ask_q` (ask time) rides `bind_q` one cycle and, when
 *     that branch is served, redirects the next ask to the target (zero-bubble
 *     in the ask stream, as today).
 *
 * BINDING (pc-tagged, design 2.1.1): `bind_q` carries the ask-time slot-1
 * lookup {pc, btb/dir result} forward one cycle.  At enqueue the entry binds
 * that result IFF `bind_q.pc == entry.pc`; otherwise it binds zeroed
 * not-taken metadata.  Because BTB/DIR metadata is a pure function of the
 * lookup address, an address match is correct unconditionally -- this is the
 * epoch's job done without a counter (a resteer changes the enqueued address,
 * so a stale binding stops matching for free).
 *
 * WINDOW ACCEPTANCE (tag-checked, design 7.1): a window is enqueued only when
 * it is valid, its served word matches the outstanding ask, no redirect is
 * landing this cycle, and the queue is not backpressuring.  A valid-but-
 * mismatched window (a stale wrong-path presentation around a retarget) is
 * treated as an unserved cycle.
 *
 * REDIRECT (design 2.5): `i_redirect_valid` resteers the ask, pulses
 * `o_core_redirect` to the provider seam, and flushes the queue -- full
 * (backend / trap / MRET / FENCE.I / PD) or partial (`i_redirect_partial`, the
 * RAS dequeue-fire that keeps the head return entry).  A redirect dominates the
 * same-cycle enqueue (accept is gated off).
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

    // ---- BTB / DIR lookup (combinational, at the ask address) ----
    output logic [                   XLEN-1:1] o_lookup_pc,
    input  logic                               i_btb_hit,
    input  logic                               i_btb_taken,
    input  logic [                   XLEN-1:1] i_btb_target,
    input  logic                               i_dir_taken,
    input  logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_idx,

    // ---- Provider ask out (fetch side) ----
    output logic [XLEN-1:1] o_ask_pc,
    output logic            o_core_redirect, // resteer pulse to the provider seam

    // ---- Queue enqueue out ----
    output logic                 [1:0] o_enq_valid,     // [1] implies [0]; 1-wide: [1] tied 0
    output riscv_pkg::pq_entry_t       o_enq_entry0,
    output riscv_pkg::pq_entry_t       o_enq_entry1,
    output logic                       o_flush_full,
    output logic                       o_flush_partial,

    // ---- Queue backpressure in ----
    input logic i_queue_backpressure
);

  localparam int unsigned SbWidth = riscv_pkg::ImemSidebandWidth;

  // ===========================================================================
  // Ask register + binding pipe
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

  // ===========================================================================
  // Serve decode (self-aligned: the served instruction is at ask_q; the window
  // low word is word(ask_q) by construction, so no parity reconciliation).
  // ===========================================================================
  logic [                   XLEN-1:0] served_addr;
  logic                               served_hw;  // halfword within the low word (bit 1)
  assign served_addr = ask_q;
  assign served_hw   = ask_q[1];

  logic [31:0] low_word, high_word;
  assign low_word  = i_win_instr[31:0];
  assign high_word = i_win_instr[63:32];

  // B1 (1-wide) decodes only the served instruction from the low word: the
  // high window word's upper half and the high-word sideband are slot-2 (B2)
  // territory, and served_addr bit 0 is always 0 (2-byte alignment).  Sink the
  // as-yet-unused bits so lint stays clean until B2 wires them in.
  wire _unused_b2 = &{1'b0, i_win_served_addr[0], high_word[31:16],
                      i_win_sideband[2*SbWidth-1:SbWidth]};

  // Current-word sideband is the low sideband word (word(ask_q)).
  logic [SbWidth-1:0] sb_cur;
  assign sb_cur = i_win_sideband[SbWidth-1:0];

  logic is_compressed;
  logic allows_slot2_after;
  logic slot2_start_ok;
  assign is_compressed = served_hw ? sb_cur[riscv_pkg::ImemSbIsCompressedHi]
                                   : sb_cur[riscv_pkg::ImemSbIsCompressedLo];
  assign allows_slot2_after = served_hw ? sb_cur[riscv_pkg::ImemSbAllowsSlot2AfterHi]
                                        : sb_cur[riscv_pkg::ImemSbAllowsSlot2AfterLo];
  assign slot2_start_ok = served_hw ? sb_cur[riscv_pkg::ImemSbSlot2StartValidHi]
                                    : sb_cur[riscv_pkg::ImemSbSlot2StartValidLo];

  // Instruction bytes: RVC parcel in [15:0]; native word aligned or
  // spanning-assembled from the two window words.
  logic [15:0] parcel;
  logic [31:0] instr_bytes;
  assign parcel = served_hw ? low_word[31:16] : low_word[15:0];
  always_comb begin
    if (is_compressed) instr_bytes = {16'h0000, parcel};
    else if (!served_hw) instr_bytes = low_word;
    else instr_bytes = {high_word[15:0], low_word[31:16]};  // spanning at halfword
  end

  logic [XLEN-1:0] served_size;
  assign served_size = is_compressed ? riscv_pkg::PcIncrementCompressed
                                     : riscv_pkg::PcIncrement32bit;

  // ===========================================================================
  // Window acceptance (tag-checked) and pc-tagged binding
  // ===========================================================================
  logic served_tag_ok;
  logic accept;
  assign served_tag_ok = (i_win_served_addr[XLEN-1:1] == ask_q[XLEN-1:1]);
  assign accept = i_win_valid && served_tag_ok && !i_redirect_valid && !i_queue_backpressure;

  logic bind_match;
  assign bind_match = bind_valid_q && (bind_pc_q == ask_q[XLEN-1:1]);

  // ===========================================================================
  // Enqueue entry
  // ===========================================================================
  riscv_pkg::pq_entry_t entry;
  always_comb begin
    entry                    = '0;
    entry.pc                 = served_addr[XLEN-1:1];
    entry.instr_bytes        = riscv_pkg::instr_t'(instr_bytes);
    entry.is_compressed      = is_compressed;
    entry.allows_slot2_after = allows_slot2_after;
    entry.slot2_start_ok     = slot2_start_ok;
    entry.btb_hit            = bind_match ? bind_btb_hit_q : 1'b0;
    entry.predicted_taken    = bind_match ? bind_btb_taken_q : 1'b0;
    entry.predicted_target   = bind_match ? bind_btb_target_q : '0;
    entry.dir_taken          = bind_match ? bind_dir_taken_q : 1'b0;
    entry.dir_idx            = bind_match ? bind_dir_idx_q : '0;
  end

  assign o_enq_valid  = {1'b0, accept};  // 1-wide skeleton: slot-2 unused
  assign o_enq_entry0 = entry;
  assign o_enq_entry1 = '0;

  // A served predicted-taken branch is the ask-time redirect: its (registered)
  // binding steers the next ask to the target.
  logic taken_redirect;
  assign taken_redirect = accept && bind_match && bind_btb_taken_q;

  // ===========================================================================
  // Next ask (design 2.5 priority): redirect > taken slot-1 > sequential >
  // hold (freeze / backpressure / unserved).
  // ===========================================================================
  logic [XLEN-1:0] ask_d;
  always_comb begin
    if (i_redirect_valid) ask_d = {i_redirect_target, 1'b0};
    else if (taken_redirect) ask_d = {bind_btb_target_q, 1'b0};
    else if (accept) ask_d = served_addr + served_size;
    else ask_d = ask_q;  // hold the ask (freeze / backpressure / stale window)
  end

  assign o_ask_pc    = ask_d[XLEN-1:1];
  assign o_lookup_pc = ask_d[XLEN-1:1];

  // ===========================================================================
  // Queue flush + provider retarget pulse
  // ===========================================================================
  assign o_flush_full    = i_redirect_valid && !i_redirect_partial;
  assign o_flush_partial = i_redirect_valid && i_redirect_partial;
  assign o_core_redirect = i_redirect_valid;

  // ===========================================================================
  // State update
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ask_q        <= '0;  // reset vector 0 (core overrides via a redirect)
      bind_valid_q <= 1'b0;
    end else begin
      ask_q             <= ask_d;
      // Capture this cycle's ask-time lookup for next-cycle binding.  A
      // redirect target's own lookup is captured normally (it is the correct
      // path); a partial redirect likewise re-arms at the return target.
      bind_valid_q      <= 1'b1;
      bind_pc_q         <= ask_d[XLEN-1:1];
      bind_btb_hit_q    <= i_btb_hit;
      bind_btb_taken_q  <= i_btb_taken;
      bind_btb_target_q <= i_btb_target;
      bind_dir_taken_q  <= i_dir_taken;
      bind_dir_idx_q    <= i_dir_idx;
    end
  end

`ifndef SYNTHESIS
  // The pc-tag makes a bound prediction's address provably the entry's address.
  always_ff @(posedge i_clk) begin
    if (!i_rst && o_enq_valid[0] && entry.predicted_taken) begin
      p_bound_taken_pc_matches :
      assert (bind_pc_q == entry.pc)
      else $error("parcel_fill_engine: taken binding pc-tag mismatch");
    end
  end
`endif

endmodule : parcel_fill_engine
