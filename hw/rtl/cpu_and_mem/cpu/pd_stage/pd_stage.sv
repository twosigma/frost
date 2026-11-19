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
  conditional branch's final direction differs from the BTB direction IF
  followed (tagged or bimodal in slot 1, tagged in slot 2), when the backing
  BTB predicts a JAL or JALR in either slot that the BTB did not predict taken
  (see that section), or when the indirect target predictor gives a JALR that
  is not a return a target other than the one the BTB predicted.

  Both slots register the instruction without rewriting it to a NOP. A bubble
  (flush, PD redirect, or sel_nop) rides in inject_nop, which ID applies before
  decode, and a bubble's early source fields are x0. An older illegal compressed
  instruction also bubbles slot 2 while its own trap advances. PD and ID flush on
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
    // inject_nop. A backing jump, tagged branch direction, or indirect target
    // can redirect for slot 2.
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id_2,
    // IF's backing BTB result for each slot (index 0 is slot 1): a hit, the
    // entry's size and return type, and target bits [PhysAddrBits-1:1].
    input logic [1:0] i_backing_hit,
    input logic [1:0] i_backing_compressed,
    input logic [1:0] i_backing_return,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target,
    // Slot 2's return type and target for each size of slot 1 (index 1:
    // compressed). The entries at the packet's sel_compressed are
    // i_backing_return[1] and i_backing_target[1]; the redirect target
    // registers take slot 2's from these, so slot 1's size selects last.
    input logic [1:0] i_backing_slot2_return_by_size,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_slot2_target_by_size,
    // IF's indirect target predictor result for each slot: a hit and target
    // bits [PhysAddrBits-1:1]; the upper bits come from the JALR's own PC.
    input logic [1:0] i_itt_hit,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_itt_target,
    // Redirect to IF, and the new direction: taken redirects to the branch
    // target, not taken to the fall-through. It fires for a conditional
    // branch whose final direction differs from the BTB direction IF
    // followed, for a backing jump, or for a non-return indirect target.
    output logic o_pd_redirect,
    output logic o_pd_redirect_taken,
    output logic [XLEN-1:0] o_pd_redirect_target,
    // ID applies this redirect to slot 2's effective prediction.
    output logic o_pd_redirect_slot2,
    // A backing call, return or coroutine swap pushes, pops or exchanges
    // the stack top. An indirect-target call can also push its link. IF
    // applies the operation once per redirected instruction.
    output logic o_pd_redirect_ras_push,
    output logic o_pd_redirect_ras_pop,
    output logic [XLEN-1:0] o_pd_redirect_ras_link,
    // A firing backing BTB redirect, and the PC of the instruction whose
    // entry it used, for the backing BTB's replacement state.
    output logic o_pd_backing_refresh,
    output logic [XLEN-1:0] o_pd_backing_refresh_pc,
    // Each slot's conditional-branch decode, before validity qualification,
    // for the tagged predictor's saved lookups.
    output logic [1:0] o_cond_branch,
    // Each slot's JALR decode, and whether it is one the indirect target
    // predictor covers (not a return), for the saved lookups.
    output logic [1:0] o_jalr,
    output logic [1:0] o_itt_eligible,
    // Each slot's JAL or JALR decode and its direction-history bit: a
    // conditional branch's final predicted direction (the direction ID
    // applies), or a jump's predicted target bit 2.
    output logic [1:0] o_jump,
    output logic [1:0] o_pred_taken,
    // Registered-packet equivalents of the control-flow and direction-history
    // outputs above, qualified with each slot's liveness for consumers acting
    // the cycle after PD accepts a packet.
    output logic [1:0] o_q_cond_branch,
    output logic [1:0] o_q_jalr,
    output logic [1:0] o_q_itt_eligible,
    output logic [1:0] o_q_cf,
    output logic [1:0] o_q_pred_taken
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
  logic pd_reset_seen_q = 1'b0;
  logic pd_redirect_target_reference_armed = 1'b0;
`ifdef FORMAL
  wire pd_sim_reset_seen_q = 1'b1;
`else
  wire pd_sim_reset_seen_q = pd_reset_seen_q;
