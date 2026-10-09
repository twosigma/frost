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
    input logic [                 XLEN-1:0] i_restored_ras_top,

    // Commit-time misprediction recovery path.
    input logic                                  i_mispredict_recovery_pending,
    input riscv_pkg::mispredict_commit_capture_t i_mispredict_commit_q,

    // Correctly-predicted branch commit path (BTB update only).
    input logic                                      i_correct_branch_commit_pending,
    input riscv_pkg::correct_branch_commit_capture_t i_correct_branch_commit_q,
    // Held slot-2 training request, unmasked by early recovery. All other
    // sources have priority; the producer clears it when served.
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
  logic [XLEN-1:0] restored_ras_top;
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
  assign restored_ras_top               = i_restored_ras_top;
  assign mispredict_recovery_pending    = i_mispredict_recovery_pending;
  assign mispredict_commit_q            = i_mispredict_commit_q;
  assign correct_branch_commit_pending  = i_correct_branch_commit_pending;
  assign correct_branch_commit_q        = i_correct_branch_commit_q;
  logic correct_branch_commit_pending_2_raw;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q_2;
  assign correct_branch_commit_pending_2_raw = i_correct_branch_commit_pending_2_raw;
  assign correct_branch_commit_q_2           = i_correct_branch_commit_q_2;

  // Cap fanout of the BTB transaction muxes.
  (* max_fanout = 64 *)riscv_pkg::from_ex_comb_t late_from_ex_comb;
  (* max_fanout = 64 *)riscv_pkg::from_ex_comb_t from_ex_comb_synth;

  // Build the late BTB candidate independently of early_mispredict_active.
  always_comb begin
    late_from_ex_comb = '0;

    if (mispredict_recovery_pending) begin
      // Commit-time fallback misprediction recovery.
      late_from_ex_comb.branch_taken          = 1'b1;
      late_from_ex_comb.branch_target_address = mispredict_commit_q.redirect_pc;

      if (mispredict_commit_q.is_branch &&
          (!mispredict_commit_q.is_jalr || mispredict_commit_q.is_return)) begin
        // Train conditional branches, JAL, and returns, including coroutine
        // swaps. JAL training allows a later BTB hit. A return hit uses the RAS
        // or the stored target when the stack is empty. Other JALRs do not
        // enter the BTB; call and return bits select the stack action.
        late_from_ex_comb.btb_update            = 1'b1;
        late_from_ex_comb.btb_update_pc         = mispredict_commit_q.pc;
        late_from_ex_comb.btb_update_target     = mispredict_commit_q.branch_target;
        late_from_ex_comb.btb_update_taken      = mispredict_commit_q.branch_taken;
        late_from_ex_comb.btb_update_compressed = mispredict_commit_q.is_compressed;
        late_from_ex_comb.btb_update_call       = mispredict_commit_q.is_call;
        late_from_ex_comb.btb_update_return     = mispredict_commit_q.is_return;
      end

      if (mispredict_commit_q.has_checkpoint) begin
        late_from_ex_comb.ras_misprediction       = 1'b1;
        late_from_ex_comb.ras_restore_tos         = restored_ras_tos;
        late_from_ex_comb.ras_restore_valid_count = restored_ras_valid_count;
        late_from_ex_comb.ras_restore_top         = restored_ras_top;
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
      // Train correctly predicted conditional branches without a PC redirect.
      if (correct_branch_commit_q.is_branch && !correct_branch_commit_q.is_jal &&
          !correct_branch_commit_q.is_jalr) begin
        late_from_ex_comb.btb_update = 1'b1;
        late_from_ex_comb.btb_update_pc = correct_branch_commit_q.pc;
        late_from_ex_comb.btb_update_target = correct_branch_commit_q.branch_target;
        late_from_ex_comb.btb_update_taken = correct_branch_commit_q.branch_taken;
        late_from_ex_comb.btb_update_compressed = correct_branch_commit_q.is_compressed;
      end

    end else if (correct_branch_commit_pending_2_raw) begin
      // The slot-2 request stays visible during early recovery. The producer
      // holds it until it is served, replaced by a newer capture, or dropped
      // by a full flush or reset.
      if (correct_branch_commit_q_2.is_branch && !correct_branch_commit_q_2.is_jal &&
          !correct_branch_commit_q_2.is_jalr) begin
        late_from_ex_comb.btb_update = 1'b1;
        late_from_ex_comb.btb_update_pc = correct_branch_commit_q_2.pc;
        late_from_ex_comb.btb_update_target = correct_branch_commit_q_2.branch_target;
        late_from_ex_comb.btb_update_taken = correct_branch_commit_q_2.branch_taken;
        late_from_ex_comb.btb_update_compressed = correct_branch_commit_q_2.is_compressed;
      end
    end
  end

  // Final mux: early recovery overrides the complete lower-priority
  // transaction.
  always_comb begin
    from_ex_comb_synth = late_from_ex_comb;

    if (early_mispredict_active) begin
      from_ex_comb_synth                         = '0;
      from_ex_comb_synth.branch_taken            = 1'b1;
      from_ex_comb_synth.branch_target_address   = early_mispredict_redirect_pc;

      // Early recovery only handles checkpointed conditional branches, so the
      // BTB update and RAS restore are unconditional on this path.
      from_ex_comb_synth.btb_update              = 1'b1;
      from_ex_comb_synth.btb_update_pc           = early_mispredict_pc;
      from_ex_comb_synth.btb_update_target       = early_mispredict_branch_target;
      from_ex_comb_synth.btb_update_taken        = early_mispredict_branch_taken;
      from_ex_comb_synth.btb_update_compressed   = early_mispredict_is_compressed;

      from_ex_comb_synth.ras_misprediction       = 1'b1;
      from_ex_comb_synth.ras_restore_tos         = restored_ras_tos;
      from_ex_comb_synth.ras_restore_valid_count = restored_ras_valid_count;
      from_ex_comb_synth.ras_restore_top         = restored_ras_top;
    end

    // Compute redirect fields directly for timing. Early recovery has priority.
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
  // The selected bus must equal the late transaction without early recovery;
  // during early recovery, its BTB fields must match the early payload.
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
