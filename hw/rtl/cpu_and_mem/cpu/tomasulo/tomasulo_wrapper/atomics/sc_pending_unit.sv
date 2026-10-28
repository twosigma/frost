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
//   * SC selection requires a matching ROB head, a physical address, an
//     empty committed SQ and available completion resources.
//   * A selected coherent SC completes independently of SQ drain status.
//     Its held context survives flushes through result consumption.
//   * A partial flush clears only entries younger than the flush tag
//     (is_younger); a full flush clears the table.
//   * The table must not be smaller than the SQ (see ScTableDepth).
//
// The store-fault path, the MEM-adapter input mux, and lq_result_accepted
// live in the wrapper.
// =============================================================================
module sc_pending_unit #(
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes
) (
    input logic i_atomic_protected = 1'b0,
    input logic [2:0] i_reservation_size = '0,
    output logic o_coherent_arm_valid,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_arm_tag,
    output logic o_coherent_valid,
    input logic i_coherent_ready = 1'b0,
    output logic [riscv_pkg::XLEN-1:0] o_coherent_addr,
    output logic [2:0] o_coherent_size,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_tag,
    input logic i_coherent_result_valid = 1'b0,
    output logic o_coherent_result_ready,
    input logic i_coherent_success = 1'b0,
    input logic i_coherent_error = 1'b0,
    output logic o_sc_value_zero,
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
    output logic o_sc_head_is_cached,
    output logic o_sc_fire_success,

    output logic o_sc_pending,
    output riscv_pkg::fu_complete_t o_sc_fu_complete
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (!i_rst_n) reset_seen_q <= 1'b1;
`endif

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

  // Each waiting SC holds an SQ entry until commit, and flushes clear the
  // matching SQ and SC-table entries together. At most SqDepth SCs can wait,
  // including the issuing SC, so a SqDepth table always has a free slot for it.
  // A smaller table could drop an SC at allocation and leave it unable to fire.
  localparam int unsigned ScTableDepth = riscv_pkg::SqDepth;
  logic [ScTableDepth-1:0] sct_valid;
  logic [ScTableDepth-1:0] sct_addr_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sct_tag[ScTableDepth];
  logic [riscv_pkg::XLEN-1:0] sct_addr[ScTableDepth];
  logic [2:0] sct_size[ScTableDepth];
  // Classify each stored PA in parallel with the ROB-head lookup. Selecting
  // one class bit avoids a wide address mux followed by range comparisons
  // on the uncached SC completion path.
  (* keep = "true" *) logic [ScTableDepth-1:0] sct_is_cached;
  function automatic logic addr_is_cached(input logic [riscv_pkg::XLEN-1:0] addr);
    addr_is_cached = (addr >= riscv_pkg::XLEN'(CACHED_BASE)) &&
        (addr < riscv_pkg::XLEN'(CACHED_BASE) + riscv_pkg::XLEN'(CACHED_SIZE_BYTES));
  endfunction
  localparam logic [riscv_pkg::XLEN-1:0] CachedBase = riscv_pkg::XLEN'(CACHED_BASE);
  localparam logic [riscv_pkg::XLEN-1:0] CachedSize = riscv_pkg::XLEN'(CACHED_SIZE_BYTES);
  localparam logic [riscv_pkg::XLEN-1:0] CachedLimit = CachedBase + CachedSize;
  localparam logic [riscv_pkg::XLEN-1:0] CachedMask = CachedSize - 1'b1;
  localparam bit CachedRegionAligned = CachedSize != 0 &&
      (CachedSize & CachedMask) == 0 && (CachedBase & CachedMask) == 0 &&
      CachedLimit > CachedBase;
  if (CachedRegionAligned) begin : gen_coherent_cached_class
    for (genvar i = 0; i < ScTableDepth; i++) begin : gen_slot
      assign sct_is_cached[i] = (sct_addr[i] & ~CachedMask) == CachedBase;
    end
  end else begin : gen_range_cached_class
  for (genvar i = 0; i < ScTableDepth; i++) begin : gen_cached_class
    assign sct_is_cached[i] = addr_is_cached(sct_addr[i]);
  end
  end
`ifndef SYNTHESIS
  if (1'b1) begin : gen_cached_class_check
    for (genvar i = 0; i < ScTableDepth; i++) begin : gen_slot
`ifdef FORMAL
      always_comb begin
`else
      always @(posedge i_clk) begin
        if (!$isunknown(sct_addr[i]))
`endif
        assert (sct_is_cached[i] == addr_is_cached(sct_addr[i]));
      end
    end
  end
`endif

  // Compare ROB ages relative to the head for partial flushes.
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

  // Compare reservation granules before selecting the head entry, for timing.
  // With no head match, the default compares the zero address.
  logic [ScTableDepth-1:0] sct_resv_match;
  always_comb begin
    for (int i = 0; i < ScTableDepth; i++) begin
      sct_resv_match[i] = sct_is_cached[i] ?
          (lq_reservation_addr == sct_addr[i] && i_reservation_size == sct_size[i]) :
          (lq_reservation_addr[riscv_pkg::XLEN-1:3] == sct_addr[i][riscv_pkg::XLEN-1:3]);
    end
  end

  // Head match: an in-flight SC sits at the ROB head.
  logic                       sct_hit;
  logic                       sct_hit_addr_valid;
  logic [riscv_pkg::XLEN-1:0] sct_hit_addr;
  logic                       sct_hit_resv_match;
  logic [                2:0] sct_hit_size;
  logic [   ScTableDepth-1:0] sct_hit_oh;
  always_comb begin
    sct_hit               = 1'b0;
    sct_hit_addr_valid    = 1'b0;
    sct_hit_addr          = '0;
    sct_hit_resv_match    = (lq_reservation_addr[riscv_pkg::XLEN-1:3] == '0);
    sct_hit_oh            = '0;
    sct_hit_size          = '0;
    o_sc_head_query_match = 1'b0;
    o_sc_head_is_cached   = addr_is_cached('0);
    for (int i = 0; i < ScTableDepth; i++) begin
      if (sct_valid[i] && (sct_tag[i] == head_tag)) begin
        sct_hit = 1'b1;
        sct_hit_addr_valid = sct_addr_valid[i];
        sct_hit_addr = sct_addr[i];
        sct_hit_size = sct_size[i];
        o_sc_head_is_cached = sct_is_cached[i];
        sct_hit_resv_match = sct_resv_match[i];
        sct_hit_oh[i] = 1'b1;
        // Use sct_hit_addr's highest-index priority, even if its address is invalid.
        // Coherence queries compare complete DMA sectors.
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
      // Capture issue-cycle faults too. The registered fault blocks firing and
      // clears the entry one cycle later; completion uses the fault path.
      !(speculative_flush_en && is_younger(
          o_mem_rs_issue.rob_tag, i_flush_tag, head_tag
      ));

  // Payload capture omits flush gates for timing. Only sct_valid exposes the
  // payload, so a rejected allocation may safely write a free entry.
  logic sct_payload_alloc;
  assign sct_payload_alloc = o_mem_rs_issue.valid &&
      ((o_mem_rs_issue.op == riscv_pkg::SC_W) ||
       (o_mem_rs_issue.op == riscv_pkg::SC_D));

  logic sc_can_fire;
  logic sc_success;
  logic sc_fire_now;
  logic sc_slot_ready, coherent_head;
  logic coherent_selected_q, coherent_sent_q;
  logic [riscv_pkg::XLEN-1:0] coherent_addr_q, coherent_vaddr_q, coherent_hit_vaddr;
  logic [2:0] coherent_size_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_tag_q;

  if (1'b1) begin : gen_coherent_fault_address
    logic [riscv_pkg::XLEN-1:0] virtual_address_q[ScTableDepth];
    always_ff @(posedge i_clk) begin
      for (int slot = 0; slot < ScTableDepth; slot++) begin
        if (sct_payload_alloc && sct_free_oh[slot]) begin
          virtual_address_q[slot] <= o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0];
          sct_size[slot] <= o_mem_rs_issue.op == riscv_pkg::SC_D ? 3'd3 : 3'd2;
        end
      end
    end
    always_comb begin
      coherent_hit_vaddr = '0;
      for (int slot = 0; slot < ScTableDepth; slot++) begin
        if (sct_hit_oh[slot]) coherent_hit_vaddr = virtual_address_q[slot];
      end
    end
  end

  // The fire also waits for the entry's PA (i_sct_addr_fill_* under active
  // translation). Firing at the issue cycle would compare the VA against the
  // PA-domain reservation, and it would beat the MMU's fault delivery for an
  // SC whose translation is refused.
  assign sc_can_fire = sct_hit && sct_hit_addr_valid && sq_committed_empty;
  // Coherent cached SC matches the exact physical address and W/D size.
  // Other SCs match the reserved doubleword by comparing address[XLEN-1:3].
  assign sc_success  = lq_reservation_valid && sct_hit_resv_match;
  // Wait for coherence permission and an idle MEM adapter input. A live store
  // fault is registered first; next cycle it takes priority over the SC result,
  // which the wrapper holds until the adapter is free.
  riscv_pkg::fu_complete_t sc_fu_complete;
  if (1'b1) begin : gen_coherent_completion
    assign sc_slot_ready = !mem_adapter_result_pending &&
                         !lq_fu_complete.valid &&
                         !sc_completion_pending &&
                         !store_misalign_fu_complete_reg.valid;
    assign coherent_head = o_sc_head_is_cached;
    assign sc_fire_now = coherent_selected_q ?
        (coherent_sent_q && i_coherent_result_valid && sc_slot_ready) :
        (sc_can_fire && !i_coh_sc_hold && sc_slot_ready && (!coherent_head || !sc_success));
    assign o_coherent_arm_valid = coherent_head && sc_can_fire && sc_success &&
        !i_coh_sc_hold && sc_slot_ready && !coherent_selected_q;
    assign o_coherent_arm_tag = head_tag;
    assign o_coherent_valid = coherent_selected_q && !coherent_sent_q;
    assign o_coherent_addr = coherent_addr_q;
    assign o_coherent_size = coherent_size_q;
    assign o_coherent_tag = coherent_tag_q;
    assign o_coherent_result_ready = coherent_selected_q && coherent_sent_q && sc_slot_ready;

    always_ff @(posedge i_clk) begin
      if (!i_rst_n) begin
        coherent_selected_q <= 1'b0;
        coherent_sent_q <= 1'b0;
        coherent_addr_q <= '0;
        coherent_vaddr_q <= '0;
        coherent_size_q <= '0;
        coherent_tag_q <= '0;
      end else begin
        if (o_coherent_arm_valid && i_atomic_protected && !speculative_flush_all) begin
          coherent_selected_q <= 1'b1;
          coherent_sent_q <= 1'b0;
          coherent_addr_q <= sct_hit_addr;
          coherent_vaddr_q <= coherent_hit_vaddr;
          coherent_size_q <= sct_hit_size;
          coherent_tag_q <= head_tag;
        end
        if (o_coherent_valid && i_coherent_ready) coherent_sent_q <= 1'b1;
        if (i_coherent_result_valid && o_coherent_result_ready) coherent_selected_q <= 1'b0;
      end
    end

    // SC completion carries the selected request identity.
    always_comb begin
      o_sc_value_zero = coherent_selected_q ? i_coherent_success : sc_success;
      sc_fu_complete = '0;
      sc_fu_complete.valid = sc_fire_now;
      sc_fu_complete.tag = coherent_selected_q ? coherent_tag_q : head_tag;
      sc_fu_complete.value = {
        {(riscv_pkg::FLEN - 1) {1'b0}}, ~(coherent_selected_q ? i_coherent_success : sc_success)
      };
      if (coherent_selected_q && i_coherent_error) begin
        o_sc_value_zero = coherent_vaddr_q == '0;
        sc_fu_complete.value = riscv_pkg::FLEN'(coherent_vaddr_q);
        sc_fu_complete.exception = 1'b1;
        sc_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(riscv_pkg::ExcStoreAccessFault);
      end
    end
    assign o_sc_fire_success = sc_fire_now &&
        (coherent_selected_q ? i_coherent_success && !i_coherent_error : sc_success);
  end
  assign o_sc_head_addr_valid = sct_hit && sct_hit_addr_valid;
  assign o_sc_head_addr = sct_hit_addr;

`ifdef FORMAL
`ifdef SC_HEAD_QUERY_LOCAL_PROOF
  always_comb begin
    assert (o_sc_head_is_cached == addr_is_cached(o_sc_head_addr));
    assert (o_sc_head_query_match ==
            (o_sc_head_addr_valid &&
             (o_sc_head_addr[riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb] ==
              i_coh_query_addr[riscv_pkg::XLEN-1:riscv_pkg::DmaCoherenceLineLsb])));
  end
`endif
`endif

  // Table valid bits: allocate on SC issue, free on fire, flush younger entries.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      sct_valid <= '0;
    end else begin
      // Preserve older SCs on a partial flush; they may still be waiting for the head.
      if (i_flush_en) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && is_younger(sct_tag[i], i_flush_tag, head_tag)) begin
            sct_valid[i] <= 1'b0;
          end
        end
      end
      // The registered fault blocks firing this cycle and clears the faulting SC
      // on the edge. It completes only through the fault path.
      if (store_misalign_fu_complete_reg.valid) begin
        for (int i = 0; i < ScTableDepth; i++) begin
          if (sct_valid[i] && (sct_tag[i] == store_misalign_fu_complete_reg.tag)) begin
            sct_valid[i] <= 1'b0;
          end
        end
      end
      if (sc_fire_now) begin
        for (int i = 0; i < ScTableDepth; i++) if (sct_hit_oh[i]) sct_valid[i] <= 1'b0;
      end
      // Allocation targets a free slot; fire, fault, and flush target valid slots,
      // so their indices cannot collide. ScTableDepth guarantees a free slot.
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
          // SC has no immediate: dispatch supplies imm==0, so src1 is its address.
          sct_addr[i] <= o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0];
        end
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n && sct_alloc && !sct_has_free)
      $error(
          "sc_pending_unit: SC tag %0d issued with the table full; it would never fire",
          o_mem_rs_issue.rob_tag
      );
  end

  always_ff @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n && sct_payload_alloc && !$isunknown(
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
`ifndef SYNTHESIS
`ifdef FORMAL
  always_comb begin
`else
  always @(posedge i_clk) begin
    if (!$isunknown({o_sc_value_zero, sc_fu_complete.value}))
`endif
      p_sc_value_zero_exact : assert (o_sc_value_zero == (sc_fu_complete.value == '0));
  end
`endif

`ifdef COHERENT_SC_LOCAL_PROOF
  logic [1:0] f_selected_past = '0;
  always_ff @(posedge i_clk) begin
    f_selected_past <= {f_selected_past[0], 1'b1};
    if (f_selected_past[1] && i_rst_n && $past(i_rst_n)) begin
      if ($past(coherent_selected_q)) begin
        assert ({coherent_addr_q, coherent_vaddr_q, coherent_size_q, coherent_tag_q} == $past(
            {coherent_addr_q, coherent_vaddr_q, coherent_size_q, coherent_tag_q}
        ));
        if (!$past(i_coherent_result_valid && o_coherent_result_ready))
          assert (coherent_selected_q);
      end
      if (coherent_selected_q && !$past(coherent_selected_q))
        assert ($past(o_coherent_arm_valid && i_atomic_protected && !speculative_flush_all));
      if ($past(o_coherent_valid && !i_coherent_ready)) assert (o_coherent_valid);
      if (o_coherent_result_ready) assert (coherent_selected_q && coherent_sent_q);
      if (coherent_selected_q && sc_fire_now) begin
        assert (sc_fu_complete.tag == coherent_tag_q);
        if (i_coherent_error) begin
          assert (sc_fu_complete.exception);
          assert (sc_fu_complete.value == riscv_pkg::FLEN'(coherent_vaddr_q));
        end
        assert (i_coherent_result_valid && o_coherent_result_ready);
      end
    end
  end
`endif

endmodule
