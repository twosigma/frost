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

// Candidate blocks already come from the raw gearbox. o_slip consumes one
// extra bit with the CURRENT candidate. XGMII is qualified by o_xgmii_valid;
// the raw-domain clock continues through the occasional block-enable pause.
module eth10g_pcs_rx #(
    parameter int unsigned BER_WINDOW_CYCLES = 20142
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_signal_ok,
    input logic [65:0] i_block,
    input logic i_block_valid,
    output logic o_slip,
    output logic [63:0] o_xgmii_data,
    output logic [7:0] o_xgmii_ctrl,
    output logic o_xgmii_valid,
    output logic o_locked,
    output logic o_high_ber,
    output logic o_bad_block
);
  logic [63:0] descrambled, decoded, checked_data;
  logic [7:0] decoded_ctrl, checked_ctrl;
  logic [1:0] header_reg;
  logic valid_reg, good_reg, bad_block;
  logic reset_path;
  logic pcs_ok, checked_valid, bad_sequence;
  assign reset_path = i_rst || !i_signal_ok;
  assign pcs_ok = i_signal_ok && o_locked && !o_high_ber;

  eth10g_block_lock block_lock (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_signal_ok(i_signal_ok),
      .i_block_valid(i_block_valid),
      .i_header(i_block[1:0]),
      .o_slip(o_slip),
      .o_locked(o_locked)
  );
  eth10g_ber_monitor #(
      .WINDOW_CYCLES(BER_WINDOW_CYCLES)
  ) ber_monitor (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_locked(o_locked),
      .i_block_valid(i_block_valid),
      .i_header(i_block[1:0]),
      .o_high_ber(o_high_ber)
  );
  eth10g_descrambler descrambler (
      .i_clk(i_clk),
      .i_rst(reset_path),
      .i_enable(i_block_valid),
      .i_data(i_block[65:2]),
      .o_data(descrambled)
  );
  eth10g_decode decoder (
      .i_payload(descrambled),
      .i_header(header_reg),
      .o_xgmii_data(decoded),
      .o_xgmii_ctrl(decoded_ctrl),
      .o_bad_block(bad_block)
  );
  eth10g_rx_sequence sequence_check (
      .i_clk(i_clk),
      .i_rst(i_rst || !pcs_ok),
      .i_enable(valid_reg && good_reg),
      .i_xgmii_data(decoded),
      .i_xgmii_ctrl(decoded_ctrl),
      .i_bad_block(bad_block),
      .o_xgmii_data(checked_data),
      .o_xgmii_ctrl(checked_ctrl),
      .o_valid(checked_valid),
      .o_bad_sequence(bad_sequence)
  );
  always_ff @(posedge i_clk) begin
    if (reset_path) begin
      valid_reg  <= 1'b0;
      good_reg   <= 1'b0;
      header_reg <= '0;
    end else begin
      valid_reg <= i_block_valid;
      good_reg  <= o_locked && !o_high_ber;
      if (i_block_valid) header_reg <= i_block[1:0];
    end
  end
  // Local fault also aborts an unfinished MAC frame when the input disappears.
  assign o_xgmii_valid = !i_rst && (pcs_ok ? checked_valid : (valid_reg || !i_signal_ok));
  assign o_xgmii_data  = pcs_ok ? checked_data : 64'h0100009c0100009c;
  assign o_xgmii_ctrl  = pcs_ok ? checked_ctrl : 8'h11;
  assign o_bad_block   = pcs_ok && checked_valid && bad_sequence;
endmodule
