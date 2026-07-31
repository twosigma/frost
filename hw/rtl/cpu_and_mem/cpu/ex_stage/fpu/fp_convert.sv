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
    FCVT.W.S / FCVT.WU.S:  rd = (u)int32(fs1)   - FP to 32-bit integer
    FCVT.S.W / FCVT.S.WU:  fd = float(rs1)      - 32-bit integer to FP
    FMV.X.W / FMV.W.X:     raw 32-bit bit moves (no conversion)
    RV64 (XLEN=64) adds, in the matching S/D-width instance:
    FCVT.L.* / FCVT.LU.*:  rd = (u)int64(fs1)   - FP to 64-bit integer
    FCVT.*.L / FCVT.*.LU:  fd = float(rs1)      - 64-bit integer to FP
    FMV.X.D / FMV.D.X:     raw 64-bit bit moves

  The op encodes the integer width: on RV64 the W-forms keep 32-bit
  saturation bounds and sign-extend their integer results from bit 31
  (FMV.X.W included, unsigned forms included), while their integer
  operands convert the low word's value via operand pre-extension.
  L-forms use the full XLEN-wide bounds and datapath.

  Multi-cycle implementation (5-cycle latency):
    Cycle 0: Capture operands, unpack, compute LZC / shift amounts
    Cycle 1: FP->int shift/round prep, int->fp normalize
    Cycle 2: FP->int round add
    Cycle 3: Final pack/flags
    Cycle 4: Output registered result

  Rounding:
    - Integer to FP may require rounding (mantissa narrower than the integer)
    - FP to integer uses specified rounding mode

  Exception handling:
    - Invalid (NV): FP to int conversion of NaN, infinity, or out of range
    - Inexact (NX): Result is not exact
