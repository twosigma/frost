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
    input logic i_flush,

    // Current PC for BTB lookup
    input logic [riscv_pkg::XLEN-1:0] i_pc,

    // Control signals for prediction gating (all should be registered for timing)
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic i_branch_taken,
    input logic i_any_holdoff_safe,     // Registered holdoff signals
    input logic i_is_32bit_spanning,
    input logic i_spanning_wait_for_fetch,
    input logic i_spanning_in_progress,
    input logic i_disable_branch_prediction,

    // BTB update interface (from EX stage)
    input logic                       i_btb_update,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_pc,
    input logic [riscv_pkg::XLEN-1:0] i_btb_update_target,
    input logic                       i_btb_update_taken,

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

    // Combinational prediction outputs (for pc_controller next_pc selection)
    output logic                       o_predicted_taken,
    output logic [riscv_pkg::XLEN-1:0] o_predicted_target,

    // Registered prediction outputs (for pipeline stage alignment)
    output logic o_prediction_used_r,  // Prediction was actually used (registered)
    output logic [riscv_pkg::XLEN-1:0] o_predicted_target_r,  // Target address (registered)

    // Control outputs
    output logic o_prediction_used,  // Prediction used this cycle (for pc_controller)
    output logic o_prediction_holdoff,  // One cycle after prediction (for c_ext_state)
    output logic o_btb_only_prediction_holdoff,  // Holdoff when BTB (not RAS) predicted
    output logic o_sel_prediction_r,  // Registered sel_prediction (for pc_controller pc_reg)
    output logic o_control_flow_to_halfword_pred,  // Prediction targets halfword address

    // RAS prediction outputs (for pipeline passthrough)
    output logic o_ras_predicted,  // RAS prediction was used
    output logic [riscv_pkg::XLEN-1:0] o_ras_predicted_target,  // RAS predicted return address
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_checkpoint_tos,  // TOS checkpoint for recovery
    output logic [riscv_pkg::RasPtrBits:0] o_ras_checkpoint_valid_count  // Valid count checkpoint
);

  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;
  localparam int unsigned RasDepth = riscv_pkg::RasDepth;

  // ===========================================================================
  // BTB Instance
  // ===========================================================================
  logic            btb_hit;
  logic            btb_predicted_taken;
  logic [XLEN-1:0] btb_predicted_target;

  branch_predictor #(
      .XLEN(XLEN)
  ) branch_predictor_inst (
      .i_clk,
      .i_rst(i_reset),

      // Prediction lookup (uses current PC)
      .i_pc(i_pc),
      .o_btb_hit(btb_hit),
      .o_predicted_taken(btb_predicted_taken),
      .o_predicted_target(btb_predicted_target),

      // Update from EX stage
      .i_update(i_btb_update),
      .i_update_pc(i_btb_update_pc),
      .i_update_target(i_btb_update_target),
      .i_update_taken(i_btb_update_taken)
  );

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

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      ras_misprediction_r <= 1'b0;
      ras_restore_tos_r <= '0;
      ras_restore_valid_count_r <= '0;
      ras_pop_after_restore_r <= 1'b0;
    end else begin
      ras_misprediction_r <= i_ras_misprediction;
      ras_restore_tos_r <= i_ras_restore_tos;
      ras_restore_valid_count_r <= i_ras_restore_valid_count;
      ras_pop_after_restore_r <= i_ras_pop_after_restore;
    end
  end

  // Compute prediction_allowed for BTB
  // BTB doesn't know instruction type, so must block halfword-aligned PCs
  // (could be second half of spanning instruction)
  // CRITICAL: Block during prediction_holdoff to prevent feedback loop.
  // After a prediction redirects PC, the next cycle has stale instruction data.
  // If BTB predicts again on that stale data, prediction_holdoff stays high forever.
  //
  // TIMING OPTIMIZATION: Keep BTB/RAS allow logic independent of late
  // i_branch_taken. Branch filtering is applied at the final "prediction used"
  // stage to avoid dragging branch resolution through the full predictor cone.
  logic prediction_common;
  logic prediction_allowed_stable;
  assign prediction_common = !i_reset && !i_trap_taken && !i_mret_taken && !i_stall &&
                             !i_any_holdoff_safe &&
                             !o_prediction_holdoff &&
                             !i_is_32bit_spanning && !i_spanning_wait_for_fetch &&
                             !i_spanning_in_progress &&
                             !i_disable_branch_prediction;
  assign prediction_allowed_stable = prediction_common && !i_pc[1];

  logic prediction_allowed;
  assign prediction_allowed = prediction_allowed_stable;

  // Compute ras_prediction_allowed - allows halfword-aligned PCs for compressed instructions.
  logic ras_prediction_allowed_stable;
  assign ras_prediction_allowed_stable = prediction_common && (!i_pc[1] || i_is_compressed);

  logic ras_prediction_allowed;
  assign ras_prediction_allowed = ras_prediction_allowed_stable;

  return_address_stack #(
      .RAS_DEPTH(RasDepth),
      .RAS_PTR_BITS(RasPtrBits)
  ) ras_inst (
      .i_clk,
      .i_rst(i_reset),
      .i_stall,
      .i_is_call(ras_is_call),
      .i_is_return(ras_is_return),
      .i_is_coroutine(ras_is_coroutine),
      .i_link_address(i_link_address),
      .i_prediction_allowed(ras_prediction_allowed),
      .i_btb_only_prediction_holdoff(o_btb_only_prediction_holdoff),
      .i_misprediction(ras_misprediction_r),
      .i_restore_tos(ras_restore_tos_r),
      .i_restore_valid_count(ras_restore_valid_count_r),
      .i_pop_after_restore(ras_pop_after_restore_r),
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
  //   - During spanning instruction processing (must complete spanning first)
  //   - For halfword-aligned PCs (might be spanning, can't predict safely)
  //   - When branch prediction is disabled (verification mode)
  //
  // TIMING: Uses i_any_holdoff_safe (registered) to break path from branch_taken.

  // sel_prediction for BTB only (without RAS)
  logic sel_btb_prediction;
  assign sel_btb_prediction = prediction_allowed && btb_predicted_taken;

  // sel_prediction for RAS (for returns, RAS takes priority over BTB)
  // Use ras_prediction_allowed which permits halfword-aligned PCs for compressed instructions
  logic sel_ras_prediction;
  assign sel_ras_prediction = ras_prediction_allowed && ras_valid;

  // Combined prediction selection: RAS takes priority for returns
  logic sel_prediction;
  assign sel_prediction = sel_ras_prediction || sel_btb_prediction;

  // Actual prediction use must still be blocked when branch resolution is taking
  // priority this cycle. Keep this as a final gate to shorten branch_taken depth.
  logic prediction_used_effective;
  assign prediction_used_effective = sel_prediction && !i_branch_taken;

  // Export combinational prediction for pc_controller
  // RAS prediction takes priority over BTB for returns
  assign o_predicted_taken = sel_ras_prediction || btb_predicted_taken;
  assign o_predicted_target = sel_ras_prediction ? ras_target : btb_predicted_target;
  assign o_prediction_used = prediction_used_effective;

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

  // Keep branch filtering in prediction_used_effective so registered metadata
  // only tracks predictions that were actually used.
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_used_r  <= 1'b0;
      o_predicted_target_r <= '0;
      o_sel_prediction_r   <= 1'b0;
    end else if (~i_stall) begin
      o_prediction_used_r  <= prediction_used_effective;
      // IMPORTANT: Register the combined RAS+BTB target, not just BTB target.
      // This is used for misprediction detection in EX stage - must match
      // the target we actually redirected PC to.
      o_predicted_target_r <= o_predicted_target;
      o_sel_prediction_r   <= prediction_used_effective;
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

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_holdoff <= 1'b0;
    end else if (~i_stall) begin
      // Set holdoff on cycle after prediction; clear on flush
      o_prediction_holdoff <= i_flush ? 1'b0 : prediction_used_effective;
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
  assign btb_only_prediction_effective = btb_only_prediction && !i_branch_taken;

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_btb_only_prediction_holdoff <= 1'b0;
    end else if (~i_stall) begin
      o_btb_only_prediction_holdoff <= i_flush ? 1'b0 : btb_only_prediction_effective;
    end
  end

endmodule : branch_prediction_controller
