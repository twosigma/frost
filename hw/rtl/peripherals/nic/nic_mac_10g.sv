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
 * nic_mac_10g: pluggable 10GBASE-R MAC and 64b/66b PCS block.
 *
 * Connects to nic_engine over a pure core-clock (i_clk) 64-bit AXI4-Stream
 * and sideband interface, and to a board transceiver (GTY or loopback) over
 * the 64-bit raw PMA interface in i_tx_clk and i_rx_clk. RAW_LOOPBACK = 1
 * builds the raw TX-to-RX loopback behind PHY_CTRL.MAC_LOOPBACK (requires a
 * shared MAC clock); RAW_LOOPBACK = 0 omits it for independent TX and RX
 * clocks and reports o_raw_loopback_en = 0.
 */
module nic_mac_10g #(
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int unsigned RX_FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned RAW_LOOPBACK = 1,
    localparam int unsigned LimitBits = $clog2(RX_FIFO_DEPTH) + 1
) (
    // Core clock domain (nic_engine boundary).
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_soft_rst,
    input  logic                                i_restart,
    output logic [                         1:0] o_ready,
    output logic [                         7:0] o_link,
    output logic                                o_raw_loopback_en,
    input  logic                                i_mac_loopback,
    input  logic [                        47:0] i_station_mac,
    input  logic [                         1:0] i_pause_ctrl,
    input  logic [               LimitBits-1:0] i_pause_high_water,
    input  logic [               LimitBits-1:0] i_pause_low_water,
    input  logic [                        15:0] i_pause_interval,
    input  logic [               LimitBits-1:0] i_rx_fifo_limit,
    input  logic                                i_rx_fifo_limit_wr,
    output logic                                o_rx_fifo_limit_busy,
    input  logic                                i_rx_desc_starved,
    output logic [nic_pkg::NumMacTotals*64-1:0] o_totals,

    // Core-clock AXI4-Stream TX slave (from nic_engine).
    input  logic        s_axis_tx_tvalid,
    output logic        s_axis_tx_tready,
    input  logic [63:0] s_axis_tx_tdata,
    input  logic [ 7:0] s_axis_tx_tkeep,
    input  logic        s_axis_tx_tlast,
    input  logic        s_axis_tx_tuser,
    input  logic [14:0] i_tx_csum,

    // Core-clock AXI4-Stream RX master (toward nic_engine).
    output logic        m_axis_rx_tvalid,
    input  logic        m_axis_rx_tready,
    output logic [63:0] m_axis_rx_tdata,
    output logic [ 7:0] m_axis_rx_tkeep,
    output logic        m_axis_rx_tlast,

    // 10GBASE-R PMA wire interface.
    input  logic        i_tx_clk,
    input  logic        i_rx_clk,
    input  logic        i_tx_clk_ok,
    input  logic        i_rx_clk_ok,
    output logic [63:0] o_tx_raw_data,
    output logic        o_tx_raw_valid,
    input  logic [63:0] i_rx_raw_data,
    input  logic        i_rx_raw_valid,
    input  logic        i_rx_signal_ok,
    output logic        o_rx_block_lock  // PCS block lock, synchronized to i_clk (a flop)
);
  logic tx_rst, rx_rst;
  logic mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser, mac_tx_csum_en;
  logic [63:0] mac_tx_tdata;
  logic [7:0] mac_tx_tkeep, mac_tx_csum_start, mac_tx_csum_offset;
  logic mac_rx_tvalid, mac_rx_tready, mac_rx_tlast;
  logic [63:0] mac_rx_tdata;
  logic [7:0] mac_rx_tkeep;
  logic [63:0] rx_wire_data;
  logic [7:0] rx_wire_ctrl;
  logic rx_wire_valid;
  logic tx_tick;
  logic rx_locked, rx_high_ber, rx_local_fault, rx_remote_fault, tx_link_ready;
  logic tx_drop, rx_bad_frame, rx_bad_fcs, rx_overflow, tx_bad_block, rx_bad_block;
  logic m_user;

  logic [63:0] rx_raw_data;
  logic rx_raw_valid, rx_signal_ok;

  assign o_raw_loopback_en = (RAW_LOOPBACK != 0);

  nic_mac_cdc #(
      .FIFO_DEPTH(FIFO_DEPTH),
      .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
      .GMII_MODE(1'b0)
  ) u_cdc (
      .i_clk                   (i_clk),
      .i_rst                   (i_rst),
      .i_soft_rst              (i_soft_rst),
      .i_restart               (i_restart),
      .o_ready                 (o_ready),
      .o_link                  (o_link),
      .i_station_mac           (i_station_mac),
      .i_pause_ctrl            (i_pause_ctrl),
      .i_pause_high_water      (i_pause_high_water),
      .i_pause_low_water       (i_pause_low_water),
      .i_pause_interval        (i_pause_interval),
      .i_rx_fifo_limit         (i_rx_fifo_limit),
      .i_rx_fifo_limit_wr      (i_rx_fifo_limit_wr),
      .o_rx_fifo_limit_busy    (o_rx_fifo_limit_busy),
      .i_rx_desc_starved       (i_rx_desc_starved),
      .o_totals                (o_totals),
      .s_axis_tx_tvalid        (s_axis_tx_tvalid),
      .s_axis_tx_tready        (s_axis_tx_tready),
      .s_axis_tx_tdata         (s_axis_tx_tdata),
      .s_axis_tx_tkeep         (s_axis_tx_tkeep),
      .s_axis_tx_tlast         (s_axis_tx_tlast),
      .s_axis_tx_tuser         (s_axis_tx_tuser),
      .i_tx_csum               (i_tx_csum),
      .m_axis_rx_tvalid        (m_axis_rx_tvalid),
      .m_axis_rx_tready        (m_axis_rx_tready),
      .m_axis_rx_tdata         (m_axis_rx_tdata),
      .m_axis_rx_tkeep         (m_axis_rx_tkeep),
      .m_axis_rx_tlast         (m_axis_rx_tlast),
      .i_tx_clk                (i_tx_clk),
      .i_rx_clk                (i_rx_clk),
      .i_tx_clk_ok             (i_tx_clk_ok),
      .i_rx_clk_ok             (i_rx_clk_ok),
      .o_tx_rst                (tx_rst),
      .o_rx_rst                (rx_rst),
      .o_mac_tx_tvalid         (mac_tx_tvalid),
      .i_mac_tx_tready         (mac_tx_tready),
      .o_mac_tx_tdata          (mac_tx_tdata),
      .o_mac_tx_tkeep          (mac_tx_tkeep),
      .o_mac_tx_tlast          (mac_tx_tlast),
      .o_mac_tx_tuser          (mac_tx_tuser),
      .o_mac_tx_csum_en        (mac_tx_csum_en),
      .o_mac_tx_csum_start     (mac_tx_csum_start),
      .o_mac_tx_csum_offset    (mac_tx_csum_offset),
      .i_tx_tick               (tx_tick),
      .i_mac_rx_tvalid         (mac_rx_tvalid),
      .o_mac_rx_tready         (mac_rx_tready),
      .i_mac_rx_tdata          (mac_rx_tdata),
      .i_mac_rx_tkeep          (mac_rx_tkeep),
      .i_mac_rx_tlast          (mac_rx_tlast),
      .i_rx_wire_data          (rx_wire_data),
      .i_rx_wire_ctrl          (rx_wire_ctrl),
      .i_rx_wire_valid         (rx_wire_valid),
      .i_rx_locked             (rx_locked),
      .i_rx_high_ber           (rx_high_ber),
      .i_rx_local_fault        (rx_local_fault),
      .i_rx_remote_fault       (rx_remote_fault),
      .i_rx_signal_ok          (rx_signal_ok),
      .i_tx_link_ready         (tx_link_ready),
      .i_rx_overflow           (rx_overflow),
      .i_rx_bad_frame          (rx_bad_frame),
      .i_rx_bad_fcs            (rx_bad_fcs),
      .i_rx_bad_block          (rx_bad_block),
      .i_tx_drop               (tx_drop),
      .i_tx_bad_block          (tx_bad_block),
      .i_gmii_preamble_drop    (1'b0),
      .i_gmii_rx_er_event      (1'b0),
      .i_gmii_er_preamble_event(1'b0),
      .i_gmii_er_ext_event     (1'b0),
      .i_gmii_short_ifg_event  (1'b0),
      .i_gmii_pre_accept_event (1'b0),
      .i_pcs_event             (5'b0)
  );
  assign o_rx_block_lock = o_link[nic_pkg::LinkBitRxLocked];

  // ---- raw loopback -----------------------------------------------------------------------
  if (RAW_LOOPBACK != 0) begin : gen_raw_loopback
    logic loop_sync, loop_q;
    cdc_sync u_loop_sync (
        .i_clk  (i_rx_clk),
        .i_rst  (1'b0),
        .i_async(i_mac_loopback),
        .o_sync (loop_sync)
    );
    always_ff @(posedge i_rx_clk) begin
      if (rx_rst) loop_q <= loop_sync;
    end
    assign rx_raw_data  = loop_q ? o_tx_raw_data : i_rx_raw_data;
    assign rx_raw_valid = loop_q ? o_tx_raw_valid : i_rx_raw_valid;
    assign rx_signal_ok = loop_q ? 1'b1 : i_rx_signal_ok;
  end else begin : gen_no_raw_loopback
    assign rx_raw_data  = i_rx_raw_data;
    assign rx_raw_valid = i_rx_raw_valid;
    assign rx_signal_ok = i_rx_signal_ok;
    /* verilator lint_off UNUSEDSIGNAL */
    logic mac_loopback_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign mac_loopback_unused = i_mac_loopback;
  end

  // ---- 10GBASE-R MAC and 64b/66b PCS ------------------------------------------------------
  eth10g_mac_pcs #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_mac (
      .i_tx_clk         (i_tx_clk),
      .i_tx_rst         (tx_rst),
      .i_rx_clk         (i_rx_clk),
      .i_rx_rst         (rx_rst),
      .s_axis_tdata     (mac_tx_tdata),
      .s_axis_tkeep     (mac_tx_tkeep),
      .s_axis_tvalid    (mac_tx_tvalid),
      .s_axis_tready    (mac_tx_tready),
      .s_axis_tlast     (mac_tx_tlast),
      .s_axis_tuser     (mac_tx_tuser),
      .i_csum_en        (mac_tx_csum_en),
      .i_csum_start     (mac_tx_csum_start),
      .i_csum_offset    (mac_tx_csum_offset),
      .m_axis_tdata     (mac_rx_tdata),
      .m_axis_tkeep     (mac_rx_tkeep),
      .m_axis_tvalid    (mac_rx_tvalid),
      .m_axis_tready    (mac_rx_tready),
      .m_axis_tlast     (mac_rx_tlast),
      .m_axis_tuser     (m_user),
      .o_tx_raw_data    (o_tx_raw_data),
      .o_tx_raw_valid   (o_tx_raw_valid),
      .o_tx_link_ready  (tx_link_ready),
      .o_tx_word_tick   (tx_tick),
      .i_rx_raw_data    (rx_raw_data),
      .i_rx_raw_valid   (rx_raw_valid),
      .i_rx_signal_ok   (rx_signal_ok),
      .o_rx_xgmii_data  (rx_wire_data),
      .o_rx_xgmii_ctrl  (rx_wire_ctrl),
      .o_rx_xgmii_valid (rx_wire_valid),
      .o_rx_locked      (rx_locked),
      .o_rx_high_ber    (rx_high_ber),
      .o_rx_local_fault (rx_local_fault),
      .o_rx_remote_fault(rx_remote_fault),
      .o_tx_drop        (tx_drop),
      .o_rx_bad_frame   (rx_bad_frame),
      .o_rx_bad_fcs     (rx_bad_fcs),
      .o_rx_overflow    (rx_overflow),
      .o_tx_bad_block   (tx_bad_block),
      .o_rx_bad_block   (rx_bad_block)
  );
  /* verilator lint_off UNUSEDSIGNAL */  // the RX MAC publishes complete frames only: tuser is 0
  logic m_user_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign m_user_unused = m_user;
endmodule : nic_mac_10g
