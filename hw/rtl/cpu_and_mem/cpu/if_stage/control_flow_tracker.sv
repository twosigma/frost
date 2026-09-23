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
 * Tracks redirects and suppresses stale BRAM data for the following one or two
 * cycles. Holdoffs insert NOPs, block prediction on stale instructions, and
 * protect C-extension state.
 *
 * control_flow_change is combinational; control_flow_holdoff is its registered
 * successor. reset_holdoff covers the first post-reset cycle. any_holdoff
 * includes combinational sources; any_holdoff_safe uses only registered sources.
 */
module control_flow_tracker #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    // Fetch progress (live window valid or stall-replay bundle presented).
    // Holdoffs extend through no-progress cycles exactly as through stalls:
    // the stale-suppression window must still cover the first delivery.
    input logic i_fetch_progress,
    input logic i_flush,
    input logic i_fence_i_flush,

    // Control flow sources
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic            i_branch_taken,
    input logic            i_pd_redirect,             // PD predicted-taken BTB-miss redirect
    input logic [XLEN-1:0] i_pd_redirect_target,
    input logic            i_prediction_used,         // BTB prediction used this cycle
    // Slot-2 BTB prediction, treated like a 1-cycle-late redirect in the same
    // way as pd_redirect. BRAM was fetching the sequential next bundle, so
    // cycle N+2 needs a NOP. It folds into control_flow_change so the
    // control_flow_holdoff machinery covers slot-2 prediction redirects.
    input logic            i_slot2_prediction_used,
    input logic [XLEN-1:0] i_slot2_predicted_target,
    input logic [XLEN-1:0] i_branch_target,
    input logic [XLEN-1:0] i_trap_target,
    input logic [XLEN-1:0] i_predicted_target,

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

  // Every FENCE-class event performs a full front-end flush and PC redirect in
  // pc_controller, so its same-cycle bubble is handled by the pipeline/frontend
  // flush inputs. Keep it out of this combinational change term: the registered
  // FENCE-class pulse has high fanout, and feeding it through the IF holdoff
  // cone puts it on the PC critical path. The separate registered holdoff below
  // still suppresses the stale post-fence fetch response.
  logic control_flow_change;
  logic control_flow_without_predictions;
  logic control_flow_holdoff_q;
  logic fence_i_fetch_holdoff_q;

  assign control_flow_change = i_trap_taken || i_mret_taken || i_branch_taken ||
                               i_pd_redirect || i_prediction_used ||
                               i_slot2_prediction_used;
  assign o_control_flow_change = control_flow_change;

  // ===========================================================================
  // Holdoff Registers
  // ===========================================================================
  // Track stale instruction cycles after control flow changes

  // No-progress fetch cycles freeze the front end like a stall: the holdoff
  // must survive them so the first delivered window after a redirect is still
  // treated as the stale-suppression cycle.
  logic fetch_stall;
  assign fetch_stall = i_stall || !i_fetch_progress;

  // Finish the non-prediction outcomes before either late prediction flag.
  // The flags then enter just one small gate with reset at each register.
  (* keep = "true" *)logic holdoff_without_predictions;
  (* keep = "true" *)logic reset_holdoff_without_predictions;
  logic control_flow_holdoff_next, reset_holdoff_next;
  assign holdoff_without_predictions = control_flow_without_predictions ||
      (control_flow_holdoff_q && fetch_stall);
  assign reset_holdoff_without_predictions = fetch_stall || control_flow_without_predictions;
  assign control_flow_holdoff_next = !i_reset &&
      (i_prediction_used || i_slot2_prediction_used || holdoff_without_predictions);
  assign reset_holdoff_next = i_reset || (o_reset_holdoff &&
      (i_prediction_used || i_slot2_prediction_used || reset_holdoff_without_predictions));

  always_ff @(posedge i_clk) begin
    // Redirects are captured even during a stall, so back-pressure cannot
    // skip the stale-response suppression cycle.
    control_flow_holdoff_q <= control_flow_holdoff_next;
    o_reset_holdoff <= reset_holdoff_next;
    if (i_reset) begin
      fence_i_fetch_holdoff_q <= 1'b0;
    end else begin
      fence_i_fetch_holdoff_q <= i_fence_i_flush || (fence_i_fetch_holdoff_q && fetch_stall);
    end
  end

`ifdef CONTROL_FLOW_HOLDOFF_LOCAL_PROOF
  // Original transitions, for arbitrary current bits and simultaneous inputs.
  always_comb begin
    assert (control_flow_holdoff_next ==
        (!i_reset && (control_flow_change || (control_flow_holdoff_q && fetch_stall))));
    assert (reset_holdoff_next ==
        (i_reset || (o_reset_holdoff && (fetch_stall || control_flow_change))));
  end
`endif

  // ===========================================================================
  // Combined Holdoff Signals
  // ===========================================================================
  // any_holdoff: All sources (includes combinational control_flow_change)
  // any_holdoff_safe: Only registered sources (breaks timing from branch_taken)

  assign o_control_flow_holdoff = control_flow_holdoff_q || fence_i_fetch_holdoff_q;
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
    (i_prediction_used && i_predicted_target[1]) ||
    (i_slot2_prediction_used && i_slot2_predicted_target[1]);

  // Complete all four next-state cases before either prediction-used flag
  // arrives. Slot 1 includes the live BTB tag comparison; slot 2 includes the
  // emitted-bundle validity cone. Neither late flag should traverse the
  // target OR and stalled-state hold logic before selecting the next state.
  // A prediction always redirects, even during a stall, so only the neither-
  // prediction case can retain the old flag. Simultaneous sources still OR
  // their target bits; no exclusivity is assumed. Reset is inside every kept
  // candidate so the final 4:1 mux needs only six inputs.
  logic halfword_without_predictions;
  (* keep = "true" *) logic [3:0] halfword_next_by_prediction;

  assign control_flow_without_predictions =
    i_trap_taken || i_mret_taken || i_branch_taken || i_pd_redirect;
  assign halfword_without_predictions =
    (i_branch_taken && i_branch_target[1]) ||
    ((i_trap_taken || i_mret_taken) && i_trap_target[1]) ||
    (i_pd_redirect && i_pd_redirect_target[1]);
  assign halfword_next_by_prediction[0] = !i_reset &&
    (halfword_without_predictions ||
     (o_control_flow_to_halfword_r && fetch_stall && !control_flow_without_predictions));
  assign halfword_next_by_prediction[1] = !i_reset &&
    (halfword_without_predictions || i_predicted_target[1]);
  assign halfword_next_by_prediction[2] = !i_reset &&
    (halfword_without_predictions || i_slot2_predicted_target[1]);
  assign halfword_next_by_prediction[3] = !i_reset &&
    (halfword_without_predictions || i_predicted_target[1] || i_slot2_predicted_target[1]);

  always_ff @(posedge i_clk) begin
    o_control_flow_to_halfword_r <= i_slot2_prediction_used ?
      (i_prediction_used ? halfword_next_by_prediction[3] : halfword_next_by_prediction[2]) :
      (i_prediction_used ? halfword_next_by_prediction[1] : halfword_next_by_prediction[0]);
  end

endmodule : control_flow_tracker
