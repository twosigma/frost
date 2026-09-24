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
 * Builds the from_ex_comb_t that IF uses for fetch redirects, BTB updates, and
 * RAS restores. In the out-of-order core these come from branch resolution and
 * ROB commit rather than an EX stage. Sources, in priority order: early
 * misprediction recovery, commit-time misprediction recovery, and correctly
 * predicted branch commits (slot 1, then slot 2).
 *
 * The lower-priority transaction is built without the early-recovery
 * qualifier, and a final mux gives early recovery priority. The late PC and
 * outcome outputs (o_btb_late_update_*) let the BTB compute both counter
 * read-modify-write candidates in parallel.
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
    input logic                                  i_mispredict_recovery_pending,
    input riscv_pkg::mispredict_commit_capture_t i_mispredict_commit_q,

    // Correctly-predicted branch commit path (BTB update only).
    input logic                                      i_correct_branch_commit_pending,
    input riscv_pkg::correct_branch_commit_capture_t i_correct_branch_commit_q,
    // Held slot-2 correct-branch training request, raw (not masked by early
    // recovery). Every other source wins over it, in late_from_ex_comb or the
    // final early mux, and the producer decides on its own when it has been
    // served and can be cleared.
    input logic                                      i_correct_branch_commit_pending_2_raw,
    input riscv_pkg::correct_branch_commit_capture_t i_correct_branch_commit_q_2,

    // Lower-priority BTB counter-RMW candidate.  These outputs never depend on
    // i_early_mispredict_active; the selected bus below remains the sole source
    // of actual BTB writes.
    output logic [XLEN-1:0] o_btb_late_update_pc,
    output logic            o_btb_late_update_taken,

    output riscv_pkg::from_ex_comb_t o_from_ex_comb
);

  // --- Port aliases.
  logic early_mispredict_active;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;
  logic early_mispredict_is_compressed;
  logic [riscv_pkg::RasPtrBits-1:0] restored_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] restored_ras_valid_count;
  logic mispredict_recovery_pending;
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic correct_branch_commit_pending;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q;
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
  logic correct_branch_commit_pending_2_raw;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q_2;
  assign correct_branch_commit_pending_2_raw = i_correct_branch_commit_pending_2_raw;
  assign correct_branch_commit_q_2           = i_correct_branch_commit_q_2;

  // TIMING: the selected transaction drives the write and read-modify-write
  // read pins of every BTB RAM replica. The fanout cap makes synthesis
  // replicate the one-LUT-deep priority mux per consumer region; it takes
  // effect only on the high-fanout index and write-enable bits.
  (* max_fanout = 64 *)riscv_pkg::from_ex_comb_t late_from_ex_comb;
  (* max_fanout = 64 *)riscv_pkg::from_ex_comb_t from_ex_comb_synth;

  // Compute all lower-priority effects without early_mispredict_active, so
  // the BTB's late read-modify-write address (o_btb_late_update_pc) cannot
  // depend structurally on the early-recovery qualifier.
  always_comb begin
    late_from_ex_comb = '0;

    if (mispredict_recovery_pending) begin
      // Commit-time fallback misprediction recovery.
      late_from_ex_comb.branch_taken          = 1'b1;
      late_from_ex_comb.branch_target_address = mispredict_commit_q.redirect_pc;

      if (mispredict_commit_q.is_branch && !mispredict_commit_q.is_jalr) begin
        // BTB update for conditional branches and JAL (JALR never enters the
        // BTB). Training JAL lets a JAL that missed the BTB hit on its next
        // execution.
        late_from_ex_comb.btb_update                         = 1'b1;
        late_from_ex_comb.btb_update_pc                      = mispredict_commit_q.pc;
        late_from_ex_comb.btb_update_target                  = mispredict_commit_q.branch_target;
        late_from_ex_comb.btb_update_taken                   = mispredict_commit_q.branch_taken;
        late_from_ex_comb.btb_update_compressed              = mispredict_commit_q.is_compressed;
        late_from_ex_comb.btb_update_requires_pc_reg_handoff = 1'b1;
      end

      if (mispredict_commit_q.has_checkpoint) begin
        late_from_ex_comb.ras_misprediction       = 1'b1;
        late_from_ex_comb.ras_restore_tos         = restored_ras_tos;
        late_from_ex_comb.ras_restore_valid_count = restored_ras_valid_count;
        if (mispredict_commit_q.is_return && mispredict_commit_q.is_call) begin
          // Coroutine: the 2'b11 swap encoding, see riscv_pkg. IF did
          // pop-then-push, so recovery replays both halves. A plain push would
          // leave the RAS one entry deeper than the real call stack.
          late_from_ex_comb.ras_pop_after_restore = 1'b1;
          late_from_ex_comb.ras_push_after_restore = 1'b1;
          late_from_ex_comb.ras_push_address_after_restore = mispredict_commit_q.pc +
              (mispredict_commit_q.is_compressed ? 64'd2 : 64'd4);
        end else if (mispredict_commit_q.is_return) begin
          late_from_ex_comb.ras_pop_after_restore = 1'b1;
        end else if (mispredict_commit_q.is_call) begin
          late_from_ex_comb.ras_push_after_restore = 1'b1;
          late_from_ex_comb.ras_push_address_after_restore = mispredict_commit_q.pc +
              (mispredict_commit_q.is_compressed ? 64'd2 : 64'd4);
        end
      end
    end else if (correct_branch_commit_pending) begin
      // Correctly-predicted branch commit: update BTB (no PC redirect).
      // Uses registered commit data to break rob_exception → BTB critical path.
      if (correct_branch_commit_q.is_branch && !correct_branch_commit_q.is_jal &&
          !correct_branch_commit_q.is_jalr) begin
        late_from_ex_comb.btb_update = 1'b1;
        late_from_ex_comb.btb_update_pc = correct_branch_commit_q.pc;
        late_from_ex_comb.btb_update_target = correct_branch_commit_q.branch_target;
        late_from_ex_comb.btb_update_taken = correct_branch_commit_q.branch_taken;
        late_from_ex_comb.btb_update_compressed = correct_branch_commit_q.is_compressed;
        late_from_ex_comb.btb_update_requires_pc_reg_handoff = 1'b1;
      end

    end else if (correct_branch_commit_pending_2_raw) begin
      // Slot-2 correctly-predicted branch retire. Reading the raw held
      // capture keeps this candidate visible during early recovery. The
      // producer clears it only on a real service cycle.
      if (correct_branch_commit_q_2.is_branch && !correct_branch_commit_q_2.is_jal &&
          !correct_branch_commit_q_2.is_jalr) begin
        late_from_ex_comb.btb_update = 1'b1;
        late_from_ex_comb.btb_update_pc = correct_branch_commit_q_2.pc;
        late_from_ex_comb.btb_update_target = correct_branch_commit_q_2.branch_target;
        late_from_ex_comb.btb_update_taken = correct_branch_commit_q_2.branch_taken;
        late_from_ex_comb.btb_update_compressed = correct_branch_commit_q_2.is_compressed;
        late_from_ex_comb.btb_update_requires_pc_reg_handoff = 1'b1;
      end
    end
  end

  // Final mux: early recovery overrides the complete lower-priority
  // transaction.
  always_comb begin
    from_ex_comb_synth = late_from_ex_comb;

    if (early_mispredict_active) begin
      // Early misprediction recovery: redirect PC and update BTB
      from_ex_comb_synth                                    = '0;
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
    end

    // These two redirect fields have a much smaller exact priority function
    // than the complete transaction. State it directly so commit recovery
    // does not traverse both whole-struct mux layers on its way to the IF PC
    // controller. Early recovery retains priority when both sources are set.
    from_ex_comb_synth.branch_taken = early_mispredict_active || mispredict_recovery_pending;
    if (early_mispredict_active) begin
      from_ex_comb_synth.branch_target_address = early_mispredict_redirect_pc;
    end else if (mispredict_recovery_pending) begin
      from_ex_comb_synth.branch_target_address = mispredict_commit_q.redirect_pc;
    end else begin
      from_ex_comb_synth.branch_target_address = '0;
    end
  end

  assign o_btb_late_update_pc    = late_from_ex_comb.btb_update_pc;
  assign o_btb_late_update_taken = late_from_ex_comb.btb_update_taken;
  assign o_from_ex_comb = from_ex_comb_synth;

`ifndef SYNTHESIS
  // Check the selected bus at the producer: with no early recovery it must
  // equal the late transaction, and during early recovery its BTB fields must
  // follow the early sideband. These are asserts rather than assumptions, so a
  // formal proof that integrates this block is not handed the contract.
  always_comb begin
    if (!early_mispredict_active && !$isunknown({from_ex_comb_synth, late_from_ex_comb})) begin
      p_non_early_transaction_is_late : assert (from_ex_comb_synth == late_from_ex_comb);
    end

    if (early_mispredict_active && !$isunknown(
            {from_ex_comb_synth.btb_update,
                     from_ex_comb_synth.btb_update_pc,
                     from_ex_comb_synth.btb_update_taken,
                     early_mispredict_pc,
                     early_mispredict_branch_taken}
        )) begin
      p_early_btb_update_selected : assert (from_ex_comb_synth.btb_update);
      p_early_btb_pc_selected : assert (from_ex_comb_synth.btb_update_pc == early_mispredict_pc);
      p_early_btb_outcome_selected :
      assert (from_ex_comb_synth.btb_update_taken == early_mispredict_branch_taken);
    end
  end
`endif

endmodule : ex_comb_synthesizer
