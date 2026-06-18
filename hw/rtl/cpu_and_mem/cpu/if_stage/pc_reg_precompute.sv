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
 * PC Register Pre-computation
 *
 * Computes pc_reg + 0/2/4 in parallel and selects the result for both
 * the "instruction is compressed" and "instruction is 32-bit" cases using
 * ONLY registered select signals.
 *
 * This module exists as a synthesis boundary: when instantiated with
 * (* dont_touch = "yes" *), Vivado cannot merge the CARRY8 adder chains
 * with the downstream is_compressed MUX in pc_increment_calculator.
 * Without this boundary, Vivado folds is_compressed (BRAM-dependent,
 * late-arriving) into the CARRY8 S-inputs, putting the entire carry chain
 * on the BRAM->o_pc_reg critical path.
 *
 * All inputs are registered — outputs settle ~0.3 ns into the cycle,
 * well before BRAM data arrives at ~0.9 ns.
 */
(* keep_hierarchy = "yes" *)
module pc_reg_precompute #(
    parameter int unsigned XLEN = 32
) (
    input logic [XLEN-1:0] i_pc_reg,

    // Registered select signals (all early-arriving)
    input logic i_spanning_wait_for_fetch,
    input logic i_spanning_to_halfword_registered,
    input logic i_prediction_from_buffer_holdoff,
    input logic i_spanning_in_progress,
    input logic i_spanning_eligible,

    // Pre-computed results for both is_compressed outcomes
    output logic [XLEN-1:0] o_pc_reg_if_compressed,
    output logic [XLEN-1:0] o_pc_reg_if_32bit,
    // 2-wide dispatch addition.  Slot-2 only fires behind a compressed
    // slot-1, so bundle advances are RVC+RVC (+4) or RVC+32b (+6).
    // The +4 case reuses pc_reg_if_32bit.
    // The hold path also applies — bundles cannot advance pc_reg through a
    // prediction-from-buffer holdoff.
    output logic [XLEN-1:0] o_pc_reg_plus_6
);

  localparam int unsigned PcRegWordBits = XLEN - 2;
  localparam logic [PcRegWordBits-1:0] PcRegWordInc1 = {{(PcRegWordBits - 1) {1'b0}}, 1'b1};
  localparam logic [PcRegWordBits-1:0] PcRegWordInc2 = {{(PcRegWordBits - 2) {1'b0}}, 2'b10};

  logic [PcRegWordBits-1:0] pc_reg_word;
  logic [PcRegWordBits-1:0] pc_reg_word_plus_1;
  logic [PcRegWordBits-1:0] pc_reg_word_plus_2;
  logic                     pc_reg_halfword;
  assign pc_reg_word        = i_pc_reg[XLEN-1:2];
  assign pc_reg_halfword    = i_pc_reg[1];
  assign pc_reg_word_plus_1 = pc_reg_word + PcRegWordInc1;
  assign pc_reg_word_plus_2 = pc_reg_word + PcRegWordInc2;

  logic [XLEN-1:0] pc_reg_plus_0, pc_reg_plus_2, pc_reg_plus_4;
  logic [XLEN-1:0] pc_reg_plus_6;
  assign pc_reg_plus_0 = i_pc_reg;
  // Use word-index adders so pc_reg[1] only drives final muxes, not the full
  // high-bit carry chain.
  assign pc_reg_plus_2 = {
    pc_reg_halfword ? pc_reg_word_plus_1 : pc_reg_word, ~pc_reg_halfword, i_pc_reg[0]
  };
  assign pc_reg_plus_4 = {pc_reg_word_plus_1, pc_reg_halfword, i_pc_reg[0]};
  assign pc_reg_plus_6 = {
    pc_reg_halfword ? pc_reg_word_plus_2 : pc_reg_word_plus_1, ~pc_reg_halfword, i_pc_reg[0]
  };

  // Hold pc_reg at +0 for spanning wait, holdoff cycles
  logic pc_reg_hold;
  assign pc_reg_hold = i_prediction_from_buffer_holdoff;

  // Result assuming instruction is compressed (is_compressed = 1):
  //   is_32bit_spanning = spanning_eligible && !1 = 0, so hold only from pc_reg_hold.
  //   Priority: hold (+0) > compressed && !spanning_in_progress (+2) > default (+4)
  always_comb begin
    if (pc_reg_hold) o_pc_reg_if_compressed = pc_reg_plus_0;
    else o_pc_reg_if_compressed = pc_reg_plus_2;
  end

  // Result assuming instruction is 32-bit (is_compressed = 0):
  //   is_32bit_spanning = spanning_eligible (all registered).
  //   hold (+0) when pc_reg_hold || spanning_eligible, else default (+4).
  assign o_pc_reg_if_32bit = pc_reg_hold ? pc_reg_plus_0 : pc_reg_plus_4;

  // 2-wide bundle advance.  Hold collapses to +0 just like the 1-wide outputs.
  assign o_pc_reg_plus_6   = pc_reg_hold ? pc_reg_plus_0 : pc_reg_plus_6;

endmodule : pc_reg_precompute
