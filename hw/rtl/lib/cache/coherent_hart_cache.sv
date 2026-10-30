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

module coherent_hart_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TAG_BITS = 5,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned SIM_FAST_MAINT = 0
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
    // Protection covers request presentation as well as acceptance.
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
    output logic o_cut_hold,
    output logic o_cut_admit_valid,
    input logic i_cut_admit_ready,
    output logic [ADDR_WIDTH-1:0] o_cut_address,
    output logic o_cut_inval_valid,
    input logic i_cut_inval_done,
    output logic o_cut_release,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
    input logic i_p_valid,
    output logic o_p_ready,
    input logic [ADDR_WIDTH+29:0] i_p,
    output logic o_r_valid,
    input logic i_r_ready,
    output logic [ADDR_WIDTH+274:0] o_r,
    output logic o_w_valid,
    input logic i_w_ready,
    output logic [ADDR_WIDTH+259:0] o_w,
    input logic i_wa_valid,
    output logic o_wa_ready,
    input logic [ADDR_WIDTH+10:0] i_wa,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic o_c_valid,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    input logic i_iup_req_valid,
    output logic o_iup_req_ready,
    input logic [ADDR_WIDTH-1:0] i_iup_req_addr,
    input logic [3:0] i_iup_req_id,
    output logic o_iup_resp_valid,
    output logic [3:0] o_iup_resp_id,
    output logic [255:0] o_iup_resp_data,
    output logic o_iup_resp_error,
    input logic i_walk_req_valid,
    output logic o_walk_req_ready,
    input logic [ADDR_WIDTH-1:0] i_walk_req_addr,
    input logic [2:0] i_walk_req_id,
    output logic o_walk_resp_valid,
    output logic [2:0] o_walk_resp_id,
    output logic [255:0] o_walk_resp_data,
    output logic o_walk_resp_error,
    input logic i_fence_sync,
    output logic o_fence_done,
    output cache_perf_pkg::cache_instance_perf_events_t o_l1i_perf_events,
    output cache_perf_pkg::cache_instance_perf_events_t o_l1d_perf_events,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);

  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  logic [2:0] d_valid, d_ready, g_ready, c_valid, c_ready, c_selected, u_ready;
  coh_d_t demand[3];
  coh_g_t grant;
  coh_c_t completion[3];
  coh_u_t release_message;
  logic l1d_fatal, l1i_fatal;
  logic [ADDR_WIDTH-1:0] l1d_fatal_addr, l1i_fatal_addr;
  typedef enum logic [2:0] {
    MaintIdle,
    WalkClean,
    WalkDone,
    FenceClean,
    FenceInvalidate,
    FenceWait,
    FenceDone,
    MaintGap
  } maint_state_t;
  maint_state_t maint_state_q;
  logic fence_dropped_q;
  logic maint_valid, maint_done, clean_valid, clean_done;
  logic [ADDR_WIDTH-1:0] clean_addr;
  logic l1i_invalidate, l1i_busy;
  logic if_req_valid, if_req_ready, if_req_write;
  logic [ADDR_WIDTH-1:0] if_req_addr;
  logic [2:0] if_req_id, if_resp_id;
  logic if_resp_valid, if_resp_error;
  logic [255:0] if_resp_data;
  assign grant = i_g;
  assign release_message = i_u;
  assign o_fatal = l1d_fatal || l1i_fatal;
  assign o_fatal_addr = l1d_fatal ? l1d_fatal_addr : l1i_fatal_addr;
  assign o_g_ready = g_ready[grant.q[6:5]];
  assign o_u_ready = u_ready[release_message.q[6:5]];
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(3)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid  (c_valid),
      .o_ready  (c_ready),
      .i_payload({completion[2], completion[1], completion[0]}),
      .o_valid  (o_c_valid),
      .o_offer  (),
      .i_ready  (i_c_ready),
      .o_payload(o_c)
  );
  coherence_d_arbiter #(
      .WIDTH((ADDR_WIDTH + 312)),
      .PORTS(3)
  ) demands (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(d_valid),
      .o_ready(d_ready),
      .i_payload({demand[2], demand[1], demand[0]}),
      .o_valid(o_d_valid),
      .o_offer(),
      .i_ready(i_d_ready),
      .o_payload(o_d)
  );
  coherence_l1d #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .TAG_BITS(TAG_BITS)
  ) l1d (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(i_fatal_stop),
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
      .i_maint_valid(maint_valid),
      .i_maint_line(maint_state_q == WalkClean),
      .i_maint_address(clean_addr),
      .o_maint_done(maint_done),
      .o_cut_hold(o_cut_hold),
      .o_cut_admit_valid(o_cut_admit_valid),
      .i_cut_admit_ready(i_cut_admit_ready),
      .o_cut_address(o_cut_address),
      .o_cut_inval_valid(o_cut_inval_valid),
      .i_cut_inval_done(i_cut_inval_done),
      .o_cut_release(o_cut_release),
      .o_d_valid(d_valid[0]),
      .i_d_ready(d_ready[0]),
      .o_d(demand[0]),
      .i_p_valid(i_p_valid),
      .o_p_ready(o_p_ready),
      .i_p(i_p),
      .o_r_valid(o_r_valid),
      .i_r_ready(i_r_ready),
      .o_r(o_r),
      .o_w_valid(o_w_valid),
      .i_w_ready(i_w_ready),
      .o_w(o_w),
      .i_wa_valid(i_wa_valid),
      .o_wa_ready(o_wa_ready),
      .i_wa(i_wa),
      .i_g_valid(i_g_valid && grant.q[6:5] == 0),
      .o_g_ready(g_ready[0]),
      .i_g(i_g),
      .o_c_valid(c_valid[0]),
      .o_c_selected(c_selected[0]),
      .i_c_ready(c_ready[0]),
      .o_c(completion[0]),
      .i_u_valid(i_u_valid && release_message.q[6:5] == 0),
      .o_u_ready(u_ready[0]),
      .i_u(i_u),
      .o_perf_events(o_l1d_perf_events),
      .o_fatal(l1d_fatal),
      .o_fatal_addr(l1d_fatal_addr)
  );

  frost_cache #(
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1I_CACHE_BYTES),
      .LINE_BYTES(32),
      .WAYS(L1I_WAYS),
      .BIMODAL_INSERT(1'b0),
      .UP_ID_BITS(4),
      .DOWN_ID_BITS(3),
      .NUM_MSHR(2),
      .NUM_WB(2),
      .TAG_MEMORY_PRIMITIVE("block"),
      .TAG_READ_LATENCY(1),
      .DATA_MEMORY_PRIMITIVE("block"),
      .DATA_READ_LATENCY(2),
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
  ) l1i (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .o_fatal_error(l1i_fatal),
      .o_fatal_addr(l1i_fatal_addr),
      .i_writeback_all(1'b0),
      .i_invalidate_all(l1i_invalidate),
      .o_maint_busy(l1i_busy),
      .i_up_req_valid(i_iup_req_valid),
      .o_up_req_ready(o_iup_req_ready),
      .i_up_req_write(1'b0),
      .i_up_req_addr(i_iup_req_addr),
      .i_up_req_wdata('0),
      .i_up_req_wstrb('0),
      .i_up_req_id(i_iup_req_id),
      .i_up_req_maintenance(1'b0),
      .i_up_req_probe(1'b0),
      .i_up_req_probe_inval(1'b0),
      .i_probe_release_valid(1'b0),
      .i_probe_release_id('0),
      .o_up_resp_valid(o_iup_resp_valid),
      .o_up_resp_id(o_iup_resp_id),
      .o_up_resp_error(o_iup_resp_error),
      .o_up_resp_rdata(o_iup_resp_data),
      .o_down_req_valid(if_req_valid),
      .i_down_req_ready(if_req_ready),
      .o_down_req_write(if_req_write),
      .o_down_req_addr(if_req_addr),
      .o_down_req_wdata(),
      .o_down_req_wstrb(),
      .o_down_req_id(if_req_id),
      .o_down_req_maintenance(),
      .i_down_resp_valid(if_resp_valid),
      .i_down_resp_id(if_resp_id),
      .i_down_resp_error(if_resp_error),
      .i_down_resp_rdata(if_resp_data),
      .o_perf_events(o_l1i_perf_events),
      .o_write_perf_events()
  );
  coherence_line_bridge #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .PORT_CLASS(1),
      .CLEAN(1'b0)
  ) if_bridge (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(i_fatal_stop),
      .i_req_valid(if_req_valid),
      .o_req_ready(if_req_ready),
      .i_req_write(if_req_write),
      .i_req_addr(if_req_addr),
      .i_req_data('0),
      .i_req_mask('0),
      .i_req_id(if_req_id),
      .o_resp_valid(if_resp_valid),
      .o_resp_id(if_resp_id),
      .o_resp_data(if_resp_data),
      .o_resp_error(if_resp_error),
      .o_clean_valid(),
      .o_clean_addr(),
      .i_clean_done(1'b0),
      .o_d_valid(d_valid[1]),
      .i_d_ready(d_ready[1]),
      .o_d(demand[1]),
      .i_g_valid(i_g_valid && grant.q[6:5] == 1),
      .o_g_ready(g_ready[1]),
      .i_g(i_g),
      .o_c_valid(c_valid[1]),
      .o_c_selected(c_selected[1]),
      .i_c_ready(c_ready[1]),
      .o_c(completion[1]),
      .i_u_valid(i_u_valid && release_message.q[6:5] == 1),
      .o_u_ready(u_ready[1]),
      .i_u(i_u)
  );
  coherence_line_bridge #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .PORT_CLASS(2),
      .CLEAN(1'b1)
  ) walk_bridge (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(i_fatal_stop),
      .i_req_valid(i_walk_req_valid),
      .o_req_ready(o_walk_req_ready),
      .i_req_write(1'b0),
      .i_req_addr(i_walk_req_addr),
      .i_req_data('0),
      .i_req_mask('0),
      .i_req_id(i_walk_req_id),
      .o_resp_valid(o_walk_resp_valid),
      .o_resp_id(o_walk_resp_id),
      .o_resp_data(o_walk_resp_data),
      .o_resp_error(o_walk_resp_error),
      .o_clean_valid(clean_valid),
      .o_clean_addr(clean_addr),
      .i_clean_done(clean_done),
      .o_d_valid(d_valid[2]),
      .i_d_ready(d_ready[2]),
      .o_d(demand[2]),
      .i_g_valid(i_g_valid && grant.q[6:5] == 2),
      .o_g_ready(g_ready[2]),
      .i_g(i_g),
      .o_c_valid(c_valid[2]),
      .o_c_selected(c_selected[2]),
      .i_c_ready(c_ready[2]),
      .o_c(completion[2]),
      .i_u_valid(i_u_valid && release_message.q[6:5] == 2),
      .o_u_ready(u_ready[2]),
      .i_u(i_u)
  );

  // The maintenance owner is fixed for the complete sweep or line clean.
  assign maint_valid = maint_state_q == WalkClean || maint_state_q == FenceClean;
  assign clean_done = maint_state_q == WalkDone;
  assign l1i_invalidate = maint_state_q == FenceInvalidate;
  assign o_fence_done = maint_state_q == FenceDone;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      maint_state_q   <= MaintIdle;
      fence_dropped_q <= 1'b0;
    end else begin
      if (maint_state_q == MaintIdle) fence_dropped_q <= 1'b0;
      else if (!i_fence_sync) fence_dropped_q <= 1'b1;
      case (maint_state_q)
        MaintIdle: begin
          if (i_fence_sync) maint_state_q <= FenceClean;
          else if (clean_valid) maint_state_q <= WalkClean;
        end
        WalkClean: if (maint_done) maint_state_q <= WalkDone;
        WalkDone: if (!clean_valid) maint_state_q <= MaintGap;
        FenceClean: if (maint_done) maint_state_q <= FenceInvalidate;
        FenceInvalidate: if (l1i_busy) maint_state_q <= FenceWait;
        FenceWait:
        if (!l1i_busy) maint_state_q <= i_fence_sync && !fence_dropped_q ? FenceDone : MaintGap;
        FenceDone: if (!i_fence_sync) maint_state_q <= MaintGap;
        MaintGap: maint_state_q <= MaintIdle;
        default: maint_state_q <= MaintIdle;
      endcase
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    assert (c_valid == (c_selected & {3{!i_rst}}));
    if (!i_rst) begin
      assert ($onehot0(c_ready));
      for (int port_idx = 0; port_idx < 3; port_idx++) begin
        if (c_valid[port_idx] && c_ready[port_idx])
          assert (o_c_valid && i_c_ready && o_c == completion[port_idx]);
      end
    end
  end
`endif
endmodule
