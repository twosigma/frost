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
  FP hazard detection logic extracted from hazard_resolution_unit.
  Purely combinational -- detects all floating-point pipeline hazards.

  Hazards detected:
  - FP load-use: FLW in EX with FP consumer in PD (fp_load_potential_hazard)
  - FPU in-flight: any pipelined FP op in flight with FP consumer in PD
  - Single-to-pipelined: FSGNJ* in EX feeding FADD/FMUL/FMA in ID
  - FP-to-int-to-int-to-fp: FP-to-int in EX feeding int-to-FP in PD
  - FP load MA: FLW in MA with multi-cycle FP consumer in PD
  - CSR fflags read: CSRR fflags/frm/fcsr in EX with FP producer in MA
*/
module hru_fp_hazards (
    input  riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input  riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input  riscv_pkg::from_ex_comb_t  i_from_ex_comb,
    input  riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input  logic                      i_stall_registered,
    output logic                      o_fp_load_potential_hazard,
    output logic                      o_fpu_inflight_hazard,
    output logic                      o_fpu_single_to_pipelined_hazard,
    output logic                      o_fp_to_int_to_int_to_fp_hazard,
    output logic                      o_fp_load_ma_hazard,
    output logic                      o_csr_fflags_read_hazard
);

  // F extension: FLW load-use hazard detection
  // FLW writes to FP register, so we check if next instruction uses that FP register
  // FP source registers use the same field positions as integer (rs1/rs2) plus rs3 for FMA
  logic fp_dest_matches_source;
  assign fp_dest_matches_source =
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.fp_source_reg_3_early;

  assign o_fp_load_potential_hazard = i_from_id_to_ex.is_fp_load && fp_dest_matches_source;

  // FP source registers from PD stage (used by multiple hazard checks)
  logic [4:0] fpu_src1, fpu_src2, fpu_src3;
  assign fpu_src1 = i_from_pd_to_id.source_reg_1_early;
  assign fpu_src2 = i_from_pd_to_id.source_reg_2_early;
  assign fpu_src3 = i_from_pd_to_id.fp_source_reg_3_early;

  // ===========================================================================
  // FPU In-Flight Hazard Detection
  // ===========================================================================
  // Conservative timing-friendly rule: if ANY FP op is in flight, stall any FP consumer.
  // This removes wide register-compare trees from the critical path. FP throughput drops,
  // but correctness is preserved (extra stalls only).
  logic fpu_inflight_any;

  assign fpu_inflight_any =
      (i_from_ex_comb.fpu_inflight_dest_1 != 5'b0) ||
      (i_from_ex_comb.fpu_inflight_dest_2 != 5'b0) ||
      (i_from_ex_comb.fpu_inflight_dest_3 != 5'b0) ||
      (i_from_ex_comb.fpu_inflight_dest_4 != 5'b0) ||
      (i_from_ex_comb.fpu_inflight_dest_5 != 5'b0) ||
      (i_from_ex_comb.fpu_inflight_dest_6 != 5'b0);

  // Also stall on the cycle a pipelined FP op enters EX (before inflight dest is recorded).
  // Gate by ~i_stall_registered: only detect on the cycle the instruction actually advances.
  logic fpu_entering_ex_hazard;
  assign fpu_entering_ex_hazard = i_from_id_to_ex.is_pipelined_fp_op && ~i_stall_registered;

  // Check if the instruction in PD stage is an FP consumer (reads from FP registers).
  // Only FP consumer instructions should trigger hazard detection against in-flight FP dests.
  // Without this check, non-FP instructions (e.g., integer ops in TEST() macro) that happen
  // to have register numbers matching in-flight FP destinations would cause spurious stalls.
  logic is_incoming_fp_consumer;
  assign is_incoming_fp_consumer =
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_OP_FP) ||
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_FMADD) ||
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_FMSUB) ||
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_FNMSUB) ||
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_FNMADD) ||
      (i_from_pd_to_id.instruction.opcode ==
       riscv_pkg::OPC_STORE_FP);

  assign o_fpu_inflight_hazard = is_incoming_fp_consumer &&
                                 (fpu_inflight_any || fpu_entering_ex_hazard);

  // ===========================================================================
  // FP Single-Cycle to Pipelined Hazard Detection
  // ===========================================================================
  // When a TRUE SINGLE-CYCLE FP op (FSGNJ*) is in EX and a PIPELINED FP op
  // (FADD, FSUB, FMUL, FMA) in ID depends on it, insert a stall cycle.
  // This is necessary because the registered forwarding signals have OLD values
  // at the posedge when the pipelined op captures operands.
  //
  // NOTE: Multi-cycle ops (FMV.W.X, FCVT, FMIN, FMAX, etc.) are NOT included here
  // because they cause stalls via convert_busy or compare_busy. By the time that
  // stall releases and the consumer enters EX, the producer has moved to MA and
  // normal forwarding handles it.
  logic fp_op_in_ex_is_single_cycle;
  logic fp_op_in_id_is_pipelined;
  logic single_cycle_dest_matches_pipelined_src;

  // Check if instruction in EX is a TRUE single-cycle FP op that writes to FP register.
  // Only FSGNJ* are true single-cycle - they don't use any busy signal and complete
  // in one cycle without stalling the pipeline.
  assign fp_op_in_ex_is_single_cycle = i_from_id_to_ex.is_fp_compute &&
      (i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJ_S ||
       i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJN_S ||
       i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJX_S ||
       i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJ_D ||
       i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJN_D ||
       i_from_id_to_ex.instruction_operation == riscv_pkg::FSGNJX_D);

  // Check if instruction in ID (about to enter EX) is a pipelined FP op
  assign fp_op_in_id_is_pipelined =
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_OP_FP &&
       (i_from_pd_to_id.instruction.funct7[6:1] == 6'b000000 ||  // FADD.{S,D}
      i_from_pd_to_id.instruction.funct7[6:1] == 6'b000010 ||  // FSUB.{S,D}
      i_from_pd_to_id.instruction.funct7[6:1] == 6'b000100)) ||  // FMUL.{S,D}
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_FMADD) ||
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_FMSUB) ||
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_FNMSUB) ||
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_FNMADD);

  // Check if the single-cycle op's dest matches any of the pipelined op's sources
  assign single_cycle_dest_matches_pipelined_src =
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.fp_source_reg_3_early;

  // Detect hazard: single-cycle FP in EX, pipelined FP in ID, with RAW dependency
  // Gate by ~i_stall_registered to only trigger once (not during stall)
  assign o_fpu_single_to_pipelined_hazard = fp_op_in_ex_is_single_cycle &&
                                            fp_op_in_id_is_pipelined &&
                                            single_cycle_dest_matches_pipelined_src &&
                                            ~i_stall_registered;

  // ===========================================================================
  // FP-to-int -> int-to-fp Hazard
  // ===========================================================================
  logic incoming_int_to_fp;

  // FP-to-int -> int-to-fp (FMV.W.X/FCVT.S.W) hazard on integer register
  assign incoming_int_to_fp =
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_OP_FP) && (
      (i_from_pd_to_id.instruction.funct7[6:2] == 5'b11010) ||
      (i_from_pd_to_id.instruction.funct7[6:2] == 5'b11110 &&
       i_from_pd_to_id.instruction.funct3 == 3'b000));

  assign o_fp_to_int_to_int_to_fp_hazard =
      i_from_id_to_ex.is_fp_to_int &&
      incoming_int_to_fp &&
      (i_from_id_to_ex.instruction.dest_reg ==
       i_from_pd_to_id.source_reg_1_early) &&
      ~i_stall_registered;

  // ===========================================================================
  // FP Load (MA) -> Multi-Cycle FP Op (ID) Hazard
  // ===========================================================================
  // Multi-cycle FP ops capture operands at posedge. When an FLW is in MA and the
  // consumer is still in ID, insert a single bubble so the load data is stable
  // before the consumer enters EX.
  logic fp_op_in_id_is_multicycle;
  logic fp_load_ma_matches_src;

  assign fp_op_in_id_is_multicycle = fp_op_in_id_is_pipelined ||
      (i_from_pd_to_id.instruction.opcode == riscv_pkg::OPC_OP_FP &&
       (i_from_pd_to_id.instruction.funct7[6:1] == 6'b000110 ||  // FDIV.{S,D}
      i_from_pd_to_id.instruction.funct7[6:1] == 6'b010110));  // FSQRT.{S,D}

  assign fp_load_ma_matches_src = i_from_ex_to_ma.is_fp_load &&
      (i_from_ex_to_ma.fp_dest_reg == fpu_src1 ||
       i_from_ex_to_ma.fp_dest_reg == fpu_src2 ||
       i_from_ex_to_ma.fp_dest_reg == fpu_src3);

  assign o_fp_load_ma_hazard = fp_op_in_id_is_multicycle && fp_load_ma_matches_src;

  // ===========================================================================
  // CSR fflags/fcsr Read Hazard Detection (F extension)
  // ===========================================================================
  // When a CSR read of fflags/frm/fcsr is in EX and an FP instruction that
  // generates exception flags is in MA, we must stall. The FP instruction's
  // flags won't be accumulated in the CSR until it reaches WB, so reading
  // fflags in EX would get stale data.
  //
  // Hazard scenario:
  //   Cycle N: FSQRT completes EX -> MA, CSRR fflags enters EX (reads stale fflags!)
  //   Cycle N+1: FSQRT MA -> WB (flags accumulated), CSRR EX -> MA
  //   Fix: Stall CSRR in EX until FSQRT reaches WB
  logic is_csr_fflags_read;
  logic fp_flags_producer_in_ma;

  // Detect CSR read of fflags (0x001), frm (0x002), or fcsr (0x003)
  assign is_csr_fflags_read = i_from_id_to_ex.is_csr_instruction &&
      (i_from_id_to_ex.csr_address == riscv_pkg::CsrFflags ||
       i_from_id_to_ex.csr_address == riscv_pkg::CsrFrm ||
       i_from_id_to_ex.csr_address == riscv_pkg::CsrFcsr);

  // Detect FP instruction in MA that produces flags (arithmetic ops, not FMV)
  // Most FP compute ops produce flags except FMV.W.X, FMV.X.W, FSGNJ*, FCLASS
  // For simplicity, we check fp_regfile_write_enable which covers most cases
  // where flags matter (arithmetic results going to FP regfile)
  assign fp_flags_producer_in_ma = i_from_ex_to_ma.is_fp_instruction &&
      (i_from_ex_to_ma.fp_regfile_write_enable || i_from_ex_to_ma.is_fp_to_int);

  // Stall CSR fflags/fcsr read when FP instruction in MA will produce flags
  // Gate by ~i_stall_registered to only trigger once (not during stall cycle)
  assign o_csr_fflags_read_hazard = is_csr_fflags_read && fp_flags_producer_in_ma &&
                                     ~i_stall_registered;

endmodule : hru_fp_hazards
