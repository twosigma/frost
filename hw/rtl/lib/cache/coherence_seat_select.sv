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

// Select the first eligible candidates that fit in the free seats. Each
// candidate's rank is the eligible count below it, saturated at three: six-bit
// group counts and a partial count within the candidate's own group add up in
// two levels of six-input functions.
module coherence_seat_select #(
    parameter int unsigned SLOTS = 19
) (
    input logic [SLOTS-1:0] i_eligible,
    input logic [1:0] i_occupied_count,
    input logic i_join,
    output logic [SLOTS-1:0] o_selected,
    output logic [1:0] o_selected_count
);
  localparam int unsigned GroupBits = 6;
  localparam int unsigned Groups = (SLOTS + GroupBits - 1) / GroupBits;
  // Counts saturate at three, the most seats a fill holds.
  function automatic logic [1:0] saturate(input int unsigned count);
    saturate = count > 3 ? 2'd3 : 2'(count);
  endfunction
  logic [1:0] room, total;
  logic [Groups-1:0][1:0] group_count;
  logic [SLOTS-1:0][1:0] rank;
  int unsigned group_sum;
  // Free seats: three less the occupied seats and a joining reader.
  assign room = int'(i_occupied_count) + int'(i_join) >= 3 ? 2'd0 :
      2'(3 - int'(i_occupied_count) - int'(i_join));
  for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_group
    localparam int unsigned Base  = group_index * GroupBits;
    localparam int unsigned Width = SLOTS - Base < GroupBits ? SLOTS - Base : GroupBits;
    assign group_count[group_index] = saturate($countones(i_eligible[Base+:Width]));
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_rank
    localparam int unsigned Group  = slot / GroupBits;
    localparam int unsigned Offset = slot % GroupBits;
    logic [1:0] partial;
    int unsigned below;
    if (Offset == 0) begin : gen_group_start
      assign partial = 2'd0;
    end else begin : gen_group_inner
      assign partial = saturate($countones(i_eligible[Group*GroupBits+:Offset]));
    end
    always_comb begin
      below = int'(partial);
      for (int index = 0; index < int'(Group); index++) below += int'(group_count[index]);
      rank[slot] = saturate(below);
    end
    assign o_selected[slot] = i_eligible[slot] && rank[slot] < room;
  end
  always_comb begin
    group_sum = 0;
    for (int index = 0; index < int'(Groups); index++) group_sum += int'(group_count[index]);
    total = saturate(group_sum);
  end
  assign o_selected_count = total < room ? total : room;
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
