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
  The vector unit's mask unit: the mask-register logical operations, vcpop.m,
  vfirst.m, vmsbf.m, vmsif.m, vmsof.m, viota.m and vid.v. An instruction is fed
  as a series of steps, one per cycle, starting with i_first set; state that
  spans steps (the running count, whether a first set bit has been seen, the
  element index) belongs to the instruction in flight and restarts on
  i_first.

  The logical, count, first and set-before/including/only-first operations
  read 64 mask bits per step: i_a (vs2), i_b (vs1, logical operations only)
  and i_act, the active bits (inside the body and selected by v0); bit j of
  step s is mask bit 64*s + j. Their results are mask bits; an inactive bit
  reads 0 and the sequencer merges it with the destination. viota.m and vid.v
  produce one 64-bit word of SEW-wide elements per step: i_a and i_act hold the
  mask bits of the word's elements in their low 64/SEW bits.

  o_scalar carries vcpop.m's count and vfirst.m's index (all ones when no
  active bit is set) as of the step it belongs to; the last step's value is
  the instruction's result. Every step's outputs appear a fixed two cycles
  after the cycle that takes its input.
*/
module vec_mask_unit #(
    // Mask bits per instruction at most (VLEN): sizes the counts.
    parameter int unsigned MAX_BITS = 512
) (
    input  logic                     i_clk,
    input  logic                     i_rst,
    input  logic                     i_valid,
    input  logic                     i_first,
    input  vec_pkg::mask_op_e        i_op,
    input  vec_pkg::sew_e            i_sew,
    input  logic              [63:0] i_a,
    input  logic              [63:0] i_b,
    input  logic              [63:0] i_act,
    output logic                     o_valid,
    output logic              [63:0] o_result,
    output logic              [63:0] o_scalar
);


  localparam int unsigned CountBits = $clog2(MAX_BITS + 1);

  // Stage 0: input registers.
  logic s0_valid, s0_first;
  vec_pkg::mask_op_e s0_op;
  vec_pkg::sew_e s0_sew;
  logic [63:0] s0_a, s0_b, s0_act;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_first <= i_first;
    s0_op <= i_op;
    s0_sew <= i_sew;
    s0_a <= i_a;
    s0_b <= i_b;
    s0_act <= i_act;
  end

  // Stage 1: everything that does not depend on earlier steps.
  logic [63:0] x, lowest, below, logic_r;
  logic [6:0] pop, first_idx;
  logic any;
  always_comb begin
    x = s0_a & s0_act;
    lowest = x & (~x + 64'd1);
    below = lowest - 64'd1;  // all ones when x is zero
    any = |x;
    pop = 7'($countones(x));
    first_idx = 7'd0;
    for (int j = 63; j >= 0; j--) if (x[j]) first_idx = 7'(j);
    unique case (s0_op)
      vec_pkg::VK_AND: logic_r = s0_a & s0_b;
      vec_pkg::VK_NAND: logic_r = ~(s0_a & s0_b);
      vec_pkg::VK_ANDN: logic_r = s0_a & ~s0_b;
      vec_pkg::VK_XOR: logic_r = s0_a ^ s0_b;
      vec_pkg::VK_OR: logic_r = s0_a | s0_b;
      vec_pkg::VK_NOR: logic_r = ~(s0_a | s0_b);
      vec_pkg::VK_ORN: logic_r = s0_a | ~s0_b;
      default: logic_r = ~(s0_a ^ s0_b);  // vec_pkg::VK_XNOR
    endcase
  end

  // viota.m: per element, the active set bits before it within the word.
  logic [3:0] prefix[8];
  logic [3:0] word_pop;
  always_comb begin
    logic [3:0] run;
    logic [7:0] bits;
    run = 4'd0;
    unique case (s0_sew)
      vec_pkg::SEW8: bits = x[7:0];
      vec_pkg::SEW16: bits = {4'b0, x[3:0]};
      vec_pkg::SEW32: bits = {6'b0, x[1:0]};
      default: bits = {7'b0, x[0]};
    endcase
    for (int k = 0; k < 8; k++) begin
      prefix[k] = run;
      run = run + 4'(bits[k]);
    end
    word_pop = run;
  end

  logic s1_valid, s1_first, s1_any;
  vec_pkg::mask_op_e s1_op;
  vec_pkg::sew_e s1_sew;
  logic [63:0] s1_act, s1_lowest, s1_below, s1_logic;
  logic [6:0] s1_pop, s1_first_idx;
  logic [3:0] s1_prefix[8];
  logic [3:0] s1_word_pop;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_first <= s0_first;
    s1_op <= s0_op;
    s1_sew <= s0_sew;
    s1_act <= s0_act;
    s1_lowest <= lowest;
    s1_below <= below;
    s1_logic <= logic_r;
    s1_any <= any;
    s1_pop <= pop;
    s1_first_idx <= first_idx;
    s1_prefix <= prefix;
    s1_word_pop <= word_pop;
  end

  // Stage 2: combine with the state of the instruction in flight.
  logic [CountBits-1:0] count_q, base_q, index_q;
  logic found_q;
  logic [CountBits-1:0] count_in, base_in, index_in;
  logic found_in;
  assign count_in = s1_first ? '0 : count_q;
  assign base_in  = s1_first ? '0 : base_q;
  assign index_in = s1_first ? '0 : index_q;
  assign found_in = s1_first ? 1'b0 : found_q;

  logic [CountBits-1:0] count_next, index_next, base_next, first_abs, step_elems;
  logic found_next;
  logic [63:0] result, scalar;
  always_comb begin
    unique case (s1_sew)
      vec_pkg::SEW8: step_elems = CountBits'(8);
      vec_pkg::SEW16: step_elems = CountBits'(4);
      vec_pkg::SEW32: step_elems = CountBits'(2);
      default: step_elems = CountBits'(1);
    endcase
    count_next = count_in;
    index_next = index_in;
    base_next  = base_in;
    found_next = found_in;
    first_abs  = base_in + CountBits'(s1_first_idx);
    result     = '0;
    scalar     = '0;
    unique case (s1_op)
      vec_pkg::VK_CPOP: begin
        count_next = count_in + CountBits'(s1_pop);
        scalar = 64'(count_next);
      end
      vec_pkg::VK_FIRST: begin
        if (!found_in && s1_any) begin
          found_next = 1'b1;
          index_next = first_abs;
        end
        base_next = base_in + CountBits'(64);
        scalar = found_next ? 64'(index_next) : '1;
      end
      vec_pkg::VK_SBF, vec_pkg::VK_SIF, vec_pkg::VK_SOF: begin
        if (!found_in) begin
          unique case (s1_op)
            vec_pkg::VK_SBF: result = s1_act & s1_below;
            vec_pkg::VK_SIF: result = s1_act & (s1_below | s1_lowest);
            default: result = s1_lowest;
          endcase
        end
        found_next = found_in || s1_any;
      end
      vec_pkg::VK_IOTA: begin
        unique case (s1_sew)
          vec_pkg::SEW8:
          for (int k = 0; k < 8; k++) result[8*k+:8] = 8'(count_in + CountBits'(s1_prefix[k]));
          vec_pkg::SEW16:
          for (int k = 0; k < 4; k++) result[16*k+:16] = 16'(count_in + CountBits'(s1_prefix[k]));
          vec_pkg::SEW32:
          for (int k = 0; k < 2; k++) result[32*k+:32] = 32'(count_in + CountBits'(s1_prefix[k]));
          default: result = 64'(count_in);
        endcase
        count_next = count_in + CountBits'(s1_word_pop);
      end
      vec_pkg::VK_ID: begin
        unique case (s1_sew)
          vec_pkg::SEW8: for (int k = 0; k < 8; k++) result[8*k+:8] = 8'(index_in + CountBits'(k));
          vec_pkg::SEW16:
          for (int k = 0; k < 4; k++) result[16*k+:16] = 16'(index_in + CountBits'(k));
          vec_pkg::SEW32:
          for (int k = 0; k < 2; k++) result[32*k+:32] = 32'(index_in + CountBits'(k));
          default: result = 64'(index_in);
        endcase
        index_next = index_in + step_elems;
      end
      default: result = s1_logic;
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_valid <= 1'b0;
      count_q <= '0;
      base_q  <= '0;
      index_q <= '0;
      found_q <= 1'b0;
    end else begin
      o_valid <= s1_valid;
      if (s1_valid) begin
        count_q <= count_next;
        base_q  <= base_next;
        index_q <= index_next;
        found_q <= found_next;
      end
    end
    o_result <= result;
    o_scalar <= scalar;
  end

endmodule
