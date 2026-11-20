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

// DDR block-design boundary. The test drives the response ports and observes
// the request and reset pins of the same instance used by the board.
module ddr_subsys_wrapper (
    input  logic cpu_clk,
    jtag_clk,
    default_250mhz_clk_clk_p,
    default_250mhz_clk_clk_n,
    input  logic sys_reset,
    cpu_aresetn,
    jtag_aresetn,
    output logic mem_ok,

    input logic S00_AXI_awvalid,
    output logic S00_AXI_awready,
    input logic [4:0] S00_AXI_awid,
    input logic [30:0] S00_AXI_awaddr,
    input logic [7:0] S00_AXI_awlen,
    input logic [2:0] S00_AXI_awsize,
    input logic [1:0] S00_AXI_awburst,
    input logic S00_AXI_wvalid,
    output logic S00_AXI_wready,
    input logic [511:0] S00_AXI_wdata,
    input logic [63:0] S00_AXI_wstrb,
    input logic S00_AXI_wlast,
    output logic S00_AXI_bvalid,
    input logic S00_AXI_bready,
    output logic [4:0] S00_AXI_bid,
    output logic [1:0] S00_AXI_bresp,
    input logic S00_AXI_arvalid,
    output logic S00_AXI_arready,
    input logic [4:0] S00_AXI_arid,
    input logic [30:0] S00_AXI_araddr,
    input logic [7:0] S00_AXI_arlen,
    input logic [2:0] S00_AXI_arsize,
    input logic [1:0] S00_AXI_arburst,
    output logic S00_AXI_rvalid,
    input logic S00_AXI_rready,
    output logic [4:0] S00_AXI_rid,
    output logic [511:0] S00_AXI_rdata,
    output logic [1:0] S00_AXI_rresp,
    output logic S00_AXI_rlast,

    output logic ddr4_sdram_c0_act_n,
    output logic [16:0] ddr4_sdram_c0_adr,
    output logic [1:0] ddr4_sdram_c0_ba,
    output logic ddr4_sdram_c0_bg,
    ddr4_sdram_c0_ck_c,
    ddr4_sdram_c0_ck_t,
    output logic ddr4_sdram_c0_cke,
    ddr4_sdram_c0_cs_n,
    ddr4_sdram_c0_odt,
    ddr4_sdram_c0_reset_n,
    inout wire [8:0] ddr4_sdram_c0_dm_n,
    ddr4_sdram_c0_dqs_c,
    ddr4_sdram_c0_dqs_t,
    inout wire [71:0] ddr4_sdram_c0_dq
);
endmodule
