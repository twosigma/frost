// Copyright (c) 2026 John Goodacre.

/*
 * coherence_prefetch_agent reads ahead of the hart's ascending streams into
 * the coherence home's L2. Two l2_stream_prefetcher tables choose the lines,
 * trained on the home's registered copy of its D acceptance: hart-0 data
 * GetS and GetM requests, L2 hits included, train the data table, and hart-0
 * ReadOnce.IF refills train the instruction table (IF_STREAMS entries, none
 * when zero). Both tables load new requests only while i_room reports room
 * for a prefetch fill. Each predicted line uses source 3, class 3 and one
 * coherence_request_endpoint: the data table owns identities 0 to
 * MAX_INFLIGHT - 1, the instruction table the next IF_INFLIGHT.
 *
 * The home answers each Prefetch with a data-less GrantAck after one lookup.
 * A fill it starts goes on after the identity's release, and target data
 * needs no probe; victim replacement can recall private data. Each identity
 * stays occupied through G, C and U, and the agent takes every G and U for
 * source 3 when presented. A predicted line that a live identity already
 * holds is dropped, so no two live identities hold one line. Predictions
 * stay within the training access's 4 KiB page. Fatal stop blocks training
 * and endpoint request admission. Occupied identities keep their protocol
 * state.
 */

`include "coherence_types.svh"

module coherence_prefetch_agent #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned STREAMS = 4,
    parameter int unsigned DISTANCE = 8,
    parameter int unsigned MAX_INFLIGHT = 3,
    // Instruction-table streams and identities; IF_STREAMS = 0 builds no
    // instruction table.
    parameter int unsigned IF_STREAMS = 2,
    parameter int unsigned IF_INFLIGHT = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_pause,
    // The home's registered prefetch room indication.
    input logic i_room,

    // The home's registered copy of its D acceptance.
    input logic i_train_valid,
    input logic [3:0] i_train_opcode,
    input logic [8:0] i_train_q,
    input logic [ADDR_WIDTH-1:0] i_train_addr,

    // Requester ports toward the home (source 3).
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
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam int unsigned Slots = 4;
  localparam int unsigned IdBits = 2;
  localparam int unsigned LineOffBits = $clog2(L2_LINE_BYTES);
  localparam int unsigned LineBits = ADDR_WIDTH - LineOffBits;
  localparam bit IfTable = IF_STREAMS != 0;
  localparam int unsigned IfLanes = IfTable ? IF_INFLIGHT : 0;
  localparam int unsigned IfIdBits = IF_INFLIGHT > 1 ? $clog2(IF_INFLIGHT) : 1;
  localparam int unsigned IfNumIds = 1 << IfIdBits;
  // The lanes of each table.
  localparam logic [Slots-1:0] DataLanes = Slots'((1 << MAX_INFLIGHT) - 1);
  localparam logic [Slots-1:0] IfLaneMask = Slots'(((1 << IfLanes) - 1) << MAX_INFLIGHT);

  coherence_pkg::q_t train_q;
  assign train_q = i_train_q;
  wire train_hart = i_train_valid && !i_fatal_stop && train_q.src == 2'd0;
  wire train_demand = train_hart && train_q.port_class == 2'd0 &&
      (i_train_opcode == coherence_pkg::GetS || i_train_opcode == coherence_pkg::GetM);
  wire train_if = train_hart && train_q.port_class == 2'd1 &&
      i_train_opcode == coherence_pkg::ReadOnceIF;

  logic pf_req_valid, pf_req_ready, pf_resp_valid;
`ifdef FORMAL
  logic [Slots-1:0] pf_busy;
  logic [Slots-1:0][2:0] f_phase;
`endif
  logic [ADDR_WIDTH-1:0] pf_req_addr;
  logic [IdBits-1:0] pf_req_id, pf_resp_id;
  l2_stream_prefetcher #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .L2_LINE_BYTES(L2_LINE_BYTES),
      .STREAMS(STREAMS),
      .DISTANCE(DISTANCE),
      .MAX_INFLIGHT(MAX_INFLIGHT),
      .ID_BITS(IdBits)
  ) prefetcher (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_miss_valid(train_demand),
      .i_miss_addr(i_train_addr),
      .i_enable(i_room),
      .o_req_valid(pf_req_valid),
      .i_req_ready(pf_req_ready),
      .o_req_addr(pf_req_addr),
      .o_req_id(pf_req_id),
      .i_resp_valid(pf_resp_valid),
      .i_resp_id(pf_resp_id)
`ifdef FORMAL,
      .o_formal_busy(pf_busy)
