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
  IEEE 754 rounding and normalization module for single-precision FP.

  This module takes a normalized or denormalized mantissa with guard, round,
  and sticky bits and produces a properly rounded IEEE 754 single-precision
  result with exception flags.

  Input format:
    - sign: result sign
    - exponent: biased exponent (may need adjustment)
    - mantissa: 25-bit mantissa including implicit 1 (1.mmm...mmm)
    - guard, round, sticky: rounding bits

  Rounding modes (per IEEE 754):
    - RNE (000): Round to Nearest, ties to Even
    - RTZ (001): Round towards Zero (truncate)
    - RDN (010): Round Down (towards -infinity)
    - RUP (011): Round Up (towards +infinity)
    - RMM (100): Round to Nearest, ties to Max Magnitude

  The module handles:
    - Normal rounding
    - Mantissa overflow from rounding (increment exponent)
    - Overflow detection (exponent >= 255)
    - Underflow detection (result is subnormal)
    - Generation of infinity on overflow
    - Proper handling of subnormal results
*/
module fp_round (
    input  logic                        i_sign,
    input  logic signed          [ 9:0] i_exponent,       // Signed to allow subnormal/underflow
    input  logic                 [24:0] i_mantissa,       // 1.24 bits (bit 24 = implicit 1)
    input  logic                        i_guard,          // Guard bit (first bit after mantissa)
    input  logic                        i_round,          // Round bit (second bit after mantissa)
    input  logic                        i_sticky,         // Sticky bit (OR of all remaining bits)
    input  logic                 [ 2:0] i_rounding_mode,
    input  logic                        i_is_zero,        // Input is zero
    output logic                 [31:0] o_result,
    output riscv_pkg::fp_flags_t        o_flags
);

  // Mantissa includes one extra fraction bit; drop it for the retained mantissa
  logic [23:0] mantissa_retained;
  logic        guard_bit;
  logic        round_bit;
  logic        sticky_bit;
  assign mantissa_retained = i_mantissa[24:1];  // 1 + 23 fraction bits
  assign guard_bit = i_mantissa[0];
  assign round_bit = i_guard;
  assign sticky_bit = i_round | i_sticky;

  // Subnormal handling: shift mantissa right when exponent <= 0
  logic        [23:0] mantissa_work;
  logic               guard_work;
  logic               round_work;
  logic               sticky_work;
  logic signed [ 9:0] exp_work;

  fp_subnorm_shift #(
      .MANT_BITS   (24),
      .EXP_EXT_BITS(10)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained),
      .i_guard   (guard_bit),
      .i_round   (round_bit),
      .i_sticky  (sticky_bit),
      .i_exponent(i_exponent),
      .o_mantissa(mantissa_work),
      .o_guard   (guard_work),
      .o_round   (round_work),
      .o_sticky  (sticky_work),
      .o_exponent(exp_work)
  );

  // Determine if we should round up
  logic round_up;
  logic lsb;  // Least significant bit of retained mantissa

  assign lsb = mantissa_work[0];

  assign round_up = riscv_pkg::fp_compute_round_up(
      i_rounding_mode, guard_work, round_work, sticky_work, lsb, i_sign
  );

  // Apply rounding to mantissa
  logic [24:0] rounded_mantissa;
  logic        mantissa_overflow;

  assign rounded_mantissa  = {1'b0, mantissa_work} + {24'b0, round_up};
  assign mantissa_overflow = rounded_mantissa[24];

  // Adjust exponent and mantissa for overflow
  logic signed [9:0] adjusted_exponent;
  logic [22:0] final_mantissa;

  always_comb begin
    if (mantissa_overflow) begin
      // Mantissa overflowed: 1.111...1 + 1 = 10.000...0
      // Shift right and increment exponent
      if (exp_work == 10'sd0) begin
        adjusted_exponent = 10'sd1;
      end else begin
        adjusted_exponent = exp_work + 1;
      end
      final_mantissa = rounded_mantissa[23:1];  // Take bits [23:1] after shift
    end else begin
      adjusted_exponent = exp_work;
      final_mantissa = rounded_mantissa[22:0];
    end
  end

  // Check for overflow (exponent >= 255)
  logic is_overflow;
  assign is_overflow = (adjusted_exponent >= 10'sd255);

  // Check for underflow (exponent <= 0, result is subnormal)
  logic is_underflow;
  assign is_underflow = (adjusted_exponent <= 10'sd0);

  // Inexact if any rounding bits were set
  logic is_inexact;
  assign is_inexact = guard_work | round_work | sticky_work;

  // Generate final result
  always_comb begin
    o_flags = '0;

    if (i_is_zero) begin
      // Zero result
      o_result = {i_sign, 31'b0};
    end else if (is_overflow) begin
      // Overflow: return infinity (or max normal depending on rounding mode)
      o_flags.of = 1'b1;
      o_flags.nx = 1'b1;

      // For RTZ and rounding away from infinity, return max normal
      // Otherwise return infinity
      if ((i_rounding_mode == riscv_pkg::FRM_RTZ) ||
          (i_rounding_mode == riscv_pkg::FRM_RDN && !i_sign) ||
          (i_rounding_mode == riscv_pkg::FRM_RUP && i_sign)) begin
        // Max normal number
        o_result = {i_sign, 8'hFE, 23'h7FFFFF};
      end else begin
        // Infinity
        o_result = {i_sign, 8'hFF, 23'b0};
      end
    end else if (is_underflow) begin
      // Underflow: subnormal or zero
      o_flags.uf = is_inexact;
      o_flags.nx = is_inexact;
      o_result   = {i_sign, 8'b0, final_mantissa};
    end else begin
      // Normal result
      o_flags.nx = is_inexact;
      o_result   = {i_sign, adjusted_exponent[7:0], final_mantissa};
    end
  end

endmodule : fp_round
