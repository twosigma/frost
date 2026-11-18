// Copyright (c) 2026 John Goodacre.

/*
  Compare fp_fma_pipe results and flags bit for bit with Berkeley SoftFloat
  (fp_softfloat_ref.c through DPI-C), one operation per cycle.

  Each cycle launches a directed vector (i_ext_valid, always accepted) or,
  with i_gen_enable, a generated one, unless i_bubble asks for an idle cycle.
  The reference is computed at launch and travels down a shift register as
  deep as the pipeline, so the comparison also checks the latency: the
  pipeline's o_valid must coincide with the shift register's tail.

  The generator draws the pipelined operations, rounding modes 0..4 and the
  operand classes of fp_engine_equiv_harness (correlated operands for
  cancellation, subnormals, infinities, NaNs, extreme exponents, ties and
  improperly boxed single operands); an FMA addend tracks the product's
  exponent.
*/
module fp_fma_pipe_equiv_harness #(
    parameter int unsigned VECTOR_TARGET = 100000
) (
    input logic i_clk,
    input logic i_rst_n,

    input logic        i_gen_enable,
    input logic [63:0] i_seed,
    input logic        i_bubble,

    input logic        i_ext_valid,
    input logic [ 7:0] i_ext_op,
    input logic [ 2:0] i_ext_rm,
    input logic [63:0] i_ext_a,
    input logic [63:0] i_ext_b,
    input logic [63:0] i_ext_c,

    output logic        o_done,
    output logic [31:0] o_vector_target,
    output logic [63:0] o_vectors,
    output logic [31:0] o_mismatches,
    output logic [31:0] o_latency_errors,

    output logic        o_fail_valid,
    output logic [ 7:0] o_fail_op,
    output logic [ 2:0] o_fail_rm,
    output logic [63:0] o_fail_a,
    output logic [63:0] o_fail_b,
    output logic [63:0] o_fail_c,
    output logic [63:0] o_fail_dut,
    output logic [63:0] o_fail_ref,
    output logic [ 4:0] o_fail_dut_flags,
    output logic [ 4:0] o_fail_ref_flags
);

  localparam int unsigned Depth = riscv_pkg::FpPipeDepth;

  import "DPI-C" function int fp_softfloat_ref(
    input string op,
    input int rm,
    input longint unsigned a,
    input longint unsigned b,
    input longint unsigned c,
    output longint unsigned result,
    output int flags
  );

  function automatic riscv_pkg::instr_op_e op_at(input logic [3:0] idx);
    case (idx)
      4'd0: op_at = riscv_pkg::FADD_S;
      4'd1: op_at = riscv_pkg::FSUB_S;
      4'd2: op_at = riscv_pkg::FMUL_S;
      4'd3: op_at = riscv_pkg::FMADD_S;
      4'd4: op_at = riscv_pkg::FMSUB_S;
      4'd5: op_at = riscv_pkg::FNMADD_S;
      4'd6: op_at = riscv_pkg::FNMSUB_S;
      4'd7: op_at = riscv_pkg::FMADD_S;
      4'd8: op_at = riscv_pkg::FADD_D;
      4'd9: op_at = riscv_pkg::FSUB_D;
      4'd10: op_at = riscv_pkg::FMUL_D;
      4'd11: op_at = riscv_pkg::FMADD_D;
      4'd12: op_at = riscv_pkg::FMSUB_D;
      4'd13: op_at = riscv_pkg::FNMADD_D;
      4'd14: op_at = riscv_pkg::FNMSUB_D;
      default: op_at = riscv_pkg::FMADD_D;
    endcase
  endfunction

  function automatic logic op_is_double(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D, riscv_pkg::FMUL_D, riscv_pkg::FMADD_D,
      riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      op_is_double = 1'b1;
      default: op_is_double = 1'b0;
    endcase
  endfunction

  function automatic logic [63:0] xorshift64(input logic [63:0] value);
    logic [63:0] step;
    begin
      step = value ^ (value << 13);
      step = step ^ (step >> 7);
      step = step ^ (step << 17);
      xorshift64 = step;
    end
  endfunction

  // Operand shapes, as fp_engine_equiv_harness.
  function automatic logic [63:0] shape_fp(input logic [63:0] raw, input logic [3:0] class_sel,
                                           input logic is_double, input logic [11:0] ref_exp,
                                           input logic [51:0] ref_frac, input logic box_raw);
    logic sign;
    logic [11:0] exp_w;
    logic [51:0] frac;
    logic [5:0] bit_pos;
    logic [63:0] value;
    begin
      sign = raw[63];
      frac = raw[51:0];
      bit_pos = raw[5:0];
      exp_w = is_double ? {1'b0, raw[62:52]} : {4'b0, raw[62:55]};
      case (class_sel)
        4'd1: exp_w = (is_double ? 12'd1023 : 12'd127) + {{7{raw[36]}}, raw[36:32]};
        4'd2: begin
          exp_w = ref_exp + {{10{raw[33]}}, raw[33:32]};
          frac  = {ref_frac[51:12], raw[11:0]} ^ ({52{raw[40]}} & {40'b0, raw[23:12]});
        end
        4'd3: exp_w = ref_exp + {{8{raw[35]}}, raw[35:32]};
        4'd4: begin
          exp_w = '0;
          if (frac == '0) frac = 52'd1;
        end
        4'd5: begin
          exp_w = '0;
          frac  = 52'd1 << (is_double ? (bit_pos % 6'd52) : (bit_pos % 6'd23 + 6'd29));
        end
        4'd6: begin
          exp_w = '0;
          frac  = '0;
        end
        4'd7: begin
          exp_w = is_double ? 12'h7FF : 12'hFF;
          frac  = '0;
        end
        4'd8: begin
          exp_w = is_double ? 12'h7FF : 12'hFF;
          frac  = {1'b1, raw[50:0]};
        end
        4'd9: begin
          exp_w = is_double ? 12'h7FF : 12'hFF;
          frac  = {1'b0, raw[50:30], raw[29:1] | {28'b0, 1'b1}, raw[0] | !is_double};
        end
        4'd10: begin
          exp_w = is_double ? 12'h7FE : 12'hFE;
          frac  = raw[33] ? '1 : frac;
        end
        4'd11: begin
          exp_w = raw[34] ? 12'd1 : 12'd2;
          frac  = raw[33] ? '0 : frac;
        end
        4'd12: frac = '0;
        4'd13: frac = {raw[51:30], raw[29] ? 30'h0 : 30'h3FFF_FFFF};
        // Small exponents: products and sums near the subnormal range.
        4'd14: exp_w = is_double ? {1'b0, 6'b0, raw[36:32]} + 12'd480 : {6'b0, raw[37:32]};
        default: ;
      endcase
      if (is_double) begin
        if (exp_w[11]) exp_w = 12'd1;
        else if (exp_w > 12'h7FF) exp_w = 12'h7FE;
        value = {sign, exp_w[10:0], frac};
      end else begin
        if (exp_w[11]) exp_w = 12'd1;
        else if (exp_w > 12'hFF) exp_w = 12'hFE;
        value = {
          box_raw ? raw[31:0] ^ 32'h1234_5678 : 32'hFFFF_FFFF, sign, exp_w[7:0], frac[51:29]
        };
      end
      shape_fp = value;
    end
  endfunction

  logic [63:0] rnd_a, rnd_b, rnd_c, rnd_d, rnd_e;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rnd_a <= (i_seed == '0) ? 64'h0123_4567_89AB_CDEF : i_seed;
      rnd_b <= ~i_seed ^ 64'hDEAD_BEEF_CAFE_F00D;
      rnd_c <= {i_seed[31:0], i_seed[63:32]} ^ 64'h5555_AAAA_3333_CCCC;
      rnd_d <= {i_seed[15:0], i_seed[63:16]} ^ 64'h0F0F_1234_F0F0_5678;
      rnd_e <= {i_seed[47:0], i_seed[63:48]} ^ 64'h9E37_79B9_7F4A_7C15;
    end else begin
      rnd_a <= xorshift64(rnd_a);
      rnd_b <= xorshift64(rnd_b);
      rnd_c <= xorshift64(rnd_c);
      rnd_d <= xorshift64(rnd_d);
      rnd_e <= xorshift64(rnd_e);
    end
  end

  riscv_pkg::instr_op_e gen_op;
  logic gen_d;
  logic [63:0] gen_a, gen_b, gen_c;
  logic [11:0] gen_prod_exp;
  logic [ 2:0] gen_rm;
  always_comb begin
    gen_op = op_at(rnd_e[3:0]);
    gen_d = op_is_double(gen_op);
    gen_a = shape_fp(rnd_a, rnd_e[11:8], gen_d, gen_d ? 12'd1023 : 12'd127, '0,
                     rnd_e[30] && rnd_e[31] && rnd_e[32]);
    gen_b = shape_fp(
      rnd_b,
      rnd_e[15:12],
      gen_d,
      gen_d ? {1'b0, gen_a[62:52]} : {4'b0, gen_a[30:23]},
      gen_d ? gen_a[51:0] : {gen_a[22:0], 29'b0},
      rnd_e[33] && rnd_e[34] && rnd_e[35]
    );
    gen_prod_exp = gen_d ? ({1'b0, gen_a[62:52]} + {1'b0, gen_b[62:52]} - 12'd1023) :
        ({4'b0, gen_a[30:23]} + {4'b0, gen_b[30:23]} - 12'd127);
    gen_c = shape_fp(
      rnd_c,
      rnd_e[19:16],
      gen_d,
      gen_prod_exp,
      gen_d ? gen_a[51:0] : {gen_a[22:0], 29'b0},
      rnd_e[36] && rnd_e[37] && rnd_e[38]
    );
    gen_rm = (rnd_d[2:0] > 3'd4) ? {1'b0, rnd_d[4:3]} : rnd_d[2:0];
  end

  logic [63:0] launched_q;
  logic gen_ready;
  assign gen_ready = i_gen_enable && (launched_q < 64'(VECTOR_TARGET));

  logic launch;
  riscv_pkg::instr_op_e l_op;
  logic [2:0] l_rm;
  logic [63:0] l_a, l_b, l_c;
  always_comb begin
    launch = !i_bubble && (i_ext_valid || gen_ready);
    if (i_ext_valid) begin
      l_op = riscv_pkg::instr_op_e'(i_ext_op);
      l_rm = i_ext_rm;
      l_a  = i_ext_a;
      l_b  = i_ext_b;
      l_c  = i_ext_c;
    end else begin
      l_op = gen_op;
      l_rm = gen_rm;
      l_a  = gen_a;
      l_b  = gen_b;
      l_c  = gen_c;
    end
  end

  // Reference shift register.
  logic exp_valid[Depth];
  logic exp_known[Depth];
  logic [63:0] exp_res[Depth];
  logic [4:0] exp_flg[Depth];
  logic [7:0] exp_op[Depth];
  logic [2:0] exp_rm[Depth];
  logic [63:0] exp_a[Depth], exp_b[Depth], exp_c[Depth];

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      for (int i = 0; i < Depth; i++) exp_valid[i] <= 1'b0;
    end else begin
      for (int i = Depth - 1; i > 0; i--) begin
        exp_valid[i] <= exp_valid[i-1];
        exp_known[i] <= exp_known[i-1];
        exp_res[i]   <= exp_res[i-1];
        exp_flg[i]   <= exp_flg[i-1];
        exp_op[i]    <= exp_op[i-1];
        exp_rm[i]    <= exp_rm[i-1];
        exp_a[i]     <= exp_a[i-1];
        exp_b[i]     <= exp_b[i-1];
        exp_c[i]     <= exp_c[i-1];
      end
      exp_valid[0] <= launch;
      if (launch) begin
        longint unsigned r;
        int f;
        exp_known[0] <= fp_softfloat_ref(l_op.name(), int'(l_rm), l_a, l_b, l_c, r, f) != 0;
        exp_res[0]   <= r;
        exp_flg[0]   <= 5'(f);
        exp_op[0]    <= 8'(l_op);
        exp_rm[0]    <= l_rm;
        exp_a[0]     <= l_a;
        exp_b[0]     <= l_b;
        exp_c[0]     <= l_c;
      end
    end
  end

  logic dut_valid;
  logic [63:0] dut_result;
  riscv_pkg::fp_flags_t dut_flags;
  fp_fma_pipe u_dut (
      .i_clk   (i_clk),
      .i_rst_n (i_rst_n),
      .i_valid (launch),
      .i_op    (l_op),
      .i_rm    (l_rm),
      .i_src1  (l_a),
      .i_src2  (l_b),
      .i_src3  (l_c),
      .o_valid (dut_valid),
      .o_result(dut_result),
      .o_flags (dut_flags)
  );

  logic [63:0] vectors_q;
  logic [31:0] mismatches_q, latency_q;
  logic inflight;
  always_comb begin
    inflight = 1'b0;
    for (int i = 0; i < Depth; i++) inflight |= exp_valid[i];
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      launched_q   <= '0;
      vectors_q    <= '0;
      mismatches_q <= '0;
      latency_q    <= '0;
      o_fail_valid <= 1'b0;
    end else begin
      if (launch && !i_ext_valid) launched_q <= launched_q + 64'd1;
      if (dut_valid != exp_valid[Depth-1]) latency_q <= latency_q + 32'd1;
      if (exp_valid[Depth-1]) begin
        vectors_q <= vectors_q + 64'd1;
        if (!exp_known[Depth-1] || dut_result != exp_res[Depth-1] ||
            5'(dut_flags) != exp_flg[Depth-1]) begin
          mismatches_q <= mismatches_q + 32'd1;
          if (!o_fail_valid) begin
            o_fail_valid     <= 1'b1;
            o_fail_op        <= exp_op[Depth-1];
            o_fail_rm        <= exp_rm[Depth-1];
            o_fail_a         <= exp_a[Depth-1];
            o_fail_b         <= exp_b[Depth-1];
            o_fail_c         <= exp_c[Depth-1];
            o_fail_dut       <= dut_result;
            o_fail_ref       <= exp_res[Depth-1];
            o_fail_dut_flags <= 5'(dut_flags);
            o_fail_ref_flags <= exp_flg[Depth-1];
          end
        end
      end
    end
  end

  assign o_vector_target = 32'(VECTOR_TARGET);
  assign o_vectors = vectors_q;
  assign o_mismatches = mismatches_q;
  assign o_latency_errors = latency_q;
  assign o_done = !gen_ready && !inflight;

endmodule : fp_fma_pipe_equiv_harness
