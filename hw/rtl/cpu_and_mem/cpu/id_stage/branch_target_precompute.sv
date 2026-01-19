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
 * Branch Target Pre-computation for Pipeline Balancing
 *
 * This combinational module pre-computes branch and jump targets in the ID stage
 * to remove adders from the EX stage critical path. It also pre-computes values
 * for RAS and BTB verification.
 *
 * Pre-computed values:
 *   - Branch target (PC + B-type immediate)
 *   - JAL target (PC + J-type immediate)
 *   - RAS expected rs1 (ras_predicted_target - I-type immediate)
 *   - BTB expected rs1 (btb_predicted_target - I-type immediate)
 *   - BTB correct flag for non-JALR instructions
 *
 * TIMING OPTIMIZATION:
 * For JALR instructions, the actual target requires forwarded rs1 and is computed
 * in EX stage. However, we can verify the prediction using algebraic transformation:
 *   actual_target = rs1 + imm
 *   (rs1 + imm == predicted) iff (rs1 == predicted - imm)
 * By pre-computing (predicted - imm) here, we remove the JALR adder from the
 * EX stage comparison critical path.
 */
module branch_target_precompute #(
    parameter int unsigned XLEN = 32
) (
    // PC and immediates for target computation
    input logic [XLEN-1:0] i_program_counter,
    input logic [XLEN-1:0] i_immediate_i_type,
    input logic [XLEN-1:0] i_immediate_b_type,
    input logic [XLEN-1:0] i_immediate_j_type,

    // Branch prediction inputs
    input logic [XLEN-1:0] i_ras_predicted_target,
    input logic [XLEN-1:0] i_btb_predicted_target,

    // Instruction type (for selecting precomputed target)
    input logic i_is_jal,

    // Pre-computed branch/jump targets
    output logic [XLEN-1:0] o_branch_target_precomputed,
    output logic [XLEN-1:0] o_jal_target_precomputed,

    // Pre-computed RAS verification value
    // For JALR returns: expected_rs1 = ras_predicted_target - imm_i
    // EX stage compares: forwarded_rs1 == expected_rs1
    output logic [XLEN-1:0] o_ras_expected_rs1,

    // Pre-computed BTB verification values
    // For JALR: expected_rs1 = btb_predicted_target - imm_i
    // For non-JALR: compare precomputed target with btb_predicted_target
    output logic [XLEN-1:0] o_btb_expected_rs1,
    output logic            o_btb_correct_non_jalr
);

  // Pre-computed branch/jump targets for pipeline balancing.
  // Computing PC-relative targets here removes adders from EX stage critical path.
  // Only JALR target is computed in EX since it requires forwarded rs1.
  assign o_branch_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_b_type));
  assign o_jal_target_precomputed = i_program_counter + XLEN'(signed'(i_immediate_j_type));

  // TIMING OPTIMIZATION: Pre-compute expected rs1 for RAS target verification.
  // For JALR returns: actual_target = rs1 + immediate_i_type
  // Therefore: expected_rs1 = ras_predicted_target - immediate_i_type
  // This allows EX stage to verify RAS prediction by comparing forwarded_rs1
  // with this pre-computed value, removing the JALR adder from the critical path.
  assign o_ras_expected_rs1 = i_ras_predicted_target - XLEN'(signed'(i_immediate_i_type));

  // TIMING OPTIMIZATION: Pre-compute BTB target verification.
  // Same algebraic transformation as RAS, applied to BTB comparison.
  // For JALR: btb_expected_rs1 = btb_predicted_target - immediate_i_type
  //   EX stage compares: forwarded_rs1 == btb_expected_rs1
  assign o_btb_expected_rs1 = i_btb_predicted_target - XLEN'(signed'(i_immediate_i_type));

  // For non-JALR (JAL/branches): targets are PC-relative, computed here
  //   Compare precomputed target with btb_predicted_target in ID stage
  //   This removes the entire comparison from EX stage critical path
  logic [XLEN-1:0] precomputed_target_for_btb;
  assign precomputed_target_for_btb = i_is_jal ? o_jal_target_precomputed :
                                                 o_branch_target_precomputed;

  // Pre-compute BTB correctness for non-JALR instructions
  // This comparison happens in ID stage where timing is not critical
  assign o_btb_correct_non_jalr = (precomputed_target_for_btb == i_btb_predicted_target);

endmodule : branch_target_precompute
