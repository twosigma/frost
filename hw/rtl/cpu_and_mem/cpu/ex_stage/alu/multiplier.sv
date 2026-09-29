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
 * Integer multiplier for the RISC-V M-extension. The shared
 * dsp_tiled_multiplier_unsigned core multiplies the operands' low XLEN bits,
 * and one subtraction in the upper half turns that product into the product
 * of the (XLEN+1)-bit signed operands. One operation may enter every cycle,
 * and latency is the same for every op sent here: MUL, MULH, MULHSU and
 * MULHU. With int_muldiv_shim's SHORT_WORD_OPS=0 it also runs MULW; by
 * default MULW uses a separate 32-bit tiled core. There are no early-outs in
 * this full-width path.
 *
 * Each operand is a = lo_a - sa*2^XLEN, where lo_a is its low XLEN bits and
 * sa its sign bit, so
 *   a*b = lo_a*lo_b - 2^XLEN*(sa*lo_b + sb*lo_a) + sa*sb*2^(2*XLEN).
 * The last term vanishes modulo 2^(2*XLEN): the 2*XLEN-bit result is the
 * unsigned product of the low parts with (sa*lo_b + sb*lo_a) subtracted from
 * its upper half.
 *
 * Pipeline:
 *   S0:         register the low parts, which the core's DSP input registers
 *               absorb, and the correction terms sb*lo_a and sa*lo_b in
 *               fabric. Only the terms depend on the sign bits, so no logic
 *               sits between the operands and the DSPs.
 *   tiled core: dsp_tiled_multiplier_unsigned, DSP48E2-shaped 27x35 tiles
 *               with a pipelined pairwise reduction tree. Its depth comes
 *               from riscv_pkg::dsp_tiled_stages, the single source of the
 *               staging formula. Beside it, the correction terms are summed
 *               in the first cycle and the sum rides a shift register.
 *   S_final:    subtract the correction from the product's upper half
 *               (registered).
 *
 * Total latency = 1 + dsp_tiled_stages(XLEN, XLEN, 27, 35) + 1 cycles,
 * exported to the shim as riscv_pkg::MulPipeDepth. The time-zero check at
 * the bottom of this file stops simulation if the two differ.
 *
 * Operand sign handling, done by the caller in the shim:
 *   MUL/MULW: both operands zero-extended to XLEN+1
 *   MULH:     both operands sign-extended
 *   MULHSU:   rs1 sign-extended, rs2 zero-extended
 *   MULHU:    both operands zero-extended
 */
module multiplier #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,
    input logic signed [XLEN:0] i_operand_a,  // (XLEN+1)-bit signed input
    input logic signed [XLEN:0] i_operand_b,  // (XLEN+1)-bit signed input
    input logic i_valid_input,  // Start multiplication (1 cycle pulse)
    output logic [2*XLEN-1:0] o_product_result,  // 2*XLEN product (registered)
    output logic o_valid_output,  // Result ready (MulPipeDepth cycles after input)
    output logic o_completing_next_cycle  // 1 cycle before o_valid_output
);

  localparam int unsigned ProdW = 2 * XLEN;
  localparam int unsigned TiledStages = riscv_pkg::dsp_tiled_stages(XLEN, XLEN, 27, 35);

  // ---------------------------------------------------------------------------
  // Stage S0: low parts and correction terms
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] a_lo_s0_reg, b_lo_s0_reg;
  logic [XLEN-1:0] corr_a_s0_reg, corr_b_s0_reg;  // sb*lo_a and sa*lo_b
  logic vld_s0_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) vld_s0_reg <= 1'b0;
    else vld_s0_reg <= i_valid_input;
  end

  always_ff @(posedge i_clk) begin
    a_lo_s0_reg   <= i_operand_a[XLEN-1:0];
    b_lo_s0_reg   <= i_operand_b[XLEN-1:0];
    corr_a_s0_reg <= i_operand_b[XLEN] ? i_operand_a[XLEN-1:0] : '0;
    corr_b_s0_reg <= i_operand_a[XLEN] ? i_operand_b[XLEN-1:0] : '0;
  end

  // ---------------------------------------------------------------------------
  // Tiled unsigned multiply core (shared with the FP datapaths)
  // ---------------------------------------------------------------------------
  logic [ProdW-1:0] uprod;
  logic uprod_valid;

  dsp_tiled_multiplier_unsigned #(
      .A_WIDTH(XLEN),
      .B_WIDTH(XLEN)
  ) u_tiled (
      .i_clk,
      .i_rst,
      .i_valid_input(vld_s0_reg),
      .i_operand_a(a_lo_s0_reg),
      .i_operand_b(b_lo_s0_reg),
      .o_product_result(uprod),
      .o_valid_output(uprod_valid),
      .o_completing_next_cycle()
  );

  // The correction is summed on the edge that starts the core and then rides
  // its own shift register beside it. Only its low XLEN bits reach the result.
  logic [XLEN-1:0] corr_pipe[TiledStages];
  always_ff @(posedge i_clk) begin
    corr_pipe[0] <= corr_a_s0_reg + corr_b_s0_reg;
    for (int s = 1; s < TiledStages; s++) begin
      corr_pipe[s] <= corr_pipe[s-1];
    end
  end
  logic [XLEN-1:0] corr_at_output;
  assign corr_at_output = corr_pipe[TiledStages-1];

  // ---------------------------------------------------------------------------
  // Stage S_final: subtract the correction from the upper half
  // ---------------------------------------------------------------------------
  logic [ProdW-1:0] prod_final_reg;
  logic vld_final_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) vld_final_reg <= 1'b0;
    else vld_final_reg <= uprod_valid;
  end

  always_ff @(posedge i_clk) begin
    prod_final_reg <= {uprod[ProdW-1:XLEN] - corr_at_output, uprod[XLEN-1:0]};
  end

  assign o_product_result        = prod_final_reg;
  assign o_valid_output          = vld_final_reg;
  assign o_completing_next_cycle = uprod_valid;

`ifndef SYNTHESIS
  // The shim sizes its tracker from riscv_pkg::MulPipeDepth, so this
  // module's real depth has to match it exactly.
  initial begin
    p_mul_pipe_depth_matches :
    assert ((1 + TiledStages + 1) == riscv_pkg::MulPipeDepth)
    else
      $fatal(
          1,
          "multiplier depth %0d != riscv_pkg::MulPipeDepth %0d",
          1 + TiledStages + 1,
          riscv_pkg::MulPipeDepth
      );
  end
`endif

endmodule : multiplier
