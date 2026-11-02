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

// Ready work precedes other eligible work within circular priority.
// With LAST_CODED, the last input stands for a group of slots kept apart:
// picking it yields i_last_code, the slot the group offers, in place of the
// input's index.
module coherence_work_select #(
    parameter int unsigned SLOTS = 19,
    parameter bit LAST_CODED = 1'b0,
    parameter int unsigned CODE_BITS = SLOTS > 1 ? $clog2(SLOTS) : 1
) (
    input logic [SLOTS-1:0] i_eligible,
    input logic [SLOTS-1:0] i_ready,
    // i_later[slot]: the slot is at or after the rotation point.
    input logic [SLOTS-1:0] i_later,
    input logic [CODE_BITS-1:0] i_last_code,
    output logic o_found,
    output logic [CODE_BITS-1:0] o_pick
);
  localparam int unsigned GroupBits = 6;
  localparam int unsigned Groups = (SLOTS + GroupBits - 1) / GroupBits;
  logic [3:0][SLOTS-1:0] candidates;
  (* keep = "true" *) logic [3:0][SLOTS-1:0] class_selected;
  // Six-slot candidate summaries; each slot's priority comes from the lower
  // groups' summaries and its own group's lower slots.
  (* keep = "true" *) logic [3:0][Groups-1:0] class_groups;
  logic [3:0] class_found;
  logic [3:0][CODE_BITS-1:0] class_pick;
  // Each input's pick: its index, or i_last_code for a coded last input.
  logic [SLOTS-1:0][CODE_BITS-1:0] codes;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_codes
    assign codes[slot] = LAST_CODED && slot == SLOTS - 1 ? i_last_code : CODE_BITS'(slot);
  end
  logic [SLOTS-1:0] selected;
  assign o_found = |i_eligible;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_candidates
    assign candidates[0][slot] = i_eligible[slot] && i_ready[slot] && i_later[slot];
    assign candidates[1][slot] = i_eligible[slot] && i_ready[slot];
    assign candidates[2][slot] = i_eligible[slot] && i_later[slot];
    assign candidates[3][slot] = i_eligible[slot];
  end
  for (genvar choice = 0; choice < 4; choice++) begin : gen_class
    for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_group
      localparam int unsigned Base  = group_index * GroupBits;
      localparam int unsigned Width = SLOTS - Base < GroupBits ? SLOTS - Base : GroupBits;
      assign class_groups[choice][group_index] = |candidates[choice][Base+:Width];
    end
    assign class_found[choice] = |class_groups[choice];
    for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_priority
      localparam int unsigned Group  = slot / GroupBits;
      localparam int unsigned Offset = slot % GroupBits;
      logic below;
      always_comb begin
        below = 1'b0;
        for (int group_index = 0; group_index < int'(Group); group_index++)
        below |= class_groups[choice][group_index];
        for (int lower = 0; lower < int'(Offset); lower++)
        below |= candidates[choice][Group*GroupBits+lower];
      end
      assign class_selected[choice][slot] = candidates[choice][slot] && !below;
    end
    for (genvar bit_index = 0; bit_index < CODE_BITS; bit_index++) begin : gen_encode
      logic [SLOTS-1:0] contributors;
      for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_contributor
        assign contributors[slot] = class_selected[choice][slot] && codes[slot][bit_index];
      end
      assign class_pick[choice][bit_index] = |contributors;
    end
  end
  assign selected = class_found[0] ? class_selected[0] : class_found[1] ? class_selected[1] :
      class_found[2] ? class_selected[2] : class_selected[3];
  assign o_pick = class_found[0] ? class_pick[0] : class_found[1] ? class_pick[1] :
      class_found[2] ? class_pick[2] : class_pick[3];
  // The indexed inputs' picks fit in CODE_BITS.
  if (SLOTS < 1 || CODE_BITS < 1 || CODE_BITS > 16 ||
      (1 << CODE_BITS) < (LAST_CODED ? SLOTS - 1 : SLOTS)) begin : gen_invalid
    initial $fatal(1, "coherence_work_select: invalid parameters");
  end
`ifndef SYNTHESIS
  logic [CODE_BITS-1:0] reference_pick, reference_first;
  logic reference_after, ready_found;
  always_comb begin
    ready_found = |(i_eligible & i_ready);
    reference_pick = '0;
    reference_first = '0;
    reference_after = 1'b0;
    for (int slot = SLOTS - 1; slot >= 0; slot--) begin
      if (i_eligible[slot] && (!ready_found || i_ready[slot])) begin
        reference_first = codes[slot];
        if (i_later[slot]) begin
          reference_after = 1'b1;
          reference_pick  = codes[slot];
        end
      end
    end
    if (!reference_after) reference_pick = reference_first;
    assert (o_pick == reference_pick);
    assert ($onehot0(selected));
  end
`endif
endmodule
