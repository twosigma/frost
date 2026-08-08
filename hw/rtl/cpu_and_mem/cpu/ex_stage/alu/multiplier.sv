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
 * Fully-pipelined Integer Multiplier — RISC-V M-extension multiply operations
 *
 * Sign-correction wrapper around the shared dsp_tiled_multiplier_unsigned
 * core at (XLEN+1)-bit operands (plan decision D7). One operation may enter
 * every cycle; latency is uniform for every op (MUL/MULH/MULHSU/MULHU and,
 * at XLEN=64, MULW — no early-outs, so the shim's shift-register tracker
 * stays simple).
 *
 * Pipeline:
 *   S0            — convert the signed operands to (XLEN+1)-bit magnitudes
 *                   and capture the result-sign XOR (registered).
 *   tiled core    — dsp_tiled_multiplier_unsigned, DSP48E2-shaped 27x35
 *                   tiles with a pipelined pairwise reduction tree. Its
 *                   depth comes from riscv_pkg::dsp_tiled_stages (the single
 *                   source of the staging formula).
 *   S_final       — fused two's-complement sign correction of the unsigned
 *                   product via the XOR/carry-in identity
 *                   -(u) = (u ^ mask) + neg, one wide add (registered).
 *
 * Total latency = 1 + dsp_tiled_stages(XLEN+1, XLEN+1, 27, 35) + 1 cycles,
 * exported to the shim as riscv_pkg::MulPipeDepth; the elaboration check at
 * the bottom keeps this module and that constant from drifting (D7: the
 * depth is never hand-copied).
 *
 * Operand Sign Handling (caller in shim):
 *   MUL/MULW: Both operands zero-extended to XLEN+1
 *   MULH:     Both operands sign-extended
 *   MULHSU:   rs1 sign-extended, rs2 zero-extended
 *   MULHU:    Both operands zero-extended
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

  localparam int unsigned OpW = XLEN + 1;
  localparam int unsigned ProdW = 2 * OpW;
  localparam int unsigned TiledStages = riscv_pkg::dsp_tiled_stages(OpW, OpW, 27, 35);

  // ---------------------------------------------------------------------------
  // Stage S0 — capture magnitudes + sign
  // ---------------------------------------------------------------------------
  function automatic logic [OpW-1:0] abs_op(input logic signed [OpW-1:0] value);
    abs_op = value[OpW-1] ? (~value + 1'b1) : value;
  endfunction

  logic [OpW-1:0] a_mag_s0_reg, b_mag_s0_reg;
  logic neg_s0_reg;
  logic vld_s0_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) vld_s0_reg <= 1'b0;
    else vld_s0_reg <= i_valid_input;
  end

  always_ff @(posedge i_clk) begin
    a_mag_s0_reg <= abs_op(i_operand_a);
    b_mag_s0_reg <= abs_op(i_operand_b);
    neg_s0_reg   <= i_operand_a[OpW-1] ^ i_operand_b[OpW-1];
  end

  // ---------------------------------------------------------------------------
  // Tiled unsigned multiply core (shared with the FP datapaths)
  // ---------------------------------------------------------------------------
  logic [ProdW-1:0] uprod;
  logic uprod_valid;

  dsp_tiled_multiplier_unsigned #(
      .A_WIDTH(OpW),
      .B_WIDTH(OpW)
  ) u_tiled (
      .i_clk,
      .i_rst,
      .i_valid_input(vld_s0_reg),
      .i_operand_a(a_mag_s0_reg),
      .i_operand_b(b_mag_s0_reg),
      .o_product_result(uprod),
      .o_valid_output(uprod_valid),
      .o_completing_next_cycle()
  );

  // The sign bit rides its own shift register beside the tiled core.
  logic [TiledStages-1:0] neg_pipe;
  always_ff @(posedge i_clk) begin
    neg_pipe <= {neg_pipe[TiledStages-2:0], neg_s0_reg};
  end
  logic neg_at_output;
  assign neg_at_output = neg_pipe[TiledStages-1];

  // ---------------------------------------------------------------------------
  // Stage S_final — fused sign correction, one wide add:
  //   -(u) = ~u + 1 = (u ^ mask) + neg   with mask = {ProdW{neg}}
  // ---------------------------------------------------------------------------
  logic [ProdW-1:0] signed_prod_comb;
  assign signed_prod_comb = (uprod ^ {ProdW{neg_at_output}}) + ProdW'(neg_at_output);

  logic [ProdW-1:0] prod_final_reg;
  logic vld_final_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) vld_final_reg <= 1'b0;
    else vld_final_reg <= uprod_valid;
  end

  always_ff @(posedge i_clk) begin
    prod_final_reg <= signed_prod_comb;
  end

  assign o_product_result        = prod_final_reg[2*XLEN-1:0];
  assign o_valid_output          = vld_final_reg;
  assign o_completing_next_cycle = uprod_valid;

`ifndef SYNTHESIS
  // D7 drift check: the shim sizes its tracker from riscv_pkg::MulPipeDepth;
  // this module's real depth must match it exactly.
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
