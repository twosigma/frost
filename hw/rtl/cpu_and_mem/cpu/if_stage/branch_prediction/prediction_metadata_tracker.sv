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
 * Aligns slot-1 prediction metadata (taken, target, and the call and return
 * types of the BTB entry behind the target) with the packet IF emits,
 * across stalls, NOP bubbles, and the pending-prediction handoff
 * (hw/rtl/cpu_and_mem/cpu/README.md, "Pending-prediction handoff"). Validity
 * is saved when a stall begins, restored with the held instruction, and
 * cleared for bubbles. Only the packet at a pending prediction's saved PC
 * may carry or consume it. Target and call/return types are meaningful only
 * when the packet is predicted taken.
 */
module prediction_metadata_tracker #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,
    // Clear saved metadata when pc_controller kills the pending prediction
    // after a redirect or after pc_reg steps past its PC.
    input logic i_pending_prediction_kill,
    input logic i_stall_registered,

    // Current registered prediction from branch_prediction_controller
    input logic            i_prediction_used_r,
    input logic [XLEN-1:0] i_predicted_target_r,
    input logic            i_predicted_is_call_r,
    input logic            i_predicted_is_return_r,
    // Deferred prediction state and the output packet's PC. i_output_pc
    // must use the same live/replay selection as the rest of the IF-to-PD packet.
    input logic            i_pending_prediction_active,
    input logic [XLEN-1:0] i_pending_prediction_pc,
    input logic [XLEN-1:0] i_output_pc,
    // A variable-latency fetch can collapse the normal one-request lead so a
    // prediction is consumed in the same cycle its instruction is emitted.
    // That packet must carry the live prediction instead of the preceding
    // cycle's registered metadata.
    input logic            i_live_prediction_for_output,
    // Assertion-only check that the live lookup PC matches the output PC.
    // An invalid packet may carry any target.
    input logic            i_live_target_aligned_with_output,
    input logic [XLEN-1:0] i_live_predicted_target,
    input logic            i_live_predicted_is_call,
    input logic            i_live_predicted_is_return,
    input logic            i_pending_prediction_fetch_holdoff,
    // Apply the pending target. Consume saved metadata only when this pulse
    // accompanies its unstalled instruction at the output.
    input logic            i_pending_prediction_target_handoff,

    // Instruction type signals (determine which metadata source to use)
    input logic i_sel_nop,          // Current output is NOP
    input logic i_sel_nop_saved,    // Saved sel_nop from stall
    input logic i_use_saved_values, // Use stall-saved values

