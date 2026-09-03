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
// Load-queue issue selection, all of it parallel: the oldest CDB-ready entry,
// memory-issue eligibility with MMIO/LR/AMO head gates and older-AMO blocking,
// and a separate ROB-head priority path. Per-entry masks and tree encoders
// replace a serial scan. issue_cdb_idx drives the LQ data LUTRAM read in
// load_queue.
//
// Combinational, with no state of its own. load_queue owns the registered
// older-AMO block vector, in physical entry order, derived from each live
// entry's exact allocation-time AMO dependencies. This module rotates that
// vector into head-relative scan order. A killed identity can keep a
// conservative block bit through its one invalid cleanup cycle, but lq_valid
// masks it here and the state drains before the slot is reused. Keeping the
// dependency state in load_queue takes the ROB-age subtract/min/compare logic
// out of the issue-selector capture-enable cone. A head AMO enters the
// head-priority scans on i_sq_committed_empty alone, which subsumed the old
// 512-cycle deadlock breaker (since removed).
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

  // issue_cdb_* keep the names load_queue uses for the same signals. The body
  // assigns these local copies; the output assignments at the bottom of the
  // file export them.
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

  // Phase A: tree priority encoder for the oldest CDB-ready entry
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
      // An MMIO entry is eligible here only at the ROB head.  The dedicated
      // head path below admits that same entry with unconditional priority, so
      // this normal-scan admission is redundant at the LQ boundary.  It is kept
      // to preserve the pre-MMIO-order Boolean shape.  The downstream
      // data-memory router enforces drain ordering at its irreversible
      // read-accept boundary.
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

  // Rotate the parent's registered older-AMO block vector, which arrives in
  // physical entry order, into scan order alongside the eligibility masks.
  // The module header covers its exactness and the stale-invalid-row case.
  logic [DEPTH-1:0] blocked_by_amo;
  assign blocked_by_amo = rotate_mask_from_head(blocked_by_amo_phys_q, head_idx);

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
  // queue order is not always identical to ROB age.  To keep the oldest
  // architectural load from starving behind a younger blocked entry, an
  // eligible ROB-head load takes priority over the normal physical-order scan.
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

  // rob_head_match_q is one-hot by construction: live LQ entries carry
  // distinct ROB tags, so the registered compare matches at most one physical
  // entry.  The head-eligibility gates keep that one-hot form rather than
  // serially scanning all entries to recover a found/index tuple.  It is the
  // natural representation of the unique ROB-head load, and it is a timing
  // cut: lq_addr_valid now reaches head_mem_stored_found through a per-entry
  // eligibility LUT plus an OR reduction, and reaches issue_mem_onehot
  // directly.  The old !head_mem_stored_found loop made each physical entry
  // depend on every earlier entry and placed a long priority ripple on every
  // sq_check capture and feedback bit.  Index and tag are parallel OR encoders
  // of rob_head_match_q itself, so the eligibility signals, lq_addr_valid in
  // particular, affect found and onehot but not the selected payload identity,
  // which is consumed only when the corresponding found bit is true.  Selection and
  // cycle latency are unchanged.
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      // The ROB-head load takes head-priority for the single sq_check staging
      // slot in every load class, MMIO and LR included.  The sparse LQ scans in
      // ring order from head_idx (= head_ptr, not the ROB-head entry's physical
      // slot), so without this an eligible ROB-head MMIO/LR load can lose the
      // slot to a ring-earlier younger load.  If that younger load is fenced
      // behind an un-drainable older store (uncommitted, non-forwardable) it
      // camps there forever and starves the head: the call_stress UART
      // poll-load wedge.  Admitting the head is safe and live.  The head is the
      // oldest architectural load (age 0), so only committed, and therefore
      // draining, older stores can fence it, never the younger wrong-path
      // stores that create the hog.  sq_check_replace then evicts the younger
      // staged entry.  Store->load ordering stays correct through the
      // downstream sq_check_entry_issueable / sq_can_issue gates, which let
      // MMIO and LR leave the LQ only at the ROB head (asserted by
      // p_mmio_only_at_head), together with the router's MMIO drain guard on
      // irreversible effects.  A head AMO stays gated on i_sq_committed_empty:
      // its RMW write lives in the LQ, invisible to SQ disambiguation, so it
      // has to see an empty committed queue.  That gating subsumed the old
      // force_head_amo deadlock breaker, since removed.  head_mem_update
      // already admitted MMIO and excluded only LR, so this also removes the
      // stored-vs-update asymmetry: a head MMIO load used to keep priority only
      // on the cycle its address arrived, then lose it once it sat with
      // lq_addr_valid=1.
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
