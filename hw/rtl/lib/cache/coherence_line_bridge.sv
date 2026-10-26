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

`include "coherence_types.svh"

// A line request owns its identity until the home releases its completion.
module coherence_line_bridge #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned ID_BITS = 3,
    parameter int unsigned SOURCE = 0,
    parameter int unsigned PORT_CLASS = 1,
    parameter bit CLEAN = 1'b0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_req_valid,
    output logic o_req_ready,
    input logic i_req_write,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [255:0] i_req_data,
    input logic [31:0] i_req_mask,
    input logic [ID_BITS-1:0] i_req_id,
    output logic o_resp_valid,
    output logic [255:0] o_resp_data,
    output logic [ID_BITS-1:0] o_resp_id,
    output logic o_resp_error,
    output logic o_clean_valid,
    output logic [ADDR_WIDTH-1:0] o_clean_addr,
    input logic i_clean_done,
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
    Clean,
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
  logic [ID_BITS-1:0] id_q;
  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_req_ready = !i_rst && !i_fatal_stop && phase_q == Idle;
  assign o_clean_valid = !i_rst && phase_q == Clean;
  assign o_clean_addr = demand_q.addr;
  assign o_d_valid = !i_rst && phase_q == Demand;
  assign o_d = demand_q;
  assign o_g_ready = !i_rst && phase_q == Grant && grant_in.q == demand_q.q &&
      grant_in.addr == demand_q.addr;
  assign completion = {
    demand_q.q,
    grant_q.tid,
    demand_q.addr,
    grant_q.error ? coherence_pkg::Error : coherence_pkg::Consumed,
    1'b1
  };
  assign o_c_valid = !i_rst && phase_q == Complete;
  assign o_c = completion;
  assign o_u_ready = !i_rst && phase_q == Release && release_in.q == demand_q.q &&
      release_in.tid == grant_q.tid && release_in.addr == demand_q.addr;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      demand_q <= '0;
      grant_q <= '0;
      id_q <= '0;
      o_resp_valid <= 1'b0;
      o_resp_id <= '0;
      o_resp_data <= '0;
      o_resp_error <= 1'b0;
    end else begin
      o_resp_valid <= 1'b0;
      case (phase_q)
        Idle:
        if (i_req_valid && o_req_ready) begin
          demand_q <= '0;
          demand_q.opcode <= SOURCE == 2 ?
              (i_req_write ? coherence_pkg::DMAWrite : coherence_pkg::DMARead) :
              (PORT_CLASS == 2 ? coherence_pkg::ReadOncePTW : coherence_pkg::ReadOnceIF);
          demand_q.q <= {2'(SOURCE), 2'(PORT_CLASS), SOURCE == 2 ? 4'(i_req_id) : 4'b0, 1'b0};
          demand_q.addr <= {i_req_addr[ADDR_WIDTH-1:5], 5'b0};
          demand_q.mask <= SOURCE == 2 ? i_req_mask : '0;
          demand_q.wdata <= SOURCE == 2 ? i_req_data : '0;
          id_q <= i_req_id;
          phase_q <= CLEAN ? Clean : Demand;
        end
        Clean: if (i_clean_done) phase_q <= Demand;
        Demand: if (i_d_ready) phase_q <= Grant;
        Grant:
        if (i_g_valid && o_g_ready) begin
          grant_q <= grant_in;
          phase_q <= Complete;
        end
        Complete: if (i_c_ready) phase_q <= Release;
        Release:
        if (i_u_valid && o_u_ready) begin
          o_resp_valid <= 1'b1;
          o_resp_id <= id_q;
          o_resp_data <= grant_q.data;
          o_resp_error <= grant_q.error;
          phase_q <= Idle;
        end
        default: phase_q <= Idle;
      endcase
    end
  end
  if (!((SOURCE == 0 && (PORT_CLASS == 1 || PORT_CLASS == 2)) ||
        (SOURCE == 2 && PORT_CLASS == 3 && ID_BITS == 4))) begin : gen_invalid
    initial $fatal(1, "coherence_line_bridge: invalid identity");
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_req_valid && o_req_ready) begin
      assert (i_req_addr[4:0] == 0);
      assert (SOURCE == 2 || !i_req_write);
    end
  end
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (!i_rst && i_req_valid && o_req_ready) begin
      assume (i_req_addr[4:0] == 0);
      assume (SOURCE == 2 || !i_req_write);
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_d_valid && !i_d_ready)) begin
        assert (o_d_valid);
        assert (o_d == $past(o_d));
      end
      if ($past(o_c_valid && !i_c_ready)) begin
        assert (o_c_valid);
        assert (o_c == $past(o_c));
      end
      if (o_resp_valid) assert ($past(i_u_valid && o_u_ready));
      if ($past(phase_q != Idle) && phase_q == Idle) assert ($past(i_u_valid && o_u_ready));
      if (phase_q != Idle && $past(phase_q != Idle)) begin
        assert (id_q == $past(id_q));
        assert (demand_q == $past(demand_q));
      end
      if (o_c_valid) begin
        assert (completion.q == grant_q.q);
        assert (completion.addr == grant_q.addr);
      end
      cover (o_resp_valid && !o_resp_error);
    end
  end
`endif
endmodule
