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

// =============================================================================
// commit_bus_pipeline
// =============================================================================
// Extracted verbatim from tomasulo_wrapper.sv (pure RTL boundary move, zero
// functional change).  One-cycle pipeline register on the ROB commit bus that
// breaks the critical path from ROB head_ready/commit_en through SQ/RAT to LQ.
// All internal consumers (RAT, SQ commit, SC logic) use this registered view.
// The valid bits are split out and reset on full flush so Vivado does not drag
// the reset net onto the payload register bits.  Slot 2 (widen-commit) is
// pipelined the same way; it is never SC/AMO/LR by construction.
//
// The wrapper keeps the combinational commit_bus / commit_bus_2 (zero-cycle
// path for cpu_ooo misprediction detection) and the reset-qualified
// reconstruction; only the registers live here.
// =============================================================================
module commit_bus_pipeline (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,

    // Combinational commit bus from the ROB (slot 1 + widen-commit slot 2)
    input riscv_pkg::reorder_buffer_commit_t i_commit_bus,
    input riscv_pkg::reorder_buffer_commit_t i_commit_bus_2,

    // Registered slot-1 commit bus + decomposed fields
    output riscv_pkg::reorder_buffer_commit_t o_commit_bus_q,
    output logic o_commit_bus_q_valid,
    output logic o_commit_q_dest_valid,
    output logic o_commit_q_dest_rf,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_commit_q_dest_reg,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_commit_q_tag,
    output logic o_commit_q_is_sc,
    output logic o_commit_q_is_store_like,
    output logic o_commit_q_sc_failed,

    // Registered slot-2 commit bus + decomposed fields
    output riscv_pkg::reorder_buffer_commit_t o_commit_bus_2_q,
    output logic o_commit_bus_2_q_valid,
    output logic o_commit_q_2_dest_valid,
    output logic o_commit_q_2_dest_rf,
    output logic [riscv_pkg::RegAddrWidth-1:0] o_commit_q_2_dest_reg,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_commit_q_2_tag,
    output logic o_commit_q_2_is_store_like
);

  // ---------------------------------------------------------------------------
  // Alias ports back to the wrapper's local names so the always_ff body below
  // is byte-identical to the original tomasulo_wrapper logic.
  // ---------------------------------------------------------------------------
  riscv_pkg::reorder_buffer_commit_t commit_bus;
  riscv_pkg::reorder_buffer_commit_t commit_bus_2;
  assign commit_bus   = i_commit_bus;
  assign commit_bus_2 = i_commit_bus_2;

  logic commit_bus_q_valid;
  riscv_pkg::reorder_buffer_commit_t commit_bus_q;
  logic commit_q_dest_valid;
  logic commit_q_dest_rf;
  logic [riscv_pkg::RegAddrWidth-1:0] commit_q_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] commit_q_tag;
  logic commit_q_is_sc;
  logic commit_q_is_store_like;
  logic commit_q_sc_failed;
  logic commit_bus_2_q_valid;
  riscv_pkg::reorder_buffer_commit_t commit_bus_2_q;
  logic commit_q_2_dest_valid;
  logic commit_q_2_dest_rf;
  logic [riscv_pkg::RegAddrWidth-1:0] commit_q_2_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] commit_q_2_tag;
  logic commit_q_2_is_store_like;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) commit_bus_q_valid <= 1'b0;
    else commit_bus_q_valid <= commit_bus.valid;
  end

  always_ff @(posedge i_clk) begin
    commit_bus_q <= commit_bus;
    commit_q_dest_valid <= commit_bus.dest_valid;
    commit_q_dest_rf <= commit_bus.dest_rf;
    commit_q_dest_reg <= commit_bus.dest_reg;
    commit_q_tag <= commit_bus.tag;
    commit_q_is_sc <= commit_bus.is_sc;
    commit_q_is_store_like <= commit_bus.is_store || commit_bus.is_fp_store || commit_bus.is_sc;
    commit_q_sc_failed <= commit_bus.is_sc && commit_bus.value[0];
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) commit_bus_2_q_valid <= 1'b0;
    else commit_bus_2_q_valid <= commit_bus_2.valid;
  end

  always_ff @(posedge i_clk) begin
    commit_bus_2_q <= commit_bus_2;
    commit_q_2_dest_valid <= commit_bus_2.dest_valid;
    commit_q_2_dest_rf <= commit_bus_2.dest_rf;
    commit_q_2_dest_reg <= commit_bus_2.dest_reg;
    commit_q_2_tag <= commit_bus_2.tag;
    // Slot 2 excludes SC by construction, so "store_like" collapses to
    // is_store | is_fp_store — the SC discard path is not reachable.
    commit_q_2_is_store_like <= commit_bus_2.is_store || commit_bus_2.is_fp_store;
  end

  // Drive the output ports from the registered locals.
  assign o_commit_bus_q             = commit_bus_q;
  assign o_commit_bus_q_valid       = commit_bus_q_valid;
  assign o_commit_q_dest_valid      = commit_q_dest_valid;
  assign o_commit_q_dest_rf         = commit_q_dest_rf;
  assign o_commit_q_dest_reg        = commit_q_dest_reg;
  assign o_commit_q_tag             = commit_q_tag;
  assign o_commit_q_is_sc           = commit_q_is_sc;
  assign o_commit_q_is_store_like   = commit_q_is_store_like;
  assign o_commit_q_sc_failed       = commit_q_sc_failed;
  assign o_commit_bus_2_q           = commit_bus_2_q;
  assign o_commit_bus_2_q_valid     = commit_bus_2_q_valid;
  assign o_commit_q_2_dest_valid    = commit_q_2_dest_valid;
  assign o_commit_q_2_dest_rf       = commit_q_2_dest_rf;
  assign o_commit_q_2_dest_reg      = commit_q_2_dest_reg;
  assign o_commit_q_2_tag           = commit_q_2_tag;
  assign o_commit_q_2_is_store_like = commit_q_2_is_store_like;

endmodule
