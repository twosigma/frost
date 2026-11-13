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
  One 64-bit integer lane of the vector unit: element-wise integer, logical,
  shift, Zvbb and compare operations at SEW 8, 16, 32 or 64. Operand a is the
  vs2 element group, b the vs1 element group or the replicated scalar, and
  i_mask holds the v0 bit of each element (element k of the lane at bit k)
  for merges. Results come out a fixed three cycles after the input is
  taken, whatever the operation and operand values (an input register and
  two computing stages), so every operation has data-independent latency.
  Compares put one bit per element in o_mask (bit k for element k) and zero
  o_result; other operations zero o_mask.

  The adder works on 72 bits: each byte is followed by a separator bit. Inside
  an element the separator propagates the carry (a-side 1, b-side 0); at an
  element boundary both sides equal the carry-in, so the separator stops the
  carry, injects the next element's carry-in, and its sum bit is the carry out
  of the element below it. Subtraction adds the inverted operand with a
  carry-in of 1, so that bit is 1 exactly when a >= b, unsigned.
*/
module vec_int_lane
  import vec_pkg::*;
(
    input  logic           i_clk,
    input  logic           i_rst,
    input  logic           i_valid,
    input  int_op_e        i_op,
    input  sew_e           i_sew,
    input  logic    [63:0] i_a,
    input  logic    [63:0] i_b,
    input  logic    [ 7:0] i_mask,
    output logic           o_valid,
    output logic    [63:0] o_result,
    output logic    [ 7:0] o_mask
);

  // --------------------------------------------------------------------------
  // Stage 0: input registers
  // --------------------------------------------------------------------------
  logic s0_valid;
  int_op_e s0_op;
  sew_e s0_sew;
  logic [63:0] s0_a, s0_b;
  logic [7:0] s0_mask;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op <= i_op;
    s0_sew <= i_sew;
    s0_a <= i_a;
    s0_b <= i_b;
    s0_mask <= i_mask;
  end

  // Byte i starts an element.
  function automatic logic [7:0] element_starts(input sew_e sew);
    unique case (sew)
      SEW8: element_starts = 8'b1111_1111;
      SEW16: element_starts = 8'b0101_0101;
      SEW32: element_starts = 8'b0001_0001;
      default: element_starts = 8'b0000_0001;
    endcase
  endfunction

  // Byte i is the top byte of an element.
  function automatic logic [7:0] element_tops(input sew_e sew);
    unique case (sew)
      SEW8: element_tops = 8'b1111_1111;
      SEW16: element_tops = 8'b1010_1010;
      SEW32: element_tops = 8'b1000_1000;
      default: element_tops = 8'b1000_0000;
    endcase
  endfunction

  // --------------------------------------------------------------------------
  // Stage 1: adder, byte compares, logic, shifts, per-byte counts
  // --------------------------------------------------------------------------
  logic [7:0] starts, tops;
  assign starts = element_starts(s0_sew);
  assign tops   = element_tops(s0_sew);

  logic op_add, op_rsub;
  assign op_add  = (s0_op == VI_ADD);
  assign op_rsub = (s0_op == VI_RSUB);

  // Every non-add arithmetic use (sub, rsub, min/max, compares) subtracts.
  logic [63:0] add_x, add_y;
  logic cin;
  assign add_x = op_rsub ? s0_b : s0_a;
  assign add_y = op_add ? s0_b : (op_rsub ? ~s0_a : ~s0_b);
  assign cin   = !op_add;

  logic [71:0] ext_x, ext_y, ext_sum;
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      ext_x[9*i+:8] = add_x[8*i+:8];
      ext_y[9*i+:8] = add_y[8*i+:8];
      // The separator above byte i: a boundary when byte i is an element top.
      ext_x[9*i+8]  = tops[i] ? cin : 1'b1;
      ext_y[9*i+8]  = tops[i] ? cin : 1'b0;
    end
  end
  assign ext_sum = ext_x + ext_y + 72'(cin);

  logic [63:0] sum;
  logic [ 7:0] carry_out;  // valid at element tops: a >= b unsigned (subtract)
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      sum[8*i+:8]  = ext_sum[9*i+:8];
      carry_out[i] = ext_sum[9*i+8];
    end
  end

  logic [7:0] byte_eq;
  always_comb for (int i = 0; i < 8; i++) byte_eq[i] = (s0_a[8*i+:8] == s0_b[8*i+:8]);

  // Shifts and rotates for each element width; stage 2 picks one.
  logic [63:0] shl[4], shr[4], sra_r[4], rol_r[4], ror_r[4];
  always_comb begin
    for (int e = 0; e < 8; e++) begin
      shl[0][8*e+:8]   = s0_a[8*e+:8] << s0_b[8*e+:3];
      shr[0][8*e+:8]   = s0_a[8*e+:8] >> s0_b[8*e+:3];
      sra_r[0][8*e+:8] = $signed(s0_a[8*e+:8]) >>> s0_b[8*e+:3];
      rol_r[0][8*e+:8] = 8'({s0_a[8*e+:8], s0_a[8*e+:8]} << s0_b[8*e+:3] >> 8);
      ror_r[0][8*e+:8] = 8'({s0_a[8*e+:8], s0_a[8*e+:8]} >> s0_b[8*e+:3]);
    end
    for (int e = 0; e < 4; e++) begin
      shl[1][16*e+:16]   = s0_a[16*e+:16] << s0_b[16*e+:4];
      shr[1][16*e+:16]   = s0_a[16*e+:16] >> s0_b[16*e+:4];
      sra_r[1][16*e+:16] = $signed(s0_a[16*e+:16]) >>> s0_b[16*e+:4];
      rol_r[1][16*e+:16] = 16'({s0_a[16*e+:16], s0_a[16*e+:16]} << s0_b[16*e+:4] >> 16);
      ror_r[1][16*e+:16] = 16'({s0_a[16*e+:16], s0_a[16*e+:16]} >> s0_b[16*e+:4]);
    end
    for (int e = 0; e < 2; e++) begin
      shl[2][32*e+:32]   = s0_a[32*e+:32] << s0_b[32*e+:5];
      shr[2][32*e+:32]   = s0_a[32*e+:32] >> s0_b[32*e+:5];
      sra_r[2][32*e+:32] = $signed(s0_a[32*e+:32]) >>> s0_b[32*e+:5];
      rol_r[2][32*e+:32] = 32'({s0_a[32*e+:32], s0_a[32*e+:32]} << s0_b[32*e+:5] >> 32);
      ror_r[2][32*e+:32] = 32'({s0_a[32*e+:32], s0_a[32*e+:32]} >> s0_b[32*e+:5]);
    end
    shl[3]   = s0_a << s0_b[5:0];
    shr[3]   = s0_a >> s0_b[5:0];
    sra_r[3] = $signed(s0_a) >>> s0_b[5:0];
    rol_r[3] = 64'({s0_a, s0_a} << s0_b[5:0] >> 64);
    ror_r[3] = 64'({s0_a, s0_a} >> s0_b[5:0]);
  end

  // Leading zeros, trailing zeros and population counts of every byte,
  // halfword and word; stage 2 combines the two words for SEW 64.
  logic [3:0] lz8[8], tz8[8], pop8[8];
  logic [4:0] lz16[4], tz16[4], pop16[4];
  logic [5:0] lz32[2], tz32[2], pop32[2];
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      lz8[i] = 4'd8;
      tz8[i] = 4'd8;
      for (int j = 0; j < 8; j++) if (s0_a[8*i+j]) lz8[i] = 4'(7 - j);
      for (int j = 7; j >= 0; j--) if (s0_a[8*i+j]) tz8[i] = 4'(j);
      pop8[i] = 4'($countones(s0_a[8*i+:8]));
    end
    for (int i = 0; i < 4; i++) begin
      lz16[i] = 5'd16;
      tz16[i] = 5'd16;
      for (int j = 0; j < 16; j++) if (s0_a[16*i+j]) lz16[i] = 5'(15 - j);
      for (int j = 15; j >= 0; j--) if (s0_a[16*i+j]) tz16[i] = 5'(j);
      pop16[i] = 5'($countones(s0_a[16*i+:16]));
    end
    for (int i = 0; i < 2; i++) begin
      lz32[i] = 6'd32;
      tz32[i] = 6'd32;
      for (int j = 0; j < 32; j++) if (s0_a[32*i+j]) lz32[i] = 6'(31 - j);
      for (int j = 31; j >= 0; j--) if (s0_a[32*i+j]) tz32[i] = 6'(j);
      pop32[i] = 6'($countones(s0_a[32*i+:32]));
    end
  end

  logic s1_valid;
  int_op_e s1_op;
  sew_e s1_sew;
  logic [63:0] s1_a, s1_b, s1_sum, s1_shift;
  logic [7:0] s1_mask, s1_carry, s1_byte_eq;
  logic [3:0] s1_lz8[8], s1_tz8[8], s1_pop8[8];
  logic [4:0] s1_lz16[4], s1_tz16[4], s1_pop16[4];
  logic [5:0] s1_lz32[2], s1_tz32[2], s1_pop32[2];
  logic [63:0] shift_sel;
  always_comb begin
    unique case (s0_op)
      VI_SLL:  shift_sel = shl[s0_sew];
      VI_SRL:  shift_sel = shr[s0_sew];
      VI_SRA:  shift_sel = sra_r[s0_sew];
      VI_ROL:  shift_sel = rol_r[s0_sew];
      default: shift_sel = ror_r[s0_sew];
    endcase
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_op <= s0_op;
    s1_sew <= s0_sew;
    s1_a <= s0_a;
    s1_b <= s0_b;
    s1_mask <= s0_mask;
    s1_sum <= sum;
    s1_carry <= carry_out;
    s1_byte_eq <= byte_eq;
    s1_shift <= shift_sel;
    s1_lz8 <= lz8;
    s1_tz8 <= tz8;
    s1_pop8 <= pop8;
    s1_lz16 <= lz16;
    s1_tz16 <= tz16;
    s1_pop16 <= pop16;
    s1_lz32 <= lz32;
    s1_tz32 <= tz32;
    s1_pop32 <= pop32;
  end

  // --------------------------------------------------------------------------
  // Stage 2: per-element flags, counts, reversals and the result select
  // --------------------------------------------------------------------------
  // Per-element flags, kept at the element's lowest byte index for the
  // replication below: eq, a < b unsigned, a < b signed.
  logic [7:0] el_eq, el_ltu, el_lt;
  logic [7:0] tops2;
  assign tops2 = element_tops(s1_sew);
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      logic a_neg, b_neg;
      el_eq[i]  = 1'b0;
      el_ltu[i] = 1'b0;
      el_lt[i]  = 1'b0;
      a_neg     = s1_a[8*i+7];
      b_neg     = s1_b[8*i+7];
      if (tops2[i]) begin
        el_ltu[i] = !s1_carry[i];
        el_lt[i]  = (a_neg && !b_neg) || ((a_neg == b_neg) && !s1_carry[i]);
      end
    end
    unique case (s1_sew)
      SEW8: el_eq = s1_byte_eq;
      SEW16: for (int k = 0; k < 4; k++) el_eq[2*k+1] = &s1_byte_eq[2*k+:2];
      SEW32: for (int k = 0; k < 2; k++) el_eq[4*k+3] = &s1_byte_eq[4*k+:4];
      default: el_eq[7] = &s1_byte_eq;
    endcase
  end

  // Replicate each element's flag (held at its top byte) to all its bytes.
  function automatic logic [7:0] spread(input logic [7:0] at_top, input sew_e sew);
    unique case (sew)
      SEW8: spread = at_top;
      SEW16: for (int k = 0; k < 4; k++) spread[2*k+:2] = {2{at_top[2*k+1]}};
      SEW32: for (int k = 0; k < 2; k++) spread[4*k+:4] = {4{at_top[4*k+3]}};
      default: spread = {8{at_top[7]}};
    endcase
  endfunction

  // Pack each element's flag (held at its top byte) into bit k for element k.
  function automatic logic [7:0] pack(input logic [7:0] at_top, input sew_e sew);
    pack = '0;
    unique case (sew)
      SEW8: pack = at_top;
      SEW16: for (int k = 0; k < 4; k++) pack[k] = at_top[2*k+1];
      SEW32: for (int k = 0; k < 2; k++) pack[k] = at_top[4*k+3];
      default: pack[0] = at_top[7];
    endcase
  endfunction

  // The merge mask of each byte (element k's bit spread over its bytes).
  logic [7:0] merge_bytes;
  always_comb begin
    unique case (s1_sew)
      SEW8: merge_bytes = s1_mask;
      SEW16: for (int k = 0; k < 4; k++) merge_bytes[2*k+:2] = {2{s1_mask[k]}};
      SEW32: for (int k = 0; k < 2; k++) merge_bytes[4*k+:4] = {4{s1_mask[k]}};
      default: merge_bytes = {8{s1_mask[0]}};
    endcase
  end

  // Element counts from the per-byte counts.
  logic [63:0] count_clz, count_ctz, count_pop;
  always_comb begin
    count_clz = '0;
    count_ctz = '0;
    count_pop = '0;
    unique case (s1_sew)
      SEW8:
      for (int k = 0; k < 8; k++) begin
        count_clz[8*k+:8] = 8'(s1_lz8[k]);
        count_ctz[8*k+:8] = 8'(s1_tz8[k]);
        count_pop[8*k+:8] = 8'(s1_pop8[k]);
      end
      SEW16:
      for (int k = 0; k < 4; k++) begin
        count_clz[16*k+:16] = 16'(s1_lz16[k]);
        count_ctz[16*k+:16] = 16'(s1_tz16[k]);
        count_pop[16*k+:16] = 16'(s1_pop16[k]);
      end
      SEW32:
      for (int k = 0; k < 2; k++) begin
        count_clz[32*k+:32] = 32'(s1_lz32[k]);
        count_ctz[32*k+:32] = 32'(s1_tz32[k]);
        count_pop[32*k+:32] = 32'(s1_pop32[k]);
      end
      default: begin
        logic [6:0] lz, tz, pc;
        lz = (s1_lz32[1] == 6'd32) ? 7'(7'd32 + 7'(s1_lz32[0])) : 7'(s1_lz32[1]);
        tz = (s1_tz32[0] == 6'd32) ? 7'(7'd32 + 7'(s1_tz32[1])) : 7'(s1_tz32[0]);
        pc = 7'(7'(s1_pop32[0]) + 7'(s1_pop32[1]));
        count_clz = 64'(lz);
        count_ctz = 64'(tz);
        count_pop = 64'(pc);
      end
    endcase
  end

  // Bit and byte reversals within each element.
  logic [63:0] brev8_v, rev8_v, brev_v;
  always_comb begin
    for (int i = 0; i < 8; i++) for (int j = 0; j < 8; j++) brev8_v[8*i+j] = s1_a[8*i+7-j];
    unique case (s1_sew)
      SEW8: rev8_v = s1_a;
      SEW16: for (int k = 0; k < 4; k++) rev8_v[16*k+:16] = {s1_a[16*k+:8], s1_a[16*k+8+:8]};
      SEW32:
      for (int k = 0; k < 2; k++)
      for (int j = 0; j < 4; j++) rev8_v[32*k+8*j+:8] = s1_a[32*k+8*(3-j)+:8];
      default: for (int j = 0; j < 8; j++) rev8_v[8*j+:8] = s1_a[8*(7-j)+:8];
    endcase
    // A bit reverse is the byte reverse of the per-byte bit reverse.
    unique case (s1_sew)
      SEW8: brev_v = brev8_v;
      SEW16: for (int k = 0; k < 4; k++) brev_v[16*k+:16] = {brev8_v[16*k+:8], brev8_v[16*k+8+:8]};
      SEW32:
      for (int k = 0; k < 2; k++)
      for (int j = 0; j < 4; j++) brev_v[32*k+8*j+:8] = brev8_v[32*k+8*(3-j)+:8];
      default: for (int j = 0; j < 8; j++) brev_v[8*j+:8] = brev8_v[8*(7-j)+:8];
    endcase
  end

  logic [7:0] lt_bytes, ltu_bytes;
  assign lt_bytes  = spread(el_lt, s1_sew);
  assign ltu_bytes = spread(el_ltu, s1_sew);

  logic [63:0] result;
  logic [ 7:0] mask_at_top;
  always_comb begin
    result = '0;
    mask_at_top = '0;
    unique case (s1_op)
      VI_ADD, VI_SUB, VI_RSUB: result = s1_sum;
      VI_AND: result = s1_a & s1_b;
      VI_OR: result = s1_a | s1_b;
      VI_XOR: result = s1_a ^ s1_b;
      VI_ANDN: result = s1_a & ~s1_b;
      VI_MINU, VI_MIN, VI_MAXU, VI_MAX: begin
        logic [7:0] pick_a;
        unique case (s1_op)
          VI_MINU: pick_a = ltu_bytes;
          VI_MIN:  pick_a = lt_bytes;
          VI_MAXU: pick_a = ~ltu_bytes;
          default: pick_a = ~lt_bytes;
        endcase
        for (int i = 0; i < 8; i++) result[8*i+:8] = pick_a[i] ? s1_a[8*i+:8] : s1_b[8*i+:8];
      end
      VI_SLL, VI_SRL, VI_SRA, VI_ROL, VI_ROR: result = s1_shift;
      VI_MERGE:
      for (int i = 0; i < 8; i++) result[8*i+:8] = merge_bytes[i] ? s1_b[8*i+:8] : s1_a[8*i+:8];
      VI_MV: result = s1_b;
      VI_BREV: result = brev_v;
      VI_BREV8: result = brev8_v;
      VI_REV8: result = rev8_v;
      VI_CLZ: result = count_clz;
      VI_CTZ: result = count_ctz;
      VI_CPOP: result = count_pop;
      VI_MSEQ: mask_at_top = el_eq;
      VI_MSNE: mask_at_top = ~el_eq & element_tops(s1_sew);
      VI_MSLTU: mask_at_top = el_ltu;
      VI_MSLT: mask_at_top = el_lt;
      VI_MSLEU: mask_at_top = el_ltu | el_eq;
      VI_MSLE: mask_at_top = el_lt | el_eq;
      VI_MSGTU: mask_at_top = ~(el_ltu | el_eq) & element_tops(s1_sew);
      default: mask_at_top = ~(el_lt | el_eq) & element_tops(s1_sew);  // VI_MSGT
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s1_valid;
    o_result <= result;
    o_mask   <= pack(mask_at_top, s1_sew);
  end

endmodule
