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

// =============================================================================
// lq_issue_selector
// =============================================================================
// Select CDB-ready and memory-issue entries in ring order from head_idx,
// with a separate ROB-head priority path. Ring order is not age order because
// allocation refills holes. issue_cdb_idx selects the LQ data LUTRAM read.
//
// load_queue registers the older-AMO block vector in physical entry order.
// This combinational selector rotates it into scan order. A freed or flushed
// entry can retain a stale block bit for its first invalid cycle; lq_valid
// masks it here, and load_queue clears it before reuse. A head AMO requires
// i_sq_committed_empty.
// =============================================================================
module lq_issue_selector #(
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

  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  logic issue_cdb_found;
  logic [IdxWidth-1:0] issue_cdb_idx;

  function automatic logic [DEPTH-1:0] rotate_mask_from_head(input logic [DEPTH-1:0] mask,
                                                             input logic [IdxWidth-1:0] start_idx);
    logic [(2*DEPTH)-1:0] doubled;
    logic [(2*DEPTH)-1:0] shifted;
    begin
      doubled = {mask, mask};
      shifted = doubled >> start_idx;
      rotate_mask_from_head = shifted[DEPTH-1:0];
    end
  endfunction

  // Pre-computed circular scan indices (head-relative order)
  logic [IdxWidth-1:0] scan_idx[DEPTH];
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++) begin
      scan_idx[j] = IdxWidth'(head_idx + IdxWidth'(j));
    end
  end

  // Phase A: choose the lowest ready index at or above head_idx, or wrap to
  // the lowest ready index. The found bit is independent of head_idx.
  logic [DEPTH-1:0] cdb_ready_phys;
  logic [DEPTH-1:0] at_or_above_head;
  logic [DEPTH-1:0] cdb_ready_upper;
  logic cdb_upper_found;
  logic [IdxWidth-1:0] cdb_upper_idx;
  logic [IdxWidth-1:0] cdb_lowest_idx;
  assign cdb_ready_phys = lq_valid & lq_data_valid;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      at_or_above_head[i] = IdxWidth'(i) >= head_idx;
    end
  end
  assign cdb_ready_upper = cdb_ready_phys & at_or_above_head;
  assign cdb_upper_found = |cdb_ready_upper;
  always_comb begin
    cdb_upper_idx  = '0;
    cdb_lowest_idx = '0;
    for (int i = DEPTH - 1; i >= 0; i--) begin
      if (cdb_ready_upper[i]) cdb_upper_idx = IdxWidth'(i);
      if (cdb_ready_phys[i]) cdb_lowest_idx = IdxWidth'(i);
    end
  end
  assign issue_cdb_found = |cdb_ready_phys;
  assign issue_cdb_idx   = cdb_upper_found ? cdb_upper_idx : cdb_lowest_idx;

`ifndef SYNTHESIS
`ifndef FORMAL
  // Scan indices wrap at 2**IdxWidth, so DEPTH must be a power of two to
  // visit every entry exactly once.
  initial begin
    assert ((1 << IdxWidth) == DEPTH)
    else $error("lq_issue_selector: DEPTH must be a power of two");
  end
