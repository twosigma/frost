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
 * MAC/PCS clock crossings, packet FIFOs, resets, and raw loopback.
 *
 * RX beats cross as 68-bit FIFO words {code, data}; TX adds the abort bit and 15-bit checksum
 * request for 84 bits (nic_pkg beat code: {last, bytes - 1}). Each domain's reset comes from nic_domain_reset
 * under the core-side controller's generation handshake; the FIFO half in
 * a domain resets with that domain, the core-side half with
 * i_core_rst_dom. The raw loopback (MAC_LOOPBACK: raw TX into raw RX with
 * no crossing logic, so only for one clock shared by both directions)
 * exists with RAW_LOOPBACK = 1; its select is sampled by the RX domain
 * while it is in reset, so a change takes effect through an RX-domain
 * reset. With RAW_LOOPBACK = 0 (independent TX and RX clocks, such as a
 * transceiver's) neither the mux nor its select synchronizer is built, raw
 * RX comes only from the PHY inputs and i_mac_loopback is ignored. Status
 * levels are two-flop synchronized; MAC event pulses become 64-bit totals
 * in the core domain through Gray-coded counters that rebase while the
 * domain is not ready.
 *
 * The RX FIFO is RX_FIFO_DEPTH words deep and reports full at a runtime
 * limit (i_rx_fifo_limit, 8..RX_FIFO_DEPTH words). A new limit crosses to the
 * RX clock through a request/acknowledge mailbox: it is applied as one value
 * and o_rx_fifo_limit_busy stays high until it has been, and a write is
 * issued (i_rx_fifo_limit_wr) only while the mailbox is idle. The mailbox
 * takes the RX FIFO's two resets, so a reset returns the limit to its
 * default on both sides together.
 */
module nic_mac_wrap #(
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int unsigned RX_FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    // 1 = the raw TX-to-RX loopback behind MAC_LOOPBACK (a shared MAC clock);
    // 0 = no loopback path (independent TX and RX clocks).
    parameter int unsigned RAW_LOOPBACK = 1,
    // 0 = 10GBASE-R 64b/66b PCS + gearbox; 1 = 8-bit GMII serializer/deserializer
    // for 10/100/1000BASE-T SGMII PCS/PMA cores.
    parameter bit GMII_MODE = 1'b0
) (
    // Core domain.
    input logic i_clk,
    input logic i_rst,
    input logic i_soft_rst,
    input logic [1:0] i_req,  // reset handshake (0 = TX, 1 = RX)
    input logic [1:0] i_gen,
    output logic [1:0] o_in_reset,  // raw domain levels for the controller
    output logic [1:0] o_applied_gen,
    output logic [1:0] o_applied_valid,
    input logic [1:0] i_core_rst_dom,
    input logic i_mac_loopback,
    // Station address (quasi-static) and the 802.3x configuration, which crosses with the FIFO
    // limit in one mailbox: {interval, low_water, high_water, tx_en, rx_en}.
    input logic [47:0] i_station_mac,
    input logic [1:0] i_pause_ctrl,
    input logic [$clog2(RX_FIFO_DEPTH):0] i_pause_high_water,
    input logic [$clog2(RX_FIFO_DEPTH):0] i_pause_low_water,
    input logic [15:0] i_pause_interval,

    input  logic                           i_tx_valid,
    output logic                           o_tx_ready,
    input  logic [                   63:0] i_tx_data,
    input  logic [                    3:0] i_tx_code,
    // The frame's checksum request {offset/2, start/2, enable}, with every beat.
    input  logic [                   14:0] i_tx_csum,
    // Set on a frame's last beat to drop the frame at the MAC (an abandoned frame).
    input  logic                           i_tx_abort,
    output logic                           o_rx_valid,
    input  logic                           i_rx_ready,
    output logic [                   63:0] o_rx_data,
    output logic [                    3:0] o_rx_code,
    // The RX FIFO's occupancy limit in words; a write pulse starts its crossing.
    input  logic [$clog2(RX_FIFO_DEPTH):0] i_rx_fifo_limit,
    input  logic                           i_rx_fifo_limit_wr,
    output logic                           o_rx_fifo_limit_busy,

    output logic o_rx_locked,
    output logic o_rx_high_ber,
    output logic o_rx_local_fault,
    output logic o_rx_remote_fault,
    output logic o_tx_link_ready,
    output logic o_rx_signal_ok,
    // Totals in counter order: rx_overflow, rx_bad_frame, rx_bad_fcs,
    // rx_bad_block, tx_drop, tx_bad_block, gmii_preamble_drop, gmii_rx_er,
    // rx_pause, tx_pause, tx_paused_cycles.
    output logic [10:0][63:0] o_totals,

    // MAC domains.
    input  logic        i_tx_clk,
    input  logic        i_rx_clk,
    output logic [63:0] o_tx_raw_data,
    output logic        o_tx_raw_valid,
    input  logic [63:0] i_rx_raw_data,
    input  logic        i_rx_raw_valid,
    input  logic        i_rx_signal_ok
);
  logic tx_rst, rx_rst;

  // Separate registered resets launch asynchronous assertion into each MAC domain.
  logic rst_for_tx_q, rst_for_rx_q;
  always_ff @(posedge i_clk) begin
    rst_for_tx_q <= i_rst;
    rst_for_rx_q <= i_rst;
  end

  nic_domain_reset u_tx_reset (
      .i_clk           (i_tx_clk),
      .i_core_rst_async(rst_for_tx_q),
      .i_req_async     (i_req[0]),
      .i_gen_async     (i_gen[0]),
      .o_domain_rst    (tx_rst),
      .o_in_reset      (o_in_reset[0]),
      .o_applied_gen   (o_applied_gen[0]),
      .o_applied_valid (o_applied_valid[0])
  );
  nic_domain_reset u_rx_reset (
      .i_clk           (i_rx_clk),
      .i_core_rst_async(rst_for_rx_q),
      .i_req_async     (i_req[1]),
      .i_gen_async     (i_gen[1]),
      .o_domain_rst    (rx_rst),
      .o_in_reset      (o_in_reset[1]),
      .o_applied_gen   (o_applied_gen[1]),
      .o_applied_valid (o_applied_valid[1])
  );

  // ---- TX: core beats to the MAC ------------------------------------------------------
  // t_word = {abort[83], checksum request[82:68], code[67:64], data[63:0]}
  logic [83:0] t_word, f_word;
  logic t_valid, t_ready, f_valid, f_ready;
  async_fifo #(
      .DATA_WIDTH(84),
      .DEPTH(FIFO_DEPTH)
  ) u_tx_fifo (
      .i_limit('0),
      .o_occupancy(),
      .i_clk(i_clk),
      // A soft reset of this domain clears the FIFO at run time.
      .i_rst(i_rst || i_core_rst_dom[0]),
      .i_data({i_tx_abort, i_tx_csum, i_tx_code, i_tx_data}),
      .i_valid(i_tx_valid),
      .o_ready(o_tx_ready),
      .o_clk(i_tx_clk),
      .o_rst(tx_rst),
      .o_data(f_word),
      .o_valid(f_valid),
      .i_ready(f_ready)
  );
  logic [7:0] t_keep;
  assign t_keep = 8'hFF >> (3'd7 - t_word[66:64]);

  // ---- RX: MAC beats to the core ------------------------------------------------------
  logic [63:0] m_data;
  logic [ 7:0] m_keep;
  logic m_valid, m_ready, m_last;
  logic [2:0] m_bytes_m1;
  always_comb begin
    m_bytes_m1 = '0;
    for (int i = 0; i < 8; i++) if (m_keep[i]) m_bytes_m1 = 3'(i);
  end
  logic [67:0] r_word;
  localparam int unsigned LimitBits = $clog2(RX_FIFO_DEPTH) + 1;
  localparam logic [LimitBits-1:0] LimitDefault =
      LimitBits'((nic_pkg::RxFifoLimitDefault < RX_FIFO_DEPTH) ?
      nic_pkg::RxFifoLimitDefault : RX_FIFO_DEPTH);
  // The configuration word: {interval[15:0], low_water, high_water, tx_en, rx_en, limit}.
  localparam int unsigned CfgBits = 16 + 3 * LimitBits + 2;
  localparam logic [CfgBits-1:0] CfgDefault = {
    nic_pkg::PauseIntervalDefault, {2 * LimitBits{1'b0}}, 2'b00, LimitDefault
  };
  logic [CfgBits-1:0] rx_cfg_msg, rx_cfg_q;
  logic rx_limit_msg_valid, rx_limit_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic rx_limit_idle;
  /* verilator lint_on UNUSEDSIGNAL */
  cdc_mailbox #(
      .WIDTH(CfgBits)
  ) u_rx_limit (
      .i_src_clk(i_clk),
      // Match the RX FIFO's core half: this receiver must clear for either reset source.
      .i_src_rst(i_rst || i_core_rst_dom[1]),
      .i_src_data({
        i_pause_interval, i_pause_low_water, i_pause_high_water, i_pause_ctrl, i_rx_fifo_limit
      }),
      .i_src_valid(i_rx_fifo_limit_wr),
      .o_src_ready(rx_limit_ready),
      .o_src_idle(rx_limit_idle),
      .i_dst_clk(i_rx_clk),
      .i_dst_rst(rx_rst),
      .o_dst_data(rx_cfg_msg),
      .o_dst_valid(rx_limit_msg_valid),
      .i_dst_ready(1'b1)
  );
  assign o_rx_fifo_limit_busy = !rx_limit_ready;
  always_ff @(posedge i_rx_clk) begin
    if (rx_rst) rx_cfg_q <= CfgDefault;
    else if (rx_limit_msg_valid) rx_cfg_q <= rx_cfg_msg;
  end
  logic [LimitBits-1:0] rx_limit_q, cfg_high_water, cfg_low_water;
  logic [ 1:0] cfg_ctrl;
  logic [15:0] cfg_interval;
  assign {cfg_interval, cfg_low_water, cfg_high_water, cfg_ctrl, rx_limit_q} = rx_cfg_q;

  // Effective thresholds: 0 selects three quarters / one quarter of the limit; high-water stays below
  // the limit (the FIFO stops accepting at limit - 2) and low-water below high-water.
  logic [LimitBits-1:0]
      high_water_eff_q, low_water_eff_q, high_water_cap, high_water_next, low_water_next;
  assign high_water_cap = rx_limit_q - LimitBits'(4);
  always_comb begin
    high_water_next = (cfg_high_water == '0) ? rx_limit_q - (rx_limit_q >> 2) : cfg_high_water;
    if (high_water_next > high_water_cap) high_water_next = high_water_cap;
    low_water_next = (cfg_low_water == '0) ? (rx_limit_q >> 2) : cfg_low_water;
    if (low_water_next >= high_water_next) low_water_next = high_water_next >> 1;
  end
  always_ff @(posedge i_rx_clk) begin
    high_water_eff_q <= high_water_next;
    low_water_eff_q  <= low_water_next;
  end

  // Station address into the two MAC domains.
  logic [47:0] mac_rx_s, mac_tx_s;
  cdc_sync #(
      .WIDTH(48)
  ) u_mac_rx_sync (
      .i_clk  (i_rx_clk),
      .i_rst  (1'b0),
      .i_async(i_station_mac),
      .o_sync (mac_rx_s)
  );
  cdc_sync #(
      .WIDTH(48)
  ) u_mac_tx_sync (
      .i_clk  (i_tx_clk),
      .i_rst  (1'b0),
      .i_async(i_station_mac),
      .o_sync (mac_tx_s)
  );

  logic [$clog2(RX_FIFO_DEPTH):0] rx_occupancy;
  logic pf_valid, pf_ready, pause_rx_ev, pause_rx_tog, want_pause;
  logic [67:0] pf_word;
  logic [15:0] pause_rx_interval;
  nic_pause_rx #(
      .OCC_BITS(LimitBits)
  ) u_pause_rx (
      .i_clk           (i_rx_clk),
      .i_rst           (rx_rst),
      .i_mac           (mac_rx_s),
      .i_m_data        (m_data),
      .i_m_code        ({m_last, m_bytes_m1}),
      .i_m_valid       (m_valid),
      .o_m_ready       (m_ready),
      .o_f_valid       (pf_valid),
      .o_f_word        (pf_word),
      .i_f_ready       (pf_ready),
      .i_occupancy     (rx_occupancy),
      .i_high_water    (high_water_eff_q),
      .i_low_water     (low_water_eff_q),
      .i_tx_en         (cfg_ctrl[nic_pkg::PauseCtrlBitTx]),
      .o_want_pause    (want_pause),
      .o_pause_ev      (pause_rx_ev),
      .o_pause_tog     (pause_rx_tog),
      .o_pause_interval(pause_rx_interval)
  );
  async_fifo #(
      .DATA_WIDTH(68),
      .DEPTH(RX_FIFO_DEPTH),
      .DYNAMIC_LIMIT(1'b1)
  ) u_rx_fifo (
      .i_limit(rx_limit_q),
      .o_occupancy(rx_occupancy),
      .i_clk(i_rx_clk),
      .i_rst(rx_rst),
      .i_data(pf_word),
      .i_valid(pf_valid),
      .o_ready(pf_ready),
      .o_clk(i_clk),
      // A soft reset of this domain clears the FIFO at run time.
      .o_rst(i_rst || i_core_rst_dom[1]),
      .o_data(r_word),
      .o_valid(o_rx_valid),
      .i_ready(i_rx_ready)
  );
  assign o_rx_data = r_word[63:0];
  assign o_rx_code = r_word[67:64];

  // ---- the raw loopback -------------------------------------------------------------------
  logic [63:0] rx_raw_data;
  logic rx_raw_valid, rx_signal_ok;
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
    // No TX-to-RX path: the PHY inputs alone feed the RX PCS, and PHY_CTRL's
    // MAC_LOOPBACK bit is stored by the register block but selects nothing.
    assign rx_raw_data  = i_rx_raw_data;
    assign rx_raw_valid = i_rx_raw_valid;
    assign rx_signal_ok = i_rx_signal_ok;
    /* verilator lint_off UNUSEDSIGNAL */
    logic mac_loopback_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign mac_loopback_unused = i_mac_loopback;
  end

  // ---- the MAC/PCS ------------------------------------------------------------------------
  logic rx_locked, rx_high_ber, rx_local_fault, rx_remote_fault, tx_link_ready;
  logic tx_drop, rx_bad_frame, rx_bad_fcs, rx_overflow, tx_bad_block, rx_bad_block;
  logic m_user;
  logic tx_tick;
  // GMII receive events (the 10GBASE-R PCS has none): a frame dropped in the preamble stage, and
  // the first rx_er of a burst inside a frame.
  logic gmii_preamble_drop, gmii_rx_er_event;
  if (!GMII_MODE) begin : gen_10g_pcs
    assign gmii_preamble_drop = 1'b0;
    assign gmii_rx_er_event   = 1'b0;
    eth10g_mac_pcs #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
    ) u_mac (
        .i_tx_clk         (i_tx_clk),
        .i_tx_rst         (tx_rst),
        .i_rx_clk         (i_rx_clk),
        .i_rx_rst         (rx_rst),
        .s_axis_tdata     (t_word[63:0]),
        .s_axis_tkeep     (t_keep),
        .s_axis_tvalid    (t_valid),
        .s_axis_tready    (t_ready),
        .s_axis_tlast     (t_word[67]),
        .s_axis_tuser     (t_word[83]),
        .i_csum_en        (t_word[68]),
        .i_csum_start     ({t_word[75:69], 1'b0}),
        .i_csum_offset    ({t_word[82:76], 1'b0}),
        .m_axis_tdata     (m_data),
        .m_axis_tkeep     (m_keep),
        .m_axis_tvalid    (m_valid),
        .m_axis_tready    (m_ready),
        .m_axis_tlast     (m_last),
        .m_axis_tuser     (m_user),
        .o_tx_raw_data    (o_tx_raw_data),
        .o_tx_raw_valid   (o_tx_raw_valid),
        .o_tx_link_ready  (tx_link_ready),
        .o_tx_word_tick   (tx_tick),
        .i_rx_raw_data    (rx_raw_data),
        .i_rx_raw_valid   (rx_raw_valid),
        .i_rx_signal_ok   (rx_signal_ok),
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
  end else begin : gen_1g_gmii
    // 1G GMII adapter around eth10g_mac_tx and eth10g_mac_rx.
    // o_tx_raw_data[9:0] = {gmii_tx_er, gmii_tx_en, gmii_txd[7:0]}, o_tx_raw_valid = sgmii_clk_en
    // rx_raw_data[9:0]   = {gmii_rx_er, gmii_rx_dv, gmii_rxd[7:0]}, rx_raw_valid   = sgmii_clk_en
    logic [63:0] xgmii_tx_data;
    logic [ 7:0] xgmii_tx_ctrl;
    logic        mac_tx_ready;
    logic [ 2:0] gmii_tx_lane_q;
    logic        gmii_tx_clk_en;
    logic        tx_xgmii_en;
    logic [7:0] cur_tx_byte, gmii_txd_q;
    logic cur_tx_ctrl, gmii_tx_en_q, gmii_tx_er_q;

    assign gmii_tx_clk_en = i_rx_raw_valid;
    assign tx_tick        = gmii_tx_clk_en;
    assign tx_xgmii_en    = gmii_tx_clk_en && (gmii_tx_lane_q == 3'd7);
    assign tx_link_ready  = rx_signal_ok;
    assign t_ready        = mac_tx_ready && tx_link_ready;

    eth10g_mac_tx #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
    ) u_mac_tx (
        .i_clk        (i_tx_clk),
        .i_rst        (tx_rst),
        .i_enable     (tx_xgmii_en),
        .s_axis_tdata (t_word[63:0]),
        .s_axis_tkeep (t_keep),
        .s_axis_tvalid(t_valid && tx_link_ready),
        .s_axis_tready(mac_tx_ready),
        .s_axis_tlast (t_word[67]),
        .s_axis_tuser (t_word[83]),
        .i_csum_en    (t_word[68]),
        .i_csum_start ({t_word[75:69], 1'b0}),
        .i_csum_offset({t_word[82:76], 1'b0}),
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
          // XGMII /S/ (0xFB) on lane 0 becomes the first 0x55 preamble byte in GMII
          gmii_txd_q   <= 8'h55;
          gmii_tx_en_q <= 1'b1;
          gmii_tx_er_q <= 1'b0;
        end else begin
          // XGMII /T/ (0xFD) or /I/ (0x07) becomes GMII idle
          gmii_txd_q   <= 8'h00;
          gmii_tx_en_q <= 1'b0;
          gmii_tx_er_q <= 1'b0;
        end
      end
    end

    assign o_tx_raw_data  = {54'b0, gmii_tx_er_q, gmii_tx_en_q, gmii_txd_q};
    assign o_tx_raw_valid = gmii_tx_clk_en;

    // GMII to XGMII RX deserializer
    typedef enum logic [1:0] {
      GMII_RX_IDLE,
      GMII_RX_PREAMBLE,
      GMII_RX_DATA,
      GMII_RX_WAIT_END
    } gmii_rx_state_e;

    gmii_rx_state_e gmii_rx_state_q;
    logic [2:0] gmii_rx_lane_q;
    logic [63:0] rx_accum_data_q, xgmii_rx_data_q;
    logic [7:0] rx_accum_ctrl_q, xgmii_rx_ctrl_q;
    logic       xgmii_rx_en_q;
    logic       gmii_er_prev_q;

    wire  [7:0] gmii_rxd = rx_raw_data[7:0];
    wire        gmii_rx_dv = rx_raw_data[8];
    wire        gmii_rx_er = rx_raw_data[9];
    wire        gmii_rx_clk_en = rx_raw_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        rx_raw_unused = |rx_raw_data[63:10];
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge i_rx_clk) begin
      if (rx_rst || !rx_signal_ok) begin
        gmii_rx_state_q <= GMII_RX_IDLE;
        gmii_rx_lane_q <= 3'd0;
        rx_accum_data_q <= 64'h0707_0707_0707_0707;
        rx_accum_ctrl_q <= 8'hff;
        xgmii_rx_data_q <= 64'h0707_0707_0707_0707;
        xgmii_rx_ctrl_q <= 8'hff;
        xgmii_rx_en_q <= 1'b0;
        gmii_preamble_drop <= 1'b0;
        gmii_rx_er_event <= 1'b0;
        gmii_er_prev_q <= 1'b0;
      end else begin
        xgmii_rx_en_q <= 1'b0;
        gmii_preamble_drop <= 1'b0;
        gmii_rx_er_event <= 1'b0;
        if (gmii_rx_clk_en) begin
          // One event per rx_er burst inside the frame's data enable
          gmii_er_prev_q   <= gmii_rx_dv && gmii_rx_er;
          gmii_rx_er_event <= gmii_rx_dv && gmii_rx_er && !gmii_er_prev_q;
          unique case (gmii_rx_state_q)
            GMII_RX_IDLE: begin
              if (gmii_rx_dv) begin
                if (!gmii_rx_er && (gmii_rxd == 8'hd5)) begin
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
                xgmii_rx_data_q <= 64'hd555_5555_5555_55fb;
                xgmii_rx_ctrl_q <= 8'h01;
                xgmii_rx_en_q   <= 1'b1;
                gmii_rx_lane_q  <= 3'd0;
                gmii_rx_state_q <= GMII_RX_DATA;
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
                // End of frame: insert /T/ (0xFD) at gmii_rx_lane_q and /I/ (0x07) after
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
        .m_axis_tdata (m_data),
        .m_axis_tkeep (m_keep),
        .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready),
        .m_axis_tlast (m_last),
        .m_axis_tuser (m_user),
        .o_bad_frame  (rx_bad_frame),
        .o_bad_fcs    (rx_bad_fcs),
        .o_overflow   (rx_overflow)
    );

    assign rx_locked       = rx_signal_ok;
    assign rx_high_ber     = 1'b0;
    assign rx_local_fault  = !rx_signal_ok;
    assign rx_remote_fault = 1'b0;
    assign tx_bad_block    = 1'b0;
    assign rx_bad_block    = 1'b0;
  end
  /* verilator lint_off UNUSEDSIGNAL */  // the RX MAC publishes complete frames only: tuser is 0
  logic m_user_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign m_user_unused = m_user;

  // ---- 802.3x transmit side -------------------------------------------------------------------
  logic tx_en_s, rx_en_s, want_pause_s, pause_tog_s;
  logic [15:0] interval_cfg_s, pause_interval_s;
  logic tx_paused, tx_pause_ev;
  cdc_sync #(
      .WIDTH(3)
  ) u_pause_lvl_sync (
      .i_clk  (i_tx_clk),
      .i_rst  (1'b0),
      .i_async({want_pause, cfg_ctrl}),
      .o_sync ({want_pause_s, tx_en_s, rx_en_s})
  );
  cdc_sync #(
      .WIDTH(33)
  ) u_pause_bus_sync (
      .i_clk  (i_tx_clk),
      .i_rst  (1'b0),
      .i_async({pause_rx_tog, pause_rx_interval, cfg_interval}),
      .o_sync ({pause_tog_s, pause_interval_s, interval_cfg_s})
  );
  nic_pause_tx #(
      .GMII_MODE(GMII_MODE)
  ) u_pause_tx (
      .i_clk           (i_tx_clk),
      .i_rst           (tx_rst),
      .i_tick          (tx_tick),
      .i_mac           (mac_tx_s),
      .i_rx_en         (rx_en_s),
      .i_tx_en         (tx_en_s),
      .i_interval_cfg  (interval_cfg_s),
      .i_want_pause    (want_pause_s),
      .i_pause_tog     (pause_tog_s),
      .i_pause_interval(pause_interval_s),
      .i_f_word        (f_word),
      .i_f_valid       (f_valid),
      .o_f_ready       (f_ready),
      .o_t_word        (t_word),
      .o_t_valid       (t_valid),
      .i_t_ready       (t_ready),
      .o_paused        (tx_paused),
      .o_tx_pause_ev   (tx_pause_ev)
  );

  // ---- status levels into the core domain ------------------------------------------------
  // Each level is registered in its own domain first (the MAC computes some
  // of them combinationally), so the synchronizers see flop outputs only.
  logic [4:0] rx_status_q;
  logic tx_link_ready_q;
  always_ff @(posedge i_rx_clk) begin
    rx_status_q <= {rx_signal_ok, rx_remote_fault, rx_local_fault, rx_high_ber, rx_locked};
  end
  always_ff @(posedge i_tx_clk) begin
    tx_link_ready_q <= tx_link_ready;
  end
  cdc_sync #(
      .WIDTH(5)
  ) u_rx_status_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(rx_status_q),
      .o_sync ({o_rx_signal_ok, o_rx_remote_fault, o_rx_local_fault, o_rx_high_ber, o_rx_locked})
  );
  cdc_sync u_tx_status_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(tx_link_ready_q),
      .o_sync (o_tx_link_ready)
  );

  // ---- event totals -----------------------------------------------------------------------
  logic [10:0] ev_pulse;
  logic [10:0] ev_clk, ev_rst, ev_rebase;
  assign ev_pulse = {
    tx_paused,
    tx_pause_ev,
    pause_rx_ev,
    gmii_rx_er_event,
    gmii_preamble_drop,
    tx_bad_block,
    tx_drop,
    rx_bad_block,
    rx_bad_fcs,
    rx_bad_frame,
    rx_overflow
  };
  assign ev_clk = {
    i_tx_clk,
    i_tx_clk,
    i_rx_clk,
    i_rx_clk,
    i_rx_clk,
    i_tx_clk,
    i_tx_clk,
    i_rx_clk,
    i_rx_clk,
    i_rx_clk,
    i_rx_clk
  };
  // Each counter takes its event's domain reset, and a soft reset rebases or
  // clears the totals at run time.
  assign ev_rst = {
    tx_rst, tx_rst, rx_rst, rx_rst, rx_rst, tx_rst, tx_rst, rx_rst, rx_rst, rx_rst, rx_rst
  };
  assign ev_rebase = {
    i_core_rst_dom[0],
    i_core_rst_dom[0],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[0],
    i_core_rst_dom[0],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[1]
  };
  for (genvar e = 0; e < 11; e++) begin : g_events
    cdc_gray_count u_count (
        .i_src_clk   (ev_clk[e]),
        .i_src_rst   (ev_rst[e]),
        .i_src_event (ev_pulse[e]),
        .i_dst_clk   (i_clk),
        // A soft reset clears the totals at run time.
        .i_dst_rst   (i_rst || i_soft_rst),
        .i_dst_rebase(ev_rebase[e]),
        .o_dst_total (o_totals[e])
    );
  end
endmodule : nic_mac_wrap
