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
 * Top-level performance counters and the counter read mux.
 *
 * Holds the cpu_ooo top-level counters (dispatch, stall causes, front-end
 * bubbles, flush and serialization cycles, ROB-empty and no-retire cycles,
 * prediction fences, and the 2-wide width funnel) and the cache-hierarchy
 * counters, which follow the tomasulo_wrapper block in the global index space.
 * It counts and snapshots its two blocks and muxes all three onto the CSR read
 * port. The cache block also keeps its preceding snapshot, so software can
 * read both ends of a timed region afterward.
 *
 * Four registered copies of the capture trigger drive the snapshot registers,
 * so a snapshot lands one cycle after the trigger. The selector, the bank
 * choice, and the read result are registered to break the high-fanout path
 * from the selector through the counters to the CSR read. README.md in this
 * directory has the CSR protocol ("CSR interface") and the index layout
 * ("Numbering contract").
 */

module perf_counter_aggregator #(
    // Also register o_perf_counter_csr_half_q: the 32-bit half (mperfdata or
    // mperfdatah) named by i_rob_commit_comb's CSR address. This is correct
    // only where that raw address is registered on the same edge as the read
    // data, as in cpu_ooo; other users read o_perf_counter_data_q.
    parameter bit PreselectCsrHalf = 1'b0
) (
    input logic i_clk,
    input logic i_rst,

    // Event sources.
    input riscv_pkg::reorder_buffer_alloc_req_t       i_rob_alloc_req,
    // Slot-2 dispatch fire (flush-gated rob_alloc_req_2.alloc_valid).
    input logic                                       i_dispatch_fire_2,
    // IF→PD 2-wide delivery events (see if_width_events_t).
    input riscv_pkg::if_width_events_t                i_if_width_events,
    // MEM_RS issued while >=2 entries were ready (single issue port is the
    // limiter).  Registered inside the reservation station.
    input logic                                       i_mem_rs_two_ready_one_issued,
    // >=3 FU completions requested the 2-lane CDB.  Registered inside the
    // tomasulo_wrapper.
    input logic                                       i_cdb_oversubscribed,
    input riscv_pkg::dispatch_status_t                i_dispatch_status,
    input riscv_pkg::reorder_buffer_commit_t          i_rob_commit_comb,
    input logic                                       i_flush_pipeline,
    input logic                                 [1:0] i_post_flush_holdoff_q,
    input logic                                       i_csr_in_flight,
    input logic                                       i_csr_wb_pending,
    input logic                                       i_serializing_alloc_fire,
    input logic                                       i_front_end_cf_serialize_stall,
    input logic                                       i_rob_empty,
    input logic                                       i_disable_branch_prediction_ooo,
    input logic                                       i_disable_branch_prediction,
    input logic                                       i_prediction_fence_branch,
    input logic                                       i_prediction_fence_jal,
    input logic                                       i_prediction_fence_indirect,
    // Cache events are registered at their physical sources before crossing
    // the cache-hierarchy -> cpu_ooo boundary.
    input cache_perf_pkg::cache_perf_events_t         i_cache_perf_events,

    // CSR / tomasulo_wrapper interface.
    input  logic [ 7:0] i_perf_counter_select,
    input  logic        i_perf_snapshot_capture,
    input  logic        i_perf_cache_previous_select,
    input  logic [63:0] i_wrapper_perf_counter_data,
    output logic [ 7:0] o_wrapper_perf_counter_select,
    output logic [63:0] o_perf_counter_data_q,
    output logic [31:0] o_perf_counter_csr_half_q,
    output logic [31:0] o_perf_counter_count
);

  localparam int unsigned PerfTopCounterCount = 42;
  localparam int unsigned PerfWrapperCounterCount = 64;
  localparam int unsigned PerfCacheCounterCount = 24;
  localparam int unsigned PerfWrapperBase = PerfTopCounterCount;
  // The cache counters form a third block after the wrapper block, so the
  // wrapper base stays fixed. Global indices are a software interface
  // (README.md, "Numbering contract"): add counters without renumbering.
  localparam int unsigned PerfCacheBase = PerfTopCounterCount + PerfWrapperCounterCount;
  localparam int unsigned PerfCounterCount = PerfCacheBase + PerfCacheCounterCount;
  localparam logic [7:0] PerfTopCounterCountSel = 8'(PerfTopCounterCount);
  localparam logic [7:0] PerfWrapperBaseSel = 8'(PerfWrapperBase);
  localparam logic [7:0] PerfCacheBaseSel = 8'(PerfCacheBase);
  localparam logic [7:0] PerfCounterCountSel = 8'(PerfCounterCount);
  localparam int unsigned PerfDispatchFire = 0;
  localparam int unsigned PerfDispatchStall = 1;
  localparam int unsigned PerfFrontendBubble = 2;
  localparam int unsigned PerfFlushRecovery = 3;
  localparam int unsigned PerfPostFlushHoldoff = 4;
  localparam int unsigned PerfCsrSerialize = 5;
  localparam int unsigned PerfControlFlowSerialize = 6;
  localparam int unsigned PerfDispatchStallRobFull = 7;
  localparam int unsigned PerfDispatchStallIntRsFull = 8;
  localparam int unsigned PerfDispatchStallMulRsFull = 9;
  localparam int unsigned PerfDispatchStallMemRsFull = 10;
  localparam int unsigned PerfDispatchStallFpRsFull = 11;
  localparam int unsigned PerfDispatchStallFmulRsFull = 12;
  localparam int unsigned PerfDispatchStallFdivRsFull = 13;
  localparam int unsigned PerfDispatchStallLqFull = 14;
  localparam int unsigned PerfDispatchStallSqFull = 15;
  localparam int unsigned PerfDispatchStallCheckpointFull = 16;
  localparam int unsigned PerfNoRetireNotEmpty = 17;
  localparam int unsigned PerfRobEmpty = 18;
  localparam int unsigned PerfPredictionDisabled = 19;
  localparam int unsigned PerfPredictionFenceBranch = 20;
  localparam int unsigned PerfPredictionFenceJal = 21;
  localparam int unsigned PerfPredictionFenceIndirect = 22;
  // 2-wide width-funnel counters: IF→PD delivery width + slot-2 kill causes
  // + slot-2 BTB predicted-taken events.
  localparam int unsigned PerfIfDeliver1 = 23;
  localparam int unsigned PerfIfDeliver2 = 24;
  localparam int unsigned PerfIfSlot2KillS1NativeCtrl = 25;
  localparam int unsigned PerfIfSlot2KillS1NativeSerialize = 26;
  localparam int unsigned PerfIfSlot2KillSlot1Ctrl = 27;
  localparam int unsigned PerfIfSlot2KillClass = 28;
  localparam int unsigned PerfIfSlot2KillWindowLimit = 29;
  localparam int unsigned PerfIfSlot2KillTransient = 30;
  localparam int unsigned PerfIfSlot2PredTaken = 31;
  // 2-wide width-funnel counters: dispatch fire-2 + slot-2 blocked causes.
  localparam int unsigned PerfDispatchFire2 = 32;
  localparam int unsigned PerfDispatchSlot2Present = 33;
  localparam int unsigned PerfDispatchSlot2FpSerialized = 34;
  localparam int unsigned PerfDispatchSlot2BlockS1Branch = 35;
  localparam int unsigned PerfDispatchSlot2BlockRobFull2 = 36;
  localparam int unsigned PerfDispatchSlot2BlockRsFull2 = 37;
  localparam int unsigned PerfDispatchSlot2BlockLsqFull2 = 38;
  localparam int unsigned PerfDispatchSlot2BlockCkpt = 39;
  // 2-wide width-funnel counters: back-end single-resource limiters.
  localparam int unsigned PerfMemRsTwoReadyOneIssued = 40;
  localparam int unsigned PerfCdbOversubscribed = 41;
  localparam int unsigned PerfTopSnapshotBankSpan = (PerfTopCounterCount + 3) / 4;
  // Cache-block-local indices; global indices are PerfCacheBase + local.
  localparam int unsigned PerfCacheL1iAccess = 0;
  localparam int unsigned PerfCacheL1iHit = 1;
  localparam int unsigned PerfCacheL1iMiss = 2;
  localparam int unsigned PerfCacheL1iWriteback = 3;
  localparam int unsigned PerfCacheL1dAccess = 4;
  localparam int unsigned PerfCacheL1dHit = 5;
  localparam int unsigned PerfCacheL1dMiss = 6;
  localparam int unsigned PerfCacheL1dWriteback = 7;
  localparam int unsigned PerfCacheL2Access = 8;
  localparam int unsigned PerfCacheL2Hit = 9;
  localparam int unsigned PerfCacheL2Miss = 10;
  localparam int unsigned PerfCacheL2Writeback = 11;
  localparam int unsigned PerfCacheL1iFetchMissStall = 12;
  localparam int unsigned PerfCacheL1dMissCyclesSum = 13;
  localparam int unsigned PerfCacheL2MissCyclesSum = 14;
  // Non-blocking cache observers: hit-under-miss per level, the tag-stage
  // stall classes, and the L1D and L2 cycles with miss_outstanding >= 2.
  localparam int unsigned PerfCacheL1iHitUnderMiss = 15;
  localparam int unsigned PerfCacheL1dHitUnderMiss = 16;
  localparam int unsigned PerfCacheL2HitUnderMiss = 17;
  localparam int unsigned PerfCacheL1dSlotFullStall = 18;
  localparam int unsigned PerfCacheL2SlotFullStall = 19;
  localparam int unsigned PerfCacheL1dConflictStall = 20;
  localparam int unsigned PerfCacheL2ConflictStall = 21;
  localparam int unsigned PerfCacheL1dMissOverlapCycles = 22;
  localparam int unsigned PerfCacheL2MissOverlapCycles = 23;
  localparam int unsigned PerfCacheSnapshotBankSpan = (PerfCacheCounterCount + 3) / 4;
  localparam int unsigned PerfCacheSelBits = $clog2(PerfCacheCounterCount);

  // --- Port aliases.
  riscv_pkg::reorder_buffer_alloc_req_t        rob_alloc_req;
  logic                                        dispatch_fire_2;
  riscv_pkg::if_width_events_t                 if_width_events;
  logic                                        mem_rs_two_ready_one_issued;
  logic                                        cdb_oversubscribed;
  riscv_pkg::dispatch_status_t                 dispatch_status;
  riscv_pkg::reorder_buffer_commit_t           rob_commit_comb;
  logic                                        flush_pipeline;
  logic                                 [ 1:0] post_flush_holdoff_q;
  logic                                        csr_in_flight;
  logic                                        csr_wb_pending;
  logic                                        serializing_alloc_fire;
  logic                                        front_end_cf_serialize_stall;
  logic                                        rob_empty;
  logic                                        disable_branch_prediction_ooo;
  logic                                        prediction_fence_branch;
  logic                                        prediction_fence_jal;
  logic                                        prediction_fence_indirect;
  logic                                 [ 7:0] perf_counter_select;
  logic                                        perf_snapshot_capture;
  logic                                 [63:0] wrapper_perf_counter_data;
  assign rob_alloc_req                 = i_rob_alloc_req;
  assign dispatch_fire_2               = i_dispatch_fire_2;
  assign if_width_events               = i_if_width_events;
  assign mem_rs_two_ready_one_issued   = i_mem_rs_two_ready_one_issued;
  assign cdb_oversubscribed            = i_cdb_oversubscribed;
  assign dispatch_status               = i_dispatch_status;
  assign rob_commit_comb               = i_rob_commit_comb;
  assign flush_pipeline                = i_flush_pipeline;
  assign post_flush_holdoff_q          = i_post_flush_holdoff_q;
  assign csr_in_flight                 = i_csr_in_flight;
  assign csr_wb_pending                = i_csr_wb_pending;
  assign serializing_alloc_fire        = i_serializing_alloc_fire;
  assign front_end_cf_serialize_stall  = i_front_end_cf_serialize_stall;
  assign rob_empty                     = i_rob_empty;
  assign disable_branch_prediction_ooo = i_disable_branch_prediction_ooo;
  assign prediction_fence_branch       = i_prediction_fence_branch;
  assign prediction_fence_jal          = i_prediction_fence_jal;
  assign prediction_fence_indirect     = i_prediction_fence_indirect;
  assign perf_counter_select           = i_perf_counter_select;
  assign perf_snapshot_capture         = i_perf_snapshot_capture;
  assign wrapper_perf_counter_data     = i_wrapper_perf_counter_data;

  logic [63:0] perf_top_live[PerfTopCounterCount];
  logic [63:0] perf_top_snapshot[PerfTopCounterCount];
  logic [63:0] perf_top_inc[PerfTopCounterCount];
  logic [63:0] perf_top_inc_q[PerfTopCounterCount];
  logic [63:0] perf_cache_live[PerfCacheCounterCount];
  logic [63:0] perf_cache_snapshot[PerfCacheCounterCount];
  logic [63:0] perf_cache_previous_snapshot[PerfCacheCounterCount];
  logic [63:0] perf_cache_inc[PerfCacheCounterCount];
  logic [63:0] perf_cache_inc_q[PerfCacheCounterCount];
  logic [7:0] perf_counter_select_q;  // registered mperfsel, see below
  logic perf_cache_previous_select_q;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank0;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank1;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank2;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank3;
  logic [63:0] perf_counter_data_comb;
  logic [63:0] perf_counter_data_q;
  logic [31:0] perf_counter_count;
  logic [7:0] wrapper_perf_counter_select;
  logic [7:0] cache_perf_counter_select;

  // The selector is registered because the raw mperfsel value from csr_file
  // fans out to the block compares and index decode here and in
  // tomasulo_perf_counters. Software cannot see the extra cycle of read
  // latency (README.md, "CSR interface").
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_counter_select_q        <= '0;
      perf_cache_previous_select_q <= 1'b0;
    end else begin
      perf_counter_select_q        <= perf_counter_select;
      perf_cache_previous_select_q <= i_perf_cache_previous_select;
    end
  end

  assign wrapper_perf_counter_select =
      ((perf_counter_select_q >= PerfWrapperBaseSel) &&
       (perf_counter_select_q < PerfCacheBaseSel)) ?
      (perf_counter_select_q - PerfWrapperBaseSel) : 8'd0;
  assign cache_perf_counter_select =
      ((perf_counter_select_q >= PerfCacheBaseSel) &&
       (perf_counter_select_q < PerfCounterCountSel)) ?
      (perf_counter_select_q - PerfCacheBaseSel) : 8'd0;
  assign perf_counter_count = PerfCounterCount;
  // The capture trigger comes from the commit path and drives hundreds of
  // snapshot clock enables, so it is registered as four bank copies, as in
  // tomasulo_perf_counters. A snapshot therefore lands one cycle after the
  // triggering commit, which software cannot observe: CSR instructions
  // serialize and reads are deltas.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_top_snapshot_capture_bank0 <= 1'b0;
      perf_top_snapshot_capture_bank1 <= 1'b0;
      perf_top_snapshot_capture_bank2 <= 1'b0;
      perf_top_snapshot_capture_bank3 <= 1'b0;
    end else begin
      perf_top_snapshot_capture_bank0 <= perf_snapshot_capture;
      perf_top_snapshot_capture_bank1 <= perf_snapshot_capture;
      perf_top_snapshot_capture_bank2 <= perf_snapshot_capture;
      perf_top_snapshot_capture_bank3 <= perf_snapshot_capture;
    end
  end

  always_comb begin
    for (int i = 0; i < PerfTopCounterCount; i++) begin
      perf_top_inc[i] = '0;
    end

    perf_top_inc[PerfDispatchFire] = {{63{1'b0}}, rob_alloc_req.alloc_valid};
    perf_top_inc[PerfDispatchStall] = {{63{1'b0}}, dispatch_status.stall};
    perf_top_inc[PerfFrontendBubble] = {
      {63{1'b0}},
      (!i_rst && !flush_pipeline && (post_flush_holdoff_q == 2'd0) &&
       !dispatch_status.stall &&
       !(csr_in_flight || csr_wb_pending || serializing_alloc_fire) &&
       !front_end_cf_serialize_stall &&
       !dispatch_status.dispatch_valid)
    };
    perf_top_inc[PerfFlushRecovery] = {{63{1'b0}}, flush_pipeline};
    perf_top_inc[PerfPostFlushHoldoff] = {{63{1'b0}}, (post_flush_holdoff_q != 2'd0)};
    perf_top_inc[PerfCsrSerialize] = {
      {63{1'b0}}, (csr_in_flight || csr_wb_pending || serializing_alloc_fire)
    };
    perf_top_inc[PerfControlFlowSerialize] = {{63{1'b0}}, front_end_cf_serialize_stall};
    perf_top_inc[PerfDispatchStallRobFull] = {{63{1'b0}}, dispatch_status.reorder_buffer_full};
    perf_top_inc[PerfDispatchStallIntRsFull] = {{63{1'b0}}, dispatch_status.int_rs_full};
    perf_top_inc[PerfDispatchStallMulRsFull] = {{63{1'b0}}, dispatch_status.mul_rs_full};
    perf_top_inc[PerfDispatchStallMemRsFull] = {{63{1'b0}}, dispatch_status.mem_rs_full};
    perf_top_inc[PerfDispatchStallFpRsFull] = {{63{1'b0}}, dispatch_status.fp_rs_full};
    perf_top_inc[PerfDispatchStallFmulRsFull] = {{63{1'b0}}, dispatch_status.fmul_rs_full};
    perf_top_inc[PerfDispatchStallFdivRsFull] = {{63{1'b0}}, dispatch_status.fdiv_rs_full};
    perf_top_inc[PerfDispatchStallLqFull] = {{63{1'b0}}, dispatch_status.lq_full};
    perf_top_inc[PerfDispatchStallSqFull] = {{63{1'b0}}, dispatch_status.sq_full};
    perf_top_inc[PerfDispatchStallCheckpointFull] = {{63{1'b0}}, dispatch_status.checkpoint_full};
    perf_top_inc[PerfNoRetireNotEmpty] = {
      {63{1'b0}}, (!rob_commit_comb.valid && !rob_empty && !flush_pipeline)
    };
    perf_top_inc[PerfRobEmpty] = {{63{1'b0}}, (rob_empty && !flush_pipeline)};
    perf_top_inc[PerfPredictionDisabled] = {
      {63{1'b0}}, (disable_branch_prediction_ooo && !i_disable_branch_prediction)
    };
    perf_top_inc[PerfPredictionFenceBranch] = {{63{1'b0}}, prediction_fence_branch};
    perf_top_inc[PerfPredictionFenceJal] = {{63{1'b0}}, prediction_fence_jal};
    perf_top_inc[PerfPredictionFenceIndirect] = {{63{1'b0}}, prediction_fence_indirect};
    perf_top_inc[PerfIfDeliver1] = {{63{1'b0}}, if_width_events.deliver1};
    perf_top_inc[PerfIfDeliver2] = {{63{1'b0}}, if_width_events.deliver2};
    perf_top_inc[PerfIfSlot2KillS1NativeCtrl] = {{63{1'b0}}, if_width_events.kill_s1_native_ctrl};
    perf_top_inc[PerfIfSlot2KillS1NativeSerialize] = {
      {63{1'b0}}, if_width_events.kill_s1_native_serialize
    };
    perf_top_inc[PerfIfSlot2KillSlot1Ctrl] = {{63{1'b0}}, if_width_events.kill_slot1_ctrl};
    perf_top_inc[PerfIfSlot2KillClass] = {{63{1'b0}}, if_width_events.kill_class};
    perf_top_inc[PerfIfSlot2KillWindowLimit] = {{63{1'b0}}, if_width_events.kill_window_limit};
    perf_top_inc[PerfIfSlot2KillTransient] = {{63{1'b0}}, if_width_events.kill_transient};
    perf_top_inc[PerfIfSlot2PredTaken] = {{63{1'b0}}, if_width_events.slot2_pred_taken};
    perf_top_inc[PerfDispatchFire2] = {{63{1'b0}}, dispatch_fire_2};
    perf_top_inc[PerfDispatchSlot2Present] = {{63{1'b0}}, dispatch_status.slot2_present};
    perf_top_inc[PerfDispatchSlot2FpSerialized] = {{63{1'b0}}, dispatch_status.slot2_fp_serialized};
    perf_top_inc[PerfDispatchSlot2BlockS1Branch] = {
      {63{1'b0}}, dispatch_status.slot2_block_s1_branch
    };
    perf_top_inc[PerfDispatchSlot2BlockRobFull2] = {
      {63{1'b0}}, dispatch_status.slot2_block_rob_full2
    };
    perf_top_inc[PerfDispatchSlot2BlockRsFull2] = {
      {63{1'b0}}, dispatch_status.slot2_block_rs_full2
    };
    perf_top_inc[PerfDispatchSlot2BlockLsqFull2] = {
      {63{1'b0}}, dispatch_status.slot2_block_lsq_full2
    };
    perf_top_inc[PerfDispatchSlot2BlockCkpt] = {{63{1'b0}}, dispatch_status.slot2_block_ckpt};
    perf_top_inc[PerfMemRsTwoReadyOneIssued] = {{63{1'b0}}, mem_rs_two_ready_one_issued};
    perf_top_inc[PerfCdbOversubscribed] = {{63{1'b0}}, cdb_oversubscribed};
  end

  always_comb begin
    for (int i = 0; i < PerfCacheCounterCount; i++) begin
      perf_cache_inc[i] = '0;
    end

    perf_cache_inc[PerfCacheL1iAccess] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1i.access};
    perf_cache_inc[PerfCacheL1iHit] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1i.hit};
    perf_cache_inc[PerfCacheL1iMiss] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1i.miss};
    perf_cache_inc[PerfCacheL1iWriteback] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1i.writeback
    };
    perf_cache_inc[PerfCacheL1dAccess] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1d.access};
    perf_cache_inc[PerfCacheL1dHit] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1d.hit};
    perf_cache_inc[PerfCacheL1dMiss] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l1d.miss};
    perf_cache_inc[PerfCacheL1dWriteback] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1d.writeback
    };
    perf_cache_inc[PerfCacheL2Access] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l2.access};
    perf_cache_inc[PerfCacheL2Hit] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l2.hit};
    perf_cache_inc[PerfCacheL2Miss] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l2.miss};
    perf_cache_inc[PerfCacheL2Writeback] = {{63{1'b0}}, i_cache_perf_events.hierarchy.l2.writeback};
    perf_cache_inc[PerfCacheL1iFetchMissStall] = {
      {63{1'b0}}, i_cache_perf_events.l1i_fetch_miss_stall
    };
    // miss_outstanding is the number of miss-status slots in use, not counting
    // maintenance (cache_perf_pkg::MissOutstandingBits wide), so the sums
    // integrate slot occupancy over time.
    perf_cache_inc[PerfCacheL1dMissCyclesSum] =
        64'(i_cache_perf_events.hierarchy.l1d.miss_outstanding);
    perf_cache_inc[PerfCacheL2MissCyclesSum] =
        64'(i_cache_perf_events.hierarchy.l2.miss_outstanding);
    perf_cache_inc[PerfCacheL1iHitUnderMiss] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1i.hit_under_miss
    };
    perf_cache_inc[PerfCacheL1dHitUnderMiss] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1d.hit_under_miss
    };
    perf_cache_inc[PerfCacheL2HitUnderMiss] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l2.hit_under_miss
    };
    perf_cache_inc[PerfCacheL1dSlotFullStall] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1d.slot_full_stall
    };
    perf_cache_inc[PerfCacheL2SlotFullStall] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l2.slot_full_stall
    };
    perf_cache_inc[PerfCacheL1dConflictStall] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l1d.conflict_stall
    };
    perf_cache_inc[PerfCacheL2ConflictStall] = {
      {63{1'b0}}, i_cache_perf_events.hierarchy.l2.conflict_stall
    };
    perf_cache_inc[PerfCacheL1dMissOverlapCycles] = {
      {63{1'b0}}, (i_cache_perf_events.hierarchy.l1d.miss_outstanding >= 4'd2)
    };
    perf_cache_inc[PerfCacheL2MissOverlapCycles] = {
      {63{1'b0}}, (i_cache_perf_events.hierarchy.l2.miss_outstanding >= 4'd2)
    };
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < PerfTopCounterCount; i++) begin
        perf_top_inc_q[i] <= '0;
        perf_top_live[i] <= '0;
        perf_top_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < PerfTopCounterCount; i++) begin
        perf_top_inc_q[i] <= perf_top_inc[i];
        perf_top_live[i]  <= perf_top_live[i] + perf_top_inc_q[i];
        if (i < PerfTopSnapshotBankSpan) begin
          if (perf_top_snapshot_capture_bank0) begin
            perf_top_snapshot[i] <= perf_top_live[i] + perf_top_inc_q[i];
          end
        end else if (i < (2 * PerfTopSnapshotBankSpan)) begin
          if (perf_top_snapshot_capture_bank1) begin
            perf_top_snapshot[i] <= perf_top_live[i] + perf_top_inc_q[i];
          end
        end else if (i < (3 * PerfTopSnapshotBankSpan)) begin
          if (perf_top_snapshot_capture_bank2) begin
            perf_top_snapshot[i] <= perf_top_live[i] + perf_top_inc_q[i];
          end
        end else if (perf_top_snapshot_capture_bank3) begin
          perf_top_snapshot[i] <= perf_top_live[i] + perf_top_inc_q[i];
        end
      end
    end
  end

  // The cache block uses the top block's four capture strobes, so its
  // counters are captured with the top-level ones without another high-fanout
  // copy of the trigger. The preceding snapshot lets software defer the
  // cache-counter reads until after a timed region and still read both ends.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < PerfCacheCounterCount; i++) begin
        perf_cache_inc_q[i] <= '0;
        perf_cache_live[i] <= '0;
        perf_cache_snapshot[i] <= '0;
        perf_cache_previous_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < PerfCacheCounterCount; i++) begin
        perf_cache_inc_q[i] <= perf_cache_inc[i];
        perf_cache_live[i]  <= perf_cache_live[i] + perf_cache_inc_q[i];
        if (i < PerfCacheSnapshotBankSpan) begin
          if (perf_top_snapshot_capture_bank0) begin
            perf_cache_previous_snapshot[i] <= perf_cache_snapshot[i];
            perf_cache_snapshot[i] <= perf_cache_live[i] + perf_cache_inc_q[i];
          end
        end else if (i < (2 * PerfCacheSnapshotBankSpan)) begin
          if (perf_top_snapshot_capture_bank1) begin
            perf_cache_previous_snapshot[i] <= perf_cache_snapshot[i];
            perf_cache_snapshot[i] <= perf_cache_live[i] + perf_cache_inc_q[i];
          end
        end else if (i < (3 * PerfCacheSnapshotBankSpan)) begin
          if (perf_top_snapshot_capture_bank2) begin
            perf_cache_previous_snapshot[i] <= perf_cache_snapshot[i];
            perf_cache_snapshot[i] <= perf_cache_live[i] + perf_cache_inc_q[i];
          end
        end else if (perf_top_snapshot_capture_bank3) begin
          perf_cache_previous_snapshot[i] <= perf_cache_snapshot[i];
          perf_cache_snapshot[i] <= perf_cache_live[i] + perf_cache_inc_q[i];
        end
      end
    end
  end

  always_comb begin
    perf_counter_data_comb = '0;
    if (perf_counter_select_q < PerfTopCounterCountSel) begin
      perf_counter_data_comb = perf_top_snapshot[perf_counter_select_q[5:0]];
    end else if (perf_counter_select_q < PerfCacheBaseSel) begin
      perf_counter_data_comb = wrapper_perf_counter_data;
    end else if (perf_counter_select_q < PerfCounterCountSel) begin
      perf_counter_data_comb =
          perf_cache_previous_select_q ?
          perf_cache_previous_snapshot[cache_perf_counter_select[PerfCacheSelBits-1:0]] :
          perf_cache_snapshot[cache_perf_counter_select[PerfCacheSelBits-1:0]];
    end
  end

  // A second register stage, acceptable for debug-facing CSRs. It breaks the
  // remaining path from the selector through the counter data and the CSR
  // read into rename and dispatch.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_counter_data_q <= '0;
    end else begin
      perf_counter_data_q <= perf_counter_data_comb;
    end
  end

  // cpu_ooo's commit bus registers this raw CSR address on the same edge as
  // perf_counter_data_q, so the half can be selected here, before that
  // register. csr_file still applies its current-cycle read and flush
  // qualification and its own output register, so neither the snapshot
  // sampled nor the CSR read latency changes.
  if (PreselectCsrHalf) begin : gen_csr_half
    always_ff @(posedge i_clk) begin
      if (i_rst) o_perf_counter_csr_half_q <= '0;
      else begin
        o_perf_counter_csr_half_q <=
            (i_rob_commit_comb.csr_addr == riscv_pkg::CsrMperfDataH) ?
            perf_counter_data_comb[63:32] : perf_counter_data_comb[31:0];
      end
    end
  end else begin : gen_no_csr_half
    assign o_perf_counter_csr_half_q = '0;
  end

  // --- Output wiring.
  assign o_wrapper_perf_counter_select = wrapper_perf_counter_select;
  assign o_perf_counter_data_q         = perf_counter_data_q;
  assign o_perf_counter_count          = perf_counter_count;

endmodule : perf_counter_aggregator
