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

// Rank candidates before applying the available-seat limit.
module coherence_seat_select #(
    parameter int unsigned SLOTS = 19
) (
    input logic [SLOTS-1:0] i_eligible,
    input logic [SLOTS-1:0] i_occupied,
    input logic i_join,
    output logic [SLOTS-1:0] o_selected
);
  localparam int unsigned CountBits = $clog2(SLOTS + 1);
  logic [CountBits-1:0] occupied;
  logic [2:0] allow_rank;
  logic [2:0][SLOTS-1:0] ranked;
  assign occupied = CountBits'($countones(i_occupied));
  assign allow_rank[0] = occupied < 3 && !(i_join && occupied == 2);
  assign allow_rank[1] = occupied < 2 && !(i_join && occupied == 1);
  assign allow_rank[2] = occupied == 0 && !i_join;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_rank
    if (slot == 0) begin : gen_first
      assign ranked[0][slot] = i_eligible[slot];
      assign ranked[1][slot] = 1'b0;
      assign ranked[2][slot] = 1'b0;
    end else begin : gen_later
      localparam int unsigned PrefixBits = $clog2(slot + 1);
      logic [PrefixBits-1:0] earlier;
      assign earlier = PrefixBits'($countones(i_eligible[slot-1:0]));
      for (genvar rank_index = 0; rank_index < 3; rank_index++) begin : gen_compare
        assign ranked[rank_index][slot] = i_eligible[slot] && int'(earlier) == rank_index;
      end
    end
  end
  assign o_selected = ({SLOTS{allow_rank[0]}} & ranked[0]) |
      ({SLOTS{allow_rank[1]}} & ranked[1]) | ({SLOTS{allow_rank[2]}} & ranked[2]);
`ifndef SYNTHESIS
  logic [SLOTS-1:0] reference_selected;
  integer seats;
  always_comb begin
    seats = $countones(i_occupied) + int'(i_join);
    reference_selected = '0;
    for (int slot = 0; slot < SLOTS; slot++) begin
      if (i_eligible[slot] && seats < 3) begin
        reference_selected[slot] = 1'b1;
        seats++;
      end
    end
    assert (o_selected == reference_selected);
  end
`endif
endmodule
