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

// A decoded registered selector chooses among registered candidate masks.
module coherent_lq_candidate_select #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned SELECT_WIDTH = 3,
    localparam int unsigned CANDIDATES = 1 << SELECT_WIDTH,
    localparam int unsigned GROUPS = (CANDIDATES + 2) / 3
) (
    input logic i_clk,
    input logic [SELECT_WIDTH-1:0] i_select,
    input logic [CANDIDATES*WIDTH-1:0] i_candidates,
    output logic [WIDTH-1:0] o_selected
);
  (* keep = "true" *) logic [CANDIDATES-1:0] select_q;
  always_ff @(posedge i_clk) select_q <= CANDIDATES'(1) << i_select;
  for (genvar bit_index = 0; bit_index < WIDTH; bit_index++) begin : gen_bit
    (* keep = "true" *) logic [GROUPS-1:0] partial;
    for (genvar group_index = 0; group_index < GROUPS; group_index++) begin : gen_group
      localparam int unsigned Terms = CANDIDATES - 3 * group_index < 3 ?
          CANDIDATES - 3 * group_index : 3;
      logic [Terms-1:0] terms;
      for (genvar term_index = 0; term_index < Terms; term_index++) begin : gen_term
        localparam int unsigned Candidate = 3 * group_index + term_index;
        assign terms[term_index] = select_q[Candidate] &&
            i_candidates[Candidate*WIDTH+bit_index];
      end
      assign partial[group_index] = |terms;
    end
    assign o_selected[bit_index] = |partial;
  end
`ifndef SYNTHESIS
  logic [SELECT_WIDTH-1:0] reference_select_q;
  logic initialized = 1'b0;
  always_ff @(posedge i_clk) begin
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
          o_selected == i_candidates[reference_select_q*WIDTH+:WIDTH]);
  end
`endif
endmodule
