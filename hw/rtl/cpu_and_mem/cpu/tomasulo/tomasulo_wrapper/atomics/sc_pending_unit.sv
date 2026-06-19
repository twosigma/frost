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
// sc_pending_unit
// =============================================================================
// Store-conditional (SC.W) resolution.
//
// In-flight SCs are tracked in a small table keyed by ROB tag, so the SC that
// reaches the ROB head can ALWAYS fire -- even when an LR/SC retry loop is
// branch-speculated and the core issues several SCs (one per speculated
// iteration) before the oldest resolves. A single pending-SC register failed
// here: a younger speculative SC overwrote the head SC's rob_tag, so the head
// SC's tag never matched, it never fired, the branch never resolved, and the
// core deadlocked. Observed on Linux printk's _prb_commit cmpxchg loop (11 SCs
// issued, 8-deep speculation; head=tag15 but the register held tag19). BRAM
// LR/SC resolves before a second SC issues, so BRAM/FreeRTOS were unaffected;
// the longer cached-tier (DDR) latency exposes the overlap.
//
// Two flush rules matter and were both bugs in the single-register version:
//   * an SC fires when head_tag matches a VALID entry and the SQ is drained;
//   * an entry is cleared on a flush ONLY if it is younger than the flush
//     boundary (is_younger) -- NOT unconditionally on partial flush, which
//     would drop a surviving older SC.
// Depth = NumCheckpoints + 1 (branch speculation depth bounds concurrent SCs).
//
// The store-misalign exception path, MEM-adapter input mux, and
// lq_result_accepted remain in the wrapper. is_younger is duplicated here
// (identical to the load_queue / RS copies).
// =============================================================================
module sc_pending_unit (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,

    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic i_sq_committed_empty,
    input logic i_lq_reservation_valid,
    input logic [riscv_pkg::XLEN-1:0] i_lq_reservation_addr,
    input logic i_mem_adapter_result_pending,
    input riscv_pkg::fu_complete_t i_lq_fu_complete,
    input logic i_store_misalign_issue,
    input riscv_pkg::fu_complete_t i_store_misalign_fu_complete_reg,
    input riscv_pkg::rs_issue_t i_mem_rs_issue,
    input logic [riscv_pkg::XLEN-1:0] i_sq_effective_addr,
    input logic i_speculative_flush_all,
    input logic i_speculative_flush_en,
    input logic i_speculative_partial_flush,

    output logic o_sc_pending,
    output riscv_pkg::fu_complete_t o_sc_fu_complete
);

  // ---------------------------------------------------------------------------
  // Alias input ports back to the wrapper's local names.
  // ---------------------------------------------------------------------------
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic sq_committed_empty;
  logic lq_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] lq_reservation_addr;
  logic mem_adapter_result_pending;
  riscv_pkg::fu_complete_t lq_fu_complete;
  logic store_misalign_issue;
  riscv_pkg::fu_complete_t store_misalign_fu_complete_reg;
  riscv_pkg::rs_issue_t o_mem_rs_issue;
  logic [riscv_pkg::XLEN-1:0] sq_effective_addr;
  logic speculative_flush_all;
  logic speculative_flush_en;
  logic speculative_partial_flush;
  assign head_tag = i_head_tag;
  assign sq_committed_empty = i_sq_committed_empty;
  assign lq_reservation_valid = i_lq_reservation_valid;
  assign lq_reservation_addr = i_lq_reservation_addr;
  assign mem_adapter_result_pending = i_mem_adapter_result_pending;
  assign lq_fu_complete = i_lq_fu_complete;
  assign store_misalign_issue = i_store_misalign_issue;
  assign store_misalign_fu_complete_reg = i_store_misalign_fu_complete_reg;
  assign o_mem_rs_issue = i_mem_rs_issue;
  assign sq_effective_addr = i_sq_effective_addr;
  assign speculative_flush_all = i_speculative_flush_all;
  assign speculative_flush_en = i_speculative_flush_en;
  assign speculative_partial_flush = i_speculative_partial_flush;

  // SC tracking table: one entry per in-flight SC, keyed by ROB tag.
  localparam int unsigned ScTableDepth = riscv_pkg::NumCheckpoints + 1;
  logic [ScTableDepth-1:0] sct_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sct_tag[ScTableDepth];
  logic [riscv_pkg::XLEN-1:0] sct_addr[ScTableDepth];

  // Age comparison for the SC flush guard (identical to load_queue / RS).
  function automatic logic is_younger(input logic [riscv_pkg::ReorderBufferTagWidth-1:0] entry_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] head);
    logic [riscv_pkg::ReorderBufferTagWidth:0] entry_age;
    logic [riscv_pkg::ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // Head match: an in-flight SC sits at the ROB head.
  logic                       sct_hit;
  logic [riscv_pkg::XLEN-1:0] sct_hit_addr;
  logic [   ScTableDepth-1:0] sct_hit_oh;
  always_comb begin
    sct_hit      = 1'b0;
    sct_hit_addr = '0;
    sct_hit_oh   = '0;
    for (int i = 0; i < ScTableDepth; i++) begin
      if (sct_valid[i] && (sct_tag[i] == head_tag)) begin
        sct_hit       = 1'b1;
        sct_hit_addr  = sct_addr[i];
        sct_hit_oh[i] = 1'b1;
      end
    end
  end

  // First free slot for a newly-issued SC.
  logic                    sct_has_free;
  logic [ScTableDepth-1:0] sct_free_oh;
  always_comb begin
    sct_has_free = 1'b0;
    sct_free_oh  = '0;
    for (int i = 0; i < ScTableDepth; i++) begin
      if (!sct_valid[i] && !sct_has_free) begin
        sct_has_free   = 1'b1;
        sct_free_oh[i] = 1'b1;
      end
    end
  end
  // Capture an issuing SC. Reject a phantom SC only when it is younger than the
  // flush boundary (it is being killed); a real SC that survives the flush must
  // be captured even if its issue coincides with the flush window.
  logic sct_alloc;
  assign sct_alloc = o_mem_rs_issue.valid && !speculative_flush_all &&
      (o_mem_rs_issue.op == riscv_pkg::SC_W) &&
      !(speculative_flush_en && is_younger(
      o_mem_rs_issue.rob_tag, i_flush_tag, head_tag
  ));

  logic sc_can_fire;
  logic sc_success;
  logic sc_fire_now;

  assign sc_can_fire = sct_hit && sq_committed_empty;
  assign sc_success = lq_reservation_valid
      && (lq_reservation_addr[riscv_pkg::XLEN-1:2] == sct_hit_addr[riscv_pkg::XLEN-1:2]);
  // Arm SC only when the MEM adapter has no competing same-cycle producer; the
  // registered completion below owns the MEM adapter on the next cycle.
  assign sc_fire_now = sc_can_fire &&
                       !mem_adapter_result_pending &&
                       !lq_fu_complete.valid &&
                       !store_misalign_issue &&
                       !store_misalign_fu_complete_reg.valid;

  // SC fu_complete generation. The firing SC's tag IS head_tag (it matched).
  riscv_pkg::fu_complete_t sc_fu_complete;
  always_comb begin
    sc_fu_complete       = '0;
    sc_fu_complete.valid = sc_fire_now;
    sc_fu_complete.tag   = head_tag;
    sc_fu_complete.value = {{(riscv_pkg::FLEN - 1) {1'b0}}, ~sc_success};
  end

  // Table valid bits: allocate on SC issue, free on fire, flush younger entries.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      sct_valid <= '0;
    end else begin
      // Clear ONLY entries younger than the flush boundary (i_flush_tag) -- i.e.
      // actually being flushed. Do NOT clear on speculative_partial_flush alone:
      // an SC older than the mispredicted branch (e.g. one still waiting for the
      // head to reach it on the slow cached tier) must survive.
      if (i_flush_en) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && is_younger(sct_tag[i], i_flush_tag, head_tag)) begin
            sct_valid[i] <= 1'b0;
          end
        end
      end
      // Free the firing entry.
      if (sc_fire_now) begin
        for (int i = 0; i < ScTableDepth; i++) if (sct_hit_oh[i]) sct_valid[i] <= 1'b0;
      end
      // Allocate a newly-issued SC into the first free slot. (Alloc targets a
      // free slot; fire/flush clear valid slots, so the indices never collide.)
      if (sct_alloc && sct_has_free) begin
        for (int i = 0; i < ScTableDepth; i++) if (sct_free_oh[i]) sct_valid[i] <= 1'b1;
      end
    end
  end

  // SC tag/addr capture (no reset; gated by the alloc one-hot).
  always_ff @(posedge i_clk) begin
    if (sct_alloc && sct_has_free) begin
      for (int i = 0; i < ScTableDepth; i++) begin
        if (sct_free_oh[i]) begin
          sct_tag[i]  <= o_mem_rs_issue.rob_tag;
          sct_addr[i] <= sq_effective_addr;
        end
      end
    end
  end

  assign o_sc_pending     = |sct_valid;
  assign o_sc_fu_complete = sc_fu_complete;

endmodule
