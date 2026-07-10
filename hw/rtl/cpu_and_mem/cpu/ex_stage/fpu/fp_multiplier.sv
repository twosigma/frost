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
  IEEE 754 single-precision floating-point multiplier.

  Implements FMUL.S operation.

  Fully pipelined implementation:
    Cycle 0: Capture operands
    Cycle 1: Unpack, compute result sign and exponent, detect special cases
    Cycle 2: Multiply mantissas (24x24 -> 48 bits)
    Cycle 2B: TIMING: 3-cycle DSP-tiled multiplier pipeline
    Cycle 3A: Compute leading zero count (LZC)
    Cycle 3B: Apply normalization shift
    Cycle 4A: Subnormal handling, compute rounding inputs
    Cycle 4B: Compute round-up decision
    Cycle 5: Apply rounding increment, format result
    Cycle 6: Capture result
    Cycle 7: Output registered result

  The unit accepts a new operation every cycle. Valid bits and sideband metadata
  move through the same register boundaries as the datapath.

  Special case handling:
    - NaN propagation (quiet NaN result)
    - Infinity * 0 = NaN (invalid)
    - Infinity * finite = infinity
    - Zero * anything = zero (with proper sign)
*/
module fp_multiplier #(
    parameter int unsigned FP_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [FP_WIDTH-1:0] i_operand_a,
    input logic [FP_WIDTH-1:0] i_operand_b,
    input logic [2:0] i_rounding_mode,
    input logic i_stall,  // Pipeline stall (unused in non-pipelined mode)
    output logic [FP_WIDTH-1:0] o_result,
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned ProdBits = MantBits * 2;
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcBits = $clog2(ProdBits + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam logic signed [ExpExtBits-1:0] ExpBiasExt = ExpExtBits'(ExpBias);
  localparam logic signed [ExpExtBits:0] MantBitsPlus3Signed = {1'b0, ExpExtBits'(MantBits + 3)};
  localparam logic [LzcBits-1:0] MantBitsPlus3Shift = LzcBits'(MantBits + 3);

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
  // =========================================================================
  // Captured Operands (registered at start of operation)
  // =========================================================================

  logic [FP_WIDTH-1:0] operand_a_reg, operand_b_reg;
  logic [2:0] rounding_mode_reg;

  // =========================================================================
  // Stage 1: Unpack (combinational from captured operands)
  // =========================================================================

  logic [FP_WIDTH-1:0] op_a, op_b;
  assign op_a = operand_a_reg;
  assign op_b = operand_b_reg;

  logic sign_a, sign_b, result_sign;
  logic [ExpBits-1:0] exp_a, exp_b;
  logic [ExpBits-1:0] exp_a_adj, exp_b_adj;
  logic [MantBits-1:0] mant_a, mant_b;

  // Special value detection
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;
  logic is_subnormal_a, is_subnormal_b;

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_a (
      .i_operand(op_a),
      .o_sign(sign_a),
      .o_exp(exp_a),
      .o_exp_adj(exp_a_adj),
      .o_frac(),
      .o_mant(mant_a),
      .o_is_zero(is_zero_a),
      .o_is_subnormal(is_subnormal_a),
      .o_is_inf(is_inf_a),
      .o_is_nan(is_nan_a),
      .o_is_snan(is_snan_a)
  );
  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_b (
      .i_operand(op_b),
      .o_sign(sign_b),
      .o_exp(exp_b),
      .o_exp_adj(exp_b_adj),
      .o_frac(),
      .o_mant(mant_b),
      .o_is_zero(is_zero_b),
      .o_is_subnormal(is_subnormal_b),
      .o_is_inf(is_inf_b),
      .o_is_nan(is_nan_b),
      .o_is_snan(is_snan_b)
  );

  assign result_sign = sign_a ^ sign_b;

  // Compute tentative exponent (before normalization)
  logic signed [ExpExtBits-1:0] tentative_exp;
  assign tentative_exp = $signed(
      {{(ExpExtBits - ExpBits) {1'b0}}, exp_a_adj}
  ) + $signed(
      {{(ExpExtBits - ExpBits) {1'b0}}, exp_b_adj}
  ) - ExpBiasExt;

  // Special case handling
  logic                is_special;
  logic [FP_WIDTH-1:0] special_result;
  logic                special_invalid;

  always_comb begin
    is_special = 1'b0;
    special_result = '0;
    special_invalid = 1'b0;

    if (is_nan_a || is_nan_b) begin
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = is_snan_a | is_snan_b;
    end else if ((is_inf_a && is_zero_b) || (is_zero_a && is_inf_b)) begin
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf_a || is_inf_b) begin
      is_special = 1'b1;
      special_result = {result_sign, ExpMax, {FracBits{1'b0}}};
    end else if (is_zero_a || is_zero_b) begin
      is_special = 1'b1;
      special_result = {result_sign, {(FP_WIDTH - 1) {1'b0}}};
    end
  end

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Register (after unpack, before multiply)
  // =========================================================================

  logic                         result_sign_s2;
  logic signed [ExpExtBits-1:0] tentative_exp_s2;
  logic [MantBits-1:0] mant_a_s2, mant_b_s2;
  logic                is_special_s2;
  logic [FP_WIDTH-1:0] special_result_s2;
  logic                special_invalid_s2;
  logic [         2:0] rm_s2;

  // =========================================================================
  // Stage 2: Start mantissa multiply
  // Uses DSP-tiled {27x35} unsigned multiplier (18+17 cascade-friendly).
  // =========================================================================

  logic [ProdBits-1:0] product_s2_tiled;
  logic                product_s2_tiled_valid;
  logic                valid_s2;

  dsp_tiled_multiplier_unsigned #(
      .A_WIDTH(MantBits),
      .B_WIDTH(MantBits)
  ) u_mantissa_multiplier (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid_input(valid_s2),
      .i_operand_a(mant_a_s2),
      .i_operand_b(mant_b_s2),
      .o_product_result(product_s2_tiled),
      .o_valid_output(product_s2_tiled_valid),
      .o_completing_next_cycle(  /*unused*/)
  );

  logic                         mult_meta_valid     [MultLatency];
  logic                         mult_result_sign    [MultLatency];
  logic signed [ExpExtBits-1:0] mult_tentative_exp  [MultLatency];
  logic                         mult_is_special     [MultLatency];
  logic        [  FP_WIDTH-1:0] mult_special_result [MultLatency];
  logic                         mult_special_invalid[MultLatency];
  logic        [           2:0] mult_rm             [MultLatency];

  // =========================================================================
  // Stage 2B -> Stage 3 Pipeline Register (after multiply, before normalize)
  // =========================================================================

  logic                         result_sign_s3;
  logic signed [ExpExtBits-1:0] tentative_exp_s3;
  logic        [  ProdBits-1:0] product_s3;
  logic                         is_special_s3;
  logic        [  FP_WIDTH-1:0] special_result_s3;
  logic                         special_invalid_s3;
  logic        [           2:0] rm_s3;

  // =========================================================================
  // Stage 3A: Compute Leading Zero Count (combinational from stage 3 regs)
  // =========================================================================

  logic                         product_is_zero_s3;
  logic                         product_msb_set_s3;

  assign product_is_zero_s3 = (product_s3 == '0);
  assign product_msb_set_s3 = product_s3[ProdBits-1];

  logic [LzcBits-1:0] lzc_s3;
  logic               lzc_prod_is_zero;

  // LZC on bits [ProdBits-2:0] (MSB checked separately)
  fp_lzc #(
      .WIDTH(ProdBits - 1)
  ) u_prod_lzc (
      .i_value (product_s3[ProdBits-2:0]),
      .o_lzc   (lzc_s3),
      .o_is_zero(lzc_prod_is_zero)
  );

  // =========================================================================
  // Stage 3A -> Stage 3B Pipeline Register (after LZC, before shift)
  // =========================================================================

  logic                         result_sign_s3b;
  logic signed [ExpExtBits-1:0] tentative_exp_s3b;
  logic        [  ProdBits-1:0] product_s3b;
  logic                         product_is_zero_s3b;
  logic                         product_msb_set_s3b;
  logic        [   LzcBits-1:0] lzc_s3b;
  logic                         is_special_s3b;
  logic        [  FP_WIDTH-1:0] special_result_s3b;
  logic                         special_invalid_s3b;
  logic        [           2:0] rm_s3b;

  // =========================================================================
  // Stage 3B: Apply Normalization Shift (combinational from stage 3B regs)
  // =========================================================================

  logic        [  ProdBits-1:0] normalized_product_s3b;
  logic signed [ExpExtBits-1:0] normalized_exp_s3b;

  always_comb begin
    if (product_is_zero_s3b) begin
      normalized_product_s3b = '0;
      normalized_exp_s3b = '0;
    end else if (product_msb_set_s3b) begin
      normalized_product_s3b = product_s3b;
      normalized_exp_s3b = tentative_exp_s3b + 1;
    end else begin
      normalized_product_s3b = product_s3b << (lzc_s3b + 1'b1);
      normalized_exp_s3b = tentative_exp_s3b - $signed({{(ExpExtBits - LzcBits) {1'b0}}, lzc_s3b});
    end
  end

  // =========================================================================
  // Stage 3B -> Stage 4 Pipeline Register (after normalize, before round)
  // =========================================================================

  logic                         result_sign_s4;
  logic signed [ExpExtBits-1:0] exp_s4;
  logic        [  ProdBits-1:0] product_s4;
  logic                         product_is_zero_s4;
  logic                         is_special_s4;
  // TIMING OPTIMIZATION: Pre-compute subnormal condition in stage 3B to reduce
  // critical path depth in stage 4A. The comparison is done on normalized_exp_s3b
  // and registered, so the mux select is ready immediately in stage 4A.
  logic        [  FP_WIDTH-1:0] special_result_s4;
  logic                         special_invalid_s4;
  logic        [           2:0] rm_s4;

  // =========================================================================
  // Stage 4A: Subnormal handling, compute rounding inputs
  // =========================================================================

  logic        [    MantBits:0] pre_round_mant_s4;
  logic guard_bit_s4, round_bit_s4, sticky_bit_s4;

  localparam int unsigned GuardIndexP4 = ProdBits - MantBits - 2;

  assign pre_round_mant_s4 = product_s4[ProdBits-1-:(MantBits+1)];
  assign guard_bit_s4 = product_s4[GuardIndexP4];
  assign round_bit_s4 = product_s4[GuardIndexP4-1];
  assign sticky_bit_s4 = |product_s4[GuardIndexP4-2:0];

  // Extract mantissa and rounding bits
  logic [MantBits-1:0] mantissa_retained_s4;
  assign mantissa_retained_s4 = pre_round_mant_s4[MantBits:1];

  // Subnormal handling: compute shift and apply
  logic [MantBits-1:0] mantissa_work_s4;
  logic guard_work_s4, round_work_s4, sticky_work_s4;
  logic signed [ExpExtBits-1:0] exp_work_s4;

  // TIMING OPTIMIZATION: Use pre-computed subnormal condition (registered)
  // instead of comparing exp_s4 <= 0 here (which was on the critical path).
  // When is_subnormal_s4 is false, exp_s4 > 0 so fp_subnorm_shift passes through.
  fp_subnorm_shift #(
      .MANT_BITS   (MantBits),
      .EXP_EXT_BITS(ExpExtBits)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained_s4),
      .i_guard   (pre_round_mant_s4[0]),
      .i_round   (guard_bit_s4),
      .i_sticky  (round_bit_s4 | sticky_bit_s4),
      .i_exponent(exp_s4),
      .o_mantissa(mantissa_work_s4),
      .o_guard   (guard_work_s4),
      .o_round   (round_work_s4),
      .o_sticky  (sticky_work_s4),
      .o_exponent(exp_work_s4)
  );

  // =========================================================================
  // Stage 4A -> Stage 4B Pipeline Register (after subnormal handling)
  // =========================================================================

  logic [MantBits-1:0] mantissa_work_s4b;
  logic guard_work_s4b, round_work_s4b, sticky_work_s4b;
  logic signed [ExpExtBits-1:0] exp_work_s4b;
  logic                         result_sign_s4b;
  logic                         product_is_zero_s4b;
  logic        [           2:0] rm_s4b;
  logic                         is_special_s4b;
  logic        [  FP_WIDTH-1:0] special_result_s4b;
  logic                         special_invalid_s4b;

  // Stage 4B: Compute round-up decision
  logic                         round_up_s4b_comb;
  logic                         lsb_s4b;

  assign lsb_s4b = mantissa_work_s4b[0];

  assign round_up_s4b_comb = riscv_pkg::fp_compute_round_up(
      rm_s4b, guard_work_s4b, round_work_s4b, sticky_work_s4b, lsb_s4b, result_sign_s4b
  );

  // Compute is_inexact for flags
  logic is_inexact_s4b;
  assign is_inexact_s4b = guard_work_s4b | round_work_s4b | sticky_work_s4b;

  // =========================================================================
  // Stage 4B -> Stage 5 Pipeline Register (after round-up decision)
  // =========================================================================

  logic                                  result_sign_s5;
  logic signed          [ExpExtBits-1:0] exp_work_s5;
  logic                 [  MantBits-1:0] mantissa_work_s5;
  logic                                  round_up_s5;
  logic                                  is_inexact_s5;
  logic                                  product_is_zero_s5;
  logic                 [           2:0] rm_s5;
  logic                                  is_special_s5;
  logic                 [  FP_WIDTH-1:0] special_result_s5;
  logic                                  special_invalid_s5;

  // =========================================================================
  // Stage 5: Apply rounding and format result (combinational from s5 regs)
  // =========================================================================

  // Compute final result using shared result assembler
  logic                 [  FP_WIDTH-1:0] final_result_s5_comb;
  riscv_pkg::fp_flags_t                  final_flags_s5_comb;

  fp_result_assembler #(
      .FP_WIDTH  (FP_WIDTH),
      .ExpBits   (ExpBits),
      .FracBits  (FracBits),
      .MantBits  (MantBits),
      .ExpExtBits(ExpExtBits)
  ) u_result_asm (
      .i_exp_work        (exp_work_s5),
      .i_mantissa_work   (mantissa_work_s5),
      .i_round_up        (round_up_s5),
      .i_is_inexact      (is_inexact_s5),
      .i_result_sign     (result_sign_s5),
      .i_rm              (rm_s5),
      .i_is_special      (is_special_s5),
      .i_special_result  (special_result_s5),
      .i_special_invalid (special_invalid_s5),
      .i_special_div_zero(1'b0),
      .i_is_zero_result  (product_is_zero_s5),
      .i_zero_sign       (result_sign_s5),
      .o_result          (final_result_s5_comb),
      .o_flags           (final_flags_s5_comb)
  );

  // =========================================================================
  // Stage 5 -> Stage 6 Pipeline Register (final output)
  // =========================================================================

  logic [FP_WIDTH-1:0] result_s6;
  riscv_pkg::fp_flags_t flags_s6;
  logic valid_s1, valid_s3, valid_s3b, valid_s4, valid_s4b, valid_s5, valid_s6;

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
      valid_s6  <= 1'b0;
      for (int i = 0; i < MultLatency; i++) begin
        mult_meta_valid[i] <= 1'b0;
      end
    end else begin
      valid_s1 <= i_valid;
      valid_s2 <= valid_s1;
      valid_s3 <= product_s2_tiled_valid;
      valid_s3b <= valid_s3;
      valid_s4 <= valid_s3b;
      valid_s4b <= valid_s4;
      valid_s5 <= valid_s4b;
      valid_s6 <= valid_s5;

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
      rounding_mode_reg <= i_rounding_mode;
    end

    result_sign_s2 <= result_sign;
    tentative_exp_s2 <= tentative_exp;
    mant_a_s2 <= mant_a;
    mant_b_s2 <= mant_b;
    is_special_s2 <= is_special;
    special_result_s2 <= special_result;
    special_invalid_s2 <= special_invalid;
    rm_s2 <= rounding_mode_reg;

    mult_result_sign[0] <= result_sign_s2;
    mult_tentative_exp[0] <= tentative_exp_s2;
    mult_is_special[0] <= is_special_s2;
    mult_special_result[0] <= special_result_s2;
    mult_special_invalid[0] <= special_invalid_s2;
    mult_rm[0] <= rm_s2;
    for (int i = 1; i < MultLatency; i++) begin
      mult_result_sign[i] <= mult_result_sign[i-1];
      mult_tentative_exp[i] <= mult_tentative_exp[i-1];
      mult_is_special[i] <= mult_is_special[i-1];
      mult_special_result[i] <= mult_special_result[i-1];
      mult_special_invalid[i] <= mult_special_invalid[i-1];
      mult_rm[i] <= mult_rm[i-1];
    end

    result_sign_s3 <= mult_result_sign[MultLatency-1];
    tentative_exp_s3 <= mult_tentative_exp[MultLatency-1];
    product_s3 <= product_s2_tiled;
    is_special_s3 <= mult_is_special[MultLatency-1];
    special_result_s3 <= mult_special_result[MultLatency-1];
    special_invalid_s3 <= mult_special_invalid[MultLatency-1];
    rm_s3 <= mult_rm[MultLatency-1];

    result_sign_s3b <= result_sign_s3;
    tentative_exp_s3b <= tentative_exp_s3;
    product_s3b <= product_s3;
    product_is_zero_s3b <= product_is_zero_s3;
    product_msb_set_s3b <= product_msb_set_s3;
    lzc_s3b <= lzc_s3;
    is_special_s3b <= is_special_s3;
    special_result_s3b <= special_result_s3;
    special_invalid_s3b <= special_invalid_s3;
    rm_s3b <= rm_s3;

    result_sign_s4 <= result_sign_s3b;
    exp_s4 <= normalized_exp_s3b;
    product_s4 <= normalized_product_s3b;
    product_is_zero_s4 <= product_is_zero_s3b;
    is_special_s4 <= is_special_s3b;
    special_result_s4 <= special_result_s3b;
    special_invalid_s4 <= special_invalid_s3b;
    rm_s4 <= rm_s3b;

    mantissa_work_s4b <= mantissa_work_s4;
    guard_work_s4b <= guard_work_s4;
    round_work_s4b <= round_work_s4;
    sticky_work_s4b <= sticky_work_s4;
    exp_work_s4b <= exp_work_s4;
    result_sign_s4b <= result_sign_s4;
    product_is_zero_s4b <= product_is_zero_s4;
    rm_s4b <= rm_s4;
    is_special_s4b <= is_special_s4;
    special_result_s4b <= special_result_s4;
    special_invalid_s4b <= special_invalid_s4;

    result_sign_s5 <= result_sign_s4b;
    exp_work_s5 <= exp_work_s4b;
    mantissa_work_s5 <= mantissa_work_s4b;
    round_up_s5 <= round_up_s4b_comb;
    is_inexact_s5 <= is_inexact_s4b;
    product_is_zero_s5 <= product_is_zero_s4b;
    rm_s5 <= rm_s4b;
    is_special_s5 <= is_special_s4b;
    special_result_s5 <= special_result_s4b;
    special_invalid_s5 <= special_invalid_s4b;

    result_s6 <= final_result_s5_comb;
    flags_s6 <= final_flags_s5_comb;
  end

  assign o_valid  = valid_s6;

  // Output from registered s6
  assign o_result = result_s6;
  assign o_flags  = flags_s6;

endmodule : fp_multiplier
