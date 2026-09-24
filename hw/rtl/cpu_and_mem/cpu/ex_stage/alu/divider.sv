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
 * Radix-2 restoring divider for RISC-V DIV/REM, fully pipelined: a division
 * may start every cycle. Each stage runs two restoring iterations and so
 * produces two quotient bits, making the pipeline WIDTH/2 stages deep. With
 * the initialization stage, latency is WIDTH/2 + 1 cycles: 17 at WIDTH=32,
 * 33 at WIDTH=64. Operands enter as magnitudes. The output negates the
 * quotient when the operand signs differ, and the remainder when the
 * dividend is negative.
 *
 * Stage s has consumed only 2*s dividend bits, so its incoming remainder
 * fits in 2*s bits. Its two subtractors need only 2*s+3 bits, including
 * borrow. A divisor with any higher bit set cannot fit either shifted
 * remainder. Testing those bits separately avoids carrying through the
 * unused upper part of the early stages without changing their latency.
 *
 * RISC-V special cases:
 *   - Divide by zero: quotient = -1 (all 1s), remainder = dividend
 *   - Signed overflow (MIN_INT / -1): quotient = MIN_INT, remainder = 0,
 *     which falls out of two's-complement wraparound in the magnitude path
 *
 * int_muldiv_shim keeps its own copies of this latency, and each must equal
 * WIDTH/2 + 1 for its divider: DivPipeDepth sizes the in-flight tracker for
 * the full-width divider, and WordDivDepth sets where operations for the
 * 32-bit word divider enter that tracker.
 */
