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
  IEEE 754 floating-point square root — fully pipelined.

  Accepts a new operation every cycle. Pipeline depth:
    SP (FP_WIDTH=32): RootBits + 9 = 27 + 9 = 36 stages (padded +1 to match divider)
    DP (FP_WIDTH=64): RootBits + 9 = 56 + 9 = 65 stages (padded +1 to match divider)

  Pipeline structure:
    Stage 0:  Input capture
    Stage 1:  SETUP — unpack, classify, LZC, special case detect, exp/mantissa adjustment
    Stage 2:  PREP — initialize sqrt state (root=0, remainder=0, radicand shifted)
    Stages 3..3+RootBits-1:  COMPUTE — one digit-recurrence step per stage
    Stage 3+RootBits:    PAD — extra register stage (aligns depth with divider)
    Stage 3+RootBits+1:  NORMALIZE
    Stage 3+RootBits+2:  ROUND_SHIFT
    Stage 3+RootBits+3:  ROUND_PREP
    Stage 3+RootBits+4:  ROUND_APPLY
    Stage 3+RootBits+5:  OUTPUT

  Special cases (NaN, negative, inf, zero) detected at SETUP. The COMPUTE
  stages still execute on don't-care data; the OUTPUT stage selects the
  special result when is_special is set.
*/
module fp_sqrt #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_valid,
    input  logic                 [FP_WIDTH-1:0] i_operand,
    input  logic                 [         2:0] i_rounding_mode,
    output logic                 [FP_WIDTH-1:0] o_result,
    output logic                                o_valid,
    output logic                                o_stall,
    output riscv_pkg::fp_flags_t                o_flags
);

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned RootBits = MantBits + 3;
  localparam int unsigned RadicandBits = 2 * RootBits;
  localparam int unsigned RemBits = (2 * RootBits) + 2;
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned LzcMantBits = $clog2(FracBits + 1);
  localparam int unsigned ShiftBits = $clog2(MantBits + 3 + 1);
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};
  localparam logic [FP_WIDTH-1:0] CanonicalNan = {1'b0, ExpMax, 1'b1, {FracBits - 1{1'b0}}};
  localparam logic signed [ExpExtBits-1:0] ExpBiasExt = ExpExtBits'(ExpBias);
  localparam logic signed [ExpExtBits-1:0] ExpBiasMinus1Ext = ExpExtBits'(ExpBias - 1);

  // Total stages: 3 (input+setup+prep) + RootBits (compute) + 1 (pad) + 5 (norm..output) = RootBits + 9
  localparam int unsigned TotalStages = RootBits + 9;

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
  logic [FP_WIDTH-1:0] s0_operand;
  logic [2:0] s0_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s0_operand <= '0;
      s0_rm <= 3'b0;
    end else if (i_valid) begin
      s0_operand <= i_operand;
      s0_rm <= i_rounding_mode;
    end
  end

  // =========================================================================
  // Stage 1: SETUP — unpack, classify, LZC, special case detect, exp adjustment
  // (combinational from s0, registered into s1)
  // =========================================================================
  logic                setup_sign;
  logic [ ExpBits-1:0] setup_exp;
  logic [FracBits-1:0] setup_mant;
  logic setup_is_zero, setup_is_inf, setup_is_nan, setup_is_snan;
  logic setup_is_subnormal;

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack (
      .i_operand(s0_operand),
      .o_sign(setup_sign),
      .o_exp(setup_exp),
      .o_exp_adj(),
      .o_frac(setup_mant),
      .o_mant(),
      .o_is_zero(setup_is_zero),
      .o_is_subnormal(setup_is_subnormal),
      .o_is_inf(setup_is_inf),
      .o_is_nan(setup_is_nan),
      .o_is_snan(setup_is_snan)
  );

  logic [LzcMantBits-1:0] setup_mant_lzc;
  logic                   setup_mant_lzc_zero;
  fp_lzc #(
      .WIDTH(FracBits)
  ) u_mant_lzc (
      .i_value(setup_mant),
      .o_lzc(setup_mant_lzc),
      .o_is_zero(setup_mant_lzc_zero)
  );

  // Combinational setup logic
  logic [LzcMantBits:0] setup_sub_shift;
  logic signed [ExpExtBits-1:0] setup_exp_adj;
  logic [MantBits-1:0] setup_mant_norm;
  logic setup_is_special;
  logic [FP_WIDTH-1:0] setup_special_result;
  logic setup_special_invalid;
  logic signed [ExpExtBits-1:0] setup_unbiased_exp;
  logic setup_exp_is_even;
  logic signed [ExpExtBits:0] setup_adjusted_exp;
  logic [MantBits:0] setup_mantissa_int;

  always_comb begin
    setup_sub_shift = '0;
    setup_exp_adj = '0;
    setup_mant_norm = '0;
    setup_unbiased_exp = '0;
    setup_exp_is_even = 1'b0;
    setup_adjusted_exp = '0;
    setup_mantissa_int = '0;

    if (setup_is_subnormal) begin
      setup_sub_shift = {1'b0, setup_mant_lzc} + {{LzcMantBits{1'b0}}, 1'b1};
      setup_exp_adj = $signed({{(ExpExtBits) {1'b0}}}) + 1 -
          $signed({{(ExpExtBits - LzcMantBits - 1) {1'b0}}, setup_sub_shift});
      setup_mant_norm = {1'b0, setup_mant} << setup_sub_shift;
    end else begin
      setup_exp_adj   = $signed({{(ExpExtBits - ExpBits) {1'b0}}, setup_exp});
      setup_mant_norm = {1'b1, setup_mant};
    end

    // Special case detection
    setup_is_special = 1'b0;
    setup_special_result = '0;
    setup_special_invalid = 1'b0;

    if (setup_is_nan) begin
      setup_is_special = 1'b1;
      setup_special_result = CanonicalNan;
      setup_special_invalid = setup_is_snan;
    end else if (setup_sign && !setup_is_zero) begin
      setup_is_special = 1'b1;
      setup_special_result = CanonicalNan;
      setup_special_invalid = 1'b1;
    end else if (setup_is_inf) begin
      setup_is_special = 1'b1;
      setup_special_result = {1'b0, ExpMax, {FracBits{1'b0}}};
    end else if (setup_is_zero) begin
      setup_is_special = 1'b1;
      setup_special_result = {setup_sign, {(FP_WIDTH - 1) {1'b0}}};
    end

    setup_unbiased_exp = setup_exp_adj - ExpBiasExt;
    setup_exp_is_even  = ~setup_unbiased_exp[0];

    if (setup_exp_is_even) begin
      setup_adjusted_exp = setup_exp_adj + ExpBiasExt;
      setup_mantissa_int = {1'b0, setup_mant_norm};
    end else begin
      setup_adjusted_exp = setup_exp_adj + ExpBiasMinus1Ext;
      setup_mantissa_int = {setup_mant_norm, 1'b0};
    end
  end

  // Stage 1 output registers
  logic s1_is_special;
  logic [FP_WIDTH-1:0] s1_special_result;
  logic s1_special_invalid;
  logic signed [ExpExtBits:0] s1_adjusted_exp;
  logic [MantBits:0] s1_mantissa_int;
  logic [2:0] s1_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s1_is_special <= 1'b0;
      s1_special_result <= '0;
      s1_special_invalid <= 1'b0;
      s1_adjusted_exp <= '0;
      s1_mantissa_int <= '0;
      s1_rm <= 3'b0;
    end else begin
      s1_is_special <= setup_is_special;
      s1_special_result <= setup_special_result;
      s1_special_invalid <= setup_special_invalid;
      s1_adjusted_exp <= setup_adjusted_exp;
      s1_mantissa_int <= setup_mantissa_int;
      s1_rm <= s0_rm;
    end
  end

  // =========================================================================
  // Stage 2: PREP — initialize sqrt state
  // (combinational from s1, registered into s2)
  // =========================================================================
  logic signed [ExpExtBits-1:0] prep_result_exp;
  logic [RadicandBits-1:0] prep_radicand;

  always_comb begin
    prep_result_exp = ExpExtBits'($signed(s1_adjusted_exp >>> 1));
    prep_radicand = {{(RadicandBits-(MantBits+1)){1'b0}}, s1_mantissa_int} <<
                    ShiftBits'(MantBits + 5);
  end

  // Stage 2 output registers
  logic signed [ExpExtBits-1:0] s2_result_exp;
  logic [RootBits-1:0] s2_root;
  logic [RemBits-1:0] s2_remainder;
  logic [RadicandBits-1:0] s2_radicand;
  logic s2_is_special;
  logic [FP_WIDTH-1:0] s2_special_result;
  logic s2_special_invalid;
  logic [2:0] s2_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s2_result_exp <= '0;
      s2_root <= '0;
      s2_remainder <= '0;
      s2_radicand <= '0;
      s2_is_special <= 1'b0;
      s2_special_result <= '0;
      s2_special_invalid <= 1'b0;
      s2_rm <= 3'b0;
    end else begin
      s2_result_exp <= prep_result_exp;
      s2_root <= '0;
      s2_remainder <= '0;
      s2_radicand <= prep_radicand;
      s2_is_special <= s1_is_special;
      s2_special_result <= s1_special_result;
      s2_special_invalid <= s1_special_invalid;
      s2_rm <= s1_rm;
    end
  end

  // =========================================================================
  // Stages 3..3+RootBits-1: COMPUTE — one digit-recurrence step per stage
  // =========================================================================

  // Pipeline arrays (RootBits+1 entries: index 0 = input, index RootBits = output)
  logic        [    RootBits-1:0] comp_root           [RootBits+1];
  logic        [     RemBits-1:0] comp_remainder      [RootBits+1];
  logic        [RadicandBits-1:0] comp_radicand       [RootBits+1];
  // Metadata arrays
  logic signed [  ExpExtBits-1:0] comp_result_exp     [RootBits+1];
  logic                           comp_is_special     [RootBits+1];
  logic        [    FP_WIDTH-1:0] comp_special_result [RootBits+1];
  logic                           comp_special_invalid[RootBits+1];
  logic        [             2:0] comp_rm             [RootBits+1];

  // Connect stage 2 output to compute pipeline input
  assign comp_root[0]            = s2_root;
  assign comp_remainder[0]       = s2_remainder;
  assign comp_radicand[0]        = s2_radicand;
  assign comp_result_exp[0]      = s2_result_exp;
  assign comp_is_special[0]      = s2_is_special;
  assign comp_special_result[0]  = s2_special_result;
  assign comp_special_invalid[0] = s2_special_invalid;
  assign comp_rm[0]              = s2_rm;

  // Generate block: one digit-recurrence step per stage
  for (genvar g = 0; g < RootBits; g++) begin : gen_sqrt
    // Combinational: bring down 2 radicand bits, trial subtract, set root bit
    logic [RemBits-1:0] rem_candidate;
    logic [RemBits-1:0] trial_divisor;
    logic               rem_ge;

    assign rem_candidate = {comp_remainder[g][RemBits-3:0], comp_radicand[g][RadicandBits-1-:2]};
    assign trial_divisor = {{RootBits{1'b0}}, comp_root[g], 2'b01};
    assign rem_ge = rem_candidate >= trial_divisor;

    // Registered output
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        comp_root[g+1]            <= '0;
        comp_remainder[g+1]       <= '0;
        comp_radicand[g+1]        <= '0;
        comp_result_exp[g+1]      <= '0;
        comp_is_special[g+1]      <= 1'b0;
        comp_special_result[g+1]  <= '0;
        comp_special_invalid[g+1] <= 1'b0;
        comp_rm[g+1]              <= 3'b0;
      end else begin
        comp_radicand[g+1] <= {comp_radicand[g][RadicandBits-3:0], 2'b00};
        if (rem_ge) begin
          comp_remainder[g+1] <= rem_candidate - trial_divisor;
          comp_root[g+1]      <= {comp_root[g][RootBits-2:0], 1'b1};
        end else begin
          comp_remainder[g+1] <= rem_candidate;
          comp_root[g+1]      <= {comp_root[g][RootBits-2:0], 1'b0};
        end
        comp_result_exp[g+1]      <= comp_result_exp[g];
        comp_is_special[g+1]      <= comp_is_special[g];
        comp_special_result[g+1]  <= comp_special_result[g];
        comp_special_invalid[g+1] <= comp_special_invalid[g];
        comp_rm[g+1]              <= comp_rm[g];
      end
    end
  end

  // =========================================================================
  // Stage 3+RootBits: PAD — extra register stage to align with divider depth
  // =========================================================================
  logic [RootBits-1:0] s_pad_root;
  logic [RemBits-1:0] s_pad_remainder;
  logic signed [ExpExtBits-1:0] s_pad_result_exp;
  logic s_pad_is_special;
  logic [FP_WIDTH-1:0] s_pad_special_result;
  logic s_pad_special_invalid;
  logic [2:0] s_pad_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_pad_root <= '0;
      s_pad_remainder <= '0;
      s_pad_result_exp <= '0;
      s_pad_is_special <= 1'b0;
      s_pad_special_result <= '0;
      s_pad_special_invalid <= 1'b0;
      s_pad_rm <= 3'b0;
    end else begin
      s_pad_root <= comp_root[RootBits];
      s_pad_remainder <= comp_remainder[RootBits];
      s_pad_result_exp <= comp_result_exp[RootBits];
      s_pad_is_special <= comp_is_special[RootBits];
      s_pad_special_result <= comp_special_result[RootBits];
      s_pad_special_invalid <= comp_special_invalid[RootBits];
      s_pad_rm <= comp_rm[RootBits];
    end
  end

  // =========================================================================
  // Stage 3+RootBits+1: NORMALIZE
  // =========================================================================
  logic [RootBits-1:0] norm_root;
  logic signed [ExpExtBits-1:0] norm_result_exp;

  always_comb begin
    norm_root = s_pad_root;
    norm_result_exp = s_pad_result_exp;
    if (!s_pad_root[RootBits-1]) begin
      norm_root = s_pad_root << 1;
      norm_result_exp = s_pad_result_exp - 1;
    end
  end

  // Stage registers
  logic [RootBits-1:0] s_norm_root;
  logic [RemBits-1:0] s_norm_remainder;
  logic signed [ExpExtBits-1:0] s_norm_result_exp;
  logic s_norm_is_special;
  logic [FP_WIDTH-1:0] s_norm_special_result;
  logic s_norm_special_invalid;
  logic [2:0] s_norm_rm;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_norm_root <= '0;
      s_norm_remainder <= '0;
      s_norm_result_exp <= '0;
      s_norm_is_special <= 1'b0;
      s_norm_special_result <= '0;
      s_norm_special_invalid <= 1'b0;
      s_norm_rm <= 3'b0;
    end else begin
      s_norm_root <= norm_root;
      s_norm_remainder <= s_pad_remainder;
      s_norm_result_exp <= norm_result_exp;
      s_norm_is_special <= s_pad_is_special;
      s_norm_special_result <= s_pad_special_result;
      s_norm_special_invalid <= s_pad_special_invalid;
      s_norm_rm <= s_pad_rm;
    end
  end

  // =========================================================================
  // Stage 3+RootBits+2: ROUND_SHIFT — fp_subnorm_shift
  // =========================================================================
  logic [MantBits:0] rsh_pre_round_mant;
  logic              rsh_guard_bit;
  logic              rsh_round_bit;
  logic              rsh_sticky_bit;
  logic              rsh_is_zero;

  assign rsh_pre_round_mant = s_norm_root[RootBits-1-:(MantBits+1)];
  assign rsh_guard_bit      = s_norm_root[1];
  assign rsh_round_bit      = s_norm_root[0];
  assign rsh_sticky_bit     = |s_norm_remainder;
  assign rsh_is_zero        = (s_norm_root == '0) && (s_norm_remainder == '0);

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
  logic s_rsh_is_special;
  logic [FP_WIDTH-1:0] s_rsh_special_result;
  logic s_rsh_special_invalid;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_rsh_exp <= '0;
      s_rsh_mantissa <= '0;
      s_rsh_guard <= 1'b0;
      s_rsh_round <= 1'b0;
      s_rsh_sticky <= 1'b0;
      s_rsh_is_zero <= 1'b0;
      s_rsh_rm <= 3'b0;
      s_rsh_is_special <= 1'b0;
      s_rsh_special_result <= '0;
      s_rsh_special_invalid <= 1'b0;
    end else begin
      s_rsh_exp <= rsh_exp_out;
      s_rsh_mantissa <= rsh_mantissa_out;
      s_rsh_guard <= rsh_guard_out;
      s_rsh_round <= rsh_round_out;
      s_rsh_sticky <= rsh_sticky_out;
      s_rsh_is_zero <= rsh_is_zero;
      s_rsh_rm <= s_norm_rm;
      s_rsh_is_special <= s_norm_is_special;
      s_rsh_special_result <= s_norm_special_result;
      s_rsh_special_invalid <= s_norm_special_invalid;
    end
  end

  // =========================================================================
  // Stage 3+RootBits+3: ROUND_PREP — compute round-up decision
  // =========================================================================
  logic rprep_round_up;
  logic rprep_lsb;
  logic rprep_is_inexact;

  assign rprep_lsb = s_rsh_mantissa[0];
  // sqrt result is always positive (sign=0)
  assign rprep_round_up = riscv_pkg::fp_compute_round_up(
      s_rsh_rm, s_rsh_guard, s_rsh_round, s_rsh_sticky, rprep_lsb, 1'b0
  );
  assign rprep_is_inexact = s_rsh_guard | s_rsh_round | s_rsh_sticky;

  // Stage registers
  logic signed [ExpExtBits-1:0] s_rprep_exp;
  logic [MantBits-1:0] s_rprep_mantissa;
  logic s_rprep_round_up;
  logic s_rprep_is_inexact;
  logic s_rprep_is_zero;
  logic [2:0] s_rprep_rm;
  logic s_rprep_is_special;
  logic [FP_WIDTH-1:0] s_rprep_special_result;
  logic s_rprep_special_invalid;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s_rprep_exp <= '0;
      s_rprep_mantissa <= '0;
      s_rprep_round_up <= 1'b0;
      s_rprep_is_inexact <= 1'b0;
      s_rprep_is_zero <= 1'b0;
      s_rprep_rm <= 3'b0;
      s_rprep_is_special <= 1'b0;
      s_rprep_special_result <= '0;
      s_rprep_special_invalid <= 1'b0;
    end else begin
      s_rprep_exp <= s_rsh_exp;
      s_rprep_mantissa <= s_rsh_mantissa;
      s_rprep_round_up <= rprep_round_up;
      s_rprep_is_inexact <= rprep_is_inexact;
      s_rprep_is_zero <= s_rsh_is_zero;
      s_rprep_rm <= s_rsh_rm;
      s_rprep_is_special <= s_rsh_is_special;
      s_rprep_special_result <= s_rsh_special_result;
      s_rprep_special_invalid <= s_rsh_special_invalid;
    end
  end

  // =========================================================================
  // Stage 3+RootBits+4: ROUND_APPLY — fp_result_assembler
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
      .i_result_sign(1'b0),  // sqrt result is always positive
      .i_rm(s_rprep_rm),
      .i_is_special(s_rprep_is_special),
      .i_special_result(s_rprep_special_result),
      .i_special_invalid(s_rprep_special_invalid),
      .i_special_div_zero(1'b0),
      .i_is_zero_result(s_rprep_is_zero & ~s_rprep_is_special),
      .i_zero_sign(1'b0),
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
  // Stage 3+RootBits+5: OUTPUT — register final result
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

endmodule : fp_sqrt
