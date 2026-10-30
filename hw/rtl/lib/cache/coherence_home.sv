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

// Independent completions pin their L2 ways through Release. A fill overlaps
// victim recalls. Detached dirty blocks own their addresses until B.
module coherence_home #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned NUM_WB = 2,
    parameter int unsigned COMPLETIONS = 19,
    parameter int unsigned RESULTS = 8,
    parameter int unsigned FILLS = 4,
    parameter bit ULTRA = 1'b1,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned WbBits = NUM_WB > 1 ? $clog2(NUM_WB) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
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
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS);
  localparam int unsigned SetBits = $clog2(Sets);
  localparam int unsigned CompletionBits = COMPLETIONS > 1 ? $clog2(COMPLETIONS) : 1;
  localparam int unsigned ResultBits = RESULTS > 1 ? $clog2(RESULTS) : 1;
  localparam int unsigned FillBits = FILLS > 1 ? $clog2(FILLS) : 1;
  localparam int unsigned Puts = 2;
  localparam int unsigned Clients = RESULTS + FILLS + Puts;
  localparam int unsigned TokenBits = $clog2(Clients);
  localparam int unsigned TagPacketBits = TokenBits + ADDR_WIDTH;
  localparam int unsigned ReadPacketBits = TagPacketBits + WayBits;
  localparam int unsigned UpdatePacketBits = ReadPacketBits + 3 + 9 * LINE_BYTES;
  localparam logic [5:0] FillTid = 6'(coherence_pkg::fill_base(1));
  localparam logic [5:0] PutTid = 6'(coherence_pkg::put_base(1, 4));
  typedef struct packed {
    logic [TokenBits-1:0]  token;
    logic [ADDR_WIDTH-1:0] addr;
  } tag_packet_t;
  typedef struct packed {
    logic [TokenBits-1:0] token;
    logic [WayBits-1:0] way;
    logic [ADDR_WIDTH-1:0] addr;
  } read_packet_t;
  typedef struct packed {
    logic [TokenBits-1:0] token;
    logic [WayBits-1:0] way;
    logic [ADDR_WIDTH-1:0] addr;
    logic tag_write;
    logic [1:0] state;
    logic [LINE_BYTES-1:0] mask;
    logic [8*LINE_BYTES-1:0] data;
  } update_packet_t;
  typedef enum logic [3:0] {
    FillFree,
    FillRecall,
    FillDetach,
    FillInvalidate,
    FillInvalidateWait,
    FillMemory,
    FillInstall,
    FillInstallWait,
    FillReady,
    FillFatal
  } fill_phase_t;
  typedef enum logic [2:0] {
    RecallOffer,
    RecallWait,
    RecallAck,
    RecallDone
  } recall_phase_t;
  typedef enum logic [2:0] {
    PutFree,
    PutLookup,
    PutDecision,
    PutUpdate,
    PutUpdateWait,
    PutAck,
    PutFatal
  } put_phase_t;
  fill_phase_t fill_phase_q[FILLS];
  recall_phase_t recall_phase_q[FILLS];
  put_phase_t put_phase_q[Puts];
  (* max_fanout = 64 *) logic run;
  logic active, work_valid, work_offer, work_error;
  coh_d_t work;
  logic [5:0] work_tid;
  logic [ResultBits-1:0] work_buffer, image_index;
  logic [255:0] image_data;
  logic [COMPLETIONS-1:0] waiting, waiting_offer, park, wake, wake_error;
  logic [COMPLETIONS-1:0][ADDR_WIDTH+311:0] waiting_request;
  logic [COMPLETIONS-1:0][ADDR_WIDTH-1:0] waiting_addr;
  logic [COMPLETIONS-1:0][3:0] waiting_opcode;
  logic retry_valid, retry_park, pin_valid;
  logic [5:0] decision_tid;
  logic [WAYS-1:0] completion_exclude, array_exclude;
  logic put_busy;
  coh_w_t incoming_put, selected_put_q;
  logic put_selected_q, put_key_match, put_blocked;
  coh_r_t reply;
  logic [RESULTS-1:0] engine_idle, engine_lookup;
  logic [RESULTS-1:0] engine_read;
  logic [RESULTS-1:0] engine_r_ready;
  logic [RESULTS-1:0] engine_update;
  logic [RESULTS-1:0] engine_result, engine_result_ready, engine_fatal;
  logic [RESULTS-1:0][ADDR_WIDTH-1:0] engine_addr;
  logic [RESULTS-1:0][5:0] engine_tid;
  logic [RESULTS-1:0][3:0] engine_opcode;
  logic [RESULTS-1:0] engine_maintenance, engine_counted_q;
  logic work_counted;
  logic [RESULTS-1:0][WayBits-1:0] engine_way;
  logic [RESULTS-1:0][255:0] engine_image;
  logic [RESULTS-1:0][ADDR_WIDTH+274:0] engine_result_payload;
  logic [RESULTS-1:0][LINE_BYTES-1:0] engine_update_mask;
  logic [RESULTS-1:0][8*LINE_BYTES-1:0] engine_update_data;
  logic [Clients-1:0] tag_valid, tag_ready, read_valid, read_ready;
  logic [Clients-1:0] update_valid, update_ready, probe_valid, probe_ready;
  logic [Clients-1:0] ack_valid, ack_ready;
  logic [Clients-1:0][TagPacketBits-1:0] tag_payload;
  logic [Clients-1:0][ReadPacketBits-1:0] read_payload;
  logic [Clients-1:0][UpdatePacketBits-1:0] update_payload;
  logic [Clients-1:0][ADDR_WIDTH+29:0] probe_payload;
  logic [Clients-1:0][ADDR_WIDTH+10:0] ack_payload;
  tag_packet_t tag_request;
  read_packet_t row_request;
  update_packet_t update_request;
  logic tag_request_valid, tag_request_ready, row_request_valid, row_request_ready;
  logic update_request_valid, update_request_ready;
  logic probe_out_valid, probe_out_offer, ack_out_valid, result_valid, result_ready;
  logic [ADDR_WIDTH+29:0] probe_out;
  logic [ADDR_WIDTH+10:0] ack_out;
  coh_g_t result;
  logic array_response, array_hit, array_available, array_claim;
  logic [TokenBits-1:0] array_token, array_data_token, array_updated_token;
  logic [ADDR_WIDTH-1:0] array_query, array_addr;
  logic [WayBits-1:0] array_way;
  logic [1:0] array_state;
  logic array_data_valid, array_updated;
  logic [8*LINE_BYTES-1:0] array_data;
  logic decision_engine, decision_put, decision_blocked, victim_blocked;
  logic decision_hit, decision_fill, decision_join, decision_retry;
  logic [FillBits-1:0] fill_free_index;
  logic [FILLS-1:0] join_fill;
  logic decision_reader;
  logic fill_free, wb_free;
  logic [WbBits-1:0] wb_free_index;
  logic [ADDR_WIDTH-1:0] decision_addr;
  logic [3:0] decision_opcode;
  logic [FILLS-1:0][ADDR_WIDTH-1:0] fill_addr_q, fill_old_addr_q;
  logic [FILLS-1:0][WayBits-1:0] fill_way_q;
  logic [FILLS-1:0][WbBits-1:0] fill_wb_q;
  logic [FILLS-1:0][8*LINE_BYTES-1:0] fill_image_q;
  logic [FILLS-1:0] fill_victim_q, fill_sent_q, fill_done_q, fill_error_q;
  logic [FILLS-1:0] fill_read_sent_q, fill_read_done_q, fill_sector_q;
  logic [FILLS-1:0] fill_dirty_q, fill_r_ready;
  logic [FILLS-1:0][LINE_BYTES/32-1:0] fill_dirty_sectors_q;
  logic [COMPLETIONS-1:0] fill_seats_q[FILLS], fill_add_seats[FILLS];
  logic [1:0] fill_seat_count_q[FILLS], fill_add_count[FILLS];
  logic [FILLS-1:0] fill_wake;
  logic [FILLS-1:0][ADDR_WIDTH+29:0] fill_probe;
  coh_wa_t fill_ack_q[FILLS];
  logic [NUM_WB-1:0] wb_valid_q, wb_frozen_q, wb_sent_q;
  logic [ADDR_WIDTH-1:0] wb_addr_q[NUM_WB];
  logic [8*LINE_BYTES-1:0] wb_data_q[NUM_WB];
  coh_w_t put_q[Puts];
  logic [Puts-1:0] put_maintenance;
  logic [Puts-1:0][ADDR_WIDTH-1:0] put_addr;
  logic [Puts-1:0][WayBits-1:0] put_way_q;
  logic [FILLS+NUM_WB-1:0] memory_valid, memory_ready;
  localparam int unsigned MemoryBits = 1 + ADDR_WIDTH + 8 * LINE_BYTES + 5;
  logic [FILLS+NUM_WB-1:0][MemoryBits-1:0] memory_payload;
  logic memory_out_valid;
  logic [MemoryBits-1:0] memory_out;
  logic perf_lookup, perf_maintenance;
  logic [FILLS-1:0] fill_write_q, filling, write_filling;
  localparam int unsigned MemorySources = FILLS + NUM_WB;
  localparam int unsigned MemorySelectBits = $clog2(MemorySources);
  logic [MemorySelectBits-1:0] memory_next_q, memory_pick, memory_first;
  logic memory_found, memory_after;
