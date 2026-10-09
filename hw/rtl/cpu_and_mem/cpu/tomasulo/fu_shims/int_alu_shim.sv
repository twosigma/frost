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
 * Integer ALU Shim
 *
 * Translates rs_issue_t from the INT reservation station into the ALU's native
 * port interface and packs the result into fu_complete_t for the CDB.
 *
 * The ALU is combinational, so the shim presents each result in its issue
 * cycle. It has no multiplier or divider: M-extension operations issue
 * through MUL_RS to int_muldiv_shim.
 *
 * Dispatch puts JALR's link address (PC + 2 or PC + 4) in imm and its
 * I-immediate in jalr_imm for branch resolution. For AUIPC, imm is PC + imm_u.
 *
 * Conditional branches do not write the CDB: o_fu_complete.valid follows the
 * RS's predecoded i_issue_writes_cdb_hint, which is clear for them, and branch
 * resolution runs on its own path. JALR does complete here, so its link
 * address wakes dependents. ECALL, EBREAK, illegal instructions and fetch
 * faults complete as exceptions. A CSR instruction sends its write operand to
 * the CDB; the CSR itself is read and written at commit. The CSR operand and
 * the fetch-fault value enter the result through the ALU's i_side_result.
 */
module int_alu_shim #(
    parameter bit USE_SHIFT_AMOUNT_HINT = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // From INT reservation station (issue output)
    input riscv_pkg::rs_issue_t       i_rs_issue,
    input logic                       i_issue_writes_cdb_hint,
    // Used only with USE_SHIFT_AMOUNT_HINT (the second INT pipe). It belongs to
    // the same issue packet and must equal the amount the ALU would select.
    input logic                 [5:0] i_shift_amount_hint,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // Back-pressure: ALU is single-cycle, always ready
    output logic o_fu_busy
);

  // ---------------------------------------------------------------------------
  // Reconstruct instruction fields needed by the ALU
  // ---------------------------------------------------------------------------
  riscv_pkg::instr_t alu_instruction;

  always_comb begin
    alu_instruction              = '0;
    // Opcode controls the ALU's internal operand_b mux:
    //   OPC_OP_IMM -> use sign-extended i_immediate_i_type
    //   OPC_OP     -> use i_operand_b (register value)
    alu_instruction.opcode       = i_rs_issue.use_imm ? riscv_pkg::OPC_OP_IMM : riscv_pkg::OPC_OP;
    // source_reg_2 provides the shift amount for immediate-shift operations
    // (SLLI, SRLI, SRAI, BSETI, BCLRI, BINVI, BEXTI, RORI); on RV64 the
    // base shifts carry shamt[5] in instruction bit 25 = funct7[0].
    alu_instruction.source_reg_2 = i_rs_issue.imm[4:0];
    alu_instruction.funct7[0]    = i_rs_issue.imm[5];
  end

  // ---------------------------------------------------------------------------
  // Operation classes the ALU has no result group for
  // ---------------------------------------------------------------------------
  logic is_csr_imm_op;
  assign is_csr_imm_op = (i_rs_issue.op == riscv_pkg::CSRRWI) ||
                          (i_rs_issue.op == riscv_pkg::CSRRSI) ||
                          (i_rs_issue.op == riscv_pkg::CSRRCI);

  logic is_csr_reg_op;
  assign is_csr_reg_op = (i_rs_issue.op == riscv_pkg::CSRRW) ||
                          (i_rs_issue.op == riscv_pkg::CSRRS) ||
                          (i_rs_issue.op == riscv_pkg::CSRRC);

  logic is_ecall_op;
  logic is_ebreak_op;
  logic is_illegal_op;
  logic is_fetch_fault_op;
  logic is_fetch_page_fault_op;
  assign is_ecall_op = (i_rs_issue.op == riscv_pkg::ECALL);
  assign is_ebreak_op = (i_rs_issue.op == riscv_pkg::EBREAK);
  assign is_illegal_op = (i_rs_issue.op == riscv_pkg::ILLEGAL);
  // Fetch-fault pseudo-ops carry an instruction access fault
  // (cause 1) or an instruction page fault (cause 12). epc is the entry's PC.
  // xtval arrives precomputed in imm: PC + the offset of the faulting
  // portion (2 for a page-straddling instruction whose second halfword
  // faulted, 0 otherwise). It rides the CDB value slot, like a data fault's VA.
  assign is_fetch_fault_op = (i_rs_issue.op == riscv_pkg::FETCH_FAULT);
  assign is_fetch_page_fault_op = (i_rs_issue.op == riscv_pkg::FETCH_PAGE_FAULT);

  // The ALU ORs in a CSR write operand or a fetch fault's xtval. These ops
  // select no ALU result group; all other ops contribute zero here.
  // ECALL, EBREAK and ILLEGAL complete with a zero value.
  logic [riscv_pkg::XLEN-1:0] side_result;
  assign side_result =
      ({riscv_pkg::XLEN{is_fetch_fault_op || is_fetch_page_fault_op}} & i_rs_issue.imm) |
      ({riscv_pkg::XLEN{is_csr_imm_op}} & riscv_pkg::XLEN'(i_rs_issue.csr_imm)) |
      ({riscv_pkg::XLEN{is_csr_reg_op}} & i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]);

  // ---------------------------------------------------------------------------
  // ALU instantiation
  // ---------------------------------------------------------------------------
  logic [riscv_pkg::XLEN-1:0] alu_result;

  alu #(
      .XLEN(riscv_pkg::XLEN),
      .USE_SHIFT_AMOUNT_HINT(USE_SHIFT_AMOUNT_HINT)
  ) u_alu (
      .i_instruction(alu_instruction),
      .i_instruction_operation(i_rs_issue.op),
      .i_operand_a(i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]),
      .i_operand_b(i_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .i_shift_amount_hint(i_shift_amount_hint),
      .i_immediate_u_type(i_rs_issue.imm),
      .i_immediate_i_type(i_rs_issue.imm),
      // JALR's link address rides the immediate word (dispatch puts it there).
      .i_link_address(i_rs_issue.imm),
      .i_side_result(side_result),
      .o_result(alu_result)
  );

  // ---------------------------------------------------------------------------
  // Pack output into fu_complete_t
  // ---------------------------------------------------------------------------
  always_comb begin
    o_fu_complete.tag       = i_rs_issue.rob_tag;
    // The RS clears this hint for conditional branches.
    o_fu_complete.valid     = i_rs_issue.valid & i_issue_writes_cdb_hint;
    o_fu_complete.value     = riscv_pkg::FLEN'(alu_result);
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);

    if (is_ecall_op || is_ebreak_op || is_illegal_op || is_fetch_fault_op ||
        is_fetch_page_fault_op) begin
      // Synchronous traps complete on CDB so the ROB can take them precisely at commit.
      o_fu_complete.exception = 1'b1;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
          is_fetch_page_fault_op ? riscv_pkg::ExcInstrPageFault[riscv_pkg::ExcCauseWidth-1:0] :
          is_fetch_fault_op ? riscv_pkg::ExcInstrAccessFault[riscv_pkg::ExcCauseWidth-1:0] :
          is_illegal_op ? riscv_pkg::ExcIllegalInstr[riscv_pkg::ExcCauseWidth-1:0] :
          is_ecall_op ? riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0] :
          riscv_pkg::ExcBreakpoint[riscv_pkg::ExcCauseWidth-1:0]);
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    if (i_rst_n && i_rs_issue.valid) begin
`ifndef FORMAL
      // The wrapper's formal harness leaves op/RS pairing symbolic, so this
      // check runs in simulation only.
      assert (!(i_rs_issue.op inside {
        riscv_pkg::MUL, riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU,
        riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU,
        riscv_pkg::MULW, riscv_pkg::DIVW, riscv_pkg::DIVUW,
        riscv_pkg::REMW, riscv_pkg::REMUW
      }))
      else $error("int_alu_shim: M-extension operation must issue through int_muldiv_shim");
`endif

      if (i_issue_writes_cdb_hint) begin
        assert (i_rs_issue.op != riscv_pkg::BEQ && i_rs_issue.op != riscv_pkg::BNE &&
                i_rs_issue.op != riscv_pkg::BLT && i_rs_issue.op != riscv_pkg::BGE &&
                i_rs_issue.op != riscv_pkg::BLTU && i_rs_issue.op != riscv_pkg::BGEU)
        else $error("int_alu_shim: writeback hint asserted for conditional branch");
      end else begin
        assert (i_rs_issue.op == riscv_pkg::BEQ || i_rs_issue.op == riscv_pkg::BNE ||
                i_rs_issue.op == riscv_pkg::BLT || i_rs_issue.op == riscv_pkg::BGE ||
                i_rs_issue.op == riscv_pkg::BLTU || i_rs_issue.op == riscv_pkg::BGEU)
        else $error("int_alu_shim: writeback hint cleared for non-branch op");
      end
    end
  end
`endif

  assign o_fu_busy = 1'b0;

endmodule : int_alu_shim
