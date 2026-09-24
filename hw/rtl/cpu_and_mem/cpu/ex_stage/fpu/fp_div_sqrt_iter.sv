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
  Iterative IEEE 754 divide and square root: FDIV.S, FDIV.D, FSQRT.S, FSQRT.D
  on one shared datapath. FP divide and square root are rare, so the unit runs
  one operation at a time.

  Handshake: o_ready is high only in the idle state. An operation starts on a
  cycle with i_valid and o_ready high (and i_kill low), and o_valid pulses for
  one cycle when the result is ready. i_kill drops the operation in progress:
  the unit returns to idle and produces no later completion. o_valid is not
  gated by i_kill, so the caller must drop a result that completes in the kill
  cycle. Single-precision results appear in o_result[31:0]; the caller
  NaN-boxes them.

  Latency from the accepted i_valid cycle to the o_valid cycle:
    single precision  36 cycles
    double precision  65 cycles

  Results, flags, and latency must match the unrolled reference pipelines in
  hw/sim (fp_divider and fp_sqrt) for every operand, rounding mode, and
  precision; the fp_div_sqrt_equiv bench tests this over directed and random
  operands. Each state computes one reference stage's expressions with the same
  helper modules, so the register values match the reference's after every
  state, except in the datapath of a special case, which fp_result_assembler
  ignores (see ST_NORM). The shared registers differ in width from the
  reference's; the comments below give the bounds that make them hold the same
  values.
