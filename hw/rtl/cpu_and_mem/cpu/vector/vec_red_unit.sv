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
  i_init. Inactive elements are bypassed by per-node active flags rather than
  substituting 64-bit identities. o_acc holds the reduction of vs1[0] and every
  active element up to and including the step, so the last step's value is the
  result: SEW bits wide, or 2*SEW bits for the widening sums, zero-extended to
  64 bits.

  Element positions that can only be active at narrow SEWs use narrow datapaths
  through the tree (8/10/11 bits for elements 4..7, 16/17 bits for elements
  2..3, 32 bits for element 1) before extending to 64 bits where they join
  element 0. Each combine node shares one comparator across signed and unsigned
  min/max. Every step's output appears a fixed five cycles after the cycle that
  takes its input.
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

  function automatic logic [9:0] combine10(input vec_pkg::red_op_e op, input logic [9:0] x,
                                           input logic [9:0] y);
    logic sgn, want_max, lt, take_y;
    logic [9:0] xc, yc;
    sgn = (op == vec_pkg::VR_MIN) || (op == vec_pkg::VR_MAX);
    want_max = (op == vec_pkg::VR_MAXU) || (op == vec_pkg::VR_MAX);
    xc = {x[9] ^ sgn, x[8:0]};
    yc = {y[9] ^ sgn, y[8:0]};
    lt = xc < yc;
    take_y = want_max ? lt : !lt;
    unique case (op)
      vec_pkg::VR_AND: combine10 = x & y;
      vec_pkg::VR_OR:  combine10 = x | y;
      vec_pkg::VR_XOR: combine10 = x ^ y;
      vec_pkg::VR_MINU, vec_pkg::VR_MIN, vec_pkg::VR_MAXU, vec_pkg::VR_MAX:
      combine10 = take_y ? y : x;
      default: combine10 = x + y;
    endcase
  endfunction

  function automatic logic [10:0] combine11(input vec_pkg::red_op_e op, input logic [10:0] x,
                                            input logic [10:0] y);
    logic sgn, want_max, lt, take_y;
    logic [10:0] xc, yc;
    sgn = (op == vec_pkg::VR_MIN) || (op == vec_pkg::VR_MAX);
    want_max = (op == vec_pkg::VR_MAXU) || (op == vec_pkg::VR_MAX);
    xc = {x[10] ^ sgn, x[9:0]};
    yc = {y[10] ^ sgn, y[9:0]};
    lt = xc < yc;
    take_y = want_max ? lt : !lt;
    unique case (op)
      vec_pkg::VR_AND: combine11 = x & y;
      vec_pkg::VR_OR:  combine11 = x | y;
      vec_pkg::VR_XOR: combine11 = x ^ y;
      vec_pkg::VR_MINU, vec_pkg::VR_MIN, vec_pkg::VR_MAXU, vec_pkg::VR_MAX:
      combine11 = take_y ? y : x;
      default: combine11 = x + y;
    endcase
  endfunction

  function automatic logic [16:0] combine17(input vec_pkg::red_op_e op, input logic [16:0] x,
                                            input logic [16:0] y);
    logic sgn, want_max, lt, take_y;
    logic [16:0] xc, yc;
    sgn = (op == vec_pkg::VR_MIN) || (op == vec_pkg::VR_MAX);
    want_max = (op == vec_pkg::VR_MAXU) || (op == vec_pkg::VR_MAX);
    xc = {x[16] ^ sgn, x[15:0]};
    yc = {y[16] ^ sgn, y[15:0]};
    lt = xc < yc;
    take_y = want_max ? lt : !lt;
    unique case (op)
      vec_pkg::VR_AND: combine17 = x & y;
      vec_pkg::VR_OR:  combine17 = x | y;
      vec_pkg::VR_XOR: combine17 = x ^ y;
      vec_pkg::VR_MINU, vec_pkg::VR_MIN, vec_pkg::VR_MAXU, vec_pkg::VR_MAX:
      combine17 = take_y ? y : x;
      default: combine17 = x + y;
    endcase
  endfunction

  function automatic logic [63:0] combine64(input vec_pkg::red_op_e op, input logic [63:0] x,
                                            input logic [63:0] y);
    logic sgn, want_max, lt, take_y;
    logic [63:0] xc, yc;
    sgn = (op == vec_pkg::VR_MIN) || (op == vec_pkg::VR_MAX);
    want_max = (op == vec_pkg::VR_MAXU) || (op == vec_pkg::VR_MAX);
    xc = {x[63] ^ sgn, x[62:0]};
    yc = {y[63] ^ sgn, y[62:0]};
    lt = xc < yc;
    take_y = want_max ? lt : !lt;
    unique case (op)
      vec_pkg::VR_AND: combine64 = x & y;
      vec_pkg::VR_OR:  combine64 = x | y;
      vec_pkg::VR_XOR: combine64 = x ^ y;
      vec_pkg::VR_MINU, vec_pkg::VR_MIN, vec_pkg::VR_MAXU, vec_pkg::VR_MAX:
      combine64 = take_y ? y : x;
      default: combine64 = x + y;
    endcase
  endfunction

  // Extend element 0 of a word at width sew to 64 bits.
  function automatic logic [63:0] elem0_ext(input logic [63:0] word, input vec_pkg::sew_e sew,
                                            input logic sgn);
    unique case (sew)
      vec_pkg::SEW8:  elem0_ext = sgn ? 64'($signed(word[7:0])) : 64'(word[7:0]);
      vec_pkg::SEW16: elem0_ext = sgn ? 64'($signed(word[15:0])) : 64'(word[15:0]);
      vec_pkg::SEW32: elem0_ext = sgn ? 64'($signed(word[31:0])) : 64'(word[31:0]);
      default:        elem0_ext = word;
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
    s0_op    <= i_op;
    s0_sew   <= i_sew;
    s0_word  <= i_word;
    s0_init  <= i_init;
    s0_act   <= i_act;
  end

  // Per-position element extraction and active flags.
  logic [ 7:0] e_act_d;
  logic [63:0] e0_d;
  logic [31:0] e1_d;
  logic [15:0] e2_d, e3_d;
  logic [7:0] e4_d, e5_d, e6_d, e7_d;
  logic [63:0] init_ext;
  always_comb begin
    logic sgn;
    logic [3:0] nelem;
    vec_pkg::sew_e w;
    sgn = is_signed(s0_op);
    unique case (s0_sew)
      vec_pkg::SEW8:  nelem = 4'd8;
      vec_pkg::SEW16: nelem = 4'd4;
      vec_pkg::SEW32: nelem = 4'd2;
      default:        nelem = 4'd1;
    endcase
    for (int k = 0; k < 8; k++) e_act_d[k] = (k < int'(nelem)) && s0_act[k];

    e0_d = elem0_ext(s0_word, s0_sew, sgn);
    unique case (s0_sew)
      vec_pkg::SEW8:  e1_d = sgn ? 32'($signed(s0_word[15:8])) : 32'(s0_word[15:8]);
      vec_pkg::SEW16: e1_d = sgn ? 32'($signed(s0_word[31:16])) : 32'(s0_word[31:16]);
      default:        e1_d = s0_word[63:32];
    endcase
    if (s0_sew == vec_pkg::SEW8) begin
      e2_d = sgn ? 16'($signed(s0_word[23:16])) : 16'(s0_word[23:16]);
      e3_d = sgn ? 16'($signed(s0_word[31:24])) : 16'(s0_word[31:24]);
    end else begin
      e2_d = s0_word[47:32];
      e3_d = s0_word[63:48];
    end
    e4_d = s0_word[39:32];
    e5_d = s0_word[47:40];
    e6_d = s0_word[55:48];
    e7_d = s0_word[63:56];

    // The scalar operand, extended like the elements: vs1[0] is SEW wide, or
    // 2*SEW wide for the widening sums.
    w = s0_sew;
    if (s0_op == vec_pkg::VR_WSUMU || s0_op == vec_pkg::VR_WSUM)
      w = (s0_sew == vec_pkg::SEW64) ? vec_pkg::SEW64 : vec_pkg::sew_e'(s0_sew + 2'd1);
    init_ext = elem0_ext(s0_init, w, sgn);
  end

  logic se_valid, se_first;
  vec_pkg::red_op_e se_op;
  vec_pkg::sew_e se_sew;
  logic [ 7:0] se_act;
  logic [63:0] se_e0, se_init;
  logic [31:0] se_e1;
  logic [15:0] se_e2, se_e3;
  logic [7:0] se_e4, se_e5, se_e6, se_e7;
  always_ff @(posedge i_clk) begin
    if (i_rst) se_valid <= 1'b0;
    else se_valid <= s0_valid;
    se_first <= s0_first;
    se_op    <= s0_op;
    se_sew   <= s0_sew;
    se_act   <= e_act_d;
    se_e0    <= e0_d;
    se_e1    <= e1_d;
    se_e2    <= e2_d;
    se_e3    <= e3_d;
    se_e4    <= e4_d;
    se_e5    <= e5_d;
    se_e6    <= e6_d;
    se_e7    <= e7_d;
    se_init  <= init_ext;
  end

  // Tree level 1.
  logic se_sgn;
  logic [63:0] se_e1_64, s1_l0_d;
  logic [16:0] se_e2_17, se_e3_17, s1_l1_d;
  logic [9:0] se_e4_10, se_e5_10, se_e6_10, se_e7_10, s1_l2_d, s1_l3_d;
  assign se_sgn   = is_signed(se_op);
  assign se_e1_64 = se_sgn ? 64'($signed(se_e1)) : 64'(se_e1);
  assign se_e2_17 = se_sgn ? 17'($signed(se_e2)) : 17'(se_e2);
  assign se_e3_17 = se_sgn ? 17'($signed(se_e3)) : 17'(se_e3);
  assign se_e4_10 = se_sgn ? 10'($signed(se_e4)) : 10'(se_e4);
  assign se_e5_10 = se_sgn ? 10'($signed(se_e5)) : 10'(se_e5);
  assign se_e6_10 = se_sgn ? 10'($signed(se_e6)) : 10'(se_e6);
  assign se_e7_10 = se_sgn ? 10'($signed(se_e7)) : 10'(se_e7);
  assign s1_l0_d  = !se_act[0] ? se_e1_64 : (!se_act[1] ? se_e0 : combine64(se_op, se_e0, se_e1_64));
  assign s1_l1_d  = !se_act[2] ? se_e3_17 : (!se_act[3] ? se_e2_17 : combine17(
      se_op, se_e2_17, se_e3_17
  ));
  assign s1_l2_d  = !se_act[4] ? se_e5_10 : (!se_act[5] ? se_e4_10 : combine10(
      se_op, se_e4_10, se_e5_10
  ));
  assign s1_l3_d  = !se_act[6] ? se_e7_10 : (!se_act[7] ? se_e6_10 : combine10(
      se_op, se_e6_10, se_e7_10
  ));

  logic s1_valid, s1_first;
  vec_pkg::red_op_e s1_op;
  vec_pkg::sew_e s1_sew;
  logic [ 3:0] s1_act;
  logic [63:0] s1_l0, s1_init;
  logic [16:0] s1_l1;
  logic [ 9:0] s1_l2, s1_l3;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= se_valid;
    s1_first  <= se_first;
    s1_op     <= se_op;
    s1_sew    <= se_sew;
    s1_act[0] <= se_act[0] || se_act[1];
    s1_act[1] <= se_act[2] || se_act[3];
    s1_act[2] <= se_act[4] || se_act[5];
    s1_act[3] <= se_act[6] || se_act[7];
    s1_l0     <= s1_l0_d;
    s1_l1     <= s1_l1_d;
    s1_l2     <= s1_l2_d;
    s1_l3     <= s1_l3_d;
    s1_init   <= se_init;
  end

  // Tree level 2.
  logic s1_sgn;
  logic [63:0] s1_l1_64, s2_l0_d;
  logic [10:0] s1_l2_11, s1_l3_11, s2_l1_d;
  assign s1_sgn   = is_signed(s1_op);
  assign s1_l1_64 = s1_sgn ? 64'($signed(s1_l1)) : 64'(s1_l1);
  assign s1_l2_11 = s1_sgn ? 11'($signed(s1_l2)) : 11'(s1_l2);
  assign s1_l3_11 = s1_sgn ? 11'($signed(s1_l3)) : 11'(s1_l3);
  assign s2_l0_d  = !s1_act[0] ? s1_l1_64 : (!s1_act[1] ? s1_l0 : combine64(s1_op, s1_l0, s1_l1_64));
  assign s2_l1_d  = !s1_act[2] ? s1_l3_11 : (!s1_act[3] ? s1_l2_11 : combine11(
      s1_op, s1_l2_11, s1_l3_11
  ));

  logic s2_valid, s2_first;
  vec_pkg::red_op_e s2_op;
  vec_pkg::sew_e s2_sew;
  logic [ 1:0] s2_act;
  logic [63:0] s2_l0, s2_init;
  logic [10:0] s2_l1;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
    s2_first  <= s1_first;
    s2_op     <= s1_op;
    s2_sew    <= s1_sew;
    s2_act[0] <= s1_act[0] || s1_act[1];
    s2_act[1] <= s1_act[2] || s1_act[3];
    s2_l0     <= s2_l0_d;
    s2_l1     <= s2_l1_d;
    s2_init   <= s1_init;
  end

  // Tree level 3.
  logic s2_sgn;
  logic [63:0] s2_l1_64, s3_word_d;
  assign s2_sgn    = is_signed(s2_op);
  assign s2_l1_64  = s2_sgn ? 64'($signed(s2_l1)) : 64'(s2_l1);
  assign s3_word_d = !s2_act[0] ? s2_l1_64 : (!s2_act[1] ? s2_l0 : combine64(
      s2_op, s2_l0, s2_l1_64
  ));

  logic s3_valid, s3_first, s3_act;
  vec_pkg::red_op_e s3_op;
  vec_pkg::sew_e s3_sew;
  logic [63:0] s3_word, s3_init;
  always_ff @(posedge i_clk) begin
    if (i_rst) s3_valid <= 1'b0;
    else s3_valid <= s2_valid;
    s3_first <= s2_first;
    s3_op    <= s2_op;
    s3_sew   <= s2_sew;
    s3_act   <= s2_act[0] || s2_act[1];
    s3_word  <= s3_word_d;
    s3_init  <= s2_init;
  end

  // The running value: the scalar operand on an instruction's first step.
  logic [63:0] acc_q, acc_in, acc_next, acc_cut;
  assign acc_in   = s3_first ? s3_init : acc_q;
  assign acc_next = s3_act ? combine64(s3_op, acc_in, s3_word) : acc_in;
  always_comb begin
    vec_pkg::sew_e w;
    w = s3_sew;
    if (s3_op == vec_pkg::VR_WSUMU || s3_op == vec_pkg::VR_WSUM)
      w = (s3_sew == vec_pkg::SEW64) ? vec_pkg::SEW64 : vec_pkg::sew_e'(s3_sew + 2'd1);
    unique case (w)
      vec_pkg::SEW8:  acc_cut = 64'(acc_next[7:0]);
      vec_pkg::SEW16: acc_cut = 64'(acc_next[15:0]);
      vec_pkg::SEW32: acc_cut = 64'(acc_next[31:0]);
      default:        acc_cut = acc_next;
    endcase
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s3_valid;
    if (s3_valid) acc_q <= acc_next;
    o_acc <= acc_cut;
  end

endmodule
