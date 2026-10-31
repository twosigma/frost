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

// Request validity selects the count prepared from readiness and carry bits.
module coherent_debug_request_count #(
    parameter int unsigned WIDTH = 8
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic i_ready,
    output logic [WIDTH-1:0] o_count
);
  logic valid, ready;
  logic [WIDTH-1:0] carry;
  (* keep = "true" *) logic [WIDTH-1:0] ready_count, next_count;
  always_comb begin
    valid = 1'b0;
    ready = 1'b0;
    if (i_valid) valid = 1'b1;
    if (i_ready) ready = 1'b1;
  end
  assign carry[0] = 1'b1;
  for (genvar bit_index = 1; bit_index < WIDTH; bit_index++) begin : gen_carry
    assign carry[bit_index] = &o_count[bit_index-1:0];
  end
  assign ready_count = o_count ^ (carry & {WIDTH{ready}});
  assign next_count  = valid ? ready_count : o_count;
  always_ff @(posedge i_clk) begin
    if (i_rst) o_count <= '0;
    else o_count <= next_count;
  end
`ifndef SYNTHESIS
  logic [WIDTH-1:0] reference_count;
  logic reference_seen = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reference_count <= '0;
      reference_seen  <= 1'b1;
    end else if (i_valid && i_ready) reference_count <= reference_count + 1'b1;
    if (reference_seen) p_count_exact : assert (o_count === reference_count);
  end
`endif
`ifdef FORMAL
  initial assume (i_rst);
  always_comb begin
    p_next_exact : assert (next_count == o_count + WIDTH'(i_valid && i_ready));
  end
`endif
endmodule