`ifdef FORMAL
    // Formal-only observation ports: Yosys does not resolve hierarchical
    // references from the standalone harness into this instance.
    output logic            o_formal_pending_valid,
    output logic            o_formal_pending_owner_match,
    output logic            o_formal_pending_consume,
    output logic [XLEN-1:0] o_formal_pending_pc,
    output logic [XLEN-1:0] o_formal_pending_target,
`endif

    // Outputs to PD stage
    output logic            o_btb_predicted_taken,
    output logic [XLEN-1:0] o_btb_predicted_target,
    // Types of the entry behind o_btb_predicted_target, which drive IF's
    // return address stack operation for the packet
    output logic            o_btb_predicted_is_call,
    output logic            o_btb_predicted_is_return
);

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prediction metadata when stall begins for restoration after unstall.

  logic prediction_taken_saved;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      prediction_taken_saved <= 1'b0;
    end else if (i_stall & ~i_stall_registered) begin
      prediction_taken_saved <= i_prediction_used_r;
    end
  end

  // ===========================================================================
  // Pending Prediction Preservation
  // ===========================================================================
  // When IF keeps walking older instructions after a BTB redirect, the normal
  // 1-cycle registered metadata would attach to the wrong instruction and then
  // disappear before the predicted branch itself arrives. The state below
  // carries it until that branch reaches the output.

  logic            prediction_taken_pending_saved;
  logic [XLEN-1:0] prediction_target_pending_saved;
  logic            prediction_is_call_pending_saved;
  logic            prediction_is_return_pending_saved;
  logic [XLEN-1:0] prediction_pc_pending_saved;
  logic            prediction_pending_saved_valid;

  logic            effective_sel_nop;
  assign effective_sel_nop = i_use_saved_values ? i_sel_nop_saved : i_sel_nop;

  logic effective_pending_prediction_replay;
  logic effective_pending_prediction_consume;
  logic effective_pending_prediction_direct;
  logic effective_pending_prediction_direct_consume;
  logic pending_prediction_capture;
  logic pending_prediction_owner_matches_output;
  logic pending_prediction_live_owner_matches_output;
  assign pending_prediction_owner_matches_output = i_output_pc == prediction_pc_pending_saved;
  assign pending_prediction_live_owner_matches_output = i_output_pc == i_pending_prediction_pc;
  assign effective_pending_prediction_replay =
      prediction_pending_saved_valid &&
      !effective_sel_nop &&
      !i_pending_prediction_fetch_holdoff &&
      pending_prediction_owner_matches_output;
  assign effective_pending_prediction_consume =
      effective_pending_prediction_replay && !i_stall &&
      i_pending_prediction_target_handoff;
  // If the predicted instruction emits on the first pending cycle, attach
  // the registered metadata directly and do not leave a saved copy after
  // handoff. Otherwise save it for that instruction's later release.
  assign effective_pending_prediction_direct =
      !prediction_pending_saved_valid &&
      i_pending_prediction_active &&
      !effective_sel_nop &&
      !i_pending_prediction_fetch_holdoff &&
      pending_prediction_live_owner_matches_output;
  assign effective_pending_prediction_direct_consume =
      effective_pending_prediction_direct && !i_stall &&
      i_pending_prediction_target_handoff;

  // Capture once, using pending active rather than fetch holdoff: the
  // immediate-predecessor exception can release holdoff on this first cycle.
  // Capture may occur during a stall because pending state and target hold.
  // Do not overwrite the saved copy before consumption or kill.
  assign pending_prediction_capture =
      !prediction_pending_saved_valid &&
      i_pending_prediction_active &&
      !effective_pending_prediction_direct_consume;

`ifdef FORMAL
  assign o_formal_pending_valid       = prediction_pending_saved_valid;
  assign o_formal_pending_owner_match = pending_prediction_owner_matches_output;
  assign o_formal_pending_consume     = effective_pending_prediction_consume;
  assign o_formal_pending_pc          = prediction_pc_pending_saved;
  assign o_formal_pending_target      = prediction_target_pending_saved;
`endif

  // Kill must override capture, including during stalls. A PD redirect can
  // coincide with capture of pre-kill state; retaining it would mark a
  // refetched instruction as redirected when its target was never fetched.
  // A predicted JAL could then retire without recovery.
  //
  // Kill clears state at the edge, so replay can still appear that cycle.
  // Redirects squash that output through flush or PD's redirect clear. A
  // walk-past kill has no such clear, but cannot overlap saved replay:
  // pending pc_reg arms stop at the predicted PC, and any redirect allowing
  // pc_reg to step past it has already cleared saved metadata.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_pending_prediction_kill) begin
      prediction_taken_pending_saved <= 1'b0;
      prediction_pending_saved_valid <= 1'b0;
    end else if (pending_prediction_capture) begin
      // An active pending prediction means a taken prediction redirected
      // fetch, so i_prediction_used_r is not needed to qualify the capture.
      prediction_taken_pending_saved <= 1'b1;
      prediction_pending_saved_valid <= 1'b1;
    end else if (effective_pending_prediction_consume) begin
      prediction_pending_saved_valid <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (pending_prediction_capture) begin
      prediction_target_pending_saved    <= i_predicted_target_r;
      prediction_is_call_pending_saved   <= i_predicted_is_call_r;
      prediction_is_return_pending_saved <= i_predicted_is_return_r;
      prediction_pc_pending_saved        <= i_pending_prediction_pc;
    end
  end

  // ===========================================================================
  // Output Selection
  // ===========================================================================
  // Validity, in priority order:
  //   1. NOP or pending fetch holdoff: no prediction. Stale metadata on a NOP
  //      would cause a false misprediction in EX.
  //   2. Saved pending prediction at its saved PC: replay the saved metadata.
  //   3. First pending cycle at the predicted PC: attach the registered metadata.
  //   4. Any other packet while a prediction is saved or pending: no
  //      prediction, and nothing is consumed.
  //   5. Collapsed lead: attach the live prediction to the emitted packet.
  //   6. Otherwise: the registered metadata, or its stall-saved copy.
  //
  // Select by saved state and PC equality before applying bubble and
  // fetch-holdoff gates.
  (* keep = "true" *)logic owner_taken_live;
  (* keep = "true" *)logic owner_taken_registered;
  logic output_prediction_allowed;
  always_comb begin
    if (prediction_pending_saved_valid) begin
      owner_taken_live = pending_prediction_owner_matches_output && prediction_taken_pending_saved;
      owner_taken_registered = owner_taken_live;
    end else if (i_pending_prediction_active) begin
      owner_taken_live = pending_prediction_live_owner_matches_output;
      owner_taken_registered = pending_prediction_live_owner_matches_output;
    end else begin
      owner_taken_live = 1'b1;
      owner_taken_registered = i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
    end
  end
  assign output_prediction_allowed = !effective_sel_nop && !i_pending_prediction_fetch_holdoff;
  assign o_btb_predicted_taken = output_prediction_allowed &&
      (i_live_prediction_for_output ? owner_taken_live : owner_taken_registered);

