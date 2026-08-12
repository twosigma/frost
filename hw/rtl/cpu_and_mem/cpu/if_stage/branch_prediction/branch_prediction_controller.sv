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
 * Branch Prediction Controller
 *
 * Encapsulates the branch prediction logic for the IF stage, including:
 *   - Branch Target Buffer (BTB) instantiation and management
 *   - Return Address Stack (RAS) for function call/return prediction
 *   - Prediction gating logic (when to use predictions)
 *   - Prediction registration for pipeline timing alignment
 *   - Holdoff generation for C-extension state clearing
 *
 * TIMING OPTIMIZATION: This module registers prediction outputs and uses
 * only registered control signals for gating decisions. The combinational
 * BTB lookup result is gated by registered holdoff signals, breaking the
 * path from stall logic through prediction to PC calculation.
 *
 * Architecture:
 *   - BTB provides combinational lookup (o_btb_* signals)
 *   - RAS provides return address prediction for JALR returns
 *   - RAS prediction takes priority over BTB for detected returns
 *   - sel_prediction gates when prediction actually redirects PC
 *   - Registered outputs (o_prediction_*_r) align with instruction timing
 *   - prediction_holdoff signals c_ext_state to clear stale buffers
 */
module branch_prediction_controller (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_stall_registered,
    // Fetch progress (live window valid OR stall-replay bundle presented).
    // New predictions are suppressed upstream via
    // i_disable_branch_prediction when there is no progress; this input
    // additionally HOLDS the registered prediction pipeline (metadata,
    // pc_reg handoff, holdoffs) so a prediction consumed on the last
    // delivered cycle keeps its bookkeeping until the deferred window
    // arrives and the dance can resume.
    input logic i_fetch_progress,
    input logic i_flush,
    // PD-stage redirect. Kills in-flight registered prediction metadata the
    // same way a flush does: a PD redirect steals the PC stream from any
    // prediction made in the same (or previous) cycle, so the registered
    // pc_reg handoff must not survive it. pc_controller's redirect_kill
    // pulse only suppresses the handoff for one cycle and is not stall-aware;
    // clearing at the source keeps a stall from replaying a dead prediction.
    input logic i_pd_redirect,
    input logic [riscv_pkg::XLEN-1:0] i_pd_redirect_target,

    // Current PC for slot-1 BTB lookup (live fetch address)
    input logic [riscv_pkg::XLEN-1:0] i_pc,

    // Slot-2 BTB lookup candidates.  i_pc_2/i_pc_2_alt retain the actual
    // pc_reg+2/pc_reg+4 addresses for direction-predictor metadata.  Both BTB
    // replicas are shifted so i_pc_2_base=pc_reg addresses their entries
    // without either candidate increment on an asynchronous LUTRAM address.
    // The late size bit selects only after both lookups have completed.
    input logic [riscv_pkg::XLEN-1:0] i_pc_2,
    input logic [riscv_pkg::XLEN-1:0] i_pc_2_alt,
    input logic [riscv_pkg::XLEN-1:0] i_pc_2_base,
    input logic                       i_slot2_pc_use_alt,
    input logic                       i_slot2_valid,
    // Candidate-local sizes arrive without the late slot-1-size select, so
    // each fixed BTB result can complete its strict halfword safety check in
    // parallel.
    input logic                       i_slot2_is_compressed_plus2,
    input logic                       i_slot2_is_compressed_plus4,
    // Slot-2 instruction's compressed flag (live from instruction_aligner).
    // Retained as a simulation/formal observation for the legacy-equivalence
    // oracle below; synthesis uses the two fixed-candidate inputs above.
    input logic                       i_slot2_is_compressed,

    // Control signals for prediction gating (all should be registered for timing)
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic i_branch_taken,
    input logic i_any_holdoff_safe,     // Registered holdoff signals
    input logic i_is_32bit_spanning,
    input logic i_use_instr_buffer,
    input logic i_disable_branch_prediction,

    // BTB update interface (from EX stage)
    input logic                       i_btb_update,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_pc,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_target,
    input logic                       i_btb_update_taken,
    input logic                       i_btb_update_compressed,
    input logic                       i_btb_update_requires_pc_reg_handoff,
    // Direct early-recovery counter-RMW candidate.  The selected update port
    // above remains the sole source of actual BTB writes.
    input logic                       i_btb_early_update_active,
    input logic [riscv_pkg::XLEN-1:0] i_btb_early_update_pc,
    input logic                       i_btb_early_update_taken,
    // Independently selected lower-priority counter-RMW candidate.
    input logic [riscv_pkg::XLEN-1:0] i_btb_late_update_pc,
    input logic                       i_btb_late_update_taken,

    // RAS inputs (for call/return detection)
    input riscv_pkg::instr_t i_instruction,  // Current instruction for RAS detection
    input logic [15:0] i_raw_parcel,  // Raw 16-bit parcel (for compressed detection)
    input logic i_is_compressed,  // Current instruction is compressed
    input logic i_instruction_valid,  // Instruction is valid (not NOP/holdoff)
    input logic [riscv_pkg::XLEN-1:0] i_link_address,  // Pre-computed link address for push

    // RAS misprediction recovery (from EX stage)
    input logic                             i_ras_misprediction,
    input logic [riscv_pkg::RasPtrBits-1:0] i_ras_restore_tos,
    input logic [  riscv_pkg::RasPtrBits:0] i_ras_restore_valid_count,
    input logic                             i_ras_pop_after_restore,
    input logic                             i_ras_push_after_restore,
    input logic [      riscv_pkg::XLEN-1:0] i_ras_push_address_after_restore,

    // Bimodal direction-predictor training (from commit, CONDITIONAL branches
    // only).  Trains at the committing branch PC; no carried GHR / predict-PC.
    input logic                               i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic                               i_dir_update_taken,

    // Combinational prediction outputs (for pc_controller next_pc selection)
    output logic                       o_predicted_taken,
    output logic [riscv_pkg::XLEN-1:0] o_predicted_target,

    // Registered prediction outputs (for pipeline stage alignment)
    output logic o_prediction_used_r,  // Prediction was actually used (registered)
    output logic [riscv_pkg::XLEN-1:0] o_predicted_target_r,  // Target address (registered)

    // Control outputs
    output logic o_prediction_used,  // Prediction used this cycle (for pc_controller)
    output logic o_prediction_used_for_pc,  // Stall-ungated PC mux select
    output logic o_prediction_holdoff,  // One cycle after prediction (for c_ext_state)
    output logic o_btb_only_prediction_holdoff,  // Holdoff when BTB (not RAS) predicted
    output logic o_sel_prediction_r,  // Registered sel_prediction (for pc_controller pc_reg)
    output logic o_prediction_requires_pc_reg_handoff,
    // Predicted op must still execute in IF/PD/ID
    output logic o_control_flow_to_halfword_pred,  // Prediction targets halfword address

    // Slot-2 prediction outputs.  Combinational: feeds
    // pc_controller's slot-2 redirect path AND the slot-2 IF→PD metadata.
    // A taken slot-2 prediction redirects pc[N+2] to o_slot2_predicted_target
    // and triggers a 1-cycle bubble at cycle N+2 (the BRAM was already
    // fetching the wrong-path sequential address at cycle N+1).
    output logic                       o_slot2_prediction_used,
    output logic                       o_slot2_prediction_used_for_pc,
    output logic                       o_slot2_btb_hit,
    output logic                       o_slot2_predicted_taken,
    output logic [riscv_pkg::XLEN-1:0] o_slot2_predicted_target,

    // RAS prediction outputs (for pipeline passthrough)
    output logic o_ras_predicted,  // RAS prediction was used
    output logic [riscv_pkg::XLEN-1:0] o_ras_predicted_target,  // RAS predicted return address
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_checkpoint_tos,  // TOS checkpoint for recovery
    output logic [riscv_pkg::RasPtrBits:0] o_ras_checkpoint_valid_count,  // Valid count checkpoint

    // Decoupled bimodal direction (NOT gated by btb_hit), registered to
    // align with the prediction metadata carried to PD.  PD redirects on a BTB
    // miss when this predicts taken (any offset sign).
    output logic o_dir_predicted_taken,
    // Predict-time bimodal index to carry with each fetched branch
    // (slot-1 registered to align with the prediction metadata; slot-2
    // combinational off its own lookup PC) and hand back at commit for training.
    output logic [riscv_pkg::BpDirIdxBits-1:0] o_dir_idx,
    output logic [riscv_pkg::BpDirIdxBits-1:0] o_dir_idx_2
);

  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;
  localparam int unsigned RasDepth = riscv_pkg::RasDepth;

  // ===========================================================================
  // BTB Instance (slot-1 + slot-2 lookup ports, single update port)
  // ===========================================================================
  logic            btb_hit;
  logic            btb_predicted_taken;
  logic [XLEN-1:0] btb_predicted_target;
  logic            btb_compressed;
  logic            btb_requires_pc_reg_handoff;

  // Slot-2 BTB outputs.
  logic            btb_hit_2;
  logic            btb_predicted_taken_2;
  logic            btb_predicted_taken_2_plus2;
  logic            btb_predicted_taken_2_plus4;
  logic [XLEN-1:0] btb_predicted_target_2;
  logic            btb_compressed_2;
  logic            btb_compressed_2_plus2;
  logic            btb_compressed_2_plus4;
  logic            btb_requires_pc_reg_handoff_2;

  // Taken predictions always need the predicted PC to keep flowing through
  // IF/PD/ID so the branch or stale predicted op can resolve architecturally.
  // Avoid putting the BTB metadata RAM read on the pending-prediction arm path.
  assign o_prediction_requires_pc_reg_handoff = dir_predicted_taken;

  branch_predictor #(
      .XLEN(XLEN)
  ) branch_predictor_inst (
      .i_clk,
      .i_rst(i_reset),

      // Slot-1 prediction lookup (uses current fetch PC)
      .i_pc(i_pc),
      .o_btb_hit(btb_hit),
      .o_predicted_taken(btb_predicted_taken),
      .o_predicted_target(btb_predicted_target),
      .o_btb_compressed(btb_compressed),
      .o_btb_requires_pc_reg_handoff(btb_requires_pc_reg_handoff),

      // Shifted slot-2 BTB replicas are both addressed by pc_reg.
      .i_pc_2_base(i_pc_2_base),
      .i_pc_2_use_alt(i_slot2_pc_use_alt),
      .o_predicted_taken_2_plus2(btb_predicted_taken_2_plus2),
      .o_predicted_taken_2_plus4(btb_predicted_taken_2_plus4),
      .o_btb_compressed_2_plus2(btb_compressed_2_plus2),
      .o_btb_compressed_2_plus4(btb_compressed_2_plus4),
      .o_btb_hit_2(btb_hit_2),
      .o_predicted_taken_2(btb_predicted_taken_2),
      .o_predicted_target_2(btb_predicted_target_2),
      .o_btb_compressed_2(btb_compressed_2),
      .o_btb_requires_pc_reg_handoff_2(btb_requires_pc_reg_handoff_2),

      // Update from EX stage
      .i_update(i_btb_update),
      .i_update_pc(i_btb_update_pc),
      .i_update_target(i_btb_update_target),
      .i_update_taken(i_btb_update_taken),
      .i_update_compressed(i_btb_update_compressed),
      .i_update_requires_pc_reg_handoff(i_btb_update_requires_pc_reg_handoff),
      .i_early_update_active(i_btb_early_update_active),
      .i_early_update_pc(i_btb_early_update_pc),
      .i_early_update_taken(i_btb_early_update_taken),
      .i_late_update_pc(i_btb_late_update_pc),
      .i_late_update_taken(i_btb_late_update_taken)
  );

  // ===========================================================================
  // Direction Predictor (decoupled bimodal) — the BTB-miss direction
  // ===========================================================================
  // Supplies a taken/not-taken direction independent of the BTB, so a conditional
  // branch that MISSES the BTB still has a trained direction for the PD-stage
  // computed-target redirect.  The BTB still supplies the target and
  // the direction for branches that HIT it.  Trained at commit on conditional
  // branches only, indexed by the committing branch PC.
  logic dir_taken;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_pred_idx;  // slot-1 predict-time index

  direction_predictor #(
      .XLEN(XLEN),
      .BIM_BITS(riscv_pkg::BpDirIdxBits)
  ) direction_predictor_inst (
      .i_clk,
      .i_rst(i_reset),

      // Slot-1 lookup (same live fetch PC as the BTB)
      .i_pc(i_pc),
      .o_taken(dir_taken),
      .o_pred_idx(dir_pred_idx),

      // Commit-time training (conditional branches only).  Trained at the carried
      // predict-time index so it updates the exact entry the prediction read.
      .i_update_valid(i_dir_update_valid),
      .i_update_idx  (i_dir_update_idx),
      .i_update_taken(i_dir_update_taken)
  );

  // Registered decoupled bimodal direction, snapshot in the SAME
  // ~i_stall stage as the registered prediction metadata (o_predicted_target_r /
  // prediction_used_r) so the bit carried to PD aligns with that instruction.
  // This is dir_taken (decoupled), NOT dir_predicted_taken (gated by btb_hit,
  // which would be 0 on a miss).
  logic dir_taken_snapshot_r;
  assign o_dir_predicted_taken = dir_taken_snapshot_r;

  // Carry the predict-time bimodal index.  Slot-1 is registered in the
  // SAME stage as dir_taken_snapshot_r (aligns with the prediction metadata
  // reaching from_if_to_pd); slot-2's prediction is combinational, so its index
  // is combinational off the selected slot-2 lookup PC (i_pc_2 / i_pc_2_alt).
  logic [riscv_pkg::XLEN-1:0] selected_slot2_pc;
  assign selected_slot2_pc = i_slot2_pc_use_alt ? i_pc_2_alt : i_pc_2;
  logic [riscv_pkg::BpDirIdxBits-1:0] pred_idx_snapshot_r;
  assign o_dir_idx   = pred_idx_snapshot_r;
  assign o_dir_idx_2 = selected_slot2_pc[riscv_pkg::BpDirIdxBits:1];

  // BTB-hit direction comes from the BTB's own 2-bit counter (btb_predicted_taken).
  // The decoupled bimodal (dir_taken) is used ONLY for the PD BTB-miss redirect
  // (carried to PD as o_dir_predicted_taken); it never overrides a BTB hit.
  logic dir_predicted_taken;
  logic dir_predicted_taken_2;
  assign dir_predicted_taken   = btb_predicted_taken;
  assign dir_predicted_taken_2 = btb_predicted_taken_2;

  // ===========================================================================
  // RAS (Return Address Stack) Instance
  // ===========================================================================
  // RAS provides return address prediction for JALR instructions.
  // Detects call/return patterns and maintains a stack of return addresses.

  // RAS detector signals
  logic ras_is_call;
  logic ras_is_return;
  logic ras_is_coroutine;

  ras_detector ras_detector_inst (
      .i_instruction(i_instruction),
      .i_raw_parcel(i_raw_parcel),
      .i_is_compressed(i_is_compressed),
      .i_instruction_valid(i_instruction_valid),
      .o_is_call(ras_is_call),
      .o_is_return(ras_is_return),
      .o_is_coroutine(ras_is_coroutine)
  );

  // RAS stack signals
  logic                  ras_valid;
  logic [      XLEN-1:0] ras_target;
  logic [RasPtrBits-1:0] ras_checkpoint_tos;
  logic [  RasPtrBits:0] ras_checkpoint_valid_count;

  // ===========================================================================
  // RAS Recovery Signal Registration (Timing Optimization)
  // ===========================================================================
  // Register misprediction recovery inputs to break the EX->IF critical path.
  // Safe because any redirect triggers holdoff, so predictions are blocked
  // while the one-cycle-delayed restore takes effect.
  logic                  ras_misprediction_r;
  logic [RasPtrBits-1:0] ras_restore_tos_r;
  logic [  RasPtrBits:0] ras_restore_valid_count_r;
  logic                  ras_pop_after_restore_r;
  logic                  ras_push_after_restore_r;
  logic [      XLEN-1:0] ras_push_address_after_restore_r;

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      ras_misprediction_r <= 1'b0;
      ras_pop_after_restore_r <= 1'b0;
      ras_push_after_restore_r <= 1'b0;
    end else begin
      ras_misprediction_r <= i_ras_misprediction;
      ras_pop_after_restore_r <= i_ras_pop_after_restore;
      ras_push_after_restore_r <= i_ras_push_after_restore;
    end
  end

  always_ff @(posedge i_clk) begin
    ras_restore_tos_r <= i_ras_restore_tos;
    ras_restore_valid_count_r <= i_ras_restore_valid_count;
    ras_push_address_after_restore_r <= i_ras_push_address_after_restore;
  end

  // Compute prediction_allowed for BTB
  // Block halfword-aligned PCs unless the BTB entry is marked as compressed.
  // A 32-bit spanning instruction at a halfword PC must NOT be predicted because
  // the redirect would corrupt the spanning state machine. Compressed instructions
  // at halfword PCs are safe to predict.
  // CRITICAL: Block during prediction_holdoff to prevent feedback loop.
  // After a prediction redirects PC, the next cycle has stale instruction data.
  // If BTB predicts again on that stale data, prediction_holdoff stays high forever.
  //
  // TIMING OPTIMIZATION: Keep BTB/RAS allow logic independent of late
  // i_branch_taken and i_is_32bit_spanning. Both are applied at the final
  // "prediction used" stage to avoid dragging them through the full predictor
  // cone. This makes is_32bit_spanning (which depends on BRAM → is_compressed)
  // parallel with the prediction logic instead of serial, cutting ~5 LUT levels
  // from the critical path:
  //   BEFORE: BRAM → is_compressed → is_32bit_spanning → prediction_common → RAS → PC
  //   AFTER:  BRAM → is_32bit_spanning ─┐
  //           registered → prediction_common → sel_prediction ─ AND → prediction_used → PC
  logic prediction_common;
  logic prediction_allowed_stable;
  // TIMING OPTIMIZATION: Use i_stall_registered to break the critical 14-level path
  // rob_valid → commit_en → mret_start → id_valid → stall → prediction_common → RAS WE.
  // During the first stall cycle (stall=1, stall_registered=0), a prediction may fire.
  // This is safe: MRET/trap stalls flush the pipeline next cycle, and checkpoint restore
  // corrects any spurious RAS push/pop. Non-trap stalls have short paths that arrive
  // well before the clock edge regardless.
  assign prediction_common = !i_reset && !i_trap_taken && !i_mret_taken && !i_stall_registered &&
                             !i_any_holdoff_safe &&
                             !o_prediction_holdoff &&
                             !i_use_instr_buffer &&
                             !i_disable_branch_prediction;
  assign prediction_allowed_stable = prediction_common && (!i_pc[1] || btb_compressed);

  logic prediction_allowed;
  assign prediction_allowed = prediction_allowed_stable;

  // Compute ras_prediction_allowed - allows halfword-aligned PCs for compressed instructions.
  logic ras_prediction_allowed_stable;
  assign ras_prediction_allowed_stable = prediction_common && (!i_pc[1] || i_is_compressed);

  logic ras_prediction_allowed;
  assign ras_prediction_allowed = ras_prediction_allowed_stable;

  // Gate RAS pop with is_32bit_spanning (removed from prediction_common for timing).
  // This is on the registered pop path (RAS always_ff), not the PC mux critical path.
  // Prevents RAS state corruption from spurious pops during spanning instructions.
  logic ras_pop_prediction_allowed;
  // The first cycle of a front-end stall may still have a live BTB/RAS lookup
  // because prediction_common uses i_stall_registered for timing.  Do not let
  // that cycle mutate speculative RAS state: pc/o_pc_reg and prediction
  // sideband are not advancing together, so consuming a prediction there can
  // re-tag a later instruction with the wrong PC.
  assign ras_pop_prediction_allowed = ras_prediction_allowed && !i_is_32bit_spanning && !i_stall;
  logic ras_write_prediction_allowed;
  assign ras_write_prediction_allowed = ras_prediction_allowed && !i_is_32bit_spanning &&
                                        !i_stall_registered;

  return_address_stack #(
      .RAS_DEPTH(RasDepth),
      .RAS_PTR_BITS(RasPtrBits)
  ) ras_inst (
      .i_clk,
      .i_rst(i_reset),
      .i_stall_registered,
      .i_is_call(ras_is_call),
      .i_is_return(ras_is_return),
      .i_is_coroutine(ras_is_coroutine),
      .i_link_address(i_link_address),
      .i_prediction_allowed(ras_pop_prediction_allowed),
      .i_prediction_allowed_for_write(ras_write_prediction_allowed),
      .i_btb_only_prediction_holdoff(o_btb_only_prediction_holdoff),
      .i_misprediction(ras_misprediction_r),
      .i_restore_tos(ras_restore_tos_r),
      .i_restore_valid_count(ras_restore_valid_count_r),
      .i_pop_after_restore(ras_pop_after_restore_r),
      .i_push_after_restore(ras_push_after_restore_r),
      .i_push_address_after_restore(ras_push_address_after_restore_r),
      .o_ras_valid(ras_valid),
      .o_ras_target(ras_target),
      .o_checkpoint_tos(ras_checkpoint_tos),
      .o_checkpoint_valid_count(ras_checkpoint_valid_count)
  );

  // ===========================================================================
  // Prediction Gating Logic
  // ===========================================================================
  // sel_prediction determines when a BTB prediction actually redirects the PC.
  // We block predictions in various scenarios to maintain correctness:
  //
  //   - During reset, trap, mret, stall (higher priority control flow)
  //   - During branch taken from EX (actual resolution overrides prediction)
  //   - During holdoff cycles (instruction data is stale)
  //   - While the instruction buffer is in use
  //   - For halfword-aligned PCs unless the BTB entry is marked compressed
  //   - When branch prediction is disabled (verification mode)
  //
  // TIMING: Uses i_any_holdoff_safe (registered) to break path from branch_taken.

  // sel_prediction for BTB only (without RAS)
  logic sel_btb_prediction;
  assign sel_btb_prediction = prediction_allowed && dir_predicted_taken;

  // sel_prediction for RAS (for returns, RAS takes priority over BTB)
  // Use ras_prediction_allowed which permits halfword-aligned PCs for compressed instructions
  logic sel_ras_prediction;
  assign sel_ras_prediction = ras_prediction_allowed && ras_valid;

  // Combined prediction selection: RAS takes priority for returns
  logic sel_prediction;
  assign sel_prediction = sel_ras_prediction || sel_btb_prediction;

  // Actual prediction use must still be blocked when branch resolution or spanning
  // is taking priority this cycle. Keep branch_taken and is_32bit_spanning as final
  // gates to keep them out of the deep prediction_common → RAS → sel_prediction cone.
  logic prediction_used_effective;
  logic prediction_used_for_pc;
  // Only "use" a prediction when IF can actually consume it. A prediction that
  // fires on the first stall cycle is especially dangerous for halfword target
  // handoff: the branch bytes can keep moving through IF while the PC/metadata
  // bookkeeping stays behind by one instruction.
  assign prediction_used_for_pc = sel_prediction && !i_branch_taken && !i_is_32bit_spanning;
  assign prediction_used_effective = prediction_used_for_pc && !i_stall;

  // Export combinational prediction for pc_controller
  // RAS prediction takes priority over BTB for returns
  assign o_predicted_taken = sel_ras_prediction || dir_predicted_taken;
  assign o_predicted_target = sel_ras_prediction ? ras_target : btb_predicted_target;
  assign o_prediction_used = prediction_used_effective;
  assign o_prediction_used_for_pc = prediction_used_for_pc;

  // Detect prediction to halfword-aligned address
  logic predicted_target_is_halfword;
  assign predicted_target_is_halfword = sel_ras_prediction ?
                                        ras_target[1] : btb_predicted_target[1];
  assign o_control_flow_to_halfword_pred = prediction_used_effective &&
                                           predicted_target_is_halfword;

  // RAS prediction outputs (for pipeline passthrough)
  assign o_ras_predicted = sel_ras_prediction;
  assign o_ras_predicted_target = ras_target;
  assign o_ras_checkpoint_tos = ras_checkpoint_tos;
  assign o_ras_checkpoint_valid_count = ras_checkpoint_valid_count;

  // ===========================================================================
  // Prediction Registration
  // ===========================================================================
  // Register prediction outputs for pipeline timing alignment.
  // When we predict at PC_N in cycle N:
  //   - Cycle N: BTB lookup, sel_prediction computed, PC redirected
  //   - Cycle N+1: Instruction at PC_N arrives, needs registered prediction metadata
  //
  // CRITICAL: Only set registered taken flag if prediction was ACTUALLY USED.
  // If prediction was blocked (e.g., halfword-aligned PC), but we still pass
  // the raw BTB output, EX stage will think we predicted and skip the redirect.

  // A PD or slot-2 redirect can steal the fetch stream from a younger slot-1
  // prediction.  A PD redirect kills registered metadata when none is live or
  // when its target differs; preserving live metadata for a matching target
  // keeps the already-redirected branch's predicted-taken marker attached
  // through a stalled redirect (the cjpeg double-dispatch fix).
  //
  // Slot-2 is simpler: prediction_common includes !o_prediction_holdoff, and
  // registered slot-1 metadata implies that holdoff.  Therefore a consumed
  // slot-2 prediction necessarily has no older slot-1 metadata to preserve;
  // its target comparison was tautological.  Keep slot-2's full same-cycle
  // metadata/handoff kill, but do not route this late sideband-derived signal
  // to the prediction-holdoff flops below.
  logic pd_redirect_kills_prediction_metadata;
  assign pd_redirect_kills_prediction_metadata =
      i_pd_redirect &&
      (!o_prediction_used_r || (o_predicted_target_r != i_pd_redirect_target));

  logic redirect_kills_prediction_metadata;
  assign redirect_kills_prediction_metadata = pd_redirect_kills_prediction_metadata ||
                                              o_slot2_prediction_used;

  // Keep branch filtering in prediction_used_effective so registered metadata
  // only tracks predictions that were actually used.
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_used_r <= 1'b0;
      o_sel_prediction_r  <= 1'b0;
    end else if (i_flush) begin
      // Redirect flushes invalidate any in-flight prediction metadata even if
      // the front-end is stalled. Keeping the old registered target/live bit
      // across a stall+flush lets a stale prediction apply to a later
      // instruction stream with the wrong PC/instruction pairing.
      o_prediction_used_r <= 1'b0;
      o_sel_prediction_r  <= 1'b0;
    end else if (i_pd_redirect || o_slot2_prediction_used) begin
      // PD redirects and slot-2 prediction redirects kill a slot-1 prediction's
      // PC-REG HANDOFF exactly like a flush: they outrank it in the next_pc
      // mux, so the prediction never owns the fetch stream. pc_controller's
      // redirect_kill_pending_q / o_slot2_redirect_q suppressions are
      // one-cycle pulses that are not stall-aware, while this register IS
      // stall-held -- a stall starting in the kill cycle used to let the dead
      // prediction's pc_reg handoff fire on release, desyncing pc_reg from
      // the fetched bytes (stale words executed under wrong PCs; see
      // test_pd_redirect_with_stall_kills_registered_prediction_handoff).
      //
      // CRITICAL SCOPE: only the handoff (o_sel_prediction_r) dies here. The
      // METADATA bit (o_prediction_used_r -> btb_predicted_taken carried with
      // the in-flight instruction) must survive: clearing it on an unrelated
      // pd/slot-2 redirect strips a predicted-taken branch of its "front-end
      // already redirected" marker, and pd_stage's Lever-A heuristic then
      // re-redirects to the SAME target -- double-dispatching the (already
      // unsquashable) target bundle. Observed as two extra retirements in
      // cjpeg's Huffman zero-run loop, skipping one coefficient and emitting
      // a one-bit-short code (646-byte JPEG).
      o_sel_prediction_r <= 1'b0;
      if (redirect_kills_prediction_metadata) begin
        o_prediction_used_r <= 1'b0;
      end else if (~i_stall && i_fetch_progress) begin
        o_prediction_used_r <= prediction_used_effective;
      end
    end else if (~i_stall && i_fetch_progress) begin
      // i_fetch_progress in the gate: a prediction consumed on the last
      // cycle must keep its registered metadata and pc_reg handoff armed
      // across fetch-invalid cycles until the deferred instruction arrives.
      o_prediction_used_r <= prediction_used_effective;
      o_sel_prediction_r  <= prediction_used_effective;
    end
  end

  always_ff @(posedge i_clk) begin
    if (~i_stall && i_fetch_progress) begin
      // IMPORTANT: Register the combined RAS+BTB target, not just BTB target.
      // This is used for misprediction detection in EX stage - must match
      // the target we actually redirected PC to.
      o_predicted_target_r <= o_predicted_target;
      // Snapshot the decoupled bimodal direction AND its predict-time
      // index in the SAME stage so both carried values align with the instruction.
      dir_taken_snapshot_r <= dir_taken;
      pred_idx_snapshot_r  <= dir_pred_idx;
    end
  end

  // ===========================================================================
  // Prediction Holdoff Generation
  // ===========================================================================
  // Generate a one-cycle delayed signal after prediction for c_ext_state.
  // This tells c_ext_state to clear stale spanning/buffer state AFTER the
  // branch instruction processes but BEFORE the predicted target.
  //
  // Unlike control_flow_holdoff, this does NOT block is_compressed detection
  // which is needed for correct instruction processing at the branch PC.
  //
  // A slot-2 prediction can only fire while this holdoff is already clear.  If
  // a younger slot-1 BTB hit occurs on the same cycle, it may reload the
  // holdoff here, but slot2_redirect_q/control_flow_holdoff_q quarantine that
  // state inside the mandatory stale-fetch bubble.  Prediction is blocked in
  // the bubble, and the holdoff self-clears on its first delivered cycle.  The
  // architectural redirect and registered slot-1 metadata are still resolved
  // on the original edge above; this split only removes the instruction-memory
  // sideband cone from the holdoff flops' synchronous reset pins.

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_holdoff <= 1'b0;
    end else if (i_flush) begin
      o_prediction_holdoff <= 1'b0;
    end else if (pd_redirect_kills_prediction_metadata) begin
      o_prediction_holdoff <= 1'b0;
    end else if (~i_stall && i_fetch_progress) begin
      // Set holdoff on cycle after prediction.  Held through fetch-invalid
      // cycles so the deferred predicted-branch delivery still gets its
      // sel_nop exemption in if_stage.
      o_prediction_holdoff <= prediction_used_effective;
    end
  end

  // ===========================================================================
  // BTB-Only Prediction Holdoff
  // ===========================================================================
  // Track when BTB (but not RAS) made the prediction. This matters because:
  //   - BTB predicts based on PC (fetch address) BEFORE instruction arrives
  //   - RAS predicts based on instruction content AFTER instruction arrives
  //
  // During prediction_holdoff:
  //   - If BTB predicted: the instruction at the predicted PC arrives (VALID)
  //     RAS should be able to push if this instruction is a call
  //   - If RAS predicted: the next sequential instruction arrives (STALE)
  //     RAS detection should be blocked to prevent spurious pushes
  //
  // btb_only_prediction = BTB predicted AND RAS did NOT predict
  logic btb_only_prediction;
  assign btb_only_prediction = sel_btb_prediction && !sel_ras_prediction;
  logic btb_only_prediction_effective;
  assign btb_only_prediction_effective = btb_only_prediction && !i_stall &&
                                         !i_branch_taken && !i_is_32bit_spanning;

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_btb_only_prediction_holdoff <= 1'b0;
    end else if (i_flush) begin
      o_btb_only_prediction_holdoff <= 1'b0;
    end else if (pd_redirect_kills_prediction_metadata) begin
      o_btb_only_prediction_holdoff <= 1'b0;
    end else if (~i_stall && i_fetch_progress) begin
      o_btb_only_prediction_holdoff <= btb_only_prediction_effective;
    end
  end

  // ===========================================================================
  // Slot-2 Prediction Gating
  // ===========================================================================
  // Slot-2 prediction reuses prediction_common (same per-cycle blockers as
  // slot-1 — reset/trap/mret/holdoff/spanning/buffer/disabled) and adds:
  //   - i_slot2_valid: slot-2 must actually be firing this cycle.  Slot-2
  //     invalid means slot-1 is a NOP/branch/etc., or slot-2 doesn't fit.
  //   - halfword PC guard: slot-2 PC[1]=1 is only safe to predict when the
  //     BTB entry's compressed flag matches the live slot-2 instruction's
  //     compressed flag.  This relaxes the earlier stricter
  //     "btb_compressed_2 must be 1" check (which only allowed compressed
  //     slot-2 at a halfword PC) — native (32-bit) slot-2 is now allowed
  //     at a halfword PC too, provided the BTB entry was trained for the
  //     same size.  A size mismatch means the BTB was trained at this PC
  //     for a different alignment and the predicted target would mispredict
  //     anyway, so we suppress prediction in that case.
  //
  // Slot-2 has no RAS lookup (the one-branch-per-bundle rule keeps slot-2
  // invalid when slot-1
  // is a branch / call / return; the only RAS user is slot-1).  Slot-2's
  // prediction_used is purely BTB-driven.
  logic slot2_prediction_common;
  logic slot2_plus2_safe_taken;
  logic slot2_plus4_safe_taken;
  logic slot2_selected_safe_taken;
  // slot2_prediction_common reuses prediction_common but is computed
  // independently so the slot-2 cone doesn't pull in slot-1's
  // !i_pc[1] || btb_compressed term.
  assign slot2_prediction_common = prediction_common && i_slot2_valid;

  // Qualify the fixed +2 and +4 lookup results independently.  i_pc_2[1]
  // and i_pc_2_alt[1] are the exact candidate halfword identities; one is a
  // word address and the other a halfword address.  The strict halfword guard
  // remains unchanged: a candidate at PC[1]=1 is usable only when its BTB
  // entry was trained for that candidate's live instruction size.
  assign slot2_plus2_safe_taken = btb_predicted_taken_2_plus2 &&
                                  (!i_pc_2[1] ||
                                   (i_slot2_is_compressed_plus2 == btb_compressed_2_plus2));
  assign slot2_plus4_safe_taken = btb_predicted_taken_2_plus4 &&
                                  (!i_pc_2_alt[1] ||
                                   (i_slot2_is_compressed_plus4 == btb_compressed_2_plus4));

  // The late slot-1 size bit now selects between two completed one-bit
  // qualify results.  Target, hit, direction-index, and metadata selection
  // continue to use this same selector and therefore retain candidate identity.
  assign slot2_selected_safe_taken = i_slot2_pc_use_alt ?
      slot2_plus4_safe_taken : slot2_plus2_safe_taken;

  logic slot2_sel_btb_prediction;
  assign slot2_sel_btb_prediction = slot2_prediction_common && slot2_selected_safe_taken;

  // Final slot-2 prediction-used: same late-arrival gates as slot-1
  // (i_branch_taken, i_is_32bit_spanning, !i_stall).  These keep prediction
  // suppression aligned with the slot-1 path so a same-cycle branch
  // resolution / spanning event takes priority over a slot-2 BTB hit.
  assign o_slot2_prediction_used_for_pc =
      slot2_sel_btb_prediction && !i_branch_taken && !i_is_32bit_spanning;
  assign o_slot2_prediction_used = o_slot2_prediction_used_for_pc && !i_stall;
  assign o_slot2_btb_hit = btb_hit_2 && i_slot2_valid;
  assign o_slot2_predicted_taken = o_slot2_prediction_used;
  assign o_slot2_predicted_target = btb_predicted_target_2;

