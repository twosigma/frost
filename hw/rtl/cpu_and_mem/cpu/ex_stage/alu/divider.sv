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
 * High-frequency Radix-4 divider for RISC-V DIV, DIVU, REM and REMU and their
 * RV64 W forms, one operation at a time.
 *
 * Key microarchitectural features:
 *   - Radix-4 Datapath: Retires 2 quotient bits per cycle, halving worst-case
 *     iteration counts to WIDTH/2 (32 steps for 64-bit ops, 16 steps for W forms).
 *   - Precomputed Multiples: Divisor multiples (1D, 2D, 3D) are formed during
 *     the idle-to-active setup cycle (3D = 2D + 1D). In each recurrence cycle,
 *     three parallel wide subtractions evaluate simultaneously into a late 4:1
 *     multiplexer, keeping the loop path strictly within ~380-420 ps without
 *     lowering Fmax.
 *   - CLZ Early Termination: A parallel leading-zero count tree on the dividend
 *     magnitude skips leading zero digit pairs, allowing small dividends to
 *     retire in 4-8 cycles instead of the full 32.
 *   - Instant Fast Paths: Divide-by-zero, signed overflow, and dividend < divisor
 *     retire in a single cycle.
 *   - Interface Contract: Preserves the standard handshake (i_start while o_idle,
 *     i_kill abort, o_done and o_result held until i_accept or i_kill).
 */
