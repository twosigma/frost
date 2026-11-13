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
  The vector unit's non-arithmetic floating-point operations for one IEEE 754
  binary format, EXP exponent bits and FRAC fraction bits (FP16, FP32 or
  FP64). i_op selects
    0 equal          (vmfeq; vmfne inverts it)
    1 less than      (vmflt; vmfgt swaps the operands)
    2 less or equal  (vmfle; vmfge swaps the operands)
    3 minimum        (vfmin)
    4 maximum        (vfmax)
    5 sign inject    (vfsgnj: a's magnitude, b's sign)
    6 negated sign   (vfsgnjn)
    7 xor sign       (vfsgnjx)
    8 classify       (vfclass: the ten-bit class mask)
  A comparison returns its answer in bit 0. o_flags are fflags {NV, DZ, OF,
  UF, NX}: equality and minimum/maximum are invalid on a signaling NaN, the
  ordered comparisons on any NaN. Minimum and maximum return the other
  operand when one is a NaN, the canonical NaN when both are, and treat -0 as
  less than +0. Every result appears a fixed one cycle after the cycle that
  takes the input.
*/
module vec_fp_misc #(
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input  logic         i_clk,
    input  logic         i_rst,
    input  logic         i_valid,
    input  logic [  3:0] i_op,
    input  logic [W-1:0] i_a,
    input  logic [W-1:0] i_b,
    output logic         o_valid,
    output logic [W-1:0] o_result,
    output logic [  4:0] o_flags
);

  localparam logic [W-1:0] CanonicalNan = {1'b0, {EXP{1'b1}}, 1'b1, {(FRAC - 1) {1'b0}}};

  logic s0_valid;
  logic [3:0] s0_op;
  logic [W-1:0] s0_a, s0_b;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op <= i_op;
    s0_a  <= i_a;
    s0_b  <= i_b;
  end

  function automatic logic is_nan(input logic [W-1:0] x);
    is_nan = (x[W-2-:EXP] == '1) && (x[FRAC-1:0] != '0);
  endfunction
  function automatic logic is_snan(input logic [W-1:0] x);
    is_snan = is_nan(x) && !x[FRAC-1];
  endfunction
  function automatic logic [9:0] classify(input logic [W-1:0] x);
    logic s, ez, eo, fz;
    s = x[W-1];
    ez = (x[W-2-:EXP] == '0);
    eo = (x[W-2-:EXP] == '1);
    fz = (x[FRAC-1:0] == '0);
    classify = '0;
    classify[0] = s && eo && fz;
    classify[1] = s && !ez && !eo;
    classify[2] = s && ez && !fz;
    classify[3] = s && ez && fz;
    classify[4] = !s && ez && fz;
    classify[5] = !s && ez && !fz;
    classify[6] = !s && !ez && !eo;
    classify[7] = !s && eo && fz;
    classify[8] = eo && !fz && !x[FRAC-1];
    classify[9] = eo && !fz && x[FRAC-1];
  endfunction

  logic [W-1:0] result;
  logic [  4:0] flags;
  always_comb begin
    logic a_nan, b_nan, any_snan, both_zero, mag_lt, mag_eq, lt, eq, pick_a;
    a_nan = is_nan(s0_a);
    b_nan = is_nan(s0_b);
    any_snan = is_snan(s0_a) || is_snan(s0_b);
    both_zero = (s0_a[W-2:0] == '0) && (s0_b[W-2:0] == '0);
    mag_lt = s0_a[W-2:0] < s0_b[W-2:0];
    mag_eq = s0_a[W-2:0] == s0_b[W-2:0];
    // Ordered relations of two non-NaN values; zeros of either sign are equal.
    eq = !a_nan && !b_nan && ((s0_a == s0_b) || both_zero);
    lt = !a_nan && !b_nan && !both_zero &&
        ((s0_a[W-1] && !s0_b[W-1]) || (!s0_a[W-1] && !s0_b[W-1] && mag_lt) ||
         (s0_a[W-1] && s0_b[W-1] && !mag_lt && !mag_eq));
    // Minimum picks a when a < b or a is -0 against a zero; maximum the rest.
    pick_a = lt || (both_zero && s0_a[W-1]);
    result = '0;
    flags = '0;
    unique case (s0_op)
      4'd0: begin
        result[0] = eq;
        flags[4]  = any_snan;
      end
      4'd1: begin
        result[0] = lt;
        flags[4]  = a_nan || b_nan;
      end
      4'd2: begin
        result[0] = lt || eq;
        flags[4]  = a_nan || b_nan;
      end
      4'd3, 4'd4: begin
        flags[4] = any_snan;
        if (a_nan && b_nan) result = CanonicalNan;
        else if (a_nan) result = s0_b;
        else if (b_nan) result = s0_a;
        else if (pick_a == (s0_op == 4'd3)) result = s0_a;
        else result = s0_b;
      end
      4'd5: result = {s0_b[W-1], s0_a[W-2:0]};
      4'd6: result = {!s0_b[W-1], s0_a[W-2:0]};
      4'd7: result = {s0_a[W-1] ^ s0_b[W-1], s0_a[W-2:0]};
      default: result = W'(classify(s0_a));
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s0_valid;
    o_result <= result;
    o_flags  <= flags;
  end

endmodule
