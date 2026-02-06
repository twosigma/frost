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
  Parameterized IEEE 754 operand classifier.

  Pure combinational module. Classifies an FP operand based on its
  exponent and fraction fields.
*/
module fp_classify_operand #(
    parameter int unsigned EXP_BITS  = 8,
    parameter int unsigned FRAC_BITS = 23
) (
    input  logic [ EXP_BITS-1:0] i_exp,
    input  logic [FRAC_BITS-1:0] i_frac,
    output logic                 o_is_zero,
    output logic                 o_is_subnormal,
    output logic                 o_is_inf,
    output logic                 o_is_nan,
    output logic                 o_is_snan
);

  localparam logic [EXP_BITS-1:0] ExpMax = {EXP_BITS{1'b1}};

  assign o_is_zero      = (i_exp == '0) && (i_frac == '0);
  assign o_is_subnormal = (i_exp == '0) && (i_frac != '0);
  assign o_is_inf       = (i_exp == ExpMax) && (i_frac == '0);
  assign o_is_nan       = (i_exp == ExpMax) && (i_frac != '0);
  assign o_is_snan      = o_is_nan && ~i_frac[FRAC_BITS-1];

endmodule : fp_classify_operand
