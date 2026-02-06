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
  Floating-Point Unit (FPU) Top-Level Module

  This module implements the complete RISC-V F extension (single-precision
  floating-point) by routing operations to specialized sub-units.

  Submodule Hierarchy:
  ====================
    fpu
    ├── fp_adder.sv          Multi-cycle add/subtract (4-cycle, FADD.S, FSUB.S)
    ├── fp_multiplier.sv     Multi-cycle multiply (8-cycle, FMUL.S)
    ├── fp_divider.sv        Sequential divide (~15 cycles, FDIV.S)
    ├── fp_sqrt.sv           Sequential square root (~15 cycles, FSQRT.S)
    ├── fp_fma.sv            Multi-cycle FMA (12-cycle, FMADD/FMSUB/FNMADD/FNMSUB)
    ├── fp_compare.sv        Comparisons and min/max (3-cycle)
    ├── fp_convert.sv        Integer/FP conversions (3-cycle)
    ├── fp_classify.sv       FCLASS.S (1-cycle)
    └── fp_sign_inject.sv    Sign injection (1-cycle, FSGNJ variants)

  Operation Latencies:
  ====================
    2-cycle:  FSGNJ*, FCLASS, FEQ/FLT/FLE, FMIN/FMAX (multi-cycle, stalls pipeline)
    5-cycle:  FCVT.S.D / FCVT.D.S (multi-cycle, stalls pipeline)
    5-cycle:  FCVT, FMV (multi-cycle, stalls pipeline)
    10-cycle: FADD, FSUB (multi-cycle, stalls pipeline)
    9-cycle:  FMUL (multi-cycle, stalls pipeline)
    14-cycle: FMADD, FMSUB, FNMADD, FNMSUB (multi-cycle, stalls pipeline)
    ~32-cycle: FDIV, FSQRT (sequential, stalls pipeline)

  Design Note:
  ============
    Multi-cycle operations (adder, multiplier, FMA, convert) use internal state
    machines and capture operands at the start of each operation. This non-pipelined
    design simplifies timing by ensuring operand stability without complex
    capture bypass mechanisms. The pipeline stalls until each operation completes.

  Interface:
  ==========
    - Accepts operation type from instruction decoder
    - Resolves dynamic rounding mode (FRM_DYN -> frm CSR value)
    - Routes operands to appropriate sub-unit
    - Multiplexes results back to pipeline
    - Aggregates exception flags for CSR update