`endif
  );

  logic [Slots-1:0] ep_request_valid, ep_request_ready, ep_d_valid, ep_d_ready, ep_g_ready;
  logic [Slots-1:0] ep_grant_valid, ep_c_valid, ep_c_ready, ep_u_ready, ep_live;
  logic [Slots-1:0] data_match, if_match;
  logic [Slots-1:0][ADDR_WIDTH+311:0] ep_d;
  logic [Slots-1:0][ADDR_WIDTH+274:0] ep_grant;
  logic [Slots-1:0][ADDR_WIDTH+17:0] ep_c;
  logic [Slots-1:0][LineBits-1:0] live_line;

  // The instruction table, or its idle tie-offs.
  logic if_req_valid, if_req_ready, if_resp_valid;
  logic [ADDR_WIDTH-1:0] if_req_addr;
  logic [IfIdBits-1:0] if_req_id, if_resp_id;
`ifdef FORMAL
  logic [IfNumIds-1:0] if_busy;
`endif

  // A table's request duplicates a line that a live identity holds. The
  // instruction table also yields a line the data table is requesting, so
  // the two never load one line on the same cycle. A duplicate is taken and
  // dropped, and its id returns at once, on a cycle with no U, which returns
  // an id through the same response port.
  wire admit = !i_fatal_stop && !i_pause;
  wire data_dup = |(ep_live & data_match);
  wire data_drop = pf_req_valid && admit && data_dup && !i_u_valid;
  logic if_dup, if_drop;
  assign pf_req_ready = data_dup ? data_drop : ep_request_ready[pf_req_id] && admit;

  // The home presents G and U for source 3 only to the identity waiting for
  // them, and takes the G from a prefetch completion slot as accepted when
  // it is presented.
  assign o_g_ready = 1'b1;
  assign o_u_ready = 1'b1;

  // The U for an identity frees it in its table.
  logic [IdBits-1:0] u_slot;
  always_comb begin
    u_slot = '0;
    for (int s = 0; s < int'(Slots); s++) if (ep_u_ready[s]) u_slot = IdBits'(s);
  end
  wire u_fire = i_u_valid && |ep_u_ready;
  assign pf_resp_valid = (u_fire && DataLanes[u_slot]) || data_drop;
  assign pf_resp_id = data_drop ? pf_req_id : u_slot;

  if (IfTable) begin : gen_if_table
    l2_stream_prefetcher #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .L2_LINE_BYTES(L2_LINE_BYTES),
        .STREAMS(IF_STREAMS),
        .DISTANCE(DISTANCE),
        .MAX_INFLIGHT(IF_INFLIGHT),
        .ID_BITS(IfIdBits),
        .IGNORE_BACKWARD(1)
    ) if_streams (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_miss_valid(train_if),
        .i_miss_addr(i_train_addr),
        .i_enable(i_room),
        .o_req_valid(if_req_valid),
        .i_req_ready(if_req_ready),
        .o_req_addr(if_req_addr),
        .o_req_id(if_req_id),
        .i_resp_valid(if_resp_valid),
        .i_resp_id(if_resp_id)
`ifdef FORMAL,
        .o_formal_busy(if_busy)
`endif
    );
    assign if_dup = |(ep_live & if_match) || (pf_req_valid &&
        pf_req_addr[ADDR_WIDTH-1:LineOffBits] == if_req_addr[ADDR_WIDTH-1:LineOffBits]);
    assign if_drop = if_req_valid && admit && if_dup && !i_u_valid;
    assign if_req_ready = if_dup ? if_drop :
        ep_request_ready[MAX_INFLIGHT+int'(if_req_id)] && admit;
    assign if_resp_valid = (u_fire && IfLaneMask[u_slot]) || if_drop;
    assign if_resp_id = if_drop ? if_req_id : IfIdBits'(u_slot - IdBits'(MAX_INFLIGHT));
  end else begin : gen_no_if_table
    assign if_req_valid = 1'b0;
    assign if_req_addr = '0;
    assign if_req_id = '0;
    assign if_dup = 1'b0;
    assign if_drop = 1'b0;
    assign if_req_ready = 1'b0;
    assign if_resp_valid = 1'b0;
    assign if_resp_id = '0;
`ifdef FORMAL
    assign if_busy = '0;
