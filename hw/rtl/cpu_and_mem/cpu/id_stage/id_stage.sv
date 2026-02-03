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
 * Instruction Decode (ID) stage - Third stage of the 6-stage RISC-V pipeline.
 *
 * This module decodes RISC-V instructions into control signals and immediate values.
 * It instantiates decoders for instruction type determination and immediate
 * value extraction. The module identifies load instructions, store operations, branch
 * conditions, and ALU operations. It supports pipeline flushing on branch mispredictions
 * and stalling for hazards. The decoded information is passed to the Execute stage through
 * a pipeline register that can be flushed or stalled as needed for correct program execution.
 *
 * Submodule Hierarchy:
 * ====================
 *   id_stage
 *   ├── instr_decoder           - Main instruction decoder (opcode -> operation)
 *   ├── immediate_decoder       - Immediate value extraction (I/S/B/U/J types)
 *   ├── instruction_type_decoder - Direct instruction type detection (timing optimization)
 *   └── branch_target_precompute - Pre-computed branch/jump targets and prediction verification
 */
module id_stage #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::rf_to_fwd_t i_rf_to_id,  // Regfile read data (combinational from PD src regs)
    input riscv_pkg::fp_rf_to_fwd_t i_fp_rf_to_id,  // FP regfile read data (F extension)
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,  // WB bypass (WB writes same cycle ID reads)
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex
);

  // Internal signals for decoded instruction information
  riscv_pkg::instr_t instruction;
  riscv_pkg::instr_op_e instruction_operation;
  riscv_pkg::branch_taken_op_e branch_operation;
  riscv_pkg::store_op_e store_operation;

  // Immediate values for different instruction formats
  logic [XLEN-1:0] immediate_i_type;
  logic [XLEN-1:0] immediate_s_type;
  logic [XLEN-1:0] immediate_b_type;
  logic [XLEN-1:0] immediate_u_type;
  logic [XLEN-1:0] immediate_j_type;

  // Instruction type detection signals
  logic is_load_instruction;
  logic is_load_byte_direct;
  logic is_load_halfword_direct;
  logic is_load_unsigned_direct;
  logic is_multiply_direct;
  logic is_divide_direct;
  logic is_csr_instruction;
  logic [11:0] csr_address;
  logic [4:0] csr_imm;
  logic is_amo_instruction;
  logic is_lr;
  logic is_sc;
  logic is_ecall;
  logic is_ebreak;
  logic is_mret;
  logic is_wfi;
  logic is_jal_direct;
  logic is_jalr_direct;
  logic is_ras_return_precomputed;
  logic is_ras_call_precomputed;

  // Pre-computed branch/jump targets and prediction verification
  logic [XLEN-1:0] branch_target_precomputed;
  logic [XLEN-1:0] jal_target_precomputed;
  logic [XLEN-1:0] ras_expected_rs1_precomputed;
  logic [XLEN-1:0] btb_expected_rs1_precomputed;
  logic btb_correct_non_jalr_precomputed;

  assign instruction = i_from_pd_to_id.instruction;

  // ===========================================================================
  // Submodule Instantiations
  // ===========================================================================

  // Instantiate instruction decoder to determine operation type
  instr_decoder instr_decoder_inst (
      .i_instr(instruction),
      .o_instr_op(instruction_operation),
      .o_store_op(store_operation),
      .o_branch_taken_op(branch_operation)
  );

  // Instantiate immediate decoder for all immediate formats
  immediate_decoder #(
      .XLEN(XLEN)
  ) immediate_decoder_inst (
      .i_instruction(instruction),
      .o_immediate_i_type(immediate_i_type),
      .o_immediate_s_type(immediate_s_type),
      .o_immediate_b_type(immediate_b_type),
      .o_immediate_u_type(immediate_u_type),
      .o_immediate_j_type(immediate_j_type)
  );

  // Instantiate instruction type decoder for direct type detection
  instruction_type_decoder #(
      .XLEN(XLEN)
  ) instruction_type_decoder_inst (
      .i_instruction(instruction),
      .i_immediate_i_type(immediate_i_type),
      // Load type outputs
      .o_is_load_instruction(is_load_instruction),
      .o_is_load_byte(is_load_byte_direct),
      .o_is_load_halfword(is_load_halfword_direct),
      .o_is_load_unsigned(is_load_unsigned_direct),
      // M-extension outputs
      .o_is_multiply(is_multiply_direct),
      .o_is_divide(is_divide_direct),
      // CSR outputs
      .o_is_csr_instruction(is_csr_instruction),
      .o_csr_address(csr_address),
      .o_csr_imm(csr_imm),
      // A-extension outputs
      .o_is_amo_instruction(is_amo_instruction),
      .o_is_lr(is_lr),
      .o_is_sc(is_sc),
      // Privileged instruction outputs
      .o_is_ecall(is_ecall),
      .o_is_ebreak(is_ebreak),
      .o_is_mret(is_mret),
      .o_is_wfi(is_wfi),
      // JAL/JALR outputs
      .o_is_jal(is_jal_direct),
      .o_is_jalr(is_jalr_direct),
      // RAS instruction type outputs
      .o_is_ras_return(is_ras_return_precomputed),
      .o_is_ras_call(is_ras_call_precomputed)
  );

  // Instantiate branch target pre-computation unit
  branch_target_precompute #(
      .XLEN(XLEN)
  ) branch_target_precompute_inst (
      .i_program_counter(i_from_pd_to_id.program_counter),
      .i_immediate_i_type(immediate_i_type),
      .i_immediate_b_type(immediate_b_type),
      .i_immediate_j_type(immediate_j_type),
      .i_ras_predicted_target(i_from_pd_to_id.ras_predicted_target),
      .i_btb_predicted_target(i_from_pd_to_id.btb_predicted_target),
      .i_is_jal(is_jal_direct),
      // Pre-computed target outputs
      .o_branch_target_precomputed(branch_target_precomputed),
      .o_jal_target_precomputed(jal_target_precomputed),
      // Pre-computed RAS verification
      .o_ras_expected_rs1(ras_expected_rs1_precomputed),
      // Pre-computed BTB verification
      .o_btb_expected_rs1(btb_expected_rs1_precomputed),
      .o_btb_correct_non_jalr(btb_correct_non_jalr_precomputed)
  );

  // F extension - floating-point instruction detection
  // Direct decode from opcode for timing optimization
  logic is_fp_load_direct;  // FLW/FLD
  logic is_fp_store_direct;  // FSW/FSD
  logic is_fp_load_double_direct;  // FLD
  logic is_fp_store_double_direct;  // FSD
  logic is_fp_compute_direct;  // All F arithmetic/compare/convert ops
  logic is_fp_fma_direct;  // FMA instructions (separate opcode)
  logic is_fp_instruction_direct;

  assign is_fp_load_direct = (instruction.opcode == riscv_pkg::OPC_LOAD_FP) &&
                             ((instruction.funct3 == 3'b010) ||
                              (instruction.funct3 == 3'b011));
  assign is_fp_store_direct = (instruction.opcode == riscv_pkg::OPC_STORE_FP) &&
                              ((instruction.funct3 == 3'b010) ||
                               (instruction.funct3 == 3'b011));
  assign is_fp_load_double_direct = (instruction.opcode == riscv_pkg::OPC_LOAD_FP) &&
                                    (instruction.funct3 == 3'b011);
  assign is_fp_store_double_direct = (instruction.opcode == riscv_pkg::OPC_STORE_FP) &&
                                     (instruction.funct3 == 3'b011);
  assign is_fp_compute_direct = instruction.opcode == riscv_pkg::OPC_OP_FP;
  assign is_fp_fma_direct = (instruction.opcode == riscv_pkg::OPC_FMADD) |
                            (instruction.opcode == riscv_pkg::OPC_FMSUB) |
                            (instruction.opcode == riscv_pkg::OPC_FNMSUB) |
                            (instruction.opcode == riscv_pkg::OPC_FNMADD);
  assign is_fp_instruction_direct = is_fp_load_direct | is_fp_store_direct |
                                   is_fp_compute_direct | is_fp_fma_direct;

  // FP instructions that produce integer results (write to integer regfile)
  // FEQ, FLT, FLE: funct7[6:2]=10100, funct3 determines compare type
  // FCLASS.S: funct7[6:2]=11100, funct3=001
  // FCVT.W.S, FCVT.WU.S: funct7[6:2]=11000
  // FMV.X.W: funct7[6:2]=11100, funct3=000
  logic is_fp_to_int_direct;
  assign is_fp_to_int_direct = is_fp_compute_direct && (
      (instruction.funct7[6:2] == 5'b10100) |  // FEQ/FLT/FLE
      (instruction.funct7[6:2] == 5'b11100 && instruction.funct3 == 3'b001) |  // FCLASS
      (instruction.funct7[6:2] == 5'b11000) |  // FCVT.W.S, FCVT.WU.S
      (instruction.funct7[6:2] == 5'b11100 && instruction.funct3 == 3'b000)  // FMV.X.W
      );

  // FP instructions that take integer source (read from integer regfile)
  // FCVT.S.W, FCVT.S.WU: funct7[6:2]=11010
  // FMV.W.X: funct7[6:2]=11110, funct3=000
  logic is_int_to_fp_direct;
  assign is_int_to_fp_direct = is_fp_compute_direct && (
      (instruction.funct7[6:2] == 5'b11010) |  // FCVT.S.W, FCVT.S.WU
      (instruction.funct7[6:2] == 5'b11110 && instruction.funct3 == 3'b000)  // FMV.W.X
      );

  // Pipelined FP operations (multi-cycle ops that track in-flight destinations)
  // Used by hazard_resolution_unit to detect RAW hazards without re-decoding the operation.
  // Includes: FADD, FSUB, FMUL, FDIV, FSQRT, and all FMA variants
  logic is_pipelined_fp_op_direct;
  assign is_pipelined_fp_op_direct = is_fp_fma_direct |  // All FMA ops
      (is_fp_compute_direct && (
          instruction.funct7[6:3] == 4'b0000 ||  // FADD.S (0000000), FSUB.S (0000100)
      instruction.funct7[6:3] == 4'b0001 ||  // FMUL.S (0001000), FDIV.S (0001100)
      instruction.funct7[6:2] == 5'b01011  // FSQRT.S (0101100)
      ));

  // Extract rounding mode from instruction (bits [14:12] = funct3)
  // For FP operations, funct3 encodes rounding mode
  logic [2:0] fp_rm_direct;
  assign fp_rm_direct = instruction.funct3;

  // ===========================================================================
  // WB Bypass Logic
  // ===========================================================================
  // WB bypass for regfile data: When WB writes to a register that ID is reading,
  // we must use the WB write data instead of the regfile read data. This is because
  // the regfile read (async) happens the same cycle as the WB write (sync), so the
  // regfile read would get stale data before the write commits.

  logic wb_bypass_rs1;
  logic wb_bypass_rs2;
  logic [XLEN-1:0] source_reg_1_data_bypassed;
  logic [XLEN-1:0] source_reg_2_data_bypassed;

  assign wb_bypass_rs1 = i_from_ma_to_wb.regfile_write_enable &&
                         |i_from_ma_to_wb.instruction.dest_reg &&
                         (i_from_ma_to_wb.instruction.dest_reg ==
                          i_from_pd_to_id.source_reg_1_early);
  assign wb_bypass_rs2 = i_from_ma_to_wb.regfile_write_enable &&
                         |i_from_ma_to_wb.instruction.dest_reg &&
                         (i_from_ma_to_wb.instruction.dest_reg ==
                          i_from_pd_to_id.source_reg_2_early);

  assign source_reg_1_data_bypassed = wb_bypass_rs1 ? i_from_ma_to_wb.regfile_write_data :
                                                      i_rf_to_id.source_reg_1_data;
  assign source_reg_2_data_bypassed = wb_bypass_rs2 ? i_from_ma_to_wb.regfile_write_data :
                                                      i_rf_to_id.source_reg_2_data;

  // F extension: WB bypass for FP registers
  // Same-cycle bypass: When WB writes to an FP register that ID is reading
  logic fp_wb_bypass_rs1;
  logic fp_wb_bypass_rs2;
  logic fp_wb_bypass_rs3;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_1_data_bypassed;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_2_data_bypassed;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_3_data_bypassed;

  // Use fp_dest_reg instead of instruction.dest_reg because for pipelined FPU
  // operations, the original instruction has moved on but fp_dest_reg tracks the
  // actual destination register being written.
  assign fp_wb_bypass_rs1 = i_from_ma_to_wb.fp_regfile_write_enable &&
                            (i_from_ma_to_wb.fp_dest_reg ==
                             i_from_pd_to_id.source_reg_1_early);
  assign fp_wb_bypass_rs2 = i_from_ma_to_wb.fp_regfile_write_enable &&
                            (i_from_ma_to_wb.fp_dest_reg ==
                             i_from_pd_to_id.source_reg_2_early);
  assign fp_wb_bypass_rs3 = i_from_ma_to_wb.fp_regfile_write_enable &&
                            (i_from_ma_to_wb.fp_dest_reg ==
                             i_from_pd_to_id.fp_source_reg_3_early);

  assign fp_source_reg_1_data_bypassed = fp_wb_bypass_rs1 ? i_from_ma_to_wb.fp_regfile_write_data :
                                                           i_fp_rf_to_id.fp_source_reg_1_data;
  assign fp_source_reg_2_data_bypassed = fp_wb_bypass_rs2 ? i_from_ma_to_wb.fp_regfile_write_data :
                                                           i_fp_rf_to_id.fp_source_reg_2_data;
  assign fp_source_reg_3_data_bypassed = fp_wb_bypass_rs3 ? i_from_ma_to_wb.fp_regfile_write_data :
                                                           i_fp_rf_to_id.fp_source_reg_3_data;

  // ===========================================================================
  // Source Register x0 Check Pre-computation
  // ===========================================================================
  // TIMING OPTIMIZATION: Pre-compute x0 check for source registers.
  // This moves the ~|source_reg NOR gate out of the EX stage critical path.
  // The forwarding unit uses these registered flags instead of computing them combinationally.

  logic source_reg_1_is_x0;
  logic source_reg_2_is_x0;
  assign source_reg_1_is_x0 = ~|i_from_pd_to_id.source_reg_1_early;
  assign source_reg_2_is_x0 = ~|i_from_pd_to_id.source_reg_2_early;

  // ===========================================================================
  // Pipeline Register
  // ===========================================================================
  // Latch decoded values and pass to Execute stage

  always_ff @(posedge i_clk) begin
    // On reset, insert a NOP (no operation) into the pipeline
    if (i_pipeline_ctrl.reset) begin
      o_from_id_to_ex.instruction                  <= riscv_pkg::NOP;
      o_from_id_to_ex.instruction_operation        <= riscv_pkg::ADDI;  // ADDI x0, x0, 0 (NOP)
      o_from_id_to_ex.is_load_instruction          <= 1'b0;
      o_from_id_to_ex.is_load_byte                 <= 1'b0;
      o_from_id_to_ex.is_load_halfword             <= 1'b0;
      o_from_id_to_ex.is_load_unsigned             <= 1'b0;
      o_from_id_to_ex.is_multiply                  <= 1'b0;
      o_from_id_to_ex.is_divide                    <= 1'b0;
      o_from_id_to_ex.program_counter              <= '0;
      o_from_id_to_ex.branch_operation             <= riscv_pkg::NULL;
      o_from_id_to_ex.store_operation              <= riscv_pkg::STN;  // Store nothing
      o_from_id_to_ex.is_jump_and_link             <= 1'b0;
      o_from_id_to_ex.is_jump_and_link_register    <= 1'b0;
      o_from_id_to_ex.is_csr_instruction           <= 1'b0;
      o_from_id_to_ex.csr_address                  <= '0;
      o_from_id_to_ex.csr_imm                      <= '0;
      // A extension (atomics)
      o_from_id_to_ex.is_amo_instruction           <= 1'b0;
      o_from_id_to_ex.is_lr                        <= 1'b0;
      o_from_id_to_ex.is_sc                        <= 1'b0;
      // Privileged instructions (trap handling)
      o_from_id_to_ex.is_mret                      <= 1'b0;
      o_from_id_to_ex.is_wfi                       <= 1'b0;
      o_from_id_to_ex.is_ecall                     <= 1'b0;
      o_from_id_to_ex.is_ebreak                    <= 1'b0;
      o_from_id_to_ex.link_address                 <= '0;
      // Pre-computed branch/jump targets (pipeline balancing)
      o_from_id_to_ex.branch_target_precomputed    <= '0;
      o_from_id_to_ex.jal_target_precomputed       <= '0;
      // Regfile read data (read in ID stage using early source regs from PD)
      o_from_id_to_ex.source_reg_1_data            <= '0;
      o_from_id_to_ex.source_reg_2_data            <= '0;
      // Pre-computed x0 check flags (timing optimization)
      o_from_id_to_ex.source_reg_1_is_x0           <= 1'b1;  // NOP uses x0
      o_from_id_to_ex.source_reg_2_is_x0           <= 1'b1;  // NOP uses x0
      // Branch prediction metadata
      o_from_id_to_ex.btb_hit                      <= 1'b0;
      o_from_id_to_ex.btb_predicted_taken          <= 1'b0;
      o_from_id_to_ex.btb_predicted_target         <= '0;
      // RAS prediction metadata
      o_from_id_to_ex.ras_predicted                <= 1'b0;
      o_from_id_to_ex.ras_predicted_target         <= '0;
      o_from_id_to_ex.ras_checkpoint_tos           <= '0;
      o_from_id_to_ex.ras_checkpoint_valid_count   <= '0;
      // TIMING OPTIMIZATION: Pre-computed RAS instruction type flags
      o_from_id_to_ex.is_ras_return                <= 1'b0;
      o_from_id_to_ex.is_ras_call                  <= 1'b0;
      o_from_id_to_ex.ras_predicted_target_nonzero <= 1'b0;
      o_from_id_to_ex.ras_expected_rs1             <= '0;
      // TIMING OPTIMIZATION: Pre-computed BTB verification
      o_from_id_to_ex.btb_correct_non_jalr         <= 1'b0;
      o_from_id_to_ex.btb_expected_rs1             <= '0;
      // F extension
      o_from_id_to_ex.is_fp_instruction            <= 1'b0;
      o_from_id_to_ex.is_fp_load                   <= 1'b0;
      o_from_id_to_ex.is_fp_store                  <= 1'b0;
      o_from_id_to_ex.is_fp_load_double            <= 1'b0;
      o_from_id_to_ex.is_fp_store_double           <= 1'b0;
      o_from_id_to_ex.is_fp_compute                <= 1'b0;
      o_from_id_to_ex.is_pipelined_fp_op           <= 1'b0;
      o_from_id_to_ex.is_fp_to_int                 <= 1'b0;
      o_from_id_to_ex.is_int_to_fp                 <= 1'b0;
      o_from_id_to_ex.fp_rm                        <= 3'b0;
      o_from_id_to_ex.fp_source_reg_1_data         <= '0;
      o_from_id_to_ex.fp_source_reg_2_data         <= '0;
      o_from_id_to_ex.fp_source_reg_3_data         <= '0;
    end else if (~i_pipeline_ctrl.stall) begin
      // When pipeline is not stalled, pass decoded instruction to Execute stage
      // If flushing (e.g., due to branch), insert NOP instead
      o_from_id_to_ex.instruction <= i_pipeline_ctrl.flush ? riscv_pkg::NOP : instruction;
      o_from_id_to_ex.instruction_operation <= i_pipeline_ctrl.flush ? riscv_pkg::ADDI :
                                                                       instruction_operation;
      o_from_id_to_ex.is_load_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_load_instruction;
      // Determine load size and sign extension - use direct decode for timing
      o_from_id_to_ex.is_load_byte <= i_pipeline_ctrl.flush ? 1'b0 : is_load_byte_direct;
      o_from_id_to_ex.is_load_halfword <= i_pipeline_ctrl.flush ? 1'b0 : is_load_halfword_direct;
      o_from_id_to_ex.is_load_unsigned <= i_pipeline_ctrl.flush ? 1'b0 : is_load_unsigned_direct;
      // Check if this is a multiply operation (M extension) - use direct decode
      o_from_id_to_ex.is_multiply <= i_pipeline_ctrl.flush ? 1'b0 : is_multiply_direct;
      // Check if this is a divide/remainder operation (M extension) - use direct decode
      o_from_id_to_ex.is_divide <= i_pipeline_ctrl.flush ? 1'b0 : is_divide_direct;
      o_from_id_to_ex.program_counter <= i_from_pd_to_id.program_counter;
      o_from_id_to_ex.branch_operation <= i_pipeline_ctrl.flush ? riscv_pkg::NULL :
                                                                  branch_operation;
      o_from_id_to_ex.store_operation <= i_pipeline_ctrl.flush ? riscv_pkg::STN : store_operation;
      o_from_id_to_ex.is_jump_and_link <= i_pipeline_ctrl.flush ? 1'b0 : is_jal_direct;
      o_from_id_to_ex.is_jump_and_link_register <= i_pipeline_ctrl.flush ? 1'b0 : is_jalr_direct;
      // CSR instruction fields (Zicsr extension)
      o_from_id_to_ex.is_csr_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_csr_instruction;
      o_from_id_to_ex.csr_address <= csr_address;
      o_from_id_to_ex.csr_imm <= csr_imm;
      // A extension (atomics)
      o_from_id_to_ex.is_amo_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_amo_instruction;
      o_from_id_to_ex.is_lr <= i_pipeline_ctrl.flush ? 1'b0 : is_lr;
      o_from_id_to_ex.is_sc <= i_pipeline_ctrl.flush ? 1'b0 : is_sc;
      // Privileged instructions (trap handling)
      o_from_id_to_ex.is_mret <= i_pipeline_ctrl.flush ? 1'b0 : is_mret;
      o_from_id_to_ex.is_wfi <= i_pipeline_ctrl.flush ? 1'b0 : is_wfi;
      o_from_id_to_ex.is_ecall <= i_pipeline_ctrl.flush ? 1'b0 : is_ecall;
      o_from_id_to_ex.is_ebreak <= i_pipeline_ctrl.flush ? 1'b0 : is_ebreak;
      // Pre-computed link address from IF stage
      o_from_id_to_ex.link_address <= i_from_pd_to_id.link_address;
      // Pre-computed branch/jump targets (computed here, used by EX stage)
      o_from_id_to_ex.branch_target_precomputed <= branch_target_precomputed;
      o_from_id_to_ex.jal_target_precomputed <= jal_target_precomputed;
      // Branch prediction metadata - clear on flush (prediction for flushed instr is invalid)
      o_from_id_to_ex.btb_hit <= i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.btb_hit;
      o_from_id_to_ex.btb_predicted_taken <= i_pipeline_ctrl.flush ? 1'b0 :
                                              i_from_pd_to_id.btb_predicted_taken;
      o_from_id_to_ex.btb_predicted_target <= i_from_pd_to_id.btb_predicted_target;
      // RAS prediction metadata - clear on flush (prediction for flushed instr is invalid)
      o_from_id_to_ex.ras_predicted <= i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.ras_predicted;
      o_from_id_to_ex.ras_predicted_target <= i_from_pd_to_id.ras_predicted_target;
      o_from_id_to_ex.ras_checkpoint_tos <= i_from_pd_to_id.ras_checkpoint_tos;
      o_from_id_to_ex.ras_checkpoint_valid_count <= i_from_pd_to_id.ras_checkpoint_valid_count;
      // TIMING OPTIMIZATION: Pre-computed RAS instruction type flags
      // These remove comparisons from the EX stage critical path
      o_from_id_to_ex.is_ras_return <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_return_precomputed;
      o_from_id_to_ex.is_ras_call <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_call_precomputed;
      o_from_id_to_ex.ras_predicted_target_nonzero <= |i_from_pd_to_id.ras_predicted_target;
      // Pre-computed expected rs1 for RAS verification (removes JALR adder from critical path)
      o_from_id_to_ex.ras_expected_rs1 <= ras_expected_rs1_precomputed;
      // TIMING OPTIMIZATION: Pre-computed BTB verification
      // For non-JALR: target comparison done in ID stage (no forwarding dependency)
      // For JALR: use btb_expected_rs1 in EX stage (same algebraic transformation as RAS)
      o_from_id_to_ex.btb_correct_non_jalr <= i_pipeline_ctrl.flush ? 1'b0 :
                                              btb_correct_non_jalr_precomputed;
      o_from_id_to_ex.btb_expected_rs1 <= btb_expected_rs1_precomputed;
      // F extension - clear on flush
      o_from_id_to_ex.is_fp_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_instruction_direct;
      o_from_id_to_ex.is_fp_load <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_direct;
      o_from_id_to_ex.is_fp_store <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_direct;
      o_from_id_to_ex.is_fp_load_double <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_double_direct;
      o_from_id_to_ex.is_fp_store_double <= i_pipeline_ctrl.flush ? 1'b0 :
                                            is_fp_store_double_direct;
      o_from_id_to_ex.is_fp_compute <= i_pipeline_ctrl.flush ? 1'b0 :
                                       (is_fp_compute_direct | is_fp_fma_direct);
      o_from_id_to_ex.is_pipelined_fp_op <= i_pipeline_ctrl.flush ? 1'b0 :
                                            is_pipelined_fp_op_direct;
      o_from_id_to_ex.is_fp_to_int <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_to_int_direct;
      o_from_id_to_ex.is_int_to_fp <= i_pipeline_ctrl.flush ? 1'b0 : is_int_to_fp_direct;
      o_from_id_to_ex.fp_rm <= fp_rm_direct;
    end
    // Pass immediate values and regfile data (datapath, not affected by reset - only by stall)
    if (~i_pipeline_ctrl.stall) begin
      o_from_id_to_ex.immediate_u_type <= immediate_u_type;
      o_from_id_to_ex.immediate_s_type <= immediate_s_type;
      o_from_id_to_ex.immediate_i_type <= immediate_i_type;
      o_from_id_to_ex.immediate_b_type <= immediate_b_type;
      o_from_id_to_ex.immediate_j_type <= immediate_j_type;
      // Regfile read data (read in ID stage, with WB bypass, registered here for EX stage)
      o_from_id_to_ex.source_reg_1_data <= source_reg_1_data_bypassed;
      o_from_id_to_ex.source_reg_2_data <= source_reg_2_data_bypassed;
      // Pre-computed x0 check flags (timing optimization for forwarding unit)
      o_from_id_to_ex.source_reg_1_is_x0 <= source_reg_1_is_x0;
      o_from_id_to_ex.source_reg_2_is_x0 <= source_reg_2_is_x0;
      // F extension: FP register file read data (with WB bypass)
      o_from_id_to_ex.fp_source_reg_1_data <= fp_source_reg_1_data_bypassed;
      o_from_id_to_ex.fp_source_reg_2_data <= fp_source_reg_2_data_bypassed;
      o_from_id_to_ex.fp_source_reg_3_data <= fp_source_reg_3_data_bypassed;
    end
  end

endmodule : id_stage