*/
module fpu #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Operation valid and type
    input logic                 i_valid,
    input riscv_pkg::instr_op_e i_operation,

    // Operands (FP source registers, or integer for FMV.W.X / FCVT.S.W)
    input logic [riscv_pkg::FpWidth-1:0] i_operand_a,  // rs1 / fs1
    input logic [riscv_pkg::FpWidth-1:0] i_operand_b,  // rs2 / fs2
    input logic [riscv_pkg::FpWidth-1:0] i_operand_c,  // fs3 (for FMA only)
    input logic [XLEN-1:0] i_int_operand,  // Integer operand for FMV.W.X, FCVT.S.W

    // Destination register - tracked through pipeline for pipelined operations
    input logic [4:0] i_dest_reg,

    // Rounding mode
    input logic [2:0] i_rm_instr,  // Rounding mode from instruction
    input logic [2:0] i_rm_csr,    // Rounding mode from frm CSR

    // Pipeline control
    input logic i_stall,            // External stall (excludes FPU busy)
    input logic i_stall_registered, // Stall in previous cycle

    // Results
    // FP result (or integer for FMV.X.W, FCVT.W.S, etc.)
    output logic [riscv_pkg::FpWidth-1:0] o_result,
    output logic o_valid,  // Result is valid this cycle
    output logic o_result_to_int,  // Result goes to integer register (not FP)
    output logic [4:0] o_dest_reg,  // Destination register for this result

    // Stall signal for multi-cycle operations
    output logic o_stall,  // FPU needs more cycles

    // Exception flags
    output riscv_pkg::fp_flags_t o_flags,

    // In-flight destination registers for RAW hazard detection
    // These are destinations of pipelined ops that haven't completed yet
    output logic [4:0] o_inflight_dest_1,  // Adder/mult stage 0
    output logic [4:0] o_inflight_dest_2,  // Adder/mult stage 1
    output logic [4:0] o_inflight_dest_3,  // FMA stage 0
    output logic [4:0] o_inflight_dest_4,  // FMA stage 1
    output logic [4:0] o_inflight_dest_5,  // FMA stage 2
    output logic [4:0] o_inflight_dest_6   // Sequential (div/sqrt)
);

  localparam int unsigned FpWidth = riscv_pkg::FpWidth;
  localparam int unsigned FpPad = (FpWidth > 32) ? (FpWidth - 32) : 0;
  localparam int unsigned FpIntPad = (FpWidth > XLEN) ? (FpWidth - XLEN) : 0;

  function automatic [FpWidth-1:0] box32(input logic [31:0] value);
    box32 = {{FpPad{1'b1}}, value};
  endfunction

  function automatic [FpWidth-1:0] zext_xlen(input logic [XLEN-1:0] value);
    zext_xlen = {{FpIntPad{1'b0}}, value};
  endfunction

  // ===========================================================================
  // Input Pipeline Registers (TIMING)
  // ===========================================================================
  // Register all FPU inputs to break timing paths from memory/forwarding.
  // This adds 1 cycle of latency to all FP operations but significantly
  // eases timing closure by isolating the FPU from the critical forwarding paths.
  // Since all FP operations are already multi-cycle, this extra cycle has
  // minimal performance impact.

  logic                 valid_r;
  riscv_pkg::instr_op_e operation_r;
  logic [FpWidth-1:0] operand_a_r, operand_b_r, operand_c_r;
  logic [XLEN-1:0] int_operand_r;
  logic [     4:0] dest_reg_r;
  logic [     2:0] rm_instr_r;

  // Track when input capture is in progress (for stall generation)
  logic            input_capture_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_r <= 1'b0;
      input_capture_pending <= 1'b0;
      operation_r <= riscv_pkg::instr_op_e'(0);
      operand_a_r <= '0;
      operand_b_r <= '0;
      operand_c_r <= '0;
      int_operand_r <= '0;
      dest_reg_r <= '0;
      rm_instr_r <= '0;
    end else begin
      // Capture inputs when i_valid arrives and no operation is pending
      // Must also check !fpu_active to prevent re-capture during multi-cycle ops
      if (i_valid && !input_capture_pending && !valid_r && !fpu_active) begin
        operation_r <= i_operation;
        operand_a_r <= i_operand_a;
        operand_b_r <= i_operand_b;
        operand_c_r <= i_operand_c;
        int_operand_r <= i_int_operand;
        dest_reg_r <= i_dest_reg;
        rm_instr_r <= i_rm_instr;
        input_capture_pending <= 1'b1;
      end
      // One cycle after capture, assert valid_r to start the operation
      if (input_capture_pending) begin
        valid_r <= 1'b1;
        input_capture_pending <= 1'b0;
      end else begin
        valid_r <= 1'b0;
      end
    end
  end

  // ===========================================================================
  // Multi-Cycle Operation Stall Logic
  // ===========================================================================
  // Multi-cycle operations (adder, multiplier, FMA) use internal state machines
  // and signal when they are busy. The CPU pipeline stalls until the result
  // is available. Since operands are captured at the start of each operation,
  // no complex capture bypass logic is needed.

  logic       adder_busy;  // True when adder is computing
  logic       multiplier_busy;  // True when multiplier is computing
  logic       fma_busy;  // True when FMA is computing
  logic       compare_busy;  // True when compare is computing
  logic       convert_busy;  // True when converter is computing

  // ===========================================================================
  // Effective Rounding Mode Resolution
  // ===========================================================================
  // If instruction specifies FRM_DYN (dynamic), use the CSR value.
  // Uses registered rounding mode for timing.

  logic [2:0] effective_rm;
  assign effective_rm = (rm_instr_r == riscv_pkg::FRM_DYN) ? i_rm_csr : rm_instr_r;

  // ===========================================================================
  // Operand Unboxing (NaN-boxed single-precision in 64-bit FP regs)
  // ===========================================================================
  // Uses registered operands for timing.
  logic [31:0] operand_a_s, operand_b_s, operand_c_s;
  logic [FpWidth-1:0] operand_a_d, operand_b_d, operand_c_d;

  assign operand_a_d = operand_a_r;
  assign operand_b_d = operand_b_r;
  assign operand_c_d = operand_c_r;

  generate
    if (FpWidth == 32) begin : gen_unbox_s
      assign operand_a_s = operand_a_r[31:0];
      assign operand_b_s = operand_b_r[31:0];
      assign operand_c_s = operand_c_r[31:0];
    end else begin : gen_unbox_s_nanbox
      assign operand_a_s = (&operand_a_r[FpWidth-1:32]) ?
                           operand_a_r[31:0] : riscv_pkg::FpCanonicalNan;
      assign operand_b_s = (&operand_b_r[FpWidth-1:32]) ?
                           operand_b_r[31:0] : riscv_pkg::FpCanonicalNan;
      assign operand_c_s = (&operand_c_r[FpWidth-1:32]) ?
                           operand_c_r[31:0] : riscv_pkg::FpCanonicalNan;
    end
  endgenerate

  // ===========================================================================
  // Operation Decode
  // ===========================================================================
  // Determine which sub-unit handles the operation and prepare control signals.

  logic is_fp_op_for_stall;
  logic op_add, op_sub, op_mul, op_div, op_sqrt;
  logic op_fmadd, op_fmsub, op_fnmadd, op_fnmsub;
  logic op_min, op_max, op_eq, op_lt, op_le;
  logic op_sgnj, op_sgnjn, op_sgnjx;
  logic op_cvt_w_s, op_cvt_wu_s, op_cvt_s_w, op_cvt_s_wu;
  logic op_cvt_w_d, op_cvt_wu_d, op_cvt_d_w, op_cvt_d_wu;
  logic op_cvt_s_d, op_cvt_d_s;
  logic op_mv_x_w, op_mv_w_x;
  logic op_fclass;
  logic op_is_double;

  // Use i_valid (set only for FP compute ops) to gate stall without
  // pulling full decode into the stall path.
  assign is_fp_op_for_stall = i_valid;

  always_comb begin
    // Default all to 0
    op_add      = 1'b0;
    op_sub      = 1'b0;
    op_mul      = 1'b0;
    op_div      = 1'b0;
    op_sqrt     = 1'b0;
    op_fmadd    = 1'b0;
    op_fmsub    = 1'b0;
    op_fnmadd   = 1'b0;
    op_fnmsub   = 1'b0;
    op_min      = 1'b0;
    op_max      = 1'b0;
    op_eq       = 1'b0;
    op_lt       = 1'b0;
    op_le       = 1'b0;
    op_sgnj     = 1'b0;
    op_sgnjn    = 1'b0;
    op_sgnjx    = 1'b0;
    op_cvt_w_s  = 1'b0;
    op_cvt_wu_s = 1'b0;
    op_cvt_s_w  = 1'b0;
    op_cvt_s_wu = 1'b0;
    op_cvt_w_d  = 1'b0;
    op_cvt_wu_d = 1'b0;
    op_cvt_d_w  = 1'b0;
    op_cvt_d_wu = 1'b0;
    op_cvt_s_d  = 1'b0;
    op_cvt_d_s  = 1'b0;
    op_mv_x_w   = 1'b0;
    op_mv_w_x   = 1'b0;
    op_fclass   = 1'b0;

    case (operation_r)
      riscv_pkg::FADD_S, riscv_pkg::FADD_D:     op_add = 1'b1;
      riscv_pkg::FSUB_S, riscv_pkg::FSUB_D:     op_sub = 1'b1;
      riscv_pkg::FMUL_S, riscv_pkg::FMUL_D:     op_mul = 1'b1;
      riscv_pkg::FDIV_S, riscv_pkg::FDIV_D:     op_div = 1'b1;
      riscv_pkg::FSQRT_S, riscv_pkg::FSQRT_D:   op_sqrt = 1'b1;
      riscv_pkg::FMADD_S, riscv_pkg::FMADD_D:   op_fmadd = 1'b1;
      riscv_pkg::FMSUB_S, riscv_pkg::FMSUB_D:   op_fmsub = 1'b1;
      riscv_pkg::FNMADD_S, riscv_pkg::FNMADD_D: op_fnmadd = 1'b1;
      riscv_pkg::FNMSUB_S, riscv_pkg::FNMSUB_D: op_fnmsub = 1'b1;
      riscv_pkg::FMIN_S, riscv_pkg::FMIN_D:     op_min = 1'b1;
      riscv_pkg::FMAX_S, riscv_pkg::FMAX_D:     op_max = 1'b1;
      riscv_pkg::FEQ_S, riscv_pkg::FEQ_D:       op_eq = 1'b1;
      riscv_pkg::FLT_S, riscv_pkg::FLT_D:       op_lt = 1'b1;
      riscv_pkg::FLE_S, riscv_pkg::FLE_D:       op_le = 1'b1;
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJ_D:   op_sgnj = 1'b1;
      riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJN_D: op_sgnjn = 1'b1;
      riscv_pkg::FSGNJX_S, riscv_pkg::FSGNJX_D: op_sgnjx = 1'b1;
      riscv_pkg::FCVT_W_S:                      op_cvt_w_s = 1'b1;
      riscv_pkg::FCVT_WU_S:                     op_cvt_wu_s = 1'b1;
      riscv_pkg::FCVT_S_W:                      op_cvt_s_w = 1'b1;
      riscv_pkg::FCVT_S_WU:                     op_cvt_s_wu = 1'b1;
      riscv_pkg::FCVT_W_D:                      op_cvt_w_d = 1'b1;
      riscv_pkg::FCVT_WU_D:                     op_cvt_wu_d = 1'b1;
      riscv_pkg::FCVT_D_W:                      op_cvt_d_w = 1'b1;
      riscv_pkg::FCVT_D_WU:                     op_cvt_d_wu = 1'b1;
      riscv_pkg::FCVT_S_D:                      op_cvt_s_d = 1'b1;
      riscv_pkg::FCVT_D_S:                      op_cvt_d_s = 1'b1;
      riscv_pkg::FMV_X_W:                       op_mv_x_w = 1'b1;
      riscv_pkg::FMV_W_X:                       op_mv_w_x = 1'b1;
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D: op_fclass = 1'b1;
      default:                                  ;
    endcase
  end

  // Identify double-precision operations for unit selection
  always_comb begin
    op_is_double = 1'b0;
    case (operation_r)
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D, riscv_pkg::FMUL_D,
      riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCLASS_D:
      op_is_double = 1'b1;
      default: op_is_double = 1'b0;
    endcase
  end

  // Group operations by sub-unit
  logic use_adder, use_multiplier, use_divider, use_sqrt, use_fma;
  logic use_compare, use_convert, use_convert_s, use_convert_d, use_convert_sd;
  logic use_classify, use_sign_inject;

  assign use_adder = op_add | op_sub;
  assign use_multiplier = op_mul;
  assign use_divider = op_div;
  assign use_sqrt = op_sqrt;
  assign use_fma = op_fmadd | op_fmsub | op_fnmadd | op_fnmsub;
  assign use_compare = op_min | op_max | op_eq | op_lt | op_le;
  assign use_convert_s = op_cvt_w_s | op_cvt_wu_s | op_cvt_s_w | op_cvt_s_wu |
                         op_mv_x_w | op_mv_w_x;
  assign use_convert_d = op_cvt_w_d | op_cvt_wu_d | op_cvt_d_w | op_cvt_d_wu;
  assign use_convert_sd = op_cvt_s_d | op_cvt_d_s;
  assign use_convert = use_convert_s | use_convert_d | use_convert_sd;
  assign use_classify = op_fclass;
  assign use_sign_inject = op_sgnj | op_sgnjn | op_sgnjx;

  // ===========================================================================
  // Sub-Unit Wrapper Instantiations
  // ===========================================================================

  // --- Wrapper output signals ---
  logic                 [FpWidth-1:0] adder_result;
  logic                               adder_valid;
  riscv_pkg::fp_flags_t               adder_flags;
  logic                               adder_start;
  logic                 [        4:0] dest_reg_adder;

  logic                 [FpWidth-1:0] multiplier_result;
  logic                               multiplier_valid;
  riscv_pkg::fp_flags_t               multiplier_flags;
  logic                               multiplier_start;
  logic                 [        4:0] dest_reg_multiplier;

  logic                 [FpWidth-1:0] fma_result;
  logic                               fma_valid;
  riscv_pkg::fp_flags_t               fma_flags;
  logic                               fma_start;
  logic                 [        4:0] dest_reg_fma;

  logic                 [FpWidth-1:0] compare_result;
  logic                               compare_is_compare;
  logic                               compare_valid;
  riscv_pkg::fp_flags_t               compare_flags;
  logic                               compare_start;
  logic                 [        4:0] dest_reg_compare;

  logic                 [FpWidth-1:0] sign_inject_result;
  logic                               sign_inject_valid;
  logic                               sign_inject_start;
  logic                 [        4:0] dest_reg_sign_inject;

  logic                 [       31:0] classify_result;
  logic                               classify_valid;
  logic                               classify_start;
  logic                 [        4:0] dest_reg_classify;

  logic                 [FpWidth-1:0] divider_result;
  logic                               divider_valid;
  riscv_pkg::fp_flags_t               divider_flags;
  logic                 [FpWidth-1:0] sqrt_result;
  logic                               sqrt_valid;
  riscv_pkg::fp_flags_t               sqrt_flags;
  logic                               seq_start;
  logic                 [        4:0] dest_reg_seq;
  logic                               dest_reg_seq_valid;

  logic                 [FpWidth-1:0] convert_fp_result;
  logic                 [   XLEN-1:0] convert_int_result;
  logic                               convert_is_fp_to_int;
  logic                               convert_valid;
  riscv_pkg::fp_flags_t               convert_flags;
  logic                               convert_start;
  logic                 [        4:0] dest_reg_convert;

  // --- FMA control signals ---
  logic fma_negate_product, fma_negate_c;
  assign fma_negate_product = op_fnmadd | op_fnmsub;
  assign fma_negate_c       = op_fmsub | op_fnmadd;

  // --- Adder (FADD, FSUB) ---
  fpu_adder_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_adder (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_adder),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_is_subtract(op_sub),
      .i_rounding_mode(effective_rm),
      .i_dest_reg(dest_reg_r),
      .o_result(adder_result),
      .o_valid(adder_valid),
      .o_flags(adder_flags),
      .o_busy(adder_busy),
      .o_dest_reg(dest_reg_adder),
      .o_start(adder_start)
  );

  // --- Multiplier (FMUL) ---
  fpu_mult_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_multiplier (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_multiplier),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_rounding_mode(effective_rm),
      .i_dest_reg(dest_reg_r),
      .o_result(multiplier_result),
      .o_valid(multiplier_valid),
      .o_flags(multiplier_flags),
      .o_busy(multiplier_busy),
      .o_dest_reg(dest_reg_multiplier),
      .o_start(multiplier_start)
  );

  // --- FMA (FMADD, FMSUB, FNMADD, FNMSUB) ---
  fpu_fma_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_fma (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_fma),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_c_s(operand_c_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_operand_c_d(operand_c_d),
      .i_negate_product(fma_negate_product),
      .i_negate_c(fma_negate_c),
      .i_rounding_mode(effective_rm),
      .i_dest_reg(dest_reg_r),
      .o_result(fma_result),
      .o_valid(fma_valid),
      .o_flags(fma_flags),
      .o_busy(fma_busy),
      .o_dest_reg(dest_reg_fma),
      .o_start(fma_start)
  );

  // --- Compare (FEQ, FLT, FLE, FMIN, FMAX) ---
  fpu_compare_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_compare (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_compare),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_operation(operation_r),
      .i_dest_reg(dest_reg_r),
      .o_result(compare_result),
      .o_is_compare(compare_is_compare),
      .o_valid(compare_valid),
      .o_flags(compare_flags),
      .o_busy(compare_busy),
      .o_dest_reg(dest_reg_compare),
      .o_start(compare_start)
  );

  // --- Sign Injection (FSGNJ, FSGNJN, FSGNJX) ---
  fpu_sign_inject_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_sign_inject (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_sign_inject),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_operation(operation_r),
      .i_dest_reg(dest_reg_r),
      .o_result(sign_inject_result),
      .o_valid(sign_inject_valid),
      .o_flags(  /*unused*/),
      .o_busy(  /*unused*/),
      .o_dest_reg(dest_reg_sign_inject),
      .o_start(sign_inject_start)
  );

  // --- Classify (FCLASS) ---
  fpu_classify_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_classify (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_unit(use_classify),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_a_d(operand_a_d),
      .i_dest_reg(dest_reg_r),
      .o_result(classify_result),
      .o_valid(classify_valid),
      .o_busy(  /*unused*/),
      .o_dest_reg(dest_reg_classify),
      .o_start(classify_start)
  );

  // --- Divider/Sqrt (FDIV, FSQRT) ---
  fpu_div_sqrt_unit #(
      .FP_WIDTH_D(FpWidth)
  ) u_div_sqrt (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_divider(use_divider),
      .i_use_sqrt(use_sqrt),
      .i_op_is_double(op_is_double),
      .i_operand_a_s(operand_a_s),
      .i_operand_b_s(operand_b_s),
      .i_operand_a_d(operand_a_d),
      .i_operand_b_d(operand_b_d),
      .i_rounding_mode(effective_rm),
      .i_dest_reg(dest_reg_r),
      .o_divider_result(divider_result),
      .o_divider_valid(divider_valid),
      .o_divider_flags(divider_flags),
      .o_sqrt_result(sqrt_result),
      .o_sqrt_valid(sqrt_valid),
      .o_sqrt_flags(sqrt_flags),
      .o_busy(  /*unused*/),
      .o_dest_reg(dest_reg_seq),
      .o_dest_reg_valid(dest_reg_seq_valid),
      .o_start(seq_start)
  );

  // --- Convert (FCVT, FMV) ---
  fpu_convert_unit #(
      .XLEN(XLEN),
      .FP_WIDTH_D(FpWidth)
  ) u_convert (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(valid_r),
      .i_use_convert_s(use_convert_s),
      .i_use_convert_d(use_convert_d),
      .i_use_convert_sd(use_convert_sd),
      .i_operand_a_s(operand_a_s),
      .i_operand_a_d(operand_a_d),
      .i_int_operand(int_operand_r),
      .i_operation(operation_r),
      .i_rounding_mode(effective_rm),
      .i_dest_reg(dest_reg_r),
      .o_fp_result(convert_fp_result),
      .o_int_result(convert_int_result),
      .o_is_fp_to_int(convert_is_fp_to_int),
      .o_valid(convert_valid),
      .o_flags(convert_flags),
      .o_busy(convert_busy),
      .o_dest_reg(dest_reg_convert),
      .o_start(convert_start)
  );

  // ===========================================================================
  // Result Multiplexing
  // ===========================================================================
  // Select result based on operation type and track which operations produce
  // results for integer registers vs FP registers.

  // Operations that produce integer results (go to integer regfile)
  logic result_is_integer;
  assign result_is_integer = op_cvt_w_s | op_cvt_wu_s | op_cvt_w_d | op_cvt_wu_d |
                             op_mv_x_w | op_eq | op_lt | op_le | op_fclass;

  // Select the appropriate dest_reg based on which operation is producing results
  logic [4:0] selected_dest_reg;
  always_comb begin
    if (adder_valid) selected_dest_reg = dest_reg_adder;
    else if (multiplier_valid) selected_dest_reg = dest_reg_multiplier;
    else if (fma_valid) selected_dest_reg = dest_reg_fma;
    else if (compare_valid) selected_dest_reg = dest_reg_compare;
    else if (convert_valid) selected_dest_reg = dest_reg_convert;
    else if (classify_valid) selected_dest_reg = dest_reg_classify;
    else if (sign_inject_valid) selected_dest_reg = dest_reg_sign_inject;
    else if (divider_valid || sqrt_valid) selected_dest_reg = dest_reg_seq;
    else selected_dest_reg = 5'b0;
  end

  // ===========================================================================
  // Multi-Cycle Result Valid Signal
  // ===========================================================================
  // Results from all multi-cycle ops are valid for exactly one cycle when
  // the state machine completes. No holding needed since the unit stays
  // in output state for one cycle.

  logic multicycle_result_valid;
  assign multicycle_result_valid = adder_valid | multiplier_valid | fma_valid | compare_valid
                                 | convert_valid | classify_valid | sign_inject_valid;

  // Output dest_reg (combinational, captured into output register)
  logic [4:0] dest_reg_comb;
  assign dest_reg_comb = multicycle_result_valid ? selected_dest_reg :
                         (divider_valid || sqrt_valid) ? dest_reg_seq : 5'b0;

  // Result valid from any source (combinational)
  logic any_valid_comb;
  assign any_valid_comb = multicycle_result_valid | divider_valid | sqrt_valid;

  // Result selection
  // Multi-cycle operations output their result when their state machine
  // completes (valid signal goes high).
  logic [FpWidth-1:0] result_comb;
  riscv_pkg::fp_flags_t flags_comb;
  logic result_to_int_comb;
  always_comb begin
    result_comb = '0;
    flags_comb = '0;
    result_to_int_comb = 1'b0;

    if (adder_valid) begin
      result_comb = adder_result;
      flags_comb  = adder_flags;
    end else if (multiplier_valid) begin
      result_comb = multiplier_result;
      flags_comb  = multiplier_flags;
    end else if (fma_valid) begin
      result_comb = fma_result;
      flags_comb  = fma_flags;
    end else if (compare_valid) begin
      result_comb = compare_result;
      result_to_int_comb = compare_is_compare;  // FEQ/FLT/FLE results go to integer register
      flags_comb = compare_flags;
    end else if (convert_valid) begin
      result_comb = convert_is_fp_to_int ? zext_xlen(convert_int_result) : convert_fp_result;
      result_to_int_comb = convert_is_fp_to_int;
      flags_comb = convert_flags;
    end else if (classify_valid) begin
      result_comb = zext_xlen(classify_result);
      result_to_int_comb = 1'b1;  // FCLASS result goes to integer register
    end else if (sign_inject_valid) begin
      result_comb = sign_inject_result;
    end else if (divider_valid) begin
      result_comb = divider_result;
      flags_comb  = divider_flags;
    end else if (sqrt_valid) begin
      result_comb = sqrt_result;
      flags_comb  = sqrt_flags;
    end
  end

  // Register outputs for timing (adds 1 cycle of latency to all FPU ops).
  logic [FpWidth-1:0] result_reg;
  riscv_pkg::fp_flags_t flags_reg;
  logic result_to_int_reg;
  logic [4:0] dest_reg_out;
  logic valid_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      result_reg <= '0;
      flags_reg <= '0;
      result_to_int_reg <= 1'b0;
      dest_reg_out <= 5'b0;
      valid_reg <= 1'b0;
    end else begin
      valid_reg <= any_valid_comb;
      if (any_valid_comb) begin
        result_reg <= result_comb;
        flags_reg <= flags_comb;
        result_to_int_reg <= result_to_int_comb;
        dest_reg_out <= dest_reg_comb;
      end
    end
  end

  assign o_result = result_reg;
  assign o_flags = flags_reg;
  assign o_result_to_int = result_to_int_reg;
  assign o_dest_reg = dest_reg_out;
  assign o_valid = valid_reg;

  // Stall output for multi-cycle operations.
  // Use a registered active flag plus a small range check to avoid feeding
  // the full operation decode into the stall path.
  logic start_any;
  logic fpu_active;
  assign start_any = adder_start | multiplier_start | fma_start | compare_start |
                     convert_start | classify_start | sign_inject_start | seq_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) fpu_active <= 1'b0;
    else if (valid_reg) fpu_active <= 1'b0;
    else if (start_any) fpu_active <= 1'b1;
  end

  // Stall includes input_capture_pending to account for the input pipeline stage
  assign o_stall = (fpu_active | (i_valid & is_fp_op_for_stall) | input_capture_pending) &
                   ~valid_reg;

  // ===========================================================================
  // In-Flight Destination Register Outputs
  // ===========================================================================
  // For RAW hazard detection: expose destinations of in-flight operations.
  // Since multi-cycle ops stall the pipeline, there's only one in-flight
  // destination at a time for each unit type.
  // In-flight destinations for RAW hazard detection
  // These go to 0 when the operation is complete (busy goes low) so hazards clear.
  // The next instruction should use forwarding from MA.
  assign o_inflight_dest_1 = adder_busy ? dest_reg_adder : 5'b0;
  assign o_inflight_dest_2 = multiplier_busy ? dest_reg_multiplier : 5'b0;
  assign o_inflight_dest_3 = fma_busy ? dest_reg_fma : 5'b0;
  assign o_inflight_dest_4 = compare_busy ? dest_reg_compare : 5'b0;
  assign o_inflight_dest_5 = convert_busy ? dest_reg_convert : 5'b0;
  logic seq_inflight;
  // Drop sequential inflight hazard when the result is valid so EX->MA can capture it.
  assign seq_inflight = dest_reg_seq_valid & ~(divider_valid | sqrt_valid);
  assign o_inflight_dest_6 = seq_inflight ? dest_reg_seq : 5'b0;

endmodule : fpu
