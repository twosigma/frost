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
 * nic_mac_cdc: shared core-to-MAC clock-domain crossing shell for pluggable
 * NIC MAC blocks (nic_mac_10g and nic_mac_1g).
 *
 * Faces nic_engine in the core clock domain (i_clk) with 64-bit AXI4-Stream TX
 * and RX ports plus reset, flow-control, link-status, and counter-total
 * sideband signals. Faces the concrete MAC/PCS in i_tx_clk and i_rx_clk with
 * MAC-domain 64-bit AXI4-Stream, synchronized resets, XGMII pause snooping,
 * status capture, and event-pulse counters.
 *
 * RX and TX beats cross as 68-bit FIFO words {code, data}, keeping the beat
 * code {last, bytes - 1} compact inside the async FIFOs while converting
 * combinationally to and from 8-bit AXI4-Stream TKEEP at the core boundary.
 * TX checksum requests cross once per frame in a 15-bit side FIFO, and a
 * reserved beat code (TxAbortCode) marks a closing abort beat (TUSER = 1).
 */
module nic_mac_cdc #(
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int unsigned RX_FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216,
    // 0 = 10GBASE-R pause quanta (8 words per quantum); 1 = GMII (64 byte times).
    parameter bit GMII_MODE = 1'b0,
    localparam int unsigned LimitBits = $clog2(RX_FIFO_DEPTH) + 1
) (
    // Core clock domain (nic_engine boundary).
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_soft_rst,
    input  logic                                i_restart,
    output logic [                         1:0] o_ready,
    output logic [                         7:0] o_link,
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

    // MAC clock domains (i_tx_clk, i_rx_clk).
    input  logic i_tx_clk,
    input  logic i_rx_clk,
    input  logic i_tx_clk_ok,
    input  logic i_rx_clk_ok,
    output logic o_tx_rst,
    output logic o_rx_rst,

    // MAC-domain TX AXI4-Stream master (toward MAC transmitter).
    output logic        o_mac_tx_tvalid,
    input  logic        i_mac_tx_tready,
    output logic [63:0] o_mac_tx_tdata,
    output logic [ 7:0] o_mac_tx_tkeep,
    output logic        o_mac_tx_tlast,
    output logic        o_mac_tx_tuser,
    output logic        o_mac_tx_csum_en,
    output logic [ 7:0] o_mac_tx_csum_start,
    output logic [ 7:0] o_mac_tx_csum_offset,
    input  logic        i_tx_tick,

    // MAC-domain RX AXI4-Stream slave (from MAC receiver) and wire snooper.
    input  logic        i_mac_rx_tvalid,
    output logic        o_mac_rx_tready,
    input  logic [63:0] i_mac_rx_tdata,
    input  logic [ 7:0] i_mac_rx_tkeep,
    input  logic        i_mac_rx_tlast,
    input  logic [63:0] i_rx_wire_data,
    input  logic [ 7:0] i_rx_wire_ctrl,
    input  logic        i_rx_wire_valid,

    // MAC-domain link status levels.
    input logic i_rx_locked,
    input logic i_rx_high_ber,
    input logic i_rx_local_fault,
    input logic i_rx_remote_fault,
    input logic i_rx_signal_ok,
    input logic i_tx_link_ready,

    // MAC-domain event pulses.
    input logic       i_rx_overflow,
    input logic       i_rx_bad_frame,
    input logic       i_rx_bad_fcs,
    input logic       i_rx_bad_block,
    input logic       i_tx_drop,
    input logic       i_tx_bad_block,
    input logic       i_gmii_preamble_drop,
    input logic       i_gmii_rx_er_event,
    input logic       i_gmii_er_preamble_event,
    input logic       i_gmii_er_ext_event,
    input logic       i_gmii_short_ifg_event,
    input logic       i_gmii_pre_accept_event,
    input logic [4:0] i_pcs_event
);
  // ---- MAC-domain reset handshake ---------------------------------------------------------
  logic [1:0] clk_ok, in_reset, applied_gen, applied_valid;
  logic [1:0] req, gen, core_rst_dom;
  logic tx_rst, rx_rst;

  cdc_sync #(
      .WIDTH(2)
  ) u_clk_ok_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async({i_rx_clk_ok, i_tx_clk_ok}),
      .o_sync (clk_ok)
  );

  nic_mac_reset_ctrl u_mac_reset (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_restart      (i_restart),
      .i_clk_ok       (clk_ok),
      .i_in_reset     (in_reset),
      .i_applied_gen  (applied_gen),
      .i_applied_valid(applied_valid),
      .o_req          (req),
      .o_gen          (gen),
      .o_core_rst_dom (core_rst_dom),
      .o_ready        (o_ready)
  );

  // Separate registered resets launch asynchronous assertion into each MAC domain.
  logic rst_for_tx_q, rst_for_rx_q;
  always_ff @(posedge i_clk) begin
    rst_for_tx_q <= i_rst;
    rst_for_rx_q <= i_rst;
  end

  nic_domain_reset u_tx_reset (
      .i_clk           (i_tx_clk),
      .i_core_rst_async(rst_for_tx_q),
      .i_req_async     (req[0]),
      .i_gen_async     (gen[0]),
      .o_domain_rst    (tx_rst),
      .o_in_reset      (in_reset[0]),
      .o_applied_gen   (applied_gen[0]),
      .o_applied_valid (applied_valid[0])
  );
  nic_domain_reset u_rx_reset (
      .i_clk           (i_rx_clk),
      .i_core_rst_async(rst_for_rx_q),
      .i_req_async     (req[1]),
      .i_gen_async     (gen[1]),
      .o_domain_rst    (rx_rst),
      .o_in_reset      (in_reset[1]),
      .o_applied_gen   (applied_gen[1]),
      .o_applied_valid (applied_valid[1])
  );
  assign o_tx_rst = tx_rst;
  assign o_rx_rst = rx_rst;

  // ---- TX: core AXI4-Stream beats to the MAC ----------------------------------------------
  // t_word = {abort[83], checksum request[82:68], code[67:64], data[63:0]}
  localparam logic [3:0] TxAbortCode = 4'b0000;
  localparam int unsigned TxCsumDepth = 32;
  logic [83:0] t_word, f_word;
  logic t_valid, t_ready, f_valid, f_ready;
  // The write half of both TX FIFOs clears for either reset source, as the RX FIFO's core
  // half does, so one term feeds the data and side FIFOs.
  logic tx_wr_rst;
  assign tx_wr_rst = i_rst || core_rst_dom[0];

  logic [3:0] tx_code;
  assign tx_code = nic_pkg::tkeep_to_beat_code(s_axis_tx_tlast, s_axis_tx_tkeep);

  // Write side: the side entry is pushed with the first beat; both FIFOs must have room for it.
  logic tx_wr_first_q, tx_data_ready, tx_csum_ready, tx_beat_ok, tx_beat_fire;
  assign tx_beat_ok       = !tx_wr_first_q || tx_csum_ready;
  assign s_axis_tx_tready = tx_data_ready && tx_beat_ok;
  assign tx_beat_fire     = s_axis_tx_tvalid && s_axis_tx_tready;
  always_ff @(posedge i_clk) begin
    if (tx_wr_rst) tx_wr_first_q <= 1'b1;
    else if (tx_beat_fire) tx_wr_first_q <= s_axis_tx_tlast || s_axis_tx_tuser;
  end

  logic [67:0] f_beat;
  logic [14:0] f_csum;
  logic f_beat_valid, f_beat_ready, f_csum_valid, f_csum_pop;
  async_fifo #(
      .DATA_WIDTH(68),
      .DEPTH(FIFO_DEPTH)
  ) u_tx_fifo (
      .i_limit('0),
      .o_occupancy(),
      .i_clk(i_clk),
      // A soft reset of this domain clears the FIFO at run time.
      .i_rst(tx_wr_rst),
      .i_data({s_axis_tx_tuser ? TxAbortCode : tx_code, s_axis_tx_tdata}),
      .i_valid(s_axis_tx_tvalid && tx_beat_ok),
      .o_ready(tx_data_ready),
      .o_clk(i_tx_clk),
      .o_rst(tx_rst),
      .o_data(f_beat),
      .o_valid(f_beat_valid),
      .i_ready(f_beat_ready)
  );
  async_fifo #(
      .DATA_WIDTH(15),
      .DEPTH(TxCsumDepth)
  ) u_tx_csum_fifo (
      .i_limit('0),
      .o_occupancy(),
      .i_clk(i_clk),
      .i_rst(tx_wr_rst),
      .i_data(i_tx_csum),
      .i_valid(s_axis_tx_tvalid && tx_wr_first_q && tx_data_ready),
      .o_ready(tx_csum_ready),
      .o_clk(i_tx_clk),
      .o_rst(tx_rst),
      .o_data(f_csum),
      .o_valid(f_csum_valid),
      .i_ready(f_csum_pop)
  );

  // Read side: a frame's first beat waits for its side entry, which pops with that beat.
  logic tx_rd_first_q, f_abort;
  logic [3:0] f_code;
  assign f_abort      = (f_beat[67:64] == TxAbortCode);
  assign f_code       = f_abort ? 4'b1000 : f_beat[67:64];
  assign f_valid      = f_beat_valid && (!tx_rd_first_q || f_csum_valid);
  assign f_beat_ready = f_ready && (!tx_rd_first_q || f_csum_valid);
  assign f_csum_pop   = f_valid && f_ready && tx_rd_first_q;
  assign f_word       = {f_abort, f_csum, f_code, f_beat[63:0]};
  always_ff @(posedge i_tx_clk) begin
    if (tx_rst) tx_rd_first_q <= 1'b1;
    else if (f_valid && f_ready) tx_rd_first_q <= f_code[3];
  end

  assign o_mac_tx_tvalid      = t_valid;
  assign t_ready              = i_mac_tx_tready;
  assign o_mac_tx_tdata       = t_word[63:0];
  assign o_mac_tx_tkeep       = 8'hFF >> (3'd7 - t_word[66:64]);
  assign o_mac_tx_tlast       = t_word[67];
  assign o_mac_tx_tuser       = t_word[83];
  assign o_mac_tx_csum_en     = t_word[68];
  assign o_mac_tx_csum_start  = {t_word[75:69], 1'b0};
  assign o_mac_tx_csum_offset = {t_word[82:76], 1'b0};

  // ---- RX: MAC AXI4-Stream beats to the core ----------------------------------------------
  logic [2:0] m_bytes_m1;
  always_comb begin
    m_bytes_m1 = '0;
    for (int i = 0; i < 8; i++) if (i_mac_rx_tkeep[i]) m_bytes_m1 = 3'(i);
  end
  logic [67:0] r_word;
  localparam logic [LimitBits-1:0] LimitDefault =
      LimitBits'((nic_pkg::RxFifoLimitDefault < RX_FIFO_DEPTH) ?
      nic_pkg::RxFifoLimitDefault : RX_FIFO_DEPTH);
  // The configuration word: {low_water, high_water, tx_en, rx_en, limit}.
  localparam int unsigned CfgBits = 3 * LimitBits + 2;
  localparam logic [CfgBits-1:0] CfgDefault = {{2 * LimitBits{1'b0}}, 2'b00, LimitDefault};
  logic [CfgBits-1:0] rx_cfg_msg, rx_cfg_q;
  logic rx_limit_msg_valid, rx_limit_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic rx_limit_idle;
  /* verilator lint_on UNUSEDSIGNAL */
  cdc_mailbox #(
      .WIDTH(CfgBits)
  ) u_rx_limit (
      .i_src_clk  (i_clk),
      // Match the RX FIFO's core half: this receiver must clear for either reset source.
      .i_src_rst  (i_rst || core_rst_dom[1]),
      .i_src_data ({i_pause_low_water, i_pause_high_water, i_pause_ctrl, i_rx_fifo_limit}),
      .i_src_valid(i_rx_fifo_limit_wr),
      .o_src_ready(rx_limit_ready),
      .o_src_idle (rx_limit_idle),
      .i_dst_clk  (i_rx_clk),
      .i_dst_rst  (rx_rst),
      .o_dst_data (rx_cfg_msg),
      .o_dst_valid(rx_limit_msg_valid),
      .i_dst_ready(1'b1)
  );
  assign o_rx_fifo_limit_busy = !rx_limit_ready;
  always_ff @(posedge i_rx_clk) begin
    if (rx_rst) rx_cfg_q <= CfgDefault;
    else if (rx_limit_msg_valid) rx_cfg_q <= rx_cfg_msg;
  end
  logic [LimitBits-1:0] rx_limit_q, cfg_high_water, cfg_low_water;
  logic [1:0] cfg_ctrl;
  assign {cfg_low_water, cfg_high_water, cfg_ctrl, rx_limit_q} = rx_cfg_q;

  // Effective thresholds: 0 selects three quarters / one quarter of the limit; high-water
  // stays below the limit (the FIFO stops accepting at limit - 2) and low-water below it.
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

  // Station address into both MAC domains, and configured pause interval into TX.
  logic [47:0] mac_rx_s, mac_tx_s;
  logic [15:0] interval_cfg_s;
  localparam logic [47:0] MacDefault = '0;
  logic [47:0] mac_rx_sent_q;
  logic [63:0] txc_sent_q;
  logic mac_rx_ready, mac_rx_msg_valid, txc_ready, txc_msg_valid;
  logic [47:0] mac_rx_msg;
  logic [63:0] txc_msg;
  /* verilator lint_off UNUSEDSIGNAL */
  logic mac_rx_idle, txc_idle;
  /* verilator lint_on UNUSEDSIGNAL */
  logic mac_rx_send, txc_send;
  assign mac_rx_send = (i_station_mac != mac_rx_sent_q);
  assign txc_send = ({i_pause_interval, i_station_mac} != txc_sent_q);
  cdc_mailbox #(
      .WIDTH(48)
  ) u_mac_rx_mbx (
      .i_src_clk  (i_clk),
      // As u_rx_limit: the core half clears for either reset source.
      .i_src_rst  (i_rst || core_rst_dom[1]),
      .i_src_data (i_station_mac),
      .i_src_valid(mac_rx_send),
      .o_src_ready(mac_rx_ready),
      .o_src_idle (mac_rx_idle),
      .i_dst_clk  (i_rx_clk),
      .i_dst_rst  (rx_rst),
      .o_dst_data (mac_rx_msg),
      .o_dst_valid(mac_rx_msg_valid),
      .i_dst_ready(1'b1)
  );
  cdc_mailbox #(
      .WIDTH(64)
  ) u_tx_cfg_mbx (
      .i_src_clk  (i_clk),
      // As the TX FIFO's write side: the core half clears for either reset source.
      .i_src_rst  (i_rst || core_rst_dom[0]),
      .i_src_data ({i_pause_interval, i_station_mac}),
      .i_src_valid(txc_send),
      .o_src_ready(txc_ready),
      .o_src_idle (txc_idle),
      .i_dst_clk  (i_tx_clk),
      .i_dst_rst  (tx_rst),
      .o_dst_data (txc_msg),
      .o_dst_valid(txc_msg_valid),
      .i_dst_ready(1'b1)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst || core_rst_dom[1]) mac_rx_sent_q <= MacDefault;
    else if (mac_rx_send && mac_rx_ready) mac_rx_sent_q <= i_station_mac;
    if (i_rst || core_rst_dom[0]) txc_sent_q <= {nic_pkg::PauseIntervalDefault, MacDefault};
    else if (txc_send && txc_ready) txc_sent_q <= {i_pause_interval, i_station_mac};
  end
  always_ff @(posedge i_rx_clk) begin
    if (rx_rst) mac_rx_s <= MacDefault;
    else if (mac_rx_msg_valid) mac_rx_s <= mac_rx_msg;
  end
  always_ff @(posedge i_tx_clk) begin
    if (tx_rst) {interval_cfg_s, mac_tx_s} <= {nic_pkg::PauseIntervalDefault, MacDefault};
    else if (txc_msg_valid) {interval_cfg_s, mac_tx_s} <= txc_msg;
  end

  logic [$clog2(RX_FIFO_DEPTH):0] rx_occupancy;
  logic pf_valid, pf_ready, pause_rx_ev, want_pause;
  logic [67:0] pf_word;
  logic [15:0] pause_rx_interval;
  nic_pause_rx_wire #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_pause_wire (
      .i_clk           (i_rx_clk),
      .i_rst           (rx_rst),
      .i_enable        (i_rx_wire_valid),
      .i_xgmii_data    (i_rx_wire_data),
      .i_xgmii_ctrl    (i_rx_wire_ctrl),
      .i_mac           (mac_rx_s),
      .o_pause_ev      (pause_rx_ev),
      .o_pause_tog     (),
      .o_pause_interval(pause_rx_interval)
  );
  nic_pause_rx #(
      .OCC_BITS(LimitBits)
  ) u_pause_rx (
      .i_clk           (i_rx_clk),
      .i_rst           (rx_rst),
      .i_mac           (mac_rx_s),
      .i_m_data        (i_mac_rx_tdata),
      .i_m_code        ({i_mac_rx_tlast, m_bytes_m1}),
      .i_m_valid       (i_mac_rx_tvalid),
      .o_m_ready       (o_mac_rx_tready),
      .o_f_valid       (pf_valid),
      .o_f_word        (pf_word),
      .i_f_ready       (pf_ready),
      .i_occupancy     (rx_occupancy),
      .i_high_water    (high_water_eff_q),
      .i_low_water     (low_water_eff_q),
      .i_tx_en         (cfg_ctrl[nic_pkg::PauseCtrlBitTx]),
      .o_want_pause    (want_pause),
      .o_pause_ev      (),
      .o_pause_tog     (),
      .o_pause_interval()
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
      .o_rst(i_rst || core_rst_dom[1]),
      .o_data(r_word),
      .o_valid(m_axis_rx_tvalid),
      .i_ready(m_axis_rx_tready)
  );
  assign m_axis_rx_tdata = r_word[63:0];
  assign m_axis_rx_tlast = r_word[67];
  assign m_axis_rx_tkeep = nic_pkg::beat_code_to_tkeep(r_word[67:64]);

  // ---- 802.3x transmit side ---------------------------------------------------------------
  logic tx_en_s, rx_en_s, want_pause_s;
  logic tx_paused, tx_pause_ev;
  cdc_sync #(
      .WIDTH(3)
  ) u_pause_lvl_sync (
      .i_clk  (i_tx_clk),
      .i_rst  (1'b0),
      .i_async({want_pause, cfg_ctrl}),
      .o_sync ({want_pause_s, tx_en_s, rx_en_s})
  );

  logic rx_rst_in_tx, tx_rst_in_rx, pause_rst_rx, pause_rst_tx;
  cdc_sync u_rx_rst_to_tx (
      .i_clk  (i_tx_clk),
      .i_rst  (1'b0),
      .i_async(rx_rst),
      .o_sync (rx_rst_in_tx)
  );
  cdc_sync u_tx_rst_to_rx (
      .i_clk  (i_rx_clk),
      .i_rst  (1'b0),
      .i_async(tx_rst),
      .o_sync (tx_rst_in_rx)
  );
  // Either domain's reset clears both halves of the pause-event mailbox.
  assign pause_rst_rx = rx_rst || tx_rst_in_rx;
  assign pause_rst_tx = tx_rst || rx_rst_in_tx;
  logic pend_q, pe_ready, pause_ev_tx;
  logic [15:0] pend_interval_q, pause_interval_tx;
  /* verilator lint_off UNUSEDSIGNAL */
  logic pe_idle;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge i_rx_clk) begin
    if (pause_rst_rx) pend_q <= 1'b0;
    else begin
      if (pend_q && pe_ready) pend_q <= 1'b0;
      if (pause_rx_ev) begin
        pend_q          <= 1'b1;
        pend_interval_q <= pause_rx_interval;
      end
    end
  end
  cdc_mailbox #(
      .WIDTH(16)
  ) u_pause_ev_mbx (
      .i_src_clk  (i_rx_clk),
      .i_src_rst  (pause_rst_rx),
      .i_src_data (pend_interval_q),
      .i_src_valid(pend_q),
      .o_src_ready(pe_ready),
      .o_src_idle (pe_idle),
      .i_dst_clk  (i_tx_clk),
      .i_dst_rst  (pause_rst_tx),
      .o_dst_data (pause_interval_tx),
      .o_dst_valid(pause_ev_tx),
      .i_dst_ready(1'b1)
  );
  nic_pause_tx #(
      .GMII_MODE(GMII_MODE)
  ) u_pause_tx (
      .i_clk           (i_tx_clk),
      .i_rst           (tx_rst),
      .i_tick          (i_tx_tick),
      .i_mac           (mac_tx_s),
      .i_rx_en         (rx_en_s),
      .i_tx_en         (tx_en_s),
      .i_interval_cfg  (interval_cfg_s),
      .i_want_pause    (want_pause_s),
      .i_pause_ev      (pause_ev_tx),
      .i_pause_interval(pause_interval_tx),
      .i_f_word        (f_word),
      .i_f_valid       (f_valid),
      .o_f_ready       (f_ready),
      .o_t_word        (t_word),
      .o_t_valid       (t_valid),
      .i_t_ready       (t_ready),
      .o_paused        (tx_paused),
      .o_tx_pause_ev   (tx_pause_ev)
  );

  // ---- status levels into the core domain -------------------------------------------------
  logic [4:0] rx_status_q;
  logic tx_link_ready_q;
  always_ff @(posedge i_rx_clk) begin
    rx_status_q <= {
      i_rx_signal_ok, i_rx_remote_fault, i_rx_local_fault, i_rx_high_ber, i_rx_locked
    };
  end
  always_ff @(posedge i_tx_clk) begin
    tx_link_ready_q <= i_tx_link_ready;
  end
  logic rx_signal_ok_s, rx_remote_fault_s, rx_local_fault_s, rx_high_ber_s, rx_locked_s;
  logic tx_link_ready_s;
  cdc_sync #(
      .WIDTH(5)
  ) u_rx_status_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(rx_status_q),
      .o_sync ({rx_signal_ok_s, rx_remote_fault_s, rx_local_fault_s, rx_high_ber_s, rx_locked_s})
  );
  cdc_sync u_tx_status_sync (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(tx_link_ready_q),
      .o_sync (tx_link_ready_s)
  );
  assign o_link = {
    clk_ok[1],
    clk_ok[0],
    rx_signal_ok_s,
    tx_link_ready_s,
    rx_remote_fault_s,
    rx_local_fault_s,
    rx_high_ber_s,
    rx_locked_s
  };

  // ---- event totals -----------------------------------------------------------------------
  logic desc_starved_s, overflow_no_desc;
  cdc_sync u_desc_starved_sync (
      .i_clk  (i_rx_clk),
      .i_rst  (1'b0),
      .i_async(i_rx_desc_starved),
      .o_sync (desc_starved_s)
  );
  assign overflow_no_desc = i_rx_overflow && desc_starved_s;

  localparam int unsigned NumEv = nic_pkg::NumMacTotals;
  logic [NumEv-1:0] ev_pulse;
  assign ev_pulse = {
    i_pcs_event,
    overflow_no_desc,
    i_gmii_pre_accept_event,
    i_gmii_short_ifg_event,
    i_gmii_er_ext_event,
    i_gmii_er_preamble_event,
    tx_paused,
    tx_pause_ev,
    pause_rx_ev,
    i_gmii_rx_er_event,
    i_gmii_preamble_drop,
    i_tx_bad_block,
    i_tx_drop,
    i_rx_bad_block,
    i_rx_bad_fcs,
    i_rx_bad_frame,
    i_rx_overflow
  };
  localparam logic [NumEv-1:0] EvIsRx = {
    {5{1'b1}},  // pcs_event
    {5{1'b1}},  // overflow_no_desc, pre_accept, short_ifg, er_ext, er_preamble
    1'b0,  // tx_paused
    1'b0,  // tx_pause_ev
    {3{1'b1}},  // pause_rx_ev, gmii_rx_er, gmii_preamble_drop
    {2{1'b0}},  // tx_bad_block, tx_drop
    {4{1'b1}}  // rx_bad_block, rx_bad_fcs, rx_bad_frame, rx_overflow
  };
  localparam int unsigned MacBase = nic_pkg::CntRxMacOverflow;
  localparam int unsigned GmiiBaseStart = nic_pkg::CntRxGmiiPreambleDrop - MacBase;
  localparam int unsigned PauseStart = nic_pkg::CntRxPauseFrames - MacBase;
  localparam int unsigned GmiiExtStart = nic_pkg::CntRxGmiiErPreamble - MacBase;
  localparam int unsigned OverflowNoDesc = nic_pkg::CntRxMacOverflowNoDesc - MacBase;
  localparam int unsigned PcsStart = nic_pkg::CntPcsSyncLoss - MacBase;

  logic rx_rebase, tx_rebase;
  assign {rx_rebase, tx_rebase} = core_rst_dom;
  // Skip GMII-only ranges while keeping the event indices used by the board Gray-bus constraints.
  for (
      genvar e = 0;
      e < NumEv;
      e = GMII_MODE ? e + 1 :
          (e + 1 == GmiiBaseStart) ? PauseStart :
          (e + 1 == GmiiExtStart) ? OverflowNoDesc :
          (e + 1 == PcsStart) ? NumEv : e + 1
  ) begin : g_events
    logic ev_clk, ev_rst, ev_rebase;
    if (EvIsRx[e]) begin : g_rx
      assign ev_clk = i_rx_clk;
      assign ev_rst = rx_rst;
      assign ev_rebase = rx_rebase;
    end else begin : g_tx
      assign ev_clk = i_tx_clk;
      assign ev_rst = tx_rst;
      assign ev_rebase = tx_rebase;
    end
    cdc_gray_count u_count (
        .i_src_clk   (ev_clk),
        .i_src_rst   (ev_rst),
        .i_src_event (ev_pulse[e]),
        .i_dst_clk   (i_clk),
        // A soft reset clears the totals at run time.
        .i_dst_rst   (i_rst || i_soft_rst),
        .i_dst_rebase(ev_rebase),
        .o_dst_total (o_totals[e*64+:64])
    );
  end
  if (!GMII_MODE) begin : g_no_gmii_totals
    assign o_totals[GmiiBaseStart*64+:(PauseStart-GmiiBaseStart)*64] = '0;
    assign o_totals[GmiiExtStart*64+:(OverflowNoDesc-GmiiExtStart)*64] = '0;
    assign o_totals[PcsStart*64+:(NumEv-PcsStart)*64] = '0;
  end
endmodule : nic_mac_cdc
