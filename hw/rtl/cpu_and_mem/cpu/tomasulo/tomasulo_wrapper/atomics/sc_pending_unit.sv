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
// Store-conditional (SC.W/SC.D) resolution.
//
// MEM_RS can issue SCs out of program order: a branch-speculated LR/SC retry
// loop issues one SC per speculated iteration before the oldest resolves. Each
// issued SC therefore waits in a small table keyed by its ROB tag, so the SC
// at the ROB head can always fire and a younger SC never blocks it.
//
// Rules:
//   * An SC fires when head_tag matches a valid entry whose physical address
//     is known and the SQ is committed-empty, unless the MEM adapter slot is
//     busy or the coherence port holds SC fires (sc_fire_now).
//   * A partial flush clears only entries younger than the flush tag
//     (is_younger); a full flush clears the table.
//   * The table must not be smaller than the SQ (see ScTableDepth).
//
// The store-fault path, the MEM-adapter input mux, and lq_result_accepted
// live in the wrapper.
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
    // The wrapper's registered SC completion is still waiting for the MEM
    // adapter (a registered store fault took the slot first); no fire while
    // it waits.
    input logic i_sc_completion_pending,
    // The registered store-fault strobe (misalign, PMA, or the MMU's page/
    // access fault), one cycle after the fault decision.  It carries the
    // faulting op's tag, blocks the fire in its cycle, and kills a faulting
    // SC's entry. This unit never sees the live fault decision.
    input riscv_pkg::fu_complete_t i_store_misalign_fu_complete_reg,
    input riscv_pkg::rs_issue_t i_mem_rs_issue,
    input logic [riscv_pkg::XLEN-1:0] i_sq_effective_addr,
    // The reservation compare is in the PA domain, so under active data
    // translation the issue-time capture (a VA) is a placeholder. The entry's
    // address becomes usable only when the MMU's PA fill arrives, matched by
    // tag, and the fire waits for that. When translation is inactive the
    // alloc-time capture is already the PA.
    input logic i_sct_alloc_addr_valid,
    input logic i_sct_addr_fill_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sct_addr_fill_tag,
    input logic [riscv_pkg::XLEN-1:0] i_sct_addr_fill_addr,
    input logic i_speculative_flush_all,
    input logic i_speculative_flush_en,
    // DMA coherence: hold SC fires while the head SC's line is
    // admitted to a DMA write; expose the head SC's address for admission
    // and the successful fire that opens the SC window.
    input logic i_coh_sc_hold,
    // Compare each pending address before selecting the head entry, avoiding
    // a wide address mux followed by the coherence port's line comparison.
    input logic [riscv_pkg::XLEN-1:0] i_coh_query_addr,
    output logic o_sc_head_query_match,
    output logic o_sc_head_addr_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sc_head_addr,
    output logic o_sc_fire_success,

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
  logic sc_completion_pending;
  riscv_pkg::fu_complete_t store_misalign_fu_complete_reg;
  riscv_pkg::rs_issue_t o_mem_rs_issue;
  logic [riscv_pkg::XLEN-1:0] sq_effective_addr;
  logic speculative_flush_all;
  logic speculative_flush_en;
  assign head_tag = i_head_tag;
  assign sq_committed_empty = i_sq_committed_empty;
  assign lq_reservation_valid = i_lq_reservation_valid;
  assign lq_reservation_addr = i_lq_reservation_addr;
  assign mem_adapter_result_pending = i_mem_adapter_result_pending;
  assign lq_fu_complete = i_lq_fu_complete;
  assign sc_completion_pending = i_sc_completion_pending;
  assign store_misalign_fu_complete_reg = i_store_misalign_fu_complete_reg;
  assign o_mem_rs_issue = i_mem_rs_issue;
  assign sq_effective_addr = i_sq_effective_addr;
  assign speculative_flush_all = i_speculative_flush_all;
  assign speculative_flush_en = i_speculative_flush_en;

  // SC tracking table: one entry per in-flight SC, keyed by ROB tag. A waiting
  // SC also holds its SQ entry, which it keeps until it commits after firing,
  // and every flush that clears SQ entries clears the matching table entries
  // on the same edge. So at most SqDepth SCs wait at once, counting the one
  // issuing, and a table of SqDepth entries always has a free entry for it
  // (checked in simulation below). An SC that found no free entry would be
  // dropped at allocation and never fire.
  localparam int unsigned ScTableDepth = riscv_pkg::SqDepth;
  logic [ScTableDepth-1:0] sct_valid;
  logic [ScTableDepth-1:0] sct_addr_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sct_tag[ScTableDepth];
  logic [riscv_pkg::XLEN-1:0] sct_addr[ScTableDepth];

  // Age comparison for the SC flush guard (identical to the load_queue and
  // reservation_station copies).
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
  logic                       sct_hit_addr_valid;
  logic [riscv_pkg::XLEN-1:0] sct_hit_addr;
  logic [   ScTableDepth-1:0] sct_hit_oh;
  always_comb begin
    sct_hit               = 1'b0;
    sct_hit_addr_valid    = 1'b0;
    sct_hit_addr          = '0;
    sct_hit_oh            = '0;
    o_sc_head_query_match = 1'b0;
    for (int i = 0; i < ScTableDepth; i++) begin
      if (sct_valid[i] && (sct_tag[i] == head_tag)) begin
        sct_hit = 1'b1;
        sct_hit_addr_valid = sct_addr_valid[i];
        sct_hit_addr = sct_addr[i];
        sct_hit_oh[i] = 1'b1;
        // Same highest-index priority as sct_hit_addr, including an
        // address-invalid winning entry. Coherence compares whole lines, not
        // the LR/SC doubleword granule, so the split is
        // riscv_pkg::DmaCoherenceLineLsb, the same constant lq_coherence_port
        // and the load queue compare on.
        o_sc_head_query_match = sct_addr_valid[i] &&
            (sct_addr[i][riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb] ==
             i_coh_query_addr[riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb]);
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
  // Capture an issuing SC unless a flush kills it this cycle: a full flush
  // rejects every SC, a partial flush only SCs younger than the flush tag. An
  // older SC that issues during a partial flush survives it and must be
  // captured.
  logic sct_alloc;
  assign sct_alloc = o_mem_rs_issue.valid && !speculative_flush_all &&
      ((o_mem_rs_issue.op == riscv_pkg::SC_W) ||
       (o_mem_rs_issue.op == riscv_pkg::SC_D)) &&
      // An SC that faults in its own issue cycle is still captured; the
      // registered fault strobe kills its entry one cycle later and blocks
      // every fire in between, so the entry never fires (the SC completes
      // through the fault path).
      // Consulting the live fault decision here would put the store address,
      // misalignment and PMA cone on the allocation path.
      !(speculative_flush_en && is_younger(
          o_mem_rs_issue.rob_tag, i_flush_tag, head_tag
      ));

  // Payload capture ignores the flush vetoes in sct_alloc. Those vetoes
  // govern sct_valid, the only visibility gate for the tag, address, and
  // address-valid payloads, so a rejected SC can refresh a free entry's dead
  // payload without becoming observable, and the flush age compare stays off
  // the payload enables.
  logic sct_payload_alloc;
  assign sct_payload_alloc = o_mem_rs_issue.valid &&
      ((o_mem_rs_issue.op == riscv_pkg::SC_W) ||
       (o_mem_rs_issue.op == riscv_pkg::SC_D));

  logic sc_can_fire;
  logic sc_success;
  logic sc_fire_now;

  // The fire also waits for the entry's PA (i_sct_addr_fill_* under active
  // translation). Firing at the issue cycle would compare the VA against the
  // PA-domain reservation, and it would beat the MMU's fault delivery for an
  // SC whose translation is refused.
  assign sc_can_fire = sct_hit && sct_hit_addr_valid && sq_committed_empty;
  assign sc_success = lq_reservation_valid
      // The SC matches a reservation anywhere in the reserved doubleword
      // (FROST's reservation granule).
      && (lq_reservation_addr[riscv_pkg::XLEN-1:3] == sct_hit_addr[riscv_pkg::XLEN-1:3]);
  // Fire only when the coherence port is not holding SCs and the MEM adapter
  // has no competing producer: no result pending, no live LQ result, no
  // registered store fault presenting, and no earlier SC completion still
  // waiting in the wrapper.  A store that faults in the fire cycle is not
  // consulted here: its registered fault takes the MEM slot first next cycle
  // and the wrapper holds the SC completion until the slot is free.
  // Consulting the live decision would put the store address, misalignment
  // and PMA cone on this unit's write path.
  assign sc_fire_now = sc_can_fire && !i_coh_sc_hold &&
                       !mem_adapter_result_pending &&
                       !lq_fu_complete.valid &&
                       !sc_completion_pending &&
                       !store_misalign_fu_complete_reg.valid;

  // SC fu_complete generation: the firing SC matched head_tag, so that is its tag.
  riscv_pkg::fu_complete_t sc_fu_complete;
  always_comb begin
    sc_fu_complete       = '0;
    sc_fu_complete.valid = sc_fire_now;
    sc_fu_complete.tag   = head_tag;
    sc_fu_complete.value = {{(riscv_pkg::FLEN - 1) {1'b0}}, ~sc_success};
  end
  assign o_sc_head_addr_valid = sct_hit && sct_hit_addr_valid;
  assign o_sc_head_addr = sct_hit_addr;

`ifdef FORMAL
`ifdef SC_HEAD_QUERY_LOCAL_PROOF
  always_comb begin
    assert (o_sc_head_query_match ==
            (o_sc_head_addr_valid &&
             (o_sc_head_addr[riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb] ==
              i_coh_query_addr[riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb])));
  end
`endif
`endif
  assign o_sc_fire_success = sc_fire_now && sc_success;

  // Table valid bits: allocate on SC issue, free on fire, flush younger entries.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      sct_valid <= '0;
    end else begin
      // Clear only the entries younger than the flush boundary (i_flush_tag),
      // the ones this flush is killing. Clearing every entry on a partial
      // flush would drop an SC older than the mispredicted branch that is
      // still waiting for the head.
      if (i_flush_en) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && is_younger(sct_tag[i], i_flush_tag, head_tag)) begin
            sct_valid[i] <= 1'b0;
          end
        end
      end
      // Kill the entry of an SC that faulted, at the registered store-fault
      // strobe. It completes through the fault path, never by firing: the
      // registered strobe blocks every fire in its own cycle (above) and the
      // entry is gone on the next edge, so no address-valid faulting SC can
      // fire in the one extra cycle it stays resident.
      if (store_misalign_fu_complete_reg.valid) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && (sct_tag[i] == store_misalign_fu_complete_reg.tag)) begin
            sct_valid[i] <= 1'b0;
          end
        end
      end
      // Free the firing entry.
      if (sc_fire_now) begin
        for (int i = 0; i < ScTableDepth; i++) if (sct_hit_oh[i]) sct_valid[i] <= 1'b0;
      end
      // Allocate a newly-issued SC into the first free slot (ScTableDepth
      // explains why one is always free). Alloc targets a free slot and the
      // fire/fault/flush clears target valid slots, so the indices never
      // collide.
      if (sct_alloc && sct_has_free) begin
        for (int i = 0; i < ScTableDepth; i++) if (sct_free_oh[i]) sct_valid[i] <= 1'b1;
      end
    end
  end

  // Address-valid bits: set at alloc when the capture is already the PA
  // (translation inactive), else by the MMU's tag-matched fill.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sct_addr_valid <= '0;
    end else begin
      if (sct_payload_alloc && sct_has_free) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_free_oh[i]) sct_addr_valid[i] <= i_sct_alloc_addr_valid;
        end
      end
      if (i_sct_addr_fill_valid) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && (sct_tag[i] == i_sct_addr_fill_tag)) sct_addr_valid[i] <= 1'b1;
        end
      end
    end
  end

  // SC tag/addr capture (no reset; gated by the alloc one-hot), plus the
  // MMU's later PA fill under active translation.
  always_ff @(posedge i_clk) begin
    if (i_sct_addr_fill_valid) begin
      for (int i = 0; i < ScTableDepth; i++) begin
        if (sct_valid[i] && (sct_tag[i] == i_sct_addr_fill_tag)) begin
          sct_addr[i] <= i_sct_addr_fill_addr;
        end
      end
    end
    if (sct_payload_alloc && sct_has_free) begin
      for (int i = 0; i < ScTableDepth; i++) begin
        if (sct_free_oh[i]) begin
          sct_tag[i]  <= o_mem_rs_issue.rob_tag;
          // SC has no immediate operand: dispatch guarantees imm==0.  Use
          // src1 directly so the AGU is absent from the wide address D cone.
          sct_addr[i] <= o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0];
        end
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (i_rst_n && sct_alloc && !sct_has_free)
      $error(
          "sc_pending_unit: SC tag %0d issued with the table full; it would never fire",
          o_mem_rs_issue.rob_tag
      );
  end

  always_ff @(posedge i_clk) begin
    if (i_rst_n && sct_payload_alloc && !$isunknown(
            {o_mem_rs_issue.imm, o_mem_rs_issue.src1_value, sq_effective_addr}
        )) begin
      p_sc_effective_addr_is_src1 :
      assert (
        o_mem_rs_issue.imm == '0 &&
        o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] == sq_effective_addr
      );
    end
  end
`endif
`endif

  assign o_sc_pending     = |sct_valid;
  assign o_sc_fu_complete = sc_fu_complete;

endmodule