`ifdef COHERENCE_HOME_CONTROL
  logic [(1<<TokenBits)-1:0] f_tag_owner, f_read_owner, f_update_owner;
  logic [(1<<TokenBits)-1:0][ADDR_WIDTH-1:0] f_tag_address;
  logic [RESULTS-1:0] f_engine_unpinned;
  logic [RESULTS-1:0] f_engine_pinned, f_engine_initial_error;
  logic f_local_fatal;
  logic [COMPLETIONS-1:0] f_fill_waiting, f_fill_seated;
  always_comb begin
    f_fill_waiting = '0;
    f_fill_seated  = '0;
    f_local_fatal  = |engine_fatal;
    f_tag_address  = '0;
    for (int engine = 0; engine < RESULTS; engine++) f_tag_address[engine] = engine_addr[engine];
    for (int put = 0; put < Puts; put++) f_tag_address[RESULTS+FILLS+put] = put_addr[put];
    for (int fill = 0; fill < FILLS; fill++) f_local_fatal |= fill_phase_q[fill] == FillFatal;
    for (int put = 0; put < Puts; put++) f_local_fatal |= put_phase_q[put] == PutFatal;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady)
      f_fill_waiting |= fill_seats_q[fill];
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree) f_fill_seated |= fill_seats_q[fill];
  end
  for (genvar client = Clients; client < (1 << TokenBits); client++) begin : gen_unused_owner
    assign f_tag_owner[client] = 1'b0;
    assign f_read_owner[client] = 1'b0;
    assign f_update_owner[client] = 1'b0;
  end
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill_owner
    assign f_tag_owner[RESULTS+fill] = 1'b0;
    assign f_read_owner[RESULTS+fill] =
        (fill_phase_q[fill] == FillRecall || fill_phase_q[fill] == FillFatal) &&
        fill_read_sent_q[fill] && !fill_read_done_q[fill];
    assign f_update_owner[RESULTS+fill] =
        fill_phase_q[fill] == FillInvalidateWait || fill_phase_q[fill] == FillInstallWait;
  end
  for (genvar put = 0; put < Puts; put++) begin : gen_put_owner
    assign f_tag_owner[RESULTS+FILLS+put] = put_phase_q[put] == PutDecision;
    assign f_read_owner[RESULTS+FILLS+put] = 1'b0;
    assign f_update_owner[RESULTS+FILLS+put] = put_phase_q[put] == PutUpdateWait;
  end
`endif

  function automatic logic [ADDR_WIDTH-1:0] request_addr(input coh_d_t packet);
    request_addr = packet.addr;
  endfunction
  function automatic logic [3:0] request_opcode(input coh_d_t packet);
    request_opcode = packet.opcode;
  endfunction
  for (genvar slot = 0; slot < COMPLETIONS; slot++) begin : gen_waiter_fields
    assign waiting_addr[slot]   = request_addr(waiting_request[slot]);
    assign waiting_opcode[slot] = request_opcode(waiting_request[slot]);
  end
  function automatic logic same_block(input logic [ADDR_WIDTH-1:0] a,
                                      input logic [ADDR_WIDTH-1:0] b);
    same_block = a[ADDR_WIDTH-1:OffsetBits] == b[ADDR_WIDTH-1:OffsetBits];
  endfunction
  function automatic logic same_sector(input logic [ADDR_WIDTH-1:0] a,
                                       input logic [ADDR_WIDTH-1:0] b);
    same_sector = a[ADDR_WIDTH-1:5] == b[ADDR_WIDTH-1:5];
  endfunction
  function automatic logic same_set(input logic [ADDR_WIDTH-1:0] a, input logic [ADDR_WIDTH-1:0] b);
    same_set = a[OffsetBits+:SetBits] == b[OffsetBits+:SetBits];
  endfunction
  function automatic logic read_waiter(input logic [3:0] opcode);
    read_waiter = opcode == coherence_pkg::GetS || opcode == coherence_pkg::LoadReserved ||
        opcode == coherence_pkg::ReadOnceIF || opcode == coherence_pkg::ReadOncePTW ||
        opcode == coherence_pkg::DMARead || opcode == coherence_pkg::Prefetch;
  endfunction
  // Reset clears every register that internal work updates, so internal
  // work is qualified by the stop condition alone. Outputs add the reset.
  assign run = !i_fatal_stop && !o_fatal;
  assign active = !i_rst && run;
  assign incoming_put = i_w;
  assign reply = i_r;
  assign image_data = engine_image[image_index];
  coherence_home_completions #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .SLOTS(COMPLETIONS),
      .RESULT_SLOTS(RESULTS)
  ) completions (
      .i_clk,
      .i_rst,
      .i_fatal_stop(i_fatal_stop || o_fatal),
      .i_d_valid,
      .o_d_ready,
      .i_d,
      .o_work_valid(work_valid),
      .o_work_offer(work_offer),
      .i_work_ready(run),
      .o_work(work),
      .o_work_tid(work_tid),
      .o_work_buffer(work_buffer),
      .o_work_error(work_error),
      .o_work_counted(work_counted),
      .i_count_valid(run && array_response && decision_engine),
      .i_count_tid(decision_tid),
      .o_waiting(waiting),
      .o_waiting_offer(waiting_offer),
      .o_waiting_request(waiting_request),
      .i_park(park),
      .i_wake(wake),
      .i_wake_error(wake_error),
      .i_retry_park(retry_park),
      .o_image_index(image_index),
      .i_image_data(image_data),
      .i_retry_valid(retry_valid),
      .i_retry_tid(decision_tid),
      .i_pin_valid(pin_valid),
      .i_pin_tid(decision_tid),
      .i_pin_way(array_way),
      .i_query_addr(array_query),
      .o_exclude(completion_exclude),
      .i_put_addr(selected_put_q.addr),
      .o_put_busy(put_busy),
      .i_result_valid(result_valid && run),
      .o_result_ready(result_ready),
      .i_result(result),
      .o_g_valid,
      .i_g_ready,
      .o_g,
      .i_c_valid,
      .o_c_ready,
      .i_c,
      .o_u_valid,
      .i_u_ready,
`ifdef COHERENCE_HOME_CONTROL
      .i_fill_waiting(f_fill_waiting),
      .i_fill_seated(f_fill_seated),
      .i_engine_busy(~engine_idle),
      .i_engine_unpinned(f_engine_unpinned),
      .i_engine_pinned(f_engine_pinned),
      .i_engine_initial_error(f_engine_initial_error),
      .i_engine_tid(engine_tid),
      .i_engine_addr(engine_addr),
`endif
      .o_u
  );

  for (genvar engine = 0; engine < RESULTS; engine++) begin : gen_engine
    coherence_home_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS)
    ) service (
        .i_clk,
        .i_rst,
        .i_stop(!run),
        .i_work_valid(work_offer && work_buffer == ResultBits'(engine)),
        .i_work(work),
        .i_tid(work_tid),
        .i_work_error(work_error),
        .o_idle(engine_idle[engine]),
        .o_lookup_valid(engine_lookup[engine]),
        .i_lookup_ready(tag_ready[engine]),
        .o_addr(engine_addr[engine]),
        .o_tid(engine_tid[engine]),
        .o_opcode(engine_opcode[engine]),
        .o_maintenance(engine_maintenance[engine]),
        .i_decision_valid(array_response && run && array_token == TokenBits'(engine)),
        .i_decision_resident(decision_hit),
        .i_decision_way(array_way),
        .i_decision_state(array_state),
        .o_read_valid(engine_read[engine]),
        .o_read_offer(read_valid[engine]),
        .i_read_ready(read_ready[engine]),
        .o_way(engine_way[engine]),
        .i_data_valid(array_data_valid && array_data_token == TokenBits'(engine)),
        .i_data(array_data),
        .o_p_valid(probe_valid[engine]),
        .i_p_ready(probe_ready[engine]),
        .o_p(probe_payload[engine]),
        .i_r_valid,
        .o_r_ready(engine_r_ready[engine]),
        .i_r,
        .o_wa_valid(ack_valid[engine]),
        .i_wa_ready(ack_ready[engine]),
        .o_wa(ack_payload[engine]),
        .o_update_valid(engine_update[engine]),
        .i_update_ready(update_ready[engine]),
        .o_update_mask(engine_update_mask[engine]),
        .o_update_data(engine_update_data[engine]),
        .i_updated(array_updated && array_updated_token == TokenBits'(engine)),
        .o_result_valid(engine_result[engine]),
        .i_result_ready(engine_result_ready[engine]),
        .o_result(engine_result_payload[engine]),
        .o_image(engine_image[engine]),
`ifdef COHERENCE_HOME_CONTROL
        .o_tag_owner(f_tag_owner[engine]),
        .o_unpinned_owner(f_engine_unpinned[engine]),
        .o_pin_owner(f_engine_pinned[engine]),
        .o_initial_error(f_engine_initial_error[engine]),
        .o_read_owner(f_read_owner[engine]),
        .o_update_owner(f_update_owner[engine]),
`endif
        .o_fatal(engine_fatal[engine])
    );
    always_ff @(posedge i_clk) begin
      if (i_rst) engine_counted_q[engine] <= 1'b0;
      else if (work_offer && work_buffer == ResultBits'(engine))
        engine_counted_q[engine] <= work_counted;
    end
    assign tag_valid[engine] = engine_lookup[engine];
    assign tag_payload[engine] = {TokenBits'(engine), engine_addr[engine]};
    assign read_payload[engine] = {TokenBits'(engine), engine_way[engine], engine_addr[engine]};
    assign update_valid[engine] = engine_update[engine];
    assign update_payload[engine] = {
      TokenBits'(engine),
      engine_way[engine],
      engine_addr[engine],
      1'b1,
      2'(coherence_pkg::Modified),
      engine_update_mask[engine],
      engine_update_data[engine]
    };
  end
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 275),
      .PORTS(RESULTS),
      .HOLD_VALID(1)
  ) result_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(engine_result),
      .o_ready(engine_result_ready),
      .i_payload(engine_result_payload),
      .o_valid(result_valid),
      .o_offer(),
      .i_ready(result_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active),
`endif
      .o_payload(result)
  );
  coherence_d_arbiter #(
      .WIDTH(TagPacketBits),
      .PORTS(Clients),
      .HOLD_VALID(1)
  ) tag_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(tag_valid),
      .o_ready(tag_ready),
      .i_payload(tag_payload),
      .o_valid(tag_request_valid),
      .o_offer(),
      .i_ready(tag_request_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active),
`endif
      .o_payload(tag_request)
  );
  coherence_d_arbiter #(
      .WIDTH(ReadPacketBits),
      .PORTS(Clients)
  ) read_arbiter (
      .i_clk,
      .i_rst(!active),
      .i_valid(read_valid),
      .o_ready(read_ready),
      .i_payload(read_payload),
      .o_valid(row_request_valid),
      .o_offer(),
      .i_ready(row_request_ready && active),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active || f_local_fatal),
`endif
      .o_payload(row_request)
  );
  coherence_d_arbiter #(
      .WIDTH(UpdatePacketBits),
      .PORTS(Clients),
      .HOLD_VALID(1)
  ) update_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(update_valid),
      .o_ready(update_ready),
      .i_payload(update_payload),
      .o_valid(update_request_valid),
      .o_offer(),
      .i_ready(update_request_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active),
`endif
      .o_payload(update_request)
  );
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 30),
      .PORTS(Clients),
      .HOLD_VALID(1)
  ) probe_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(probe_valid),
      .o_ready(probe_ready),
      .i_payload(probe_payload),
      .o_valid(probe_out_valid),
      .o_offer(probe_out_offer),
      .i_ready(i_p_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active),
