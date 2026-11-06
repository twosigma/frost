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
    parameter int unsigned HOME_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned HOME_WAYS = 4,
    parameter int unsigned HOME_LINE_BYTES = 64,
    parameter bit STREAM_PREFETCH = 1'b0,
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
`ifdef COH_MAINT_FOUR
  logic four_records_q = 0;
  wire  install = four_records_q;
  wire  evict = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) four_records_q <= 0;
    else if (record_count == 4) four_records_q <= 1;
  end
`else
  (* anyseq *) logic install, evict;
`endif
  logic pending_q, tail_q, sent_q, granted_q, written_q, live, request_ready;
  logic pop, credit, accepted_q, acquire;
  logic [2:0] record_count;
  logic [1:0] head_index;
  logic [3:0] record_valid, record_sealed;
  logic [3:0][ADDR_WIDTH-1:0] record_addr;
  logic [3:0][255:0] record_data;
  logic [3:0][31:0] record_mask;
  logic [7:0] mask_q;
  logic resident_q, put_q, put_accepted_q, reply_valid_q;
  logic [63:0] value_q, store_q, installed_value_q, grant_image_q;
  coh_d_t request;
  coh_g_t grant_payload;
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
  assign o_store_ready = !i_rst && credit;
  assign pending_q = record_count != 0;
  assign tail_q = record_count > 1;
  assign store_q = record_data[head_index][63:0];
  assign mask_q = record_mask[head_index][7:0];
  assign acquire = pending_q && !sent_q && !live && !resident_q && !put_q;
  assign pop = pending_q && record_sealed[head_index] && install &&
      !reply_valid_q && !i_p_valid && !put_q &&
      (granted_q || (resident_q && !sent_q && !live));
  coherence_store_buffer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .TAG_BITS(TAG_BITS),
      .EP_BITS(1)
  ) stores (
      .o_combined(),
      .i_clk,
      .i_rst,
      .i_push(|i_write_mask),
      .i_addr(ADDR_WIDTH'(32'h80000000)),
      .i_data(i_write_data),
      .i_mask(i_write_mask),
      .i_tag(i_write_tag),
      .i_pop(pop),
      .i_seal(pending_q && !record_sealed[head_index]),
      .i_seal_index(head_index),
      .i_acquire(1'b0),
      .i_acquire_index('0),
      .i_acquire_ep('0),
      .o_ready(credit),
      .o_done(accepted_q),
      .o_count(record_count),
      .o_head(head_index),
      .o_valid(record_valid),
      .o_sealed(record_sealed),
      .o_acquired(),
      .o_addr(record_addr),
      .o_data(record_data),
      .o_mask(record_mask),
      .o_tag(),
      .o_contributors(),
      .o_ep()
  );
  assign o_pending_store = pending_q;
  assign o_write_inflight = accepted_q;
  assign o_write_done = accepted_q;
  assign o_p_ready = !i_rst && !reply_valid_q;
  assign o_r_valid = !i_rst && reply_valid_q;
  assign o_r = reply_q;
  assign o_w_valid = !i_rst && put_q && !put_accepted_q;
  assign o_w = put;
  assign o_wa_ready = !i_rst && put_q;
  assign o_sc_write_pending = 0;
  assign o_atomic_live = 0;
  assign o_block_valid = record_valid;
  assign o_block_addr = record_addr;
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
      .i_request_valid(acquire),
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
      .o_grant(grant_payload),
      .i_done_valid(written_q),
      .o_done_ready(),
      .i_done_status(coherence_pkg::Consumed),
      .i_write_done(written_q),
      .i_error_disposed(1'b0),
      .o_c_valid(o_c_valid[0]),
      .i_c_ready(i_c_ready[0]),
      .o_c(o_c[0]),
      .i_u_valid,
      .o_u_ready,
      .i_u,
      .o_live(live)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sent_q <= 0;
      granted_q <= 0;
      written_q <= 0;
      resident_q <= 0;
      put_q <= 0;
      put_accepted_q <= 0;
      reply_valid_q <= 0;
      reply_q <= '0;
      value_q <= 64'h200000cf;
      installed_value_q <= 64'h200000cf;
      grant_image_q <= 0;
    end else begin
      assert (!i_maint_valid);
      if (written_q) assert (value_q == installed_value_q);
      if (o_r_valid && reply_q.data_valid) assert (reply_q.data == {4{installed_value_q}});
      if (o_w_valid) assert (put.data == {4{installed_value_q}});
      if (|i_write_mask) assert (record_count < 4);
      if (acquire && request_ready) begin
        sent_q <= 1;
        written_q <= 0;
      end
      if (grant_valid) begin
        granted_q <= 1;
        grant_image_q <= grant_payload.data[63:0];
      end
      if (pop) begin
        for (int byte_index = 0; byte_index < 8; byte_index++)
        if (mask_q[byte_index]) begin
          value_q[8*byte_index+:8] <= store_q[8*byte_index+:8];
          installed_value_q[8*byte_index+:8] <= store_q[8*byte_index+:8];
        end else if (granted_q) begin
          value_q[8*byte_index+:8] <= grant_image_q[8*byte_index+:8];
        end
        resident_q <= 1;
        granted_q  <= 0;
        written_q  <= 1;
      end
      if (resident_q && !pop && !put_q && !reply_valid_q && !i_p_valid && evict) begin
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
      if (o_c_valid[0]) assert (written_q && !granted_q);
      if (i_u_valid && o_u_ready) begin
        assert (written_q && value_q == installed_value_q);
        sent_q <= 0;
        cover (written_q && !pending_q);
      end
      cover (tail_q && pop);
      cover (pop && !granted_q);
      cover (pop && granted_q && mask_q == 8'h02);
      cover (pending_q && put_q && put_accepted_q);
      cover (pending_q && o_r_valid && i_r_ready && reply_q.absorbed);
      cover (written_q && pending_q && !tail_q);
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
`ifdef COH_MAINT_COVER
  wire fill_step = 1, invalidate_step = 1;
