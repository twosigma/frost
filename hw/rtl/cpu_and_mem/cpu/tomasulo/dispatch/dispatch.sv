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
 *     - src_ready=0, src_tag=ROB tag (will be woken by CDB)
 *     - dispatch emits a registered repair-read request; the wrapper checks
 *       whether that ROB entry is already done one cycle later and, if so,
 *       wakes the RS with the ROB value
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

    // Slot-2 instruction input (2-wide dispatch).  i_valid_2 is high whenever
    // the front-end supplied a real second instruction; when it is '0 (no
    // valid slot-2 this cycle) bundle_fire_ok reduces to slot-1's fire
    // condition.
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex_2,
    input logic                      i_valid_2,

    // Source register addresses (from PD early extraction, registered in ID)
    // These are used for RAT lookup timing optimization
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs1_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_rs2_addr,
    input logic [riscv_pkg::RegAddrWidth-1:0] i_fp_rs3_addr,

    // Slot-2 source register addresses (2-wide dispatch).  The intra-bundle
    // RAW bypass below compares these against slot-1's destination so a slot-2
    // source that reads slot-1's result picks up slot-1's fresh ROB tag.
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

    // Slot-2 ROB allocation (2-wide dispatch).  ROB returns alloc_tag = tail+1.
    // Held inactive (alloc_valid=0) when slot-2 isn't firing.
    output riscv_pkg::reorder_buffer_alloc_req_t  o_rob_alloc_req_2,
    input  riscv_pkg::reorder_buffer_alloc_resp_t i_rob_alloc_resp_2,

    // ROB entry-done vector, retained for interface stability.  The old
    // slot-2 missed-CDB conservative gate was removed after dispatch grew
    // channels 4/5/6 for slot-2 done-repair; missed-CDB operands are now
    // repaired by the registered bypass path in the wrapper/RS.
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_done,

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

    // Slot-2 lookup results from tomasulo_wrapper (raw, before intra-bundle
    // RAW bypass).  Dispatch applies bypass against slot-1's just-renamed
    // dest before the result is consumed downstream.
    input riscv_pkg::rat_lookup_t i_int_src1_2,
    input riscv_pkg::rat_lookup_t i_int_src2_2,
    input riscv_pkg::rat_lookup_t i_fp_src1_2,
    input riscv_pkg::rat_lookup_t i_fp_src2_2,
    input riscv_pkg::rat_lookup_t i_fp_src3_2,

    // =========================================================================
    // RAT Rename (to tomasulo_wrapper — write dest mapping)
    // =========================================================================
    // Slot 1
    output logic                                        o_rat_alloc_valid,
    output logic                                        o_rat_alloc_dest_rf,   // 0=INT, 1=FP
    output logic [         riscv_pkg::RegAddrWidth-1:0] o_rat_alloc_dest_reg,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag,

    // Slot 2 (2-wide dispatch).  o_rat_alloc_valid_2 asserts when slot-2 fires
    // with a register destination, renaming it in the same cycle as slot-1.
    output logic                                        o_rat_alloc_valid_2,
    output logic                                        o_rat_alloc_dest_rf_2,
    output logic [         riscv_pkg::RegAddrWidth-1:0] o_rat_alloc_dest_reg_2,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rat_alloc_rob_tag_2,

    // =========================================================================
    // ROB Done-Entry Repair Read Request (generic source ports)
    // =========================================================================
    // Channels 1-3 carry slot-1 source tags; channels 4-6 carry slot-2 source
    // tags.  Each channel is registered one cycle so the wrapper's
    // rob_entry_done indexed lookup is off the dispatch cone.
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
    output riscv_pkg::rs_dispatch_t o_fmul_rs_dispatch,
    output riscv_pkg::rs_dispatch_t o_fdiv_rs_dispatch,

    // Slot-2 per-RS dispatch packets (2-wide dispatch).  The dispatch unit
    // routes slot-2 to the RS family matching its rs_type and asserts
    // .valid only on that one packet when slot-2 fires.
    output riscv_pkg::rs_dispatch_t o_int_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_mul_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_mem_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_fp_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_fmul_rs_dispatch_2,
    output riscv_pkg::rs_dispatch_t o_fdiv_rs_dispatch_2,

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
    // overlay slot-1's same-cycle rename (Session F gap fix #6).
    output logic                                        o_checkpoint_save_for_slot2,

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

    // Slot-2 "room for 2" status (true when the structure has 0 or 1 free
    // entries — i.e., not enough room for a 2-wide bundle).  Used to gate
    // slot-2 fire when slot-1 is also targeting the same structure.
    input logic i_rob_full_for_2,
    input logic i_int_rs_full_for_2,
    input logic i_mul_rs_full_for_2,
    input logic i_mem_rs_full_for_2,
    input logic i_fp_rs_full_for_2,
    input logic i_fmul_rs_full_for_2,
    input logic i_fdiv_rs_full_for_2,
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
  assign op = i_from_id_to_ex.is_illegal_instruction ? riscv_pkg::ILLEGAL :
                                                    i_from_id_to_ex.instruction_operation;

  // RS routing is pre-decoded in ID and registered into from_id_to_ex_t so
  // the dispatch fire signals do not start with a large instruction_operation
  // case tree.
  riscv_pkg::rs_type_e rs_type;
  assign rs_type = riscv_pkg::rs_type_e'(i_from_id_to_ex.rs_type);

  // Destination register classification
  logic has_dest;
  logic dest_rf;  // 0=INT, 1=FP
  logic [riscv_pkg::RegAddrWidth-1:0] dest_reg;

  // Pre-decoded in id_stage and registered into from_id_to_ex_t to keep the
  // op-classification decode out of the dispatch -> RS-write critical path.
  // The id_stage helper applies the same is_illegal -> ILLEGAL override used
  // below to construct `op`, so these flags are equivalent to re-running the
  // has_fp_dest(op) / has_int_dest(op) functions here.  Removes the
  // 4-LUT-deep decode chain from instruction_operation that fed
  // has_int_dest_flag1 on the worst-case ID->RS path (post-synth WNS=-1.576ns).
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
  logic op_has_fp_flags;

  // uses_fp_rs1/rs2/rs3 and uses_int_rs1/rs2 are pre-decoded in id_stage and
  // registered into from_id_to_ex_t (timing optimization — see has_*_dest_flag
  // above for the ID->RS path that motivated the move).
  assign uses_fp_rs1_flag = i_from_id_to_ex.uses_fp_rs1;
  assign uses_fp_rs2_flag = i_from_id_to_ex.uses_fp_rs2;
  assign uses_fp_rs3_flag = i_from_id_to_ex.uses_fp_rs3;
  assign uses_int_rs1     = i_from_id_to_ex.uses_int_rs1;
  assign uses_int_rs2     = i_from_id_to_ex.uses_int_rs2;

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
    mem_signed = i_from_id_to_ex.is_load_instruction &&
                 !i_from_id_to_ex.is_load_unsigned &&
                 (i_from_id_to_ex.is_load_byte || i_from_id_to_ex.is_load_halfword);
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
  // Slot-2 Instruction Classification (mirrors slot-1 above)
  // ===========================================================================
  // Decoded the same way as slot-1 but driven from i_from_id_to_ex_2 / i_valid_2.
  // When the bundle has no valid slot-2 (i_valid_2='0), these signals collapse
  // to defaults and feed an all-zero slot-2 dispatch packet.

  riscv_pkg::instr_op_e op_2;
  assign op_2 = i_from_id_to_ex_2.is_illegal_instruction ? riscv_pkg::ILLEGAL :
                                                      i_from_id_to_ex_2.instruction_operation;

  riscv_pkg::rs_type_e rs_type_2;
  assign rs_type_2 = riscv_pkg::rs_type_e'(i_from_id_to_ex_2.rs_type);

  // Slot-2 destination classification.
  logic has_dest_2;
  logic dest_rf_2;
  logic [riscv_pkg::RegAddrWidth-1:0] dest_reg_2;

  // Pre-decoded in id_stage and registered into from_id_to_ex_t — see slot-1
  // has_*_dest_flag for the timing motivation.
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

  // Pre-decoded slot-2 source/dest flags (mirror of slot-1).
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

  always_comb begin
    case (op_2)
      riscv_pkg::LB, riscv_pkg::LBU, riscv_pkg::SB: mem_size_2 = riscv_pkg::MEM_SIZE_BYTE;
      riscv_pkg::LH, riscv_pkg::LHU, riscv_pkg::SH: mem_size_2 = riscv_pkg::MEM_SIZE_HALF;
      riscv_pkg::LW, riscv_pkg::SW, riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      mem_size_2 = riscv_pkg::MEM_SIZE_WORD;
      riscv_pkg::FLD, riscv_pkg::FSD: mem_size_2 = riscv_pkg::MEM_SIZE_DOUBLE;
      default: mem_size_2 = riscv_pkg::MEM_SIZE_WORD;
    endcase

    mem_signed_2 = i_from_id_to_ex_2.is_load_instruction &&
                   !i_from_id_to_ex_2.is_load_unsigned &&
                   (i_from_id_to_ex_2.is_load_byte || i_from_id_to_ex_2.is_load_halfword);
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
      riscv_pkg::JALR,
      riscv_pkg::BSETI, riscv_pkg::BCLRI, riscv_pkg::BINVI, riscv_pkg::BEXTI, riscv_pkg::RORI: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_i_type;
      end

      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::FSW, riscv_pkg::FSD: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_s_type;
      end

      riscv_pkg::LUI: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_u_type;
      end

      riscv_pkg::AUIPC: begin
        use_imm_2 = 1'b1;
        imm_2     = i_from_id_to_ex_2.immediate_u_type;
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
    if (i_from_id_to_ex_2.ras_predicted) begin
      predicted_taken_2  = 1'b1;
      predicted_target_2 = i_from_id_to_ex_2.ras_predicted_target;
    end else if (i_from_id_to_ex_2.btb_predicted_taken) begin
      predicted_taken_2  = 1'b1;
      predicted_target_2 = i_from_id_to_ex_2.btb_predicted_target;
    end else begin
      predicted_taken_2  = 1'b0;
      predicted_target_2 = '0;
    end
  end

  // Slot-2 branch target.
  logic [riscv_pkg::XLEN-1:0] branch_target_2;
  always_comb begin
    if (is_jal_flag_2) branch_target_2 = i_from_id_to_ex_2.jal_target_precomputed;
    else branch_target_2 = i_from_id_to_ex_2.branch_target_precomputed;
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
                   (i_from_id_to_ex.is_amo_instruction &&
                    !i_from_id_to_ex.is_lr &&
                    !i_from_id_to_ex.is_sc);
  assign need_sq = is_store_flag || is_fp_store_flag || i_from_id_to_ex.is_sc;

  logic need_checkpoint;
  assign need_checkpoint = is_branch_flag;

  logic dispatch_valid;
  assign dispatch_valid = i_valid && !i_flush;

  // Slot-2 resource needs.  When slot-2 isn't firing (i_valid_2=0) all of
  // these are don't-cares for the bundle gate and o_stall collapses to the
  // 1-wide form.
  logic need_lq_2, need_sq_2;
  assign need_lq_2 = is_load_flag_2 || is_fp_load_flag_2 ||
                     i_from_id_to_ex_2.is_lr ||
                     (i_from_id_to_ex_2.is_amo_instruction &&
                      !i_from_id_to_ex_2.is_lr &&
                      !i_from_id_to_ex_2.is_sc);
  assign need_sq_2 = is_store_flag_2 || is_fp_store_flag_2 || i_from_id_to_ex_2.is_sc;

  logic need_checkpoint_2;
  assign need_checkpoint_2 = is_branch_flag_2;

  logic dispatch_valid_2;
  logic slot2_fp_compute_serialized;
  assign slot2_fp_compute_serialized =
      (rs_type_2 == riscv_pkg::RS_FP) ||
      (rs_type_2 == riscv_pkg::RS_FMUL) ||
      (rs_type_2 == riscv_pkg::RS_FDIV);
  assign dispatch_valid_2 = i_valid_2 && !i_flush && !slot2_fp_compute_serialized;

  // Slot-2's RS-room check.  Same-RS-as-slot-1 needs room for 2; otherwise
  // room for 1 in slot-2's RS suffices (slot-1 didn't take from that RS).
  logic rs_full_for_slot2;
  always_comb begin
    case (rs_type_2)
      riscv_pkg::RS_INT:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_INT) ? i_int_rs_full_for_2 : i_int_rs_full;
      riscv_pkg::RS_MUL:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_MUL) ? i_mul_rs_full_for_2 : i_mul_rs_full;
      riscv_pkg::RS_MEM:
      rs_full_for_slot2 = (rs_type == riscv_pkg::RS_MEM) ? i_mem_rs_full_for_2 : i_mem_rs_full;
      // Slot-2 FP compute dispatch is serialized off before the bundle gate
      // (`dispatch_valid_2=0`), so these fullness inputs are don't-cares for
      // slot-2.  Keeping them out of the slot-2 room mux prevents FP RS
      // fullness from gating unrelated integer/memory dispatch packets.
      riscv_pkg::RS_FP, riscv_pkg::RS_FMUL, riscv_pkg::RS_FDIV: rs_full_for_slot2 = 1'b0;
      riscv_pkg::RS_NONE: rs_full_for_slot2 = 1'b0;
      default: rs_full_for_slot2 = 1'b0;
    endcase
  end

  // Slot-2's LQ / SQ / checkpoint room checks given slot-1's needs.
  logic lq_full_for_slot2;
  logic sq_full_for_slot2;
  assign lq_full_for_slot2 = need_lq ? i_lq_full_for_2 : i_lq_full;
  assign sq_full_for_slot2 = need_sq ? i_sq_full_for_2 : i_sq_full;

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

    // Stall semantics (per design doc Session D, "simpler stall"):
    //   o_stall = !(slot1_can_fire && (!slot2_valid || slot2_can_fire))
    // If slot-2 is invalid, this reduces to !slot1_can_fire — identical to
    // the 1-wide baseline.  When slot-2 IS valid but cannot fire, we stall
    // both slots so the front-end re-presents the bundle next cycle (no
    // skid buffer).
    if (!dispatch_valid) begin
      o_stall = 1'b0;
    end else begin
      o_stall = !bundle_fire_ok;
    end
    o_status.stall = o_stall;
  end

  // Dispatch fires when valid and not stalled.  Split per-RS dispatch outputs
  // use RS-specific fire terms so unrelated full signals do not feed every
  // reservation station's input registers through the shared rs_full mux.
  logic dispatch_common_ready;
  logic dispatch_fire;
  logic slot1_can_fire;  // Slot-1 standalone gate (unchanged)
  logic slot2_can_fire;  // Slot-2 gate, conditional on slot1_can_fire
  logic slot2_resources_ok;
  logic slot2_bundle_ok;
  logic bundle_fire_ok;  // Whole bundle fires (slot-1 + optional slot-2)
  logic int_rs_dispatch_fire;
  logic mul_rs_dispatch_fire;
  logic mem_rs_dispatch_fire;
  logic fp_rs_dispatch_fire;
  logic fmul_rs_dispatch_fire;
  logic fdiv_rs_dispatch_fire;
  // Slot-2 per-RS fire signals.  Each independently requires the bundle to
  // fire and routes slot-2's packet into exactly one RS family.
  logic int_rs_dispatch_fire_2;
  logic mul_rs_dispatch_fire_2;
  logic mem_rs_dispatch_fire_2;
  logic fp_rs_dispatch_fire_2;
  logic fmul_rs_dispatch_fire_2;
  logic fdiv_rs_dispatch_fire_2;

  assign dispatch_common_ready =
      dispatch_valid &&
      !i_hold &&
      !i_rob_full &&
      !(need_lq && i_lq_full) &&
      !(need_sq && i_sq_full) &&
      !(need_checkpoint && !i_checkpoint_available);
  assign slot1_can_fire = dispatch_common_ready && !rs_full;
  // Slot-2 is bundle-terminated by a slot-1 branch (decision #1).  Slot-2
  // alloc requires slot-1 alloc to also fire, so slot1_can_fire is part of
  // the gate.  Resource room counts are "for 2" when both slots target the
  // same structure, plain "full" when they don't (rs_full_for_slot2 etc.
  // already encode this).
  //
  // Session M: the conservative `slot2_source_done_pending` gate (Session G
  // placeholder for decision #5) is removed.  Slot-2 now has its own
  // done-repair coverage via dispatch's bypass channels 4/5/6 → wrapper →
  // RS i_repair_valid_4/5/6.  An already-done slot-2 source is repaired the
  // cycle after dispatch, just like slot-1.

  assign slot2_resources_ok = !is_branch_flag &&  // slot-1 not a branch
      !i_rob_full_for_2 &&
      !rs_full_for_slot2 &&
      !(need_lq_2 && lq_full_for_slot2) &&
      !(need_sq_2 && sq_full_for_slot2) &&
      !(need_checkpoint_2 && !i_checkpoint_available);
  assign slot2_can_fire = slot1_can_fire && dispatch_valid_2 && slot2_resources_ok;
  assign slot2_bundle_ok = !dispatch_valid_2 || slot2_resources_ok;
  // Whole bundle fires together — either both fire or neither.  When
  // slot-2 isn't valid, the OR collapses to 1 and the bundle gate matches
  // slot-1's standalone gate.
  assign bundle_fire_ok = slot1_can_fire && slot2_bundle_ok;
  assign dispatch_fire = bundle_fire_ok;
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
  assign fmul_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_FMUL) && !i_fmul_rs_full &&
      slot2_bundle_ok;
  assign fdiv_rs_dispatch_fire =
      dispatch_common_ready && (rs_type == riscv_pkg::RS_FDIV) && !i_fdiv_rs_full &&
      slot2_bundle_ok;

  // Slot-2 per-RS dispatch fire signals.  Each gates on bundle_fire_ok plus
  // slot-2's specific RS family.  Like the slot-1 per-RS signals, only the
  // RS family targeted by slot-2 has its valid bit asserted.
  assign int_rs_dispatch_fire_2  = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_INT);
  assign mul_rs_dispatch_fire_2  = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_MUL);
  assign mem_rs_dispatch_fire_2  = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_MEM);
  assign fp_rs_dispatch_fire_2   = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_FP);
  assign fmul_rs_dispatch_fire_2 = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_FMUL);
  assign fdiv_rs_dispatch_fire_2 = bundle_fire_ok && dispatch_valid_2 &&
                                   (rs_type_2 == riscv_pkg::RS_FDIV);

  // ===========================================================================
  // RAT Source Address Outputs
  // ===========================================================================
  // Drive RAT lookup addresses. For instructions that use INT rs1 + FP rs2
  // (e.g., FP stores: base address from INT rs1, data from FP rs2), we route
  // accordingly.

  assign o_int_src1_addr = i_rs1_addr;
  assign o_int_src2_addr = i_rs2_addr;
  assign o_fp_src1_addr = i_rs1_addr;
  assign o_fp_src2_addr = i_rs2_addr;
  assign o_fp_src3_addr = i_fp_rs3_addr;

  // Slot-2 RAT lookup addresses (2-wide dispatch).  Each address feeds an
  // independent RAT read port; intra-bundle RAW bypass below overrides the
  // RAT lookup result rather than the address itself.
  assign o_int_src1_addr_2 = i_rs1_addr_2;
  assign o_int_src2_addr_2 = i_rs2_addr_2;
  assign o_fp_src1_addr_2 = i_rs1_addr_2;
  assign o_fp_src2_addr_2 = i_rs2_addr_2;
  assign o_fp_src3_addr_2 = i_fp_rs3_addr_2;

  // ===========================================================================
  // Source Operand Resolution
  // ===========================================================================
  // For each source, select between INT and FP RAT based on instruction type,
  // then resolve ready/tag/value from the RAT lookup result.

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

  // Slot-2 done-repair channels (4/5/6) — mirror of slot-1.  Use the
  // intra-bundle-RAW-resolved `*_2_eff` views: when slot-2 reads slot-1's
  // dest the eff tag is slot-1's just-allocated ROB tag (not yet done at
  // T+1, so the bypass channel produces no spurious wake), and when not
  // intra-bundle the eff tag matches the raw RAT lookup.
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

    bypass_valid_6_next = 1'b0;
    bypass_tag_6_next   = '0;
    if (uses_fp_rs3_flag_2) begin
      bypass_valid_6_next = fp_src3_2_eff.renamed;
      bypass_tag_6_next   = fp_src3_2_eff.tag;
    end
  end

  // Register repair-read addresses so the ROB done/value lookup is no longer in
  // the dispatch source-ready/value cone.  Tags are covered by the valid bits.
  // Slot-2 channels (4/5/6) gate on `bundle_fire_ok && dispatch_valid_2` rather
  // than `dispatch_fire` alone — slot-2's bypass valid is meaningful only when
  // slot-2 actually fires, not just when slot-1 does.
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
      o_bypass_valid_4 <= bundle_fire_ok && dispatch_valid_2 && bypass_valid_4_next;
      o_bypass_valid_5 <= bundle_fire_ok && dispatch_valid_2 && bypass_valid_5_next;
      o_bypass_valid_6 <= bundle_fire_ok && dispatch_valid_2 && bypass_valid_6_next;
    end
  end

  always_ff @(posedge i_clk) begin
    o_bypass_tag_1 <= bypass_tag_1_next;
    o_bypass_tag_2 <= bypass_tag_2_next;
    o_bypass_tag_3 <= bypass_tag_3_next;
    o_bypass_tag_4 <= bypass_tag_4_next;
    o_bypass_tag_5 <= bypass_tag_5_next;
    o_bypass_tag_6 <= bypass_tag_6_next;
  end

  // Source resolution
  // RAT lookup: renamed=1 means source maps to an in-flight ROB entry.
  // Dispatch does not inspect completed ROB values in-line.  Renamed sources
  // wait for either the CDB or the registered done-repair wakeup above.
  //
  // Keep INT and FP source slots separate here.  The per-RS dispatch builders
  // below select only the source family each RS can actually consume, which
  // keeps unrelated RAT outputs out of the RS dispatch-ready cones.
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
  // For each slot-2 source operand, if the architectural register matches
  // slot-1's destination AND slot-1 has a valid dest of the matching family
  // (INT vs FP), replace the RAT lookup with {renamed=1, tag=slot-1 ROB tag}.
  // The RAT itself was sampled before slot-1's rename took effect, so without
  // this override slot-2 would race against an unrenamed (stale) source.
  //
  // Per design doc decision #6, RAT proper does not see this case; it is
  // resolved entirely inside dispatch, feeding the per-RS slot-2 builders.

  // Slot-1 dest match conditions, factored once.  has_dest=1 implies dest
  // is non-x0 for INT (per the dest_reg='0 -> has_dest=0 path) and any
  // valid arch reg for FP, so an x0 false match is impossible.
  logic slot1_dest_int;
  logic slot1_dest_fp;
  assign slot1_dest_int = has_dest && !dest_rf;
  assign slot1_dest_fp  = has_dest && dest_rf;

  // INT slot-2 sources: match against slot-1 INT dest.
  logic intra_bundle_int_src1_2;
  logic intra_bundle_int_src2_2;
  assign intra_bundle_int_src1_2 = slot1_dest_int && (i_rs1_addr_2 != '0) &&
                                   (dest_reg == i_rs1_addr_2);
  assign intra_bundle_int_src2_2 = slot1_dest_int && (i_rs2_addr_2 != '0) &&
                                   (dest_reg == i_rs2_addr_2);

  // FP slot-2 sources: match against slot-1 FP dest.  FP regs do not have an
  // x0 hardwired-zero, so no zero-address guard is needed.
  logic intra_bundle_fp_src1_2;
  logic intra_bundle_fp_src2_2;
  logic intra_bundle_fp_src3_2;
  assign intra_bundle_fp_src1_2 = slot1_dest_fp && (dest_reg == i_rs1_addr_2);
  assign intra_bundle_fp_src2_2 = slot1_dest_fp && (dest_reg == i_rs2_addr_2);
  assign intra_bundle_fp_src3_2 = slot1_dest_fp && (dest_reg == i_fp_rs3_addr_2);

  // Effective slot-2 lookup results after intra-bundle RAW override.
  riscv_pkg::rat_lookup_t int_src1_2_eff;
  riscv_pkg::rat_lookup_t int_src2_2_eff;
  riscv_pkg::rat_lookup_t fp_src1_2_eff;
  riscv_pkg::rat_lookup_t fp_src2_2_eff;
  riscv_pkg::rat_lookup_t fp_src3_2_eff;

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

  // Slot-2 ready/tag/value triplets, parallel to slot-1.  Wired into the
  // per-RS slot-2 dispatch builders below.
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
    o_rob_alloc_req.is_fence = i_from_id_to_ex.is_fence;
    o_rob_alloc_req.is_fence_i = i_from_id_to_ex.is_fence_i;
    o_rob_alloc_req.is_wfi = i_from_id_to_ex.is_wfi;
    o_rob_alloc_req.is_mret = i_from_id_to_ex.is_mret;
    o_rob_alloc_req.is_amo = i_from_id_to_ex.is_amo_instruction;
    o_rob_alloc_req.is_lr = i_from_id_to_ex.is_lr;
    o_rob_alloc_req.is_sc = i_from_id_to_ex.is_sc;
    o_rob_alloc_req.is_compressed = i_from_id_to_ex.is_compressed;

    // CSR info (stored in ROB for commit-time serialized execution)
    o_rob_alloc_req.csr_addr = i_from_id_to_ex.csr_address;
    o_rob_alloc_req.csr_op = i_from_id_to_ex.instruction.funct3;
    // CSR write data: rs1 for register-based ops, zero-extended imm for immediate ops
    o_rob_alloc_req.csr_write_data =
      i_from_id_to_ex.is_csr_imm ?
      {{(riscv_pkg::XLEN - 5) {1'b0}}, i_from_id_to_ex.csr_imm} :
    // For register-based CSR ops, the actual rs1 value won't be known
    // until the source operand resolves. The ALU shim will handle
    // reading rs1 from the RS issue and computing the CSR result.
    '0;

    // FP flags validity: FP compute ops produce flags, FP loads do not.
    // Derive this from the decoded op here so FP flags do not depend on a
    // parallel ID-stage opcode classifier staying aligned through stalls.
    o_rob_alloc_req.has_fp_flags = op_has_fp_flags;
  end

  // Slot-2 ROB alloc request: same field shape, slot-2 inputs.  alloc_valid
  // requires the bundle to fire AND slot-2 to be valid (per the alloc_2-
  // implies-alloc contract enforced by the ROB).
  always_comb begin
    o_rob_alloc_req_2 = '0;

    o_rob_alloc_req_2.alloc_valid = bundle_fire_ok && dispatch_valid_2;
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
    o_rob_alloc_req_2.is_jal = is_jal_flag_2;
    o_rob_alloc_req_2.is_jalr = is_jalr_flag_2;
    o_rob_alloc_req_2.is_csr = i_from_id_to_ex_2.is_csr_instruction;
    o_rob_alloc_req_2.is_fence = i_from_id_to_ex_2.is_fence;
    o_rob_alloc_req_2.is_fence_i = i_from_id_to_ex_2.is_fence_i;
    o_rob_alloc_req_2.is_wfi = i_from_id_to_ex_2.is_wfi;
    o_rob_alloc_req_2.is_mret = i_from_id_to_ex_2.is_mret;
    o_rob_alloc_req_2.is_amo = i_from_id_to_ex_2.is_amo_instruction;
    o_rob_alloc_req_2.is_lr = i_from_id_to_ex_2.is_lr;
    o_rob_alloc_req_2.is_sc = i_from_id_to_ex_2.is_sc;
    o_rob_alloc_req_2.is_compressed = i_from_id_to_ex_2.is_compressed;

    o_rob_alloc_req_2.csr_addr = i_from_id_to_ex_2.csr_address;
    o_rob_alloc_req_2.csr_op = i_from_id_to_ex_2.instruction.funct3;
    o_rob_alloc_req_2.csr_write_data =
      i_from_id_to_ex_2.is_csr_imm ?
      {{(riscv_pkg::XLEN - 5) {1'b0}}, i_from_id_to_ex_2.csr_imm} :
    '0;

    o_rob_alloc_req_2.has_fp_flags = op_has_fp_flags_2;
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

  // Slot-2 RAT rename output.  Asserted only when slot-2 is allocating into
  // ROB AND has a destination register (matches slot-1's gate).  The ROB
  // returns slot-2's tag as i_rob_alloc_resp_2.alloc_tag (= tail+1).
  always_comb begin
    o_rat_alloc_valid_2    = bundle_fire_ok && dispatch_valid_2 && has_dest_2;
    o_rat_alloc_dest_rf_2  = dest_rf_2;
    o_rat_alloc_dest_reg_2 = dest_reg_2;
    o_rat_alloc_rob_tag_2  = i_rob_alloc_resp_2.alloc_tag;
  end

  // ===========================================================================
  // RS Dispatch Output
  // ===========================================================================

  riscv_pkg::rs_dispatch_t rs_dispatch_base;

  always_comb begin
    rs_dispatch_base                  = '0;

    rs_dispatch_base.rs_type          = rs_type;
    rs_dispatch_base.rob_tag          = i_rob_alloc_resp.alloc_tag;
    rs_dispatch_base.op               = op;

    // Unused operands are ready constants.  Per-RS builders below overwrite
    // only the source slots that can be consumed by that RS family.
    rs_dispatch_base.src1_ready       = 1'b1;
    rs_dispatch_base.src2_ready       = 1'b1;
    rs_dispatch_base.src3_ready       = 1'b1;

    // Immediate
    rs_dispatch_base.imm              = imm;
    rs_dispatch_base.use_imm          = use_imm;

    // Rounding mode
    rs_dispatch_base.rm               = resolved_rm;

    // Branch info
    rs_dispatch_base.branch_target    = branch_target;
    rs_dispatch_base.predicted_taken  = predicted_taken;
    rs_dispatch_base.predicted_target = predicted_target;

    // Memory info
    rs_dispatch_base.is_fp_mem        = is_fp_load_flag || is_fp_store_flag;
    rs_dispatch_base.mem_needs_lq     = need_lq;
    rs_dispatch_base.mem_needs_sq     = need_sq;
    rs_dispatch_base.mem_size         = mem_size;
    rs_dispatch_base.mem_signed       = mem_signed;

    // CSR info
    rs_dispatch_base.csr_addr         = i_from_id_to_ex.csr_address;
    rs_dispatch_base.csr_imm          = i_from_id_to_ex.csr_imm;

    // PC and pre-computed link address for AUIPC/JAL/JALR handling.
    rs_dispatch_base.pc               = i_from_id_to_ex.program_counter;
    rs_dispatch_base.link_addr        = i_from_id_to_ex.link_address;

    // Early misprediction recovery: checkpoint info and branch type.
    // need_checkpoint is true for conditional branches and JALR (not JAL).
    // When dispatch fires for a branch, a checkpoint is always available
    // (dispatch stalls otherwise), so has_checkpoint = need_checkpoint.
    rs_dispatch_base.has_checkpoint   = need_checkpoint;
    rs_dispatch_base.checkpoint_id    = i_checkpoint_alloc_id;
    rs_dispatch_base.is_call          = is_call_flag;
    rs_dispatch_base.is_return        = is_return_flag;
  end

  always_comb begin
    o_int_rs_dispatch = rs_dispatch_base;
    o_mul_rs_dispatch = rs_dispatch_base;
    o_mem_rs_dispatch = rs_dispatch_base;
    o_fp_rs_dispatch = rs_dispatch_base;
    o_fmul_rs_dispatch = rs_dispatch_base;
    o_fdiv_rs_dispatch = rs_dispatch_base;

    o_int_rs_dispatch.valid = int_rs_dispatch_fire;
    o_mul_rs_dispatch.valid = mul_rs_dispatch_fire;
    o_mem_rs_dispatch.valid = mem_rs_dispatch_fire;
    o_fp_rs_dispatch.valid = fp_rs_dispatch_fire;
    o_fmul_rs_dispatch.valid = fmul_rs_dispatch_fire;
    o_fdiv_rs_dispatch.valid = fdiv_rs_dispatch_fire;

    // INT_RS: integer-only sources.  LUI/AUIPC/JAL-like operations keep the
    // default ready constants for unused slots.
    if (uses_int_rs1) begin
      o_int_rs_dispatch.src1_ready = int_src1_ready;
      o_int_rs_dispatch.src1_tag   = int_src1_tag;
      o_int_rs_dispatch.src1_value = int_src1_value;
    end
    if (uses_int_rs2) begin
      o_int_rs_dispatch.src2_ready = int_src2_ready;
      o_int_rs_dispatch.src2_tag   = int_src2_tag;
      o_int_rs_dispatch.src2_value = int_src2_value;
    end

    // MUL_RS: M-extension operations always consume integer rs1/rs2.
    o_mul_rs_dispatch.src1_ready = int_src1_ready;
    o_mul_rs_dispatch.src1_tag   = int_src1_tag;
    o_mul_rs_dispatch.src1_value = int_src1_value;
    o_mul_rs_dispatch.src2_ready = int_src2_ready;
    o_mul_rs_dispatch.src2_tag   = int_src2_tag;
    o_mul_rs_dispatch.src2_value = int_src2_value;

    // MEM_RS: base address is integer rs1 when present; store data is integer
    // rs2 for integer stores/AMOs and FP rs2 for FP stores.
    if (uses_int_rs1) begin
      o_mem_rs_dispatch.src1_ready = int_src1_ready;
      o_mem_rs_dispatch.src1_tag   = int_src1_tag;
      o_mem_rs_dispatch.src1_value = int_src1_value;
    end
    if (uses_fp_rs2_flag) begin
      o_mem_rs_dispatch.src2_ready = fp_src2_ready;
      o_mem_rs_dispatch.src2_tag   = fp_src2_tag;
      o_mem_rs_dispatch.src2_value = fp_src2_value;
    end else if (uses_int_rs2) begin
      o_mem_rs_dispatch.src2_ready = int_src2_ready;
      o_mem_rs_dispatch.src2_tag   = int_src2_tag;
      o_mem_rs_dispatch.src2_value = int_src2_value;
    end

    // FP_RS: most operations use FP rs1; int-to-FP moves/conversions use INT
    // rs1.  Source 2, when present, is always FP for this RS.
    if (uses_fp_rs1_flag) begin
      o_fp_rs_dispatch.src1_ready = fp_src1_ready;
      o_fp_rs_dispatch.src1_tag   = fp_src1_tag;
      o_fp_rs_dispatch.src1_value = fp_src1_value;
    end else if (uses_int_rs1) begin
      o_fp_rs_dispatch.src1_ready = int_src1_ready;
      o_fp_rs_dispatch.src1_tag   = int_src1_tag;
      o_fp_rs_dispatch.src1_value = int_src1_value;
    end
    if (uses_fp_rs2_flag) begin
      o_fp_rs_dispatch.src2_ready = fp_src2_ready;
      o_fp_rs_dispatch.src2_tag   = fp_src2_tag;
      o_fp_rs_dispatch.src2_value = fp_src2_value;
    end

    // FMUL_RS: FP multiply/FMA.  FMUL uses src1/src2; FMA also uses src3.
    o_fmul_rs_dispatch.src1_ready = fp_src1_ready;
    o_fmul_rs_dispatch.src1_tag   = fp_src1_tag;
    o_fmul_rs_dispatch.src1_value = fp_src1_value;
    o_fmul_rs_dispatch.src2_ready = fp_src2_ready;
    o_fmul_rs_dispatch.src2_tag   = fp_src2_tag;
    o_fmul_rs_dispatch.src2_value = fp_src2_value;
    if (uses_fp_rs3_flag) begin
      o_fmul_rs_dispatch.src3_ready = fp_src3_ready;
      o_fmul_rs_dispatch.src3_tag   = fp_src3_tag;
      o_fmul_rs_dispatch.src3_value = fp_src3_value;
    end

    // FDIV_RS: FDIV uses src1/src2; FSQRT uses only src1.
    o_fdiv_rs_dispatch.src1_ready = fp_src1_ready;
    o_fdiv_rs_dispatch.src1_tag   = fp_src1_tag;
    o_fdiv_rs_dispatch.src1_value = fp_src1_value;
    if (uses_fp_rs2_flag) begin
      o_fdiv_rs_dispatch.src2_ready = fp_src2_ready;
      o_fdiv_rs_dispatch.src2_tag   = fp_src2_tag;
      o_fdiv_rs_dispatch.src2_value = fp_src2_value;
    end

    // Backward-compatible combined dispatch observation used by existing unit
    // tests and debug taps.  Keep this equivalent to the old single-bus source
    // selection; the full CPU's split wrapper path uses the per-RS outputs.
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
  // Slot-2 uses the same per-RS routing as slot-1 but with slot-2 sources.
  // The slot-2 source ready/tag/value triplets (int_src1_2_*, fp_src1_2_*,
  // ...) already include the intra-bundle RAW bypass against slot-1's dest.

  riscv_pkg::rs_dispatch_t rs_dispatch_base_2;

  always_comb begin
    rs_dispatch_base_2                  = '0;

    rs_dispatch_base_2.rs_type          = rs_type_2;
    rs_dispatch_base_2.rob_tag          = i_rob_alloc_resp_2.alloc_tag;
    rs_dispatch_base_2.op               = op_2;

    rs_dispatch_base_2.src1_ready       = 1'b1;
    rs_dispatch_base_2.src2_ready       = 1'b1;
    rs_dispatch_base_2.src3_ready       = 1'b1;

    rs_dispatch_base_2.imm              = imm_2;
    rs_dispatch_base_2.use_imm          = use_imm_2;

    rs_dispatch_base_2.rm               = resolved_rm_2;

    rs_dispatch_base_2.branch_target    = branch_target_2;
    rs_dispatch_base_2.predicted_taken  = predicted_taken_2;
    rs_dispatch_base_2.predicted_target = predicted_target_2;

    rs_dispatch_base_2.is_fp_mem        = is_fp_load_flag_2 || is_fp_store_flag_2;
    rs_dispatch_base_2.mem_needs_lq     = need_lq_2;
    rs_dispatch_base_2.mem_needs_sq     = need_sq_2;
    rs_dispatch_base_2.mem_size         = mem_size_2;
    rs_dispatch_base_2.mem_signed       = mem_signed_2;

    rs_dispatch_base_2.csr_addr         = i_from_id_to_ex_2.csr_address;
    rs_dispatch_base_2.csr_imm          = i_from_id_to_ex_2.csr_imm;

    rs_dispatch_base_2.pc               = i_from_id_to_ex_2.program_counter;
    rs_dispatch_base_2.link_addr        = i_from_id_to_ex_2.link_address;

    // Slot-2 only ever needs a checkpoint when slot-2 is the branch.  Per
    // decision #1 slot-1 is non-branch in that case, so the single
    // checkpoint pool entry is available.
    rs_dispatch_base_2.has_checkpoint   = need_checkpoint_2;
    rs_dispatch_base_2.checkpoint_id    = i_checkpoint_alloc_id;
    rs_dispatch_base_2.is_call          = is_call_flag_2;
    rs_dispatch_base_2.is_return        = is_return_flag_2;
  end

  always_comb begin
    o_int_rs_dispatch_2 = rs_dispatch_base_2;
    o_mul_rs_dispatch_2 = rs_dispatch_base_2;
    o_mem_rs_dispatch_2 = rs_dispatch_base_2;
    o_fp_rs_dispatch_2 = rs_dispatch_base_2;
    o_fmul_rs_dispatch_2 = rs_dispatch_base_2;
    o_fdiv_rs_dispatch_2 = rs_dispatch_base_2;

    o_int_rs_dispatch_2.valid = int_rs_dispatch_fire_2;
    o_mul_rs_dispatch_2.valid = mul_rs_dispatch_fire_2;
    o_mem_rs_dispatch_2.valid = mem_rs_dispatch_fire_2;
    o_fp_rs_dispatch_2.valid = fp_rs_dispatch_fire_2;
    o_fmul_rs_dispatch_2.valid = fmul_rs_dispatch_fire_2;
    o_fdiv_rs_dispatch_2.valid = fdiv_rs_dispatch_fire_2;

    // INT_RS slot-2: integer-only sources.
    if (uses_int_rs1_2) begin
      o_int_rs_dispatch_2.src1_ready = int_src1_2_ready;
      o_int_rs_dispatch_2.src1_tag   = int_src1_2_tag;
      o_int_rs_dispatch_2.src1_value = int_src1_2_value;
    end
    if (uses_int_rs2_2) begin
      o_int_rs_dispatch_2.src2_ready = int_src2_2_ready;
      o_int_rs_dispatch_2.src2_tag   = int_src2_2_tag;
      o_int_rs_dispatch_2.src2_value = int_src2_2_value;
    end

    // MUL_RS slot-2: M-extension always consumes integer rs1/rs2.
    o_mul_rs_dispatch_2.src1_ready = int_src1_2_ready;
    o_mul_rs_dispatch_2.src1_tag   = int_src1_2_tag;
    o_mul_rs_dispatch_2.src1_value = int_src1_2_value;
    o_mul_rs_dispatch_2.src2_ready = int_src2_2_ready;
    o_mul_rs_dispatch_2.src2_tag   = int_src2_2_tag;
    o_mul_rs_dispatch_2.src2_value = int_src2_2_value;

    // MEM_RS slot-2: base = INT rs1; data = INT rs2 or FP rs2 for FP stores.
    if (uses_int_rs1_2) begin
      o_mem_rs_dispatch_2.src1_ready = int_src1_2_ready;
      o_mem_rs_dispatch_2.src1_tag   = int_src1_2_tag;
      o_mem_rs_dispatch_2.src1_value = int_src1_2_value;
    end
    if (uses_fp_rs2_flag_2) begin
      o_mem_rs_dispatch_2.src2_ready = fp_src2_2_ready;
      o_mem_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
      o_mem_rs_dispatch_2.src2_value = fp_src2_2_value;
    end else if (uses_int_rs2_2) begin
      o_mem_rs_dispatch_2.src2_ready = int_src2_2_ready;
      o_mem_rs_dispatch_2.src2_tag   = int_src2_2_tag;
      o_mem_rs_dispatch_2.src2_value = int_src2_2_value;
    end

    // FP_RS slot-2: most ops use FP rs1; INT-to-FP conversions use INT rs1.
    if (uses_fp_rs1_flag_2) begin
      o_fp_rs_dispatch_2.src1_ready = fp_src1_2_ready;
      o_fp_rs_dispatch_2.src1_tag   = fp_src1_2_tag;
      o_fp_rs_dispatch_2.src1_value = fp_src1_2_value;
    end else if (uses_int_rs1_2) begin
      o_fp_rs_dispatch_2.src1_ready = int_src1_2_ready;
      o_fp_rs_dispatch_2.src1_tag   = int_src1_2_tag;
      o_fp_rs_dispatch_2.src1_value = int_src1_2_value;
    end
    if (uses_fp_rs2_flag_2) begin
      o_fp_rs_dispatch_2.src2_ready = fp_src2_2_ready;
      o_fp_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
      o_fp_rs_dispatch_2.src2_value = fp_src2_2_value;
    end

    // FMUL_RS slot-2: FP multiply / FMA.
    o_fmul_rs_dispatch_2.src1_ready = fp_src1_2_ready;
    o_fmul_rs_dispatch_2.src1_tag   = fp_src1_2_tag;
    o_fmul_rs_dispatch_2.src1_value = fp_src1_2_value;
    o_fmul_rs_dispatch_2.src2_ready = fp_src2_2_ready;
    o_fmul_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
    o_fmul_rs_dispatch_2.src2_value = fp_src2_2_value;
    if (uses_fp_rs3_flag_2) begin
      o_fmul_rs_dispatch_2.src3_ready = fp_src3_2_ready;
      o_fmul_rs_dispatch_2.src3_tag   = fp_src3_2_tag;
      o_fmul_rs_dispatch_2.src3_value = fp_src3_2_value;
    end

    // FDIV_RS slot-2: FDIV uses src1/src2; FSQRT uses only src1.
    o_fdiv_rs_dispatch_2.src1_ready = fp_src1_2_ready;
    o_fdiv_rs_dispatch_2.src1_tag   = fp_src1_2_tag;
    o_fdiv_rs_dispatch_2.src1_value = fp_src1_2_value;
    if (uses_fp_rs2_flag_2) begin
      o_fdiv_rs_dispatch_2.src2_ready = fp_src2_2_ready;
      o_fdiv_rs_dispatch_2.src2_tag   = fp_src2_2_tag;
      o_fdiv_rs_dispatch_2.src2_value = fp_src2_2_value;
    end
  end

  // ===========================================================================
  // Checkpoint Management
  // ===========================================================================
  // The checkpoint pool is single-port (one save per cycle).  Per design
  // decision #1 a 2-wide bundle never has both slots be branches, so the
  // pool is sufficient.  When slot-2 is the branch (slot-1 was non-branch),
  // the snapshot's branch_tag points at slot-2's ROB tag and RAS metadata
  // comes from slot-2's IF-time capture.  The slot2_overlay flag drives the
  // RAT snapshot to fold slot-1's same-cycle rename into the saved image so
  // recovery from a slot-2 misprediction reinstates slot-1's allocation
  // (Session F gap fix #6).

  logic checkpoint_save_slot1;
  logic checkpoint_save_slot2;
  assign checkpoint_save_slot1 = dispatch_fire && need_checkpoint;
  assign checkpoint_save_slot2 = bundle_fire_ok && dispatch_valid_2 && need_checkpoint_2;

  always_comb begin
    // Single save signal; either slot-1 OR slot-2 (never both per decision #1).
    o_checkpoint_save = checkpoint_save_slot1 || checkpoint_save_slot2;
    o_checkpoint_save_for_slot2 = checkpoint_save_slot2;
    o_checkpoint_id = i_checkpoint_alloc_id;
    // branch_tag selects which ROB entry the checkpoint protects.  When
    // slot-2 is the branch, the ROB allocates it at tail+1.
    o_checkpoint_branch_tag = checkpoint_save_slot2 ?
                              i_rob_alloc_resp_2.alloc_tag :
                              i_rob_alloc_resp.alloc_tag;

    // RAS state to save: comes from the prediction metadata in the
    // instruction (captured at IF time — reflects RAS state before
    // any push/pop for this instruction).  Use slot-2's IF capture when
    // slot-2 is the branch.
    if (checkpoint_save_slot2) begin
      o_ras_tos         = i_from_id_to_ex_2.ras_checkpoint_tos;
      o_ras_valid_count = i_from_id_to_ex_2.ras_checkpoint_valid_count;
    end else begin
      o_ras_tos         = i_from_id_to_ex.ras_checkpoint_tos;
      o_ras_valid_count = i_from_id_to_ex.ras_checkpoint_valid_count;
    end

    // ROB checkpoint recording (separate from RAT checkpoint).  The ROB's
    // i_checkpoint_valid is single-port and the ROB internally associates
    // it with whichever alloc slot has is_branch set, so we can drive it
    // from the same combined save signal.
    o_rob_checkpoint_valid = o_checkpoint_save;
    o_rob_checkpoint_id    = i_checkpoint_alloc_id;
  end

endmodule : dispatch
