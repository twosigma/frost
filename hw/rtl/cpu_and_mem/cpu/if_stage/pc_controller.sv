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
  Program Counter Controller

  Manages the program counter for the IF stage, computing the next PC based on
  control flow events, branch prediction, and instruction type (C-extension).

  Submodules:
  ===========
    pc_controller
    ├── control_flow_tracker       Holdoff signal generation for stale instruction cycles
    └── pc_increment_calculator    Sequential PC computation with parallel adders

  Block Diagram:
  ==============
    +-------------------------------------------------------------------------+
    |                         PC Controller                                   |
    |                                                                         |
    |  Control inputs --------------------------------------------------------|
    |  (trap, mret, branch, prediction)                                       |
    |                          |                                              |
    |                          v                                              |
    |  +-----------------------------------------+                            |
    |  |       control_flow_tracker              |                            |
    |  |  - holdoff signal generation            |                            |
    |  |  - stale cycle detection                |                            |
    |  +--------------------+--------------------+                            |
    |                       | holdoff signals                                 |
    |                       v                                                 |
    |  +-----------------------------------------+                            |
    |  |     pc_increment_calculator             |                            |
    |  |  - parallel adders (pc+0, pc+2, pc+4)   |--> seq_next_pc             |
    |  |  - C-ext aware increment selection      |--> seq_next_pc_reg         |
    |  +-----------------------------------------+                            |
    |                       |                                                 |
    |                       v                                                 |
    |  +-----------------------------------------+                            |
    |  |     Final PC Mux (Priority Encoded)     |                            |
    |  |  reset > trap > stall > branch >        |------------------> o_pc    |
    |  |  prediction > sequential                |------------------> o_pc_reg|
    |  +-----------------------------------------+                            |
    |                                                                         |
    +-------------------------------------------------------------------------+

  Key Functions:
  ==============
    1. Control flow tracking - Detect stale instruction cycles after redirects
    2. PC increment calculation - C-extension aware (+0, +2, or +4) [submodule]
    3. Mid-32bit correction - Handle landing in middle of 32-bit instruction
    4. Final PC selection - Priority mux with timing-optimized flat structure

  All branches and jumps (JAL, JALR, conditional branches) are resolved in the EX
  stage and come through the i_branch_taken/i_branch_target interface.
