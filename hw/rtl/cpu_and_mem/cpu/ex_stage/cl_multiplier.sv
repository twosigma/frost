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

// Three-stage carry-less multiplier. Reversing both operands lets the low
// triangular product serve CLMUL, CLMULH, and CLMULR. Each group reduces eight
// multiplier bits before the final reduction and result reversal.
module cl_multiplier (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid_input,
    input logic [63:0] i_operand_a,
    input logic [63:0] i_operand_b,
    input logic i_reverse,
    input logic i_high,
    output logic [63:0] o_result,
    output logic o_valid_output
);
  logic [63:0] operand_a_q, operand_b_q;
  logic reverse_q, high_q, reverse_qq, high_qq;
  logic [ 2:0] valid_q;
  logic [63:0] partial_q[8];
  logic [63:0] reduced, reversed;

  always_ff @(posedge i_clk) begin
    if (i_rst) valid_q <= '0;
    else valid_q <= {valid_q[1:0], i_valid_input};
    for (int bit_idx = 0; bit_idx < 64; bit_idx++) begin
      operand_a_q[bit_idx] <= i_reverse ? i_operand_a[63-bit_idx] : i_operand_a[bit_idx];
      operand_b_q[bit_idx] <= i_reverse ? i_operand_b[63-bit_idx] : i_operand_b[bit_idx];
    end
    reverse_q <= i_reverse;
    high_q <= i_high;
    reverse_qq <= reverse_q;
    high_qq <= high_q;
  end
  assign o_valid_output = valid_q[2];

  for (genvar group_idx = 0; group_idx < 8; group_idx++) begin : gen_partial
    logic [63:0] partial;
    always_comb begin
      partial = '0;
      for (int bit_idx = 8 * group_idx; bit_idx < 8 * (group_idx + 1); bit_idx++)
      partial ^= (operand_a_q << bit_idx) & {64{operand_b_q[bit_idx]}};
    end
    always_ff @(posedge i_clk) partial_q[group_idx] <= partial;
  end

  always_comb begin
    reduced = '0;
    for (int group_idx = 0; group_idx < 8; group_idx++) reduced ^= partial_q[group_idx];
    for (int bit_idx = 0; bit_idx < 64; bit_idx++) reversed[bit_idx] = reduced[63-bit_idx];
  end
  always_ff @(posedge i_clk)
    o_result <= reverse_qq ? (high_qq ? {1'b0, reversed[63:1]} : reversed) : reduced;
endmodule : cl_multiplier
