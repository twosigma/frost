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
 * nic_mac_1g: pluggable 10/100/1000BASE-T GMII MAC block.
 *
 * Connects to nic_engine over the same pure core-clock (i_clk) 64-bit
 * AXI4-Stream and sideband interface as nic_mac_10g, and to a board SGMII
 * PCS/PMA core (or GMII PHY) over 8-bit GMII ports plus the 16-bit PCS
 * status_vector level in i_rx_clk.
 *
 * Internally, nic_mac_cdc handles the core-to-MAC clock crossings, reset
 * handshakes, 802.3x PAUSE, and Gray-coded event counters, while an 8-bit
 * GMII serializer/deserializer adapts eth10g_mac_tx and eth10g_mac_rx to
 * byte-wide GMII with rate-adaptation clock enable (i_gmii_rx_clk_en).
 */
module nic_mac_1g #(
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int unsigned RX_FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned RAW_LOOPBACK = 1,
    // 1 = a frame whose preamble holds one lone rx_er before a valid SFD is
    // accepted, the errored byte counted as a preamble byte; 0 = dropped.
    parameter bit RX_PREAMBLE_ER_TOLERANT = 1'b0,
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

    // GMII / SGMII PCS wire interface.
    input  logic        i_tx_clk,
    input  logic        i_rx_clk,
    input  logic        i_tx_clk_ok,
    input  logic        i_rx_clk_ok,
    output logic [ 7:0] o_gmii_txd,
    output logic        o_gmii_tx_en,
    output logic        o_gmii_tx_er,
    output logic        o_gmii_tx_clk_en,
    input  logic [ 7:0] i_gmii_rxd,
    input  logic        i_gmii_rx_dv,
    input  logic        i_gmii_rx_er,
    input  logic        i_gmii_rx_clk_en,
    input  logic [15:0] i_pcs_status,
    input  logic        i_rx_signal_ok,
    output logic        o_rx_block_lock    // link-up level, synchronized to i_clk (a flop)
);
  logic tx_rst, rx_rst;
  logic mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser, mac_tx_csum_en;
  logic [63:0] mac_tx_tdata;
  logic [7:0] mac_tx_tkeep, mac_tx_csum_start, mac_tx_csum_offset;
  logic mac_rx_tvalid, mac_rx_tready, mac_rx_tlast;
  logic [63:0] mac_rx_tdata;
  logic [7:0] mac_rx_tkeep;
  logic [63:0] xgmii_rx_data_q;
  logic [7:0] xgmii_rx_ctrl_q;
  logic xgmii_rx_en_q;
  logic tx_tick, tx_link_ready, rx_signal_ok;
  logic tx_drop, rx_bad_frame, rx_bad_fcs, rx_overflow;
  logic gmii_preamble_drop, gmii_rx_er_event;
  logic gmii_er_preamble_event, gmii_er_ext_event, gmii_short_ifg_event, gmii_pre_accept_event;
  logic [4:0] pcs_event;
  logic m_user;

  assign o_raw_loopback_en = (RAW_LOOPBACK != 0);

  nic_mac_cdc #(
      .FIFO_DEPTH(FIFO_DEPTH),
      .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
      .GMII_MODE(1'b1)
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
      .i_rx_wire_data          (xgmii_rx_data_q),
      .i_rx_wire_ctrl          (xgmii_rx_ctrl_q),
      .i_rx_wire_valid         (xgmii_rx_en_q),
      .i_rx_locked             (rx_signal_ok),
      .i_rx_high_ber           (1'b0),
      .i_rx_local_fault        (!rx_signal_ok),
      .i_rx_remote_fault       (1'b0),
      .i_rx_signal_ok          (rx_signal_ok),
      .i_tx_link_ready         (tx_link_ready),
      .i_rx_overflow           (rx_overflow),
      .i_rx_bad_frame          (rx_bad_frame),
      .i_rx_bad_fcs            (rx_bad_fcs),
      .i_rx_bad_block          (1'b0),
      .i_tx_drop               (tx_drop),
      .i_tx_bad_block          (1'b0),
      .i_gmii_preamble_drop    (gmii_preamble_drop),
      .i_gmii_rx_er_event      (gmii_rx_er_event),
      .i_gmii_er_preamble_event(gmii_er_preamble_event),
      .i_gmii_er_ext_event     (gmii_er_ext_event),
      .i_gmii_short_ifg_event  (gmii_short_ifg_event),
      .i_gmii_pre_accept_event (gmii_pre_accept_event),
      .i_pcs_event             (pcs_event)
  );
  assign o_rx_block_lock = o_link[nic_pkg::LinkBitRxLocked];

  // ---- GMII TX serializer -----------------------------------------------------------------
  logic [63:0] xgmii_tx_data;
  logic [ 7:0] xgmii_tx_ctrl;
  logic        eth_tx_ready;
  logic [ 2:0] gmii_tx_lane_q;
  logic        gmii_tx_clk_en;
  logic        tx_xgmii_en;
  logic [7:0] cur_tx_byte, gmii_txd_q;
  logic cur_tx_ctrl, gmii_tx_en_q, gmii_tx_er_q;

  assign gmii_tx_clk_en = i_gmii_rx_clk_en;
  assign tx_tick        = gmii_tx_clk_en;
  assign tx_xgmii_en    = gmii_tx_clk_en && (gmii_tx_lane_q == 3'd7);
  assign tx_link_ready  = rx_signal_ok;
  assign mac_tx_tready  = eth_tx_ready && tx_link_ready;

  eth10g_mac_tx #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_mac_tx (
      .i_clk        (i_tx_clk),
      .i_rst        (tx_rst),
      .i_enable     (tx_xgmii_en),
      .s_axis_tdata (mac_tx_tdata),
      .s_axis_tkeep (mac_tx_tkeep),
      .s_axis_tvalid(mac_tx_tvalid && tx_link_ready),
      .s_axis_tready(eth_tx_ready),
      .s_axis_tlast (mac_tx_tlast),
      .s_axis_tuser (mac_tx_tuser),
      .i_csum_en    (mac_tx_csum_en),
      .i_csum_start (mac_tx_csum_start),
      .i_csum_offset(mac_tx_csum_offset),
      .o_xgmii_data (xgmii_tx_data),
      .o_xgmii_ctrl (xgmii_tx_ctrl),
      .o_drop       (tx_drop)
  );

  assign cur_tx_byte = xgmii_tx_data[gmii_tx_lane_q*8+:8];
  assign cur_tx_ctrl = xgmii_tx_ctrl[gmii_tx_lane_q];

  always_ff @(posedge i_tx_clk) begin
    if (tx_rst) begin
      gmii_tx_lane_q <= 3'd0;
      gmii_txd_q     <= 8'h00;
      gmii_tx_en_q   <= 1'b0;
      gmii_tx_er_q   <= 1'b0;
    end else if (gmii_tx_clk_en) begin
      gmii_tx_lane_q <= gmii_tx_lane_q + 3'd1;
      if (!cur_tx_ctrl) begin
        gmii_txd_q   <= cur_tx_byte;
        gmii_tx_en_q <= 1'b1;
        gmii_tx_er_q <= 1'b0;
      end else if (cur_tx_byte == 8'hfb) begin
        // XGMII /S/ (0xFB) on lane 0 becomes the first 0x55 preamble byte in GMII.
        gmii_txd_q   <= 8'h55;
        gmii_tx_en_q <= 1'b1;
        gmii_tx_er_q <= 1'b0;
      end else begin
        // XGMII /T/ (0xFD) or /I/ (0x07) becomes GMII idle.
        gmii_txd_q   <= 8'h00;
        gmii_tx_en_q <= 1'b0;
        gmii_tx_er_q <= 1'b0;
      end
    end
  end

  assign o_gmii_txd       = gmii_txd_q;
  assign o_gmii_tx_en     = gmii_tx_en_q;
  assign o_gmii_tx_er     = gmii_tx_er_q;
  assign o_gmii_tx_clk_en = gmii_tx_clk_en;

  // ---- raw loopback -----------------------------------------------------------------------
  logic [ 7:0] gmii_rxd;
  logic        gmii_rx_dv;
  logic        gmii_rx_er;
  logic        gmii_rx_clk_en;
  logic [15:0] pcs_status;

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
    assign gmii_rxd       = loop_q ? gmii_txd_q : i_gmii_rxd;
    assign gmii_rx_dv     = loop_q ? gmii_tx_en_q : i_gmii_rx_dv;
    assign gmii_rx_er     = loop_q ? gmii_tx_er_q : i_gmii_rx_er;
    assign gmii_rx_clk_en = loop_q ? gmii_tx_clk_en : i_gmii_rx_clk_en;
    assign pcs_status     = loop_q ? 16'b0 : i_pcs_status;
    assign rx_signal_ok   = loop_q ? 1'b1 : i_rx_signal_ok;
  end else begin : gen_no_raw_loopback
    assign gmii_rxd       = i_gmii_rxd;
    assign gmii_rx_dv     = i_gmii_rx_dv;
    assign gmii_rx_er     = i_gmii_rx_er;
    assign gmii_rx_clk_en = i_gmii_rx_clk_en;
    assign pcs_status     = i_pcs_status;
    assign rx_signal_ok   = i_rx_signal_ok;
    /* verilator lint_off UNUSEDSIGNAL */
    logic mac_loopback_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign mac_loopback_unused = i_mac_loopback;
  end

  // ---- PCS status_vector monitor ----------------------------------------------------------
  // Bit 1 is link synchronisation, 2 RUDI(/C/), 4 RUDI(INVALID), 5 RXDISPERR,
  // 6 RXNOTINTABLE.
  /* verilator lint_off UNUSEDSIGNAL */
  wire        pcs_status_unused = |{pcs_status[15:7], pcs_status[3], pcs_status[0]};
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0] pcs_prev_q;
  logic       pcs_sync_prev_q;
  always_ff @(posedge i_rx_clk) begin
    if (rx_rst) begin
      pcs_prev_q <= '0;
      pcs_event  <= '0;
    end else begin
      pcs_prev_q <= {pcs_status[4], pcs_status[2]};
      pcs_event <= {
        pcs_status[6],
        pcs_status[5],
        pcs_status[4] && !pcs_prev_q[1],
        pcs_status[2] && !pcs_prev_q[0],
        pcs_sync_prev_q && !pcs_status[1]
      };
    end
  end
  always_ff @(posedge i_rx_clk) begin
    if (rx_rst) pcs_sync_prev_q <= 1'b0;
    else pcs_sync_prev_q <= pcs_status[1];
  end

  // ---- GMII RX deserializer ---------------------------------------------------------------
  typedef enum logic [1:0] {
    GMII_RX_IDLE,
    GMII_RX_PREAMBLE,
    GMII_RX_DATA,
    GMII_RX_WAIT_END
  } gmii_rx_state_e;

  gmii_rx_state_e gmii_rx_state_q;
  logic [2:0] gmii_rx_lane_q;
  logic [63:0] rx_accum_data_q;
  logic [7:0] rx_accum_ctrl_q;
  logic gmii_er_prev_q, gmii_er_pre_prev_q, gmii_er_ext_prev_q;
  logic       pre_er_seen_q;
  logic [3:0] ifg_cnt_q;
  logic ifg_valid_q, gmii_dv_prev_q;

  always_ff @(posedge i_rx_clk) begin
    if (rx_rst || !rx_signal_ok) begin
      gmii_rx_state_q        <= GMII_RX_IDLE;
      gmii_rx_lane_q         <= 3'd0;
      rx_accum_data_q        <= 64'h0707_0707_0707_0707;
      rx_accum_ctrl_q        <= 8'hff;
      xgmii_rx_data_q        <= 64'h0707_0707_0707_0707;
      xgmii_rx_ctrl_q        <= 8'hff;
      xgmii_rx_en_q          <= 1'b0;
      gmii_preamble_drop     <= 1'b0;
      gmii_rx_er_event       <= 1'b0;
      gmii_er_prev_q         <= 1'b0;
      gmii_er_pre_prev_q     <= 1'b0;
      gmii_er_ext_prev_q     <= 1'b0;
      gmii_er_preamble_event <= 1'b0;
      gmii_er_ext_event      <= 1'b0;
      gmii_short_ifg_event   <= 1'b0;
      gmii_pre_accept_event  <= 1'b0;
      pre_er_seen_q          <= 1'b0;
      ifg_cnt_q              <= '0;
      ifg_valid_q            <= 1'b0;
      gmii_dv_prev_q         <= 1'b0;
    end else begin
      xgmii_rx_en_q          <= 1'b0;
      gmii_preamble_drop     <= 1'b0;
      gmii_rx_er_event       <= 1'b0;
      gmii_er_preamble_event <= 1'b0;
      gmii_er_ext_event      <= 1'b0;
      gmii_short_ifg_event   <= 1'b0;
      gmii_pre_accept_event  <= 1'b0;
      if (gmii_rx_clk_en) begin
        gmii_er_prev_q <= gmii_rx_dv && gmii_rx_er && (gmii_rx_state_q == GMII_RX_DATA);
        gmii_rx_er_event <= gmii_rx_dv && gmii_rx_er && (gmii_rx_state_q == GMII_RX_DATA) &&
            !gmii_er_prev_q;
        gmii_er_pre_prev_q <= gmii_rx_dv && gmii_rx_er &&
            (gmii_rx_state_q == GMII_RX_IDLE || gmii_rx_state_q == GMII_RX_PREAMBLE ||
             gmii_rx_state_q == GMII_RX_WAIT_END);
        gmii_er_preamble_event <= gmii_rx_dv && gmii_rx_er &&
            (gmii_rx_state_q == GMII_RX_IDLE || gmii_rx_state_q == GMII_RX_PREAMBLE) &&
            !gmii_er_pre_prev_q;
        gmii_er_ext_prev_q <= !gmii_rx_dv && gmii_rx_er;
        gmii_er_ext_event <= !gmii_rx_dv && gmii_rx_er && !gmii_er_ext_prev_q;
        gmii_dv_prev_q <= gmii_rx_dv;
        if (gmii_rx_dv) begin
          ifg_cnt_q <= '0;
          if (!gmii_dv_prev_q && ifg_valid_q && ifg_cnt_q < 4'd12) gmii_short_ifg_event <= 1'b1;
          ifg_valid_q <= 1'b1;
        end else if (ifg_cnt_q != 4'd15) begin
          ifg_cnt_q <= ifg_cnt_q + 4'd1;
        end
        unique case (gmii_rx_state_q)
          GMII_RX_IDLE: begin
            if (gmii_rx_dv) begin
              pre_er_seen_q <= 1'b0;
              if (RX_PREAMBLE_ER_TOLERANT && gmii_rx_er && gmii_rxd == 8'h55) begin
                pre_er_seen_q   <= 1'b1;
                gmii_rx_state_q <= GMII_RX_PREAMBLE;
              end else if (!gmii_rx_er && (gmii_rxd == 8'hd5)) begin
                xgmii_rx_data_q <= 64'hd555_5555_5555_55fb;
                xgmii_rx_ctrl_q <= 8'h01;
                xgmii_rx_en_q   <= 1'b1;
                gmii_rx_lane_q  <= 3'd0;
                gmii_rx_state_q <= GMII_RX_DATA;
              end else if (!gmii_rx_er && (gmii_rxd == 8'h55)) begin
                gmii_rx_state_q <= GMII_RX_PREAMBLE;
              end else begin
                gmii_rx_state_q    <= GMII_RX_WAIT_END;
                gmii_preamble_drop <= 1'b1;
              end
            end
          end

          GMII_RX_PREAMBLE: begin
            if (!gmii_rx_dv) begin
              gmii_rx_state_q <= GMII_RX_IDLE;
            end else if (!gmii_rx_er && (gmii_rxd == 8'hd5)) begin
              xgmii_rx_data_q       <= 64'hd555_5555_5555_55fb;
              xgmii_rx_ctrl_q       <= 8'h01;
              xgmii_rx_en_q         <= 1'b1;
              gmii_rx_lane_q        <= 3'd0;
              gmii_rx_state_q       <= GMII_RX_DATA;
              gmii_pre_accept_event <= pre_er_seen_q;
            end else if (RX_PREAMBLE_ER_TOLERANT && gmii_rx_er && gmii_rxd == 8'h55 &&
                       !pre_er_seen_q) begin
              pre_er_seen_q <= 1'b1;
            end else if (gmii_rx_er || (gmii_rxd != 8'h55)) begin
              gmii_rx_state_q    <= GMII_RX_WAIT_END;
              gmii_preamble_drop <= 1'b1;
            end
          end

          GMII_RX_DATA: begin
            if (gmii_rx_dv) begin
              if (gmii_rx_lane_q == 3'd7) begin
                xgmii_rx_data_q <= {gmii_rx_er ? 8'hfe : gmii_rxd, rx_accum_data_q[55:0]};
                xgmii_rx_ctrl_q <= {gmii_rx_er, rx_accum_ctrl_q[6:0]};
                xgmii_rx_en_q   <= 1'b1;
                gmii_rx_lane_q  <= 3'd0;
              end else begin
                rx_accum_data_q[gmii_rx_lane_q*8+:8] <= gmii_rx_er ? 8'hfe : gmii_rxd;
                rx_accum_ctrl_q[gmii_rx_lane_q]      <= gmii_rx_er;
                gmii_rx_lane_q                       <= gmii_rx_lane_q + 3'd1;
              end
            end else begin
              // End of frame: insert /T/ (0xFD) at gmii_rx_lane_q and /I/ (0x07) after.
              for (int b = 0; b < 8; b++) begin
                if (b < int'(gmii_rx_lane_q)) begin
                  xgmii_rx_data_q[b*8+:8] <= rx_accum_data_q[b*8+:8];
                  xgmii_rx_ctrl_q[b]      <= rx_accum_ctrl_q[b];
                end else if (b == int'(gmii_rx_lane_q)) begin
                  xgmii_rx_data_q[b*8+:8] <= 8'hfd;
                  xgmii_rx_ctrl_q[b]      <= 1'b1;
                end else begin
                  xgmii_rx_data_q[b*8+:8] <= 8'h07;
                  xgmii_rx_ctrl_q[b]      <= 1'b1;
                end
              end
              xgmii_rx_en_q   <= 1'b1;
              gmii_rx_lane_q  <= 3'd0;
              gmii_rx_state_q <= GMII_RX_IDLE;
            end
          end

          GMII_RX_WAIT_END: begin
            if (!gmii_rx_dv) begin
              gmii_rx_state_q <= GMII_RX_IDLE;
            end
          end
        endcase
      end
    end
  end

  eth10g_mac_rx #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_mac_rx (
      .i_clk        (i_rx_clk),
      .i_rst        (rx_rst),
      .i_enable     (xgmii_rx_en_q),
      .i_xgmii_data (xgmii_rx_data_q),
      .i_xgmii_ctrl (xgmii_rx_ctrl_q),
      .m_axis_tdata (mac_rx_tdata),
      .m_axis_tkeep (mac_rx_tkeep),
      .m_axis_tvalid(mac_rx_tvalid),
      .m_axis_tready(mac_rx_tready),
      .m_axis_tlast (mac_rx_tlast),
      .m_axis_tuser (m_user),
      .o_bad_frame  (rx_bad_frame),
      .o_bad_fcs    (rx_bad_fcs),
      .o_overflow   (rx_overflow)
  );
  /* verilator lint_off UNUSEDSIGNAL */  // the RX MAC publishes complete frames only: tuser is 0
  logic m_user_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign m_user_unused = m_user;
endmodule : nic_mac_1g
