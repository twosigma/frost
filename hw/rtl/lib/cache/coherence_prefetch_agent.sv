// Copyright (c) 2026 John Goodacre.

/*
 * coherence_prefetch_agent reads ahead of the hart's ascending data streams
 * into the coherence home's L2. Accepted hart-0 data GetS and GetM requests
 * train l2_stream_prefetcher, including L2 hits. Each predicted line uses
 * source 3, class 3 and one of up to four coherence_request_endpoint instances.
 *
 * A Prefetch miss returns a data-less GrantAck after its fill completes.
 * Target data needs no probe; victim replacement can recall private data.
 * Each identity stays occupied through G, C and U. Successful grants finish
 * with Consumed and errored grants with Error. Predictions stay within the
 * training access's 4 KiB page. Fatal stop blocks training and endpoint
 * request admission. Occupied identities keep their protocol state.
 */

`include "coherence_types.svh"

module coherence_prefetch_agent #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned STREAMS = 4,
    parameter int unsigned DISTANCE = 8,
    parameter int unsigned MAX_INFLIGHT = 3
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_pause,

    // The hart's D channel, observed: a request counts on the cycle the home's
    // arbiter takes it.
    input logic i_train_valid,
    input logic [ADDR_WIDTH+311:0] i_train_d,

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
  // The predictor allocates only the lowest MAX_INFLIGHT identities.
  localparam int unsigned Slots   = MAX_INFLIGHT;
  localparam int unsigned IdBits  = 2;
  localparam int unsigned ArbBits = Slots > 1 ? $clog2(Slots) : 1;

  coh_d_t train;
  assign train = i_train_d;
  wire train_demand = i_train_valid && !i_fatal_stop && train.q.src == 2'd0 &&
      train.q.port_class == 2'd0 &&
      (train.opcode == coherence_pkg::GetS || train.opcode == coherence_pkg::GetM);

  logic pf_req_valid, pf_req_ready, pf_resp_valid;
`ifdef FORMAL
  logic [(1<<IdBits)-1:0] pf_busy;
  logic [Slots-1:0][2:0] f_phase;
  logic [ArbBits-1:0] f_d_next, f_c_next;
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
      .i_miss_addr(train.addr),
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
  logic [Slots-1:0] d_selected, c_selected;
  logic [Slots-1:0][ADDR_WIDTH+311:0] ep_d;
  logic [Slots-1:0][ADDR_WIDTH+274:0] ep_grant;
  logic [Slots-1:0][ ADDR_WIDTH+17:0] ep_c;

  for (genvar s = 0; s < Slots; s++) begin : gen_slot
    coh_d_t request;
    coh_g_t endpoint_grant;
    assign endpoint_grant = ep_grant[s];
    always_comb begin
      request = '0;
      request.opcode = coherence_pkg::Prefetch;
      request.q = {2'd3, 2'd3, 4'(s), 1'b0};
      request.addr = {pf_req_addr[ADDR_WIDTH-1:5], 5'b0};
      request.size = 3'd5;
    end
    assign ep_request_valid[s] =
        pf_req_valid && !i_fatal_stop && !i_pause && pf_req_id == IdBits'(s);
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

  assign pf_req_ready = ep_request_ready[ArbBits'(pf_req_id)] && !i_fatal_stop && !i_pause;
  assign o_g_ready = |ep_g_ready;
  assign o_u_ready = |ep_u_ready;

  // The U for an id frees that id in the prefetcher.
  logic [IdBits-1:0] u_slot;
  always_comb begin
    u_slot = '0;
    for (int s = 0; s < int'(Slots); s++) if (ep_u_ready[s]) u_slot = IdBits'(s);
  end
  assign pf_resp_valid = i_u_valid && |ep_u_ready;
  assign pf_resp_id = u_slot;

  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(Slots)
  ) demands (
      .i_clk,
      .i_rst,
      .i_valid(ep_d_valid),
      .o_ready(ep_d_ready),
      .i_payload(ep_d),
      .o_valid(o_d_valid),
      .o_offer(),
      .o_selected(d_selected),
      .i_ready(i_d_ready),
      .o_payload(o_d)
`ifdef FORMAL,
      .o_formal_next(f_d_next)
`endif
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
      .i_payload(ep_c),
      .o_valid(o_c_valid),
      .o_offer(),
      .o_selected(c_selected),
      .i_ready(i_c_ready),
      .o_payload(o_c)
`ifdef FORMAL,
      .o_formal_next(f_c_next)
`endif
  );

  if (MAX_INFLIGHT < 1 || MAX_INFLIGHT > 4 ||
      (L2_LINE_BYTES != 32 && L2_LINE_BYTES != 64)) begin : gen_invalid_config
    initial
      $fatal(1, "coherence_prefetch_agent: MAX_INFLIGHT must be 1..4 and L2_LINE_BYTES 32 or 64");
  end

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst) begin
      // A U names one endpoint, and an id is loaded only into an idle endpoint.
      assert ($countones(ep_u_ready & {Slots{i_u_valid}}) <= 1);
      assert ($countones(ep_g_ready & {Slots{i_g_valid}}) <= 1);
      if (pf_req_valid && !i_fatal_stop) assert (!ep_live[ArbBits'(pf_req_id)] || !pf_req_ready);
    end
  end
`endif
`ifdef FORMAL
  // Idle ports above the cap do not change the D or C arbitration order.
  logic f_ref_d_valid, f_ref_c_valid;
  logic [3:0] f_ref_d_ready, f_ref_c_ready, f_ref_d_selected, f_ref_c_selected;
  logic [1:0] f_ref_d_next, f_ref_c_next;
  logic [ADDR_WIDTH+311:0] f_ref_d;
  logic [ ADDR_WIDTH+17:0] f_ref_c;
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 312),
      .PORTS(4)
  ) f_reference_demands (
      .i_clk,
      .i_rst,
      .i_valid(4'(ep_d_valid)),
      .o_ready(f_ref_d_ready),
      .i_payload((4 * (ADDR_WIDTH + 312))'(ep_d)),
      .o_valid(f_ref_d_valid),
      .o_offer(),
      .o_selected(f_ref_d_selected),
      .i_ready(i_d_ready),
      .o_payload(f_ref_d),
      .o_formal_next(f_ref_d_next)
  );
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(4),
      .HOLD_VALID(1)
  ) f_reference_completions (
      .i_clk,
      .i_rst,
      .i_valid(4'(ep_c_valid)),
      .o_ready(f_ref_c_ready),
      .i_payload((4 * (ADDR_WIDTH + 18))'(ep_c)),
      .o_valid(f_ref_c_valid),
      .o_offer(),
      .o_selected(f_ref_c_selected),
      .i_ready(i_c_ready),
      .o_payload(f_ref_c),
      .o_formal_next(f_ref_c_next)
  );
  logic f_past_valid = 1'b0;
  logic [Slots-1:0] f_owned_q, f_d_q, f_g_q, f_c_q, f_error_q;
  logic [Slots-1:0][ADDR_WIDTH-1:0] f_addr_q;
  logic [Slots-1:0][5:0] f_tid_q;
  coh_d_t f_d;
  coh_g_t f_g;
  coh_c_t f_c;
  coh_u_t f_u;
  assign f_d = o_d;
  assign f_g = i_g;
  assign f_c = o_c;
  assign f_u = i_u;
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
      assert (int'(f_ref_d_next) <= Slots && int'(f_ref_c_next) <= Slots);
      assert (f_d_next == ArbBits'(int'(f_ref_d_next) == Slots ? 0 : int'(f_ref_d_next)));
      assert (f_c_next == ArbBits'(int'(f_ref_c_next) == Slots ? 0 : int'(f_ref_c_next)));
      assert (f_ref_d_selected == 4'(d_selected));
      assert (f_ref_c_selected == 4'(c_selected));
      assert (f_ref_d_ready == 4'(ep_d_ready));
      assert (f_ref_c_ready == 4'(ep_c_ready));
      assert (f_ref_d_valid == o_d_valid && f_ref_c_valid == o_c_valid);
      if (o_d_valid) assert (f_ref_d == o_d);
      if (o_c_valid) assert (f_ref_c == o_c);
      assert (f_owned_q == ep_live);
      assert (pf_busy == 4'(ep_live | (pf_req_valid ? Slots'(1) << pf_req_id : Slots'(0))));
      assert ($countones(f_owned_q) <= MAX_INFLIGHT);
      if (pf_req_valid) begin
        assert (int'(pf_req_id) < MAX_INFLIGHT);
        assert (!ep_live[ArbBits'(pf_req_id)]);
      end
      assert ($onehot0(ep_g_ready));
      assert ($onehot0(ep_u_ready));
      assert (!(i_fatal_stop || i_pause) || !(|ep_request_valid));
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
          f_addr_q[s] <= pf_req_addr;
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
      cover (f_u_fire);
      cover (&f_owned_q && o_c_valid && !i_c_ready && i_fatal_stop);
    end
    if (f_past_valid && $past(i_rst)) assert (ep_live == '0);
    cover (f_past_valid && i_rst && (&f_owned_q));
  end
`endif
endmodule
