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
  One 64-bit multiply lane of the vector unit at SEW 8, 16, 32 or 64. It forms
  every element's full 2*SEW-bit product of x and y with the signedness the
  operation selects, and returns the low or high SEW bits (vmul, vmulh,
  vmulhu, vmulhsu) or z plus or minus the low bits (vmacc, vnmsac and, with
  the operands chosen by the sequencer, vmadd and vnmsub). o_wide holds the
  full products of the lane's elements for the widening
  multiplies, element k at bits 2*SEW*k; vwmul, vwmulu and vwmulsu use vec_pkg::VM_MULH,
  vec_pkg::VM_MULHU and vec_pkg::VM_MULHSU for their signedness. Every result appears a fixed
  six cycles after the cycle that takes the input, whatever the operation
  and operands.

  SEW 16, 32 and 64 share four 33x33 signed multipliers (one 17x17 slice each
  at SEW 16, two 33x33 slices at SEW 32, and the four 32-bit quadrant products
  at SEW 64), while SEW 8 uses eight 9x9 signed products. Operands are
  registered before the multipliers, followed by three multiplier pipeline
  stages, one product-assembly register stage, and the final output/accumulate
  register stage.
*/
module vec_mul_lane (
    input  logic                     i_clk,
    input  logic                     i_rst,
    input  logic                     i_valid,
    input  vec_pkg::mul_op_e         i_op,
    input  vec_pkg::sew_e            i_sew,
    input  logic             [ 63:0] i_x,
    input  logic             [ 63:0] i_y,
    input  logic             [ 63:0] i_z,
    output logic                     o_valid,
    output logic             [ 63:0] o_result,
    output logic             [127:0] o_wide
);


  // Stage 0: input registers.
  logic s0_valid;
  vec_pkg::mul_op_e s0_op;
  vec_pkg::sew_e s0_sew;
  logic [63:0] s0_x, s0_y, s0_z;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op  <= i_op;
    s0_sew <= i_sew;
    s0_x   <= i_x;
    s0_y   <= i_y;
    s0_z   <= i_z;
  end

  // x is signed for MULH and MULHSU, y only for MULH; the low-half results
  // (MUL, MACC, NMSAC) are the same for any signedness. Stage A prepares and
  // registers the four 33-bit signed multiplier operands (shared by SEW 16,
  // 32 and 64) and the eight 9-bit signed operands for SEW 8.
  logic x_signed, y_signed;
  assign x_signed = (s0_op == vec_pkg::VM_MULH) || (s0_op == vec_pkg::VM_MULHSU);
  assign y_signed = (s0_op == vec_pkg::VM_MULH);

  logic signed [32:0] ax_d[4], ay_d[4];
  logic signed [8:0] a8x_d[8], a8y_d[8];
  always_comb begin
    for (int e = 0; e < 8; e++) begin
      a8x_d[e] = $signed({x_signed & s0_x[8*e+7], s0_x[8*e+:8]});
      a8y_d[e] = $signed({y_signed & s0_y[8*e+7], s0_y[8*e+:8]});
    end
    for (int k = 0; k < 4; k++) begin
      ax_d[k] = '0;
      ay_d[k] = '0;
    end
    unique case (s0_sew)
      vec_pkg::SEW8, vec_pkg::SEW16: begin
        for (int k = 0; k < 4; k++) begin
          ax_d[k] = $signed({{17{x_signed & s0_x[16*k+15]}}, s0_x[16*k+:16]});
          ay_d[k] = $signed({{17{y_signed & s0_y[16*k+15]}}, s0_y[16*k+:16]});
        end
      end
      vec_pkg::SEW32: begin
        ax_d[0] = $signed({x_signed & s0_x[31], s0_x[31:0]});
        ay_d[0] = $signed({y_signed & s0_y[31], s0_y[31:0]});
        ax_d[1] = $signed({x_signed & s0_x[63], s0_x[63:32]});
        ay_d[1] = $signed({y_signed & s0_y[63], s0_y[63:32]});
      end
      default: begin  // SEW64: X = X_hi * 2^32 + X_lo, Y = Y_hi * 2^32 + Y_lo
        ax_d[0] = $signed({1'b0, s0_x[31:0]});
        ay_d[0] = $signed({1'b0, s0_y[31:0]});
        ax_d[1] = $signed({x_signed & s0_x[63], s0_x[63:32]});
        ay_d[1] = $signed({y_signed & s0_y[63], s0_y[63:32]});
        ax_d[2] = $signed({1'b0, s0_x[31:0]});
        ay_d[2] = $signed({y_signed & s0_y[63], s0_y[63:32]});
        ax_d[3] = $signed({x_signed & s0_x[63], s0_x[63:32]});
        ay_d[3] = $signed({1'b0, s0_y[31:0]});
      end
    endcase
  end

  logic sa_valid;
  vec_pkg::mul_op_e sa_op;
  vec_pkg::sew_e sa_sew;
  logic [63:0] sa_z;
  logic signed [32:0] sa_ax[4], sa_ay[4];
  logic signed [8:0] sa_a8x[8], sa_a8y[8];
  always_ff @(posedge i_clk) begin
    if (i_rst) sa_valid <= 1'b0;
    else sa_valid <= s0_valid;
    sa_op  <= s0_op;
    sa_sew <= s0_sew;
    sa_z   <= s0_z;
    sa_ax  <= ax_d;
    sa_ay  <= ay_d;
    sa_a8x <= a8x_d;
    sa_a8y <= a8y_d;
  end

  // Four shared 33x33 signed products and eight 9x9 signed products.
  logic signed [65:0] m_comb[4];
  logic [127:0] p8_comb;
  always_comb begin
    for (int k = 0; k < 4; k++) m_comb[k] = sa_ax[k] * sa_ay[k];
    for (int e = 0; e < 8; e++) begin
      logic signed [17:0] pe;
      pe = sa_a8x[e] * sa_a8y[e];
      p8_comb[16*e+:16] = pe[15:0];
    end
  end

  // Multiplier pipeline: MulStages register stages absorbed into the DSP
  // cascades, followed by one stage that combines the partial products into
  // a single 128-bit packed product register.
  localparam int MulStages = 3;
  logic pv[MulStages];
  vec_pkg::mul_op_e pop[MulStages];
  vec_pkg::sew_e psew[MulStages];
  logic [63:0] pz[MulStages];
  logic signed [65:0] pm[MulStages][4];
  logic [127:0] pp8[MulStages];
  always_ff @(posedge i_clk) begin
    if (i_rst) for (int k = 0; k < MulStages; k++) pv[k] <= 1'b0;
    else begin
      pv[0] <= sa_valid;
      for (int k = 1; k < MulStages; k++) pv[k] <= pv[k-1];
    end
    pop[0]  <= sa_op;
    psew[0] <= sa_sew;
    pz[0]   <= sa_z;
    pm[0]   <= m_comb;
    pp8[0]  <= p8_comb;
    for (int k = 1; k < MulStages; k++) begin
      pop[k]  <= pop[k-1];
      psew[k] <= psew[k-1];
      pz[k]   <= pz[k-1];
      pm[k]   <= pm[k-1];
      pp8[k]  <= pp8[k-1];
    end
  end

  // Stage 2: combine SEW64 quadrants and pack the selected width's products
  // into one 128-bit register before the final accumulate stage.
  logic [95:0] p64_mid;
  logic [127:0] p64, prod_next;
  assign p64_mid = 96'($signed(pm[MulStages-1][2])) + 96'($signed(pm[MulStages-1][3]));
  assign p64 = {64'd0, pm[MulStages-1][0][63:0]} + {p64_mid, 32'd0} +
               {pm[MulStages-1][1][63:0], 64'd0};
  always_comb begin
    unique case (psew[MulStages-1])
      vec_pkg::SEW8: prod_next = pp8[MulStages-1];
      vec_pkg::SEW16:
      prod_next = {
        pm[MulStages-1][3][31:0],
        pm[MulStages-1][2][31:0],
        pm[MulStages-1][1][31:0],
        pm[MulStages-1][0][31:0]
      };
      vec_pkg::SEW32: prod_next = {pm[MulStages-1][1][63:0], pm[MulStages-1][0][63:0]};
      default: prod_next = p64;
    endcase
  end

  logic s2_valid;
  vec_pkg::mul_op_e s2_op;
  vec_pkg::sew_e s2_sew;
  logic [63:0] s2_z;
  logic [127:0] s2_prod;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= pv[MulStages-1];
    s2_op   <= pop[MulStages-1];
    s2_sew  <= psew[MulStages-1];
    s2_z    <= pz[MulStages-1];
    s2_prod <= prod_next;
  end

  // Final stage: low or high halves, the accumulate, and the wide products.
  logic [63:0] lo, hi;
  always_comb begin
    lo = '0;
    hi = '0;
    unique case (s2_sew)
      vec_pkg::SEW8:
      for (int e = 0; e < 8; e++) begin
        lo[8*e+:8] = s2_prod[16*e+:8];
        hi[8*e+:8] = s2_prod[16*e+8+:8];
      end
      vec_pkg::SEW16:
      for (int e = 0; e < 4; e++) begin
        lo[16*e+:16] = s2_prod[32*e+:16];
        hi[16*e+:16] = s2_prod[32*e+16+:16];
      end
      vec_pkg::SEW32:
      for (int e = 0; e < 2; e++) begin
        lo[32*e+:32] = s2_prod[64*e+:32];
        hi[32*e+:32] = s2_prod[64*e+32+:32];
      end
      default: begin
        lo = s2_prod[63:0];
        hi = s2_prod[127:64];
      end
    endcase
  end

  // z + lo or z - lo per element: the 72-bit separator adder of
  // vec_int_lane, with the subtrahend inverted and a carry-in of 1.
  logic [7:0] tops;
  always_comb begin
    unique case (s2_sew)
      vec_pkg::SEW8:  tops = 8'b1111_1111;
      vec_pkg::SEW16: tops = 8'b1010_1010;
      vec_pkg::SEW32: tops = 8'b1000_1000;
      default:        tops = 8'b1000_0000;
    endcase
  end
  logic sub;
  logic [63:0] acc_y;
  logic [71:0] ext_x, ext_y, ext_sum;
  logic [63:0] acc;
  assign sub   = (s2_op == vec_pkg::VM_NMSAC);
  assign acc_y = sub ? ~lo : lo;
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      ext_x[9*i+:8] = s2_z[8*i+:8];
      ext_y[9*i+:8] = acc_y[8*i+:8];
      ext_x[9*i+8]  = tops[i] ? sub : 1'b1;
      ext_y[9*i+8]  = tops[i] ? sub : 1'b0;
    end
  end
  assign ext_sum = ext_x + ext_y + 72'(sub);
  always_comb for (int i = 0; i < 8; i++) acc[8*i+:8] = ext_sum[9*i+:8];

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s2_valid;
    unique case (s2_op)
      vec_pkg::VM_MUL: o_result <= lo;
      vec_pkg::VM_MULH, vec_pkg::VM_MULHU, vec_pkg::VM_MULHSU: o_result <= hi;
      default: o_result <= acc;
    endcase
    o_wide <= s2_prod;
  end

endmodule
