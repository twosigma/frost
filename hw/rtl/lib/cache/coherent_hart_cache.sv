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
    // L1D request endpoints, 1 to 8: endpoint 0 serves stores, LR, AMO and
    // SC. Nonzero endpoints carry loads and optional GetS hints; with three or
    // more, at most one at a time carries a lookahead store.
    parameter int unsigned L1D_MISSES = 8,
    parameter bit L1D_STREAM_PREFETCH = 1'b0,
    parameter int unsigned HOME_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned HOME_WAYS = 4,
    parameter int unsigned HOME_LINE_BYTES = 64,
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
    output logic [3:0] o_block_valid,
    output logic [3:0][ADDR_WIDTH-1:0] o_block_addr,
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
    // With i_cut_admit_ready: the CPU holds nothing for the line.
    input logic i_cut_admit_clean = 1'b0,
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
    // Earlier writes to instruction memory outside the home have completed.
    input logic i_imem_sync_done = 1'b1,
    output logic o_fence_done,
`ifdef COH_MAINT_OWNED
    input logic [63:0] i_maint_first,
    i_maint_final,
    output logic [8+8+7+3*64-1:0] o_maint_view,
    output logic [3:0][ADDR_WIDTH+2:0] o_maint_read_requests,
    output logic o_maint_swept,
`endif
    output cache_perf_pkg::cache_instance_perf_events_t o_l1i_perf_events,
    output cache_perf_pkg::cache_instance_perf_events_t o_l1d_perf_events,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
