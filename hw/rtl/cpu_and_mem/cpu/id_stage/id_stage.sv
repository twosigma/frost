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
 * Third in-order front-end stage. Decodes up to two instructions and registers
 * their dispatch packets, with flush and stall handling. Parallel helpers
 * decode operations, immediates, timing-critical instruction classes, and
 * branch targets.
 */
module id_stage #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    // Predicted-taken redirect override from pd_stage. The redirect and its
    // target are formed from PD registers only (the same signals IF gets).
    // Applying the override here, not in pd_stage's o_from_pd_to_id register,
    // keeps target arithmetic off the PD-to-ID register D path.
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    input riscv_pkg::rf_to_fwd_t i_rf_to_id,  // Regfile read data (combinational from PD src regs)
    input riscv_pkg::fp_rf_to_fwd_t i_fp_rf_to_id,  // FP regfile read data (F extension)
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,  // WB bypass (WB writes same cycle ID reads)
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex,
    // Next-edge value of o_from_id_to_ex (its register D), for a consumer
    // that keeps a registered copy of fields it selects against this output.
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex_next,
    // Slot-2 instruction (2-wide dispatch).  Mirror of the slot-1 inputs above.
    // Slot 2 does not receive the PD predicted-taken redirect override, which
    // covers slot 1 only (see pd_stage.sv).  Slot 2 carries its own BTB
    // metadata (staged slot-2 BTB lookup) but no RAS prediction; IF ties that
    // off.  A slot-2 misprediction recovers in the back end like any other.
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id_2,
    input riscv_pkg::rf_to_fwd_t i_rf_to_id_2,
    input riscv_pkg::fp_rf_to_fwd_t i_fp_rf_to_id_2,
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex_2,
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex_next_2
);

  // Effective BTB metadata after applying the PD predicted-taken redirect override.
  // i_pd_redirect combines a registered branch candidate with the same-edge
  // PD-to-ID packet's registered veto metadata, so it is high in the cycle the
  // detected branch itself reaches id_stage and the override lands on that
  // instruction.
  logic [XLEN-1:0] effective_btb_predicted_target;
  logic            effective_btb_hit;
  logic            effective_btb_predicted_taken;
  assign effective_btb_predicted_target = i_pd_redirect ? i_pd_redirect_target :
                                          i_from_pd_to_id.btb_predicted_target;
  assign effective_btb_hit = i_pd_redirect | i_from_pd_to_id.btb_hit;
  assign effective_btb_predicted_taken = i_pd_redirect | i_from_pd_to_id.btb_predicted_taken;

  // Slot-1 instruction and decoder outputs
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
  logic is_sret;
  logic is_dret;
  logic is_wfi;
  logic is_jal_direct;
  logic is_jalr_direct;
  logic is_ras_return_precomputed;
  logic is_ras_call_precomputed;

  // Pre-computed branch/jump targets and prediction verification
  logic [XLEN-1:0] branch_target_precomputed;
  logic [XLEN-1:0] jal_target_precomputed;
  logic [XLEN-1:0] link_address_precomputed;
  logic [XLEN-1:0] ras_expected_rs1_precomputed;
  logic [XLEN-1:0] btb_expected_rs1_precomputed;
  logic btb_correct_non_jalr_precomputed;
  logic ras_correct_non_jalr_precomputed;
  logic [XLEN-1:0] pc_relative_precomputed;

  // TIMING: pd_stage passes the instruction through un-NOP'd and carries the
  // bubble in inject_nop.  The NOP is applied here, from registered inputs in
  // one LUT, so the front-end-stall-fed NOP select stays off the D path of the
  // pd_stage 32-bit instruction register.
  assign instruction = i_from_pd_to_id.inject_nop ? riscv_pkg::NOP : i_from_pd_to_id.instruction;
  assign link_address_precomputed =
      i_from_pd_to_id.program_counter +
      (i_from_pd_to_id.is_compressed ? riscv_pkg::PcIncrementCompressed :
                                       riscv_pkg::PcIncrement32bit);

  // ===========================================================================
  // Submodule Instantiations
  // ===========================================================================

  logic decoder_illegal;

  instr_decoder instr_decoder_inst (
      .i_instr(instruction),
      .o_instr_op(instruction_operation),
      .o_store_op(store_operation),
      .o_branch_taken_op(branch_operation),
      .o_illegal(decoder_illegal)
  );

  logic is_illegal_instruction;
  assign is_illegal_instruction = decoder_illegal | i_from_pd_to_id.illegal_instruction;
  // A fetch fault (access or page fault) overrides decode entirely. The
  // fetched bytes are garbage and may even decode as a NOP, so the
  // dispatch-valid and operation paths both key on this flag, with priority
  // over illegal.
  logic is_fetch_fault;
  assign is_fetch_fault = i_from_pd_to_id.fetch_fault;
  // Fetch-fault qualifiers (meaningful only with is_fetch_fault): page fault
  // vs access fault, and a fault on the second halfword only (xtval = PC + 2).
  logic is_fetch_fault_page;
  logic is_fetch_fault_hi;
  assign is_fetch_fault_page = i_from_pd_to_id.fetch_fault_page;
  assign is_fetch_fault_hi   = i_from_pd_to_id.fetch_fault_hi;

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
      .o_is_sret(is_sret),
      .o_is_dret(is_dret),
      .o_is_wfi(is_wfi),
      // JAL/JALR outputs
      .o_is_jal(is_jal_direct),
      .o_is_jalr(is_jalr_direct),
      // RAS instruction type outputs
      .o_is_ras_return(is_ras_return_precomputed),
      .o_is_ras_call(is_ras_call_precomputed)
  );

  branch_target_precompute #(
      .XLEN(XLEN)
  ) branch_target_precompute_inst (
      .i_program_counter(i_from_pd_to_id.program_counter),
      .i_immediate_i_type(immediate_i_type),
      .i_immediate_b_type(immediate_b_type),
      .i_immediate_j_type(immediate_j_type),
      .i_ras_predicted_target(i_from_pd_to_id.ras_predicted_target),
      .i_btb_predicted_target(effective_btb_predicted_target),
      .i_immediate_u_type(immediate_u_type),
      .i_is_jal(is_jal_direct),
      .i_is_fetch_fault(is_fetch_fault),
      .i_is_fetch_fault_hi(is_fetch_fault_hi),
      // Pre-computed target outputs
      .o_branch_target_precomputed(branch_target_precomputed),
      .o_jal_target_precomputed(jal_target_precomputed),
      .o_pc_relative_precomputed(pc_relative_precomputed),
      // Pre-computed RAS verification
      .o_ras_expected_rs1(ras_expected_rs1_precomputed),
      // Pre-computed BTB verification
      .o_btb_expected_rs1(btb_expected_rs1_precomputed),
      .o_btb_correct_non_jalr(btb_correct_non_jalr_precomputed),
      .o_ras_correct_non_jalr(ras_correct_non_jalr_precomputed)
  );

  // F extension: floating-point instruction detection, decoded from the opcode
  // directly for timing.
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

  // FP instructions that produce integer results (write to integer regfile).
  // funct7[6:2] leaves out the fmt bits, so each pattern covers S and D:
  // FEQ, FLT, FLE: funct7[6:2]=10100, funct3 determines compare type
  // FCLASS: funct7[6:2]=11100, funct3=001
  // FCVT to integer (W, WU, L, LU): funct7[6:2]=11000
  // FMV.X.W, FMV.X.D: funct7[6:2]=11100, funct3=000
  logic is_fp_to_int_direct;
  assign is_fp_to_int_direct = is_fp_compute_direct && (
      (instruction.funct7[6:2] == 5'b10100) |  // FEQ/FLT/FLE
      (instruction.funct7[6:2] == 5'b11100 && instruction.funct3 == 3'b001) |  // FCLASS
      (instruction.funct7[6:2] == 5'b11000) |  // FCVT to integer
      (instruction.funct7[6:2] == 5'b11100 && instruction.funct3 == 3'b000)  // FMV.X.W/D
      );

  // FP instructions that take an integer source (read the integer regfile),
  // again for both S and D:
  // FCVT from integer (W, WU, L, LU): funct7[6:2]=11010
  // FMV.W.X, FMV.D.X: funct7[6:2]=11110, funct3=000
  logic is_int_to_fp_direct;
  assign is_int_to_fp_direct = is_fp_compute_direct && (
      (instruction.funct7[6:2] == 5'b11010) |  // FCVT from integer
      (instruction.funct7[6:2] == 5'b11110 && instruction.funct3 == 3'b000)  // FMV.W.X/D.X
      );

  // Multi-cycle FP operations: FADD, FSUB, FMUL, FDIV, FSQRT, and all FMA
  // variants. Nothing downstream uses this flag.
  logic is_pipelined_fp_op_direct;
  assign is_pipelined_fp_op_direct = is_fp_fma_direct |  // All FMA ops
      (is_fp_compute_direct && (
          instruction.funct7[6:3] == 4'b0000 ||  // FADD.S (0000000), FSUB.S (0000100)
      instruction.funct7[6:3] == 4'b0001 ||  // FMUL.S (0001000), FDIV.S (0001100)
      instruction.funct7[6:2] == 5'b01011  // FSQRT.S (0101100)
      ));

  // Rounding mode: for FP operations funct3 (bits [14:12]) encodes rm.
  logic [2:0] fp_rm_direct;
  assign fp_rm_direct = instruction.funct3;

  // ===========================================================================
  // WB Bypass Logic
  // ===========================================================================
  // WB bypass for regfile data.  When WB writes a register that ID is reading
  // in the same cycle, the asynchronous regfile read returns the stale value,
  // so the WB write data is selected instead.  In cpu_ooo this input is tied
  // off (write enables forced low, see from_ma_to_wb_commit there): ROB commit
  // can write from more than one source per cycle, and i_rf_to_id already
  // carries the resolved 3-source bypass from ooo_register_files, so this
  // single-source bypass never fires and i_rf_to_id falls through.

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

  // F extension: the same-cycle WB bypass for FP registers (also tied off in
  // cpu_ooo).
  logic fp_wb_bypass_rs1;
  logic fp_wb_bypass_rs2;
  logic fp_wb_bypass_rs3;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_1_data_bypassed;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_2_data_bypassed;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_3_data_bypassed;

  // The FP bypass compares fp_dest_reg, the FP register being written, not
  // instruction.dest_reg.
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
  // Pre-computed x0 flags for the source registers; nothing downstream uses
  // them.

  logic source_reg_1_is_x0;
  logic source_reg_2_is_x0;
  assign source_reg_1_is_x0 = ~|i_from_pd_to_id.source_reg_1_early;
  assign source_reg_2_is_x0 = ~|i_from_pd_to_id.source_reg_2_early;

  // ===========================================================================
  // Pre-decoded Operand-Classification Flags (timing optimization)
  // ===========================================================================
  // Dispatch reads these registered flags instead of decoding the operation.
  // The classifier reads PD's instruction bits in parallel with instr_decoder;
  // legality, fetch-fault and injected-NOP selection qualify the finished
  // class. This also removes operation-to-class decode from ID's D path and
  // the decoded queue's next-state shadow. Both slots use the same classifier.
  logic has_int_dest_pre;
  logic has_fp_dest_pre;
  logic uses_int_rs1_pre;
  logic uses_int_rs2_pre;
  logic uses_fp_rs1_pre;
  logic uses_fp_rs2_pre;
  logic uses_fp_rs3_pre;
  logic [2:0] rs_type_pre;
  logic is_int_store_pre;
  logic is_branch_or_jump_pre;
  logic is_fence_pre;
  logic is_fence_i_pre;
  logic is_sfence_vma_pre;
  logic is_csr_imm_pre;
  logic has_fp_flags_pre;

  instr_operand_classifier operand_classifier (
      .i_instr(i_from_pd_to_id.instruction),
      .i_inject_nop(i_from_pd_to_id.inject_nop),
      .i_illegal(is_illegal_instruction),
      .i_fetch_fault(is_fetch_fault),
      .o_has_int_dest(has_int_dest_pre),
      .o_has_fp_dest(has_fp_dest_pre),
      .o_uses_int_rs1(uses_int_rs1_pre),
      .o_uses_int_rs2(uses_int_rs2_pre),
      .o_uses_fp_rs1(uses_fp_rs1_pre),
      .o_uses_fp_rs2(uses_fp_rs2_pre),
      .o_uses_fp_rs3(uses_fp_rs3_pre),
      .o_rs_type(rs_type_pre),
      .o_is_int_store(is_int_store_pre),
      .o_is_branch_or_jump(is_branch_or_jump_pre),
      .o_is_fence(is_fence_pre),
      .o_is_fence_i(is_fence_i_pre),
      .o_is_sfence_vma(is_sfence_vma_pre),
      .o_is_csr_imm(is_csr_imm_pre),
      .o_has_fp_flags(has_fp_flags_pre)
  );

  // ===========================================================================
  // Pipeline Register
  // ===========================================================================
  // Register the decoded packet, which reaches dispatch through the decoded
  // bundle queue (directly when DECODED_QUEUE_DEPTH is 0).

  // TIMING: every o_from_id_to_ex/o_from_id_to_ex_2 payload register's clock
  // enable is this one advance term.  Left unnamed, synthesis drives all of
  // them from a single inverter of the stall.  Naming the advance and capping
  // its fanout lets the inverter replicate per register region; logically it
  // is just ~stall.  keep is required: without it synthesis folds the
  // inverter into a wider clock-enable LUT and drops the fanout cap with it.
  (* keep = "true", max_fanout = 64 *) logic id_advance;
  assign id_advance = ~i_pipeline_ctrl.stall;


  always_ff @(posedge i_clk) begin
    // Reset loads a NOP into the pipeline register.
    if (i_pipeline_ctrl.reset) begin
      o_from_id_to_ex.instruction               <= riscv_pkg::NOP;
      o_from_id_to_ex.is_compressed             <= 1'b0;
      o_from_id_to_ex.instruction_operation     <= riscv_pkg::ADDI;  // ADDI x0, x0, 0 (NOP)
      o_from_id_to_ex.is_load_instruction       <= 1'b0;
      o_from_id_to_ex.is_load_byte              <= 1'b0;
      o_from_id_to_ex.is_load_halfword          <= 1'b0;
      o_from_id_to_ex.is_load_unsigned          <= 1'b0;
      o_from_id_to_ex.is_multiply               <= 1'b0;
      o_from_id_to_ex.is_divide                 <= 1'b0;
      o_from_id_to_ex.branch_operation          <= riscv_pkg::NULL;
      o_from_id_to_ex.store_operation           <= riscv_pkg::STN;  // Store nothing
      o_from_id_to_ex.rs_type                   <= riscv_pkg::RS_INT;
      o_from_id_to_ex.is_int_store              <= 1'b0;
      o_from_id_to_ex.is_branch_or_jump         <= 1'b0;
      o_from_id_to_ex.is_fence                  <= 1'b0;
      o_from_id_to_ex.is_fence_i                <= 1'b0;
      o_from_id_to_ex.is_csr_imm                <= 1'b0;
      o_from_id_to_ex.has_fp_flags              <= 1'b0;
      o_from_id_to_ex.is_jump_and_link          <= 1'b0;
      o_from_id_to_ex.is_jump_and_link_register <= 1'b0;
      o_from_id_to_ex.is_csr_instruction        <= 1'b0;
      // A extension (atomics)
      o_from_id_to_ex.is_amo_instruction        <= 1'b0;
      o_from_id_to_ex.is_lr                     <= 1'b0;
      o_from_id_to_ex.is_sc                     <= 1'b0;
      // Privileged instructions (trap handling)
      o_from_id_to_ex.is_mret                   <= 1'b0;
      o_from_id_to_ex.is_sret                   <= 1'b0;
      o_from_id_to_ex.is_dret                   <= 1'b0;
      o_from_id_to_ex.is_sfence_vma             <= 1'b0;
      o_from_id_to_ex.is_wfi                    <= 1'b0;
      o_from_id_to_ex.is_ecall                  <= 1'b0;
      o_from_id_to_ex.is_ebreak                 <= 1'b0;
      o_from_id_to_ex.is_illegal_instruction    <= 1'b0;
      o_from_id_to_ex.is_fetch_fault            <= 1'b0;
      o_from_id_to_ex.is_fetch_fault_page       <= 1'b0;
      o_from_id_to_ex.is_fetch_fault_hi         <= 1'b0;
      // Branch prediction metadata
      o_from_id_to_ex.btb_hit                   <= 1'b0;
      o_from_id_to_ex.btb_predicted_taken       <= 1'b0;
      // RAS prediction metadata
      o_from_id_to_ex.ras_predicted             <= 1'b0;
      // Pre-computed RAS instruction type flags
      o_from_id_to_ex.is_ras_return             <= 1'b0;
      o_from_id_to_ex.is_ras_call               <= 1'b0;
      // Pre-computed BTB verification
      o_from_id_to_ex.btb_correct_non_jalr      <= 1'b0;
      o_from_id_to_ex.ras_correct_non_jalr      <= 1'b0;
      // F extension
      o_from_id_to_ex.is_fp_instruction         <= 1'b0;
      o_from_id_to_ex.is_fp_load                <= 1'b0;
      o_from_id_to_ex.is_fp_store               <= 1'b0;
      o_from_id_to_ex.is_fp_load_double         <= 1'b0;
      o_from_id_to_ex.is_fp_store_double        <= 1'b0;
      o_from_id_to_ex.is_fp_compute             <= 1'b0;
      o_from_id_to_ex.is_pipelined_fp_op        <= 1'b0;
      o_from_id_to_ex.is_fp_to_int              <= 1'b0;
      o_from_id_to_ex.is_int_to_fp              <= 1'b0;
      // Pre-decoded operand-classification flags
      o_from_id_to_ex.has_int_dest              <= 1'b0;
      o_from_id_to_ex.has_fp_dest               <= 1'b0;
      o_from_id_to_ex.uses_int_rs1              <= 1'b0;
      o_from_id_to_ex.uses_int_rs2              <= 1'b0;
      o_from_id_to_ex.uses_fp_rs1               <= 1'b0;
      o_from_id_to_ex.uses_fp_rs2               <= 1'b0;
      o_from_id_to_ex.uses_fp_rs3               <= 1'b0;
      o_from_id_to_ex.is_not_nop                <= 1'b0;
    end else if (id_advance) begin
      // While the pipeline advances, pass the decoded instruction on, or a NOP
      // when flushing.
      o_from_id_to_ex.instruction <= i_pipeline_ctrl.flush ? riscv_pkg::NOP : instruction;
      o_from_id_to_ex.is_compressed <= i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.is_compressed;
      o_from_id_to_ex.instruction_operation <= i_pipeline_ctrl.flush ? riscv_pkg::ADDI :
                                                                       instruction_operation;
      o_from_id_to_ex.is_load_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_load_instruction;
      // Load size and sign extension, from direct decode for timing
      o_from_id_to_ex.is_load_byte <= i_pipeline_ctrl.flush ? 1'b0 : is_load_byte_direct;
      o_from_id_to_ex.is_load_halfword <= i_pipeline_ctrl.flush ? 1'b0 : is_load_halfword_direct;
      o_from_id_to_ex.is_load_unsigned <= i_pipeline_ctrl.flush ? 1'b0 : is_load_unsigned_direct;
      o_from_id_to_ex.is_multiply <= i_pipeline_ctrl.flush ? 1'b0 : is_multiply_direct;
      o_from_id_to_ex.is_divide <= i_pipeline_ctrl.flush ? 1'b0 : is_divide_direct;
      o_from_id_to_ex.branch_operation <= i_pipeline_ctrl.flush ? riscv_pkg::NULL :
                                                                  branch_operation;
      o_from_id_to_ex.store_operation <= i_pipeline_ctrl.flush ? riscv_pkg::STN : store_operation;
      o_from_id_to_ex.rs_type <= i_pipeline_ctrl.flush ? riscv_pkg::RS_INT : rs_type_pre;
      o_from_id_to_ex.is_int_store <= i_pipeline_ctrl.flush ? 1'b0 : is_int_store_pre;
      o_from_id_to_ex.is_branch_or_jump <= i_pipeline_ctrl.flush ? 1'b0 : is_branch_or_jump_pre;
      o_from_id_to_ex.is_fence <= i_pipeline_ctrl.flush ? 1'b0 : is_fence_pre;
      o_from_id_to_ex.is_fence_i <= i_pipeline_ctrl.flush ? 1'b0 : is_fence_i_pre;
      o_from_id_to_ex.is_csr_imm <= i_pipeline_ctrl.flush ? 1'b0 : is_csr_imm_pre;
      o_from_id_to_ex.has_fp_flags <= i_pipeline_ctrl.flush ? 1'b0 : has_fp_flags_pre;
      o_from_id_to_ex.is_jump_and_link <= i_pipeline_ctrl.flush ? 1'b0 : is_jal_direct;
      o_from_id_to_ex.is_jump_and_link_register <= i_pipeline_ctrl.flush ? 1'b0 : is_jalr_direct;
      // CSR instruction fields (Zicsr extension)
      o_from_id_to_ex.is_csr_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_csr_instruction;
      // A extension (atomics)
      o_from_id_to_ex.is_amo_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_amo_instruction;
      o_from_id_to_ex.is_lr <= i_pipeline_ctrl.flush ? 1'b0 : is_lr;
      o_from_id_to_ex.is_sc <= i_pipeline_ctrl.flush ? 1'b0 : is_sc;
      // Privileged instructions (trap handling)
      // is_mret carries any xRET (SRET and DRET ride the MRET machinery); is_sret
      // qualifies which one for the trap-unit/CSR side and the priv gates.
      o_from_id_to_ex.is_mret <= i_pipeline_ctrl.flush ? 1'b0 : (is_mret || is_sret || is_dret);
      o_from_id_to_ex.is_sret <= i_pipeline_ctrl.flush ? 1'b0 : is_sret;
      o_from_id_to_ex.is_dret <= i_pipeline_ctrl.flush ? 1'b0 : is_dret;
      o_from_id_to_ex.is_sfence_vma <= i_pipeline_ctrl.flush ? 1'b0 : is_sfence_vma_pre;
      o_from_id_to_ex.is_wfi <= i_pipeline_ctrl.flush ? 1'b0 : is_wfi;
      o_from_id_to_ex.is_ecall <= i_pipeline_ctrl.flush ? 1'b0 : is_ecall;
      o_from_id_to_ex.is_ebreak <= i_pipeline_ctrl.flush ? 1'b0 : is_ebreak;
      o_from_id_to_ex.is_illegal_instruction <= i_pipeline_ctrl.flush ? 1'b0 :
                                                is_illegal_instruction;
      o_from_id_to_ex.is_fetch_fault <= i_pipeline_ctrl.flush ? 1'b0 : is_fetch_fault;
      o_from_id_to_ex.is_fetch_fault_page <= is_fetch_fault_page;
      o_from_id_to_ex.is_fetch_fault_hi <= is_fetch_fault_hi;
      // Branch prediction metadata, cleared on flush (it belongs to a flushed instruction)
      o_from_id_to_ex.btb_hit <= i_pipeline_ctrl.flush ? 1'b0 : effective_btb_hit;
      o_from_id_to_ex.btb_predicted_taken <= i_pipeline_ctrl.flush ? 1'b0 :
                                              effective_btb_predicted_taken;
      // RAS prediction metadata, cleared on flush for the same reason
      o_from_id_to_ex.ras_predicted <= i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.ras_predicted;
      // Pre-computed RAS call/return flags; dispatch passes them to the ROB for
      // RAS recovery.
      o_from_id_to_ex.is_ras_return <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_return_precomputed;
      o_from_id_to_ex.is_ras_call <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_call_precomputed;
      // Pre-computed target checks.  A branch or JAL has a PC-relative target,
      // so ID compares it with both predictions; a JALR is checked at
      // resolution.
      o_from_id_to_ex.btb_correct_non_jalr <= i_pipeline_ctrl.flush ? 1'b0 :
                                              btb_correct_non_jalr_precomputed;
      o_from_id_to_ex.ras_correct_non_jalr <= i_pipeline_ctrl.flush ? 1'b0 :
                                              ras_correct_non_jalr_precomputed;
      // F extension, cleared on flush
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
      // Pre-decoded operand-classification flags, cleared on flush
      o_from_id_to_ex.has_int_dest <= i_pipeline_ctrl.flush ? 1'b0 : has_int_dest_pre;
      o_from_id_to_ex.has_fp_dest <= i_pipeline_ctrl.flush ? 1'b0 : has_fp_dest_pre;
      o_from_id_to_ex.uses_int_rs1 <= i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs1_pre;
      o_from_id_to_ex.uses_int_rs2 <= i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs2_pre;
      o_from_id_to_ex.uses_fp_rs1 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs1_pre;
      o_from_id_to_ex.uses_fp_rs2 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs2_pre;
      o_from_id_to_ex.uses_fp_rs3 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs3_pre;
      // Registered NOP detect.  After a flush or reset the register holds the
      // NOP pattern, so is_not_nop is 0 there too, which matches NOP semantics.
      // A fault-tagged bundle must dispatch even when its garbage bytes happen
      // to encode a NOP.
      o_from_id_to_ex.is_not_nop <= i_pipeline_ctrl.flush ? 1'b0 :
          ((instruction != riscv_pkg::NOP) || is_fetch_fault);
    end
    // Datapath payload (immediates, targets, regfile data): not reset, only stalled.
    if (id_advance) begin
      o_from_id_to_ex.program_counter <= i_from_pd_to_id.program_counter;
      o_from_id_to_ex.csr_address <= csr_address;
      o_from_id_to_ex.csr_imm <= csr_imm;
      // Compute link address from registered PD inputs instead of the live IF
      // sideband path.
      o_from_id_to_ex.link_address <= link_address_precomputed;
      // Pre-computed targets (see branch_target_precompute)
      o_from_id_to_ex.branch_target_precomputed <= branch_target_precomputed;
      o_from_id_to_ex.jal_target_precomputed <= jal_target_precomputed;
      o_from_id_to_ex.pc_relative_precomputed <= pc_relative_precomputed;
      o_from_id_to_ex.btb_predicted_target <= effective_btb_predicted_target;
      o_from_id_to_ex.ras_predicted_target <= i_from_pd_to_id.ras_predicted_target;
      o_from_id_to_ex.ras_checkpoint_tos <= i_from_pd_to_id.ras_checkpoint_tos;
      o_from_id_to_ex.ras_checkpoint_valid_count <= i_from_pd_to_id.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      o_from_id_to_ex.bp_dir_idx <= i_from_pd_to_id.bp_dir_idx;
      o_from_id_to_ex.ras_predicted_target_nonzero <= |i_from_pd_to_id.ras_predicted_target;
      // Expected rs1 values (see branch_target_precompute).
      o_from_id_to_ex.ras_expected_rs1 <= ras_expected_rs1_precomputed;
      o_from_id_to_ex.btb_expected_rs1 <= btb_expected_rs1_precomputed;
      o_from_id_to_ex.fp_rm <= fp_rm_direct;
      o_from_id_to_ex.immediate_u_type <= immediate_u_type;
      o_from_id_to_ex.immediate_s_type <= immediate_s_type;
      o_from_id_to_ex.immediate_i_type <= immediate_i_type;
      o_from_id_to_ex.immediate_b_type <= immediate_b_type;
      o_from_id_to_ex.immediate_j_type <= immediate_j_type;
      // Register file read data, with the WB bypass applied
      o_from_id_to_ex.source_reg_1_data <= source_reg_1_data_bypassed;
      o_from_id_to_ex.source_reg_2_data <= source_reg_2_data_bypassed;
      // Pre-computed x0 check flags
      o_from_id_to_ex.source_reg_1_is_x0 <= source_reg_1_is_x0;
      o_from_id_to_ex.source_reg_2_is_x0 <= source_reg_2_is_x0;
      // F extension: FP register file read data (with WB bypass)
      o_from_id_to_ex.fp_source_reg_1_data <= fp_source_reg_1_data_bypassed;
      o_from_id_to_ex.fp_source_reg_2_data <= fp_source_reg_2_data_bypassed;
      o_from_id_to_ex.fp_source_reg_3_data <= fp_source_reg_3_data_bypassed;
    end
  end

  // Next-edge value of o_from_id_to_ex: the always_ff update above, repeated
  // with a hold default. Change both together; the assertion below checks
  // that the register matches.
  riscv_pkg::from_id_to_ex_t id_next;
  assign o_from_id_to_ex_next = id_next;
  always_comb begin
    id_next = o_from_id_to_ex;
    // Reset loads a NOP into the pipeline register.
    if (i_pipeline_ctrl.reset) begin
      id_next.instruction = riscv_pkg::NOP;
      id_next.is_compressed = 1'b0;
      id_next.instruction_operation = riscv_pkg::ADDI;  // ADDI x0, x0, 0 (NOP)
      id_next.is_load_instruction = 1'b0;
      id_next.is_load_byte = 1'b0;
      id_next.is_load_halfword = 1'b0;
      id_next.is_load_unsigned = 1'b0;
      id_next.is_multiply = 1'b0;
      id_next.is_divide = 1'b0;
      id_next.branch_operation = riscv_pkg::NULL;
      id_next.store_operation = riscv_pkg::STN;  // Store nothing
      id_next.rs_type = riscv_pkg::RS_INT;
      id_next.is_int_store = 1'b0;
      id_next.is_branch_or_jump = 1'b0;
      id_next.is_fence = 1'b0;
      id_next.is_fence_i = 1'b0;
      id_next.is_csr_imm = 1'b0;
      id_next.has_fp_flags = 1'b0;
      id_next.is_jump_and_link = 1'b0;
      id_next.is_jump_and_link_register = 1'b0;
      id_next.is_csr_instruction = 1'b0;
      // A extension (atomics)
      id_next.is_amo_instruction = 1'b0;
      id_next.is_lr = 1'b0;
      id_next.is_sc = 1'b0;
      // Privileged instructions (trap handling)
      id_next.is_mret = 1'b0;
      id_next.is_sret = 1'b0;
      id_next.is_dret = 1'b0;
      id_next.is_sfence_vma = 1'b0;
      id_next.is_wfi = 1'b0;
      id_next.is_ecall = 1'b0;
      id_next.is_ebreak = 1'b0;
      id_next.is_illegal_instruction = 1'b0;
      id_next.is_fetch_fault = 1'b0;
      id_next.is_fetch_fault_page = 1'b0;
      id_next.is_fetch_fault_hi = 1'b0;
      // Branch prediction metadata
      id_next.btb_hit = 1'b0;
      id_next.btb_predicted_taken = 1'b0;
      // RAS prediction metadata
      id_next.ras_predicted = 1'b0;
      // Pre-computed RAS instruction type flags
      id_next.is_ras_return = 1'b0;
      id_next.is_ras_call = 1'b0;
      // Pre-computed BTB verification
      id_next.btb_correct_non_jalr = 1'b0;
      id_next.ras_correct_non_jalr = 1'b0;
      // F extension
      id_next.is_fp_instruction = 1'b0;
      id_next.is_fp_load = 1'b0;
      id_next.is_fp_store = 1'b0;
      id_next.is_fp_load_double = 1'b0;
      id_next.is_fp_store_double = 1'b0;
      id_next.is_fp_compute = 1'b0;
      id_next.is_pipelined_fp_op = 1'b0;
      id_next.is_fp_to_int = 1'b0;
      id_next.is_int_to_fp = 1'b0;
      // Pre-decoded operand-classification flags
      id_next.has_int_dest = 1'b0;
      id_next.has_fp_dest = 1'b0;
      id_next.uses_int_rs1 = 1'b0;
      id_next.uses_int_rs2 = 1'b0;
      id_next.uses_fp_rs1 = 1'b0;
      id_next.uses_fp_rs2 = 1'b0;
      id_next.uses_fp_rs3 = 1'b0;
      id_next.is_not_nop = 1'b0;
    end else if (id_advance) begin
      // While the pipeline advances, pass the decoded instruction on, or a NOP
      // when flushing.
      id_next.instruction = i_pipeline_ctrl.flush ? riscv_pkg::NOP : instruction;
      id_next.is_compressed = i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.is_compressed;
      id_next.instruction_operation = i_pipeline_ctrl.flush ? riscv_pkg::ADDI :
                                                                       instruction_operation;
      id_next.is_load_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_load_instruction;
      // Load size and sign extension, from direct decode for timing
      id_next.is_load_byte = i_pipeline_ctrl.flush ? 1'b0 : is_load_byte_direct;
      id_next.is_load_halfword = i_pipeline_ctrl.flush ? 1'b0 : is_load_halfword_direct;
      id_next.is_load_unsigned = i_pipeline_ctrl.flush ? 1'b0 : is_load_unsigned_direct;
      id_next.is_multiply = i_pipeline_ctrl.flush ? 1'b0 : is_multiply_direct;
      id_next.is_divide = i_pipeline_ctrl.flush ? 1'b0 : is_divide_direct;
      id_next.branch_operation = i_pipeline_ctrl.flush ? riscv_pkg::NULL : branch_operation;
      id_next.store_operation = i_pipeline_ctrl.flush ? riscv_pkg::STN : store_operation;
      id_next.rs_type = i_pipeline_ctrl.flush ? riscv_pkg::RS_INT : rs_type_pre;
      id_next.is_int_store = i_pipeline_ctrl.flush ? 1'b0 : is_int_store_pre;
      id_next.is_branch_or_jump = i_pipeline_ctrl.flush ? 1'b0 : is_branch_or_jump_pre;
      id_next.is_fence = i_pipeline_ctrl.flush ? 1'b0 : is_fence_pre;
      id_next.is_fence_i = i_pipeline_ctrl.flush ? 1'b0 : is_fence_i_pre;
      id_next.is_csr_imm = i_pipeline_ctrl.flush ? 1'b0 : is_csr_imm_pre;
      id_next.has_fp_flags = i_pipeline_ctrl.flush ? 1'b0 : has_fp_flags_pre;
      id_next.is_jump_and_link = i_pipeline_ctrl.flush ? 1'b0 : is_jal_direct;
      id_next.is_jump_and_link_register = i_pipeline_ctrl.flush ? 1'b0 : is_jalr_direct;
      // CSR instruction fields (Zicsr extension)
      id_next.is_csr_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_csr_instruction;
      // A extension (atomics)
      id_next.is_amo_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_amo_instruction;
      id_next.is_lr = i_pipeline_ctrl.flush ? 1'b0 : is_lr;
      id_next.is_sc = i_pipeline_ctrl.flush ? 1'b0 : is_sc;
      // Privileged instructions (trap handling)
      // is_mret carries any xRET (SRET and DRET ride the MRET machinery); is_sret
      // qualifies which one for the trap-unit/CSR side and the priv gates.
      id_next.is_mret = i_pipeline_ctrl.flush ? 1'b0 : (is_mret || is_sret || is_dret);
      id_next.is_sret = i_pipeline_ctrl.flush ? 1'b0 : is_sret;
      id_next.is_dret = i_pipeline_ctrl.flush ? 1'b0 : is_dret;
      id_next.is_sfence_vma = i_pipeline_ctrl.flush ? 1'b0 : is_sfence_vma_pre;
      id_next.is_wfi = i_pipeline_ctrl.flush ? 1'b0 : is_wfi;
      id_next.is_ecall = i_pipeline_ctrl.flush ? 1'b0 : is_ecall;
      id_next.is_ebreak = i_pipeline_ctrl.flush ? 1'b0 : is_ebreak;
      id_next.is_illegal_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_illegal_instruction;
      id_next.is_fetch_fault = i_pipeline_ctrl.flush ? 1'b0 : is_fetch_fault;
      id_next.is_fetch_fault_page = is_fetch_fault_page;
      id_next.is_fetch_fault_hi = is_fetch_fault_hi;
      // Branch prediction metadata, cleared on flush (it belongs to a flushed instruction)
      id_next.btb_hit = i_pipeline_ctrl.flush ? 1'b0 : effective_btb_hit;
      id_next.btb_predicted_taken = i_pipeline_ctrl.flush ? 1'b0 : effective_btb_predicted_taken;
      // RAS prediction metadata, cleared on flush for the same reason
      id_next.ras_predicted = i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id.ras_predicted;
      // Pre-computed RAS call/return flags; dispatch passes them to the ROB for
      // RAS recovery.
      id_next.is_ras_return = i_pipeline_ctrl.flush ? 1'b0 : is_ras_return_precomputed;
      id_next.is_ras_call = i_pipeline_ctrl.flush ? 1'b0 : is_ras_call_precomputed;
      // Pre-computed target checks.  A branch or JAL has a PC-relative target,
      // so ID compares it with both predictions; a JALR is checked at
      // resolution.
      id_next.btb_correct_non_jalr = i_pipeline_ctrl.flush ? 1'b0 :
                                              btb_correct_non_jalr_precomputed;
      id_next.ras_correct_non_jalr = i_pipeline_ctrl.flush ? 1'b0 :
                                              ras_correct_non_jalr_precomputed;
      // F extension, cleared on flush
      id_next.is_fp_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_fp_instruction_direct;
      id_next.is_fp_load = i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_direct;
      id_next.is_fp_store = i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_direct;
      id_next.is_fp_load_double = i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_double_direct;
      id_next.is_fp_store_double = i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_double_direct;
      id_next.is_fp_compute = i_pipeline_ctrl.flush ? 1'b0 :
                                       (is_fp_compute_direct | is_fp_fma_direct);
      id_next.is_pipelined_fp_op = i_pipeline_ctrl.flush ? 1'b0 : is_pipelined_fp_op_direct;
      id_next.is_fp_to_int = i_pipeline_ctrl.flush ? 1'b0 : is_fp_to_int_direct;
      id_next.is_int_to_fp = i_pipeline_ctrl.flush ? 1'b0 : is_int_to_fp_direct;
      // Pre-decoded operand-classification flags, cleared on flush
      id_next.has_int_dest = i_pipeline_ctrl.flush ? 1'b0 : has_int_dest_pre;
      id_next.has_fp_dest = i_pipeline_ctrl.flush ? 1'b0 : has_fp_dest_pre;
      id_next.uses_int_rs1 = i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs1_pre;
      id_next.uses_int_rs2 = i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs2_pre;
      id_next.uses_fp_rs1 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs1_pre;
      id_next.uses_fp_rs2 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs2_pre;
      id_next.uses_fp_rs3 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs3_pre;
      // Registered NOP detect.  After a flush or reset the register holds the
      // NOP pattern, so is_not_nop is 0 there too, which matches NOP semantics.
      // A fault-tagged bundle must dispatch even when its garbage bytes happen
      // to encode a NOP.
      id_next.is_not_nop = i_pipeline_ctrl.flush ? 1'b0 :
          ((instruction != riscv_pkg::NOP) || is_fetch_fault);
    end
    // Datapath payload (immediates, targets, regfile data): not reset, only stalled.
    if (id_advance) begin
      id_next.program_counter = i_from_pd_to_id.program_counter;
      id_next.csr_address = csr_address;
      id_next.csr_imm = csr_imm;
      // Compute link address from registered PD inputs instead of the live IF
      // sideband path.
      id_next.link_address = link_address_precomputed;
      // Pre-computed targets (see branch_target_precompute)
      id_next.branch_target_precomputed = branch_target_precomputed;
      id_next.jal_target_precomputed = jal_target_precomputed;
      id_next.pc_relative_precomputed = pc_relative_precomputed;
      id_next.btb_predicted_target = effective_btb_predicted_target;
      id_next.ras_predicted_target = i_from_pd_to_id.ras_predicted_target;
      id_next.ras_checkpoint_tos = i_from_pd_to_id.ras_checkpoint_tos;
      id_next.ras_checkpoint_valid_count = i_from_pd_to_id.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      id_next.bp_dir_idx = i_from_pd_to_id.bp_dir_idx;
      id_next.ras_predicted_target_nonzero = |i_from_pd_to_id.ras_predicted_target;
      // Expected rs1 values (see branch_target_precompute).
      id_next.ras_expected_rs1 = ras_expected_rs1_precomputed;
      id_next.btb_expected_rs1 = btb_expected_rs1_precomputed;
      id_next.fp_rm = fp_rm_direct;
      id_next.immediate_u_type = immediate_u_type;
      id_next.immediate_s_type = immediate_s_type;
      id_next.immediate_i_type = immediate_i_type;
      id_next.immediate_b_type = immediate_b_type;
      id_next.immediate_j_type = immediate_j_type;
      // Register file read data, with the WB bypass applied
      id_next.source_reg_1_data = source_reg_1_data_bypassed;
      id_next.source_reg_2_data = source_reg_2_data_bypassed;
      // Pre-computed x0 check flags
      id_next.source_reg_1_is_x0 = source_reg_1_is_x0;
      id_next.source_reg_2_is_x0 = source_reg_2_is_x0;
      // F extension: FP register file read data (with WB bypass)
      id_next.fp_source_reg_1_data = fp_source_reg_1_data_bypassed;
      id_next.fp_source_reg_2_data = fp_source_reg_2_data_bypassed;
      id_next.fp_source_reg_3_data = fp_source_reg_3_data_bypassed;
    end
  end
`ifndef SYNTHESIS
  logic o_from_id_to_ex_next_checks_armed = 1'b0;
  riscv_pkg::from_id_to_ex_t o_from_id_to_ex_next_q;
  always_ff @(posedge i_clk) begin
    o_from_id_to_ex_next_q <= o_from_id_to_ex_next;
    o_from_id_to_ex_next_checks_armed <= 1'b1;
    if (o_from_id_to_ex_next_checks_armed && !$isunknown(o_from_id_to_ex_next_q)) begin
      p_next_state_matches_register : assert (o_from_id_to_ex == o_from_id_to_ex_next_q);
    end
  end
`endif

  // ===========================================================================
  // Slot-2: Decoders + FP Detect + WB Bypass + x0 Check + Pipeline Register
  // ===========================================================================
  // Mirror of the slot-1 logic above, driven from i_from_pd_to_id_2. As for
  // slot 1, PD carries the bubble in inject_nop, and the NOP is applied here
  // before the slot-2 decoders (the operand classifier applies it itself).
  // Slot 2 does not get the PD predicted-taken redirect override; its BTB/RAS
  // metadata is whatever PD passed through from IF.

  riscv_pkg::instr_t                      instruction_2;
  riscv_pkg::instr_op_e                   instruction_operation_2;
  riscv_pkg::branch_taken_op_e            branch_operation_2;
  riscv_pkg::store_op_e                   store_operation_2;

  logic                        [XLEN-1:0] immediate_i_type_2;
  logic                        [XLEN-1:0] immediate_s_type_2;
  logic                        [XLEN-1:0] immediate_b_type_2;
  logic                        [XLEN-1:0] immediate_u_type_2;
  logic                        [XLEN-1:0] immediate_j_type_2;

  logic                                   is_load_instruction_2;
  logic                                   is_load_byte_direct_2;
  logic                                   is_load_halfword_direct_2;
  logic                                   is_load_unsigned_direct_2;
  logic                                   is_multiply_direct_2;
  logic                                   is_divide_direct_2;
  logic                                   is_csr_instruction_2;
  logic                        [    11:0] csr_address_2;
  logic                        [     4:0] csr_imm_2;
  logic                                   is_amo_instruction_2;
  logic                                   is_lr_2;
  logic                                   is_sc_2;
  logic                                   is_ecall_2;
  logic                                   is_ebreak_2;
  logic                                   is_mret_2;
  logic                                   is_sret_2;
  logic                                   is_dret_2;
  logic                                   is_wfi_2;
  logic                                   is_jal_direct_2;
  logic                                   is_jalr_direct_2;
  logic                                   is_ras_return_precomputed_2;
  logic                                   is_ras_call_precomputed_2;

  logic                        [XLEN-1:0] branch_target_precomputed_2;
  logic                        [XLEN-1:0] jal_target_precomputed_2;
  logic                        [XLEN-1:0] link_address_precomputed_2;
  logic                        [XLEN-1:0] ras_expected_rs1_precomputed_2;
  logic                        [XLEN-1:0] btb_expected_rs1_precomputed_2;
  logic                                   btb_correct_non_jalr_precomputed_2;

  logic                                   ras_correct_non_jalr_precomputed_2;
  logic                        [XLEN-1:0] pc_relative_precomputed_2;
  assign instruction_2 = i_from_pd_to_id_2.inject_nop ? riscv_pkg::NOP :
                                                        i_from_pd_to_id_2.instruction;
  assign link_address_precomputed_2 =
      i_from_pd_to_id_2.program_counter +
      (i_from_pd_to_id_2.is_compressed ? riscv_pkg::PcIncrementCompressed :
                                         riscv_pkg::PcIncrement32bit);

  logic decoder_illegal_2;

  instr_decoder instr_decoder_inst_2 (
      .i_instr(instruction_2),
      .o_instr_op(instruction_operation_2),
      .o_store_op(store_operation_2),
      .o_branch_taken_op(branch_operation_2),
      .o_illegal(decoder_illegal_2)
  );

  logic is_illegal_instruction_2;
  assign is_illegal_instruction_2 = decoder_illegal_2 | i_from_pd_to_id_2.illegal_instruction;
  logic is_fetch_fault_2;
  assign is_fetch_fault_2 = i_from_pd_to_id_2.fetch_fault;
  logic is_fetch_fault_page_2;
  logic is_fetch_fault_hi_2;
  assign is_fetch_fault_page_2 = i_from_pd_to_id_2.fetch_fault_page;
  assign is_fetch_fault_hi_2   = i_from_pd_to_id_2.fetch_fault_hi;

  immediate_decoder #(
      .XLEN(XLEN)
  ) immediate_decoder_inst_2 (
      .i_instruction(instruction_2),
      .o_immediate_i_type(immediate_i_type_2),
      .o_immediate_s_type(immediate_s_type_2),
      .o_immediate_b_type(immediate_b_type_2),
      .o_immediate_u_type(immediate_u_type_2),
      .o_immediate_j_type(immediate_j_type_2)
  );

  instruction_type_decoder #(
      .XLEN(XLEN)
  ) instruction_type_decoder_inst_2 (
      .i_instruction(instruction_2),
      .i_immediate_i_type(immediate_i_type_2),
      .o_is_load_instruction(is_load_instruction_2),
      .o_is_load_byte(is_load_byte_direct_2),
      .o_is_load_halfword(is_load_halfword_direct_2),
      .o_is_load_unsigned(is_load_unsigned_direct_2),
      .o_is_multiply(is_multiply_direct_2),
      .o_is_divide(is_divide_direct_2),
      .o_is_csr_instruction(is_csr_instruction_2),
      .o_csr_address(csr_address_2),
      .o_csr_imm(csr_imm_2),
      .o_is_amo_instruction(is_amo_instruction_2),
      .o_is_lr(is_lr_2),
      .o_is_sc(is_sc_2),
      .o_is_ecall(is_ecall_2),
      .o_is_ebreak(is_ebreak_2),
      .o_is_mret(is_mret_2),
      .o_is_sret(is_sret_2),
      .o_is_dret(is_dret_2),
      .o_is_wfi(is_wfi_2),
      .o_is_jal(is_jal_direct_2),
      .o_is_jalr(is_jalr_direct_2),
      .o_is_ras_return(is_ras_return_precomputed_2),
      .o_is_ras_call(is_ras_call_precomputed_2)
  );

  branch_target_precompute #(
      .XLEN(XLEN)
  ) branch_target_precompute_inst_2 (
      .i_program_counter(i_from_pd_to_id_2.program_counter),
      .i_immediate_i_type(immediate_i_type_2),
      .i_immediate_b_type(immediate_b_type_2),
      .i_immediate_j_type(immediate_j_type_2),
      .i_ras_predicted_target(i_from_pd_to_id_2.ras_predicted_target),
      .i_btb_predicted_target(i_from_pd_to_id_2.btb_predicted_target),
      .i_immediate_u_type(immediate_u_type_2),
      .i_is_jal(is_jal_direct_2),
      .i_is_fetch_fault(is_fetch_fault_2),
      .i_is_fetch_fault_hi(is_fetch_fault_hi_2),
      .o_branch_target_precomputed(branch_target_precomputed_2),
      .o_jal_target_precomputed(jal_target_precomputed_2),
      .o_pc_relative_precomputed(pc_relative_precomputed_2),
      .o_ras_expected_rs1(ras_expected_rs1_precomputed_2),
      .o_btb_expected_rs1(btb_expected_rs1_precomputed_2),
      .o_btb_correct_non_jalr(btb_correct_non_jalr_precomputed_2),
      .o_ras_correct_non_jalr(ras_correct_non_jalr_precomputed_2)
  );

  // F extension: slot-2 floating-point instruction detection
  logic is_fp_load_direct_2;
  logic is_fp_store_direct_2;
  logic is_fp_load_double_direct_2;
  logic is_fp_store_double_direct_2;
  logic is_fp_compute_direct_2;
  logic is_fp_fma_direct_2;
  logic is_fp_instruction_direct_2;

  assign is_fp_load_direct_2 = (instruction_2.opcode == riscv_pkg::OPC_LOAD_FP) &&
                               ((instruction_2.funct3 == 3'b010) ||
                                (instruction_2.funct3 == 3'b011));
  assign is_fp_store_direct_2 = (instruction_2.opcode == riscv_pkg::OPC_STORE_FP) &&
                                ((instruction_2.funct3 == 3'b010) ||
                                 (instruction_2.funct3 == 3'b011));
  assign is_fp_load_double_direct_2 = (instruction_2.opcode == riscv_pkg::OPC_LOAD_FP) &&
                                      (instruction_2.funct3 == 3'b011);
  assign is_fp_store_double_direct_2 = (instruction_2.opcode == riscv_pkg::OPC_STORE_FP) &&
                                       (instruction_2.funct3 == 3'b011);
  assign is_fp_compute_direct_2 = instruction_2.opcode == riscv_pkg::OPC_OP_FP;
  assign is_fp_fma_direct_2 = (instruction_2.opcode == riscv_pkg::OPC_FMADD) |
                              (instruction_2.opcode == riscv_pkg::OPC_FMSUB) |
                              (instruction_2.opcode == riscv_pkg::OPC_FNMSUB) |
                              (instruction_2.opcode == riscv_pkg::OPC_FNMADD);
  assign is_fp_instruction_direct_2 = is_fp_load_direct_2 | is_fp_store_direct_2 |
                                     is_fp_compute_direct_2 | is_fp_fma_direct_2;

  logic is_fp_to_int_direct_2;
  assign is_fp_to_int_direct_2 = is_fp_compute_direct_2 && (
      (instruction_2.funct7[6:2] == 5'b10100) |
      (instruction_2.funct7[6:2] == 5'b11100 && instruction_2.funct3 == 3'b001) |
      (instruction_2.funct7[6:2] == 5'b11000) |
      (instruction_2.funct7[6:2] == 5'b11100 && instruction_2.funct3 == 3'b000)
      );

  logic is_int_to_fp_direct_2;
  assign is_int_to_fp_direct_2 = is_fp_compute_direct_2 && (
      (instruction_2.funct7[6:2] == 5'b11010) |
      (instruction_2.funct7[6:2] == 5'b11110 && instruction_2.funct3 == 3'b000)
      );

  logic is_pipelined_fp_op_direct_2;
  assign is_pipelined_fp_op_direct_2 = is_fp_fma_direct_2 |
      (is_fp_compute_direct_2 && (
          instruction_2.funct7[6:3] == 4'b0000 ||
      instruction_2.funct7[6:3] == 4'b0001 ||
      instruction_2.funct7[6:2] == 5'b01011
      ));

  logic [2:0] fp_rm_direct_2;
  assign fp_rm_direct_2 = instruction_2.funct3;

  // Slot-2 WB Bypass
  logic wb_bypass_rs1_2;
  logic wb_bypass_rs2_2;
  logic [XLEN-1:0] source_reg_1_data_bypassed_2;
  logic [XLEN-1:0] source_reg_2_data_bypassed_2;

  assign wb_bypass_rs1_2 = i_from_ma_to_wb.regfile_write_enable &&
                           |i_from_ma_to_wb.instruction.dest_reg &&
                           (i_from_ma_to_wb.instruction.dest_reg ==
                            i_from_pd_to_id_2.source_reg_1_early);
  assign wb_bypass_rs2_2 = i_from_ma_to_wb.regfile_write_enable &&
                           |i_from_ma_to_wb.instruction.dest_reg &&
                           (i_from_ma_to_wb.instruction.dest_reg ==
                            i_from_pd_to_id_2.source_reg_2_early);

  assign source_reg_1_data_bypassed_2 = wb_bypass_rs1_2 ? i_from_ma_to_wb.regfile_write_data :
                                                          i_rf_to_id_2.source_reg_1_data;
  assign source_reg_2_data_bypassed_2 = wb_bypass_rs2_2 ? i_from_ma_to_wb.regfile_write_data :
                                                          i_rf_to_id_2.source_reg_2_data;

  logic fp_wb_bypass_rs1_2;
  logic fp_wb_bypass_rs2_2;
  logic fp_wb_bypass_rs3_2;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_1_data_bypassed_2;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_2_data_bypassed_2;
  logic [riscv_pkg::FpWidth-1:0] fp_source_reg_3_data_bypassed_2;

  assign fp_wb_bypass_rs1_2 = i_from_ma_to_wb.fp_regfile_write_enable &&
                              (i_from_ma_to_wb.fp_dest_reg ==
                               i_from_pd_to_id_2.source_reg_1_early);
  assign fp_wb_bypass_rs2_2 = i_from_ma_to_wb.fp_regfile_write_enable &&
                              (i_from_ma_to_wb.fp_dest_reg ==
                               i_from_pd_to_id_2.source_reg_2_early);
  assign fp_wb_bypass_rs3_2 = i_from_ma_to_wb.fp_regfile_write_enable &&
                              (i_from_ma_to_wb.fp_dest_reg ==
                               i_from_pd_to_id_2.fp_source_reg_3_early);

  assign fp_source_reg_1_data_bypassed_2 = fp_wb_bypass_rs1_2 ?
                                           i_from_ma_to_wb.fp_regfile_write_data :
                                           i_fp_rf_to_id_2.fp_source_reg_1_data;
  assign fp_source_reg_2_data_bypassed_2 = fp_wb_bypass_rs2_2 ?
                                           i_from_ma_to_wb.fp_regfile_write_data :
                                           i_fp_rf_to_id_2.fp_source_reg_2_data;
  assign fp_source_reg_3_data_bypassed_2 = fp_wb_bypass_rs3_2 ?
                                           i_from_ma_to_wb.fp_regfile_write_data :
                                           i_fp_rf_to_id_2.fp_source_reg_3_data;

  // Slot-2 x0 check
  logic source_reg_1_is_x0_2;
  logic source_reg_2_is_x0_2;
  assign source_reg_1_is_x0_2 = ~|i_from_pd_to_id_2.source_reg_1_early;
  assign source_reg_2_is_x0_2 = ~|i_from_pd_to_id_2.source_reg_2_early;

  // Slot-2 pre-decoded operand-classification flags (mirror of slot 1).
  logic has_int_dest_pre_2;
  logic has_fp_dest_pre_2;
  logic uses_int_rs1_pre_2;
  logic uses_int_rs2_pre_2;
  logic uses_fp_rs1_pre_2;
  logic uses_fp_rs2_pre_2;
  logic uses_fp_rs3_pre_2;
  logic [2:0] rs_type_pre_2;
  logic is_int_store_pre_2;
  logic is_branch_or_jump_pre_2;
  logic is_fence_pre_2;
  logic is_fence_i_pre_2;
  logic is_sfence_vma_pre_2;
  logic is_csr_imm_pre_2;
  logic has_fp_flags_pre_2;

  instr_operand_classifier operand_classifier_2 (
      .i_instr(i_from_pd_to_id_2.instruction),
      .i_inject_nop(i_from_pd_to_id_2.inject_nop),
      .i_illegal(is_illegal_instruction_2),
      .i_fetch_fault(is_fetch_fault_2),
      .o_has_int_dest(has_int_dest_pre_2),
      .o_has_fp_dest(has_fp_dest_pre_2),
      .o_uses_int_rs1(uses_int_rs1_pre_2),
      .o_uses_int_rs2(uses_int_rs2_pre_2),
      .o_uses_fp_rs1(uses_fp_rs1_pre_2),
      .o_uses_fp_rs2(uses_fp_rs2_pre_2),
      .o_uses_fp_rs3(uses_fp_rs3_pre_2),
      .o_rs_type(rs_type_pre_2),
      .o_is_int_store(is_int_store_pre_2),
      .o_is_branch_or_jump(is_branch_or_jump_pre_2),
      .o_is_fence(is_fence_pre_2),
      .o_is_fence_i(is_fence_i_pre_2),
      .o_is_sfence_vma(is_sfence_vma_pre_2),
      .o_is_csr_imm(is_csr_imm_pre_2),
      .o_has_fp_flags(has_fp_flags_pre_2)
  );


  // Slot-2 Pipeline Register
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      o_from_id_to_ex_2.instruction               <= riscv_pkg::NOP;
      o_from_id_to_ex_2.is_compressed             <= 1'b0;
      o_from_id_to_ex_2.instruction_operation     <= riscv_pkg::ADDI;
      o_from_id_to_ex_2.is_load_instruction       <= 1'b0;
      o_from_id_to_ex_2.is_load_byte              <= 1'b0;
      o_from_id_to_ex_2.is_load_halfword          <= 1'b0;
      o_from_id_to_ex_2.is_load_unsigned          <= 1'b0;
      o_from_id_to_ex_2.is_multiply               <= 1'b0;
      o_from_id_to_ex_2.is_divide                 <= 1'b0;
      o_from_id_to_ex_2.branch_operation          <= riscv_pkg::NULL;
      o_from_id_to_ex_2.store_operation           <= riscv_pkg::STN;
      o_from_id_to_ex_2.rs_type                   <= riscv_pkg::RS_INT;
      o_from_id_to_ex_2.is_int_store              <= 1'b0;
      o_from_id_to_ex_2.is_branch_or_jump         <= 1'b0;
      o_from_id_to_ex_2.is_fence                  <= 1'b0;
      o_from_id_to_ex_2.is_fence_i                <= 1'b0;
      o_from_id_to_ex_2.is_csr_imm                <= 1'b0;
      o_from_id_to_ex_2.has_fp_flags              <= 1'b0;
      o_from_id_to_ex_2.is_jump_and_link          <= 1'b0;
      o_from_id_to_ex_2.is_jump_and_link_register <= 1'b0;
      o_from_id_to_ex_2.is_csr_instruction        <= 1'b0;
      o_from_id_to_ex_2.is_amo_instruction        <= 1'b0;
      o_from_id_to_ex_2.is_lr                     <= 1'b0;
      o_from_id_to_ex_2.is_sc                     <= 1'b0;
      o_from_id_to_ex_2.is_mret                   <= 1'b0;
      o_from_id_to_ex_2.is_sret                   <= 1'b0;
      o_from_id_to_ex_2.is_dret                   <= 1'b0;
      o_from_id_to_ex_2.is_sfence_vma             <= 1'b0;
      o_from_id_to_ex_2.is_wfi                    <= 1'b0;
      o_from_id_to_ex_2.is_ecall                  <= 1'b0;
      o_from_id_to_ex_2.is_ebreak                 <= 1'b0;
      o_from_id_to_ex_2.is_illegal_instruction    <= 1'b0;
      o_from_id_to_ex_2.is_fetch_fault            <= 1'b0;
      o_from_id_to_ex_2.is_fetch_fault_page       <= 1'b0;
      o_from_id_to_ex_2.is_fetch_fault_hi         <= 1'b0;
      o_from_id_to_ex_2.btb_hit                   <= 1'b0;
      o_from_id_to_ex_2.btb_predicted_taken       <= 1'b0;
      o_from_id_to_ex_2.ras_predicted             <= 1'b0;
      o_from_id_to_ex_2.is_ras_return             <= 1'b0;
      o_from_id_to_ex_2.is_ras_call               <= 1'b0;
      o_from_id_to_ex_2.btb_correct_non_jalr      <= 1'b0;
      o_from_id_to_ex_2.ras_correct_non_jalr      <= 1'b0;
      o_from_id_to_ex_2.is_fp_instruction         <= 1'b0;
      o_from_id_to_ex_2.is_fp_load                <= 1'b0;
      o_from_id_to_ex_2.is_fp_store               <= 1'b0;
      o_from_id_to_ex_2.is_fp_load_double         <= 1'b0;
      o_from_id_to_ex_2.is_fp_store_double        <= 1'b0;
      o_from_id_to_ex_2.is_fp_compute             <= 1'b0;
      o_from_id_to_ex_2.is_pipelined_fp_op        <= 1'b0;
      o_from_id_to_ex_2.is_fp_to_int              <= 1'b0;
      o_from_id_to_ex_2.is_int_to_fp              <= 1'b0;
      // Pre-decoded operand-classification flags
      o_from_id_to_ex_2.has_int_dest              <= 1'b0;
      o_from_id_to_ex_2.has_fp_dest               <= 1'b0;
      o_from_id_to_ex_2.uses_int_rs1              <= 1'b0;
      o_from_id_to_ex_2.uses_int_rs2              <= 1'b0;
      o_from_id_to_ex_2.uses_fp_rs1               <= 1'b0;
      o_from_id_to_ex_2.uses_fp_rs2               <= 1'b0;
      o_from_id_to_ex_2.uses_fp_rs3               <= 1'b0;
      o_from_id_to_ex_2.is_not_nop                <= 1'b0;
    end else if (id_advance) begin
      o_from_id_to_ex_2.instruction <= i_pipeline_ctrl.flush ? riscv_pkg::NOP : instruction_2;
      o_from_id_to_ex_2.is_compressed <= i_pipeline_ctrl.flush ? 1'b0 :
                                                                   i_from_pd_to_id_2.is_compressed;
      o_from_id_to_ex_2.instruction_operation <= i_pipeline_ctrl.flush ? riscv_pkg::ADDI :
                                                                         instruction_operation_2;
      o_from_id_to_ex_2.is_load_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_load_instruction_2;
      o_from_id_to_ex_2.is_load_byte <= i_pipeline_ctrl.flush ? 1'b0 : is_load_byte_direct_2;
      o_from_id_to_ex_2.is_load_halfword <= i_pipeline_ctrl.flush ? 1'b0 :
                                            is_load_halfword_direct_2;
      o_from_id_to_ex_2.is_load_unsigned <= i_pipeline_ctrl.flush ? 1'b0 :
                                            is_load_unsigned_direct_2;
      o_from_id_to_ex_2.is_multiply <= i_pipeline_ctrl.flush ? 1'b0 : is_multiply_direct_2;
      o_from_id_to_ex_2.is_divide <= i_pipeline_ctrl.flush ? 1'b0 : is_divide_direct_2;
      o_from_id_to_ex_2.branch_operation <= i_pipeline_ctrl.flush ? riscv_pkg::NULL :
                                                                    branch_operation_2;
      o_from_id_to_ex_2.store_operation <= i_pipeline_ctrl.flush ? riscv_pkg::STN :
                                                                   store_operation_2;
      o_from_id_to_ex_2.rs_type <= i_pipeline_ctrl.flush ? riscv_pkg::RS_INT : rs_type_pre_2;
      o_from_id_to_ex_2.is_int_store <= i_pipeline_ctrl.flush ? 1'b0 : is_int_store_pre_2;
      o_from_id_to_ex_2.is_branch_or_jump <= i_pipeline_ctrl.flush ? 1'b0 : is_branch_or_jump_pre_2;
      o_from_id_to_ex_2.is_fence <= i_pipeline_ctrl.flush ? 1'b0 : is_fence_pre_2;
      o_from_id_to_ex_2.is_fence_i <= i_pipeline_ctrl.flush ? 1'b0 : is_fence_i_pre_2;
      o_from_id_to_ex_2.is_csr_imm <= i_pipeline_ctrl.flush ? 1'b0 : is_csr_imm_pre_2;
      o_from_id_to_ex_2.has_fp_flags <= i_pipeline_ctrl.flush ? 1'b0 : has_fp_flags_pre_2;
      o_from_id_to_ex_2.is_jump_and_link <= i_pipeline_ctrl.flush ? 1'b0 : is_jal_direct_2;
      o_from_id_to_ex_2.is_jump_and_link_register <= i_pipeline_ctrl.flush ? 1'b0 :
                                                     is_jalr_direct_2;
      o_from_id_to_ex_2.is_csr_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_csr_instruction_2;
      o_from_id_to_ex_2.is_amo_instruction <= i_pipeline_ctrl.flush ? 1'b0 : is_amo_instruction_2;
      o_from_id_to_ex_2.is_lr <= i_pipeline_ctrl.flush ? 1'b0 : is_lr_2;
      o_from_id_to_ex_2.is_sc <= i_pipeline_ctrl.flush ? 1'b0 : is_sc_2;
      o_from_id_to_ex_2.is_mret <= i_pipeline_ctrl.flush ? 1'b0 :
                                   (is_mret_2 || is_sret_2 || is_dret_2);
      o_from_id_to_ex_2.is_sret <= i_pipeline_ctrl.flush ? 1'b0 : is_sret_2;
      o_from_id_to_ex_2.is_dret <= i_pipeline_ctrl.flush ? 1'b0 : is_dret_2;
      o_from_id_to_ex_2.is_sfence_vma <= i_pipeline_ctrl.flush ? 1'b0 : is_sfence_vma_pre_2;
      o_from_id_to_ex_2.is_wfi <= i_pipeline_ctrl.flush ? 1'b0 : is_wfi_2;
      o_from_id_to_ex_2.is_ecall <= i_pipeline_ctrl.flush ? 1'b0 : is_ecall_2;
      o_from_id_to_ex_2.is_ebreak <= i_pipeline_ctrl.flush ? 1'b0 : is_ebreak_2;
      o_from_id_to_ex_2.is_illegal_instruction <= i_pipeline_ctrl.flush ? 1'b0 :
                                                  is_illegal_instruction_2;
      o_from_id_to_ex_2.is_fetch_fault <= i_pipeline_ctrl.flush ? 1'b0 : is_fetch_fault_2;
      o_from_id_to_ex_2.is_fetch_fault_page <= is_fetch_fault_page_2;
      o_from_id_to_ex_2.is_fetch_fault_hi <= is_fetch_fault_hi_2;
      o_from_id_to_ex_2.btb_hit <= i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id_2.btb_hit;
      o_from_id_to_ex_2.btb_predicted_taken <= i_pipeline_ctrl.flush ? 1'b0 :
                                               i_from_pd_to_id_2.btb_predicted_taken;
      o_from_id_to_ex_2.ras_predicted <= i_pipeline_ctrl.flush ? 1'b0 :
                                         i_from_pd_to_id_2.ras_predicted;
      o_from_id_to_ex_2.is_ras_return <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_return_precomputed_2;
      o_from_id_to_ex_2.is_ras_call <= i_pipeline_ctrl.flush ? 1'b0 : is_ras_call_precomputed_2;
      o_from_id_to_ex_2.btb_correct_non_jalr <= i_pipeline_ctrl.flush ? 1'b0 :
                                                btb_correct_non_jalr_precomputed_2;
      o_from_id_to_ex_2.ras_correct_non_jalr <= i_pipeline_ctrl.flush ? 1'b0 :
                                                ras_correct_non_jalr_precomputed_2;
      o_from_id_to_ex_2.is_fp_instruction <= i_pipeline_ctrl.flush ? 1'b0 :
                                             is_fp_instruction_direct_2;
      o_from_id_to_ex_2.is_fp_load <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_direct_2;
      o_from_id_to_ex_2.is_fp_store <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_direct_2;
      o_from_id_to_ex_2.is_fp_load_double <= i_pipeline_ctrl.flush ? 1'b0 :
                                             is_fp_load_double_direct_2;
      o_from_id_to_ex_2.is_fp_store_double <= i_pipeline_ctrl.flush ? 1'b0 :
                                              is_fp_store_double_direct_2;
      o_from_id_to_ex_2.is_fp_compute <= i_pipeline_ctrl.flush ? 1'b0 :
                                         (is_fp_compute_direct_2 | is_fp_fma_direct_2);
      o_from_id_to_ex_2.is_pipelined_fp_op <= i_pipeline_ctrl.flush ? 1'b0 :
                                              is_pipelined_fp_op_direct_2;
      o_from_id_to_ex_2.is_fp_to_int <= i_pipeline_ctrl.flush ? 1'b0 : is_fp_to_int_direct_2;
      o_from_id_to_ex_2.is_int_to_fp <= i_pipeline_ctrl.flush ? 1'b0 : is_int_to_fp_direct_2;
      // Pre-decoded operand-classification flags, cleared on flush
      o_from_id_to_ex_2.has_int_dest <= i_pipeline_ctrl.flush ? 1'b0 : has_int_dest_pre_2;
      o_from_id_to_ex_2.has_fp_dest <= i_pipeline_ctrl.flush ? 1'b0 : has_fp_dest_pre_2;
      o_from_id_to_ex_2.uses_int_rs1 <= i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs1_pre_2;
      o_from_id_to_ex_2.uses_int_rs2 <= i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs2_pre_2;
      o_from_id_to_ex_2.uses_fp_rs1 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs1_pre_2;
      o_from_id_to_ex_2.uses_fp_rs2 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs2_pre_2;
      o_from_id_to_ex_2.uses_fp_rs3 <= i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs3_pre_2;
      // As for slot 1, a fault-tagged slot dispatches even when its garbage
      // bytes encode a NOP.
      o_from_id_to_ex_2.is_not_nop <= i_pipeline_ctrl.flush ? 1'b0 :
          ((instruction_2 != riscv_pkg::NOP) || is_fetch_fault_2);
    end
    if (id_advance) begin
      o_from_id_to_ex_2.program_counter <= i_from_pd_to_id_2.program_counter;
      o_from_id_to_ex_2.csr_address <= csr_address_2;
      o_from_id_to_ex_2.csr_imm <= csr_imm_2;
      o_from_id_to_ex_2.link_address <= link_address_precomputed_2;
      o_from_id_to_ex_2.branch_target_precomputed <= branch_target_precomputed_2;
      o_from_id_to_ex_2.jal_target_precomputed <= jal_target_precomputed_2;
      o_from_id_to_ex_2.pc_relative_precomputed <= pc_relative_precomputed_2;
      o_from_id_to_ex_2.btb_predicted_target <= i_from_pd_to_id_2.btb_predicted_target;
      o_from_id_to_ex_2.ras_predicted_target <= i_from_pd_to_id_2.ras_predicted_target;
      o_from_id_to_ex_2.ras_checkpoint_tos <= i_from_pd_to_id_2.ras_checkpoint_tos;
      o_from_id_to_ex_2.ras_checkpoint_valid_count <= i_from_pd_to_id_2.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      o_from_id_to_ex_2.bp_dir_idx <= i_from_pd_to_id_2.bp_dir_idx;
      o_from_id_to_ex_2.ras_predicted_target_nonzero <= |i_from_pd_to_id_2.ras_predicted_target;
      o_from_id_to_ex_2.ras_expected_rs1 <= ras_expected_rs1_precomputed_2;
      o_from_id_to_ex_2.btb_expected_rs1 <= btb_expected_rs1_precomputed_2;
      o_from_id_to_ex_2.fp_rm <= fp_rm_direct_2;
      o_from_id_to_ex_2.immediate_u_type <= immediate_u_type_2;
      o_from_id_to_ex_2.immediate_s_type <= immediate_s_type_2;
      o_from_id_to_ex_2.immediate_i_type <= immediate_i_type_2;
      o_from_id_to_ex_2.immediate_b_type <= immediate_b_type_2;
      o_from_id_to_ex_2.immediate_j_type <= immediate_j_type_2;
      o_from_id_to_ex_2.source_reg_1_data <= source_reg_1_data_bypassed_2;
      o_from_id_to_ex_2.source_reg_2_data <= source_reg_2_data_bypassed_2;
      o_from_id_to_ex_2.source_reg_1_is_x0 <= source_reg_1_is_x0_2;
      o_from_id_to_ex_2.source_reg_2_is_x0 <= source_reg_2_is_x0_2;
      o_from_id_to_ex_2.fp_source_reg_1_data <= fp_source_reg_1_data_bypassed_2;
      o_from_id_to_ex_2.fp_source_reg_2_data <= fp_source_reg_2_data_bypassed_2;
      o_from_id_to_ex_2.fp_source_reg_3_data <= fp_source_reg_3_data_bypassed_2;
    end
  end

  // Next-edge value of o_from_id_to_ex_2: the always_ff update above,
  // repeated with a hold default. Change both together; the assertion below
  // checks that the register matches.
  riscv_pkg::from_id_to_ex_t id_next_2;
  assign o_from_id_to_ex_next_2 = id_next_2;
  always_comb begin
    id_next_2 = o_from_id_to_ex_2;
    if (i_pipeline_ctrl.reset) begin
      id_next_2.instruction = riscv_pkg::NOP;
      id_next_2.is_compressed = 1'b0;
      id_next_2.instruction_operation = riscv_pkg::ADDI;
      id_next_2.is_load_instruction = 1'b0;
      id_next_2.is_load_byte = 1'b0;
      id_next_2.is_load_halfword = 1'b0;
      id_next_2.is_load_unsigned = 1'b0;
      id_next_2.is_multiply = 1'b0;
      id_next_2.is_divide = 1'b0;
      id_next_2.branch_operation = riscv_pkg::NULL;
      id_next_2.store_operation = riscv_pkg::STN;
      id_next_2.rs_type = riscv_pkg::RS_INT;
      id_next_2.is_int_store = 1'b0;
      id_next_2.is_branch_or_jump = 1'b0;
      id_next_2.is_fence = 1'b0;
      id_next_2.is_fence_i = 1'b0;
      id_next_2.is_csr_imm = 1'b0;
      id_next_2.has_fp_flags = 1'b0;
      id_next_2.is_jump_and_link = 1'b0;
      id_next_2.is_jump_and_link_register = 1'b0;
      id_next_2.is_csr_instruction = 1'b0;
      id_next_2.is_amo_instruction = 1'b0;
      id_next_2.is_lr = 1'b0;
      id_next_2.is_sc = 1'b0;
      id_next_2.is_mret = 1'b0;
      id_next_2.is_sret = 1'b0;
      id_next_2.is_dret = 1'b0;
      id_next_2.is_sfence_vma = 1'b0;
      id_next_2.is_wfi = 1'b0;
      id_next_2.is_ecall = 1'b0;
      id_next_2.is_ebreak = 1'b0;
      id_next_2.is_illegal_instruction = 1'b0;
      id_next_2.is_fetch_fault = 1'b0;
      id_next_2.is_fetch_fault_page = 1'b0;
      id_next_2.is_fetch_fault_hi = 1'b0;
      id_next_2.btb_hit = 1'b0;
      id_next_2.btb_predicted_taken = 1'b0;
      id_next_2.ras_predicted = 1'b0;
      id_next_2.is_ras_return = 1'b0;
      id_next_2.is_ras_call = 1'b0;
      id_next_2.btb_correct_non_jalr = 1'b0;
      id_next_2.ras_correct_non_jalr = 1'b0;
      id_next_2.is_fp_instruction = 1'b0;
      id_next_2.is_fp_load = 1'b0;
      id_next_2.is_fp_store = 1'b0;
      id_next_2.is_fp_load_double = 1'b0;
      id_next_2.is_fp_store_double = 1'b0;
      id_next_2.is_fp_compute = 1'b0;
      id_next_2.is_pipelined_fp_op = 1'b0;
      id_next_2.is_fp_to_int = 1'b0;
      id_next_2.is_int_to_fp = 1'b0;
      // Pre-decoded operand-classification flags
      id_next_2.has_int_dest = 1'b0;
      id_next_2.has_fp_dest = 1'b0;
      id_next_2.uses_int_rs1 = 1'b0;
      id_next_2.uses_int_rs2 = 1'b0;
      id_next_2.uses_fp_rs1 = 1'b0;
      id_next_2.uses_fp_rs2 = 1'b0;
      id_next_2.uses_fp_rs3 = 1'b0;
      id_next_2.is_not_nop = 1'b0;
    end else if (id_advance) begin
      id_next_2.instruction = i_pipeline_ctrl.flush ? riscv_pkg::NOP : instruction_2;
      id_next_2.is_compressed = i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id_2.is_compressed;
      id_next_2.instruction_operation = i_pipeline_ctrl.flush ? riscv_pkg::ADDI :
                                                                         instruction_operation_2;
      id_next_2.is_load_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_load_instruction_2;
      id_next_2.is_load_byte = i_pipeline_ctrl.flush ? 1'b0 : is_load_byte_direct_2;
      id_next_2.is_load_halfword = i_pipeline_ctrl.flush ? 1'b0 : is_load_halfword_direct_2;
      id_next_2.is_load_unsigned = i_pipeline_ctrl.flush ? 1'b0 : is_load_unsigned_direct_2;
      id_next_2.is_multiply = i_pipeline_ctrl.flush ? 1'b0 : is_multiply_direct_2;
      id_next_2.is_divide = i_pipeline_ctrl.flush ? 1'b0 : is_divide_direct_2;
      id_next_2.branch_operation = i_pipeline_ctrl.flush ? riscv_pkg::NULL : branch_operation_2;
      id_next_2.store_operation = i_pipeline_ctrl.flush ? riscv_pkg::STN : store_operation_2;
      id_next_2.rs_type = i_pipeline_ctrl.flush ? riscv_pkg::RS_INT : rs_type_pre_2;
      id_next_2.is_int_store = i_pipeline_ctrl.flush ? 1'b0 : is_int_store_pre_2;
      id_next_2.is_branch_or_jump = i_pipeline_ctrl.flush ? 1'b0 : is_branch_or_jump_pre_2;
      id_next_2.is_fence = i_pipeline_ctrl.flush ? 1'b0 : is_fence_pre_2;
      id_next_2.is_fence_i = i_pipeline_ctrl.flush ? 1'b0 : is_fence_i_pre_2;
      id_next_2.is_csr_imm = i_pipeline_ctrl.flush ? 1'b0 : is_csr_imm_pre_2;
      id_next_2.has_fp_flags = i_pipeline_ctrl.flush ? 1'b0 : has_fp_flags_pre_2;
      id_next_2.is_jump_and_link = i_pipeline_ctrl.flush ? 1'b0 : is_jal_direct_2;
      id_next_2.is_jump_and_link_register = i_pipeline_ctrl.flush ? 1'b0 : is_jalr_direct_2;
      id_next_2.is_csr_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_csr_instruction_2;
      id_next_2.is_amo_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_amo_instruction_2;
      id_next_2.is_lr = i_pipeline_ctrl.flush ? 1'b0 : is_lr_2;
      id_next_2.is_sc = i_pipeline_ctrl.flush ? 1'b0 : is_sc_2;
      id_next_2.is_mret = i_pipeline_ctrl.flush ? 1'b0 : (is_mret_2 || is_sret_2 || is_dret_2);
      id_next_2.is_sret = i_pipeline_ctrl.flush ? 1'b0 : is_sret_2;
      id_next_2.is_dret = i_pipeline_ctrl.flush ? 1'b0 : is_dret_2;
      id_next_2.is_sfence_vma = i_pipeline_ctrl.flush ? 1'b0 : is_sfence_vma_pre_2;
      id_next_2.is_wfi = i_pipeline_ctrl.flush ? 1'b0 : is_wfi_2;
      id_next_2.is_ecall = i_pipeline_ctrl.flush ? 1'b0 : is_ecall_2;
      id_next_2.is_ebreak = i_pipeline_ctrl.flush ? 1'b0 : is_ebreak_2;
      id_next_2.is_illegal_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_illegal_instruction_2;
      id_next_2.is_fetch_fault = i_pipeline_ctrl.flush ? 1'b0 : is_fetch_fault_2;
      id_next_2.is_fetch_fault_page = is_fetch_fault_page_2;
      id_next_2.is_fetch_fault_hi = is_fetch_fault_hi_2;
      id_next_2.btb_hit = i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id_2.btb_hit;
      id_next_2.btb_predicted_taken = i_pipeline_ctrl.flush ? 1'b0 :
                                               i_from_pd_to_id_2.btb_predicted_taken;
      id_next_2.ras_predicted = i_pipeline_ctrl.flush ? 1'b0 : i_from_pd_to_id_2.ras_predicted;
      id_next_2.is_ras_return = i_pipeline_ctrl.flush ? 1'b0 : is_ras_return_precomputed_2;
      id_next_2.is_ras_call = i_pipeline_ctrl.flush ? 1'b0 : is_ras_call_precomputed_2;
      id_next_2.btb_correct_non_jalr = i_pipeline_ctrl.flush ? 1'b0 :
                                                btb_correct_non_jalr_precomputed_2;
      id_next_2.ras_correct_non_jalr = i_pipeline_ctrl.flush ? 1'b0 :
                                                ras_correct_non_jalr_precomputed_2;
      id_next_2.is_fp_instruction = i_pipeline_ctrl.flush ? 1'b0 : is_fp_instruction_direct_2;
      id_next_2.is_fp_load = i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_direct_2;
      id_next_2.is_fp_store = i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_direct_2;
      id_next_2.is_fp_load_double = i_pipeline_ctrl.flush ? 1'b0 : is_fp_load_double_direct_2;
      id_next_2.is_fp_store_double = i_pipeline_ctrl.flush ? 1'b0 : is_fp_store_double_direct_2;
      id_next_2.is_fp_compute = i_pipeline_ctrl.flush ? 1'b0 :
                                         (is_fp_compute_direct_2 | is_fp_fma_direct_2);
      id_next_2.is_pipelined_fp_op = i_pipeline_ctrl.flush ? 1'b0 : is_pipelined_fp_op_direct_2;
      id_next_2.is_fp_to_int = i_pipeline_ctrl.flush ? 1'b0 : is_fp_to_int_direct_2;
      id_next_2.is_int_to_fp = i_pipeline_ctrl.flush ? 1'b0 : is_int_to_fp_direct_2;
      // Pre-decoded operand-classification flags, cleared on flush
      id_next_2.has_int_dest = i_pipeline_ctrl.flush ? 1'b0 : has_int_dest_pre_2;
      id_next_2.has_fp_dest = i_pipeline_ctrl.flush ? 1'b0 : has_fp_dest_pre_2;
      id_next_2.uses_int_rs1 = i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs1_pre_2;
      id_next_2.uses_int_rs2 = i_pipeline_ctrl.flush ? 1'b0 : uses_int_rs2_pre_2;
      id_next_2.uses_fp_rs1 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs1_pre_2;
      id_next_2.uses_fp_rs2 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs2_pre_2;
      id_next_2.uses_fp_rs3 = i_pipeline_ctrl.flush ? 1'b0 : uses_fp_rs3_pre_2;
      id_next_2.is_not_nop = i_pipeline_ctrl.flush ? 1'b0 :
          ((instruction_2 != riscv_pkg::NOP) || is_fetch_fault_2);
    end
    if (id_advance) begin
      id_next_2.program_counter = i_from_pd_to_id_2.program_counter;
      id_next_2.csr_address = csr_address_2;
      id_next_2.csr_imm = csr_imm_2;
      id_next_2.link_address = link_address_precomputed_2;
      id_next_2.branch_target_precomputed = branch_target_precomputed_2;
      id_next_2.jal_target_precomputed = jal_target_precomputed_2;
      id_next_2.pc_relative_precomputed = pc_relative_precomputed_2;
      id_next_2.btb_predicted_target = i_from_pd_to_id_2.btb_predicted_target;
      id_next_2.ras_predicted_target = i_from_pd_to_id_2.ras_predicted_target;
      id_next_2.ras_checkpoint_tos = i_from_pd_to_id_2.ras_checkpoint_tos;
      id_next_2.ras_checkpoint_valid_count = i_from_pd_to_id_2.ras_checkpoint_valid_count;
      // Carry the predict-time bimodal index through to commit.
      id_next_2.bp_dir_idx = i_from_pd_to_id_2.bp_dir_idx;
      id_next_2.ras_predicted_target_nonzero = |i_from_pd_to_id_2.ras_predicted_target;
      id_next_2.ras_expected_rs1 = ras_expected_rs1_precomputed_2;
      id_next_2.btb_expected_rs1 = btb_expected_rs1_precomputed_2;
      id_next_2.fp_rm = fp_rm_direct_2;
      id_next_2.immediate_u_type = immediate_u_type_2;
      id_next_2.immediate_s_type = immediate_s_type_2;
      id_next_2.immediate_i_type = immediate_i_type_2;
      id_next_2.immediate_b_type = immediate_b_type_2;
      id_next_2.immediate_j_type = immediate_j_type_2;
      id_next_2.source_reg_1_data = source_reg_1_data_bypassed_2;
      id_next_2.source_reg_2_data = source_reg_2_data_bypassed_2;
      id_next_2.source_reg_1_is_x0 = source_reg_1_is_x0_2;
      id_next_2.source_reg_2_is_x0 = source_reg_2_is_x0_2;
      id_next_2.fp_source_reg_1_data = fp_source_reg_1_data_bypassed_2;
      id_next_2.fp_source_reg_2_data = fp_source_reg_2_data_bypassed_2;
      id_next_2.fp_source_reg_3_data = fp_source_reg_3_data_bypassed_2;
    end
  end
`ifndef SYNTHESIS
  logic o_from_id_to_ex_next_2_checks_armed = 1'b0;
  riscv_pkg::from_id_to_ex_t o_from_id_to_ex_next_2_q;
  always_ff @(posedge i_clk) begin
    o_from_id_to_ex_next_2_q <= o_from_id_to_ex_next_2;
    o_from_id_to_ex_next_2_checks_armed <= 1'b1;
    if (o_from_id_to_ex_next_2_checks_armed && !$isunknown(o_from_id_to_ex_next_2_q)) begin
      p_slot2_next_state_matches_register : assert (o_from_id_to_ex_2 == o_from_id_to_ex_next_2_q);
    end
  end
`endif

endmodule : id_stage