module divider #(
    parameter int unsigned WIDTH = 32  // Bit width
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
  // The pipeline divides magnitudes. These signs are re-applied at the output.
  logic dividend_is_negative, divisor_is_negative;
  logic quotient_should_be_negative, remainder_should_be_negative;
  logic [WIDTH-1:0] dividend_absolute_value, divisor_absolute_value;

  always_comb begin
    dividend_is_negative = i_is_signed_operation & i_dividend[WIDTH-1];
    divisor_is_negative = i_is_signed_operation & i_divisor[WIDTH-1];
    dividend_absolute_value = dividend_is_negative ? (~i_dividend + 1'b1) : i_dividend;
    divisor_absolute_value = divisor_is_negative ? (~i_divisor + 1'b1) : i_divisor;
    // The quotient is negative when the operand signs differ. The remainder
    // takes the sign of the dividend.
    quotient_should_be_negative = dividend_is_negative ^ divisor_is_negative;
    remainder_should_be_negative = dividend_is_negative;
  end

  // Two quotient bits per stage: 16 stages at WIDTH=32, 32 at WIDTH=64
  localparam int unsigned NumPipelineStages = WIDTH / 2;

  // Stage-boundary registers: entry 0 is the initialized input, entry
  // NumPipelineStages the finished division.
  logic [WIDTH-1:0] remainder_pipeline     [NumPipelineStages+1];
  // Keep a pipeline register at both ends of each extracted quotient delay
  // SRL, so stage arithmetic ends at a local flip-flop instead of an SRL
  // input. The SRL is shorter by those registers; the pipeline depth is the
  // same.
  (* srl_style = "reg_srl_reg" *)logic [WIDTH-1:0] quotient_pipeline      [NumPipelineStages+1];
  logic [WIDTH-1:0] divisor_pipeline       [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic [WIDTH-1:0] dividend_pipeline      [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             quotient_sign_pipeline [NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             remainder_sign_pipeline[NumPipelineStages+1];
  (* srl_style = "srl_reg" *)logic             divide_by_zero_pipeline[NumPipelineStages+1];
  logic             valid_pipeline         [NumPipelineStages+1];

  // Stage 0: latch the magnitudes, the result signs, and the zero-divisor flag.
  always_ff @(posedge i_clk) begin
    valid_pipeline[0] <= i_rst ? 1'b0 : i_valid_input;
    divisor_pipeline[0] <= divisor_absolute_value;
    dividend_pipeline[0] <= dividend_absolute_value;
    remainder_pipeline[0] <= '0;
    quotient_pipeline[0] <= dividend_absolute_value;  // Dividend shifts to become quotient
    quotient_sign_pipeline[0] <= quotient_should_be_negative;
    remainder_sign_pipeline[0] <= remainder_should_be_negative;
    divide_by_zero_pipeline[0] <= (i_divisor == '0) & i_valid_input;
  end

  // Main radix-2 restoring division pipeline (WIDTH/2 stages, filling entries 1..WIDTH/2)
  // Each stage computes two quotient bits through shift-and-subtract
  generate
    for (
        genvar stage_index = 0; stage_index < NumPipelineStages; ++stage_index
    ) begin : gen_division_stages
      localparam int unsigned RemainderWidth = 2 * (stage_index + 1);
      logic [RemainderWidth:0] remainder_shifted;
      logic [RemainderWidth:0] subtraction_result;
      logic subtraction_is_negative;
      logic [RemainderWidth:0] next_remainder;
      logic [1:0] quotient_bits;
      logic divisor_exceeds_remainder_width;

      // The remainder never exceeds the dividend prefix consumed so far,
      // including division by zero. Neither iteration can accept a divisor
      // with bits above this stage's two-bit-longer prefix. The final stage
      // uses all WIDTH bits, making this test constant false there.
      assign divisor_exceeds_remainder_width = |(divisor_pipeline[stage_index] >> RemainderWidth);

      // Two restoring iterations run back to back before the next stage register.
      always_comb begin
        // First iteration: shift the remainder left and pull in the next
        // dividend bit from the top of quotient_pipeline.
        remainder_shifted = {
          remainder_pipeline[stage_index][RemainderWidth-1:0],
          quotient_pipeline[stage_index][WIDTH-1]
        };
        subtraction_result = remainder_shifted - divisor_pipeline[stage_index][RemainderWidth-1:0];
        // A borrow or any omitted divisor bit means the full divisor did not
        // fit: restore the shifted remainder and leave the quotient bit zero.
        subtraction_is_negative = subtraction_result[RemainderWidth] |
            divisor_exceeds_remainder_width;
        next_remainder = subtraction_is_negative ? remainder_shifted : subtraction_result;
        quotient_bits[1] = ~subtraction_is_negative;

        // Second iteration: the same step on the next dividend bit down.
        remainder_shifted = {
          RemainderWidth'(next_remainder), quotient_pipeline[stage_index][WIDTH-2]
        };
        subtraction_result = remainder_shifted - divisor_pipeline[stage_index][RemainderWidth-1:0];
        subtraction_is_negative = subtraction_result[RemainderWidth] |
            divisor_exceeds_remainder_width;
        next_remainder = subtraction_is_negative ? remainder_shifted : subtraction_result;
        quotient_bits[0] = ~subtraction_is_negative;
      end

      always_ff @(posedge i_clk) begin
        remainder_pipeline[stage_index+1] <= WIDTH'(next_remainder);
        // The two new quotient bits shift in at the LSBs as the dividend bits
        // this stage consumed shift out of the top.
        quotient_pipeline[stage_index+1] <= {
          quotient_pipeline[stage_index][WIDTH-3:0], quotient_bits
        };
        divisor_pipeline[stage_index+1] <= divisor_pipeline[stage_index];
        dividend_pipeline[stage_index+1] <= dividend_pipeline[stage_index];
        quotient_sign_pipeline[stage_index+1] <= quotient_sign_pipeline[stage_index];
        remainder_sign_pipeline[stage_index+1] <= remainder_sign_pipeline[stage_index];
        divide_by_zero_pipeline[stage_index+1] <= divide_by_zero_pipeline[stage_index];
        valid_pipeline[stage_index+1] <= i_rst ? 1'b0 : valid_pipeline[stage_index];
      end

`ifdef DIVIDER_PREFIX_LOCAL_PROOF
      // Compositional lemma against the reference full-width restoring steps.
      // Entry 0 initializes each transaction's remainder to zero. Each stage
      // assumes the preceding prefix bound and proves the next one, so the
      // lemmas compose for valid results, including a zero divisor. Invalid
      // data left in the pipeline after reset need not obey this bound;
      // reset clears every valid bit independently of the data registers.
      logic [WIDTH:0] reference_remainder;
      logic [WIDTH:0] reference_shifted;
      logic [WIDTH:0] reference_subtraction;
      logic [1:0] reference_bits;
      always_comb begin
        assume ((remainder_pipeline[stage_index] >> (2 * stage_index)) == '0);
        reference_remainder = {1'b0, remainder_pipeline[stage_index]};
        for (int iteration = 0; iteration < 2; iteration++) begin
          reference_shifted = {
            WIDTH'(reference_remainder), quotient_pipeline[stage_index][WIDTH-1-iteration]
          };
          reference_subtraction = reference_shifted - {1'b0, divisor_pipeline[stage_index]};
          reference_bits[1-iteration] = !reference_subtraction[WIDTH];
          reference_remainder = reference_subtraction[WIDTH] ? reference_shifted :
              reference_subtraction;
        end
        assert (WIDTH'(next_remainder) == WIDTH'(reference_remainder));
        assert (quotient_bits == reference_bits);
        assert ((next_remainder >> RemainderWidth) == '0);
      end
`endif
    end
  endgenerate

  // Output stage: sign correction, then the divide-by-zero overrides.
  wire [WIDTH-1:0] quotient_unsigned = quotient_pipeline[NumPipelineStages];
  wire [WIDTH-1:0] remainder_unsigned = remainder_pipeline[NumPipelineStages][WIDTH-1:0];

  wire [WIDTH-1:0] quotient_signed = quotient_sign_pipeline[NumPipelineStages] ?
                                     (~quotient_unsigned + 1'b1) : quotient_unsigned;
  wire [WIDTH-1:0] remainder_signed = remainder_sign_pipeline[NumPipelineStages] ?
                                      (~remainder_unsigned + 1'b1) : remainder_unsigned;

  // Divide by zero returns the original dividend as the remainder. The
  // pipeline carries only its magnitude, so the sign comes back from
  // remainder_sign_pipeline. That bit equals dividend_is_negative for signed
  // ops and is 0 for unsigned ops, where the magnitude is already the answer.
  wire [WIDTH-1:0] dividend_signed = remainder_sign_pipeline[NumPipelineStages] ?
                                     (~dividend_pipeline[NumPipelineStages] + 1'b1) :
                                     dividend_pipeline[NumPipelineStages];

  // Divide by zero overrides the computed results, per the RISC-V spec.
  assign o_quotient  = divide_by_zero_pipeline[NumPipelineStages] ?
                       {WIDTH{1'b1}} :  // All 1s for divide by zero
      quotient_signed;
  assign o_remainder = divide_by_zero_pipeline[NumPipelineStages] ?
                       dividend_signed :  // Return original dividend (sign preserved)
      remainder_signed;

  assign o_valid_output = valid_pipeline[NumPipelineStages];

endmodule : divider
