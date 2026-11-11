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
    parameter int unsigned COMPLETIONS = coherence_pkg::completion_count(1),
    parameter int unsigned RESULTS = 8,
    parameter int unsigned FILLS = 8,
    // Fills a prefetch leaves free for demand misses: a prefetch allocates a
    // fill only while more than PREFETCH_RESERVE fills are free.
    parameter int unsigned PREFETCH_RESERVE = FILLS / 4,
    // Completion slots kept for prefetch requests (coherence_home_completions
    // PREFETCH_SLOTS); zero shares every slot.
    parameter int unsigned PREFETCH_SLOTS = coherence_pkg::PrefetchIds,
    parameter bit ULTRA = 1'b1,
    parameter int unsigned SIM_FAST_MAINT = 0,
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
    // Registered: more than PREFETCH_RESERVE fills were free on the cycle
    // before, so a prefetch could allocate one. A prefetcher can hold back
    // requests while it is clear.
    output logic o_prefetch_room,
    // A registered copy of D acceptance: a strobe on the cycle after it, with
    // the accepted request's opcode, identity and address.
    output logic o_accepted,
    output logic [3:0] o_accepted_opcode,
    output logic [8:0] o_accepted_q,
    output logic [ADDR_WIDTH-1:0] o_accepted_addr,
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
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS);
  localparam int unsigned SetBits = $clog2(Sets);
  localparam int unsigned CompletionBits = COMPLETIONS > 1 ? $clog2(COMPLETIONS) : 1;
  localparam int unsigned ResultBits = RESULTS > 1 ? $clog2(RESULTS) : 1;
  // The completion table's result buffers: the engines' and the forward
  // buffer, index RESULTS.
  localparam int unsigned BufferBits = $clog2(RESULTS + 1);
  localparam int unsigned FillBits = FILLS > 1 ? $clog2(FILLS) : 1;
  localparam int unsigned Puts = 2;
  localparam int unsigned Clients = RESULTS + FILLS + Puts;
  localparam int unsigned TokenBits = $clog2(Clients);
  localparam int unsigned TagPacketBits = TokenBits + ADDR_WIDTH;
  localparam int unsigned ReadPacketBits = TagPacketBits + WayBits;
  localparam int unsigned UpdatePacketBits = ReadPacketBits + 4 + 9 * LINE_BYTES;
  localparam int unsigned TagBits = ADDR_WIDTH - SetBits - OffsetBits;
  localparam logic [5:0] FillTid = 6'(coherence_pkg::fill_base(1));
  localparam logic [5:0] PutTid = 6'(coherence_pkg::put_base(1, FILLS));
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
    logic has_data;  // |mask, formed before the update arbiter registers it
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
  // The fill phase keeps its next-state logic on the D input; mapping part
  // of it onto the flops' reset pin lengthened the tag-to-phase path.
  (* extract_reset = "no" *) fill_phase_t fill_phase_q[FILLS];
  // Registered phase flags for the tag decision. They change only where their
  // decoded phase value changes, so the decision reads one flop per owner and
  // the flags' inputs stay shallow.
  logic [FILLS-1:0] fill_live_q, fill_blocking_q;
  logic [Puts-1:0] put_busy_q;
  recall_phase_t recall_phase_q[FILLS];
  put_phase_t put_phase_q[Puts];
  (* max_fanout = 64 *) logic run;
  logic fatal_event, work_valid, work_error;
  coh_d_t work;
  logic [5:0] work_tid;
  logic [ResultBits-1:0] work_buffer;
  logic [BufferBits-1:0] image_index;
  logic [RESULTS:0] image_select;
  logic [255:0] image_data;
  logic [COMPLETIONS-1:0] waiting, park, wake, wake_error;
  logic [COMPLETIONS-1:0][ADDR_WIDTH+311:0] waiting_request;
  logic [COMPLETIONS-1:0][ADDR_WIDTH-1:0] waiting_addr;
  logic [COMPLETIONS-1:0][3:0] waiting_opcode;
  logic retry_valid, retry_park, pin_valid;
  logic [5:0] decision_tid;
  logic [WAYS-1:0] completion_exclude, array_exclude;
  logic [WAYS-1:0] streaming_exclude;
  (* keep = "true" *) logic [WAYS-1:0] owner_exclude;
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
  logic [RESULTS-1:0] engine_non_alloc;
  logic work_counted;
  logic [RESULTS-1:0][WayBits-1:0] engine_way;
  logic [RESULTS-1:0][255:0] engine_image;
  logic [RESULTS-1:0][ADDR_WIDTH+274:0] engine_result_payload;
  logic [RESULTS-1:0][LINE_BYTES-1:0] engine_update_mask;
  logic [RESULTS-1:0][8*LINE_BYTES-1:0] engine_update_data;
  logic [Clients-1:0] tag_valid, tag_ready, read_valid, read_ready;
  logic [Clients-1:0] update_valid, update_ready, probe_valid, probe_ready;
  // The update arbiter's selected client, whose acceptance waits only on the
  // array's readiness.
  logic [Clients-1:0] update_selected;
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
  logic probe_out_valid, ack_out_valid, result_valid, result_ready;
  logic [ADDR_WIDTH+29:0] probe_out;
  logic [ADDR_WIDTH+10:0] ack_out;
  coh_g_t result;
  logic array_response, array_hit, array_available, array_claim;
  logic [TokenBits-1:0] array_token, array_data_token, array_updated_token, array_query_token;
  logic [(1 << TokenBits)-1:0] array_token_onehot;
  logic [ADDR_WIDTH-1:0] array_query, array_addr;
  logic [WayBits-1:0] array_way;
  logic [WAYS-1:0][TagBits-1:0] array_tags;
  logic [ADDR_WIDTH-1:0] held_put_next, work_addr;
  logic [NUM_WB-1:0] wb_block_q, wb_set_q;
  (* keep = "true" *) logic [NUM_WB-1:0] wb_blocks, wb_victims;
  logic [NUM_WB-1:0][WAYS-1:0] wb_tag_q;
  logic [FILLS-1:0] fill_block_q, fill_old_block_q, fill_set_q;
  (* keep = "true" *) logic [FILLS-1:0] fill_blocks, fill_victims;
  logic [Puts-1:0] put_sector_q, put_set_q, put_accepted_q;
  (* keep = "true" *) logic [Puts-1:0] put_blocks, put_victims;
  logic [Puts-1:0][WAYS-1:0] put_tag_q;
  logic held_put_sector_q, held_put_set_q;
  logic [WAYS-1:0] held_put_tag_q;
  logic [RESULTS-1:0] engine_set_q, engine_accepted_q;
  (* keep = "true" *) logic [RESULTS-1:0] engine_victims;
  logic [RESULTS-1:0][WAYS-1:0] engine_tag_q;
  logic work_set_q;
  logic [WAYS-1:0] work_tag_q;
  logic put_query_q, put_victim_q, put_owner_q, fill_allocated_q, victim_allocated_q;
  logic [1:0] array_state;
  logic array_data_valid, array_updated;
  logic [8*LINE_BYTES-1:0] array_data;
  logic decision_engine, decision_put;
  (* keep = "true" *) logic decision_blocked, victim_blocked;
  logic decision_hit, decision_join, decision_retry;
  (* keep = "true" *) logic decision_fill;
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
  // A zero allocation clears the image as data; it is not a reset event.
  (* extract_reset = "no" *) logic [FILLS-1:0][8*LINE_BYTES-1:0] fill_image_q;
  logic [FILLS-1:0] fill_victim_q, fill_sent_q, fill_done_q, fill_error_q;
  // A successful fill has woken its waiters. Set on the first FillInstallWait
  // cycle and cleared on allocation.
  logic [FILLS-1:0] fill_woken_q;
  logic [FILLS-1:0] fill_read_sent_q, fill_read_done_q, fill_sector_q;
  logic [FILLS-1:0] fill_dirty_q, fill_r_ready, fill_prefetch_q;
  // Prefetch decisions. The tag port serves one lookup at a time, so flags
  // captured with a lookup's token when the port accepts it belong to the
  // decision in progress: lookup_prefetch_q, the lookup is a prefetch's;
  // lookup_fill_q, that prefetch may allocate a fill (no non-prefetch
  // request for its block was live before its dispatch). Only decisions
  // allocate fills and write-back slots, and none falls between a lookup's
  // acceptance and its response, so the room flags registered from the
  // live flags are exact at the decision but for slots freed meanwhile.
  logic lookup_prefetch_q, lookup_fill_q, prefetch_fill_q, prefetch_room_q, wb_two_free_q;
  logic [RESULTS-1:0] engine_prefetch_q, engine_nofill_q;
  logic work_nofill, array_two_available;
  logic [FILLS-1:0][LINE_BYTES/32-1:0] fill_dirty_sectors_q;
  logic [COMPLETIONS-1:0] fill_seats_q[FILLS], fill_add_seats[FILLS];
  logic [1:0] fill_seat_count_q[FILLS], fill_add_count[FILLS];
  // Forwarding a fill's line to its primary request. fill_primary_q[fill] is
  // the primary's seat while it waits for its forward: a GetS, LoadReserved
  // or GetM whose decision allocated the fill, which needs no probe or update
  // to be granted. fill_primary_upper_q is its sector of a 64-byte line.
  // fill_forward_q marks a fill whose primary may take the forward: it holds
  // its line, and its victim handling has let the install begin.
  logic [COMPLETIONS-1:0] fill_primary_q[FILLS];
  logic [FILLS-1:0] fill_primary_upper_q, fill_forward_q;
  // The primary's G without data, recorded at allocation: its q, its tid
  // and whether it is a GetM, so a forward reads only fill registers.
  logic [8:0] fill_primary_ident_q[FILLS];
  logic [5:0] fill_primary_tid_q[FILLS];
  logic [FILLS-1:0] fill_primary_getm_q;
  // A zero fill serves a GetMZero miss: its image starts as zeros with its
  // memory read done, so it reads no memory, and it installs Modified, since
  // only the L2 holds the zeros of the sector its primary does not own.
  logic [FILLS-1:0] fill_zero_q, fill_zero_alloc;
  // The forward on offer: a fill that may forward, its primary's slot, its
  // way and the sector. forward_data_q holds the accepted forward's sector
  // until the forward buffer's G.
  logic forward_valid, forward_ready, forward_accept;
  logic [FILLS-1:0] forward_pick, forward_pick_q, forward_later_q;
  // fill_forward_set[fill]: the fill enters FillInstall with a primary on
  // this edge, so it may forward from the next cycle. Both of its uses apply
  // it only while the home runs.
  logic [FILLS-1:0] fill_forward_set;
  logic [COMPLETIONS-1:0] forward_slots;
  logic [WayBits-1:0] forward_way;
  coh_g_t forward_result;
  logic [255:0] forward_data, forward_data_q;
  logic [FILLS-1:0] fill_wake;
  logic [FILLS-1:0][ADDR_WIDTH+29:0] fill_probe;
  // Held packets are stored as plain vectors and read through typed views.
  logic [ADDR_WIDTH+10:0] fill_ack_q[FILLS];
  logic [NUM_WB-1:0] wb_valid_q, wb_frozen_q, wb_sent_q;
  logic [ADDR_WIDTH-1:0] wb_addr_q[NUM_WB];
  logic [8*LINE_BYTES-1:0] wb_data_q[NUM_WB];
  logic [ADDR_WIDTH+259:0] put_q[Puts];
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
  logic f_local_fatal, f_query_held;
  logic [COMPLETIONS-1:0] f_fill_waiting, f_fill_seated, f_fill_primary;
  always_comb begin
    f_fill_waiting = '0;
    f_fill_seated  = '0;
    f_fill_primary = '0;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree) f_fill_primary |= fill_primary_q[fill];
    f_local_fatal = |engine_fatal;
    f_tag_address = '0;
    for (int engine = 0; engine < RESULTS; engine++) f_tag_address[engine] = engine_addr[engine];
    for (int put = 0; put < Puts; put++) f_tag_address[RESULTS+FILLS+put] = put_addr[put];
    for (int fill = 0; fill < FILLS; fill++) f_local_fatal |= fill_phase_q[fill] == FillFatal;
    for (int put = 0; put < Puts; put++) f_local_fatal |= put_phase_q[put] == PutFatal;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady &&
        !(fill_phase_q[fill] == FillInstallWait && fill_woken_q[fill]))
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
  function automatic logic [8:0] request_q(input coh_d_t packet);
    request_q = packet.q;
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
  function automatic logic [TagBits-1:0] block_tag(input logic [ADDR_WIDTH-1:0] addr);
    block_tag = addr[ADDR_WIDTH-1:OffsetBits+SetBits];
  endfunction
  function automatic logic read_waiter(input logic [3:0] opcode);
    read_waiter = opcode == coherence_pkg::GetS || opcode == coherence_pkg::LoadReserved ||
        opcode == coherence_pkg::ReadOnceIF || opcode == coherence_pkg::ReadOncePTW ||
        opcode == coherence_pkg::DMARead;
  endfunction
  // Reset clears the home at its flops. A stop reaches internal work and
  // outputs through this flop, so no selection or payload path starts at the
  // fatal logic. A home failure stops the home on the edge that sets o_fatal.
  // The fatal stop input stays set until reset and takes effect on the cycle
  // after it rises.
  always_comb begin
    fatal_event = work_valid && work_error && coherence_pkg::is_getm(work.opcode);
    if (i_mem_resp_valid && i_mem_resp_id[4] && i_mem_resp_error) fatal_event = 1'b1;
    for (int engine = 0; engine < RESULTS; engine++) if (engine_fatal[engine]) fatal_event = 1'b1;
    for (int put = 0; put < Puts; put++) if (put_phase_q[put] == PutFatal) fatal_event = 1'b1;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] == FillFatal) fatal_event = 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) run <= 1'b1;
    else run <= !i_fatal_stop && !o_fatal && !fatal_event;
  end
  assign incoming_put = i_w;
  assign reply = i_r;
  always_comb begin
    image_data = {256{image_select[RESULTS]}} & forward_data_q;
    for (int engine = 0; engine < RESULTS; engine++)
    image_data |= {256{image_select[engine]}} & engine_image[engine];
  end
  coherence_home_completions #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .SLOTS(COMPLETIONS),
      .RESULT_SLOTS(RESULTS),
      .PREFETCH_SLOTS(PREFETCH_SLOTS)
  ) completions (
      .i_clk,
      .i_rst,
      .i_fatal_stop(!run),
      .i_d_valid,
      .o_d_ready,
      .i_d,
      .o_work_valid(work_valid),
      .i_work_ready(run),
      .o_work(work),
      .o_work_tid(work_tid),
      .o_work_buffer(work_buffer),
      .o_work_error(work_error),
      .o_work_counted(work_counted),
      .o_work_nofill(work_nofill),
      .o_accepted,
      .o_accepted_opcode,
      .o_accepted_q,
      .o_accepted_addr,
      .i_count_valid(run && array_response && decision_engine),
      .i_count_tid(decision_tid),
      .o_waiting(waiting),
      .o_waiting_request(waiting_request),
      .i_park(park),
      .i_wake(wake),
      .i_wake_error(wake_error),
      .i_retry_park(retry_park),
      .o_image_index(image_index),
      .o_image_select(image_select),
      .i_image_data(image_data),
      .i_forward_valid(forward_valid),
      .o_forward_ready(forward_ready),
      .i_forward_slots(forward_slots),
      .i_forward_way(forward_way),
      .i_forward(forward_result),
      .i_retry_valid(retry_valid),
      .i_retry_tid(decision_tid),
      .i_pin_valid(pin_valid),
      .i_pin_tid(decision_tid),
      .i_pin_way(array_way),
      .i_query_addr(array_query),
      .o_exclude(completion_exclude),
      .i_next_put_addr(held_put_next),
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
      .i_fill_primary(f_fill_primary),
      .i_engine_busy(~engine_idle),
      .i_engine_unpinned(f_engine_unpinned),
      .i_engine_pinned(f_engine_pinned),
      .i_engine_initial_error(f_engine_initial_error),
      .i_engine_tid(engine_tid),
      .i_engine_addr(engine_addr),
      .i_query_held(f_query_held),
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
        .i_work_valid(work_valid && work_buffer == ResultBits'(engine)),
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
        .o_non_alloc(engine_non_alloc[engine]),
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
    // The engine's work is a prefetch, and that prefetch may not allocate a
    // fill: registered with the work, so the tag decision and the victim
    // terms read one flop per engine.
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        engine_counted_q[engine]  <= 1'b0;
        engine_prefetch_q[engine] <= 1'b0;
        engine_nofill_q[engine]   <= 1'b0;
      end else if (work_valid && work_buffer == ResultBits'(engine)) begin
        engine_counted_q[engine]  <= work_counted;
        engine_prefetch_q[engine] <= work.opcode == coherence_pkg::Prefetch;
        engine_nofill_q[engine]   <= work_nofill;
      end
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
      |engine_update_mask[engine],
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
      .o_selected(),
      .i_ready(result_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run),
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
      .o_selected(),
      .i_ready(tag_request_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run),
`endif
      .o_payload(tag_request)
  );
  coherence_d_arbiter #(
      .WIDTH(ReadPacketBits),
      .PORTS(Clients)
  ) read_arbiter (
      .i_clk,
      // A stop clears this arbiter at run time, as a reset does.
      .i_rst(i_rst || !run),
      .i_valid(read_valid),
      .o_ready(read_ready),
      .i_payload(read_payload),
      .o_valid(row_request_valid),
      .o_selected(),
      .i_ready(row_request_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run || f_local_fatal),
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
      .o_selected(update_selected),
      .i_ready(update_request_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run),
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
      .o_selected(),
      .i_ready(i_p_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run),
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
      .o_selected(),
      .i_ready(i_wa_ready && run),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(!run),
`endif
      .o_payload(ack_out)
  );
  assign o_p_valid = run && probe_out_valid;
  assign o_p = probe_out;
  assign o_r_ready = run && (|engine_r_ready || |fill_r_ready);
  assign o_wa_valid = run && ack_out_valid;
  assign o_wa = ack_out;

  coherence_home_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .TOKEN_BITS(TokenBits),
      .ULTRA(ULTRA),
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
  ) array (
      .i_clk,
      .i_rst,
      .o_init_done(),
      .i_req_valid(tag_request_valid && run),
      .o_req_ready(tag_request_ready),
      .i_req_addr(tag_request.addr),
      .i_req_token(tag_request.token),
      .o_query_addr(array_query),
      .o_query_token(array_query_token),
      .i_exclude(array_exclude),
      .o_resp_valid(array_response),
      .i_resp_ready(run),
      .i_resp_claim(array_claim),
      .o_resp_token(array_token),
      .o_resp_token_onehot(array_token_onehot),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_two_available(array_two_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .o_resp_tags(array_tags),
      .i_read_valid(row_request_valid && run),
      .i_read_offer(row_request_valid),
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
      .i_update_has_data(update_request.has_data),
      .i_update_mask(update_request.mask),
      .i_update_data(update_request.data),
      .i_update_token(update_request.token),
      .o_updated(array_updated),
`ifdef COHERENCE_HOME_CONTROL
      .i_tag_owner(f_tag_owner),
      .i_tag_address(f_tag_address),
      .i_read_owner(f_read_owner),
      .i_update_owner(f_update_owner),
      .o_query_held(f_query_held),
`endif
      .o_updated_token(array_updated_token)
  );

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      lookup_prefetch_q <= 1'b0;
      lookup_fill_q <= 1'b0;
      prefetch_fill_q <= 1'b0;
      prefetch_room_q <= 1'b0;
      wb_two_free_q <= 1'b0;
    end else begin
      if (tag_request_valid && run && tag_request_ready) begin
        lookup_prefetch_q <= int'(tag_request.token) < RESULTS &&
            engine_prefetch_q[ResultBits'(tag_request.token)];
        lookup_fill_q <= int'(tag_request.token) < RESULTS &&
            engine_prefetch_q[ResultBits'(tag_request.token)] &&
            !engine_nofill_q[ResultBits'(tag_request.token)];
      end
      prefetch_room_q <= $countones(~fill_live_q) > PREFETCH_RESERVE;
      prefetch_fill_q <= lookup_fill_q && $countones(~fill_live_q) > PREFETCH_RESERVE;
      wb_two_free_q   <= $countones(~wb_valid_q) >= 2;
    end
  end
  assign o_prefetch_room = prefetch_room_q;
  // Way exclusion uses the registered set comparisons below. The array reads
  // it in selection and response cycles, when the query has held since the
  // edge before, and no fill is allocated and no put accepted on that edge
  // for an owner that excludes a way.
  always_comb begin
    owner_exclude = '0;
    for (int fill = 0; fill < FILLS; fill++) begin
      if (fill_phase_q[fill] != FillFree && fill_set_q[fill])
        owner_exclude[fill_way_q[fill]] = 1'b1;
    end
    for (int put = 0; put < Puts; put++) begin
      if ((put_phase_q[put] == PutUpdate || put_phase_q[put] == PutUpdateWait ||
          put_phase_q[put] == PutAck) && put_set_q[put])
        owner_exclude[put_way_q[put]] = 1'b1;
    end
    streaming_exclude = '0;
    if (int'(array_query_token) < RESULTS && engine_non_alloc[ResultBits'(array_query_token)]) begin
      streaming_exclude = ~(WAYS'(1));
    end
  end
  assign array_exclude = completion_exclude | owner_exclude | streaming_exclude;
  // The response-cycle decision compares the query block and the victim block
  // with every owner's address. Those comparisons are registered from the
  // cycle before: a response follows the selection cycle, and the query, the
  // way tags and the write-back and fill addresses hold from selection
  // through the response. A put or an engine can take a new address on the
  // cycle before a response, so the comparisons with the arriving address
  // and the acceptance itself are registered as well.
  always_ff @(posedge i_clk) begin
    for (int wb = 0; wb < NUM_WB; wb++) begin
      wb_block_q[wb] <= same_block(wb_addr_q[wb], array_query);
      wb_set_q[wb]   <= same_set(wb_addr_q[wb], array_query);
      for (int way = 0; way < WAYS; way++)
      wb_tag_q[wb][way] <= block_tag(wb_addr_q[wb]) == array_tags[way];
    end
    for (int fill = 0; fill < FILLS; fill++) begin
      fill_block_q[fill] <= same_block(fill_addr_q[fill], array_query);
      fill_old_block_q[fill] <= same_block(fill_old_addr_q[fill], array_query);
      fill_set_q[fill] <= same_set(fill_addr_q[fill], array_query);
    end
    for (int put = 0; put < Puts; put++) begin
      put_sector_q[put] <= same_sector(put_addr[put], decision_addr);
      put_set_q[put] <= same_set(put_addr[put], array_query);
      for (int way = 0; way < WAYS; way++)
      put_tag_q[put][way] <= block_tag(put_addr[put]) == array_tags[way];
      put_accepted_q[put] <= i_w_valid && o_w_ready && incoming_put.put_id == 1'(put);
    end
    held_put_sector_q <= same_sector(held_put_next, decision_addr);
    held_put_set_q <= same_set(held_put_next, array_query);
    for (int way = 0; way < WAYS; way++)
    held_put_tag_q[way] <= block_tag(held_put_next) == array_tags[way];
    for (int engine = 0; engine < RESULTS; engine++) begin
      engine_set_q[engine] <= same_set(engine_addr[engine], array_query);
      for (int way = 0; way < WAYS; way++)
      engine_tag_q[engine][way] <= block_tag(engine_addr[engine]) == array_tags[way];
      engine_accepted_q[engine] <= run && work_valid && work_buffer == ResultBits'(engine);
    end
    work_set_q <= same_set(work_addr, array_query);
    for (int way = 0; way < WAYS; way++) work_tag_q[way] <= block_tag(work_addr) == array_tags[way];
  end
  // The selected put's address on the next cycle, and the selected work's.
  // An idle selection takes the incoming W's address whether or not W is
  // valid: a W that is not valid leaves no put selected on the next cycle,
  // and every use of these comparisons waits for a selected or accepted put.
  // The put selection does not wait for the stop condition either: W
  // readiness already requires the home to be active.
  assign held_put_next = put_selected_q ? selected_put_q.addr : incoming_put.addr;
  assign work_addr = request_addr(work);
  // One blocking term per owner: blocks a same-sector query, victims a
  // victim block that the owner holds. The decision and the W readiness that
  // follows it are built from kept nodes, each a function of at most six kept
  // signals or registers. Each node is one LUT and every reduction is a tree,
  // so their depth does not depend on how synthesis treats nearby logic:
  //   1. way selects of the registered tag compares, owner phase decodes;
  //   2. one blocking and one victim term per owner;
  //   3. reduction nodes of at most six terms and the fill precondition;
  //   4. decision_blocked and victim_blocked;
  //   5. the decisions and the W readiness.
  (* keep = "true" *) logic work_tag_sel, held_put_tag_sel;
  (* keep = "true" *) logic [RESULTS-1:0] engine_tag_sel, engine_other;
  (* keep = "true" *) logic [NUM_WB-1:0] wb_tag_sel;
  (* keep = "true" *) logic [Puts-1:0] put_tag_sel, put_live;
  (* keep = "true" *) logic [FILLS-1:0] fill_live, fill_blocking, fill_way_match;
  (* keep = "true" *) logic decision_from_engine, wb_free_any, fill_free_any, state_allows_fill;
  (* keep = "true" *) logic fill_pre;
  assign work_tag_sel = work_tag_q[array_way];
  assign held_put_tag_sel = held_put_tag_q[array_way];
  for (genvar wb = 0; wb < NUM_WB; wb++) begin : gen_wb_terms
    assign wb_tag_sel[wb] = wb_tag_q[wb][array_way];
    assign wb_blocks[wb]  = wb_valid_q[wb] && wb_block_q[wb];
    assign wb_victims[wb] = wb_valid_q[wb] && wb_set_q[wb] && wb_tag_sel[wb];
  end
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill_terms
    assign fill_live[fill] = fill_live_q[fill];
    assign fill_blocking[fill] = fill_blocking_q[fill];
    assign fill_way_match[fill] = fill_way_q[fill] == array_way;
    assign fill_victims[fill] = fill_live[fill] && fill_set_q[fill] && fill_way_match[fill];
    assign fill_blocks[fill] = fill_blocking[fill] &&
        (fill_block_q[fill] || (fill_victim_q[fill] && fill_old_block_q[fill]));
  end
  for (genvar put = 0; put < Puts; put++) begin : gen_put_terms
    assign put_tag_sel[put] = put_tag_q[put][array_way];
    assign put_live[put] = put_busy_q[put] && !array_token_onehot[RESULTS+FILLS+put];
    assign put_blocks[put] = put_live[put] &&
        (put_accepted_q[put] ? held_put_sector_q : put_sector_q[put]);
    assign put_victims[put] = put_live[put] && (put_accepted_q[put] ?
        held_put_set_q && held_put_tag_sel : put_set_q[put] && put_tag_sel[put]);
  end
  for (genvar engine = 0; engine < RESULTS; engine++) begin : gen_engine_terms
    assign engine_tag_sel[engine] = engine_tag_q[engine][array_way];
    // A prefetch never touches the array after its decision, so its engine
    // protects no victim.
    assign engine_other[engine] = !engine_idle[engine] && !array_token_onehot[engine] &&
        !engine_prefetch_q[engine];
    assign engine_victims[engine] = engine_other[engine] && (engine_accepted_q[engine] ?
        work_set_q && work_tag_sel : engine_set_q[engine] && engine_tag_sel[engine]);
  end
  // Reduction nodes of at most six terms each.
  localparam int unsigned OwnerTerms  = NUM_WB + FILLS + Puts;
  localparam int unsigned OwnerNodes  = (OwnerTerms + 5) / 6;
  localparam int unsigned EngineNodes = (RESULTS + 5) / 6;
  wire [OwnerTerms-1:0] owner_blocks = {wb_blocks, fill_blocks, put_blocks};
  wire [OwnerTerms-1:0] owner_victims = {wb_victims, fill_victims, put_victims};
  (* keep = "true" *) logic [OwnerNodes-1:0] block_nodes, victim_nodes;
  (* keep = "true" *) logic [EngineNodes-1:0] engine_victim_nodes;
  for (genvar node = 0; node < OwnerNodes; node++) begin : gen_owner_nodes
    localparam int unsigned Bits = OwnerTerms - 6 * node < 6 ? OwnerTerms - 6 * node : 6;
    assign block_nodes[node]  = |owner_blocks[6*node+:Bits];
    assign victim_nodes[node] = |owner_victims[6*node+:Bits];
  end
  for (genvar node = 0; node < EngineNodes; node++) begin : gen_engine_nodes
    localparam int unsigned Bits = RESULTS - 6 * node < 6 ? RESULTS - 6 * node : 6;
    assign engine_victim_nodes[node] = |engine_victims[6*node+:Bits];
  end
  assign decision_blocked = |block_nodes;
  assign victim_blocked = |victim_nodes ||
      (array_state != coherence_pkg::Invalid && |engine_victim_nodes);
  // The fill precondition: an engine's miss with a fill and, for a valid
  // victim, a write-back slot available.
  assign decision_from_engine = int'(array_token) < RESULTS;
  always_comb begin
    wb_free_any = 1'b0;
    for (int wb = 0; wb < NUM_WB; wb++) wb_free_any |= !wb_valid_q[wb] && !wb_frozen_q[wb];
  end
  assign fill_free_any = !(&fill_live);
  assign state_allows_fill = array_state == coherence_pkg::Invalid || wb_free_any;
  // A prefetch allocates only while more than PREFETCH_RESERVE fills are
  // free, two ways of the set were available and, for a valid victim, two
  // write-back slots are free, and only if it may fill at all: it never
  // takes a reserved fill, the last available way or the last write-back
  // slot.
  (* keep = "true" *) logic prefetch_fill_ok;
  assign prefetch_fill_ok = !lookup_prefetch_q || (prefetch_fill_q && array_two_available &&
      (array_state == coherence_pkg::Invalid || wb_two_free_q));
  assign fill_pre = decision_from_engine && !array_hit && array_available && fill_free_any &&
      state_allows_fill && prefetch_fill_ok;
  // The registered phase flags and the one-hot response token match their
  // encodings outside reset. Every formal task checks this, including those
  // read with SYNTHESIS defined, which makes the checks inductive; simulation
  // checks them once a reset has been seen.
`ifdef FORMAL
  `define HOME_DECISION_CHECKS
  wire decision_reset_seen = !i_rst;
`elsif SYNTHESIS
`else
  `define HOME_DECISION_CHECKS
  logic decision_reset_seen = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) decision_reset_seen <= 1'b1;
`endif
`ifdef HOME_DECISION_CHECKS
  always_comb
    if (decision_reset_seen) begin
      assert (fill_pre == (decision_engine && !array_hit && array_available && fill_free &&
          (array_state == coherence_pkg::Invalid || wb_free) && (!lookup_prefetch_q ||
          (prefetch_fill_q && array_two_available &&
           (array_state == coherence_pkg::Invalid || wb_two_free_q)))));
      for (int token = 0; token < (1 << TokenBits); token++)
      assert (array_token_onehot[token] == (int'(array_token) == token));
      for (int fill = 0; fill < FILLS; fill++) begin
        assert (fill_live_q[fill] == (fill_phase_q[fill] != FillFree));
        assert (fill_blocking_q[fill] ==
            (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady));
      end
      for (int put = 0; put < Puts; put++)
      assert (put_busy_q[put] == (put_phase_q[put] != PutFree));
      if (update_request_valid) assert (update_request.has_data == |update_request.mask);
    end
  `undef HOME_DECISION_CHECKS
`endif
  // The deciding request's identity, recorded with a primary's fill.
  logic [8:0] decision_q;
  always_comb begin
    decision_q = '0;
    for (int slot = 0; slot < COMPLETIONS; slot++)
    if (decision_tid == 6'(slot)) decision_q = request_q(waiting_request[slot]);
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
    fill_free = 1'b0;
    fill_free_index = '0;
    wb_free = 1'b0;
    wb_free_index = '0;
    for (int wb = NUM_WB - 1; wb >= 0; wb--) begin
      if (!wb_valid_q[wb] && !wb_frozen_q[wb]) begin
        wb_free = 1'b1;
        wb_free_index = WbBits'(wb);
      end
    end
    for (int fill = FILLS - 1; fill >= 0; fill--) begin
      if (fill_phase_q[fill] == FillFree) begin
        fill_free = 1'b1;
        fill_free_index = FillBits'(fill);
      end
    end
    decision_hit = array_hit && array_available && !decision_blocked;
    decision_fill = fill_pre && !decision_blocked && !victim_blocked;
    decision_join = |join_fill;
    decision_retry = decision_engine && !decision_hit && !lookup_prefetch_q;
    array_claim = run && array_response && (decision_hit || decision_fill);
    retry_valid = run && array_response && decision_retry;
    retry_park = decision_fill || decision_join;
    pin_valid = run && array_response && decision_engine && decision_hit && !lookup_prefetch_q;
  end

  // Parked readers own metadata seats, including readers with predecessors.
  // A demand fill's primary owns the first; a forward gives it up.
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_seats
    logic [COMPLETIONS-1:0] eligible;
    logic enabled, joining;
    assign enabled = run && fill_phase_q[fill] != FillFree &&
        fill_phase_q[fill] != FillReady && fill_phase_q[fill] != FillInstallWait &&
        !fill_error_q[fill];
    assign join_fill[fill] = array_response && fill_phase_q[fill] != FillFree &&
        fill_phase_q[fill] != FillReady && fill_phase_q[fill] != FillInstallWait &&
        !fill_error_q[fill] && fill_seat_count_q[fill] < 3 && fill_block_q[fill] &&
        decision_reader;
    assign joining = run && array_response && join_fill[fill];
    for (genvar slot = 0; slot < COMPLETIONS; slot++) begin : gen_eligible
      if (PREFETCH_SLOTS != 0 && slot >= COMPLETIONS - PREFETCH_SLOTS) begin : gen_prefetch_slot
        // A prefetch slot holds only Prefetches, which take no seat.
        assign eligible[slot] = 1'b0;
      end else begin : gen_request_slot
        assign eligible[slot] = enabled && waiting[slot] && same_block(
            waiting_addr[slot], fill_addr_q[fill]
        ) && read_waiter(
            waiting_opcode[slot]
        );
      end
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
      // A successful fill's wake leaves out a primary that waits for its
      // forward; an error wakes every seat with the error.
      if (fill_wake[fill]) begin
        wake |= fill_error_q[fill] ? fill_seats_q[fill] :
            fill_seats_q[fill] & ~fill_primary_q[fill];
        if (fill_error_q[fill]) wake_error |= fill_seats_q[fill];
      end
    end
  end

  assign put_key_match = incoming_put.hart == selected_put_q.hart &&
      incoming_put.put_id == selected_put_q.put_id && incoming_put.epoch == selected_put_q.epoch &&
      incoming_put.addr == selected_put_q.addr;
  // The selected put's block is compared with the fill and write-back blocks
  // one cycle ahead, from its next address, and the comparisons are reduced
  // before the register, so W readiness reads one registered term. A fill or
  // write-back slot that stops blocking on an edge still holds the put for
  // that cycle. The fill and write-back slot allocated on an edge take the
  // query and victim blocks, compared from the decision.
  // One term per fill and write-back slot, reduced as one vector.
  logic [FILLS+NUM_WB-1:0] put_owners;
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_put_fill_owner
    assign put_owners[fill] = fill_blocking_q[fill] && (same_block(
        fill_addr_q[fill], held_put_next
    ) || (fill_victim_q[fill] && same_block(
        fill_old_addr_q[fill], held_put_next
    )));
  end
  for (genvar wb = 0; wb < NUM_WB; wb++) begin : gen_put_wb_owner
    assign put_owners[FILLS+wb] = wb_valid_q[wb] && same_block(wb_addr_q[wb], held_put_next);
  end
  always_ff @(posedge i_clk) begin
    put_query_q  <= same_block(array_query, held_put_next);
    put_victim_q <= same_block(array_addr, held_put_next);
    put_owner_q  <= |put_owners;
    if (i_rst) begin
      fill_allocated_q   <= 1'b0;
      victim_allocated_q <= 1'b0;
    end else begin
      fill_allocated_q <= run && array_response && decision_fill;
      victim_allocated_q <= run && array_response && decision_fill &&
          array_state != coherence_pkg::Invalid;
    end
  end
  // The fill decision arrives last: the selected put waits on it only when
  // its block is this response's valid victim.
  (* keep = "true" *) logic put_held_blocked, put_victim_match, w_ready_early;
  assign put_victim_match = array_response && array_state != coherence_pkg::Invalid &&
      held_put_set_q && held_put_tag_sel;
  // The held put's blocking term: the registered reduction and the owners
  // allocated on the edge before, in one node, so W readiness has a fixed
  // depth at any fill count.
  assign put_held_blocked = put_owner_q || (fill_allocated_q && put_query_q) ||
      (victim_allocated_q && put_victim_q);
  assign put_blocked = put_held_blocked || (put_victim_match && decision_fill);
  assign w_ready_early = run && put_selected_q && !put_busy && !put_held_blocked &&
      !put_busy_q[selected_put_q.put_id];
  // One kept LUT of six kept signals, with decision_fill written out, so the
  // readiness reaches the L1D from a fixed depth.
  (* keep = "true" *) logic w_ready_final;
  assign w_ready_final = w_ready_early && put_key_match && !(put_victim_match && decision_fill);
  assign o_w_ready = w_ready_final;
`ifndef SYNTHESIS
  always_comb
    if (sim_reset_seen_q && !i_rst)
      assert (o_w_ready == (run && put_selected_q && put_key_match && !put_busy &&
          !put_blocked && put_phase_q[selected_put_q.put_id] == PutFree));
`endif
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      put_selected_q <= 1'b0;
      selected_put_q <= '0;
    end else begin
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
      1'b1,
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
        put_busy_q[put] <= 1'b0;
        put_q[put] <= '0;
        put_way_q[put] <= '0;
      end else if (run) begin
        if (i_w_valid && o_w_ready && incoming_put.put_id == 1'(put)) begin
          put_q[put] <= incoming_put;
          put_busy_q[put] <= 1'b1;
          put_phase_q[put] <= PutLookup;
        end
        if (tag_valid[Client] && tag_ready[Client]) put_phase_q[put] <= PutDecision;
        // The busy flag follows every write that can leave PutFree; the tag
        // and update offers already require a busy phase.
        if (array_response && array_token_onehot[Client]) begin
          put_busy_q[put] <= 1'b1;
          if (!array_hit) put_phase_q[put] <= PutFatal;
          else if (decision_blocked) put_phase_q[put] <= PutLookup;
          else begin
            put_way_q[put]   <= array_way;
            put_phase_q[put] <= PutUpdate;
          end
        end
        if (update_valid[Client] && update_ready[Client]) put_phase_q[put] <= PutUpdateWait;
        if (array_updated && array_updated_token == TokenBits'(Client)) begin
          put_phase_q[put] <= PutAck;
          put_busy_q[put]  <= 1'b1;
        end
        if (ack_valid[Client] && ack_ready[Client]) begin
          put_phase_q[put] <= PutFree;
          put_busy_q[put]  <= 1'b0;
        end
      end
    end
  end

  // An allocation's first phase: FillMemory without a victim, else
  // FillRecall.
  (* keep = "true" *) fill_phase_t fill_phase_allocated;
  assign fill_phase_allocated = array_state == coherence_pkg::Invalid ? FillMemory : FillRecall;
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill
    localparam int unsigned Client = RESULTS + fill;
    coh_p_t probe;
    coh_wa_t absorbed_ack;
    wire probe_matches = reply.tid == FillTid + 6'(fill) && reply.addr == probe.addr &&
        reply.epoch == 0 && reply.hart == 0 &&
        (reply.opcode == coherence_pkg::ProbeAck || reply.opcode == coherence_pkg::ProbeData);
    wire allocate = run && array_response && decision_fill && fill_free_index == FillBits'(fill);
    // The primary may take a forward: a GetS, LoadReserved or GetM, and not
    // a prefetch, whose decision allocates the fill.
    wire forwardable = !lookup_prefetch_q && (decision_opcode == coherence_pkg::GetS ||
        decision_opcode == coherence_pkg::LoadReserved || coherence_pkg::is_getm(
        decision_opcode
    ));
    // Every fill that a GetMZero's decision allocates is a zero fill.
    wire zero_fill = !lookup_prefetch_q && decision_opcode == coherence_pkg::GetMZero;
    assign fill_zero_alloc[fill] = allocate && zero_fill;
    // The fill enters FillInstall on this edge.
    wire install_entry = fill_phase_q[fill] == FillMemory && (fill_done_q[fill] ?
        !fill_error_q[fill] : i_mem_resp_valid && i_mem_resp_id == 5'(fill) && !i_mem_resp_error);
    wire forwarded = forward_accept && forward_pick[fill];
    wire [COMPLETIONS-1:0] forward_seat = forwarded ? fill_primary_q[fill] : '0;
    // Prepare both waiter-mask outcomes before the allocation decision.
    // Joining, retiring and failed-fill cleanup retain their original
    // priority over allocation.
    (* keep = "true" *) logic [COMPLETIONS-1:0] seats_without_allocation, seats_with_allocation;
    always_comb begin
      seats_without_allocation = fill_seats_q[fill];
      seats_with_allocation = lookup_prefetch_q ? '0 : COMPLETIONS'(1) << decision_tid;
      if (run) begin
        seats_without_allocation = (fill_seats_q[fill] | fill_add_seats[fill]) & ~forward_seat;
        if (array_response && join_fill[fill]) begin
          seats_without_allocation[CompletionBits'(decision_tid)] = 1'b1;
          seats_with_allocation[CompletionBits'(decision_tid)] = 1'b1;
        end
        if (fill_phase_q[fill] == FillReady && pin_valid &&
            fill_seats_q[fill][CompletionBits'(decision_tid)]) begin
          seats_without_allocation[CompletionBits'(decision_tid)] = 1'b0;
          seats_with_allocation[CompletionBits'(decision_tid)] = 1'b0;
        end
        if (fill_phase_q[fill] == FillMemory && fill_done_q[fill] && fill_error_q[fill]) begin
          seats_without_allocation = '0;
          seats_with_allocation = '0;
        end
      end
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) fill_seats_q[fill] <= '0;
      else if (allocate) fill_seats_q[fill] <= seats_with_allocation;
      else fill_seats_q[fill] <= seats_without_allocation;
    end
    assign fill_forward_set[fill] = install_entry && fill_primary_q[fill] != 0;
    // The phase's next state forms in kept nodes beside the two late
    // decisions, which select it last: allocation, which finds the fill in
    // FillFree, and update acceptance, which finds it in FillInvalidate or
    // FillInstall. No other phase write applies in those phases.
    (* keep = "true" *) fill_phase_t fill_phase_hold, fill_phase_updated;
    (* keep = "true" *) logic fill_update_armed;
    always_comb begin
      fill_phase_hold = fill_phase_q[fill];
      if (run) begin
        if (fill_phase_q[fill] == FillReady && fill_seats_q[fill] == 0) fill_phase_hold = FillFree;
        if (i_r_valid && fill_r_ready[fill] && reply.error) fill_phase_hold = FillFatal;
        if (fill_phase_q[fill] == FillRecall && recall_phase_q[fill] == RecallDone &&
            !(LINE_BYTES == 64 && !fill_sector_q[fill]) && fill_read_done_q[fill])
          fill_phase_hold = FillDetach;
        if (fill_phase_q[fill] == FillDetach) fill_phase_hold = FillInvalidate;
        if (fill_phase_q[fill] == FillInvalidateWait && array_updated &&
            array_updated_token == TokenBits'(Client))
          fill_phase_hold = FillMemory;
        if (fill_phase_q[fill] == FillMemory && fill_done_q[fill])
          fill_phase_hold = fill_error_q[fill] ? FillFree : FillInstall;
        // A successful response that arrives in FillMemory installs from
        // the next cycle, beside the image capture below. A response that
        // arrives in an earlier phase, and every error response, waits in
        // fill_done_q for the transition above.
        if (fill_phase_q[fill] == FillMemory && !fill_done_q[fill] && i_mem_resp_valid &&
            i_mem_resp_id == 5'(fill) && !i_mem_resp_error)
          fill_phase_hold = FillInstall;
        if (fill_phase_q[fill] == FillInstallWait && array_updated &&
            array_updated_token == TokenBits'(Client))
          fill_phase_hold = FillReady;
      end
    end
    assign fill_phase_updated = fill_phase_q[fill] == FillInvalidate ? FillInvalidateWait :
        FillInstallWait;
    assign fill_update_armed = run && update_selected[Client] &&
        (fill_phase_q[fill] == FillInvalidate || fill_phase_q[fill] == FillInstall);
    always_ff @(posedge i_clk) begin
      if (i_rst) fill_phase_q[fill] <= FillFree;
      else if (update_request_ready && fill_update_armed) fill_phase_q[fill] <= fill_phase_updated;
      else if (allocate) fill_phase_q[fill] <= fill_phase_allocated;
      else fill_phase_q[fill] <= fill_phase_hold;
    end
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
      fill_phase_q[fill] == FillInvalidate ? 2'(coherence_pkg::Invalid) :
          fill_zero_q[fill] ? 2'(coherence_pkg::Modified) : 2'(coherence_pkg::Shared),
      fill_phase_q[fill] == FillInstall,
      {LINE_BYTES{fill_phase_q[fill] == FillInstall}},
      fill_phase_q[fill] == FillInstall ? fill_image_q[fill] : {(8 * LINE_BYTES) {1'b0}}
    };
    // A successful fill wakes its waiters once, on the first cycle after the
    // array accepts its install update. Seat admission is closed from then
    // on, so the registered seat mask names every waiter. A waiter that
    // reaches its tag decision before the install completes finds its line
    // blocked by the fill and retries without parking. A primary that waits
    // for its forward is not a waiter: it keeps its seat until the forward.
    // A failed fill wakes every seat with the error.
    assign fill_wake[fill] = run &&
        ((fill_phase_q[fill] == FillInstallWait && !fill_woken_q[fill]) ||
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
        fill_live_q[fill] <= 1'b0;
        fill_blocking_q[fill] <= 1'b0;
        recall_phase_q[fill] <= RecallDone;
        fill_addr_q[fill] <= '0;
        fill_old_addr_q[fill] <= '0;
        fill_way_q[fill] <= '0;
        fill_wb_q[fill] <= '0;
        fill_sent_q[fill] <= 1'b0;
        fill_done_q[fill] <= 1'b0;
        fill_error_q[fill] <= 1'b0;
        fill_woken_q[fill] <= 1'b0;
        fill_victim_q[fill] <= 1'b0;
        fill_read_sent_q[fill] <= 1'b0;
        fill_read_done_q[fill] <= 1'b0;
        fill_sector_q[fill] <= 1'b0;
        fill_dirty_q[fill] <= 1'b0;
        fill_dirty_sectors_q[fill] <= '0;
        fill_seat_count_q[fill] <= '0;
        fill_primary_q[fill] <= '0;
        fill_primary_upper_q[fill] <= 1'b0;
        fill_primary_ident_q[fill] <= '0;
        fill_primary_tid_q[fill] <= '0;
        fill_primary_getm_q[fill] <= 1'b0;
        fill_zero_q[fill] <= 1'b0;
        fill_forward_q[fill] <= 1'b0;
        fill_write_q[fill] <= 1'b0;
        fill_prefetch_q[fill] <= 1'b0;
        fill_ack_q[fill] <= '0;
      end else begin
        if (o_mem_req_valid && i_mem_req_ready && o_mem_req_id == 5'(fill))
          fill_sent_q[fill] <= 1'b1;
        if (i_mem_resp_valid && i_mem_resp_id == 5'(fill)) begin
          fill_image_q[fill] <= i_mem_resp_data;
          fill_done_q[fill]  <= 1'b1;
          fill_error_q[fill] <= i_mem_resp_error;
        end
        // A zero fill's image is zero from allocation; it sends no read, so no
        // response for its identity arrives.
        if (run && fill_zero_alloc[fill]) fill_image_q[fill] <= '0;
        if (run) begin
          // A forward takes the primary's seat away on the edge it is
          // accepted, beside any seats added or released then.
          fill_seat_count_q[fill] <= fill_seat_count_q[fill] + fill_add_count[fill] - 2'(forwarded);
          if (forwarded) begin
            fill_primary_q[fill] <= '0;
            fill_forward_q[fill] <= 1'b0;
          end
          if (fill_forward_set[fill]) fill_forward_q[fill] <= 1'b1;
          if (allocate) begin
            fill_addr_q[fill] <= {decision_addr[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
            fill_old_addr_q[fill] <= array_addr;
            fill_way_q[fill] <= array_way;
            fill_wb_q[fill] <= wb_free_index;
            fill_victim_q[fill] <= array_state != coherence_pkg::Invalid;
            fill_sent_q[fill] <= zero_fill;
            fill_done_q[fill] <= zero_fill;
            fill_error_q[fill] <= 1'b0;
            fill_zero_q[fill] <= zero_fill;
            fill_woken_q[fill] <= 1'b0;
            fill_read_sent_q[fill] <= array_state == coherence_pkg::Invalid;
            fill_read_done_q[fill] <= array_state == coherence_pkg::Invalid;
            fill_sector_q[fill] <= 1'b0;
            fill_dirty_q[fill] <= array_state == coherence_pkg::Modified;
            fill_dirty_sectors_q[fill] <= '0;
            fill_seat_count_q[fill] <= lookup_prefetch_q ? 2'd0 : 2'd1;
            fill_primary_q[fill] <= forwardable ? COMPLETIONS'(1) << decision_tid : '0;
            fill_primary_upper_q[fill] <= LINE_BYTES == 64 && decision_addr[5];
            fill_primary_ident_q[fill] <= decision_q;
            fill_primary_tid_q[fill] <= decision_tid;
            fill_primary_getm_q[fill] <= coherence_pkg::is_getm(decision_opcode);
            fill_forward_q[fill] <= 1'b0;
            fill_prefetch_q[fill] <= lookup_prefetch_q;
            fill_write_q[fill] <= decision_opcode == coherence_pkg::DMAWrite;
          end
          if (array_response && join_fill[fill]) begin
            fill_seat_count_q[fill] <= fill_seat_count_q[fill] + fill_add_count[fill] + 1'b1 -
                2'(forwarded);
          end
          if (fill_phase_q[fill] == FillReady && pin_valid &&
              fill_seats_q[fill][CompletionBits'(decision_tid)]) begin
            fill_seat_count_q[fill] <= fill_seat_count_q[fill] - 1'b1 - 2'(forwarded);
          end
          if (fill_phase_q[fill] == FillReady && fill_seats_q[fill] == 0) fill_live_q[fill] <= 1'b0;
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
            if (!reply.error) begin
              if (reply.absorbed) begin
                fill_ack_q[fill] <= absorbed_ack;
                recall_phase_q[fill] <= RecallAck;
              end else recall_phase_q[fill] <= RecallDone;
            end
          end
          if (ack_valid[Client] && ack_ready[Client]) recall_phase_q[fill] <= RecallDone;
          if (fill_phase_q[fill] == FillRecall && recall_phase_q[fill] == RecallDone &&
              LINE_BYTES == 64 && !fill_sector_q[fill]) begin
            fill_sector_q[fill]  <= 1'b1;
            recall_phase_q[fill] <= RecallOffer;
          end
          if (fill_phase_q[fill] == FillMemory && fill_done_q[fill] && fill_error_q[fill]) begin
            fill_live_q[fill] <= 1'b0;
            fill_blocking_q[fill] <= 1'b0;
            fill_seat_count_q[fill] <= '0;
            fill_primary_q[fill] <= '0;
          end
          if (fill_phase_q[fill] == FillInstallWait) fill_woken_q[fill] <= 1'b1;
          if (fill_phase_q[fill] == FillInstallWait && array_updated &&
              array_updated_token == TokenBits'(Client))
            fill_blocking_q[fill] <= 1'b0;
          // Allocation finds the fill free, where no update above applies, so
          // its writes come last and the late decision selects them last.
          if (allocate) begin
            fill_live_q[fill] <= 1'b1;
            fill_blocking_q[fill] <= 1'b1;
            recall_phase_q[fill] <= RecallOffer;
          end
        end
      end
    end
  end

  // Fills that may forward take turns: the first at or after the fill after
  // the last one forwarded, else the first. forward_later_q[fill] holds fill
  // > the last fill forwarded, and holds every fill after the highest one
  // forwards. The pick offers its primary's slot, its way and the primary's
  // sector of its line, all from registers. The completion table accepts
  // while its forward buffer is free; the slot then holds its grant, and the
  // sector stays in forward_data_q until that grant's G.
  function automatic logic [FILLS-1:0] forward_turn(input logic [FILLS-1:0] ready,
                                                    input logic [FILLS-1:0] later);
    forward_turn = '0;
    for (int fill = FILLS - 1; fill >= 0; fill--)
    if (|(ready & later) ? ready[fill] && later[fill] : ready[fill])
      forward_turn = FILLS'(1) << fill;
  endfunction
  function automatic logic [FILLS-1:0] forward_after(input logic [FILLS-1:0] pick);
    for (int fill = 0; fill < FILLS; fill++)
    forward_after[fill] = pick[FILLS-1] || (pick & ((FILLS'(1) << fill) - FILLS'(1))) != 0;
  endfunction
  // forward_pick_q holds the turn of the current state, formed from the
  // next state: the fills that may forward, without an accepted forward's
  // fill and with each install that begins with a primary, and the turn
  // past an accepted forward's fill. An allocation finds its fill free, so
  // it never clears a fill that may forward, and the late decision stays
  // out of the pick.
  logic [FILLS-1:0] forward_ready_next;
  assign forward_ready_next = fill_forward_q | (run ? fill_forward_set : '0);
  // Prepare each fill's blockers before testing its ready bit. Acceptance
  // chooses between the current turn and the turn after the accepted fill.
  logic [FILLS-1:0] forward_pick_if_held, forward_pick_if_accepted;
  coherence_home_forward_turn_select #(
      .FILLS(FILLS)
  ) u_forward_held (
      .i_ready(forward_ready_next),
      .i_later(forward_later_q),
      .o_pick (forward_pick_if_held)
  );
  coherence_home_forward_turn_select #(
      .FILLS(FILLS)
  ) u_forward_accepted (
      .i_ready(forward_ready_next & ~forward_pick_q),
      .i_later(forward_after(forward_pick_q)),
      .o_pick (forward_pick_if_accepted)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) forward_pick_q <= '0;
    else forward_pick_q <= forward_accept ? forward_pick_if_accepted : forward_pick_if_held;
  end
  assign forward_pick = forward_pick_q;
  always_comb begin
    forward_slots  = '0;
    forward_way    = '0;
    forward_data   = '0;
    forward_result = '0;
    for (int fill = 0; fill < FILLS; fill++) begin
      if (forward_pick[fill]) begin
        forward_slots |= fill_primary_q[fill];
        forward_way |= fill_way_q[fill];
        forward_data  |= 256'(fill_image_q[fill] >>
            (LINE_BYTES == 64 && fill_primary_upper_q[fill] ? 256 : 0));
        forward_result.q |= fill_primary_ident_q[fill];
        forward_result.tid |= fill_primary_tid_q[fill];
        forward_result.addr |= fill_addr_q[fill] |
            ADDR_WIDTH'(LINE_BYTES == 64 && fill_primary_upper_q[fill] ? 32 : 0);
        // With 64-byte lines a zero fill's grant tells its requester that the
        // upper sector's zeros are performed here.
        forward_result.opcode |= fill_zero_q[fill] ?
            (LINE_BYTES == 64 ? coherence_pkg::GrantMZero : coherence_pkg::GrantM) :
            fill_primary_getm_q[fill] ? coherence_pkg::GrantM : coherence_pkg::GrantS;
      end
    end
  end
  assign forward_valid  = run && |fill_forward_q;
  assign forward_accept = forward_valid && forward_ready;
  always_ff @(posedge i_clk) begin
    if (forward_accept) forward_data_q <= forward_data;
    if (i_rst) forward_later_q <= '1;
    else if (forward_accept) forward_later_q <= forward_after(forward_pick);
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
  logic [NUM_WB-1:0][LINE_BYTES/32-1:0] wb_take_array, wb_take_reply;
  logic [NUM_WB-1:0][FILLS-1:0] wb_owner;
  always_comb begin
    wb_take_array = '0;
    wb_take_reply = '0;
    for (int wb = 0; wb < NUM_WB; wb++)
    for (int fill = 0; fill < FILLS; fill++) begin
      wb_owner[wb][fill] = fill_wb_q[fill] == WbBits'(wb) && wb_valid_q[wb] && !wb_frozen_q[wb];
      for (int sector = 0; sector < LINE_BYTES / 32; sector++) begin
        if (wb_owner[wb][fill] && array_data_valid &&
            array_data_token == TokenBits'(RESULTS + fill) && !fill_dirty_sectors_q[fill][sector])
          wb_take_array[wb][sector] = 1'b1;
        if (wb_owner[wb][fill] && i_r_valid && fill_r_ready[fill] && reply.data_valid &&
            (LINE_BYTES == 64 && reply.addr[5]) == 1'(sector))
          wb_take_reply[wb][sector] = 1'b1;
      end
    end
  end
  // The AXI bridge can keep running through a CPU reset.
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
        // At most one fill reads or recalls into a write-back slot at a time,
        // so each sector takes the resident row or the dirty reply directly;
        // the reply, which arrives last, wins and is selected last.
        for (int wb = 0; wb < NUM_WB; wb++)
        for (int sector = 0; sector < LINE_BYTES / 32; sector++) begin
          if (wb_take_array[wb][sector])
            wb_data_q[wb][sector*256+:256] <= array_data[sector*256+:256];
          if (wb_take_reply[wb][sector]) wb_data_q[wb][sector*256+:256] <= reply.data;
        end
        for (int fill = 0; fill < FILLS; fill++) begin
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
      if (work_valid && work_error && coherence_pkg::is_getm(work.opcode)) begin
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

  if (NUM_WB < 1 || NUM_WB > 16 || FILLS < 1 || FILLS > 16 ||
      PREFETCH_RESERVE >= FILLS) begin : gen_invalid
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
  // Free fills and write-back slots counted from the phases.
  logic [ FILLS-1:0] reference_fill_free;
  logic [NUM_WB-1:0] reference_wb_free;
  logic [4:0] reference_free_fills, reference_free_wbs;
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_reference_fill_free
    assign reference_fill_free[fill] = fill_phase_q[fill] == FillFree;
  end
  assign reference_wb_free = ~wb_valid_q & ~wb_frozen_q;
  assign reference_free_fills = 5'($countones(reference_fill_free));
  assign reference_free_wbs = 5'($countones(reference_wb_free));
  // Direct comparisons that the registered response-cycle terms replace.
  logic reference_blocked, reference_victim;
  always_comb begin
    reference_blocked = 1'b0;
    reference_victim  = 1'b0;
    for (int wb = 0; wb < NUM_WB; wb++)
    if (wb_valid_q[wb]) begin
      if (same_block(wb_addr_q[wb], decision_addr)) reference_blocked = 1'b1;
      if (same_block(wb_addr_q[wb], array_addr)) reference_victim = 1'b1;
    end
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree) begin
      if (same_set(fill_addr_q[fill], array_query) && fill_way_q[fill] == array_way)
        reference_victim = 1'b1;
      if (fill_phase_q[fill] != FillReady && (same_block(
              fill_addr_q[fill], decision_addr
          ) || (fill_victim_q[fill] && same_block(
              fill_old_addr_q[fill], decision_addr
          ))))
        reference_blocked = 1'b1;
    end
    for (int put = 0; put < Puts; put++)
    if (put_phase_q[put] != PutFree && array_token != TokenBits'(RESULTS + FILLS + put)) begin
      if (same_sector(put_addr[put], decision_addr)) reference_blocked = 1'b1;
      if (same_block(put_addr[put], array_addr)) reference_victim = 1'b1;
    end
    for (int engine = 0; engine < RESULTS; engine++)
    if (array_state != coherence_pkg::Invalid && !engine_idle[engine] &&
        array_token != TokenBits'(engine) &&
        engine_opcode[engine] != coherence_pkg::Prefetch && same_block(
            engine_addr[engine], array_addr
        ))
      reference_victim = 1'b1;
  end
  logic reference_put_blocked, reference_ready_q;
  always_comb begin
    reference_put_blocked = array_response && decision_fill &&
        array_state != coherence_pkg::Invalid && same_block(array_addr, selected_put_q.addr);
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady && (same_block(
            fill_addr_q[fill], selected_put_q.addr
        ) || (fill_victim_q[fill] && same_block(
            fill_old_addr_q[fill], selected_put_q.addr
        ))))
      reference_put_blocked = 1'b1;
    for (int wb = 0; wb < NUM_WB; wb++)
    if (wb_valid_q[wb] && same_block(wb_addr_q[wb], selected_put_q.addr))
      reference_put_blocked = 1'b1;
  end
  // The owners that block the next cycle's put address now. W readiness
  // registers this reduction, so a hold beyond the current conflicts follows
  // a conflict of the cycle before.
  logic reference_put_owner_next, reference_put_owner_q;
  always_comb begin
    reference_put_owner_next = 1'b0;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillReady && (same_block(
            fill_addr_q[fill], held_put_next
        ) || (fill_victim_q[fill] && same_block(
            fill_old_addr_q[fill], held_put_next
        ))))
      reference_put_owner_next = 1'b1;
    for (int wb = 0; wb < NUM_WB; wb++)
    if (wb_valid_q[wb] && same_block(wb_addr_q[wb], held_put_next)) reference_put_owner_next = 1'b1;
  end
  logic [ADDR_WIDTH-1:0] reference_held_put_q;
  // held_put_exact_q: the held address of the cycle before is this cycle's
  // selected put's, as it is whenever a put was selected or a W was valid.
  logic held_put_exact_q;
  // Each fill's success wake, recorded from the wake itself.
  logic [FILLS-1:0] reference_woken_q;
  always_ff @(posedge i_clk)
    for (int fill = 0; fill < FILLS; fill++)
      if (i_rst || (run && array_response && decision_fill && fill_free_index == FillBits'(fill)))
        reference_woken_q[fill] <= 1'b0;
      else if (fill_wake[fill] && !fill_error_q[fill]) reference_woken_q[fill] <= 1'b1;
  always_ff @(posedge i_clk) begin
    reference_ready_q <= !i_rst;
    reference_held_put_q <= held_put_next;
    reference_put_owner_q <= reference_put_owner_next;
    held_put_exact_q <= put_selected_q || i_w_valid;
    // The completion table compares live sectors with held_put_next.
    if (sim_reset_seen_q && !i_rst && reference_ready_q) begin
      if (held_put_exact_q) assert (selected_put_q.addr == reference_held_put_q);
      if (put_selected_q) assert (held_put_exact_q);
    end
  end
  // At most one fill reads or recalls into a write-back slot in a cycle.
  logic [NUM_WB-1:0][FILLS-1:0] reference_wb_writers;
  always_comb begin
    for (int wb = 0; wb < NUM_WB; wb++)
    for (int fill = 0; fill < FILLS; fill++)
    reference_wb_writers[wb][fill] = wb_owner[wb][fill] &&
        ((array_data_valid && array_data_token == TokenBits'(RESULTS + fill)) ||
         (i_r_valid && fill_r_ready[fill] && reply.data_valid));
  end
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && run)
      for (int wb = 0; wb < NUM_WB; wb++) assert ($onehot0(reference_wb_writers[wb]));
  logic [WAYS-1:0] reference_exclude;
  logic exclude_matched_q;
  always_comb begin
    reference_exclude = '0;
    for (int fill = 0; fill < FILLS; fill++)
    if (fill_phase_q[fill] != FillFree && same_set(fill_addr_q[fill], array_query))
      reference_exclude[fill_way_q[fill]] = 1'b1;
    for (int put = 0; put < Puts; put++)
    if ((put_phase_q[put] == PutUpdate || put_phase_q[put] == PutUpdateWait ||
         put_phase_q[put] == PutAck) && same_set(
            put_addr[put], array_query
        ))
      reference_exclude[put_way_q[put]] = 1'b1;
  end
`ifdef COHERENCE_HOME_CONTROL
  // The prefetch flags of the lookup belong to its owner from the tag port's
  // acceptance through the decision.
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      for (int engine = 0; engine < RESULTS; engine++)
      if (f_tag_owner[engine])
        assert (lookup_prefetch_q == engine_prefetch_q[engine] &&
            lookup_fill_q == (engine_prefetch_q[engine] && !engine_nofill_q[engine]));
      for (int put = 0; put < Puts; put++)
      if (f_tag_owner[RESULTS+FILLS+put]) assert (!lookup_prefetch_q && !lookup_fill_q);
    end
  // While the array selects or responds, the query has held since the edge
  // before and no excluding owner changed its address on that edge.
  always_ff @(posedge i_clk)
    if (!i_rst && f_query_held) begin
      for (int fill = 0; fill < FILLS; fill++)
      if (fill_phase_q[fill] != FillFree)
        assert (fill_set_q[fill] == same_set(fill_addr_q[fill], array_query));
      for (int put = 0; put < Puts; put++)
      if (put_phase_q[put] == PutUpdate || put_phase_q[put] == PutUpdateWait ||
          put_phase_q[put] == PutAck)
        assert (put_set_q[put] == same_set(put_addr[put], array_query));
    end
`endif
  always_ff @(posedge i_clk) begin
    // Checked on each response for the response and selection cycles.
    exclude_matched_q <= array_exclude ==
        (completion_exclude | reference_exclude | streaming_exclude);
    if (sim_reset_seen_q && !i_rst && array_response && reference_ready_q) begin
      assert (exclude_matched_q);
      assert (array_exclude == (completion_exclude | reference_exclude | streaming_exclude));
    end
  end
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      // Every current conflict blocks W; any further hold follows a conflict
      // of the cycle before.
      if (reference_ready_q && held_put_exact_q && reference_put_blocked) assert (put_blocked);
      if (reference_ready_q && held_put_exact_q && put_blocked)
        assert (reference_put_blocked || reference_put_owner_q);
      if (array_response) begin
        if (decision_fill && decision_from_engine && engine_non_alloc[ResultBits'(array_token)])
          assert (array_way == '0);
        for (int wb = 0; wb < NUM_WB; wb++) begin
          assert (wb_blocks[wb] == (wb_valid_q[wb] && same_block(wb_addr_q[wb], decision_addr)));
          assert (wb_victims[wb] == (wb_valid_q[wb] && same_block(wb_addr_q[wb], array_addr)));
        end
        for (int fill = 0; fill < FILLS; fill++) begin
          assert (fill_block_q[fill] == same_block(fill_addr_q[fill], decision_addr));
          assert (fill_victims[fill] == (fill_phase_q[fill] != FillFree && same_set(
              fill_addr_q[fill], array_query
          ) && fill_way_q[fill] == array_way));
          assert (fill_blocks[fill] == (fill_phase_q[fill] != FillFree &&
              fill_phase_q[fill] != FillReady && (same_block(
              fill_addr_q[fill], decision_addr
          ) || (fill_victim_q[fill] && same_block(
              fill_old_addr_q[fill], decision_addr
          )))));
        end
        for (int put = 0; put < Puts; put++)
        if (put_phase_q[put] != PutFree && array_token != TokenBits'(RESULTS + FILLS + put)) begin
          assert (put_blocks[put] == same_sector(put_addr[put], decision_addr));
          assert (put_victims[put] == same_block(put_addr[put], array_addr));
        end
        for (int engine = 0; engine < RESULTS; engine++)
        if (!engine_idle[engine] && array_token != TokenBits'(engine))
          assert (engine_victims[engine] == (engine_opcode[engine] != coherence_pkg::Prefetch &&
              same_block(
              engine_addr[engine], array_addr
          )));
        if (held_put_exact_q)
          assert ((held_put_set_q && held_put_tag_q[array_way]) == same_block(
              array_addr, selected_put_q.addr
          ));
        assert (decision_blocked == reference_blocked);
        assert (victim_blocked == reference_victim);
      end
      assert (join_fill == (array_response && reference_join ?
          FILLS'(1) << reference_join_index : FILLS'(0)));
      assert ($onehot0({engine_r_ready, fill_r_ready}));
      assert ((park & wake) == 0);
      // The forward offers one fill that may forward, with its primary's
      // slot and the fill's way and line sector. The registered pick is the
      // turn of the current state.
      assert (forward_pick_q == forward_turn(fill_forward_q, forward_later_q));
      assert ($onehot0(forward_pick) && (forward_pick & ~fill_forward_q) == 0);
      assert ((forward_pick != 0) == (fill_forward_q != 0));
      assert (forward_valid == (run && fill_forward_q != 0));
      for (int fill = 0; fill < FILLS; fill++)
      if (forward_pick[fill]) begin
        assert (forward_slots == fill_primary_q[fill] && forward_way == fill_way_q[fill] &&
            forward_data == 256'(fill_image_q[fill] >>
            (LINE_BYTES == 64 && fill_primary_upper_q[fill] ? 256 : 0)));
        assert (forward_result.tid == fill_primary_tid_q[fill] && !forward_result.error &&
            forward_result.data == '0);
      end
      if (|image_select)
        assert (image_data == (int'(image_index) == RESULTS ? forward_data_q :
            engine_image[ResultBits'(image_index)]));
      if (work_valid && run) assert (engine_idle[work_buffer]);
      if (array_response && decision_engine)
        assert (same_block(array_query, engine_addr[ResultBits'(array_token)]));
      for (int engine = 0; engine < RESULTS; engine++)
      if (run) assert (engine_read[engine] == read_valid[engine]);
      if (run) assert ((row_request_valid && row_request_ready) == (|(read_valid & read_ready)));
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
      if (array_response && run && decision_fill) begin
        assert (!array_exclude[array_way] && !decision_blocked && !victim_blocked);
        if (array_state != coherence_pkg::Invalid) assert (wb_free);
      end
      // The prefetch flags belong to the decision in progress, and a
      // prefetch decision never retries, pins, joins or parks.
      if (array_response) begin
        if (decision_engine)
          assert (lookup_prefetch_q ==
              (engine_opcode[ResultBits'(array_token)] == coherence_pkg::Prefetch) &&
              lookup_fill_q == (lookup_prefetch_q && !engine_nofill_q[ResultBits'(array_token)]));
          else assert (!lookup_prefetch_q && !lookup_fill_q);
        if (lookup_prefetch_q) assert (!retry_valid && !pin_valid && !decision_join);
      end
      // A prefetch allocates only when it may fill, more than PREFETCH_RESERVE
      // fills are free, two ways were available and, for a valid victim, two
      // write-back slots are free.
      if (array_response && run && decision_fill && lookup_prefetch_q) begin
        assert (lookup_fill_q && array_two_available);
        assert (int'(reference_free_fills) > PREFETCH_RESERVE);
        if (array_state != coherence_pkg::Invalid) assert (reference_free_wbs >= 2);
      end
      // A busy engine serves its slot's request.
      for (int engine = 0; engine < RESULTS; engine++)
      if (!engine_idle[engine]) begin
        assert (int'(engine_tid[engine]) < COMPLETIONS &&
            engine_opcode[engine] == waiting_opcode[CompletionBits'(engine_tid[engine])]);
        assert (engine_prefetch_q[engine] == (engine_opcode[engine] == coherence_pkg::Prefetch));
        if (engine_nofill_q[engine]) assert (engine_prefetch_q[engine]);
      end
      for (int fill = 0; fill < FILLS; fill++)
      if (fill_prefetch_q[fill] && fill_phase_q[fill] != FillFree) assert (!fill_write_q[fill]);
      if (array_response && run && !array_hit && array_available)
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
        // A successful fill wakes its waiters exactly once: after the array
        // accepts its install update and no later than the install's
        // completion, which every FillReady fill has passed.
        assert (fill_woken_q[fill] == reference_woken_q[fill]);
        if (fill_woken_q[fill])
          assert (fill_phase_q[fill] == FillInstallWait || fill_phase_q[fill] == FillReady ||
              fill_phase_q[fill] == FillFree);
        if (fill_phase_q[fill] == FillReady) assert (fill_woken_q[fill]);
        if (fill_wake[fill]) assert (!fill_woken_q[fill]);
        // No request takes a seat while the install completes, so the wake
        // names every waiter.
        if (fill_phase_q[fill] == FillInstallWait)
          assert (fill_add_seats[fill] == 0 && !join_fill[fill]);
        // A pending primary is one seat of a demand fill: a GetS,
        // LoadReserved or GetM of the fill's block, in the recorded sector.
        // The fill may forward once it holds its line and its install has
        // begun, and a success wake never names its pending primary.
        assert ($onehot0(
            fill_primary_q[fill]
        ) && (fill_primary_q[fill] & ~fill_seats_q[fill]) == 0);
        assert (fill_forward_q[fill] == (fill_primary_q[fill] != 0 &&
            (fill_phase_q[fill] == FillInstall || fill_phase_q[fill] == FillInstallWait ||
             fill_phase_q[fill] == FillReady)));
        // A fill's address is block aligned and a slot's is sector aligned,
        // so the fill's address and recorded sector give the primary's.
        if (fill_phase_q[fill] != FillFree) assert (fill_addr_q[fill][OffsetBits-1:0] == 0);
        if (fill_primary_q[fill] != 0) begin
          assert (fill_phase_q[fill] != FillFree && !fill_prefetch_q[fill] && !fill_write_q[fill]);
          for (int slot = 0; slot < COMPLETIONS; slot++)
          if (fill_primary_q[fill][slot]) begin
            assert (waiting_opcode[slot] == coherence_pkg::GetS ||
                waiting_opcode[slot] == coherence_pkg::LoadReserved ||
                coherence_pkg::is_getm(
                waiting_opcode[slot]
            ));
            // A zero fill's primary is the GetMZero that allocated it.
            assert (fill_zero_q[fill] == (waiting_opcode[slot] == coherence_pkg::GetMZero));
            assert (same_block(waiting_addr[slot], fill_addr_q[fill]));
            if (LINE_BYTES == 64) assert (waiting_addr[slot][5] == fill_primary_upper_q[fill]);
            assert (fill_primary_ident_q[fill] == request_q(
                waiting_request[slot]
            ) && fill_primary_tid_q[fill] == 6'(slot) &&
                fill_primary_getm_q[fill] == coherence_pkg::is_getm(
                waiting_opcode[slot]
            ));
          end
        end
        if (fill_wake[fill] && !fill_error_q[fill]) assert ((wake & fill_primary_q[fill]) == 0);
        // A zero fill reads no memory: its read is done from allocation, with
        // a zero image, and it is a demand GetMZero's fill.
        if (fill_phase_q[fill] != FillFree && fill_zero_q[fill]) begin
          assert (fill_sent_q[fill] && fill_done_q[fill] && !fill_error_q[fill]);
          assert (!fill_prefetch_q[fill] && !fill_write_q[fill] && fill_primary_getm_q[fill]);
          if (fill_phase_q[fill] != FillReady && fill_phase_q[fill] != FillInstallWait)
            assert (fill_image_q[fill] == '0);
        end
        if (memory_valid[fill]) assert (!fill_zero_q[fill]);
        if (fill_phase_q[fill] != FillFree) assert (int'(fill_way_q[fill]) < WAYS);
        // A seated request's decision takes its completion pin only from a
        // ready fill, which releases the seat on the same edge; a forward
        // gives the primary its pin and releases its seat in any phase it
        // may forward in.
        if (pin_valid && fill_phase_q[fill] != FillFree &&
            fill_seats_q[fill][CompletionBits'(decision_tid)])
          assert (fill_phase_q[fill] == FillReady);
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
`ifdef COHERENCE_HOME_PREFETCH_COVER
  logic [FILLS-1:0] f_prefetch_ready, f_prefetch_seated, f_prefetch_failed;
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_prefetch_cover_terms
    assign f_prefetch_ready[fill] = fill_prefetch_q[fill] && fill_phase_q[fill] == FillReady;
    assign f_prefetch_seated[fill] = fill_prefetch_q[fill] && fill_phase_q[fill] == FillMemory &&
        fill_seats_q[fill] != 0;
    assign f_prefetch_failed[fill] = fill_prefetch_q[fill] && fill_phase_q[fill] == FillMemory &&
        fill_done_q[fill] && fill_error_q[fill];
  end
`endif
  (* anyconst *) logic [OffsetBits-1:0] f_byte;
`ifdef COHERENCE_HOME_WB_PROOF
  // A watched byte of each fill's memory response stays in its image, and a
  // forward from that fill offers it at the same offset of the sector when
  // the byte lies in the primary's sector. This task runs on free data; the
  // control tasks keep their payloads at zero.
  logic [7:0] f_fill_byte_q[FILLS];
  always_ff @(posedge i_clk)
    for (int fill = 0; fill < FILLS; fill++) begin
      if (i_mem_resp_valid && i_mem_resp_id == 5'(fill))
        f_fill_byte_q[fill] <= i_mem_resp_data[8*f_byte+:8];
      if (run && fill_zero_alloc[fill]) f_fill_byte_q[fill] <= '0;
      if (!i_rst && fill_done_q[fill]) begin
        assert (fill_image_q[fill][8*f_byte+:8] == f_fill_byte_q[fill]);
        if (forward_pick[fill] &&
            (LINE_BYTES != 64 || f_byte[OffsetBits-1] == fill_primary_upper_q[fill]))
          assert (forward_data[8*int'(f_byte[4:0])+:8] == f_fill_byte_q[fill]);
      end
    end
`endif
`ifdef COHERENCE_HOME_COVER
  logic [2:0] f_seen_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) f_seen_q <= '0;
    else
      f_seen_q <= f_seen_q | {(|wb_frozen_q), (|wb_sent_q),
        (run && array_response && decision_blocked)};
  end
`endif
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !$past(i_rst) && $past(i_fatal_stop)) assume (i_fatal_stop || i_rst);
    if (!i_rst) begin
      p_stop_held : assert (run || i_fatal_stop || o_fatal);
      p_fatal_stops : assert (!(run && o_fatal));
    end
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
      if (result_valid && run && result_ready) assert (int'(result.tid) < COMPLETIONS);
      for (int engine = 0; engine < RESULTS; engine++) begin
        assert (int'(engine_tid[engine]) < COMPLETIONS);
        for (int other = engine + 1; other < RESULTS; other++)
        if (!engine_idle[engine] && !engine_idle[other])
          assert (engine_tid[engine] != engine_tid[other]);
      end
      for (int fill = 0; fill < FILLS; fill++) begin
        // A demand fill keeps its primary's seat until the install begins;
        // a forward can take it away from then on.
        if (fill_phase_q[fill] != FillFree && fill_phase_q[fill] != FillInstall &&
            fill_phase_q[fill] != FillInstallWait && fill_phase_q[fill] != FillReady)
          assert (fill_seats_q[fill] != 0 || fill_prefetch_q[fill]);
        for (int slot = 0; slot < COMPLETIONS; slot++)
        if (fill_phase_q[fill] != FillFree && fill_seats_q[fill][slot])
          assert (same_block(
              fill_addr_q[fill], waiting_addr[slot]
          ) && waiting_opcode[slot] != coherence_pkg::Prefetch);
        for (int other = fill + 1; other < FILLS; other++)
        if (fill_phase_q[fill] != FillFree && fill_phase_q[other] != FillFree)
          assert ((fill_seats_q[fill] & fill_seats_q[other]) == 0);
        if (fill_wake[fill] && fill_error_q[fill])
          assert (fill_seats_q[fill] != 0 || fill_prefetch_q[fill]);
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
`ifdef COHERENCE_HOME_PREFETCH_COVER
    if (!i_rst) begin
      // A prefetch's fill installs with no seat, gains a demand seat, and
      // fails. Prefetches never reach the highest fill indices (lowest-free
      // allocation and the reserve), so these cover any fill.
      cover (|f_prefetch_ready);
      cover (|f_prefetch_seated);
      cover (|f_prefetch_failed);
      // Prefetch decisions: an allocation, one held back by the fill
      // reserve, and one for a block a demand holds. The way and write-back
      // limits are exercised by the home bench and the bounded tasks.
      if (run && array_response && lookup_prefetch_q && !array_hit) begin
        cover (decision_fill);
        cover (lookup_fill_q && !prefetch_fill_q && fill_free_any);
        cover (!lookup_fill_q);
      end
    end
`endif
`ifdef COHERENCE_HOME_FILL_COVER
    // Fill phase interleavings reachable with the control harness's free
    // inputs. Fill 0 stands for each fill.
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // A successful response in FillMemory installs from the next cycle.
      cover ($past(
          run && fill_phase_q[0] == FillMemory && !fill_done_q[0] && i_mem_resp_valid &&
          i_mem_resp_id == 5'd0 && !i_mem_resp_error
      ) && fill_phase_q[0] == FillInstall);
      // A request takes a seat on the edge the array accepts the install.
      cover (run && fill_phase_q[0] == FillInstall && update_ready[RESULTS] &&
             fill_add_seats[0] != 0);
      // Two waiters have woken while the install completes.
      cover (fill_phase_q[0] == FillInstallWait && fill_woken_q[0] && fill_seat_count_q[0] == 2'd2);
      // A primary takes its forward while its fill is in FillInstall, and a
      // forwarded G is taken while the install completes.
      cover (run && forward_accept && forward_pick[0] && fill_phase_q[0] == FillInstall);
      cover ($past(
          run && !forward_ready
      ) && run && forward_ready && fill_phase_q[0] == FillInstallWait);
    end
`endif
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

// Prefer the first ready fill in later, else the first ready fill. Each bit
// tests ready after the blockers; later need not be a suffix or one-hot.
module coherence_home_forward_turn_select #(
    parameter int unsigned FILLS = 8
) (
    input  logic [FILLS-1:0] i_ready,
    input  logic [FILLS-1:0] i_later,
    output logic [FILLS-1:0] o_pick
);
  localparam int unsigned Groups = (FILLS + 2) / 3;
  for (genvar fill = 0; fill < FILLS; fill++) begin : gen_fill
    localparam logic [FILLS-1:0] Below = (FILLS'(1) << fill) - FILLS'(1);
    localparam logic [FILLS-1:0] Above = ~(Below | (FILLS'(1) << fill));
    // Bound each blocker reduction before combining its groups. Sharing an
    // unbounded suffix reduction can otherwise serialize the ready inputs.
    (* keep = "true" *) wire [Groups-1:0] below_ready_groups;
    (* keep = "true" *) wire [Groups-1:0] below_later_groups, above_later_groups;
    for (genvar group_idx = 0; group_idx < Groups; group_idx++) begin : gen_group
      wire [2:0] ready_below, ready_above, later;
      for (genvar lane = 0; lane < 3; lane++) begin : gen_lane
        localparam int unsigned Index = 3 * group_idx + lane;
        if (Index < FILLS) begin : gen_present
          assign ready_below[lane] = i_ready[Index] && Below[Index];
          assign ready_above[lane] = i_ready[Index] && Above[Index];
          assign later[lane] = i_later[Index];
        end else begin : gen_padding
          assign ready_below[lane] = 1'b0;
          assign ready_above[lane] = 1'b0;
          assign later[lane] = 1'b0;
        end
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT3 #(
          .INIT(8'hfe)
      ) u_below_ready (
          .I0(ready_below[0]),
          .I1(ready_below[1]),
          .I2(ready_below[2]),
          .O (below_ready_groups[group_idx])
      );
      (* dont_touch = "true" *) LUT6 #(
          .INIT(64'hfffff888f888f888)
      ) u_below_later (
          .I0(ready_below[0]),
          .I1(later[0]),
          .I2(ready_below[1]),
          .I3(later[1]),
          .I4(ready_below[2]),
          .I5(later[2]),
          .O (below_later_groups[group_idx])
      );
      (* dont_touch = "true" *) LUT6 #(
          .INIT(64'hfffff888f888f888)
      ) u_above_later (
          .I0(ready_above[0]),
          .I1(later[0]),
          .I2(ready_above[1]),
          .I3(later[1]),
          .I4(ready_above[2]),
          .I5(later[2]),
          .O (above_later_groups[group_idx])
      );
`else
      assign below_ready_groups[group_idx] = |ready_below;
      assign below_later_groups[group_idx] = |(ready_below & later);
      assign above_later_groups[group_idx] = |(ready_above & later);
`endif
    end
    (* keep = "true" *)wire below_ready = |below_ready_groups;
    (* keep = "true" *)wire below_later = |below_later_groups;
    (* keep = "true" *)wire above_later = |above_later_groups;
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *) LUT5 #(
        .INIT(32'h22270000)
    ) u_pick (
        .I0(i_later[fill]),
        .I1(below_later),
        .I2(below_ready),
        .I3(above_later),
        .I4(i_ready[fill]),
        .O (o_pick[fill])
    );
`else
    assign o_pick[fill] = i_ready[fill] &&
        (i_later[fill] ? !below_later : (!below_ready && !above_later));
`endif
  end
endmodule