`endif
  end

  for (genvar s = 0; s < Slots; s++) begin : gen_slot
    // The lane's table: data lanes take the data table's id s, instruction
    // lanes the instruction table's id s - MAX_INFLIGHT.
    localparam bit IsData = DataLanes [s];
    localparam bit IsIf   = IfLaneMask[s];
    coh_d_t request, held;
    coh_g_t endpoint_grant;
    assign endpoint_grant = ep_grant[s];
    assign held = ep_d[s];
    assign live_line[s] = held.addr[ADDR_WIDTH-1:LineOffBits];
    assign data_match[s] = live_line[s] == pf_req_addr[ADDR_WIDTH-1:LineOffBits];
    assign if_match[s] = live_line[s] == if_req_addr[ADDR_WIDTH-1:LineOffBits];
    always_comb begin
      request = '0;
      request.opcode = coherence_pkg::Prefetch;
      request.q = {2'd3, 2'd3, 4'(s), 1'b0};
      request.addr = IsData ? {pf_req_addr[ADDR_WIDTH-1:5], 5'b0} :
          {if_req_addr[ADDR_WIDTH-1:5], 5'b0};
      request.size = 3'd5;
    end
    // Each table's lowest-free-id allocator uses only its own identities.
    if (IsData) begin : gen_data_lane
      assign ep_request_valid[s] = pf_req_valid && admit && !data_dup && pf_req_id == IdBits'(s);
    end else if (IsIf) begin : gen_if_lane
      assign ep_request_valid[s] = if_req_valid && admit && !if_dup &&
          if_req_id == IfIdBits'(s - MAX_INFLIGHT);
    end else begin : gen_idle_lane
      assign ep_request_valid[s] = 1'b0;
    end
    coherence_request_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SOURCE(3),
        .PORT_CLASS(3),
        .SLOT(s)
    ) endpoint (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_epoch(1'b0),
        .i_request_valid(ep_request_valid[s]),
        .o_request_ready(ep_request_ready[s]),
        .i_request(request),
        .o_d_valid(ep_d_valid[s]),
        .i_d_ready(ep_d_ready[s]),
        .o_d(ep_d[s]),
        .i_g_valid(i_g_valid),
        .o_g_ready(ep_g_ready[s]),
        .i_g(i_g),
        .o_grant_valid(ep_grant_valid[s]),
        .i_grant_ready(1'b1),
        .o_grant(ep_grant[s]),
        // The endpoint samples the completion only in its Done phase, where
        // its grant register holds the grant just taken.
        .i_done_valid(1'b1),
        .o_done_ready(),
        .i_done_status(endpoint_grant.error ? coherence_pkg::Error : coherence_pkg::Consumed),
        .i_write_done(1'b0),
        .i_error_disposed(endpoint_grant.error),
        .o_c_valid(ep_c_valid[s]),
        .o_c_selected(),
        .i_c_ready(ep_c_ready[s]),
        .o_c(ep_c[s]),
        .i_u_valid(i_u_valid),
        .o_u_ready(ep_u_ready[s]),
        .i_u(i_u),
        .o_live(ep_live[s])
`ifdef FORMAL,
        .o_formal_phase(f_phase[s])
