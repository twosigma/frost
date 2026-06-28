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
// Extracted verbatim from load_queue.sv (pure RTL boundary move, zero functional
// change, except for the optional registered deadlock break input).  Parallel
// issue selection: Phase A (oldest CDB-ready entry), Phase B
// (memory-issue eligibility masks with MMIO/LR/AMO head gating + older-AMO
// blocking), and the explicit ROB-head priority result.  Replaces the old serial
// 16-level scan with per-entry masks + tree encoders.  issue_cdb_idx is exported
// to drive the LQ data LUTRAM read; the RAM stays in load_queue.  Entry-array and
// control inputs keep the parent's names so the bodies are byte-identical;
// rotate_mask_from_head is duplicated (pure combinational).
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
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] lq_rob_tag_flat,
    input logic [$clog2(DEPTH)-1:0] head_idx,
    input logic i_sq_committed_empty,
    input logic i_force_head_amo,

    output logic o_issue_cdb_found,
    output logic [$clog2(DEPTH)-1:0] o_issue_cdb_idx,
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
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_mem_stored_rob_tag,
    output logic o_head_mem_update_found,
    output logic [$clog2(DEPTH)-1:0] o_head_mem_update_idx,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_mem_update_rob_tag
);

  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  // issue_cdb_* are declared in the parent before this block; the body assigns
  // them, so declare them locally here and export.
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

  // Phase A: per-entry CDB readiness (parallel, no inter-entry dependency)
  logic [DEPTH-1:0] cdb_ready_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      cdb_ready_mask[i] = lq_valid[scan_idx[i]] && lq_data_valid[scan_idx[i]];
    end
  end

  // Phase A: tree priority encoder — find oldest CDB-ready entry
  always_comb begin
    issue_cdb_found = 1'b0;
    issue_cdb_idx   = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (cdb_ready_mask[i] && !issue_cdb_found) begin
        issue_cdb_found = 1'b1;
        issue_cdb_idx   = scan_idx[i];
      end
    end
  end

  // Mask of the entry already claimed by the sq_check staging register.  Keep
  // this as registered one-hot state instead of deriving it from sq_check_idx
  // with a live equality compare.  The derived compare put sq_check_idx on the
  // issue-selection -> sq_check_payload_en control path, which is exactly the
  // post-synth WNS limiter on x3.
  logic [DEPTH-1:0] in_flight_mask;
  assign in_flight_mask = sq_check_in_flight_mask;

  // Phase B: per-entry memory issue eligibility (parallel).
  // Split stored-address entries from the single entry whose address arrives
  // this cycle.  The late i_addr_update.valid then only selects between two
  // pre-encoded candidates instead of driving the full scan and address RAM
  // read cone.
  logic [DEPTH-1:0] mem_eligible_stored_phys;
  logic [DEPTH-1:0] mem_eligible_update_phys;
  logic [DEPTH-1:0] mem_eligible_stored_mask;
  logic [DEPTH-1:0] mem_eligible_update_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
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

  // AMO blocking: identify scan positions with pending (unresolved) AMOs.
  // A pending older AMO must block younger memory ops until its write
  // phase completes and the slot becomes data-valid.
  logic [DEPTH-1:0] pending_amo_phys;
  logic [DEPTH-1:0] pending_amo_at;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      pending_amo_phys[i] = lq_valid[i] && lq_is_amo[i] && !lq_data_valid[i];
    end
  end
  assign pending_amo_at = rotate_mask_from_head(pending_amo_phys, head_idx);

  // Prefix-OR: compute "has older pending AMO" for each scan position
  logic [DEPTH-1:0] blocked_by_amo;
  /* verilator lint_off ALWCOMBORDER */
  always_comb begin
    blocked_by_amo[0] = 1'b0;
    for (int unsigned i = 1; i < DEPTH; i++) begin
      blocked_by_amo[i] = blocked_by_amo[i-1] | pending_amo_at[i-1];
    end
  end
  /* verilator lint_on ALWCOMBORDER */

  // Final Phase B masks: eligible AND not blocked by older AMO.
  logic [DEPTH-1:0] mem_issue_stored_mask;
  logic [DEPTH-1:0] mem_issue_update_mask;
  assign mem_issue_stored_mask = mem_eligible_stored_mask & ~blocked_by_amo;
  assign mem_issue_update_mask = mem_eligible_update_mask & ~blocked_by_amo;

  // Encode the oldest normal stored-address and current-update candidates here
  // while scan_idx is already local. Exporting encoded candidates avoids
  // re-scanning the masks in load_queue on the SQ-check payload enable path.
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

  // The sparse queue can reuse reclaimed holes after flushes, so physical
  // queue order is not always identical to ROB age.  To avoid starving the
  // oldest architectural load behind a younger blocked entry, explicitly
  // prioritize an eligible ROB-head load over the normal physical-order scan.
  logic head_mem_stored_found;
  logic [IdxWidth-1:0] head_mem_stored_idx;
  logic [ReorderBufferTagWidth-1:0] head_mem_stored_rob_tag;
  logic head_mem_update_found;
  logic [IdxWidth-1:0] head_mem_update_idx;
  logic [ReorderBufferTagWidth-1:0] head_mem_update_rob_tag;
  always_comb begin
    head_mem_stored_found   = 1'b0;
    head_mem_stored_idx     = '0;
    head_mem_stored_rob_tag = '0;
    head_mem_update_found   = 1'b0;
    head_mem_update_idx     = '0;
    head_mem_update_rob_tag = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (!head_mem_stored_found &&
          lq_valid[i] &&
          rob_head_match_q[i] &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          !lq_is_mmio[i] &&
          !lq_is_lr[i] &&
          (!lq_is_amo[i] || (i_force_head_amo && i_sq_committed_empty))) begin
        head_mem_stored_found   = 1'b1;
        head_mem_stored_idx     = IdxWidth'(i);
        head_mem_stored_rob_tag = lq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      end

      if (!head_mem_update_found &&
          lq_valid[i] &&
          rob_head_match_q[i] &&
          addr_update_pre_match_q[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          !lq_is_lr[i] &&
          (!lq_is_amo[i] || (i_force_head_amo && i_sq_committed_empty))) begin
        head_mem_update_found   = 1'b1;
        head_mem_update_idx     = IdxWidth'(i);
        head_mem_update_rob_tag = lq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      end
    end
  end

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
  assign o_head_mem_stored_rob_tag = head_mem_stored_rob_tag;
  assign o_head_mem_update_found = head_mem_update_found;
  assign o_head_mem_update_idx = head_mem_update_idx;
  assign o_head_mem_update_rob_tag = head_mem_update_rob_tag;

endmodule
