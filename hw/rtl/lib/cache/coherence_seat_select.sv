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
// group counts, their prefix sums and each candidate's within-group count form
// kept six-input nodes so every candidate and the selected count settle in
// three LUT levels at up to twenty-four slots.
module coherence_seat_select #(
    parameter int unsigned SLOTS = 20
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
  function automatic logic [1:0] sat_add2(input logic [1:0] a, input logic [1:0] b);
    logic [2:0] sum;
    sum = {1'b0, a} + {1'b0, b};
    sat_add2 = sum > 3'd3 ? 2'd3 : sum[1:0];
  endfunction
  function automatic logic [1:0] sat_add3(input logic [1:0] a, input logic [1:0] b,
                                          input logic [1:0] c);
    logic [3:0] sum;
    sum = {2'b0, a} + {2'b0, b} + {2'b0, c};
    sat_add3 = sum > 4'd3 ? 2'd3 : sum[1:0];
  endfunction
  (* keep = "true" *) logic [1:0] room;
  (* keep = "true" *) logic [Groups-1:0][1:0] group_count;
  logic [Groups-1:0][1:0] group_prefix;
  // Free seats: three less the occupied seats and a joining reader.
  assign room = int'(i_occupied_count) + int'(i_join) >= 3 ? 2'd0 :
      2'(3 - int'(i_occupied_count) - int'(i_join));
  for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_group
    localparam int unsigned Base  = group_index * GroupBits;
    localparam int unsigned Width = SLOTS - Base < GroupBits ? SLOTS - Base : GroupBits;
    assign group_count[group_index] = saturate($countones(i_eligible[Base+:Width]));
  end
  // Saturated sum of group_count[0..group_index-1], built from kept nodes of
  // at most three two-bit counts (six inputs). Up to four groups (twenty-four
  // slots) complete in one level; wider tables extend by two groups per level.
  for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_prefix
    if (group_index == 0) begin : gen_zero
      assign group_prefix[0] = 2'd0;
    end else if (group_index == 1) begin : gen_one
      assign group_prefix[1] = group_count[0];
    end else if (group_index == 2) begin : gen_two
      (* keep = "true" *) logic [1:0] prefix_node;
      assign prefix_node = sat_add2(group_count[0], group_count[1]);
      assign group_prefix[2] = prefix_node;
    end else if (group_index == 3) begin : gen_three
      (* keep = "true" *) logic [1:0] prefix_node;
      assign prefix_node = sat_add3(group_count[0], group_count[1], group_count[2]);
      assign group_prefix[3] = prefix_node;
    end else if ((group_index % 2) == 0) begin : gen_even
      (* keep = "true" *) logic [1:0] prefix_node;
      assign prefix_node = sat_add2(group_prefix[group_index-1], group_count[group_index-1]);
      assign group_prefix[group_index] = prefix_node;
    end else begin : gen_odd
      (* keep = "true" *) logic [1:0] prefix_node;
      assign prefix_node = sat_add3(
          group_prefix[group_index-2], group_count[group_index-2], group_count[group_index-1]
      );
      assign group_prefix[group_index] = prefix_node;
    end
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_rank
    localparam int unsigned Group  = slot / GroupBits;
    localparam int unsigned Offset = slot % GroupBits;
    (* keep = "true" *) logic selected_node;
    if (Group == 0 && Offset == 0) begin : gen_g0_o0
      assign selected_node = i_eligible[slot] && room != 2'd0;
    end else if (Group == 0 && Offset == 1) begin : gen_g0_o1
      assign selected_node = i_eligible[slot] && ({2'b0, i_eligible[0]} < {1'b0, room});
    end else if (Group == 0) begin : gen_g0_inner
      (* keep = "true" *) logic [1:0] partial_node;
      assign partial_node  = saturate($countones(i_eligible[0+:Offset]));
      assign selected_node = i_eligible[slot] && partial_node < room;
    end else if (Offset == 0) begin : gen_o0
      assign selected_node = i_eligible[slot] && group_prefix[Group] < room;
    end else if (Offset == 1) begin : gen_o1
      assign selected_node = i_eligible[slot] &&
          ({1'b0, group_prefix[Group]} + {2'b0, i_eligible[Group*GroupBits]}) < {1'b0, room};
    end else begin : gen_inner
      // Saturating the within-group count to three when ineligible forces
      // group_prefix + partial >= 3 >= room, folding i_eligible[slot] into the
      // six-input partial node so selection fits in one six-input node.
      (* keep = "true" *) logic [1:0] partial_gated;
      assign partial_gated = i_eligible[slot] ? saturate(
          $countones(i_eligible[Group*GroupBits+:Offset])
      ) : 2'd3;
      assign selected_node = ({1'b0, group_prefix[Group]} + {1'b0, partial_gated}) < {1'b0, room};
    end
    assign o_selected[slot] = selected_node;
  end
  // Total eligible count is saturate(group_prefix[Groups-1] + group_count[Groups-1]).
  // Clamping directly against room depends only on those two counts and room
  // (six inputs).
  wire  [2:0] total_sum = {1'b0, group_prefix[Groups-1]} + {1'b0, group_count[Groups-1]};
  (* keep = "true" *)logic [1:0] selected_count_node;
  assign selected_count_node = total_sum < {1'b0, room} ? total_sum[1:0] : room;
  assign o_selected_count = selected_count_node;
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
