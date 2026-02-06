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
  IEEE 754 single-precision floating-point divider.

  Implements FDIV.S operation using a sequential radix-2 restoring division algorithm.

  Latency: 36 cycles (not pipelined, stalls pipeline during operation)
    - 1 cycle: Input capture (IDLE)
    - 1 cycle: Operand unpacking and LZC (UNPACK)
    - 1 cycle: Mantissa normalization and special case detection (INIT)
    - 1 cycle: Division initialization (SETUP)
    - 26 cycles: Mantissa division (1 integer bit + 26 fractional/guard bits)
    - 1 cycle: Normalization prep (capture LZC)
    - 1 cycle: Normalization apply
    - 1 cycle: Subnormal handling and shift prep
    - 1 cycle: Compute round-up decision
    - 1 cycle: Apply rounding increment, format result
    - 1 cycle: Output registered result

  The UNPACK/INIT/SETUP pipeline stages split the operand processing to reduce
  combinational depth and improve timing (reduces net delay from wide datapath).

  Special case handling:
    - NaN propagation
    - Divide by zero (returns infinity, raises DZ flag)
    - 0/0 = NaN (invalid)
    - inf/inf = NaN (invalid)
    - x/0 = infinity (for finite non-zero x)
    - 0/x = 0 (for finite non-zero x)
