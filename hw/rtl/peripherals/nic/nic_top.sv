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
 * NIC integration across the core and MAC clock domains.
 *
 * Toward the SoC: a 64-bit AXI4-Lite register slave, an AXI4 master for
 * DMA, and a level interrupt. The register bridge selects 32-bit write
 * lanes, complete wide-address writes, and aligned 64-bit read pairs. The DMA
 * master issues single-beat bursts of one 32-byte line (AxSIZE 5, INCR) at
 * full physical addresses, with ids of IdBits, AxCACHE 0011, AxPROT 010 and
 * AxLOCK 0; it always accepts B and R. Its line_port_axi_bridge resets with
 * the subsystem reset only: the RESET drain leaves it idle before the
 * front end's reset.
 * Toward the board: the MAC clocks, the raw PMA interface, the PHY status and
 * control lines, and the PCS block lock for a board-level transceiver
 * supervisor. RAW_LOOPBACK selects whether the raw TX-to-RX loopback exists
 * (nic_mac_wrap): 1 for one MAC clock shared by both directions, 0 for
 * independent TX and RX clocks, where PHY_STATUS reads CLK_SHARED as 0.
 *
 * i_rst carries the next-cycle value of the caller's registered subsystem
 * reset (the D input of soc_top's rst_core). nic_top registers it
 * as rst_q, which follows soc_top's rst_core. The core-domain reset
 * nic_rst_q, the OR of that reset and the RESET sequence's
 * pulse, is likewise a register computed one cycle ahead.
 */
module nic_top #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter logic [63:0] APERTURE_BASE = 64'h8000_0000,
    parameter logic [63:0] APERTURE_BYTES = 64'h4000_0000,
    parameter logic [31:0] TICK_DEFAULT = 32'd300,
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned STARVATION_LIMIT = 8,
    parameter int unsigned RAW_LOOPBACK = 1,
    parameter bit GMII_MODE = 1'b0,
    // The DMA master's AXI address and id widths; addresses are zero-extended
    // from ADDR_WIDTH and ids from IdBits.
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
    input  logic        i_tx_clk,
    input  logic        i_rx_clk,
    input  logic        i_tx_clk_ok,     // asynchronous levels
    input  logic        i_rx_clk_ok,
    output logic [63:0] o_tx_raw_data,
    output logic        o_tx_raw_valid,
    input  logic [63:0] i_rx_raw_data,
    input  logic        i_rx_raw_valid,
    input  logic        i_rx_signal_ok,
    input  logic [ 4:0] i_phy_status,    // asynchronous levels, nic_pkg PhyStatusBit*
    output logic [ 3:1] o_phy_ctrl,      // PHY_RESET, PMA_LOOPBACK, TX_DISABLE
    output logic        o_rx_block_lock  // PCS block lock, synchronized to i_clk (a flop)
);
  localparam int unsigned TagBits = 4;

  initial begin
    if (DMA_AXI_ID_BITS < IdBits) $fatal(1, "nic_top: DMA_AXI_ID_BITS must cover the 3 id bits");
    if (DMA_AXI_ADDR_BITS < ADDR_WIDTH) $fatal(1, "nic_top: DMA_AXI_ADDR_BITS below ADDR_WIDTH");
  end

  // ---- reset controller and the MAC domains -------------------------------------------
  logic reset_req, stop_dma, soft_rst, reset_busy, front_idle, wide_mode;
  logic [1:0] clk_ok, in_reset, applied_gen, applied_valid, req, gen, core_rst_dom, ready;
  // i_rst is the caller's next reset value, so rst_q matches its registered
  // reset. Compute nic_rst_q ahead of the edge to equal rst_q || soft_rst.
  logic core_rst_next;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 64 *)logic rst_q;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 128 *)logic nic_rst_q;
  logic reg_wr_en, reg_wr64_en;
  logic [11:0] reg_wr_offset, reg_rd_offset;
  logic [31:0] reg_wr_data;
  logic [63:0] reg_wr64_data, reg_rd_pair;
  axil_reg_bridge #(
      .ADDR_BITS(12),
      .WIDE_COUNT(2),
      .WIDE_OFFSETS({nic_pkg::TxBase64Offset, nic_pkg::RxBase64Offset})
  ) reg_bridge (
      .i_clk(i_clk),
      .i_rst(rst_q),
      .i_axil_awvalid(i_reg_axil_awvalid),
      .o_axil_awready(o_reg_axil_awready),
      .i_axil_awaddr(i_reg_axil_awaddr),
      .i_axil_awprot(i_reg_axil_awprot),
      .i_axil_wvalid(i_reg_axil_wvalid),
      .o_axil_wready(o_reg_axil_wready),
      .i_axil_wdata(i_reg_axil_wdata),
      .i_axil_wstrb(i_reg_axil_wstrb),
      .o_axil_bvalid(o_reg_axil_bvalid),
      .i_axil_bready(i_reg_axil_bready),
      .o_axil_bresp(o_reg_axil_bresp),
      .i_axil_arvalid(i_reg_axil_arvalid),
      .o_axil_arready(o_reg_axil_arready),
      .i_axil_araddr(i_reg_axil_araddr),
      .i_axil_arprot(i_reg_axil_arprot),
      .o_axil_rvalid(o_reg_axil_rvalid),
      .i_axil_rready(i_reg_axil_rready),
      .o_axil_rdata(o_reg_axil_rdata),
      .o_axil_rresp(o_reg_axil_rresp),
      .o_wr_en(reg_wr_en),
      .o_wr_offset(reg_wr_offset),
      .o_wr_data(reg_wr_data),
      .o_wr64_en(reg_wr64_en),
      .o_wr64_data(reg_wr64_data),
      .o_rd_offset(reg_rd_offset),
      .i_rd_pair(reg_rd_pair)
  );

  always_ff @(posedge i_clk) begin
    rst_q     <= i_rst;
    nic_rst_q <= i_rst || core_rst_next;
  end
