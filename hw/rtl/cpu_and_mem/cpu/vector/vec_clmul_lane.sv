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
  One 64-bit carry-less multiply lane of the vector unit (Zvbc vclmul and
  vclmulh, SEW 64): the 128-bit carry-less product of a and b, returned as its
  low half, or its high half when i_high is set. The product is built as eight
  partial XORs of eight shifted copies of a each, combined in the next cycle,
  and appears a fixed two cycles after the cycle that takes the input, for
  every operand.
*/
module vec_clmul_lane (
    input  logic        i_clk,
    input  logic        i_rst,
    input  logic        i_valid,
    input  logic        i_high,
    input  logic [63:0] i_a,
    input  logic [63:0] i_b,
    output logic        o_valid,
    output logic [63:0] o_result
);

  logic s0_valid, s0_high;
  logic [63:0] s0_a, s0_b;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_high <= i_high;
    s0_a <= i_a;
    s0_b <= i_b;
  end

  // Partial product g: the XOR of a shifted by 8g+j for each set bit j of
  // byte g of b.
  logic [127:0] part[8];
  always_comb begin
    for (int g = 0; g < 8; g++) begin
      part[g] = '0;
      for (int j = 0; j < 8; j++) if (s0_b[8*g+j]) part[g] = part[g] ^ (128'(s0_a) << (8 * g + j));
    end
  end

  logic s1_valid, s1_high;
  logic [127:0] s1_part[8];
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_high <= s0_high;
    s1_part <= part;
  end

  logic [127:0] product;
  always_comb begin
    product = '0;
    for (int g = 0; g < 8; g++) product = product ^ s1_part[g];
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s1_valid;
    o_result <= s1_high ? product[127:64] : product[63:0];
  end

endmodule
