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
 * Formal-only conservative abstraction of pc_increment_calculator.  The
 * production module's timing-oriented package-typedef $bits expression is not
 * accepted by Yosys 0.64.  The release proof does not depend on increment
 * arithmetic, so every output is left unconstrained.  This admits every
 * production transition plus arbitrary additional PC movements; a passing
 * result is therefore stronger than one tied to a particular increment model.
 */
// verilog_lint: waive module-filename
module pc_increment_calculator #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,
    input logic i_is_compressed,
    input logic i_is_compressed_for_pc,
    input logic i_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // The production module's i_sel_nop cofactors of the two selects (its
    // final 2:1 is steered by i_sel_nop); unused here like the selects.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_prediction_from_buffer_holdoff,
    input logic i_control_flow_to_halfword_r,
    input logic i_stall_registered,
    input logic i_mid_32bit_correction,
    output logic [XLEN-1:0] o_seq_next_pc,
    output logic [XLEN-1:0] o_seq_next_pc_plus_2,
    output riscv_pkg::fetch_verdict_t o_seq_next_pc_verdict,
    output riscv_pkg::fetch_verdict_t o_seq_next_pc_plus_2_verdict,
    output logic [XLEN-1:0] o_seq_next_pc_reg,
    output logic o_seq_next_pc_reg_neq_pc
);

  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc;
  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc_plus_2;
  (* anyseq *) riscv_pkg::fetch_verdict_t f_seq_next_pc_verdict;
  (* anyseq *) riscv_pkg::fetch_verdict_t f_seq_next_pc_plus_2_verdict;
  (* anyseq *) logic [XLEN-1:0] f_seq_next_pc_reg;
  (* anyseq *) logic f_seq_next_pc_reg_neq_pc;

  assign o_seq_next_pc = f_seq_next_pc;
  assign o_seq_next_pc_plus_2 = f_seq_next_pc_plus_2;
  assign o_seq_next_pc_verdict = f_seq_next_pc_verdict;
  assign o_seq_next_pc_plus_2_verdict = f_seq_next_pc_plus_2_verdict;
  assign o_seq_next_pc_reg = f_seq_next_pc_reg;
  assign o_seq_next_pc_reg_neq_pc = f_seq_next_pc_reg_neq_pc;

endmodule : pc_increment_calculator
