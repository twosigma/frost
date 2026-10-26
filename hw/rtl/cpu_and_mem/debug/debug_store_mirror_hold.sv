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

// An occupied mirror slot holds its address until consumption.
module debug_store_mirror_hold #(
    parameter int unsigned ADDR_WIDTH = 16
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_push,
    input logic i_pop,
    input logic [ADDR_WIDTH-1:0] i_addr,
    output logic o_valid,
    output logic [ADDR_WIDTH-1:0] o_addr
);
  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else if (o_valid) begin
      if (i_pop) o_valid <= 1'b0;
    end else if (i_push) o_valid <= 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) o_addr <= '0;
    else if (!o_valid) o_addr <= i_addr;
  end
`ifndef SYNTHESIS
  logic reference_valid, reference_seen = 1'b0;
  logic [ADDR_WIDTH-1:0] reference_addr;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reference_seen  <= 1'b1;
      reference_valid <= 1'b0;
      reference_addr  <= '0;
    end else if (reference_valid) begin
      if (i_pop) reference_valid <= 1'b0;
    end else if (i_push) begin
      reference_valid <= 1'b1;
      reference_addr  <= i_addr;
    end
    if (reference_seen) begin
      assert (o_valid == reference_valid);
      if (o_valid) assert (o_addr == reference_addr);
    end
  end
`endif
`ifdef FORMAL
  initial assume (i_rst);
`endif
endmodule
