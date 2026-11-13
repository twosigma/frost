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
  full products of the lane's elements at SEW 8, 16 and 32 for the widening
  multiplies, element k at bits 2*SEW*k; vwmul, vwmulu and vwmulsu use vec_pkg::VM_MULH,
  vec_pkg::VM_MULHU and vec_pkg::VM_MULHSU for their signedness. Every result appears a fixed
  six cycles after the cycle that takes the input, whatever the operation
  and operands.

  The products are computed separately for each element width from operands
  extended to SEW+1 bits, so one signed multiply covers the signed, unsigned and
  mixed forms. The operands and their extension bits are registered before
  the multipliers, which are followed by four register stages that synthesis
  places inside the DSP cascades.
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
  // (MUL, MACC, NMSAC) are the same for any signedness. Stage A registers
  // the operands with their sign-extension bits, so the multipliers start
  // from registers.
  logic x_signed, y_signed;
  assign x_signed = (s0_op == vec_pkg::VM_MULH) || (s0_op == vec_pkg::VM_MULHSU);
  assign y_signed = (s0_op == vec_pkg::VM_MULH);
  logic sa_valid;
  vec_pkg::mul_op_e sa_op;
  vec_pkg::sew_e sa_sew;
  logic [63:0] sa_x, sa_y, sa_z;
  logic [7:0] sa_xs, sa_ys;  // sign-extension bit of each byte's element
  always_ff @(posedge i_clk) begin
    if (i_rst) sa_valid <= 1'b0;
    else sa_valid <= s0_valid;
    sa_op  <= s0_op;
    sa_sew <= s0_sew;
    sa_x   <= s0_x;
    sa_y   <= s0_y;
    sa_z   <= s0_z;
    for (int i = 0; i < 8; i++) begin
      sa_xs[i] <= x_signed & s0_x[8*i+7];
      sa_ys[i] <= y_signed & s0_y[8*i+7];
    end
  end

  // Full products for each element width, from SEW+1-bit extended operands.
  logic [7:0][15:0] p8;
  logic [3:0][31:0] p16;
  logic [1:0][63:0] p32;
  logic [127:0] p64;
  always_comb begin
    for (int e = 0; e < 8; e++) begin
      logic signed [8:0] xe, ye;
      logic signed [17:0] pe;
      xe = {sa_xs[e], sa_x[8*e+:8]};
      ye = {sa_ys[e], sa_y[8*e+:8]};
      pe = xe * ye;
      p8[e] = pe[15:0];
    end
    for (int e = 0; e < 4; e++) begin
      logic signed [16:0] xe, ye;
      logic signed [33:0] pe;
      xe = {sa_xs[2*e+1], sa_x[16*e+:16]};
      ye = {sa_ys[2*e+1], sa_y[16*e+:16]};
      pe = xe * ye;
      p16[e] = pe[31:0];
    end
    for (int e = 0; e < 2; e++) begin
      logic signed [32:0] xe, ye;
      logic signed [65:0] pe;
      xe = {sa_xs[4*e+3], sa_x[32*e+:32]};
      ye = {sa_ys[4*e+3], sa_y[32*e+:32]};
      pe = xe * ye;
      p32[e] = pe[63:0];
    end
    begin
      logic signed [64:0] xe, ye;
      logic signed [129:0] pe;
      xe  = {sa_xs[7], sa_x};
      ye  = {sa_ys[7], sa_y};
      pe  = xe * ye;
      p64 = pe[127:0];
    end
  end

  // Product pipeline: MulStages register stages after the multipliers, which
  // synthesis places inside the DSP cascades of the wide products.
  localparam int MulStages = 4;
  logic pv[MulStages];
  vec_pkg::mul_op_e pop[MulStages];
  vec_pkg::sew_e psew[MulStages];
  logic [63:0] pz[MulStages];
  logic [7:0][15:0] pp8[MulStages];
  logic [3:0][31:0] pp16[MulStages];
  logic [1:0][63:0] pp32[MulStages];
  logic [127:0] pp64[MulStages];
  always_ff @(posedge i_clk) begin
    if (i_rst) for (int k = 0; k < MulStages; k++) pv[k] <= 1'b0;
    else begin
      pv[0] <= sa_valid;
      for (int k = 1; k < MulStages; k++) pv[k] <= pv[k-1];
    end
    pop[0]  <= sa_op;
    psew[0] <= sa_sew;
    pz[0]   <= sa_z;
    pp8[0]  <= p8;
    pp16[0] <= p16;
    pp32[0] <= p32;
    pp64[0] <= p64;
    for (int k = 1; k < MulStages; k++) begin
      pop[k]  <= pop[k-1];
      psew[k] <= psew[k-1];
      pz[k]   <= pz[k-1];
      pp8[k]  <= pp8[k-1];
      pp16[k] <= pp16[k-1];
      pp32[k] <= pp32[k-1];
      pp64[k] <= pp64[k-1];
    end
  end
  logic s2_valid;
  vec_pkg::mul_op_e s2_op;
  vec_pkg::sew_e s2_sew;
  logic [63:0] s2_z;
  logic [7:0][15:0] s2_p8;
  logic [3:0][31:0] s2_p16;
  logic [1:0][63:0] s2_p32;
  logic [127:0] s2_p64;
  assign s2_valid = pv[MulStages-1];
  assign s2_op = pop[MulStages-1];
  assign s2_sew = psew[MulStages-1];
  assign s2_z = pz[MulStages-1];
  assign s2_p8 = pp8[MulStages-1];
  assign s2_p16 = pp16[MulStages-1];
  assign s2_p32 = pp32[MulStages-1];
  assign s2_p64 = pp64[MulStages-1];

  // Final stage: low or high halves, the accumulate, and the wide products.
  logic [63:0] lo, hi;
  logic [127:0] wide;
  always_comb begin
    lo   = '0;
    hi   = '0;
    wide = '0;
    unique case (s2_sew)
      vec_pkg::SEW8:
      for (int e = 0; e < 8; e++) begin
        lo[8*e+:8] = s2_p8[e][7:0];
        hi[8*e+:8] = s2_p8[e][15:8];
        wide[16*e+:16] = s2_p8[e];
      end
      vec_pkg::SEW16:
      for (int e = 0; e < 4; e++) begin
        lo[16*e+:16]   = s2_p16[e][15:0];
        hi[16*e+:16]   = s2_p16[e][31:16];
        wide[32*e+:32] = s2_p16[e];
      end
      vec_pkg::SEW32:
      for (int e = 0; e < 2; e++) begin
        lo[32*e+:32]   = s2_p32[e][31:0];
        hi[32*e+:32]   = s2_p32[e][63:32];
        wide[64*e+:64] = s2_p32[e];
      end
      default: begin
        lo = s2_p64[63:0];
        hi = s2_p64[127:64];
      end
    endcase
  end

  // z + lo or z - lo per element: the 72-bit separator adder of
  // vec_int_lane, with the subtrahend inverted and a carry-in of 1.
  logic [7:0] tops;
  always_comb begin
    unique case (s2_sew)
      vec_pkg::SEW8: tops = 8'b1111_1111;
      vec_pkg::SEW16: tops = 8'b1010_1010;
      vec_pkg::SEW32: tops = 8'b1000_1000;
      default: tops = 8'b1000_0000;
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
    o_wide <= wide;
  end

endmodule
