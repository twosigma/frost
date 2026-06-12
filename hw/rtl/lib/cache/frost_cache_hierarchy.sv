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
 * frost_cache_hierarchy -- the per-board cache hierarchy, as one module.
 *
 * Instantiates L1 (BRAM) and, when HAS_L2 != 0, L2 (URAM) behind it; the
 * upstream and downstream ports are the same line protocol as frost_cache, so
 * the hierarchy is itself a line-port slave (up) / master (down):
 *
 *   Genesys2 (HAS_L2=0):  up -> L1(BRAM) -> down (DDR3)
 *   X3       (HAS_L2=1):  up -> L1(BRAM) -> L2(URAM) -> down (DDR4)
 *
 * The L1 is identical on both boards and "none the wiser" what backs it.
 * Both shapes are exercised by the cocotb cache unit tests.
 */
module frost_cache_hierarchy #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L1_DATA_WRITE_LATENCY = 1,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned L2_DATA_READ_LATENCY = 6,
    parameter int unsigned L2_DATA_WRITE_LATENCY = 2
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave).
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    output logic                    o_up_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Downstream line port (master) -- to the AXI bridge / main memory.
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    input  logic                    i_down_resp_valid,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);

  // L1 downstream wires (to L2 or straight to the hierarchy's downstream port).
  logic                    l1_down_req_valid;
  logic                    l1_down_req_ready;
  logic                    l1_down_req_write;
  logic [  ADDR_WIDTH-1:0] l1_down_req_addr;
  logic [LINE_BYTES*8-1:0] l1_down_req_wdata;
  logic [  LINE_BYTES-1:0] l1_down_req_wstrb;
  logic                    l1_down_resp_valid;
  logic [LINE_BYTES*8-1:0] l1_down_resp_rdata;

  frost_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1_CACHE_BYTES),
      .LINE_BYTES(LINE_BYTES),
      .DATA_MEMORY_PRIMITIVE("block"),
      .DATA_READ_LATENCY(L1_DATA_READ_LATENCY),
      .DATA_WRITE_LATENCY(L1_DATA_WRITE_LATENCY)
  ) l1_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid(i_up_req_valid),
      .o_up_req_ready(o_up_req_ready),
      .i_up_req_write(i_up_req_write),
      .i_up_req_addr(i_up_req_addr),
      .i_up_req_wdata(i_up_req_wdata),
      .i_up_req_wstrb(i_up_req_wstrb),
      .o_up_resp_valid(o_up_resp_valid),
      .o_up_resp_rdata(o_up_resp_rdata),
      .o_down_req_valid(l1_down_req_valid),
      .i_down_req_ready(l1_down_req_ready),
      .o_down_req_write(l1_down_req_write),
      .o_down_req_addr(l1_down_req_addr),
      .o_down_req_wdata(l1_down_req_wdata),
      .o_down_req_wstrb(l1_down_req_wstrb),
      .i_down_resp_valid(l1_down_resp_valid),
      .i_down_resp_rdata(l1_down_resp_rdata)
  );

  if (HAS_L2 != 0) begin : gen_l2
    frost_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_SIZE_BYTES(L2_CACHE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .DATA_MEMORY_PRIMITIVE("ultra"),
        .DATA_READ_LATENCY(L2_DATA_READ_LATENCY),
        .DATA_WRITE_LATENCY(L2_DATA_WRITE_LATENCY)
    ) l2_cache (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_up_req_valid(l1_down_req_valid),
        .o_up_req_ready(l1_down_req_ready),
        .i_up_req_write(l1_down_req_write),
        .i_up_req_addr(l1_down_req_addr),
        .i_up_req_wdata(l1_down_req_wdata),
        .i_up_req_wstrb(l1_down_req_wstrb),
        .o_up_resp_valid(l1_down_resp_valid),
        .o_up_resp_rdata(l1_down_resp_rdata),
        .o_down_req_valid(o_down_req_valid),
        .i_down_req_ready(i_down_req_ready),
        .o_down_req_write(o_down_req_write),
        .o_down_req_addr(o_down_req_addr),
        .o_down_req_wdata(o_down_req_wdata),
        .o_down_req_wstrb(o_down_req_wstrb),
        .i_down_resp_valid(i_down_resp_valid),
        .i_down_resp_rdata(i_down_resp_rdata)
    );
  end else begin : gen_no_l2
    assign o_down_req_valid   = l1_down_req_valid;
    assign l1_down_req_ready  = i_down_req_ready;
    assign o_down_req_write   = l1_down_req_write;
    assign o_down_req_addr    = l1_down_req_addr;
    assign o_down_req_wdata   = l1_down_req_wdata;
    assign o_down_req_wstrb   = l1_down_req_wstrb;
    assign l1_down_resp_valid = i_down_resp_valid;
    assign l1_down_resp_rdata = i_down_resp_rdata;
  end

endmodule : frost_cache_hierarchy
