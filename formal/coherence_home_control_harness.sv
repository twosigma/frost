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
module coherence_home_control_harness #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WAYS = 1,
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
  coherence_home #(
      .COMPLETIONS(3),
      .RESULTS(2),
      .FILLS(2),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(2 * LINE_BYTES * WAYS),
      .WAYS(WAYS),
      .ULTRA(0)
  ) home (
      .i_clk,
      .i_rst,
      .i_fatal_stop(i_stop),
      .i_d_valid,
      .o_d_ready(),
      .i_d(demand),
      .o_p_valid(),
      .i_p_ready,
      .o_p(),
      .i_r_valid,
      .o_r_ready(),
      .i_r(reply),
      .i_w_valid,
      .o_w_ready(),
      .i_w(put),
      .o_wa_valid(),
      .i_wa_ready,
      .o_wa(),
      .o_g_valid(),
      .i_g_ready,
      .o_g(),
      .i_c_valid,
      .o_c_ready(),
      .i_c(completion),
      .o_u_valid(),
      .i_u_ready,
      .o_u(),
      .o_mem_req_valid(),
      .i_mem_req_ready(i_mem_ready),
      .o_mem_req_write(),
      .o_mem_req_addr(),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(),
      .i_mem_resp_valid(i_mem_valid),
      .i_mem_resp_id(i_mem_id),
      .i_mem_resp_data('0),
      .i_mem_resp_error(i_mem_error),
      .o_perf_events(),
      .o_write_perf_events(),
      .o_fatal(),
      .o_fatal_addr()
  );
endmodule
