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

module nic_diag_formal (
    input logic              i_clk,
    input logic              i_rx_clk,
    input logic              i_tx_clk,
    input logic              i_rst,
    input logic              i_soft_rst,
    input logic [ 5:0]       i_common_events,
    input logic [ 5:0]       i_gmii_events,
    input logic [ 4:0]       i_pcs_events,
    input logic              i_desc_starved,
    input logic [20:0][63:0] i_mac_totals,
    input logic [11:0]       i_offset,
    input logic [32:0]       i_phy_sample
);
  logic clear;
  assign clear = i_rst || i_soft_rst;

  // The PHY receiver has two synchronizer stages, then acknowledges the observed
  // toggle and accumulates its payload on the following core edge.
  logic [3:0] reset_history_q = '0;
  logic [2:0] toggle_q;
  logic [31:0] payload_q;
  logic pending_q;
  logic [4:0][63:0] phy_ref_q;
  always_ff @(posedge i_clk) begin
    reset_history_q <= {reset_history_q[2:0], 1'b1};
    toggle_q <= {toggle_q[1:0], i_phy_sample[32]};
    if (clear) begin
      pending_q <= 1'b0;
      payload_q <= '0;
      phy_ref_q <= '0;
    end else begin
      pending_q <= toggle_q[1] != toggle_q[2];
      if (toggle_q[1] != toggle_q[2]) payload_q <= i_phy_sample[31:0];
      if (pending_q) begin
        phy_ref_q[0] <= 64'(payload_q[15:0]);
        phy_ref_q[1] <= phy_ref_q[1] + 64'(payload_q[15:0]);
        phy_ref_q[2] <= 64'(payload_q[31:16]);
        phy_ref_q[3] <= phy_ref_q[3] + 64'(payload_q[31:16]);
        phy_ref_q[4] <= phy_ref_q[4] + 64'd1;
      end
    end
  end
  always_comb begin
    if (!reset_history_q[3]) assume (i_rst);
    assert ((reset_history_q[3:1] & ~reset_history_q[2:0]) == '0);
  end

  for (genvar mode = 0; mode < 2; mode++) begin : g_mode
    localparam bit Gmii = mode != 0;
    logic [20:0][63:0] totals;
    logic phy_ack;
    logic [63:0] rd;
    nic_mac_cdc #(
        .FIFO_DEPTH(16),
        .RX_FIFO_DEPTH(16),
        .MAX_FRAME_BYTES(64),
        .GMII_MODE(Gmii)
    ) u_mac (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_soft_rst(i_soft_rst),
        .i_restart(1'b0),
        .i_station_mac('0),
        .i_pause_ctrl('0),
        .i_pause_high_water('0),
        .i_pause_low_water('0),
        .i_pause_interval('0),
        .i_rx_fifo_limit('0),
        .i_rx_fifo_limit_wr(1'b0),
        .i_rx_desc_starved(i_desc_starved),
        .o_totals(totals),
        .s_axis_tx_tvalid(1'b0),
        .s_axis_tx_tdata('0),
        .s_axis_tx_tkeep('0),
        .s_axis_tx_tlast(1'b0),
        .s_axis_tx_tuser(1'b0),
        .i_tx_csum('0),
        .m_axis_rx_tready(1'b0),
        .i_tx_clk(i_tx_clk),
        .i_rx_clk(i_rx_clk),
        .i_tx_clk_ok(1'b1),
        .i_rx_clk_ok(1'b1),
        .i_mac_tx_tready(1'b0),
        .i_tx_tick(1'b0),
        .i_mac_rx_tvalid(1'b0),
        .i_mac_rx_tdata('0),
        .i_mac_rx_tkeep('0),
        .i_mac_rx_tlast(1'b0),
        .i_rx_wire_data('0),
        .i_rx_wire_ctrl('0),
        .i_rx_wire_valid(1'b0),
        .i_rx_locked(1'b0),
        .i_rx_high_ber(1'b0),
        .i_rx_local_fault(1'b0),
        .i_rx_remote_fault(1'b0),
        .i_rx_signal_ok(1'b0),
        .i_tx_link_ready(1'b0),
        .i_rx_overflow(i_common_events[0]),
        .i_rx_bad_frame(i_common_events[1]),
        .i_rx_bad_fcs(i_common_events[2]),
        .i_rx_bad_block(i_common_events[3]),
        .i_tx_drop(i_common_events[4]),
        .i_tx_bad_block(i_common_events[5]),
        .i_gmii_preamble_drop(i_gmii_events[0]),
        .i_gmii_rx_er_event(i_gmii_events[1]),
        .i_gmii_er_preamble_event(i_gmii_events[2]),
        .i_gmii_er_ext_event(i_gmii_events[3]),
        .i_gmii_short_ifg_event(i_gmii_events[4]),
        .i_gmii_pre_accept_event(i_gmii_events[5]),
        .i_pcs_event(i_pcs_events)
    );
    nic_csr #(
        .RX_FIFO_DEPTH  (16),
        .ENABLE_PHY_DIAG(Gmii)
    ) u_csr (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_soft_rst(i_soft_rst),
        .i_wr_en(1'b0),
        .i_wr_offset('0),
        .i_wr_data('0),
        .i_wr64_en(1'b0),
        .i_wr64_data('0),
        .i_rd_offset(i_offset),
        .o_rd_pair(rd),
        .i_irq_status('0),
        .i_irq_mask('0),
        .i_rx_coalesce('0),
        .i_tx_coalesce('0),
        .i_tick('0),
        .i_rx_head('0),
        .i_tx_head('0),
        .i_rx_idle(1'b0),
        .i_tx_idle(1'b0),
        .i_reset_busy(1'b0),
        .i_rx_fifo_empty(1'b0),
        .i_rx_fifo_limit_busy(1'b0),
        .i_rx_ready(1'b0),
        .i_tx_ready(1'b0),
        .i_link('0),
        .i_phy_status('0),
        .i_phy_diag(i_phy_sample),
        .o_phy_diag_ack(phy_ack),
        .i_rx_complete(1'b0),
        .i_rx_complete_flags('0),
        .i_rx_complete_bytes('0),
        .i_rx_filtered(1'b0),
        .i_tx_complete(1'b0),
        .i_tx_complete_flags('0),
        .i_tx_complete_bytes('0),
        .i_segment_err(1'b0),
        .i_mac_totals(i_mac_totals)
    );

    // Compare the counters at their CDC boundary using the ABI slot order.
    logic [20:0] events;
    assign events = {
      i_pcs_events,
      i_common_events[0] && u_mac.u_desc_starved_sync.o_sync,
      i_gmii_events[5:2],
      u_mac.tx_paused,
      u_mac.tx_pause_ev,
      u_mac.pause_rx_ev,
      i_gmii_events[1:0],
      i_common_events
    };
    always_comb begin
      assert (u_mac.u_desc_starved_sync.i_clk == i_rx_clk);
      assert (u_mac.u_desc_starved_sync.i_async == i_desc_starved);
    end
    for (genvar e = 0; e < 21; e++) begin : g_count
      localparam bit GmiiOnly = (e >= 6 && e <= 7) || (e >= 11 && e <= 14) || e >= 16;
      localparam bit TxDomain = e == 4 || e == 5 || e == 9 || e == 10;
      localparam logic [11:0] Offset = (e <= 10) ? 12'h0d0 + 12'(8 * e) :
          12'h140 + 12'(8 * (e - 11));
      if (Gmii || !GmiiOnly) begin : g_live
        always_comb begin
          assert (u_mac.g_events[e].u_count.i_src_clk == (TxDomain ? i_tx_clk : i_rx_clk));
          assert (u_mac.g_events[e].u_count.i_src_rst == (TxDomain ? u_mac.tx_rst : u_mac.rx_rst));
          assert (u_mac.g_events[e].u_count.i_src_event == events[e]);
          assert (u_mac.g_events[e].u_count.i_dst_clk == i_clk);
          assert (u_mac.g_events[e].u_count.i_dst_rst == clear);
          assert (u_mac.g_events[e].u_count.i_dst_rebase == u_mac.core_rst_dom[TxDomain ? 0 : 1]);
          assert (totals[e] == u_mac.g_events[e].u_count.o_dst_total);
        end
      end else begin : g_disabled
        always_comb assert (totals[e] == '0);
      end
      // The decoder holds for any totals presented at the engine boundary.
      always_comb if (i_offset[11:3] == Offset[11:3]) assert (rd == i_mac_totals[e]);
    end

    if (Gmii) begin : g_phy_present
      // Compare each stage once a reset edge establishes its state.
      always_comb begin
        if (reset_history_q[0]) begin
          assert (u_csr.g_phy_diag.u_diag_tog_sync.stage_q[0] == toggle_q[0]);
          assert (u_csr.g_phy_diag.phy_diag_valid_q == pending_q);
          assert (u_csr.g_phy_diag.phy_diag_sample_q == payload_q);
          assert (u_csr.phy_rxerr_last_q == phy_ref_q[0]);
          assert (u_csr.phy_rxerr_sum_q == phy_ref_q[1]);
          assert (u_csr.phy_fcs_last_q == phy_ref_q[2]);
          assert (u_csr.phy_fcs_sum_q == phy_ref_q[3]);
          assert (u_csr.phy_polls_q == phy_ref_q[4]);
        end
        if (reset_history_q[1]) assert (u_csr.g_phy_diag.diag_tog_s == toggle_q[1]);
        if (reset_history_q[2]) assert (phy_ack == toggle_q[2]);
        if (reset_history_q[3])
          cover (phy_ref_q[4] == 2 && phy_ref_q[1] != 0 && i_offset == 12'h198);
      end
    end else begin : g_phy_absent
      always_comb begin
        assert (!phy_ack);
        if (reset_history_q[3])
          cover (i_offset == 12'h190 && i_phy_sample[32] && |i_phy_sample[15:0]);
      end
    end
    for (genvar p = 0; p < 5; p++) begin : g_phy_read
      localparam logic [11:0] Offset = 12'h190 + 12'(8 * p);
      always_comb
        if ((!Gmii || reset_history_q[3]) && i_offset[11:3] == Offset[11:3])
          assert (rd == (Gmii ? phy_ref_q[p] : '0));
    end
  end
endmodule : nic_diag_formal