*/
module fp_div_sqrt_iter (
    input logic i_clk,
    input logic i_rst,

    // Operation start. Sampled only while o_ready is high.
    input logic        i_valid,
    input logic        i_is_sqrt,
    input logic        i_is_double,
    input logic [63:0] i_operand_a,
    input logic [63:0] i_operand_b,
    input logic [ 2:0] i_rounding_mode,

    // Drop the operation in progress (pipeline flush).
    input logic i_kill,

    output logic                        o_ready,
    output logic                        o_valid,
    output logic                 [63:0] o_result,
    output riscv_pkg::fp_flags_t        o_flags
);

  // Widest of the two precisions. Single-precision values are right-justified
  // in the same registers. Every operator involved (add, subtract, compare,
  // shift left, shift right, OR reduction) agrees with its narrow counterpart
  // on zero-extended operands as long as the bits a narrow shift would drop are
  // zero (see the bounds at ST_SETUP and ST_ITERATE), so the single-precision
  // datapath is the double-precision one restricted to its low bits.
  localparam int unsigned FracW = 52;  // fraction field
  localparam int unsigned MantW = 53;  // mantissa including the implicit bit
  localparam int unsigned QuotW = 56;  // MantW + 3 guard positions
  localparam int unsigned RemW = 58;  // partial remainder and its candidate
  localparam int unsigned ExpW = 15;  // signed working exponent
  localparam int unsigned LzcW = 6;  // $clog2(FracW + 1)

  localparam int unsigned MantBitsS = 24;
  localparam int unsigned MantBitsD = 53;

  // Digit counts: DivCycles = MantBits + 2, RootBits = MantBits + 3.
  localparam logic [5:0] DivStepsS = 6'd26;
  localparam logic [5:0] DivStepsD = 6'd55;
  localparam logic [5:0] SqrtStepsS = 6'd27;
  localparam logic [5:0] SqrtStepsD = 6'd56;

  localparam logic signed [ExpW-1:0] BiasS = ExpW'(127);
  localparam logic signed [ExpW-1:0] BiasD = ExpW'(1023);

  localparam logic [31:0] InfS = 32'h7F80_0000;
  localparam logic [63:0] InfD = 64'h7FF0_0000_0000_0000;

  // One state per reference stage, so the latency matches: ST_IDLE captures,
  // ST_INIT is fp_divider's init and fp_sqrt's setup, ST_SETUP is fp_divider's
  // setup and fp_sqrt's prep, ST_ITERATE runs the DivCycles divide steps or
  // RootBits root steps, ST_NORM_PREP is divide only, and ST_RESULT_REG is the
  // reference's output stage. Both operations reach ST_OUTPUT, the o_valid
  // cycle, MantBits + 12 cycles after the start.
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_UNPACK,
    ST_INIT,
    ST_SETUP,
    ST_ITERATE,
    ST_NORM_PREP,
    ST_NORM,
    ST_ROUND_SHIFT,
    ST_ROUND_PREP,
    ST_ROUND_APPLY,
    ST_RESULT_REG,
    ST_OUTPUT
  } state_e;

  // ===========================================================================
  // State
  // ===========================================================================
  state_e state_q;
  logic [5:0] steps_q;

  logic [63:0] op_a_q, op_b_q;
  logic is_sqrt_q, is_double_q;
  logic [2:0] rm_q;

  // Unpack results, registered in ST_UNPACK.
  logic [LzcW-1:0] lzc_a_q, lzc_b_q;
  logic zero_a_q, sub_a_q, inf_a_q, nan_a_q, snan_a_q;
  logic zero_b_q, sub_b_q, inf_b_q, nan_b_q, snan_b_q;

  // Datapath. Each register carries several stage values in sequence:
  //   rem_q     mantissa A / square-root radicand, then the partial remainder
  //   quo_q     quotient or root, then the mantissa to be rounded
  //   div_q     divisor / square-root radicand feed
  //   exp_q     operand A exponent, then the result exponent
  //   special_q the special-case result, then the assembled result
  logic signed [ExpW-1:0] exp_q;
  logic signed [ExpW-1:0] exp_b_q;
  logic [RemW-1:0] rem_q;
  logic [QuotW-1:0] quo_q;
  logic [MantW:0] div_q;
  logic [63:0] special_q;
  logic is_special_q, special_nv_q, special_dz_q, sign_q;
  logic guard_q, round_q, sticky_q, zero_result_q;
  logic round_up_q, inexact_q;
  riscv_pkg::fp_flags_t flags_q;

  assign o_ready  = (state_q == ST_IDLE);
  assign o_valid  = (state_q == ST_OUTPUT);
  assign o_result = special_q;
  assign o_flags  = flags_q;

  // ===========================================================================
  // Operand unpack and classify (ST_UNPACK and ST_INIT read these)
  // ===========================================================================
  logic sign_a_s, sign_b_s, sign_a_d, sign_b_d;
  logic [7:0] exp_a_s, exp_b_s;
  logic [10:0] exp_a_d, exp_b_d;
  logic [MantBitsS-1:0] mant_a_s, mant_b_s;
  logic [MantBitsD-1:0] mant_a_d, mant_b_d;
  logic zero_a_s, sub_a_s, inf_a_s, nan_a_s, snan_a_s;
  logic zero_b_s, sub_b_s, inf_b_s, nan_b_s, snan_b_s;
  logic zero_a_d, sub_a_d, inf_a_d, nan_a_d, snan_a_d;
  logic zero_b_d, sub_b_d, inf_b_d, nan_b_d, snan_b_d;
  logic [7:0] unused_exp_adj_a_s, unused_exp_adj_b_s;
  logic [10:0] unused_exp_adj_a_d, unused_exp_adj_b_d;
  logic [22:0] unused_frac_a_s, unused_frac_b_s;
  logic [51:0] unused_frac_a_d, unused_frac_b_d;

  fp_operand_unpacker #(
      .FP_WIDTH(32)
  ) u_unpack_a_s (
      .i_operand(op_a_q[31:0]),
      .o_sign(sign_a_s),
      .o_exp(exp_a_s),
      .o_exp_adj(unused_exp_adj_a_s),
      .o_frac(unused_frac_a_s),
      .o_mant(mant_a_s),
      .o_is_zero(zero_a_s),
      .o_is_subnormal(sub_a_s),
      .o_is_inf(inf_a_s),
      .o_is_nan(nan_a_s),
      .o_is_snan(snan_a_s)
  );

  fp_operand_unpacker #(
      .FP_WIDTH(64)
  ) u_unpack_a_d (
      .i_operand(op_a_q),
      .o_sign(sign_a_d),
      .o_exp(exp_a_d),
      .o_exp_adj(unused_exp_adj_a_d),
      .o_frac(unused_frac_a_d),
      .o_mant(mant_a_d),
      .o_is_zero(zero_a_d),
      .o_is_subnormal(sub_a_d),
      .o_is_inf(inf_a_d),
      .o_is_nan(nan_a_d),
      .o_is_snan(snan_a_d)
  );

  fp_operand_unpacker #(
      .FP_WIDTH(32)
  ) u_unpack_b_s (
      .i_operand(op_b_q[31:0]),
      .o_sign(sign_b_s),
      .o_exp(exp_b_s),
      .o_exp_adj(unused_exp_adj_b_s),
      .o_frac(unused_frac_b_s),
      .o_mant(mant_b_s),
      .o_is_zero(zero_b_s),
      .o_is_subnormal(sub_b_s),
      .o_is_inf(inf_b_s),
      .o_is_nan(nan_b_s),
      .o_is_snan(snan_b_s)
  );

  fp_operand_unpacker #(
      .FP_WIDTH(64)
  ) u_unpack_b_d (
      .i_operand(op_b_q),
      .o_sign(sign_b_d),
      .o_exp(exp_b_d),
      .o_exp_adj(unused_exp_adj_b_d),
      .o_frac(unused_frac_b_d),
      .o_mant(mant_b_d),
      .o_is_zero(zero_b_d),
      .o_is_subnormal(sub_b_d),
      .o_is_inf(inf_b_d),
      .o_is_nan(nan_b_d),
      .o_is_snan(snan_b_d)
  );

  logic sign_a, sign_b;
  logic [10:0] exp_a, exp_b;
  logic [MantW-1:0] mant_a_raw, mant_b_raw;

  always_comb begin
    if (is_double_q) begin
      sign_a     = sign_a_d;
      sign_b     = sign_b_d;
      exp_a      = exp_a_d;
      exp_b      = exp_b_d;
      mant_a_raw = mant_a_d;
      mant_b_raw = mant_b_d;
    end else begin
      sign_a     = sign_a_s;
      sign_b     = sign_b_s;
      exp_a      = {3'b0, exp_a_s};
      exp_b      = {3'b0, exp_b_s};
      mant_a_raw = {{(MantW - MantBitsS) {1'b0}}, mant_a_s};
      mant_b_raw = {{(MantW - MantBitsS) {1'b0}}, mant_b_s};
    end
  end

  // Leading zeros of the fraction field, per precision, as in the reference.
  logic [4:0] lzc_a_s_raw, lzc_b_s_raw;
  logic [5:0] lzc_a_d_raw, lzc_b_d_raw;
  logic unused_lzc_zero_a_s, unused_lzc_zero_b_s;
  logic unused_lzc_zero_a_d, unused_lzc_zero_b_d;

  fp_lzc #(
      .WIDTH(23)
  ) u_lzc_a_s (
      .i_value(op_a_q[22:0]),
      .o_lzc(lzc_a_s_raw),
      .o_is_zero(unused_lzc_zero_a_s)
  );

  fp_lzc #(
      .WIDTH(FracW)
  ) u_lzc_a_d (
      .i_value(op_a_q[FracW-1:0]),
      .o_lzc(lzc_a_d_raw),
      .o_is_zero(unused_lzc_zero_a_d)
  );

  fp_lzc #(
      .WIDTH(23)
  ) u_lzc_b_s (
      .i_value(op_b_q[22:0]),
      .o_lzc(lzc_b_s_raw),
      .o_is_zero(unused_lzc_zero_b_s)
  );

  fp_lzc #(
      .WIDTH(FracW)
  ) u_lzc_b_d (
      .i_value(op_b_q[FracW-1:0]),
      .o_lzc(lzc_b_d_raw),
      .o_is_zero(unused_lzc_zero_b_d)
  );

  logic [LzcW-1:0] lzc_a, lzc_b;
  assign lzc_a = is_double_q ? lzc_a_d_raw : {1'b0, lzc_a_s_raw};
  assign lzc_b = is_double_q ? lzc_b_d_raw : {1'b0, lzc_b_s_raw};

  // ===========================================================================
  // ST_INIT: subnormal normalization, exponent adjust, special cases
  // ===========================================================================
  logic [LzcW:0] sub_shift_a, sub_shift_b;
  logic [MantW-1:0] init_mant_a, init_mant_b;
  logic signed [ExpW-1:0] init_exp_a, init_exp_b;

  assign sub_shift_a = {1'b0, lzc_a_q} + {{LzcW{1'b0}}, 1'b1};
  assign sub_shift_b = {1'b0, lzc_b_q} + {{LzcW{1'b0}}, 1'b1};

  always_comb begin
    if (sub_a_q) begin
      init_mant_a = mant_a_raw << sub_shift_a;
      init_exp_a  = ExpW'(1) - $signed({{(ExpW - LzcW - 1) {1'b0}}, sub_shift_a});
    end else if (exp_a == '0) begin
      init_mant_a = '0;
      init_exp_a  = '0;
    end else begin
      init_mant_a = mant_a_raw;
      init_exp_a  = $signed({{(ExpW - 11) {1'b0}}, exp_a});
    end

    if (sub_b_q) begin
      init_mant_b = mant_b_raw << sub_shift_b;
      init_exp_b  = ExpW'(1) - $signed({{(ExpW - LzcW - 1) {1'b0}}, sub_shift_b});
    end else if (exp_b == '0) begin
      init_mant_b = '0;
      init_exp_b  = '0;
    end else begin
      init_mant_b = mant_b_raw;
      init_exp_b  = $signed({{(ExpW - 11) {1'b0}}, exp_b});
    end
  end

  // Special-case results are built at both widths and selected by precision,
  // matching each reference unit's CanonicalNan / infinity / zero patterns.
  logic init_is_special, init_special_nv, init_special_dz;
  logic [63:0] init_special_result;
  logic div_sign;

  assign div_sign = sign_a ^ sign_b;

  always_comb begin
    init_is_special     = 1'b0;
    init_special_nv     = 1'b0;
    init_special_dz     = 1'b0;
    init_special_result = '0;

    if (is_sqrt_q) begin
      if (nan_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? riscv_pkg::FpCanonicalNan64 :
            {32'b0, riscv_pkg::FpCanonicalNan};
        init_special_nv = snan_a_q;
      end else if (sign_a && !zero_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? riscv_pkg::FpCanonicalNan64 :
            {32'b0, riscv_pkg::FpCanonicalNan};
        init_special_nv = 1'b1;
      end else if (inf_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? InfD : {32'b0, InfS};
      end else if (zero_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? {sign_a, 63'b0} : {32'b0, sign_a, 31'b0};
      end
    end else begin
      if (nan_a_q || nan_b_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? riscv_pkg::FpCanonicalNan64 :
            {32'b0, riscv_pkg::FpCanonicalNan};
        init_special_nv = snan_a_q | snan_b_q;
      end else if (inf_a_q && inf_b_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? riscv_pkg::FpCanonicalNan64 :
            {32'b0, riscv_pkg::FpCanonicalNan};
        init_special_nv = 1'b1;
      end else if (zero_a_q && zero_b_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? riscv_pkg::FpCanonicalNan64 :
            {32'b0, riscv_pkg::FpCanonicalNan};
        init_special_nv = 1'b1;
      end else if (inf_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? {div_sign, InfD[62:0]} : {32'b0, div_sign, InfS[30:0]};
      end else if (inf_b_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? {div_sign, 63'b0} : {32'b0, div_sign, 31'b0};
      end else if (zero_b_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? {div_sign, InfD[62:0]} : {32'b0, div_sign, InfS[30:0]};
        init_special_dz = ~zero_a_q;
      end else if (zero_a_q) begin
        init_is_special = 1'b1;
        init_special_result = is_double_q ? {div_sign, 63'b0} : {32'b0, div_sign, 31'b0};
      end
    end
  end

  // Square-root exponent parity: an odd unbiased exponent moves one power of
  // two into the radicand so the halved exponent stays exact.
  logic signed [ExpW-1:0] exp_bias;
  logic sqrt_exp_even;
  logic signed [ExpW-1:0] sqrt_adjusted_exp;
  logic [MantW:0] sqrt_mantissa_int;

  assign exp_bias = is_double_q ? BiasD : BiasS;
  // Bit 0 of (init_exp_a - exp_bias), the reference's unbiased exponent parity.
  assign sqrt_exp_even = ~(init_exp_a[0] ^ exp_bias[0]);
  assign sqrt_adjusted_exp = sqrt_exp_even ? (init_exp_a + exp_bias) :
      (init_exp_a + exp_bias - ExpW'(1));
  assign sqrt_mantissa_int = sqrt_exp_even ? {1'b0, init_mant_a} : {init_mant_a, 1'b0};

  // ===========================================================================
  // ST_SETUP and ST_ITERATE: one restoring digit-recurrence step
  // ===========================================================================
  // The divide setup is the same step with no pre-shift: quotient bit
  // (mant_a >= mant_b) and remainder mant_a - mant_b or mant_a.
  //
  // rem_q and quo_q differ in width from the reference's registers but hold
  // the same integers, because every bit that a shift drops, here or in the
  // reference, is zero:
  //   Divide: both mantissas are normalized into [2^(MantBits-1), 2^MantBits),
  //   so mant_a < 2*mant_b and setup leaves 0 <= rem < mant_b. Each later step
  //   keeps r < d = mant_b <= 2^MantBits - 1, so the remainder never reaches
  //   bit MantBits. The quotient gains one bit in setup and one per step, so
  //   before each shift it is below 2^(DivBits-1), where DivBits = MantBits + 3
  //   is the reference's quotient width.
  //   Square root: each step keeps rem_k <= 2*root_k with root_k < 2^k, so
  //   before step k (k <= RootBits-1, at most 55) the remainder is below 2^56
  //   and {rem_q[55:0], radicand pair} drops only zeros. Only the final
  //   remainder can reach 2^56; it is only OR-reduced into the sticky bit, and
  //   RemW = 58 bits hold it.
  logic setup_step;  // divide setup: shift the remainder by zero
  logic [RemW-1:0] step_minuend, step_subtrahend;
  logic [RemW:0] step_diff;
  logic step_ge;

  assign setup_step = (state_q == ST_SETUP);

  always_comb begin
    if (is_sqrt_q) begin
      step_minuend    = {rem_q[RemW-3:0], div_q[MantW:MantW-1]};
      step_subtrahend = {quo_q, 2'b01};
    end else begin
      step_minuend = setup_step ? rem_q : {rem_q[RemW-2:0], 1'b0};
      step_subtrahend = {{(RemW - MantW - 1) {1'b0}}, div_q};
    end
  end

  assign step_diff = {1'b0, step_minuend} - {1'b0, step_subtrahend};
  assign step_ge   = ~step_diff[RemW];

  // ===========================================================================
  // ST_NORM: normalize by at most one position
  // ===========================================================================
  // fp_divider normalizes its quotient by a full leading-zero count. Outside
  // the special cases both mantissas are normalized, so mant_a/mant_b lies in
  // (1/2, 2) and the quotient in [2^(DivBits-2), 2^DivBits - 1]: the count is 0
  // or 1, the same one-bit shift fp_sqrt uses. For special cases
  // fp_result_assembler ignores the datapath, so the difference is not visible.
  logic norm_needs_shift;
  assign norm_needs_shift = is_double_q ? ~quo_q[MantBitsD+2] : ~quo_q[MantBitsS+2];

  // ===========================================================================
  // ST_ROUND_SHIFT: extract the rounding bits and apply the subnormal shift
  // ===========================================================================
  logic [MantW-1:0] rsh_mantissa_in;
  logic rsh_guard_in, rsh_round_in, rsh_sticky_in;
  logic [MantW-1:0] rsh_mantissa_out;
  logic rsh_guard_out, rsh_round_out, rsh_sticky_out;
  logic signed [ExpW-1:0] rsh_exp_out;

  // The retained mantissa is the top MantBits bits of the quotient and the
  // guard is the next bit down. As in the reference, round is the next bit and
  // sticky is the last quotient bit ORed with the remainder. The guard, round,
  // and sticky positions are the same at both precisions.
  assign rsh_mantissa_in = is_double_q ? {quo_q[QuotW-1:3]} :
      {{(MantW - MantBitsS) {1'b0}}, quo_q[MantBitsS+2:3]};
  assign rsh_guard_in = quo_q[2];
  assign rsh_round_in = quo_q[1];
  assign rsh_sticky_in = quo_q[0] | (|rem_q);

  // One fp_subnorm_shift serves both precisions: a right shift of the
  // right-justified {mantissa, guard, round, sticky} keeps the same low bits
  // and shifted-out sticky, and its clamp at 56 positions agrees with the
  // single-precision reference's clamp at 27 for every shift amount that can
  // reach it.
  fp_subnorm_shift #(
      .MANT_BITS(MantW),
      .EXP_EXT_BITS(ExpW)
  ) u_subnorm_shift (
      .i_mantissa(rsh_mantissa_in),
      .i_guard(rsh_guard_in),
      .i_round(rsh_round_in),
      .i_sticky(rsh_sticky_in),
      .i_exponent(exp_q),
      .o_mantissa(rsh_mantissa_out),
      .o_guard(rsh_guard_out),
      .o_round(rsh_round_out),
      .o_sticky(rsh_sticky_out),
      .o_exponent(rsh_exp_out)
  );

  // ===========================================================================
  // ST_ROUND_PREP: rounding decision
  // ===========================================================================
  logic rprep_round_up;
  assign rprep_round_up = riscv_pkg::fp_compute_round_up(
      rm_q, guard_q, round_q, sticky_q, quo_q[0], sign_q
  );

  // ===========================================================================
  // ST_ROUND_APPLY: assemble the result at the operation's width
  // ===========================================================================
  // exp_q is truncated to the reference's 10- or 13-bit width here, which is
  // exact: fp_subnorm_shift has turned every non-positive exponent into 0,
  // and over every operand class, the post-normalize decrement included, the
  // working exponent stays within [-1076, 3121] at double and [-151, 404] at
  // single. That is inside this 15-bit register and the reference's 13- and
  // 10-bit ones, so neither wraps.
  logic [31:0] assembled_s;
  logic [63:0] assembled_d;
  riscv_pkg::fp_flags_t flags_s, flags_d;

  fp_result_assembler #(
      .FP_WIDTH(32),
      .ExpBits(8),
      .FracBits(23),
      .MantBits(MantBitsS),
      .ExpExtBits(10)
  ) u_assemble_s (
      .i_exp_work(exp_q[9:0]),
      .i_mantissa_work(quo_q[MantBitsS-1:0]),
      .i_round_up(round_up_q),
      .i_is_inexact(inexact_q),
      .i_result_sign(sign_q),
      .i_rm(rm_q),
      .i_is_special(is_special_q),
      .i_special_result(special_q[31:0]),
      .i_special_invalid(special_nv_q),
      .i_special_div_zero(special_dz_q),
      .i_is_zero_result(zero_result_q & ~is_special_q),
      .i_zero_sign(sign_q),
      .o_result(assembled_s),
      .o_flags(flags_s)
  );

  fp_result_assembler #(
      .FP_WIDTH(64),
      .ExpBits(11),
      .FracBits(52),
      .MantBits(MantBitsD),
      .ExpExtBits(13)
  ) u_assemble_d (
      .i_exp_work(exp_q[12:0]),
      .i_mantissa_work(quo_q[MantBitsD-1:0]),
      .i_round_up(round_up_q),
      .i_is_inexact(inexact_q),
      .i_result_sign(sign_q),
      .i_rm(rm_q),
      .i_is_special(is_special_q),
      .i_special_result(special_q),
      .i_special_invalid(special_nv_q),
      .i_special_div_zero(special_dz_q),
      .i_is_zero_result(zero_result_q & ~is_special_q),
      .i_zero_sign(sign_q),
      .o_result(assembled_d),
      .o_flags(flags_d)
  );

  // ===========================================================================
  // Sequencer
  // ===========================================================================
  logic [5:0] total_steps;
  always_comb begin
    if (i_is_sqrt) total_steps = i_is_double ? SqrtStepsD : SqrtStepsS;
    else total_steps = i_is_double ? DivStepsD : DivStepsS;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q <= ST_IDLE;
    end else if (i_kill) begin
      state_q <= ST_IDLE;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (i_valid) begin
            state_q     <= ST_UNPACK;
            op_a_q      <= i_operand_a;
            op_b_q      <= i_operand_b;
            rm_q        <= i_rounding_mode;
            is_sqrt_q   <= i_is_sqrt;
            is_double_q <= i_is_double;
            steps_q     <= total_steps;
            quo_q       <= '0;
          end
        end

        ST_UNPACK: begin
          state_q  <= ST_INIT;
          lzc_a_q  <= lzc_a;
          lzc_b_q  <= lzc_b;
          zero_a_q <= is_double_q ? zero_a_d : zero_a_s;
          sub_a_q  <= is_double_q ? sub_a_d : sub_a_s;
          inf_a_q  <= is_double_q ? inf_a_d : inf_a_s;
          nan_a_q  <= is_double_q ? nan_a_d : nan_a_s;
          snan_a_q <= is_double_q ? snan_a_d : snan_a_s;
          zero_b_q <= is_double_q ? zero_b_d : zero_b_s;
          sub_b_q  <= is_double_q ? sub_b_d : sub_b_s;
          inf_b_q  <= is_double_q ? inf_b_d : inf_b_s;
          nan_b_q  <= is_double_q ? nan_b_d : nan_b_s;
          snan_b_q <= is_double_q ? snan_b_d : snan_b_s;
        end

        ST_INIT: begin
          state_q      <= ST_SETUP;
          is_special_q <= init_is_special;
          special_q    <= init_special_result;
          special_nv_q <= init_special_nv;
          special_dz_q <= init_special_dz;
          sign_q       <= is_sqrt_q ? 1'b0 : div_sign;
          if (is_sqrt_q) begin
            rem_q <= {{(RemW - MantW - 1) {1'b0}}, sqrt_mantissa_int};
            exp_q <= sqrt_adjusted_exp;
          end else begin
            rem_q   <= {{(RemW - MantW) {1'b0}}, init_mant_a};
            div_q   <= {1'b0, init_mant_b};
            exp_q   <= init_exp_a;
            exp_b_q <= init_exp_b;
          end
        end

        ST_SETUP: begin
          state_q <= ST_ITERATE;
          if (is_sqrt_q) begin
            // Left-justify the radicand so each step consumes its top two bits.
            // The reference's 2*RootBits-bit radicand has the mantissa in its
            // top MantBits+1 bits and zeros below; this register holds only
            // those bits and shifts zeros in, so it feeds the same bit pairs in
            // the same order.
            div_q <= is_double_q ? rem_q[MantW:0] : {rem_q[MantBitsS:0], 29'b0};
            rem_q <= '0;
            quo_q <= '0;
            exp_q <= exp_q >>> 1;
          end else begin
            exp_q <= exp_q - exp_b_q + exp_bias;
            quo_q <= {quo_q[QuotW-2:0], step_ge};
            rem_q <= step_ge ? step_diff[RemW-1:0] : step_minuend;
          end
        end

        ST_ITERATE: begin
          quo_q <= {quo_q[QuotW-2:0], step_ge};
          rem_q <= step_ge ? step_diff[RemW-1:0] : step_minuend;
          if (is_sqrt_q) div_q <= {div_q[MantW-2:0], 2'b00};
          if (steps_q == 6'd1) state_q <= is_sqrt_q ? ST_NORM : ST_NORM_PREP;
          steps_q <= steps_q - 6'd1;
        end

        // The divide reference spends this cycle on a leading-zero count of the
        // quotient, which here is the one-bit shift in ST_NORM (see there); the
        // state keeps the divide latency equal to the reference's.
        ST_NORM_PREP: begin
          state_q <= ST_NORM;
        end

        ST_NORM: begin
          state_q <= ST_ROUND_SHIFT;
          zero_result_q <= (quo_q == '0) && (rem_q == '0);
          if (norm_needs_shift) begin
            quo_q <= {quo_q[QuotW-2:0], 1'b0};
            exp_q <= exp_q - ExpW'(1);
          end
        end

        ST_ROUND_SHIFT: begin
          state_q <= ST_ROUND_PREP;
          quo_q <= {{(QuotW - MantW) {1'b0}}, rsh_mantissa_out};
          guard_q <= rsh_guard_out;
          round_q <= rsh_round_out;
          sticky_q <= rsh_sticky_out;
          exp_q <= rsh_exp_out;
        end

        ST_ROUND_PREP: begin
          state_q    <= ST_ROUND_APPLY;
          round_up_q <= rprep_round_up;
          inexact_q  <= guard_q | round_q | sticky_q;
        end

        ST_ROUND_APPLY: begin
          state_q   <= ST_RESULT_REG;
          special_q <= is_double_q ? assembled_d : {32'b0, assembled_s};
          flags_q   <= is_double_q ? flags_d : flags_s;
        end

        // The reference spends this cycle re-registering the assembled result.
        // special_q and flags_q already hold it, so the state only supplies the
        // delay that keeps the completion on the reference's cycle.
        ST_RESULT_REG: begin
          state_q <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          state_q <= ST_IDLE;
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

endmodule : fp_div_sqrt_iter
