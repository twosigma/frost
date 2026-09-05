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

// Clause 49 self-synchronizing x^58 + x^39 + 1 scrambler.
// Process payload bits from bit zero upward; sync headers bypass this module.
// A reset seeds history with ones. State and output hold when enable is low.
module eth10g_scrambler (
    input  logic        i_clk,
    input  logic        i_rst,
    input  logic        i_enable,
    input  logic [63:0] i_data,
    output logic [63:0] o_data
);
  logic [57:0] history, next_history;
  logic [63:0] next_data;
  always_comb begin
    next_history = history;
    next_data = '0;
    for (int bit_index = 0; bit_index < 64; bit_index++) begin
      next_data[bit_index] = i_data[bit_index] ^ next_history[38] ^ next_history[57];
      next_history = {next_history[56:0], next_data[bit_index]};
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      history <= '1;
      o_data  <= '0;
    end else if (i_enable) begin
      history <= next_history;
      o_data  <= next_data;
    end
  end
endmodule