`ifndef SYNTHESIS
  bit reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (rst_q) reset_seen_q <= 1'b1;
    if (reset_seen_q && !$isunknown({rst_q, soft_rst, nic_rst_q})) begin
      assert (nic_rst_q == (rst_q || soft_rst))
      else $error("nic_rst_q is not the registered reset OR the RESET pulse");
    end
  end
`endif

  cdc_sync #(
      .WIDTH(2)
  ) u_clk_ok_sync (
      .i_clk  (i_clk),
      .i_rst  (rst_q),
      .i_async({i_rx_clk_ok, i_tx_clk_ok}),
      .o_sync (clk_ok)
  );
  nic_reset_ctrl u_reset (
      .i_clk          (i_clk),
      .i_rst          (rst_q),
      .i_reset_req    (reset_req),
      .i_dma_idle     (front_idle),
      .o_stop_dma     (stop_dma),
      .o_core_rst     (soft_rst),
      .o_core_rst_next(core_rst_next),
      .o_busy         (reset_busy),
      .i_clk_ok       (clk_ok),
      .i_in_reset     (in_reset),
      .i_applied_gen  (applied_gen),
      .i_applied_valid(applied_valid),
      .o_req          (req),
      .o_gen          (gen),
      .o_core_rst_dom (core_rst_dom),
      .o_ready        (ready)
  );

  logic tx_fifo_valid, tx_fifo_ready, rx_fifo_valid, rx_fifo_ready;
  logic [63:0] tx_fifo_data, rx_fifo_data;
  logic [3:0] tx_fifo_code, rx_fifo_code;
  logic rx_locked, rx_high_ber, rx_local_fault, rx_remote_fault, tx_link_ready, rx_signal_ok;
  logic [5:0][63:0] mac_totals;
  logic [3:0] phy_ctrl;
  assign o_phy_ctrl = phy_ctrl[3:1];

  nic_mac_wrap #(
      .FIFO_DEPTH(FIFO_DEPTH),
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
      .RAW_LOOPBACK(RAW_LOOPBACK),
      .GMII_MODE(GMII_MODE)
  ) u_mac (
      .i_clk            (i_clk),
      .i_rst            (rst_q),
      .i_soft_rst       (soft_rst),
      .i_req            (req),
      .i_gen            (gen),
      .o_in_reset       (in_reset),
      .o_applied_gen    (applied_gen),
      .o_applied_valid  (applied_valid),
      .i_core_rst_dom   (core_rst_dom),
      .i_mac_loopback   (phy_ctrl[nic_pkg::PhyCtrlBitMacLoopback]),
      .i_tx_valid       (tx_fifo_valid),
      .o_tx_ready       (tx_fifo_ready),
      .i_tx_data        (tx_fifo_data),
      .i_tx_code        (tx_fifo_code),
      .o_rx_valid       (rx_fifo_valid),
      .i_rx_ready       (rx_fifo_ready),
      .o_rx_data        (rx_fifo_data),
      .o_rx_code        (rx_fifo_code),
      .o_rx_locked      (rx_locked),
      .o_rx_high_ber    (rx_high_ber),
      .o_rx_local_fault (rx_local_fault),
      .o_rx_remote_fault(rx_remote_fault),
      .o_tx_link_ready  (tx_link_ready),
      .o_rx_signal_ok   (rx_signal_ok),
      .o_totals         (mac_totals),
      .i_tx_clk         (i_tx_clk),
      .i_rx_clk         (i_rx_clk),
      .o_tx_raw_data    (o_tx_raw_data),
      .o_tx_raw_valid   (o_tx_raw_valid),
      .i_rx_raw_data    (i_rx_raw_data),
      .i_rx_raw_valid   (i_rx_raw_valid),
      .i_rx_signal_ok   (i_rx_signal_ok)
  );
  // The block lock leaves as the status synchronizer's output register.
  assign o_rx_block_lock = rx_locked;

  // ---- registers and interrupts ----------------------------------------------------------
  logic rx_en, tx_en, promisc, rx_restart, tx_restart;
  logic [47:0] mac;
  logic [ADDR_WIDTH-1:0] rx_base, tx_base;
  logic [4:0] rx_size, tx_size;
  logic [15:0] rx_tail, tx_tail, rx_head, tx_head;
  logic rx_idle, tx_idle;
  logic link_change, desc_err, rx_drop;
  logic [31:0] irq_status, irq_mask, rx_itr, tx_itr, tick;
  logic rx_complete, tx_complete, rx_filtered;
  logic [2:0] rx_complete_flags, tx_complete_flags;
  logic [15:0] rx_complete_bytes, tx_complete_bytes;
  logic [4:0] phy_status_sync, phy_status;
  cdc_sync #(
      .WIDTH(5)
  ) u_phy_status_sync (
      .i_clk  (i_clk),
      .i_rst  (rst_q),
      .i_async(i_phy_status),
      .o_sync (phy_status_sync)
  );
  // Software chooses MAC_LOOPBACK from CLK_SHARED, so a build without the raw
  // loopback reports it as 0 whatever the board drives.
  always_comb begin
    phy_status = phy_status_sync;
    if (RAW_LOOPBACK == 0) phy_status[nic_pkg::PhyStatusBitClkShared] = 1'b0;
  end

  nic_csr #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_csr (
      .i_clk(i_clk),
      .i_rst(rst_q),
      .i_soft_rst(soft_rst),
      .i_wr_en(reg_wr_en),
      .i_wr_offset(reg_wr_offset),
      .i_wr_data(reg_wr_data),
      .i_wr64_en(reg_wr64_en),
      .i_wr64_data(reg_wr64_data),
      .i_rd_offset(reg_rd_offset),
      .o_rd_pair(reg_rd_pair),
      .i_irq_status(irq_status),
      .i_irq_mask(irq_mask),
      .i_rx_itr(rx_itr),
      .i_tx_itr(tx_itr),
      .i_tick(tick),
      .o_rx_en(rx_en),
      .o_tx_en(tx_en),
      .o_wide_mode(wide_mode),
      .o_promisc(promisc),
      .o_mac(mac),
      .o_reset_req(reset_req),
      .o_rx_base(rx_base),
      .o_tx_base(tx_base),
      .o_rx_size_log2(rx_size),
      .o_tx_size_log2(tx_size),
      .o_rx_tail(rx_tail),
      .o_tx_tail(tx_tail),
      .o_rx_restart(rx_restart),
      .o_tx_restart(tx_restart),
      .o_phy_ctrl(phy_ctrl),
      .i_rx_head(rx_head),
      .i_tx_head(tx_head),
      .i_rx_idle(rx_idle),
      .i_tx_idle(tx_idle),
      .i_reset_busy(reset_busy),
      .i_rx_fifo_empty(!rx_fifo_valid),
      .i_rx_ready(ready[1]),
      .i_tx_ready(ready[0]),
      .i_link({
        clk_ok[1],
        clk_ok[0],
        rx_signal_ok,
        tx_link_ready,
        rx_remote_fault,
        rx_local_fault,
        rx_high_ber,
        rx_locked
      }),
      .i_phy_status(phy_status),
      .i_rx_complete(rx_complete),
      .i_rx_complete_flags(rx_complete_flags),
      .i_rx_complete_bytes(rx_complete_bytes),
      .i_rx_filtered(rx_filtered),
      .i_tx_complete(tx_complete),
      .i_tx_complete_flags(tx_complete_flags),
      .i_tx_complete_bytes(tx_complete_bytes),
      .i_mac_totals(mac_totals),
      .o_link_change(link_change),
      .o_desc_err(desc_err),
      .o_rx_drop(rx_drop)
  );

  nic_irq #(
      .TICK_DEFAULT(TICK_DEFAULT)
  ) u_irq (
      .i_clk        (i_clk),
      .i_rst        (nic_rst_q),
      .i_wr_en      (reg_wr_en && !reset_busy && !reset_req),
      .i_wr_offset  (reg_wr_offset),
      .i_wr_data    (reg_wr_data),
      .o_status     (irq_status),
      .o_mask       (irq_mask),
      .o_rx_itr     (rx_itr),
      .o_tx_itr     (tx_itr),
      .o_tick       (tick),
      .i_rx_done    (rx_complete),
      .i_tx_done    (tx_complete),
      .i_rx_drop    (rx_drop),
      .i_link_change(link_change),
      .i_desc_err   (desc_err),
      .o_irq        (o_irq)
  );

  // ---- engines and the front-end -----------------------------------------------------------
  logic [1:0] req_valid, req_ready, req_write, resp_valid, resp_error;
  logic [1:0][  ADDR_WIDTH-1:0] req_addr;
  logic [1:0][LINE_BYTES*8-1:0] req_wdata;
  logic [1:0][  LINE_BYTES-1:0] req_wstrb;
  logic [1:0][1:0] req_kind, resp_kind;
  logic [1:0][TagBits-1:0] req_tag, resp_tag;
  logic [LINE_BYTES*8-1:0] resp_rdata;

  nic_rx_engine #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .TAG_BITS(TagBits),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_rx (
      .i_clk           (i_clk),
      .i_rst           (nic_rst_q),
      .i_enable        (rx_en),
      .i_wide_mode     (wide_mode),
      .i_base          (rx_base),
      .i_size_log2     (rx_size),
      .i_tail          (rx_tail),
      .i_restart       (rx_restart),
      .i_promisc       (promisc),
      .i_mac           (mac),
      .i_stop          (stop_dma),
      .i_abort         (!ready[1]),
      .o_head          (rx_head),
      .o_idle          (rx_idle),
      .i_fifo_valid    (rx_fifo_valid),
      .o_fifo_ready    (rx_fifo_ready),
      .i_fifo_data     (rx_fifo_data),
      .i_fifo_code     (rx_fifo_code),
      .o_req_valid     (req_valid[0]),
      .i_req_ready     (req_ready[0]),
      .o_req_write     (req_write[0]),
      .o_req_addr      (req_addr[0]),
      .o_req_wdata     (req_wdata[0]),
      .o_req_wstrb     (req_wstrb[0]),
      .o_req_kind      (req_kind[0]),
      .o_req_tag       (req_tag[0]),
      .i_resp_valid    (resp_valid[0]),
      .i_resp_kind     (resp_kind[0]),
      .i_resp_tag      (resp_tag[0]),
      .i_resp_error    (resp_error[0]),
      .i_resp_rdata    (resp_rdata),
      .o_complete      (rx_complete),
      .o_complete_flags(rx_complete_flags),
      .o_complete_bytes(rx_complete_bytes),
      .o_filtered      (rx_filtered)
  );

  nic_tx_engine #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .TAG_BITS(TagBits),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_tx (
      .i_clk           (i_clk),
      .i_rst           (nic_rst_q),
      .i_enable        (tx_en),
      .i_wide_mode     (wide_mode),
      .i_base          (tx_base),
      .i_size_log2     (tx_size),
      .i_tail          (tx_tail),
      .i_restart       (tx_restart),
      .i_stop          (stop_dma),
      .i_abort         (!ready[0]),
      .o_head          (tx_head),
      .o_idle          (tx_idle),
      .o_fifo_valid    (tx_fifo_valid),
      .i_fifo_ready    (tx_fifo_ready),
      .o_fifo_data     (tx_fifo_data),
      .o_fifo_code     (tx_fifo_code),
      .o_req_valid     (req_valid[1]),
      .i_req_ready     (req_ready[1]),
      .o_req_write     (req_write[1]),
      .o_req_addr      (req_addr[1]),
      .o_req_wdata     (req_wdata[1]),
      .o_req_wstrb     (req_wstrb[1]),
      .o_req_kind      (req_kind[1]),
      .o_req_tag       (req_tag[1]),
      .i_resp_valid    (resp_valid[1]),
      .i_resp_kind     (resp_kind[1]),
      .i_resp_tag      (resp_tag[1]),
      .i_resp_error    (resp_error[1]),
      .i_resp_rdata    (resp_rdata),
      .o_complete      (tx_complete),
      .o_complete_flags(tx_complete_flags),
      .o_complete_bytes(tx_complete_bytes)
  );

  // The front end's line port, carried by the AXI master below.
  logic dma_req_valid, dma_req_ready, dma_req_write, dma_resp_valid, dma_resp_error;
  logic [ADDR_WIDTH-1:0] dma_req_addr;
  logic [LINE_BYTES*8-1:0] dma_req_wdata, dma_resp_rdata;
  logic [LINE_BYTES-1:0] dma_req_wstrb;
  logic [IdBits-1:0] dma_req_id, dma_resp_id;

  nic_dma_front #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .NUM_ENTRIES(8),
      .SIDE_CAP(6),
      .STARVATION_LIMIT(STARVATION_LIMIT),
      .TAG_BITS(TagBits),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_front (
      .i_clk           (i_clk),
      .i_rst           (nic_rst_q),
      .i_stop          (stop_dma),
      .o_idle          (front_idle),
      .i_req_valid     (req_valid),
      .o_req_ready     (req_ready),
      .i_req_write     (req_write),
      .i_req_addr      (req_addr),
      .i_req_wdata     (req_wdata),
      .i_req_wstrb     (req_wstrb),
      .i_req_kind      (req_kind),
      .i_req_tag       (req_tag),
      .o_resp_valid    (resp_valid),
      .o_resp_kind     (resp_kind),
      .o_resp_tag      (resp_tag),
      .o_resp_error    (resp_error),
      .o_resp_rdata    (resp_rdata),
      .o_dma_req_valid (dma_req_valid),
      .i_dma_req_ready (dma_req_ready),
      .o_dma_req_write (dma_req_write),
      .o_dma_req_addr  (dma_req_addr),
      .o_dma_req_wdata (dma_req_wdata),
      .o_dma_req_wstrb (dma_req_wstrb),
      .o_dma_req_id    (dma_req_id),
      .i_dma_resp_valid(dma_resp_valid),
      .i_dma_resp_error(dma_resp_error),
      .i_dma_resp_id   (dma_resp_id),
      .i_dma_resp_rdata(dma_resp_rdata)
  );

  // ---- the DMA AXI4 master ---------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] dma_axi_awaddr, dma_axi_araddr;
  logic [IdBits-1:0] dma_axi_awid, dma_axi_arid;
  line_port_axi_bridge #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .AXI_ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .ID_BITS(IdBits),
      .AXI_ID_BITS(IdBits),
      .BASE_ADDR('0),
      .RESP_ERRORS(1'b1)
  ) u_dma_axi (
      .i_clk         (i_clk),
      .i_rst         (rst_q),
      .i_axi_rst     (rst_q),
      .i_req_valid   (dma_req_valid),
      .o_req_ready   (dma_req_ready),
      .i_req_write   (dma_req_write),
      .i_req_addr    (dma_req_addr),
      .i_req_wdata   (dma_req_wdata),
      .i_req_wstrb   (dma_req_wstrb),
      .i_req_id      (dma_req_id),
      .o_resp_valid  (dma_resp_valid),
      .o_resp_id     (dma_resp_id),
      .o_resp_rdata  (dma_resp_rdata),
      .o_resp_error  (dma_resp_error),
      .o_axi_awvalid (o_dma_axi_awvalid),
      .i_axi_awready (i_dma_axi_awready),
      .o_axi_awid    (dma_axi_awid),
      .o_axi_awaddr  (dma_axi_awaddr),
      .o_axi_awlen   (o_dma_axi_awlen),
      .o_axi_awsize  (o_dma_axi_awsize),
      .o_axi_awburst (o_dma_axi_awburst),
      .o_axi_wvalid  (o_dma_axi_wvalid),
      .i_axi_wready  (i_dma_axi_wready),
      .o_axi_wdata   (o_dma_axi_wdata),
      .o_axi_wstrb   (o_dma_axi_wstrb),
      .o_axi_wlast   (o_dma_axi_wlast),
      .i_axi_bvalid  (i_dma_axi_bvalid),
      .o_axi_bready  (o_dma_axi_bready),
      .i_axi_bid     (IdBits'(i_dma_axi_bid)),
      .i_axi_bresp   (i_dma_axi_bresp),
      .o_axi_arvalid (o_dma_axi_arvalid),
      .i_axi_arready (i_dma_axi_arready),
      .o_axi_arid    (dma_axi_arid),
      .o_axi_araddr  (dma_axi_araddr),
      .o_axi_arlen   (o_dma_axi_arlen),
      .o_axi_arsize  (o_dma_axi_arsize),
      .o_axi_arburst (o_dma_axi_arburst),
      .i_axi_rvalid  (i_dma_axi_rvalid),
      .o_axi_rready  (o_dma_axi_rready),
      .i_axi_rid     (IdBits'(i_dma_axi_rid)),
      .i_axi_rdata   (i_dma_axi_rdata),
      .i_axi_rresp   (i_dma_axi_rresp),
      .i_axi_rlast   (i_dma_axi_rlast),
      .o_rd_err_valid(),
      .o_rd_err_resp (),
      .o_rd_err_id   (),
      .o_wr_err_valid(),
      .o_wr_err_resp (),
      .o_wr_err_id   ()
  );
  assign o_dma_axi_awid    = DMA_AXI_ID_BITS'(dma_axi_awid);
  assign o_dma_axi_arid    = DMA_AXI_ID_BITS'(dma_axi_arid);
  assign o_dma_axi_awaddr  = DMA_AXI_ADDR_BITS'(dma_axi_awaddr);
  assign o_dma_axi_araddr  = DMA_AXI_ADDR_BITS'(dma_axi_araddr);
  assign o_dma_axi_awlock  = 1'b0;
  assign o_dma_axi_arlock  = 1'b0;
  assign o_dma_axi_awcache = 4'b0011;
  assign o_dma_axi_arcache = 4'b0011;
  assign o_dma_axi_awprot  = 3'b010;
  assign o_dma_axi_arprot  = 3'b010;
  assign o_dma_axi_awqos   = 4'd0;
  assign o_dma_axi_arqos   = 4'd0;
endmodule : nic_top
