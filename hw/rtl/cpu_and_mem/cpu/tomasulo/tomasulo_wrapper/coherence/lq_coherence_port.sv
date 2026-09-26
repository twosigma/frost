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
 *            write-phase AMO or LR on the line (i_lq_query_busy), and this
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
 * The mirror tracks the hierarchy, not speculative core state, so it survives
 * flushes: the sequencer still holds its entry and releases it once the write
 * is ordered.
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
    input  logic            i_sc_head_addr_valid,   // an SC at the head knows its address
    input  logic [XLEN-1:0] i_sc_head_addr,
    input  logic            i_sc_head_query_match,  // current head matches o_lq_query_addr
    input  logic            i_sc_fire_success,      // a successful SC fired this cycle
    input  logic            i_sc_commit,            // any SC committed this cycle
    input  logic            i_sq_committed_empty,
    output logic            o_sc_hold,              // hold SC fires

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
  localparam int unsigned LineLsb  = riscv_pkg::DmaCoherenceLineLsb;  // 32-byte lines
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
  // Admission pipeline. The admit answer is computed one cycle after the
  // presented request is registered here and returned a cycle later,
  // qualified by the presented slot, so nothing combinational crosses the
  // hierarchy: the load queue's comparators start from this module's flops
  // and end in one. The window between that check and the atomic launches it
  // could miss is closed by blanket holds: the load queue holds every staged
  // AMO/LR launch and the SC unit holds every SC fire in the cycle the answer
  // is presented (the fire cycle) and the cycle after it, by which time the
  // mirror-based holds have caught up. An atomic captured in the decision
  // cycle is staged when the admission fires, and its first launch waits for
  // its own compare against the mirror (the load queue's coh_hold_valid_q).
  // ---------------------------------------------------------------------------
  logic adm_req_valid_q;
  logic [LockBits-1:0] adm_req_slot_q;
  logic [LineBits-1:0] adm_req_line_q;
  logic admit_ready_q;
  logic [LockBits-1:0] admit_ready_slot_q;
  logic admit_fire, admit_fired_q, admit_ready_d, lq_admit_pulse_q;

  assign o_lq_query_addr = {adm_req_line_q, {LineLsb{1'b0}}};
  logic sc_conflict;
  // The SC unit compares pending entries with the registered query line before
  // selecting the head, so i_sc_head_query_match equals
  // i_sc_head_addr_valid && line_of(i_sc_head_addr) == adm_req_line_q
  // (asserted below).
  assign sc_conflict = i_sc_head_query_match || (sc_fired_q && sc_head_line_q == adm_req_line_q) ||
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
  // head (or one whose address was not yet known) has no hold of its own, so
  // its SC waits for its own compare.
  logic sc_hold_current;
  assign sc_hold_current = sc_hold_valid_q && (sc_hold_tag_q == i_head_tag);
  assign o_sc_hold = sc_hold_q || !sc_hold_current || admit_ready_q || admit_fired_q;

  // ---------------------------------------------------------------------------
  // Invalidation, applied from flops in four cycles from the sequencer's
  // request: register the line, apply it (L0 clear, slot marks, reservation)
  // while capturing local line copies, compare the validation table and the
  // observation still in the pipeline register, report done. The replay
  // comparators use the local copies for groups of eight ROB rows; they need
  // no additional handshake cycle.
  // ---------------------------------------------------------------------------
  logic [1:0] inval_phase_q;
  logic lq_inval_valid_q;
  logic [LineBits-1:0] inval_line_q;
  assign o_lq_inval_valid = lq_inval_valid_q;
  assign o_lq_inval_addr  = {inval_line_q, {LineLsb{1'b0}}};
  assign o_inval_done     = (inval_phase_q == 2'd3);

  // ---------------------------------------------------------------------------
  // Validation table with its observation pipeline register. One entry per ROB
  // tag, written from the pipeline register one cycle after the load queue
  // reports a cached load's memory observation (an L0 hit, a store-queue
  // forward or a launch to the L1D), and cleared when the tag retires (both
  // commit slots) or is flushed. A load stays validated from its observation
  // to its retirement, so its value is equivalent to one observed at
  // retirement; with stores ordered at the L1D before a FENCE retires and
  // device loads completing at the head, that is what makes every FENCE
  // variant, acquire and same-address ordering hold under a second agent
  // without serializing loads. The replay mask is registered, so the line
  // comparators sit off the ROB's commit cone.
  // ---------------------------------------------------------------------------
  logic obs_pend_valid_q;
  logic [TagWidth-1:0] obs_pend_tag_q;
  logic [LineBits-1:0] obs_pend_line_q;
  logic [RobDepth-1:0] obs_valid_q;
  logic [LineBits-1:0] obs_line_q[RobDepth];
  logic [RobDepth-1:0] replay_mask_d, replay_mask_q;
  // Phase 1 separates the line capture from the phase-2 replay comparison, so
  // local copies captured in that cycle add no cycle to the comparison or the
  // done pulse.
  localparam int unsigned ReplayCompareGroupSize = 8;
  localparam int unsigned ReplayCompareGroups =
      (RobDepth + ReplayCompareGroupSize - 1) / ReplayCompareGroupSize;
  // Preserve the row groups so the load-queue launch and the replay compares
  // can place independently, with only a register-to-register hop between.
  (* dont_touch = "true" *) logic [LineBits-1:0] inval_compare_line_q[ReplayCompareGroups];
  for (
      genvar group_index = 0; group_index < ReplayCompareGroups; group_index++
  ) begin : gen_compare_line
    always_ff @(posedge i_clk) inval_compare_line_q[group_index] <= inval_line_q;
  end
  // Complete small equality groups before their final reduction, avoiding
  // column-bound carry chains across the distributed validation rows.
  localparam int unsigned LineCompareBits   = 15;
  localparam int unsigned LineCompareChunks = (LineBits + LineCompareBits - 1) / LineCompareBits;
  (* keep = "true" *) logic [RobDepth-1:0][LineCompareChunks-1:0] observed_equal_chunks;
  (* keep = "true" *) logic [LineCompareChunks-1:0] pending_equal_chunks;
  for (genvar chunk = 0; chunk < LineCompareChunks; chunk++) begin : gen_line_compare_chunk
    localparam int unsigned FirstBit = chunk * LineCompareBits;
    localparam int unsigned ChunkBits = ((LineBits - FirstBit) < LineCompareBits) ?
        (LineBits - FirstBit) : LineCompareBits;
    assign pending_equal_chunks[chunk] =
        obs_pend_line_q[FirstBit+:ChunkBits] == inval_compare_line_q[0][FirstBit+:ChunkBits];
    for (genvar row = 0; row < RobDepth; row++) begin : gen_row
      assign observed_equal_chunks[row][chunk] =
          obs_line_q[row][FirstBit+:ChunkBits] ==
              inval_compare_line_q[row/ReplayCompareGroupSize][FirstBit+:ChunkBits];
    end
  end

  always_comb begin
    for (int i = 0; i < int'(RobDepth); i++) begin
      replay_mask_d[i] = (inval_phase_q == 2'd2) &&
          ((obs_valid_q[i] && (&observed_equal_chunks[i])) ||
           (obs_pend_valid_q && (obs_pend_tag_q == TagWidth'(i)) &&
            (&pending_equal_chunks)));
    end
  end
  assign o_replay_set_mask = replay_mask_q;

`ifdef COHERENCE_REPLAY_LOCAL_PROOF
  // Checks the grouped, chunked replay compares against the reference replay
  // next-state equation (full-width compares against inval_line_q), plus the
  // phase invariant (in phases 2 and 3 every group copy equals inval_line_q).
  // Only the first reset is assumed; observation, commit, flush and later
  // reset inputs are unrestricted.
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (!i_rst_n);
    if (f_past_valid) begin
      if (inval_phase_q == 2'd2 || inval_phase_q == 2'd3) begin
        for (int group_index = 0; group_index < ReplayCompareGroups; group_index++)
        assert (inval_compare_line_q[group_index] == inval_line_q);
      end
      for (int row = 0; row < RobDepth; row++) begin
        assert (replay_mask_d[row] == ((inval_phase_q == 2'd2) &&
            ((obs_valid_q[row] && (obs_line_q[row] == inval_line_q)) ||
             (obs_pend_valid_q && (obs_pend_tag_q == TagWidth'(row)) &&
              (obs_pend_line_q == inval_line_q)))));
      end
      cover (inval_phase_q == 2'd2 && obs_pend_valid_q && (&pending_equal_chunks));
      cover (inval_phase_q == 2'd2 && obs_valid_q[0] && (&observed_equal_chunks[0]));
      cover (!i_rst_n);
    end
  end
  always_comb begin
    assert ((&pending_equal_chunks) == (obs_pend_line_q == inval_compare_line_q[0]));
    for (int row = 0; row < RobDepth; row++)
    assert ((&observed_equal_chunks[row]) ==
          (obs_line_q[row] == inval_compare_line_q[row/ReplayCompareGroupSize]));
  end
`endif

`ifdef COHERENCE_OBSERVATION_PROOF
  // Track one arbitrary ROB tag from input history. No LQ slot state is
  // needed: an observation stays live until this port sees retirement or a
  // flush. This is a port contract, not a proof of the producing LQ/ROB.
  (* anyconst *) logic [TagWidth-1:0] f_observation_tag;
  logic f_observation_past_valid = 1'b0;
  logic f_observed_q, f_accepted_q, f_had_observation_q, f_observe_previous_q;
  logic [LineBits-1:0] f_latest_line_q, f_previous_line_q;
  logic f_expected_replay_q;
  wire f_observe = i_observe_valid && i_observe_rob_tag == f_observation_tag;
  wire f_commit_1 = i_commit_valid && i_commit_tag == f_observation_tag;
  wire f_commit_2 = i_commit_valid_2 && i_commit_tag_2 == f_observation_tag;
  wire f_commit = f_commit_1 || f_commit_2;
  // Independently order the two segments of the circular ROB: tags below
  // head follow tags at or above head; within a segment numeric order holds.
  wire f_younger = ((f_observation_tag < i_head_tag) == (i_flush_tag < i_head_tag)) ?
      (f_observation_tag > i_flush_tag) : (f_observation_tag < i_head_tag);
  wire f_kill = i_flush_all || (i_flush_en && f_younger);
  wire f_accept = f_observe && !f_kill;
  wire f_pending = obs_pend_valid_q && obs_pend_tag_q == f_observation_tag;
  // A first observation exists only in the pipeline for one cycle. Later
  // observations may overlap an older table value; even different lines are
  // allowed here, so the proof does not assume one observation per load.
  wire f_table_expected = f_observed_q && (!f_accepted_q || f_had_observation_q);
  wire [LineBits-1:0] f_table_line = f_accepted_q ? f_previous_line_q : f_latest_line_q;
  wire f_replay_expected = (inval_phase_q == 2'd2) &&
      ((f_accepted_q && f_latest_line_q == inval_line_q) ||
       (f_table_expected && f_table_line == inval_line_q));

  always_ff @(posedge i_clk) begin
    f_observation_past_valid <= 1'b1;
    if (!f_observation_past_valid) assume (!i_rst_n);
`ifndef COHERENCE_OBSERVATION_UNRESTRICTED
    if (i_rst_n && f_observation_past_valid) begin
      // A load observes before completion, CDB acceptance and ROB retirement;
      // this port receives registered commit lanes. Proving that integration
      // timing is a separate obligation. Use input history, not DUT validity,
      // to exclude retirement overlapping the current or previous observation.
      if (f_commit) assume (!f_observe && !f_observe_previous_q);
    end
`endif

    if (!i_rst_n) begin
      f_observed_q <= 1'b0;
      f_accepted_q <= 1'b0;
      f_had_observation_q <= 1'b0;
      f_observe_previous_q <= 1'b0;
      f_expected_replay_q <= 1'b0;
    end else begin
      f_observe_previous_q <= f_observe;
      f_accepted_q <= f_accept;
      if (f_kill || f_commit) begin
        f_observed_q <= 1'b0;
        f_had_observation_q <= 1'b0;
      end else if (f_observe) begin
        f_observed_q <= 1'b1;
        f_had_observation_q <= f_observed_q;
      end
      if (f_accept) begin
        f_previous_line_q <= f_latest_line_q;
        f_latest_line_q   <= line_of(i_observe_addr);
      end
      f_expected_replay_q <= f_replay_expected;
    end

    if (f_observation_past_valid) begin
      assert (f_pending == f_accepted_q);
      assert (!f_accepted_q || f_observe_previous_q);
      if (f_pending) assert (obs_pend_line_q == f_latest_line_q);
`ifndef COHERENCE_OBSERVATION_UNRESTRICTED
      assert (obs_valid_q[f_observation_tag] == f_table_expected);
      assert ((obs_valid_q[f_observation_tag] || f_pending) == f_observed_q);
      if (obs_valid_q[f_observation_tag]) assert (obs_line_q[f_observation_tag] == f_table_line);
      assert (o_replay_set_mask[f_observation_tag] == f_expected_replay_q);
      if (o_replay_set_mask[f_observation_tag])
        assert ($past(i_rst_n && f_observed_q && inval_phase_q == 2'd2));
`endif
      // Strengthen induction across the actual invalidation pipeline. The
      // observation proof uses the captured line, not the optimized compares.
      if (inval_phase_q == 2'd2 || inval_phase_q == 2'd3) begin
        for (int group_index = 0; group_index < ReplayCompareGroups; group_index++)
        assert (inval_compare_line_q[group_index] == inval_line_q);
      end
      // These checks also run with the producer assumption disabled. Pending
      // writes take priority over commit cleanup, but never over a flush kill.
      if (!$past(i_rst_n) || $past(f_kill) || $past(f_commit && !f_observe && !f_accepted_q)) begin
        assert (!f_pending);
        assert (!obs_valid_q[f_observation_tag]);
      end
      if ($past(i_rst_n && f_accepted_q && !f_kill)) begin
        assert (obs_valid_q[f_observation_tag]);
        assert (obs_line_q[f_observation_tag] == $past(f_latest_line_q));
      end
    end
  end

  // Reachability checks exercise cleanup, wraparound and re-observation of a
  // reused tag. They do not assert that the DMA or ROB environment progresses.
  logic [2:0] f_quiet_cycles_q;
  logic f_released_q, f_reused_q, f_released_by_commit_q, f_inval_admitted_q;
  logic [LineBits-1:0] f_released_line_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_quiet_cycles_q <= '0;
      f_released_q <= 1'b0;
      f_reused_q <= 1'b0;
      f_released_by_commit_q <= 1'b0;
      f_inval_admitted_q <= 1'b0;
    end else begin
      if (inval_phase_q == 2'd0 && i_inval_valid)
        f_inval_admitted_q <= (int'(i_inval_slot) < int'(NUM_LOCK)) && adm_valid_q[i_inval_slot];
      if (!f_observed_q || f_observe || f_kill || f_commit) f_quiet_cycles_q <= '0;
      else if (!(&f_quiet_cycles_q)) f_quiet_cycles_q <= f_quiet_cycles_q + 1'b1;
      if (f_observed_q && (f_kill || f_commit)) begin
        f_released_q <= 1'b1;
        f_released_line_q <= f_latest_line_q;
        f_released_by_commit_q <= f_commit && !f_kill;
        f_reused_q <= 1'b0;
      end
      if (f_released_q && f_accept && line_of(i_observe_addr) != f_released_line_q)
        f_reused_q <= 1'b1;
    end
    if (f_observation_past_valid && i_rst_n) begin
      cover (f_quiet_cycles_q >= 3'd4 && obs_valid_q[f_observation_tag]);
      cover (f_observed_q && f_commit_1);
      cover (f_observed_q && f_commit_2 && i_commit_valid &&
          i_commit_tag == TagWidth'(f_observation_tag - 1'b1));
      cover (f_observed_q && f_commit && i_observe_valid && !f_observe);
      cover ($past(i_rst_n && f_pending && i_flush_all) && !f_observed_q);
      cover ($past(
          i_rst_n && f_pending && i_flush_en && !i_flush_all &&
          f_observation_tag < i_head_tag && i_flush_tag >= i_head_tag
      ) && !f_observed_q);
      cover ($past(i_rst_n && f_observe && i_flush_all) && !f_pending);
      cover ($past(i_rst_n && f_observe && i_flush_en && !i_flush_all && f_younger) && !f_pending);
      cover ($past(
          i_rst_n && f_accept && i_flush_en && f_observation_tag == i_flush_tag
      ) && f_pending);
      cover ($past(
          i_rst_n && f_accept && i_flush_en && f_observation_tag != i_flush_tag
      ) && f_pending);
      cover (f_reused_q && obs_valid_q[f_observation_tag] && !f_pending &&
          obs_line_q[f_observation_tag] != f_released_line_q && f_released_by_commit_q);
      cover (f_reused_q && obs_valid_q[f_observation_tag] && !f_pending &&
          obs_line_q[f_observation_tag] != f_released_line_q && !f_released_by_commit_q);
      cover (f_inval_admitted_q && o_replay_set_mask[f_observation_tag] && $past(
          f_pending && !obs_valid_q[f_observation_tag]
      ));
      cover (f_inval_admitted_q && o_replay_set_mask[f_observation_tag] && $past(!f_pending));
      cover (f_inval_admitted_q && o_replay_set_mask[f_observation_tag] && !f_observed_q);
      cover (f_inval_admitted_q && o_replay_set_mask[f_observation_tag] && $past(
          i_rst_n && f_pending && obs_valid_q[f_observation_tag] &&
          obs_pend_line_q != obs_line_q[f_observation_tag] &&
          obs_line_q[f_observation_tag] == inval_line_q
      ));
    end
  end
`endif


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
      assert (i_sc_head_query_match === (i_sc_head_addr_valid && (line_of(
          i_sc_head_addr
      ) == adm_req_line_q)))
      else $error("lq_coherence_port: preselected SC query comparison differs");
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