`ifndef SYNTHESIS
  // Equivalence oracle for the former select-then-qualify expression.  It
  // covers the selected candidate's counter, size metadata, strict halfword
  // predicate, and late selector without constraining the unselected lookup.
  logic slot2_sel_btb_prediction_legacy;
  logic slot2_selected_pc_is_halfword_legacy;
  logic slot2_selected_candidate_compressed;
  assign slot2_selected_pc_is_halfword_legacy = i_slot2_pc_use_alt ? i_pc_2_alt[1] : i_pc_2[1];
  assign slot2_selected_candidate_compressed = i_slot2_pc_use_alt ?
      i_slot2_is_compressed_plus4 : i_slot2_is_compressed_plus2;
  assign slot2_sel_btb_prediction_legacy = slot2_prediction_common &&
      (!slot2_selected_pc_is_halfword_legacy ||
       (i_slot2_is_compressed == btb_compressed_2)) &&
      dir_predicted_taken_2;

  // These state implications make the slot-2 kill simplification above exact.
  // They also guard the timing split: future changes must not allow slot-2 to
  // consume a prediction while either holdoff or registered slot-1 metadata is
  // live.
  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
      if (!$isunknown({slot2_sel_btb_prediction, slot2_sel_btb_prediction_legacy})) begin
        p_slot2_parallel_qualification_matches_legacy :
        assert (slot2_sel_btb_prediction == slot2_sel_btb_prediction_legacy);
      end
      if (slot2_prediction_common && !$isunknown(
              {i_slot2_is_compressed, slot2_selected_candidate_compressed}
          )) begin
        p_slot2_candidate_size_selector_identity :
        assert (i_slot2_is_compressed == slot2_selected_candidate_compressed);
      end
      p_btb_holdoff_implies_prediction_holdoff :
      assert (!o_btb_only_prediction_holdoff || o_prediction_holdoff);
      p_registered_metadata_implies_prediction_holdoff :
      assert (!o_prediction_used_r || o_prediction_holdoff);
      p_slot2_requires_clear_prediction_holdoff :
      assert (!o_slot2_prediction_used || !o_prediction_holdoff);
      p_slot2_requires_clear_btb_holdoff :
      assert (!o_slot2_prediction_used || !o_btb_only_prediction_holdoff);
      p_slot2_requires_clear_registered_metadata :
      assert (!o_slot2_prediction_used || !o_prediction_used_r);
    end
  end
`endif

endmodule : branch_prediction_controller
