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
 * Takes 33-bit inputs (sign-extended for signed operations) and produces 64-bit result.
 * Uses FPGA DSP blocks for fast 33x33 signed multiplication.
 *
 * Timing:
 *   - 4-cycle latency: result available 4 cycles after valid input
 *   - Registered pipeline breaks critical timing path through DSP
 *   - Requires multi-cycle stall for dependent instructions
 *
 * Pipeline Integration:
 *   Cycle N:   MUL in EX - operands presented, multiply computes
 *   Cycle N+4: MUL in MA - o_product_result has correct value (registered)
 *   The multiply result must be captured separately since o_product_result
 *   is registered and not available combinationally in the same cycle.
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
    input logic signed [32:0] i_operand_a,  // 33-bit signed input (sign-extend for signed multiply)
    input logic signed [32:0] i_operand_b,  // 33-bit signed input
    input logic i_valid_input,  // Start multiplication
    output logic [63:0] o_product_result,  // 64-bit product output (registered)
    output logic o_valid_output,  // Result ready (PipeStages cycles after valid input)
    // Signals completion next cycle - used by hazard unit to end stall
    output logic o_completing_next_cycle
);

  // Pipeline depth after the DSP multiply (Vivado recommends 4 stages for 33x33).
  localparam int unsigned PipeStages = 4;

  (* use_dsp = "yes" *) logic [63:0] product;
  logic [63:0] product_pipe[PipeStages];
  logic [PipeStages-1:0] valid_pipe;

  // Pipelined registered multiplication using DSP blocks
  // The multiply is computed combinationally but the output is registered
  // across multiple stages, breaking the critical timing path.
  assign product = 64'(i_operand_a * i_operand_b);
  always_ff @(posedge i_clk) begin
    product_pipe[0] <= product;
    valid_pipe[0]   <= i_valid_input;
    for (int i = 1; i < PipeStages; i++) begin
      product_pipe[i] <= product_pipe[i-1];
      valid_pipe[i]   <= valid_pipe[i-1];
    end
  end

  assign o_product_result = product_pipe[PipeStages-1];
  assign o_valid_output   = valid_pipe[PipeStages-1];

  // Signal that multiply will complete next cycle (one stage before output valid).
  // This allows hazard unit to anticipate completion and end stall early.
  generate
    if (PipeStages > 1) begin : gen_complete_next
      assign o_completing_next_cycle = valid_pipe[PipeStages-2];
    end else begin : gen_complete_next_bypass
      assign o_completing_next_cycle = i_valid_input;
    end
  endgenerate

endmodule : multiplier
