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

// Formal environment for prediction_metadata_tracker's split control/payload
// contract.  The registered predictor target models the production
// branch_prediction_controller: it may change freely on a running cycle and
// holds throughout a stall. Pending prediction owner/output PCs are arbitrary,
// so the proof covers both exact-owner replay and a real non-owner predecessor.
// The remaining controls and payloads are arbitrary except for the
// source-provenance and reset implications that if_stage guarantees.
module prediction_metadata_tracker_formal (
    input logic i_clk
);

  localparam int unsigned XLEN = 8;

  (* anyseq *) logic i_reset;
  (* anyseq *) logic i_stall;
  (* anyseq *) logic i_flush;
  (* anyseq *) logic i_pending_prediction_kill;
  (* anyseq *) logic i_prediction_holdoff;
  (* anyseq *) logic i_prediction_used_r;
  (* anyseq *) logic i_pending_prediction_active;
  (* anyseq *) logic [XLEN-1:0] i_pending_prediction_pc;
  (* anyseq *) logic [XLEN-1:0] i_output_pc;
  (* anyseq *) logic i_live_prediction_for_output;
  (* anyseq *) logic i_live_target_aligned_with_output;
  (* anyseq *) logic [XLEN-1:0] i_live_predicted_target;
  (* anyseq *) logic i_pending_prediction_fetch_holdoff;
  (* anyseq *) logic i_pending_prediction_target_handoff;
  (* anyseq *) logic i_sel_nop;
  (* anyseq *) logic i_sel_nop_saved;
  (* anyseq *) logic i_use_saved_values;
  (* anyseq *) logic [XLEN-1:0] next_registered_target;

  logic f_past_valid;
  logic i_stall_registered;
  logic [XLEN-1:0] i_predicted_target_r;
  logic o_btb_hit;
  logic o_btb_predicted_taken;
  logic [XLEN-1:0] o_btb_predicted_target;
  logic formal_pending_valid;
  logic formal_pending_owner_match;
  logic formal_pending_consume;
  logic [XLEN-1:0] formal_pending_pc;
  logic [XLEN-1:0] formal_pending_target;

  initial begin
    f_past_valid = 1'b0;
    assume (i_reset);
  end

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;

    if (i_reset) begin
      i_stall_registered   <= 1'b0;
      i_predicted_target_r <= '0;
    end else begin
      i_stall_registered <= i_stall;
      if (!i_stall) begin
        i_predicted_target_r <= next_registered_target;
      end
    end

  end

  always_comb begin
    // A saved replay is a subset of the registered-stall phase.  Extra
    // arbitrary blockers are omitted so the proof covers more control
    // combinations than the production integration can generate.
    assume (!i_use_saved_values || i_stall_registered);

    // A collapsed-lead valid is generated from the raw same-PC phase and only
    // when neither registered nor pending metadata already owns the packet.
    assume (!i_live_prediction_for_output ||
            (i_live_target_aligned_with_output && !i_stall_registered &&
             !i_prediction_used_r &&
             !formal_pending_valid));

    // Production reset inserts a NOP and never asks for saved/live metadata.
    assume (!i_reset || (i_sel_nop && !i_use_saved_values && !i_live_prediction_for_output));
  end

  prediction_metadata_tracker #(
      .XLEN(XLEN)
  ) u_dut (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_flush,
      .i_pending_prediction_kill,
      .i_prediction_holdoff,
      .i_stall_registered,
      .i_prediction_used_r,
      .i_predicted_target_r,
      .i_pending_prediction_active,
      .i_pending_prediction_pc,
      .i_output_pc,
      .i_live_prediction_for_output,
      .i_live_target_aligned_with_output,
      .i_live_predicted_target,
      .i_pending_prediction_fetch_holdoff,
      .i_pending_prediction_target_handoff,
      .i_sel_nop,
      .i_sel_nop_saved,
      .i_use_saved_values,
      .o_formal_pending_valid(formal_pending_valid),
      .o_formal_pending_owner_match(formal_pending_owner_match),
      .o_formal_pending_consume(formal_pending_consume),
      .o_formal_pending_pc(formal_pending_pc),
      .o_formal_pending_target(formal_pending_target),
      .o_btb_hit,
      .o_btb_predicted_taken,
      .o_btb_predicted_target
  );

  // Reach each payload provenance, including an invalid packet with a nonzero
  // target.  The DUT's legacy oracle asserts that the latter is observationally
  // identical once the taken bit gates the target.
  always_ff @(posedge i_clk) begin
    if (f_past_valid && $past(
            formal_pending_valid
        ) && !$past(
            i_reset || i_flush || i_pending_prediction_kill || formal_pending_consume
        )) begin
      // A pending episode is immutable until its exact owner consumes it or a
      // reset/redirect kills it. In particular, another apparent prediction
      // during fetch holdoff cannot overwrite the saved owner or target.
      assert (formal_pending_valid);
      assert (formal_pending_pc == $past(formal_pending_pc));
      assert (formal_pending_target == $past(formal_pending_target));
    end

    cover (f_past_valid && !o_btb_predicted_taken && (o_btb_predicted_target != '0));
    cover (f_past_valid && i_live_prediction_for_output && o_btb_predicted_taken);
    cover (f_past_valid && formal_pending_valid && o_btb_predicted_taken);
    cover (f_past_valid && formal_pending_valid &&
           i_prediction_used_r && i_pending_prediction_fetch_holdoff &&
           (i_pending_prediction_pc != formal_pending_pc));
    // The motivating raw-WCS predecessor phase opens fetch holdoff on the
    // first pending-active registered-prediction cycle. The non-owner is
    // suppressed while its younger branch packet is captured.
    cover (f_past_valid && i_pending_prediction_active &&
           !i_pending_prediction_fetch_holdoff &&
           (i_output_pc != i_pending_prediction_pc) && !o_btb_hit &&
           !o_btb_predicted_taken);
    // A real non-owner packet may pass while pending metadata remains saved;
    // it must carry no prediction until its exact owner PC arrives.
    cover (f_past_valid && formal_pending_valid &&
           !formal_pending_owner_match &&
           !i_sel_nop && !i_pending_prediction_fetch_holdoff &&
           !o_btb_hit && !o_btb_predicted_taken);
    // Model a self-targeting/RAS-pop collision: raw lookup alignment remains
    // true while registered metadata already owns the packet and its target.
    cover (f_past_valid && i_prediction_used_r &&
           i_live_target_aligned_with_output &&
           !formal_pending_valid &&
           (i_live_predicted_target != i_predicted_target_r) &&
           (o_btb_predicted_target == i_predicted_target_r));
  end

endmodule : prediction_metadata_tracker_formal
