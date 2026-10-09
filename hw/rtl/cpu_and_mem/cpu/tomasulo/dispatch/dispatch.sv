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
 * Dispatch up to two decoded instructions into the out-of-order back end.
 * Each firing instruction allocates a ROB entry, resolves RAT sources,
 * renames its destination, and routes to an RS or directly to the ROB.
 * Branches and jumps also save a checkpoint.
 *
 * Slot 2 requires slot 1 to fire. Admitted slots fire or stall together on
 * ROB, RS, queue, checkpoint, or recovery holds. FP compute in slot 2 is
 * deferred. Dispatch is combinational except for registered repair requests.
 *
 * A renamed source waits on its ROB tag for CDB or done-entry repair. The
 * repair request appears one cycle after dispatch; the wrapper wakes the RS
 * if that ROB entry is already done. Unrenamed sources use register-file data.
 *
 * JAL, WFI and xRET use RS_NONE. Their allocation flags let the ROB complete
 * and commit them without an RS.
 */

module dispatch #(
    // Use packet2.is_real for slot-2 presence. The decoded queue must provide
    // i_valid_2 == i_valid && packet2.is_real; the default uses i_valid_2.
    parameter bit SLOT2_VALID_FROM_BUNDLE = 1'b0,
    // Use bypassed integer register-file reads directly for packet values.
    // i_int_rf_* must also feed the RAT value inputs. Packet masks handle x0
    // and source use. With the default 0, i_int_rf_* is unused.
    parameter bit RAW_INT_RF_VALUES = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Instruction Input (from ID stage pipeline register)
    // =========================================================================
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    // Bundle-valid candidate, not yet qualified by flush. Dispatch applies
    // i_flush (below) as the only recovery qualification.
    input logic                      i_valid,

    // Slot 2 is a preflush candidate. An absent slot 2 leaves admission to slot 1.
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex_2,
    input logic                      i_valid_2,

    // Source addresses decoded in PD and registered in ID for RAT lookup.
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs1_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs2_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_fp_rs3_addr,

    // Slot-2 source addresses for RAT lookup and the intra-bundle RAW bypass.
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs1_addr_2,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs2_addr_2,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_fp_rs3_addr_2,

    // =========================================================================
    // FRM CSR (for dynamic rounding mode resolution)
    // =========================================================================
    input logic [2:0] i_frm_csr,

    // =========================================================================
    // ROB Allocation Interface (to/from tomasulo_wrapper)
    // =========================================================================
    output riscv_pkg::reorder_buffer_alloc_req_t  o_rob_alloc_req,
    input  riscv_pkg::reorder_buffer_alloc_resp_t i_rob_alloc_resp,

    // Slot-2 ROB allocation returns tail+1; alloc_valid is low unless slot 2 fires.
    output riscv_pkg::reorder_buffer_alloc_req_t  o_rob_alloc_req_2,
    input  riscv_pkg::reorder_buffer_alloc_resp_t i_rob_alloc_resp_2,

    // =========================================================================
    // RAT Source Lookups (combinational, from tomasulo_wrapper)
    // =========================================================================
    // Slot-1 addresses driven out to tomasulo_wrapper
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src1_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src2_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src1_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src2_addr,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src3_addr,

    // Slot-1 lookup results from tomasulo_wrapper
    input riscv_pkg::rat_lookup_t i_int_src1,
    input riscv_pkg::rat_lookup_t i_int_src2,
    input riscv_pkg::rat_lookup_t i_fp_src1,
    input riscv_pkg::rat_lookup_t i_fp_src2,
    input riscv_pkg::rat_lookup_t i_fp_src3,

    // Slot-2 addresses driven out to tomasulo_wrapper (2-wide dispatch)
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src1_addr_2,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_int_src2_addr_2,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src1_addr_2,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src2_addr_2,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_fp_src3_addr_2,

    // Slot-2 RAT results before bypassing slot 1's same-cycle rename.
    input riscv_pkg::rat_lookup_t i_int_src1_2,
    input riscv_pkg::rat_lookup_t i_int_src2_2,
    input riscv_pkg::rat_lookup_t i_fp_src1_2,
    input riscv_pkg::rat_lookup_t i_fp_src2_2,
    input riscv_pkg::rat_lookup_t i_fp_src3_2,

    // Bypassed integer register-file reads at i_rs1_addr/i_rs2_addr (slot 1)
    // and i_rs1_addr_2/i_rs2_addr_2 (slot 2): the RAT lookups' value source.
    // Used only with RAW_INT_RF_VALUES.
    input logic [riscv_pkg::XLEN-1:0] i_int_rf_rs1_data,
    input logic [riscv_pkg::XLEN-1:0] i_int_rf_rs2_data,
    input logic [riscv_pkg::XLEN-1:0] i_int_rf_rs1_data_2,
    input logic [riscv_pkg::XLEN-1:0] i_int_rf_rs2_data_2,

    // =========================================================================
    // RAT Rename (to tomasulo_wrapper: writes the dest mapping)
    // =========================================================================
    // Slot 1
    output logic                                        o_rat_alloc_valid,
    output logic                                        o_rat_alloc_dest_rf,   // 0=INT, 1=FP
    output logic [         riscv_pkg::RegAddrWidth-1:0] o_rat_alloc_dest_reg,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag,

    // Slot 2 renames its destination in the same cycle as slot 1.
    output logic                                        o_rat_alloc_valid_2,
    output logic                                        o_rat_alloc_dest_rf_2,
    output logic [         riscv_pkg::RegAddrWidth-1:0] o_rat_alloc_dest_reg_2,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag_2,

    // =========================================================================
    // ROB Done-Entry Repair Read Request (generic source ports)
    // =========================================================================
    // Repair channels 1-3 carry slot-1 source tags; channels 4-6 carry slot-2
    // tags. Requests appear one cycle after dispatch.
    output logic                                        o_bypass_valid_1,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_1,
    output logic                                        o_bypass_valid_2,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_2,
    output logic                                        o_bypass_valid_3,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_3,
    output logic                                        o_bypass_valid_4,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_4,
    output logic                                        o_bypass_valid_5,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_5,
    output logic                                        o_bypass_valid_6,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_bypass_tag_6,

    // =========================================================================
    // RS Dispatch (to tomasulo_wrapper)
    // =========================================================================
    output riscv_pkg::rs_dispatch_t o_rs_dispatch,
    output riscv_pkg::rs_dispatch_t o_int_rs_dispatch,
    output riscv_pkg::rs_dispatch_t o_mul_rs_dispatch,
    output riscv_pkg::rs_dispatch_t o_mem_rs_dispatch,
    output riscv_pkg::rs_dispatch_t o_fp_rs_dispatch,

    // Slot-2 packets: only the selected RS receives a valid packet.
    output riscv_pkg::rs_dispatch_t o_int_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_mul_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_mem_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_fp_rs_dispatch_2,

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
    // Slot-2-branch flag: when slot-2 is the branch the snapshot must
    // overlay slot-1's same-cycle rename.
    output logic                                        o_checkpoint_save_for_slot2,
    // Candidates before dispatch qualification. ANDing each o_alloc_has_dest
    // with the bundle fire gives its RAT allocation valid. During a checkpoint
    // save, o_checkpoint_slot2_candidate equals o_checkpoint_save_for_slot2.
    output logic                                        o_alloc_has_dest,
    output logic                                        o_alloc_has_dest_2,
    output logic                                        o_checkpoint_slot2_candidate,

    // RAS state to save with checkpoint
    input  logic [riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input  logic [  riscv_pkg::RasPtrBits:0] i_ras_valid_count,
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [  riscv_pkg::RasPtrBits:0] o_ras_valid_count,
    output logic [      riscv_pkg::XLEN-1:0] o_ras_top,

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
    input logic i_lq_full,
    input logic i_sq_full,

    // Two-slot room flags, conservative (they can block dispatch for a cycle
    // after room appears). Used when both slots need the same structure;
    // every two-slot bundle needs two ROB entries.
    input logic i_rob_full_for_2,
    input logic i_int_rs_full_for_2,
    input logic i_mul_rs_full_for_2,
    input logic i_mem_rs_full_for_2,
    input logic i_fp_rs_full_for_2,
    input logic i_lq_full_for_2,
    input logic i_sq_full_for_2,

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
  assign op = i_from_id_to_ex.is_fetch_fault ?
      (i_from_id_to_ex.is_fetch_fault_page ? riscv_pkg::FETCH_PAGE_FAULT :
                                             riscv_pkg::FETCH_FAULT) :
      i_from_id_to_ex.is_illegal_instruction ? riscv_pkg::ILLEGAL :
                                             i_from_id_to_ex.instruction_operation;

  // ID registers the RS route for dispatch.
  riscv_pkg::rs_type_e rs_type;
  assign rs_type = riscv_pkg::rs_type_e'(i_from_id_to_ex.rs_type);

  // Destination register classification
  logic has_dest;
  logic dest_rf;  // 0=INT, 1=FP
  logic [riscv_pkg::RegAddrWidth-1:0] dest_reg;

  // ID registers destination flags after applying illegal-instruction and
  // fetch-fault overrides, matching the decoded op.
  logic has_fp_dest_flag;
  logic has_int_dest_flag;
  assign has_fp_dest_flag  = i_from_id_to_ex.has_fp_dest;
  assign has_int_dest_flag = i_from_id_to_ex.has_int_dest;

  always_comb begin
    if (has_fp_dest_flag) begin
      has_dest = 1'b1;
      dest_rf  = 1'b1;
      dest_reg = i_from_id_to_ex.instruction.dest_reg;
    end else if (has_int_dest_flag) begin
      // Do not rename x0, but still allocate a ROB entry for the instruction.
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
  logic op_has_fp_flags;

  // ID registers the source-use flags alongside the destination flags.
  assign uses_fp_rs1_flag = i_from_id_to_ex.uses_fp_rs1;
  assign uses_fp_rs2_flag = i_from_id_to_ex.uses_fp_rs2;
  assign uses_fp_rs3_flag = i_from_id_to_ex.uses_fp_rs3;
  assign uses_int_rs1     = i_from_id_to_ex.uses_int_rs1;
  assign uses_int_rs2     = i_from_id_to_ex.uses_int_rs2;

  // An illegal FSW or FSD (FS=Off) keeps its decoded is_fp_store; the mask
  // keeps it from reaching the ROB and the reservation station as a store.
  assign is_store_flag    = i_from_id_to_ex.is_int_store;
  assign is_fp_store_flag = i_from_id_to_ex.is_fp_store && !i_from_id_to_ex.is_illegal_instruction;
  assign is_load_flag     = i_from_id_to_ex.is_load_instruction;
  assign is_fp_load_flag  = i_from_id_to_ex.is_fp_load;
  assign is_branch_flag   = i_from_id_to_ex.is_branch_or_jump;
  assign is_jal_flag      = i_from_id_to_ex.is_jump_and_link;
  assign is_jalr_flag     = i_from_id_to_ex.is_jump_and_link_register;
  assign op_has_fp_flags  = i_from_id_to_ex.has_fp_flags;

  // Reuse the ID-stage RAS classification so commit-time recovery matches the
  // IF-stage RAS detector. In particular, compressed `c.jalr t0` expands to
  // `jalr x1, x5, 0` and is a plain call in real code, not a return.
  assign is_call_flag     = i_from_id_to_ex.is_ras_call;
  assign is_return_flag   = i_from_id_to_ex.is_ras_return;

  // Memory operation size and sign
  riscv_pkg::mem_size_e mem_size;
  logic                 mem_signed;
  logic                 mem_size_defaulted;

  always_comb begin
    mem_size_defaulted = 1'b0;
    case (op)
      riscv_pkg::LB, riscv_pkg::LBU, riscv_pkg::SB: mem_size = riscv_pkg::MEM_SIZE_BYTE;
      riscv_pkg::LH, riscv_pkg::LHU, riscv_pkg::SH: mem_size = riscv_pkg::MEM_SIZE_HALF;
      riscv_pkg::LW, riscv_pkg::LWU, riscv_pkg::SW, riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      mem_size = riscv_pkg::MEM_SIZE_WORD;
      riscv_pkg::FLD, riscv_pkg::FSD, riscv_pkg::LD, riscv_pkg::SD,
      riscv_pkg::LR_D, riscv_pkg::SC_D,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D,
      riscv_pkg::AMOXOR_D, riscv_pkg::AMOAND_D, riscv_pkg::AMOOR_D,
      riscv_pkg::AMOMIN_D, riscv_pkg::AMOMAX_D,
      riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D:
      mem_size = riscv_pkg::MEM_SIZE_DOUBLE;
      default: begin
        mem_size = riscv_pkg::MEM_SIZE_WORD;
        mem_size_defaulted = 1'b1;
      end
    endcase

    // LB, LH, LW and LR.W sign-extend; LBU, LHU, LWU and FP loads do not.
    // LR uses OPC_AMO, so is_load_instruction alone would miss LR.W.
    // The flag is ignored for full-width LD and LR.D.
    mem_signed = (i_from_id_to_ex.is_load_instruction || i_from_id_to_ex.is_lr) &&
                 !i_from_id_to_ex.is_load_unsigned;
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
      // I-type immediate (loads and ALU-immediate operations)
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LWU, riscv_pkg::LD,
      riscv_pkg::ADDIW, riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW,
      // B-ext immediate forms
      riscv_pkg::BSETI, riscv_pkg::BCLRI, riscv_pkg::BINVI, riscv_pkg::BEXTI, riscv_pkg::RORI,
      riscv_pkg::SLLI_UW, riscv_pkg::RORIW: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_i_type;
      end

      // S-type immediate (stores)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::SD,
      riscv_pkg::FSW, riscv_pkg::FSD: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_s_type;
      end

      // U-type immediate
      riscv_pkg::LUI: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.immediate_u_type;
      end

      // AUIPC: ID precomputed PC + imm_u, so the ALU materializes it like LUI
      // and the station carries no PC.
      riscv_pkg::AUIPC: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.pc_relative_precomputed;
      end

      // JALR's link address is its ALU result in imm. The target's 12-bit
      // I-immediate travels separately in jalr_imm.
      riscv_pkg::JALR: begin
        use_imm = 1'b1;
        imm     = i_from_id_to_ex.link_address;
      end

      // Conditional branches: the precomputed PC-relative target rides the
      // otherwise unused immediate; branch_jump_unit reads it there.
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT, riscv_pkg::BGE,
      riscv_pkg::BLTU, riscv_pkg::BGEU: begin
        use_imm = 1'b0;
        imm     = i_from_id_to_ex.branch_target_precomputed;
      end

      // JAL is RS_NONE and never reaches a station; its packet carries the
      // precomputed target for consistency with the branches.
      riscv_pkg::JAL: begin
        use_imm = 1'b0;
        imm     = i_from_id_to_ex.jal_target_precomputed;
      end

      // Fetch-fault pseudo-ops: ID precomputed PC + the offset of the
      // faulting portion within the instruction (2 when only the second
      // halfword of a page-straddling instruction faulted, else 0); the INT
      // ALU shim reports the immediate as the exception's xtval.
      riscv_pkg::FETCH_FAULT, riscv_pkg::FETCH_PAGE_FAULT: begin
        use_imm = 1'b0;
        imm     = i_from_id_to_ex.pc_relative_precomputed;
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
    if (i_from_id_to_ex.btb_predicted_taken) begin
      predicted_taken  = 1'b1;
      predicted_target = i_from_id_to_ex.btb_predicted_target;
    end else begin
      predicted_taken  = 1'b0;
      predicted_target = '0;
    end
  end

  // Direct-branch target check: ID compared its precomputed PC-relative target
  // with the BTB prediction; JALR resolves its own target at execute.
  logic predicted_target_ok;
  assign predicted_target_ok = i_from_id_to_ex.btb_correct_non_jalr;

  // Branch target (pre-computed in ID stage)
  logic [riscv_pkg::XLEN-1:0] branch_target;
  always_comb begin
    if (is_jal_flag) branch_target = i_from_id_to_ex.jal_target_precomputed;
    else branch_target = i_from_id_to_ex.branch_target_precomputed;
  end

  // ===========================================================================
  // Slot-2 Instruction Classification (mirrors slot-1 above)
  // ===========================================================================
  // Decoded the same way as slot 1, from i_from_id_to_ex_2. When slot 2 does
  // not fire, its ROB, RAT, RS, and checkpoint valids stay low, and its
  // registered done-repair valids stay low on the next cycle.

  riscv_pkg::instr_op_e op_2;
  assign op_2 = i_from_id_to_ex_2.is_fetch_fault ?
      (i_from_id_to_ex_2.is_fetch_fault_page ? riscv_pkg::FETCH_PAGE_FAULT :
                                               riscv_pkg::FETCH_FAULT) :
      i_from_id_to_ex_2.is_illegal_instruction ? riscv_pkg::ILLEGAL :
                                               i_from_id_to_ex_2.instruction_operation;

  riscv_pkg::rs_type_e rs_type_2;
  assign rs_type_2 = riscv_pkg::rs_type_e'(i_from_id_to_ex_2.rs_type);

  // Slot-2 destination classification.
  logic has_dest_2;
  logic dest_rf_2;
  logic [riscv_pkg::RegAddrWidth-1:0] dest_reg_2;

  logic has_fp_dest_flag_2;
  logic has_int_dest_flag_2;
  assign has_fp_dest_flag_2  = i_from_id_to_ex_2.has_fp_dest;
  assign has_int_dest_flag_2 = i_from_id_to_ex_2.has_int_dest;

  always_comb begin
    if (has_fp_dest_flag_2) begin
      has_dest_2 = 1'b1;
      dest_rf_2  = 1'b1;
      dest_reg_2 = i_from_id_to_ex_2.instruction.dest_reg;
    end else if (has_int_dest_flag_2) begin
      has_dest_2 = (i_from_id_to_ex_2.instruction.dest_reg != 5'b0);
      dest_rf_2  = 1'b0;
      dest_reg_2 = i_from_id_to_ex_2.instruction.dest_reg;
    end else begin
      has_dest_2 = 1'b0;
      dest_rf_2  = 1'b0;
      dest_reg_2 = '0;
    end
  end

  // Slot-2 source classification.
  logic uses_int_rs1_2, uses_int_rs2_2;
  logic uses_fp_rs1_flag_2, uses_fp_rs2_flag_2, uses_fp_rs3_flag_2;
  logic is_store_flag_2, is_fp_store_flag_2, is_load_flag_2, is_fp_load_flag_2;
  logic is_branch_flag_2, is_call_flag_2, is_return_flag_2;
  logic is_jal_flag_2, is_jalr_flag_2;
  logic op_has_fp_flags_2;

  assign uses_fp_rs1_flag_2 = i_from_id_to_ex_2.uses_fp_rs1;
  assign uses_fp_rs2_flag_2 = i_from_id_to_ex_2.uses_fp_rs2;
  assign uses_fp_rs3_flag_2 = i_from_id_to_ex_2.uses_fp_rs3;
  assign uses_int_rs1_2 = i_from_id_to_ex_2.uses_int_rs1;
  assign uses_int_rs2_2 = i_from_id_to_ex_2.uses_int_rs2;

  assign is_store_flag_2 = i_from_id_to_ex_2.is_int_store;
  assign is_fp_store_flag_2 =
      i_from_id_to_ex_2.is_fp_store && !i_from_id_to_ex_2.is_illegal_instruction;
  assign is_load_flag_2 = i_from_id_to_ex_2.is_load_instruction;
  assign is_fp_load_flag_2 = i_from_id_to_ex_2.is_fp_load;
  assign is_branch_flag_2 = i_from_id_to_ex_2.is_branch_or_jump;
  assign is_jal_flag_2 = i_from_id_to_ex_2.is_jump_and_link;
  assign is_jalr_flag_2 = i_from_id_to_ex_2.is_jump_and_link_register;
  assign op_has_fp_flags_2 = i_from_id_to_ex_2.has_fp_flags;
  assign is_call_flag_2 = i_from_id_to_ex_2.is_ras_call;
  assign is_return_flag_2 = i_from_id_to_ex_2.is_ras_return;

  // Slot-2 memory size + sign.
  riscv_pkg::mem_size_e mem_size_2;
  logic                 mem_signed_2;
  logic                 mem_size_2_defaulted;

  always_comb begin
    mem_size_2_defaulted = 1'b0;
    case (op_2)
      riscv_pkg::LB, riscv_pkg::LBU, riscv_pkg::SB: mem_size_2 = riscv_pkg::MEM_SIZE_BYTE;
      riscv_pkg::LH, riscv_pkg::LHU, riscv_pkg::SH: mem_size_2 = riscv_pkg::MEM_SIZE_HALF;
      riscv_pkg::LW, riscv_pkg::LWU, riscv_pkg::SW, riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      mem_size_2 = riscv_pkg::MEM_SIZE_WORD;
      riscv_pkg::FLD, riscv_pkg::FSD, riscv_pkg::LD, riscv_pkg::SD,
      riscv_pkg::LR_D, riscv_pkg::SC_D,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D,
      riscv_pkg::AMOXOR_D, riscv_pkg::AMOAND_D, riscv_pkg::AMOOR_D,
      riscv_pkg::AMOMIN_D, riscv_pkg::AMOMAX_D,
      riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D:
      mem_size_2 = riscv_pkg::MEM_SIZE_DOUBLE;
      default: begin
        mem_size_2 = riscv_pkg::MEM_SIZE_WORD;
        mem_size_2_defaulted = 1'b1;
      end
    endcase

    // Includes is_lr for LR.W's sign extension; see slot 1's mem_signed.
    mem_signed_2 = (i_from_id_to_ex_2.is_load_instruction || i_from_id_to_ex_2.is_lr) &&
                   !i_from_id_to_ex_2.is_load_unsigned;
  end

  // Slot-2 FP rounding mode.
  logic [2:0] resolved_rm_2;
  always_comb begin
    if (i_from_id_to_ex_2.fp_rm == 3'b111) resolved_rm_2 = i_frm_csr;
    else resolved_rm_2 = i_from_id_to_ex_2.fp_rm;
  end

  // Slot-2 immediate.
  logic [riscv_pkg::XLEN-1:0] imm_2;
  logic                       use_imm_2;

  always_comb begin
    use_imm_2 = 1'b0;
    imm_2     = '0;

    case (op_2)
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LWU, riscv_pkg::LD,
      riscv_pkg::ADDIW, riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW,
      riscv_pkg::BSETI, riscv_pkg::BCLRI, riscv_pkg::BINVI, riscv_pkg::BEXTI, riscv_pkg::RORI,
      riscv_pkg::SLLI_UW, riscv_pkg::RORIW: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_i_type;
      end

      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::SD,
      riscv_pkg::FSW, riscv_pkg::FSD: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_s_type;
      end

      riscv_pkg::LUI: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_u_type;
      end

      // AUIPC: precomputed PC + imm_u (see slot 1).
      riscv_pkg::AUIPC: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.pc_relative_precomputed;
      end

      // JALR: link address in imm, I-immediate in jalr_imm (see slot 1).
      riscv_pkg::JALR: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.link_address;
      end

      // Conditional branches and JAL: precomputed PC-relative target (see slot 1).
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT, riscv_pkg::BGE,
      riscv_pkg::BLTU, riscv_pkg::BGEU: begin
        use_imm_2 = 1'b0;
        imm_2     = i_from_id_to_ex_2.branch_target_precomputed;
      end

      riscv_pkg::JAL: begin
        use_imm_2 = 1'b0;
        imm_2     = i_from_id_to_ex_2.jal_target_precomputed;
      end

      // Fetch-fault pseudo-ops: precomputed xtval (see slot 1).
      riscv_pkg::FETCH_FAULT, riscv_pkg::FETCH_PAGE_FAULT: begin
        use_imm_2 = 1'b0;
        imm_2     = i_from_id_to_ex_2.pc_relative_precomputed;
      end

      default: begin
        use_imm_2 = 1'b0;
        imm_2     = '0;
      end
    endcase
  end

  // Slot-2 predicted branch info.
  logic                       predicted_taken_2;
  logic [riscv_pkg::XLEN-1:0] predicted_target_2;

  always_comb begin
    if (i_from_id_to_ex_2.btb_predicted_taken) begin
      predicted_taken_2  = 1'b1;
      predicted_target_2 = i_from_id_to_ex_2.btb_predicted_target;
    end else begin
      predicted_taken_2  = 1'b0;
      predicted_target_2 = '0;
    end
  end

  // Slot-2 direct-branch target check (see slot 1).
  logic predicted_target_ok_2;
  assign predicted_target_ok_2 = i_from_id_to_ex_2.btb_correct_non_jalr;

  // Slot-2 branch target.
  logic [riscv_pkg::XLEN-1:0] branch_target_2;
  always_comb begin
    if (is_jal_flag_2) branch_target_2 = i_from_id_to_ex_2.jal_target_precomputed;
    else branch_target_2 = i_from_id_to_ex_2.branch_target_precomputed;
  end

  // ===========================================================================
  // Stall Logic
  // ===========================================================================

  // Keep the registered RS-route selection separate for timing.
  (* keep = "true" *) logic rs_full;
  always_comb begin
    case (rs_type)
      riscv_pkg::RS_INT: rs_full = i_int_rs_full;
      riscv_pkg::RS_MUL: rs_full = i_mul_rs_full;
      riscv_pkg::RS_MEM: rs_full = i_mem_rs_full;
      riscv_pkg::RS_FP: rs_full = i_fp_rs_full;
      riscv_pkg::RS_NONE: rs_full = 1'b0;  // No RS needed
      default: rs_full = 1'b0;
    endcase
  end

  // ID clears queue needs for illegal instructions and fetch faults. They
  // route to INT_RS and must not wait for load/store queue space.
  logic need_lq, need_sq;
  assign need_lq = i_from_id_to_ex.needs_lq;
  assign need_sq = i_from_id_to_ex.needs_sq;

  logic need_checkpoint;
  assign need_checkpoint = is_branch_flag;

  logic dispatch_valid;
  assign dispatch_valid = i_valid && !i_flush;

  // Slot-2 resource needs. When slot 2 is absent these are don't-cares:
  // slot2_bundle_ok is 1 and o_stall reduces to slot 1's condition.
  logic need_lq_2, need_sq_2;
  assign need_lq_2 = i_from_id_to_ex_2.needs_lq;
  assign need_sq_2 = i_from_id_to_ex_2.needs_sq;

  logic need_checkpoint_2;
  assign need_checkpoint_2 = is_branch_flag_2;

  logic dispatch_valid_2;
  logic slot2_fp_compute_serialized;
  assign slot2_fp_compute_serialized = (rs_type_2 == riscv_pkg::RS_FP);
  assign dispatch_valid_2 = i_valid_2 && !i_flush && !slot2_fp_compute_serialized;

  // Two slots targeting the same RS need two free entries; otherwise one suffices.
  logic rs_full_for_slot2;
  always_comb begin
    case (rs_type_2)
      riscv_pkg::RS_INT:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_INT) ? i_int_rs_full_for_2 : i_int_rs_full;
      riscv_pkg::RS_MUL:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_MUL) ? i_mul_rs_full_for_2 : i_mul_rs_full;
      riscv_pkg::RS_MEM:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_MEM) ? i_mem_rs_full_for_2 : i_mem_rs_full;
      // FP compute in slot 2 is deferred (dispatch_valid_2=0), so it needs no
      // FP_RS space this cycle.
      riscv_pkg::RS_FP: rs_full_for_slot2 = 1'b0;
      riscv_pkg::RS_NONE: rs_full_for_slot2 = 1'b0;
      default: rs_full_for_slot2 = 1'b0;
    endcase
  end

  // Slot-2 queue capacity, accounting for slot 1.
  logic lq_full_for_slot2;
  logic sq_full_for_slot2;
  assign lq_full_for_slot2 = need_lq ? i_lq_full_for_2 : i_lq_full;
  assign sq_full_for_slot2 = need_sq ? i_sq_full_for_2 : i_sq_full;

  (* max_fanout = 64 *)logic bundle_fire_ok;  // Whole bundle fires (slot-1 + optional slot-2)
  logic slot2_only_block;

  always_comb begin
    o_status = '0;
    o_status.dispatch_valid = dispatch_valid;
    o_status.reorder_buffer_full = dispatch_valid && i_rob_full;
    o_status.int_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_INT) && i_int_rs_full;
    o_status.mul_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_MUL) && i_mul_rs_full;
    o_status.mem_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_MEM) && i_mem_rs_full;
    o_status.fp_rs_full = dispatch_valid && (rs_type == riscv_pkg::RS_FP) && i_fp_rs_full;
    o_status.lq_full = dispatch_valid && need_lq && i_lq_full;
    o_status.sq_full = dispatch_valid && need_sq && i_sq_full;
    o_status.checkpoint_full = dispatch_valid && need_checkpoint && !i_checkpoint_available;

    // The block_* counters count cycles where slot 2 alone blocks a bundle
    // that slot 1 could dispatch. Slot-1 stalls are counted above.
    o_status.slot2_present = i_valid_2 && !i_flush;
    o_status.slot2_fp_serialized = i_valid_2 && !i_flush && slot2_fp_compute_serialized;
    o_status.slot2_block_s1_branch = slot2_only_block && is_branch_flag;
    o_status.slot2_block_rob_full2 = slot2_only_block && i_rob_full_for_2;
    o_status.slot2_block_rs_full2 = slot2_only_block && rs_full_for_slot2;
    o_status.slot2_block_lsq_full2 = slot2_only_block && ((need_lq_2 && lq_full_for_slot2) ||
                                                          (need_sq_2 && sq_full_for_slot2));
    o_status.slot2_block_ckpt = slot2_only_block && need_checkpoint_2 && !i_checkpoint_available;

    // With no slot 2, only slot 1 can stall. Otherwise both slots wait, and
    // the front end must hold the bundle; there is no skid buffer.
    //
    // o_stall must mean "a valid dispatch was blocked". It feeds
    // replay_after_dispatch_stall_q in frontend_validity_tracker, which can
    // revalidate held ID contents. Without dispatch_valid, a resource becoming
    // full after dispatch could replay the same instruction. Other front-end
    // holds may assert while dispatch is invalid, but this replay source must
    // stay qualified. Registering the stall would also require capture storage.
    o_stall = dispatch_valid && !bundle_fire_ok;
    // Count back-pressure only for a valid dispatch.
    o_status.stall = dispatch_valid && !bundle_fire_ok;
  end

  // Separate per-RS fire terms and fanout limits localize dispatch enables.
  (* max_fanout = 64 *)logic dispatch_common_ready;
  (* max_fanout = 64 *)logic dispatch_fire;
  (* max_fanout = 64 *)logic slot1_can_fire;  // Slot-1 standalone gate
  // Slot-2 gate, conditional on slot1_can_fire.
  (* keep = "true", max_fanout = 64 *)logic slot2_can_fire;
  logic slot2_resources_ok;
  (* max_fanout = 64 *)logic slot2_bundle_ok;
  logic int_rs_dispatch_fire;
  logic mul_rs_dispatch_fire;
  logic mem_rs_dispatch_fire;
  logic fp_rs_dispatch_fire;
  logic int_rs_dispatch_fire_2;
  logic mul_rs_dispatch_fire_2;
  logic mem_rs_dispatch_fire_2;
  logic fp_rs_dispatch_fire_2;

  assign dispatch_common_ready =
      dispatch_valid &&
      !i_hold &&
      !i_rob_full &&
      !(need_lq && i_lq_full) &&
      !(need_sq && i_sq_full) &&
      !(need_checkpoint && !i_checkpoint_available);
  assign slot1_can_fire = dispatch_common_ready && !rs_full;
  // A slot-1 branch or jump ends the bundle. Slot 2 requires slot 1 to fire
  // and enough space for both slots in each shared resource.
  //
  // A producer already done does not block slot 2: repair channels 4 and 5
  // wake its sources the cycle after dispatch, as channels 1-3 do for slot 1.

  assign slot2_resources_ok = !is_branch_flag &&  // slot-1 not a branch
      !i_rob_full_for_2 &&
      !rs_full_for_slot2 &&
      !(need_lq_2 && lq_full_for_slot2) &&
      !(need_sq_2 && sq_full_for_slot2) &&
      !(need_checkpoint_2 && !i_checkpoint_available);
  logic slot2_present_for_admission;
  assign slot2_present_for_admission = SLOT2_VALID_FROM_BUNDLE ?
      (i_from_id_to_ex_2.is_real && !slot2_fp_compute_serialized) : dispatch_valid_2;
  assign slot2_can_fire = slot1_can_fire && slot2_present_for_admission && slot2_resources_ok;
  assign slot2_bundle_ok = !slot2_present_for_admission || slot2_resources_ok;
  // Count cycles where slot 2 alone blocks dispatch.
  assign slot2_only_block = dispatch_valid_2 && slot1_can_fire && !slot2_resources_ok;
  // Both admitted slots fire together; absent slot 2 adds no restriction.
  assign bundle_fire_ok = slot1_can_fire && slot2_bundle_ok;
  assign dispatch_fire = bundle_fire_ok;

