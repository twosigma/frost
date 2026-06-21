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
 * Integrates the IF/PD/ID front-end with Tomasulo-based out-of-order execution.
 *
 * Pipeline structure:
 *   IF → PD → ID → DISPATCH → [OOO execution via Tomasulo] → COMMIT
 *
 * Regfile and CSR writes retire through ROB commit. Branch/BTB/RAS recovery
 * comes from early branch resolution or ROB commit, and front-end stalls come
 * from dispatch/back-end back-pressure.
 */

module cpu_ooo #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C,
    // Cached memory tier (high-address region). Loads/stores to [CACHED_BASE,
    // CACHED_BASE+CACHED_SIZE_BYTES) are served by the cache hierarchy with
    // handshake (variable-latency) completion; the low BRAM range + MMIO stay
    // 1-cycle.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,
    // Instruction memory interface
    output logic [XLEN-1:0] o_pc,
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    input logic i_instr_bank_sel_r,  // Fetch-word parity (for spanning select)
    // Fetch window valid (see if_stage).  Tie 1 for fixed 1-cycle providers.
    input logic i_instr_valid,
    // Stall-replay bundle consumed this cycle (see if_stage) -- the fetch
    // provider counts it as a served cycle for its owed-ask tracking.
    output logic o_fetch_replay_consume,
    // Front-end pipeline stall (pipeline_ctrl.stall): the fetch provider
    // withholds publish-valid and holds its owed ask while this is high so a
    // window the stalled decode cannot consume is never presented.
    output logic o_pipeline_stall,
    // FENCE.I support: the cache-sync handshake (request held while the ROB
    // serializer stalls the fence at the head; done is a level while the
    // request is high) and the committed-fence flush pulse that drops the
    // fetch provider's buffered lines.
    output logic o_fence_i_sync_req,
    input logic i_fence_i_sync_done,
    output logic o_fence_i_flush,
    // Data memory interface
    input logic [XLEN-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    // BRAM-only byte-write-enable. Identical to o_data_mem_per_byte_wr_en
    // except MMIO-targeted stores are masked out at the SQ/AMO source using
    // their registered is_mmio flag. Breaks the issued_idx → WEA timing path
    // by keeping the address-range MMIO check out of the BRAM write-enable
    // combinational cone. Peripherals still consume the unmasked signal so
    // MMIO writes remain visible to UART/FIFO/timer logic.
    output logic [3:0] o_data_mem_bram_byte_wr_en,
    output logic o_data_mem_read_enable,
    // Cached tier (high-address region). Tier-routed write/read requests
    // (already qualified by is_cached in the router) plus the handshake
    // completion inputs from the cached_tier_adapter.
    output logic [3:0] o_data_mem_cached_byte_wr_en,
    // Cached-tier write data: SQ-store drain data, or the AMO new value on the
    // single cycle a cached AMO read-modify-write is launched to the adapter.
    // Driven by the router, which owns the SQ-vs-AMO cached-write mux. The mux
    // sits on the cached-only write-data path (not the wide BRAM write-data
    // cascade that was the old post-opt timing offender), and the AMO ALU cone
    // only reaches it through the rare, ROB-head-serialized cached AMO.
    output logic [XLEN-1:0] o_data_mem_cached_wr_data,
    output logic o_data_mem_cached_read_enable,
    input logic [XLEN-1:0] i_cached_read_data,
    input logic i_cached_read_valid,
    input logic i_cached_write_done,
    input logic i_cached_write_inflight,
    output logic o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic o_mmio_load_valid,
    output logic o_mmio_fifo0_read_pulse,
    output logic o_mmio_fifo1_read_pulse,
    output logic o_mmio_uart_rx_ready_pulse,
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
  logic dispatch_flush;
  logic full_flush_side_effect_kill;
  logic flush_for_trap;
  logic flush_for_mret;
  riscv_pkg::dispatch_status_t dispatch_status;

  // Top-level perf-counter interface. The counters and aggregation logic live
  // in perf_counter_aggregator; these signals cross its boundary: selector and
  // snapshot pulse from the CSR file, wrapper counter data from the
  // tomasulo_wrapper, and the muxed result/count back to the CSR read port.
  logic [7:0] perf_counter_select;
  logic perf_snapshot_capture;
  logic [63:0] perf_counter_data_q;
  logic [31:0] perf_counter_count;
  logic [7:0] wrapper_perf_counter_select;
  logic [63:0] wrapper_perf_counter_data;

  // CSR dispatch fence: the CDB carries rs1 (write operand) for CSR ops,
  // not the CSR read result (which is only available at commit). Stall
  // dispatch after a CSR until it commits so no dependent instruction
  // picks up the wrong CDB value.
  logic csr_in_flight;
  logic csr_wb_pending;
  localparam int unsigned BranchInFlightCountWidth = $clog2(riscv_pkg::ReorderBufferDepth + 1);
  logic [BranchInFlightCountWidth-1:0] branch_in_flight_count;
  // Front-end control-flow hints driven by frontend_validity_tracker and
  // consumed by the pipeline-control prediction/serialization logic + perf.
  // (The remaining unpredicted/has-control-flow intermediates are internal to
  // frontend_validity_tracker.)
  logic front_end_indirect_control_flow_pending;
  logic pd_unpredicted_control_flow;
  logic id_unpredicted_control_flow;
  logic prediction_fence_branch;
  logic prediction_fence_jal;
  logic prediction_fence_indirect;
  logic disable_branch_prediction_ooo;
  (* max_fanout = 32 *) logic serializing_alloc_fire;
  logic csr_commit_fire;  // forward declaration; driven below in CSR section
  logic branch_resolved_correct;  // branch resolved correctly at execute time
  logic branch_unresolved_decrement;  // resolve event for unresolved counter

  // Pipeline-control outputs consumed by other submodules (re-declared here as
  // wires; the producing logic lives in ooo_pipeline_control). The in-flight
  // counters and prediction-fence intermediates are internal to that module.
  logic front_end_cf_serialize_stall;
  logic stall_q;
  logic id_stall_q;
  logic replay_after_dispatch_stall_q;
  logic replay_after_serialize_stall_q;
  logic [1:0] post_flush_holdoff_q;
  logic trap_taken_reg, mret_taken_reg;
  logic sq_committed_empty;  // committed-but-unwritten stores pending (drain gate)
  logic trap_drain_wait;
  logic [XLEN-1:0] trap_target_reg;

  ooo_pipeline_control #(
      .XLEN(XLEN)
  ) ooo_pipeline_control_inst (
      .i_clk,
      .i_rst,
      .i_rob_alloc_req(rob_alloc_req),
      .i_rob_checkpoint_valid(rob_checkpoint_valid),
      .i_csr_commit_fire(csr_commit_fire),
      .i_correct_branch_commit_pending(correct_branch_commit_pending),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_mispredict_commit_q(mispredict_commit_q),
      .i_rob_commit(rob_commit),
      .i_trap_taken(trap_taken),
      .i_mret_taken(mret_taken),
      .i_trap_target(trap_target),
      .i_dispatch_stall(dispatch_stall),
      .i_csr_wb_pending(csr_wb_pending),
      .i_branch_unresolved_decrement(branch_unresolved_decrement),
      .i_front_end_indirect_control_flow_pending(front_end_indirect_control_flow_pending),
      .i_pd_unpredicted_control_flow(pd_unpredicted_control_flow),
      .i_id_unpredicted_control_flow(id_unpredicted_control_flow),
      .i_disable_branch_prediction(i_disable_branch_prediction),
      .i_flush_pipeline(flush_pipeline),
      .o_pipeline_ctrl(pipeline_ctrl),
      .o_serializing_alloc_fire(serializing_alloc_fire),
      .o_csr_in_flight(csr_in_flight),
      .o_branch_in_flight_count(branch_in_flight_count),
      .o_disable_branch_prediction_ooo(disable_branch_prediction_ooo),
      .o_front_end_cf_serialize_stall(front_end_cf_serialize_stall),
      .o_stall_q(stall_q),
      .o_id_stall_q(id_stall_q),
      .o_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .o_replay_after_serialize_stall_q(replay_after_serialize_stall_q),
      .o_post_flush_holdoff_q(post_flush_holdoff_q),
      .o_trap_taken_reg(trap_taken_reg),
      .o_mret_taken_reg(mret_taken_reg),
      .o_trap_target_reg(trap_target_reg)
  );

  // ===========================================================================
  // Inter-stage signals
  // ===========================================================================
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_pd_to_id_t from_pd_to_id;
  logic pd_redirect;
  logic [XLEN-1:0] pd_redirect_target;
  riscv_pkg::from_id_to_ex_t from_id_to_ex;

  // Slot-2 inter-stage signals (2-wide dispatch).  IF extracts a real slot-2
  // instruction whenever the bundle allows it; from_if_to_pd_2 carries it
  // (sel_nop=1 only when there is no valid second instruction this cycle) and
  // PD/ID propagate it to dispatch, which fires slot-2 subject to the bundle
  // restrictions (slot-1 taken control flow ends the bundle, slot-2 cannot be
  // an FP-compute op, and slot-2 renamed sources use done-repair channels
  // 4/5/6 for the missed-CDB case).
  riscv_pkg::from_if_to_pd_t from_if_to_pd_2;
  riscv_pkg::from_pd_to_id_t from_pd_to_id_2;
  riscv_pkg::from_id_to_ex_t from_id_to_ex_2;

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
  logic dbg_trap_taken_raw  /* verilator public_flat_rd */;
  logic dbg_trap_taken_q  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_trap_cause_internal  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_trap_pc_internal  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_interrupt_resume_pc  /* verilator public_flat_rd */;
  logic dbg_port0_int_we  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_port0_int_addr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_port0_int_data  /* verilator public_flat_rd */;
  logic dbg_port1_int_we  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_port1_int_addr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_port1_int_data  /* verilator public_flat_rd */;
  logic dbg_commit_dest_valid  /* verilator public_flat_rd */;
  logic dbg_commit_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_commit_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_value  /* verilator public_flat_rd */;
  logic dbg_commit_2_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_2_pc  /* verilator public_flat_rd */;
  logic dbg_commit_2_dest_valid  /* verilator public_flat_rd */;
  logic dbg_commit_2_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_commit_2_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_2_value  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_reg_pc  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_dest_valid  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rob_commit_reg_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_reg_value  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_2_reg_pc  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_dest_valid  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rob_commit_2_reg_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_2_reg_value  /* verilator public_flat_rd */;
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
  assign o_pipeline_stall = pipeline_ctrl.stall;
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
  always_comb begin
    split_rs_dispatch_dbg = '0;
    if (int_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = int_rs_dispatch;
    end else if (mul_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = mul_rs_dispatch;
    end else if (mem_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = mem_rs_dispatch;
    end else if (fp_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fp_rs_dispatch;
    end else if (fmul_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fmul_rs_dispatch;
    end else if (fdiv_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fdiv_rs_dispatch;
    end
  end

  assign dbg_rs_dispatch_valid = split_rs_dispatch_dbg.valid;
  assign dbg_rs_dispatch_pc = split_rs_dispatch_dbg.pc;
  assign dbg_rs_dispatch_rob_tag = split_rs_dispatch_dbg.rob_tag;
  assign dbg_rs_dispatch_src1_ready = split_rs_dispatch_dbg.src1_ready;
  assign dbg_rs_dispatch_src1_tag = split_rs_dispatch_dbg.src1_tag;
  assign dbg_rs_dispatch_src2_ready = split_rs_dispatch_dbg.src2_ready;
  assign dbg_rs_dispatch_src2_tag = split_rs_dispatch_dbg.src2_tag;
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
      .i_instr_valid,
      .o_fetch_replay_consume,
      .i_from_ex_comb(from_ex_comb_synth),
      .i_trap_ctrl(trap_ctrl),
      .i_frontend_state_flush(frontend_state_flush),
      .i_fence_i_flush(fence_i_flush),
      .i_fence_i_target(fence_i_target_pc),
      .i_disable_branch_prediction(disable_branch_prediction_ooo),
      // Bimodal direction-predictor training (conditional branches only — see
      // dir_update_* below).
      .i_dir_update_valid(dir_update_valid),
      .i_dir_update_idx(dir_update_idx),
      .i_dir_update_taken(dir_update_taken),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_target(pd_redirect_target),
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd),
      .o_from_if_to_pd_2(from_if_to_pd_2)
  );

  // ===========================================================================
  // Stage 2: Pre-Decode (PD)
  // ===========================================================================

  pd_stage #(
      .XLEN(XLEN)
  ) pd_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .o_from_pd_to_id(from_pd_to_id),
      .i_from_if_to_pd_2(from_if_to_pd_2),
      .o_from_pd_to_id_2(from_pd_to_id_2),
      .o_pd_redirect(pd_redirect),
      .o_pd_redirect_target(pd_redirect_target)
  );

  // ===========================================================================
  // Register Files (read in ID, write from ROB commit)
  // ===========================================================================

  // Both architectural register files (integer + FP) and the widen-commit
  // write-back bypass now live in ooo_register_files. Write ports come from ROB
  // commit (port 0 = slot 1, port 1 = slot 2); read addresses come from the
  // ID-early and dispatch source fields of both bundle slots. The resolved
  // (post-bypass) read results feed ID, dispatch, and the RAT.

  // FP data width — also used below by the commit-side write-port packing.
  localparam int unsigned FpW = riscv_pkg::FpWidth;

  riscv_pkg::rf_to_fwd_t                rf_to_fwd;
  riscv_pkg::rf_to_fwd_t                rf_to_fwd_2;
  logic                      [XLEN-1:0] int_rf_dispatch_rs1_data;
  logic                      [XLEN-1:0] int_rf_dispatch_rs2_data;
  logic                      [XLEN-1:0] int_rf_dispatch_rs1_data_2;
  logic                      [XLEN-1:0] int_rf_dispatch_rs2_data_2;
  riscv_pkg::fp_rf_to_fwd_t             fp_rf_to_fwd;
  riscv_pkg::fp_rf_to_fwd_t             fp_rf_to_fwd_2;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs1_data;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs2_data;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs3_data;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs1_data_2;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs2_data_2;
  logic                      [ FpW-1:0] fp_rf_dispatch_rs3_data_2;

  // Bypass-disable struct fed to id_stage (forces id_stage's internal 1-source
  // WB bypass off; the 3-source bypass in ooo_register_files is used instead).
  // Driven in the ID section below.
  riscv_pkg::from_ma_to_wb_t            from_ma_to_wb_commit;

  ooo_register_files #(
      .XLEN(XLEN)
  ) ooo_register_files_inst (
      .i_clk,
      .i_port0_int_we  (port0_int_we),
      .i_port0_int_addr(port0_int_addr),
      .i_port0_int_data(port0_int_data),
      .i_port1_int_we  (port1_int_we),
      .i_port1_int_addr(port1_int_addr),
      .i_port1_int_data(port1_int_data),
      .i_port0_fp_we   (port0_fp_we),
      .i_port0_fp_addr (port0_fp_addr),
      .i_port0_fp_data (port0_fp_data),
      .i_port1_fp_we   (port1_fp_we),
      .i_port1_fp_addr (port1_fp_addr),
      .i_port1_fp_data (port1_fp_data),
      .i_from_pd_to_id  (from_pd_to_id),
      .i_from_pd_to_id_2(from_pd_to_id_2),
      .i_from_id_to_ex  (from_id_to_ex),
      .i_from_id_to_ex_2(from_id_to_ex_2),
      .o_rf_to_fwd  (rf_to_fwd),
      .o_rf_to_fwd_2(rf_to_fwd_2),
      .o_int_rf_dispatch_rs1_data  (int_rf_dispatch_rs1_data),
      .o_int_rf_dispatch_rs2_data  (int_rf_dispatch_rs2_data),
      .o_int_rf_dispatch_rs1_data_2(int_rf_dispatch_rs1_data_2),
      .o_int_rf_dispatch_rs2_data_2(int_rf_dispatch_rs2_data_2),
      .o_fp_rf_to_fwd  (fp_rf_to_fwd),
      .o_fp_rf_to_fwd_2(fp_rf_to_fwd_2),
      .o_fp_rf_dispatch_rs1_data  (fp_rf_dispatch_rs1_data),
      .o_fp_rf_dispatch_rs2_data  (fp_rf_dispatch_rs2_data),
      .o_fp_rf_dispatch_rs3_data  (fp_rf_dispatch_rs3_data),
      .o_fp_rf_dispatch_rs1_data_2(fp_rf_dispatch_rs1_data_2),
      .o_fp_rf_dispatch_rs2_data_2(fp_rf_dispatch_rs2_data_2),
      .o_fp_rf_dispatch_rs3_data_2(fp_rf_dispatch_rs3_data_2)
  );

  // ===========================================================================
  // Stage 3: Instruction Decode (ID)
  // ===========================================================================
  // ROB commit writes are architectural WB for the OOO core. Decode still needs
  // same-cycle bypass when it reads a source register that is being committed.
  always_comb begin
    // id_stage has its own in-module wb_bypass that fires on matches
    // against `instruction.dest_reg` using this struct's regfile_write_*
    // fields.  That bypass only covers ONE source (the primary port
    // write) and would return stale data when cpu_ooo's 3-source
    // priority chain picks an auxiliary source (slot 2 or displaced
    // slot 1) over the primary.  Force the WE fields low here so
    // id_stage's bypass never fires and falls through to
    // i_rf_to_id.source_reg_*_data — which is already the fully-resolved
    // 3-source bypass result computed in this file.
    from_ma_to_wb_commit                         = '0;
    from_ma_to_wb_commit.regfile_write_enable    = 1'b0;
    from_ma_to_wb_commit.regfile_write_data      = '0;
    from_ma_to_wb_commit.instruction.dest_reg    = '0;
    from_ma_to_wb_commit.fp_regfile_write_enable = 1'b0;
    from_ma_to_wb_commit.fp_dest_reg             = '0;
    from_ma_to_wb_commit.fp_regfile_write_data   = '0;
  end

  id_stage #(
      .XLEN(XLEN)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_target(pd_redirect_target),
      .i_rf_to_id(rf_to_fwd),
      .i_fp_rf_to_id(fp_rf_to_fwd),
      .i_from_ma_to_wb(from_ma_to_wb_commit),
      .o_from_id_to_ex(from_id_to_ex),
      // Slot-2 (2-wide dispatch).  i_from_pd_to_id_2 carries the real second
      // instruction of the bundle; o_from_id_to_ex_2 is its decoded form, and
      // dispatch raises i_valid_2 when slot-2 is present and allowed to fire.
      .i_from_pd_to_id_2(from_pd_to_id_2),
      .i_rf_to_id_2(rf_to_fwd_2),
      .i_fp_rf_to_id_2(fp_rf_to_fwd_2),
      .o_from_id_to_ex_2(from_id_to_ex_2)
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

  // Front-end validity / control-flow tracking lives in
  // frontend_validity_tracker. cpu_ooo keeps these boundary wires: the staged
  // valid bits (also tapped for debug) and the 2-wide dispatch enables.
  logic if_valid_q;
  logic pd_valid_q;
  logic id_valid;
  logic id_valid_2;

  frontend_validity_tracker frontend_validity_tracker_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(from_id_to_ex),
      .i_from_id_to_ex_2(from_id_to_ex_2),
      .i_post_flush_holdoff_q(post_flush_holdoff_q),
      .i_dispatch_flush(dispatch_flush),
      .i_csr_in_flight(csr_in_flight),
      .i_id_stall_q(id_stall_q),
      .i_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .i_flush_pipeline(flush_pipeline),
      .o_if_valid_q(if_valid_q),
      .o_pd_valid_q(pd_valid_q),
      .o_id_valid(id_valid),
      .o_id_valid_2(id_valid_2),
      .o_pd_unpredicted_control_flow(pd_unpredicted_control_flow),
      .o_id_unpredicted_control_flow(id_unpredicted_control_flow),
      .o_front_end_indirect_control_flow_pending(front_end_indirect_control_flow_pending),
      .o_prediction_fence_branch(prediction_fence_branch),
      .o_prediction_fence_jal(prediction_fence_jal),
      .o_prediction_fence_indirect(prediction_fence_indirect)
  );

  assign dbg_if_valid_q = if_valid_q;
  assign dbg_pd_valid_q = pd_valid_q;
  assign dbg_id_valid   = id_valid;

  // ===========================================================================
  // Tomasulo Wrapper Instance
  // ===========================================================================

  // ROB interface
  riscv_pkg::reorder_buffer_alloc_req_t  rob_alloc_req_raw;
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

  // Widen-commit slot 2 — populated by the ROB when commit_2_fire fires.
  // With the 2-write-port regfile there is no FIFO or back-pressure: both
  // slot 1 (rob_commit) and slot 2 (rob_commit_2) write the regfile in
  // the same cycle via independent ports.  widen_commit_ok is thus
  // permanently asserted (the ROB still uses the gate plumbing so the
  // signal path stays symmetric with the earlier FIFO approach).
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb_2;
  riscv_pkg::reorder_buffer_commit_t rob_commit_2;
  logic rob_commit_2_valid_raw;
  logic rob_commit_2_store_like_raw;
  logic rob_commit_2_valid;
  assign rob_commit_2_valid = rob_commit_2.valid;
  logic rob_commit_store_like_raw;
  logic sq_committed_empty_for_trap;
  assign rob_commit_store_like_raw =
      rob_commit_valid_raw &&
      (rob_commit_comb.is_store || rob_commit_comb.is_fp_store || rob_commit_comb.is_sc);
  logic widen_commit_ok;
  assign widen_commit_ok = 1'b1;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_epoch;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done_vec;

  // Per-ROB-entry predict-time bimodal index for the direction predictor.  Written
  // at ROB allocation (mirroring rob_entry_epoch) and read at commit to train the
  // exact bimodal entry the branch's prediction read.  No reset: only entries
  // allocated for a committing conditional branch are ever read.
  logic [riscv_pkg::BpDirIdxBits-1:0] branch_dir_idx_table[riscv_pkg::ReorderBufferDepth];

  // RAT lookup - slot 1
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr, int_src2_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr, fp_src2_addr, fp_src3_addr;
  riscv_pkg::rat_lookup_t int_src1_lookup, int_src2_lookup;
  riscv_pkg::rat_lookup_t fp_src1_lookup, fp_src2_lookup, fp_src3_lookup;

  // RAT lookup - slot 2 (2-wide dispatch).  The integer lookups feed slot-2
  // rename in dispatch.  The FP lookups are wired but unused (slot-2 cannot be
  // an FP-compute op), hence the UNUSEDSIGNAL waiver below.
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr_2, int_src2_addr_2;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr_2, fp_src2_addr_2, fp_src3_addr_2;
  /* verilator lint_off UNUSEDSIGNAL */
  riscv_pkg::rat_lookup_t int_src1_lookup_2, int_src2_lookup_2;
  riscv_pkg::rat_lookup_t fp_src1_lookup_2, fp_src2_lookup_2, fp_src3_lookup_2;
  /* verilator lint_on UNUSEDSIGNAL */

  // RAT rename - slot 1
  logic                                        rat_alloc_valid_raw;
  logic                                        rat_alloc_valid;
  logic                                        rat_alloc_dest_rf;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag;

  // RAT rename - slot 2 (2-wide dispatch).  Dispatch drives these when slot-2
  // fires with a register destination.
  logic                                        rat_alloc_valid_2_raw;
  logic                                        rat_alloc_valid_2;
  logic                                        rat_alloc_dest_rf_2;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg_2;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag_2;

  always_comb begin
    rob_alloc_req = rob_alloc_req_raw;
    rob_alloc_req.alloc_valid = rob_alloc_req_raw.alloc_valid && !full_flush_side_effect_kill;
  end

  assign rat_alloc_valid   = rat_alloc_valid_raw && !full_flush_side_effect_kill;
  assign rat_alloc_valid_2 = rat_alloc_valid_2_raw && !full_flush_side_effect_kill;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rob_entry_epoch <= '0;
    end else begin
      if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready) begin
        rob_entry_epoch[rob_alloc_resp.alloc_tag] <= ~rob_entry_epoch[rob_alloc_resp.alloc_tag];
      end
      if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready) begin
        rob_entry_epoch[rob_alloc_resp_2.alloc_tag] <= ~rob_entry_epoch[rob_alloc_resp_2.alloc_tag];
      end
    end
  end

  // Record each allocated entry's predict-time bimodal index, keyed by ROB tag,
  // using the same alloc signals as rob_entry_epoch.  Each slot stores its OWN
  // predict index (slot-1 and slot-2 looked up different PCs).
  always_ff @(posedge i_clk) begin
    if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp.alloc_tag] <= from_id_to_ex.bp_dir_idx;
    end
    if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp_2.alloc_tag] <= from_id_to_ex_2.bp_dir_idx;
    end
  end

  // ===========================================================================
  // Direction Predictor Commit-Time Training (bimodal)
  // ===========================================================================
  // Train the decoupled bimodal at commit for CONDITIONAL branches only.
  // rob_commit_comb.is_branch is true for branches AND jumps (is_branch_or_jump),
  // so exclude JAL/JALR.  Branches commit only at the head (slot-1, never slot-2),
  // so one update port suffices.  The training index is the branch's predict-time
  // bimodal index, recovered from branch_dir_idx_table at the committing tag, so
  // training updates the exact entry the prediction read.
  logic                               dir_update_valid_comb;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_comb;
  logic                               dir_update_taken_comb;
  assign dir_update_valid_comb = rob_commit_comb.valid && rob_commit_comb.is_branch &&
                                 !rob_commit_comb.is_jal && !rob_commit_comb.is_jalr;
  assign dir_update_idx_comb = branch_dir_idx_table[rob_commit_comb.tag];
  assign dir_update_taken_comb = rob_commit_comb.branch_taken;

  // Register the predictor update before it enters IF.  This removes the
  // ROB-head/serializer path from the distributed-RAM read-modify-write timing
  // arc; training is still in commit order, just one cycle later.
  logic                               dir_update_valid;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx;
  logic                               dir_update_taken;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dir_update_valid <= 1'b0;
      dir_update_idx   <= '0;
      dir_update_taken <= 1'b0;
    end else begin
      dir_update_valid <= dir_update_valid_comb;
      dir_update_idx   <= dir_update_idx_comb;
      dir_update_taken <= dir_update_taken_comb;
    end
  end

  // RS dispatch
  riscv_pkg::rs_dispatch_t int_rs_dispatch;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch;
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch;
  riscv_pkg::rs_dispatch_t split_rs_dispatch_dbg;

  // Slot-2 RS dispatch packets (2-wide dispatch, back-end side).
  // Driven by dispatch and consumed by the wrapper.  A packet's valid asserts
  // when slot-2 fires and routes to that RS family.
  riscv_pkg::rs_dispatch_t int_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch_2;

  // Slot-2 ROB allocation request + response.
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2_raw;
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp_2;

  always_comb begin
    rob_alloc_req_2 = rob_alloc_req_2_raw;
    rob_alloc_req_2.alloc_valid = rob_alloc_req_2_raw.alloc_valid && !full_flush_side_effect_kill;
  end

  // Checkpoint
  logic checkpoint_available;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_alloc_id;
  logic checkpoint_save_raw;
  logic checkpoint_save;
  logic checkpoint_save_for_slot2_raw;
  logic checkpoint_save_for_slot2;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_branch_tag;
  logic [riscv_pkg::RasPtrBits-1:0] dispatch_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] dispatch_ras_valid_count;
  logic rob_checkpoint_valid_raw;
  logic rob_checkpoint_valid;
  logic [riscv_pkg::CheckpointIdWidth-1:0] rob_checkpoint_id;

  assign checkpoint_save = checkpoint_save_raw && !full_flush_side_effect_kill;
  assign checkpoint_save_for_slot2 = checkpoint_save_for_slot2_raw && !full_flush_side_effect_kill;
  assign rob_checkpoint_valid = rob_checkpoint_valid_raw && !full_flush_side_effect_kill;

  // Resource status
  logic rob_full, rob_empty;
  logic int_rs_full, mul_rs_full, mem_rs_full;
  logic fp_rs_full, fmul_rs_full, fdiv_rs_full;
  logic lq_full, sq_full;

  // Slot-2 "room for 2" status from the wrapper.  Used by dispatch to gate
  // slot-2 fire when slot-1 is also targeting the same structure.
  logic rob_full_for_2;
  logic int_rs_full_for_2, mul_rs_full_for_2, mem_rs_full_for_2;
  logic fp_rs_full_for_2, fmul_rs_full_for_2, fdiv_rs_full_for_2;
  logic lq_full_for_2, sq_full_for_2;

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
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic frontend_state_flush;

  // CDB
  riscv_pkg::cdb_broadcast_t cdb_out;
  logic [riscv_pkg::NumFus-1:0] cdb_grant;

  // ROB status
  logic [riscv_pkg::ReorderBufferTagWidth:0] rob_count;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic head_valid, head_done;
  logic fence_i_flush;
  assign o_fence_i_flush = fence_i_flush;
  logic [XLEN-1:0] fence_i_target_pc;

  // CSR coordination
  logic csr_start, csr_done_ack;
  logic trap_pending;
  logic trap_mret_commit_hold_q;
  logic [XLEN-1:0] rob_trap_pc;
  riscv_pkg::exc_cause_t rob_trap_cause;
  riscv_pkg::exc_cause_t rob_trap_cause_remapped;
  logic [1:0] csr_priv;  // current privilege from csr_file (PrivM/PrivU)
  // Arbitrated trap cause from trap_unit (interrupt cause with bit 31, or the
  // remapped synchronous-exception cause) -> csr_file mcause. Declared here so
  // it is visible above the trap_unit instantiation that drives it.
  logic [XLEN-1:0] trap_cause_internal;
  logic [XLEN-1:0] rob_trap_value;
  logic rob_trap_taken_ack;
  logic mret_start, mret_done_ack;
  logic [XLEN-1:0] mepc_value;
  logic interrupt_pending;

  // Memory interfaces
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr, sq_mem_write_data;
  logic [3:0] sq_mem_write_byte_en;
  logic sq_mem_write_is_mmio;
  // Registered cached-tier flag for the SQ write (parallels is_mmio). Used by
  // the router to steer the store's byte-write enables to the cached tier and
  // mask them off the BRAM, keeping the late address-range test off the BRAM
  // WEA cone.
  logic sq_mem_write_is_cached;
  logic sq_mem_write_done;

  logic lq_mem_read_en;
  logic lq_mem_addr_valid;
  logic [XLEN-1:0] lq_mem_read_addr;
  riscv_pkg::mem_size_e lq_mem_read_size;
  logic [XLEN-1:0] lq_mem_read_data;
  logic lq_mem_read_valid;
  logic lq_mem_request_valid;
  logic lq_mem_request_fire;

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
  logic dispatch_bypass_valid_1, dispatch_bypass_valid_2, dispatch_bypass_valid_3;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_1, dispatch_bypass_tag_2, dispatch_bypass_tag_3;
  // Slot-2 done-repair channels (Session M).
  logic dispatch_bypass_valid_4, dispatch_bypass_valid_5, dispatch_bypass_valid_6;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_4, dispatch_bypass_tag_5, dispatch_bypass_tag_6;

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
  // Packed 2D (not unpacked) so it can cross module ports to branch_resolution /
  // misprediction_flush_controller (yosys read_verilog -sv rejects unpacked-array
  // ports). Element access is identical and the flattened storage is unchanged.
  logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag;
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

  // Owner tag tracking (only updates on save).  Use checkpoint_branch_tag
  // rather than rob_alloc_resp.alloc_tag so slot-2 branches store their own
  // ROB tag (not slot-1's).  Without this, the owner-tag check at branch
  // resolution (`checkpoint_owner_tag[ckpt] == rs_issue_int.rob_tag`) and at
  // commit fallback fails for slot-2 branches, suppressing branch resolution
  // and deadlocking the ROB head.
  always_ff @(posedge i_clk) begin
    if (rob_checkpoint_valid) checkpoint_owner_tag[rob_checkpoint_id] <= checkpoint_branch_tag;
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
  logic [$clog2(riscv_pkg::IntRsDepth+1)-1:0] rs_count;

  // FRM CSR
  logic [2:0] frm_csr;

  // CSR read data
  logic [XLEN-1:0] csr_read_data;  // registered (1-cycle latency)
  logic [XLEN-1:0] csr_mtvec;

  tomasulo_wrapper #(
      .SPLIT_RS_DISPATCH(1'b1),
      .ENABLE_DISPATCH_DONE_REPAIR(1'b1),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) u_tomasulo (
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
      .i_alloc_req(rob_alloc_req),
      .o_alloc_resp(rob_alloc_resp),
      // Slot-2 alloc plumbed end-to-end (back-end side).  The dispatch unit
      // raises alloc_valid_2 when slot-2 fires, allocating a second ROB entry
      // (tail+1) in the same cycle as slot-1.
      .i_alloc_req_2(rob_alloc_req_2),
      .o_alloc_resp_2(rob_alloc_resp_2),

      // Current privilege (PrivM/PrivU) for U-mode CSR/MRET illegal checks
      .i_priv(csr_priv),

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

      // Widen-commit slot 2 observation plus the downstream-ready gate.
      // cpu_ooo ties the gate high because slot 2 has a dedicated regfile
      // write port.
      .o_commit_2(rob_commit_2),
      .o_commit_comb_2(rob_commit_comb_2),
      .o_commit_2_valid_raw(rob_commit_2_valid_raw),
      .o_commit_2_store_like_raw(rob_commit_2_store_like_raw),
      .i_widen_commit_ok(widen_commit_ok),
      // Commit-time branch recovery is registered for timing; hold the ROB
      // during that recovery cycle so younger wrong-path entries cannot retire.
      .i_commit_hold(csr_commit_fire || trap_mret_commit_hold_q || mispredict_recovery_pending),

      // ROB external coordination
      .o_csr_start(csr_start),
      .i_csr_done(csr_done_ack),
      .o_trap_pending(trap_pending),
      .o_trap_pc(rob_trap_pc),
      .o_trap_cause(rob_trap_cause),
      .o_trap_value(rob_trap_value),
      .i_trap_taken(rob_trap_taken_ack),
      .o_mret_start(mret_start),
      .i_mret_done(mret_done_ack),
      .i_mepc(mepc_value),
      .i_interrupt_pending(interrupt_pending),
      .i_trap_misaligned_accesses(|csr_mtvec[XLEN-1:2]),

      // Flush
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_flush_all(flush_all),
      .i_flush_after_head_commit(commit_recovery_flush_after_head),
      .i_backend_recovery_hold(early_backend_recovery_hold),
      .i_slow_write_inflight(i_cached_write_inflight),

      // Early misprediction recovery
      .i_early_recovery_flush(early_backend_recovery_pending),
      .i_early_recovery_en(early_recovery_en),
      .i_early_recovery_tag(early_recovery_tag),

      // ROB status
      .o_fence_i_flush(fence_i_flush),
      .o_sq_committed_empty(sq_committed_empty),
      .i_fence_i_sync_done(i_fence_i_sync_done),
      .o_fence_i_sync_req(o_fence_i_sync_req),
      .o_rob_full(rob_full),
      .o_rob_full_for_2(rob_full_for_2),
      .o_rob_empty(rob_empty),
      .o_rob_count(rob_count),
      .o_head_tag(head_tag),
      .o_head_valid(head_valid),
      .o_head_done(head_done),

      // ROB bypass read
      .i_read_tag(rob_read_tag),
      .o_read_done(rob_read_done),
      .o_read_value(rob_read_value),
      .o_rob_entry_done_vec(rob_entry_done_vec),
      .i_rob_entry_epoch(rob_entry_epoch),
      .i_bypass_valid_1(dispatch_bypass_valid_1),
      .i_bypass_tag_1(dispatch_bypass_tag_1),
      .o_bypass_value_1(),
      .i_bypass_valid_2(dispatch_bypass_valid_2),
      .i_bypass_tag_2(dispatch_bypass_tag_2),
      .o_bypass_value_2(),
      .i_bypass_valid_3(dispatch_bypass_valid_3),
      .i_bypass_tag_3(dispatch_bypass_tag_3),
      .o_bypass_value_3(),
      .i_bypass_valid_4(dispatch_bypass_valid_4),
      .i_bypass_tag_4(dispatch_bypass_tag_4),
      .o_bypass_value_4(),
      .i_bypass_valid_5(dispatch_bypass_valid_5),
      .i_bypass_tag_5(dispatch_bypass_tag_5),
      .o_bypass_value_5(),
      .i_bypass_valid_6(dispatch_bypass_valid_6),
      .i_bypass_tag_6(dispatch_bypass_tag_6),
      .o_bypass_value_6(),

      // RAT source lookups - slot 1
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

      // RAT source lookups - slot 2 (2-wide dispatch)
      .i_int_src1_addr_2(int_src1_addr_2),
      .i_int_src2_addr_2(int_src2_addr_2),
      .o_int_src1_2(int_src1_lookup_2),
      .o_int_src2_2(int_src2_lookup_2),
      .i_fp_src1_addr_2(fp_src1_addr_2),
      .i_fp_src2_addr_2(fp_src2_addr_2),
      .i_fp_src3_addr_2(fp_src3_addr_2),
      .o_fp_src1_2(fp_src1_lookup_2),
      .o_fp_src2_2(fp_src2_lookup_2),
      .o_fp_src3_2(fp_src3_lookup_2),

      // RAT regfile data - slot 1
      .i_int_regfile_data1(int_rf_dispatch_rs1_data),
      .i_int_regfile_data2(int_rf_dispatch_rs2_data),
      .i_fp_regfile_data1 (fp_rf_dispatch_rs1_data),
      .i_fp_regfile_data2 (fp_rf_dispatch_rs2_data),
      .i_fp_regfile_data3 (fp_rf_dispatch_rs3_data),

      // RAT regfile data - slot 2 (Session G: now wired through the
      // dispatch-stage slot-2 reads with widen-commit bypass).
      .i_int_regfile_data1_2(int_rf_dispatch_rs1_data_2),
      .i_int_regfile_data2_2(int_rf_dispatch_rs2_data_2),
      .i_fp_regfile_data1_2 (fp_rf_dispatch_rs1_data_2),
      .i_fp_regfile_data2_2 (fp_rf_dispatch_rs2_data_2),
      .i_fp_regfile_data3_2 (fp_rf_dispatch_rs3_data_2),

      // RAT rename - slot 1
      .i_rat_alloc_valid(rat_alloc_valid),
      .i_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .i_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .i_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT rename - slot 2 (2-wide dispatch; dispatch raises valid_2 on fire)
      .i_rat_alloc_valid_2(rat_alloc_valid_2),
      .i_rat_alloc_dest_rf_2(rat_alloc_dest_rf_2),
      .i_rat_alloc_dest_reg_2(rat_alloc_dest_reg_2),
      .i_rat_alloc_rob_tag_2(rat_alloc_rob_tag_2),

      // RAT checkpoint save
      .i_checkpoint_save(checkpoint_save),
      .i_checkpoint_id(checkpoint_id),
      .i_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(dispatch_ras_tos),
      .i_ras_valid_count(dispatch_ras_valid_count),
      .i_checkpoint_save_for_slot2(checkpoint_save_for_slot2),

      // RAT checkpoint restore
      .i_checkpoint_restore(checkpoint_restore),
      .i_checkpoint_restore_id(checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
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
      .i_rs_dispatch('0),
      .i_int_rs_dispatch(int_rs_dispatch),
      .i_mul_rs_dispatch(mul_rs_dispatch),
      .i_mem_rs_dispatch(mem_rs_dispatch),
      .i_fp_rs_dispatch(fp_rs_dispatch),
      .i_fmul_rs_dispatch(fmul_rs_dispatch),
      .i_fdiv_rs_dispatch(fdiv_rs_dispatch),
      // Slot-2 RS dispatch — driven from dispatch unit.  The wrapper just
      // forwards what dispatch produces; valids assert when slot-2 fires.
      .i_int_rs_dispatch_2(int_rs_dispatch_2),
      .i_mul_rs_dispatch_2(mul_rs_dispatch_2),
      .i_mem_rs_dispatch_2(mem_rs_dispatch_2),
      .i_fp_rs_dispatch_2(fp_rs_dispatch_2),
      .i_fmul_rs_dispatch_2(fmul_rs_dispatch_2),
      .i_fdiv_rs_dispatch_2(fdiv_rs_dispatch_2),
      .o_rs_full(),

      // RS issue + status (INT_RS)
      .o_rs_issue(rs_issue_int),
      .i_rs_fu_ready(1'b1),
      .o_int_rs_full(int_rs_full),
      .o_int_rs_full_for_2(int_rs_full_for_2),
      .o_rs_empty(rs_empty),
      .o_rs_count(rs_count),

      // MUL_RS
      .o_mul_rs_issue(rs_issue_mul),
      .i_mul_rs_fu_ready(1'b1),
      .o_mul_rs_full(mul_rs_full),
      .o_mul_rs_full_for_2(mul_rs_full_for_2),
      .o_mul_rs_empty(),
      .o_mul_rs_count(),

      // MEM_RS
      .o_mem_rs_issue(rs_issue_mem),
      .i_mem_rs_fu_ready(1'b1),
      .o_mem_rs_full(mem_rs_full),
      .o_mem_rs_full_for_2(mem_rs_full_for_2),
      .o_mem_rs_empty(),
      .o_mem_rs_count(),

      // FP_RS
      .o_fp_rs_issue(rs_issue_fp),
      .i_fp_rs_fu_ready(1'b1),
      .o_fp_rs_full(fp_rs_full),
      .o_fp_rs_full_for_2(fp_rs_full_for_2),
      .o_fp_rs_empty(),
      .o_fp_rs_count(),

      // FMUL_RS
      .o_fmul_rs_issue(rs_issue_fmul),
      .i_fmul_rs_fu_ready(1'b1),
      .o_fmul_rs_full(fmul_rs_full),
      .o_fmul_rs_full_for_2(fmul_rs_full_for_2),
      .o_fmul_rs_empty(),
      .o_fmul_rs_count(),

      // FDIV_RS
      .o_fdiv_rs_issue(rs_issue_fdiv),
      .i_fdiv_rs_fu_ready(1'b1),
      .o_fdiv_rs_full(fdiv_rs_full),
      .o_fdiv_rs_full_for_2(fdiv_rs_full_for_2),
      .o_fdiv_rs_empty(),
      .o_fdiv_rs_count(),

      // CSR read data
      .i_csr_read_data(csr_read_data),

      // Store queue memory interface
      .o_sq_mem_write_en(sq_mem_write_en),
      .o_sq_mem_write_addr(sq_mem_write_addr),
      .o_sq_mem_write_data(sq_mem_write_data),
      .o_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .o_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .o_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_sq_mem_write_done(sq_mem_write_done),

      // Load queue memory interface
      .o_lq_mem_read_en(lq_mem_read_en),
      .o_lq_mem_addr_valid(lq_mem_addr_valid),
      .o_lq_mem_read_addr(lq_mem_read_addr),
      .o_lq_mem_read_size(lq_mem_read_size),
      .i_lq_mem_read_data(lq_mem_read_data),
      .i_lq_mem_read_valid(lq_mem_read_valid),

      // LQ/SQ status
      .o_lq_full(lq_full),
      .o_lq_full_for_2(lq_full_for_2),
      .o_lq_empty(lq_empty),
      .o_lq_count(lq_count),
      .o_sq_full(sq_full),
      .o_sq_full_for_2(sq_full_for_2),
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

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) trap_mret_commit_hold_q <= 1'b0;
    // trap_drain_wait: a trap/MRET is waiting for committed stores to drain
    // (see trap_unit) -- hold commit so the wait is bounded.
    else
      trap_mret_commit_hold_q <= trap_pending || mret_start || trap_drain_wait;
  end

  // ===========================================================================
  // Dispatch Unit
  // ===========================================================================

  dispatch u_dispatch (
      .i_clk,
      .i_rst_n(rst_n),

      .i_from_id_to_ex(from_id_to_ex),
      .i_valid(id_valid),

      // Slot-2 instruction (2-wide dispatch).  Carries the real second
      // instruction of the bundle; id_valid_2 is '1 whenever IF supplied one
      // and '0 only when the bundle has no valid slot-2 this cycle.
      .i_from_id_to_ex_2(from_id_to_ex_2),
      .i_valid_2(id_valid_2),

      .i_rs1_addr(from_id_to_ex.instruction.source_reg_1),
      .i_rs2_addr(from_id_to_ex.instruction.source_reg_2),
      .i_fp_rs3_addr(from_id_to_ex.instruction.funct7[6:2]),

      // Slot-2 source register addresses (2-wide dispatch).
      .i_rs1_addr_2(from_id_to_ex_2.instruction.source_reg_1),
      .i_rs2_addr_2(from_id_to_ex_2.instruction.source_reg_2),
      .i_fp_rs3_addr_2(from_id_to_ex_2.instruction.funct7[6:2]),

      .i_frm_csr(frm_csr),

      // ROB
      .o_rob_alloc_req (rob_alloc_req_raw),
      .i_rob_alloc_resp(rob_alloc_resp),

      // Slot-2 ROB alloc (2-wide dispatch)
      .o_rob_alloc_req_2 (rob_alloc_req_2_raw),
      .i_rob_alloc_resp_2(rob_alloc_resp_2),

      // ROB entry-done vector retained for dispatch interface stability; the
      // old slot-2 conservative missed-CDB gate has been replaced by
      // done-repair channels 4/5/6.
      .i_rob_entry_done(rob_entry_done_vec),

      // RAT lookups - slot 1
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

      // RAT lookups - slot 2 (2-wide dispatch)
      .o_int_src1_addr_2(int_src1_addr_2),
      .o_int_src2_addr_2(int_src2_addr_2),
      .o_fp_src1_addr_2 (fp_src1_addr_2),
      .o_fp_src2_addr_2 (fp_src2_addr_2),
      .o_fp_src3_addr_2 (fp_src3_addr_2),

      .i_int_src1_2(int_src1_lookup_2),
      .i_int_src2_2(int_src2_lookup_2),
      .i_fp_src1_2 (fp_src1_lookup_2),
      .i_fp_src2_2 (fp_src2_lookup_2),
      .i_fp_src3_2 (fp_src3_lookup_2),

      // RAT rename - slot 1
      .o_rat_alloc_valid(rat_alloc_valid_raw),
      .o_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .o_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .o_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT rename - slot 2 (dispatch asserts valid_2 when slot-2 fires)
      .o_rat_alloc_valid_2(rat_alloc_valid_2_raw),
      .o_rat_alloc_dest_rf_2(rat_alloc_dest_rf_2),
      .o_rat_alloc_dest_reg_2(rat_alloc_dest_reg_2),
      .o_rat_alloc_rob_tag_2(rat_alloc_rob_tag_2),

      // ROB done-entry repair read request
      .o_bypass_valid_1(dispatch_bypass_valid_1),
      .o_bypass_tag_1  (dispatch_bypass_tag_1),
      .o_bypass_valid_2(dispatch_bypass_valid_2),
      .o_bypass_tag_2  (dispatch_bypass_tag_2),
      .o_bypass_valid_3(dispatch_bypass_valid_3),
      .o_bypass_tag_3  (dispatch_bypass_tag_3),
      .o_bypass_valid_4(dispatch_bypass_valid_4),
      .o_bypass_tag_4  (dispatch_bypass_tag_4),
      .o_bypass_valid_5(dispatch_bypass_valid_5),
      .o_bypass_tag_5  (dispatch_bypass_tag_5),
      .o_bypass_valid_6(dispatch_bypass_valid_6),
      .o_bypass_tag_6  (dispatch_bypass_tag_6),

      // RS dispatch
      .o_rs_dispatch(),
      .o_int_rs_dispatch(int_rs_dispatch),
      .o_mul_rs_dispatch(mul_rs_dispatch),
      .o_mem_rs_dispatch(mem_rs_dispatch),
      .o_fp_rs_dispatch(fp_rs_dispatch),
      .o_fmul_rs_dispatch(fmul_rs_dispatch),
      .o_fdiv_rs_dispatch(fdiv_rs_dispatch),

      // Slot-2 RS dispatch (2-wide dispatch).  At most one packet has .valid=1
      // per cycle — the RS family slot-2 routes to when it fires.
      .o_int_rs_dispatch_2 (int_rs_dispatch_2),
      .o_mul_rs_dispatch_2 (mul_rs_dispatch_2),
      .o_mem_rs_dispatch_2 (mem_rs_dispatch_2),
      .o_fp_rs_dispatch_2  (fp_rs_dispatch_2),
      .o_fmul_rs_dispatch_2(fmul_rs_dispatch_2),
      .o_fdiv_rs_dispatch_2(fdiv_rs_dispatch_2),

      // Checkpoint management
      .i_checkpoint_available(checkpoint_available),
      .i_checkpoint_alloc_id(checkpoint_alloc_id),
      .o_checkpoint_save(checkpoint_save_raw),
      .o_checkpoint_save_for_slot2(checkpoint_save_for_slot2_raw),
      .o_checkpoint_id(checkpoint_id),
      .o_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(from_if_to_pd.ras_checkpoint_tos),
      .i_ras_valid_count(from_if_to_pd.ras_checkpoint_valid_count),
      .o_ras_tos(dispatch_ras_tos),
      .o_ras_valid_count(dispatch_ras_valid_count),
      .o_rob_checkpoint_valid(rob_checkpoint_valid_raw),
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

      // Slot-2 "room for 2" status from the wrapper.
      .i_rob_full_for_2(rob_full_for_2),
      .i_int_rs_full_for_2(int_rs_full_for_2),
      .i_mul_rs_full_for_2(mul_rs_full_for_2),
      .i_mem_rs_full_for_2(mem_rs_full_for_2),
      .i_fp_rs_full_for_2(fp_rs_full_for_2),
      .i_fmul_rs_full_for_2(fmul_rs_full_for_2),
      .i_fdiv_rs_full_for_2(fdiv_rs_full_for_2),
      .i_lq_full_for_2(lq_full_for_2),
      .i_sq_full_for_2(sq_full_for_2),

      // Flush / early-recovery hold
      .i_flush(dispatch_flush),
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
  // Branch/jump instructions issue from INT_RS with their CDB broadcast
  // suppressed by the ALU shim; branch_resolution resolves them and drives the
  // branch_update the ROB trusts.
  logic            is_jalr_issue;
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_resolution #(
      .XLEN(XLEN)
  ) branch_resolution_inst (
      .i_rs_issue_int(rs_issue_int),
      .i_head_tag(head_tag),
      .i_early_mispredict_tag(early_mispredict_tag),
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_backend_recovery_pending(early_backend_recovery_pending),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_mispredict_commit_q(mispredict_commit_q),
      .i_flush_for_trap(flush_for_trap),
      .i_flush_for_mret(flush_for_mret),
      .i_fence_i_flush(fence_i_flush),
      .i_checkpoint_in_use(checkpoint_in_use),
      .i_checkpoint_owner_tag(checkpoint_owner_tag),
      .o_branch_update(branch_update),
      .o_branch_resolved_correct(branch_resolved_correct),
      .o_branch_unresolved_decrement(branch_unresolved_decrement),
      .o_is_jalr_issue(is_jalr_issue),
      .o_branch_taken_resolved(branch_taken_resolved),
      .o_branch_target_resolved(branch_target_resolved)
  );

  // LQ memory-request fire (unrelated to branch resolution; kept in cpu_ooo).
  assign lq_mem_request_fire = lq_mem_request_valid ||
                               (lq_mem_read_en && !sq_mem_write_en && !amo_mem_write_en);

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

  logic                                        early_mispredict_active;
  logic                                        early_backend_recovery_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [                            XLEN-1:0] early_mispredict_redirect_pc;
  logic [    riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic                                        early_mispredict_is_compressed;
  logic [                            XLEN-1:0] early_mispredict_pc;
  logic [                            XLEN-1:0] early_mispredict_branch_target;
  logic                                        early_mispredict_branch_taken;
  logic                                        early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  logic                                        early_backend_recovery_hold;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic                                        early_recovery_trap_taken_reg;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic                                        early_recovery_mret_taken_reg;

  // Local phase-equivalent copies of the registered full-flush pulses.  The
  // pipeline-control copies also drive IF and global flush logic; using these
  // local copies keeps the MRET/trap kill routing out of the early-recovery
  // capture flops.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      early_recovery_trap_taken_reg <= 1'b0;
      early_recovery_mret_taken_reg <= 1'b0;
    end else begin
      early_recovery_trap_taken_reg <= trap_taken;
      early_recovery_mret_taken_reg <= mret_taken;
    end
  end

  early_misprediction_recovery #(
      .XLEN(XLEN)
  ) early_misprediction_recovery_inst (
      .i_clk,
      .i_rst,
      .i_branch_update(branch_update),
      .i_rs_issue_int(rs_issue_int),
      .i_head_tag(head_tag),
      .i_is_jalr_issue(is_jalr_issue),
      .i_branch_taken_resolved(branch_taken_resolved),
      .i_branch_target_resolved(branch_target_resolved),
      .i_fence_i_flush(fence_i_flush),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_flush_all(flush_all),
      .i_flush_for_trap(early_recovery_trap_taken_reg),
      .i_flush_for_mret(early_recovery_mret_taken_reg),
      .i_trap_taken_reg(early_recovery_trap_taken_reg),
      .i_mret_taken_reg(early_recovery_mret_taken_reg),
      .o_early_mispredict_active(early_mispredict_active),
      .o_early_backend_recovery_pending(early_backend_recovery_pending),
      .o_early_backend_flush_tag(early_backend_flush_tag),
      .o_early_mispredict_tag(early_mispredict_tag),
      .o_early_mispredict_redirect_pc(early_mispredict_redirect_pc),
      .o_early_mispredict_checkpoint_id(early_mispredict_checkpoint_id),
      .o_early_mispredict_is_compressed(early_mispredict_is_compressed),
      .o_early_mispredict_pc(early_mispredict_pc),
      .o_early_mispredict_branch_target(early_mispredict_branch_target),
      .o_early_mispredict_branch_taken(early_mispredict_branch_taken),
      .o_early_recovery_en(early_recovery_en),
      .o_early_recovery_tag(early_recovery_tag),
      .o_early_backend_recovery_hold(early_backend_recovery_hold)
  );

  // ===========================================================================
  // Commit-Time Actions
  // ===========================================================================

  // Regfile write ports (driven by commit_actions, consumed by
  // ooo_register_files), CSR serialization handshakes, and retire status.
  logic            port0_int_we;
  logic [     4:0] port0_int_addr;
  logic [XLEN-1:0] port0_int_data;
  logic            port0_fp_we;
  logic [     4:0] port0_fp_addr;
  logic [ FpW-1:0] port0_fp_data;
  logic            port1_int_we;
  logic [     4:0] port1_int_addr;
  logic [XLEN-1:0] port1_int_data;
  logic            port1_fp_we;
  logic [     4:0] port1_fp_addr;
  logic [ FpW-1:0] port1_fp_data;
  logic [     1:0] instruction_retired_count;

  commit_actions #(
      .XLEN(XLEN)
  ) commit_actions_inst (
      .i_clk,
      .i_rst,
      .i_rob_commit(rob_commit),
      .i_rob_commit_2(rob_commit_2),
      .i_rob_commit_valid(rob_commit_valid),
      .i_csr_read_data(csr_read_data),
      .i_trap_taken(trap_taken),
      .o_port0_int_we(port0_int_we),
      .o_port0_int_addr(port0_int_addr),
      .o_port0_int_data(port0_int_data),
      .o_port0_fp_we(port0_fp_we),
      .o_port0_fp_addr(port0_fp_addr),
      .o_port0_fp_data(port0_fp_data),
      .o_port1_int_we(port1_int_we),
      .o_port1_int_addr(port1_int_addr),
      .o_port1_int_data(port1_int_data),
      .o_port1_fp_we(port1_fp_we),
      .o_port1_fp_addr(port1_fp_addr),
      .o_port1_fp_data(port1_fp_data),
      .o_csr_commit_fire(csr_commit_fire),
      .o_csr_wb_pending(csr_wb_pending),
      .o_vld(o_vld),
      .o_pc_vld(o_pc_vld),
      .o_instruction_retired_count(instruction_retired_count)
  );

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

`ifndef SYNTHESIS
  assign dbg_trap_taken_raw = trap_taken;
  assign dbg_trap_taken_q = trap_taken_reg;
  assign dbg_trap_cause_internal = trap_cause_internal;
  assign dbg_trap_pc_internal = trap_pc_internal;
  assign dbg_interrupt_resume_pc = interrupt_resume_pc;
  assign dbg_port0_int_we = port0_int_we;
  assign dbg_port0_int_addr = port0_int_addr;
  assign dbg_port0_int_data = port0_int_data;
  assign dbg_port1_int_we = port1_int_we;
  assign dbg_port1_int_addr = port1_int_addr;
  assign dbg_port1_int_data = port1_int_data;
  assign dbg_commit_dest_valid = rob_commit_comb.dest_valid;
  assign dbg_commit_dest_rf = rob_commit_comb.dest_rf;
  assign dbg_commit_dest_reg = rob_commit_comb.dest_reg;
  assign dbg_commit_value = rob_commit_comb.value[XLEN-1:0];
  assign dbg_commit_2_valid = rob_commit_comb_2.valid;
  assign dbg_commit_2_pc = rob_commit_comb_2.pc;
  assign dbg_commit_2_dest_valid = rob_commit_comb_2.dest_valid;
  assign dbg_commit_2_dest_rf = rob_commit_comb_2.dest_rf;
  assign dbg_commit_2_dest_reg = rob_commit_comb_2.dest_reg;
  assign dbg_commit_2_value = rob_commit_comb_2.value[XLEN-1:0];
  assign dbg_rob_commit_reg_valid = rob_commit.valid;
  assign dbg_rob_commit_reg_pc = rob_commit.pc;
  assign dbg_rob_commit_reg_dest_valid = rob_commit.dest_valid;
  assign dbg_rob_commit_reg_dest_rf = rob_commit.dest_rf;
  assign dbg_rob_commit_reg_dest_reg = rob_commit.dest_reg;
  assign dbg_rob_commit_reg_value = rob_commit.value[XLEN-1:0];
  assign dbg_rob_commit_2_reg_valid = rob_commit_2.valid;
  assign dbg_rob_commit_2_reg_pc = rob_commit_2.pc;
  assign dbg_rob_commit_2_reg_dest_valid = rob_commit_2.dest_valid;
  assign dbg_rob_commit_2_reg_dest_rf = rob_commit_2.dest_rf;
  assign dbg_rob_commit_2_reg_dest_reg = rob_commit_2.dest_reg;
  assign dbg_rob_commit_2_reg_value = rob_commit_2.value[XLEN-1:0];
`endif

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
  // Capture/flush state produced by the controller and consumed across cpu_ooo
  // (the recovery struct mispredict_commit_q and the flush/checkpoint controls
  // are declared near the top; these few were section-local).
  logic correct_branch_commit_pending;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask;
  logic flush_after_head;

  misprediction_flush_controller #(
      .XLEN(XLEN)
  ) misprediction_flush_controller_inst (
      .i_clk,
      .i_rst,
      .i_rob_commit_misprediction_raw(rob_commit_misprediction_raw),
      .i_rob_commit_correct_branch_raw(rob_commit_correct_branch_raw),
      .i_rob_commit_comb(rob_commit_comb),
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_backend_recovery_pending(early_backend_recovery_pending),
      .i_head_tag(head_tag),
      .i_early_mispredict_tag(early_mispredict_tag),
      .i_early_backend_flush_tag(early_backend_flush_tag),
      .i_early_mispredict_checkpoint_id(early_mispredict_checkpoint_id),
      .i_trap_taken_reg(trap_taken_reg),
      .i_mret_taken_reg(mret_taken_reg),
      .i_flush_for_trap(flush_for_trap),
      .i_flush_for_mret(flush_for_mret),
      .i_fence_i_flush(fence_i_flush),
      .i_checkpoint_in_use(checkpoint_in_use),
      .i_checkpoint_younger_than_flush(checkpoint_younger_than_flush),
      .i_checkpoint_owner_tag(checkpoint_owner_tag),
      .o_mispredict_commit_q(mispredict_commit_q),
      .o_mispredict_recovery_pending(mispredict_recovery_pending),
      .o_fence_i_target_pc(fence_i_target_pc),
      .o_correct_branch_commit_pending(correct_branch_commit_pending),
      .o_correct_branch_commit_q(correct_branch_commit_q),
      .o_flush_pipeline(flush_pipeline),
      .o_dispatch_flush(dispatch_flush),
      .o_full_flush_side_effect_kill(full_flush_side_effect_kill),
      .o_frontend_state_flush(frontend_state_flush),
      .o_flush_en(flush_en),
      .o_flush_tag(flush_tag),
      .o_flush_all(flush_all),
      .o_commit_recovery_flush_after_head(commit_recovery_flush_after_head),
      .o_flush_after_head(flush_after_head),
      .o_checkpoint_restore(checkpoint_restore),
      .o_checkpoint_restore_id(checkpoint_restore_id),
      .o_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
      .o_checkpoint_flush_free_mask(checkpoint_flush_free_mask),
      .o_checkpoint_free(checkpoint_free),
      .o_checkpoint_free_id(checkpoint_free_id)
  );

  // ===========================================================================
  // Synthesize from_ex_comb for IF Stage
  // ===========================================================================
  // The IF stage expects from_ex_comb_t for branch redirect, BTB update,
  // and RAS restore. In OOO mode, these come from ROB commit.

  ex_comb_synthesizer #(
      .XLEN(XLEN)
  ) ex_comb_synthesizer_inst (
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_mispredict_redirect_pc(early_mispredict_redirect_pc),
      .i_early_mispredict_pc(early_mispredict_pc),
      .i_early_mispredict_branch_target(early_mispredict_branch_target),
      .i_early_mispredict_branch_taken(early_mispredict_branch_taken),
      .i_early_mispredict_is_compressed(early_mispredict_is_compressed),
      .i_restored_ras_tos(restored_ras_tos),
      .i_restored_ras_valid_count(restored_ras_valid_count),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_mispredict_commit_q(mispredict_commit_q),
      .i_correct_branch_commit_pending(correct_branch_commit_pending),
      .i_correct_branch_commit_q(correct_branch_commit_q),
      .o_from_ex_comb(from_ex_comb_synth)
  );

  // ===========================================================================
  // Memory Interface
  // ===========================================================================
  // Route LQ/SQ memory requests to the external data memory port.
  // Priority: SQ writes > AMO writes > queued LQ reads
  // The L0 cache is inside the tomasulo_wrapper (lq_l0_cache).

  // Cached-tier write data (SQ-store drain data, or the AMO new value on the
  // single cycle a cached AMO write launches) is produced by the router, which
  // owns the SQ-vs-AMO cached-write mux.

  data_mem_request_router #(
      .XLEN(XLEN),
      .MMIO_ADDR(MMIO_ADDR),
      .MMIO_SIZE_BYTES(MMIO_SIZE_BYTES),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) data_mem_request_router_inst (
      .i_clk,
      .i_rst,
      .i_sq_mem_write_en(sq_mem_write_en),
      .i_sq_mem_write_addr(sq_mem_write_addr),
      .i_sq_mem_write_data(sq_mem_write_data),
      .i_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .i_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .i_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_amo_mem_write_en(amo_mem_write_en),
      .i_amo_mem_write_addr(amo_mem_write_addr),
      .i_amo_mem_write_data(amo_mem_write_data),
      .i_lq_mem_read_en(lq_mem_read_en),
      .i_lq_mem_read_addr(lq_mem_read_addr),
      .i_lq_mem_addr_valid(lq_mem_addr_valid),
      .i_data_mem_rd_data(i_data_mem_rd_data),
      .i_cached_read_data(i_cached_read_data),
      .i_cached_read_valid(i_cached_read_valid),
      .i_cached_write_done(i_cached_write_done),
      .i_cached_write_inflight(i_cached_write_inflight),
      .o_data_mem_addr(o_data_mem_addr),
      .o_data_mem_wr_data(o_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(o_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(o_data_mem_bram_byte_wr_en),
      .o_data_mem_read_enable(o_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(o_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(o_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(o_data_mem_cached_read_enable),
      .o_mmio_read_pulse(o_mmio_read_pulse),
      .o_mmio_load_addr(o_mmio_load_addr),
      .o_mmio_load_valid(o_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(o_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(o_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(o_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(sq_mem_write_done),
      .o_amo_mem_write_done(amo_mem_write_done),
      .o_lq_mem_request_valid(lq_mem_request_valid),
      .o_lq_mem_read_data(lq_mem_read_data),
      .o_lq_mem_read_valid(lq_mem_read_valid)
  );

  // ===========================================================================
  // CSR File
  // ===========================================================================
  // CSR operations are serialized: the ROB waits for the CSR at head,
  // then signals csr_start. The CSR file performs the read/write,
  // then signals csr_done.

  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mepc;
  logic csr_mstatus_mie_direct;

  // CSR write data: for register ops (CSRRW/CSRRS/CSRRC), the ALU shim
  // stored rs1 in rob_commit.value. For immediate ops (CSRRWI/CSRRSI/CSRRCI),
  // the ALU shim stored zero_extend(csr_imm) in rob_commit.value.
  logic [XLEN-1:0] csr_write_data_from_commit;
  assign csr_write_data_from_commit = rob_commit.value[XLEN-1:0];
  logic rob_commit_fp_flags_nonzero;
  logic rob_commit_2_fp_flags_nonzero;
  logic rob_commit_fp_flags_valid;
  logic rob_commit_2_fp_flags_valid;
  logic rob_commit_any_fp_flags_valid;
  riscv_pkg::fp_flags_t rob_commit_fp_flags_merged;

  assign rob_commit_fp_flags_nonzero = rob_commit.fp_flags.nv | rob_commit.fp_flags.dz |
                                       rob_commit.fp_flags.of | rob_commit.fp_flags.uf |
                                       rob_commit.fp_flags.nx;
  assign rob_commit_2_fp_flags_nonzero = rob_commit_2.fp_flags.nv | rob_commit_2.fp_flags.dz |
                                         rob_commit_2.fp_flags.of | rob_commit_2.fp_flags.uf |
                                         rob_commit_2.fp_flags.nx;
  assign rob_commit_fp_flags_valid = rob_commit_valid && rob_commit_fp_flags_nonzero &&
                                     !rob_commit.exception;
  assign rob_commit_2_fp_flags_valid = rob_commit_2_valid && rob_commit_2_fp_flags_nonzero &&
                                       !rob_commit_2.exception;
  assign rob_commit_any_fp_flags_valid = rob_commit_fp_flags_valid || rob_commit_2_fp_flags_valid;

  always_comb begin
    rob_commit_fp_flags_merged.nv = (rob_commit_fp_flags_valid && rob_commit.fp_flags.nv) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.nv);
    rob_commit_fp_flags_merged.dz = (rob_commit_fp_flags_valid && rob_commit.fp_flags.dz) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.dz);
    rob_commit_fp_flags_merged.of = (rob_commit_fp_flags_valid && rob_commit.fp_flags.of) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.of);
    rob_commit_fp_flags_merged.uf = (rob_commit_fp_flags_valid && rob_commit.fp_flags.uf) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.uf);
    rob_commit_fp_flags_merged.nx = (rob_commit_fp_flags_valid && rob_commit.fp_flags.nx) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.nx);
  end

  // mtval for synchronous exceptions, per the RISC-V privileged spec:
  //   - BREAKPOINT (EBREAK): mtval = the breakpoint instruction's virtual
  //     address (the faulting PC, which equals mepc).
  //   - LOAD/STORE address-misaligned: mtval = the misaligned virtual
  //     address. The load_queue / SQ park that address in the head entry's
  //     CDB value slot (unused for an exception), exposed as rob_trap_value.
  //   - Everything else FROST raises here (ECALL): mtval = 0.
  logic [XLEN-1:0] csr_trap_value;
  always_comb begin
    unique case (rob_trap_cause)
      riscv_pkg::ExcBreakpoint[$bits(rob_trap_cause)-1:0]: csr_trap_value = rob_trap_pc;
      riscv_pkg::ExcLoadAddrMisalign[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcStoreAddrMisalign[$bits(
          rob_trap_cause
      )-1:0]:
      csr_trap_value = rob_trap_value;
      default: csr_trap_value = '0;
    endcase
  end

  // ECALL cause is privilege-dependent (U-mode = 8, M-mode = 11). The FU shim
  // tags every ECALL as ExcEcallMmode (it has no architectural privilege), so
  // remap at commit using the current privilege. csr_file writes this to mcause
  // -- the load-bearing path. It is also fed to trap_unit.i_exception_cause for
  // symmetry, though FROST does not vector mtvec on synchronous-exception causes
  // (only interrupts vector) and trap_unit's own o_trap_cause is unused. The
  // csr_trap_value (mtval) mux above intentionally keeps the ORIGINAL cause
  // (ECALL mtval is 0 either way).
  //
  // SAFE against the cause==11 / IntMachineExternal (0x8000_000B) low-bit
  // collision: rob_trap_cause carries synchronous-exception causes ONLY (ROB
  // o_trap_cause = head_exc_cause; the ROB's i_interrupt_pending is WFI-wakeup
  // only, never a cause source), so a value of 11 here is unambiguously an
  // M-mode ECALL.
  assign rob_trap_cause_remapped =
      ((rob_trap_cause == riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0]) &&
       (csr_priv == riscv_pkg::PrivU)) ?
      riscv_pkg::ExcEcallUmode[riscv_pkg::ExcCauseWidth-1:0] : rob_trap_cause;

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
      .o_csr_read_data_comb(),
      .i_instruction_retired_count(instruction_retired_count),
      .i_interrupts(i_interrupts),
      .i_mtime(i_mtime),
      .i_trap_taken(trap_taken),
      .i_trap_pc(trap_pc_internal),
      // mcause from trap_unit's arbitrated cause: interrupt cause (with the
      // interrupt bit) for interrupts, or the remapped exception cause (which
      // carries the U-mode ECALL remap via trap_unit.i_exception_cause below).
      .i_trap_cause(trap_cause_internal),
      .i_trap_value(csr_trap_value),
      .i_mret_taken(mret_taken),
      .o_mstatus(csr_mstatus),
      .o_mie(csr_mie),
      .o_mtvec(csr_mtvec),
      .o_mepc(csr_mepc),
      .o_mstatus_mie_direct(csr_mstatus_mie_direct),
      .o_priv(csr_priv),
      // FP flags: accumulated from ROB commit
      .i_fp_flags(rob_commit_fp_flags_merged),
      .i_fp_flags_valid(rob_commit_any_fp_flags_valid),
      .i_fp_flags_wb_valid(rob_commit_any_fp_flags_valid),
      .i_fp_flags_ma('0),
      .i_fp_flags_ma_valid(1'b0),
      .o_frm(frm_csr),
      .o_perf_counter_select(perf_counter_select),
      .o_perf_snapshot_capture(perf_snapshot_capture),
      .i_perf_counter_data(perf_counter_data_q),
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
  logic [XLEN-1:0] trap_value_internal;
  logic [XLEN-1:0] interrupt_resume_pc;

  function automatic logic [XLEN-1:0] retired_next_pc(
      input riscv_pkg::reorder_buffer_commit_t commit
  );
    logic [XLEN-1:0] step;
    begin
      step = commit.is_compressed ? {{(XLEN - 2){1'b0}}, 2'b10} :
                                    {{(XLEN - 3){1'b0}}, 3'b100};
      if (commit.is_branch || commit.is_mret) begin
        retired_next_pc = commit.redirect_pc;
      end else begin
        retired_next_pc = commit.pc + step;
      end
    end
  endfunction

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      interrupt_resume_pc <= '0;
    end else if (mret_taken) begin
      // An MRET retires through the trap/MRET full flush, NOT the normal commit
      // path: the cycle after o_mret_taken, flush_all (from mret_taken_reg)
      // wipes the ROB head and gates commit_en, so the MRET never appears on
      // rob_commit_valid_raw and never updates interrupt_resume_pc via the
      // branches below. Without this seed, interrupt_resume_pc keeps the
      // architectural next-PC of the instruction *before* the MRET -- which is
      // the MRET instruction's own PC -- for the entire MRET-to-U window (until
      // the first post-MRET instruction commits). A machine interrupt taken
      // after privilege drops below M (eligible once the trap_unit inhibit
      // lifts, ~2 cycles later, long before that first commit) would then save
      // mepc = <MRET PC>, an M-mode handler address, which Linux later restores
      // and MRETs to illegally in U-mode (the ret_from_exception 0x80388bba
      // panic). Seed the resume PC from the MRET target (mepc, == the MRET
      // redirect target) now so it is already correct before the inhibit
      // window closes. csr_mepc is stable here: MRET does not write mepc and
      // cannot coincide with a trap entry that would.
      interrupt_resume_pc <= csr_mepc;
    end else if (rob_commit_2_valid_raw) begin
      interrupt_resume_pc <= retired_next_pc(rob_commit_comb_2);
    end else if (rob_commit_valid_raw) begin
      interrupt_resume_pc <= retired_next_pc(rob_commit_comb);
    end
  end

  // A same-cycle store-like ROB commit is not yet in the SQ committed set.
  // If a trap full-flushes here, the registered commit can be masked before
  // SQ observes it. Delay trap/MRET one cycle so SQ can own and drain it.
  assign sq_committed_empty_for_trap =
      sq_committed_empty && !rob_commit_store_like_raw && !rob_commit_2_store_like_raw;

  trap_unit #(
      .XLEN(XLEN)
  ) trap_unit_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_stall(1'b0),  // OOO: no stall for trap check
      .i_sq_committed_empty(sq_committed_empty_for_trap),
      .o_trap_drain_wait(trap_drain_wait),
      .i_mstatus(csr_mstatus),
      .i_mie(csr_mie),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      .i_priv(csr_priv),
      .i_interrupts(i_interrupts),
      // Exception from ROB commit
      .i_exception_valid(trap_pending),
      .i_exception_cause({
        {(XLEN - $bits(rob_trap_cause_remapped)) {1'b0}}, rob_trap_cause_remapped
      }),
      .i_exception_tval('0),
      .i_exception_pc(rob_trap_pc),
      .i_interrupt_pc(interrupt_resume_pc),
      .i_mret_start(mret_start),
      .i_wfi_start(1'b0),  // WFI handled by ROB serialization
      .o_trap_taken(trap_taken),
      .o_mret_taken(mret_taken),
      .o_trap_target(trap_target),
      .o_trap_pc(trap_pc_internal),
      .o_trap_cause(trap_cause_internal),
      .o_trap_value(trap_value_internal),
      .o_stall_for_wfi()  // WFI stall handled at ROB head
  );

`ifndef SYNTHESIS
  // FROST DEBUG (TEMP -- remove after the first-timer-IRQ ra-corruption hunt):
  // (1) every trap taken -- does a commit write-port collide this cycle (codex
  //     #3: async interrupt + same-cycle commit corrupting x1/ra + saved PC)?
  // (2/3) any commit that writes x1/ra a bogus LOW value (the 0xcc0 panic ra).
  // (4) heartbeat every 500k cycles: is the CPU progressing (head_pc advancing)
  //     or stuck (e.g. a DDR load that never returns) before the first IRQ?
  int unsigned frost_cyc = 0;
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      frost_cyc <= frost_cyc + 1;
      if ((frost_cyc % 500000) == 0)
        $display("FROST_HB cyc=%0d head_pc=%08x trap_taken=%b cmt_vld=%b p0we=%b p0a=%0d",
                 frost_cyc, rob_trap_pc, trap_taken, rob_commit_valid, port0_int_we,
                 port0_int_addr);
      if (trap_taken)
        $display("FROST_DBG %0t TRAP cause=%08x csr_pc=%08x rob_pc=%08x resume_pc=%08x mepc=%08x | p0we=%b p0a=%0d p0d=%08x p1we=%b p1a=%0d p1d=%08x cmt_vld=%b",
                 $time, trap_cause_internal, trap_pc_internal, rob_trap_pc,
                 interrupt_resume_pc, csr_mepc, port0_int_we, port0_int_addr,
                 port0_int_data, port1_int_we, port1_int_addr, port1_int_data,
                 rob_commit_valid);
      if (port0_int_we && (port0_int_addr == 5'd1) && (port0_int_data < 32'h0000_1000))
        $display("FROST_DBG %0t *** RA<-%08x PORT0 trap_taken=%b rob_trap_pc=%08x mepc=%08x",
                 $time, port0_int_data, trap_taken, rob_trap_pc, csr_mepc);
      if (port1_int_we && (port1_int_addr == 5'd1) && (port1_int_data < 32'h0000_1000))
        $display("FROST_DBG %0t *** RA<-%08x PORT1 trap_taken=%b rob_trap_pc=%08x mepc=%08x",
                 $time, port1_int_data, trap_taken, rob_trap_pc, csr_mepc);
    end
  end
`endif

  // Use the registered trap/mret pulses when driving the front-end flush so
  // flush_pipeline no longer rides on the combinational
  //   rob_valid[head_idx] → commit_en → trap_unit → trap_taken
  // cone. The ROB-side flush_all already consumes trap_taken_reg /
  // mret_taken_reg (see the flush_en block), so the front-end flush now
  // aligns with the backend's one-cycle-late full-flush pulse rather than
  // leading it. Trap handling pays an extra cycle of frontend squash, which
  // is negligible for non-exception workloads (CoreMark, ISA tests, normal
  // programs) and stays behind the already-registered trap_target_reg /
  // rob_trap_taken_ack handshake. Breaks the -0.982 ns rob_valid_reg[27] →
  // pd_stage btb_predicted_target critical path.
  assign flush_for_trap = trap_taken_reg;
  assign flush_for_mret = mret_taken_reg;

  // Acknowledge trap/mret to the ROB on the registered recovery pulse. This
  // keeps the head trap metadata stable through the CSR trap-entry update; the
  // commit hold above blocks younger retirement during the delay.
  assign rob_trap_taken_ack = trap_taken_reg;
  assign mret_done_ack = mret_taken_reg;

  // ===========================================================================
  // Profiling Counter Aggregation
  // ===========================================================================
  perf_counter_aggregator perf_counter_aggregator_inst (
      .i_clk,
      .i_rst,
      .i_rob_alloc_req(rob_alloc_req),
      .i_dispatch_status(dispatch_status),
      .i_rob_commit_comb(rob_commit_comb),
      .i_flush_pipeline(flush_pipeline),
      .i_post_flush_holdoff_q(post_flush_holdoff_q),
      .i_csr_in_flight(csr_in_flight),
      .i_csr_wb_pending(csr_wb_pending),
      .i_serializing_alloc_fire(serializing_alloc_fire),
      .i_front_end_cf_serialize_stall(front_end_cf_serialize_stall),
      .i_rob_empty(rob_empty),
      .i_disable_branch_prediction_ooo(disable_branch_prediction_ooo),
      .i_disable_branch_prediction(i_disable_branch_prediction),
      .i_prediction_fence_branch(prediction_fence_branch),
      .i_prediction_fence_jal(prediction_fence_jal),
      .i_prediction_fence_indirect(prediction_fence_indirect),
      .i_perf_counter_select(perf_counter_select),
      .i_perf_snapshot_capture(perf_snapshot_capture),
      .i_wrapper_perf_counter_data(wrapper_perf_counter_data),
      .o_wrapper_perf_counter_select(wrapper_perf_counter_select),
      .o_perf_counter_data_q(perf_counter_data_q),
      .o_perf_counter_count(perf_counter_count)
  );

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
