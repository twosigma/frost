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
    // Slot-2 instruction (2-wide dispatch). IF supplies a real second
    // instruction whenever the bundle has one and raises sel_nop only when it
    // does not. The aligner has already expanded it from the predecode
    // sideband: effective_instr holds the finished instruction and
    // decomp_illegal the selected candidate's illegal-RVC flag. PD extracts
    // its source fields and carries invalidation separately in inject_nop.
    // The PD redirect is slot-1 only.
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
  // Take slot 1's compressed select from the raw parcel's low bits, not IF's
  // sideband sel_compressed (which IF still uses for PC and buffer timing).
  // That keeps the BRAM sideband out of PD's instruction and branch-target
  // muxes, so no path runs from it through the instruction select into the
  // target carry chain. The illegal-RVC flag is the predecoded one.
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
  // Select the final instruction from the IF packet. These are priority
  // muxes, so nothing here depends on the sel_* signals being one-hot.

  logic [31:0] final_instruction;

  // TIMING: the registered slot-1 instruction is built from IF's predecoded
  // fields, with no decoder of its own. Bits [24:15] come from IF's
  // predecoded source fields (the IMEM sideband's RVC expansion or the native
  // word, already selected), and a compressed parcel's other bits come from
  // rvc_extra_predecoded. The checks below compare the result with the
  // reference expansion.
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

  // Slot 2 arrives already expanded. The aligner takes each of its three
  // candidates' RVC expansion from the predecode sideband in parallel with its
  // position select, so no RVC expander follows the position mux.
  // effective_instr holds the finished instruction for both RVC and native
  // cases, and decomp_illegal the selected candidate's illegal-RVC flag.
  // sel_compressed is the sideband compressed flag, which equals
  // raw_parcel[1:0] != 2'b11.
  logic pd_sel_compressed_2;
  assign pd_sel_compressed_2 = i_from_if_to_pd_2.sel_compressed;

  logic [31:0] instruction_non_nop_2;
  logic [21:0] slot2_instruction_non_source_q;
  logic [21:0] slot2_instruction_non_source;

  // Slot 2's rs1 and rs2 are registered once, in the early source fields.
  // slot2_instruction_non_source_q holds the other 22 instruction bits, and
  // o_from_pd_to_id_2.instruction is reassembled from both. This avoids a
  // second, deeper D path for the same bits.
  localparam logic [21:0] Slot2NopNonSource = {7'b0000000, 15'h0013};

  assign instruction_non_nop_2 = i_from_if_to_pd_2.effective_instr;

  logic [4:0] source_reg_1_2;
  logic [4:0] source_reg_2_2;

  // Source fields before NOP injection. The synchronous clear below
  // (slot2_early_source_clear) applies slot invalidation through the FDRE
  // reset pin, keeping the bubble and flush mux off these 10 D inputs. rs1[2:1]
  // come from the source-hot sideband bits, the rest of rs1 from
  // rs1_rest_predecoded, and all of rs2 from IF's predecoded bits [24:20].
  // These registers supply rs1 and rs2 of the reassembled instruction.
  assign source_reg_1_2 = {
    i_from_if_to_pd_2.rs1_rest_predecoded[2:1],
    i_from_if_to_pd_2.source_hot_predecoded[1:0],
    i_from_if_to_pd_2.rs1_rest_predecoded[0]
  };
  assign source_reg_2_2 = i_from_if_to_pd_2.bits24_20_predecoded;
  // Keep the bubble select off the remaining 22 instruction D inputs, as slot 1
  // does for its full instruction register. The registered
  // o_from_pd_to_id_2.inject_nop bit tells ID when to substitute the NOP. The
  // source fields keep their own clear below, so they read x0 for an invalid
  // slot.
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

  // The predecoded fields are a second copy of instruction bits. Check them
  // against the instruction wherever both are available, so the registered
  // instruction and the early source registers cannot diverge from the
  // architectural instruction. The IF packet registers hold nothing meaningful
  // until their first reset edge, and cocotb can start the clock before it
  // drives top-level reset, so arm these checks only once a reset has been seen
  // at a clock edge.
  logic source_hot_checks_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) source_hot_checks_armed <= 1'b1;

    // A fetch-fault bundle carries garbage instruction bytes by contract
    // (from_if_to_pd_t.fetch_fault): decode overrides them with the fault
    // pseudo-op, so the bypass need not match them. The cached provider's
    // fault window is all zeros while the packet's instruction register keeps
    // the last real word, which is where the two visibly diverge.
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
  // PD Redirect: Predicted-Taken Branch With No BTB or RAS Prediction
  // ===========================================================================
  // A slot-1 conditional branch that nothing has redirected yet (no taken BTB
  // or RAS prediction) and that the bimodal direction predictor calls taken
  // (bp_dir_taken) redirects IF to PC + offset, for either offset sign, instead
  // of waiting to resolve as a misprediction.
  //
  // Native B-type and compressed C.BEQZ/C.BNEZ targets are computed in two
  // protected, format-specific 13-bit carry-select candidates. Both immediates
  // fit after sign-extending the compressed 9-bit offset to 13 bits. If s is
  // that 13-bit immediate's sign and c is the low-add carry, the high result is
  // exactly PC_high+c-s: unchanged for {s,c}=00/11, +1 for 01, and -1 for 10.
  //
  // The PC-high +/-1 values depend only on the registered PC and settle before
  // the instruction BRAM responds. The protected candidate boundaries keep the
  // compressed/native select after both low carry chains; without them Vivado
  // folds the candidates into one selected-immediate adder. The redirect
  // register captures the selected low result, the raw {sign, carry} select,
  // and all three PC-high values, and the next cycle's shallow high-part mux
  // decodes the select. That keeps the correction decode out of the late
  // carry-to-D path. The full target is exact modulo 2^XLEN.

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

  logic pd_native_branch;
  logic pd_compressed_branch;
  assign pd_native_branch = !pd_sel_compressed &&
                            (i_from_if_to_pd.effective_instr[6:0] == riscv_pkg::OPC_BRANCH);
  assign pd_compressed_branch =
      (i_from_if_to_pd.raw_parcel[1:0] == 2'b01) &&
      ((i_from_if_to_pd.raw_parcel[15:13] == 3'b110) ||
       (i_from_if_to_pd.raw_parcel[15:13] == 3'b111));

  localparam int unsigned PdTargetSplit = 13;
  localparam int unsigned PdTargetHighWidth = XLEN - PdTargetSplit;

  (* keep = "true" *) logic [PdTargetHighWidth-1:0] pd_pc_high_plus_one;
  (* keep = "true" *) logic [PdTargetHighWidth-1:0] pd_pc_high_minus_one;
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_target_native_low_candidate;
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_target_compressed_low_candidate;
  (* keep = "true" *) logic [1:0] pd_target_native_high_select;
  (* keep = "true" *) logic [1:0] pd_target_compressed_high_select;
  logic [PdTargetSplit-1:0] pd_target_selected_low;
  logic [1:0] pd_target_selected_high_select;

  (* dont_touch = "yes" *) pd_target_high_precompute #(
      .HIGH_WIDTH(PdTargetHighWidth)
  ) u_pd_target_high_precompute (
      .i_pc_high          (i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit]),
      .o_pc_high_plus_one (pd_pc_high_plus_one),
      .o_pc_high_minus_one(pd_pc_high_minus_one)
  );

  (* dont_touch = "yes" *) pd_target_candidate #(
      .SPLIT(PdTargetSplit)
  ) u_pd_target_native_candidate (
      .i_pc_low     (i_from_if_to_pd.program_counter[PdTargetSplit-1:0]),
      .i_imm_low    (pd_imm_b_native[PdTargetSplit-1:0]),
      .o_target_low (pd_target_native_low_candidate),
      .o_high_select(pd_target_native_high_select)
  );

  (* dont_touch = "yes" *) pd_target_candidate #(
      .SPLIT(PdTargetSplit)
  ) u_pd_target_compressed_candidate (
      .i_pc_low     (i_from_if_to_pd.program_counter[PdTargetSplit-1:0]),
      .i_imm_low    (pd_imm_b_compressed[PdTargetSplit-1:0]),
      .o_target_low (pd_target_compressed_low_candidate),
      .o_high_select(pd_target_compressed_high_select)
  );

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

  // Fire the PD redirect for a conditional branch, native B-type or compressed
  // C.BEQZ/C.BNEZ, that the front end has not already redirected and that the
  // bimodal predictor calls taken (bp_dir_taken, carried from IF).
  //
  // TIMING: the candidate register captures only branch && direction,
  // independent of every late veto and of the previous qualified redirect. The
  // four vetoes cross the same edge in the slot-1 PD-to-ID packet, so
  // pd_redirect_r qualifies the candidate with those registered copies in one
  // LUT. This keeps the served-window metadata path and the redirect feedback
  // off the candidate's D input.
  logic pd_backward_branch;
  logic pd_redirect_candidate_r;
  logic pd_redirect_r;
  assign pd_backward_branch =
      (pd_native_branch || pd_compressed_branch) &&  // conditional branch (any offset)
      i_from_if_to_pd.bp_dir_taken;  // decoupled bimodal predicts TAKEN

  // These packet fields are the registered copies, from the same packet, of the
  // vetoes that pd_backward_branch leaves out. inject_nop carries sel_nop on an
  // ordinary edge. When a qualified redirect fires, that same edge records
  // inject_nop, so a branch-shaped wrong-path payload captured beside it stays
  // masked on the following cycle. Candidate and packet FFs share the stall
  // enable, so that mask stays aligned while held. Reset and flush clear the
  // candidate directly. The packet's fetch_fault is gated by !sel_nop, which is
  // equivalent here because inject_nop already vetoes sel_nop.
  assign pd_redirect_r = pd_redirect_candidate_r &&
      !o_from_pd_to_id.btb_predicted_taken &&
      !o_from_pd_to_id.ras_predicted &&
      !o_from_pd_to_id.inject_nop &&
      !o_from_pd_to_id.fetch_fault;

  // The redirect to IF comes only from registers at the PD boundary: the
  // candidate FF plus one LUT over PD-to-ID packet FFs, and the split target
  // registers below. No combinational path runs from PD's inputs into IF's PC
  // mux. The redirect costs two bubbles, one of them the wrong-path packet that
  // enters PD before the registered redirect fires. That packet is squashed at
  // the PD-to-ID register: both slots flag it in inject_nop for their consumers
  // to apply.
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_target_low_r;
  (* keep = "true" *) logic [1:0] pd_redirect_target_high_select_r;
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
      pd_redirect_target_low_r <= pd_target_selected_low;
      pd_redirect_target_high_select_r <= pd_target_selected_high_select;
      pd_redirect_pc_high_r <= i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit];
      pd_redirect_pc_high_plus_one_r <= pd_pc_high_plus_one;
      pd_redirect_pc_high_minus_one_r <= pd_pc_high_minus_one;
    end
  end

  assign pd_redirect_target_high = select_pd_target_high(
      pd_redirect_target_high_select_r,
      pd_redirect_pc_high_r,
      pd_redirect_pc_high_plus_one_r,
      pd_redirect_pc_high_minus_one_r
  );

  assign o_pd_redirect = pd_redirect_r;
  assign o_pd_redirect_target = {pd_redirect_target_high, pd_redirect_target_low_r};

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

  // Reference model: a single redirect FF with the full next-state equation
  // (branch, direction, the four vetoes, and !redirect). On an enabled edge
  // with no reset or flush, the candidate captures only
  //   branch && direction
  // while the packet FFs capture the four vetoes. If a redirect is already
  // qualified, the packet captures inject_nop on that same edge, which masks a
  // wrong-path candidate exactly where the reference uses !redirect. Reset and
  // flush clear the candidate, and a stall holds candidate and packet
  // (including that mask), so the one-LUT redirect equals the reference across
  // every control sequence. Compare at the clock edge, before the nonblocking
  // updates, to avoid delta-cycle races between the independently updated
  // registers.
  logic pd_redirect_reference_q;
  logic pd_redirect_reference_armed = 1'b0;
  logic pd_backward_branch_reference;
  assign pd_backward_branch_reference =
      (pd_native_branch || pd_compressed_branch) &&
      i_from_if_to_pd.bp_dir_taken &&
      !i_from_if_to_pd.btb_predicted_taken &&
      !i_from_if_to_pd.ras_predicted &&
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

  // Reference model: a full-width target register, sampled on the same enabled
  // edges as the split registers. This one check covers register alignment,
  // stall hold, alternating branch formats, and the high-part mux after the
  // register.
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
  // Pipeline Register: PD → ID
  // ===========================================================================
  // Register all outputs to ID stage with stall and flush support.

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
      // RAS prediction metadata
      o_from_pd_to_id.ras_predicted       <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      // The instruction is registered without being rewritten to a NOP. A
      // bubble (flush, the PD redirect squashing the wrong-path packet that
      // entered PD behind the branch, or sel_nop) rides in inject_nop, and its
      // consumers apply it: id_stage decode and frontend_validity_tracker. That
      // keeps the deep, stall-fed sel_nop select off the 32-bit instruction D
      // inputs. pd_redirect_r is one LUT over registers, so no live IF path
      // enters these muxes. The early source fields below still come from
      // final_instruction and read x0 for a bubble.
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
      // Branch prediction metadata, cleared on flush or PD redirect. The BTB
      // fields pass through unchanged: id_stage marks a PD-redirected branch
      // taken, with the PD target, from pd_redirect_r and the split target
      // registers (the same signals that drive the IF redirect). Both are
      // shallow logic over registers, which keeps the PC + offset carry chain
      // off these D inputs.
      o_from_pd_to_id.btb_predicted_taken <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                              i_from_if_to_pd.btb_predicted_taken;
      // RAS prediction metadata - clear on flush/pd_redirect
      o_from_pd_to_id.ras_predicted <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                        i_from_if_to_pd.ras_predicted;
    end

    if (~i_pipeline_ctrl.stall) begin
      o_from_pd_to_id.program_counter <= i_from_if_to_pd.program_counter;
      // Early source registers, x0 for a bubble
      o_from_pd_to_id.source_reg_1_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_1;
      o_from_pd_to_id.source_reg_2_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_2;
      o_from_pd_to_id.btb_predicted_target <= i_from_if_to_pd.btb_predicted_target;
      o_from_pd_to_id.ras_predicted_target <= i_from_if_to_pd.ras_predicted_target;
      o_from_pd_to_id.ras_checkpoint_tos <= i_from_if_to_pd.ras_checkpoint_tos;
      o_from_pd_to_id.ras_checkpoint_valid_count <= i_from_if_to_pd.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      o_from_pd_to_id.bp_dir_idx <= i_from_if_to_pd.bp_dir_idx;
    end
  end

  // ===========================================================================
  // Slot-2 Pipeline Register: PD → ID
  // ===========================================================================
  // Mirror of the slot-1 register above, driven from i_from_if_to_pd_2 and
  // pd_sel_compressed_2 / instruction_non_nop_2 / source_reg_*_2. Stall and flush
  // gating apply to both slots alike, since a bundle advances as a whole.
  // pd_redirect_r squashes both slots: when the slot-1 redirect fires, the
  // wrong-path packet in PD that cycle includes slot 2.

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
      o_from_pd_to_id_2.ras_predicted       <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      // Register payload and bubble control independently. Applying the
      // registered marker in ID keeps sel_nop, flush, and pd_redirect_r off the
      // BRAM-to-slot-2-instruction D path, with no added PD-to-ID latency.
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
      o_from_pd_to_id_2.ras_predicted <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                          i_from_if_to_pd_2.ras_predicted;
    end

    if (~i_pipeline_ctrl.stall) begin
      o_from_pd_to_id_2.program_counter <= i_from_if_to_pd_2.program_counter;
      o_from_pd_to_id_2.btb_predicted_target <= i_from_if_to_pd_2.btb_predicted_target;
      o_from_pd_to_id_2.ras_predicted_target <= i_from_if_to_pd_2.ras_predicted_target;
      o_from_pd_to_id_2.ras_checkpoint_tos <= i_from_if_to_pd_2.ras_checkpoint_tos;
      o_from_pd_to_id_2.ras_checkpoint_valid_count <= i_from_if_to_pd_2.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      o_from_pd_to_id_2.bp_dir_idx <= i_from_if_to_pd_2.bp_dir_idx;
    end
  end

  // Slot 2's early source fields behave like slot 1's, but apply invalidation
  // as a synchronous register clear instead of a mux on every data bit. The
  // clear includes !stall because a bubble or flush arriving during a held
  // cycle must not overwrite the held source addresses before the bundle
  // advances. Vivado can then map the payload to D, !stall to CE, and this term
  // to R, which takes the last LUT off the IMEM-data-to-source-field paths with
  // no added latency.
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
