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
 * lq_coherence_port: the core's side of the DMA coherence handshake
 * (hw/rtl/lib/cache/dma_coherence_sequencer.sv). A DMA write to a line the
 * CPU may hold walks three phases here, in the order the sequencer issues
 * them:
 *
 *   admit    The line is admitted when no atomic on it is between its read
 *            and its write: the load queue reports a staged, in-flight or
 *            write-phase AMO or LR on the line (o_lq_query_busy), and this
 *            module tracks an SC at the ROB head whose address is known (it
 *            may fire this cycle) and a fired SC whose store has not yet
 *            drained. From admission until release the line is mirrored
 *            here, the load queue holds AMO and LR launches on it, and the
 *            SC pending unit holds SC fires on it.
 *   inval    After the L1D probe has invalidated every copy, the load queue
 *            drops the L0's dword copies, marks in-flight loads of the line
 *            not-to-fill and in-flight LRs reservation-suppressed, and
 *            clears a matching reservation. Every load in the validation
 *            table that observed memory on the line is flagged: the ROB
 *            replays a flagged load when it reaches the head (restart at its
 *            own PC, no architectural side effect), so a younger load that
 *            sampled the line before the DMA write can never retire after an
 *            older load that sampled it afterwards.
 *   release  The DMA write has been ordered at the shared level: the mirror
 *            entry is dropped and the launch holds lift.
 *
 * Pipelining. The admit answer is computed one cycle after the presented
 * request is registered here and returned a cycle later, qualified by the
 * presented slot, so nothing combinational crosses the hierarchy: the load
 * queue's comparators start from this module's flops and end in one. The
 * window between that check and the atomic launches it could miss is
 * closed by blanket holds: the load queue holds every staged AMO/LR launch
 * and the SC unit holds every SC fire in the cycle the answer is presented
 * (the fire cycle) and the cycle after it, by which time the mirror-based
 * holds have caught up; an atomic captured in the decision cycle is staged
 * when the admission fires, and its first launch waits for its own compare
 * against the mirror (the load queue's coh_hold_valid_q). The SC hold names
 * the ROB head it was computed for, so an SC whose address became known
 * since waits for its own compare. Invalidation is
 * applied from flops as well and takes four cycles: register the line,
 * apply it (L0 clear, slot marks, reservation), compare the validation table
 * and the observation still in the pipeline register, report done.
 *
 * Validation table. One entry per ROB tag, written from a pipeline register
 * one cycle after the load queue reports a cached load's memory observation
 * (an L0 hit, a store-queue forward or a launch to the L1D), cleared when
 * the tag retires (both commit slots) or is flushed; an observation of a
 * load a flush kills in the same cycle is never written, so a reused tag
 * starts clean. A load stays validated from its observation
 * to its retirement, so its value is equivalent to one observed at
 * retirement; with stores ordered at the L1D before a FENCE retires and
 * device loads completing at the head, that is what makes every FENCE
 * variant, acquire and same-address ordering hold under a second agent
 * without serializing loads. The replay mask is registered, so the line
 * comparators sit off the ROB's commit cone.
 *
 * Flushes. The mirror tracks the hierarchy, not speculative core state, so
 * it survives flushes: the sequencer still holds its entry and releases it
 * once the write is ordered. A full flush squashes an uncommitted SC: its
 * window closes (or never opens, for a fire coinciding with the flush), but
 * a committed SC's window stays until its store has drained.
 */
module lq_coherence_port #(
    parameter int unsigned NUM_LOCK = riscv_pkg::DmaCoherenceLocks,
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned LockBits = (NUM_LOCK > 1) ? $clog2(NUM_LOCK) : 1,
    localparam int unsigned TagWidth = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned RobDepth = riscv_pkg::ReorderBufferDepth
) (
    input logic i_clk,
    input logic i_rst_n,

    // Hierarchy handshake (dma_coherence_sequencer): latched presentations.
    input  logic                i_admit_valid,
    input  logic [LockBits-1:0] i_admit_slot,
    input  logic [    XLEN-1:0] i_admit_addr,
    output logic                o_admit_ready,
    input  logic                i_inval_valid,
    input  logic [LockBits-1:0] i_inval_slot,
    output logic                o_inval_done,
    input  logic                i_release_valid,
    input  logic [LockBits-1:0] i_release_slot,

    // Load queue.
    output logic [    XLEN-1:0]           o_lq_query_addr,
    input  logic                          i_lq_query_busy,
    output logic                          o_lq_inval_valid,
    output logic [    XLEN-1:0]           o_lq_inval_addr,
    output logic [NUM_LOCK-1:0]           o_lq_block_valid,
    output logic [NUM_LOCK-1:0][XLEN-1:0] o_lq_block_addr,
    output logic                          o_lq_admit_pulse,   // blanket AMO/LR launch hold
    input  logic                          i_observe_valid,
    input  logic [TagWidth-1:0]           i_observe_rob_tag,
    input  logic [    XLEN-1:0]           i_observe_addr,

    // SC pending unit and the commit bus.
    input  logic            i_sc_head_addr_valid,  // an SC at the head knows its address
    input  logic [XLEN-1:0] i_sc_head_addr,
    input  logic            i_sc_fire_success,     // a successful SC fired this cycle
    input  logic            i_sc_commit,           // any SC committed this cycle
    input  logic            i_sq_committed_empty,
    output logic            o_sc_hold,             // hold SC fires

    // Retirement and flushes for the validation table.
    input logic                i_commit_valid,
    input logic [TagWidth-1:0] i_commit_tag,
    input logic                i_commit_valid_2,
    input logic [TagWidth-1:0] i_commit_tag_2,
    input logic                i_flush_all,
    input logic                i_flush_en,
    input logic [TagWidth-1:0] i_flush_tag,
    input logic [TagWidth-1:0] i_head_tag,

    // ROB: entries to mark for replay (registered).
    output logic [RobDepth-1:0] o_replay_set_mask
);
  localparam int unsigned LineLsb = 5;  // 32-byte lines
  localparam int unsigned LineBits = XLEN - LineLsb;

  function automatic logic [LineBits-1:0] line_of(input logic [XLEN-1:0] addr);
    line_of = addr[XLEN-1:LineLsb];
  endfunction

  // True when tag is younger than flush_tag, measured from head (the ROB's
  // should_flush_entry / the SC unit's is_younger).
  function automatic logic is_younger(input logic [TagWidth-1:0] tag,
                                      input logic [TagWidth-1:0] flush_tag,
                                      input logic [TagWidth-1:0] head);
    logic [TagWidth:0] tag_age, flush_age;
    tag_age = {1'b0, tag} - {1'b0, head};
    flush_age = {1'b0, flush_tag} - {1'b0, head};
    is_younger = tag_age > flush_age;
  endfunction

  // ---------------------------------------------------------------------------
  // Admitted-line mirror
  // ---------------------------------------------------------------------------
  logic [NUM_LOCK-1:0] adm_valid_q;
  logic [LineBits-1:0] adm_line_q  [NUM_LOCK];
  always_comb begin
    for (int k = 0; k < int'(NUM_LOCK); k++) begin
      o_lq_block_valid[k] = adm_valid_q[k];
      o_lq_block_addr[k]  = {adm_line_q[k], {LineLsb{1'b0}}};
    end
  end

  // ---------------------------------------------------------------------------
  // SC window: the head SC's line is captured every cycle (no deep enable);
  // a registered successful fire opens the window on that captured line, and
  // it closes once the committed SC's store has drained.
  // ---------------------------------------------------------------------------
  logic sc_head_valid_q, sc_fired_q;
  logic [LineBits-1:0] sc_head_line_q;
  logic [TagWidth-1:0] sc_head_tag_q;
  logic sc_win_valid_q, sc_win_committed_q, sc_win_committed_seen_q;
  logic [LineBits-1:0] sc_win_line_q;
  logic sc_hold_q, sc_hold_valid_q;
  logic [TagWidth-1:0] sc_hold_tag_q;

  // ---------------------------------------------------------------------------
  // Admission pipeline
  // ---------------------------------------------------------------------------
  logic adm_req_valid_q;
  logic [LockBits-1:0] adm_req_slot_q;
  logic [LineBits-1:0] adm_req_line_q;
  logic admit_ready_q;
  logic [LockBits-1:0] admit_ready_slot_q;
  logic admit_fire, admit_fired_q, admit_ready_d, lq_admit_pulse_q;

  assign o_lq_query_addr = {adm_req_line_q, {LineLsb{1'b0}}};
  logic sc_conflict;
  assign sc_conflict = (i_sc_head_addr_valid && (line_of(
      i_sc_head_addr
  ) == adm_req_line_q)) || (sc_fired_q && (sc_head_line_q == adm_req_line_q)) ||
      (sc_win_valid_q && (sc_win_line_q == adm_req_line_q));
  // The answer names the entry it was computed for; the sequencer presents
  // a latched entry, so a mismatch only means the entry has moved on.
  assign o_admit_ready = admit_ready_q && i_admit_valid && (i_admit_slot == admit_ready_slot_q);
  assign admit_fire = o_admit_ready;
  // One flop for the load queue's launch gate: the same OR of the decision
  // and fired cycles, registered from their next-state values.
  assign admit_ready_d = adm_req_valid_q && !i_lq_query_busy && !sc_conflict && !admit_fire;
  assign o_lq_admit_pulse = lq_admit_pulse_q;
  // sc_hold_q was computed for the head named by sc_hold_tag_q; a different
  // head (or one whose address was not yet known) has no hold of its own.
  logic sc_hold_current;
  assign sc_hold_current = sc_hold_valid_q && (sc_hold_tag_q == i_head_tag);
  assign o_sc_hold = sc_hold_q || !sc_hold_current || admit_ready_q || admit_fired_q;

  // ---------------------------------------------------------------------------
  // Invalidation: four phases from the sequencer's request (see the header).
  // ---------------------------------------------------------------------------
  logic [1:0] inval_phase_q;
  logic lq_inval_valid_q;
  logic [LineBits-1:0] inval_line_q;
  assign o_lq_inval_valid = lq_inval_valid_q;
  assign o_lq_inval_addr  = {inval_line_q, {LineLsb{1'b0}}};
  assign o_inval_done     = (inval_phase_q == 2'd3);

  // ---------------------------------------------------------------------------
  // Validation table with its observation pipeline register
  // ---------------------------------------------------------------------------
  logic obs_pend_valid_q;
  logic [TagWidth-1:0] obs_pend_tag_q;
  logic [LineBits-1:0] obs_pend_line_q;
  logic [RobDepth-1:0] obs_valid_q;
  logic [LineBits-1:0] obs_line_q[RobDepth];
  logic [RobDepth-1:0] replay_mask_d, replay_mask_q;
  always_comb begin
    for (int i = 0; i < int'(RobDepth); i++) begin
      replay_mask_d[i] = (inval_phase_q == 2'd2) &&
          ((obs_valid_q[i] && (obs_line_q[i] == inval_line_q)) ||
           (obs_pend_valid_q && (obs_pend_tag_q == TagWidth'(i)) &&
            (obs_pend_line_q == inval_line_q)));
    end
  end
  assign o_replay_set_mask = replay_mask_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      adm_valid_q             <= '0;
      sc_head_valid_q         <= 1'b0;
      sc_fired_q              <= 1'b0;
      sc_win_valid_q          <= 1'b0;
      sc_win_committed_q      <= 1'b0;
      sc_win_committed_seen_q <= 1'b0;
      sc_hold_q               <= 1'b0;
      sc_hold_valid_q         <= 1'b0;
      adm_req_valid_q         <= 1'b0;
      admit_ready_q           <= 1'b0;
      lq_admit_pulse_q        <= 1'b0;
      admit_fired_q           <= 1'b0;
      inval_phase_q           <= 2'd0;
      lq_inval_valid_q        <= 1'b0;
      obs_pend_valid_q        <= 1'b0;
      obs_valid_q             <= '0;
      replay_mask_q           <= '0;
    end else begin
      // Admission pipeline: capture the presentation, decide, answer.
      adm_req_valid_q    <= i_admit_valid && !admit_fire;
      adm_req_slot_q     <= i_admit_slot;
      adm_req_line_q     <= line_of(i_admit_addr);
      admit_ready_q      <= admit_ready_d;
      lq_admit_pulse_q   <= admit_ready_d || admit_fire;
      admit_ready_slot_q <= adm_req_slot_q;
      admit_fired_q      <= admit_fire;

      // Mirror.
      if (i_release_valid) adm_valid_q[i_release_slot] <= 1'b0;
      if (admit_fire) begin
        adm_valid_q[admit_ready_slot_q] <= 1'b1;
        adm_line_q[admit_ready_slot_q]  <= line_of(i_admit_addr);
      end

      // SC window: opens the cycle after a successful fire that no full
      // flush squashed, is marked committed by the SC's commit whenever it
      // arrives (the opening cycle included), and closes once the committed
      // store has drained; a full flush closes an uncommitted window.
      sc_head_valid_q         <= i_sc_head_addr_valid;
      sc_head_line_q          <= line_of(i_sc_head_addr);
      sc_head_tag_q           <= i_head_tag;
      sc_fired_q              <= i_sc_fire_success && !i_flush_all;
      sc_win_committed_seen_q <= sc_win_committed_q;
      if (i_flush_all && !sc_win_committed_q) begin
        sc_win_valid_q     <= 1'b0;
        sc_win_committed_q <= 1'b0;
      end else if (sc_fired_q) begin
        sc_win_valid_q     <= 1'b1;
        sc_win_committed_q <= i_sc_commit;
        sc_win_line_q      <= sc_head_line_q;
      end else if (sc_win_valid_q) begin
        if (i_sc_commit) sc_win_committed_q <= 1'b1;
        if (sc_win_committed_seen_q && i_sq_committed_empty) begin
          sc_win_valid_q     <= 1'b0;
          sc_win_committed_q <= 1'b0;
        end
      end
      sc_hold_q       <= 1'b0;
      sc_hold_valid_q <= sc_head_valid_q;
      sc_hold_tag_q   <= sc_head_tag_q;
      for (int k = 0; k < int'(NUM_LOCK); k++) begin
        if (adm_valid_q[k] && sc_head_valid_q && (adm_line_q[k] == sc_head_line_q))
          sc_hold_q <= 1'b1;
      end

      // Invalidation phases.
      lq_inval_valid_q <= 1'b0;
      unique case (inval_phase_q)
        2'd0: begin
          if (i_inval_valid) begin
            inval_line_q     <= adm_line_q[i_inval_slot];
            lq_inval_valid_q <= 1'b1;
            inval_phase_q    <= 2'd1;
          end
        end
        2'd1: inval_phase_q <= 2'd2;  // the load queue applies this cycle
        2'd2: inval_phase_q <= 2'd3;  // the replay mask is computed this cycle
        default: inval_phase_q <= 2'd0;  // done presented; the sequencer fires
      endcase

      // Validation table: pipeline register, then the table.
      // An observation of a load a flush kills in this same cycle is dropped
      // here: its tag is free for reuse, and the table must never carry an
      // entry for an instruction other than the load that observed.
      obs_pend_valid_q <= i_observe_valid && !i_flush_all && !(i_flush_en && is_younger(
          i_observe_rob_tag, i_flush_tag, i_head_tag
      ));
      obs_pend_tag_q <= i_observe_rob_tag;
      obs_pend_line_q <= line_of(i_observe_addr);
      replay_mask_q <= replay_mask_d;
      if (i_flush_all) begin
        obs_valid_q <= '0;
      end else begin
        if (i_flush_en) begin
          for (int i = 0; i < int'(RobDepth); i++) begin
            if (obs_valid_q[i] && is_younger(TagWidth'(i), i_flush_tag, i_head_tag))
              obs_valid_q[i] <= 1'b0;
          end
        end
        if (i_commit_valid) obs_valid_q[i_commit_tag] <= 1'b0;
        if (i_commit_valid_2) obs_valid_q[i_commit_tag_2] <= 1'b0;
        if (obs_pend_valid_q && !(i_flush_en && is_younger(
                obs_pend_tag_q, i_flush_tag, i_head_tag
            ))) begin
          obs_valid_q[obs_pend_tag_q] <= 1'b1;
          obs_line_q[obs_pend_tag_q]  <= obs_pend_line_q;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      if (admit_fire && adm_valid_q[admit_ready_slot_q])
        $error("lq_coherence_port: slot %0d admitted while held", admit_ready_slot_q);
      if (i_inval_valid && (inval_phase_q == 2'd0) && !adm_valid_q[i_inval_slot])
        $error("lq_coherence_port: invalidation for slot %0d never admitted", i_inval_slot);
      if (i_release_valid && !adm_valid_q[i_release_slot])
        $error("lq_coherence_port: release of slot %0d never admitted", i_release_slot);
    end
  end
`endif

endmodule : lq_coherence_port
