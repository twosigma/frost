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
  IEEE 754 single-precision floating-point square root.

  Implements FSQRT.S operation using a digit-by-digit algorithm.

  Latency: RootBits + 9 cycles (not pipelined, stalls pipeline during operation)
    where RootBits = MantBits + 3 = FracBits + 4 (27 for SP, 56 for DP)
    - 1 cycle:  Input capture (IDLE -> SETUP)
    - 1 cycle:  Special case detection and setup (SETUP -> PREP)
    - 1 cycle:  Prep register capture (PREP -> COMPUTE)
    - RootBits cycles: Square root computation (COMPUTE, one digit per cycle)
    - 1 cycle:  Normalization (NORMALIZE)
    - 1 cycle:  Subnormal handling and shift prep (ROUND_SHIFT)
    - 1 cycle:  Compute round-up decision (ROUND_PREP)
    - 1 cycle:  Apply rounding increment, format result (ROUND_APPLY)
    - 1 cycle:  Capture result (OUTPUT)
    - 1 cycle:  Output registered result (DONE)

  Algorithm: Non-restoring digit recurrence
    sqrt(x) where x = 2^(2k) * m, m in [1, 4)
    Result = 2^k * sqrt(m)

  Special case handling:
    - sqrt(NaN) = NaN
    - sqrt(-x) = NaN (invalid, for x > 0)
    - sqrt(+inf) = +inf
    - sqrt(-0) = -0
    - sqrt(+0) = +0
