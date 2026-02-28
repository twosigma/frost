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
 * Tomasulo Integration Wrapper
 *
 * Verification wrapper that instantiates ROB + RAT + six RS instances
 * (INT_RS, MUL_RS, MEM_RS, FP_RS, FMUL_RS, FDIV_RS) and hardwires the
 * internal commit bus, dispatch routing, and shared CDB/flush signals.
 *
 * Replaces the previous rob_rat_wrapper as the integration test vehicle.
 * This wrapper will grow as CDB arbiter, LQ, SQ, ALUs, and FPUs are added.
 *
 * Dispatch routing:
 *   i_rs_dispatch.rs_type is decoded to per-RS dispatch valid signals.
 *   All RS instances share the same dispatch data bus; only the valid
 *   signal is gated per RS type.
 *
 * Internal wiring:
 *   ROB.o_commit --> commit_bus --> RAT.i_commit
 *                               --> o_commit (exposed for testbench observation)
 *   i_fu_complete --> cdb_arbiter --> cdb_bus --> ROB.i_cdb_write (derived)
 *                                            --> all RS .i_cdb (broadcast for wakeup)
 *   cdb_arbiter.o_grant --> o_cdb_grant (back-pressure to FUs)
 *   Flush --> all modules
 *   ROB.o_head_tag --> all RS .i_rob_head_tag (for age-based partial flush)
 */

