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
 * Prediction Metadata Tracker
 *
 * Manages branch prediction metadata as it flows through the IF stage,
 * handling the complexities of stalls.
 *
 * When an instruction enters the pipeline, its prediction metadata must
 * accompany it through all stages. This is complicated by:
 *   1. Stalls - BRAM output changes during stall, but we need the original prediction
 *   2. NOPs - Inserted during holdoff cycles, have no valid prediction
 *
 * This module saves prediction metadata at critical points and selects the
 * correct metadata to output based on the current instruction type.
 *
 * Metadata Flow:
 *   - prediction_r: Registered prediction from branch_prediction_controller
 *   - prediction_saved: Saved at stall start for restoration
 *   - prediction_to_pd: Final output based on instruction type
 */
module prediction_metadata_tracker #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,
    input logic i_prediction_holdoff,  // Prediction happened - clear stale saved state
    input logic i_stall_registered,

    // Current registered prediction from branch_prediction_controller
    input logic            i_prediction_used_r,
    input logic [XLEN-1:0] i_predicted_target_r,
    input logic            i_pending_prediction_fetch_holdoff,

    // Instruction type signals (determine which metadata source to use)
    input logic i_sel_nop,          // Current output is NOP
    input logic i_sel_nop_saved,    // Saved sel_nop from stall
    input logic i_use_saved_values, // Use stall-saved values

    // Outputs to PD stage
    output logic            o_btb_hit,
    output logic            o_btb_predicted_taken,
    output logic [XLEN-1:0] o_btb_predicted_target
);

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prediction metadata when stall begins for restoration after unstall.

  logic            prediction_hit_saved;
  logic            prediction_taken_saved;
  logic [XLEN-1:0] prediction_target_saved;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      prediction_hit_saved <= 1'b0;
      prediction_taken_saved <= 1'b0;
      prediction_target_saved <= '0;
    end else if (i_stall & ~i_stall_registered) begin
      // Save at stall start
      prediction_hit_saved <= i_prediction_used_r;
      prediction_taken_saved <= i_prediction_used_r;
      prediction_target_saved <= i_predicted_target_r;
    end
  end

  // ===========================================================================
  // Pending Prediction Preservation
  // ===========================================================================
  // Pending prediction handoff preservation:
  // when IF keeps walking older instructions after a BTB redirect, the normal
  // 1-cycle registered metadata would otherwise get attached to the wrong
  // instruction and then disappear before the predicted branch itself arrives.

  logic            prediction_hit_pending_saved;
  logic            prediction_taken_pending_saved;
  logic [XLEN-1:0] prediction_target_pending_saved;
  logic            prediction_pending_saved_valid;

  logic            effective_sel_nop;
  assign effective_sel_nop = i_use_saved_values ? i_sel_nop_saved : i_sel_nop;

  logic effective_pending_prediction_consume;
  assign effective_pending_prediction_consume =
      prediction_pending_saved_valid &&
      !effective_sel_nop &&
      !i_pending_prediction_fetch_holdoff;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      prediction_hit_pending_saved    <= 1'b0;
      prediction_taken_pending_saved  <= 1'b0;
      prediction_target_pending_saved <= '0;
      prediction_pending_saved_valid  <= 1'b0;
    end else if (!i_stall) begin
      if (effective_pending_prediction_consume) begin
        prediction_pending_saved_valid <= 1'b0;
      end

      if (i_prediction_used_r && i_pending_prediction_fetch_holdoff) begin
        prediction_hit_pending_saved    <= i_prediction_used_r;
        prediction_taken_pending_saved  <= i_prediction_used_r;
        prediction_target_pending_saved <= i_predicted_target_r;
        prediction_pending_saved_valid  <= 1'b1;
      end
    end
  end

  // ===========================================================================
  // Output Selection
  // ===========================================================================
  // Select prediction metadata based on instruction type:
  //   1. sel_nop = 1: Clear prediction (NOP has no valid prediction)
  //   2. pending_saved valid: Replay saved BTB metadata for predicted branch
  //   3. pending holdoff: Clear metadata during old-path handoff phase
  //   4. Otherwise: Use normal registered (with stall handling)
  //
  // CRITICAL: When sel_nop is set, the output is a NOP, not the actual
  // instruction. Passing stale prediction metadata would cause incorrect
  // misprediction detection in EX stage.

  always_comb begin
    if (effective_sel_nop) begin
      // NOP: clear prediction metadata
      o_btb_hit = 1'b0;
      o_btb_predicted_taken = 1'b0;
      o_btb_predicted_target = '0;
    end else if (prediction_pending_saved_valid && !i_pending_prediction_fetch_holdoff) begin
      // The predicted branch/jump is finally reaching IF/PD after the pending
      // old-path handoff. Replay the saved BTB metadata on this instruction.
      o_btb_hit = prediction_hit_pending_saved;
      o_btb_predicted_taken = prediction_taken_pending_saved;
      o_btb_predicted_target = prediction_target_pending_saved;
    end else if (i_pending_prediction_fetch_holdoff) begin
      // During the old-path handoff phase, registered BTB metadata belongs to a
      // younger predicted branch, not the instruction currently in IF/PD.
      o_btb_hit = 1'b0;
      o_btb_predicted_taken = 1'b0;
      o_btb_predicted_target = '0;
    end else begin
      // Normal instruction: use registered prediction (with stall handling)
      o_btb_hit = i_use_saved_values ? prediction_hit_saved : i_prediction_used_r;
      o_btb_predicted_taken = i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
      o_btb_predicted_target = i_use_saved_values ? prediction_target_saved : i_predicted_target_r;
    end
  end

endmodule : prediction_metadata_tracker
