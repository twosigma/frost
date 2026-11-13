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
  The GHASH block of the vector unit (Zvkg) for one 128-bit element group:
  vghsh.vv computes (Y ^ X) * H and vgmul.vv computes Y * H in GF(2^128) with
  the GCM polynomial x^128 + x^7 + x^2 + x + 1, where Y is i_vd, H is i_vs2 and
  X is i_vs1. As the specification defines, each byte's bits are reversed on
  the way in and out, so bit i of a reversed operand is the coefficient of x^i.

  Four carry-less multiply lanes form the four 64x64 partial products of the
  128-bit operands, and one cycle folds the 256-bit product back to 128 bits.
  The result appears a fixed four cycles after the cycle that takes the input,
  for any data (Zvkt).
*/
module vec_ghash_group (
    input  logic         i_clk,
    input  logic         i_rst,
    input  logic         i_valid,
    input  logic         i_gmul,   // vgmul.vv (no X); vghsh.vv otherwise
    input  logic [127:0] i_vd,
    input  logic [127:0] i_vs2,
    input  logic [127:0] i_vs1,
    output logic         o_valid,
    output logic [127:0] o_result
);

  // Reverse the bits of every byte.
  function automatic logic [127:0] brev8(input logic [127:0] x);
    for (int i = 0; i < 16; i++) for (int j = 0; j < 8; j++) brev8[8*i+j] = x[8*i+7-j];
  endfunction

  // Stage 0: the operands in coefficient order.
  logic s0_valid;
  logic [127:0] s0_s, s0_h;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_s <= brev8(i_gmul ? i_vd : (i_vd ^ i_vs1));
    s0_h <= brev8(i_vs2);
  end

  // The four partial products, two cycles later.
  logic [127:0] p_ll, p_lh, p_hl, p_hh;
  logic lane_valid;
  vec_clmul_lane u_ll (
      .i_clk,
      .i_rst,
      .i_valid(s0_valid),
      .i_high(1'b0),
      .i_a(s0_s[63:0]),
      .i_b(s0_h[63:0]),
      .o_valid(lane_valid),
      .o_result(),
      .o_product(p_ll)
  );
  vec_clmul_lane u_lh (
      .i_clk,
      .i_rst,
      .i_valid(1'b0),
      .i_high(1'b0),
      .i_a(s0_s[63:0]),
      .i_b(s0_h[127:64]),
      .o_valid(),
      .o_result(),
      .o_product(p_lh)
  );
  vec_clmul_lane u_hl (
      .i_clk,
      .i_rst,
      .i_valid(1'b0),
      .i_high(1'b0),
      .i_a(s0_s[127:64]),
      .i_b(s0_h[63:0]),
      .o_valid(),
      .o_result(),
      .o_product(p_hl)
  );
  vec_clmul_lane u_hh (
      .i_clk,
      .i_rst,
      .i_valid(1'b0),
      .i_high(1'b0),
      .i_a(s0_s[127:64]),
      .i_b(s0_h[127:64]),
      .o_valid(),
      .o_result(),
      .o_product(p_hh)
  );

  // Fold the 256-bit product modulo x^128 + x^7 + x^2 + x + 1: each set bit
  // at or above 128 clears itself and adds x^7 + x^2 + x + 1 shifted to it.
  logic [255:0] full, folded;
  always_comb begin
    full   = {128'b0, p_ll} ^ ({128'b0, p_lh} << 64) ^ ({128'b0, p_hl} << 64) ^ ({p_hh, 128'b0});
    folded = full;
    for (int i = 255; i >= 128; i--) begin
      folded[i-128] = folded[i-128] ^ folded[i];
      folded[i-127] = folded[i-127] ^ folded[i];
      folded[i-126] = folded[i-126] ^ folded[i];
      folded[i-121] = folded[i-121] ^ folded[i];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= lane_valid;
    o_result <= brev8(folded[127:0]);
  end

endmodule