*/
module fp_sqrt #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_valid,
    input  logic                 [FP_WIDTH-1:0] i_operand,
    input  logic                 [         2:0] i_rounding_mode,
    output logic                 [FP_WIDTH-1:0] o_result,
    output logic                                o_valid,
    output logic                                o_stall,
    output riscv_pkg::fp_flags_t                o_flags
);

  // State machine
  typedef enum logic [3:0] {
    IDLE,
    SETUP,
    PREP,
    COMPUTE,
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
  localparam int unsigned RootBits = MantBits + 3;
  localparam int unsigned RadicandBits = 2 * RootBits;
  localparam int unsigned RemBits = (2 * RootBits) + 2;
  localparam int unsigned CycleCountBits = $clog2(RootBits + 1);
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcMantBits = $clog2(FracBits + 1);
  localparam int unsigned ShiftBits = $clog2(MantBits + 3 + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam logic signed [ExpExtBits-1:0] ExpBiasExt = ExpExtBits'(ExpBias);
  localparam logic signed [ExpExtBits-1:0] ExpBiasMinus1Ext = ExpExtBits'(ExpBias - 1);
  localparam logic [CycleCountBits-1:0] RootBitsMinus1 = CycleCountBits'(RootBits - 1);

  logic [CycleCountBits-1:0] cycle_count;

  // Registered input
  logic [      FP_WIDTH-1:0] operand_reg;

  // Operand fields
  logic                      sign;
  logic [       ExpBits-1:0] exp;
  logic [      FracBits-1:0] mant;
  logic is_zero, is_inf, is_nan, is_snan;
  logic                           is_subnormal;
  logic signed [  ExpExtBits-1:0] exp_adj;
  logic        [    MantBits-1:0] mant_norm;
  logic        [ LzcMantBits-1:0] mant_lzc;
  logic        [   LzcMantBits:0] sub_shift;
  // Special case handling
  logic                           is_special;
  logic        [    FP_WIDTH-1:0] special_result;
  logic                           special_invalid;

  // Square root state
  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *)logic signed [  ExpExtBits-1:0] result_exp;
  logic        [    RootBits-1:0] root;  // Result accumulator
  logic        [     RemBits-1:0] remainder;  // For digit computation
  logic        [RadicandBits-1:0] radicand;  // Mantissa bits consumed 2 at a time

  // Rounding mode storage
  logic        [             2:0] rm;
  logic                           result_sign;
  logic signed [  ExpExtBits-1:0] sqrt_unbiased_exp;
  logic                           sqrt_exp_is_even;
  logic signed [    ExpExtBits:0] sqrt_adjusted_exp;
  logic        [      MantBits:0] sqrt_mantissa_int;
  logic        [   ShiftBits-1:0] sqrt_shift_amount;

  // Prep registers to break long operand->radicand path
  logic                           prep_is_special;
  logic        [    FP_WIDTH-1:0] prep_special_result;
  logic                           prep_special_invalid;
  logic signed [    ExpExtBits:0] prep_sqrt_adjusted_exp;
  logic        [      MantBits:0] prep_sqrt_mantissa_int;

  // Rounding inputs
  logic        [      MantBits:0] sqrt_pre_round_mant;
  logic                           sqrt_guard_bit;
  logic                           sqrt_round_bit;
  logic                           sqrt_sticky_bit;
  logic                           sqrt_is_zero;

  // =========================================================================
  // Operand Unpacking
  // =========================================================================

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack (
      .i_operand(operand_reg),
      .o_sign(sign),
      .o_exp(exp),
      .o_exp_adj(),
      .o_frac(mant),
      .o_mant(),
      .o_is_zero(is_zero),
      .o_is_subnormal(is_subnormal),
      .o_is_inf(is_inf),
      .o_is_nan(is_nan),
      .o_is_snan(is_snan)
  );

  logic mant_lzc_zero;
  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc (
      .i_value (mant),
      .o_lzc   (mant_lzc),
      .o_is_zero(mant_lzc_zero)
  );

  always_comb begin
    sub_shift = '0;
    exp_adj = '0;
    mant_norm = '0;
    sqrt_unbiased_exp = '0;
    sqrt_exp_is_even = 1'b0;
    sqrt_adjusted_exp = '0;
    sqrt_mantissa_int = '0;
    sqrt_shift_amount = '0;

    if (is_subnormal) begin
      sub_shift = {1'b0, mant_lzc} + {{LzcMantBits{1'b0}}, 1'b1};
      exp_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, sub_shift});
      mant_norm = {1'b0, mant} << sub_shift;
    end else begin
      exp_adj   = $signed({{(ExpExtBits - ExpBits) {1'b0}}, exp});
      mant_norm = {1'b1, mant};
    end

    // Special case detection
    is_special = 1'b0;
    special_result = '0;
    special_invalid = 1'b0;

    if (is_nan) begin
      // sqrt(NaN) = NaN
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = is_snan;
    end else if (sign && !is_zero) begin
      // sqrt(negative) = NaN (invalid)
      is_special = 1'b1;
      special_result = CanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf) begin
      // sqrt(+inf) = +inf
      is_special = 1'b1;
      special_result = {1'b0, ExpMax, {FracBits{1'b0}}};
    end else if (is_zero) begin
      // sqrt(+/-0) = +/-0
      is_special = 1'b1;
      special_result = {sign, {(FP_WIDTH - 1) {1'b0}}};
    end

    sqrt_unbiased_exp = exp_adj - ExpBiasExt;
    sqrt_exp_is_even  = ~sqrt_unbiased_exp[0];

    if (sqrt_exp_is_even) begin
      // Unbiased exponent is even
      sqrt_adjusted_exp = exp_adj + ExpBiasExt;
      sqrt_mantissa_int = {1'b0, mant_norm};
      sqrt_shift_amount = ShiftBits'(MantBits + 5);
    end else begin
      // Unbiased exponent is odd: scale mantissa by 2
      sqrt_adjusted_exp = exp_adj + ExpBiasMinus1Ext;
      sqrt_mantissa_int = {mant_norm, 1'b0};
      sqrt_shift_amount = ShiftBits'(MantBits + 5);
    end
  end

  assign sqrt_pre_round_mant = root[RootBits-1-:(MantBits+1)];
  assign sqrt_guard_bit = root[1];
  assign sqrt_round_bit = root[0];
  assign sqrt_sticky_bit = |remainder;
  assign sqrt_is_zero = (root == '0) && (remainder == '0);

  // =========================================================================
  // ROUND_SHIFT prep: Subnormal handling and rounding bit extraction
  // =========================================================================

  // Extract mantissa and rounding bits
  logic [MantBits-1:0] mantissa_retained_prep;
  assign mantissa_retained_prep = sqrt_pre_round_mant[MantBits:1];

  // Subnormal handling: compute shift and apply
  logic [MantBits-1:0] mantissa_work_prep;
  logic guard_work_prep, round_work_prep, sticky_work_prep;
  logic signed [ExpExtBits-1:0] exp_work_prep;

  fp_subnorm_shift #(
      .MANT_BITS   (MantBits),
      .EXP_EXT_BITS(ExpExtBits)
  ) u_subnorm_shift (
      .i_mantissa(mantissa_retained_prep),
      .i_guard   (sqrt_pre_round_mant[0]),
      .i_round   (sqrt_guard_bit),
      .i_sticky  (sqrt_round_bit | sqrt_sticky_bit),
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
  logic                         sqrt_is_zero_shift;
  logic        [           2:0] rm_shift;

  // Compute round-up decision (sqrt result is always positive)
  logic                         round_up_prep;
  logic                         lsb_prep;

  assign lsb_prep = mantissa_work_shift[0];

  // sqrt result is always positive (sign=0), so RDN->0, RUP->guard|round|sticky
  assign round_up_prep = riscv_pkg::fp_compute_round_up(
      rm_shift, guard_work_shift, round_work_shift, sticky_work_shift, lsb_prep, 1'b0
  );

  // Compute is_inexact for flags
  logic is_inexact_prep;
  assign is_inexact_prep = guard_work_shift | round_work_shift | sticky_work_shift;

  // =========================================================================
  // ROUND_PREP -> ROUND_APPLY Pipeline Registers
  // =========================================================================

  logic signed          [ExpExtBits-1:0] exp_work_apply;
  logic                 [  MantBits-1:0] mantissa_work_apply;
  logic                                  round_up_apply;
  logic                                  is_inexact_apply;
  logic                                  sqrt_is_zero_apply;
  logic                 [           2:0] rm_apply;

  // =========================================================================
  // ROUND_APPLY: Apply rounding and format result
  // =========================================================================

  // Compute final result using shared result assembler
  // sqrt result is always positive (sign=0), so the general overflow formula
  // (RTZ || (RDN && !sign) || (RUP && sign)) correctly simplifies to (RTZ || RDN).
  logic                 [  FP_WIDTH-1:0] final_result_apply_comb;
  riscv_pkg::fp_flags_t                  final_flags_apply_comb;

  fp_result_assembler #(
      .FP_WIDTH  (FP_WIDTH),
      .ExpBits   (ExpBits),
      .FracBits  (FracBits),
      .MantBits  (MantBits),
      .ExpExtBits(ExpExtBits)
  ) u_result_asm (
      .i_exp_work        (exp_work_apply),
      .i_mantissa_work   (mantissa_work_apply),
      .i_round_up        (round_up_apply),
      .i_is_inexact      (is_inexact_apply),
      .i_result_sign     (1'b0),
      .i_rm              (rm_apply),
      .i_is_special      (1'b0),
      .i_special_result  ({FP_WIDTH{1'b0}}),
      .i_special_invalid (1'b0),
      .i_special_div_zero(1'b0),
      .i_is_zero_result  (sqrt_is_zero_apply),
      .i_zero_sign       (1'b0),
      .o_result          (final_result_apply_comb),
      .o_flags           (final_flags_apply_comb)
  );

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
          next_state = SETUP;
        end
      end
      SETUP: begin
        next_state = PREP;
      end
      PREP: begin
        if (prep_is_special) begin
          next_state = DONE;
        end else begin
          next_state = COMPUTE;
        end
      end
      COMPUTE: begin
        if (cycle_count == RootBitsMinus1) begin
          next_state = NORMALIZE;
        end
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
  // Main Datapath
  // =========================================================================

  logic                 [FP_WIDTH-1:0] result_reg;
  riscv_pkg::fp_flags_t                flags_reg;
  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *)logic                                valid_reg;

  // Digit-by-digit sqrt helpers
  logic                 [ RemBits-1:0] rem_candidate;
  logic                 [ RemBits-1:0] trial_divisor;
  logic                                rem_ge;

  assign rem_candidate = {remainder[RemBits-3:0], radicand[RadicandBits-1-:2]};
  assign trial_divisor = {{RootBits{1'b0}}, root, 2'b01};
  assign rem_ge = rem_candidate >= trial_divisor;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_count <= '0;
      root <= '0;
      remainder <= '0;
      radicand <= '0;
      result_exp <= '0;
      rm <= 3'b0;
      result_sign <= 1'b0;
      operand_reg <= '0;
      prep_is_special <= 1'b0;
      prep_special_result <= '0;
      prep_special_invalid <= 1'b0;
      prep_sqrt_adjusted_exp <= '0;
      prep_sqrt_mantissa_int <= '0;
      // ROUND_SHIFT -> ROUND_PREP registers
      exp_work_shift <= '0;
      mantissa_work_shift <= '0;
      guard_work_shift <= 1'b0;
      round_work_shift <= 1'b0;
      sticky_work_shift <= 1'b0;
      sqrt_is_zero_shift <= 1'b0;
      rm_shift <= 3'b0;
      // ROUND_PREP -> ROUND_APPLY registers
      exp_work_apply <= '0;
      mantissa_work_apply <= '0;
      round_up_apply <= 1'b0;
      is_inexact_apply <= 1'b0;
      sqrt_is_zero_apply <= 1'b0;
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
            operand_reg <= i_operand;
            rm <= i_rounding_mode;
            cycle_count <= '0;
          end
        end

        SETUP: begin
          prep_is_special <= is_special;
          prep_special_result <= special_result;
          prep_special_invalid <= special_invalid;
          prep_sqrt_adjusted_exp <= sqrt_adjusted_exp;
          prep_sqrt_mantissa_int <= sqrt_mantissa_int;
        end

        PREP: begin
          result_sign <= 1'b0;  // sqrt result is always positive (or zero)

          // Initialize sqrt computation (special cases override output and skip compute)
          // For sqrt: result_exp = (exp - bias) / 2 + bias
          result_exp <= ExpExtBits'($signed(prep_sqrt_adjusted_exp >>> 1));
          root <= '0;
          remainder <= '0;
          radicand <= {{(RadicandBits-(MantBits+1)){1'b0}}, prep_sqrt_mantissa_int} <<
                      ShiftBits'(MantBits + 5);

          if (prep_is_special) begin
            result_reg <= prep_special_result;
            flags_reg  <= {prep_special_invalid, 1'b0, 1'b0, 1'b0, 1'b0};
          end
        end

        COMPUTE: begin
          cycle_count <= cycle_count + 1;
          // Digit-by-digit square root: bring down 2 bits per iteration
          radicand <= {radicand[RadicandBits-3:0], 2'b00};
          if (rem_ge) begin
            remainder <= rem_candidate - trial_divisor;
            root <= {root[RootBits-2:0], 1'b1};
          end else begin
            remainder <= rem_candidate;
            root <= {root[RootBits-2:0], 1'b0};
          end
        end

        NORMALIZE: begin
          // The root should already be normalized
          // root[RootBits-1] should be the implicit 1
          if (!root[RootBits-1]) begin
            root <= root << 1;
            result_exp <= result_exp - 1;
          end
        end

        ROUND_SHIFT: begin
          exp_work_shift <= exp_work_prep;
          mantissa_work_shift <= mantissa_work_prep;
          guard_work_shift <= guard_work_prep;
          round_work_shift <= round_work_prep;
          sticky_work_shift <= sticky_work_prep;
          sqrt_is_zero_shift <= sqrt_is_zero;
          rm_shift <= rm;
        end

        ROUND_PREP: begin
          // Capture round-up decision into apply registers
          exp_work_apply <= exp_work_shift;
          mantissa_work_apply <= mantissa_work_shift;
          round_up_apply <= round_up_prep;
          is_inexact_apply <= is_inexact_prep;
          sqrt_is_zero_apply <= sqrt_is_zero_shift;
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
  // Stall immediately when i_valid is asserted (FSQRT enters EX), matching integer
  // divider pattern where stall = (is_divide & ~divider_valid_output). The integer
  // stall is true from the first cycle because valid_output starts at 0. We achieve
  // the same by OR'ing i_valid with the state check, so stall is asserted on the
  // same cycle the instruction enters EX. Stall drops when valid_reg goes high.
  assign o_stall  = ((state != IDLE) || i_valid) && ~valid_reg;

endmodule : fp_sqrt
