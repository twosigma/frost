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
  - Instruction selection muxing (NOP, spanning, compressed, or aligned)
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
    output riscv_pkg::from_pd_to_id_t o_from_pd_to_id
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
    if (i_from_if_to_pd.sel_spanning) instruction_non_nop = i_from_if_to_pd.spanning_instr;
    else if (i_from_if_to_pd.sel_compressed) instruction_non_nop = decompressed_instr;
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
  // For 32-bit instructions, extract from effective_instr (spanning or aligned).
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
  // Pipeline Register: PD → ID
  // ===========================================================================
  // Register all outputs to ID stage with stall and flush support.

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      // On reset, insert NOP into pipeline
      o_from_pd_to_id.instruction                <= riscv_pkg::NOP;
      o_from_pd_to_id.program_counter            <= '0;
      o_from_pd_to_id.link_address               <= '0;
      o_from_pd_to_id.source_reg_1_early         <= 5'd0;
      o_from_pd_to_id.source_reg_2_early         <= 5'd0;
      o_from_pd_to_id.fp_source_reg_3_early      <= 5'd0;  // F extension: FMA rs3
      o_from_pd_to_id.illegal_instruction        <= 1'b0;
      // Branch prediction metadata
      o_from_pd_to_id.btb_hit                    <= 1'b0;
      o_from_pd_to_id.btb_predicted_taken        <= 1'b0;
      o_from_pd_to_id.btb_predicted_target       <= '0;
      // RAS prediction metadata
      o_from_pd_to_id.ras_predicted              <= 1'b0;
      o_from_pd_to_id.ras_predicted_target       <= '0;
      o_from_pd_to_id.ras_checkpoint_tos         <= '0;
      o_from_pd_to_id.ras_checkpoint_valid_count <= '0;
    end else if (~i_pipeline_ctrl.stall) begin
      // When flushing, insert NOP; otherwise pass values from decompression
      o_from_pd_to_id.instruction <= i_pipeline_ctrl.flush ? riscv_pkg::NOP : final_instruction;
      o_from_pd_to_id.program_counter <= i_from_if_to_pd.program_counter;
      o_from_pd_to_id.link_address <= i_from_if_to_pd.link_address;
      // Early source registers for forwarding/hazard timing
      o_from_pd_to_id.source_reg_1_early <= i_pipeline_ctrl.flush ? 5'd0 : source_reg_1;
      o_from_pd_to_id.source_reg_2_early <= i_pipeline_ctrl.flush ? 5'd0 : source_reg_2;
      o_from_pd_to_id.fp_source_reg_3_early <= i_pipeline_ctrl.flush ? 5'd0 : fp_source_reg_3;
      // Illegal compressed indication is only valid when compressed decode path is selected.
      o_from_pd_to_id.illegal_instruction <= i_pipeline_ctrl.flush ? 1'b0 :
                                             (!i_from_if_to_pd.sel_nop &&
                                              i_from_if_to_pd.sel_compressed &&
                                              decomp_is_compressed && decomp_illegal);
      // Branch prediction metadata - clear on flush (prediction for flushed instr is invalid)
      o_from_pd_to_id.btb_hit <= i_pipeline_ctrl.flush ? 1'b0 : i_from_if_to_pd.btb_hit;
      o_from_pd_to_id.btb_predicted_taken <= i_pipeline_ctrl.flush ? 1'b0 :
                                              i_from_if_to_pd.btb_predicted_taken;
      o_from_pd_to_id.btb_predicted_target <= i_from_if_to_pd.btb_predicted_target;
      // RAS prediction metadata - clear on flush (prediction for flushed instr is invalid)
      o_from_pd_to_id.ras_predicted <= i_pipeline_ctrl.flush ? 1'b0 : i_from_if_to_pd.ras_predicted;
      o_from_pd_to_id.ras_predicted_target <= i_from_if_to_pd.ras_predicted_target;
      o_from_pd_to_id.ras_checkpoint_tos <= i_from_if_to_pd.ras_checkpoint_tos;
      o_from_pd_to_id.ras_checkpoint_valid_count <= i_from_if_to_pd.ras_checkpoint_valid_count;
    end
    // When stalled, hold current values (implicit - no else clause)
  end

endmodule : pd_stage