`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (!$isunknown({dispatch_valid, dispatch_valid_2, slot2_present_for_admission})) begin
      p_queued_slot2_valid_contract :
      assert (!SLOT2_VALID_FROM_BUNDLE || !dispatch_valid ||
              (dispatch_valid_2 == slot2_present_for_admission));
      p_bundle_admission_exact :
      assert (bundle_fire_ok == (slot1_can_fire && (!dispatch_valid_2 || slot2_resources_ok)));
      p_slot2_admission_exact :
      assert (slot2_can_fire == (slot1_can_fire && dispatch_valid_2 && slot2_resources_ok));
    end
  end
`endif
`ifdef DISPATCH_ADMISSION_LOCAL_PROOF
  always_comb begin
    if (SLOT2_VALID_FROM_BUNDLE && dispatch_valid) assume (i_valid_2 == i_from_id_to_ex_2.is_real);
    // Only FMA ops read FP source 3, and they route to FP_RS. ID and the
    // decoded queue carry both fields together, clearing source 3 use on
    // reset and flush.
    if (i_from_id_to_ex_2.uses_fp_rs3) assume (rs_type_2 == riscv_pkg::RS_FP);
    p_slot2_no_fp_source3 : assert (!(slot2_can_fire && uses_fp_rs3_flag_2));
    p_bundle_admission_formal :
    assert (bundle_fire_ok == (slot1_can_fire && (!dispatch_valid_2 || slot2_resources_ok)));
    p_slot2_admission_formal :
    assert (slot2_can_fire == (slot1_can_fire && dispatch_valid_2 && slot2_resources_ok));
  end
`endif


  assign int_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_INT) && !i_int_rs_full &&
      slot2_bundle_ok;
  assign mul_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_MUL) && !i_mul_rs_full &&
      slot2_bundle_ok;
  assign mem_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_MEM) && !i_mem_rs_full &&
      slot2_bundle_ok;
  assign fp_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_FP) && !i_fp_rs_full &&
      slot2_bundle_ok;

  assign int_rs_dispatch_fire_2 = slot2_can_fire && (rs_type_2 == riscv_pkg::RS_INT);
  assign mul_rs_dispatch_fire_2 = slot2_can_fire && (rs_type_2 == riscv_pkg::RS_MUL);
  assign mem_rs_dispatch_fire_2 = slot2_can_fire && (rs_type_2 == riscv_pkg::RS_MEM);
  assign fp_rs_dispatch_fire_2 = slot2_can_fire && (rs_type_2 == riscv_pkg::RS_FP);

  // ===========================================================================
  // RAT Source Address Outputs
  // ===========================================================================
  // INT and FP lookups share source addresses. Packet builders select the
  // register family; FP stores use an INT base and FP data.

  assign o_int_src1_addr = i_rs1_addr;
  assign o_int_src2_addr = i_rs2_addr;
  assign o_fp_src1_addr = i_rs1_addr;
  assign o_fp_src2_addr = i_rs2_addr;
  assign o_fp_src3_addr = i_fp_rs3_addr;

  // The intra-bundle bypass overrides RAT results, not lookup addresses.
  assign o_int_src1_addr_2 = i_rs1_addr_2;
  assign o_int_src2_addr_2 = i_rs2_addr_2;
  assign o_fp_src1_addr_2 = i_rs1_addr_2;
  assign o_fp_src2_addr_2 = i_rs2_addr_2;
  assign o_fp_src3_addr_2 = i_fp_rs3_addr_2;

  // ===========================================================================
  // Source Operand Resolution
  // ===========================================================================

  logic                                        int_src1_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] int_src1_tag;
  logic [                 riscv_pkg::FLEN-1:0] int_src1_value;

  logic                                        int_src2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] int_src2_tag;
  logic [                 riscv_pkg::FLEN-1:0] int_src2_value;

  logic                                        fp_src1_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src1_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src1_value;

  logic                                        fp_src2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src2_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src2_value;

  logic                                        fp_src3_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src3_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src3_value;

  logic                                        bypass_valid_1_next;
  logic                                        bypass_valid_2_next;
  logic                                        bypass_valid_3_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_1_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_2_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_3_next;
  logic                                        bypass_valid_4_next;
  logic                                        bypass_valid_5_next;
  logic                                        bypass_valid_6_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_4_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_5_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] bypass_tag_6_next;

  always_comb begin
    bypass_valid_1_next = 1'b0;
    bypass_tag_1_next   = '0;
    if (uses_fp_rs1_flag) begin
      bypass_valid_1_next = i_fp_src1.renamed;
      bypass_tag_1_next   = i_fp_src1.tag;
    end else if (uses_int_rs1) begin
      bypass_valid_1_next = i_int_src1.renamed;
      bypass_tag_1_next   = i_int_src1.tag;
    end

    bypass_valid_2_next = 1'b0;
    bypass_tag_2_next   = '0;
    if (uses_fp_rs2_flag) begin
      bypass_valid_2_next = i_fp_src2.renamed;
      bypass_tag_2_next   = i_fp_src2.tag;
    end else if (uses_int_rs2) begin
      bypass_valid_2_next = i_int_src2.renamed;
      bypass_tag_2_next   = i_int_src2.tag;
    end

    bypass_valid_3_next = 1'b0;
    bypass_tag_3_next   = '0;
    if (uses_fp_rs3_flag) begin
      bypass_valid_3_next = i_fp_src3.renamed;
      bypass_tag_3_next   = i_fp_src3.tag;
    end
  end

  // Effective slot-2 lookup results after intra-bundle RAW override.
  riscv_pkg::rat_lookup_t int_src1_2_eff;
  riscv_pkg::rat_lookup_t int_src2_2_eff;
  riscv_pkg::rat_lookup_t fp_src1_2_eff;
  riscv_pkg::rat_lookup_t fp_src2_2_eff;
  riscv_pkg::rat_lookup_t fp_src3_2_eff;

  // Repair channels 4 and 5 use the bypassed tags. An intra-bundle RAW uses
  // slot 1's new ROB tag, which is not done at the repair read; other sources
  // use the RAT tag.
  always_comb begin
    bypass_valid_4_next = 1'b0;
    bypass_tag_4_next   = '0;
    if (uses_fp_rs1_flag_2) begin
      bypass_valid_4_next = fp_src1_2_eff.renamed;
      bypass_tag_4_next   = fp_src1_2_eff.tag;
    end else if (uses_int_rs1_2) begin
      bypass_valid_4_next = int_src1_2_eff.renamed;
      bypass_tag_4_next   = int_src1_2_eff.tag;
    end

    bypass_valid_5_next = 1'b0;
    bypass_tag_5_next   = '0;
    if (uses_fp_rs2_flag_2) begin
      bypass_valid_5_next = fp_src2_2_eff.renamed;
      bypass_tag_5_next   = fp_src2_2_eff.tag;
    end else if (uses_int_rs2_2) begin
      bypass_valid_5_next = int_src2_2_eff.renamed;
      bypass_tag_5_next   = int_src2_2_eff.tag;
    end

    // Channel 6 is unused: only FMA reads FP source 3, and FP compute ops
    // do not dispatch in slot 2.
    bypass_valid_6_next = 1'b0;
    bypass_tag_6_next   = '0;
  end

