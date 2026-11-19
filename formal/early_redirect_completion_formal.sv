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
// Check the production redirect and flush controllers with arbitrary issue
// traffic, commit events, reset, and checkpoint ownership.
module early_redirect_completion_formal #(
    localparam int unsigned TagBits = riscv_pkg::ReorderBufferTagWidth
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_trap,
    input logic i_xret,
    input logic i_native_fence,
    input logic i_translation_flush,
    input logic i_commit_miss,
    input logic [1:0] i_correct_commit,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_younger_than_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0][TagBits-1:0] i_checkpoint_owner_tag,
    input logic i_fatal_stop,
    input logic i_is_jalr,
    input logic i_taken,
    input logic [riscv_pkg::XLEN-1:0] i_target,
    input logic [TagBits-1:0] i_head,
    input riscv_pkg::rs_issue_t i_issue,
    input riscv_pkg::reorder_buffer_branch_update_t i_update,
    input riscv_pkg::reorder_buffer_commit_t i_commit,
    input riscv_pkg::reorder_buffer_commit_t i_commit_2,
    input logic [riscv_pkg::XLEN-1:0] i_fence_i_target_pc
);
  logic trap_q, xret_q, fence_q, native_fence_q;
  logic early_active, early_pending, early_fire, backend, backend_next;
  logic full_flush, commit_pending, partial_flush, fetch_flush, after_head, jalr;
  logic [TagBits-1:0] early_tag, backend_tag, flush_tag;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint;

  always_ff @(posedge i_clk) begin
    trap_q <= !i_rst && i_trap;
    xret_q <= !i_rst && i_xret;
    fence_q <= !i_rst && (i_native_fence || i_translation_flush);
    native_fence_q <= !i_rst && i_native_fence;
  end

  early_misprediction_recovery recovery (
      .i_clk,
      .i_rst,
      .i_fatal_stop,
      .i_branch_update(i_update),
      .i_rs_issue_int(i_issue),
      .i_is_jalr_issue(i_is_jalr),
      .i_branch_taken_resolved(i_taken),
      .i_branch_target_resolved(i_target),
      .i_fence_i_flush(fence_q),
      .i_active_fence_i_flush(native_fence_q),
      .i_mispredict_recovery_pending(commit_pending),
      .i_flush_all(full_flush),
      .i_flush_for_trap(trap_q),
      .i_flush_for_mret(xret_q),
      .i_trap_taken_reg(trap_q),
      .i_mret_taken_reg(xret_q),
      .o_early_mispredict_active(early_active),
      .o_early_mispredict_pending(early_pending),
      .o_early_mispredict_fire(early_fire),
      .o_early_backend_recovery_pending(backend),
      .o_early_backend_recovery_pending_next(backend_next),
      .o_early_backend_flush_tag(backend_tag),
      .o_early_mispredict_tag(early_tag),
      .o_early_mispredict_checkpoint_id(checkpoint),
      .o_early_mispredict_is_jalr(jalr)
  );

  misprediction_flush_controller flush_control (
      .i_clk,
      .i_rst,
      .i_rob_commit_misprediction_raw(i_commit_miss),
      .i_rob_commit_correct_branch_raw(i_correct_commit[0]),
      .i_rob_commit_comb(i_commit),
      .i_rob_commit_correct_branch_2_raw(i_correct_commit[1]),
      .i_rob_commit_comb_2(i_commit_2),
      .i_early_mispredict_active(early_active),
      .i_early_mispredict_pending(early_pending),
      .i_early_mispredict_fire(early_fire),
      .i_early_backend_recovery_pending(backend),
      .i_early_backend_recovery_pending_next(backend_next),
      .i_head_tag(i_head),
      .i_early_mispredict_tag(early_tag),
      .i_early_backend_flush_tag(backend_tag),
      .i_early_mispredict_checkpoint_id(checkpoint),
      .i_trap_taken_reg(trap_q),
      .i_mret_taken_reg(xret_q),
      .i_flush_for_trap(trap_q),
      .i_flush_for_mret(xret_q),
      .i_fence_i_flush(fence_q),
      .i_active_fence_i_flush(native_fence_q),
      .i_trap_taken(i_trap),
      .i_mret_taken(i_xret),
      .i_fence_class_flush_event(i_native_fence || i_translation_flush),
      .i_fence_i_target_pc,
      .i_checkpoint_in_use,
      .i_checkpoint_owner_tag,
      .i_checkpoint_younger_than_flush,
      .o_mispredict_recovery_pending(commit_pending),
      .o_fetch_flush(fetch_flush),
      .o_flush_en(partial_flush),
      .o_flush_tag(flush_tag),
      .o_flush_all(full_flush),
      .o_commit_recovery_flush_after_head(after_head)
  );

  // A full flush in the redirect cycle already selects an older target.
  // An accepted redirect remembers its own tag until the next edge.
  logic reset_seen = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen <= 1'b1;
    if (reset_seen && !i_rst && early_active && !full_flush) begin
      p_redirect_flushes_fetch : assert (fetch_flush);
    end
    if (reset_seen && !i_rst && $past(!i_rst && early_active && !full_flush)) begin
      p_redirect_completes :
      assert (full_flush || (partial_flush && flush_tag == $past(early_tag)));
      c_jalr_partial : cover ($past(jalr) && !full_flush && partial_flush && !after_head);
      c_branch_partial : cover (!$past(jalr) && !full_flush && partial_flush && !after_head);
      c_older_commit : cover (after_head && !full_flush && $past(i_head != early_tag));
      c_trap : cover (full_flush && trap_q);
      c_xret : cover (full_flush && xret_q);
      c_native_fence : cover (full_flush && native_fence_q);
      c_translation : cover (full_flush && fence_q && !native_fence_q);
    end
  end
endmodule
