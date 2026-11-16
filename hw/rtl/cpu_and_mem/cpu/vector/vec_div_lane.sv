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

// One restoring divide step per cycle, with no operand-dependent early exit.
// The sequencer extends SEW operands to 64 bits and truncates the result.
module vec_div_lane (
    input logic i_clk,
    i_rst,
    i_valid,
    i_signed,
    i_rem,
    input logic [63:0] i_a,
    i_b,
    output logic o_valid,
    output logic [63:0] o_result
);
  logic busy_q, neg_q, neg_rem_q, rem_q, zero_q;
  logic [6:0] count_q;
  logic [63:0] divisor_q, quotient_q, remainder_q, dividend_q;
  logic [64:0] trial, difference;
  logic [63:0] next_q, next_r, unsigned_result;
  assign trial = {remainder_q, quotient_q[63]};
  assign difference = trial - {1'b0, divisor_q};
  assign next_q = {quotient_q[62:0], !difference[64]};
  assign next_r = difference[64] ? trial[63:0] : difference[63:0];
  assign unsigned_result = rem_q ? next_r : next_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      busy_q  <= 1'b0;
      o_valid <= 1'b0;
      count_q <= 0;
    end else begin
      o_valid <= 1'b0;
      if (i_valid && !busy_q) begin
        busy_q <= 1'b1;
        count_q <= 0;
        divisor_q <= (i_signed && i_b[63]) ? -i_b : i_b;
        quotient_q <= (i_signed && i_a[63]) ? -i_a : i_a;
        remainder_q <= 0;
        dividend_q <= i_a;
        neg_q <= i_signed && (i_a[63] ^ i_b[63]);
        neg_rem_q <= i_signed && i_a[63];
        rem_q <= i_rem;
        zero_q <= i_b == 0;
      end else if (busy_q) begin
        quotient_q <= next_q;
        remainder_q <= next_r;
        count_q <= count_q + 1;
        if (count_q == 63) begin
          busy_q  <= 1'b0;
          o_valid <= 1'b1;
          if (zero_q) o_result <= rem_q ? dividend_q : '1;
          else o_result <= (rem_q ? neg_rem_q : neg_q) ? -unsigned_result : unsigned_result;
        end
      end
    end
  end
endmodule
