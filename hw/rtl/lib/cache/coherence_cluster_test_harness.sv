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
    parameter int unsigned TAG_BITS = 7,
    // L1D request endpoints.
    parameter int unsigned L1D_MISSES = 1,
    parameter int unsigned L1D_CACHE_BYTES = 1024,
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned HOME_CACHE_BYTES = 512,
    parameter int unsigned HOME_WAYS = 4,
    parameter int unsigned HOME_COMPLETIONS = coherence_pkg::completion_count(1),
    parameter int unsigned HOME_RESULTS = 8,
    parameter int unsigned HOME_FILLS = 8,
    parameter int unsigned HOME_PREFETCH_SLOTS = coherence_pkg::PrefetchIds,
    parameter bit L1D_STREAM_PREFETCH = 1'b0,
    // Register stages between the L1D and the home, as cpu_top's
    // MEMORY_LINK_STAGES places them. With stages, the grant, put-ack and
    // release holds delay the home's side, because the L1D side of those
    // links takes every message.
    parameter int unsigned LINK_STAGES = 0
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
    input logic i_write_zero = 1'b0,
    input logic [TAG_BITS-1:0] i_write_tag,
    output logic o_write_done,
    output logic o_write_inflight,
    output logic o_store_ready,
    output logic o_pending_store,
    output logic o_sc_write_pending,
    output logic o_atomic_live,
    output logic [3:0] o_block_valid,
    output logic [3:0][ADDR_WIDTH-1:0] o_block_addr,
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
    input logic i_hold_wa,
    input logic i_hold_release,
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
    output logic [L1D_MISSES-1:0] o_live_stores,
    output logic [1:0] o_held_puts,
    output logic o_load_grant,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr,
    // The hart's line client (source 0, class 3), crossing LINK_STAGES as
    // cpu_top places it.
    input logic i_line_req_valid,
    output logic o_line_req_ready,
    input logic i_line_req_write,
    input logic [ADDR_WIDTH-1:0] i_line_req_addr,
    input logic [255:0] i_line_req_data,
    input logic [31:0] i_line_req_mask,
    input logic [3:0] i_line_req_id,
    output logic o_line_resp_valid,
    output logic [3:0] o_line_resp_id,
    output logic [255:0] o_line_resp_data,
    output logic o_line_resp_error
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
  // The L1D's side of each channel; equal to the home's side without stages.
  coh_p_t  l1d_probe;
  coh_r_t  l1d_reply;
  coh_w_t  l1d_put;
  coh_wa_t l1d_ack;
  coh_g_t  l1d_grant;
  coh_u_t  l1d_release;
  logic l1d_p_valid, l1d_p_ready, l1d_r_valid, l1d_r_ready, l1d_w_valid, l1d_w_ready;
  logic l1d_wa_valid, l1d_wa_ready, l1d_g_valid, l1d_g_ready, l1d_u_valid, l1d_u_ready;
  logic [L1D_MISSES-1:0] l1d_d_valid, l1d_d_ready, l1d_c_valid, l1d_c_ready;
  logic [L1D_MISSES-1:0][ADDR_WIDTH+311:0] l1d_d;
  logic [L1D_MISSES-1:0][ ADDR_WIDTH+17:0] l1d_c;
  logic hart_fatal, home_fatal;
  logic [1:0] accepted_puts_q;
  // The line client's channels: line_* on its side, home_line_* on the home's.
  coh_d_t line_d, home_line_d;
  coh_c_t line_c, home_line_c;
  coh_g_t line_g;
  coh_u_t line_u;
  logic line_d_valid, line_d_ready, home_line_d_valid, home_line_d_ready;
  logic line_c_valid, line_c_ready, home_line_c_valid, home_line_c_ready;
  logic line_g_valid, line_g_ready, line_u_valid, line_u_ready;
  wire grant_line = grant.q.src == 0 && grant.q.port_class == 3;
  wire release_line = release_message.q.src == 0 && release_message.q.port_class == 3;
  logic [ADDR_WIDTH-1:0] hart_fatal_addr, home_fatal_addr;
  assign o_fatal = hart_fatal || home_fatal;
  assign o_fatal_addr = hart_fatal ? hart_fatal_addr : home_fatal_addr;
  // A reader ordered behind a lookahead store can hold that store's fill,
  // so the head store's acquisition needs a second fill.
  if (L1D_MISSES >= 3 && HOME_FILLS < 2) begin : gen_invalid_fills
    initial $fatal(1, "coherence_cluster_test_harness: three or more L1D endpoints need two fills");
  end
  assign o_held_puts = accepted_puts_q | (w_valid ? (2'b01 << put.put_id) : 2'b00);
  assign o_load_grant = g_valid && g_ready && grant.q.src == 0 &&
      grant.opcode == coherence_pkg::GrantS;
  always_ff @(posedge i_clk) begin
    if (i_rst) accepted_puts_q <= '0;
    else begin
      if (w_valid && w_ready) accepted_puts_q[put.put_id] <= 1'b1;
      if (wa_valid && wa_ready && !i_hold_wa) accepted_puts_q[ack.put_id] <= 1'b0;
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) o_live_stores <= '0;
    else begin
      for (int ep = 0; ep < L1D_MISSES; ep++) begin
        if (home_d_valid && home_d_ready && home_d.q.src == 0 && coherence_pkg::is_getm(
                home_d.opcode
            ) && home_d.q.id == 4'(ep))
          o_live_stores[ep] <= 1'b1;
        if (u_valid && u_ready && release_message.q.src == 0 && release_message.q.id == 4'(ep))
          o_live_stores[ep] <= 1'b0;
      end
    end
  end
  coherence_l1d #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_BYTES(L1D_CACHE_BYTES),
      .WAYS(L1D_WAYS),
      .TAG_BITS(TAG_BITS),
      .MISSES(L1D_MISSES),
      .HOME_CACHE_BYTES(HOME_CACHE_BYTES),
      .HOME_WAYS(HOME_WAYS),
      .HOME_LINE_BYTES(LINE_BYTES),
      .STREAM_PREFETCH(L1D_STREAM_PREFETCH),
      .WITHDRAW_ABSORBED_W(LINK_STAGES != 0)
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
      .i_write_zero(i_write_zero),
      .i_write_tag(i_write_tag),
      .o_write_done(o_write_done),
      .o_write_inflight(o_write_inflight),
      .o_store_ready(o_store_ready),
      .o_twin_push(),
      .o_twin_push_addr(),
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
      .o_d_valid(l1d_d_valid),
      .i_d_ready(l1d_d_ready),
      .o_d(l1d_d),
      .i_p_valid(l1d_p_valid),
      .o_p_ready(l1d_p_ready),
      .i_p(l1d_probe),
      .o_r_valid(l1d_r_valid),
      .i_r_ready(l1d_r_ready),
      .o_r(l1d_reply),
      .o_w_valid(l1d_w_valid),
      .i_w_ready(l1d_w_ready),
      .o_w(l1d_put),
      .i_wa_valid(l1d_wa_valid),
      .o_wa_ready(l1d_wa_ready),
      .i_wa(l1d_ack),
      .i_g_valid(l1d_g_valid),
      .o_g_ready(l1d_g_ready),
      .i_g(l1d_grant),
      .o_c_valid(l1d_c_valid),
      .i_c_ready(l1d_c_ready),
      .o_c(l1d_c),
      .i_u_valid(l1d_u_valid),
      .o_u_ready(l1d_u_ready),
      .i_u(l1d_release),
      .o_perf_events(o_l1d_perf),
      .o_fatal(hart_fatal),
      .o_fatal_addr(hart_fatal_addr)
  );
  if (LINK_STAGES == 0) begin : gen_direct
    // The L1D's endpoints meet the home's arbiters directly.
    assign hart_d_valid = l1d_d_valid;
    assign l1d_d_ready = hart_d_ready;
    assign hart_d = l1d_d;
    assign hart_c_valid = l1d_c_valid;
    assign l1d_c_ready = hart_c_ready;
    assign hart_c = l1d_c;
    assign l1d_p_valid = p_valid;
    assign p_ready = l1d_p_ready;
    assign l1d_probe = probe;
    assign r_valid = l1d_r_valid;
    assign l1d_r_ready = r_ready;
    assign reply = l1d_reply;
    assign w_valid = l1d_w_valid;
    assign l1d_w_ready = w_ready;
    assign put = l1d_put;
    assign l1d_wa_valid = wa_valid && !i_hold_wa;
    assign wa_ready = l1d_wa_ready;
    assign l1d_ack = ack;
    assign l1d_g_valid = g_valid && grant.q.src == 0 && !grant_line && !i_hold_grant;
    assign hart_g_ready = l1d_g_ready;
    assign l1d_grant = grant;
    assign l1d_u_valid = u_valid && release_message.q.src == 0 && !release_line && !i_hold_release;
    assign hart_u_ready = l1d_u_ready;
    assign l1d_release = release_message;
  end else begin : gen_links
    // As in cpu_top: the L1D's demands and completions merge on its side,
    // then cross one credit link each; the home's arbiters see a single hart
    // port at index 0 and nothing at the others.
    logic d_valid, d_ready, c_valid, c_ready, link_d_valid, link_c_valid;
    logic link_g_valid, link_u_valid, link_wa_valid;
    logic [ADDR_WIDTH+311:0] d_payload, linked_d;
    logic [ADDR_WIDTH+17:0] c_payload, linked_c;
    coherence_d_arbiter #(
        .WIDTH(ADDR_WIDTH + 312),
        .PORTS(L1D_MISSES)
    ) l1d_demands (
        .i_clk,
        .i_rst,
        .i_valid(l1d_d_valid),
        .o_ready(l1d_d_ready),
        .i_payload(l1d_d),
        .o_valid(d_valid),
        .o_selected(),
        .i_ready(d_ready),
        .o_payload(d_payload)
    );
    coherence_d_arbiter #(
        .WIDTH(ADDR_WIDTH + 18),
        .PORTS(L1D_MISSES),
        .HOLD_VALID(1)
    ) l1d_completions (
        .i_clk,
        .i_rst,
        .i_valid(l1d_c_valid),
        .o_ready(l1d_c_ready),
        .i_payload(l1d_c),
        .o_valid(c_valid),
        .o_selected(),
        .i_ready(c_ready),
        .o_payload(c_payload)
    );
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 312),
        .STAGES(LINK_STAGES),
        .KIND  (1)
    ) link_d (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (d_valid),
        .o_ready  (d_ready),
        .i_payload(d_payload),
        .o_valid  (link_d_valid),
        .i_ready  (hart_d_ready[0]),
        .o_payload(linked_d)
    );
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 18),
        .STAGES(LINK_STAGES),
        .KIND  (1)
    ) link_c (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (c_valid),
        .o_ready  (c_ready),
        .i_payload(c_payload),
        .o_valid  (link_c_valid),
        .i_ready  (hart_c_ready[0]),
        .o_payload(linked_c)
    );
    always_comb begin
      hart_d_valid = '0;
      hart_d = '0;
      hart_c_valid = '0;
      hart_c = '0;
      hart_d_valid[0] = link_d_valid;
      hart_d[0] = linked_d;
      hart_c_valid[0] = link_c_valid;
      hart_c[0] = linked_c;
    end
    coherence_link #(
        .WIDTH(ADDR_WIDTH + 30),
        .STAGES(LINK_STAGES),
        .KIND(1),
        .CREDITS(1)
    ) link_p (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (p_valid),
        .o_ready  (p_ready),
        .i_payload(probe),
        .o_valid  (l1d_p_valid),
        .i_ready  (l1d_p_ready),
        .o_payload(l1d_probe)
    );
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 275),
        .STAGES(LINK_STAGES),
        .KIND  (0)
    ) link_r (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (l1d_r_valid),
        .o_ready  (l1d_r_ready),
        .i_payload(l1d_reply),
        .o_valid  (r_valid),
        .i_ready  (r_ready),
        .o_payload(reply)
    );
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 260),
        .STAGES(LINK_STAGES),
        .KIND  (2)
    ) link_w (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (l1d_w_valid),
        .o_ready  (l1d_w_ready),
        .i_payload(l1d_put),
        .o_valid  (w_valid),
        .i_ready  (w_ready),
        .o_payload(put)
    );
    // The holds stall the home's side; the links' L1D side takes every
    // message they present.
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 11),
        .STAGES(LINK_STAGES),
        .KIND  (0)
    ) link_wa (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (wa_valid && !i_hold_wa),
        .o_ready  (),
        .i_payload(ack),
        .o_valid  (link_wa_valid),
        .i_ready  (l1d_wa_ready),
        .o_payload(l1d_ack)
    );
    assign l1d_wa_valid = link_wa_valid;
    assign wa_ready = 1'b1;
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 275),
        .STAGES(LINK_STAGES),
        .KIND  (0)
    ) link_g (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (g_valid && grant.q.src == 0 && !grant_line && !i_hold_grant),
        .o_ready  (),
        .i_payload(grant),
        .o_valid  (link_g_valid),
        .i_ready  (l1d_g_ready),
        .o_payload(l1d_grant)
    );
    assign l1d_g_valid  = link_g_valid;
    assign hart_g_ready = 1'b1;
    coherence_link #(
        .WIDTH (ADDR_WIDTH + 15),
        .STAGES(LINK_STAGES),
        .KIND  (0)
    ) link_u (
        .i_clk,
        .i_rst,
        .i_stopped(o_fatal),
        .i_valid  (u_valid && release_message.q.src == 0 && !release_line && !i_hold_release),
        .o_ready  (),
        .i_payload(release_message),
        .o_valid  (link_u_valid),
        .i_ready  (l1d_u_ready),
        .o_payload(l1d_release)
    );
    assign l1d_u_valid  = link_u_valid;
    assign hart_u_ready = 1'b1;
  end
  coherence_dma_ingress #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .SOURCE(2'd0),
      .PORT_CLASS(2'd3),
      .SLOTS(coherence_pkg::HartLineIds)
  ) line_client (
      .i_clk,
      .i_rst,
      .i_fatal_stop(i_fatal_stop || o_fatal),
      .i_req_valid(i_line_req_valid),
      .o_req_ready(o_line_req_ready),
      .i_req_write(i_line_req_write),
      .i_req_addr(i_line_req_addr),
      .i_req_data(i_line_req_data),
      .i_req_mask(i_line_req_mask),
      .i_req_id(i_line_req_id),
      .i_req_non_alloc(1'b0),
      .o_resp_valid(o_line_resp_valid),
      .o_resp_data(o_line_resp_data),
      .o_resp_id(o_line_resp_id),
      .o_resp_error(o_line_resp_error),
      .o_d_valid(line_d_valid),
      .i_d_ready(line_d_ready),
      .o_d(line_d),
      .i_g_valid(line_g_valid),
      .o_g_ready(line_g_ready),
      .i_g(line_g),
      .o_c_valid(line_c_valid),
      .i_c_ready(line_c_ready),
      .o_c(line_c),
      .i_u_valid(line_u_valid),
      .o_u_ready(line_u_ready),
      .i_u(line_u)
  );
  coherence_link #(
      .WIDTH (ADDR_WIDTH + 312),
      .STAGES(LINK_STAGES),
      .KIND  (1)
  ) link_line_d (
      .i_clk,
      .i_rst,
      .i_stopped(o_fatal),
      .i_valid  (line_d_valid),
      .o_ready  (line_d_ready),
      .i_payload(line_d),
      .o_valid  (home_line_d_valid),
      .i_ready  (home_line_d_ready),
      .o_payload(home_line_d)
  );
  coherence_link #(
      .WIDTH (ADDR_WIDTH + 18),
      .STAGES(LINK_STAGES),
      .KIND  (1)
  ) link_line_c (
      .i_clk,
      .i_rst,
      .i_stopped(o_fatal),
      .i_valid  (line_c_valid),
      .o_ready  (line_c_ready),
      .i_payload(line_c),
      .o_valid  (home_line_c_valid),
      .i_ready  (home_line_c_ready),
      .o_payload(home_line_c)
  );
  coherence_link #(
      .WIDTH (ADDR_WIDTH + 275),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_line_g (
      .i_clk,
      .i_rst,
      .i_stopped(o_fatal),
      .i_valid  (g_valid && grant_line),
      .o_ready  (),
      .i_payload(grant),
      .o_valid  (line_g_valid),
      .i_ready  (line_g_ready),
      .o_payload(line_g)
  );
  coherence_link #(
      .WIDTH (ADDR_WIDTH + 15),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_line_u (
      .i_clk,
      .i_rst,
      .i_stopped(o_fatal),
      .i_valid  (u_valid && release_line),
      .o_ready  (),
      .i_payload(release_message),
      .o_valid  (line_u_valid),
      .i_ready  (line_u_ready),
      .o_payload(line_u)
  );
