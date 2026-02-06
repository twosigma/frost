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
  Floating-point to integer and integer to floating-point conversions.

  Operations:
    FCVT.W.S:  rd = (int32_t)fs1    - Convert FP to signed 32-bit integer
    FCVT.WU.S: rd = (uint32_t)fs1   - Convert FP to unsigned 32-bit integer
    FCVT.S.W:  fd = (float)rs1      - Convert signed 32-bit integer to FP
    FCVT.S.WU: fd = (float)rs1      - Convert unsigned 32-bit integer to FP
    FMV.X.W:   rd = bits(fs1)       - Move FP bits to integer (no conversion)
    FMV.W.X:   fd = bits(rs1)       - Move integer bits to FP (no conversion)

  Multi-cycle implementation (5-cycle latency):
    Cycle 0: Capture operands, unpack, compute LZC / shift amounts
    Cycle 1: FP->int shift/round prep, int->fp normalize
    Cycle 2: FP->int round add
    Cycle 3: Final pack/flags
    Cycle 4: Output registered result

  Rounding:
    - Integer to FP may require rounding (24-bit mantissa for 32-bit int)
    - FP to integer uses specified rounding mode

  Exception handling:
    - Invalid (NV): FP to int conversion of NaN, infinity, or out of range
    - Inexact (NX): Result is not exact