*/
module pc_controller #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_stall_registered,
    input logic i_flush,  // Pipeline flush - block state updates from garbage instructions
    input logic i_fence_i_flush,  // FENCE.I flush (registered pulse) - for pending prediction kill

    // Branch/Jump from EX stage (includes JAL, JALR, and all conditional branches)
    input logic            i_branch_taken,
    input logic [XLEN-1:0] i_branch_target,

    // Trap control
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,

    // C-extension state
    input logic i_spanning_wait_for_fetch,
    input logic i_spanning_in_progress,
    input logic i_spanning_eligible,  // Registered-only spanning condition (no BRAM dep)
    input logic i_spanning_to_halfword,
    input logic i_spanning_to_halfword_registered,
    input logic i_is_compressed,  // Combinational (for spanning detection, etc.)
    input logic i_is_compressed_for_pc,  // Registered (TIMING OPTIMIZATION: for PC increment)

    // Branch prediction (from branch_prediction_controller)
    input logic i_predicted_taken,  // BTB predicts taken (combinational)
    input logic [XLEN-1:0] i_predicted_target,  // Predicted target address (combinational)
    input logic [XLEN-1:0] i_predicted_target_r,  // Predicted target address (registered)
    input logic i_prediction_used,  // Prediction actually used this cycle
    input logic i_ras_predicted,  // Prediction came from RAS/return detection
    input logic i_sel_prediction_r,  // Registered prediction used (for pc_reg)
    // Predicted op must still execute in IF/PD/ID
    input logic i_prediction_requires_pc_reg_handoff,
    input logic i_prediction_holdoff,  // One cycle after prediction (for pc_increment)
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_prediction_used_from_buffer,  // Current prediction came from IF buffer
    input logic i_sel_nop,

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
    output logic o_pending_prediction_fetch_holdoff,
    output logic o_pending_prediction_target_holdoff
);

  // ===========================================================================
  // Control Flow Tracker - Holdoff Signal Generation
  // ===========================================================================
  // Track control flow changes and generate holdoff signals for stale cycles.
  // BRAM has latency, so i_instr is stale for 1-2 cycles after PC change.

  control_flow_tracker #(
      .XLEN(XLEN)
  ) control_flow_tracker_inst (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_flush,
      // Control flow sources
      .i_trap_taken,
      .i_mret_taken,
      .i_branch_taken,
      .i_prediction_used,
      .i_branch_target,
      .i_trap_target,
      .i_predicted_target,
      // C-extension spanning holdoff
      .i_spanning_to_halfword_registered,
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
  // PC Increment Calculator - Sequential PC Computation
  // ===========================================================================
  // Computes next sequential PC values using parallel adders for timing optimization.
  // See pc_increment_calculator.sv for detailed implementation.

  logic [XLEN-1:0] seq_next_pc, seq_next_pc_reg;

  pc_increment_calculator #(
      .XLEN(XLEN)
  ) pc_increment_calculator_inst (
      // Current PC values
      .i_pc(o_pc),
      .i_pc_reg(o_pc_reg),

      // C-extension state signals
      .i_spanning_wait_for_fetch,
      .i_spanning_in_progress,
      .i_spanning_eligible,
      .i_spanning_to_halfword,
      .i_spanning_to_halfword_registered,
      .i_is_compressed,
      .i_is_compressed_for_pc,

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
      .o_seq_next_pc_reg(seq_next_pc_reg)
  );

  // ===========================================================================
  // Mid-32bit Correction Detection
  // ===========================================================================
  // Detect when we've landed in the middle of a 32-bit instruction

  logic prev_was_32bit;

  // Use o_any_holdoff_safe to break timing path. Also clear during flush
  // to prevent garbage instructions from corrupting this state.
  //
  // CRITICAL: Clear prev_was_32bit on both i_prediction_used AND i_sel_prediction_r.
  // - i_prediction_used = 1 in cycle N (when prediction fires)
  // - i_sel_prediction_r = 1 in cycle N+1 (when o_pc_reg is about to update to target)
  //
  // We need i_sel_prediction_r because:
  // - Cycle N: i_prediction_used=1, clear prev_was_32bit
  // - Cycle N+1: i_prediction_used=0 (blocked by !o_pc[1] since o_pc=target), but
  //   prev_was_32bit could be SET by the branch instruction being processed
  // - If we don't clear in cycle N+1, prev_was_32bit carries stale state to cycle N+2
  // - In cycle N+2: o_pc_reg=target, prev_was_32bit=1 (stale), causes incorrect NOP
  //
  // Likewise, sel_nop bubbles can carry stale bytes from a previous path. Treat
  // them as non-instructions here so the mid-32bit correction logic cannot fire
  // on a real halfword PC like 0x316e using stale 32-bit history from 0x317c.
  always_ff @(posedge i_clk) begin
    if (i_reset || o_any_holdoff_safe || i_flush || i_prediction_used || i_sel_prediction_r ||
        i_sel_nop || pending_prediction_target_holdoff_q)
      prev_was_32bit <= 1'b0;
    else if (!i_stall)
      prev_was_32bit <= !i_is_compressed && !i_spanning_in_progress && !i_spanning_wait_for_fetch;
  end

  assign o_mid_32bit_correction = prev_was_32bit && o_pc_reg[1] &&
                                  !i_spanning_in_progress && !i_spanning_wait_for_fetch &&
                                  !pending_prediction_target_holdoff_q;

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
  logic sel_prediction_r;
  assign sel_prediction_r = !i_reset && i_sel_prediction_r && !pending_prediction_valid;

  logic            pending_prediction_valid;
  logic [XLEN-1:0] pending_prediction_pc;
  logic [XLEN-1:0] pending_prediction_target;
  logic            pending_prediction_effective;
  logic            pending_prediction_from_buffer;
  logic            prediction_needs_pending;
  logic            use_pending_prediction_for_pc_reg;
  logic            pending_prediction_crossing_pc_reg;
  logic            pending_prediction_cross_handoff;
  logic            pending_prediction_target_handoff;
  logic            pending_prediction_allow_cross;
  logic            stale_pending_prediction;
  logic            hold_pending_prediction_fetch;
  logic            hold_pending_prediction_consume_fetch;
  (* keep = "true" *)logic            pending_prediction_cross_handoff_pc_mux;
  (* keep = "true" *)logic            pending_prediction_target_handoff_pc_mux;
  (* keep = "true" *)logic            use_pending_prediction_for_pc_reg_pc_mux;
  (* keep = "true" *)logic            stale_pending_prediction_pc_mux;
  (* keep = "true" *)logic            hold_pending_prediction_fetch_pc_mux;
  (* keep = "true" *)logic            hold_pending_prediction_consume_fetch_pc_mux;
  logic            pending_prediction_target_holdoff_q;
  logic            pending_prediction_target_holdoff_prev_q;
  logic            pending_prediction_pc_ready_q;
  logic            redirect_kill_pending_q;
  logic [XLEN-2:0] pending_prediction_pc_hw;
  logic [XLEN-1:0] pending_prediction_target_next_word;
  logic [XLEN-2:0] pc_reg_hw;
  logic            halfword_target_lead_catchup;
  logic            clear_pending_prediction_state;
  logic            pending_prediction_valid_d;
  logic            pending_prediction_allow_cross_d;
  logic            pending_prediction_from_buffer_d;

  assign pending_prediction_pc_hw = pending_prediction_pc[XLEN-1:1];
  assign pending_prediction_target_next_word =
      {pending_prediction_target[XLEN-1:2], 2'b00} + riscv_pkg::PcIncrement32bit;
  assign pc_reg_hw = o_pc_reg[XLEN-1:1];

  // TIMING OPTIMIZATION: Register seq_next_pc_reg_hw before the pending
  // prediction crossing comparison. This breaks the critical 24-level path
  // from mispredict_recovery → flush → is_compressed → pc_reg_normal →
  // seq_next_pc_reg → CARRY8 comparison → pending_prediction_allow_cross/CE.
  // The 1-cycle-old value is safe because stale_pending_prediction and
  // redirect_kill_pending_q handle delayed crossing detection gracefully.
  logic [XLEN-2:0] seq_next_pc_reg_hw_q;
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_branch_taken || i_trap_taken || i_mret_taken)
      seq_next_pc_reg_hw_q <= '0;
    else if (!i_stall) seq_next_pc_reg_hw_q <= seq_next_pc_reg[XLEN-1:1];
  end
  // Lower-half, word-aligned predictions only need the pending-handoff path
  // when pc_reg would otherwise skip over the branch PC. Treating every such
  // prediction as pending breaks normal taken-call flow: fetch redirects to the
  // target, but pc_reg gets forced back through a spurious pending handoff and
  // eventually re-tags non-control-flow PCs as predicted-taken. Keep the
  // pending path restricted to the original "pc_reg would advance past o_pc"
  // case and leave ordinary registered handoffs alone.
  assign prediction_needs_pending =
      i_prediction_used && !i_ras_predicted &&
      (o_pc[1] || i_predicted_target[1] ||
       ((seq_next_pc_reg != o_pc) && i_prediction_requires_pc_reg_handoff));
  // TIMING: Replace !i_flush with !i_fence_i_flush to break the critical path
  // from mispredict_recovery_pending through flush_pipeline into this cone.
  // For mispredict, !i_branch_taken already kills the pending prediction.
  // For trap/mret, !i_trap_taken/!i_mret_taken already kill it.
  // Only FENCE.I needs explicit suppression here (and it's already registered).
  assign pending_prediction_effective = pending_prediction_valid && !redirect_kill_pending_q &&
                                        !i_fence_i_flush && !i_branch_taken &&
                                        !i_trap_taken && !i_mret_taken;
  assign o_pending_prediction_active = pending_prediction_effective;

  // A compressed branch/return can be predicted from the upper halfword of a
  // 32-bit fetch word. In that case pc_reg may advance from the lower halfword
  // to the next word and never equal the branch PC exactly. Treat "crossing"
  // the pending halfword as ready-to-apply, and clear anything already behind
  // pc_reg so stale redirects cannot pin fetch forever.
  assign pending_prediction_crossing_pc_reg =
      pending_prediction_effective &&
      pending_prediction_allow_cross &&
      (pc_reg_hw < pending_prediction_pc_hw) &&
      (seq_next_pc_reg_hw_q >= pending_prediction_pc_hw);
  assign pending_prediction_cross_handoff =
      pending_prediction_effective &&
      pending_prediction_allow_cross &&
      pending_prediction_crossing_pc_reg;
  assign pending_prediction_target_handoff =
      pending_prediction_effective &&
      (pending_prediction_allow_cross ?
           ((o_pc_reg == pending_prediction_pc) &&
            !pending_prediction_crossing_pc_reg) :
           ((o_pc_reg == pending_prediction_pc) &&
            pending_prediction_pc_ready_q));
  assign use_pending_prediction_for_pc_reg =
      pending_prediction_cross_handoff ||
      pending_prediction_target_handoff;
  assign stale_pending_prediction = pending_prediction_effective &&
                                    !use_pending_prediction_for_pc_reg &&
                                    (pc_reg_hw > pending_prediction_pc_hw);
  assign hold_pending_prediction_fetch =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
      !stale_pending_prediction;
  assign hold_pending_prediction_consume_fetch =
      pending_prediction_effective && use_pending_prediction_for_pc_reg;
  // Keep a PC-mux-local copy of the pending-handoff cone so synthesis can
  // place it near the next_pc/next_pc_reg muxes instead of routing the shared
  // state/output version back across the IF control logic.
  assign pending_prediction_cross_handoff_pc_mux =
      pending_prediction_effective &&
      pending_prediction_allow_cross &&
      pending_prediction_crossing_pc_reg;
  assign pending_prediction_target_handoff_pc_mux =
      pending_prediction_effective &&
      (pending_prediction_allow_cross ?
           ((o_pc_reg == pending_prediction_pc) &&
            !pending_prediction_crossing_pc_reg) :
           ((o_pc_reg == pending_prediction_pc) &&
            pending_prediction_pc_ready_q));
  assign use_pending_prediction_for_pc_reg_pc_mux =
      pending_prediction_cross_handoff_pc_mux ||
      pending_prediction_target_handoff_pc_mux;
  assign stale_pending_prediction_pc_mux =
      pending_prediction_effective &&
      !use_pending_prediction_for_pc_reg_pc_mux &&
      (pc_reg_hw > pending_prediction_pc_hw);
  assign hold_pending_prediction_fetch_pc_mux =
      pending_prediction_effective &&
      !use_pending_prediction_for_pc_reg_pc_mux &&
      !stale_pending_prediction_pc_mux;
  assign hold_pending_prediction_consume_fetch_pc_mux =
      pending_prediction_effective &&
      use_pending_prediction_for_pc_reg_pc_mux;
  assign o_pending_prediction_holdoff =
      hold_pending_prediction_fetch || hold_pending_prediction_consume_fetch;
  assign o_pending_prediction_target_handoff = pending_prediction_target_handoff;
  assign o_pending_prediction_fetch_holdoff =
      hold_pending_prediction_fetch ||
      (hold_pending_prediction_consume_fetch &&
       pending_prediction_allow_cross &&
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
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken) begin
      pending_prediction_target_holdoff_q <= 1'b0;
    end else if (!i_stall) begin
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
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken) begin
      pending_prediction_target_holdoff_prev_q <= 1'b0;
    end else if (!i_stall) begin
      pending_prediction_target_holdoff_prev_q <= pending_prediction_target_holdoff_q;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_reset) redirect_kill_pending_q <= 1'b0;
    else redirect_kill_pending_q <= i_flush || i_branch_taken || i_trap_taken || i_mret_taken;
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken) begin
      pending_prediction_pc_ready_q <= 1'b0;
    end else if (!i_stall) begin
      if (redirect_kill_pending_q || pending_prediction_target_handoff ||
          stale_pending_prediction) begin
        pending_prediction_pc_ready_q <= 1'b0;
      end else if (pending_prediction_effective && !pending_prediction_allow_cross &&
                   (o_pc == pending_prediction_pc)) begin
        pending_prediction_pc_ready_q <= 1'b1;
      end
    end
  end

  assign clear_pending_prediction_state =
      redirect_kill_pending_q || pending_prediction_target_handoff ||
      stale_pending_prediction;

  always_comb begin
    pending_prediction_valid_d = pending_prediction_valid;
    pending_prediction_allow_cross_d = pending_prediction_allow_cross;
    pending_prediction_from_buffer_d = pending_prediction_from_buffer;

    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken) begin
      pending_prediction_valid_d = 1'b0;
      pending_prediction_allow_cross_d = 1'b0;
      pending_prediction_from_buffer_d = 1'b0;
    end else if (!i_stall) begin
      if (clear_pending_prediction_state) begin
        pending_prediction_valid_d = 1'b0;
        pending_prediction_allow_cross_d = 1'b0;
        pending_prediction_from_buffer_d = 1'b0;
      end else if (prediction_needs_pending) begin
        pending_prediction_valid_d = 1'b1;
        pending_prediction_allow_cross_d = o_pc[1];
        pending_prediction_from_buffer_d = i_prediction_used_from_buffer;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    pending_prediction_valid <= pending_prediction_valid_d;
    pending_prediction_allow_cross <= pending_prediction_allow_cross_d;
    pending_prediction_from_buffer <= pending_prediction_from_buffer_d;
  end

  // TIMING: Use !pending_prediction_valid as the CE instead of the
  // combinational prediction_needs_pending.  This breaks the 11-level critical
  // path from instruction-memory BRAM → decode → prediction_needs_pending → CE
  // of these 64-bit buses.  The invariant is: prediction_needs_pending can only
  // fire when pending_prediction_valid is 0 (fetch is held while a prediction is
  // pending, so no new BTB hit can occur).  Capturing speculatively every
  // non-stalled cycle while valid is 0 means the data is ready the instant the
  // control block sets valid.
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      pending_prediction_pc     <= '0;
      pending_prediction_target <= '0;
    end else if (!i_stall && !pending_prediction_valid) begin
      pending_prediction_pc     <= o_pc;
      pending_prediction_target <= i_predicted_target;
    end
  end

  logic [XLEN-1:0] next_pc, next_pc_reg;
  logic trap_or_mret;
  assign trap_or_mret = i_trap_taken || i_mret_taken;

  always_comb begin
    if (i_reset) next_pc = '0;
    else if (trap_or_mret) next_pc = i_trap_target;
    else if (i_stall) next_pc = o_pc;
    else if (i_branch_taken) next_pc = i_branch_target;
    else if (i_prediction_used) next_pc = i_predicted_target;
    // During the target-holdoff bubble, keep fetch at most one word ahead of
    // the still-held target PC. Letting it run farther ahead makes pc_reg pick
    // up instruction-size metadata from the wrong word; freezing it on the
    // target loses the normal one-word BRAM lead and shifts later spanning
    // assembly by a full word.
    else if (o_pending_prediction_target_holdoff)
      next_pc = (o_pc == pending_prediction_target) ? pending_prediction_target_next_word : o_pc;
    else if (hold_pending_prediction_consume_fetch_pc_mux)
      // Upper-half predictions need a 2-step handoff:
      // 1. Land pc_reg on the predicted branch PC so the control-flow
      //    instruction itself still flows through IF/PD/ID.
      // 2. On the following cycle, advance pc_reg to the real target.
      //
      // Keep fetch parked on the target during step 1. Once pc_reg is actually
      // consuming the predicted control-flow op in step 2, restore the normal
      // one-word fetch lead immediately. Holding fetch on the target for both
      // steps leaves the next target instruction paired with the stale target
      // word instead of the following word.
      next_pc =
          pending_prediction_cross_handoff_pc_mux ? pending_prediction_target :
          ((pending_prediction_allow_cross &&
            pending_prediction_target_handoff_pc_mux &&
            !pending_prediction_from_buffer) ?
               seq_next_pc : pending_prediction_target);
    else if (halfword_target_lead_catchup)
      // After a non-cross halfword target bubble, the compressed target op is
      // already consuming the target word. Restore the normal fetch lead by
      // skipping the extra halfword-parcel step and requesting the following
      // word immediately.
      next_pc = seq_next_pc + riscv_pkg::PcIncrementCompressed;
    else if (hold_pending_prediction_fetch_pc_mux)
      next_pc = pending_prediction_allow_cross ? pending_prediction_target : pending_prediction_pc;
    else next_pc = seq_next_pc;
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
    else if (i_stall) next_pc_reg = o_pc_reg;
    else if (i_branch_taken) next_pc_reg = i_branch_target;
    // After a non-cross pending handoff, the first target cycle is a bubble
    // while BRAM returns the target word. Hold pc_reg on the target during
    // that bubble; advancing here pairs the arriving target word with the next
    // halfword PC and corrupts C-extension alignment on loop back-edges.
    else if (o_pending_prediction_target_holdoff) next_pc_reg = o_pc_reg;
    else if (pending_prediction_effective && !pending_prediction_allow_cross &&
             !use_pending_prediction_for_pc_reg_pc_mux)
      next_pc_reg = pending_prediction_pc;
    else if (pending_prediction_cross_handoff_pc_mux) next_pc_reg = pending_prediction_pc;
    else if (pending_prediction_target_handoff_pc_mux) next_pc_reg = pending_prediction_target;
    else if (sel_prediction_r) next_pc_reg = i_predicted_target_r;
    else next_pc_reg = seq_next_pc_reg;
  end

  // PC registers
  always_ff @(posedge i_clk) begin
    o_pc <= next_pc;
    o_pc_reg <= next_pc_reg;
  end

`ifndef SYNTHESIS
`endif

endmodule : pc_controller
