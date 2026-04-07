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
 * Tomasulo Dispatch Unit
 *
 * Sits between the ID stage and the Tomasulo out-of-order backend.
 * Takes decoded instructions (from_id_to_ex_t) and:
 *   1. Allocates a ROB entry
 *   2. Looks up source registers in the RAT (via tomasulo_wrapper ports)
 *   3. Renames the destination register in the RAT
 *   4. Routes the instruction to the correct Reservation Station
 *   5. Allocates a checkpoint for branches/jumps
 *   6. Generates back-pressure (stall) when resources are exhausted
 *
 * The dispatch is combinational: all outputs are derived from the registered
 * from_id_to_ex pipeline register in the same cycle.
 *
 * Stall conditions (any one stalls the front-end):
 *   - ROB full
 *   - Target RS full
 *   - LQ full (for loads)
 *   - SQ full (for stores)
 *   - No checkpoint available (for branches/jumps)
 *
 * Source operand resolution:
 *   For each source register, the RAT is consulted:
 *   - If the RAT says "renamed" (maps to a ROB tag):
 *     - Check if the ROB entry is already done (bypass read)
 *     - If done: src_ready=1, src_value=ROB value
 *     - If not done: src_ready=0, src_tag=ROB tag (will be woken by CDB)
 *   - If the RAT says "architectural" (no rename):
 *     - src_ready=1, src_value=regfile value
 *
 * Instructions that don't need an RS (WFI, MRET, PAUSE) are dispatched
 * to the ROB only (rs_type=RS_NONE). They are marked done at dispatch
 * with appropriate flags so the ROB handles them at commit.
 */

