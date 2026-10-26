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

module coherence_read_payload_formal #(
    parameter int unsigned WIDTH = 42
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_allocate,
    input logic [2:0] i_allocate_id,
    input logic [WIDTH-1:0] i_payload
);
  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_rst);
  end
  coherence_read_payload #(
      .WIDTH(WIDTH)
  ) dut (
      .i_clk,
      .i_rst,
      .i_allocate,
      .i_allocate_id,
      .i_payload,
      .o_payload()
  );
endmodule