module tomasulo_wrapper (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // ROB Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // =========================================================================
    // FU Completion Requests (to CDB Arbiter)
    // =========================================================================
`ifdef VERILATOR
    input riscv_pkg::fu_complete_t i_fu_complete  [riscv_pkg::NumFus],
`else
    input riscv_pkg::fu_complete_t i_fu_complete_0,
    input riscv_pkg::fu_complete_t i_fu_complete_1,
    input riscv_pkg::fu_complete_t i_fu_complete_2,
    input riscv_pkg::fu_complete_t i_fu_complete_3,
    input riscv_pkg::fu_complete_t i_fu_complete_4,
    input riscv_pkg::fu_complete_t i_fu_complete_5,
    input riscv_pkg::fu_complete_t i_fu_complete_6,
`endif

    // =========================================================================
    // CDB Grant (back-pressure to FUs)
    // =========================================================================
    output logic [riscv_pkg::NumFus-1:0] o_cdb_grant,

    // =========================================================================
    // CDB Broadcast Output (for testbench observation)
    // =========================================================================
    output riscv_pkg::cdb_broadcast_t o_cdb,

    // =========================================================================
    // ROB Branch Update Interface (from Branch Unit)
    // =========================================================================
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // ROB Checkpoint Recording (from Dispatch)
    // =========================================================================
    input logic                                    i_rob_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_rob_checkpoint_id,

    // =========================================================================
    // Commit Observation (tapped from internal commit bus)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,

    // =========================================================================
    // ROB External Coordination
    // =========================================================================
    input  logic                                        i_sq_empty,
    output logic                                        o_csr_start,
    input  logic                                        i_csr_done,
    output logic                                        o_trap_pending,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_pc,
    output riscv_pkg::exc_cause_t                       o_trap_cause,
    input  logic                                        i_trap_taken,
    output logic                                        o_mret_start,
    input  logic                                        i_mret_done,
    input  logic                  [riscv_pkg::XLEN-1:0] i_mepc,
    input  logic                                        i_interrupt_pending,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // ROB Status
    // =========================================================================
    output logic                                        o_fence_i_flush,
    output logic                                        o_rob_full,
    output logic                                        o_rob_empty,
    output logic [  riscv_pkg::ReorderBufferTagWidth:0] o_rob_count,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // ROB Bypass Read
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,

    // =========================================================================
    // RAT Source Lookups (combinational)
    // =========================================================================
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr,
    output riscv_pkg::rat_lookup_t                               o_int_src1,
    output riscv_pkg::rat_lookup_t                               o_int_src2,

    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr,
    output riscv_pkg::rat_lookup_t                               o_fp_src1,
    output riscv_pkg::rat_lookup_t                               o_fp_src2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3,

    // RAT Regfile data
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // =========================================================================
    // RAT Rename (from Dispatch)
    // =========================================================================
    input logic                                        i_rat_alloc_valid,
    input logic                                        i_rat_alloc_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag,

    // =========================================================================
    // RAT Checkpoint Save (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Restore (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Free (from ROB on correct branch commit)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,

    // =========================================================================
    // RAT Checkpoint Availability
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id,

    // =========================================================================
    // RS Dispatch (from Dispatch)
    // =========================================================================
`ifdef ICARUS
    input logic i_rs_dispatch_valid,
    input logic [2:0] i_rs_dispatch_rs_type,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_rob_tag,
    input logic [31:0] i_rs_dispatch_op,
    input logic i_rs_dispatch_src1_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src1_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src1_value,
    input logic i_rs_dispatch_src2_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src2_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src2_value,
    input logic i_rs_dispatch_src3_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src3_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src3_value,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_imm,
    input logic i_rs_dispatch_use_imm,
    input logic [2:0] i_rs_dispatch_rm,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_branch_target,
    input logic i_rs_dispatch_predicted_taken,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_predicted_target,
    input logic i_rs_dispatch_is_fp_mem,
    input logic [1:0] i_rs_dispatch_mem_size,
    input logic i_rs_dispatch_mem_signed,
    input logic [11:0] i_rs_dispatch_csr_addr,
    input logic [4:0] i_rs_dispatch_csr_imm,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_pc,
`else
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
`endif
    output logic o_rs_full,

    // =========================================================================
    // RS Issue (to Functional Unit)
    // =========================================================================
`ifdef ICARUS
    output logic                                                        o_rs_issue_valid,
    output logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] o_rs_issue_rob_tag,
    output logic                 [                                31:0] o_rs_issue_op,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src1_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src2_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src3_value,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_imm,
    output logic                                                        o_rs_issue_use_imm,
    output logic                 [                                 2:0] o_rs_issue_rm,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_branch_target,
    output logic                                                        o_rs_issue_predicted_taken,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_predicted_target,
    output logic                                                        o_rs_issue_is_fp_mem,
    output logic                 [                                 1:0] o_rs_issue_mem_size,
    output logic                                                        o_rs_issue_mem_signed,
    output logic                 [                                11:0] o_rs_issue_csr_addr,
    output logic                 [                                 4:0] o_rs_issue_csr_imm,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_pc,
`else
    output riscv_pkg::rs_issue_t                                        o_rs_issue,
`endif
    input  logic                                                        i_rs_fu_ready,

    // =========================================================================
    // RS Status (INT_RS)
    // =========================================================================
    output logic       o_int_rs_full,
    output logic       o_rs_empty,
    output logic [3:0] o_rs_count,

    // =========================================================================
    // MUL_RS (Integer multiply/divide, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mul_rs_issue,
    input  logic                                                           i_mul_rs_fu_ready,
    output logic                                                           o_mul_rs_full,
    output logic                                                           o_mul_rs_empty,
    output logic                 [$clog2(riscv_pkg::MulRsDepth + 1) - 1:0] o_mul_rs_count,

    // =========================================================================
    // MEM_RS (Load/store, depth 8)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mem_rs_issue,
    input  logic                                                           i_mem_rs_fu_ready,
    output logic                                                           o_mem_rs_full,
    output logic                                                           o_mem_rs_empty,
    output logic                 [$clog2(riscv_pkg::MemRsDepth + 1) - 1:0] o_mem_rs_count,

    // =========================================================================
    // FP_RS (FP add/sub/cmp/cvt/classify/sgnj, depth 6)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                          o_fp_rs_issue,
    input  logic                                                          i_fp_rs_fu_ready,
    output logic                                                          o_fp_rs_full,
    output logic                                                          o_fp_rs_empty,
    output logic                 [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] o_fp_rs_count,

    // =========================================================================
    // FMUL_RS (FP multiply/FMA, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fmul_rs_issue,
    input  logic                                                            i_fmul_rs_fu_ready,
    output logic                                                            o_fmul_rs_full,
    output logic                                                            o_fmul_rs_empty,
    output logic                 [$clog2(riscv_pkg::FmulRsDepth + 1) - 1:0] o_fmul_rs_count,

    // =========================================================================
    // FDIV_RS (FP divide/sqrt, depth 2)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fdiv_rs_issue,
    input  logic                                                            i_fdiv_rs_fu_ready,
    output logic                                                            o_fdiv_rs_full,
    output logic                                                            o_fdiv_rs_empty,
    output logic                 [$clog2(riscv_pkg::FdivRsDepth + 1) - 1:0] o_fdiv_rs_count,

    // =========================================================================
    // CSR Read Data (for ALU shim — CSR operations return old CSR value)
    // =========================================================================
    input logic [riscv_pkg::XLEN-1:0] i_csr_read_data,

    // =========================================================================
    // Load Queue: SQ Disambiguation (driven by testbench until SQ added)
    // =========================================================================
    input logic i_sq_all_older_addrs_known,
    input riscv_pkg::sq_forward_result_t i_sq_forward,
    output logic o_sq_check_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_sq_check_rob_tag,
    output riscv_pkg::mem_size_e o_sq_check_size,

    // =========================================================================
    // Load Queue: Memory Interface
    // =========================================================================
    output logic                                       o_lq_mem_read_en,
    output logic                 [riscv_pkg::XLEN-1:0] o_lq_mem_read_addr,
    output riscv_pkg::mem_size_e                       o_lq_mem_read_size,
    input  logic                 [riscv_pkg::XLEN-1:0] i_lq_mem_read_data,
    input  logic                                       i_lq_mem_read_valid,

    // =========================================================================
    // Load Queue: L0 Cache Invalidation (from SQ, future)
    // =========================================================================
    input logic                       i_cache_invalidate_valid,
    input logic [riscv_pkg::XLEN-1:0] i_cache_invalidate_addr,

    // =========================================================================
    // Load Queue: Status
    // =========================================================================
    output logic                                    o_lq_full,
    output logic                                    o_lq_empty,
    output logic [$clog2(riscv_pkg::LqDepth+1)-1:0] o_lq_count
);

  // ===========================================================================
  // Internal commit bus: ROB -> RAT
  // ===========================================================================
  riscv_pkg::reorder_buffer_commit_t commit_bus;

  // Expose commit bus to testbench
  assign o_commit = commit_bus;

  // Head tag for RS partial flush
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  assign head_tag = o_head_tag;

  // ===========================================================================
  // CDB Arbiter: FU completions → single CDB broadcast
  // ===========================================================================
  riscv_pkg::cdb_broadcast_t cdb_bus;

`ifdef VERILATOR
  // Override slots 0-6: internal FU pipelines replace external i_fu_complete.
  // Slots 4-6 use a priority mux: internal FP adapter takes precedence,
  // external i_fu_complete falls through when idle (test injection path).
  riscv_pkg::fu_complete_t cdb_arb_in[riscv_pkg::NumFus];
  always_comb begin
    cdb_arb_in[0] = alu_adapter_to_arbiter;
    cdb_arb_in[1] = mul_adapter_to_arbiter;
    cdb_arb_in[2] = div_adapter_to_arbiter;
    cdb_arb_in[3] = mem_adapter_to_arbiter;
    cdb_arb_in[4] = fp_add_adapter_to_arbiter.valid ? fp_add_adapter_to_arbiter : i_fu_complete[4];
    cdb_arb_in[5] = fp_mul_adapter_to_arbiter.valid ? fp_mul_adapter_to_arbiter : i_fu_complete[5];
    cdb_arb_in[6] = fp_div_adapter_to_arbiter.valid ? fp_div_adapter_to_arbiter : i_fu_complete[6];
  end

  cdb_arbiter u_cdb_arbiter (
      .i_clk        (i_clk),
      .i_rst_n      (i_rst_n),
      .i_fu_complete(cdb_arb_in),
      .o_cdb        (cdb_bus),
      .o_grant      (o_cdb_grant)
  );
`else
  // Icarus / Yosys: connect individual flattened ports
  // Slots 0-2 come from internal FU pipelines; slots 3-6 from external ports
  cdb_arbiter u_cdb_arbiter (
      .i_clk          (i_clk),
      .i_rst_n        (i_rst_n),
      .i_fu_complete_0(alu_adapter_to_arbiter),
      .i_fu_complete_1(mul_adapter_to_arbiter),
      .i_fu_complete_2(div_adapter_to_arbiter),
      .i_fu_complete_3(mem_adapter_to_arbiter),
      .i_fu_complete_4(fp_add_adapter_to_arbiter),
      .i_fu_complete_5(fp_mul_adapter_to_arbiter),
      .i_fu_complete_6(fp_div_adapter_to_arbiter),
      .o_cdb          (cdb_bus),
      .o_grant        (o_cdb_grant)
  );
`endif

  // Expose CDB broadcast for testbench observation
  assign o_cdb = cdb_bus;

  // Derive ROB CDB write from CDB broadcast
  riscv_pkg::reorder_buffer_cdb_write_t cdb_write_from_arbiter;
  always_comb begin
    cdb_write_from_arbiter.valid     = cdb_bus.valid;
    cdb_write_from_arbiter.tag       = cdb_bus.tag;
    cdb_write_from_arbiter.value     = cdb_bus.value;
    cdb_write_from_arbiter.exception = cdb_bus.exception;
    cdb_write_from_arbiter.exc_cause = cdb_bus.exc_cause;
    cdb_write_from_arbiter.fp_flags  = cdb_bus.fp_flags;
  end

  // ===========================================================================
  // Dispatch Routing: decode rs_type to per-RS dispatch valid signals
  // ===========================================================================
  logic int_rs_dispatch_valid;
  logic mul_rs_dispatch_valid;
  logic mem_rs_dispatch_valid;
  logic fp_rs_dispatch_valid;
  logic fmul_rs_dispatch_valid;
  logic fdiv_rs_dispatch_valid;

`ifdef ICARUS
  wire [2:0] dispatch_rs_type = i_rs_dispatch_rs_type;
  wire       dispatch_valid = i_rs_dispatch_valid;
`else
  wire [2:0] dispatch_rs_type = i_rs_dispatch.rs_type;
  wire       dispatch_valid = i_rs_dispatch.valid;
`endif

  always_comb begin
    int_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_INT);
    mul_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MUL);
    mem_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MEM);
    fp_rs_dispatch_valid   = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FP);
    fmul_rs_dispatch_valid = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FMUL);
    fdiv_rs_dispatch_valid = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FDIV);
  end

  // Internal full signals for mux
  logic int_rs_full_w;
  logic mul_rs_full_w;
  logic mem_rs_full_w;
  logic fp_rs_full_w;
  logic fmul_rs_full_w;
  logic fdiv_rs_full_w;

  // o_rs_full: dispatch-target mux (NOT dedicated INT_RS full; use o_int_rs_full)
  always_comb begin
    case (dispatch_rs_type)
      riscv_pkg::RS_INT:  o_rs_full = int_rs_full_w;
      riscv_pkg::RS_MUL:  o_rs_full = mul_rs_full_w;
      riscv_pkg::RS_MEM:  o_rs_full = mem_rs_full_w;
      riscv_pkg::RS_FP:   o_rs_full = fp_rs_full_w;
      riscv_pkg::RS_FMUL: o_rs_full = fmul_rs_full_w;
      riscv_pkg::RS_FDIV: o_rs_full = fdiv_rs_full_w;
      default:            o_rs_full = 1'b0;
    endcase
  end

  // Per-RS full output ports (dedicated, not muxed)
  assign o_int_rs_full  = int_rs_full_w;
  assign o_mul_rs_full  = mul_rs_full_w;
  assign o_mem_rs_full  = mem_rs_full_w;
  assign o_fp_rs_full   = fp_rs_full_w;
  assign o_fmul_rs_full = fmul_rs_full_w;
  assign o_fdiv_rs_full = fdiv_rs_full_w;

  // ===========================================================================
  // ALU Pipeline: INT_RS issue → shim → adapter → CDB arbiter slot 0
  // ===========================================================================
  riscv_pkg::rs_issue_t    int_rs_issue_w;  // INT_RS issue output
  riscv_pkg::fu_complete_t alu_shim_out;  // ALU shim → adapter
  riscv_pkg::fu_complete_t alu_adapter_to_arbiter;  // adapter → arbiter
  logic                    alu_adapter_result_pending;
  logic                    alu_fu_busy;  // always 0 for single-cycle ALU
  logic                    int_rs_fu_ready;

  assign int_rs_fu_ready = i_rs_fu_ready & ~alu_adapter_result_pending;

  // ===========================================================================
  // MUL/DIV Pipeline: MUL_RS issue → shim → adapters → CDB arbiter slots 1,2
  // ===========================================================================
  riscv_pkg::rs_issue_t    mul_rs_issue_w;  // MUL_RS issue output (internal)
  riscv_pkg::fu_complete_t mul_shim_out;  // shim MUL → adapter
  riscv_pkg::fu_complete_t div_shim_out;  // shim DIV → adapter
  riscv_pkg::fu_complete_t mul_adapter_to_arbiter;  // adapter → arbiter slot 1
  riscv_pkg::fu_complete_t div_adapter_to_arbiter;  // adapter → arbiter slot 2
  logic                    mul_adapter_result_pending;
  logic                    div_adapter_result_pending;
  logic                    muldiv_busy;
  logic                    mul_rs_fu_ready;

  assign mul_rs_fu_ready = i_mul_rs_fu_ready & ~muldiv_busy
                           & ~mul_adapter_result_pending & ~div_adapter_result_pending;

  // DIV result accepted: the adapter consumes the shim's output this cycle.
  // Either the adapter is idle and the shim presents a valid result (pass-through),
  // or the adapter is pending, gets granted, and the shim presents a new valid result.
  logic div_result_accepted;
  assign div_result_accepted =
      (!div_adapter_result_pending && div_shim_out.valid) ||
      (div_adapter_result_pending && o_cdb_grant[2] && div_shim_out.valid);

  // ===========================================================================
  // MEM (Load) Pipeline: LQ → adapter → CDB arbiter slot 3
  // ===========================================================================
  riscv_pkg::fu_complete_t lq_fu_complete;  // LQ → adapter
  riscv_pkg::fu_complete_t mem_adapter_to_arbiter;  // adapter → arbiter slot 3
  logic                    mem_adapter_result_pending;

  // ===========================================================================
  // FP_ADD Pipeline: FP_RS issue → fp_add_shim → adapter → CDB arbiter slot 4
  // ===========================================================================
  riscv_pkg::rs_issue_t    fp_rs_issue_w;  // FP_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_add_shim_out;  // shim → adapter
  riscv_pkg::fu_complete_t fp_add_adapter_to_arbiter;  // adapter → arbiter
  logic                    fp_add_adapter_result_pending;
  logic                    fp_add_busy;
  logic                    fp_rs_fu_ready;

  assign fp_rs_fu_ready = i_fp_rs_fu_ready & ~fp_add_busy & ~fp_add_adapter_result_pending;

  // ===========================================================================
  // FP_MUL Pipeline: FMUL_RS issue → fp_mul_shim → adapter → CDB arbiter slot 5
  // ===========================================================================
  riscv_pkg::rs_issue_t    fmul_rs_issue_w;  // FMUL_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_mul_shim_out;
  riscv_pkg::fu_complete_t fp_mul_adapter_to_arbiter;
  logic                    fp_mul_adapter_result_pending;
  logic                    fp_mul_busy;
  logic                    fmul_rs_fu_ready;

  assign fmul_rs_fu_ready = i_fmul_rs_fu_ready & ~fp_mul_busy & ~fp_mul_adapter_result_pending;

  // ===========================================================================
  // FP_DIV Pipeline: FDIV_RS issue → fp_div_shim → adapter → CDB arbiter slot 6
  // ===========================================================================
  riscv_pkg::rs_issue_t    fdiv_rs_issue_w;  // FDIV_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_div_shim_out;
  riscv_pkg::fu_complete_t fp_div_adapter_to_arbiter;
  logic                    fp_div_adapter_result_pending;
  logic                    fp_div_busy;
  logic                    fdiv_rs_fu_ready;

  assign fdiv_rs_fu_ready = i_fdiv_rs_fu_ready & ~fp_div_busy & ~fp_div_adapter_result_pending;

  // ===========================================================================
  // Reorder Buffer Instance
  // ===========================================================================
  reorder_buffer u_rob (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation
      .i_alloc_req (i_alloc_req),
      .o_alloc_resp(o_alloc_resp),

      // CDB (from arbiter)
      .i_cdb_write(cdb_write_from_arbiter),

      // Branch
      .i_branch_update(i_branch_update),

      // Checkpoint recording
      .i_checkpoint_valid(i_rob_checkpoint_valid),
      .i_checkpoint_id   (i_rob_checkpoint_id),

      // Commit output -> internal bus
      .o_commit(commit_bus),

      // External coordination
      .i_sq_empty         (i_sq_empty),
      .o_csr_start        (o_csr_start),
      .i_csr_done         (i_csr_done),
      .o_trap_pending     (o_trap_pending),
      .o_trap_pc          (o_trap_pc),
      .o_trap_cause       (o_trap_cause),
      .i_trap_taken       (i_trap_taken),
      .o_mret_start       (o_mret_start),
      .i_mret_done        (i_mret_done),
      .i_mepc             (i_mepc),
      .i_interrupt_pending(i_interrupt_pending),

      // Flush
      .i_flush_en (i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(i_flush_all),

      // Status
      .o_fence_i_flush(o_fence_i_flush),
      .o_full         (o_rob_full),
      .o_empty        (o_rob_empty),
      .o_count        (o_rob_count),
      .o_head_tag     (o_head_tag),
      .o_head_valid   (o_head_valid),
      .o_head_done    (o_head_done),

      // Bypass read
      .i_read_tag  (i_read_tag),
      .o_read_done (o_read_done),
      .o_read_value(o_read_value)
  );

  // ===========================================================================
  // Register Alias Table Instance
  // ===========================================================================
  register_alias_table u_rat (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Source lookups
      .i_int_src1_addr(i_int_src1_addr),
      .i_int_src2_addr(i_int_src2_addr),
      .o_int_src1     (o_int_src1),
      .o_int_src2     (o_int_src2),
      .i_fp_src1_addr (i_fp_src1_addr),
      .i_fp_src2_addr (i_fp_src2_addr),
      .i_fp_src3_addr (i_fp_src3_addr),
      .o_fp_src1      (o_fp_src1),
      .o_fp_src2      (o_fp_src2),
      .o_fp_src3      (o_fp_src3),

      // Regfile data
      .i_int_regfile_data1(i_int_regfile_data1),
      .i_int_regfile_data2(i_int_regfile_data2),
      .i_fp_regfile_data1 (i_fp_regfile_data1),
      .i_fp_regfile_data2 (i_fp_regfile_data2),
      .i_fp_regfile_data3 (i_fp_regfile_data3),

      // Rename
      .i_alloc_valid   (i_rat_alloc_valid),
      .i_alloc_dest_rf (i_rat_alloc_dest_rf),
      .i_alloc_dest_reg(i_rat_alloc_dest_reg),
      .i_alloc_rob_tag (i_rat_alloc_rob_tag),

      // Commit (from internal bus)
      .i_commit(commit_bus),

      // Checkpoint save
      .i_checkpoint_save      (i_checkpoint_save),
      .i_checkpoint_id        (i_checkpoint_id),
      .i_checkpoint_branch_tag(i_checkpoint_branch_tag),
      .i_ras_tos              (i_ras_tos),
      .i_ras_valid_count      (i_ras_valid_count),

      // Checkpoint restore
      .i_checkpoint_restore   (i_checkpoint_restore),
      .i_checkpoint_restore_id(i_checkpoint_restore_id),
      .o_ras_tos              (o_ras_tos),
      .o_ras_valid_count      (o_ras_valid_count),

      // Checkpoint free
      .i_checkpoint_free   (i_checkpoint_free),
      .i_checkpoint_free_id(i_checkpoint_free_id),

      // Flush
      .i_flush_all(i_flush_all),

      // Checkpoint availability
      .o_checkpoint_available(o_checkpoint_available),
      .o_checkpoint_alloc_id (o_checkpoint_alloc_id)
  );

  // ===========================================================================
  // Reservation Station Instances
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // INT_RS (depth 8): Integer ALU ops, branches, CSR
  // ---------------------------------------------------------------------------
`ifdef ICARUS
  // Individual port connections -- avoids wide packed struct VPI-facing ports
  // (Icarus VPI crashes on 352+ bit struct ports; see reservation_station.sv).
  reservation_station #(
      .DEPTH(riscv_pkg::IntRsDepth)
  ) u_int_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch (individual ports)
      .i_dispatch_valid           (int_rs_dispatch_valid),
      .i_dispatch_rs_type         (i_rs_dispatch_rs_type),
      .i_dispatch_rob_tag         (i_rs_dispatch_rob_tag),
      .i_dispatch_op              (i_rs_dispatch_op),
      .i_dispatch_src1_ready      (i_rs_dispatch_src1_ready),
      .i_dispatch_src1_tag        (i_rs_dispatch_src1_tag),
      .i_dispatch_src1_value      (i_rs_dispatch_src1_value),
      .i_dispatch_src2_ready      (i_rs_dispatch_src2_ready),
      .i_dispatch_src2_tag        (i_rs_dispatch_src2_tag),
      .i_dispatch_src2_value      (i_rs_dispatch_src2_value),
      .i_dispatch_src3_ready      (i_rs_dispatch_src3_ready),
      .i_dispatch_src3_tag        (i_rs_dispatch_src3_tag),
      .i_dispatch_src3_value      (i_rs_dispatch_src3_value),
      .i_dispatch_imm             (i_rs_dispatch_imm),
      .i_dispatch_use_imm         (i_rs_dispatch_use_imm),
      .i_dispatch_rm              (i_rs_dispatch_rm),
      .i_dispatch_branch_target   (i_rs_dispatch_branch_target),
      .i_dispatch_predicted_taken (i_rs_dispatch_predicted_taken),
      .i_dispatch_predicted_target(i_rs_dispatch_predicted_target),
      .i_dispatch_is_fp_mem       (i_rs_dispatch_is_fp_mem),
      .i_dispatch_mem_size        (i_rs_dispatch_mem_size),
      .i_dispatch_mem_signed      (i_rs_dispatch_mem_signed),
      .i_dispatch_csr_addr        (i_rs_dispatch_csr_addr),
      .i_dispatch_csr_imm         (i_rs_dispatch_csr_imm),
      .i_dispatch_pc              (i_rs_dispatch_pc),
      .o_full                     (int_rs_full_w),

      // CDB snoop (from arbiter)
      .i_cdb(cdb_bus),

      // Issue (individual ports → internal wires for shim)
      .o_issue_valid           (o_rs_issue_valid),
      .o_issue_rob_tag         (o_rs_issue_rob_tag),
      .o_issue_op              (o_rs_issue_op),
      .o_issue_src1_value      (o_rs_issue_src1_value),
      .o_issue_src2_value      (o_rs_issue_src2_value),
      .o_issue_src3_value      (o_rs_issue_src3_value),
      .o_issue_imm             (o_rs_issue_imm),
      .o_issue_use_imm         (o_rs_issue_use_imm),
      .o_issue_rm              (o_rs_issue_rm),
      .o_issue_branch_target   (o_rs_issue_branch_target),
      .o_issue_predicted_taken (o_rs_issue_predicted_taken),
      .o_issue_predicted_target(o_rs_issue_predicted_target),
      .o_issue_is_fp_mem       (o_rs_issue_is_fp_mem),
      .o_issue_mem_size        (o_rs_issue_mem_size),
      .o_issue_mem_signed      (o_rs_issue_mem_signed),
      .o_issue_csr_addr        (o_rs_issue_csr_addr),
      .o_issue_csr_imm         (o_rs_issue_csr_imm),
      .o_issue_pc              (o_rs_issue_pc),
      .i_fu_ready              (int_rs_fu_ready),

      // Flush (shared with ROB)
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count)
  );

  // ICARUS: Pack individual RS issue outputs into struct for ALU shim.
  // Internal packed struct wires are fine for Icarus — only VPI-facing ports
  // of >352 bits cause crashes.
  always_comb begin
    int_rs_issue_w.valid            = o_rs_issue_valid;
    int_rs_issue_w.rob_tag          = o_rs_issue_rob_tag;
    int_rs_issue_w.op               = riscv_pkg::instr_op_e'(o_rs_issue_op);
    int_rs_issue_w.src1_value       = o_rs_issue_src1_value;
    int_rs_issue_w.src2_value       = o_rs_issue_src2_value;
    int_rs_issue_w.src3_value       = o_rs_issue_src3_value;
    int_rs_issue_w.imm              = o_rs_issue_imm;
    int_rs_issue_w.use_imm          = o_rs_issue_use_imm;
    int_rs_issue_w.rm               = o_rs_issue_rm;
    int_rs_issue_w.branch_target    = o_rs_issue_branch_target;
    int_rs_issue_w.predicted_taken  = o_rs_issue_predicted_taken;
    int_rs_issue_w.predicted_target = o_rs_issue_predicted_target;
    int_rs_issue_w.is_fp_mem        = o_rs_issue_is_fp_mem;
    int_rs_issue_w.mem_size         = riscv_pkg::mem_size_e'(o_rs_issue_mem_size);
    int_rs_issue_w.mem_signed       = o_rs_issue_mem_signed;
    int_rs_issue_w.csr_addr         = o_rs_issue_csr_addr;
    int_rs_issue_w.csr_imm          = o_rs_issue_csr_imm;
    int_rs_issue_w.pc               = o_rs_issue_pc;
  end

  // ICARUS: other RS types not instantiated (multi-RS integration tests
  // use Verilator; the RS module itself has standalone Icarus tests).
  assign mul_rs_full_w   = 1'b0;
  assign mem_rs_full_w   = 1'b0;
  assign fp_rs_full_w    = 1'b0;
  assign fmul_rs_full_w  = 1'b0;
  assign fdiv_rs_full_w  = 1'b0;
  assign o_mul_rs_issue  = '0;
  assign o_mem_rs_issue  = '0;
  assign o_fp_rs_issue   = '0;
  assign o_fmul_rs_issue = '0;
  assign o_fdiv_rs_issue = '0;
  assign o_mul_rs_empty  = 1'b1;
  assign o_mem_rs_empty  = 1'b1;
  assign o_fp_rs_empty   = 1'b1;
  assign o_fmul_rs_empty = 1'b1;
  assign o_fdiv_rs_empty = 1'b1;
  assign o_mul_rs_count  = '0;
  assign o_mem_rs_count  = '0;
  assign o_fp_rs_count   = '0;
  assign o_fmul_rs_count = '0;
  assign o_fdiv_rs_count = '0;
