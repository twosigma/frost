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
    input logic i_flush,  // Pipeline flush - block state updates from garbage instructions

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
    input logic i_is_32bit_spanning,
    input logic i_spanning_to_halfword,
    input logic i_spanning_to_halfword_registered,
    input logic i_is_compressed,  // Combinational (for spanning detection, etc.)
    input logic i_is_compressed_for_pc,  // Registered (TIMING OPTIMIZATION: for PC increment)

    // Branch prediction (from branch_prediction_controller)
    input logic i_predicted_taken,  // BTB predicts taken (combinational)
    input logic [XLEN-1:0] i_predicted_target,  // Predicted target address (combinational)
    input logic [XLEN-1:0] i_predicted_target_r,  // Predicted target address (registered)
    input logic i_prediction_used,  // Prediction actually used this cycle
    input logic i_sel_prediction_r,  // Registered prediction used (for pc_reg)
    input logic i_prediction_holdoff,  // One cycle after prediction (for pc_increment)
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle

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
    output logic o_mid_32bit_correction
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
      .i_is_32bit_spanning,
      .i_spanning_to_halfword,
      .i_spanning_to_halfword_registered,
      .i_is_compressed,

      // Holdoff and control signals
      .i_any_holdoff_safe(o_any_holdoff_safe),
      .i_prediction_holdoff,
      .i_prediction_from_buffer_holdoff,
      .i_control_flow_to_halfword_r(o_control_flow_to_halfword_r),

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
  always_ff @(posedge i_clk) begin
    if (i_reset || o_any_holdoff_safe || i_flush || i_prediction_used || i_sel_prediction_r)
      prev_was_32bit <= 1'b0;
    else if (!i_stall)
      prev_was_32bit <= !i_is_compressed && !i_spanning_in_progress && !i_spanning_wait_for_fetch;
  end

  assign o_mid_32bit_correction = prev_was_32bit && o_pc_reg[1] &&
                                  !i_spanning_in_progress && !i_spanning_wait_for_fetch;

  // ===========================================================================
  // Final PC Selection - Single Flat Priority Mux
  // ===========================================================================
  // Minimize logic depth from branch_taken to output.
  // Priority selects are computed in parallel, then one-hot OR structure.
  //
  // Priority order (highest first):
  //   1. Reset
  //   2. Trap/MRET
  //   3. Stall (hold current)
  //   4. Branch/Jump taken (actual, from EX stage)
  //   5. Predicted taken (from BTB) - only when not in holdoff
  //   6. Sequential

  logic sel_reset, sel_trap, sel_stall, sel_branch, sel_seq;

  assign sel_reset = i_reset;
  assign sel_trap = !i_reset && (i_trap_taken || i_mret_taken);
  assign sel_stall = !i_reset && !i_trap_taken && !i_mret_taken && i_stall;
  assign sel_branch = !i_reset && !i_trap_taken && !i_mret_taken && !i_stall && i_branch_taken;
  // i_prediction_used comes from branch_prediction_controller (gated prediction)
  assign sel_seq = !sel_reset & !sel_trap & !sel_stall & !sel_branch & !i_prediction_used;

  // For next_pc_reg, use the REGISTERED prediction (1 cycle delayed).
  // This is because o_pc_reg represents the PC of the instruction being processed,
  // which lags o_pc (the fetch address) by one cycle.
  // When we predict taken at PC_N in cycle N:
  //   - next_pc goes to target immediately (fetch from target in cycle N+1)
  //   - next_pc_reg stays sequential in cycle N (instruction at PC_{N-1} is processed)
  //   - next_pc_reg goes to target in cycle N+1 (using registered prediction)
  //
  // CRITICAL: Use i_sel_prediction_r (registered i_prediction_used from branch_prediction_controller),
  // not i_predicted_taken! i_predicted_taken is the raw BTB output which doesn't include the
  // gating from i_prediction_used (halfword-aligned check, spanning check, etc.). If we blocked
  // i_prediction_used for a halfword-aligned PC but used raw BTB output here, pc_reg
  // would jump to the target while pc stays sequential - a mismatch.
  logic sel_prediction_r;
  assign sel_prediction_r = !sel_reset && !sel_trap && !sel_stall && !sel_branch &&
                            !o_any_holdoff_safe && i_sel_prediction_r;

  logic [XLEN-1:0] next_pc, next_pc_reg;

  // One-hot parallel OR mux - all AND gates computed in parallel
  // This is flatter than cascaded ternary operators
  assign next_pc = ({XLEN{sel_reset}} & {XLEN{1'b0}}) |
                   ({XLEN{sel_trap}} & i_trap_target) |
                   ({XLEN{sel_stall}} & o_pc) |
                   ({XLEN{sel_branch}} & i_branch_target) |
                   ({XLEN{i_prediction_used}} & i_predicted_target) |
                   ({XLEN{sel_seq}} & seq_next_pc);

  // For next_pc_reg, use the REGISTERED prediction (sel_prediction_r).
  // This ensures o_pc_reg tracks the instruction PC correctly:
  //   - In cycle N (prediction made): next_pc_reg = sequential (for current instruction)
  //   - In cycle N+1 (registered): next_pc_reg = predicted_target_r (for branch instruction)
  //   - In cycle N+2: o_pc_reg = predicted_target_r (for target instruction)
  logic sel_seq_for_pc_reg;
  assign sel_seq_for_pc_reg = !sel_reset && !sel_trap && !sel_stall && !sel_branch &&
                              !sel_prediction_r;

  assign next_pc_reg = ({XLEN{sel_reset}} & {XLEN{1'b0}}) |
                       ({XLEN{sel_trap}} & i_trap_target) |
                       ({XLEN{sel_stall}} & o_pc_reg) |
                       ({XLEN{sel_branch}} & i_branch_target) |
                       ({XLEN{sel_prediction_r}} & i_predicted_target_r) |
                       ({XLEN{sel_seq_for_pc_reg}} & seq_next_pc_reg);

  // PC registers
  always_ff @(posedge i_clk) begin
    o_pc <= next_pc;
    o_pc_reg <= next_pc_reg;
  end

endmodule : pc_controller
