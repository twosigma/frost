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
 * Tomasulo Wrapper Testbench -- Flattened RS Ports for Icarus VPI
 *
 * Icarus Verilog 12.0 crashes (vvp event.cc assertion) on very wide
 * packed struct VPI-facing ports. Internal signals of any width are fine;
 * only ports that cocotb drives/reads via VPI are affected. Ports up to
 * 187 bits (reorder_buffer_commit_t) work; 352+ bits crash. This wrapper
 * flattens the rs_dispatch_t (373-bit) and rs_issue_t (352-bit) ports
 * into individual scalar signals and connects them directly to the
 * tomasulo_wrapper's individual ICARUS ports. No intermediate packed
 * struct wires are created.
 *
 * All other ROB/RAT ports (<=187 bits) pass through unchanged.
 *
 * Used automatically when SIM=icarus via Makefile TOPLEVEL override.
 */

module tomasulo_wrapper_tb (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // ROB Allocation Interface -- pass through (<130 bits)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // =========================================================================
    // ROB CDB Write Interface -- pass through (84 bits)
    // =========================================================================
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write,

    // =========================================================================
    // CDB Broadcast for RS Wakeup -- pass through (84 bits)
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // =========================================================================
    // ROB Branch Update Interface -- pass through (73 bits)
    // =========================================================================
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // ROB Checkpoint Recording -- pass through (scalar)
    // =========================================================================
    input logic                                    i_rob_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_rob_checkpoint_id,

    // =========================================================================
    // Commit Observation -- pass through (output, ~167 bits)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,

    // =========================================================================
    // ROB External Coordination -- pass through (all small)
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
    // Flush -- pass through (small)
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // ROB Status -- pass through (small)
    // =========================================================================
    output logic                                        o_fence_i_flush,
    output logic                                        o_rob_full,
    output logic                                        o_rob_empty,
    output logic [  riscv_pkg::ReorderBufferTagWidth:0] o_rob_count,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // ROB Bypass Read -- pass through (small)
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,

    // =========================================================================
    // RAT Source Lookups -- pass through (~70-bit outputs)
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
    // RAT Rename -- pass through (small)
    // =========================================================================
    input logic                                        i_rat_alloc_valid,
    input logic                                        i_rat_alloc_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag,

    // =========================================================================
    // RAT Checkpoint Save -- pass through (small)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Restore -- pass through (small)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Free -- pass through (small)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,

    // =========================================================================
    // RAT Checkpoint Availability -- pass through (small)
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id,

    // =========================================================================
    // RS Dispatch -- flattened from rs_dispatch_t (373 bits)
    // =========================================================================
    input  logic        i_rs_dispatch_valid,
    input  logic [ 2:0] i_rs_dispatch_rs_type,
    input  logic [ 4:0] i_rs_dispatch_rob_tag,
    input  logic [31:0] i_rs_dispatch_op,
    input  logic        i_rs_dispatch_src1_ready,
    input  logic [ 4:0] i_rs_dispatch_src1_tag,
    input  logic [63:0] i_rs_dispatch_src1_value,
    input  logic        i_rs_dispatch_src2_ready,
    input  logic [ 4:0] i_rs_dispatch_src2_tag,
    input  logic [63:0] i_rs_dispatch_src2_value,
    input  logic        i_rs_dispatch_src3_ready,
    input  logic [ 4:0] i_rs_dispatch_src3_tag,
    input  logic [63:0] i_rs_dispatch_src3_value,
    input  logic [31:0] i_rs_dispatch_imm,
    input  logic        i_rs_dispatch_use_imm,
    input  logic [ 2:0] i_rs_dispatch_rm,
    input  logic [31:0] i_rs_dispatch_branch_target,
    input  logic        i_rs_dispatch_predicted_taken,
    input  logic [31:0] i_rs_dispatch_predicted_target,
    input  logic        i_rs_dispatch_is_fp_mem,
    input  logic [ 1:0] i_rs_dispatch_mem_size,
    input  logic        i_rs_dispatch_mem_signed,
    input  logic [11:0] i_rs_dispatch_csr_addr,
    input  logic [ 4:0] i_rs_dispatch_csr_imm,
    output logic        o_rs_full,

    // =========================================================================
    // RS Issue -- flattened from rs_issue_t (352 bits)
    // =========================================================================
    output logic        o_rs_issue_valid,
    output logic [ 4:0] o_rs_issue_rob_tag,
    output logic [31:0] o_rs_issue_op,
    output logic [63:0] o_rs_issue_src1_value,
    output logic [63:0] o_rs_issue_src2_value,
    output logic [63:0] o_rs_issue_src3_value,
    output logic [31:0] o_rs_issue_imm,
    output logic        o_rs_issue_use_imm,
    output logic [ 2:0] o_rs_issue_rm,
    output logic [31:0] o_rs_issue_branch_target,
    output logic        o_rs_issue_predicted_taken,
    output logic [31:0] o_rs_issue_predicted_target,
    output logic        o_rs_issue_is_fp_mem,
    output logic [ 1:0] o_rs_issue_mem_size,
    output logic        o_rs_issue_mem_signed,
    output logic [11:0] o_rs_issue_csr_addr,
    output logic [ 4:0] o_rs_issue_csr_imm,

    input logic i_rs_fu_ready,

    // =========================================================================
    // RS Status -- pass through (small)
    // =========================================================================
    output logic       o_rs_empty,
    output logic [3:0] o_rs_count
);

  // ---------------------------------------------------------------------------
  // Instantiate tomasulo_wrapper -- direct port-to-port pass-through.
  // No intermediate packed struct wires (avoids Icarus event.cc crash).
  // ---------------------------------------------------------------------------
  tomasulo_wrapper u_dut (
      .i_clk,
      .i_rst_n,
      // ROB
      .i_alloc_req,
      .o_alloc_resp,
      .i_cdb_write,
      .i_cdb,
      .i_branch_update,
      .i_rob_checkpoint_valid,
      .i_rob_checkpoint_id,
      .o_commit,
      .i_sq_empty,
      .o_csr_start,
      .i_csr_done,
      .o_trap_pending,
      .o_trap_pc,
      .o_trap_cause,
      .i_trap_taken,
      .o_mret_start,
      .i_mret_done,
      .i_mepc,
      .i_interrupt_pending,
      .i_flush_en,
      .i_flush_tag,
      .i_flush_all,
      .o_fence_i_flush,
      .o_rob_full,
      .o_rob_empty,
      .o_rob_count,
      .o_head_tag,
      .o_head_valid,
      .o_head_done,
      .i_read_tag,
      .o_read_done,
      .o_read_value,
      // RAT
      .i_int_src1_addr,
      .i_int_src2_addr,
      .o_int_src1,
      .o_int_src2,
      .i_fp_src1_addr,
      .i_fp_src2_addr,
      .i_fp_src3_addr,
      .o_fp_src1,
      .o_fp_src2,
      .o_fp_src3,
      .i_int_regfile_data1,
      .i_int_regfile_data2,
      .i_fp_regfile_data1,
      .i_fp_regfile_data2,
      .i_fp_regfile_data3,
      .i_rat_alloc_valid,
      .i_rat_alloc_dest_rf,
      .i_rat_alloc_dest_reg,
      .i_rat_alloc_rob_tag,
      .i_checkpoint_save,
      .i_checkpoint_id,
      .i_checkpoint_branch_tag,
      .i_ras_tos,
      .i_ras_valid_count,
      .i_checkpoint_restore,
      .i_checkpoint_restore_id,
      .o_ras_tos,
      .o_ras_valid_count,
      .i_checkpoint_free,
      .i_checkpoint_free_id,
      .o_checkpoint_available,
      .o_checkpoint_alloc_id,
      // RS -- individual port connections (compiled with -DICARUS)
      .i_rs_dispatch_valid           (i_rs_dispatch_valid),
      .i_rs_dispatch_rs_type         (i_rs_dispatch_rs_type),
      .i_rs_dispatch_rob_tag         (i_rs_dispatch_rob_tag),
      .i_rs_dispatch_op              (i_rs_dispatch_op),
      .i_rs_dispatch_src1_ready      (i_rs_dispatch_src1_ready),
      .i_rs_dispatch_src1_tag        (i_rs_dispatch_src1_tag),
      .i_rs_dispatch_src1_value      (i_rs_dispatch_src1_value),
      .i_rs_dispatch_src2_ready      (i_rs_dispatch_src2_ready),
      .i_rs_dispatch_src2_tag        (i_rs_dispatch_src2_tag),
      .i_rs_dispatch_src2_value      (i_rs_dispatch_src2_value),
      .i_rs_dispatch_src3_ready      (i_rs_dispatch_src3_ready),
      .i_rs_dispatch_src3_tag        (i_rs_dispatch_src3_tag),
      .i_rs_dispatch_src3_value      (i_rs_dispatch_src3_value),
      .i_rs_dispatch_imm             (i_rs_dispatch_imm),
      .i_rs_dispatch_use_imm         (i_rs_dispatch_use_imm),
      .i_rs_dispatch_rm              (i_rs_dispatch_rm),
      .i_rs_dispatch_branch_target   (i_rs_dispatch_branch_target),
      .i_rs_dispatch_predicted_taken (i_rs_dispatch_predicted_taken),
      .i_rs_dispatch_predicted_target(i_rs_dispatch_predicted_target),
      .i_rs_dispatch_is_fp_mem       (i_rs_dispatch_is_fp_mem),
      .i_rs_dispatch_mem_size        (i_rs_dispatch_mem_size),
      .i_rs_dispatch_mem_signed      (i_rs_dispatch_mem_signed),
      .i_rs_dispatch_csr_addr        (i_rs_dispatch_csr_addr),
      .i_rs_dispatch_csr_imm         (i_rs_dispatch_csr_imm),
      .o_rs_full,
      .o_rs_issue_valid              (o_rs_issue_valid),
      .o_rs_issue_rob_tag            (o_rs_issue_rob_tag),
      .o_rs_issue_op                 (o_rs_issue_op),
      .o_rs_issue_src1_value         (o_rs_issue_src1_value),
      .o_rs_issue_src2_value         (o_rs_issue_src2_value),
      .o_rs_issue_src3_value         (o_rs_issue_src3_value),
      .o_rs_issue_imm                (o_rs_issue_imm),
      .o_rs_issue_use_imm            (o_rs_issue_use_imm),
      .o_rs_issue_rm                 (o_rs_issue_rm),
      .o_rs_issue_branch_target      (o_rs_issue_branch_target),
      .o_rs_issue_predicted_taken    (o_rs_issue_predicted_taken),
      .o_rs_issue_predicted_target   (o_rs_issue_predicted_target),
      .o_rs_issue_is_fp_mem          (o_rs_issue_is_fp_mem),
      .o_rs_issue_mem_size           (o_rs_issue_mem_size),
      .o_rs_issue_mem_signed         (o_rs_issue_mem_signed),
      .o_rs_issue_csr_addr           (o_rs_issue_csr_addr),
      .o_rs_issue_csr_imm            (o_rs_issue_csr_imm),
      .i_rs_fu_ready,
      .o_rs_empty,
      .o_rs_count
  );

endmodule
