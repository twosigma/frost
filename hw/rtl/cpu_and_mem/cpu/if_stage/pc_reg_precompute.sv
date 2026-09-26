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
 * pc_reg + 2, + 4, + 6, and + 8, computed in parallel from the registered
 * i_pc_reg for pc_increment_calculator.
 *
 * The module is a synthesis boundary. pc_increment_calculator instantiates it
 * with (* dont_touch = "yes" *), so Vivado cannot merge these CARRY8 adders
 * with the bundle-advance mux that follows. Merged, the late predecode-derived
 * select would drive the CARRY8 S inputs and put the whole carry chain on the
 * select path. With only a registered input, the sums settle well before the
 * fetch window arrives.
 */
(* keep_hierarchy = "yes" *)
module pc_reg_precompute #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc_reg,

    // One-instruction advances: +2 (compressed) and +4 (32-bit)
    output logic [XLEN-1:0] o_pc_reg_if_compressed,
    output logic [XLEN-1:0] o_pc_reg_if_32bit,
    // Two-instruction bundle advances: RVC+RVC is +4 (o_pc_reg_if_32bit),
    // RVC+32b or 32b+RVC is +6, and 32b+32b is +8.
    output logic [XLEN-1:0] o_pc_reg_plus_6,
    output logic [XLEN-1:0] o_pc_reg_plus_8
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

  logic [XLEN-1:0] pc_reg_plus_2, pc_reg_plus_4;
  logic [XLEN-1:0] pc_reg_plus_6;
  logic [XLEN-1:0] pc_reg_plus_8;
  // Use word-index adders so pc_reg[1] only drives final muxes, not the full
  // high-bit carry chain.
  assign pc_reg_plus_2 = {
    pc_reg_halfword ? pc_reg_word_plus_1 : pc_reg_word, ~pc_reg_halfword, i_pc_reg[0]
  };
  assign pc_reg_plus_4 = {pc_reg_word_plus_1, pc_reg_halfword, i_pc_reg[0]};
  assign pc_reg_plus_6 = {
    pc_reg_halfword ? pc_reg_word_plus_2 : pc_reg_word_plus_1, ~pc_reg_halfword, i_pc_reg[0]
  };
  assign pc_reg_plus_8 = {pc_reg_word_plus_2, pc_reg_halfword, i_pc_reg[0]};

  assign o_pc_reg_if_compressed = pc_reg_plus_2;
  assign o_pc_reg_if_32bit = pc_reg_plus_4;
  assign o_pc_reg_plus_6 = pc_reg_plus_6;
  assign o_pc_reg_plus_8 = pc_reg_plus_8;

endmodule : pc_reg_precompute
