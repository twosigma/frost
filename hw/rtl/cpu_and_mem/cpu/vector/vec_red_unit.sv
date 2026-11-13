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
  The vector unit's reduction unit: vredsum, vredand, vredor, vredxor,
  vredminu, vredmin, vredmaxu, vredmax, and the widening vwredsumu and
  vwredsum. An instruction is a series of one-cycle steps, each one 64-bit word
  of SEW elements with an active bit per element (i_act, element k at bit k);
  the first step, marked by i_first, also brings the scalar operand vs1[0] in
  i_init. Inactive elements count as the operation's identity. o_acc holds the
  reduction of vs1[0] and every active element up to and including the
  step, so the last step's value is the result: SEW bits wide, or 2*SEW bits
  for the widening sums, zero-extended to 64 bits.

  Elements are extended to 64 bits (sign-extended for vredmin, vredmax and
  vwredsum, zero-extended otherwise), so one 64-bit operation serves every
  element width, and the result is cut back to its width at the end. A word is
  extended in one cycle and reduced by a three-level tree, one level per
  cycle, before it meets the running value; every step's output appears a
  fixed five cycles after the cycle that takes its input.
*/
module vec_red_unit (
    input  logic                    i_clk,
    input  logic                    i_rst,
    input  logic                    i_valid,
    input  logic                    i_first,
    input  vec_pkg::red_op_e        i_op,
    input  vec_pkg::sew_e           i_sew,
    input  logic             [63:0] i_word,
    input  logic             [ 7:0] i_act,
    input  logic             [63:0] i_init,
    output logic                    o_valid,
    output logic             [63:0] o_acc
);


  function automatic logic is_signed(input vec_pkg::red_op_e op);
    is_signed = (op == vec_pkg::VR_MIN) || (op == vec_pkg::VR_MAX) || (op == vec_pkg::VR_WSUM);
  endfunction

  function automatic logic [63:0] identity(input vec_pkg::red_op_e op);
    unique case (op)
      vec_pkg::VR_AND, vec_pkg::VR_MINU: identity = '1;
      vec_pkg::VR_MIN: identity = 64'h7FFF_FFFF_FFFF_FFFF;
      vec_pkg::VR_MAX: identity = 64'h8000_0000_0000_0000;
      default: identity = '0;
    endcase
  endfunction

  function automatic logic [63:0] combine(input vec_pkg::red_op_e op, input logic [63:0] x,
                                          input logic [63:0] y);
    unique case (op)
      vec_pkg::VR_AND: combine = x & y;
      vec_pkg::VR_OR: combine = x | y;
      vec_pkg::VR_XOR: combine = x ^ y;
      vec_pkg::VR_MINU: combine = (x < y) ? x : y;
      vec_pkg::VR_MIN: combine = ($signed(x) < $signed(y)) ? x : y;
      vec_pkg::VR_MAXU: combine = (x > y) ? x : y;
      vec_pkg::VR_MAX: combine = ($signed(x) > $signed(y)) ? x : y;
      default: combine = x + y;  // the sums
    endcase
  endfunction

  // Extend element k of a word at a width (k wraps within the word's
  // elements; the caller substitutes the identity past the last one).
  function automatic logic [63:0] element(input logic [63:0] word, input vec_pkg::sew_e sew,
                                          input int k, input logic sgn);
    unique case (sew)
      vec_pkg::SEW8: element = sgn ? 64'($signed(word[8*k+:8])) : 64'(word[8*k+:8]);
      vec_pkg::SEW16: element = sgn ? 64'($signed(word[16*(k%4)+:16])) : 64'(word[16*(k%4)+:16]);
      vec_pkg::SEW32: element = sgn ? 64'($signed(word[32*(k%2)+:32])) : 64'(word[32*(k%2)+:32]);
      default: element = word;
    endcase
  endfunction

  // Stage 0: input registers.
  logic s0_valid, s0_first;
  vec_pkg::red_op_e s0_op;
  vec_pkg::sew_e s0_sew;
  logic [63:0] s0_word, s0_init;
  logic [7:0] s0_act;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_first <= i_first;
    s0_op <= i_op;
    s0_sew <= i_sew;
    s0_word <= i_word;
    s0_init <= i_init;
    s0_act <= i_act;
  end

  // Eight extended elements, the identity past the word's element count or
  // when inactive; tree level 1 combines them in pairs a cycle later.
  logic [63:0] e[8];
  logic [3:0] nelem;
  always_comb begin
    unique case (s0_sew)
      vec_pkg::SEW8: nelem = 4'd8;
      vec_pkg::SEW16: nelem = 4'd4;
      vec_pkg::SEW32: nelem = 4'd2;
      default: nelem = 4'd1;
    endcase
    for (int k = 0; k < 8; k++)
    e[k] = (k < int'(nelem) && s0_act[k]) ? element(s0_word, s0_sew, k, is_signed(s0_op)) :
        identity(s0_op);
  end

  // The scalar operand, extended like the elements: vs1[0] is SEW wide, or
  // 2*SEW wide for the widening sums.
  logic [63:0] init_ext;
  always_comb begin
    logic sgn;
    vec_pkg::sew_e w;
    sgn = is_signed(s0_op);
    w   = s0_sew;
    if (s0_op == vec_pkg::VR_WSUMU || s0_op == vec_pkg::VR_WSUM)
      w = (s0_sew == vec_pkg::SEW64) ? vec_pkg::SEW64 : vec_pkg::sew_e'(s0_sew + 2'd1);
    init_ext = element(s0_init, w, 0, sgn);
  end

  logic se_valid, se_first;
  vec_pkg::red_op_e se_op;
  vec_pkg::sew_e se_sew;
  logic [63:0] se_e[8], se_init;
  always_ff @(posedge i_clk) begin
    if (i_rst) se_valid <= 1'b0;
    else se_valid <= s0_valid;
    se_first <= s0_first;
    se_op <= s0_op;
    se_sew <= s0_sew;
    se_e <= e;
    se_init <= init_ext;
  end

  // Tree level 1.
  logic s1_valid, s1_first;
  vec_pkg::red_op_e s1_op;
  vec_pkg::sew_e s1_sew;
  logic [63:0] s1_l1[4], s1_init;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= se_valid;
    s1_first <= se_first;
    s1_op <= se_op;
    s1_sew <= se_sew;
    for (int k = 0; k < 4; k++) s1_l1[k] <= combine(se_op, se_e[2*k], se_e[2*k+1]);
    s1_init <= se_init;
  end

  // Tree level 2.
  logic s2_valid, s2_first;
  vec_pkg::red_op_e s2_op;
  vec_pkg::sew_e s2_sew;
  logic [63:0] s2_l2[2], s2_init;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
    s2_first <= s1_first;
    s2_op <= s1_op;
    s2_sew <= s1_sew;
    for (int k = 0; k < 2; k++) s2_l2[k] <= combine(s1_op, s1_l1[2*k], s1_l1[2*k+1]);
    s2_init <= s1_init;
  end

  // Tree level 3.
  logic s3_valid, s3_first;
  vec_pkg::red_op_e s3_op;
  vec_pkg::sew_e s3_sew;
  logic [63:0] s3_word, s3_init;
  always_ff @(posedge i_clk) begin
    if (i_rst) s3_valid <= 1'b0;
    else s3_valid <= s2_valid;
    s3_first <= s2_first;
    s3_op <= s2_op;
    s3_sew <= s2_sew;
    s3_word <= combine(s2_op, s2_l2[0], s2_l2[1]);
    s3_init <= s2_init;
  end

  // The running value: the scalar operand on an instruction's first step.
  logic [63:0] acc_q, acc_in, acc_next, acc_cut;
  assign acc_in   = s3_first ? s3_init : acc_q;
  assign acc_next = combine(s3_op, acc_in, s3_word);
  always_comb begin
    vec_pkg::sew_e w;
    w = s3_sew;
    if (s3_op == vec_pkg::VR_WSUMU || s3_op == vec_pkg::VR_WSUM)
      w = (s3_sew == vec_pkg::SEW64) ? vec_pkg::SEW64 : vec_pkg::sew_e'(s3_sew + 2'd1);
    unique case (w)
      vec_pkg::SEW8: acc_cut = 64'(acc_next[7:0]);
      vec_pkg::SEW16: acc_cut = 64'(acc_next[15:0]);
      vec_pkg::SEW32: acc_cut = 64'(acc_next[31:0]);
      default: acc_cut = acc_next;
    endcase
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s3_valid;
    if (s3_valid) acc_q <= acc_next;
    o_acc <= acc_cut;
  end

endmodule