`endif
      .o_payload(probe_out)
  );
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 11),
      .PORTS(Clients),
      .HOLD_VALID(1)
  ) ack_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(ack_valid),
      .o_ready(ack_ready),
      .i_payload(ack_payload),
      .o_valid(ack_out_valid),
      .o_offer(),
      .i_ready(i_wa_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!active),
`endif
      .o_payload(ack_out)
  );
  // The L1D qualifies an offered probe with the same reset itself.
  assign o_p_valid = run && probe_out_offer;
  assign o_p = probe_out;
  assign o_r_ready = active && (|engine_r_ready || |fill_r_ready);
  assign o_wa_valid = active && ack_out_valid;
  assign o_wa = ack_out;

  coherence_home_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .TOKEN_BITS(TokenBits),
      .ULTRA(ULTRA)
  ) array (
      .i_clk,
      .i_rst,
      .o_init_done(),
      .i_req_valid(tag_request_valid && run),
      .o_req_ready(tag_request_ready),
      .i_req_addr(tag_request.addr),
      .i_req_token(tag_request.token),
      .o_query_addr(array_query),
      .i_exclude(array_exclude),
      .o_resp_valid(array_response),
      .i_resp_ready(run),
      .i_resp_claim(array_claim),
      .o_resp_token(array_token),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .i_read_valid(row_request_valid && active),
      .o_read_ready(row_request_ready),
      .i_read_addr(row_request.addr),
      .i_read_way(row_request.way),
      .i_read_token(row_request.token),
      .o_read_valid(array_data_valid),
      .o_read_token(array_data_token),
      .o_read_data(array_data),
      .i_update_valid(update_request_valid && run),
      .o_update_ready(update_request_ready),
      .i_update_addr(update_request.addr),
      .i_update_way(update_request.way),
      .i_update_tag(update_request.tag_write),
      .i_update_state(update_request.state),
      .i_update_mask(update_request.mask),
      .i_update_data(update_request.data),
      .i_update_token(update_request.token),
      .o_updated(array_updated),
`ifdef COHERENCE_HOME_CONTROL
      .i_tag_owner(f_tag_owner),
      .i_tag_address(f_tag_address),
      .i_read_owner(f_read_owner),
      .i_update_owner(f_update_owner),
`endif
      .o_updated_token(array_updated_token)
  );

  always_comb begin
    array_exclude = completion_exclude;
    for (int fill = 0; fill < FILLS; fill++) begin
      if (fill_phase_q[fill] != FillFree && same_set(fill_addr_q[fill], array_query))
        array_exclude[fill_way_q[fill]] = 1'b1;
    end
    for (int put = 0; put < Puts; put++) begin
      if ((put_phase_q[put] == PutUpdate || put_phase_q[put] == PutUpdateWait ||
          put_phase_q[put] == PutAck) && same_set(
              put_addr[put], array_query
          ))
        array_exclude[put_way_q[put]] = 1'b1;
    end
  end
  always_comb begin
    decision_reader = 1'b0;
    for (int engine = 0; engine < RESULTS; engine++)
    decision_reader |= array_token == TokenBits'(engine) && read_waiter(engine_opcode[engine]);
    decision_engine = int'(array_token) < RESULTS;
    decision_put = int'(array_token) >= RESULTS + FILLS;
    decision_addr = array_query;
    decision_tid = '0;
    decision_opcode = '0;
    if (decision_engine) begin
      if (LINE_BYTES == 64) decision_addr[5] = engine_addr[ResultBits'(array_token)][5];
      decision_tid = engine_tid[ResultBits'(array_token)];
      decision_opcode = engine_opcode[ResultBits'(array_token)];
    end
    for (int put = 0; put < Puts; put++)
    if (LINE_BYTES == 64 && array_token == TokenBits'(RESULTS + FILLS + put))
      decision_addr[5] = put_addr[put][5];
    decision_blocked = 1'b0;
    victim_blocked = 1'b0;
    fill_free = 1'b0;
    fill_free_index = '0;
    wb_free = 1'b0;
    wb_free_index = '0;
    for (int wb = NUM_WB - 1; wb >= 0; wb--) begin
      if (!wb_valid_q[wb] && !wb_frozen_q[wb]) begin
        wb_free = 1'b1;
        wb_free_index = WbBits'(wb);
      end
      if (wb_valid_q[wb]) begin
        if (same_block(wb_addr_q[wb], decision_addr)) decision_blocked = 1'b1;
        if (same_block(wb_addr_q[wb], array_addr)) victim_blocked = 1'b1;
      end
    end
    for (int fill = FILLS - 1; fill >= 0; fill--) begin
      if (fill_phase_q[fill] == FillFree) begin
        fill_free = 1'b1;
        fill_free_index = FillBits'(fill);
      end else begin
        if (same_set(fill_addr_q[fill], array_query) && fill_way_q[fill] == array_way)
          victim_blocked = 1'b1;
        if (fill_phase_q[fill] != FillReady) begin
          if (same_block(fill_addr_q[fill], decision_addr)) begin
            decision_blocked = 1'b1;
          end
          if (fill_victim_q[fill] && same_block(fill_old_addr_q[fill], decision_addr))
            decision_blocked = 1'b1;
        end
      end
    end
    for (int put = 0; put < Puts; put++) begin
      if (put_phase_q[put] != PutFree &&
          (!decision_put || array_token != TokenBits'(RESULTS + FILLS + put))) begin
        if (same_sector(put_addr[put], decision_addr)) decision_blocked = 1'b1;
        if (same_block(put_addr[put], array_addr)) victim_blocked = 1'b1;
      end
    end
    for (int engine = 0; engine < RESULTS; engine++) begin
      if (array_state != coherence_pkg::Invalid && !engine_idle[engine] &&
          array_token != TokenBits'(engine) && same_block(
              engine_addr[engine], array_addr
          ))
        victim_blocked = 1'b1;
    end
    decision_hit = array_hit && array_available && !decision_blocked;
    decision_fill = decision_engine && !array_hit && array_available && !decision_blocked &&
        !victim_blocked && fill_free &&
        (array_state == coherence_pkg::Invalid || wb_free);
    decision_join = |join_fill;
    decision_retry = decision_engine && !decision_hit;
    array_claim = run && array_response && (decision_hit || decision_fill);
    retry_valid = run && array_response && decision_retry;
    retry_park = decision_fill || decision_join;
    pin_valid = run && array_response && decision_engine && decision_hit;
  end

  // Parked readers own metadata seats, including readers with predecessors.
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_seats
    logic [COMPLETIONS-1:0] eligible;
    logic enabled, joining;
    assign enabled = run && fill_phase_q[fill] != FillFree &&
        fill_phase_q[fill] != FillReady && fill_phase_q[fill] != FillInstallWait &&
        !fill_error_q[fill];
    assign join_fill[fill] = fill_phase_q[fill] != FillFree &&
        fill_phase_q[fill] != FillReady && fill_phase_q[fill] != FillInstallWait &&
        !fill_error_q[fill] && fill_seat_count_q[fill] < 3 &&
        same_block(
        fill_addr_q[fill], decision_addr
    ) && decision_reader;
    assign joining = run && array_response && join_fill[fill];
    for (genvar slot = 0; slot < COMPLETIONS; slot++) begin : gen_eligible
      assign eligible[slot] = enabled && waiting_offer[slot] && same_block(
          waiting_addr[slot], fill_addr_q[fill]
      ) && read_waiter(
          waiting_opcode[slot]
      );
    end
    coherence_seat_select #(
        .SLOTS(COMPLETIONS)
    ) selector (
        .i_eligible(eligible),
        .i_occupied_count(fill_seat_count_q[fill]),
        .i_join(joining),
        .o_selected(fill_add_seats[fill]),
        .o_selected_count(fill_add_count[fill])
    );
  end
  always_comb begin
    park = '0;
    wake = '0;
    wake_error = '0;
    for (int fill = 0; fill < FILLS; fill++) begin
      park |= fill_add_seats[fill];
      if (fill_wake[fill]) begin
        wake |= fill_seats_q[fill];
        if (fill_error_q[fill]) wake_error |= fill_seats_q[fill];
      end
    end
  end

  assign put_key_match = incoming_put.hart == selected_put_q.hart &&
      incoming_put.put_id == selected_put_q.put_id && incoming_put.epoch == selected_put_q.epoch &&
      incoming_put.addr == selected_put_q.addr;
  always_comb begin
    put_blocked = 1'b0;
    if (array_response && decision_fill && array_state != coherence_pkg::Invalid && same_block(
            array_addr, selected_put_q.addr
        ))
      put_blocked = 1'b1;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady && (same_block(
            fill_addr_q[fill], selected_put_q.addr
        ) || (fill_victim_q[fill] && same_block(
            fill_old_addr_q[fill], selected_put_q.addr
        ))))
      put_blocked = 1'b1;
    for (int wb = 0; wb < NUM_WB; wb++)
    if (wb_valid_q[wb] && same_block(wb_addr_q[wb], selected_put_q.addr)) put_blocked = 1'b1;
  end
  assign o_w_ready = active && put_selected_q && put_key_match && !put_busy && !put_blocked &&
      put_phase_q[selected_put_q.put_id] == PutFree;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      put_selected_q <= 1'b0;
      selected_put_q <= '0;
    end else if (run) begin
      if (!put_selected_q && i_w_valid) begin
        selected_put_q <= incoming_put;
        put_selected_q <= 1'b1;
      end
      if (put_selected_q && (!i_w_valid || !put_key_match || o_w_ready)) put_selected_q <= 1'b0;
    end
  end

  for (genvar put = 0; put < Puts; put++) begin : gen_put
    localparam int unsigned Client = RESULTS + FILLS + put;
    coh_w_t  packet;
    coh_wa_t ack;
    assign packet = put_q[put];
    assign put_maintenance[put] = packet.maintenance;
    wire upper = LINE_BYTES == 64 && packet.addr[5];
    assign put_addr[put] = packet.addr;
    assign tag_valid[Client] = run && put_phase_q[put] == PutLookup;
    assign tag_payload[Client] = {TokenBits'(Client), put_addr[put]};
    assign read_valid[Client] = 1'b0;
    assign read_payload[Client] = '0;
    assign probe_valid[Client] = 1'b0;
    assign probe_payload[Client] = '0;
    assign update_valid[Client] = run && put_phase_q[put] == PutUpdate;
    assign update_payload[Client] = {
      TokenBits'(Client),
      put_way_q[put],
      put_addr[put],
      1'b1,
      2'(coherence_pkg::Modified),
      LINE_BYTES'(32'hffff_ffff) << (upper ? 32 : 0),
      (8 * LINE_BYTES)'(packet.data) << (upper ? 256 : 0)
    };
    assign ack_valid[Client] = run && put_phase_q[put] == PutAck;
    assign ack_payload[Client] = ack;
    always_comb begin
      ack = '0;
      ack.hart = packet.hart;
      ack.put_id = packet.put_id;
      ack.epoch = packet.epoch;
      ack.addr = packet.addr;
      ack.tid = PutTid + 6'(put);
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        put_phase_q[put] <= PutFree;
        put_q[put] <= '0;
        put_way_q[put] <= '0;
      end else if (run) begin
        if (i_w_valid && o_w_ready && incoming_put.put_id == 1'(put)) begin
          put_q[put] <= incoming_put;
          put_phase_q[put] <= PutLookup;
        end
        if (tag_valid[Client] && tag_ready[Client]) put_phase_q[put] <= PutDecision;
        if (array_response && array_token == TokenBits'(Client)) begin
          if (!array_hit) put_phase_q[put] <= PutFatal;
          else if (decision_blocked) put_phase_q[put] <= PutLookup;
          else begin
            put_way_q[put]   <= array_way;
            put_phase_q[put] <= PutUpdate;
          end
        end
        if (update_valid[Client] && update_ready[Client]) put_phase_q[put] <= PutUpdateWait;
        if (array_updated && array_updated_token == TokenBits'(Client)) put_phase_q[put] <= PutAck;
        if (ack_valid[Client] && ack_ready[Client]) put_phase_q[put] <= PutFree;
      end
    end
  end

  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill
    localparam int unsigned Client = RESULTS + fill;
    coh_p_t probe;
    coh_wa_t absorbed_ack;
    wire probe_matches = reply.tid == FillTid + 6'(fill) && reply.addr == probe.addr &&
        reply.epoch == 0 && reply.hart == 0 &&
        (reply.opcode == coherence_pkg::ProbeAck || reply.opcode == coherence_pkg::ProbeData);
    wire allocate = run && array_response && decision_fill && fill_free_index == FillBits'(fill);
    assign tag_valid[Client] = 1'b0;
    assign tag_payload[Client] = '0;
    assign read_valid[Client] = fill_phase_q[fill] == FillRecall && !fill_read_sent_q[fill];
    assign read_payload[Client] = {TokenBits'(Client), fill_way_q[fill], fill_old_addr_q[fill]};
    assign probe_valid[Client] = run && fill_phase_q[fill] == FillRecall &&
        recall_phase_q[fill] == RecallOffer;
    assign probe_payload[Client] = probe;
    assign fill_probe[fill] = probe;
    assign fill_r_ready[fill] = run && fill_phase_q[fill] == FillRecall &&
        recall_phase_q[fill] == RecallWait && probe_matches;
    assign ack_valid[Client] = run && fill_phase_q[fill] == FillRecall &&
        recall_phase_q[fill] == RecallAck;
    assign ack_payload[Client] = fill_ack_q[fill];
    assign update_valid[Client] = run &&
        (fill_phase_q[fill] == FillInvalidate || fill_phase_q[fill] == FillInstall);
    assign update_payload[Client] = {
      TokenBits'(Client),
      fill_way_q[fill],
      fill_phase_q[fill] == FillInvalidate ? fill_old_addr_q[fill] : fill_addr_q[fill],
      1'b1,
      fill_phase_q[fill] == FillInvalidate ? 2'(coherence_pkg::Invalid) : 2'(coherence_pkg::Shared),
      {LINE_BYTES{fill_phase_q[fill] == FillInstall}},
      fill_phase_q[fill] == FillInstall ? fill_image_q[fill] : {(8 * LINE_BYTES) {1'b0}}
    };
    assign fill_wake[fill] = run &&
        ((fill_phase_q[fill] == FillInstallWait && array_updated &&
          array_updated_token == TokenBits'(Client)) ||
         (fill_phase_q[fill] == FillMemory && fill_done_q[fill] && fill_error_q[fill]));
    always_comb begin
      probe = '0;
      probe.opcode = coherence_pkg::ProbeRead;
      probe.tid = FillTid + 6'(fill);
      probe.addr = fill_old_addr_q[fill] | ADDR_WIDTH'(int'(fill_sector_q[fill]) * 32);
      probe.reason = coherence_pkg::Replace;
      absorbed_ack = '0;
      absorbed_ack.hart = reply.hart;
      absorbed_ack.put_id = reply.put_id;
      absorbed_ack.epoch = reply.put_epoch;
      absorbed_ack.addr = reply.addr;
      absorbed_ack.absorbed = 1'b1;
      absorbed_ack.tid = reply.tid;
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        fill_phase_q[fill] <= FillFree;
        recall_phase_q[fill] <= RecallDone;
        fill_addr_q[fill] <= '0;
        fill_old_addr_q[fill] <= '0;
        fill_way_q[fill] <= '0;
        fill_wb_q[fill] <= '0;
        fill_sent_q[fill] <= 1'b0;
        fill_done_q[fill] <= 1'b0;
        fill_error_q[fill] <= 1'b0;
        fill_victim_q[fill] <= 1'b0;
        fill_read_sent_q[fill] <= 1'b0;
        fill_read_done_q[fill] <= 1'b0;
        fill_sector_q[fill] <= 1'b0;
        fill_dirty_q[fill] <= 1'b0;
        fill_dirty_sectors_q[fill] <= '0;
        fill_seats_q[fill] <= '0;
        fill_seat_count_q[fill] <= '0;
        fill_write_q[fill] <= 1'b0;
        fill_ack_q[fill] <= '0;
      end else begin
        if (o_mem_req_valid && i_mem_req_ready && o_mem_req_id == 5'(fill))
          fill_sent_q[fill] <= 1'b1;
        if (i_mem_resp_valid && i_mem_resp_id == 5'(fill)) begin
          fill_image_q[fill] <= i_mem_resp_data;
          fill_done_q[fill]  <= 1'b1;
          fill_error_q[fill] <= i_mem_resp_error;
        end
        if (run) begin
          fill_seats_q[fill] <= fill_seats_q[fill] | fill_add_seats[fill];
          fill_seat_count_q[fill] <= fill_seat_count_q[fill] + fill_add_count[fill];
          if (allocate) begin
            fill_addr_q[fill] <= {decision_addr[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
            fill_old_addr_q[fill] <= array_addr;
            fill_way_q[fill] <= array_way;
            fill_wb_q[fill] <= wb_free_index;
            fill_victim_q[fill] <= array_state != coherence_pkg::Invalid;
            fill_sent_q[fill] <= 1'b0;
            fill_done_q[fill] <= 1'b0;
            fill_error_q[fill] <= 1'b0;
            fill_read_sent_q[fill] <= array_state == coherence_pkg::Invalid;
            fill_read_done_q[fill] <= array_state == coherence_pkg::Invalid;
            fill_sector_q[fill] <= 1'b0;
            fill_dirty_q[fill] <= array_state == coherence_pkg::Modified;
            fill_dirty_sectors_q[fill] <= '0;
            fill_seats_q[fill] <= COMPLETIONS'(1) << decision_tid;
            fill_seat_count_q[fill] <= 1;
            fill_write_q[fill] <= decision_opcode == coherence_pkg::DMAWrite;
            fill_phase_q[fill] <= array_state == coherence_pkg::Invalid ? FillMemory : FillRecall;
            recall_phase_q[fill] <= RecallOffer;
          end
          if (array_response && join_fill[fill]) begin
            fill_seats_q[fill][CompletionBits'(decision_tid)] <= 1'b1;
            fill_seat_count_q[fill] <= fill_seat_count_q[fill] + fill_add_count[fill] + 1'b1;
          end
          if (fill_phase_q[fill] == FillReady && pin_valid &&
              fill_seats_q[fill][CompletionBits'(decision_tid)]) begin
            fill_seats_q[fill][CompletionBits'(decision_tid)] <= 1'b0;
            fill_seat_count_q[fill] <= fill_seat_count_q[fill] - 1'b1;
          end
          if (fill_phase_q[fill] == FillReady && fill_seats_q[fill] == 0)
            fill_phase_q[fill] <= FillFree;
          if (read_valid[Client] && read_ready[Client]) fill_read_sent_q[fill] <= 1'b1;
          if (array_data_valid && array_data_token == TokenBits'(Client))
            fill_read_done_q[fill] <= 1'b1;
          if (probe_valid[Client] && probe_ready[Client]) recall_phase_q[fill] <= RecallWait;
          if (i_r_valid && fill_r_ready[fill]) begin
            if (reply.data_valid) begin
              fill_dirty_q[fill] <= 1'b1;
              for (int sector = 0; sector < LINE_BYTES / 32; sector++)
              if ((LINE_BYTES == 64 && reply.addr[5]) == 1'(sector))
                fill_dirty_sectors_q[fill][sector] <= 1'b1;
            end
            if (reply.error) fill_phase_q[fill] <= FillFatal;
            else begin
              if (reply.absorbed) begin
                fill_ack_q[fill] <= absorbed_ack;
                recall_phase_q[fill] <= RecallAck;
              end else recall_phase_q[fill] <= RecallDone;
            end
          end
          if (ack_valid[Client] && ack_ready[Client]) recall_phase_q[fill] <= RecallDone;
          if (fill_phase_q[fill] == FillRecall && recall_phase_q[fill] == RecallDone) begin
            if (LINE_BYTES == 64 && !fill_sector_q[fill]) begin
              fill_sector_q[fill]  <= 1'b1;
              recall_phase_q[fill] <= RecallOffer;
            end else if (fill_read_done_q[fill]) fill_phase_q[fill] <= FillDetach;
          end
          if (fill_phase_q[fill] == FillDetach) fill_phase_q[fill] <= FillInvalidate;
          if (fill_phase_q[fill] == FillInvalidate && update_ready[Client])
            fill_phase_q[fill] <= FillInvalidateWait;
          if (fill_phase_q[fill] == FillInvalidateWait && array_updated &&
              array_updated_token == TokenBits'(Client))
            fill_phase_q[fill] <= FillMemory;
          if (fill_phase_q[fill] == FillMemory && fill_done_q[fill]) begin
            fill_phase_q[fill] <= fill_error_q[fill] ? FillFree : FillInstall;
            if (fill_error_q[fill]) begin
              fill_seats_q[fill] <= '0;
              fill_seat_count_q[fill] <= '0;
            end
          end
          if (fill_phase_q[fill] == FillInstall && update_ready[Client])
            fill_phase_q[fill] <= FillInstallWait;
          if (fill_phase_q[fill] == FillInstallWait && array_updated &&
              array_updated_token == TokenBits'(Client))
            fill_phase_q[fill] <= FillReady;
        end
      end
    end
  end

  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill_memory
    assign memory_valid[fill]   = run && fill_phase_q[fill] != FillFree && !fill_sent_q[fill];
    assign memory_payload[fill] = {1'b0, fill_addr_q[fill], {(8 * LINE_BYTES) {1'b0}}, 5'(fill)};
  end
  for (genvar wb = 0; wb < NUM_WB; wb++) begin : gen_wb_memory
    assign memory_valid[FILLS+wb]   = run && wb_valid_q[wb] && wb_frozen_q[wb] && !wb_sent_q[wb];
    assign memory_payload[FILLS+wb] = {1'b1, wb_addr_q[wb], wb_data_q[wb], 5'(16 + wb)};
  end
  always_comb begin
    memory_pick  = '0;
    memory_first = '0;
    memory_found = 1'b0;
    memory_after = 1'b0;
    memory_ready = '0;
    for (int source_idx = MemorySources - 1; source_idx >= 0; source_idx--) begin
      if (memory_valid[source_idx]) begin
        memory_found = 1'b1;
        memory_first = MemorySelectBits'(source_idx);
        if (source_idx >= int'(memory_next_q)) begin
          memory_after = 1'b1;
          memory_pick  = MemorySelectBits'(source_idx);
        end
      end
      if (o_mem_req_valid && i_mem_req_ready &&
          o_mem_req_id == (source_idx < FILLS ? 5'(source_idx) : 5'(16+source_idx-FILLS)))
        memory_ready[source_idx] = 1'b1;
    end
    if (!memory_after) memory_pick = memory_first;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      memory_out_valid <= 1'b0;
      memory_out <= '0;
      memory_next_q <= '0;
    end else begin
      if (o_mem_req_valid && i_mem_req_ready) memory_out_valid <= 1'b0;
      if (!memory_out_valid && run && memory_found) begin
        memory_out_valid <= 1'b1;
        memory_out <= memory_payload[memory_pick];
        if (memory_pick == MemorySelectBits'(MemorySources - 1)) memory_next_q <= '0;
        else memory_next_q <= memory_pick + 1'b1;
      end
    end
  end
  assign o_mem_req_valid = memory_out_valid && !i_rst;
  assign {o_mem_req_write, o_mem_req_addr, o_mem_req_data, o_mem_req_id} = memory_out;
  assign o_mem_req_mask = {LINE_BYTES{o_mem_req_write}};
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wb_valid_q  <= '0;
      wb_frozen_q <= '0;
      wb_sent_q   <= '0;
      for (int wb = 0; wb < NUM_WB; wb++) wb_addr_q[wb] <= '0;
    end else begin
      for (int wb = 0; wb < NUM_WB; wb++) begin
        if (o_mem_req_valid && i_mem_req_ready && o_mem_req_id == 5'(16 + wb))
          wb_sent_q[wb] <= 1'b1;
        if (i_mem_resp_valid && i_mem_resp_id == 5'(16 + wb) && !i_mem_resp_error) begin
          wb_valid_q[wb]  <= 1'b0;
          wb_frozen_q[wb] <= 1'b0;
          wb_sent_q[wb]   <= 1'b0;
        end
      end
      if (run) begin
        if (array_response && decision_fill && array_state != coherence_pkg::Invalid) begin
          wb_valid_q[wb_free_index]  <= 1'b1;
          wb_frozen_q[wb_free_index] <= 1'b0;
          wb_sent_q[wb_free_index]   <= 1'b0;
          wb_addr_q[wb_free_index]   <= array_addr;
        end
        for (int fill = 0; fill < FILLS; fill++) begin
          for (int wb = 0; wb < NUM_WB; wb++)
          if (fill_wb_q[fill] == WbBits'(wb) && wb_valid_q[wb] && !wb_frozen_q[wb]) begin
            if (array_data_valid && array_data_token == TokenBits'(RESULTS + fill)) begin
              for (int sector = 0; sector < LINE_BYTES / 32; sector++)
              if (!fill_dirty_sectors_q[fill][sector])
                wb_data_q[wb][sector*256+:256] <= array_data[sector*256+:256];
            end
            for (int sector = 0; sector < LINE_BYTES / 32; sector++)
            if (i_r_valid && fill_r_ready[fill] && reply.data_valid &&
                  (LINE_BYTES == 64 && reply.addr[5]) == 1'(sector))
              wb_data_q[wb][sector*256+:256] <= reply.data;
          end
          if (fill_phase_q[fill] == FillDetach && wb_valid_q[fill_wb_q[fill]] &&
              !wb_frozen_q[fill_wb_q[fill]]) begin
            if (fill_dirty_q[fill]) wb_frozen_q[fill_wb_q[fill]] <= 1'b1;
            else wb_valid_q[fill_wb_q[fill]] <= 1'b0;
          end
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_fatal <= 1'b0;
      o_fatal_addr <= '0;
    end else begin
      for (int engine = 0; engine < RESULTS; engine++)
      if (engine_fatal[engine]) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= engine_addr[engine];
      end
      for (int put = 0; put < Puts; put++)
      if (put_phase_q[put] == PutFatal) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= put_addr[put];
      end
      for (int fill = 0; fill < FILLS; fill++)
      if (fill_phase_q[fill] == FillFatal) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= fill_old_addr_q[fill];
      end
      if (work_offer && work_error && work.opcode == coherence_pkg::GetM) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= work.addr;
      end
      if (i_mem_resp_valid && i_mem_resp_id[4] && i_mem_resp_error) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= wb_addr_q[WbBits'(i_mem_resp_id)];
      end
    end
  end

  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_perf
    assign filling[fill] = fill_phase_q[fill] != FillFree;
    assign write_filling[fill] = filling[fill] && fill_write_q[fill];
  end
  always_comb begin
    perf_maintenance = decision_engine ? engine_maintenance[ResultBits'(array_token)] : 1'b0;
    for (int put = 0; put < Puts; put++)
    if (array_token == TokenBits'(RESULTS + FILLS + put)) perf_maintenance = put_maintenance[put];
    perf_lookup = run && array_response && !perf_maintenance &&
        (!decision_engine || !engine_counted_q[ResultBits'(array_token)]);
  end
  always_ff @(posedge i_clk) begin
    o_perf_events <= '0;
    o_write_perf_events <= '0;
    if (!i_rst) begin
      o_perf_events.access <= perf_lookup;
      o_perf_events.hit <= perf_lookup && array_hit;
      o_perf_events.miss <= perf_lookup && !array_hit;
      o_perf_events.miss_outstanding <= cache_perf_pkg::MissOutstandingBits'($countones(filling));
      o_write_perf_events.write_fill_outstanding <= cache_perf_pkg::MissOutstandingBits'($countones(
          write_filling
      ));
      o_perf_events.writeback <= |(memory_valid[FILLS+:NUM_WB] & memory_ready[FILLS+:NUM_WB]);
      o_perf_events.slot_full_stall <= run && array_response && decision_retry && !retry_park;
      o_perf_events.conflict_stall <= run && array_response && decision_blocked;
      o_write_perf_events.write_fill <= run && array_response && decision_fill &&
          decision_opcode == coherence_pkg::DMAWrite;
    end
  end

  if (NUM_WB < 1 || NUM_WB > 16 || FILLS < 1 || FILLS > 4) begin : gen_invalid
    initial $fatal(1, "coherence_home: invalid capacity");
  end
`ifndef SYNTHESIS
  logic reference_join;
  logic [FillBits-1:0] reference_join_index;
  always_comb begin
    reference_join = 1'b0;
    reference_join_index = '0;
    for (int fill = FILLS - 1; fill >= 0; fill--)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady && same_block(
            fill_addr_q[fill], decision_addr
        )) begin
      reference_join = fill_phase_q[fill] != FillInstallWait &&
          !fill_error_q[fill] && fill_seat_count_q[fill] < 3 &&
          decision_engine && read_waiter(decision_opcode);
      reference_join_index = FillBits'(fill);
    end
  end
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      assert (join_fill == (reference_join ? FILLS'(1) << reference_join_index : FILLS'(0)));
      assert ($onehot0({engine_r_ready, fill_r_ready}));
      assert ((park & wake) == 0);
      if (work_valid && active) assert (engine_idle[work_buffer]);
      if (array_response && decision_engine)
        assert (same_block(array_query, engine_addr[ResultBits'(array_token)]));
      for (int engine = 0; engine < RESULTS; engine++)
      if (active) assert (engine_read[engine] == read_valid[engine]);
      if (active) assert ((row_request_valid && row_request_ready) == (|(read_valid & read_ready)));
      for (int put = 0; put < Puts; put++)
      if (array_response && array_token == TokenBits'(RESULTS + FILLS + put))
        assert (same_block(array_query, put_addr[put]));
      if (i_w_valid && o_w_ready) assert (incoming_put.hart == 0 && incoming_put.epoch == 0);
      if (i_mem_resp_valid) begin
        if (i_mem_resp_id[4]) begin
          assert (int'(i_mem_resp_id[3:0]) < NUM_WB);
          assert (wb_valid_q[WbBits'(i_mem_resp_id)] && wb_sent_q[WbBits'(i_mem_resp_id)]);
        end else begin
          assert (int'(i_mem_resp_id) < FILLS);
          assert (fill_phase_q[FillBits'(i_mem_resp_id)] != FillFree &&
            fill_sent_q[FillBits'(i_mem_resp_id)] && !fill_done_q[FillBits'(i_mem_resp_id)]);
        end
      end
      if (array_response && active && decision_fill) begin
        assert (!array_exclude[array_way] && !decision_blocked && !victim_blocked);
        if (array_state != coherence_pkg::Invalid) assert (wb_free);
      end
      if (array_response && active && !array_hit && array_available)
        assert (!array_exclude[array_way]);
      for (int put = 0; put < Puts; put++) begin
        if (array_response && array_token == TokenBits'(RESULTS + FILLS + put))
          assert (put_phase_q[put] == PutDecision);
        if (array_updated && array_updated_token == TokenBits'(RESULTS + FILLS + put))
          assert (put_phase_q[put] == PutUpdateWait);
      end
      for (int fill = 0; fill < FILLS; fill++) begin
        assert ($countones(fill_seats_q[fill]) <= 3);
        assert (int'(fill_seat_count_q[fill]) == $countones(fill_seats_q[fill]));
        if (array_data_valid && array_data_token == TokenBits'(RESULTS + fill)) begin
          assert (fill_phase_q[fill] == FillRecall || fill_phase_q[fill] == FillFatal);
          assert (wb_valid_q[fill_wb_q[fill]] && !wb_frozen_q[fill_wb_q[fill]]);
        end
        if (fill_phase_q[fill] == FillRecall || fill_phase_q[fill] == FillDetach)
          assert (wb_valid_q[fill_wb_q[fill]] && !wb_frozen_q[fill_wb_q[fill]]);
        for (int other = fill + 1; other < FILLS; other++)
        if (fill_phase_q[fill] != FillFree && fill_phase_q[other] != FillFree) begin
          assert (!same_block(fill_addr_q[fill], fill_addr_q[other]));
          assert (!(same_set(
              fill_addr_q[fill], fill_addr_q[other]
          ) && fill_way_q[fill] == fill_way_q[other]));
        end
      end
    end
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [31:0] f_memory_pending_q;
  (* anyconst *) logic [OffsetBits-1:0] f_byte;
`ifdef COHERENCE_HOME_COVER
  logic [2:0] f_seen_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) f_seen_q <= '0;
    else
      f_seen_q <= f_seen_q | {(|wb_frozen_q), (|wb_sent_q),
        (active && array_response && decision_blocked)};
  end
`endif
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !$past(i_rst) && $past(i_fatal_stop)) assume (i_fatal_stop || i_rst);
    if (!i_rst && i_w_valid)
      assume (incoming_put.hart == 0 && incoming_put.epoch == 0 && incoming_put.addr[4:0] == 0);
    if (i_rst) f_memory_pending_q <= '0;
    else begin
      if (o_mem_req_valid && i_mem_req_ready) begin
        assert (!f_memory_pending_q[o_mem_req_id]);
        f_memory_pending_q[o_mem_req_id] <= 1'b1;
      end
      if (i_mem_resp_valid) begin
        assume (f_memory_pending_q[i_mem_resp_id]);
        f_memory_pending_q[i_mem_resp_id] <= 1'b0;
      end
      for (int id = 0; id < 32; id++) begin
        if (id < FILLS) begin
          if (f_memory_pending_q[id])
            assert (fill_phase_q[id] != FillFree && fill_sent_q[id] && !fill_done_q[id]);
        end else if (id >= 16 && id < 16 + NUM_WB) begin
          if (f_memory_pending_q[id])
            assert (wb_valid_q[id-16] && wb_sent_q[id-16] && wb_frozen_q[id-16]);
        end else assert (!f_memory_pending_q[id]);
      end
    end
    if (!i_rst) begin
      assert ((wb_frozen_q & ~wb_valid_q) == 0);
      assert ((wb_sent_q & ~wb_frozen_q) == 0);
      assert ((fill_done_q & ~fill_sent_q) == 0);
`ifdef COHERENCE_HOME_CONTROL
      assert ((fill_read_done_q & ~fill_read_sent_q) == 0);
`endif
      if (o_mem_req_valid) assert (o_mem_req_write == o_mem_req_id[4]);
      if (o_mem_req_valid && o_mem_req_write) begin
        assert (int'(o_mem_req_id[3:0]) < NUM_WB);
        assert (wb_valid_q[WbBits'(o_mem_req_id)] && wb_frozen_q[WbBits'(o_mem_req_id)] &&
            !wb_sent_q[WbBits'(o_mem_req_id)]);
      end
      if (o_mem_req_valid && !o_mem_req_write) begin
        assert (int'(o_mem_req_id) < FILLS);
        assert (fill_phase_q[FillBits'(o_mem_req_id)] != FillFree &&
            !fill_sent_q[FillBits'(o_mem_req_id)] && !fill_done_q[FillBits'(o_mem_req_id)]);
      end
      for (int fill = 0; fill < FILLS; fill++) begin
        if (fill_phase_q[fill] == FillInstall || fill_phase_q[fill] == FillInstallWait ||
            fill_phase_q[fill] == FillReady)
          assert (fill_sent_q[fill] && fill_done_q[fill] && !fill_error_q[fill]);
        if (fill_phase_q[fill] == FillRecall || fill_phase_q[fill] == FillDetach ||
            fill_phase_q[fill] == FillFatal) begin
          assert (wb_valid_q[fill_wb_q[fill]] && !wb_frozen_q[fill_wb_q[fill]]);
          for (int other = fill + 1; other < FILLS; other++)
          if (fill_phase_q[other] == FillRecall || fill_phase_q[other] == FillDetach ||
              fill_phase_q[other] == FillFatal)
            assert (fill_wb_q[fill] != fill_wb_q[other]);
        end
      end
    end
    if (!i_rst) begin
`ifndef COHERENCE_HOME_WB_PROOF
      if (pin_valid) assert (array_hit && !decision_blocked);
      if (array_claim && !array_hit) assert (!array_exclude[array_way]);
      if (retry_valid) assert (!pin_valid);
      if (result_valid && active && result_ready) assert (int'(result.tid) < COMPLETIONS);
      for (int engine = 0; engine < RESULTS; engine++) begin
        assert (int'(engine_tid[engine]) < COMPLETIONS);
        for (int other = engine + 1; other < RESULTS; other++)
        if (!engine_idle[engine] && !engine_idle[other])
          assert (engine_tid[engine] != engine_tid[other]);
      end
      for (int fill = 0; fill < FILLS; fill++) begin
        if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady)
          assert (fill_seats_q[fill] != 0);
        for (int slot = 0; slot < COMPLETIONS; slot++)
        if (fill_phase_q[fill] != FillFree && fill_seats_q[fill][slot])
          assert (same_block(fill_addr_q[fill], waiting_addr[slot]));
        for (int other = fill + 1; other < FILLS; other++)
        if (fill_phase_q[fill] != FillFree && fill_phase_q[other] != FillFree)
          assert ((fill_seats_q[fill] & fill_seats_q[other]) == 0);
        if (fill_wake[fill]) assert (fill_seats_q[fill] != 0);
        if (fill_phase_q[fill] == FillReady) assert (fill_add_seats[fill] == 0);
      end
      assert (o_perf_events.access == (o_perf_events.hit || o_perf_events.miss));
      assert (!(o_perf_events.hit && o_perf_events.miss));
      assert (o_perf_events.miss_outstanding <= FILLS);
      assert (o_write_perf_events.write_fill_outstanding <= o_perf_events.miss_outstanding);
`endif
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
`ifdef COHERENCE_HOME_CONTROL
      if ($past(f_local_fatal)) assert (o_fatal);
`endif
      for (int wb = 0; wb < NUM_WB; wb++) begin
        if ($past(
                wb_frozen_q[wb]
            ) && !$past(
                i_mem_resp_valid && i_mem_resp_id == 5'(16 + wb) && !i_mem_resp_error
            )) begin
          assert (wb_valid_q[wb] && wb_frozen_q[wb]);
          assert (wb_addr_q[wb] == $past(wb_addr_q[wb]));
`ifndef COHERENCE_HOME_CONTROL
          assert (wb_data_q[wb][8*f_byte+:8] == $past(wb_data_q[wb][8*f_byte+:8]));
`endif
        end
      end
      if ($past(o_mem_req_valid && !i_mem_req_ready)) begin
        assert (o_mem_req_valid);
        assert ({o_mem_req_write, o_mem_req_addr, o_mem_req_id, o_mem_req_mask} == $past(
            {o_mem_req_write, o_mem_req_addr, o_mem_req_id, o_mem_req_mask}
        ));
`ifndef COHERENCE_HOME_CONTROL
        assert (o_mem_req_data == $past(o_mem_req_data));
`endif
      end
    end
`ifdef COHERENCE_HOME_COVER
    if (!i_rst) begin
`ifdef COHERENCE_HOME_COVER_ERROR
      cover (o_fatal && |wb_sent_q && &f_seen_q);
`else
      cover (&f_seen_q && f_past_valid && $past(!i_rst && wb_sent_q[0] && i_mem_resp_valid &&
                                                i_mem_resp_id == 16 && !i_mem_resp_error) &&
             !wb_valid_q[0]);
`endif
    end
`endif
  end
`endif

endmodule
