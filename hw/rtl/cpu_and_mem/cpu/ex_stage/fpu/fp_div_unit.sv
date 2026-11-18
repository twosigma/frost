// Copyright (c) 2026 John Goodacre.

/*
  FDIV.S and FDIV.D, one operation at a time, radix 16 (four quotient bits
  per cycle).

  The interface follows fp_engine: i_start is sampled while o_idle is high,
  o_done pulses for one cycle with the result (single NaN-boxed) and flags,
  and i_kill returns the unit to idle on the next cycle.

  States (cycles after the start sample):
    UNPACK  classify; special results (NaN, infinity, zero, division by zero)
            go straight to ROUND; leading zeros of subnormal significands
    NORM    normalize subnormal significands (only with a subnormal operand)
    SETUP   D = 2 * Mb and its multiples 2D..15D (one level of three-input
            adds), remainder R = Ma (R < D)
    DIV     n steps: the fifteen remainders 16R - mD (m = 1..15) in parallel;
            the digit q is the number that are not negative, R' = 16R - qD.
            n = 7 (single, 28 quotient bits) or 14 (double, 56 bits).
    POST    normalize the quotient by one column, round and sticky bits,
            tininess, and the right shift of a subnormal result
    ROUND   round, pack, overflow, tininess after rounding, flags
    DONE    o_done
  Latency for normal operands: 12 cycles single, 19 double (start sample to
  DONE).
*/
module fp_div_unit (
    input logic i_clk,
    input logic i_rst_n,

    input logic                        i_start,
    input riscv_pkg::instr_op_e        i_op,
    input logic                 [ 2:0] i_rm,
    input logic                 [63:0] i_src1,
    input logic                 [63:0] i_src2,
    input logic                        i_kill,

    output logic                        o_idle,
    output logic                        o_done,
    output logic                 [63:0] o_result,
    output riscv_pkg::fp_flags_t        o_flags
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_UNPACK,
    S_NORM,
    S_SETUP,
    S_DIV,
    S_POST,
    S_ROUND,
    S_DONE
  } state_e;
  state_e state;

  localparam int unsigned RW = 59;  // remainder and multiple width (16R < 16D < 2^59)
  localparam int unsigned EW = 14;  // signed biased exponent

  // ===========================================================================
  // Operands sampled at start
  // ===========================================================================
  logic [63:0] a_q, b_q;
  logic is_d, sign_q;
  logic [2:0] rm_q;

  // ===========================================================================
  // UNPACK
  // ===========================================================================
  logic box_a, box_b;
  logic [10:0] ea_f, eb_f;
  logic [51:0] fa, fb;
  always_comb begin
    box_a = &a_q[63:32];
    box_b = &b_q[63:32];
    if (is_d) begin
      ea_f = a_q[62:52];
      eb_f = b_q[62:52];
      fa   = a_q[51:0];
      fb   = b_q[51:0];
    end else begin
      ea_f = box_a ? {3'b0, a_q[30:23]} : 11'h0FF;
      eb_f = box_b ? {3'b0, b_q[30:23]} : 11'h0FF;
      fa   = box_a ? {a_q[22:0], 29'b0} : {1'b1, 51'b0};
      fb   = box_b ? {b_q[22:0], 29'b0} : {1'b1, 51'b0};
    end
  end

  logic [10:0] emax_f;
  assign emax_f = is_d ? 11'h7FF : 11'h0FF;
  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan, a_snan, b_snan, a_sub, b_sub;
  assign a_zero = (ea_f == '0) && (fa == '0);
  assign b_zero = (eb_f == '0) && (fb == '0);
  assign a_sub  = (ea_f == '0) && (fa != '0);
  assign b_sub  = (eb_f == '0) && (fb != '0);
  assign a_inf  = (ea_f == emax_f) && (fa == '0);
  assign b_inf  = (eb_f == emax_f) && (fb == '0);
  assign a_nan  = (ea_f == emax_f) && (fa != '0);
  assign b_nan  = (eb_f == emax_f) && (fb != '0);
  assign a_snan = a_nan && !fa[51];
  assign b_snan = b_nan && !fb[51];

  logic [52:0] ma_raw, mb_raw;
  assign ma_raw = {ea_f != '0, fa};
  assign mb_raw = {eb_f != '0, fb};

  logic [5:0] lz_a, lz_b;
  always_comb begin
    lz_a = 6'd0;
    lz_b = 6'd0;
    for (int i = 0; i <= 52; i++) begin
      if (ma_raw[i]) lz_a = 6'(52 - i);
      if (mb_raw[i]) lz_b = 6'(52 - i);
    end
  end

  // Biased quotient exponent: (max(ea,1) - lz_a) - (max(eb,1) - lz_b) + bias.
  logic signed [EW-1:0] eq_unpack;
  assign eq_unpack = $signed(
      EW'(a_sub ? 11'd1 : ea_f)
  ) - $signed(
      EW'(lz_a)
  ) - $signed(
      EW'(b_sub ? 11'd1 : eb_f)
  ) + $signed(
      EW'(lz_b)
  ) + $signed(
      is_d ? EW'(1023) : EW'(127)
  );

  // Special results.
  logic sp_nan, sp_nv, sp_dz, sp_inf, sp_zero, special;
  assign sp_nan  = a_nan || b_nan || (a_zero && b_zero) || (a_inf && b_inf);
  assign sp_nv   = a_snan || b_snan || (a_zero && b_zero) || (a_inf && b_inf);
  assign sp_dz   = !sp_nan && b_zero && !a_inf;
  assign sp_inf  = !sp_nan && (a_inf || b_zero);
  assign sp_zero = !sp_nan && !sp_inf && (a_zero || b_inf);
  assign special = sp_nan || sp_inf || sp_zero;

  // ===========================================================================
  // Datapath registers
  // ===========================================================================
  logic [52:0] ma, mb;
  logic [5:0] lza_q, lzb_q;
  logic signed [EW-1:0] eq;
  logic [RW-1:0] rem;
  logic [RW-1:0] mult[16];  // mult[m] = m * D, D = 2 * Mb
  logic [55:0] quo;
  logic [3:0] steps;
  logic sp_nan_q, sp_nv_q, sp_dz_q, sp_inf_q, sp_zero_q;

  // ===========================================================================
  // DIV step: radix 16, all fifteen trial subtractions in parallel
  // ===========================================================================
  logic [RW-1:0] rem16;
  logic [RW:0] trial[16];
  logic [15:0] nonneg;
  logic [3:0] digit;
  assign rem16 = {rem[RW-5:0], 4'b0};
  always_comb begin
    for (int m = 0; m < 16; m++) begin
      trial[m]  = {1'b0, rem16} - {1'b0, mult[m]};
      nonneg[m] = !trial[m][RW];
    end
    // nonneg is a thermometer code (m = 0 always passes).
    digit = '0;
    for (int m = 1; m < 16; m++) digit = digit + 4'(nonneg[m]);
  end

  // ===========================================================================
  // POST: normalize the quotient, round bits, tininess, subnormal shift
  // ===========================================================================
  // Q = floor(Ma * 16^n / (2 Mb)): quo[55:0] (double) or quo[27:0] (single).
  // Q / 16^n lies in (1/4, 1), so its top bit or the next one is set.
  logic rem_nz;
  assign rem_nz = (rem != '0);

  logic top;
  logic [52:0] m_full;  // significand at full precision (single in [52:29])
  logic rnd_full, stk_full;
  logic signed [EW-1:0] e_full;
  always_comb begin
    if (is_d) begin
      top      = quo[55];
      m_full   = top ? quo[55:3] : quo[54:2];
      rnd_full = top ? quo[2] : quo[1];
      stk_full = (top ? |quo[1:0] : quo[0]) || rem_nz;
    end else begin
      top      = quo[27];
      m_full   = {(top ? quo[27:4] : quo[26:3]), 29'b0};
      rnd_full = top ? quo[3] : quo[2];
      stk_full = (top ? |quo[2:0] : |quo[1:0]) || rem_nz;
    end
    e_full = top ? eq : eq - EW'(1);
  end

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

  // Tininess after rounding: below emin unless the quotient sits one binade
  // below and rounds up to 2^emin at full precision.
  logic full_ones, full_lsb, tiny;
  assign full_ones = is_d ? (&m_full[52:0]) : (&m_full[52:29]);
  assign full_lsb = is_d ? m_full[0] : m_full[29];
  assign tiny = (e_full < EW'(1)) && !((e_full == EW'(0)) && full_ones && round_up(
      rm_q, sign_q, full_lsb, rnd_full, stk_full
  ));

  // Subnormal result: shift {significand, round} right by 1 - e_full and
  // fold the bits shifted out into sticky.
  logic [6:0] dn_shift;
  logic [54:0] dn_in, dn_out;
  logic dn_lost;
  always_comb begin
    if (e_full >= EW'(1)) dn_shift = '0;
    else if (e_full < $signed(-(EW'(60)))) dn_shift = 7'd61;
    else dn_shift = 7'(EW'(1) - e_full);
    dn_in   = is_d ? {m_full, rnd_full, 1'b0} : {m_full[52:29], rnd_full, 30'b0};
    dn_out  = (dn_shift >= 7'd55) ? '0 : (dn_in >> dn_shift);
    dn_lost = 1'b0;
    for (int i = 0; i < 55; i++) if ((7'(i) < dn_shift) && dn_in[i]) dn_lost = 1'b1;
  end

  // ===========================================================================
  // ROUND (from the POST registers)
  // ===========================================================================
  logic [52:0] r_m;  // significand after the subnormal shift (single in [52:29])
  logic r_rnd, r_stk, r_tiny;
  logic signed [EW-1:0] r_e;  // biased exponent, 1 for a subnormal result

  logic inc;
  assign inc = round_up(rm_q, sign_q, is_d ? r_m[0] : r_m[29], r_rnd, r_stk);

  // {exponent field before the hidden bit, fraction} + hidden + increment.
  logic [EW-1:0] ebase;
  logic [EW+52-1:0] pack_d;
  logic [EW+23-1:0] pack_s;
  assign ebase  = r_e - EW'(1);
  assign pack_d = {ebase, r_m[51:0]} + ((EW + 52)'(r_m[52]) << 52) + (EW + 52)'(inc);
  assign pack_s = {ebase, r_m[51:29]} + ((EW + 23)'(r_m[52]) << 23) + (EW + 23)'(inc);

  logic of, nx;
  assign of = is_d ? (pack_d[EW+52-1:52] >= EW'(2047)) : (pack_s[EW+23-1:23] >= EW'(255));
  assign nx = r_rnd || r_stk;

  logic of_to_max;
  always_comb begin
    case (rm_q)
      riscv_pkg::FRM_RTZ: of_to_max = 1'b1;
      riscv_pkg::FRM_RDN: of_to_max = !sign_q;
      riscv_pkg::FRM_RUP: of_to_max = sign_q;
      default: of_to_max = 1'b0;
    endcase
  end

  logic [63:0] round_result;
  riscv_pkg::fp_flags_t round_flags;
  always_comb begin
    round_flags = '0;
    if (sp_nan_q) begin
      round_result = is_d ? riscv_pkg::FpCanonicalNan64 :
          {32'hFFFF_FFFF, riscv_pkg::FpCanonicalNan};
      round_flags.nv = sp_nv_q;
    end else if (sp_inf_q) begin
      round_result   = is_d ? {sign_q, 11'h7FF, 52'b0} : {32'hFFFF_FFFF, sign_q, 8'hFF, 23'b0};
      round_flags.dz = sp_dz_q;
    end else if (sp_zero_q) begin
      round_result = is_d ? {sign_q, 63'b0} : {32'hFFFF_FFFF, sign_q, 31'b0};
    end else if (of) begin
      round_flags.of = 1'b1;
      round_flags.nx = 1'b1;
      if (is_d) round_result = of_to_max ? {sign_q, 11'h7FE, {52{1'b1}}} : {sign_q, 11'h7FF, 52'b0};
      else
        round_result = of_to_max ? {32'hFFFF_FFFF, sign_q, 8'hFE, {23{1'b1}}} :
            {32'hFFFF_FFFF, sign_q, 8'hFF, 23'b0};
    end else begin
      round_flags.nx = nx;
      round_flags.uf = r_tiny && nx;
      round_result   = is_d ? {sign_q, pack_d[62:0]} : {32'hFFFF_FFFF, sign_q, pack_s[30:0]};
    end
  end

  logic [RW-1:0] d1, d2, d4, d8;
  assign d1 = RW'({mb, 1'b0});
  assign d2 = d1 << 1;
  assign d4 = d1 << 2;
  assign d8 = d1 << 3;

  // ===========================================================================
  // Sequencer
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      state <= S_IDLE;
    end else if (i_kill) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: if (i_start) state <= S_UNPACK;
        S_UNPACK: state <= special ? S_ROUND : ((a_sub || b_sub) ? S_NORM : S_SETUP);
        S_NORM: state <= S_SETUP;
        S_SETUP: state <= S_DIV;
        S_DIV: if (steps == 4'd1) state <= S_POST;
        S_POST: state <= S_ROUND;
        S_ROUND: state <= S_DONE;
        default: state <= S_IDLE;  // S_DONE
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    case (state)
      S_IDLE: begin
        a_q <= i_src1;
        b_q <= i_src2;
        is_d <= (i_op == riscv_pkg::FDIV_D);
        rm_q <= i_rm;
        sign_q <= (i_op == riscv_pkg::FDIV_D) ? (i_src1[63] ^ i_src2[63]) :
            ((&i_src1[63:32] && i_src1[31]) ^ (&i_src2[63:32] && i_src2[31]));
      end
      S_UNPACK: begin
        ma        <= ma_raw;
        mb        <= mb_raw;
        lza_q     <= lz_a;
        lzb_q     <= lz_b;
        eq        <= eq_unpack;
        sp_nan_q  <= sp_nan;
        sp_nv_q   <= sp_nv;
        sp_dz_q   <= sp_dz;
        sp_inf_q  <= sp_inf;
        sp_zero_q <= sp_zero;
      end
      S_NORM: begin
        ma <= ma << lza_q;
        mb <= mb << lzb_q;
      end
      S_SETUP: begin
        // D = 2 Mb; one level of three-input adds forms every multiple.
        mult[0]  <= '0;
        mult[1]  <= d1;
        mult[2]  <= d2;
        mult[3]  <= d2 + d1;
        mult[4]  <= d4;
        mult[5]  <= d4 + d1;
        mult[6]  <= d4 + d2;
        mult[7]  <= d4 + d2 + d1;
        mult[8]  <= d8;
        mult[9]  <= d8 + d1;
        mult[10] <= d8 + d2;
        mult[11] <= d8 + d2 + d1;
        mult[12] <= d8 + d4;
        mult[13] <= d8 + d4 + d1;
        mult[14] <= d8 + d4 + d2;
        mult[15] <= (d8 << 1) - d1;
        rem      <= RW'(ma);
        quo      <= '0;
        steps    <= is_d ? 4'd14 : 4'd7;
      end
      S_DIV: begin
        rem   <= trial[digit][RW-1:0];
        quo   <= {quo[51:0], digit};
        steps <= steps - 4'd1;
      end
      default: ;
    endcase
  end

  // POST registers and the result register.
  always_ff @(posedge i_clk) begin
    if (state == S_POST) begin
      r_m    <= is_d ? dn_out[54:2] : {dn_out[54:31], 29'b0};
      r_rnd  <= is_d ? dn_out[1] : dn_out[30];
      r_stk  <= dn_lost || stk_full || (is_d ? dn_out[0] : (|dn_out[29:0]));
      r_tiny <= tiny;
      r_e    <= (e_full >= EW'(1)) ? e_full : EW'(1);
    end
    if (state == S_ROUND) begin
      o_result <= round_result;
      o_flags  <= round_flags;
    end
  end

  assign o_idle = (state == S_IDLE);
  assign o_done = (state == S_DONE);


endmodule : fp_div_unit
