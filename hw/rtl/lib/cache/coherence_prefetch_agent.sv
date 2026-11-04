// Copyright (c) 2026 John Goodacre.

/*
 * coherence_prefetch_agent reads ahead of the hart's ascending data streams
 * into the coherence home's L2. Accepted hart-0 data GetS and GetM requests
 * train l2_stream_prefetcher, including L2 hits. Each predicted line uses
 * source 3, class 3 and one of four coherence_request_endpoint instances.
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
    parameter int unsigned MAX_INFLIGHT = 4
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,

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
  localparam int unsigned Slots  = 4;
  localparam int unsigned IdBits = 2;

  coh_d_t train;
  assign train = i_train_d;
  wire train_demand = i_train_valid && !i_fatal_stop && train.q.src == 2'd0 &&
      train.q.port_class == 2'd0 &&
      (train.opcode == coherence_pkg::GetS || train.opcode == coherence_pkg::GetM);

  logic pf_req_valid, pf_req_ready, pf_resp_valid;
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
  );

  logic [Slots-1:0] ep_request_valid, ep_request_ready, ep_d_valid, ep_d_ready, ep_g_ready;
  logic [Slots-1:0] ep_grant_valid, ep_c_valid, ep_c_ready, ep_u_ready, ep_live;
  logic [Slots-1:0][ADDR_WIDTH+311:0] ep_d;
  logic [Slots-1:0][ADDR_WIDTH+274:0] ep_grant;
  logic [Slots-1:0][ ADDR_WIDTH+17:0] ep_c;

  for (genvar s = 0; s < Slots; s++) begin : gen_slot
    coh_d_t request;
    always_comb begin
      request = '0;
      request.opcode = coherence_pkg::Prefetch;
      request.q = {2'd3, 2'd3, 4'(s), 1'b0};
      request.addr = {pf_req_addr[ADDR_WIDTH-1:5], 5'b0};
      request.size = 3'd5;
    end
    assign ep_request_valid[s] = pf_req_valid && !i_fatal_stop && pf_req_id == IdBits'(s);
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
        .i_done_status(ep_grant[s].error ? coherence_pkg::Error : coherence_pkg::Consumed),
        .i_write_done(1'b0),
        .i_error_disposed(ep_grant[s].error),
        .o_c_valid(ep_c_valid[s]),
        .o_c_selected(),
        .i_c_ready(ep_c_ready[s]),
        .o_c(ep_c[s]),
        .i_u_valid(i_u_valid),
        .o_u_ready(ep_u_ready[s]),
        .i_u(i_u),
        .o_live(ep_live[s])
    );
  end

  assign pf_req_ready = ep_request_ready[pf_req_id] && !i_fatal_stop;
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

  if (MAX_INFLIGHT < 1 || MAX_INFLIGHT > Slots ||
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
      if (pf_req_valid && !i_fatal_stop) assert (!ep_live[pf_req_id] || !pf_req_ready);
    end
  end
`endif
endmodule
