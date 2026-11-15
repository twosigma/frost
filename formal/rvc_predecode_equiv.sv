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

// The fill-time RV64C expansion (with Zcb and Zcmop) must equal the
// independent reference decoder for every 16-bit parcel, including reserved
// and native encodings.
module rvc_predecode_equiv;
  (* anyconst *) logic [15:0] parcel;
  logic [31:0] expanded;
  logic illegal;
  rvc_decompressor dut (
      .i_instr_compressed(parcel),
      .o_instr_expanded(expanded),
      .o_illegal(illegal)
  );
  // The stored source fields equal the expansion's: bits [24:20], rs1 and
  // rs2[1], for every compressed parcel including reserved ones.
  logic rd_is_x2;
  logic [5:0] source_fields;
  assign rd_is_x2 = parcel[11:7] == 5'd2;
  assign source_fields = riscv_pkg::imem_rvc_source_fields(parcel, rd_is_x2);
  logic [riscv_pkg::ImemSidebandWidth-1:0] paired_sideband;
  assign paired_sideband = riscv_pkg::imem_make_sideband({parcel, parcel});
  always_comb begin
    assert (riscv_pkg::imem_rvc_expand(parcel) == {illegal, expanded});
    if (parcel[1:0] != 2'b11) begin
      assert (riscv_pkg::imem_rvc_bits24_20(parcel, rd_is_x2) == expanded[24:20]);
      assert (source_fields == {expanded[21], expanded[19:15]});
    end
    if (parcel[6:0] == 7'h73) begin
      assert (paired_sideband[riscv_pkg::ImemSbNativeSerializeLo] == (parcel[14:12] != 3'b100));
      assert (paired_sideband[riscv_pkg::ImemSbNativeSerializeHi] == (parcel[14:12] != 3'b100));
      assert (paired_sideband[riscv_pkg::ImemSbAllowsSlot2AfterLo] == (parcel[14:12] == 3'b100));
      assert (paired_sideband[riscv_pkg::ImemSbSlot2StartValidHi] == (parcel[14:12] == 3'b100));
    end
  end
endmodule
