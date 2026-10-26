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

// Five independent asynchronous FIFOs carry the complete AXI4 channels.
// Owners reset both sides together, using cdc_reset_pair for unrelated clocks.
module axi_cdc #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned ID_WIDTH = 4,
    parameter int unsigned USER_WIDTH = 1,
    parameter int unsigned DEPTH = 4
) (
    input logic i_src_clk,
    input logic i_src_rst,
    input logic i_dst_clk,
    input logic i_dst_rst,
    input logic i_src_awvalid,
    output logic o_src_awready,
    input logic [ID_WIDTH-1:0] i_src_awid,
    input logic [ADDR_WIDTH-1:0] i_src_awaddr,
    input logic [8-1:0] i_src_awlen,
    input logic [3-1:0] i_src_awsize,
    input logic [2-1:0] i_src_awburst,
    input logic i_src_awlock,
    input logic [4-1:0] i_src_awcache,
    input logic [3-1:0] i_src_awprot,
    input logic [4-1:0] i_src_awqos,
    input logic [4-1:0] i_src_awregion,
    input logic [USER_WIDTH-1:0] i_src_awuser,
    input logic i_src_wvalid,
    output logic o_src_wready,
    input logic [DATA_WIDTH-1:0] i_src_wdata,
    input logic [DATA_WIDTH/8-1:0] i_src_wstrb,
    input logic i_src_wlast,
    input logic [USER_WIDTH-1:0] i_src_wuser,
    output logic o_src_bvalid,
    input logic i_src_bready,
    output logic [ID_WIDTH-1:0] o_src_bid,
    output logic [2-1:0] o_src_bresp,
    output logic [USER_WIDTH-1:0] o_src_buser,
    input logic i_src_arvalid,
    output logic o_src_arready,
    input logic [ID_WIDTH-1:0] i_src_arid,
    input logic [ADDR_WIDTH-1:0] i_src_araddr,
    input logic [8-1:0] i_src_arlen,
    input logic [3-1:0] i_src_arsize,
    input logic [2-1:0] i_src_arburst,
    input logic i_src_arlock,
    input logic [4-1:0] i_src_arcache,
    input logic [3-1:0] i_src_arprot,
    input logic [4-1:0] i_src_arqos,
    input logic [4-1:0] i_src_arregion,
    input logic [USER_WIDTH-1:0] i_src_aruser,
    output logic o_src_rvalid,
    input logic i_src_rready,
    output logic [ID_WIDTH-1:0] o_src_rid,
    output logic [DATA_WIDTH-1:0] o_src_rdata,
    output logic [2-1:0] o_src_rresp,
    output logic o_src_rlast,
    output logic [USER_WIDTH-1:0] o_src_ruser,
    output logic o_dst_awvalid,
    input logic i_dst_awready,
    output logic [ID_WIDTH-1:0] o_dst_awid,
    output logic [ADDR_WIDTH-1:0] o_dst_awaddr,
    output logic [8-1:0] o_dst_awlen,
    output logic [3-1:0] o_dst_awsize,
    output logic [2-1:0] o_dst_awburst,
    output logic o_dst_awlock,
    output logic [4-1:0] o_dst_awcache,
    output logic [3-1:0] o_dst_awprot,
    output logic [4-1:0] o_dst_awqos,
    output logic [4-1:0] o_dst_awregion,
    output logic [USER_WIDTH-1:0] o_dst_awuser,
    output logic o_dst_wvalid,
    input logic i_dst_wready,
    output logic [DATA_WIDTH-1:0] o_dst_wdata,
    output logic [DATA_WIDTH/8-1:0] o_dst_wstrb,
    output logic o_dst_wlast,
    output logic [USER_WIDTH-1:0] o_dst_wuser,
    input logic i_dst_bvalid,
    output logic o_dst_bready,
    input logic [ID_WIDTH-1:0] i_dst_bid,
    input logic [2-1:0] i_dst_bresp,
    input logic [USER_WIDTH-1:0] i_dst_buser,
    output logic o_dst_arvalid,
    input logic i_dst_arready,
    output logic [ID_WIDTH-1:0] o_dst_arid,
    output logic [ADDR_WIDTH-1:0] o_dst_araddr,
    output logic [8-1:0] o_dst_arlen,
    output logic [3-1:0] o_dst_arsize,
    output logic [2-1:0] o_dst_arburst,
    output logic o_dst_arlock,
    output logic [4-1:0] o_dst_arcache,
    output logic [3-1:0] o_dst_arprot,
    output logic [4-1:0] o_dst_arqos,
    output logic [4-1:0] o_dst_arregion,
    output logic [USER_WIDTH-1:0] o_dst_aruser,
    input logic i_dst_rvalid,
    output logic o_dst_rready,
    input logic [ID_WIDTH-1:0] i_dst_rid,
    input logic [DATA_WIDTH-1:0] i_dst_rdata,
    input logic [2-1:0] i_dst_rresp,
    input logic i_dst_rlast,
    input logic [USER_WIDTH-1:0] i_dst_ruser
);
  logic aw_valid;
  assign o_dst_awvalid = aw_valid && !i_dst_rst;
  async_fifo #(
      .DATA_WIDTH(ID_WIDTH + ADDR_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4 + USER_WIDTH),
      .DEPTH(DEPTH),
      .READY_MARGIN(0)
  ) aw_fifo (
      .i_clk(i_src_clk),
      .i_rst(i_src_rst),
      .i_data({
        i_src_awid,
        i_src_awaddr,
        i_src_awlen,
        i_src_awsize,
        i_src_awburst,
        i_src_awlock,
        i_src_awcache,
        i_src_awprot,
        i_src_awqos,
        i_src_awregion,
        i_src_awuser
      }),
      .i_valid(i_src_awvalid),
      .o_ready(o_src_awready),
      .o_clk(i_dst_clk),
      .o_rst(i_dst_rst),
      .o_data({
        o_dst_awid,
        o_dst_awaddr,
        o_dst_awlen,
        o_dst_awsize,
        o_dst_awburst,
        o_dst_awlock,
        o_dst_awcache,
        o_dst_awprot,
        o_dst_awqos,
        o_dst_awregion,
        o_dst_awuser
      }),
      .o_valid(aw_valid),
      .i_ready(i_dst_awready && !i_dst_rst)
  );
  logic w_valid;
  assign o_dst_wvalid = w_valid && !i_dst_rst;
  async_fifo #(
      .DATA_WIDTH(DATA_WIDTH + DATA_WIDTH / 8 + 1 + USER_WIDTH),
      .DEPTH(DEPTH),
      .READY_MARGIN(0)
  ) w_fifo (
      .i_clk  (i_src_clk),
      .i_rst  (i_src_rst),
      .i_data ({i_src_wdata, i_src_wstrb, i_src_wlast, i_src_wuser}),
      .i_valid(i_src_wvalid),
      .o_ready(o_src_wready),
      .o_clk  (i_dst_clk),
      .o_rst  (i_dst_rst),
      .o_data ({o_dst_wdata, o_dst_wstrb, o_dst_wlast, o_dst_wuser}),
      .o_valid(w_valid),
      .i_ready(i_dst_wready && !i_dst_rst)
  );
  logic b_valid;
  assign o_src_bvalid = b_valid && !i_src_rst;
  async_fifo #(
      .DATA_WIDTH(ID_WIDTH + 2 + USER_WIDTH),
      .DEPTH(DEPTH),
      .READY_MARGIN(0)
  ) b_fifo (
      .i_clk  (i_dst_clk),
      .i_rst  (i_dst_rst),
      .i_data ({i_dst_bid, i_dst_bresp, i_dst_buser}),
      .i_valid(i_dst_bvalid),
      .o_ready(o_dst_bready),
      .o_clk  (i_src_clk),
      .o_rst  (i_src_rst),
      .o_data ({o_src_bid, o_src_bresp, o_src_buser}),
      .o_valid(b_valid),
      .i_ready(i_src_bready && !i_src_rst)
  );
  logic ar_valid;
  assign o_dst_arvalid = ar_valid && !i_dst_rst;
  async_fifo #(
      .DATA_WIDTH(ID_WIDTH + ADDR_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4 + USER_WIDTH),
      .DEPTH(DEPTH),
      .READY_MARGIN(0)
  ) ar_fifo (
      .i_clk(i_src_clk),
      .i_rst(i_src_rst),
      .i_data({
        i_src_arid,
        i_src_araddr,
        i_src_arlen,
        i_src_arsize,
        i_src_arburst,
        i_src_arlock,
        i_src_arcache,
        i_src_arprot,
        i_src_arqos,
        i_src_arregion,
        i_src_aruser
      }),
      .i_valid(i_src_arvalid),
      .o_ready(o_src_arready),
      .o_clk(i_dst_clk),
      .o_rst(i_dst_rst),
      .o_data({
        o_dst_arid,
        o_dst_araddr,
        o_dst_arlen,
        o_dst_arsize,
        o_dst_arburst,
        o_dst_arlock,
        o_dst_arcache,
        o_dst_arprot,
        o_dst_arqos,
        o_dst_arregion,
        o_dst_aruser
      }),
      .o_valid(ar_valid),
      .i_ready(i_dst_arready && !i_dst_rst)
  );
  logic r_valid;
  assign o_src_rvalid = r_valid && !i_src_rst;
  async_fifo #(
      .DATA_WIDTH(ID_WIDTH + DATA_WIDTH + 2 + 1 + USER_WIDTH),
      .DEPTH(DEPTH),
      .READY_MARGIN(0)
  ) r_fifo (
      .i_clk  (i_dst_clk),
      .i_rst  (i_dst_rst),
      .i_data ({i_dst_rid, i_dst_rdata, i_dst_rresp, i_dst_rlast, i_dst_ruser}),
      .i_valid(i_dst_rvalid),
      .o_ready(o_dst_rready),
      .o_clk  (i_src_clk),
      .o_rst  (i_src_rst),
      .o_data ({o_src_rid, o_src_rdata, o_src_rresp, o_src_rlast, o_src_ruser}),
      .o_valid(r_valid),
      .i_ready(i_src_rready && !i_src_rst)
  );
endmodule : axi_cdc
