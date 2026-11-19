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

// Control interleavings span four cache capacities and three completion identities.
// The four-way configurations let prefetches allocate and meet the fill
// reserve, the last available way and the last write-back slot.
module coherence_home_control_harness #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WAYS = 1,
    parameter int unsigned FILLS = 2,
    parameter int unsigned PREFETCH_RESERVE = FILLS / 4,
    parameter bit ULTRA = 1'b0,
    parameter int unsigned PREFETCH_SLOTS = 0,
    localparam int unsigned AddressBits = $clog2(8 * LINE_BYTES * WAYS)
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stop,
    input logic i_d_valid,
    input logic [343:0] i_d,
    input logic i_p_ready,
    input logic i_r_valid,
    input logic [306:0] i_r,
    input logic i_w_valid,
    input logic [291:0] i_w,
    input logic i_wa_ready,
    input logic i_g_ready,
    input logic i_c_valid,
    input logic [49:0] i_c,
    input logic i_u_ready,
    input logic i_mem_ready,
    input logic i_mem_valid,
    input logic [4:0] i_mem_id,
    input logic i_mem_error
);
  `FROST_COHERENCE_TYPES(32)
  coh_d_t demand;
  coh_r_t reply;
  coh_w_t put;
  coh_c_t completion;
  always_comb begin
    demand = i_d;
    demand.addr[31:AddressBits] = '0;
    demand.wdata = '0;
    reply = i_r;
    reply.addr[31:AddressBits] = '0;
    reply.data = '0;
    put = i_w;
    put.addr[31:AddressBits] = '0;
    put.data = '0;
    completion = i_c;
    completion.addr[31:AddressBits] = '0;
  end
`ifdef COHERENCE_HOME_CMO_WITNESS
  `define FROST_CMO_OBSERVE(signal) signal
  logic witness_d_ready, witness_p_valid, witness_r_ready;
  logic witness_g_valid, witness_c_ready, witness_mem_req;
  logic [4:0] witness_mem_req_id;
  coh_p_t witness_p;
  coh_g_t witness_g;

  typedef enum logic [1:0] {
    AbsentClean,
    ResidentClean,
    DirtyFlush,
    DirtyInval
  } witness_case_t;
  (* anyconst *) witness_case_t witness_case;
  logic witness_reset_seen = 1'b0;
  logic [1:0] witness_demands;
  logic witness_initial;
  coh_d_t witness_d;
  coh_r_t witness_r;
  coh_c_t witness_c;
  logic witness_r_valid, witness_c_valid, witness_mem_valid;
  logic [4:0] witness_mem_id;

  // A GetS installs clean data. GetMZero installs a modified copy.
  always_comb begin
    witness_initial = witness_case != AbsentClean && witness_demands == 0;
    witness_d = '0;
    witness_d.size = 3'd3;
    if (witness_initial) begin
      if (witness_case == ResidentClean) witness_d.opcode = coherence_pkg::GetS;
      else witness_d.opcode = coherence_pkg::GetMZero;
    end else begin
      case (witness_case)
        DirtyInval: witness_d.opcode = coherence_pkg::InvalBlock;
        DirtyFlush: witness_d.opcode = coherence_pkg::FlushBlock;
        default:    witness_d.opcode = coherence_pkg::CleanBlock;
      endcase
      witness_d.q.port_class = 3;
      witness_d.q.id = 4'(coherence_pkg::CmoId);
    end
  end

  // Reply to the home's accepted probes, grants and memory commands.
  always_ff @(posedge i_clk) begin
    witness_reset_seen <= 1'b1;
    assume (i_rst == !witness_reset_seen);
    if (i_rst) begin
      witness_demands <= 0;
      witness_r_valid <= 0;
      witness_c_valid <= 0;
      witness_mem_valid <= 0;
      witness_mem_id <= 0;
      witness_r <= '0;
      witness_c <= '0;
    end else begin
      assume (!i_stop && !i_w_valid && i_wa_ready && i_u_ready && i_mem_ready && !i_mem_error);
      assume (i_d_valid == (witness_demands < (witness_case == AbsentClean ? 1 : 2)));
      assume (i_d == witness_d);
      assume (i_p_ready == !witness_r_valid && i_r_valid == witness_r_valid);
      assume (i_r == witness_r);
      assume (i_g_ready == !witness_c_valid && i_c_valid == witness_c_valid);
      assume (i_c == witness_c);
      assume (i_mem_valid == witness_mem_valid && i_mem_id == witness_mem_id);
      if (i_d_valid && witness_d_ready) witness_demands <= witness_demands + 1'b1;
      if (witness_p_valid && i_p_ready) begin
        witness_r_valid <= 1'b1;
        witness_r <= '0;
        witness_r.tid <= witness_p.tid;
        witness_r.addr <= witness_p.addr;
        witness_r.clear <= 1'b1;
      end else if (i_r_valid && witness_r_ready) witness_r_valid <= 1'b0;
      if (witness_g_valid && i_g_ready) begin
        witness_c_valid <= 1'b1;
        witness_c <= '0;
        witness_c.q <= witness_g.q;
        witness_c.tid <= witness_g.tid;
        witness_c.addr <= witness_g.addr;
        witness_c.status <= coherence_pkg::Consumed;
        witness_c.write_done <= 1'b1;
      end else if (i_c_valid && witness_c_ready) witness_c_valid <= 1'b0;
      witness_mem_valid <= witness_mem_req && i_mem_ready;
      if (witness_mem_req && i_mem_ready) witness_mem_id <= witness_mem_req_id;
    end
  end
`else
  `define FROST_CMO_OBSERVE(signal)
`endif

  coherence_home #(
      .COMPLETIONS(3),
      .RESULTS(2),
      .PREFETCH_SLOTS(PREFETCH_SLOTS),
      .FILLS(FILLS),
      .PREFETCH_RESERVE(PREFETCH_RESERVE),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(2 * LINE_BYTES * WAYS),
      .WAYS(WAYS),
      .ULTRA(ULTRA)
  ) home (
      .i_clk,
      .i_rst,
      .i_fatal_stop(i_stop),
      .i_d_valid,
      .o_d_ready(`FROST_CMO_OBSERVE(witness_d_ready)),
      .i_d(demand),
      .o_p_valid(`FROST_CMO_OBSERVE(witness_p_valid)),
      .i_p_ready,
      .o_p(`FROST_CMO_OBSERVE(witness_p)),
      .i_r_valid,
      .o_r_ready(`FROST_CMO_OBSERVE(witness_r_ready)),
      .i_r(reply),
      .i_w_valid,
      .o_w_ready(),
      .i_w(put),
      .o_wa_valid(),
      .i_wa_ready,
      .o_wa(),
      .o_g_valid(`FROST_CMO_OBSERVE(witness_g_valid)),
      .i_g_ready,
      .o_g(`FROST_CMO_OBSERVE(witness_g)),
      .i_c_valid,
      .o_c_ready(`FROST_CMO_OBSERVE(witness_c_ready)),
      .i_c(completion),
      .o_u_valid(),
      .i_u_ready,
      .o_u(),
      .o_prefetch_room(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
      .o_mem_req_valid(`FROST_CMO_OBSERVE(witness_mem_req)),
      .i_mem_req_ready(i_mem_ready),
      .o_mem_req_write(),
      .o_mem_req_addr(),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(`FROST_CMO_OBSERVE(witness_mem_req_id)),
      .i_mem_resp_valid(i_mem_valid),
      .i_mem_resp_id(i_mem_id),
      .i_mem_resp_data('0),
      .i_mem_resp_error(i_mem_error),
      .o_perf_events(),
      .o_write_perf_events(),
      .o_fatal(),
      .o_fatal_addr()
  );
  `undef FROST_CMO_OBSERVE
endmodule
