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

// One committed FP element. Width codes are log2(bytes), as in vsew.
// kind: 0 FMA, 1 miscellaneous, 2 divide/sqrt, 3 FP-to-integer,
// 4 integer-to-FP, 5 FP-to-FP, 6 reciprocal estimate. Widening arithmetic
// converts each narrow operand exactly before launching the wider FMA.
// The FP16 arithmetic, estimate and FP16/integer conversion instances exist
// only with riscv_pkg::VectorZvfh; the FP16/FP32 conversions (Zvfhmin)
// always do.
module vec_fp_lane (
    input logic i_clk,
    i_rst,
    i_valid,
    input logic [2:0] i_kind,
    input logic [3:0] i_op,
    input logic [1:0] i_aw,
    i_bw,
    i_dw,
    input logic [2:0] i_rm,
    input logic i_signed,
    i_neg_prod,
    i_neg_add,
    input logic [63:0] i_a,
    i_b,
    i_c,
    output logic o_ready,
    o_valid,
    output logic [63:0] o_result,
    output logic [4:0] o_flags
);
  typedef enum logic [3:0] {
    IDLE,
    CHECK_A,
    CONVERT_A,
    WAIT_A,
    CHECK_B,
    CONVERT_B,
    WAIT_B,
    EXECUTE,
    WAIT_RESULT
  } state_e;
  state_e state;
  logic [2:0] kind_q, rm_q;
  logic [3:0] op_q;
  logic [1:0] aw_q, bw_q, dw_q;
  logic signed_q, neg_prod_q, neg_add_q;
  logic [63:0] a_q, b_q, c_q;
  logic [4:0] flags_q;
  logic [1:0] cv_sw, cv_dw;
  logic [63:0] cv_a;
  logic [2:0] cv_rm;
  logic cv_start;
  assign cv_sw = (state == CONVERT_B || state == WAIT_B) ? bw_q : aw_q;
  assign cv_dw = dw_q;
  assign cv_a = (state == CONVERT_B || state == WAIT_B) ? b_q : a_q;
  assign cv_rm = kind_q == 5 ? rm_q : 3'd0;
  assign cv_start = state == CONVERT_A || state == CONVERT_B || (state == EXECUTE && kind_q == 5);

  logic [3:0] fma_v, misc_v, div_v, estimate_v;
  logic [3:0][63:0] fma_r, misc_r, div_r, estimate_r;
  logic [3:0][4:0] fma_f, misc_f, div_f, estimate_f;
  assign fma_v[0] = 1'b0;
  assign misc_v[0] = 1'b0;
  assign div_v[0] = 1'b0;
  assign estimate_v[0] = 1'b0;
  assign fma_r[0] = '0;
  assign misc_r[0] = '0;
  assign div_r[0] = '0;
  assign estimate_r[0] = '0;
  assign fma_f[0] = '0;
  assign misc_f[0] = '0;
  assign div_f[0] = '0;
  assign estimate_f[0] = '0;
  for (genvar w = 1; w <= 3; w++) begin : g_format
    if (w > 1 || riscv_pkg::VectorZvfh) begin : g_units
      localparam int W = 8 << w;
      localparam int E = w == 1 ? 5 : w == 2 ? 8 : 11;
      localparam int F = W - E - 1;
      logic [W-1:0] fr, mr, dr, er;
      vec_fma #(
          .EXP (E),
          .FRAC(F)
      ) u_fma (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_valid(state == EXECUTE && kind_q == 0 && dw_q == 2'(w)),
          .i_op(op_q[1:0]),
          .i_neg_prod(neg_prod_q),
          .i_neg_add(neg_add_q),
          .i_rm(rm_q),
          .i_a(a_q[W-1:0]),
          .i_b(b_q[W-1:0]),
          .i_c(op_q[1:0] == 2 ? b_q[W-1:0] : c_q[W-1:0]),
          .o_valid(fma_v[w]),
          .o_result(fr),
          .o_flags(fma_f[w])
      );
      vec_fp_misc #(
          .EXP (E),
          .FRAC(F)
      ) u_misc (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_valid(state == EXECUTE && kind_q == 1 && dw_q == 2'(w)),
          .i_op(op_q),
          .i_a(a_q[W-1:0]),
          .i_b(b_q[W-1:0]),
          .o_valid(misc_v[w]),
          .o_result(mr),
          .o_flags(misc_f[w])
      );
      vec_fdivsqrt #(
          .EXP (E),
          .FRAC(F)
      ) u_div (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_valid(state == EXECUTE && kind_q == 2 && dw_q == 2'(w)),
          .o_ready(),
          .i_sqrt(op_q[0]),
          .i_rm(rm_q),
          .i_a(a_q[W-1:0]),
          .i_b(b_q[W-1:0]),
          .o_valid(div_v[w]),
          .o_result(dr),
          .o_flags(div_f[w])
      );
      vec_fp_estimate #(
          .EXP (E),
          .FRAC(F)
      ) u_estimate (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_valid(state == EXECUTE && kind_q == 6 && dw_q == 2'(w)),
          .o_ready(),
          .i_rsqrt(op_q[0]),
          .i_rm(rm_q),
          .i_a(a_q[W-1:0]),
          .o_valid(estimate_v[w]),
          .o_result(er),
          .o_flags(estimate_f[w])
      );
      assign fma_r[w] = 64'(fr);
      assign misc_r[w] = 64'(mr);
      assign div_r[w] = 64'(dr);
      assign estimate_r[w] = 64'(er);
    end else begin : g_no_units
      assign fma_v[w] = 1'b0;
      assign misc_v[w] = 1'b0;
      assign div_v[w] = 1'b0;
      assign estimate_v[w] = 1'b0;
      assign fma_r[w] = '0;
      assign misc_r[w] = '0;
      assign div_r[w] = '0;
      assign estimate_r[w] = '0;
      assign fma_f[w] = '0;
      assign misc_f[w] = '0;
      assign div_f[w] = '0;
      assign estimate_f[w] = '0;
    end
  end

  logic [3:0][3:0] f2i_v, i2f_v, f2f_v;
  logic [3:0][3:0][63:0] f2i_r, i2f_r, f2f_r;
  logic [3:0][3:0][4:0] f2i_f, i2f_f, f2f_f;
  for (genvar s = 0; s <= 3; s++) begin : g_source
    for (genvar d = 0; d <= 3; d++) begin : g_dest
      localparam int SW = 8 << s;
      localparam int DW = 8 << d;
      localparam int SE = s == 1 ? 5 : s == 2 ? 8 : 11;
      localparam int DE = d == 1 ? 5 : d == 2 ? 8 : 11;
      if (s >= 1 && d >= s - 1 && d <= s + 1 && (s > 1 || riscv_pkg::VectorZvfh)) begin : g_f2i
        logic [DW-1:0] result;
        vec_f2i #(
            .EXP (SE),
            .FRAC(SW - SE - 1),
            .IW  (DW)
        ) u_convert (
            .i_clk(i_clk),
            .i_rst(i_rst),
            .i_valid(state == EXECUTE && kind_q == 3 && aw_q == 2'(s) && dw_q == 2'(d)),
            .i_signed(signed_q),
            .i_rm(rm_q),
            .i_a(a_q[SW-1:0]),
            .o_valid(f2i_v[s][d]),
            .o_result(result),
            .o_flags(f2i_f[s][d])
        );
        assign f2i_r[s][d] = 64'(result);
      end else begin : g_no_f2i
        assign f2i_v[s][d] = 1'b0;
        assign f2i_r[s][d] = '0;
        assign f2i_f[s][d] = '0;
      end
      if (d >= 1 && s >= d - 1 && s <= d + 1 && (d > 1 || riscv_pkg::VectorZvfh)) begin : g_i2f
        logic [DW-1:0] result;
        vec_i2f #(
            .IW  (SW),
            .EXP (DE),
            .FRAC(DW - DE - 1)
        ) u_convert (
            .i_clk(i_clk),
            .i_rst(i_rst),
            .i_valid(state == EXECUTE && kind_q == 4 && aw_q == 2'(s) && dw_q == 2'(d)),
            .i_signed(signed_q),
            .i_rm(rm_q),
            .i_a(a_q[SW-1:0]),
            .o_valid(i2f_v[s][d]),
            .o_result(result),
            .o_flags(i2f_f[s][d])
        );
        assign i2f_r[s][d] = 64'(result);
      end else begin : g_no_i2f
        assign i2f_v[s][d] = 1'b0;
        assign i2f_r[s][d] = '0;
        assign i2f_f[s][d] = '0;
      end
      if (s >= 1 && d >= 1 && (d == s + 1 || s == d + 1)) begin : g_f2f
        logic [DW-1:0] result;
        vec_f2f #(
            .SEXP (SE),
            .SFRAC(SW - SE - 1),
            .DEXP (DE),
            .DFRAC(DW - DE - 1)
        ) u_convert (
            .i_clk(i_clk),
            .i_rst(i_rst),
            .i_valid(cv_start && cv_sw == 2'(s) && cv_dw == 2'(d)),
            .i_rm(cv_rm),
            .i_a(cv_a[SW-1:0]),
            .o_valid(f2f_v[s][d]),
            .o_result(result),
            .o_flags(f2f_f[s][d])
        );
        assign f2f_r[s][d] = 64'(result);
      end else begin : g_no_f2f
        assign f2f_v[s][d] = 1'b0;
        assign f2f_r[s][d] = '0;
        assign f2f_f[s][d] = '0;
      end
    end
  end
  logic result_valid;
  logic [63:0] result;
  logic [4:0] flags;
  always_comb begin
    result_valid = 1'b0;
    result = '0;
    flags = '0;
    case (kind_q)
      0: begin
        result_valid = fma_v[dw_q];
        result = fma_r[dw_q];
        flags = fma_f[dw_q];
      end
      1: begin
        result_valid = misc_v[dw_q];
        result = misc_r[dw_q];
        flags = misc_f[dw_q];
      end
      2: begin
        result_valid = div_v[dw_q];
        result = div_r[dw_q];
        flags = div_f[dw_q];
      end
      3: begin
        result_valid = f2i_v[aw_q][dw_q];
        result = f2i_r[aw_q][dw_q];
        flags = f2i_f[aw_q][dw_q];
      end
      4: begin
        result_valid = i2f_v[aw_q][dw_q];
        result = i2f_r[aw_q][dw_q];
        flags = i2f_f[aw_q][dw_q];
      end
      5: begin
        result_valid = f2f_v[aw_q][dw_q];
        result = f2f_r[aw_q][dw_q];
        flags = f2f_f[aw_q][dw_q];
      end
      6: begin
        result_valid = estimate_v[dw_q];
        result = estimate_r[dw_q];
        flags = estimate_f[dw_q];
      end
      default: ;
    endcase
  end
  assign o_ready = state == IDLE;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state   <= IDLE;
      o_valid <= 1'b0;
    end else begin
      o_valid <= 1'b0;
      case (state)
        IDLE:
        if (i_valid) begin
          kind_q <= i_kind;
          op_q <= i_op;
          aw_q <= i_aw;
          bw_q <= i_bw;
          dw_q <= i_dw;
          rm_q <= i_rm;
          signed_q <= i_signed;
          neg_prod_q <= i_neg_prod;
          neg_add_q <= i_neg_add;
          a_q <= i_a;
          b_q <= i_b;
          c_q <= i_c;
          flags_q <= '0;
          state <= CHECK_A;
        end
        CHECK_A:   state <= kind_q == 0 && aw_q != dw_q ? CONVERT_A : CHECK_B;
        CONVERT_A: state <= WAIT_A;
        WAIT_A:
        if (f2f_v[aw_q][dw_q]) begin
          a_q <= f2f_r[aw_q][dw_q];
          flags_q <= flags_q | f2f_f[aw_q][dw_q];
          state <= CHECK_B;
        end
        CHECK_B:   state <= kind_q == 0 && bw_q != dw_q ? CONVERT_B : EXECUTE;
        CONVERT_B: state <= WAIT_B;
        WAIT_B:
        if (f2f_v[bw_q][dw_q]) begin
          b_q <= f2f_r[bw_q][dw_q];
          flags_q <= flags_q | f2f_f[bw_q][dw_q];
          state <= EXECUTE;
        end
        EXECUTE:   state <= WAIT_RESULT;
        WAIT_RESULT:
        if (result_valid) begin
          o_result <= result;
          o_flags <= flags_q | flags;
          o_valid <= 1'b1;
          state <= IDLE;
        end
        default:   state <= IDLE;
      endcase
    end
  end
endmodule
