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
  Register-number checks of vector arithmetic for each LMUL class:
  o_illegal[k] covers alignment of groups of 2^k registers (k = 0 for LMUL 1
  and the fractional LMULs), mask-destination overlap, a masked write of v0
  and v0 read both as the mask and as data. It depends on the instruction
  bits only, so cpu_ooo forms it from each copy of ID's output that enters
  the decoded queue and carries it in the queue's shadow beside slot 1.
  Dispatch uses it only in builds without the vector unit (VECTOR = 0, where
  ID already rejects every OP-V instruction):
    illegal = vill || o_illegal[vlmul[2] ? 0 : vlmul[1:0]]
  With the unit, vec_dispatch_legality supplies the full arithmetic legality
  instead, and these bits have no load.
*/
module vec_lmul_legality (
    input  logic [31:0] i_insn,
    output logic [ 3:0] o_illegal
);

  logic [2:0] funct3;
  logic [5:0] funct6;
  logic [4:0] vd, vs1, vs2;
  logic mask_dest, uses_vs1, masked;
  assign funct3 = i_insn[14:12];
  assign funct6 = i_insn[31:26];
  assign vd = i_insn[11:7];
  assign vs1 = i_insn[19:15];
  assign vs2 = i_insn[24:20];
  assign masked = !i_insn[25];
  assign mask_dest = (funct3 != 3'b010) && (funct6[5:3] == 3'b011);
  assign uses_vs1 = (funct3 == 3'b000);

  for (genvar k = 0; k < 4; k++) begin : gen_class
    // Register groups of 2^k registers align to 2^k.
    localparam logic [4:0] Align = 5'((1 << k) - 1);
    assign o_illegal[k] = ((vs2 & Align) != 5'd0) ||
        (uses_vs1 && ((vs1 & Align) != 5'd0)) ||
        (!mask_dest && ((vd & Align) != 5'd0)) ||
        (mask_dest && (vd > vs2) && (vd <= (vs2 | Align))) ||
        (mask_dest && uses_vs1 && (vd > vs1) && (vd <= (vs1 | Align))) ||
        (masked && !mask_dest && (vd == 5'd0)) ||
        // The implicit mask uses EEW=1; a vector data source uses SEW.
        (masked && ((vs2 == 5'd0) || (uses_vs1 && vs1 == 5'd0)));
  end

endmodule
