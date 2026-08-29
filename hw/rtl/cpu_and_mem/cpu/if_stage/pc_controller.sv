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
  IF program-counter controller. control_flow_tracker generates stale-cycle
  holdoffs; pc_increment_calculator computes C-extension and two-wide advances
  in parallel. The final flat mux prioritizes reset, trap, a FENCE-class
  frontend flush (FENCE.I, SFENCE.VMA, or translation-affecting CSR
  serialization), branch,
  PD redirect, hold, prediction, then sequential advance. Mid-32-bit correction
  is disabled for 64-bit fetch.

  Branch/jump redirects (JAL, JALR, conditional branches) arrive on the
  i_branch_taken/i_branch_target interface only on misprediction recovery
  (early or commit-time, synthesized by ex_comb_synthesizer); correctly
  predicted branches commit without a redirect here.
*/
module pc_controller #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_stall_registered,
    // Fetch progress: live window valid OR the stall-replay bundle is being
    // presented (see if_stage).  When low, PC and the pending-prediction walk
    // freeze (hold arms in the muxes + fetch_stall gating below); backend
    // redirects still land.  The provider re-serves the owed fetch address
    // while o_pc holds, so no ask is ever skipped.
    input logic i_fetch_progress,
    input logic i_flush,  // Pipeline flush - block state updates from garbage instructions
    // Registered FENCE-class frontend flush pulse. This covers FENCE.I,
    // SFENCE.VMA, and translation-affecting CSR serialization on one interface.
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,

    // Branch/Jump from EX stage (includes JAL, JALR, and all conditional branches)
    input logic            i_branch_taken,
    input logic [XLEN-1:0] i_branch_target,

    // PD backward-branch heuristic redirect (from pd_stage)
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    input logic i_window_cannot_serve,  // Served window cannot hold pc_reg -> resteer+hold
    // Raw window-cannot-serve (UNGATED by sel_nop) -- the exact predecessor-drop
    // condition (see the pending-prediction load-drop fix below).  Narrows the
    // immediate-predecessor carve-out to fire ONLY when the load would actually
    // be dropped (wcs=1), not at the ~50k benign wcs=0 dual-issue sites.
    input logic i_window_cannot_serve_raw,

    // Trap control
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,

    // C-extension state
    input logic i_is_compressed,  // Combinational (for spanning detection, etc.)
    input logic i_is_compressed_for_pc,  // Registered (TIMING OPTIMIZATION: for PC increment)

    // 2-wide bundle metadata.  Slot-2 fires behind both RVC and native 32-bit
    // slot-1s, so valid bundles advance by +4, +6, or +8.  When slot-2 is
    // invalid, this falls back to the 1-wide +2/+4 advance.
    input logic i_slot2_valid,
    input logic i_slot2_is_compressed,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // sel_nop=0 / sel_nop=1 cofactors of the two selects above (if_stage);
    // the merged selects only feed the calculator's sim reference now.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,

    // Branch prediction (from branch_prediction_controller)
    input logic i_predicted_taken,  // BTB predicts taken (combinational)
    input logic [XLEN-1:0] i_predicted_target,  // Predicted target address (combinational)
    input logic [XLEN-1:0] i_predicted_target_r,  // Predicted target address (registered)
    input logic i_prediction_used,  // Prediction actually used this cycle
    input logic i_prediction_used_for_pc,  // Stall-ungated select for PC D mux only
    input logic i_ras_predicted,  // Prediction came from RAS/return detection
    input logic i_sel_prediction_r,  // Registered prediction used (for pc_reg)
    // Predicted op must still execute in IF/PD/ID
    input logic i_prediction_requires_pc_reg_handoff,
    input logic i_prediction_holdoff,  // One cycle after prediction (for pc_increment)
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_prediction_used_from_buffer,  // Current prediction came from IF buffer
    input logic i_sel_nop,

    // Slot-2 BTB prediction redirect (dual-port BTB).  Behaves
    // analogously to pd_redirect: the slot-2 lookup happens at cycle N+1
    // when the slot-2 instruction is in IF, but BRAM at cycle N+1 was
    // already fetching the sequential next bundle, so cycle N+2 must be
    // NOP'd as wrong-path.  A taken slot-2 prediction redirects both pc
    // and pc_reg to the slot-2 target immediately (just like pd_redirect),
    // and o_slot2_redirect_q tracks the bubble cycle for the if_stage
    // sel_nop expression.
    input  logic            i_slot2_prediction_used,
    // Slot-2 PC-mux arm select (no late !i_branch_taken term; see above).
    input  logic            i_slot2_prediction_used_for_pc,
    input  logic [XLEN-1:0] i_slot2_predicted_target,
    output logic            o_slot2_redirect_q,

    // Outputs
    output logic [XLEN-1:0] o_pc,
    output logic [XLEN-1:0] o_pc_reg,
    output logic o_control_flow_change,
    output logic o_control_flow_holdoff,
    output logic o_control_flow_to_halfword,
    output logic o_control_flow_to_halfword_r,
    output logic o_reset_holdoff,
    output logic o_any_holdoff,
    output logic o_any_holdoff_safe,
    output logic o_mid_32bit_correction,
    output logic o_pending_prediction_active,
    output logic o_pending_prediction_target_handoff,
    output logic o_pending_prediction_holdoff,
    // Its raw-WCS=0 / raw-WCS=1 cofactors: the branch-prediction enable takes
    // the raw verdict as its last input instead of through this hold.
    output logic o_pending_prediction_holdoff_wcs0,
    output logic o_pending_prediction_holdoff_wcs,
    output logic o_pending_prediction_fetch_holdoff,
    // Exact i_window_cannot_serve_raw=0 cofactor of the fetch holdoff. IF uses
    // it to absorb the raw mismatch at sel_nop's final OR.
    output logic o_pending_prediction_fetch_holdoff_wcs0,
    // Exact i_window_cannot_serve_raw=1 cofactor of the fetch holdoff. IF uses
    // it to build the window-resteer qualifier in parallel with the live
    // served-window comparison.
    output logic o_pending_prediction_fetch_holdoff_wcs,
    output logic o_pending_prediction_target_holdoff,
    // Pending-prediction kill (for prediction_metadata_tracker's pending-saved
    // metadata).  Asserted on every event that kills the pending-prediction
    // FETCH state here without the normal target-handoff consume: the redirect
    // clear list of the pending-valid flop, plus the stale walk-past clear.
    // The tracker's pending-saved metadata is the carried twin of that fetch
    // state and must die with it: metadata claiming "front-end already
    // redirected" may never outlive the redirect itself.  Otherwise a later
    // replay attaches it to the re-fetched instruction -- for a predicted jal
    // whose pending state a PD redirect killed, the jal re-emits carrying its
    // own (correct) target as "already predicted", the ROB sees a correctly
    // predicted jal, and the lost fetch redirect is never recovered (the
    // taken-branch -> jal-at-dword+4 call-skip bug).
    output logic o_pending_prediction_redirect_kill,
    // Phase 3 M5: the next-pc mux output and its flop enable, for the
    // instruction MMU's PA shadows (looked up combinationally on next_pc,
    // registered beside o_pc), plus "next_pc holds at o_pc by mux
    // selection" (no redirect arm fired and there is no fetch progress),
    // which qualifies the shadow's registered next-page lookup key. An
    // unresolved translation stalls the whole front end (pipeline_ctrl.stall)
    // rather than holding pc here, so the fetch lead is never disturbed.
    output logic [XLEN-1:0] o_next_pc,
    output logic o_next_pc_holds,
    output logic o_pc_update_en,
    // The selector's arms, for the instruction MMU: the one-hot winner,
    // which arms carry o_pc + d (0 <= d < 16, judged from pc's own
    // translation), and every other arm's EARLY value (its operand before
    // the selection), so the shadow's verdict is a one-hot select of 1-bit
    // per-arm results instead of a lookup behind the 64-bit mux.
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_sel,
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_seq,
    output logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] o_npc_cmp_val,
    // Every arm's actual value, for the IMMU's per-arm physical-address
    // candidates (next_pc is the one-hot select of these).
    output logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] o_npc_val,
    // For the o_npc_seq arms: the riscv_pkg::fetch_verdict of the arm's
    // value, predecoded on the PC-advance path (pc_increment_calculator) so
    // the immu never derives it from the late sequential PC.
    output riscv_pkg::fetch_verdict_t [riscv_pkg::PcNextArms-1:0] o_npc_seq_verdict
);

  // ===========================================================================
  // Control Flow Tracker - Holdoff Signal Generation
  // ===========================================================================
  // Track control flow changes and generate holdoff signals for stale cycles.
  // BRAM has latency, so i_instr is stale for 1-2 cycles after PC change.

  // Fetch-invalid cycles freeze the pending-prediction walk and the redirect
  // bubble bookkeeping exactly like a stall: nothing was delivered, so none
  // of the per-delivery state may advance.
  logic fetch_stall;
  assign fetch_stall = i_stall || !i_fetch_progress;

  control_flow_tracker #(
      .XLEN(XLEN)
  ) control_flow_tracker_inst (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_fetch_progress,
      .i_flush,
      .i_fence_i_flush,
      // Control flow sources
      .i_trap_taken,
      .i_mret_taken,
      .i_branch_taken,
      .i_pd_redirect,
      .i_pd_redirect_target,
      .i_prediction_used,
      .i_slot2_prediction_used,
      .i_slot2_predicted_target,
      .i_branch_target,
      .i_trap_target,
      .i_predicted_target,
      // Outputs
      .o_control_flow_change,
      .o_control_flow_holdoff,
      .o_reset_holdoff,
      .o_any_holdoff,
      .o_any_holdoff_safe,
      .o_control_flow_to_halfword,
      .o_control_flow_to_halfword_r
  );

  // ===========================================================================
  // Slot-2 Redirect Bubble Register
  // ===========================================================================
  // After a slot-2 BTB-prediction redirect at cycle N+1, BRAM at cycle N+2
  // returns the wrong-path sequential bundle.  o_slot2_redirect_q asserts
  // for one cycle (N+2) so the if_stage sel_nop can NOP that wrong-path
  // bundle (mirroring pd_redirect_q's role).  Cleared by reset/flush and
  // by any higher-priority redirect that already kills the front-end state.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      o_slot2_redirect_q <= 1'b0;
    end else if (!fetch_stall) begin
      o_slot2_redirect_q <= i_slot2_prediction_used;
    end
  end

  // ===========================================================================
  // PC Increment Calculator - Sequential PC Computation
  // ===========================================================================
  // Computes next sequential PC values using parallel adders for timing optimization.
  // See pc_increment_calculator.sv for detailed implementation.

  logic [XLEN-1:0] seq_next_pc, seq_next_pc_plus_2, seq_next_pc_reg;
  logic seq_next_pc_reg_neq_pc;
  riscv_pkg::fetch_verdict_t seq_next_pc_verdict, seq_next_pc_plus_2_verdict;

  pc_increment_calculator #(
      .XLEN(XLEN)
  ) pc_increment_calculator_inst (
      // Current PC values
      .i_pc(o_pc),
      .i_pc_reg(o_pc_reg),

      // C-extension state signals
      .i_is_compressed,
      .i_is_compressed_for_pc,
      .i_sel_nop,
      .i_pc_fetch_advance_sel,
      .i_pc_reg_advance_sel,
      .i_pc_fetch_advance_sel_run,
      .i_pc_fetch_advance_sel_nop,
      .i_pc_reg_advance_sel_run,
      .i_pc_reg_advance_sel_nop,

      // Holdoff and control signals
      .i_any_holdoff_safe(o_any_holdoff_safe),
      .i_prediction_holdoff,
      .i_prediction_from_buffer_holdoff,
      .i_control_flow_to_halfword_r(o_control_flow_to_halfword_r),
      .i_stall_registered,

      // Mid-32bit correction
      .i_mid_32bit_correction(o_mid_32bit_correction),

      // Outputs
      .o_seq_next_pc(seq_next_pc),
      .o_seq_next_pc_plus_2(seq_next_pc_plus_2),
      .o_seq_next_pc_verdict(seq_next_pc_verdict),
      .o_seq_next_pc_plus_2_verdict(seq_next_pc_plus_2_verdict),
      .o_seq_next_pc_reg(seq_next_pc_reg),
      .o_seq_next_pc_reg_neq_pc(seq_next_pc_reg_neq_pc)
  );

  // ===========================================================================
  // Mid-32bit Correction Detection — DISABLED with 64-bit fetch
  // ===========================================================================
  // With 64-bit fetch, 32-bit instructions at PC[1]=1 are assembled
  // immediately from both words.  There is no "landing in the middle" of a
  // 32-bit instruction, so the mid-32bit correction is never needed.
  assign o_mid_32bit_correction = 1'b0;

  // ===========================================================================
  // Final PC Selection - Priority-Encoded Muxes
  // ===========================================================================
  // Use explicit priority muxes instead of one-hot AND/OR trees so trap/stall
  // gating doesn't get duplicated across every select term.

  // For next_pc_reg, use the REGISTERED prediction (1 cycle delayed).
  // This is because o_pc_reg represents the PC of the instruction being processed,
  // which lags o_pc (the fetch address) by one cycle.
  // When we predict taken at PC_N in cycle N:
  //   - next_pc goes to target immediately (fetch from target in cycle N+1)
  //   - next_pc_reg stays sequential in cycle N (instruction at PC_{N-1} is processed)
  //   - next_pc_reg goes to target in cycle N+1 (using registered prediction)
  //
  // Word-aligned predictions still use the original registered 1-cycle handoff:
  // the branch PC reaches o_pc_reg in the next cycle, and then i_sel_prediction_r
  // advances pc_reg to the predicted target. This must remain active during the
  // post-prediction holdoff cycle; otherwise pc_reg misses the target handoff
  // and keeps stepping sequentially while fetch has already redirected.
  //
  // Halfword-aligned predictions are different. A compressed branch/return in
  // the upper half of a fetch word can cause pc_reg to step past the branch PC
  // numerically before the registered prediction pulse lines up. Keep a pending
  // {branch_pc,target} pair only for that halfword-crossing case. When pc_reg
  // is about to cross from the lower halfword to the pending branch PC, land on
  // the branch PC first so IF still emits the predicted control-flow
  // instruction itself before advancing pc_reg to the target.
  // Suppress sel_prediction_r when any redirect killed the pending state last
  // cycle (redirect_kill_pending_q).  This prevents a wrong-path BTB prediction
  // that fired simultaneously with a PD redirect from advancing pc_reg to the
  // wrong target.  For branch_taken/trap/mret, sel_prediction_r is already
  // harmless (higher-priority mux entries override it), but suppressing it is
  // cleaner and strictly safer.
  logic sel_prediction_r;
  // Also suppress slot-1's registered pc_reg-handoff during the
  // slot-2 redirect bubble.  Otherwise, when both slot-1 (on the
  // wrong-path next-bundle PC) and slot-2 BTB hit in the same cycle,
  // slot-1's sel_prediction_r at cycle N+2 would steer pc_reg to slot-1's
  // target instead of holding it on the slot-2 target.
  assign sel_prediction_r = !i_reset && i_sel_prediction_r &&
                            !pending_prediction_valid && !redirect_kill_pending_q &&
                            !o_slot2_redirect_q;

  logic            pending_prediction_valid;
  logic [XLEN-1:0] pending_prediction_pc;
  // Capture the compressed predecessor beside pending_prediction_pc so the
  // live pc_reg control cone only pays for a registered equality compare.
  // KEEP prevents synthesis from reconstructing this tag as
  // pending_prediction_pc-2 and putting the carry chain back on pc_reg.
  (* keep = "true" *)logic [XLEN-1:0] pending_prediction_prev_pc;
  logic [XLEN-1:0] pending_prediction_target;
  logic            pending_prediction_effective;
  logic            pending_imm_pred_emit;
  logic            pim_base;  // immediate-predecessor + pending (pre-narrowing)
  logic            carve_out_engaged_q;  // latched: raw wcs=1 seen this episode
  logic            pending_prediction_from_buffer;
  logic            prediction_needs_pending;
  logic            use_pending_prediction_for_pc_reg;
  logic            pending_prediction_crossing_pc_reg;
  logic            pending_prediction_target_handoff;
  logic            pending_prediction_allow_cross;
  (* keep = "true", max_fanout = 16 *)logic            pending_prediction_allow_cross_pc_mux_q;
  logic            stale_pending_prediction;
  logic            hold_pending_prediction_fetch;
  logic            hold_pending_prediction_consume_fetch;
  logic            pending_prediction_cross_handoff_pc_mux;
  logic            pending_prediction_target_handoff_pc_mux;
  logic            use_pending_prediction_for_pc_reg_pc_mux;
  logic            hold_pending_prediction_fetch_pc_mux;
  (* max_fanout = 16 *)logic            pending_wcs_seq_override_pc_mux;
  logic            pending_prediction_target_holdoff_q;
  logic            pending_prediction_target_holdoff_prev_q;
  logic            pending_prediction_pc_ready_q;
  logic            redirect_kill_pending_q;
  logic [XLEN-2:0] pending_prediction_pc_hw;
  logic [XLEN-1:0] pending_prediction_target_next_word;
  logic [XLEN-2:0] pc_reg_hw;
  logic            pc_reg_before_pending;
  logic            pc_reg_at_pending;
  logic            pc_reg_after_pending;
  logic            seq_reaches_pending;
  logic            pc_reg_at_pending_predecessor;
  logic            pending_predecessor_needs_emit;
  logic [XLEN-2:0] seq_next_pc_reg_hw_q;
  logic            halfword_target_lead_catchup;
  logic            clear_pending_prediction_state;
  // pending_prediction_allow_cross_d / pending_prediction_from_buffer_d were
  // removed when those FFs moved to a !pending_prediction_valid speculative-
  // capture pattern (see the timing comment near the always_ff below).

  assign pending_prediction_pc_hw = pending_prediction_pc[XLEN-1:1];
  assign pending_prediction_target_next_word =
      {pending_prediction_target[XLEN-1:2], 2'b00} + riscv_pkg::PcIncrement32bit;
  assign pc_reg_hw = o_pc_reg[XLEN-1:1];
  assign pc_reg_before_pending = pc_reg_hw < pending_prediction_pc_hw;
  assign pc_reg_at_pending = o_pc_reg == pending_prediction_pc;
  assign pc_reg_after_pending = pc_reg_hw > pending_prediction_pc_hw;
  assign seq_reaches_pending = seq_next_pc_reg_hw_q >= pending_prediction_pc_hw;
  assign pc_reg_at_pending_predecessor = o_pc_reg == pending_prediction_prev_pc;
  assign pending_predecessor_needs_emit = i_window_cannot_serve_raw || carve_out_engaged_q;

  // TIMING OPTIMIZATION: Register seq_next_pc_reg_hw before the pending
  // prediction crossing comparison. This breaks the critical 24-level path
  // from mispredict_recovery → flush → is_compressed → pc_reg_normal →
  // seq_next_pc_reg → CARRY8 comparison → pending_prediction_allow_cross/CE.
  // The 1-cycle-old value is safe because stale_pending_prediction and
  // redirect_kill_pending_q handle delayed crossing detection gracefully.
  always_ff @(posedge i_clk) begin
    if (i_flush || i_branch_taken || i_pd_redirect || i_trap_taken || i_mret_taken)
      seq_next_pc_reg_hw_q <= '0;
    else if (!fetch_stall) seq_next_pc_reg_hw_q <= seq_next_pc_reg[XLEN-1:1];
  end
  // Lower-half, word-aligned predictions only need the pending-handoff path
  // when pc_reg would otherwise skip over the branch PC. Treating every such
  // prediction as pending breaks normal taken-call flow: fetch redirects to the
  // target, but pc_reg gets forced back through a spurious pending handoff and
  // eventually re-tags non-control-flow PCs as predicted-taken. Keep the
  // pending path restricted to the original "pc_reg would advance past o_pc"
  // case and leave ordinary registered handoffs alone.
  // Do not arm pending_prediction when slot-2 BTB redirects in
  // the same cycle.  Slot-2 owns next_pc/next_pc_reg this cycle; the
  // slot-1 BTB hit (on the now-wrong-path next-bundle PC) is moot, and
  // letting its halfword target latch a pending_prediction state would
  // fight the slot-2 redirect bubble at cycle N+2.
  //
  // Timing: avoid using (seq_next_pc_reg != o_pc) on the pending-valid D path.
  // That pulls the full pc_reg increment adders and equality compare into the
  // same-cycle prediction arm cone. When prediction is allowed, the front-end is
  // not in holdoff, so a word-aligned fetch PC that pc_reg has not reached yet
  // only needs pending when the selected instruction-size advance misses the
  // fetch PC's halfword lane. If pc_reg is already on the predicted PC, the
  // predicted op is being emitted this cycle and the registered target handoff
  // can take over normally.
  // BOOT-HANG FIX: use the full compare, never a bit1-only proxy.  A bit1
  // proxy (pc_reg advance XOR size) diverges from the full result when pc_reg
  // is >=2 words behind the word-aligned fetch PC -- both are word-aligned so
  // bit 1 matches, but the words differ. There the proxy says 0 ("no miss")
  // while the truth (seq_next_pc_reg != o_pc) is 1, so
  // prediction_needs_pending is wrongly false, the prediction is applied without
  // the pc_reg handoff, and fetch redirects to the wrong PC (silent on HW where
  // the assert below is compiled out -> the no-MMU Linux boot hang at pid_max).
  // The full compare is conservative-safe (only ever pends MORE, exactly in
  // the cases a bit1 proxy misses). TIMING: the compare is precomputed
  // per-candidate inside pc_increment_calculator (compare-then-mux off
  // registered operands, bit-identical to (seq_next_pc_reg != o_pc)) so the
  // late sideband-derived advance select only steers a 1-bit mux here instead
  // of feeding a 32-bit comparator on the pending-valid D path.
  logic pc_reg_next_misses_fetch_pc_for_prediction;
  assign pc_reg_next_misses_fetch_pc_for_prediction = seq_next_pc_reg_neq_pc;

  assign prediction_needs_pending =
      i_prediction_used && !i_ras_predicted && !i_slot2_prediction_used &&
      (o_pc[1] || i_predicted_target[1] ||
       (pc_reg_next_misses_fetch_pc_for_prediction &&
        i_prediction_requires_pc_reg_handoff));
  // TIMING: Replace !i_flush with !i_fence_i_flush to break the critical path
  // from mispredict_recovery_pending through flush_pipeline into this cone.
  // For mispredict, !i_branch_taken already kills the pending prediction.
  // For trap/mret, !i_trap_taken/!i_mret_taken already kill it.
  // Only the FENCE-class pulse needs explicit suppression here (and it is
  // already registered).
  assign pending_prediction_effective = pending_prediction_valid && !redirect_kill_pending_q &&
                                        !i_fence_i_flush && !i_branch_taken &&
                                        !i_trap_taken && !i_mret_taken;
  assign o_pending_prediction_active = pending_prediction_effective;

  // A compressed branch/return can be predicted from the upper halfword of a
  // 32-bit fetch word. In that case pc_reg may advance from the lower halfword
  // to the next word and never equal the branch PC exactly. Treat "crossing"
  // the pending halfword as ready-to-apply, and clear anything already behind
  // pc_reg so stale redirects cannot pin fetch forever. The mutually exclusive
  // before/at/after predicates also let the handoff cone avoid re-testing
  // conditions already implied by its selected relation.
  assign pending_prediction_crossing_pc_reg =
      pending_prediction_effective &&
      pending_prediction_allow_cross &&
      pc_reg_before_pending &&
      seq_reaches_pending;
  assign pending_prediction_target_handoff =
      pending_prediction_effective && pc_reg_at_pending &&
      (pending_prediction_allow_cross || pending_prediction_pc_ready_q);
  assign use_pending_prediction_for_pc_reg =
      pending_prediction_effective &&
      ((pending_prediction_allow_cross && pc_reg_before_pending && seq_reaches_pending) ||
       (pc_reg_at_pending &&
        (pending_prediction_allow_cross || pending_prediction_pc_ready_q)));
  assign stale_pending_prediction = pending_prediction_effective && pc_reg_after_pending;
  // Pending-prediction load-drop fix (the no-MMU-Linux timer-IRQ boot hang):
  // immediate-predecessor carve-out.  When a pending BTB
  // prediction is in flight for a branch that is the COMPRESSED parcel immediately
  // after pc_reg (pending_prediction_pc == o_pc_reg + 2) and pc_reg has NOT yet
  // reached it (!use_pending, !stale), the parcel currently at pc_reg is a
  // correct-path OLDER instruction that MUST execute (e.g. the no-MMU IRQ revmap_size
  // load at 0x8005a19a sitting between the fetch point and the predicted bgeu at
  // 0x8005a19c).  Without this, hold_pending_prediction_fetch squashes it (->
  // o_pending_prediction_fetch_holdoff -> if_stage sel_nop) and the land-on-branch arm
  // jumps pc_reg straight to pending_prediction_pc, DROPPING it.  pending_imm_pred_emit
  // suppresses the fetch-holdoff squash + the land-on-branch jump so the parcel emits
  // and pc_reg advances SEQUENTIALLY onto the branch.  pending_prediction_valid stays
  // live, so the prediction still applies (metadata-replay path unchanged) once pc_reg
  // reaches the branch.  This is the documented design intent of
  // prediction_metadata_tracker ("IF keeps walking older instructions after a BTB
  // redirect").
  //
  // LOOP-BREAK: the predicate uses ONLY registered state -- o_pc_reg and the
  // predecessor tag captured beside pending_prediction_pc.  An earlier form used
  // seq_next_pc_reg, which
  // depends on pc_reg_advance_sel -> sel_nop; combined with gate (a) feeding
  // pending_imm_pred_emit BACK into sel_nop (via o_pending_prediction_fetch_holdoff)
  // that closed a combinational cycle (Verilator "Active region did not converge" at
  // ~16.6M, masked by -Wno-UNOPTFLAT).  o_pc_reg + PcIncrementCompressed is exactly the
  // value seq_next_pc_reg held while the parcel was squashed (if_stage.sv's
  // pc_reg_advance_sel_live always_comb DEFAULTS to +2 when sel_nop=1), so behaviour is
  // preserved for the compressed immediate-predecessor (the observed drop case) while
  // the cycle is broken.  A 32-bit predecessor is intentionally NOT covered: it cannot be
  // identified sel_nop-free here (the served instruction-size signals are unreliable
  // under the coincident served-window guard) and the prior form did not cover it
  // either (it too saw +2 during the squash), so the scope is unchanged.
  // NARROWING: the base condition (pim_base, below) by itself fires ~50k times/boot, at
  // wcs=0 dual-issue load+branch bundles where the load already emits -- and there, the
  // carve-out clearing sel_nop makes pc_reg_advance_sel_live pick +4 (slot-2) so pc_reg
  // jumps PAST the branch, mishandling the pending prediction -> stale-ra wild ret
  // (of_prop_next_string 0x8021fcae).
  assign pim_base =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
      !pc_reg_after_pending && pc_reg_at_pending_predecessor;
  // NARROW to the true drop condition: the load is only DROPPED when the served window cannot
  // deliver it (raw wcs=1).  But the load can only EMIT on the wcs=0 cycle (one after the
  // resteer), so a plain "&& wcs" would drop pim exactly then and re-NOP the load.  Instead
  // LATCH the engagement once wcs=1 is seen during the episode, and hold it until the
  // episode ends (pc_reg reaches the branch -> pim_base falls) or any redirect.  This is
  // NOT a pc_reg hold -- pim still advances pc_reg via the carve-out -- so it cannot
  // deadlock.  At wcs=0 sites it never engages.  Acyclic: raw wcs is independent of sel_nop.
  assign pending_imm_pred_emit = pim_base && pending_predecessor_needs_emit;
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush || !pim_base) begin
      carve_out_engaged_q <= 1'b0;
    end else if (!fetch_stall && i_window_cannot_serve_raw) begin
      carve_out_engaged_q <= 1'b1;
    end
  end
  assign hold_pending_prediction_fetch =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
      !pc_reg_after_pending &&
      !(pc_reg_at_pending_predecessor && pending_predecessor_needs_emit);
  assign hold_pending_prediction_consume_fetch = use_pending_prediction_for_pc_reg;
  // Keep a PC-mux-local copy of the pending-handoff cone so synthesis can
  // place it near the next_pc/next_pc_reg muxes instead of routing the shared
  // state/output version back across the IF control logic. These nodes are not
  // preserved: flattening their implied predicates is the timing objective.
  assign pending_prediction_cross_handoff_pc_mux =
      pending_prediction_effective &&
      pending_prediction_allow_cross_pc_mux_q &&
      pc_reg_before_pending &&
      seq_reaches_pending;
  assign pending_prediction_target_handoff_pc_mux =
      pending_prediction_effective && pc_reg_at_pending &&
      (pending_prediction_allow_cross_pc_mux_q || pending_prediction_pc_ready_q);
  assign use_pending_prediction_for_pc_reg_pc_mux =
      pending_prediction_effective &&
      ((pending_prediction_allow_cross_pc_mux_q && pc_reg_before_pending &&
        seq_reaches_pending) ||
       (pc_reg_at_pending &&
        (pending_prediction_allow_cross_pc_mux_q || pending_prediction_pc_ready_q)));
  // TIMING: the raw served-window verdict used to clear this hold condition,
  // then traverse the complete one-hot PC priority tree. Cofactor it into the
  // arm value instead. With H0 equal to this WCS-free hold, X equal to the
  // immediate-predecessor predicate, and W equal to raw WCS, the old hold is
  // H=H0&!(W&X). Thus H?V:SEQ is exactly
  // H0?((W&X)?SEQ:V):SEQ. The late override is fanout-capped so it replicates
  // beside the PC/IMMU arm consumers instead of recreating a wide control net.
  assign pending_wcs_seq_override_pc_mux = i_window_cannot_serve_raw && pim_base;
  assign hold_pending_prediction_fetch_pc_mux =
      pending_prediction_effective &&
      !use_pending_prediction_for_pc_reg_pc_mux &&
      !pc_reg_after_pending &&
      !(pim_base && carve_out_engaged_q);
  assign o_pending_prediction_holdoff =
      hold_pending_prediction_fetch || hold_pending_prediction_consume_fetch;
  // Shannon cofactors of the hold above on the raw served-window verdict
  // (pending_predecessor_needs_emit = raw WCS || carve_out_engaged_q).
  assign o_pending_prediction_holdoff_wcs0 =
      (pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
       !pc_reg_after_pending &&
       !(pc_reg_at_pending_predecessor && carve_out_engaged_q)) ||
      hold_pending_prediction_consume_fetch;
  assign o_pending_prediction_holdoff_wcs =
      (pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
       !pc_reg_after_pending && !pc_reg_at_pending_predecessor) ||
      hold_pending_prediction_consume_fetch;
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              i_window_cannot_serve_raw,
              o_pending_prediction_holdoff,
              o_pending_prediction_holdoff_wcs0,
              o_pending_prediction_holdoff_wcs
            }
        )) begin
      p_pending_prediction_holdoff_cofactors_exact :
      assert (o_pending_prediction_holdoff ==
              (i_window_cannot_serve_raw ? o_pending_prediction_holdoff_wcs :
                                           o_pending_prediction_holdoff_wcs0));
    end
  end
