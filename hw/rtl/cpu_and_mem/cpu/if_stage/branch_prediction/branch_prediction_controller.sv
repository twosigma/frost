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
 * IF branch-prediction control: BTB lookup, RAS call/return handling,
 * prediction gating, registered metadata, and C-extension holdoff. RAS targets
 * take priority over BTB targets for detected returns; sel_prediction marks an
 * actual redirect.
 *
 * Prediction outputs and gating controls are registered. The combinational BTB
 * result sees only registered holdoffs, keeping stall logic off the PC path.
 */
module branch_prediction_controller (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_stall_registered,
    // Fetch progress: a live window is valid, or a stall-replay bundle is
    // presented. With no progress, i_disable_branch_prediction suppresses new
    // predictions upstream. This input also holds the registered prediction
    // pipeline (metadata, pc_reg handoff, holdoffs), so a prediction consumed
    // on the last delivered cycle keeps its bookkeeping until the deferred
    // window arrives.
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

    // Slot-2 BTB lookup candidates. i_pc_2/i_pc_2_alt carry the pc_reg+2 and
    // pc_reg+4 addresses used for direction-predictor metadata. The live
    // slot-1 i_pc launches three single-address images one cycle before
    // i_pc_2_base is served, and each image splits its block-RAM payload from
    // its staged distributed-RAM tag. The ordinary +2 and +4 images cover the
    // same word. The rotated +2 image covers the successor word at the same
    // redirect latency. The one-hot candidate-valid inputs below qualify the
    // staged results, so the candidate identity stays the one IF chose.
    input logic [riscv_pkg::XLEN-1:0] i_pc_2,
    input logic [riscv_pkg::XLEN-1:0] i_pc_2_alt,
    input logic [riscv_pkg::XLEN-1:0] i_pc_2_base,
    // True only for the first live response after an unstalled fetch-invalid
    // gap. PC equality with an emitted slot-2 candidate is ordinary fixed-
    // latency lookahead and must not by itself transfer metadata ownership.
    // A fixed-latency live-taken/staged-not-taken disagreement is handled
    // separately below by suppressing the duplicate live owner.
    input logic                       i_lookup_lead_collapsed,
    input logic                       i_slot2_plus2_candidate_valid,
    input logic                       i_slot2_plus4_candidate_valid,
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
    // TIMING: the raw served-window verdict is the latest prediction-disable
    // input. Its two cofactors arrive early, prediction_common is built from
    // both, and the raw verdict picks between the finished results in the last
    // LUT. IF ties the non-covering cofactor to disabled.
    input logic i_disable_branch_prediction_wcs0,
    input logic i_disable_branch_prediction_wcs,
    input logic i_window_cannot_serve_raw,

    // BTB update interface (from EX stage)
    input logic                       i_btb_update,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_pc,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_target,
    input logic                       i_btb_update_taken,
    input logic                       i_btb_update_compressed,
    input logic                       i_btb_update_requires_pc_reg_handoff,
    // Direct early-recovery counter-RMW candidate.  The selected update port
    // above remains the sole source of BTB writes.
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

    // Bimodal direction-predictor training from commit, conditional branches
    // only.  The index carried with the branch names the entry to train; the
    // predictor keeps no global history and no carried predict-PC.
    input logic                               i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic                               i_dir_update_taken,

    // Combinational prediction outputs (for pc_controller next_pc selection)
    output logic                       o_predicted_taken,
    output logic [riscv_pkg::XLEN-1:0] o_predicted_target,

    // Registered prediction outputs (for pipeline stage alignment)
    output logic o_prediction_used_r,  // Prediction was used (registered)
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

    // Slot-2 prediction outputs.  Combinational: they feed pc_controller's
    // slot-2 redirect path and the slot-2 IF→PD metadata.
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

    // Decoupled bimodal direction, not gated by btb_hit, registered to align
    // with the prediction metadata carried to PD.  PD redirects on a BTB miss
    // when this predicts taken (any offset sign).  The live companions cover a
    // variable-latency response that collapses the normal lookup lead.
    output logic o_dir_predicted_taken,
    output logic o_dir_predicted_taken_live,
    // Predict-time bimodal index to carry with each fetched branch
    // (slot-1 registered to align with the prediction metadata; slot-2
    // combinational off its own lookup PC) and hand back at commit for training.
    output logic [riscv_pkg::BpDirIdxBits-1:0] o_dir_idx,
    output logic [riscv_pkg::BpDirIdxBits-1:0] o_dir_idx_live,
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

  // Target, hit, direction index, and selected metadata all follow one
  // candidate identity. The +4 arm is already validity-qualified, and the
  // one-hot contract asserted below makes low the safe default when there is
  // no live slot-2 candidate.
  logic            slot2_pc_use_alt;
  assign slot2_pc_use_alt = i_slot2_plus4_candidate_valid;

  // TIMING: the BTB update bundle is registered here before it reaches the
  // predictor. Upstream it is the recovery unit's one-LUT priority mux over
  // three registered commit records (mispredict / correct-branch slot 1 /
  // slot 2) plus the early-recovery override, and the predictor turns it
  // straight into a read-modify-write of its LUTRAM tables (tag read,
  // compare, counter step, write): post-place on x3 the recovery -> predictor
  // hop plus that RMW was a WNS-edge family (~3.6k paths). Training now
  // lands one cycle later, which only a prediction made in that single cycle
  // can observe; consecutive updates keep their relative order (both delayed
  // alike), so the RMW hazards are unchanged. The direction predictor keeps
  // its own same-cycle training input.
  logic                       btb_update_q;
  logic [riscv_pkg::XLEN-1:0] btb_update_pc_q;
  logic [riscv_pkg::XLEN-1:0] btb_update_target_q;
  logic                       btb_update_taken_q;
  logic                       btb_update_compressed_q;
  logic                       btb_update_requires_pc_reg_handoff_q;
  logic                       btb_early_update_active_q;
  logic [riscv_pkg::XLEN-1:0] btb_early_update_pc_q;
  logic                       btb_early_update_taken_q;
  logic [riscv_pkg::XLEN-1:0] btb_late_update_pc_q;
  logic                       btb_late_update_taken_q;
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      btb_update_q              <= 1'b0;
      btb_early_update_active_q <= 1'b0;
    end else begin
      btb_update_q              <= i_btb_update;
      btb_early_update_active_q <= i_btb_early_update_active;
    end
    btb_update_pc_q                      <= i_btb_update_pc;
    btb_update_target_q                  <= i_btb_update_target;
    btb_update_taken_q                   <= i_btb_update_taken;
    btb_update_compressed_q              <= i_btb_update_compressed;
    btb_update_requires_pc_reg_handoff_q <= i_btb_update_requires_pc_reg_handoff;
    btb_early_update_pc_q                <= i_btb_early_update_pc;
    btb_early_update_taken_q             <= i_btb_early_update_taken;
    btb_late_update_pc_q                 <= i_btb_late_update_pc;
    btb_late_update_taken_q              <= i_btb_late_update_taken;
  end

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

      // The live fetch PC launches the slot-2 rows one cycle ahead; pc_reg is
      // the current served-base tag/index used to select the staged response.
      .i_pc_2_lookup_base(i_pc),
      .i_pc_2_base(i_pc_2_base),
      .i_pc_2_use_alt(slot2_pc_use_alt),
      .o_predicted_taken_2_plus2(btb_predicted_taken_2_plus2),
      .o_predicted_taken_2_plus4(btb_predicted_taken_2_plus4),
      .o_btb_compressed_2_plus2(btb_compressed_2_plus2),
      .o_btb_compressed_2_plus4(btb_compressed_2_plus4),
      .o_btb_hit_2(btb_hit_2),
      .o_predicted_taken_2(btb_predicted_taken_2),
      .o_predicted_target_2(btb_predicted_target_2),
      .o_btb_compressed_2(btb_compressed_2),
      .o_btb_requires_pc_reg_handoff_2(btb_requires_pc_reg_handoff_2),

      // Update from EX stage, through the staging registers above
      .i_update(btb_update_q),
      .i_update_pc(btb_update_pc_q),
      .i_update_target(btb_update_target_q),
      .i_update_taken(btb_update_taken_q),
      .i_update_compressed(btb_update_compressed_q),
      .i_update_requires_pc_reg_handoff(btb_update_requires_pc_reg_handoff_q),
      .i_early_update_active(btb_early_update_active_q),
      .i_early_update_pc(btb_early_update_pc_q),
      .i_early_update_taken(btb_early_update_taken_q),
      .i_late_update_pc(btb_late_update_pc_q),
      .i_late_update_taken(btb_late_update_taken_q)
  );

  // ===========================================================================
  // Direction Predictor (decoupled bimodal): the BTB-miss direction
  // ===========================================================================
  // Supplies a taken/not-taken direction independent of the BTB, so a
  // conditional branch that misses the BTB still has a trained direction for
  // the PD-stage computed-target redirect.  A branch that hits the BTB takes
  // both its target and its direction from the BTB.  Trained at commit on
  // conditional branches only, at the predict-time index carried with the
  // branch.
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

  // Registered decoupled bimodal direction, snapshot in the same ~i_stall
  // stage as the registered prediction metadata (o_predicted_target_r,
  // prediction_used_r) so the bit carried to PD aligns with that instruction.
  // The source is dir_taken, not dir_predicted_taken: the latter is gated by
  // btb_hit and would read 0 on a miss.
  logic dir_taken_snapshot_r;
  assign o_dir_predicted_taken = dir_taken_snapshot_r;

  // Carry the predict-time bimodal index.  Slot-1 registers it in the same
  // stage as dir_taken_snapshot_r, which aligns it with the prediction metadata
  // reaching from_if_to_pd.  Slot-2's prediction is combinational, so its index
  // is combinational off the selected slot-2 lookup PC (i_pc_2 or i_pc_2_alt).
  logic [riscv_pkg::XLEN-1:0] selected_slot2_pc;
  assign selected_slot2_pc = slot2_pc_use_alt ? i_pc_2_alt : i_pc_2;
  logic selected_slot2_candidate_compressed;
  assign selected_slot2_candidate_compressed = slot2_pc_use_alt ?
      i_slot2_is_compressed_plus4 : i_slot2_is_compressed_plus2;

  // A variable-latency response can collapse the normal one-request lookup
  // lead until the live slot-1 PC names the instruction already emitted in
  // slot 2.  The emitted instruction is the unique metadata owner.  If its
  // staged BTB image missed, transfer an exact live BTB hit to slot 2 rather
  // than either dropping the useful redirect or registering it against the
  // following slot-1 packet.
  logic slot1_aliases_emitted_slot2_plus2;
  logic slot1_aliases_emitted_slot2_plus4;
  logic slot1_aliases_emitted_slot2;
  logic fixed_lead_live_taken_aliases_emitted_slot2;
  logic slot2_live_fallback_hit;
  logic slot2_live_fallback_size_safe;
  logic slot2_live_fallback_select;
  assign slot1_aliases_emitted_slot2_plus2 =
      i_slot2_valid && i_slot2_plus2_candidate_valid && (i_pc == i_pc_2);
  assign slot1_aliases_emitted_slot2_plus4 =
      i_slot2_valid && i_slot2_plus4_candidate_valid && (i_pc == i_pc_2_alt);
  assign slot2_live_fallback_size_safe =
      !i_pc[1] || (selected_slot2_candidate_compressed == btb_compressed);

  logic [riscv_pkg::BpDirIdxBits-1:0] pred_idx_snapshot_r;
  assign o_dir_idx      = pred_idx_snapshot_r;
  assign o_dir_idx_live = dir_pred_idx;
  assign o_dir_idx_2    = selected_slot2_pc[riscv_pkg::BpDirIdxBits:1];

  // BTB-hit direction comes from the BTB's own 2-bit counter (btb_predicted_taken).
  // The decoupled bimodal (dir_taken) serves only the PD BTB-miss redirect,
  // carried to PD as o_dir_predicted_taken.  It never overrides a BTB hit.
  logic dir_predicted_taken;
  logic dir_predicted_taken_2;
  assign dir_predicted_taken = btb_predicted_taken;
  assign dir_predicted_taken_2 = btb_predicted_taken_2;

  // The slot-1 sidebands must not describe the following packet while the
  // live lookup is being claimed by emitted slot 2. Taken fallbacks still need
  // the branch to flow through IF/PD/ID, but slot 2 owns that handoff directly.
  assign o_dir_predicted_taken_live = dir_taken && !slot1_aliases_emitted_slot2;
  assign o_prediction_requires_pc_reg_handoff = dir_predicted_taken && !slot1_aliases_emitted_slot2;

  // ===========================================================================
  // RAS (Return Address Stack) Instance
  // ===========================================================================
  // Return-address prediction for JALR returns.  ras_detector classifies the
  // current instruction as a call, a return, or a coroutine swap, and
  // return_address_stack holds the pushed link addresses.

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

  // Compute prediction_allowed for BTB.  At PC[1]=1, only an entry trained as
  // compressed can belong to slot 1; this is BTB-entry provenance, not a test
  // of the assembled live instruction.  RAS returns are classified from that
  // assembled instruction and therefore do not use this BTB size qualifier.
  // A real spanning instruction is handled independently by the narrow final
  // use/pop gates below.
  // prediction_holdoff blocks as well: after a prediction redirects the PC,
  // the next cycle carries stale instruction data, and a BTB prediction made
  // on that data would keep prediction_holdoff high forever.
  //
  // Keep the shared BTB/RAS allow cone independent of late i_branch_taken and
  // i_is_32bit_spanning.  Branch resolution remains a final-use gate;
  // spanning suppresses BTB use there and qualifies RAS selection/pop beside
  // the output.  Neither signal fans backward through prediction_common or
  // the wide target dataplane.  This makes is_32bit_spanning (which depends on
  // BRAM → is_compressed) parallel with the prediction logic instead of
  // serial, cutting ~5 LUT levels from the critical path:
  //   BEFORE: BRAM → is_compressed → is_32bit_spanning → prediction_common → RAS → PC
  //   AFTER:  BRAM → is_32bit_spanning ─┐
  //           registered → prediction_common → sel_prediction ─ AND → prediction_used → PC
  logic prediction_common;
  logic prediction_allowed_stable;
  // Use i_stall_registered to break the 14-level path
  // rob_valid → commit_en → mret_start → id_valid → stall → prediction_common → RAS WE.
  // During the first stall cycle (stall=1, stall_registered=0), a prediction may fire.
  // This is safe: MRET/trap stalls flush the pipeline next cycle, and checkpoint restore
  // corrects any spurious RAS push/pop. Non-trap stalls have short paths that arrive
  // well before the clock edge regardless.
  logic prediction_common_wcs0, prediction_common_wcs;
  assign prediction_common_wcs0 = !i_reset && !i_trap_taken && !i_mret_taken &&
                                  !i_stall_registered && !i_any_holdoff_safe &&
                                  !o_prediction_holdoff && !i_use_instr_buffer &&
                                  !i_disable_branch_prediction_wcs0;
  assign prediction_common_wcs = !i_reset && !i_trap_taken && !i_mret_taken &&
                                 !i_stall_registered && !i_any_holdoff_safe &&
                                 !o_prediction_holdoff && !i_use_instr_buffer &&
                                 !i_disable_branch_prediction_wcs;
  assign prediction_common = i_window_cannot_serve_raw ? prediction_common_wcs :
                                                         prediction_common_wcs0;
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              prediction_common,
              i_disable_branch_prediction,
              i_reset,
              i_trap_taken,
              i_mret_taken,
              i_stall_registered,
              i_any_holdoff_safe,
              o_prediction_holdoff,
              i_use_instr_buffer
            }
        )) begin
      p_prediction_common_cofactors_exact :
      assert (prediction_common == (!i_reset && !i_trap_taken && !i_mret_taken &&
                                    !i_stall_registered && !i_any_holdoff_safe &&
                                    !o_prediction_holdoff && !i_use_instr_buffer &&
                                    !i_disable_branch_prediction));
    end
  end
