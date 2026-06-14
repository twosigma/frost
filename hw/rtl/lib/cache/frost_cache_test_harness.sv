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
 * frost_cache_test_harness -- cocotb unit-bench top for the cache hierarchy.
 *
 * Exposes both upstream line ports (data side + instruction side) and wires
 * the SAME backside topology the CPU integration uses:
 * frost_cache_hierarchy -> line_port_axi_bridge -> axi_behavioral_memory.
 * The bench drives raw line transactions and checks them against a reference
 * model; -G parameters select the board shape (HAS_L2) and shrink the caches
 * so eviction/thrash paths are cheap to hit.
 */
module frost_cache_test_harness #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 1024,
    parameter int unsigned L1I_CACHE_BYTES = 1024,
    parameter int unsigned L2_CACHE_BYTES = 4096,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L2_DATA_READ_LATENCY = 6,
    parameter int unsigned L2_DATA_WRITE_LATENCY = 2,
    parameter logic [31:0] BASE_ADDR = 32'h8000_0000,
    parameter int unsigned MEM_BYTES = 4 * 1024 * 1024,
    parameter int unsigned MEM_LATENCY = 12
) (
    input  logic                    i_clk,
    input  logic                    i_rst,
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    output logic                    o_up_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,
    input  logic                    i_iup_req_valid,
    output logic                    o_iup_req_ready,
    input  logic                    i_iup_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_iup_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_iup_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_iup_req_wstrb,
    output logic                    o_iup_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_iup_resp_rdata,
    input  logic                    i_fence_sync,
    output logic                    o_fence_done
);

  logic stack_down_req_valid, stack_down_req_ready, stack_down_req_write;
  logic [ADDR_WIDTH-1:0] stack_down_req_addr;
  logic [LINE_BYTES*8-1:0] stack_down_req_wdata;
  logic [LINE_BYTES-1:0] stack_down_req_wstrb;
  logic stack_down_resp_valid;
  logic [LINE_BYTES*8-1:0] stack_down_resp_rdata;

  frost_cache_hierarchy #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .HAS_L2(HAS_L2),
      .L1_CACHE_BYTES(L1_CACHE_BYTES),
      .L1_DATA_READ_LATENCY(L1_DATA_READ_LATENCY),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .L2_CACHE_BYTES(L2_CACHE_BYTES),
      .L2_DATA_READ_LATENCY(L2_DATA_READ_LATENCY),
      .L2_DATA_WRITE_LATENCY(L2_DATA_WRITE_LATENCY)
  ) cache_hierarchy (
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
      .i_iup_req_valid(i_iup_req_valid),
      .o_iup_req_ready(o_iup_req_ready),
      .i_iup_req_write(i_iup_req_write),
      .i_iup_req_addr(i_iup_req_addr),
      .i_iup_req_wdata(i_iup_req_wdata),
      .i_iup_req_wstrb(i_iup_req_wstrb),
      .o_iup_resp_valid(o_iup_resp_valid),
      .o_iup_resp_rdata(o_iup_resp_rdata),
      .i_fence_sync(i_fence_sync),
      .o_fence_done(o_fence_done),
      .o_down_req_valid(stack_down_req_valid),
      .i_down_req_ready(stack_down_req_ready),
      .o_down_req_write(stack_down_req_write),
      .o_down_req_addr(stack_down_req_addr),
      .o_down_req_wdata(stack_down_req_wdata),
      .o_down_req_wstrb(stack_down_req_wstrb),
      .i_down_resp_valid(stack_down_resp_valid),
      .i_down_resp_rdata(stack_down_resp_rdata)
  );

  logic axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
  logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast;
  logic [31:0] axi_awaddr, axi_araddr;
  logic [7:0] axi_awlen, axi_arlen;
  logic [2:0] axi_awsize, axi_arsize;
  logic [1:0] axi_awburst, axi_arburst, axi_bresp, axi_rresp;
  logic [LINE_BYTES*8-1:0] axi_wdata, axi_rdata;
  logic [LINE_BYTES-1:0] axi_wstrb;
  logic axi_wlast;

  line_port_axi_bridge #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .BASE_ADDR (BASE_ADDR)
  ) bridge (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_req_valid(stack_down_req_valid),
      .o_req_ready(stack_down_req_ready),
      .i_req_write(stack_down_req_write),
      .i_req_addr(stack_down_req_addr),
      .i_req_wdata(stack_down_req_wdata),
      .i_req_wstrb(stack_down_req_wstrb),
      .o_resp_valid(stack_down_resp_valid),
      .o_resp_rdata(stack_down_resp_rdata),
      .o_axi_awvalid(axi_awvalid),
      .i_axi_awready(axi_awready),
      .o_axi_awaddr(axi_awaddr),
      .o_axi_awlen(axi_awlen),
      .o_axi_awsize(axi_awsize),
      .o_axi_awburst(axi_awburst),
      .o_axi_wvalid(axi_wvalid),
      .i_axi_wready(axi_wready),
      .o_axi_wdata(axi_wdata),
      .o_axi_wstrb(axi_wstrb),
      .o_axi_wlast(axi_wlast),
      .i_axi_bvalid(axi_bvalid),
      .o_axi_bready(axi_bready),
      .i_axi_bresp(axi_bresp),
      .o_axi_arvalid(axi_arvalid),
      .i_axi_arready(axi_arready),
      .o_axi_araddr(axi_araddr),
      .o_axi_arlen(axi_arlen),
      .o_axi_arsize(axi_arsize),
      .o_axi_arburst(axi_arburst),
      .i_axi_rvalid(axi_rvalid),
      .o_axi_rready(axi_rready),
      .i_axi_rdata(axi_rdata),
      .i_axi_rresp(axi_rresp),
      .i_axi_rlast(axi_rlast)
  );

  axi_behavioral_memory #(
      .LINE_BYTES(LINE_BYTES),
      .MEM_BYTES(MEM_BYTES),
      .LATENCY(MEM_LATENCY),
      .USE_INIT_FILE(1'b0)
  ) main_memory (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_axi_awvalid(axi_awvalid),
      .o_axi_awready(axi_awready),
      .i_axi_awaddr(axi_awaddr),
      .i_axi_awlen(axi_awlen),
      .i_axi_wvalid(axi_wvalid),
      .o_axi_wready(axi_wready),
      .i_axi_wdata(axi_wdata),
      .i_axi_wstrb(axi_wstrb),
      .o_axi_bvalid(axi_bvalid),
      .i_axi_bready(axi_bready),
      .o_axi_bresp(axi_bresp),
      .i_axi_arvalid(axi_arvalid),
      .o_axi_arready(axi_arready),
      .i_axi_araddr(axi_araddr),
      .i_axi_arlen(axi_arlen),
      .o_axi_rvalid(axi_rvalid),
      .i_axi_rready(axi_rready),
      .o_axi_rdata(axi_rdata),
      .o_axi_rresp(axi_rresp),
      .o_axi_rlast(axi_rlast)
  );

endmodule : frost_cache_test_harness
