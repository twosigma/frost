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
 * line_port_arbiter -- 2:1 arbiter for single-outstanding line ports.
 *
 * Two upstream line-port slaves multiplexed onto one downstream master;
 * every port speaks the frost_cache line protocol (see frost_cache.sv).
 * Port 0 has fixed priority: FROST wires the D-side L1 there (its misses
 * stall committed work) and the I-side L1 to port 1 (fetch runs ahead
 * through a buffer and can absorb the wait).
 *
 * Single-outstanding: a granted request owns the downstream port until its
 * response pulse returns; the loser's ready stays low and its held request
 * fires afterward. While a winner is still presenting (downstream not yet
 * ready), the grant may switch to a later-arriving port-0 request -- legal
 * because slaves capture payload only at the fire and masters hold valid
 * until ready.
 *
 * The line protocol has no transaction IDs, so a grant register steers the
 * single (unbackpressureable) resp_valid pulse back to the owner; rdata is
 * broadcast and qualified by the per-side valid. The per-side port groups
 * are the stable seam: hit-under-miss / multiple-outstanding can replace
 * the internals later without re-plumbing upstream or downstream.
 */
module line_port_arbiter #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port 0 (slave; fixed priority).
    input  logic                    i_up0_req_valid,
    output logic                    o_up0_req_ready,
    input  logic                    i_up0_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up0_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up0_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up0_req_wstrb,
    output logic                    o_up0_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up0_resp_rdata,

    // Upstream line port 1 (slave).
    input  logic                    i_up1_req_valid,
    output logic                    o_up1_req_ready,
    input  logic                    i_up1_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up1_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up1_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up1_req_wstrb,
    output logic                    o_up1_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up1_resp_rdata,

    // Downstream line port (master).
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    input  logic                    i_down_resp_valid,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);

  // Transaction-in-flight tracking: set at the downstream fire, cleared by
  // the response pulse; owner_q remembers which side fired.
  logic busy_q;
  logic owner_q;  // 0 = port 0, 1 = port 1

  // Payload select while idle: port 0 wins whenever it is requesting.
  logic sel1;
  assign sel1 = !i_up0_req_valid;

  // Pass-through request path: the winner's payload, the winner's fire.
  assign o_down_req_valid = !busy_q && (i_up0_req_valid || i_up1_req_valid);
  assign o_down_req_write = sel1 ? i_up1_req_write : i_up0_req_write;
  assign o_down_req_addr = sel1 ? i_up1_req_addr : i_up0_req_addr;
  assign o_down_req_wdata = sel1 ? i_up1_req_wdata : i_up0_req_wdata;
  assign o_down_req_wstrb = sel1 ? i_up1_req_wstrb : i_up0_req_wstrb;

  // Ready mirrors the downstream ready so both seams fire in the same cycle
  // and payload capture lines up. Port 0's ready never looks at its own
  // valid ("ready may wait for valid" style, like the FSM-state readies of
  // the other slaves); port 1's is additionally masked by port 0's request,
  // which is the whole priority rule.
  assign o_up0_req_ready = !busy_q && i_down_req_ready;
  assign o_up1_req_ready = !busy_q && i_down_req_ready && !i_up0_req_valid;

  logic down_fire;
  assign down_fire = o_down_req_valid && i_down_req_ready;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      busy_q  <= 1'b0;
      owner_q <= 1'b0;
    end else if (down_fire) begin
      busy_q  <= 1'b1;
      owner_q <= sel1;
    end else if (i_down_resp_valid) begin
      busy_q <= 1'b0;
    end
  end

  // Response steering: the single pulse goes to the owner; rdata is
  // broadcast and qualified by the valid.
  assign o_up0_resp_valid = busy_q && !owner_q && i_down_resp_valid;
  assign o_up1_resp_valid = busy_q && owner_q && i_down_resp_valid;
  assign o_up0_resp_rdata = i_down_resp_rdata;
  assign o_up1_resp_rdata = i_down_resp_rdata;

`ifndef SYNTHESIS
  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_down_resp_valid && !busy_q)
        $error("line_port_arbiter: downstream response with no transaction in flight");
      if (down_fire && busy_q)
        $error("line_port_arbiter: request fired while a transaction is in flight");
    end
  end
`endif

endmodule : line_port_arbiter
