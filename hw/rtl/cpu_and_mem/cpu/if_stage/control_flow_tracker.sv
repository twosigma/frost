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
 * Control Flow Tracker
 *
 * Tracks control flow changes and generates holdoff signals to indicate when
 * instruction data from BRAM is stale. Due to BRAM latency, after a control
 * flow change (branch, trap, mret, prediction), the fetched instruction data
 * is stale for 1-2 cycles until the new instruction arrives.
 *
 * Holdoff signals are used throughout the IF stage to:
 *   - Insert NOPs during stale instruction cycles
 *   - Block predictions during holdoff (would predict on wrong instruction)
 *   - Prevent C-extension state machine corruption from garbage data
 *
 * Signals:
 * ========
 *   control_flow_change: Combinational, true when any redirect occurs this cycle
 *   control_flow_holdoff: Registered, true one cycle after control_flow_change
 *   reset_holdoff: True on first cycle after reset
 *   any_holdoff: OR of all holdoff sources (includes combinational)
 *   any_holdoff_safe: OR of registered holdoff sources only (for timing)
 *
 * Related Modules:
 *   - pc_controller.sv: Instantiates this module, uses holdoff for PC selection
 *   - branch_prediction_controller.sv: Uses any_holdoff_safe to block predictions
 *   - instruction_aligner.sv: Uses holdoff to insert NOPs
 */
module control_flow_tracker #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,
    input logic i_fence_i_flush,

    // Control flow sources
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic            i_branch_taken,
    input logic            i_pd_redirect,         // PD backward-branch heuristic redirect
    input logic [XLEN-1:0] i_pd_redirect_target,
    input logic            i_prediction_used,     // BTB prediction used this cycle
    input logic [XLEN-1:0] i_branch_target,
    input logic [XLEN-1:0] i_trap_target,
    input logic [XLEN-1:0] i_predicted_target,

    // C-extension spanning to halfword (causes extra holdoff)
    input logic i_spanning_to_halfword_registered,

    // Outputs
    output logic o_control_flow_change,
    output logic o_control_flow_holdoff,
    output logic o_reset_holdoff,
    output logic o_any_holdoff,
    output logic o_any_holdoff_safe,
    output logic o_control_flow_to_halfword,
    output logic o_control_flow_to_halfword_r
);

  // ===========================================================================
  // Control Flow Detection
  // ===========================================================================
  // Detect any control flow change this cycle (branches, traps, predictions)

  // FENCE.I performs a full front-end flush without an explicit redirect
  // target. Treat its registered flush pulse as a control-flow event so the
  // IF holdoff machinery suppresses stale in-flight fetch data for one cycle
  // before the post-fence sequential stream resumes.
  assign o_control_flow_change = i_trap_taken || i_mret_taken || i_branch_taken ||
                                 i_pd_redirect || i_prediction_used || i_fence_i_flush;

  // ===========================================================================
  // Holdoff Registers
  // ===========================================================================
  // Track stale instruction cycles after control flow changes

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_control_flow_holdoff <= 1'b0;
      o_reset_holdoff <= 1'b1;
    end else if (o_control_flow_change) begin
      // Latch redirect holdoff even if the front-end is stalled. Otherwise a
      // mispredict/redirect that arrives into back-pressure can skip the stale
      // BRAM-suppression window and pair new-path instruction data with an old PC.
      o_control_flow_holdoff <= 1'b1;
    end else if (!i_stall) begin
      o_control_flow_holdoff <= 1'b0;
      o_reset_holdoff <= 1'b0;
    end
  end

  // ===========================================================================
  // Combined Holdoff Signals
  // ===========================================================================
  // any_holdoff: All sources (includes combinational control_flow_change)
  // any_holdoff_safe: Only registered sources (breaks timing from branch_taken)

  assign o_any_holdoff = o_control_flow_change || o_control_flow_holdoff || o_reset_holdoff;
  assign o_any_holdoff_safe = o_control_flow_holdoff || o_reset_holdoff;

  // ===========================================================================
  // Halfword-Aligned Control Flow Detection
  // ===========================================================================
  // Detect when control flow targets a halfword-aligned address (PC[1]=1).
  // This affects C-extension instruction alignment.

  assign o_control_flow_to_halfword =
    (i_branch_taken && i_branch_target[1]) ||
    (i_trap_taken && i_trap_target[1]) ||
    (i_mret_taken && i_trap_target[1]) ||
    (i_pd_redirect && i_pd_redirect_target[1]) ||
    (i_prediction_used && i_predicted_target[1]);

  always_ff @(posedge i_clk) begin
    if (i_reset) o_control_flow_to_halfword_r <= 1'b0;
    else if (o_control_flow_change) o_control_flow_to_halfword_r <= o_control_flow_to_halfword;
    else if (!i_stall) o_control_flow_to_halfword_r <= o_control_flow_to_halfword;
  end

endmodule : control_flow_tracker