`endif
`endif

  // Registered one-hot mask of the entry in the sq_check staging register.
  logic [DEPTH-1:0] in_flight_mask;
  assign in_flight_mask = sq_check_in_flight_mask;

  // Phase B: select stored-address and arriving-address candidates separately.
  // load_queue chooses between them using the current address-update valid.
  logic [DEPTH-1:0] mem_eligible_stored_phys;
  logic [DEPTH-1:0] mem_eligible_update_phys;
  logic [DEPTH-1:0] mem_eligible_stored_mask;
  logic [DEPTH-1:0] mem_eligible_update_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      // MMIO is eligible only at the ROB head, where the head path takes
      // priority. The memory router drains committed stores before device reads.
      mem_eligible_stored_phys[i] =
          lq_valid[i] &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!lq_is_mmio[i] || rob_head_match_q[i]) &&
          (!lq_is_lr[i]   || rob_head_match_q[i]) &&
          (!lq_is_amo[i]  || (rob_head_match_q[i] && i_sq_committed_empty));

      mem_eligible_update_phys[i] =
          lq_valid[i] &&
          addr_update_pre_match_q[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!lq_is_lr[i]   || rob_head_match_q[i]) &&
          (!lq_is_amo[i]  || (rob_head_match_q[i] && i_sq_committed_empty));
    end
  end
  assign mem_eligible_stored_mask = rotate_mask_from_head(mem_eligible_stored_phys, head_idx);
  assign mem_eligible_update_mask = rotate_mask_from_head(mem_eligible_update_phys, head_idx);

  // Rotate older-AMO blocking into the same order as the eligibility masks.
  logic [DEPTH-1:0] blocked_by_amo;
  assign blocked_by_amo = rotate_mask_from_head(blocked_by_amo_phys_q, head_idx);

  logic [DEPTH-1:0] mem_issue_stored_mask;
  logic [DEPTH-1:0] mem_issue_update_mask;
  assign mem_issue_stored_mask = mem_eligible_stored_mask & ~blocked_by_amo;
  assign mem_issue_update_mask = mem_eligible_update_mask & ~blocked_by_amo;

  // Encode the first stored-address and arriving-address candidates.
  logic stored_scan_found;
  logic [IdxWidth-1:0] stored_scan_idx;
  logic [IdxWidth-1:0] stored_scan_pos;
  logic [DEPTH-1:0] stored_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] stored_scan_rob_tag;

  logic update_scan_found;
  logic [IdxWidth-1:0] update_scan_idx;
  logic [IdxWidth-1:0] update_scan_pos;
  logic [DEPTH-1:0] update_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] update_scan_rob_tag;

  always_comb begin
    stored_scan_found   = 1'b0;
    stored_scan_idx     = '0;
    stored_scan_pos     = '0;
    stored_scan_onehot  = '0;
    stored_scan_rob_tag = '0;
    update_scan_found   = 1'b0;
    update_scan_idx     = '0;
    update_scan_pos     = '0;
    update_scan_onehot  = '0;
    update_scan_rob_tag = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (mem_issue_stored_mask[i] && !stored_scan_found) begin
        stored_scan_found = 1'b1;
        stored_scan_idx = scan_idx[i];
        stored_scan_pos = IdxWidth'(i);
        stored_scan_onehot[scan_idx[i]] = 1'b1;
        stored_scan_rob_tag =
            lq_rob_tag_flat[scan_idx[i]*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      end

      if (mem_issue_update_mask[i] && !update_scan_found) begin
        update_scan_found = 1'b1;
        update_scan_idx = scan_idx[i];
        update_scan_pos = IdxWidth'(i);
        update_scan_onehot[scan_idx[i]] = 1'b1;
        update_scan_rob_tag =
            lq_rob_tag_flat[scan_idx[i]*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      end
    end
  end

  // Select the first candidate across both address sources for replacement.
  // This selection omits address-update valid; load_queue qualifies it and
  // applies ROB-head priority separately.
  logic [DEPTH-1:0] merged_eligible_phys, merged_upper;
  logic merged_upper_found;
  (* keep = "true" *) logic [DEPTH-1:0] merged_first_upper, merged_first_any;
  assign merged_eligible_phys =
      (mem_eligible_stored_phys | mem_eligible_update_phys) & ~blocked_by_amo_phys_q;
  assign merged_upper = merged_eligible_phys & at_or_above_head;
  assign merged_upper_found = |merged_upper;
  for (genvar g = 0; g < DEPTH; g++) begin : gen_merged_physical
    if (g == 0) begin : gen_first
      assign merged_first_upper[g] = merged_upper[g];
      assign merged_first_any[g]   = merged_eligible_phys[g];
    end else begin : gen_later
      assign merged_first_upper[g] = merged_upper[g] && !(|merged_upper[g-1:0]);
      assign merged_first_any[g]   = merged_eligible_phys[g] && !(|merged_eligible_phys[g-1:0]);
    end
  end
  assign o_merged_scan_onehot = merged_upper_found ? merged_first_upper : merged_first_any;

  // ROB-head priority prevents a younger blocked entry from starving the head.
  logic head_mem_stored_found;
  logic [IdxWidth-1:0] head_mem_stored_idx;
  logic [DEPTH-1:0] head_mem_stored_onehot;
  logic [ReorderBufferTagWidth-1:0] head_mem_stored_rob_tag;
  logic head_mem_update_found;
  logic [IdxWidth-1:0] head_mem_update_idx;
  logic [DEPTH-1:0] head_mem_update_onehot;
  logic [ReorderBufferTagWidth-1:0] head_mem_update_rob_tag;
  logic [IdxWidth-1:0] head_match_idx;
  logic [ReorderBufferTagWidth-1:0] head_match_rob_tag;

  // Live entries have distinct ROB tags, so rob_head_match_q is at most
  // one-hot. Index and tag are OR-encoded from it and are consumed only when
  // the corresponding found bit is true.
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      // A staged load may wait on a store younger than the ROB head. That
      // store cannot commit until the head retires. The head must therefore
      // bypass ring order and replace the staged load, including for MMIO
      // and LR (load queue README, "ROB-head priority"). Only committed,
      // draining stores can block the head. Downstream issue gates preserve
      // MMIO/LR head ordering, and the router drains stores before device
      // reads. AMOs require an empty committed SQ because their LQ write
      // path is invisible to SQ disambiguation.
      head_mem_stored_onehot[i] =
          lq_valid[i] &&
          rob_head_match_q[i] &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!lq_is_amo[i] || i_sq_committed_empty);

      head_mem_update_onehot[i] =
          lq_valid[i] &&
          rob_head_match_q[i] &&
          addr_update_pre_match_q[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!lq_is_amo[i] || i_sq_committed_empty);
    end
  end

  assign head_mem_stored_found = |head_mem_stored_onehot;
  assign head_mem_update_found = |head_mem_update_onehot;

  always_comb begin
    head_match_idx     = '0;
    head_match_rob_tag = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      head_match_idx |= IdxWidth'(i) & {IdxWidth{rob_head_match_q[i]}};
      head_match_rob_tag |=
          lq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth] &
          {ReorderBufferTagWidth{rob_head_match_q[i]}};
    end
  end

  assign head_mem_stored_idx = head_match_idx;
  assign head_mem_stored_rob_tag = head_match_rob_tag;
  assign head_mem_update_idx = head_match_idx;
  assign head_mem_update_rob_tag = head_match_rob_tag;

  assign o_issue_cdb_found = issue_cdb_found;
  assign o_issue_cdb_idx = issue_cdb_idx;
  assign o_stored_scan_found = stored_scan_found;
  assign o_stored_scan_idx = stored_scan_idx;
  assign o_stored_scan_pos = stored_scan_pos;
  assign o_stored_scan_onehot = stored_scan_onehot;
  assign o_stored_scan_rob_tag = stored_scan_rob_tag;
  assign o_update_scan_found = update_scan_found;
  assign o_update_scan_idx = update_scan_idx;
  assign o_update_scan_pos = update_scan_pos;
  assign o_update_scan_onehot = update_scan_onehot;
  assign o_update_scan_rob_tag = update_scan_rob_tag;
  assign o_head_mem_stored_found = head_mem_stored_found;
  assign o_head_mem_stored_idx = head_mem_stored_idx;
  assign o_head_mem_stored_onehot = head_mem_stored_onehot;
  assign o_head_mem_stored_rob_tag = head_mem_stored_rob_tag;
  assign o_head_mem_update_found = head_mem_update_found;
  assign o_head_mem_update_idx = head_mem_update_idx;
  assign o_head_mem_update_onehot = head_mem_update_onehot;
  assign o_head_mem_update_rob_tag = head_mem_update_rob_tag;

endmodule
