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
 * Aligns branch-prediction metadata with IF output across stalls and inserted
 * NOPs. Validity is saved when a stall begins, restored with the held
 * instruction, and cleared for bubbles. The target payload follows source
 * provenance independently and is meaningful only with predicted-taken.
 */
module prediction_metadata_tracker #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,
    // Pending-prediction fetch state killed by a redirect (or the stale
    // walk-past) in pc_controller this cycle.  The pending-saved metadata
    // below is the carried twin of that fetch state and must die with it;
    // see o_pending_prediction_redirect_kill in pc_controller.
    input logic i_pending_prediction_kill,
    // Legacy observation retained for the standalone/formal seam. Metadata
    // validity and payload routing no longer depend on this late signal.
    input logic i_prediction_holdoff,
    input logic i_stall_registered,

    // Current registered prediction from branch_prediction_controller
    input logic            i_prediction_used_r,
    input logic [XLEN-1:0] i_predicted_target_r,
    // Exact owner of a prediction that pc_controller has deferred while
    // pc_reg walks older instructions, and the PC of the packet IF is
    // presenting now. i_output_pc must follow the same live/stall-replay mux
    // as the rest of the IF->PD packet.
    input logic            i_pending_prediction_active,
    input logic [XLEN-1:0] i_pending_prediction_pc,
    input logic [XLEN-1:0] i_output_pc,
    // A variable-latency fetch can collapse the normal one-request lead so a
    // prediction is consumed in the same cycle its instruction is emitted.
    // That packet must carry the live prediction instead of the preceding
    // cycle's registered metadata.
    input logic            i_live_prediction_for_output,
    // Assertion-only provenance oracle for the same collapsed-lead case. The
    // synthesized wide target route is deliberately independent of prediction
    // enable, NOP, and combinational stall controls: an invalid packet may
    // carry arbitrary target data, while a valid packet must carry the target
    // from the lookup whose PC is aligned with that packet.
    input logic            i_live_target_aligned_with_output,
    input logic [XLEN-1:0] i_live_predicted_target,
    input logic            i_pending_prediction_fetch_holdoff,
    // Exact pc_controller consume/apply pulse for the pending target arm.
    // Metadata must remain saved unless the same owner handoff really wins.
    input logic            i_pending_prediction_target_handoff,

    // Instruction type signals (determine which metadata source to use)
    input logic i_sel_nop,          // Current output is NOP
    input logic i_sel_nop_saved,    // Saved sel_nop from stall
    input logic i_use_saved_values, // Use stall-saved values