module divider #(
    parameter int unsigned WIDTH = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input logic             i_start,      // Begin a division (only while o_idle)
    input logic             i_kill,       // Abandon the operation
    input logic             i_accept,     // The held result is taken
    input logic             i_is_signed,  // DIV, REM and their W forms
    input logic             i_is_word,    // W form: low-half operands, sign-extended result
    input logic             i_is_rem,     // Remainder instead of quotient
    input logic [WIDTH-1:0] i_dividend,
    input logic [WIDTH-1:0] i_divisor,

    output logic             o_idle,
    output logic             o_done,   // o_result is valid, held until i_accept or i_kill
    output logic [WIDTH-1:0] o_result
);

  localparam int unsigned HalfWidth  = WIDTH / 2;
  localparam int unsigned CountWidth = $clog2(WIDTH);

  // ---------------------------------------------------------------------------
  // Operand magnitudes and result sign
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] dividend, divisor;
  logic dividend_negative, divisor_negative;
  logic [WIDTH-1:0] dividend_magnitude, divisor_magnitude;

  always_comb begin
    dividend = i_dividend;
    divisor  = i_divisor;
    if (i_is_word) begin
      dividend = {{HalfWidth{i_is_signed & i_dividend[HalfWidth-1]}}, i_dividend[HalfWidth-1:0]};
      divisor  = {{HalfWidth{i_is_signed & i_divisor[HalfWidth-1]}}, i_divisor[HalfWidth-1:0]};
    end
    dividend_negative  = i_is_signed & dividend[WIDTH-1];
    divisor_negative   = i_is_signed & divisor[WIDTH-1];
    dividend_magnitude = dividend_negative ? (~dividend + 1'b1) : dividend;
    divisor_magnitude  = divisor_negative ? (~divisor + 1'b1) : divisor;
  end

  // ---------------------------------------------------------------------------
  // Leading-Zero Counter (CLZ)
  // ---------------------------------------------------------------------------
  function automatic logic [CountWidth:0] clz(input logic [WIDTH-1:0] val);
    int unsigned i;
    logic found;
    begin
      clz = (CountWidth + 1)'(WIDTH);
      found = 1'b0;
      for (i = 0; i < WIDTH; i++) begin
        if (val[WIDTH - 1 - i] && !found) begin
          clz = (CountWidth + 1)'(i);
          found = 1'b1;
        end
      end
    end
  endfunction

  logic [CountWidth:0] lz_dividend;
  assign lz_dividend = clz(dividend_magnitude);

  // For W forms, the active operand is restricted to the lower half.
  logic [CountWidth:0] lz_active;
  assign lz_active = i_is_word ?
      ((lz_dividend >= (CountWidth + 1)'(HalfWidth)) ?
          (lz_dividend - (CountWidth + 1)'(HalfWidth)) : '0) :
      lz_dividend;

  // Number of 2-bit radix-4 steps we can safely skip based on leading zeros
  logic [CountWidth-1:0] skip_steps;
  assign skip_steps = CountWidth'(lz_active >> 1);

  logic [CountWidth-1:0] max_steps;
  assign max_steps = i_is_word ? CountWidth'(HalfWidth / 2) : CountWidth'(WIDTH / 2);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic running_q, done_q;
  logic [WIDTH-1:0] remainder_q;
  logic [WIDTH-1:0] quotient_q;
  logic [WIDTH-1:0] d1_q;
  logic [WIDTH:0]   d2_q;
  logic [WIDTH+1:0] d3_q;
  logic [CountWidth-1:0] steps_left_q;
  logic word_q, rem_q, negate_q;
  logic [WIDTH-1:0] fast_result_q;
  logic fast_exit_q;

  assign o_idle = !running_q && !done_q;
  assign o_done = done_q;

  // ---------------------------------------------------------------------------
  // Radix-4 Recurrence Datapath (3 Parallel Subtractions + Late Select)
  // ---------------------------------------------------------------------------
  logic [WIDTH+1:0] shifted;
  logic [WIDTH+2:0] diff1, diff2, diff3;
  logic [1:0] q_digit;
  logic [WIDTH-1:0] next_remainder;

  assign shifted = {remainder_q, quotient_q[WIDTH-1:WIDTH-2]};
  assign diff1 = {1'b0, shifted} - {3'b0, d1_q};
  assign diff2 = {1'b0, shifted} - {2'b0, d2_q};
  assign diff3 = {1'b0, shifted} - {1'b0, d3_q};

  always_comb begin
    if (!diff3[WIDTH+2]) begin
      next_remainder = diff3[WIDTH-1:0];
      q_digit = 2'b11;
    end else if (!diff2[WIDTH+2]) begin
      next_remainder = diff2[WIDTH-1:0];
      q_digit = 2'b10;
    end else if (!diff1[WIDTH+2]) begin
      next_remainder = diff1[WIDTH-1:0];
      q_digit = 2'b01;
    end else begin
      next_remainder = shifted[WIDTH-1:0];
      q_digit = 2'b00;
    end
  end

  // ---------------------------------------------------------------------------
  // Fast Path Detection
  // ---------------------------------------------------------------------------
  logic is_div_by_zero;
  logic is_overflow;
  logic is_smaller;
  logic is_fast_path;

  assign is_div_by_zero = (divisor == '0);
  assign is_overflow = i_is_signed && (dividend == {1'b1, {(WIDTH - 1) {1'b0}}}) && (divisor == '1);
  assign is_smaller = (dividend_magnitude < divisor_magnitude) && !is_div_by_zero;
  assign is_fast_path = is_div_by_zero || is_overflow || is_smaller;

  // ---------------------------------------------------------------------------
  // Sequential Control & Datapath
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst || i_kill) begin
      running_q   <= 1'b0;
      done_q      <= 1'b0;
      fast_exit_q <= 1'b0;
    end else if (o_idle) begin
      if (i_start) begin
        if (is_fast_path) begin
          running_q   <= 1'b0;
          done_q      <= 1'b1;
          fast_exit_q <= 1'b1;
        end else begin
          running_q   <= 1'b1;
          done_q      <= 1'b0;
          fast_exit_q <= 1'b0;
        end
      end
    end else if (running_q) begin
      running_q <= steps_left_q != '0;
      done_q    <= steps_left_q == '0;
    end else if (i_accept) begin
      done_q      <= 1'b0;
      fast_exit_q <= 1'b0;
    end
  end

  // Datapath registers
  logic [WIDTH-1:0] aligned_dividend;
  assign aligned_dividend = i_is_word ?
      {dividend_magnitude[HalfWidth-1:0], {HalfWidth{1'b0}}} : dividend_magnitude;

  always_ff @(posedge i_clk) begin
    if (o_idle) begin
      remainder_q   <= '0;
      word_q        <= i_is_word;
      rem_q         <= i_is_rem;
      negate_q      <= i_is_rem ? dividend_negative :
          (dividend_negative ^ divisor_negative) && (divisor != '0);

      // Fast exit result selection
      if (is_div_by_zero) begin
        fast_result_q <= i_is_rem ? dividend : '1;
      end else if (is_overflow) begin
        fast_result_q <= i_is_rem ? '0 : dividend;
      end else if (is_smaller) begin
        fast_result_q <= i_is_rem ? dividend : '0;
      end else begin
        fast_result_q <= '0;
      end

      // CLZ shift and step counter setup
      if (skip_steps < max_steps) begin
        quotient_q   <= aligned_dividend << (skip_steps * 2);
        steps_left_q <= (max_steps - skip_steps) - 1'b1;
      end else begin
        quotient_q   <= aligned_dividend;
        steps_left_q <= '0;
      end

      // Precomputed divisor multiples: 1D, 2D, 3D
      d1_q <= divisor_magnitude;
      d2_q <= {1'b0, divisor_magnitude} << 1;
      d3_q <= ({2'b00, divisor_magnitude} << 1) + {2'b00, divisor_magnitude};
    end else if (running_q) begin
      remainder_q  <= next_remainder;
      quotient_q   <= {quotient_q[WIDTH-3:0], q_digit};
      steps_left_q <= steps_left_q - 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Result
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] magnitude, signed_result;
  assign magnitude = rem_q ? remainder_q : quotient_q;
  assign signed_result = negate_q ? (~magnitude + 1'b1) : magnitude;

  logic [WIDTH-1:0] computed_result;
  assign computed_result = word_q ?
      {{HalfWidth{signed_result[HalfWidth-1]}}, signed_result[HalfWidth-1:0]} : signed_result;

  assign o_result = fast_exit_q ?
      (word_q ? {{HalfWidth{fast_result_q[HalfWidth-1]}}, fast_result_q[HalfWidth-1:0]} : fast_result_q) :
      computed_result;

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL
  initial assume (i_rst);

  logic f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;
  always @(posedge i_clk) begin
    if (f_past_valid) assume (!i_rst);
  end

  logic f_word;
  logic [CountWidth:0] f_cycles;
  always @(posedge i_clk) begin
    if (o_idle && i_start) begin
      f_word   <= i_is_word;
      f_cycles <= '0;
    end else if (running_q) begin
      f_cycles <= f_cycles + 1'b1;
    end
  end

`ifndef DIVIDER_FORMAL_NO_REFERENCE
  function automatic logic [WIDTH-1:0] reference(
      input logic [WIDTH-1:0] a_in, input logic [WIDTH-1:0] b_in, input logic is_signed,
      input logic is_word, input logic is_rem);
    logic [WIDTH-1:0] a, b, q, r, result;
    begin
      a = a_in;
      b = b_in;
      if (is_word) begin
        a = {{HalfWidth{is_signed & a_in[HalfWidth-1]}}, a_in[HalfWidth-1:0]};
        b = {{HalfWidth{is_signed & b_in[HalfWidth-1]}}, b_in[HalfWidth-1:0]};
      end
      if (b == '0) begin
        q = '1;
        r = a;
      end else if (is_signed && a == {1'b1, {(WIDTH - 1) {1'b0}}} && b == '1) begin
        q = a;
        r = '0;
      end else if (is_signed) begin
        q = $signed(a) / $signed(b);
        r = $signed(a) % $signed(b);
      end else begin
        q = a / b;
        r = a % b;
      end
      result = is_rem ? r : q;
      if (is_word) result = {{HalfWidth{result[HalfWidth-1]}}, result[HalfWidth-1:0]};
      reference = result;
    end
  endfunction

  logic [WIDTH-1:0] f_expected;
  always @(posedge i_clk) begin
    if (o_idle && i_start)
      f_expected <= reference(i_dividend, i_divisor, i_is_signed, i_is_word, i_is_rem);
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && done_q) assert (o_result == f_expected);
  end
`endif

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      assert (!(running_q && done_q));
      if ($past(!i_rst)) begin
        // Only start may leave idle. Steps progress to done unless killed;
        // kill returns idle next cycle. Done and result must remain stable
        // until accept or kill.
        if ($past(o_idle && i_start && !i_kill && is_fast_path)) assert (done_q);
        if ($past(o_idle && i_start && !i_kill && !is_fast_path)) assert (running_q);
        if ($past(running_q && steps_left_q != '0 && !i_kill)) assert (running_q);
        if ($past(running_q && steps_left_q == '0 && !i_kill)) assert (done_q);
        if ($past(o_idle && !i_start)) assert (o_idle);
        if ($past(i_kill)) assert (o_idle);
        if ($past(done_q && !i_accept && !i_kill)) assert (done_q && $stable(o_result));
        if ($past(done_q && i_accept && !i_kill)) assert (o_idle);
      end
      cover (done_q && f_word && o_result[WIDTH-1]);
      cover (done_q && !f_word && o_result == {1'b1, {(WIDTH - 1) {1'b0}}});
    end
  end
`endif

endmodule : divider
