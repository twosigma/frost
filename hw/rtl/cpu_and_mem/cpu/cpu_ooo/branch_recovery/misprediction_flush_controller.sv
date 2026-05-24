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
 * Commit-time misprediction & flush controller.
 *
 * Detects mispredictions at commit (distinguishing them from branches already
 * handled by early recovery), captures the recovery payload (mispredict_commit_q
 * and the correctly-predicted-branch BTB-update payload) into registers off the
 * timing cone, and drives the prioritized flush hierarchy into the front-end and
 * OOO back-end: flush_all for traps / MRET / FENCE.I, flush_en+flush_tag for
 * partial mispredict recovery (early or commit-time), plus the checkpoint
 * restore / free / bulk-free-mask machinery.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Misprediction & Flush Controller" section, with the parent's signals
 * presented as ports and aliased back to their original names.
 */

module misprediction_flush_controller #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input logic i_rob_commit_misprediction_raw,
    input logic i_rob_commit_correct_branch_raw,
    input riscv_pkg::reorder_buffer_commit_t i_rob_commit_comb,
    input logic i_early_mispredict_active,
    input logic i_early_backend_recovery_pending,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_mispredict_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_backend_flush_tag,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_early_mispredict_checkpoint_id,
    input logic i_trap_taken_reg,
    input logic i_mret_taken_reg,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_fence_i_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_younger_than_flush,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0]
        i_checkpoint_owner_tag[riscv_pkg::NumCheckpoints],

    output cpu_ooo_pkg::mispredict_commit_capture_t o_mispredict_commit_q,
    output logic o_mispredict_recovery_pending,
    output logic [XLEN-1:0] o_fence_i_target_pc,
    output logic o_correct_branch_commit_pending,
    output cpu_ooo_pkg::correct_branch_commit_capture_t o_correct_branch_commit_q,
    output logic o_flush_pipeline,
    output logic o_dispatch_flush,
    output logic o_full_flush_side_effect_kill,
    output logic o_frontend_state_flush,
    output logic o_flush_en,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_flush_tag,
    output logic o_flush_all,
    output logic o_commit_recovery_flush_after_head,
    output logic o_flush_after_head,
    output logic o_checkpoint_restore,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_restore_id,
    output logic o_checkpoint_restore_reclaim_all,
    output logic [riscv_pkg::NumCheckpoints-1:0] o_checkpoint_flush_free_mask,
    output logic o_checkpoint_free,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_free_id
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  logic rob_commit_misprediction_raw;
  logic rob_commit_correct_branch_raw;
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb;
  logic early_mispredict_active;
  logic early_backend_recovery_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic trap_taken_reg;
  logic mret_taken_reg;
  logic flush_for_trap;
  logic flush_for_mret;
  logic fence_i_flush;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_younger_than_flush;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag[riscv_pkg::NumCheckpoints];
  assign rob_commit_misprediction_raw   = i_rob_commit_misprediction_raw;
  assign rob_commit_correct_branch_raw  = i_rob_commit_correct_branch_raw;
  assign rob_commit_comb                = i_rob_commit_comb;
  assign early_mispredict_active        = i_early_mispredict_active;
  assign early_backend_recovery_pending = i_early_backend_recovery_pending;
  assign head_tag                       = i_head_tag;
  assign early_mispredict_tag           = i_early_mispredict_tag;
  assign early_backend_flush_tag        = i_early_backend_flush_tag;
  assign early_mispredict_checkpoint_id = i_early_mispredict_checkpoint_id;
  assign trap_taken_reg                 = i_trap_taken_reg;
  assign mret_taken_reg                 = i_mret_taken_reg;
  assign flush_for_trap                 = i_flush_for_trap;
  assign flush_for_mret                 = i_flush_for_mret;
  assign fence_i_flush                  = i_fence_i_flush;
  assign checkpoint_in_use              = i_checkpoint_in_use;
  assign checkpoint_younger_than_flush  = i_checkpoint_younger_than_flush;
  always_comb checkpoint_owner_tag = i_checkpoint_owner_tag;

  // Outputs produced below (also read internally); wired to o_* at the end.
  cpu_ooo_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic mispredict_recovery_pending;
  logic [XLEN-1:0] fence_i_target_pc;
  logic flush_pipeline;
  logic dispatch_flush;
  logic full_flush_side_effect_kill;
  logic frontend_state_flush;
  logic flush_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag;
  logic flush_all;
  logic commit_recovery_flush_after_head;
  logic checkpoint_restore;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_restore_id;
  logic checkpoint_restore_reclaim_all;
  logic checkpoint_free;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id;

  // Suppress commit-time misprediction only for the SAME branch that early
  // recovery is currently handling.  The old blanket !early_mispredict_pending
  // gate would suppress mispredictions from DIFFERENT branches that happen
  // to commit on the same cycle, silently dropping their recovery.
  logic commit_is_misprediction;
  assign commit_is_misprediction = rob_commit_misprediction_raw &&
                                    !((early_mispredict_active ||
                                       early_backend_recovery_pending) &&
                                      head_tag == early_mispredict_tag);

  // Register only the mispredict recovery fields that are consumed one cycle
  // later.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) mispredict_recovery_pending <= 1'b0;
    else mispredict_recovery_pending <= commit_is_misprediction;
  end

  // Misprediction data capture (no reset - gated by commit_is_misprediction)
  always_ff @(posedge i_clk) begin
    if (commit_is_misprediction) begin
      mispredict_commit_q.tag            <= rob_commit_comb.tag;
      mispredict_commit_q.has_checkpoint <= rob_commit_comb.has_checkpoint;
      mispredict_commit_q.checkpoint_id  <= rob_commit_comb.checkpoint_id;
      mispredict_commit_q.redirect_pc    <= rob_commit_comb.redirect_pc;
      mispredict_commit_q.pc             <= rob_commit_comb.pc;
      mispredict_commit_q.branch_target  <= rob_commit_comb.branch_target;
      mispredict_commit_q.branch_taken   <= rob_commit_comb.branch_taken;
      mispredict_commit_q.is_branch      <= rob_commit_comb.is_branch;
      mispredict_commit_q.is_call        <= rob_commit_comb.is_call;
      mispredict_commit_q.is_return      <= rob_commit_comb.is_return;
      mispredict_commit_q.is_jal         <= rob_commit_comb.is_jal;
      mispredict_commit_q.is_jalr        <= rob_commit_comb.is_jalr;
      mispredict_commit_q.is_compressed  <= rob_commit_comb.is_compressed;
    end
  end

  // FENCE.I commits before its flush pulse reaches IF. Capture the precise
  // fallthrough PC so the front-end can restart from the architectural next
  // instruction instead of from speculative fetch state that was already ahead.
  always_ff @(posedge i_clk) begin
    if (rob_commit_comb.valid && rob_commit_comb.is_fence_i) begin
      fence_i_target_pc <= rob_commit_comb.pc + (rob_commit_comb.is_compressed ? 32'd2 : 32'd4);
    end
  end

  // Register correctly-predicted branch commit for BTB update + checkpoint free.
  logic correct_branch_commit_pending;
  cpu_ooo_pkg::correct_branch_commit_capture_t correct_branch_commit_q;

  // Correct branch: predicted correctly AND not early-recovered (a misprediction)
  wire commit_is_correct_branch = rob_commit_correct_branch_raw;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_commit_pending <= 1'b0;
    else correct_branch_commit_pending <= commit_is_correct_branch;
  end

  // Correct branch data capture (no reset - gated by commit_is_correct_branch)
  always_ff @(posedge i_clk) begin
    if (commit_is_correct_branch) begin
      correct_branch_commit_q.tag           <= rob_commit_comb.tag;
      correct_branch_commit_q.checkpoint_id <= rob_commit_comb.checkpoint_id;
      correct_branch_commit_q.pc            <= rob_commit_comb.pc;
      correct_branch_commit_q.branch_target <= rob_commit_comb.branch_target;
      correct_branch_commit_q.branch_taken  <= rob_commit_comb.branch_taken;
      correct_branch_commit_q.is_branch     <= rob_commit_comb.is_branch;
      correct_branch_commit_q.is_jal        <= rob_commit_comb.is_jal;
      correct_branch_commit_q.is_jalr       <= rob_commit_comb.is_jalr;
      correct_branch_commit_q.is_compressed <= rob_commit_comb.is_compressed;
    end
  end

  // Flush pipeline on the redirecting early-recovery phase, registered
  // misprediction recovery, trap, MRET, or FENCE.I. The delayed backend
  // recovery phase is a hold-only bubble, not a second frontend flush.
  always_comb begin
    flush_pipeline = early_mispredict_active || mispredict_recovery_pending ||
                     flush_for_trap ||
                     flush_for_mret || fence_i_flush;
  end

  // Dispatch needs a same-cycle kill for commit-time partial recovery.
  assign dispatch_flush = mispredict_recovery_pending;
  assign full_flush_side_effect_kill = trap_taken_reg || mret_taken_reg || fence_i_flush;

  // IF internal state cleanup can lag trap/MRET by one cycle, but keep
  // mispredict and FENCE.I cleanup on their existing timing.
  assign frontend_state_flush =
      early_mispredict_active || mispredict_recovery_pending ||
      fence_i_flush || trap_taken_reg || mret_taken_reg;

  // Tomasulo flush hierarchy.
  always_comb begin
    flush_en  = 1'b0;
    flush_tag = '0;
    flush_all = 1'b0;

    if (trap_taken_reg || mret_taken_reg) begin
      flush_all = 1'b1;
    end else if (early_backend_recovery_pending) begin
      flush_en  = 1'b1;
      flush_tag = early_backend_flush_tag;
    end else if (mispredict_recovery_pending) begin
      flush_en  = 1'b1;
      flush_tag = mispredict_commit_q.tag;
    end else if (fence_i_flush) begin
      flush_all = 1'b1;
    end
  end

  // Commit-time mispredict recovery is already a registered 1-cycle pulse.
  assign commit_recovery_flush_after_head = mispredict_recovery_pending;

  // flush_after_head: commit-time mispredict recovery retired the offending
  // branch at the ROB head in the previous cycle. The checkpoint mask uses
  // this to free ALL in-use checkpoints.
  logic flush_after_head;
  assign flush_after_head = commit_recovery_flush_after_head;

  // Checkpoint restore on misprediction (early or commit-time)
  always_comb begin
    if (flush_all) begin
      checkpoint_restore = 1'b0;
      checkpoint_restore_id = '0;
      checkpoint_restore_reclaim_all = 1'b0;
    end else if (early_mispredict_active) begin
      // Early recovery: restore checkpoint only
      checkpoint_restore = 1'b1;
      checkpoint_restore_id = early_mispredict_checkpoint_id;
      checkpoint_restore_reclaim_all = 1'b0;
    end else if (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint) begin
      // Commit-time fallback
      checkpoint_restore = 1'b1;
      checkpoint_restore_id = mispredict_commit_q.checkpoint_id;
      checkpoint_restore_reclaim_all = 1'b0;
    end else begin
      checkpoint_restore = 1'b0;
      checkpoint_restore_id = '0;
      checkpoint_restore_reclaim_all = 1'b0;
    end
  end

  // Bulk flush free mask: register on flush_en, apply one cycle later.
  // When flush_after_head, free ALL in-use checkpoints (the age comparison
  // wraps and misses everything).  Otherwise, free only younger checkpoints.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) checkpoint_flush_free_mask_q <= '0;
    else if (flush_en)
      checkpoint_flush_free_mask_q <= flush_after_head ? checkpoint_in_use
                                                       : checkpoint_younger_than_flush;
    else checkpoint_flush_free_mask_q <= '0;
  end
  assign checkpoint_flush_free_mask = checkpoint_flush_free_mask_q;

  // Checkpoint free: early recovery or guarded branch commit fallback.
  logic correct_branch_commit_checkpoint_live;
  always_comb begin
    correct_branch_commit_checkpoint_live = 1'b0;
    if (correct_branch_commit_pending) begin
      correct_branch_commit_checkpoint_live =
          checkpoint_in_use[correct_branch_commit_q.checkpoint_id] &&
          (checkpoint_owner_tag[correct_branch_commit_q.checkpoint_id] ==
           correct_branch_commit_q.tag);
    end
  end

  always_comb begin
    checkpoint_free    = 1'b0;
    checkpoint_free_id = '0;

    if (flush_all) begin
      checkpoint_free    = 1'b0;
      checkpoint_free_id = '0;
    end else if (early_backend_recovery_pending) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = early_mispredict_checkpoint_id;
    end else if (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = mispredict_commit_q.checkpoint_id;
    end else if (correct_branch_commit_checkpoint_live) begin
      checkpoint_free    = 1'b1;
      checkpoint_free_id = correct_branch_commit_q.checkpoint_id;
    end
  end

  // --- Output wiring.
  assign o_mispredict_commit_q              = mispredict_commit_q;
  assign o_mispredict_recovery_pending      = mispredict_recovery_pending;
  assign o_fence_i_target_pc                = fence_i_target_pc;
  assign o_correct_branch_commit_pending    = correct_branch_commit_pending;
  assign o_correct_branch_commit_q          = correct_branch_commit_q;
  assign o_flush_pipeline                   = flush_pipeline;
  assign o_dispatch_flush                   = dispatch_flush;
  assign o_full_flush_side_effect_kill      = full_flush_side_effect_kill;
  assign o_frontend_state_flush             = frontend_state_flush;
  assign o_flush_en                         = flush_en;
  assign o_flush_tag                        = flush_tag;
  assign o_flush_all                        = flush_all;
  assign o_commit_recovery_flush_after_head = commit_recovery_flush_after_head;
  assign o_flush_after_head                 = flush_after_head;
  assign o_checkpoint_restore               = checkpoint_restore;
  assign o_checkpoint_restore_id            = checkpoint_restore_id;
  assign o_checkpoint_restore_reclaim_all   = checkpoint_restore_reclaim_all;
  assign o_checkpoint_flush_free_mask       = checkpoint_flush_free_mask;
  assign o_checkpoint_free                  = checkpoint_free;
  assign o_checkpoint_free_id               = checkpoint_free_id;

endmodule : misprediction_flush_controller