`endif
    );
  end

  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(Slots)
  ) demands (
      .i_clk,
      .i_rst,
      .i_valid(ep_d_valid),
      .o_ready(ep_d_ready),
      .i_payload({ep_d[3], ep_d[2], ep_d[1], ep_d[0]}),
      .o_valid(o_d_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(i_d_ready),
      .o_payload(o_d)
  );
  // Each endpoint holds its C offer until acceptance.
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(Slots),
      .HOLD_VALID(1)
  ) completions (
      .i_clk,
      .i_rst,
      .i_valid(ep_c_valid),
      .o_ready(ep_c_ready),
      .i_payload({ep_c[3], ep_c[2], ep_c[1], ep_c[0]}),
      .o_valid(o_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(i_c_ready),
      .o_payload(o_c)
  );

  if (MAX_INFLIGHT < 1 || MAX_INFLIGHT + IfLanes > Slots || (IfTable && IF_INFLIGHT < 1) ||
      (L2_LINE_BYTES != 32 && L2_LINE_BYTES != 64)) begin : gen_invalid_config
    initial
      $fatal(
          1,
          "coherence_prefetch_agent: MAX_INFLIGHT + IF_INFLIGHT must be 1..4, L2_LINE_BYTES 32 or 64"
      );
  end

`ifndef SYNTHESIS
  // No two live identities hold one line.
  logic shared_line;
  always_comb begin
    shared_line = 1'b0;
    for (int s = 0; s < int'(Slots); s++)
    for (int t = 0; t < s; t++)
    if (ep_live[s] && ep_live[t] && live_line[s] == live_line[t]) shared_line = 1'b1;
  end
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst) begin
      // A U names one endpoint, and an id is loaded only into an idle endpoint.
      assert ($countones(ep_u_ready & {Slots{i_u_valid}}) <= 1);
      assert ($countones(ep_g_ready & {Slots{i_g_valid}}) <= 1);
      if (pf_req_valid && !i_fatal_stop) assert (!ep_live[pf_req_id] || !pf_req_ready);
      assert (!shared_line);
      // The home sends G and U for source 3 only to a waiting identity.
      if (i_g_valid) assert (|ep_g_ready);
      if (i_u_valid) assert (|ep_u_ready);
    end
  end
