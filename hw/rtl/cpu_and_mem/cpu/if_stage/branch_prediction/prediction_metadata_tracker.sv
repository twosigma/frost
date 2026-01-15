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
 * handling the complexities of stalls and spanning instructions.
 *
 * When an instruction enters the pipeline, its prediction metadata must
 * accompany it through all stages. This is complicated by:
 *   1. Stalls - BRAM output changes during stall, but we need the original prediction
 *   2. Spanning - 32-bit instructions spanning two words take multiple cycles
 *   3. NOPs - Inserted during holdoff cycles, have no valid prediction
 *
 * This module saves prediction metadata at critical points and selects the
 * correct metadata to output based on the current instruction type.
 *
 * Metadata Flow:
 *   - prediction_r: Registered prediction from branch_prediction_controller
 *   - prediction_saved: Saved at stall start for restoration
 *   - prediction_spanning_saved: Saved when spanning starts
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

    // Instruction type signals (determine which metadata source to use)
    input logic i_sel_nop,             // Current output is NOP
    input logic i_sel_spanning,        // Current output is spanning instruction
    input logic i_sel_nop_saved,       // Saved sel_nop from stall
    input logic i_sel_spanning_saved,  // Saved sel_spanning from stall
    input logic i_use_saved_values,    // Use stall-saved values

    // Spanning detection
    input logic i_is_32bit_spanning,
    input logic i_spanning_wait_for_fetch,

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
  // Spanning Instruction Preservation
  // ===========================================================================
  // When a 32-bit instruction spans two memory words (halfword-aligned), the
  // first cycle outputs NOP while waiting for the second word. By the time we
  // output the actual spanning instruction, the registered prediction has
  // advanced to a different PC. Save prediction when spanning starts.
  //
  // Detect first cycle of spanning (is_32bit_spanning but not yet in wait state)

  logic spanning_first_cycle;
  assign spanning_first_cycle = i_is_32bit_spanning && !i_spanning_wait_for_fetch;

  logic            prediction_hit_spanning_saved;
  logic            prediction_taken_spanning_saved;
  logic [XLEN-1:0] prediction_target_spanning_saved;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      prediction_hit_spanning_saved <= 1'b0;
      prediction_taken_spanning_saved <= 1'b0;
      prediction_target_spanning_saved <= '0;
    end else if (!i_stall && spanning_first_cycle) begin
      // Save when spanning starts
      prediction_hit_spanning_saved <= i_prediction_used_r;
      prediction_taken_spanning_saved <= i_prediction_used_r;
      prediction_target_spanning_saved <= i_predicted_target_r;
    end
    // Note: Don't clear on other conditions. Stale values when not in
    // spanning are harmless since sel_spanning gates their use.
  end

  // ===========================================================================
  // Output Selection
  // ===========================================================================
  // Select prediction metadata based on instruction type:
  //   1. sel_nop = 1: Clear prediction (NOP has no valid prediction)
  //   2. sel_spanning = 1: Use spanning-saved (from when spanning started)
  //   3. Otherwise: Use normal registered (with stall handling)
  //
  // CRITICAL: When sel_nop is set, the output is a NOP, not the actual
  // instruction. Passing stale prediction metadata would cause incorrect
  // misprediction detection in EX stage.
  //
  // ALSO: Spanning instructions are at halfword-aligned addresses (pc_reg[1]=1).
  // Predictions are blocked for halfword-aligned PCs, so spanning instructions
  // never have valid predictions. Always output zeros to prevent stale metadata.

  logic effective_sel_nop;
  logic effective_sel_spanning;
  assign effective_sel_nop = i_use_saved_values ? i_sel_nop_saved : i_sel_nop;
  assign effective_sel_spanning = i_use_saved_values ? i_sel_spanning_saved : i_sel_spanning;

  always_comb begin
    if (effective_sel_nop) begin
      // NOP: clear prediction metadata
      o_btb_hit = 1'b0;
      o_btb_predicted_taken = 1'b0;
      o_btb_predicted_target = '0;
    end else if (effective_sel_spanning) begin
      // Spanning: predictions blocked for halfword PCs, always output zeros
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
