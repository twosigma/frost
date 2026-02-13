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
 * Pipelined Registered Multiplier - RISC-V M-extension multiply operations
 *
 * Implements a 4-cycle latency multiplier for MUL, MULH, MULHSU, MULHU instructions.
 * Takes 33-bit signed inputs and produces a 64-bit result.
 *
 * The datapath is explicitly tiled for DSP48E2-friendly mapping:
 *   - Convert signed operands to absolute magnitudes (33 bits)
 *   - Compute 33x33 unsigned product with 27x35 tiles (27x(18+17) cascade-friendly)
 *   - Apply final sign correction in a dedicated registered stage
 *
 * Timing:
 *   - 4-cycle latency from i_valid_input to o_valid_output
 *   - 3 cycles for 33x33 tiled unsigned multiply + 1 sign-correction stage
 *   - Wider configurations in shared tiled core can add more cycles (32-bit chunked reduction)
 *
 * Pipeline Integration:
 *   Cycle N:   Capture operands and operation sign
 *   Cycle N+3: Unsigned product magnitude ready
 *   Cycle N+4: Signed corrected product valid on o_product_result
 *
 * Operand Sign Handling (in ALU):
 *   MUL:    Both operands zero-extended (33'b0, rs1/rs2)
 *   MULH:   Both operands sign-extended ({rs[31], rs})
 *   MULHSU: rs1 sign-extended, rs2 zero-extended
 *   MULHU:  Both operands zero-extended
 *
 * Related Modules:
 *   - alu.sv: Instantiates multiplier, selects result portion (low/high 32 bits)
 *   - hazard_resolution_unit.sv: Stalls pipeline for multi-cycle multiply
 */
module multiplier (
    input logic i_clk,
    input logic i_rst,
    input logic signed [32:0] i_operand_a,  // 33-bit signed input (sign-extend for signed multiply)
    input logic signed [32:0] i_operand_b,  // 33-bit signed input
    input logic i_valid_input,  // Start multiplication
    output logic [63:0] o_product_result,  // 64-bit product output (registered)
    output logic o_valid_output,  // Result ready (PipeStages cycles after valid input)
    // Signals completion next cycle - used by hazard unit to end stall
    output logic o_completing_next_cycle
);

  function automatic logic [32:0] abs_33(input logic signed [32:0] value);
    abs_33 = value[32] ? (~value + 33'd1) : value;
  endfunction

  logic result_is_negative_reg;

  logic [32:0] operand_a_magnitude;
  logic [32:0] operand_b_magnitude;
  logic [65:0] product_magnitude;
  logic product_magnitude_valid;

  logic signed [65:0] product_signed_reg;
  logic product_signed_valid_reg;

  assign operand_a_magnitude = abs_33(i_operand_a);
  assign operand_b_magnitude = abs_33(i_operand_b);

  // Capture final sign once per operation (only one in-flight multiply is allowed).
  always_ff @(posedge i_clk) begin
    if (i_rst) result_is_negative_reg <= 1'b0;
    else if (i_valid_input) result_is_negative_reg <= i_operand_a[32] ^ i_operand_b[32];
  end

  // 33x33 tiled unsigned multiply using cascade-friendly {27x35} tiles.
  // Shared core uses chunked 32-bit reductions; this configuration resolves in 3 cycles.
  dsp_tiled_multiplier_unsigned #(
      .A_WIDTH(33),
      .B_WIDTH(33)
  ) u_dsp_tiled_unsigned_mul (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid_input(i_valid_input),
      .i_operand_a(operand_a_magnitude),
      .i_operand_b(operand_b_magnitude),
      .o_product_result(product_magnitude),
      .o_valid_output(product_magnitude_valid),
      .o_completing_next_cycle(  /*unused*/)
  );

  // Final sign correction stage (kept registered to balance timing).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      product_signed_reg <= '0;
      product_signed_valid_reg <= 1'b0;
    end else begin
      product_signed_valid_reg <= product_magnitude_valid;
      if (product_magnitude_valid) begin
        product_signed_reg <= result_is_negative_reg ? -$signed(product_magnitude) :
            $signed(product_magnitude);
      end
    end
  end

  assign o_product_result = product_signed_reg[63:0];
  assign o_valid_output = product_signed_valid_reg;
  // Product magnitude stage completes one cycle before final signed output.
  assign o_completing_next_cycle = product_magnitude_valid;

endmodule : multiplier
