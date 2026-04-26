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
  Pre-Decode (PD) Stage - Second stage of the 6-stage RISC-V pipeline.

  This stage performs RVC decompression and instruction selection. The IF stage
  outputs raw parcel and selection signals; PD performs the actual decompression.
  This breaks the long combinational path from memory read through decompression
  to pipeline registers.

  Key operations:
  - RVC decompression (16-bit to 32-bit instruction expansion)
  - Instruction selection muxing (NOP, compressed, or aligned; spanning is pre-assembled in IF)
  - Early source register extraction for forwarding/hazard timing

  The decompressed/selected instruction is registered and passed to ID stage,
  which performs full instruction decoding and immediate extraction.

  Flush is observed here (along with ID stage) during the 2-cycle flush
  window after branches, traps, or MRET.
*/
module pd_stage #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd,
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id,
    // Backward-branch-taken static heuristic: PD redirect to IF
    output logic o_pd_redirect,
    output logic [XLEN-1:0] o_pd_redirect_target
);

  // ===========================================================================
  // RVC Decompressor
  // ===========================================================================
  // Decompress the raw 16-bit parcel from IF stage.
  // This runs from registered values, giving a full cycle for decompression.

  logic [31:0] decompressed_instr;
  logic        decomp_is_compressed;
  logic        decomp_illegal;

  rvc_decompressor decompressor_inst (
      .i_instr_compressed(i_from_if_to_pd.raw_parcel),
      .o_instr_expanded(decompressed_instr),
      .o_is_compressed(decomp_is_compressed),
      .o_illegal(decomp_illegal)
  );

  // ===========================================================================
  // Final Instruction Selection
  // ===========================================================================
  // Select final instruction based on selection signals from IF stage.
  // Selection signals are already registered at IF→PD boundary.
  // Use a priority mux to avoid relying on one-hot guarantees for sel_*.

  logic [31:0] final_instruction;
  logic [31:0] instruction_non_nop;

  always_comb begin
    if (i_from_if_to_pd.sel_compressed) instruction_non_nop = decompressed_instr;
    else instruction_non_nop = i_from_if_to_pd.effective_instr;
  end

  always_comb begin
    if (i_from_if_to_pd.sel_nop) final_instruction = riscv_pkg::NOP;
    else final_instruction = instruction_non_nop;
  end

  // ===========================================================================
  // Early Source Register Extraction (Timing Optimized)
  // ===========================================================================
  // Extract source registers in parallel with decompression for forwarding/hazard
  // detection. This runs from registered values and feeds into registered outputs.
  //
  // For compressed instructions, extract from the decompressed instruction output.
  // For 32-bit instructions, extract from effective_instr (spanning is pre-assembled in IF).
  // For NOP, source registers are x0.
  //
  // This is simpler than the reverted approach that extracted in IF stage because:
  // 1. We work from registered values (no timing pressure)
  // 2. We can just extract from the final instruction output

  logic [4:0] source_reg_1;
  logic [4:0] source_reg_2;
  logic [4:0] fp_source_reg_3;  // F extension: rs3 for FMA instructions

  // Extract from final instruction - bits [19:15] for rs1, bits [24:20] for rs2
  assign source_reg_1 = final_instruction[19:15];
  assign source_reg_2 = final_instruction[24:20];
  // F extension: rs3 for FMA is in bits [31:27] (R4-type format)
  assign fp_source_reg_3 = final_instruction[31:27];

  // ===========================================================================
  // Backward-Branch-Taken Static Heuristic
  // ===========================================================================
  // Detect backward conditional branches that the BTB missed. Predict them as
  // taken and redirect IF to the computed target. This saves ~4-5 cycles vs
  // waiting for EX-stage misprediction recovery on cold-start BTB misses.
  //
  // After decompression, ALL conditional branches (including C.BEQZ/C.BNEZ)
  // have B-type format with opcode 7'b1100011 and sign bit at bit[31].

  // B-type immediate extraction from the decompressed instruction
  logic [XLEN-1:0] pd_imm_b;
  assign pd_imm_b = {
    {19{final_instruction[31]}},  // sign-extend bits [31:13]
    final_instruction[31],  // imm[12]
    final_instruction[7],  // imm[11]
    final_instruction[30:25],  // imm[10:5]
    final_instruction[11:8],  // imm[4:1]
    1'b0  // imm[0] always zero
  };

  logic [XLEN-1:0] pd_backward_target;
  assign pd_backward_target = i_from_if_to_pd.program_counter + pd_imm_b;

  logic pd_backward_branch;
  assign pd_backward_branch =
      (final_instruction[6:0] == riscv_pkg::OPC_BRANCH) &&  // conditional branch
      final_instruction[31] &&  // backward (negative offset)
      !i_from_if_to_pd.btb_predicted_taken &&  // BTB didn't predict
      !i_from_if_to_pd.ras_predicted &&  // RAS didn't predict
      !i_from_if_to_pd.sel_nop &&  // not a bubble
      !pd_redirect_r;  // not already redirecting
  // pd_redirect_r suppression is critical: when the registered redirect fires,
  // the wrong-path instruction in PD could look like a backward branch. Without
  // this guard, a spurious second redirect fires and its holdoff cycle squashes
  // the real target instruction arriving from BRAM.

  // Redirect output to IF — REGISTERED for timing.
  // Registering eliminates the cross-module combinational path (32-bit adder +
  // routing from PD to IF's PC mux) that caused a ~1ns timing regression.
  // Cost: 2 bubble cycles instead of 1 per redirect. The extra bubble is the
  // wrong-path instruction that enters PD before the registered redirect fires;
  // it is squashed by forcing NOP into the PD→ID register (see pd_redirect_r
  // usage below).
  logic pd_redirect_r;
  logic [XLEN-1:0] pd_redirect_target_r;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) pd_redirect_r <= 1'b0;
    else if (!i_pipeline_ctrl.stall) pd_redirect_r <= pd_backward_branch;
    // Hold during stall (implicit)
  end

  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.stall) pd_redirect_target_r <= pd_backward_target;
  end

  assign o_pd_redirect = pd_redirect_r;
  assign o_pd_redirect_target = pd_redirect_target_r;

  // ===========================================================================
  // Pipeline Register: PD → ID
  // ===========================================================================
  // Register all outputs to ID stage with stall and flush support.

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      // On reset, insert NOP into pipeline
      o_from_pd_to_id.instruction         <= riscv_pkg::NOP;
      o_from_pd_to_id.illegal_instruction <= 1'b0;
      // Branch prediction metadata
      o_from_pd_to_id.btb_hit             <= 1'b0;
      o_from_pd_to_id.btb_predicted_taken <= 1'b0;
      // RAS prediction metadata
      o_from_pd_to_id.ras_predicted       <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      // When flushing or when the registered PD redirect fires (squashing the
      // wrong-path instruction that entered PD one cycle after detection),
      // insert NOP; otherwise pass values from decompression.
      //
      // pd_redirect_r is a registered signal (no timing concern in this mux).
      o_from_pd_to_id.instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ?
                                      riscv_pkg::NOP : final_instruction;
      // Illegal compressed indication is only valid when compressed decode path is selected.
      o_from_pd_to_id.illegal_instruction <= (i_pipeline_ctrl.flush || pd_redirect_r) ? 1'b0 :
                                             (!i_from_if_to_pd.sel_nop &&
                                              i_from_if_to_pd.sel_compressed &&
                                              decomp_is_compressed && decomp_illegal);
      // Branch prediction metadata - clear on flush/pd_redirect.
      //
      // TIMING: the pd_backward_branch heuristic override (mark cold backward
      // branches as predicted-taken with the +imm target) used to be applied
      // here. That created a long combinational chain
      //   BRAM out → c_ext_state mux → assembled_instr → final_instruction
      //   → pd_imm_b → +PC carry chain → o_from_pd_to_id_reg[btb_predicted_target]/D
      // which became the worst path (-0.469 ns) once the LQ → data_memory cone
      // closed. The o_from_pd_to_id register now passes the BTB metadata through
      // unchanged; id_stage applies the override on its consumer side using the
      // already-registered pd_redirect_r / pd_redirect_target_r outputs (the same
      // signals that drive the IF redirect). Both override sources are FF
      // outputs there, so the mux is a fast LUT instead of a 12-level cone.
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
      o_from_pd_to_id.link_address <= i_from_if_to_pd.link_address;
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
    end
    // When stalled, hold current values (implicit - no else clause)
  end

endmodule : pd_stage
