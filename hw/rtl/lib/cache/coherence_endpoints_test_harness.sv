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

module coherence_endpoints_test_harness #(
    parameter int unsigned ADDR_WIDTH  = 32,
    parameter int unsigned NUM_HARTS   = 2,
    parameter int unsigned L2_NUM_MSHR = 4
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_epoch,
    output logic [255:0] o_widths,
    output logic [27:0] o_layout,
    input logic i_req_error_disposed,
    input logic i_req_request_valid,
    output logic o_req_request_ready,
    input logic [ADDR_WIDTH+311:0] i_req_request,
    output logic o_req_d_valid,
    input logic i_req_d_ready,
    output logic [ADDR_WIDTH+311:0] o_req_d,
    input logic i_req_g_valid,
    output logic o_req_g_ready,
    input logic [ADDR_WIDTH+274:0] i_req_g,
    output logic o_req_grant_valid,
    input logic i_req_grant_ready,
    output logic [ADDR_WIDTH+274:0] o_req_grant,
    input logic i_req_done_valid,
    output logic o_req_done_ready,
    input logic [1:0] i_req_done_status,
    input logic i_req_write_done,
    output logic o_req_c_valid,
    input logic i_req_c_ready,
    output logic [ADDR_WIDTH+17:0] o_req_c,
    input logic i_req_u_valid,
    output logic o_req_u_ready,
    input logic [ADDR_WIDTH+14:0] i_req_u,
    output logic o_req_live,
    input logic i_ptw_error_disposed,
    input logic i_ptw_request_valid,
    output logic o_ptw_request_ready,
    input logic [ADDR_WIDTH+311:0] i_ptw_request,
    output logic o_ptw_d_valid,
    input logic i_ptw_d_ready,
    output logic [ADDR_WIDTH+311:0] o_ptw_d,
    input logic i_ptw_g_valid,
    output logic o_ptw_g_ready,
    input logic [ADDR_WIDTH+274:0] i_ptw_g,
    output logic o_ptw_grant_valid,
    input logic i_ptw_grant_ready,
    output logic [ADDR_WIDTH+274:0] o_ptw_grant,
    input logic i_ptw_done_valid,
    output logic o_ptw_done_ready,
    input logic [1:0] i_ptw_done_status,
    input logic i_ptw_write_done,
    output logic o_ptw_c_valid,
    input logic i_ptw_c_ready,
    output logic [ADDR_WIDTH+17:0] o_ptw_c,
    input logic i_ptw_u_valid,
    output logic o_ptw_u_ready,
    input logic [ADDR_WIDTH+14:0] i_ptw_u,
    output logic o_ptw_live,
    input logic i_home_error_disposed,
    input logic i_home_d_valid,
    output logic o_home_d_ready,
    input logic [ADDR_WIDTH+311:0] i_home_d,
    output logic o_home_work_valid,
    output logic [ADDR_WIDTH+311:0] o_home_work,
    input logic i_home_result_valid,
    output logic o_home_result_ready,
    input logic [ADDR_WIDTH+274:0] i_home_result,
    output logic o_home_g_valid,
    input logic i_home_g_ready,
    output logic [ADDR_WIDTH+274:0] o_home_g,
    input logic i_home_c_valid,
    output logic o_home_c_ready,
    input logic [ADDR_WIDTH+17:0] i_home_c,
    input logic i_home_absorb_valid,
    output logic o_home_absorb_ready,
    input logic [ADDR_WIDTH+274:0] i_home_absorb,
    input logic i_home_cancel_valid,
    input logic [ADDR_WIDTH+10:0] i_home_cancel,
    output logic o_home_u_valid,
    input logic i_home_u_ready,
    output logic [ADDR_WIDTH+14:0] o_home_u,
    output logic o_home_live,
    output logic [3:0] o_home_pending,
    input logic i_put0_freeze_valid,
    output logic o_put0_freeze_ready,
    input logic [ADDR_WIDTH+259:0] i_put0_freeze,
    output logic o_put0_w_valid,
    input logic i_put0_w_ready,
    output logic [ADDR_WIDTH+259:0] o_put0_w,
    input logic i_put0_absorb_valid,
    output logic o_put0_absorb_ready,
    input logic [5:0] i_put0_absorb_tid,
    input logic [ADDR_WIDTH-1:0] i_put0_absorb_addr,
    input logic i_put0_absorb_epoch,
    output logic o_put0_absorbed,
    input logic i_put0_wa_valid,
    output logic o_put0_wa_ready,
    input logic [ADDR_WIDTH+10:0] i_put0_wa,
    output logic o_put0_cancel_valid,
    output logic o_put0_live,
    output logic o_put0_fatal,
    input logic i_put1_freeze_valid,
    output logic o_put1_freeze_ready,
    input logic [ADDR_WIDTH+259:0] i_put1_freeze,
    output logic o_put1_w_valid,
    input logic i_put1_w_ready,
    output logic [ADDR_WIDTH+259:0] o_put1_w,
    input logic i_put1_absorb_valid,
    output logic o_put1_absorb_ready,
    input logic [5:0] i_put1_absorb_tid,
    input logic [ADDR_WIDTH-1:0] i_put1_absorb_addr,
    input logic i_put1_absorb_epoch,
    output logic o_put1_absorbed,
    input logic i_put1_wa_valid,
    output logic o_put1_wa_ready,
    input logic [ADDR_WIDTH+10:0] i_put1_wa,
    output logic o_put1_cancel_valid,
    output logic o_put1_live,
    output logic o_put1_fatal,
    input logic i_probe_valid,
    output logic o_probe_ready,
    input logic [ADDR_WIDTH+30-1:0] i_probe_payload,
    output logic o_probe_valid,
    input logic i_probe_ready,
    output logic [ADDR_WIDTH+30-1:0] o_probe_payload,
    input logic i_reply_valid,
    output logic o_reply_ready,
    input logic [ADDR_WIDTH+275-1:0] i_reply_payload,
    output logic o_reply_valid,
    input logic i_reply_ready,
    output logic [ADDR_WIDTH+275-1:0] o_reply_payload
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  coh_d_t  width_d;
  coh_p_t  width_p;
  coh_r_t  width_r;
  coh_w_t  width_w;
  coh_wa_t width_wa;
  coh_g_t  width_g;
  coh_c_t  width_c;
  coh_u_t  width_u;
