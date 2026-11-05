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
  which it reassembles slot 2's instruction, and raises the PD redirect when a
  slot-1 conditional branch's final direction differs from the BTB direction
  IF followed, or when the backing BTB predicts a JAL or JALR in either slot
  that the BTB did not predict taken (see that section).

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
    // inject_nop. Only a backing BTB prediction redirects for slot 2.
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id_2,
    // IF's backing BTB result for each slot (index 0 is slot 1): a hit, the
    // entry's size and return type, and target bits [PhysAddrBits-1:1].
    input logic [1:0] i_backing_hit,
    input logic [1:0] i_backing_compressed,
    input logic [1:0] i_backing_return,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target,
    // Redirect to IF, and the new direction: taken redirects to the branch
    // target, not taken to the fall-through. It fires for a slot-1
    // conditional branch whose final direction differs from the BTB
    // direction IF followed, and for a backing BTB prediction. See the PD
    // redirect section below.
    output logic o_pd_redirect,
    output logic o_pd_redirect_taken,
    output logic [XLEN-1:0] o_pd_redirect_target,
    // The redirect is a backing BTB prediction for slot 2, to which ID then
    // applies it instead of slot 1.
    output logic o_pd_redirect_slot2,
    // The redirect's return address stack operation, for a backing BTB
    // prediction of a call (push the link address), a return (pop), or a
    // coroutine swap (both). IF performs it once per redirected instruction.
    output logic o_pd_redirect_ras_push,
    output logic o_pd_redirect_ras_pop,
    output logic [XLEN-1:0] o_pd_redirect_ras_link,
    // A firing backing BTB redirect, and the PC of the instruction whose
    // entry it used, for the backing BTB's replacement state.
    output logic o_pd_backing_refresh,
    output logic [XLEN-1:0] o_pd_backing_refresh_pc,
    // Each slot's conditional-branch decode, before validity qualification,
    // for the tagged predictor's saved lookups.
    output logic [1:0] o_cond_branch
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
  // Driven from i_from_if_to_pd_2. A slot-1 branch ends its bundle in the
  // aligner, so a slot-1 redirect's packet never has a valid slot 2, and a
  // slot-2 redirect's slot 1 is not control flow.

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
  // PD Redirect: Final Direction Differs From the BTB
  // ===========================================================================
  // A slot-1 conditional branch whose final direction differs from the BTB
  // direction IF followed redirects IF instead of waiting to resolve as a
  // misprediction: to PC + offset, for either offset sign, when it is taken
  // without a taken BTB prediction, and to the fall-through when the tagged
  // predictor says not taken after a taken BTB prediction. The direction
  // candidates are described where they are formed below.
  //
  // A JAL or JALR in either slot that the BTB did not predict taken redirects
  // when the backing BTB hits for it with an entry of the same size: to the
  // entry's target, or to the stack's top while the stack holds an entry when
  // the entry was trained on a return, with the stack operation that the
  // instruction's encoding names. Execution checks the target like any
  // prediction's.
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

  always_ff @(posedge i_clk) begin
    if (pd_reset_seen_q && !i_pipeline_ctrl.reset && !$isunknown(
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

  // Direction candidates. A slot-1 conditional branch's final direction comes
  // from the tagged predictor when one of its entries matched, and otherwise
  // from the BTB, which the bimodal predictor can turn from a miss or a
  // not-taken hit into taken. PD redirects only when the final direction
  // differs from the BTB direction that IF followed:
  //   taken: the final direction is taken. It fires when the BTB did not
  //          predict taken and redirects to the branch target.
  //   not-taken: the tagged predictor says not taken. It fires when the BTB
  //          predicted taken and redirects to the fall-through.
  // The two candidates are exclusive. They are registered apart from the
  // packet's redirect vetoes, which qualify them after the register for
  // timing.
  logic pd_cond_branch;
  logic pd_taken_candidate;
  logic pd_not_taken_candidate;
  logic pd_taken_candidate_r;
  logic pd_not_taken_candidate_r;
  logic pd_redirect_r;
  logic pd_backing_redirect_r;
  logic pd_backing_redirect_2_r;
  assign pd_cond_branch = pd_native_branch || pd_compressed_branch;
  // Slot 2's effective instruction is already expanded, so its opcode alone
  // marks a conditional branch.
  assign o_cond_branch[0] = pd_cond_branch;
  assign o_cond_branch[1] = i_from_if_to_pd_2.effective_instr[6:0] == riscv_pkg::OPC_BRANCH;
  assign pd_taken_candidate = pd_cond_branch &&
      (i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken : i_from_if_to_pd.bp_dir_taken);
  assign pd_not_taken_candidate = pd_cond_branch && i_from_if_to_pd.tage_valid &&
                                  !i_from_if_to_pd.tage_taken;

  // Backing BTB candidates, one per slot: a JAL or JALR (funct3 000, as in
  // instruction_type_decoder) with a hit of the same size. Slot 1's
  // fields are its native word's or its RV64C expansion's
  // (rvc_extra_predecoded).
  //
  // The target registers' data muxes take their controls from slot 1's
  // branch decode and the backing BTB's registered tag fields, never from
  // the jump or return decodes. A packet whose slot 1 is not a conditional
  // branch loads the backing target: slot 1's entry when slot 1 hits and
  // slot 2's otherwise, or the stack's top when that entry was trained on a
  // return and the stack holds an entry. A jump in slot 1 leaves no valid
  // slot 2, and a valid slot 2 follows a slot 1 that is not control flow, so
  // every redirect takes its own slot's entry unless an entry does not match
  // its instruction, which costs only a misprediction. A hit in
  // slot 2 lies in slot 1's 4 GiB region (the backing BTB gives the word
  // after the last set no slot-2 hit), so slot 1's PC supplies the upper
  // bits.
  //
  // The redirect's stack operation is the one the redirecting instruction's
  // encoding names, decoded from PD's registered instruction in the redirect
  // cycle by the rules instruction_type_decoder and recovery use: a JAL or
  // JALR that links (rd x1 or x5) pushes, and a JALR with rs1 x1, a zero
  // immediate, and rd x0 or x5 pops.
  function automatic logic is_jalr(input logic [31:0] instruction);
    is_jalr = (instruction[6:0] == riscv_pkg::OPC_JALR) && (instruction[14:12] == 3'b000);
  endfunction
  function automatic logic is_jump(input logic [31:0] instruction);
    is_jump = (instruction[6:0] == riscv_pkg::OPC_JAL) || is_jalr(instruction);
  endfunction
  function automatic logic is_call(input logic [31:0] instruction);
    is_call = is_jump(instruction) && ((instruction[11:7] == 5'd1) || (instruction[11:7] == 5'd5));
  endfunction
  function automatic logic is_return(input logic [31:0] instruction);
    is_return = is_jalr(instruction) && (instruction[19:15] == 5'd1) &&
        (instruction[31:20] == 12'd0) &&
        ((instruction[11:7] == 5'd0) || (instruction[11:7] == 5'd5));
  endfunction
  logic pd_slot1_jump;
  logic pd_slot2_jump;
  logic pd_backing_target_return;
  logic pd_backing_candidate;
  logic pd_backing_candidate_2;
  logic pd_backing_candidate_r;
  logic pd_backing_candidate_2_r;
  logic pd_backing_target_select;
  logic [XLEN-1:0] pd_backing_target;
  assign pd_slot1_jump = is_jump(instruction_non_nop_predecoded_rs2);
  assign pd_slot2_jump = is_jump(i_from_if_to_pd_2.effective_instr);
  assign pd_backing_candidate = pd_slot1_jump && i_backing_hit[0] &&
                                (i_backing_compressed[0] == pd_sel_compressed);
  assign pd_backing_candidate_2 = pd_slot2_jump && i_backing_hit[1] &&
                                  (i_backing_compressed[1] == pd_sel_compressed_2);
  assign pd_backing_target_select = !pd_cond_branch;
  // Both slots share the packet's stack recovery point.
  assign pd_backing_target_return =
      (i_backing_hit[0] ? i_backing_return[0] : i_backing_return[1]) &&
      (i_from_if_to_pd.ras_checkpoint_valid_count != '0);
  assign pd_backing_target = pd_backing_target_return ? i_from_if_to_pd.ras_checkpoint_top : {
    i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
    i_backing_hit[0] ? i_backing_target[0] : i_backing_target[1],
    1'b0
  };

  // The packet carries same-edge vetoes: predicted taken, inject_nop, and
  // fetch fault. A redirect sets inject_nop on the following wrong-path
  // packet, masking its candidates. Candidates and packet share the stall
  // enable; reset and flush clear the candidates. Gating fetch_fault with
  // !sel_nop is safe because inject_nop already vetoes sel_nop. Each backing
  // candidate takes its own slot's vetoes.
  assign pd_backing_redirect_r = pd_backing_candidate_r &&
      !o_from_pd_to_id.btb_predicted_taken && !o_from_pd_to_id.inject_nop &&
      !o_from_pd_to_id.fetch_fault;
  assign pd_backing_redirect_2_r = pd_backing_candidate_2_r &&
      !o_from_pd_to_id_2.btb_predicted_taken && !o_from_pd_to_id_2.inject_nop &&
      !o_from_pd_to_id_2.fetch_fault;
  assign pd_redirect_r =
      (((pd_taken_candidate_r && !o_from_pd_to_id.btb_predicted_taken) ||
        (pd_not_taken_candidate_r && o_from_pd_to_id.btb_predicted_taken)) &&
       !o_from_pd_to_id.inject_nop &&
       !o_from_pd_to_id.fetch_fault) ||
      pd_backing_redirect_r || pd_backing_redirect_2_r;

  // IF's redirect depends only on PD registers. It costs two bubbles; both
  // slots of the wrong-path packet entering PD behind the branch are
  // squashed through inject_nop.
  // The format candidates, the fall-through, and their selects load on the
  // same enabled edge, so the mux after them equals one register of the
  // selected target.
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_target_native_low_r;
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_target_compressed_low_r;
  (* keep = "true" *) logic [1:0] pd_redirect_target_native_high_select_r;
  (* keep = "true" *) logic [1:0] pd_redirect_target_compressed_high_select_r;
  (* keep = "true" *) logic pd_redirect_target_compressed_r;
  (* keep = "true" *) logic [PdTargetSplit-1:0] pd_redirect_pc_low_r;
  (* keep = "true" *) logic pd_redirect_fall_through_select_r;
  logic [PdTargetSplit:0] pd_redirect_fall_through;
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
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) begin
      pd_taken_candidate_r     <= 1'b0;
      pd_not_taken_candidate_r <= 1'b0;
      pd_backing_candidate_r   <= 1'b0;
      pd_backing_candidate_2_r <= 1'b0;
    end else if (!i_pipeline_ctrl.stall) begin
      pd_taken_candidate_r     <= pd_taken_candidate;
      pd_not_taken_candidate_r <= pd_not_taken_candidate;
      pd_backing_candidate_r   <= pd_backing_candidate;
      pd_backing_candidate_2_r <= pd_backing_candidate_2;
    end
  end

  // A packet whose slot 1 is not a conditional branch loads the backing
  // target as the native target with PC-high selected, and its fall-through
  // and compressed-format selects stay clear.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_redirect_target_native_low_r <= pd_backing_target_select ?
          pd_backing_target[PdTargetSplit-1:0] : pd_target_native_low_candidate;
      pd_redirect_target_compressed_low_r <= pd_target_compressed_low_candidate;
      pd_redirect_target_native_high_select_r <= pd_backing_target_select ?
          2'b00 : pd_target_native_high_select;
      pd_redirect_target_compressed_high_select_r <= pd_target_compressed_high_select;
      pd_redirect_target_compressed_r <= pd_compressed_branch;
      pd_redirect_pc_low_r <= i_from_if_to_pd.program_counter[PdTargetSplit-1:0];
      pd_redirect_fall_through_select_r <= pd_not_taken_candidate;
      pd_redirect_pc_high_r <= pd_backing_target_select ?
          pd_backing_target[XLEN-1:PdTargetSplit] :
          i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit];
      pd_redirect_pc_high_plus_one_r <= pd_pc_high_plus_one;
      pd_redirect_pc_high_minus_one_r <= pd_pc_high_minus_one;
    end
  end

  // A copy of the not-taken candidate with the target registers' enable
  // selects the fall-through and the redirect direction. While either
  // candidate register is set it equals the not-taken one: both loaded on the
  // same unstalled edge, and only a flush, which clears the candidates,
  // separates them.
  //
  // The fall-through of a not-taken redirect is the branch's PC plus its
  // size, in the same split form as the targets, added after the registers:
  // the target paths have slack for it, and the late size decode stays out.
  // A conditional branch is compressed exactly when pd_compressed_branch is
  // set, so its register picks the size. The high select is {0, carry}, which
  // picks PC-high or PC-high + 1.
  assign pd_redirect_fall_through = {1'b0, pd_redirect_pc_low_r} +
      (pd_redirect_target_compressed_r ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                                         (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_redirect_target_low = pd_redirect_fall_through_select_r ?
      pd_redirect_fall_through[PdTargetSplit-1:0] :
      pd_redirect_target_compressed_r ? pd_redirect_target_compressed_low_r :
                                        pd_redirect_target_native_low_r;
  assign pd_redirect_target_high_select = pd_redirect_fall_through_select_r ?
      {1'b0, pd_redirect_fall_through[PdTargetSplit]} :
      pd_redirect_target_compressed_r ? pd_redirect_target_compressed_high_select_r :
                                        pd_redirect_target_native_high_select_r;
  assign pd_redirect_target_high = select_pd_target_high(
      pd_redirect_target_high_select,
      pd_redirect_pc_high_r,
      pd_redirect_pc_high_plus_one_r,
      pd_redirect_pc_high_minus_one_r
  );

  assign o_pd_redirect = pd_redirect_r;
  assign o_pd_redirect_taken = !pd_redirect_fall_through_select_r;
  assign o_pd_redirect_target = {pd_redirect_target_high, pd_redirect_target_low};
  assign o_pd_redirect_slot2 = pd_backing_redirect_2_r;
  logic pd_registered_call, pd_registered_call_2;
  logic pd_registered_return, pd_registered_return_2;
  assign pd_registered_call = is_call(o_from_pd_to_id.instruction);
  assign pd_registered_call_2 = is_call(o_from_pd_to_id_2.instruction);
  assign pd_registered_return = is_return(o_from_pd_to_id.instruction);
  assign pd_registered_return_2 = is_return(o_from_pd_to_id_2.instruction);
  assign o_pd_redirect_ras_push = (pd_backing_redirect_r && pd_registered_call) ||
                                  (pd_backing_redirect_2_r && pd_registered_call_2);
  assign o_pd_redirect_ras_pop = (pd_backing_redirect_r && pd_registered_return) ||
                                 (pd_backing_redirect_2_r && pd_registered_return_2);
  assign o_pd_backing_refresh = pd_backing_redirect_r || pd_backing_redirect_2_r;
  assign o_pd_backing_refresh_pc = pd_backing_redirect_r ? o_from_pd_to_id.program_counter :
                                                           o_from_pd_to_id_2.program_counter;
  assign o_pd_redirect_ras_link = pd_backing_redirect_2_r ?
      o_from_pd_to_id_2.program_counter + (o_from_pd_to_id_2.is_compressed ?
          XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit)) :
      o_from_pd_to_id.program_counter + (o_from_pd_to_id.is_compressed ?
          XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit));

`ifndef SYNTHESIS
  // Compare against registering the selected target on the same edge, with
  // the fall-through from the packet's PC.
  logic [PdTargetSplit:0] pd_fall_through_sum;
  assign pd_fall_through_sum = {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      (pd_sel_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                           (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  logic pd_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) pd_reset_seen_q <= 1'b1;
  end
  logic [PdTargetSplit-1:0] pd_redirect_target_low_reference_r;
  logic [1:0] pd_redirect_target_high_select_reference_r;
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_redirect_target_low_reference_r <= pd_not_taken_candidate ?
          pd_fall_through_sum[PdTargetSplit-1:0] :
          (pd_backing_target_select ? pd_backing_target[PdTargetSplit-1:0] :
                                      pd_target_selected_low);
      pd_redirect_target_high_select_reference_r <= pd_not_taken_candidate ?
          {1'b0, pd_fall_through_sum[PdTargetSplit]} :
          (pd_backing_target_select ? 2'b00 : pd_target_selected_high_select);
    end
  end
  always_ff @(posedge i_clk) begin
    if (pd_reset_seen_q && pd_redirect_target_reference_armed && !$isunknown(
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
  // Reference model of the candidate FFs: reset and flush clear them even
  // during a stall, a stall holds them, and every enabled edge captures the
  // branch and its directions with no feedback from the qualified redirect.
  // The two candidates are never set together.
  logic pd_taken_candidate_payload_reference_q;
  logic pd_not_taken_candidate_payload_reference_q;
  logic pd_redirect_candidate_payload_reference_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_taken_candidate_payload_reference_q <= 1'b0;
      pd_not_taken_candidate_payload_reference_q <= 1'b0;
      pd_redirect_candidate_payload_reference_armed <= 1'b1;
    end else begin
      if (pd_redirect_candidate_payload_reference_armed && !$isunknown(
              {
                pd_taken_candidate_r,
                pd_not_taken_candidate_r,
                pd_redirect_fall_through_select_r,
                pd_taken_candidate_payload_reference_q,
                pd_not_taken_candidate_payload_reference_q
              }
          )) begin
        p_pd_taken_candidate_payload_exact :
        assert (pd_taken_candidate_r == pd_taken_candidate_payload_reference_q);
        p_pd_not_taken_candidate_payload_exact :
        assert (pd_not_taken_candidate_r == pd_not_taken_candidate_payload_reference_q);
        p_pd_redirect_candidates_exclusive :
        assert (!(pd_taken_candidate_r && pd_not_taken_candidate_r));
        p_pd_redirect_fall_through_select_matches_candidate :
        assert (!(pd_taken_candidate_r || pd_not_taken_candidate_r) ||
                (pd_redirect_fall_through_select_r == pd_not_taken_candidate_r));
      end

      if (i_pipeline_ctrl.flush) begin
        pd_taken_candidate_payload_reference_q <= 1'b0;
        pd_not_taken_candidate_payload_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_taken_candidate_payload_reference_q <=
            (pd_native_branch || pd_compressed_branch) &&
            (i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken :
                                          i_from_if_to_pd.bp_dir_taken);
        pd_not_taken_candidate_payload_reference_q <=
            (pd_native_branch || pd_compressed_branch) &&
            i_from_if_to_pd.tage_valid && !i_from_if_to_pd.tage_taken;
        pd_redirect_candidate_payload_reference_armed <= 1'b1;
      end
    end
  end

  // Compare with a register of the fully qualified redirect and its
  // direction. The packet's inject_nop accounts for sel_nop and the previous
  // redirect; the other vetoes are the BTB direction and fetch fault. Shared
  // enables preserve this alignment across stalls, and reset or flush clears
  // the candidates. Compare before nonblocking updates to avoid delta-cycle
  // races.
  logic pd_redirect_reference_q;
  logic pd_redirect_taken_reference_q;
  logic pd_redirect_reference_armed = 1'b0;
  logic pd_final_taken_reference;
  logic pd_redirect_reference_next;
  assign pd_final_taken_reference =
      i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken :
      (i_from_if_to_pd.btb_predicted_taken || i_from_if_to_pd.bp_dir_taken);
  logic pd_backing_reference_next;
  logic pd_backing_reference_next_2;
  assign pd_backing_reference_next = pd_slot1_jump && i_backing_hit[0] &&
      (i_backing_compressed[0] == pd_sel_compressed) &&
      !i_from_if_to_pd.btb_predicted_taken && !i_from_if_to_pd.sel_nop &&
      !i_from_if_to_pd.fetch_fault;
  assign pd_backing_reference_next_2 = pd_slot2_jump && i_backing_hit[1] &&
      (i_backing_compressed[1] == pd_sel_compressed_2) &&
      !i_from_if_to_pd_2.btb_predicted_taken && !i_from_if_to_pd_2.sel_nop &&
      !i_from_if_to_pd_2.fetch_fault;
  assign pd_redirect_reference_next =
      (((pd_native_branch || pd_compressed_branch) &&
        (pd_final_taken_reference != i_from_if_to_pd.btb_predicted_taken) &&
        !i_from_if_to_pd.sel_nop &&
        !i_from_if_to_pd.fetch_fault) ||
       pd_backing_reference_next || pd_backing_reference_next_2) &&
      !pd_redirect_reference_q;

  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_reference_q <= 1'b0;
      pd_redirect_reference_armed <= 1'b1;
    end else begin
      if (pd_redirect_reference_armed && !$isunknown(
              {pd_redirect_r, pd_redirect_reference_q, o_pd_redirect_taken,
               pd_redirect_taken_reference_q}
          )) begin
        p_pd_redirect_registered_veto_exact : assert (pd_redirect_r == pd_redirect_reference_q);
        p_pd_redirect_direction_exact :
        assert (!pd_redirect_r || (o_pd_redirect_taken == pd_redirect_taken_reference_q));
      end

      if (i_pipeline_ctrl.flush) begin
        pd_redirect_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_redirect_reference_q <= pd_redirect_reference_next;
        pd_redirect_taken_reference_q <=
            (pd_backing_reference_next || pd_backing_reference_next_2) ||
            pd_final_taken_reference;
        pd_redirect_reference_armed <= 1'b1;
      end
    end
  end

  // A full-width reference sampled on the same enabled edges checks target
  // alignment, stall hold, and the target, fall-through, and format
  // selection.
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
        pd_redirect_target_reference_q <= pd_not_taken_candidate ?
            i_from_if_to_pd.program_counter +
            (pd_sel_compressed ? XLEN'(riscv_pkg::PcIncrementCompressed) :
                                 XLEN'(riscv_pkg::PcIncrement32bit)) :
            (pd_backing_target_select ? pd_backing_target : pd_backward_target_reference);
        pd_redirect_target_reference_armed <= 1'b1;
      end
    end
  end

  // A firing backing redirect takes the target its own instruction's decode
  // names, the stack's top for a return while the stack holds an entry and
  // its slot's entry otherwise, whenever the entry's return type matches that
  // decode and, for slot 2, slot 1 has no hit and no fetch fault. A faulting
  // slot 1's bytes are arbitrary and can decode as a conditional branch,
  // which selects the direction target; its trap squashes the redirect.
  logic [XLEN-1:0] pd_backing_decoded_target_reference_q;
  logic [XLEN-1:0] pd_backing_decoded_target_reference_2_q;
  logic pd_backing_decoded_reference_valid_q;
  logic pd_backing_decoded_reference_valid_2_q;
  logic pd_backing_decoded_reference_armed = 1'b0;
  logic pd_backing_stack_holds_entry;
  logic pd_slot1_return_reference, pd_slot2_return_reference;
  assign pd_backing_stack_holds_entry = i_from_if_to_pd.ras_checkpoint_valid_count != '0;
  assign pd_slot1_return_reference = is_return(instruction_non_nop_predecoded_rs2);
  assign pd_slot2_return_reference = is_return(i_from_if_to_pd_2.effective_instr);
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_backing_decoded_reference_armed <= 1'b0;
    end else begin
      if (pd_backing_decoded_reference_armed && !$isunknown(
              {
                pd_backing_redirect_r,
                pd_backing_redirect_2_r,
                pd_backing_decoded_reference_valid_q,
                pd_backing_decoded_reference_valid_2_q
              }
          )) begin
        p_pd_backing_slot1_target_matches_decode :
        assert (!(pd_backing_redirect_r && pd_backing_decoded_reference_valid_q) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_q));
        p_pd_backing_slot2_target_matches_decode :
        assert (!(pd_backing_redirect_2_r && !pd_backing_redirect_r &&
                  pd_backing_decoded_reference_valid_2_q) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_2_q));
      end
      if (!i_pipeline_ctrl.stall) begin
        pd_backing_decoded_target_reference_q <=
            (pd_slot1_return_reference && pd_backing_stack_holds_entry) ?
            i_from_if_to_pd.ras_checkpoint_top :
            {i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits], i_backing_target[0],
             1'b0};
        pd_backing_decoded_target_reference_2_q <=
            (pd_slot2_return_reference && pd_backing_stack_holds_entry) ?
            i_from_if_to_pd.ras_checkpoint_top :
            {i_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
             i_backing_target[1], 1'b0};
        pd_backing_decoded_reference_valid_q <= i_backing_return[0] == pd_slot1_return_reference;
        pd_backing_decoded_reference_valid_2_q <= !i_backing_hit[0] &&
            !i_from_if_to_pd.fetch_fault && (i_backing_return[1] == pd_slot2_return_reference);
        pd_backing_decoded_reference_armed <= 1'b1;
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

`ifdef FORMAL
  // ===========================================================================
  // Formal model (formal/pd_backing_redirect.sby)
  // ===========================================================================
  // The simulation checks above run only when their operands are known
  // (!$isunknown), which Yosys evaluates as false, so the properties they
  // state are restated here without that gate. IF's
  // RV64C expansions and target candidates match the packet's instruction,
  // as those checks state. A slot-2 backing hit lies in slot 1's 4 GiB
  // region, which backing_btb guarantees by giving the word after its last
  // set no slot-2 hit (formal/backing_btb.sby), and IF pairs a slot 2 behind
  // a slot 1 that decodes as a conditional branch only when slot 1 faults,
  // since a fault response carries arbitrary bytes and predecode metadata.
  logic formal_past_valid = 1'b0;
  logic [1:0] formal_backing_compressed_q;
  logic [31:0] formal_slot1_instruction_q;
  logic [31:0] formal_slot2_instruction_q;
  always_ff @(posedge i_clk) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (i_pipeline_ctrl.reset);
    assume (!i_backing_hit[1] ||
            (i_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] ==
             i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits]));
    assume (i_from_if_to_pd_2.sel_nop || !pd_cond_branch || i_from_if_to_pd.fetch_fault);
    if (!i_pipeline_ctrl.stall) begin
      formal_backing_compressed_q <= i_backing_compressed;
      formal_slot1_instruction_q  <= instruction_non_nop;
      formal_slot2_instruction_q  <= instruction_non_nop_2;
    end
  end

  always_comb begin
    if (!i_from_if_to_pd.sel_nop && !i_from_if_to_pd.fetch_fault) begin
      assume (!pd_sel_compressed || ((instruction_non_nop_predecoded_rs2 == instruction_non_nop) &&
                                     (decomp_illegal == decomp_illegal_reference)));
      assume (i_from_if_to_pd.source_hot_predecoded ==
              {instruction_non_nop[21], instruction_non_nop[17:16]});
      assume (i_from_if_to_pd.rs1_rest_predecoded ==
              {instruction_non_nop[19:18], instruction_non_nop[15]});
      assume (i_from_if_to_pd.bits24_20_predecoded == instruction_non_nop[24:20]);
    end
    if (!i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault) begin
      assume (pd_sel_compressed_2 == (i_from_if_to_pd_2.raw_parcel[1:0] != 2'b11));
      assume (!pd_sel_compressed_2 || ((instruction_non_nop_2 == decompressed_instr_2) &&
                                       (i_from_if_to_pd_2.decomp_illegal ==
                                        decomp_illegal_reference_2)));
      assume (i_from_if_to_pd_2.source_hot_predecoded ==
              {instruction_non_nop_2[21], instruction_non_nop_2[17:16]});
      assume (source_reg_1_2 == instruction_non_nop_2[19:15]);
      assume (source_reg_2_2 == instruction_non_nop_2[24:20]);
      assume (source_reg_1_2[2:1] == i_from_if_to_pd_2.source_hot_predecoded[1:0]);
    end
    assume (pd_target_native_split == pd_target_native_reference);
    assume (pd_target_compressed_split == pd_target_compressed_reference);
  end

  logic formal_registered_jump, formal_registered_jump_2;
  logic [XLEN-1:0] formal_redirect_pc;
  assign formal_registered_jump = is_jump(o_from_pd_to_id.instruction);
  assign formal_registered_jump_2 = is_jump(o_from_pd_to_id_2.instruction);
  assign formal_redirect_pc = pd_backing_redirect_r ? o_from_pd_to_id.program_counter :
                                                      o_from_pd_to_id_2.program_counter;
  always_comb begin
    if (formal_past_valid && !i_pipeline_ctrl.reset) begin
      // A backing redirect fires for its slot's registered JAL or JALR, of
      // the entry's size, and never with the slot's fast-taken prediction,
      // bubble or fetch fault. A slot-2 redirect has a valid slot 2.
      if (pd_backing_redirect_r) begin
        p_formal_slot1_redirect_is_its_jump :
        assert (formal_registered_jump &&
                (o_from_pd_to_id.is_compressed == formal_backing_compressed_q[0]) &&
                !o_from_pd_to_id.btb_predicted_taken && !o_from_pd_to_id.inject_nop &&
                !o_from_pd_to_id.fetch_fault);
      end
      if (pd_backing_redirect_2_r) begin
        p_formal_slot2_redirect_is_its_jump :
        assert (formal_registered_jump_2 &&
                (o_from_pd_to_id_2.is_compressed == formal_backing_compressed_q[1]) &&
                !o_from_pd_to_id_2.btb_predicted_taken && !o_from_pd_to_id_2.inject_nop &&
                !o_from_pd_to_id_2.fetch_fault);
      end
      if (o_pd_redirect_slot2) begin
        p_formal_slot2_flag_is_a_slot2_redirect :
        assert (pd_backing_redirect_2_r && !o_from_pd_to_id_2.inject_nop);
      end
      // The registered instruction that names the stack operation is the
      // redirecting slot's instruction.
      if (pd_backing_redirect_r) begin
        p_formal_slot1_registered_instruction :
        assert (o_from_pd_to_id.instruction == formal_slot1_instruction_q);
      end
      if (pd_backing_redirect_2_r) begin
        p_formal_slot2_registered_instruction :
        assert (o_from_pd_to_id_2.instruction == formal_slot2_instruction_q);
      end
      // A stack operation comes only with a backing redirect of a call or a
      // return, by the redirecting instruction's encoding.
      if (o_pd_redirect_ras_push) begin
        p_formal_push_is_a_redirected_call :
        assert ((pd_backing_redirect_r && pd_registered_call) ||
                (pd_backing_redirect_2_r && pd_registered_call_2));
      end
      if (o_pd_redirect_ras_pop) begin
        p_formal_pop_is_a_redirected_return :
        assert ((pd_backing_redirect_r && pd_registered_return) ||
                (pd_backing_redirect_2_r && pd_registered_return_2));
      end
      // A refresh names the redirecting slot's PC.
      if (o_pd_backing_refresh) begin
        p_formal_refresh_is_a_backing_redirect :
        assert (o_pd_redirect && (o_pd_backing_refresh_pc == formal_redirect_pc));
      end
      // The reference models above: the qualified redirect and its
      // direction, the full-width target, and each backing redirect's
      // decoded-rule target.
      if (pd_redirect_reference_armed) begin
        p_formal_redirect_matches_reference : assert (pd_redirect_r == pd_redirect_reference_q);
        p_formal_direction_matches_reference :
        assert (!pd_redirect_r || (o_pd_redirect_taken == pd_redirect_taken_reference_q));
      end
      if (pd_redirect_target_reference_armed) begin
        p_formal_target_matches_reference :
        assert (o_pd_redirect_target == pd_redirect_target_reference_q);
      end
      if (pd_backing_decoded_reference_armed) begin
        p_formal_slot1_target_matches_decode :
        assert (!(pd_backing_redirect_r && pd_backing_decoded_reference_valid_q) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_q));
        p_formal_slot2_target_matches_decode :
        assert (!(pd_backing_redirect_2_r && !pd_backing_redirect_r &&
                  pd_backing_decoded_reference_valid_2_q) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_2_q));
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (formal_past_valid && !i_pipeline_ctrl.reset) begin
      cover (pd_backing_redirect_r && !o_pd_redirect_ras_push && !o_pd_redirect_ras_pop);
      cover (pd_backing_redirect_2_r && o_pd_redirect_ras_push);
      cover (pd_backing_redirect_r && o_pd_redirect_ras_pop &&
             (o_pd_redirect_target == o_from_pd_to_id.ras_checkpoint_top));
      cover (pd_backing_redirect_2_r && o_pd_redirect_ras_pop);
      cover (pd_backing_redirect_r && i_pipeline_ctrl.stall);
      cover (pd_redirect_r && !pd_backing_redirect_r && !pd_backing_redirect_2_r &&
             pd_redirect_reference_armed && pd_redirect_target_reference_armed);
      cover (pd_backing_redirect_r && pd_backing_decoded_reference_armed &&
             pd_backing_decoded_reference_valid_q);
      cover (pd_backing_redirect_2_r && !pd_backing_redirect_r &&
             pd_backing_decoded_reference_armed && pd_backing_decoded_reference_valid_2_q);
    end
  end
`endif

endmodule : pd_stage