*/
module fp_convert #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
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
  // 32-bit saturation bounds for the W-forms at XLEN=64 (IntMinW doubles as
  // the magnitude of the most negative word). Stage 4 sign-extends every
  // W-form result from bit 31, so these stay in unextended low-word form.
  localparam logic [XLEN-1:0] IntMaxW = XLEN'(64'h0000_0000_7FFF_FFFF);
  localparam logic [XLEN-1:0] IntMinW = XLEN'(64'h0000_0000_8000_0000);
  localparam logic [XLEN-1:0] UintMaxW = XLEN'(64'h0000_0000_FFFF_FFFF);
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

  fp_operand_unpacker #(
      .FP_WIDTH(FP_WIDTH)
  ) u_unpack (
      .i_operand(fp_operand_reg),
      .o_sign(fp_sign),
      .o_exp(fp_exp),
      .o_exp_adj(),
      .o_frac(fp_mant),
      .o_mant(fp_mantissa),
      .o_is_zero(fp_is_zero),
      .o_is_subnormal(fp_is_subnormal),
      .o_is_inf(fp_is_inf),
      .o_is_nan(fp_is_nan),
      .o_is_snan()
  );

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
                          (operation_reg == riscv_pkg::FCVT_D_W) ||
                          (operation_reg == riscv_pkg::FCVT_S_L) ||
                          (operation_reg == riscv_pkg::FCVT_D_L);

  // At XLEN=64 the W-form int->fp ops convert the low word's value:
  // pre-extend it (sign for .W, zero for .WU) and run the XLEN-wide
  // datapath, which is numerically identical. At XLEN=32 the flag is
  // constant 0 and the operand passes through untouched.
  logic            int_to_fp_word;
  logic [XLEN-1:0] shaped_int_operand;
  assign int_to_fp_word = (XLEN == 64) &&
      ((operation_reg == riscv_pkg::FCVT_S_W) || (operation_reg == riscv_pkg::FCVT_S_WU) ||
       (operation_reg == riscv_pkg::FCVT_D_W) || (operation_reg == riscv_pkg::FCVT_D_WU));
  assign shaped_int_operand = int_to_fp_word ? XLEN'($signed(
      {is_signed_conv & int_operand_reg[31], int_operand_reg[31:0]}
  )) : int_operand_reg;

  always_comb begin
    if (is_signed_conv && shaped_int_operand[XLEN-1]) begin
      abs_int  = -shaped_int_operand;
      int_sign = 1'b1;
    end else begin
      abs_int  = shaped_int_operand;
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
  logic        [  ShiftBits-1:0] fp_to_int_shift_amt;
  logic        [ExtMantBits-1:0] fp_to_int_shifted_ext;

  // Effective fp->int bounds: W-forms at XLEN=64 saturate at the 32-bit
  // limits; everything else (all ops at XLEN=32, L-forms at 64) keeps the
  // XLEN-wide constants, so the rv32 build is bit-identical.
  logic                          fp_to_int_word_s2;
  logic signed [ ExpExtBits-1:0] max_exp_signed_eff;
  logic signed [ ExpExtBits-1:0] max_exp_unsigned_eff;
  logic        [       XLEN-1:0] int_max_eff;
  logic        [       XLEN-1:0] int_min_eff;
  logic        [       XLEN-1:0] uint_max_eff;

  assign fp_to_int_word_s2 = (XLEN == 64) &&
      ((operation_s2 == riscv_pkg::FCVT_W_S) || (operation_s2 == riscv_pkg::FCVT_WU_S) ||
       (operation_s2 == riscv_pkg::FCVT_W_D) || (operation_s2 == riscv_pkg::FCVT_WU_D));
  assign max_exp_signed_eff = fp_to_int_word_s2 ? ExpExtBits'(30) : MaxExpSignedExt;
  assign max_exp_unsigned_eff = fp_to_int_word_s2 ? ExpExtBits'(31) : MaxExpUnsignedExt;
  assign int_max_eff = fp_to_int_word_s2 ? IntMaxW : IntMax;
  assign int_min_eff = fp_to_int_word_s2 ? IntMinW : IntMin;
  assign uint_max_eff = fp_to_int_word_s2 ? UintMaxW : UintMax;

  always_comb begin
    is_unsigned_conv = (operation_s2 == riscv_pkg::FCVT_WU_S) ||
                       (operation_s2 == riscv_pkg::FCVT_WU_D) ||
                       (operation_s2 == riscv_pkg::FCVT_LU_S) ||
                       (operation_s2 == riscv_pkg::FCVT_LU_D);
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
      fp_to_int_force_result_s2_comb  = is_unsigned_conv ? uint_max_eff : int_max_eff;
    end else if (fp_is_inf_s2) begin
      fp_to_int_force_valid_s2_comb   = 1'b1;
      fp_to_int_force_invalid_s2_comb = 1'b1;
      if (fp_sign_s2) begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? '0 : int_min_eff;
      end else begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? uint_max_eff : int_max_eff;
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
      end else if (unbiased_exp_s2 > max_exp_signed_eff) begin
        if (!is_unsigned_conv && fp_sign_s2 &&
            (unbiased_exp_s2 == max_exp_unsigned_eff) &&
            (fp_mantissa_s2 == {1'b1, {FracBits{1'b0}}})) begin
          // The most negative integer of the effective width is the one
          // signed value with the unsigned-range exponent that is still in
          // range. Pass its magnitude so stage 4's signed path produces it
          // without NV.
          shifted_value = int_min_eff;
          round_bit = 1'b0;
          sticky_bit = 1'b0;
        end else if (is_unsigned_conv && !fp_sign_s2 &&
                     (unbiased_exp_s2 <= max_exp_unsigned_eff)) begin
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
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? '0 : int_min_eff;
          end else begin
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? uint_max_eff : int_max_eff;
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

  // FMV.X.* move to the integer register. When XLEN exceeds FP_WIDTH (the S
  // instance at XLEN=64) the RV64 FMV.X.W semantic sign-extends the 32-bit
  // pattern into rd. At XLEN <= FP_WIDTH the operand covers rd directly
  // (FMV.X.W at XLEN=32; FMV.X.D in the D instance at XLEN=64 — the low
  // slice in the D instance at XLEN=32 only keeps elaboration legal, since
  // FMV.X.D never decodes there).
  localparam int unsigned MoveIntWidth = (FP_WIDTH < XLEN) ? FP_WIDTH : XLEN;
  generate
    if (XLEN > FP_WIDTH) begin : gen_move_int_sext
      assign move_int_result_s2_comb = {
        {(XLEN - FP_WIDTH) {fp_operand_reg[FP_WIDTH-1]}}, fp_operand_reg
      };
    end else begin : gen_move_int_full
      assign move_int_result_s2_comb = XLEN'(fp_operand_reg[MoveIntWidth-1:0]);
    end
  endgenerate

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

  // Stage-4 mirrors of the effective-width selection (derived from
  // operation_s4 so no stage leans on another stage's classification).
  // The limits apply to the (XLEN+1)-bit rounded magnitude: largest
  // positive signed value, magnitude of the most negative signed value,
  // and largest unsigned value of the effective integer width.
  logic fp_to_int_word_s4;
  logic [XLEN:0] signed_pos_limit_s4;
  logic [XLEN:0] signed_neg_limit_s4;
  logic [XLEN:0] unsigned_limit_s4;
  logic [XLEN-1:0] int_max_eff_s4;
  logic [XLEN-1:0] int_min_eff_s4;
  logic [XLEN-1:0] uint_max_eff_s4;

  assign fp_to_int_word_s4 = (XLEN == 64) &&
      ((operation_s4 == riscv_pkg::FCVT_W_S) || (operation_s4 == riscv_pkg::FCVT_WU_S) ||
       (operation_s4 == riscv_pkg::FCVT_W_D) || (operation_s4 == riscv_pkg::FCVT_WU_D));
  assign signed_pos_limit_s4 =
      fp_to_int_word_s4 ? (XLEN + 1)'(64'h0000_0000_7FFF_FFFF) : {2'b00, {(XLEN - 1) {1'b1}}};
  assign signed_neg_limit_s4 =
      fp_to_int_word_s4 ? (XLEN + 1)'(64'h0000_0000_8000_0000) : {2'b01, {(XLEN - 1) {1'b0}}};
  assign unsigned_limit_s4 =
      fp_to_int_word_s4 ? (XLEN + 1)'(64'h0000_0000_FFFF_FFFF) : {1'b0, {XLEN{1'b1}}};
  assign int_max_eff_s4 = fp_to_int_word_s4 ? IntMaxW : IntMax;
  assign int_min_eff_s4 = fp_to_int_word_s4 ? IntMinW : IntMin;
  assign uint_max_eff_s4 = fp_to_int_word_s4 ? UintMaxW : UintMax;

  always_comb begin
    final_fp_result_s4_comb = '0;
    final_int_result_s4_comb = '0;
    final_is_fp_to_int_s4_comb = 1'b0;
    final_flags_s4_comb = '0;
    fp_to_int_invalid_s4_comb = 1'b0;

    unique case (operation_s4)
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S, riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D: begin
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
              if (fp_to_int_rounded_value_s4 > signed_neg_limit_s4) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = int_min_eff_s4;
              end else begin
                final_int_result_s4_comb = -fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end
          end else begin
            if (fp_to_int_is_unsigned_s4) begin
              if (fp_to_int_rounded_value_s4 > unsigned_limit_s4) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = uint_max_eff_s4;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end else begin
              if (fp_to_int_rounded_value_s4 > signed_pos_limit_s4) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = int_max_eff_s4;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[XLEN-1:0];
              end
            end
          end

          final_flags_s4_comb.nv = fp_to_int_invalid_s4_comb;
          final_flags_s4_comb.nx = fp_to_int_inexact_pre_s4 & ~fp_to_int_invalid_s4_comb;
        end

        if (fp_to_int_word_s4) begin
          // RV64 W-forms: rd receives the 32-bit result (saturation values
          // included, unsigned included) sign-extended from bit 31.
          final_int_result_s4_comb = XLEN'($signed(final_int_result_s4_comb[31:0]));
        end
      end

      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_S_L, riscv_pkg::FCVT_S_LU, riscv_pkg::FCVT_D_L, riscv_pkg::FCVT_D_LU: begin
        final_fp_result_s4_comb = int_to_fp_result_s4;
        final_flags_s4_comb.nx  = int_to_fp_inexact_s4;
      end

      riscv_pkg::FMV_X_W, riscv_pkg::FMV_X_D: begin
        final_int_result_s4_comb   = move_int_result_s4;
        final_is_fp_to_int_s4_comb = 1'b1;
      end

      riscv_pkg::FMV_W_X, riscv_pkg::FMV_D_X: begin
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
  // State Machine Control
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) state <= IDLE;
    else state <= next_state;
  end

  // =========================================================================
  // Data Pipeline Registers
  // =========================================================================
  always_ff @(posedge i_clk) begin
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
