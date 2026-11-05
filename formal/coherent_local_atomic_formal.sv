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

// Reservation and completion blocks are checked against the production wrapper.
module coherent_local_reservation_formal (
    input logic commit_bus_q_valid,
    input logic commit_q_is_sc,
    input logic commit_q_sc_failed,
    input riscv_pkg::reorder_buffer_commit_t commit_bus_q,
    input logic i_coherent_atomic_live,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_sc_tag,
    input logic i_coherent_sc_write_done,
    input logic sq_cache_invalidate_valid,
    input logic lq_reservation_valid,
    input logic o_coherent_write_sc,
    input logic o_sq_mem_write_is_cached,
    input logic [63:0] sq_cache_invalidate_addr,
    input logic [63:0] lq_reservation_addr,
    output logic sc_clear_reservation,
    output logic reservation_snoop_invalidate,
    output logic sc_discard
);
  assign sc_clear_reservation = (commit_bus_q_valid && commit_q_is_sc &&
      !(!commit_q_sc_failed &&
        i_coherent_atomic_live && commit_bus_q.tag == o_coherent_sc_tag)) ||
      (i_coherent_sc_write_done);
  assign reservation_snoop_invalidate = sq_cache_invalidate_valid &&
      lq_reservation_valid &&
      !(o_coherent_write_sc && o_sq_mem_write_is_cached) &&
      ((sq_cache_invalidate_addr[riscv_pkg::XLEN-1:5] == lq_reservation_addr[riscv_pkg::XLEN-1:5]));
  assign sc_discard = commit_bus_q_valid && commit_q_sc_failed;
  always_comb begin
    if (commit_bus_q_valid && commit_q_is_sc && !commit_q_sc_failed &&
        i_coherent_atomic_live && commit_bus_q.tag == o_coherent_sc_tag)
      p_success_clears_at_write : assert (sc_clear_reservation == i_coherent_sc_write_done);
    if (commit_bus_q_valid && commit_q_is_sc && commit_q_sc_failed)
      p_failure_clears_and_discards : assert (sc_clear_reservation && sc_discard);
    if (o_coherent_write_sc && o_sq_mem_write_is_cached)
      p_sc_snoop_exclusion : assert (!reservation_snoop_invalidate);
  end
endmodule