`endif
  assign o_pending_prediction_target_handoff = pending_prediction_target_handoff;
  assign o_pending_prediction_fetch_holdoff =
      hold_pending_prediction_fetch ||
      (hold_pending_prediction_consume_fetch &&
       pending_prediction_allow_cross &&
       (o_pc_reg != pending_prediction_pc));
  // Shannon cofactor for raw WCS=0. The immediate-predecessor carve-out then
  // depends only on its registered episode latch. IF uses W | E(W) = W | E(0)
  // so raw WCS no longer traverses this pending-prediction priority cone on
  // the architectural sel_nop path.
  assign o_pending_prediction_fetch_holdoff_wcs0 =
      (pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
       !pc_reg_after_pending &&
       !(pc_reg_at_pending_predecessor && carve_out_engaged_q)) ||
      (hold_pending_prediction_consume_fetch && pending_prediction_allow_cross &&
       (o_pc_reg != pending_prediction_pc));
  // Shannon cofactor for raw WCS=1. In that cofactor
  // pending_predecessor_needs_emit is true, so the immediate-predecessor
  // carve-out removes the fetch hold regardless of carve_out_engaged_q.
  assign o_pending_prediction_fetch_holdoff_wcs =
      (pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
       !pc_reg_after_pending && !pc_reg_at_pending_predecessor) ||
      (hold_pending_prediction_consume_fetch && pending_prediction_allow_cross &&
       (o_pc_reg != pending_prediction_pc));
  assign o_pending_prediction_target_holdoff = pending_prediction_target_holdoff_q;
  assign halfword_target_lead_catchup =
      pending_prediction_target_holdoff_prev_q &&
      !pending_prediction_target_holdoff_q &&
      !pending_prediction_effective &&
      !i_sel_nop &&
      i_is_compressed &&
      o_pc_reg[1] &&
      (o_pc == (o_pc_reg + riscv_pkg::PcIncrementCompressed));

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_target_holdoff_q <= 1'b0;
    end else if (!fetch_stall) begin
      // Keep exactly one target bubble after the pending handoff. With fetch
      // capped to the target's next word, that is enough time for the target
      // word to arrive while preserving the normal one-word BRAM lead.
      //
      // Upper-half cross-handoffs must still emit the predicted control-flow
      // instruction itself when pc_reg lands on the branch PC, so the bubble
      // remains restricted to the non-cross pending handoff path.
      pending_prediction_target_holdoff_q <=
          hold_pending_prediction_consume_fetch && !pending_prediction_allow_cross;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_target_holdoff_prev_q <= 1'b0;
    end else if (!fetch_stall) begin
      pending_prediction_target_holdoff_prev_q <= pending_prediction_target_holdoff_q;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_reset) redirect_kill_pending_q <= 1'b0;
    else
      redirect_kill_pending_q <= i_flush || i_branch_taken || i_pd_redirect ||
                                     i_trap_taken || i_mret_taken || i_fence_i_flush;
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_pc_ready_q <= 1'b0;
    end else if (!fetch_stall) begin
      if (redirect_kill_pending_q || pending_prediction_target_handoff ||
          stale_pending_prediction) begin
        pending_prediction_pc_ready_q <= 1'b0;
      end else if (pending_prediction_effective && !pending_prediction_allow_cross &&
                   (o_pc == pending_prediction_pc)) begin
        pending_prediction_pc_ready_q <= 1'b1;
      end
    end
  end

  // The target-handoff consume must ride the same !fetch_stall enable as the
  // pc_reg flop it hands off to. An ungated consume during a stall discards
  // the pending target while pc_reg is frozen: pc_reg then advances
  // SEQUENTIALLY past the predicted-taken branch while fetch follows the
  // target, and the aligner serves target-path bytes under sequential
  // pc_reg PCs. Downstream decode faithfully manufactures phantom
  // instructions from that pairing (a non-branch can dispatch as a
  // taken branch, "mispredict", and redirect the machine to a garbage
  // address). The crossing arm needs no gate: it consumes implicitly via
  // stale_pending_prediction only after pc_reg really advances.
  assign clear_pending_prediction_state =
      redirect_kill_pending_q || (pending_prediction_target_handoff && !fetch_stall) ||
      stale_pending_prediction;

  // Same-cycle mirror of every pending-state death EXCEPT the legitimate
  // target-handoff consume (where the tracker's own replay-consume attaches
  // the metadata to the emitting branch).  The direct redirect terms fire on
  // the event cycle itself -- one cycle before redirect_kill_pending_q --
  // which is required to beat the tracker's same-cycle pending-save capture
  // (the capture predicate reads pre-kill i_prediction_used_r/fetch-holdoff
  // values on exactly the cycle a PD redirect lands).
  assign o_pending_prediction_redirect_kill =
      i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
      i_pd_redirect || i_fence_i_flush || stale_pending_prediction;

`ifndef SYNTHESIS
  // The un-stalled handoff consume assumes the target arm actually wins the
  // next_pc_reg mux. The redirect arms are fine (they kill the pending state
  // themselves), but the three non-redirect arms above the target arm would
  // consume without applying — the same desync this consume gate fixes, via
  // a different door. Keep that assumption observable.
  always_comb begin
    if (pending_prediction_target_handoff && !fetch_stall && !i_reset && !$isunknown(
            {i_window_cannot_serve, i_slot2_prediction_used_for_pc,
                     o_pending_prediction_target_holdoff}
        )) begin
      p_handoff_consume_implies_apply :
      assert (!i_window_cannot_serve && !i_slot2_prediction_used_for_pc &&
              !o_pending_prediction_target_holdoff);
    end
  end
