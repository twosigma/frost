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
 * FROST OOO CPU Core - Tomasulo Out-of-Order RISC-V Processor (RV32IMACBFD)
 *
 * Replaces the in-order EX/MA/WB stages with Tomasulo-based out-of-order
 * execution. Preserves the existing IF/PD/ID front-end.
 *
 * Pipeline structure:
 *   IF → PD → ID → DISPATCH → [OOO execution via Tomasulo] → COMMIT
 *
 * Key changes from in-order cpu.sv:
 *   - REMOVED: EX/MA/WB stages, forwarding_unit, fp_forwarding_unit,
 *              hazard_resolution_unit (in-order versions)
 *   - ADDED: dispatch module, tomasulo_wrapper (ROB+RAT+RS+CDB+LQ+SQ+FU shims)
 *   - CHANGED: Regfile writes come from ROB commit, not WB stage
 *   - CHANGED: CSR writes happen at ROB commit (serialized)
 *   - CHANGED: Branch/BTB/RAS updates come from ROB commit, not EX stage
 *   - CHANGED: Pipeline stalls come from dispatch back-pressure
 */

module cpu_ooo #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    input logic i_rst,
    // Instruction memory interface
    output logic [XLEN-1:0] o_pc,
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    input logic [3:0] i_instr_sideband,  // Predecode: {next_sb[1:0], current_sb[1:0]}
    input logic i_instr_bank_sel_r,  // Fetch-word parity (for spanning select)
    // Data memory interface
    input logic [XLEN-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    output logic o_data_mem_read_enable,
    output logic o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic o_mmio_load_valid,
    // Status
    output logic o_rst_done,
    output logic o_vld,
    output logic o_pc_vld,
    // Interrupts
    input riscv_pkg::interrupt_t i_interrupts,
    input logic [63:0] i_mtime,
    // Debug
    input logic i_disable_branch_prediction
);

  // Active-low reset for Tomasulo modules
  logic rst_n;
  assign rst_n = ~i_rst;

  // ===========================================================================
  // Pipeline Control
  // ===========================================================================
  // Simplified pipeline control for OOO: only stall/flush from dispatch
  // and commit-time events (traps, mispredictions).

  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  logic dispatch_stall;
  (* max_fanout = 32 *) logic flush_pipeline;
  (* max_fanout = 32 *) logic frontend_stall;
  logic flush_for_trap;
  logic flush_for_mret;
  riscv_pkg::dispatch_status_t dispatch_status;

  localparam int unsigned PerfTopCounterCount = 23;
  localparam int unsigned PerfWrapperCounterCount = 34;
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

  logic [63:0] perf_top_live[PerfTopCounterCount];
  logic [63:0] perf_top_snapshot[PerfTopCounterCount];
  logic [63:0] perf_top_inc[PerfTopCounterCount];
  logic [63:0] perf_top_inc_q[PerfTopCounterCount];
  logic [7:0] perf_counter_select;
  logic [7:0] perf_counter_select_q;  // registered copy — breaks fanout-513 cone
  logic perf_snapshot_capture;
  localparam int unsigned PerfTopSnapshotBankSpan = (PerfTopCounterCount + 3) / 4;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank0;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank1;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank2;
  (* max_fanout = 512 *) logic perf_top_snapshot_capture_bank3;
  logic [63:0] perf_counter_data;
  logic [31:0] perf_counter_count;
  logic [7:0] wrapper_perf_counter_select;
  logic [63:0] wrapper_perf_counter_data;

  // CSR dispatch fence: the CDB carries rs1 (write operand) for CSR ops,
  // not the CSR read result (which is only available at commit). Stall
  // dispatch after a CSR until it commits so no dependent instruction
  // picks up the wrong CDB value.
  logic csr_in_flight;
  logic branch_in_flight;
  localparam int unsigned BranchInFlightCountWidth = $clog2(riscv_pkg::ReorderBufferDepth + 1);
  logic [BranchInFlightCountWidth-1:0] branch_in_flight_count;
  logic front_end_control_flow_pending;
  logic front_end_indirect_control_flow_pending;
  logic if_unpredicted_control_flow;
  logic if_unpredicted_indirect_control_flow;
  logic pd_unpredicted_control_flow;
  logic pd_unpredicted_indirect_control_flow;
  logic pd_unpredicted_branch;
  logic pd_unpredicted_jal;
  logic id_unpredicted_control_flow;
  logic id_unpredicted_indirect_control_flow;
  logic id_unpredicted_branch;
  logic id_unpredicted_jal;
  logic front_end_prediction_fence_pending;
  logic prediction_fence_branch;
  logic prediction_fence_jal;
  logic prediction_fence_indirect;
  logic disable_branch_prediction_ooo;
  (* max_fanout = 32 *) logic serializing_alloc_fire;
  logic csr_commit_fire;  // forward declaration; driven below in CSR section
  logic branch_alloc_fire;
  logic branch_commit_fire;
  logic branch_resolved_correct;  // branch resolved correctly at execute time
  logic branch_unresolved_decrement;  // resolve event for unresolved counter

  // CSR results are only architecturally available at commit, so hold the
  // front-end after dispatching a CSR until it completes.
  //
  // Register serializing_alloc_fire to break the UNOPTFLAT combinational
  // loop: dispatch_fire → serializing_alloc_fire → pipeline_ctrl.stall →
  // IF stage → dispatch_fire.  The 1-cycle delay is safe because
  // csr_in_flight (also registered) provides the long-duration stall;
  // serializing_alloc_fire_q covers the same cycle once csr_in_flight
  // rises.
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

  // The counter is balanced at commit time (same as original) to keep the
  // ROB / RS / LQ / SQ resource accounting correct for back-to-back branches
  // that slip through the 1-cycle stall propagation window.
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
  // Incremented at dispatch (branch_alloc_fire), decremented at execute
  // (branch_unresolved_decrement), reset on flush.  This counter is separate
  // from branch_in_flight_count (which balances at commit) and is used
  // solely for the prediction-disable and front-end-stall signals.
  // When all dispatched branches have resolved, prediction can safely
  // re-enable even though the branches haven't committed yet.
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

  // The existing in-order front-end prediction machinery is not robust to a
  // younger predicted redirect arriving behind an older unresolved branch/jump.
  // Suppress new predictions once an unpredicted control-flow op has advanced
  // into PD/ID. Do not let an IF-stage branch self-lock prediction off
  // forever: in hot loops that creates a circular dependency where the current
  // branch is always "unpredicted" only because prediction is already
  // disabled.
  assign front_end_prediction_fence_pending = pd_unpredicted_control_flow ||
                                              id_unpredicted_control_flow;
  // The prediction fence (front_end_prediction_fence_pending) is removed from
  // this gate.  Disabling prediction while an unpredicted branch/JAL sits in
  // PD/ID serialized the front-end on every cold-BTB branch, wasting ~20% of
  // cycles.  The OOO checkpoint system already handles recovery from wrong-
  // path speculation past unpredicted branches; checkpoint_full is < 0.1%.
  // The separate front_end_cf_serialize_stall still protects against the
  // dangerous case of speculating past unpredicted indirect jumps (JALR).
  assign disable_branch_prediction_ooo = i_disable_branch_prediction ||
                                         csr_in_flight ||
                                         serializing_alloc_fire;

  // If an older unresolved branch/jump is still in flight, the shared
  // in-order front-end cannot safely march a younger *unpredicted*
  // indirect control-flow instruction through IF/PD/ID. Direct branches/JALs
  // already have enough predictor metadata to keep the front-end moving; the
  // riskier case is an unresolved older branch plus a younger unpredicted
  // indirect redirect (JALR/return).
  logic front_end_cf_serialize_stall_comb;
  logic front_end_cf_serialize_stall  /* verilator isolate_assignments */;
  assign front_end_cf_serialize_stall_comb =
      branch_unresolved && front_end_indirect_control_flow_pending;

  // This stall is a front-end serialization fence, not an architectural
  // requirement. Register it so the branch_in_flight + IF/PD/ID control-flow
  // decode cone does not sit directly on the main pipeline stall path.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) front_end_cf_serialize_stall <= 1'b0;
    else front_end_cf_serialize_stall <= front_end_cf_serialize_stall_comb;
  end

  // Registered stall for IF stage stall-capture registers.
  // The IF stage saves combinational outputs (BRAM data, is_compressed, etc.)
  // on the rising edge of stall and restores them via stall_registered.
  logic stall_q;
  logic replay_after_dispatch_stall_q;
  logic replay_after_serialize_stall_q;
  assign frontend_stall =
      (dispatch_stall || csr_in_flight || serializing_alloc_fire ||
       front_end_cf_serialize_stall) && !flush_pipeline;
  always_ff @(posedge i_clk) begin
    if (i_rst) stall_q <= 1'b0;
    else stall_q <= frontend_stall;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_dispatch_stall_q <= 1'b0;
    else replay_after_dispatch_stall_q <= dispatch_stall && !flush_pipeline;
  end

  // CSR serialization stalls are asserted a cycle after the serializing CSR
  // allocates, so the ID register already contains the younger blocked
  // instruction on the first stalled cycle. Give that held image one replay
  // cycle after the fence drops; otherwise instructions like `mret` following
  // `csrw mepc, ...` are stranded in ID and overwritten by younger fetch.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_serialize_stall_q <= 1'b0;
    else
      replay_after_serialize_stall_q <=
        (csr_in_flight || serializing_alloc_fire) && !flush_pipeline;
  end

  // Post-flush holdoff: BRAM has 1-cycle read latency, so i_instr is stale
  // for one cycle after a flush/redirect. Suppress the valid tracker during
  // this cycle to prevent stale instructions from being dispatched.
  logic [1:0] post_flush_holdoff_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) post_flush_holdoff_q <= '0;
    else if (!pipeline_ctrl.stall)
      if (flush_pipeline)
        // One cycle is sufficient here: PD/ID are explicitly flushed in the
        // redirect cycle, and the next cycle is the only stale BRAM return.
        // Holding longer drops real target instructions after control-flow
        // redirects, especially at compressed function entries.
        post_flush_holdoff_q <= 2'd1;
      else if (post_flush_holdoff_q != 2'd0) post_flush_holdoff_q <= post_flush_holdoff_q - 2'd1;
  end

  // Delay the IF/backend-visible trap/MRET recovery pulse by one cycle. PD/ID
  // still flush immediately, but IF and Tomasulo pay an extra recovery bubble
  // to break the long ROB/trap -> redirect/backend-flush cones.
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

  // Front-end stall: dispatch back-pressure or CSR serialization
  // Front-end flush: misprediction or trap at commit
  always_comb begin
    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_rst;
    pipeline_ctrl.stall = frontend_stall;
    pipeline_ctrl.stall_registered = stall_q;
    // Only true execution/backpressure stalls belong in stall_for_trap_check.
    // Front-end CSR serialization fences must not suppress IF-stage
    // control-flow cleanup on redirects, or stale C-extension state can
    // survive a branch/return flush.
    pipeline_ctrl.stall_for_trap_check = dispatch_stall;
    pipeline_ctrl.flush = flush_pipeline;
    pipeline_ctrl.trap_taken_registered = trap_taken_reg;
    pipeline_ctrl.mret_taken_registered = mret_taken_reg;
  end

  // ===========================================================================
  // Inter-stage signals
  // ===========================================================================
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_pd_to_id_t from_pd_to_id;
  logic pd_redirect;
  logic [XLEN-1:0] pd_redirect_target;
  riscv_pkg::from_id_to_ex_t from_id_to_ex;

  // Temporary debug mirrors for cocotb control-flow tracing.
  logic dbg_if_ras_predicted  /* verilator public_flat_rd */;
  logic dbg_pd_ras_predicted  /* verilator public_flat_rd */;
  logic dbg_id_ras_predicted  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits-1:0] dbg_if_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_if_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits-1:0] dbg_pd_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_pd_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits-1:0] dbg_id_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_id_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic dbg_commit_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_pc  /* verilator public_flat_rd */;
  logic dbg_commit_is_return  /* verilator public_flat_rd */;
  logic dbg_commit_is_call  /* verilator public_flat_rd */;
  logic [riscv_pkg::CheckpointIdWidth-1:0] dbg_commit_checkpoint_id  /* verilator public_flat_rd */;
  logic dbg_commit_has_checkpoint  /* verilator public_flat_rd */;
  logic dbg_commit_predicted_taken  /* verilator public_flat_rd */;
  logic dbg_commit_branch_taken  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_pd_pc  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_pd_instr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_id_pc  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_id_instr  /* verilator public_flat_rd */;
  logic dbg_id_is_mret  /* verilator public_flat_rd */;
  logic dbg_if_valid_q  /* verilator public_flat_rd */;
  logic dbg_pd_valid_q  /* verilator public_flat_rd */;
  logic dbg_id_valid  /* verilator public_flat_rd */;
  logic [1:0] dbg_post_flush_holdoff_q  /* verilator public_flat_rd */;
  logic dbg_csr_in_flight  /* verilator public_flat_rd */;
  logic dbg_pipeline_stall  /* verilator public_flat_rd */;
  logic dbg_pipeline_stall_registered  /* verilator public_flat_rd */;
  logic dbg_dispatch_stall  /* verilator public_flat_rd */;
  logic dbg_front_end_cf_serialize_stall  /* verilator public_flat_rd */;
  logic dbg_stall_q  /* verilator public_flat_rd */;
  logic dbg_replay_after_dispatch_stall_q  /* verilator public_flat_rd */;
  logic dbg_replay_after_serialize_stall_q  /* verilator public_flat_rd */;
  logic [BranchInFlightCountWidth-1:0] dbg_branch_in_flight_count  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_alloc_pc  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_is_csr  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_is_mret  /* verilator public_flat_rd */;
  logic dbg_btb_update  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_btb_update_pc  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_btb_update_target  /* verilator public_flat_rd */;
  logic dbg_btb_update_taken  /* verilator public_flat_rd */;
  logic dbg_btb_update_compressed  /* verilator public_flat_rd */;
  logic dbg_issue_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_issue_pc  /* verilator public_flat_rd */;
  logic dbg_issue_predicted_taken  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rs_dispatch_pc  /* verilator public_flat_rd */;
  // verilog_lint: waive-start line-length
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_rob_tag  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_src1_ready  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_src1_tag  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_src2_ready  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_src2_tag  /* verilator public_flat_rd */;
`ifndef SYNTHESIS
  logic dbg_rat_alloc_valid  /* verilator public_flat_rd */;
  logic dbg_rat_alloc_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rat_alloc_dest_reg  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rat_alloc_rob_tag  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_last_a0_alloc_pc  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_last_a0_alloc_tag  /* verilator public_flat_rd */;
  // verilog_lint: waive-stop line-length
`endif

  assign dbg_if_ras_predicted = from_if_to_pd.ras_predicted;
  assign dbg_pd_ras_predicted = from_pd_to_id.ras_predicted;
  assign dbg_id_ras_predicted = from_id_to_ex.ras_predicted;
  assign dbg_if_ras_checkpoint_tos = from_if_to_pd.ras_checkpoint_tos;
  assign dbg_if_ras_checkpoint_valid_count = from_if_to_pd.ras_checkpoint_valid_count;
  assign dbg_pd_ras_checkpoint_tos = from_pd_to_id.ras_checkpoint_tos;
  assign dbg_pd_ras_checkpoint_valid_count = from_pd_to_id.ras_checkpoint_valid_count;
  assign dbg_id_ras_checkpoint_tos = from_id_to_ex.ras_checkpoint_tos;
  assign dbg_id_ras_checkpoint_valid_count = from_id_to_ex.ras_checkpoint_valid_count;
  assign dbg_commit_valid = rob_commit_comb.valid;
  assign dbg_commit_pc = rob_commit_comb.pc;
  assign dbg_commit_is_return = rob_commit_comb.is_return;
  assign dbg_commit_is_call = rob_commit_comb.is_call;
  assign dbg_commit_checkpoint_id = rob_commit_comb.checkpoint_id;
  assign dbg_commit_has_checkpoint = rob_commit_comb.has_checkpoint;
  assign dbg_commit_predicted_taken = rob_commit_comb.predicted_taken;
  assign dbg_commit_branch_taken = rob_commit_comb.branch_taken;
  assign dbg_pd_pc = from_pd_to_id.program_counter;
  assign dbg_pd_instr = from_pd_to_id.instruction;
  assign dbg_id_pc = from_id_to_ex.program_counter;
  assign dbg_id_instr = from_id_to_ex.instruction;
  assign dbg_id_is_mret = from_id_to_ex.is_mret;
  assign dbg_post_flush_holdoff_q = post_flush_holdoff_q;
  assign dbg_csr_in_flight = csr_in_flight;
  assign dbg_pipeline_stall = pipeline_ctrl.stall;
  assign dbg_pipeline_stall_registered = pipeline_ctrl.stall_registered;
  assign dbg_dispatch_stall = dispatch_stall;
  assign dbg_front_end_cf_serialize_stall = front_end_cf_serialize_stall;
  assign dbg_stall_q = stall_q;
  assign dbg_replay_after_dispatch_stall_q = replay_after_dispatch_stall_q;
  assign dbg_replay_after_serialize_stall_q = replay_after_serialize_stall_q;
  assign dbg_branch_in_flight_count = branch_in_flight_count;
  assign dbg_btb_update = from_ex_comb_synth.btb_update;
  assign dbg_btb_update_pc = from_ex_comb_synth.btb_update_pc;
  assign dbg_btb_update_target = from_ex_comb_synth.btb_update_target;
  assign dbg_btb_update_taken = from_ex_comb_synth.btb_update_taken;
  assign dbg_btb_update_compressed = from_ex_comb_synth.btb_update_compressed;
  assign dbg_issue_valid = rs_issue_int.valid;
  assign dbg_issue_pc = rs_issue_int.pc;
  assign dbg_issue_predicted_taken = rs_issue_int.predicted_taken;
  assign dbg_rs_dispatch_valid = rs_dispatch.valid;
  assign dbg_rs_dispatch_pc = rs_dispatch.pc;
  assign dbg_rs_dispatch_rob_tag = rs_dispatch.rob_tag;
  assign dbg_rs_dispatch_src1_ready = rs_dispatch.src1_ready;
  assign dbg_rs_dispatch_src1_tag = rs_dispatch.src1_tag;
  assign dbg_rs_dispatch_src2_ready = rs_dispatch.src2_ready;
  assign dbg_rs_dispatch_src2_tag = rs_dispatch.src2_tag;
