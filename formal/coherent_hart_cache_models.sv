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

// Small cache contracts for the maintenance composition proof.
// Data arrays and replacement are covered by their component targets.
`include "coherence_types.svh"

module coherence_l1d #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TAG_BITS = 7,
    parameter int unsigned MISSES = 1,
    parameter int unsigned SIM_FAST_MAINT = 0,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned Sets = CACHE_BYTES / (32 * WAYS),
    localparam int unsigned SetBits = $clog2(Sets)
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
    input logic i_cut_admit_clean = 1'b0,
    output logic [ADDR_WIDTH-1:0] o_cut_address,
    output logic o_cut_inval_valid,
    input logic i_cut_inval_done,
    output logic o_cut_release,
    output logic [MISSES-1:0] o_d_valid,
    input logic [MISSES-1:0] i_d_ready,
    output logic [MISSES-1:0][ADDR_WIDTH+311:0] o_d,
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
    output logic [MISSES-1:0] o_c_valid,
    output logic [MISSES-1:0] o_c_selected,
    input logic [MISSES-1:0] i_c_ready,
    output logic [MISSES-1:0][ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  (* anyseq *) logic install, evict;
  logic pending_q, sent_q, granted_q, written_q, live, request_ready;
  logic resident_q, put_q, put_accepted_q, reply_valid_q;
  logic [63:0] value_q, store_q;
  coh_d_t request;
  coh_p_t probe;
  coh_r_t reply_q;
  coh_w_t put;
  logic   grant_valid;
  assign probe = i_p;
  always_comb begin
    request = '0;
    request.opcode = coherence_pkg::GetM;
    request.addr = 32'h80000000;
    put = '0;
    put.addr = request.addr;
    put.data = {4{value_q}};
  end
  assign o_store_ready = !i_rst && !pending_q && !live;
  assign o_pending_store = pending_q;
  assign o_write_inflight = pending_q;
  assign o_write_done = grant_valid;
  assign o_p_ready = !i_rst && !reply_valid_q;
  assign o_r_valid = !i_rst && reply_valid_q;
  assign o_r = reply_q;
  assign o_w_valid = !i_rst && put_q && !put_accepted_q;
  assign o_w = put;
  assign o_wa_ready = !i_rst && put_q;
  assign o_sc_write_pending = 0;
  assign o_atomic_live = 0;
  assign o_block_valid = 0;
  assign o_block_addr = 0;
  assign o_read_valid = 0;
  assign o_read_id = 0;
  assign o_read_data = 0;
  assign o_read_error = 0;
  assign o_sc_ready = 0;
  assign o_sc_result_valid = 0;
  assign o_sc_success = 0;
  assign o_sc_error = 0;
  assign o_sc_write_done = 0;
  assign o_sc_write_tag = 0;
  assign o_maint_done = 0;
  assign o_cut_hold = 0;
  assign o_cut_admit_valid = 0;
  assign o_cut_address = 0;
  assign o_cut_inval_valid = 0;
  assign o_cut_release = 0;
  assign o_perf_events = '0;
  assign o_fatal = 0;
  assign o_fatal_addr = 0;
  coherence_request_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) endpoint (
      .i_clk,
      .i_rst,
      .i_epoch(1'b0),
      .i_request_valid(pending_q && !sent_q),
      .o_request_ready(request_ready),
      .i_request(request),
      .o_d_valid(o_d_valid[0]),
      .i_d_ready(i_d_ready[0]),
      .o_d(o_d[0]),
      .i_g_valid,
      .o_g_ready,
      .i_g,
      .o_grant_valid(grant_valid),
      .i_grant_ready(1'b1),
      .o_grant(),
      .i_done_valid(written_q),
      .o_done_ready(),
      .i_done_status(coherence_pkg::Consumed),
      .i_write_done(written_q),
      .i_error_disposed(1'b0),
      .o_c_valid(o_c_valid[0]),
      .o_c_selected(o_c_selected[0]),
      .i_c_ready(i_c_ready[0]),
      .o_c(o_c[0]),
      .i_u_valid,
      .o_u_ready,
      .i_u,
      .o_live(live)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pending_q <= 0;
      sent_q <= 0;
      granted_q <= 0;
      written_q <= 0;
      resident_q <= 0;
      put_q <= 0;
      put_accepted_q <= 0;
      reply_valid_q <= 0;
      reply_q <= '0;
      value_q <= 64'h200000cf;
      store_q <= 0;
    end else begin
      assert (!i_maint_valid);
      if (|i_write_mask) begin
        assert (o_store_ready);
        pending_q <= 1;
        sent_q <= 0;
        granted_q <= 0;
        written_q <= 0;
        store_q <= i_write_data;
      end
      if (pending_q && !sent_q && request_ready) sent_q <= 1;
      if (grant_valid) granted_q <= 1;
      if (pending_q && granted_q && install) begin
        value_q <= store_q;
        resident_q <= 1;
        pending_q <= 0;
        written_q <= 1;
      end
      if (resident_q && !pending_q && !reply_valid_q && !i_p_valid && evict) begin
        resident_q <= 0;
        put_q <= 1;
      end
      if (i_p_valid && o_p_ready) begin
        reply_valid_q <= 1;
        reply_q <= '0;
        reply_q.tid <= probe.tid;
        reply_q.addr <= probe.addr;
        reply_q.data <= {4{value_q}};
        reply_q.data_valid <= (resident_q || (put_q && !put_accepted_q)) &&
            probe.addr == request.addr;
        reply_q.absorbed <= put_q && !put_accepted_q && probe.addr == request.addr;
      end
      if (o_r_valid && i_r_ready) begin
        reply_valid_q <= 0;
        if (reply_q.data_valid) resident_q <= 0;
      end
      if (o_w_valid && i_w_ready) put_accepted_q <= 1;
      if (i_wa_valid && o_wa_ready) begin
        put_q <= 0;
        put_accepted_q <= 0;
      end
      if (o_c_valid[0]) assert (written_q && !pending_q);
      if (i_u_valid && o_u_ready) begin
        assert (written_q && value_q == store_q);
        cover (written_q && !pending_q);
      end
      cover (o_r_valid && i_r_ready && reply_q.absorbed);
    end
  end

endmodule

// verilog_lint: waive module-filename
module frost_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
    parameter int unsigned CACHE_SIZE_BYTES = 128 * 1024,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WAYS = 4,
    parameter bit BIMODAL_INSERT = 1'b0,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned DOWN_ID_BITS = 4,
    parameter int unsigned NUM_MSHR = 4,
    parameter int unsigned NUM_WB = 2,
    parameter int unsigned NUM_WAITERS = 1,
    parameter int unsigned NUM_PROBE = 0,
    // verilog_lint: waive explicit-parameter-storage-type
    parameter DATA_MEMORY_PRIMITIVE = "block",
    parameter int unsigned DATA_READ_LATENCY = 2,
    parameter int unsigned DATA_WRITE_LATENCY = 1,
    // verilog_lint: waive explicit-parameter-storage-type
    parameter TAG_MEMORY_PRIMITIVE = "block",
    parameter int unsigned TAG_READ_LATENCY = 1,
    parameter int unsigned SIM_FAST_MAINT = 0
) (
    input logic i_clk,
    input logic i_rst,

    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [  UP_ID_BITS-1:0] i_up_req_id,
    input  logic                    i_up_req_maintenance,
    input  logic                    i_up_req_probe,
    input  logic                    i_up_req_probe_inval,
    input  logic                    i_probe_release_valid,
    input  logic [  UP_ID_BITS-1:0] i_probe_release_id,
    output logic                    o_up_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_up_resp_id,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,
    output logic                    o_up_resp_error,
    output logic                    o_fatal_error,
    output logic [  ADDR_WIDTH-1:0] o_fatal_addr,

    input  logic i_writeback_all,
    input  logic i_invalidate_all,
    output logic o_maint_busy,

    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [DOWN_ID_BITS-1:0] o_down_req_id,
    output logic                    o_down_req_maintenance,
    input  logic                    i_down_resp_valid,
    input  logic                    i_down_resp_error = 1'b0,
    input  logic [DOWN_ID_BITS-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata,

    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
    output cache_perf_pkg::cache_write_perf_events_t o_write_perf_events
);
  (* anyseq *) logic fill_step, invalidate_step;
  logic valid_q, demand_q, waiting_q, fill_q, busy_q;
  logic [UP_ID_BITS-1:0] id_q;
  logic [LINE_BYTES*8-1:0] data_q, fill_data_q;
  logic fill_error_q;
  assign o_up_req_ready = !i_rst && !i_invalidate_all && !busy_q &&
      !demand_q && !waiting_q && !fill_q && !o_up_resp_valid;
  assign o_down_req_valid = !i_rst && demand_q;
  assign o_down_req_write = 0;
  assign o_down_req_addr = 32'h80000000;
  assign o_down_req_wdata = 0;
  assign o_down_req_wstrb = 0;
  assign o_down_req_id = 0;
  assign o_down_req_maintenance = 0;
  assign o_maint_busy = busy_q;
  assign o_fatal_error = 0;
  assign o_fatal_addr = 0;
  assign o_perf_events = '0;
  assign o_write_perf_events = '0;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_q <= 0;
      demand_q <= 0;
      waiting_q <= 0;
      fill_q <= 0;
      busy_q <= 0;
      id_q <= 0;
      data_q <= 0;
      fill_data_q <= 0;
      fill_error_q <= 0;
      o_up_resp_valid <= 0;
      o_up_resp_id <= 0;
      o_up_resp_rdata <= 0;
      o_up_resp_error <= 0;
    end else begin
      assert (!i_writeback_all);
      o_up_resp_valid <= 0;
      if (i_up_req_valid && o_up_req_ready) begin
        id_q <= i_up_req_id;
        if (valid_q) begin
          o_up_resp_valid <= 1;
          o_up_resp_id <= i_up_req_id;
          o_up_resp_rdata <= data_q;
          o_up_resp_error <= 0;
        end else demand_q <= 1;
      end
      if (o_down_req_valid && i_down_req_ready) begin
        demand_q  <= 0;
        waiting_q <= 1;
      end
      if (i_down_resp_valid) begin
        assert (waiting_q);
        waiting_q <= 0;
        fill_q <= 1;
        fill_data_q <= i_down_resp_rdata;
        fill_error_q <= i_down_resp_error;
      end
      if (fill_q && fill_step) begin
        fill_q <= 0;
        data_q <= fill_data_q;
        valid_q <= !fill_error_q;
        o_up_resp_valid <= 1;
        o_up_resp_id <= id_q;
        o_up_resp_rdata <= fill_data_q;
        o_up_resp_error <= fill_error_q;
      end
      if (i_invalidate_all) busy_q <= 1;
      if (busy_q && !i_invalidate_all && !demand_q && !waiting_q &&
          !fill_q && !o_up_resp_valid && invalidate_step) begin
        valid_q <= 0;
        busy_q  <= 0;
      end
      cover (i_invalidate_all && (waiting_q || fill_q));
    end
  end

endmodule
