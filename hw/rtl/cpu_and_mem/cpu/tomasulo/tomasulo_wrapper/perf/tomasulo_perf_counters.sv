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
 * Tomasulo back-end performance counters.
 *
 * Owns the 60 back-end profiling counters: ROB head-wait / commit-blocked
 * buckets and their decompositions, per-FU back-pressure, memory disambiguation,
 * occupancy sums, L0$ hit/fill, and widen-commit opportunity/fire/blocker
 * breakdowns. Accumulates each event, snapshots all 60 on demand (4 fanout
 * banks), and muxes the selected counter to the CSR read port.
 *
 * Extracted verbatim from tomasulo_wrapper (no functional change): the body
 * below is the former "Backend Profiling Counters" section together with its
 * parameter and storage declarations, with the parent's event signals presented
 * as ports and aliased back to their original names.
 */

module tomasulo_perf_counters (
    input logic i_clk,
    input logic i_rst_n,

    // ROB-sourced event bundle.
    input riscv_pkg::rob_perf_events_t i_rob_perf_events,

    // Per-FU back-pressure / readiness.
    input logic i_int_rs_fu_ready,
    input logic i_o_rs_empty,
    input logic i_mul_rs_fu_ready,
    input logic i_o_mul_rs_empty,
    input riscv_pkg::fu_complete_t i_mem_fu_to_adapter,
    input logic i_mem_adapter_result_pending,
    input logic i_fp_rs_fu_ready,
    input logic i_o_fp_rs_empty,
    input logic i_fmul_rs_fu_ready,
    input logic i_o_fmul_rs_empty,
    input logic i_fdiv_rs_fu_ready,
    input logic i_o_fdiv_rs_empty,

    // Memory disambiguation / SQ-LQ status.
    input logic i_sq_check_valid,
    input logic i_sq_all_older_addrs_known,
    input logic i_sq_committed_empty,
    input logic i_o_sq_mem_write_en,
    input logic i_o_lq_mem_read_en,

    // Occupancy counts.
    input logic [  riscv_pkg::ReorderBufferTagWidth:0] i_o_rob_count,
    input logic [    $clog2(riscv_pkg::LqDepth+1)-1:0] i_o_lq_count,
    input logic [    $clog2(riscv_pkg::SqDepth+1)-1:0] i_o_sq_count,
    input logic [ $clog2(riscv_pkg::IntRsDepth+1)-1:0] i_o_rs_count,
    input logic [ $clog2(riscv_pkg::MulRsDepth+1)-1:0] i_o_mul_rs_count,
    input logic [ $clog2(riscv_pkg::MemRsDepth+1)-1:0] i_o_mem_rs_count,
    input logic [  $clog2(riscv_pkg::FpRsDepth+1)-1:0] i_o_fp_rs_count,
    input logic [$clog2(riscv_pkg::FmulRsDepth+1)-1:0] i_o_fmul_rs_count,
    input logic [$clog2(riscv_pkg::FdivRsDepth+1)-1:0] i_o_fdiv_rs_count,

    // L0$ + head-load disambiguation diagnostics.
    input logic i_lq_l0_hit,
    input logic i_lq_l0_fill,
    input logic i_lq_mem_outstanding,
    input logic i_lq_head_load_addr_pending,
    input logic i_lq_head_load_sq_disambig,
    input logic i_lq_head_load_bus_blocked,
    input logic i_lq_head_load_cdb_wait,
    input logic i_lq_head_load_post_lq,
    input logic i_lq_head_load_bb_issued,
    input logic i_lq_head_load_bb_bus_busy,
    input logic i_lq_head_load_bb_amo,
    input logic i_lq_head_load_bb_sq_wait,
    input logic i_lq_head_load_bb_staging,

    // head_wait_int decomposition status.
    input logic i_int_rs_head_in_rs,
    input logic i_int_rs_head_rs_ready,
    input logic i_int_rs_head_in_stage2,

    // CSR read port.
    input  logic        i_perf_snapshot_capture,
    input  logic [ 7:0] i_perf_counter_select,
    output logic [63:0] o_perf_counter_data
);

  // --- Port aliases: keep the extracted body identical to the tomasulo_wrapper original.
  riscv_pkg::rob_perf_events_t rob_perf_events;
  logic int_rs_fu_ready, o_rs_empty, mul_rs_fu_ready, o_mul_rs_empty;
  riscv_pkg::fu_complete_t mem_fu_to_adapter;
  logic mem_adapter_result_pending;
  logic fp_rs_fu_ready, o_fp_rs_empty, fmul_rs_fu_ready, o_fmul_rs_empty;
  logic fdiv_rs_fu_ready, o_fdiv_rs_empty;
  logic sq_check_valid, sq_all_older_addrs_known, sq_committed_empty;
  logic o_sq_mem_write_en, o_lq_mem_read_en;
  logic [riscv_pkg::ReorderBufferTagWidth:0] o_rob_count;
  logic [$clog2(riscv_pkg::LqDepth+1)-1:0] o_lq_count;
  logic [$clog2(riscv_pkg::SqDepth+1)-1:0] o_sq_count;
  logic [$clog2(riscv_pkg::IntRsDepth+1)-1:0] o_rs_count;
  logic [$clog2(riscv_pkg::MulRsDepth+1)-1:0] o_mul_rs_count;
  logic [$clog2(riscv_pkg::MemRsDepth+1)-1:0] o_mem_rs_count;
  logic [$clog2(riscv_pkg::FpRsDepth+1)-1:0] o_fp_rs_count;
  logic [$clog2(riscv_pkg::FmulRsDepth+1)-1:0] o_fmul_rs_count;
  logic [$clog2(riscv_pkg::FdivRsDepth+1)-1:0] o_fdiv_rs_count;
  logic lq_l0_hit, lq_l0_fill, lq_mem_outstanding;
  logic lq_head_load_addr_pending, lq_head_load_sq_disambig, lq_head_load_bus_blocked;
  logic lq_head_load_cdb_wait, lq_head_load_post_lq;
  logic lq_head_load_bb_issued, lq_head_load_bb_bus_busy, lq_head_load_bb_amo;
  logic lq_head_load_bb_sq_wait, lq_head_load_bb_staging;
  logic int_rs_head_in_rs, int_rs_head_rs_ready, int_rs_head_in_stage2;
  assign rob_perf_events            = i_rob_perf_events;
  assign int_rs_fu_ready            = i_int_rs_fu_ready;
  assign o_rs_empty                 = i_o_rs_empty;
  assign mul_rs_fu_ready            = i_mul_rs_fu_ready;
  assign o_mul_rs_empty             = i_o_mul_rs_empty;
  assign mem_fu_to_adapter          = i_mem_fu_to_adapter;
  assign mem_adapter_result_pending = i_mem_adapter_result_pending;
  assign fp_rs_fu_ready             = i_fp_rs_fu_ready;
  assign o_fp_rs_empty              = i_o_fp_rs_empty;
  assign fmul_rs_fu_ready           = i_fmul_rs_fu_ready;
  assign o_fmul_rs_empty            = i_o_fmul_rs_empty;
  assign fdiv_rs_fu_ready           = i_fdiv_rs_fu_ready;
  assign o_fdiv_rs_empty            = i_o_fdiv_rs_empty;
  assign sq_check_valid             = i_sq_check_valid;
  assign sq_all_older_addrs_known   = i_sq_all_older_addrs_known;
  assign sq_committed_empty         = i_sq_committed_empty;
  assign o_sq_mem_write_en          = i_o_sq_mem_write_en;
  assign o_lq_mem_read_en           = i_o_lq_mem_read_en;
  assign o_rob_count                = i_o_rob_count;
  assign o_lq_count                 = i_o_lq_count;
  assign o_sq_count                 = i_o_sq_count;
  assign o_rs_count                 = i_o_rs_count;
  assign o_mul_rs_count             = i_o_mul_rs_count;
  assign o_mem_rs_count             = i_o_mem_rs_count;
  assign o_fp_rs_count              = i_o_fp_rs_count;
  assign o_fmul_rs_count            = i_o_fmul_rs_count;
  assign o_fdiv_rs_count            = i_o_fdiv_rs_count;
  assign lq_l0_hit                  = i_lq_l0_hit;
  assign lq_l0_fill                 = i_lq_l0_fill;
  assign lq_mem_outstanding         = i_lq_mem_outstanding;
  assign lq_head_load_addr_pending  = i_lq_head_load_addr_pending;
  assign lq_head_load_sq_disambig   = i_lq_head_load_sq_disambig;
  assign lq_head_load_bus_blocked   = i_lq_head_load_bus_blocked;
  assign lq_head_load_cdb_wait      = i_lq_head_load_cdb_wait;
  assign lq_head_load_post_lq       = i_lq_head_load_post_lq;
  assign lq_head_load_bb_issued     = i_lq_head_load_bb_issued;
  assign lq_head_load_bb_bus_busy   = i_lq_head_load_bb_bus_busy;
  assign lq_head_load_bb_amo        = i_lq_head_load_bb_amo;
  assign lq_head_load_bb_sq_wait    = i_lq_head_load_bb_sq_wait;
  assign lq_head_load_bb_staging    = i_lq_head_load_bb_staging;
  assign int_rs_head_in_rs          = i_int_rs_head_in_rs;
  assign int_rs_head_rs_ready       = i_int_rs_head_rs_ready;
  assign int_rs_head_in_stage2      = i_int_rs_head_in_stage2;

  localparam int unsigned WrapperPerfCounterCount = 60;
  localparam int unsigned PerfHeadWaitTotal = 0;
  localparam int unsigned PerfHeadWaitInt = 1;
  localparam int unsigned PerfHeadWaitBranch = 2;
  localparam int unsigned PerfHeadWaitMul = 3;
  localparam int unsigned PerfHeadWaitMemLoad = 4;
  localparam int unsigned PerfHeadWaitMemStore = 5;
  localparam int unsigned PerfHeadWaitMemAmo = 6;
  localparam int unsigned PerfHeadWaitFp = 7;
  localparam int unsigned PerfHeadWaitFmul = 8;
  localparam int unsigned PerfHeadWaitFdiv = 9;
  localparam int unsigned PerfCommitBlockedCsr = 10;
  localparam int unsigned PerfCommitBlockedFence = 11;
  localparam int unsigned PerfCommitBlockedWfi = 12;
  localparam int unsigned PerfCommitBlockedMret = 13;
  localparam int unsigned PerfCommitBlockedTrap = 14;
  localparam int unsigned PerfIntBackpressure = 15;
  localparam int unsigned PerfMulBackpressure = 16;
  localparam int unsigned PerfMemResultBackpressure = 17;
  localparam int unsigned PerfFpAddBackpressure = 18;
  localparam int unsigned PerfFmulBackpressure = 19;
  localparam int unsigned PerfFdivBackpressure = 20;
  localparam int unsigned PerfMemDisambiguationWait = 21;
  localparam int unsigned PerfSqCommittedPending = 22;
  localparam int unsigned PerfSqMemWriteFire = 23;
  localparam int unsigned PerfLqMemReadFire = 24;
  localparam int unsigned PerfRobOccupancySum = 25;
  localparam int unsigned PerfLqOccupancySum = 26;
  localparam int unsigned PerfSqOccupancySum = 27;
  localparam int unsigned PerfIntRsOccupancySum = 28;
  localparam int unsigned PerfMulRsOccupancySum = 29;
  localparam int unsigned PerfMemRsOccupancySum = 30;
  localparam int unsigned PerfFpRsOccupancySum = 31;
  localparam int unsigned PerfFmulRsOccupancySum = 32;
  localparam int unsigned PerfFdivRsOccupancySum = 33;
  localparam int unsigned PerfLqL0Hit = 34;
  localparam int unsigned PerfLqL0Fill = 35;
  localparam int unsigned PerfHeadAndNextDone = 36;
  localparam int unsigned PerfHeadWaitLoadOutstanding = 37;
  localparam int unsigned PerfHeadWaitLoadNoOutstanding = 38;
  localparam int unsigned PerfHeadPlusOneDone = 39;
  localparam int unsigned PerfCommit2Opportunity = 40;
  localparam int unsigned PerfCommit2FireActual = 41;
  localparam int unsigned PerfHeadLoadAddrPending = 42;
  localparam int unsigned PerfHeadLoadSqDisambig = 43;
  localparam int unsigned PerfHeadLoadBusBlocked = 44;
  localparam int unsigned PerfHeadLoadCdbWait = 45;
  localparam int unsigned PerfHeadLoadPostLq = 46;
  localparam int unsigned PerfHeadLoadBbIssued = 47;
  localparam int unsigned PerfHeadLoadBbBusBusy = 48;
  localparam int unsigned PerfHeadLoadBbAmo = 49;
  localparam int unsigned PerfHeadLoadBbSqWait = 50;
  localparam int unsigned PerfHeadLoadBbStaging = 51;
  localparam int unsigned PerfHeadIntOperandWait = 52;
  localparam int unsigned PerfHeadIntRsReadyNotIssued = 53;
  localparam int unsigned PerfHeadIntStage2 = 54;
  localparam int unsigned PerfHeadIntPostRs = 55;
  localparam int unsigned PerfCommit2BlockedHeadSerial = 56;
  localparam int unsigned PerfCommit2BlockedNextSerial = 57;
  localparam int unsigned PerfCommit2BlockedNextBranchMispred = 58;
  localparam int unsigned PerfCommit2BlockedNextBranchCorrect = 59;

  logic [63:0] perf_live[WrapperPerfCounterCount];
  logic [63:0] perf_snapshot[WrapperPerfCounterCount];
  logic [63:0] perf_inc[WrapperPerfCounterCount];
  logic [63:0] perf_inc_q[WrapperPerfCounterCount];
  localparam int unsigned PerfSnapshotBankSpan = (WrapperPerfCounterCount + 3) / 4;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank0;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank1;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank2;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank3;
  assign perf_snapshot_capture_bank0 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank1 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank2 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank3 = i_perf_snapshot_capture;

  always_comb begin
    for (int i = 0; i < WrapperPerfCounterCount; i++) begin
      perf_inc[i] = '0;
    end

    perf_inc[PerfHeadWaitTotal] = {{63{1'b0}}, rob_perf_events.head_wait_total};
    perf_inc[PerfHeadWaitInt] = {{63{1'b0}}, rob_perf_events.head_wait_int};
    perf_inc[PerfHeadWaitBranch] = {{63{1'b0}}, rob_perf_events.head_wait_branch};
    perf_inc[PerfHeadWaitMul] = {{63{1'b0}}, rob_perf_events.head_wait_mul};
    perf_inc[PerfHeadWaitMemLoad] = {{63{1'b0}}, rob_perf_events.head_wait_mem_load};
    perf_inc[PerfHeadWaitMemStore] = {{63{1'b0}}, rob_perf_events.head_wait_mem_store};
    perf_inc[PerfHeadWaitMemAmo] = {{63{1'b0}}, rob_perf_events.head_wait_mem_amo};
    perf_inc[PerfHeadWaitFp] = {{63{1'b0}}, rob_perf_events.head_wait_fp};
    perf_inc[PerfHeadWaitFmul] = {{63{1'b0}}, rob_perf_events.head_wait_fmul};
    perf_inc[PerfHeadWaitFdiv] = {{63{1'b0}}, rob_perf_events.head_wait_fdiv};
    perf_inc[PerfCommitBlockedCsr] = {{63{1'b0}}, rob_perf_events.commit_blocked_csr};
    perf_inc[PerfCommitBlockedFence] = {{63{1'b0}}, rob_perf_events.commit_blocked_fence};
    perf_inc[PerfCommitBlockedWfi] = {{63{1'b0}}, rob_perf_events.commit_blocked_wfi};
    perf_inc[PerfCommitBlockedMret] = {{63{1'b0}}, rob_perf_events.commit_blocked_mret};
    perf_inc[PerfCommitBlockedTrap] = {{63{1'b0}}, rob_perf_events.commit_blocked_trap};

    perf_inc[PerfIntBackpressure] = {{63{1'b0}}, (!int_rs_fu_ready && !o_rs_empty)};
    perf_inc[PerfMulBackpressure] = {{63{1'b0}}, (!mul_rs_fu_ready && !o_mul_rs_empty)};
    perf_inc[PerfMemResultBackpressure] = {
      {63{1'b0}}, (mem_fu_to_adapter.valid && mem_adapter_result_pending)
    };
    perf_inc[PerfFpAddBackpressure] = {{63{1'b0}}, (!fp_rs_fu_ready && !o_fp_rs_empty)};
    perf_inc[PerfFmulBackpressure] = {{63{1'b0}}, (!fmul_rs_fu_ready && !o_fmul_rs_empty)};
    perf_inc[PerfFdivBackpressure] = {{63{1'b0}}, (!fdiv_rs_fu_ready && !o_fdiv_rs_empty)};
    perf_inc[PerfMemDisambiguationWait] = {
      {63{1'b0}}, (sq_check_valid && !sq_all_older_addrs_known)
    };
    perf_inc[PerfSqCommittedPending] = {{63{1'b0}}, !sq_committed_empty};
    perf_inc[PerfSqMemWriteFire] = {{63{1'b0}}, o_sq_mem_write_en};
    perf_inc[PerfLqMemReadFire] = {{63{1'b0}}, o_lq_mem_read_en};
    perf_inc[PerfRobOccupancySum] = {{(64 - $bits(o_rob_count)) {1'b0}}, o_rob_count};
    perf_inc[PerfLqOccupancySum] = {{(64 - $bits(o_lq_count)) {1'b0}}, o_lq_count};
    perf_inc[PerfSqOccupancySum] = {{(64 - $bits(o_sq_count)) {1'b0}}, o_sq_count};
    perf_inc[PerfIntRsOccupancySum] = {{(64 - $bits(o_rs_count)) {1'b0}}, o_rs_count};
    perf_inc[PerfMulRsOccupancySum] = {{(64 - $bits(o_mul_rs_count)) {1'b0}}, o_mul_rs_count};
    perf_inc[PerfMemRsOccupancySum] = {{(64 - $bits(o_mem_rs_count)) {1'b0}}, o_mem_rs_count};
    perf_inc[PerfFpRsOccupancySum] = {{(64 - $bits(o_fp_rs_count)) {1'b0}}, o_fp_rs_count};
    perf_inc[PerfFmulRsOccupancySum] = {{(64 - $bits(o_fmul_rs_count)) {1'b0}}, o_fmul_rs_count};
    perf_inc[PerfFdivRsOccupancySum] = {{(64 - $bits(o_fdiv_rs_count)) {1'b0}}, o_fdiv_rs_count};
    perf_inc[PerfLqL0Hit] = {{63{1'b0}}, lq_l0_hit};
    perf_inc[PerfLqL0Fill] = {{63{1'b0}}, lq_l0_fill};
    perf_inc[PerfHeadAndNextDone] = {{63{1'b0}}, rob_perf_events.head_and_next_done};
    perf_inc[PerfHeadWaitLoadOutstanding] = {
      {63{1'b0}}, (rob_perf_events.head_wait_mem_load && lq_mem_outstanding)
    };
    perf_inc[PerfHeadWaitLoadNoOutstanding] = {
      {63{1'b0}}, (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding)
    };
    perf_inc[PerfHeadPlusOneDone] = {{63{1'b0}}, rob_perf_events.head_plus_one_done};
    perf_inc[PerfCommit2Opportunity] = {{63{1'b0}}, rob_perf_events.commit_2_opportunity};
    perf_inc[PerfCommit2FireActual] = {{63{1'b0}}, rob_perf_events.commit_2_fire_actual};
    perf_inc[PerfHeadLoadAddrPending] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_addr_pending)
    };
    perf_inc[PerfHeadLoadSqDisambig] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_sq_disambig)
    };
    perf_inc[PerfHeadLoadBusBlocked] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bus_blocked)
    };
    perf_inc[PerfHeadLoadCdbWait] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_cdb_wait)
    };
    perf_inc[PerfHeadLoadPostLq] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_post_lq)
    };
    perf_inc[PerfHeadLoadBbIssued] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bb_issued)
    };
    perf_inc[PerfHeadLoadBbBusBusy] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bb_bus_busy)
    };
    perf_inc[PerfHeadLoadBbAmo] = {
      {63{1'b0}}, (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bb_amo)
    };
    perf_inc[PerfHeadLoadBbSqWait] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bb_sq_wait)
    };
    perf_inc[PerfHeadLoadBbStaging] = {
      {63{1'b0}},
      (rob_perf_events.head_wait_mem_load && !lq_mem_outstanding && lq_head_load_bb_staging)
    };
    perf_inc[PerfHeadIntOperandWait] = {
      {63{1'b0}}, (rob_perf_events.head_wait_int && int_rs_head_in_rs && !int_rs_head_rs_ready)
    };
    perf_inc[PerfHeadIntRsReadyNotIssued] = {
      {63{1'b0}}, (rob_perf_events.head_wait_int && int_rs_head_in_rs && int_rs_head_rs_ready)
    };
    perf_inc[PerfHeadIntStage2] = {
      {63{1'b0}}, (rob_perf_events.head_wait_int && !int_rs_head_in_rs && int_rs_head_in_stage2)
    };
    perf_inc[PerfHeadIntPostRs] = {
      {63{1'b0}}, (rob_perf_events.head_wait_int && !int_rs_head_in_rs && !int_rs_head_in_stage2)
    };
    perf_inc[PerfCommit2BlockedHeadSerial] = {
      {63{1'b0}}, rob_perf_events.commit_2_blocked_head_serial
    };
    perf_inc[PerfCommit2BlockedNextSerial] = {
      {63{1'b0}}, rob_perf_events.commit_2_blocked_next_serial
    };
    perf_inc[PerfCommit2BlockedNextBranchMispred] = {
      {63{1'b0}}, rob_perf_events.commit_2_blocked_next_branch_mispred
    };
    perf_inc[PerfCommit2BlockedNextBranchCorrect] = {
      {63{1'b0}}, rob_perf_events.commit_2_blocked_next_branch_correct
    };
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      for (int i = 0; i < WrapperPerfCounterCount; i++) begin
        perf_inc_q[i] <= '0;
        perf_live[i] <= '0;
        perf_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < WrapperPerfCounterCount; i++) begin
        perf_inc_q[i] <= perf_inc[i];
        perf_live[i]  <= perf_live[i] + perf_inc_q[i];
        if (i < PerfSnapshotBankSpan) begin
          if (perf_snapshot_capture_bank0) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (i < (2 * PerfSnapshotBankSpan)) begin
          if (perf_snapshot_capture_bank1) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (i < (3 * PerfSnapshotBankSpan)) begin
          if (perf_snapshot_capture_bank2) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (perf_snapshot_capture_bank3) begin
          perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
        end
      end
    end
  end

  always_comb begin
    o_perf_counter_data = '0;
    if (i_perf_counter_select < 8'(WrapperPerfCounterCount)) begin
      o_perf_counter_data = perf_snapshot[i_perf_counter_select[5:0]];
    end
  end

endmodule : tomasulo_perf_counters