`endif

  // Express the valid bit as clear/enable/set control rather than a full
  // next-state mux on D.  The priority is unchanged, but Vivado can map the
  // clear and hold portions onto flop control pins and keep the prediction arm
  // cone narrower.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush || clear_pending_prediction_state) begin
      pending_prediction_valid <= 1'b0;
    end else if (!fetch_stall && prediction_needs_pending) begin
      pending_prediction_valid <= 1'b1;
    end
  end

  // TIMING: Use !pending_prediction_valid as the CE instead of the
  // combinational prediction_needs_pending.  This breaks the BRAM →
  // sel_nop_2 → seq_next_pc_reg → CARRY8 NEQ → prediction_needs_pending → CE
  // path that drove pending_prediction_allow_cross_reg/CE to -1.303ns post-
  // synth.  The invariant: prediction_needs_pending can only fire when
  // pending_prediction_valid is 0 (fetch is held while a prediction is
  // pending, so no new BTB hit can occur).  Capturing speculatively every
  // non-stalled cycle while valid is 0 means the captured data is ready the
  // instant the control block sets valid.
  //
  // No explicit reset/clear: these registers are only consumed inside the
  // pending_prediction_effective gate (i.e., when valid=1), so their value
  // when valid=0 is don't-care.  Same pattern as pending_prediction_pc/target
  // below — extended to allow_cross/from_buffer to lift their CE off the
  // BRAM critical path.
  always_ff @(posedge i_clk) begin
    if (!fetch_stall && !pending_prediction_valid) begin
      pending_prediction_pc                   <= o_pc;
      pending_prediction_prev_pc              <= o_pc - riscv_pkg::PcIncrementCompressed;
      pending_prediction_target               <= i_predicted_target;
      pending_prediction_allow_cross          <= o_pc[1];
      pending_prediction_allow_cross_pc_mux_q <= o_pc[1];
      pending_prediction_from_buffer          <= i_prediction_used_from_buffer;
    end
  end

  logic [XLEN-1:0] next_pc, next_pc_reg;
  logic trap_or_mret;
  assign trap_or_mret = i_trap_taken || i_mret_taken;

  // ---------------------------------------------------------------------------
  // next_pc: ONE-HOT winner + balanced mux (timing restructure).
  //
  // This used to be a thirteen-arm serial if/else priority chain, which
  // synthesises to a ~13-deep 2:1 mux cascade on a 64-bit datum. next_pc is
  // the lookup key of the instruction MMU's shadow, so that cascade sat in
  // front of the ITLB CAM and its permission/PMA resolution: the whole
  // string was measured as the worst path on BOTH boards (21-22 logic
  // levels, IMEM PC-metadata -> next_pc -> immu pa1_q).
  //
  // The arms and their order are UNCHANGED; only the shape is. The kill term
  // for each arm is the OR of the higher-priority conditions, which a tool
  // can build as a balanced prefix tree, and the datum is an AND-OR reduce
  // instead of a cascade. p_next_pc_onehot / p_next_pc_matches_priority below
  // pin both properties against the original expression in simulation.
  // ---------------------------------------------------------------------------
  localparam int unsigned NPcArms = riscv_pkg::PcNextArms;
  logic [NPcArms-1:0] npc_cond;  // raw arm conditions, priority order
  logic [NPcArms-1:0] npc_sel;  // one-hot winner
  logic [XLEN-1:0] npc_val[NPcArms];
  // For the instruction MMU (see the o_npc_* ports): which arms are
  // o_pc + d, and the early operand of the others.
  logic [NPcArms-1:0] npc_seq;
  logic [NPcArms-1:0][XLEN-1:0] npc_cmp_val;
  riscv_pkg::fetch_verdict_t [NPcArms-1:0] npc_seq_verdict;
  // o_pc's own verdict, for the arms that hold at it (from the pc register).
  riscv_pkg::fetch_verdict_t pc_verdict;
  assign pc_verdict = riscv_pkg::fetch_verdict(o_pc);

  // The pending-prediction consume arm's own 2-level select, hoisted out so
  // the arm value is a plain datum like every other arm. Its sequential
  // case is named so the MMU can classify the arm the same way.
  logic npc_consume_is_seq;
  logic [XLEN-1:0] npc_consume_val;
  assign npc_consume_is_seq = pending_prediction_allow_cross_pc_mux_q &&
      pending_prediction_target_handoff_pc_mux && !pending_prediction_from_buffer;
  assign npc_consume_val = npc_consume_is_seq ? seq_next_pc : pending_prediction_target;

  always_comb begin
    npc_cond[0] = i_reset;
    npc_cond[1] = trap_or_mret;
    npc_cond[2] = i_fence_i_flush;
    npc_cond[3] = i_branch_taken;
    npc_cond[4] = i_pd_redirect;
    npc_cond[5] = i_window_cannot_serve;
    npc_cond[6] = !i_fetch_progress;
    npc_cond[7] = i_slot2_prediction_used_for_pc;
    npc_cond[8] = i_prediction_used_for_pc;
    npc_cond[9] = o_pending_prediction_target_holdoff;
    npc_cond[10] = use_pending_prediction_for_pc_reg_pc_mux;
    npc_cond[11] = halfword_target_lead_catchup;
    npc_cond[12] = hold_pending_prediction_fetch_pc_mux;
    npc_cond[13] = 1'b1;  // default arm: sequential

    npc_val[0] = '0;
    npc_val[1] = i_trap_target;
    npc_val[2] = i_fence_i_target;
    npc_val[3] = i_branch_target;
    npc_val[4] = i_pd_redirect_target;
    npc_val[5] = {o_pc_reg[XLEN-1:2], 2'b00};
    npc_val[6] = o_pc;
    npc_val[7] = i_slot2_predicted_target;
    npc_val[8] = i_predicted_target;
    npc_val[9] = (o_pc == pending_prediction_target) ? pending_prediction_target_next_word : o_pc;
    npc_val[10] = npc_consume_val;
    npc_val[11] = seq_next_pc_plus_2;
    npc_val[12] = pending_wcs_seq_override_pc_mux ? seq_next_pc :
        (pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
         pending_prediction_pc);
    npc_val[13] = seq_next_pc;

    // Arms whose value is o_pc + d with 0 <= d < 16: the hold arm (d = 0),
    // the target-holdoff arm when it holds at o_pc, the consume arm's
    // sequential case, and the two sequential arms (seq_next_pc and its +2
    // are o_pc + 2 .. o_pc + 12; the mid-32-bit correction is disabled at
    // rv64). Every other arm is judged on its early operand: the raw
    // redirect targets, pc_reg's word, and the registered pending
    // addresses. The consume arm and target-holdoff arm are mixed; arm 12 is
    // sequential only for the raw-WCS override and otherwise compares its
    // early pending operand.
    npc_seq = '0;
    npc_seq[6] = 1'b1;
    npc_seq[9] = !(o_pc == pending_prediction_target);
    npc_seq[10] = npc_consume_is_seq;
    npc_seq[11] = 1'b1;
    npc_seq[12] = pending_wcs_seq_override_pc_mux;
    npc_seq[13] = 1'b1;
    for (int unsigned k = 0; k < NPcArms; k++) npc_cmp_val[k] = npc_val[k];
    npc_cmp_val[9] = pending_prediction_target_next_word;
    npc_cmp_val[10] = pending_prediction_target;
    // Arm 12's comparator operand is don't-care during its sequential
    // override. Keep WCS out of this wide bus and retain the early pending
    // operand for the non-sequential case.
    npc_cmp_val[12] = pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
        pending_prediction_pc;
    // The sequential arms' predecoded verdicts (don't-care where !npc_seq).
    npc_seq_verdict = '0;
    npc_seq_verdict[6] = pc_verdict;
    npc_seq_verdict[9] = pc_verdict;
    npc_seq_verdict[10] = seq_next_pc_verdict;
    npc_seq_verdict[11] = seq_next_pc_plus_2_verdict;
    npc_seq_verdict[12] = seq_next_pc_verdict;
    npc_seq_verdict[13] = seq_next_pc_verdict;
  end
  assign o_npc_sel = npc_sel;
  assign o_npc_seq = npc_seq;
  assign o_npc_cmp_val = npc_cmp_val;
  always_comb begin
    for (int unsigned k = 0; k < NPcArms; k++) o_npc_val[k] = npc_val[k];
  end
  assign o_npc_seq_verdict = npc_seq_verdict;

  // One-hot: arm k wins when it asks and no higher-priority arm does. The
  // kill term is a plain OR reduce of the strictly-higher-priority bits, so
  // the tool is free to balance it instead of chaining.
  always_comb begin
    for (int unsigned k = 0; k < NPcArms; k++) begin
      npc_sel[k] = npc_cond[k] && !(|(npc_cond & ((1 << k) - 1)));
    end
  end

  always_comb begin
    next_pc = '0;
    for (int unsigned k = 0; k < NPcArms; k++) begin
      next_pc |= {XLEN{npc_sel[k]}} & npc_val[k];
    end
  end

  // For next_pc_reg, use the REGISTERED prediction handoff for both BTB and
  // RAS predictions. next_pc still redirects fetch immediately, but pc_reg is
  // the instruction-side view and can pay one extra cycle here to keep the
  // current fetch-response cone out of the pc_reg D path.
  //
  // This ensures o_pc_reg tracks the instruction PC correctly:
  //   - In cycle N (prediction made): next_pc_reg = sequential (for current instruction)
  //   - In cycle N+1 (registered): next_pc_reg = predicted_target_r (for branch instruction)
  //   - In cycle N+2: o_pc_reg = predicted_target_r (for target instruction)
  always_comb begin
    if (i_reset) next_pc_reg = '0;
    else if (trap_or_mret) next_pc_reg = i_trap_target;
    else if (i_fence_i_flush) next_pc_reg = i_fence_i_target;
    else if (i_branch_taken) next_pc_reg = i_branch_target;
    else if (i_pd_redirect) next_pc_reg = i_pd_redirect_target;
    else if (i_window_cannot_serve) next_pc_reg = o_pc_reg;
    // No fetch progress: hold the instruction address (nothing is being
    // delivered).  Same placement rationale as the next_pc hold arm above.
    else if (!i_fetch_progress) next_pc_reg = o_pc_reg;
    // Slot-2 BTB prediction: pc_reg jumps to the slot-2 target
    // immediately (mirroring pd_redirect's pc_reg handoff).  The cycle
    // after the redirect is NOP'd via the standard control_flow_holdoff
    // path (seq_sel_holdoff holds pc_reg at the target), and BRAM data for
    // the target arrives the cycle after that.
    else if (i_slot2_prediction_used_for_pc) next_pc_reg = i_slot2_predicted_target;
    // After a non-cross pending handoff, the first target cycle is a bubble
    // while BRAM returns the target word. Hold pc_reg on the target during
    // that bubble; advancing here pairs the arriving target word with the next
    // halfword PC and corrupts C-extension alignment on loop back-edges.
    else if (o_pending_prediction_target_holdoff) next_pc_reg = o_pc_reg;
    // Pending-prediction load-drop fix: suppress the land-on-branch JUMP in the
    // immediate-predecessor carve-out so pc_reg advances SEQUENTIALLY
    // (seq_next_pc_reg, which equals pending_prediction_pc here) and the
    // intervening older parcel emits first instead of being skipped.
    // pending_prediction_valid stays live -> the target handoff (below)
    // still fires when pc_reg actually reaches the branch.
    else if (pending_prediction_effective && !pending_prediction_allow_cross_pc_mux_q &&
             !use_pending_prediction_for_pc_reg_pc_mux && !pending_imm_pred_emit)
      next_pc_reg = pending_prediction_pc;
    else if (pending_prediction_cross_handoff_pc_mux) next_pc_reg = pending_prediction_pc;
    else if (pending_prediction_target_handoff_pc_mux) next_pc_reg = pending_prediction_target;
    else if (sel_prediction_r) next_pc_reg = i_predicted_target_r;
    else next_pc_reg = seq_next_pc_reg;
  end

  // PC registers
  logic pc_update_en;
  assign pc_update_en = i_reset || trap_or_mret || i_fence_i_flush || !i_stall;

  // Exports for the instruction MMU's PA shadows (see the port comment).
  assign o_next_pc = next_pc;
  assign o_next_pc_holds = !i_reset && !trap_or_mret && !i_fence_i_flush && !i_branch_taken &&
      !i_pd_redirect && !i_window_cannot_serve && !i_fetch_progress;
  assign o_pc_update_en = pc_update_en;

  // Phase 3 M2: the PC flops carry the FULL architectural value (no
  // producer-side masking). An out-of-map PC is matched against the 32-bit
  // fetch seam through if_stage's masked serve view, delivers a
  // fault-tagged bundle, and raises a precise instruction access fault via
  // the FETCH_FAULT pseudo-op — it never silently aliases.
  always_ff @(posedge i_clk) begin
    if (pc_update_en) begin
      o_pc     <= next_pc;
      o_pc_reg <= next_pc_reg;
    end
  end

`ifndef SYNTHESIS
  // The predecessor tag is speculative don't-care state while pending-valid is
  // low.  Once an episode is armed, it must remain the exact modulo-XLEN
  // predecessor of the captured branch PC through holds, stalls, and redirect
  // kill cycles.  The second assertion is a simulation-only equivalence oracle
  // for the retired live-adder predicate; no copy of that adder is synthesized.
  always_ff @(posedge i_clk) begin
    if (!i_reset && pending_prediction_valid) begin
      p_pending_prediction_prev_pc_matches_capture :
      assert (pending_prediction_prev_pc ==
              (pending_prediction_pc - riscv_pkg::PcIncrementCompressed));

      p_pending_prediction_prev_pc_predicate_equivalent :
      assert ((o_pc_reg == pending_prediction_prev_pc) ==
              (pending_prediction_pc ==
               (o_pc_reg + riscv_pkg::PcIncrementCompressed)));
    end
  end

  // The fast predictor pc_reg_next_misses_fetch_pc_for_prediction models the
  // only case its functional consumer needs: pc_reg is still behind a
  // word-aligned predicted fetch PC, and a plain instruction-size advance might
  // miss that PC's halfword lane. seq_next_pc_reg (the full result) is broader:
  // it also differs from o_pc when pc_reg is already equal to o_pc and the
  // current instruction advances normally. That is not a pending-handoff case
  // because the predicted op is already being emitted. It is also overridden
  // when the increment is held or NOP-forced: under a fetch stall/no-progress
  // L1I miss, under a registered control-flow/reset holdoff, or under i_sel_nop.
  // Gate this sim-only oracle to the fast predictor's actual valid domain.
  always_ff @(posedge i_clk) begin
    if (!i_reset && !fetch_stall && !o_any_holdoff_safe && !i_sel_nop &&
        i_prediction_used && !i_ras_predicted &&
        !i_slot2_prediction_used && !o_pc[1] && !i_predicted_target[1] &&
        (o_pc_reg != o_pc) &&
        i_prediction_requires_pc_reg_handoff) begin
      p_pending_prediction_fast_miss_matches_full :
      assert (pc_reg_next_misses_fetch_pc_for_prediction == (seq_next_pc_reg != o_pc));
    end
  end
