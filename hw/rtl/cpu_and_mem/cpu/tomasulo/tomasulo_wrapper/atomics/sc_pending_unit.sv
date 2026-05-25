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
// Extracted verbatim from tomasulo_wrapper.sv (pure RTL boundary move, zero
// functional change).  Store-conditional (SC.W) resolution:
//   * the SC pending register FSM (set at MEM_RS SC issue, cleared on fire /
//     flush / age) and its data capture (rob_tag + address),
//   * the combinational fire/success decode, and
//   * the sc_fu_complete result packet.
// The store-misalign exception path, the MEM-adapter input mux, and
// lq_result_accepted remain in the wrapper; this unit consumes store_misalign_*
// as inputs and produces sc_pending (visible to dispatch) and sc_fu_complete
// (registered by the wrapper before the MEM adapter).
//
// is_younger is duplicated here (it is also used elsewhere in the wrapper, and
// the wrapper comment notes it is identical to the load_queue / RS copies).
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
  // Alias input ports back to the wrapper's local names so the bodies below are
  // byte-identical to the original tomasulo_wrapper logic.
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

  // SC pending state (rob_tag / addr are internal; sc_pending is also output)
  logic sc_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sc_pending_rob_tag;
  logic [riscv_pkg::XLEN-1:0] sc_pending_addr;

  // Age comparison for SC flush guard (identical to load_queue/reservation_station)
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

  logic sc_can_fire;
  logic sc_success;
  logic sc_fire_now;

  assign sc_can_fire = sc_pending && (sc_pending_rob_tag == head_tag) && sq_committed_empty;
  assign sc_success = lq_reservation_valid
      && (lq_reservation_addr[riscv_pkg::XLEN-1:2] == sc_pending_addr[riscv_pkg::XLEN-1:2]);
  // Arm SC only when the MEM adapter has no competing same-cycle producer.
  // This keeps the rare SC head-tag compare local to the SC register D path;
  // the registered completion below owns the MEM adapter on the next cycle.
  assign sc_fire_now = sc_can_fire &&
                       !mem_adapter_result_pending &&
                       !lq_fu_complete.valid &&
                       !store_misalign_issue &&
                       !store_misalign_fu_complete_reg.valid;

  // SC fu_complete generation
  riscv_pkg::fu_complete_t sc_fu_complete;
  always_comb begin
    sc_fu_complete       = '0;
    sc_fu_complete.valid = sc_fire_now;
    sc_fu_complete.tag   = sc_pending_rob_tag;
    sc_fu_complete.value = {{(riscv_pkg::FLEN - 1) {1'b0}}, ~sc_success};
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sc_pending <= 1'b0;
    end else if (speculative_flush_all) begin
      sc_pending <= 1'b0;
    end else begin
      // Set when MEM_RS issues SC.  Gate with flush signals because
      // the RS output valid is no longer suppressed during flush for
      // timing closure — a phantom SC set during partial flush would
      // leave sc_pending stuck (the flushed tag never reaches head).
      if (o_mem_rs_issue.valid && !speculative_flush_all && !speculative_flush_en
          && (o_mem_rs_issue.op == riscv_pkg::SC_W)) begin
        sc_pending <= 1'b1;
      end
      // Clear when SC fu_complete is armed for the registered MEM path.
      if (sc_fire_now) begin
        sc_pending <= 1'b0;
      end
      // A pending SC is speculative if it is younger than the flush boundary,
      // or if recovery is draining everything younger than the current/just-
      // retired head.
      if (i_flush_en && sc_pending && (speculative_partial_flush || is_younger(
              sc_pending_rob_tag, i_flush_tag, head_tag
          ))) begin
        sc_pending <= 1'b0;
      end
    end
  end

  // SC data capture (no reset - gated by sc_pending)
  always_ff @(posedge i_clk) begin
    if (o_mem_rs_issue.valid && !speculative_flush_all && !speculative_flush_en
        && (o_mem_rs_issue.op == riscv_pkg::SC_W)) begin
      sc_pending_rob_tag <= o_mem_rs_issue.rob_tag;
      sc_pending_addr    <= sq_effective_addr;
    end
  end

  assign o_sc_pending     = sc_pending;
  assign o_sc_fu_complete = sc_fu_complete;

endmodule
