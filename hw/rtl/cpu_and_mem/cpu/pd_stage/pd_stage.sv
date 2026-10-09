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
  Pre-Decode (PD) stage: second stage of the in-order front end.

  PD forms slot 1's 32-bit instruction: the native word (IF assembles one that
  spans two words), or for a compressed parcel the RV64C expansion that IF
  selected from the predecode sideband. Slot 2 arrives already expanded by
  the instruction aligner (see instruction_aligner.sv). In simulation only,
  local rvc_decompressors expand both slots' raw parcels as the reference for
  the checks below. PD also registers early source-register fields, from
  which it reassembles slot 2's instruction, and raises the PD redirect for a
  predicted-taken slot-1 branch (see that section).

  Both slots register the instruction without rewriting it to a NOP. A bubble
  (flush, PD redirect, or sel_nop) rides in inject_nop, which ID applies before
  decode, and a bubble's early source fields are x0. PD, like ID, is flushed on
  branch, trap, xRET, and FENCE-class recovery.
*/
module pd_stage #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id,
    // Slot 2 arrives expanded in effective_instr, with decomp_illegal and
    // sel_nop. PD extracts its source fields and carries invalidation in
    // inject_nop. The PD redirect applies only to slot 1.
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id_2,
    // Redirect to IF for a slot-1 conditional branch that nothing has
    // redirected yet and the bimodal predictor calls taken, for either offset
    // sign. See the PD redirect section below.
    output logic o_pd_redirect,
    output logic [XLEN-1:0] o_pd_redirect_target
);

  // ===========================================================================
  // Compressed Select and Illegal Flag
  // ===========================================================================
  // Slot 1 selects compressed instructions from raw parcel bits for timing.
  // IF uses sel_compressed for PC and buffer control. Legality is predecoded.
  logic pd_sel_compressed;
  logic decomp_illegal;
  assign pd_sel_compressed = (i_from_if_to_pd.raw_parcel[1:0] != 2'b11);
  assign decomp_illegal = i_from_if_to_pd.rvc_extra_predecoded[22];

`ifndef SYNTHESIS
  // Reference expansion of slot 1's raw parcel, which the checks below compare
  // with IF's predecoded fields. instruction_non_nop is the instruction PD
  // would register if it decoded the parcel itself.
  logic [31:0] decompressed_instr;
  logic        decomp_illegal_reference;
  logic [31:0] instruction_non_nop;

  rvc_decompressor decompressor_inst (
      .i_instr_compressed(i_from_if_to_pd.raw_parcel),
      .o_instr_expanded(decompressed_instr),
      .o_is_compressed(),
      .o_illegal(decomp_illegal_reference)
  );
  assign instruction_non_nop = pd_sel_compressed ? decompressed_instr :
                                                   i_from_if_to_pd.effective_instr;
`endif

  // ===========================================================================
  // Final Instruction Selection
  // ===========================================================================
  // Reassemble slot 1, then select a NOP for its early source fields.

  logic [31:0] final_instruction;

  // Bits [24:15] come from IF's selected source fields. For a compressed
  // parcel, rvc_extra_predecoded supplies the remaining instruction bits.
  logic [31:0] instruction_non_nop_predecoded_rs2;
  always_comb begin
    instruction_non_nop_predecoded_rs2 = i_from_if_to_pd.effective_instr;
    if (pd_sel_compressed) begin
      instruction_non_nop_predecoded_rs2[31:25] = i_from_if_to_pd.rvc_extra_predecoded[21:15];
      instruction_non_nop_predecoded_rs2[14:0]  = i_from_if_to_pd.rvc_extra_predecoded[14:0];
    end
    instruction_non_nop_predecoded_rs2[24:20] = i_from_if_to_pd.bits24_20_predecoded;
    instruction_non_nop_predecoded_rs2[19:15] = {
      i_from_if_to_pd.rs1_rest_predecoded[2:1],
      i_from_if_to_pd.source_hot_predecoded[1:0],
      i_from_if_to_pd.rs1_rest_predecoded[0]
    };
  end

  always_comb begin
    if (i_from_if_to_pd.sel_nop) final_instruction = riscv_pkg::NOP;
    else final_instruction = instruction_non_nop_predecoded_rs2;
  end

  // ===========================================================================
  // Early Source Register Extraction
  // ===========================================================================
  // Early source registers, taken from final_instruction: the predecoded
  // fields above, or x0 for a NOP. No logic reads slot 1's copies; slot 2's
  // rs1 and rs2 copies hold its instruction bits (see below).

  logic [4:0] source_reg_1;
  logic [4:0] source_reg_2;

  assign source_reg_1 = final_instruction[19:15];
  assign source_reg_2 = final_instruction[24:20];

  // ===========================================================================
  // Slot-2: Instruction Selection and Source Extraction
  // ===========================================================================
  // Driven from i_from_if_to_pd_2. The PD redirect is slot-1 only, and a slot-1
  // branch ends its bundle in the aligner, so the branch's packet never has a
  // valid slot 2.

  // The aligner selects among expanded slot-2 candidates. sel_compressed
  // must agree with raw_parcel[1:0] != 2'b11.
  logic pd_sel_compressed_2;
  assign pd_sel_compressed_2 = i_from_if_to_pd_2.sel_compressed;

  logic [31:0] instruction_non_nop_2;
  logic [21:0] slot2_instruction_non_source_q;
  logic [21:0] slot2_instruction_non_source;

  // Slot 2 stores rs1 and rs2 in the early source registers and the remaining
  // 22 bits in slot2_instruction_non_source_q, then reassembles the instruction.
  localparam logic [21:0] Slot2NopNonSource = {7'b0000000, 15'h0013};

  assign instruction_non_nop_2 = i_from_if_to_pd_2.effective_instr;

  logic [4:0] source_reg_1_2;
  logic [4:0] source_reg_2_2;

  // Unqualified source fields: rs1[2:1] comes from source_hot_predecoded,
  // the remaining rs1 bits from rs1_rest_predecoded, and rs2 from bits [24:20].
  // slot2_early_source_clear applies invalidation through the register reset.
  assign source_reg_1_2 = {
    i_from_if_to_pd_2.rs1_rest_predecoded[2:1],
    i_from_if_to_pd_2.source_hot_predecoded[1:0],
    i_from_if_to_pd_2.rs1_rest_predecoded[0]
  };
  assign source_reg_2_2 = i_from_if_to_pd_2.bits24_20_predecoded;
  // ID applies inject_nop to these unqualified bits. Invalid slots still
  // clear the separately registered source fields to x0.
  assign slot2_instruction_non_source = {instruction_non_nop_2[31:25], instruction_non_nop_2[14:0]};
  assign o_from_pd_to_id_2.instruction = {
    slot2_instruction_non_source_q[21:15],
    o_from_pd_to_id_2.source_reg_2_early,
    o_from_pd_to_id_2.source_reg_1_early,
    slot2_instruction_non_source_q[14:0]
  };

`ifndef SYNTHESIS
  // Reference expansion of slot 2's raw parcel, for the checks below.
  logic [31:0] decompressed_instr_2;
  logic        decomp_illegal_reference_2;
  rvc_decompressor decompressor_2_inst (
      .i_instr_compressed(i_from_if_to_pd_2.raw_parcel),
      .o_instr_expanded(decompressed_instr_2),
      .o_is_compressed(),
      .o_illegal(decomp_illegal_reference_2)
  );

  // Check that predecoded fields and early source registers match the
  // instruction. Arm after a reset edge, since IF's packet is undefined
  // before reset and the simulation clock can start before reset is driven.
  logic source_hot_checks_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) source_hot_checks_armed <= 1'b1;

    // Fetch-fault bytes are undefined (from_if_to_pd_t.fetch_fault) and need
    // not match the bypass fields: decode substitutes a fault pseudo-op.
    if (source_hot_checks_armed && !i_pipeline_ctrl.reset && !$isunknown(
            {
              i_from_if_to_pd.sel_nop,
              i_from_if_to_pd.fetch_fault,
              i_from_if_to_pd.source_hot_predecoded,
              i_from_if_to_pd.bits24_20_predecoded,
              i_from_if_to_pd.rs1_rest_predecoded,
              instruction_non_nop
            }
        ) && !i_from_if_to_pd.sel_nop && !i_from_if_to_pd.fetch_fault) begin
      p_slot1_source_hot_matches_instruction :
      assert (
          i_from_if_to_pd.source_hot_predecoded ==
          {instruction_non_nop[21], instruction_non_nop[17:16]}
      );
      p_slot1_rvc_expansion_matches_instruction :
      assert (!pd_sel_compressed ||
              (instruction_non_nop_predecoded_rs2 == instruction_non_nop &&
               decomp_illegal == decomp_illegal_reference));
      p_slot1_rs1_rest_match_instruction :
      assert (i_from_if_to_pd.rs1_rest_predecoded ==
          {instruction_non_nop[19:18], instruction_non_nop[15]});
      p_slot1_bits24_20_match_instruction :
      assert (i_from_if_to_pd.bits24_20_predecoded == instruction_non_nop[24:20]);
    end
    if (source_hot_checks_armed && !i_pipeline_ctrl.reset && !$isunknown(
            {
              i_from_if_to_pd_2.sel_nop,
              i_from_if_to_pd_2.fetch_fault,
              i_from_if_to_pd_2.source_hot_predecoded,
              i_from_if_to_pd_2.bits24_20_predecoded,
              i_from_if_to_pd_2.rs1_rest_predecoded,
              i_from_if_to_pd_2.raw_parcel,
              i_from_if_to_pd_2.decomp_illegal,
              pd_sel_compressed_2,
              instruction_non_nop_2
            }
        ) && !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault) begin
      p_slot2_sel_compressed_matches_parcel :
      assert (pd_sel_compressed_2 == (i_from_if_to_pd_2.raw_parcel[1:0] != 2'b11));
      p_slot2_rvc_expansion_matches_reference :
      assert (!pd_sel_compressed_2 ||
              (instruction_non_nop_2 == decompressed_instr_2 &&
               i_from_if_to_pd_2.decomp_illegal == decomp_illegal_reference_2));
      p_slot2_source_hot_matches_instruction :
      assert (
          i_from_if_to_pd_2.source_hot_predecoded ==
          {instruction_non_nop_2[21], instruction_non_nop_2[17:16]}
      );
      p_slot2_early_rs1_matches_instruction :
      assert (source_reg_1_2 == instruction_non_nop_2[19:15]);
      p_slot2_early_rs2_matches_instruction :
      assert (source_reg_2_2 == instruction_non_nop_2[24:20]);
      p_slot2_early_rs1_hot_bits_are_direct :
      assert (source_reg_1_2[2:1] == i_from_if_to_pd_2.source_hot_predecoded[1:0]);
    end
  end
`endif

  // ===========================================================================
  // PD Redirect: Predicted-Taken Branch With No BTB Prediction
  // ===========================================================================
  // A slot-1 conditional branch that nothing has redirected yet (no taken BTB
  // prediction) and that the bimodal direction predictor calls taken
  // (bp_dir_taken) redirects IF to PC + offset, for either offset sign, instead
  // of waiting to resolve as a misprediction.
  //
  // Native B-type and compressed C.BEQZ/C.BNEZ targets are computed as two
  // format-specific 13-bit carry-select candidates. Both immediates fit after
  // sign-extending the compressed 9-bit offset to 13 bits. If s is that 13-bit
  // immediate's sign and c is the low-add carry, the high result is exactly
  // PC_high+c-s: unchanged for {s,c}=00/11, +1 for 01, and -1 for 10.
  //
  // IF carries both low sums and {sign, carry} selects in the packet. PD
  // captures them, the format bit, and PC_high with its +/-1 corrections on
  // the same edge. The next cycle selects the format and high correction.
  // The full target is exact modulo 2^XLEN.

`ifndef SYNTHESIS
  // The two branch immediates, for the candidate checks below.
  logic [XLEN-1:0] pd_imm_b_native;
  assign pd_imm_b_native = {
    {(XLEN - 13) {i_from_if_to_pd.effective_instr[31]}},  // sign-extend bits [XLEN-1:13]
    i_from_if_to_pd.effective_instr[31],  // imm[12]
    i_from_if_to_pd.effective_instr[7],  // imm[11]
    i_from_if_to_pd.effective_instr[30:25],  // imm[10:5]
    i_from_if_to_pd.effective_instr[11:8],  // imm[4:1]
    1'b0  // imm[0] always zero
  };

  logic [XLEN-1:0] pd_imm_b_compressed;
  assign pd_imm_b_compressed = {
    {(XLEN - 9) {i_from_if_to_pd.raw_parcel[12]}},  // sign-extend bits [XLEN-1:9]
    i_from_if_to_pd.raw_parcel[12],  // imm[8]
    i_from_if_to_pd.raw_parcel[6:5],  // imm[7:6]
    i_from_if_to_pd.raw_parcel[2],  // imm[5]
    i_from_if_to_pd.raw_parcel[11:10],  // imm[4:3]
    i_from_if_to_pd.raw_parcel[4:3],  // imm[2:1]
    1'b0  // imm[0] always zero
  };
`endif

  logic pd_native_branch;
  logic pd_compressed_branch;
  assign pd_native_branch = !pd_sel_compressed &&
                            (i_from_if_to_pd.effective_instr[6:0] == riscv_pkg::OPC_BRANCH);
  assign pd_compressed_branch =
      (i_from_if_to_pd.raw_parcel[1:0] == 2'b01) &&
      ((i_from_if_to_pd.raw_parcel[15:13] == 3'b110) ||
       (i_from_if_to_pd.raw_parcel[15:13] == 3'b111));

  localparam int unsigned PdTargetSplit = riscv_pkg::PdTargetSplit;
  localparam int unsigned PdTargetHighWidth = XLEN - PdTargetSplit;

  (* keep = "true" *) logic [PdTargetHighWidth-1:0] pd_pc_high_plus_one;
  (* keep = "true" *) logic [PdTargetHighWidth-1:0] pd_pc_high_minus_one;
  logic [PdTargetSplit-1:0] pd_target_native_low_candidate;
  logic [PdTargetSplit-1:0] pd_target_compressed_low_candidate;
  logic [1:0] pd_target_native_high_select;
  logic [1:0] pd_target_compressed_high_select;
  logic [PdTargetSplit-1:0] pd_target_selected_low;
  logic [1:0] pd_target_selected_high_select;

  (* dont_touch = "yes" *) pd_target_high_precompute #(
      .HIGH_WIDTH(PdTargetHighWidth)
  ) u_pd_target_high_precompute (
      .i_pc_high          (i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit]),
      .o_pc_high_plus_one (pd_pc_high_plus_one),
      .o_pc_high_minus_one(pd_pc_high_minus_one)
  );

  // The candidates arrive in the packet (see pd_target_candidate).
  assign pd_target_native_low_candidate = i_from_if_to_pd.pd_target_native_low;
  assign pd_target_native_high_select = i_from_if_to_pd.pd_target_native_high_select;
  assign pd_target_compressed_low_candidate = i_from_if_to_pd.pd_target_compressed_low;
  assign pd_target_compressed_high_select = i_from_if_to_pd.pd_target_compressed_high_select;

  assign pd_target_selected_low = pd_compressed_branch ?
      pd_target_compressed_low_candidate : pd_target_native_low_candidate;
  assign pd_target_selected_high_select = pd_compressed_branch ?
      pd_target_compressed_high_select : pd_target_native_high_select;

  function automatic logic [PdTargetHighWidth-1:0] select_pd_target_high(
      input logic [1:0] high_select, input logic [PdTargetHighWidth-1:0] pc_high,
      input logic [PdTargetHighWidth-1:0] pc_high_plus_one,
      input logic [PdTargetHighWidth-1:0] pc_high_minus_one);
    case (high_select)
      2'b00, 2'b11: select_pd_target_high = pc_high;
      2'b01: select_pd_target_high = pc_high_plus_one;
      2'b10: select_pd_target_high = pc_high_minus_one;
      default: select_pd_target_high = 'x;
    endcase
  endfunction

`ifndef SYNTHESIS
  logic [XLEN-1:0] pd_target_native_reference;
  logic [XLEN-1:0] pd_target_compressed_reference;
  logic [XLEN-1:0] pd_backward_target_reference;
  logic [XLEN-1:0] pd_target_native_split;
  logic [XLEN-1:0] pd_target_compressed_split;
  logic [XLEN-1:0] pd_target_selected_split;
  assign pd_target_native_reference = i_from_if_to_pd.program_counter + pd_imm_b_native;
  assign pd_target_compressed_reference = i_from_if_to_pd.program_counter + pd_imm_b_compressed;
  assign pd_backward_target_reference = pd_compressed_branch ? pd_target_compressed_reference :
                                        pd_target_native_reference;
  assign pd_target_native_split = {
    select_pd_target_high(
        pd_target_native_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_target_native_low_candidate
  };
  assign pd_target_compressed_split = {
    select_pd_target_high(
        pd_target_compressed_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_target_compressed_low_candidate
  };
  assign pd_target_selected_split = {
    select_pd_target_high(
        pd_target_selected_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_target_selected_low
  };

  always_comb begin
    if (!$isunknown(
            {
              i_from_if_to_pd.program_counter,
              pd_imm_b_native,
              pd_imm_b_compressed,
              pd_target_native_split,
              pd_target_compressed_split,
              pd_target_selected_split,
              pd_backward_target_reference
            }
        )) begin
      p_pd_native_target_candidate_exact :
      assert (pd_target_native_split == pd_target_native_reference);
      p_pd_compressed_target_candidate_exact :
      assert (pd_target_compressed_split == pd_target_compressed_reference);
      p_pd_target_split_exact : assert (pd_target_selected_split == pd_backward_target_reference);
    end
  end
`endif

  // Register branch && direction separately from the packet's redirect
  // vetoes, then qualify the candidate after the register for timing.
  logic pd_backward_branch;
  logic pd_redirect_candidate_r;
  logic pd_redirect_r;
  assign pd_backward_branch =
      (pd_native_branch || pd_compressed_branch) &&  // conditional branch (any offset)
      i_from_if_to_pd.bp_dir_taken;  // decoupled bimodal predicts TAKEN

  // The packet carries same-edge vetoes: predicted taken, inject_nop, and
  // fetch fault. A redirect sets inject_nop on the following wrong-path
  // packet, masking its candidate. Candidate and packet share the stall
  // enable; reset and flush clear the candidate. Gating fetch_fault with
  // !sel_nop is safe because inject_nop already vetoes sel_nop.
  assign pd_redirect_r = pd_redirect_candidate_r &&
      !o_from_pd_to_id.btb_predicted_taken &&
      !o_from_pd_to_id.inject_nop &&
      !o_from_pd_to_id.fetch_fault;

  // IF's redirect depends only on PD registers. It costs two bubbles; both
  // slots of the wrong-path packet entering PD behind the branch are
  // squashed through inject_nop.
  // Both format candidates and the format bit load on the same enabled edge,
  // so the mux after them equals one register of the selected candidate.
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_target_native_low_r;
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_target_compressed_low_r;
  (* keep = "true" *) logic [1:0] pd_redirect_target_native_high_select_r;
  (* keep = "true" *) logic [1:0] pd_redirect_target_compressed_high_select_r;
  (* keep = "true" *) logic pd_redirect_target_compressed_r;
  logic [PdTargetSplit-1:0] pd_redirect_target_low;
  logic [1:0] pd_redirect_target_high_select;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_r;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_plus_one_r;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_minus_one_r;
  logic [PdTargetHighWidth-1:0] pd_redirect_target_high;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) pd_redirect_candidate_r <= 1'b0;
    else if (!i_pipeline_ctrl.stall) pd_redirect_candidate_r <= pd_backward_branch;
  end

  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_redirect_target_native_low_r <= pd_target_native_low_candidate;
      pd_redirect_target_compressed_low_r <= pd_target_compressed_low_candidate;
      pd_redirect_target_native_high_select_r <= pd_target_native_high_select;
      pd_redirect_target_compressed_high_select_r <= pd_target_compressed_high_select;
      pd_redirect_target_compressed_r <= pd_compressed_branch;
      pd_redirect_pc_high_r <= i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit];
      pd_redirect_pc_high_plus_one_r <= pd_pc_high_plus_one;
      pd_redirect_pc_high_minus_one_r <= pd_pc_high_minus_one;
    end
  end

  assign pd_redirect_target_low = pd_redirect_target_compressed_r ?
      pd_redirect_target_compressed_low_r : pd_redirect_target_native_low_r;
  assign pd_redirect_target_high_select = pd_redirect_target_compressed_r ?
      pd_redirect_target_compressed_high_select_r : pd_redirect_target_native_high_select_r;
  assign pd_redirect_target_high = select_pd_target_high(
      pd_redirect_target_high_select,
      pd_redirect_pc_high_r,
      pd_redirect_pc_high_plus_one_r,
      pd_redirect_pc_high_minus_one_r
  );

  assign o_pd_redirect = pd_redirect_r;
  assign o_pd_redirect_target = {pd_redirect_target_high, pd_redirect_target_low};

`ifndef SYNTHESIS
  // Compare against registering the selected candidate on the same edge.
  logic [PdTargetSplit-1:0] pd_redirect_target_low_reference_r;
  logic [1:0] pd_redirect_target_high_select_reference_r;
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_redirect_target_low_reference_r <= pd_target_selected_low;
      pd_redirect_target_high_select_reference_r <= pd_target_selected_high_select;
    end
  end
  always_ff @(posedge i_clk) begin
    if (!$isunknown(
            {
              pd_redirect_target_low_reference_r,
              pd_redirect_target_low,
              pd_redirect_target_high_select_reference_r,
              pd_redirect_target_high_select
            }
        )) begin
      p_pd_redirect_target_low_capture_exact :
      assert (pd_redirect_target_low == pd_redirect_target_low_reference_r);
      p_pd_redirect_target_high_select_capture_exact :
      assert (pd_redirect_target_high_select == pd_redirect_target_high_select_reference_r);
    end
  end
`endif

`ifndef SYNTHESIS
  // Reference model of the candidate FF: reset and flush clear it even during a
  // stall, a stall holds it, and every enabled edge captures branch &&
  // direction with no feedback from the qualified redirect.
  logic pd_redirect_candidate_payload_reference_q;
  logic pd_redirect_candidate_payload_reference_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_candidate_payload_reference_q <= 1'b0;
      pd_redirect_candidate_payload_reference_armed <= 1'b1;
    end else begin
      if (pd_redirect_candidate_payload_reference_armed && !$isunknown(
              {pd_redirect_candidate_r, pd_redirect_candidate_payload_reference_q}
          )) begin
        p_pd_redirect_candidate_payload_exact :
        assert (pd_redirect_candidate_r == pd_redirect_candidate_payload_reference_q);
      end

      if (i_pipeline_ctrl.flush) begin
        pd_redirect_candidate_payload_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_redirect_candidate_payload_reference_q <=
            (pd_native_branch || pd_compressed_branch) && i_from_if_to_pd.bp_dir_taken;
        pd_redirect_candidate_payload_reference_armed <= 1'b1;
      end
    end
  end

  // Compare with a register of the fully qualified redirect. The packet's
  // inject_nop accounts for sel_nop and the previous redirect; the other
  // vetoes are predicted taken and fetch fault. Shared enables preserve this
  // alignment across stalls, and reset or flush clears the candidate.
  // Compare before nonblocking updates to avoid delta-cycle races.
  logic pd_redirect_reference_q;
  logic pd_redirect_reference_armed = 1'b0;
  logic pd_backward_branch_reference;
  assign pd_backward_branch_reference =
      (pd_native_branch || pd_compressed_branch) &&
      i_from_if_to_pd.bp_dir_taken &&
      !i_from_if_to_pd.btb_predicted_taken &&
      !i_from_if_to_pd.sel_nop &&
      !i_from_if_to_pd.fetch_fault &&
      !pd_redirect_reference_q;

  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_reference_q <= 1'b0;
      pd_redirect_reference_armed <= 1'b1;
    end else begin
      if (pd_redirect_reference_armed && !$isunknown(
              {pd_redirect_r, pd_redirect_reference_q}
          )) begin
        p_pd_redirect_registered_veto_exact : assert (pd_redirect_r == pd_redirect_reference_q);
      end

      if (i_pipeline_ctrl.flush) begin
        pd_redirect_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_redirect_reference_q <= pd_backward_branch_reference;
        pd_redirect_reference_armed <= 1'b1;
      end
    end
  end

  // A full-width reference sampled on the same enabled edges checks target
  // alignment, stall hold, and format selection.
  logic [XLEN-1:0] pd_redirect_target_reference_q;
  logic pd_redirect_target_reference_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_target_reference_armed <= 1'b0;
    end else begin
      if (pd_redirect_target_reference_armed && !$isunknown(
              {o_pd_redirect_target, pd_redirect_target_reference_q}
          )) begin
        p_pd_redirect_target_boundary_exact :
        assert (o_pd_redirect_target == pd_redirect_target_reference_q);
      end
      if (!i_pipeline_ctrl.stall) begin
        pd_redirect_target_reference_q <= pd_backward_target_reference;
        pd_redirect_target_reference_armed <= 1'b1;
      end
    end
  end
`endif

  // ===========================================================================
  // Pipeline Register: PD to ID
  // ===========================================================================

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      o_from_pd_to_id.instruction         <= riscv_pkg::NOP;
      o_from_pd_to_id.inject_nop          <= 1'b1;
      o_from_pd_to_id.is_compressed       <= 1'b0;
      o_from_pd_to_id.illegal_instruction <= 1'b0;
      o_from_pd_to_id.fetch_fault         <= 1'b0;
      o_from_pd_to_id.fetch_fault_page    <= 1'b0;
      o_from_pd_to_id.fetch_fault_hi      <= 1'b0;
      // Branch prediction metadata
      o_from_pd_to_id.btb_predicted_taken <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      // ID and frontend_validity_tracker apply inject_nop. It squashes
      // flushes, the packet behind a PD redirect, and sel_nop bubbles.
      // Early source fields read x0 for a bubble.
      o_from_pd_to_id.instruction <= instruction_non_nop_predecoded_rs2;
      o_from_pd_to_id.inject_nop <= i_pipeline_ctrl.flush || pd_redirect_r ||
                                    i_from_if_to_pd.sel_nop;
      o_from_pd_to_id.is_compressed <= (i_pipeline_ctrl.flush || pd_redirect_r ||
                                        i_from_if_to_pd.sel_nop) ? 1'b0 :
                                                                 pd_sel_compressed;
      // Illegal compressed indication is only valid when compressed decode path is selected.
      o_from_pd_to_id.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                              (!i_from_if_to_pd.sel_nop &&
                                              pd_sel_compressed && decomp_illegal);
      // The fetch fault has the same flush/redirect clear and !sel_nop gate as
      // the illegal flag. Decode replaces the instruction's garbage bytes with
      // a fetch-fault pseudo-op.
      o_from_pd_to_id.fetch_fault <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                      (!i_from_if_to_pd.sel_nop &&
                                       i_from_if_to_pd.fetch_fault);
      // Fault kind and faulting-halfword qualifiers: meaningful only under
      // fetch_fault, so they pass through unqualified.
      o_from_pd_to_id.fetch_fault_page <= i_from_if_to_pd.fetch_fault_page;
      o_from_pd_to_id.fetch_fault_hi <= i_from_if_to_pd.fetch_fault_hi;
      // ID applies the PD redirect's taken flag and target to the branch.
      // Here, flush and redirect only clear the younger packet's taken flag.
      o_from_pd_to_id.btb_predicted_taken <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                              i_from_if_to_pd.btb_predicted_taken;
    end

    if (~i_pipeline_ctrl.stall) begin
      o_from_pd_to_id.program_counter <= i_from_if_to_pd.program_counter;
      // Early source registers, x0 for a bubble
      o_from_pd_to_id.source_reg_1_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_1;
      o_from_pd_to_id.source_reg_2_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_2;
      o_from_pd_to_id.btb_predicted_target <= i_from_if_to_pd.btb_predicted_target;
      o_from_pd_to_id.ras_checkpoint_tos <= i_from_if_to_pd.ras_checkpoint_tos;
      o_from_pd_to_id.ras_checkpoint_valid_count <= i_from_if_to_pd.ras_checkpoint_valid_count;
      o_from_pd_to_id.ras_checkpoint_top <= i_from_if_to_pd.ras_checkpoint_top;
      // Carry the predict-time bimodal index through to commit.
      o_from_pd_to_id.bp_dir_idx <= i_from_if_to_pd.bp_dir_idx;
    end
  end

  // ===========================================================================
  // Slot-2 Pipeline Register: PD to ID
  // ===========================================================================
  // Both slots advance together. pd_redirect_r squashes both slots of the
  // wrong-path packet following the branch.

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      slot2_instruction_non_source_q        <= Slot2NopNonSource;
      o_from_pd_to_id_2.inject_nop          <= 1'b1;
      o_from_pd_to_id_2.is_compressed       <= 1'b0;
      o_from_pd_to_id_2.illegal_instruction <= 1'b0;
      o_from_pd_to_id_2.fetch_fault         <= 1'b0;
      o_from_pd_to_id_2.fetch_fault_page    <= 1'b0;
      o_from_pd_to_id_2.fetch_fault_hi      <= 1'b0;
      o_from_pd_to_id_2.btb_predicted_taken <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      slot2_instruction_non_source_q <= slot2_instruction_non_source;
      o_from_pd_to_id_2.inject_nop <= i_pipeline_ctrl.flush || pd_redirect_r ||
                                      i_from_if_to_pd_2.sel_nop;
      o_from_pd_to_id_2.is_compressed <= (i_pipeline_ctrl.flush || pd_redirect_r ||
                                          i_from_if_to_pd_2.sel_nop) ? 1'b0 :
                                                                    pd_sel_compressed_2;
      o_from_pd_to_id_2.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                                (!i_from_if_to_pd_2.sel_nop &&
                                                i_from_if_to_pd_2.decomp_illegal);
      // slot-2 fetch-fault pass-through (see slot-1).
      o_from_pd_to_id_2.fetch_fault <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                        (!i_from_if_to_pd_2.sel_nop &&
                                         i_from_if_to_pd_2.fetch_fault);
      o_from_pd_to_id_2.fetch_fault_page <= i_from_if_to_pd_2.fetch_fault_page;
      o_from_pd_to_id_2.fetch_fault_hi <= i_from_if_to_pd_2.fetch_fault_hi;
      o_from_pd_to_id_2.btb_predicted_taken <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                                i_from_if_to_pd_2.btb_predicted_taken;
    end

    if (~i_pipeline_ctrl.stall) begin
      o_from_pd_to_id_2.program_counter <= i_from_if_to_pd_2.program_counter;
      o_from_pd_to_id_2.btb_predicted_target <= i_from_if_to_pd_2.btb_predicted_target;
      o_from_pd_to_id_2.ras_checkpoint_tos <= i_from_if_to_pd_2.ras_checkpoint_tos;
      o_from_pd_to_id_2.ras_checkpoint_valid_count <= i_from_if_to_pd_2.ras_checkpoint_valid_count;
      o_from_pd_to_id_2.ras_checkpoint_top <= i_from_if_to_pd_2.ras_checkpoint_top;
      // Carry the predict-time bimodal index through to commit.
      o_from_pd_to_id_2.bp_dir_idx <= i_from_if_to_pd_2.bp_dir_idx;
    end
  end

  // Clear slot 2's early source fields synchronously for invalidation, so
  // Vivado can use the register reset pin. Include !stall: a bubble or flush
  // must not overwrite held source addresses before the bundle advances.
  logic slot2_early_source_clear;
  assign slot2_early_source_clear = !i_pipeline_ctrl.stall &&
      (i_pipeline_ctrl.flush || pd_redirect_r || i_from_if_to_pd_2.sel_nop);

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      o_from_pd_to_id_2.source_reg_1_early <= 5'd0;
      o_from_pd_to_id_2.source_reg_2_early <= 5'd0;
    end else if (slot2_early_source_clear) begin
      o_from_pd_to_id_2.source_reg_1_early <= 5'd0;
      o_from_pd_to_id_2.source_reg_2_early <= 5'd0;
    end else if (!i_pipeline_ctrl.stall) begin
      o_from_pd_to_id_2.source_reg_1_early <= source_reg_1_2;
      o_from_pd_to_id_2.source_reg_2_early <= source_reg_2_2;
    end
  end

`ifdef FROST_DEBUG_FETCH_ILA
  // Fetch ILA probes (build.py --debug-ila): marked copies that the debug core
  // samples. Nothing here feeds the design. The low 16 PC bits suffice because
  // the capture triggers on a page offset.
  (* mark_debug = "true" *) logic [15:0] dbg_ila_pd_id_pc;
  (* mark_debug = "true" *) logic [31:0] dbg_ila_pd_id_instr;
  (* mark_debug = "true" *) logic dbg_ila_pd_id_inject_nop;
  (* mark_debug = "true" *) logic dbg_ila_pd_id_fetch_fault;
  assign dbg_ila_pd_id_pc = o_from_pd_to_id.program_counter[15:0];
  assign dbg_ila_pd_id_instr = o_from_pd_to_id.instruction;
  assign dbg_ila_pd_id_inject_nop = o_from_pd_to_id.inject_nop;
  assign dbg_ila_pd_id_fetch_fault = o_from_pd_to_id.fetch_fault;
`endif

endmodule : pd_stage
