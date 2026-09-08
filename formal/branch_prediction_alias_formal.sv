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

// Public alias equivalence under IF's structural base+2/base+4 wiring.
module branch_prediction_alias_formal (
    input wire [riscv_pkg::XLEN-1:0] live_pc,
    input wire [riscv_pkg::XLEN-1:0] base_pc,
    input wire valid_plus2,
    input wire valid_plus4,
    output wire reference_alias,
    output wire candidate_alias
);
  // Matching-width IF uses these exact candidate widths and constants.
  wire [riscv_pkg::XLEN-1:0] pc_plus2 = base_pc + riscv_pkg::PcIncrementCompressed;
  wire [riscv_pkg::XLEN-1:0] pc_plus4 = base_pc + riscv_pkg::PcIncrement32bit;

  // Pin the generic oracle explicitly so the two parameter modes are tested.
  branch_prediction_controller #(
      .SLOT2_PC_FROM_BASE(1'b0)
  ) reference (
      .i_pc(live_pc),
      .i_pc_2(pc_plus2),
      .i_pc_2_alt(pc_plus4),
      .i_pc_2_base(base_pc),
      .i_slot2_plus2_candidate_valid(valid_plus2),
      .i_slot2_plus4_candidate_valid(valid_plus4),
      .o_slot1_aliases_slot2_candidate(reference_alias)
  );

  branch_prediction_controller #(
      .SLOT2_PC_FROM_BASE(1'b1)
  ) candidate (
      .i_pc(live_pc),
      .i_pc_2(pc_plus2),
      .i_pc_2_alt(pc_plus4),
      .i_pc_2_base(base_pc),
      .i_slot2_plus2_candidate_valid(valid_plus2),
      .i_slot2_plus4_candidate_valid(valid_plus4),
      .o_slot1_aliases_slot2_candidate(candidate_alias)
  );

  // Independent valids expose each predicate separately through the OR output.
  // No alignment, one-hot, fetch-valid, or architectural-PC assumptions.
  always_comb begin
    assert (reference_alias == candidate_alias);
  end
endmodule