`endif
  assign prediction_allowed_stable = prediction_common &&
                                     !slot1_aliases_emitted_slot2 &&
                                     (!i_pc[1] || btb_compressed);

  logic prediction_allowed;
  assign prediction_allowed = prediction_allowed_stable;

  // RAS returns use the assembled instruction and therefore do not need the
  // BTB entry's halfword-size qualification.  The production IF stage fetches
  // a 64-bit window, so a native return at PC[1]=1 is fully present; generic
  // integrations still block any real spanning case at the final use/pop
  // gates below.  Keeping live PC[1] out of this decision also prevents it
  // from fanning through the 64-bit RAS/BTB target dataplane.
  logic ras_prediction_allowed_stable;
  assign ras_prediction_allowed_stable = prediction_common && !slot1_aliases_emitted_slot2;

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
      // Calls push independently of prediction_allowed, so gate every RAS
      // classification at the ownership boundary, not only the pop select.
      .i_is_call(ras_is_call && !slot1_aliases_emitted_slot2),
      .i_is_return(ras_is_return && !slot1_aliases_emitted_slot2),
      .i_is_coroutine(ras_is_coroutine && !slot1_aliases_emitted_slot2),
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
  // sel_prediction decides when a BTB prediction redirects the PC.
  // Predictions are blocked:
  //
  //   - During reset, trap, mret, stall (higher priority control flow)
  //   - During branch taken from EX (actual resolution overrides prediction)
  //   - During holdoff cycles (instruction data is stale)
  //   - When the served window does not cover the instruction packet
  //   - While the instruction buffer is in use
  //   - For halfword-aligned PCs unless the BTB entry is marked compressed
  //   - When branch prediction is disabled (verification mode)
  //
  // TIMING: Uses i_any_holdoff_safe (registered) to break path from branch_taken.

  // sel_prediction for BTB only (without RAS)
  logic sel_btb_prediction;
  assign sel_btb_prediction = prediction_allowed && dir_predicted_taken;

  // sel_prediction for RAS (for returns, RAS takes priority over BTB).  The
  // final spanning qualifier keeps the module safe if it is ever reused with
  // a fetch window narrower than the current 64-bit production interface.
  logic ras_target_candidate;
  assign ras_target_candidate = ras_valid;
  logic sel_ras_prediction;
  assign sel_ras_prediction = ras_prediction_allowed && ras_valid && !i_is_32bit_spanning;

  // Combined prediction selection: RAS takes priority for returns
  logic sel_prediction;
  assign sel_prediction = sel_ras_prediction || sel_btb_prediction;

  // Prediction use must still be blocked when branch resolution or spanning
  // takes priority this cycle. Keep branch_taken and is_32bit_spanning as final
  // gates to keep them out of the deep prediction_common → RAS → sel_prediction cone.
  logic prediction_used_effective;
  logic prediction_used_for_pc;
  // Mark a prediction used only when IF can consume it. A prediction that
  // fires on the first stall cycle is a hazard for halfword target handoff:
  // the branch bytes can keep moving through IF while the PC/metadata
  // bookkeeping stays behind by one instruction.
  assign prediction_used_for_pc = sel_prediction && !i_branch_taken && !i_is_32bit_spanning;
  assign prediction_used_effective = prediction_used_for_pc && !i_stall;

  // Combinational prediction for pc_controller.  RAS prediction takes priority
  // over the BTB for returns.  Select the 64-bit target from candidate
  // provenance, not from prediction_common: global prediction disables and
  // front-end holdoffs only invalidate the control result, and consumers ignore
  // this payload when prediction_used is low.  This preserves the selected
  // target on every valid prediction while keeping late serialization controls
  // out of the wide target dataplane.
  assign o_predicted_taken = sel_ras_prediction || dir_predicted_taken;
  assign o_predicted_target = ras_target_candidate ? ras_target : btb_predicted_target;
  assign o_prediction_used = prediction_used_effective;
  assign o_prediction_used_for_pc = prediction_used_for_pc;

  logic predicted_target_is_halfword;
  assign predicted_target_is_halfword = o_predicted_target[1];
  assign o_control_flow_to_halfword_pred = prediction_used_effective &&
                                           predicted_target_is_halfword;

`ifndef SYNTHESIS
  // Legacy target selection used the validity-qualified RAS select.  Raw RAS
  // provenance may change the payload on a blocked cycle, but never on a
  // prediction that can steer the PC.
  logic [XLEN-1:0] predicted_target_valid_legacy;
  assign predicted_target_valid_legacy = sel_ras_prediction ? ras_target : btb_predicted_target;
  always_comb begin
    if (!$isunknown(
            {prediction_used_for_pc, o_predicted_target, predicted_target_valid_legacy}
        )) begin
      p_valid_predicted_target_matches_legacy :
      assert (!prediction_used_for_pc || (o_predicted_target == predicted_target_valid_legacy));
    end
  end
