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
  The SHA-2 block of the vector unit (Zvknha with SEW 32, Zvknhb with SEW 64)
  for one element group of four words: vsha2ms, vsha2cl and vsha2ch. Words
  are SEW wide, element k at bits SEW*k, and only the low 128 bits are used
  at SEW 32.

  vsha2ms takes W[0..3] in i_vd, {W[4], W[9], W[10], W[11]} in i_vs2 and
  W[12..15] in i_vs1 and returns W[16..19]. vsha2cl and vsha2ch take the state
  {h, g, d, c} in i_vd and {f, e, b, a} in i_vs2, run two rounds with the
  message-plus-constant words 0 and 1 (cl) or 2 and 3 (ch) of i_vs1, and return
  the new {f, e, b, a}.

  Each round's sums are formed with carry-save adders and one carry adder:
  the first cycle forms one round's sigma, choice and majority terms, the next
  its new a and e, and two more cycles do the second round, as the message
  schedule's two dependent pairs of words do. Every result appears a fixed four
  cycles after the cycle that takes the input, for any data (Zvkt).
*/
module vec_sha2_group (
    input  logic                     i_clk,
    input  logic                     i_rst,
    input  logic                     i_valid,
    input  vec_pkg::sha_op_e         i_op,
    input  logic                     i_sew64,
    input  logic             [255:0] i_vd,
    input  logic             [255:0] i_vs2,
    input  logic             [255:0] i_vs1,
    output logic                     o_valid,
    output logic             [255:0] o_result
);


  function automatic logic [63:0] ror(input logic [63:0] x, input int n, input logic w64);
    if (w64) ror = (x >> n) | (x << (64 - n));
    else ror = 64'(32'((x[31:0] >> n) | (x[31:0] << (32 - n))));
  endfunction

  function automatic logic [63:0] big_sigma0(input logic [63:0] x, input logic w64);
    big_sigma0 = w64 ? (ror(x, 28, 1) ^ ror(x, 34, 1) ^ ror(x, 39, 1)) :
        (ror(x, 2, 0) ^ ror(x, 13, 0) ^ ror(x, 22, 0));
  endfunction

  function automatic logic [63:0] big_sigma1(input logic [63:0] x, input logic w64);
    big_sigma1 = w64 ? (ror(x, 14, 1) ^ ror(x, 18, 1) ^ ror(x, 41, 1)) :
        (ror(x, 6, 0) ^ ror(x, 11, 0) ^ ror(x, 25, 0));
  endfunction

  function automatic logic [63:0] small_sigma0(input logic [63:0] x, input logic w64);
    small_sigma0 = w64 ? (ror(x, 1, 1) ^ ror(x, 8, 1) ^ (x >> 7)) :
        (ror(x, 7, 0) ^ ror(x, 18, 0) ^ 64'(x[31:0] >> 3));
  endfunction

  function automatic logic [63:0] small_sigma1(input logic [63:0] x, input logic w64);
    small_sigma1 = w64 ? (ror(x, 19, 1) ^ ror(x, 61, 1) ^ (x >> 6)) :
        (ror(x, 17, 0) ^ ror(x, 19, 0) ^ 64'(x[31:0] >> 10));
  endfunction

  // Sum of five words: three carry-save levels and one carry adder.
  function automatic logic [63:0] sum5(input logic [63:0] p, input logic [63:0] q,
                                       input logic [63:0] r, input logic [63:0] s,
                                       input logic [63:0] t);
    logic [63:0] s1, c1, s2, c2, s3, c3;
    s1   = p ^ q ^ r;
    c1   = ((p & q) | (p & r) | (q & r)) << 1;
    s2   = s1 ^ c1 ^ s;
    c2   = ((s1 & c1) | (s1 & s) | (c1 & s)) << 1;
    s3   = s2 ^ c2 ^ t;
    c3   = ((s2 & c2) | (s2 & t) | (c2 & t)) << 1;
    sum5 = s3 + c3;
  endfunction

  // Word k of a 256-bit group at the element width.
  function automatic logic [63:0] word(input logic [255:0] v, input int k, input logic w64);
    word = w64 ? v[64*k+:64] : 64'(v[32*k+:32]);
  endfunction

  logic s0_valid, s0_w64;
  vec_pkg::sha_op_e s0_op;
  logic [255:0] s0_vd, s0_vs2, s0_vs1;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op  <= i_op;
    s0_w64 <= i_sew64;
    s0_vd  <= i_vd;
    s0_vs2 <= i_vs2;
    s0_vs1 <= i_vs1;
  end

  // Unpacked inputs. Rounds: {h, g, d, c} = vd[0..3], {f, e, b, a} =
  // vs2[0..3]. Schedule: W0..W3 = vd, W4 W9 W10 W11 = vs2, W12..W15 = vs1.
  logic [63:0] a, b, c, d, e, f, g, h, wk0, wk1;
  logic [63:0] w[16];
  always_comb begin
    h   = word(s0_vd, 0, s0_w64);
    g   = word(s0_vd, 1, s0_w64);
    d   = word(s0_vd, 2, s0_w64);
    c   = word(s0_vd, 3, s0_w64);
    f   = word(s0_vs2, 0, s0_w64);
    e   = word(s0_vs2, 1, s0_w64);
    b   = word(s0_vs2, 2, s0_w64);
    a   = word(s0_vs2, 3, s0_w64);
    wk0 = word(s0_vs1, (s0_op == vec_pkg::VS_CH) ? 2 : 0, s0_w64);
    wk1 = word(s0_vs1, (s0_op == vec_pkg::VS_CH) ? 3 : 1, s0_w64);
    for (int k = 0; k < 16; k++) w[k] = '0;
    for (int k = 0; k < 4; k++) begin
      w[k] = word(s0_vd, k, s0_w64);
      w[12+k] = word(s0_vs1, k, s0_w64);
    end
    w[4]  = word(s0_vs2, 0, s0_w64);
    w[9]  = word(s0_vs2, 1, s0_w64);
    w[10] = word(s0_vs2, 2, s0_w64);
    w[11] = word(s0_vs2, 3, s0_w64);
  end

  // Stage 1: first-round terms; first schedule terms.
  typedef struct packed {
    logic [63:0] a,  b,  c,   d,  e,   f, g, h, wk1;
    logic [63:0] s0, s1, maj, ch, hwk;
  } round_t;
  logic s1_valid, s1_w64;
  vec_pkg::sha_op_e s1_op;
  round_t s1_r;
  logic [3:0][63:0] s1_m16, s1_m17;
  logic [63:0] s1_w2, s1_w3, s1_w11, s1_w12, s1_sg3, s1_sg4;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_op <= s0_op;
    s1_w64 <= s0_w64;
    s1_r.a <= a;
    s1_r.b <= b;
    s1_r.c <= c;
    s1_r.d <= d;
    s1_r.e <= e;
    s1_r.f <= f;
    s1_r.g <= g;
    s1_r.h <= h;
    s1_r.wk1 <= wk1;
    s1_r.s0 <= big_sigma0(a, s0_w64);
    s1_r.s1 <= big_sigma1(e, s0_w64);
    s1_r.maj <= (a & b) ^ (a & c) ^ (b & c);
    s1_r.ch <= (e & f) ^ (~e & g);
    s1_r.hwk <= h + wk0;
    // W16 = s1(W14) + W9 + s0(W1) + W0; W17 = s1(W15) + W10 + s0(W2) + W1.
    s1_m16 <= {small_sigma1(w[14], s0_w64), w[9], small_sigma0(w[1], s0_w64), w[0]};
    s1_m17 <= {small_sigma1(w[15], s0_w64), w[10], small_sigma0(w[2], s0_w64), w[1]};
    // W18 = s1(W16) + W11 + s0(W3) + W2; W19 = s1(W17) + W12 + s0(W4) + W3.
    s1_w2 <= w[2];
    s1_w3 <= w[3];
    s1_w11 <= w[11];
    s1_w12 <= w[12];
    s1_sg3 <= small_sigma0(w[3], s0_w64);
    s1_sg4 <= small_sigma0(w[4], s0_w64);
  end

  // Stage 2: first-round a and e; W16 and W17.
  logic s2_valid, s2_w64;
  vec_pkg::sha_op_e s2_op;
  logic [63:0] s2_a1, s2_e1, s2_a, s2_b, s2_c, s2_e, s2_f, s2_g, s2_wk1;
  logic [63:0] s2_w16, s2_w17, s2_r18, s2_r19;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
    s2_op  <= s1_op;
    s2_w64 <= s1_w64;
    s2_a1  <= sum5(s1_r.hwk, s1_r.s1, s1_r.ch, s1_r.s0, s1_r.maj);
    s2_e1  <= sum5(s1_r.hwk, s1_r.s1, s1_r.ch, s1_r.d, 64'd0);
    s2_a   <= s1_r.a;
    s2_b   <= s1_r.b;
    s2_c   <= s1_r.c;
    s2_e   <= s1_r.e;
    s2_f   <= s1_r.f;
    s2_g   <= s1_r.g;
    s2_wk1 <= s1_r.wk1;
    s2_w16 <= sum5(s1_m16[0], s1_m16[1], s1_m16[2], s1_m16[3], 64'd0);
    s2_w17 <= sum5(s1_m17[0], s1_m17[1], s1_m17[2], s1_m17[3], 64'd0);
    s2_r18 <= s1_w11 + s1_sg3 + s1_w2;
    s2_r19 <= s1_w12 + s1_sg4 + s1_w3;
  end

  // Stage 3: second-round terms on (a1, a, b, c, e1, e, f, g); sigma1 of
  // W16 and W17.
  logic s3_valid, s3_w64;
  vec_pkg::sha_op_e s3_op;
  logic [63:0] s3_a1, s3_e1, s3_s0, s3_s1, s3_maj, s3_ch, s3_gwk, s3_c;
  logic [63:0] s3_w16, s3_w17, s3_sg16, s3_sg17, s3_r18, s3_r19;
  always_ff @(posedge i_clk) begin
    if (i_rst) s3_valid <= 1'b0;
    else s3_valid <= s2_valid;
    s3_op <= s2_op;
    s3_w64 <= s2_w64;
    s3_a1 <= s2_a1;
    s3_e1 <= s2_e1;
    s3_s0 <= big_sigma0(s2_a1, s2_w64);
    s3_s1 <= big_sigma1(s2_e1, s2_w64);
    s3_maj <= (s2_a1 & s2_a) ^ (s2_a1 & s2_b) ^ (s2_a & s2_b);
    s3_ch <= (s2_e1 & s2_e) ^ (~s2_e1 & s2_f);
    s3_gwk <= s2_g + s2_wk1;
    s3_c <= s2_c;
    s3_w16 <= s2_w16;
    s3_w17 <= s2_w17;
    s3_sg16 <= small_sigma1(s2_w16, s2_w64);
    s3_sg17 <= small_sigma1(s2_w17, s2_w64);
    s3_r18 <= s2_r18;
    s3_r19 <= s2_r19;
  end

  // Stage 4: second-round a and e, W18 and W19, and the packed result.
  logic [63:0] a2, e2, w18, w19;
  logic [255:0] result;
  logic [3:0][63:0] r;
  assign a2  = sum5(s3_gwk, s3_s1, s3_ch, s3_s0, s3_maj);
  assign e2  = sum5(s3_gwk, s3_s1, s3_ch, s3_c, 64'd0);
  assign w18 = s3_sg16 + s3_r18;
  assign w19 = s3_sg17 + s3_r19;
  always_comb begin
    if (s3_op == vec_pkg::VS_MS) r = {w19, w18, s3_w17, s3_w16};
    else r = {a2, s3_a1, e2, s3_e1};  // {a, b, e, f} after two rounds: f in word 0
    result = '0;
    for (int k = 0; k < 4; k++) begin
      if (s3_w64) result[64*k+:64] = r[k];
      else result[32*k+:32] = r[k][31:0];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s3_valid;
    o_result <= result;
  end

endmodule
