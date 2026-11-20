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

// The fetch-input contract of the frozen pre-change PD
// (predictor_reference/pd_stage.original.sv), copied verbatim with the
// signals it reads: the sixteen assumptions pd_history_twin keeps. The twin
// read them from the frozen file before; this copy compiles none of that
// file's simulation checks. The eight target-sum and three slot-1
// source-field assumptions the twin drops are left out.
module pd_fetch_contract #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    input logic [1:0] i_backing_hit,
    input logic [1:0] i_backing_compressed,
    input logic [1:0] i_backing_return,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target,
    input logic [1:0] i_backing_slot2_return_by_size,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_slot2_target_by_size,
    input logic [1:0] i_itt_hit,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_itt_target
);
  localparam int unsigned PdTargetSplit = riscv_pkg::PdTargetSplit;
  localparam int unsigned PdTargetHighWidth = XLEN - PdTargetSplit;

  // IF uses sel_compressed for PC and buffer control. Legality is predecoded.
  logic pd_sel_compressed;
  logic decomp_illegal;
  assign pd_sel_compressed = (i_from_if_to_pd.raw_parcel[1:0] != 2'b11);
  assign decomp_illegal = i_from_if_to_pd.rvc_extra_predecoded[22];

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

  logic pd_sel_compressed_2;
  logic [31:0] instruction_non_nop_2;
  logic [4:0] source_reg_1_2;
  logic [4:0] source_reg_2_2;
  assign pd_sel_compressed_2 = i_from_if_to_pd_2.sel_compressed;
  assign instruction_non_nop_2 = i_from_if_to_pd_2.effective_instr;
  assign source_reg_1_2 = {
    i_from_if_to_pd_2.rs1_rest_predecoded[2:1],
    i_from_if_to_pd_2.source_hot_predecoded[1:0],
    i_from_if_to_pd_2.rs1_rest_predecoded[0]
  };
  assign source_reg_2_2 = i_from_if_to_pd_2.bits24_20_predecoded;

  logic [31:0] decompressed_instr_2;
  logic        decomp_illegal_reference_2;
  rvc_decompressor decompressor_2_inst (
      .i_instr_compressed(i_from_if_to_pd_2.raw_parcel),
      .o_instr_expanded(decompressed_instr_2),
      .o_is_compressed(),
      .o_illegal(decomp_illegal_reference_2)
  );

  logic [PdTargetHighWidth-1:0] pd_pc_high_plus_one;
  logic [PdTargetHighWidth-1:0] pd_pc_high_minus_one;
  pd_target_high_precompute #(
      .HIGH_WIDTH(PdTargetHighWidth)
  ) u_pd_target_high_precompute (
      .i_pc_high          (i_from_if_to_pd.program_counter[XLEN-1:PdTargetSplit]),
      .o_pc_high_plus_one (pd_pc_high_plus_one),
      .o_pc_high_minus_one(pd_pc_high_minus_one)
  );
  logic [PdTargetSplit:0] pd_slot2_pc_sum;
  logic pd_slot2_pc_carry;
  logic [PdTargetSplit-1:0] pd_slot2_pc_low;
  assign pd_slot2_pc_sum = {1'b0, i_from_if_to_pd.program_counter[PdTargetSplit-1:0]} +
      (pd_sel_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                           (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_slot2_pc_carry = pd_slot2_pc_sum[PdTargetSplit];
  assign pd_slot2_pc_low = pd_slot2_pc_sum[PdTargetSplit-1:0];

  logic formal_past_valid = 1'b0;
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
  end
endmodule
