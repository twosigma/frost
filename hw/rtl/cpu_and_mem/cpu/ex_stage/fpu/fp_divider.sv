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
  IEEE 754 floating-point divider — fully pipelined.

  Accepts a new operation every cycle. Pipeline depth:
    SP (FP_WIDTH=32): DivCycles + 10 = 26 + 10 = 36 stages
    DP (FP_WIDTH=64): DivCycles + 10 = 55 + 10 = 65 stages

  Pipeline structure:
    Stage 0:  Input capture (operand regs, rounding mode)
    Stage 1:  UNPACK — fp_operand_unpacker + fp_lzc (combinational, outputs registered)
    Stage 2:  INIT — mantissa normalization, special case detection (registered)
    Stage 3:  SETUP — compute result_exp, initial quotient/remainder/divisor
    Stages 4..4+DivCycles-1:  DIVIDE — one radix-2 step per stage (generate block)
    Stage 4+DivCycles:    NORMALIZE_PREP — fp_lzc on quotient
    Stage 4+DivCycles+1:  NORMALIZE — shift quotient, adjust exponent
    Stage 4+DivCycles+2:  ROUND_SHIFT — fp_subnorm_shift
    Stage 4+DivCycles+3:  ROUND_PREP — fp_compute_round_up
    Stage 4+DivCycles+4:  ROUND_APPLY — fp_result_assembler
    Stage 4+DivCycles+5:  OUTPUT — register final result

  Special cases (NaN, inf, zero, div-by-zero) detected at INIT. The DIVIDE
  stages still execute on don't-care data; the OUTPUT stage selects the
  special result when is_special is set.
