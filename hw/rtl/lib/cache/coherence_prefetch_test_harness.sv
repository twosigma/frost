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

module coherence_prefetch_test_harness #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned PREFETCH_INFLIGHT = 3,
    parameter bit DMA_PAUSE = 1,
    parameter bit PREFETCH = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_hold_pf_g,
    input logic i_hold_pf_c,
    input logic i_hold_pf_u,
    input logic i_train_enable,
    input logic i_d_valid,
    output logic o_d_ready,
    input logic [ADDR_WIDTH+311:0] i_d,
    output logic o_p_valid,
    input logic i_p_ready,
    output logic [ADDR_WIDTH+29:0] o_p,
    input logic i_r_valid,
    output logic o_r_ready,
    input logic [ADDR_WIDTH+274:0] i_r,
    input logic i_w_valid,
    output logic o_w_ready,
    input logic [ADDR_WIDTH+259:0] i_w,
    output logic o_wa_valid,
    input logic i_wa_ready,
    output logic [ADDR_WIDTH+10:0] o_wa,
    output logic o_g_valid,
    input logic i_g_ready,
    output logic [ADDR_WIDTH+274:0] o_g,
    input logic i_c_valid,
    output logic o_c_ready,
    input logic [ADDR_WIDTH+17:0] i_c,
    output logic o_u_valid,
    input logic i_u_ready,
    output logic [ADDR_WIDTH+14:0] o_u,
    output logic o_mem_req_valid,
    input logic i_mem_req_ready,
    output logic o_mem_req_write,
    output logic [ADDR_WIDTH-1:0] o_mem_req_addr,
    output logic [8*LINE_BYTES-1:0] o_mem_req_data,
    output logic [LINE_BYTES-1:0] o_mem_req_mask,
    output logic [4:0] o_mem_req_id,
    input logic i_mem_resp_valid,
    input logic [4:0] i_mem_resp_id,
    input logic [8*LINE_BYTES-1:0] i_mem_resp_data,
    input logic i_mem_resp_error,
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
    output cache_perf_pkg::cache_write_perf_events_t o_write_perf_events,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  coh_d_t home_d, pf_d;
  coh_g_t home_g;
  coh_c_t home_c, pf_c;
  coh_u_t home_u;
  logic home_d_valid, home_d_ready, pf_d_valid;
  logic home_g_valid, home_g_ready, pf_g_ready;
  logic home_c_valid, home_c_ready, pf_c_valid, home_c_pass;
  logic home_u_valid, home_u_ready, pf_u_ready;
  logic [1:0] d_ready, c_ready;

  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(2)
  ) demands (
      .i_clk,
      .i_rst,
      .i_valid({pf_d_valid, i_d_valid}),
      .o_ready(d_ready),
      .i_payload({pf_d, i_d}),
      .o_valid(home_d_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_d_ready),
      .o_payload(home_d)
  );
  assign o_d_ready = d_ready[0];
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(2),
      .HOLD_VALID(1)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid({pf_c_valid, i_c_valid}),
      .o_ready(c_ready),
      .i_payload({pf_c, i_c}),
      .o_valid(home_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_c_ready && home_c_pass),
      .o_payload(home_c)
  );
  assign home_c_pass = home_c.q.src != 2'd3 || !i_hold_pf_c;
  assign o_c_ready = c_ready[0];
  assign o_g_valid = home_g_valid && home_g.q.src != 2'd3;
  assign o_g = home_g;
  assign home_g_ready = home_g.q.src == 2'd3 ? pf_g_ready && !i_hold_pf_g : i_g_ready;
  assign o_u_valid = home_u_valid && home_u.q.src != 2'd3;
  assign o_u = home_u;
  assign home_u_ready = home_u.q.src == 2'd3 ? pf_u_ready && !i_hold_pf_u : i_u_ready;

  coh_d_t demand;
  assign demand = i_d;
  logic dma_pause;
  wire dma_offer = i_d_valid && demand.q.src == 2'd2;
  wire pf_pause = DMA_PAUSE && dma_pause;
  // The transport driver admits DMA at D. Its response pulses follow the
  // ingress policy: reads after G, writes after U, with one pulse per cycle.
  logic [15:0] dma_write_q;
  logic [3:0] dma_reads_q;
  logic dma_response_q;
  wire dma_read_grant = o_g_valid && i_g_ready && home_g.q.src == 2'd2 && !dma_write_q[home_g.q.id];
  wire dma_write_release = o_u_valid && i_u_ready && home_u.q.src == 2'd2 &&
      dma_write_q[home_u.q.id];
  wire dma_read_response = (|dma_reads_q) && !dma_write_release;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dma_write_q <= '0;
      dma_reads_q <= '0;
      dma_response_q <= 1'b0;
    end else begin
      if (dma_offer && o_d_ready)
        dma_write_q[demand.q.id] <= demand.opcode == coherence_pkg::DMAWrite;
      dma_reads_q <= dma_reads_q + 4'(dma_read_grant) - 4'(dma_read_response);
      dma_response_q <= dma_write_release || dma_read_response;
    end
  end
  coherence_prefetch_pause pause_control (
      .i_clk,
      .i_rst,
      .i_dma_valid(dma_offer),
      .i_dma_accept(dma_offer && o_d_ready),
      .i_dma_response(dma_response_q),
      .o_pause(dma_pause)
  );

  if (PREFETCH) begin : gen_prefetch
    coherence_prefetch_agent #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .L2_LINE_BYTES(LINE_BYTES),
        .MAX_INFLIGHT(PREFETCH_INFLIGHT)
    ) agent (
        .i_clk,
        .i_rst,
        .i_fatal_stop,
        .i_pause(pf_pause),
        .i_train_valid(i_d_valid && d_ready[0] && i_train_enable),
        .i_train_d(i_d),
        .o_d_valid(pf_d_valid),
        .i_d_ready(d_ready[1]),
        .o_d(pf_d),
        .i_g_valid(home_g_valid && !i_hold_pf_g),
        .o_g_ready(pf_g_ready),
        .i_g(home_g),
        .o_c_valid(pf_c_valid),
        .i_c_ready(c_ready[1]),
        .o_c(pf_c),
        .i_u_valid(home_u_valid && !i_hold_pf_u),
        .o_u_ready(pf_u_ready),
        .i_u(home_u)
    );
  end else begin : gen_no_prefetch
    assign pf_d_valid = 1'b0;
    assign pf_d = '0;
    assign pf_c_valid = 1'b0;
    assign pf_c = '0;
    assign pf_g_ready = 1'b0;
    assign pf_u_ready = 1'b0;
  end

  coherence_home #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(16 * LINE_BYTES),
      .SIM_FAST_MAINT(1)
  ) home (
      .i_clk,
      .i_rst,
      .i_fatal_stop,
      .i_d_valid(home_d_valid),
      .o_d_ready(home_d_ready),
      .i_d(home_d),
      .o_p_valid,
      .i_p_ready,
      .o_p,
      .i_r_valid,
      .o_r_ready,
      .i_r,
      .i_w_valid,
      .o_w_ready,
      .i_w,
      .o_wa_valid,
      .i_wa_ready,
      .o_wa,
      .o_g_valid(home_g_valid),
      .i_g_ready(home_g_ready),
      .o_g(home_g),
      .i_c_valid(home_c_valid && home_c_pass),
      .o_c_ready(home_c_ready),
      .i_c(home_c),
      .o_u_valid(home_u_valid),
      .i_u_ready(home_u_ready),
      .o_u(home_u),
      .o_mem_req_valid,
      .i_mem_req_ready,
      .o_mem_req_write,
      .o_mem_req_addr,
      .o_mem_req_data,
      .o_mem_req_mask,
      .o_mem_req_id,
      .i_mem_resp_valid,
      .i_mem_resp_id,
      .i_mem_resp_data,
      .i_mem_resp_error,
      .o_perf_events,
      .o_write_perf_events,
      .o_fatal,
      .o_fatal_addr
  );
endmodule
