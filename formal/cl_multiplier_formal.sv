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

// Compare all three result slices against a full polynomial product.
module cl_multiplier_formal (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [63:0] i_a,
    input logic [63:0] i_b,
    input logic i_reverse,
    input logic i_high
);
  logic [63:0] result;
  logic valid;
  cl_multiplier dut (
      .i_clk,
      .i_rst,
      .i_valid_input(i_valid),
      .i_operand_a(i_a),
      .i_operand_b(i_b),
      .i_reverse,
      .i_high,
      .o_result(result),
      .o_valid_output(valid)
  );
  logic [127:0] product;
  always_comb begin
    product = '0;
    for (int bit_idx = 0; bit_idx < 64; bit_idx++)
    if (i_b[bit_idx]) product ^= {64'b0, i_a} << bit_idx;
  end
  logic [63:0] expected[3];
  logic [2:0] expected_valid;
  logic past_valid = 1'b0;
  always @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_rst);
    if (i_rst) expected_valid <= '0;
    else expected_valid <= {expected_valid[1:0], i_valid};
    expected[0] <= i_reverse ? (i_high ? product[127:64] : product[126:63]) : product[63:0];
    expected[1] <= expected[0];
    expected[2] <= expected[1];
    if (past_valid) begin
      assert (valid == expected_valid[2]);
      if (valid) assert (result == expected[2]);
      cover (valid && result[63]);
    end
  end
endmodule : cl_multiplier_formal
