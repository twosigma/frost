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
 * nic_top: the NIC. The core-domain side (registers, interrupt block, reset
 * controller, DMA front-end, RX and TX engines) around nic_mac_wrap (the
 * MAC/PCS in its own clock domains, the packet FIFOs and the crossings).
 *
 * Toward the SoC: the register window (32-bit lane writes and a 64-bit
 * read pair by byte offset), one DMA line port (ids of IdBits), a level
 * interrupt, the MAC clocks, the raw PMA interface and the board's PHY
 * status and control lines.
 */
module nic_top #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000,
    parameter logic [31:0] TICK_DEFAULT = 32'd300,
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned STARVATION_LIMIT = 8,
    localparam int unsigned IdBits = 2
) (
    input logic i_clk,
    input logic i_rst,

    // Register window.
    input  logic        i_wr_en,
    input  logic [11:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    input  logic [11:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    output logic        o_irq,

    // DMA line port (master).
    output logic                    o_dma_req_valid,
    input  logic                    i_dma_req_ready,
    output logic                    o_dma_req_write,
    output logic [  ADDR_WIDTH-1:0] o_dma_req_addr,
    output logic [LINE_BYTES*8-1:0] o_dma_req_wdata,
    output logic [  LINE_BYTES-1:0] o_dma_req_wstrb,
    output logic [      IdBits-1:0] o_dma_req_id,
    input  logic                    i_dma_resp_valid,
    input  logic [      IdBits-1:0] i_dma_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_dma_resp_rdata,

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
    output logic [ 3:1] o_phy_ctrl       // PHY_RESET, PMA_LOOPBACK, TX_DISABLE
);
  localparam int unsigned TagBits = 4;

  // ---- reset controller and the MAC domains -------------------------------------------
  logic reset_req, stop_dma, soft_rst, reset_busy, front_idle;
  logic [1:0] clk_ok, in_reset, applied_gen, applied_valid, req, gen, core_rst_dom, ready;
  logic nic_rst;
  assign nic_rst = i_rst || soft_rst;

  cdc_sync #(
      .WIDTH(2)
  ) u_clk_ok_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async({i_rx_clk_ok, i_tx_clk_ok}),
      .o_sync (clk_ok)
  );
  nic_reset_ctrl u_reset (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_reset_req    (reset_req),
      .i_dma_idle     (front_idle),
      .o_stop_dma     (stop_dma),
      .o_core_rst     (soft_rst),
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
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_mac (
      .i_clk            (i_clk),
      .i_rst            (i_rst),
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
  logic [4:0] phy_status;
  cdc_sync #(
      .WIDTH(5)
  ) u_phy_status_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(i_phy_status),
      .o_sync (phy_status)
  );

  nic_csr #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_csr (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_soft_rst(soft_rst),
      .i_wr_en(i_wr_en),
      .i_wr_offset(i_wr_offset),
      .i_wr_data(i_wr_data),
      .i_rd_offset(i_rd_offset),
      .o_rd_pair(o_rd_pair),
      .i_irq_status(irq_status),
      .i_irq_mask(irq_mask),
      .i_rx_itr(rx_itr),
      .i_tx_itr(tx_itr),
      .i_tick(tick),
      .o_rx_en(rx_en),
      .o_tx_en(tx_en),
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
      .i_rst        (nic_rst),
      .i_wr_en      (i_wr_en && !reset_busy && !reset_req),
      .i_wr_offset  (i_wr_offset),
      .i_wr_data    (i_wr_data),
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
      .i_rst           (nic_rst),
      .i_enable        (rx_en),
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
      .i_rst           (nic_rst),
      .i_enable        (tx_en),
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

  nic_dma_front #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .NUM_ENTRIES(4),
      .SIDE_CAP(3),
      .STARVATION_LIMIT(STARVATION_LIMIT),
      .TAG_BITS(TagBits),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) u_front (
      .i_clk           (i_clk),
      .i_rst           (nic_rst),
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
      .o_dma_req_valid (o_dma_req_valid),
      .i_dma_req_ready (i_dma_req_ready),
      .o_dma_req_write (o_dma_req_write),
      .o_dma_req_addr  (o_dma_req_addr),
      .o_dma_req_wdata (o_dma_req_wdata),
      .o_dma_req_wstrb (o_dma_req_wstrb),
      .o_dma_req_id    (o_dma_req_id),
      .i_dma_resp_valid(i_dma_resp_valid),
      .i_dma_resp_id   (i_dma_resp_id),
      .i_dma_resp_rdata(i_dma_resp_rdata)
  );
endmodule : nic_top