module dispatch (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Instruction Input (from ID stage pipeline register)
    // =========================================================================
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input logic                      i_valid,          // Instruction is valid (not flushed/bubbled)

    // Source register addresses (from PD early extraction, registered in ID)
    // These are used for RAT lookup timing optimization
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs1_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs2_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_fp_rs3_addr,

    // =========================================================================
    // FRM CSR (for dynamic rounding mode resolution)
    // =========================================================================
    input logic [2:0] i_frm_csr,

    // =========================================================================
    // ROB Allocation Interface (to/from tomasulo_wrapper)
    // =========================================================================
    output riscv_pkg::reorder_buffer_alloc_req_t  o_rob_alloc_req,
    input  riscv_pkg::reorder_buffer_alloc_resp_t i_rob_alloc_resp,

    // =========================================================================
    // RAT Source Lookups (combinational, from tomasulo_wrapper)
    // =========================================================================
    // Addresses driven out to tomasulo_wrapper
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src1_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src2_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src1_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src2_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src3_addr,

    // Lookup results from tomasulo_wrapper
    input riscv_pkg::rat_lookup_t i_int_src1,
    input riscv_pkg::rat_lookup_t i_int_src2,
    input riscv_pkg::rat_lookup_t i_fp_src1,
    input riscv_pkg::rat_lookup_t i_fp_src2,
    input riscv_pkg::rat_lookup_t i_fp_src3,

    // =========================================================================
    // RAT Rename (to tomasulo_wrapper — write dest mapping)
    // =========================================================================
    output logic                                        o_rat_alloc_valid,
    output logic                                        o_rat_alloc_dest_rf,   // 0=INT, 1=FP
    output logic [         riscv_pkg::RegAddrWidth-1:0] o_rat_alloc_dest_reg,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag,

    // =========================================================================
    // ROB Done-Entry Bypass (generic source ports)
    // =========================================================================
    input  logic [   riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_done,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_1,
    input  logic [                 riscv_pkg::FLEN-1:0] i_bypass_value_1,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_2,
    input  logic [                 riscv_pkg::FLEN-1:0] i_bypass_value_2,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_3,
    input  logic [                 riscv_pkg::FLEN-1:0] i_bypass_value_3,

    // =========================================================================
    // RS Dispatch (to tomasulo_wrapper)
    // =========================================================================
    output riscv_pkg::rs_dispatch_t o_rs_dispatch,

    // =========================================================================
    // Checkpoint Management (to/from tomasulo_wrapper)
    // =========================================================================
    // Checkpoint availability
    input logic                                    i_checkpoint_available,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_alloc_id,

    // Checkpoint save request (for branches)
    output logic                                        o_checkpoint_save,
    output logic [    riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_id,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_checkpoint_branch_tag,

    // RAS state to save with checkpoint
    input  logic [riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input  logic [  riscv_pkg::RasPtrBits:0] i_ras_valid_count,
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [  riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // ROB checkpoint recording
    output logic                                    o_rob_checkpoint_valid,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_rob_checkpoint_id,

    // =========================================================================
    // Resource Status (from tomasulo_wrapper)
    // =========================================================================
    input logic i_rob_full,
    input logic i_int_rs_full,
    input logic i_mul_rs_full,
    input logic i_mem_rs_full,
    input logic i_fp_rs_full,
    input logic i_fmul_rs_full,
    input logic i_fdiv_rs_full,
    input logic i_lq_full,
    input logic i_sq_full,

    // =========================================================================
    // ROB Bypass Read (for source operand resolution)
    // =========================================================================
    // We need up to 5 simultaneous ROB reads for source operands.
    // The tomasulo_wrapper exposes a single read port; the dispatch
    // module uses the RAT lookup result's "done" and "value" fields
    // which are returned by the RAT+ROB bypass path.

    // =========================================================================
    // Flush / recovery hold
    // =========================================================================
    input logic i_flush,
    input logic i_hold,

    // =========================================================================
    // Output: Stall Signal (to front-end pipeline control)
    // =========================================================================
    output riscv_pkg::dispatch_status_t o_status,
    output logic o_stall
);

  // ===========================================================================
  // Instruction Classification
  // ===========================================================================

  riscv_pkg::instr_op_e op;
  assign op = i_from_id_to_ex.instruction_operation;

  // RS routing
  riscv_pkg::rs_type_e rs_type;
  always_comb begin
    case (op)
      // Integer ALU operations -> INT_RS
      riscv_pkg::ADD, riscv_pkg::SUB, riscv_pkg::AND,
      riscv_pkg::OR, riscv_pkg::XOR, riscv_pkg::SLL,
      riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLT, riscv_pkg::SLTU,
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LUI, riscv_pkg::AUIPC, riscv_pkg::JALR,
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT,
      riscv_pkg::BGE, riscv_pkg::BLTU, riscv_pkg::BGEU,
      // Zba/Zbb/Zbs/Zbkb/Zicond -> INT_RS (1-cycle ALU)
      riscv_pkg::SH1ADD, riscv_pkg::SH2ADD,
      riscv_pkg::SH3ADD,
      riscv_pkg::BSET, riscv_pkg::BCLR,
      riscv_pkg::BINV, riscv_pkg::BEXT,
      riscv_pkg::BSETI, riscv_pkg::BCLRI,
      riscv_pkg::BINVI, riscv_pkg::BEXTI,
      riscv_pkg::ANDN, riscv_pkg::ORN,
      riscv_pkg::XNOR, riscv_pkg::CLZ,
      riscv_pkg::CTZ, riscv_pkg::CPOP,
      riscv_pkg::MAX, riscv_pkg::MAXU,
      riscv_pkg::MIN, riscv_pkg::MINU,
      riscv_pkg::SEXT_B, riscv_pkg::SEXT_H,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI,
      riscv_pkg::ORC_B, riscv_pkg::REV8,
      riscv_pkg::CZERO_EQZ, riscv_pkg::CZERO_NEZ,
      riscv_pkg::PACK, riscv_pkg::PACKH,
      riscv_pkg::BREV8, riscv_pkg::ZIP, riscv_pkg::UNZIP,
      // CSR instructions -> INT_RS
      riscv_pkg::CSRRW, riscv_pkg::CSRRS,
      riscv_pkg::CSRRC, riscv_pkg::CSRRWI,
      riscv_pkg::CSRRSI, riscv_pkg::CSRRCI,
      // Privileged (exceptions) -> INT_RS
      riscv_pkg::ECALL, riscv_pkg::EBREAK:
      rs_type = riscv_pkg::RS_INT;

      // Multiply/divide -> MUL_RS
      riscv_pkg::MUL, riscv_pkg::MULH,
      riscv_pkg::MULHSU, riscv_pkg::MULHU,
      riscv_pkg::DIV, riscv_pkg::DIVU,
      riscv_pkg::REM, riscv_pkg::REMU:
      rs_type = riscv_pkg::RS_MUL;

      // Memory operations -> MEM_RS (both INT and FP)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW,
      riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::FLD, riscv_pkg::FSD,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      riscv_pkg::FENCE, riscv_pkg::FENCE_I:
      rs_type = riscv_pkg::RS_MEM;

      // FP add/sub/cmp/cvt/classify/sgnj -> FP_RS
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S,
      riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S,
      riscv_pkg::FLE_S, riscv_pkg::FEQ_D,
      riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_W_X,
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D:
      rs_type = riscv_pkg::RS_FP;

      // FP multiply/FMA -> FMUL_RS (3 sources for FMA)
      riscv_pkg::FMUL_S, riscv_pkg::FMUL_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S,
      riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      rs_type = riscv_pkg::RS_FMUL;

      // FP divide/sqrt -> FDIV_RS (long latency)
      riscv_pkg::FDIV_S, riscv_pkg::FSQRT_S, riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D:
      rs_type = riscv_pkg::RS_FDIV;

      // Instructions that don't need RS (dispatch directly to Reorder Buffer)
      riscv_pkg::JAL, riscv_pkg::WFI, riscv_pkg::MRET, riscv_pkg::PAUSE:
      rs_type = riscv_pkg::RS_NONE;

      default: rs_type = riscv_pkg::RS_INT;  // Default fallback
    endcase
  end

  // Destination register classification
  logic has_dest;
  logic dest_rf;  // 0=INT, 1=FP
  logic [riscv_pkg::RegAddrWidth-1:0] dest_reg;

  // Inlined has_fp_dest
  logic has_fp_dest_flag;
  always_comb begin
    case (op)
      // FP loads
      riscv_pkg::FLW, riscv_pkg::FLD,
      // FP compute ops
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FMUL_S, riscv_pkg::FDIV_S,
      riscv_pkg::FSQRT_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMUL_D, riscv_pkg::FDIV_D,
      riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      // INT to FP conversion -> FP fd
      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      // FP format conversion
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S,
      // INT to FP bit move -> FP fd
      riscv_pkg::FMV_W_X:
      has_fp_dest_flag = 1'b1;

      default: has_fp_dest_flag = 1'b0;
    endcase
  end

  // Inlined has_int_dest
  logic has_int_dest_flag;
  always_comb begin
    case (op)
      // Integer ALU ops with rd
      riscv_pkg::ADD, riscv_pkg::SUB, riscv_pkg::AND,
      riscv_pkg::OR, riscv_pkg::XOR, riscv_pkg::SLL,
      riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLT, riscv_pkg::SLTU,
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LUI, riscv_pkg::AUIPC,
      riscv_pkg::JAL, riscv_pkg::JALR,
      // B-extension
      riscv_pkg::SH1ADD, riscv_pkg::SH2ADD,
      riscv_pkg::SH3ADD,
      riscv_pkg::BSET, riscv_pkg::BCLR,
      riscv_pkg::BINV, riscv_pkg::BEXT,
      riscv_pkg::BSETI, riscv_pkg::BCLRI,
      riscv_pkg::BINVI, riscv_pkg::BEXTI,
      riscv_pkg::ANDN, riscv_pkg::ORN,
      riscv_pkg::XNOR, riscv_pkg::CLZ,
      riscv_pkg::CTZ, riscv_pkg::CPOP,
      riscv_pkg::MAX, riscv_pkg::MAXU,
      riscv_pkg::MIN, riscv_pkg::MINU,
      riscv_pkg::SEXT_B, riscv_pkg::SEXT_H,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI,
      riscv_pkg::ORC_B, riscv_pkg::REV8,
      riscv_pkg::CZERO_EQZ, riscv_pkg::CZERO_NEZ,
      riscv_pkg::PACK, riscv_pkg::PACKH,
      riscv_pkg::BREV8, riscv_pkg::ZIP, riscv_pkg::UNZIP,
      // M-extension
      riscv_pkg::MUL, riscv_pkg::MULH,
      riscv_pkg::MULHSU, riscv_pkg::MULHU,
      riscv_pkg::DIV, riscv_pkg::DIVU,
      riscv_pkg::REM, riscv_pkg::REMU,
      // Integer loads
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      // Atomics (return old value to rd)
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      // CSR (return old CSR value to rd)
      riscv_pkg::CSRRW, riscv_pkg::CSRRS,
      riscv_pkg::CSRRC, riscv_pkg::CSRRWI,
      riscv_pkg::CSRRSI, riscv_pkg::CSRRCI,
      // FP compare -> INT rd
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S,
      riscv_pkg::FLE_S, riscv_pkg::FEQ_D,
      riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      // FP classify -> INT rd
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      // FP to INT conversion -> INT rd
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      // FP to INT bit move -> INT rd
      riscv_pkg::FMV_X_W:
      has_int_dest_flag = 1'b1;

      default: has_int_dest_flag = 1'b0;
    endcase
  end

  always_comb begin
    if (has_fp_dest_flag) begin
      has_dest = 1'b1;
      dest_rf  = 1'b1;
      dest_reg = i_from_id_to_ex.instruction.dest_reg;
    end else if (has_int_dest_flag) begin
      // x0 writes are architectural NOPs — still allocate ROB entry but
      // don't rename (RAT should never map x0)
      has_dest = (i_from_id_to_ex.instruction.dest_reg != 5'b0);
      dest_rf  = 1'b0;
      dest_reg = i_from_id_to_ex.instruction.dest_reg;
    end else begin
      has_dest = 1'b0;
      dest_rf  = 1'b0;
      dest_reg = '0;
    end
  end

  // Source register classification
  logic uses_int_rs1, uses_int_rs2;
  logic uses_fp_rs1_flag, uses_fp_rs2_flag, uses_fp_rs3_flag;
  logic is_store_flag, is_fp_store_flag, is_load_flag, is_fp_load_flag;
  logic is_branch_flag, is_call_flag, is_return_flag;
  logic is_jal_flag, is_jalr_flag;

  always_comb begin
    // Inlined uses_fp_rs1
    case (op)
      // FP compute ops (fs1)
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FMUL_S, riscv_pkg::FDIV_S,
      riscv_pkg::FSQRT_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMUL_D, riscv_pkg::FDIV_D,
      riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      // FP compare (fs1, fs2) -> INT rd
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S,
      riscv_pkg::FLE_S, riscv_pkg::FEQ_D,
      riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      // FP classify (fs1) -> INT rd
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      // FP to INT conversion (fs1) -> INT rd
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      // FP to INT bit move (fs1) -> INT rd
      riscv_pkg::FMV_X_W,
      // FP format conversion
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S:
      uses_fp_rs1_flag = 1'b1;

      default: uses_fp_rs1_flag = 1'b0;
    endcase

    // Inlined uses_fp_rs2
    case (op)
      // FP compute ops with 2+ sources
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FDIV_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D, riscv_pkg::FMUL_D, riscv_pkg::FDIV_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      // FP compare (fs1, fs2)
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S,
      riscv_pkg::FLE_S, riscv_pkg::FEQ_D,
      riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      // FP stores (base=INT rs1, data=FP rs2)
      riscv_pkg::FSW, riscv_pkg::FSD:
      uses_fp_rs2_flag = 1'b1;

      default: uses_fp_rs2_flag = 1'b0;
    endcase

    // Inlined uses_fp_rs3
    case (op)
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S,
      riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      uses_fp_rs3_flag = 1'b1;

      default: uses_fp_rs3_flag = 1'b0;
    endcase

    // INT rs1: most instructions use rs1 from integer regfile
    // Exception: pure FP compute ops use FP rs1 instead
    // Loads, stores, branches, ALU, CSR, AMO all use INT rs1
    // FP stores (FSW/FSD) use INT rs1 for base address
    uses_int_rs1 = !uses_fp_rs1_flag && (
      op != riscv_pkg::LUI && op != riscv_pkg::AUIPC && op != riscv_pkg::JAL &&
      op != riscv_pkg::ECALL && op != riscv_pkg::EBREAK &&
      op != riscv_pkg::FENCE && op != riscv_pkg::FENCE_I &&
      op != riscv_pkg::WFI && op != riscv_pkg::MRET && op != riscv_pkg::PAUSE &&
    // CSR immediate ops encode a 5-bit immediate in the rs1 field,
    // not an actual register address. Don't look up the RAT for these.
    op != riscv_pkg::CSRRWI && op != riscv_pkg::CSRRSI && op != riscv_pkg::CSRRCI);

    // INT rs2: branches, R-type ALU, stores, AMO, SC
    // FP stores use FP rs2 for data, not INT rs2
    uses_int_rs2 = !uses_fp_rs2_flag && (
    // Inlined is_conditional_branch_op
    (op == riscv_pkg::BEQ ||
      op == riscv_pkg::BNE ||
      op == riscv_pkg::BLT ||
      op == riscv_pkg::BGE ||
      op == riscv_pkg::BLTU ||
      op == riscv_pkg::BGEU) ||
    // R-type integer ALU (have rs2)
    op == riscv_pkg::ADD ||
      op == riscv_pkg::SUB ||
      op == riscv_pkg::AND ||
      op == riscv_pkg::OR ||
      op == riscv_pkg::XOR ||
      op == riscv_pkg::SLL ||
      op == riscv_pkg::SRL ||
      op == riscv_pkg::SRA ||
      op == riscv_pkg::SLT ||
      op == riscv_pkg::SLTU ||
      op == riscv_pkg::MUL ||
      op == riscv_pkg::MULH ||
      op == riscv_pkg::MULHSU ||
      op == riscv_pkg::MULHU ||
      op == riscv_pkg::DIV ||
      op == riscv_pkg::DIVU ||
      op == riscv_pkg::REM ||
      op == riscv_pkg::REMU ||
    // B-extension with rs2
    op == riscv_pkg::SH1ADD ||
      op == riscv_pkg::SH2ADD ||
      op == riscv_pkg::SH3ADD ||
      op == riscv_pkg::BSET ||
      op == riscv_pkg::BCLR ||
      op == riscv_pkg::BINV ||
      op == riscv_pkg::BEXT ||
      op == riscv_pkg::ANDN ||
      op == riscv_pkg::ORN ||
      op == riscv_pkg::XNOR ||
      op == riscv_pkg::MAX ||
      op == riscv_pkg::MAXU ||
      op == riscv_pkg::MIN ||
      op == riscv_pkg::MINU ||
      op == riscv_pkg::ROL ||
      op == riscv_pkg::ROR ||
      op == riscv_pkg::CZERO_EQZ ||
      op == riscv_pkg::CZERO_NEZ ||
      op == riscv_pkg::PACK ||
      op == riscv_pkg::PACKH ||
      op == riscv_pkg::ZIP ||
      op == riscv_pkg::UNZIP ||
    // Integer stores
    op == riscv_pkg::SB || op == riscv_pkg::SH || op == riscv_pkg::SW ||
    // Atomics (rs2 is source value for AMO/SC)
    op == riscv_pkg::SC_W ||
      op == riscv_pkg::AMOSWAP_W ||
      op == riscv_pkg::AMOADD_W ||
      op == riscv_pkg::AMOXOR_W ||
      op == riscv_pkg::AMOAND_W ||
      op == riscv_pkg::AMOOR_W ||
      op == riscv_pkg::AMOMIN_W ||
      op == riscv_pkg::AMOMAX_W ||
      op == riscv_pkg::AMOMINU_W ||
      op == riscv_pkg::AMOMAXU_W ||
    // JALR uses rs1 only (not rs2)
    1'b0);

    is_store_flag = (op == riscv_pkg::SB || op == riscv_pkg::SH || op == riscv_pkg::SW);
    is_fp_store_flag = (op == riscv_pkg::FSW || op == riscv_pkg::FSD);
    is_load_flag = i_from_id_to_ex.is_load_instruction;
    is_fp_load_flag = i_from_id_to_ex.is_fp_load;

    // Inlined is_branch_or_jump_op
    is_branch_flag = (
      op == riscv_pkg::BEQ ||
      op == riscv_pkg::BNE ||
      op == riscv_pkg::BLT ||
      op == riscv_pkg::BGE ||
      op == riscv_pkg::BLTU ||
      op == riscv_pkg::BGEU ||
      op == riscv_pkg::JAL ||
      op == riscv_pkg::JALR);
    // Inlined is_jal_op
    is_jal_flag = (op == riscv_pkg::JAL);
    // Inlined is_jalr_op
    is_jalr_flag = (op == riscv_pkg::JALR);

    // Reuse the ID-stage RAS classification so commit-time recovery matches the
    // IF-stage RAS detector. In particular, compressed `c.jalr t0` expands to
    // `jalr x1, x5, 0` and is a plain call in real code, not a return.
    is_call_flag = i_from_id_to_ex.is_ras_call;
    is_return_flag = i_from_id_to_ex.is_ras_return;
  end

  // Memory operation size and sign
  riscv_pkg::mem_size_e mem_size;
  logic                 mem_signed;

  always_comb begin
    case (op)
      riscv_pkg::LB, riscv_pkg::LBU, riscv_pkg::SB: mem_size = riscv_pkg::MEM_SIZE_BYTE;
      riscv_pkg::LH, riscv_pkg::LHU, riscv_pkg::SH: mem_size = riscv_pkg::MEM_SIZE_HALF;
      riscv_pkg::LW, riscv_pkg::SW, riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      mem_size = riscv_pkg::MEM_SIZE_WORD;
      riscv_pkg::FLD, riscv_pkg::FSD: mem_size = riscv_pkg::MEM_SIZE_DOUBLE;
      default: mem_size = riscv_pkg::MEM_SIZE_WORD;
    endcase

    // Signed loads: LB, LH (unsigned: LBU, LHU, LW, FP loads)
    mem_signed = (op == riscv_pkg::LB || op == riscv_pkg::LH);
  end

  // FP rounding mode resolution: if instruction says DYN (3'b111), use frm CSR
  logic [2:0] resolved_rm;
  always_comb begin
    if (i_from_id_to_ex.fp_rm == 3'b111) resolved_rm = i_frm_csr;
    else resolved_rm = i_from_id_to_ex.fp_rm;
  end

  // Immediate value selection
  logic [riscv_pkg::XLEN-1:0] imm;
  logic                       use_imm;

  always_comb begin
    use_imm = 1'b0;
    imm     = '0;

    case (op)
      // I-type immediate (loads, ALU-imm, JALR)
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::JALR,
      // B-ext immediate forms
      riscv_pkg::BSETI, riscv_pkg::BCLRI, riscv_pkg::BINVI, riscv_pkg::BEXTI, riscv_pkg::RORI: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_i_type;
      end

      // S-type immediate (stores)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::FSW, riscv_pkg::FSD: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_s_type;
      end

      // U-type immediate
      riscv_pkg::LUI: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_u_type;
      end

      riscv_pkg::AUIPC: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_u_type;
      end

      default: begin
        use_imm = 1'b0;
        imm     = '0;
      end
    endcase
  end

  // Predicted branch info
  logic                       predicted_taken;
  logic [riscv_pkg::XLEN-1:0] predicted_target;

  always_comb begin
    if (i_from_id_to_ex.ras_predicted) begin
      predicted_taken  = 1'b1;
      predicted_target = i_from_id_to_ex.ras_predicted_target;
    end else if (i_from_id_to_ex.btb_predicted_taken) begin
      predicted_taken  = 1'b1;
      predicted_target = i_from_id_to_ex.btb_predicted_target;
    end else begin
      predicted_taken  = 1'b0;
      predicted_target = '0;
    end
  end

  // Branch target (pre-computed in ID stage)
  logic [riscv_pkg::XLEN-1:0] branch_target;
  always_comb begin
    if (is_jal_flag) branch_target = i_from_id_to_ex.jal_target_precomputed;
    else branch_target = i_from_id_to_ex.branch_target_precomputed;
  end

  // ===========================================================================
  // Stall Logic
  // ===========================================================================

  logic rs_full;
  always_comb begin
    case (rs_type)
      riscv_pkg::RS_INT: rs_full = i_int_rs_full;
      riscv_pkg::RS_MUL: rs_full = i_mul_rs_full;
      riscv_pkg::RS_MEM: rs_full = i_mem_rs_full;
      riscv_pkg::RS_FP: rs_full = i_fp_rs_full;
      riscv_pkg::RS_FMUL: rs_full = i_fmul_rs_full;
      riscv_pkg::RS_FDIV: rs_full = i_fdiv_rs_full;
      riscv_pkg::RS_NONE: rs_full = 1'b0;  // No RS needed
      default: rs_full = 1'b0;
    endcase
  end

  logic need_lq, need_sq;
  assign need_lq = is_load_flag || is_fp_load_flag ||
                   i_from_id_to_ex.is_lr ||
                   i_from_id_to_ex.is_amo_instruction;
  assign need_sq = is_store_flag || is_fp_store_flag ||
                   i_from_id_to_ex.is_sc ||
                   (i_from_id_to_ex.is_amo_instruction && !i_from_id_to_ex.is_lr);

  logic need_checkpoint;
  assign need_checkpoint = is_branch_flag;

  logic dispatch_valid;
  assign dispatch_valid = i_valid && !i_flush;

  // Stall: back-pressure when any needed resource is full
  always_comb begin
    o_status = '0;
    o_status.dispatch_valid = dispatch_valid;
    o_status.reorder_buffer_full = dispatch_valid && i_rob_full;
    o_status.int_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_INT) && i_int_rs_full;
    o_status.mul_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_MUL) && i_mul_rs_full;
    o_status.mem_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_MEM) && i_mem_rs_full;
    o_status.fp_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_FP) && i_fp_rs_full;
    o_status.fmul_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_FMUL) && i_fmul_rs_full;
    o_status.fdiv_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_FDIV) && i_fdiv_rs_full;
    o_status.lq_full = dispatch_valid && need_lq && i_lq_full;
    o_status.sq_full = dispatch_valid && need_sq && i_sq_full;
    o_status.checkpoint_full = dispatch_valid && need_checkpoint && !i_checkpoint_available;

    if (!dispatch_valid) begin
      o_stall = 1'b0;
    end else begin
      o_stall = i_hold ||
                i_rob_full ||
                rs_full ||
                (need_lq && i_lq_full) ||
                (need_sq && i_sq_full) ||
                (need_checkpoint && !i_checkpoint_available);
    end
    o_status.stall = o_stall;
  end

  // Dispatch fires when valid and not stalled
  logic dispatch_fire;
  assign dispatch_fire   = dispatch_valid && !o_stall;

  // ===========================================================================
  // RAT Source Address Outputs
  // ===========================================================================
  // Drive RAT lookup addresses. For instructions that use INT rs1 + FP rs2
  // (e.g., FP stores: base address from INT rs1, data from FP rs2), we route
  // accordingly.

  assign o_int_src1_addr = i_rs1_addr;
  assign o_int_src2_addr = i_rs2_addr;
  assign o_fp_src1_addr  = i_rs1_addr;
  assign o_fp_src2_addr  = i_rs2_addr;
  assign o_fp_src3_addr  = i_fp_rs3_addr;

  // ===========================================================================
  // Source Operand Resolution
  // ===========================================================================
  // For each source, select between INT and FP RAT based on instruction type,
  // then resolve ready/tag/value from the RAT lookup result.

  logic                                        src1_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] src1_tag;
  logic [                 riscv_pkg::FLEN-1:0] src1_value;

  logic                                        src2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] src2_tag;
  logic [                 riscv_pkg::FLEN-1:0] src2_value;

  logic                                        src3_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] src3_tag;
  logic [                 riscv_pkg::FLEN-1:0] src3_value;

  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_1_sel;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_2_sel;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_3_sel;

  always_comb begin
    if (uses_fp_rs1_flag) bypass_tag_1_sel = i_fp_src1.tag;
    else if (uses_int_rs1) bypass_tag_1_sel = i_int_src1.tag;
    else bypass_tag_1_sel = '0;

    if (uses_fp_rs2_flag) bypass_tag_2_sel = i_fp_src2.tag;
    else if (uses_int_rs2) bypass_tag_2_sel = i_int_src2.tag;
    else bypass_tag_2_sel = '0;

    if (uses_fp_rs3_flag) bypass_tag_3_sel = i_fp_src3.tag;
    else bypass_tag_3_sel = '0;
  end

  assign o_bypass_tag_1 = bypass_tag_1_sel;
  assign o_bypass_tag_2 = bypass_tag_2_sel;
  assign o_bypass_tag_3 = bypass_tag_3_sel;

  // Source 1 resolution
  // RAT lookup: renamed=1 means source maps to an in-flight ROB entry.
  // Dispatch checks whether that ROB entry is already done and uses the
  // async bypass value when available; otherwise the RS waits for the CDB.
  always_comb begin
    if (uses_fp_rs1_flag) begin
      src1_ready = !i_fp_src1.renamed;
      if (i_fp_src1.renamed && i_rob_entry_done[i_fp_src1.tag]) begin
        src1_ready = 1'b1;
        src1_value = i_bypass_value_1;
      end else begin
        src1_value = i_fp_src1.value;
      end
      src1_tag = i_fp_src1.tag;
    end else if (uses_int_rs1) begin
      src1_ready = !i_int_src1.renamed;
      if (i_int_src1.renamed && i_rob_entry_done[i_int_src1.tag]) begin
        src1_ready = 1'b1;
        src1_value = i_bypass_value_1;
      end else begin
        src1_value = i_int_src1.value;
      end
      src1_tag = i_int_src1.tag;
    end else begin
      // No source 1 needed (LUI, AUIPC, JAL, etc.)
      src1_ready = 1'b1;
      src1_tag   = '0;
      src1_value = '0;
    end
  end

  // Source 2 resolution
  always_comb begin
    if (uses_fp_rs2_flag) begin
      src2_ready = !i_fp_src2.renamed;
      if (i_fp_src2.renamed && i_rob_entry_done[i_fp_src2.tag]) begin
        src2_ready = 1'b1;
        src2_value = i_bypass_value_2;
      end else begin
        src2_value = i_fp_src2.value;
      end
      src2_tag = i_fp_src2.tag;
    end else if (uses_int_rs2) begin
      src2_ready = !i_int_src2.renamed;
      if (i_int_src2.renamed && i_rob_entry_done[i_int_src2.tag]) begin
        src2_ready = 1'b1;
        src2_value = i_bypass_value_2;
      end else begin
        src2_value = i_int_src2.value;
      end
      src2_tag = i_int_src2.tag;
    end else begin
      // No source 2 needed
      src2_ready = 1'b1;
      src2_tag   = '0;
      src2_value = '0;
    end
  end

  // Source 3 resolution (FMA only — always FP)
  always_comb begin
    if (uses_fp_rs3_flag) begin
      src3_ready = !i_fp_src3.renamed;
      if (i_fp_src3.renamed && i_rob_entry_done[i_fp_src3.tag]) begin
        src3_ready = 1'b1;
        src3_value = i_bypass_value_3;
      end else begin
        src3_value = i_fp_src3.value;
      end
      src3_tag = i_fp_src3.tag;
    end else begin
      src3_ready = 1'b1;
      src3_tag   = '0;
      src3_value = '0;
    end
  end

  // ===========================================================================
  // ROB Allocation Request
  // ===========================================================================

  always_comb begin
    o_rob_alloc_req = '0;

    o_rob_alloc_req.alloc_valid = dispatch_fire;
    o_rob_alloc_req.pc = i_from_id_to_ex.program_counter;
    o_rob_alloc_req.rs_type = rs_type;
    o_rob_alloc_req.dest_rf = dest_rf;
    o_rob_alloc_req.dest_reg = dest_reg;
    o_rob_alloc_req.dest_valid = has_dest;
    o_rob_alloc_req.is_store = is_store_flag;
    o_rob_alloc_req.is_fp_store = is_fp_store_flag;
    o_rob_alloc_req.is_branch = is_branch_flag;
    o_rob_alloc_req.predicted_taken = predicted_taken;
    o_rob_alloc_req.predicted_target = predicted_target;
    o_rob_alloc_req.branch_target = branch_target;
    o_rob_alloc_req.is_call = is_call_flag;
    o_rob_alloc_req.is_return = is_return_flag;
    o_rob_alloc_req.link_addr = i_from_id_to_ex.link_address;
    o_rob_alloc_req.is_jal = is_jal_flag;
    o_rob_alloc_req.is_jalr = is_jalr_flag;
    o_rob_alloc_req.is_csr = i_from_id_to_ex.is_csr_instruction;
    o_rob_alloc_req.is_fence = (op == riscv_pkg::FENCE);
    o_rob_alloc_req.is_fence_i = (op == riscv_pkg::FENCE_I);
    o_rob_alloc_req.is_wfi = i_from_id_to_ex.is_wfi;
    o_rob_alloc_req.is_mret = i_from_id_to_ex.is_mret;
    o_rob_alloc_req.is_amo = i_from_id_to_ex.is_amo_instruction;
    o_rob_alloc_req.is_lr = i_from_id_to_ex.is_lr;
    o_rob_alloc_req.is_sc = i_from_id_to_ex.is_sc;
    // Compressed instruction detection: link_address == PC + 2 (vs PC + 4 for 32-bit).
    // Cannot check opcode[1:0] because decompression expands all instructions to 32-bit.
    o_rob_alloc_req.is_compressed =
        (i_from_id_to_ex.link_address == i_from_id_to_ex.program_counter + 32'd2);

    // CSR info (stored in ROB for commit-time serialized execution)
    o_rob_alloc_req.csr_addr = i_from_id_to_ex.csr_address;
    o_rob_alloc_req.csr_op = i_from_id_to_ex.instruction.funct3;
    // CSR write data: rs1 for register-based ops, zero-extended imm for immediate ops
    o_rob_alloc_req.csr_write_data =
      (op == riscv_pkg::CSRRWI || op == riscv_pkg::CSRRSI || op == riscv_pkg::CSRRCI) ?
        {{(riscv_pkg::XLEN - 5) {1'b0}}, i_from_id_to_ex.csr_imm} :
    // For register-based CSR ops, the actual rs1 value won't be known
    // until the source operand resolves. The ALU shim will handle
    // reading rs1 from the RS issue and computing the CSR result.
    '0;

    // FP flags validity: FP compute ops produce flags, FP loads do not
    o_rob_alloc_req.has_fp_flags = i_from_id_to_ex.is_fp_compute;
  end

  // ===========================================================================
  // RAT Rename Output
  // ===========================================================================

  always_comb begin
    o_rat_alloc_valid    = dispatch_fire && has_dest;
    o_rat_alloc_dest_rf  = dest_rf;
    o_rat_alloc_dest_reg = dest_reg;
    o_rat_alloc_rob_tag  = i_rob_alloc_resp.alloc_tag;
  end

  // ===========================================================================
  // RS Dispatch Output
  // ===========================================================================

  always_comb begin
    o_rs_dispatch                  = '0;

    o_rs_dispatch.valid            = dispatch_fire && (rs_type != riscv_pkg::RS_NONE);
    o_rs_dispatch.rs_type          = rs_type;
    o_rs_dispatch.rob_tag          = i_rob_alloc_resp.alloc_tag;
    o_rs_dispatch.op               = op;

    // Source operands
    o_rs_dispatch.src1_ready       = src1_ready;
    o_rs_dispatch.src1_tag         = src1_tag;
    o_rs_dispatch.src1_value       = src1_value;

    o_rs_dispatch.src2_ready       = src2_ready;
    o_rs_dispatch.src2_tag         = src2_tag;
    o_rs_dispatch.src2_value       = src2_value;

    o_rs_dispatch.src3_ready       = src3_ready;
    o_rs_dispatch.src3_tag         = src3_tag;
    o_rs_dispatch.src3_value       = src3_value;

    // Immediate
    o_rs_dispatch.imm              = imm;
    o_rs_dispatch.use_imm          = use_imm;

    // Rounding mode
    o_rs_dispatch.rm               = resolved_rm;

    // Branch info
    o_rs_dispatch.branch_target    = branch_target;
    o_rs_dispatch.predicted_taken  = predicted_taken;
    o_rs_dispatch.predicted_target = predicted_target;

    // Memory info
    o_rs_dispatch.is_fp_mem        = is_fp_load_flag || is_fp_store_flag;
    o_rs_dispatch.mem_size         = mem_size;
    o_rs_dispatch.mem_signed       = mem_signed;

    // CSR info
    o_rs_dispatch.csr_addr         = i_from_id_to_ex.csr_address;
    o_rs_dispatch.csr_imm          = i_from_id_to_ex.csr_imm;

    // PC and pre-computed link address for AUIPC/JAL/JALR handling.
    o_rs_dispatch.pc               = i_from_id_to_ex.program_counter;
    o_rs_dispatch.link_addr        = i_from_id_to_ex.link_address;

    // Early misprediction recovery: checkpoint info and branch type.
    // need_checkpoint is true for conditional branches and JALR (not JAL).
    // When dispatch fires for a branch, a checkpoint is always available
    // (dispatch stalls otherwise), so has_checkpoint = need_checkpoint.
    o_rs_dispatch.has_checkpoint   = need_checkpoint;
    o_rs_dispatch.checkpoint_id    = i_checkpoint_alloc_id;
    o_rs_dispatch.is_call          = is_call_flag;
    o_rs_dispatch.is_return        = is_return_flag;
  end

  // ===========================================================================
  // Checkpoint Management
  // ===========================================================================

  always_comb begin
    // Save checkpoint when dispatching a branch/jump
    o_checkpoint_save       = dispatch_fire && need_checkpoint;
    o_checkpoint_id         = i_checkpoint_alloc_id;
    o_checkpoint_branch_tag = i_rob_alloc_resp.alloc_tag;

    // RAS state to save: comes from the prediction metadata in the
    // instruction (captured at IF time — reflects RAS state before
    // any push/pop for this instruction).
    o_ras_tos               = i_from_id_to_ex.ras_checkpoint_tos;
    o_ras_valid_count       = i_from_id_to_ex.ras_checkpoint_valid_count;

    // ROB checkpoint recording (separate from RAT checkpoint)
    o_rob_checkpoint_valid  = o_checkpoint_save;
    o_rob_checkpoint_id     = i_checkpoint_alloc_id;
  end

endmodule : dispatch
