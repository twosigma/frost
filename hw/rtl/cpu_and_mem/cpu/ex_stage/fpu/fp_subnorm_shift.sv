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
  Parameterized subnormal right-shift for IEEE 754 rounding.

  Pure combinational module. When i_exponent <= 0, right-shifts
  {mantissa, guard, round, sticky} by (1 - exponent) positions,
  accumulating a sticky bit from all shifted-out positions.
  When i_exponent > 0, passes through unchanged.
*/
module fp_subnorm_shift #(
    parameter int unsigned MANT_BITS    = 24,
    parameter int unsigned EXP_EXT_BITS = 10
) (
    input  logic        [   MANT_BITS-1:0] i_mantissa,
    input  logic                           i_guard,
    input  logic                           i_round,
    input  logic                           i_sticky,
    input  logic signed [EXP_EXT_BITS-1:0] i_exponent,
    output logic        [   MANT_BITS-1:0] o_mantissa,
    output logic                           o_guard,
    output logic                           o_round,
    output logic                           o_sticky,
    output logic signed [EXP_EXT_BITS-1:0] o_exponent
);

  localparam int unsigned TotalBits = MANT_BITS + 3;
  localparam int unsigned ShiftBits = $clog2(TotalBits + 1);

  logic        [ TotalBits-1:0] mantissa_ext;
  logic        [ TotalBits-1:0] shifted_ext;
  logic                         shifted_sticky;
  logic        [ ShiftBits-1:0] shift_amt;
  logic signed [EXP_EXT_BITS:0] shift_amt_signed;

  always_comb begin
    o_mantissa = i_mantissa;
    o_guard = i_guard;
    o_round = i_round;
    o_sticky = i_sticky;
    o_exponent = i_exponent;
    mantissa_ext = {i_mantissa, i_guard, i_round, i_sticky};
    shifted_ext = mantissa_ext;
    shifted_sticky = 1'b0;
    shift_amt = '0;
    shift_amt_signed = '0;

    if (i_exponent <= 0) begin
      shift_amt_signed = $signed({1'b0, {EXP_EXT_BITS{1'b0}}}) + 1 -
          $signed({i_exponent[EXP_EXT_BITS-1], i_exponent});
      if (shift_amt_signed >= $signed((EXP_EXT_BITS + 1)'(TotalBits)))
        shift_amt = ShiftBits'(TotalBits);
      else shift_amt = shift_amt_signed[ShiftBits-1:0];
      if (shift_amt >= ShiftBits'(TotalBits)) begin
        shifted_ext = '0;
        shifted_sticky = |mantissa_ext;
      end else if (shift_amt != 0) begin
        shifted_ext = mantissa_ext >> shift_amt;
        shifted_sticky = 1'b0;
        for (int i = 0; i < TotalBits; i++) begin
          if (i < shift_amt) shifted_sticky = shifted_sticky | mantissa_ext[i];
        end
      end
      o_mantissa = shifted_ext[TotalBits-1:3];
      o_guard = shifted_ext[2];
      o_round = shifted_ext[1];
      o_sticky = shifted_ext[0] | shifted_sticky;
      o_exponent = '0;
    end
  end

endmodule : fp_subnorm_shift
