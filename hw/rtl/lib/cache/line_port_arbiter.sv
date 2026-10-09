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

/*
 * line_port_arbiter: N:1 arbiter for tagged line ports.
 *
 * NUM_PORTS upstream line-port slaves multiplexed onto one downstream master.
 * Every port speaks the tagged line protocol ("Line protocol" in
 * hw/rtl/lib/cache/README.md). Fixed priority by port index: port 0 wins
 * whenever it is requesting, port 1 when port 0 is not, and so on.
 * frost_cache_hierarchy composes a 2:1 instance (walker over L1I) under a
 * starvation-bounded 3:1 instance (L1D, then that pair, then DMA).
 *
 * The downstream id is {port index, upstream id}, so responses are steered
 * back to their port by the prefix alone and the downstream slave sees ids
 * that are unique across every upstream master. There is no grant lock. A
 * request flows whenever the downstream is ready, however many transactions
 * are already in flight, and the loser of a cycle fires on a later one.
 * rdata is broadcast and qualified by the per-port response valid.
 *
 * STARVATION_LIMIT > 0 bounds the wait of a lower-priority port. A port that
 * has watched that many grants go to other ports while presenting a request
 * is starved and wins over every port that is not (the lowest starved port if
 * several), then the fixed order resumes. Several ports can starve together,
 * so a port waits at most STARVATION_LIMIT + NUM_PORTS - 2 competing grants.
 * That needs STARVATION_LIMIT >= NUM_PORTS - 1 (checked at elaboration), or a
 * lower-index starved port could starve again before a higher-index one is
 * served. The bound counts grants, not cycles: under downstream backpressure
 * a cycle count would saturate for every waiting port between two
 * acceptances, and the lowest index would win each time. 0 keeps pure fixed
 * priority. The hierarchy's top arbiter uses the bound to give the DMA port
 * a progress guarantee under a sustained stream of CPU-side misses.
 *
 * The maintenance bit travels with the granted request, so a lower cache can
 * leave fence.i writeback traffic out of its performance counters whichever
 * port wins.
 */
