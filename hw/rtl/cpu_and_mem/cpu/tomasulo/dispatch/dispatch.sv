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

module dispatch
  import riscv_pkg::*;
(
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Instruction Input (from ID stage pipeline register)
    // =========================================================================
    input from_id_to_ex_t i_from_id_to_ex,
    input logic           i_valid,  // Instruction is valid (not flushed/bubbled)

    // Source register addresses (from PD early extraction, registered in ID)
    // These are used for RAT lookup timing optimization
    input logic [RegAddrWidth-1:0] i_rs1_addr,
    input logic [RegAddrWidth-1:0] i_rs2_addr,
    input logic [RegAddrWidth-1:0] i_fp_rs3_addr,

    // =========================================================================
    // FRM CSR (for dynamic rounding mode resolution)
    // =========================================================================
    input logic [2:0] i_frm_csr,

    // =========================================================================
    // ROB Allocation Interface (to/from tomasulo_wrapper)
    // =========================================================================
    output reorder_buffer_alloc_req_t  o_rob_alloc_req,
    input  reorder_buffer_alloc_resp_t i_rob_alloc_resp,

    // =========================================================================
    // RAT Source Lookups (combinational, from tomasulo_wrapper)
    // =========================================================================
    // Addresses driven out to tomasulo_wrapper
    output logic [RegAddrWidth-1:0] o_int_src1_addr,
    output logic [RegAddrWidth-1:0] o_int_src2_addr,
    output logic [RegAddrWidth-1:0] o_fp_src1_addr,
    output logic [RegAddrWidth-1:0] o_fp_src2_addr,
    output logic [RegAddrWidth-1:0] o_fp_src3_addr,

    // Lookup results from tomasulo_wrapper
    input rat_lookup_t i_int_src1,
    input rat_lookup_t i_int_src2,
    input rat_lookup_t i_fp_src1,
    input rat_lookup_t i_fp_src2,
    input rat_lookup_t i_fp_src3,

    // =========================================================================
    // RAT Rename (to tomasulo_wrapper — write dest mapping)
    // =========================================================================
    output logic                             o_rat_alloc_valid,
    output logic                             o_rat_alloc_dest_rf,   // 0=INT, 1=FP
    output logic [RegAddrWidth-1:0]          o_rat_alloc_dest_reg,
    output logic [ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag,

    // =========================================================================
    // RS Dispatch (to tomasulo_wrapper)
    // =========================================================================
    output rs_dispatch_t o_rs_dispatch,

    // =========================================================================
    // Checkpoint Management (to/from tomasulo_wrapper)
    // =========================================================================
    // Checkpoint availability
    input  logic                         i_checkpoint_available,
    input  logic [CheckpointIdWidth-1:0] i_checkpoint_alloc_id,

    // Checkpoint save request (for branches)
    output logic                             o_checkpoint_save,
    output logic [CheckpointIdWidth-1:0]     o_checkpoint_id,
    output logic [ReorderBufferTagWidth-1:0] o_checkpoint_branch_tag,

    // RAS state to save with checkpoint
    input  logic [RasPtrBits-1:0] i_ras_tos,
    input  logic [RasPtrBits:0]   i_ras_valid_count,
    output logic [RasPtrBits-1:0] o_ras_tos,
    output logic [RasPtrBits:0]   o_ras_valid_count,

    // ROB checkpoint recording
    output logic                         o_rob_checkpoint_valid,
    output logic [CheckpointIdWidth-1:0] o_rob_checkpoint_id,

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
    // Flush
    // =========================================================================
    input logic i_flush,

    // =========================================================================
    // Output: Stall Signal (to front-end pipeline control)
    // =========================================================================
    output logic o_stall
);

  // ===========================================================================
  // Instruction Classification
  // ===========================================================================

  instr_op_e op;
  assign op = i_from_id_to_ex.instruction_operation;

  // RS routing
  rs_type_e rs_type;
  assign rs_type = get_rs_type(op);

  // Destination register classification
  logic has_dest;
  logic dest_rf;  // 0=INT, 1=FP
  logic [RegAddrWidth-1:0] dest_reg;

  always_comb begin
    if (has_fp_dest(op)) begin
      has_dest = 1'b1;
      dest_rf  = 1'b1;
      dest_reg = i_from_id_to_ex.instruction.dest_reg;
    end else if (has_int_dest(op)) begin
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
    uses_fp_rs1_flag = uses_fp_rs1(op);
    uses_fp_rs2_flag = uses_fp_rs2(op);
    uses_fp_rs3_flag = uses_fp_rs3(op);

    // INT rs1: most instructions use rs1 from integer regfile
    // Exception: pure FP compute ops use FP rs1 instead
    // Loads, stores, branches, ALU, CSR, AMO all use INT rs1
    // FP stores (FSW/FSD) use INT rs1 for base address
    uses_int_rs1 = !uses_fp_rs1_flag && (
      op != LUI && op != AUIPC && op != JAL &&
      op != ECALL && op != EBREAK &&
      op != FENCE && op != FENCE_I &&
      op != WFI && op != MRET && op != PAUSE
    );

    // INT rs2: branches, R-type ALU, stores, AMO, SC
    // FP stores use FP rs2 for data, not INT rs2
    uses_int_rs2 = !uses_fp_rs2_flag && (
      is_conditional_branch_op(op) ||
      // R-type integer ALU (have rs2)
      op == ADD || op == SUB || op == AND || op == OR || op == XOR ||
      op == SLL || op == SRL || op == SRA || op == SLT || op == SLTU ||
      op == MUL || op == MULH || op == MULHSU || op == MULHU ||
      op == DIV || op == DIVU || op == REM || op == REMU ||
      // B-extension with rs2
      op == SH1ADD || op == SH2ADD || op == SH3ADD ||
      op == BSET || op == BCLR || op == BINV || op == BEXT ||
      op == ANDN || op == ORN || op == XNOR ||
      op == MAX || op == MAXU || op == MIN || op == MINU ||
      op == ROL || op == ROR ||
      op == CZERO_EQZ || op == CZERO_NEZ ||
      op == PACK || op == PACKH || op == ZIP || op == UNZIP ||
      // Integer stores
      op == SB || op == SH || op == SW ||
      // Atomics (rs2 is the source value for AMO/SC)
      op == SC_W ||
      op == AMOSWAP_W || op == AMOADD_W || op == AMOXOR_W ||
      op == AMOAND_W || op == AMOOR_W ||
      op == AMOMIN_W || op == AMOMAX_W || op == AMOMINU_W || op == AMOMAXU_W ||
      // JALR uses rs1 only (not rs2)
      1'b0
    );

    is_store_flag    = (op == SB || op == SH || op == SW);
    is_fp_store_flag = (op == FSW || op == FSD);
    is_load_flag     = i_from_id_to_ex.is_load_instruction;
    is_fp_load_flag  = i_from_id_to_ex.is_fp_load;

    is_branch_flag = is_branch_or_jump_op(op);
    is_jal_flag    = is_jal_op(op);
    is_jalr_flag   = is_jalr_op(op);

    // Call: JAL/JALR with rd in {x1, x5}
    is_call_flag = (is_jal_flag || is_jalr_flag) &&
                   (dest_reg == 5'd1 || dest_reg == 5'd5);

    // Return: JALR with rs1 in {x1, x5}, rd != rs1
    is_return_flag = is_jalr_flag &&
                     (i_rs1_addr == 5'd1 || i_rs1_addr == 5'd5) &&
                     (dest_reg != i_rs1_addr);
  end

  // Memory operation size and sign
  mem_size_e mem_size;
  logic      mem_signed;

  always_comb begin
    case (op)
      LB, LBU, SB: mem_size = MEM_SIZE_BYTE;
      LH, LHU, SH: mem_size = MEM_SIZE_HALF;
      LW, SW, FLW, FSW,
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W:
                    mem_size = MEM_SIZE_WORD;
      FLD, FSD:     mem_size = MEM_SIZE_DOUBLE;
      default:      mem_size = MEM_SIZE_WORD;
    endcase

    // Signed loads: LB, LH (unsigned: LBU, LHU, LW, FP loads)
    mem_signed = (op == LB || op == LH);
  end

  // FP rounding mode resolution: if instruction says DYN (3'b111), use frm CSR
  logic [2:0] resolved_rm;
  always_comb begin
    if (i_from_id_to_ex.fp_rm == 3'b111)
      resolved_rm = i_frm_csr;
    else
      resolved_rm = i_from_id_to_ex.fp_rm;
  end

  // Immediate value selection
  logic [XLEN-1:0] imm;
  logic             use_imm;

  always_comb begin
    use_imm = 1'b0;
    imm     = '0;

    case (op)
      // I-type immediate (loads, ALU-imm, JALR)
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LB, LH, LW, LBU, LHU,
      FLW, FLD,
      JALR,
      // B-ext immediate forms
      BSETI, BCLRI, BINVI, BEXTI, RORI: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_i_type;
      end

      // S-type immediate (stores)
      SB, SH, SW, FSW, FSD: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_s_type;
      end

      // U-type immediate
      LUI: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_u_type;
      end

      AUIPC: begin
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
  logic            predicted_taken;
  logic [XLEN-1:0] predicted_target;

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
  logic [XLEN-1:0] branch_target;
  always_comb begin
    if (is_jal_flag)
      branch_target = i_from_id_to_ex.jal_target_precomputed;
    else
      branch_target = i_from_id_to_ex.branch_target_precomputed;
  end

  // ===========================================================================
  // Stall Logic
  // ===========================================================================

  logic rs_full;
  always_comb begin
    case (rs_type)
      RS_INT:  rs_full = i_int_rs_full;
      RS_MUL:  rs_full = i_mul_rs_full;
      RS_MEM:  rs_full = i_mem_rs_full;
      RS_FP:   rs_full = i_fp_rs_full;
      RS_FMUL: rs_full = i_fmul_rs_full;
      RS_FDIV: rs_full = i_fdiv_rs_full;
      RS_NONE: rs_full = 1'b0;  // No RS needed
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
    if (!dispatch_valid) begin
      o_stall = 1'b0;
    end else begin
      o_stall = i_rob_full ||
                rs_full ||
                (need_lq && i_lq_full) ||
                (need_sq && i_sq_full) ||
                (need_checkpoint && !i_checkpoint_available);
    end
  end

  // Dispatch fires when valid and not stalled
  logic dispatch_fire;
  assign dispatch_fire = dispatch_valid && !o_stall;

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

  logic             src1_ready;
  logic [ReorderBufferTagWidth-1:0] src1_tag;
  logic [FLEN-1:0]  src1_value;

  logic             src2_ready;
  logic [ReorderBufferTagWidth-1:0] src2_tag;
  logic [FLEN-1:0]  src2_value;

  logic             src3_ready;
  logic [ReorderBufferTagWidth-1:0] src3_tag;
  logic [FLEN-1:0]  src3_value;

  // Source 1 resolution
  // RAT lookup: renamed=1 means source is in-flight (not ready, wait for CDB)
  //             renamed=0 means source is architectural (ready, use regfile value)
  always_comb begin
    if (uses_fp_rs1_flag) begin
      src1_ready = !i_fp_src1.renamed;
      src1_tag   = i_fp_src1.tag;
      src1_value = i_fp_src1.value;
    end else if (uses_int_rs1) begin
      src1_ready = !i_int_src1.renamed;
      src1_tag   = i_int_src1.tag;
      src1_value = i_int_src1.value;
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
      src2_tag   = i_fp_src2.tag;
      src2_value = i_fp_src2.value;
    end else if (uses_int_rs2) begin
      src2_ready = !i_int_src2.renamed;
      src2_tag   = i_int_src2.tag;
      src2_value = i_int_src2.value;
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
      src3_tag   = i_fp_src3.tag;
      src3_value = i_fp_src3.value;
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
    o_rob_alloc_req.pc          = i_from_id_to_ex.program_counter;
    o_rob_alloc_req.dest_rf     = dest_rf;
    o_rob_alloc_req.dest_reg    = dest_reg;
    o_rob_alloc_req.dest_valid  = has_dest;
    o_rob_alloc_req.is_store    = is_store_flag;
    o_rob_alloc_req.is_fp_store = is_fp_store_flag;
    o_rob_alloc_req.is_branch   = is_branch_flag;
    o_rob_alloc_req.predicted_taken  = predicted_taken;
    o_rob_alloc_req.predicted_target = predicted_target;
    o_rob_alloc_req.is_call     = is_call_flag;
    o_rob_alloc_req.is_return   = is_return_flag;
    o_rob_alloc_req.link_addr   = i_from_id_to_ex.link_address;
    o_rob_alloc_req.is_jal      = is_jal_flag;
    o_rob_alloc_req.is_jalr     = is_jalr_flag;
    o_rob_alloc_req.is_csr      = i_from_id_to_ex.is_csr_instruction;
    o_rob_alloc_req.is_fence    = (op == FENCE);
    o_rob_alloc_req.is_fence_i  = (op == FENCE_I);
    o_rob_alloc_req.is_wfi      = i_from_id_to_ex.is_wfi;
    o_rob_alloc_req.is_mret     = i_from_id_to_ex.is_mret;
    o_rob_alloc_req.is_amo      = i_from_id_to_ex.is_amo_instruction;
    o_rob_alloc_req.is_lr       = i_from_id_to_ex.is_lr;
    o_rob_alloc_req.is_sc       = i_from_id_to_ex.is_sc;
    // Compressed instruction detection: opcode[1:0] != 2'b11
    o_rob_alloc_req.is_compressed = (i_from_id_to_ex.instruction.opcode[1:0] != 2'b11);

    // CSR info (stored in ROB for commit-time serialized execution)
    o_rob_alloc_req.csr_addr = i_from_id_to_ex.csr_address;
    o_rob_alloc_req.csr_op   = i_from_id_to_ex.instruction.funct3;
    // CSR write data: rs1 for register-based ops, zero-extended imm for immediate ops
    o_rob_alloc_req.csr_write_data =
      (op == CSRRWI || op == CSRRSI || op == CSRRCI) ?
        {{(XLEN - 5) {1'b0}}, i_from_id_to_ex.csr_imm} :
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
    o_rs_dispatch = '0;

    o_rs_dispatch.valid   = dispatch_fire && (rs_type != RS_NONE);
    o_rs_dispatch.rs_type = rs_type;
    o_rs_dispatch.rob_tag = i_rob_alloc_resp.alloc_tag;
    o_rs_dispatch.op      = op;

    // Source operands
    o_rs_dispatch.src1_ready = src1_ready;
    o_rs_dispatch.src1_tag   = src1_tag;
    o_rs_dispatch.src1_value = src1_value;

    o_rs_dispatch.src2_ready = src2_ready;
    o_rs_dispatch.src2_tag   = src2_tag;
    o_rs_dispatch.src2_value = src2_value;

    o_rs_dispatch.src3_ready = src3_ready;
    o_rs_dispatch.src3_tag   = src3_tag;
    o_rs_dispatch.src3_value = src3_value;

    // Immediate
    o_rs_dispatch.imm     = imm;
    o_rs_dispatch.use_imm = use_imm;

    // Rounding mode
    o_rs_dispatch.rm = resolved_rm;

    // Branch info
    o_rs_dispatch.branch_target    = branch_target;
    o_rs_dispatch.predicted_taken  = predicted_taken;
    o_rs_dispatch.predicted_target = predicted_target;

    // Memory info
    o_rs_dispatch.is_fp_mem  = is_fp_load_flag || is_fp_store_flag;
    o_rs_dispatch.mem_size   = mem_size;
    o_rs_dispatch.mem_signed = mem_signed;

    // CSR info
    o_rs_dispatch.csr_addr = i_from_id_to_ex.csr_address;
    o_rs_dispatch.csr_imm  = i_from_id_to_ex.csr_imm;

    // PC (for AUIPC, branch/jump link address computation)
    o_rs_dispatch.pc = i_from_id_to_ex.program_counter;
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
    o_ras_tos         = i_from_id_to_ex.ras_checkpoint_tos;
    o_ras_valid_count = i_from_id_to_ex.ras_checkpoint_valid_count;

    // ROB checkpoint recording (separate from RAT checkpoint)
    o_rob_checkpoint_valid = o_checkpoint_save;
    o_rob_checkpoint_id    = i_checkpoint_alloc_id;
  end

endmodule : dispatch