`else
  // Packed struct port connections (Verilator, synthesis, formal).

  // INT_RS dispatch with routed valid
  riscv_pkg::rs_dispatch_t int_rs_dispatch;
  always_comb begin
    int_rs_dispatch       = i_rs_dispatch;
    int_rs_dispatch.valid = int_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::IntRsDepth)
  ) u_int_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch
      .i_dispatch(int_rs_dispatch),
      .o_full    (int_rs_full_w),

      // CDB snoop (from arbiter)
      .i_cdb(cdb_bus),

      // Issue (to internal wire for ALU shim)
      .o_issue(int_rs_issue_w),
      .i_fu_ready(int_rs_fu_ready),

      // Flush (shared with ROB)
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count)
  );

  // Observation port: expose INT_RS issue for testbench
  assign o_rs_issue = int_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MUL_RS (depth 4): Integer multiply/divide
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mul_rs_dispatch;
  always_comb begin
    mul_rs_dispatch       = i_rs_dispatch;
    mul_rs_dispatch.valid = mul_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MulRsDepth)
  ) u_mul_rs (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_dispatch    (mul_rs_dispatch),
      .o_full        (mul_rs_full_w),
      .i_cdb         (cdb_bus),
      .o_issue       (mul_rs_issue_w),
      .i_fu_ready    (mul_rs_fu_ready),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),
      .o_empty       (o_mul_rs_empty),
      .o_count       (o_mul_rs_count)
  );

  // Observation port: expose MUL_RS issue for testbench
  assign o_mul_rs_issue = mul_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MEM_RS (depth 8): Loads/stores (both INT and FP)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  always_comb begin
    mem_rs_dispatch       = i_rs_dispatch;
    mem_rs_dispatch.valid = mem_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MemRsDepth)
  ) u_mem_rs (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_dispatch    (mem_rs_dispatch),
      .o_full        (mem_rs_full_w),
      .i_cdb         (cdb_bus),
      .o_issue       (o_mem_rs_issue),
      .i_fu_ready    (i_mem_rs_fu_ready),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),
      .o_empty       (o_mem_rs_empty),
      .o_count       (o_mem_rs_count)
  );

  // ---------------------------------------------------------------------------
  // FP_RS (depth 6): FP add/sub/cmp/cvt/classify/sgnj
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  always_comb begin
    fp_rs_dispatch       = i_rs_dispatch;
    fp_rs_dispatch.valid = fp_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth)
  ) u_fp_rs (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_dispatch    (fp_rs_dispatch),
      .o_full        (fp_rs_full_w),
      .i_cdb         (cdb_bus),
      .o_issue       (fp_rs_issue_w),
      .i_fu_ready    (fp_rs_fu_ready),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),
      .o_empty       (o_fp_rs_empty),
      .o_count       (o_fp_rs_count)
  );

  // ---------------------------------------------------------------------------
  // FMUL_RS (depth 4): FP multiply/FMA (3 sources)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch;
  always_comb begin
    fmul_rs_dispatch       = i_rs_dispatch;
    fmul_rs_dispatch.valid = fmul_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FmulRsDepth)
  ) u_fmul_rs (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_dispatch    (fmul_rs_dispatch),
      .o_full        (fmul_rs_full_w),
      .i_cdb         (cdb_bus),
      .o_issue       (fmul_rs_issue_w),
      .i_fu_ready    (fmul_rs_fu_ready),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),
      .o_empty       (o_fmul_rs_empty),
      .o_count       (o_fmul_rs_count)
  );

  // ---------------------------------------------------------------------------
  // FDIV_RS (depth 2): FP divide/sqrt (long latency)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch;
  always_comb begin
    fdiv_rs_dispatch       = i_rs_dispatch;
    fdiv_rs_dispatch.valid = fdiv_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FdivRsDepth)
  ) u_fdiv_rs (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_dispatch    (fdiv_rs_dispatch),
      .o_full        (fdiv_rs_full_w),
      .i_cdb         (cdb_bus),
      .o_issue       (fdiv_rs_issue_w),
      .i_fu_ready    (fdiv_rs_fu_ready),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),
      .o_empty       (o_fdiv_rs_empty),
      .o_count       (o_fdiv_rs_count)
  );

  // Observation ports: expose FP RS issue for testbench
  assign o_fp_rs_issue   = fp_rs_issue_w;
  assign o_fmul_rs_issue = fmul_rs_issue_w;
  assign o_fdiv_rs_issue = fdiv_rs_issue_w;
`endif

  // ===========================================================================
  // ALU Shim: translate rs_issue_t → ALU → fu_complete_t
  // ===========================================================================
  int_alu_shim u_alu_shim (
      .i_clk          (i_clk),
      .i_rst_n        (i_rst_n),
      .i_rs_issue     (int_rs_issue_w),
      .i_csr_read_data(i_csr_read_data),
      .o_fu_complete  (alu_shim_out),
      .o_fu_busy      (alu_fu_busy)
  );

  // ===========================================================================
  // ALU CDB Adapter: result holding register between ALU and CDB arbiter
  // ===========================================================================
  fu_cdb_adapter u_alu_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (alu_shim_out),
      .o_fu_complete   (alu_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[0]),
      .o_result_pending(alu_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // MUL/DIV Shim: translate rs_issue_t → multiplier/divider → fu_complete_t
  // ===========================================================================
  int_muldiv_shim u_muldiv_shim (
      .i_clk            (i_clk),
      .i_rst_n          (i_rst_n),
      .i_rs_issue       (mul_rs_issue_w),
      .o_mul_fu_complete(mul_shim_out),
      .o_div_fu_complete(div_shim_out),
      .o_fu_busy        (muldiv_busy),
      .i_flush          (i_flush_all),
      .i_flush_en       (i_flush_en),
      .i_flush_tag      (i_flush_tag),
      .i_rob_head_tag   (head_tag),
      .i_div_accepted   (div_result_accepted)
  );

  // ===========================================================================
  // MUL CDB Adapter: result holding register → CDB arbiter slot 1
  // ===========================================================================
  fu_cdb_adapter u_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mul_shim_out),
      .o_fu_complete   (mul_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[1]),
      .o_result_pending(mul_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // DIV CDB Adapter: result holding register → CDB arbiter slot 2
  // ===========================================================================
  fu_cdb_adapter u_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (div_shim_out),
      .o_fu_complete   (div_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[2]),
      .o_result_pending(div_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

`ifdef ICARUS
  // Under Icarus, MEM_RS is stubbed and LQ is not instantiated.
  // Slot 3 reverts to external i_fu_complete_3 (handled by CDB arbiter wiring).
  assign mem_adapter_to_arbiter = i_fu_complete_3;
  assign mem_adapter_result_pending = 1'b0;
  assign lq_fu_complete = '0;
  assign o_lq_full = 1'b0;
  assign o_lq_empty = 1'b1;
  assign o_lq_count = '0;
  assign o_sq_check_valid = 1'b0;
  assign o_sq_check_addr = '0;
  assign o_sq_check_rob_tag = '0;
  assign o_sq_check_size = riscv_pkg::MEM_SIZE_WORD;  // verilog_lint: waive parameter-name-style
  assign o_lq_mem_read_en = 1'b0;
  assign o_lq_mem_read_addr = '0;
  assign o_lq_mem_read_size = riscv_pkg::MEM_SIZE_WORD;  // verilog_lint: waive parameter-name-style

  // Under Icarus, FP_RS/FMUL_RS/FDIV_RS are stubbed (no FP shims).
  // Slots 4-6 revert to external i_fu_complete_4/5/6.
  assign fp_add_adapter_to_arbiter = i_fu_complete_4;
  assign fp_add_adapter_result_pending = 1'b0;
  assign fp_add_shim_out = '0;
  assign fp_add_busy = 1'b0;
  assign fp_mul_adapter_to_arbiter = i_fu_complete_5;
  assign fp_mul_adapter_result_pending = 1'b0;
  assign fp_mul_shim_out = '0;
  assign fp_mul_busy = 1'b0;
  assign fp_div_adapter_to_arbiter = i_fu_complete_6;
  assign fp_div_adapter_result_pending = 1'b0;
  assign fp_div_shim_out = '0;
  assign fp_div_busy = 1'b0;
  assign fp_rs_issue_w = '0;
  assign fmul_rs_issue_w = '0;
  assign fdiv_rs_issue_w = '0;
`else
  // ===========================================================================
  // Load Queue: Allocation from Dispatch
  // ===========================================================================
  // Determine if the dispatched MEM_RS instruction is a load
  logic lq_alloc_is_load;
  always_comb begin
    case (i_rs_dispatch.op)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LR_W:
      lq_alloc_is_load = 1'b1;
      default: lq_alloc_is_load = 1'b0;
    endcase
  end

  riscv_pkg::lq_alloc_req_t lq_alloc_req;
  always_comb begin
    lq_alloc_req.valid    = mem_rs_dispatch_valid && lq_alloc_is_load;
    lq_alloc_req.rob_tag  = i_rs_dispatch.rob_tag;
    lq_alloc_req.is_fp    = i_rs_dispatch.is_fp_mem;
    lq_alloc_req.size     = i_rs_dispatch.mem_size;
    lq_alloc_req.sign_ext = i_rs_dispatch.mem_signed;
  end

  // ===========================================================================
  // Load Queue: Address Update from MEM_RS Issue
  // ===========================================================================
  logic lq_issue_is_load;
  always_comb begin
    case (o_mem_rs_issue.op)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LR_W:
      lq_issue_is_load = 1'b1;
      default: lq_issue_is_load = 1'b0;
    endcase
  end

  logic [riscv_pkg::XLEN-1:0] lq_effective_addr;
  assign lq_effective_addr = o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm;

  // MMIO detection: address >= MMIO base
  localparam logic [riscv_pkg::XLEN-1:0] MmioBase = 32'h4000_0000;
  logic lq_addr_is_mmio;
  assign lq_addr_is_mmio = (lq_effective_addr >= MmioBase);

  riscv_pkg::lq_addr_update_t lq_addr_update;
  always_comb begin
    lq_addr_update.valid   = o_mem_rs_issue.valid && lq_issue_is_load;
    lq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    lq_addr_update.address = lq_effective_addr;
    lq_addr_update.is_mmio = lq_addr_is_mmio;
  end

  // ===========================================================================
  // Load Queue Instance
  // ===========================================================================
  load_queue u_lq (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation (from dispatch)
      .i_alloc(lq_alloc_req),
      .o_full (o_lq_full),

      // Address update (from MEM_RS issue)
      .i_addr_update(lq_addr_update),

      // SQ disambiguation (external until SQ added)
      .o_sq_check_valid          (o_sq_check_valid),
      .o_sq_check_addr           (o_sq_check_addr),
      .o_sq_check_rob_tag        (o_sq_check_rob_tag),
      .o_sq_check_size           (o_sq_check_size),
      .i_sq_all_older_addrs_known(i_sq_all_older_addrs_known),
      .i_sq_forward              (i_sq_forward),

      // Memory interface (external)
      .o_mem_read_en   (o_lq_mem_read_en),
      .o_mem_read_addr (o_lq_mem_read_addr),
      .o_mem_read_size (o_lq_mem_read_size),
      .i_mem_read_data (i_lq_mem_read_data),
      .i_mem_read_valid(i_lq_mem_read_valid),

      // CDB result (to MEM adapter)
      .o_fu_complete           (lq_fu_complete),
      .i_adapter_result_pending(mem_adapter_result_pending),

      // ROB head tag (for MMIO ordering)
      .i_rob_head_tag(head_tag),

      // L0 cache invalidation
      .i_cache_invalidate_valid(i_cache_invalidate_valid),
      .i_cache_invalidate_addr (i_cache_invalidate_addr),

      // Flush
      .i_flush_en (i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(i_flush_all),

      // Status
      .o_empty(o_lq_empty),
      .o_count(o_lq_count)
  );

  // ===========================================================================
  // MEM CDB Adapter: result holding register → CDB arbiter slot 3
  // ===========================================================================
  fu_cdb_adapter u_mem_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (lq_fu_complete),
      .o_fu_complete   (mem_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[3]),
      .o_result_pending(mem_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Add Shim: translate rs_issue_t → FPU subunits → fu_complete_t
  // ===========================================================================
  fp_add_shim u_fp_add_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fp_rs_issue_w),
      .o_fu_complete (fp_add_shim_out),
      .o_fu_busy     (fp_add_busy),
      .i_flush       (i_flush_all),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP Add CDB Adapter: result holding register → CDB arbiter slot 4
  // ===========================================================================
  fu_cdb_adapter u_fp_add_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_add_shim_out),
      .o_fu_complete   (fp_add_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[4]),
      .o_result_pending(fp_add_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Multiply Shim: translate rs_issue_t → FPU mult/FMA → fu_complete_t
  // ===========================================================================
  fp_mul_shim u_fp_mul_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fmul_rs_issue_w),
      .o_fu_complete (fp_mul_shim_out),
      .o_fu_busy     (fp_mul_busy),
      .i_flush       (i_flush_all),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP Multiply CDB Adapter: result holding register → CDB arbiter slot 5
  // ===========================================================================
  fu_cdb_adapter u_fp_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_mul_shim_out),
      .o_fu_complete   (fp_mul_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[5]),
      .o_result_pending(fp_mul_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Divide/Sqrt Shim: translate rs_issue_t → FPU div/sqrt → fu_complete_t
  // ===========================================================================
  fp_div_shim u_fp_div_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fdiv_rs_issue_w),
      .o_fu_complete (fp_div_shim_out),
      .o_fu_busy     (fp_div_busy),
      .i_flush       (i_flush_all),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP Divide CDB Adapter: result holding register → CDB arbiter slot 6
  // ===========================================================================
  fu_cdb_adapter u_fp_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_div_shim_out),
      .o_fu_complete   (fp_div_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[6]),
      .o_result_pending(fp_div_adapter_result_pending),
      .i_flush         (i_flush_all),
      .i_flush_en      (i_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );
