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
 * ID-stage precomputation of PC-relative values and target-prediction checks,
 * which keeps these adders and comparators out of execute.
 *
 * Pre-computed values:
 *   - Branch target (PC + B-type immediate)
 *   - JAL target (PC + J-type immediate)
 *   - PC-relative result for AUIPC (PC + U-type immediate) and the xtval of a
 *     fetch-fault pseudo-op (PC + faulting-halfword offset); dispatch carries
 *     it in the RS immediate so those ops need no PC at execute
 *   - BTB and RAS correct flags for non-JALR instructions
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
    // Branch prediction inputs
    input  logic [XLEN-1:0] i_ras_predicted_target,
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
    output logic            o_btb_correct_non_jalr,
    // Same compare against the RAS prediction, for non-JALR instructions
    output logic            o_ras_correct_non_jalr
);

  // PC-relative targets. Only the JALR target is left to branch resolution,
  // which has rs1.
  assign o_branch_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_b_type));
  assign o_jal_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_j_type));

  // PC-relative result for AUIPC and the fetch-fault pseudo-ops.  Its own
  // adder: the two target adders above keep their inputs untouched.
  logic [XLEN-1:0] pc_relative_offset;
  assign pc_relative_offset = i_is_fetch_fault ?
      {{(XLEN - 2) {1'b0}}, i_is_fetch_fault_hi, 1'b0} : XLEN'(signed'(i_immediate_u_type));
  assign o_pc_relative_precomputed = i_program_counter + pc_relative_offset;

  // JAL and branches have PC-relative targets, so the whole prediction
  // comparison fits in ID, and branch resolution sees only its one-bit result
  // (the ROB checks a JAL's full target itself at allocation).  Both
  // prediction sources are checked; dispatch forwards the one it selected.
  logic [XLEN-1:0] precomputed_target_for_btb;
  assign precomputed_target_for_btb = i_is_jal ? o_jal_target_precomputed :
                                                 o_branch_target_precomputed;
  assign o_btb_correct_non_jalr = (precomputed_target_for_btb == i_btb_predicted_target);
  assign o_ras_correct_non_jalr = (precomputed_target_for_btb == i_ras_predicted_target);

endmodule : branch_target_precompute
