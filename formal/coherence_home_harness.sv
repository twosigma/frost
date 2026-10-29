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

// Three writes visit two conflicting lines while a victim response is delayed.
module coherence_home_harness #(
    parameter bit FAIL_B = 1'b0
) (
    input logic i_clk,
    input logic i_rst
);
  `FROST_COHERENCE_TYPES(32)
  logic past_valid = 1'b0;
  logic [1:0] number_q;
  logic live_q, d_ready, p_valid, r_valid, r_ready, g_valid, c_valid, c_ready, u_valid;
  coh_d_t demand;
  coh_p_t probe;
  coh_r_t reply;
  coh_g_t grant;
  coh_c_t completion;
  logic mem_valid, mem_write, read_pending, b_pending, response_valid;
  logic [4:0] mem_id, b_id, response_id;
  logic [6:0] b_age;
  logic response_error;
  always_comb begin
    demand = '0;
    demand.opcode = coherence_pkg::DMAWrite;
    demand.q.src = 2;
    demand.q.port_class = 3;
    demand.addr = number_q == 1 ? 32'd128 : 32'd0;
    demand.mask = '1;
    response_valid = read_pending || b_pending && b_age == 50;
    response_id = read_pending ? 5'd0 : b_id;
    response_error = !read_pending && FAIL_B;
  end
  coherence_home #(
      .COMPLETIONS(2),
      .RESULTS(2),
      .CACHE_BYTES(128),
      .WAYS(1),
      .ULTRA(0)
  ) home (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(1'b0),
      .i_d_valid(!live_q && number_q < 3),
      .o_d_ready(d_ready),
      .i_d(demand),
      .o_p_valid(p_valid),
      .i_p_ready(!r_valid),
      .o_p(probe),
      .i_r_valid(r_valid),
      .o_r_ready(r_ready),
      .i_r(reply),
      .i_w_valid(1'b0),
      .o_w_ready(),
      .i_w('0),
      .o_wa_valid(),
      .i_wa_ready(1'b1),
      .o_wa(),
      .o_g_valid(g_valid),
      .i_g_ready(1'b1),
      .o_g(grant),
      .i_c_valid(c_valid),
      .o_c_ready(c_ready),
      .i_c(completion),
      .o_u_valid(u_valid),
      .i_u_ready(1'b1),
      .o_u(),
      .o_mem_req_valid(mem_valid),
      .i_mem_req_ready(1'b1),
      .o_mem_req_write(mem_write),
      .o_mem_req_addr(),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(mem_id),
      .i_mem_resp_valid(response_valid),
      .i_mem_resp_id(response_id),
      .i_mem_resp_data(512'b0),
      .i_mem_resp_error(response_error),
      .o_fatal(),
      .o_fatal_addr()
  );
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid)
      assume (i_rst);
      else assume (!i_rst);
    if (i_rst) begin
      number_q <= 0;
      live_q <= 0;
      r_valid <= 0;
      reply <= '0;
      c_valid <= 0;
      completion <= '0;
      read_pending <= 0;
      b_pending <= 0;
      b_id <= 0;
      b_age <= 0;
    end else begin
      if (!live_q && number_q < 3 && d_ready) live_q <= 1;
      if (u_valid) begin
        live_q   <= 0;
        number_q <= number_q + 1'b1;
      end
      if (p_valid && !r_valid) begin
        r_valid <= 1;
        reply <= '0;
        reply.tid <= probe.tid;
        reply.addr <= probe.addr;
        reply.clear <= 1;
      end
      if (r_valid && r_ready) r_valid <= 0;
      if (g_valid) begin
        c_valid <= 1;
        completion.q <= grant.q;
        completion.tid <= grant.tid;
        completion.addr <= grant.addr;
        completion.status <= coherence_pkg::Consumed;
        completion.write_done <= 1;
      end
      if (c_valid && c_ready) c_valid <= 0;
      read_pending <= mem_valid && !mem_write;
      if (mem_valid && mem_write) begin
        b_pending <= 1;
        b_id <= mem_id;
        b_age <= 0;
      end else if (b_pending && b_age < 50) b_age <= b_age + 1'b1;
      if (response_valid && !read_pending) b_pending <= 0;
    end
  end
endmodule
