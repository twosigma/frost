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
 * when port 0 is not, and so on. frost_cache_hierarchy composes two 2:1
 * instances into a 3:1 tree with the order L1D > walker > L1I: a data miss
 * stalls committed work, a walk unblocks a load that is stalling commit, and
 * fetch runs ahead through its buffer.
 *
 * Ids compose: the downstream id is {port index, upstream id}, so responses
 * are steered back to their port by the prefix alone and the downstream
 * slave sees ids that are unique across every upstream master. There is no
 * grant lock. A request flows whenever the downstream is ready, however many
 * transactions are already in flight, and the loser of a cycle fires on a
 * later one. rdata is broadcast and qualified by the per-port response valid.
 *
 * The maintenance provenance bit (passive observer classification) travels
 * with each request: the downstream sees the winning port's bit on every
 * fire, so a lower cache's traffic statistics stay exact whichever port wins.
 */
module line_port_arbiter #(
    parameter  int unsigned NUM_PORTS  = 2,
    parameter  int unsigned ADDR_WIDTH = 32,
    parameter  int unsigned LINE_BYTES = 32,
    parameter  int unsigned UP_ID_BITS = 3,
    localparam int unsigned PortBits   = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1,
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
    if (NUM_PORTS > (1 << PortBits))
      $fatal(1, "line_port_arbiter: NUM_PORTS exceeds the port-index width");
  end

  // Priority select: the lowest requesting port index.
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
  // and payload capture lines up; a port's ready is masked by every
  // lower-index request, which is the whole priority rule. Port 0's ready
  // never looks at its own valid.
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      logic higher_priority_busy;
      higher_priority_busy = 1'b0;
      for (int q = 0; q < p; q++) higher_priority_busy |= i_up_req_valid[q];
      o_up_req_ready[p] = i_down_req_ready && !higher_priority_busy;
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
