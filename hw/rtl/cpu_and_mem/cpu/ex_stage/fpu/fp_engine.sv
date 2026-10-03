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
  Iterative floating-point engine for every F and D compute instruction:
  add/subtract, multiply, fused multiply-add, divide, square root, conversions,
  min/max, compares, classify, sign injection and the FMV moves, at single and
  double precision. One operation runs at a time.

  Two decode cycles classify the captured operands and resolve every special
  operand (NaN, infinity, zero, invalid, divide by zero, out-of-range
  conversion), FCLASS and sign injection. Everything else runs on one shared
  datapath:
    R  113-bit accumulator. Column 111 holds the leading bit of a normalized
       significand, column 112 a carry (after an add) or a sign (after a
       subtract), and column 0 is a sticky column: every right shift ORs the
       bits it shifts out into it.
    X  113-bit second operand, same layout.
    Q  56-bit multiplier, quotient or root bits.
    E, EX  exponents of column 111 of R and X.
  one 113-bit adder, and shifts by one or eight columns. An operand's 53-bit
  significand ({hidden, fraction}, single-precision fractions left-aligned)
  loads at columns [111:59], so both precisions share the datapath and differ
  only in iteration counts, exponent limits and the column where rounding
  happens (59 for double, 88 for single). Rounding happens once, from R's full
  contents, at the result precision.

  Multiply is radix-2 shift-and-add (53 or 24 steps); divide and square root
  are non-restoring, one bit per step (56 or 27 bits). Add and FMA normalize
  both operands and align the one with the smaller exponent into its sticky
  column; the product keeps all 106 bits, so FMA rounds once. Compares and
  min/max order the operands by subtracting their magnitudes, and integers
  (conversions to integer, FMV) leave through R[111:48]. Latency depends on the
  operation and the operands.

  i_start is sampled only while o_idle is high. o_done pulses for one cycle
  with the result: single-precision FP results NaN-boxed, integer results
  (compares, FCLASS, conversions to integer, FMV.X.*) XLEN-correct. i_kill drops
  the operation in progress; the engine is idle again on the next cycle.