`else
  (* anyseq *) logic fill_step, invalidate_step;
`endif
  logic [1:0] valid_q, demand_q, waiting_q, fill_q;
  logic busy_q;
  logic [1:0][UP_ID_BITS-1:0] id_q;
  logic [1:0][ADDR_WIDTH-1:0] address_q;
  logic [1:0][LINE_BYTES*8-1:0] data_q, fill_data_q;
  logic [1:0] fill_error_q;
  wire [1:0] live = demand_q | waiting_q | fill_q;
  wire slot = live[0];
  wire down_slot = !demand_q[0];
  wire fill_slot = !fill_q[0];
  wire sector = i_up_req_addr[5];
  wire pipeline_idle = !(|live) && !o_up_resp_valid;
  wire sweep = busy_q && !i_invalidate_all && pipeline_idle && invalidate_step;
  wire same_sector = (live[0] && address_q[0] == i_up_req_addr) ||
      (live[1] && address_q[1] == i_up_req_addr);
  assign o_up_req_ready = !i_rst && !i_invalidate_all && !busy_q &&
      !(&live) && !(|fill_q) && !o_up_resp_valid && !same_sector;
  assign o_down_req_valid = !i_rst && |demand_q;
  assign o_down_req_write = 0;
  assign o_down_req_addr = address_q[down_slot];
  assign o_down_req_wdata = 0;
  assign o_down_req_wstrb = 0;
  assign o_down_req_id = DOWN_ID_BITS'(down_slot);
  assign o_down_req_maintenance = 0;
  assign o_maint_busy = busy_q;
  assign o_fatal_error = 0;
  assign o_fatal_addr = 0;
  assign o_perf_events = '0;
  assign o_write_perf_events = '0;
  logic swept_q;
  logic [1:0] old_fill_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_q <= 0;
      demand_q <= 0;
      waiting_q <= 0;
      fill_q <= 0;
      busy_q <= 0;
      id_q <= 0;
      address_q <= 0;
      data_q <= 0;
      fill_data_q <= 0;
      fill_error_q <= 0;
      o_up_resp_valid <= 0;
      o_up_resp_id <= 0;
      o_up_resp_rdata <= 0;
      o_up_resp_error <= 0;
      old_fill_q <= 0;
      swept_q <= 0;
    end else begin
      assert (!i_writeback_all);
      for (int n = 0; n < 2; n++) assert ($onehot0({demand_q[n], waiting_q[n], fill_q[n]}));
      if (swept_q) assert ((old_fill_q & live) == 0);
      o_up_resp_valid <= 0;
      if (i_up_req_valid && o_up_req_ready) begin
        id_q[slot] <= i_up_req_id;
        address_q[slot] <= i_up_req_addr;
        old_fill_q[slot] <= 0;
        if (valid_q[sector]) begin
          o_up_resp_valid <= 1;
          o_up_resp_id <= i_up_req_id;
          o_up_resp_rdata <= data_q[sector];
          o_up_resp_error <= 0;
        end else demand_q[slot] <= 1;
      end
      if (o_down_req_valid && i_down_req_ready) begin
        demand_q[down_slot]  <= 0;
        waiting_q[down_slot] <= 1;
      end
      if (i_down_resp_valid) begin
        assert (i_down_resp_id < 2);
        assert (waiting_q[i_down_resp_id[0]]);
        waiting_q[i_down_resp_id[0]] <= 0;
        fill_q[i_down_resp_id[0]] <= 1;
        fill_data_q[i_down_resp_id[0]] <= i_down_resp_rdata;
        fill_error_q[i_down_resp_id[0]] <= i_down_resp_error;
      end
      if ((|fill_q) && fill_step) begin
        assert (!(swept_q && old_fill_q[fill_slot]));
        fill_q[fill_slot] <= 0;
        data_q[address_q[fill_slot][5]] <= fill_data_q[fill_slot];
        valid_q[address_q[fill_slot][5]] <= !fill_error_q[fill_slot];
        o_up_resp_valid <= 1;
        o_up_resp_id <= id_q[fill_slot];
        o_up_resp_rdata <= fill_data_q[fill_slot];
        o_up_resp_error <= fill_error_q[fill_slot];
      end
      if (i_invalidate_all) begin
        busy_q <= 1;
        old_fill_q <= live;
        swept_q <= 0;
      end
      if (sweep) begin
        assert (!(|waiting_q) && !(|fill_q) && !(|demand_q) && !o_up_resp_valid);
        valid_q <= 0;
        busy_q  <= 0;
        swept_q <= 1;
      end
      cover (i_invalidate_all && (|waiting_q || |fill_q));
      cover (i_invalidate_all && &live);
      cover (&waiting_q);
    end
  end

endmodule
