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
 * Fully-pipelined Integer Multiplier — RISC-V M-extension multiply operations
 *
 * Implements a 4-cycle latency, 1-op/cycle throughput multiplier for
 * MUL, MULH, MULHSU, MULHU instructions. Takes 33-bit signed inputs and
 * produces a 64-bit result. A new operation may enter every clock cycle.
 *
 * The datapath is explicitly tiled for DSP48E2-friendly mapping and
 * pipelined across 4 register stages so that each stage's combinational
 * depth fits a 300 MHz UltraScale+ budget:
 *
 *   Stage S0 (cycle T → T+1 edge)
 *     - Combinational: convert signed operands to 33-bit magnitudes
 *       (abs_33) and compute the result sign XOR.
 *     - Registered: A_mag, B_mag, neg, vld.
 *     - Critical path: 33-bit conditional negate. Short.
 *
 *   Stage S1 (cycle T+1 → T+2 edge)
 *     - Combinational: split the 33-bit magnitudes into {hi(16), lo(17)}
 *       halves and compute four parallel 17-bit-wide partial products:
 *         P00 = A_lo * B_lo   (17 x 17 -> 34 bits)
 *         P01 = A_lo * B_hi   (17 x 16 -> 33 bits)
 *         P10 = A_hi * B_lo   (16 x 17 -> 33 bits)
 *         P11 = A_hi * B_hi   (16 x 16 -> 32 bits)
 *     - Registered: P00, P01, P10, P11, neg, vld.
 *     - Critical path: one 17 x 17 DSP48E2 tile (fits in a single DSP
 *       combinational multiply; the four tiles run in parallel).
 *
 *   Stage S2 (cycle T+2 → T+3 edge)
 *     - Combinational: partial-sum reduction into two 34-bit operands:
 *         s_mid   = P01 + P10              (34 bits, aligned at shift 17)
 *         s_hi_lo = {P11 at bit 34, P00 at bit 0}  (non-overlapping concat)
 *     - Registered: s_mid, s_hi_lo, neg, vld.
 *     - Critical path: one 34-bit add.
 *
 *   Stage S3 (cycle T+3 → T+4 edge)
 *     - Combinational: final 66-bit add combined with sign correction via
 *       the XOR/carry-in trick:
 *         mask    = {66{neg}}
 *         signed_sum = (s_hi_lo ^ mask) + ((s_mid << 17) ^ mask) + (neg << 1)
 *       which evaluates to  s_hi_lo + (s_mid << 17)  when neg=0 and to
 *       -(s_hi_lo + (s_mid << 17))                    when neg=1, using a
 *       single 3-operand 66-bit add (synthesis maps to a carry-save +
 *       final add, ~2.5 ns on UltraScale+).
 *     - Registered: product (66 bits), vld.
 *
 *   Cycle T+4: o_valid_output=1, o_product_result = product[63:0].
 *
 * Operand Sign Handling (caller in shim):
 *   MUL:    Both operands zero-extended (33'b0, rs1/rs2)
 *   MULH:   Both operands sign-extended ({rs[31], rs})
 *   MULHSU: rs1 sign-extended, rs2 zero-extended
 *   MULHU:  Both operands zero-extended
 */
module multiplier (
    input logic i_clk,
    input logic i_rst,
    input logic signed [32:0] i_operand_a,  // 33-bit signed input
    input logic signed [32:0] i_operand_b,  // 33-bit signed input
    input logic i_valid_input,  // Start multiplication (1 cycle pulse)
    output logic [63:0] o_product_result,  // 64-bit product output (registered)
    output logic o_valid_output,  // Result ready (4 cycles after valid input)
    output logic o_completing_next_cycle  // 1 cycle before o_valid_output
);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic logic [32:0] abs_33(input logic signed [32:0] value);
    abs_33 = value[32] ? (~value + 33'd1) : value;
  endfunction

  // 17-bit / 16-bit halves of a 33-bit magnitude.
  localparam int unsigned LoW = 17;
  localparam int unsigned HiW = 16;

  // ---------------------------------------------------------------------------
  // Stage S0 — capture magnitudes + sign
  // ---------------------------------------------------------------------------
  logic [32:0] a_mag_comb, b_mag_comb;
  logic neg_comb;

  assign a_mag_comb = abs_33(i_operand_a);
  assign b_mag_comb = abs_33(i_operand_b);
  assign neg_comb   = i_operand_a[32] ^ i_operand_b[32];

  logic [32:0] a_mag_s0_reg, b_mag_s0_reg;
  logic neg_s0_reg;
  logic vld_s0_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vld_s0_reg <= 1'b0;
    end else begin
      vld_s0_reg <= i_valid_input;
    end
  end

  always_ff @(posedge i_clk) begin
    a_mag_s0_reg <= a_mag_comb;
    b_mag_s0_reg <= b_mag_comb;
    neg_s0_reg   <= neg_comb;
  end

  // ---------------------------------------------------------------------------
  // Stage S1 — DSP48E2-shaped 17x17 / 17x16 / 16x17 / 16x16 partial products
  // ---------------------------------------------------------------------------
  logic [LoW-1:0] a_lo, b_lo;
  logic [HiW-1:0] a_hi, b_hi;

  assign a_lo = a_mag_s0_reg[LoW-1:0];
  assign a_hi = a_mag_s0_reg[LoW+HiW-1:LoW];
  assign b_lo = b_mag_s0_reg[LoW-1:0];
  assign b_hi = b_mag_s0_reg[LoW+HiW-1:LoW];

  (* use_dsp = "yes" *)logic [LoW+LoW-1:0] p00_comb;  // 34 bits
  (* use_dsp = "yes" *)logic [LoW+HiW-1:0] p01_comb;  // 33 bits
  (* use_dsp = "yes" *)logic [HiW+LoW-1:0] p10_comb;  // 33 bits
  (* use_dsp = "yes" *)logic [HiW+HiW-1:0] p11_comb;  // 32 bits

  assign p00_comb = a_lo * b_lo;
  assign p01_comb = a_lo * b_hi;
  assign p10_comb = a_hi * b_lo;
  assign p11_comb = a_hi * b_hi;

  logic [LoW+LoW-1:0] p00_s1_reg;
  logic [LoW+HiW-1:0] p01_s1_reg;
  logic [HiW+LoW-1:0] p10_s1_reg;
  logic [HiW+HiW-1:0] p11_s1_reg;
  logic               neg_s1_reg;
  logic               vld_s1_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vld_s1_reg <= 1'b0;
    end else begin
      vld_s1_reg <= vld_s0_reg;
    end
  end

  always_ff @(posedge i_clk) begin
    p00_s1_reg <= p00_comb;
    p01_s1_reg <= p01_comb;
    p10_s1_reg <= p10_comb;
    p11_s1_reg <= p11_comb;
    neg_s1_reg <= neg_s0_reg;
  end

  // ---------------------------------------------------------------------------
  // Stage S2 — partial-sum reduction
  //
  //   s_mid   = P01 + P10                   (34 bits, shift-17 lane)
  //   s_hi_lo = {P11 at bit 34, P00 at bit 0}
  //
  // P00 (34 bits, [33:0]) and P11 (32 bits, [65:34]) occupy disjoint bit
  // positions in the final 66-bit sum, so s_hi_lo is a pure concat, not
  // an addition.
  // ---------------------------------------------------------------------------
  logic [LoW+HiW:0] s_mid_comb;  // 34 bits (33-bit + 33-bit add)
  logic [     65:0] s_hi_lo_comb;  // 66 bits ({P11, P00})

  assign s_mid_comb   = {1'b0, p01_s1_reg} + {1'b0, p10_s1_reg};
  assign s_hi_lo_comb = {p11_s1_reg, p00_s1_reg};

  logic [LoW+HiW:0] s_mid_s2_reg;
  logic [     65:0] s_hi_lo_s2_reg;
  logic             neg_s2_reg;
  logic             vld_s2_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vld_s2_reg <= 1'b0;
    end else begin
      vld_s2_reg <= vld_s1_reg;
    end
  end

  always_ff @(posedge i_clk) begin
    s_mid_s2_reg   <= s_mid_comb;
    s_hi_lo_s2_reg <= s_hi_lo_comb;
    neg_s2_reg     <= neg_s1_reg;
  end

  // ---------------------------------------------------------------------------
  // Stage S3 — final 66-bit add fused with sign correction
  //
  // Identity used:
  //   -(a + b) = (~a + ~b) + 2
  //            = (a ^ 1s) + (b ^ 1s) + 2
  //
  // With mask = {66{neg}}:
  //   result = (a ^ mask) + (b ^ mask) + (neg << 1)
  //          = a + b             when neg = 0
  //          = -(a + b)          when neg = 1
  //
  // This is a single 3-operand 66-bit add — synthesis maps it to one
  // carry-save layer plus a 66-bit final add (~2.5 ns on UltraScale+).
  // No separate conditional-negation stage is needed.
  // ---------------------------------------------------------------------------
  logic [65:0] s_shifted_mid_comb;
  logic [65:0] mask_comb;
  logic [65:0] addend_a_comb, addend_b_comb;
  logic [65:0] extra_comb;
  logic [65:0] signed_full_comb;

  assign s_shifted_mid_comb = 66'(s_mid_s2_reg) << LoW;
  assign mask_comb          = {66{neg_s2_reg}};
  assign addend_a_comb      = s_hi_lo_s2_reg ^ mask_comb;
  assign addend_b_comb      = s_shifted_mid_comb ^ mask_comb;
  assign extra_comb         = {64'b0, neg_s2_reg, 1'b0};  // 2*neg
  assign signed_full_comb   = addend_a_comb + addend_b_comb + extra_comb;

  logic [65:0] prod_s3_reg;
  logic        vld_s3_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vld_s3_reg <= 1'b0;
    end else begin
      vld_s3_reg <= vld_s2_reg;
    end
  end

  always_ff @(posedge i_clk) begin
    prod_s3_reg <= signed_full_comb;
  end

  assign o_product_result        = prod_s3_reg[63:0];
  assign o_valid_output          = vld_s3_reg;
  assign o_completing_next_cycle = vld_s2_reg;

endmodule : multiplier