`ifdef FORMAL
    // Explicit formal observation seam. Yosys does not resolve hierarchical
    // references from the standalone harness into this instance, so expose
    // the lifecycle state only in read-formal builds.
    output logic            o_formal_pending_valid,
    output logic            o_formal_pending_owner_match,
    output logic            o_formal_pending_consume,
    output logic [XLEN-1:0] o_formal_pending_pc,
    output logic [XLEN-1:0] o_formal_pending_target,
`endif

    // Outputs to PD stage
    output logic            o_btb_hit,
    output logic            o_btb_predicted_taken,
    output logic [XLEN-1:0] o_btb_predicted_target
);

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prediction metadata when stall begins for restoration after unstall.

  logic prediction_hit_saved;
  logic prediction_taken_saved;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      prediction_hit_saved   <= 1'b0;
      prediction_taken_saved <= 1'b0;
    end else if (i_stall & ~i_stall_registered) begin
      // Save at stall start
      prediction_hit_saved   <= i_prediction_used_r;
      prediction_taken_saved <= i_prediction_used_r;
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
  // The normal registered metadata can reach its exact owner on the first
  // pending-active cycle. If that packet is consumable now, attach it directly
  // and do not create a replay entry that would outlive pc_controller's
  // handoff. A NOP, held-off packet, non-owner predecessor, or stalled owner
  // must instead preserve the packet for a later exact-owner release.
  assign effective_pending_prediction_direct =
      !prediction_pending_saved_valid &&
      i_pending_prediction_active &&
      !effective_sel_nop &&
      !i_pending_prediction_fetch_holdoff &&
      pending_prediction_live_owner_matches_output;
  assign effective_pending_prediction_direct_consume =
      effective_pending_prediction_direct && !i_stall &&
      i_pending_prediction_target_handoff;

  // One capture per pending episode. Capture keys off the episode, not its
  // fetch-holdoff output: the immediate-predecessor carve-out opens that
  // holdoff on the first cycle the registered prediction exists. Capture is
  // also stall-independent because both pc_controller and the registered
  // target hold their owner/payload throughout a stall. Never overwrite the
  // first capture while the response is owed.
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

  // The kill must dominate the same-cycle capture: a PD redirect lands on
  // exactly the cycle the capture predicate still reads pre-kill pending
  // episode state. Without the kill, the saved
  // metadata outlives the pending fetch state it describes and the replay
  // below attaches "front-end already redirected" to the re-fetched
  // instruction whose redirect was in fact lost (for a predicted jal at a
  // taken-branch target, the ROB then retires it with no recovery and the
  // callee is skipped).  The kill is deliberately not stall-gated, matching
  // the pending-valid clear in pc_controller.
  //
  // The kill is an edge-clear only: on the kill cycle itself the pre-edge
  // saved state can still drive the combinational replay output below.  That
  // window is closed downstream for every redirect term -- the PD->ID
  // register zeroes btb_hit/btb_predicted_taken on flush and pd_redirect_r,
  // and trap/mret/branch_taken assert the flush -- so a same-cycle replayed
  // output is never consumed.  The stale walk-past term has no downstream
  // scrub, but it cannot coincide with a live saved replay: the pending
  // land-on-branch / immediate-predecessor pc_reg arms stop the walk exactly
  // on the pending PC (no step-over while the pending state is effective),
  // and the unguided post-redirect cycle that could step past has already
  // cleared the saved state via the same-cycle redirect term above.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_pending_prediction_kill) begin
      prediction_hit_pending_saved   <= 1'b0;
      prediction_taken_pending_saved <= 1'b0;
      prediction_pending_saved_valid <= 1'b0;
    end else if (pending_prediction_capture) begin
      // A live pc_controller pending episode is itself proof that a taken
      // prediction redirected fetch; the independently registered used bit is
      // no longer needed as a capture qualifier.
      prediction_hit_pending_saved   <= 1'b1;
      prediction_taken_pending_saved <= 1'b1;
      prediction_pending_saved_valid <= 1'b1;
    end else if (effective_pending_prediction_consume) begin
      prediction_pending_saved_valid <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (pending_prediction_capture) begin
      prediction_target_pending_saved <= i_predicted_target_r;
      prediction_pc_pending_saved     <= i_pending_prediction_pc;
    end
  end

  // ===========================================================================
  // Output Selection
  // ===========================================================================
  // Select prediction validity based on instruction type:
  //   1. sel_nop = 1: Clear prediction (NOP has no valid prediction)
  //   2. pending-saved owner: replay saved metadata for its exact branch
  //   3. first-cycle pending owner: attach registered metadata directly
  //   4. pending non-owner: clear metadata without consuming it
  //   5. same-cycle prediction: attach live metadata to the emitted branch
  //   6. Otherwise: use normal registered metadata (with stall handling)
  //
  // A NOP must carry no prediction metadata; stale metadata would trigger
  // incorrect EX misprediction detection.
  always_comb begin
    if (effective_sel_nop) begin
      // NOP: clear prediction metadata
      o_btb_hit             = 1'b0;
      o_btb_predicted_taken = 1'b0;
    end else if (effective_pending_prediction_replay) begin
      // The exact predicted branch/jump is finally reaching IF/PD after the
      // pending old-path handoff. Replay the saved BTB metadata only here.
      o_btb_hit             = prediction_hit_pending_saved;
      o_btb_predicted_taken = prediction_taken_pending_saved;
    end else if (effective_pending_prediction_direct) begin
      // The exact owner arrived before a side-buffer capture was necessary.
      // pc_controller's active episode proves this registered packet is a
      // taken prediction; a concurrent stall captures it for release.
      o_btb_hit             = 1'b1;
      o_btb_predicted_taken = 1'b1;
    end else if (prediction_pending_saved_valid || i_pending_prediction_active ||
                 i_pending_prediction_fetch_holdoff) begin
      // During the old-path handoff, registered BTB metadata belongs to a
      // younger predicted branch. The served-window immediate-predecessor
      // carve-out deliberately releases a real older packet with the fetch
      // holdoff low; its PC mismatch must neither stamp nor consume the saved
      // branch metadata.
      o_btb_hit             = 1'b0;
      o_btb_predicted_taken = 1'b0;
    end else if (i_live_prediction_for_output) begin
      // Normal BRAM timing predicts one request ahead and uses the registered
      // path below. A delayed response can instead put lookup PC and emitted
      // instruction PC on the same packet; using i_prediction_used_r there
      // would record not-taken after the fetch stream already redirected.
      o_btb_hit             = 1'b1;
      o_btb_predicted_taken = 1'b1;
    end else begin
      // Normal instruction: use registered prediction (with stall handling)
      o_btb_hit             = i_use_saved_values ? prediction_hit_saved : i_prediction_used_r;
      o_btb_predicted_taken = i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
    end
  end

  // Target payload routing is intentionally separate from prediction
  // validity.  In particular, the current-cycle stall/dispatch cone may clear
  // hit/taken, but must not select or zero 64 target bits on their way to the
  // PD register.  The registered target already holds throughout an IF stall,
  // so the old stall-saved target replica was redundant.  Pending replay has
  // its own registered provenance. Existing or stall-replayed metadata
  // retains its target (including a self-targeting prediction whose live RAS
  // state has already popped); otherwise the target is harmless live payload.
  // The raw PC-alignment comparison remains a validity/proof input only and
  // never selects these 64 bits.
  //
  // The payload is architecturally meaningful only when
  // o_btb_predicted_taken is high.  Letting invalid packets carry one of these
  // provenance-selected values is therefore cycle-exact at every consumer.
  always_comb begin
    if (prediction_pending_saved_valid) begin
      o_btb_predicted_target = prediction_target_pending_saved;
    end else if (i_use_saved_values || i_prediction_used_r) begin
      o_btb_predicted_target = i_predicted_target_r;
    end else begin
      o_btb_predicted_target = i_live_predicted_target;
    end
  end

