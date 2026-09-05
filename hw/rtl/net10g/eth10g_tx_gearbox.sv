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

// Elastic 66-to-64 packer. Bit zero is earliest on both interfaces.
// The raw output has no backpressure. Continuous block input produces a
// continuous raw stream after startup; the block ready rate is 32/33.
module eth10g_tx_gearbox (
    input logic i_clk,
    input logic i_rst,
    input logic [65:0] i_block,
    input logic i_block_valid,
    output logic o_block_ready,
    output logic [63:0] o_raw_data,
    output logic o_raw_valid
);
  logic [193:0] reservoir, next_reservoir;
  logic [7:0] count, next_count;
  assign o_raw_data = reservoir[63:0];
  assign o_raw_valid = !i_rst && count >= 8'd64;
  assign o_block_ready = !i_rst && count <= 8'd128;

  always_comb begin
    next_reservoir = reservoir;
    next_count = count;
    if (o_raw_valid) begin
      next_reservoir = next_reservoir >> 64;
      next_count = next_count - 8'd64;
    end
    if (i_block_valid && o_block_ready) begin
      next_reservoir = next_reservoir | ({{128{1'b0}}, i_block} << next_count);
      next_count = next_count + 8'd66;
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
