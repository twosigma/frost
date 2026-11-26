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
// Select CDB-ready and memory-issue entries in ROB-head-relative age order
// (breaking equal-age ties by physical index), with a separate ROB-head
// priority path. issue_cdb_idx selects the LQ data LUTRAM read.
//
// load_queue registers each entry's ROB-head-relative age and older-AMO block
// vector in physical entry order. A freed or flushed entry can retain a stale
// block bit for its first invalid cycle; lq_valid masks it here, and
// load_queue clears it before reuse. A head AMO or LR requires
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
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] i_entry_age_flat,
    input logic i_sq_committed_empty,

    output logic o_issue_cdb_found,
    output logic [$clog2(DEPTH)-1:0] o_issue_cdb_idx,
    output logic [DEPTH-1:0] o_merged_scan_onehot,
    output logic o_stored_scan_found,
    output logic [$clog2(DEPTH)-1:0] o_stored_scan_idx,
    output logic [(riscv_pkg::ReorderBufferTagWidth+$clog2(DEPTH))-1:0] o_stored_scan_pos,
    output logic [DEPTH-1:0] o_stored_scan_onehot,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_stored_scan_rob_tag,
    output logic o_update_scan_found,
    output logic [$clog2(DEPTH)-1:0] o_update_scan_idx,
    output logic [(riscv_pkg::ReorderBufferTagWidth+$clog2(DEPTH))-1:0] o_update_scan_pos,
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
  localparam int unsigned PosWidth = ReorderBufferTagWidth + IdxWidth;

  logic [ReorderBufferTagWidth-1:0] entry_age[DEPTH];
  for (genvar g_age = 0; g_age < DEPTH; g_age++) begin : gen_entry_age
    assign entry_age[g_age] = i_entry_age_flat[g_age*ReorderBufferTagWidth+:ReorderBufferTagWidth];
  end

  logic issue_cdb_found;
  logic [IdxWidth-1:0] issue_cdb_idx;

  // Balanced binary tournament picking the oldest eligible entry (minimum
  // entry_age, breaking equal-age ties by lowest physical index).
  function automatic logic [IdxWidth:0] pick_oldest(input logic [DEPTH-1:0] mask);
    logic [DEPTH-1:0] lvl_valid;
    logic [IdxWidth-1:0] lvl_idx[DEPTH];
    logic [ReorderBufferTagWidth-1:0] lvl_age[DEPTH];
    int unsigned span;
    begin
      for (int unsigned i = 0; i < DEPTH; i++) begin
        lvl_valid[i] = mask[i];
        lvl_idx[i]   = IdxWidth'(i);
        lvl_age[i]   = entry_age[i];
      end
      for (span = DEPTH >> 1; span > 0; span = span >> 1) begin
        for (int unsigned i = 0; i < span; i++) begin
          logic left_v, right_v, pick_right;
          left_v = lvl_valid[2*i];
          right_v = lvl_valid[2*i+1];
          pick_right = right_v && (!left_v || (lvl_age[2*i+1] < lvl_age[2*i]));
          lvl_valid[i] = left_v || right_v;
          lvl_idx[i] = pick_right ? lvl_idx[2*i+1] : lvl_idx[2*i];
          lvl_age[i] = pick_right ? lvl_age[2*i+1] : lvl_age[2*i];
        end
      end
      pick_oldest = {lvl_valid[0], lvl_valid[0] ? lvl_idx[0] : IdxWidth'(0)};
    end
  endfunction

  // Phase A: choose the oldest ready entry (lowest age, tie-broken by index).
  logic [ DEPTH-1:0] cdb_ready_phys;
  logic [IdxWidth:0] cdb_pick;
  assign cdb_ready_phys = lq_valid & lq_data_valid;
  assign cdb_pick = pick_oldest(cdb_ready_phys);
  assign issue_cdb_found = cdb_pick[IdxWidth];
  assign issue_cdb_idx = cdb_pick[IdxWidth-1:0];

`ifndef SYNTHESIS
`ifndef FORMAL
  initial begin
`ifdef FROST_SIM_ASSERTIONS
    if (!((1 << IdxWidth) == DEPTH)) $error("lq_issue_selector: DEPTH must be a power of two");
`else
    assert ((1 << IdxWidth) == DEPTH)
    else $error("lq_issue_selector: DEPTH must be a power of two");
`endif
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
          (!(lq_is_lr[i] || lq_is_amo[i]) || (rob_head_match_q[i] && i_sq_committed_empty));

      mem_eligible_update_phys[i] =
          lq_valid[i] &&
          addr_update_pre_match_q[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!(lq_is_lr[i] || lq_is_amo[i]) || (rob_head_match_q[i] && i_sq_committed_empty));
    end
  end

  logic [DEPTH-1:0] mem_issue_stored_phys;
  logic [DEPTH-1:0] mem_issue_update_phys;
  logic [DEPTH-1:0] merged_eligible_phys;
  assign mem_issue_stored_phys = mem_eligible_stored_phys & ~blocked_by_amo_phys_q;
  assign mem_issue_update_phys = mem_eligible_update_phys & ~blocked_by_amo_phys_q;
  assign merged_eligible_phys  = mem_issue_stored_phys | mem_issue_update_phys;

  // Encode the oldest stored-address, arriving-address, and merged candidates.
  logic [IdxWidth:0] stored_pick, update_pick, merged_pick;
  logic stored_scan_found;
  logic [IdxWidth-1:0] stored_scan_idx;
  logic [PosWidth-1:0] stored_scan_pos;
  logic [DEPTH-1:0] stored_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] stored_scan_rob_tag;

  logic update_scan_found;
  logic [IdxWidth-1:0] update_scan_idx;
  logic [PosWidth-1:0] update_scan_pos;
  logic [DEPTH-1:0] update_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] update_scan_rob_tag;

  logic merged_scan_found;
  logic [IdxWidth-1:0] merged_scan_idx;
  logic [DEPTH-1:0] merged_scan_onehot;

  always_comb begin
    stored_pick = pick_oldest(mem_issue_stored_phys);
    update_pick = pick_oldest(mem_issue_update_phys);
    merged_pick = pick_oldest(merged_eligible_phys);

    stored_scan_found = stored_pick[IdxWidth];
    stored_scan_idx = stored_pick[IdxWidth-1:0];
    stored_scan_pos = stored_scan_found ? {entry_age[stored_scan_idx], stored_scan_idx} : '0;
    stored_scan_onehot = stored_scan_found ? (DEPTH'(1) << stored_scan_idx) : '0;
    stored_scan_rob_tag = stored_scan_found ?
        lq_rob_tag_flat[stored_scan_idx*ReorderBufferTagWidth+:ReorderBufferTagWidth] : '0;

    update_scan_found = update_pick[IdxWidth];
    update_scan_idx = update_pick[IdxWidth-1:0];
    update_scan_pos = update_scan_found ? {entry_age[update_scan_idx], update_scan_idx} : '0;
    update_scan_onehot = update_scan_found ? (DEPTH'(1) << update_scan_idx) : '0;
    update_scan_rob_tag = update_scan_found ?
        lq_rob_tag_flat[update_scan_idx*ReorderBufferTagWidth+:ReorderBufferTagWidth] : '0;

    merged_scan_found = merged_pick[IdxWidth];
    merged_scan_idx = merged_pick[IdxWidth-1:0];
    merged_scan_onehot = merged_scan_found ? (DEPTH'(1) << merged_scan_idx) : '0;
  end

  assign o_merged_scan_onehot = merged_scan_onehot;

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
      // take priority and replace the staged load, including for MMIO and LR
      // (load queue README, "Age-ordered replacement and ROB-head priority").
      // Only committed,
      // draining stores can block the head. Downstream issue gates preserve
      // MMIO/LR head ordering, and the router drains stores before device
      // reads. AMOs require an empty committed SQ because their LQ write
      // path is invisible to SQ disambiguation. LRs require it so that no
      // store older than the LR writes after the LR sets its reservation
      // (load queue README, "LR and SC"). The per-entry block applies here
      // too: no older AMO is pending at the head, but a retired vector memory
      // instruction can still be accessing memory.
      head_mem_stored_onehot[i] =
          lq_valid[i] &&
          rob_head_match_q[i] &&
          !blocked_by_amo_phys_q[i] &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!(lq_is_lr[i] || lq_is_amo[i]) || i_sq_committed_empty);

      head_mem_update_onehot[i] =
          lq_valid[i] &&
          rob_head_match_q[i] &&
          !blocked_by_amo_phys_q[i] &&
          addr_update_pre_match_q[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!(lq_is_lr[i] || lq_is_amo[i]) || i_sq_committed_empty);
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
