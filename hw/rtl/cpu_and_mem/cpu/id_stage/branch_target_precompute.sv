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
 * ID-stage branch/jump target and prediction-verification precomputation. The
 * adders live here to keep them off the EX critical path.
 *
 * Pre-computed values:
 *   - Branch target (PC + B-type immediate)
 *   - JAL target (PC + J-type immediate)
 *   - PC-relative result for AUIPC (PC + U-type immediate) and the xtval of a
 *     fetch-fault pseudo-op (PC + faulting-halfword offset); dispatch carries
 *     it in the RS immediate so those ops need no PC at execute
 *   - RAS expected rs1 (ras_predicted_target - I-type immediate)
 *   - BTB expected rs1 (btb_predicted_target - I-type immediate)
 *   - BTB and RAS correct flags for non-JALR instructions
 *
 * A JALR target needs forwarded rs1, so EX computes it. The adder still comes
 * out of the prediction check, by rearranging the comparison:
 *   actual_target = rs1 + imm
 *   (rs1 + imm == predicted) iff (rs1 == predicted - imm)
 * EX compares forwarded rs1 against the precomputed (predicted - imm), with no
 * adder in front of the comparator.
 */
module branch_target_precompute #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // PC and immediates for target computation
    input  logic [XLEN-1:0] i_program_counter,
    input  logic [XLEN-1:0] i_immediate_i_type,
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
    // Pre-computed RAS verification value
    // For JALR returns: expected_rs1 = ras_predicted_target - imm_i
    // EX stage compares: forwarded_rs1 == expected_rs1
    output logic [XLEN-1:0] o_ras_expected_rs1,
    // Pre-computed BTB verification values
    // For JALR: expected_rs1 = btb_predicted_target - imm_i
    // For non-JALR: compare precomputed target with btb_predicted_target
    output logic [XLEN-1:0] o_btb_expected_rs1,
    output logic            o_btb_correct_non_jalr,
    // Same compare against the RAS prediction, for non-JALR instructions
    output logic            o_ras_correct_non_jalr
);

  // PC-relative targets. Only the JALR target is left to EX, which is where
  // forwarded rs1 is available.
  assign o_branch_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_b_type));
  assign o_jal_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_j_type));

  // PC-relative result for AUIPC and the fetch-fault pseudo-ops.  Its own
  // adder: the two target adders above keep their inputs untouched.
  logic [XLEN-1:0] pc_relative_offset;
  assign pc_relative_offset = i_is_fetch_fault ?
      {{(XLEN - 2) {1'b0}}, i_is_fetch_fault_hi, 1'b0} : XLEN'(signed'(i_immediate_u_type));
  assign o_pc_relative_precomputed = i_program_counter + pc_relative_offset;

  // Expected rs1 for RAS verification. A JALR return has
  // actual_target = rs1 + immediate_i_type, so the RAS prediction is right
  // exactly when rs1 == ras_predicted_target - immediate_i_type.
  assign o_ras_expected_rs1 = i_ras_predicted_target - XLEN'(signed'(i_immediate_i_type));

  // Same rearrangement for the BTB: EX compares forwarded rs1 against
  // btb_predicted_target - immediate_i_type.
  assign o_btb_expected_rs1 = i_btb_predicted_target - XLEN'(signed'(i_immediate_i_type));

  // JAL and branches have PC-relative targets, so the whole prediction
  // comparison fits in ID and EX sees only its result.  Both prediction
  // sources are checked; dispatch forwards the one it selected.
  logic [XLEN-1:0] precomputed_target_for_btb;
  assign precomputed_target_for_btb = i_is_jal ? o_jal_target_precomputed :
                                                 o_branch_target_precomputed;
  assign o_btb_correct_non_jalr = (precomputed_target_for_btb == i_btb_predicted_target);
  assign o_ras_correct_non_jalr = (precomputed_target_for_btb == i_ras_predicted_target);

endmodule : branch_target_precompute