`endif

  // RAS prediction outputs (for pipeline passthrough)
  assign o_ras_predicted = sel_ras_prediction;
  assign o_ras_predicted_target = ras_target;
  assign o_ras_checkpoint_tos = ras_checkpoint_tos;
  assign o_ras_checkpoint_valid_count = ras_checkpoint_valid_count;

  // ===========================================================================
  // Prediction Registration
  // ===========================================================================
  // Register prediction outputs for pipeline timing alignment.
  // For a prediction made at PC_N in cycle N:
  //   - Cycle N: BTB lookup, sel_prediction computed, PC redirected
  //   - Cycle N+1: Instruction at PC_N arrives, needs registered prediction metadata
  //
  // The registered taken flag is set only when the prediction was used.
  // Passing the raw BTB output on a blocked cycle (a halfword-aligned PC, say)
  // makes EX believe a prediction happened and skip the redirect.

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
  // tracks only the predictions that were used.
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
      // pc_reg handoff the same way a flush does: they outrank it in the
      // next_pc mux, so the prediction never owns the fetch stream.
      // pc_controller's redirect_kill_pending_q and o_slot2_redirect_q
      // suppressions are one-cycle pulses that are not stall-aware, while this
      // register is stall-held. A stall starting in the kill cycle used to let
      // the dead prediction's pc_reg handoff fire on release, desyncing pc_reg
      // from the fetched bytes (stale words executed under wrong PCs; see
      // test_pd_redirect_with_stall_kills_registered_prediction_handoff).
      //
      // Kill only the handoff here. Prediction metadata must survive an
      // unrelated PD/slot-2 redirect or the in-flight branch loses its
      // already-redirected marker and PD redirects to the same target again.
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
      // Register the combined RAS+BTB target used for the redirect. EX
      // compares against this value.
      o_predicted_target_r <= o_predicted_target;
      // Snapshot the decoupled bimodal direction and its predict-time index in
      // the same stage so both carried values align with the instruction.
      dir_taken_snapshot_r <= slot1_aliases_emitted_slot2 ? 1'b0 : dir_taken;
      pred_idx_snapshot_r  <= slot1_aliases_emitted_slot2 ? '0 : dir_pred_idx;
    end
  end

  // ===========================================================================
  // Prediction Holdoff Generation
  // ===========================================================================
  // A one-cycle delayed signal after a prediction, for c_ext_state.  It tells
  // c_ext_state to clear stale spanning/buffer state after the branch
  // instruction processes and before the predicted target arrives.
  //
  // Unlike control_flow_holdoff, this does not block is_compressed detection,
  // which the instruction at the branch PC still needs.
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
  // Track when the BTB, and not the RAS, made the prediction.  The two predict
  // at different points:
  //   - BTB predicts from the PC (fetch address) before the instruction arrives
  //   - RAS predicts from instruction content after the instruction arrives
  //
  // So during prediction_holdoff:
  //   - If the BTB predicted, the instruction at the predicted PC arrives and
  //     is valid, and the RAS may push if that instruction is a call
  //   - If the RAS predicted, the next sequential instruction arrives and is
  //     stale, so RAS detection is blocked to prevent spurious pushes
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
  // Slot-2 prediction reuses prediction_common, so it inherits slot-1's
  // per-cycle blockers: reset, trap, mret, holdoff, non-covering window,
  // instruction buffer, and prediction disabled.  On top of those:
  //   - i_slot2_valid: slot-2 must be firing this cycle.  Slot-2 invalid
  //     means slot-1 is a NOP or a branch, or slot-2 does not fit.
  //   - halfword PC guard: a slot-2 PC[1]=1 is safe to predict only when the
  //     BTB entry's compressed flag matches the live slot-2 instruction's
  //     compressed flag.  This relaxes the earlier "btb_compressed_2 must be
  //     1" check, which allowed only a compressed slot-2 at a halfword PC.
  //     A native 32-bit slot-2 is now allowed there too, provided the BTB
  //     entry was trained for the same size.  A size mismatch means the BTB
  //     was trained at this PC for a different alignment, so its target would
  //     mispredict and the prediction is suppressed.
  //
  // Slot-2 has no RAS lookup: the one-branch-per-bundle rule keeps slot-2
  // invalid when slot-1 is a branch, call, or return, so slot-1 is the only
  // RAS user.  Slot-2's prediction_used comes from the BTB alone.
  logic slot2_prediction_common;
  logic slot2_plus2_safe_taken;
  logic slot2_plus4_safe_taken;
  logic slot2_candidate_valid;
  logic slot2_plus2_candidate_safe_taken;
  logic slot2_plus4_candidate_safe_taken;
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

  // Absorb candidate identity into each completed one-bit result, then OR the
  // mutually exclusive arms.  This is exactly the old select-then-qualify
  // behavior when slot-2 is valid, but removes raw slot-1 compression from the
  // late prediction gate.  The full IF-stage i_slot2_valid remains authoritative
  // for holdoff/flush/replay suppression.
  assign slot2_candidate_valid = i_slot2_plus2_candidate_valid || i_slot2_plus4_candidate_valid;
  assign slot2_plus2_candidate_safe_taken = i_slot2_plus2_candidate_valid && slot2_plus2_safe_taken;
  assign slot2_plus4_candidate_safe_taken = i_slot2_plus4_candidate_valid && slot2_plus4_safe_taken;

  // A fixed-latency lookup normally names the instruction concurrently
  // emitted in slot 2. Usually the staged slot-2 image and the live slot-1
  // image agree, so slot 2 remains authoritative and the redundant live
  // proposal is harmless. A just-trained BTB row can make only the live image
  // taken, however. Treating that late verdict as a future slot-1 owner arms
  // pending metadata for an instruction that has already dispatched, causing
  // a duplicate replay under stale bytes. Suppress that live owner rather
  // than retroactively predicting the already-emitted packet; the branch
  // resolves normally this one training-transition cycle.
  assign fixed_lead_live_taken_aliases_emitted_slot2 =
      !i_lookup_lead_collapsed &&
      (slot1_aliases_emitted_slot2_plus2 || slot1_aliases_emitted_slot2_plus4) &&
      btb_hit && dir_predicted_taken &&
      !(slot2_plus2_candidate_safe_taken || slot2_plus4_candidate_safe_taken);
  assign slot1_aliases_emitted_slot2 =
      (slot1_aliases_emitted_slot2_plus2 || slot1_aliases_emitted_slot2_plus4) &&
      (i_lookup_lead_collapsed || fixed_lead_live_taken_aliases_emitted_slot2);

  // Only a collapsed fetch lead transfers a live hit into slot 2. The fixed-
  // latency disagreement above falls back to normal branch resolution.
  assign slot2_live_fallback_hit =
      i_lookup_lead_collapsed && slot1_aliases_emitted_slot2 && !btb_hit_2 && btb_hit;

  // The staged lookup remains authoritative whenever it hits. On a staged
  // miss, an exact live hit for the same emitted instruction supplies both
  // metadata and (when taken) the redirect. A live not-taken hit is still a
  // real BTB hit, so EX can distinguish it from a direction-only BTB miss.
  assign slot2_live_fallback_select =
      prediction_common && slot2_live_fallback_hit &&
      slot2_live_fallback_size_safe && dir_predicted_taken;

  logic slot2_sel_btb_prediction;
  assign slot2_sel_btb_prediction =
      (slot2_prediction_common &&
       (slot2_plus2_candidate_safe_taken || slot2_plus4_candidate_safe_taken)) ||
      slot2_live_fallback_select;

  // Final slot-2 prediction-used: same late-arrival gates as slot-1
  // (i_branch_taken, i_is_32bit_spanning, !i_stall).  These keep prediction
  // suppression aligned with the slot-1 path so a same-cycle branch
  // resolution / spanning event takes priority over a slot-2 BTB hit.
  assign o_slot2_prediction_used_for_pc =
      slot2_sel_btb_prediction && !i_branch_taken && !i_is_32bit_spanning;
  assign o_slot2_prediction_used = o_slot2_prediction_used_for_pc && !i_stall;
  assign o_slot2_btb_hit =
      (btb_hit_2 && i_slot2_valid && slot2_candidate_valid) ||
      slot2_live_fallback_hit;
  assign o_slot2_predicted_taken = o_slot2_prediction_used;
  assign o_slot2_predicted_target =
      slot2_live_fallback_hit ? btb_predicted_target : btb_predicted_target_2;

`ifndef SYNTHESIS
  // Equivalence oracle for the former select-then-qualify expression.  It
  // covers the selected candidate's counter, size metadata, strict halfword
  // predicate, and late selector without constraining the unselected lookup.
  logic slot2_sel_btb_prediction_legacy;
  logic slot2_selected_pc_is_halfword_legacy;
  assign slot2_selected_pc_is_halfword_legacy = slot2_pc_use_alt ? i_pc_2_alt[1] : i_pc_2[1];
  assign slot2_sel_btb_prediction_legacy = slot2_prediction_common && slot2_candidate_valid &&
      (!slot2_selected_pc_is_halfword_legacy ||
       (i_slot2_is_compressed == btb_compressed_2)) &&
      dir_predicted_taken_2;

  // These state implications make the slot-2 kill simplification above exact.
  // They also guard the timing split: future changes must not allow slot-2 to
  // consume a prediction while either holdoff or registered slot-1 metadata is
  // live.
  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
      if (!$isunknown(
              {i_slot2_valid, i_slot2_plus2_candidate_valid, i_slot2_plus4_candidate_valid}
          )) begin
        p_slot2_candidate_valids_are_onehot :
        assert ($onehot0({i_slot2_plus4_candidate_valid, i_slot2_plus2_candidate_valid}));
        p_live_slot2_has_exactly_one_candidate :
        assert (!i_slot2_valid || $onehot(
            {i_slot2_plus4_candidate_valid, i_slot2_plus2_candidate_valid}
        ));
        p_slot2_target_selector_uses_plus4_valid :
        assert (slot2_pc_use_alt == i_slot2_plus4_candidate_valid);
      end
      if (!$isunknown(
              {
                slot2_sel_btb_prediction,
                slot2_sel_btb_prediction_legacy,
                slot2_live_fallback_select
              }
          )) begin
        p_slot2_parallel_qualification_plus_fallback_exact :
        assert (slot2_sel_btb_prediction ==
                (slot2_sel_btb_prediction_legacy || slot2_live_fallback_select));
      end
      if (slot2_prediction_common && !$isunknown(
              {i_slot2_is_compressed, selected_slot2_candidate_compressed}
          )) begin
        p_slot2_candidate_size_selector_identity :
        assert (i_slot2_is_compressed == selected_slot2_candidate_compressed);
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
      p_registered_holdoff_blocks_slot2_pc_redirect :
      assert (!i_any_holdoff_safe || !o_slot2_prediction_used_for_pc);
      if (!$isunknown(
              {
                slot1_aliases_emitted_slot2,
                o_prediction_used,
                o_prediction_used_for_pc,
                o_ras_predicted
              }
          )) begin
        p_emitted_slot2_has_unique_slot1_prediction_owner :
        assert (!slot1_aliases_emitted_slot2 ||
                (!o_prediction_used && !o_prediction_used_for_pc && !o_ras_predicted));
      end
      if (!$isunknown({slot2_live_fallback_hit, o_slot2_btb_hit})) begin
        p_live_fallback_hit_is_carried_by_slot2 :
        assert (!slot2_live_fallback_hit || o_slot2_btb_hit);
      end
      if (!$isunknown(
              {
                fixed_lead_live_taken_aliases_emitted_slot2,
                o_prediction_used,
                o_prediction_used_for_pc,
                o_ras_predicted,
                slot2_live_fallback_hit
              }
          )) begin
        p_fixed_lead_disagreement_has_no_duplicate_live_owner :
        assert (!fixed_lead_live_taken_aliases_emitted_slot2 ||
                (!o_prediction_used && !o_prediction_used_for_pc &&
                 !o_ras_predicted && !slot2_live_fallback_hit));
      end
    end
  end
`endif

endmodule : branch_prediction_controller