`ifndef SYNTHESIS
  assign dbg_rat_alloc_valid = rat_alloc_valid;
  assign dbg_rat_alloc_dest_rf = rat_alloc_dest_rf;
  assign dbg_rat_alloc_dest_reg = rat_alloc_dest_reg;
  assign dbg_rat_alloc_rob_tag = rat_alloc_rob_tag;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dbg_last_a0_alloc_pc  <= '0;
      dbg_last_a0_alloc_tag <= '0;
    end else if (rat_alloc_valid && !rat_alloc_dest_rf && (rat_alloc_dest_reg == 5'd10)) begin
      dbg_last_a0_alloc_pc  <= rob_alloc_req.pc;
      dbg_last_a0_alloc_tag <= rat_alloc_rob_tag;
    end
  end
`endif

  // Synthesized from_ex_comb for IF stage (branch redirect, BTB update, RAS restore)
  riscv_pkg::from_ex_comb_t from_ex_comb_synth;

  // Trap control
  riscv_pkg::trap_ctrl_t trap_ctrl;
  logic trap_taken, mret_taken;
  logic [XLEN-1:0] trap_target;

  assign trap_ctrl.trap_taken  = trap_taken_reg;
  assign trap_ctrl.mret_taken  = mret_taken_reg;
  assign trap_ctrl.trap_target = trap_target_reg;

  // ===========================================================================
  // Stage 1: Instruction Fetch (IF) — UNCHANGED
  // ===========================================================================

  if_stage #(
      .XLEN(XLEN)
  ) if_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_instr,
      .i_instr_sideband,
      .i_instr_bank_sel_r,
      .i_from_ex_comb(from_ex_comb_synth),
      .i_trap_ctrl(trap_ctrl),
      .i_frontend_state_flush(frontend_state_flush),
      .i_fence_i_flush(fence_i_flush),
      .i_fence_i_target(fence_i_target_pc),
      .i_disable_branch_prediction(disable_branch_prediction_ooo),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_target(pd_redirect_target),
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd)
  );

  // ===========================================================================
  // Stage 2: Pre-Decode (PD) — UNCHANGED
  // ===========================================================================

  pd_stage #(
      .XLEN(XLEN)
  ) pd_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .o_from_pd_to_id(from_pd_to_id),
      .o_pd_redirect(pd_redirect),
      .o_pd_redirect_target(pd_redirect_target)
  );

  // ===========================================================================
  // Register Files (read in ID, write from ROB commit)
  // ===========================================================================

  // Integer register file
  logic                      [4*XLEN-1:0] int_rf_read_data;
  logic                                   int_rf_write_enable;
  logic                      [       4:0] int_rf_write_addr;
  logic                      [  XLEN-1:0] int_rf_write_data;
  logic                                   int_rf_wb_bypass_id_rs1;
  logic                                   int_rf_wb_bypass_id_rs2;
  logic                                   int_rf_wb_bypass_dispatch_rs1;
  logic                                   int_rf_wb_bypass_dispatch_rs2;
  logic                      [  XLEN-1:0] int_rf_dispatch_rs1_data;
  logic                      [  XLEN-1:0] int_rf_dispatch_rs2_data;

  riscv_pkg::rf_to_fwd_t                  rf_to_fwd;
  riscv_pkg::from_ma_to_wb_t              from_ma_to_wb_commit;

  generic_regfile #(
      .DATA_WIDTH(XLEN),
      .NUM_READ_PORTS(4),
      .HARDWIRE_ZERO(1)
  ) regfile_inst (
      .i_clk,
      .i_write_enable(int_rf_write_enable),
      .i_write_addr(int_rf_write_addr),
      .i_write_data(int_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(int_rf_read_data)
  );

  assign int_rf_wb_bypass_id_rs1 = int_rf_write_enable &&
                                   |int_rf_write_addr &&
                                   (int_rf_write_addr == from_pd_to_id.source_reg_1_early);
  assign int_rf_wb_bypass_id_rs2 = int_rf_write_enable &&
                                   |int_rf_write_addr &&
                                   (int_rf_write_addr == from_pd_to_id.source_reg_2_early);
  assign int_rf_wb_bypass_dispatch_rs1 = int_rf_write_enable &&
                                         |int_rf_write_addr &&
                                         (int_rf_write_addr ==
                                          from_id_to_ex.instruction.source_reg_1);
  assign int_rf_wb_bypass_dispatch_rs2 = int_rf_write_enable &&
                                         |int_rf_write_addr &&
                                         (int_rf_write_addr ==
                                          from_id_to_ex.instruction.source_reg_2);

  // Bypass data for ID/dispatch: use rob_commit.value directly (fast path).
  // For CSR commits, int_rf_write_data includes the slow csr_read_data_comb
  // path (16 logic levels through exception FSM + CSR file).  But CSR commits
  // never coincide with active dispatch/ID consumption because csr_in_flight
  // stalls the entire front-end pipeline, so using rob_commit.value here is
  // functionally safe and eliminates the critical path.
  logic [XLEN-1:0] int_rf_commit_bypass_data;
  assign int_rf_commit_bypass_data = rob_commit.value[XLEN-1:0];

  assign rf_to_fwd.source_reg_1_data = int_rf_wb_bypass_id_rs1 ? int_rf_commit_bypass_data :
                                       int_rf_read_data[XLEN-1:0];
  assign rf_to_fwd.source_reg_2_data = int_rf_wb_bypass_id_rs2 ? int_rf_commit_bypass_data :
                                       int_rf_read_data[2*XLEN-1:XLEN];
  assign int_rf_dispatch_rs1_data = int_rf_wb_bypass_dispatch_rs1 ? int_rf_commit_bypass_data :
                                    int_rf_read_data[3*XLEN-1:2*XLEN];
  assign int_rf_dispatch_rs2_data = int_rf_wb_bypass_dispatch_rs2 ? int_rf_commit_bypass_data :
                                    int_rf_read_data[4*XLEN-1:3*XLEN];

  // FP register file
  localparam int unsigned FpW = riscv_pkg::FpWidth;
  logic                     [6*FpW-1:0] fp_rf_read_data;
  logic                                 fp_rf_write_enable;
  logic                     [      4:0] fp_rf_write_addr;
  logic                     [  FpW-1:0] fp_rf_write_data;
  logic                                 fp_rf_wb_bypass_id_rs1;
  logic                                 fp_rf_wb_bypass_id_rs2;
  logic                                 fp_rf_wb_bypass_id_rs3;
  logic                                 fp_rf_wb_bypass_dispatch_rs1;
  logic                                 fp_rf_wb_bypass_dispatch_rs2;
  logic                                 fp_rf_wb_bypass_dispatch_rs3;
  logic                     [  FpW-1:0] fp_rf_dispatch_rs1_data;
  logic                     [  FpW-1:0] fp_rf_dispatch_rs2_data;
  logic                     [  FpW-1:0] fp_rf_dispatch_rs3_data;

  riscv_pkg::fp_rf_to_fwd_t             fp_rf_to_fwd;

  generic_regfile #(
      .DATA_WIDTH(FpW),
      .NUM_READ_PORTS(6),
      .HARDWIRE_ZERO(0)
  ) fp_regfile_inst (
      .i_clk,
      .i_write_enable(fp_rf_write_enable),
      .i_write_addr(fp_rf_write_addr),
      .i_write_data(fp_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex.instruction.funct7[6:2],
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.fp_source_reg_3_early,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(fp_rf_read_data)
  );

  assign fp_rf_wb_bypass_id_rs1 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.source_reg_1_early);
  assign fp_rf_wb_bypass_id_rs2 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.source_reg_2_early);
  assign fp_rf_wb_bypass_id_rs3 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.fp_source_reg_3_early);
  assign fp_rf_wb_bypass_dispatch_rs1 = fp_rf_write_enable &&
                                        (fp_rf_write_addr ==
                                         from_id_to_ex.instruction.source_reg_1);
  assign fp_rf_wb_bypass_dispatch_rs2 = fp_rf_write_enable &&
                                        (fp_rf_write_addr ==
                                         from_id_to_ex.instruction.source_reg_2);
  assign fp_rf_wb_bypass_dispatch_rs3 = fp_rf_write_enable &&
                                        (fp_rf_write_addr == from_id_to_ex.instruction.funct7[6:2]);

  assign fp_rf_to_fwd.fp_source_reg_1_data = fp_rf_wb_bypass_id_rs1 ? fp_rf_write_data :
                                             fp_rf_read_data[FpW-1:0];
  assign fp_rf_to_fwd.fp_source_reg_2_data = fp_rf_wb_bypass_id_rs2 ? fp_rf_write_data :
                                             fp_rf_read_data[2*FpW-1:FpW];
  assign fp_rf_to_fwd.fp_source_reg_3_data = fp_rf_wb_bypass_id_rs3 ? fp_rf_write_data :
                                             fp_rf_read_data[3*FpW-1:2*FpW];
  assign fp_rf_dispatch_rs1_data = fp_rf_wb_bypass_dispatch_rs1 ? fp_rf_write_data :
                                   fp_rf_read_data[4*FpW-1:3*FpW];
  assign fp_rf_dispatch_rs2_data = fp_rf_wb_bypass_dispatch_rs2 ? fp_rf_write_data :
                                   fp_rf_read_data[5*FpW-1:4*FpW];
  assign fp_rf_dispatch_rs3_data = fp_rf_wb_bypass_dispatch_rs3 ? fp_rf_write_data :
                                   fp_rf_read_data[6*FpW-1:5*FpW];

  // ===========================================================================
  // Stage 3: Instruction Decode (ID)
  // ===========================================================================
  // ROB commit writes are architectural WB for the OOO core. Decode still needs
  // same-cycle bypass when it reads a source register that is being committed.
  always_comb begin
    from_ma_to_wb_commit                         = '0;
    from_ma_to_wb_commit.regfile_write_enable    = int_rf_write_enable;
    from_ma_to_wb_commit.regfile_write_data      = int_rf_write_data;
    from_ma_to_wb_commit.instruction.dest_reg    = int_rf_write_addr;
    from_ma_to_wb_commit.fp_regfile_write_enable = fp_rf_write_enable;
    from_ma_to_wb_commit.fp_dest_reg             = fp_rf_write_addr;
    from_ma_to_wb_commit.fp_regfile_write_data   = fp_rf_write_data;
  end

  id_stage #(
      .XLEN(XLEN)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_rf_to_id(rf_to_fwd),
      .i_fp_rf_to_id(fp_rf_to_fwd),
      .i_from_ma_to_wb(from_ma_to_wb_commit),
      .o_from_id_to_ex(from_id_to_ex)
  );

  // ===========================================================================
  // Instruction Validity (pipeline valid tracking)
  // ===========================================================================
  // After a flush/reset, the pipeline inserts NOP bubbles:
  //   T=0: PD/ID flush to NOP
  //   T=1: IF holdoff NOP (stale i_instr from 1-cycle memory latency)
  //   T=2: First real instruction reaches PD
  //   T=3: First real instruction reaches ID (from_id_to_ex valid)
  // A 3-stage valid tracker matches this IF→PD→ID latency plus the holdoff
  // cycle, ensuring NOP bubbles are never dispatched.

  logic if_valid_q;  // tracks valid at IF→PD boundary
  logic pd_valid_q;  // tracks valid at PD→ID boundary

  // Track IF stage's sel_nop through the pipeline to know when from_id_to_ex
  // contains a real instruction vs a NOP bubble (holdoff/flush/reset).
  // 2-stage chain: if_valid_q captures at PD register edge, pd_valid_q
  // captures at ID register edge — matching when from_id_to_ex is updated.
  always_ff @(posedge i_clk) begin
    if (i_rst || pipeline_ctrl.flush) begin
      if_valid_q <= 1'b0;
      pd_valid_q <= 1'b0;
    end else if (!pipeline_ctrl.stall) begin
      if_valid_q <= !from_if_to_pd.sel_nop && (post_flush_holdoff_q == 2'd0);
      pd_valid_q <= if_valid_q;
    end
  end

  // id_valid: reads flush_pipeline/i_rst/stall_q directly instead of
  // pipeline_ctrl fields.  This breaks a false Verilator UNOPTFLAT cycle
  // (pipeline_ctrl.stall depends on dispatch_stall which depends on
  // id_valid, but id_valid only needs .flush/.reset/.stall_registered
  // which are independent of dispatch_stall).
  logic id_valid;
  assign id_valid = pd_valid_q && !flush_pipeline && !i_rst &&
                    (from_id_to_ex.instruction != riscv_pkg::NOP) &&
                    !from_id_to_ex.is_illegal_instruction &&
                    !csr_in_flight &&
      // Re-dispatch the held ID image after real backpressure stalls,
      // and after CSR serialization fences. The CSR itself has already
      // allocated before csr_in_flight rises; the held ID image during the
      // fence is the younger blocked instruction that still needs exactly
      // one valid replay cycle after the fence drops.
      (!stall_q || replay_after_dispatch_stall_q || replay_after_serialize_stall_q);
  assign dbg_if_valid_q = if_valid_q;
  assign dbg_pd_valid_q = pd_valid_q;
  assign dbg_id_valid = id_valid;

  logic if_has_control_flow;
  logic if_has_indirect_control_flow;
  logic pd_has_control_flow;
  logic pd_has_indirect_control_flow;
  logic id_has_control_flow;
  logic id_has_indirect_control_flow;

  function automatic logic if_stage_has_control_flow(input riscv_pkg::from_if_to_pd_t if_pkt);
    logic [2:0] c_funct3;
    logic [3:0] c_funct4;
    logic [4:0] c_rs1;
    logic [4:0] c_rs2;
    logic [1:0] c_op;
    begin
      c_funct3 = if_pkt.raw_parcel[15:13];
      c_funct4 = if_pkt.raw_parcel[15:12];
      c_rs1 = if_pkt.raw_parcel[11:7];
      c_rs2 = if_pkt.raw_parcel[6:2];
      c_op = if_pkt.raw_parcel[1:0];

      if_stage_has_control_flow = 1'b0;
      if (!if_pkt.sel_nop) begin
        if (if_pkt.sel_compressed) begin
          // IF stage carries raw compressed parcels, not decompressed opcodes.
          // Recognize compressed control-flow directly so younger BTB lookups
          // cannot run ahead of an older unresolved c.branch/c.jump.
          if_stage_has_control_flow = ((c_op == 2'b01) && ((c_funct3 == 3'b001) ||  // C.JAL (RV32)
          (c_funct3 == 3'b101) ||  // C.J
          (c_funct3 == 3'b110) ||  // C.BEQZ
          (c_funct3 == 3'b111))) ||  // C.BNEZ
          ((c_op == 2'b10) &&
               (c_rs2 == 5'b00000) &&
               (c_rs1 != 5'b00000) &&
               ((c_funct4 == 4'b1000) ||  // C.JR
          (c_funct4 == 4'b1001)));  // C.JALR
        end else begin
          if_stage_has_control_flow =
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_BRANCH) ||
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JAL) ||
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JALR);
        end
      end
    end
  endfunction

  function automatic logic if_stage_has_indirect_control_flow(
      input riscv_pkg::from_if_to_pd_t if_pkt);
    logic [15:0] c_instr;
    logic [ 1:0] c_op;
    logic [ 3:0] c_funct4;
    logic [4:0] c_rs1, c_rs2;
    begin
      if_stage_has_indirect_control_flow = 1'b0;
      if (!if_pkt.sel_nop) begin
        if (if_pkt.sel_compressed) begin
          c_instr = if_pkt.effective_instr[15:0];
          c_op = c_instr[1:0];
          c_funct4 = c_instr[15:12];
          c_rs1 = c_instr[11:7];
          c_rs2 = c_instr[6:2];
          if_stage_has_indirect_control_flow = ((c_op == 2'b10) &&
                                                (c_rs2 == 5'b00000) &&
                                                (c_rs1 != 5'b00000) &&
                                                ((c_funct4 == 4'b1000) ||
                                                 (c_funct4 == 4'b1001)));
        end else begin
          if_stage_has_indirect_control_flow = (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JALR);
        end
      end
    end
  endfunction

  assign if_has_control_flow = if_stage_has_control_flow(from_if_to_pd);
  assign if_has_indirect_control_flow = if_stage_has_indirect_control_flow(from_if_to_pd);
  assign pd_has_control_flow = if_valid_q &&
                               ((from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JAL) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JALR));
  assign pd_has_indirect_control_flow = if_valid_q &&
                                        (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JALR);
  assign id_has_control_flow = pd_valid_q && (
      from_id_to_ex.instruction_operation == riscv_pkg::BEQ ||
      from_id_to_ex.instruction_operation == riscv_pkg::BNE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLT ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLTU ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGEU ||
      from_id_to_ex.instruction_operation == riscv_pkg::JAL ||
      from_id_to_ex.instruction_operation == riscv_pkg::JALR
  );
  assign id_has_indirect_control_flow = pd_valid_q &&
                                        (from_id_to_ex.instruction_operation == riscv_pkg::JALR);

  // Only unpredicted front-end control flow needs the extra prediction fence.
  // Once an older branch/return has already redirected fetch onto its predicted
  // path, later predictions on that same path are expected and required for
  // tight loops. Treating already-predicted IF/PD/ID control-flow ops as
  // "pending" shuts prediction back off and creates a second unpredicted copy
  // of the same branch, which is exactly what breaks compressed back-edge loops.
  // IF-stage control flow detection is registered to break a combinational
  // loop: pipeline_ctrl.stall → IF stage (c_ext_state, aligner, prediction
  // metadata) → from_if_to_pd → front_end_control_flow_pending →
  // front_end_cf_serialize_stall → pipeline_ctrl.stall.  One cycle of
  // latency is harmless — the serialization fence is a performance hint.
  logic if_unpredicted_control_flow_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_unpredicted_control_flow_q <= 1'b0;
    else
      if_unpredicted_control_flow_q <= if_has_control_flow &&
                                       !(from_if_to_pd.btb_predicted_taken ||
                                         from_if_to_pd.ras_predicted);
  end
  assign if_unpredicted_control_flow = if_unpredicted_control_flow_q;
  assign if_unpredicted_indirect_control_flow = if_unpredicted_control_flow_q &&
                                                if_has_indirect_control_flow;
  assign pd_unpredicted_control_flow = pd_has_control_flow &&
                                       !(from_pd_to_id.btb_predicted_taken ||
                                         from_pd_to_id.ras_predicted);
  assign pd_unpredicted_indirect_control_flow = pd_has_indirect_control_flow &&
                                                !(from_pd_to_id.btb_predicted_taken ||
                                                  from_pd_to_id.ras_predicted);
  assign pd_unpredicted_branch = pd_unpredicted_control_flow &&
                                 (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH);
  assign pd_unpredicted_jal = pd_unpredicted_control_flow &&
                              (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JAL);
  assign id_unpredicted_control_flow = id_has_control_flow &&
                                       !(from_id_to_ex.btb_predicted_taken ||
                                         from_id_to_ex.ras_predicted);
  assign id_unpredicted_indirect_control_flow = id_has_indirect_control_flow &&
                                                !(from_id_to_ex.btb_predicted_taken ||
                                                  from_id_to_ex.ras_predicted);
  assign id_unpredicted_branch = id_unpredicted_control_flow && (
      from_id_to_ex.instruction_operation == riscv_pkg::BEQ ||
      from_id_to_ex.instruction_operation == riscv_pkg::BNE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLT ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLTU ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGEU
  );
  assign id_unpredicted_jal = id_unpredicted_control_flow &&
                              (from_id_to_ex.instruction_operation == riscv_pkg::JAL);
  assign front_end_control_flow_pending = if_unpredicted_control_flow ||
                                          pd_unpredicted_control_flow ||
                                          id_unpredicted_control_flow;
  assign front_end_indirect_control_flow_pending = if_unpredicted_indirect_control_flow ||
                                                   pd_unpredicted_indirect_control_flow ||
                                                   id_unpredicted_indirect_control_flow;
  always_comb begin
    prediction_fence_branch = 1'b0;
    prediction_fence_jal = 1'b0;
    prediction_fence_indirect = 1'b0;
    if (id_unpredicted_indirect_control_flow) begin
      prediction_fence_indirect = 1'b1;
    end else if (id_unpredicted_jal) begin
      prediction_fence_jal = 1'b1;
    end else if (id_unpredicted_branch) begin
      prediction_fence_branch = 1'b1;
    end else if (pd_unpredicted_indirect_control_flow) begin
      prediction_fence_indirect = 1'b1;
    end else if (pd_unpredicted_jal) begin
      prediction_fence_jal = 1'b1;
    end else if (pd_unpredicted_branch) begin
      prediction_fence_branch = 1'b1;
    end
  end

  // ===========================================================================
  // Tomasulo Wrapper Instance
  // ===========================================================================

  // ROB interface
  riscv_pkg::reorder_buffer_alloc_req_t  rob_alloc_req;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp;
  assign dbg_rob_alloc_valid = rob_alloc_req.alloc_valid;
  assign dbg_rob_alloc_pc = rob_alloc_req.pc;
  assign dbg_rob_alloc_is_csr = rob_alloc_req.is_csr;
  assign dbg_rob_alloc_is_mret = rob_alloc_req.is_mret;
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb;  // combinational from ROB
  riscv_pkg::reorder_buffer_commit_t rob_commit;  // registered — drives CSR/regfile/bypass
  logic rob_commit_valid;
  logic rob_commit_valid_raw;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_epoch;

  // RAT lookup
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr, int_src2_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr, fp_src2_addr, fp_src3_addr;
  riscv_pkg::rat_lookup_t int_src1_lookup, int_src2_lookup;
  riscv_pkg::rat_lookup_t fp_src1_lookup, fp_src2_lookup, fp_src3_lookup;

  // RAT rename
  logic                                        rat_alloc_valid;
  logic                                        rat_alloc_dest_rf;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rob_entry_epoch <= '0;
    end else if (rob_alloc_req.alloc_valid) begin
      rob_entry_epoch[rob_alloc_resp.alloc_tag] <= ~rob_entry_epoch[rob_alloc_resp.alloc_tag];
    end
  end

  // RS dispatch
  riscv_pkg::rs_dispatch_t                                        rs_dispatch;

  // Checkpoint
  logic                                                           checkpoint_available;
  logic                    [    riscv_pkg::CheckpointIdWidth-1:0] checkpoint_alloc_id;
  logic                                                           checkpoint_save;
  logic                    [    riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_branch_tag;
  logic                    [           riscv_pkg::RasPtrBits-1:0] dispatch_ras_tos;
  logic                    [             riscv_pkg::RasPtrBits:0] dispatch_ras_valid_count;
  logic                                                           rob_checkpoint_valid;
  logic                    [    riscv_pkg::CheckpointIdWidth-1:0] rob_checkpoint_id;

  // Resource status
  logic rob_full, rob_empty;
  logic int_rs_full, mul_rs_full, mem_rs_full;
  logic fp_rs_full, fmul_rs_full, fdiv_rs_full;
  logic lq_full, sq_full;

  // Branch update
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  logic rob_commit_misprediction_raw;
  logic rob_commit_correct_branch_raw;
  logic rob_head_commit_misprediction_candidate;

  // Flush
  logic flush_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag;
  logic flush_all;
  logic commit_recovery_flush_after_head;
  (* max_fanout = 32 *) logic mispredict_recovery_pending;
  typedef struct packed {
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic has_checkpoint;
    logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] redirect_pc;
    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_call;
    logic is_return;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } mispredict_commit_capture_t;
  mispredict_commit_capture_t mispredict_commit_q;
  logic frontend_state_flush;

  // CDB
  riscv_pkg::cdb_broadcast_t cdb_out;
  logic [riscv_pkg::NumFus-1:0] cdb_grant;

  // ROB status
  logic [riscv_pkg::ReorderBufferTagWidth:0] rob_count;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic head_valid, head_done;
  logic fence_i_flush;
  logic [XLEN-1:0] fence_i_target_pc;

  // CSR coordination
  logic csr_start, csr_done_ack;
  logic trap_pending;
  logic [XLEN-1:0] rob_trap_pc;
  riscv_pkg::exc_cause_t rob_trap_cause;
  logic rob_trap_taken_ack;
  logic mret_start, mret_done_ack;
  logic [XLEN-1:0] mepc_value;
  logic interrupt_pending;

  // Memory interfaces
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr, sq_mem_write_data;
  logic [3:0] sq_mem_write_byte_en;
  logic sq_mem_write_done, sq_mem_write_done_comb;

  logic lq_mem_read_en;
  logic [XLEN-1:0] lq_mem_read_addr;
  riscv_pkg::mem_size_e lq_mem_read_size;
  logic [XLEN-1:0] lq_mem_read_data;
  logic lq_mem_read_valid;
  logic lq_mem_request_valid;
  logic [XLEN-1:0] lq_mem_request_addr;
  logic lq_mem_request_fire;
  logic [XLEN-1:0] lq_mem_request_addr_eff;

  // AMO memory interface
  logic amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr, amo_mem_write_data;
  logic amo_mem_write_done;

  // RS issue (exposed but not externally driven — FU shims are inside wrapper)
  riscv_pkg::rs_issue_t rs_issue_int, rs_issue_mul, rs_issue_mem;
  riscv_pkg::rs_issue_t rs_issue_fp, rs_issue_fmul, rs_issue_fdiv;

  // ROB bypass read
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rob_read_tag;
  logic rob_read_done;
  logic [riscv_pkg::FLEN-1:0] rob_read_value;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done_dispatch;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_1, dispatch_bypass_tag_2, dispatch_bypass_tag_3;
  logic [riscv_pkg::FLEN-1:0]
      dispatch_bypass_value_1, dispatch_bypass_value_2, dispatch_bypass_value_3;

  // Checkpoint restore (from flush controller)
  logic checkpoint_restore;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_restore_id;
  logic checkpoint_restore_reclaim_all;
  logic [riscv_pkg::RasPtrBits-1:0] restored_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] restored_ras_valid_count;

  // Checkpoint free (from commit or flush-time reclaim)
  logic checkpoint_free;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id;

  // Track checkpoint → ROB tag mapping for flush-time reclaim.
  // When a partial flush fires, checkpoints belonging to younger-than-flush-tag
  // branches must be freed to prevent checkpoint slot exhaustion.
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag[riscv_pkg::NumCheckpoints];
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;

  // Pre-merge checkpoint_in_use: matches RAT checkpoint_valid priorities
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use_next;
  always_comb begin
    if (flush_all || checkpoint_restore_reclaim_all) checkpoint_in_use_next = '0;
    else begin
      checkpoint_in_use_next = checkpoint_in_use;
      checkpoint_in_use_next = checkpoint_in_use_next & ~checkpoint_flush_free_mask;
      if (checkpoint_free) checkpoint_in_use_next[checkpoint_free_id] = 1'b0;
      // Save wins over all clears
      if (rob_checkpoint_valid) checkpoint_in_use_next[rob_checkpoint_id] = 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) checkpoint_in_use <= '0;
    else checkpoint_in_use <= checkpoint_in_use_next;
  end

  // Owner tag tracking (only updates on save)
  always_ff @(posedge i_clk) begin
    if (rob_checkpoint_valid) checkpoint_owner_tag[rob_checkpoint_id] <= rob_alloc_resp.alloc_tag;
  end

  // Flush-time checkpoint reclaim: free checkpoints owned by flushed entries.
  // Compute which checkpoints are younger than flush_tag (combinational).
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_younger_than_flush;
  logic [riscv_pkg::ReorderBufferTagWidth:0] ckpt_owner_age[riscv_pkg::NumCheckpoints];
  logic [riscv_pkg::ReorderBufferTagWidth:0] ckpt_flush_age;
  always_comb begin
    ckpt_flush_age = {1'b0, flush_tag} - {1'b0, head_tag};
    for (int i = 0; i < riscv_pkg::NumCheckpoints; i++) begin
      ckpt_owner_age[i] = {1'b0, checkpoint_owner_tag[i]} - {1'b0, head_tag};
      // > excludes the restoring checkpoint (freed via checkpoint_free separately)
      checkpoint_younger_than_flush[i] = checkpoint_in_use[i] &&
                                          (ckpt_owner_age[i] > ckpt_flush_age);
    end
  end

  // Debug/visibility bitmap for the younger checkpoints targeted by the most
  // recent partial flush.  Functional reclaim happens via
  // checkpoint_flush_free_mask_q below; re-freeing the same IDs later can
  // accidentally clear newly reallocated checkpoints.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_pending;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) checkpoint_flush_pending <= '0;
    else if (flush_en)
      checkpoint_flush_pending <= flush_after_head ? checkpoint_in_use
                                                   : checkpoint_younger_than_flush;
    else checkpoint_flush_pending <= '0;
  end

  // LQ/SQ status
  logic lq_empty, sq_empty;
  logic [$clog2(riscv_pkg::LqDepth+1)-1:0] lq_count;
  logic [$clog2(riscv_pkg::SqDepth+1)-1:0] sq_count;
  logic rs_empty;
  logic [3:0] rs_count;

  // FRM CSR
  logic [2:0] frm_csr;

  // CSR read data
  logic [XLEN-1:0] csr_read_data;  // registered (1-cycle latency)
  logic [XLEN-1:0] csr_read_data_comb;  // combinational (same cycle, for rd write)

  tomasulo_wrapper u_tomasulo (
      .i_clk,
      .i_rst_n(rst_n),

      .i_frm_csr(frm_csr),

      // FU completion test injection (unused in production)
      .i_fu_complete_0('0),
      .i_fu_complete_1('0),
      .i_fu_complete_2('0),
      .i_fu_complete_3('0),
      .i_fu_complete_4('0),
      .i_fu_complete_5('0),
      .i_fu_complete_6('0),

      // ROB allocation
      .i_alloc_req (rob_alloc_req),
      .o_alloc_resp(rob_alloc_resp),

      .o_cdb_grant(cdb_grant),
      .o_cdb(cdb_out),

      // Branch update
      .i_branch_update(branch_update),

      // ROB checkpoint recording
      .i_rob_checkpoint_valid(rob_checkpoint_valid),
      .i_rob_checkpoint_id(rob_checkpoint_id),

      // Commit
      .o_commit(rob_commit),
      .o_commit_comb(rob_commit_comb),
      .o_commit_valid_raw(rob_commit_valid_raw),
      .o_commit_misprediction_raw(rob_commit_misprediction_raw),
      .o_commit_correct_branch_raw(rob_commit_correct_branch_raw),
      .o_head_commit_misprediction_candidate(rob_head_commit_misprediction_candidate),

      // ROB external coordination
      .o_csr_start(csr_start),
      .i_csr_done(csr_done_ack),
      .o_trap_pending(trap_pending),
      .o_trap_pc(rob_trap_pc),
      .o_trap_cause(rob_trap_cause),
      .i_trap_taken(rob_trap_taken_ack),
      .o_mret_start(mret_start),
      .i_mret_done(mret_done_ack),
      .i_mepc(mepc_value),
      .i_interrupt_pending(interrupt_pending),

      // Flush
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_flush_all(flush_all),
      .i_flush_after_head_commit(commit_recovery_flush_after_head),
      .i_backend_recovery_hold(early_backend_recovery_hold),

      // Early misprediction recovery
      .i_early_recovery_flush(early_backend_recovery_pending),
      .i_early_recovery_en(early_recovery_en),
      .i_early_recovery_tag(early_recovery_tag),

      // ROB status
      .o_fence_i_flush(fence_i_flush),
      .o_rob_full(rob_full),
      .o_rob_empty(rob_empty),
      .o_rob_count(rob_count),
      .o_head_tag(head_tag),
      .o_head_valid(head_valid),
      .o_head_done(head_done),

      // ROB bypass read
      .i_read_tag(rob_read_tag),
      .o_read_done(rob_read_done),
      .o_read_value(rob_read_value),
      .o_rob_entry_done_vec(rob_entry_done_dispatch),
      .i_rob_entry_epoch(rob_entry_epoch),
      .i_bypass_tag_1(dispatch_bypass_tag_1),
      .o_bypass_value_1(dispatch_bypass_value_1),
      .i_bypass_tag_2(dispatch_bypass_tag_2),
      .o_bypass_value_2(dispatch_bypass_value_2),
      .i_bypass_tag_3(dispatch_bypass_tag_3),
      .o_bypass_value_3(dispatch_bypass_value_3),

      // RAT source lookups
      .i_int_src1_addr(int_src1_addr),
      .i_int_src2_addr(int_src2_addr),
      .o_int_src1(int_src1_lookup),
      .o_int_src2(int_src2_lookup),
      .i_fp_src1_addr(fp_src1_addr),
      .i_fp_src2_addr(fp_src2_addr),
      .i_fp_src3_addr(fp_src3_addr),
      .o_fp_src1(fp_src1_lookup),
      .o_fp_src2(fp_src2_lookup),
      .o_fp_src3(fp_src3_lookup),

      // RAT regfile data
      .i_int_regfile_data1(int_rf_dispatch_rs1_data),
      .i_int_regfile_data2(int_rf_dispatch_rs2_data),
      .i_fp_regfile_data1 (fp_rf_dispatch_rs1_data),
      .i_fp_regfile_data2 (fp_rf_dispatch_rs2_data),
      .i_fp_regfile_data3 (fp_rf_dispatch_rs3_data),

      // RAT rename
      .i_rat_alloc_valid(rat_alloc_valid),
      .i_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .i_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .i_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT checkpoint save
      .i_checkpoint_save(checkpoint_save),
      .i_checkpoint_id(checkpoint_id),
      .i_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(dispatch_ras_tos),
      .i_ras_valid_count(dispatch_ras_valid_count),

      // RAT checkpoint restore
      .i_checkpoint_restore(checkpoint_restore),
      .i_checkpoint_restore_id(checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
      .i_checkpoint_reclaim_mask(checkpoint_reclaim_mask),
      .i_checkpoint_flush_free_mask(checkpoint_flush_free_mask),
      .o_ras_tos(restored_ras_tos),
      .o_ras_valid_count(restored_ras_valid_count),

      // RAT checkpoint free
      .i_checkpoint_free(checkpoint_free),
      .i_checkpoint_free_id(checkpoint_free_id),

      // RAT checkpoint availability
      .o_checkpoint_available(checkpoint_available),
      .o_checkpoint_alloc_id (checkpoint_alloc_id),

      // RS dispatch
      .i_rs_dispatch(rs_dispatch),
      .o_rs_full(),

      // RS issue + status (INT_RS)
      .o_rs_issue(rs_issue_int),
      .i_rs_fu_ready(1'b1),
      .o_int_rs_full(int_rs_full),
      .o_rs_empty(rs_empty),
      .o_rs_count(rs_count),

      // MUL_RS
      .o_mul_rs_issue(rs_issue_mul),
      .i_mul_rs_fu_ready(1'b1),
      .o_mul_rs_full(mul_rs_full),
      .o_mul_rs_empty(),
      .o_mul_rs_count(),

      // MEM_RS
      .o_mem_rs_issue(rs_issue_mem),
      .i_mem_rs_fu_ready(1'b1),
      .o_mem_rs_full(mem_rs_full),
      .o_mem_rs_empty(),
      .o_mem_rs_count(),

      // FP_RS
      .o_fp_rs_issue(rs_issue_fp),
      .i_fp_rs_fu_ready(1'b1),
      .o_fp_rs_full(fp_rs_full),
      .o_fp_rs_empty(),
      .o_fp_rs_count(),

      // FMUL_RS
      .o_fmul_rs_issue(rs_issue_fmul),
      .i_fmul_rs_fu_ready(1'b1),
      .o_fmul_rs_full(fmul_rs_full),
      .o_fmul_rs_empty(),
      .o_fmul_rs_count(),

      // FDIV_RS
      .o_fdiv_rs_issue(rs_issue_fdiv),
      .i_fdiv_rs_fu_ready(1'b1),
      .o_fdiv_rs_full(fdiv_rs_full),
      .o_fdiv_rs_empty(),
      .o_fdiv_rs_count(),

      // CSR read data
      .i_csr_read_data(csr_read_data),

      // Store queue memory interface
      .o_sq_mem_write_en(sq_mem_write_en),
      .o_sq_mem_write_addr(sq_mem_write_addr),
      .o_sq_mem_write_data(sq_mem_write_data),
      .o_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .i_sq_mem_write_done(sq_mem_write_done),

      // Load queue memory interface
      .o_lq_mem_read_en(lq_mem_read_en),
      .o_lq_mem_read_addr(lq_mem_read_addr),
      .o_lq_mem_read_size(lq_mem_read_size),
      .i_lq_mem_read_data(lq_mem_read_data),
      .i_lq_mem_read_valid(lq_mem_read_valid),

      // LQ/SQ status
      .o_lq_full (lq_full),
      .o_lq_empty(lq_empty),
      .o_lq_count(lq_count),
      .o_sq_full (sq_full),
      .o_sq_empty(sq_empty),
      .o_sq_count(sq_count),

      // AMO memory interface
      .o_amo_mem_write_en  (amo_mem_write_en),
      .o_amo_mem_write_addr(amo_mem_write_addr),
      .o_amo_mem_write_data(amo_mem_write_data),
      .i_amo_mem_write_done(amo_mem_write_done),

      // Profiling snapshot
      .i_perf_snapshot_capture(perf_snapshot_capture),
      .i_perf_counter_select (wrapper_perf_counter_select),
      .o_perf_counter_data   (wrapper_perf_counter_data)
  );

  // ===========================================================================
  // Dispatch Unit
  // ===========================================================================

  dispatch u_dispatch (
      .i_clk,
      .i_rst_n(rst_n),

      .i_from_id_to_ex(from_id_to_ex),
      .i_valid(id_valid),

      .i_rs1_addr(from_id_to_ex.instruction.source_reg_1),
      .i_rs2_addr(from_id_to_ex.instruction.source_reg_2),
      .i_fp_rs3_addr(from_id_to_ex.instruction.funct7[6:2]),

      .i_frm_csr(frm_csr),

      // ROB
      .o_rob_alloc_req (rob_alloc_req),
      .i_rob_alloc_resp(rob_alloc_resp),

      // RAT lookups
      .o_int_src1_addr(int_src1_addr),
      .o_int_src2_addr(int_src2_addr),
      .o_fp_src1_addr (fp_src1_addr),
      .o_fp_src2_addr (fp_src2_addr),
      .o_fp_src3_addr (fp_src3_addr),

      .i_int_src1(int_src1_lookup),
      .i_int_src2(int_src2_lookup),
      .i_fp_src1 (fp_src1_lookup),
      .i_fp_src2 (fp_src2_lookup),
      .i_fp_src3 (fp_src3_lookup),

      // RAT rename
      .o_rat_alloc_valid(rat_alloc_valid),
      .o_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .o_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .o_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // ROB done-entry bypass
      .i_rob_entry_done(rob_entry_done_dispatch),
      .o_bypass_tag_1  (dispatch_bypass_tag_1),
      .i_bypass_value_1(dispatch_bypass_value_1),
      .o_bypass_tag_2  (dispatch_bypass_tag_2),
      .i_bypass_value_2(dispatch_bypass_value_2),
      .o_bypass_tag_3  (dispatch_bypass_tag_3),
      .i_bypass_value_3(dispatch_bypass_value_3),

      // RS dispatch
      .o_rs_dispatch(rs_dispatch),

      // Checkpoint management
      .i_checkpoint_available(checkpoint_available),
      .i_checkpoint_alloc_id(checkpoint_alloc_id),
      .o_checkpoint_save(checkpoint_save),
      .o_checkpoint_id(checkpoint_id),
      .o_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(from_if_to_pd.ras_checkpoint_tos),
      .i_ras_valid_count(from_if_to_pd.ras_checkpoint_valid_count),
      .o_ras_tos(dispatch_ras_tos),
      .o_ras_valid_count(dispatch_ras_valid_count),
      .o_rob_checkpoint_valid(rob_checkpoint_valid),
      .o_rob_checkpoint_id(rob_checkpoint_id),

      // Resource status
      .i_rob_full(rob_full),
      .i_int_rs_full(int_rs_full),
      .i_mul_rs_full(mul_rs_full),
      .i_mem_rs_full(mem_rs_full),
      .i_fp_rs_full(fp_rs_full),
      .i_fmul_rs_full(fmul_rs_full),
      .i_fdiv_rs_full(fdiv_rs_full),
      .i_lq_full(lq_full),
      .i_sq_full(sq_full),

      // Flush / early-recovery hold
      .i_flush(flush_pipeline),
      .i_hold (early_backend_recovery_hold),

      // Dispatch profiling status
      .o_status(dispatch_status),

      // Stall output
      .o_stall(dispatch_stall)
  );

  // ===========================================================================
  // ROB Bypass Read — read head entry value for CSR write data
  // ===========================================================================
  assign rob_read_tag = head_tag;

  // ===========================================================================
  // Branch Resolution Unit
  // ===========================================================================
  // Branch/jump instructions issue from INT_RS. The ALU shim suppresses CDB
  // broadcast for these ops. Instead, we resolve them here and generate
  // a reorder_buffer_branch_update_t that goes to the ROB.

  // The INT reservation station keeps o_issue.valid free of same-cycle flush
  // gating for timing, so a flushed stage2 entry can still appear valid at the
  // cpu_ooo branch-resolution input for one cycle. That is harmless for the
  // CDB/memory paths that consume tags, but it is not harmless here: a phantom
  // branch issue can fabricate branch_update/BTB writes using wrong-path PCs.
  // Suppress branch/jump resolution whenever a flush is active or a commit-time
  // misprediction is being raised in the same cycle.
  logic suppress_branch_resolution;
  logic branch_issue_is_flushed;
  logic branch_issue_checkpoint_live;
  logic [riscv_pkg::ReorderBufferTagWidth:0] branch_issue_age;
  logic [riscv_pkg::ReorderBufferTagWidth:0] early_flush_age;
  typedef struct packed {
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } correct_branch_commit_capture_t;

  logic [riscv_pkg::ReorderBufferTagWidth:0] commit_flush_age;
  always_comb begin
    branch_issue_checkpoint_live = 1'b1;
    if (rs_issue_int.has_checkpoint) begin
      // Use the registered checkpoint state here to avoid a feedback loop
      // through execute-time checkpoint free.  The owner-tag check still
      // filters out stale/reused checkpoint IDs.
      branch_issue_checkpoint_live =
          checkpoint_in_use[rs_issue_int.checkpoint_id] &&
          (checkpoint_owner_tag[rs_issue_int.checkpoint_id] == rs_issue_int.rob_tag);
    end
  end

  // The INT RS leaves o_issue.valid ungated for one cycle around flushes so a
  // just-flushed stage2 entry can still appear at the branch-resolution input.
  // Suppress only entries that are actually being flushed.  Suppressing all
  // branch resolution during a partial recovery can drop an older surviving
  // branch if it happens to issue in the recovery cycle, leaving its ROB entry
  // permanently unresolved.
  assign branch_issue_age = {1'b0, rs_issue_int.rob_tag} - {1'b0, head_tag};
  assign early_flush_age  = {1'b0, early_mispredict_tag} - {1'b0, head_tag};
  assign commit_flush_age = {1'b0, mispredict_commit_q.tag} - {1'b0, head_tag};

  always_comb begin
    branch_issue_is_flushed = 1'b0;

    if (flush_for_trap || flush_for_mret || fence_i_flush) begin
      branch_issue_is_flushed = rs_issue_int.valid;
    end else if (early_mispredict_active) begin
      // Partial early recovery keeps only entries strictly older than the
      // mispredicting branch.  The flush-tag branch itself has already
      // generated recovery data and must not re-resolve.
      branch_issue_is_flushed = rs_issue_int.valid && (branch_issue_age >= early_flush_age);
    end else if (early_backend_recovery_pending) begin
      branch_issue_is_flushed = rs_issue_int.valid && (branch_issue_age >= early_flush_age);
    end else if (mispredict_recovery_pending) begin
      // Commit-time recovery only fires when the mispredicted branch commits at
      // the ROB head, so there are no older survivors to preserve here. Using
      // a head-relative age compare in this cycle is incorrect because head_tag
      // has already advanced past the mispredicting branch, which can let a
      // just-flushed younger branch re-resolve for one cycle.
      branch_issue_is_flushed = rs_issue_int.valid;
    end
    // NOTE: rob_head_commit_misprediction_candidate is intentionally NOT used
    // here to suppress branch resolution.  Routing the candidate signal through
    // suppress_branch_resolution → is_branch_issue → branch comparison (CARRY8)
    // → branch_update → commit_en created a 16-level combinational chain that
    // was the WNS critical path (-0.739 ns).  Removing it is safe because:
    //   (a) commit_en already has a direct branch_update collision guard that
    //       delays commit when the same branch resolves and commits in one cycle;
    //   (b) resolution writes to entries that will be flushed are harmless;
    //   (c) early_mispredict_fire still gates on the candidate directly.
  end

  assign suppress_branch_resolution = branch_issue_is_flushed;

  logic is_branch_issue;
  assign is_branch_issue = rs_issue_int.valid && branch_issue_checkpoint_live &&
                           !suppress_branch_resolution && (
      rs_issue_int.op == riscv_pkg::BEQ  || rs_issue_int.op == riscv_pkg::BNE  ||
      rs_issue_int.op == riscv_pkg::BLT  || rs_issue_int.op == riscv_pkg::BGE  ||
      rs_issue_int.op == riscv_pkg::BLTU || rs_issue_int.op == riscv_pkg::BGEU ||
      rs_issue_int.op == riscv_pkg::JAL  || rs_issue_int.op == riscv_pkg::JALR);

  logic is_jal_issue, is_jalr_issue;
  assign is_jal_issue  = is_branch_issue && (rs_issue_int.op == riscv_pkg::JAL);
  assign is_jalr_issue = is_branch_issue && (rs_issue_int.op == riscv_pkg::JALR);

  // Map instr_op_e → branch_taken_op_e for branch_jump_unit
  riscv_pkg::branch_taken_op_e branch_op_resolved;
  assign lq_mem_request_fire = lq_mem_request_valid ||
                               (lq_mem_read_en && !sq_mem_write_en && !amo_mem_write_en);
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;

  always_comb begin
    case (rs_issue_int.op)
      riscv_pkg::BEQ:                  branch_op_resolved = riscv_pkg::BREQ;
      riscv_pkg::BNE:                  branch_op_resolved = riscv_pkg::BRNE;
      riscv_pkg::BLT:                  branch_op_resolved = riscv_pkg::BRLT;
      riscv_pkg::BGE:                  branch_op_resolved = riscv_pkg::BRGE;
      riscv_pkg::BLTU:                 branch_op_resolved = riscv_pkg::BRLTU;
      riscv_pkg::BGEU:                 branch_op_resolved = riscv_pkg::BRGEU;
      riscv_pkg::JAL, riscv_pkg::JALR: branch_op_resolved = riscv_pkg::JUMP;
      default:                         branch_op_resolved = riscv_pkg::NULL;
    endcase
  end

  // Branch/jump condition evaluation and target computation
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) u_branch_resolve (
      .i_branch_operation         (branch_op_resolved),
      .i_is_jump_and_link         (is_jal_issue),
      .i_is_jump_and_link_register(is_jalr_issue),
      .i_operand_a                (rs_issue_int.src1_value[XLEN-1:0]),
      .i_operand_b                (rs_issue_int.src2_value[XLEN-1:0]),
      // Dispatch stores the correct pre-computed target in branch_target
      // (jal_target_precomputed for JAL, branch_target_precomputed for branches)
      .i_branch_target_precomputed(rs_issue_int.branch_target),
      .i_jal_target_precomputed   (rs_issue_int.branch_target),
      .i_immediate_i_type         (rs_issue_int.imm),
      .o_branch_taken             (branch_taken_resolved),
      .o_branch_target_address    (branch_target_resolved)
  );

  // Misprediction detection (authoritative — the ROB trusts this flag)
  logic branch_mispredicted;
  always_comb begin
    if (!is_branch_issue) begin
      branch_mispredicted = 1'b0;
    end else if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      // Direction misprediction (taken vs not-taken)
      branch_mispredicted = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 branch_target_resolved != rs_issue_int.predicted_target) begin
      // Target misprediction (both taken but different targets)
      branch_mispredicted = 1'b1;
    end else begin
      branch_mispredicted = 1'b0;
    end
  end

  // Generate branch_update for the ROB
  always_comb begin
    branch_update              = '0;
    // JAL is resolved architecturally at ROB allocation time, so its later
    // branch-unit issue must not write back into a possibly already-committed
    // ROB slot.
    branch_update.valid        = is_branch_issue && !is_jal_issue;
    branch_update.tag          = rs_issue_int.rob_tag;
    branch_update.taken        = branch_taken_resolved;
    branch_update.target       = branch_target_resolved;
    branch_update.mispredicted = branch_mispredicted;
  end

  // Early branch resolution: signals when a branch resolves as correctly
  // predicted.  Used to drop front_end_cf_serialize_stall early.
  assign branch_resolved_correct = branch_update.valid && !branch_update.mispredicted;

  // Direct JALs are architecturally resolved at dispatch/rename time and
  // therefore never enter the unresolved-branch tracker.
  assign branch_unresolved_decrement = branch_resolved_correct;

  // ===========================================================================
  // Early Misprediction Recovery
  // ===========================================================================
  // When a branch resolves as mispredicted, initiate recovery immediately
  // instead of waiting for the branch to reach ROB head and commit.
  // This reduces the mispredict penalty from ~15 cycles to ~2 cycles.
  //
  // Cycle N:   branch_update fires with mispredicted=1 → capture data
  // Cycle N+1: early_mispredict_pending → redirect + RAT restore + backend hold
  // Cycle N+2: early_backend_recovery_pending → backend partial flush + hold

  (* max_fanout = 32 *) logic early_mispredict_capture;
  logic early_mispredict_fire;
  logic early_mispredict_pending;
  logic early_mispredict_active;
  logic early_backend_recovery_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;

  // Captured data from the mispredicting branch
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic early_mispredict_is_compressed;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;

  // Fire when a conditional-branch misprediction is detected at execute time.
  // JALR remains on the older commit-time recovery path for now.
  //
  // Block on:
  // - an existing early-recovery phase (one-at-a-time; missed mispredictions
  //   fall to commit-time recovery)
  // - mispredict_recovery_pending (commit-time recovery in progress)
  // - fence_i_flush (registered 1-cycle full flush pulse)
  //
  // Trap/MRET and same-cycle head-commit misprediction conflicts are masked on
  // the next cycle before redirect / checkpoint-restore / backend-flush. That
  // keeps those high-priority blockers off the wide capture-enable cone.
  //
  // Half-word-aligned branches are safe: the redirect PC (link_addr or
  // branch_target) is computed at dispatch independent of alignment, the
  // epoch-based RAT restore handles tag wraparound, and frontend_state_flush
  // resets the C-extension alignment state machine on the redirect cycle.
  //
  // Multiple unresolved branches are safe: early recovery does a partial
  // flush (keeping entries older than the mispredicting branch) and restores
  // the branch's own checkpoint. Older branches retain their checkpoints
  // and can resolve normally or trigger their own recovery later. The
  // one-at-a-time guard (!early_mispredict_pending, !early_backend_recovery_
  // pending) prevents overlapping recoveries.
  logic [riscv_pkg::ReorderBufferTagWidth:0] early_branch_age;
  assign early_branch_age = {1'b0, branch_update.tag} - {1'b0, head_tag};
  assign early_mispredict_capture = branch_update.valid && branch_update.mispredicted &&
                                    !early_mispredict_pending &&
                                    !early_backend_recovery_pending;
  assign early_mispredict_fire = early_mispredict_capture &&
                                  rs_issue_int.has_checkpoint && !is_jalr_issue &&
                                  !fence_i_flush && !mispredict_recovery_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) early_mispredict_pending <= 1'b0;
    else early_mispredict_pending <= early_mispredict_fire;
  end

  assign early_mispredict_active = early_mispredict_pending &&
                                   !mispredict_recovery_pending &&
                                   !trap_taken_reg && !mret_taken_reg &&
                                   !fence_i_flush;

  // Delay the high-fanout backend partial flush one cycle behind the fast
  // frontend redirect and RAT restore.
  always_ff @(posedge i_clk) begin
    if (i_rst) early_backend_recovery_pending <= 1'b0;
    else if (flush_for_trap || flush_for_mret || fence_i_flush) begin
      early_backend_recovery_pending <= 1'b0;
    end else begin
      early_backend_recovery_pending <= early_mispredict_active;
    end
  end

  // The backend partial flush already trails the fast redirect by one cycle,
  // so re-register the flush tag locally instead of reusing the N-cycle
  // capture register across the whole Tomasulo flush network.
  always_ff @(posedge i_clk) begin
    if (early_mispredict_active) begin
      early_backend_flush_tag <= early_mispredict_tag;
    end
  end

  // Capture recovery data on the fire cycle
  always_ff @(posedge i_clk) begin
    if (early_mispredict_capture) begin
      // Debug display disabled for performance
      // $display("[EARLY_FIRE] t=%0t tag=%0d pc=0x%08x age=%0d head=%0d ckpt=%0d redirect=0x%08x taken=%0d",
      //     $time, branch_update.tag, rs_issue_int.pc, early_branch_age, head_tag,
      //     rs_issue_int.has_checkpoint,
      //     branch_taken_resolved ? branch_target_resolved : rs_issue_int.link_addr,
      //     branch_taken_resolved);
      early_mispredict_tag <= branch_update.tag;

      // Redirect PC: taken → actual target, not taken → fallthrough (link_addr)
      early_mispredict_redirect_pc <= branch_taken_resolved ?
          branch_target_resolved : rs_issue_int.link_addr;

      // Early recovery only fires for checkpointed conditional branches.
      early_mispredict_checkpoint_id <= rs_issue_int.checkpoint_id;

      // BTB update data
      early_mispredict_pc <= rs_issue_int.pc;
      early_mispredict_branch_target <= branch_target_resolved;
      early_mispredict_branch_taken <= branch_taken_resolved;
      early_mispredict_is_compressed <= (rs_issue_int.link_addr == rs_issue_int.pc + 32'd2);
    end
  end


  // Mark the branch as early-recovered before it can commit. The delayed
  // backend flush uses a separate qualifier so speculative structures can
  // still distinguish early recovery from commit-time flush-after-head.
  logic early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  assign early_recovery_en  = early_mispredict_active;
  assign early_recovery_tag = early_mispredict_tag;

  // Hold dispatch/issue/dequeue across both early-recovery phases. Phase 1
  // still uses flush_pipeline to redirect and kill wrong-path frontend state;
  // phase 2 must behave like a backpressure bubble instead of a second
  // frontend flush so the redirected target instruction stream is preserved.
  logic early_backend_recovery_hold;
  assign early_backend_recovery_hold = early_mispredict_active || early_backend_recovery_pending;

  // ===========================================================================
  // Commit-Time Actions
  // ===========================================================================

  // --- Regfile writes from ROB commit ---
  // CSR instructions use o_csr_read_data_comb (combinational, same cycle) so
  // the rd write can happen on the same commit cycle as non-CSR instructions.
  always_comb begin
    int_rf_write_enable = 1'b0;
    int_rf_write_addr   = '0;
    int_rf_write_data   = '0;
    fp_rf_write_enable  = 1'b0;
    fp_rf_write_addr    = '0;
    fp_rf_write_data    = '0;

    if (rob_commit_valid && rob_commit.dest_valid && !rob_commit.exception) begin
      if (rob_commit.is_csr) begin
        // CSR: write old CSR value (combinational read) to rd
        int_rf_write_enable = 1'b1;
        int_rf_write_addr   = rob_commit.dest_reg;
        int_rf_write_data   = csr_read_data_comb;
      end else if (rob_commit.dest_rf == 1'b0) begin
        // INT destination
        int_rf_write_enable = 1'b1;
        int_rf_write_addr   = rob_commit.dest_reg;
        int_rf_write_data   = rob_commit.value[XLEN-1:0];
      end else begin
        // FP destination
        fp_rf_write_enable = 1'b1;
        fp_rf_write_addr   = rob_commit.dest_reg;
        fp_rf_write_data   = rob_commit.value;
      end
    end
  end

  // --- Instruction retire signal ---
  assign o_vld = rob_commit_valid && !rob_commit.exception;

  // --- PC validity ---
  assign o_pc_vld = o_vld;

  // ===========================================================================
  // Commit-Bus Pipeline Register
  // ===========================================================================
  // Register the ROB commit output to break the commit_en → CSR/regfile
  // critical path (mispredict_recovery_pending → ROB alloc → commit_en →
  // commit bus → CSR read → regfile write, 18 levels).
  // Misprediction/branch detection uses narrow raw ROB status bits to avoid
  // adding latency to flush initiation while keeping the full commit payload
  // off the branch-recovery timing cone.
  // The wrapper already provides a registered observation port for commit.
  assign rob_commit_valid = rob_commit.valid;

  // DEBUG: verify early recovery redirect_pc matches commit-time redirect_pc
  // (Disabled for performance — re-enable for debugging.)
  // always @(posedge i_clk) begin
  //   if (!i_rst && rob_commit_comb.valid && rob_commit_comb.early_recovered &&
  //       rob_commit_comb.misprediction) begin
  //     $display("[EARLY_VERIFY] t=%0t tag=%0d commit_redirect=0x%08x early_redirect=0x%08x %s",
  //         $time, rob_commit_comb.tag, rob_commit_comb.redirect_pc,
  //         early_mispredict_redirect_pc,
  //         (rob_commit_comb.redirect_pc == early_mispredict_redirect_pc) ? "MATCH" : "MISMATCH!");
  //   end
  //   if (!i_rst && commit_is_misprediction) begin
  //     $display("[COMMIT_MISPREDICT] t=%0t tag=%0d pc=0x%08x redirect=0x%08x",
  //         $time, rob_commit_comb.tag, rob_commit_comb.pc, rob_commit_comb.redirect_pc);
  //   end
  // end

  // ===========================================================================
  // Misprediction & Flush Controller
  // ===========================================================================
  // Suppress commit-time misprediction only for the SAME branch that early
  // recovery is currently handling.  The old blanket !early_mispredict_pending
  // gate would suppress mispredictions from DIFFERENT branches that happen
  // to commit on the same cycle, silently dropping their recovery.
  //
  // The same-cycle race: rob_early_recovered hasn't been written yet when
  // early_mispredict_pending first fires, so check the tag explicitly.
  logic commit_is_misprediction;
  assign commit_is_misprediction = rob_commit_misprediction_raw &&
                                    !((early_mispredict_active ||
                                       early_backend_recovery_pending) &&
                                      head_tag == early_mispredict_tag);

  // Register only the mispredict recovery fields that are consumed one cycle
  // later. Capturing the entire commit struct here needlessly drags unrelated
  // head metadata and payload bits onto the recovery timing cone.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) mispredict_recovery_pending <= 1'b0;
    else mispredict_recovery_pending <= commit_is_misprediction;
  end

  // Misprediction data capture (no reset - gated by commit_is_misprediction)
  always_ff @(posedge i_clk) begin
    if (commit_is_misprediction) begin
      mispredict_commit_q.tag            <= rob_commit_comb.tag;
      mispredict_commit_q.has_checkpoint <= rob_commit_comb.has_checkpoint;
      mispredict_commit_q.checkpoint_id  <= rob_commit_comb.checkpoint_id;
      mispredict_commit_q.redirect_pc    <= rob_commit_comb.redirect_pc;
      mispredict_commit_q.pc             <= rob_commit_comb.pc;
      mispredict_commit_q.branch_target  <= rob_commit_comb.branch_target;
      mispredict_commit_q.branch_taken   <= rob_commit_comb.branch_taken;
      mispredict_commit_q.is_branch      <= rob_commit_comb.is_branch;
      mispredict_commit_q.is_call        <= rob_commit_comb.is_call;
      mispredict_commit_q.is_return      <= rob_commit_comb.is_return;
      mispredict_commit_q.is_jal         <= rob_commit_comb.is_jal;
      mispredict_commit_q.is_jalr        <= rob_commit_comb.is_jalr;
      mispredict_commit_q.is_compressed  <= rob_commit_comb.is_compressed;
    end
  end

  // FENCE.I commits before its flush pulse reaches IF. Capture the precise
  // fallthrough PC so the front-end can restart from the architectural next
  // instruction instead of from speculative fetch state that was already ahead.
  always_ff @(posedge i_clk) begin
    if (rob_commit_comb.valid && rob_commit_comb.is_fence_i) begin
      fence_i_target_pc <= rob_commit_comb.pc + (rob_commit_comb.is_compressed ? 32'd2 : 32'd4);
    end
  end

  // Register correctly-predicted branch commit for BTB update + checkpoint free.
  // Breaks the rob_exception → commit_en → BTB write critical path (same pattern
  // as mispredict_commit_q above).
  logic correct_branch_commit_pending;
  correct_branch_commit_capture_t correct_branch_commit_q;

  // Correct branch: predicted correctly AND not early-recovered (which was a misprediction)
  wire commit_is_correct_branch = rob_commit_correct_branch_raw;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_commit_pending <= 1'b0;
    else correct_branch_commit_pending <= commit_is_correct_branch;
  end

  // Correct branch data capture (no reset - gated by commit_is_correct_branch)
  always_ff @(posedge i_clk) begin
    if (commit_is_correct_branch) begin
      correct_branch_commit_q.tag           <= rob_commit_comb.tag;
      correct_branch_commit_q.checkpoint_id <= rob_commit_comb.checkpoint_id;
      correct_branch_commit_q.pc            <= rob_commit_comb.pc;
      correct_branch_commit_q.branch_target <= rob_commit_comb.branch_target;
      correct_branch_commit_q.branch_taken  <= rob_commit_comb.branch_taken;
      correct_branch_commit_q.is_branch     <= rob_commit_comb.is_branch;
      correct_branch_commit_q.is_jal        <= rob_commit_comb.is_jal;
      correct_branch_commit_q.is_jalr       <= rob_commit_comb.is_jalr;
      correct_branch_commit_q.is_compressed <= rob_commit_comb.is_compressed;
    end
  end

  // Flush pipeline on the redirecting early-recovery phase, registered
  // misprediction recovery, trap, MRET, or FENCE.I. The delayed backend
  // recovery phase is a hold-only bubble, not a second frontend flush.
  always_comb begin
    // fence_i_flush is already a registered 1-cycle pulse from the ROB, one
    // cycle after FENCE.I commits. Gate the front-end flush directly from that
    // pulse so dispatch cannot allocate into the same cycle as a full flush.
    flush_pipeline = early_mispredict_active || mispredict_recovery_pending ||
                     flush_for_trap ||
                     flush_for_mret || fence_i_flush;
  end

  // IF internal state cleanup can lag trap/MRET by one cycle, but keep
  // mispredict and FENCE.I cleanup on their existing timing.
  assign frontend_state_flush =
      early_mispredict_active || mispredict_recovery_pending ||
      fence_i_flush || trap_taken_reg || mret_taken_reg;

  // Tomasulo flush:
  //   - Early recovery uses flush_en + flush_tag because the mispredicted
  //     branch is still in-flight and older survivors must be preserved.
  //   - Commit-time misprediction recovery still emits flush_en + flush_tag,
  //     but also raises commit_recovery_flush_after_head so the backend can
  //     treat that case as "flush all speculative state younger than head"
  //     without rediscovering it from head/tag compares.
  //   - Trap/MRET/FENCE.I use flush_all only.
  always_comb begin
    flush_en  = 1'b0;
    flush_tag = '0;
    flush_all = 1'b0;

    if (trap_taken_reg || mret_taken_reg) begin
      flush_all = 1'b1;
    end else if (early_backend_recovery_pending) begin
      flush_en  = 1'b1;
      flush_tag = early_backend_flush_tag;
    end else if (mispredict_recovery_pending) begin
      flush_en  = 1'b1;
      flush_tag = mispredict_commit_q.tag;
    end else if (fence_i_flush) begin
      flush_all = 1'b1;
    end
  end

  // Commit-time mispredict recovery is already a registered 1-cycle pulse from
  // the retiring ROB head, so downstream speculative structures do not need to
  // rediscover "flush after head" from head/tag arithmetic.
  assign commit_recovery_flush_after_head = mispredict_recovery_pending;

  // flush_after_head: commit-time mispredict recovery retired the offending
  // branch at the ROB head in the previous cycle. The checkpoint mask uses
  // this to free ALL in-use checkpoints.
  logic flush_after_head;
  assign flush_after_head = commit_recovery_flush_after_head;

  // Checkpoint restore on misprediction (early or commit-time)
  always_comb begin
    if (flush_all) begin
      checkpoint_restore = 1'b0;
      checkpoint_restore_id = '0;
      checkpoint_restore_reclaim_all = 1'b0;
    end else if (early_mispredict_active) begin
      // Early recovery: restore checkpoint only
      checkpoint_restore = 1'b1;
      checkpoint_restore_id = early_mispredict_checkpoint_id;
      checkpoint_restore_reclaim_all = 1'b0;
    end else if (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint) begin
      // Commit-time fallback
      checkpoint_restore = 1'b1;
      checkpoint_restore_id = mispredict_commit_q.checkpoint_id;
      checkpoint_restore_reclaim_all = 1'b0;
    end else begin
      checkpoint_restore = 1'b0;
      checkpoint_restore_id = '0;
      checkpoint_restore_reclaim_all = 1'b0;
    end
  end

  // Checkpoint reclaim mask for RAT (unused — reclaim_all is 0)
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_reclaim_mask;
  assign checkpoint_reclaim_mask = '0;

  // Bulk flush free mask: register on flush_en, apply one cycle later.
  // When flush_after_head, free ALL in-use checkpoints (the age comparison
  // wraps and misses everything).  Otherwise, free only younger checkpoints.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) checkpoint_flush_free_mask_q <= '0;
    else if (flush_en)
      checkpoint_flush_free_mask_q <= flush_after_head ? checkpoint_in_use
                                                       : checkpoint_younger_than_flush;
    else checkpoint_flush_free_mask_q <= '0;
  end
  assign checkpoint_flush_free_mask = checkpoint_flush_free_mask_q;

  // Checkpoint free: early recovery or guarded branch commit fallback.
  // Flush-time reclaim is handled by
  // checkpoint_flush_free_mask one cycle after flush_en.
  logic correct_branch_commit_checkpoint_live;
  always_comb begin
    correct_branch_commit_checkpoint_live = 1'b0;
    if (correct_branch_commit_pending) begin
      correct_branch_commit_checkpoint_live =
          checkpoint_in_use[correct_branch_commit_q.checkpoint_id] &&
          (checkpoint_owner_tag[correct_branch_commit_q.checkpoint_id] ==
           correct_branch_commit_q.tag);
    end
  end

  always_comb begin
    checkpoint_free    = 1'b0;
    checkpoint_free_id = '0;

    if (flush_all) begin
      checkpoint_free    = 1'b0;
      checkpoint_free_id = '0;
    end else if (early_backend_recovery_pending) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = early_mispredict_checkpoint_id;
    end else if (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = mispredict_commit_q.checkpoint_id;
    end else if (correct_branch_commit_checkpoint_live) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = correct_branch_commit_q.checkpoint_id;
    end
  end

  // ===========================================================================
  // Synthesize from_ex_comb for IF Stage
  // ===========================================================================
  // The IF stage expects from_ex_comb_t for branch redirect, BTB update,
  // and RAS restore. In OOO mode, these come from ROB commit.

  always_comb begin
    from_ex_comb_synth = '0;

    if (early_mispredict_active) begin
      // Early misprediction recovery: redirect PC and update BTB
      from_ex_comb_synth.branch_taken                       = 1'b1;
      from_ex_comb_synth.branch_target_address              = early_mispredict_redirect_pc;

      // Early recovery only handles checkpointed conditional branches, so the
      // BTB update and RAS restore are unconditional on this path.
      from_ex_comb_synth.btb_update                         = 1'b1;
      from_ex_comb_synth.btb_update_pc                      = early_mispredict_pc;
      from_ex_comb_synth.btb_update_target                  = early_mispredict_branch_target;
      from_ex_comb_synth.btb_update_taken                   = early_mispredict_branch_taken;
      from_ex_comb_synth.btb_update_compressed              = early_mispredict_is_compressed;
      from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;

      from_ex_comb_synth.ras_misprediction                  = 1'b1;
      from_ex_comb_synth.ras_restore_tos                    = restored_ras_tos;
      from_ex_comb_synth.ras_restore_valid_count            = restored_ras_valid_count;
    end else if (mispredict_recovery_pending) begin
      // Commit-time fallback misprediction recovery.
      from_ex_comb_synth.branch_taken          = 1'b1;
      from_ex_comb_synth.branch_target_address = mispredict_commit_q.redirect_pc;

      if (mispredict_commit_q.is_branch && !mispredict_commit_q.is_jalr) begin
        // BTB update for conditional branches AND JAL. Previously JAL was
        // excluded, causing every execution of a BTB-cold JAL to mispredict
        // (~6500 total in CoreMark). Including JAL trains the BTB so only
        // the first execution of each unique JAL site mispredicts (~100).
        from_ex_comb_synth.btb_update                         = 1'b1;
        from_ex_comb_synth.btb_update_pc                      = mispredict_commit_q.pc;
        from_ex_comb_synth.btb_update_target                  = mispredict_commit_q.branch_target;
        from_ex_comb_synth.btb_update_taken                   = mispredict_commit_q.branch_taken;
        from_ex_comb_synth.btb_update_compressed              = mispredict_commit_q.is_compressed;
        from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;
      end

      if (mispredict_commit_q.has_checkpoint) begin
        from_ex_comb_synth.ras_misprediction       = 1'b1;
        from_ex_comb_synth.ras_restore_tos         = restored_ras_tos;
        from_ex_comb_synth.ras_restore_valid_count = restored_ras_valid_count;
        if (mispredict_commit_q.is_return) begin
          from_ex_comb_synth.ras_pop_after_restore = 1'b1;
        end else if (mispredict_commit_q.is_call) begin
          from_ex_comb_synth.ras_push_after_restore = 1'b1;
          from_ex_comb_synth.ras_push_address_after_restore = mispredict_commit_q.pc +
              (mispredict_commit_q.is_compressed ? 32'd2 : 32'd4);
        end
      end
    end else if (correct_branch_commit_pending) begin
      // Correctly-predicted branch commit: update BTB (no PC redirect).
      // Uses registered commit data to break rob_exception → BTB critical path.
      if (correct_branch_commit_q.is_branch && !correct_branch_commit_q.is_jal &&
          !correct_branch_commit_q.is_jalr) begin
        from_ex_comb_synth.btb_update = 1'b1;
        from_ex_comb_synth.btb_update_pc = correct_branch_commit_q.pc;
        from_ex_comb_synth.btb_update_target = correct_branch_commit_q.branch_target;
        from_ex_comb_synth.btb_update_taken = correct_branch_commit_q.branch_taken;
        from_ex_comb_synth.btb_update_compressed = correct_branch_commit_q.is_compressed;
        from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;
      end

    end
  end

  // ===========================================================================
  // Memory Interface
  // ===========================================================================
  // Route LQ/SQ memory requests to the external data memory port.
  // Priority: SQ writes > queued LQ reads > AMO writes
  // The L0 cache is inside the tomasulo_wrapper (lq_l0_cache).

  always_comb begin
    // Load queue memory read. Bypass the one-entry request register when the
    // port is already free; fall back to the queued copy only when a store
    // or AMO held the port in the previous cycle.
    o_data_mem_read_enable = !sq_mem_write_en && !amo_mem_write_en &&
                             (lq_mem_request_valid || lq_mem_read_en);

    o_data_mem_addr = sq_mem_write_en ? sq_mem_write_addr :
                      amo_mem_write_en ? amo_mem_write_addr :
                      o_data_mem_read_enable ? lq_mem_request_addr_eff : '0;

    o_data_mem_wr_data = sq_mem_write_en ? sq_mem_write_data :
                         amo_mem_write_en ? amo_mem_write_data : '0;
    o_data_mem_per_byte_wr_en = sq_mem_write_en ? sq_mem_write_byte_en :
                                amo_mem_write_en ? 4'b1111 : 4'b0000;

    sq_mem_write_done_comb = sq_mem_write_en;
    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en;

    o_mmio_load_addr = lq_mem_request_addr_eff;
    o_mmio_load_valid = o_data_mem_read_enable &&
                        (lq_mem_request_addr_eff >= MMIO_ADDR[XLEN-1:0]) &&
                        (lq_mem_request_addr_eff < (MMIO_ADDR[XLEN-1:0] +
                                                   MMIO_SIZE_BYTES[XLEN-1:0]));
  end

  // SQ write done: register to align with write_outstanding in the SQ
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_mem_write_done <= 1'b0;
      lq_mem_request_valid <= 1'b0;
    end else begin
      sq_mem_write_done <= sq_mem_write_done_comb;

      if (lq_mem_request_valid) begin
        // Hold the queued load request until stores/AMOs stop owning the port.
        if (!sq_mem_write_en && !amo_mem_write_en) begin
          lq_mem_request_valid <= 1'b0;
        end
      end else if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en)) begin
        lq_mem_request_valid <= 1'b1;
      end
    end
  end

  // Capture the blocked load request so it can retry once the store/AMO port
  // conflict clears. Unblocked loads bypass this register entirely.
  always_ff @(posedge i_clk) begin
    if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en)) begin
      lq_mem_request_addr <= lq_mem_read_addr;
    end
  end

  // Load data always comes from external memory
  assign lq_mem_read_data = i_data_mem_rd_data;

  // Memory read valid: 1-cycle latency from when the queued load request
  // actually reaches the external memory/MMIO port.
  logic mem_read_pending;
  logic lq_mem_read_accepted;
  assign lq_mem_read_accepted = o_data_mem_read_enable;
  always_ff @(posedge i_clk) begin
    if (i_rst) mem_read_pending <= 1'b0;
    else mem_read_pending <= lq_mem_read_accepted;
  end
  assign lq_mem_read_valid = mem_read_pending;

  // MMIO read pulse
  assign o_mmio_read_pulse = lq_mem_read_accepted &&
                             (o_data_mem_addr >= MMIO_ADDR[XLEN-1:0]) &&
                             (o_data_mem_addr < (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  // ===========================================================================
  // CSR File
  // ===========================================================================
  // CSR operations are serialized: the ROB waits for the CSR at head,
  // then signals csr_start. The CSR file performs the read/write,
  // then signals csr_done.

  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mtvec, csr_mepc;
  logic csr_mstatus_mie_direct;

  // CSR execution happens at commit time (serialized by ROB).
  // The ALU shim passes through the rs1/imm value as the CDB result.
  // At commit, the value is available in rob_commit.value.
  assign csr_commit_fire = rob_commit_valid && rob_commit.is_csr && !rob_commit.exception;

  // CSR write data: for register ops (CSRRW/CSRRS/CSRRC), the ALU shim
  // stored rs1 in rob_commit.value. For immediate ops (CSRRWI/CSRRSI/CSRRCI),
  // the ALU shim stored zero_extend(csr_imm) in rob_commit.value.
  logic [XLEN-1:0] csr_write_data_from_commit;
  assign csr_write_data_from_commit = rob_commit.value[XLEN-1:0];

  csr_file #(
      .XLEN(XLEN)
  ) csr_file_inst (
      .i_clk,
      .i_rst,
      .i_csr_read_enable(csr_commit_fire),
      .i_csr_address(rob_commit.csr_addr),
      .i_csr_op(rob_commit.csr_op),
      .i_csr_write_data(csr_write_data_from_commit),
      .i_csr_write_enable(csr_commit_fire),
      .o_csr_read_data(csr_read_data),
      .o_csr_read_data_comb(csr_read_data_comb),
      .i_instruction_retired(o_vld && !trap_taken),
      .i_interrupts(i_interrupts),
      .i_mtime(i_mtime),
      .i_trap_taken(trap_taken),
      .i_trap_pc(rob_trap_pc),
      .i_trap_cause({{(XLEN - $bits(rob_trap_cause)) {1'b0}}, rob_trap_cause}),
      .i_trap_value('0),
      .i_mret_taken(mret_taken),
      .o_mstatus(csr_mstatus),
      .o_mie(csr_mie),
      .o_mtvec(csr_mtvec),
      .o_mepc(csr_mepc),
      .o_mstatus_mie_direct(csr_mstatus_mie_direct),
      // FP flags: accumulated from ROB commit
      .i_fp_flags(rob_commit.fp_flags),
      .i_fp_flags_valid(rob_commit_valid && rob_commit.has_fp_flags && !rob_commit.exception),
      .i_fp_flags_wb_valid(rob_commit_valid && rob_commit.has_fp_flags),
      .i_fp_flags_ma('0),
      .i_fp_flags_ma_valid(1'b0),
      .o_frm(frm_csr),
      .o_perf_counter_select(perf_counter_select),
      .o_perf_snapshot_capture(perf_snapshot_capture),
      .i_perf_counter_data(perf_counter_data),
      .i_perf_counter_count(perf_counter_count)
  );

  // CSR done acknowledgment — 1-cycle delay to match CSR file read latency.
  // csr_start fires on cycle N (ROB enters SERIAL_CSR_EXEC), csr_done_ack
  // fires on cycle N+1, allowing the ROB to commit.
  logic csr_done_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) csr_done_q <= 1'b0;
    else csr_done_q <= csr_start;
  end
  assign csr_done_ack = csr_done_q;

  // MEPC for MRET
  assign mepc_value = csr_mepc;

  // ===========================================================================
  // Trap Unit
  // ===========================================================================
  // Handles exceptions from ROB commit and external interrupts.

  // Interrupt pending signal — raw pending without MIE gate.
  // Per RISC-V spec, WFI wakes on ANY pending interrupt, even if masked.
  // The trap unit separately checks MIE to decide whether to take the trap.
  assign interrupt_pending = i_interrupts.meip || i_interrupts.mtip || i_interrupts.msip;

  logic [XLEN-1:0] trap_target_internal, trap_pc_internal;
  logic [XLEN-1:0] trap_cause_internal, trap_value_internal;

  trap_unit #(
      .XLEN(XLEN)
  ) trap_unit_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_stall(1'b0),  // OOO: no stall for trap check
      .i_mstatus(csr_mstatus),
      .i_mie(csr_mie),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      .i_interrupts(i_interrupts),
      // Exception from ROB commit
      .i_exception_valid(trap_pending),
      .i_exception_cause({{(XLEN - $bits(rob_trap_cause)) {1'b0}}, rob_trap_cause}),
      .i_exception_tval('0),
      .i_exception_pc(rob_trap_pc),
      .i_mret_in_ex(mret_start),
      .i_wfi_in_ex(1'b0),  // WFI handled by ROB serialization
      .o_trap_taken(trap_taken),
      .o_mret_taken(mret_taken),
      .o_trap_target(trap_target),
      .o_trap_pc(trap_pc_internal),
      .o_trap_cause(trap_cause_internal),
      .o_trap_value(trap_value_internal),
      .o_stall_for_wfi()  // WFI stall handled at ROB head
  );

  assign flush_for_trap = trap_taken;
  assign flush_for_mret = mret_taken;

  // Acknowledge trap/mret to ROB using REGISTERED versions to break the
  // combinational feedback: rob_valid → o_mret_start → trap_unit →
  // mret_taken → i_mret_done → serial FSM → commit_en → CSR → regfile.
  // The ROB's serial FSM stays in TRAP_WAIT/MRET_EXEC one extra cycle.
  assign rob_trap_taken_ack = trap_taken_reg;
  assign mret_done_ack = mret_taken_reg;

  // ===========================================================================
  // Profiling Counter Aggregation
  // ===========================================================================
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
                      !(csr_in_flight || serializing_alloc_fire) &&
                      !front_end_cf_serialize_stall &&
                      !dispatch_status.dispatch_valid)
    };
    perf_top_inc[PerfFlushRecovery] = {{63{1'b0}}, flush_pipeline};
    perf_top_inc[PerfPostFlushHoldoff] = {{63{1'b0}}, (post_flush_holdoff_q != 2'd0)};
    perf_top_inc[PerfCsrSerialize] = {{63{1'b0}}, (csr_in_flight || serializing_alloc_fire)};
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
    perf_counter_data = '0;
    if (perf_counter_select_q < PerfTopCounterCountSel) begin
      perf_counter_data = perf_top_snapshot[perf_counter_select_q[4:0]];
    end else if (perf_counter_select_q < PerfCounterCountSel) begin
      perf_counter_data = wrapper_perf_counter_data;
    end
  end

  // ===========================================================================
  // Reset Done
  // ===========================================================================
  // Reset done when L0 cache (inside tomasulo_wrapper) finishes clearing.
  // For now, use a simple counter.
  logic [7:0] rst_counter;
  always_ff @(posedge i_clk) begin
    if (i_rst) rst_counter <= '0;
    else if (!o_rst_done) rst_counter <= rst_counter + 8'd1;
  end
  assign o_rst_done = (rst_counter == 8'hFF);

endmodule : cpu_ooo
