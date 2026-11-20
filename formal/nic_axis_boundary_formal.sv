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
 * Formal boundary check for the core-clock AXI4-Stream <-> beat-code
 * bijection and abort/checksum side-FIFO framing between nic_engine and
 * nic_mac_cdc.
 */
module nic_axis_boundary_formal (
    input logic        i_clk,
    input logic        i_rst,
    input logic [ 3:0] i_tx_code,
    input logic        i_tx_abort,
    input logic [63:0] i_tx_data,
    input logic        i_tx_valid,
    input logic        i_tx_data_ready,
    input logic        i_tx_csum_ready,
    input logic [ 3:0] i_rx_code,
    input logic [63:0] i_rx_data
);
  localparam logic [3:0] TxAbortCode = 4'b0000;

  // nic_engine TX encoding: beat code -> {tlast, tkeep, tuser}.
  wire        tx_tlast = i_tx_code[3];
  wire [ 7:0] tx_tkeep = nic_pkg::beat_code_to_tkeep(i_tx_code);
  wire        tx_tuser = i_tx_abort;

  // nic_mac_cdc TX decoding: {tlast, tkeep, tuser} -> FIFO word & side-FIFO framing.
  wire [ 3:0] tx_decoded_code = nic_pkg::tkeep_to_beat_code(tx_tlast, tx_tkeep);
  wire [67:0] tx_axis_fifo_word = {tx_tuser ? TxAbortCode : tx_decoded_code, i_tx_data};
  wire [67:0] tx_ref_fifo_word = {i_tx_abort ? TxAbortCode : i_tx_code, i_tx_data};

  // Side-FIFO first-beat tracking (AXIS path vs beat-code path).
  logic axis_first_q, ref_first_q;
  wire axis_ok = !axis_first_q || i_tx_csum_ready;
  wire ref_ok = !ref_first_q || i_tx_csum_ready;
  wire axis_ready = i_tx_data_ready && axis_ok;
  wire ref_ready = i_tx_data_ready && ref_ok;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      axis_first_q <= 1'b1;
      ref_first_q  <= 1'b1;
    end else begin
      if (i_tx_valid && axis_ready) axis_first_q <= tx_tlast || tx_tuser;
      if (i_tx_valid && ref_ready) ref_first_q <= i_tx_code[3] || i_tx_abort;
    end
  end

  // nic_mac_cdc RX encoding -> nic_engine RX decoding.
  wire       rx_tlast = i_rx_code[3];
  wire [7:0] rx_tkeep = nic_pkg::beat_code_to_tkeep(i_rx_code);
  wire [3:0] rx_decoded_code = nic_pkg::tkeep_to_beat_code(rx_tlast, rx_tkeep);

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
  end

  always_comb begin
    // Bijection across all 16 beat codes in both directions.
    assert (tx_decoded_code == i_tx_code);
    assert (rx_decoded_code == i_rx_code);
    assert (tx_axis_fifo_word == tx_ref_fifo_word);
    // TKEEP is always a contiguous low-byte mask of 1..8 bytes.
    assert (tx_tkeep inside {8'h01, 8'h03, 8'h07, 8'h0F, 8'h1F, 8'h3F, 8'h7F, 8'hFF});
    assert (rx_tkeep inside {8'h01, 8'h03, 8'h07, 8'h0F, 8'h1F, 8'h3F, 8'h7F, 8'hFF});
    // Non-abort valid frame beats (non-final beats always carry 8 bytes: code[2:0] == 7)
    // never collide with TxAbortCode.
    if (!i_tx_abort && (i_tx_code[3] || i_tx_code[2:0] == 3'd7))
      assert (tx_axis_fifo_word[67:64] != TxAbortCode);
    if (f_past_valid) begin
      assert (axis_first_q == ref_first_q);
      assert (axis_ready == ref_ready);
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      cover (i_tx_valid && axis_ready && !tx_tlast && !tx_tuser && (tx_tkeep == 8'hFF));
      cover (i_tx_valid && axis_ready && tx_tlast && !tx_tuser && (tx_tkeep == 8'h01));
      cover (i_tx_valid && axis_ready && tx_tuser && (tx_axis_fifo_word[67:64] == TxAbortCode));
      cover (rx_tlast && (rx_tkeep == 8'h1F));
    end
  end
`endif
endmodule : nic_axis_boundary_formal
