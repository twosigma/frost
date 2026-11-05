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

// Source 3 of the coherent home: reads the lines ahead of ascending miss
// streams into the L2 with Prefetch requests.
//
// Two l2_stream_prefetcher tables choose the lines. The data table watches
// the hart data misses the home accepts (GetS, GetM and LoadReserved, so
// store streams train it too), the instruction table the hart's instruction
// refills (ReadOnceIF). Both read the home's registered copy of its D
// acceptance, and both load new requests only while the home reports room
// for a prefetch fill.
// The instruction table preserves entries across backward refills up to
// 2 * DISTANCE - 1 lines behind their last line in the same page.
//
// The wrapper owns IDS prefetch identities {3, 3, id}. It takes a table's
// request, with a free identity, into a D register that holds until the home
// accepts it; the two tables alternate when both have one. The home answers
// every Prefetch with GrantAck after one lookup. The wrapper takes every G and
// U for source 3 when they arrive (the home's prefetch completion slots rely
// on this for G), presents C from registers through a held arbiter, and
// returns the identity, and the table's own read id, at U.
module coherence_prefetcher #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned DATA_STREAMS = 4,
    parameter int unsigned IF_STREAMS = 2,
    parameter int unsigned DISTANCE = 8,
    // Prefetch identities, 1 to coherence_pkg::PrefetchIds: the requests in
    // flight from the D register to U.
    parameter int unsigned IDS = 4
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    // The home's registered copy of its D acceptance.
    input logic i_accepted,
    input logic [3:0] i_accepted_opcode,
    input logic [8:0] i_accepted_q,
    input logic [ADDR_WIDTH-1:0] i_accepted_addr,
    // The home's registered prefetch room indication.
    input logic i_room,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic o_c_valid,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u
);
`ifndef SYNTHESIS
`ifdef FORMAL
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam int unsigned Ids = coherence_pkg::PrefetchIds;
  localparam int unsigned IdBits = $clog2(Ids);
  // Each table's own read ids: as many as the identities, so the pool, not
  // a table, bounds the reads in flight.
  localparam int unsigned TableIdBits = IdBits;
  if (IDS < 1 || IDS > Ids || DATA_STREAMS < 1 || IF_STREAMS < 1) begin : gen_invalid
    initial $fatal(1, "coherence_prefetcher: invalid parameters");
  end
  typedef enum logic [1:0] {
    Idle,
    WaitGrant,
    Complete,
    WaitRelease
  } phase_t;
  phase_t phase_q[Ids];
  logic [ADDR_WIDTH-1:0] addr_q[Ids];
  logic [5:0] tid_q[Ids];
  logic [Ids-1:0] table_q, error_q, release_match, c_valid, c_ready, idle;
  logic [TableIdBits-1:0] table_id_q[Ids];
  logic [Ids-1:0][ADDR_WIDTH+17:0] completions;
  coh_g_t grant_in;
  coh_u_t release_in;
  coherence_pkg::q_t accepted_q;
  assign grant_in   = i_g;
  assign release_in = i_u;
  assign accepted_q = i_accepted_q;

  // The tables. A hart's data misses train the data table and its
  // instruction refills the instruction table.
  wire hart_request = i_accepted && accepted_q.src < 2;
  wire watch_data = hart_request && accepted_q.port_class == 0 &&
      (i_accepted_opcode == coherence_pkg::GetS || i_accepted_opcode == coherence_pkg::GetM ||
       i_accepted_opcode == coherence_pkg::LoadReserved);
  (* keep = "true" *) wire if_request = hart_request && accepted_q.port_class == 1;
  wire watch_if = if_request && i_accepted_opcode == coherence_pkg::ReadOnceIF;
  logic [1:0] table_valid, table_ready, table_resp_valid;
  logic [1:0][ADDR_WIDTH-1:0] table_addr;
  logic [1:0][TableIdBits-1:0] table_id;
  logic [TableIdBits-1:0] table_resp_id;
  l2_stream_prefetcher #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .L2_LINE_BYTES(LINE_BYTES),
      .STREAMS(DATA_STREAMS),
      .DISTANCE(DISTANCE),
      .MAX_INFLIGHT(Ids),
      .ID_BITS(TableIdBits)
  ) data_streams (
      .i_clk,
      .i_rst,
      .i_miss_valid(watch_data),
      .i_miss_addr(i_accepted_addr),
      .i_enable(i_room),
      .o_req_valid(table_valid[0]),
      .i_req_ready(table_ready[0]),
      .o_req_addr(table_addr[0]),
      .o_req_id(table_id[0]),
      .i_resp_valid(table_resp_valid[0]),
      .i_resp_id(table_resp_id)
  );
  l2_stream_prefetcher #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .L2_LINE_BYTES(LINE_BYTES),
      .STREAMS(IF_STREAMS),
      .IGNORE_BACKWARD(1),
      .DISTANCE(DISTANCE),
      .MAX_INFLIGHT(Ids),
      .ID_BITS(TableIdBits)
  ) if_streams (
      .i_clk,
      .i_rst,
      .i_miss_valid(watch_if),
      .i_miss_addr(i_accepted_addr),
      .i_enable(i_room),
      .o_req_valid(table_valid[1]),
      .i_req_ready(table_ready[1]),
      .o_req_addr(table_addr[1]),
      .o_req_id(table_id[1]),
      .i_resp_valid(table_resp_valid[1]),
      .i_resp_id(table_resp_id)
  );

  // The lowest idle identity among the first IDS.
  logic free;
  logic [IdBits-1:0] free_id;
  for (genvar id = 0; id < Ids; id++) begin : gen_idle
    assign idle[id] = phase_q[id] == Idle;
  end
  always_comb begin
    free = 1'b0;
    free_id = '0;
    for (int id = IDS - 1; id >= 0; id--) begin
      if (idle[id]) begin
        free = 1'b1;
        free_id = IdBits'(id);
      end
    end
  end

  // The D register. It loads a table's request with a free identity when it
  // is empty, so its load does not wait on D readiness; the instruction table
  // goes first when it is its turn or the data table has nothing.
  logic d_valid_q, turn_q, load, pick;
  logic [ADDR_WIDTH-1:0] d_addr_q;
  logic [IdBits-1:0] d_id_q;
  wire d_fire = o_d_valid && i_d_ready;
  assign pick = table_valid[1] && (!table_valid[0] || turn_q);
  assign load = !i_fatal_stop && !d_valid_q && |table_valid && free;
  assign table_ready = {load && pick, load && !pick};
  coh_d_t demand;
  always_comb begin
    demand = '0;
    demand.opcode = coherence_pkg::Prefetch;
    demand.q = {2'd3, 2'd3, (4 - IdBits)'(0), d_id_q, 1'b0};
    demand.addr = d_addr_q;
    demand.size = 3'd5;
  end
  assign o_d_valid = !i_rst && !i_fatal_stop && d_valid_q;
  assign o_d = demand;

  for (genvar id = 0; id < Ids; id++) begin : gen_id
    wire [8:0] identity = {2'd3, 2'd3, 4'(id), 1'b0};
    assign release_match[id] = phase_q[id] == WaitRelease && release_in.q == identity &&
        release_in.addr == addr_q[id] && release_in.tid == tid_q[id];
    assign c_valid[id] = !i_rst && phase_q[id] == Complete;
    assign completions[id] = {
      identity,
      tid_q[id],
      addr_q[id],
      error_q[id] ? coherence_pkg::Error : coherence_pkg::Consumed,
      1'b0
    };
  end
  // Every G and U for source 3 belongs to an identity waiting for it, and
  // is taken when it arrives.
  assign o_g_ready = 1'b1;
  wire [IdBits-1:0] grant_id = grant_in.q.id[IdBits-1:0];
  assign o_u_ready = 1'b1;
  // Each identity offering C holds its offer until the C is accepted.
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(Ids),
      .HOLD_VALID(1)
  ) completion_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(c_valid),
      .o_ready(c_ready),
      .i_payload(completions),
      .o_valid(o_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(i_c_ready),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(1'b0),
`endif
      .o_payload(o_c)
  );
  // At U the identity's table gets its read id back.
  logic [IdBits-1:0] release_id;
  always_comb begin
    release_id = '0;
    for (int id = 0; id < Ids; id++) if (release_match[id]) release_id = IdBits'(id);
  end
  wire release_fire = i_u_valid && |release_match;
  assign table_resp_valid = {
    release_fire && table_q[release_id], release_fire && !table_q[release_id]
  };
  assign table_resp_id = table_id_q[release_id];

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      d_valid_q <= 1'b0;
      d_addr_q <= '0;
      d_id_q <= '0;
      turn_q <= 1'b0;
      table_q <= '0;
      error_q <= '0;
      for (int id = 0; id < Ids; id++) begin
        phase_q[id] <= Idle;
        addr_q[id] <= '0;
        tid_q[id] <= '0;
        table_id_q[id] <= '0;
      end
    end else begin
      if (d_fire) d_valid_q <= 1'b0;
      if (load) begin
        d_valid_q <= 1'b1;
        d_addr_q <= table_addr[pick];
        d_id_q <= free_id;
        turn_q <= !pick;
        phase_q[free_id] <= WaitGrant;
        addr_q[free_id] <= table_addr[pick];
        table_q[free_id] <= pick;
        table_id_q[free_id] <= table_id[pick];
      end
      if (i_g_valid) begin
        tid_q[grant_id]   <= grant_in.tid;
        error_q[grant_id] <= grant_in.error;
        phase_q[grant_id] <= Complete;
      end
      for (int id = 0; id < Ids; id++) begin
        if (c_valid[id] && c_ready[id]) phase_q[id] <= WaitRelease;
        if (i_u_valid && release_match[id]) phase_q[id] <= Idle;
      end
    end
  end
`ifndef SYNTHESIS
  // The home's view of each identity: its D accepted, its G sent, its C
  // taken. The home sends one G for each accepted D, and a U only after the
  // identity's C.
  logic [Ids-1:0] f_sent_q, f_granted_q, f_completed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_sent_q <= '0;
      f_granted_q <= '0;
      f_completed_q <= '0;
    end else begin
      if (d_fire) f_sent_q[d_id_q] <= 1'b1;
      if (i_g_valid) f_granted_q[grant_id] <= 1'b1;
      for (int id = 0; id < Ids; id++) begin
        if (c_valid[id] && c_ready[id]) f_completed_q[id] <= 1'b1;
        if (i_u_valid && release_match[id]) begin
          f_sent_q[id] <= 1'b0;
          f_granted_q[id] <= 1'b0;
          f_completed_q[id] <= 1'b0;
        end
      end
    end
  end
  wire grant_legal = int'(grant_in.q.id) < IDS &&
      grant_in.q == {2'd3, 2'd3, 4'(grant_id), 1'b0} && f_sent_q[grant_id] &&
      !f_granted_q[grant_id] && grant_in.addr == addr_q[grant_id] &&
      grant_in.opcode == coherence_pkg::GrantAck && grant_in.data == '0;
  coh_c_t completion_out;
  assign completion_out = o_c;
  wire [IdBits-1:0] completion_id = completion_out.q.id[IdBits-1:0];
  logic release_legal;
  always_comb begin
    release_legal = 1'b0;
    for (int id = 0; id < IDS; id++)
    if (f_completed_q[id] && release_in.q == {2'd3, 2'd3, 4'(id), 1'b0} &&
        release_in.addr == addr_q[id] && release_in.tid == tid_q[id])
      release_legal = 1'b1;
  end
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !$past(i_rst) && $past(i_fatal_stop)) assume (i_fatal_stop || i_rst);
  end
  always_comb
    if (!i_rst) begin
      if (i_g_valid) assume (grant_legal);
      if (i_u_valid) assume (release_legal);
    end
`else
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      if (i_g_valid) assert (grant_legal);
      if (i_u_valid) assert (release_legal);
    end
`endif
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      // Each identity's phase follows the home's view of it, and only the
      // identity in the D register waits to be sent.
      for (int id = 0; id < Ids; id++) begin
        if (id >= IDS) assert (phase_q[id] == Idle);
        case (phase_q[id])
          Idle: assert (!f_sent_q[id] && !f_granted_q[id] && !f_completed_q[id]);
          WaitGrant:
          assert (!f_granted_q[id] && !f_completed_q[id] &&
              f_sent_q[id] == !(d_valid_q && d_id_q == IdBits'(id)));
          Complete: assert (f_sent_q[id] && f_granted_q[id] && !f_completed_q[id]);
          default: assert (f_sent_q[id] && f_granted_q[id] && f_completed_q[id]);
        endcase
        if (phase_q[id] != Idle) assert (addr_q[id][$clog2(LINE_BYTES)-1:0] == 0);
      end
      if (d_valid_q)
        assert (phase_q[d_id_q] == WaitGrant && addr_q[d_id_q] == d_addr_q && int'(d_id_q) < IDS);
      // A legal U matches exactly one identity.
      assert ($onehot0(release_match));
      if (i_u_valid) assert (|release_match);
      if (o_c_valid && i_c_ready) begin
        assert (phase_q[completion_id] == Complete);
        assert (o_c == completions[completion_id]);
      end
      for (int table_index = 0; table_index < 2; table_index++)
      if (table_valid[table_index]) assert (table_addr[table_index][$clog2(LINE_BYTES)-1:0] == 0);
    end
  end
`ifdef FORMAL
  // The table of the last load.
  logic f_last_pick_q = 1'b0, f_loaded_q = 1'b0;
  always_ff @(posedge i_clk)
    if (load) begin
      f_last_pick_q <= pick;
      f_loaded_q <= 1'b1;
    end
  // The D and C presentations hold until taken, and D is a Prefetch of a
  // line for one of the identities.
  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_d_valid && !i_d_ready) && !i_fatal_stop) assert (o_d_valid && o_d == $past(o_d));
      if ($past(o_c_valid && !i_c_ready)) assert (o_c_valid && o_c == $past(o_c));
    end
    if (!i_rst && o_d_valid)
      assert (demand.opcode == coherence_pkg::Prefetch && demand.size == 3'd5 &&
          demand.mask == '0 && demand.q.src == 2'd3 && demand.q.port_class == 2'd3 &&
          int'(demand.q.id) < IDS && demand.addr[$clog2(
          LINE_BYTES
      )-1:0] == 0);
    if (!i_rst) begin
      cover (&f_sent_q[IDS-1:0]);
      // The tables take turns: an instruction load right after a data load.
      cover (load && pick && f_last_pick_q == 1'b0 && f_loaded_q);
      cover (o_c_valid && !i_c_ready && i_g_valid);
      cover (i_u_valid && o_u_ready && table_resp_valid[1]);
    end
  end
`endif
`endif
endmodule