`ifdef PRED_METADATA_OUTPUT_LOCAL_PROOF
  logic f_btb_taken;
  logic validity_prefix_decides;
  logic validity_prefix_taken;
  logic registered_taken;
  (* keep = "true" *)logic taken_when_live;
  (* keep = "true" *)logic taken_when_not_live;
  always_comb begin
    validity_prefix_decides = 1'b1;
    validity_prefix_taken   = 1'b0;
    if (effective_sel_nop) begin
      validity_prefix_taken = 1'b0;
    end else if (effective_pending_prediction_replay) begin
      // Only the predicted instruction may replay the saved metadata.
      validity_prefix_taken = prediction_taken_pending_saved;
    end else if (effective_pending_prediction_direct) begin
      // On the first pending cycle, the registered prediction is taken.
      // A coinciding stall captures it for later release.
      validity_prefix_taken = 1'b1;
    end else if (prediction_pending_saved_valid || i_pending_prediction_active ||
                 i_pending_prediction_fetch_holdoff) begin
      // An older packet released by the predecessor exception cannot carry
      // or consume the younger branch's prediction.
      validity_prefix_taken = 1'b0;
    end else begin
      validity_prefix_decides = 1'b0;
    end
  end
  assign registered_taken = i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
  // A delayed fetch can align the live lookup and output PCs. Use the live
  // taken bit then, or the packet could report not-taken after redirecting.
  assign taken_when_live = validity_prefix_decides ? validity_prefix_taken : 1'b1;
  assign taken_when_not_live = validity_prefix_decides ? validity_prefix_taken : registered_taken;
  assign f_btb_taken = i_live_prediction_for_output ? taken_when_live : taken_when_not_live;

  always_comb begin
    assert (o_btb_predicted_taken == f_btb_taken);
    // Formal checks settled combinational values; simulation checks at capture.
    assert (!prediction_pending_saved_valid || pending_prediction_owner_matches_output ||
        !o_btb_predicted_taken);
    assert (!i_pending_prediction_active || prediction_pending_saved_valid ||
        pending_prediction_live_owner_matches_output || !o_btb_predicted_taken);
  end
`endif

  // Target and types are selected independently of validity. No stall copy
  // is needed: the registered target holds through stalls, and pending
  // predictions have their own saved copy. Registered metadata takes
  // priority over a live lookup, even for a self-targeting prediction.
  // Consumers ignore the target unless o_btb_predicted_taken is set.
  always_comb begin
    if (prediction_pending_saved_valid) begin
      o_btb_predicted_target    = prediction_target_pending_saved;
      o_btb_predicted_is_call   = prediction_is_call_pending_saved;
      o_btb_predicted_is_return = prediction_is_return_pending_saved;
    end else if (i_use_saved_values || i_prediction_used_r) begin
      o_btb_predicted_target    = i_predicted_target_r;
      o_btb_predicted_is_call   = i_predicted_is_call_r;
      o_btb_predicted_is_return = i_predicted_is_return_r;
    end else begin
      o_btb_predicted_target    = i_live_predicted_target;
      o_btb_predicted_is_call   = i_live_predicted_is_call;
      o_btb_predicted_is_return = i_live_predicted_is_return;
    end
  end

