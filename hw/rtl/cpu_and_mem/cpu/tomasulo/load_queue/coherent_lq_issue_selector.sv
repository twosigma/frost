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

// Coherent issue selection computes both SQ drain states in parallel.
module coherent_lq_issue_selector #(
    parameter int unsigned DEPTH = riscv_pkg::LqDepth
) (
    input logic i_clk,
    input logic [DEPTH-1:0] lq_valid,
    input logic [DEPTH-1:0] lq_addr_valid,
    input logic [DEPTH-1:0] lq_is_mmio,
    input logic [DEPTH-1:0] lq_issued,
    input logic [DEPTH-1:0] lq_data_valid,
    input logic [DEPTH-1:0] lq_is_lr,
    input logic [DEPTH-1:0] lq_is_amo,
    input logic [DEPTH-1:0] sq_check_in_flight_mask,
    input logic [DEPTH-1:0] addr_update_pre_match_q,
    input logic [DEPTH-1:0] rob_head_match_q,
    input logic [DEPTH-1:0] blocked_by_amo_phys_q,
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] lq_rob_tag_flat,
    input logic [$clog2(DEPTH)-1:0] head_idx,
    input logic i_sq_committed_empty,
    input logic [DEPTH-1:0] i_staged_younger,

    output logic o_replace_without_update,
    output logic o_replace_with_update,

    output logic o_issue_cdb_found,
    output logic [$clog2(DEPTH)-1:0] o_issue_cdb_idx,
    output logic [DEPTH-1:0] o_merged_scan_onehot,
    output logic o_stored_scan_found,
    output logic [$clog2(DEPTH)-1:0] o_stored_scan_idx,
    output logic [$clog2(DEPTH)-1:0] o_stored_scan_pos,
    output logic [DEPTH-1:0] o_stored_scan_onehot,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_stored_scan_rob_tag,
    output logic o_update_scan_found,
    output logic [$clog2(DEPTH)-1:0] o_update_scan_idx,
    output logic [$clog2(DEPTH)-1:0] o_update_scan_pos,
    output logic [DEPTH-1:0] o_update_scan_onehot,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_update_scan_rob_tag,
    output logic o_head_mem_stored_found,
    output logic [$clog2(DEPTH)-1:0] o_head_mem_stored_idx,
    output logic [DEPTH-1:0] o_head_mem_stored_onehot,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_mem_stored_rob_tag,
    output logic o_head_mem_update_found,
    output logic [$clog2(DEPTH)-1:0] o_head_mem_update_idx,
    output logic [DEPTH-1:0] o_head_mem_update_onehot,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_mem_update_rob_tag
);
  typedef struct packed {
    logic replace_without_update;
    logic replace_with_update;
    logic issue_cdb_found;
    logic [$clog2(DEPTH)-1:0] issue_cdb_idx;
    logic [DEPTH-1:0] merged_scan_onehot;
    logic stored_scan_found;
    logic [$clog2(DEPTH)-1:0] stored_scan_idx;
    logic [$clog2(DEPTH)-1:0] stored_scan_pos;
    logic [DEPTH-1:0] stored_scan_onehot;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] stored_scan_rob_tag;
    logic update_scan_found;
    logic [$clog2(DEPTH)-1:0] update_scan_idx;
    logic [$clog2(DEPTH)-1:0] update_scan_pos;
    logic [DEPTH-1:0] update_scan_onehot;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] update_scan_rob_tag;
    logic head_mem_stored_found;
    logic [$clog2(DEPTH)-1:0] head_mem_stored_idx;
    logic [DEPTH-1:0] head_mem_stored_onehot;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_mem_stored_rob_tag;
    logic head_mem_update_found;
    logic [$clog2(DEPTH)-1:0] head_mem_update_idx;
    logic [DEPTH-1:0] head_mem_update_onehot;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_mem_update_rob_tag;
  } selection_t;
  selection_t selected;
  wire [$bits(selected)-1:0] choices[2];

  localparam int unsigned IdxWidth = $clog2(DEPTH);
  localparam int unsigned TagWidth = riscv_pkg::ReorderBufferTagWidth;
  logic [DEPTH-1:0] precedes[DEPTH];
  for (genvar selected = 0; selected < DEPTH; selected++) begin : gen_order
    for (genvar other = 0; other < DEPTH; other++) begin : gen_other
      if (other < selected) begin : gen_below
        if (selected == DEPTH - 1) begin : gen_last
          assign precedes[selected][other] = head_idx <= IdxWidth'(other);
        end else begin : gen_not_last
          assign precedes[selected][other] = head_idx <= IdxWidth'(other) ||
              head_idx > IdxWidth'(selected);
        end
      end else if (other > selected) begin : gen_above
        if (other == DEPTH - 1) begin : gen_last
          assign precedes[selected][other] = head_idx > IdxWidth'(selected);
        end else begin : gen_not_last
          assign precedes[selected][other] = head_idx <= IdxWidth'(other) &&
              head_idx > IdxWidth'(selected);
        end
      end else begin : gen_same
        assign precedes[selected][other] = 1'b0;
      end
    end
  end

  for (genvar drained = 0; drained < 2; drained++) begin : gen_drain_choice
    (* keep = "true" *) selection_t choice;
    logic [DEPTH-1:0] eligible[4];
    logic [DEPTH-1:0] first[4];
    logic [DEPTH-1:0] head_stored, head_update;
    assign choices[drained] = choice;
    for (genvar index = 0; index < DEPTH; index++) begin : gen_eligible
      wire available_without_valid = !lq_issued[index] && !lq_data_valid[index] &&
          !sq_check_in_flight_mask[index];
      wire atomic_ok = !(lq_is_lr[index] || lq_is_amo[index]) ||
          (rob_head_match_q[index] && 1'(drained));
      (* keep = "true" *) logic stored_ready, update_ready, merged_ready;
      (* keep = "true" *) logic head_stored_ready, head_update_ready;
      assign stored_ready = available_without_valid && lq_addr_valid[index] &&
          (!lq_is_mmio[index] || rob_head_match_q[index]) && atomic_ok &&
          !blocked_by_amo_phys_q[index];
      assign update_ready = available_without_valid && addr_update_pre_match_q[index] &&
          atomic_ok && !blocked_by_amo_phys_q[index];
      assign merged_ready = stored_ready || update_ready;
      assign head_stored_ready = available_without_valid && rob_head_match_q[index] &&
          lq_addr_valid[index] && (!(lq_is_lr[index] || lq_is_amo[index]) || 1'(drained));
      assign head_update_ready = available_without_valid && rob_head_match_q[index] &&
          addr_update_pre_match_q[index] &&
          (!(lq_is_lr[index] || lq_is_amo[index]) || 1'(drained));
      assign eligible[0][index] = lq_valid[index] && stored_ready;
      assign eligible[1][index] = lq_valid[index] && update_ready;
      assign eligible[2][index] = lq_valid[index] && merged_ready;
      assign eligible[3][index] = lq_valid[index] && lq_data_valid[index];
      assign head_stored[index] = lq_valid[index] && head_stored_ready;
      assign head_update[index] = lq_valid[index] && head_update_ready;
    end
    for (genvar source = 0; source < 4; source++) begin : gen_ring
      for (genvar index = 0; index < DEPTH; index++) begin : gen_first
        localparam int unsigned Groups = (DEPTH + 2) / 3;
        (* keep = "true" *) logic [Groups-1:0] earlier_group;
        for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_group
          localparam int unsigned Bits = DEPTH - 3 * group_index < 3 ?
              DEPTH - 3 * group_index : 3;
          assign earlier_group[group_index] =
              |(eligible[source][3*group_index+:Bits] & precedes[index][3*group_index+:Bits]);
        end
        assign first[source][index] = eligible[source][index] && !(|earlier_group);
      end
    end
    always_comb begin
      choice = '0;
      choice.issue_cdb_found = |eligible[3];
      choice.merged_scan_onehot = first[2];
      choice.stored_scan_found = |eligible[0];
      choice.stored_scan_onehot = first[0];
      choice.update_scan_found = |eligible[1];
      choice.update_scan_onehot = first[1];
      choice.head_mem_stored_found = |head_stored;
      choice.head_mem_stored_onehot = head_stored;
      choice.head_mem_update_found = |head_update;
      choice.head_mem_update_onehot = head_update;
      choice.replace_without_update = choice.head_mem_stored_found ?
          (|(i_staged_younger & head_stored)) : (|(i_staged_younger & first[0]));
      choice.replace_with_update = choice.head_mem_stored_found ?
          (|(i_staged_younger & head_stored)) : choice.head_mem_update_found ?
              (|(i_staged_younger & head_update)) : (|(i_staged_younger & first[2]));
      for (int index = 0; index < DEPTH; index++) begin
        choice.issue_cdb_idx |= IdxWidth'(index) & {IdxWidth{first[3][index]}};
        choice.stored_scan_idx |= IdxWidth'(index) & {IdxWidth{first[0][index]}};
        choice.stored_scan_pos |= IdxWidth'(IdxWidth'(index) - head_idx) &
            {IdxWidth{first[0][index]}};
        choice.stored_scan_rob_tag |= lq_rob_tag_flat[index*TagWidth+:TagWidth] &
            {TagWidth{first[0][index]}};
        choice.update_scan_idx |= IdxWidth'(index) & {IdxWidth{first[1][index]}};
        choice.update_scan_pos |= IdxWidth'(IdxWidth'(index) - head_idx) &
            {IdxWidth{first[1][index]}};
        choice.update_scan_rob_tag |= lq_rob_tag_flat[index*TagWidth+:TagWidth] &
            {TagWidth{first[1][index]}};
        choice.head_mem_stored_idx |= IdxWidth'(index) & {IdxWidth{rob_head_match_q[index]}};
        choice.head_mem_stored_rob_tag |= lq_rob_tag_flat[index*TagWidth+:TagWidth] &
            {TagWidth{rob_head_match_q[index]}};
      end
      choice.head_mem_update_idx = choice.head_mem_stored_idx;
      choice.head_mem_update_rob_tag = choice.head_mem_stored_rob_tag;
    end
  end
  assign selected = i_sq_committed_empty ? choices[1] : choices[0];
  // The result scan does not depend on the drain case, so its outputs come
  // from the first choice without the drain select.
  selection_t undrained;
  assign undrained = choices[0];
  assign o_replace_without_update = selected.replace_without_update;
  assign o_replace_with_update = selected.replace_with_update;
  assign o_issue_cdb_found = undrained.issue_cdb_found;
  assign o_issue_cdb_idx = undrained.issue_cdb_idx;
  assign o_merged_scan_onehot = selected.merged_scan_onehot;
  assign o_stored_scan_found = selected.stored_scan_found;
  assign o_stored_scan_idx = selected.stored_scan_idx;
  assign o_stored_scan_pos = selected.stored_scan_pos;
  assign o_stored_scan_onehot = selected.stored_scan_onehot;
  assign o_stored_scan_rob_tag = selected.stored_scan_rob_tag;
  assign o_update_scan_found = selected.update_scan_found;
  assign o_update_scan_idx = selected.update_scan_idx;
  assign o_update_scan_pos = selected.update_scan_pos;
  assign o_update_scan_onehot = selected.update_scan_onehot;
  assign o_update_scan_rob_tag = selected.update_scan_rob_tag;
  assign o_head_mem_stored_found = selected.head_mem_stored_found;
  assign o_head_mem_stored_idx = selected.head_mem_stored_idx;
  assign o_head_mem_stored_onehot = selected.head_mem_stored_onehot;
  assign o_head_mem_stored_rob_tag = selected.head_mem_stored_rob_tag;
  assign o_head_mem_update_found = selected.head_mem_update_found;
  assign o_head_mem_update_idx = selected.head_mem_update_idx;
  assign o_head_mem_update_onehot = selected.head_mem_update_onehot;
  assign o_head_mem_update_rob_tag = selected.head_mem_update_rob_tag;

`ifndef SYNTHESIS
  selection_t reference;
  lq_issue_selector #(
      .DEPTH(DEPTH)
  ) reference_selector (
      .lq_valid(lq_valid),
      .lq_addr_valid(lq_addr_valid),
      .lq_is_mmio(lq_is_mmio),
      .lq_issued(lq_issued),
      .lq_data_valid(lq_data_valid),
      .lq_is_lr(lq_is_lr),
      .lq_is_amo(lq_is_amo),
      .sq_check_in_flight_mask(sq_check_in_flight_mask),
      .addr_update_pre_match_q(addr_update_pre_match_q),
      .rob_head_match_q(rob_head_match_q),
      .blocked_by_amo_phys_q(blocked_by_amo_phys_q),
      .lq_rob_tag_flat(lq_rob_tag_flat),
      .head_idx(head_idx),
      .i_sq_committed_empty(i_sq_committed_empty),
      .o_issue_cdb_found(reference.issue_cdb_found),
      .o_issue_cdb_idx(reference.issue_cdb_idx),
      .o_merged_scan_onehot(reference.merged_scan_onehot),
      .o_stored_scan_found(reference.stored_scan_found),
      .o_stored_scan_idx(reference.stored_scan_idx),
      .o_stored_scan_pos(reference.stored_scan_pos),
      .o_stored_scan_onehot(reference.stored_scan_onehot),
      .o_stored_scan_rob_tag(reference.stored_scan_rob_tag),
      .o_update_scan_found(reference.update_scan_found),
      .o_update_scan_idx(reference.update_scan_idx),
      .o_update_scan_pos(reference.update_scan_pos),
      .o_update_scan_onehot(reference.update_scan_onehot),
      .o_update_scan_rob_tag(reference.update_scan_rob_tag),
      .o_head_mem_stored_found(reference.head_mem_stored_found),
      .o_head_mem_stored_idx(reference.head_mem_stored_idx),
      .o_head_mem_stored_onehot(reference.head_mem_stored_onehot),
      .o_head_mem_stored_rob_tag(reference.head_mem_stored_rob_tag),
      .o_head_mem_update_found(reference.head_mem_update_found),
      .o_head_mem_update_idx(reference.head_mem_update_idx),
      .o_head_mem_update_onehot(reference.head_mem_update_onehot),
      .o_head_mem_update_rob_tag(reference.head_mem_update_rob_tag)
  );
  assign reference.replace_without_update = reference.head_mem_stored_found ?
      (|(i_staged_younger & reference.head_mem_stored_onehot)) :
      (|(i_staged_younger & reference.stored_scan_onehot));
  assign reference.replace_with_update = reference.head_mem_stored_found ?
      (|(i_staged_younger & reference.head_mem_stored_onehot)) : reference.head_mem_update_found ?
          (|(i_staged_younger & reference.head_mem_update_onehot)) :
          (|(i_staged_younger & reference.merged_scan_onehot));
`ifdef FORMAL
  always_comb
`else
  always @(posedge i_clk)
`endif
  begin
    p_selection_exact : assert (selected == reference);
    p_result_scan_undrained :
    assert (o_issue_cdb_found == selected.issue_cdb_found &&
            o_issue_cdb_idx == selected.issue_cdb_idx);
  end
`endif
endmodule
