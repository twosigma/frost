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
 * OOO back-end: flush_all for traps / MRET / FENCE-class retirement,
 * flush_en+flush_tag for partial mispredict recovery (early or commit-time), plus the checkpoint
 * restore / free / bulk-free-mask machinery.
 * Slot-2 correct-branch training is held independently and has its own
 * checkpoint-free channel.
 *
 * Every broadcast (flush_all, flush_pipeline, frontend_state_flush,
 * flush_en/flush_tag, checkpoint_restore/_id) is decoded from registered
 * state only - the registered full-flush pulse and the pending flags - never
 * from the raw trap/MRET takes or FENCE-class event; sim references pin each one to its
 * priority-chain definition.
 */

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
    // The trap/xRET take strobes and the serializer-owned FENCE-class
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
    // Phase-identical full-flush alias for latency-critical consumers (the
    // commit-writeback valid mask). Both outputs come from the replicated
    // registered semantic-event image; FENCE-class recovery remains the
    // full-flush winner if a younger partial recovery is also pending.
    output logic o_flush_all_flat,
    output logic o_commit_recovery_flush_after_head,
    output logic o_flush_after_head,
    output logic o_checkpoint_restore,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_restore_id,
    output logic o_checkpoint_restore_reclaim_all,
    output logic [riscv_pkg::NumCheckpoints-1:0] o_checkpoint_flush_free_mask,
    output logic o_checkpoint_free,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_free_id,
    // Slot-2 correct-branch side effects: a second, direct checkpoint-free
    // channel (never contends with the recovery arms of the primary mux)
    // and a held BTB-training capture.  Export the raw held bit, without the
    // early-recovery service gate, so the parallel late BTB RMW address has no
    // combinational early-active dependency.  correct_branch_2_served remains
    // internal and still controls exactly when the held capture is cleared.
    output logic o_correct_branch_commit_pending_2_raw,
    output riscv_pkg::correct_branch_commit_capture_t o_correct_branch_commit_q_2,
    output logic o_checkpoint_free_2,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_free_id_2
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
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

  // Outputs produced below (also read internally); wired to o_* at the end.
  // TIMING: the capture payloads feed every replica of the (fanout-capped,
  // hence replicated) BTB training mux in ex_comb_synthesizer.  Per-bit caps
  // let the hot flag/select bits replicate with the mux while the wide PC
  // fields (per-bit load ≈ replica count) stay single.
  (* max_fanout = 64 *) riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  // TIMING: mispredict_recovery_pending's register net IS o_dispatch_flush
  // (direct alias) and feeds every recovery-priority arm here, so it lands on
  // RS/LQ/SQ kill and capture gating across the whole backend (largest family
  // of post-place failing paths by TNS, ~570-fanout nets en route).  Cap the
  // register so synthesis replicates the flop per consumer region; its D-cone
  // is one shallow LUT.  flush_pipeline / frontend_state_flush /
  // full_flush_side_effect_kill are the uncapped comb broadcasts of the same
  // recovery state into the front-end — cap them like flush_en/flush_all below.
  // Cap 24 (was 48): at 48 only two replicas materialized and the family
  // stayed the #2 post-place TNS contributor; tighter cap = one replica per
  // consumer region.
  (* max_fanout = 24 *) logic mispredict_recovery_pending;
  logic [XLEN-1:0] fence_i_target_pc;
  (* max_fanout = 64 *) logic flush_pipeline;
  logic dispatch_flush;
  (* max_fanout = 64 *) logic full_flush_side_effect_kill;
  (* max_fanout = 64 *) logic frontend_state_flush;
  // TIMING: flush_en / flush_tag / flush_all broadcast into the whole backend
  // (ROB commit gate, RS/LQ/SQ kills, RAT).  They are shallow functions of
  // registered recovery state, so cap the fanout and let synthesis replicate
  // the driver LUTs per consumer region.  Pure fanout splitting — the
  // priority structure below is untouched.
  (* max_fanout = 64 *) logic flush_en;
  (* max_fanout = 64 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag;
  (* max_fanout = 64 *) logic flush_all;
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
  // instruction instead of from speculative fetch state that was already
  // ahead. CSR commits latch the same way (Phase 3 M4, plan D10): a
  // translation-class CSR recovery consumes the same target when its delayed
  // fence_i_flush pulse follows; latching every CSR commit is harmless when no
  // recovery follows.
  always_ff @(posedge i_clk) begin
    if (rob_commit_comb.valid && (rob_commit_comb.is_fence_i || rob_commit_comb.is_csr)) begin
      fence_i_target_pc <= fence_i_target_pc_pre;
    end
  end

  // Register correctly-predicted branch commit for BTB update + checkpoint free.
  // TIMING: selects the correct-branch arm of the BTB training mux
  // (ex_comb_synthesizer) — with the mux replicated per RAM region, this
  // select feeds every replica.  Cap for the same per-region replication.
  (* max_fanout = 48 *) logic correct_branch_commit_pending;
  // Payload cap: same reasoning as mispredict_commit_q above.
  (* max_fanout = 64 *) riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q;

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

  // --- Slot-2 correct-branch capture ---
  // pending_2 is HELD until the BTB-training channel is idle (all higher
  // synthesizer arms quiet), superseded by a newer slot-2 capture, or
  // flushed.  The checkpoint free must NOT wait: it pulses on the first
  // held cycle, and the ownership CAM qualification (in_use && owner match)
  // self-limits it to exactly one pulse — cpu_ooo clears in_use on the free,
  // so a reallocated id can never be freed again by a stale hold.
  // TIMING: the held slot-2 select feeds the lowest-priority arm of every
  // replica of the BTB training mux — uncapped it became the single largest
  // post-place failing-path family (8388 paths) once the mux replicated.
  // Same caps as the slot-1 pending/payload pair.
  (* max_fanout = 48 *) logic correct_branch_commit_pending_2;
  (* max_fanout = 64 *) riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q_2;
  wire commit_is_correct_branch_2 = rob_commit_correct_branch_2_raw;
  logic correct_branch_2_served;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) correct_branch_commit_pending_2 <= 1'b0;
    else if (commit_is_correct_branch_2) correct_branch_commit_pending_2 <= 1'b1;
    else if (correct_branch_2_served) correct_branch_commit_pending_2 <= 1'b0;
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

  // One-shot slot-2 checkpoint free (see ownership self-limit note above).
  logic correct_branch_commit_checkpoint_live_2;
  always_comb begin
    correct_branch_commit_checkpoint_live_2 = 1'b0;
    if (correct_branch_commit_pending_2) begin
      correct_branch_commit_checkpoint_live_2 =
          checkpoint_in_use[correct_branch_commit_q_2.checkpoint_id] &&
          (checkpoint_owner_tag[correct_branch_commit_q_2.checkpoint_id] ==
           correct_branch_commit_q_2.tag);
    end
  end
  assign o_checkpoint_free_2    = !flush_all && correct_branch_commit_checkpoint_live_2;
  assign o_checkpoint_free_id_2 = correct_branch_commit_q_2.checkpoint_id;

  // ---------------------------------------------------------------------
  // Broadcast decode. Every flush/restore broadcast below is ONE LUT of
  // registered state: the registered full-flush pulse (== trap || MRET ||
  // FENCE-class recovery, pinned by p_flush_all_is_the_pulse_or), the recovery-pending
  // flags and the early-recovery pending flag. The raw trap/MRET takes and
  // serializer FENCE-class event never reach a broadcast net; they only feed
  // the sim references that pin every output to its original priority-chain
  // definition.
  // ---------------------------------------------------------------------
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 64 *)
  logic full_flush_side_effect_kill_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) full_flush_side_effect_kill_q <= 1'b0;
    else full_flush_side_effect_kill_q <= i_trap_taken || i_mret_taken || i_fence_class_flush_event;
  end
  assign full_flush_side_effect_kill = full_flush_side_effect_kill_q;
  assign flush_all                   = full_flush_side_effect_kill_q;

  // early_mispredict_active without its trap/MRET terms: identical whenever
  // flush_all is low, and every use below is dominated by flush_all.
  logic early_redirect_fast;
  assign early_redirect_fast = early_mispredict_pending && !mispredict_recovery_pending &&
                               !active_fence_i_flush;

  // Flush pipeline on the redirecting early-recovery phase, registered
  // misprediction recovery, trap, MRET, or FENCE-class recovery. The delayed backend
  // recovery phase is a hold-only bubble, not a second frontend flush.
  assign flush_pipeline = flush_all || mispredict_recovery_pending || early_redirect_fast;

  // IF internal state cleanup can lag trap/MRET by one cycle, but keep
  // mispredict and FENCE-class cleanup on its existing timing.
  assign frontend_state_flush = flush_pipeline;

  // Dispatch needs a same-cycle kill for commit-time partial recovery.
  assign dispatch_flush = mispredict_recovery_pending;
  // TIMING: the kill was the comb OR of three REGISTERED pulses -- an
  // uncapped ~250-load broadcast into RAT/ROB allocation and the commit bus
  // that synthesis cannot replicate (only registers survive replication
  // through opt). It is now a register fed by those pulses' semantic source
  // events: the identical value on every cycle (the oracle below pins it), but
  // a flop the tool replicates per consumer region.
  // Tomasulo flush hierarchy. fence_i_flush (the shared FENCE-class pulse)
  // sits in the FULL-flush tier,
  // not below the partial arms: a younger branch's recovery pulse landing
  // in the fence/CSR flush cycle must not demote the flush to a partial
  // one — ops between the fence and that branch may have been fetched
  // before the L1I invalidate finished (stale code), and for the D10
  // translation-CSR flavor a younger load may have issued under the old
  // satp with its stale PA already in the LQ. The full flush is a strict
  // superset of the partial kill, the PC mux already prefers the fence
  // target over the branch redirect, and the partial-recovery pendings
  // tolerate being superseded by flush_all exactly as they do when a trap
  // wins this arbitration.
  assign flush_en = !flush_all && (early_backend_recovery_pending || mispredict_recovery_pending);
  always_comb begin
    flush_tag = '0;
    if (flush_all) flush_tag = '0;
    else if (early_backend_recovery_pending) flush_tag = early_backend_flush_tag;
    else if (mispredict_recovery_pending) flush_tag = mispredict_commit_q.tag;
  end

  // Commit-time mispredict recovery is already a registered 1-cycle pulse.
  assign commit_recovery_flush_after_head = mispredict_recovery_pending;

  // flush_after_head: commit-time mispredict recovery retired the offending
  // branch at the ROB head in the previous cycle. The checkpoint mask uses
  // this to free ALL in-use checkpoints.
  logic flush_after_head;
  assign flush_after_head = commit_recovery_flush_after_head;

  // Checkpoint restore on misprediction (early or commit-time). The restore
  // id is the checkpoint RAM read address: it feeds ~460 LUTRAM address pins
  // and then the whole RAT restore mux tree. Its readout is only observed
  // while checkpoint_restore is high or the RAS restore payload is taken
  // (commit-time recovery with a checkpoint, or early_mispredict_active), so
  // it is one LUT of registered state: zero on the full-flush pulse, else
  // the early id unless commit-time recovery is pending. It differs from
  // the original priority chain only where nothing reads it.
  assign checkpoint_restore = !flush_all &&
      (early_redirect_fast ||
       (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint));
  assign checkpoint_restore_id =
      flush_all ? '0 :
      (early_mispredict_pending && !mispredict_recovery_pending) ? early_mispredict_checkpoint_id :
      mispredict_commit_q.checkpoint_id;
  assign checkpoint_restore_reclaim_all = 1'b0;

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
  assign o_flush_tag                           = flush_tag;
  assign o_flush_all                           = flush_all;
  assign o_flush_all_flat                      = flush_all;

