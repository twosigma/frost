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
 * Every port speaks the tagged line protocol (hw/rtl/lib/cache/README.md).
 * Fixed priority by port index: port 0 wins whenever it is requesting, port 1
 * when port 0 is not, and so on. frost_cache_hierarchy composes a 2:1
 * instance (walker > L1I) under a starvation-bounded 3:1 instance
 * (L1D > walker/L1I > DMA): a data miss stalls committed work, a walk
 * unblocks a load that is stalling commit, fetch runs ahead through its
 * buffer, and DMA drains a device's buffers.
 *
 * Ids compose: the downstream id is {port index, upstream id}, so responses
 * are steered back to their port by the prefix alone and the downstream
 * slave sees ids that are unique across every upstream master. There is no
 * grant lock. A request flows whenever the downstream is ready, however many
 * transactions are already in flight, and the loser of a cycle fires on a
 * later one. rdata is broadcast and qualified by the per-port response valid.
 *
 * STARVATION_LIMIT > 0 bounds the wait of a lower-priority port: a port that
 * has watched that many grants go to other ports while presenting a request
 * becomes starved and wins over every unstarved port (the lowest starved
 * port if several), then the fixed order resumes. Several ports can starve
 * together, so a port waits at most STARVATION_LIMIT + NUM_PORTS - 2
 * competing grants; that needs STARVATION_LIMIT >= NUM_PORTS - 1 (checked
 * at elaboration), or a lower starved port could re-starve before a higher
 * one is served. Counting grants rather than cycles keeps the bound under
 * downstream backpressure, where a cycle count would saturate for every
 * waiting port between two acceptances and the lowest would win each time.
 * 0 keeps pure fixed priority. The hierarchy's top arbiter uses the bound so
 * the DMA port has a progress guarantee under a sustained stream of
 * CPU-side misses.
 *
 * The maintenance provenance bit (passive observer classification) travels
 * with each request: the downstream sees the winning port's bit on every
 * fire, so a lower cache's traffic statistics stay exact whichever port wins.
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

  // Starvation bound: grants to other ports each port has waited through
  // with a request presented, saturating at the limit. Absent entirely when
  // the bound is 0.
  logic [NUM_PORTS-1:0] starved;
  if (STARVATION_LIMIT != 0) begin : gen_starvation
    localparam int unsigned WaitBits = $clog2(STARVATION_LIMIT + 1);
    logic [WaitBits-1:0] wait_q[NUM_PORTS];
    always_comb begin
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        starved[p] = i_up_req_valid[p] && (wait_q[p] == WaitBits'(STARVATION_LIMIT));
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
    assign starved = '0;
  end

  // Priority select: the lowest starved requesting port, else the lowest
  // requesting port index.
  logic [PortBits-1:0] sel;
  logic                any_valid;
  always_comb begin
    sel       = '0;
    any_valid = 1'b0;
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (i_up_req_valid[p]) begin
        sel       = PortBits'(p);
        any_valid = 1'b1;
      end
    end
    for (int p = int'(NUM_PORTS) - 1; p >= 0; p--) begin
      if (starved[p]) sel = PortBits'(p);
    end
  end

  // Pass-through request path: the winner's payload, the winner's fire.
  assign o_down_req_valid       = any_valid;
  assign o_down_req_write       = i_up_req_write[sel];
  assign o_down_req_addr        = i_up_req_addr[sel];
  assign o_down_req_wdata       = i_up_req_wdata[sel];
  assign o_down_req_wstrb       = i_up_req_wstrb[sel];
  assign o_down_req_id          = {sel, i_up_req_id[sel]};
  assign o_down_req_maintenance = i_up_req_maintenance[sel];

  // Ready mirrors the downstream ready so both seams fire in the same cycle
  // and payload capture lines up; a requesting port is ready only while it
  // is the selected one, which is the whole priority rule. With nothing
  // requesting every port sees the downstream ready.
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      o_up_req_ready[p] = i_down_req_ready && (!any_valid || (sel == PortBits'(p)));
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
