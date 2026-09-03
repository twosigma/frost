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
  Pre-Decode (PD) stage: second stage of the in-order front-end.

  PD expands the slot-1 compressed parcel (16-bit to 32-bit) and selects the
  final instruction for each slot. IF supplies the slot-1 raw parcel and the
  selection signals, so decompression runs from registered values here rather
  than extending the path from instruction-memory read through the expander into
  a pipeline register. Slot 2 arrives already decompressed: the instruction
  aligner expands the candidate parcels beside its position select (see
  instruction_aligner.sv), so PD takes slot 2's effective_instr and
  decomp_illegal as they stand. The slot-1 mux picks a NOP, the expanded
  compressed instruction, or the aligned 32-bit word. Slot 2 needs only the NOP
  choice. Spanning instructions are assembled back in IF.

  PD also extracts the source registers early for forwarding and hazard
  detection, with narrow source-hot bypasses on the bits that set the timing,
  and builds the predicted-branch redirect target from protected native and
  compressed 13-bit candidates split across the redirect register.

  The selected instruction is registered and passed to ID, which does the full
  decode and immediate extraction. PD observes flush, along with ID, during
  branch, trap, MRET, and FENCE-class recovery.
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
    // does not. The aligner has already decompressed it: effective_instr holds
    // the finished instruction and decomp_illegal the selected candidate's
    // illegal-RVC flag, so PD only muxes and extracts. The predicted-taken
    // redirect stays slot-1 only.
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id_2,
    // Redirect to IF for a branch of either offset sign that the BTB missed and
    // the trained direction predictor calls taken. See the section below.
    output logic o_pd_redirect,
    output logic [XLEN-1:0] o_pd_redirect_target
);

  // ===========================================================================
  // RVC Decompressor
  // ===========================================================================
  // Expand the raw 16-bit parcel from IF. The parcel is registered at the
  // IF/PD boundary, so decompression gets a full cycle.

  logic [31:0] decompressed_instr;
  logic        decomp_is_compressed;
  logic        decomp_illegal;

  rvc_decompressor decompressor_inst (
      .i_instr_compressed(i_from_if_to_pd.raw_parcel),
      .i_rd_is_x2(i_from_if_to_pd.raw_parcel[11:7] == 5'd2),
      .o_instr_expanded(decompressed_instr),
      .o_is_compressed(decomp_is_compressed),
      .o_illegal(decomp_illegal)
  );

  // Derive the PD-local compressed select from the raw parcel bits instead of
  // using the IF sideband select. The sideband remains useful for PC/buffer
  // timing in IF, but keeping it out of PD's instruction/target muxes avoids a
  // BRAM sideband -> final-instruction -> branch-target carry-chain path.
  logic pd_sel_compressed;
  assign pd_sel_compressed = decomp_is_compressed;

  // ===========================================================================
  // Final Instruction Selection
  // ===========================================================================
  // Select the final instruction from the IF selection signals, which are
  // registered at the IF→PD boundary. These are priority muxes, so nothing
  // here depends on the sel_* signals being one-hot.

  logic [31:0] final_instruction;
  logic [31:0] instruction_non_nop;
  logic [31:0] instruction_non_nop_with_hot_rs1;

  always_comb begin
    if (pd_sel_compressed) instruction_non_nop = decompressed_instr;
    else instruction_non_nop = i_from_if_to_pd.effective_instr;
  end

  // The two slot-1 instruction endpoints in the current low-IMEM set are
  // rs1[2:1], instruction bits [17:16]. Drive those two D inputs from the
  // source-hot metadata IF carries instead. Every other instruction bit, and
  // all early-source bits, keep their existing cones.
  assign instruction_non_nop_with_hot_rs1 = {
    instruction_non_nop[31:18],
    i_from_if_to_pd.source_hot_predecoded[1:0],
    instruction_non_nop[15:0]
  };

  always_comb begin
    if (i_from_if_to_pd.sel_nop) final_instruction = riscv_pkg::NOP;
    else final_instruction = instruction_non_nop;
  end

  // ===========================================================================
  // Early Source Register Extraction
  // ===========================================================================
  // Extract the source registers beside decompression, for forwarding and
  // hazard detection. Inputs and outputs are both registered, so there is slack
  // here. A compressed instruction takes its fields from the decompressor
  // output, a 32-bit instruction from effective_instr (spanning words are
  // assembled in IF), and a NOP reads x0. An earlier version extracted in IF
  // instead and was reverted; extracting from the already selected instruction
  // here is shorter and off the critical path.

  logic [4:0] source_reg_1;
  logic [4:0] source_reg_2;
  logic [4:0] fp_source_reg_3;  // F extension: rs3 for FMA instructions

  assign source_reg_1 = final_instruction[19:15];
  assign source_reg_2 = final_instruction[24:20];
  // F extension: rs3 for FMA is in bits [31:27] (R4-type format)
  assign fp_source_reg_3 = final_instruction[31:27];

  // ===========================================================================
  // Slot-2: Instruction Selection and Source Extraction
  // ===========================================================================
  // Mirror of the slot-1 logic above, driven from i_from_if_to_pd_2. Slot 2
  // sits out the predicted-taken redirect, which is slot-1 only: a slot-1
  // branch terminates the bundle back in the aligner (decision #1 there), so
  // slot 2 is already invalid on any cycle the redirect can fire.

  // Slot 2 arrives already decompressed. The aligner expands the three
  // candidate parcels beside its position select and delivers the finished
  // instruction in effective_instr for both the RVC and native cases, plus the
  // selected candidate's illegal-RVC flag in decomp_illegal. That removes the
  // serial position-mux -> RVC expander cone which put the o_from_pd_to_id_2
  // instruction in the post-opt WNS group on x3. sel_compressed carries the
  // sideband compressed flag, bit-identical to the parcel-derived
  // o_is_compressed that a local decompressor produced.
  logic pd_sel_compressed_2;
  assign pd_sel_compressed_2 = i_from_if_to_pd_2.sel_compressed;

  logic [31:0] final_instruction_2;
  logic [31:0] instruction_non_nop_2;
  logic [21:0] slot2_instruction_non_source_q;
  logic [21:0] final_instruction_non_source_2;

  // The architectural instruction and the early hazard metadata used to
  // duplicate the same rs1/rs2 state in two FF banks. Keep one canonical
  // registered copy in the early fields and register only the remaining
  // instruction bits here. This removes the deeper duplicate source-field D
  // cone without changing the PD->ID boundary or adding a cycle.
  localparam logic [21:0] Slot2NopNonSource = {7'b0000000, 15'h0013};

  assign instruction_non_nop_2 = i_from_if_to_pd_2.effective_instr;

  always_comb begin
    if (i_from_if_to_pd_2.sel_nop) final_instruction_2 = riscv_pkg::NOP;
    else final_instruction_2 = instruction_non_nop_2;
  end

  logic [4:0] source_reg_1_2;
  logic [4:0] source_reg_2_2;
  logic [4:0] fp_source_reg_3_2;

  // Extract the payload bits before NOP injection.  The dedicated registered
  // clear below carries slot invalidation on the FDRE reset pin, keeping the
  // final bubble/flush mux off these 15 timing-facing D inputs.
  // The three slot-2 low-IMEM endpoints are early rs1[2:1] and rs2[1].
  // The early fields are slot 2's canonical instruction-source
  // registers, so this also keeps its reconstructed instruction coherent.
  assign source_reg_1_2 = {
    instruction_non_nop_2[19:18],
    i_from_if_to_pd_2.source_hot_predecoded[1:0],
    instruction_non_nop_2[15]
  };
  assign source_reg_2_2 = {
    instruction_non_nop_2[24:22],
    i_from_if_to_pd_2.source_hot_predecoded[2],
    instruction_non_nop_2[20]
  };
  assign fp_source_reg_3_2 = instruction_non_nop_2[31:27];
  assign final_instruction_non_source_2 = {final_instruction_2[31:25], final_instruction_2[14:0]};
  assign o_from_pd_to_id_2.instruction = {
    slot2_instruction_non_source_q[21:15],
    o_from_pd_to_id_2.source_reg_2_early,
    o_from_pd_to_id_2.source_reg_1_early,
    slot2_instruction_non_source_q[14:0]
  };

`ifndef SYNTHESIS
  // This metadata is a physical bypass of instruction bits that already exist.
  // Check the packet contract wherever both representations are available, so
  // the overridden instruction and the early-source registers cannot diverge
  // from the architectural instruction. The IF packet registers hold nothing
  // meaningful until their first reset edge, and cocotb can start the clock
  // before it drives top-level reset, so arm these checks only once a reset has
  // been seen at a clock edge.
  logic source_hot_checks_armed = 1'b0;
  always @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) source_hot_checks_armed <= 1'b1;

    if (source_hot_checks_armed && !i_pipeline_ctrl.reset && !$isunknown(
            {i_from_if_to_pd.sel_nop, i_from_if_to_pd.source_hot_predecoded, instruction_non_nop}
        ) && !i_from_if_to_pd.sel_nop) begin
      p_slot1_source_hot_matches_instruction :
      assert (
          i_from_if_to_pd.source_hot_predecoded ==
          {instruction_non_nop[21], instruction_non_nop[17:16]}
      );
    end
    if (source_hot_checks_armed && !i_pipeline_ctrl.reset && !$isunknown(
            {
              i_from_if_to_pd_2.sel_nop,
              i_from_if_to_pd_2.source_hot_predecoded,
              instruction_non_nop_2
            }
        ) && !i_from_if_to_pd_2.sel_nop) begin
      p_slot2_source_hot_matches_instruction :
      assert (
          i_from_if_to_pd_2.source_hot_predecoded ==
          {instruction_non_nop_2[21], instruction_non_nop_2[17:16]}
      );
      p_slot2_early_rs1_matches_instruction :
      assert (source_reg_1_2 == instruction_non_nop_2[19:15]);
      p_slot2_early_rs1_hot_bits_are_direct :
      assert (source_reg_1_2[2:1] == i_from_if_to_pd_2.source_hot_predecoded[1:0]);
    end
  end
`endif

  // ===========================================================================
  // Predicted-Taken Redirect on BTB Miss
  // (generalized from the former backward-branch static heuristic)
  // ===========================================================================
  // Detect conditional branches of either offset sign that the BTB missed and
  // that the decoupled direction predictor calls taken, then redirect IF to the
  // computed PC+imm target. That saves ~4-5 cycles against waiting for EX-stage
  // misprediction recovery. This once fired only for backward offsets under a
  // static "backward => taken" rule. It now follows the trained direction
  // predictor (carried as bp_dir_taken), so forward taken branches that thrash
  // the 256-entry BTB also redirect here instead of mispredicting.
  //
  // Compute native B-type and compressed C.BEQZ/C.BNEZ branch targets in two
  // protected, format-specific 13-bit carry-select candidates. Both
  // immediates fit after sign-extending the compressed 9-bit offset to 13
  // bits. If s is that 13-bit immediate's sign and c is the low-add carry,
  // the high result is exactly PC_high+c-s: unchanged for {s,c}=00/11, +1
  // for 01, and -1 for 10.
  //
  // The PC-high +/-1 candidates depend only on the registered PC and settle
  // before the instruction BRAM responds. Protected candidate boundaries keep
  // the compressed/native mode select after both low carry cones. Without them
  // Vivado folds the candidates algebraically into one selected-immediate
  // adder. At the existing redirect register edge, PD captures the selected low
  // result, the raw {sign, carry} state, and three PC-high banks. The following
  // redirect-to-IF cycle decodes that registered state in the existing shallow
  // high-bank mux, which keeps the correction encoder out of the late
  // carry-to-D cone. The full target stays modulo-XLEN exact and redirect
  // latency is unchanged.

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

  // Fire the PD redirect for any conditional branch, native B-type or
  // compressed C.BEQZ/C.BNEZ, that the front-end has not already redirected and
  // that the decoupled bimodal predicts taken (carried from IF as
  // bp_dir_taken). The target pieces above cover both offset signs, so forward
  // taken branches that miss the BTB redirect here instead of stalling to an
  // EX-stage misprediction. The signal keeps the name pd_backward_branch to
  // limit churn.
  logic pd_backward_branch;
  assign pd_backward_branch =
      (pd_native_branch || pd_compressed_branch) &&  // conditional branch (any offset)
      i_from_if_to_pd.bp_dir_taken &&  // decoupled bimodal predicts TAKEN
      !i_from_if_to_pd.btb_predicted_taken &&  // front-end didn't already redirect
      !i_from_if_to_pd.ras_predicted &&  // RAS didn't predict
      !i_from_if_to_pd.sel_nop &&  // not a bubble
      !i_from_if_to_pd.fetch_fault &&  // garbage bytes must not redirect (M2)
      !pd_redirect_r;  // not already redirecting
  // The pd_redirect_r term matters: when the registered redirect fires, the
  // wrong-path instruction sitting in PD can itself look like a predicted-taken
  // branch. Without this guard a spurious second redirect fires, and its
  // holdoff cycle squashes the real target instruction arriving from BRAM.

  // The redirect output to IF is registered for timing. That removes the
  // cross-module combinational path, target adder plus routing from PD to IF's
  // PC mux, which cost ~1 ns. The price is 2 bubble cycles per redirect instead
  // of 1. The extra bubble is the wrong-path instruction that enters PD before
  // the registered redirect fires. It is squashed at the PD→ID register: slot 1
  // flags it in inject_nop for its consumers to apply, slot 2 takes a NOP
  // in-register (see the pd_redirect_r uses below).
  logic pd_redirect_r;
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
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) pd_redirect_r <= 1'b0;
    else if (!i_pipeline_ctrl.stall) pd_redirect_r <= pd_backward_branch;
    // Hold during stall (implicit)
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
  // Preserve the former full-target register as a simulation-only oracle. It
  // samples on exactly the same nonstall edges as the split banks, so this one
  // check covers boundary alignment, stall hold, format alternation, and the
  // post-boundary high-bank mux without adding hardware to the timing cone.
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
      o_from_pd_to_id.btb_hit             <= 1'b0;
      o_from_pd_to_id.btb_predicted_taken <= 1'b0;
      // RAS prediction metadata
      o_from_pd_to_id.ras_predicted       <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      // A flush, or the registered PD redirect squashing the wrong-path
      // instruction that entered PD one cycle after detection, marks the bubble
      // in inject_nop. Otherwise the values come from decompression.
      // pd_redirect_r is registered, so it costs nothing in this mux.
      //
      // The instruction passes through without being rewritten to a NOP. The
      // bubble (flush, registered pd_redirect, or sel_nop) rides in the
      // registered inject_nop bit and the consumers apply it: id_stage decode
      // and frontend_validity_tracker. That takes the deep frontend-stall-fed
      // sel_nop select off the 32-bit instruction D-mux, which is what x3
      // timing needs. final_instruction still feeds the shallow 5-bit
      // source-reg extraction below, where the sel_nop mux is off the critical
      // path.
      o_from_pd_to_id.instruction <= instruction_non_nop_with_hot_rs1;
      o_from_pd_to_id.inject_nop <= i_pipeline_ctrl.flush || pd_redirect_r ||
                                    i_from_if_to_pd.sel_nop;
      o_from_pd_to_id.is_compressed <= (i_pipeline_ctrl.flush || pd_redirect_r ||
                                        i_from_if_to_pd.sel_nop) ? 1'b0 :
                                                                 pd_sel_compressed;
      // Illegal compressed indication is only valid when compressed decode path is selected.
      o_from_pd_to_id.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                              (!i_from_if_to_pd.sel_nop &&
                                              pd_sel_compressed &&
                                              decomp_is_compressed && decomp_illegal);
      // Phase 3 M2: the fetch PMA fault rides the illegal-instruction shape,
      // with the same flush/redirect clears and the same !sel_nop gate. Decode
      // overrides the garbage bytes with the FETCH_FAULT pseudo-op.
      o_from_pd_to_id.fetch_fault <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                      (!i_from_if_to_pd.sel_nop &&
                                       i_from_if_to_pd.fetch_fault);
      // Fault kind / faulting-halfword qualifiers (M5): meaningful only
      // under fetch_fault, so they ride through unqualified.
      o_from_pd_to_id.fetch_fault_page <= i_from_if_to_pd.fetch_fault_page;
      o_from_pd_to_id.fetch_fault_hi <= i_from_if_to_pd.fetch_fault_hi;
      // Branch prediction metadata - clear on flush/pd_redirect.
      //
      // The pd_backward_branch override, marking cold backward branches
      // predicted-taken with the +imm target, used to be applied here. It
      // created a long combinational chain
      //   BRAM out → c_ext_state mux → assembled_instr → final_instruction
      //   → pd_imm_b → +PC carry chain → o_from_pd_to_id_reg[btb_predicted_target]/D
      // which became the worst path (-0.469 ns) once the LQ → data_memory cone
      // closed. This register now passes the BTB metadata through unchanged, and
      // id_stage applies the override on the consumer side from the already
      // registered pd_redirect_r and split target-bank outputs, the same signals
      // that drive the IF redirect. Both override sources are FF outputs there,
      // so the mux is one fast LUT instead of a 12-level cone.
      o_from_pd_to_id.btb_hit <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                  i_from_if_to_pd.btb_hit;
      o_from_pd_to_id.btb_predicted_taken <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                              i_from_if_to_pd.btb_predicted_taken;
      // RAS prediction metadata - clear on flush/pd_redirect
      o_from_pd_to_id.ras_predicted <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                        i_from_if_to_pd.ras_predicted;
    end

    if (~i_pipeline_ctrl.stall) begin
      o_from_pd_to_id.program_counter <= i_from_if_to_pd.program_counter;
      // Early source registers for forwarding/hazard timing
      o_from_pd_to_id.source_reg_1_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_1;
      o_from_pd_to_id.source_reg_2_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                             5'd0 : source_reg_2;
      o_from_pd_to_id.fp_source_reg_3_early <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                                5'd0 : fp_source_reg_3;
      o_from_pd_to_id.btb_predicted_target <= i_from_if_to_pd.btb_predicted_target;
      o_from_pd_to_id.ras_predicted_target <= i_from_if_to_pd.ras_predicted_target;
      o_from_pd_to_id.ras_checkpoint_tos <= i_from_if_to_pd.ras_checkpoint_tos;
      o_from_pd_to_id.ras_checkpoint_valid_count <= i_from_if_to_pd.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      o_from_pd_to_id.bp_dir_idx <= i_from_if_to_pd.bp_dir_idx;
    end
    // When stalled, hold current values (implicit - no else clause)
  end

  // ===========================================================================
  // Slot-2 Pipeline Register: PD → ID
  // ===========================================================================
  // Mirror of the slot-1 register above, driven from i_from_if_to_pd_2 and
  // pd_sel_compressed_2 / final_instruction_2 / source_reg_*_2. Stall and flush
  // gating apply to both slots alike, since a bundle advances as a whole.
  // pd_redirect_r squashes both slots: when the slot-1 redirect fires, the
  // wrong-path instruction in PD that cycle covers slot 2 too.

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      slot2_instruction_non_source_q        <= Slot2NopNonSource;
      // Slot-2 keeps its in-register NOP injection (below); inject_nop is the
      // slot-1-only x3 timing mechanism, so it is held 0 for slot-2.
      o_from_pd_to_id_2.inject_nop          <= 1'b0;
      o_from_pd_to_id_2.is_compressed       <= 1'b0;
      o_from_pd_to_id_2.illegal_instruction <= 1'b0;
      o_from_pd_to_id_2.fetch_fault         <= 1'b0;
      o_from_pd_to_id_2.fetch_fault_page    <= 1'b0;
      o_from_pd_to_id_2.fetch_fault_hi      <= 1'b0;
      o_from_pd_to_id_2.btb_hit             <= 1'b0;
      o_from_pd_to_id_2.btb_predicted_taken <= 1'b0;
      o_from_pd_to_id_2.ras_predicted       <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      slot2_instruction_non_source_q <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                          Slot2NopNonSource :
                                          final_instruction_non_source_2;
      o_from_pd_to_id_2.inject_nop <= 1'b0;  // slot-2 keeps in-register NOP (see reset)
      o_from_pd_to_id_2.is_compressed <= (i_pipeline_ctrl.flush || pd_redirect_r ||
                                          i_from_if_to_pd_2.sel_nop) ? 1'b0 :
                                                                    pd_sel_compressed_2;
      o_from_pd_to_id_2.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                                (!i_from_if_to_pd_2.sel_nop &&
                                                i_from_if_to_pd_2.decomp_illegal);
      // Phase 3 M2: slot-2 fetch-fault pass-through (see slot-1).
      o_from_pd_to_id_2.fetch_fault <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                        (!i_from_if_to_pd_2.sel_nop &&
                                         i_from_if_to_pd_2.fetch_fault);
      o_from_pd_to_id_2.fetch_fault_page <= i_from_if_to_pd_2.fetch_fault_page;
      o_from_pd_to_id_2.fetch_fault_hi <= i_from_if_to_pd_2.fetch_fault_hi;
      o_from_pd_to_id_2.btb_hit <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                    i_from_if_to_pd_2.btb_hit;
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

  // Keep the old source-field behavior exactly, but make invalidation a
  // synchronous register clear rather than a LUT on every data bit. The clear
  // includes !stall because a bubble or flush arriving during a held cycle must
  // not overwrite the replayed source addresses until the bundle advances.
  // Vivado can then map payload to D, !stall to CE, and this term to R, and the
  // residual IMEM-data -> slot-2 early-source paths lose their final LUT
  // without retiming the instruction or adding latency.
  logic slot2_early_source_clear;
  assign slot2_early_source_clear = !i_pipeline_ctrl.stall &&
      (i_pipeline_ctrl.flush || pd_redirect_r || i_from_if_to_pd_2.sel_nop);

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      o_from_pd_to_id_2.source_reg_1_early    <= 5'd0;
      o_from_pd_to_id_2.source_reg_2_early    <= 5'd0;
      o_from_pd_to_id_2.fp_source_reg_3_early <= 5'd0;
    end else if (slot2_early_source_clear) begin
      o_from_pd_to_id_2.source_reg_1_early    <= 5'd0;
      o_from_pd_to_id_2.source_reg_2_early    <= 5'd0;
      o_from_pd_to_id_2.fp_source_reg_3_early <= 5'd0;
    end else if (!i_pipeline_ctrl.stall) begin
      o_from_pd_to_id_2.source_reg_1_early    <= source_reg_1_2;
      o_from_pd_to_id_2.source_reg_2_early    <= source_reg_2_2;
      o_from_pd_to_id_2.fp_source_reg_3_early <= fp_source_reg_3_2;
    end
  end

endmodule : pd_stage
