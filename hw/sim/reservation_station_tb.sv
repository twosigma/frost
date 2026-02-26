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
 * Reservation Station Testbench Wrapper -- Flattened Ports for Icarus VPI
 *
 * Icarus Verilog 12.0 crashes (vvp event.cc assertion) on very wide
 * packed struct VPI-facing ports. Internal signals of any width are fine;
 * only ports that cocotb drives/reads via VPI are affected. Ports up to
 * 187 bits (reorder_buffer_commit_t) work; 352+ bits crash. This wrapper
 * exposes the rs_dispatch_t (373-bit) and rs_issue_t (352-bit) fields as
 * individual scalar ports and connects them directly to the RS module's
 * individual ICARUS ports. No intermediate packed struct wires are created.
 *
 * The cdb_broadcast_t (84-bit) passes through unchanged.
 *
 * Used automatically when SIM=icarus via Makefile TOPLEVEL override.
 */

module reservation_station_tb #(
    parameter int unsigned DEPTH = 8
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Dispatch -- flattened from rs_dispatch_t (373 bits)
    // =========================================================================
    input  logic        i_dispatch_valid,
    input  logic [ 2:0] i_dispatch_rs_type,
    input  logic [ 4:0] i_dispatch_rob_tag,
    input  logic [31:0] i_dispatch_op,
    input  logic        i_dispatch_src1_ready,
    input  logic [ 4:0] i_dispatch_src1_tag,
    input  logic [63:0] i_dispatch_src1_value,
    input  logic        i_dispatch_src2_ready,
    input  logic [ 4:0] i_dispatch_src2_tag,
    input  logic [63:0] i_dispatch_src2_value,
    input  logic        i_dispatch_src3_ready,
    input  logic [ 4:0] i_dispatch_src3_tag,
    input  logic [63:0] i_dispatch_src3_value,
    input  logic [31:0] i_dispatch_imm,
    input  logic        i_dispatch_use_imm,
    input  logic [ 2:0] i_dispatch_rm,
    input  logic [31:0] i_dispatch_branch_target,
    input  logic        i_dispatch_predicted_taken,
    input  logic [31:0] i_dispatch_predicted_target,
    input  logic        i_dispatch_is_fp_mem,
    input  logic [ 1:0] i_dispatch_mem_size,
    input  logic        i_dispatch_mem_signed,
    input  logic [11:0] i_dispatch_csr_addr,
    input  logic [ 4:0] i_dispatch_csr_imm,
    input  logic [31:0] i_dispatch_pc,
    output logic        o_full,

    // =========================================================================
    // CDB Snoop / Wakeup (84 bits -- small enough for Icarus VPI)
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // =========================================================================
    // Issue -- flattened from rs_issue_t (352 bits)
    // =========================================================================
    output logic        o_issue_valid,
    output logic [ 4:0] o_issue_rob_tag,
    output logic [31:0] o_issue_op,
    output logic [63:0] o_issue_src1_value,
    output logic [63:0] o_issue_src2_value,
    output logic [63:0] o_issue_src3_value,
    output logic [31:0] o_issue_imm,
    output logic        o_issue_use_imm,
    output logic [ 2:0] o_issue_rm,
    output logic [31:0] o_issue_branch_target,
    output logic        o_issue_predicted_taken,
    output logic [31:0] o_issue_predicted_target,
    output logic        o_issue_is_fp_mem,
    output logic [ 1:0] o_issue_mem_size,
    output logic        o_issue_mem_signed,
    output logic [11:0] o_issue_csr_addr,
    output logic [ 4:0] o_issue_csr_imm,
    output logic [31:0] o_issue_pc,

    input logic i_fu_ready,

    // =========================================================================
    // Flush Control
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // Status / Debug
    // =========================================================================
    output logic                       o_empty,
    output logic [$clog2(DEPTH+1)-1:0] o_count
);

  // ---------------------------------------------------------------------------
  // Instantiate reservation station -- direct port-to-port pass-through.
  // No intermediate packed struct wires (avoids Icarus event.cc crash).
  // ---------------------------------------------------------------------------
  reservation_station #(
      .DEPTH(DEPTH)
  ) u_rs (
      .i_clk,
      .i_rst_n,
      // Dispatch (individual ports, compiled with -DICARUS)
      .i_dispatch_valid           (i_dispatch_valid),
      .i_dispatch_rs_type         (i_dispatch_rs_type),
      .i_dispatch_rob_tag         (i_dispatch_rob_tag),
      .i_dispatch_op              (i_dispatch_op),
      .i_dispatch_src1_ready      (i_dispatch_src1_ready),
      .i_dispatch_src1_tag        (i_dispatch_src1_tag),
      .i_dispatch_src1_value      (i_dispatch_src1_value),
      .i_dispatch_src2_ready      (i_dispatch_src2_ready),
      .i_dispatch_src2_tag        (i_dispatch_src2_tag),
      .i_dispatch_src2_value      (i_dispatch_src2_value),
      .i_dispatch_src3_ready      (i_dispatch_src3_ready),
      .i_dispatch_src3_tag        (i_dispatch_src3_tag),
      .i_dispatch_src3_value      (i_dispatch_src3_value),
      .i_dispatch_imm             (i_dispatch_imm),
      .i_dispatch_use_imm         (i_dispatch_use_imm),
      .i_dispatch_rm              (i_dispatch_rm),
      .i_dispatch_branch_target   (i_dispatch_branch_target),
      .i_dispatch_predicted_taken (i_dispatch_predicted_taken),
      .i_dispatch_predicted_target(i_dispatch_predicted_target),
      .i_dispatch_is_fp_mem       (i_dispatch_is_fp_mem),
      .i_dispatch_mem_size        (i_dispatch_mem_size),
      .i_dispatch_mem_signed      (i_dispatch_mem_signed),
      .i_dispatch_csr_addr        (i_dispatch_csr_addr),
      .i_dispatch_csr_imm         (i_dispatch_csr_imm),
      .i_dispatch_pc              (i_dispatch_pc),
      .o_full,
      // CDB
      .i_cdb,
      // Issue (individual ports, compiled with -DICARUS)
      .o_issue_valid              (o_issue_valid),
      .o_issue_rob_tag            (o_issue_rob_tag),
      .o_issue_op                 (o_issue_op),
      .o_issue_src1_value         (o_issue_src1_value),
      .o_issue_src2_value         (o_issue_src2_value),
      .o_issue_src3_value         (o_issue_src3_value),
      .o_issue_imm                (o_issue_imm),
      .o_issue_use_imm            (o_issue_use_imm),
      .o_issue_rm                 (o_issue_rm),
      .o_issue_branch_target      (o_issue_branch_target),
      .o_issue_predicted_taken    (o_issue_predicted_taken),
      .o_issue_predicted_target   (o_issue_predicted_target),
      .o_issue_is_fp_mem          (o_issue_is_fp_mem),
      .o_issue_mem_size           (o_issue_mem_size),
      .o_issue_mem_signed         (o_issue_mem_signed),
      .o_issue_csr_addr           (o_issue_csr_addr),
      .o_issue_csr_imm            (o_issue_csr_imm),
      .o_issue_pc                 (o_issue_pc),
      .i_fu_ready,
      // Flush
      .i_flush_en,
      .i_flush_tag,
      .i_rob_head_tag,
      .i_flush_all,
      // Status
      .o_empty,
      .o_count
  );

endmodule
