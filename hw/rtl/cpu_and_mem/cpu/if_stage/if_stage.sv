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
 * Instruction Fetch (IF) Stage - first stage of the in-order front-end
 *
 * This top-level module orchestrates instruction fetching by instantiating and
 * connecting specialized submodules organized into two subsystems:
 *
 * Submodule Hierarchy:
 * ====================
 *   if_stage
 *   ├── pc_controller               PC management, next-PC selection
 *   │   └── control_flow_tracker        Holdoff signal generation
 *   ├── branch_prediction/          Branch prediction subsystem
 *   │   ├── branch_predictor            32-entry BTB (combinational lookup)
 *   │   ├── branch_prediction_controller  Prediction gating and registration
 *   │   └── prediction_metadata_tracker   Stall/spanning metadata handling
 *   └── c_extension/                Compressed instruction subsystem
 *       ├── c_ext_state                 State machines (spanning, buffer)
 *       └── instruction_aligner         Parcel selection and type detection
 *
 * Block Diagram:
 * ==============
 *   +-------------------------------------------------------------------------+
 *   |                              IF Stage                                   |
 *   |                                                                         |
 *   |  +------------------------------------------------------------------+   |
 *   |  |              Branch Prediction Subsystem                         |   |
 *   |  |  +-------------+  +--------------------+  +------------------+   |   |
 *   |  |  |   branch_   |  | branch_prediction_ |  | prediction_      |   |   |
 *   |  |  |  predictor  |->|    controller      |->| metadata_tracker |---+---+-> to PD
 *   |  |  |   (BTB)     |  |                    |  |                  |   |   |
 *   |  |  +------^------+  +---------+----------+  +------------------+   |   |
 *   |  +---------+-------------------+------------------------------------+   |
 *   |  BTB update|                   | prediction                             |
 *   |  from EX   |                   v                                        |
 *   |            |        +----------------------+                            |
 *   |            +--------|    pc_controller     |----------------------> o_pc|
 *   |                     +----------+-----------+                            |
 *   |  +-------------------------+---+------------------------------------+   |
 *   |  |             C-Extension Subsystem                                |   |
 *   |  |  +-------------+  +-----v--------------+                         |   |
 *   |  |  | c_ext_state |->|instruction_aligner |-------------------------+---+-> to PD
 *   |  |  |             |  |                    |                         |   |
 *   |  |  +-------------+  +--------------------+                         |   |
 *   |  +------------------------------------------------------------------+   |
 *   |                                                                         |
 *   |  i_instr ---------------------------------------------------------------|
 *   +-------------------------------------------------------------------------+
 *
 * Features:
 * =========
 *   - RISC-V C extension support (compressed 16-bit instructions)
 *   - Handles 32-bit instructions spanning two memory words (PC[1]=1)
 *   - Branch prediction with 32-entry BTB
 *   - Outputs raw parcel + selection signals for PD stage decompression
 *
 * TIMING OPTIMIZATION:
 *   Decompression moved to PD stage for better timing. IF stage outputs raw
 *   16-bit parcel and selection signals; PD stage performs the actual RVC
 *   decompression. This breaks the long combinational path from memory read
 *   through decompression to pipeline registers.
 *
 *   Branches and jumps are resolved by the OOO integration logic and
 *   redirected through the i_from_ex_comb interface.
 */