`ifndef SYNTHESIS
  // Registers power up arbitrary and the reset can reach this module a few
  // cycles after the first edge, so the simulation checks begin at the first
  // reset.
`ifdef FORMAL
  // Formal tasks start from a reset or from an induction state; the checks
  // apply in both.
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
`ifdef COH_MAINT_OWNED
  logic [3:0][2:0] f_if_phase;
  logic [3:0][ADDR_WIDTH-1:0] f_if_address;
  logic [3:0][2:0] f_if_id;
  logic [1:0] f_if_cache_waiting;
  logic [1:0][ADDR_WIDTH-1:0] f_if_cache_address;
`endif
  // D and C ports: the L1D's endpoints first, then two IF slots and two PTW
  // slots. G and U route by port class.
  localparam int unsigned Ports   = L1D_MISSES + 4;
  localparam int unsigned IfPort  = L1D_MISSES;
  localparam int unsigned PtwPort = L1D_MISSES + 2;
  logic [Ports-1:0] d_valid, d_ready, c_valid, c_ready;
  logic [2:0] g_ready, u_ready;
  // Per-requester packets are plain vectors, read whole by the arbiters.
  logic [Ports-1:0][ADDR_WIDTH+311:0] demand;
  coh_g_t grant;
  logic [Ports-1:0][ADDR_WIDTH+17:0] completion;
  coh_u_t release_message;
  logic l1d_fatal, l1i_fatal;
  logic [ADDR_WIDTH-1:0] l1d_fatal_addr, l1i_fatal_addr;
  typedef enum logic [2:0] {
    MaintIdle,
    FenceInvalidate,
    FenceWait,
    FenceDone,
    MaintGap
  } maint_state_t;
  maint_state_t maint_state_q;
  logic fence_dropped_q;
  logic l1i_invalidate, l1i_busy;
  logic if_req_valid, if_req_ready, if_req_write;
  logic [ADDR_WIDTH-1:0] if_req_addr;
  logic [2:0] if_req_id, if_resp_id;
  logic if_resp_valid, if_resp_error;
  logic [255:0] if_resp_data;
  logic [1:0] if_slot_ready, if_slot_valid, if_slot_resp, if_slot_error;
  logic [1:0] if_g_ready, if_u_ready;
  logic [1:0][  2:0] if_slot_id;
  logic [1:0][255:0] if_slot_data;
  // The walker's two bridge slots. Slot 0 takes a request when it is idle,
  // slot 1 otherwise, so a page-table read can leave while the previous
  // read's slot finishes its completion and release.
  logic [1:0] walk_slot_ready, walk_slot_valid, walk_slot_resp, walk_slot_error;
  logic [1:0] walk_g_ready, walk_u_ready;
  logic [1:0][  2:0] walk_slot_id;
  logic [1:0][255:0] walk_slot_data;
  assign if_req_ready = |if_slot_ready;
  assign if_slot_valid = {
    if_req_valid && !if_slot_ready[0] && if_slot_ready[1], if_req_valid && if_slot_ready[0]
  };
  assign g_ready[1] = |if_g_ready;
  assign u_ready[1] = |if_u_ready;
  assign if_resp_valid = |if_slot_resp;
  assign if_resp_id = ({3{if_slot_resp[0]}} & if_slot_id[0]) |
      ({3{if_slot_resp[1]}} & if_slot_id[1]);
  assign if_resp_data = ({256{if_slot_resp[0]}} & if_slot_data[0]) |
      ({256{if_slot_resp[1]}} & if_slot_data[1]);
  assign if_resp_error = |(if_slot_resp & if_slot_error);
  assign o_walk_req_ready = |walk_slot_ready;
  assign walk_slot_valid = {
    i_walk_req_valid && !walk_slot_ready[0] && walk_slot_ready[1],
    i_walk_req_valid && walk_slot_ready[0]
  };
  assign g_ready[2] = |walk_g_ready;
  assign u_ready[2] = |walk_u_ready;
  // One G per cycle, and each slot registers its response at its G.
  assign o_walk_resp_valid = |walk_slot_resp;
  assign o_walk_resp_id = ({3{walk_slot_resp[0]}} & walk_slot_id[0]) |
      ({3{walk_slot_resp[1]}} & walk_slot_id[1]);
  assign o_walk_resp_data = ({256{walk_slot_resp[0]}} & walk_slot_data[0]) |
      ({256{walk_slot_resp[1]}} & walk_slot_data[1]);
  assign o_walk_resp_error = |(walk_slot_resp & walk_slot_error);
  assign grant = i_g;
  assign release_message = i_u;
  assign o_fatal = l1d_fatal || l1i_fatal;
  assign o_fatal_addr = l1d_fatal ? l1d_fatal_addr : l1i_fatal_addr;
  assign o_g_ready = g_ready[grant.q[6:5]];
  assign o_u_ready = u_ready[release_message.q[6:5]];
  // Each C source holds its offer from SendC or Complete until acceptance.
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(Ports),
      .HOLD_VALID(1)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid(c_valid),
      .o_ready(c_ready),
      .i_payload(completion),
      .o_valid(o_c_valid),
      .o_selected(),
      .i_ready(i_c_ready),
      .o_payload(o_c)
  );
  coherence_d_arbiter #(
      .WIDTH((ADDR_WIDTH + 312)),
      .PORTS(Ports)
  ) demands (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(d_valid),
      .o_ready(d_ready),
      .i_payload(demand),
      .o_valid(o_d_valid),
      .o_selected(),
      .i_ready(i_d_ready),
      .o_payload(o_d)
  );
  coherence_l1d #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .TAG_BITS(TAG_BITS),
      .MISSES(L1D_MISSES),
      .HOME_CACHE_BYTES(HOME_CACHE_BYTES),
      .HOME_WAYS(HOME_WAYS),
      .HOME_LINE_BYTES(HOME_LINE_BYTES),
      .STREAM_PREFETCH(L1D_STREAM_PREFETCH),
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
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
      .i_maint_valid(1'b0),
      .i_maint_line(1'b0),
      .i_maint_address('0),
      .o_maint_done(),
      .o_cut_hold(o_cut_hold),
      .o_cut_admit_valid(o_cut_admit_valid),
      .i_cut_admit_ready(i_cut_admit_ready),
      .i_cut_admit_clean(i_cut_admit_clean),
      .o_cut_address(o_cut_address),
      .o_cut_inval_valid(o_cut_inval_valid),
      .i_cut_inval_done(i_cut_inval_done),
      .o_cut_release(o_cut_release),
      .o_d_valid(d_valid[L1D_MISSES-1:0]),
      .i_d_ready(d_ready[L1D_MISSES-1:0]),
      .o_d(demand[L1D_MISSES-1:0]),
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
      .o_c_valid(c_valid[L1D_MISSES-1:0]),
      .i_c_ready(c_ready[L1D_MISSES-1:0]),
      .o_c(completion[L1D_MISSES-1:0]),
      .i_u_valid(i_u_valid && release_message.q[6:5] == 0),
      .o_u_ready(u_ready[0]),
      .i_u(i_u),
`ifdef COH_MAINT_OWNED
      .i_maint_first(i_maint_first),
      .i_maint_final(i_maint_final),
      .o_maint_view(o_maint_view),
`endif
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
`ifdef COH_MAINT_OWNED
      .i_maint_final(i_maint_final),
      .i_maint_final_seen(o_maint_view[8+8+7+3*64-2]),
      .o_maint_swept(o_maint_swept),
      .o_maint_if_waiting(f_if_cache_waiting),
      .o_maint_if_address(f_if_cache_address),
`endif
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
  for (genvar slot = 0; slot < 2; slot++) begin : gen_if
    coherence_line_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .PORT_CLASS(1),
        .SLOT(slot),
        .EARLY_RESPONSE(1'b1),
        .CLEAN(1'b0)
    ) if_bridge (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_stop),
`ifdef COH_MAINT_OWNED
        .i_maint_final(i_maint_final),
        .i_maint_final_seen(o_maint_view[8+8+7+3*64-2]),
        .o_maint_phase(f_if_phase[slot]),
        .o_maint_address(f_if_address[slot]),
        .o_maint_id(f_if_id[slot]),
`endif
        .i_req_valid(if_slot_valid[slot]),
        .o_req_ready(if_slot_ready[slot]),
        .i_req_write(if_req_write),
        .i_req_addr(if_req_addr),
        .i_req_data('0),
        .i_req_mask('0),
        .i_req_id(if_req_id),
        .o_resp_valid(if_slot_resp[slot]),
        .o_resp_id(if_slot_id[slot]),
        .o_resp_data(if_slot_data[slot]),
        .o_resp_error(if_slot_error[slot]),
        .o_clean_valid(),
        .o_clean_addr(),
        .i_clean_done(1'b0),
        .o_d_valid(d_valid[IfPort+slot]),
        .i_d_ready(d_ready[IfPort+slot]),
        .o_d(demand[IfPort+slot]),
        .i_g_valid(i_g_valid && grant.q[6:5] == 1),
        .o_g_ready(if_g_ready[slot]),
        .i_g(i_g),
        .o_c_valid(c_valid[IfPort+slot]),
        .i_c_ready(c_ready[IfPort+slot]),
        .o_c(completion[IfPort+slot]),
        .i_u_valid(i_u_valid && release_message.q[6:5] == 1),
        .o_u_ready(if_u_ready[slot]),
        .i_u(i_u)
    );
  end
  for (genvar slot = 0; slot < 2; slot++) begin : gen_walk
    coherence_line_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .PORT_CLASS(2),
        .SLOT(slot),
        .EARLY_RESPONSE(1'b1),
        .CLEAN(1'b0)
    ) walk_bridge (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_stop),
`ifdef COH_MAINT_OWNED
        .i_maint_final(i_maint_final),
        .i_maint_final_seen(o_maint_view[8+8+7+3*64-2]),
        .o_maint_phase(f_if_phase[slot+2]),
        .o_maint_address(f_if_address[slot+2]),
        .o_maint_id(f_if_id[slot+2]),
`endif
        .i_req_valid(walk_slot_valid[slot]),
        .o_req_ready(walk_slot_ready[slot]),
        .i_req_write(1'b0),
        .i_req_addr(i_walk_req_addr),
        .i_req_data('0),
        .i_req_mask('0),
        .i_req_id(i_walk_req_id),
        .o_resp_valid(walk_slot_resp[slot]),
        .o_resp_id(walk_slot_id[slot]),
        .o_resp_data(walk_slot_data[slot]),
        .o_resp_error(walk_slot_error[slot]),
        .o_clean_valid(),
        .o_clean_addr(),
        .i_clean_done(1'b0),
        .o_d_valid(d_valid[PtwPort+slot]),
        .i_d_ready(d_ready[PtwPort+slot]),
        .o_d(demand[PtwPort+slot]),
        .i_g_valid(i_g_valid && grant.q[6:5] == 2),
        .o_g_ready(walk_g_ready[slot]),
        .i_g(i_g),
        .o_c_valid(c_valid[PtwPort+slot]),
        .i_c_ready(c_ready[PtwPort+slot]),
        .o_c(completion[PtwPort+slot]),
        .i_u_valid(i_u_valid && release_message.q[6:5] == 2),
        .o_u_ready(walk_u_ready[slot]),
        .i_u(i_u)
    );
  end
  // The serializer drains committed stores before requesting synchronization.
  // IF and PTW reads obtain dirty L1D bytes through the home's probes.
  assign l1i_invalidate = maint_state_q == FenceInvalidate;
  assign o_fence_done   = maint_state_q == FenceDone;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      maint_state_q   <= MaintIdle;
      fence_dropped_q <= 1'b0;
    end else begin
      if (maint_state_q == MaintIdle) fence_dropped_q <= 1'b0;
      else if (!i_fence_sync) fence_dropped_q <= 1'b1;
      case (maint_state_q)
        MaintIdle: begin
          if (i_fence_sync) maint_state_q <= FenceInvalidate;
        end
        FenceInvalidate: if (l1i_busy) maint_state_q <= FenceWait;
        FenceWait:
        if (!l1i_busy && i_imem_sync_done)
          maint_state_q <= i_fence_sync && !fence_dropped_q ? FenceDone : MaintGap;
        FenceDone: if (!i_fence_sync) maint_state_q <= MaintGap;
        MaintGap: maint_state_q <= MaintIdle;
        default: maint_state_q <= MaintIdle;
      endcase
    end
  end
`ifndef SYNTHESIS
  logic [Ports-1:0] c_stalled_q;
  always_ff @(posedge i_clk) begin
    c_stalled_q <= i_rst ? '0 : c_valid & ~c_ready;
    if (sim_reset_seen_q && !i_rst) begin
      assert ((c_stalled_q & ~c_valid) == 0);
      assert ($onehot0(c_ready));
      assert ($onehot0(if_slot_valid));
      assert ((if_req_valid && if_req_ready) == (|if_slot_valid));
      assert ($onehot0(if_g_ready));
      assert ($onehot0(if_u_ready));
      assert ($onehot0(if_slot_resp));
      assert ($onehot0(walk_slot_valid));
      assert ((i_walk_req_valid && o_walk_req_ready) == (|walk_slot_valid));
      assert ($onehot0(walk_g_ready));
      assert ($onehot0(walk_u_ready));
      assert ($onehot0(walk_slot_resp));
      for (int port_idx = 0; port_idx < Ports; port_idx++) begin
        if (c_valid[port_idx] && c_ready[port_idx])
          assert (o_c_valid && i_c_ready && o_c == completion[port_idx]);
      end
    end
  end
`endif
`ifdef FORMAL
  logic f_invalidated_q, f_busy_q, f_mirror_wait_q;
  logic [1:0] f_if_live_q, f_if_responded_q;
  logic [1:0][2:0] f_if_id_q;
  logic [1:0] f_if_waiting_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_if_live_q <= 0;
      f_if_responded_q <= 0;
      f_if_id_q <= 0;
      f_if_waiting_q <= 0;
    end else begin
      if (if_req_valid && if_req_ready) begin
        assert (if_req_id < 2 && !f_if_waiting_q[if_req_id[0]]);
        f_if_waiting_q[if_req_id[0]] <= 1;
      end
      if (if_resp_valid) begin
        assert (if_resp_id < 2 && f_if_waiting_q[if_resp_id[0]]);
        f_if_waiting_q[if_resp_id[0]] <= 0;
      end
      for (int mshr = 0; mshr < 2; mshr++)
      assert (f_if_waiting_q[mshr] ==
            ((f_if_live_q[0] && !f_if_responded_q[0] && f_if_id_q[0] == 3'(mshr)) ||
             (f_if_live_q[1] && !f_if_responded_q[1] && f_if_id_q[1] == 3'(mshr))));
      for (int slot = 0; slot < 2; slot++) begin
        if (if_slot_valid[slot]) begin
          assert (!f_if_live_q[slot]);
          f_if_live_q[slot] <= 1;
          f_if_responded_q[slot] <= 0;
          f_if_id_q[slot] <= if_req_id;
        end
        if (if_slot_resp[slot]) begin
          assert (f_if_live_q[slot] && !f_if_responded_q[slot]);
          assert (if_slot_id[slot] == f_if_id_q[slot]);
          f_if_responded_q[slot] <= 1;
        end
        if (i_u_valid && if_u_ready[slot]) begin
          assert (f_if_live_q[slot] && f_if_responded_q[slot]);
          f_if_live_q[slot] <= 0;
        end
      end
      cover ((if_slot_valid[0] && f_if_live_q[1] && f_if_responded_q[1] &&
          f_if_id_q[1] == if_req_id) || (if_slot_valid[1] && f_if_live_q[0] &&
          f_if_responded_q[0] && f_if_id_q[0] == if_req_id));
      cover (&f_if_live_q && !(|f_if_responded_q));
      cover (o_fence_done && |(f_if_live_q & f_if_responded_q));
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst || maint_state_q == MaintIdle) begin
      f_invalidated_q <= 0;
      f_busy_q <= 0;
      f_mirror_wait_q <= 0;
    end else begin
      if (l1i_invalidate) f_invalidated_q <= 1;
      if (l1i_busy) f_busy_q <= 1;
      if (maint_state_q == FenceWait && !i_imem_sync_done) f_mirror_wait_q <= 1;
    end
    if (!i_rst && o_fence_done) begin
`ifdef COH_MAINT_OWNED
      p_maint_fact_fence_done : assert (f_invalidated_q && f_busy_q && !l1i_busy);
`else
      assert (f_invalidated_q && f_busy_q && !l1i_busy);
`endif
      assert (!fence_dropped_q);
      if (!$past(o_fence_done)) assert ($past(i_imem_sync_done));
      cover (f_mirror_wait_q);
    end
  end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!i_rst && maint_state_q != MaintIdle)
      p_maint_seq_fence_owner : assert (o_maint_view[8+8+7+3*64-2]);
`endif
`ifdef COH_MAINT_OWNED
  for (genvar n = 0; n < 4; n++) begin : gen_maint_read_observation
    assign o_maint_read_requests[n] = {f_if_phase[n], f_if_address[n]};
  end
  logic f_if_context;
  always_comb begin
    f_if_context = f_if_cache_waiting == f_if_waiting_q;
    for (int m = 0; m < 2; m++)
    if (f_if_waiting_q[m] != ((f_if_live_q[0] && !f_if_responded_q[0] && f_if_id_q[0] == 3'(m)) ||
        (f_if_live_q[1] && !f_if_responded_q[1] && f_if_id_q[1] == 3'(m))))
      f_if_context = 0;
    if (&(f_if_live_q & ~f_if_responded_q) && f_if_id_q[0] == f_if_id_q[1]) f_if_context = 0;
    for (int n = 0; n < 2; n++) begin
      if (f_if_live_q[n] != (f_if_phase[n] != 0)) f_if_context = 0;
      if (f_if_phase[n] != 0 && (!f_if_live_q[n] || f_if_id[n] != f_if_id_q[n])) f_if_context = 0;
      if (f_if_phase[n] != 0 && f_if_phase[n] <= 3 && f_if_responded_q[n]) f_if_context = 0;
      if (f_if_phase[n] == 5 && !f_if_responded_q[n]) f_if_context = 0;
      if (f_if_phase[n] == 4 && !f_if_responded_q[n] && !if_slot_resp[n]) f_if_context = 0;
      if (f_if_live_q[n] && !f_if_responded_q[n]) begin
        if (f_if_id_q[n] >= 2) f_if_context = 0;
        else if (!f_if_cache_waiting[f_if_id_q[n][0]] ||
            f_if_cache_address[f_if_id_q[n][0]] != f_if_address[n])
          f_if_context = 0;
      end
      if (if_slot_resp[n] && (!f_if_live_q[n] ||
          f_if_responded_q[n] ||
          if_slot_id[n] != f_if_id_q[n]))
        f_if_context = 0;
    end
  end
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      p_maint_if_context : assert (f_if_context);
      p_maint_if_one_response : assert ($onehot0(if_slot_resp));
    end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      if (l1i_busy) p_maint_if_busy_final : assert (o_maint_view[8+8+7+3*64-2]);
      if ((maint_state_q == FenceWait && !l1i_busy) ||
          maint_state_q == FenceDone ||
          maint_state_q == MaintGap)
        p_maint_if_sweep_complete : assert (o_maint_swept);
    end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      if (maint_state_q == FenceWait || maint_state_q == FenceDone || maint_state_q == MaintGap)
        p_maint_if_fence_history : assert (f_invalidated_q && f_busy_q);
      if (maint_state_q == FenceDone || maint_state_q == MaintGap)
        p_maint_if_fence_finished : assert (!l1i_busy);
    end
`endif
endmodule
