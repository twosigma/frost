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
  The vector unit's floating-point to integer conversion for one IEEE 754
  format (EXP exponent and FRAC fraction bits) and one integer width IW, so
  one source covers vfcvt.x.f, vfcvt.xu.f, their round-toward-zero forms
  (with i_rm RTZ), and the widening and narrowing forms (vfwcvt.x.f,
  vfncvt.x.f and their unsigned forms). i_signed selects a signed result.
  Values out of range, infinities and NaNs give the RISC-V saturated result
  (the largest value for NaN and positive overflow, the smallest for negative
  overflow) and raise NV; an inexact in-range result raises NX. Every result
  appears a fixed five cycles after the cycle that takes the input.
*/
module vec_f2i #(
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    parameter int unsigned IW = 32,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input  logic          i_clk,
    input  logic          i_rst,
    input  logic          i_valid,
    input  logic          i_signed,
    input  logic [   2:0] i_rm,
    input  logic [ W-1:0] i_a,
    output logic          o_valid,
    output logic [IW-1:0] o_result,
    output logic [   4:0] o_flags
);

  localparam int P = FRAC + 1;
  localparam int Bias = (1 << (EXP - 1)) - 1;
  localparam int XW = EXP + 3;
  localparam int AW = $clog2(IW + 1);  // shift 0..IW
  localparam int IMax = IW - 1;  // signed, for exponent comparisons

  logic [5:0] v;
  always_ff @(posedge i_clk) begin
    if (i_rst) v <= '0;
    else v <= {v[4:0], i_valid};
  end

  // Stage 0: inputs.
  logic s0_signed;
  logic [2:0] s0_rm;
  logic [W-1:0] s0_a;
  always_ff @(posedge i_clk) begin
    s0_signed <= i_signed;
    s0_rm <= i_rm;
    s0_a <= i_a;
  end

  // Stage 1: classify. value = sig * 2^(e - FRAC); the fixed-point form
  // sig << (e + 1) has P fraction bits. e > IW - 1 always overflows; e < -1
  // leaves only a sticky bit.
  logic [EXP-1:0] a_e;
  logic signed [XW-1:0] a_exp;
  assign a_e   = s0_a[W-2-:EXP];
  assign a_exp = (a_e == '0) ? XW'(1 - Bias) : XW'(a_e) - XW'(Bias);

  logic s1_sign, s1_nan, s1_inf, s1_big, s1_tiny, s1_signed;
  logic [2:0] s1_rm;
  logic [AW-1:0] s1_amt;
  logic [P-1:0] s1_sig;
  always_ff @(posedge i_clk) begin
    s1_sign <= s0_a[W-1];
    s1_nan <= (a_e == '1) && (s0_a[FRAC-1:0] != '0);
    s1_inf <= (a_e == '1) && (s0_a[FRAC-1:0] == '0);
    s1_big <= (a_e != '1) && (a_exp > XW'(IMax));
    s1_tiny <= a_exp < -1;
    s1_amt <= AW'(a_exp + 1);
    s1_sig <= {a_e != '0, s0_a[FRAC-1:0]};
    s1_signed <= s0_signed;
    s1_rm <= s0_rm;
  end

  // Stage 2: shift into fixed point.
  logic [IW+P-1:0] s2_fixed;
  logic s2_sign, s2_nan, s2_inf, s2_big, s2_xsticky, s2_signed;
  logic [2:0] s2_rm;
  always_ff @(posedge i_clk) begin
    s2_fixed <= (s1_tiny || s1_big) ? '0 : ((IW + P)'(s1_sig) << s1_amt);
    s2_xsticky <= s1_tiny && (s1_sig != '0);
    s2_sign <= s1_sign;
    s2_nan <= s1_nan;
    s2_inf <= s1_inf;
    s2_big <= s1_big;
    s2_signed <= s1_signed;
    s2_rm <= s1_rm;
  end

  // Stage 3: rounding decision.
  function automatic logic round_up(input logic [2:0] rm, input logic sign, input logic lsb,
                                    input logic guard, input logic sticky);
    unique case (rm)
      3'd0: round_up = guard && (sticky || lsb);  // RNE
      3'd2: round_up = sign && (guard || sticky);  // RDN
      3'd3: round_up = !sign && (guard || sticky);  // RUP
      3'd4: round_up = guard;  // RMM
      default: round_up = 1'b0;  // RTZ
    endcase
  endfunction

  logic r_guard, r_sticky;
  assign r_guard  = s2_fixed[P-1];
  assign r_sticky = (|s2_fixed[P-2:0]) || s2_xsticky;

  logic [IW-1:0] s3_int;
  logic s3_up, s3_inexact, s3_sign, s3_nan, s3_inf, s3_big, s3_signed;
  always_ff @(posedge i_clk) begin
    s3_int <= s2_fixed[IW+P-1:P];
    s3_up <= round_up(s2_rm, s2_sign, s2_fixed[P], r_guard, r_sticky);
    s3_inexact <= r_guard || r_sticky;
    s3_sign <= s2_sign;
    s3_nan <= s2_nan;
    s3_inf <= s2_inf;
    s3_big <= s2_big;
    s3_signed <= s2_signed;
  end

  // Stage 4: increment.
  logic [IW:0] s4_mag;
  logic s4_inexact, s4_sign, s4_nan, s4_inf, s4_big, s4_signed;
  always_ff @(posedge i_clk) begin
    s4_mag <= {1'b0, s3_int} + (IW + 1)'(s3_up);
    s4_inexact <= s3_inexact;
    s4_sign <= s3_sign;
    s4_nan <= s3_nan;
    s4_inf <= s3_inf;
    s4_big <= s3_big;
    s4_signed <= s3_signed;
  end

  // Output: range, sign and saturation.
  logic [IW-1:0] result;
  logic [4:0] flags;
  always_comb begin
    logic fits, invalid;
    if (s4_signed)
      fits = s4_sign ? (s4_mag <= (IW + 1)'(1) << (IW - 1)) : (s4_mag < (IW + 1)'(1) << (IW - 1));
    else fits = s4_sign ? (s4_mag == '0) : !s4_mag[IW];
    invalid = s4_nan || s4_inf || s4_big || !fits;
    flags   = '0;
    if (invalid) begin
      flags[4] = 1'b1;
      if (s4_signed)
        result = (s4_sign && !s4_nan) ? {1'b1, {(IW - 1) {1'b0}}} : {1'b0, {(IW - 1) {1'b1}}};
      else result = (s4_sign && !s4_nan) ? '0 : '1;
    end else begin
      flags[0] = s4_inexact;
      result   = s4_sign ? IW'(-s4_mag) : s4_mag[IW-1:0];
    end
  end

  always_ff @(posedge i_clk) begin
    o_result <= result;
    o_flags  <= flags;
  end
  assign o_valid = v[5];

endmodule
