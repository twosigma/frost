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

module coherence_if_pair_formal (
    input logic i_clk
);
  `FROST_COHERENCE_TYPES(32)
  logic past_valid = 0;
  wire  rst = !past_valid;
  always_ff @(posedge i_clk) past_valid <= 1;
  (* anyseq *) logic offer, choose, result_choose, permit_g, permit_c, permit_u;
  logic d_ready, work_valid, result_ready, g_valid, c_ready, u_valid;
  logic [5:0] work_tid;
  coh_d_t demand, work;
  coh_g_t result, grant;
  coh_c_t completion_q;
  coh_u_t released;
  logic [1:0] live_q, result_q, granted_q;
  logic [1:0][5:0] tid_q;
  logic c_valid_q, reused_q, if1_younger_q;
  wire d_valid = !rst && offer && !live_q[choose];
  wire result_valid = !rst && result_q[result_choose];
  wire g_ready = permit_g && !c_valid_q;
  always_comb begin
    demand = '0;
    demand.opcode = coherence_pkg::ReadOnceIF;
    demand.q = choose ? 9'h022 : 9'h020;
    demand.addr = choose ? 32'h80000020 : 32'h80000000;
    result = '0;
    result.opcode = coherence_pkg::GrantData;
    result.q = result_choose ? 9'h022 : 9'h020;
    result.tid = tid_q[result_choose];
    result.addr = result_choose ? 32'h80000020 : 32'h80000000;
  end
  coherence_home_completions #(
      .SLOTS(3),
      .RESULT_SLOTS(2),
      .CACHE_BYTES(256),
      .WAYS(2),
      .PREFETCH_SLOTS(0)
  ) dut (
      .i_clk,
      .i_rst(rst),
      .i_fatal_stop(1'b0),
      .i_d_valid(d_valid),
      .o_d_ready(d_ready),
      .i_d(demand),
      .o_work_valid(work_valid),
      .o_work_offer(),
      .i_work_ready(1'b1),
      .o_work(work),
      .o_work_tid(work_tid),
      .o_work_buffer(),
      .o_work_error(),
      .o_work_counted(),
      .o_work_nofill(),
      .i_count_valid(1'b0),
      .i_count_tid('0),
      .o_waiting(),
      .o_waiting_offer(),
      .o_waiting_request(),
      .i_park('0),
      .i_wake('0),
      .i_wake_error('0),
      .i_retry_park(1'b0),
      .o_image_index(),
      .o_image_select(),
      .i_image_data('0),
      .i_retry_valid(1'b0),
      .i_retry_tid('0),
      .i_pin_valid(1'b0),
      .i_pin_tid('0),
      .i_pin_way('0),
      .i_query_addr('0),
      .o_exclude(),
      .i_next_put_addr('0),
      .o_put_busy(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
      .i_result_valid(result_valid),
      .o_result_ready(result_ready),
      .i_result(result),
      .o_g_valid(g_valid),
      .i_g_ready(g_ready),
      .o_g(grant),
      .i_c_valid(c_valid_q && permit_c),
      .o_c_ready(c_ready),
      .i_c(completion_q),
      .o_u_valid(u_valid),
      .i_u_ready(permit_u),
      .o_u(released)
  );
  always_ff @(posedge i_clk) begin
    if (rst) begin
      live_q <= 0;
      result_q <= 0;
      granted_q <= 0;
      tid_q <= 0;
      completion_q <= '0;
      c_valid_q <= 0;
      reused_q <= 0;
      if1_younger_q <= 0;
    end else begin
      if (d_valid && d_ready) begin
        live_q[choose] <= 1;
        if (choose) if1_younger_q <= live_q[0];
      end
      if (work_valid) begin
        result_q[work.q[1]] <= 1;
        tid_q[work.q[1]] <= work_tid;
      end
      if (result_valid && result_ready) result_q[result_choose] <= 0;
      if (g_valid && g_ready) begin
        granted_q[grant.q[1]] <= 1;
        c_valid_q <= 1;
        completion_q <= {grant.q, grant.tid, grant.addr, coherence_pkg::Consumed, 1'b1};
      end
      if (c_valid_q && permit_c && c_ready) c_valid_q <= 0;
      if (u_valid && permit_u) begin
        live_q[released.q[1]] <= 0;
        granted_q[released.q[1]] <= 0;
        reused_q <= 1;
        if (!released.q[1]) if1_younger_q <= 0;
      end
      cover (&live_q && !(|granted_q));
      cover (if1_younger_q && live_q[0] && g_valid && g_ready &&
          grant.q == 9'h022 && !granted_q[0]);
      cover (if1_younger_q && u_valid && permit_u && released.q == 9'h022 && live_q[0]);
      cover (reused_q && d_valid && d_ready && |live_q);
    end
  end
endmodule
