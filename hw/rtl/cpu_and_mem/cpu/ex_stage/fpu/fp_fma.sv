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
  IEEE 754 single-precision fused multiply-add.

  This implementation computes (a * b) + c with a single rounding step.
  It handles NaNs, infinities, zeros, and subnormal operands.

  Operations:
    FMADD.S:  fd = (fs1 * fs2) + fs3
    FMSUB.S:  fd = (fs1 * fs2) - fs3
    FNMADD.S: fd = -(fs1 * fs2) - fs3
    FNMSUB.S: fd = -(fs1 * fs2) + fs3

  Multi-cycle implementation (23-cycle latency, non-pipelined, deep post-multiply pipeline):
    Cycle 0: Capture operands
    Cycle 1: Unpack operands, detect special cases
    Cycle 2: Multiply mantissas (24x24 -> 48 bits)
    Cycle 2B: TIMING: 10-stage pipeline after DSP multiply
    Cycle 3A: Product LZC computation
    Cycle 3B: Normalize product (apply shift)
    Cycle 4: Align exponent/shift amount prep
    Cycle 5: Align product and addend (barrel shift)
    Cycle 6A: Add/subtract
    Cycle 6B: LZC
    Cycle 7: Normalize based on LZC
    Cycle 8A: Subnormal handling, compute rounding inputs
    Cycle 8B: Compute round-up decision
    Cycle 9: Apply rounding increment, format result
    Cycle 10: Output registered result
