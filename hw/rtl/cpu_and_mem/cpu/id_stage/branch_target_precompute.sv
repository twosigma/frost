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
 * ID-stage PC-relative targets, results, and prediction checks. Dispatch
 * carries the AUIPC result or fetch-fault xtval in the RS immediate, so
 * those operations need no PC at execute.
 *
 * A JALR target needs rs1, so branch resolution computes it and compares it
 * with the predicted target directly.
 */
module branch_target_precompute #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // PC and immediates for target computation
    input  logic [XLEN-1:0] i_program_counter,
    input  logic [XLEN-1:0] i_immediate_b_type,
    input  logic [XLEN-1:0] i_immediate_j_type,
    input  logic [XLEN-1:0] i_immediate_u_type,
    // Branch prediction input
    input  logic [XLEN-1:0] i_btb_predicted_target,
    // Instruction type (for selecting precomputed target)
    input  logic            i_is_jal,
    // Fetch-fault pseudo-op and its faulting-halfword qualifier
    input  logic            i_is_fetch_fault,
    input  logic            i_is_fetch_fault_hi,
    // Pre-computed branch/jump targets
    output logic [XLEN-1:0] o_branch_target_precomputed,
    output logic [XLEN-1:0] o_jal_target_precomputed,
    // Pre-computed PC-relative result: AUIPC's PC + imm_u, or the fetch-fault
    // pseudo-op's xtval (PC, or PC + 2 when only the second halfword faulted)
    output logic [XLEN-1:0] o_pc_relative_precomputed,
    // Non-JALR: the precomputed target equals btb_predicted_target
    output logic            o_btb_correct_non_jalr
);

  assign o_branch_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_b_type));
  assign o_jal_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_j_type));

  // AUIPC and fetch faults share a result adder, separate from the targets.
  logic [XLEN-1:0] pc_relative_offset;
  assign pc_relative_offset = i_is_fetch_fault ?
      {{(XLEN - 2) {1'b0}}, i_is_fetch_fault_hi, 1'b0} : XLEN'(signed'(i_immediate_u_type));
  assign o_pc_relative_precomputed = i_program_counter + pc_relative_offset;

  // Branch resolution uses this comparison bit. The ROB checks a JAL's full
  // target at allocation. Compare both targets before selecting, for timing.
  logic jal_target_matches, branch_target_matches;
  assign jal_target_matches = o_jal_target_precomputed == i_btb_predicted_target;
  assign branch_target_matches = o_branch_target_precomputed == i_btb_predicted_target;
  assign o_btb_correct_non_jalr = i_is_jal ? jal_target_matches : branch_target_matches;

endmodule : branch_target_precompute