`endif
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

  // A reserved compressed parcel or c.ebreak traps at the head of the bundle
  // while the fetch predecoder permits pairing; c.ebreak is the sole compressed
  // parcel whose expansion sets bits 6 and 4 (OPC_CSR). Keep the older trap and
  // discard its younger slot at the same PD edge, before either can steer or
  // allocate history.
  logic pd_slot1_illegal_rvc, pd_slot1_traps_rvc, pd_older_illegal, pd_slot2_nop;
  logic pd_slot2_predictable;
  assign pd_slot1_illegal_rvc = pd_sel_compressed && decomp_illegal;
  assign pd_slot1_traps_rvc = pd_sel_compressed &&
      (decomp_illegal ||
       (i_from_if_to_pd.rvc_extra_predecoded[6] && i_from_if_to_pd.rvc_extra_predecoded[4]));
  assign pd_older_illegal = pd_slot1_traps_rvc && !i_from_if_to_pd.sel_nop &&
                            !i_from_if_to_pd.fetch_fault;
  // i_from_if_to_pd.sel_nop implies i_from_if_to_pd_2.sel_nop, so slot 2's
  // bubble flag already covers a slot-1 bubble.
  assign pd_slot2_nop = i_from_if_to_pd_2.sel_nop ||
                        (pd_slot1_traps_rvc && !i_from_if_to_pd.fetch_fault);
  assign pd_slot2_predictable = !pd_older_illegal && !i_from_if_to_pd_2.decomp_illegal;

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
    // IF tags slot 2 with every fault of the words it shares with slot 1, so
    // a valid slot 2 behind a faulting slot 1 faults too, and its own veto
    // keeps it from a backing redirect.
    if (source_hot_checks_armed && !i_pipeline_ctrl.reset && !$isunknown(
            {i_from_if_to_pd.fetch_fault, i_from_if_to_pd_2.sel_nop, i_from_if_to_pd_2.fetch_fault}
        )) begin
      p_slot2_faults_behind_a_faulting_slot1 :
      assert (!i_from_if_to_pd.fetch_fault || i_from_if_to_pd_2.sel_nop ||
              i_from_if_to_pd_2.fetch_fault);
    end
  end
`endif

  // ===========================================================================
  // PD Redirect: Final Direction Differs From the BTB
  // ===========================================================================
  // A conditional branch in either slot whose final direction differs from the
  // BTB direction IF followed redirects IF instead of waiting to resolve as a
  // misprediction: to PC + offset, for either offset sign, when it is taken
  // without a taken BTB prediction (a tagged match in either slot, or slot 1's
  // bimodal fallback), and to the fall-through when a tagged match says not
  // taken after a taken BTB prediction. The direction candidates are described
  // where they are formed below.
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
  // IF carries both low sums and {sign, carry} selects in each slot's packet.
  // PD registers each slot's raw candidates, the raw backing BTB and indirect
  // target responses, 2-bit indirect target equality chunks, and slot 1's
  // PC_high with its +/-1 corrections on the packet edge. The next cycle
  // decodes the registered instructions, qualifies redirects, selects the
  // winning target, and forms the registered-packet history outputs. The full
  // target is exact modulo 2^XLEN.

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
                            (i_from_if_to_pd.effective_instr[6:0] == riscv_pkg::OPC_BRANCH) &&
                            (i_from_if_to_pd.effective_instr[14:13] != 2'b01);
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

  function automatic logic [1:0] fold_slot2_pc_carry(input logic slot2_pc_carry,
                                                     input logic [1:0] high_select);
    if (slot2_pc_carry) begin
      fold_slot2_pc_carry = (high_select == 2'b10) ? 2'b00 : 2'b01;
    end else begin
      fold_slot2_pc_carry = high_select;
    end
  endfunction

  // Slot-2 conditional-branch target operands. IF precomputes slot 2's low
  // PC+offset candidates and {sign, carry} selects relative to slot 2's PC.
  // Adding slot 1's size to slot 1's low PC gives slot 2's low PC and the
  // carry from bit 12 into bit 13, which folds into the two high-select bits
  // so both slots share slot 1's PC_high and +/-1 values without waiting on
  // IF's 64-bit slot-2 PC adder.
  logic [PdTargetSplit:0] pd_slot2_pc_sum;
  logic pd_slot2_pc_carry;
  logic [PdTargetSplit-1:0] pd_slot2_pc_low;
  logic [PdTargetSplit-1:0] pd_slot2_target_native_low_candidate;
  logic [PdTargetSplit-1:0] pd_slot2_target_compressed_low_candidate;
  logic [1:0] pd_slot2_target_native_high_select;
  logic [1:0] pd_slot2_target_compressed_high_select;
  logic [PdTargetSplit-1:0] pd_slot2_target_selected_low;
  logic [1:0] pd_slot2_target_selected_high_select;

  assign pd_slot2_pc_sum = {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      (pd_sel_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                           (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_slot2_pc_carry = pd_slot2_pc_sum[PdTargetSplit];
  assign pd_slot2_pc_low = pd_slot2_pc_sum[PdTargetSplit-1:0];
  assign pd_slot2_target_native_low_candidate = i_from_if_to_pd_2.pd_target_native_low;
  assign pd_slot2_target_compressed_low_candidate = i_from_if_to_pd_2.pd_target_compressed_low;
  assign pd_slot2_target_native_high_select = fold_slot2_pc_carry(
      pd_slot2_pc_carry, i_from_if_to_pd_2.pd_target_native_high_select
  );
  assign pd_slot2_target_compressed_high_select = fold_slot2_pc_carry(
      pd_slot2_pc_carry, i_from_if_to_pd_2.pd_target_compressed_high_select
  );
  assign pd_slot2_target_selected_low = pd_sel_compressed_2 ?
      pd_slot2_target_compressed_low_candidate : pd_slot2_target_native_low_candidate;
  assign pd_slot2_target_selected_high_select = pd_sel_compressed_2 ?
      pd_slot2_target_compressed_high_select : pd_slot2_target_native_high_select;

`ifndef SYNTHESIS
  logic [XLEN-1:0] pd_slot2_imm_b_native;
  logic [XLEN-1:0] pd_slot2_imm_b_compressed;
  logic [XLEN-1:0] pd_slot2_target_native_reference;
  logic [XLEN-1:0] pd_slot2_target_compressed_reference;
  logic [XLEN-1:0] pd_slot2_target_reference;
  logic [XLEN-1:0] pd_slot2_target_native_split;
  logic [XLEN-1:0] pd_slot2_target_compressed_split;
  logic [XLEN-1:0] pd_slot2_target_split;
  logic pd_slot2_pc_matches_slot1_step;
  assign pd_slot2_imm_b_native = {
    {(XLEN - 13) {i_from_if_to_pd_2.effective_instr[31]}},
    i_from_if_to_pd_2.effective_instr[31],
    i_from_if_to_pd_2.effective_instr[7],
    i_from_if_to_pd_2.effective_instr[30:25],
    i_from_if_to_pd_2.effective_instr[11:8],
    1'b0
  };
  assign pd_slot2_imm_b_compressed = {
    {(XLEN - 9) {i_from_if_to_pd_2.raw_parcel[12]}},
    i_from_if_to_pd_2.raw_parcel[12],
    i_from_if_to_pd_2.raw_parcel[6:5],
    i_from_if_to_pd_2.raw_parcel[2],
    i_from_if_to_pd_2.raw_parcel[11:10],
    i_from_if_to_pd_2.raw_parcel[4:3],
    1'b0
  };
  assign pd_slot2_target_native_reference = i_from_if_to_pd_2.program_counter +
                                            pd_slot2_imm_b_native;
  assign pd_slot2_target_compressed_reference = i_from_if_to_pd_2.program_counter +
                                                pd_slot2_imm_b_compressed;
  assign pd_slot2_target_reference = pd_sel_compressed_2 ?
      pd_slot2_target_compressed_reference : pd_slot2_target_native_reference;
  assign pd_slot2_target_native_split = {
    select_pd_target_high(
        pd_slot2_target_native_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_slot2_target_native_low_candidate
  };
  assign pd_slot2_target_compressed_split = {
    select_pd_target_high(
        pd_slot2_target_compressed_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_slot2_target_compressed_low_candidate
  };
  assign pd_slot2_target_split = {
    select_pd_target_high(
        pd_slot2_target_selected_high_select,
        i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
        pd_pc_high_plus_one,
        pd_pc_high_minus_one
    ),
    pd_slot2_target_selected_low
  };
  assign pd_slot2_pc_matches_slot1_step =
      i_from_if_to_pd_2.program_counter ==
      (i_from_if_to_pd.program_counter +
       (pd_sel_compressed ? XLEN'(riscv_pkg::PcIncrementCompressed) :
                            XLEN'(riscv_pkg::PcIncrement32bit)));
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
    if (pd_reset_seen_q && !i_pipeline_ctrl.reset &&
        !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault && !$isunknown(
            {
              i_from_if_to_pd_2.program_counter,
              pd_sel_compressed_2,
              pd_slot2_imm_b_native,
              pd_slot2_imm_b_compressed,
              pd_slot2_target_native_split,
              pd_slot2_target_compressed_split,
              pd_slot2_target_split,
              pd_slot2_target_reference
            }
        )) begin
      p_pd_slot2_native_target_candidate_exact :
      assert (pd_sel_compressed_2 ||
              (pd_slot2_target_native_split == pd_slot2_target_native_reference));
      p_pd_slot2_compressed_target_candidate_exact :
      assert (pd_slot2_target_compressed_split == pd_slot2_target_compressed_reference);
      p_pd_slot2_target_split_exact : assert (pd_slot2_target_split == pd_slot2_target_reference);
    end
    if (pd_reset_seen_q && !i_pipeline_ctrl.reset &&
        !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault && !$isunknown(
            {i_from_if_to_pd.program_counter, i_from_if_to_pd_2.program_counter,
             i_from_if_to_pd.raw_parcel[1:0]}
        )) begin
      p_pd_slot2_pc_matches_raw_slot1_step : assert (pd_slot2_pc_matches_slot1_step);
    end
    if (pd_reset_seen_q && !i_pipeline_ctrl.reset &&
        !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault && !$isunknown(
            {i_from_if_to_pd_2.is_cond_branch, instruction_non_nop_2[14:13],
             instruction_non_nop_2[6:0]}
        )) begin
      p_pd_slot2_cond_branch_predecode_exact :
      assert (i_from_if_to_pd_2.is_cond_branch ==
              ((instruction_non_nop_2[6:0] == riscv_pkg::OPC_BRANCH) &&
               (instruction_non_nop_2[14:13] != 2'b01)));
    end
  end
`endif

  // Direction candidates. A slot-1 conditional branch's final direction comes
  // from the tagged predictor when one of its entries matched, and otherwise
  // from the BTB, which the bimodal predictor can turn from a miss or a
  // not-taken hit into taken. A slot-2 conditional branch uses the tagged
  // predictor when one of its entries matched and keeps the BTB direction
  // otherwise. PD redirects only when the final direction differs from the
  // BTB direction that IF followed:
  //   taken: the final direction is taken. It fires when the BTB did not
  //          predict taken and redirects to the branch target.
  //   not-taken: the tagged predictor says not taken. It fires when the BTB
  //          predicted taken and redirects to the fall-through.
  // Each slot's two candidates are exclusive and registered apart from the
  // packet's redirect vetoes, which qualify them after the register.
  logic pd_cond_branch;
  logic pd_cond_branch_2;
  logic pd_taken_candidate;
  logic pd_not_taken_candidate;
  logic pd_taken_candidate_2;
  logic pd_not_taken_candidate_2;
  logic pd_taken_candidate_r;
  logic pd_not_taken_candidate_r;
  logic pd_taken_candidate_2_r;
  logic pd_not_taken_candidate_2_r;
  logic pd_dir_redirect_1_r;
  logic pd_dir_redirect_2_raw_r;
  logic pd_dir_redirect_2_r;
  logic pd_redirect_r;
  logic pd_backing_redirect_r;
  logic pd_backing_redirect_2_r;
  assign pd_cond_branch = pd_native_branch || pd_compressed_branch;
  // Predecoded per start position in instruction_aligner ahead of slot2_pos.
  assign pd_cond_branch_2 = pd_slot2_predictable && i_from_if_to_pd_2.is_cond_branch;
  assign o_cond_branch[0] = pd_cond_branch;
  assign o_cond_branch[1] = pd_cond_branch_2;
  assign pd_taken_candidate = pd_cond_branch &&
      (i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken : i_from_if_to_pd.bp_dir_taken);
  assign pd_not_taken_candidate = pd_cond_branch && i_from_if_to_pd.tage_valid &&
                                  !i_from_if_to_pd.tage_taken;
  assign pd_taken_candidate_2 = pd_cond_branch_2 && i_from_if_to_pd_2.tage_valid &&
                                i_from_if_to_pd_2.tage_taken;
  assign pd_not_taken_candidate_2 = pd_cond_branch_2 && i_from_if_to_pd_2.tage_valid &&
                                    !i_from_if_to_pd_2.tage_taken;

  // Backing BTB candidates, one per slot: a JAL or JALR (funct3 000, as in
  // instruction_type_decoder) with a hit of the same size. Slot 1's
  // fields are its native word's or its RV64C expansion's
  // (rvc_extra_predecoded).
  //
  // Slot 1's conditional branch owns the shared target registers first, then
  // a slot-1 jump (for its backing BTB target), then slot 2's conditional
  // branch, and otherwise the backing target (serving slot 2's backing hit).
  // A control-flow slot 1 ends the bundle in IF, so a valid non-faulting slot 2
  // follows a slot 1 that is neither a branch nor a jump; keeping slot 1's jump
  // decode ahead of slot 2's branch also preserves priority when slot 2's
  // unused parcel behind a jump decodes as a branch. pd_redirect_next forms
  // these selects from the decode terms; the copies here serve the checks.
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
  logic pd_native_jump;
  logic pd_rvc_jump;
  logic pd_slot1_jump;
  logic pd_slot2_jump;
  logic pd_backing_candidate;
  logic pd_backing_candidate_2;
  logic pd_backing_candidate_r;
  logic pd_backing_candidate_2_r;
  assign pd_native_jump = is_jump(i_from_if_to_pd.effective_instr);
  assign pd_rvc_jump = !decomp_illegal &&
      ((i_from_if_to_pd.rvc_extra_predecoded[6:0] == riscv_pkg::OPC_JAL) ||
       ((i_from_if_to_pd.rvc_extra_predecoded[6:0] == riscv_pkg::OPC_JALR) &&
        (i_from_if_to_pd.rvc_extra_predecoded[14:12] == 3'b000)));
  assign pd_slot1_jump = pd_sel_compressed ? pd_rvc_jump : pd_native_jump;
  assign pd_slot2_jump = pd_slot2_predictable && is_jump(i_from_if_to_pd_2.effective_instr);
  assign pd_backing_candidate = pd_slot1_jump && i_backing_hit[0] &&
                                (i_backing_compressed[0] == pd_sel_compressed);
  assign pd_backing_candidate_2 = pd_slot2_jump && i_backing_hit[1] &&
                                  (i_backing_compressed[1] == pd_sel_compressed_2);
  // A hit on old bytes in slot 1 can coincide with a live jump in slot 2.
  // Use the entry of the slot that can actually make the backing redirect.
  logic pd_backing_slot1_live, pd_backing_slot1_owner;
  assign pd_backing_slot1_live = pd_backing_candidate && !i_from_if_to_pd.sel_nop &&
                                 !i_from_if_to_pd.fetch_fault;
  assign pd_backing_slot1_owner = pd_backing_slot1_live && !i_from_if_to_pd.btb_predicted_taken;
  // Indirect target candidates, one per slot: a JALR that is not a return,
  // whose indirect target predictor lookup hit, unless the BTB predicted it
  // taken with that target. The target replaces the BTB's (or gives one) and
  // takes precedence over a backing BTB entry for the same JALR.
  logic [1:0] pd_jalr;
  logic [1:0] pd_itt_eligible;
  logic [1:0] pd_itt_available;
  logic [1:0] pd_itt_available_r;
  logic [1:0] pd_itt_fast_taken_r;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] pd_itt_slot_target_r;
  (* keep = "true" *) logic [1:0] pd_itt_override_r;
  logic pd_itt_candidate_r;
  logic pd_itt_candidate_2_r;
  logic pd_itt_redirect_r;
  logic pd_itt_redirect_2_r;
  logic [XLEN-1:0] pd_itt_target_r;
  assign pd_jalr[0] = !pd_slot1_illegal_rvc && is_jalr(instruction_non_nop_predecoded_rs2);
  assign pd_jalr[1] = pd_slot2_predictable && is_jalr(i_from_if_to_pd_2.effective_instr);
  assign pd_itt_eligible[0] = pd_jalr[0] && !is_return(instruction_non_nop_predecoded_rs2);
  assign pd_itt_eligible[1] = pd_jalr[1] && !is_return(i_from_if_to_pd_2.effective_instr);
  assign pd_itt_available = pd_itt_eligible & i_itt_hit;
  assign o_jalr = pd_jalr;
  assign o_itt_eligible = pd_itt_eligible;
  assign o_jump = {pd_slot2_jump, pd_slot1_jump};
  // Form the direction-history bit for each possible fast prediction. A
  // conditional contributes its final direction. A jump contributes target
  // bit 2 from the indirect hit, the fast target, or the backing entry.
  logic [1:0] pd_backing_bit;
  logic pd_unpredicted_bit;
  logic [1:0] pd_taken, pd_veto, pd_fast_bit, pd_fast_taken, pd_itt_bit;
  logic pd_ras_valid;
  logic [1:0] pd_history_fixed, pd_history_uses_backing;
  logic [1:0] pd_history_if_fast;
  logic [1:0] pd_history_if_neither_fast;
  logic pd_history_if_only_slot1_fast;
  assign pd_taken = {pd_taken_candidate_2, pd_taken_candidate};
  assign pd_veto = {pd_not_taken_candidate_2, pd_not_taken_candidate};
  assign pd_itt_bit = {i_itt_target[1][1], i_itt_target[0][1]};
  assign pd_ras_valid = i_from_if_to_pd.ras_checkpoint_valid_count != '0;
  assign pd_fast_bit = {
    i_from_if_to_pd_2.btb_predicted_target[2], i_from_if_to_pd.btb_predicted_target[2]
  };
  assign pd_fast_taken = {
    i_from_if_to_pd_2.btb_predicted_taken, i_from_if_to_pd.btb_predicted_taken
  };
  assign pd_unpredicted_bit = pd_backing_slot1_live ? pd_backing_bit[0] : pd_backing_bit[1];
  for (genvar s = 0; s < 2; s++) begin : gen_history_bit
    assign pd_backing_bit[s] = i_backing_return[s] && pd_ras_valid ?
        i_from_if_to_pd.ras_checkpoint_top[2] : i_backing_target[s][1];
    assign pd_history_if_fast[s] = o_jump[s] ?
        (pd_itt_available[s] ? pd_itt_bit[s] : pd_fast_bit[s]) : pd_taken[s] || !pd_veto[s];
    assign pd_history_fixed[s] = o_jump[s] ? pd_itt_available[s] && pd_itt_bit[s] : pd_taken[s];
    assign pd_history_uses_backing[s] = o_jump[s] && !pd_itt_available[s];
    assign pd_history_if_neither_fast[s] = pd_history_fixed[s] ||
        (pd_history_uses_backing[s] && pd_unpredicted_bit);
  end
  // If slot 1 was already predicted taken it cannot own the backing entry
  // for a slot-2 history update, even on a stale hit in slot 1.
  assign pd_history_if_only_slot1_fast = pd_history_fixed[1] ||
      (pd_history_uses_backing[1] && pd_backing_bit[1]);
  assign o_pred_taken[0] = pd_fast_taken[0] ? pd_history_if_fast[0] : pd_history_if_neither_fast[0];
  assign o_pred_taken[1] = pd_fast_taken[1] ? pd_history_if_fast[1] :
      pd_fast_taken[0] ? pd_history_if_only_slot1_fast : pd_history_if_neither_fast[1];
`ifndef SYNTHESIS
  // Reference with the target comparison before the packet register.
  logic pd_itt_candidate;
  logic pd_itt_candidate_2;
  assign pd_itt_candidate = pd_itt_eligible[0] && i_itt_hit[0] &&
      !(i_from_if_to_pd.btb_predicted_taken &&
        (i_from_if_to_pd.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] == i_itt_target[0]));
  assign pd_itt_candidate_2 = pd_itt_eligible[1] && i_itt_hit[1] &&
      !(i_from_if_to_pd_2.btb_predicted_taken &&
        (i_from_if_to_pd_2.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] == i_itt_target[1]));
  logic pd_backing_target_select;
  logic pd_backing_target_return;
  logic [XLEN-1:0] pd_backing_target;
  assign pd_backing_target_select = !pd_cond_branch && (pd_slot1_jump || !pd_cond_branch_2);
  // Both slots share the packet's stack recovery point.
  assign pd_backing_target_return =
      (pd_backing_slot1_owner ? i_backing_return[0] : i_backing_return[1]) &&
      (i_from_if_to_pd.ras_checkpoint_valid_count != '0);
  assign pd_backing_target = pd_backing_target_return ? i_from_if_to_pd.ras_checkpoint_top : {
    i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
    pd_backing_slot1_owner ? i_backing_target[0] : i_backing_target[1],
    1'b0
  };
`endif

  // ===========================================================================
  // Raw Per-Source Redirect Capture (Pre-Flop)
  // ===========================================================================
  // Register each predictor source and branch-target candidate directly at the
  // PD edge without pre-flop instruction decode or cross-source priority
  // muxing. Compare the indirect target against the fast BTB target in 2-bit
  // chunks before the edge and reduce the chunk bits after the edge.
  localparam int unsigned IttTargetBits = riscv_pkg::PhysAddrBits - 1;
  localparam int unsigned IttEqChunks = (IttTargetBits + 1) / 2;

  logic pd_dir_taken_raw_next;
  logic pd_dir_not_taken_raw_next;
  logic pd_dir_taken_2_raw_next;
  logic pd_dir_not_taken_2_raw_next;
  logic pd_dir_taken_raw_r;
  logic pd_dir_not_taken_raw_r;
  logic pd_dir_taken_2_raw_r;
  logic pd_dir_not_taken_2_raw_r;
  logic [1:0] pd_backing_hit_r;
  logic [1:0] pd_backing_compressed_r;
  logic [1:0] pd_backing_return_r;
  logic [1:0][IttTargetBits-1:0] pd_backing_target_r;
  logic [1:0] pd_itt_hit_r;
  (* keep = "true" *) logic [1:0][IttEqChunks-1:0] pd_itt_eq_chunk_next;
  logic [1:0][IttEqChunks-1:0] pd_itt_eq_chunk_r;

  logic [PdTargetSplit-1:0] pd_s1_native_low_r;
  logic [PdTargetSplit-1:0] pd_s1_comp_low_r;
  logic [1:0] pd_s1_native_hs_r;
  logic [1:0] pd_s1_comp_hs_r;
  logic [PdTargetSplit-1:0] pd_s2_native_low_r;
  logic [PdTargetSplit-1:0] pd_s2_comp_low_r;
  logic [1:0] pd_s2_native_hs_r;
  logic [1:0] pd_s2_comp_hs_r;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_r;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_plus_one_r;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic [PdTargetHighWidth-1:0] pd_redirect_pc_high_minus_one_r;

  assign pd_dir_taken_raw_next = i_from_if_to_pd.tage_valid ?
      i_from_if_to_pd.tage_taken : i_from_if_to_pd.bp_dir_taken;
  assign pd_dir_not_taken_raw_next = i_from_if_to_pd.tage_valid && !i_from_if_to_pd.tage_taken;
  assign pd_dir_taken_2_raw_next = i_from_if_to_pd_2.tage_valid && i_from_if_to_pd_2.tage_taken;
  assign pd_dir_not_taken_2_raw_next = i_from_if_to_pd_2.tage_valid &&
                                       !i_from_if_to_pd_2.tage_taken;

  for (genvar c = 0; c < IttEqChunks; c++) begin : gen_itt_eq_chunk
    if (2 * c + 1 < IttTargetBits) begin : gen_pair
      assign pd_itt_eq_chunk_next[0][c] =
          i_from_if_to_pd.btb_predicted_target[1+2*c+:2] == i_itt_target[0][2*c+:2];
      assign pd_itt_eq_chunk_next[1][c] =
          i_from_if_to_pd_2.btb_predicted_target[1+2*c+:2] == i_itt_target[1][2*c+:2];
    end else begin : gen_single
      assign pd_itt_eq_chunk_next[0][c] =
          i_from_if_to_pd.btb_predicted_target[1+2*c] == i_itt_target[0][2*c];
      assign pd_itt_eq_chunk_next[1][c] =
          i_from_if_to_pd_2.btb_predicted_target[1+2*c] == i_itt_target[1][2*c];
    end
  end

  // Redirect-enabling raw flags clear on reset or flush even during a stall,
  // matching the original candidate registers.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_dir_taken_raw_r       <= 1'b0;
      pd_dir_not_taken_raw_r   <= 1'b0;
      pd_dir_taken_2_raw_r     <= 1'b0;
      pd_dir_not_taken_2_raw_r <= 1'b0;
      pd_backing_hit_r         <= 2'b00;
      pd_itt_hit_r             <= 2'b00;
    end else if (i_pipeline_ctrl.flush) begin
      pd_dir_taken_raw_r       <= 1'b0;
      pd_dir_not_taken_raw_r   <= 1'b0;
      pd_dir_taken_2_raw_r     <= 1'b0;
      pd_dir_not_taken_2_raw_r <= 1'b0;
      pd_backing_hit_r         <= 2'b00;
      pd_itt_hit_r             <= 2'b00;
    end else if (!i_pipeline_ctrl.stall) begin
      pd_dir_taken_raw_r       <= pd_dir_taken_raw_next;
      pd_dir_not_taken_raw_r   <= pd_dir_not_taken_raw_next;
      pd_dir_taken_2_raw_r     <= pd_dir_taken_2_raw_next;
      pd_dir_not_taken_2_raw_r <= pd_dir_not_taken_2_raw_next;
      pd_backing_hit_r         <= i_backing_hit;
      pd_itt_hit_r             <= i_itt_hit;
    end
  end

  // Target payloads and split equality chunks load on every unstalled edge,
  // staying aligned with the registered PD-to-ID packets across stalls.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_backing_compressed_r         <= i_backing_compressed;
      pd_backing_return_r             <= i_backing_return;
      pd_backing_target_r             <= i_backing_target;
      pd_itt_slot_target_r            <= i_itt_target;
      pd_itt_fast_taken_r             <= {
        i_from_if_to_pd_2.btb_predicted_taken, i_from_if_to_pd.btb_predicted_taken
      };
      pd_itt_eq_chunk_r               <= pd_itt_eq_chunk_next;
      pd_s1_native_low_r              <= i_from_if_to_pd.pd_target_native_low;
      pd_s1_comp_low_r                <= i_from_if_to_pd.pd_target_compressed_low;
      pd_s1_native_hs_r               <= i_from_if_to_pd.pd_target_native_high_select;
      pd_s1_comp_hs_r                 <= i_from_if_to_pd.pd_target_compressed_high_select;
      pd_s2_native_low_r              <= i_from_if_to_pd_2.pd_target_native_low;
      pd_s2_comp_low_r                <= i_from_if_to_pd_2.pd_target_compressed_low;
      pd_s2_native_hs_r               <= i_from_if_to_pd_2.pd_target_native_high_select;
      pd_s2_comp_hs_r                 <= i_from_if_to_pd_2.pd_target_compressed_high_select;
      pd_redirect_pc_high_r           <= i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit];
      pd_redirect_pc_high_plus_one_r  <= pd_pc_high_plus_one;
      pd_redirect_pc_high_minus_one_r <= pd_pc_high_minus_one;
    end
  end

  // ===========================================================================
  // Post-Flop Parallel Decode, Redirect Qualification, and Target Selection
  // ===========================================================================
  // Decode control-flow classes directly from the registered instructions in a
  // balanced two-level tree, in parallel with the two-level reduction of the
  // 2-bit indirect-target equality chunks.
  logic [1:0][31:0] pd_reg_instr;
  logic [1:0] pd_reg_live;
  (* keep = "true" *) logic [1:0] pd_reg_op_cf_hi;
  (* keep = "true" *) logic [1:0] pd_reg_f3_br_ok;
  (* keep = "true" *) logic [1:0] pd_reg_f3_jalr_ok;
  (* keep = "true" *) logic [1:0] pd_reg_op_jump_f3;
  (* keep = "true" *) logic [1:0] pd_reg_ret_imm_lo;
  (* keep = "true" *) logic [1:0] pd_reg_ret_imm_hi;
  (* keep = "true" *) logic [1:0] pd_reg_ret_rs1_ra;
  (* keep = "true" *) logic [1:0] pd_reg_ret_rd_ok;
  (* keep = "true" *) logic [1:0] pd_reg_itt_eligible_raw;
  (* keep = "true" *) logic [1:0] pd_itt_eq_g0;
  (* keep = "true" *) logic [1:0] pd_itt_eq_g1;
  (* keep = "true" *) logic [1:0] pd_itt_eq_g2;
  logic [1:0] pd_reg_dir_mismatch;
  logic [1:0] pd_reg_backing_qual;

  assign pd_reg_instr[0] = o_from_pd_to_id.instruction;
  assign pd_reg_instr[1] = o_from_pd_to_id_2.instruction;
  assign pd_reg_live[0] = !o_from_pd_to_id.inject_nop && !o_from_pd_to_id.fetch_fault &&
                          !o_from_pd_to_id.illegal_instruction;
  assign pd_reg_live[1] = !o_from_pd_to_id_2.inject_nop && !o_from_pd_to_id_2.fetch_fault &&
                          !o_from_pd_to_id_2.illegal_instruction;

  for (genvar s = 0; s < 2; s++) begin : gen_reg_decode
    // OPC_BRANCH = 7'b1100011, OPC_JALR = 7'b1100111, OPC_JAL = 7'b1101111
    // all share [6:4]=3'b110 and [1:0]=2'b11.
    assign pd_reg_op_cf_hi[s] = (pd_reg_instr[s][6:4] == 3'b110) &&
                                (pd_reg_instr[s][1:0] == 2'b11);
    assign pd_reg_f3_br_ok[s] = (pd_reg_instr[s][3:2] == 2'b00) &&
                                (pd_reg_instr[s][14:13] != 2'b01);
    assign pd_reg_f3_jalr_ok[s] = (pd_reg_instr[s][3:2] == 2'b01) &&
                                  (pd_reg_instr[s][14:12] == 3'b000);
    assign pd_reg_op_jump_f3[s] = ((pd_reg_instr[s][3:2] == 2'b01) &&
                                   (pd_reg_instr[s][14:12] == 3'b000)) ||
                                  (pd_reg_instr[s][3:2] == 2'b11);
    assign pd_reg_ret_imm_lo[s] = (pd_reg_instr[s][25:20] == 6'd0);
    assign pd_reg_ret_imm_hi[s] = (pd_reg_instr[s][31:26] == 6'd0);
    assign pd_reg_ret_rs1_ra[s] = (pd_reg_instr[s][19:15] == 5'd1);
    assign pd_reg_ret_rd_ok[s] = (pd_reg_instr[s][11:7] == 5'd0) ||
                                 (pd_reg_instr[s][11:7] == 5'd5);
    assign pd_reg_itt_eligible_raw[s] = pd_reg_op_cf_hi[s] && pd_reg_f3_jalr_ok[s] &&
        !(pd_reg_ret_imm_lo[s] && pd_reg_ret_imm_hi[s] &&
          pd_reg_ret_rs1_ra[s] && pd_reg_ret_rd_ok[s]);
    assign pd_itt_eq_g0[s] = &pd_itt_eq_chunk_r[s][5:0];
    assign pd_itt_eq_g1[s] = &pd_itt_eq_chunk_r[s][11:6];
    assign pd_itt_eq_g2[s] = &pd_itt_eq_chunk_r[s][IttEqChunks-1:12];
    assign pd_itt_override_r[s] = !pd_itt_fast_taken_r[s] ||
        !(pd_itt_eq_g0[s] && pd_itt_eq_g1[s] && pd_itt_eq_g2[s]);
  end

  assign pd_reg_dir_mismatch[0] =
      (pd_dir_taken_raw_r && !o_from_pd_to_id.btb_predicted_taken) ||
      (pd_dir_not_taken_raw_r && o_from_pd_to_id.btb_predicted_taken);
  assign pd_reg_dir_mismatch[1] =
      (pd_dir_taken_2_raw_r && !o_from_pd_to_id_2.btb_predicted_taken) ||
      (pd_dir_not_taken_2_raw_r && o_from_pd_to_id_2.btb_predicted_taken);
  assign pd_reg_backing_qual[0] = pd_backing_hit_r[0] &&
      (pd_backing_compressed_r[0] == o_from_pd_to_id.is_compressed) &&
      !o_from_pd_to_id.btb_predicted_taken;
  assign pd_reg_backing_qual[1] = pd_backing_hit_r[1] &&
      (pd_backing_compressed_r[1] == o_from_pd_to_id_2.is_compressed) &&
      !o_from_pd_to_id_2.btb_predicted_taken;

  // Registered-packet candidate views (used by checks and debug probes).
  assign pd_taken_candidate_r = pd_reg_op_cf_hi[0] && pd_reg_f3_br_ok[0] && pd_dir_taken_raw_r;
  assign pd_not_taken_candidate_r = pd_reg_op_cf_hi[0] && pd_reg_f3_br_ok[0] &&
                                    pd_dir_not_taken_raw_r;
  assign pd_taken_candidate_2_r = pd_reg_op_cf_hi[1] && pd_reg_f3_br_ok[1] && pd_dir_taken_2_raw_r;
  assign pd_not_taken_candidate_2_r = pd_reg_op_cf_hi[1] && pd_reg_f3_br_ok[1] &&
                                      pd_dir_not_taken_2_raw_r;
  assign pd_backing_candidate_r = pd_reg_op_cf_hi[0] && pd_reg_op_jump_f3[0] &&
      pd_backing_hit_r[0] && (pd_backing_compressed_r[0] == o_from_pd_to_id.is_compressed);
  assign pd_backing_candidate_2_r = pd_reg_op_cf_hi[1] && pd_reg_op_jump_f3[1] &&
      pd_backing_hit_r[1] && (pd_backing_compressed_r[1] == o_from_pd_to_id_2.is_compressed);
  assign pd_itt_available_r = pd_reg_itt_eligible_raw & pd_itt_hit_r;
  assign pd_itt_candidate_r = pd_itt_available_r[0] && pd_itt_override_r[0];
  assign pd_itt_candidate_2_r = pd_itt_available_r[1] && pd_itt_override_r[1];

  // Qualified redirects.
  assign pd_dir_redirect_1_r = pd_reg_op_cf_hi[0] && pd_reg_f3_br_ok[0] &&
                               pd_reg_dir_mismatch[0] && pd_reg_live[0];
  assign pd_dir_redirect_2_raw_r = pd_reg_op_cf_hi[1] && pd_reg_f3_br_ok[1] &&
                                   pd_reg_dir_mismatch[1] && pd_reg_live[1];
  assign pd_backing_redirect_r = pd_reg_op_cf_hi[0] && pd_reg_op_jump_f3[0] &&
                                 pd_reg_backing_qual[0] && pd_reg_live[0];
  assign pd_backing_redirect_2_r = pd_reg_op_cf_hi[1] && pd_reg_op_jump_f3[1] &&
                                   pd_reg_backing_qual[1] && pd_reg_live[1];
  assign pd_itt_redirect_r = pd_reg_itt_eligible_raw[0] && pd_itt_hit_r[0] &&
                             pd_itt_override_r[0] && pd_reg_live[0];
  assign pd_itt_redirect_2_r = pd_reg_itt_eligible_raw[1] && pd_itt_hit_r[1] &&
                               pd_itt_override_r[1] && pd_reg_live[1];
  assign pd_dir_redirect_2_r = pd_dir_redirect_2_raw_r && !pd_dir_redirect_1_r &&
                               !pd_backing_redirect_r && !pd_itt_redirect_r;
  assign pd_redirect_r =
      pd_dir_redirect_1_r || pd_dir_redirect_2_raw_r ||
      pd_backing_redirect_r || pd_backing_redirect_2_r ||
      pd_itt_redirect_r || pd_itt_redirect_2_r;

  // Parallel post-flop target formation for branches (both slots and their
  // fall-throughs), backing BTB, and indirect target predictor.
  logic [PdTargetSplit:0] pd_s1_ft_sum;
  logic [PdTargetSplit:0] pd_s2_ft_sum;
  logic pd_reg_s2_pc_carry;
  logic [PdTargetSplit-1:0] pd_s1_br_low;
  logic [PdTargetSplit-1:0] pd_s2_br_low;
  logic [1:0] pd_s1_br_hs;
  logic [1:0] pd_s2_br_hs_raw;
  logic [1:0] pd_s2_br_hs;
  logic pd_sel_s2_br;
  logic [PdTargetSplit-1:0] pd_br_target_low;
  logic [1:0] pd_br_target_hs;
  logic [PdTargetHighWidth-1:0] pd_br_target_high;
  logic pd_reg_ras_valid;
  logic pd_backing_use_ras;
  logic [XLEN-1:0] pd_backing_redirect_target_r;
  logic pd_itt_target_select_r;
  logic pd_backing_target_select_r;

  assign pd_s1_ft_sum = {1'b0, o_from_pd_to_id.program_counter[PdTargetSplit-1:0]} +
      (o_from_pd_to_id.is_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                                       (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_s2_ft_sum = {1'b0, o_from_pd_to_id_2.program_counter[PdTargetSplit-1:0]} +
      (o_from_pd_to_id_2.is_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                                         (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  // Slot 2's PC equals slot 1's PC + {2, 4}, so bit PdTargetSplit differs iff
  // slot 1's low PC stepped across the split boundary.
  assign pd_reg_s2_pc_carry = o_from_pd_to_id_2.program_counter[PdTargetSplit] ^
                              o_from_pd_to_id.program_counter[PdTargetSplit];
  assign pd_s1_br_low = pd_dir_not_taken_raw_r ? pd_s1_ft_sum[PdTargetSplit-1:0] :
      (o_from_pd_to_id.is_compressed ? pd_s1_comp_low_r : pd_s1_native_low_r);
  assign pd_s2_br_low = pd_dir_not_taken_2_raw_r ? pd_s2_ft_sum[PdTargetSplit-1:0] :
      (o_from_pd_to_id_2.is_compressed ? pd_s2_comp_low_r : pd_s2_native_low_r);
  assign pd_s1_br_hs = pd_dir_not_taken_raw_r ? {1'b0, pd_s1_ft_sum[PdTargetSplit]} :
      (o_from_pd_to_id.is_compressed ? pd_s1_comp_hs_r : pd_s1_native_hs_r);
  assign pd_s2_br_hs_raw = o_from_pd_to_id_2.is_compressed ? pd_s2_comp_hs_r : pd_s2_native_hs_r;
  assign pd_s2_br_hs = pd_dir_not_taken_2_raw_r ?
      {1'b0, pd_s2_ft_sum[PdTargetSplit] | pd_reg_s2_pc_carry} :
      fold_slot2_pc_carry(pd_reg_s2_pc_carry, pd_s2_br_hs_raw);

  assign pd_sel_s2_br = pd_dir_redirect_2_raw_r && !pd_dir_redirect_1_r;
  assign pd_br_target_low = pd_sel_s2_br ? pd_s2_br_low : pd_s1_br_low;
  assign pd_br_target_hs = pd_sel_s2_br ? pd_s2_br_hs : pd_s1_br_hs;
  assign pd_br_target_high = select_pd_target_high(
      pd_br_target_hs,
      pd_redirect_pc_high_r,
      pd_redirect_pc_high_plus_one_r,
      pd_redirect_pc_high_minus_one_r
  );

  assign pd_reg_ras_valid = o_from_pd_to_id.ras_checkpoint_valid_count != '0;
  assign pd_backing_use_ras = pd_reg_ras_valid &&
      (pd_backing_redirect_r ? pd_backing_return_r[0] : pd_backing_return_r[1]);
  assign pd_backing_redirect_target_r = pd_backing_use_ras ? o_from_pd_to_id.ras_checkpoint_top : {
    o_from_pd_to_id.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
    pd_backing_redirect_r ? pd_backing_target_r[0] : pd_backing_target_r[1],
    1'b0
  };

  assign pd_itt_target_r = pd_itt_redirect_r ?
      {o_from_pd_to_id.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
       pd_itt_slot_target_r[0], 1'b0} :
      {o_from_pd_to_id_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
       pd_itt_slot_target_r[1], 1'b0};

  assign pd_itt_target_select_r = pd_itt_redirect_r || pd_itt_redirect_2_r;
  assign pd_backing_target_select_r = !pd_itt_target_select_r &&
      (pd_backing_redirect_r ||
       (!pd_dir_redirect_1_r && !pd_dir_redirect_2_raw_r && pd_backing_redirect_2_r));

  assign o_pd_redirect = pd_redirect_r;
  assign o_pd_redirect_taken = !((pd_dir_redirect_1_r && pd_dir_not_taken_raw_r) ||
                                 (pd_dir_redirect_2_r && pd_dir_not_taken_2_raw_r));
  assign o_pd_redirect_target = pd_itt_target_select_r ? pd_itt_target_r :
      pd_backing_target_select_r ? pd_backing_redirect_target_r :
                                   {pd_br_target_high, pd_br_target_low};
  assign o_pd_redirect_slot2 = pd_backing_redirect_2_r || pd_dir_redirect_2_r ||
                               pd_itt_redirect_2_r;

  // Registered-packet history outputs for consumers acting the cycle after PD
  // accepts a packet (e.g. tage_history).
  logic [1:0] pd_reg_backing_bit;
  logic pd_reg_backing_target_bit2;
  logic [1:0] pd_reg_br_dir;
  logic [1:0] pd_reg_jump_dir;
  assign pd_reg_backing_bit[0] = (pd_backing_return_r[0] && pd_reg_ras_valid) ?
      o_from_pd_to_id.ras_checkpoint_top[2] : pd_backing_target_r[0][1];
  assign pd_reg_backing_bit[1] = (pd_backing_return_r[1] && pd_reg_ras_valid) ?
      o_from_pd_to_id.ras_checkpoint_top[2] : pd_backing_target_r[1][1];
  assign pd_reg_backing_target_bit2 = pd_backing_redirect_r ?
      pd_reg_backing_bit[0] : pd_reg_backing_bit[1];
  assign pd_reg_br_dir[0] = pd_dir_taken_raw_r ||
      (!pd_dir_not_taken_raw_r && o_from_pd_to_id.btb_predicted_taken);
  assign pd_reg_br_dir[1] = pd_dir_taken_2_raw_r ||
      (!pd_dir_not_taken_2_raw_r && o_from_pd_to_id_2.btb_predicted_taken);
  assign pd_reg_jump_dir[0] = (pd_reg_itt_eligible_raw[0] && pd_itt_hit_r[0]) ?
      pd_itt_slot_target_r[0][1] :
      (o_from_pd_to_id.btb_predicted_taken ? o_from_pd_to_id.btb_predicted_target[2] :
                                             pd_reg_backing_target_bit2);
  assign pd_reg_jump_dir[1] = (pd_reg_itt_eligible_raw[1] && pd_itt_hit_r[1]) ?
      pd_itt_slot_target_r[1][1] :
      (o_from_pd_to_id_2.btb_predicted_taken ? o_from_pd_to_id_2.btb_predicted_target[2] :
                                               pd_reg_backing_target_bit2);
  assign o_q_cond_branch[0] = pd_reg_op_cf_hi[0] && pd_reg_f3_br_ok[0] && pd_reg_live[0];
  assign o_q_cond_branch[1] = pd_reg_op_cf_hi[1] && pd_reg_f3_br_ok[1] && pd_reg_live[1];
  assign o_q_jalr[0] = pd_reg_op_cf_hi[0] && pd_reg_f3_jalr_ok[0] && pd_reg_live[0];
  assign o_q_jalr[1] = pd_reg_op_cf_hi[1] && pd_reg_f3_jalr_ok[1] && pd_reg_live[1];
  assign o_q_itt_eligible[0] = pd_reg_itt_eligible_raw[0] && pd_reg_live[0];
  assign o_q_itt_eligible[1] = pd_reg_itt_eligible_raw[1] && pd_reg_live[1];
  assign o_q_cf[0] = pd_reg_op_cf_hi[0] && (pd_reg_f3_br_ok[0] || pd_reg_op_jump_f3[0]) &&
                     pd_reg_live[0];
  assign o_q_cf[1] = pd_reg_op_cf_hi[1] && (pd_reg_f3_br_ok[1] || pd_reg_op_jump_f3[1]) &&
                     pd_reg_live[1];
  assign o_q_pred_taken[0] = (pd_reg_op_cf_hi[0] && pd_reg_op_jump_f3[0]) ?
      pd_reg_jump_dir[0] : pd_reg_br_dir[0];
  assign o_q_pred_taken[1] = (pd_reg_op_cf_hi[1] && pd_reg_op_jump_f3[1]) ?
      pd_reg_jump_dir[1] : pd_reg_br_dir[1];

  logic pd_registered_call, pd_registered_call_2;
  logic pd_registered_return, pd_registered_return_2;
  assign pd_registered_call = is_call(o_from_pd_to_id.instruction);
  assign pd_registered_call_2 = is_call(o_from_pd_to_id_2.instruction);
  assign pd_registered_return = is_return(o_from_pd_to_id.instruction);
  assign pd_registered_return_2 = is_return(o_from_pd_to_id_2.instruction);
  // An indirect call the BTB predicted taken has had its push from IF.
  assign o_pd_redirect_ras_push =
      ((pd_backing_redirect_r ||
        (pd_itt_redirect_r && !o_from_pd_to_id.btb_predicted_taken)) && pd_registered_call) ||
      ((pd_backing_redirect_2_r ||
        (pd_itt_redirect_2_r && !o_from_pd_to_id_2.btb_predicted_taken)) && pd_registered_call_2);
  assign o_pd_redirect_ras_pop = (pd_backing_redirect_r && pd_registered_return) ||
                                 (pd_backing_redirect_2_r && pd_registered_return_2);
  assign o_pd_backing_refresh = pd_backing_redirect_r || pd_backing_redirect_2_r;
  assign o_pd_backing_refresh_pc = pd_backing_redirect_r ? o_from_pd_to_id.program_counter :
                                                           o_from_pd_to_id_2.program_counter;
  assign o_pd_redirect_ras_link = (pd_backing_redirect_2_r || pd_itt_redirect_2_r) ?
      o_from_pd_to_id_2.program_counter + (o_from_pd_to_id_2.is_compressed ?
          XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit)) :
      o_from_pd_to_id.program_counter + (o_from_pd_to_id.is_compressed ?
          XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit));

`ifndef SYNTHESIS
  // Compare the split post-flop branch target and split indirect compare
  // against full-width references sampled on the same enabled edge.
  logic [PdTargetSplit:0] pd_fall_through_sum;
  logic [PdTargetSplit:0] pd_slot2_fall_through_sum;
  assign pd_fall_through_sum = {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      (pd_sel_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                           (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_slot2_fall_through_sum = {1'b0, pd_slot2_pc_low} +
      (pd_sel_compressed_2 ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                             (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) pd_reset_seen_q <= 1'b1;
  end
  logic [PdTargetSplit-1:0] pd_s1_taken_low_ref_r;
  logic [PdTargetSplit-1:0] pd_s1_ft_low_ref_r;
  logic [1:0] pd_s1_taken_hs_ref_r;
  logic [1:0] pd_s1_ft_hs_ref_r;
  logic [PdTargetSplit-1:0] pd_s2_taken_low_ref_r;
  logic [PdTargetSplit-1:0] pd_s2_ft_low_ref_r;
  logic [1:0] pd_s2_taken_hs_ref_r;
  logic [1:0] pd_s2_ft_hs_ref_r;
  logic [PdTargetSplit-1:0] pd_s1_br_low_reference_r;
  logic [1:0] pd_s1_br_hs_reference_r;
  logic [PdTargetSplit-1:0] pd_s2_br_low_reference_r;
  logic [1:0] pd_s2_br_hs_reference_r;
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) begin
      pd_s1_taken_low_ref_r <= pd_sel_compressed ?
          pd_target_compressed_low_candidate : pd_target_native_low_candidate;
      pd_s1_ft_low_ref_r    <= pd_fall_through_sum[PdTargetSplit-1:0];
      pd_s1_taken_hs_ref_r  <= pd_sel_compressed ?
          pd_target_compressed_high_select : pd_target_native_high_select;
      pd_s1_ft_hs_ref_r     <= {1'b0, pd_fall_through_sum[PdTargetSplit]};
      pd_s2_taken_low_ref_r <= pd_slot2_target_selected_low;
      pd_s2_ft_low_ref_r    <= pd_slot2_fall_through_sum[PdTargetSplit-1:0];
      pd_s2_taken_hs_ref_r  <= pd_slot2_target_selected_high_select;
      pd_s2_ft_hs_ref_r     <= {1'b0, pd_slot2_fall_through_sum[PdTargetSplit] | pd_slot2_pc_carry};
    end
  end
  assign pd_s1_br_low_reference_r = pd_dir_not_taken_raw_r ?
      pd_s1_ft_low_ref_r : pd_s1_taken_low_ref_r;
  assign pd_s1_br_hs_reference_r = pd_dir_not_taken_raw_r ?
      pd_s1_ft_hs_ref_r : pd_s1_taken_hs_ref_r;
  assign pd_s2_br_low_reference_r = pd_dir_not_taken_2_raw_r ?
      pd_s2_ft_low_ref_r : pd_s2_taken_low_ref_r;
  assign pd_s2_br_hs_reference_r = pd_dir_not_taken_2_raw_r ?
      pd_s2_ft_hs_ref_r : pd_s2_taken_hs_ref_r;
  always_ff @(posedge i_clk) begin
    if (pd_reset_seen_q && pd_redirect_target_reference_armed && !$isunknown(
            {
              pd_reg_live,
              pd_s1_br_low_reference_r,
              pd_s1_br_low,
              pd_s1_br_hs_reference_r,
              pd_s1_br_hs,
              pd_s2_br_low_reference_r,
              pd_s2_br_low,
              pd_s2_br_hs_reference_r,
              pd_s2_br_hs,
              pd_itt_override_r,
              pd_itt_fast_taken_r,
              o_from_pd_to_id.btb_predicted_target,
              o_from_pd_to_id_2.btb_predicted_target,
              pd_itt_slot_target_r
            }
        )) begin
      p_pd_s1_br_target_capture_exact :
      assert (!pd_reg_live[0] ||
              ((pd_s1_br_low == pd_s1_br_low_reference_r) &&
               (pd_s1_br_hs == pd_s1_br_hs_reference_r)));
      p_pd_s2_br_target_capture_exact :
      assert (!pd_reg_live[1] ||
              ((pd_s2_br_low == pd_s2_br_low_reference_r) &&
               (pd_s2_br_hs == pd_s2_br_hs_reference_r)));
      p_pd_itt_override_split_exact :
      assert ((pd_itt_override_r[0] == (!pd_itt_fast_taken_r[0] ||
                   (o_from_pd_to_id.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] !=
                    pd_itt_slot_target_r[0]))) &&
              (pd_itt_override_r[1] == (!pd_itt_fast_taken_r[1] ||
                   (o_from_pd_to_id_2.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] !=
                    pd_itt_slot_target_r[1]))));
    end
  end
`endif

`ifndef SYNTHESIS
`ifndef FORMAL
  // Redirect checks require pd_reset_seen_q as well as sample-valid flags.
  // System assertions arm after the testbench's driven reset interval.
`endif
  // Reference model of the candidate FFs: reset and flush clear them even
  // during a stall, a stall holds them, and every enabled edge captures the
  // branch and its directions with no feedback from the qualified redirect.
  // The two candidates are never set together.
  logic pd_taken_candidate_payload_reference_q;
  logic pd_not_taken_candidate_payload_reference_q;
  logic pd_taken_candidate_2_payload_reference_q;
  logic pd_not_taken_candidate_2_payload_reference_q;
  logic pd_redirect_candidate_payload_reference_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_taken_candidate_payload_reference_q <= 1'b0;
      pd_not_taken_candidate_payload_reference_q <= 1'b0;
      pd_taken_candidate_2_payload_reference_q <= 1'b0;
      pd_not_taken_candidate_2_payload_reference_q <= 1'b0;
      pd_redirect_candidate_payload_reference_armed <= 1'b0;
    end else begin
      if (pd_sim_reset_seen_q && pd_redirect_candidate_payload_reference_armed && !$isunknown(
              {
                pd_reg_live,
                pd_taken_candidate_r,
                pd_not_taken_candidate_r,
                pd_taken_candidate_2_r,
                pd_not_taken_candidate_2_r,
                pd_taken_candidate_payload_reference_q,
                pd_not_taken_candidate_payload_reference_q,
                pd_taken_candidate_2_payload_reference_q,
                pd_not_taken_candidate_2_payload_reference_q
              }
          )) begin
        p_pd_taken_candidate_payload_exact :
        assert (!pd_reg_live[0] ||
                (pd_taken_candidate_r == pd_taken_candidate_payload_reference_q));
        p_pd_not_taken_candidate_payload_exact :
        assert (!pd_reg_live[0] ||
                (pd_not_taken_candidate_r == pd_not_taken_candidate_payload_reference_q));
        p_pd_taken_candidate_2_payload_exact :
        assert (!pd_reg_live[1] ||
                (pd_taken_candidate_2_r == pd_taken_candidate_2_payload_reference_q));
        p_pd_not_taken_candidate_2_payload_exact :
        assert (!pd_reg_live[1] ||
                (pd_not_taken_candidate_2_r == pd_not_taken_candidate_2_payload_reference_q));
        p_pd_redirect_candidates_exclusive :
        assert (!(pd_taken_candidate_r && pd_not_taken_candidate_r));
        p_pd_slot2_redirect_candidates_exclusive :
        assert (!(pd_taken_candidate_2_r && pd_not_taken_candidate_2_r));
      end

      if (i_pipeline_ctrl.flush) begin
        pd_taken_candidate_payload_reference_q <= 1'b0;
        pd_not_taken_candidate_payload_reference_q <= 1'b0;
        pd_taken_candidate_2_payload_reference_q <= 1'b0;
        pd_not_taken_candidate_2_payload_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_taken_candidate_payload_reference_q <=
            (pd_native_branch || pd_compressed_branch) &&
            (i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken :
                                          i_from_if_to_pd.bp_dir_taken);
        pd_not_taken_candidate_payload_reference_q <=
            (pd_native_branch || pd_compressed_branch) &&
            i_from_if_to_pd.tage_valid && !i_from_if_to_pd.tage_taken;
        pd_taken_candidate_2_payload_reference_q <=
            pd_cond_branch_2 && i_from_if_to_pd_2.tage_valid &&
            i_from_if_to_pd_2.tage_taken;
        pd_not_taken_candidate_2_payload_reference_q <=
            pd_cond_branch_2 && i_from_if_to_pd_2.tage_valid &&
            !i_from_if_to_pd_2.tage_taken;
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
  logic pd_dir_redirect_2_reference_q;
  logic pd_redirect_taken_reference_q;
  logic pd_redirect_reference_armed = 1'b0;
  logic pd_final_taken_reference;
  logic pd_final_taken_reference_2;
  logic pd_dir_redirect_1_reference_next;
  logic pd_dir_redirect_2_reference_next;
  logic pd_redirect_reference_next;
  assign pd_final_taken_reference =
      i_from_if_to_pd.tage_valid ? i_from_if_to_pd.tage_taken :
      (i_from_if_to_pd.btb_predicted_taken || i_from_if_to_pd.bp_dir_taken);
  assign pd_final_taken_reference_2 =
      i_from_if_to_pd_2.tage_valid ? i_from_if_to_pd_2.tage_taken :
                                     i_from_if_to_pd_2.btb_predicted_taken;
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
  // An indirect target candidate with its slot's bubble and fault vetoes.
  logic pd_itt_reference_next;
  logic pd_itt_reference_next_2;
  assign pd_itt_reference_next = pd_itt_candidate && !i_from_if_to_pd.sel_nop &&
                                 !i_from_if_to_pd.fetch_fault;
  assign pd_itt_reference_next_2 = pd_itt_candidate_2 && !i_from_if_to_pd_2.sel_nop &&
                                   !i_from_if_to_pd_2.fetch_fault;
  assign pd_dir_redirect_1_reference_next =
      (pd_native_branch || pd_compressed_branch) &&
      (pd_final_taken_reference != i_from_if_to_pd.btb_predicted_taken) &&
      !i_from_if_to_pd.sel_nop &&
      !i_from_if_to_pd.fetch_fault &&
      !pd_redirect_reference_q;
  assign pd_dir_redirect_2_reference_next =
      pd_cond_branch_2 &&
      (pd_final_taken_reference_2 != i_from_if_to_pd_2.btb_predicted_taken) &&
      !i_from_if_to_pd_2.sel_nop &&
      !i_from_if_to_pd_2.fetch_fault &&
      !pd_dir_redirect_1_reference_next &&
      !pd_backing_reference_next &&
      !pd_itt_reference_next &&
      !pd_redirect_reference_q;
  assign pd_redirect_reference_next =
      pd_dir_redirect_1_reference_next || pd_dir_redirect_2_reference_next ||
      ((pd_backing_reference_next || pd_backing_reference_next_2 ||
        pd_itt_reference_next || pd_itt_reference_next_2) &&
       !pd_redirect_reference_q);

  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_reference_q <= 1'b0;
      pd_dir_redirect_2_reference_q <= 1'b0;
      pd_redirect_reference_armed <= 1'b1;
    end else begin
      if (pd_sim_reset_seen_q && pd_redirect_reference_armed && !$isunknown(
              {pd_redirect_r, pd_redirect_reference_q, pd_dir_redirect_2_r,
               pd_dir_redirect_2_reference_q, o_pd_redirect_taken,
               pd_redirect_taken_reference_q}
          )) begin
        p_pd_redirect_registered_veto_exact : assert (pd_redirect_r == pd_redirect_reference_q);
        p_pd_dir_redirect_2_registered_veto_exact :
        assert (pd_dir_redirect_2_r == pd_dir_redirect_2_reference_q);
        p_pd_redirect_direction_exact :
        assert (!pd_redirect_r || (o_pd_redirect_taken == pd_redirect_taken_reference_q));
      end

      if (i_pipeline_ctrl.flush) begin
        pd_redirect_reference_q <= 1'b0;
        pd_dir_redirect_2_reference_q <= 1'b0;
      end else if (!i_pipeline_ctrl.stall) begin
        pd_redirect_reference_q <= pd_redirect_reference_next;
        pd_dir_redirect_2_reference_q <= pd_dir_redirect_2_reference_next;
        pd_redirect_taken_reference_q <=
            pd_dir_redirect_2_reference_next ? pd_final_taken_reference_2 :
            ((pd_backing_reference_next || pd_backing_reference_next_2 ||
              pd_itt_reference_next || pd_itt_reference_next_2) ||
             pd_final_taken_reference);
        pd_redirect_reference_armed <= 1'b1;
      end
    end
  end

  // A full-width reference sampled on the same enabled edges checks target
  // alignment, stall hold, and the target, fall-through, and format
  // selection.
  logic [XLEN-1:0] pd_slot1_redirect_target_reference_q;
  logic [XLEN-1:0] pd_slot2_redirect_target_reference_q;
  logic [XLEN-1:0] pd_slot1_redirect_target_next_reference;
  logic [XLEN-1:0] pd_slot2_redirect_target_next_reference;
  logic [XLEN-1:0] pd_redirect_target_reference;
  // An indirect target candidate's target and its select, sampled like the
  // target registers.
  logic [XLEN-1:0] pd_itt_target_reference_q;
  logic pd_itt_select_reference_q;
  assign pd_slot1_redirect_target_next_reference = pd_not_taken_candidate ?
      i_from_if_to_pd.program_counter +
      (pd_sel_compressed ? XLEN'(riscv_pkg::PcIncrementCompressed) :
                           XLEN'(riscv_pkg::PcIncrement32bit)) :
      (pd_backing_target_select ? pd_backing_target : pd_backward_target_reference);
  assign pd_slot2_redirect_target_next_reference = pd_not_taken_candidate_2 ?
      i_from_if_to_pd_2.program_counter +
      (pd_sel_compressed_2 ? XLEN'(riscv_pkg::PcIncrementCompressed) :
                             XLEN'(riscv_pkg::PcIncrement32bit)) :
      pd_slot2_target_reference;
  assign pd_redirect_target_reference = pd_itt_select_reference_q ? pd_itt_target_reference_q :
      pd_dir_redirect_2_reference_q ? pd_slot2_redirect_target_reference_q :
                                      pd_slot1_redirect_target_reference_q;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_redirect_target_reference_armed <= 1'b0;
    end else begin
      if (pd_sim_reset_seen_q && pd_redirect_target_reference_armed &&
          pd_redirect_reference_armed && !$isunknown(
              {
                pd_redirect_r,
                o_pd_redirect_target,
                pd_redirect_target_reference
              }
          )) begin
        p_pd_redirect_target_boundary_exact :
        assert (!pd_redirect_r || (o_pd_redirect_target == pd_redirect_target_reference));
      end
      // Independent of the reference: a not-taken redirect goes to the
      // redirecting instruction's fall-through.
      if (pd_sim_reset_seen_q && o_pd_redirect && !o_pd_redirect_taken && !$isunknown(
              {o_pd_redirect_target, o_pd_redirect_slot2, o_from_pd_to_id.program_counter,
               o_from_pd_to_id_2.program_counter}
          )) begin
        p_pd_not_taken_redirect_falls_through :
        assert (o_pd_redirect_target == (o_pd_redirect_slot2 ?
            o_from_pd_to_id_2.program_counter + (o_from_pd_to_id_2.is_compressed ?
                XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit)) :
            o_from_pd_to_id.program_counter + (o_from_pd_to_id.is_compressed ?
                XLEN'(riscv_pkg::PcIncrementCompressed) : XLEN'(riscv_pkg::PcIncrement32bit))));
      end
      if (!i_pipeline_ctrl.stall) begin
        pd_slot1_redirect_target_reference_q <= pd_slot1_redirect_target_next_reference;
        pd_slot2_redirect_target_reference_q <= pd_slot2_redirect_target_next_reference;
        pd_itt_target_reference_q <= {
          pd_itt_reference_next ? i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] :
                                  i_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
          pd_itt_eligible[0] ? i_itt_target[0] : i_itt_target[1],
          1'b0
        };
        pd_itt_select_reference_q <= pd_itt_reference_next || pd_itt_reference_next_2;
        pd_redirect_target_reference_armed <= 1'b1;
      end
    end
  end

  // A firing backing redirect takes the target its own instruction's decode
  // names, the stack's top for a return while the stack holds an entry and
  // its slot's entry otherwise, whenever the entry's return type matches that
  // decode.
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
      if (pd_sim_reset_seen_q && pd_backing_decoded_reference_armed && !$isunknown(
              {
                pd_backing_redirect_r,
                pd_backing_redirect_2_r,
                pd_backing_decoded_reference_valid_q,
                pd_backing_decoded_reference_valid_2_q
              }
          )) begin
        p_pd_backing_slot1_target_matches_decode :
        assert (!(pd_backing_redirect_r && pd_backing_decoded_reference_valid_q &&
                  !pd_itt_target_select_r) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_q));
        p_pd_backing_slot2_target_matches_decode :
        assert (!(pd_backing_redirect_2_r && !pd_backing_redirect_r &&
                  pd_backing_decoded_reference_valid_2_q && !pd_itt_target_select_r) ||
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
        pd_backing_decoded_reference_valid_2_q <= i_backing_return[1] == pd_slot2_return_reference;
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
      // Raw start parcel, for Sstvala's illegal-instruction xtval.
      o_from_pd_to_id.raw_parcel <= i_from_if_to_pd.raw_parcel;
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
      o_from_pd_to_id_2.inject_nop <= i_pipeline_ctrl.flush || pd_redirect_r || pd_slot2_nop;
      o_from_pd_to_id_2.is_compressed <= (i_pipeline_ctrl.flush || pd_redirect_r ||
                                          pd_slot2_nop) ? 1'b0 :
                                                                    pd_sel_compressed_2;
      o_from_pd_to_id_2.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                                (!pd_slot2_nop &&
                                                i_from_if_to_pd_2.decomp_illegal);
      // slot-2 fetch-fault pass-through (see slot-1).
      o_from_pd_to_id_2.fetch_fault <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                        (!pd_slot2_nop &&
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
      o_from_pd_to_id_2.raw_parcel <= i_from_if_to_pd_2.raw_parcel;
    end
  end

  // Clear slot 2's early source fields synchronously for invalidation, so
  // Vivado can use the register reset pin. Include !stall: a bubble or flush
  // must not overwrite held source addresses before the bundle advances.
  logic slot2_early_source_clear;
  assign slot2_early_source_clear = !i_pipeline_ctrl.stall &&
      (i_pipeline_ctrl.flush || pd_redirect_r || pd_slot2_nop);

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
  // as those checks state. A slot-2 backing hit lies in slot 1's target
  // region, which backing_btb guarantees by giving the word after its last
  // set no slot-2 hit (formal/backing_btb.sby). IF's pairing predecode
  // recognizes legal control-flow encodings. It can pair a reserved C.JR x0
  // even though expansion produces a JALR. Faulting bytes can be arbitrary,
  // and a valid slot 2 behind a faulting slot 1 faults too. IF's
  // slot-2 backing type and target for each size of slot 1 are its slot-2
  // fields at the packet's sel_compressed (formal/if_slot2_precompute.sby).
  logic formal_past_valid = 1'b0;
  logic [1:0] formal_backing_compressed_q;
  logic [31:0] formal_slot1_instruction_q;
  logic [31:0] formal_slot2_instruction_q;
  logic [PdTargetSplit:0] formal_s1_native_low_sum;
  logic [PdTargetSplit:0] formal_s1_comp_low_sum;
  logic [PdTargetSplit:0] formal_s2_native_low_sum;
  logic [PdTargetSplit:0] formal_s2_comp_low_sum;
  assign formal_s1_native_low_sum =
      {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      {1'b0, pd_imm_b_native[PdTargetSplit-1:0]};
  assign formal_s1_comp_low_sum =
      {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      {1'b0, pd_imm_b_compressed[PdTargetSplit-1:0]};
  assign formal_s2_native_low_sum =
      {1'b0, i_from_if_to_pd_2.program_counter[PdTargetSplit-1:0]} +
      {1'b0, pd_slot2_imm_b_native[PdTargetSplit-1:0]};
  assign formal_s2_comp_low_sum =
      {1'b0, i_from_if_to_pd_2.program_counter[PdTargetSplit-1:0]} +
      {1'b0, pd_slot2_imm_b_compressed[PdTargetSplit-1:0]};

  // Sample the original compare-before-register equations independently,
  // including the reset/flush rules for candidates and qualified redirects.
  logic [1:0] formal_itt_candidates_q;
  logic formal_itt_redirect_q;
  logic [1:0] formal_jump_history;
  assign formal_jump_history[0] = pd_itt_candidate ? i_itt_target[0][1] :
      i_from_if_to_pd.btb_predicted_taken ? i_from_if_to_pd.btb_predicted_target[2] :
                                           pd_backing_target[2];
  assign formal_jump_history[1] = pd_itt_candidate_2 ? i_itt_target[1][1] :
      i_from_if_to_pd_2.btb_predicted_taken ? i_from_if_to_pd_2.btb_predicted_target[2] :
                                             pd_backing_target[2];
  logic formal_itt_payload_loaded = 1'b0;
  // Reference model of Cycle-T combinational history outputs sampled on every
  // accepted PD packet edge, to prove o_q_* equivalence at the stage boundary.
  logic formal_q_accept_q;
  logic [1:0] formal_q_cond_branch_ref_q;
  logic [1:0] formal_q_jalr_ref_q;
  logic [1:0] formal_q_itt_eligible_ref_q;
  logic [1:0] formal_q_cf_ref_q;
  logic [1:0] formal_q_pred_taken_ref_q;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) begin
      formal_itt_candidates_q <= '0;
      formal_itt_redirect_q   <= 1'b0;
    end else if (!i_pipeline_ctrl.stall) begin
      formal_itt_candidates_q <= {pd_itt_candidate_2, pd_itt_candidate};
      formal_itt_redirect_q   <= (pd_itt_reference_next || pd_itt_reference_next_2) &&
                                 !pd_redirect_reference_q;
    end
    if (!i_pipeline_ctrl.stall) begin
      formal_itt_payload_loaded <= 1'b1;
    end
    if (i_pipeline_ctrl.reset) begin
      formal_q_accept_q <= 1'b0;
    end else begin
      formal_q_accept_q <= !i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush && !pd_redirect_r;
      if (!i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush && !pd_redirect_r) begin
        formal_q_cond_branch_ref_q[0]  <= pd_cond_branch && !i_from_if_to_pd.sel_nop &&
                                          !i_from_if_to_pd.fetch_fault;
        formal_q_cond_branch_ref_q[1]  <= pd_cond_branch_2 && !i_from_if_to_pd_2.sel_nop &&
                                          !i_from_if_to_pd_2.fetch_fault;
        formal_q_jalr_ref_q[0]         <= pd_jalr[0] && !i_from_if_to_pd.sel_nop &&
                                          !i_from_if_to_pd.fetch_fault;
        formal_q_jalr_ref_q[1]         <= pd_jalr[1] && !i_from_if_to_pd_2.sel_nop &&
                                          !i_from_if_to_pd_2.fetch_fault;
        formal_q_itt_eligible_ref_q[0] <= pd_itt_eligible[0] && !i_from_if_to_pd.sel_nop &&
                                          !i_from_if_to_pd.fetch_fault;
        formal_q_itt_eligible_ref_q[1] <= pd_itt_eligible[1] && !i_from_if_to_pd_2.sel_nop &&
                                          !i_from_if_to_pd_2.fetch_fault;
        formal_q_cf_ref_q[0]           <= (pd_cond_branch || pd_slot1_jump) &&
                                          !i_from_if_to_pd.sel_nop && !i_from_if_to_pd.fetch_fault;
        formal_q_cf_ref_q[1]           <= (pd_cond_branch_2 || pd_slot2_jump) &&
                                          !i_from_if_to_pd_2.sel_nop &&
                                          !i_from_if_to_pd_2.fetch_fault;
        formal_q_pred_taken_ref_q      <= o_pred_taken;
      end
    end
  end

  always_comb begin
    if (formal_past_valid) begin
      p_formal_itt_registered_candidates_exact :
      assert ((!pd_reg_live[0] || (pd_itt_candidate_r == formal_itt_candidates_q[0])) &&
              (!pd_reg_live[1] || (pd_itt_candidate_2_r == formal_itt_candidates_q[1])));
      p_formal_itt_registered_select_exact :
      assert (pd_itt_target_select_r == formal_itt_redirect_q);
    end
    if (formal_itt_payload_loaded) begin
      p_formal_itt_override_split_exact :
      assert ((pd_itt_override_r[0] == (!pd_itt_fast_taken_r[0] ||
                   (o_from_pd_to_id.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] !=
                    pd_itt_slot_target_r[0]))) &&
              (pd_itt_override_r[1] == (!pd_itt_fast_taken_r[1] ||
                   (o_from_pd_to_id_2.btb_predicted_target[riscv_pkg::PhysAddrBits-1:1] !=
                    pd_itt_slot_target_r[1]))));
    end
    if (formal_past_valid && !i_pipeline_ctrl.reset && formal_q_accept_q) begin
      p_formal_q_cond_branch_exact : assert (o_q_cond_branch == formal_q_cond_branch_ref_q);
      p_formal_q_jalr_exact : assert (o_q_jalr == formal_q_jalr_ref_q);
      p_formal_q_itt_eligible_exact : assert (o_q_itt_eligible == formal_q_itt_eligible_ref_q);
      p_formal_q_cf_exact : assert (o_q_cf == formal_q_cf_ref_q);
      p_formal_q_pred_taken_slot1_exact :
      assert (!o_q_cf[0] || (o_q_pred_taken[0] == formal_q_pred_taken_ref_q[0]));
      p_formal_q_pred_taken_slot2_exact :
      assert (!o_q_cf[1] || (o_q_pred_taken[1] == formal_q_pred_taken_ref_q[1]));
    end
    p_formal_itt_history_bit1_exact :
    assert (o_pred_taken[0] == (pd_slot1_jump ? formal_jump_history[0] :
        pd_taken_candidate || (!pd_not_taken_candidate && i_from_if_to_pd.btb_predicted_taken)));
    p_formal_itt_history_bit2_exact :
    assert (o_pred_taken[1] == (pd_slot2_jump ? formal_jump_history[1] :
        pd_taken_candidate_2 || (!pd_not_taken_candidate_2 && pd_fast_taken[1])));
    c_formal_itt_equal_fast_target :
    cover (formal_itt_payload_loaded && pd_itt_available_r[1] && pd_reg_live[1] &&
           !pd_itt_override_r[1]);
    c_formal_itt_different_fast_target :
    cover (formal_itt_payload_loaded && pd_itt_fast_taken_r[1] && pd_itt_redirect_2_r);
    c_formal_itt_held_target_select :
    cover (formal_itt_payload_loaded && i_pipeline_ctrl.stall && pd_itt_target_select_r);
  end

  logic [1:0][XLEN-1:0] formal_itt_slot_target_q;
  always_ff @(posedge i_clk) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (i_pipeline_ctrl.reset);
    assume (!i_backing_hit[1] ||
            (i_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] ==
             i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits]));
    // The aligner classifies the original parcel. Reserved C.JR x0 can pair.
    assume (i_from_if_to_pd_2.sel_nop || i_from_if_to_pd.fetch_fault ||
            !(pd_sel_compressed ? riscv_pkg::imem_compressed_control(
        i_from_if_to_pd.raw_parcel
    ) : riscv_pkg::imem_native_control(
        i_from_if_to_pd.effective_instr[6:0]
    )));
    assume (i_from_if_to_pd_2.sel_nop || !i_from_if_to_pd.fetch_fault ||
            i_from_if_to_pd_2.fetch_fault);
    if (!i_pipeline_ctrl.stall) begin
      formal_backing_compressed_q <= i_backing_compressed;
      for (int slot = 0; slot < 2; slot++)
      formal_itt_slot_target_q[slot] <= {
        slot == 0 ? i_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] :
                    i_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
        i_itt_target[slot],
        1'b0
      };
      formal_slot1_instruction_q <= instruction_non_nop;
      formal_slot2_instruction_q <= instruction_non_nop_2;
    end
  end

  always_comb begin
    assume (!i_from_if_to_pd.sel_nop || i_from_if_to_pd_2.sel_nop);
    assume ({i_backing_return[1], i_backing_target[1]} ==
            {i_backing_slot2_return_by_size[i_from_if_to_pd.sel_compressed],
             i_backing_slot2_target_by_size[i_from_if_to_pd.sel_compressed]});
    assume (i_from_if_to_pd_2.program_counter ==
            {pd_slot2_pc_carry ? pd_pc_high_plus_one :
                                 i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit],
             pd_slot2_pc_low});
    assume (!i_from_if_to_pd.is_cond_branch);
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
      assume (i_from_if_to_pd_2.is_cond_branch ==
              ((instruction_non_nop_2[6:0] == riscv_pkg::OPC_BRANCH) &&
               (instruction_non_nop_2[14:13] != 2'b01)));
      assume (i_from_if_to_pd_2.source_hot_predecoded ==
              {instruction_non_nop_2[21], instruction_non_nop_2[17:16]});
      assume (source_reg_1_2 == instruction_non_nop_2[19:15]);
      assume (source_reg_2_2 == instruction_non_nop_2[24:20]);
      assume (source_reg_1_2[2:1] == i_from_if_to_pd_2.source_hot_predecoded[1:0]);
    end
    assume (i_from_if_to_pd.pd_target_native_low == formal_s1_native_low_sum[PdTargetSplit-1:0]);
    assume (i_from_if_to_pd.pd_target_native_high_select ==
            {pd_imm_b_native[PdTargetSplit-1], formal_s1_native_low_sum[PdTargetSplit]});
    assume (i_from_if_to_pd.pd_target_compressed_low == formal_s1_comp_low_sum[PdTargetSplit-1:0]);
    assume (i_from_if_to_pd.pd_target_compressed_high_select ==
            {pd_imm_b_compressed[PdTargetSplit-1], formal_s1_comp_low_sum[PdTargetSplit]});
    assume (i_from_if_to_pd_2.pd_target_native_low == formal_s2_native_low_sum[PdTargetSplit-1:0]);
    assume (i_from_if_to_pd_2.pd_target_native_high_select ==
            {pd_slot2_imm_b_native[PdTargetSplit-1], formal_s2_native_low_sum[PdTargetSplit]});
    assume (i_from_if_to_pd_2.pd_target_compressed_low ==
            formal_s2_comp_low_sum[PdTargetSplit-1:0]);
    assume (i_from_if_to_pd_2.pd_target_compressed_high_select ==
            {pd_slot2_imm_b_compressed[PdTargetSplit-1], formal_s2_comp_low_sum[PdTargetSplit]});
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
                !o_from_pd_to_id_2.fetch_fault && !o_from_pd_to_id.fetch_fault);
      end
      if (pd_dir_redirect_1_r) begin
        p_formal_slot1_dir_redirect_is_its_branch :
        assert ((o_from_pd_to_id.instruction == formal_slot1_instruction_q) &&
                (o_from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH) &&
                (o_from_pd_to_id.instruction[14:13] != 2'b01) &&
                !o_from_pd_to_id.inject_nop && !o_from_pd_to_id.fetch_fault);
      end
      if (pd_dir_redirect_2_r) begin
        p_formal_slot2_dir_redirect_is_its_branch :
        assert ((o_from_pd_to_id_2.instruction == formal_slot2_instruction_q) &&
                (o_from_pd_to_id_2.instruction[6:0] == riscv_pkg::OPC_BRANCH) &&
                (o_from_pd_to_id_2.instruction[14:13] != 2'b01) &&
                !o_from_pd_to_id_2.inject_nop && !o_from_pd_to_id_2.fetch_fault &&
                !o_from_pd_to_id.fetch_fault && !pd_dir_redirect_1_r && !pd_backing_redirect_r);
      end
      if ((o_from_pd_to_id.illegal_instruction ||
           (!o_from_pd_to_id.inject_nop && o_from_pd_to_id.is_compressed &&
            (o_from_pd_to_id.instruction == 32'h0010_0073))) &&
          !o_from_pd_to_id.fetch_fault) begin
        p_reserved_slot_holds_redirect :
        assert (!o_pd_redirect && o_from_pd_to_id_2.inject_nop &&
                (o_q_cond_branch == 2'b00) && (o_q_jalr == 2'b00) &&
                (o_q_itt_eligible == 2'b00) && (o_q_cf == 2'b00));
      end
      if (o_from_pd_to_id_2.illegal_instruction && !o_from_pd_to_id_2.fetch_fault) begin
        p_reserved_slot2_no_redirect : assert (!o_pd_redirect_slot2);
      end
      if (pd_older_illegal) begin
        p_reserved_slot_has_no_history :
        assert (o_jalr == 0 && o_jump == 0 && o_cond_branch == 0 && o_itt_eligible == 0);
      end
      cover (pd_older_illegal && i_from_if_to_pd.raw_parcel == 16'h8002 &&
             !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault &&
             is_jalr(
          i_from_if_to_pd_2.effective_instr
      ) && i_itt_hit[1] && !i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush && !pd_redirect_r);
      cover (pd_older_illegal && i_from_if_to_pd.raw_parcel == 16'h9002 &&
             !i_from_if_to_pd_2.sel_nop && !i_from_if_to_pd_2.fetch_fault &&
             is_jalr(
          i_from_if_to_pd_2.effective_instr
      ) && i_itt_hit[1] && !i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush && !pd_redirect_r);
      cover (pd_itt_redirect_2_r && !pd_itt_redirect_r &&
             (o_from_pd_to_id_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] !=
              o_from_pd_to_id.program_counter[XLEN-1:riscv_pkg::PhysAddrBits]));
      if (o_pd_redirect_slot2) begin
        p_formal_slot2_flag_is_a_slot2_redirect :
        assert ((pd_backing_redirect_2_r || pd_dir_redirect_2_r || pd_itt_redirect_2_r) &&
                !o_from_pd_to_id_2.inject_nop);
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
      // A push or pop requires a redirect from its registered call or return.
      if (o_pd_redirect_ras_push) begin
        p_formal_push_is_a_redirected_call :
        assert (((pd_backing_redirect_r || pd_itt_redirect_r) && pd_registered_call) ||
                ((pd_backing_redirect_2_r || pd_itt_redirect_2_r) && pd_registered_call_2));
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
      p_formal_slot1_target_split_exact :
      assert (pd_target_selected_split == pd_backward_target_reference);
      p_formal_slot2_target_split_exact :
      assert (pd_slot2_target_split == pd_slot2_target_reference);
      if (pd_redirect_candidate_payload_reference_armed) begin
        p_formal_candidate_payload_exact :
        assert ((!pd_reg_live[0] ||
                 ((pd_taken_candidate_r == pd_taken_candidate_payload_reference_q) &&
                  (pd_not_taken_candidate_r == pd_not_taken_candidate_payload_reference_q))) &&
                (!pd_reg_live[1] ||
                 ((pd_taken_candidate_2_r == pd_taken_candidate_2_payload_reference_q) &&
                  (pd_not_taken_candidate_2_r == pd_not_taken_candidate_2_payload_reference_q))));
        p_formal_candidates_exclusive :
        assert (!(pd_taken_candidate_r && pd_not_taken_candidate_r) &&
                !(pd_taken_candidate_2_r && pd_not_taken_candidate_2_r));
      end
      // The reference models above: the qualified redirect and its
      // direction, the per-slot branch target capture, the full-width target,
      // and each backing redirect's decoded-rule target.
      if (pd_redirect_reference_armed) begin
        p_formal_redirect_matches_reference : assert (pd_redirect_r == pd_redirect_reference_q);
        p_formal_dir_redirect_2_matches_reference :
        assert (pd_dir_redirect_2_r == pd_dir_redirect_2_reference_q);
        p_formal_direction_matches_reference :
        assert (!pd_redirect_r || (o_pd_redirect_taken == pd_redirect_taken_reference_q));
      end
      if (pd_redirect_target_reference_armed) begin
        p_formal_s1_br_target_capture_exact :
        assert (!pd_reg_live[0] ||
                ((pd_s1_br_low == pd_s1_br_low_reference_r) &&
                 (pd_s1_br_hs == pd_s1_br_hs_reference_r)));
        p_formal_s2_br_target_capture_exact :
        assert (!pd_reg_live[1] ||
                ((pd_s2_br_low == pd_s2_br_low_reference_r) &&
                 (pd_s2_br_hs == pd_s2_br_hs_reference_r)));
      end
      if (pd_redirect_target_reference_armed && pd_redirect_reference_armed) begin
        p_formal_target_matches_reference :
        assert (!pd_redirect_r || (o_pd_redirect_target == pd_redirect_target_reference));
      end
      if (pd_backing_decoded_reference_armed) begin
        p_formal_slot1_target_matches_decode :
        assert (!(pd_backing_redirect_r && pd_backing_decoded_reference_valid_q &&
                  !pd_itt_target_select_r) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_q));
        p_formal_slot2_target_matches_decode :
        assert (!(pd_backing_redirect_2_r && !pd_backing_redirect_r &&
                  pd_backing_decoded_reference_valid_2_q && !pd_itt_target_select_r) ||
                (o_pd_redirect_target == pd_backing_decoded_target_reference_2_q));
      end
      // An indirect target redirect fires for its slot's registered JALR that
      // is not a return.
      if (pd_itt_redirect_r) begin
        p_formal_slot1_indirect_payload :
        assert (o_pd_redirect && o_pd_redirect_taken && !o_pd_redirect_slot2 &&
                o_pd_redirect_target == formal_itt_slot_target_q[0]);
        p_formal_slot1_itt_redirect_is_its_jalr :
        assert (is_jalr(
            o_from_pd_to_id.instruction
        ) && !pd_registered_return && !o_from_pd_to_id.inject_nop);
      end
      if (pd_itt_redirect_2_r) begin
        p_formal_slot2_indirect_payload :
        assert (o_pd_redirect && o_pd_redirect_taken && o_pd_redirect_slot2 &&
                o_pd_redirect_target == formal_itt_slot_target_q[1]);
        p_formal_slot2_itt_redirect_is_its_jalr :
        assert (is_jalr(
            o_from_pd_to_id_2.instruction
        ) && !pd_registered_return_2 && !o_from_pd_to_id_2.inject_nop);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (formal_past_valid && !i_pipeline_ctrl.reset) begin
      cover (pd_itt_redirect_r && pd_backing_redirect_r);
      cover (pd_itt_redirect_2_r && pd_backing_redirect_2_r);
      cover (pd_backing_redirect_r && !o_pd_redirect_ras_push && !o_pd_redirect_ras_pop);
      cover (pd_backing_redirect_2_r && o_pd_redirect_ras_push);
      cover (pd_backing_redirect_r && o_pd_redirect_ras_pop &&
             (o_pd_redirect_target == o_from_pd_to_id.ras_checkpoint_top));
      cover (pd_backing_redirect_2_r && o_pd_redirect_ras_pop);
      cover (pd_backing_redirect_r && i_pipeline_ctrl.stall);
      cover (pd_redirect_r && !pd_backing_redirect_r && !pd_backing_redirect_2_r &&
             pd_redirect_reference_armed && pd_redirect_target_reference_armed);
      cover (pd_dir_redirect_2_r && o_pd_redirect_taken &&
             pd_redirect_reference_armed && pd_redirect_target_reference_armed);
      cover (pd_dir_redirect_2_r && !o_pd_redirect_taken &&
             pd_redirect_reference_armed && pd_redirect_target_reference_armed);
      cover (pd_dir_redirect_2_r && pd_reg_s2_pc_carry && o_pd_redirect_taken);
      cover (pd_dir_redirect_2_r && pd_reg_s2_pc_carry && !o_pd_redirect_taken);
      cover (pd_backing_redirect_r && pd_backing_decoded_reference_armed &&
             pd_backing_decoded_reference_valid_q);
      cover (pd_backing_redirect_2_r && !pd_backing_redirect_r &&
             pd_backing_decoded_reference_armed && pd_backing_decoded_reference_valid_2_q);
      cover (pd_itt_redirect_r && o_from_pd_to_id.btb_predicted_taken);
      cover (pd_itt_redirect_2_r && o_pd_redirect_ras_push);
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // Cover points for simulation coverage (tests/README.md).
  // A slot-2 conditional branch redirects to its taken target from the tagged predictor.
  cover_pd_slot2_taken_redirect :
  cover property (@(posedge i_clk) disable iff (!pd_sim_reset_seen_q || i_pipeline_ctrl.reset)
      pd_dir_redirect_2_r && o_pd_redirect_taken && !i_pipeline_ctrl.stall &&
      !i_pipeline_ctrl.flush);
  // A slot-2 conditional branch vetoes a taken BTB prediction from the tagged predictor.
  cover_pd_slot2_not_taken_veto :
  cover property (@(posedge i_clk) disable iff (!pd_sim_reset_seen_q || i_pipeline_ctrl.reset)
      pd_dir_redirect_2_r && !o_pd_redirect_taken && !i_pipeline_ctrl.stall &&
      !i_pipeline_ctrl.flush);
  // A slot-2 direction redirect is held through a stall before firing.
  cover_pd_slot2_redirect_held_through_stall :
  cover property (@(posedge i_clk) disable iff (!pd_sim_reset_seen_q || i_pipeline_ctrl.reset)
      pd_dir_redirect_2_r && i_pipeline_ctrl.stall);
  // A slot-2 direction candidate or redirect is cleared by a flush.
  cover_pd_slot2_candidate_lost_to_flush :
  cover property (@(posedge i_clk) disable iff (!pd_sim_reset_seen_q || i_pipeline_ctrl.reset)
      i_pipeline_ctrl.flush &&
      (pd_dir_redirect_2_r || pd_taken_candidate_2_r || pd_not_taken_candidate_2_r));
`endif
`endif

endmodule : pd_stage
