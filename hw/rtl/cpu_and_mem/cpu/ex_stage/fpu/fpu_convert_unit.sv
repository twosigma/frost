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

// FPU Convert Unit Wrapper
// Wraps fp_convert S + D + fp_convert_sd with a shared tracking FSM,
// NaN-boxing, and dest reg capture. Handles both FP and integer results.
module fpu_convert_unit #(
    parameter int unsigned XLEN       = 32,
    parameter int unsigned FP_WIDTH_D = 64
) (
    input  logic                                  i_clk,
    input  logic                                  i_rst,
    input  logic                                  i_valid,
    input  logic                                  i_use_convert_s,
    input  logic                                  i_use_convert_d,
    input  logic                                  i_use_convert_sd,
    input  logic                 [          31:0] i_operand_a_s,
    input  logic                 [FP_WIDTH_D-1:0] i_operand_a_d,
    input  logic                 [      XLEN-1:0] i_int_operand,
    input  riscv_pkg::instr_op_e                  i_operation,
    input  logic                 [           2:0] i_rounding_mode,
    input  logic                 [           4:0] i_dest_reg,
    output logic                 [FP_WIDTH_D-1:0] o_fp_result,
    output logic                 [      XLEN-1:0] o_int_result,
    output logic                                  o_is_fp_to_int,
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

  // Tracking FSM (shared across S, D, and SD convert paths)
  logic started, can_start;
  logic start_s, start_d, start_sd;
  assign can_start = ~started;
  assign start_s   = i_valid & i_use_convert_s & can_start;
  assign start_d   = i_valid & i_use_convert_d & can_start;
  assign start_sd  = i_valid & i_use_convert_sd & can_start;
  assign o_start   = start_s | start_d | start_sd;

  always_ff @(posedge i_clk) begin
    if (i_rst) started <= 1'b0;
    else if (o_valid) started <= 1'b0;
    else if (o_start) started <= 1'b1;
  end
  assign o_busy = started & ~o_valid;

  // S results
  logic                 [          31:0] fp_result_s;
  logic                 [      XLEN-1:0] int_result_s;
  logic                                  is_fp_to_int_s;
  logic                                  valid_s;
  riscv_pkg::fp_flags_t                  flags_s;

  // D results
  logic                 [FP_WIDTH_D-1:0] fp_result_d;
  logic                 [      XLEN-1:0] int_result_d;
  logic                                  is_fp_to_int_d;
  logic                                  valid_d;
  riscv_pkg::fp_flags_t                  flags_d;

  // SD results
  logic                 [FP_WIDTH_D-1:0] sd_result;
  logic                                  sd_valid;
  riscv_pkg::fp_flags_t                  sd_flags;

  assign o_valid = valid_s | valid_d | sd_valid;
  assign o_fp_result = valid_s ? box32(
      fp_result_s
  ) : valid_d ? fp_result_d : sd_valid ? sd_result : '0;
  assign o_int_result = valid_s ? int_result_s : valid_d ? int_result_d : '0;
  assign o_is_fp_to_int = valid_s ? is_fp_to_int_s : valid_d ? is_fp_to_int_d : 1'b0;
  assign o_flags = valid_s ? flags_s : valid_d ? flags_d : sd_valid ? sd_flags : '0;

  // Dest reg capture
  always_ff @(posedge i_clk) begin
    if (i_rst) o_dest_reg <= 5'b0;
    else if (i_valid && (i_use_convert_s || i_use_convert_d || i_use_convert_sd) && can_start)
      o_dest_reg <= i_dest_reg;
  end

  fp_convert #(
      .XLEN(XLEN),
      .FP_WIDTH(32)
  ) convert_s (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(start_s),
      .i_fp_operand(i_operand_a_s),
      .i_int_operand(i_int_operand),
      .i_operation(i_operation),
      .i_rounding_mode(i_rounding_mode),
      .o_fp_result(fp_result_s),
      .o_int_result(int_result_s),
      .o_is_fp_to_int(is_fp_to_int_s),
      .o_valid(valid_s),
      .o_flags(flags_s)
  );

  fp_convert #(
      .XLEN(XLEN),
      .FP_WIDTH(FP_WIDTH_D)
  ) convert_d (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(start_d),
      .i_fp_operand(i_operand_a_d),
      .i_int_operand(i_int_operand),
      .i_operation(i_operation),
      .i_rounding_mode(i_rounding_mode),
      .o_fp_result(fp_result_d),
      .o_int_result(int_result_d),
      .o_is_fp_to_int(is_fp_to_int_d),
      .o_valid(valid_d),
      .o_flags(flags_d)
  );

  fp_convert_sd #(
      .FP_WIDTH(FP_WIDTH_D)
  ) convert_sd (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(start_sd),
      .i_operand_s(i_operand_a_s),
      .i_operand_d(i_operand_a_d),
      .i_operation(i_operation),
      .i_rounding_mode(i_rounding_mode),
      .o_result(sd_result),
      .o_valid(sd_valid),
      .o_flags(sd_flags)
  );

endmodule : fpu_convert_unit
