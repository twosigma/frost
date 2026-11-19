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

// Compare two predictions of the same instruction at the execution boundary.
// ID precomputes a direct branch's target comparison from its PC-relative
// target, carried in imm. JALR (including a return) compares the actual target.
module branch_prediction_resolution_formal (
    input riscv_pkg::rs_issue_t i_issue,
    input logic [1:0] i_taken,
    input logic [1:0][riscv_pkg::XLEN-1:0] i_target,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_branch_predicate_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_mispredict_tag,
    input logic i_early_mispredict_active,
    input logic i_early_backend_recovery_pending,
    input logic i_mispredict_recovery_pending,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_fence_i_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0]
        i_checkpoint_owner_tag
);

  riscv_pkg::reorder_buffer_branch_update_t update[2];
  logic [1:0] correct;
  // Trap, return and fence flushes discard every issued branch. Partial
  // recovery preserves strictly older issues and takes priority over the
  // commit-pending indication when both controls are presented.
  logic [riscv_pkg::ReorderBufferTagWidth:0] issue_age, cutoff_age;
  logic partial_recovery, full_flush, checkpoint_live, eligible_issue, expected_valid;
  assign issue_age = {1'b0, i_branch_predicate_tag} - {1'b0, i_head_tag};
  assign cutoff_age = {1'b0, i_early_mispredict_tag} - {1'b0, i_head_tag};
  assign partial_recovery = i_early_mispredict_active || i_early_backend_recovery_pending;
  assign full_flush = i_flush_for_trap || i_flush_for_mret || i_fence_i_flush;
  assign checkpoint_live = !i_issue.has_checkpoint ||
      (i_checkpoint_in_use[i_issue.checkpoint_id] &&
       i_checkpoint_owner_tag[i_issue.checkpoint_id] == i_branch_predicate_tag);
  assign eligible_issue = i_issue.valid && i_issue.is_branch_class && !i_issue.is_jal &&
                          checkpoint_live;
  assign expected_valid = eligible_issue && !full_flush &&
                          (partial_recovery ? issue_age < cutoff_age :
                                              !i_mispredict_recovery_pending);
  for (genvar p = 0; p < 2; p++) begin : gen_prediction
    riscv_pkg::rs_issue_t issue;
    always_comb begin
      issue = i_issue;
      issue.predicted_taken = i_taken[p];
      issue.predicted_target = i_target[p];
      issue.predicted_target_ok = (i_issue.imm == i_target[p]);
    end
    branch_resolution u_resolve (
        .i_rs_issue_int(issue),
        .i_branch_predicate_tag,
        .i_head_tag,
        .i_early_mispredict_tag,
        .i_early_mispredict_active,
        .i_early_backend_recovery_pending,
        .i_mispredict_recovery_pending,
        .i_flush_for_trap,
        .i_flush_for_mret,
        .i_fence_i_flush,
        .i_checkpoint_in_use,
        .i_checkpoint_owner_tag,
        .o_branch_update(update[p]),
        .o_branch_resolved_correct(correct[p]),
        .o_is_jalr_issue(),
        .o_branch_taken_resolved(),
        .o_branch_target_resolved()
    );
    logic missed;
    assign missed = (i_taken[p] != update[p].taken) ||
                    (update[p].taken && i_target[p] != update[p].target);
    always_comb begin
      p_wrong_direction_or_taken_target_recovers :
      assert (update[p].mispredicted == (update[p].valid && missed));
      p_correct_resolution : assert (correct[p] == (update[p].valid && !update[p].mispredicted));
      p_only_surviving_issues_update : assert (update[p].valid == expected_valid);
    end
  end
  always_comb begin
    p_prediction_independent_resolution :
    assert ({update[0].valid, update[0].tag, update[0].taken, update[0].target} ==
            {update[1].valid, update[1].tag, update[1].taken, update[1].target});
    cover (correct[0] && update[1].mispredicted && i_issue.is_jalr && (&i_taken));
    cover (correct[0] && update[1].mispredicted && !i_issue.is_jalr && i_taken == 2'b01);
    cover (correct[0] && update[1].mispredicted && !i_issue.is_jalr && i_taken == 2'b10);
    cover ((&correct) && i_taken == 2'b00 && i_target[0] != i_target[1]);
    cover (partial_recovery && i_mispredict_recovery_pending && update[0].valid);
    cover (eligible_issue && !full_flush && partial_recovery && issue_age >= cutoff_age &&
           !update[0].valid);
  end

endmodule : branch_prediction_resolution_formal