module line_port_arbiter #(
    parameter int unsigned NUM_PORTS = 2,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned STARVATION_LIMIT = 0,
    localparam int unsigned PortBits = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1,
    localparam int unsigned DownIdBits = UP_ID_BITS + PortBits
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line ports (slaves), packed per port; index 0 has priority.
    input  logic [NUM_PORTS-1:0]                   i_up_req_valid,
    output logic [NUM_PORTS-1:0]                   o_up_req_ready,
    input  logic [NUM_PORTS-1:0]                   i_up_req_write,
    input  logic [NUM_PORTS-1:0][  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [NUM_PORTS-1:0][LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [NUM_PORTS-1:0][  LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [NUM_PORTS-1:0][  UP_ID_BITS-1:0] i_up_req_id,
    input  logic [NUM_PORTS-1:0]                   i_up_req_maintenance,
    output logic [NUM_PORTS-1:0]                   o_up_resp_valid,
    output logic [NUM_PORTS-1:0][  UP_ID_BITS-1:0] o_up_resp_id,
    output logic [NUM_PORTS-1:0][LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Downstream line port (master).
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [  DownIdBits-1:0] o_down_req_id,
    output logic                    o_down_req_maintenance,
    input  logic                    i_down_resp_valid,
    input  logic [  DownIdBits-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);

  initial begin
    if (NUM_PORTS < 1) $fatal(1, "line_port_arbiter: NUM_PORTS must be >= 1");
    if ((STARVATION_LIMIT != 0) && (STARVATION_LIMIT + 1 < NUM_PORTS))
      $fatal(1, "line_port_arbiter: STARVATION_LIMIT must be >= NUM_PORTS - 1 for the bound");
    if (NUM_PORTS > (1 << PortBits))
      $fatal(1, "line_port_arbiter: NUM_PORTS exceeds the port-index width");
  end

  // Starvation bound: per port, the grants to other ports it has waited
  // through while presenting a request, saturating at the limit. Absent
  // entirely when the bound is 0.
  logic [NUM_PORTS-1:0] starved;
  (* dont_touch = "true" *)logic [NUM_PORTS-1:0] at_limit;
  if (STARVATION_LIMIT != 0) begin : gen_starvation
    localparam int unsigned WaitBits = $clog2(STARVATION_LIMIT + 1);
    logic [WaitBits-1:0] wait_q[NUM_PORTS];
    // The registered half of starved, kept as its own net so the grant below
    // is a single level from the request valids (see there).
    always_comb begin
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        at_limit[p] = (wait_q[p] == WaitBits'(STARVATION_LIMIT));
        starved[p]  = i_up_req_valid[p] && at_limit[p];
      end
    end
    always_ff @(posedge i_clk) begin
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        if (i_rst || !i_up_req_valid[p] || o_up_req_ready[p]) begin
          wait_q[p] <= '0;
        end else if (o_down_req_valid && i_down_req_ready &&
                     (wait_q[p] != WaitBits'(STARVATION_LIMIT))) begin
          wait_q[p] <= wait_q[p] + 1'b1;
        end
      end
    end
  end else begin : gen_no_starvation
    assign starved  = '0;
    assign at_limit = '0;
  end

  // Grant, one-hot: the lowest starved requesting port, else the lowest
  // requesting port, else port 0 while nothing requests (the idle payload is
  // then port 0's, as an encoded select of 0 presents it; ready and the fire
  // are qualified by any_valid). Each grant bit is a flat function of the
  // port valids and limit flags, not a priority chain, and synthesis keeps
  // the nets, so a request valid reaches the downstream payload through one
  // grant level and one select level. The downstream (the L2 in the full
  // system) makes its own accept decision from that payload in the same
  // cycle. p_grant_is_priority checks the grant against the priority rule in
  // its encoded form.
  (* dont_touch = "true" *)logic [NUM_PORTS-1:0] grant;
  logic [NUM_PORTS-1:0] grant_generic;
  logic [NUM_PORTS-1:0] valid_below, starved_below;  // any lower port
  logic [PortBits-1:0] sel;  // the grant's index, for the id prefix
  logic any_valid, any_starved;
  always_comb begin
    any_valid   = |i_up_req_valid;
    any_starved = |starved;
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      valid_below[p]   = 1'b0;
      starved_below[p] = 1'b0;
      for (int q = 0; q < p; q++) begin
        valid_below[p] |= i_up_req_valid[q];
        starved_below[p] |= starved[q];
      end
      grant_generic[p] = (starved[p] && !starved_below[p]) ||
          (!any_starved && !valid_below[p] && (i_up_req_valid[p] || ((p == 0) && !any_valid)));
    end
  end

`ifdef FROST_XILINX_PRIMS
  if ((NUM_PORTS == 3) && (STARVATION_LIMIT != 0)) begin : gen_three_port_grant
    // Three request bits plus three registered limit flags fit one LUT6 per
    // grant bit. Explicit LUTs keep synthesis from sharing the any-starved
    // term, which would add a logic level between the late request valid and
    // the downstream accept.
    function automatic logic [63:0] grant_truth(input int winner);
      logic [2:0] requests, limits;
      int selected;
      for (int row = 0; row < 64; row++) begin
        requests = 3'(row);
        limits   = 3'(row >> 3);
        selected = 0;
        for (int port = 2; port >= 0; port--) begin
          if (requests[port]) selected = port;
        end
        for (int port = 2; port >= 0; port--) begin
          if (requests[port] && limits[port]) selected = port;
        end
        grant_truth[row] = selected == winner;
      end
    endfunction
    for (genvar port = 0; port < 3; port++) begin : gen_port
      (* dont_touch = "true" *) LUT6 #(
          .INIT(grant_truth(port))
      ) grant_lut (
          .I0(i_up_req_valid[0]),
          .I1(i_up_req_valid[1]),
          .I2(i_up_req_valid[2]),
          .I3(at_limit[0]),
          .I4(at_limit[1]),
          .I5(at_limit[2]),
          .O (grant[port])
      );
    end
  end else begin : gen_other_grant
    assign grant = grant_generic;
  end
`else
  assign grant = grant_generic;
`endif
  always_comb begin
    sel = '0;
    for (int p = 0; p < int'(NUM_PORTS); p++) if (grant[p]) sel |= PortBits'(p);
  end

`ifdef LINE_ARBITER_GRANT_PROOF
  logic [PortBits-1:0] f_sel;
  always_comb begin
    f_sel = '0;
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (i_up_req_valid[p]) f_sel = PortBits'(p);
    end
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (starved[p]) f_sel = PortBits'(p);
    end
    assert (grant == (NUM_PORTS'(1) << f_sel));
  end
`endif

  // Pass-through request path: the granted port's payload, AND-OR selected by
  // the one-hot grant (one LUT level per bit for up to three ports).
  logic dn_write, dn_maint;
  logic [  ADDR_WIDTH-1:0] dn_addr;
  logic [LINE_BYTES*8-1:0] dn_wdata;
  logic [  LINE_BYTES-1:0] dn_wstrb;
  logic [  UP_ID_BITS-1:0] dn_id;
  always_comb begin
    dn_write = 1'b0;
    dn_maint = 1'b0;
    dn_addr  = '0;
    dn_wdata = '0;
    dn_wstrb = '0;
    dn_id    = '0;
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      dn_write |= grant[p] & i_up_req_write[p];
      dn_maint |= grant[p] & i_up_req_maintenance[p];
      dn_addr |= {ADDR_WIDTH{grant[p]}} & i_up_req_addr[p];
      dn_wdata |= {(LINE_BYTES * 8) {grant[p]}} & i_up_req_wdata[p];
      dn_wstrb |= {LINE_BYTES{grant[p]}} & i_up_req_wstrb[p];
      dn_id |= {UP_ID_BITS{grant[p]}} & i_up_req_id[p];
    end
  end
  assign o_down_req_valid       = any_valid;
  assign o_down_req_write       = dn_write;
  assign o_down_req_addr        = dn_addr;
  assign o_down_req_wdata       = dn_wdata;
  assign o_down_req_wstrb       = dn_wstrb;
  assign o_down_req_id          = {sel, dn_id};
  assign o_down_req_maintenance = dn_maint;

  // Ready mirrors the downstream ready, so an upstream fire and its
  // downstream fire happen in the same cycle. A requesting port is ready only
  // while it holds the grant, which is what enforces the priority. With
  // nothing requesting, every port sees the downstream ready.
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      o_up_req_ready[p] = i_down_req_ready && (!any_valid || grant[p]);
    end
  end

  // Response steering by the port prefix of the id; rdata broadcast.
  logic [PortBits-1:0] resp_port;
  assign resp_port = i_down_resp_id[DownIdBits-1-:PortBits];
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      o_up_resp_valid[p] = i_down_resp_valid && (resp_port == PortBits'(p));
      o_up_resp_id[p]    = i_down_resp_id[UP_ID_BITS-1:0];
      o_up_resp_rdata[p] = i_down_resp_rdata;
    end
  end

`ifndef SYNTHESIS
  // The priority rule in its encoded form: the lowest requesting port, then
  // the lowest starved port over it, 0 when idle. The flat grant above must
  // agree with it every cycle.
  logic [PortBits-1:0] chk_sel;
  always_comb begin
    chk_sel = '0;
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (i_up_req_valid[p]) chk_sel = PortBits'(p);
    end
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (starved[p]) chk_sel = PortBits'(p);
    end
  end

  // Protocol checks (simulation only): every response carries a port prefix
  // that exists, and the per-port in-flight count never goes negative,
  // because the downstream may only answer what was fired.
  logic [NUM_PORTS-1:0] chk_fire, chk_done;
  logic [NUM_PORTS-1:0][7:0] inflight_q;
  assign chk_fire = i_up_req_valid & o_up_req_ready;
  assign chk_done = o_up_resp_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      inflight_q <= '0;
    end else begin
      p_grant_is_priority : assert ((sel == chk_sel) && (grant == (NUM_PORTS'(1) << chk_sel)));
      if (i_down_resp_valid && (32'(resp_port) >= NUM_PORTS))
        $error("line_port_arbiter: response for nonexistent port %0d", resp_port);
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        if (chk_done[p] && inflight_q[p] == 8'd0)
          $error("line_port_arbiter: response on port %0d with nothing in flight", p);
        inflight_q[p] <= inflight_q[p] + 8'(chk_fire[p]) - 8'(chk_done[p]);
      end
    end
  end
`endif

endmodule : line_port_arbiter