`endif
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [Slots-1:0] f_owned_q, f_d_q, f_g_q, f_c_q, f_error_q;
  logic [Slots-1:0][ADDR_WIDTH-1:0] f_addr_q;
  logic [Slots-1:0][5:0] f_tid_q;
  logic [Slots-1:0] f_data_live, f_if_live;
  coh_d_t f_d;
  coh_g_t f_g;
  coh_c_t f_c;
  coh_u_t f_u;
  assign f_d = o_d;
  assign f_g = i_g;
  assign f_c = o_c;
  assign f_u = i_u;
  // Each table's view of its identities: the lanes it owns, as its ids.
  assign f_data_live = ep_live & DataLanes;
  assign f_if_live = (ep_live & IfLaneMask) >> MAX_INFLIGHT;
  wire f_d_fire = o_d_valid && i_d_ready;
  wire f_g_fire = i_g_valid && o_g_ready;
  wire f_c_fire = o_c_valid && i_c_ready;
  wire f_u_fire = i_u_valid && o_u_ready;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) begin
      f_owned_q <= '0;
      f_d_q <= '0;
      f_g_q <= '0;
      f_c_q <= '0;
      f_error_q <= '0;
    end else begin
      assert (f_owned_q == ep_live);
      assert (pf_busy == (f_data_live | (pf_req_valid ? Slots'(1) << pf_req_id : Slots'(0))));
      assert ($countones(f_data_live) <= MAX_INFLIGHT);
      assert ((ep_live & ~(DataLanes | IfLaneMask)) == '0);
      if (pf_req_valid) begin
        assert (int'(pf_req_id) < MAX_INFLIGHT);
        assert (!ep_live[pf_req_id]);
      end
      if (IfTable) begin
        assert (if_busy == (IfNumIds'(f_if_live) |
            (if_req_valid ? IfNumIds'(1) << if_req_id : IfNumIds'(0))));
        if (if_req_valid) begin
          assert (int'(if_req_id) < IF_INFLIGHT);
          assert (!ep_live[MAX_INFLIGHT+int'(if_req_id)]);
        end
      end
      assert ($onehot0(ep_g_ready));
      assert ($onehot0(ep_u_ready));
      assert (!(i_fatal_stop || i_pause) || !(|ep_request_valid));
      assert (!shared_line);
      for (int s = 0; s < Slots; s++) begin
        if (f_owned_q[s]) begin
          assert (ep_d[s][ADDR_WIDTH+299+:9] == {2'd3, 2'd3, 4'(s), 1'b0});
          assert (ep_d[s][ADDR_WIDTH+308+:4] == coherence_pkg::Prefetch);
          assert (!ep_d[s][257]);
          assert (f_addr_q[s][$clog2(L2_LINE_BYTES)-1:0] == '0);
          assert (f_d_q[s] == (f_phase[s] >= 2));
          assert (f_g_q[s] == (f_phase[s] >= 3));
          assert (f_c_q[s] == (f_phase[s] == 6));
          if (f_g_q[s]) begin
            assert (ep_grant[s][0] == f_error_q[s]);
            assert (ep_grant[s][ADDR_WIDTH+257+:6] == f_tid_q[s]);
          end
        end
        if (ep_c_valid[s]) begin
          assert (ep_c[s][ADDR_WIDTH+9+:9] == {2'd3, 2'd3, 4'(s), 1'b0});
          assert (ep_c[s][ADDR_WIDTH+3+:6] == f_tid_q[s]);
          assert (ep_c[s][3+:ADDR_WIDTH] == f_addr_q[s]);
          assert (ep_c[s][1+:2] == (f_error_q[s] ? coherence_pkg::Error : coherence_pkg::Consumed));
          assert (!ep_c[s][0]);
        end
        if (ep_request_valid[s] && ep_request_ready[s]) begin
          assert (!f_owned_q[s]);
          f_owned_q[s] <= 1'b1;
          f_d_q[s] <= 1'b0;
          f_g_q[s] <= 1'b0;
          f_c_q[s] <= 1'b0;
          f_addr_q[s] <= DataLanes[s] ? pf_req_addr : if_req_addr;
        end
        if (f_owned_q[s]) assert (ep_d[s][299+:ADDR_WIDTH] == f_addr_q[s]);
        if (f_d_fire && f_d.q.id == 4'(s)) begin
          assert (f_owned_q[s] && !f_d_q[s]);
          assert (f_d.q == {2'd3, 2'd3, 4'(s), 1'b0});
          assert (f_d.opcode == coherence_pkg::Prefetch && !f_d.non_alloc);
          assert (f_d.addr == f_addr_q[s]);
          assert (f_d.addr[$clog2(L2_LINE_BYTES)-1:0] == '0);
          f_d_q[s] <= 1'b1;
        end
        if (f_g_fire && ep_g_ready[s]) begin
          assert (f_owned_q[s] && f_d_q[s] && !f_g_q[s]);
          assert (f_g.addr == f_addr_q[s]);
          f_g_q[s] <= 1'b1;
          f_tid_q[s] <= f_g.tid;
          f_error_q[s] <= f_g.error;
        end
        if (f_c_fire && f_c.q.id == 4'(s)) begin
          assert (f_owned_q[s] && f_g_q[s] && !f_c_q[s]);
          assert (f_c.addr == f_addr_q[s] && f_c.tid == f_tid_q[s]);
          assert (f_c.status == (f_error_q[s] ? coherence_pkg::Error : coherence_pkg::Consumed));
          assert (!f_c.write_done);
          f_c_q[s] <= 1'b1;
        end
        if (f_u_fire && ep_u_ready[s]) begin
          assert (f_owned_q[s] && f_c_q[s]);
          assert (f_u.addr == f_addr_q[s] && f_u.tid == f_tid_q[s]);
          f_owned_q[s] <= 1'b0;
        end
      end
      if (f_past_valid && !$past(i_rst)) begin
        if ($past(o_d_valid && !i_d_ready)) assert (o_d_valid && o_d == $past(o_d));
        if ($past(o_c_valid && !i_c_ready)) assert (o_c_valid && o_c == $past(o_c));
      end
      cover (&f_owned_q && &f_d_q);
      cover (f_c_fire && f_c.status == coherence_pkg::Error);
      cover (u_fire);
      cover (&f_owned_q && o_c_valid && !i_c_ready && i_fatal_stop);
      cover (data_drop);
      if (IfTable) cover (if_drop);
    end
    if (f_past_valid && $past(i_rst)) assert (ep_live == '0);
    cover (f_past_valid && i_rst && (&f_owned_q));
  end
`endif
endmodule
