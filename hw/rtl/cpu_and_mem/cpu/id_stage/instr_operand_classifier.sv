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

// Classify dispatch operands directly from instruction fields, in parallel
// with instr_decoder, so the serial instruction -> operation enum ->
// operand-class decode stays off the ID D path. The decoder still decides
// legality: at the output, i_inject_nop selects the NOP's class, and i_illegal
// or i_fetch_fault then selects the neutral class. i_instr is PD's instruction
// before the NOP is applied; i_illegal is instr_decoder's flag for the
// instruction ID decodes (the NOP when i_inject_nop is set) ORed with PD's
// illegal flag and ID's mstatus.FS=Off check.
module instr_operand_classifier (
    input riscv_pkg::instr_t i_instr,
    input logic i_inject_nop,
    input logic i_illegal,
    input logic i_fetch_fault,
    output logic o_has_int_dest,
    output logic o_has_fp_dest,
    output logic o_uses_int_rs1,
    output logic o_uses_int_rs2,
    output logic o_uses_fp_rs1,
    output logic o_uses_fp_rs2,
    output logic o_uses_fp_rs3,
    output logic [2:0] o_rs_type,
    output logic o_is_int_store,
    output logic o_is_branch_or_jump,
    output logic o_is_fence,
    output logic o_is_fence_i,
    output logic o_is_sfence_vma,
    output logic o_is_csr_imm,
    output logic o_has_fp_flags
);
  typedef struct packed {
    logic has_int_dest, has_fp_dest;
    logic uses_int_rs1, uses_int_rs2, uses_fp_rs1, uses_fp_rs2, uses_fp_rs3;
    logic [2:0] rs_type;
    logic is_int_store, is_branch_or_jump, is_fence, is_fence_i;
    logic is_sfence_vma, is_csr_imm, has_fp_flags;
  } operand_class_t;

  operand_class_t raw_class, selected_class;
  logic fp_int_input, fp_int_output, fp_two_sources;
  assign fp_int_input = (i_instr.funct7[6:1] == 6'b110100) || (i_instr.funct7[6:1] == 6'b111100);
  assign fp_int_output = (i_instr.funct7[6:1] == 6'b110000) ||
      (i_instr.funct7[6:1] == 6'b111000) || (i_instr.funct7[6:1] == 6'b101000);
  assign fp_two_sources = (i_instr.funct7[6:1] == 6'b000000) ||
      (i_instr.funct7[6:1] == 6'b000010) || (i_instr.funct7[6:1] == 6'b000100) ||
      (i_instr.funct7[6:1] == 6'b000110) || (i_instr.funct7[6:1] == 6'b001000) ||
      (i_instr.funct7[6:1] == 6'b001010) || (i_instr.funct7[6:1] == 6'b101000);

  always_comb begin
    raw_class = '0;
    raw_class.rs_type = riscv_pkg::RS_INT;
    case (i_instr.opcode)
      riscv_pkg::OPC_OP, riscv_pkg::OPC_OP_32: begin
        raw_class.has_int_dest = 1'b1;
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.uses_int_rs2 = 1'b1;
        raw_class.rs_type = (i_instr.funct7 == 7'b0000001) ? riscv_pkg::RS_MUL : riscv_pkg::RS_INT;
      end
      riscv_pkg::OPC_OP_IMM, riscv_pkg::OPC_OP_IMM_32: begin
        raw_class.has_int_dest = 1'b1;
        raw_class.uses_int_rs1 = 1'b1;
      end
      riscv_pkg::OPC_LUI, riscv_pkg::OPC_AUIPC: raw_class.has_int_dest = 1'b1;
      riscv_pkg::OPC_JAL: begin
        raw_class.has_int_dest = 1'b1;
        raw_class.is_branch_or_jump = 1'b1;
        raw_class.rs_type = riscv_pkg::RS_NONE;
      end
      riscv_pkg::OPC_JALR: begin
        raw_class.has_int_dest = 1'b1;
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.is_branch_or_jump = 1'b1;
      end
      riscv_pkg::OPC_BRANCH: begin
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.uses_int_rs2 = 1'b1;
        raw_class.is_branch_or_jump = 1'b1;
      end
      riscv_pkg::OPC_LOAD, riscv_pkg::OPC_LOAD_FP: begin
        raw_class.has_int_dest = i_instr.opcode == riscv_pkg::OPC_LOAD;
        raw_class.has_fp_dest = i_instr.opcode == riscv_pkg::OPC_LOAD_FP;
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.rs_type = riscv_pkg::RS_MEM;
      end
      riscv_pkg::OPC_STORE, riscv_pkg::OPC_STORE_FP: begin
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.uses_int_rs2 = i_instr.opcode == riscv_pkg::OPC_STORE;
        raw_class.uses_fp_rs2 = i_instr.opcode == riscv_pkg::OPC_STORE_FP;
        raw_class.is_int_store = i_instr.opcode == riscv_pkg::OPC_STORE;
        raw_class.rs_type = riscv_pkg::RS_MEM;
      end
      riscv_pkg::OPC_AMO: begin
        raw_class.has_int_dest = 1'b1;
        raw_class.uses_int_rs1 = 1'b1;
        raw_class.uses_int_rs2 = i_instr.funct7[6:2] != 5'b00010;  // LR has no rs2.
        raw_class.rs_type = riscv_pkg::RS_MEM;
      end
      riscv_pkg::OPC_FMADD, riscv_pkg::OPC_FMSUB,
      riscv_pkg::OPC_FNMSUB, riscv_pkg::OPC_FNMADD: begin
        raw_class.has_fp_dest = 1'b1;
        raw_class.uses_fp_rs1 = 1'b1;
        raw_class.uses_fp_rs2 = 1'b1;
        raw_class.uses_fp_rs3 = 1'b1;
        raw_class.has_fp_flags = 1'b1;
        raw_class.rs_type = riscv_pkg::RS_FMUL;
      end
      riscv_pkg::OPC_OP_FP: begin
        raw_class.has_int_dest = fp_int_output;
        raw_class.has_fp_dest  = !fp_int_output;
        raw_class.uses_int_rs1 = fp_int_input;
        raw_class.uses_fp_rs1  = !fp_int_input;
        raw_class.uses_fp_rs2  = fp_two_sources;
        raw_class.has_fp_flags = 1'b1;
        case (i_instr.funct7[6:1])
          6'b000100: raw_class.rs_type = riscv_pkg::RS_FMUL;
          6'b000110, 6'b010110: raw_class.rs_type = riscv_pkg::RS_FDIV;
          default: raw_class.rs_type = riscv_pkg::RS_FP;
        endcase
      end
      riscv_pkg::OPC_MISC_MEM: begin
        // PAUSE (exactly 0x0100000F, matching instr_decoder's PAUSE arm) is a
        // no-operand INT_RS op that completes like a NOP; it waits on nothing
        // and, unlike FENCE, does not drain committed stores.
        if (i_instr.funct3 == 3'b000 && i_instr.funct7 == 7'b0000000 &&
            i_instr.source_reg_2 == 5'b10000 && i_instr.source_reg_1 == '0 &&
            i_instr.dest_reg == '0)
          raw_class.rs_type = riscv_pkg::RS_INT;
        else begin
          raw_class.rs_type = riscv_pkg::RS_MEM;
          raw_class.is_fence = i_instr.funct3 == 3'b000;
          raw_class.is_fence_i = i_instr.funct3 == 3'b001;
        end
      end
      riscv_pkg::OPC_CSR: begin
        if (i_instr.funct3 != 3'b000) begin
          raw_class.has_int_dest = 1'b1;
          raw_class.uses_int_rs1 = !i_instr.funct3[2];
          raw_class.is_csr_imm   = i_instr.funct3[2];
        end else if (i_instr.funct7 == 7'b0001001) begin
          raw_class.rs_type = riscv_pkg::RS_MEM;
          raw_class.is_fence_i = 1'b1;
          raw_class.is_sfence_vma = 1'b1;
        end else if ({i_instr.funct7, i_instr.source_reg_2} != 12'h000 &&
                     {i_instr.funct7, i_instr.source_reg_2} != 12'h001) begin
          raw_class.rs_type = riscv_pkg::RS_NONE;  // Legal xRET / WFI.
        end
      end
      default: ;  // Illegal opcode: i_illegal selects the neutral class.
    endcase

    selected_class = raw_class;
    if (i_inject_nop) begin
      selected_class = '0;
      selected_class.rs_type = riscv_pkg::RS_INT;
      selected_class.has_int_dest = 1'b1;
      selected_class.uses_int_rs1 = 1'b1;
    end
    // An illegal instruction or a fetch fault reads no operands, so its INT_RS
    // entry waits on no source register (a fetch fault's register fields are
    // garbage).
    if (i_illegal || i_fetch_fault) begin
      selected_class = '0;
      selected_class.rs_type = riscv_pkg::RS_INT;
    end
  end

  assign {o_has_int_dest, o_has_fp_dest, o_uses_int_rs1, o_uses_int_rs2,
          o_uses_fp_rs1, o_uses_fp_rs2, o_uses_fp_rs3, o_rs_type,
          o_is_int_store, o_is_branch_or_jump, o_is_fence, o_is_fence_i,
          o_is_sfence_vma, o_is_csr_imm, o_has_fp_flags} = selected_class;
endmodule : instr_operand_classifier
