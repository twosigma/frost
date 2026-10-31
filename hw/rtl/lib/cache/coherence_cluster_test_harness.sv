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

module coherence_cluster_test_harness #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned TAG_BITS   = 7,
    // L1D request endpoints.
    parameter int unsigned L1D_MISSES = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_read_valid,
    input logic [2:0] i_read_id,
    input logic [1:0] i_read_kind,
    input logic [2:0] i_read_size,
    input logic [TAG_BITS-1:0] i_read_tag,
    input logic [ADDR_WIDTH-1:0] i_address,
    output logic o_read_valid,
    input logic i_read_ready,
    output logic [2:0] o_read_id,
    output logic [63:0] o_read_data,
    output logic o_read_error,
    input logic [7:0] i_write_mask,
    input logic [63:0] i_write_data,
    input logic i_write_atomic,
    input logic i_write_sc,
    input logic [TAG_BITS-1:0] i_write_tag,
    output logic o_write_done,
    output logic o_write_inflight,
    output logic o_store_ready,
    output logic o_pending_store,
    output logic o_sc_write_pending,
    output logic o_atomic_live,
    output logic [1:0] o_block_valid,
    output logic [1:0][ADDR_WIDTH-1:0] o_block_addr,
    input logic i_atomic_protected,
    input logic i_sc_valid,
    output logic o_sc_ready,
    input logic [ADDR_WIDTH-1:0] i_sc_address,
    input logic [2:0] i_sc_size,
    input logic [TAG_BITS-1:0] i_sc_tag,
    input logic i_sc_commit,
    output logic o_sc_result_valid,
    input logic i_sc_result_ready,
    output logic o_sc_success,
    output logic o_sc_error,
    output logic o_sc_write_done,
    output logic [TAG_BITS-1:0] o_sc_write_tag,
    input logic i_reservation_valid,
    input logic [ADDR_WIDTH-1:0] i_reservation_addr,
    input logic [2:0] i_reservation_size,
    input logic i_maint_valid,
    input logic i_maint_line,
    input logic [ADDR_WIDTH-1:0] i_maint_address,
    output logic o_maint_done,
    output logic o_cut_hold,
    output logic o_cut_admit_valid,
    input logic i_cut_admit_ready,
    output logic [ADDR_WIDTH-1:0] o_cut_address,
    output logic o_cut_inval_valid,
    input logic i_cut_inval_done,
    output logic o_cut_release,
    input logic i_hold_grant,
    input logic i_agent_valid,
    output logic o_agent_ready,
    input logic [ADDR_WIDTH+311:0] i_agent_d,
    output logic o_agent_g_valid,
    input logic i_agent_g_ready,
    output logic [ADDR_WIDTH+274:0] o_agent_g,
    input logic i_agent_c_valid,
    output logic o_agent_c_ready,
    input logic [ADDR_WIDTH+17:0] i_agent_c,
    output logic o_agent_u_valid,
    input logic i_agent_u_ready,
    output logic [ADDR_WIDTH+14:0] o_agent_u,
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
    output cache_perf_pkg::cache_instance_perf_events_t o_l1d_perf,
    output cache_perf_pkg::cache_instance_perf_events_t o_l2_perf,
    output cache_perf_pkg::cache_write_perf_events_t o_l2_write_perf,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  coh_d_t home_d;
  logic [L1D_MISSES-1:0][ADDR_WIDTH+311:0] hart_d;
  logic [L1D_MISSES-1:0][ADDR_WIDTH+17:0] hart_c;
  coh_p_t probe;
  coh_r_t reply;
  coh_w_t put;
  coh_wa_t ack;
  coh_g_t grant;
  coh_c_t home_c;
  coh_u_t release_message;
  logic [L1D_MISSES-1:0] hart_d_valid, hart_d_ready, hart_c_valid, hart_c_ready;
  logic home_d_valid, home_d_ready;
  logic p_valid, p_ready, r_valid, r_ready, w_valid, w_ready, wa_valid, wa_ready;
  logic g_valid, g_ready, hart_g_ready, home_c_valid, home_c_ready;
  logic u_valid, u_ready, hart_u_ready;
  logic hart_fatal, home_fatal;
  logic [ADDR_WIDTH-1:0] hart_fatal_addr, home_fatal_addr;
  assign o_fatal = hart_fatal || home_fatal;
  assign o_fatal_addr = hart_fatal ? hart_fatal_addr : home_fatal_addr;
  coherence_l1d #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_BYTES(1024),
      .TAG_BITS(TAG_BITS),
      .MISSES(L1D_MISSES)
  ) hart (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(i_fatal_stop || o_fatal),
      .i_read_valid(i_read_valid),
      .i_read_id(i_read_id),
      .i_read_kind(i_read_kind),
      .i_read_size(i_read_size),
      .i_read_tag(i_read_tag),
      .i_address(i_address),
      .o_read_valid(o_read_valid),
      .i_read_ready(i_read_ready),
      .o_read_id(o_read_id),
      .o_read_data(o_read_data),
      .o_read_error(o_read_error),
      .i_write_mask(i_write_mask),
      .i_write_data(i_write_data),
      .i_write_atomic(i_write_atomic),
      .i_write_sc(i_write_sc),
      .i_write_tag(i_write_tag),
      .o_write_done(o_write_done),
      .o_write_inflight(o_write_inflight),
      .o_store_ready(o_store_ready),
      .o_pending_store(o_pending_store),
      .o_sc_write_pending(o_sc_write_pending),
      .o_atomic_live(o_atomic_live),
      .o_block_valid(o_block_valid),
      .o_block_addr(o_block_addr),
      .i_atomic_protected(i_atomic_protected),
      .i_sc_valid(i_sc_valid),
      .o_sc_ready(o_sc_ready),
      .i_sc_address(i_sc_address),
      .i_sc_size(i_sc_size),
      .i_sc_tag(i_sc_tag),
      .i_sc_commit(i_sc_commit),
      .o_sc_result_valid(o_sc_result_valid),
      .i_sc_result_ready(i_sc_result_ready),
      .o_sc_success(o_sc_success),
      .o_sc_error(o_sc_error),
      .o_sc_write_done(o_sc_write_done),
      .o_sc_write_tag(o_sc_write_tag),
      .i_reservation_valid(i_reservation_valid),
      .i_reservation_addr(i_reservation_addr),
      .i_reservation_size(i_reservation_size),
      .i_maint_valid(i_maint_valid),
      .i_maint_line(i_maint_line),
      .i_maint_address(i_maint_address),
      .o_maint_done(o_maint_done),
      .o_cut_hold(o_cut_hold),
      .o_cut_admit_valid(o_cut_admit_valid),
      .i_cut_admit_ready(i_cut_admit_ready),
      .o_cut_address(o_cut_address),
      .o_cut_inval_valid(o_cut_inval_valid),
      .i_cut_inval_done(i_cut_inval_done),
      .o_cut_release(o_cut_release),
      .o_d_valid(hart_d_valid),
      .i_d_ready(hart_d_ready),
      .o_d(hart_d),
      .i_p_valid(p_valid),
      .o_p_ready(p_ready),
      .i_p(probe),
      .o_r_valid(r_valid),
      .i_r_ready(r_ready),
      .o_r(reply),
      .o_w_valid(w_valid),
      .i_w_ready(w_ready),
      .o_w(put),
      .i_wa_valid(wa_valid),
      .o_wa_ready(wa_ready),
      .i_wa(ack),
      .i_g_valid(g_valid && grant.q.src == 0 && !i_hold_grant),
      .o_g_ready(hart_g_ready),
      .i_g(grant),
      .o_c_valid(hart_c_valid),
      .o_c_selected(),
      .i_c_ready(hart_c_ready),
      .o_c(hart_c),
      .i_u_valid(u_valid && release_message.q.src == 0),
      .o_u_ready(hart_u_ready),
      .i_u(release_message),
      .o_perf_events(o_l1d_perf),
      .o_fatal(hart_fatal),
      .o_fatal_addr(hart_fatal_addr)
  );
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(L1D_MISSES + 1)
  ) arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid({i_agent_valid, hart_d_valid}),
      .o_ready({o_agent_ready, hart_d_ready}),
      .i_payload({i_agent_d, hart_d}),
      .o_valid(home_d_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_d_ready),
      .o_payload(home_d)
  );
  assign o_agent_g_valid = g_valid && grant.q.src == 2;
  assign o_agent_g = grant;
  assign g_ready = grant.q.src == 2 ? i_agent_g_ready : hart_g_ready && !i_hold_grant;
  assign o_agent_u_valid = u_valid && release_message.q.src == 2;
  assign o_agent_u = release_message;
  assign u_ready = release_message.q.src == 2 ? i_agent_u_ready : hart_u_ready;
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(L1D_MISSES + 1),
      .HOLD_VALID(1)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid({i_agent_c_valid, hart_c_valid}),
      .o_ready({o_agent_c_ready, hart_c_ready}),
      .i_payload({i_agent_c, hart_c}),
      .o_valid(home_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_c_ready),
      .o_payload(home_c)
  );
  coherence_home #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .CACHE_BYTES(512),
      .LINE_BYTES (LINE_BYTES)
  ) home (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(i_fatal_stop || o_fatal),
      .i_d_valid(home_d_valid),
      .o_d_ready(home_d_ready),
      .i_d(home_d),
      .o_p_valid(p_valid),
      .i_p_ready(p_ready),
      .o_p(probe),
      .i_r_valid(r_valid),
      .o_r_ready(r_ready),
      .i_r(reply),
      .i_w_valid(w_valid),
      .o_w_ready(w_ready),
      .i_w(put),
      .o_wa_valid(wa_valid),
      .i_wa_ready(wa_ready),
      .o_wa(ack),
      .o_g_valid(g_valid),
      .i_g_ready(g_ready),
      .o_g(grant),
      .i_c_valid(home_c_valid),
      .o_c_ready(home_c_ready),
      .i_c(home_c),
      .o_u_valid(u_valid),
      .i_u_ready(u_ready),
      .o_u(release_message),
      .o_mem_req_valid(o_mem_req_valid),
      .i_mem_req_ready(i_mem_req_ready),
      .o_mem_req_write(o_mem_req_write),
      .o_mem_req_addr(o_mem_req_addr),
      .o_mem_req_data(o_mem_req_data),
      .o_mem_req_mask(o_mem_req_mask),
      .o_mem_req_id(o_mem_req_id),
      .i_mem_resp_valid(i_mem_resp_valid),
      .i_mem_resp_id(i_mem_resp_id),
      .i_mem_resp_data(i_mem_resp_data),
      .i_mem_resp_error(i_mem_resp_error),
      .o_perf_events(o_l2_perf),
      .o_write_perf_events(o_l2_write_perf),
      .o_fatal(home_fatal),
      .o_fatal_addr(home_fatal_addr)
  );
endmodule