`endif

`ifndef SYNTHESIS
  // Reference the original serial pending-handoff equations in simulation.
  // The synthesized equations above use identities implied by the mutually
  // exclusive before/at/after PC relations; this oracle keeps those reductions
  // pinned to the prior behavior for every fully known input combination.
  logic pending_crossing_ref;
  logic pending_cross_handoff_ref;
  logic pending_target_handoff_ref;
  logic pending_use_ref;
  logic pending_stale_ref;
  logic pending_pim_base_ref;
  logic pending_emit_ref;
  logic pending_hold_fetch_ref;
  logic pending_hold_consume_ref;
  logic pending_crossing_pc_mux_ref;
  logic pending_cross_handoff_pc_mux_ref;
  logic pending_target_handoff_pc_mux_ref;
  logic pending_use_pc_mux_ref;
  logic pending_stale_pc_mux_ref;
  logic pending_hold_fetch_pc_mux_ref;
  logic pending_hold_consume_pc_mux_ref;
  logic npc_consume_is_seq_ref;

  always_comb begin
    pending_crossing_ref = pending_prediction_effective && pending_prediction_allow_cross &&
                           pc_reg_before_pending && seq_reaches_pending;
    pending_cross_handoff_ref = pending_prediction_effective &&
                                pending_prediction_allow_cross && pending_crossing_ref;
    pending_target_handoff_ref = pending_prediction_effective &&
        (pending_prediction_allow_cross ?
             (pc_reg_at_pending && !pending_crossing_ref) :
             (pc_reg_at_pending && pending_prediction_pc_ready_q));
    pending_use_ref = pending_cross_handoff_ref || pending_target_handoff_ref;
    pending_stale_ref = pending_prediction_effective && !pending_use_ref && pc_reg_after_pending;
    pending_pim_base_ref = pending_prediction_effective && !pending_use_ref &&
                           !pending_stale_ref && pc_reg_at_pending_predecessor;
    pending_emit_ref = pending_pim_base_ref && pending_predecessor_needs_emit;
    pending_hold_fetch_ref = pending_prediction_effective && !pending_use_ref &&
                             !pending_stale_ref && !pending_emit_ref;
    pending_hold_consume_ref = pending_prediction_effective && pending_use_ref;

    pending_crossing_pc_mux_ref = pending_prediction_effective &&
                                  pending_prediction_allow_cross_pc_mux_q &&
                                  pc_reg_before_pending && seq_reaches_pending;
    pending_cross_handoff_pc_mux_ref = pending_prediction_effective &&
        pending_prediction_allow_cross_pc_mux_q && pending_crossing_pc_mux_ref;
    pending_target_handoff_pc_mux_ref = pending_prediction_effective &&
        (pending_prediction_allow_cross_pc_mux_q ?
             (pc_reg_at_pending && !pending_crossing_pc_mux_ref) :
             (pc_reg_at_pending && pending_prediction_pc_ready_q));
    pending_use_pc_mux_ref = pending_cross_handoff_pc_mux_ref || pending_target_handoff_pc_mux_ref;
    pending_stale_pc_mux_ref = pending_prediction_effective && !pending_use_pc_mux_ref &&
                               pc_reg_after_pending;
    pending_hold_fetch_pc_mux_ref = pending_prediction_effective &&
                                    !pending_use_pc_mux_ref &&
                                    !pending_stale_pc_mux_ref && !pending_emit_ref;
    pending_hold_consume_pc_mux_ref = pending_prediction_effective && pending_use_pc_mux_ref;
    npc_consume_is_seq_ref = !pending_cross_handoff_pc_mux_ref &&
                             pending_prediction_allow_cross_pc_mux_q &&
                             pending_target_handoff_pc_mux_ref &&
                             !pending_prediction_from_buffer;
  end

  always_comb begin
    if (!$isunknown(
            {
              pending_prediction_effective,
              pending_prediction_allow_cross,
              pending_prediction_allow_cross_pc_mux_q,
              o_pc_reg,
              pending_prediction_pc,
              pending_prediction_prev_pc,
              seq_next_pc_reg_hw_q,
              pending_prediction_pc_ready_q,
              i_window_cannot_serve_raw,
              carve_out_engaged_q,
              pending_prediction_from_buffer
            }
        )) begin
      p_pending_crossing_reduction_exact :
      assert (pending_prediction_crossing_pc_reg == pending_crossing_ref);
      p_pending_target_reduction_exact :
      assert (pending_prediction_target_handoff == pending_target_handoff_ref);
      p_pending_use_reduction_exact : assert (use_pending_prediction_for_pc_reg == pending_use_ref);
      p_pending_stale_reduction_exact : assert (stale_pending_prediction == pending_stale_ref);
      p_pending_pim_reduction_exact : assert (pim_base == pending_pim_base_ref);
      p_pending_emit_reduction_exact : assert (pending_imm_pred_emit == pending_emit_ref);
      p_pending_hold_reduction_exact :
      assert (hold_pending_prediction_fetch == pending_hold_fetch_ref);
      p_pending_fetch_holdoff_wcs0_cofactor_exact :
      assert (i_window_cannot_serve_raw ||
              o_pending_prediction_fetch_holdoff_wcs0 ==
              o_pending_prediction_fetch_holdoff);
      p_pending_fetch_holdoff_wcs_cofactor_exact :
      assert (!i_window_cannot_serve_raw ||
              o_pending_prediction_fetch_holdoff_wcs ==
              o_pending_prediction_fetch_holdoff);
      p_pending_consume_reduction_exact :
      assert (hold_pending_prediction_consume_fetch == pending_hold_consume_ref);
      p_pending_cross_pc_mux_reduction_exact :
      assert (pending_prediction_cross_handoff_pc_mux == pending_cross_handoff_pc_mux_ref);
      p_pending_target_pc_mux_reduction_exact :
      assert (pending_prediction_target_handoff_pc_mux == pending_target_handoff_pc_mux_ref);
      p_pending_use_pc_mux_reduction_exact :
      assert (use_pending_prediction_for_pc_reg_pc_mux == pending_use_pc_mux_ref);
      p_pending_hold_pc_mux_cofactor_exact :
      assert (
        pending_hold_fetch_pc_mux_ref ==
        (hold_pending_prediction_fetch_pc_mux && !pending_wcs_seq_override_pc_mux)
      );
      p_pending_consume_pc_mux_reduction_exact :
      assert (use_pending_prediction_for_pc_reg_pc_mux == pending_hold_consume_pc_mux_ref);
      p_npc_consume_seq_reduction_exact : assert (npc_consume_is_seq == npc_consume_is_seq_ref);

      // A FENCE-class redirect must disable every raw-WCS consumer in this
      // controller, independent of the served-window comparator result.
      p_fence_masks_raw_window_pending_state :
      assert (!i_fence_i_flush ||
              (!pending_prediction_effective && !pim_base &&
               !pending_imm_pred_emit && !hold_pending_prediction_fetch &&
               !hold_pending_prediction_fetch_pc_mux &&
               !hold_pending_prediction_consume_fetch &&
               !pending_wcs_seq_override_pc_mux &&
               !o_pending_prediction_fetch_holdoff &&
               !o_pending_prediction_fetch_holdoff_wcs0 &&
               !o_pending_prediction_fetch_holdoff_wcs));
      p_fence_target_wins_both_pc_muxes :
      assert (!i_fence_i_flush || i_reset || trap_or_mret ||
              (next_pc == i_fence_i_target && next_pc_reg == i_fence_i_target));
    end
  end

  // The carve latch may still contain its pre-FENCE value during the event
  // edge, but the synchronous clear above must remove it by the next cycle.
  logic fence_i_flush_q;
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      fence_i_flush_q <= 1'b0;
    end else begin
      if (fence_i_flush_q) begin
        p_fence_clears_carve_latch : assert (!carve_out_engaged_q);
      end
      fence_i_flush_q <= i_fence_i_flush;
    end
  end

  // Simulation-only equivalence oracle for the next_pc timing restructure.
  // npc_ref reproduces the ORIGINAL thirteen-arm serial priority chain
  // verbatim; nothing of it is synthesized. If the one-hot/balanced form ever
  // diverges from the priority semantics -- including the arm ORDER, which is
  // what makes redirects beat predictions -- these fire immediately, on every
  // cycle of every existing regression, rather than surfacing as a mystery
  // fetch bug later.
  logic [XLEN-1:0] npc_ref;
  always_comb begin
    if (i_reset) npc_ref = '0;
    else if (trap_or_mret) npc_ref = i_trap_target;
    else if (i_fence_i_flush) npc_ref = i_fence_i_target;
    else if (i_branch_taken) npc_ref = i_branch_target;
    else if (i_pd_redirect) npc_ref = i_pd_redirect_target;
    else if (i_window_cannot_serve) npc_ref = {o_pc_reg[XLEN-1:2], 2'b00};
    else if (!i_fetch_progress) npc_ref = o_pc;
    else if (i_slot2_prediction_used_for_pc) npc_ref = i_slot2_predicted_target;
    else if (i_prediction_used_for_pc) npc_ref = i_predicted_target;
    else if (o_pending_prediction_target_holdoff)
      npc_ref = (o_pc == pending_prediction_target) ? pending_prediction_target_next_word : o_pc;
    else if (use_pending_prediction_for_pc_reg_pc_mux) npc_ref = npc_consume_val;
    else if (halfword_target_lead_catchup) npc_ref = seq_next_pc_plus_2;
    else if (pending_hold_fetch_pc_mux_ref)
      npc_ref = pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
          pending_prediction_pc;
    else npc_ref = seq_next_pc;
  end

  always_comb begin
    p_next_pc_onehot : assert ($onehot(npc_sel));
    p_next_pc_matches_priority : assert (next_pc == npc_ref);
  end

  // The MMU's view of the arms is exact: a sequential arm is o_pc + d with
  // 0 <= d < 16, and every other arm's early operand IS its value.
  always_ff @(posedge i_clk) begin
    if (!i_reset && !$isunknown({o_pc, npc_seq, npc_cmp_val})) begin
      for (int unsigned k = 0; k < NPcArms; k++) begin
        if (npc_seq[k]) begin
          p_npc_seq_arm_is_pc_plus_small : assert ((npc_val[k] - o_pc) < 64'd16);
          p_npc_seq_verdict_exact :
          assert (npc_seq_verdict[k] == riscv_pkg::fetch_verdict(npc_val[k]));
        end else begin
          p_npc_cmp_val_is_arm_value : assert (npc_cmp_val[k] == npc_val[k]);
        end
      end
    end
  end
`endif

`ifdef FORMAL
  // pending_predecessor_needs_emit is the only raw served-window cofactor
  // downstream of the prediction-release companion.  Once the integrated
  // c_ext_state property proves that a release cannot overlap
  // pending_prediction_effective, every use of that cofactor must be masked.
  // Check all architectural pending-state consumers here, including the
  // duplicated PC-mux arm, rather than relying on the source-code factoring.
  always_comb begin
    if (!pending_prediction_effective) begin
      p_inactive_pending_masks_predecessor_base : assert (!pim_base);
      p_inactive_pending_masks_predecessor_emit : assert (!pending_imm_pred_emit);
      p_inactive_pending_masks_predecessor_hold : assert (!hold_pending_prediction_fetch);
      p_inactive_pending_masks_predecessor_pc_mux : assert (!hold_pending_prediction_fetch_pc_mux);
      p_inactive_pending_masks_wcs_pc_override : assert (!pending_wcs_seq_override_pc_mux);
      p_inactive_pending_masks_fetch_holdoff : assert (!o_pending_prediction_fetch_holdoff);
      p_inactive_pending_masks_fetch_holdoff_wcs0 :
      assert (!o_pending_prediction_fetch_holdoff_wcs0);
      p_inactive_pending_masks_fetch_holdoff_wcs : assert (!o_pending_prediction_fetch_holdoff_wcs);
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
      cover_pending_predecessor_emit :
      cover (pending_prediction_effective && pending_predecessor_needs_emit);
    end
  end
`endif

endmodule : pc_controller
