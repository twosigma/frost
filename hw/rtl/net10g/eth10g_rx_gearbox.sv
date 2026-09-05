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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Two Sigma Open Source, LLC

// Raw 64-bit stream to candidate 66-bit blocks. A slip consumes one extra bit
// together with the current candidate. Keeping one lookahead bit makes every
// slip atomic, including candidates that straddle a raw word boundary.
module eth10g_rx_gearbox (
    input logic i_clk,
    input logic i_rst,
    input logic [63:0] i_raw_data,
    input logic i_raw_valid,
    input logic i_slip,
    output logic [65:0] o_block,
    output logic o_block_valid
);
  logic [193:0] reservoir, next_reservoir;
  logic [7:0] count, next_count;
  assign o_block = reservoir[65:0];
  assign o_block_valid = !i_rst && count >= 8'd67;

  always_comb begin
    next_reservoir = reservoir;
    next_count = count;
    if (o_block_valid) begin
      next_reservoir = next_reservoir >> (i_slip ? 67 : 66);
      next_count = next_count - (i_slip ? 8'd67 : 8'd66);
    end
    if (i_raw_valid) begin
      next_reservoir = next_reservoir | ({{130{1'b0}}, i_raw_data} << next_count);
      next_count = next_count + 8'd64;
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reservoir <= '0;
      count <= '0;
    end else begin
      reservoir <= next_reservoir;
      count <= next_count;
    end
  end
endmodule
