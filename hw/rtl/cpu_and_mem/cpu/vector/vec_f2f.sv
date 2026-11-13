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
  The vector unit's floating-point to floating-point conversion from one IEEE
  754 format (SEXP exponent and SFRAC fraction bits) to another (DEXP and
  DFRAC): vfwcvt.f.f when the destination is wider, which is exact, and
  vfncvt.f.f when it is narrower. i_rm is the RISC-V rounding mode, or 5 for
  round to odd (vfncvt.rod.f.f). NaNs become the canonical NaN, and a
  signaling NaN raises NV; a narrowing raises OF, UF (tininess after
  rounding) and NX as IEEE 754 defines them. Every result appears a fixed
  eight cycles after the cycle that takes the input.
*/
module vec_f2f #(
    parameter int unsigned SEXP = 8,
    parameter int unsigned SFRAC = 23,
    parameter int unsigned DEXP = 11,
    parameter int unsigned DFRAC = 52,
    localparam int unsigned SW = 1 + SEXP + SFRAC,
    localparam int unsigned DW = 1 + DEXP + DFRAC
) (
    input  logic          i_clk,
    input  logic          i_rst,
    input  logic          i_valid,
    input  logic [   2:0] i_rm,
    input  logic [SW-1:0] i_a,
    output logic          o_valid,
    output logic [DW-1:0] o_result,
    output logic [   4:0] o_flags
);

  localparam int SP = SFRAC + 1;
  localparam int DP = DFRAC + 1;
  localparam int SBias = (1 << (SEXP - 1)) - 1;
  localparam int DBias = (1 << (DEXP - 1)) - 1;
  localparam int SEmin = 1 - SBias;
  localparam int DEmin = 1 - DBias;
  localparam int DEmax = DBias;
  localparam int XW = ((SEXP > DEXP) ? SEXP : DEXP) + 3;
  localparam int NB = (SP + 15) / 16;
  localparam int LzW = $clog2(NB * 16 + 1);
  localparam int WN = ((SP > DP) ? SP : DP) + 2;  // rounding window
  localparam int RW = $clog2(WN + 1);  // subnormal shift, 0..WN
  localparam logic [DW-1:0] CanonicalNan = {1'b0, {DEXP{1'b1}}, 1'b1, {(DFRAC - 1) {1'b0}}};

  logic [8:0] v;
  always_ff @(posedge i_clk) begin
    if (i_rst) v <= '0;
    else v <= {v[7:0], i_valid};
  end

  // Special operands, carried from stage 1 to stage 7: {nan, snan, inf, zero}.
  logic [3:0] spec[1:7];
  logic sgn[1:7];
  logic [2:0] rmq[1:7];

  // Stage 0: inputs.
  logic [2:0] s0_rm;
  logic [SW-1:0] s0_a;
  always_ff @(posedge i_clk) begin
    s0_rm <= i_rm;
    s0_a  <= i_a;
  end

  // Stage 1: unpack.
  logic [ SEXP-1:0] a_e;
  logic [SFRAC-1:0] a_f;
  assign a_e = s0_a[SW-2-:SEXP];
  assign a_f = s0_a[SFRAC-1:0];
  logic [SP-1:0] s1_sig;
  logic signed [XW-1:0] s1_exp;
  always_ff @(posedge i_clk) begin
    spec[1] <= {
      (a_e == '1) && (a_f != '0),
      (a_e == '1) && (a_f != '0) && !a_f[SFRAC-1],
      (a_e == '1) && (a_f == '0),
      (a_e == '0) && (a_f == '0)
    };
    sgn[1] <= s0_a[SW-1];
    rmq[1] <= s0_rm;
    s1_sig <= {a_e != '0, a_f};
    s1_exp <= (a_e == '0) ? XW'(SEmin) : XW'(a_e) - XW'(SBias);
    for (int k = 2; k <= 7; k++) begin
      spec[k] <= spec[k-1];
      sgn[k]  <= sgn[k-1];
      rmq[k]  <= rmq[k-1];
    end
  end

  // Stage 2: leading zeros of each 16-bit block of the significand.
  logic [NB*16-1:0] sigp;
  logic [NB-1:0] bz;
  logic [NB-1:0][3:0] blz;
  assign sigp = {s1_sig, {(NB * 16 - SP) {1'b0}}};
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      bz[b]  = (sigp[NB*16-1-16*b-:16] == '0);
      blz[b] = 4'd15;
      for (int j = 0; j < 16; j++) if (sigp[NB*16-16-16*b+j]) blz[b] = 4'(15 - j);
    end
  end
  logic [SP-1:0] s2_sig;
  logic signed [XW-1:0] s2_exp;
  logic [NB-1:0] s2_bz;
  logic [NB-1:0][3:0] s2_blz;
  always_ff @(posedge i_clk) begin
    s2_sig <= s1_sig;
    s2_exp <= s1_exp;
    s2_bz  <= bz;
    s2_blz <= blz;
  end

  // Stage 3: leading-zero count.
  logic [LzW-1:0] lz;
  always_comb begin
    lz = '0;
    for (int b = NB - 1; b >= 0; b--) if (!s2_bz[b]) lz = LzW'(16 * b) + LzW'(s2_blz[b]);
  end
  logic [SP-1:0] s3_sig;
  logic signed [XW-1:0] s3_exp;
  logic [LzW-1:0] s3_lz;
  always_ff @(posedge i_clk) begin
    s3_sig <= s2_sig;
    s3_exp <= s2_exp;
    s3_lz  <= lz;
  end

  // Stage 4: normalize (a subnormal source moves its leading one to the top)
  // and find how far the destination's subnormal range shifts it right.
  logic [WN-1:0] s4_win;
  logic signed [XW-1:0] s4_exp;
  logic [RW-1:0] s4_rsh;
  logic signed [XW-1:0] e_norm;
  assign e_norm = s3_exp - XW'(s3_lz);
  always_ff @(posedge i_clk) begin
    s4_win <= {s3_sig << s3_lz, {(WN - SP) {1'b0}}};
    s4_exp <= e_norm;
    if (e_norm >= XW'(DEmin)) s4_rsh <= '0;
    else if (XW'(DEmin) - e_norm > XW'(WN)) s4_rsh <= RW'(WN);
    else s4_rsh <= RW'(XW'(DEmin) - e_norm);
  end

  // Stage 5: the right shift into the subnormal range, its sticky bit, and
  // whether the value rounded with the exponent unbounded reaches 2^DEmin
  // (for tininess after rounding).
  function automatic logic round_up(input logic [2:0] rm, input logic sign, input logic lsb,
                                    input logic guard, input logic sticky);
    unique case (rm)
      3'd0: round_up = guard && (sticky || lsb);  // RNE
      3'd2: round_up = sign && (guard || sticky);  // RDN
      3'd3: round_up = !sign && (guard || sticky);  // RUP
      3'd4: round_up = guard;  // RMM
      default: round_up = 1'b0;  // RTZ, round to odd
    endcase
  endfunction

  logic [WN-1:0] rmask;
  always_comb for (int j = 0; j < WN; j++) rmask[j] = (32'(s4_rsh) > 32'(j));
  logic [WN-1:0] s5_win;
  logic s5_xsticky, s5_carry_full;
  logic signed [XW-1:0] s5_exp, s5_exp_full;
  always_ff @(posedge i_clk) begin
    s5_win <= s4_win >> s4_rsh;
    s5_xsticky <= |(s4_win & rmask);
    s5_exp <= (s4_rsh != '0) ? XW'(DEmin) : s4_exp;
    s5_exp_full <= s4_exp;
    s5_carry_full <= (&s4_win[WN-1-:DP]) && round_up(
        rmq[4], sgn[4], s4_win[WN-DP], s4_win[WN-1-DP], |s4_win[WN-2-DP:0]
    );
  end

  // Stage 6: rounding decision; round to odd sets the last bit when inexact.
  logic r_guard, r_sticky;
  assign r_guard  = s5_win[WN-1-DP];
  assign r_sticky = (|s5_win[WN-2-DP:0]) || s5_xsticky;
  logic [DP-1:0] s6_sig;
  logic s6_up, s6_jam, s6_inexact, s6_tiny, s6_ovf_gt, s6_ovf_eq;
  logic [DEXP-1:0] s6_ef0, s6_ef1;
  always_ff @(posedge i_clk) begin
    s6_sig <= s5_win[WN-1-:DP];
    s6_up <= round_up(rmq[5], sgn[5], s5_win[WN-DP], r_guard, r_sticky);
    s6_jam <= (rmq[5] == 3'd5) && (r_guard || r_sticky);
    s6_inexact <= r_guard || r_sticky;
    s6_tiny <= (s5_exp_full < XW'(DEmin)) && !((s5_exp_full == XW'(DEmin - 1)) && s5_carry_full);
    s6_ovf_gt <= s5_exp > XW'(DEmax);
    s6_ovf_eq <= s5_exp == XW'(DEmax);
    s6_ef0 <= DEXP'(s5_exp + XW'(DBias));
    s6_ef1 <= DEXP'(s5_exp + XW'(DBias + 1));
  end

  // Stage 7: increment.
  logic [DP:0] s7_sig;
  logic s7_inexact, s7_tiny, s7_ovf_gt, s7_ovf_eq;
  logic [DEXP-1:0] s7_ef0, s7_ef1;
  always_ff @(posedge i_clk) begin
    s7_sig <= ({1'b0, s6_sig} + (DP + 1)'(s6_up)) | (DP + 1)'(s6_jam);
    s7_inexact <= s6_inexact;
    s7_tiny <= s6_tiny;
    s7_ovf_gt <= s6_ovf_gt;
    s7_ovf_eq <= s6_ovf_eq;
    s7_ef0 <= s6_ef0;
    s7_ef1 <= s6_ef1;
  end

  // Output: overflow, special operands, packing. A subnormal keeps exponent
  // field 0 until rounding sets the hidden bit.
  logic [DW-1:0] result;
  logic [4:0] flags;
  always_comb begin
    logic is_nan, is_snan, is_inf, is_zero, sign;
    logic [2:0] rm;
    {is_nan, is_snan, is_inf, is_zero} = spec[7];
    sign = sgn[7];
    rm = rmq[7];
    flags = '0;
    if (is_nan) begin
      result   = CanonicalNan;
      flags[4] = is_snan;
    end else if (is_inf) begin
      result = {sign, {DEXP{1'b1}}, {DFRAC{1'b0}}};
    end else if (is_zero) begin
      result = {sign, {(DW - 1) {1'b0}}};
    end else if (s7_ovf_gt || (s7_ovf_eq && s7_sig[DP])) begin
      flags[2] = 1'b1;
      flags[0] = 1'b1;
      // RTZ, round to odd, and rounding toward the other infinity give the
      // largest finite value.
      if ((rm == 3'd1) || (rm == 3'd5) || (rm == 3'd2 && !sign) || (rm == 3'd3 && sign))
        result = {sign, {(DEXP - 1) {1'b1}}, 1'b0, {DFRAC{1'b1}}};
      else result = {sign, {DEXP{1'b1}}, {DFRAC{1'b0}}};
    end else begin
      result   = {sign, s7_sig[DP] ? s7_ef1 : (s7_sig[DP-1] ? s7_ef0 : '0), s7_sig[DFRAC-1:0]};
      flags[0] = s7_inexact;
      flags[1] = s7_inexact && s7_tiny;
    end
  end

  always_ff @(posedge i_clk) begin
    o_result <= result;
    o_flags  <= flags;
  end
  assign o_valid = v[8];

endmodule
