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
 * Formal-only stand-in for pc_increment_calculator in the prediction_release
 * and prediction_handoff targets. Every PC output is unconstrained, which
 * admits every real PC movement and more, so a pass does not depend on the
 * increment arithmetic. The pending-PC relations are full-width compares of
 * those outputs, which pc_increment_relation proves the real calculator
 * matches.
 */
// verilog_lint: waive module-filename
module pc_increment_calculator #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,
    input logic [XLEN-1:0] i_pending_prediction_pc,
    input logic i_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // Selects for each bundle shape; i_sel_nop and i_slot2_valid choose the
    // shape in the real calculator. All selects are unused in this model.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_one,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_two,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_one,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_two,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,
    input logic i_slot2_valid,
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_control_flow_to_halfword_r,
    output logic [XLEN-1:0] o_seq_next_pc,
    output logic [XLEN-1:0] o_seq_next_pc_plus_2,
    output logic [XLEN-1:0] o_seq_next_pc_reg,
    output logic o_seq_next_pc_reg_neq_pc,
    output riscv_pkg::pc_pending_rel_t o_seq_next_pc_reg_rel_pending,
    output riscv_pkg::pc_pending_rel_t o_seq_next_pc_reg_rel_fetch,
    output riscv_pkg::pc_pending_rel_t o_pc_reg_rel_pending,
    output riscv_pkg::pc_pending_rel_t o_pc_reg_rel_fetch
);

  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc;
  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc_plus_2;
  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc_reg;
  (* anyseq *) logic f_seq_next_pc_reg_neq_pc;

  assign o_seq_next_pc = f_seq_next_pc;
  assign o_seq_next_pc_plus_2 = f_seq_next_pc_plus_2;
  assign o_seq_next_pc_reg = f_seq_next_pc_reg;
  assign o_seq_next_pc_reg_neq_pc = f_seq_next_pc_reg_neq_pc;

  function automatic logic [4:0] pending_rel(input logic [XLEN-1:0] v, input logic [XLEN-1:0] side);
    pending_rel = {
      v == side,
      v[XLEN-1:1] < side[XLEN-1:1],
      v[XLEN-1:1] > side[XLEN-1:1],
      v == XLEN'(side - XLEN'(2)),
      v == XLEN'(side - XLEN'(4))
    };
  endfunction
  assign o_seq_next_pc_reg_rel_pending = pending_rel(f_seq_next_pc_reg, i_pending_prediction_pc);
  assign o_seq_next_pc_reg_rel_fetch = pending_rel(f_seq_next_pc_reg, i_pc);
  assign o_pc_reg_rel_pending = pending_rel(i_pc_reg, i_pending_prediction_pc);
  assign o_pc_reg_rel_fetch = pending_rel(i_pc_reg, i_pc);

endmodule : pc_increment_calculator
