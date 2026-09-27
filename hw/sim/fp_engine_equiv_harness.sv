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
  Equivalence bench for fp_engine against Berkeley SoftFloat, the arithmetic
  library Spike uses (fp_softfloat_ref.c, through DPI-C). One operation runs at
  a time: the sequencer starts the engine, takes the reference result for the
  same operation, waits for the engine, and compares the value and the flags
  bit for bit.

  Stimulus comes from two places. i_ext_valid injects a directed vector while
  o_ext_ready is high. With i_gen_enable high the internal generator supplies
  vectors instead: xorshift chains pick the operation from every F and D
  compute instruction, the rounding mode, and a class for each operand
  (random bits, ordinary exponents, subnormals, zeros, infinities, quiet and
  signalling NaNs, extremes, exact powers of two, tie patterns, operands
  correlated with the first one so sums and FMA results cancel, integer
  shapes, and improperly NaN-boxed single-precision values).

  With i_kill_enable high each vector first runs on the engine and is killed
  i_kill_delay cycles after the start (a random delay when that is 0). The
  engine must not complete after the kill and must be idle on the next cycle;
  the vector then runs whole, so residue the kill left behind shows up as a
  mismatch.

  Counters are the interface to the test; the first mismatch is latched in
  the o_fail_* outputs. o_max_latency is the longest engine latency seen.
