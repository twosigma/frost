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
  Floating-point comparison and min/max operations.

  2-cycle pipelined implementation:
    Cycle 0: Capture operands
    Cycle 1: Magnitude comparison, NaN/zero detection
    Cycle 2: Sign-aware comparison, result selection, output

  Comparison operations (result goes to integer register):
    FEQ.S: rd = (fs1 == fs2) ? 1 : 0
    FLT.S: rd = (fs1 < fs2) ? 1 : 0
    FLE.S: rd = (fs1 <= fs2) ? 1 : 0

  Min/Max operations (result goes to FP register):
    FMIN.S: fd = min(fs1, fs2)
    FMAX.S: fd = max(fs1, fs2)

  NaN handling per IEEE 754-2008 minNum/maxNum:
    - If exactly one operand is NaN, return the other operand
    - If both operands are NaN, return canonical NaN
    - Signaling NaN always raises invalid exception

  Exception handling:
    - FEQ raises invalid only for signaling NaN
    - FLT/FLE raise invalid for any NaN (signaling or quiet)
    - FMIN/FMAX raise invalid only for signaling NaN
*/
module fp_compare #(
    parameter int unsigned FP_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [FP_WIDTH-1:0] i_operand_a,  // fs1
    input logic [FP_WIDTH-1:0] i_operand_b,  // fs2
    input riscv_pkg::instr_op_e i_operation,
    output logic [FP_WIDTH-1:0] o_result,  // Comparison result (0 or 1) or min/max
    output logic o_is_compare,  // True for FEQ/FLT/FLE (result to int reg)
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // =========================================================================
  // State Machine
  // =========================================================================

  typedef enum logic [1:0] {
    IDLE   = 2'b00,
    STAGE1 = 2'b01,
    STAGE2 = 2'b10
  } state_e;

  state_e state, next_state;

  // =========================================================================
  // Stage 0 -> Stage 1: Capture operands
  // =========================================================================

  logic [FP_WIDTH-1:0] operand_a_s1, operand_b_s1;
  riscv_pkg::instr_op_e operation_s1;

  // =========================================================================
  // Stage 1: Extract fields and compute magnitude comparison (combinational)
  // =========================================================================

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};

  // Extract fields
  logic sign_a_s1, sign_b_s1;
  logic [ExpBits-1:0] exp_a_s1, exp_b_s1;
  logic [FracBits-1:0] mant_a_s1, mant_b_s1;

  assign sign_a_s1 = operand_a_s1[FP_WIDTH-1];
  assign sign_b_s1 = operand_b_s1[FP_WIDTH-1];
  assign exp_a_s1  = operand_a_s1[FP_WIDTH-2-:ExpBits];
  assign exp_b_s1  = operand_b_s1[FP_WIDTH-2-:ExpBits];
  assign mant_a_s1 = operand_a_s1[FracBits-1:0];
  assign mant_b_s1 = operand_b_s1[FracBits-1:0];

  // NaN detection
  logic is_nan_a_s1, is_nan_b_s1;
  logic is_snan_a_s1, is_snan_b_s1;
  logic either_nan_s1, either_snan_s1;

  assign is_nan_a_s1 = (exp_a_s1 == ExpMax) && (mant_a_s1 != '0);
  assign is_nan_b_s1 = (exp_b_s1 == ExpMax) && (mant_b_s1 != '0);
  assign is_snan_a_s1 = is_nan_a_s1 && ~mant_a_s1[FracBits-1];
  assign is_snan_b_s1 = is_nan_b_s1 && ~mant_b_s1[FracBits-1];
  assign either_nan_s1 = is_nan_a_s1 | is_nan_b_s1;
  assign either_snan_s1 = is_snan_a_s1 | is_snan_b_s1;

  // Zero detection
  logic is_zero_a_s1, is_zero_b_s1;
  assign is_zero_a_s1 = (exp_a_s1 == '0) && (mant_a_s1 == '0);
  assign is_zero_b_s1 = (exp_b_s1 == '0) && (mant_b_s1 == '0);

  // Magnitude comparison
  logic [FP_WIDTH-2:0] mag_a_s1, mag_b_s1;
  assign mag_a_s1 = operand_a_s1[FP_WIDTH-2:0];
  assign mag_b_s1 = operand_b_s1[FP_WIDTH-2:0];

  logic mag_a_lt_b_s1;  // |a| < |b|
  logic mag_a_eq_b_s1;  // |a| == |b|
  assign mag_a_lt_b_s1 = mag_a_s1 < mag_b_s1;
  assign mag_a_eq_b_s1 = mag_a_s1 == mag_b_s1;

  // =========================================================================
  // Stage 1 -> Stage 2: Pipeline registers
  // =========================================================================

  logic [FP_WIDTH-1:0] operand_a_s2, operand_b_s2;
  riscv_pkg::instr_op_e operation_s2;
  logic sign_a_s2, sign_b_s2;
  logic is_nan_a_s2, is_nan_b_s2;
  logic either_nan_s2, either_snan_s2;
  logic is_zero_a_s2, is_zero_b_s2;
  logic mag_a_lt_b_s2, mag_a_eq_b_s2;

  // =========================================================================
  // Stage 2: Sign-aware comparison and result selection (combinational)
  // =========================================================================

  // Full comparison considering signs
  logic a_lt_b_s2;  // a < b
  logic a_eq_b_s2;  // a == b
  logic a_le_b_s2;  // a <= b

  always_comb begin
    if (is_zero_a_s2 && is_zero_b_s2) begin
      // +0 == -0
      a_lt_b_s2 = 1'b0;
      a_eq_b_s2 = 1'b1;
    end else if (sign_a_s2 != sign_b_s2) begin
      // Different signs: negative < positive
      a_lt_b_s2 = sign_a_s2;
      a_eq_b_s2 = 1'b0;
    end else if (sign_a_s2) begin
      // Both negative: larger magnitude means smaller value
      a_lt_b_s2 = ~mag_a_lt_b_s2 & ~mag_a_eq_b_s2;
      a_eq_b_s2 = mag_a_eq_b_s2;
    end else begin
      // Both positive: smaller magnitude means smaller value
      a_lt_b_s2 = mag_a_lt_b_s2;
      a_eq_b_s2 = mag_a_eq_b_s2;
    end
  end

  assign a_le_b_s2 = a_lt_b_s2 | a_eq_b_s2;

  // Min/Max selection
  logic [FP_WIDTH-1:0] min_result_s2, max_result_s2;

  always_comb begin
    if (is_nan_a_s2 && is_nan_b_s2) begin
      min_result_s2 = CanonicalNan;
      max_result_s2 = CanonicalNan;
    end else if (is_nan_a_s2) begin
      min_result_s2 = operand_b_s2;
      max_result_s2 = operand_b_s2;
    end else if (is_nan_b_s2) begin
      min_result_s2 = operand_a_s2;
      max_result_s2 = operand_a_s2;
    end else begin
      if (is_zero_a_s2 && is_zero_b_s2) begin
        min_result_s2 = sign_a_s2 ? operand_a_s2 : operand_b_s2;
        max_result_s2 = sign_a_s2 ? operand_b_s2 : operand_a_s2;
      end else begin
        min_result_s2 = a_lt_b_s2 ? operand_a_s2 : operand_b_s2;
        max_result_s2 = a_lt_b_s2 ? operand_b_s2 : operand_a_s2;
      end
    end
  end

  // Compute final result
  logic                 [FP_WIDTH-1:0] result_s2_comb;
  logic                                is_compare_s2_comb;
  riscv_pkg::fp_flags_t                flags_s2_comb;

  always_comb begin
    result_s2_comb = '0;
    is_compare_s2_comb = 1'b0;
    flags_s2_comb = '0;

    unique case (operation_s2)
      riscv_pkg::FEQ_S, riscv_pkg::FEQ_D: begin
        is_compare_s2_comb = 1'b1;
        if (either_nan_s2) begin
          result_s2_comb   = '0;
          flags_s2_comb.nv = either_snan_s2;
        end else begin
          result_s2_comb = {{(FP_WIDTH - 1) {1'b0}}, a_eq_b_s2};
        end
      end

      riscv_pkg::FLT_S, riscv_pkg::FLT_D: begin
        is_compare_s2_comb = 1'b1;
        if (either_nan_s2) begin
          result_s2_comb   = '0;
          flags_s2_comb.nv = 1'b1;
        end else begin
          result_s2_comb = {{(FP_WIDTH - 1) {1'b0}}, a_lt_b_s2};
        end
      end

      riscv_pkg::FLE_S, riscv_pkg::FLE_D: begin
        is_compare_s2_comb = 1'b1;
        if (either_nan_s2) begin
          result_s2_comb   = '0;
          flags_s2_comb.nv = 1'b1;
        end else begin
          result_s2_comb = {{(FP_WIDTH - 1) {1'b0}}, a_le_b_s2};
        end
      end

      riscv_pkg::FMIN_S, riscv_pkg::FMIN_D: begin
        is_compare_s2_comb = 1'b0;
        result_s2_comb = min_result_s2;
        flags_s2_comb.nv = either_snan_s2;
      end

      riscv_pkg::FMAX_S, riscv_pkg::FMAX_D: begin
        is_compare_s2_comb = 1'b0;
        result_s2_comb = max_result_s2;
        flags_s2_comb.nv = either_snan_s2;
      end

      default: begin
        result_s2_comb = '0;
        is_compare_s2_comb = 1'b0;
      end
    endcase
  end

  // =========================================================================
  // Output registers
  // =========================================================================

  logic                 [FP_WIDTH-1:0] result_reg;
  logic                                is_compare_reg;
  riscv_pkg::fp_flags_t                flags_reg;
  logic                                valid_reg;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      operand_a_s1 <= '0;
      operand_b_s1 <= '0;
      operation_s1 <= riscv_pkg::ADD;
      operand_a_s2 <= '0;
      operand_b_s2 <= '0;
      operation_s2 <= riscv_pkg::ADD;
      sign_a_s2 <= 1'b0;
      sign_b_s2 <= 1'b0;
      is_nan_a_s2 <= 1'b0;
      is_nan_b_s2 <= 1'b0;
      either_nan_s2 <= 1'b0;
      either_snan_s2 <= 1'b0;
      is_zero_a_s2 <= 1'b0;
      is_zero_b_s2 <= 1'b0;
      mag_a_lt_b_s2 <= 1'b0;
      mag_a_eq_b_s2 <= 1'b0;
      result_reg <= '0;
      is_compare_reg <= 1'b0;
      flags_reg <= '0;
      valid_reg <= 1'b0;
    end else begin
      state <= next_state;
      valid_reg <= (state == STAGE2);

      case (state)
        IDLE: begin
          if (i_valid) begin
            operand_a_s1 <= i_operand_a;
            operand_b_s1 <= i_operand_b;
            operation_s1 <= i_operation;
          end
        end

        STAGE1: begin
          // Capture stage 1 results into stage 2 registers
          operand_a_s2 <= operand_a_s1;
          operand_b_s2 <= operand_b_s1;
          operation_s2 <= operation_s1;
          sign_a_s2 <= sign_a_s1;
          sign_b_s2 <= sign_b_s1;
          is_nan_a_s2 <= is_nan_a_s1;
          is_nan_b_s2 <= is_nan_b_s1;
          either_nan_s2 <= either_nan_s1;
          either_snan_s2 <= either_snan_s1;
          is_zero_a_s2 <= is_zero_a_s1;
          is_zero_b_s2 <= is_zero_b_s1;
          mag_a_lt_b_s2 <= mag_a_lt_b_s1;
          mag_a_eq_b_s2 <= mag_a_eq_b_s1;
        end

        STAGE2: begin
          // Capture final result
          result_reg <= result_s2_comb;
          is_compare_reg <= is_compare_s2_comb;
          flags_reg <= flags_s2_comb;
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
      STAGE2: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Outputs
  // =========================================================================

  assign o_result = result_reg;
  assign o_is_compare = is_compare_reg;
  assign o_flags = flags_reg;
  assign o_valid = valid_reg;

endmodule : fp_compare
