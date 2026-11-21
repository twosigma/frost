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

module rob_wfi_head_ready_formal (
    input logic i_clk,
    input logic i_rst_n,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_live_wfis,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_live_done,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_branch,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_exception,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_result_held,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_head_mask,
    input riscv_pkg::reorder_buffer_alloc_req_t i_alloc_req,
    input riscv_pkg::reorder_buffer_alloc_req_t i_alloc_req_2,
    input logic i_alloc_en,
    input logic i_alloc_en_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_tag_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic i_head_valid,
    input logic i_head_is_wfi,
    input logic i_head_exception,
    input logic i_head_cause_zero,
    input logic i_head_stored_ready,
    input logic i_commit_ready,
    input logic i_commit,
    input logic i_interrupt_pending,
    input logic i_completion,
    input logic i_jal_mispredict_retired,
    input logic i_flush_en,
    input logic i_flush_all,
    input logic i_flush_after_head_commit
);
  logic reset_seen = 1'b0;
  wire  alloc_wfi = i_alloc_en && i_alloc_req.is_wfi;
  wire  alloc_wfi_2 = i_alloc_en_2 && i_alloc_req_2.is_wfi;
  wire  legal_wfi_head = i_head_valid && i_head_is_wfi && !i_head_exception;

  // The witnesses use concrete, uncompressed alloc requests for WFI and
  // JAL x0,+12, with a fall-through prediction. Keep unused payloads free.
  function automatic logic matches_cover_instruction(
      input riscv_pkg::reorder_buffer_alloc_req_t request, input logic jal);
    riscv_pkg::reorder_buffer_alloc_req_t expected;
    expected = '0;
    expected.alloc_valid = 1'b1;
    expected.pc = request.pc;
    expected.rs_type = riscv_pkg::RS_NONE;
    expected.predicted_target = request.predicted_target;
    expected.branch_target = jal ? request.pc + 64'd12 : request.branch_target;
    expected.link_addr = request.pc + 64'd4;
    expected.is_branch = jal;
    expected.is_jal = jal;
    expected.is_wfi = !jal;
    expected.csr_addr = request.csr_addr;
    expected.insn_bits = jal ? 32'h00c0_006f : 32'h1050_0073;
    return !request.pc[0] && request == expected;
  endfunction

  wire active_no_completion = i_rst_n && !i_completion;
  wire slot1_wfi = matches_cover_instruction(i_alloc_req, 1'b0);
  wire slot1_jal = matches_cover_instruction(i_alloc_req, 1'b1);
  wire slot2_wfi = matches_cover_instruction(i_alloc_req_2, 1'b0);
  wire waiting_alloc = active_no_completion && i_alloc_en && !i_alloc_en_2 && slot1_wfi;
  wire jal_wfi_alloc = active_no_completion && i_alloc_en && i_alloc_en_2 &&
      slot1_jal && slot2_wfi && i_alloc_req_2.pc == i_alloc_req.link_addr;
  wire jal_mispredict = active_no_completion && i_jal_mispredict_retired;
  wire commit_flush = i_flush_en && !i_flush_all && i_flush_after_head_commit;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) reset_seen <= 1'b1;
    if (reset_seen && i_rst_n) begin
      // The decoder supplies disjoint WFI and control-flow classes.
      if (alloc_wfi)
        a_slot1_wfi_class :
        assume (!(i_alloc_req.is_branch || i_alloc_req.is_jal || i_alloc_req.is_jalr));
      if (alloc_wfi_2)
        a_slot2_wfi_class :
        assume (!(i_alloc_req_2.is_branch || i_alloc_req_2.is_jal || i_alloc_req_2.is_jalr));
      // The ROB interface permits one held result. An already complete
      // instruction can hold a result only if it is a nonexceptional branch.
      a_single_result_held : assume ($onehot0(i_result_held));
      a_held_complete_branch :
      assume ((i_result_held & i_live_done & ~(i_branch & ~i_exception)) == '0);

      p_single_head : assert ($onehot(i_head_mask));
      p_live_wfi_complete : assert ((i_live_wfis & ~i_live_done) == '0);
      p_live_wfi_is_not_branch : assert ((i_live_wfis & i_branch) == '0);
      p_live_wfi_has_no_held_result : assert ((i_live_wfis & i_result_held) == '0);
      if (legal_wfi_head) p_wfi_head_stored_ready : assert (i_head_stored_ready);

      if (legal_wfi_head && i_head_cause_zero && i_head_stored_ready &&
          !i_commit && !i_completion) begin
        if (i_commit_ready && !i_interrupt_pending)
          c_waiting_slot1_wfi : cover ($past(waiting_alloc) && i_head_tag == $past(i_alloc_tag));
        if (commit_flush && !i_commit_ready && $past(jal_mispredict))
          c_slot2_wfi_in_commit_recovery :
          cover ($past(jal_wfi_alloc, 2) && i_head_tag == $past(i_alloc_tag_2, 2));
      end
    end
  end
endmodule

bind reorder_buffer rob_wfi_head_ready_formal wfi_head_ready (
    .i_clk,
    .i_rst_n,
    .i_live_wfis(rob_valid & rob_f_is_wfi),
    .i_live_done(rob_valid & rob_done),
    .i_branch(rob_f_is_branch),
    .i_exception(rob_exception),
    .i_result_held,
    .i_head_mask(head_clear_mask),
    .i_alloc_req,
    .i_alloc_req_2,
    .i_alloc_en(alloc_en),
    .i_alloc_en_2(alloc_en_2),
    .i_alloc_tag(tail_idx),
    .i_alloc_tag_2(tail_idx_2),
    .i_head_tag(head_idx),
    .i_head_valid(head_valid),
    .i_head_is_wfi(o_head_is_wfi),
    .i_head_exception(head_exception),
    .i_head_cause_zero(o_trap_cause == '0),
    .i_head_stored_ready(head_stored_ready),
    .i_commit_ready(commit_ready_early),
    .i_commit(o_commit_valid_raw),
    .i_interrupt_pending,
    .i_completion(i_cdb_write.valid || i_cdb_write_2.valid || i_branch_update.valid ||
                  i_store_complete_valid),
    .i_jal_mispredict_retired(o_commit_misprediction_raw && o_commit_comb.is_jal),
    .i_flush_en,
    .i_flush_all,
    .i_flush_after_head_commit
);
