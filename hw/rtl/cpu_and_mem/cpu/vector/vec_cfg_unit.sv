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
  The vector-config unit: the combinational result of vsetvli, vsetivli and
  vsetvl for a vector length of VLEN bits and ELEN 64.

  The new vtype comes from vsetvli's 11-bit immediate, vsetivli's 10-bit
  immediate or vsetvl's rs2. It is illegal (vill) when vsew selects SEW above
  64, vlmul is the reserved 100, a fractional LMUL is smaller than SEW/ELEN,
  or any bit above bit 7 is set; an illegal vtype gives VLMAX 0 and vl 0.
  Otherwise VLMAX = VLEN / SEW * LMUL and
    rs1 = x0 (vsetvli, vsetvl):  vl = VLMAX (the rd != x0 form; with rd = x0
                                 the instruction keeps min(vl, VLMAX), which
                                 the CSR file applies at commit),
    otherwise:                   vl = min(AVL, VLMAX),
  where AVL is rs1's value, or vsetivli's 5-bit immediate. o_vl is also the
  value written to rd.
*/
module vec_cfg_unit #(
    parameter  int unsigned VLEN = 256,
    localparam int unsigned XLEN = riscv_pkg::XLEN
) (
    input  riscv_pkg::instr_op_e            i_op,
    input  logic                 [XLEN-1:0] i_avl,        // rs1 (vsetvli, vsetvl)
    input  logic                 [XLEN-1:0] i_vtype,      // rs2 (vsetvl)
    input  logic                 [    11:0] i_imm,        // instruction bits 31:20
    input  logic                 [     4:0] i_rs1_field,  // rs1 number, or vsetivli's AVL
    output logic                            o_vill,
    output logic                 [     7:0] o_vtype,      // vma, vta, vsew, vlmul; 0 when vill
    output logic                            o_rs1_x0,     // vsetvli/vsetvl with rs1 = x0
    output logic                 [    15:0] o_vlmax,
    output logic                 [    15:0] o_vl
);

  localparam int unsigned LogVlen = $clog2(VLEN);

  logic [XLEN-1:0] vtype_full;
  logic [2:0] vsew, vlmul;
  logic illegal;
  logic [15:0] vlmax;
  logic [XLEN-1:0] avl;
  always_comb begin
    unique case (i_op)
      riscv_pkg::VSETIVLI: vtype_full = XLEN'(i_imm[9:0]);
      riscv_pkg::VSETVL: vtype_full = i_vtype;
      default: vtype_full = XLEN'(i_imm[10:0]);
    endcase
    vsew  = vtype_full[5:3];
    vlmul = vtype_full[2:0];
    unique case (vlmul)
      3'b100:  illegal = 1'b1;
      3'b101:  illegal = vsew > 3'd0;  // LMUL 1/8: SEW 8 only
      3'b110:  illegal = vsew > 3'd1;  // LMUL 1/4
      3'b111:  illegal = vsew > 3'd2;  // LMUL 1/2
      default: illegal = vsew > 3'd3;  // LMUL 1 to 8: SEW up to 64
    endcase
    illegal = illegal || (vtype_full[XLEN-1:8] != '0);
    // VLMAX = 2^(log2 VLEN - (vsew + 3) + lmul_shift); legal settings keep
    // the exponent at least log2(VLEN) - 6.
    vlmax   = '0;
    if (!illegal) begin
      unique case (vlmul)
        3'b101:  vlmax = 16'(VLEN) >> (vsew + 3'd6);
        3'b110:  vlmax = 16'(VLEN) >> (vsew + 3'd5);
        3'b111:  vlmax = 16'(VLEN) >> (vsew + 3'd4);
        default: vlmax = (16'(VLEN) << vlmul) >> (vsew + 3'd3);
      endcase
    end
    avl = (i_op == riscv_pkg::VSETIVLI) ? XLEN'(i_rs1_field) : i_avl;
    o_rs1_x0 = (i_op != riscv_pkg::VSETIVLI) && (i_rs1_field == 5'd0);
    o_vill = illegal;
    o_vtype = illegal ? 8'd0 : vtype_full[7:0];
    o_vlmax = vlmax;
    if (o_rs1_x0) o_vl = vlmax;
    else if (avl > XLEN'(vlmax)) o_vl = vlmax;
    else o_vl = avl[15:0];
  end

  // LogVlen documents the supported range; the CSR file checks it.
  if (LogVlen < 7 || LogVlen > 9) begin : gen_vlen_check
    initial $fatal(1, "vec_cfg_unit: VLEN must be 128, 256 or 512");
  end

endmodule
