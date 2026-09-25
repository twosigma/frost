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
  (for the catch-up arm), and the next pc_reg. Every candidate increment is
  added in parallel and the late size selects come after the adders:
  Instead of:  next_pc = pc + mux(select, 0, 2, 4)  [select→mux→CARRY8]
  We do:       next_pc = mux(select, pc+2, pc+4)  [CARRY8 in parallel, then mux]

  The pc_reg sums come from pc_reg_precompute, a separate module that keeps
  its adders apart from the bundle-size mux. The fetch candidates apply the
  prediction-holdoff and halfword-target choices before the bundle-size mux.
  Each result is computed for both values of i_sel_nop, which picks last. For
  the fetch PC and fetch PC + 2, the redirect/reset holdoff, also a late
  input, joins that final pick.
*/
module pc_increment_calculator #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Current PC values (registered outputs from pc_controller)
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,

    input logic i_sel_nop,  // IF emits a NOP: the window may be stale, so its sizes are unreliable

    // Encoded instruction-bundle advance: +2/+4 one-wide, +4/+6/+8 for
    // two-wide bundles (RVC+RVC, RVC+32b / 32b+RVC, 32b+32b).
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // The two selects above for i_sel_nop = 0 ("run") and i_sel_nop = 1
    // ("nop"). Every candidate mux below is built for both, and i_sel_nop, the
    // latest control in the front end, picks between the finished results
    // last. The merged selects above feed only the simulation reference.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,

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
    output logic o_seq_next_pc_reg_neq_pc
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
  // The one-wide +2/+4, the two-wide +6/+8, and +10 (the +2 value after +8).
  // Build these from the word index so pc[1] selects between precomputed
  // word increments instead of feeding the full carry chain.
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
  // Index 0 is i_sel_nop = 0 ("run"), index 1 is i_sel_nop = 1 ("nop").
  localparam int unsigned NCof = 2;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] fetch_advance_sel_cof[NCof];
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] reg_advance_sel_cof  [NCof];
  assign fetch_advance_sel_cof[0] = i_pc_fetch_advance_sel_run;
  assign fetch_advance_sel_cof[1] = i_pc_fetch_advance_sel_nop;
  assign reg_advance_sel_cof[0]   = i_pc_reg_advance_sel_run;
  assign reg_advance_sel_cof[1]   = i_pc_reg_advance_sel_nop;

  // ===========================================================================
  // Parallel Adders for PC_reg (Instruction Address)
  // ===========================================================================
  // pc_reg + 2/4/6/8 come from the registered i_pc_reg alone and settle well
  // before the fetch window arrives, so the late bundle-advance select drives
  // only the 4:1 mux after them and never reaches the CARRY8 chains. The
  // dont_touch instance keeps the adders in pc_reg_precompute, apart from
  // that mux (see pc_reg_precompute).
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

  // The only wide mux that uses the late pc_reg advance select. Its result
  // feeds pc_controller's final priority mux.
  //
  // Under i_sel_nop the window may be stale (the wrong address after a
  // redirect), so its size bits are unreliable. Outside stall replay, if_stage
  // sets i_pc_reg_advance_sel_nop to +2, which keeps pc_reg from overshooting
  // a pending branch PC.
  //
  // With a valid slot 2, the bundle advance is RVC+RVC = +4
  // (pc_reg_if_32bit), RVC+32b or 32b+RVC = +6, and 32b+32b = +8.
  logic [XLEN-1:0] pc_reg_normal_cof[NCof];
  for (genvar c = 0; c < NCof; c++) begin : gen_pc_reg_advance_cof
    pc_reg_advance_mux #(
        .XLEN(XLEN)
    ) u_pc_reg_advance_mux (
        .i_pc_reg_if_compressed(pc_reg_if_compressed),
        .i_pc_reg_if_32bit(pc_reg_if_32bit),
        .i_pc_reg_plus_6(pc_reg_plus_6),
        .i_pc_reg_plus_8(pc_reg_plus_8),
        .i_advance_sel(reg_advance_sel_cof[c]),
        .o_pc_reg_normal(pc_reg_normal_cof[c])
    );
  end

  // ===========================================================================
  // Final Sequential PC Selection (used by final PC mux in pc_controller)
  // ===========================================================================
  // Select from the precomputed values by holdoff state.
  // i_any_holdoff_safe already includes pc_controller's predecessor release.
  logic seq_sel_holdoff;
  assign seq_sel_holdoff = i_any_holdoff_safe;

  // For each bundle size, apply the prediction-holdoff and halfword-target
  // choices first, without the redirect/reset holdoff. The advance mux then
  // picks a finished value, and the holdoff joins i_sel_nop only at the final
  // selection. The keep attributes stop synthesis from moving the holdoff
  // muxes after the size selection. Both values of a pair reuse the existing
  // fixed-increment adders, including their wraparound at XLEN bits.
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

  (* keep = "true" *) logic [XLEN-1:0] seq_next_pc_cof[NCof];
  (* keep = "true" *) logic [XLEN-1:0] seq_next_pc_plus_2_cof[NCof];
  logic [XLEN-1:0] seq_next_pc_reg_cof[NCof];
  always_comb begin
    for (int unsigned c = 0; c < NCof; c++) begin
      unique case (fetch_advance_sel_cof[c])
        riscv_pkg::PcAdvancePlus4: begin
          seq_next_pc_cof[c] = seq_pc_candidate[1];
          seq_next_pc_plus_2_cof[c] = seq_pc_plus_2_candidate[1];
        end
        riscv_pkg::PcAdvancePlus6: begin
          seq_next_pc_cof[c] = seq_pc_candidate[2];
          seq_next_pc_plus_2_cof[c] = seq_pc_plus_2_candidate[2];
        end
        riscv_pkg::PcAdvancePlus8: begin
          seq_next_pc_cof[c] = seq_pc_candidate[3];
          seq_next_pc_plus_2_cof[c] = seq_pc_plus_2_candidate[3];
        end
        default: begin
          seq_next_pc_cof[c] = seq_pc_candidate[0];
          seq_next_pc_plus_2_cof[c] = seq_pc_plus_2_candidate[0];
        end
      endcase
      if (seq_sel_holdoff) seq_next_pc_reg_cof[c] = i_pc_reg;
      else seq_next_pc_reg_cof[c] = pc_reg_normal_cof[c];
    end
  end

  // The predecessor release makes i_any_holdoff_safe a late input too, so it
  // is applied with i_sel_nop after both size results settle. Each bit uses
  // the holdoff, i_sel_nop, and three finished data bits (one LUT5).
  assign o_seq_next_pc = i_any_holdoff_safe ? next_pc_plus_4 :
      i_sel_nop ? seq_next_pc_cof[1] : seq_next_pc_cof[0];
  assign o_seq_next_pc_plus_2 = i_any_holdoff_safe ? next_pc_plus_6 :
      i_sel_nop ? seq_next_pc_plus_2_cof[1] : seq_next_pc_plus_2_cof[0];
  assign o_seq_next_pc_reg = i_sel_nop ? seq_next_pc_reg_cof[1] : seq_next_pc_reg_cof[0];

