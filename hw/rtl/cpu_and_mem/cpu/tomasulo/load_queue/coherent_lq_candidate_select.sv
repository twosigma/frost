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

// Registers the candidate mask the select names. A clear zeroes the
// registered selection.
module coherent_lq_candidate_select #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned SELECT_WIDTH = 3,
    localparam int unsigned CANDIDATES = 1 << SELECT_WIDTH
) (
    input logic i_clk,
    input logic i_clear,
    input logic [SELECT_WIDTH-1:0] i_select,
    input logic [CANDIDATES*WIDTH-1:0] i_candidates,
    output logic [WIDTH-1:0] o_selected
);
  always_ff @(posedge i_clk) begin
    if (i_clear) o_selected <= '0;
    else o_selected <= i_candidates[i_select*WIDTH+:WIDTH];
  end
`ifndef SYNTHESIS
  // The form this replaces: registered candidates chosen by a registered select.
  logic [CANDIDATES*WIDTH-1:0] reference_candidates_q;
  logic [SELECT_WIDTH-1:0] reference_select_q;
  logic initialized = 1'b0;
  always_ff @(posedge i_clk) begin
    reference_candidates_q <= i_clear ? '0 : i_candidates;
    reference_select_q <= i_select;
    initialized <= 1'b1;
  end
`ifdef FORMAL
  always_comb
`else
  always @(posedge i_clk)
`endif
  begin
    if (initialized)
      p_candidate_select_exact : assert (
          o_selected == reference_candidates_q[reference_select_q*WIDTH+:WIDTH]);
  end
`endif
endmodule