*/
module fp_divider #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_valid,
    input  logic                 [FP_WIDTH-1:0] i_operand_a,      // Dividend
    input  logic                 [FP_WIDTH-1:0] i_operand_b,      // Divisor
    input  logic                 [         2:0] i_rounding_mode,
    output logic                 [FP_WIDTH-1:0] o_result,
    output logic                                o_valid,
    output logic                                o_stall,          // Stall pipeline during division
    output riscv_pkg::fp_flags_t                o_flags
);

  // State machine - expanded for pipelined SETUP
  typedef enum logic [3:0] {
    IDLE,
    UNPACK,
    INIT,
    SETUP,
    DIVIDE,
    NORMALIZE_PREP,
    NORMALIZE,
    ROUND_SHIFT,
    ROUND_PREP,
    ROUND_APPLY,
    OUTPUT,
    DONE
  } state_t;

  state_t state, next_state;
  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned DivBits = MantBits + 3;  // mantissa + guard bits
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcMantBits = $clog2(FracBits + 1);
  localparam int unsigned QuotLzcBits = $clog2(DivBits + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [ExpBits-1:0] MaxNormalExp = ExpMax - 1'b1;
  localparam logic [FracBits-1:0] MaxMant = {FracBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam int unsigned DivCycles = MantBits + 2;
  localparam int unsigned CycleCountBits = $clog2(DivCycles + 1);
  localparam logic signed [ExpExtBits-1:0] ExpBiasExt = ExpExtBits'(ExpBias);
  localparam logic signed [ExpExtBits-1:0] ExpMaxSigned = {
    {(ExpExtBits - ExpBits - 1) {1'b0}}, 1'b0, ExpMax
  };
  localparam logic [CycleCountBits-1:0] DivCyclesMinus1 = CycleCountBits'(DivCycles - 1);

  logic [CycleCountBits-1:0] cycle_count;

  // Registered inputs
  logic [FP_WIDTH-1:0] operand_a_reg;
  logic [FP_WIDTH-1:0] operand_b_reg;

  // =========================================================================
  // UNPACK Stage: Classification and LZC (combinational from operand_*_reg)
  // =========================================================================

  logic sign_a, sign_b;
  logic [ExpBits-1:0] exp_a, exp_b;
  logic [LzcMantBits-1:0] mant_lzc_a, mant_lzc_b;
  logic is_subnormal_a, is_subnormal_b;
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;

  assign sign_a = operand_a_reg[FP_WIDTH-1];
  assign sign_b = operand_b_reg[FP_WIDTH-1];
  assign exp_a  = operand_a_reg[FP_WIDTH-2-:ExpBits];
  assign exp_b  = operand_b_reg[FP_WIDTH-2-:ExpBits];

  // Classification
  fp_classify_operand #(
      .EXP_BITS (ExpBits),
      .FRAC_BITS(FracBits)
  ) u_classify_a (
      .i_exp(exp_a),
      .i_frac(operand_a_reg[FracBits-1:0]),
      .o_is_zero(is_zero_a),
      .o_is_subnormal(is_subnormal_a),
      .o_is_inf(is_inf_a),
      .o_is_nan(is_nan_a),
      .o_is_snan(is_snan_a)
  );
  fp_classify_operand #(
      .EXP_BITS (ExpBits),
      .FRAC_BITS(FracBits)
  ) u_classify_b (
      .i_exp(exp_b),
      .i_frac(operand_b_reg[FracBits-1:0]),
      .o_is_zero(is_zero_b),
      .o_is_subnormal(is_subnormal_b),
      .o_is_inf(is_inf_b),
      .o_is_nan(is_nan_b),
      .o_is_snan(is_snan_b)
  );

  // Leading zero count for subnormal normalization
  logic mant_lzc_zero_a, mant_lzc_zero_b;

  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc_a (
      .i_value (operand_a_reg[FracBits-1:0]),
      .o_lzc   (mant_lzc_a),
      .o_is_zero(mant_lzc_zero_a)
  );
  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc_b (
      .i_value (operand_b_reg[FracBits-1:0]),
      .o_lzc   (mant_lzc_b),
      .o_is_zero(mant_lzc_zero_b)
  );

  // =========================================================================
  // UNPACK -> INIT Pipeline Registers
  // =========================================================================

  logic sign_a_r, sign_b_r;
  logic [ExpBits-1:0] exp_a_r, exp_b_r;
  logic [LzcMantBits-1:0] mant_lzc_a_r, mant_lzc_b_r;
  logic is_subnormal_a_r, is_subnormal_b_r;
  logic is_zero_a_r, is_zero_b_r;
  logic is_inf_a_r, is_inf_b_r;
  logic is_nan_a_r, is_nan_b_r;
  logic is_snan_a_r, is_snan_b_r;
  logic [FracBits-1:0] raw_mant_a_r, raw_mant_b_r;

  // =========================================================================
  // INIT Stage: Mantissa Normalization and Special Case Detection
  // Uses registered values from UNPACK stage
  // =========================================================================

  logic [LzcMantBits:0] sub_shift_a, sub_shift_b;
  logic signed [ExpExtBits-1:0] exp_a_adj, exp_b_adj;
  logic [MantBits-1:0] mant_a, mant_b;
  logic is_special_init;
  logic [FP_WIDTH-1:0] special_result_init;
  logic special_invalid_init;
  logic special_div_zero_init;

  always_comb begin
    sub_shift_a = '0;
    sub_shift_b = '0;
    exp_a_adj = '0;
    exp_b_adj = '0;
    mant_a = '0;
    mant_b = '0;

    // Operand A normalization using registered LZC
    if (is_subnormal_a_r) begin
      sub_shift_a = {1'b0, mant_lzc_a_r} + {{LzcMantBits{1'b0}}, 1'b1};
      exp_a_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, sub_shift_a});
      mant_a = {1'b0, raw_mant_a_r} << sub_shift_a;
    end else if (exp_a_r == '0) begin
      // Zero
      exp_a_adj = '0;
      mant_a = '0;
    end else begin
      // Normal
      exp_a_adj = $signed({{(ExpExtBits - ExpBits) {1'b0}}, exp_a_r});
      mant_a = {1'b1, raw_mant_a_r};
    end

    // Operand B normalization using registered LZC
    if (is_subnormal_b_r) begin
      sub_shift_b = {1'b0, mant_lzc_b_r} + {{LzcMantBits{1'b0}}, 1'b1};
      exp_b_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, sub_shift_b});
      mant_b = {1'b0, raw_mant_b_r} << sub_shift_b;
    end else if (exp_b_r == '0) begin
      // Zero
      exp_b_adj = '0;
      mant_b = '0;
    end else begin
      // Normal
      exp_b_adj = $signed({{(ExpExtBits - ExpBits) {1'b0}}, exp_b_r});
      mant_b = {1'b1, raw_mant_b_r};
    end

    // Special case detection using registered classification flags
    is_special_init = 1'b0;
    special_result_init = '0;
    special_invalid_init = 1'b0;
    special_div_zero_init = 1'b0;

    if (is_nan_a_r || is_nan_b_r) begin
      is_special_init = 1'b1;
      special_result_init = CanonicalNan;
      special_invalid_init = is_snan_a_r | is_snan_b_r;
    end else if (is_inf_a_r && is_inf_b_r) begin
      // inf / inf = NaN
      is_special_init = 1'b1;
      special_result_init = CanonicalNan;
      special_invalid_init = 1'b1;
    end else if (is_zero_a_r && is_zero_b_r) begin
      // 0 / 0 = NaN
      is_special_init = 1'b1;
      special_result_init = CanonicalNan;
      special_invalid_init = 1'b1;
    end else if (is_inf_a_r) begin
      // inf / x = inf
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, ExpMax, {FracBits{1'b0}}};
    end else if (is_inf_b_r) begin
      // x / inf = 0
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, {(FP_WIDTH - 1) {1'b0}}};
    end else if (is_zero_b_r) begin
      // x / 0 = inf (divide by zero)
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, ExpMax, {FracBits{1'b0}}};
      special_div_zero_init = ~is_zero_a_r;
    end else if (is_zero_a_r) begin
      // 0 / x = 0
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, {(FP_WIDTH - 1) {1'b0}}};
    end
  end

  // =========================================================================
  // INIT -> SETUP Pipeline Registers
  // =========================================================================

  logic result_sign_r;
  logic signed [ExpExtBits-1:0] exp_a_adj_r, exp_b_adj_r;
  logic [MantBits-1:0] mant_a_r, mant_b_r;
  logic                         is_special_r;
  logic        [  FP_WIDTH-1:0] special_result_r;
  logic                         special_invalid_r;
  logic                         special_div_zero_r;

  // =========================================================================
  // Division state
  // =========================================================================

  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *)logic signed [ExpExtBits-1:0] result_exp;
  logic        [   DivBits-1:0] quotient;  // mantissa + guard bits
  logic        [   DivBits-1:0] remainder;
  logic        [   DivBits-1:0] divisor;

  // Rounding mode storage
  logic        [           2:0] rm;

  // Rounding inputs
  logic        [    MantBits:0] div_pre_round_mant;
  logic                         div_guard_bit;
  logic                         div_round_bit;
  logic                         div_sticky_bit;
  logic                         div_is_zero;

  assign div_pre_round_mant = quotient[DivBits-1-:(MantBits+1)];
  assign div_guard_bit = quotient[1];
  assign div_round_bit = quotient[0];
  assign div_sticky_bit = |remainder;
  assign div_is_zero = (quotient == '0) && (remainder == '0);

  // =========================================================================
  // ROUND_SHIFT prep: Subnormal handling and rounding bit extraction
  // =========================================================================

  // Extract mantissa and rounding bits
  logic [MantBits-1:0] mantissa_retained_prep;
  assign mantissa_retained_prep = div_pre_round_mant[MantBits:1];

  // Subnormal handling: compute shift and apply
  logic [MantBits-1:0] mantissa_work_prep;
  logic guard_work_prep, round_work_prep, sticky_work_prep;
  logic signed [ExpExtBits-1:0] exp_work_prep;

  fp_subnorm_shift #(
      .MANT_BITS   (MantBits),
      .EXP_EXT_BITS(ExpExtBits)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained_prep),
      .i_guard   (div_pre_round_mant[0]),
      .i_round   (div_guard_bit),
      .i_sticky  (div_round_bit | div_sticky_bit),
      .i_exponent(result_exp),
      .o_mantissa(mantissa_work_prep),
      .o_guard   (guard_work_prep),
      .o_round   (round_work_prep),
      .o_sticky  (sticky_work_prep),
      .o_exponent(exp_work_prep)
  );

  // =========================================================================
  // ROUND_SHIFT -> ROUND_PREP Pipeline Registers
  // =========================================================================

  logic signed [ExpExtBits-1:0] exp_work_shift;
  logic        [  MantBits-1:0] mantissa_work_shift;
  logic                         guard_work_shift;
  logic                         round_work_shift;
  logic                         sticky_work_shift;
  logic                         div_is_zero_shift;
  logic        [           2:0] rm_shift;

  // Compute round-up decision
  logic                         round_up_prep;
  logic                         lsb_prep;

  assign lsb_prep = mantissa_work_shift[0];

  assign round_up_prep = riscv_pkg::fp_compute_round_up(
      rm_shift, guard_work_shift, round_work_shift, sticky_work_shift, lsb_prep, result_sign_r
  );

  // Compute is_inexact for flags
  logic is_inexact_prep;
  assign is_inexact_prep = guard_work_shift | round_work_shift | sticky_work_shift;

  // =========================================================================
  // ROUND_PREP -> ROUND_APPLY Pipeline Registers
  // =========================================================================

  logic                         result_sign_apply;
  logic signed [ExpExtBits-1:0] exp_work_apply;
  logic        [  MantBits-1:0] mantissa_work_apply;
  logic                         round_up_apply;
  logic                         is_inexact_apply;
  logic                         div_is_zero_apply;
  logic        [           2:0] rm_apply;

  // =========================================================================
  // ROUND_APPLY: Apply rounding and format result
  // =========================================================================

  logic        [    MantBits:0] rounded_mantissa_apply;
  logic                         mantissa_overflow_apply;
  logic signed [ExpExtBits-1:0] adjusted_exponent_apply;
  logic        [  FracBits-1:0] final_mantissa_apply;
  logic is_overflow_apply, is_underflow_apply;

  assign rounded_mantissa_apply  = {1'b0, mantissa_work_apply} + {{MantBits{1'b0}}, round_up_apply};
  assign mantissa_overflow_apply = rounded_mantissa_apply[MantBits];

  always_comb begin
    if (mantissa_overflow_apply) begin
      if (exp_work_apply == '0) begin
        adjusted_exponent_apply = {{(ExpExtBits - 1) {1'b0}}, 1'b1};
      end else begin
        adjusted_exponent_apply = exp_work_apply + 1;
      end
      final_mantissa_apply = rounded_mantissa_apply[MantBits-1:1];
    end else begin
      adjusted_exponent_apply = exp_work_apply;
      final_mantissa_apply = rounded_mantissa_apply[FracBits-1:0];
    end
  end

  assign is_overflow_apply  = (adjusted_exponent_apply >= ExpMaxSigned);
  assign is_underflow_apply = (adjusted_exponent_apply <= '0);

  // Compute final result
  logic [FP_WIDTH-1:0] final_result_apply_comb;
  riscv_pkg::fp_flags_t final_flags_apply_comb;

  always_comb begin
    final_result_apply_comb = '0;
    final_flags_apply_comb  = '0;

    if (div_is_zero_apply) begin
      final_result_apply_comb = {result_sign_apply, {(FP_WIDTH - 1) {1'b0}}};
    end else if (is_overflow_apply) begin
      final_flags_apply_comb.of = 1'b1;
      final_flags_apply_comb.nx = 1'b1;
      if ((rm_apply == riscv_pkg::FRM_RTZ) ||
          (rm_apply == riscv_pkg::FRM_RDN && !result_sign_apply) ||
          (rm_apply == riscv_pkg::FRM_RUP && result_sign_apply)) begin
        final_result_apply_comb = {result_sign_apply, MaxNormalExp, MaxMant};
      end else begin
        final_result_apply_comb = {result_sign_apply, ExpMax, {FracBits{1'b0}}};
      end
    end else if (is_underflow_apply) begin
      final_flags_apply_comb.uf = is_inexact_apply;
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb   = {result_sign_apply, {ExpBits{1'b0}}, final_mantissa_apply};
    end else begin
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb = {
        result_sign_apply, adjusted_exponent_apply[ExpBits-1:0], final_mantissa_apply
      };
    end
  end

  // =========================================================================
  // ROUND_APPLY -> OUTPUT Pipeline Registers
  // =========================================================================

  logic [FP_WIDTH-1:0] result_output;
  riscv_pkg::fp_flags_t flags_output;

  // =========================================================================
  // State Machine
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      IDLE: begin
        if (i_valid) begin
          next_state = UNPACK;
        end
      end
      UNPACK: begin
        next_state = INIT;
      end
      INIT: begin
        // Always go to SETUP - is_special_r will be valid there
        next_state = SETUP;
      end
      SETUP: begin
        // is_special_r is now valid (registered in INIT)
        if (is_special_r) begin
          next_state = DONE;
        end else begin
          next_state = DIVIDE;
        end
      end
      DIVIDE: begin
        if (cycle_count == DivCyclesMinus1) begin
          next_state = NORMALIZE_PREP;
        end
      end
      NORMALIZE_PREP: begin
        next_state = NORMALIZE;
      end
      NORMALIZE: begin
        next_state = ROUND_SHIFT;
      end
      ROUND_SHIFT: begin
        next_state = ROUND_PREP;
      end
      ROUND_PREP: begin
        next_state = ROUND_APPLY;
      end
      ROUND_APPLY: begin
        next_state = OUTPUT;
      end
      OUTPUT: begin
        next_state = DONE;
      end
      DONE: begin
        next_state = IDLE;
      end
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Division Logic
  // =========================================================================

  logic [    DivBits-1:0] next_quotient;
  logic [    DivBits-1:0] next_remainder;
  logic [    DivBits-1:0] shifted_remainder;
  logic [    DivBits-1:0] diff;
  logic                   diff_neg;
  logic [QuotLzcBits-1:0] quotient_lzc;
  logic                   quotient_is_zero;

  always_comb begin
    shifted_remainder = {remainder[DivBits-2:0], 1'b0};
    diff = shifted_remainder - divisor;
    diff_neg = diff[DivBits-1];

    if (diff_neg) begin
      // Remainder < divisor: quotient bit is 0
      next_remainder = shifted_remainder;
      next_quotient  = {quotient[DivBits-2:0], 1'b0};
    end else begin
      // Remainder >= divisor: quotient bit is 1
      next_remainder = diff;
      next_quotient  = {quotient[DivBits-2:0], 1'b1};
    end
  end

  // Leading-zero count for quotient normalization
  fp_lzc #(
      .WIDTH(DivBits)
  ) u_quot_lzc (
      .i_value (quotient),
      .o_lzc   (quotient_lzc),
      .o_is_zero(quotient_is_zero)
  );

  // Pre-compute normalization results to avoid quotient-driven clock-enables
  logic        [    DivBits-1:0] quotient_norm;
  logic signed [ ExpExtBits-1:0] result_exp_norm;
  logic        [QuotLzcBits-1:0] quotient_lzc_r;
  logic                          quotient_is_zero_r;

  always_comb begin
    quotient_norm   = quotient;
    result_exp_norm = result_exp;
    if (!quotient_is_zero_r && quotient_lzc_r != 0) begin
      quotient_norm = quotient << quotient_lzc_r;
      result_exp_norm = result_exp - $signed({{(ExpExtBits - QuotLzcBits) {1'b0}}, quotient_lzc_r});
    end
  end

  // =========================================================================
  // Main Datapath
  // =========================================================================

  logic [FP_WIDTH-1:0] result_reg;
  riscv_pkg::fp_flags_t flags_reg;
  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *) logic valid_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_count <= '0;
      quotient <= '0;
      remainder <= '0;
      divisor <= '0;
      result_exp <= '0;
      rm <= 3'b0;
      operand_a_reg <= '0;
      operand_b_reg <= '0;
      // UNPACK -> INIT registers
      sign_a_r <= 1'b0;
      sign_b_r <= 1'b0;
      exp_a_r <= '0;
      exp_b_r <= '0;
      mant_lzc_a_r <= '0;
      mant_lzc_b_r <= '0;
      is_subnormal_a_r <= 1'b0;
      is_subnormal_b_r <= 1'b0;
      is_zero_a_r <= 1'b0;
      is_zero_b_r <= 1'b0;
      is_inf_a_r <= 1'b0;
      is_inf_b_r <= 1'b0;
      is_nan_a_r <= 1'b0;
      is_nan_b_r <= 1'b0;
      is_snan_a_r <= 1'b0;
      is_snan_b_r <= 1'b0;
      raw_mant_a_r <= '0;
      raw_mant_b_r <= '0;
      // INIT -> SETUP registers
      result_sign_r <= 1'b0;
      exp_a_adj_r <= '0;
      exp_b_adj_r <= '0;
      mant_a_r <= '0;
      mant_b_r <= '0;
      is_special_r <= 1'b0;
      special_result_r <= '0;
      special_invalid_r <= 1'b0;
      special_div_zero_r <= 1'b0;
      // ROUND_SHIFT -> ROUND_PREP registers
      exp_work_shift <= '0;
      mantissa_work_shift <= '0;
      guard_work_shift <= 1'b0;
      round_work_shift <= 1'b0;
      sticky_work_shift <= 1'b0;
      div_is_zero_shift <= 1'b0;
      rm_shift <= 3'b0;
      // NORMALIZE prep registers
      quotient_lzc_r <= '0;
      quotient_is_zero_r <= 1'b0;
      // ROUND_PREP -> ROUND_APPLY registers
      result_sign_apply <= 1'b0;
      exp_work_apply <= '0;
      mantissa_work_apply <= '0;
      round_up_apply <= 1'b0;
      is_inexact_apply <= 1'b0;
      div_is_zero_apply <= 1'b0;
      rm_apply <= 3'b0;
      // ROUND_APPLY -> OUTPUT registers
      result_output <= '0;
      flags_output <= '0;
      // Final output
      result_reg <= '0;
      flags_reg <= '0;
      valid_reg <= 1'b0;
    end else begin
      valid_reg <= 1'b0;

      case (state)
        IDLE: begin
          if (i_valid) begin
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            rm <= i_rounding_mode;
            cycle_count <= '0;
          end
        end

        UNPACK: begin
          // Register operand classification and LZC results
          sign_a_r <= sign_a;
          sign_b_r <= sign_b;
          exp_a_r <= exp_a;
          exp_b_r <= exp_b;
          mant_lzc_a_r <= mant_lzc_a;
          mant_lzc_b_r <= mant_lzc_b;
          is_subnormal_a_r <= is_subnormal_a;
          is_subnormal_b_r <= is_subnormal_b;
          is_zero_a_r <= is_zero_a;
          is_zero_b_r <= is_zero_b;
          is_inf_a_r <= is_inf_a;
          is_inf_b_r <= is_inf_b;
          is_nan_a_r <= is_nan_a;
          is_nan_b_r <= is_nan_b;
          is_snan_a_r <= is_snan_a;
          is_snan_b_r <= is_snan_b;
          raw_mant_a_r <= operand_a_reg[FracBits-1:0];
          raw_mant_b_r <= operand_b_reg[FracBits-1:0];
        end

        INIT: begin
          // Register normalized mantissas and special case detection
          result_sign_r <= sign_a_r ^ sign_b_r;
          exp_a_adj_r <= exp_a_adj;
          exp_b_adj_r <= exp_b_adj;
          mant_a_r <= mant_a;
          mant_b_r <= mant_b;
          is_special_r <= is_special_init;
          special_result_r <= special_result_init;
          special_invalid_r <= special_invalid_init;
          special_div_zero_r <= special_div_zero_init;
        end

        SETUP: begin
          // Use registered values from INIT stage
          if (is_special_r) begin
            result_reg <= special_result_r;
            flags_reg  <= {special_invalid_r, special_div_zero_r, 1'b0, 1'b0, 1'b0};
          end else begin
            // Initialize division using registered mantissas
            // exp_result = exp_a - exp_b + 127
            result_exp <= exp_a_adj_r - exp_b_adj_r + ExpBiasExt;
            divisor <= {{(DivBits - MantBits) {1'b0}}, mant_b_r};
            if (mant_a_r >= mant_b_r) begin
              quotient  <= {{(DivBits - 1) {1'b0}}, 1'b1};
              remainder <= {{(DivBits - MantBits) {1'b0}}, mant_a_r - mant_b_r};
            end else begin
              quotient  <= '0;
              remainder <= {{(DivBits - MantBits) {1'b0}}, mant_a_r};
            end
          end
        end

        DIVIDE: begin
          cycle_count <= cycle_count + 1'b1;
          quotient <= next_quotient;
          remainder <= next_remainder;
        end

        NORMALIZE_PREP: begin
          quotient_lzc_r <= quotient_lzc;
          quotient_is_zero_r <= quotient_is_zero;
        end

        NORMALIZE: begin
          quotient   <= quotient_norm;
          result_exp <= result_exp_norm;
          // quotient[DivBits-1] is now the implicit 1 (unless result is zero)
        end

        ROUND_SHIFT: begin
          exp_work_shift <= exp_work_prep;
          mantissa_work_shift <= mantissa_work_prep;
          guard_work_shift <= guard_work_prep;
          round_work_shift <= round_work_prep;
          sticky_work_shift <= sticky_work_prep;
          div_is_zero_shift <= div_is_zero;
          rm_shift <= rm;
        end

        ROUND_PREP: begin
          // Capture round-up decision into apply registers
          result_sign_apply <= result_sign_r;
          exp_work_apply <= exp_work_shift;
          mantissa_work_apply <= mantissa_work_shift;
          round_up_apply <= round_up_prep;
          is_inexact_apply <= is_inexact_prep;
          div_is_zero_apply <= div_is_zero_shift;
          rm_apply <= rm_shift;
        end

        ROUND_APPLY: begin
          // Capture final result into output registers
          result_output <= final_result_apply_comb;
          flags_output  <= final_flags_apply_comb;
        end

        OUTPUT: begin
          // Capture into final result registers
          result_reg <= result_output;
          flags_reg  <= flags_output;
        end

        DONE: begin
          valid_reg <= 1'b1;
        end

        default: ;
      endcase
    end
  end

  // =========================================================================
  // Outputs
  // =========================================================================

  assign o_result = result_reg;
  assign o_flags  = flags_reg;
  assign o_valid  = valid_reg;
  // Stall immediately when i_valid is asserted (FDIV enters EX), matching integer
  // divider pattern where stall = (is_divide & ~divider_valid_output). The integer
  // stall is true from the first cycle because valid_output starts at 0. We achieve
  // the same by OR'ing i_valid with the state check, so stall is asserted on the
  // same cycle the instruction enters EX. Stall drops when valid_reg goes high.
  assign o_stall  = ((state != IDLE) || i_valid) && ~valid_reg;

endmodule : fp_divider
