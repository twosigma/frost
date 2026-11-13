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
  The vector unit's integer to floating-point conversion for one integer
  width IW and one IEEE 754 format (EXP exponent and FRAC fraction bits), so
  one source covers vfcvt.f.x, vfcvt.f.xu and the widening and narrowing
  forms (vfwcvt.f.x, vfncvt.f.x and their unsigned forms). i_signed reads the
  input as signed. The result is rounded in i_rm; o_flags raise NX when
  rounding changes the value, and OF with NX when it exceeds the format.
  Every result appears a fixed seven cycles after the cycle that takes the
  input.
*/
module vec_i2f #(
    parameter int unsigned IW = 32,
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input  logic          i_clk,
    input  logic          i_rst,
    input  logic          i_valid,
    input  logic          i_signed,
    input  logic [   2:0] i_rm,
    input  logic [IW-1:0] i_a,
    output logic          o_valid,
    output logic [ W-1:0] o_result,
    output logic [   4:0] o_flags
);

  localparam int P = FRAC + 1;
  localparam int Bias = (1 << (EXP - 1)) - 1;
  localparam int Emax = Bias;
  localparam int NB = (IW + 15) / 16;  // 16-bit blocks covering IW bits
  localparam int LzW = $clog2(NB * 16 + 1);
  localparam int XW = (EXP > 8 ? EXP : 8) + 3;
  localparam int WN = (IW > P + 2) ? IW : P + 2;  // rounding window
  localparam int IMax = IW - 1;

  logic [7:0] v;
  always_ff @(posedge i_clk) begin
    if (i_rst) v <= '0;
    else v <= {v[6:0], i_valid};
  end

  // Stage 0: inputs.
  logic s0_signed;
  logic [2:0] s0_rm;
  logic [IW-1:0] s0_a;
  always_ff @(posedge i_clk) begin
    s0_signed <= i_signed;
    s0_rm <= i_rm;
    s0_a <= i_a;
  end

  // Stage 1: sign and magnitude.
  logic s1_sign;
  logic [2:0] s1_rm;
  logic [IW-1:0] s1_mag;
  always_ff @(posedge i_clk) begin
    s1_sign <= s0_signed && s0_a[IW-1];
    s1_mag  <= (s0_signed && s0_a[IW-1]) ? -s0_a : s0_a;
    s1_rm   <= s0_rm;
  end

  // Stage 2: leading zeros of each 16-bit block (block 0 at the top).
  logic [NB*16-1:0] magp;
  logic [NB-1:0] bz;
  logic [NB-1:0][3:0] blz;
  assign magp = {s1_mag, {(NB * 16 - IW) {1'b0}}};
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      bz[b]  = (magp[NB*16-1-16*b-:16] == '0);
      blz[b] = 4'd15;
      for (int j = 0; j < 16; j++) if (magp[NB*16-16-16*b+j]) blz[b] = 4'(15 - j);
    end
  end
  logic s2_sign;
  logic [2:0] s2_rm;
  logic [IW-1:0] s2_mag;
  logic [NB-1:0] s2_bz;
  logic [NB-1:0][3:0] s2_blz;
  always_ff @(posedge i_clk) begin
    s2_sign <= s1_sign;
    s2_rm   <= s1_rm;
    s2_mag  <= s1_mag;
    s2_bz   <= bz;
    s2_blz  <= blz;
  end

  // Stage 3: leading-zero count.
  logic [LzW-1:0] lz;
  always_comb begin
    lz = '0;
    for (int b = NB - 1; b >= 0; b--) if (!s2_bz[b]) lz = LzW'(16 * b) + LzW'(s2_blz[b]);
  end
  logic s3_sign, s3_zero;
  logic [2:0] s3_rm;
  logic [IW-1:0] s3_mag;
  logic [LzW-1:0] s3_lz;
  always_ff @(posedge i_clk) begin
    s3_sign <= s2_sign;
    s3_zero <= &s2_bz;
    s3_rm   <= s2_rm;
    s3_mag  <= s2_mag;
    s3_lz   <= lz;
  end

  // Stage 4: normalize; the leading one's weight is 2^(IW - 1 - lz).
  logic s4_sign, s4_zero;
  logic [2:0] s4_rm;
  logic [WN-1:0] s4_win;
  logic signed [XW-1:0] s4_exp;
  always_ff @(posedge i_clk) begin
    s4_sign <= s3_sign;
    s4_zero <= s3_zero;
    s4_rm   <= s3_rm;
    s4_win  <= {s3_mag << s3_lz, {(WN - IW) {1'b0}}};
    s4_exp  <= XW'(IMax) - XW'(s3_lz);
  end

  // Stage 5: rounding decision.
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
  assign r_guard  = s4_win[WN-1-P];
  assign r_sticky = |s4_win[WN-2-P:0];

  logic s5_sign, s5_zero, s5_up, s5_inexact, s5_ovf_gt, s5_ovf_eq;
  logic [  2:0] s5_rm;
  logic [P-1:0] s5_sig;
  logic [EXP-1:0] s5_ef0, s5_ef1;
  always_ff @(posedge i_clk) begin
    s5_sign <= s4_sign;
    s5_zero <= s4_zero;
    s5_rm <= s4_rm;
    s5_sig <= s4_win[WN-1-:P];
    s5_up <= round_up(s4_rm, s4_sign, s4_win[WN-P], r_guard, r_sticky);
    s5_inexact <= r_guard || r_sticky;
    s5_ovf_gt <= s4_exp > XW'(Emax);
    s5_ovf_eq <= s4_exp == XW'(Emax);
    s5_ef0 <= EXP'(s4_exp + XW'(Bias));
    s5_ef1 <= EXP'(s4_exp + XW'(Bias + 1));
  end

  // Stage 6: increment; a carry out leaves the fraction zero.
  logic s6_sign, s6_zero, s6_inexact, s6_ovf_gt, s6_ovf_eq;
  logic [2:0] s6_rm;
  logic [P:0] s6_sig;
  logic [EXP-1:0] s6_ef0, s6_ef1;
  always_ff @(posedge i_clk) begin
    s6_sign <= s5_sign;
    s6_zero <= s5_zero;
    s6_rm <= s5_rm;
    s6_sig <= {1'b0, s5_sig} + (P + 1)'(s5_up);
    s6_inexact <= s5_inexact;
    s6_ovf_gt <= s5_ovf_gt;
    s6_ovf_eq <= s5_ovf_eq;
    s6_ef0 <= s5_ef0;
    s6_ef1 <= s5_ef1;
  end

  // Output: overflow and packing.
  logic [W-1:0] result;
  logic [  4:0] flags;
  always_comb begin
    flags = '0;
    if (s6_zero) begin
      result = '0;
    end else if (s6_ovf_gt || (s6_ovf_eq && s6_sig[P])) begin
      flags[2] = 1'b1;
      flags[0] = 1'b1;
      // RTZ, and rounding toward the other infinity, give the largest finite.
      if ((s6_rm == 3'd1) || (s6_rm == 3'd2 && !s6_sign) || (s6_rm == 3'd3 && s6_sign))
        result = {s6_sign, {(EXP - 1) {1'b1}}, 1'b0, {FRAC{1'b1}}};
      else result = {s6_sign, {EXP{1'b1}}, {FRAC{1'b0}}};
    end else begin
      result   = {s6_sign, s6_sig[P] ? s6_ef1 : s6_ef0, s6_sig[FRAC-1:0]};
      flags[0] = s6_inexact;
    end
  end

  always_ff @(posedge i_clk) begin
    o_result <= result;
    o_flags  <= flags;
  end
  assign o_valid = v[7];

endmodule
