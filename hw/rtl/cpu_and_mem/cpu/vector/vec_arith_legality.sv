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
  table entry and a register-field test, and the result is their OR. The
  floating-point encodings (OPFVV, OPFVF) have their own rule set, built the
  same way from the same tables and register-field tests.
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

  // ---------------------------------------------------------------------------
  // Floating point (OPFVV, OPFVF): riscv_pkg::vector_fp_illegal
  // ---------------------------------------------------------------------------
  // The encodings the FP families define (riscv_pkg::vector_fp_ok)
  logic fvv, fvf, fp_ok;
  assign fvv = f3 == 3'b001;
  assign fvf = f3 == 3'b101;
  always_comb begin
    fp_ok = 1'b0;
    if (fvv || fvf) begin
      case (f6)
        6'h00, 6'h02, 6'h04, 6'h06, 6'h08, 6'h09, 6'h0a, 6'h18, 6'h19, 6'h1b, 6'h1c, 6'h20, 6'h24,
        6'h28, 6'h29, 6'h2a, 6'h2b, 6'h2c, 6'h2d, 6'h2e, 6'h2f, 6'h30, 6'h32, 6'h34, 6'h36,
        6'h38, 6'h3c, 6'h3d, 6'h3e, 6'h3f:
        fp_ok = 1'b1;
        6'h01, 6'h03, 6'h05, 6'h07, 6'h31, 6'h33: fp_ok = fvv;
        6'h0e, 6'h0f, 6'h1d, 6'h1f, 6'h21, 6'h27: fp_ok = fvf;
        6'h10: fp_ok = vm && (fvf ? (vs2 == 5'd0) : (vs1 == 5'd0));
        6'h17: fp_ok = fvf && (!vm || (vs2 == 5'd0));
        // Conversions: every subopcode below 24 except 4, 5 and 13
        6'h12: fp_ok = fvv && (vs1[4:3] != 2'b11) && (vs1[4:1] != 4'b0010) && (vs1 != 5'd13);
        6'h13: fp_ok = fvv && ((vs1 == 5'd0) || (vs1 == 5'd4) || (vs1 == 5'd5) || (vs1 == 5'd16));
        default: fp_ok = 1'b0;
      endcase
    end
  end

  // FP instruction classes: conversions (fcvt; fwcvt widening, fncvt
  // narrowing), the unary group (square root, estimates, classify),
  // reductions (fwred widening), widened destinations (fwiden: vd at twice
  // SEW and twice LMUL, except the widening reductions' single register),
  // vs2 at twice SEW (fawide), compares into masks, vfmv.s.f (fsmove),
  // vfmv.f.s (fsread), vfmv.v.f (fmvvf), vfslide1up and the widening fused
  // operations (fwfma). vs1 is a vector source only in the vector-vector
  // forms other than the unary groups and vfmv.f.s.
  logic fcvt, fwcvt, fncvt, funary, fred, fwred, fwiden, fawide, fcmp;
  logic fsmove, fsread, fmvvf, fslideup, fwfma, fuses_a, fuses_b;
  assign fcvt = f6 == 6'h12;
  assign fwcvt = fcvt && (vs1[4:3] == 2'b01);
  assign fncvt = fcvt && vs1[4];
  assign funary = f6 == 6'h13;
  assign fwred = fvv && ((f6 == 6'h31) || (f6 == 6'h33));
  assign fred = fwred || (fvv && (f6[5:3] == 3'b000) && f6[0]);
  assign fwiden = ((f6[5:4] == 2'b11) && !fwred) || fwcvt;
  assign fawide = fncvt || (f6 == 6'h34) || (f6 == 6'h36);
  assign fcmp = f6[5:3] == 3'b011;
  assign fsmove = fvf && (f6 == 6'h10);
  assign fsread = fvv && (f6 == 6'h10);
  assign fmvvf = (f6 == 6'h17) && vm;
  assign fslideup = f6 == 6'h0e;
  assign fwfma = f6[5:2] == 4'b1111;
  assign fuses_a = !fsmove && !fmvvf;
  assign fuses_b = fvv && !fcvt && !funary && !fsread;

  // FP elements are 16, 32 or 64 bits. A conversion whose vs1[2:1] is 1
  // reads an integer, and one whose vs1[2:1] is 1 or 2 writes FP; the wide
  // side of a widening or narrowing conversion is at least 16 bits.
  logic fint_src, ffp_dst, fwidth_bad;
  assign fint_src = vs1[2:1] == 2'b01;
  assign ffp_dst = (vs1[2:1] == 2'b01) || (vs1[2:1] == 2'b10);
  assign fwidth_bad = (sew == 2'd0) && (!fcvt || (!fint_src && !fncvt) || (ffp_dst && !fwcvt));

  // A 16-bit FP operand outside the two Zvfhmin conversions, vfwcvt.f.f.v
  // (vs1 = 12) and vfncvt.f.f.w (vs1 = 20): legal with Zvfh
  logic ffp16;
  assign ffp16 = fcvt ? (((!fint_src && (fncvt ? (sew == 2'd0) : (sew == 2'd1))) ||
                          (ffp_dst && (fwcvt ? (sew == 2'd0) : (sew == 2'd1)))) &&
                         (vs1 != 5'd12) && (vs1 != 5'd20)) : (sew == 2'd1);

  // EEW above 64 or EMUL above 8 for a widened operand
  logic frange_bad;
  assign frange_bad = (fwiden && (lmul == 3'b011)) || ((fwiden || fwred) && (sew == 2'd3)) ||
      (fawide && ((lmul == 3'b011) || (sew == 2'd3)));

  // Masks, reductions and the scalar moves use one register for vd;
  // reduction seeds one register for vs1; vfmv.f.s element 0 of vs2
  logic fd_sew, fa_sew, falign_bad;
  assign fd_sew = !fcmp && !fred && !fsmove && !fsread && !fwiden;
  assign fa_sew = !fsread && !fawide;
  assign falign_bad = (fwiden && misaligned(
      vd[2:0], p1
  )) || (fd_sew && misaligned(
      vd[2:0], p0
  )) || (fuses_a && ((fawide && misaligned(
      vs2[2:0], p1
  )) || (fa_sew && misaligned(
      vs2[2:0], p0
  )))) || (fuses_b && !fred && misaligned(
      vs1[2:0], p0
  ));

  // A masked instruction may not write v0 unless the result is a mask or a
  // reduction, and v0 as the EEW-1 mask may not also be read as data
  logic fv0_bad;
  assign fv0_bad = !vm && (((vd == 5'd0) && !fcmp && !fred) || (fuses_a && (vs2 == 5'd0)) ||
                           (fuses_b && (vs1 == 5'd0)));

  // Sources read at different EEWs may not overlap: a widening reduction's
  // seed and vs2, and a wide vs2 beside an SEW vs1. A widening fused
  // operation also reads its wide destination, so no narrow source may
  // overlap it.
  logic fsrc_bad, fwfma_bad;
  assign fsrc_bad  = fuses_a && fuses_b && ((fwred && eq_ab[p0]) || (fawide && eq_ab[p1]));
  assign fwfma_bad = fwfma && (eq_da[p1] || (fuses_b && eq_db[p1]));

  // Destination overlaps: a mask result or a narrowed destination must be
  // its source's lowest register; a source narrower than a widened
  // destination must be its upper part and not fractional; vfslide1up's
  // destination may not overlap vs2 at all
  logic flow_bad, fhigh_bad;
  assign flow_bad = (fcmp && eq_da[p0] && !eq_da[0]) ||
      (fcmp && fuses_b && eq_db[p0] && !eq_db[0]) || (fncvt && eq_da[p1] && !eq_da[0]);
  assign fhigh_bad = (fwiden && !fawide && eq_da[p1] && (lmul[2] || !vs2_low[p0])) ||
      (fwiden && fuses_b && eq_db[p1] && (lmul[2] || !vs1_low[p0]));

  logic fp_bad;
  assign fp_bad = vtype_bad || fwidth_bad || (!riscv_pkg::VectorZvfh && ffp16) || frange_bad ||
      falign_bad || fv0_bad || fsrc_bad || fwfma_bad || flow_bad || fhigh_bad ||
      (fslideup && eq_da[p0]);

  assign o_illegal = fp_ok ? fp_bad : whole ? whole_bad : arith_bad;

  // The opcode is OP-V by construction; vma and vta never affect legality
  logic unused;
  assign unused = &{1'b0, i_vtype[7:6], i_insn[6:0]};

endmodule
