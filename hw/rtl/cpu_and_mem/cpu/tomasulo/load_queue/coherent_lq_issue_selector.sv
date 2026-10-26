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

  for (genvar drained = 0; drained < 2; drained++) begin : gen_drain_choice
    (* keep = "true" *) selection_t choice;
    assign choices[drained] = choice;
    lq_issue_selector #(
        .DEPTH(DEPTH)
    ) selector (
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
        .i_sq_committed_empty(1'(drained)),
        .o_issue_cdb_found(choice.issue_cdb_found),
        .o_issue_cdb_idx(choice.issue_cdb_idx),
        .o_merged_scan_onehot(choice.merged_scan_onehot),
        .o_stored_scan_found(choice.stored_scan_found),
        .o_stored_scan_idx(choice.stored_scan_idx),
        .o_stored_scan_pos(choice.stored_scan_pos),
        .o_stored_scan_onehot(choice.stored_scan_onehot),
        .o_stored_scan_rob_tag(choice.stored_scan_rob_tag),
        .o_update_scan_found(choice.update_scan_found),
        .o_update_scan_idx(choice.update_scan_idx),
        .o_update_scan_pos(choice.update_scan_pos),
        .o_update_scan_onehot(choice.update_scan_onehot),
        .o_update_scan_rob_tag(choice.update_scan_rob_tag),
        .o_head_mem_stored_found(choice.head_mem_stored_found),
        .o_head_mem_stored_idx(choice.head_mem_stored_idx),
        .o_head_mem_stored_onehot(choice.head_mem_stored_onehot),
        .o_head_mem_stored_rob_tag(choice.head_mem_stored_rob_tag),
        .o_head_mem_update_found(choice.head_mem_update_found),
        .o_head_mem_update_idx(choice.head_mem_update_idx),
        .o_head_mem_update_onehot(choice.head_mem_update_onehot),
        .o_head_mem_update_rob_tag(choice.head_mem_update_rob_tag)
    );
  end
  assign selected = i_sq_committed_empty ? choices[1] : choices[0];
  assign o_issue_cdb_found = selected.issue_cdb_found;
  assign o_issue_cdb_idx = selected.issue_cdb_idx;
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
  always_comb begin
    p_selection_exact : assert (selected == reference);
  end
`endif
endmodule
