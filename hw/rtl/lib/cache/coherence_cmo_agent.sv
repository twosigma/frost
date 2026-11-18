/*
 *    Copyright (c) 2026 John Goodacre.
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

`include "coherence_types.svh"

// The hart's Zicbom requester (see the cache README, Zicbom write-back). The
// store queue hands it one 64-byte block at a time, after every older store
// has installed in the L1D. It sends one CleanBlock, FlushBlock or InvalBlock
// per home line (two with 32-byte home lines) with the identity
// {SOURCE, class 3, coherence_pkg::CmoId}, takes the home's GrantAck, completes it and waits
// for the release, then pulses o_done. The home recalls the L1D's copies
// through probes, so the L1D holds no CMO state.
//
// Kinds follow riscv_pkg::cmo_kind_e: 0 inval, 1 clean, 2 flush. A grant with
// its error bit set completes with Error and raises o_error until reset (the
// home raises its fatal stop for a failed memory write).
module coherence_cmo_agent #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned HOME_LINE_BYTES = 64,
    parameter int unsigned SOURCE = 0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_req_valid,
    output logic o_req_ready,
    input logic [1:0] i_req_kind,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    output logic o_done,
    output logic o_error,
    // No block in flight.
    output logic o_idle,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic o_c_valid,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  typedef enum logic [2:0] {
    Idle,
    Demand,
    Grant,
    Complete,
    Release
  } phase_t;
  phase_t phase_q;
  coh_d_t demand_q;
  coh_g_t grant_in, grant_q;
  coh_c_t completion;
  coh_u_t release_in;
  // With 32-byte home lines a block is two home lines; the second request
  // follows the first one's release.
  localparam bit TwoLines = HOME_LINE_BYTES == 32;
  logic second_q;

  function automatic logic [3:0] cmo_opcode(input logic [1:0] kind);
    unique case (kind)
      2'd1: cmo_opcode = coherence_pkg::CleanBlock;
      2'd2: cmo_opcode = coherence_pkg::FlushBlock;
      default: cmo_opcode = coherence_pkg::InvalBlock;
    endcase
  endfunction

  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_req_ready = !i_fatal_stop && phase_q == Idle;
  assign o_idle = phase_q == Idle;
  assign o_d_valid = phase_q == Demand;
  assign o_d = demand_q;
  assign o_g_ready = phase_q == Grant && grant_in.q == demand_q.q && grant_in.addr == demand_q.addr;
  always_comb begin
    completion = '0;
    completion.q = demand_q.q;
    completion.tid = grant_q.tid;
    completion.addr = demand_q.addr;
    completion.status = grant_q.error ? coherence_pkg::Error : coherence_pkg::Consumed;
  end
  assign o_c_valid = phase_q == Complete;
  assign o_c = completion;
  assign o_u_ready = phase_q == Release && release_in.q == demand_q.q &&
      release_in.tid == grant_q.tid && release_in.addr == demand_q.addr;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q  <= Idle;
      demand_q <= '0;
      grant_q  <= '0;
      second_q <= 1'b0;
      o_done   <= 1'b0;
      o_error  <= 1'b0;
    end else begin
      o_done <= 1'b0;
      case (phase_q)
        Idle:
        if (i_req_valid && !i_fatal_stop) begin
          demand_q <= '0;
          demand_q.opcode <= cmo_opcode(i_req_kind);
          demand_q.q <= {2'(SOURCE), 2'd3, 4'(coherence_pkg::CmoId), 1'b0};
          demand_q.addr <= {i_req_addr[ADDR_WIDTH-1:6], 6'b0};
          demand_q.maintenance <= 1'b1;
          second_q <= 1'b0;
          phase_q <= Demand;
        end
        Demand:   if (i_d_ready) phase_q <= Grant;
        Grant:
        if (i_g_valid && o_g_ready) begin
          grant_q <= grant_in;
          if (grant_in.error) o_error <= 1'b1;
          phase_q <= Complete;
        end
        Complete: if (i_c_ready) phase_q <= Release;
        Release:
        if (i_u_valid && o_u_ready) begin
          if (TwoLines && !second_q) begin
            second_q <= 1'b1;
            demand_q.addr <= demand_q.addr | ADDR_WIDTH'(32);
            phase_q <= Demand;
          end else begin
            o_done  <= 1'b1;
            phase_q <= Idle;
          end
        end
        default:  phase_q <= Idle;
      endcase
    end
  end

  if (HOME_LINE_BYTES != 32 && HOME_LINE_BYTES != 64) begin : gen_invalid
    initial $fatal(1, "coherence_cmo_agent: HOME_LINE_BYTES must be 32 or 64");
  end

  // Simulation checks; the formal tasks that compose this requester keep
  // their own assertion counts.
`ifndef SYNTHESIS
`ifndef FORMAL
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      if (phase_q != Idle) begin
        assert (coherence_pkg::is_cmo(demand_q.opcode) && demand_q.maintenance);
        assert (demand_q.q == {2'(SOURCE), 2'd3, 4'(coherence_pkg::CmoId), 1'b0});
        assert (demand_q.addr[4:0] == 0);
        if (!TwoLines) assert (demand_q.addr[5] == 0);
      end
      // The home answers a Zicbom request with GrantAck alone.
      if (i_g_valid && o_g_ready) assert (grant_in.opcode == coherence_pkg::GrantAck);
    end
`endif
`endif
endmodule
