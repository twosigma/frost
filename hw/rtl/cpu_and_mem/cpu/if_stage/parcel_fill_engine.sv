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
 * (PARCEL_QUEUE_DESIGN.md sections 2.1 / 2.1.1 / 2.1.2 / 2.1.3 / 2.6).
 *
 * SEQUENTIAL-MARCH FETCH (x3 timing closure, design 2.1.3).  The original walk
 * tied the imem fetch ADDRESS to the decoded next-instruction address, closing a
 * same-cycle combinational loop (BRAM sideband -> 2-wide bundle decode -> next
 * address -> BRAM address) that was the x3 WNS (-3.059 ns).  Registering that ask
 * breaks the loop but serve-every-other-cycle throttles a variable-length fetch
 * (the next address needs the current instruction's size, which a registered
 * address lacks in time) -> +26.7% CoreMark.  This module instead DECOUPLES the
 * two:
 *
 *   - FETCH side: `fetch_ptr_q` is a REGISTERED word-address counter that free-
 *     marches +8 B (two words) per cycle, redirect-loadable, gated only by buffer
 *     space.  It drives `o_ask_pc`.  Being a pure register with no dependency on
 *     the decoded window, it breaks the imem loop and, on the always-valid BRAM,
 *     pipelines two words/cycle (no serve-every-other-cycle throttle on the
 *     DECODER).  The provider (fetch_provider, design 2.1.3) marches its own owed
 *     ask in lockstep rather than serve-capturing this pointer, so the runahead
 *     never makes it skip a word.
 *   - An elastic word FIFO buffers arriving windows (two words each).  It
 *     decouples the fetch (push_addr, running ahead) from the instruction-
 *     granular decode (decode_ptr, trailing) -- this runahead IS the prefetch.
 *   - DECODE side: `decode_ptr_q` is the REGISTERED instruction pointer.  The
 *     2-wide bundle decoder (unchanged) reads the two-word self-aligned view at
 *     `decode_ptr` from the FIFO front and advances `decode_ptr` by the bundle
 *     size, gated by queue backpressure.  It fires EVERY cycle the view is
 *     present -- the buffer hides the fetch/decode rate mismatch.
 *
 * The provider seam, parcel_queue, and consume engine are unchanged.  The window
 * acceptance is still address-tag-checked (design 7.1): a window is pushed only
 * when its served word matches the buffer's outstanding-fetch address.
 *
 * BINDING (pc-tagged, design 2.1.1): with `decode_ptr` registered, the slot-1
 * BTB/DIR lookup at `o_lookup_pc = decode_ptr` and the enqueue of that
 * instruction are the SAME cycle, so the prediction binds directly (the
 * lookup address IS the enqueued entry's pc -- the pc-tag holds trivially, no
 * carry register).  Slot-2 binds from its walk-time lookup at `decode_ptr +
 * size(slot-1)`.
 *
 * SLOT-2 (design 2.1.2 / 2.6): a contiguous slot-2 at `decode_ptr + size(slot-1)`
 * is decoded from the same two-word view and enqueued as `e1` iff
 * `e0.allows_slot2_after && e1.slot2_start_ok && !e0.predicted_taken`.  A NEXT_HI
 * 32-bit slot-2 straddles a third word and is suppressed (B3a).
 *
 * REDIRECT (design 2.5): a predicted-TAKEN branch (slot-1 immediate, slot-2
 * one-shot registered) and an external `i_redirect_valid` both resteer the walk.
 * A taken branch flushes only the FETCH BUFFER (the sequentially-prefetched
 * fall-through past the branch is wrong; the enqueued bundle up to the branch is
 * valid) and reloads both pointers to the target -- a fetch bubble absorbed by
 * the queue.  An external redirect additionally flushes the queue -- full
 * (backend / trap / MRET / FENCE.I / PD) or partial (`i_redirect_partial`, the
 * RAS dequeue-fire).  It dominates the taken-branch resteer and the enqueue.
 * The queue flushes fire this cycle (with the consume-side flush); the provider
 * retarget pulse `o_core_redirect` is delayed one cycle so it lands when the
 * registered `fetch_ptr` presents the target.
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

    // ---- Slot-1 BTB / DIR lookup (decode-time, at the decode pointer) ----
    output logic [                   XLEN-1:1] o_lookup_pc,
    input  logic                               i_btb_hit,
    input  logic                               i_btb_taken,
    input  logic [                   XLEN-1:1] i_btb_target,
    input  logic                               i_dir_taken,
    input  logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_idx,

    // ---- Slot-2 BTB / DIR lookup (walk-time, at decode_ptr + size(slot-1)) ----
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
  // Elastic fetch word FIFO
  // ===========================================================================
  // Holds 32-bit words (+ per-word predecode sideband) in fetch order, from the
  // word containing decode_ptr up to the marching fetch pointer.  The decoder
  // peeks the two-word view {word(decode_ptr), word(decode_ptr)+1} at the FIFO
  // front; arriving windows push two words at the back.  Decouples the
  // (registered, marching) fetch address from the (registered, instruction-
  // granular) decode pointer.
  localparam int unsigned BufWords = 8;  // power of two
  localparam int unsigned BufIdxW = $clog2(BufWords);  // 3
  localparam int unsigned BufCntW = $clog2(BufWords + 1);

  logic [       31:0] fifo_word[BufWords];
  logic [SbWidth-1:0] fifo_sb  [BufWords];
  logic [BufIdxW-1:0] rd_ptr_q, wr_ptr_q;
  logic [BufCntW-1:0] count_q;

  // ===========================================================================
  // Fetch request pointer (word-granular free march) + push tag
  // ===========================================================================
  // fetch_ptr_q : the word address requested this cycle (o_ask_pc).  It free-
  //               marches +8 B (two words) per cycle, gated only by buffer room,
  //               so on the always-valid BRAM it pipelines two words/cycle.  The
  //               provider tolerates the runahead because it marches its OWN owed
  //               ask in lockstep (fetch_provider, design 2.1.3) rather than
  //               serve-capturing this pointer -- so it never skips a word.
  // push_addr_q : the word address of the next word-pair expected/pushed (the
  //               FIFO tail).  A window is pushed only when its served word
  //               matches push_addr_q (in-order, tag-checked acceptance);
  //               push_addr trails fetch_ptr by the in-flight window.
  logic [   XLEN-1:0] fetch_ptr_q;
  logic [   XLEN-1:0] push_addr_q;

  // ===========================================================================
  // Decode pointer (instruction address) + registered redirect pulse
  // ===========================================================================
  logic [   XLEN-1:0] decode_ptr_q;
  logic               o_core_redirect_q;

  // Registered slot-2-taken redirect (one-shot; kept off the fast decode path).
  logic               slot2_redir_pending_q;
  logic [   XLEN-1:1] slot2_redir_target_q;

  // ===========================================================================
  // Decode view: the two-word self-aligned window at decode_ptr (FIFO front)
  // ===========================================================================
  logic [31:0] low_word, high_word;
  logic [SbWidth-1:0] sb_lo, sb_hi;
  assign low_word  = fifo_word[rd_ptr_q];
  assign high_word = fifo_word[rd_ptr_q+BufIdxW'(1)];
  assign sb_lo     = fifo_sb[rd_ptr_q];
  assign sb_hi     = fifo_sb[rd_ptr_q+BufIdxW'(1)];

  logic [XLEN-1:0] served_addr;
  logic            served_hw;  // halfword within the low word (bit 1)
  assign served_addr = decode_ptr_q;
  assign served_hw   = decode_ptr_q[1];

  // view_valid: both view words present (need >=2 buffered words to decode).
  logic view_valid;
  assign view_valid = (count_q >= BufCntW'(2));

  // served_addr / s2_pc bit 0 are always 0 (2-byte alignment); sink them so
  // lint stays clean (every other bit is consumed by slot-1/slot-2 decode).
  wire  _unused = &{1'b0, i_win_served_addr[0], s2_pc[0], decode_ptr_q[0]};

  // ===========================================================================
  // Slot-1 decode (the instruction at decode_ptr)
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
  // match, or the unfireable branch+slot-2 bundle wedges dispatch forever.  The
  // predecode sideband only flags COMPRESSED control flow (folded into
  // AllowsSlot2After) -- native control flow has no sideband bit, decode here.
  logic s1_is_native_control;
  assign s1_is_native_control =
      !s1_is_compressed && ((s1_bytes[6:0] == riscv_pkg::OPC_BRANCH) ||
                            (s1_bytes[6:0] == riscv_pkg::OPC_JAL) ||
                            (s1_bytes[6:0] == riscv_pkg::OPC_JALR));

  assign s1_can_lead = (s1_is_compressed ? s1_allows_after_sb : s1_slot2_start_ok) &&
                       !s1_is_native_control;

  logic [XLEN-1:0] s1_size;
  assign s1_size = s1_is_compressed ? riscv_pkg::PcIncrementCompressed
                                    : riscv_pkg::PcIncrement32bit;

  // ===========================================================================
  // Slot-2 decode (contiguous instruction at decode_ptr + size(slot-1))
  // ===========================================================================
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

  logic s2_is_native_control;
  assign s2_is_native_control =
      !s2_is_compressed && ((s2_bytes[6:0] == riscv_pkg::OPC_BRANCH) ||
                            (s2_bytes[6:0] == riscv_pkg::OPC_JAL) ||
                            (s2_bytes[6:0] == riscv_pkg::OPC_JALR));
  logic s2_can_lead;
  assign s2_can_lead = (s2_is_compressed ? s2_allows_after_sb : s2_start_ok) &&
                       !s2_is_native_control;

  // ===========================================================================
  // Redirect + decode-fire arbitration
  // ===========================================================================
  // Only a FULL redirect (flush) gates the decode.  A PARTIAL (RAS-return)
  // redirect must NOT gate the enqueue: o_ras_redirect_valid is computed on the
  // consume side from dequeue-fire, which -- on an FWFT return into an empty
  // queue -- rides this cycle's incoming enqueue.  Gating on it closes a
  // combinational loop; the queue's partial flush already discards any
  // same-cycle wrong-path enqueue.
  logic full_redirect;
  assign full_redirect = i_redirect_valid && !i_redirect_partial;

  logic slot2_redir_fire;
  assign slot2_redir_fire = slot2_redir_pending_q;

  // Decode fires (produces a bundle) when the two-word view is present, the
  // queue can accept, and no FULL redirect / slot-2 redirect is landing this
  // cycle.  Gate on full_redirect, NOT raw i_redirect_valid: the RAS partial
  // redirect is computed on the consume side from this cycle's dequeue-fire,
  // which rides this cycle's enqueue (o_enq_valid <- decode_fire); gating
  // decode_fire on it closes an oscillating combinational loop.  full_redirect
  // masks the partial term to a constant, breaking the loop -- and the queue's
  // partial flush already discards any same-cycle wrong-path enqueue.
  logic decode_fire;
  assign decode_fire = view_valid && !i_queue_backpressure && !full_redirect && !slot2_redir_fire;

  // Slot-1 predicted-taken branch (decode-time; the bind is direct at decode_ptr).
  logic slot1_taken;
  assign slot1_taken = decode_fire && i_btb_taken;

  // ===========================================================================
  // Bundle formation (design 2.1.2)
  // ===========================================================================
  logic slot2_present;
  assign slot2_present = decode_fire && s1_can_lead && s2_start_ok && !slot1_taken && !s2_straddle;

  // Slot-2 predicted-taken branch: walk-time result -> registered redirect.
  logic slot2_taken;
  assign slot2_taken = slot2_present && i_btb_taken_2;

  // ===========================================================================
  // Enqueue entries.  Predictions bind directly (o_lookup_pc == decode_ptr ==
  // e0.pc, so the pc-tag holds trivially; no carry register).
  // ===========================================================================
  riscv_pkg::pq_entry_t e0, e1;
  always_comb begin
    e0                    = '0;
    e0.pc                 = served_addr[XLEN-1:1];
    e0.instr_bytes        = riscv_pkg::instr_t'(s1_bytes);
    e0.is_compressed      = s1_is_compressed;
    e0.allows_slot2_after = s1_can_lead;
    e0.slot2_start_ok     = s1_slot2_start_ok;
    e0.btb_hit            = i_btb_hit;
    e0.predicted_taken    = i_btb_taken;
    e0.predicted_target   = i_btb_target;
    e0.dir_taken          = i_dir_taken;
    e0.dir_idx            = i_dir_idx;
  end

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

  assign o_enq_valid   = {slot2_present, decode_fire};  // slot2_present implies decode_fire
  assign o_enq_entry0  = e0;
  assign o_enq_entry1  = e1;

  assign o_lookup_pc   = decode_ptr_q[XLEN-1:1];  // slot-1 lookup at the decode ptr
  assign o_lookup_pc_2 = s2_pc[XLEN-1:1];  // slot-2 walk-time lookup

  // ===========================================================================
  // Decode advance (bytes) + word-consume count
  // ===========================================================================
  // The next decode address: external redirect > slot-2 fire > slot-1 taken >
  // sequential advance past the served bundle > hold.
  logic [XLEN-1:0] decode_ptr_d;
  logic            decode_reload;  // decode_ptr jumps (redirect / taken branch)
  logic [XLEN-1:1] decode_reload_tgt;
  always_comb begin
    decode_reload     = 1'b1;
    decode_reload_tgt = i_redirect_target;
    if (i_redirect_valid) decode_reload_tgt = i_redirect_target;
    else if (slot2_redir_fire) decode_reload_tgt = slot2_redir_target_q;
    else if (slot1_taken) decode_reload_tgt = i_btb_target;
    else decode_reload = 1'b0;
  end

  logic [XLEN-1:0] seq_advance;
  assign seq_advance = slot2_present ? (s2_pc + s2_size) : (served_addr + s1_size);

  always_comb begin
    if (decode_reload) decode_ptr_d = {decode_reload_tgt, 1'b0};
    else if (decode_fire) decode_ptr_d = seq_advance;
    else decode_ptr_d = decode_ptr_q;  // hold (backpressure / empty buffer)
  end

  // Words consumed from the FIFO front this cycle (word(decode_ptr_d) -
  // word(decode_ptr_q)) when advancing sequentially; the whole buffer is flushed
  // on a reload so no incremental pop then.
  logic [BufIdxW:0] pop_words;
  always_comb begin
    if (decode_reload) pop_words = '0;  // buffer flushed on reload
    else if (decode_fire)
      pop_words = (BufIdxW + 1)'(decode_ptr_d[XLEN-1:2] - decode_ptr_q[XLEN-1:2]);
    else pop_words = '0;
  end

  // ===========================================================================
  // Fetch march + window push (tag-checked, in-order)
  // ===========================================================================
  // A window arriving this cycle is pushed iff it is valid, matches the expected
  // next fetch word (push_addr_q), there is buffer room, and no reload is
  // flushing the buffer this cycle.
  logic buffer_flush;
  assign buffer_flush = i_redirect_valid || slot2_redir_fire || slot1_taken;

  // A window is accepted when it is valid, matches the expected next fetch word
  // (push_addr_q), there is buffer room, and no reload is flushing the buffer.
  logic push_en;
  assign push_en = i_win_valid && !buffer_flush &&
                   (i_win_served_addr[XLEN-1:2] == push_addr_q[XLEN-1:2]) &&
                   (count_q <= BufCntW'(BufWords - 2));

  // Free-march the request pointer while the buffer has room for the result --
  // reserve four word slots (this cycle's push + the in-flight window pair).
  logic fetch_advance;
  assign fetch_advance = !buffer_flush && (count_q <= BufCntW'(BufWords - 4));

  logic [31:0] push_w0, push_w1;
  logic [SbWidth-1:0] push_sb0, push_sb1;
  assign push_w0  = i_win_instr[31:0];
  assign push_w1  = i_win_instr[63:32];
  assign push_sb0 = i_win_sideband[SbWidth-1:0];
  assign push_sb1 = i_win_sideband[2*SbWidth-1:SbWidth];

  // ===========================================================================
  // Queue flush + provider retarget pulse
  // ===========================================================================
  // Queue flushes fire this cycle, aligned with the consume-side flush.  A
  // taken-branch resteer flushes only the fetch buffer (its enqueued bundle is
  // valid), NOT the queue.  The provider retarget PULSE is delayed one cycle so
  // it lands when fetch_ptr_q presents the redirect / taken target.
  assign o_flush_full    = i_redirect_valid && !i_redirect_partial;
  assign o_flush_partial = i_redirect_valid && i_redirect_partial;
  assign o_core_redirect = o_core_redirect_q;

  assign o_ask_pc = fetch_ptr_q[XLEN-1:1];

  // ===========================================================================
  // State update
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      decode_ptr_q          <= '0;  // reset vector 0 (core overrides via a redirect)
      fetch_ptr_q           <= '0;
      push_addr_q           <= '0;
      rd_ptr_q              <= '0;
      wr_ptr_q              <= '0;
      count_q               <= '0;
      o_core_redirect_q     <= 1'b0;
      slot2_redir_pending_q <= 1'b0;
    end else begin
      // ---- Decode pointer ----
      decode_ptr_q <= decode_ptr_d;

      // ---- Fetch request pointer + FIFO ----
      if (buffer_flush) begin
        // Flush the fetch buffer and restart the request march at the resteer
        // target's word.  decode_reload_tgt is the same target the decode pointer
        // takes; the fetch/push pointers word-align it (the halfword offset lives
        // in decode_ptr, surfaced as served_hw at the view).
        fetch_ptr_q <= {decode_reload_tgt[XLEN-1:2], 2'b00};
        push_addr_q <= {decode_reload_tgt[XLEN-1:2], 2'b00};
        rd_ptr_q    <= '0;
        wr_ptr_q    <= '0;
        count_q     <= '0;
      end else begin
        if (fetch_advance) fetch_ptr_q <= fetch_ptr_q + XLEN'(8);
        if (push_en) begin
          fifo_word[wr_ptr_q]             <= push_w0;
          fifo_word[wr_ptr_q+BufIdxW'(1)] <= push_w1;
          fifo_sb[wr_ptr_q]               <= push_sb0;
          fifo_sb[wr_ptr_q+BufIdxW'(1)]   <= push_sb1;
          wr_ptr_q                        <= wr_ptr_q + BufIdxW'(2);
          push_addr_q                     <= push_addr_q + XLEN'(8);
        end
        rd_ptr_q <= rd_ptr_q + BufIdxW'(pop_words);
        count_q  <= count_q + (push_en ? BufCntW'(2) : BufCntW'(0)) - BufCntW'(pop_words);
      end

      // ---- Provider retarget pulse (delayed one cycle to align with fetch_ptr) ----
      o_core_redirect_q <= buffer_flush;

      // ---- Slot-2 one-shot redirect ----
      slot2_redir_pending_q <= !i_redirect_valid && slot2_taken;
      if (slot2_taken) slot2_redir_target_q <= i_btb_target_2;
    end
  end

`ifndef SYNTHESIS
  // Slot-2 is contiguous with slot-1, and a fire cycle enqueues nothing.
  always_ff @(posedge i_clk) begin
    if (!i_rst && o_enq_valid[1]) begin
      p_slot2_implies_slot1 : assert (o_enq_valid[0]);
      p_slot2_contiguous : assert (e1.pc == (e0.pc + (s1_is_compressed ? 31'd1 : 31'd2)));
    end
    // FIFO never overflows or underflows.
    if (!i_rst) begin
      p_count_bound : assert (count_q <= BufCntW'(BufWords));
      p_pop_has_data : assert (pop_words <= count_q);
    end
    // FIFO front word always corresponds to word(decode_ptr).
    if (!i_rst && view_valid && !buffer_flush) begin
      p_front_aligned : assert (pop_words <= (BufIdxW + 1)'(2));
    end
  end
`endif

endmodule : parcel_fill_engine