*/
module fp_engine_equiv_harness #(
    // Vectors the internal generator produces before it stops and raises
    // o_done. Directed vectors count too. A longer sweep runs with
    // FROST_VERILATOR_EXTRA_ARGS=-GVECTOR_TARGET=<n>.
    parameter int unsigned VECTOR_TARGET = 100000,
    // Cycles a single operation may take before it is counted as a timeout.
    parameter int unsigned WAIT_LIMIT = 1024
) (
    input logic i_clk,
    input logic i_rst_n,

    input logic        i_gen_enable,
    input logic [63:0] i_seed,

    input  logic        i_ext_valid,
    input  logic [ 7:0] i_ext_op,
    input  logic [ 2:0] i_ext_rm,
    input  logic [63:0] i_ext_a,
    input  logic [63:0] i_ext_b,
    input  logic [63:0] i_ext_c,
    output logic        o_ext_ready,

    input logic       i_kill_enable,
    input logic [9:0] i_kill_delay,

    output logic        o_done,
    output logic [31:0] o_vector_target,
    output logic [63:0] o_vectors,
    output logic [31:0] o_mismatches,
    output logic [31:0] o_timeouts,
    output logic [31:0] o_kills,
    output logic [31:0] o_kill_leaks,
    output logic [31:0] o_kill_stuck,
    output logic [31:0] o_max_latency,

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

  // ===========================================================================
  // Operation table
  // ===========================================================================
  localparam int unsigned NumOps = 64;

  // Arithmetic operations appear more than once so they dominate the mix.
  function automatic riscv_pkg::instr_op_e op_at(input logic [5:0] idx);
    case (idx)
      6'd0: op_at = riscv_pkg::FADD_S;
      6'd1: op_at = riscv_pkg::FSUB_S;
      6'd2: op_at = riscv_pkg::FMUL_S;
      6'd3: op_at = riscv_pkg::FDIV_S;
      6'd4: op_at = riscv_pkg::FSQRT_S;
      6'd5: op_at = riscv_pkg::FMADD_S;
      6'd6: op_at = riscv_pkg::FMSUB_S;
      6'd7: op_at = riscv_pkg::FNMADD_S;
      6'd8: op_at = riscv_pkg::FNMSUB_S;
      6'd9: op_at = riscv_pkg::FSGNJ_S;
      6'd10: op_at = riscv_pkg::FSGNJN_S;
      6'd11: op_at = riscv_pkg::FSGNJX_S;
      6'd12: op_at = riscv_pkg::FMIN_S;
      6'd13: op_at = riscv_pkg::FMAX_S;
      6'd14: op_at = riscv_pkg::FCVT_W_S;
      6'd15: op_at = riscv_pkg::FCVT_WU_S;
      6'd16: op_at = riscv_pkg::FMV_X_W;
      6'd17: op_at = riscv_pkg::FMV_W_X;
      6'd18: op_at = riscv_pkg::FEQ_S;
      6'd19: op_at = riscv_pkg::FLT_S;
      6'd20: op_at = riscv_pkg::FLE_S;
      6'd21: op_at = riscv_pkg::FCLASS_S;
      6'd22: op_at = riscv_pkg::FCVT_S_W;
      6'd23: op_at = riscv_pkg::FCVT_S_WU;
      6'd24: op_at = riscv_pkg::FCVT_L_S;
      6'd25: op_at = riscv_pkg::FCVT_LU_S;
      6'd26: op_at = riscv_pkg::FCVT_S_L;
      6'd27: op_at = riscv_pkg::FCVT_S_LU;
      6'd28: op_at = riscv_pkg::FADD_D;
      6'd29: op_at = riscv_pkg::FSUB_D;
      6'd30: op_at = riscv_pkg::FMUL_D;
      6'd31: op_at = riscv_pkg::FDIV_D;
      6'd32: op_at = riscv_pkg::FSQRT_D;
      6'd33: op_at = riscv_pkg::FMADD_D;
      6'd34: op_at = riscv_pkg::FMSUB_D;
      6'd35: op_at = riscv_pkg::FNMADD_D;
      6'd36: op_at = riscv_pkg::FNMSUB_D;
      6'd37: op_at = riscv_pkg::FSGNJ_D;
      6'd38: op_at = riscv_pkg::FSGNJN_D;
      6'd39: op_at = riscv_pkg::FSGNJX_D;
      6'd40: op_at = riscv_pkg::FMIN_D;
      6'd41: op_at = riscv_pkg::FMAX_D;
      6'd42: op_at = riscv_pkg::FCVT_W_D;
      6'd43: op_at = riscv_pkg::FCVT_WU_D;
      6'd44: op_at = riscv_pkg::FCVT_S_D;
      6'd45: op_at = riscv_pkg::FCVT_D_S;
      6'd46: op_at = riscv_pkg::FEQ_D;
      6'd47: op_at = riscv_pkg::FLT_D;
      6'd48: op_at = riscv_pkg::FLE_D;
      6'd49: op_at = riscv_pkg::FCLASS_D;
      6'd50: op_at = riscv_pkg::FCVT_D_W;
      6'd51: op_at = riscv_pkg::FCVT_D_WU;
      6'd52: op_at = riscv_pkg::FCVT_L_D;
      6'd53: op_at = riscv_pkg::FCVT_LU_D;
      6'd54: op_at = riscv_pkg::FCVT_D_L;
      6'd55: op_at = riscv_pkg::FCVT_D_LU;
      6'd56: op_at = riscv_pkg::FMV_X_D;
      6'd57: op_at = riscv_pkg::FMV_D_X;
      6'd58: op_at = riscv_pkg::FMADD_D;
      6'd59: op_at = riscv_pkg::FMADD_S;
      6'd60: op_at = riscv_pkg::FADD_D;
      6'd61: op_at = riscv_pkg::FSUB_S;
      6'd62: op_at = riscv_pkg::FNMSUB_D;
      default: op_at = riscv_pkg::FMSUB_S;
    endcase
  endfunction

  import "DPI-C" function int fp_softfloat_ref(
    input string op,
    input int rm,
    input longint unsigned a,
    input longint unsigned b,
    input longint unsigned c,
    output longint unsigned result,
    output int flags
  );

  // Source operand kinds of an operation.
  function automatic logic op_is_double_src(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D, riscv_pkg::FMUL_D, riscv_pkg::FDIV_D,
      riscv_pkg::FSQRT_D, riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D,
      riscv_pkg::FNMSUB_D, riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FMIN_D, riscv_pkg::FMAX_D, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_S_D, riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCLASS_D, riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D, riscv_pkg::FMV_X_D:
      op_is_double_src = 1'b1;
      default: op_is_double_src = 1'b0;
    endcase
  endfunction

  function automatic logic op_has_int_src(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_S_L, riscv_pkg::FCVT_S_LU,
      riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU, riscv_pkg::FCVT_D_L, riscv_pkg::FCVT_D_LU,
      riscv_pkg::FMV_W_X, riscv_pkg::FMV_D_X:
      op_has_int_src = 1'b1;
      default: op_has_int_src = 1'b0;
    endcase
  endfunction

  function automatic logic op_is_fma(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      op_is_fma = 1'b1;
      default: op_is_fma = 1'b0;
    endcase
  endfunction

  function automatic logic op_is_f2i(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D, riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D:
      op_is_f2i = 1'b1;
      default: op_is_f2i = 1'b0;
    endcase
  endfunction

  // ===========================================================================
  // Stimulus generator
  // ===========================================================================
  logic [63:0] rnd_a, rnd_b, rnd_c, rnd_d, rnd_e;

  function automatic logic [63:0] xorshift64(input logic [63:0] value);
    logic [63:0] step;
    begin
      step = value ^ (value << 13);
      step = step ^ (step >> 7);
      step = step ^ (step << 17);
      xorshift64 = step;
    end
  endfunction

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

  // Build an FP operand from raw bits and a class code. ref_exp is the biased
  // exponent the correlated classes stay near (the first operand's, or the
  // product's for an FMA addend). box_raw leaves a single-precision value's
  // upper half random (an improperly boxed register).
  function automatic logic [63:0] shape_fp(input logic [63:0] raw, input logic [3:0] class_sel,
                                           input logic is_double, input logic [11:0] ref_exp,
                                           input logic [51:0] ref_frac, input logic box_raw);
    logic sign;
    logic [11:0] exp_w;
    logic [51:0] frac;
    logic [10:0] exp_d;
    logic [7:0] exp_s;
    logic [5:0] bit_pos;
    logic [63:0] value;
    begin
      sign = raw[63];
      exp_d = raw[62:52];
      exp_s = raw[62:55];
      frac = raw[51:0];
      bit_pos = raw[5:0];
      exp_w = is_double ? {1'b0, exp_d} : {4'b0, exp_s};

      case (class_sel)
        // Exponent near the bias.
        4'd1: exp_w = (is_double ? 12'd1023 : 12'd127) + {{7{raw[36]}}, raw[36:32]};
        // Near the reference exponent, sharing the reference's leading
        // fraction bits: sums and FMA results that cancel.
        4'd2: begin
          exp_w = ref_exp + {{10{raw[33]}}, raw[33:32]};
          frac  = {ref_frac[51:12], raw[11:0]} ^ ({52{raw[40]}} & {40'b0, raw[23:12]});
        end
        4'd3: exp_w = ref_exp + {{8{raw[35]}}, raw[35:32]};
        // Subnormal, random fraction.
        4'd4: begin
          exp_w = '0;
          if (frac == '0) frac = 52'd1;
        end
        // Subnormal, single bit.
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
        // Quiet and signalling NaN.
        4'd8: begin
          exp_w = is_double ? 12'h7FF : 12'hFF;
          frac  = {1'b1, raw[50:0]};
        end
        4'd9: begin
          exp_w = is_double ? 12'h7FF : 12'hFF;
          frac  = {1'b0, raw[50:30], raw[29:1] | {28'b0, 1'b1}, raw[0] | !is_double};
        end
        // Largest finite, smallest normal, exponent extremes.
        4'd10: begin
          exp_w = is_double ? 12'h7FE : 12'hFE;
          frac  = raw[33] ? '1 : frac;
        end
        4'd11: begin
          exp_w = raw[34] ? 12'd1 : 12'd2;
          frac  = raw[33] ? '0 : frac;
        end
        // Exact power of two, and ties.
        4'd12: frac = '0;
        4'd13: frac = {raw[51:30], raw[29] ? 30'h0 : 30'h3FFF_FFFF};
        // Integer-valued exponent range (conversions to integer).
        4'd14: exp_w = (is_double ? 12'd1023 : 12'd127) + {6'b0, raw[37:32]} - 12'd2;
        default: ;  // classes 0 and 15 keep the raw bits
      endcase

      // Keep the exponent in range (correlated classes can wrap).
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

  // Integer operand shapes for conversions to FP and the FMV moves.
  function automatic logic [63:0] shape_int(input logic [63:0] raw, input logic [3:0] class_sel);
    begin
      case (class_sel)
        4'd0, 4'd1: shape_int = raw;
        4'd2: shape_int = {56'b0, raw[7:0]};
        4'd3: shape_int = 64'd1 << raw[5:0];
        4'd4: shape_int = (64'd1 << raw[5:0]) - 64'd1;
        4'd5: shape_int = (64'd1 << raw[5:0]) + 64'd1;
        4'd6: shape_int = -{56'b0, raw[7:0]};
        4'd7: shape_int = 64'h8000_0000_0000_0000;
        4'd8: shape_int = '1;
        4'd9: shape_int = {{32{raw[31]}}, raw[31:0]};
        4'd10: shape_int = {32'b0, raw[31:0]};
        4'd11: shape_int = 64'h0000_0000_8000_0000;
        4'd12: shape_int = raw >> raw[37:32];
        4'd13: shape_int = {raw[63:40], 40'hFF_FFFF_FFFF};
        4'd14: shape_int = '0;
        default: shape_int = {raw[63:32], 32'hFFFF_FFFF};
      endcase
    end
  endfunction

  // ===========================================================================
  // Sequencer
  // ===========================================================================
  typedef enum logic [2:0] {
    SEQ_IDLE,
    SEQ_LAUNCH,
    SEQ_WAIT,
    SEQ_COMPARE,
    SEQ_KILL_WAIT,
    SEQ_KILL_CHECK
  } seq_state_e;

  seq_state_e seq_state;

  riscv_pkg::instr_op_e cur_op;
  logic [2:0] cur_rm;
  logic [63:0] cur_a, cur_b, cur_c;

  logic [63:0] vectors_q;
  logic [31:0] mismatches_q;
  logic [31:0] timeouts_q;
  logic [31:0] kills_q;
  logic [31:0] kill_leaks_q;
  logic [31:0] kill_stuck_q;
  logic [31:0] max_latency_q;
  logic [31:0] wait_count;
  logic [9:0] kill_count;
  logic [9:0] kill_delay_q;
  logic kill_armed;
  logic replay_q;

  logic gen_ready;
  assign gen_ready = i_gen_enable && (vectors_q < 64'(VECTOR_TARGET));

  assign o_vector_target = 32'(VECTOR_TARGET);
  assign o_ext_ready = (seq_state == SEQ_IDLE) && !replay_q;
  assign o_done = (vectors_q >= 64'(VECTOR_TARGET)) && (seq_state == SEQ_IDLE) && !replay_q;
  assign o_vectors = vectors_q;
  assign o_mismatches = mismatches_q;
  assign o_timeouts = timeouts_q;
  assign o_kills = kills_q;
  assign o_kill_leaks = kill_leaks_q;
  assign o_kill_stuck = kill_stuck_q;
  assign o_max_latency = max_latency_q;

  // Generated vector
  riscv_pkg::instr_op_e gen_op;
  logic gen_d;
  logic [63:0] gen_a, gen_b, gen_c;
  logic [11:0] gen_prod_exp;
  always_comb begin
    gen_op = op_at(rnd_e[5:0]);
    gen_d  = op_is_double_src(gen_op);
    if (op_has_int_src(gen_op)) begin
      gen_a = shape_int(rnd_a, rnd_e[11:8]);
    end else begin
      gen_a = shape_fp(
        rnd_a,
        op_is_f2i(
          gen_op
        ) && rnd_e[40] ? 4'd14 : rnd_e[11:8],
        gen_d,
        gen_d ? 12'd1023 : 12'd127,
        '0,
        rnd_e[30] && rnd_e[31] && rnd_e[32]
      );
    end
    gen_b = shape_fp(
      rnd_b,
      rnd_e[15:12],
      gen_d,
      gen_d ? {1'b0, gen_a[62:52]} : {4'b0, gen_a[30:23]},
      gen_d ? gen_a[51:0] : {gen_a[22:0], 29'b0},
      rnd_e[33] && rnd_e[34] && rnd_e[35]
    );
    // An FMA addend correlated with the product's exponent.
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
  end

  // Engine and reference outputs
  logic eng_idle, eng_done;
  logic [63:0] eng_result;
  riscv_pkg::fp_flags_t eng_flags;
  logic eng_start, eng_kill;

  logic dut_seen;
  logic [63:0] dut_res, ref_res;
  logic [4:0] dut_flg, ref_flg;
  logic ref_known;

  logic launch;
  assign launch = (seq_state == SEQ_LAUNCH);

  assign eng_start = launch;
  assign eng_kill = (seq_state == SEQ_KILL_WAIT) && (kill_count == kill_delay_q);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      seq_state     <= SEQ_IDLE;
      vectors_q     <= '0;
      mismatches_q  <= '0;
      timeouts_q    <= '0;
      kills_q       <= '0;
      kill_leaks_q  <= '0;
      kill_stuck_q  <= '0;
      max_latency_q <= '0;
      wait_count    <= '0;
      dut_seen      <= 1'b0;
      o_fail_valid  <= 1'b0;
      kill_count    <= '0;
      kill_delay_q  <= '0;
      kill_armed    <= 1'b0;
      replay_q      <= 1'b0;
    end else begin
      case (seq_state)
        SEQ_IDLE: begin
          dut_seen   <= 1'b0;
          wait_count <= '0;
          kill_count <= '0;
          if (replay_q) begin
            replay_q   <= 1'b0;
            kill_armed <= 1'b0;
            seq_state  <= SEQ_LAUNCH;
          end else if (i_ext_valid) begin
            cur_op       <= riscv_pkg::instr_op_e'(i_ext_op);
            cur_rm       <= i_ext_rm;
            cur_a        <= i_ext_a;
            cur_b        <= i_ext_b;
            cur_c        <= i_ext_c;
            kill_armed   <= i_kill_enable;
            kill_delay_q <= i_kill_delay;
            seq_state    <= SEQ_LAUNCH;
          end else if (gen_ready) begin
            cur_op       <= gen_op;
            // Mostly the five rounding modes, uniformly.
            cur_rm       <= (rnd_d[2:0] > 3'd4) ? {1'b0, rnd_d[4:3]} : rnd_d[2:0];
            cur_a        <= gen_a;
            cur_b        <= gen_b;
            cur_c        <= gen_c;
            kill_armed   <= i_kill_enable;
            kill_delay_q <= (i_kill_delay == '0) ? rnd_d[14:5] : i_kill_delay;
            seq_state    <= SEQ_LAUNCH;
          end
        end

        SEQ_LAUNCH: begin
          if (!kill_armed) begin
            longint unsigned r;
            int f;
            ref_known <= fp_softfloat_ref(
                cur_op.name(), int'(cur_rm), cur_a, cur_b, cur_c, r, f
            ) != 0;
            ref_res <= r;
            ref_flg <= 5'(f);
          end
          seq_state <= kill_armed ? SEQ_KILL_WAIT : SEQ_WAIT;
        end

        // Killed run: the engine alone. A completion before the kill is
        // legal; one after it is a leak.
        SEQ_KILL_WAIT: begin
          kill_count <= kill_count + 10'd1;
          if (eng_kill) begin
            kills_q   <= kills_q + 32'd1;
            seq_state <= SEQ_KILL_CHECK;
          end else if (eng_done) begin
            // Completed before the kill point: nothing to kill.
            replay_q  <= 1'b1;
            seq_state <= SEQ_IDLE;
          end
        end

        SEQ_KILL_CHECK: begin
          if (eng_done) kill_leaks_q <= kill_leaks_q + 32'd1;
          if (!eng_idle) kill_stuck_q <= kill_stuck_q + 32'd1;
          replay_q  <= 1'b1;
          seq_state <= SEQ_IDLE;
        end

        SEQ_WAIT: begin
          wait_count <= wait_count + 32'd1;
          if (eng_done && !dut_seen) begin
            dut_seen <= 1'b1;
            dut_res  <= eng_result;
            dut_flg  <= eng_flags;
            if (wait_count + 32'd1 > max_latency_q) max_latency_q <= wait_count + 32'd1;
          end
          if (dut_seen || eng_done) begin
            seq_state <= SEQ_COMPARE;
          end else if (wait_count >= 32'(WAIT_LIMIT)) begin
            timeouts_q <= timeouts_q + 32'd1;
            vectors_q  <= vectors_q + 64'd1;
            seq_state  <= SEQ_IDLE;
          end
        end

        SEQ_COMPARE: begin
          vectors_q <= vectors_q + 64'd1;
          if (!ref_known || (dut_res != ref_res) || (dut_flg != ref_flg)) begin
            mismatches_q <= mismatches_q + 32'd1;
            if (!o_fail_valid) begin
              o_fail_valid     <= 1'b1;
              o_fail_op        <= 8'(cur_op);
              o_fail_rm        <= cur_rm;
              o_fail_a         <= cur_a;
              o_fail_b         <= cur_b;
              o_fail_c         <= cur_c;
              o_fail_dut       <= dut_res;
              o_fail_ref       <= ref_res;
              o_fail_dut_flags <= dut_flg;
              o_fail_ref_flags <= ref_flg;
            end
          end
          seq_state <= SEQ_IDLE;
        end

        default: seq_state <= SEQ_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // Units
  // ===========================================================================
  fp_engine u_engine (
      .i_clk   (i_clk),
      .i_rst_n (i_rst_n),
      .i_start (eng_start),
      .i_op    (cur_op),
      .i_rm    (cur_rm),
      .i_src1  (cur_a),
      .i_src2  (cur_b),
      .i_src3  (cur_c),
      .i_kill  (eng_kill),
      .o_idle  (eng_idle),
      .o_done  (eng_done),
      .o_result(eng_result),
      .o_flags (eng_flags)
  );

endmodule : fp_engine_equiv_harness
