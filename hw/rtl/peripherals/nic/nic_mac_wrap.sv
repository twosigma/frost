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
 * RX and TX beats cross as 68-bit FIFO words {code, data}. TX checksum requests cross
 * once per frame in a side FIFO, and a reserved beat code marks an abort.
 * The ordinary nic_pkg beat code is {last, bytes - 1}. Each domain's reset comes from nic_domain_reset
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
    parameter bit GMII_MODE = 1'b0,
    // GMII only: 1 = a frame whose preamble holds one lone rx_er (before a valid SFD) is accepted, the
    // errored byte counted as a preamble byte; 0 = it is dropped (rx_gmii_preamble_drop). Both
    // count the rx_er in rx_gmii_er_preamble.
    parameter bit RX_PREAMBLE_ER_TOLERANT = 1'b0
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
    // Station address and pause interval cross to their consumers through mailboxes.
    // The RX configuration mailbox carries {low_water, high_water, tx_en, rx_en, limit}.
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
    // Core-domain level: the RX engine holds a frame and has no descriptor (counts MAC overflows
    // that happen meanwhile as dropped for "descriptor not available").
    input logic i_rx_desc_starved,
    // Totals in counter order: rx_overflow, rx_bad_frame, rx_bad_fcs,
    // rx_bad_block, tx_drop, tx_bad_block, gmii_preamble_drop, gmii_rx_er,
    // rx_pause, tx_pause, tx_paused_cycles, then nic_pkg CntRxGmiiErPreamble .. CntPcsRxnotintable.
    output logic [nic_pkg::NumMacTotals-1:0][63:0] o_totals,

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
  //
  // The data FIFO carries 68-bit beats {code, data}. The two per-frame fields travel apart:
  // the checksum request (constant across a frame, used from its first beat) crosses in a
  // small side FIFO, one entry per frame pushed with the first beat, and an abort is the
  // closing beat's code TxAbortCode (a non-final beat of one byte, which a frame never
  // contains), decoded back to {last, one byte} plus the abort flag after the crossing. The
  // first beat of a frame leaves the data FIFO together with its side entry.
  localparam logic [3:0] TxAbortCode = 4'b0000;
  localparam int unsigned TxCsumDepth = 32;
  logic [83:0] t_word, f_word;
  logic t_valid, t_ready, f_valid, f_ready;
  // The write half of both TX FIFOs clears for either reset source, as the RX FIFO's core
  // half does, so one term feeds the data and side FIFOs.
  logic tx_wr_rst;
  assign tx_wr_rst = i_rst || i_core_rst_dom[0];

  // Write side: the side entry is pushed with the first beat; both FIFOs must have room for it.
  logic tx_wr_first_q, tx_data_ready, tx_csum_ready, tx_beat_ok, tx_beat_fire;
  assign tx_beat_ok   = !tx_wr_first_q || tx_csum_ready;
  assign o_tx_ready   = tx_data_ready && tx_beat_ok;
  assign tx_beat_fire = i_tx_valid && o_tx_ready;
  always_ff @(posedge i_clk) begin
    if (tx_wr_rst) tx_wr_first_q <= 1'b1;
    else if (tx_beat_fire) tx_wr_first_q <= i_tx_code[3] || i_tx_abort;
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
      .i_data({i_tx_abort ? TxAbortCode : i_tx_code, i_tx_data}),
      .i_valid(i_tx_valid && tx_beat_ok),
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
      .i_valid(i_tx_valid && tx_wr_first_q && tx_data_ready),
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
  // The configuration word: {low_water, high_water, tx_en, rx_en, limit}. The pause interval
  // goes to TX in its own mailbox (below).
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
      .i_src_rst  (i_rst || i_core_rst_dom[1]),
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

  // Station address into the two MAC domains, and the configured pause interval into TX. Each
  // domain has a mailbox from the core: the core side sends the whole value again whenever it
  // differs from the last value sent (after a reset that is the reset default), so the MAC
  // domain always sees one complete value, never a mix of old and new bits. A domain restart
  // resets its mailbox's core side too (i_core_rst_dom), so the value is sent again.
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
      .i_src_rst  (i_rst || i_core_rst_dom[1]),
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
      .i_src_rst  (i_rst || i_core_rst_dom[0]),
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
    if (i_rst || i_core_rst_dom[1]) mac_rx_sent_q <= MacDefault;
    else if (mac_rx_send && mac_rx_ready) mac_rx_sent_q <= i_station_mac;
    if (i_rst || i_core_rst_dom[0]) txc_sent_q <= {nic_pkg::PauseIntervalDefault, MacDefault};
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
  logic [63:0] rx_wire_data;
  logic [7:0] rx_wire_ctrl;
  logic rx_wire_valid;
  nic_pause_rx_wire #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) u_pause_wire (
      .i_clk(i_rx_clk),
      .i_rst(rx_rst),
      .i_enable(rx_wire_valid),
      .i_xgmii_data(rx_wire_data),
      .i_xgmii_ctrl(rx_wire_ctrl),
      .i_mac(mac_rx_s),
      .o_pause_ev(pause_rx_ev),
      .o_pause_tog(),
      .o_pause_interval(pause_rx_interval)
  );
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
  // Further GMII diagnostics: rx_er in the preamble, rx_er with the data enable low (carrier extend,
  // false carrier), a short inter-frame gap, a frame kept despite a lone preamble rx_er, and the PCS
  // status_vector events (sync lost, RUDI /C/, RUDI INVALID, RXDISPERR, RXNOTINTABLE).
  logic gmii_er_preamble_event, gmii_er_ext_event, gmii_short_ifg_event, gmii_pre_accept_event;
  logic [4:0] pcs_event;
  if (!GMII_MODE) begin : gen_10g_pcs
    assign gmii_preamble_drop = 1'b0;
    assign gmii_rx_er_event = 1'b0;
    assign gmii_er_preamble_event = 1'b0;
    assign gmii_er_ext_event = 1'b0;
    assign gmii_short_ifg_event = 1'b0;
    assign gmii_pre_accept_event = 1'b0;
    assign pcs_event = '0;
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
  end else begin : gen_1g_gmii
    // 1G GMII adapter around eth10g_mac_tx and eth10g_mac_rx.
    // o_tx_raw_data[9:0] = {gmii_tx_er, gmii_tx_en, gmii_txd[7:0]}, o_tx_raw_valid = sgmii_clk_en
    // rx_raw_data[9:0]   = {gmii_rx_er, gmii_rx_dv, gmii_rxd[7:0]}, rx_raw_valid   = sgmii_clk_en
    // rx_raw_data[25:10] = the PCS/PMA status_vector (a level in the RX clock domain)
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
    logic xgmii_rx_en_q;
    logic gmii_er_prev_q, gmii_er_pre_prev_q, gmii_er_ext_prev_q;
    // A lone rx_er has been taken as a preamble byte in this frame's preamble.
    logic       pre_er_seen_q;
    // Byte times since the data enable fell (saturating); frames are counted short below 12.
    logic [3:0] ifg_cnt_q;
    logic ifg_valid_q, gmii_dv_prev_q;

    wire  [ 7:0] gmii_rxd = rx_raw_data[7:0];
    wire         gmii_rx_dv = rx_raw_data[8];
    wire         gmii_rx_er = rx_raw_data[9];
    wire         gmii_rx_clk_en = rx_raw_valid;
    wire  [15:0] pcs_status = rx_raw_data[25:10];
    /* verilator lint_off UNUSEDSIGNAL */
    wire         rx_raw_unused = |rx_raw_data[63:26];
    /* verilator lint_on UNUSEDSIGNAL */

    // PCS status_vector events, one per rx clock (the vector is a level in this domain). Bit 1 is
    // link synchronisation, 2 RUDI(/C/), 4 RUDI(INVALID), 5 RXDISPERR, 6 RXNOTINTABLE.
    logic [ 1:0] pcs_prev_q;
    logic        pcs_sync_prev_q;
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
        gmii_er_pre_prev_q <= 1'b0;
        gmii_er_ext_prev_q <= 1'b0;
        gmii_er_preamble_event <= 1'b0;
        gmii_er_ext_event <= 1'b0;
        gmii_short_ifg_event <= 1'b0;
        gmii_pre_accept_event <= 1'b0;
        pre_er_seen_q <= 1'b0;
        ifg_cnt_q <= '0;
        ifg_valid_q <= 1'b0;
        gmii_dv_prev_q <= 1'b0;
      end else begin
        xgmii_rx_en_q <= 1'b0;
        gmii_preamble_drop <= 1'b0;
        gmii_rx_er_event <= 1'b0;
        gmii_er_preamble_event <= 1'b0;
        gmii_er_ext_event <= 1'b0;
        gmii_short_ifg_event <= 1'b0;
        gmii_pre_accept_event <= 1'b0;
        if (gmii_rx_clk_en) begin
          // One event per rx_er burst: inside the frame's data enable (after its SFD), in its
          // preamble (data enable with the receiver before the SFD), or outside it (carrier extend).
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
          // Inter-frame gap in byte times, from the data enable's fall to the next rise.
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
                if (RX_PREAMBLE_ER_TOLERANT && gmii_rx_er) begin
                  // A lone rx_er on the first preamble byte is taken as a preamble byte
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
                xgmii_rx_data_q <= 64'hd555_5555_5555_55fb;
                xgmii_rx_ctrl_q <= 8'h01;
                xgmii_rx_en_q <= 1'b1;
                gmii_rx_lane_q <= 3'd0;
                gmii_rx_state_q <= GMII_RX_DATA;
                gmii_pre_accept_event <= pre_er_seen_q;
              end else if (RX_PREAMBLE_ER_TOLERANT && gmii_rx_er && !pre_er_seen_q) begin
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

    assign rx_wire_data  = xgmii_rx_data_q;
    assign rx_wire_ctrl  = xgmii_rx_ctrl_q;
    assign rx_wire_valid = xgmii_rx_en_q;
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

  // A received pause interval reaches TX through a mailbox from the RX domain. An event that
  // arrives while the mailbox is busy is held (the newest wins) and sent when it is free. Each
  // side of this mailbox resets with either MAC domain, so a reset of one domain leaves
  // neither half mid-handshake, and no event from before a TX reset restarts the timer after it.
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
      .i_tick          (tx_tick),
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
  // The RX engine's descriptor-starved level, synchronised into the RX domain, qualifies overflows.
  logic desc_starved_s, overflow_no_desc;
  cdc_sync u_desc_starved_sync (
      .i_clk  (i_rx_clk),
      .i_rst  (1'b0),
      .i_async(i_rx_desc_starved),
      .o_sync (desc_starved_s)
  );
  assign overflow_no_desc = rx_overflow && desc_starved_s;

  localparam int unsigned NumEv = nic_pkg::NumMacTotals;
  logic [NumEv-1:0] ev_pulse;
  logic [NumEv-1:0] ev_clk, ev_rst, ev_rebase;
  // Event sources in o_totals order, with their clock domain: 1 = RX MAC clock, 0 = TX MAC clock.
  assign ev_pulse = {
    pcs_event,
    overflow_no_desc,
    gmii_pre_accept_event,
    gmii_short_ifg_event,
    gmii_er_ext_event,
    gmii_er_preamble_event,
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
  localparam logic [NumEv-1:0] EvIsRx = {
    {5{1'b1}},  // pcs_event
    {5{1'b1}},  // overflow_no_desc, pre_accept, short_ifg, er_ext, er_preamble
    1'b0,  // tx_paused
    1'b0,  // tx_pause_ev
    {3{1'b1}},  // pause_rx_ev, gmii_rx_er, gmii_preamble_drop
    {2{1'b0}},  // tx_bad_block, tx_drop
    {4{1'b1}}  // rx_bad_block, rx_bad_fcs, rx_bad_frame, rx_overflow
  };
  // Each counter takes its event's domain reset, and a soft reset rebases or
  // clears the totals at run time.
  for (genvar e = 0; e < NumEv; e++) begin : g_events
    assign ev_clk[e]    = EvIsRx[e] ? i_rx_clk : i_tx_clk;
    assign ev_rst[e]    = EvIsRx[e] ? rx_rst : tx_rst;
    assign ev_rebase[e] = EvIsRx[e] ? i_core_rst_dom[1] : i_core_rst_dom[0];
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