*/
module fp_divider #(
    parameter int unsigned FP_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [FP_WIDTH-1:0] i_operand_a,  // Dividend
    input logic [FP_WIDTH-1:0] i_operand_b,  // Divisor
    input logic [2:0] i_rounding_mode,
    output logic [FP_WIDTH-1:0] o_result,
    output logic o_valid,
    output logic o_stall,  // Always 0 (pipelined, never stalls)
    output riscv_pkg::fp_flags_t o_flags
);

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned DivBits = MantBits + 3;  // mantissa + guard bits
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcMantBits = $clog2(FracBits + 1);
  localparam int unsigned QuotLzcBits = $clog2(DivBits + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam int unsigned DivCycles = MantBits + 2;
  localparam logic signed [ExpExtBits-1:0] ExpBiasExt = ExpExtBits'(ExpBias);

  localparam int unsigned TotalStages = DivCycles + 10;

  // Valid pipeline
  logic pipe_valid[TotalStages+1];

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i <= TotalStages; i++) begin
        pipe_valid[i] <= 1'b0;
      end
    end else begin
      pipe_valid[0] <= i_valid;
      for (int i = 1; i <= TotalStages; i++) begin
        pipe_valid[i] <= pipe_valid[i-1];
      end
    end
  end

  // =========================================================================
  // Stage 0: Input Capture
  // =========================================================================
  logic [FP_WIDTH-1:0] s0_operand_a;
  logic [FP_WIDTH-1:0] s0_operand_b;
  logic [2:0] s0_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s0_operand_a <= '0;
      s0_operand_b <= '0;
      s0_rm <= 3'b0;
    end else if (i_valid) begin
      s0_operand_a <= i_operand_a;
      s0_operand_b <= i_operand_b;
      s0_rm <= i_rounding_mode;
    end
  end

  // =========================================================================
  // Stage 1: UNPACK — fp_operand_unpacker + fp_lzc (combinational from s0)
  // =========================================================================
  logic sign_a, sign_b;
  logic [ExpBits-1:0] exp_a, exp_b;
  logic [LzcMantBits-1:0] mant_lzc_a, mant_lzc_b;
  logic is_subnormal_a, is_subnormal_b;
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_a (
      .i_operand(s0_operand_a),
      .o_sign(sign_a),
      .o_exp(exp_a),
      .o_exp_adj(),
      .o_frac(),
      .o_mant(),
      .o_is_zero(is_zero_a),
      .o_is_subnormal(is_subnormal_a),
      .o_is_inf(is_inf_a),
      .o_is_nan(is_nan_a),
      .o_is_snan(is_snan_a)
  );
  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack_b (
      .i_operand(s0_operand_b),
      .o_sign(sign_b),
      .o_exp(exp_b),
      .o_exp_adj(),
      .o_frac(),
      .o_mant(),
      .o_is_zero(is_zero_b),
      .o_is_subnormal(is_subnormal_b),
      .o_is_inf(is_inf_b),
      .o_is_nan(is_nan_b),
      .o_is_snan(is_snan_b)
  );

  logic mant_lzc_zero_a, mant_lzc_zero_b;
  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc_a (
      .i_value(s0_operand_a[FracBits-1:0]),
      .o_lzc(mant_lzc_a),
      .o_is_zero(mant_lzc_zero_a)
  );
  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc_b (
      .i_value(s0_operand_b[FracBits-1:0]),
      .o_lzc(mant_lzc_b),
      .o_is_zero(mant_lzc_zero_b)
  );

  // Register UNPACK outputs -> Stage 1 output registers
  logic s1_sign_a, s1_sign_b;
  logic [ExpBits-1:0] s1_exp_a, s1_exp_b;
  logic [LzcMantBits-1:0] s1_mant_lzc_a, s1_mant_lzc_b;
  logic s1_is_subnormal_a, s1_is_subnormal_b;
  logic s1_is_zero_a, s1_is_zero_b;
  logic s1_is_inf_a, s1_is_inf_b;
  logic s1_is_nan_a, s1_is_nan_b;
  logic s1_is_snan_a, s1_is_snan_b;
  logic [FracBits-1:0] s1_raw_mant_a, s1_raw_mant_b;
  logic [2:0] s1_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s1_sign_a <= 1'b0;
      s1_sign_b <= 1'b0;
      s1_exp_a <= '0;
      s1_exp_b <= '0;
      s1_mant_lzc_a <= '0;
      s1_mant_lzc_b <= '0;
      s1_is_subnormal_a <= 1'b0;
      s1_is_subnormal_b <= 1'b0;
      s1_is_zero_a <= 1'b0;
      s1_is_zero_b <= 1'b0;
      s1_is_inf_a <= 1'b0;
      s1_is_inf_b <= 1'b0;
      s1_is_nan_a <= 1'b0;
      s1_is_nan_b <= 1'b0;
      s1_is_snan_a <= 1'b0;
      s1_is_snan_b <= 1'b0;
      s1_raw_mant_a <= '0;
      s1_raw_mant_b <= '0;
      s1_rm <= 3'b0;
    end else begin
      s1_sign_a <= sign_a;
      s1_sign_b <= sign_b;
      s1_exp_a <= exp_a;
      s1_exp_b <= exp_b;
      s1_mant_lzc_a <= mant_lzc_a;
      s1_mant_lzc_b <= mant_lzc_b;
      s1_is_subnormal_a <= is_subnormal_a;
      s1_is_subnormal_b <= is_subnormal_b;
      s1_is_zero_a <= is_zero_a;
      s1_is_zero_b <= is_zero_b;
      s1_is_inf_a <= is_inf_a;
      s1_is_inf_b <= is_inf_b;
      s1_is_nan_a <= is_nan_a;
      s1_is_nan_b <= is_nan_b;
      s1_is_snan_a <= is_snan_a;
      s1_is_snan_b <= is_snan_b;
      s1_raw_mant_a <= s0_operand_a[FracBits-1:0];
      s1_raw_mant_b <= s0_operand_b[FracBits-1:0];
      s1_rm <= s0_rm;
    end
  end

  // =========================================================================
  // Stage 2: INIT — Mantissa Normalization and Special Case Detection
  // (combinational from s1, registered into s2)
  // =========================================================================
  logic [LzcMantBits:0] init_sub_shift_a, init_sub_shift_b;
  logic signed [ExpExtBits-1:0] init_exp_a_adj, init_exp_b_adj;
  logic [MantBits-1:0] init_mant_a, init_mant_b;
  logic init_is_special;
  logic [FP_WIDTH-1:0] init_special_result;
  logic init_special_invalid;
  logic init_special_div_zero;

  always_comb begin
    init_sub_shift_a = '0;
    init_sub_shift_b = '0;
    init_exp_a_adj = '0;
    init_exp_b_adj = '0;
    init_mant_a = '0;
    init_mant_b = '0;

    if (s1_is_subnormal_a) begin
      init_sub_shift_a = {1'b0, s1_mant_lzc_a} + {{LzcMantBits{1'b0}}, 1'b1};
      init_exp_a_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, init_sub_shift_a});
      init_mant_a = {1'b0, s1_raw_mant_a} << init_sub_shift_a;
    end else if (s1_exp_a == '0) begin
      init_exp_a_adj = '0;
      init_mant_a = '0;
    end else begin
      init_exp_a_adj = $signed({{(ExpExtBits - ExpBits) {1'b0}}, s1_exp_a});
      init_mant_a = {1'b1, s1_raw_mant_a};
    end

    if (s1_is_subnormal_b) begin
      init_sub_shift_b = {1'b0, s1_mant_lzc_b} + {{LzcMantBits{1'b0}}, 1'b1};
      init_exp_b_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, init_sub_shift_b});
      init_mant_b = {1'b0, s1_raw_mant_b} << init_sub_shift_b;
    end else if (s1_exp_b == '0) begin
      init_exp_b_adj = '0;
      init_mant_b = '0;
    end else begin
      init_exp_b_adj = $signed({{(ExpExtBits - ExpBits) {1'b0}}, s1_exp_b});
      init_mant_b = {1'b1, s1_raw_mant_b};
    end

    init_is_special = 1'b0;
    init_special_result = '0;
    init_special_invalid = 1'b0;
    init_special_div_zero = 1'b0;

    if (s1_is_nan_a || s1_is_nan_b) begin
      init_is_special = 1'b1;
      init_special_result = CanonicalNan;
      init_special_invalid = s1_is_snan_a | s1_is_snan_b;
    end else if (s1_is_inf_a && s1_is_inf_b) begin
      init_is_special = 1'b1;
      init_special_result = CanonicalNan;
      init_special_invalid = 1'b1;
    end else if (s1_is_zero_a && s1_is_zero_b) begin
      init_is_special = 1'b1;
      init_special_result = CanonicalNan;
      init_special_invalid = 1'b1;
    end else if (s1_is_inf_a) begin
      init_is_special = 1'b1;
      init_special_result = {s1_sign_a ^ s1_sign_b, ExpMax, {FracBits{1'b0}}};
    end else if (s1_is_inf_b) begin
      init_is_special = 1'b1;
      init_special_result = {s1_sign_a ^ s1_sign_b, {(FP_WIDTH - 1) {1'b0}}};
    end else if (s1_is_zero_b) begin
      init_is_special = 1'b1;
      init_special_result = {s1_sign_a ^ s1_sign_b, ExpMax, {FracBits{1'b0}}};
      init_special_div_zero = ~s1_is_zero_a;
    end else if (s1_is_zero_a) begin
      init_is_special = 1'b1;
      init_special_result = {s1_sign_a ^ s1_sign_b, {(FP_WIDTH - 1) {1'b0}}};
    end
  end

  // Stage 2 output registers
  logic s2_result_sign;
  logic signed [ExpExtBits-1:0] s2_exp_a_adj, s2_exp_b_adj;
  logic [MantBits-1:0] s2_mant_a, s2_mant_b;
  logic s2_is_special;
  logic [FP_WIDTH-1:0] s2_special_result;
  logic s2_special_invalid;
  logic s2_special_div_zero;
  logic [2:0] s2_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s2_result_sign <= 1'b0;
      s2_exp_a_adj <= '0;
      s2_exp_b_adj <= '0;
      s2_mant_a <= '0;
      s2_mant_b <= '0;
      s2_is_special <= 1'b0;
      s2_special_result <= '0;
      s2_special_invalid <= 1'b0;
      s2_special_div_zero <= 1'b0;
      s2_rm <= 3'b0;
    end else begin
      s2_result_sign <= s1_sign_a ^ s1_sign_b;
      s2_exp_a_adj <= init_exp_a_adj;
      s2_exp_b_adj <= init_exp_b_adj;
      s2_mant_a <= init_mant_a;
      s2_mant_b <= init_mant_b;
      s2_is_special <= init_is_special;
      s2_special_result <= init_special_result;
      s2_special_invalid <= init_special_invalid;
      s2_special_div_zero <= init_special_div_zero;
      s2_rm <= s1_rm;
    end
  end

  // =========================================================================
  // Stage 3: SETUP — compute result_exp, initial quotient/remainder/divisor
  // (combinational from s2, registered into s3)
  // =========================================================================
  logic signed [ExpExtBits-1:0] setup_result_exp;
  logic [DivBits-1:0] setup_quotient;
  logic [DivBits-1:0] setup_remainder;
  logic [DivBits-1:0] setup_divisor;

  always_comb begin
    setup_result_exp = s2_exp_a_adj - s2_exp_b_adj + ExpBiasExt;
    setup_divisor = {{(DivBits - MantBits) {1'b0}}, s2_mant_b};
    if (s2_mant_a >= s2_mant_b) begin
      setup_quotient  = {{(DivBits - 1) {1'b0}}, 1'b1};
      setup_remainder = {{(DivBits - MantBits) {1'b0}}, s2_mant_a - s2_mant_b};
    end else begin
      setup_quotient  = '0;
      setup_remainder = {{(DivBits - MantBits) {1'b0}}, s2_mant_a};
    end
  end

  // Stage 3 output registers
  logic signed [ExpExtBits-1:0] s3_result_exp;
  logic [DivBits-1:0] s3_quotient;
  logic [DivBits-1:0] s3_remainder;
  logic [DivBits-1:0] s3_divisor;
  // Metadata pass-through
  logic s3_result_sign;
  logic s3_is_special;
  logic [FP_WIDTH-1:0] s3_special_result;
  logic s3_special_invalid;
  logic s3_special_div_zero;
  logic [2:0] s3_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s3_result_exp <= '0;
      s3_quotient <= '0;
      s3_remainder <= '0;
      s3_divisor <= '0;
      s3_result_sign <= 1'b0;
      s3_is_special <= 1'b0;
      s3_special_result <= '0;
      s3_special_invalid <= 1'b0;
      s3_special_div_zero <= 1'b0;
      s3_rm <= 3'b0;
    end else begin
      s3_result_exp <= setup_result_exp;
      s3_quotient <= setup_quotient;
      s3_remainder <= setup_remainder;
      s3_divisor <= setup_divisor;
      s3_result_sign <= s2_result_sign;
      s3_is_special <= s2_is_special;
      s3_special_result <= s2_special_result;
      s3_special_invalid <= s2_special_invalid;
      s3_special_div_zero <= s2_special_div_zero;
      s3_rm <= s2_rm;
    end
  end

  // =========================================================================
  // Stages 4..4+DivCycles-1: DIVIDE — one radix-2 step per stage
  // =========================================================================

  // Pipeline arrays for divide stages (DivCycles+1 entries: index 0 = input, index DivCycles = output)
  logic        [   DivBits-1:0] div_quotient        [DivCycles+1];
  logic        [   DivBits-1:0] div_remainder       [DivCycles+1];
  logic        [   DivBits-1:0] div_divisor         [DivCycles+1];
  // Metadata arrays
  logic signed [ExpExtBits-1:0] div_result_exp      [DivCycles+1];
  logic                         div_result_sign     [DivCycles+1];
  logic                         div_is_special      [DivCycles+1];
  logic        [  FP_WIDTH-1:0] div_special_result  [DivCycles+1];
  logic                         div_special_invalid [DivCycles+1];
  logic                         div_special_div_zero[DivCycles+1];
  logic        [           2:0] div_rm              [DivCycles+1];

  // Connect stage 3 output to divide pipeline input
  assign div_quotient[0]         = s3_quotient;
  assign div_remainder[0]        = s3_remainder;
  assign div_divisor[0]          = s3_divisor;
  assign div_result_exp[0]       = s3_result_exp;
  assign div_result_sign[0]      = s3_result_sign;
  assign div_is_special[0]       = s3_is_special;
  assign div_special_result[0]   = s3_special_result;
  assign div_special_invalid[0]  = s3_special_invalid;
  assign div_special_div_zero[0] = s3_special_div_zero;
  assign div_rm[0]               = s3_rm;

  // Generate block: one radix-2 division step per stage
  for (genvar g = 0; g < DivCycles; g++) begin : gen_div
    // Combinational: trial subtract
    logic [DivBits-1:0] shifted_rem;
    logic [DivBits-1:0] diff;
    logic               diff_neg;

    assign shifted_rem = {div_remainder[g][DivBits-2:0], 1'b0};
    assign diff = shifted_rem - div_divisor[g];
    assign diff_neg = diff[DivBits-1];

    // Registered output
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        div_quotient[g+1]         <= '0;
        div_remainder[g+1]        <= '0;
        div_divisor[g+1]          <= '0;
        div_result_exp[g+1]       <= '0;
        div_result_sign[g+1]      <= 1'b0;
        div_is_special[g+1]       <= 1'b0;
        div_special_result[g+1]   <= '0;
        div_special_invalid[g+1]  <= 1'b0;
        div_special_div_zero[g+1] <= 1'b0;
        div_rm[g+1]               <= 3'b0;
      end else begin
        if (diff_neg) begin
          div_remainder[g+1] <= shifted_rem;
          div_quotient[g+1]  <= {div_quotient[g][DivBits-2:0], 1'b0};
        end else begin
          div_remainder[g+1] <= diff;
          div_quotient[g+1]  <= {div_quotient[g][DivBits-2:0], 1'b1};
        end
        div_divisor[g+1]          <= div_divisor[g];
        div_result_exp[g+1]       <= div_result_exp[g];
        div_result_sign[g+1]      <= div_result_sign[g];
        div_is_special[g+1]       <= div_is_special[g];
        div_special_result[g+1]   <= div_special_result[g];
        div_special_invalid[g+1]  <= div_special_invalid[g];
        div_special_div_zero[g+1] <= div_special_div_zero[g];
        div_rm[g+1]               <= div_rm[g];
      end
    end
  end

  // =========================================================================
  // Stage 4+DivCycles: NORMALIZE_PREP — LZC on quotient
  // =========================================================================
  logic [QuotLzcBits-1:0] norm_prep_lzc;
  logic                   norm_prep_is_zero;

  fp_lzc #(
      .WIDTH(DivBits)
  ) u_quot_lzc (
      .i_value(div_quotient[DivCycles]),
      .o_lzc(norm_prep_lzc),
      .o_is_zero(norm_prep_is_zero)
  );

  // Stage registers
  logic [DivBits-1:0] s_nprep_quotient;
  logic [DivBits-1:0] s_nprep_remainder;
  logic signed [ExpExtBits-1:0] s_nprep_result_exp;
  logic [QuotLzcBits-1:0] s_nprep_lzc;
  logic s_nprep_is_zero;
  logic s_nprep_result_sign;
  logic s_nprep_is_special;
  logic [FP_WIDTH-1:0] s_nprep_special_result;
  logic s_nprep_special_invalid;
  logic s_nprep_special_div_zero;
  logic [2:0] s_nprep_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_nprep_quotient <= '0;
      s_nprep_remainder <= '0;
      s_nprep_result_exp <= '0;
      s_nprep_lzc <= '0;
      s_nprep_is_zero <= 1'b0;
      s_nprep_result_sign <= 1'b0;
      s_nprep_is_special <= 1'b0;
      s_nprep_special_result <= '0;
      s_nprep_special_invalid <= 1'b0;
      s_nprep_special_div_zero <= 1'b0;
      s_nprep_rm <= 3'b0;
    end else begin
      s_nprep_quotient <= div_quotient[DivCycles];
      s_nprep_remainder <= div_remainder[DivCycles];
      s_nprep_result_exp <= div_result_exp[DivCycles];
      s_nprep_lzc <= norm_prep_lzc;
      s_nprep_is_zero <= norm_prep_is_zero;
      s_nprep_result_sign <= div_result_sign[DivCycles];
      s_nprep_is_special <= div_is_special[DivCycles];
      s_nprep_special_result <= div_special_result[DivCycles];
      s_nprep_special_invalid <= div_special_invalid[DivCycles];
      s_nprep_special_div_zero <= div_special_div_zero[DivCycles];
      s_nprep_rm <= div_rm[DivCycles];
    end
  end

  // =========================================================================
  // Stage 4+DivCycles+1: NORMALIZE — shift quotient, adjust exponent
  // =========================================================================
  logic [DivBits-1:0] norm_quotient;
  logic signed [ExpExtBits-1:0] norm_result_exp;

  always_comb begin
    norm_quotient   = s_nprep_quotient;
    norm_result_exp = s_nprep_result_exp;
    if (!s_nprep_is_zero && s_nprep_lzc != 0) begin
      norm_quotient = s_nprep_quotient << s_nprep_lzc;
      norm_result_exp = s_nprep_result_exp -
          $signed({{(ExpExtBits - QuotLzcBits) {1'b0}}, s_nprep_lzc});
    end
  end

  // Stage registers
  logic [DivBits-1:0] s_norm_quotient;
  logic [DivBits-1:0] s_norm_remainder;
  logic signed [ExpExtBits-1:0] s_norm_result_exp;
  logic s_norm_result_sign;
  logic s_norm_is_special;
  logic [FP_WIDTH-1:0] s_norm_special_result;
  logic s_norm_special_invalid;
  logic s_norm_special_div_zero;
  logic [2:0] s_norm_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_norm_quotient <= '0;
      s_norm_remainder <= '0;
      s_norm_result_exp <= '0;
      s_norm_result_sign <= 1'b0;
      s_norm_is_special <= 1'b0;
      s_norm_special_result <= '0;
      s_norm_special_invalid <= 1'b0;
      s_norm_special_div_zero <= 1'b0;
      s_norm_rm <= 3'b0;
    end else begin
      s_norm_quotient <= norm_quotient;
      s_norm_remainder <= s_nprep_remainder;
      s_norm_result_exp <= norm_result_exp;
      s_norm_result_sign <= s_nprep_result_sign;
      s_norm_is_special <= s_nprep_is_special;
      s_norm_special_result <= s_nprep_special_result;
      s_norm_special_invalid <= s_nprep_special_invalid;
      s_norm_special_div_zero <= s_nprep_special_div_zero;
      s_norm_rm <= s_nprep_rm;
    end
  end

  // =========================================================================
  // Stage 4+DivCycles+2: ROUND_SHIFT — fp_subnorm_shift
  // =========================================================================

  // Extract rounding bits from normalized quotient
  logic [MantBits:0] rsh_pre_round_mant;
  logic              rsh_guard_bit;
  logic              rsh_round_bit;
  logic              rsh_sticky_bit;
  logic              rsh_is_zero;

  assign rsh_pre_round_mant = s_norm_quotient[DivBits-1-:(MantBits+1)];
  assign rsh_guard_bit      = s_norm_quotient[1];
  assign rsh_round_bit      = s_norm_quotient[0];
  assign rsh_sticky_bit     = |s_norm_remainder;
  assign rsh_is_zero        = (s_norm_quotient == '0) && (s_norm_remainder == '0);

  logic [MantBits-1:0] rsh_mantissa_retained;
  assign rsh_mantissa_retained = rsh_pre_round_mant[MantBits:1];

  logic [MantBits-1:0] rsh_mantissa_out;
  logic rsh_guard_out, rsh_round_out, rsh_sticky_out;
  logic signed [ExpExtBits-1:0] rsh_exp_out;

  fp_subnorm_shift #(
      .MANT_BITS(MantBits),
      .EXP_EXT_BITS(ExpExtBits)
  ) u_subnorm_shift (
      .i_mantissa(rsh_mantissa_retained),
      .i_guard(rsh_pre_round_mant[0]),
      .i_round(rsh_guard_bit),
      .i_sticky(rsh_round_bit | rsh_sticky_bit),
      .i_exponent(s_norm_result_exp),
      .o_mantissa(rsh_mantissa_out),
      .o_guard(rsh_guard_out),
      .o_round(rsh_round_out),
      .o_sticky(rsh_sticky_out),
      .o_exponent(rsh_exp_out)
  );

  // Stage registers
  logic signed [ExpExtBits-1:0] s_rsh_exp;
  logic [MantBits-1:0] s_rsh_mantissa;
  logic s_rsh_guard, s_rsh_round, s_rsh_sticky;
  logic s_rsh_is_zero;
  logic [2:0] s_rsh_rm;
  logic s_rsh_result_sign;
  logic s_rsh_is_special;
  logic [FP_WIDTH-1:0] s_rsh_special_result;
  logic s_rsh_special_invalid;
  logic s_rsh_special_div_zero;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_rsh_exp <= '0;
      s_rsh_mantissa <= '0;
      s_rsh_guard <= 1'b0;
      s_rsh_round <= 1'b0;
      s_rsh_sticky <= 1'b0;
      s_rsh_is_zero <= 1'b0;
      s_rsh_rm <= 3'b0;
      s_rsh_result_sign <= 1'b0;
      s_rsh_is_special <= 1'b0;
      s_rsh_special_result <= '0;
      s_rsh_special_invalid <= 1'b0;
      s_rsh_special_div_zero <= 1'b0;
    end else begin
      s_rsh_exp <= rsh_exp_out;
      s_rsh_mantissa <= rsh_mantissa_out;
      s_rsh_guard <= rsh_guard_out;
      s_rsh_round <= rsh_round_out;
      s_rsh_sticky <= rsh_sticky_out;
      s_rsh_is_zero <= rsh_is_zero;
      s_rsh_rm <= s_norm_rm;
      s_rsh_result_sign <= s_norm_result_sign;
      s_rsh_is_special <= s_norm_is_special;
      s_rsh_special_result <= s_norm_special_result;
      s_rsh_special_invalid <= s_norm_special_invalid;
      s_rsh_special_div_zero <= s_norm_special_div_zero;
    end
  end

  // =========================================================================
  // Stage 4+DivCycles+3: ROUND_PREP — compute round-up decision
  // =========================================================================
  logic rprep_round_up;
  logic rprep_lsb;
  logic rprep_is_inexact;

  assign rprep_lsb = s_rsh_mantissa[0];
  assign rprep_round_up = riscv_pkg::fp_compute_round_up(
      s_rsh_rm, s_rsh_guard, s_rsh_round, s_rsh_sticky, rprep_lsb, s_rsh_result_sign
  );
  assign rprep_is_inexact = s_rsh_guard | s_rsh_round | s_rsh_sticky;

  // Stage registers
  logic s_rprep_result_sign;
  logic signed [ExpExtBits-1:0] s_rprep_exp;
  logic [MantBits-1:0] s_rprep_mantissa;
  logic s_rprep_round_up;
  logic s_rprep_is_inexact;
  logic s_rprep_is_zero;
  logic [2:0] s_rprep_rm;
  logic s_rprep_is_special;
  logic [FP_WIDTH-1:0] s_rprep_special_result;
  logic s_rprep_special_invalid;
  logic s_rprep_special_div_zero;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_rprep_result_sign <= 1'b0;
      s_rprep_exp <= '0;
      s_rprep_mantissa <= '0;
      s_rprep_round_up <= 1'b0;
      s_rprep_is_inexact <= 1'b0;
      s_rprep_is_zero <= 1'b0;
      s_rprep_rm <= 3'b0;
      s_rprep_is_special <= 1'b0;
      s_rprep_special_result <= '0;
      s_rprep_special_invalid <= 1'b0;
      s_rprep_special_div_zero <= 1'b0;
    end else begin
      s_rprep_result_sign <= s_rsh_result_sign;
      s_rprep_exp <= s_rsh_exp;
      s_rprep_mantissa <= s_rsh_mantissa;
      s_rprep_round_up <= rprep_round_up;
      s_rprep_is_inexact <= rprep_is_inexact;
      s_rprep_is_zero <= s_rsh_is_zero;
      s_rprep_rm <= s_rsh_rm;
      s_rprep_is_special <= s_rsh_is_special;
      s_rprep_special_result <= s_rsh_special_result;
      s_rprep_special_invalid <= s_rsh_special_invalid;
      s_rprep_special_div_zero <= s_rsh_special_div_zero;
    end
  end

  // =========================================================================
  // Stage 4+DivCycles+4: ROUND_APPLY — fp_result_assembler
  // =========================================================================
  logic [FP_WIDTH-1:0] rapply_result;
  riscv_pkg::fp_flags_t rapply_flags;

  fp_result_assembler #(
      .FP_WIDTH(FP_WIDTH),
      .ExpBits(ExpBits),
      .FracBits(FracBits),
      .MantBits(MantBits),
      .ExpExtBits(ExpExtBits)
  ) u_result_asm (
      .i_exp_work(s_rprep_exp),
      .i_mantissa_work(s_rprep_mantissa),
      .i_round_up(s_rprep_round_up),
      .i_is_inexact(s_rprep_is_inexact),
      .i_result_sign(s_rprep_result_sign),
      .i_rm(s_rprep_rm),
      .i_is_special(s_rprep_is_special),
      .i_special_result(s_rprep_special_result),
      .i_special_invalid(s_rprep_special_invalid),
      .i_special_div_zero(s_rprep_special_div_zero),
      .i_is_zero_result(s_rprep_is_zero & ~s_rprep_is_special),
      .i_zero_sign(s_rprep_result_sign),
      .o_result(rapply_result),
      .o_flags(rapply_flags)
  );

  // Stage registers
  logic [FP_WIDTH-1:0] s_rapply_result;
  riscv_pkg::fp_flags_t s_rapply_flags;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_rapply_result <= '0;
      s_rapply_flags  <= '0;
    end else begin
      s_rapply_result <= rapply_result;
      s_rapply_flags  <= rapply_flags;
    end
  end

  // =========================================================================
  // Stage 4+DivCycles+5: OUTPUT — register final result
  // =========================================================================
  logic [FP_WIDTH-1:0] s_output_result;
  riscv_pkg::fp_flags_t s_output_flags;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_output_result <= '0;
      s_output_flags  <= '0;
    end else begin
      s_output_result <= s_rapply_result;
      s_output_flags  <= s_rapply_flags;
    end
  end

  // =========================================================================
  // Outputs
  // =========================================================================
  assign o_result = s_output_result;
  assign o_flags  = s_output_flags;
  assign o_valid  = pipe_valid[TotalStages];
  assign o_stall  = 1'b0;  // Fully pipelined — never stalls

endmodule : fp_divider