*/
module fp_fma #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_valid,
    input  logic                 [FP_WIDTH-1:0] i_operand_a,
    input  logic                 [FP_WIDTH-1:0] i_operand_b,
    input  logic                 [FP_WIDTH-1:0] i_operand_c,
    input  logic                                i_negate_product,
    input  logic                                i_negate_c,
    input  logic                 [         2:0] i_rounding_mode,
    input  logic                                i_stall,
    output logic                 [FP_WIDTH-1:0] o_result,
    output logic                                o_valid,
    output riscv_pkg::fp_flags_t                o_flags
);

  typedef enum logic [4:0] {
    IDLE    = 5'b00000,
    STAGE1  = 5'b00001,
    STAGE2  = 5'b00010,
    STAGE2B = 5'b10000,  // TIMING: Post-multiply pipeline shift (MulPipeStages deep)
    STAGE3A = 5'b00011,
    STAGE3B = 5'b00100,
    STAGE4  = 5'b00101,
    STAGE4B = 5'b00110,
    STAGE5A = 5'b00111,
    STAGE5B = 5'b01000,
    STAGE6  = 5'b01001,
    STAGE7A = 5'b01010,
    STAGE7B = 5'b01011,
    STAGE8  = 5'b01100,
    STAGE9  = 5'b01101
  } state_e;

  state_e state, next_state;

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned ProdBits = MantBits * 2;
  localparam int unsigned SumBits = ProdBits + 1;
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcProdBits = $clog2(ProdBits + 1);
  localparam int unsigned LzcSumBits = $clog2(SumBits + 1);
  localparam int unsigned ShiftBits = $clog2(ProdBits + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  // Post-multiply pipeline depth (Vivado recommends 10 stages for wide multiplier).
  localparam int unsigned MulPipeStages = 10;

  // Input registers
  logic [FP_WIDTH-1:0] operand_a_reg;
  logic [FP_WIDTH-1:0] operand_b_reg;
  logic [FP_WIDTH-1:0] operand_c_reg;
  logic                negate_product_reg;
  logic                negate_c_reg;
  logic [         2:0] rm_reg;

  // =========================================================================
  // Stage 1: Unpack operands (combinational from registered inputs)
  // =========================================================================

  logic sign_a, sign_b, sign_c;
  logic [ExpBits-1:0] exp_a, exp_b, exp_c;
  logic [FracBits-1:0] mant_a, mant_b, mant_c;
  logic is_zero_a, is_zero_b, is_zero_c;
  logic is_inf_a, is_inf_b, is_inf_c;
  logic is_nan_a, is_nan_b, is_nan_c;
  logic is_snan_a, is_snan_b, is_snan_c;
  logic [ExpBits-1:0] exp_a_adj, exp_b_adj, exp_c_adj;
  logic [MantBits-1:0] mant_a_int, mant_b_int, mant_c_int;
  logic is_subnormal_a, is_subnormal_b, is_subnormal_c;

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_a (
      .i_operand(operand_a_reg),
      .o_sign(sign_a),
      .o_exp(exp_a),
      .o_exp_adj(exp_a_adj),
      .o_frac(mant_a),
      .o_mant(mant_a_int),
      .o_is_zero(is_zero_a),
      .o_is_subnormal(is_subnormal_a),
      .o_is_inf(is_inf_a),
      .o_is_nan(is_nan_a),
      .o_is_snan(is_snan_a)
  );
  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_b (
      .i_operand(operand_b_reg),
      .o_sign(sign_b),
      .o_exp(exp_b),
      .o_exp_adj(exp_b_adj),
      .o_frac(mant_b),
      .o_mant(mant_b_int),
      .o_is_zero(is_zero_b),
      .o_is_subnormal(is_subnormal_b),
      .o_is_inf(is_inf_b),
      .o_is_nan(is_nan_b),
      .o_is_snan(is_snan_b)
  );
  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_c (
      .i_operand(operand_c_reg),
      .o_sign(sign_c),
      .o_exp(exp_c),
      .o_exp_adj(exp_c_adj),
      .o_frac(mant_c),
      .o_mant(mant_c_int),
      .o_is_zero(is_zero_c),
      .o_is_subnormal(is_subnormal_c),
      .o_is_inf(is_inf_c),
      .o_is_nan(is_nan_c),
      .o_is_snan(is_snan_c)
  );

  // Sign control for FMA variants
  logic sign_prod;
  logic sign_c_adj;
  assign sign_prod  = sign_a ^ sign_b ^ negate_product_reg;
  assign sign_c_adj = sign_c ^ negate_c_reg;

  // Special case detection
  logic                is_special;
  logic [FP_WIDTH-1:0] special_result;
  logic                special_invalid;

  always_comb begin
    is_special = 1'b0;
    special_result = '0;
    special_invalid = 1'b0;

    if (is_nan_a || is_nan_b || is_nan_c) begin
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = is_snan_a | is_snan_b | is_snan_c;
    end else if ((is_inf_a && is_zero_b) || (is_zero_a && is_inf_b)) begin
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf_a || is_inf_b) begin
      if (is_inf_c && (sign_c_adj != sign_prod)) begin
        is_special = 1'b1;
        special_result = CanonicalNan;
        special_invalid = 1'b1;
      end else begin
        is_special = 1'b1;
        special_result = {sign_prod, ExpMax, {FracBits{1'b0}}};
      end
    end else if (is_inf_c) begin
      is_special = 1'b1;
      special_result = {sign_c_adj, ExpMax, {FracBits{1'b0}}};
    end
  end

  // Product exponent
  logic signed [ExpExtBits-1:0] prod_exp_tentative;
  assign prod_exp_tentative = $signed(
      {{(ExpExtBits - ExpBits) {1'b0}}, exp_a_adj}
  ) + $signed(
      {{(ExpExtBits - ExpBits) {1'b0}}, exp_b_adj}
  ) - ExpExtBits'(ExpBias);

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Registers (after unpack, before multiply)
  // =========================================================================

  logic [MantBits-1:0] mant_a_s2, mant_b_s2;
  logic signed [ExpExtBits-1:0] prod_exp_s2;
  logic                         prod_sign_s2;
  logic signed [ExpExtBits-1:0] c_exp_s2;
  logic        [  MantBits-1:0] mant_c_s2;
  logic                         c_sign_s2;
  logic        [           2:0] rm_s2;
  logic                         is_special_s2;
  logic        [  FP_WIDTH-1:0] special_result_s2;
  logic                         special_invalid_s2;

  // =========================================================================
  // Stage 2: Multiply (combinational 24x24 from stage 2 regs)
  // Use DSP48 blocks to reduce LUT congestion
  // =========================================================================

  (* use_dsp = "yes" *)
  logic        [  ProdBits-1:0] prod_mant_s2_comb;
  assign prod_mant_s2_comb = mant_a_s2 * mant_b_s2;

  // =========================================================================
  // Post-Multiply Product Pipeline (TIMING: break DSP critical path)
  // =========================================================================
  // Deep pipeline after DSP multiply to satisfy timing (MulPipeStages stages).

  (* srl_style = "srl_reg" *)logic        [     ProdBits-1:0] prod_pipe          [MulPipeStages];
  logic        [MulPipeStages-1:0] prod_valid_pipe;

  // =========================================================================
  // Stage 2B -> Stage 3 Pipeline Registers (after DSP pipeline, before LZC)
  // =========================================================================

  logic        [     ProdBits-1:0] prod_mant_s3;
  logic signed [   ExpExtBits-1:0] prod_exp_s3;
  logic                            prod_sign_s3;
  logic signed [   ExpExtBits-1:0] c_exp_s3;
  logic        [     MantBits-1:0] mant_c_s3;
  logic                            c_sign_s3;
  logic        [              2:0] rm_s3;
  logic                            is_special_s3;
  logic        [     FP_WIDTH-1:0] special_result_s3;
  logic                            special_invalid_s3;

  // =========================================================================
  // Stage 3A: Product LZC (combinational from stage 3 regs)
  // =========================================================================

  logic        [  LzcProdBits-1:0] prod_lzc;
  logic                            prod_is_zero;
  logic                            prod_msb_set;

  assign prod_is_zero = (prod_mant_s3 == '0);
  assign prod_msb_set = prod_mant_s3[ProdBits-1];

  // LZC on bits [ProdBits-2:0] (MSB checked separately)
  logic prod_lzc_is_zero;
  fp_lzc #(
      .WIDTH(ProdBits - 1)
  ) u_prod_lzc (
      .i_value (prod_mant_s3[ProdBits-2:0]),
      .o_lzc   (prod_lzc),
      .o_is_zero(prod_lzc_is_zero)
  );

  // =========================================================================
  // Stage 3A -> Stage 3B Pipeline Registers (after LZC, before shift)
  // =========================================================================

  logic        [   ProdBits-1:0] prod_mant_s3b;
  logic signed [ ExpExtBits-1:0] prod_exp_s3b;
  logic                          prod_sign_s3b;
  logic                          prod_is_zero_s3b;
  logic                          prod_msb_set_s3b;
  logic        [LzcProdBits-1:0] prod_lzc_s3b;
  logic signed [ ExpExtBits-1:0] c_exp_s3b;
  logic        [   MantBits-1:0] mant_c_s3b;
  logic                          c_sign_s3b;
  logic        [            2:0] rm_s3b;
  logic                          is_special_s3b;
  logic        [   FP_WIDTH-1:0] special_result_s3b;
  logic                          special_invalid_s3b;

  // =========================================================================
  // Stage 3B: Apply Normalization Shift (combinational from stage 3B regs)
  // =========================================================================

  logic signed [ ExpExtBits-1:0] prod_exp_norm;
  logic        [   ProdBits-1:0] prod_mant_norm;

  always_comb begin
    if (prod_is_zero_s3b) begin
      prod_mant_norm = '0;
      prod_exp_norm  = '0;
    end else if (prod_msb_set_s3b) begin
      prod_mant_norm = prod_mant_s3b;
      prod_exp_norm  = prod_exp_s3b + 1;
    end else begin
      prod_mant_norm = prod_mant_s3b << (prod_lzc_s3b + 1'b1);
      prod_exp_norm  = prod_exp_s3b - $signed({{(ExpExtBits - LzcProdBits) {1'b0}}, prod_lzc_s3b});
    end
  end

  // =========================================================================
  // Stage 3B -> Stage 4 Pipeline Registers (after prod norm, before align)
  // =========================================================================

  logic signed [ExpExtBits-1:0] prod_exp_s4;
  logic        [  ProdBits-1:0] prod_mant_s4;
  logic                         prod_sign_s4;
  logic signed [ExpExtBits-1:0] c_exp_s4;
  logic        [  ProdBits-1:0] c_mant_s4;
  logic                         c_sign_s4;
  logic        [           2:0] rm_s4;
  logic                         is_special_s4;
  logic        [  FP_WIDTH-1:0] special_result_s4;
  logic                         special_invalid_s4;

  // =========================================================================
  // Stage 4: Align prep (exponent compare + shift amount)
  // =========================================================================

  logic signed [ExpExtBits-1:0] exp_large;
  logic        [ ShiftBits-1:0] shift_prod_amt;
  logic        [ ShiftBits-1:0] shift_c_amt;
  logic signed [  ExpExtBits:0] shift_prod_signed;
  logic signed [  ExpExtBits:0] shift_c_signed;
  localparam logic signed [ExpExtBits:0] ProdBitsSigned = {1'b0, ExpExtBits'(ProdBits)};

  always_comb begin
    exp_large = (prod_exp_s4 >= c_exp_s4) ? prod_exp_s4 : c_exp_s4;

    shift_prod_signed = $signed({exp_large[ExpExtBits-1], exp_large}) -
        $signed({prod_exp_s4[ExpExtBits-1], prod_exp_s4});
    shift_c_signed = $signed({exp_large[ExpExtBits-1], exp_large}) -
        $signed({c_exp_s4[ExpExtBits-1], c_exp_s4});

    if (shift_prod_signed < 0) shift_prod_amt = '0;
    else if (shift_prod_signed >= ProdBitsSigned) shift_prod_amt = ShiftBits'(ProdBits);
    else shift_prod_amt = shift_prod_signed[ShiftBits-1:0];

    if (shift_c_signed < 0) shift_c_amt = '0;
    else if (shift_c_signed >= ProdBitsSigned) shift_c_amt = ShiftBits'(ProdBits);
    else shift_c_amt = shift_c_signed[ShiftBits-1:0];
  end

  // =========================================================================
  // Stage 4 -> Stage 4b Pipeline Registers (after shift amount calc)
  // =========================================================================

  logic signed [ExpExtBits-1:0] exp_large_s4b;
  logic        [ ShiftBits-1:0] shift_prod_amt_s4b;
  logic        [ ShiftBits-1:0] shift_c_amt_s4b;

  // =========================================================================
  // Stage 4b: Align (barrel shift - combinational from stage 4 regs)
  // =========================================================================

  logic        [  ProdBits-1:0] prod_aligned;
  logic        [  ProdBits-1:0] c_aligned;
  logic                         sticky_prod;
  logic                         sticky_c;

  always_comb begin
    prod_aligned = prod_mant_s4;
    sticky_prod  = 1'b0;
    if (shift_prod_amt_s4b >= ShiftBits'(ProdBits)) begin
      prod_aligned = '0;
      sticky_prod  = |prod_mant_s4;
    end else if (shift_prod_amt_s4b != 0) begin
      prod_aligned = prod_mant_s4 >> shift_prod_amt_s4b;
      sticky_prod  = 1'b0;
      for (int i = 0; i < ProdBits; i++) begin
        if (i < shift_prod_amt_s4b) sticky_prod = sticky_prod | prod_mant_s4[i];
      end
    end

    c_aligned = c_mant_s4;
    sticky_c  = 1'b0;
    if (shift_c_amt_s4b >= ShiftBits'(ProdBits)) begin
      c_aligned = '0;
      sticky_c  = |c_mant_s4;
    end else if (shift_c_amt_s4b != 0) begin
      c_aligned = c_mant_s4 >> shift_c_amt_s4b;
      sticky_c  = 1'b0;
      for (int i = 0; i < ProdBits; i++) begin
        if (i < shift_c_amt_s4b) sticky_c = sticky_c | c_mant_s4[i];
      end
    end
  end

  // =========================================================================
  // Stage 4b -> Stage 5 Pipeline Registers (after align, before add)
  // =========================================================================

  logic signed [ExpExtBits-1:0] exp_large_s5;
  logic [ProdBits-1:0] prod_aligned_s5;
  logic [ProdBits-1:0] c_aligned_s5;
  logic prod_sign_s5;
  logic c_sign_s5;
  logic sticky_s5;
  logic sticky_c_sub_s5;  // Sticky from smaller operand shifted out during subtraction
  logic [2:0] rm_s5;
  logic is_special_s5;
  logic [FP_WIDTH-1:0] special_result_s5;
  logic special_invalid_s5;

  // =========================================================================
  // Stage 5A: Add/Subtract (combinational from stage 5 regs)
  // =========================================================================

  logic [SumBits-1:0] sum_s5a_comb;
  logic result_sign_s5a_comb;
  logic sign_large_s5a_comb;
  logic sign_small_s5a_comb;
  logic sum_is_zero_s5a_comb;

  always_comb begin
    if (prod_sign_s5 == c_sign_s5) begin
      sum_s5a_comb = {1'b0, prod_aligned_s5} + {1'b0, c_aligned_s5};
      result_sign_s5a_comb = prod_sign_s5;
      sign_large_s5a_comb = prod_sign_s5;
      sign_small_s5a_comb = c_sign_s5;
    end else begin
      if (prod_aligned_s5 > c_aligned_s5) begin
        sum_s5a_comb = {1'b0, prod_aligned_s5} - {1'b0, c_aligned_s5};
        result_sign_s5a_comb = prod_sign_s5;
        sign_large_s5a_comb = prod_sign_s5;
        sign_small_s5a_comb = c_sign_s5;
      end else if (c_aligned_s5 > prod_aligned_s5) begin
        sum_s5a_comb = {1'b0, c_aligned_s5} - {1'b0, prod_aligned_s5};
        result_sign_s5a_comb = c_sign_s5;
        sign_large_s5a_comb = c_sign_s5;
        sign_small_s5a_comb = prod_sign_s5;
      end else begin
        sum_s5a_comb = '0;
        result_sign_s5a_comb = prod_sign_s5;
        sign_large_s5a_comb = prod_sign_s5;
        sign_small_s5a_comb = c_sign_s5;
      end
    end
    sum_is_zero_s5a_comb = (sum_s5a_comb == '0);
  end

  // =========================================================================
  // Stage 5A -> Stage 5B Pipeline Register (after add/sub)
  // =========================================================================

  logic [SumBits-1:0] sum_s5a;
  logic result_sign_s5a;
  logic sign_large_s5a;
  logic sign_small_s5a;
  logic sum_is_zero_s5a;

  // =========================================================================
  // Stage 5B: LZC (combinational from stage 5A regs)
  // =========================================================================

  logic [LzcSumBits-1:0] lzc_s5b_comb;
  logic lzc_sum_is_zero;

  // LZC on bits [SumBits-2:0] (MSB checked separately in normalize stage)
  fp_lzc #(
      .WIDTH(SumBits - 1)
  ) u_sum_lzc (
      .i_value (sum_s5a[SumBits-2:0]),
      .o_lzc   (lzc_s5b_comb),
      .o_is_zero(lzc_sum_is_zero)
  );

  // =========================================================================
  // Stage 5B -> Stage 6 Pipeline Registers (after add/LZC, before normalize)
  // =========================================================================

  logic signed [ExpExtBits-1:0] exp_large_s6;
  logic [SumBits-1:0] sum_s6;
  logic sum_is_zero_s6;
  logic [LzcSumBits-1:0] lzc_s6;
  logic sum_sticky_s6;
  logic sticky_c_sub_s6;  // Sticky from addend shifted out during subtraction
  logic result_sign_s6;
  logic sign_large_s6;
  logic sign_small_s6;
  logic [2:0] rm_s6;
  logic is_special_s6;
  logic [FP_WIDTH-1:0] special_result_s6;
  logic special_invalid_s6;

  // =========================================================================
  // Stage 6: Normalize (combinational from stage 6 regs)
  // =========================================================================

  logic [LzcSumBits-1:0] norm_shift;
  logic [SumBits-1:0] normalized_sum_s6_comb;
  logic signed [ExpExtBits-1:0] normalized_exp_s6_comb;
  logic norm_sticky_s6_comb;  // Sticky bit from normalization right-shift

  assign norm_shift = lzc_s6;

  always_comb begin
    norm_sticky_s6_comb = 1'b0;
    if (sum_is_zero_s6) begin
      normalized_sum_s6_comb = '0;
      normalized_exp_s6_comb = '0;
    end else if (sum_s6[SumBits-1]) begin
      normalized_sum_s6_comb = sum_s6 >> 1;
      normalized_exp_s6_comb = exp_large_s6 + 1;
      // Capture the bit shifted out - it contributes to sticky for rounding
      norm_sticky_s6_comb = sum_s6[0];
    end else if (lzc_s6 > 0) begin
      normalized_sum_s6_comb = sum_s6 << norm_shift;
      normalized_exp_s6_comb = exp_large_s6 -
          $signed({{(ExpExtBits - LzcSumBits) {1'b0}}, norm_shift});
    end else begin
      normalized_sum_s6_comb = sum_s6;
      normalized_exp_s6_comb = exp_large_s6;
    end
  end

  // =========================================================================
  // Stage 6 -> Stage 7 Pipeline Registers (after normalize, before round)
  // =========================================================================

  logic [SumBits-1:0] normalized_sum_s7;
  logic signed [ExpExtBits-1:0] normalized_exp_s7;
  logic sum_is_zero_s7;
  logic sum_sticky_s7;
  logic sticky_c_sub_s7;  // Sticky from addend shifted out during subtraction
  logic norm_sticky_s7;  // Sticky from normalization right-shift
  logic result_sign_s7;
  logic sign_large_s7;
  logic sign_small_s7;
  logic [2:0] rm_s7;
  logic is_special_s7;
  logic [FP_WIDTH-1:0] special_result_s7;
  logic special_invalid_s7;

  // =========================================================================
  // Stage 7A: Prepare rounding inputs (subnormal handling)
  // =========================================================================

  logic [MantBits:0] pre_round_mant_s7;
  logic final_sticky_s7;
  logic fp_round_sign_s7a_comb;

  assign pre_round_mant_s7 = normalized_sum_s7[ProdBits-1:FracBits];
  assign final_sticky_s7   = |normalized_sum_s7[FracBits-3:0] | sum_sticky_s7 | norm_sticky_s7;

  always_comb begin
    fp_round_sign_s7a_comb = result_sign_s7;
    if (sum_is_zero_s7 && !sum_sticky_s7) begin
      if (sign_large_s7 != sign_small_s7)
        fp_round_sign_s7a_comb = (rm_s7 == riscv_pkg::FRM_RDN) ? 1'b1 : 1'b0;
      else fp_round_sign_s7a_comb = sign_large_s7;
    end
  end

  // Extract mantissa and rounding bits
  logic [MantBits-1:0] mantissa_retained_s7;
  logic guard_bit_s7, round_bit_s7, sticky_bit_s7;
  logic guard_bit_raw_s7;

  assign mantissa_retained_s7 = pre_round_mant_s7[MantBits:1];
  assign guard_bit_raw_s7 = pre_round_mant_s7[0];
  // When the addend was shifted out during subtraction AND guard=1 AND bits[22:0]=0,
  // the exact result is just below the boundary, so guard should be 0.
  // This handles the FMA precision case where subtracting a small value causes
  // a borrow that flips the guard bit.
  assign guard_bit_s7 = guard_bit_raw_s7 &
                        ~(sticky_c_sub_s7 & (normalized_sum_s7[FracBits-1:0] == '0));
  assign round_bit_s7 = normalized_sum_s7[FracBits-1];
  assign sticky_bit_s7 = normalized_sum_s7[FracBits-2] | final_sticky_s7;

  // Subnormal handling: compute shift and apply
  logic [MantBits-1:0] mantissa_work_s7a_comb;
  logic guard_work_s7a_comb, round_work_s7a_comb, sticky_work_s7a_comb;
  logic signed [ExpExtBits-1:0] exp_work_s7a_comb;

  fp_subnorm_shift #(
      .MANT_BITS   (MantBits),
      .EXP_EXT_BITS(ExpExtBits)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained_s7),
      .i_guard   (guard_bit_s7),
      .i_round   (round_bit_s7),
      .i_sticky  (sticky_bit_s7),
      .i_exponent(normalized_exp_s7),
      .o_mantissa(mantissa_work_s7a_comb),
      .o_guard   (guard_work_s7a_comb),
      .o_round   (round_work_s7a_comb),
      .o_sticky  (sticky_work_s7a_comb),
      .o_exponent(exp_work_s7a_comb)
  );

  // =========================================================================
  // Stage 7A -> Stage 7B Pipeline Register (after subnormal handling)
  // =========================================================================

  logic [MantBits-1:0] mantissa_work_s7b;
  logic guard_work_s7b, round_work_s7b, sticky_work_s7b;
  logic signed [ExpExtBits-1:0] exp_work_s7b;
  logic fp_round_sign_s7b;
  logic is_zero_result_s7b;

  // Stage 7B: Compute round-up decision
  logic round_up_s7b_comb;
  logic lsb_s7b;

  assign lsb_s7b = mantissa_work_s7b[0];

  assign round_up_s7b_comb = riscv_pkg::fp_compute_round_up(
      rm_s7, guard_work_s7b, round_work_s7b, sticky_work_s7b, lsb_s7b, fp_round_sign_s7b
  );

  // Compute is_inexact for flags
  logic is_inexact_s7b;
  assign is_inexact_s7b = guard_work_s7b | round_work_s7b | sticky_work_s7b;

  // =========================================================================
  // Stage 7B -> Stage 8 Pipeline Register (after round-up decision)
  // =========================================================================

  logic                                  result_sign_s8;
  logic signed          [ExpExtBits-1:0] exp_work_s8;
  logic                 [  MantBits-1:0] mantissa_work_s8;
  logic                                  round_up_s8;
  logic                                  is_inexact_s8;
  logic                                  is_zero_result_s8;
  logic                 [           2:0] rm_s8;
  logic                                  is_special_s8;
  logic                 [  FP_WIDTH-1:0] special_result_s8;
  logic                                  special_invalid_s8;

  // =========================================================================
  // Stage 8: Apply rounding and format result (combinational from s8 regs)
  // =========================================================================

  // Compute final result using shared result assembler
  logic                 [  FP_WIDTH-1:0] final_result_s8_comb;
  riscv_pkg::fp_flags_t                  final_flags_s8_comb;

  fp_result_assembler #(
      .FP_WIDTH  (FP_WIDTH),
      .ExpBits   (ExpBits),
      .FracBits  (FracBits),
      .MantBits  (MantBits),
      .ExpExtBits(ExpExtBits)
  ) u_result_asm (
      .i_exp_work        (exp_work_s8),
      .i_mantissa_work   (mantissa_work_s8),
      .i_round_up        (round_up_s8),
      .i_is_inexact      (is_inexact_s8),
      .i_result_sign     (result_sign_s8),
      .i_rm              (rm_s8),
      .i_is_special      (is_special_s8),
      .i_special_result  (special_result_s8),
      .i_special_invalid (special_invalid_s8),
      .i_special_div_zero(1'b0),
      .i_is_zero_result  (is_zero_result_s8),
      .i_zero_sign       (result_sign_s8),
      .o_result          (final_result_s8_comb),
      .o_flags           (final_flags_s8_comb)
  );

  // =========================================================================
  // Stage 8 -> Stage 9 Pipeline Register (final output)
  // =========================================================================

  logic [FP_WIDTH-1:0] result_s9;
  riscv_pkg::fp_flags_t flags_s9;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================

  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *) logic valid_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      operand_a_reg <= '0;
      operand_b_reg <= '0;
      operand_c_reg <= '0;
      negate_product_reg <= 1'b0;
      negate_c_reg <= 1'b0;
      rm_reg <= 3'b0;
      // Stage 2
      mant_a_s2 <= '0;
      mant_b_s2 <= '0;
      prod_exp_s2 <= '0;
      prod_sign_s2 <= 1'b0;
      c_exp_s2 <= '0;
      mant_c_s2 <= '0;
      c_sign_s2 <= 1'b0;
      rm_s2 <= 3'b0;
      is_special_s2 <= 1'b0;
      special_result_s2 <= '0;
      special_invalid_s2 <= 1'b0;
      // Stage 2B (TIMING: after DSP multiply -- prod_pipe reset removed for SRL
      // inference; prod_valid_pipe gates consumption so reset of data is unnecessary)
      prod_valid_pipe <= '0;
      // Stage 3 (before LZC)
      prod_mant_s3 <= '0;
      prod_exp_s3 <= '0;
      prod_sign_s3 <= 1'b0;
      c_exp_s3 <= '0;
      mant_c_s3 <= '0;
      c_sign_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      is_special_s3 <= 1'b0;
      special_result_s3 <= '0;
      special_invalid_s3 <= 1'b0;
      // Stage 3B (after LZC, before shift)
      prod_mant_s3b <= '0;
      prod_exp_s3b <= '0;
      prod_sign_s3b <= 1'b0;
      prod_is_zero_s3b <= 1'b0;
      prod_msb_set_s3b <= 1'b0;
      prod_lzc_s3b <= '0;
      c_exp_s3b <= '0;
      mant_c_s3b <= '0;
      c_sign_s3b <= 1'b0;
      rm_s3b <= 3'b0;
      is_special_s3b <= 1'b0;
      special_result_s3b <= '0;
      special_invalid_s3b <= 1'b0;
      // Stage 4
      prod_exp_s4 <= '0;
      prod_mant_s4 <= '0;
      prod_sign_s4 <= 1'b0;
      c_exp_s4 <= '0;
      c_mant_s4 <= '0;
      c_sign_s4 <= 1'b0;
      rm_s4 <= 3'b0;
      is_special_s4 <= 1'b0;
      special_result_s4 <= '0;
      special_invalid_s4 <= 1'b0;
      // Stage 4b
      exp_large_s4b <= '0;
      shift_prod_amt_s4b <= '0;
      shift_c_amt_s4b <= '0;
      // Stage 5 (aligned operands)
      exp_large_s5 <= '0;
      prod_aligned_s5 <= '0;
      c_aligned_s5 <= '0;
      prod_sign_s5 <= 1'b0;
      c_sign_s5 <= 1'b0;
      sticky_s5 <= 1'b0;
      sticky_c_sub_s5 <= 1'b0;
      rm_s5 <= 3'b0;
      is_special_s5 <= 1'b0;
      special_result_s5 <= '0;
      special_invalid_s5 <= 1'b0;
      // Stage 5A (add/sub results)
      sum_s5a <= '0;
      result_sign_s5a <= 1'b0;
      sign_large_s5a <= 1'b0;
      sign_small_s5a <= 1'b0;
      sum_is_zero_s5a <= 1'b0;
      // Stage 6
      exp_large_s6 <= '0;
      sum_s6 <= '0;
      sum_is_zero_s6 <= 1'b0;
      lzc_s6 <= '0;
      sum_sticky_s6 <= 1'b0;
      sticky_c_sub_s6 <= 1'b0;
      result_sign_s6 <= 1'b0;
      sign_large_s6 <= 1'b0;
      sign_small_s6 <= 1'b0;
      rm_s6 <= 3'b0;
      is_special_s6 <= 1'b0;
      special_result_s6 <= '0;
      special_invalid_s6 <= 1'b0;
      // Stage 7 (normalize)
      normalized_sum_s7 <= '0;
      normalized_exp_s7 <= '0;
      sum_is_zero_s7 <= 1'b0;
      sum_sticky_s7 <= 1'b0;
      sticky_c_sub_s7 <= 1'b0;
      norm_sticky_s7 <= 1'b0;
      result_sign_s7 <= 1'b0;
      sign_large_s7 <= 1'b0;
      sign_small_s7 <= 1'b0;
      rm_s7 <= 3'b0;
      is_special_s7 <= 1'b0;
      special_result_s7 <= '0;
      special_invalid_s7 <= 1'b0;
      // Stage 7B (rounding inputs)
      mantissa_work_s7b <= '0;
      guard_work_s7b <= 1'b0;
      round_work_s7b <= 1'b0;
      sticky_work_s7b <= 1'b0;
      exp_work_s7b <= '0;
      fp_round_sign_s7b <= 1'b0;
      is_zero_result_s7b <= 1'b0;
      // Stage 8 (after round-up decision)
      result_sign_s8 <= 1'b0;
      exp_work_s8 <= '0;
      mantissa_work_s8 <= '0;
      round_up_s8 <= 1'b0;
      is_inexact_s8 <= 1'b0;
      is_zero_result_s8 <= 1'b0;
      rm_s8 <= 3'b0;
      is_special_s8 <= 1'b0;
      special_result_s8 <= '0;
      special_invalid_s8 <= 1'b0;
      // Stage 9 (final output)
      result_s9 <= '0;
      flags_s9 <= '0;
      valid_reg <= 1'b0;
    end else begin
      state <= next_state;
      valid_reg <= (state == STAGE9);
      // Post-multiply product pipeline (free-running for DSP register inference)
      prod_pipe[0] <= prod_mant_s2_comb;
      prod_valid_pipe[0] <= (state == STAGE2);
      for (int i = 1; i < MulPipeStages; i++) begin
        prod_pipe[i] <= prod_pipe[i-1];
        prod_valid_pipe[i] <= prod_valid_pipe[i-1];
      end

      case (state)
        IDLE: begin
          if (i_valid) begin
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            operand_c_reg <= i_operand_c;
            negate_product_reg <= i_negate_product;
            negate_c_reg <= i_negate_c;
            rm_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          mant_a_s2 <= mant_a_int;
          mant_b_s2 <= mant_b_int;
          prod_exp_s2 <= prod_exp_tentative;
          prod_sign_s2 <= sign_prod;
          c_exp_s2 <= $signed({{(ExpExtBits - ExpBits) {1'b0}}, exp_c_adj});
          mant_c_s2 <= mant_c_int;
          c_sign_s2 <= sign_c_adj;
          rm_s2 <= rm_reg;
          is_special_s2 <= is_special;
          special_result_s2 <= special_result;
          special_invalid_s2 <= special_invalid;
        end

        STAGE2: begin
          // Multiply pipeline runs continuously; no action needed here.
        end

        STAGE2B: begin
          // TIMING: Wait for pipelined product to emerge, then load stage 3 regs
          if (prod_valid_pipe[MulPipeStages-1]) begin
            prod_mant_s3 <= prod_pipe[MulPipeStages-1];
            prod_exp_s3 <= prod_exp_s2;
            prod_sign_s3 <= prod_sign_s2;
            c_exp_s3 <= c_exp_s2;
            mant_c_s3 <= mant_c_s2;
            c_sign_s3 <= c_sign_s2;
            rm_s3 <= rm_s2;
            is_special_s3 <= is_special_s2;
            special_result_s3 <= special_result_s2;
            special_invalid_s3 <= special_invalid_s2;
          end
        end

        STAGE3A: begin
          // Capture LZC results into stage 3B registers
          prod_mant_s3b <= prod_mant_s3;
          prod_exp_s3b <= prod_exp_s3;
          prod_sign_s3b <= prod_sign_s3;
          prod_is_zero_s3b <= prod_is_zero;
          prod_msb_set_s3b <= prod_msb_set;
          prod_lzc_s3b <= prod_lzc;
          c_exp_s3b <= c_exp_s3;
          mant_c_s3b <= mant_c_s3;
          c_sign_s3b <= c_sign_s3;
          rm_s3b <= rm_s3;
          is_special_s3b <= is_special_s3;
          special_result_s3b <= special_result_s3;
          special_invalid_s3b <= special_invalid_s3;
        end

        STAGE3B: begin
          // Capture normalized product into stage 4 registers
          prod_exp_s4 <= prod_exp_norm;
          prod_mant_s4 <= prod_mant_norm;
          prod_sign_s4 <= prod_sign_s3b;
          c_exp_s4 <= c_exp_s3b;
          c_mant_s4 <= {mant_c_s3b, {MantBits{1'b0}}};
          c_sign_s4 <= c_sign_s3b;
          rm_s4 <= rm_s3b;
          is_special_s4 <= is_special_s3b;
          special_result_s4 <= special_result_s3b;
          special_invalid_s4 <= special_invalid_s3b;
        end

        STAGE4: begin
          exp_large_s4b <= exp_large;
          shift_prod_amt_s4b <= shift_prod_amt;
          shift_c_amt_s4b <= shift_c_amt;
        end

        STAGE4B: begin
          exp_large_s5 <= exp_large_s4b;
          prod_aligned_s5 <= prod_aligned;
          c_aligned_s5 <= c_aligned;
          prod_sign_s5 <= prod_sign_s4;
          c_sign_s5 <= c_sign_s4;
          sticky_s5 <= sticky_prod | sticky_c;
          // Track when the smaller operand was shifted out during subtraction.
          // This affects the guard bit calculation for FMA precision.
          sticky_c_sub_s5 <= (prod_sign_s4 != c_sign_s4) ? (
              (prod_aligned > c_aligned) ? sticky_c :
              (c_aligned > prod_aligned) ? sticky_prod :
              1'b0
          ) : 1'b0;
          rm_s5 <= rm_s4;
          is_special_s5 <= is_special_s4;
          special_result_s5 <= special_result_s4;
          special_invalid_s5 <= special_invalid_s4;
        end

        STAGE5A: begin
          sum_s5a <= sum_s5a_comb;
          result_sign_s5a <= result_sign_s5a_comb;
          sign_large_s5a <= sign_large_s5a_comb;
          sign_small_s5a <= sign_small_s5a_comb;
          sum_is_zero_s5a <= sum_is_zero_s5a_comb;
        end

        STAGE5B: begin
          exp_large_s6 <= exp_large_s5;
          sum_s6 <= sum_s5a;
          sum_is_zero_s6 <= sum_is_zero_s5a;
          lzc_s6 <= lzc_s5b_comb;
          sum_sticky_s6 <= sticky_s5;
          sticky_c_sub_s6 <= sticky_c_sub_s5;
          result_sign_s6 <= result_sign_s5a;
          sign_large_s6 <= sign_large_s5a;
          sign_small_s6 <= sign_small_s5a;
          rm_s6 <= rm_s5;
          is_special_s6 <= is_special_s5;
          special_result_s6 <= special_result_s5;
          special_invalid_s6 <= special_invalid_s5;
        end

        STAGE6: begin
          normalized_sum_s7 <= normalized_sum_s6_comb;
          normalized_exp_s7 <= normalized_exp_s6_comb;
          sum_is_zero_s7 <= sum_is_zero_s6;
          sum_sticky_s7 <= sum_sticky_s6;
          sticky_c_sub_s7 <= sticky_c_sub_s6;
          norm_sticky_s7 <= norm_sticky_s6_comb;
          result_sign_s7 <= result_sign_s6;
          sign_large_s7 <= sign_large_s6;
          sign_small_s7 <= sign_small_s6;
          rm_s7 <= rm_s6;
          is_special_s7 <= is_special_s6;
          special_result_s7 <= special_result_s6;
          special_invalid_s7 <= special_invalid_s6;
        end

        STAGE7A: begin
          // Capture subnormal handling outputs into stage 7B registers
          mantissa_work_s7b <= mantissa_work_s7a_comb;
          guard_work_s7b <= guard_work_s7a_comb;
          round_work_s7b <= round_work_s7a_comb;
          sticky_work_s7b <= sticky_work_s7a_comb;
          exp_work_s7b <= exp_work_s7a_comb;
          fp_round_sign_s7b <= fp_round_sign_s7a_comb;
          is_zero_result_s7b <= sum_is_zero_s7 && !sum_sticky_s7;
        end

        STAGE7B: begin
          // Capture round-up decision into s8 registers
          result_sign_s8 <= fp_round_sign_s7b;
          exp_work_s8 <= exp_work_s7b;
          mantissa_work_s8 <= mantissa_work_s7b;
          round_up_s8 <= round_up_s7b_comb;
          is_inexact_s8 <= is_inexact_s7b;
          is_zero_result_s8 <= is_zero_result_s7b;
          rm_s8 <= rm_s7;
          is_special_s8 <= is_special_s7;
          special_result_s8 <= special_result_s7;
          special_invalid_s8 <= special_invalid_s7;
        end

        STAGE8: begin
          // Capture final result into s9 registers
          result_s9 <= final_result_s8_comb;
          flags_s9  <= final_flags_s8_comb;
        end

        STAGE9: begin
          // Output already captured in s9
        end

        default: ;
      endcase
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;
    case (state)
      IDLE:    if (i_valid) next_state = STAGE1;
      STAGE1:  next_state = STAGE2;
      STAGE2:  next_state = STAGE2B;
      STAGE2B: next_state = state_e'(prod_valid_pipe[MulPipeStages - 1] ? STAGE3A : STAGE2B);
      STAGE3A: next_state = STAGE3B;
      STAGE3B: next_state = STAGE4;
      STAGE4:  next_state = STAGE4B;
      STAGE4B: next_state = STAGE5A;
      STAGE5A: next_state = STAGE5B;
      STAGE5B: next_state = STAGE6;
      STAGE6:  next_state = STAGE7A;
      STAGE7A: next_state = STAGE7B;
      STAGE7B: next_state = STAGE8;
      STAGE8:  next_state = STAGE9;
      STAGE9:  next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // Output logic (from registered s9)
  assign o_result = result_s9;
  assign o_flags  = flags_s9;
  assign o_valid  = valid_reg;

endmodule : fp_fma
