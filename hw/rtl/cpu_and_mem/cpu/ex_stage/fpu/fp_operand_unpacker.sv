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
  IEEE 754 floating-point operand unpacker and classifier.

  Pure combinational module that extracts fields from a packed FP operand
  and classifies it (zero, subnormal, infinity, NaN, signaling NaN).

  This consolidates the repeated operand unpacking and classification
  pattern used across FP arithmetic modules (adder, multiplier, FMA,
  divider, sqrt, convert).

  Outputs:
    o_sign        - Sign bit
    o_exp         - Raw exponent field
    o_exp_adj     - Adjusted exponent (subnormals use exp=1 instead of 0)
    o_frac        - Raw fraction field (without implicit bit)
    o_mant        - Full mantissa with implicit leading bit (1.frac or 0.frac)
    o_is_zero     - Operand is +/-0
    o_is_subnormal- Operand is subnormal (denormalized)
    o_is_inf      - Operand is +/-infinity
    o_is_nan      - Operand is NaN (quiet or signaling)
    o_is_snan     - Operand is signaling NaN
*/
module fp_operand_unpacker #(
    parameter int unsigned FP_WIDTH  = 32,
    parameter int unsigned EXP_BITS  = (FP_WIDTH == 32) ? 8 : 11,
    parameter int unsigned FRAC_BITS = (FP_WIDTH == 32) ? 23 : 52,
    parameter int unsigned MANT_BITS = FRAC_BITS + 1
) (
    input  logic [ FP_WIDTH-1:0] i_operand,
    output logic                 o_sign,
    output logic [ EXP_BITS-1:0] o_exp,
    output logic [ EXP_BITS-1:0] o_exp_adj,
    output logic [FRAC_BITS-1:0] o_frac,
    output logic [MANT_BITS-1:0] o_mant,
    output logic                 o_is_zero,
    output logic                 o_is_subnormal,
    output logic                 o_is_inf,
    output logic                 o_is_nan,
    output logic                 o_is_snan
);

  // Extract fields
  assign o_sign = i_operand[FP_WIDTH-1];
  assign o_exp = i_operand[FP_WIDTH-2-:EXP_BITS];
  assign o_frac = i_operand[FRAC_BITS-1:0];

  // Adjusted exponent: subnormals use biased exponent 1 (not 0) for
  // correct arithmetic when combined with the denormalized mantissa.
  assign o_exp_adj = (o_exp == '0 && o_frac != '0) ? {{(EXP_BITS - 1) {1'b0}}, 1'b1} : o_exp;

  // Mantissa with implicit leading bit (1 for normal, 0 for zero/subnormal)
  assign o_mant = (o_exp == '0) ? {1'b0, o_frac} : {1'b1, o_frac};

  // Classification
  fp_classify_operand #(
      .EXP_BITS (EXP_BITS),
      .FRAC_BITS(FRAC_BITS)
  ) u_classify (
      .i_exp         (o_exp),
      .i_frac        (o_frac),
      .o_is_zero     (o_is_zero),
      .o_is_subnormal(o_is_subnormal),
      .o_is_inf      (o_is_inf),
      .o_is_nan      (o_is_nan),
      .o_is_snan     (o_is_snan)
  );

endmodule : fp_operand_unpacker
