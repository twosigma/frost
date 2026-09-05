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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Two Sigma Open Source, LLC

// Standalone full-duplex MAC/PCS with a raw 64-bit PMA-facing interface.
// TX and RX clocks are independent, nominally 161.1328125 MHz. AXIS TX is
// synchronous to i_tx_clk and AXIS RX to i_rx_clk. No packet CDC is hidden
// here. The only crossing is a two-flop synchronization of fault status.
module eth10g_mac_pcs #(
    parameter int MAX_FRAME_BYTES = 9216,
    parameter int unsigned BER_WINDOW_CYCLES = 20142
) (
    input logic i_tx_clk,
    input logic i_tx_rst,
    input logic i_rx_clk,
    input logic i_rx_rst,
    input logic [63:0] s_axis_tdata,
    input logic [7:0] s_axis_tkeep,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tlast,
    input logic s_axis_tuser,
    output logic [63:0] m_axis_tdata,
    output logic [7:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tlast,
    output logic m_axis_tuser,
    output logic [63:0] o_tx_raw_data,
    output logic o_tx_raw_valid,
    output logic o_tx_link_ready,
    input logic [63:0] i_rx_raw_data,
    input logic i_rx_raw_valid,
    input logic i_rx_signal_ok,
    output logic o_rx_locked,
    output logic o_rx_high_ber,
    output logic o_rx_local_fault,
    output logic o_rx_remote_fault,
    output logic o_tx_drop,
    output logic o_rx_bad_frame,
    output logic o_rx_bad_fcs,
    output logic o_rx_overflow,
    output logic o_tx_bad_block,
    output logic o_rx_bad_block
);
  logic [63:0] mac_tx_data, rs_tx_data, rx_data;
  logic [7:0] mac_tx_ctrl, rs_tx_ctrl, rx_ctrl;
  logic tx_enable, rx_enable, mac_tx_ready;
  logic [65:0] tx_block, rx_block;
  logic tx_block_valid, tx_block_ready, rx_block_valid, rx_slip;
  (* ASYNC_REG = "TRUE" *) logic [1:0] local_fault_sync, remote_fault_sync;
  always_ff @(posedge i_tx_clk) begin
    if (i_tx_rst) begin
      local_fault_sync  <= 2'b11;
      remote_fault_sync <= '0;
    end else begin
      local_fault_sync  <= {local_fault_sync[0], o_rx_local_fault};
      remote_fault_sync <= {remote_fault_sync[0], o_rx_remote_fault};
    end
  end
  // Let MAC frames finish internally during a fault. The mux truncates a
  // frame on the wire, as RS fault signaling requires; it never pauses one.
  eth10g_tx_reconcile reconcile_tx (
      .i_clk(i_tx_clk),
      .i_rst(i_tx_rst),
      .i_enable(tx_enable),
      .i_local_fault(local_fault_sync[1]),
      .i_remote_fault(remote_fault_sync[1]),
      .i_xgmii_data(mac_tx_data),
      .i_xgmii_ctrl(mac_tx_ctrl),
      .o_xgmii_data(rs_tx_data),
      .o_xgmii_ctrl(rs_tx_ctrl),
      .o_link_ready(o_tx_link_ready)
  );
  // Backpressure ingress until the TX-domain fault response has recovered.
  // Frames accepted before a later link failure can still be lost on the wire.
  assign s_axis_tready = mac_tx_ready && o_tx_link_ready;
  eth10g_mac_tx #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) mac_tx (
      .i_clk(i_tx_clk),
      .i_rst(i_tx_rst),
      .i_enable(tx_enable),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid && o_tx_link_ready),
      .s_axis_tready(mac_tx_ready),
      .s_axis_tlast(s_axis_tlast),
      .s_axis_tuser(s_axis_tuser),
      .o_xgmii_data(mac_tx_data),
      .o_xgmii_ctrl(mac_tx_ctrl),
      .o_drop(o_tx_drop)
  );
  eth10g_pcs_tx pcs_tx (
      .i_clk(i_tx_clk),
      .i_rst(i_tx_rst),
      .i_xgmii_data(rs_tx_data),
      .i_xgmii_ctrl(rs_tx_ctrl),
      .o_xgmii_ready(tx_enable),
      .o_block(tx_block),
      .o_block_valid(tx_block_valid),
      .i_block_ready(tx_block_ready),
      .o_bad_block(o_tx_bad_block)
  );
  eth10g_tx_gearbox tx_gearbox (
      .i_clk(i_tx_clk),
      .i_rst(i_tx_rst),
      .i_block(tx_block),
      .i_block_valid(tx_block_valid),
      .o_block_ready(tx_block_ready),
      .o_raw_data(o_tx_raw_data),
      .o_raw_valid(o_tx_raw_valid)
  );
  eth10g_rx_gearbox rx_gearbox (
      .i_clk(i_rx_clk),
      .i_rst(i_rx_rst || !i_rx_signal_ok),
      .i_raw_data(i_rx_raw_data),
      .i_raw_valid(i_rx_raw_valid),
      .i_slip(rx_slip),
      .o_block(rx_block),
      .o_block_valid(rx_block_valid)
  );
  eth10g_pcs_rx #(
      .BER_WINDOW_CYCLES(BER_WINDOW_CYCLES)
  ) pcs_rx (
      .i_clk(i_rx_clk),
      .i_rst(i_rx_rst),
      .i_signal_ok(i_rx_signal_ok),
      .i_block(rx_block),
      .i_block_valid(rx_block_valid),
      .o_slip(rx_slip),
      .o_xgmii_data(rx_data),
      .o_xgmii_ctrl(rx_ctrl),
      .o_xgmii_valid(rx_enable),
      .o_locked(o_rx_locked),
      .o_high_ber(o_rx_high_ber),
      .o_bad_block(o_rx_bad_block)
  );
  eth10g_fault_monitor fault_monitor (
      .i_clk(i_rx_clk),
      .i_rst(i_rx_rst),
      .i_enable(rx_enable),
      .i_pcs_ok(i_rx_signal_ok && o_rx_locked && !o_rx_high_ber),
      .i_xgmii_data(rx_data),
      .i_xgmii_ctrl(rx_ctrl),
      .o_local_fault(o_rx_local_fault),
      .o_remote_fault(o_rx_remote_fault)
  );
  eth10g_mac_rx #(
      .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
  ) mac_rx (
      .i_clk(i_rx_clk),
      .i_rst(i_rx_rst),
      .i_enable(rx_enable),
      .i_xgmii_data(rx_data),
      .i_xgmii_ctrl(rx_ctrl),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
      .m_axis_tuser(m_axis_tuser),
      .o_bad_frame(o_rx_bad_frame),
      .o_bad_fcs(o_rx_bad_fcs),
      .o_overflow(o_rx_overflow)
  );
endmodule
