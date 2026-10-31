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

// The AXI burst bridge and coherent ingress share a requester reset.
module coherent_axi_test_harness #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_WIDTH = 5,
    parameter int unsigned LINE_ADDR_WIDTH = 32,
    parameter int unsigned LINE_ID_BITS = 3,
    parameter logic [63:0] REGION_BASE = 64'h8000_0000,
    parameter logic [63:0] REGION_BYTES = 64'h4000_0000,
    parameter int unsigned WRITE_BURSTS = 4,
    parameter int unsigned READ_BURSTS = 4,
    parameter int unsigned STARVATION_LIMIT = 8,
    parameter int unsigned INGRESS_SLOTS = 4
) (
    input logic i_clk,
    input logic i_rst,

    // AXI4 slave.
    input  logic                    i_axi_awvalid,
    output logic                    o_axi_awready,
    input  logic [    ID_WIDTH-1:0] i_axi_awid,
    input  logic [  ADDR_WIDTH-1:0] i_axi_awaddr,
    input  logic [             7:0] i_axi_awlen,
    input  logic [             2:0] i_axi_awsize,
    input  logic [             1:0] i_axi_awburst,
    input  logic                    i_axi_awlock,
    input  logic [             3:0] i_axi_awcache,
    input  logic [             2:0] i_axi_awprot,
    input  logic [             3:0] i_axi_awqos,
    input  logic                    i_axi_wvalid,
    output logic                    o_axi_wready,
    input  logic [  DATA_WIDTH-1:0] i_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] i_axi_wstrb,
    input  logic                    i_axi_wlast,
    output logic                    o_axi_bvalid,
    input  logic                    i_axi_bready,
    output logic [    ID_WIDTH-1:0] o_axi_bid,
    output logic [             1:0] o_axi_bresp,
    input  logic                    i_axi_arvalid,
    output logic                    o_axi_arready,
    input  logic [    ID_WIDTH-1:0] i_axi_arid,
    input  logic [  ADDR_WIDTH-1:0] i_axi_araddr,
    input  logic [             7:0] i_axi_arlen,
    input  logic [             2:0] i_axi_arsize,
    input  logic [             1:0] i_axi_arburst,
    input  logic                    i_axi_arlock,
    input  logic [             3:0] i_axi_arcache,
    input  logic [             2:0] i_axi_arprot,
    input  logic [             3:0] i_axi_arqos,
    output logic                    o_axi_rvalid,
    input  logic                    i_axi_rready,
    output logic [    ID_WIDTH-1:0] o_axi_rid,
    output logic [  DATA_WIDTH-1:0] o_axi_rdata,
    output logic [             1:0] o_axi_rresp,
    output logic                    o_axi_rlast,

    // Line port (master) into the coherent ingress.
    output logic                         o_line_req_valid,
    output logic                         i_line_req_ready,
    output logic                         o_line_req_write,
    output logic [  LINE_ADDR_WIDTH-1:0] o_line_req_addr,
    output logic [     8*LINE_BYTES-1:0] o_line_req_wdata,
    output logic [       LINE_BYTES-1:0] o_line_req_wstrb,
    output logic [     LINE_ID_BITS-1:0] o_line_req_id,
    output logic                         i_line_resp_valid,
    output logic [     LINE_ID_BITS-1:0] i_line_resp_id,
    output logic [     8*LINE_BYTES-1:0] i_line_resp_rdata,
    output logic                         i_line_resp_error,
    output logic                         o_d_valid,
    input  logic                         i_d_ready,
    output logic [LINE_ADDR_WIDTH+311:0] o_d,
    input  logic                         i_g_valid,
    output logic                         o_g_ready,
    input  logic [LINE_ADDR_WIDTH+274:0] i_g,
    output logic                         o_c_valid,
    input  logic                         i_c_ready,
    output logic [ LINE_ADDR_WIDTH+17:0] o_c,
    input  logic                         i_u_valid,
    output logic                         o_u_ready,
    input  logic [ LINE_ADDR_WIDTH+14:0] i_u
);
  logic [3:0] response_id;
  assign i_line_resp_id = response_id[LINE_ID_BITS-1:0];
  axi_coherent_bridge #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .ID_WIDTH(ID_WIDTH),
      .LINE_ADDR_WIDTH(LINE_ADDR_WIDTH),
      .LINE_ID_BITS(LINE_ID_BITS),
      .REGION_BASE(REGION_BASE),
      .REGION_BYTES(REGION_BYTES),
      .WRITE_BURSTS(WRITE_BURSTS),
      .READ_BURSTS(READ_BURSTS),
      .STARVATION_LIMIT(STARVATION_LIMIT)
  ) bridge (
      .*
  );
  coherence_dma_ingress #(
      .ADDR_WIDTH(LINE_ADDR_WIDTH),
      .SLOTS(INGRESS_SLOTS)
  ) ingress (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(1'b0),
      .i_req_valid(o_line_req_valid),
      .o_req_ready(i_line_req_ready),
      .i_req_write(o_line_req_write),
      .i_req_addr(o_line_req_addr),
      .i_req_data(o_line_req_wdata),
      .i_req_mask(o_line_req_wstrb),
      .i_req_id(4'(o_line_req_id)),
      .o_resp_valid(i_line_resp_valid),
      .o_resp_id(response_id),
      .o_resp_data(i_line_resp_rdata),
      .o_resp_error(i_line_resp_error),
      .o_d_valid(o_d_valid),
      .i_d_ready(i_d_ready),
      .o_d(o_d),
      .i_g_valid(i_g_valid),
      .o_g_ready(o_g_ready),
      .i_g(i_g),
      .o_c_valid(o_c_valid),
      .i_c_ready(i_c_ready),
      .o_c(o_c),
      .i_u_valid(i_u_valid),
      .o_u_ready(o_u_ready),
      .i_u(i_u)
  );
endmodule
