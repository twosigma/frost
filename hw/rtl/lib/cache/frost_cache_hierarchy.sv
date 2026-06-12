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
 * Instantiates the data-side L1, the instruction-side L1I, the 2:1 line-port
 * arbiter below them, and, when HAS_L2 != 0, L2 (URAM) behind the arbiter;
 * every port speaks the frost_cache line protocol, so the hierarchy is a
 * two-slave line-port module with one downstream master:
 *
 *   Genesys2 (HAS_L2=0):  up  -> L1(BRAM)  -\
 *                                            arbiter -> down (DDR3)
 *                         iup -> L1I(BRAM) -/
 *   X3       (HAS_L2=1):  up  -> L1(BRAM)  -\
 *                                            arbiter -> L2(URAM) -> down (DDR4)
 *                         iup -> L1I(BRAM) -/
 *
 * The arbiter gives the data side fixed priority (its misses stall committed
 * work; the instruction side fetches ahead through a buffer).  L1I sits above
 * the shared level (L2 or main memory), so data written back from the L1 is
 * visible to instruction fetch once it reaches that level -- the property
 * fence.i relies on.  The L1I is a plain frost_cache used read-only: the
 * instruction side never issues writes, so its dirty/evict logic stays idle.
 * Both shapes are exercised by the cocotb cache unit tests.
 */
module frost_cache_hierarchy #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L1_DATA_WRITE_LATENCY = 1,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1I_DATA_READ_LATENCY = 2,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned L2_DATA_READ_LATENCY = 6,
    parameter int unsigned L2_DATA_WRITE_LATENCY = 2
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave) -- data side.
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    output logic                    o_up_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Upstream line port (slave) -- instruction side (read-only use: FROST
    // never issues writes here; wdata/wstrb exist for protocol symmetry).
    input  logic                    i_iup_req_valid,
    output logic                    o_iup_req_ready,
    input  logic                    i_iup_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_iup_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_iup_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_iup_req_wstrb,
    output logic                    o_iup_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_iup_resp_rdata,

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

  // Per-L1 downstream wires into the arbiter, and the arbiter's downstream
  // (to L2 or straight to the hierarchy's downstream port).
  logic                    l1_down_req_valid;
  logic                    l1_down_req_ready;
  logic                    l1_down_req_write;
  logic [  ADDR_WIDTH-1:0] l1_down_req_addr;
  logic [LINE_BYTES*8-1:0] l1_down_req_wdata;
  logic [  LINE_BYTES-1:0] l1_down_req_wstrb;
  logic                    l1_down_resp_valid;
  logic [LINE_BYTES*8-1:0] l1_down_resp_rdata;

  logic                    l1i_down_req_valid;
  logic                    l1i_down_req_ready;
  logic                    l1i_down_req_write;
  logic [  ADDR_WIDTH-1:0] l1i_down_req_addr;
  logic [LINE_BYTES*8-1:0] l1i_down_req_wdata;
  logic [  LINE_BYTES-1:0] l1i_down_req_wstrb;
  logic                    l1i_down_resp_valid;
  logic [LINE_BYTES*8-1:0] l1i_down_resp_rdata;

  logic                    arb_down_req_valid;
  logic                    arb_down_req_ready;
  logic                    arb_down_req_write;
  logic [  ADDR_WIDTH-1:0] arb_down_req_addr;
  logic [LINE_BYTES*8-1:0] arb_down_req_wdata;
  logic [  LINE_BYTES-1:0] arb_down_req_wstrb;
  logic                    arb_down_resp_valid;
  logic [LINE_BYTES*8-1:0] arb_down_resp_rdata;

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

  frost_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1I_CACHE_BYTES),
      .LINE_BYTES(LINE_BYTES),
      .DATA_MEMORY_PRIMITIVE("block"),
      .DATA_READ_LATENCY(L1I_DATA_READ_LATENCY)
  ) l1i_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid(i_iup_req_valid),
      .o_up_req_ready(o_iup_req_ready),
      .i_up_req_write(i_iup_req_write),
      .i_up_req_addr(i_iup_req_addr),
      .i_up_req_wdata(i_iup_req_wdata),
      .i_up_req_wstrb(i_iup_req_wstrb),
      .o_up_resp_valid(o_iup_resp_valid),
      .o_up_resp_rdata(o_iup_resp_rdata),
      .o_down_req_valid(l1i_down_req_valid),
      .i_down_req_ready(l1i_down_req_ready),
      .o_down_req_write(l1i_down_req_write),
      .o_down_req_addr(l1i_down_req_addr),
      .o_down_req_wdata(l1i_down_req_wdata),
      .o_down_req_wstrb(l1i_down_req_wstrb),
      .i_down_resp_valid(l1i_down_resp_valid),
      .i_down_resp_rdata(l1i_down_resp_rdata)
  );

  // 2:1 arbiter below the two L1s: data side on port 0 (fixed priority).
  line_port_arbiter #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES)
  ) l1_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up0_req_valid(l1_down_req_valid),
      .o_up0_req_ready(l1_down_req_ready),
      .i_up0_req_write(l1_down_req_write),
      .i_up0_req_addr(l1_down_req_addr),
      .i_up0_req_wdata(l1_down_req_wdata),
      .i_up0_req_wstrb(l1_down_req_wstrb),
      .o_up0_resp_valid(l1_down_resp_valid),
      .o_up0_resp_rdata(l1_down_resp_rdata),
      .i_up1_req_valid(l1i_down_req_valid),
      .o_up1_req_ready(l1i_down_req_ready),
      .i_up1_req_write(l1i_down_req_write),
      .i_up1_req_addr(l1i_down_req_addr),
      .i_up1_req_wdata(l1i_down_req_wdata),
      .i_up1_req_wstrb(l1i_down_req_wstrb),
      .o_up1_resp_valid(l1i_down_resp_valid),
      .o_up1_resp_rdata(l1i_down_resp_rdata),
      .o_down_req_valid(arb_down_req_valid),
      .i_down_req_ready(arb_down_req_ready),
      .o_down_req_write(arb_down_req_write),
      .o_down_req_addr(arb_down_req_addr),
      .o_down_req_wdata(arb_down_req_wdata),
      .o_down_req_wstrb(arb_down_req_wstrb),
      .i_down_resp_valid(arb_down_resp_valid),
      .i_down_resp_rdata(arb_down_resp_rdata)
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
        .i_up_req_valid(arb_down_req_valid),
        .o_up_req_ready(arb_down_req_ready),
        .i_up_req_write(arb_down_req_write),
        .i_up_req_addr(arb_down_req_addr),
        .i_up_req_wdata(arb_down_req_wdata),
        .i_up_req_wstrb(arb_down_req_wstrb),
        .o_up_resp_valid(arb_down_resp_valid),
        .o_up_resp_rdata(arb_down_resp_rdata),
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
    assign o_down_req_valid    = arb_down_req_valid;
    assign arb_down_req_ready  = i_down_req_ready;
    assign o_down_req_write    = arb_down_req_write;
    assign o_down_req_addr     = arb_down_req_addr;
    assign o_down_req_wdata    = arb_down_req_wdata;
    assign o_down_req_wstrb    = arb_down_req_wstrb;
    assign arb_down_resp_valid = i_down_resp_valid;
    assign arb_down_resp_rdata = i_down_resp_rdata;
  end

endmodule : frost_cache_hierarchy