module coherent_local_completion_formal (
    input logic i_clk,
    input logic i_rst_n,
    input riscv_pkg::fu_complete_t lq_fu_complete,
    input riscv_pkg::fu_complete_t sc_fu_complete,
    input riscv_pkg::fu_complete_t store_misalign_fu_complete_reg,
    input riscv_pkg::fu_complete_t uncached_store_complete,
    output logic lq_result_accepted,
    output logic mem_adapter_result_pending,
    output logic sc_pending,
    output riscv_pkg::fu_complete_t result
);
  wire speculative_flush_all = 1'b0;
  wire speculative_flush_en = 1'b0;
  wire [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag = '0, head_tag = 2;
  riscv_pkg::fu_complete_t mem_adapter_to_arbiter;
  logic [riscv_pkg::NumFus-1:0] o_cdb_grant;
  riscv_pkg::fu_complete_t sc_fu_complete_reg;
  logic sc_completion_held;
  assign sc_completion_held = sc_fu_complete_reg.valid && store_misalign_fu_complete_reg.valid;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) sc_fu_complete_reg.valid <= 1'b0;
    else sc_fu_complete_reg.valid <= sc_fu_complete.valid || sc_completion_held;

    if (!sc_fu_complete_reg.valid) begin
      sc_fu_complete_reg.tag <= sc_fu_complete.tag;
      sc_fu_complete_reg.value <= sc_fu_complete.value;
      sc_fu_complete_reg.exception <= sc_fu_complete.exception;
      sc_fu_complete_reg.exc_cause <= sc_fu_complete.exc_cause;
      sc_fu_complete_reg.fp_flags <= sc_fu_complete.fp_flags;
    end
  end


  (* dont_touch = "true" *)logic sc_valid_adapter_q;
  (* dont_touch = "true" *)logic sc_valid_lq_q;
  (* dont_touch = "true" *)logic sc_valid_issue_q;
  (* dont_touch = "true" *)logic sc_valid_wakeup_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      sc_valid_adapter_q <= 1'b0;
      sc_valid_lq_q      <= 1'b0;
      sc_valid_issue_q   <= 1'b0;
      sc_valid_wakeup_q  <= 1'b0;
    end else begin
      sc_valid_adapter_q <= sc_fu_complete.valid ||
          (sc_valid_adapter_q && store_misalign_fu_complete_reg.valid);
      sc_valid_lq_q <= sc_fu_complete.valid ||
          (sc_valid_lq_q && store_misalign_fu_complete_reg.valid);
      sc_valid_issue_q <= sc_fu_complete.valid ||
          (sc_valid_issue_q && store_misalign_fu_complete_reg.valid);
      sc_valid_wakeup_q <= sc_fu_complete.valid ||
          (sc_valid_wakeup_q && store_misalign_fu_complete_reg.valid);
    end
  end


  riscv_pkg::fu_complete_t mem_fu_to_adapter;
  always_comb begin
    if (store_misalign_fu_complete_reg.valid) begin
      mem_fu_to_adapter = store_misalign_fu_complete_reg;
    end else if (sc_valid_adapter_q) begin
      mem_fu_to_adapter = sc_fu_complete_reg;
      mem_fu_to_adapter.valid = 1'b1;
    end else if (uncached_store_complete.valid) begin
      mem_fu_to_adapter = uncached_store_complete;
    end else begin
      mem_fu_to_adapter = lq_fu_complete;
    end
  end


  assign lq_result_accepted = lq_fu_complete.valid &&
                              !uncached_store_complete.valid &&
                              !sc_valid_lq_q &&
                              !store_misalign_fu_complete_reg.valid &&
                              !mem_adapter_result_pending;

  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .ALWAYS_GRANTED(1'b1)
  ) u_mem_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mem_fu_to_adapter),
      .o_fu_complete   (mem_adapter_to_arbiter),
      .o_held_value    (),
      .i_grant         (o_cdb_grant[3]),
      .o_result_pending(mem_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );
  (* anyseq *) riscv_pkg::fu_complete_t competing;
  cdb_arbiter arbiter (
      .i_clk,
      .i_rst_n,
      .i_fu_complete_0(competing),
      .i_fu_complete_1(competing),
      .i_fu_complete_2(competing),
      .i_fu_complete_3(mem_adapter_to_arbiter),
      .i_fu_complete_4(competing),
      .i_fu_complete_5(competing),
      .i_fu_complete_6(competing),
      .i_fu_complete_7(competing),
      .i_alu_value_is_live(1'b0),
      .i_alu_live_value('0),
      .i_alu_tree_fallback_value(competing.value),
      .i_alu2_value_is_live(1'b0),
      .i_alu2_live_value('0),
      .i_alu2_tree_fallback_value(competing.value),
      .i_kill(1'b0),
      .o_grant(o_cdb_grant)
  );
  assign sc_pending = sc_fu_complete_reg.valid;
  always_comb begin
    result = mem_adapter_to_arbiter;
    result.valid = mem_adapter_to_arbiter.valid && o_cdb_grant[riscv_pkg::FU_MEM];
    p_mem_service : assert (!mem_adapter_to_arbiter.valid || o_cdb_grant[riscv_pkg::FU_MEM]);
    p_mem_no_held_result : assert (!mem_adapter_result_pending);
  end
endmodule

module coherent_local_atomic_formal #(
    parameter int unsigned MODE = 1,
    parameter bit COVER_MODE = 0
) (
    input logic i_clk
);
  coherence_store_boundary_formal #(
      .MODE(MODE),
      .SECTOR_CASE(0),
      .LOCAL_PROGRESS(1),
      .COVER_LOCAL(COVER_MODE)
  ) dependency (
      .i_clk
  );
endmodule
