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

module coherence_request_endpoint_equiv #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned SOURCE = 0,
    parameter int unsigned PORT_CLASS = 0,
    parameter int unsigned SLOT = 7
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_epoch,
    input logic i_request_valid,
    input logic [ADDR_WIDTH+311:0] i_request,
    input logic i_d_ready,
    input logic i_g_valid,
    input logic [ADDR_WIDTH+274:0] i_g,
    input logic i_grant_ready,
    input logic i_done_valid,
    input logic [1:0] i_done_status,
    input logic i_write_done,
    input logic i_error_disposed,
    input logic i_c_ready,
    input logic i_u_valid,
    input logic [ADDR_WIDTH+14:0] i_u
);
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
  end
  logic ref_o_request_ready;
  logic ref_o_d_valid;
  logic [ADDR_WIDTH+311:0] ref_o_d;
  logic ref_o_g_ready;
  logic ref_o_grant_valid;
  logic [ADDR_WIDTH+274:0] ref_o_grant;
  logic ref_o_done_ready;
  logic ref_o_c_valid;
  logic ref_o_c_selected;
  logic [ADDR_WIDTH+17:0] ref_o_c;
  logic ref_o_u_ready;
  logic ref_o_live;
  logic [6:0] ref_o_phase;
  coherence_request_endpoint_reference #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .SOURCE(SOURCE),
      .PORT_CLASS(PORT_CLASS),
      .SLOT(SLOT)
  ) reference_endpoint (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(i_epoch),
      .i_request_valid(i_request_valid),
      .i_request(i_request),
      .i_d_ready(i_d_ready),
      .i_g_valid(i_g_valid),
      .i_g(i_g),
      .i_grant_ready(i_grant_ready),
      .i_done_valid(i_done_valid),
      .i_done_status(i_done_status),
      .i_write_done(i_write_done),
      .i_error_disposed(i_error_disposed),
      .i_c_ready(i_c_ready),
      .i_u_valid(i_u_valid),
      .i_u(i_u),
      .o_request_ready(ref_o_request_ready),
      .o_d_valid(ref_o_d_valid),
      .o_d(ref_o_d),
      .o_g_ready(ref_o_g_ready),
      .o_grant_valid(ref_o_grant_valid),
      .o_grant(ref_o_grant),
      .o_done_ready(ref_o_done_ready),
      .o_c_valid(ref_o_c_valid),
      .o_c_selected(ref_o_c_selected),
      .o_c(ref_o_c),
      .o_u_ready(ref_o_u_ready),
      .o_live(ref_o_live),
      .o_phase(ref_o_phase)
  );
  for (genvar mode = 0; mode < 2; mode++) begin : gen_mode
    logic candidate_o_request_ready;
    logic candidate_o_d_valid;
    logic [ADDR_WIDTH+311:0] candidate_o_d;
    logic candidate_o_g_ready;
    logic candidate_o_grant_valid;
    logic [ADDR_WIDTH+274:0] candidate_o_grant;
    logic candidate_o_done_ready;
    logic candidate_o_c_valid;
    logic candidate_o_c_selected;
    logic [ADDR_WIDTH+17:0] candidate_o_c;
    logic candidate_o_u_ready;
    logic candidate_o_live;
    logic [6:0] candidate_o_phase;
    coherence_request_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SOURCE(SOURCE),
        .PORT_CLASS(PORT_CLASS),
        .SLOT(SLOT),
        .LOCAL_PHASE_UPDATES(mode != 0)
    ) candidate_endpoint (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_epoch(i_epoch),
        .i_request_valid(i_request_valid),
        .i_request(i_request),
        .i_d_ready(i_d_ready),
        .i_g_valid(i_g_valid),
        .i_g(i_g),
        .i_grant_ready(i_grant_ready),
        .i_done_valid(i_done_valid),
        .i_done_status(i_done_status),
        .i_write_done(i_write_done),
        .i_error_disposed(i_error_disposed),
        .i_c_ready(i_c_ready),
        .i_u_valid(i_u_valid),
        .i_u(i_u),
        .o_request_ready(candidate_o_request_ready),
        .o_d_valid(candidate_o_d_valid),
        .o_d(candidate_o_d),
        .o_g_ready(candidate_o_g_ready),
        .o_grant_valid(candidate_o_grant_valid),
        .o_grant(candidate_o_grant),
        .o_done_ready(candidate_o_done_ready),
        .o_c_valid(candidate_o_c_valid),
        .o_c_selected(candidate_o_c_selected),
        .o_c(candidate_o_c),
        .o_u_ready(candidate_o_u_ready),
        .o_live(candidate_o_live),
        .o_phase(candidate_o_phase)
    );
    always_ff @(posedge i_clk) begin
      if (f_past_valid) begin
        assert (candidate_o_request_ready == ref_o_request_ready);
        assert (candidate_o_d_valid == ref_o_d_valid);
        assert (candidate_o_d == ref_o_d);
        assert (candidate_o_g_ready == ref_o_g_ready);
        assert (candidate_o_grant_valid == ref_o_grant_valid);
        assert (candidate_o_grant == ref_o_grant);
        assert (candidate_o_done_ready == ref_o_done_ready);
        assert (candidate_o_c_valid == ref_o_c_valid);
        assert (candidate_o_c_selected == ref_o_c_selected);
        assert (candidate_o_c == ref_o_c);
        assert (candidate_o_u_ready == ref_o_u_ready);
        assert (candidate_o_live == ref_o_live);
        assert (candidate_o_phase == ref_o_phase);
        assert ($onehot(candidate_o_phase));
      end
    end
  end
  logic [3:0] progress_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) progress_q <= 0;
    else begin
      case (progress_q)
        0: if (i_request_valid && ref_o_request_ready) progress_q <= 1;
        1: if (ref_o_d_valid && i_d_ready) progress_q <= 2;
        2: if (i_g_valid && ref_o_g_ready) progress_q <= 3;
        3: if (ref_o_grant_valid && i_grant_ready) progress_q <= 4;
        4: if (i_done_valid && ref_o_done_ready) progress_q <= 5;
        5: if (ref_o_c_valid && i_c_ready) progress_q <= 6;
        6: if (i_u_valid && ref_o_u_ready) progress_q <= 7;
        default: progress_q <= progress_q;
      endcase
    end
    if (f_past_valid) cover (progress_q == 7 && !ref_o_live);
  end
endmodule
