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
 * Top-level performance-counter aggregator.
 *
 * Owns the 23 cpu_ooo top-level profiling counters (dispatch fire/stall,
 * front-end bubbles, flush recovery, serialization fences, per-resource
 * dispatch-stall reasons, ROB-empty, prediction fences, ...), accumulates them,
 * snapshots them on demand, and muxes the selected counter (top-level or
 * tomasulo_wrapper range) to the CSR read port. A registered selector and a
 * registered read result break the high-fanout selector -> counter -> CSR cone.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Profiling Counter Aggregation" section together with its parameter and
 * storage declarations, with the parent's signals presented as ports and
 * aliased back to their original names.
 */

module perf_counter_aggregator (
    input logic i_clk,
    input logic i_rst,

    // Event sources.
    input riscv_pkg::reorder_buffer_alloc_req_t       i_rob_alloc_req,
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

    // CSR / tomasulo_wrapper interface.
    input  logic [ 7:0] i_perf_counter_select,
    input  logic        i_perf_snapshot_capture,
    input  logic [63:0] i_wrapper_perf_counter_data,
    output logic [ 7:0] o_wrapper_perf_counter_select,
    output logic [63:0] o_perf_counter_data_q,
    output logic [31:0] o_perf_counter_count
);

  localparam int unsigned PerfTopCounterCount = 23;
  localparam int unsigned PerfWrapperCounterCount = 60;
  localparam int unsigned PerfWrapperBase = PerfTopCounterCount;
  localparam int unsigned PerfCounterCount = PerfTopCounterCount + PerfWrapperCounterCount;
  localparam logic [7:0] PerfTopCounterCountSel = 8'(PerfTopCounterCount);
  localparam logic [7:0] PerfWrapperBaseSel = 8'(PerfWrapperBase);
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
  localparam int unsigned PerfTopSnapshotBankSpan = (PerfTopCounterCount + 3) / 4;

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::reorder_buffer_alloc_req_t        rob_alloc_req;
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
  logic [7:0] perf_counter_select_q;  // registered copy — breaks fanout-513 cone
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank0;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank1;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank2;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank3;
  logic [63:0] perf_counter_data_comb;
  logic [63:0] perf_counter_data_q;
  logic [31:0] perf_counter_count;
  logic [7:0] wrapper_perf_counter_select;

  // Pipeline register for perf_counter_select to break the fanout-513 timing
  // cone (perf_counter_select_reg → comparison/index decode across two modules).
  // Adds 1-cycle read latency which is negligible for profiling counters.
  always_ff @(posedge i_clk) begin
    perf_counter_select_q <= perf_counter_select;
  end

  assign wrapper_perf_counter_select =
      ((perf_counter_select_q >= PerfWrapperBaseSel) &&
       (perf_counter_select_q < PerfCounterCountSel)) ?
      (perf_counter_select_q - PerfWrapperBaseSel) : 8'd0;
  assign perf_counter_count = PerfCounterCount;
  assign perf_top_snapshot_capture_bank0 = perf_snapshot_capture;
  assign perf_top_snapshot_capture_bank1 = perf_snapshot_capture;
  assign perf_top_snapshot_capture_bank2 = perf_snapshot_capture;
  assign perf_top_snapshot_capture_bank3 = perf_snapshot_capture;

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

  always_comb begin
    perf_counter_data_comb = '0;
    if (perf_counter_select_q < PerfTopCounterCountSel) begin
      perf_counter_data_comb = perf_top_snapshot[perf_counter_select_q[4:0]];
    end else if (perf_counter_select_q < PerfCounterCountSel) begin
      perf_counter_data_comb = wrapper_perf_counter_data;
    end
  end

  // Performance counters are debug-facing CSRs, so a second register stage is
  // acceptable here. It breaks the remaining selector -> perf-data -> CSR read
  // -> rename/dispatch fanout cone without affecting CoreMark/ISA execution.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_counter_data_q <= '0;
    end else begin
      perf_counter_data_q <= perf_counter_data_comb;
    end
  end

  // --- Output wiring.
  assign o_wrapper_perf_counter_select = wrapper_perf_counter_select;
  assign o_perf_counter_data_q         = perf_counter_data_q;
  assign o_perf_counter_count          = perf_counter_count;

endmodule : perf_counter_aggregator