`ifdef FORMAL
  initial begin
    assert ($bits(width_d) == ADDR_WIDTH + 312);
    assert ($bits(width_p) == ADDR_WIDTH + 30);
    assert ($bits(width_r) == ADDR_WIDTH + 275);
    assert ($bits(width_w) == ADDR_WIDTH + 260);
    assert ($bits(width_wa) == ADDR_WIDTH + 11);
    assert ($bits(width_g) == ADDR_WIDTH + 275);
    assert ($bits(width_c) == ADDR_WIDTH + 18);
    assert ($bits(width_u) == ADDR_WIDTH + 15);
    assert (coherence_pkg::completion_count(1) == 19);
    assert (coherence_pkg::completion_count(2) == 30);
    assert (coherence_pkg::put_base(2, 4) == 34);
    assert (coherence_pkg::put_base(2, 16) == 46);
    assert (coherence_pkg::home_count(2, 4) == 38);
    assert (coherence_pkg::home_count(2, 16) == 50);
    assert (coherence_pkg::home_count(2, 30) == 64);
    assert (coherence_pkg::home_count(1, 43) == 64);
  end
`endif
  assign o_widths = {
    32'($bits(width_d)),
    32'($bits(width_p)),
    32'($bits(width_r)),
    32'($bits(width_w)),
    32'($bits(width_wa)),
    32'($bits(width_g)),
    32'($bits(width_c)),
    32'($bits(width_u))
  };
  assign o_layout = {
    7'(coherence_pkg::completion_count(NUM_HARTS)),
    7'(coherence_pkg::fill_base(NUM_HARTS)),
    7'(coherence_pkg::put_base(NUM_HARTS, L2_NUM_MSHR)),
    7'(coherence_pkg::home_count(NUM_HARTS, L2_NUM_MSHR))
  };
  coherence_request_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_req (
      .i_error_disposed(i_req_error_disposed),
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_request_valid(i_req_request_valid),
      .o_request_ready(o_req_request_ready),
      .i_request(i_req_request),
      .o_d_valid(o_req_d_valid),
      .i_d_ready(i_req_d_ready),
      .o_d(o_req_d),
      .i_g_valid(i_req_g_valid),
      .o_g_ready(o_req_g_ready),
      .i_g(i_req_g),
      .o_grant_valid(o_req_grant_valid),
      .i_grant_ready(i_req_grant_ready),
      .o_grant(o_req_grant),
      .i_done_valid(i_req_done_valid),
      .o_done_ready(o_req_done_ready),
      .i_done_status(i_req_done_status),
      .i_write_done(i_req_write_done),
      .o_c_valid(o_req_c_valid),
      .o_c_selected(),
      .i_c_ready(i_req_c_ready),
      .o_c(o_req_c),
      .i_u_valid(i_req_u_valid),
      .o_u_ready(o_req_u_ready),
      .i_u(i_req_u),
      .o_live(o_req_live)
  );

  coherence_request_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .PORT_CLASS(2)
  ) u_ptw (
      .i_error_disposed(i_ptw_error_disposed),
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_request_valid(i_ptw_request_valid),
      .o_request_ready(o_ptw_request_ready),
      .i_request(i_ptw_request),
      .o_d_valid(o_ptw_d_valid),
      .i_d_ready(i_ptw_d_ready),
      .o_d(o_ptw_d),
      .i_g_valid(i_ptw_g_valid),
      .o_g_ready(o_ptw_g_ready),
      .i_g(i_ptw_g),
      .o_grant_valid(o_ptw_grant_valid),
      .i_grant_ready(i_ptw_grant_ready),
      .o_grant(o_ptw_grant),
      .i_done_valid(i_ptw_done_valid),
      .o_done_ready(o_ptw_done_ready),
      .i_done_status(i_ptw_done_status),
      .i_write_done(i_ptw_write_done),
      .o_c_valid(o_ptw_c_valid),
      .o_c_selected(),
      .i_c_ready(i_ptw_c_ready),
      .o_c(o_ptw_c),
      .i_u_valid(i_ptw_u_valid),
      .o_u_ready(o_ptw_u_ready),
      .i_u(i_ptw_u),
      .o_live(o_ptw_live)
  );

  coherence_home_endpoint #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .NUM_HARTS  (NUM_HARTS),
      .L2_NUM_MSHR(L2_NUM_MSHR)
  ) u_home (
      .i_error_disposed(i_home_error_disposed),
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_d_valid(i_home_d_valid),
      .o_d_ready(o_home_d_ready),
      .i_d(i_home_d),
      .o_work_valid(o_home_work_valid),
      .o_work_offer(),
      .o_work(o_home_work),
      .i_result_valid(i_home_result_valid),
      .o_result_ready(o_home_result_ready),
      .i_result(i_home_result),
      .o_g_valid(o_home_g_valid),
      .i_g_ready(i_home_g_ready),
      .o_g(o_home_g),
      .i_c_valid(i_home_c_valid),
      .o_c_ready(o_home_c_ready),
      .i_c(i_home_c),
      .i_absorb_valid(i_home_absorb_valid),
      .o_absorb_ready(o_home_absorb_ready),
      .i_absorb(i_home_absorb),
      .i_cancel_valid(i_home_cancel_valid),
      .i_cancel(i_home_cancel),
      .o_u_valid(o_home_u_valid),
      .i_u_ready(i_home_u_ready),
      .o_u(o_home_u),
      .o_live(o_home_live),
      .o_pending(o_home_pending)
  );

  coherence_put_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_put0 (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_freeze_valid(i_put0_freeze_valid),
      .o_freeze_ready(o_put0_freeze_ready),
      .i_freeze(i_put0_freeze),
      .o_w_valid(o_put0_w_valid),
      .i_w_ready(i_put0_w_ready),
      .o_w(o_put0_w),
      .i_absorb_valid(i_put0_absorb_valid),
      .o_absorb_ready(o_put0_absorb_ready),
      .i_absorb_tid(i_put0_absorb_tid),
      .i_absorb_addr(i_put0_absorb_addr),
      .i_absorb_epoch(i_put0_absorb_epoch),
      .o_absorbed(o_put0_absorbed),
      .i_wa_valid(i_put0_wa_valid),
      .o_wa_ready(o_put0_wa_ready),
      .i_wa(i_put0_wa),
      .o_cancel_valid(o_put0_cancel_valid),
      .o_live(o_put0_live),
      .o_fatal(o_put0_fatal)
  );

  coherence_put_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .SLOT(1)
  ) u_put1 (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_freeze_valid(i_put1_freeze_valid),
      .o_freeze_ready(o_put1_freeze_ready),
      .i_freeze(i_put1_freeze),
      .o_w_valid(o_put1_w_valid),
      .i_w_ready(i_put1_w_ready),
      .o_w(o_put1_w),
      .i_absorb_valid(i_put1_absorb_valid),
      .o_absorb_ready(o_put1_absorb_ready),
      .i_absorb_tid(i_put1_absorb_tid),
      .i_absorb_addr(i_put1_absorb_addr),
      .i_absorb_epoch(i_put1_absorb_epoch),
      .o_absorbed(o_put1_absorbed),
      .i_wa_valid(i_put1_wa_valid),
      .o_wa_ready(o_put1_wa_ready),
      .i_wa(i_put1_wa),
      .o_cancel_valid(o_put1_cancel_valid),
      .o_live(o_put1_live),
      .o_fatal(o_put1_fatal)
  );

  coherence_channel #(
      .WIDTH(ADDR_WIDTH + 30)
  ) u_probe (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(i_probe_valid),
      .o_ready(o_probe_ready),
      .i_payload(i_probe_payload),
      .o_valid(o_probe_valid),
      .i_ready(i_probe_ready),
      .o_payload(o_probe_payload)
  );

  coherence_channel #(
      .WIDTH(ADDR_WIDTH + 275)
  ) u_reply (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(i_reply_valid),
      .o_ready(o_reply_ready),
      .i_payload(i_reply_payload),
      .o_valid(o_reply_valid),
      .i_ready(i_reply_ready),
      .o_payload(o_reply_payload)
  );
endmodule
