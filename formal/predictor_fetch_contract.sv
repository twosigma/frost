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

// IF proves the packet and registered restore conditions here. The PD/history
// comparison assumes the same conditions on its inputs after the initial reset.
module predictor_fetch_contract (
    input logic i_clk,
    i_reset,
    i_pd_redirect,
    input logic [4:1] i_restore_arm,
    input riscv_pkg::from_if_to_pd_t s1,
    s2,
    input logic [1:0] i_backing_hit,
    i_backing_return,
    i_by_size_return,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target,
    i_by_size_target
);
  localparam int unsigned Width = riscv_pkg::XLEN;
  localparam int unsigned Split = riscv_pkg::PdTargetSplit;
  logic started = 1'b0;
  logic raw_compressed;
  assign raw_compressed = s1.raw_parcel[1:0] != 2'b11;
  logic [31:0] expanded1, expanded2;
  logic illegal1, illegal2;
  rvc_decompressor decoder1 (
      .i_instr_compressed(s1.raw_parcel),
      .o_instr_expanded(expanded1),
      .o_is_compressed(),
      .o_illegal(illegal1)
  );
  rvc_decompressor decoder2 (
      .i_instr_compressed(s2.raw_parcel),
      .o_instr_expanded(expanded2),
      .o_is_compressed(),
      .o_illegal(illegal2)
  );

  function automatic logic [4:0] rs1_bits(input riscv_pkg::from_if_to_pd_t packet);
    rs1_bits = {
      packet.rs1_rest_predecoded[2:1],
      packet.source_hot_predecoded[1:0],
      packet.rs1_rest_predecoded[0]
    };
  endfunction

  logic [31:0] instr1, instr2, assembled1;
  assign instr1 = raw_compressed ? expanded1 : s1.effective_instr;
  assign instr2 = s2.effective_instr;
  assign assembled1 = {
    s1.rvc_extra_predecoded[21:15],
    s1.bits24_20_predecoded,
    rs1_bits(s1),
    s1.rvc_extra_predecoded[14:0]
  };

  logic [1:0] native_low_ok, native_high_ok, compressed_low_ok, compressed_high_ok;
  for (genvar slot = 0; slot < 2; slot++) begin : gen_targets
    riscv_pkg::from_if_to_pd_t packet;
    logic [31:0] insn;
    logic [15:0] parcel;
    logic [Split-1:0] native_imm, compressed_imm;
    logic [Split:0] native_sum, compressed_sum;
    assign packet = slot == 0 ? s1 : s2;
    assign insn = packet.effective_instr;
    assign parcel = packet.raw_parcel;
    assign native_imm = Split'($signed({insn[31], insn[7], insn[30:25], insn[11:8], 1'b0}));
    assign compressed_imm = Split'($signed(
        {parcel[12], parcel[6:5], parcel[2], parcel[11:10], parcel[4:3], 1'b0}
    ));
    assign native_sum = {1'b0, packet.program_counter[Split-1:0]} + {1'b0, native_imm};
    assign compressed_sum = {1'b0, packet.program_counter[Split-1:0]} + {1'b0, compressed_imm};
    assign native_low_ok[slot] = packet.pd_target_native_low == native_sum[Split-1:0];
    assign native_high_ok[slot] = packet.pd_target_native_high_select ==
        {native_imm[Split-1], native_sum[Split]};
    assign compressed_low_ok[slot] = packet.pd_target_compressed_low == compressed_sum[Split-1:0];
    assign compressed_high_ok[slot] = packet.pd_target_compressed_high_select ==
        {compressed_imm[Split-1], compressed_sum[Split]};
  end

  always @(posedge i_clk) begin
    started <= 1'b1;
    if (!started) assume (i_reset);
    if (started) begin
      p_s1_native_low : assert (native_low_ok[0]);
      p_s1_native_high : assert (native_high_ok[0]);
      p_s1_compressed_low : assert (compressed_low_ok[0]);
      p_s1_compressed_high : assert (compressed_high_ok[0]);
      p_s2_native_low : assert (s2.sel_compressed || native_low_ok[1]);
      p_s2_native_high : assert (s2.sel_compressed || native_high_ok[1]);
      p_s2_compressed_low : assert (compressed_low_ok[1]);
      p_s2_compressed_high : assert (compressed_high_ok[1]);
      p_pd_restore : assert (!i_restore_arm[4] || $past(!i_reset && i_pd_redirect));
      p_backing_region :
      assert (!i_backing_hit[1] ||
                  s1.program_counter[Width-1:riscv_pkg::PhysAddrBits] ==
                  s2.program_counter[Width-1:riscv_pkg::PhysAddrBits]);
      p_pair_control :
      assert (s2.sel_nop || s1.fetch_fault || !(raw_compressed ? riscv_pkg::imem_compressed_control(
          s1.raw_parcel
      ) : riscv_pkg::imem_native_control(
          s1.effective_instr[6:0]
      )));
      p_pair_fault : assert (s2.sel_nop || !s1.fetch_fault || s2.fetch_fault);
      p_pair_bubble : assert (!s1.sel_nop || s2.sel_nop);
      p_backing_by_size :
      assert ({i_backing_return[1], i_backing_target[1]} ==
                {i_by_size_return[s1.sel_compressed], i_by_size_target[s1.sel_compressed]});
      p_packet_step :
      assert (s2.program_counter == s1.program_counter +
           (raw_compressed ? riscv_pkg::PcIncrementCompressed : riscv_pkg::PcIncrement32bit));
      p_slot1_cond_clear : assert (!s1.is_cond_branch);
      if (!s1.sel_nop && !s1.fetch_fault) begin
        p_s1_expansion :
        assert (!raw_compressed ||
            ({assembled1, s1.rvc_extra_predecoded[22]} == {expanded1, illegal1}));
        p_s1_hot : assert (s1.source_hot_predecoded == {instr1[21], instr1[17:16]});
        p_s1_rs1 : assert (s1.rs1_rest_predecoded == {instr1[19:18], instr1[15]});
        p_s1_rs2 : assert (s1.bits24_20_predecoded == instr1[24:20]);
      end
      if (!s2.sel_nop && !s2.fetch_fault) begin
        p_s2_size : assert (s2.sel_compressed == (s2.raw_parcel[1:0] != 2'b11));
        p_s2_expansion :
        assert (!s2.sel_compressed || ({instr2, s2.decomp_illegal} == {expanded2, illegal2}));
        p_s2_branch :
        assert (s2.is_cond_branch ==
            ((instr2[6:0] == riscv_pkg::OPC_BRANCH) && (instr2[14:13] != 2'b01)));
        p_s2_hot : assert (s2.source_hot_predecoded == {instr2[21], instr2[17:16]});
        p_s2_rs1 : assert (rs1_bits(s2) == instr2[19:15]);
        p_s2_rs2 : assert (s2.bits24_20_predecoded == instr2[24:20]);
        p_s2_rs1_hot : assert (s2.source_hot_predecoded[1:0] == 2'(rs1_bits(s2) >> 1));
      end
      c_pair : cover (!s1.sel_nop && !s2.sel_nop);
      c_backing_hit : cover (i_backing_hit[1]);
      c_restore : cover (i_restore_arm[4]);
    end
  end
endmodule
