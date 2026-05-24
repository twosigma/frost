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
 * OOO pipeline control.
 *
 * The OOO back-end stalls almost exclusively at dispatch, so this block
 * aggregates the front-end stall/serialization sources and the registered
 * trap/MRET recovery state into the pipeline_ctrl_t the IF/PD/ID stages
 * consume. It owns:
 *   - the in-flight bookkeeping counters (csr_in_flight, branch_in_flight,
 *     branch_unresolved, serializing_alloc_fire);
 *   - the CSR-serialization / control-flow-serialization front-end stalls and
 *     their registered replay pulses (stall_q / id_stall_q / replay_*);
 *   - the post-flush BRAM holdoff;
 *   - the registered trap/MRET pulse and trap target;
 *   - the prediction-disable gate and pipeline_ctrl assembly.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Pipeline Control" section logic, with the parent's signals presented
 * as ports and aliased back to their original names. cpu_ooo retains the global
 * signal declarations; only the logic moved here.
 */

module ooo_pipeline_control #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::reorder_buffer_alloc_req_t i_rob_alloc_req,
    input logic i_rob_checkpoint_valid,
    input logic i_csr_commit_fire,
    input logic i_correct_branch_commit_pending,
    input logic i_mispredict_recovery_pending,
    input riscv_pkg::mispredict_commit_capture_t i_mispredict_commit_q,
    input riscv_pkg::reorder_buffer_commit_t i_rob_commit,
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,
    input logic i_dispatch_stall,
    input logic i_csr_wb_pending,
    input logic i_branch_unresolved_decrement,
    input logic i_front_end_indirect_control_flow_pending,
    input logic i_pd_unpredicted_control_flow,
    input logic i_id_unpredicted_control_flow,
    input logic i_disable_branch_prediction,
    input logic i_flush_pipeline,

    output riscv_pkg::pipeline_ctrl_t o_pipeline_ctrl,
    output logic o_serializing_alloc_fire,
    output logic o_csr_in_flight,
    output logic [$clog2(riscv_pkg::ReorderBufferDepth+1)-1:0] o_branch_in_flight_count,
    output logic o_disable_branch_prediction_ooo,
    output logic o_front_end_cf_serialize_stall,
    output logic o_stall_q,
    output logic o_id_stall_q,
    output logic o_replay_after_dispatch_stall_q,
    output logic o_replay_after_serialize_stall_q,
    output logic [1:0] o_post_flush_holdoff_q,
    output logic o_trap_taken_reg,
    output logic o_mret_taken_reg,
    output logic [XLEN-1:0] o_trap_target_reg
);

  localparam int unsigned BranchInFlightCountWidth = $clog2(riscv_pkg::ReorderBufferDepth + 1);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req;
  logic rob_checkpoint_valid;
  logic csr_commit_fire;
  logic correct_branch_commit_pending;
  logic mispredict_recovery_pending;
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  riscv_pkg::reorder_buffer_commit_t rob_commit;
  logic trap_taken;
  logic mret_taken;
  logic [XLEN-1:0] trap_target;
  logic dispatch_stall;
  logic csr_wb_pending;
  logic branch_unresolved_decrement;
  logic front_end_indirect_control_flow_pending;
  logic pd_unpredicted_control_flow;
  logic id_unpredicted_control_flow;
  logic flush_pipeline;
  assign rob_alloc_req                           = i_rob_alloc_req;
  assign rob_checkpoint_valid                    = i_rob_checkpoint_valid;
  assign csr_commit_fire                         = i_csr_commit_fire;
  assign correct_branch_commit_pending           = i_correct_branch_commit_pending;
  assign mispredict_recovery_pending             = i_mispredict_recovery_pending;
  assign mispredict_commit_q                     = i_mispredict_commit_q;
  assign rob_commit                              = i_rob_commit;
  assign trap_taken                              = i_trap_taken;
  assign mret_taken                              = i_mret_taken;
  assign trap_target                             = i_trap_target;
  assign dispatch_stall                          = i_dispatch_stall;
  assign csr_wb_pending                          = i_csr_wb_pending;
  assign branch_unresolved_decrement             = i_branch_unresolved_decrement;
  assign front_end_indirect_control_flow_pending = i_front_end_indirect_control_flow_pending;
  assign pd_unpredicted_control_flow             = i_pd_unpredicted_control_flow;
  assign id_unpredicted_control_flow             = i_id_unpredicted_control_flow;
  assign flush_pipeline                          = i_flush_pipeline;

  // Signals produced here (also read internally); wired to o_* at the end.
  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  (* max_fanout = 32 *) logic frontend_stall;
  logic csr_in_flight;
  logic branch_in_flight;
  logic [BranchInFlightCountWidth-1:0] branch_in_flight_count;
  logic front_end_prediction_fence_pending;
  logic disable_branch_prediction_ooo;
  (* max_fanout = 32 *) logic serializing_alloc_fire;
  logic branch_alloc_fire;
  logic branch_commit_fire;

  // CSR results are only architecturally available at commit, so hold the
  // front-end after dispatching a CSR until it completes.  serializing_alloc_fire
  // is registered to break the dispatch->stall->IF->dispatch UNOPTFLAT loop.
  logic serializing_alloc_fire_comb;
  assign serializing_alloc_fire_comb = rob_alloc_req.alloc_valid && rob_alloc_req.is_csr;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) serializing_alloc_fire <= 1'b0;
    else serializing_alloc_fire <= serializing_alloc_fire_comb;
  end
  // Keep the in-flight counter aligned to the same predicate that allocates
  // speculative checkpoints so commit-time free/recovery bookkeeping balances.
  assign branch_alloc_fire = rob_checkpoint_valid;
  logic branch_unresolved_alloc_fire;
  assign branch_unresolved_alloc_fire =
      rob_alloc_req.alloc_valid && rob_alloc_req.is_branch && !rob_alloc_req.is_jal;
  assign branch_commit_fire = correct_branch_commit_pending ||
                             (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint);

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) csr_in_flight <= 1'b0;
    else if (csr_commit_fire) csr_in_flight <= 1'b0;
    else if (rob_alloc_req.alloc_valid && rob_alloc_req.is_csr) csr_in_flight <= 1'b1;
  end

  // The counter is balanced at commit time to keep the ROB / RS / LQ / SQ
  // resource accounting correct for back-to-back branches that slip through the
  // 1-cycle stall propagation window.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) begin
      branch_in_flight_count <= '0;
    end else begin
      case ({
        branch_alloc_fire, branch_commit_fire
      })
        2'b10: branch_in_flight_count <= branch_in_flight_count + 1'b1;
        2'b01:
        if (branch_in_flight_count != '0) branch_in_flight_count <= branch_in_flight_count - 1'b1;
        default: branch_in_flight_count <= branch_in_flight_count;
      endcase
    end
  end

  assign branch_in_flight = (branch_in_flight_count != '0);

  // Track the number of branches that have dispatched but not yet resolved.
  logic [BranchInFlightCountWidth-1:0] branch_unresolved_count;
  logic branch_unresolved;
  logic branch_unresolved_is_one;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) begin
      branch_unresolved_count  <= '0;
      branch_unresolved_is_one <= 1'b0;
    end else begin
      case ({
        branch_unresolved_alloc_fire, branch_unresolved_decrement
      })
        2'b10: begin
          branch_unresolved_count  <= branch_unresolved_count + 1'b1;
          branch_unresolved_is_one <= (branch_unresolved_count == '0);
        end
        2'b01: begin
          if (branch_unresolved_count != '0) begin
            branch_unresolved_count  <= branch_unresolved_count - 1'b1;
            branch_unresolved_is_one <= (branch_unresolved_count == BranchInFlightCountWidth'(2));
          end
        end
        default: begin
          branch_unresolved_count  <= branch_unresolved_count;
          branch_unresolved_is_one <= branch_unresolved_is_one;
        end
      endcase
    end
  end
  assign branch_unresolved = (branch_unresolved_count != '0);

  // Suppress new predictions once an unpredicted control-flow op has advanced
  // into PD/ID (see cpu_ooo history for the rationale on the disabled gate).
  assign front_end_prediction_fence_pending = pd_unpredicted_control_flow ||
                                              id_unpredicted_control_flow;
  assign disable_branch_prediction_ooo = i_disable_branch_prediction ||
                                         csr_in_flight ||
                                         serializing_alloc_fire;

  // If an older unresolved branch/jump is still in flight, the shared in-order
  // front-end cannot safely march a younger *unpredicted* indirect control-flow
  // instruction through IF/PD/ID.
  logic front_end_cf_serialize_stall_comb;
  logic front_end_cf_serialize_stall  /* verilator isolate_assignments */;
  assign front_end_cf_serialize_stall_comb =
      branch_unresolved && front_end_indirect_control_flow_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) front_end_cf_serialize_stall <= 1'b0;
    else front_end_cf_serialize_stall <= front_end_cf_serialize_stall_comb;
  end

  // Registered stall for IF stage stall-capture registers.
  logic stall_q;
  logic id_stall_q;
  logic replay_after_dispatch_stall_q;
  logic replay_after_serialize_stall_q;
  logic replay_after_serialize_stall_next;
  assign frontend_stall =
      (dispatch_stall || csr_in_flight || csr_wb_pending || serializing_alloc_fire ||
       front_end_cf_serialize_stall) && !flush_pipeline;
  always_ff @(posedge i_clk) begin
    if (i_rst) stall_q <= 1'b0;
    else stall_q <= frontend_stall;
  end

  // Keep dispatch-valid replay gating off the high-fanout IF stall-capture flop.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) id_stall_q <= 1'b0;
    else if (replay_after_serialize_stall_next) id_stall_q <= 1'b0;
    else id_stall_q <= frontend_stall;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_dispatch_stall_q <= 1'b0;
    else replay_after_dispatch_stall_q <= dispatch_stall && !flush_pipeline;
  end

  // CSR serialization release replay (see cpu_ooo history for mret-after-csrw).
  assign replay_after_serialize_stall_next =
      (csr_wb_pending || (csr_commit_fire && !rob_commit.dest_valid)) && !flush_pipeline;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_serialize_stall_q <= 1'b0;
    else replay_after_serialize_stall_q <= replay_after_serialize_stall_next;
  end

  // Post-flush holdoff: BRAM has 1-cycle read latency, so i_instr is stale for
  // one cycle after a flush/redirect.
  logic [1:0] post_flush_holdoff_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) post_flush_holdoff_q <= '0;
    else if (!pipeline_ctrl.stall)
      if (flush_pipeline) post_flush_holdoff_q <= 2'd1;
      else if (post_flush_holdoff_q != 2'd0) post_flush_holdoff_q <= post_flush_holdoff_q - 2'd1;
  end

  // Delay the IF/backend-visible trap/MRET recovery pulse by one cycle.
  logic trap_taken_reg, mret_taken_reg;
  logic [XLEN-1:0] trap_target_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      trap_taken_reg <= 1'b0;
      mret_taken_reg <= 1'b0;
    end else begin
      trap_taken_reg <= trap_taken;
      mret_taken_reg <= mret_taken;
    end
  end

  always_ff @(posedge i_clk) begin
    if (trap_taken || mret_taken) trap_target_reg <= trap_target;
  end

  always_comb begin
    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_rst;
    pipeline_ctrl.stall = frontend_stall;
    pipeline_ctrl.stall_registered = stall_q;
    pipeline_ctrl.stall_for_trap_check = dispatch_stall;
    pipeline_ctrl.flush = flush_pipeline;
    pipeline_ctrl.trap_taken_registered = trap_taken_reg;
    pipeline_ctrl.mret_taken_registered = mret_taken_reg;
  end

  // --- Output wiring.
  assign o_pipeline_ctrl                  = pipeline_ctrl;
  assign o_serializing_alloc_fire         = serializing_alloc_fire;
  assign o_csr_in_flight                  = csr_in_flight;
  assign o_branch_in_flight_count         = branch_in_flight_count;
  assign o_disable_branch_prediction_ooo  = disable_branch_prediction_ooo;
  assign o_front_end_cf_serialize_stall   = front_end_cf_serialize_stall;
  assign o_stall_q                        = stall_q;
  assign o_id_stall_q                     = id_stall_q;
  assign o_replay_after_dispatch_stall_q  = replay_after_dispatch_stall_q;
  assign o_replay_after_serialize_stall_q = replay_after_serialize_stall_q;
  assign o_post_flush_holdoff_q           = post_flush_holdoff_q;
  assign o_trap_taken_reg                 = trap_taken_reg;
  assign o_mret_taken_reg                 = mret_taken_reg;
  assign o_trap_target_reg                = trap_target_reg;

endmodule : ooo_pipeline_control
