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
 * nic_mac_wrap: the MAC/PCS in its two clock domains and everything that
 * crosses to the core domain: the packet FIFOs, the domain resets, the
 * status levels, the event counters and the raw loopback.
 *
 * Beats cross as 68-bit FIFO words {code, data} (nic_pkg beat code:
 * {last, bytes - 1}). Each domain's reset comes from nic_domain_reset
 * under the core-side controller's generation handshake; the FIFO half in
 * a domain resets with that domain, the core-side half with
 * i_core_rst_dom. MAC_LOOPBACK (raw TX into raw RX; only meaningful with
 * one shared clock) is sampled by the RX domain while it is in reset, so
 * a change takes effect through a MAC-domain reset. Status levels are
 * two-flop synchronized; MAC event pulses become 64-bit totals in the
 * core domain through Gray-coded counters that rebase while the domain
 * is not ready.
 */
module nic_mac_wrap #(
    parameter int unsigned FIFO_DEPTH = 512,
    parameter int MAX_FRAME_BYTES = 9216
) (
    // Core domain.
    input  logic       i_clk,
    input  logic       i_rst,
    input  logic       i_soft_rst,
    input  logic [1:0] i_req,            // reset handshake (0 = TX, 1 = RX)
    input  logic [1:0] i_gen,
    output logic [1:0] o_in_reset,       // raw domain levels for the controller
    output logic [1:0] o_applied_gen,
    output logic [1:0] o_applied_valid,
    input  logic [1:0] i_core_rst_dom,
    input  logic       i_mac_loopback,

    input  logic        i_tx_valid,
    output logic        o_tx_ready,
    input  logic [63:0] i_tx_data,
    input  logic [ 3:0] i_tx_code,
    output logic        o_rx_valid,
    input  logic        i_rx_ready,
    output logic [63:0] o_rx_data,
    output logic [ 3:0] o_rx_code,

    output logic o_rx_locked,
    output logic o_rx_high_ber,
    output logic o_rx_local_fault,
    output logic o_rx_remote_fault,
    output logic o_tx_link_ready,
    output logic o_rx_signal_ok,
    // Totals in counter order: rx_overflow, rx_bad_frame, rx_bad_fcs,
    // rx_bad_block, tx_drop, tx_bad_block.
    output logic [5:0][63:0] o_totals,

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

  // One registered copy of the core reset per domain: the flop that launches
  // the asynchronous assertion into a MAC domain fans out nowhere else.
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
  logic [67:0] t_word;
  logic t_valid, t_ready;
  async_fifo #(
      .DATA_WIDTH(68),
      .DEPTH(FIFO_DEPTH)
  ) u_tx_fifo (
      .i_clk  (i_clk),
      .i_rst  (i_rst || i_core_rst_dom[0]),
      .i_data ({i_tx_code, i_tx_data}),
      .i_valid(i_tx_valid),
      .o_ready(o_tx_ready),
      .o_clk  (i_tx_clk),
      .o_rst  (tx_rst),
      .o_data (t_word),
      .o_valid(t_valid),
      .i_ready(t_ready)
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
  async_fifo #(
      .DATA_WIDTH(68),
      .DEPTH(FIFO_DEPTH)
  ) u_rx_fifo (
      .i_clk  (i_rx_clk),
      .i_rst  (rx_rst),
      .i_data ({m_last, m_bytes_m1, m_data}),
      .i_valid(m_valid),
      .o_ready(m_ready),
      .o_clk  (i_clk),
      .o_rst  (i_rst || i_core_rst_dom[1]),
      .o_data (r_word),
      .o_valid(o_rx_valid),
      .i_ready(i_rx_ready)
  );
  assign o_rx_data = r_word[63:0];
  assign o_rx_code = r_word[67:64];

  // ---- the raw loopback -------------------------------------------------------------------
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
  logic [63:0] rx_raw_data;
  logic rx_raw_valid, rx_signal_ok;
  assign rx_raw_data  = loop_q ? o_tx_raw_data : i_rx_raw_data;
  assign rx_raw_valid = loop_q ? o_tx_raw_valid : i_rx_raw_valid;
  assign rx_signal_ok = loop_q ? 1'b1 : i_rx_signal_ok;

  // ---- the MAC/PCS ------------------------------------------------------------------------
  logic rx_locked, rx_high_ber, rx_local_fault, rx_remote_fault, tx_link_ready;
  logic tx_drop, rx_bad_frame, rx_bad_fcs, rx_overflow, tx_bad_block, rx_bad_block;
  logic m_user;
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
      .s_axis_tuser     (1'b0),
      .m_axis_tdata     (m_data),
      .m_axis_tkeep     (m_keep),
      .m_axis_tvalid    (m_valid),
      .m_axis_tready    (m_ready),
      .m_axis_tlast     (m_last),
      .m_axis_tuser     (m_user),
      .o_tx_raw_data    (o_tx_raw_data),
      .o_tx_raw_valid   (o_tx_raw_valid),
      .o_tx_link_ready  (tx_link_ready),
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
  /* verilator lint_off UNUSEDSIGNAL */  // the RX MAC publishes complete frames only: tuser is 0
  logic m_user_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign m_user_unused = m_user;

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
  logic [5:0] ev_pulse;
  logic [5:0] ev_clk, ev_rst, ev_rebase;
  assign ev_pulse = {tx_bad_block, tx_drop, rx_bad_block, rx_bad_fcs, rx_bad_frame, rx_overflow};
  assign ev_clk = {i_tx_clk, i_tx_clk, i_rx_clk, i_rx_clk, i_rx_clk, i_rx_clk};
  assign ev_rst = {tx_rst, tx_rst, rx_rst, rx_rst, rx_rst, rx_rst};
  assign ev_rebase = {
    i_core_rst_dom[0],
    i_core_rst_dom[0],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[1],
    i_core_rst_dom[1]
  };
  for (genvar e = 0; e < 6; e++) begin : g_events
    cdc_gray_count u_count (
        .i_src_clk   (ev_clk[e]),
        .i_src_rst   (ev_rst[e]),
        .i_src_event (ev_pulse[e]),
        .i_dst_clk   (i_clk),
        .i_dst_rst   (i_rst || i_soft_rst),
        .i_dst_rebase(ev_rebase[e]),
        .o_dst_total (o_totals[e])
    );
  end
endmodule : nic_mac_wrap
