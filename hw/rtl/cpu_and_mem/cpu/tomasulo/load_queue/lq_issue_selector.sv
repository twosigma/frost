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
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
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

  // Head AMOs are admitted to the head-priority scans on i_sq_committed_empty
  // alone; the deadlock-breaker override is subsumed but the port is kept so
  // the breaker plumbing in load_queue stays intact as a backstop.
  logic unused_force_head_amo;
  assign unused_force_head_amo = i_force_head_amo;

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

  // AMO blocking: a pending (unresolved) older AMO must block younger memory
  // ops until its write phase completes and the slot becomes data-valid.
  // "Older" is decided by ROB-tag age relative to the ROB head, NOT by ring
  // position: the sparse queue reuses reclaimed holes after flushes, so
  // physical position is not allocation order and a position-based prefix-OR
  // can let a younger load slip past a pending AMO (it then reads the
  // pre-AMO memory value).  Tag age over the live ROB window is exact.
  logic [DEPTH-1:0] pending_amo_phys;
  logic [riscv_pkg::ReorderBufferTagWidth:0] entry_head_age[DEPTH];
  logic [riscv_pkg::ReorderBufferTagWidth:0] oldest_pending_amo_age;
  // TIMING (x3 WNS cone): compute the oldest-pending-AMO age as a balanced
  // pairwise-min TREE (log2(DEPTH) = 3 deep for DEPTH=8) instead of the serial
  // min the for-loop synthesized into (~DEPTH compare-select stages).  This min
  // reduction sits on the head_ptr -> issue-select -> sq_check_capture path that
  // is the post-opt x3 WNS limiter (-5.581ns; the AMO-age ripple is a dominant
  // contributor).  A min is order-independent, so the tree is BIT-IDENTICAL to
  // the ripple.  Heap layout: leaves at [DEPTH-1 .. 2*DEPTH-2], internal nodes
  // [0 .. DEPTH-2], root = [0].
  localparam int unsigned AmoAgeW = ReorderBufferTagWidth + 1;
  logic [AmoAgeW-1:0] amo_age_tree[2*DEPTH-1];
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      entry_head_age[i] = {1'b0, lq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth]} -
          {1'b0, i_rob_head_tag};
      pending_amo_phys[i] = lq_valid[i] && lq_is_amo[i] && !lq_data_valid[i];
      // Masked leaf: a non-pending-AMO entry contributes the max age ('1) so it
      // never wins the min (matches the old "no pending AMO -> '1" default).
      amo_age_tree[DEPTH-1+i] = pending_amo_phys[i] ? entry_head_age[i] : '1;
    end
    for (int i = int'(DEPTH) - 2; i >= 0; i--) begin
      amo_age_tree[i] = (amo_age_tree[2*i+1] <= amo_age_tree[2*i+2]) ?
                        amo_age_tree[2*i+1] : amo_age_tree[2*i+2];
    end
    oldest_pending_amo_age = amo_age_tree[0];
  end

  // Physical-index mask (matches lq_valid indexing), then rotate into scan
  // order alongside the eligibility masks.
  logic [DEPTH-1:0] blocked_by_amo_phys;
  logic [DEPTH-1:0] blocked_by_amo;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      blocked_by_amo_phys[i] = lq_valid[i] && (entry_head_age[i] > oldest_pending_amo_age);
    end
  end
  assign blocked_by_amo = rotate_mask_from_head(blocked_by_amo_phys, head_idx);

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
      // The ROB-head load gets head-priority for the single sq_check staging
      // slot for EVERY load class, INCLUDING MMIO and LR.  The sparse LQ scans
      // in ring order from head_idx (= head_ptr, not the ROB-head entry's
      // physical slot), so without this an eligible ROB-head MMIO/LR load can
      // lose the slot to a ring-earlier younger load; if that younger load is
      // fenced behind an un-drainable (uncommitted, non-forwardable) older
      // store it camps there forever and starves the head (the call_stress
      // UART poll-load wedge).  Admitting the head is always safe and live:
      // the head is the oldest architectural load (age 0), so it can only be
      // fenced by COMMITTED — hence draining — older stores, never by the
      // younger wrong-path stores that create the hog.  sq_check_replace then
      // evicts the younger staged entry, and the downstream
      // sq_check_entry_issueable / sq_can_issue gates (MMIO & LR issue only at
      // the ROB head, asserted by p_mmio_only_at_head) keep store->load
      // ordering correct.  A head AMO stays gated on i_sq_committed_empty (its
      // RMW write lives in the LQ, invisible to SQ disambiguation, so it must
      // see an empty committed queue); i_force_head_amo remains the AMO
      // deadlock-breaker backstop.  head_mem_update already admitted MMIO — it
      // only excluded LR — so this also removes that stored-vs-update
      // asymmetry (a head MMIO load kept priority only on the exact cycle its
      // address arrived, then lost it once it sat with lq_addr_valid=1).
      if (!head_mem_stored_found &&
          lq_valid[i] &&
          rob_head_match_q[i] &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          (!lq_is_amo[i] || i_sq_committed_empty)) begin
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
          (!lq_is_amo[i] || i_sq_committed_empty)) begin
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
