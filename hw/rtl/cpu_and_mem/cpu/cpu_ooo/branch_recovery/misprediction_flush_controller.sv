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
 * Commit-time misprediction and flush controller.
 *
 * Capture commit recovery and correct-branch BTB training. Full flushes
 * (trap, xRET, FENCE-class recovery) take priority over early or commit-time
 * partial recovery. Drive checkpoint restore, free, and bulk free masks.
 * Slot-2 training has a held capture and an independent checkpoint free.
 *
 * Flush and restore broadcasts use registered state; raw trap, xRET, and
 * FENCE-class events feed only register inputs.
 */

(* keep_hierarchy = "yes" *)
module misprediction_flush_controller #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input logic i_rob_commit_misprediction_raw,
    input logic i_rob_commit_correct_branch_raw,
    input riscv_pkg::reorder_buffer_commit_t i_rob_commit_comb,
    // Slot-2 mirror: correctly-predicted branch retiring at head+1.
    input logic i_rob_commit_correct_branch_2_raw,
    input riscv_pkg::reorder_buffer_commit_t i_rob_commit_comb_2,
    input logic i_early_mispredict_active,
    input logic i_early_mispredict_pending,
    input logic i_early_backend_recovery_pending,
    // Next-cycle value of i_early_backend_recovery_pending.
    input logic i_early_backend_recovery_pending_next,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_mispredict_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_backend_flush_tag,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_early_mispredict_checkpoint_id,
    input logic i_trap_taken_reg,
    input logic i_mret_taken_reg,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_fence_i_flush,
    input logic i_active_fence_i_flush,
    // The trap/xRET take strobes and the ROB serializer's FENCE-class
    // retirement event, one cycle before their registered full-flush pulses.
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic i_fence_class_flush_event,
    input logic [XLEN-1:0] i_fence_i_target_pc,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_younger_than_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0]
        i_checkpoint_owner_tag,

    output riscv_pkg::mispredict_commit_capture_t o_mispredict_commit_q,
    output logic o_mispredict_recovery_pending,
    output logic [XLEN-1:0] o_fence_i_target_pc,
    output logic o_correct_branch_commit_pending,
    output riscv_pkg::correct_branch_commit_capture_t o_correct_branch_commit_q,
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
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_free_id,
    // Slot-2 has an independent checkpoint-free channel and a held BTB
    // training request. Export the raw pending bit for the late BTB candidate;
    // correct_branch_2_served clears it when no higher-priority source wins.
    output logic o_correct_branch_commit_pending_2_raw,
    output riscv_pkg::correct_branch_commit_capture_t o_correct_branch_commit_q_2,
    output logic o_checkpoint_free_2,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_free_id_2
);

  // Port aliases.
  logic rob_commit_misprediction_raw;
  logic rob_commit_correct_branch_raw;
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb;
  logic early_mispredict_active;
  logic early_mispredict_pending;
  logic early_backend_recovery_pending;
  logic active_fence_i_flush;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic trap_taken_reg;
  logic mret_taken_reg;
  logic flush_for_trap;
  logic flush_for_mret;
  logic fence_i_flush;
  logic [XLEN-1:0] fence_i_target_pc_pre;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_younger_than_flush;
  logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag;
  assign rob_commit_misprediction_raw  = i_rob_commit_misprediction_raw;
  assign rob_commit_correct_branch_raw = i_rob_commit_correct_branch_raw;
  assign rob_commit_comb               = i_rob_commit_comb;
  logic rob_commit_correct_branch_2_raw;
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb_2;
  assign rob_commit_correct_branch_2_raw = i_rob_commit_correct_branch_2_raw;
  assign rob_commit_comb_2               = i_rob_commit_comb_2;
  assign early_mispredict_active         = i_early_mispredict_active;
  assign early_mispredict_pending        = i_early_mispredict_pending;
  assign active_fence_i_flush            = i_active_fence_i_flush;
  assign early_backend_recovery_pending  = i_early_backend_recovery_pending;
  assign head_tag                        = i_head_tag;
  assign early_mispredict_tag            = i_early_mispredict_tag;
  assign early_backend_flush_tag         = i_early_backend_flush_tag;
  assign early_mispredict_checkpoint_id  = i_early_mispredict_checkpoint_id;
  assign trap_taken_reg                  = i_trap_taken_reg;
  assign mret_taken_reg                  = i_mret_taken_reg;
  assign flush_for_trap                  = i_flush_for_trap;
  assign flush_for_mret                  = i_flush_for_mret;
  assign fence_i_flush                   = i_fence_i_flush;
  assign fence_i_target_pc_pre           = i_fence_i_target_pc;
  assign checkpoint_in_use               = i_checkpoint_in_use;
  assign checkpoint_younger_than_flush   = i_checkpoint_younger_than_flush;
  assign checkpoint_owner_tag            = i_checkpoint_owner_tag;

  // Recovery payloads and broadcasts. Cap fanout for replication.
  (* max_fanout = 64 *) riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  (* max_fanout = 24 *) logic mispredict_recovery_pending;
  logic [XLEN-1:0] fence_i_target_pc;
  (* max_fanout = 64 *) logic flush_pipeline;
  logic dispatch_flush;
  (* max_fanout = 64 *) logic full_flush_side_effect_kill;
  (* max_fanout = 64 *) logic frontend_state_flush;
  (* max_fanout = 64 *) logic flush_en;
  (* max_fanout = 64 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag;
  (* max_fanout = 64 *) logic flush_all;
  logic commit_recovery_flush_after_head;
  logic checkpoint_restore;
  (* max_fanout = 48 *) logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_restore_id;
  logic checkpoint_restore_reclaim_all;
  logic checkpoint_free;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id;

  // Suppress a commit-time misprediction only for the branch early recovery
  // is already handling. A blanket early-recovery gate would also drop the
  // recovery of a different mispredicted branch that commits in the same
  // cycle.
  logic commit_is_misprediction;
  assign commit_is_misprediction = rob_commit_misprediction_raw &&
                                    !((early_mispredict_active ||
                                       early_backend_recovery_pending) &&
                                      head_tag == early_mispredict_tag);

  // Commit-time recovery is a one-cycle pulse the cycle after the
  // mispredicted branch retires. Reset or a full flush clears it.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) mispredict_recovery_pending <= 1'b0;
    else mispredict_recovery_pending <= commit_is_misprediction;
  end

  // Refresh the payload every edge; it is consumed only while
  // mispredict_recovery_pending is high.
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_d;
  always_comb begin
    mispredict_commit_d.tag            = rob_commit_comb.tag;
    mispredict_commit_d.has_checkpoint = rob_commit_comb.has_checkpoint;
    mispredict_commit_d.checkpoint_id  = rob_commit_comb.checkpoint_id;
    mispredict_commit_d.redirect_pc    = rob_commit_comb.redirect_pc;
    mispredict_commit_d.pc             = rob_commit_comb.pc;
    mispredict_commit_d.branch_target  = rob_commit_comb.branch_target;
    mispredict_commit_d.branch_taken   = rob_commit_comb.branch_taken;
    mispredict_commit_d.is_branch      = rob_commit_comb.is_branch;
    mispredict_commit_d.is_call        = rob_commit_comb.is_call;
    mispredict_commit_d.is_return      = rob_commit_comb.is_return;
    mispredict_commit_d.is_jal         = rob_commit_comb.is_jal;
    mispredict_commit_d.is_jalr        = rob_commit_comb.is_jalr;
    mispredict_commit_d.is_compressed  = rob_commit_comb.is_compressed;
  end
  always_ff @(posedge i_clk) mispredict_commit_q <= mispredict_commit_d;

`ifdef MISPREDICT_CAPTURE_LOCAL_PROOF
  // While recovery is pending, the payload must equal a copy captured
  // only on a mispredicted commit.
  riscv_pkg::mispredict_commit_capture_t f_gated_capture;
  logic f_capture_initialized = 1'b0;
  always @(posedge i_clk) begin
    f_capture_initialized <= 1'b1;
    if (commit_is_misprediction) f_gated_capture <= mispredict_commit_d;
    if (f_capture_initialized && mispredict_recovery_pending)
      assert (mispredict_commit_q == f_gated_capture);
  end
`endif

  // Capture the architectural fallthrough PC at retirement for the FENCE-class
  // refetch. FENCE.I and SFENCE.VMA flush one cycle after retiring; a
  // translation CSR writes csr_file from the registered commit bus and flushes
  // two cycles after. Every CSR commit captures it, which is harmless when no
  // recovery follows.
  always_ff @(posedge i_clk) begin
    if (rob_commit_comb.valid && (rob_commit_comb.is_fence_i || rob_commit_comb.is_csr)) begin
      fence_i_target_pc <= fence_i_target_pc_pre;
    end
  end

  // Register correct-branch commit for BTB training and checkpoint free.
  (* max_fanout = 48 *) logic correct_branch_commit_pending;
  // Keep the unreset payload on clock enables, for timing.
  (* max_fanout = 64, extract_reset = "no" *)
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q;

  // The ROB qualifies this strobe with a checkpointed head that neither
  // mispredicted nor recovered early. Keep the qualified capture enable.
  (* keep = "true" *) wire commit_is_correct_branch = rob_commit_correct_branch_raw;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_commit_pending <= 1'b0;
    else correct_branch_commit_pending <= commit_is_correct_branch;
  end

  // Correct branch data capture (no reset; gated by commit_is_correct_branch)
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

  // Slot-2 correct-branch capture.
  // Hold training until served, superseded by a newer slot-2 capture, or
  // cleared by a full flush. Checkpoint free may fire only in the first held
  // cycle and requires in_use plus a matching tag. A held record can outlive
  // its checkpoint and ROB tag; repeating the free could release a new
  // branch's checkpoint.
  (* max_fanout = 48 *) logic correct_branch_commit_pending_2;
  (* max_fanout = 64, extract_reset = "no" *)
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q_2;
  (* keep = "true" *) wire commit_is_correct_branch_2 = rob_commit_correct_branch_2_raw;
  logic correct_branch_2_served;
  // Set after a held capture's first cycle, the only cycle its free may pulse.
  logic correct_branch_2_free_done_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_commit_pending_2 <= 1'b0;
    else if (commit_is_correct_branch_2) correct_branch_commit_pending_2 <= 1'b1;
    else if (correct_branch_2_served) correct_branch_commit_pending_2 <= 1'b0;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_2_free_done_q <= 1'b0;
    else if (commit_is_correct_branch_2) correct_branch_2_free_done_q <= 1'b0;
    else if (correct_branch_commit_pending_2) correct_branch_2_free_done_q <= 1'b1;
  end

  always_ff @(posedge i_clk) begin
    if (commit_is_correct_branch_2) begin
      correct_branch_commit_q_2.tag           <= rob_commit_comb_2.tag;
      correct_branch_commit_q_2.checkpoint_id <= rob_commit_comb_2.checkpoint_id;
      correct_branch_commit_q_2.pc            <= rob_commit_comb_2.pc;
      correct_branch_commit_q_2.branch_target <= rob_commit_comb_2.branch_target;
      correct_branch_commit_q_2.branch_taken  <= rob_commit_comb_2.branch_taken;
      correct_branch_commit_q_2.is_branch     <= rob_commit_comb_2.is_branch;
      correct_branch_commit_q_2.is_jal        <= rob_commit_comb_2.is_jal;
      correct_branch_commit_q_2.is_jalr       <= rob_commit_comb_2.is_jalr;
      correct_branch_commit_q_2.is_compressed <= rob_commit_comb_2.is_compressed;
    end
  end

  // Served when every higher-priority synthesizer arm is quiet this cycle.
  assign correct_branch_2_served = correct_branch_commit_pending_2 &&
      !early_mispredict_active && !mispredict_recovery_pending &&
      !correct_branch_commit_pending;

  // One-shot slot-2 checkpoint free (see the capture comment above).
  logic correct_branch_commit_checkpoint_live_2;
  always_comb begin
    correct_branch_commit_checkpoint_live_2 = 1'b0;
    if (correct_branch_commit_pending_2 && !correct_branch_2_free_done_q) begin
      correct_branch_commit_checkpoint_live_2 =
          checkpoint_in_use[correct_branch_commit_q_2.checkpoint_id] &&
          (checkpoint_owner_tag[correct_branch_commit_q_2.checkpoint_id] ==
           correct_branch_commit_q_2.tag);
    end
  end
  assign o_checkpoint_free_2    = !flush_all && correct_branch_commit_checkpoint_live_2;
  assign o_checkpoint_free_id_2 = correct_branch_commit_q_2.checkpoint_id;

  // ---------------------------------------------------------------------
  // Broadcast decode uses registered full-flush and recovery state. Raw
  // trap, xRET, and FENCE-class events feed only register inputs.
  // Register the OR of full-flush events so its driver can replicate.
  // ---------------------------------------------------------------------
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 64 *)
  logic full_flush_side_effect_kill_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) full_flush_side_effect_kill_q <= 1'b0;
    else full_flush_side_effect_kill_q <= i_trap_taken || i_mret_taken || i_fence_class_flush_event;
  end
  assign full_flush_side_effect_kill = full_flush_side_effect_kill_q;
  assign flush_all                   = full_flush_side_effect_kill_q;

  // Same-edge copy of the full-flush register for restore fanout. Both
  // registers sample the same data and reset, so they agree after one edge.
  (* dont_touch = "true" *) logic restore_flush_all_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) restore_flush_all_q <= 1'b0;
    else restore_flush_all_q <= i_trap_taken || i_mret_taken || i_fence_class_flush_event;
  end

  // Same-edge full-flush copy for frontend fanout.
  (* dont_touch = "true" *) logic frontend_flush_all_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) frontend_flush_all_q <= 1'b0;
    else frontend_flush_all_q <= i_trap_taken || i_mret_taken || i_fence_class_flush_event;
  end

  // early_mispredict_active without its trap/MRET terms: identical whenever
  // flush_all is low, and every use below is dominated by flush_all.
  logic early_redirect_fast;
  assign early_redirect_fast = early_mispredict_pending && !mispredict_recovery_pending &&
                               !active_fence_i_flush;

  // Flush the pipeline on the redirecting early-recovery phase, registered
  // misprediction recovery, trap, xRET, or FENCE-class recovery. The delayed
  // backend recovery phase is not a second front-end flush.
  assign flush_pipeline = frontend_flush_all_q || mispredict_recovery_pending ||
                          early_redirect_fast;

  // IF's internal-state flush is flush_pipeline itself. It follows a trap or
  // xRET take by one cycle, which IF's internal-state cleanup tolerates.
  assign frontend_state_flush = flush_pipeline;

  // Dispatch needs a same-cycle kill for commit-time partial recovery.
  assign dispatch_flush = mispredict_recovery_pending;
  // Full flush takes priority over partial recovery. FENCE.I must discard
  // all potentially stale instructions; translation-CSR recovery must also
  // discard loads translated under the old satp. The PC mux gives the fence
  // target priority, and full flush supersedes pending partial recovery.
  // Register flush_en from the pending flags' next states so it equals
  // !flush_all && (early_backend_recovery_pending || mispredict_recovery_pending).
  always_ff @(posedge i_clk) begin
    if (i_rst) flush_en <= 1'b0;
    else
      flush_en <= !(i_trap_taken || i_mret_taken || i_fence_class_flush_event) &&
          (i_early_backend_recovery_pending_next || (!flush_all && commit_is_misprediction));
  end
  // Consumers use the tag only for partial flushes, and full flush wins in
  // every consumer, including the LQ early-recovery input. The tag therefore
  // does not need a flush_all gate.
  always_comb begin
    flush_tag = '0;
    if (early_backend_recovery_pending) flush_tag = early_backend_flush_tag;
    else if (mispredict_recovery_pending) flush_tag = mispredict_commit_q.tag;
  end
  // Register the selected tag from next states for fanout. Early backend
  // recovery captures early_mispredict_tag on its launch edge; commit recovery
  // captures mispredict_commit_d on its launch edge.
  (* max_fanout = 32 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag_q;
  always_ff @(posedge i_clk) begin
    if (i_early_backend_recovery_pending_next) flush_tag_q <= i_early_mispredict_tag;
    else if (!(i_rst || flush_all) && commit_is_misprediction)
      flush_tag_q <= mispredict_commit_d.tag;
    else flush_tag_q <= '0;
  end

  // Commit-time mispredict recovery is already a registered 1-cycle pulse.
  assign commit_recovery_flush_after_head = mispredict_recovery_pending;

  // flush_after_head means commit-time mispredict recovery retired the
  // offending branch at the ROB head in the previous cycle. The checkpoint mask
  // uses this to free all in-use checkpoints.
  logic flush_after_head;
  assign flush_after_head = commit_recovery_flush_after_head;

  // Restore early or at commit when a checkpoint exists. The ID is observed
  // only during checkpoint restore or RAS restore. Early recovery excludes
  // commit recovery, so select the early ID whenever commit recovery is idle;
  // no early_mispredict_pending gate is needed on the address.
  assign checkpoint_restore = !restore_flush_all_q &&
      (early_redirect_fast ||
       (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint));
  assign checkpoint_restore_id =
      restore_flush_all_q ? '0 :
      !mispredict_recovery_pending ? early_mispredict_checkpoint_id :
      mispredict_commit_q.checkpoint_id;
  assign checkpoint_restore_reclaim_all = 1'b0;

  // Bulk flush free mask: register on flush_en, apply one cycle later. When
  // flush_after_head, free all in-use checkpoints, because the age comparison
  // wraps and misses every one of them. Otherwise free only younger
  // checkpoints.
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
  assign o_mispredict_commit_q                 = mispredict_commit_q;
  assign o_mispredict_recovery_pending         = mispredict_recovery_pending;
  assign o_fence_i_target_pc                   = fence_i_target_pc;
  assign o_correct_branch_commit_pending       = correct_branch_commit_pending;
  assign o_correct_branch_commit_pending_2_raw = correct_branch_commit_pending_2;
  assign o_correct_branch_commit_q_2           = correct_branch_commit_q_2;
  assign o_correct_branch_commit_q             = correct_branch_commit_q;
  assign o_flush_pipeline                      = flush_pipeline;
  assign o_dispatch_flush                      = dispatch_flush;
  assign o_full_flush_side_effect_kill         = full_flush_side_effect_kill;
  assign o_frontend_state_flush                = frontend_state_flush;
  assign o_flush_en                            = flush_en;
  assign o_flush_tag                           = flush_tag_q;
  assign o_flush_all                           = flush_all;

`ifndef SYNTHESIS
  // Reference decode: plain priority chains built from the individual
  // registered trap, xRET, and FENCE-class pulses and early_mispredict_active.
  logic ref_flush_all, ref_flush_en, ref_flush_pipeline, ref_frontend_state_flush;
  logic ref_checkpoint_restore;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] ref_flush_tag;
  logic [riscv_pkg::CheckpointIdWidth-1:0] ref_checkpoint_restore_id;
  always_comb begin
    ref_flush_all = trap_taken_reg || mret_taken_reg || fence_i_flush;
    ref_flush_en  = 1'b0;
    ref_flush_tag = '0;
    if (ref_flush_all) begin
    end else if (early_backend_recovery_pending) begin
      ref_flush_en  = 1'b1;
      ref_flush_tag = early_backend_flush_tag;
    end else if (mispredict_recovery_pending) begin
      ref_flush_en  = 1'b1;
      ref_flush_tag = mispredict_commit_q.tag;
    end
    ref_flush_pipeline = early_mispredict_active || mispredict_recovery_pending ||
        flush_for_trap || flush_for_mret || fence_i_flush;
    ref_frontend_state_flush = early_mispredict_active || mispredict_recovery_pending ||
        fence_i_flush || trap_taken_reg || mret_taken_reg;
    ref_checkpoint_restore = 1'b0;
    ref_checkpoint_restore_id = '0;
    if (ref_flush_all) begin
    end else if (early_mispredict_active) begin
      ref_checkpoint_restore    = 1'b1;
      ref_checkpoint_restore_id = early_mispredict_checkpoint_id;
    end else if (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint) begin
      ref_checkpoint_restore    = 1'b1;
      ref_checkpoint_restore_id = mispredict_commit_q.checkpoint_id;
    end
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown(
            {flush_all, ref_flush_all, flush_en, ref_flush_en, flush_tag, flush_tag_q,
             ref_flush_tag, flush_pipeline, ref_flush_pipeline, frontend_state_flush,
             ref_frontend_state_flush,
             checkpoint_restore, ref_checkpoint_restore, checkpoint_restore_id,
             ref_checkpoint_restore_id}
        )) begin
      p_flush_all_is_the_pulse_or : assert (flush_all == ref_flush_all);
      p_flush_en_exact : assert (flush_en == ref_flush_en);
      p_flush_tag_exact_when_enabled : assert (!ref_flush_en || flush_tag == ref_flush_tag);
      p_flush_tag_q_exact : assert (flush_tag_q == flush_tag);
      p_flush_pipeline_exact : assert (flush_pipeline == ref_flush_pipeline);
      p_frontend_state_flush_exact : assert (frontend_state_flush == ref_frontend_state_flush);
      p_checkpoint_restore_exact : assert (checkpoint_restore == ref_checkpoint_restore);
      p_checkpoint_restore_id_exact_where_observed :
      assert (!(ref_checkpoint_restore || early_mispredict_active ||
                (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint)) ||
              checkpoint_restore_id == ref_checkpoint_restore_id);
    end
  end

  logic restore_flush_copy_armed_q = 1'b0;
  always_ff @(posedge i_clk) begin
    restore_flush_copy_armed_q <= 1'b1;
    if (restore_flush_copy_armed_q) begin
      p_restore_flush_copy_matches : assert (restore_flush_all_q == full_flush_side_effect_kill_q);
      p_frontend_flush_copy_matches :
      assert (frontend_flush_all_q == full_flush_side_effect_kill_q);
    end
  end
`endif
  assign o_commit_recovery_flush_after_head = commit_recovery_flush_after_head;
  assign o_flush_after_head                 = flush_after_head;
  assign o_checkpoint_restore               = checkpoint_restore;
  assign o_checkpoint_restore_id            = checkpoint_restore_id;
  assign o_checkpoint_restore_reclaim_all   = checkpoint_restore_reclaim_all;
  assign o_checkpoint_flush_free_mask       = checkpoint_flush_free_mask;
  assign o_checkpoint_free                  = checkpoint_free;
  assign o_checkpoint_free_id               = checkpoint_free_id;

endmodule : misprediction_flush_controller
