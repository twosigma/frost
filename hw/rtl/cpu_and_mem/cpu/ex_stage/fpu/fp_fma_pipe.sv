// Copyright (c) 2026 John Goodacre.

/*
  Pipelined F/D multiply-add: FADD, FSUB, FMUL, FMADD, FMSUB, FNMADD and
  FNMSUB at single and double precision, one operation per cycle, fixed
  latency riscv_pkg::FpPipeDepth (7). Inputs are sampled every cycle; o_result
  and o_flags present the operation sampled FpPipeDepth cycles earlier.
  i_valid only drives o_valid (for harnesses); the datapath runs freely.

  Every operation is a fused a*b + c with one rounding: FADD/FSUB take b = 1.0,
  FMUL has no addend (an exact zero takes the product's sign). Single precision
  runs left-aligned in the 53-bit significand ({hidden, fraction, 29 zeros}),
  with its own bias, exponent range and rounding column. An improperly
  NaN-boxed single operand reads as the canonical NaN.

  Significands M (53 bits) have value M * 2^(E-52); E is emin for zero and
  subnormal operands. A 217-bit window holds:
    P  = Ma * Mb at [160:55]; columns below 55 keep addend bits exact;
    C  = Mc at [215:163] shifted right by shamt = 56 + Ea + Eb - Ec, clamped at
         0 (then the product lies two columns clear below C) and forced to 0
         for a zero product. Addend bits below column 0 fold into column 0
         (sticky). They do so only while C < 2^53 in window units and a
         nonzero product is at least 2^55, so the sum keeps its round column
         above column 0.
  Column 216 has exponent E_top = Ea + Eb + 57 (or Ec + 1 when clamped), and
  E_top >= emin + 1, so normalization is a left shift only. It is limited to
  E_top - emin (subnormal results) by a barrier bit OR-ed into the
  leading-zero count. With an effective subtraction both P - C and C - P are
  formed; the sign of P - C selects, so no negate stage follows.

  Stages (X0 is the sampling cycle; Rn is the register visible in cycle n):
    X0  unpack, classify, decode                       -> R1
    X1  significand tiles (DSP), exponents, shamt,
        trailing zeros of Mc, special results          -> R2
    X2  partial-product add, addend alignment, barrier -> R3
    X3  P +/- C and C - P (3:2 compression + carry)    -> R4
    X4  leading-zero counts (barrier), trailing zeros  -> R5
    X5  normalize, exponent field, sticky compares     -> R6
    X6  round, pack, overflow, tininess, specials      -> R7 (o_result)
  Underflow uses tininess after rounding, as RISC-V requires.
*/
module fp_fma_pipe (
    input logic i_clk,
    input logic i_rst_n,

    input logic                        i_valid,
    input riscv_pkg::instr_op_e        i_op,
    input logic                 [ 2:0] i_rm,
    input logic                 [63:0] i_src1,
    input logic                 [63:0] i_src2,
    input logic                 [63:0] i_src3,

    output logic                        o_valid,
    output logic                 [63:0] o_result,
    output riscv_pkg::fp_flags_t        o_flags
);

  localparam int unsigned Depth = riscv_pkg::FpPipeDepth;
  localparam int unsigned W = 217;  // window columns [216:0]
  localparam int unsigned ExpW = 14;  // signed exponent arithmetic

  // ===========================================================================
  // X0: decode and unpack
  // ===========================================================================
  logic x0_d, x0_add, x0_mul, x0_neg_prod, x0_neg_c;
  always_comb begin
    x0_d        = 1'b0;
    x0_add      = 1'b0;
    x0_mul      = 1'b0;
    x0_neg_prod = 1'b0;
    x0_neg_c    = 1'b0;
    case (i_op)
      riscv_pkg::FADD_S:   x0_add = 1'b1;
      riscv_pkg::FSUB_S: begin
        x0_add   = 1'b1;
        x0_neg_c = 1'b1;
      end
      riscv_pkg::FMUL_S:   x0_mul = 1'b1;
      riscv_pkg::FMSUB_S:  x0_neg_c = 1'b1;
      riscv_pkg::FNMSUB_S: x0_neg_prod = 1'b1;
      riscv_pkg::FNMADD_S: begin
        x0_neg_prod = 1'b1;
        x0_neg_c    = 1'b1;
      end
      riscv_pkg::FADD_D: begin
        x0_d   = 1'b1;
        x0_add = 1'b1;
      end
      riscv_pkg::FSUB_D: begin
        x0_d     = 1'b1;
        x0_add   = 1'b1;
        x0_neg_c = 1'b1;
      end
      riscv_pkg::FMUL_D: begin
        x0_d   = 1'b1;
        x0_mul = 1'b1;
      end
      riscv_pkg::FMADD_D:  x0_d = 1'b1;
      riscv_pkg::FMSUB_D: begin
        x0_d     = 1'b1;
        x0_neg_c = 1'b1;
      end
      riscv_pkg::FNMSUB_D: begin
        x0_d        = 1'b1;
        x0_neg_prod = 1'b1;
      end
      riscv_pkg::FNMADD_D: begin
        x0_d        = 1'b1;
        x0_neg_prod = 1'b1;
        x0_neg_c    = 1'b1;
      end
      default:             ;  // FMADD_S
    endcase
  end

  typedef struct packed {
    logic        sign;
    logic [10:0] expf;       // biased exponent field (single: low 8 bits)
    logic [51:0] frac;       // fraction, single left-aligned
    logic        exp_zero;
    logic        exp_max;
    logic        frac_zero;
  } unpacked_t;

  function automatic unpacked_t unpack(input logic [63:0] v, input logic is_d);
    unpacked_t u;
    logic box_ok;
    begin
      box_ok = &v[63:32];
      if (is_d) begin
        u.sign = v[63];
        u.expf = v[62:52];
        u.frac = v[51:0];
        u.exp_max = &v[62:52];
      end else begin
        u.sign = box_ok && v[31];
        u.expf = box_ok ? {3'b0, v[30:23]} : 11'h0FF;
        u.frac = box_ok ? {v[22:0], 29'b0} : {1'b1, 51'b0};
        u.exp_max = !box_ok || (&v[30:23]);
      end
      u.exp_zero = (u.expf == '0);
      u.frac_zero = (u.frac == '0);
      unpack = u;
    end
  endfunction

  unpacked_t x0_a, x0_b, x0_c;
  always_comb begin
    x0_a = unpack(i_src1, x0_d);
    if (x0_add) begin
      // b = 1.0
      x0_b.sign = 1'b0;
      x0_b.expf = x0_d ? 11'd1023 : 11'd127;
      x0_b.frac = '0;
      x0_b.exp_zero = 1'b0;
      x0_b.exp_max = 1'b0;
      x0_b.frac_zero = 1'b1;
    end else begin
      x0_b = unpack(i_src2, x0_d);
    end
    if (x0_mul) begin
      // No addend: a zero of the product's sign (fixed up at the end).
      x0_c.sign = 1'b0;
      x0_c.expf = '0;
      x0_c.frac = '0;
      x0_c.exp_zero = 1'b1;
      x0_c.exp_max = 1'b0;
      x0_c.frac_zero = 1'b1;
    end else begin
      x0_c = unpack(x0_add ? i_src2 : i_src3, x0_d);
    end
  end

  // R1
  unpacked_t r1_a, r1_b, r1_c;
  logic r1_d, r1_mul, r1_neg_prod, r1_neg_c;
  logic [2:0] r1_rm;
  logic [52:0] r1_ma, r1_mb;  // DSP operand registers
  always_ff @(posedge i_clk) begin
    r1_a        <= x0_a;
    r1_b        <= x0_b;
    r1_c        <= x0_c;
    r1_d        <= x0_d;
    r1_mul      <= x0_mul;
    r1_neg_prod <= x0_neg_prod;
    r1_neg_c    <= x0_neg_c;
    r1_rm       <= i_rm;
    r1_ma       <= {!x0_a.exp_zero, x0_a.frac};
    r1_mb       <= {!x0_b.exp_zero, x0_b.frac};
  end

  // ===========================================================================
  // X1: significand tiles, exponents, special results
  // ===========================================================================
  // 53 x 53 as four tiles of the integer multiplier's 27 x 35 shape:
  //   t00 = a[26:0]  * b[34:0]  at 0     t01 = a[26:0]  * b[52:35] at 35
  //   t10 = a[52:27] * b[34:0]  at 27    t11 = a[52:27] * b[52:35] at 62
  (* use_dsp = "yes" *)logic [61:0] x1_t00;
  (* use_dsp = "yes" *)logic [44:0] x1_t01;
  (* use_dsp = "yes" *)logic [60:0] x1_t10;
  (* use_dsp = "yes" *)logic [43:0] x1_t11;
  assign x1_t00 = 62'(r1_ma[26:0] * r1_mb[34:0]);
  assign x1_t01 = 45'(r1_ma[26:0] * r1_mb[52:35]);
  assign x1_t10 = 61'(r1_ma[52:27] * r1_mb[34:0]);
  assign x1_t11 = 44'(r1_ma[52:27] * r1_mb[52:35]);

  // Biased exponents with subnormals (and zero) at 1.
  logic [10:0] x1_eba, x1_ebb, x1_ebc;
  assign x1_eba = r1_a.exp_zero ? 11'd1 : r1_a.expf;
  assign x1_ebb = r1_b.exp_zero ? 11'd1 : r1_b.expf;
  assign x1_ebc = r1_c.exp_zero ? 11'd1 : r1_c.expf;

  logic [ExpW-1:0] x1_bias;
  assign x1_bias = r1_d ? ExpW'(1023) : ExpW'(127);

  logic signed [ExpW-1:0] x1_shamt_raw;
  logic [ExpW-1:0] x1_bt_prod, x1_bt_c;
  // shamt = 56 + Ea + Eb - Ec, with E = EB - bias.
  assign x1_shamt_raw = $signed(
      ExpW'(x1_eba) + ExpW'(x1_ebb) - ExpW'(x1_ebc) - x1_bias + ExpW'(56)
  );
  // Biased exponent of window column 216.
  assign x1_bt_prod = ExpW'(x1_eba) + ExpW'(x1_ebb) - x1_bias + ExpW'(57);
  assign x1_bt_c = ExpW'(x1_ebc) + ExpW'(1);

  logic x1_a_zero, x1_b_zero, x1_c_zero, x1_prod_zero;
  logic x1_a_inf, x1_b_inf, x1_c_inf;
  logic x1_a_nan, x1_b_nan, x1_c_nan, x1_any_snan;
  assign x1_a_zero = r1_a.exp_zero && r1_a.frac_zero;
  assign x1_b_zero = r1_b.exp_zero && r1_b.frac_zero;
  assign x1_c_zero = r1_c.exp_zero && r1_c.frac_zero;
  assign x1_prod_zero = x1_a_zero || x1_b_zero;
  assign x1_a_inf = r1_a.exp_max && r1_a.frac_zero;
  assign x1_b_inf = r1_b.exp_max && r1_b.frac_zero;
  assign x1_c_inf = r1_c.exp_max && r1_c.frac_zero;
  assign x1_a_nan = r1_a.exp_max && !r1_a.frac_zero;
  assign x1_b_nan = r1_b.exp_max && !r1_b.frac_zero;
  assign x1_c_nan = r1_c.exp_max && !r1_c.frac_zero;
  // The quiet bit is fraction bit 51 at both precisions (single left-aligned).
  assign x1_any_snan = (x1_a_nan && !r1_a.frac[51]) || (x1_b_nan && !r1_b.frac[51]) ||
      (x1_c_nan && !r1_c.frac[51]);

  logic x1_sp, x1_sc, x1_sub;
  assign x1_sp  = r1_a.sign ^ r1_b.sign ^ r1_neg_prod;
  // FMUL: the absent addend takes the product's sign.
  assign x1_sc  = r1_mul ? x1_sp : (r1_c.sign ^ r1_neg_c);
  assign x1_sub = x1_sp ^ x1_sc;

  logic x1_inv_mul, x1_p_inf, x1_inv_add, x1_res_nan, x1_res_inf, x1_res_inf_sign, x1_nv;
  assign x1_inv_mul = (x1_a_inf && x1_b_zero) || (x1_a_zero && x1_b_inf);
  assign x1_p_inf = (x1_a_inf || x1_b_inf) && !x1_inv_mul;
  assign x1_inv_add = x1_p_inf && x1_c_inf && x1_sub;
  assign x1_res_nan = x1_a_nan || x1_b_nan || x1_c_nan || x1_inv_mul || x1_inv_add;
  assign x1_nv = x1_any_snan || x1_inv_mul || (x1_inv_add && !x1_a_nan && !x1_b_nan && !x1_c_nan);
  assign x1_res_inf = !x1_res_nan && (x1_p_inf || x1_c_inf);
  assign x1_res_inf_sign = x1_p_inf ? x1_sp : x1_sc;

  // Clamp and saturate the alignment; a zero product leaves C at the top.
  logic x1_clamp;
  logic [7:0] x1_shamt;
  assign x1_clamp = x1_prod_zero || x1_shamt_raw[ExpW-1];
  assign x1_shamt = x1_clamp ? 8'd0 : ((x1_shamt_raw > $signed(
      ExpW'(255)
  )) ? 8'd255 : x1_shamt_raw[7:0]);

  // Trailing zeros of Mc (53 when zero).
  logic [52:0] x1_mc;
  logic [ 5:0] x1_mc_tz;
  assign x1_mc = {!r1_c.exp_zero, r1_c.frac};
  always_comb begin
    x1_mc_tz = 6'd53;
    for (int i = 52; i >= 0; i--) if (x1_mc[i]) x1_mc_tz = 6'(i);
  end

  // R2
  logic [61:0] r2_t00;
  logic [44:0] r2_t01;
  logic [60:0] r2_t10;
  logic [43:0] r2_t11;
  logic [52:0] r2_mc;
  logic [5:0] r2_mc_tz;
  logic [7:0] r2_shamt;
  logic [ExpW-1:0] r2_bt;
  logic r2_d, r2_sp, r2_sc, r2_sub, r2_prod_zero, r2_c_zero;
  logic r2_res_nan, r2_res_inf, r2_res_inf_sign, r2_nv;
  logic [2:0] r2_rm;
  always_ff @(posedge i_clk) begin
    r2_t00          <= x1_t00;
    r2_t01          <= x1_t01;
    r2_t10          <= x1_t10;
    r2_t11          <= x1_t11;
    r2_mc           <= x1_mc;
    r2_mc_tz        <= x1_mc_tz;
    r2_shamt        <= x1_shamt;
    r2_bt           <= x1_clamp ? x1_bt_c : x1_bt_prod;
    r2_d            <= r1_d;
    r2_sp           <= x1_sp;
    r2_sc           <= x1_sc;
    r2_sub          <= x1_sub;
    r2_prod_zero    <= x1_prod_zero;
    r2_c_zero       <= x1_c_zero;
    r2_res_nan      <= x1_res_nan;
    r2_res_inf      <= x1_res_inf;
    r2_res_inf_sign <= x1_res_inf_sign;
    r2_nv           <= x1_nv;
    r2_rm           <= r1_rm;
  end

  // ===========================================================================
  // X2: partial products, addend alignment, normalization barrier
  // ===========================================================================
  logic [105:0] x2_pa, x2_pb;
  assign x2_pa = {r2_t11, r2_t00};
  assign x2_pb = (106'(r2_t01) << 35) + (106'(r2_t10) << 27);

  // C at [215:163], shifted right; bits below column 0 fold into column 0.
  logic [W-1:0] x2_c_full, x2_c_shift, x2_cw;
  logic x2_c_low;
  assign x2_c_full = {1'b0, r2_mc, 163'b0};
  assign x2_c_shift = x2_c_full >> r2_shamt;
  // Mc[i] lands at column 163 + i - shamt: column 0 or below iff i <= shamt - 163.
  assign x2_c_low = (r2_mc_tz != 6'd53) && (11'(r2_shamt) >= 11'(r2_mc_tz) + 11'd163);
  assign x2_cw = {x2_c_shift[W-1:1], x2_c_low};

  // Normalization limit lz_lim = E_top - emin = BT - 1 (biased emin is 1).
  logic [ExpW-1:0] x2_lz_lim;
  logic [W-1:0] x2_barrier;
  assign x2_lz_lim = r2_bt - ExpW'(1);
  always_comb begin
    x2_barrier = '0;
    if (x2_lz_lim < ExpW'(W)) x2_barrier[8'(W-1)-x2_lz_lim[7:0]] = 1'b1;
  end

  // R3
  logic [105:0] r3_pa, r3_pb;
  logic [W-1:0] r3_cw, r3_barrier;
  logic [ExpW-1:0] r3_bt;
  logic r3_d, r3_sp, r3_sc, r3_sub, r3_both_zero;
  logic r3_res_nan, r3_res_inf, r3_res_inf_sign, r3_nv;
  logic [2:0] r3_rm;
  always_ff @(posedge i_clk) begin
    r3_pa           <= x2_pa;
    r3_pb           <= x2_pb;
    r3_cw           <= x2_cw;
    r3_barrier      <= x2_barrier;
    r3_bt           <= r2_bt;
    r3_d            <= r2_d;
    r3_sp           <= r2_sp;
    r3_sc           <= r2_sc;
    r3_sub          <= r2_sub;
    r3_both_zero    <= r2_prod_zero && r2_c_zero;
    r3_res_nan      <= r2_res_nan;
    r3_res_inf      <= r2_res_inf;
    r3_res_inf_sign <= r2_res_inf_sign;
    r3_nv           <= r2_nv;
    r3_rm           <= r2_rm;
  end

  // ===========================================================================
  // X3: S1 = P + C or P - C, S2 = C - P (218-bit two's complement)
  // ===========================================================================
  // Each sum is one 3:2 compression folded into the adder LUTs plus a carry
  // chain. S2 = C + ~pA + ~pB + 2: the compressed carry vector's free bit 0
  // and the carry-in supply the 2.
  localparam int unsigned SW = W + 1;
  logic [SW-1:0] x3_pa, x3_pb, x3_c1, x3_npa, x3_npb, x3_c2;
  assign x3_pa  = SW'(r3_pa) << 55;
  assign x3_pb  = SW'(r3_pb) << 55;
  assign x3_c1  = r3_sub ? ~(SW'(r3_cw)) : SW'(r3_cw);
  assign x3_npa = ~x3_pa;
  assign x3_npb = ~x3_pb;
  assign x3_c2  = SW'(r3_cw);

  // Sum and shifted majority of three vectors; s2's carry vector takes 1 at
  // bit 0.
  logic [SW-1:0] x3_s1_x, x3_s1_y, x3_s2_x, x3_s2_y, x3_s1, x3_s2;
  assign x3_s1_x = x3_pa ^ x3_pb ^ x3_c1;
  assign x3_s1_y = {
    (x3_pa[SW-2:0] & x3_pb[SW-2:0]) | (x3_pa[SW-2:0] & x3_c1[SW-2:0]) |
                    (x3_pb[SW-2:0] & x3_c1[SW-2:0]),
    1'b0
  };
  assign x3_s2_x = x3_npa ^ x3_npb ^ x3_c2;
  assign x3_s2_y = {
    (x3_npa[SW-2:0] & x3_npb[SW-2:0]) | (x3_npa[SW-2:0] & x3_c2[SW-2:0]) |
                    (x3_npb[SW-2:0] & x3_c2[SW-2:0]),
    1'b1
  };
  assign x3_s1 = x3_s1_x + x3_s1_y + SW'(r3_sub);
  assign x3_s2 = x3_s2_x + x3_s2_y + SW'(1);

  // R4
  logic [SW-1:0] r4_s1, r4_s2;
  logic [W-1:0] r4_barrier;
  logic [ExpW-1:0] r4_bt;
  logic r4_d, r4_sp, r4_sc, r4_sub, r4_both_zero;
  logic r4_res_nan, r4_res_inf, r4_res_inf_sign, r4_nv;
  logic [2:0] r4_rm;
  always_ff @(posedge i_clk) begin
    r4_s1           <= x3_s1;
    r4_s2           <= x3_s2;
    r4_barrier      <= r3_barrier;
    r4_bt           <= r3_bt;
    r4_d            <= r3_d;
    r4_sp           <= r3_sp;
    r4_sc           <= r3_sc;
    r4_sub          <= r3_sub;
    r4_both_zero    <= r3_both_zero;
    r4_res_nan      <= r3_res_nan;
    r4_res_inf      <= r3_res_inf;
    r4_res_inf_sign <= r3_res_inf_sign;
    r4_nv           <= r3_nv;
    r4_rm           <= r3_rm;
  end

  // ===========================================================================
  // X4: leading zeros (limited by the barrier), trailing zeros, sign select
  // ===========================================================================
  localparam int unsigned CntW = 9;  // counts 0..256
  logic x4_neg;
  assign x4_neg = r4_sub && r4_s1[SW-1];

  logic [CntW-1:0] x4_lz1, x4_lz2, x4_tz;
  fp_pipe_lzc #(
      .WIDTH(W)
  ) u_lzc1 (
      .i_value(r4_s1[W-1:0] | r4_barrier),
      .o_count(x4_lz1)
  );
  fp_pipe_lzc #(
      .WIDTH(W)
  ) u_lzc2 (
      .i_value(r4_s2[W-1:0] | r4_barrier),
      .o_count(x4_lz2)
  );
  // Trailing zeros of S1 equal those of -S1.
  logic [W-1:0] x4_s1_rev;
  always_comb for (int i = 0; i < W; i++) x4_s1_rev[i] = r4_s1[W-1-i];
  fp_pipe_lzc #(
      .WIDTH(W)
  ) u_tzc (
      .i_value(x4_s1_rev),
      .o_count(x4_tz)
  );

  // R5
  logic [W-1:0] r5_mag;
  logic [CntW-1:0] r5_lz, r5_tz;
  logic r5_zero;
  logic [ExpW-1:0] r5_bt;
  logic r5_d, r5_sign, r5_zero_sign;
  logic r5_res_nan, r5_res_inf, r5_res_inf_sign, r5_nv;
  logic [2:0] r5_rm;
  always_ff @(posedge i_clk) begin
    r5_mag          <= x4_neg ? r4_s2[W-1:0] : r4_s1[W-1:0];
    r5_lz           <= x4_neg ? x4_lz2 : x4_lz1;
    r5_tz           <= x4_tz;
    r5_zero         <= (x4_tz == CntW'(W));
    r5_bt           <= r4_bt;
    r5_d            <= r4_d;
    // A cancelled sum takes the addend's sign.
    r5_sign         <= r4_sp ^ x4_neg;
    // Exact zero: like-signed zeros keep their sign, otherwise +0 (-0 in RDN).
    r5_zero_sign    <= (r4_both_zero && !r4_sub) ? r4_sp : (r4_rm == riscv_pkg::FRM_RDN);
    r5_res_nan      <= r4_res_nan;
    r5_res_inf      <= r4_res_inf;
    r5_res_inf_sign <= r4_res_inf_sign;
    r5_nv           <= r4_nv;
    r5_rm           <= r4_rm;
  end

  // ===========================================================================
  // X5: normalize; exponent field; sticky by trailing-zero position
  // ===========================================================================
  logic [W-1:0] x5_shifted_full;
  logic [ 55:0] x5_top;  // columns [216:161] after the shift
  assign x5_shifted_full = r5_mag << r5_lz;
  assign x5_top = x5_shifted_full[W-1-:56];

  // Lowest set column after the shift.
  logic [CntW:0] x5_low;
  assign x5_low = {1'b0, r5_tz} + {1'b0, r5_lz};

  // R6
  logic [55:0] r6_top;
  logic [ExpW-1:0] r6_ebase;  // exponent field before the hidden bit and rounding
  logic r6_stk_d, r6_xstk_d, r6_stk_s, r6_xstk_s;
  logic r6_zero, r6_d, r6_sign, r6_zero_sign;
  logic r6_res_nan, r6_res_inf, r6_res_inf_sign, r6_nv;
  logic [2:0] r6_rm;
  always_ff @(posedge i_clk) begin
    r6_top          <= x5_top;
    r6_ebase        <= r5_bt - ExpW'(1) - ExpW'(r5_lz);
    // Double: round column 163, sticky below; single: round column 192.
    r6_stk_d        <= !r5_zero && (x5_low <= 10'd162);
    r6_xstk_d       <= !r5_zero && (x5_low <= 10'd161);
    r6_stk_s        <= !r5_zero && (x5_low <= 10'd191);
    r6_xstk_s       <= !r5_zero && (x5_low <= 10'd190);
    r6_zero         <= r5_zero;
    r6_d            <= r5_d;
    r6_sign         <= r5_sign;
    r6_zero_sign    <= r5_zero_sign;
    r6_res_nan      <= r5_res_nan;
    r6_res_inf      <= r5_res_inf;
    r6_res_inf_sign <= r5_res_inf_sign;
    r6_nv           <= r5_nv;
    r6_rm           <= r5_rm;
  end

  // ===========================================================================
  // X6: round and pack
  // ===========================================================================
  function automatic logic round_up(input logic [2:0] rm, input logic sign, input logic lsb,
                                    input logic rnd, input logic stk);
    case (rm)
      riscv_pkg::FRM_RNE: round_up = rnd && (stk || lsb);
      riscv_pkg::FRM_RTZ: round_up = 1'b0;
      riscv_pkg::FRM_RDN: round_up = sign && (rnd || stk);
      riscv_pkg::FRM_RUP: round_up = !sign && (rnd || stk);
      riscv_pkg::FRM_RMM: round_up = rnd;
      default: round_up = 1'b0;
    endcase
  endfunction

  // Significand, round and extended-round bits per precision.
  logic [52:0] x6_md;
  logic x6_rnd_d, x6_xrnd_d;
  logic [23:0] x6_ms;
  logic x6_rnd_s, x6_xrnd_s;
  assign x6_md = r6_top[55:3];
  assign x6_rnd_d = r6_top[2];
  assign x6_xrnd_d = r6_top[1];
  assign x6_ms = r6_top[55:32];
  assign x6_rnd_s = r6_top[31];
  assign x6_xrnd_s = r6_top[30];

  logic x6_inc_d, x6_inc_s, x6_xinc_d, x6_xinc_s;
  assign x6_inc_d  = round_up(r6_rm, r6_sign, x6_md[0], x6_rnd_d, r6_stk_d);
  assign x6_inc_s  = round_up(r6_rm, r6_sign, x6_ms[0], x6_rnd_s, r6_stk_s);
  // Rounding at full precision one binade below emin (tininess after rounding).
  assign x6_xinc_d = round_up(r6_rm, r6_sign, x6_rnd_d, x6_xrnd_d, r6_xstk_d);
  assign x6_xinc_s = round_up(r6_rm, r6_sign, x6_rnd_s, x6_xrnd_s, r6_xstk_s);

  // {exponent field, fraction} + hidden bit at the exponent LSB + increment.
  logic [ExpW+52-1:0] x6_pack_d;
  logic [ExpW+23-1:0] x6_pack_s;
  assign x6_pack_d = {r6_ebase, x6_md[51:0]} + ((ExpW + 52)'(x6_md[52]) << 52) +
      (ExpW + 52)'(x6_inc_d);
  assign x6_pack_s = {r6_ebase, x6_ms[22:0]} + ((ExpW + 23)'(x6_ms[23]) << 23) +
      (ExpW + 23)'(x6_inc_s);

  logic x6_of_d, x6_of_s, x6_tiny_d, x6_tiny_s, x6_nx_d, x6_nx_s;
  assign x6_of_d   = x6_pack_d[ExpW+52-1:52] >= ExpW'(2047);
  assign x6_of_s   = x6_pack_s[ExpW+23-1:23] >= ExpW'(255);
  assign x6_nx_d   = x6_rnd_d || r6_stk_d;
  assign x6_nx_s   = x6_rnd_s || r6_stk_s;
  assign x6_tiny_d = !x6_md[52] && !((&x6_md[51:0]) && x6_rnd_d && x6_xinc_d);
  assign x6_tiny_s = !x6_ms[23] && !((&x6_ms[22:0]) && x6_rnd_s && x6_xinc_s);

  logic x6_of, x6_tiny, x6_nx;
  assign x6_of   = r6_d ? x6_of_d : x6_of_s;
  assign x6_tiny = r6_d ? x6_tiny_d : x6_tiny_s;
  assign x6_nx   = r6_d ? x6_nx_d : x6_nx_s;

  // Overflow: infinity, or the largest finite magnitude when the mode
  // rounds toward zero for this sign.
  logic x6_of_to_max;
  always_comb begin
    case (r6_rm)
      riscv_pkg::FRM_RTZ: x6_of_to_max = 1'b1;
      riscv_pkg::FRM_RDN: x6_of_to_max = !r6_sign;
      riscv_pkg::FRM_RUP: x6_of_to_max = r6_sign;
      default: x6_of_to_max = 1'b0;
    endcase
  end

  logic [63:0] x6_result;
  riscv_pkg::fp_flags_t x6_flags;
  always_comb begin
    x6_flags = '0;
    if (r6_res_nan) begin
      x6_result   = r6_d ? riscv_pkg::FpCanonicalNan64 : {32'hFFFF_FFFF, riscv_pkg::FpCanonicalNan};
      x6_flags.nv = r6_nv;
    end else if (r6_res_inf) begin
      x6_result = r6_d ? {r6_res_inf_sign, 11'h7FF, 52'b0} :
          {32'hFFFF_FFFF, r6_res_inf_sign, 8'hFF, 23'b0};
    end else if (r6_zero) begin
      x6_result = r6_d ? {r6_zero_sign, 63'b0} : {32'hFFFF_FFFF, r6_zero_sign, 31'b0};
    end else if (x6_of) begin
      x6_flags.of = 1'b1;
      x6_flags.nx = 1'b1;
      if (r6_d)
        x6_result = x6_of_to_max ? {r6_sign, 11'h7FE, {52{1'b1}}} : {r6_sign, 11'h7FF, 52'b0};
      else
        x6_result = x6_of_to_max ? {32'hFFFF_FFFF, r6_sign, 8'hFE, {23{1'b1}}} :
            {32'hFFFF_FFFF, r6_sign, 8'hFF, 23'b0};
    end else begin
      x6_flags.nx = x6_nx;
      x6_flags.uf = x6_tiny && x6_nx;
      x6_result   = r6_d ? {r6_sign, x6_pack_d[62:0]} : {32'hFFFF_FFFF, r6_sign, x6_pack_s[30:0]};
    end
  end

  // R7 (tail)
  logic [63:0] r7_result;
  riscv_pkg::fp_flags_t r7_flags;
  always_ff @(posedge i_clk) begin
    r7_result <= x6_result;
    r7_flags  <= x6_flags;
  end

`ifdef FP_FMA_PIPE_ABSTRACT
  // Formal models of the back end (tomasulo_wrapper.sby): arbitrary results
  // with the real latency; fp_fma_pipe_equiv covers the arithmetic.
  (* anyseq *)logic [63:0] f_result;
  (* anyseq *)logic [ 4:0] f_flags;
  assign o_result = f_result;
  assign o_flags  = riscv_pkg::fp_flags_t'(f_flags);
  logic unused_datapath;
  assign unused_datapath = ^{r7_result, r7_flags};
`else
  assign o_result = r7_result;
  assign o_flags  = r7_flags;
`endif

  // Valid chain, for harnesses and the shim's consistency check.
  logic [Depth-1:0] valid_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) valid_q <= '0;
    else valid_q <= {valid_q[Depth-2:0], i_valid};
  end
  assign o_valid = valid_q[Depth-1];

  // Bits the datapath reads elsewhere or never needs: column 0 of the shifted
  // addend (replaced by the folded sticky), S2's sign, the addend sign after
  // X3, the shifted columns below the 56 kept, and the lowest kept column.
  logic unused_bits;
  assign unused_bits = ^{x2_c_shift[0], r4_s2[SW-1], r4_sc, x5_shifted_full[W-57:0], r6_top[0]};

endmodule : fp_fma_pipe
