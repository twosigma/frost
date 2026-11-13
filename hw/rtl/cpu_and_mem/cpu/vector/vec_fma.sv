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
  A pipelined IEEE 754 fused multiply-add for one binary format, EXP exponent
  bits and FRAC fraction bits (5/10 half, 8/23 single, 11/52 double): the
  vector unit's FP16, FP32 and FP64 arithmetic. i_op selects
    0 multiply-add  (-1)^neg_prod * a * b + (-1)^neg_add * c, rounded once,
    1 multiply      (-1)^neg_prod * a * b,
    2 add           a + (-1)^neg_add * c,
  so the sequencer forms vfmacc, vfnmacc, vfmsac, vfnmsac, vfmadd and the
  rest, vfmul, vfadd, vfsub and vfrsub by choosing the operands and signs.
  i_rm is the RISC-V rounding mode (RNE, RTZ, RDN, RUP, RMM); o_flags are
  fflags {NV, DZ, OF, UF, NX} (DZ is always 0). NaN results are the canonical
  NaN; tininess is detected after rounding, and an infinity times a zero is
  invalid even when the addend is a quiet NaN.

  The product of the significands is placed at the bottom of a window of
  S = 3P+4 bits (P = FRAC+1); the addend starts at the top and is shifted
  right by the exponent difference while the multiplier runs, its shifted-out
  bits kept as a sticky bit. When the addend is far larger, or the product is
  zero, the addend stays at the top and the window's exponent follows it.
  The adder forms both differences at once so no negation follows it; a
  leading-zero count, a normalizing shift that stops at the smallest normal
  exponent (or a right shift when the window lies wholly below it), and one
  rounding finish the operation. Every stage holds one wide operation: the
  shifts are split into a coarse and a fine step. Every result appears a
  fixed fourteen cycles after the cycle that takes the input.