`ifndef SYNTHESIS
  // The tie-off above is exact: a firing slot 2 never reads FP source 3.
  always_ff @(posedge i_clk) begin
    if (i_rst_n)
      assert (!(slot2_can_fire && uses_fp_rs3_flag_2))
      else $error("dispatch: slot 2 fired with an FP source 3");
  end
`endif

  // Register repair requests for the cycle after dispatch. Valid bits
  // qualify the tags, which need no reset. Slot-2 requests require slot 2
  // to fire, not just slot 1.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      o_bypass_valid_1 <= 1'b0;
      o_bypass_valid_2 <= 1'b0;
      o_bypass_valid_3 <= 1'b0;
      o_bypass_valid_4 <= 1'b0;
      o_bypass_valid_5 <= 1'b0;
      o_bypass_valid_6 <= 1'b0;
    end else begin
      o_bypass_valid_1 <= dispatch_fire && bypass_valid_1_next;
      o_bypass_valid_2 <= dispatch_fire && bypass_valid_2_next;
      o_bypass_valid_3 <= dispatch_fire && bypass_valid_3_next;
      o_bypass_valid_4 <= slot2_can_fire && bypass_valid_4_next;
      o_bypass_valid_5 <= slot2_can_fire && bypass_valid_5_next;
      o_bypass_valid_6 <= slot2_can_fire && bypass_valid_6_next;
    end
  end

  // Limit repair-tag fanout to the stations.
  (* max_fanout = 48 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      bypass_tag_1_q,
      bypass_tag_2_q,
      bypass_tag_3_q,
      bypass_tag_4_q,
      bypass_tag_5_q,
      bypass_tag_6_q;
  always_ff @(posedge i_clk) begin
    bypass_tag_1_q <= bypass_tag_1_next;
    bypass_tag_2_q <= bypass_tag_2_next;
    bypass_tag_3_q <= bypass_tag_3_next;
    bypass_tag_4_q <= bypass_tag_4_next;
    bypass_tag_5_q <= bypass_tag_5_next;
    bypass_tag_6_q <= bypass_tag_6_next;
  end
  assign o_bypass_tag_1 = bypass_tag_1_q;
  assign o_bypass_tag_2 = bypass_tag_2_q;
  assign o_bypass_tag_3 = bypass_tag_3_q;
  assign o_bypass_tag_4 = bypass_tag_4_q;
  assign o_bypass_tag_5 = bypass_tag_5_q;
  assign o_bypass_tag_6 = bypass_tag_6_q;

  // Renamed sources wait for CDB or registered done-repair wakeup. Each RS
  // packet selects the INT or FP source family it consumes.
  always_comb begin
    int_src1_ready = !i_int_src1.renamed;
    int_src1_value = i_int_src1.value;
    int_src1_tag   = i_int_src1.tag;
  end

  always_comb begin
    int_src2_ready = !i_int_src2.renamed;
    int_src2_value = i_int_src2.value;
    int_src2_tag   = i_int_src2.tag;
  end

  always_comb begin
    fp_src1_ready = !i_fp_src1.renamed;
    fp_src1_value = i_fp_src1.value;
    fp_src1_tag   = i_fp_src1.tag;
  end

  always_comb begin
    fp_src2_ready = !i_fp_src2.renamed;
    fp_src2_value = i_fp_src2.value;
    fp_src2_tag   = i_fp_src2.tag;
  end

  always_comb begin
    fp_src3_ready = !i_fp_src3.renamed;
    fp_src3_value = i_fp_src3.value;
    fp_src3_tag   = i_fp_src3.tag;
  end

  // ---------------------------------------------------------------------------
  // Slot-2 source resolution with intra-bundle RAW bypass
  // ---------------------------------------------------------------------------
  // If a slot-2 source matches slot 1's destination register and family,
  // replace its RAT result with an unready source using slot 1's new ROB tag.
  // The RAT result precedes the rename and may describe an older producer.

  // has_dest excludes INT x0 but allows every FP register.
  logic slot1_dest_int;
  logic slot1_dest_fp;
  assign slot1_dest_int = has_dest && !dest_rf;
  assign slot1_dest_fp  = has_dest && dest_rf;

  logic intra_bundle_int_src1_2;
  logic intra_bundle_int_src2_2;
  assign intra_bundle_int_src1_2 = slot1_dest_int && (i_rs1_addr_2 != '0) &&
                                   (dest_reg == i_rs1_addr_2);
  assign intra_bundle_int_src2_2 = slot1_dest_int && (i_rs2_addr_2 != '0) &&
                                   (dest_reg == i_rs2_addr_2);

  // FP register 0 is writable, so it needs no zero-address guard.
  logic intra_bundle_fp_src1_2;
  logic intra_bundle_fp_src2_2;
  logic intra_bundle_fp_src3_2;
  assign intra_bundle_fp_src1_2 = slot1_dest_fp && (dest_reg == i_rs1_addr_2);
  assign intra_bundle_fp_src2_2 = slot1_dest_fp && (dest_reg == i_rs2_addr_2);
  assign intra_bundle_fp_src3_2 = slot1_dest_fp && (dest_reg == i_fp_rs3_addr_2);

  always_comb begin
    if (intra_bundle_int_src1_2) begin
      int_src1_2_eff.renamed = 1'b1;
      int_src1_2_eff.tag     = i_rob_alloc_resp.alloc_tag;
      int_src1_2_eff.value   = '0;
    end else begin
      int_src1_2_eff = i_int_src1_2;
    end
    if (intra_bundle_int_src2_2) begin
      int_src2_2_eff.renamed = 1'b1;
      int_src2_2_eff.tag     = i_rob_alloc_resp.alloc_tag;
      int_src2_2_eff.value   = '0;
    end else begin
      int_src2_2_eff = i_int_src2_2;
    end
    if (intra_bundle_fp_src1_2) begin
      fp_src1_2_eff.renamed = 1'b1;
      fp_src1_2_eff.tag     = i_rob_alloc_resp.alloc_tag;
      fp_src1_2_eff.value   = '0;
    end else begin
      fp_src1_2_eff = i_fp_src1_2;
    end
    if (intra_bundle_fp_src2_2) begin
      fp_src2_2_eff.renamed = 1'b1;
      fp_src2_2_eff.tag     = i_rob_alloc_resp.alloc_tag;
      fp_src2_2_eff.value   = '0;
    end else begin
      fp_src2_2_eff = i_fp_src2_2;
    end
    if (intra_bundle_fp_src3_2) begin
      fp_src3_2_eff.renamed = 1'b1;
      fp_src3_2_eff.tag     = i_rob_alloc_resp.alloc_tag;
      fp_src3_2_eff.value   = '0;
    end else begin
      fp_src3_2_eff = i_fp_src3_2;
    end
  end

  // Resolved slot-2 operands for the per-RS packet builders.
  logic                                        int_src1_2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] int_src1_2_tag;
  logic [                 riscv_pkg::FLEN-1:0] int_src1_2_value;
  logic                                        int_src2_2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] int_src2_2_tag;
  logic [                 riscv_pkg::FLEN-1:0] int_src2_2_value;
  logic                                        fp_src1_2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src1_2_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src1_2_value;
  logic                                        fp_src2_2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src2_2_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src2_2_value;
  logic                                        fp_src3_2_ready;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_src3_2_tag;
  logic [                 riscv_pkg::FLEN-1:0] fp_src3_2_value;

  always_comb begin
    int_src1_2_ready = !int_src1_2_eff.renamed;
    int_src1_2_tag   = int_src1_2_eff.tag;
    int_src1_2_value = int_src1_2_eff.value;
    int_src2_2_ready = !int_src2_2_eff.renamed;
    int_src2_2_tag   = int_src2_2_eff.tag;
    int_src2_2_value = int_src2_2_eff.value;
    fp_src1_2_ready  = !fp_src1_2_eff.renamed;
    fp_src1_2_tag    = fp_src1_2_eff.tag;
    fp_src1_2_value  = fp_src1_2_eff.value;
    fp_src2_2_ready  = !fp_src2_2_eff.renamed;
    fp_src2_2_tag    = fp_src2_2_eff.tag;
    fp_src2_2_value  = fp_src2_2_eff.value;
    fp_src3_2_ready  = !fp_src3_2_eff.renamed;
    fp_src3_2_tag    = fp_src3_2_eff.tag;
    fp_src3_2_value  = fp_src3_2_eff.value;
  end

  // ---------------------------------------------------------------------------
  // INT source values for the per-RS packets
  // ---------------------------------------------------------------------------
  // Each INT packet value is masked by source use, the x0 check, and, in
  // slot 2, the absence of an intra-bundle RAW. A RAW value arrives from
  // slot 1's result. RAW_INT_RF_VALUES combines these masks for timing.
  logic [riscv_pkg::FLEN-1:0] int_src1_read, int_src2_read;
  logic [riscv_pkg::FLEN-1:0] int_src1_2_read, int_src2_2_read;
  assign int_src1_read = RAW_INT_RF_VALUES ?
      {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, i_int_rf_rs1_data} : i_int_src1.value;
  assign int_src2_read = RAW_INT_RF_VALUES ?
      {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, i_int_rf_rs2_data} : i_int_src2.value;
  assign int_src1_2_read = RAW_INT_RF_VALUES ?
      {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, i_int_rf_rs1_data_2} : i_int_src1_2.value;
  assign int_src2_2_read = RAW_INT_RF_VALUES ?
      {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, i_int_rf_rs2_data_2} : i_int_src2_2.value;

  // Read qualifiers: for slot 2, no RAW on slot 1's destination, and with
  // RAW_INT_RF_VALUES a nonzero source register (the lookup value already
  // reads x0 as zero).
  logic int_src1_read_ok, int_src2_read_ok, int_src1_2_read_ok, int_src2_2_read_ok;
  assign int_src1_read_ok = !RAW_INT_RF_VALUES || (i_rs1_addr != '0);
  assign int_src2_read_ok = !RAW_INT_RF_VALUES || (i_rs2_addr != '0);
  assign int_src1_2_read_ok = (!RAW_INT_RF_VALUES || (i_rs1_addr_2 != '0)) &&
                              !intra_bundle_int_src1_2;
  assign int_src2_2_read_ok = (!RAW_INT_RF_VALUES || (i_rs2_addr_2 != '0)) &&
                              !intra_bundle_int_src2_2;

  // Packet masks: INT_RS and MEM_RS read INT rs1 when they use it, INT_RS
  // and the INT form of MEM_RS rs2 likewise, MUL_RS always reads both, and
  // FP_RS (and the combined packet) read INT rs1 only without an FP rs1.
  logic int_use1_mask, int_use2_mask, mul_use1_mask, mul_use2_mask;
  logic fp_int_use1_mask;
  logic int_use1_mask_2, int_use2_mask_2, mul_use1_mask_2, mul_use2_mask_2;
  logic fp_int_use1_mask_2;
  assign int_use1_mask      = uses_int_rs1 && int_src1_read_ok;
  assign int_use2_mask      = uses_int_rs2 && int_src2_read_ok;
  assign mul_use1_mask      = int_src1_read_ok;
  assign mul_use2_mask      = int_src2_read_ok;
  assign fp_int_use1_mask   = !uses_fp_rs1_flag && uses_int_rs1 && int_src1_read_ok;
  assign int_use1_mask_2    = uses_int_rs1_2 && int_src1_2_read_ok;
  assign int_use2_mask_2    = uses_int_rs2_2 && int_src2_2_read_ok;
  assign mul_use1_mask_2    = int_src1_2_read_ok;
  assign mul_use2_mask_2    = int_src2_2_read_ok;
  assign fp_int_use1_mask_2 = !uses_fp_rs1_flag_2 && uses_int_rs1_2 && int_src1_2_read_ok;

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
    // Fetch-fault bytes may decode as jumps or serializing instructions.
    // Clear these class bits so the ROB waits for the INT shim to report the
    // exception, rather than marking the entry done at allocation and losing
    // the fault before its CDB completion.
    o_rob_alloc_req.is_jal = is_jal_flag && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_jalr = is_jalr_flag && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_csr = i_from_id_to_ex.is_csr_instruction;
    o_rob_alloc_req.is_fence = i_from_id_to_ex.is_fence && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_fence_i = i_from_id_to_ex.is_fence_i && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_wfi = i_from_id_to_ex.is_wfi && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_mret = i_from_id_to_ex.is_mret && !i_from_id_to_ex.is_fetch_fault;
    o_rob_alloc_req.is_sret = i_from_id_to_ex.is_sret;
    o_rob_alloc_req.is_dret = i_from_id_to_ex.is_dret;
    o_rob_alloc_req.is_sfence_vma = i_from_id_to_ex.is_sfence_vma;
    o_rob_alloc_req.is_amo = i_from_id_to_ex.is_amo_instruction;
    o_rob_alloc_req.is_lr = i_from_id_to_ex.is_lr;
    o_rob_alloc_req.is_sc = i_from_id_to_ex.is_sc;
    o_rob_alloc_req.is_compressed = i_from_id_to_ex.is_compressed;

    // Zicsr write intent: CSRRW/CSRRWI always write; set/clear forms write
    // only with a nonzero rs1/uimm field, regardless of the register value.
    // The ROB uses this bit to reject writes to read-only CSRs. Clear
    // csr_op[1:0] for read-only accesses so csr_file uses the same intent.
    o_rob_alloc_req.csr_write_intent =
        (i_from_id_to_ex.instruction.funct3[1:0] == 2'b01) ||
        (i_from_id_to_ex.instruction.source_reg_1 != 5'b0);
    o_rob_alloc_req.csr_addr = i_from_id_to_ex.csr_address;
    o_rob_alloc_req.csr_op =
        (i_from_id_to_ex.is_csr_instruction && !o_rob_alloc_req.csr_write_intent) ?
        {i_from_id_to_ex.instruction.funct3[2], 2'b00} : i_from_id_to_ex.instruction.funct3;
    // Immediate CSR forms carry zero-extended uimm. Register forms get their
    // write operand from the INT shim on CDB. The CSR access occurs at commit.
    o_rob_alloc_req.csr_write_data =
      i_from_id_to_ex.is_csr_imm ?
      {{(riscv_pkg::XLEN - 5) {1'b0}}, i_from_id_to_ex.csr_imm} :
    '0;

    // ID predecodes flag-producing FP ops, excluding illegal ops and fetch faults.
    o_rob_alloc_req.has_fp_flags = op_has_fp_flags;

    // With FS Off, ID routes F/D instructions to INT_RS as ILLEGAL. The ROB
    // also rejects them at allocation, including fflags, frm and fcsr accesses.
    o_rob_alloc_req.is_fp_instruction = i_from_id_to_ex.is_fp_instruction;

    // The ROB rejects dynamic rounding with frm in 5-7. Legal F/D ops without
    // an rm field have funct3 <= 011, so funct3 == DYN identifies rm users.
    o_rob_alloc_req.fp_dyn_rm = i_from_id_to_ex.is_fp_instruction &&
        (i_from_id_to_ex.instruction.funct3 == riscv_pkg::FRM_DYN);
  end

  // Slot-2 allocation requires the whole bundle to fire.
  always_comb begin
    o_rob_alloc_req_2 = '0;

    o_rob_alloc_req_2.alloc_valid = slot2_can_fire;
    o_rob_alloc_req_2.pc = i_from_id_to_ex_2.program_counter;
    o_rob_alloc_req_2.rs_type = rs_type_2;
    o_rob_alloc_req_2.dest_rf = dest_rf_2;
    o_rob_alloc_req_2.dest_reg = dest_reg_2;
    o_rob_alloc_req_2.dest_valid = has_dest_2;
    o_rob_alloc_req_2.is_store = is_store_flag_2;
    o_rob_alloc_req_2.is_fp_store = is_fp_store_flag_2;
    o_rob_alloc_req_2.is_branch = is_branch_flag_2;
    o_rob_alloc_req_2.predicted_taken = predicted_taken_2;
    o_rob_alloc_req_2.predicted_target = predicted_target_2;
    o_rob_alloc_req_2.branch_target = branch_target_2;
    o_rob_alloc_req_2.is_call = is_call_flag_2;
    o_rob_alloc_req_2.is_return = is_return_flag_2;
    o_rob_alloc_req_2.link_addr = i_from_id_to_ex_2.link_address;
    o_rob_alloc_req_2.is_jal = is_jal_flag_2 && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_jalr = is_jalr_flag_2 && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_csr = i_from_id_to_ex_2.is_csr_instruction;
    o_rob_alloc_req_2.is_fence = i_from_id_to_ex_2.is_fence && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_fence_i =
        i_from_id_to_ex_2.is_fence_i && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_wfi = i_from_id_to_ex_2.is_wfi && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_mret = i_from_id_to_ex_2.is_mret && !i_from_id_to_ex_2.is_fetch_fault;
    o_rob_alloc_req_2.is_sret = i_from_id_to_ex_2.is_sret;
    o_rob_alloc_req_2.is_dret = i_from_id_to_ex_2.is_dret;
    o_rob_alloc_req_2.is_sfence_vma = i_from_id_to_ex_2.is_sfence_vma;
    o_rob_alloc_req_2.is_amo = i_from_id_to_ex_2.is_amo_instruction;
    o_rob_alloc_req_2.is_lr = i_from_id_to_ex_2.is_lr;
    o_rob_alloc_req_2.is_sc = i_from_id_to_ex_2.is_sc;
    o_rob_alloc_req_2.is_compressed = i_from_id_to_ex_2.is_compressed;

    o_rob_alloc_req_2.csr_write_intent =
        (i_from_id_to_ex_2.instruction.funct3[1:0] == 2'b01) ||
        (i_from_id_to_ex_2.instruction.source_reg_1 != 5'b0);
    o_rob_alloc_req_2.csr_addr = i_from_id_to_ex_2.csr_address;
    o_rob_alloc_req_2.csr_op =
        (i_from_id_to_ex_2.is_csr_instruction && !o_rob_alloc_req_2.csr_write_intent) ?
        {i_from_id_to_ex_2.instruction.funct3[2], 2'b00} : i_from_id_to_ex_2.instruction.funct3;
    o_rob_alloc_req_2.csr_write_data =
      i_from_id_to_ex_2.is_csr_imm ?
      {{(riscv_pkg::XLEN - 5) {1'b0}}, i_from_id_to_ex_2.csr_imm} :
    '0;

    o_rob_alloc_req_2.has_fp_flags = op_has_fp_flags_2;

    o_rob_alloc_req_2.is_fp_instruction = i_from_id_to_ex_2.is_fp_instruction;
    o_rob_alloc_req_2.fp_dyn_rm = i_from_id_to_ex_2.is_fp_instruction &&
        (i_from_id_to_ex_2.instruction.funct3 == riscv_pkg::FRM_DYN);
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

  always_comb begin
    o_rat_alloc_valid_2    = slot2_can_fire && has_dest_2;
    o_rat_alloc_dest_rf_2  = dest_rf_2;
    o_rat_alloc_dest_reg_2 = dest_reg_2;
    o_rat_alloc_rob_tag_2  = i_rob_alloc_resp_2.alloc_tag;
  end

  // ===========================================================================
  // RS Dispatch Output
  // ===========================================================================

  riscv_pkg::rs_dispatch_t rs_dispatch_base;

  always_comb begin
    rs_dispatch_base                     = '0;

    rs_dispatch_base.rs_type             = rs_type;
    rs_dispatch_base.rob_tag             = i_rob_alloc_resp.alloc_tag;
    rs_dispatch_base.op                  = op;

    // Unused operands stay ready; each RS fills only the sources it consumes.
    rs_dispatch_base.src1_ready          = 1'b1;
    rs_dispatch_base.src2_ready          = 1'b1;
    rs_dispatch_base.src3_ready          = 1'b1;

    rs_dispatch_base.imm                 = imm;
    rs_dispatch_base.use_imm             = use_imm;
    // Only JALR consumes this; every op forwards its I-immediate bits.
    rs_dispatch_base.jalr_imm            = i_from_id_to_ex.immediate_i_type[11:0];

    rs_dispatch_base.rm                  = resolved_rm;

    // Branch info. The precomputed target itself travels in imm (see the
    // immediate selection above).
    rs_dispatch_base.predicted_taken     = predicted_taken;
    rs_dispatch_base.predicted_target    = predicted_target;
    rs_dispatch_base.predicted_target_ok = predicted_target_ok;
    rs_dispatch_base.is_compressed       = i_from_id_to_ex.is_compressed;

    rs_dispatch_base.is_fp_mem           = is_fp_load_flag || is_fp_store_flag;
    rs_dispatch_base.mem_needs_lq        = need_lq;
    rs_dispatch_base.mem_needs_sq        = need_sq;
    rs_dispatch_base.mem_size            = mem_size;
    rs_dispatch_base.mem_signed          = mem_signed;

    rs_dispatch_base.csr_addr            = i_from_id_to_ex.csr_address;
    rs_dispatch_base.csr_imm             = i_from_id_to_ex.csr_imm;

    // The INT station stores PC and link address by ROB tag for branch
    // resolution and recovery. JALR's ALU result travels separately in imm.
    rs_dispatch_base.pc                  = i_from_id_to_ex.program_counter;
    rs_dispatch_base.link_addr           = i_from_id_to_ex.link_address;

    // Every branch or jump needs a checkpoint; dispatch waits for one, so
    // a firing branch always has_checkpoint.
    rs_dispatch_base.has_checkpoint      = need_checkpoint;
    rs_dispatch_base.checkpoint_id       = i_checkpoint_alloc_id;
    rs_dispatch_base.is_call             = is_call_flag;
    rs_dispatch_base.is_return           = is_return_flag;
  end

  always_comb begin
    o_int_rs_dispatch = rs_dispatch_base;
    o_mul_rs_dispatch = rs_dispatch_base;
    o_mem_rs_dispatch = rs_dispatch_base;
    o_fp_rs_dispatch = rs_dispatch_base;

    o_int_rs_dispatch.valid = int_rs_dispatch_fire;
    o_mul_rs_dispatch.valid = mul_rs_dispatch_fire;
    o_mem_rs_dispatch.valid = mem_rs_dispatch_fire;
    o_fp_rs_dispatch.valid = fp_rs_dispatch_fire;

    // INT_RS uses integer sources. Unused operands stay ready, so the
    // station ignores their tags. INT_RS and MEM_RS can pass those tags
    // unmasked because tag matches affect only unready operands.
    o_int_rs_dispatch.src1_tag = int_src1_tag;
    o_int_rs_dispatch.src2_tag = int_src2_tag;
    o_int_rs_dispatch.src1_value = int_use1_mask ? int_src1_read : '0;
    o_int_rs_dispatch.src2_value = int_use2_mask ? int_src2_read : '0;
    if (uses_int_rs1) o_int_rs_dispatch.src1_ready = int_src1_ready;
    if (uses_int_rs2) o_int_rs_dispatch.src2_ready = int_src2_ready;

    // MUL_RS: M-extension operations always consume integer rs1/rs2.
    o_mul_rs_dispatch.src1_ready = int_src1_ready;
    o_mul_rs_dispatch.src1_tag   = int_src1_tag;
    o_mul_rs_dispatch.src1_value = mul_use1_mask ? int_src1_read : '0;
    o_mul_rs_dispatch.src2_ready = int_src2_ready;
    o_mul_rs_dispatch.src2_tag   = int_src2_tag;
    o_mul_rs_dispatch.src2_value = mul_use2_mask ? int_src2_read : '0;

    // MEM_RS: base address is integer rs1 when present; store data is integer
    // rs2 for integer stores/AMOs and FP rs2 for FP stores.
    o_mem_rs_dispatch.src1_tag   = int_src1_tag;
    o_mem_rs_dispatch.src1_value = int_use1_mask ? int_src1_read : '0;
    if (uses_int_rs1) o_mem_rs_dispatch.src1_ready = int_src1_ready;
    if (uses_fp_rs2_flag) begin
      o_mem_rs_dispatch.src2_ready = fp_src2_ready;
      o_mem_rs_dispatch.src2_tag   = fp_src2_tag;
      o_mem_rs_dispatch.src2_value = fp_src2_value;
    end else if (uses_int_rs2) begin
      o_mem_rs_dispatch.src2_ready = int_src2_ready;
      o_mem_rs_dispatch.src2_tag   = int_src2_tag;
      o_mem_rs_dispatch.src2_value = int_use2_mask ? int_src2_read : '0;
    end

    // FP_RS: most operations use FP rs1; int-to-FP moves/conversions use INT
    // rs1. Sources 2 and 3, when present, are always FP (source 3 only for
    // the FMA ops).
    if (uses_fp_rs1_flag) begin
      o_fp_rs_dispatch.src1_ready = fp_src1_ready;
      o_fp_rs_dispatch.src1_tag   = fp_src1_tag;
      o_fp_rs_dispatch.src1_value = fp_src1_value;
    end else if (uses_int_rs1) begin
      o_fp_rs_dispatch.src1_ready = int_src1_ready;
      o_fp_rs_dispatch.src1_tag   = int_src1_tag;
      o_fp_rs_dispatch.src1_value = fp_int_use1_mask ? int_src1_read : '0;
    end
    if (uses_fp_rs2_flag) begin
      o_fp_rs_dispatch.src2_ready = fp_src2_ready;
      o_fp_rs_dispatch.src2_tag   = fp_src2_tag;
      o_fp_rs_dispatch.src2_value = fp_src2_value;
    end
    if (uses_fp_rs3_flag) begin
      o_fp_rs_dispatch.src3_ready = fp_src3_ready;
      o_fp_rs_dispatch.src3_tag   = fp_src3_tag;
      o_fp_rs_dispatch.src3_value = fp_src3_value;
    end

    // Combined packet for standalone use; cpu_ooo uses per-RS packets.
    // Unused sources stay ready.
    o_rs_dispatch       = rs_dispatch_base;
    o_rs_dispatch.valid = dispatch_fire && (rs_type != riscv_pkg::RS_NONE);
    if (uses_fp_rs1_flag) begin
      o_rs_dispatch.src1_ready = fp_src1_ready;
      o_rs_dispatch.src1_tag   = fp_src1_tag;
      o_rs_dispatch.src1_value = fp_src1_value;
    end else if (uses_int_rs1) begin
      o_rs_dispatch.src1_ready = int_src1_ready;
      o_rs_dispatch.src1_tag   = int_src1_tag;
      o_rs_dispatch.src1_value = int_src1_value;
    end
    if (uses_fp_rs2_flag) begin
      o_rs_dispatch.src2_ready = fp_src2_ready;
      o_rs_dispatch.src2_tag   = fp_src2_tag;
      o_rs_dispatch.src2_value = fp_src2_value;
    end else if (uses_int_rs2) begin
      o_rs_dispatch.src2_ready = int_src2_ready;
      o_rs_dispatch.src2_tag   = int_src2_tag;
      o_rs_dispatch.src2_value = int_src2_value;
    end
    if (uses_fp_rs3_flag) begin
      o_rs_dispatch.src3_ready = fp_src3_ready;
      o_rs_dispatch.src3_tag   = fp_src3_tag;
      o_rs_dispatch.src3_value = fp_src3_value;
    end
  end

  // ===========================================================================
  // Slot-2 RS Dispatch Output (mirrors slot-1)
  // ===========================================================================
  // Slot-2 operands include the intra-bundle RAW bypass.

  riscv_pkg::rs_dispatch_t rs_dispatch_base_2;

  always_comb begin
    rs_dispatch_base_2                     = '0;

    rs_dispatch_base_2.rs_type             = rs_type_2;
    rs_dispatch_base_2.rob_tag             = i_rob_alloc_resp_2.alloc_tag;
    rs_dispatch_base_2.op                  = op_2;

    rs_dispatch_base_2.src1_ready          = 1'b1;
    rs_dispatch_base_2.src2_ready          = 1'b1;
    rs_dispatch_base_2.src3_ready          = 1'b1;

    rs_dispatch_base_2.imm                 = imm_2;
    rs_dispatch_base_2.use_imm             = use_imm_2;
    rs_dispatch_base_2.jalr_imm            = i_from_id_to_ex_2.immediate_i_type[11:0];

    rs_dispatch_base_2.rm                  = resolved_rm_2;

    rs_dispatch_base_2.predicted_taken     = predicted_taken_2;
    rs_dispatch_base_2.predicted_target    = predicted_target_2;
    rs_dispatch_base_2.predicted_target_ok = predicted_target_ok_2;
    rs_dispatch_base_2.is_compressed       = i_from_id_to_ex_2.is_compressed;

    rs_dispatch_base_2.is_fp_mem           = is_fp_load_flag_2 || is_fp_store_flag_2;
    rs_dispatch_base_2.mem_needs_lq        = need_lq_2;
    rs_dispatch_base_2.mem_needs_sq        = need_sq_2;
    rs_dispatch_base_2.mem_size            = mem_size_2;
    rs_dispatch_base_2.mem_signed          = mem_signed_2;

    rs_dispatch_base_2.csr_addr            = i_from_id_to_ex_2.csr_address;
    rs_dispatch_base_2.csr_imm             = i_from_id_to_ex_2.csr_imm;

    rs_dispatch_base_2.pc                  = i_from_id_to_ex_2.program_counter;
    rs_dispatch_base_2.link_addr           = i_from_id_to_ex_2.link_address;

    // A firing slot-2 branch has a checkpoint: slot 1 cannot be a branch,
    // and dispatch waits for checkpoint availability.
    rs_dispatch_base_2.has_checkpoint      = need_checkpoint_2;
    rs_dispatch_base_2.checkpoint_id       = i_checkpoint_alloc_id;
    rs_dispatch_base_2.is_call             = is_call_flag_2;
    rs_dispatch_base_2.is_return           = is_return_flag_2;
  end

  always_comb begin
    o_int_rs_dispatch_2 = rs_dispatch_base_2;
    o_mul_rs_dispatch_2 = rs_dispatch_base_2;
    o_mem_rs_dispatch_2 = rs_dispatch_base_2;
    o_fp_rs_dispatch_2 = rs_dispatch_base_2;

    o_int_rs_dispatch_2.valid = int_rs_dispatch_fire_2;
    o_mul_rs_dispatch_2.valid = mul_rs_dispatch_fire_2;
    o_mem_rs_dispatch_2.valid = mem_rs_dispatch_fire_2;
    o_fp_rs_dispatch_2.valid = fp_rs_dispatch_fire_2;

    // INT_RS slot-2: integer-only sources (unmasked tags as in slot 1).
    o_int_rs_dispatch_2.src1_tag = int_src1_2_tag;
    o_int_rs_dispatch_2.src2_tag = int_src2_2_tag;
    o_int_rs_dispatch_2.src1_value = int_use1_mask_2 ? int_src1_2_read : '0;
    o_int_rs_dispatch_2.src2_value = int_use2_mask_2 ? int_src2_2_read : '0;
    if (uses_int_rs1_2) o_int_rs_dispatch_2.src1_ready = int_src1_2_ready;
    if (uses_int_rs2_2) o_int_rs_dispatch_2.src2_ready = int_src2_2_ready;

    // MUL_RS slot-2: M-extension always consumes integer rs1/rs2.
    o_mul_rs_dispatch_2.src1_ready = int_src1_2_ready;
    o_mul_rs_dispatch_2.src1_tag   = int_src1_2_tag;
    o_mul_rs_dispatch_2.src1_value = mul_use1_mask_2 ? int_src1_2_read : '0;
    o_mul_rs_dispatch_2.src2_ready = int_src2_2_ready;
    o_mul_rs_dispatch_2.src2_tag   = int_src2_2_tag;
    o_mul_rs_dispatch_2.src2_value = mul_use2_mask_2 ? int_src2_2_read : '0;

    // MEM_RS slot-2: base = INT rs1; data = INT rs2 or FP rs2 for FP stores.
    o_mem_rs_dispatch_2.src1_tag   = int_src1_2_tag;
    o_mem_rs_dispatch_2.src1_value = int_use1_mask_2 ? int_src1_2_read : '0;
    if (uses_int_rs1_2) o_mem_rs_dispatch_2.src1_ready = int_src1_2_ready;
    if (uses_fp_rs2_flag_2) begin
      o_mem_rs_dispatch_2.src2_ready = fp_src2_2_ready;
      o_mem_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
      o_mem_rs_dispatch_2.src2_value = fp_src2_2_value;
    end else if (uses_int_rs2_2) begin
      o_mem_rs_dispatch_2.src2_ready = int_src2_2_ready;
      o_mem_rs_dispatch_2.src2_tag   = int_src2_2_tag;
      o_mem_rs_dispatch_2.src2_value = int_use2_mask_2 ? int_src2_2_read : '0;
    end

    // FP_RS slot-2: most ops use FP rs1; INT-to-FP conversions use INT rs1.
    if (uses_fp_rs1_flag_2) begin
      o_fp_rs_dispatch_2.src1_ready = fp_src1_2_ready;
      o_fp_rs_dispatch_2.src1_tag   = fp_src1_2_tag;
      o_fp_rs_dispatch_2.src1_value = fp_src1_2_value;
    end else if (uses_int_rs1_2) begin
      o_fp_rs_dispatch_2.src1_ready = int_src1_2_ready;
      o_fp_rs_dispatch_2.src1_tag   = int_src1_2_tag;
      o_fp_rs_dispatch_2.src1_value = fp_int_use1_mask_2 ? int_src1_2_read : '0;
    end
    if (uses_fp_rs2_flag_2) begin
      o_fp_rs_dispatch_2.src2_ready = fp_src2_2_ready;
      o_fp_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
      o_fp_rs_dispatch_2.src2_value = fp_src2_2_value;
    end
  end

  // ===========================================================================
  // Checkpoint Management
  // ===========================================================================
  // The checkpoint pool has one save port. A slot-1 branch blocks slot 2,
  // so at most one branch saves per cycle. A slot-2 branch saves its own
  // ROB tag and IF-time RAS state, with slot 1's rename overlaid in the RAT
  // snapshot so recovery preserves that allocation.

  logic checkpoint_save_slot1;
  logic checkpoint_save_slot2;
  assign checkpoint_save_slot1 = dispatch_fire && need_checkpoint;
  assign checkpoint_save_slot2 = slot2_can_fire && need_checkpoint_2;

  // Saved data uses this candidate only on a save. A saving bundle has
  // exactly one branch, so it equals checkpoint_save_slot2 in that cycle.
  logic checkpoint_slot2_candidate;
  assign checkpoint_slot2_candidate = slot2_present_for_admission && need_checkpoint_2;
  assign o_checkpoint_slot2_candidate = checkpoint_slot2_candidate;
  assign o_alloc_has_dest = has_dest;
  assign o_alloc_has_dest_2 = slot2_present_for_admission && has_dest_2;

  always_comb begin
    o_checkpoint_save = checkpoint_save_slot1 || checkpoint_save_slot2;
    o_checkpoint_save_for_slot2 = checkpoint_save_slot2;
    o_checkpoint_id = i_checkpoint_alloc_id;
    // Select the checkpointed ROB entry with the candidate qualified above.
    o_checkpoint_branch_tag = checkpoint_slot2_candidate ?
                              i_rob_alloc_resp_2.alloc_tag :
                              i_rob_alloc_resp.alloc_tag;

    // The IF snapshot includes older RAS operations but precedes this
    // instruction's own push or pop.
    if (checkpoint_slot2_candidate) begin
      o_ras_tos         = i_from_id_to_ex_2.ras_checkpoint_tos;
      o_ras_valid_count = i_from_id_to_ex_2.ras_checkpoint_valid_count;
      o_ras_top         = i_from_id_to_ex_2.ras_checkpoint_top;
    end else begin
      o_ras_tos         = i_from_id_to_ex.ras_checkpoint_tos;
      o_ras_valid_count = i_from_id_to_ex.ras_checkpoint_valid_count;
      o_ras_top         = i_from_id_to_ex.ras_checkpoint_top;
    end

    // The ROB records the checkpoint on the allocating branch, in either slot.
    o_rob_checkpoint_valid = o_checkpoint_save;
    o_rob_checkpoint_id    = i_checkpoint_alloc_id;
  end

`ifndef SYNTHESIS
  // Reject memory ops that fall through to the default word size. Queue
  // needs qualify this check because FENCE and other sizeless ops use no slot.
  always_comb begin
    if (dispatch_valid && rs_type == riscv_pkg::RS_MEM && (need_lq || need_sq) && !$isunknown(
            op
        )) begin
      p_slot1_mem_size_resolved :
      assert (!mem_size_defaulted)
      else
        $error(
            "slot1 mem op %0d (lq=%b sq=%b) missing from mem_size lists", int'(op), need_lq, need_sq
        );
    end
    if (dispatch_valid_2 && rs_type_2 == riscv_pkg::RS_MEM && (need_lq_2 || need_sq_2) &&
        !$isunknown(
            op_2
        )) begin
      p_slot2_mem_size_resolved :
      assert (!mem_size_2_defaulted)
      else
        $error(
            "slot2 mem op %0d (lq=%b sq=%b) missing from mem_size lists",
            int'(op_2),
            need_lq_2,
            need_sq_2
        );
    end
  end

  // i_valid and i_valid_2 arrive before flush qualification, so the direct
  // i_flush gate must suppress every combinational allocation side effect and
  // must never feed a recovery pulse back as dispatch backpressure.
  always_comb begin
    if (!$isunknown(
            {
              i_flush,
              dispatch_valid,
              dispatch_valid_2,
              dispatch_fire,
              o_stall,
              o_rob_alloc_req.alloc_valid,
              o_rob_alloc_req_2.alloc_valid,
              o_rat_alloc_valid,
              o_rat_alloc_valid_2,
              o_checkpoint_save,
              o_checkpoint_save_for_slot2,
              o_rob_checkpoint_valid,
              o_rs_dispatch.valid,
              o_int_rs_dispatch.valid,
              o_mul_rs_dispatch.valid,
              o_mem_rs_dispatch.valid,
              o_fp_rs_dispatch.valid,
              o_int_rs_dispatch_2.valid,
              o_mul_rs_dispatch_2.valid,
              o_mem_rs_dispatch_2.valid,
              o_fp_rs_dispatch_2.valid
            }
        )) begin
      // Bundle fire must qualify the early candidates into the allocation outputs.
      p_alloc_candidates_match_fire :
      assert ((o_rat_alloc_valid == (dispatch_fire && o_alloc_has_dest)) &&
              (o_rat_alloc_valid_2 == (dispatch_fire && o_alloc_has_dest_2)) &&
              (slot2_can_fire == (dispatch_fire && slot2_present_for_admission)) &&
              (!o_checkpoint_save ||
               (o_checkpoint_save_for_slot2 == o_checkpoint_slot2_candidate)));
      p_flush_blocks_dispatch_side_effects :
      assert (!i_flush ||
              (!dispatch_valid && !dispatch_valid_2 && !dispatch_fire && !o_stall &&
               !o_rob_alloc_req.alloc_valid && !o_rob_alloc_req_2.alloc_valid &&
               !o_rat_alloc_valid && !o_rat_alloc_valid_2 && !o_checkpoint_save &&
               !o_checkpoint_save_for_slot2 && !o_rob_checkpoint_valid &&
               !o_rs_dispatch.valid && !o_int_rs_dispatch.valid &&
               !o_mul_rs_dispatch.valid && !o_mem_rs_dispatch.valid &&
               !o_fp_rs_dispatch.valid && !o_int_rs_dispatch_2.valid &&
               !o_mul_rs_dispatch_2.valid && !o_mem_rs_dispatch_2.valid &&
               !o_fp_rs_dispatch_2.valid));
    end
  end
`endif


`ifndef SYNTHESIS
  // Fetch faults must wait for their exception completion on CDB.
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      p_fetch_fault_not_done_at_alloc :
      assert (!i_from_id_to_ex.is_fetch_fault ||
              !(o_rob_alloc_req.is_jal || o_rob_alloc_req.is_jalr ||
                o_rob_alloc_req.is_fence || o_rob_alloc_req.is_fence_i ||
                o_rob_alloc_req.is_wfi || o_rob_alloc_req.is_mret));
      p_fetch_fault_not_done_at_alloc_2 :
      assert (!i_from_id_to_ex_2.is_fetch_fault ||
              !(o_rob_alloc_req_2.is_jal || o_rob_alloc_req_2.is_jalr ||
                o_rob_alloc_req_2.is_fence || o_rob_alloc_req_2.is_fence_i ||
                o_rob_alloc_req_2.is_wfi || o_rob_alloc_req_2.is_mret));
    end
  end
`endif

`ifndef SYNTHESIS
  // For a dispatched conditional branch predicted taken, the predecoded
  // target check must equal the full XLEN comparison.
  always_ff @(posedge i_clk) begin
    if (i_rst_n && int_rs_dispatch_fire && is_branch_flag && !is_jalr_flag && predicted_taken) begin
      assert (predicted_target_ok == (predicted_target == branch_target))
      else $error("dispatch: slot-1 predicted_target_ok disagrees with the target compare");
    end
    if (i_rst_n && int_rs_dispatch_fire_2 && is_branch_flag_2 && !is_jalr_flag_2 &&
        predicted_taken_2) begin
      assert (predicted_target_ok_2 == (predicted_target_2 == branch_target_2))
      else $error("dispatch: slot-2 predicted_target_ok disagrees with the target compare");
    end
  end
`endif

`ifndef SYNTHESIS
  // Each packet must match its source-use-masked RAT values. Unready
  // operands must also carry the RAT tag; ready operands ignore it.
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      p_int_rs_src1_value_exact :
      assert (o_int_rs_dispatch.src1_value == (uses_int_rs1 ? int_src1_value : '0));
      p_int_rs_src2_value_exact :
      assert (o_int_rs_dispatch.src2_value == (uses_int_rs2 ? int_src2_value : '0));
      p_mul_rs_src1_value_exact : assert (o_mul_rs_dispatch.src1_value == int_src1_value);
      p_mul_rs_src2_value_exact : assert (o_mul_rs_dispatch.src2_value == int_src2_value);
      p_mem_rs_src1_value_exact :
      assert (o_mem_rs_dispatch.src1_value == (uses_int_rs1 ? int_src1_value : '0));
      p_mem_rs_src2_value_exact :
      assert (o_mem_rs_dispatch.src2_value ==
              (uses_fp_rs2_flag ? fp_src2_value : (uses_int_rs2 ? int_src2_value : '0)));
      p_fp_rs_src1_value_exact :
      assert (o_fp_rs_dispatch.src1_value ==
              (uses_fp_rs1_flag ? fp_src1_value : (uses_int_rs1 ? int_src1_value : '0)));
      p_int_rs_src1_value_2_exact :
      assert (o_int_rs_dispatch_2.src1_value == (uses_int_rs1_2 ? int_src1_2_value : '0));
      p_int_rs_src2_value_2_exact :
      assert (o_int_rs_dispatch_2.src2_value == (uses_int_rs2_2 ? int_src2_2_value : '0));
      p_mul_rs_src1_value_2_exact : assert (o_mul_rs_dispatch_2.src1_value == int_src1_2_value);
      p_mul_rs_src2_value_2_exact : assert (o_mul_rs_dispatch_2.src2_value == int_src2_2_value);
      p_mem_rs_src1_value_2_exact :
      assert (o_mem_rs_dispatch_2.src1_value == (uses_int_rs1_2 ? int_src1_2_value : '0));
      p_mem_rs_src2_value_2_exact :
      assert (o_mem_rs_dispatch_2.src2_value ==
              (uses_fp_rs2_flag_2 ? fp_src2_2_value :
               (uses_int_rs2_2 ? int_src2_2_value : '0)));
      p_fp_rs_src1_value_2_exact :
      assert (o_fp_rs_dispatch_2.src1_value ==
              (uses_fp_rs1_flag_2 ? fp_src1_2_value :
               (uses_int_rs1_2 ? int_src1_2_value : '0)));
      p_int_rs_unready_tags_exact :
      assert ((o_int_rs_dispatch.src1_ready || o_int_rs_dispatch.src1_tag == int_src1_tag) &&
              (o_int_rs_dispatch.src2_ready || o_int_rs_dispatch.src2_tag == int_src2_tag) &&
              (o_int_rs_dispatch_2.src1_ready ||
               o_int_rs_dispatch_2.src1_tag == int_src1_2_tag) &&
              (o_int_rs_dispatch_2.src2_ready ||
               o_int_rs_dispatch_2.src2_tag == int_src2_2_tag));
      p_mem_rs_unready_base_tags_exact :
      assert ((o_mem_rs_dispatch.src1_ready || o_mem_rs_dispatch.src1_tag == int_src1_tag) &&
              (o_mem_rs_dispatch_2.src1_ready ||
               o_mem_rs_dispatch_2.src1_tag == int_src1_2_tag));
    end
  end
`endif

`ifdef ROB_LINK_DISPATCH_LOCAL_PROOF
  // cpu_ooo enables the ROB's shared link bank. Dispatch's branch gate
  // supplies its single-branch allocation contract in every state.
  always_comb begin
    p_no_slot2_behind_branch :
    assert (!(o_rob_alloc_req_2.alloc_valid && o_rob_alloc_req.is_branch));
    p_single_branch_alloc :
    assert (!(o_rob_alloc_req.alloc_valid && o_rob_alloc_req.is_branch &&
              o_rob_alloc_req_2.alloc_valid && o_rob_alloc_req_2.is_branch));
  end
`endif

endmodule : dispatch