`ifndef SYNTHESIS
  // Preserve the retired validity-qualified target mux as an oracle.  The
  // observable packet is {hit, taken, taken ? target : don't-care}: validity
  // must remain bit-exact, and every valid target must match.  This also pins
  // the contract that a changed target on an invalid bubble is ignored.
  logic [XLEN-1:0] prediction_target_saved_legacy;
  logic            btb_hit_legacy;
  logic            btb_predicted_taken_legacy;
  logic [XLEN-1:0] btb_predicted_target_legacy;

  always_ff @(posedge i_clk) begin
    if (i_stall & ~i_stall_registered) begin
      prediction_target_saved_legacy <= i_predicted_target_r;
    end
  end

  always_comb begin
    if (effective_sel_nop) begin
      btb_hit_legacy              = 1'b0;
      btb_predicted_taken_legacy  = 1'b0;
      btb_predicted_target_legacy = '0;
    end else if (effective_pending_prediction_replay) begin
      btb_hit_legacy              = prediction_hit_pending_saved;
      btb_predicted_taken_legacy  = prediction_taken_pending_saved;
      btb_predicted_target_legacy = prediction_target_pending_saved;
    end else if (effective_pending_prediction_direct) begin
      btb_hit_legacy              = 1'b1;
      btb_predicted_taken_legacy  = 1'b1;
      btb_predicted_target_legacy = i_predicted_target_r;
    end else if (prediction_pending_saved_valid || i_pending_prediction_active ||
                 i_pending_prediction_fetch_holdoff) begin
      btb_hit_legacy              = 1'b0;
      btb_predicted_taken_legacy  = 1'b0;
      btb_predicted_target_legacy = '0;
    end else if (i_live_prediction_for_output) begin
      btb_hit_legacy              = 1'b1;
      btb_predicted_taken_legacy  = 1'b1;
      btb_predicted_target_legacy = i_live_predicted_target;
    end else begin
      btb_hit_legacy = i_use_saved_values ? prediction_hit_saved : i_prediction_used_r;
      btb_predicted_taken_legacy =
          i_use_saved_values ? prediction_taken_saved : i_prediction_used_r;
      btb_predicted_target_legacy =
          i_use_saved_values ? prediction_target_saved_legacy : i_predicted_target_r;
    end
  end

  // Compare the two independently selected views only at a clock boundary.
  // Pending capture updates validity, payload, and owner in parallel NBAs;
  // an immediate assertion in a third combinational process can observe one
  // selector before the other during Verilator's delta-cycle convergence even
  // though the stable packet is identical.
  always_ff @(posedge i_clk) begin
    if (!$isunknown(
            {o_btb_hit, o_btb_predicted_taken, btb_hit_legacy, btb_predicted_taken_legacy}
        )) begin
      p_prediction_validity_matches_legacy :
      assert ({o_btb_hit, o_btb_predicted_taken} == {btb_hit_legacy, btb_predicted_taken_legacy});
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
      // Away from a pending episode, the collapsed-lead live lookup is the
      // unique metadata source. During a pending episode the owner/replay
      // priority above is authoritative even if a younger lookup appears.
      p_unowned_live_prediction_excludes_registered_metadata :
      assert (!i_live_prediction_for_output || i_pending_prediction_active ||
              prediction_pending_saved_valid || !i_prediction_used_r);
    end

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
              o_btb_hit,
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
              (!o_btb_hit && !o_btb_predicted_taken));
      p_direct_pending_metadata_has_exact_owner :
      assert (!effective_pending_prediction_direct || pending_prediction_live_owner_matches_output);
      p_pending_capture_is_not_direct_consume :
      assert (!(pending_prediction_capture && effective_pending_prediction_direct_consume));
      p_direct_pending_consume_observes_handoff :
      assert (!effective_pending_prediction_direct_consume || i_pending_prediction_target_handoff);
      p_active_pending_nonowner_carries_no_valid_metadata :
      assert (!i_pending_prediction_active || prediction_pending_saved_valid ||
              pending_prediction_live_owner_matches_output ||
              (!o_btb_hit && !o_btb_predicted_taken));
    end
  end
`endif

endmodule : prediction_metadata_tracker
