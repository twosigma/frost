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
  Legality of a vector arithmetic instruction under one vtype. o_illegal
  equals riscv_pkg::vector_arith_illegal(i_vtype, i_insn) for every input
  (formal/vec_lmul_legality_equiv.sby). vec_dispatch_legality evaluates it
  for the instruction at the decoded queue's head and registers the result.

  The form has no adder and no magnitude compare, so its depth is fixed. The
  vtype enters through small tables of the 3-bit LMUL code, the 2-bit SEW
  code and the 2-bit extension factor: the size of a register group as a
  2-bit log2 code (a fractional group is one register; a group larger than
  eight registers is rejected by the range rule, so the code saturates at 3),
  whether a source group is fractional, and the range rules. The instruction
  enters through decodes of funct6, funct3, vm and the vs1 subopcode, and
  through equalities between its register fields. Two aligned groups of 2^p
  and 2^q registers overlap exactly when their register numbers agree above
  bit max(p, q) - 1, which is eq_*[p] || eq_*[q]. A misaligned operand makes
  the instruction illegal by the alignment rule, so the overlap rules may
  assume aligned groups. Each rule is a product of an instruction class, a
  table entry and a register-field test, and the result is their OR.
*/
module vec_arith_legality (
    input  logic [ 8:0] i_vtype,   // {vill, vma, vta, vsew[2:0], vlmul[2:0]}
    input  logic [31:0] i_insn,
    output logic        o_illegal
);

  logic [5:0] f6;
  logic [2:0] f3;
  logic [4:0] vd, vs2, vs1;
  logic vm;
  assign f6  = i_insn[31:26];
  assign vm  = i_insn[25];
  assign vs2 = i_insn[24:20];
  assign vs1 = i_insn[19:15];
  assign f3  = i_insn[14:12];
  assign vd  = i_insn[11:7];

  logic vill;
  logic [1:0] sew;
  logic [2:0] lmul;
  assign vill = i_vtype[8];
  assign sew  = i_vtype[4:3];
  assign lmul = i_vtype[2:0];

  // ---------------------------------------------------------------------------
  // Instruction classes (instruction bits only)
  // ---------------------------------------------------------------------------
  logic ivv, mvv, ivi, mvx, vv, mv;
  assign ivv = f3 == 3'b000;
  assign mvv = f3 == 3'b010;
  assign ivi = f3 == 3'b011;
  assign mvx = f3 == 3'b110;
  assign vv  = ivv || mvv;
  assign mv  = mvv || mvx;

  logic whole, wred, red, masks, scan, iota, id_op, ext, smove, widen, narrow;
  logic gather, ei16, slideup, compress, cmp, mask_dest, uses_a, uses_b, wmacc, awide;
  assign whole = ivi && (f6 == 6'h27);  // vmv<nr>r.v
  assign wred = ivv && (f6[5:1] == 5'b11000);  // vwredsum[u].vs
  assign red = wred || (mvv && (f6[5:3] == 3'b000));
  assign masks = mvv && (f6[5:3] == 3'b011);  // mask-register logical
  assign scan = mvv && (f6 == 6'h14) && !vs1[4];  // vmsbf, vmsof, vmsif
  assign iota = mvv && (f6 == 6'h14) && (vs1 == 5'd16);
  assign id_op = mvv && (f6 == 6'h14) && (vs1 == 5'd17);
  assign ext = mvv && (f6 == 6'h12) && (vs1[4:3] == 2'b00);  // vzext, vsext
  assign smove = mvx && (f6 == 6'h10);  // vmv.s.x
  assign widen = (mv && (f6[5:4] == 2'b11)) || (!mv && (f6 == 6'h35));
  assign narrow = !mv && (f6[5:2] == 4'b1011);
  assign gather = !mv && ((f6 == 6'h0c) || (ivv && (f6 == 6'h0e)));
  assign ei16 = ivv && (f6 == 6'h0e);  // vrgatherei16.vv
  assign slideup = (f6 == 6'h0e) && !gather;
  assign compress = mvv && (f6 == 6'h17);
  // Compares and carry/borrow outputs: mask results from SEW data
  assign cmp = !mv && ((f6[5:3] == 3'b011) || (f6 == 6'h11) || (f6 == 6'h13));
  assign mask_dest = masks || scan || cmp;
  // vs2 is not read by vid, vmv.s.x and vmv.v.*; vs1 is a subopcode in the
  // two unary groups and a scalar in the .vx/.vi forms
  assign uses_a = !id_op && !smove && !((f6 == 6'h17) && !mv && vm);
  assign uses_b = vv && !(mvv && ((f6 == 6'h12) || (f6 == 6'h14)));
  assign wmacc = mv && (f6[5:2] == 4'b1111);  // widening multiply-accumulate
  // vs2 at twice SEW: narrowing sources and the .wv/.wx widening forms
  assign awide = narrow || (mv && (f6[5:2] == 4'b1101));

  // Register-group width classes. vd is one register (a mask, reduction or
  // scalar result), twice LMUL (widen) or LMUL (d_sew). vs2 is one register
  // (a mask), twice LMUL (awide), a fraction of LMUL (ext) or LMUL (a_sew).
  // vs1 is one register (a mask or a reduction seed), EMUL 16/SEW*LMUL
  // (ei16) or LMUL (b_sew).
  logic d_one, d_sew, a_one, a_sew, b_one, b_sew;
  assign d_one = mask_dest || red || smove;
  assign d_sew = !d_one && !widen;
  assign a_one = masks || scan || iota;
  assign a_sew = !a_one && !awide && !ext;
  assign b_one = masks || compress || red;
  assign b_sew = !b_one && !ei16;

  // ---------------------------------------------------------------------------
  // vtype tables
  // ---------------------------------------------------------------------------
  // Unsupported vtype: vill, SEW above 64, the reserved LMUL, or a fractional
  // LMUL below SEW/64
  logic vtype_bad, lmul_bad;
  always_comb begin
    unique case (lmul)
      3'b100:  lmul_bad = 1'b1;
      3'b101:  lmul_bad = sew != 2'd0;
      3'b110:  lmul_bad = sew[1];
      3'b111:  lmul_bad = sew == 2'd3;
      default: lmul_bad = 1'b0;
    endcase
  end
  assign vtype_bad = vill || i_vtype[5] || lmul_bad;

  // Group-size codes: p0 for EMUL = LMUL, p1 for twice LMUL, p16 for the
  // vrgatherei16 index group, pext for an extension source of LMUL/k
  logic [1:0] p0, p1, p16, pext;
  always_comb begin
    unique case (lmul)
      3'b000:  {p0, p1} = {2'd0, 2'd1};
      3'b001:  {p0, p1} = {2'd1, 2'd2};
      3'b010:  {p0, p1} = {2'd2, 2'd3};
      3'b011:  {p0, p1} = {2'd3, 2'd3};
      default: {p0, p1} = {2'd0, 2'd0};
    endcase
  end
  always_comb begin
    unique case (sew)
      2'd0:    p16 = p1;
      2'd1:    p16 = p0;
      2'd2:    p16 = (lmul == 3'b010) ? 2'd1 : (lmul == 3'b011) ? 2'd2 : 2'd0;
      default: p16 = (lmul == 3'b011) ? 2'd1 : 2'd0;
    endcase
  end

  // Extensions: vs1[2:1] = 1, 2, 3 select vf8, vf4, vf2 (k = 8, 4, 2); 0 is
  // the reserved k = 16. ext_bad: a source below EEW 8 or EMUL 1/8.
  // ext_frac: the source group is fractional. ext_top: a source group that
  // overlaps the destination is its upper part.
  logic ext_bad, ext_frac, ext_top;
  always_comb begin
    unique case (vs1[2:1])
      2'd0: begin
        ext_bad  = 1'b1;
        ext_frac = 1'b1;
      end
      2'd1: begin
        ext_bad  = lmul[2] || (sew != 2'd3);
        ext_frac = lmul != 3'b011;
      end
      2'd2: begin
        ext_bad  = (lmul[2] && (lmul[1:0] != 2'b11)) || !sew[1];
        ext_frac = !((lmul == 3'b010) || (lmul == 3'b011));
      end
      default: begin
        ext_bad  = (lmul[2] && !lmul[1]) || (sew == 2'd0);
        ext_frac = lmul[2] || (lmul == 3'b000);
      end
    endcase
  end
  always_comb begin
    unique case ({
      vs1[2:1], lmul
    })
      {2'd2, 3'b011} : pext = 2'd1;
      {2'd3, 3'b010} : pext = 2'd1;
      {2'd3, 3'b011} : pext = 2'd2;
      default: pext = 2'd0;
    endcase
  end
  always_comb begin
    unique case ({
      vs1[2:1], lmul
    })
      {2'd3, 3'b001} : ext_top = vs2[0];
      {2'd3, 3'b010} : ext_top = vs2[1];
      {2'd2, 3'b010} : ext_top = &vs2[1:0];
      {2'd3, 3'b011} : ext_top = vs2[2];
      {2'd2, 3'b011} : ext_top = &vs2[2:1];
      {2'd1, 3'b011} : ext_top = &vs2[2:0];
      default: ext_top = 1'b1;  // fractional: ext_frac decides
    endcase
  end

  // ---------------------------------------------------------------------------
  // Register-field tests
  // ---------------------------------------------------------------------------
  // eq_*[k]: the two register numbers agree in bits 4:k (k = 0: equal)
  logic [3:0] eq_da, eq_db, eq_ab;
  for (genvar k = 0; k < 4; k++) begin : gen_eq
    assign eq_da[k] = vd[4:k] == vs2[4:k];
    assign eq_db[k] = vd[4:k] == vs1[4:k];
    assign eq_ab[k] = vs2[4:k] == vs1[4:k];
  end

  // A register number is aligned to a group of 2^p registers when its low p
  // bits are zero
  function automatic logic misaligned(input logic [2:0] r, input logic [1:0] p);
    misaligned = ((p != 2'd0) && r[0]) || (p[1] && r[1]) || ((p == 2'd3) && r[2]);
  endfunction

  // ---------------------------------------------------------------------------
  // Rules
  // ---------------------------------------------------------------------------
  // EEW above 64 or EMUL above 8 for a widened operand, or an extension
  // source below its limits, or EMUL 16 for the vrgatherei16 indices
  logic range_bad;
  assign range_bad = (widen && (lmul == 3'b011)) || ((widen || wred) && (sew == 2'd3)) ||
      (awide && ((lmul == 3'b011) || (sew == 2'd3))) || (ext && ext_bad) ||
      (ei16 && (lmul == 3'b011) && (sew == 2'd0));

  logic align_bad;
  assign align_bad = (widen && misaligned(
      vd[2:0], p1
  )) || (d_sew && misaligned(
      vd[2:0], p0
  )) || (uses_a && ((awide && misaligned(
      vs2[2:0], p1
  )) || (ext && misaligned(
      vs2[2:0], pext
  )) || (a_sew && misaligned(
      vs2[2:0], p0
  )))) || (uses_b && ((ei16 && misaligned(
      vs1[2:0], p16
  )) || (b_sew && misaligned(
      vs1[2:0], p0
  ))));

  // A masked instruction may not write v0 unless the result is a mask or a
  // reduction, and v0 as the EEW-1 mask may not also be read as data; masked
  // vmsbf, vmsof and vmsif may not write v0 at all
  logic v0_bad;
  assign v0_bad = !vm && (((vd == 5'd0) && !mask_dest && !red) ||
                          (uses_a && (vs2 == 5'd0) && !a_one) ||
                          (uses_b && (vs1 == 5'd0) && !(masks || compress)) ||
                          (scan && (vd == 5'd0)));

  // Two sources read at different EEWs may not overlap: vcompress's mask,
  // a widened reduction seed, vrgatherei16 indices other than at SEW 16, and
  // a wide vs2 beside an SEW vs1
  logic src_bad;
  assign src_bad = uses_a && uses_b &&
      (((compress || wred) && eq_ab[p0]) ||
       (ei16 && (sew != 2'd1) && (eq_ab[p0] || eq_ab[p16])) || (awide && eq_ab[p1]));

  // A narrow source of a widening multiply-accumulate may not overlap the
  // accumulator it is added to
  logic wmacc_bad;
  assign wmacc_bad = wmacc && (eq_da[p1] || (uses_b && eq_db[p1]));

  // A destination narrower than a source it overlaps must be that source's
  // lowest register: mask results from SEW data, and narrowing
  logic low_bad;
  assign low_bad = (cmp && eq_da[p0] && !eq_da[0]) || (narrow && eq_da[p1] && !eq_da[0]) ||
      (cmp && uses_b && eq_db[p0] && !eq_db[0]);

  // A source narrower than the destination it overlaps must not be
  // fractional and must be the destination's upper part: widening and the
  // integer extensions
  logic high_bad;
  logic [3:0] vs2_low, vs1_low;
  assign vs2_low = vs2[3:0];
  assign vs1_low = vs1[3:0];
  assign high_bad = (widen && !awide && eq_da[p1] && (lmul[2] || !vs2_low[p0])) ||
      (ext && eq_da[p0] && (ext_frac || !ext_top)) ||
      (widen && uses_b && eq_db[p1] && (lmul[2] || !vs1_low[p0]));

  // Gathers, slide-ups, vcompress, viota and the set-before/including/only
  // masks may not overlap a source at all
  logic ban_bad;
  assign ban_bad = ((gather || slideup || compress || iota) && eq_da[p0]) || (scan && eq_da[0]) ||
      (((gather && ivv) || compress) && eq_db[p0]) || (ei16 && eq_db[p16]);

  logic arith_bad, whole_bad;
  assign arith_bad = vtype_bad || range_bad || align_bad || v0_bad || src_bad || wmacc_bad ||
      low_bad || high_bad || ban_bad;
  // Whole-register moves: nr = vs1 + 1 in 1, 2, 4, 8, both groups aligned to
  // nr, with a supported vtype
  assign whole_bad = vtype_bad ||
      !((vs1 == 5'd0) || (vs1 == 5'd1) || (vs1 == 5'd3) || (vs1 == 5'd7)) ||
      ((vd[2:0] & vs1[2:0]) != 3'd0) || ((vs2[2:0] & vs1[2:0]) != 3'd0);
  assign o_illegal = whole ? whole_bad : arith_bad;

  // The opcode is OP-V by construction; vma and vta never affect legality
  logic unused;
  assign unused = &{1'b0, i_vtype[7:6], i_insn[6:0]};

endmodule
