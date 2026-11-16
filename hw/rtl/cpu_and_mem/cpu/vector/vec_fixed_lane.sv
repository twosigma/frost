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

// Extended integer arithmetic for one element. Rounding uses vxrm, with
// saturation reported separately so the sequencer qualifies it by activity.
// Arithmetic, shifting, rounding and saturation have separate registers.
module vec_fixed_lane (
    input logic i_clk,
    i_rst,
    i_valid,
    input vec_pkg::extra_op_e i_op,
    input logic [1:0] i_sew,
    i_aw,
    input logic [1:0] i_vxrm,
    input logic [63:0] i_a,
    i_b,
    input logic [127:0] i_product,
    input logic i_carry,
    output logic o_valid,
    output logic [63:0] o_result,
    output logic o_sat
);
  function automatic logic [64:0] extend(input logic [63:0] x, input logic [1:0] w,
                                         input logic sgn);
    case (w)
      0: extend = {{57{sgn && x[7]}}, x[7:0]};
      1: extend = {{49{sgn && x[15]}}, x[15:0]};
      2: extend = {{33{sgn && x[31]}}, x[31:0]};
      default: extend = {sgn && x[63], x};
    endcase
  endfunction
  logic v0, v1, v2, v3;
  vec_pkg::extra_op_e op0, op1, op2, op3;
  logic [1:0] w0, w1, w2, w3, aw0, rm0, rm1;
  logic [64:0] a0, b0, rounded3;
  logic [127:0] value1, shifted2;
  logic [6:0] shift1;
  logic signed1, increment2, carry0;
  logic [127:0] product0;
  logic [ 63:0] braw0;
  logic sign_a, sign_b;
  always_comb begin
    sign_a = (i_op == vec_pkg::VX_ADD) || (i_op == vec_pkg::VX_SUB) ||
        (i_op == vec_pkg::VX_AADD) || (i_op == vec_pkg::VX_ASUB) ||
        (i_op == vec_pkg::VX_SSRA) || (i_op == vec_pkg::VX_CLIP) ||
        (i_op == vec_pkg::VX_WADD) || (i_op == vec_pkg::VX_WSUB) ||
        (i_op == vec_pkg::VX_NSRA) || (i_op == vec_pkg::VX_SEXT);
    sign_b = (i_op == vec_pkg::VX_ADD) || (i_op == vec_pkg::VX_SUB) ||
        (i_op == vec_pkg::VX_AADD) || (i_op == vec_pkg::VX_ASUB) ||
        (i_op == vec_pkg::VX_WADD) || (i_op == vec_pkg::VX_WSUB);
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) v0 <= 1'b0;
    else v0 <= i_valid;
    op0 <= i_op;
    w0 <= i_sew;
    aw0 <= i_aw;
    rm0 <= i_vxrm;
    a0 <= extend(i_a, i_aw, sign_a);
    b0 <= extend(i_b, i_sew, sign_b);
    braw0 <= i_b;
    product0 <= i_product;
    carry0 <= i_carry;
  end
  logic [64:0] add_d;
  logic sub_d, carry_d;
  always_comb begin
    sub_d = (op0 == vec_pkg::VX_SUBU) || (op0 == vec_pkg::VX_SUB) ||
        (op0 == vec_pkg::VX_ASUBU) || (op0 == vec_pkg::VX_ASUB) ||
        (op0 == vec_pkg::VX_SBC) || (op0 == vec_pkg::VX_MSBC) ||
        (op0 == vec_pkg::VX_WSUBU) || (op0 == vec_pkg::VX_WSUB);
    carry_d = carry0 && ((op0 == vec_pkg::VX_ADC) || (op0 == vec_pkg::VX_MADC) ||
        (op0 == vec_pkg::VX_SBC) || (op0 == vec_pkg::VX_MSBC));
    add_d = sub_d ? a0 - b0 - 65'(carry_d) : a0 + b0 + 65'(carry_d);
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) v1 <= 1'b0;
    else v1 <= v0;
    op1 <= op0;
    w1 <= w0;
    rm1 <= rm0;
    value1 <= {{63{add_d[64]}}, add_d};
    shift1 <= 0;
    signed1 <= 1'b1;
    case (op0)
      vec_pkg::VX_AADDU, vec_pkg::VX_AADD, vec_pkg::VX_ASUBU, vec_pkg::VX_ASUB: shift1 <= 1;
      vec_pkg::VX_SSRL, vec_pkg::VX_SSRA, vec_pkg::VX_CLIPU, vec_pkg::VX_CLIP,
      vec_pkg::VX_NSRL, vec_pkg::VX_NSRA: begin
        value1 <= {{63{a0[64]}}, a0};
        shift1 <= 7'(braw0 & ((64'd8 << aw0) - 1));
      end
      vec_pkg::VX_SMUL: begin
        value1 <= product0;
        shift1 <= (7'd8 << w0) - 1;
      end
      vec_pkg::VX_ZEXT, vec_pkg::VX_SEXT: value1 <= {{63{a0[64]}}, a0};
      vec_pkg::VX_WSLL: begin
        value1  <= {63'd0, a0} << (braw0[5:0] & ((6'd16 << w0) - 1));
        signed1 <= 1'b0;
      end
      default: ;
    endcase
  end
  logic round_d, discarded_d, halfway_d, low_d;
  logic [127:0] shifted_d, low_mask;
  always_comb begin
    shifted_d = signed1 ? 128'($signed(value1) >>> shift1) : (value1 >> shift1);
    low_mask = (128'd1 << shift1) - 1;
    discarded_d = |(value1 & low_mask);
    halfway_d = (shift1 != 0) && value1[shift1-1];
    low_d = |(value1 & (low_mask >> 1));
    case (rm1)
      0: round_d = halfway_d;
      1: round_d = halfway_d && (low_d || shifted_d[0]);
      2: round_d = 1'b0;
      default: round_d = !shifted_d[0] && discarded_d;
    endcase
    if ((op1 == vec_pkg::VX_NSRL) || (op1 == vec_pkg::VX_NSRA)) round_d = 1'b0;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      v2 <= 1'b0;
      v3 <= 1'b0;
    end else begin
      v2 <= v1;
      v3 <= v2;
    end
    op2 <= op1;
    w2 <= w1;
    shifted2 <= shifted_d;
    increment2 <= round_d;
    op3 <= op2;
    w3 <= w2;
    rounded3 <= shifted2[64:0] + 65'(increment2);
  end
  logic [64:0] max_u, max_s, min_s;
  logic [63:0] result_d;
  logic sat_d;
  always_comb begin
    max_u = (65'd1 << (7'd8 << w3)) - 1;
    max_s = max_u >> 1;
    min_s = ~max_s;
    result_d = rounded3[63:0];
    sat_d = 1'b0;
    case (op3)
      vec_pkg::VX_ADDU, vec_pkg::VX_CLIPU: begin
        sat_d = rounded3 > max_u;
        if (sat_d) result_d = max_u[63:0];
      end
      vec_pkg::VX_SUBU: begin
        sat_d = rounded3[64];
        if (sat_d) result_d = 0;
      end
      vec_pkg::VX_ADD, vec_pkg::VX_SUB, vec_pkg::VX_CLIP, vec_pkg::VX_SMUL: begin
        if ($signed(rounded3) > $signed(max_s)) begin
          result_d = max_s[63:0];
          sat_d = 1'b1;
        end else if ($signed(rounded3) < $signed(min_s)) begin
          result_d = min_s[63:0];
          sat_d = 1'b1;
        end
      end
      vec_pkg::VX_MADC: result_d = 64'(rounded3[7'd8<<w3]);
      vec_pkg::VX_MSBC: result_d = 64'(rounded3[64]);
      default: ;
    endcase
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= v3;
    o_result <= result_d;
    o_sat <= sat_d;
  end
endmodule