`ifdef PC_INCREMENT_HOLDOFF_PROOF
  // Reference for the pc_increment_holdoff formal target: the holdoff applied
  // inside each size candidate, then the same size and i_sel_nop selection,
  // with every input free (including the run and nop selects).
  logic [XLEN-1:0] f_seq_candidate[NAdvance], f_seq_plus_2_candidate[NAdvance];
  logic [XLEN-1:0] f_seq_result[NCof], f_seq_plus_2_result[NCof];
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
    for (int c = 0; c < NCof; c++) begin
      case (fetch_advance_sel_cof[c])
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
    assert (o_seq_next_pc == (i_sel_nop ? f_seq_result[1] : f_seq_result[0]));
    assert (o_seq_next_pc_plus_2 == (i_sel_nop ? f_seq_plus_2_result[1] : f_seq_plus_2_result[0]));
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
              i_pc_fetch_advance_sel,
              i_pc_fetch_advance_sel_run,
              i_pc_fetch_advance_sel_nop,
              i_pc_reg_advance_sel,
              i_pc_reg_advance_sel_run,
              i_pc_reg_advance_sel_nop
            }
        )) begin
      // The run and nop selects agree with the merged selects ...
      p_advance_sel_cofactors_exact :
      assert ((i_pc_fetch_advance_sel ==
               (i_sel_nop ? i_pc_fetch_advance_sel_nop : i_pc_fetch_advance_sel_run)) &&
              (i_pc_reg_advance_sel ==
               (i_sel_nop ? i_pc_reg_advance_sel_nop : i_pc_reg_advance_sel_run)));
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
  // pc_controller's pending-prediction decision needs the full-width
  // compare of the next pc_reg with the fetch PC (see
  // pc_reg_next_misses_fetch_pc_for_prediction there). Comparing the muxed
  // value would put the wide compare after the late advance select, so each
  // candidate is compared instead. Every operand comes from a register (i_pc,
  // i_pc_reg, and the precomputed sums), so the five compares run in parallel
  // and the late selects pick among 1-bit results. The arms below mirror the
  // o_seq_next_pc_reg selection arm for arm, including pc_reg_advance_mux's
  // default to the +2 candidate, so the result equals
  // (o_seq_next_pc_reg != i_pc) exactly.
  logic neq_hold, neq_plus2, neq_plus4, neq_plus6, neq_plus8;
  logic neq_advance_sel;
  assign neq_hold  = (i_pc_reg != i_pc);
  assign neq_plus2 = (pc_reg_if_compressed != i_pc);
  assign neq_plus4 = (pc_reg_if_32bit != i_pc);
  assign neq_plus6 = (pc_reg_plus_6 != i_pc);
  assign neq_plus8 = (pc_reg_plus_8 != i_pc);
  // Split by i_sel_nop as for o_seq_next_pc_reg: i_sel_nop picks last.
  logic neq_advance_sel_cof[NCof];
  always_comb begin
    for (int unsigned c = 0; c < NCof; c++) begin
      unique case (reg_advance_sel_cof[c])
        riscv_pkg::PcAdvancePlus2: neq_advance_sel_cof[c] = neq_plus2;
        riscv_pkg::PcAdvancePlus4: neq_advance_sel_cof[c] = neq_plus4;
        riscv_pkg::PcAdvancePlus6: neq_advance_sel_cof[c] = neq_plus6;
        riscv_pkg::PcAdvancePlus8: neq_advance_sel_cof[c] = neq_plus8;
        default:                   neq_advance_sel_cof[c] = neq_plus2;
      endcase
    end
    neq_advance_sel = i_sel_nop ? neq_advance_sel_cof[1] : neq_advance_sel_cof[0];
  end
  always_comb begin
    if (seq_sel_holdoff) o_seq_next_pc_reg_neq_pc = neq_hold;
    else o_seq_next_pc_reg_neq_pc = neq_advance_sel;
  end

`ifndef SYNTHESIS
  // The 1-bit precompute must track the wide compare exactly.
  always_comb begin
    if (o_seq_next_pc_reg_neq_pc !== (o_seq_next_pc_reg != i_pc)) begin
      $error("pc_increment_calculator: o_seq_next_pc_reg_neq_pc mismatch");
    end
  end
`endif

endmodule : pc_increment_calculator

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
