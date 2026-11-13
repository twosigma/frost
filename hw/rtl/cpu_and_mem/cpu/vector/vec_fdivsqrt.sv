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
  The vector unit's floating-point divide and square root for one IEEE 754
  format (EXP exponent and FRAC fraction bits): vfdiv, vfrdiv (operands
  swapped) and vfsqrt share one iterative unit that takes an operation when
  o_ready is high and returns it, with o_valid high for one cycle, a fixed
  P + 10 cycles later (P = FRAC + 1). i_rm is the RISC-V rounding mode;
  o_flags are fflags {NV, DZ, OF, UF, NX} with tininess detected after
  rounding, and NaN results are the canonical NaN.

  Subnormal significands are normalized first. Both operations then use one
  subtractor for P + 1 steps of a restoring digit recurrence: division
  subtracts the divisor from the partial remainder, square root subtracts
  the trial value 4 * root + 1 from the remainder with the next two
  radicand bits brought in. The last remainder gives the sticky bit, and the
  result is rounded like the other floating-point blocks.
*/
module vec_fdivsqrt #(
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input  logic         i_clk,
    input  logic         i_rst,
    input  logic         i_valid,
    output logic         o_ready,
    input  logic         i_sqrt,
    input  logic [  2:0] i_rm,
    input  logic [W-1:0] i_a,
    input  logic [W-1:0] i_b,
    output logic         o_valid,
    output logic [W-1:0] o_result,
    output logic [  4:0] o_flags
);

  localparam int P = FRAC + 1;
  localparam int Bias = (1 << (EXP - 1)) - 1;
  localparam int Emin = 1 - Bias;
  localparam int Emax = Bias;
  localparam int XW = EXP + 4;
  localparam int NB = (P + 15) / 16;
  localparam int LzW = $clog2(NB * 16 + 1);
  localparam int WN = P + 2;  // rounding window
  localparam int RW = $clog2(WN + 1);
  localparam int RemW = P + 4;
  localparam int Steps = P + 1;
  localparam int CW = $clog2(Steps + 1);
  localparam logic [W-1:0] CanonicalNan = {1'b0, {EXP{1'b1}}, 1'b1, {(FRAC - 1) {1'b0}}};

  typedef enum logic [3:0] {
    IDLE,
    LZ1,
    LZ2,
    NORM,
    SETUP,
    ITER,
    R1,
    R2,
    R3,
    R4,
    R5
  } state_e;
  state_e state;

  logic op_sqrt;
  logic [2:0] rm;
  logic [W-1:0] a_q, b_q;
  logic [CW-1:0] cnt;

  // --------------------------------------------------------------------------
  // LZ1: unpack, special operands, leading zeros of each significand block
  // --------------------------------------------------------------------------
  function automatic logic [NB*4+NB-1:0] block_lz(input logic [P-1:0] sig);
    logic [NB*16-1:0] p;
    logic [NB-1:0] z;
    logic [NB-1:0][3:0] c;
    p = {sig, {(NB * 16 - P) {1'b0}}};
    for (int b = 0; b < NB; b++) begin
      z[b] = (p[NB*16-1-16*b-:16] == '0);
      c[b] = 4'd15;
      for (int j = 0; j < 16; j++) if (p[NB*16-16-16*b+j]) c[b] = 4'(15 - j);
    end
    block_lz = {z, c};
  endfunction

  logic [EXP-1:0] ae, be;
  logic [FRAC-1:0] af, bf;
  logic a_nan, b_nan, a_snan, b_snan, a_inf, b_inf, a_zero, b_zero, res_sign;
  assign ae = a_q[W-2-:EXP];
  assign be = b_q[W-2-:EXP];
  assign af = a_q[FRAC-1:0];
  assign bf = b_q[FRAC-1:0];
  assign a_nan = (ae == '1) && (af != '0);
  assign b_nan = (be == '1) && (bf != '0);
  assign a_snan = a_nan && !af[FRAC-1];
  assign b_snan = b_nan && !bf[FRAC-1];
  assign a_inf = (ae == '1) && (af == '0);
  assign b_inf = (be == '1) && (bf == '0);
  assign a_zero = (ae == '0) && (af == '0);
  assign b_zero = (be == '0) && (bf == '0);
  assign res_sign = op_sqrt ? a_q[W-1] : (a_q[W-1] ^ b_q[W-1]);

  // Special results: {special, flags, value}.
  logic spec_hit;
  logic [4:0] spec_flags;
  logic [W-1:0] spec_val;
  always_comb begin
    spec_hit   = 1'b1;
    spec_flags = '0;
    spec_val   = CanonicalNan;
    if (op_sqrt) begin
      if (a_nan) spec_flags[4] = a_snan;
      else if (a_zero) spec_val = a_q;
      else if (a_q[W-1]) spec_flags[4] = 1'b1;
      else if (a_inf) spec_val = a_q;
      else spec_hit = 1'b0;
    end else begin
      if (a_nan || b_nan) spec_flags[4] = a_snan || b_snan;
      else if ((a_inf && b_inf) || (a_zero && b_zero)) spec_flags[4] = 1'b1;
      else if (a_inf || b_zero) begin
        spec_val = {res_sign, {EXP{1'b1}}, {FRAC{1'b0}}};
        spec_flags[3] = b_zero && !a_inf;
      end else if (a_zero || b_inf) spec_val = {res_sign, {(W - 1) {1'b0}}};
      else spec_hit = 1'b0;
    end
  end

  logic sign_q, spec_q;
  logic [  4:0] spec_flags_q;
  logic [W-1:0] spec_val_q;
  logic [P-1:0] sig_a, sig_b;
  logic signed [XW-1:0] exp_a, exp_b;
  logic [NB*4+NB-1:0] blz_a, blz_b;
  logic [LzW-1:0] lz_a, lz_b;

  function automatic logic [LzW-1:0] lz_combine(input logic [NB*4+NB-1:0] blk);
    logic [NB-1:0] z;
    logic [NB-1:0][3:0] c;
    {z, c} = blk;
    lz_combine = '0;
    for (int b = NB - 1; b >= 0; b--) if (!z[b]) lz_combine = LzW'(16 * b) + LzW'(c[b]);
  endfunction

  // --------------------------------------------------------------------------
  // Recurrence
  // --------------------------------------------------------------------------
  logic [RemW-1:0] rem;
  logic [P:0] q;  // quotient or root, P + 1 bits
  logic [P-1:0] divisor;
  logic [2*P+1:0] rad;  // radicand bits still to bring in, two per step
  logic signed [XW-1:0] exp_r;
  logic signed [XW-1:0] exp_even;  // the square root's exponent made even
  assign exp_even = exp_a[0] ? exp_a - XW'(1) : exp_a;
  logic [RemW-1:0] step_a, step_b, step_diff;
  logic step_ge;
  always_comb begin
    if (op_sqrt) begin
      step_a = {rem[RemW-3:0], rad[2*P+1-:2]};
      step_b = RemW'({q, 2'b01});
    end else begin
      step_a = rem;
      step_b = RemW'(divisor);
    end
    step_ge   = step_a >= step_b;
    step_diff = step_a - step_b;
  end

  // --------------------------------------------------------------------------
  // Rounding
  // --------------------------------------------------------------------------
  function automatic logic round_up(input logic [2:0] mode, input logic sign, input logic lsb,
                                    input logic guard, input logic sticky);
    unique case (mode)
      3'd0: round_up = guard && (sticky || lsb);  // RNE
      3'd2: round_up = sign && (guard || sticky);  // RDN
      3'd3: round_up = !sign && (guard || sticky);  // RUP
      3'd4: round_up = guard;  // RMM
      default: round_up = 1'b0;  // RTZ
    endcase
  endfunction

  logic [WN-1:0] win, rmask;
  logic xsticky, carry_full, tiny, inexact, up, ovf_gt, ovf_eq;
  logic [RW-1:0] rsh;
  logic signed [XW-1:0] exp_n;
  logic [P:0] sig_r;
  logic [EXP-1:0] ef0, ef1;
  always_comb for (int j = 0; j < WN; j++) rmask[j] = (32'(rsh) > 32'(j));

  always_ff @(posedge i_clk) begin
    o_valid <= 1'b0;
    if (i_rst) begin
      state <= IDLE;
    end else begin
      unique case (state)
        IDLE:
        if (i_valid) begin
          op_sqrt <= i_sqrt;
          rm <= i_rm;
          a_q <= i_a;
          b_q <= i_b;
          state <= LZ1;
        end
        LZ1: begin
          sign_q <= res_sign;
          spec_q <= spec_hit;
          spec_flags_q <= spec_flags;
          spec_val_q <= spec_val;
          sig_a <= {ae != '0, af};
          sig_b <= {be != '0, bf};
          exp_a <= (ae == '0) ? XW'(Emin) : XW'(ae) - XW'(Bias);
          exp_b <= (be == '0) ? XW'(Emin) : XW'(be) - XW'(Bias);
          blz_a <= block_lz({ae != '0, af});
          blz_b <= block_lz({be != '0, bf});
          state <= LZ2;
        end
        LZ2: begin
          lz_a  <= lz_combine(blz_a);
          lz_b  <= lz_combine(blz_b);
          state <= NORM;
        end
        NORM: begin
          sig_a <= sig_a << lz_a;
          sig_b <= sig_b << lz_b;
          exp_a <= exp_a - XW'(lz_a);
          exp_b <= exp_b - XW'(lz_b);
          state <= SETUP;
        end
        SETUP: begin
          // Division: a quotient in [1, 2) from a dividend at least the
          // divisor. Square root: an even exponent and a radicand in [1, 4),
          // scaled so the root has P + 1 bits.
          q <= '0;
          cnt <= '0;
          divisor <= sig_b;
          if (op_sqrt) begin
            rem   <= '0;
            rad   <= (2 * P + 2)'(exp_a[0] ? {sig_a, 1'b0} : {1'b0, sig_a}) << (FRAC + 2);
            exp_r <= exp_even >>> 1;
          end else if (sig_a < sig_b) begin
            rem   <= RemW'({sig_a, 1'b0});
            exp_r <= exp_a - exp_b - 1;
          end else begin
            rem   <= RemW'(sig_a);
            exp_r <= exp_a - exp_b;
          end
          state <= ITER;
        end
        ITER: begin
          q <= {q[P-1:0], step_ge};
          if (op_sqrt) begin
            rem <= step_ge ? step_diff : step_a;
            rad <= rad << 2;
          end else begin
            rem <= (step_ge ? step_diff : step_a) << 1;
          end
          cnt <= cnt + 1'b1;
          if (cnt == CW'(Steps - 1)) state <= R1;
        end
        R1: begin
          // Right shift into the subnormal range, and whether the value
          // rounded with the exponent unbounded reaches 2^Emin.
          win <= {q, 1'b0};
          xsticky <= rem != '0;
          if (exp_r >= XW'(Emin)) rsh <= '0;
          else if (XW'(Emin) - exp_r > XW'(WN)) rsh <= RW'(WN);
          else rsh <= RW'(XW'(Emin) - exp_r);
          carry_full <= (&q[P:1]) && round_up(rm, sign_q, q[1], q[0], rem != '0);
          state <= R2;
        end
        R2: begin
          win <= win >> rsh;
          xsticky <= xsticky || |(win & rmask);
          exp_n <= (rsh != '0) ? XW'(Emin) : exp_r;
          tiny <= (exp_r < XW'(Emin)) && !((exp_r == XW'(Emin - 1)) && carry_full);
          state <= R3;
        end
        R3: begin
          up <= round_up(rm, sign_q, win[WN-P], win[WN-1-P], (|win[WN-2-P:0]) || xsticky);
          inexact <= win[WN-1-P] || (|win[WN-2-P:0]) || xsticky;
          ovf_gt <= exp_n > XW'(Emax);
          ovf_eq <= exp_n == XW'(Emax);
          ef0 <= EXP'(exp_n + XW'(Bias));
          ef1 <= EXP'(exp_n + XW'(Bias + 1));
          state <= R4;
        end
        R4: begin
          sig_r <= {1'b0, win[WN-1-:P]} + (P + 1)'(up);
          state <= R5;
        end
        R5: begin
          o_valid <= 1'b1;
          o_flags <= '0;
          if (spec_q) begin
            o_result <= spec_val_q;
            o_flags  <= spec_flags_q;
          end else if (ovf_gt || (ovf_eq && sig_r[P])) begin
            o_flags <= 5'b00101;
            // RTZ, and rounding toward the other infinity, give the largest
            // finite value.
            if ((rm == 3'd1) || (rm == 3'd2 && !sign_q) || (rm == 3'd3 && sign_q))
              o_result <= {sign_q, {(EXP - 1) {1'b1}}, 1'b0, {FRAC{1'b1}}};
            else o_result <= {sign_q, {EXP{1'b1}}, {FRAC{1'b0}}};
          end else begin
            // A subnormal keeps exponent field 0 until rounding sets the
            // hidden bit.
            o_result <= {sign_q, sig_r[P] ? ef1 : (sig_r[P-1] ? ef0 : '0), sig_r[FRAC-1:0]};
            o_flags  <= {3'b000, inexact && tiny, inexact};
          end
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
  assign o_ready = (state == IDLE);

endmodule
