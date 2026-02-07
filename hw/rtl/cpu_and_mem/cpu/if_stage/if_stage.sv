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
 * Instruction Fetch (IF) Stage - First stage of the 6-stage RISC-V pipeline
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
 *   All branches and jumps (JAL, JALR, conditional branches) are resolved in
 *   the EX stage and redirected through the i_from_ex_comb interface.
 */
module if_stage #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input logic [31:0] i_instr,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    // Branch prediction control (for verification - prevents BTB predictions)
    input logic i_disable_branch_prediction,
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
  logic sel_prediction_r;  // Select registered prediction target
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

  // ---------------------------------------------------------------------------
  // C-Extension State Interface (c_ext_state)
  // ---------------------------------------------------------------------------
  logic spanning_wait_for_fetch;  // Waiting for second half of spanning instr
  logic spanning_in_progress;  // Currently processing spanning instruction
  logic [15:0] spanning_buffer;  // First half of spanning instruction
  logic [15:0] spanning_second_half;  // Second half of spanning instruction
  logic [XLEN-1:0] spanning_pc;  // PC of spanning instruction
  logic [31:0] instr_buffer;  // Buffered instruction for stall recovery
  logic prev_was_compressed_at_lo;  // Previous instr was compressed at addr[1]=0
  logic spanning_to_halfword;  // Spanning ends at halfword boundary
  logic spanning_to_halfword_registered;  // Registered for timing
  logic is_compressed_for_buffer;  // Stall-restored is_compressed
  logic is_compressed_for_pc;  // Registered is_compressed for PC timing
  logic use_buffer_after_spanning;  // Use buffer after spanning_to_halfword
  logic is_compressed_saved;  // Saved is_compressed for fast path
  logic saved_values_valid;  // Saved values are valid (not invalidated by control flow)

  // ---------------------------------------------------------------------------
  // Instruction Aligner Interface (instruction_aligner)
  // ---------------------------------------------------------------------------
  logic [15:0] raw_parcel;  // Selected 16-bit parcel for RVC decompression
  logic [31:0] effective_instr;  // Aligned 32-bit instruction
  logic [31:0] spanning_instr;  // Assembled spanning instruction
  logic is_compressed;  // Current instruction is 16-bit compressed
  logic is_compressed_fast;  // Fast path for PC-critical path (registered selects only)
  logic sel_nop;  // Select NOP (during holdoff/flush)
  logic sel_spanning;  // Select spanning instruction
  logic sel_compressed;  // Select compressed instruction path
  logic use_instr_buffer;  // Use buffered instruction

  // ---------------------------------------------------------------------------
  // Derived Signals and Stall State
  // ---------------------------------------------------------------------------
  logic is_32bit_spanning;  // 32-bit instruction spans two words
  logic prev_was_compressed_at_lo_saved;  // Saved for stall recovery

  // TIMING OPTIMIZATION: Pass raw instruction to aligner, not flush-gated.
  // This breaks the timing path: flush -> is_compressed -> pc_increment -> PC.
  // When flush is true, pc_controller selects branch_target anyway, so
  // is_compressed value during flush doesn't affect the PC output.
  // NOP insertion during flush is handled by PD stage, not here.
  // C-extension state updates are already protected by flush checks in c_ext_state.
  logic [31:0] instr_for_aligner;
  assign instr_for_aligner = i_instr;

  // TIMING OPTIMIZATION: Create a "safe" flush signal for c_ext_state that uses
  // only REGISTERED trap/mret signals. This breaks the critical timing path:
  //   EX stage data → trap detection → flush → c_ext_state → PC
  //
  // The combinational flush from pipeline_ctrl uses trap_taken directly, creating
  // a long path from EX stage exception detection. By using the registered versions,
  // we delay the c_ext_state clear by 1 cycle, which is fine because:
  //   1. Flush lasts 2 cycles (trap in cycle N, trap_registered in cycle N+1)
  //   2. c_ext_state also clears on control_flow_holdoff (registered)
  //   3. The 1-cycle delay doesn't affect correctness since state is stale anyway
  //
  // For PC selection (sel_trap), we still use combinational trap_taken for immediate
  // redirect. Only c_ext_state uses this delayed flush.
  //
  // TIMING OPTIMIZATION (additional): Use stall_for_trap_check instead of stall.
  // The regular stall signal depends on ~trap_taken (traps override stall), so
  // gating with ~stall reintroduces trap_taken into the path. stall_for_trap_check
  // is just stall_sources without trap/mret gating, breaking the timing path while
  // still blocking flush during actual stalls (multiply, load-use, AMO, WFI).
  // This is safe because control_flow_holdoff will clear state on the next cycle.
  logic flush_for_c_ext_safe;
  assign flush_for_c_ext_safe = (i_from_ex_comb.branch_taken |
                                  i_pipeline_ctrl.trap_taken_registered |
                                  i_pipeline_ctrl.mret_taken_registered) &
                                 ~i_pipeline_ctrl.stall_for_trap_check;

  // ===========================================================================
  // Spanning Detection
  // ===========================================================================
  // 32-bit instruction spans two words when PC[1]=1 and it's not compressed.
  // Block detection during holdoff cycles when i_instr is stale.
  // Use is_compressed_for_buffer which handles stall restoration correctly,
  // including the saved_values_valid check that clears on flush.
  //
  // TIMING OPTIMIZATION: Removed !flush from this check to break timing path.
  // When branch is taken, pc_controller selects branch_target, so is_32bit_spanning
  // value doesn't affect PC. Any spurious spanning state gets cleared on next cycle
  // via control_flow_holdoff (which is in any_holdoff_safe checked by c_ext_state).
  assign is_32bit_spanning = pc_reg[1] && !is_compressed_for_buffer &&
                             !spanning_in_progress &&
                             !control_flow_holdoff && !reset_holdoff &&
                             !spanning_to_halfword_registered;

  // No stall for spanning - we output NOP and let PC advance

  // ===========================================================================
  // Branch Prediction Controller
  // ===========================================================================
  // Encapsulates BTB, RAS, prediction gating, and registration logic.

  // RAS detection uses the assembled spanning instruction when available so
  // calls/returns that straddle words still update/predict correctly.
  logic [31:0] ras_instruction;
  logic [15:0] ras_raw_parcel;
  logic        ras_is_compressed;
  logic        sel_spanning_effective;
  logic [31:0] ras_spanning_instr;

  assign sel_spanning_effective = use_saved_values ? sel_spanning_saved : sel_spanning;
  assign ras_spanning_instr = spanning_instr_sc;

  assign ras_instruction = sel_spanning_effective ? ras_spanning_instr : effective_instr_sc;
  assign ras_raw_parcel = sel_spanning_effective ? ras_spanning_instr[15:0] : raw_parcel_sc;
  assign ras_is_compressed = sel_spanning_effective ? 1'b0 :
                             (use_saved_values ? is_compressed_for_buffer : is_compressed);

  branch_prediction_controller branch_prediction_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      // Use stall_for_trap_check to avoid pulling trap_taken into prediction gating.
      .i_stall(i_pipeline_ctrl.stall_for_trap_check),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),

      // Current PC for BTB lookup
      .i_pc(pc),

      // Control signals for prediction gating
      .i_trap_taken(i_trap_ctrl.trap_taken),
      .i_mret_taken(i_trap_ctrl.mret_taken),
      .i_branch_taken(i_from_ex_comb.branch_taken),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_is_32bit_spanning(is_32bit_spanning),
      .i_spanning_wait_for_fetch(spanning_wait_for_fetch),
      .i_spanning_in_progress(spanning_in_progress),
      .i_disable_branch_prediction(i_disable_branch_prediction),

      // BTB update interface (from EX stage)
      .i_btb_update(i_from_ex_comb.btb_update),
      .i_btb_update_pc(i_from_ex_comb.btb_update_pc),
      .i_btb_update_target(i_from_ex_comb.btb_update_target),
      .i_btb_update_taken(i_from_ex_comb.btb_update_taken),

      // RAS inputs (instruction for call/return detection)
      // CRITICAL: Use saved instruction data during stall_registered. After multi-cycle
      // stalls (load-use hazard), BRAM has advanced past the instruction we're processing.
      // The saved values contain the correct instruction from when stall started.
      .i_instruction(ras_instruction),
      .i_raw_parcel(ras_raw_parcel),
      .i_is_compressed(ras_is_compressed),
      // Instruction validity for RAS detection depends on which predictor fired:
      //   - BTB predicts based on PC (fetch address) BEFORE instruction arrives.
      //     During btb_only_prediction_holdoff, the instruction is VALID (it's the branch).
      //     RAS should be allowed to push if this instruction is a call.
      //   - RAS predicts based on instruction content AFTER instruction arrives.
      //     During prediction_holdoff (but NOT btb_only), the instruction is STALE.
      //     RAS detection should be blocked to prevent spurious pushes.
      // IMPORTANT: When using saved values (after stall), the holdoffs are stale and
      // shouldn't affect validity. The saved instruction was valid when captured.
      .i_instruction_valid(!sel_nop && !any_holdoff &&
                           (use_saved_values || !prediction_holdoff ||
                            btb_only_prediction_holdoff)),
      // IMPORTANT: Use saved link_address when using saved instruction data. When coming
      // out of stall, the saved instruction triggers RAS push/pop but link_address is
      // now for the NEW instruction. Using the wrong link_address corrupts RAS.
      .i_link_address(link_address_sc),

      // RAS misprediction recovery (from EX stage)
      .i_ras_misprediction(i_from_ex_comb.ras_misprediction),
      .i_ras_restore_tos(i_from_ex_comb.ras_restore_tos),
      .i_ras_restore_valid_count(i_from_ex_comb.ras_restore_valid_count),
      .i_ras_pop_after_restore(i_from_ex_comb.ras_pop_after_restore),

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
      .i_stall(i_pipeline_ctrl.stall),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),

      .i_branch_taken (i_from_ex_comb.branch_taken),
      .i_branch_target(i_from_ex_comb.branch_target_address),

      .i_trap_taken (i_trap_ctrl.trap_taken),
      .i_mret_taken (i_trap_ctrl.mret_taken),
      .i_trap_target(i_trap_ctrl.trap_target),

      .i_spanning_wait_for_fetch(spanning_wait_for_fetch),
      .i_spanning_in_progress(spanning_in_progress),
      .i_is_32bit_spanning(is_32bit_spanning),
      .i_spanning_to_halfword(spanning_to_halfword),
      .i_spanning_to_halfword_registered(spanning_to_halfword_registered),
      // TIMING OPTIMIZATION: Use is_compressed_fast which matches is_compressed_for_buffer
      // behavior but is computed locally in instruction_aligner for better timing.
      .i_is_compressed(is_compressed_fast),
      .i_is_compressed_for_pc(is_compressed_for_pc),

      // Branch prediction (from branch_prediction_controller)
      .i_predicted_taken(btb_predicted_taken),
      .i_predicted_target(btb_predicted_target),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_prediction_used(prediction_used),
      .i_sel_prediction_r(sel_prediction_r),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      .o_pc(pc),
      .o_pc_reg(pc_reg),
      .o_control_flow_change(control_flow_change),
      .o_control_flow_holdoff(control_flow_holdoff),
      .o_control_flow_to_halfword(control_flow_to_halfword),
      .o_control_flow_to_halfword_r(control_flow_to_halfword_r),
      .o_reset_holdoff(reset_holdoff),
      .o_any_holdoff(any_holdoff),
      .o_any_holdoff_safe(any_holdoff_safe),
      .o_mid_32bit_correction(mid_32bit_correction)
  );

  // ===========================================================================
  // C-Extension State Controller
  // ===========================================================================
  c_ext_state #(
      .XLEN(XLEN)
  ) c_ext_state_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(i_pipeline_ctrl.stall),
      // TIMING OPTIMIZATION: Use flush_for_c_ext_safe instead of pipeline_ctrl.flush.
      // This uses registered trap/mret signals to break the critical path from
      // EX stage exception detection through c_ext_state to PC calculation.
      .i_flush(flush_for_c_ext_safe),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),

      .i_control_flow_holdoff(control_flow_holdoff),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_prediction_holdoff(prediction_holdoff),

      .i_effective_instr(effective_instr),
      .i_pc_reg(pc_reg),

      .i_is_compressed(is_compressed),
      .i_is_32bit_spanning(is_32bit_spanning),

      .o_spanning_wait_for_fetch(spanning_wait_for_fetch),
      .o_spanning_in_progress(spanning_in_progress),
      .o_spanning_buffer(spanning_buffer),
      .o_spanning_second_half(spanning_second_half),
      .o_spanning_pc(spanning_pc),
      .o_instr_buffer(instr_buffer),
      .o_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .o_spanning_to_halfword(spanning_to_halfword),
      .o_spanning_to_halfword_registered(spanning_to_halfword_registered),
      .o_is_compressed_for_buffer(is_compressed_for_buffer),
      .o_is_compressed_for_pc(is_compressed_for_pc),  // TIMING OPTIMIZATION: for PC increment
      .o_use_buffer_after_spanning(use_buffer_after_spanning),
      .o_is_compressed_saved(is_compressed_saved),
      .o_saved_values_valid(saved_values_valid)
  );

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prev_was_compressed_at_lo when stall begins

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      // Clear on reset or flush - flush invalidates pre-flush state
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      prev_was_compressed_at_lo_saved <= 1'b0;
    end else if (i_pipeline_ctrl.stall & ~i_pipeline_ctrl.stall_registered) begin
      prev_was_compressed_at_lo_saved <= prev_was_compressed_at_lo;
    end
  end

  // ===========================================================================
  // Instruction Aligner
  // ===========================================================================
  instruction_aligner #(
      .XLEN(XLEN)
  ) instruction_aligner_inst (
      .i_instr(instr_for_aligner),
      .i_instr_buffer(instr_buffer),
      .i_pc_reg(pc_reg),

      .i_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .i_spanning_wait_for_fetch(spanning_wait_for_fetch),
      .i_spanning_in_progress(spanning_in_progress),
      .i_spanning_buffer(spanning_buffer),
      .i_spanning_second_half(spanning_second_half),
      .i_spanning_to_halfword_registered(spanning_to_halfword_registered),
      .i_use_buffer_after_spanning(use_buffer_after_spanning),

      .i_mid_32bit_correction(mid_32bit_correction),
      // RAS predicts after instruction arrives; next cycle's instruction is stale.
      // BTB predicts before instruction arrives, so we must NOT suppress that cycle.
      .i_prediction_holdoff(ras_prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      // TIMING OPTIMIZATION: Only use stall_registered (not combinational stall signals)
      // to break critical path from stall → is_compressed → PC
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_prev_was_compressed_at_lo_saved(prev_was_compressed_at_lo_saved),
      .i_is_compressed_saved(is_compressed_saved),
      .i_saved_values_valid(saved_values_valid),

      .o_raw_parcel(raw_parcel),
      .o_effective_instr(effective_instr),
      .o_spanning_instr(spanning_instr),
      .o_is_compressed(is_compressed),
      .o_is_compressed_fast(is_compressed_fast),
      .o_sel_nop(sel_nop),
      .o_sel_spanning(sel_spanning),
      .o_sel_compressed(sel_compressed),
      .o_use_instr_buffer(use_instr_buffer)
  );

  // RAS prediction stale cycle: only when prediction came from RAS (not BTB-only).
  assign ras_prediction_holdoff = prediction_holdoff && !btb_only_prediction_holdoff;

  // ===========================================================================
  // Stall State Registers
  // ===========================================================================
  // Save raw instruction data when stall begins for restoration after unstall.
  // This is needed because BRAM output changes while stalled.

  logic        sel_nop_saved;
  logic        sel_spanning_saved;

  // Stall-capture outputs (muxed: stall_registered ? saved : live)
  logic [15:0] raw_parcel_sc;
  logic [31:0] effective_instr_sc;
  logic [31:0] spanning_instr_sc;
  logic        sel_compressed_sc;

  stall_capture_reg #(
      .WIDTH(16)
  ) u_raw_parcel_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(raw_parcel),
      .o_data(raw_parcel_sc)
  );

  stall_capture_reg #(
      .WIDTH(32)
  ) u_effective_instr_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(effective_instr),
      .o_data(effective_instr_sc)
  );

  stall_capture_reg #(
      .WIDTH(32)
  ) u_spanning_instr_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(spanning_instr),
      .o_data(spanning_instr_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_sel_compressed_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(sel_compressed),
      .o_data(sel_compressed_sc)
  );

  // sel_nop_saved and sel_spanning_saved have non-standard flush behavior:
  // sel_nop_saved flushes to 1'b1 (not '0), and both are also passed as raw
  // saved values to prediction_metadata_tracker, so they remain manual.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      sel_nop_saved <= 1'b1;
      sel_spanning_saved <= 1'b0;
    end else if (i_pipeline_ctrl.stall & ~i_pipeline_ctrl.stall_registered) begin
      sel_nop_saved <= sel_nop;
      sel_spanning_saved <= sel_spanning;
    end
  end

  // ===========================================================================
  // Prediction From Buffer Holdoff
  // ===========================================================================
  // When RAS (or BTB) predicts from a buffered instruction, there's a fetch in
  // flight that will arrive next cycle with STALE data (it was fetched for the
  // PC after the buffered instruction, not for the predicted target).
  // This holdoff signal suppresses that stale instruction for one cycle.
  logic prediction_from_buffer_holdoff;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      prediction_from_buffer_holdoff <= 1'b0;
    end else if (!i_pipeline_ctrl.stall) begin
      // Set when prediction happens while using buffered instruction.
      // Next cycle's instruction data will be stale and needs suppression.
      prediction_from_buffer_holdoff <= prediction_used && use_instr_buffer;
    end
  end

  // ===========================================================================
  // Outputs to PD Stage
  // ===========================================================================

  assign o_pc = pc;

  // TIMING OPTIMIZATION: Removed ~flush gate from use_saved_values.
  // During flush, PD stage overrides with NOP anyway, so IF outputs don't affect
  // the final instruction. This breaks the timing path from branch_taken through
  // flush to IF stage output muxes.
  logic use_saved_values;
  assign use_saved_values = i_pipeline_ctrl.stall_registered;

  // Raw parcel output: use saved during stall
  assign o_from_if_to_pd.raw_parcel = raw_parcel_sc;

  // Selection signals
  assign o_from_if_to_pd.sel_nop = use_saved_values ? sel_nop_saved : sel_nop;
  assign o_from_if_to_pd.sel_spanning = use_saved_values ? sel_spanning_saved : sel_spanning;
  assign o_from_if_to_pd.sel_compressed = sel_compressed_sc;

  // Pre-assembled instructions for PD stage mux
  assign o_from_if_to_pd.spanning_instr = spanning_instr_sc;
  assign o_from_if_to_pd.effective_instr = effective_instr_sc;

  // PC output: use spanning PC when in spanning mode
  assign o_from_if_to_pd.program_counter = spanning_in_progress ? spanning_pc : pc_reg;

  // Pre-computed link address for JAL/JALR
  // Link address = instruction_pc + 2 (compressed) or + 4 (32-bit)
  logic [XLEN-1:0] instruction_pc;
  logic [XLEN-1:0] link_address;
  logic [XLEN-1:0] link_address_sc;

  // Determine if current instruction is compressed for link address calculation
  logic is_compressed_for_link;
  assign is_compressed_for_link = is_compressed && !spanning_in_progress &&
                                  !spanning_wait_for_fetch && !spanning_to_halfword_registered &&
                                  !mid_32bit_correction &&
                                  !control_flow_holdoff && !reset_holdoff;

  assign instruction_pc = spanning_in_progress ? spanning_pc : pc_reg;
  assign link_address = instruction_pc + (is_compressed_for_link ?
                        riscv_pkg::PcIncrementCompressed : riscv_pkg::PcIncrement32bit);

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_link_address_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(link_address),
      .o_data(link_address_sc)
  );

  assign o_from_if_to_pd.link_address = link_address_sc;

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
    end else if (i_pipeline_ctrl.stall & ~i_pipeline_ctrl.stall_registered) begin
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
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(ras_predicted_target),
      .o_data(ras_predicted_target_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits)
  ) u_ras_checkpoint_tos_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(ras_checkpoint_tos),
      .o_data(ras_checkpoint_tos_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits + 1)
  ) u_ras_checkpoint_valid_count_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_registered(i_pipeline_ctrl.stall_registered),
      .i_data(ras_checkpoint_valid_count),
      .o_data(ras_checkpoint_valid_count_sc)
  );

  // Output RAS metadata - clear for NOP/spanning, use saved during stall
  logic sel_nop_effective;
  assign sel_nop_effective = use_saved_values ? sel_nop_saved : sel_nop;

  assign o_from_if_to_pd.ras_predicted = sel_nop_effective ? 1'b0 :
                                         (use_saved_values ? ras_predicted_saved : ras_predicted);
  assign o_from_if_to_pd.ras_predicted_target = ras_predicted_target_sc;
  assign o_from_if_to_pd.ras_checkpoint_tos = ras_checkpoint_tos_sc;
  assign o_from_if_to_pd.ras_checkpoint_valid_count = ras_checkpoint_valid_count_sc;

  // ===========================================================================
  // Prediction Metadata Tracker
  // ===========================================================================
  // Manages prediction metadata for stalls and spanning instructions.
  // When outputting NOP (holdoff), clears prediction metadata.
  // When outputting spanning instruction, uses prediction from spanning start.
  // Otherwise uses registered prediction with stall handling.

  prediction_metadata_tracker #(
      .XLEN(XLEN)
  ) prediction_metadata_tracker_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(i_pipeline_ctrl.stall),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),
      .i_prediction_holdoff(prediction_holdoff),  // Clear stale saved state on prediction
      .i_stall_registered(i_pipeline_ctrl.stall_registered),

      // Registered prediction from branch_prediction_controller
      .i_prediction_used_r (prediction_used_r),
      .i_predicted_target_r(btb_predicted_target_r),

      // Instruction type signals
      .i_sel_nop(sel_nop),
      .i_sel_spanning(sel_spanning),
      .i_sel_nop_saved(sel_nop_saved),
      .i_sel_spanning_saved(sel_spanning_saved),
      .i_use_saved_values(use_saved_values),

      // Spanning detection
      .i_is_32bit_spanning(is_32bit_spanning),
      .i_spanning_wait_for_fetch(spanning_wait_for_fetch),

      // Outputs to PD stage
      .o_btb_hit(o_from_if_to_pd.btb_hit),
      .o_btb_predicted_taken(o_from_if_to_pd.btb_predicted_taken),
      .o_btb_predicted_target(o_from_if_to_pd.btb_predicted_target)
  );

endmodule : if_stage
