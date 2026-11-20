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
 * nic_top: structural composition of nic_engine with either nic_mac_10g
 * (GMII_MODE = 0) or nic_mac_1g (GMII_MODE = 1) joined over the core-clock
 * 64-bit AXI4-Stream and sideband boundary.
 *
 * Used by standalone whole-NIC benches, Yosys partition checks, and
 * TestRIG's simulation platform. soc_top instantiates nic_engine and the
 * MAC blocks side by side directly.
 */
module nic_top #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter logic [63:0] APERTURE_BASE = 64'h8000_0000,
    parameter logic [63:0] APERTURE_BYTES = 64'h4000_0000,
    parameter logic [31:0] TICK_DEFAULT = 32'd300,
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int unsigned RX_FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned STARVATION_LIMIT = 8,
    parameter int unsigned RAW_LOOPBACK = 1,
    parameter bit GMII_MODE = 1'b0,
    parameter bit RX_PREAMBLE_ER_TOLERANT = 1'b0,
    parameter int unsigned DMA_AXI_ADDR_BITS = 64,
    parameter int unsigned DMA_AXI_ID_BITS = 3,
    localparam int unsigned IdBits = 3
) (
    input logic i_clk,
    input logic i_rst,

    // AXI4-Lite register window, 64-bit data.
    input  logic        i_reg_axil_awvalid,
    output logic        o_reg_axil_awready,
    input  logic [11:0] i_reg_axil_awaddr,
    input  logic [ 2:0] i_reg_axil_awprot,
    input  logic        i_reg_axil_wvalid,
    output logic        o_reg_axil_wready,
    input  logic [63:0] i_reg_axil_wdata,
    input  logic [ 7:0] i_reg_axil_wstrb,
    output logic        o_reg_axil_bvalid,
    input  logic        i_reg_axil_bready,
    output logic [ 1:0] o_reg_axil_bresp,
    input  logic        i_reg_axil_arvalid,
    output logic        o_reg_axil_arready,
    input  logic [11:0] i_reg_axil_araddr,
    input  logic [ 2:0] i_reg_axil_arprot,
    output logic        o_reg_axil_rvalid,
    input  logic        i_reg_axil_rready,
    output logic [63:0] o_reg_axil_rdata,
    output logic [ 1:0] o_reg_axil_rresp,
    output logic        o_irq,

    // DMA AXI4 master.
    output logic                         o_dma_axi_awvalid,
    input  logic                         i_dma_axi_awready,
    output logic [  DMA_AXI_ID_BITS-1:0] o_dma_axi_awid,
    output logic [DMA_AXI_ADDR_BITS-1:0] o_dma_axi_awaddr,
    output logic [                  7:0] o_dma_axi_awlen,
    output logic [                  2:0] o_dma_axi_awsize,
    output logic [                  1:0] o_dma_axi_awburst,
    output logic                         o_dma_axi_awlock,
    output logic [                  3:0] o_dma_axi_awcache,
    output logic [                  2:0] o_dma_axi_awprot,
    output logic [                  3:0] o_dma_axi_awqos,
    output logic                         o_dma_axi_wvalid,
    input  logic                         i_dma_axi_wready,
    output logic [     LINE_BYTES*8-1:0] o_dma_axi_wdata,
    output logic [       LINE_BYTES-1:0] o_dma_axi_wstrb,
    output logic                         o_dma_axi_wlast,
    input  logic                         i_dma_axi_bvalid,
    output logic                         o_dma_axi_bready,
    input  logic [  DMA_AXI_ID_BITS-1:0] i_dma_axi_bid,
    input  logic [                  1:0] i_dma_axi_bresp,
    output logic                         o_dma_axi_arvalid,
    input  logic                         i_dma_axi_arready,
    output logic [  DMA_AXI_ID_BITS-1:0] o_dma_axi_arid,
    output logic [DMA_AXI_ADDR_BITS-1:0] o_dma_axi_araddr,
    output logic [                  7:0] o_dma_axi_arlen,
    output logic [                  2:0] o_dma_axi_arsize,
    output logic [                  1:0] o_dma_axi_arburst,
    output logic                         o_dma_axi_arlock,
    output logic [                  3:0] o_dma_axi_arcache,
    output logic [                  2:0] o_dma_axi_arprot,
    output logic [                  3:0] o_dma_axi_arqos,
    input  logic                         i_dma_axi_rvalid,
    output logic                         o_dma_axi_rready,
    input  logic [  DMA_AXI_ID_BITS-1:0] i_dma_axi_rid,
    input  logic [     LINE_BYTES*8-1:0] i_dma_axi_rdata,
    input  logic [                  1:0] i_dma_axi_rresp,
    input  logic                         i_dma_axi_rlast,

    // MAC domains and the board.
    input  logic                            i_tx_clk,
    input  logic                            i_rx_clk,
    input  logic                            i_tx_clk_ok,
    input  logic                            i_rx_clk_ok,
    output logic [                    63:0] o_tx_raw_data,
    output logic                            o_tx_raw_valid,
    input  logic [                    63:0] i_rx_raw_data,
    input  logic                            i_rx_raw_valid,
    input  logic                            i_rx_signal_ok,
    input  logic [                     4:0] i_phy_status,
    input  logic [nic_pkg::PhyDiagBits-1:0] i_phy_diag = '0,
    output logic                            o_phy_diag_ack,
    output logic [                     3:1] o_phy_ctrl,
    output logic                            o_rx_block_lock
);
  localparam int unsigned LimitBits = $clog2(RX_FIFO_DEPTH) + 1;

  logic mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser;
  logic [63:0] mac_tx_tdata;
  logic [ 7:0] mac_tx_tkeep;
  logic [14:0] mac_tx_csum;

  logic mac_rx_tvalid, mac_rx_tready, mac_rx_tlast;
  logic [63:0] mac_rx_tdata;
  logic [ 7:0] mac_rx_tkeep;

  logic mac_rst, mac_soft_rst, mac_restart;
  logic [ 1:0] mac_ready;
  logic [ 7:0] mac_link;
  logic        mac_raw_loopback_en;
  logic        mac_loopback;
  logic [47:0] mac_station_addr;
  logic [ 1:0] mac_pause_ctrl;
  logic [LimitBits-1:0] mac_pause_high_water, mac_pause_low_water;
  logic [         15:0] mac_pause_interval;
  logic [LimitBits-1:0] mac_rx_fifo_limit;
  logic mac_rx_fifo_limit_wr, mac_rx_fifo_limit_busy;
  logic                                mac_rx_desc_starved;
  logic [nic_pkg::NumMacTotals*64-1:0] mac_totals;

  nic_engine #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES),
      .TICK_DEFAULT(TICK_DEFAULT),
      .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
      .STARVATION_LIMIT(STARVATION_LIMIT),
      .DMA_AXI_ADDR_BITS(DMA_AXI_ADDR_BITS),
      .DMA_AXI_ID_BITS(DMA_AXI_ID_BITS)
  ) u_engine (
      .i_clk                   (i_clk),
      .i_rst                   (i_rst),
      .i_reg_axil_awvalid      (i_reg_axil_awvalid),
      .o_reg_axil_awready      (o_reg_axil_awready),
      .i_reg_axil_awaddr       (i_reg_axil_awaddr),
      .i_reg_axil_awprot       (i_reg_axil_awprot),
      .i_reg_axil_wvalid       (i_reg_axil_wvalid),
      .o_reg_axil_wready       (o_reg_axil_wready),
      .i_reg_axil_wdata        (i_reg_axil_wdata),
      .i_reg_axil_wstrb        (i_reg_axil_wstrb),
      .o_reg_axil_bvalid       (o_reg_axil_bvalid),
      .i_reg_axil_bready       (i_reg_axil_bready),
      .o_reg_axil_bresp        (o_reg_axil_bresp),
      .i_reg_axil_arvalid      (i_reg_axil_arvalid),
      .o_reg_axil_arready      (o_reg_axil_arready),
      .i_reg_axil_araddr       (i_reg_axil_araddr),
      .i_reg_axil_arprot       (i_reg_axil_arprot),
      .o_reg_axil_rvalid       (o_reg_axil_rvalid),
      .i_reg_axil_rready       (i_reg_axil_rready),
      .o_reg_axil_rdata        (o_reg_axil_rdata),
      .o_reg_axil_rresp        (o_reg_axil_rresp),
      .o_irq                   (o_irq),
      .o_dma_axi_awvalid       (o_dma_axi_awvalid),
      .i_dma_axi_awready       (i_dma_axi_awready),
      .o_dma_axi_awid          (o_dma_axi_awid),
      .o_dma_axi_awaddr        (o_dma_axi_awaddr),
      .o_dma_axi_awlen         (o_dma_axi_awlen),
      .o_dma_axi_awsize        (o_dma_axi_awsize),
      .o_dma_axi_awburst       (o_dma_axi_awburst),
      .o_dma_axi_awlock        (o_dma_axi_awlock),
      .o_dma_axi_awcache       (o_dma_axi_awcache),
      .o_dma_axi_awprot        (o_dma_axi_awprot),
      .o_dma_axi_awqos         (o_dma_axi_awqos),
      .o_dma_axi_wvalid        (o_dma_axi_wvalid),
      .i_dma_axi_wready        (i_dma_axi_wready),
      .o_dma_axi_wdata         (o_dma_axi_wdata),
      .o_dma_axi_wstrb         (o_dma_axi_wstrb),
      .o_dma_axi_wlast         (o_dma_axi_wlast),
      .i_dma_axi_bvalid        (i_dma_axi_bvalid),
      .o_dma_axi_bready        (o_dma_axi_bready),
      .i_dma_axi_bid           (i_dma_axi_bid),
      .i_dma_axi_bresp         (i_dma_axi_bresp),
      .o_dma_axi_arvalid       (o_dma_axi_arvalid),
      .i_dma_axi_arready       (i_dma_axi_arready),
      .o_dma_axi_arid          (o_dma_axi_arid),
      .o_dma_axi_araddr        (o_dma_axi_araddr),
      .o_dma_axi_arlen         (o_dma_axi_arlen),
      .o_dma_axi_arsize        (o_dma_axi_arsize),
      .o_dma_axi_arburst       (o_dma_axi_arburst),
      .o_dma_axi_arlock        (o_dma_axi_arlock),
      .o_dma_axi_arcache       (o_dma_axi_arcache),
      .o_dma_axi_arprot        (o_dma_axi_arprot),
      .o_dma_axi_arqos         (o_dma_axi_arqos),
      .i_dma_axi_rvalid        (i_dma_axi_rvalid),
      .o_dma_axi_rready        (o_dma_axi_rready),
      .i_dma_axi_rid           (i_dma_axi_rid),
      .i_dma_axi_rdata         (i_dma_axi_rdata),
      .i_dma_axi_rresp         (i_dma_axi_rresp),
      .i_dma_axi_rlast         (i_dma_axi_rlast),
      .o_mac_tx_tvalid         (mac_tx_tvalid),
      .i_mac_tx_tready         (mac_tx_tready),
      .o_mac_tx_tdata          (mac_tx_tdata),
      .o_mac_tx_tkeep          (mac_tx_tkeep),
      .o_mac_tx_tlast          (mac_tx_tlast),
      .o_mac_tx_tuser          (mac_tx_tuser),
      .o_mac_tx_csum           (mac_tx_csum),
      .i_mac_rx_tvalid         (mac_rx_tvalid),
      .o_mac_rx_tready         (mac_rx_tready),
      .i_mac_rx_tdata          (mac_rx_tdata),
      .i_mac_rx_tkeep          (mac_rx_tkeep),
      .i_mac_rx_tlast          (mac_rx_tlast),
      .o_mac_rst               (mac_rst),
      .o_mac_soft_rst          (mac_soft_rst),
      .o_mac_restart           (mac_restart),
      .i_mac_ready             (mac_ready),
      .i_mac_link              (mac_link),
      .i_mac_raw_loopback_en   (mac_raw_loopback_en),
      .o_mac_loopback          (mac_loopback),
      .o_mac_station_addr      (mac_station_addr),
      .o_mac_pause_ctrl        (mac_pause_ctrl),
      .o_mac_pause_high_water  (mac_pause_high_water),
      .o_mac_pause_low_water   (mac_pause_low_water),
      .o_mac_pause_interval    (mac_pause_interval),
      .o_mac_rx_fifo_limit     (mac_rx_fifo_limit),
      .o_mac_rx_fifo_limit_wr  (mac_rx_fifo_limit_wr),
      .i_mac_rx_fifo_limit_busy(mac_rx_fifo_limit_busy),
      .o_mac_rx_desc_starved   (mac_rx_desc_starved),
      .i_mac_totals            (mac_totals),
      .i_phy_status            (i_phy_status),
      .i_phy_diag              (i_phy_diag),
      .o_phy_diag_ack          (o_phy_diag_ack),
      .o_phy_ctrl              (o_phy_ctrl)
  );

  if (!GMII_MODE) begin : gen_mac_10g
    nic_mac_10g #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .RAW_LOOPBACK(RAW_LOOPBACK)
    ) u_mac (
        .i_clk               (i_clk),
        .i_rst               (mac_rst),
        .i_soft_rst          (mac_soft_rst),
        .i_restart           (mac_restart),
        .o_ready             (mac_ready),
        .o_link              (mac_link),
        .o_raw_loopback_en   (mac_raw_loopback_en),
        .i_mac_loopback      (mac_loopback),
        .i_station_mac       (mac_station_addr),
        .i_pause_ctrl        (mac_pause_ctrl),
        .i_pause_high_water  (mac_pause_high_water),
        .i_pause_low_water   (mac_pause_low_water),
        .i_pause_interval    (mac_pause_interval),
        .i_rx_fifo_limit     (mac_rx_fifo_limit),
        .i_rx_fifo_limit_wr  (mac_rx_fifo_limit_wr),
        .o_rx_fifo_limit_busy(mac_rx_fifo_limit_busy),
        .i_rx_desc_starved   (mac_rx_desc_starved),
        .o_totals            (mac_totals),
        .s_axis_tx_tvalid    (mac_tx_tvalid),
        .s_axis_tx_tready    (mac_tx_tready),
        .s_axis_tx_tdata     (mac_tx_tdata),
        .s_axis_tx_tkeep     (mac_tx_tkeep),
        .s_axis_tx_tlast     (mac_tx_tlast),
        .s_axis_tx_tuser     (mac_tx_tuser),
        .i_tx_csum           (mac_tx_csum),
        .m_axis_rx_tvalid    (mac_rx_tvalid),
        .m_axis_rx_tready    (mac_rx_tready),
        .m_axis_rx_tdata     (mac_rx_tdata),
        .m_axis_rx_tkeep     (mac_rx_tkeep),
        .m_axis_rx_tlast     (mac_rx_tlast),
        .i_tx_clk            (i_tx_clk),
        .i_rx_clk            (i_rx_clk),
        .i_tx_clk_ok         (i_tx_clk_ok),
        .i_rx_clk_ok         (i_rx_clk_ok),
        .o_tx_raw_data       (o_tx_raw_data),
        .o_tx_raw_valid      (o_tx_raw_valid),
        .i_rx_raw_data       (i_rx_raw_data),
        .i_rx_raw_valid      (i_rx_raw_valid),
        .i_rx_signal_ok      (i_rx_signal_ok),
        .o_rx_block_lock     (o_rx_block_lock)
    );
  end else begin : gen_mac_1g
    logic [7:0] gmii_txd;
    logic gmii_tx_en, gmii_tx_er, gmii_tx_clk_en;
    /* verilator lint_off UNUSEDSIGNAL */
    wire rx_raw_unused = |i_rx_raw_data[63:26];
    /* verilator lint_on UNUSEDSIGNAL */

    nic_mac_1g #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .RAW_LOOPBACK(RAW_LOOPBACK),
        .RX_PREAMBLE_ER_TOLERANT(RX_PREAMBLE_ER_TOLERANT)
    ) u_mac (
        .i_clk               (i_clk),
        .i_rst               (mac_rst),
        .i_soft_rst          (mac_soft_rst),
        .i_restart           (mac_restart),
        .o_ready             (mac_ready),
        .o_link              (mac_link),
        .o_raw_loopback_en   (mac_raw_loopback_en),
        .i_mac_loopback      (mac_loopback),
        .i_station_mac       (mac_station_addr),
        .i_pause_ctrl        (mac_pause_ctrl),
        .i_pause_high_water  (mac_pause_high_water),
        .i_pause_low_water   (mac_pause_low_water),
        .i_pause_interval    (mac_pause_interval),
        .i_rx_fifo_limit     (mac_rx_fifo_limit),
        .i_rx_fifo_limit_wr  (mac_rx_fifo_limit_wr),
        .o_rx_fifo_limit_busy(mac_rx_fifo_limit_busy),
        .i_rx_desc_starved   (mac_rx_desc_starved),
        .o_totals            (mac_totals),
        .s_axis_tx_tvalid    (mac_tx_tvalid),
        .s_axis_tx_tready    (mac_tx_tready),
        .s_axis_tx_tdata     (mac_tx_tdata),
        .s_axis_tx_tkeep     (mac_tx_tkeep),
        .s_axis_tx_tlast     (mac_tx_tlast),
        .s_axis_tx_tuser     (mac_tx_tuser),
        .i_tx_csum           (mac_tx_csum),
        .m_axis_rx_tvalid    (mac_rx_tvalid),
        .m_axis_rx_tready    (mac_rx_tready),
        .m_axis_rx_tdata     (mac_rx_tdata),
        .m_axis_rx_tkeep     (mac_rx_tkeep),
        .m_axis_rx_tlast     (mac_rx_tlast),
        .i_tx_clk            (i_tx_clk),
        .i_rx_clk            (i_rx_clk),
        .i_tx_clk_ok         (i_tx_clk_ok),
        .i_rx_clk_ok         (i_rx_clk_ok),
        .o_gmii_txd          (gmii_txd),
        .o_gmii_tx_en        (gmii_tx_en),
        .o_gmii_tx_er        (gmii_tx_er),
        .o_gmii_tx_clk_en    (gmii_tx_clk_en),
        .i_gmii_rxd          (i_rx_raw_data[7:0]),
        .i_gmii_rx_dv        (i_rx_raw_data[8]),
        .i_gmii_rx_er        (i_rx_raw_data[9]),
        .i_gmii_rx_clk_en    (i_rx_raw_valid),
        .i_pcs_status        (i_rx_raw_data[25:10]),
        .i_rx_signal_ok      (i_rx_signal_ok),
        .o_rx_block_lock     (o_rx_block_lock)
    );
    assign o_tx_raw_data  = {54'b0, gmii_tx_er, gmii_tx_en, gmii_txd};
    assign o_tx_raw_valid = gmii_tx_clk_en;
  end
endmodule : nic_top
