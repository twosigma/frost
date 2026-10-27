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

module debug_fetch_barrier_tb (
    input logic i_clk,
    input logic i_rst,
    input logic i_req_valid,
    input logic [31:0] i_req_addr,
    input logic i_go_taken,
    output logic o_invalidate,
    output logic o_go_valid,
    output logic [31:0] o_go_addr,
    input logic [63:0] i_pc,
    output logic o_line_req_valid,
    input logic i_line_req_ready,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_line_req_addr,
    output logic o_line_req_id,
    input logic i_line_resp_valid,
    input logic i_line_resp_error,
    input logic i_line_resp_id,
    input logic [255:0] i_line_resp_rdata,
    output logic [63:0] o_instr,
    output logic o_instr_valid
);
  debug_fetch_barrier barrier (
      .i_clk,
      .i_rst,
      .i_req_valid,
      .i_req_addr,
      .i_go_taken,
      .o_invalidate,
      .o_go_valid,
      .o_go_addr
  );
  fetch_provider #(
      .LINE_BYTES(32),
      .LINE_ID_BITS(1),
      .VICTIM_LINES(4),
      .DIRECT_LOOKUP(1'b1),
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .CACHED_PROVIDER(1'b0)
  ) fetch (
      .i_clk,
      .i_rst,
      .i_pc,
      .i_pa0(riscv_pkg::PhysAddrBits'(i_pc)),
      .i_pa1(riscv_pkg::PhysAddrBits'(i_pc + 64'd4)),
      .i_pa_valid(1'b1),
      .i_fault0(1'b0),
      .i_fault0_page(1'b0),
      .i_fault1(1'b0),
      .i_fault1_page(1'b0),
      .i_line_after_ok(1'b0),
      .i_retarget(1'b0),
      .i_fetch_replay_consume(1'b0),
      .i_pipeline_stall(1'b0),
      .o_instr,
      .o_instr_sideband(),
      .o_pc_metadata_by_parity(),
      .o_pc_pairability_by_parity(),
      .o_slot2_start_valid_lo_by_parity(),
      .o_instr_bank_sel_r(),
      .o_served_word(),
      .o_served_last_word(),
      .o_served_prev_word(),
      .o_served_prev_word_valid(),
      .o_served_fault0(),
      .o_served_fault0_page(),
      .o_served_fault1(),
      .o_served_fault1_page(),
      .o_instr_valid,
      .o_instr_valid_next(),
      .i_l1i_miss_outstanding(1'b0),
      .o_perf_miss_stall(),
      .o_line_req_valid,
      .i_line_req_ready,
      .o_line_req_write(),
      .o_line_req_addr,
      .o_line_req_wdata(),
      .o_line_req_wstrb(),
      .o_line_req_id,
      .i_line_resp_valid,
      .i_line_resp_error,
      .i_line_resp_id,
      .i_line_resp_rdata,
      .i_invalidate(o_invalidate)
  );
endmodule
