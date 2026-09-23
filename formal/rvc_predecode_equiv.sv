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

// The fill-time RV64C expansion must equal the independent runtime decoder
// for every 16-bit parcel, including reserved and native encodings.
module rvc_predecode_equiv;
  (* anyconst *) logic [15:0] parcel;
  logic [31:0] expanded;
  logic illegal;
  rvc_decompressor dut (
      .i_instr_compressed(parcel),
      .i_rd_is_x2(parcel[11:7] == 5'd2),
      .o_instr_expanded(expanded),
      .o_illegal(illegal)
  );
  always_comb begin
    assert (riscv_pkg::imem_rvc_expand(parcel) == {illegal, expanded});
  end
endmodule
