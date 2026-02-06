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
  FP format conversion between single and double precision.

  Operations:
    FCVT.S.D: Convert double to single (rounded per rounding mode)
    FCVT.D.S: Convert single to double (exact)

  Latency:
    5-cycle (register inputs, pipeline conversion, output) to ease timing.
*/
module fp_convert_sd #(
    parameter int unsigned FP_WIDTH = 64
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [31:0] i_operand_s,  // Single-precision operand (unboxed)
    input logic [FP_WIDTH-1:0] i_operand_d,  // Double-precision operand
    input riscv_pkg::instr_op_e i_operation,
    input logic [2:0] i_rounding_mode,
    output logic [FP_WIDTH-1:0] o_result,
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // Simple 5-cycle handshake (capture inputs, pipeline conversion, output)
  logic                                stage1_valid;
  logic                                stage2_valid;
  logic                                stage3_valid;
  logic                                stage4_valid;
  logic                                valid_reg;
  logic                 [        31:0] op_s_reg;
  logic                 [FP_WIDTH-1:0] op_d_reg;
  riscv_pkg::instr_op_e                op_reg;
  logic                 [         2:0] rm_reg;
  riscv_pkg::instr_op_e                op_reg_s2;
  logic                 [         2:0] rm_reg_s2;
  riscv_pkg::instr_op_e                op_reg_s3;
  riscv_pkg::instr_op_e                op_reg_s4;

  logic                 [FP_WIDTH-1:0] result_reg;
  riscv_pkg::fp_flags_t                flags_reg;

  // Stage 2A pipeline registers (post-subnormal handling)
  logic                 [        23:0] mantissa_work_s2a;
  logic                                guard_work_s2a;
  logic                                round_work_s2a;
  logic                                sticky_work_s2a;
  logic signed          [         9:0] exp_work_s2a;

  // Stage 3 pipeline registers (post-rounder)
  logic                 [        31:0] round_result_s2;
  riscv_pkg::fp_flags_t                round_flags_s2;
  logic                                sign_d_s2;
  logic d_is_zero_s2, d_is_inf_s2, d_is_nan_s2, d_is_snan_s2;
  logic d_overflow_s2;
  logic d_underflow_too_small_s2;
  logic [31:0] d_overflow_result_s2;
  logic sign_s_s2;
  logic [10:0] exp_d_from_s_s2;
  logic [51:0] frac_d_from_s_s2;
  logic s_is_zero_s2, s_is_inf_s2, s_is_nan_s2, s_is_snan_s2;

  // Helper: NaN-box single into FP_WIDTH (assumes FP_WIDTH >= 32)
  function automatic [FP_WIDTH-1:0] box32(input logic [31:0] value);
    box32 = {{(FP_WIDTH - 32) {1'b1}}, value};
  endfunction

  // ======================================================================
  // Combinational conversion logic
  // ======================================================================
  logic                 [FP_WIDTH-1:0] result_comb;
  riscv_pkg::fp_flags_t                flags_comb;

  // ---------- D -> S (rounded) ----------
  logic                                sign_d;
  logic                 [        10:0] exp_d;
  logic                 [        51:0] frac_d;
  logic d_is_zero, d_is_inf, d_is_nan, d_is_snan;

  assign sign_d = op_d_reg[FP_WIDTH-1];
  assign exp_d  = op_d_reg[FP_WIDTH-2-:11];
  assign frac_d = op_d_reg[51:0];

  fp_classify_operand #(
      .EXP_BITS (11),
      .FRAC_BITS(52)
  ) u_classify_d (
      .i_exp(exp_d),
      .i_frac(frac_d),
      .o_is_zero(d_is_zero),
      .o_is_subnormal(),
      .o_is_inf(d_is_inf),
      .o_is_nan(d_is_nan),
      .o_is_snan(d_is_snan)
  );

  // Stage 1 registers for D->S conversion
  logic               sign_d_s1;
  logic signed [12:0] exp_s_biased_s1;
  logic        [24:0] mant_s_s1;
  logic               guard_s_s1;
  logic               round_s_s1;
  logic               sticky_s_s1;
  logic               d_is_zero_s1;
  logic               d_is_inf_s1;
  logic               d_is_nan_s1;
  logic               d_is_snan_s1;
  logic               d_overflow_s1;
  logic               d_underflow_too_small_s1;
  logic        [31:0] d_overflow_result_s1;

  // Normalize mantissa for D
  // TIMING: Split paths for normal vs subnormal to reduce LZC critical path depth
  logic        [52:0] mant_norm_d;
  logic signed [12:0] exp_unbiased_d;
  logic        [ 5:0] lzc_d;

  // TIMING: Register LZC result to break critical path
  logic        [ 5:0] lzc_d_reg;
  logic               d_is_subnormal_reg;
  logic        [51:0] frac_d_reg;
  logic signed [12:0] exp_s_biased_normal;  // Pre-computed for normal case

  // TIMING: Compute LZC from input operand (for registering on i_valid)
  // This breaks the critical path by computing LZC from input and registering it,
  // rather than computing it from the registered op_d_reg in the next cycle.
  logic               lzc_d_is_zero;
  fp_lzc #(
      .WIDTH(52)
  ) u_lzc_d (
      .i_value (i_operand_d[51:0]),
      .o_lzc   (lzc_d),
      .o_is_zero(lzc_d_is_zero)
  );

  // TIMING: Use registered LZC for subnormal path
  always_comb begin
    mant_norm_d = {1'b1, frac_d_reg};
    exp_unbiased_d = exp_s_biased_normal - 13'sd127;  // Use pre-computed value
    if (d_is_subnormal_reg) begin
      if (frac_d_reg != 52'b0) begin
        mant_norm_d = ({1'b0, frac_d_reg} << (lzc_d_reg + 1'b1));
        exp_unbiased_d = -13'sd1022 - $signed({7'b0, lzc_d_reg}) - 13'sd1;
      end else begin
        mant_norm_d = 53'b0;
        exp_unbiased_d = -13'sd1022;
      end
    end
  end

  logic signed [12:0] exp_s_biased;
  assign exp_s_biased = exp_unbiased_d + 13'sd127;

  logic [24:0] mant_s;
  logic        guard_s;
  logic        round_s;
  logic        sticky_s;
  assign mant_s   = mant_norm_d[52:28];
  assign guard_s  = mant_norm_d[27];
  assign round_s  = mant_norm_d[26];
  assign sticky_s = |mant_norm_d[25:0];

  // -------- D->S Rounder (pipelined) --------
  // Stage A: Subnormal handling and rounding inputs
  logic        [23:0] mantissa_retained_s1;
  logic               guard_bit_s1;
  logic               round_bit_s1;
  logic               sticky_bit_s1;
  logic signed [ 9:0] round_exp_s1;
  logic        [23:0] mantissa_work_s1_comb;
  logic               guard_work_s1_comb;
  logic               round_work_s1_comb;
  logic               sticky_work_s1_comb;
  logic signed [ 9:0] exp_work_s1_comb;

  assign mantissa_retained_s1 = mant_s_s1[24:1];
  assign guard_bit_s1 = mant_s_s1[0];
  assign round_bit_s1 = guard_s_s1;
  assign sticky_bit_s1 = round_s_s1 | sticky_s_s1;
  assign round_exp_s1 = exp_s_biased_s1[9:0];

  fp_subnorm_shift #(
      .MANT_BITS(24),
      .EXP_EXT_BITS(10)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained_s1),
      .i_guard   (guard_bit_s1),
      .i_round   (round_bit_s1),
      .i_sticky  (sticky_bit_s1),
      .i_exponent(round_exp_s1),
      .o_mantissa(mantissa_work_s1_comb),
      .o_guard   (guard_work_s1_comb),
      .o_round   (round_work_s1_comb),
      .o_sticky  (sticky_work_s1_comb),
      .o_exponent(exp_work_s1_comb)
  );

  // Stage B: Apply rounding and format result
  logic                        round_up_s2_comb;
  logic                        is_inexact_s2_comb;
  logic                 [24:0] rounded_mantissa_s2_comb;
  logic                        mantissa_overflow_s2_comb;
  logic signed          [ 9:0] adjusted_exponent_s2_comb;
  logic                 [22:0] final_mantissa_s2_comb;
  logic                        is_overflow_s2_comb;
  logic                        is_underflow_s2_comb;
  logic                 [31:0] round_result_s2_comb;
  riscv_pkg::fp_flags_t        round_flags_s2_comb;
  logic                        lsb_s2;

  assign lsb_s2 = mantissa_work_s2a[0];

  assign round_up_s2_comb = riscv_pkg::fp_compute_round_up(
      rm_reg_s2, guard_work_s2a, round_work_s2a, sticky_work_s2a, lsb_s2, sign_d_s2
  );

  assign rounded_mantissa_s2_comb = {1'b0, mantissa_work_s2a} + {{24{1'b0}}, round_up_s2_comb};
  assign mantissa_overflow_s2_comb = rounded_mantissa_s2_comb[24];

  always_comb begin
    if (mantissa_overflow_s2_comb) begin
      if (exp_work_s2a == 10'sd0) adjusted_exponent_s2_comb = 10'sd1;
      else adjusted_exponent_s2_comb = exp_work_s2a + 10'sd1;
      final_mantissa_s2_comb = rounded_mantissa_s2_comb[23:1];
    end else begin
      adjusted_exponent_s2_comb = exp_work_s2a;
      final_mantissa_s2_comb = rounded_mantissa_s2_comb[22:0];
    end
  end

  assign is_overflow_s2_comb  = (adjusted_exponent_s2_comb >= 10'sd255);
  assign is_underflow_s2_comb = (adjusted_exponent_s2_comb <= 10'sd0);
  assign is_inexact_s2_comb   = guard_work_s2a | round_work_s2a | sticky_work_s2a;

  always_comb begin
    round_result_s2_comb = 32'b0;
    round_flags_s2_comb  = '0;

    if (is_overflow_s2_comb) begin
      round_flags_s2_comb.of = 1'b1;
      round_flags_s2_comb.nx = 1'b1;
      if ((rm_reg_s2 == riscv_pkg::FRM_RTZ) ||
          (rm_reg_s2 == riscv_pkg::FRM_RDN && !sign_d_s2) ||
          (rm_reg_s2 == riscv_pkg::FRM_RUP && sign_d_s2)) begin
        round_result_s2_comb = {sign_d_s2, 8'hFE, 23'h7FFFFF};
      end else begin
        round_result_s2_comb = {sign_d_s2, 8'hFF, 23'b0};
      end
    end else if (is_underflow_s2_comb) begin
      round_flags_s2_comb.uf = is_inexact_s2_comb;
      round_flags_s2_comb.nx = is_inexact_s2_comb;
      round_result_s2_comb   = {sign_d_s2, 8'b0, final_mantissa_s2_comb};
    end else begin
      round_flags_s2_comb.nx = is_inexact_s2_comb;
      round_result_s2_comb   = {sign_d_s2, adjusted_exponent_s2_comb[7:0], final_mantissa_s2_comb};
    end
  end

  // Overflow/underflow handling for D->S
  logic d_overflow;
  logic d_underflow_too_small;
  assign d_overflow = (exp_s_biased >= 13'sd255);
  assign d_underflow_too_small = (exp_s_biased <= -13'sd26);

  logic [31:0] d_overflow_result;
  logic d_overflow_to_max;
  always_comb begin
    d_overflow_to_max = (rm_reg == riscv_pkg::FRM_RTZ) ||
                        (rm_reg == riscv_pkg::FRM_RDN && !sign_d) ||
                        (rm_reg == riscv_pkg::FRM_RUP && sign_d);
    if (d_overflow_to_max) d_overflow_result = {sign_d, 8'hFE, 23'h7FFFFF};
    else d_overflow_result = {sign_d, 8'hFF, 23'b0};
  end

  logic [FP_WIDTH-1:0] d2s_result_s3;
  riscv_pkg::fp_flags_t d2s_flags_s3;

  always_comb begin
    d2s_result_s3 = '0;
    d2s_flags_s3  = '0;
    if (d_is_nan_s2) begin
      d2s_result_s3   = box32(riscv_pkg::FpCanonicalNan);
      d2s_flags_s3.nv = d_is_snan_s2;
    end else if (d_is_inf_s2) begin
      d2s_result_s3 = box32({sign_d_s2, 8'hFF, 23'b0});
    end else if (d_is_zero_s2) begin
      d2s_result_s3 = box32({sign_d_s2, 31'b0});
    end else if (d_overflow_s2) begin
      d2s_result_s3   = box32(d_overflow_result_s2);
      d2s_flags_s3.of = 1'b1;
      d2s_flags_s3.nx = 1'b1;
    end else if (d_underflow_too_small_s2) begin
      d2s_result_s3   = box32({sign_d_s2, 31'b0});
      d2s_flags_s3.uf = 1'b1;
      d2s_flags_s3.nx = 1'b1;
    end else begin
      d2s_result_s3 = box32(round_result_s2);
      d2s_flags_s3  = round_flags_s2;
    end
  end

  // ---------- S -> D (exact) ----------
  logic        sign_s;
  logic [ 7:0] exp_s;
  logic [22:0] frac_s;
  logic s_is_zero, s_is_inf, s_is_nan, s_is_snan;

  assign sign_s = op_s_reg[31];
  assign exp_s  = op_s_reg[30:23];
  assign frac_s = op_s_reg[22:0];

  fp_classify_operand #(
      .EXP_BITS (8),
      .FRAC_BITS(23)
  ) u_classify_s (
      .i_exp(exp_s),
      .i_frac(frac_s),
      .o_is_zero(s_is_zero),
      .o_is_subnormal(),
      .o_is_inf(s_is_inf),
      .o_is_nan(s_is_nan),
      .o_is_snan(s_is_snan)
  );

  // Stage 1 registers for S->D conversion
  logic               sign_s_s1;
  logic        [10:0] exp_d_from_s_s1;
  logic        [51:0] frac_d_from_s_s1;
  logic               s_is_zero_s1;
  logic               s_is_inf_s1;
  logic               s_is_nan_s1;
  logic               s_is_snan_s1;

  logic        [23:0] mant_norm_s;
  logic signed [11:0] exp_unbiased_s;
  logic        [ 4:0] lzc_s;

  logic               lzc_s_is_zero;
  fp_lzc #(
      .WIDTH(23)
  ) u_lzc_s (
      .i_value (frac_s),
      .o_lzc   (lzc_s),
      .o_is_zero(lzc_s_is_zero)
  );

  always_comb begin
    mant_norm_s = {1'b1, frac_s};
    exp_unbiased_s = $signed({4'b0, exp_s}) - 12'sd127;
    if (exp_s == 8'b0) begin
      if (frac_s != 23'b0) begin
        mant_norm_s = ({1'b0, frac_s} << (lzc_s + 1'b1));
        exp_unbiased_s = -12'sd126 - $signed({6'b0, lzc_s}) - 12'sd1;
      end else begin
        mant_norm_s = 24'b0;
        exp_unbiased_s = -12'sd126;
      end
    end
  end

  logic [10:0] exp_d_from_s;
  logic [51:0] frac_d_from_s;
  assign exp_d_from_s  = 11'(exp_unbiased_s + 12'sd1023);
  assign frac_d_from_s = {mant_norm_s[22:0], {52 - 23{1'b0}}};

  logic [FP_WIDTH-1:0] s2d_result_s3;
  riscv_pkg::fp_flags_t s2d_flags_s3;

  always_comb begin
    s2d_result_s3 = '0;
    s2d_flags_s3  = '0;
    if (s_is_nan_s2) begin
      s2d_result_s3   = riscv_pkg::FpCanonicalNan64;
      s2d_flags_s3.nv = s_is_snan_s2;
    end else if (s_is_inf_s2) begin
      s2d_result_s3 = {sign_s_s2, 11'h7FF, 52'b0};
    end else if (s_is_zero_s2) begin
      s2d_result_s3 = {sign_s_s2, 63'b0};
    end else begin
      s2d_result_s3 = {sign_s_s2, exp_d_from_s_s2, frac_d_from_s_s2};
    end
  end

  // ---------- Result mux ----------
  always_comb begin
    result_comb = '0;
    flags_comb  = '0;
    unique case (op_reg_s4)
      riscv_pkg::FCVT_S_D: begin
        result_comb = d2s_result_s3;
        flags_comb  = d2s_flags_s3;
      end
      riscv_pkg::FCVT_D_S: begin
        result_comb = s2d_result_s3;
        flags_comb  = s2d_flags_s3;
      end
      default: begin
        result_comb = '0;
        flags_comb  = '0;
      end
    endcase
  end

  // ======================================================================
  // Register outputs (4-cycle latency)
  // ======================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      stage1_valid <= 1'b0;
      stage2_valid <= 1'b0;
      stage3_valid <= 1'b0;
      stage4_valid <= 1'b0;
      valid_reg <= 1'b0;
      op_s_reg <= 32'b0;
      op_d_reg <= '0;
      op_reg <= riscv_pkg::instr_op_e'(0);
      rm_reg <= 3'b0;
      // TIMING: LZC pipeline registers
      lzc_d_reg <= '0;
      d_is_subnormal_reg <= 1'b0;
      frac_d_reg <= '0;
      exp_s_biased_normal <= '0;
      op_reg_s2 <= riscv_pkg::instr_op_e'(0);
      rm_reg_s2 <= 3'b0;
      op_reg_s3 <= riscv_pkg::instr_op_e'(0);
      op_reg_s4 <= riscv_pkg::instr_op_e'(0);
      sign_d_s1 <= 1'b0;
      exp_s_biased_s1 <= '0;
      mant_s_s1 <= '0;
      guard_s_s1 <= 1'b0;
      round_s_s1 <= 1'b0;
      sticky_s_s1 <= 1'b0;
      d_is_zero_s1 <= 1'b0;
      d_is_inf_s1 <= 1'b0;
      d_is_nan_s1 <= 1'b0;
      d_is_snan_s1 <= 1'b0;
      d_overflow_s1 <= 1'b0;
      d_underflow_too_small_s1 <= 1'b0;
      d_overflow_result_s1 <= '0;
      sign_s_s1 <= 1'b0;
      exp_d_from_s_s1 <= '0;
      frac_d_from_s_s1 <= '0;
      s_is_zero_s1 <= 1'b0;
      s_is_inf_s1 <= 1'b0;
      s_is_nan_s1 <= 1'b0;
      s_is_snan_s1 <= 1'b0;
      result_reg <= '0;
      flags_reg <= '0;
      mantissa_work_s2a <= '0;
      guard_work_s2a <= 1'b0;
      round_work_s2a <= 1'b0;
      sticky_work_s2a <= 1'b0;
      exp_work_s2a <= '0;
      round_result_s2 <= '0;
      round_flags_s2 <= '0;
      sign_d_s2 <= 1'b0;
      d_is_zero_s2 <= 1'b0;
      d_is_inf_s2 <= 1'b0;
      d_is_nan_s2 <= 1'b0;
      d_is_snan_s2 <= 1'b0;
      d_overflow_s2 <= 1'b0;
      d_underflow_too_small_s2 <= 1'b0;
      d_overflow_result_s2 <= '0;
      sign_s_s2 <= 1'b0;
      exp_d_from_s_s2 <= '0;
      frac_d_from_s_s2 <= '0;
      s_is_zero_s2 <= 1'b0;
      s_is_inf_s2 <= 1'b0;
      s_is_nan_s2 <= 1'b0;
      s_is_snan_s2 <= 1'b0;
    end else begin
      valid_reg <= 1'b0;
      if (stage4_valid) begin
        result_reg <= result_comb;
        flags_reg <= flags_comb;
        valid_reg <= 1'b1;
        stage4_valid <= 1'b0;
      end else if (stage3_valid) begin
        round_result_s2 <= round_result_s2_comb;
        round_flags_s2 <= round_flags_s2_comb;
        op_reg_s4 <= op_reg_s3;
        stage4_valid <= 1'b1;
        stage3_valid <= 1'b0;
      end else if (stage2_valid) begin
        mantissa_work_s2a <= mantissa_work_s1_comb;
        guard_work_s2a <= guard_work_s1_comb;
        round_work_s2a <= round_work_s1_comb;
        sticky_work_s2a <= sticky_work_s1_comb;
        exp_work_s2a <= exp_work_s1_comb;
        sign_d_s2 <= sign_d_s1;
        d_is_zero_s2 <= d_is_zero_s1;
        d_is_inf_s2 <= d_is_inf_s1;
        d_is_nan_s2 <= d_is_nan_s1;
        d_is_snan_s2 <= d_is_snan_s1;
        d_overflow_s2 <= d_overflow_s1;
        d_underflow_too_small_s2 <= d_underflow_too_small_s1;
        d_overflow_result_s2 <= d_overflow_result_s1;
        sign_s_s2 <= sign_s_s1;
        exp_d_from_s_s2 <= exp_d_from_s_s1;
        frac_d_from_s_s2 <= frac_d_from_s_s1;
        s_is_zero_s2 <= s_is_zero_s1;
        s_is_inf_s2 <= s_is_inf_s1;
        s_is_nan_s2 <= s_is_nan_s1;
        s_is_snan_s2 <= s_is_snan_s1;
        op_reg_s3 <= op_reg_s2;
        stage3_valid <= 1'b1;
        stage2_valid <= 1'b0;
      end else if (stage1_valid) begin
        sign_d_s1 <= sign_d;
        exp_s_biased_s1 <= exp_s_biased;
        mant_s_s1 <= mant_s;
        guard_s_s1 <= guard_s;
        round_s_s1 <= round_s;
        sticky_s_s1 <= sticky_s;
        d_is_zero_s1 <= d_is_zero;
        d_is_inf_s1 <= d_is_inf;
        d_is_nan_s1 <= d_is_nan;
        d_is_snan_s1 <= d_is_snan;
        d_overflow_s1 <= d_overflow;
        d_underflow_too_small_s1 <= d_underflow_too_small;
        d_overflow_result_s1 <= d_overflow_result;
        sign_s_s1 <= sign_s;
        exp_d_from_s_s1 <= exp_d_from_s;
        frac_d_from_s_s1 <= frac_d_from_s;
        s_is_zero_s1 <= s_is_zero;
        s_is_inf_s1 <= s_is_inf;
        s_is_nan_s1 <= s_is_nan;
        s_is_snan_s1 <= s_is_snan;
        op_reg_s2 <= op_reg;
        rm_reg_s2 <= rm_reg;
        stage2_valid <= 1'b1;
        stage1_valid <= 1'b0;
      end else if (i_valid) begin
        op_s_reg <= i_operand_s;
        op_d_reg <= i_operand_d;
        op_reg <= i_operation;
        rm_reg <= i_rounding_mode;
        stage1_valid <= 1'b1;
        // TIMING: Pre-compute and register LZC and related values from input
        // to break the critical path from op_d_reg to sticky_s
        frac_d_reg <= i_operand_d[51:0];
        d_is_subnormal_reg <= (i_operand_d[62:52] == 11'b0) && (i_operand_d[51:0] != 52'b0);
        exp_s_biased_normal <= $signed({2'b0, i_operand_d[62:52]}) - 13'sd1023 + 13'sd127;
        // Register LZC computed from input operand
        lzc_d_reg <= lzc_d;
      end
    end
  end

  assign o_valid  = valid_reg;
  assign o_result = result_reg;
  assign o_flags  = flags_reg;

endmodule : fp_convert_sd
