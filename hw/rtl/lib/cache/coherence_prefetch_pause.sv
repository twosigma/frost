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

// DMA activity spans request acceptance through its response. Prefetches pause
// while DMA is offered or outstanding and for seven idle cycles afterward.
module coherence_prefetch_pause (
    input logic i_clk,
    input logic i_rst,
    input logic i_dma_valid,
    input logic i_dma_accept,
    input logic i_dma_response,
    output logic o_pause
`ifdef FORMAL
    , output logic [6:0] o_formal_state
`endif
);
  logic [3:0] outstanding_q;
  logic [2:0] quiet_q;
`ifdef FORMAL
  assign o_formal_state = {outstanding_q, quiet_q};
`endif
  assign o_pause = i_dma_valid || (|outstanding_q) || (|quiet_q);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      outstanding_q <= '0;
      quiet_q <= '0;
    end else begin
      outstanding_q <= outstanding_q + 4'(i_dma_accept) - 4'(i_dma_response);
      if (i_dma_valid || (|outstanding_q)) quiet_q <= '1;
      else if (|quiet_q) quiet_q <= quiet_q - 1'b1;
    end
  end
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst) begin
      assert (outstanding_q <= 8);
      if (i_dma_response) assert (outstanding_q != 0);
      if (i_dma_accept && !i_dma_response) assert (outstanding_q < 8);
    end
  end
`endif
endmodule