module if_stage #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    input logic [3:0] i_instr_sideband,  // Predecode: {next_sb[1:0], current_sb[1:0]}
    input logic i_instr_bank_sel_r,  // Fetch-word parity (PC[2] from fetch cycle)
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    input logic i_frontend_state_flush,
    input logic i_fence_i_flush,  // FENCE.I flush (registered pulse) - plumbed to pc_controller
    input logic [XLEN-1:0] i_fence_i_target,
    // Branch prediction control (for verification - prevents BTB predictions)
    input logic i_disable_branch_prediction,
    // PD backward-branch heuristic redirect (from pd_stage)
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    output logic [XLEN-1:0] o_pc,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd
);

  // ===========================================================================
  // Signal Declarations - Grouped by Submodule Interface
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Branch Prediction Controller Interface (branch_prediction_controller)
  // ---------------------------------------------------------------------------
  logic btb_predicted_taken;  // Combinational: BTB hit with taken prediction
  logic [XLEN-1:0] btb_predicted_target;  // Combinational: Predicted target address
  logic prediction_used_r;  // Registered: Prediction was applied
  logic [XLEN-1:0] btb_predicted_target_r;  // Registered: Target for pipeline alignment
  logic prediction_used;  // Current prediction being used
  logic prediction_holdoff;  // Block prediction (stale data)
  logic btb_only_prediction_holdoff;  // Holdoff when BTB (not RAS) predicted - instr valid
  logic ras_prediction_holdoff;  // Holdoff when RAS predicted - next instr is stale
  logic disable_branch_prediction_effective;  // Also suppress predictions
                                              // during pending halfword redirect handoff
  logic sel_prediction_r;  // Select registered prediction target
  logic prediction_requires_pc_reg_handoff;  // Predicted op must still reach IF/PD/ID
  logic control_flow_to_halfword_pred;  // Prediction targets halfword address

  // RAS (Return Address Stack) signals
  logic ras_predicted;  // RAS prediction was used
  logic [XLEN-1:0] ras_predicted_target;  // RAS predicted return address
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos;  // TOS checkpoint
  logic [riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count;  // Valid count checkpoint

  // ---------------------------------------------------------------------------
  // PC Controller Interface (pc_controller)
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] pc;  // Current program counter (fetch address)
  logic [XLEN-1:0] pc_reg;  // Registered PC (instruction address)
  logic control_flow_change;  // Branch/jump taken this cycle
  logic control_flow_holdoff;  // Wait cycle after control flow change
  logic control_flow_to_halfword;  // Target address is halfword-aligned
  logic control_flow_to_halfword_r;  // Registered version for timing
  logic reset_holdoff;  // Wait cycle after reset
  logic any_holdoff;  // Any holdoff condition active
  logic any_holdoff_safe;  // Safe holdoff (registered signals only)
  logic mid_32bit_correction;  // Correction for 32-bit at halfword boundary
  logic pending_prediction_active;  // pc_reg still walking old-path instructions
  logic pending_prediction_target_handoff;  // Old-path branch consumed, pc_reg jumps to target
  logic pending_prediction_holdoff;  // Halfword prediction target while pc_reg catches up
  logic pending_prediction_fetch_holdoff;  // Pending redirect phase with stale fetch data
  logic pending_prediction_target_holdoff;  // First target cycle still returns stale data

  // ---------------------------------------------------------------------------
  // C-Extension State Interface (c_ext_state)
  // ---------------------------------------------------------------------------
  logic [31:0] instr_buffer;  // Buffered instruction for stall recovery
  logic [31:0] next_word_buffer;  // Next word captured alongside buffer (for spanning)
  logic prev_was_compressed_at_lo;  // Previous instr was compressed at addr[1]=0
  logic is_compressed_for_buffer;  // Stall-restored is_compressed
  logic is_compressed_for_pc;  // Registered is_compressed for PC timing
  logic use_buffer_after_prediction;  // Use buffer after prediction-from-buffer holdoff
  logic is_compressed_saved;  // Saved is_compressed for fast path
  logic saved_values_valid;  // Saved values are valid (not invalidated by control flow)
  logic [1:0] instr_buffer_sideband;  // Predecode sideband for instruction buffer

  // ---------------------------------------------------------------------------
  // Instruction Aligner Interface (instruction_aligner)
  // ---------------------------------------------------------------------------
  logic [15:0] raw_parcel;  // Selected 16-bit parcel for RVC decompression
  logic [31:0] effective_instr;  // Raw current word (for state machine/buffer)
  logic is_compressed;  // Current instruction is 16-bit compressed
  logic is_compressed_fast;  // Fast path for PC-critical path (registered selects only)
  logic sel_nop;  // Select NOP (during holdoff/flush)
  logic sel_nop_align;
  logic sel_compressed;  // Select compressed instruction path
  logic use_instr_buffer;  // Use buffered instruction

  // ---------------------------------------------------------------------------
  // Derived Signals and Stall State
  // ---------------------------------------------------------------------------
  logic prev_was_compressed_at_lo_saved;  // Saved for stall recovery
  logic ras_instruction_valid;
  logic ras_instruction_valid_live;
  (* keep = "true", max_fanout = 32 *) logic if_stage_stall;
  (* keep = "true", max_fanout = 32 *) logic if_stage_stall_registered;
  (* keep = "true" *) logic pc_controller_stall;

  // TIMING OPTIMIZATION: Pass raw instruction to aligner, not flush-gated.
  // This breaks the timing path: flush -> is_compressed -> pc_increment -> PC.
  // When flush is true, pc_controller selects branch_target anyway, so
  // is_compressed value during flush doesn't affect the PC output.
  // NOP insertion during flush is handled by PD stage, not here.
  // C-extension state updates are already protected by flush checks in c_ext_state.
  // NOTE: i_pd_redirect is intentionally NOT included in disable_branch_prediction
  // to avoid a timing-critical cross-module path.  Wrong-path BTB hits during a
  // PD redirect cycle are cleaned up via redirect_kill_pending_q and pd_redirect_q.
  assign disable_branch_prediction_effective =
      i_disable_branch_prediction || pending_prediction_holdoff ||
      i_pipeline_ctrl.flush || i_frontend_state_flush;
  assign ras_instruction_valid_live = !sel_nop &&
                                      (!prediction_holdoff || btb_only_prediction_holdoff);

  // IF internal state cleanup is allowed to lag the architectural pipeline
  // flush by one cycle. OOO trap/MRET recovery uses this to pay an extra
  // redirect bubble in IF while still flushing PD/ID immediately.
  logic flush_for_c_ext_safe;
  assign flush_for_c_ext_safe = i_frontend_state_flush;
  assign if_stage_stall = i_pipeline_ctrl.stall;
  assign if_stage_stall_registered = i_pipeline_ctrl.stall_registered;
  assign pc_controller_stall = if_stage_stall;

  // ===========================================================================
  // Branch Prediction Controller
  // ===========================================================================
  // With 64-bit fetch, spanning is eliminated — no spanning detection needed.
  // RAS detection uses the assembled instruction directly.
  logic [31:0] ras_instruction;
  logic [15:0] ras_raw_parcel;
  logic        ras_is_compressed;
  logic        ras_saved_input_available_sc;
  logic        ras_replay_inputs;
  logic        ras_instruction_valid_sc;

  // Forward declarations (moved before first use to avoid Vivado warnings)
  logic        use_saved_values;
  assign use_saved_values = if_stage_stall_registered && saved_values_valid;
  logic            prediction_reset_c_ext;
  logic [    15:0] raw_parcel_sc;
  logic [    31:0] assembled_instr_sc;
  logic [XLEN-1:0] instruction_pc_sc;
  logic [XLEN-1:0] link_address_sc;
  logic            prediction_from_buffer_holdoff;
  logic            prediction_used_from_buffer;

  assign ras_replay_inputs = if_stage_stall_registered && ras_saved_input_available_sc;

  assign ras_instruction = assembled_instr_sc;
  assign ras_raw_parcel = raw_parcel_sc;
  assign ras_is_compressed = ras_replay_inputs ? is_compressed_for_buffer : is_compressed;
  assign ras_instruction_valid = !any_holdoff_safe &&
                                 !i_from_ex_comb.branch_taken &&
                                 !i_trap_ctrl.trap_taken &&
                                 !i_trap_ctrl.mret_taken &&
                                 ras_instruction_valid_sc &&
                                 (!if_stage_stall_registered ||
                                   ras_saved_input_available_sc);
  assign prediction_used_from_buffer = prediction_used && use_instr_buffer;

  // ===========================================================================
  // RAS Input Pipeline Register (Timing Optimization)
  // ===========================================================================
  // Register instruction/validity before the branch_prediction_controller to
  // break the critical path:
  //   mispredict_recovery → flush → control_flow → buffer_select →
  //   ras_instruction → RAS call/return detect → prediction_used → PC
  // This was -1.027ns WNS with 16 LUT levels.  Registering here cuts ~10
  // levels from the chain.
  //
  // Cost: RAS push/pop fires 1 cycle after the instruction appears.  Return
  // predictions are 1 cycle stale.  This is a minor IPC cost; the pending
  // prediction mechanism already handles deferred redirects.  RAS is purely
  // speculative — mispredictions are caught at commit.
  logic [    31:0] ras_instruction_q;
  logic [    15:0] ras_raw_parcel_q;
  logic            ras_is_compressed_q;
  logic            ras_instruction_valid_q;
  logic [XLEN-1:0] link_address_sc_q;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      ras_instruction_valid_q <= 1'b0;
    end else begin
      ras_instruction_q       <= ras_instruction;
      ras_raw_parcel_q        <= ras_raw_parcel;
      ras_is_compressed_q     <= ras_is_compressed;
      ras_instruction_valid_q <= ras_instruction_valid;
      link_address_sc_q       <= link_address_sc;
    end
  end

  branch_prediction_controller branch_prediction_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      // In OOO mode, serialization stalls (for unresolved older branches/CSRs)
      // must also block new predictions. Otherwise a younger speculative branch
      // or return can arm a pending redirect that survives long enough to fight
      // with the older instruction's eventual mispredict recovery.
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),

      // Current PC for BTB lookup
      .i_pc(pc),

      // Control signals for prediction gating
      .i_trap_taken(i_trap_ctrl.trap_taken),
      .i_mret_taken(i_trap_ctrl.mret_taken),
      .i_branch_taken(i_from_ex_comb.branch_taken),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_is_32bit_spanning(1'b0),
      .i_spanning_wait_for_fetch(1'b0),
      .i_spanning_in_progress(1'b0),
      .i_use_instr_buffer(use_instr_buffer),
      .i_disable_branch_prediction(disable_branch_prediction_effective),

      // BTB update interface (from EX stage)
      .i_btb_update(i_from_ex_comb.btb_update),
      .i_btb_update_pc(i_from_ex_comb.btb_update_pc),
      .i_btb_update_target(i_from_ex_comb.btb_update_target),
      .i_btb_update_taken(i_from_ex_comb.btb_update_taken),
      .i_btb_update_compressed(i_from_ex_comb.btb_update_compressed),
      .i_btb_update_requires_pc_reg_handoff(i_from_ex_comb.btb_update_requires_pc_reg_handoff),

      // RAS inputs (pipelined — breaks flush → RAS → prediction_used path)
      // Registered versions of the instruction/validity signals.  See
      // "RAS Input Pipeline Register" block above for rationale.
      .i_instruction(ras_instruction_q),
      .i_raw_parcel(ras_raw_parcel_q),
      .i_is_compressed(ras_is_compressed_q),
      .i_instruction_valid(ras_instruction_valid_q),
      .i_link_address(link_address_sc_q),

      // RAS misprediction recovery (from EX stage)
      .i_ras_misprediction(i_from_ex_comb.ras_misprediction),
      .i_ras_restore_tos(i_from_ex_comb.ras_restore_tos),
      .i_ras_restore_valid_count(i_from_ex_comb.ras_restore_valid_count),
      .i_ras_pop_after_restore(i_from_ex_comb.ras_pop_after_restore),
      .i_ras_push_after_restore(i_from_ex_comb.ras_push_after_restore),
      .i_ras_push_address_after_restore(i_from_ex_comb.ras_push_address_after_restore),

      // Combinational prediction outputs (for pc_controller)
      .o_predicted_taken (btb_predicted_taken),
      .o_predicted_target(btb_predicted_target),

      // Registered prediction outputs (for pipeline alignment)
      .o_prediction_used_r (prediction_used_r),
      .o_predicted_target_r(btb_predicted_target_r),

      // Control outputs
      .o_prediction_used(prediction_used),
      .o_prediction_holdoff(prediction_holdoff),
      .o_btb_only_prediction_holdoff(btb_only_prediction_holdoff),
      .o_sel_prediction_r(sel_prediction_r),
      .o_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .o_control_flow_to_halfword_pred(control_flow_to_halfword_pred),

      // RAS prediction outputs
      .o_ras_predicted(ras_predicted),
      .o_ras_predicted_target(ras_predicted_target),
      .o_ras_checkpoint_tos(ras_checkpoint_tos),
      .o_ras_checkpoint_valid_count(ras_checkpoint_valid_count)
  );

  // ===========================================================================
  // PC Controller
  // ===========================================================================
  pc_controller #(
      .XLEN(XLEN)
  ) pc_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(pc_controller_stall),
      .i_stall_registered(if_stage_stall_registered),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),
      .i_fence_i_flush(i_fence_i_flush),
      .i_fence_i_target(i_fence_i_target),

      .i_branch_taken (i_from_ex_comb.branch_taken),
      .i_branch_target(i_from_ex_comb.branch_target_address),

      .i_pd_redirect(i_pd_redirect),
      .i_pd_redirect_target(i_pd_redirect_target),

      .i_trap_taken (i_trap_ctrl.trap_taken),
      .i_mret_taken (i_trap_ctrl.mret_taken),
      .i_trap_target(i_trap_ctrl.trap_target),

      .i_spanning_wait_for_fetch(1'b0),
      .i_spanning_in_progress(1'b0),
      .i_spanning_eligible(1'b0),
      .i_spanning_to_halfword(1'b0),
      .i_spanning_to_halfword_registered(1'b0),
      // TIMING OPTIMIZATION: Use is_compressed_fast which matches is_compressed_for_buffer
      // behavior but is computed locally in instruction_aligner for better timing.
      .i_is_compressed(is_compressed_fast),
      .i_is_compressed_for_pc(is_compressed_for_pc),

      // Branch prediction (from branch_prediction_controller)
      .i_predicted_taken(btb_predicted_taken),
      .i_predicted_target(btb_predicted_target),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_prediction_used(prediction_used),
      .i_ras_predicted(ras_predicted),
      .i_sel_prediction_r(sel_prediction_r),
      .i_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),
      .i_prediction_used_from_buffer(prediction_used_from_buffer),
      .i_sel_nop(sel_nop),

      .o_pc(pc),
      .o_pc_reg(pc_reg),
      .o_control_flow_change(control_flow_change),
      .o_control_flow_holdoff(control_flow_holdoff),
      .o_control_flow_to_halfword(control_flow_to_halfword),
      .o_control_flow_to_halfword_r(control_flow_to_halfword_r),
      .o_reset_holdoff(reset_holdoff),
      .o_any_holdoff(any_holdoff),
      .o_any_holdoff_safe(any_holdoff_safe),
      .o_mid_32bit_correction(mid_32bit_correction),
      .o_pending_prediction_active(pending_prediction_active),
      .o_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .o_pending_prediction_holdoff(pending_prediction_holdoff),
      .o_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),
      .o_pending_prediction_target_holdoff(pending_prediction_target_holdoff)
  );

  // ===========================================================================
  // C-Extension State Controller
  // ===========================================================================
  c_ext_state #(
      .XLEN(XLEN)
  ) c_ext_state_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(if_stage_stall),
      // TIMING OPTIMIZATION: Use flush_for_c_ext_safe instead of pipeline_ctrl.flush.
      // This uses registered trap/mret signals to break the critical path from
      // EX stage exception detection through c_ext_state to PC calculation.
      .i_flush(flush_for_c_ext_safe),
      .i_fence_i_flush(i_fence_i_flush),
      .i_stall_registered(if_stage_stall_registered),

      .i_control_flow_holdoff(control_flow_holdoff),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_reset_state(prediction_reset_c_ext),
      .i_pending_prediction_active(pending_prediction_active),
      .i_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .i_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      .i_effective_instr(effective_instr),
      // Always pass i_instr[63:32] as the next word — this is correct when
      // the BRAM is aligned (bank_sel_r == pc_reg[2]).  When misaligned, the
      // fetch_word_swapped guard inside c_ext_state blocks the update entirely.
      .i_instr_next_word(i_instr[63:32]),
      .i_fetch_word_swapped(i_instr_bank_sel_r ^ pc_reg[2]),
      .i_pc(pc),
      .i_pc_reg(pc_reg),

      .i_is_compressed(is_compressed),
      .i_sel_nop(sel_nop),
      // Align sideband to match instruction word selection
      .i_instr_sideband((i_instr_bank_sel_r ^ pc_reg[2]) ? i_instr_sideband[3:2] :
                                                           i_instr_sideband[1:0]),
      .o_instr_buffer(instr_buffer),
      .o_next_word_buffer(next_word_buffer),
      .o_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .o_is_compressed_for_buffer(is_compressed_for_buffer),
      .o_is_compressed_for_pc(is_compressed_for_pc),
      .o_use_buffer_after_prediction(use_buffer_after_prediction),
      .o_is_compressed_saved(is_compressed_saved),
      .o_saved_values_valid(saved_values_valid),
      .o_instr_buffer_sideband(instr_buffer_sideband)
  );

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prev_was_compressed_at_lo when stall begins

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe || prediction_reset_c_ext) begin
      // Clear on reset or flush - flush invalidates pre-flush state
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      prev_was_compressed_at_lo_saved <= 1'b0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      prev_was_compressed_at_lo_saved <= prev_was_compressed_at_lo;
    end
  end

  // ===========================================================================
  // Instruction Aligner
  // ===========================================================================
  instruction_aligner #(
      .XLEN(XLEN)
  ) instruction_aligner_inst (
      .i_instr(i_instr),
      .i_instr_sideband(i_instr_sideband),
      .i_instr_bank_sel_r(i_instr_bank_sel_r),
      .i_instr_buffer(instr_buffer),
      .i_instr_buffer_sideband(instr_buffer_sideband),
      .i_pc_reg(pc_reg),

      .i_prev_was_compressed_at_lo  (prev_was_compressed_at_lo),
      .i_use_buffer_after_prediction(use_buffer_after_prediction),

      .i_mid_32bit_correction(mid_32bit_correction),
      // RAS predicts after instruction arrives; next cycle's instruction is stale.
      // BTB predicts before instruction arrives, so we must NOT suppress that cycle.
      .i_prediction_holdoff(ras_prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      // TIMING OPTIMIZATION: Only use stall_registered (not combinational stall signals)
      // to break critical path from stall → is_compressed → PC
      .i_stall_registered(if_stage_stall_registered),
      .i_prev_was_compressed_at_lo_saved(prev_was_compressed_at_lo_saved),
      .i_is_compressed_saved(is_compressed_saved),
      .i_saved_values_valid(saved_values_valid && !i_fence_i_flush),

      .o_raw_parcel(raw_parcel),
      .o_effective_instr(effective_instr),
      .o_is_compressed(is_compressed),
      .o_is_compressed_fast(is_compressed_fast),
      .o_sel_nop(sel_nop_align),
      .o_sel_compressed(sel_compressed),
      .o_use_instr_buffer(use_instr_buffer)
  );

  // RAS prediction stale cycle: only when prediction came from RAS (not BTB-only).
  assign ras_prediction_holdoff = prediction_holdoff && !btb_only_prediction_holdoff;

  // Registered PD redirect: used to override the !prediction_holdoff exemption
  // in sel_nop below.  When PD redirect fires AND BTB simultaneously predicts
  // the wrong-path instruction, prediction_holdoff would otherwise prevent
  // sel_nop from squashing the stale BRAM data in the holdoff cycle.
  // This registered signal is NOT on the critical path (FF output → 1 OR gate).
  logic pd_redirect_q;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) pd_redirect_q <= 1'b0;
    else pd_redirect_q <= i_pd_redirect;
  end

  // Any non-prediction redirect leaves one stale BRAM cycle where fetch has
  // moved to the new PC but the returned word still belongs to the old path.
  // Word-aligned redirects are not exempt: they can still pair a correct new
  // PC with old-path bytes, which later poison the C-extension/buffer state.
  // Keep the prediction path special-cased through prediction_holdoff so BTB
  // hits still deliver the predicted branch instruction itself. This applies
  // both to the generic control-flow holdoff and to pending halfword-prediction
  // holdoff in pc_controller: the cycle after a BTB redirect is when the
  // predicted branch instruction itself arrives from BRAM.
  //
  // pd_redirect_q overrides the !prediction_holdoff exemption: when a PD
  // redirect caused the holdoff, the arriving BRAM data is stale even if a
  // spurious wrong-path BTB hit set prediction_holdoff.
  assign sel_nop = i_pipeline_ctrl.flush || flush_for_c_ext_safe ||
                   sel_nop_align || reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   (pending_prediction_fetch_holdoff && !prediction_holdoff) ||
                   (control_flow_holdoff && (!prediction_holdoff || pd_redirect_q));

  // ===========================================================================
  // Stall State Registers
  // ===========================================================================
  // Save raw instruction data when stall begins for restoration after unstall.
  // This is needed because BRAM output changes while stalled.

  logic sel_nop_saved;
  logic replay_saved_if_outputs;

  // Stall-capture outputs (muxed: stall_registered ? saved : live)
  logic sel_compressed_sc;

  stall_capture_reg #(
      .WIDTH(16)
  ) u_raw_parcel_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(raw_parcel),
      .o_data(raw_parcel_sc)
  );

  // ===========================================================================
  // 64-bit Spanning Assembly
  // ===========================================================================
  // With 64-bit fetch, both halves of a spanning instruction are available in
  // a single cycle.  When PC[1]=1 and the instruction is 32-bit, assemble it
  // from the current word's upper half and the next word's lower half.
  //
  // When the instruction buffer is active, the "next word" is the BRAM's
  // current word (the lead word).  When the buffer is inactive, the "next
  // word" is the BRAM's upper 32 bits from the 64-bit fetch.
  logic [31:0] assembled_instr;
  logic [15:0] spanning_second_half;
  // When the buffer is active, we can't use the current BRAM output for
  // the spanning second half because the fetch address may differ between
  // visits (due to branch prediction timing).  Instead, c_ext_state captures
  // the "next word" from i_instr[63:32] at the same time as the instruction
  // buffer. This captured next_word_buffer is always correct because at
  // buffer-capture time, the BRAM data corresponds to pc_reg's word pair.
  //
  // Select the spanning half using bank_sel_r parity to pick the correct
  // 16 bits from the 64-bit BRAM output.  The BRAM always contains two
  // consecutive words — the parity check identifies which half holds
  // word(pc_reg[31:2]+1).  This works for BOTH buffer and non-buffer cases:
  //
  //  - Non-buffer: BRAM is aligned to pc_reg (F=W), next word at i_instr[63:32].
  //  - Buffer: BRAM is at the fetch lead (F≈W+1), next word at i_instr[31:0]
  //    (the lead address was set during the compressed-at-lo cycle).
  //
  // Parity: bank_sel_r == pc_reg[2] → next word at [63:32], bits at [47:32].
  //         bank_sel_r != pc_reg[2] → next word at [31:0],  bits at [15:0].
  assign spanning_second_half = (i_instr_bank_sel_r ^ pc_reg[2]) ? i_instr[15:0] : i_instr[47:32];
  always_comb begin
    if (pc_reg[1] && !is_compressed) begin
      // 32-bit instruction at halfword boundary — assemble from two words
      assembled_instr = {spanning_second_half, effective_instr[31:16]};
    end else begin
      assembled_instr = effective_instr;
    end
  end

  stall_capture_reg #(
      .WIDTH(32)
  ) u_assembled_instr_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(assembled_instr),
      .o_data(assembled_instr_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_sel_compressed_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(sel_compressed),
      .o_data(sel_compressed_sc)
  );

  // Keep RAS replay eligibility and validity aligned with the same stall-entry
  // cycle as the captured instruction data instead of depending on
  // c_ext_state.saved_values_valid in the live RAS cone.
  stall_capture_reg #(
      .WIDTH(1)
  ) u_ras_saved_input_available_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(!sel_nop),
      .o_data(ras_saved_input_available_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_ras_instruction_valid_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_instruction_valid_live),
      .o_data(ras_instruction_valid_sc)
  );

  // sel_nop_saved has non-standard flush behavior (flushes to 1'b1, not '0),
  // and is passed to prediction_metadata_tracker, so it remains manual.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      sel_nop_saved <= 1'b1;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      sel_nop_saved <= sel_nop;
    end
  end

  // ===========================================================================
  // Prediction From Buffer Holdoff
  // ===========================================================================
  // When RAS (or BTB) predicts from a buffered instruction, there's a fetch in
  // flight that will arrive next cycle with STALE data (it was fetched for the
  // PC after the buffered instruction, not for the predicted target).
  // This holdoff signal suppresses that stale instruction for one cycle.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      prediction_from_buffer_holdoff <= 1'b0;
    end else if (!if_stage_stall) begin
      // Set when prediction happens while using buffered instruction.
      // Next cycle's instruction data will be stale and needs suppression.
      prediction_from_buffer_holdoff <= prediction_used_from_buffer;
    end
  end

  // Registered to break combinational loop: prediction_used → c_ext_state
  // (use_buffer_after_spanning) → instruction_aligner (is_compressed) →
  // pc_controller/branch_prediction_controller → prediction_used.
  // One cycle delay is correct: prediction redirects PC this cycle, new
  // fetch data arrives next cycle, so c_ext_state reset aligns with it.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) prediction_reset_c_ext <= 1'b0;
    else prediction_reset_c_ext <= prediction_used;
  end

  // Only replay saved IF outputs when the stalled cycle carried a real,
  // still-valid instruction.
  assign replay_saved_if_outputs = if_stage_stall_registered &&
                                   !flush_for_c_ext_safe &&
                                   saved_values_valid &&
                                   !sel_nop_saved;

  // ===========================================================================
  // Outputs to PD Stage
  // ===========================================================================

  assign o_pc = pc;

  // Raw parcel output: replay saved values only when the saved cycle was a real
  // instruction, otherwise use the live post-stall values.
  assign o_from_if_to_pd.raw_parcel = replay_saved_if_outputs ? raw_parcel_sc : raw_parcel;

  // Selection signals
  assign o_from_if_to_pd.sel_nop = replay_saved_if_outputs ? sel_nop_saved : sel_nop;
  assign o_from_if_to_pd.sel_compressed = replay_saved_if_outputs ? sel_compressed_sc :
                                          sel_compressed;

  // Pre-assembled instruction for PD stage (spanning already assembled in IF)
  assign o_from_if_to_pd.effective_instr = replay_saved_if_outputs ? assembled_instr_sc :
                                           assembled_instr;

  // Pre-computed link address for JAL/JALR
  // Link address = instruction_pc + 2 (compressed) or + 4 (32-bit)
  logic [XLEN-1:0] instruction_pc;
  logic [XLEN-1:0] link_address;

  // Use the same stall-safe compressed selection metadata that PD consumes.
  // This keeps link_address aligned with the actual instruction that will be
  // seen downstream, including prediction/stall replay cases.
  logic is_compressed_for_link;
  assign is_compressed_for_link = sel_compressed_sc;

  assign instruction_pc = pc_reg;
  assign link_address = instruction_pc + (is_compressed_for_link ?
                        riscv_pkg::PcIncrementCompressed : riscv_pkg::PcIncrement32bit);

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_instruction_pc_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(instruction_pc),
      .o_data(instruction_pc_sc)
  );

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_link_address_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(link_address),
      .o_data(link_address_sc)
  );

  // Keep the instruction PC aligned with the same stall-replayed instruction
  // data/link metadata that PD consumes.
  assign o_from_if_to_pd.program_counter = replay_saved_if_outputs ? instruction_pc_sc :
                                           instruction_pc;
  assign o_from_if_to_pd.link_address = replay_saved_if_outputs ? link_address_sc : link_address;

  // ===========================================================================
  // RAS Metadata for Pipeline Passthrough
  // ===========================================================================
  // RAS checkpoint data needs to be saved during stalls similar to other IF outputs.
  // The checkpoint is taken at the time of RAS prediction and passed through the
  // pipeline for misprediction recovery in EX stage.

  logic ras_predicted_saved;

  // ras_predicted_saved has a non-standard flush condition (includes
  // prediction_holdoff), so it remains a manual always_ff block.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe || prediction_holdoff) begin
      // Clear control bit on flush or prediction-driven control flow change.
      // Saved data remains but is ignored when ras_predicted_saved is low.
      ras_predicted_saved <= 1'b0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      ras_predicted_saved <= ras_predicted;
    end
  end

  logic [                 XLEN-1:0] ras_predicted_target_sc;
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos_sc;
  logic [  riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count_sc;

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_ras_predicted_target_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_predicted_target),
      .o_data(ras_predicted_target_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits)
  ) u_ras_checkpoint_tos_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_checkpoint_tos),
      .o_data(ras_checkpoint_tos_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits + 1)
  ) u_ras_checkpoint_valid_count_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_checkpoint_valid_count),
      .o_data(ras_checkpoint_valid_count_sc)
  );

  // Output RAS metadata - clear for NOP/spanning, use saved during stall
  logic sel_nop_effective;
  assign sel_nop_effective = replay_saved_if_outputs ? sel_nop_saved : sel_nop;

  assign o_from_if_to_pd.ras_predicted = sel_nop_effective ? 1'b0 :
                                         (replay_saved_if_outputs ? ras_predicted_saved :
                                          ras_predicted);
  assign o_from_if_to_pd.ras_predicted_target = replay_saved_if_outputs ?
                                                ras_predicted_target_sc :
                                                ras_predicted_target;
  assign o_from_if_to_pd.ras_checkpoint_tos = replay_saved_if_outputs ? ras_checkpoint_tos_sc :
                                              ras_checkpoint_tos;
  assign o_from_if_to_pd.ras_checkpoint_valid_count = replay_saved_if_outputs ?
      ras_checkpoint_valid_count_sc : ras_checkpoint_valid_count;

  // ===========================================================================
  // Prediction Metadata Tracker
  // ===========================================================================
  // Manages prediction metadata for stalls.
  // When outputting NOP (holdoff), clears prediction metadata.
  // Otherwise uses registered prediction with stall handling.

  prediction_metadata_tracker #(
      .XLEN(XLEN)
  ) prediction_metadata_tracker_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(if_stage_stall),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),
      .i_prediction_holdoff(prediction_holdoff),
      .i_stall_registered(if_stage_stall_registered),

      // Registered prediction from branch_prediction_controller
      .i_prediction_used_r(prediction_used_r),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),

      // Instruction type signals
      .i_sel_nop(sel_nop),
      .i_sel_nop_saved(sel_nop_saved),
      .i_use_saved_values(replay_saved_if_outputs),

      // Outputs to PD stage
      .o_btb_hit(o_from_if_to_pd.btb_hit),
      .o_btb_predicted_taken(o_from_if_to_pd.btb_predicted_taken),
      .o_btb_predicted_target(o_from_if_to_pd.btb_predicted_target)
  );

endmodule : if_stage
