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
 * Radix-2 Restoring Division Unit - RISC-V M-extension DIV/REM operations
 *
 * Implements pipelined radix-2 restoring division with 2x folding (2 bits per stage).
 * Supports both signed (DIV, REM) and unsigned (DIVU, REMU) operations.
 *
 * Algorithm Overview (Restoring Division):
 * =========================================
 * The restoring algorithm computes one quotient bit per iteration:
 *
 *   For each bit position (MSB to LSB):
 *     1. Shift remainder left, bring in next dividend bit
 *     2. Try subtracting divisor from remainder
 *     3. If result >= 0: quotient_bit = 1, keep result
 *        If result < 0:  quotient_bit = 0, restore (discard result)
 *
 *   Example: 7 ÷ 2 (binary: 0111 ÷ 0010)
 *     Iteration 1: R=0000, shift+subtract: 0000-0010 < 0, Q[3]=0, R=0000
 *     Iteration 2: R=0001, shift+subtract: 0001-0010 < 0, Q[2]=0, R=0001
 *     Iteration 3: R=0011, shift+subtract: 0011-0010 ≥ 0, Q[1]=1, R=0001
 *     Iteration 4: R=0011, shift+subtract: 0011-0010 ≥ 0, Q[0]=1, R=0001
 *     Result: Quotient=0011 (3), Remainder=0001 (1) ✓
 *
 * Pipeline Structure (2x Folded):
 * ===============================
 *   +---------+   +---------+   +---------+       +---------+   +---------+
 *   | Stage 0 | > | Stage 1 | > | Stage 2 | > ... |Stage 15 | > | Output  |
 *   | (init)  |   | 2 bits  |   | 2 bits  |       | 2 bits  |   | (sign)  |
 *   +---------+   +---------+   +---------+       +---------+   +---------+
 *
 *   Each stage computes 2 quotient bits (2x folding reduces pipeline depth).
 *   Stage 0 initializes with absolute values; output stage applies sign correction.
 *
 * Signed Division Handling:
 * =========================
 *   - Convert operands to absolute values before division
 *   - Quotient sign: negative if operand signs differ (XOR)
 *   - Remainder sign: follows dividend sign
 *   - Apply two's complement at output if needed
 *
 * Special Cases (per RISC-V spec):
 * ================================
 *   - Divide by zero: quotient = -1 (all 1s), remainder = dividend
 *   - Signed overflow (MIN_INT / -1): quotient = MIN_INT, remainder = 0
 *     (Note: overflow case handled by natural wraparound of two's complement)
 *
 * Performance:
 * ============
 *   - Latency: 17 cycles (1 init + 16 division stages)
 *   - Throughput: 1 division per cycle (fully pipelined)
 *   - Pipeline stall in hazard unit during wait
 *
 * Related Modules:
 *   - alu.sv: Instantiates divider, selects quotient vs remainder
 *   - hazard_resolution_unit.sv: Stalls pipeline during division
 */
module divider #(
    parameter int unsigned WIDTH = 32  // Bit width (32 for RV32)
) (
    input logic i_clk,
    input logic i_rst,

    input logic             i_valid_input,          // Start division
    input logic             i_is_signed_operation,  // Signed vs unsigned division
    input logic [WIDTH-1:0] i_dividend,             // Numerator
    input logic [WIDTH-1:0] i_divisor,              // Denominator

    output logic             o_valid_output,  // Result ready
    output logic [WIDTH-1:0] o_quotient,      // Division result
    output logic [WIDTH-1:0] o_remainder      // Modulo result
);
  // Operand preprocessing - convert signed values to absolute values for division
  logic dividend_is_negative, divisor_is_negative;
  logic quotient_should_be_negative, remainder_should_be_negative;
  logic [WIDTH-1:0] dividend_absolute_value, divisor_absolute_value;

  always_comb begin
    // Check if operands are negative (for signed division only)
    dividend_is_negative = i_is_signed_operation & i_dividend[WIDTH-1];
    divisor_is_negative = i_is_signed_operation & i_divisor[WIDTH-1];
    // Convert to absolute values using two's complement
    dividend_absolute_value = dividend_is_negative ? (~i_dividend + 1'b1) : i_dividend;
    divisor_absolute_value = divisor_is_negative ? (~i_divisor + 1'b1) : i_divisor;
    // Determine result signs - quotient negative if signs differ, remainder follows dividend
    quotient_should_be_negative = dividend_is_negative ^ divisor_is_negative;
    remainder_should_be_negative = dividend_is_negative;
  end

  // 2x-folded radix-2 division requires one pipeline stage per 2 bits (32 stages for 32-bit)
  localparam int unsigned NumPipelineStages = WIDTH / 2;

  // Pipeline arrays for each stage - carry values through division process
  logic [WIDTH-1:0] remainder_pipeline     [NumPipelineStages+1];  // +1 bit for subtraction
  logic [WIDTH-1:0] quotient_pipeline      [NumPipelineStages+1];
  logic [WIDTH-1:0] divisor_pipeline       [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic [WIDTH-1:0] dividend_pipeline      [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             quotient_sign_pipeline [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             remainder_sign_pipeline[NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             divide_by_zero_pipeline[NumPipelineStages+1];
  logic             valid_pipeline         [NumPipelineStages+1];

  // Stage 0: Initialize pipeline with input values
  always_ff @(posedge i_clk) begin
    valid_pipeline[0] <= i_rst ? 1'b0 : i_valid_input;
    divisor_pipeline[0] <= divisor_absolute_value;
    dividend_pipeline[0] <= dividend_absolute_value;
    remainder_pipeline[0] <= '0;  // Remainder starts at 0
    quotient_pipeline[0] <= dividend_absolute_value;  // Dividend shifts to become quotient
    quotient_sign_pipeline[0] <= quotient_should_be_negative;
    remainder_sign_pipeline[0] <= remainder_should_be_negative;
    divide_by_zero_pipeline[0] <= (i_divisor == '0) & i_valid_input;
  end

  // Main radix-2 restoring division pipeline (stages 1 through WIDTH)
  // Each stage computes one bit of the quotient through shift-and-subtract
  generate
    for (
        genvar stage_index = 0; stage_index < NumPipelineStages; ++stage_index
    ) begin : gen_division_stages
      logic [WIDTH:0] remainder_shifted;
      logic [WIDTH:0] subtraction_result;
      logic subtraction_is_negative;
      logic [WIDTH:0] next_remainder;
      logic [1:0] quotient_bits;

      // perform two iterations prior to next flip-flop stage
      always_comb begin
        // first iteration:
        // Shift remainder left and bring in next bit from quotient
        remainder_shifted = {
          remainder_pipeline[stage_index][WIDTH-1:0], quotient_pipeline[stage_index][WIDTH-1]
        };
        // Try subtracting divisor from shifted remainder
        subtraction_result = remainder_shifted - divisor_pipeline[stage_index];
        // Check if subtraction result is negative (MSB is sign bit)
        subtraction_is_negative = subtraction_result[WIDTH];
        // If negative, restore remainder; otherwise keep subtraction result
        next_remainder = subtraction_is_negative ? remainder_shifted : subtraction_result;
        // Quotient bit is 1 if subtraction succeeded (not negative)
        quotient_bits[1] = ~subtraction_is_negative;

        // second iteration:
        remainder_shifted = {WIDTH'(next_remainder), quotient_pipeline[stage_index][WIDTH-2]};
        subtraction_result = remainder_shifted - divisor_pipeline[stage_index];
        subtraction_is_negative = subtraction_result[WIDTH];
        next_remainder = subtraction_is_negative ? remainder_shifted : subtraction_result;
        quotient_bits[0] = ~subtraction_is_negative;
      end

      // Sequential registers advance values to next stage
      always_ff @(posedge i_clk) begin
        remainder_pipeline[stage_index+1] <= WIDTH'(next_remainder);
        // Shift quotient left and insert new quotient bit at LSB
        quotient_pipeline[stage_index+1] <= {
          quotient_pipeline[stage_index][WIDTH-3:0], quotient_bits
        };
        // Propagate control signals through pipeline
        divisor_pipeline[stage_index+1] <= divisor_pipeline[stage_index];
        dividend_pipeline[stage_index+1] <= dividend_pipeline[stage_index];
        quotient_sign_pipeline[stage_index+1] <= quotient_sign_pipeline[stage_index];
        remainder_sign_pipeline[stage_index+1] <= remainder_sign_pipeline[stage_index];
        divide_by_zero_pipeline[stage_index+1] <= divide_by_zero_pipeline[stage_index];
        valid_pipeline[stage_index+1] <= i_rst ? 1'b0 : valid_pipeline[stage_index];
      end
    end
  endgenerate

  // Post-processing: apply sign correction and handle divide-by-zero cases
  // Unsigned results from pipeline
  wire [WIDTH-1:0] quotient_unsigned = quotient_pipeline[NumPipelineStages];
  wire [WIDTH-1:0] remainder_unsigned = remainder_pipeline[NumPipelineStages][WIDTH-1:0];

  // Apply sign correction for signed division (negate if needed)
  wire [WIDTH-1:0] quotient_signed = quotient_sign_pipeline[NumPipelineStages] ?
                                     (~quotient_unsigned + 1'b1) : quotient_unsigned;
  wire [WIDTH-1:0] remainder_signed = remainder_sign_pipeline[NumPipelineStages] ?
                                      (~remainder_unsigned + 1'b1) : remainder_unsigned;

  // Output results - special case for divide by zero per RISC-V spec
  assign o_quotient  = divide_by_zero_pipeline[NumPipelineStages] ?
                       {WIDTH{1'b1}} :  // All 1s for divide by zero
      quotient_signed;
  assign o_remainder = divide_by_zero_pipeline[NumPipelineStages] ?
                       dividend_pipeline[NumPipelineStages] :  // Return original dividend
      remainder_signed;

  assign o_valid_output = valid_pipeline[NumPipelineStages];

endmodule : divider
