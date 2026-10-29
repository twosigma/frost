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
    input logic [1:0] i_occupied_count,
    input logic i_join,
    output logic [SLOTS-1:0] o_selected,
    output logic [1:0] o_selected_count
);
  logic [2:0] allow_rank;
  logic [2:0][SLOTS-1:0] ranked;
  assign allow_rank[0] = i_occupied_count < 3 && !(i_join && i_occupied_count == 2);
  assign allow_rank[1] = i_occupied_count < 2 && !(i_join && i_occupied_count == 1);
  assign allow_rank[2] = i_occupied_count == 0 && !i_join;
  localparam int unsigned Levels = $clog2(SLOTS);
  (* keep = "true" *) logic [Levels:0][SLOTS-1:0][2:0] prefix_count;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_leaf
    assign prefix_count[0][slot] = {2'b0, i_eligible[slot]};
  end
  for (genvar level = 0; level < Levels; level++) begin : gen_level
    for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_slot
      if (slot < (1 << level)) begin : gen_copy
        assign prefix_count[level+1][slot] = prefix_count[level][slot];
      end else begin : gen_merge
        wire [2:0] a = prefix_count[level][slot];
        wire [2:0] b = prefix_count[level][slot-(1<<level)];
        assign prefix_count[level+1][slot][0] = a[0] || b[0];
        assign prefix_count[level+1][slot][1] = a[1] || b[1] || (a[0] && b[0]);
        assign prefix_count[level+1][slot][2] = a[2] || b[2] || (a[1] && b[0]) || (a[0] && b[1]);
      end
    end
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_rank
    if (slot == 0) begin : gen_first
      assign ranked[0][slot] = i_eligible[slot];
      assign ranked[1][slot] = 1'b0;
      assign ranked[2][slot] = 1'b0;
    end else begin : gen_later
      assign ranked[0][slot] = i_eligible[slot] && !prefix_count[Levels][slot-1][0];
      assign ranked[1][slot] = i_eligible[slot] && prefix_count[Levels][slot-1][0] &&
          !prefix_count[Levels][slot-1][1];
      assign ranked[2][slot] = i_eligible[slot] && prefix_count[Levels][slot-1][1] &&
          !prefix_count[Levels][slot-1][2];
    end
  end
  assign o_selected = ({SLOTS{allow_rank[0]}} & ranked[0]) |
      ({SLOTS{allow_rank[1]}} & ranked[1]) | ({SLOTS{allow_rank[2]}} & ranked[2]);
  assign o_selected_count = 2'(allow_rank[0] && |ranked[0]) +
      2'(allow_rank[1] && |ranked[1]) + 2'(allow_rank[2] && |ranked[2]);
`ifndef SYNTHESIS
  logic [SLOTS-1:0] reference_selected;
  integer seats;
  always_comb begin
    seats = int'(i_occupied_count) + int'(i_join);
    reference_selected = '0;
    for (int slot = 0; slot < SLOTS; slot++) begin
      if (i_eligible[slot] && seats < 3) begin
        reference_selected[slot] = 1'b1;
        seats++;
      end
    end
    assert (o_selected == reference_selected);
    assert (int'(o_selected_count) == $countones(o_selected));
  end
`endif
endmodule
