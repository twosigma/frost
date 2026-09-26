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
  Equivalence bench for fp_div_sqrt_iter against the unrolled reference
  pipelines in hw/sim, fp_divider and fp_sqrt, each instantiated at both
  widths. One operation runs at a time: the sequencer starts the unit and the
  reference the operation selects on the same cycle, waits for both
  completions, and compares result and flags bit for bit.

  Stimulus comes from two places. i_ext_valid injects a directed vector while
  o_ext_ready is high, which is how the test drives its corner list. With
  i_gen_enable high the internal generator supplies vectors instead: three
  xorshift chains supply the raw operand bits and pick the operation, the
  rounding mode, and a class for each operand, so subnormals, zeros,
  infinities, quiet and signalling NaNs, exact powers of two, tie patterns and
  the exponent extremes all appear at a useful rate alongside uniformly random
  bit patterns.

  With i_kill_enable high the sequencer runs each vector twice. The first run
  is killed: i_kill is pulsed i_kill_delay cycles after the launch (clamped
  below the operation's completion cycle), the unit must produce no result and
  must be idle again on the next cycle, and the reference (which has no kill
  input) is left to finish and is discarded. The second run is the whole
  vector, compared against the reference the ordinary way, so a kill that left
  residue behind shows up as a mismatch. Only that second run counts as a
  vector.

  Counters are the interface to the test: o_vectors, o_mismatches, o_skews (a
  completion pair that did not land on the same cycle, which the matched
  latency rules out), o_timeouts, and for the kill mode o_kills, o_kill_leaks
  (a unit completion during a killed run) and o_kill_stuck (the unit not idle
  on the cycle after the kill). The first mismatch is latched in the o_fail_*
  outputs.
*/
module fp_div_sqrt_equiv_harness #(
    // Vectors the internal generator produces before it stops and raises
    // o_done. Directed vectors injected on the external port count too. A
    // longer sweep runs with FROST_VERILATOR_EXTRA_ARGS=-GVECTOR_TARGET=<n>.
    parameter int unsigned VECTOR_TARGET = 50000,
    // Cycles a single operation may take before it is counted as a timeout.
    parameter int unsigned WAIT_LIMIT = 256
) (
    input logic i_clk,
    input logic i_rst_n,

    // Internal random generator
    input logic        i_gen_enable,
    input logic [63:0] i_seed,

    // Directed vector injection
    input  logic        i_ext_valid,
    input  logic        i_ext_is_sqrt,
    input  logic        i_ext_is_double,
    input  logic [63:0] i_ext_a,
    input  logic [63:0] i_ext_b,
    input  logic [ 2:0] i_ext_rm,
    output logic        o_ext_ready,

    // Kill injection. Sampled when a vector starts; i_kill_delay counts
    // cycles after the launch cycle and is clamped to the last cycle before
    // the operation would complete (0 means 1).
    input logic       i_kill_enable,
    input logic [7:0] i_kill_delay,

    // Status
    output logic        o_done,
    output logic [31:0] o_vector_target,
    output logic [63:0] o_vectors,
    output logic [31:0] o_mismatches,
    output logic [31:0] o_skews,
    output logic [31:0] o_timeouts,
    output logic [31:0] o_kills,
    output logic [31:0] o_kill_leaks,
    output logic [31:0] o_kill_stuck,

    // First mismatch
    output logic        o_fail_valid,
    output logic [63:0] o_fail_a,
    output logic [63:0] o_fail_b,
    output logic [ 2:0] o_fail_rm,
    output logic        o_fail_is_sqrt,
    output logic        o_fail_is_double,
    output logic [63:0] o_fail_dut,
    output logic [63:0] o_fail_ref,
    output logic [ 4:0] o_fail_dut_flags,
    output logic [ 4:0] o_fail_ref_flags
);

  // ===========================================================================
  // Stimulus generator
  // ===========================================================================
  logic [63:0] rnd_a, rnd_b, rnd_c;

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
    end else begin
      rnd_a <= xorshift64(rnd_a);
      rnd_b <= xorshift64(rnd_b);
      rnd_c <= xorshift64(rnd_c);
    end
  end

  // Build one operand of the requested width from raw bits and a class code.
  function automatic logic [63:0] shape_operand(input logic [63:0] raw, input logic [3:0] class_sel,
                                                input logic is_double);
    logic sign;
    logic [10:0] exp_d;
    logic [7:0] exp_s;
    logic [51:0] frac_d;
    logic [22:0] frac_s;
    logic [5:0] bit_pos;
    logic [63:0] value_d;
    logic [31:0] value_s;
    begin
      sign = raw[63];
      exp_d = raw[62:52];
      exp_s = raw[62:55];
      frac_d = raw[51:0];
      frac_s = raw[51:29];
      bit_pos = raw[5:0];

      case (class_sel)
        // Exponent near the bias: ordinary values whose quotient can land
        // anywhere in the normal range.
        4'd1, 4'd2: begin
          exp_d = 11'd1023 + {{7{raw[35]}}, raw[35:32]};
          exp_s = 8'd127 + {{4{raw[35]}}, raw[35:32]};
        end
        // Subnormal with a random fraction.
        4'd3: begin
          exp_d  = '0;
          exp_s  = '0;
          frac_d = (raw[51:0] == '0) ? 52'd1 : raw[51:0];
          frac_s = (raw[51:29] == '0) ? 23'd1 : raw[51:29];
        end
        // Subnormal with a single bit set, including the smallest ones.
        4'd4: begin
          exp_d  = '0;
          exp_s  = '0;
          frac_d = 52'd1 << (bit_pos % 6'd52);
          frac_s = 23'd1 << (bit_pos % 6'd23);
        end
        // Zero.
        4'd5: begin
          exp_d  = '0;
          exp_s  = '0;
          frac_d = '0;
          frac_s = '0;
        end
        // Infinity.
        4'd6: begin
          exp_d  = 11'h7FF;
          exp_s  = 8'hFF;
          frac_d = '0;
          frac_s = '0;
        end
        // Quiet NaN.
        4'd7: begin
          exp_d  = 11'h7FF;
          exp_s  = 8'hFF;
          frac_d = {1'b1, raw[50:0]};
          frac_s = {1'b1, raw[50:29]};
        end
        // Signalling NaN (payload forced non-zero).
        4'd8: begin
          exp_d  = 11'h7FF;
          exp_s  = 8'hFF;
          frac_d = {1'b0, raw[50:1], 1'b1};
          frac_s = {1'b0, raw[50:30], 1'b1};
        end
        // Largest finite value.
        4'd9: begin
          exp_d  = 11'h7FE;
          exp_s  = 8'hFE;
          frac_d = {52{1'b1}};
          frac_s = {23{1'b1}};
        end
        // Smallest normal.
        4'd10: begin
          exp_d  = 11'd1;
          exp_s  = 8'd1;
          frac_d = '0;
          frac_s = '0;
        end
        // Exact power of two at a random exponent.
        4'd11: begin
          frac_d = '0;
          frac_s = '0;
        end
        // Tie candidates: a fraction whose low bits are clear or set, which
        // lands the quotient on or next to a rounding boundary.
        4'd12: begin
          frac_d = {raw[51:6], 6'b0};
          frac_s = {raw[51:35], 6'b0};
        end
        4'd13: begin
          frac_d = {raw[51:6], 6'h3F};
          frac_s = {raw[51:35], 6'h3F};
        end
        // Exponent extremes, to reach overflow and underflow after the divide.
        4'd14: begin
          exp_d = raw[32] ? 11'd1 : 11'h7FE;
          exp_s = raw[32] ? 8'd1 : 8'hFE;
        end
        default: ;  // classes 0 and 15 keep the raw bits
      endcase

      value_d = {sign, exp_d, frac_d};
      value_s = {sign, exp_s, frac_s};
      shape_operand = is_double ? value_d : {32'b0, value_s};
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
    SEQ_KILL_DRAIN
  } seq_state_e;

  seq_state_e        seq_state;

  logic              cur_is_sqrt;
  logic              cur_is_double;
  logic       [ 2:0] cur_rm;
  logic       [63:0] cur_a;
  logic       [63:0] cur_b;

  logic       [63:0] vectors_q;
  logic       [31:0] mismatches_q;
  logic       [31:0] skews_q;
  logic       [31:0] timeouts_q;
  logic       [31:0] wait_count;

  logic       [31:0] kills_q;
  logic       [31:0] kill_leaks_q;
  logic       [31:0] kill_stuck_q;
  logic       [ 7:0] kill_count;
  logic       [ 7:0] kill_delay_eff;
  logic              kill_armed;
  logic              replay_q;

  logic              gen_ready;
  assign gen_ready = i_gen_enable && (vectors_q < 64'(VECTOR_TARGET));

  assign o_vector_target = 32'(VECTOR_TARGET);
  assign o_ext_ready = (seq_state == SEQ_IDLE) && !replay_q;
  assign o_done = (vectors_q >= 64'(VECTOR_TARGET)) && (seq_state == SEQ_IDLE) && !replay_q;
  assign o_vectors = vectors_q;
  assign o_mismatches = mismatches_q;
  assign o_skews = skews_q;
  assign o_timeouts = timeouts_q;
  assign o_kills = kills_q;
  assign o_kill_leaks = kill_leaks_q;
  assign o_kill_stuck = kill_stuck_q;

  // The kill must land before the cycle the unit would complete on, which is
  // 36 (single) or 65 (double) cycles after the launch.
  function automatic logic [7:0] kill_delay_for(input logic [7:0] want, input logic is_double);
    logic [7:0] limit;
    begin
      limit = is_double ? 8'd64 : 8'd35;
      if (want == 8'd0) kill_delay_for = 8'd1;
      else if (want > limit) kill_delay_for = limit;
      else kill_delay_for = want;
    end
  endfunction

  // Unit and reference completion capture
  logic dut_seen, ref_seen;
  logic [63:0] dut_res, ref_res;
  logic [4:0] dut_flg, ref_flg;

  // Forward declarations for the instantiated units
  logic unit_ready, unit_valid;
  logic [63:0] unit_result;
  riscv_pkg::fp_flags_t unit_flags;
  logic [31:0] div_s_result, sqrt_s_result;
  logic [63:0] div_d_result, sqrt_d_result;
  logic div_s_valid, div_d_valid, sqrt_s_valid, sqrt_d_valid;
  riscv_pkg::fp_flags_t div_s_flags, div_d_flags, sqrt_s_flags, sqrt_d_flags;

  logic ref_valid;
  logic [63:0] ref_value;
  logic [4:0] ref_flags_sel;

  always_comb begin
    if (cur_is_sqrt) begin
      ref_valid     = cur_is_double ? sqrt_d_valid : sqrt_s_valid;
      ref_value     = cur_is_double ? sqrt_d_result : {32'b0, sqrt_s_result};
      ref_flags_sel = cur_is_double ? sqrt_d_flags : sqrt_s_flags;
    end else begin
      ref_valid     = cur_is_double ? div_d_valid : div_s_valid;
      ref_value     = cur_is_double ? div_d_result : {32'b0, div_s_result};
      ref_flags_sel = cur_is_double ? div_d_flags : div_s_flags;
    end
  end

  logic launch;
  assign launch = (seq_state == SEQ_LAUNCH);

  logic dut_kill;
  assign dut_kill = (seq_state == SEQ_KILL_WAIT) && ((kill_count + 8'd1) == kill_delay_eff);

  logic result_match;
  assign result_match = cur_is_double ? (dut_res == ref_res) : (dut_res[31:0] == ref_res[31:0]);

  logic flags_match;
  assign flags_match = (dut_flg == ref_flg);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      seq_state      <= SEQ_IDLE;
      vectors_q      <= '0;
      mismatches_q   <= '0;
      skews_q        <= '0;
      timeouts_q     <= '0;
      wait_count     <= '0;
      dut_seen       <= 1'b0;
      ref_seen       <= 1'b0;
      o_fail_valid   <= 1'b0;
      kills_q        <= '0;
      kill_leaks_q   <= '0;
      kill_stuck_q   <= '0;
      kill_count     <= '0;
      kill_delay_eff <= 8'd1;
      kill_armed     <= 1'b0;
      replay_q       <= 1'b0;
    end else begin
      case (seq_state)
        SEQ_IDLE: begin
          dut_seen   <= 1'b0;
          ref_seen   <= 1'b0;
          wait_count <= '0;
          kill_count <= '0;
          kill_armed <= 1'b0;
          if (replay_q) begin
            // The same vector again, whole: residue a kill left behind in the
            // unit shows up here as a mismatch against the reference.
            replay_q  <= 1'b0;
            seq_state <= SEQ_LAUNCH;
          end else if (i_ext_valid) begin
            seq_state      <= SEQ_LAUNCH;
            cur_is_sqrt    <= i_ext_is_sqrt;
            cur_is_double  <= i_ext_is_double;
            cur_rm         <= i_ext_rm;
            cur_a          <= i_ext_a;
            cur_b          <= i_ext_b;
            kill_armed     <= i_kill_enable;
            kill_delay_eff <= kill_delay_for(i_kill_delay, i_ext_is_double);
          end else if (gen_ready) begin
            seq_state      <= SEQ_LAUNCH;
            cur_is_sqrt    <= rnd_c[0];
            cur_is_double  <= rnd_c[1];
            cur_rm         <= rnd_c[4:2];
            cur_a          <= shape_operand(rnd_a, rnd_c[11:8], rnd_c[1]);
            cur_b          <= shape_operand(rnd_b, rnd_c[15:12], rnd_c[1]);
            kill_armed     <= i_kill_enable;
            kill_delay_eff <= kill_delay_for(i_kill_delay, rnd_c[1]);
          end
        end

        SEQ_LAUNCH: begin
          seq_state <= kill_armed ? SEQ_KILL_WAIT : SEQ_WAIT;
        end

        SEQ_KILL_WAIT: begin
          kill_count <= kill_count + 8'd1;
          // Nothing may complete before the kill either; the delay is clamped
          // below the completion cycle, so this would be a latency fault.
          if (unit_valid) kill_leaks_q <= kill_leaks_q + 32'd1;
          if (dut_kill) seq_state <= SEQ_KILL_DRAIN;
        end

        SEQ_KILL_DRAIN: begin
          wait_count <= wait_count + 32'd1;
          // The unit is idle from the cycle after the kill and never completes
          // the operation it dropped.
          if ((wait_count == 32'd0) && !unit_ready) kill_stuck_q <= kill_stuck_q + 32'd1;
          if (unit_valid) kill_leaks_q <= kill_leaks_q + 32'd1;
          // The references have no kill input, so let the one this vector
          // started retire before the replay reuses it.
          if (ref_valid || (wait_count >= 32'(WAIT_LIMIT))) begin
            if (!ref_valid) timeouts_q <= timeouts_q + 32'd1;
            kills_q   <= kills_q + 32'd1;
            replay_q  <= 1'b1;
            seq_state <= SEQ_IDLE;
          end
        end

        SEQ_WAIT: begin
          wait_count <= wait_count + 32'd1;
          if (unit_valid) begin
            dut_seen <= 1'b1;
            dut_res  <= unit_result;
            dut_flg  <= unit_flags;
          end
          if (ref_valid) begin
            ref_seen <= 1'b1;
            ref_res  <= ref_value;
            ref_flg  <= ref_flags_sel;
          end
          if (unit_valid ^ ref_valid) begin
            // Matched latency means the two land together. Count the skew and
            // keep waiting for the other side.
            if (!dut_seen && !ref_seen) skews_q <= skews_q + 32'd1;
          end
          if ((dut_seen || unit_valid) && (ref_seen || ref_valid)) begin
            seq_state <= SEQ_COMPARE;
          end else if (wait_count >= 32'(WAIT_LIMIT)) begin
            timeouts_q <= timeouts_q + 32'd1;
            vectors_q  <= vectors_q + 64'd1;
            seq_state  <= SEQ_IDLE;
          end
        end

        SEQ_COMPARE: begin
          seq_state <= SEQ_IDLE;
          vectors_q <= vectors_q + 64'd1;
          if (!result_match || !flags_match) begin
            mismatches_q <= mismatches_q + 32'd1;
            if (!o_fail_valid) begin
              o_fail_valid     <= 1'b1;
              o_fail_a         <= cur_a;
              o_fail_b         <= cur_b;
              o_fail_rm        <= cur_rm;
              o_fail_is_sqrt   <= cur_is_sqrt;
              o_fail_is_double <= cur_is_double;
              o_fail_dut       <= dut_res;
              o_fail_ref       <= ref_res;
              o_fail_dut_flags <= dut_flg;
              o_fail_ref_flags <= ref_flg;
            end
          end
        end

        default: seq_state <= SEQ_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // Unit under test
  // ===========================================================================
  fp_div_sqrt_iter u_dut (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(launch),
      .i_is_sqrt(cur_is_sqrt),
      .i_is_double(cur_is_double),
      .i_operand_a(cur_a),
      .i_operand_b(cur_b),
      .i_rounding_mode(cur_rm),
      .i_kill(dut_kill),
      .o_ready(unit_ready),
      .o_valid(unit_valid),
      .o_result(unit_result),
      .o_flags(unit_flags)
  );

  // ===========================================================================
  // Reference units
  // ===========================================================================
  logic unused_div_s_stall, unused_div_d_stall, unused_sqrt_s_stall, unused_sqrt_d_stall;

  fp_divider #(
      .FP_WIDTH(32)
  ) u_ref_div_s (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(launch & ~cur_is_sqrt & ~cur_is_double),
      .i_operand_a(cur_a[31:0]),
      .i_operand_b(cur_b[31:0]),
      .i_rounding_mode(cur_rm),
      .o_result(div_s_result),
      .o_valid(div_s_valid),
      .o_stall(unused_div_s_stall),
      .o_flags(div_s_flags)
  );

  fp_divider #(
      .FP_WIDTH(64)
  ) u_ref_div_d (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(launch & ~cur_is_sqrt & cur_is_double),
      .i_operand_a(cur_a),
      .i_operand_b(cur_b),
      .i_rounding_mode(cur_rm),
      .o_result(div_d_result),
      .o_valid(div_d_valid),
      .o_stall(unused_div_d_stall),
      .o_flags(div_d_flags)
  );

  fp_sqrt #(
      .FP_WIDTH(32)
  ) u_ref_sqrt_s (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(launch & cur_is_sqrt & ~cur_is_double),
      .i_operand(cur_a[31:0]),
      .i_rounding_mode(cur_rm),
      .o_result(sqrt_s_result),
      .o_valid(sqrt_s_valid),
      .o_stall(unused_sqrt_s_stall),
      .o_flags(sqrt_s_flags)
  );

  fp_sqrt #(
      .FP_WIDTH(64)
  ) u_ref_sqrt_d (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(launch & cur_is_sqrt & cur_is_double),
      .i_operand(cur_a),
      .i_rounding_mode(cur_rm),
      .o_result(sqrt_d_result),
      .o_valid(sqrt_d_valid),
      .o_stall(unused_sqrt_d_stall),
      .o_flags(sqrt_d_flags)
  );

`ifndef SYNTHESIS
  // The unit must be idle whenever a vector is launched.
  always @(posedge i_clk) begin
    if (i_rst_n && launch && !unit_ready) begin
      $error("fp_div_sqrt_equiv_harness: launched into a busy unit");
    end
  end
`endif

endmodule : fp_div_sqrt_equiv_harness