`endif

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (from rob_rat_wrapper)
  // -------------------------------------------------------------------------

  // CDB write and branch update cannot target same tag simultaneously
  always_comb begin
    assume (!(cdb_write_from_arbiter.valid && i_branch_update.valid &&
              cdb_write_from_arbiter.tag == i_branch_update.tag));
  end

  // No allocation during flush
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // No rename during full flush
  always_comb assume (!(i_rat_alloc_valid && i_flush_all));

  // No rename during checkpoint restore
  always_comb assume (!(i_rat_alloc_valid && i_checkpoint_restore));

  // Checkpoint save and restore are mutually exclusive
  always_comb assume (!(i_checkpoint_save && i_checkpoint_restore));

  // Shadow-track checkpoint validity
  reg [riscv_pkg::NumCheckpoints-1:0] f_cp_valid;

  initial f_cp_valid = '0;

  always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      f_cp_valid <= '0;
    end else if (i_flush_all) begin
      f_cp_valid <= '0;
    end else begin
      if (i_checkpoint_save) f_cp_valid[i_checkpoint_id] <= 1'b1;
      if (i_checkpoint_free) f_cp_valid[i_checkpoint_free_id] <= 1'b0;
    end
  end

  always_comb begin
    if (i_checkpoint_restore) assume (f_cp_valid[i_checkpoint_restore_id]);
  end

  // Dispatch never renames x0 to INT
  always_comb begin
    if (i_rat_alloc_valid && !i_rat_alloc_dest_rf) assume (i_rat_alloc_dest_reg != '0);
  end

  // Dispatch tag coordination
  always_comb begin
    if (i_alloc_req.alloc_valid && i_rat_alloc_valid) begin
      assume (i_rat_alloc_rob_tag == o_alloc_resp.alloc_tag);
    end
  end

  // Checkpoint ID coordination
  always_comb begin
    if (i_rob_checkpoint_valid && i_checkpoint_save) begin
      assume (i_rob_checkpoint_id == i_checkpoint_id);
    end
  end

  // No RS dispatch during flush
  always_comb begin
    assume (!(i_rs_dispatch.valid && (i_flush_en || i_flush_all)));
  end

  // No RS dispatch when targeted RS is full
  always_comb begin
    if (o_rs_full) assume (!i_rs_dispatch.valid);
  end

  // No MEM_RS load dispatch when LQ is full
  always_comb begin
    if (o_lq_full && lq_alloc_is_load) assume (!mem_rs_dispatch_valid);
  end

  // LQ memory response only after read was issued
  always_comb begin
    assume (!(i_lq_mem_read_valid && (i_flush_en || i_flush_all)));
  end

  // Dispatch routing mutual exclusion: at most one RS receives valid
  always_comb begin
    if (i_rs_dispatch.valid) begin
      p_dispatch_routes_to_exactly_one :
      assert ($onehot0(
          {
            fdiv_rs_dispatch_valid,
            fmul_rs_dispatch_valid,
            fp_rs_dispatch_valid,
            mem_rs_dispatch_valid,
            mul_rs_dispatch_valid,
            int_rs_dispatch_valid
          }
      ));
    end
  end

  // -------------------------------------------------------------------------
  // Observation: track an arbitrary INT register via lookups
  // -------------------------------------------------------------------------
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_int_track;
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_fp_track;

  always_comb begin
    assume (f_int_track != '0);
    assume (i_int_src1_addr == f_int_track);
    assume (i_fp_src1_addr == f_fp_track);
  end

  // -------------------------------------------------------------------------
  // Commit bus assertions (from rob_rat_wrapper)
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_commit_output_identity : assert (o_commit == commit_bus);
      p_commit_requires_head_ready : assert (!commit_bus.valid || (o_head_valid && o_head_done));
      p_commit_tag_is_head : assert (!commit_bus.valid || (commit_bus.tag == o_head_tag));
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: commit propagation and flush
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // INT commit clears RAT entry when tag matches
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) == $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_commit_clears_int_via_bus : assert (!o_int_src1.renamed);
      end

      // INT WAW: commit does NOT clear when tag mismatches (newer rename)
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) != $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_waw_preserves_newer_int : assert (o_int_src1.renamed);
      end

      // FP commit clears RAT entry when tag matches
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && $past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_fp_track && $past(
              o_fp_src1.renamed
          ) && $past(
              o_fp_src1.tag
          ) == $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && $past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_fp_track)) begin
        p_commit_clears_fp_via_bus : assert (!o_fp_src1.renamed);
      end

    end
  end

  // -------------------------------------------------------------------------
  // Sequential: rename-vs-commit same-cycle precedence
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      if ($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track && $past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          )) begin
        p_rename_wins_over_commit :
        assert (o_int_src1.renamed && o_int_src1.tag == $past(i_rat_alloc_rob_tag));
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: flush / recovery composition
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // flush_all empties ROB
      if ($past(i_flush_all)) begin
        p_flush_all_empties_rob : assert (o_rob_empty);
      end

      // flush_all empties all RS
      if ($past(i_flush_all)) begin
        p_flush_all_empties_int_rs : assert (o_rs_empty);
        p_flush_all_empties_mul_rs : assert (o_mul_rs_empty);
        p_flush_all_empties_mem_rs : assert (o_mem_rs_empty);
        p_flush_all_empties_fp_rs : assert (o_fp_rs_empty);
        p_flush_all_empties_fmul_rs : assert (o_fmul_rs_empty);
        p_flush_all_empties_fdiv_rs : assert (o_fdiv_rs_empty);
      end

      // flush_all frees all checkpoints
      if ($past(i_flush_all)) begin
        p_flush_all_frees_checkpoints : assert (o_checkpoint_available);
      end

      // flush_all clears INT rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_int_rename : assert (!o_int_src1.renamed);
      end

      // flush_all clears FP rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_fp_rename : assert (!o_fp_src1.renamed);
      end

      // flush_all empties LQ
      if ($past(i_flush_all)) begin
        p_flush_all_empties_lq : assert (o_lq_empty);
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_rob_empty : assert (o_rob_empty);
      p_reset_int_rs_empty : assert (o_rs_empty);
      p_reset_mul_rs_empty : assert (o_mul_rs_empty);
      p_reset_mem_rs_empty : assert (o_mem_rs_empty);
      p_reset_fp_rs_empty : assert (o_fp_rs_empty);
      p_reset_fmul_rs_empty : assert (o_fmul_rs_empty);
      p_reset_fdiv_rs_empty : assert (o_fdiv_rs_empty);
      p_reset_checkpoints_available : assert (o_checkpoint_available);
      p_reset_int_not_renamed : assert (!o_int_src1.renamed);
      p_reset_fp_not_renamed : assert (!o_fp_src1.renamed);
      p_reset_lq_empty : assert (o_lq_empty);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // RS issue fires
      cover_rs_issue : cover (o_rs_issue.valid);

      // CDB simultaneously present with RS dispatch
      cover_cdb_and_rs_dispatch : cover (cdb_bus.valid && i_rs_dispatch.valid);

      // flush_all while RS non-empty
      cover_flush_while_rs_nonempty : cover (i_flush_all && !o_rs_empty);

      // Commit fires
      cover_commit : cover (commit_bus.valid);

      // RS full: removed -- needs 9+ steps (8 dispatches + reset) but wrapper
      // cover depth is 8.  Covered by reservation_station.sby at depth 20.

      // Commit clears tracked INT register
      cover_commit_clears_int :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag == commit_bus.tag
      );

      // Rename and commit target same INT register in same cycle
      cover_rename_commit_same_cycle :
      cover (
        i_rat_alloc_valid && !i_rat_alloc_dest_rf &&
        i_rat_alloc_dest_reg == f_int_track &&
        commit_bus.valid && commit_bus.dest_valid &&
        !commit_bus.dest_rf && commit_bus.dest_reg == f_int_track
      );

      // WAW: commit for tracked register with tag mismatch
      cover_waw_tag_mismatch :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag != commit_bus.tag
      );

      // flush_all while tracked INT register is renamed
      cover_flush_while_renamed : cover (i_flush_all && o_int_src1.renamed);

      // Checkpoint save + ROB checkpoint recording in same cycle
      cover_checkpoint_save : cover (i_checkpoint_save && i_rob_checkpoint_valid);

      // Checkpoint restore (misprediction recovery)
      cover_checkpoint_restore : cover (i_checkpoint_restore);

      // FP commit via internal bus
      cover_fp_commit_via_bus :
      cover (commit_bus.valid && commit_bus.dest_valid && commit_bus.dest_rf);

      // Dispatch routing: dispatch to each RS type
      cover_dispatch_to_mul_rs : cover (mul_rs_dispatch_valid);
      cover_dispatch_to_mem_rs : cover (mem_rs_dispatch_valid);
      cover_dispatch_to_fp_rs : cover (fp_rs_dispatch_valid);
      cover_dispatch_to_fmul_rs : cover (fmul_rs_dispatch_valid);
      cover_dispatch_to_fdiv_rs : cover (fdiv_rs_dispatch_valid);

      // LQ allocation
      cover_lq_alloc : cover (lq_alloc_req.valid);

      // LQ memory read issued
      cover_lq_mem_issue : cover (o_lq_mem_read_en);
    end
  end

`endif  // FORMAL

endmodule
