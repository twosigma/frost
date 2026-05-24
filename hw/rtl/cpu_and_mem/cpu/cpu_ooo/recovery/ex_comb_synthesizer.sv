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

/*
 * from_ex_comb synthesizer.
 *
 * The IF stage consumes a from_ex_comb_t for branch redirect, BTB update, and
 * RAS restore. In the OOO core these effects originate at branch resolution /
 * ROB commit rather than an in-order EX stage, so this block synthesizes that
 * struct from the early-misprediction, commit-time-misprediction, and
 * correctly-predicted-branch-commit paths (priority in that order).
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Synthesize from_ex_comb for IF Stage" always_comb, with the parent's
 * signals presented as ports and aliased back to their original names.
 */

module ex_comb_synthesizer #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Early-misprediction recovery path.
    input logic                             i_early_mispredict_active,
    input logic [                 XLEN-1:0] i_early_mispredict_redirect_pc,
    input logic [                 XLEN-1:0] i_early_mispredict_pc,
    input logic [                 XLEN-1:0] i_early_mispredict_branch_target,
    input logic                             i_early_mispredict_branch_taken,
    input logic                             i_early_mispredict_is_compressed,
    input logic [riscv_pkg::RasPtrBits-1:0] i_restored_ras_tos,
    input logic [  riscv_pkg::RasPtrBits:0] i_restored_ras_valid_count,

    // Commit-time misprediction recovery path.
    input logic                                    i_mispredict_recovery_pending,
    input cpu_ooo_pkg::mispredict_commit_capture_t i_mispredict_commit_q,

    // Correctly-predicted branch commit path (BTB update only).
    input logic                                        i_correct_branch_commit_pending,
    input cpu_ooo_pkg::correct_branch_commit_capture_t i_correct_branch_commit_q,

    output riscv_pkg::from_ex_comb_t o_from_ex_comb
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  logic early_mispredict_active;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;
  logic early_mispredict_is_compressed;
  logic [riscv_pkg::RasPtrBits-1:0] restored_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] restored_ras_valid_count;
  logic mispredict_recovery_pending;
  cpu_ooo_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic correct_branch_commit_pending;
  cpu_ooo_pkg::correct_branch_commit_capture_t correct_branch_commit_q;
  assign early_mispredict_active        = i_early_mispredict_active;
  assign early_mispredict_redirect_pc   = i_early_mispredict_redirect_pc;
  assign early_mispredict_pc            = i_early_mispredict_pc;
  assign early_mispredict_branch_target = i_early_mispredict_branch_target;
  assign early_mispredict_branch_taken  = i_early_mispredict_branch_taken;
  assign early_mispredict_is_compressed = i_early_mispredict_is_compressed;
  assign restored_ras_tos               = i_restored_ras_tos;
  assign restored_ras_valid_count       = i_restored_ras_valid_count;
  assign mispredict_recovery_pending    = i_mispredict_recovery_pending;
  assign mispredict_commit_q            = i_mispredict_commit_q;
  assign correct_branch_commit_pending  = i_correct_branch_commit_pending;
  assign correct_branch_commit_q        = i_correct_branch_commit_q;

  riscv_pkg::from_ex_comb_t from_ex_comb_synth;

  always_comb begin
    from_ex_comb_synth = '0;

    if (early_mispredict_active) begin
      // Early misprediction recovery: redirect PC and update BTB
      from_ex_comb_synth.branch_taken                       = 1'b1;
      from_ex_comb_synth.branch_target_address              = early_mispredict_redirect_pc;

      // Early recovery only handles checkpointed conditional branches, so the
      // BTB update and RAS restore are unconditional on this path.
      from_ex_comb_synth.btb_update                         = 1'b1;
      from_ex_comb_synth.btb_update_pc                      = early_mispredict_pc;
      from_ex_comb_synth.btb_update_target                  = early_mispredict_branch_target;
      from_ex_comb_synth.btb_update_taken                   = early_mispredict_branch_taken;
      from_ex_comb_synth.btb_update_compressed              = early_mispredict_is_compressed;
      from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;

      from_ex_comb_synth.ras_misprediction                  = 1'b1;
      from_ex_comb_synth.ras_restore_tos                    = restored_ras_tos;
      from_ex_comb_synth.ras_restore_valid_count            = restored_ras_valid_count;
    end else if (mispredict_recovery_pending) begin
      // Commit-time fallback misprediction recovery.
      from_ex_comb_synth.branch_taken          = 1'b1;
      from_ex_comb_synth.branch_target_address = mispredict_commit_q.redirect_pc;

      if (mispredict_commit_q.is_branch && !mispredict_commit_q.is_jalr) begin
        // BTB update for conditional branches AND JAL. Previously JAL was
        // excluded, causing every execution of a BTB-cold JAL to mispredict
        // (~6500 total in CoreMark). Including JAL trains the BTB so only
        // the first execution of each unique JAL site mispredicts (~100).
        from_ex_comb_synth.btb_update                         = 1'b1;
        from_ex_comb_synth.btb_update_pc                      = mispredict_commit_q.pc;
        from_ex_comb_synth.btb_update_target                  = mispredict_commit_q.branch_target;
        from_ex_comb_synth.btb_update_taken                   = mispredict_commit_q.branch_taken;
        from_ex_comb_synth.btb_update_compressed              = mispredict_commit_q.is_compressed;
        from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;
      end

      if (mispredict_commit_q.has_checkpoint) begin
        from_ex_comb_synth.ras_misprediction       = 1'b1;
        from_ex_comb_synth.ras_restore_tos         = restored_ras_tos;
        from_ex_comb_synth.ras_restore_valid_count = restored_ras_valid_count;
        if (mispredict_commit_q.is_return) begin
          from_ex_comb_synth.ras_pop_after_restore = 1'b1;
        end else if (mispredict_commit_q.is_call) begin
          from_ex_comb_synth.ras_push_after_restore = 1'b1;
          from_ex_comb_synth.ras_push_address_after_restore = mispredict_commit_q.pc +
              (mispredict_commit_q.is_compressed ? 32'd2 : 32'd4);
        end
      end
    end else if (correct_branch_commit_pending) begin
      // Correctly-predicted branch commit: update BTB (no PC redirect).
      // Uses registered commit data to break rob_exception → BTB critical path.
      if (correct_branch_commit_q.is_branch && !correct_branch_commit_q.is_jal &&
          !correct_branch_commit_q.is_jalr) begin
        from_ex_comb_synth.btb_update = 1'b1;
        from_ex_comb_synth.btb_update_pc = correct_branch_commit_q.pc;
        from_ex_comb_synth.btb_update_target = correct_branch_commit_q.branch_target;
        from_ex_comb_synth.btb_update_taken = correct_branch_commit_q.branch_taken;
        from_ex_comb_synth.btb_update_compressed = correct_branch_commit_q.is_compressed;
        from_ex_comb_synth.btb_update_requires_pc_reg_handoff = 1'b1;
      end

    end
  end

  assign o_from_ex_comb = from_ex_comb_synth;

endmodule : ex_comb_synthesizer