`ifndef SYNTHESIS
  // Compare with a validity-qualified mux and stall-saved target. Validity
  // must match; targets and types need match only for taken predictions.
  logic [XLEN-1:0] prediction_target_saved_legacy;
  logic [     1:0] prediction_kind_saved_legacy;
  logic            btb_predicted_taken_legacy;
  logic [XLEN-1:0] btb_predicted_target_legacy;
  // The call and return types, selected with the target.
  logic [     1:0] btb_predicted_kind_legacy;

  always_ff @(posedge i_clk) begin
    if (i_stall & ~i_stall_registered) begin
      prediction_target_saved_legacy <= i_predicted_target_r;
      prediction_kind_saved_legacy   <= {i_predicted_is_call_r, i_predicted_is_return_r};
    end
  end

  always_comb begin
    btb_predicted_kind_legacy = '0;
    if (effective_sel_nop) begin
      btb_predicted_taken_legacy  = 1'b0;
      btb_predicted_target_legacy = '0;
    end else if (effective_pending_prediction_replay) begin
      btb_predicted_taken_legacy = prediction_taken_pending_saved;
      btb_predicted_target_legacy = prediction_target_pending_saved;
      btb_predicted_kind_legacy = {
        prediction_is_call_pending_saved, prediction_is_return_pending_saved
      };
    end else if (effective_pending_prediction_direct) begin
      btb_predicted_taken_legacy  = 1'b1;
      btb_predicted_target_legacy = i_predicted_target_r;
      btb_predicted_kind_legacy   = {i_predicted_is_call_r, i_predicted_is_return_r};
    end else if (prediction_pending_saved_valid || i_pending_prediction_active ||
                 i_pending_prediction_fetch_holdoff) begin
      btb_predicted_taken_legacy  = 1'b0;
      btb_predicted_target_legacy = '0;
    end else if (i_live_prediction_for_output) begin
      btb_predicted_taken_legacy  = 1'b1;
      btb_predicted_target_legacy = i_live_predicted_target;
      btb_predicted_kind_legacy   = {i_live_predicted_is_call, i_live_predicted_is_return};
    end else begin
      btb_predicted_taken_legacy =
          i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
      btb_predicted_target_legacy =
          i_use_saved_values ? prediction_target_saved_legacy : i_predicted_target_r;
      btb_predicted_kind_legacy =
          i_use_saved_values ? prediction_kind_saved_legacy :
                               {i_predicted_is_call_r, i_predicted_is_return_r};
    end
  end

  // Compare at the clock boundary: pending validity, PC, and payload update
  // in separate nonblocking assignments and can disagree during delta cycles.
  always_ff @(posedge i_clk) begin
    if (!$isunknown({o_btb_predicted_taken, btb_predicted_taken_legacy})) begin
      p_prediction_validity_matches_legacy :
      assert (o_btb_predicted_taken == btb_predicted_taken_legacy);
    end

    if (!$isunknown(
            {
              o_btb_predicted_taken,
              o_btb_predicted_target,
              btb_predicted_taken_legacy,
              btb_predicted_target_legacy
            }
        )) begin
      p_valid_prediction_target_matches_legacy :
      assert (!btb_predicted_taken_legacy ||
              (o_btb_predicted_target == btb_predicted_target_legacy));
    end
    if (!$isunknown(
            {
              btb_predicted_taken_legacy,
              o_btb_predicted_is_call,
              o_btb_predicted_is_return,
              btb_predicted_kind_legacy
            }
        )) begin
      p_valid_prediction_types_match_legacy :
      assert (!btb_predicted_taken_legacy ||
              ({o_btb_predicted_is_call, o_btb_predicted_is_return} ==
               btb_predicted_kind_legacy));
    end
    if (!$isunknown(
            {
              o_btb_predicted_taken,
              o_btb_predicted_target,
              btb_predicted_taken_legacy,
              btb_predicted_target_legacy
            }
        )) begin
      p_invalid_prediction_payload_is_ignored :
      assert (({XLEN{o_btb_predicted_taken}} & o_btb_predicted_target) ==
              ({XLEN{btb_predicted_taken_legacy}} & btb_predicted_target_legacy));
    end
  end

  always_comb begin
    if (!$isunknown(
            {
              i_live_prediction_for_output,
              i_live_target_aligned_with_output,
              i_stall_registered,
              i_prediction_used_r,
              prediction_pending_saved_valid,
              i_pending_prediction_active
            }
        )) begin
      p_live_valid_has_live_payload_provenance :
      assert (!i_live_prediction_for_output ||
              (i_live_target_aligned_with_output && !i_stall_registered));
      // Outside a pending prediction, the collapsed-lead live lookup is the
      // only metadata source. While a prediction is pending, the saved PC and
      // replay priority above decide, even if a younger lookup appears.
      p_unowned_live_prediction_excludes_registered_metadata :
      assert (!i_live_prediction_for_output || i_pending_prediction_active ||
              prediction_pending_saved_valid || !i_prediction_used_r);
    end
  end

  // Check PC matching and consumption at capture, after the independent
  // combinational selections settle.
  always_ff @(posedge i_clk) begin
    if (!$isunknown(
            {
              prediction_pending_saved_valid,
              effective_pending_prediction_replay,
              effective_pending_prediction_consume,
              effective_pending_prediction_direct,
              effective_pending_prediction_direct_consume,
              pending_prediction_capture,
              i_pending_prediction_target_handoff,
              pending_prediction_owner_matches_output,
              pending_prediction_live_owner_matches_output,
              effective_sel_nop,
              i_pending_prediction_fetch_holdoff,
              o_btb_predicted_taken
            }
        )) begin
      p_pending_metadata_emits_only_for_exact_owner :
      assert (!prediction_pending_saved_valid || !o_btb_predicted_taken ||
              pending_prediction_owner_matches_output);
      p_pending_consume_has_exact_owner_and_open_packet :
      assert (!effective_pending_prediction_consume ||
              (pending_prediction_owner_matches_output && !effective_sel_nop &&
               !i_pending_prediction_fetch_holdoff && !i_stall &&
               i_pending_prediction_target_handoff));
      p_pending_nonowner_carries_no_valid_metadata :
      assert (!prediction_pending_saved_valid || pending_prediction_owner_matches_output ||
              !o_btb_predicted_taken);
      p_direct_pending_metadata_has_exact_owner :
      assert (!effective_pending_prediction_direct || pending_prediction_live_owner_matches_output);
      p_pending_capture_is_not_direct_consume :
      assert (!(pending_prediction_capture && effective_pending_prediction_direct_consume));
      p_direct_pending_consume_observes_handoff :
      assert (!effective_pending_prediction_direct_consume || i_pending_prediction_target_handoff);
      p_active_pending_nonowner_carries_no_valid_metadata :
      assert (!i_pending_prediction_active || prediction_pending_saved_valid ||
              pending_prediction_live_owner_matches_output || !o_btb_predicted_taken);
    end
  end
`endif

endmodule : prediction_metadata_tracker
