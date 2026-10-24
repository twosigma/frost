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
 * axi_mux_test_harness: cocotb top for axi_mux with three upstream ports.
 *
 * Each upstream port gets its own named signals (i_upN_* / o_upN_*), so one
 * bench model drives each port; the downstream port is i_dn_* / o_dn_*.
 */
module axi_mux_test_harness #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned UP_ID_WIDTH = 3,
    parameter int unsigned W_DEPTH = 4,
    localparam int unsigned NumPorts = 3,
    localparam int unsigned DownIdWidth = UP_ID_WIDTH + 2
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_up0_awvalid,
    input logic [UP_ID_WIDTH-1:0] i_up0_awid,
    input logic [ADDR_WIDTH-1:0] i_up0_awaddr,
    input logic [8-1:0] i_up0_awlen,
    input logic [3-1:0] i_up0_awsize,
    input logic [2-1:0] i_up0_awburst,
    input logic i_up0_awlock,
    input logic [4-1:0] i_up0_awcache,
    input logic [3-1:0] i_up0_awprot,
    input logic [4-1:0] i_up0_awqos,
    input logic i_up0_wvalid,
    input logic [DATA_WIDTH-1:0] i_up0_wdata,
    input logic [DATA_WIDTH/8-1:0] i_up0_wstrb,
    input logic i_up0_wlast,
    input logic i_up0_bready,
    input logic i_up0_arvalid,
    input logic [UP_ID_WIDTH-1:0] i_up0_arid,
    input logic [ADDR_WIDTH-1:0] i_up0_araddr,
    input logic [8-1:0] i_up0_arlen,
    input logic [3-1:0] i_up0_arsize,
    input logic [2-1:0] i_up0_arburst,
    input logic i_up0_arlock,
    input logic [4-1:0] i_up0_arcache,
    input logic [3-1:0] i_up0_arprot,
    input logic [4-1:0] i_up0_arqos,
    input logic i_up0_rready,
    output logic o_up0_awready,
    output logic o_up0_wready,
    output logic o_up0_bvalid,
    output logic [UP_ID_WIDTH-1:0] o_up0_bid,
    output logic [2-1:0] o_up0_bresp,
    output logic o_up0_arready,
    output logic o_up0_rvalid,
    output logic [UP_ID_WIDTH-1:0] o_up0_rid,
    output logic [DATA_WIDTH-1:0] o_up0_rdata,
    output logic [2-1:0] o_up0_rresp,
    output logic o_up0_rlast,
    input logic i_up1_awvalid,
    input logic [UP_ID_WIDTH-1:0] i_up1_awid,
    input logic [ADDR_WIDTH-1:0] i_up1_awaddr,
    input logic [8-1:0] i_up1_awlen,
    input logic [3-1:0] i_up1_awsize,
    input logic [2-1:0] i_up1_awburst,
    input logic i_up1_awlock,
    input logic [4-1:0] i_up1_awcache,
    input logic [3-1:0] i_up1_awprot,
    input logic [4-1:0] i_up1_awqos,
    input logic i_up1_wvalid,
    input logic [DATA_WIDTH-1:0] i_up1_wdata,
    input logic [DATA_WIDTH/8-1:0] i_up1_wstrb,
    input logic i_up1_wlast,
    input logic i_up1_bready,
    input logic i_up1_arvalid,
    input logic [UP_ID_WIDTH-1:0] i_up1_arid,
    input logic [ADDR_WIDTH-1:0] i_up1_araddr,
    input logic [8-1:0] i_up1_arlen,
    input logic [3-1:0] i_up1_arsize,
    input logic [2-1:0] i_up1_arburst,
    input logic i_up1_arlock,
    input logic [4-1:0] i_up1_arcache,
    input logic [3-1:0] i_up1_arprot,
    input logic [4-1:0] i_up1_arqos,
    input logic i_up1_rready,
    output logic o_up1_awready,
    output logic o_up1_wready,
    output logic o_up1_bvalid,
    output logic [UP_ID_WIDTH-1:0] o_up1_bid,
    output logic [2-1:0] o_up1_bresp,
    output logic o_up1_arready,
    output logic o_up1_rvalid,
    output logic [UP_ID_WIDTH-1:0] o_up1_rid,
    output logic [DATA_WIDTH-1:0] o_up1_rdata,
    output logic [2-1:0] o_up1_rresp,
    output logic o_up1_rlast,
    input logic i_up2_awvalid,
    input logic [UP_ID_WIDTH-1:0] i_up2_awid,
    input logic [ADDR_WIDTH-1:0] i_up2_awaddr,
    input logic [8-1:0] i_up2_awlen,
    input logic [3-1:0] i_up2_awsize,
    input logic [2-1:0] i_up2_awburst,
    input logic i_up2_awlock,
    input logic [4-1:0] i_up2_awcache,
    input logic [3-1:0] i_up2_awprot,
    input logic [4-1:0] i_up2_awqos,
    input logic i_up2_wvalid,
    input logic [DATA_WIDTH-1:0] i_up2_wdata,
    input logic [DATA_WIDTH/8-1:0] i_up2_wstrb,
    input logic i_up2_wlast,
    input logic i_up2_bready,
    input logic i_up2_arvalid,
    input logic [UP_ID_WIDTH-1:0] i_up2_arid,
    input logic [ADDR_WIDTH-1:0] i_up2_araddr,
    input logic [8-1:0] i_up2_arlen,
    input logic [3-1:0] i_up2_arsize,
    input logic [2-1:0] i_up2_arburst,
    input logic i_up2_arlock,
    input logic [4-1:0] i_up2_arcache,
    input logic [3-1:0] i_up2_arprot,
    input logic [4-1:0] i_up2_arqos,
    input logic i_up2_rready,
    output logic o_up2_awready,
    output logic o_up2_wready,
    output logic o_up2_bvalid,
    output logic [UP_ID_WIDTH-1:0] o_up2_bid,
    output logic [2-1:0] o_up2_bresp,
    output logic o_up2_arready,
    output logic o_up2_rvalid,
    output logic [UP_ID_WIDTH-1:0] o_up2_rid,
    output logic [DATA_WIDTH-1:0] o_up2_rdata,
    output logic [2-1:0] o_up2_rresp,
    output logic o_up2_rlast,
    output logic o_dn_awvalid,
    output logic [DownIdWidth-1:0] o_dn_awid,
    output logic [ADDR_WIDTH-1:0] o_dn_awaddr,
    output logic [8-1:0] o_dn_awlen,
    output logic [3-1:0] o_dn_awsize,
    output logic [2-1:0] o_dn_awburst,
    output logic o_dn_awlock,
    output logic [4-1:0] o_dn_awcache,
    output logic [3-1:0] o_dn_awprot,
    output logic [4-1:0] o_dn_awqos,
    output logic o_dn_wvalid,
    output logic [DATA_WIDTH-1:0] o_dn_wdata,
    output logic [DATA_WIDTH/8-1:0] o_dn_wstrb,
    output logic o_dn_wlast,
    output logic o_dn_bready,
    output logic o_dn_arvalid,
    output logic [DownIdWidth-1:0] o_dn_arid,
    output logic [ADDR_WIDTH-1:0] o_dn_araddr,
    output logic [8-1:0] o_dn_arlen,
    output logic [3-1:0] o_dn_arsize,
    output logic [2-1:0] o_dn_arburst,
    output logic o_dn_arlock,
    output logic [4-1:0] o_dn_arcache,
    output logic [3-1:0] o_dn_arprot,
    output logic [4-1:0] o_dn_arqos,
    output logic o_dn_rready,
    input logic i_dn_awready,
    input logic i_dn_wready,
    input logic i_dn_bvalid,
    input logic [DownIdWidth-1:0] i_dn_bid,
    input logic [2-1:0] i_dn_bresp,
    input logic i_dn_arready,
    input logic i_dn_rvalid,
    input logic [DownIdWidth-1:0] i_dn_rid,
    input logic [DATA_WIDTH-1:0] i_dn_rdata,
    input logic [2-1:0] i_dn_rresp,
    input logic i_dn_rlast
);
  logic [NumPorts-1:0] up_awvalid;
  assign up_awvalid = {i_up2_awvalid, i_up1_awvalid, i_up0_awvalid};
  logic [NumPorts-1:0][UP_ID_WIDTH-1:0] up_awid;
  assign up_awid = {i_up2_awid, i_up1_awid, i_up0_awid};
  logic [NumPorts-1:0][ADDR_WIDTH-1:0] up_awaddr;
  assign up_awaddr = {i_up2_awaddr, i_up1_awaddr, i_up0_awaddr};
  logic [NumPorts-1:0][8-1:0] up_awlen;
  assign up_awlen = {i_up2_awlen, i_up1_awlen, i_up0_awlen};
  logic [NumPorts-1:0][3-1:0] up_awsize;
  assign up_awsize = {i_up2_awsize, i_up1_awsize, i_up0_awsize};
  logic [NumPorts-1:0][2-1:0] up_awburst;
  assign up_awburst = {i_up2_awburst, i_up1_awburst, i_up0_awburst};
  logic [NumPorts-1:0] up_awlock;
  assign up_awlock = {i_up2_awlock, i_up1_awlock, i_up0_awlock};
  logic [NumPorts-1:0][4-1:0] up_awcache;
  assign up_awcache = {i_up2_awcache, i_up1_awcache, i_up0_awcache};
  logic [NumPorts-1:0][3-1:0] up_awprot;
  assign up_awprot = {i_up2_awprot, i_up1_awprot, i_up0_awprot};
  logic [NumPorts-1:0][4-1:0] up_awqos;
  assign up_awqos = {i_up2_awqos, i_up1_awqos, i_up0_awqos};
  logic [NumPorts-1:0] up_wvalid;
  assign up_wvalid = {i_up2_wvalid, i_up1_wvalid, i_up0_wvalid};
  logic [NumPorts-1:0][DATA_WIDTH-1:0] up_wdata;
  assign up_wdata = {i_up2_wdata, i_up1_wdata, i_up0_wdata};
  logic [NumPorts-1:0][DATA_WIDTH/8-1:0] up_wstrb;
  assign up_wstrb = {i_up2_wstrb, i_up1_wstrb, i_up0_wstrb};
  logic [NumPorts-1:0] up_wlast;
  assign up_wlast = {i_up2_wlast, i_up1_wlast, i_up0_wlast};
  logic [NumPorts-1:0] up_bready;
  assign up_bready = {i_up2_bready, i_up1_bready, i_up0_bready};
  logic [NumPorts-1:0] up_arvalid;
  assign up_arvalid = {i_up2_arvalid, i_up1_arvalid, i_up0_arvalid};
  logic [NumPorts-1:0][UP_ID_WIDTH-1:0] up_arid;
  assign up_arid = {i_up2_arid, i_up1_arid, i_up0_arid};
  logic [NumPorts-1:0][ADDR_WIDTH-1:0] up_araddr;
  assign up_araddr = {i_up2_araddr, i_up1_araddr, i_up0_araddr};
  logic [NumPorts-1:0][8-1:0] up_arlen;
  assign up_arlen = {i_up2_arlen, i_up1_arlen, i_up0_arlen};
  logic [NumPorts-1:0][3-1:0] up_arsize;
  assign up_arsize = {i_up2_arsize, i_up1_arsize, i_up0_arsize};
  logic [NumPorts-1:0][2-1:0] up_arburst;
  assign up_arburst = {i_up2_arburst, i_up1_arburst, i_up0_arburst};
  logic [NumPorts-1:0] up_arlock;
  assign up_arlock = {i_up2_arlock, i_up1_arlock, i_up0_arlock};
  logic [NumPorts-1:0][4-1:0] up_arcache;
  assign up_arcache = {i_up2_arcache, i_up1_arcache, i_up0_arcache};
  logic [NumPorts-1:0][3-1:0] up_arprot;
  assign up_arprot = {i_up2_arprot, i_up1_arprot, i_up0_arprot};
  logic [NumPorts-1:0][4-1:0] up_arqos;
  assign up_arqos = {i_up2_arqos, i_up1_arqos, i_up0_arqos};
  logic [NumPorts-1:0] up_rready;
  assign up_rready = {i_up2_rready, i_up1_rready, i_up0_rready};
  logic [NumPorts-1:0] up_awready;
  assign o_up0_awready = up_awready[0];
  assign o_up1_awready = up_awready[1];
  assign o_up2_awready = up_awready[2];
  logic [NumPorts-1:0] up_wready;
  assign o_up0_wready = up_wready[0];
  assign o_up1_wready = up_wready[1];
  assign o_up2_wready = up_wready[2];
  logic [NumPorts-1:0] up_bvalid;
  assign o_up0_bvalid = up_bvalid[0];
  assign o_up1_bvalid = up_bvalid[1];
  assign o_up2_bvalid = up_bvalid[2];
  logic [NumPorts-1:0][UP_ID_WIDTH-1:0] up_bid;
  assign o_up0_bid = up_bid[0];
  assign o_up1_bid = up_bid[1];
  assign o_up2_bid = up_bid[2];
  logic [NumPorts-1:0][2-1:0] up_bresp;
  assign o_up0_bresp = up_bresp[0];
  assign o_up1_bresp = up_bresp[1];
  assign o_up2_bresp = up_bresp[2];
  logic [NumPorts-1:0] up_arready;
  assign o_up0_arready = up_arready[0];
  assign o_up1_arready = up_arready[1];
  assign o_up2_arready = up_arready[2];
  logic [NumPorts-1:0] up_rvalid;
  assign o_up0_rvalid = up_rvalid[0];
  assign o_up1_rvalid = up_rvalid[1];
  assign o_up2_rvalid = up_rvalid[2];
  logic [NumPorts-1:0][UP_ID_WIDTH-1:0] up_rid;
  assign o_up0_rid = up_rid[0];
  assign o_up1_rid = up_rid[1];
  assign o_up2_rid = up_rid[2];
  logic [NumPorts-1:0][DATA_WIDTH-1:0] up_rdata;
  assign o_up0_rdata = up_rdata[0];
  assign o_up1_rdata = up_rdata[1];
  assign o_up2_rdata = up_rdata[2];
  logic [NumPorts-1:0][2-1:0] up_rresp;
  assign o_up0_rresp = up_rresp[0];
  assign o_up1_rresp = up_rresp[1];
  assign o_up2_rresp = up_rresp[2];
  logic [NumPorts-1:0] up_rlast;
  assign o_up0_rlast = up_rlast[0];
  assign o_up1_rlast = up_rlast[1];
  assign o_up2_rlast = up_rlast[2];

  axi_mux #(
      .NUM_PORTS(NumPorts),
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .UP_ID_WIDTH(UP_ID_WIDTH),
      .W_DEPTH(W_DEPTH)
  ) u_mux (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_awvalid(up_awvalid),
      .i_up_awid(up_awid),
      .i_up_awaddr(up_awaddr),
      .i_up_awlen(up_awlen),
      .i_up_awsize(up_awsize),
      .i_up_awburst(up_awburst),
      .i_up_awlock(up_awlock),
      .i_up_awcache(up_awcache),
      .i_up_awprot(up_awprot),
      .i_up_awqos(up_awqos),
      .i_up_wvalid(up_wvalid),
      .i_up_wdata(up_wdata),
      .i_up_wstrb(up_wstrb),
      .i_up_wlast(up_wlast),
      .i_up_bready(up_bready),
      .i_up_arvalid(up_arvalid),
      .i_up_arid(up_arid),
      .i_up_araddr(up_araddr),
      .i_up_arlen(up_arlen),
      .i_up_arsize(up_arsize),
      .i_up_arburst(up_arburst),
      .i_up_arlock(up_arlock),
      .i_up_arcache(up_arcache),
      .i_up_arprot(up_arprot),
      .i_up_arqos(up_arqos),
      .i_up_rready(up_rready),
      .o_up_awready(up_awready),
      .o_up_wready(up_wready),
      .o_up_bvalid(up_bvalid),
      .o_up_bid(up_bid),
      .o_up_bresp(up_bresp),
      .o_up_arready(up_arready),
      .o_up_rvalid(up_rvalid),
      .o_up_rid(up_rid),
      .o_up_rdata(up_rdata),
      .o_up_rresp(up_rresp),
      .o_up_rlast(up_rlast),
      .o_dn_awvalid(o_dn_awvalid),
      .o_dn_awid(o_dn_awid),
      .o_dn_awaddr(o_dn_awaddr),
      .o_dn_awlen(o_dn_awlen),
      .o_dn_awsize(o_dn_awsize),
      .o_dn_awburst(o_dn_awburst),
      .o_dn_awlock(o_dn_awlock),
      .o_dn_awcache(o_dn_awcache),
      .o_dn_awprot(o_dn_awprot),
      .o_dn_awqos(o_dn_awqos),
      .o_dn_wvalid(o_dn_wvalid),
      .o_dn_wdata(o_dn_wdata),
      .o_dn_wstrb(o_dn_wstrb),
      .o_dn_wlast(o_dn_wlast),
      .o_dn_bready(o_dn_bready),
      .o_dn_arvalid(o_dn_arvalid),
      .o_dn_arid(o_dn_arid),
      .o_dn_araddr(o_dn_araddr),
      .o_dn_arlen(o_dn_arlen),
      .o_dn_arsize(o_dn_arsize),
      .o_dn_arburst(o_dn_arburst),
      .o_dn_arlock(o_dn_arlock),
      .o_dn_arcache(o_dn_arcache),
      .o_dn_arprot(o_dn_arprot),
      .o_dn_arqos(o_dn_arqos),
      .o_dn_rready(o_dn_rready),
      .i_dn_awready(i_dn_awready),
      .i_dn_wready(i_dn_wready),
      .i_dn_bvalid(i_dn_bvalid),
      .i_dn_bid(i_dn_bid),
      .i_dn_bresp(i_dn_bresp),
      .i_dn_arready(i_dn_arready),
      .i_dn_rvalid(i_dn_rvalid),
      .i_dn_rid(i_dn_rid),
      .i_dn_rdata(i_dn_rdata),
      .i_dn_rresp(i_dn_rresp),
      .i_dn_rlast(i_dn_rlast)
  );
endmodule : axi_mux_test_harness