`ifndef SYNTHESIS
  // Reference decode: the original priority chains, verbatim, from the raw
  // trap/MRET/FENCE-class inputs and early_mispredict_active.
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
            {flush_all, ref_flush_all, flush_en, ref_flush_en, flush_tag, ref_flush_tag,
             flush_pipeline, ref_flush_pipeline, frontend_state_flush, ref_frontend_state_flush,
             checkpoint_restore, ref_checkpoint_restore, checkpoint_restore_id,
             ref_checkpoint_restore_id}
        )) begin
      p_flush_all_is_the_pulse_or : assert (flush_all == ref_flush_all);
      p_flush_en_tag_exact : assert (flush_en == ref_flush_en && flush_tag == ref_flush_tag);
      p_flush_pipeline_exact : assert (flush_pipeline == ref_flush_pipeline);
      p_frontend_state_flush_exact : assert (frontend_state_flush == ref_frontend_state_flush);
      p_checkpoint_restore_exact : assert (checkpoint_restore == ref_checkpoint_restore);
      p_checkpoint_restore_id_exact_where_observed :
      assert (!(ref_checkpoint_restore || early_mispredict_active ||
                (mispredict_recovery_pending && mispredict_commit_q.has_checkpoint)) ||
              checkpoint_restore_id == ref_checkpoint_restore_id);
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
