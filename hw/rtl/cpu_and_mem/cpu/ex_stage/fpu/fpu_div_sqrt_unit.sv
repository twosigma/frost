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

// FPU Divider/Sqrt Unit Wrapper
// Wraps S and D fp_divider + fp_sqrt instances with a shared tracking FSM,
// NaN-boxing, and dest reg capture.
module fpu_div_sqrt_unit #(
    parameter int unsigned FP_WIDTH_D = 64
) (
    input  logic                                  i_clk,
    input  logic                                  i_rst,
    input  logic                                  i_valid,
    input  logic                                  i_use_divider,
    input  logic                                  i_use_sqrt,
    input  logic                                  i_op_is_double,
    input  logic                 [          31:0] i_operand_a_s,
    input  logic                 [          31:0] i_operand_b_s,
    input  logic                 [FP_WIDTH_D-1:0] i_operand_a_d,
    input  logic                 [FP_WIDTH_D-1:0] i_operand_b_d,
    input  logic                 [           2:0] i_rounding_mode,
    input  logic                 [           4:0] i_dest_reg,
    output logic                 [FP_WIDTH_D-1:0] o_divider_result,
    output logic                                  o_divider_valid,
    output riscv_pkg::fp_flags_t                  o_divider_flags,
    output logic                 [FP_WIDTH_D-1:0] o_sqrt_result,
    output logic                                  o_sqrt_valid,
    output riscv_pkg::fp_flags_t                  o_sqrt_flags,
    output logic                                  o_busy,
    output logic                 [           4:0] o_dest_reg,
    output logic                                  o_dest_reg_valid,
    output logic                                  o_start
);

  localparam int unsigned FpPad = (FP_WIDTH_D > 32) ? (FP_WIDTH_D - 32) : 0;
  function automatic [FP_WIDTH_D-1:0] box32(input logic [31:0] value);
    box32 = {{FpPad{1'b1}}, value};
  endfunction

  // Shared tracking FSM for divider and sqrt
  logic started, can_start;
  logic divider_start_s, divider_start_d, divider_start;
  logic sqrt_start_s, sqrt_start_d, sqrt_start;
  assign can_start       = ~started;
  assign divider_start_s = i_valid & i_use_divider & ~i_op_is_double & can_start;
  assign divider_start_d = i_valid & i_use_divider & i_op_is_double & can_start;
  assign sqrt_start_s    = i_valid & i_use_sqrt & ~i_op_is_double & can_start;
  assign sqrt_start_d    = i_valid & i_use_sqrt & i_op_is_double & can_start;
  assign divider_start   = divider_start_s | divider_start_d;
  assign sqrt_start      = sqrt_start_s | sqrt_start_d;
  assign o_start         = divider_start | sqrt_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) started <= 1'b0;
    else if (o_divider_valid || o_sqrt_valid) started <= 1'b0;
    else if (o_start) started <= 1'b1;
  end

  // Busy: expose started state for inflight hazard detection.
  assign o_busy = started;

  // S/D divider results
  logic                 [          31:0] divider_result_s;
  logic                                  divider_valid_s;
  riscv_pkg::fp_flags_t                  divider_flags_s;
  logic                 [FP_WIDTH_D-1:0] divider_result_d;
  logic                                  divider_valid_d;
  riscv_pkg::fp_flags_t                  divider_flags_d;

  assign o_divider_valid = divider_valid_s | divider_valid_d;
  assign o_divider_result = divider_valid_s ? box32(
      divider_result_s
  ) : divider_valid_d ? divider_result_d : '0;
  assign o_divider_flags  = divider_valid_s ? divider_flags_s :
                            divider_valid_d ? divider_flags_d : '0;

  // S/D sqrt results
  logic                 [          31:0] sqrt_result_s;
  logic                                  sqrt_valid_s;
  riscv_pkg::fp_flags_t                  sqrt_flags_s;
  logic                 [FP_WIDTH_D-1:0] sqrt_result_d;
  logic                                  sqrt_valid_d;
  riscv_pkg::fp_flags_t                  sqrt_flags_d;

  assign o_sqrt_valid  = sqrt_valid_s | sqrt_valid_d;
  assign o_sqrt_result = sqrt_valid_s ? box32(sqrt_result_s) : sqrt_valid_d ? sqrt_result_d : '0;
  assign o_sqrt_flags  = sqrt_valid_s ? sqrt_flags_s : sqrt_valid_d ? sqrt_flags_d : '0;

  // Dest reg capture with valid tracking (sequential ops need valid flag for hazard)
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_dest_reg <= 5'b0;
      o_dest_reg_valid <= 1'b0;
    end else begin
      if (o_divider_valid || o_sqrt_valid) begin
        o_dest_reg_valid <= 1'b0;
      end else if (o_start) begin
        o_dest_reg <= i_dest_reg;
        o_dest_reg_valid <= 1'b1;
      end
    end
  end

  fp_divider #(
      .FP_WIDTH(32)
  ) divider_s (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(divider_start_s),
      .i_operand_a(i_operand_a_s),
      .i_operand_b(i_operand_b_s),
      .i_rounding_mode(i_rounding_mode),
      .o_result(divider_result_s),
      .o_valid(divider_valid_s),
      .o_stall(  /*unused*/),
      .o_flags(divider_flags_s)
  );

  fp_divider #(
      .FP_WIDTH(FP_WIDTH_D)
  ) divider_d (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(divider_start_d),
      .i_operand_a(i_operand_a_d),
      .i_operand_b(i_operand_b_d),
      .i_rounding_mode(i_rounding_mode),
      .o_result(divider_result_d),
      .o_valid(divider_valid_d),
      .o_stall(  /*unused*/),
      .o_flags(divider_flags_d)
  );

  fp_sqrt #(
      .FP_WIDTH(32)
  ) sqrt_s (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(sqrt_start_s),
      .i_operand(i_operand_a_s),
      .i_rounding_mode(i_rounding_mode),
      .o_result(sqrt_result_s),
      .o_valid(sqrt_valid_s),
      .o_stall(  /*unused*/),
      .o_flags(sqrt_flags_s)
  );

  fp_sqrt #(
      .FP_WIDTH(FP_WIDTH_D)
  ) sqrt_d (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(sqrt_start_d),
      .i_operand(i_operand_a_d),
      .i_rounding_mode(i_rounding_mode),
      .o_result(sqrt_result_d),
      .o_valid(sqrt_valid_d),
      .o_stall(  /*unused*/),
      .o_flags(sqrt_flags_d)
  );

endmodule : fpu_div_sqrt_unit