*/
module fp_engine (
    input logic i_clk,
    input logic i_rst_n,

    input logic                        i_start,
    input riscv_pkg::instr_op_e        i_op,
    input logic                 [ 2:0] i_rm,
    input logic                 [63:0] i_src1,
    input logic                 [63:0] i_src2,
    input logic                 [63:0] i_src3,

    input logic i_kill,

    output logic                        o_idle,
    output logic                        o_done,
    output logic                 [63:0] o_result,
    output riscv_pkg::fp_flags_t        o_flags
);

  // ===========================================================================
  // Operation decode
  // ===========================================================================
  typedef enum logic [3:0] {
    CL_ADD,
    CL_MUL,
    CL_FMA,
    CL_DIV,
    CL_SQRT,
    CL_F2F,     // FCVT.S.D, FCVT.D.S
    CL_I2F,     // FCVT.{S,D}.{W,WU,L,LU}
    CL_F2I,     // FCVT.{W,WU,L,LU}.{S,D}
    CL_CMP,     // FEQ, FLT, FLE
    CL_MINMAX,
    CL_CLASS,
    CL_SGNJ,
    CL_MVXF,    // FMV.X.W, FMV.X.D
    CL_MVFX     // FMV.W.X, FMV.D.X
  } op_class_e;

  typedef struct packed {
    op_class_e  cls;
    logic       src_d;  // FP source operands are double precision
    logic       dst_d;  // FP result is double precision
    logic       neg_b;  // FSUB: negate operand 2
    logic       neg_p;  // FNMSUB, FNMADD: negate the product
    logic       neg_c;  // FMSUB, FNMADD: negate the addend
    // CMP: 0 FEQ, 1 FLT, 2 FLE. MINMAX: 0 FMIN, 1 FMAX. SGNJ: 0 J, 1 JN, 2 JX.
    logic [1:0] fn;
    logic       int_w;  // 32-bit integer form (and FMV.X.W)
    logic       int_u;  // unsigned integer form
  } op_dec_t;

  function automatic op_dec_t decode_op(input riscv_pkg::instr_op_e op);
    op_dec_t d;
    d = '0;
    d.cls = CL_MVFX;
    case (op)
      riscv_pkg::FADD_S: d.cls = CL_ADD;
      riscv_pkg::FSUB_S: begin
        d.cls   = CL_ADD;
        d.neg_b = 1'b1;
      end
      riscv_pkg::FMUL_S: d.cls = CL_MUL;
      riscv_pkg::FMADD_S: d.cls = CL_FMA;
      riscv_pkg::FMSUB_S: begin
        d.cls   = CL_FMA;
        d.neg_c = 1'b1;
      end
      riscv_pkg::FNMSUB_S: begin
        d.cls   = CL_FMA;
        d.neg_p = 1'b1;
      end
      riscv_pkg::FNMADD_S: begin
        d.cls   = CL_FMA;
        d.neg_p = 1'b1;
        d.neg_c = 1'b1;
      end
      riscv_pkg::FDIV_S: d.cls = CL_DIV;
      riscv_pkg::FSQRT_S: d.cls = CL_SQRT;
      riscv_pkg::FSGNJ_S: d.cls = CL_SGNJ;
      riscv_pkg::FSGNJN_S: begin
        d.cls = CL_SGNJ;
        d.fn  = 2'd1;
      end
      riscv_pkg::FSGNJX_S: begin
        d.cls = CL_SGNJ;
        d.fn  = 2'd2;
      end
      riscv_pkg::FMIN_S: d.cls = CL_MINMAX;
      riscv_pkg::FMAX_S: begin
        d.cls = CL_MINMAX;
        d.fn  = 2'd1;
      end
      riscv_pkg::FEQ_S: d.cls = CL_CMP;
      riscv_pkg::FLT_S: begin
        d.cls = CL_CMP;
        d.fn  = 2'd1;
      end
      riscv_pkg::FLE_S: begin
        d.cls = CL_CMP;
        d.fn  = 2'd2;
      end
      riscv_pkg::FCLASS_S: d.cls = CL_CLASS;
      riscv_pkg::FCVT_W_S: begin
        d.cls   = CL_F2I;
        d.int_w = 1'b1;
      end
      riscv_pkg::FCVT_WU_S: begin
        d.cls   = CL_F2I;
        d.int_w = 1'b1;
        d.int_u = 1'b1;
      end
      riscv_pkg::FCVT_L_S: d.cls = CL_F2I;
      riscv_pkg::FCVT_LU_S: begin
        d.cls   = CL_F2I;
        d.int_u = 1'b1;
      end
      riscv_pkg::FCVT_S_W: begin
        d.cls   = CL_I2F;
        d.int_w = 1'b1;
      end
      riscv_pkg::FCVT_S_WU: begin
        d.cls   = CL_I2F;
        d.int_w = 1'b1;
        d.int_u = 1'b1;
      end
      riscv_pkg::FCVT_S_L: d.cls = CL_I2F;
      riscv_pkg::FCVT_S_LU: begin
        d.cls   = CL_I2F;
        d.int_u = 1'b1;
      end
      riscv_pkg::FMV_X_W: begin
        d.cls   = CL_MVXF;
        d.int_w = 1'b1;
      end
      riscv_pkg::FMV_W_X: d.cls = CL_MVFX;

      riscv_pkg::FADD_D: begin
        d.cls   = CL_ADD;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FSUB_D: begin
        d.cls   = CL_ADD;
        d.neg_b = 1'b1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMUL_D: begin
        d.cls   = CL_MUL;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMADD_D: begin
        d.cls   = CL_FMA;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMSUB_D: begin
        d.cls   = CL_FMA;
        d.neg_c = 1'b1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FNMSUB_D: begin
        d.cls   = CL_FMA;
        d.neg_p = 1'b1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FNMADD_D: begin
        d.cls   = CL_FMA;
        d.neg_p = 1'b1;
        d.neg_c = 1'b1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FDIV_D: begin
        d.cls   = CL_DIV;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FSQRT_D: begin
        d.cls   = CL_SQRT;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FSGNJ_D: begin
        d.cls   = CL_SGNJ;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FSGNJN_D: begin
        d.cls = CL_SGNJ;
        d.fn = 2'd1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FSGNJX_D: begin
        d.cls = CL_SGNJ;
        d.fn = 2'd2;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMIN_D: begin
        d.cls   = CL_MINMAX;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMAX_D: begin
        d.cls = CL_MINMAX;
        d.fn = 2'd1;
        d.src_d = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FEQ_D: begin
        d.cls   = CL_CMP;
        d.src_d = 1'b1;
      end
      riscv_pkg::FLT_D: begin
        d.cls   = CL_CMP;
        d.fn    = 2'd1;
        d.src_d = 1'b1;
      end
      riscv_pkg::FLE_D: begin
        d.cls   = CL_CMP;
        d.fn    = 2'd2;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCLASS_D: begin
        d.cls   = CL_CLASS;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_W_D: begin
        d.cls   = CL_F2I;
        d.int_w = 1'b1;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_WU_D: begin
        d.cls   = CL_F2I;
        d.int_w = 1'b1;
        d.int_u = 1'b1;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_L_D: begin
        d.cls   = CL_F2I;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_LU_D: begin
        d.cls   = CL_F2I;
        d.int_u = 1'b1;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_D_W: begin
        d.cls   = CL_I2F;
        d.int_w = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FCVT_D_WU: begin
        d.cls   = CL_I2F;
        d.int_w = 1'b1;
        d.int_u = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FCVT_D_L: begin
        d.cls   = CL_I2F;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FCVT_D_LU: begin
        d.cls   = CL_I2F;
        d.int_u = 1'b1;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FCVT_S_D: begin
        d.cls   = CL_F2F;
        d.src_d = 1'b1;
      end
      riscv_pkg::FCVT_D_S: begin
        d.cls   = CL_F2F;
        d.dst_d = 1'b1;
      end
      riscv_pkg::FMV_X_D: d.cls = CL_MVXF;
      riscv_pkg::FMV_D_X: begin
        d.cls   = CL_MVFX;
        d.dst_d = 1'b1;
      end
      default: ;
    endcase
    decode_op = d;
  endfunction

  // ===========================================================================
  // Operand fields and classes
  // ===========================================================================
  // Fields of an operand at a precision. A single-precision operand whose upper
  // 32 bits are not all ones reads as the canonical NaN; its fraction is
  // left-aligned in the double layout.
  function automatic logic [10:0] field_exp(input logic [63:0] v, input logic box_ok,
                                            input logic is_d);
    if (is_d) field_exp = v[62:52];
    else field_exp = box_ok ? {3'b0, v[30:23]} : 11'h0FF;
  endfunction

  function automatic logic [51:0] field_frac(input logic [63:0] v, input logic box_ok,
                                             input logic is_d);
    if (is_d) field_frac = v[51:0];
    else field_frac = box_ok ? {v[22:0], 29'b0} : {1'b1, 51'b0};
  endfunction

  typedef struct packed {
    logic sign;
    logic zero;
    logic infinite;
    logic nan;
    logic snan;
    logic exp_zero;  // zero or subnormal
    logic box_ok;  // upper 32 bits all ones (single precision)
  } fp_class_t;

  function automatic fp_class_t classify(input logic [63:0] v, input logic is_d);
    fp_class_t c;
    logic [10:0] e;
    logic [51:0] f;
    logic e_max;
    begin
      c.box_ok = &v[63:32];
      e = field_exp(v, c.box_ok, is_d);
      f = field_frac(v, c.box_ok, is_d);
      e_max = is_d ? (&e) : (&e[7:0]);
      c.sign = is_d ? v[63] : (c.box_ok && v[31]);
      c.exp_zero = (e == '0);
      c.zero = c.exp_zero && (f == '0);
      c.infinite = e_max && (f == '0);
      c.nan = e_max && (f != '0);
      c.snan = c.nan && !f[51];
      classify = c;
    end
  endfunction

  // Unbiased exponent of the leading significand column (subnormals take the
  // minimum normal exponent).
  function automatic logic signed [13:0] unbiased_exp(input logic [63:0] v, input logic is_d);
    logic [10:0] e;
    begin
      e = field_exp(v, &v[63:32], is_d);
      unbiased_exp = $signed({3'b0, (e == '0) ? 11'd1 : e}) - (is_d ? 14'sd1023 : 14'sd127);
    end
  endfunction

  function automatic logic [63:0] pack_fp(input logic sign, input logic [10:0] expf,
                                          input logic [51:0] frac, input logic is_d);
    pack_fp = is_d ? {sign, expf, frac} : {32'hFFFF_FFFF, sign, expf[7:0], frac[51:29]};
  endfunction

  // ===========================================================================
  // State
  // ===========================================================================
  typedef enum logic [5:0] {
    ST_IDLE,
    ST_DEC1,        // classify the operands, registered
    ST_DEC2,        // special operands, FCLASS, sign injection; load operand A
    ST_LOADB,       // multiplier into Q
    ST_XFER,        // R <= X through the adder, X <= operand B
    ST_MUL,         // shift-and-add steps
    ST_FMA_C,       // addend into X
    ST_NORM_OPS,    // normalize subnormal operands, then set up alignment
    ST_RSHIFT,      // right shift R or X by sh_cnt, then continue at ret_q
    ST_ADD,
    ST_NEGATE,      // negative difference: R <= -R
    ST_DIV_SETUP,
    ST_DIV,         // non-restoring divide steps
    ST_DIV_FIX,     // restore a negative final remainder
    ST_SQRT_SETUP,
    ST_SQRT,        // non-restoring square-root steps
    ST_SQRT_FIX,    // restore a negative final remainder, last root bit
    ST_QFIN,        // remainder sticky, clear R
    ST_QXFER,       // quotient or root into R
    ST_I2F_NEG,
    ST_F2I_RPREP,
    ST_F2I_ROUND,
    ST_F2I_CHECK,
    ST_F2I_NEG,     // saturate, or negate a negative result
    ST_INT_OUT,     // integer result (or FMV) from R[111:48]
    ST_CMP_SUB,     // |A| - |B|
    ST_CMP_EVAL,    // magnitude order, registered
    ST_CMP_OUT,     // compare and min/max results
    ST_BE_NORM,     // carry fix, exact zero, left normalize, tininess
    ST_BE_RPREP,
    ST_BE_ROUND,
    ST_BE_CARRY,
    ST_BE_PACK,
    ST_DONE
  } state_e;

  typedef enum logic [1:0] {
    RET_ADD,
    RET_SQRT,
    RET_F2I,
    RET_BE
  } shift_ret_e;

  state_e state_q, state_d;

  // A LUT ROM: a block RAM's clock-to-out would sit in front of every decoded
  // control.
  (* rom_style = "distributed" *) op_dec_t dec_q;
  logic [2:0] rm_q;
  logic [63:0] opa_q, opb_q, opc_q;

  fp_class_t ca_q, cb_q, cc_q;
  logic signed [13:0] ea_q, eb_q, ec_q;
  logic f2i_over_q;  // F2I operand exponent above the integer range
  logic f2i_edge_q;  // F2I operand exponent at the top of the range
  logic int_zero_q;  // I2F integer operand is zero

  logic [112:0] r_q, r_d;
  logic [112:0] x_q, x_d;
  logic [55:0] q_q, q_d;
  logic signed [13:0] e_q, e_d;
  logic signed [13:0] ex_q, ex_d;
  logic [5:0] cnt_q, cnt_d;
  logic [6:0] sh_cnt_q, sh_cnt_d;
  logic sh_x_q, sh_x_d;  // shift X instead of R
  logic sh_collapse_q, sh_collapse_d;
  shift_ret_e ret_q, ret_d;

  logic sr_q, sr_d;  // sign of R, the result sign
  logic sx_q, sx_d;  // sign of X
  logic zr_q, zr_d;  // R's operand is zero (add, FMA)
  logic zx_q, zx_d;  // X's operand is zero (or X unused)
  logic eff_sub_q, eff_sub_d;
  logic first_q, first_d;  // first divide step
  logic qlast_q, qlast_d;  // last square-root bit, held for ST_SQRT_FIX
  logic rem_nz_q, rem_nz_d;
  logic tiny_q, tiny_d;
  logic inexact_q, inexact_d;
  logic round_up_q, round_up_d;
  logic oor_q, oor_d;
  logic zero_res_q, zero_res_d;
  logic mag_lt_q, mag_lt_d;  // |A| < |B|
  logic mag_eq_q, mag_eq_d;  // |A| == |B|

  logic [63:0] res_q, res_d;
  riscv_pkg::fp_flags_t flags_q, flags_d;

  assign o_idle   = (state_q == ST_IDLE);
  assign o_done   = (state_q == ST_DONE);
  assign o_result = res_q;
  assign o_flags  = flags_q;

  // FCVT to FP: integer operand, W forms extended.
  logic [63:0] int64;
  always_comb begin
    if (dec_q.int_w) begin
      int64 = dec_q.int_u ? {32'b0, opa_q[31:0]} : {{32{opa_q[31]}}, opa_q[31:0]};
    end else begin
      int64 = opa_q;
    end
  end

  logic signed [13:0] f2i_limit;
  assign f2i_limit = dec_q.int_w ? 14'sd31 : 14'sd63;

  // ===========================================================================
  // Operand loads
  // ===========================================================================
  typedef enum logic [1:0] {
    SEL_A,
    SEL_B,
    SEL_C
  } ld_sel_e;

  ld_sel_e ld_sel;
  logic [63:0] ld_raw;
  fp_class_t ld_cls;
  logic signed [13:0] ld_exp;
  always_comb begin
    unique case (ld_sel)
      SEL_B: begin
        ld_raw = opb_q;
        ld_cls = cb_q;
        ld_exp = eb_q;
      end
      SEL_C: begin
        ld_raw = opc_q;
        ld_cls = cc_q;
        ld_exp = ec_q;
      end
      default: begin
        ld_raw = opa_q;
        ld_cls = ca_q;
        ld_exp = ea_q;
      end
    endcase
  end

  // X load value. FP operands load their significand {hidden, fraction} at
  // [111:59]. The integer of an FCVT to FP, the register value of an FMV, and
  // the magnitude a compare or min/max orders load at [111:48]: W forms
  // extend from bit 31 (sign extension in column 112 for the signed forms),
  // and a magnitude drops the sign (single precision: the low 31 bits; an
  // improperly boxed operand is a NaN and its order is never used).
  logic [ 10:0] ld_expf;
  logic [ 51:0] ld_frac;
  logic [112:0] ld_word;
  logic ld_int_pos, ld_mag, ld_i2f;
  logic [63:0] ld_word64;
  assign ld_expf = field_exp(ld_raw, ld_cls.box_ok, dec_q.src_d);
  assign ld_frac = field_frac(ld_raw, ld_cls.box_ok, dec_q.src_d);
  assign ld_i2f = (dec_q.cls == CL_I2F);
  assign ld_mag = (dec_q.cls == CL_CMP) || (dec_q.cls == CL_MINMAX);
  assign ld_int_pos = ld_i2f || ld_mag || (dec_q.cls == CL_MVXF) || (dec_q.cls == CL_MVFX);
  always_comb begin
    ld_word64 = ld_raw;
    if (ld_i2f && dec_q.int_w) ld_word64[63:32] = dec_q.int_u ? '0 : {32{ld_raw[31]}};
    if (ld_mag) begin
      ld_word64[63] = 1'b0;
      if (!dec_q.src_d) ld_word64[62:31] = '0;
    end
    if (ld_int_pos) ld_word = {ld_i2f && !dec_q.int_u && ld_word64[63], ld_word64, 48'b0};
    else ld_word = {1'b0, !ld_cls.exp_zero, ld_frac, 59'b0};
  end

  // ===========================================================================
  // Result-precision constants and rounding bits
  // ===========================================================================
  logic signed [13:0] emin_p, floor_p, emax_p, bias_p;
  assign emin_p  = dec_q.dst_d ? -14'sd1022 : -14'sd126;
  assign floor_p = dec_q.dst_d ? -14'sd1023 : -14'sd127;
  assign emax_p  = dec_q.dst_d ? 14'sd1023 : 14'sd127;
  assign bias_p  = dec_q.dst_d ? 14'sd1023 : 14'sd127;

  // Significand R[111:59] (double) or R[111:88] (single), then guard, round
  // and sticky.
  logic rb_lsb, rb_guard, rb_round, rb_sticky, rb_all_ones;
  logic sticky_low;  // |R[56:0], shared by both precisions
  assign sticky_low = |r_q[56:0];
  always_comb begin
    if (dec_q.dst_d) begin
      rb_lsb      = r_q[59];
      rb_guard    = r_q[58];
      rb_round    = r_q[57];
      rb_sticky   = sticky_low;
      rb_all_ones = &r_q[111:59];
    end else begin
      rb_lsb      = r_q[88];
      rb_guard    = r_q[87];
      rb_round    = r_q[86];
      rb_sticky   = sticky_low | (|r_q[85:57]);
      rb_all_ones = &r_q[111:88];
    end
  end

  // Tininess after rounding: below the minimum normal, unless the value sits
  // in the binade just below it with an all-ones significand that rounds up
  // into it. A value left unnormalized at the floor exponent is below half the
  // minimum normal and always tiny.
  logic be_tiny;
  assign be_tiny = (e_q < emin_p) && !((e_q == floor_p) && r_q[111] && rb_all_ones &&
      riscv_pkg::fp_compute_round_up(
      rm_q, rb_guard, rb_round, rb_sticky, 1'b1, sr_q
  ));

  // Integer rounding bits: LSB at column 48.
  logic ib_guard, ib_round, ib_sticky;
  assign ib_guard  = r_q[47];
  assign ib_round  = r_q[46];
  assign ib_sticky = |r_q[45:0];

  // F2I range check of the rounded magnitude R[112:48].
  logic [64:0] f2i_mag;
  logic f2i_oor;
  assign f2i_mag = r_q[112:48];
  always_comb begin
    if (dec_q.int_u) begin
      if (sr_q) f2i_oor = (f2i_mag != '0);
      else f2i_oor = dec_q.int_w ? (f2i_mag[64:32] != '0) : f2i_mag[64];
    end else if (sr_q) begin
      f2i_oor = dec_q.int_w ?
          ((f2i_mag[64:32] != '0) || (f2i_mag[31] && (f2i_mag[30:0] != '0))) :
          (f2i_mag[64] || (f2i_mag[63] && (f2i_mag[62:0] != '0)));
    end else begin
      f2i_oor = dec_q.int_w ? (f2i_mag[64:31] != '0) : (f2i_mag[64:63] != '0);
    end
  end

  // ===========================================================================
  // Adder and register next-value selects
  // ===========================================================================
  typedef enum logic [1:0] {
    A_R,
    A_SHL1,
    A_SHL2
  } a_sel_e;

  typedef enum logic [1:0] {
    B_ZERO,
    B_X,
    B_QT,
    B_CONST
  } b_sel_e;

  typedef enum logic [1:0] {
    K_D,   // column 59
    K_S,   // column 88
    K_INT  // column 48
  } const_sel_e;

  typedef enum logic [2:0] {
    R_HOLD,
    R_SUM,
    R_SHR1,  // sum >> 1, sticky
    R_SHR8,  // sum >> 8, sticky
    R_SHL1,
    R_SHL8,
    R_CLEAR,
    R_COLLAPSE
  } r_sel_e;

  typedef enum logic [2:0] {
    X_HOLD,
    X_LOAD,
    X_SHR1,
    X_SHR8,
    X_SHL1,
    X_COLLAPSE
  } x_sel_e;

  a_sel_e a_sel;
  b_sel_e b_sel;
  const_sel_e k_sel;
  r_sel_e r_sel;
  x_sel_e x_sel;
  logic inv_a, inv_b, cin;
  logic [1:0] qt_low;  // columns 55:54 of the QT vector
  logic qt_b0;  // column 0 of the QT vector

  logic [112:0] a_in, b_in, sum;
  logic [112:0] qt_vec, const_vec;

  always_comb begin
    unique case (a_sel)
      A_SHL1:  a_in = {r_q[111:0], 1'b0};
      A_SHL2:  a_in = {r_q[110:0], 2'b0};
      default: a_in = r_q;
    endcase
  end

  // Quotient or root at [111:56] (a square-root trial value {Q, 01} or
  // {Q, 11} at [111:54]), with an optional bit at column 0.
  assign qt_vec = {1'b0, q_q, qt_low, 53'b0, qt_b0};

  always_comb begin
    const_vec = '0;
    unique case (k_sel)
      K_S:     const_vec[88] = 1'b1;
      K_INT:   const_vec[48] = 1'b1;
      default: const_vec[59] = 1'b1;
    endcase
  end

  always_comb begin
    unique case (b_sel)
      B_X:     b_in = x_q;
      B_QT:    b_in = qt_vec;
      B_CONST: b_in = const_vec;
      default: b_in = '0;
    endcase
  end

  assign sum = (a_in ^ {113{inv_a}}) + (b_in ^ {113{inv_b}}) + {112'b0, cin};

  function automatic logic [112:0] shr1(input logic [112:0] v);
    shr1 = {1'b0, v[112:2], v[1] | v[0]};
  endfunction

  function automatic logic [112:0] shr8(input logic [112:0] v);
    shr8 = {8'b0, v[112:9], |v[8:0]};
  endfunction

  function automatic logic [112:0] collapse(input logic [112:0] v);
    collapse = {112'b0, |v};
  endfunction

  always_comb begin
    unique case (r_sel)
      R_SUM:      r_d = sum;
      R_SHR1:     r_d = shr1(sum);
      R_SHR8:     r_d = shr8(sum);
      R_SHL1:     r_d = {r_q[111:0], 1'b0};
      R_SHL8:     r_d = {r_q[104:0], 8'b0};
      R_CLEAR:    r_d = '0;
      R_COLLAPSE: r_d = collapse(r_q);
      default:    r_d = r_q;
    endcase
  end

  always_comb begin
    unique case (x_sel)
      X_LOAD:     x_d = ld_word;
      X_SHR1:     x_d = shr1(x_q);
      X_SHR8:     x_d = shr8(x_q);
      X_SHL1:     x_d = {x_q[111:0], 1'b0};
      X_COLLAPSE: x_d = collapse(x_q);
      default:    x_d = x_q;
    endcase
  end

  // Exponent arithmetic: one adder, E <= P + Q + cin.
  typedef enum logic [1:0] {
    EP_E,
    EP_EX,
    EP_ZERO
  } ep_sel_e;

  typedef enum logic [2:0] {
    EQ_ZERO,
    EQ_M1,
    EQ_M8,
    EQ_LD,     // the selected operand's exponent
    EQ_NOTEX,  // ~EX (with cin: -EX)
    EQ_29,
    EQ_63,
    EQ_EMIN
  } eq_sel_e;

  ep_sel_e ep_sel;
  eq_sel_e eq_sel;
  logic e_load, e_cin, e_sqrt;
  logic ex_load, ex_dec;
  logic signed [13:0] e_p, e_qv, e_sum;
  logic signed [13:0] sqrt_e_even;  // square-root exponent made even

  always_comb begin
    unique case (ep_sel)
      EP_EX:   e_p = ex_q;
      EP_ZERO: e_p = '0;
      default: e_p = e_q;
    endcase
    unique case (eq_sel)
      EQ_M1:    e_qv = -14'sd1;
      EQ_M8:    e_qv = -14'sd8;
      EQ_LD:    e_qv = ld_exp;
      EQ_NOTEX: e_qv = ~ex_q;
      EQ_29:    e_qv = 14'sd29;
      EQ_63:    e_qv = 14'sd63;
      EQ_EMIN:  e_qv = emin_p;
      default:  e_qv = '0;
    endcase
  end

  assign e_sum = e_p + e_qv + $signed({13'b0, e_cin});
  assign sqrt_e_even = e_q - $signed({13'b0, e_q[0]});
  assign e_d = e_sqrt ? (sqrt_e_even >>> 1) : (e_load ? e_sum : e_q);
  assign ex_d = ex_load ? ld_exp : (ex_dec ? (ex_q - 14'sd1) : ex_q);

  // ===========================================================================
  // Results
  // ===========================================================================
  // FP results: pack(sign, exponent field, fraction field) at the result
  // precision. Integer results: from R[111:48] or a small constant.
  typedef enum logic [2:0] {
    FE_BIASED,  // datapath: E + bias, or 0 for a subnormal
    FE_ONES,
    FE_MAXN,
    FE_ZERO,
    FE_LD       // the selected operand's field
  } fe_sel_e;

  typedef enum logic [2:0] {
    FF_R,
    FF_ZERO,
    FF_ONES,
    FF_QNAN,
    FF_LD
  } ff_sel_e;

  typedef enum logic [2:0] {
    IR_R64,  // R[111:48]
    IR_RW,  // R[79:48] sign-extended
    IR_RBOX,  // R[79:48] NaN-boxed (FMV.W.X)
    IR_SATP,
    IR_SATN,
    IR_BIT,
    IR_CLASS,
    IR_ZERO
  } ir_sel_e;

  logic res_load, res_is_fp;
  logic fp_sign;
  fe_sel_e fe_sel;
  ff_sel_e ff_sel;
  ir_sel_e ir_sel;
  logic res_bit;

  logic signed [13:0] be_biased;
  logic [10:0] fp_expf;
  logic [51:0] fp_frac;
  assign be_biased = e_q + bias_p;

  always_comb begin
    unique case (fe_sel)
      FE_ONES: fp_expf = 11'h7FF;
      FE_MAXN: fp_expf = 11'h7FE;  // single: low 8 bits 0xFE
      FE_ZERO: fp_expf = '0;
      FE_LD:   fp_expf = ld_expf;
      default: fp_expf = r_q[111] ? be_biased[10:0] : 11'd0;
    endcase
    unique case (ff_sel)
      FF_ZERO: fp_frac = '0;
      FF_ONES: fp_frac = '1;
      FF_QNAN: fp_frac = {1'b1, 51'b0};
      FF_LD:   fp_frac = ld_frac;
      default: fp_frac = dec_q.dst_d ? r_q[110:59] : {r_q[110:88], 29'b0};
    endcase
  end

  // Saturation values of a conversion to integer (W forms sign-extended).
  logic [63:0] sat_pos, sat_neg;
  always_comb begin
    if (dec_q.int_u) begin
      sat_pos = '1;
      sat_neg = '0;
    end else if (dec_q.int_w) begin
      sat_pos = 64'h0000_0000_7FFF_FFFF;
      sat_neg = 64'hFFFF_FFFF_8000_0000;
    end else begin
      sat_pos = 64'h7FFF_FFFF_FFFF_FFFF;
      sat_neg = 64'h8000_0000_0000_0000;
    end
  end

  logic [9:0] class_mask;
  always_comb begin
    class_mask = '0;
    if (ca_q.nan) class_mask[ca_q.snan ? 8 : 9] = 1'b1;
    else if (ca_q.infinite) class_mask[ca_q.sign ? 0 : 7] = 1'b1;
    else if (ca_q.zero) class_mask[ca_q.sign ? 3 : 4] = 1'b1;
    else if (ca_q.exp_zero) class_mask[ca_q.sign ? 2 : 5] = 1'b1;
    else class_mask[ca_q.sign ? 1 : 6] = 1'b1;
  end

  logic [63:0] int_res;
  always_comb begin
    unique case (ir_sel)
      IR_RW:    int_res = {{32{r_q[79]}}, r_q[79:48]};
      IR_RBOX:  int_res = {32'hFFFF_FFFF, r_q[79:48]};
      IR_SATP:  int_res = sat_pos;
      IR_SATN:  int_res = sat_neg;
      IR_BIT:   int_res = {63'b0, res_bit};
      IR_CLASS: int_res = {54'b0, class_mask};
      IR_ZERO:  int_res = '0;
      default:  int_res = r_q[111:48];
    endcase
  end

  assign res_d = !res_load ? res_q : (res_is_fp ? pack_fp(
      fp_sign, fp_expf, fp_frac, dec_q.dst_d
  ) : int_res);

  // ===========================================================================
  // Decode cycle 2: special operands
  // ===========================================================================
  logic sign_p;  // FMA product sign
  logic sign_c;  // FMA addend sign
  logic inf_times_zero;
  assign sign_p = ca_q.sign ^ cb_q.sign ^ dec_q.neg_p;
  assign sign_c = cc_q.sign ^ dec_q.neg_c;
  assign inf_times_zero = (ca_q.infinite && cb_q.zero) || (ca_q.zero && cb_q.infinite);

  typedef enum logic [1:0] {
    SP_NONE,
    SP_QNAN,
    SP_INF,
    SP_ZERO
  } sp_kind_e;

  sp_kind_e sp_kind;
  logic sp_sign;
  riscv_pkg::fp_flags_t sp_flags;

  always_comb begin
    sp_kind  = SP_NONE;
    sp_sign  = 1'b0;
    sp_flags = '0;
    unique case (dec_q.cls)
      CL_ADD: begin
        if (ca_q.nan || cb_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan || cb_q.snan;
        end else if (ca_q.infinite && cb_q.infinite &&
                     (ca_q.sign != (cb_q.sign ^ dec_q.neg_b))) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = 1'b1;
        end else if (ca_q.infinite) begin
          sp_kind = SP_INF;
          sp_sign = ca_q.sign;
        end else if (cb_q.infinite) begin
          sp_kind = SP_INF;
          sp_sign = cb_q.sign ^ dec_q.neg_b;
        end
      end

      CL_MUL: begin
        sp_sign = ca_q.sign ^ cb_q.sign;
        if (ca_q.nan || cb_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan || cb_q.snan;
        end else if (inf_times_zero) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = 1'b1;
        end else if (ca_q.infinite || cb_q.infinite) begin
          sp_kind = SP_INF;
        end else if (ca_q.zero || cb_q.zero) begin
          sp_kind = SP_ZERO;
        end
      end

      CL_FMA: begin
        if (ca_q.nan || cb_q.nan || cc_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan || cb_q.snan || cc_q.snan || inf_times_zero;
        end else if (inf_times_zero) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = 1'b1;
        end else if (ca_q.infinite || cb_q.infinite) begin
          if (cc_q.infinite && (sign_c != sign_p)) begin
            sp_kind = SP_QNAN;
            sp_flags.nv = 1'b1;
          end else begin
            sp_kind = SP_INF;
            sp_sign = sign_p;
          end
        end else if (cc_q.infinite) begin
          sp_kind = SP_INF;
          sp_sign = sign_c;
        end
      end

      CL_DIV: begin
        sp_sign = ca_q.sign ^ cb_q.sign;
        if (ca_q.nan || cb_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan || cb_q.snan;
        end else if ((ca_q.infinite && cb_q.infinite) || (ca_q.zero && cb_q.zero)) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = 1'b1;
        end else if (ca_q.infinite) begin
          sp_kind = SP_INF;
        end else if (cb_q.infinite) begin
          sp_kind = SP_ZERO;
        end else if (cb_q.zero) begin
          sp_kind = SP_INF;
          sp_flags.dz = 1'b1;
        end else if (ca_q.zero) begin
          sp_kind = SP_ZERO;
        end
      end

      CL_SQRT: begin
        if (ca_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan;
        end else if (ca_q.sign && !ca_q.zero) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = 1'b1;
        end else if (ca_q.infinite) begin
          sp_kind = SP_INF;
        end else if (ca_q.zero) begin
          sp_kind = SP_ZERO;
          sp_sign = ca_q.sign;
        end
      end

      CL_F2F: begin
        sp_sign = ca_q.sign;
        if (ca_q.nan) begin
          sp_kind = SP_QNAN;
          sp_flags.nv = ca_q.snan;
        end else if (ca_q.infinite) begin
          sp_kind = SP_INF;
        end else if (ca_q.zero) begin
          sp_kind = SP_ZERO;
        end
      end

      CL_I2F: begin
        if (int_zero_q) sp_kind = SP_ZERO;
      end

      default: ;
    endcase
    if (sp_kind == SP_QNAN) sp_sign = 1'b0;
  end

  // F2I special operands: NaN and infinities saturate with NV, zero is 0, and
  // so is an exponent beyond the integer range (at the top exponent only an
  // unsigned positive or a signed negative value can still be in range).
  logic f2i_special, f2i_sat;
  always_comb begin
    f2i_special = ca_q.nan || ca_q.infinite || ca_q.zero || f2i_over_q ||
        (f2i_edge_q && !(dec_q.int_u ^ ca_q.sign));
    f2i_sat = !ca_q.zero;
  end

  logic sgnj_sign;
  always_comb begin
    unique case (dec_q.fn)
      2'd1:    sgnj_sign = !cb_q.sign;
      2'd2:    sgnj_sign = ca_q.sign ^ cb_q.sign;
      default: sgnj_sign = cb_q.sign;
    endcase
  end

  // Compare and min/max from the registered magnitude order.
  logic a_lt_b, a_eq_b;
  always_comb begin
    if (ca_q.zero && cb_q.zero) begin
      a_lt_b = 1'b0;
      a_eq_b = 1'b1;
    end else if (ca_q.sign != cb_q.sign) begin
      a_lt_b = ca_q.sign;
      a_eq_b = 1'b0;
    end else begin
      a_lt_b = ca_q.sign ? !(mag_lt_q || mag_eq_q) : mag_lt_q;
      a_eq_b = mag_eq_q;
    end
  end

  // Min/max picks operand B when A is a NaN, or when B orders first for FMIN
  // (last for FMAX); -0 orders below +0.
  logic minmax_pick_b;
  always_comb begin
    if (ca_q.nan) minmax_pick_b = 1'b1;
    else if (cb_q.nan) minmax_pick_b = 1'b0;
    else if (ca_q.zero && cb_q.zero) minmax_pick_b = !(ca_q.sign ^ dec_q.fn[0]);
    else minmax_pick_b = !(a_lt_b ^ dec_q.fn[0]);
  end

  // ===========================================================================
  // Sequencer
  // ===========================================================================
  logic [5:0] mul_steps, qbits;
  assign mul_steps = dec_q.src_d ? 6'd53 : 6'd24;
  assign qbits = dec_q.src_d ? 6'd56 : 6'd27;

  // Multiplier bits straight from operand B (single precision: 24 bits
  // right-aligned; an improperly boxed operand is a NaN and never multiplies).
  logic [55:0] q_mul;
  assign q_mul = dec_q.src_d ? {3'b0, !cb_q.exp_zero, opb_q[51:0]} :
      {32'b0, !cb_q.exp_zero, opb_q[22:0]};

  logic r_nonzero;
  assign r_nonzero = |r_q;

  logic r_needs_norm, x_needs_norm, r_top8_zero;
  assign r_needs_norm = !zr_q && !r_q[111];
  assign x_needs_norm = !zx_q && !x_q[111];
  assign r_top8_zero  = (r_q[111:104] == '0);

  // Alignment: EX - E, and its magnitude (collapse from 128 columns).
  logic signed [13:0] align_diff;
  logic [13:0] align_abs;
  assign align_diff = ex_q - e_q;
  assign align_abs  = align_diff[13] ? 14'(-align_diff) : 14'(align_diff);

  logic signed [13:0] denorm_diff;  // emin - E
  logic signed [13:0] f2i_diff;  // 63 - EX (F2I shift, set up in ST_XFER)
  assign denorm_diff = emin_p - e_q;
  assign f2i_diff = 14'sd63 - ex_q;

  logic sh_step8;  // this shift step moves eight columns
  assign sh_step8 = (sh_cnt_q >= 7'd8);

  logic ovf_to_max;
  assign ovf_to_max = (rm_q == riscv_pkg::FRM_RTZ) ||
      ((rm_q == riscv_pkg::FRM_RDN) && !sr_q) || ((rm_q == riscv_pkg::FRM_RUP) && sr_q);

  always_comb begin
    state_d = state_q;
    q_d = q_q;
    cnt_d = cnt_q;
    sh_cnt_d = sh_cnt_q;
    sh_x_d = sh_x_q;
    sh_collapse_d = sh_collapse_q;
    ret_d = ret_q;
    sr_d = sr_q;
    sx_d = sx_q;
    zr_d = zr_q;
    zx_d = zx_q;
    eff_sub_d = eff_sub_q;
    first_d = first_q;
    qlast_d = qlast_q;
    rem_nz_d = rem_nz_q;
    tiny_d = tiny_q;
    inexact_d = inexact_q;
    round_up_d = round_up_q;
    oor_d = oor_q;
    zero_res_d = zero_res_q;
    mag_lt_d = mag_lt_q;
    mag_eq_d = mag_eq_q;
    flags_d = flags_q;

    ld_sel = SEL_A;
    a_sel = A_R;
    b_sel = B_ZERO;
    k_sel = K_D;
    r_sel = R_HOLD;
    x_sel = X_HOLD;
    inv_a = 1'b0;
    inv_b = 1'b0;
    cin = 1'b0;
    qt_low = 2'b00;
    qt_b0 = 1'b0;
    ep_sel = EP_E;
    eq_sel = EQ_ZERO;
    e_load = 1'b0;
    e_cin = 1'b0;
    e_sqrt = 1'b0;
    ex_load = 1'b0;
    ex_dec = 1'b0;
    res_load = 1'b0;
    res_is_fp = 1'b1;
    fp_sign = sr_q;
    fe_sel = FE_BIASED;
    ff_sel = FF_R;
    ir_sel = IR_R64;
    res_bit = 1'b0;

    unique case (state_q)
      ST_IDLE: begin
        if (i_start) state_d = ST_DEC1;
      end

      ST_DEC1: state_d = ST_DEC2;

      ST_DEC2: begin
        eff_sub_d = 1'b0;
        zero_res_d = 1'b0;
        tiny_d = 1'b0;
        inexact_d = 1'b0;
        r_sel = R_CLEAR;
        // Operand A into X (the magnitude for compares, the raw value for
        // moves, the integer for FCVT to FP).
        x_sel = X_LOAD;
        ex_load = 1'b1;
        sx_d = ca_q.sign;
        zx_d = ca_q.zero;
        sr_d = ca_q.sign;
        flags_d = sp_flags;
        if (sp_kind != SP_NONE) begin
          res_load = 1'b1;
          fp_sign  = sp_sign;
          fe_sel   = (sp_kind == SP_ZERO) ? FE_ZERO : FE_ONES;
          ff_sel   = (sp_kind == SP_QNAN) ? FF_QNAN : FF_ZERO;
          state_d  = ST_DONE;
        end else begin
          unique case (dec_q.cls)
            CL_CLASS: begin
              res_load = 1'b1;
              res_is_fp = 1'b0;
              ir_sel = IR_CLASS;
              state_d = ST_DONE;
            end
            CL_SGNJ: begin
              res_load = 1'b1;
              fp_sign  = sgnj_sign;
              fe_sel   = FE_LD;
              ff_sel   = FF_LD;
              state_d  = ST_DONE;
            end
            CL_F2I: begin
              if (f2i_special) begin
                res_load = 1'b1;
                res_is_fp = 1'b0;
                ir_sel = !f2i_sat ? IR_ZERO : ((ca_q.sign && !ca_q.nan) ? IR_SATN : IR_SATP);
                flags_d.nv = f2i_sat;
                state_d = ST_DONE;
              end else begin
                state_d = ST_XFER;
              end
            end
            CL_MUL, CL_FMA: begin
              sr_d = sign_p;
              zr_d = ca_q.zero || cb_q.zero;
              // A zero product (FMA only; FMUL's is a special case) adds
              // nothing: continue with R = 0 and the addend.
              state_d = (ca_q.zero || cb_q.zero) ? ST_FMA_C : ST_LOADB;
            end
            CL_DIV: begin
              sr_d = ca_q.sign ^ cb_q.sign;
              state_d = ST_XFER;
            end
            CL_SQRT: begin
              sr_d = 1'b0;
              state_d = ST_XFER;
            end
            default: state_d = ST_XFER;
          endcase
        end
      end

      ST_LOADB: begin
        q_d = q_mul;
        ep_sel = EP_EX;
        eq_sel = EQ_LD;
        ld_sel = SEL_B;
        e_cin = 1'b1;
        e_load = 1'b1;
        cnt_d = mul_steps;
        state_d = ST_MUL;
      end

      ST_XFER: begin
        // R was cleared in ST_DEC2, so the adder passes X.
        b_sel  = B_X;
        r_sel  = R_SUM;
        ep_sel = EP_EX;
        e_load = 1'b1;
        unique case (dec_q.cls)
          CL_ADD: begin
            sr_d = sx_q;
            zr_d = zx_q;
            ld_sel = SEL_B;
            x_sel = X_LOAD;
            ex_load = 1'b1;
            sx_d = cb_q.sign ^ dec_q.neg_b;
            zx_d = cb_q.zero;
            state_d = ST_NORM_OPS;
          end
          CL_DIV: begin
            zr_d = 1'b0;
            ld_sel = SEL_B;
            x_sel = X_LOAD;
            ex_load = 1'b1;
            zx_d = 1'b0;
            state_d = ST_NORM_OPS;
          end
          CL_SQRT: begin
            zr_d = 1'b0;
            zx_d = 1'b1;
            state_d = ST_NORM_OPS;
          end
          CL_CMP, CL_MINMAX: begin
            ld_sel  = SEL_B;
            x_sel   = X_LOAD;
            state_d = ST_CMP_SUB;
          end
          CL_MVXF, CL_MVFX: state_d = ST_INT_OUT;
          CL_I2F: begin
            ep_sel = EP_ZERO;
            eq_sel = EQ_63;
            sr_d = x_q[112];
            state_d = ST_I2F_NEG;
          end
          CL_F2I: begin
            // Shift the integer LSB to column 48 (E = 63).
            ep_sel = EP_ZERO;
            eq_sel = EQ_63;
            sh_x_d = 1'b0;
            sh_collapse_d = (f2i_diff >= 14'sd128);
            sh_cnt_d = f2i_diff[6:0];
            ret_d = RET_F2I;
            state_d = (f2i_diff == '0) ? ST_F2I_RPREP : ST_RSHIFT;
          end
          default: state_d = ST_BE_NORM;  // CL_F2F
        endcase
      end

      ST_MUL: begin
        b_sel = q_q[0] ? B_X : B_ZERO;
        r_sel = R_SHR1;
        q_d   = {1'b0, q_q[55:1]};
        cnt_d = cnt_q - 6'd1;
        if (cnt_q == 6'd1) state_d = (dec_q.cls == CL_FMA) ? ST_FMA_C : ST_BE_NORM;
      end

      ST_FMA_C: begin
        ld_sel = SEL_C;
        x_sel = X_LOAD;
        ex_load = 1'b1;
        sx_d = sign_c;
        zx_d = cc_q.zero;
        state_d = ST_NORM_OPS;
      end

      ST_NORM_OPS: begin
        if (r_needs_norm) begin
          r_sel  = r_top8_zero ? R_SHL8 : R_SHL1;
          eq_sel = r_top8_zero ? EQ_M8 : EQ_M1;
          e_load = 1'b1;
        end
        if (x_needs_norm) begin
          x_sel  = X_SHL1;
          ex_dec = 1'b1;
        end
        if (!r_needs_norm && !x_needs_norm) begin
          unique case (dec_q.cls)
            CL_DIV:  state_d = ST_DIV_SETUP;
            CL_SQRT: state_d = ST_SQRT_SETUP;
            default: begin
              // Add and FMA: align the smaller-exponent operand. A zero operand
              // needs no alignment (R = 0 takes X's exponent).
              ret_d = RET_ADD;
              sh_x_d = align_diff[13];
              sh_collapse_d = (align_abs >= 14'd128);
              sh_cnt_d = align_abs[6:0];
              ep_sel = EP_EX;
              if (zx_q) begin
                state_d = ST_ADD;
              end else if (zr_q) begin
                e_load  = 1'b1;
                state_d = ST_ADD;
              end else begin
                e_load  = !align_diff[13];
                state_d = (align_diff == '0) ? ST_ADD : ST_RSHIFT;
              end
            end
          endcase
        end
      end

      ST_RSHIFT: begin
        if (sh_collapse_q) begin
          if (sh_x_q) x_sel = X_COLLAPSE;
          else r_sel = R_COLLAPSE;
          sh_cnt_d = '0;
        end else begin
          if (sh_x_q) x_sel = sh_step8 ? X_SHR8 : X_SHR1;
          else r_sel = sh_step8 ? R_SHR8 : R_SHR1;
          sh_cnt_d = sh_cnt_q - (sh_step8 ? 7'd8 : 7'd1);
        end
        if (sh_collapse_q || (sh_cnt_q == 7'd1) || (sh_cnt_q == 7'd8)) begin
          unique case (ret_q)
            RET_SQRT: state_d = ST_SQRT;
            RET_F2I:  state_d = ST_F2I_RPREP;
            RET_BE:   state_d = ST_BE_RPREP;
            default:  state_d = ST_ADD;
          endcase
        end
      end

      ST_ADD: begin
        b_sel = B_X;
        inv_b = sr_q ^ sx_q;
        cin = sr_q ^ sx_q;
        r_sel = R_SUM;
        eff_sub_d = sr_q ^ sx_q;
        state_d = (sr_q ^ sx_q) ? ST_NEGATE : ST_BE_NORM;
      end

      ST_NEGATE: begin
        if (r_q[112]) begin
          inv_a = 1'b1;
          cin   = 1'b1;
          r_sel = R_SUM;
          sr_d  = !sr_q;
        end
        state_d = ST_BE_NORM;
      end

      ST_DIV_SETUP: begin
        // Operands to [110:58], so twice a remainder stays below column 112.
        eq_sel = EQ_NOTEX;
        e_cin = 1'b1;
        e_load = 1'b1;
        r_sel = R_SHR1;
        x_sel = X_SHR1;
        q_d = '0;
        cnt_d = qbits;
        first_d = 1'b1;
        state_d = ST_DIV;
      end

      ST_DIV: begin
        // Non-restoring: P0 = A - B; then Pk = 2Pk-1 - B if Pk-1 >= 0, else
        // 2Pk-1 + B. Quotient bit k is Pk >= 0.
        a_sel = first_q ? A_R : A_SHL1;
        b_sel = B_X;
        inv_b = first_q || !r_q[112];
        cin = first_q || !r_q[112];
        r_sel = R_SUM;
        q_d = {q_q[54:0], !sum[112]};
        cnt_d = cnt_q - 6'd1;
        first_d = 1'b0;
        if (cnt_q == 6'd1) state_d = ST_DIV_FIX;
      end

      ST_DIV_FIX: begin
        if (r_q[112]) begin
          b_sel = B_X;
          r_sel = R_SUM;
        end
        state_d = ST_QFIN;
      end

      ST_SQRT_SETUP: begin
        // An odd exponent moves one factor of two into the radicand: its first
        // bit pair then starts one column higher. The radicand goes below the
        // remainder field R[111:54], first pair at R[53:52].
        e_sqrt = 1'b1;
        sh_x_d = 1'b0;
        sh_collapse_d = 1'b0;
        sh_cnt_d = e_q[0] ? 7'd58 : 7'd59;
        ret_d = RET_SQRT;
        q_d = '0;
        cnt_d = qbits;
        state_d = ST_RSHIFT;
      end

      ST_SQRT: begin
        // Non-restoring: Pk = 4Pk-1 + pair - (4Q + 1) if Pk-1 >= 0, else
        // 4Pk-1 + pair + (4Q + 3). Root bit k is Pk >= 0.
        a_sel = A_SHL2;
        b_sel = B_QT;
        qt_low = r_q[112] ? 2'b11 : 2'b01;
        inv_b = !r_q[112];
        cin = !r_q[112];
        r_sel = R_SUM;
        cnt_d = cnt_q - 6'd1;
        if (cnt_q == 6'd1) begin
          // Q must still hold the root without its last bit for the fix-up.
          qlast_d = !sum[112];
          state_d = ST_SQRT_FIX;
        end else begin
          q_d = {q_q[54:0], !sum[112]};
        end
      end

      ST_SQRT_FIX: begin
        if (r_q[112]) begin
          b_sel  = B_QT;
          qt_low = 2'b01;
          r_sel  = R_SUM;
        end
        q_d = {q_q[54:0], qlast_q};
        state_d = ST_QFIN;
      end

      ST_QFIN: begin
        rem_nz_d = r_nonzero;
        r_sel = R_CLEAR;
        state_d = ST_QXFER;
      end

      ST_QXFER: begin
        // Quotient or root to R[111:56], the remainder as sticky. Single
        // precision produces 27 bits, at R[82:56].
        b_sel   = B_QT;
        qt_b0   = rem_nz_q;
        r_sel   = R_SUM;
        eq_sel  = EQ_29;
        e_load  = !dec_q.dst_d;
        state_d = ST_BE_NORM;
      end

      ST_I2F_NEG: begin
        if (sr_q) begin
          inv_a = 1'b1;
          cin   = 1'b1;
          r_sel = R_SUM;
        end
        state_d = ST_BE_NORM;
      end

      ST_F2I_RPREP: begin
        round_up_d =
            riscv_pkg::fp_compute_round_up(rm_q, ib_guard, ib_round, ib_sticky, r_q[48], sr_q);
        inexact_d = ib_guard || ib_round || ib_sticky;
        state_d = ST_F2I_ROUND;
      end

      ST_F2I_ROUND: begin
        b_sel   = round_up_q ? B_CONST : B_ZERO;
        k_sel   = K_INT;
        r_sel   = R_SUM;
        state_d = ST_F2I_CHECK;
      end

      ST_F2I_CHECK: begin
        oor_d   = f2i_oor;
        state_d = ST_F2I_NEG;
      end

      ST_F2I_NEG: begin
        if (oor_q) begin
          res_load = 1'b1;
          res_is_fp = 1'b0;
          ir_sel = sr_q ? IR_SATN : IR_SATP;
          flags_d = '0;
          flags_d.nv = 1'b1;
          state_d = ST_DONE;
        end else begin
          if (sr_q && !dec_q.int_u) begin
            // Two's complement of the integer at [111:48]; the bits below
            // are not part of the result.
            inv_a = 1'b1;
            b_sel = B_CONST;
            k_sel = K_INT;
            r_sel = R_SUM;
          end
          state_d = ST_INT_OUT;
        end
      end

      ST_INT_OUT: begin
        res_load  = 1'b1;
        res_is_fp = 1'b0;
        flags_d   = '0;
        unique case (dec_q.cls)
          CL_MVFX: ir_sel = dec_q.dst_d ? IR_R64 : IR_RBOX;
          CL_MVXF: ir_sel = dec_q.int_w ? IR_RW : IR_R64;
          default: begin
            ir_sel = dec_q.int_w ? IR_RW : IR_R64;
            flags_d.nx = inexact_q;
          end
        endcase
        state_d = ST_DONE;
      end

      ST_CMP_SUB: begin
        b_sel = B_X;
        inv_b = 1'b1;
        cin = 1'b1;
        r_sel = R_SUM;
        state_d = ST_CMP_EVAL;
      end

      ST_CMP_EVAL: begin
        mag_lt_d = r_q[112];
        mag_eq_d = !r_nonzero;
        state_d  = ST_CMP_OUT;
      end

      ST_CMP_OUT: begin
        res_load = 1'b1;
        flags_d  = '0;
        if (dec_q.cls == CL_CMP) begin
          res_is_fp = 1'b0;
          ir_sel = IR_BIT;
          unique case (dec_q.fn)
            2'd0: begin
              res_bit = !(ca_q.nan || cb_q.nan) && a_eq_b;
              flags_d.nv = ca_q.snan || cb_q.snan;
            end
            2'd1: begin
              res_bit = !(ca_q.nan || cb_q.nan) && a_lt_b;
              flags_d.nv = ca_q.nan || cb_q.nan;
            end
            default: begin
              res_bit = !(ca_q.nan || cb_q.nan) && (a_lt_b || a_eq_b);
              flags_d.nv = ca_q.nan || cb_q.nan;
            end
          endcase
        end else begin
          flags_d.nv = ca_q.snan || cb_q.snan;
          ld_sel = minmax_pick_b ? SEL_B : SEL_A;
          if (ca_q.nan && cb_q.nan) begin
            fp_sign = 1'b0;
            fe_sel  = FE_ONES;
            ff_sel  = FF_QNAN;
          end else begin
            fp_sign = minmax_pick_b ? cb_q.sign : ca_q.sign;
            fe_sel  = FE_LD;
            ff_sel  = FF_LD;
          end
        end
        state_d = ST_DONE;
      end

      ST_BE_NORM: begin
        if (r_q[112]) begin
          r_sel  = R_SHR1;
          e_cin  = 1'b1;
          e_load = 1'b1;
        end else if (!r_nonzero) begin
          zero_res_d = 1'b1;
          state_d = ST_BE_PACK;
        end else if (!r_q[111] && (e_q > floor_p)) begin
          e_load = 1'b1;
          if (r_top8_zero && ((e_q - 14'sd8) >= floor_p)) begin
            r_sel  = R_SHL8;
            eq_sel = EQ_M8;
          end else begin
            r_sel  = R_SHL1;
            eq_sel = EQ_M1;
          end
        end else begin
          tiny_d = be_tiny;
          if (denorm_diff > 0) begin
            // Subnormal result: shift right to the minimum exponent.
            ep_sel = EP_ZERO;
            eq_sel = EQ_EMIN;
            e_load = 1'b1;
            sh_x_d = 1'b0;
            sh_collapse_d = (denorm_diff >= 14'sd128);
            sh_cnt_d = denorm_diff[6:0];
            ret_d = RET_BE;
            state_d = ST_RSHIFT;
          end else begin
            state_d = ST_BE_RPREP;
          end
        end
      end

      ST_BE_RPREP: begin
        round_up_d =
            riscv_pkg::fp_compute_round_up(rm_q, rb_guard, rb_round, rb_sticky, rb_lsb, sr_q);
        inexact_d = rb_guard || rb_round || rb_sticky;
        state_d = ST_BE_ROUND;
      end

      ST_BE_ROUND: begin
        b_sel   = round_up_q ? B_CONST : B_ZERO;
        k_sel   = dec_q.dst_d ? K_D : K_S;
        r_sel   = R_SUM;
        state_d = ST_BE_CARRY;
      end

      ST_BE_CARRY: begin
        if (r_q[112]) begin
          r_sel  = R_SHR1;
          e_cin  = 1'b1;
          e_load = 1'b1;
        end
        state_d = ST_BE_PACK;
      end

      ST_BE_PACK: begin
        res_load = 1'b1;
        flags_d  = '0;
        if (zero_res_q) begin
          fp_sign = eff_sub_q ? (rm_q == riscv_pkg::FRM_RDN) : sr_q;
          fe_sel  = FE_ZERO;
          ff_sel  = FF_ZERO;
        end else if (e_q > emax_p) begin
          fe_sel = ovf_to_max ? FE_MAXN : FE_ONES;
          ff_sel = ovf_to_max ? FF_ONES : FF_ZERO;
          flags_d.of = 1'b1;
          flags_d.nx = 1'b1;
        end else begin
          flags_d.uf = tiny_q && inexact_q;
          flags_d.nx = inexact_q;
        end
        state_d = ST_DONE;
      end

      ST_DONE: state_d = ST_IDLE;

      default: state_d = ST_IDLE;
    endcase

    if (i_kill && (state_q != ST_IDLE)) state_d = ST_IDLE;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) state_q <= ST_IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge i_clk) begin
    if (i_start && (state_q == ST_IDLE)) begin
      dec_q <= decode_op(i_op);
      rm_q  <= i_rm;
      opa_q <= i_src1;
      opb_q <= i_src2;
      opc_q <= i_src3;
    end
    if (state_q == ST_DEC1) begin
      ca_q <= classify(opa_q, dec_q.src_d);
      cb_q <= classify(opb_q, dec_q.src_d);
      cc_q <= classify(opc_q, dec_q.src_d);
      ea_q <= unbiased_exp(opa_q, dec_q.src_d);
      eb_q <= unbiased_exp(opb_q, dec_q.src_d);
      ec_q <= unbiased_exp(opc_q, dec_q.src_d);
      f2i_over_q <= (unbiased_exp(opa_q, dec_q.src_d) > f2i_limit);
      f2i_edge_q <= (unbiased_exp(opa_q, dec_q.src_d) == f2i_limit);
      int_zero_q <= (int64 == '0);
    end
    r_q <= r_d;
    x_q <= x_d;
    q_q <= q_d;
    e_q <= e_d;
    ex_q <= ex_d;
    cnt_q <= cnt_d;
    sh_cnt_q <= sh_cnt_d;
    sh_x_q <= sh_x_d;
    sh_collapse_q <= sh_collapse_d;
    ret_q <= ret_d;
    sr_q <= sr_d;
    sx_q <= sx_d;
    zr_q <= zr_d;
    zx_q <= zx_d;
    eff_sub_q <= eff_sub_d;
    first_q <= first_d;
    qlast_q <= qlast_d;
    rem_nz_q <= rem_nz_d;
    tiny_q <= tiny_d;
    inexact_q <= inexact_d;
    round_up_q <= round_up_d;
    oor_q <= oor_d;
    zero_res_q <= zero_res_d;
    mag_lt_q <= mag_lt_d;
    mag_eq_q <= mag_eq_d;
    res_q <= res_d;
    flags_q <= flags_d;
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (i_rst_n && i_start && (state_q != ST_IDLE)) begin
      $error("fp_engine: start while busy (op %0d)", i_op);
    end
  end
`endif

endmodule : fp_engine
