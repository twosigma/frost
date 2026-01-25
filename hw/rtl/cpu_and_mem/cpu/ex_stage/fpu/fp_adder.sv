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
  IEEE 754 single-precision floating-point adder/subtractor.

  Implements FADD.S and FSUB.S operations.

  Multi-cycle implementation (10-cycle latency, non-pipelined):
    Cycle 0: Capture operands
    Cycle 1: Unpack, compute exponent difference, detect special cases
    Cycle 2: Align mantissas (barrel shift), compute sticky bits
    Cycle 3A: Add/subtract mantissas
    Cycle 3B: Leading zero detection
    Cycle 4: Normalize based on LZC, extract rounding bits
    Cycle 5A: Subnormal handling, compute rounding inputs
    Cycle 5B: Compute round-up decision
    Cycle 6: Apply rounding increment, format result
    Cycle 7: Capture result
    Cycle 8: Output registered result

  This non-pipelined design stalls the CPU for the full duration
  of the operation, ensuring operand stability without complex capture bypass.

  Special case handling:
    - NaN propagation (quiet NaN result)
    - Infinity arithmetic (+inf + (-inf) = NaN, etc.)
    - Zero handling (signed zero rules)
    - Subnormal inputs (treated as zero for simplicity)
*/
module fp_adder #(
    parameter int unsigned FP_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [FP_WIDTH-1:0] i_operand_a,
    input logic [FP_WIDTH-1:0] i_operand_b,
    input logic i_is_subtract,  // 1 for FSUB, 0 for FADD
    input logic [2:0] i_rounding_mode,
    input logic i_stall,  // Pipeline stall (unused in non-pipelined mode)
    output logic [FP_WIDTH-1:0] o_result,
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // =========================================================================
  // State Machine
  // =========================================================================

  typedef enum logic [3:0] {
    IDLE    = 4'b0000,
    STAGE1  = 4'b0001,
    STAGE2  = 4'b0010,
    STAGE3A = 4'b0011,
    STAGE3B = 4'b0100,
    STAGE4  = 4'b0101,
    STAGE5A = 4'b0110,
    STAGE5B = 4'b0111,
    STAGE6  = 4'b1000,
    STAGE7  = 4'b1001
  } state_e;

  state_e state, next_state;

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned AlignBits = MantBits * 2;
  localparam int unsigned SumBits = AlignBits + 1;
  localparam int unsigned LzcBits = $clog2(SumBits + 1);
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [ExpBits-1:0] MaxNormalExp = ExpMax - 1'b1;
  localparam logic [FracBits-1:0] MaxMant = {FracBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam logic [ExpBits-1:0] AlignBitsExp = ExpBits'(AlignBits);
  localparam logic signed [ExpExtBits:0] MantBitsPlus3Signed = {1'b0, ExpExtBits'(MantBits + 3)};
  localparam logic [LzcBits-1:0] MantBitsPlus3Shift = LzcBits'(MantBits + 3);
  localparam logic signed [ExpExtBits-1:0] ExpMaxSigned = {
    {(ExpExtBits - ExpBits - 1) {1'b0}}, 1'b0, ExpMax
  };

  // =========================================================================
  // Captured Operands (registered at start of operation)
  // =========================================================================

  logic [FP_WIDTH-1:0] operand_a_reg, operand_b_reg;
  logic       is_subtract_reg;
  logic [2:0] rounding_mode_reg;

  // =========================================================================
  // Stage 1: Unpack (combinational from captured operands)
  // =========================================================================

  logic [FP_WIDTH-1:0] op_a, op_b;
  assign op_a = operand_a_reg;
  assign op_b = operand_b_reg;

  // Unpack operands
  logic sign_a, sign_b;
  logic [ExpBits-1:0] exp_a, exp_b;
  logic [ExpBits-1:0] exp_a_adj, exp_b_adj;
  logic [MantBits-1:0] mant_a, mant_b;

  assign sign_a = op_a[FP_WIDTH-1];
  assign exp_a = op_a[FP_WIDTH-2-:ExpBits];
  assign exp_b = op_b[FP_WIDTH-2-:ExpBits];
  assign exp_a_adj = (exp_a == '0 && op_a[FracBits-1:0] != '0) ?
                     {{(ExpBits-1){1'b0}}, 1'b1} : exp_a;
  assign exp_b_adj = (exp_b == '0 && op_b[FracBits-1:0] != '0) ?
                     {{(ExpBits-1){1'b0}}, 1'b1} : exp_b;

  // For subtraction, negate B's sign
  assign sign_b = op_b[FP_WIDTH-1] ^ is_subtract_reg;

  // Mantissa with implicit 1 (or 0 for subnormal/zero)
  assign mant_a = (exp_a == '0) ? {1'b0, op_a[FracBits-1:0]} : {1'b1, op_a[FracBits-1:0]};
  assign mant_b = (exp_b == '0) ? {1'b0, op_b[FracBits-1:0]} : {1'b1, op_b[FracBits-1:0]};

  // Special value detection
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;

  assign is_zero_a = (exp_a == '0) && (op_a[FracBits-1:0] == '0);
  assign is_zero_b = (exp_b == '0) && (op_b[FracBits-1:0] == '0);
  assign is_inf_a  = (exp_a == ExpMax) && (op_a[FracBits-1:0] == '0);
  assign is_inf_b  = (exp_b == ExpMax) && (op_b[FracBits-1:0] == '0);
  assign is_nan_a  = (exp_a == ExpMax) && (op_a[FracBits-1:0] != '0);
  assign is_nan_b  = (exp_b == ExpMax) && (op_b[FracBits-1:0] != '0);
  assign is_snan_a = is_nan_a && ~op_a[FracBits-1];
  assign is_snan_b = is_nan_b && ~op_b[FracBits-1];

  // Exponent difference and swap if needed (make the larger-magnitude operand "large")
  // When exponents are equal, compare mantissas to decide the larger magnitude.
  logic [ExpBits:0] exp_diff;
  logic             swap;
  logic             exp_equal;
  logic             mant_b_gt_a;
  logic sign_large, sign_small;
  logic [ExpBits-1:0] exp_large;
  logic [MantBits-1:0] mant_large, mant_small;

  assign exp_diff = {1'b0, exp_a_adj} - {1'b0, exp_b_adj};
  assign exp_equal = (exp_a_adj == exp_b_adj);
  assign mant_b_gt_a = mant_b > mant_a;
  assign swap = exp_diff[ExpBits] | (exp_equal & mant_b_gt_a);

  always_comb begin
    if (swap) begin
      sign_large = sign_b;
      sign_small = sign_a;
      exp_large  = exp_b_adj;
      mant_large = mant_b;
      mant_small = mant_a;
    end else begin
      sign_large = sign_a;
      sign_small = sign_b;
      exp_large  = exp_a_adj;
      mant_large = mant_a;
      mant_small = mant_b;
    end
  end

  // Compute shift amount (absolute difference)
  logic [ExpBits-1:0] shift_amt;
  assign shift_amt = swap ? (-exp_diff[ExpBits-1:0]) : exp_diff[ExpBits-1:0];

  // Determine if this is effective subtraction
  logic effective_sub;
  assign effective_sub = sign_large ^ sign_small;

  // Handle special cases
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
    end else if (is_inf_a && is_inf_b) begin
      if (sign_a == sign_b) begin
        is_special = 1'b1;
        special_result = {sign_a, ExpMax, {FracBits{1'b0}}};
      end else begin
        is_special = 1'b1;
        special_result = CanonicalNan;
        special_invalid = 1'b1;
      end
    end else if (is_inf_a) begin
      is_special = 1'b1;
      special_result = {sign_a, ExpMax, {FracBits{1'b0}}};
    end else if (is_inf_b) begin
      is_special = 1'b1;
      special_result = {sign_b, ExpMax, {FracBits{1'b0}}};
    end
  end

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Register (after unpack, before align)
  // =========================================================================

  logic sign_large_s2, sign_small_s2;
  logic [ExpBits-1:0] exp_s2;
  logic [ExpBits-1:0] shift_amt_s2;
  logic [MantBits-1:0] mant_large_s2_pre, mant_small_s2_pre;
  logic                 effective_sub_s2;
  logic                 is_special_s2;
  logic [ FP_WIDTH-1:0] special_result_s2;
  logic                 special_invalid_s2;
  logic [          2:0] rm_s2;

  // =========================================================================
  // Stage 2: Align Mantissas (barrel shift)
  // =========================================================================

  logic [AlignBits-1:0] aligned_small;
  logic [AlignBits-1:0] extended_small;
  logic                 sticky_from_shift;

  assign extended_small = {mant_small_s2_pre, {MantBits{1'b0}}};

  always_comb begin
    if (shift_amt_s2 >= AlignBitsExp) begin
      aligned_small = '0;
    end else begin
      aligned_small = extended_small >> shift_amt_s2;
    end
  end

  // Compute sticky bit from shifted-out bits
  always_comb begin
    if (shift_amt_s2 >= AlignBitsExp) begin
      sticky_from_shift = |extended_small;
    end else if (shift_amt_s2 > 0) begin
      sticky_from_shift = 1'b0;
      for (int i = 0; i < AlignBits; i++) begin
        if (i < shift_amt_s2) sticky_from_shift = sticky_from_shift | extended_small[i];
      end
    end else begin
      sticky_from_shift = 1'b0;
    end
  end

  // =========================================================================
  // Stage 2 -> Stage 3 Pipeline Register (after align, before add)
  // =========================================================================

  logic sign_large_s3, sign_small_s3;
  logic [ExpBits-1:0] exp_s3;
  logic [AlignBits-1:0] mant_large_s3, mant_small_s3;
  logic                sticky_s3;
  logic                effective_sub_s3;
  logic                is_special_s3;
  logic [FP_WIDTH-1:0] special_result_s3;
  logic                special_invalid_s3;
  logic [         2:0] rm_s3;

  // =========================================================================
  // Stage 3A: Add/Subtract Mantissas (combinational from stage 3 regs)
  // =========================================================================

  logic [ SumBits-1:0] sum_s3a_comb;
  logic                result_sign_s3a_comb;

  always_comb begin
    if (effective_sub_s3) begin
      sum_s3a_comb = {1'b0, mant_large_s3} - {1'b0, mant_small_s3};
      result_sign_s3a_comb = sign_large_s3;
    end else begin
      sum_s3a_comb = {1'b0, mant_large_s3} + {1'b0, mant_small_s3};
      result_sign_s3a_comb = sign_large_s3;
    end
  end

  // =========================================================================
  // Stage 3A -> Stage 3B Pipeline Register (after add/sub, before LZC)
  // =========================================================================

  logic [SumBits-1:0] sum_s3a;
  logic               result_sign_s3a;

  // =========================================================================
  // Stage 3B: Leading zero count (combinational from stage 3A regs)
  // =========================================================================

  logic [LzcBits-1:0] lzc_s3b_comb;
  logic               sum_is_zero_s3b_comb;
  logic               lzc_found_s3b;

  always_comb begin
    lzc_s3b_comb = '0;
    sum_is_zero_s3b_comb = (sum_s3a == '0);
    lzc_found_s3b = 1'b0;

    if (!sum_is_zero_s3b_comb) begin
      for (int i = SumBits - 1; i >= 0; i--) begin
        if (!lzc_found_s3b) begin
          if (sum_s3a[i]) begin
            lzc_found_s3b = 1'b1;
          end else begin
            lzc_s3b_comb = lzc_s3b_comb + 1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Stage 3 -> Stage 4 Pipeline Register (after add/LZC, before normalize)
  // =========================================================================

  logic                         result_sign_s4;
  logic                         sign_large_s4;
  logic                         sign_small_s4;
  logic signed [ExpExtBits-1:0] exp_s4;
  logic        [   SumBits-1:0] sum_s4;
  logic        [   LzcBits-1:0] lzc_s4;
  logic                         sum_is_zero_s4;
  logic                         sticky_s4;
  logic                         is_special_s4;
  logic        [  FP_WIDTH-1:0] special_result_s4;
  logic                         special_invalid_s4;
  logic        [           2:0] rm_s4;

  // =========================================================================
  // Stage 4: Normalize (combinational from stage 4 regs)
  // =========================================================================

  logic        [   SumBits-1:0] normalized_sum_s4_comb;
  logic signed [ExpExtBits-1:0] normalized_exp_s4_comb;

  logic        [   LzcBits-1:0] norm_shift;
  assign norm_shift = (lzc_s4 > {{(LzcBits-1){1'b0}}, 1'b1}) ?
                      (lzc_s4 - {{(LzcBits-1){1'b0}}, 1'b1}) : '0;

  always_comb begin
    if (sum_is_zero_s4) begin
      normalized_sum_s4_comb = '0;
      normalized_exp_s4_comb = '0;
      // verilator lint_off WIDTHEXPAND
    end else if (sum_s4[SumBits-1]) begin
      // verilator lint_on WIDTHEXPAND
      // Overflow: shift right by 1, increment exponent
      normalized_sum_s4_comb = sum_s4 >> 1;
      normalized_exp_s4_comb = exp_s4 + 1;
      // verilator lint_off WIDTHEXPAND
    end else if (lzc_s4 > 1) begin
      // verilator lint_on WIDTHEXPAND
      normalized_sum_s4_comb = sum_s4 << norm_shift;
      normalized_exp_s4_comb = exp_s4 - $signed({{(ExpExtBits - LzcBits) {1'b0}}, norm_shift});
    end else begin
      normalized_sum_s4_comb = sum_s4;
      normalized_exp_s4_comb = exp_s4;
    end
  end

  // Guard bit for overflow case (shift right)
  logic overflow_guard_s4_comb;
  assign overflow_guard_s4_comb = sum_s4[SumBits-1] ? sum_s4[0] : 1'b0;

  // TIMING: Pre-compute subnormal shift amount in STAGE4 to reduce STAGE5A path depth
  logic                       is_subnorm_s4_comb;
  logic        [ LzcBits-1:0] subnorm_shift_amt_s4_comb;
  logic signed [ExpExtBits:0] subnorm_shift_signed_s4;

  assign is_subnorm_s4_comb = (normalized_exp_s4_comb <= 0);
  assign subnorm_shift_signed_s4 = $signed(
      {1'b0, {ExpExtBits{1'b0}}}
  ) + 1 - $signed(
      {normalized_exp_s4_comb[ExpExtBits-1], normalized_exp_s4_comb}
  );

  always_comb begin
    if (subnorm_shift_signed_s4 >= MantBitsPlus3Signed)
      subnorm_shift_amt_s4_comb = MantBitsPlus3Shift;
    else if (subnorm_shift_signed_s4 <= 0) subnorm_shift_amt_s4_comb = '0;
    else subnorm_shift_amt_s4_comb = subnorm_shift_signed_s4[LzcBits-1:0];
  end

  // =========================================================================
  // Stage 4 -> Stage 5 Pipeline Register (after normalize, before round)
  // =========================================================================

  logic                         result_sign_s5;
  logic                         sign_large_s5;
  logic                         sign_small_s5;
  logic signed [ExpExtBits-1:0] normalized_exp_s5;
  logic        [   SumBits-1:0] normalized_sum_s5;
  logic                         overflow_guard_s5;
  logic                         sum_is_zero_s5;
  logic                         sticky_s5;
  logic                         is_special_s5;
  logic        [  FP_WIDTH-1:0] special_result_s5;
  logic                         special_invalid_s5;
  logic        [           2:0] rm_s5;
  // TIMING: Pre-computed subnormal shift amount to reduce STAGE5A combinational depth
  logic        [   LzcBits-1:0] subnorm_shift_amt_s5;
  logic                         is_subnorm_s5;

  // =========================================================================
  // Stage 5A: Prepare rounding inputs (subnormal handling)
  // =========================================================================

  logic        [    MantBits:0] pre_round_mant;
  logic final_guard, final_round, final_sticky;
  localparam int unsigned GuardIndex = SumBits - MantBits - 3;

  assign pre_round_mant = normalized_sum_s5[SumBits-2-:(MantBits+1)];
  assign final_guard = overflow_guard_s5 ? overflow_guard_s5 : normalized_sum_s5[GuardIndex];
  assign final_round = overflow_guard_s5 ? 1'b0 : normalized_sum_s5[GuardIndex-1];
  assign final_sticky = overflow_guard_s5 ? sticky_s5 :
                        (|normalized_sum_s5[GuardIndex-2:0] | sticky_s5);

  // Extract mantissa and rounding bits
  logic [MantBits-1:0] mantissa_retained_s5;
  logic guard_bit_s5, round_bit_s5, sticky_bit_s5;

  assign mantissa_retained_s5 = pre_round_mant[MantBits:1];
  assign guard_bit_s5 = pre_round_mant[0];
  assign round_bit_s5 = final_guard;
  assign sticky_bit_s5 = final_round | final_sticky;

  // Subnormal handling: compute shift and apply
  // TIMING: Use pre-computed shift amount from STAGE4 to reduce combinational depth
  logic [MantBits-1:0] mantissa_work_s5a_comb;
  logic guard_work_s5a_comb, round_work_s5a_comb, sticky_work_s5a_comb;
  logic signed [ExpExtBits-1:0] exp_work_s5a_comb;
  logic [MantBits+2:0] mantissa_ext_s5a, shifted_ext_s5a;
  logic shifted_sticky_s5a;

  always_comb begin
    mantissa_work_s5a_comb = mantissa_retained_s5;
    guard_work_s5a_comb = guard_bit_s5;
    round_work_s5a_comb = round_bit_s5;
    sticky_work_s5a_comb = sticky_bit_s5;
    exp_work_s5a_comb = normalized_exp_s5;
    mantissa_ext_s5a = {mantissa_retained_s5, guard_bit_s5, round_bit_s5, sticky_bit_s5};
    shifted_ext_s5a = mantissa_ext_s5a;
    shifted_sticky_s5a = 1'b0;

    // TIMING: Use pre-computed is_subnorm_s5 and subnorm_shift_amt_s5 instead of
    // computing from normalized_exp_s5 to reduce critical path depth
    if (is_subnorm_s5) begin
      if (subnorm_shift_amt_s5 >= MantBitsPlus3Shift) begin
        shifted_ext_s5a = '0;
        shifted_sticky_s5a = |mantissa_ext_s5a;
      end else if (subnorm_shift_amt_s5 != 0) begin
        shifted_ext_s5a = mantissa_ext_s5a >> subnorm_shift_amt_s5;
        shifted_sticky_s5a = 1'b0;
        for (int i = 0; i < (MantBits + 3); i++) begin
          if (i < subnorm_shift_amt_s5)
            shifted_sticky_s5a = shifted_sticky_s5a | mantissa_ext_s5a[i];
        end
      end
      mantissa_work_s5a_comb = shifted_ext_s5a[(MantBits+2):3];
      guard_work_s5a_comb = shifted_ext_s5a[2];
      round_work_s5a_comb = shifted_ext_s5a[1];
      sticky_work_s5a_comb = shifted_ext_s5a[0] | shifted_sticky_s5a;
      exp_work_s5a_comb = '0;
    end
  end

  // =========================================================================
  // Stage 5A -> Stage 5B Pipeline Register (after subnormal handling)
  // =========================================================================

  logic [MantBits-1:0] mantissa_work_s5b;
  logic guard_work_s5b, round_work_s5b, sticky_work_s5b;
  logic signed [ExpExtBits-1:0] exp_work_s5b;

  // Stage 5B: Compute round-up decision (combinational)
  logic round_up_s5b_comb;
  logic lsb_s5b;

  assign lsb_s5b = mantissa_work_s5b[0];

  always_comb begin
    unique case (rm_s5)
      riscv_pkg::FRM_RNE:
      round_up_s5b_comb = guard_work_s5b & (round_work_s5b | sticky_work_s5b | lsb_s5b);
      riscv_pkg::FRM_RTZ: round_up_s5b_comb = 1'b0;
      riscv_pkg::FRM_RDN:
      round_up_s5b_comb = result_sign_s5 & (guard_work_s5b | round_work_s5b | sticky_work_s5b);
      riscv_pkg::FRM_RUP:
      round_up_s5b_comb = ~result_sign_s5 & (guard_work_s5b | round_work_s5b | sticky_work_s5b);
      riscv_pkg::FRM_RMM: round_up_s5b_comb = guard_work_s5b;
      default: round_up_s5b_comb = guard_work_s5b & (round_work_s5b | sticky_work_s5b | lsb_s5b);
    endcase
  end

  // Compute is_inexact for flags
  logic is_inexact_s5b;
  assign is_inexact_s5b = guard_work_s5b | round_work_s5b | sticky_work_s5b;

  // =========================================================================
  // Stage 5 -> Stage 6 Pipeline Register (after round-up decision)
  // =========================================================================

  logic                         result_sign_s6;
  logic signed [ExpExtBits-1:0] exp_work_s6;
  logic        [  MantBits-1:0] mantissa_work_s6;
  logic                         round_up_s6;
  logic                         is_inexact_s6;
  logic                         sum_is_zero_s6;
  logic                         sticky_s6_saved;
  logic                         sign_large_s6;
  logic                         sign_small_s6;
  logic        [           2:0] rm_s6;
  logic                         is_special_s6;
  logic        [  FP_WIDTH-1:0] special_result_s6;
  logic                         special_invalid_s6;

  // =========================================================================
  // Stage 6: Apply rounding and format result (combinational from s6 regs)
  // =========================================================================

  logic        [    MantBits:0] rounded_mantissa_s6;
  logic                         mantissa_overflow_s6;
  logic signed [ExpExtBits-1:0] adjusted_exponent_s6;
  logic        [  FracBits-1:0] final_mantissa_s6;
  logic is_overflow_s6, is_underflow_s6;

  assign rounded_mantissa_s6  = {1'b0, mantissa_work_s6} + {{MantBits{1'b0}}, round_up_s6};
  assign mantissa_overflow_s6 = rounded_mantissa_s6[MantBits];

  always_comb begin
    if (mantissa_overflow_s6) begin
      if (exp_work_s6 == '0) begin
        adjusted_exponent_s6 = {{(ExpExtBits - 1) {1'b0}}, 1'b1};
      end else begin
        adjusted_exponent_s6 = exp_work_s6 + 1;
      end
      final_mantissa_s6 = rounded_mantissa_s6[MantBits-1:1];
    end else begin
      adjusted_exponent_s6 = exp_work_s6;
      final_mantissa_s6 = rounded_mantissa_s6[FracBits-1:0];
    end
  end

  assign is_overflow_s6  = (adjusted_exponent_s6 >= ExpMaxSigned);
  assign is_underflow_s6 = (adjusted_exponent_s6 <= '0);

  // Compute final result
  logic [FP_WIDTH-1:0] final_result_s6_comb;
  riscv_pkg::fp_flags_t final_flags_s6_comb;
  logic zero_sign_s6;

  always_comb begin
    zero_sign_s6 = (rm_s6 == riscv_pkg::FRM_RDN) ? 1'b1 : 1'b0;
    final_result_s6_comb = '0;
    final_flags_s6_comb = '0;

    if (is_special_s6) begin
      final_result_s6_comb   = special_result_s6;
      final_flags_s6_comb.nv = special_invalid_s6;
    end else if (sum_is_zero_s6 && !sticky_s6_saved) begin
      if (sign_large_s6 == sign_small_s6) zero_sign_s6 = sign_large_s6;
      final_result_s6_comb = {zero_sign_s6, {(FP_WIDTH - 1) {1'b0}}};
    end else if (is_overflow_s6) begin
      final_flags_s6_comb.of = 1'b1;
      final_flags_s6_comb.nx = 1'b1;
      if ((rm_s6 == riscv_pkg::FRM_RTZ) ||
          (rm_s6 == riscv_pkg::FRM_RDN && !result_sign_s6) ||
          (rm_s6 == riscv_pkg::FRM_RUP && result_sign_s6)) begin
        final_result_s6_comb = {result_sign_s6, MaxNormalExp, MaxMant};
      end else begin
        final_result_s6_comb = {result_sign_s6, ExpMax, {FracBits{1'b0}}};
      end
    end else if (is_underflow_s6) begin
      final_flags_s6_comb.uf = is_inexact_s6;
      final_flags_s6_comb.nx = is_inexact_s6;
      final_result_s6_comb   = {result_sign_s6, {ExpBits{1'b0}}, final_mantissa_s6};
    end else begin
      final_flags_s6_comb.nx = is_inexact_s6;
      final_result_s6_comb = {result_sign_s6, adjusted_exponent_s6[ExpBits-1:0], final_mantissa_s6};
    end
  end

  // =========================================================================
  // Stage 6 -> Stage 7 Pipeline Register (final output)
  // =========================================================================

  logic [FP_WIDTH-1:0] result_s7;
  riscv_pkg::fp_flags_t flags_s7;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      operand_a_reg <= '0;
      operand_b_reg <= '0;
      is_subtract_reg <= 1'b0;
      rounding_mode_reg <= 3'b0;
      // Stage 2 registers
      sign_large_s2 <= 1'b0;
      sign_small_s2 <= 1'b0;
      exp_s2 <= '0;
      shift_amt_s2 <= '0;
      mant_large_s2_pre <= '0;
      mant_small_s2_pre <= '0;
      effective_sub_s2 <= 1'b0;
      is_special_s2 <= 1'b0;
      special_result_s2 <= '0;
      special_invalid_s2 <= 1'b0;
      rm_s2 <= 3'b0;
      // Stage 3 registers
      sign_large_s3 <= 1'b0;
      sign_small_s3 <= 1'b0;
      exp_s3 <= '0;
      mant_large_s3 <= '0;
      mant_small_s3 <= '0;
      sticky_s3 <= 1'b0;
      effective_sub_s3 <= 1'b0;
      is_special_s3 <= 1'b0;
      special_result_s3 <= '0;
      special_invalid_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      // Stage 3A registers
      sum_s3a <= '0;
      result_sign_s3a <= 1'b0;
      // Stage 4 registers
      result_sign_s4 <= 1'b0;
      sign_large_s4 <= 1'b0;
      sign_small_s4 <= 1'b0;
      exp_s4 <= '0;
      sum_s4 <= '0;
      lzc_s4 <= '0;
      sum_is_zero_s4 <= 1'b0;
      sticky_s4 <= 1'b0;
      is_special_s4 <= 1'b0;
      special_result_s4 <= '0;
      special_invalid_s4 <= 1'b0;
      rm_s4 <= 3'b0;
      // Stage 5 registers
      result_sign_s5 <= 1'b0;
      sign_large_s5 <= 1'b0;
      sign_small_s5 <= 1'b0;
      normalized_exp_s5 <= '0;
      normalized_sum_s5 <= '0;
      overflow_guard_s5 <= 1'b0;
      sum_is_zero_s5 <= 1'b0;
      sticky_s5 <= 1'b0;
      is_special_s5 <= 1'b0;
      special_result_s5 <= '0;
      special_invalid_s5 <= 1'b0;
      rm_s5 <= 3'b0;
      subnorm_shift_amt_s5 <= '0;
      is_subnorm_s5 <= 1'b0;
      // Stage 5B registers (after subnormal handling)
      mantissa_work_s5b <= '0;
      guard_work_s5b <= 1'b0;
      round_work_s5b <= 1'b0;
      sticky_work_s5b <= 1'b0;
      exp_work_s5b <= '0;
      // Stage 6 registers (after round-up decision)
      result_sign_s6 <= 1'b0;
      exp_work_s6 <= '0;
      mantissa_work_s6 <= '0;
      round_up_s6 <= 1'b0;
      is_inexact_s6 <= 1'b0;
      sum_is_zero_s6 <= 1'b0;
      sticky_s6_saved <= 1'b0;
      sign_large_s6 <= 1'b0;
      sign_small_s6 <= 1'b0;
      rm_s6 <= 3'b0;
      is_special_s6 <= 1'b0;
      special_result_s6 <= '0;
      special_invalid_s6 <= 1'b0;
      // Stage 7 registers (final output)
      result_s7 <= '0;
      flags_s7 <= '0;
    end else begin
      state <= next_state;

      case (state)
        IDLE: begin
          if (i_valid) begin
            // Capture operands at start of operation
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            is_subtract_reg <= i_is_subtract;
            rounding_mode_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          // Capture stage 1 results into stage 2 registers
          sign_large_s2 <= sign_large;
          sign_small_s2 <= sign_small;
          exp_s2 <= exp_large;
          shift_amt_s2 <= shift_amt;
          mant_large_s2_pre <= mant_large;
          mant_small_s2_pre <= mant_small;
          effective_sub_s2 <= effective_sub;
          is_special_s2 <= is_special;
          special_result_s2 <= special_result;
          special_invalid_s2 <= special_invalid;
          rm_s2 <= rounding_mode_reg;
        end

        STAGE2: begin
          // Capture stage 2 results into stage 3 registers
          sign_large_s3 <= sign_large_s2;
          sign_small_s3 <= sign_small_s2;
          exp_s3 <= exp_s2;
          mant_large_s3 <= {mant_large_s2_pre, {MantBits{1'b0}}};
          mant_small_s3 <= aligned_small;
          sticky_s3 <= sticky_from_shift;
          effective_sub_s3 <= effective_sub_s2;
          is_special_s3 <= is_special_s2;
          special_result_s3 <= special_result_s2;
          special_invalid_s3 <= special_invalid_s2;
          rm_s3 <= rm_s2;
        end

        STAGE3A: begin
          // Capture stage 3A results into stage 3B registers
          sum_s3a <= sum_s3a_comb;
          result_sign_s3a <= result_sign_s3a_comb;
        end

        STAGE3B: begin
          // Capture stage 3B results into stage 4 registers
          result_sign_s4 <= result_sign_s3a;
          sign_large_s4 <= sign_large_s3;
          sign_small_s4 <= sign_small_s3;
          exp_s4 <= {{(ExpExtBits - ExpBits) {1'b0}}, exp_s3};
          sum_s4 <= sum_s3a;
          lzc_s4 <= lzc_s3b_comb;
          sum_is_zero_s4 <= sum_is_zero_s3b_comb;
          sticky_s4 <= sticky_s3;
          is_special_s4 <= is_special_s3;
          special_result_s4 <= special_result_s3;
          special_invalid_s4 <= special_invalid_s3;
          rm_s4 <= rm_s3;
        end

        STAGE4: begin
          // Capture stage 4 normalization into stage 5 registers
          result_sign_s5 <= result_sign_s4;
          sign_large_s5 <= sign_large_s4;
          sign_small_s5 <= sign_small_s4;
          normalized_exp_s5 <= normalized_exp_s4_comb;
          normalized_sum_s5 <= normalized_sum_s4_comb;
          overflow_guard_s5 <= overflow_guard_s4_comb;
          sum_is_zero_s5 <= sum_is_zero_s4;
          sticky_s5 <= sticky_s4;
          is_special_s5 <= is_special_s4;
          special_result_s5 <= special_result_s4;
          special_invalid_s5 <= special_invalid_s4;
          rm_s5 <= rm_s4;
          // TIMING: Pre-computed subnormal handling values
          subnorm_shift_amt_s5 <= subnorm_shift_amt_s4_comb;
          is_subnorm_s5 <= is_subnorm_s4_comb;
        end

        STAGE5A: begin
          // Capture subnormal handling outputs into stage 5B registers
          mantissa_work_s5b <= mantissa_work_s5a_comb;
          guard_work_s5b <= guard_work_s5a_comb;
          round_work_s5b <= round_work_s5a_comb;
          sticky_work_s5b <= sticky_work_s5a_comb;
          exp_work_s5b <= exp_work_s5a_comb;
        end

        STAGE5B: begin
          // Capture round-up decision and inputs into s6 registers
          result_sign_s6 <= result_sign_s5;
          exp_work_s6 <= exp_work_s5b;
          mantissa_work_s6 <= mantissa_work_s5b;
          round_up_s6 <= round_up_s5b_comb;
          is_inexact_s6 <= is_inexact_s5b;
          sum_is_zero_s6 <= sum_is_zero_s5;
          sticky_s6_saved <= sticky_s5;
          sign_large_s6 <= sign_large_s5;
          sign_small_s6 <= sign_small_s5;
          rm_s6 <= rm_s5;
          is_special_s6 <= is_special_s5;
          special_result_s6 <= special_result_s5;
          special_invalid_s6 <= special_invalid_s5;
        end

        STAGE6: begin
          // Capture final result into output registers
          result_s7 <= final_result_s6_comb;
          flags_s7  <= final_flags_s6_comb;
        end

        STAGE7: begin
          // Output stage - result already captured
        end

        default: ;
      endcase
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;
    case (state)
      IDLE: if (i_valid) next_state = STAGE1;
      STAGE1: next_state = STAGE2;
      STAGE2: next_state = STAGE3A;
      STAGE3A: next_state = STAGE3B;
      STAGE3B: next_state = STAGE4;
      STAGE4: next_state = STAGE5A;
      STAGE5A: next_state = STAGE5B;
      STAGE5B: next_state = STAGE6;
      STAGE6: next_state = STAGE7;
      STAGE7: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Output Logic
  // =========================================================================

  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *) logic valid_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) valid_reg <= 1'b0;
    else valid_reg <= (state == STAGE7);
  end
  assign o_valid  = valid_reg;

  // Output from registered stage 7
  assign o_result = result_s7;
  assign o_flags  = flags_s7;

endmodule : fp_adder