*/
module vec_fma #(
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input  logic         i_clk,
    input  logic         i_rst,
    input  logic         i_valid,
    input  logic [  1:0] i_op,
    input  logic         i_neg_prod,
    input  logic         i_neg_add,
    input  logic [  2:0] i_rm,
    input  logic [W-1:0] i_a,
    input  logic [W-1:0] i_b,
    input  logic [W-1:0] i_c,
    output logic         o_valid,
    output logic [W-1:0] o_result,
    output logic [  4:0] o_flags
);

  localparam int P = FRAC + 1;  // precision
  localparam int S = 3 * P + 4;  // window width
  localparam int Bias = (1 << (EXP - 1)) - 1;
  localparam int Emin = 1 - Bias;
  localparam int Emax = Bias;
  localparam int EW = EXP + 4;  // unpacked exponent width
  localparam int XW = EW + 2;  // exponent arithmetic width
  localparam int ShW = $clog2(S + 2);  // alignment shift, 0..S+1
  localparam int NB = (S + 16) / 16;  // 16-bit blocks covering S+1 bits
  localparam int LzW = $clog2(NB * 16 + 1);
  localparam int RW = $clog2(S + 3);  // right normalizing shift, 0..S+2
  localparam int Last = 14;  // index of the last pipeline stage
  localparam logic [W-1:0] CanonicalNan = {1'b0, {EXP{1'b1}}, 1'b1, {(FRAC - 1) {1'b0}}};
  localparam logic [W-1:0] One = {1'b0, 1'b0, {(EXP - 1) {1'b1}}, {FRAC{1'b0}}};

  // Valid bit of each stage; stage k holds an operation k cycles after input.
  logic [Last:0] v;
  always_ff @(posedge i_clk) begin
    if (i_rst) v <= '0;
    else v <= {v[Last-1:0], i_valid};
  end

  // --------------------------------------------------------------------------
  // Stage 0: inputs
  // --------------------------------------------------------------------------
  logic s0_mul_only, s0_neg_prod, s0_neg_add;
  logic [2:0] s0_rm;
  logic [W-1:0] s0_a, s0_b, s0_c;
  always_ff @(posedge i_clk) begin
    s0_mul_only <= (i_op == 2'd1);
    s0_neg_prod <= (i_op == 2'd2) ? 1'b0 : i_neg_prod;
    s0_neg_add <= (i_op == 2'd1) ? 1'b0 : i_neg_add;
    s0_rm <= i_rm;
    s0_a <= i_a;
    s0_b <= (i_op == 2'd2) ? One : i_b;
    s0_c <= (i_op == 2'd1) ? '0 : i_c;
  end

  // --------------------------------------------------------------------------
  // Stage 1: unpack
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic sign, is_zero, is_inf, is_nan, is_snan;
    logic signed [EW-1:0] exp;  // unbiased; subnormals use Emin
    logic [P-1:0] sig;
  } unpacked_t;

  localparam int UnpackedW = 5 + EW + P;
  // Returned as a plain vector in the struct's field order.
  function automatic logic [UnpackedW-1:0] unpack(input logic [W-1:0] x);
    logic [EXP-1:0] e;
    logic [FRAC-1:0] f;
    logic signed [EW-1:0] ex;
    e = x[W-2-:EXP];
    f = x[FRAC-1:0];
    ex = (e == '0) ? EW'(Emin) : EW'(signed'({1'b0, e})) - EW'(Bias);
    unpack = {
      x[W-1],
      (e == '0) && (f == '0),
      (e == '1) && (f == '0),
      (e == '1) && (f != '0),
      (e == '1) && (f != '0) && !f[FRAC-1],
      ex,
      e != '0,
      f
    };
  endfunction

  unpacked_t s1_a, s1_b, s1_c;
  logic s1_mul_only, s1_neg_prod, s1_neg_add;
  logic [2:0] s1_rm;
  always_ff @(posedge i_clk) begin
    s1_a <= unpack(s0_a);
    s1_b <= unpack(s0_b);
    s1_c <= unpack(s0_c);
    s1_mul_only <= s0_mul_only;
    s1_neg_prod <= s0_neg_prod;
    s1_neg_add <= s0_neg_add;
    s1_rm <= s0_rm;
  end

  // --------------------------------------------------------------------------
  // Operation summary, carried from stage 2 to the end
  // --------------------------------------------------------------------------
  // {rm[2:0], mul_only, sp, sc, invalid, any_nan, prod_inf, c_inf, prod_zero,
  //  c_zero}
  localparam int MW = 12;
  logic [MW-1:0] meta[2:Last];
  logic m_sp, m_sc, m_prod_inf, m_prod_zero, m_invalid;
  always_comb begin
    m_sp = s1_a.sign ^ s1_b.sign ^ s1_neg_prod;
    m_sc = s1_c.sign ^ s1_neg_add;
    m_prod_inf = s1_a.is_inf || s1_b.is_inf;
    m_prod_zero = s1_a.is_zero || s1_b.is_zero;
    m_invalid = s1_a.is_snan || s1_b.is_snan || s1_c.is_snan || (m_prod_inf && m_prod_zero) ||
        (m_prod_inf && !s1_a.is_nan && !s1_b.is_nan && s1_c.is_inf && (m_sp != m_sc));
  end
  always_ff @(posedge i_clk) begin
    meta[2] <= {
      s1_rm,
      s1_mul_only,
      m_sp,
      m_sc,
      m_invalid,
      s1_a.is_nan || s1_b.is_nan || s1_c.is_nan,
      m_prod_inf,
      s1_c.is_inf,
      m_prod_zero,
      s1_c.is_zero
    };
    for (int k = 3; k <= Last; k++) meta[k] <= meta[k-1];
  end
  function automatic logic [2:0] m_rm(input logic [MW-1:0] m);
    m_rm = m[11:9];
  endfunction
  function automatic logic m_eff_sub(input logic [MW-1:0] m);
    m_eff_sub = m[7] ^ m[6];
  endfunction

  // --------------------------------------------------------------------------
  // Multiplier: stage 1 operands, products registered at stages 2 to 5
  // --------------------------------------------------------------------------
  localparam int MulStages = 4;
  logic [2*P-1:0] prod[MulStages];
  always_ff @(posedge i_clk) begin
    prod[0] <= s1_a.sig * s1_b.sig;
    for (int k = 1; k < MulStages; k++) prod[k] <= prod[k-1];
  end

  // --------------------------------------------------------------------------
  // Stages 2 to 5: align the addend
  // --------------------------------------------------------------------------
  // Stage 2: the addend's distance below the window's top,
  // ea + eb - ec + P + 5, and the window's exponent when the product leads.
  logic signed [XW-1:0] s2_shift_raw, s2_e0n, s2_ec;
  logic s2_pzero;
  logic [P-1:0] s2_csig;
  always_ff @(posedge i_clk) begin
    s2_shift_raw <= XW'(s1_a.exp) + XW'(s1_b.exp) - XW'(s1_c.exp) + XW'(P + 5);
    s2_e0n <= XW'(s1_a.exp) + XW'(s1_b.exp) + XW'(P + 5);
    s2_ec <= XW'(s1_c.exp);
    s2_pzero <= s1_a.is_zero || s1_b.is_zero;
    s2_csig <= s1_c.is_zero ? '0 : s1_c.sig;
  end

  // Stage 3: the clamped shift and the exponent of the window's top bit (S).
  logic [ShW-1:0] s3_k;
  logic signed [XW-1:0] s3_e0;
  logic [P-1:0] s3_csig;
  always_ff @(posedge i_clk) begin
    if (s2_shift_raw < 0 || s2_pzero) begin
      s3_k  <= '0;
      s3_e0 <= s2_ec;
    end else begin
      s3_k  <= (s2_shift_raw > XW'(S + 1)) ? ShW'(S + 1) : ShW'(s2_shift_raw);
      s3_e0 <= s2_e0n;
    end
    s3_csig <= s2_csig;
  end

  // Stage 4: coarse shift by the multiple of 16, and the sticky bit: addend
  // bit i falls below the window when k > S - P + i.
  logic [S-1:0] s4_win;
  logic [3:0] s4_klo;
  logic s4_asticky;
  logic signed [XW-1:0] s4_e0;
  logic [P-1:0] amask;
  always_comb for (int i = 0; i < P; i++) amask[i] = (32'(s3_k) > 32'(S - P + i));
  always_ff @(posedge i_clk) begin
    s4_win <= {s3_csig, {(S - P) {1'b0}}} >> {s3_k[ShW-1:4], 4'b0};
    s4_klo <= s3_k[3:0];
    s4_asticky <= |(s3_csig & amask);
    s4_e0 <= s3_e0;
  end

  // Stage 5: fine shift.
  logic [S-1:0] s5_addend;
  logic s5_asticky;
  logic signed [XW-1:0] s5_e0;
  always_ff @(posedge i_clk) begin
    s5_addend <= s4_win >> s4_klo;
    s5_asticky <= s4_asticky;
    s5_e0 <= s4_e0;
  end

  // --------------------------------------------------------------------------
  // Stage 6: product plus or minus addend, and addend minus product
  // --------------------------------------------------------------------------
  logic [S+1:0] s6_r1, s6_r2;
  logic signed [XW-1:0] s6_e0;
  logic [S+1:0] sum_x, sum_y;
  assign sum_x = (S + 2)'({prod[MulStages-1], 1'b0});
  assign sum_y = {1'b0, s5_addend, s5_asticky};
  always_ff @(posedge i_clk) begin
    s6_r1 <= m_eff_sub(meta[5]) ? (sum_x - sum_y) : (sum_x + sum_y);
    s6_r2 <= sum_y - sum_x;
    s6_e0 <= s5_e0;
  end

  // --------------------------------------------------------------------------
  // Stage 7: magnitude and sign; leading zeros of each 16-bit block
  // --------------------------------------------------------------------------
  logic [S:0] mag;
  logic neg;
  logic [NB*16-1:0] magp;
  assign neg  = m_eff_sub(meta[6]) && s6_r1[S+1];
  assign mag  = neg ? s6_r2[S:0] : s6_r1[S:0];
  assign magp = {mag, {(NB * 16 - S - 1) {1'b0}}};

  logic [S:0] s7_mag;
  logic s7_sign;
  logic [NB-1:0] s7_bz;  // block b (b = 0 at the top) is all zero
  logic [NB-1:0][3:0] s7_blz;  // leading zeros within block b
  logic signed [XW-1:0] s7_e0;
  logic [NB-1:0] bz;
  logic [NB-1:0][3:0] blz;
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      bz[b]  = (magp[NB*16-1-16*b-:16] == '0);
      blz[b] = 4'd15;
      for (int j = 0; j < 16; j++) if (magp[NB*16-16-16*b+j]) blz[b] = 4'(15 - j);
    end
  end
  always_ff @(posedge i_clk) begin
    s7_bz   <= bz;
    s7_blz  <= blz;
    s7_mag  <= mag;
    s7_sign <= meta[6][7] ^ neg;
    s7_e0   <= s6_e0;
  end

  // --------------------------------------------------------------------------
  // Stage 8: leading-zero count
  // --------------------------------------------------------------------------
  logic [S:0] s8_mag;
  logic s8_sign, s8_zero;
  logic [LzW-1:0] s8_lz;
  logic signed [XW-1:0] s8_e0, s8_head;
  logic [LzW-1:0] lz;
  always_comb begin
    lz = '0;
    for (int b = NB - 1; b >= 0; b--) if (!s7_bz[b]) lz = LzW'(16 * b) + LzW'(s7_blz[b]);
  end
  always_ff @(posedge i_clk) begin
    s8_lz   <= lz;
    s8_zero <= &s7_bz;
    s8_mag  <= s7_mag;
    s8_sign <= s7_sign;
    s8_e0   <= s7_e0;
    s8_head <= s7_e0 - XW'(Emin);
  end

  // --------------------------------------------------------------------------
  // Stage 9: normalizing shift amounts and exponents
  // --------------------------------------------------------------------------
  // The magnitude moves left until its leading one is at the top, but no
  // further than to the smallest normal exponent; a magnitude whose top
  // exponent is already below it moves right instead.
  logic [S:0] s9_mag;
  logic s9_sign, s9_zero, s9_right;
  logic [LzW-1:0] s9_lamt;
  logic [ RW-1:0] s9_ramt;
  logic signed [XW-1:0] s9_exp, s9_exp_full;
  logic signed [XW-1:0] lzx;
  assign lzx = XW'(s8_lz);
  always_ff @(posedge i_clk) begin
    s9_right <= s8_head < 0;
    s9_ramt  <= (s8_head < -XW'(S + 2)) ? RW'(S + 2) : RW'(-s8_head);
    if (s8_head < 0) begin
      s9_lamt <= '0;
      s9_exp  <= XW'(Emin);
    end else if (lzx > s8_head) begin
      s9_lamt <= LzW'(s8_head);
      s9_exp  <= XW'(Emin);
    end else begin
      s9_lamt <= s8_lz;
      s9_exp  <= s8_e0 - lzx;
    end
    s9_exp_full <= s8_e0 - lzx;
    s9_mag <= s8_mag;
    s9_sign <= s8_sign;
    s9_zero <= s8_zero;
  end

  // --------------------------------------------------------------------------
  // Stage 10: coarse shifts; the right shift's sticky bit (bit j leaves when
  // the shift exceeds j)
  // --------------------------------------------------------------------------
  logic [S:0] s10_lw, s10_rw;
  logic [3:0] s10_llo, s10_rlo;
  logic s10_rsticky, s10_right, s10_sign, s10_zero;
  logic signed [XW-1:0] s10_exp, s10_exp_full;
  logic [S:0] rmask;
  always_comb for (int j = 0; j <= S; j++) rmask[j] = (32'(s9_ramt) > 32'(j));
  always_ff @(posedge i_clk) begin
    s10_lw <= s9_mag << {s9_lamt[LzW-1:4], 4'b0};
    s10_rw <= s9_mag >> {s9_ramt[RW-1:4], 4'b0};
    s10_llo <= s9_lamt[3:0];
    s10_rlo <= s9_ramt[3:0];
    s10_rsticky <= s9_right && |(s9_mag & rmask);
    s10_right <= s9_right;
    s10_sign <= s9_sign;
    s10_zero <= s9_zero;
    s10_exp <= s9_exp;
    s10_exp_full <= s9_exp_full;
  end

  // --------------------------------------------------------------------------
  // Stage 11: fine shifts
  // --------------------------------------------------------------------------
  logic [S:0] s11_norm;
  logic s11_nsticky, s11_sign, s11_zero;
  logic signed [XW-1:0] s11_exp, s11_exp_full;
  always_ff @(posedge i_clk) begin
    s11_norm <= s10_right ? (s10_rw >> s10_rlo) : (s10_lw << s10_llo);
    s11_nsticky <= s10_rsticky;
    s11_sign <= s10_sign;
    s11_zero <= s10_zero;
    s11_exp <= s10_exp;
    s11_exp_full <= s10_exp_full;
  end

  // --------------------------------------------------------------------------
  // Stage 12: rounding decision, tininess, exponent fields
  // --------------------------------------------------------------------------
  function automatic logic round_up(input logic [2:0] rm, input logic sign, input logic lsb,
                                    input logic guard, input logic sticky);
    unique case (rm)
      3'd0: round_up = guard && (sticky || lsb);  // RNE
      3'd1: round_up = 1'b0;  // RTZ
      3'd2: round_up = sign && (guard || sticky);  // RDN
      3'd3: round_up = !sign && (guard || sticky);  // RUP
      default: round_up = guard;  // RMM
    endcase
  endfunction

  logic [P-1:0] s12_sig;
  logic s12_up, s12_inexact, s12_tiny, s12_sign, s12_zero, s12_ovf_gt, s12_ovf_eq;
  logic [EXP-1:0] s12_ef0, s12_ef1;
  logic r_guard, r_sticky, r_carry_full;
  logic [2:0] r_rm;
  always_comb begin
    r_rm = m_rm(meta[11]);
    r_guard = s11_norm[S-P];
    r_sticky = (|s11_norm[S-P-1:0]) || s11_nsticky;
    // With the exponent unbounded, a value one binade below the smallest
    // normal has its leading one at bit S-1; it rounds up to 2^Emin, and is
    // then not tiny, when its top P bits are all ones and it rounds up.
    r_carry_full = (&s11_norm[S-1-:P]) && round_up(r_rm, s11_sign, s11_norm[S-P], s11_norm[S-P-1],
                                                   (|s11_norm[S-P-2:0]) || s11_nsticky);
  end
  always_ff @(posedge i_clk) begin
    s12_sig <= s11_norm[S-:P];
    s12_up <= round_up(r_rm, s11_sign, s11_norm[S-P+1], r_guard, r_sticky);
    s12_inexact <= r_guard || r_sticky;
    s12_tiny <= (s11_exp_full < XW'(Emin)) && !((s11_exp_full == XW'(Emin - 1)) && r_carry_full);
    s12_sign <= s11_sign;
    s12_zero <= s11_zero;
    s12_ovf_gt <= s11_exp > XW'(Emax);
    s12_ovf_eq <= s11_exp == XW'(Emax);
    s12_ef0 <= EXP'(s11_exp + XW'(Bias));
    s12_ef1 <= EXP'(s11_exp + XW'(Bias + 1));
  end

  // --------------------------------------------------------------------------
  // Stage 13: increment
  // --------------------------------------------------------------------------
  // A carry out of the top leaves the fraction zero and moves the exponent up.
  logic [P:0] s13_sig;
  logic s13_inexact, s13_tiny, s13_sign, s13_zero, s13_ovf_gt, s13_ovf_eq;
  logic [EXP-1:0] s13_ef0, s13_ef1;
  always_ff @(posedge i_clk) begin
    s13_sig <= {1'b0, s12_sig} + (P + 1)'(s12_up);
    s13_inexact <= s12_inexact;
    s13_tiny <= s12_tiny;
    s13_sign <= s12_sign;
    s13_zero <= s12_zero;
    s13_ovf_gt <= s12_ovf_gt;
    s13_ovf_eq <= s12_ovf_eq;
    s13_ef0 <= s12_ef0;
    s13_ef1 <= s12_ef1;
  end

  // --------------------------------------------------------------------------
  // Stage 14: overflow, special operands, packing
  // --------------------------------------------------------------------------
  logic [W-1:0] result;
  logic [  4:0] flags;
  always_comb begin
    logic [MW-1:0] m;
    logic [2:0] rm;
    logic mul_only, sp, sc, invalid, any_nan, prod_inf, c_inf, prod_zero, c_zero;
    logic carry, overflow;
    logic [EXP-1:0] efield;
    m = meta[13];
    {rm, mul_only, sp, sc, invalid, any_nan, prod_inf, c_inf, prod_zero, c_zero} = m;
    carry = s13_sig[P];
    overflow = s13_ovf_gt || (s13_ovf_eq && carry);
    // A subnormal keeps exponent field 0 until rounding sets the hidden bit.
    efield = carry ? s13_ef1 : (s13_sig[P-1] ? s13_ef0 : '0);
    flags = '0;
    if (invalid || any_nan) begin
      result   = CanonicalNan;
      flags[4] = invalid;
    end else if (prod_inf) begin
      result = {sp, {EXP{1'b1}}, {FRAC{1'b0}}};
    end else if (c_inf) begin
      result = {sc, {EXP{1'b1}}, {FRAC{1'b0}}};
    end else if (s13_zero) begin
      // An exact zero: the common sign when both terms are zero with one sign
      // (or the product alone for a multiply), else +0, or -0 rounding down.
      if (mul_only) result = {sp, {(W - 1) {1'b0}}};
      else if (prod_zero && c_zero && (sp == sc)) result = {sp, {(W - 1) {1'b0}}};
      else result = {(rm == 3'd2), {(W - 1) {1'b0}}};
    end else if (overflow) begin
      flags[2] = 1'b1;
      flags[0] = 1'b1;
      // RTZ, and rounding toward the other infinity, give the largest finite.
      if ((rm == 3'd1) || (rm == 3'd2 && !s13_sign) || (rm == 3'd3 && s13_sign))
        result = {s13_sign, {(EXP - 1) {1'b1}}, 1'b0, {FRAC{1'b1}}};
      else result = {s13_sign, {EXP{1'b1}}, {FRAC{1'b0}}};
    end else begin
      result   = {s13_sign, efield, s13_sig[FRAC-1:0]};
      flags[0] = s13_inexact;
      flags[1] = s13_inexact && s13_tiny;
    end
  end

  always_ff @(posedge i_clk) begin
    o_result <= result;
    o_flags  <= flags;
  end
  assign o_valid = v[Last];

endmodule
