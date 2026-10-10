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
  Sequential next-PC values for pc_controller: the next fetch PC, that PC + 2
  (for the catch-up arm), and the next pc_reg, with how pc_reg and the next
  pc_reg relate to the pending branch PC and to the fetch PC. Every candidate
  increment is added (or related) in parallel before selecting the bundle
  size, for timing.

  pc_reg_precompute keeps its adders separate from the bundle-size mux.
  Compute each result for one-wide, two-wide, and NOP packets, then select
  with slot-2 validity and i_sel_nop. Fetch PC results also apply the
  redirect/reset holdoff at the final selection.
*/
module pc_increment_calculator #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Current PC values (registered outputs from pc_controller)
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,
    // Branch PC of the pending prediction (pc_controller's register)
    input logic [XLEN-1:0] i_pending_prediction_pc,

    input logic i_sel_nop,  // IF emits a NOP: the window may be stale, so its sizes are unreliable

    // Encoded instruction-bundle advance: +2/+4 one-wide, +4/+6/+8 for
    // two-wide bundles (RVC+RVC, RVC+32b / 32b+RVC, 32b+32b). These merged
    // selects feed only the simulation reference.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // The advance selects by bundle shape: for a one-wide bundle (the slot-1
    // size alone), for a two-wide bundle (both sizes), and for a NOP packet.
    // Slot-2 validity and i_sel_nop select the result:
    //   merged = i_sel_nop ? nop : (i_slot2_valid ? two : one).
    // The fetch PC's NOP select equals its one-wide select, so it has no
    // separate port. During stall replay IF drives every select from the
    // same saved value, so the two controls do not matter then.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_one,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_two,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_one,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_two,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,
    input logic i_slot2_valid,

    // Holdoff and control signals
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_control_flow_to_halfword_r,

    // Outputs for final PC mux in pc_controller
    output logic [XLEN-1:0] o_seq_next_pc,  // Sequential PC for fetch
    output logic [XLEN-1:0] o_seq_next_pc_plus_2,
    output logic [XLEN-1:0] o_seq_next_pc_reg,  // Sequential PC for instruction address
    // Precomputed (o_seq_next_pc_reg != i_pc) for pc_controller's
    // pending-prediction decision (see the compare block near the end).
    output logic o_seq_next_pc_reg_neq_pc,
    // How o_seq_next_pc_reg and i_pc_reg relate to the pending branch PC and
    // to i_pc, which pc_controller captures as the branch PC. pc_controller
    // registers pc_reg's relation from these (see the relation block near
    // the end).
    output riscv_pkg::pc_pending_rel_t o_seq_next_pc_reg_rel_pending,
    output riscv_pkg::pc_pending_rel_t o_seq_next_pc_reg_rel_fetch,
    output riscv_pkg::pc_pending_rel_t o_pc_reg_rel_pending,
    output riscv_pkg::pc_pending_rel_t o_pc_reg_rel_fetch
);

  // ===========================================================================
  // PC Increment Selection Signals
  // ===========================================================================
  // Fetch PC increment, in priority order: redirect/reset holdoff, prediction
  // holdoff, control flow to a halfword target, then the bundle advance.
  // pc_controller clears i_any_holdoff_safe while it releases a pending
  // branch's predecessor as a real packet (pending_predecessor_release_wcs0).
  //
  // The two holdoffs treat a halfword PC differently. After a prediction, +2
  // from a halfword PC reaches the next word boundary without letting o_pc get
  // two instructions ahead of pc_reg. After a redirect or reset, +4 is needed
  // even from a halfword PC: +2 leaves the fetch lead too small, and the
  // window for the next word-aligned instruction arrives a cycle late.
  logic pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2;
  assign pc_inc_sel_redirect_holdoff = i_any_holdoff_safe;
  assign pc_inc_sel_prediction_holdoff = !i_any_holdoff_safe && i_prediction_holdoff;
  assign pc_inc_sel_2 = !pc_inc_sel_redirect_holdoff &&
                        !pc_inc_sel_prediction_holdoff &&
                        i_control_flow_to_halfword_r;

  // ===========================================================================
  // Parallel Adders for PC (Fetch Address)
  // ===========================================================================
  // Compute byte increments +2, +4, +6, +8, and +10 (the +2 value after +8)
  // from shared word-index sums.
  localparam int unsigned PcWordBits = XLEN - 2;
  localparam logic [PcWordBits-1:0] PcWordInc1 = {{(PcWordBits - 1) {1'b0}}, 1'b1};
  localparam logic [PcWordBits-1:0] PcWordInc2 = {{(PcWordBits - 2) {1'b0}}, 2'b10};
  localparam logic [PcWordBits-1:0] PcWordInc3 = {{(PcWordBits - 2) {1'b0}}, 2'b11};
  logic [PcWordBits-1:0] pc_word;
  logic [PcWordBits-1:0] pc_word_plus_1;
  logic [PcWordBits-1:0] pc_word_plus_2;
  logic [PcWordBits-1:0] pc_word_plus_3;
  logic                  pc_halfword;
  assign pc_word        = i_pc[XLEN-1:2];
  assign pc_halfword    = i_pc[1];
  assign pc_word_plus_1 = pc_word + PcWordInc1;
  assign pc_word_plus_2 = pc_word + PcWordInc2;
  assign pc_word_plus_3 = pc_word + PcWordInc3;

  logic [XLEN-1:0] next_pc_plus_2, next_pc_plus_4, next_pc_plus_6, next_pc_plus_8;
  logic [XLEN-1:0] next_pc_plus_10;
  assign next_pc_plus_2  = {pc_halfword ? pc_word_plus_1 : pc_word, ~pc_halfword, i_pc[0]};
  assign next_pc_plus_4  = {pc_word_plus_1, pc_halfword, i_pc[0]};
  assign next_pc_plus_6  = {pc_halfword ? pc_word_plus_2 : pc_word_plus_1, ~pc_halfword, i_pc[0]};
  assign next_pc_plus_8  = {pc_word_plus_2, pc_halfword, i_pc[0]};
  assign next_pc_plus_10 = {pc_halfword ? pc_word_plus_3 : pc_word_plus_2, ~pc_halfword, i_pc[0]};

  // Default-case bundle advance. if_stage reduces the predecode metadata to
  // the 2-bit advance selects, so the wide PC muxes here have narrow selects.
  // The fetch PC has two shapes (index 0 one-wide, which is also its NOP
  // select, and index 1 two-wide); pc_reg has three (index 2 is the NOP
  // select).
  localparam int unsigned NFetchShapes = 2;
  localparam int unsigned NRegShapes = 3;
  localparam int unsigned ShapeOne = 0;
  localparam int unsigned ShapeTwo = 1;
  localparam int unsigned ShapeNop = 2;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] fetch_advance_sel_shape[NFetchShapes];
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] reg_advance_sel_shape  [  NRegShapes];
  assign fetch_advance_sel_shape[ShapeOne] = i_pc_fetch_advance_sel_one;
  assign fetch_advance_sel_shape[ShapeTwo] = i_pc_fetch_advance_sel_two;
  assign reg_advance_sel_shape[ShapeOne]   = i_pc_reg_advance_sel_one;
  assign reg_advance_sel_shape[ShapeTwo]   = i_pc_reg_advance_sel_two;
  assign reg_advance_sel_shape[ShapeNop]   = i_pc_reg_advance_sel_nop;

  // ===========================================================================
  // Parallel Adders for PC_reg (Instruction Address)
  // ===========================================================================
  // dont_touch keeps pc_reg_precompute's adders separate from the size mux
  // for timing.
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_compressed;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_32bit;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_6;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_8;

  (* dont_touch = "yes" *) pc_reg_precompute #(
      .XLEN(XLEN)
  ) u_pc_reg_precompute (
      .i_pc_reg              (i_pc_reg),
      .o_pc_reg_if_compressed(pc_reg_if_compressed),
      .o_pc_reg_if_32bit     (pc_reg_if_32bit),
      .o_pc_reg_plus_6       (pc_reg_plus_6),
      .o_pc_reg_plus_8       (pc_reg_plus_8)
  );

  // The only wide muxes that use the pc_reg advance selects, one per bundle
  // shape. Their results feed pc_controller's final priority mux through the
  // shape selection below.
  //
  // Under i_sel_nop the window may be stale (the wrong address after a
  // redirect), so its size bits are unreliable. Outside stall replay, if_stage
  // sets i_pc_reg_advance_sel_nop to +2, which keeps pc_reg from overshooting
  // a pending branch PC.
  //
  // With a valid slot 2, the bundle advance is RVC+RVC = +4
  // (pc_reg_if_32bit), RVC+32b or 32b+RVC = +6, and 32b+32b = +8.
  logic [XLEN-1:0] pc_reg_normal_shape[NRegShapes];
  for (genvar c = 0; c < NRegShapes; c++) begin : gen_pc_reg_advance_shape
    pc_reg_advance_mux #(
        .XLEN(XLEN)
    ) u_pc_reg_advance_mux (
        .i_pc_reg_if_compressed(pc_reg_if_compressed),
        .i_pc_reg_if_32bit(pc_reg_if_32bit),
        .i_pc_reg_plus_6(pc_reg_plus_6),
        .i_pc_reg_plus_8(pc_reg_plus_8),
        .i_advance_sel(reg_advance_sel_shape[c]),
        .o_pc_reg_normal(pc_reg_normal_shape[c])
    );
  end

  // ===========================================================================
  // Final Sequential PC Selection (used by final PC mux in pc_controller)
  // ===========================================================================
  // Select from the precomputed values by holdoff state.
  // i_any_holdoff_safe already includes pc_controller's predecessor release.
  logic seq_sel_holdoff;
  assign seq_sel_holdoff = i_any_holdoff_safe;

  // Apply prediction holdoff and halfword alignment before size selection,
  // preserving this order with keep for timing. The redirect/reset holdoff
  // is applied last. All sums wrap at XLEN bits.
  localparam int unsigned NAdvance = 4;
  logic [XLEN-1:0] fetch_advance_pc[NAdvance];
  logic [XLEN-1:0] fetch_advance_pc_plus_2[NAdvance];
  assign fetch_advance_pc[0] = next_pc_plus_2;
  assign fetch_advance_pc[1] = next_pc_plus_4;
  assign fetch_advance_pc[2] = next_pc_plus_6;
  assign fetch_advance_pc[3] = next_pc_plus_8;
  assign fetch_advance_pc_plus_2[0] = next_pc_plus_4;
  assign fetch_advance_pc_plus_2[1] = next_pc_plus_6;
  assign fetch_advance_pc_plus_2[2] = next_pc_plus_8;
  assign fetch_advance_pc_plus_2[3] = next_pc_plus_10;
  (* keep = "true" *) logic [XLEN-1:0] seq_pc_candidate[NAdvance];
  (* keep = "true" *) logic [XLEN-1:0] seq_pc_plus_2_candidate[NAdvance];
  always_comb begin
    for (int unsigned k = 0; k < NAdvance; k++) begin
      if (i_prediction_holdoff) begin
        seq_pc_candidate[k] = i_pc[1] ? next_pc_plus_2 : next_pc_plus_4;
        seq_pc_plus_2_candidate[k] = i_pc[1] ? next_pc_plus_4 : next_pc_plus_6;
      end else if (i_control_flow_to_halfword_r) begin
        seq_pc_candidate[k] = next_pc_plus_2;
        seq_pc_plus_2_candidate[k] = next_pc_plus_4;
      end else begin
        seq_pc_candidate[k] = fetch_advance_pc[k];
        seq_pc_plus_2_candidate[k] = fetch_advance_pc_plus_2[k];
      end
    end
  end

  // The size selection per bundle shape.
  (* keep = "true" *) logic [XLEN-1:0] seq_next_pc_shape[NFetchShapes];
  (* keep = "true" *) logic [XLEN-1:0] seq_next_pc_plus_2_shape[NFetchShapes];
  always_comb begin
    for (int unsigned c = 0; c < NFetchShapes; c++) begin
      unique case (fetch_advance_sel_shape[c])
        riscv_pkg::PcAdvancePlus4: begin
          seq_next_pc_shape[c] = seq_pc_candidate[1];
          seq_next_pc_plus_2_shape[c] = seq_pc_plus_2_candidate[1];
        end
        riscv_pkg::PcAdvancePlus6: begin
          seq_next_pc_shape[c] = seq_pc_candidate[2];
          seq_next_pc_plus_2_shape[c] = seq_pc_plus_2_candidate[2];
        end
        riscv_pkg::PcAdvancePlus8: begin
          seq_next_pc_shape[c] = seq_pc_candidate[3];
          seq_next_pc_plus_2_shape[c] = seq_pc_plus_2_candidate[3];
        end
        default: begin
          seq_next_pc_shape[c] = seq_pc_candidate[0];
          seq_next_pc_plus_2_shape[c] = seq_pc_plus_2_candidate[0];
        end
      endcase
    end
  end

  // Fetch uses the two-wide result only for a real pair; NOPs use the
  // one-wide result. Redirect/reset holdoff overrides both.
  (* keep = "true" *) logic fetch_two_wide;
  assign fetch_two_wide = !i_sel_nop && i_slot2_valid;
  assign o_seq_next_pc = i_any_holdoff_safe ? next_pc_plus_4 :
      fetch_two_wide ? seq_next_pc_shape[ShapeTwo] : seq_next_pc_shape[ShapeOne];
  assign o_seq_next_pc_plus_2 = i_any_holdoff_safe ? next_pc_plus_6 :
      fetch_two_wide ? seq_next_pc_plus_2_shape[ShapeTwo] : seq_next_pc_plus_2_shape[ShapeOne];

  // pc_reg holds on holdoff, advances by the NOP shape for a bubble, and
  // otherwise uses the selected bundle size.
  (* keep = "true" *) logic [XLEN-1:0] seq_next_pc_reg_hold_or_nop;
  (* keep = "true" *) logic seq_next_pc_reg_hold_or_nop_sel;
  assign seq_next_pc_reg_hold_or_nop = seq_sel_holdoff ? i_pc_reg : pc_reg_normal_shape[ShapeNop];
  assign seq_next_pc_reg_hold_or_nop_sel = seq_sel_holdoff || i_sel_nop;
  assign o_seq_next_pc_reg = seq_next_pc_reg_hold_or_nop_sel ? seq_next_pc_reg_hold_or_nop :
      i_slot2_valid ? pc_reg_normal_shape[ShapeTwo] : pc_reg_normal_shape[ShapeOne];

`ifdef PC_INCREMENT_HOLDOFF_PROOF
  // Compare with holdoff applied inside each size candidate, allowing
  // arbitrary shape selects and controls.
  logic [XLEN-1:0] f_seq_candidate[NAdvance], f_seq_plus_2_candidate[NAdvance];
  logic [XLEN-1:0] f_seq_result[NFetchShapes], f_seq_plus_2_result[NFetchShapes];
  always_comb begin
    for (int unsigned k = 0; k < NAdvance; k++) begin
      if (seq_sel_holdoff) begin
        f_seq_candidate[k] = next_pc_plus_4;
        f_seq_plus_2_candidate[k] = next_pc_plus_6;
      end else if (pc_inc_sel_prediction_holdoff) begin
        f_seq_candidate[k] = i_pc[1] ? next_pc_plus_2 : next_pc_plus_4;
        f_seq_plus_2_candidate[k] = i_pc[1] ? next_pc_plus_4 : next_pc_plus_6;
      end else if (pc_inc_sel_2) begin
        f_seq_candidate[k] = next_pc_plus_2;
        f_seq_plus_2_candidate[k] = next_pc_plus_4;
      end else begin
        f_seq_candidate[k] = fetch_advance_pc[k];
        f_seq_plus_2_candidate[k] = fetch_advance_pc_plus_2[k];
      end
    end
  end

  always_comb begin
    for (int c = 0; c < NFetchShapes; c++) begin
      case (fetch_advance_sel_shape[c])
        riscv_pkg::PcAdvancePlus4: begin
          f_seq_result[c] = f_seq_candidate[1];
          f_seq_plus_2_result[c] = f_seq_plus_2_candidate[1];
        end
        riscv_pkg::PcAdvancePlus6: begin
          f_seq_result[c] = f_seq_candidate[2];
          f_seq_plus_2_result[c] = f_seq_plus_2_candidate[2];
        end
        riscv_pkg::PcAdvancePlus8: begin
          f_seq_result[c] = f_seq_candidate[3];
          f_seq_plus_2_result[c] = f_seq_plus_2_candidate[3];
        end
        default: begin
          f_seq_result[c] = f_seq_candidate[0];
          f_seq_plus_2_result[c] = f_seq_plus_2_candidate[0];
        end
      endcase
    end
    assert (o_seq_next_pc == (fetch_two_wide ? f_seq_result[ShapeTwo] : f_seq_result[ShapeOne]));
    assert (o_seq_next_pc_plus_2 ==
            (fetch_two_wide ? f_seq_plus_2_result[ShapeTwo] : f_seq_plus_2_result[ShapeOne]));
  end
`endif

`ifndef SYNTHESIS
  // Reference: a single selection chain steered by the merged selects.
  logic [XLEN-1:0] fetch_seq_next_pc_ref, fetch_seq_next_pc_plus_2_ref;
  logic [XLEN-1:0] next_sequential_pc_ref, seq_next_pc_ref, seq_next_pc_reg_ref;
  logic [XLEN-1:0] next_sequential_pc_plus_2_ref, seq_next_pc_plus_2_ref;
  logic [XLEN-1:0] pc_reg_normal_ref;
  pc_fetch_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_fetch_advance_mux_ref (
      .i_next_pc_plus_2(next_pc_plus_2),
      .i_next_pc_plus_4(next_pc_plus_4),
      .i_next_pc_plus_6(next_pc_plus_6),
      .i_next_pc_plus_8(next_pc_plus_8),
      .i_next_pc_plus_10(next_pc_plus_10),
      .i_advance_sel(i_pc_fetch_advance_sel),
      .o_fetch_seq_next_pc(fetch_seq_next_pc_ref),
      .o_fetch_seq_next_pc_plus_2(fetch_seq_next_pc_plus_2_ref)
  );
  pc_reg_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_reg_advance_mux_ref (
      .i_pc_reg_if_compressed(pc_reg_if_compressed),
      .i_pc_reg_if_32bit(pc_reg_if_32bit),
      .i_pc_reg_plus_6(pc_reg_plus_6),
      .i_pc_reg_plus_8(pc_reg_plus_8),
      .i_advance_sel(i_pc_reg_advance_sel),
      .o_pc_reg_normal(pc_reg_normal_ref)
  );
  always_comb begin
    casez ({
      pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2
    })
      3'b1??:  next_sequential_pc_ref = next_pc_plus_4;
      3'b01?:  next_sequential_pc_ref = !i_pc[1] ? next_pc_plus_4 : next_pc_plus_2;
      3'b001:  next_sequential_pc_ref = next_pc_plus_2;
      default: next_sequential_pc_ref = fetch_seq_next_pc_ref;
    endcase
    casez ({
      pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2
    })
      3'b1??:  next_sequential_pc_plus_2_ref = next_pc_plus_6;
      3'b01?:  next_sequential_pc_plus_2_ref = !i_pc[1] ? next_pc_plus_6 : next_pc_plus_4;
      3'b001:  next_sequential_pc_plus_2_ref = next_pc_plus_4;
      default: next_sequential_pc_plus_2_ref = fetch_seq_next_pc_plus_2_ref;
    endcase
    seq_next_pc_plus_2_ref = next_sequential_pc_plus_2_ref;
    seq_next_pc_ref = next_sequential_pc_ref;
    if (seq_sel_holdoff) seq_next_pc_reg_ref = i_pc_reg;
    else seq_next_pc_reg_ref = pc_reg_normal_ref;
    if (!$isunknown(
            {
              i_sel_nop,
              i_slot2_valid,
              i_pc_fetch_advance_sel,
              i_pc_fetch_advance_sel_one,
              i_pc_fetch_advance_sel_two,
              i_pc_reg_advance_sel,
              i_pc_reg_advance_sel_one,
              i_pc_reg_advance_sel_two,
              i_pc_reg_advance_sel_nop
            }
        )) begin
      // The shape selects agree with the merged selects ...
      p_advance_sel_shapes_exact :
      assert ((i_pc_fetch_advance_sel ==
               (i_sel_nop ? i_pc_fetch_advance_sel_one :
                i_slot2_valid ? i_pc_fetch_advance_sel_two : i_pc_fetch_advance_sel_one)) &&
              (i_pc_reg_advance_sel ==
               (i_sel_nop ? i_pc_reg_advance_sel_nop :
                i_slot2_valid ? i_pc_reg_advance_sel_two : i_pc_reg_advance_sel_one)));
      // ... and the split selection equals the reference every cycle.
      p_seq_next_pc_split_exact :
      assert ((o_seq_next_pc == seq_next_pc_ref) &&
              (o_seq_next_pc_plus_2 == seq_next_pc_plus_2_ref) &&
              (o_seq_next_pc_reg == seq_next_pc_reg_ref));
    end
  end
`endif

  // ===========================================================================
  // Precomputed (o_seq_next_pc_reg != i_pc): compare-then-mux form
  // ===========================================================================
  // pc_controller needs (o_seq_next_pc_reg != i_pc) for pending predictions.
  // Compare each candidate before selecting, for timing. These arms must
  // mirror o_seq_next_pc_reg, including the default +2 increment.
  logic neq_hold, neq_plus2, neq_plus4, neq_plus6, neq_plus8;
  logic neq_advance_sel;
  assign neq_hold = (i_pc_reg != i_pc);
  // For candidate A == base B + constant K, carry into bit i is
  // A[i] ^ B[i] ^ K[i]. The preceding carry out can be reconstructed
  // locally from A/B: K[i-1] ? (B[i-1] | ~A[i-1]) :
  //                             (B[i-1] & ~A[i-1]).
  // For K in {2,4,6,8}, every relationship at bit 5 or above is shared.
  // Discarding the final carry preserves modulo-XLEN arithmetic.
  if (XLEN > 5) begin : gen_increment_relation
    localparam int HighBits = XLEN - 5;
    localparam int ChunkBits = 12;
    localparam int Chunks = (HighBits + ChunkBits - 1) / ChunkBits;
    wire  [  XLEN-1:0] difference = i_pc ^ i_pc_reg;
    wire  [  XLEN-1:0] zero_bit_carry = i_pc_reg & ~i_pc;
    (* keep = "true" *)logic [Chunks-1:0] high_matches;
    for (genvar g = 0; g < Chunks; g++) begin : gen_match
      localparam int First = 5 + g * ChunkBits;
      localparam int Width = (XLEN - First < ChunkBits) ? XLEN - First : ChunkBits;
      assign high_matches[g] = difference[First+:Width] == zero_bit_carry[First-1+:Width];
    end
    function automatic logic low_match(input logic [4:0] increment);
      logic [3:0] reconstructed_carry;
      reconstructed_carry = (i_pc_reg[3:0] & ~i_pc[3:0]) |
          (increment[3:0] & (i_pc_reg[3:0] | ~i_pc[3:0]));
      low_match = ((difference[4:0] ^ increment) == {reconstructed_carry, 1'b0});
    endfunction
    assign neq_plus2 = !((&high_matches) && low_match(5'd2));
    assign neq_plus4 = !((&high_matches) && low_match(5'd4));
    assign neq_plus6 = !((&high_matches) && low_match(5'd6));
    assign neq_plus8 = !((&high_matches) && low_match(5'd8));
  end else begin : gen_small_increment_reference
    assign neq_plus2 = (pc_reg_if_compressed != i_pc);
    assign neq_plus4 = (pc_reg_if_32bit != i_pc);
    assign neq_plus6 = (pc_reg_plus_6 != i_pc);
    assign neq_plus8 = (pc_reg_plus_8 != i_pc);
  end
  // Split by bundle shape as for o_seq_next_pc_reg: the late controls pick
  // last.
  logic neq_advance_sel_shape[NRegShapes];
  always_comb begin
    for (int unsigned c = 0; c < NRegShapes; c++) begin
      unique case (reg_advance_sel_shape[c])
        riscv_pkg::PcAdvancePlus2: neq_advance_sel_shape[c] = neq_plus2;
        riscv_pkg::PcAdvancePlus4: neq_advance_sel_shape[c] = neq_plus4;
        riscv_pkg::PcAdvancePlus6: neq_advance_sel_shape[c] = neq_plus6;
        riscv_pkg::PcAdvancePlus8: neq_advance_sel_shape[c] = neq_plus8;
        default:                   neq_advance_sel_shape[c] = neq_plus2;
      endcase
    end
    neq_advance_sel = i_sel_nop ? neq_advance_sel_shape[ShapeNop] :
        i_slot2_valid ? neq_advance_sel_shape[ShapeTwo] : neq_advance_sel_shape[ShapeOne];
  end
  always_comb begin
    if (seq_sel_holdoff) o_seq_next_pc_reg_neq_pc = neq_hold;
    else o_seq_next_pc_reg_neq_pc = neq_advance_sel;
  end

  // ===========================================================================
  // Precomputed relations to the pending branch PC and to i_pc
  // ===========================================================================
  // pc_controller registers pc_reg's relation to the pending branch PC from
  // these, which keeps its wide compares out of the PC loop. Relate each
  // pc_reg candidate i_pc_reg + 2a (a = 0 for the hold, 1..4 for the +2..+8
  // advances) to both PCs, then select with the same controls as
  // o_seq_next_pc_reg.
  localparam int unsigned NRelAdvances = 5;
  logic [NRelAdvances-1:0] pc_reg_hw_wraps;
  assign pc_reg_hw_wraps[0] = 1'b0;
  for (genvar a = 1; a < NRelAdvances; a++) begin : gen_pc_reg_hw_wrap
    localparam logic [XLEN-2:0] HwLimit = {(XLEN - 1) {1'b1}} - a;
    assign pc_reg_hw_wraps[a] = i_pc_reg[XLEN-1:1] > HwLimit;
  end
  logic [NRelAdvances-1:0] rel_pending_at, rel_pending_below, rel_pending_above;
  logic [NRelAdvances-1:0] rel_pending_pred, rel_pending_pred_native;
  logic [NRelAdvances-1:0] rel_fetch_at, rel_fetch_below, rel_fetch_above;
  logic [NRelAdvances-1:0] rel_fetch_pred, rel_fetch_pred_native;
  pc_pending_relation #(
      .XLEN(XLEN)
  ) u_rel_pending (
      .i_pc_reg,
      .i_side_pc(i_pending_prediction_pc),
      .i_pc_reg_hw_wraps(pc_reg_hw_wraps),
      .o_at(rel_pending_at),
      .o_below(rel_pending_below),
      .o_above(rel_pending_above),
      .o_pred(rel_pending_pred),
      .o_pred_native(rel_pending_pred_native)
  );
  pc_pending_relation #(
      .XLEN(XLEN)
  ) u_rel_fetch (
      .i_pc_reg,
      .i_side_pc(i_pc),
      .i_pc_reg_hw_wraps(pc_reg_hw_wraps),
      .o_at(rel_fetch_at),
      .o_below(rel_fetch_below),
      .o_above(rel_fetch_above),
      .o_pred(rel_fetch_pred),
      .o_pred_native(rel_fetch_pred_native)
  );
  logic [4:0] rel_pending_by_advance[NRelAdvances];
  logic [4:0] rel_fetch_by_advance  [NRelAdvances];
  for (genvar a = 0; a < NRelAdvances; a++) begin : gen_rel_by_advance
    // Field order of riscv_pkg::pc_pending_rel_t.
    assign rel_pending_by_advance[a] = {
      rel_pending_at[a],
      rel_pending_below[a],
      rel_pending_above[a],
      rel_pending_pred[a],
      rel_pending_pred_native[a]
    };
    assign rel_fetch_by_advance[a] = {
      rel_fetch_at[a],
      rel_fetch_below[a],
      rel_fetch_above[a],
      rel_fetch_pred[a],
      rel_fetch_pred_native[a]
    };
  end
  logic [4:0] rel_pending_shape[NRegShapes];
  logic [4:0] rel_fetch_shape  [NRegShapes];
  always_comb begin
    for (int unsigned c = 0; c < NRegShapes; c++) begin
      unique case (reg_advance_sel_shape[c])
        riscv_pkg::PcAdvancePlus4: begin
          rel_pending_shape[c] = rel_pending_by_advance[2];
          rel_fetch_shape[c]   = rel_fetch_by_advance[2];
        end
        riscv_pkg::PcAdvancePlus6: begin
          rel_pending_shape[c] = rel_pending_by_advance[3];
          rel_fetch_shape[c]   = rel_fetch_by_advance[3];
        end
        riscv_pkg::PcAdvancePlus8: begin
          rel_pending_shape[c] = rel_pending_by_advance[4];
          rel_fetch_shape[c]   = rel_fetch_by_advance[4];
        end
        default: begin
          rel_pending_shape[c] = rel_pending_by_advance[1];
          rel_fetch_shape[c]   = rel_fetch_by_advance[1];
        end
      endcase
    end
  end
  always_comb begin
    if (seq_sel_holdoff) begin
      o_seq_next_pc_reg_rel_pending = rel_pending_by_advance[0];
      o_seq_next_pc_reg_rel_fetch   = rel_fetch_by_advance[0];
    end else if (i_sel_nop) begin
      o_seq_next_pc_reg_rel_pending = rel_pending_shape[ShapeNop];
      o_seq_next_pc_reg_rel_fetch   = rel_fetch_shape[ShapeNop];
    end else if (i_slot2_valid) begin
      o_seq_next_pc_reg_rel_pending = rel_pending_shape[ShapeTwo];
      o_seq_next_pc_reg_rel_fetch   = rel_fetch_shape[ShapeTwo];
    end else begin
      o_seq_next_pc_reg_rel_pending = rel_pending_shape[ShapeOne];
      o_seq_next_pc_reg_rel_fetch   = rel_fetch_shape[ShapeOne];
    end
  end
  assign o_pc_reg_rel_pending = rel_pending_by_advance[0];
  assign o_pc_reg_rel_fetch   = rel_fetch_by_advance[0];

  // Reference relation of v to the branch PC side (see pc_pending_rel_t).
  function automatic logic [4:0] pending_rel_reference(input logic [XLEN-1:0] v,
                                                       input logic [XLEN-1:0] side);
    pending_rel_reference = {
      v == side,
      v[XLEN-1:1] < side[XLEN-1:1],
      v[XLEN-1:1] > side[XLEN-1:1],
      v == XLEN'(side - XLEN'(2)),
      v == XLEN'(side - XLEN'(4))
    };
  endfunction

`ifndef SYNTHESIS
  // The 1-bit precompute must track the wide compare exactly.
  always_comb begin
    if (o_seq_next_pc_reg_neq_pc !== (o_seq_next_pc_reg != i_pc)) begin
      $error("pc_increment_calculator: o_seq_next_pc_reg_neq_pc mismatch");
    end
    if (!$isunknown(
            {o_seq_next_pc_reg, i_pc_reg, i_pc, i_pending_prediction_pc}
        ) && ((o_seq_next_pc_reg_rel_pending !== pending_rel_reference(
            o_seq_next_pc_reg, i_pending_prediction_pc
        )) || (o_seq_next_pc_reg_rel_fetch !== pending_rel_reference(
            o_seq_next_pc_reg, i_pc
        )) || (o_pc_reg_rel_pending !== pending_rel_reference(
            i_pc_reg, i_pending_prediction_pc
        )) || (o_pc_reg_rel_fetch !== pending_rel_reference(
            i_pc_reg, i_pc
        )))) begin
      $error("pc_increment_calculator: pending-PC relation mismatch");
    end
  end
`endif

`ifdef PC_INCREMENT_RELATION_PROOF
  always_comb begin
    assert (neq_plus2 == (pc_reg_if_compressed != i_pc));
    assert (neq_plus4 == (pc_reg_if_32bit != i_pc));
    assert (neq_plus6 == (pc_reg_plus_6 != i_pc));
    assert (neq_plus8 == (pc_reg_plus_8 != i_pc));
    assert (o_seq_next_pc_reg_neq_pc == (o_seq_next_pc_reg != i_pc));
    assert (o_seq_next_pc_reg_rel_pending == pending_rel_reference(
        o_seq_next_pc_reg, i_pending_prediction_pc
    ));
    assert (o_seq_next_pc_reg_rel_fetch == pending_rel_reference(o_seq_next_pc_reg, i_pc));
    assert (o_pc_reg_rel_pending == pending_rel_reference(i_pc_reg, i_pending_prediction_pc));
    assert (o_pc_reg_rel_fetch == pending_rel_reference(i_pc_reg, i_pc));
  end
`endif
endmodule : pc_increment_calculator

// How i_pc_reg + 2a relates to i_side_pc for a = 0..4 (see
// riscv_pkg::pc_pending_rel_t), without adders. With
// aligned = {i_side_pc[XLEN-1:1], i_pc_reg[0]}, aligned == i_pc_reg + 2k
// exactly when the halfword parts differ by k, and the carry relation of
// pc_increment_calculator's compare checks that. Then i_pc_reg + 2a equals
// i_side_pc, i_side_pc - 2, and i_side_pc - 4 at k = a, a + 1, and a + 2
// (with equal bit 0). For the halfword order, let D = side - pc_reg on the
// halfword parts, modulo 2^(XLEN-1), and D > a the absence of D == 0..a.
// The advance is below the side PC when the subtraction does not borrow and
// D > a; if the advance wraps, when either holds.
module pc_pending_relation #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc_reg,
    input logic [XLEN-1:0] i_side_pc,
    // i_pc_reg[XLEN-1:1] + a overflows, by advance a.
    input logic [4:0] i_pc_reg_hw_wraps,
    // One bit per advance a, as the pc_pending_rel_t fields.
    output logic [4:0] o_at,
    output logic [4:0] o_below,
    output logic [4:0] o_above,
    output logic [4:0] o_pred,
    output logic [4:0] o_pred_native
);

  localparam int unsigned NEq = 7;  // k = a + 2 for a = 4
  logic [NEq-1:0] hw_eq;  // aligned == i_pc_reg + 2k
  logic bit0_eq, borrow;
  assign bit0_eq = i_side_pc[0] == i_pc_reg[0];
  assign borrow  = i_side_pc[XLEN-1:1] < i_pc_reg[XLEN-1:1];

  if (XLEN > 5) begin : gen_carry_relation
    localparam int HighBits = XLEN - 5;
    localparam int ChunkBits = 12;
    localparam int Chunks = (HighBits + ChunkBits - 1) / ChunkBits;
    wire  [  XLEN-1:0] aligned = {i_side_pc[XLEN-1:1], i_pc_reg[0]};
    wire  [  XLEN-1:0] difference = aligned ^ i_pc_reg;
    wire  [  XLEN-1:0] zero_bit_carry = i_pc_reg & ~aligned;
    logic [Chunks-1:0] high_matches;
    for (genvar g = 0; g < Chunks; g++) begin : gen_match
      localparam int First = 5 + g * ChunkBits;
      localparam int Width = (XLEN - First < ChunkBits) ? XLEN - First : ChunkBits;
      assign high_matches[g] = difference[First+:Width] == zero_bit_carry[First-1+:Width];
    end
    for (genvar k = 0; k < NEq; k++) begin : gen_eq
      localparam logic [4:0] Increment = 5'(2 * k);
      logic [3:0] carry;
      assign carry = zero_bit_carry[3:0] | (Increment[3:0] & (i_pc_reg[3:0] | ~aligned[3:0]));
      assign hw_eq[k] = (&high_matches) && ((difference[4:0] ^ Increment) == {carry, 1'b0});
    end
  end else begin : gen_small_reference
    for (genvar k = 0; k < NEq; k++) begin : gen_eq
      assign hw_eq[k] = {i_side_pc[XLEN-1:1], i_pc_reg[0]} == XLEN'(i_pc_reg + XLEN'(2 * k));
    end
  end

  for (genvar a = 0; a < 5; a++) begin : gen_advance
    logic exceeds;  // D > a
    assign exceeds = !(|hw_eq[a:0]);
    assign o_at[a] = hw_eq[a] && bit0_eq;
    assign o_pred[a] = hw_eq[a+1] && bit0_eq;
    assign o_pred_native[a] = hw_eq[a+2] && bit0_eq;
    assign o_below[a] = i_pc_reg_hw_wraps[a] ? (!borrow || exceeds) : (!borrow && exceeds);
    assign o_above[a] = !o_below[a] && !hw_eq[a];
  end

endmodule : pc_pending_relation

// The next fetch PC and that PC + 2 for an advance select.
module pc_fetch_advance_mux #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_next_pc_plus_2,
    input logic [XLEN-1:0] i_next_pc_plus_4,
    input logic [XLEN-1:0] i_next_pc_plus_6,
    input logic [XLEN-1:0] i_next_pc_plus_8,
    input logic [XLEN-1:0] i_next_pc_plus_10,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_advance_sel,
    output logic [XLEN-1:0] o_fetch_seq_next_pc,
    output logic [XLEN-1:0] o_fetch_seq_next_pc_plus_2
);

  always_comb begin
    unique case (i_advance_sel)
      riscv_pkg::PcAdvancePlus2: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_2;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_4;
      end
      riscv_pkg::PcAdvancePlus4: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_4;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_6;
      end
      riscv_pkg::PcAdvancePlus6: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_6;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_8;
      end
      riscv_pkg::PcAdvancePlus8: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_8;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_10;
      end
      default: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_2;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_4;
      end
    endcase
  end

endmodule : pc_fetch_advance_mux

// The next pc_reg for an advance select.
module pc_reg_advance_mux #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc_reg_if_compressed,
    input logic [XLEN-1:0] i_pc_reg_if_32bit,
    input logic [XLEN-1:0] i_pc_reg_plus_6,
    input logic [XLEN-1:0] i_pc_reg_plus_8,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_advance_sel,
    output logic [XLEN-1:0] o_pc_reg_normal
);

  always_comb begin
    unique case (i_advance_sel)
      riscv_pkg::PcAdvancePlus2: o_pc_reg_normal = i_pc_reg_if_compressed;
      riscv_pkg::PcAdvancePlus4: o_pc_reg_normal = i_pc_reg_if_32bit;
      riscv_pkg::PcAdvancePlus6: o_pc_reg_normal = i_pc_reg_plus_6;
      riscv_pkg::PcAdvancePlus8: o_pc_reg_normal = i_pc_reg_plus_8;
      default:                   o_pc_reg_normal = i_pc_reg_if_compressed;
    endcase
  end

endmodule : pc_reg_advance_mux
