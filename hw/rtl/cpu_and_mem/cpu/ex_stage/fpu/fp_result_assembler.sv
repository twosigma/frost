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
  Shared result assembler for IEEE 754 floating-point arithmetic modules.
  Handles mantissa rounding, overflow/underflow detection, and final result formatting.
  Used by fp_adder, fp_multiplier, fp_divider, fp_sqrt, and fp_fma.

  Purely combinational: performs rounding increment, overflow/underflow checks, and
  assembles the final FP result with appropriate exception flags.

  Priority: special -> zero -> overflow -> underflow -> normal
*/
module fp_result_assembler #(
    parameter int unsigned FP_WIDTH   = 32,
    parameter int unsigned ExpBits    = 8,
    parameter int unsigned FracBits   = 23,
    parameter int unsigned MantBits   = 24,   // FracBits + 1
    parameter int unsigned ExpExtBits = 10
) (
    // Rounding inputs
    input  logic signed          [ExpExtBits-1:0] i_exp_work,
    input  logic                 [  MantBits-1:0] i_mantissa_work,
    input  logic                                  i_round_up,
    input  logic                                  i_is_inexact,
    // Result metadata
    input  logic                                  i_result_sign,
    input  logic                 [           2:0] i_rm,
    // Special case bypass
    input  logic                                  i_is_special,
    input  logic                 [  FP_WIDTH-1:0] i_special_result,
    input  logic                                  i_special_invalid,
    input  logic                                  i_special_div_zero,
    // Zero result bypass
    input  logic                                  i_is_zero_result,
    input  logic                                  i_zero_sign,
    // Outputs
    output logic                 [  FP_WIDTH-1:0] o_result,
    output riscv_pkg::fp_flags_t                  o_flags
);

  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [ExpBits-1:0] MaxNormalExp = ExpMax - 1'b1;
  localparam logic [FracBits-1:0] MaxMant = {FracBits{1'b1}};
  localparam logic signed [ExpExtBits-1:0] ExpMaxSigned = {
    {(ExpExtBits - ExpBits - 1) {1'b0}}, 1'b0, ExpMax
  };

  // Mantissa rounding
  logic [MantBits:0] rounded_mantissa;
  logic              mantissa_overflow;
  assign rounded_mantissa  = {1'b0, i_mantissa_work} + {{MantBits{1'b0}}, i_round_up};
  assign mantissa_overflow = rounded_mantissa[MantBits];

  // Exponent adjustment for mantissa overflow
  logic signed [ExpExtBits-1:0] adjusted_exponent;
  logic        [  FracBits-1:0] final_mantissa;

  always_comb begin
    if (mantissa_overflow) begin
      if (i_exp_work == '0) begin
        adjusted_exponent = {{(ExpExtBits - 1) {1'b0}}, 1'b1};
      end else begin
        adjusted_exponent = i_exp_work + 1;
      end
      final_mantissa = rounded_mantissa[MantBits-1:1];
    end else begin
      adjusted_exponent = i_exp_work;
      final_mantissa = rounded_mantissa[FracBits-1:0];
    end
  end

  // Overflow/underflow detection
  logic is_overflow, is_underflow;
  assign is_overflow  = (adjusted_exponent >= ExpMaxSigned);
  assign is_underflow = (adjusted_exponent <= '0);

  // Result assembly and flag generation
  always_comb begin
    o_result = '0;
    o_flags  = '0;

    if (i_is_special) begin
      o_result   = i_special_result;
      o_flags.nv = i_special_invalid;
      o_flags.dz = i_special_div_zero;
    end else if (i_is_zero_result) begin
      o_result = {i_zero_sign, {(FP_WIDTH - 1) {1'b0}}};
    end else if (is_overflow) begin
      o_flags.of = 1'b1;
      o_flags.nx = 1'b1;
      if ((i_rm == riscv_pkg::FRM_RTZ) ||
          (i_rm == riscv_pkg::FRM_RDN && !i_result_sign) ||
          (i_rm == riscv_pkg::FRM_RUP && i_result_sign)) begin
        o_result = {i_result_sign, MaxNormalExp, MaxMant};
      end else begin
        o_result = {i_result_sign, ExpMax, {FracBits{1'b0}}};
      end
    end else if (is_underflow) begin
      o_flags.uf = i_is_inexact;
      o_flags.nx = i_is_inexact;
      o_result   = {i_result_sign, {ExpBits{1'b0}}, final_mantissa};
    end else begin
      o_flags.nx = i_is_inexact;
      o_result   = {i_result_sign, adjusted_exponent[ExpBits-1:0], final_mantissa};
    end
  end

endmodule : fp_result_assembler
