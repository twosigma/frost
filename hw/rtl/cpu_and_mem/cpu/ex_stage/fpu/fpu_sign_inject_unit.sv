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

// FPU Sign Inject Unit Wrapper
// Wraps S and D fp_sign_inject instances with tracking FSM, NaN-boxing, and dest reg capture.
// Note: fp_sign_inject has o_busy instead of o_flags (no FP exceptions generated).
module fpu_sign_inject_unit #(
    parameter int unsigned FP_WIDTH_D = 64
) (
    input  logic                                  i_clk,
    input  logic                                  i_rst,
    input  logic                                  i_valid,
    input  logic                                  i_use_unit,
    input  logic                                  i_op_is_double,
    input  logic                 [          31:0] i_operand_a_s,
    input  logic                 [          31:0] i_operand_b_s,
    input  logic                 [FP_WIDTH_D-1:0] i_operand_a_d,
    input  logic                 [FP_WIDTH_D-1:0] i_operand_b_d,
    input  riscv_pkg::instr_op_e                  i_operation,
    input  logic                 [           4:0] i_dest_reg,
    output logic                 [FP_WIDTH_D-1:0] o_result,
    output logic                                  o_valid,
    output riscv_pkg::fp_flags_t                  o_flags,
    output logic                                  o_busy,
    output logic                 [           4:0] o_dest_reg,
    output logic                                  o_start
);

  localparam int unsigned FpPad = (FP_WIDTH_D > 32) ? (FP_WIDTH_D - 32) : 0;
  function automatic [FP_WIDTH_D-1:0] box32(input logic [31:0] value);
    box32 = {{FpPad{1'b1}}, value};
  endfunction

  // Tracking FSM
  logic started, can_start;
  logic start_s, start_d;
  assign can_start = ~started;
  assign start_s   = i_valid & i_use_unit & ~i_op_is_double & can_start;
  assign start_d   = i_valid & i_use_unit & i_op_is_double & can_start;
  assign o_start   = start_s | start_d;

  always_ff @(posedge i_clk) begin
    if (i_rst) started <= 1'b0;
    else if (o_valid) started <= 1'b0;
    else if (o_start) started <= 1'b1;
  end

  // Sub-unit busy signals
  logic busy_s, busy_d;
  assign o_busy  = busy_s | busy_d;

  // No FP exceptions from sign injection
  assign o_flags = '0;

  // S/D results
  logic [          31:0] result_s;
  logic                  valid_s;
  logic [FP_WIDTH_D-1:0] result_d;
  logic                  valid_d;

  assign o_valid  = valid_s | valid_d;
  assign o_result = valid_s ? box32(result_s) : valid_d ? result_d : '0;

  // Dest reg capture
  always_ff @(posedge i_clk) begin
    if (i_rst) o_dest_reg <= 5'b0;
    else if (i_valid && i_use_unit && can_start) o_dest_reg <= i_dest_reg;
  end

  fp_sign_inject #(
      .FP_WIDTH(32)
  ) sign_inject_s (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(start_s),
      .i_operand_a(i_operand_a_s),
      .i_operand_b(i_operand_b_s),
      .i_operation(i_operation),
      .o_result(result_s),
      .o_valid(valid_s),
      .o_busy(busy_s)
  );

  fp_sign_inject #(
      .FP_WIDTH(FP_WIDTH_D)
  ) sign_inject_d (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(start_d),
      .i_operand_a(i_operand_a_d),
      .i_operand_b(i_operand_b_d),
      .i_operation(i_operation),
      .o_result(result_d),
      .o_valid(valid_d),
      .o_busy(busy_d)
  );

endmodule : fpu_sign_inject_unit
