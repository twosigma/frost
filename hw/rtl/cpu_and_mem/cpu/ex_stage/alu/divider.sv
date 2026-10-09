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
 * Iterative radix-2 restoring divider for RISC-V DIV, DIVU, REM and REMU and
 * their RV64 W forms, one operation at a time. It divides magnitudes, one
 * quotient bit per cycle: WIDTH steps, or WIDTH/2 for a W form, whose operands
 * are the low halves, sign- or zero-extended. The result, quotient or
 * remainder with its sign applied (sign-extended from the low half for a W
 * form), is valid from the cycle after the last step (o_done) until i_accept:
 * WIDTH + 1 cycles after the start cycle, or WIDTH/2 + 1 for a W form.
 *
 * i_start is legal only while o_idle. i_kill abandons the operation, and the
 * divider is idle on the next cycle. While idle, the datapath registers load
 * from the inputs every cycle, so i_start reaches only the control state, not
 * the wide register enables.
 *
 * RISC-V special cases fall out of the magnitude division:
 *   - Divide by zero: every step fits, so the quotient is all ones and the
 *     remainder is the dividend's magnitude. The quotient is never negated,
 *     and the remainder takes the dividend's sign, which gives -1 and the
 *     dividend.
 *   - Signed overflow (most negative / -1): both operands are negative, so
 *     the quotient magnitude 2^(WIDTH-1) is not negated, and its bit pattern
 *     is the most negative value. The remainder is 0.
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
  // State
  // ---------------------------------------------------------------------------
  logic running_q, done_q;
  // Partial remainder: below the divisor after each step, or, for a zero
  // divisor, the dividend bits consumed so far.
  logic [WIDTH-1:0] remainder_q;
  // Dividend bits shift out of the top, quotient bits in at the bottom.
  logic [WIDTH-1:0] quotient_q;
  logic [WIDTH-1:0] divisor_q;  // Divisor magnitude
  logic [CountWidth-1:0] steps_left_q;  // Steps after the current one
  logic word_q, rem_q, negate_q;

  assign o_idle = !running_q && !done_q;
  assign o_done = done_q;

  // One restoring step: bring in the next dividend bit and subtract the
  // divisor if it fits. The shifted remainder can be WIDTH+1 bits wide; what
  // a subtraction leaves is below the divisor, so it fits in WIDTH bits.
  logic [WIDTH:0] shifted;
  logic [WIDTH+1:0] difference;
  logic fits;
  assign shifted = {remainder_q, quotient_q[WIDTH-1]};
  assign difference = {1'b0, shifted} - {2'b0, divisor_q};
  assign fits = !difference[WIDTH+1];

  always_ff @(posedge i_clk) begin
    if (i_rst || i_kill) begin
      running_q <= 1'b0;
      done_q <= 1'b0;
    end else if (o_idle) begin
      running_q <= i_start;
    end else if (running_q) begin
      running_q <= steps_left_q != '0;
      done_q <= steps_left_q == '0;
    end else if (i_accept) begin
      done_q <= 1'b0;
    end
  end

  // A W form's dividend magnitude fits in the low half. Starting it in the top
  // half consumes it in WIDTH/2 steps, which leave the quotient in the low half
  // of quotient_q and the original zeros in the top half.
  always_ff @(posedge i_clk) begin
    if (o_idle) begin
      remainder_q <= '0;
      quotient_q <= i_is_word ?
          {dividend_magnitude[HalfWidth-1:0], {HalfWidth{1'b0}}} : dividend_magnitude;
      divisor_q <= divisor_magnitude;
      steps_left_q <= i_is_word ? CountWidth'(HalfWidth - 1) : CountWidth'(WIDTH - 1);
      word_q <= i_is_word;
      rem_q <= i_is_rem;
      // The remainder takes the dividend's sign. The quotient is negative when
      // the signs differ, except for divide by zero.
      negate_q <= i_is_rem ? dividend_negative :
          (dividend_negative ^ divisor_negative) && (divisor != '0);
    end else if (running_q) begin
      remainder_q  <= fits ? difference[WIDTH-1:0] : shifted[WIDTH-1:0];
      quotient_q   <= {quotient_q[WIDTH-2:0], fits};
      steps_left_q <= steps_left_q - 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Result
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] magnitude, signed_result;
  assign magnitude = rem_q ? remainder_q : quotient_q;
  assign signed_result = negate_q ? (~magnitude + 1'b1) : magnitude;
  assign o_result = word_q ?
      {{HalfWidth{signed_result[HalfWidth-1]}}, signed_result[HalfWidth-1:0]} : signed_result;

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL
  // formal/divider.sby checks results against a reference at a small width.
  // Every start reloads the whole datapath, so an operation behaves the same
  // whatever came before it, and a bounded check that covers one complete
  // operation from reset, with arbitrary operands, kills and accept delays,
  // covers every operation. With DIVIDER_FORMAL_NO_REFERENCE (the 64-bit
  // induction) the reference is left out and the invariants below carry the
  // proof: the step count, and a remainder that stays below the divisor.
  initial assume (i_rst);

  logic f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;
  always @(posedge i_clk) begin
    if (f_past_valid) assume (!i_rst);
  end

  logic f_word;
  logic [CountWidth:0] f_cycles;  // Cycles since the start, while running
  always @(posedge i_clk) begin
    if (o_idle && i_start) begin
      f_word   <= i_is_word;
      f_cycles <= '0;
    end else if (running_q) begin
      f_cycles <= f_cycles + 1'b1;
    end
  end

`ifndef DIVIDER_FORMAL_NO_REFERENCE
  // The RISC-V result, computed independently of the datapath: operands
  // extended for W forms, then the ISA's divide-by-zero and overflow rules.
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
      if (running_q) begin
        // Done exactly one cycle after the last of WIDTH (or WIDTH/2) steps.
        assert (f_word == word_q);
        assert (32'(f_cycles) + 32'(steps_left_q) + 1 == (f_word ? HalfWidth : WIDTH));
        // After any number of steps the remainder is below a nonzero divisor,
        // so it always fits in WIDTH bits.
        if (divisor_q != '0) assert (remainder_q < divisor_q);
      end
      if ($past(!i_rst)) begin
        if ($past(running_q) && done_q) assert (f_cycles == (f_word ? HalfWidth : WIDTH));
        // Progress: a start runs, every step but the last keeps running, and
        // the last one reaches done, unless a kill intervenes. Only a start
        // leaves idle (MUL_RS's divide gate relies on it). A killed operation
        // is gone on the next cycle, and a held result stays until it is
        // taken.
        if ($past(o_idle && i_start && !i_kill)) assert (running_q);
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