`ifndef SYNTHESIS
  // The client takes every G and U its always-taken links present.
  logic line_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) line_reset_seen_q <= 1'b1;
    if (line_reset_seen_q && !i_rst && !o_fatal && !i_fatal_stop) begin
      if (line_g_valid) p_line_g_taken : assert (line_g_ready);
      if (line_u_valid) p_line_u_taken : assert (line_u_ready);
    end
  end
`endif
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(L1D_MISSES + 2)
  ) arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid({home_line_d_valid, i_agent_valid, hart_d_valid}),
      .o_ready({home_line_d_ready, o_agent_ready, hart_d_ready}),
      .i_payload({home_line_d, i_agent_d, hart_d}),
      .o_valid(home_d_valid),
      .o_selected(),
      .i_ready(home_d_ready),
      .o_payload(home_d)
  );
  // The agent port carries DMA (source 2) and prefetch (source 3) traffic.
  // The home takes a source-3 G as accepted when it is presented, so the
  // agent must take it on that cycle.
  assign o_agent_g_valid = g_valid && grant.q.src >= 2;
  assign o_agent_g = grant;
  assign g_ready = grant.q.src == 3 || grant_line ? 1'b1 :
      grant.q.src == 2 ? i_agent_g_ready : hart_g_ready && !i_hold_grant;
  assign o_agent_u_valid = u_valid && release_message.q.src >= 2;
  assign o_agent_u = release_message;
  assign u_ready = release_message.q.src >= 2 ? i_agent_u_ready :
      release_line || (hart_u_ready && !i_hold_release);
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(L1D_MISSES + 2),
      .HOLD_VALID(1)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid({home_line_c_valid, i_agent_c_valid, hart_c_valid}),
      .o_ready({home_line_c_ready, o_agent_c_ready, hart_c_ready}),
      .i_payload({home_line_c, i_agent_c, hart_c}),
      .o_valid(home_c_valid),
      .o_selected(),
      .i_ready(home_c_ready),
      .o_payload(home_c)
  );
  coherence_home #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_BYTES(HOME_CACHE_BYTES),
      .WAYS(HOME_WAYS),
      .COMPLETIONS(HOME_COMPLETIONS),
      .RESULTS(HOME_RESULTS),
      .FILLS(HOME_FILLS),
      .PREFETCH_SLOTS(HOME_PREFETCH_SLOTS),
      .LINE_BYTES(LINE_BYTES)
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
      .i_wa_ready(wa_ready && !i_hold_wa),
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
      .o_prefetch_room(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
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