*/
module fp_convert #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned FP_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [FP_WIDTH-1:0] i_fp_operand,  // FP source for FCVT.W/WU.*, FMV.X.*
    input logic [XLEN-1:0] i_int_operand,  // Integer source for FCVT.S.W/WU, FMV.W.X
    input riscv_pkg::instr_op_e i_operation,
    input logic [2:0] i_rounding_mode,
    output logic [FP_WIDTH-1:0] o_fp_result,  // Result for FCVT.*.W/WU, FMV.*.X
    output logic [XLEN-1:0] o_int_result,  // Result for FCVT.W/WU.S, FMV.X.W
    output logic o_is_fp_to_int,  // Result goes to integer register
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // =========================================================================
  // State Machine
  // =========================================================================
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    STAGE1 = 3'b001,
    STAGE2 = 3'b010,
    STAGE3 = 3'b011,
    STAGE4 = 3'b100
  } state_e;

  state_e state, next_state;

  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam int unsigned MantBits = FracBits + 1;
  localparam int unsigned ExpExtBits = ExpBits + 2;
  localparam int signed ExpBias = (1 << (ExpBits - 1)) - 1;
  localparam int unsigned ExtMantBits = MantBits + XLEN;
  localparam int unsigned IntLzcBits = $clog2(XLEN);
  localparam int unsigned ShiftBits = $clog2(ExtMantBits + 1);
  localparam int signed MaxExpSigned = XLEN - 2;
  localparam int signed MaxExpUnsigned = XLEN - 1;
  localparam logic [XLEN-1:0] IntMax = {1'b0, {XLEN - 1{1'b1}}};
  localparam logic [XLEN-1:0] IntMin = {1'b1, {XLEN - 1{1'b0}}};
  localparam logic [XLEN-1:0] UintMax = {XLEN{1'b1}};
  localparam logic signed [ExpExtBits-1:0] MaxExpSignedExt = ExpExtBits'(MaxExpSigned);
  localparam logic signed [ExpExtBits-1:0] MaxExpUnsignedExt = ExpExtBits'(MaxExpUnsigned);
  localparam logic signed [ExpExtBits-1:0] MantBitsMinus1Ext = ExpExtBits'(MantBits - 1);

  // =========================================================================
  // Registered inputs
  // =========================================================================
  logic                 [FP_WIDTH-1:0] fp_operand_reg;
  logic                 [    XLEN-1:0] int_operand_reg;
  riscv_pkg::instr_op_e                operation_reg;
  logic                 [         2:0] rm_reg;

  // =========================================================================
  // Stage 1: Unpack and prepare (combinational from registered inputs)
  // =========================================================================

  // FP field extraction
  logic                                fp_sign;
  logic                 [ ExpBits-1:0] fp_exp;
  logic                 [FracBits-1:0] fp_mant;
  logic fp_is_zero, fp_is_inf, fp_is_nan, fp_is_subnormal;
  logic [MantBits-1:0] fp_mantissa;

  assign fp_sign = fp_operand_reg[FP_WIDTH-1];
  assign fp_exp  = fp_operand_reg[FP_WIDTH-2-:ExpBits];
  assign fp_mant = fp_operand_reg[FracBits-1:0];

  fp_classify_operand #(
      .EXP_BITS (ExpBits),
      .FRAC_BITS(FracBits)
  ) u_classify (
      .i_exp(fp_exp),
      .i_frac(fp_mant),
      .o_is_zero(fp_is_zero),
      .o_is_subnormal(fp_is_subnormal),
      .o_is_inf(fp_is_inf),
      .o_is_nan(fp_is_nan),
      .o_is_snan()
  );
  assign fp_mantissa = (fp_exp == '0) ? {1'b0, fp_mant} : {1'b1, fp_mant};

  // Unbiased exponent
  logic signed [ExpExtBits-1:0] unbiased_exp;
  assign unbiased_exp = (fp_exp == '0) ? $signed(
      ExpExtBits'(1 - ExpBias)
  ) : $signed(
      {{(ExpExtBits - ExpBits) {1'b0}}, fp_exp}
  ) - ExpExtBits'(ExpBias);

  // Integer to FP: get absolute value and compute LZC
  logic [          XLEN-1:0] abs_int;
  logic                      int_sign;
  logic                      is_signed_conv;
  logic [    IntLzcBits-1:0] int_lzc;
  logic [$clog2(XLEN+1)-1:0] int_lzc_full;

  assign is_signed_conv = (operation_reg == riscv_pkg::FCVT_S_W) ||
                          (operation_reg == riscv_pkg::FCVT_D_W);

  always_comb begin
    if (is_signed_conv && int_operand_reg[31]) begin
      abs_int  = -int_operand_reg;
      int_sign = 1'b1;
    end else begin
      abs_int  = int_operand_reg;
      int_sign = 1'b0;
    end
  end

  // LZC for integer to FP - computed combinationally in stage 1
  fp_lzc #(
      .WIDTH(XLEN)
  ) u_int_lzc (
      .i_value (abs_int),
      .o_lzc   (int_lzc_full),
      .o_is_zero()
  );
  assign int_lzc = int_lzc_full[IntLzcBits-1:0];

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Registers
  // =========================================================================
  logic                fp_sign_s2;
  logic [ ExpBits-1:0] fp_exp_s2;
  logic [MantBits-1:0] fp_mantissa_s2;
  logic fp_is_zero_s2, fp_is_inf_s2, fp_is_nan_s2;
  logic signed          [ ExpExtBits-1:0] unbiased_exp_s2;
  logic                 [       XLEN-1:0] abs_int_s2;
  logic                                   int_sign_s2;
  logic                                   int_is_zero_s2;
  logic                 [ IntLzcBits-1:0] int_lzc_s2;
  riscv_pkg::instr_op_e                   operation_s2;
  logic                 [            2:0] rm_s2;

  // =========================================================================
  // Stage 2 -> Stage 3 Pipeline Registers
  // =========================================================================
  logic                 [       XLEN-1:0] fp_to_int_shifted_value_s3;
  logic                                   fp_to_int_round_bit_s3;
  logic                                   fp_to_int_sticky_bit_s3;
  logic                                   fp_to_int_inexact_pre_s3;
  logic                                   fp_to_int_force_valid_s3;
  logic                 [       XLEN-1:0] fp_to_int_force_result_s3;
  logic                                   fp_to_int_force_invalid_s3;
  logic                                   fp_to_int_force_inexact_s3;
  logic                                   fp_to_int_sign_s3;
  logic                                   fp_to_int_is_unsigned_s3;
  logic                 [            2:0] rm_s3;
  riscv_pkg::instr_op_e                   operation_s3;
  logic                 [   FP_WIDTH-1:0] int_to_fp_result_s3;
  logic                                   int_to_fp_inexact_s3;
  logic                 [   FP_WIDTH-1:0] move_fp_result_s3;
  logic                 [       XLEN-1:0] move_int_result_s3;

  // =========================================================================
  // Stage 3 -> Stage 4 Pipeline Registers
  // =========================================================================
  logic                 [         XLEN:0] fp_to_int_rounded_value_s4;
  logic                                   fp_to_int_do_round_up_s4;
  logic                 [       XLEN-1:0] fp_to_int_shifted_value_s4;
  logic                                   fp_to_int_inexact_pre_s4;
  logic                                   fp_to_int_force_valid_s4;
  logic                 [       XLEN-1:0] fp_to_int_force_result_s4;
  logic                                   fp_to_int_force_invalid_s4;
  logic                                   fp_to_int_force_inexact_s4;
  logic                                   fp_to_int_sign_s4;
  logic                                   fp_to_int_is_unsigned_s4;
  riscv_pkg::instr_op_e                   operation_s4;
  logic                 [   FP_WIDTH-1:0] int_to_fp_result_s4;
  logic                                   int_to_fp_inexact_s4;
  logic                 [   FP_WIDTH-1:0] move_fp_result_s4;
  logic                 [       XLEN-1:0] move_int_result_s4;

  // =========================================================================
  // Stage 2: FP->int prep, int->fp compute (combinational from stage 2 regs)
  // =========================================================================

  // FP to Integer conversion
  logic                                   is_unsigned_conv;
  logic                                   fp_to_int_force_valid_s2_comb;
  logic                 [       XLEN-1:0] fp_to_int_force_result_s2_comb;
  logic                                   fp_to_int_force_invalid_s2_comb;
  logic                                   fp_to_int_force_inexact_s2_comb;
  logic                 [       XLEN-1:0] fp_to_int_shifted_value_s2_comb;
  logic                                   fp_to_int_round_bit_s2_comb;
  logic                                   fp_to_int_sticky_bit_s2_comb;
  logic                                   fp_to_int_inexact_pre_s2_comb;

  logic                 [ExtMantBits-1:0] extended_mant;
  logic                 [ExtMantBits-1:0] mant_shifted_lsb;
  logic                 [       XLEN-1:0] shifted_value;
  logic round_bit, sticky_bit;
  logic [  ShiftBits-1:0] fp_to_int_shift_amt;
  logic [ExtMantBits-1:0] fp_to_int_shifted_ext;

  always_comb begin
    is_unsigned_conv = (operation_s2 == riscv_pkg::FCVT_WU_S) ||
                       (operation_s2 == riscv_pkg::FCVT_WU_D);
    fp_to_int_force_valid_s2_comb = 1'b0;
    fp_to_int_force_result_s2_comb = '0;
    fp_to_int_force_invalid_s2_comb = 1'b0;
    fp_to_int_force_inexact_s2_comb = 1'b0;
    fp_to_int_shifted_value_s2_comb = '0;
    fp_to_int_round_bit_s2_comb = 1'b0;
    fp_to_int_sticky_bit_s2_comb = 1'b0;
    fp_to_int_inexact_pre_s2_comb = 1'b0;
    extended_mant = '0;
    mant_shifted_lsb = '0;
    shifted_value = '0;
    round_bit = 1'b0;
    sticky_bit = 1'b0;
    fp_to_int_shift_amt = '0;
    fp_to_int_shifted_ext = '0;

    if (fp_is_nan_s2) begin
      fp_to_int_force_valid_s2_comb   = 1'b1;
      fp_to_int_force_invalid_s2_comb = 1'b1;
      fp_to_int_force_result_s2_comb  = is_unsigned_conv ? UintMax : IntMax;
    end else if (fp_is_inf_s2) begin
      fp_to_int_force_valid_s2_comb   = 1'b1;
      fp_to_int_force_invalid_s2_comb = 1'b1;
      if (fp_sign_s2) begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? '0 : IntMin;
      end else begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? UintMax : IntMax;
      end
    end else if (fp_is_zero_s2) begin
      fp_to_int_force_valid_s2_comb  = 1'b1;
      fp_to_int_force_result_s2_comb = '0;
    end else begin
      extended_mant = {fp_mantissa_s2, {XLEN{1'b0}}};
      mant_shifted_lsb = {{(ExtMantBits - MantBits) {1'b0}}, fp_mantissa_s2};

      if (unbiased_exp_s2 < 0) begin
        shifted_value = '0;
        round_bit = (unbiased_exp_s2 == -1) ? extended_mant[ExtMantBits-1] : 1'b0;
        sticky_bit = (unbiased_exp_s2 == -1) ? |extended_mant[ExtMantBits-2:0] : |extended_mant;
        fp_to_int_inexact_pre_s2_comb = 1'b1;
      end else if (unbiased_exp_s2 > MaxExpSignedExt) begin
        if (is_unsigned_conv && !fp_sign_s2 && (unbiased_exp_s2 <= MaxExpUnsignedExt)) begin
          if (unbiased_exp_s2 >= MantBitsMinus1Ext) begin
            fp_to_int_shift_amt = ShiftBits'(unbiased_exp_s2 - MantBitsMinus1Ext);
            fp_to_int_shifted_ext = mant_shifted_lsb << fp_to_int_shift_amt;
            shifted_value = fp_to_int_shifted_ext[XLEN-1:0];
            round_bit = 1'b0;
            sticky_bit = 1'b0;
          end else begin
            fp_to_int_shift_amt = ShiftBits'((XLEN - 1) - int'(unbiased_exp_s2));
            fp_to_int_shifted_ext = extended_mant >> fp_to_int_shift_amt;
            shifted_value = fp_to_int_shifted_ext[ExtMantBits-1:MantBits];
            round_bit = fp_to_int_shifted_ext[MantBits-1];
            sticky_bit = |fp_to_int_shifted_ext[MantBits-2:0];
            fp_to_int_inexact_pre_s2_comb = round_bit | sticky_bit;
          end
        end else begin
          fp_to_int_force_valid_s2_comb   = 1'b1;
          fp_to_int_force_invalid_s2_comb = 1'b1;
          if (fp_sign_s2) begin
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? '0 : IntMin;
          end else begin
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? UintMax : IntMax;
          end
          shifted_value = '0;
          round_bit = 1'b0;
          sticky_bit = 1'b0;
        end
      end else begin
        if (unbiased_exp_s2 >= MantBitsMinus1Ext) begin
          fp_to_int_shift_amt = ShiftBits'(unbiased_exp_s2 - MantBitsMinus1Ext);
          fp_to_int_shifted_ext = mant_shifted_lsb << fp_to_int_shift_amt;
          shifted_value = fp_to_int_shifted_ext[XLEN-1:0];
          round_bit = 1'b0;
          sticky_bit = 1'b0;
        end else begin
          fp_to_int_shift_amt = ShiftBits'((XLEN - 1) - int'(unbiased_exp_s2));
          fp_to_int_shifted_ext = extended_mant >> fp_to_int_shift_amt;
          shifted_value = fp_to_int_shifted_ext[ExtMantBits-1:MantBits];
          round_bit = fp_to_int_shifted_ext[MantBits-1];
          sticky_bit = |fp_to_int_shifted_ext[MantBits-2:0];
          fp_to_int_inexact_pre_s2_comb = round_bit | sticky_bit;
        end
      end
    end

    fp_to_int_shifted_value_s2_comb = shifted_value;
    fp_to_int_round_bit_s2_comb = round_bit;
    fp_to_int_sticky_bit_s2_comb = sticky_bit;
  end

  // Integer to FP conversion
  logic [FP_WIDTH-1:0] int_to_fp_result;
  logic                int_to_fp_inexact;

  logic [    XLEN-1:0] int_to_fp_normalized_mant;
  logic [ ExpBits-1:0] int_to_fp_result_exp;
  logic [FracBits-1:0] int_to_fp_mant;
  logic int_to_fp_r_bit, int_to_fp_s_bit;
  logic int_to_fp_round_up;
  logic [FracBits:0] int_to_fp_rounded_mant;
  logic is_signed_conv_s2;
  logic [FracBits-1:0] int_to_fp_mant_calc;
  logic int_to_fp_r_bit_calc;
  logic int_to_fp_s_bit_calc;

  generate
    if (FracBits >= (XLEN - 1)) begin : gen_int_to_fp_mant_wide
      assign int_to_fp_mant_calc = {
        int_to_fp_normalized_mant[XLEN-2:0], {(FracBits - (XLEN - 1)) {1'b0}}
      };
      assign int_to_fp_r_bit_calc = 1'b0;
      assign int_to_fp_s_bit_calc = 1'b0;
    end else begin : gen_int_to_fp_mant_narrow
      assign int_to_fp_mant_calc  = int_to_fp_normalized_mant[XLEN-2-:FracBits];
      assign int_to_fp_r_bit_calc = int_to_fp_normalized_mant[XLEN-2-FracBits];
      assign int_to_fp_s_bit_calc = |int_to_fp_normalized_mant[XLEN-3-FracBits:0];
    end
  endgenerate

  always_comb begin
    int_to_fp_result = '0;
    int_to_fp_inexact = 1'b0;
    is_signed_conv_s2 = (operation_s2 == riscv_pkg::FCVT_S_W) ||
                        (operation_s2 == riscv_pkg::FCVT_D_W);
    int_to_fp_normalized_mant = '0;
    int_to_fp_result_exp = '0;
    int_to_fp_mant = '0;
    int_to_fp_r_bit = 1'b0;
    int_to_fp_s_bit = 1'b0;
    int_to_fp_round_up = 1'b0;
    int_to_fp_rounded_mant = '0;

    if (int_is_zero_s2) begin
      int_to_fp_result = {int_sign_s2, {(FP_WIDTH - 1) {1'b0}}};
    end else begin
      // Use pre-computed LZC to normalize
      int_to_fp_normalized_mant = abs_int_s2 << int_lzc_s2;
      int_to_fp_result_exp = ExpBits'(ExpBias + (XLEN - 1 - int'(int_lzc_s2)));

      if (FracBits >= (XLEN - 1)) begin
        // Exact conversion (integer fits fully in mantissa)
        int_to_fp_mant = int_to_fp_mant_calc;
        int_to_fp_inexact = 1'b0;
      end else begin
        int_to_fp_mant = int_to_fp_mant_calc;
        int_to_fp_r_bit = int_to_fp_r_bit_calc;
        int_to_fp_s_bit = int_to_fp_s_bit_calc;

        int_to_fp_inexact = int_to_fp_r_bit | int_to_fp_s_bit;

        int_to_fp_round_up = riscv_pkg::fp_compute_round_up(
            rm_s2, int_to_fp_r_bit, 1'b0, int_to_fp_s_bit, int_to_fp_mant[0], int_sign_s2);

        int_to_fp_rounded_mant = {1'b0, int_to_fp_mant} + {{FracBits{1'b0}}, int_to_fp_round_up};

        if (int_to_fp_rounded_mant[FracBits]) begin
          int_to_fp_result_exp = int_to_fp_result_exp + 1;
          int_to_fp_mant = '0;
        end else begin
          int_to_fp_mant = int_to_fp_rounded_mant[FracBits-1:0];
        end
      end

      int_to_fp_result = {int_sign_s2, int_to_fp_result_exp, int_to_fp_mant};
    end
  end

  logic [FP_WIDTH-1:0] move_fp_result_s2_comb;
  logic [XLEN-1:0] move_int_result_s2_comb;

  generate
    if (FP_WIDTH > XLEN) begin : gen_move_fp_pad
      assign move_fp_result_s2_comb = {{(FP_WIDTH - XLEN) {1'b0}}, int_operand_reg};
    end else begin : gen_move_fp_nopad
      assign move_fp_result_s2_comb = int_operand_reg[FP_WIDTH-1:0];
    end
  endgenerate

  assign move_int_result_s2_comb = fp_operand_reg[XLEN-1:0];

  // =========================================================================
  // Stage 3: FP->int rounding add (combinational from stage 3 regs)
  // =========================================================================
  logic fp_to_int_do_round_up_s3_comb;
  logic [XLEN:0] fp_to_int_rounded_value_s3_comb;

  always_comb begin
    fp_to_int_do_round_up_s3_comb   = 1'b0;
    fp_to_int_rounded_value_s3_comb = '0;

    if (!fp_to_int_force_valid_s3) begin
      fp_to_int_do_round_up_s3_comb = riscv_pkg::fp_compute_round_up(
        rm_s3,
        fp_to_int_round_bit_s3,
        1'b0,
        fp_to_int_sticky_bit_s3,
        fp_to_int_shifted_value_s3[0],
        fp_to_int_sign_s3
      );

      fp_to_int_rounded_value_s3_comb =
          {1'b0, fp_to_int_shifted_value_s3} +
          {{XLEN{1'b0}}, fp_to_int_do_round_up_s3_comb};
    end
  end

  // =========================================================================
  // Stage 4: Compute final result (combinational from stage 4 regs)
  // =========================================================================
  logic [FP_WIDTH-1:0] final_fp_result_s4_comb;
  logic [XLEN-1:0] final_int_result_s4_comb;
  logic final_is_fp_to_int_s4_comb;
  riscv_pkg::fp_flags_t final_flags_s4_comb;
  logic fp_to_int_invalid_s4_comb;

  always_comb begin
    final_fp_result_s4_comb = '0;
    final_int_result_s4_comb = '0;
    final_is_fp_to_int_s4_comb = 1'b0;
    final_flags_s4_comb = '0;
    fp_to_int_invalid_s4_comb = 1'b0;

    unique case (operation_s4)
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D: begin
        final_is_fp_to_int_s4_comb = 1'b1;

        if (fp_to_int_force_valid_s4) begin
          final_int_result_s4_comb = fp_to_int_force_result_s4;
          final_flags_s4_comb.nv   = fp_to_int_force_invalid_s4;
          final_flags_s4_comb.nx   = fp_to_int_force_inexact_s4;
        end else begin
          if (fp_to_int_sign_s4) begin
            if (fp_to_int_is_unsigned_s4) begin
              if (fp_to_int_shifted_value_s4 != 0 || fp_to_int_do_round_up_s4) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = '0;
              end else begin
                final_int_result_s4_comb = '0;
              end
            end else begin
              if (fp_to_int_rounded_value_s4 > {2'b01, {(XLEN - 1) {1'b0}}}) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = IntMin;
              end else begin
                final_int_result_s4_comb = -fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end
          end else begin
            if (fp_to_int_is_unsigned_s4) begin
              if (fp_to_int_rounded_value_s4[XLEN]) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = UintMax;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end else begin
              if (fp_to_int_rounded_value_s4 > {2'b00, {(XLEN - 1) {1'b1}}}) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = IntMax;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end
          end

          final_flags_s4_comb.nv = fp_to_int_invalid_s4_comb;
          final_flags_s4_comb.nx = fp_to_int_inexact_pre_s4 & ~fp_to_int_invalid_s4_comb;
        end
      end

      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU: begin
        final_fp_result_s4_comb = int_to_fp_result_s4;
        final_flags_s4_comb.nx  = int_to_fp_inexact_s4;
      end

      riscv_pkg::FMV_X_W: begin
        final_int_result_s4_comb   = move_int_result_s4;
        final_is_fp_to_int_s4_comb = 1'b1;
      end

      riscv_pkg::FMV_W_X: begin
        final_fp_result_s4_comb = move_fp_result_s4;
      end

      default: begin
        final_fp_result_s4_comb = '0;
        final_int_result_s4_comb = '0;
        final_is_fp_to_int_s4_comb = 1'b0;
      end
    endcase
  end

  // =========================================================================
  // Stage 4 -> Output Registers
  // =========================================================================
  logic [FP_WIDTH-1:0] fp_result_out;
  logic [XLEN-1:0] int_result_out;
  logic is_fp_to_int_out;
  riscv_pkg::fp_flags_t flags_out;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      fp_operand_reg <= '0;
      int_operand_reg <= '0;
      operation_reg <= riscv_pkg::instr_op_e'(0);
      rm_reg <= 3'b0;
      // Stage 2 registers
      fp_sign_s2 <= 1'b0;
      fp_exp_s2 <= '0;
      fp_mantissa_s2 <= '0;
      fp_is_zero_s2 <= 1'b0;
      fp_is_inf_s2 <= 1'b0;
      fp_is_nan_s2 <= 1'b0;
      unbiased_exp_s2 <= '0;
      abs_int_s2 <= '0;
      int_sign_s2 <= 1'b0;
      int_is_zero_s2 <= 1'b0;
      int_lzc_s2 <= '0;
      operation_s2 <= riscv_pkg::instr_op_e'(0);
      rm_s2 <= 3'b0;
      // Stage 3 registers
      fp_to_int_shifted_value_s3 <= '0;
      fp_to_int_round_bit_s3 <= 1'b0;
      fp_to_int_sticky_bit_s3 <= 1'b0;
      fp_to_int_inexact_pre_s3 <= 1'b0;
      fp_to_int_force_valid_s3 <= 1'b0;
      fp_to_int_force_result_s3 <= '0;
      fp_to_int_force_invalid_s3 <= 1'b0;
      fp_to_int_force_inexact_s3 <= 1'b0;
      fp_to_int_sign_s3 <= 1'b0;
      fp_to_int_is_unsigned_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      operation_s3 <= riscv_pkg::instr_op_e'(0);
      int_to_fp_result_s3 <= '0;
      int_to_fp_inexact_s3 <= 1'b0;
      move_fp_result_s3 <= '0;
      move_int_result_s3 <= '0;
      // Stage 4 registers
      fp_to_int_rounded_value_s4 <= '0;
      fp_to_int_do_round_up_s4 <= 1'b0;
      fp_to_int_shifted_value_s4 <= '0;
      fp_to_int_inexact_pre_s4 <= 1'b0;
      fp_to_int_force_valid_s4 <= 1'b0;
      fp_to_int_force_result_s4 <= '0;
      fp_to_int_force_invalid_s4 <= 1'b0;
      fp_to_int_force_inexact_s4 <= 1'b0;
      fp_to_int_sign_s4 <= 1'b0;
      fp_to_int_is_unsigned_s4 <= 1'b0;
      operation_s4 <= riscv_pkg::instr_op_e'(0);
      int_to_fp_result_s4 <= '0;
      int_to_fp_inexact_s4 <= 1'b0;
      move_fp_result_s4 <= '0;
      move_int_result_s4 <= '0;
      // Output registers
      fp_result_out <= '0;
      int_result_out <= '0;
      is_fp_to_int_out <= 1'b0;
      flags_out <= '0;
    end else begin
      state <= next_state;

      case (state)
        IDLE: begin
          if (i_valid) begin
            fp_operand_reg <= i_fp_operand;
            int_operand_reg <= i_int_operand;
            operation_reg <= i_operation;
            rm_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          // Capture stage 1 results
          fp_sign_s2 <= fp_sign;
          fp_exp_s2 <= fp_exp;
          fp_mantissa_s2 <= fp_mantissa;
          fp_is_zero_s2 <= fp_is_zero;
          fp_is_inf_s2 <= fp_is_inf;
          fp_is_nan_s2 <= fp_is_nan;
          unbiased_exp_s2 <= unbiased_exp;
          abs_int_s2 <= abs_int;
          int_sign_s2 <= int_sign;
          int_is_zero_s2 <= (abs_int == '0);
          int_lzc_s2 <= int_lzc;
          operation_s2 <= operation_reg;
          rm_s2 <= rm_reg;
        end

        STAGE2: begin
          fp_to_int_shifted_value_s3 <= fp_to_int_shifted_value_s2_comb;
          fp_to_int_round_bit_s3 <= fp_to_int_round_bit_s2_comb;
          fp_to_int_sticky_bit_s3 <= fp_to_int_sticky_bit_s2_comb;
          fp_to_int_inexact_pre_s3 <= fp_to_int_inexact_pre_s2_comb;
          fp_to_int_force_valid_s3 <= fp_to_int_force_valid_s2_comb;
          fp_to_int_force_result_s3 <= fp_to_int_force_result_s2_comb;
          fp_to_int_force_invalid_s3 <= fp_to_int_force_invalid_s2_comb;
          fp_to_int_force_inexact_s3 <= fp_to_int_force_inexact_s2_comb;
          fp_to_int_sign_s3 <= fp_sign_s2;
          fp_to_int_is_unsigned_s3 <= is_unsigned_conv;
          rm_s3 <= rm_s2;
          operation_s3 <= operation_s2;
          int_to_fp_result_s3 <= int_to_fp_result;
          int_to_fp_inexact_s3 <= int_to_fp_inexact;
          move_fp_result_s3 <= move_fp_result_s2_comb;
          move_int_result_s3 <= move_int_result_s2_comb;
        end

        STAGE3: begin
          fp_to_int_rounded_value_s4 <= fp_to_int_rounded_value_s3_comb;
          fp_to_int_do_round_up_s4 <= fp_to_int_do_round_up_s3_comb;
          fp_to_int_shifted_value_s4 <= fp_to_int_shifted_value_s3;
          fp_to_int_inexact_pre_s4 <= fp_to_int_inexact_pre_s3;
          fp_to_int_force_valid_s4 <= fp_to_int_force_valid_s3;
          fp_to_int_force_result_s4 <= fp_to_int_force_result_s3;
          fp_to_int_force_invalid_s4 <= fp_to_int_force_invalid_s3;
          fp_to_int_force_inexact_s4 <= fp_to_int_force_inexact_s3;
          fp_to_int_sign_s4 <= fp_to_int_sign_s3;
          fp_to_int_is_unsigned_s4 <= fp_to_int_is_unsigned_s3;
          operation_s4 <= operation_s3;
          int_to_fp_result_s4 <= int_to_fp_result_s3;
          int_to_fp_inexact_s4 <= int_to_fp_inexact_s3;
          move_fp_result_s4 <= move_fp_result_s3;
          move_int_result_s4 <= move_int_result_s3;
        end

        STAGE4: begin
          fp_result_out <= final_fp_result_s4_comb;
          int_result_out <= final_int_result_s4_comb;
          is_fp_to_int_out <= final_is_fp_to_int_s4_comb;
          flags_out <= final_flags_s4_comb;
        end

        default: ;
      endcase
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;
    case (state)
      IDLE: if (i_valid) next_state = STAGE1;
      STAGE1: next_state = STAGE2;
      STAGE2: next_state = STAGE3;
      STAGE3: next_state = STAGE4;
      STAGE4: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Output Logic
  // =========================================================================
  // TIMING: Limit fanout to force register replication and improve timing
  (* max_fanout = 30 *) logic valid_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) valid_reg <= 1'b0;
    else valid_reg <= (state == STAGE4);
  end
  assign o_valid = valid_reg;

  // Output from registered stage 4
  assign o_fp_result = fp_result_out;
  assign o_int_result = int_result_out;
  assign o_is_fp_to_int = is_fp_to_int_out;
  assign o_flags = flags_out;

endmodule : fp_convert
