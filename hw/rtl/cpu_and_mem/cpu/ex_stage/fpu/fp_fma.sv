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
  IEEE 754 fused multiply-add (width-parameterized: FP_WIDTH 32 or 64).

  Computes (a * b) + c with a single rounding. Handles NaNs, infinities,
  zeros, and subnormal operands.

  Operations:
    FMADD.{S,D}:  fd = (fs1 * fs2) + fs3
    FMSUB.{S,D}:  fd = (fs1 * fs2) - fs3
    FNMADD.{S,D}: fd = -(fs1 * fs2) - fs3
    FNMSUB.{S,D}: fd = -(fs1 * fs2) + fs3
  The caller selects the variant through i_negate_product and i_negate_c.

  Fully pipelined, one operation accepted per cycle. Stages, one register
  boundary each unless noted:
    Stage 0:  capture operands
    Stage 1:  unpack operands, detect special cases, compute product exponent
    Stage 2:  mantissa multiply (MantBits x MantBits -> ProdBits) in
              dsp_tiled_multiplier_unsigned, MultLatency (3) cycles for both
              widths, with metadata on a matching shift chain
    Stage 3A: product leading zero count
    Stage 3B: product normalization shift
    Stage 4:  align prep (exponent compare, shift amounts)
    Stage 4b: align product and addend (barrel shift)
    Stage 5A: add/subtract
    Stage 5B: leading zero count on the sum
    Stage 6:  normalize the sum
    Stage 7A: subnormal shift, rounding-bit extraction
    Stage 7B: round-up decision
    Stage 8:  rounding increment and result formatting (fp_result_assembler)
    Stage 9:  output register
  Latency from i_valid to o_valid is 2 + MultLatency + 11 = 16 cycles.
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

  localparam int unsigned MultATileWidth = 27;
  localparam int unsigned MultBTileWidth = 35;
  localparam int unsigned MultNumATiles = (MantBits + MultATileWidth - 1) / MultATileWidth;
  localparam int unsigned MultNumBTiles = (MantBits + MultBTileWidth - 1) / MultBTileWidth;
  localparam int unsigned MultNumTerms = MultNumATiles * MultNumBTiles;
  localparam int unsigned MultReduceStages = (MultNumTerms <= 1) ? 0 : $clog2(MultNumTerms);
  localparam int unsigned MultMinLatency = 3;
  localparam int unsigned MultReduceLatency = MultReduceStages + 1;
  localparam int unsigned MultLatency =
      (MultReduceLatency < MultMinLatency) ? MultMinLatency : MultReduceLatency;
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
  // Stage 2: Start mantissa multiply
  // dsp_tiled_multiplier_unsigned splits the multiply into {27x35} tiles. See
  // that module for the DSP48E2 27x(18+17) decomposition.
  // =========================================================================

  logic        [  ProdBits-1:0] prod_mant_s2_tiled;
  logic                         prod_mant_s2_tiled_valid;
  logic                         valid_s2;

  dsp_tiled_multiplier_unsigned #(
      .A_WIDTH(MantBits),
      .B_WIDTH(MantBits)
  ) u_mantissa_multiplier (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid_input(valid_s2),
      .i_operand_a(mant_a_s2),
      .i_operand_b(mant_b_s2),
      .o_product_result(prod_mant_s2_tiled),
      .o_valid_output(prod_mant_s2_tiled_valid),
      .o_completing_next_cycle(  /*unused*/)
  );

  logic                          mult_meta_valid     [MultLatency];
  logic signed [ ExpExtBits-1:0] mult_prod_exp       [MultLatency];
  logic                          mult_prod_sign      [MultLatency];
  logic signed [ ExpExtBits-1:0] mult_c_exp          [MultLatency];
  logic        [   MantBits-1:0] mult_mant_c         [MultLatency];
  logic                          mult_c_sign         [MultLatency];
  logic        [            2:0] mult_rm             [MultLatency];
  logic                          mult_is_special     [MultLatency];
  logic        [   FP_WIDTH-1:0] mult_special_result [MultLatency];
  logic                          mult_special_invalid[MultLatency];

  // =========================================================================
  // Stage 2B -> Stage 3 Pipeline Registers (after DSP pipeline, before LZC)
  // =========================================================================

  logic        [   ProdBits-1:0] prod_mant_s3;
  logic signed [ ExpExtBits-1:0] prod_exp_s3;
  logic                          prod_sign_s3;
  logic signed [ ExpExtBits-1:0] c_exp_s3;
  logic        [   MantBits-1:0] mant_c_s3;
  logic                          c_sign_s3;
  logic        [            2:0] rm_s3;
  logic                          is_special_s3;
  logic        [   FP_WIDTH-1:0] special_result_s3;
  logic                          special_invalid_s3;

  // =========================================================================
  // Stage 3A: Product LZC (combinational from stage 3 regs)
  // =========================================================================

  logic        [LzcProdBits-1:0] prod_lzc;
  logic                          prod_is_zero;
  logic                          prod_msb_set;

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
  logic        [  ProdBits-1:0] prod_mant_s4b;
  logic        [  ProdBits-1:0] c_mant_s4b;
  logic                         prod_sign_s4b;
  logic                         c_sign_s4b;
  logic        [           2:0] rm_s4b;
  logic                         is_special_s4b;
  logic        [  FP_WIDTH-1:0] special_result_s4b;
  logic                         special_invalid_s4b;

  // =========================================================================
  // Stage 4b: Align (barrel shift, combinational from stage 4b regs)
  // =========================================================================

  logic        [  ProdBits-1:0] prod_aligned;
  logic        [  ProdBits-1:0] c_aligned;
  logic                         sticky_prod;
  logic                         sticky_c;

  always_comb begin
    prod_aligned = prod_mant_s4b;
    sticky_prod  = 1'b0;
    if (shift_prod_amt_s4b >= ShiftBits'(ProdBits)) begin
      prod_aligned = '0;
      sticky_prod  = |prod_mant_s4b;
    end else if (shift_prod_amt_s4b != 0) begin
      prod_aligned = prod_mant_s4b >> shift_prod_amt_s4b;
      sticky_prod  = 1'b0;
      for (int i = 0; i < ProdBits; i++) begin
        if (i < shift_prod_amt_s4b) sticky_prod = sticky_prod | prod_mant_s4b[i];
      end
    end

    c_aligned = c_mant_s4b;
    sticky_c  = 1'b0;
    if (shift_c_amt_s4b >= ShiftBits'(ProdBits)) begin
      c_aligned = '0;
      sticky_c  = |c_mant_s4b;
    end else if (shift_c_amt_s4b != 0) begin
      c_aligned = c_mant_s4b >> shift_c_amt_s4b;
      sticky_c  = 1'b0;
      for (int i = 0; i < ProdBits; i++) begin
        if (i < shift_c_amt_s4b) sticky_c = sticky_c | c_mant_s4b[i];
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
        // The smaller operand's shifted-out residual (sticky_c_sub_s5) is a
        // borrow: the exact difference is less than the truncated one by under
        // one unit, so subtract 1 and let the sticky bit mark it inexact.
        sum_s5a_comb = ({1'b0, prod_aligned_s5} - {1'b0, c_aligned_s5}) - SumBits'(sticky_c_sub_s5);
        result_sign_s5a_comb = prod_sign_s5;
        sign_large_s5a_comb = prod_sign_s5;
        sign_small_s5a_comb = c_sign_s5;
      end else if (c_aligned_s5 > prod_aligned_s5) begin
        // Symmetric borrow propagation (c is the larger operand here).
        sum_s5a_comb = ({1'b0, c_aligned_s5} - {1'b0, prod_aligned_s5}) - SumBits'(sticky_c_sub_s5);
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

  logic        [   SumBits-1:0] sum_s5a;
  logic                         result_sign_s5a;
  logic                         sign_large_s5a;
  logic                         sign_small_s5a;
  logic                         sum_is_zero_s5a;
  logic signed [ExpExtBits-1:0] exp_large_s5a;
  logic                         sticky_s5a;
  logic        [           2:0] rm_s5a;
  logic                         is_special_s5a;
  logic        [  FP_WIDTH-1:0] special_result_s5a;
  logic                         special_invalid_s5a;

  // =========================================================================
  // Stage 5B: LZC (combinational from stage 5A regs)
  // =========================================================================

  logic        [LzcSumBits-1:0] lzc_s5b_comb;
  logic                         lzc_sum_is_zero;

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
  // No guard-bit correction here. The effective-subtraction path in
  // sum_s5a_comb already subtracts the smaller operand's shifted-out residual
  // (sticky_c_sub_s5) as a borrow, so the normalized mantissa and its guard bit
  // are exact. An earlier special case at this point patched only the
  // round-to-nearest tie and left RTZ/RDN/RUP rounding 1 ULP high, which
  // failed the F/D arch-test FMA b4-b7 cases.
  assign guard_bit_s7 = guard_bit_raw_s7;
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
  logic [2:0] rm_s7b;
  logic is_special_s7b;
  logic [FP_WIDTH-1:0] special_result_s7b;
  logic special_invalid_s7b;

  // Stage 7B: Compute round-up decision
  logic round_up_s7b_comb;
  logic lsb_s7b;

  assign lsb_s7b = mantissa_work_s7b[0];

  assign round_up_s7b_comb = riscv_pkg::fp_compute_round_up(
      rm_s7b, guard_work_s7b, round_work_s7b, sticky_work_s7b, lsb_s7b, fp_round_sign_s7b
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
  logic valid_s1, valid_s3, valid_s3b, valid_s4, valid_s4b, valid_s5;
  logic valid_s5a, valid_s6, valid_s7, valid_s7b, valid_s8, valid_s9;

  // =========================================================================
  // Pipelined Control and Sequential Logic
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_s1  <= 1'b0;
      valid_s2  <= 1'b0;
      valid_s3  <= 1'b0;
      valid_s3b <= 1'b0;
      valid_s4  <= 1'b0;
      valid_s4b <= 1'b0;
      valid_s5  <= 1'b0;
      valid_s5a <= 1'b0;
      valid_s6  <= 1'b0;
      valid_s7  <= 1'b0;
      valid_s7b <= 1'b0;
      valid_s8  <= 1'b0;
      valid_s9  <= 1'b0;
      for (int i = 0; i < MultLatency; i++) begin
        mult_meta_valid[i] <= 1'b0;
      end
    end else begin
      valid_s1 <= i_valid;
      valid_s2 <= valid_s1;
      valid_s3 <= prod_mant_s2_tiled_valid;
      valid_s3b <= valid_s3;
      valid_s4 <= valid_s3b;
      valid_s4b <= valid_s4;
      valid_s5 <= valid_s4b;
      valid_s5a <= valid_s5;
      valid_s6 <= valid_s5a;
      valid_s7 <= valid_s6;
      valid_s7b <= valid_s7;
      valid_s8 <= valid_s7b;
      valid_s9 <= valid_s8;

      mult_meta_valid[0] <= valid_s2;
      for (int i = 1; i < MultLatency; i++) begin
        mult_meta_valid[i] <= mult_meta_valid[i-1];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_valid) begin
      operand_a_reg <= i_operand_a;
      operand_b_reg <= i_operand_b;
      operand_c_reg <= i_operand_c;
      negate_product_reg <= i_negate_product;
      negate_c_reg <= i_negate_c;
      rm_reg <= i_rounding_mode;
    end

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

    mult_prod_exp[0] <= prod_exp_s2;
    mult_prod_sign[0] <= prod_sign_s2;
    mult_c_exp[0] <= c_exp_s2;
    mult_mant_c[0] <= mant_c_s2;
    mult_c_sign[0] <= c_sign_s2;
    mult_rm[0] <= rm_s2;
    mult_is_special[0] <= is_special_s2;
    mult_special_result[0] <= special_result_s2;
    mult_special_invalid[0] <= special_invalid_s2;
    for (int i = 1; i < MultLatency; i++) begin
      mult_prod_exp[i] <= mult_prod_exp[i-1];
      mult_prod_sign[i] <= mult_prod_sign[i-1];
      mult_c_exp[i] <= mult_c_exp[i-1];
      mult_mant_c[i] <= mult_mant_c[i-1];
      mult_c_sign[i] <= mult_c_sign[i-1];
      mult_rm[i] <= mult_rm[i-1];
      mult_is_special[i] <= mult_is_special[i-1];
      mult_special_result[i] <= mult_special_result[i-1];
      mult_special_invalid[i] <= mult_special_invalid[i-1];
    end

    prod_mant_s3 <= prod_mant_s2_tiled;
    prod_exp_s3 <= mult_prod_exp[MultLatency-1];
    prod_sign_s3 <= mult_prod_sign[MultLatency-1];
    c_exp_s3 <= mult_c_exp[MultLatency-1];
    mant_c_s3 <= mult_mant_c[MultLatency-1];
    c_sign_s3 <= mult_c_sign[MultLatency-1];
    rm_s3 <= mult_rm[MultLatency-1];
    is_special_s3 <= mult_is_special[MultLatency-1];
    special_result_s3 <= mult_special_result[MultLatency-1];
    special_invalid_s3 <= mult_special_invalid[MultLatency-1];

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

    exp_large_s4b <= exp_large;
    shift_prod_amt_s4b <= shift_prod_amt;
    shift_c_amt_s4b <= shift_c_amt;
    prod_mant_s4b <= prod_mant_s4;
    c_mant_s4b <= c_mant_s4;
    prod_sign_s4b <= prod_sign_s4;
    c_sign_s4b <= c_sign_s4;
    rm_s4b <= rm_s4;
    is_special_s4b <= is_special_s4;
    special_result_s4b <= special_result_s4;
    special_invalid_s4b <= special_invalid_s4;

    exp_large_s5 <= exp_large_s4b;
    prod_aligned_s5 <= prod_aligned;
    c_aligned_s5 <= c_aligned;
    prod_sign_s5 <= prod_sign_s4b;
    c_sign_s5 <= c_sign_s4b;
    sticky_s5 <= sticky_prod | sticky_c;
    sticky_c_sub_s5 <= (prod_sign_s4b != c_sign_s4b) ? (
        (prod_aligned > c_aligned) ? sticky_c :
        (c_aligned > prod_aligned) ? sticky_prod :
        1'b0
    ) : 1'b0;
    rm_s5 <= rm_s4b;
    is_special_s5 <= is_special_s4b;
    special_result_s5 <= special_result_s4b;
    special_invalid_s5 <= special_invalid_s4b;

    sum_s5a <= sum_s5a_comb;
    result_sign_s5a <= result_sign_s5a_comb;
    sign_large_s5a <= sign_large_s5a_comb;
    sign_small_s5a <= sign_small_s5a_comb;
    sum_is_zero_s5a <= sum_is_zero_s5a_comb;
    exp_large_s5a <= exp_large_s5;
    sticky_s5a <= sticky_s5;
    rm_s5a <= rm_s5;
    is_special_s5a <= is_special_s5;
    special_result_s5a <= special_result_s5;
    special_invalid_s5a <= special_invalid_s5;

    exp_large_s6 <= exp_large_s5a;
    sum_s6 <= sum_s5a;
    sum_is_zero_s6 <= sum_is_zero_s5a;
    lzc_s6 <= lzc_s5b_comb;
    sum_sticky_s6 <= sticky_s5a;
    result_sign_s6 <= result_sign_s5a;
    sign_large_s6 <= sign_large_s5a;
    sign_small_s6 <= sign_small_s5a;
    rm_s6 <= rm_s5a;
    is_special_s6 <= is_special_s5a;
    special_result_s6 <= special_result_s5a;
    special_invalid_s6 <= special_invalid_s5a;

    normalized_sum_s7 <= normalized_sum_s6_comb;
    normalized_exp_s7 <= normalized_exp_s6_comb;
    sum_is_zero_s7 <= sum_is_zero_s6;
    sum_sticky_s7 <= sum_sticky_s6;
    norm_sticky_s7 <= norm_sticky_s6_comb;
    result_sign_s7 <= result_sign_s6;
    sign_large_s7 <= sign_large_s6;
    sign_small_s7 <= sign_small_s6;
    rm_s7 <= rm_s6;
    is_special_s7 <= is_special_s6;
    special_result_s7 <= special_result_s6;
    special_invalid_s7 <= special_invalid_s6;

    mantissa_work_s7b <= mantissa_work_s7a_comb;
    guard_work_s7b <= guard_work_s7a_comb;
    round_work_s7b <= round_work_s7a_comb;
    sticky_work_s7b <= sticky_work_s7a_comb;
    exp_work_s7b <= exp_work_s7a_comb;
    fp_round_sign_s7b <= fp_round_sign_s7a_comb;
    is_zero_result_s7b <= sum_is_zero_s7 && !sum_sticky_s7;
    rm_s7b <= rm_s7;
    is_special_s7b <= is_special_s7;
    special_result_s7b <= special_result_s7;
    special_invalid_s7b <= special_invalid_s7;

    result_sign_s8 <= fp_round_sign_s7b;
    exp_work_s8 <= exp_work_s7b;
    mantissa_work_s8 <= mantissa_work_s7b;
    round_up_s8 <= round_up_s7b_comb;
    is_inexact_s8 <= is_inexact_s7b;
    is_zero_result_s8 <= is_zero_result_s7b;
    rm_s8 <= rm_s7b;
    is_special_s8 <= is_special_s7b;
    special_result_s8 <= special_result_s7b;
    special_invalid_s8 <= special_invalid_s7b;

    result_s9 <= final_result_s8_comb;
    flags_s9 <= final_flags_s8_comb;
  end

  // Output logic (from registered s9)
  assign o_result = result_s9;
  assign o_flags  = flags_s9;
  assign o_valid  = valid_s9;

endmodule : fp_fma
