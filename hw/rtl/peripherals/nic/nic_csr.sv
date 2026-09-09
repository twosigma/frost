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
 * nic_csr: the NIC's register file (nic_pkg for the map; the interrupt
 * block's registers live in nic_irq and are only read through here).
 *
 * Writes are 32-bit lane writes by window offset, reads return the
 * addressed 64-bit pair (counters are read whole). Configuration writes
 * are ignored while RESET is in progress; a CTRL write with RESET set
 * requests the reset and nothing else of that write applies.
 *
 * An enable is accepted only while the direction is READY and its ring is
 * valid (BASE 32-byte aligned, SIZE in range, the ring inside the
 * aperture); a refused enable sets *_CONFIG_ERR and raises DESC_ERR. A
 * direction that loses READY (its MAC domain resetting) is disabled. BASE
 * and SIZE are writable only while the direction is disabled and idle; a
 * write starts a new ring generation (TAIL and, through o_*_restart, the
 * engine's HEAD and descriptor cache reset).
 *
 * i_soft_rst is the RESET's core-domain reset: it clears the enables, the
 * rings and the counters; the station address, PROMISC, PHY_CTRL survive.
 */
module nic_csr #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_soft_rst,

    // Register access.
    input  logic        i_wr_en,
    input  logic [11:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    /* verilator lint_off UNUSEDSIGNAL */  // reads are 64-bit aligned: bits 2:0 are ignored
    input  logic [11:0] i_rd_offset,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] o_rd_pair,

    // The interrupt block's registers.
    input logic [31:0] i_irq_status,
    input logic [31:0] i_irq_mask,
    input logic [31:0] i_rx_itr,
    input logic [31:0] i_tx_itr,
    input logic [31:0] i_tick,

    // Control.
    output logic                  o_rx_en,
    output logic                  o_tx_en,
    output logic                  o_promisc,
    output logic [          47:0] o_mac,
    output logic                  o_reset_req,
    output logic [ADDR_WIDTH-1:0] o_rx_base,
    output logic [ADDR_WIDTH-1:0] o_tx_base,
    output logic [           4:0] o_rx_size_log2,
    output logic [           4:0] o_tx_size_log2,
    output logic [          15:0] o_rx_tail,
    output logic [          15:0] o_tx_tail,
    output logic                  o_rx_restart,
    output logic                  o_tx_restart,
    output logic [           3:0] o_phy_ctrl,

    // Status.
    input logic [15:0] i_rx_head,
    input logic [15:0] i_tx_head,
    input logic        i_rx_idle,
    input logic        i_tx_idle,
    input logic        i_reset_busy,
    input logic        i_rx_fifo_empty,
    input logic        i_rx_ready,
    input logic        i_tx_ready,
    // {rx_clk_ok, tx_clk_ok, rx_signal_ok, tx_link_ready, rx_remote_fault,
    //  rx_local_fault, rx_high_ber, rx_locked}
    input logic [ 7:0] i_link,
    input logic [ 4:0] i_phy_status,

    // Completions and drops from the engines.
    input logic              i_rx_complete,
    input logic [ 2:0]       i_rx_complete_flags,  // {ABORT, ERR, TRUNC}
    input logic [15:0]       i_rx_complete_bytes,
    input logic              i_rx_filtered,
    input logic              i_tx_complete,
    input logic [ 2:0]       i_tx_complete_flags,
    input logic [15:0]       i_tx_complete_bytes,
    // MAC-domain totals in counter order: rx_overflow, rx_bad_frame,
    // rx_bad_fcs, rx_bad_block, tx_drop, tx_bad_block.
    input logic [ 5:0][63:0] i_mac_totals,

    // Events for the interrupt block (one-cycle pulses).
    output logic o_link_change,
    output logic o_desc_err,
    output logic o_rx_drop
);
  // ---- state -----------------------------------------------------------------------
  logic rx_en_q, tx_en_q, promisc_q, rx_cfg_err_q, tx_cfg_err_q;
  logic [47:0] mac_q;
  logic [ 3:0] phy_ctrl_q;
  logic [ADDR_WIDTH-1:0] rx_base_q, tx_base_q;
  logic [4:0] rx_size_q, tx_size_q;
  logic [15:0] rx_tail_q, tx_tail_q;
  logic [63:0] cnt_q[10];
  logic carrier_q;
  logic [63:0] rx_overflow_seen_q;

  assign o_rx_en = rx_en_q;
  assign o_tx_en = tx_en_q;
  assign o_promisc = promisc_q;
  assign o_mac = mac_q;
  assign o_rx_base = rx_base_q;
  assign o_tx_base = tx_base_q;
  assign o_rx_size_log2 = rx_size_q;
  assign o_tx_size_log2 = tx_size_q;
  assign o_rx_tail = rx_tail_q;
  assign o_tx_tail = tx_tail_q;
  assign o_phy_ctrl = phy_ctrl_q;

  function automatic logic ring_ok(input logic [ADDR_WIDTH-1:0] base, input logic [4:0] size);
    logic [32:0] end_addr;
    end_addr = 33'(base) + (33'd16 << size);
    ring_ok  = (base[4:0] == 5'b0) && (size >= 5'(nic_pkg::RingSizeLog2Min)) &&
        (size <= 5'(nic_pkg::RingSizeLog2Max)) && (base >= APERTURE_BASE) &&
        (end_addr <= (33'(APERTURE_BASE) + 33'(APERTURE_BYTES)));
  endfunction

  // ---- writes ------------------------------------------------------------------------
  // RESET reads back busy from the cycle after its write (o_reset_req is the
  // registered request; the controller is busy the cycle after that).
  logic reset_busy;
  assign reset_busy = i_reset_busy || o_reset_req;
  logic wr;  // a configuration write (none while RESET is in progress)
  assign wr = i_wr_en && !reset_busy;
  logic wr_ctrl;
  assign wr_ctrl = wr && (i_wr_offset == nic_pkg::CtrlOffset);
  logic reset_write;
  assign reset_write = wr_ctrl && i_wr_data[nic_pkg::CtrlBitReset];
  logic rx_enable_try, tx_enable_try, rx_enable_ok, tx_enable_ok;
  assign rx_enable_try = wr_ctrl && !reset_write && i_wr_data[nic_pkg::CtrlBitRxEn] && !rx_en_q;
  assign tx_enable_try = wr_ctrl && !reset_write && i_wr_data[nic_pkg::CtrlBitTxEn] && !tx_en_q;
  assign rx_enable_ok  = ring_ok(rx_base_q, rx_size_q) && i_rx_ready;
  assign tx_enable_ok  = ring_ok(tx_base_q, tx_size_q) && i_tx_ready;
  logic rx_ring_writable, tx_ring_writable;
  assign rx_ring_writable = wr && !rx_en_q && i_rx_idle;
  assign tx_ring_writable = wr && !tx_en_q && i_tx_idle;

  // ---- link ------------------------------------------------------------------------------
  logic carrier;
  assign carrier = i_link[nic_pkg::LinkBitRxLocked] && !i_link[nic_pkg::LinkBitRxHighBer] &&
      !i_link[nic_pkg::LinkBitRxLocalFault] && !i_link[nic_pkg::LinkBitRxRemoteFault] &&
      i_link[nic_pkg::LinkBitTxLinkReady];

  // ---- counters and events ----------------------------------------------------------
  logic rx_err, rx_abort, rx_trunc, tx_err, tx_abort;
  assign rx_abort = i_rx_complete && i_rx_complete_flags[nic_pkg::FlagAbort];
  assign rx_err = i_rx_complete && i_rx_complete_flags[nic_pkg::FlagErr] && !rx_abort;
  assign rx_trunc = i_rx_complete && i_rx_complete_flags[nic_pkg::FlagTrunc] && !rx_err &&
      !rx_abort;
  assign tx_abort = i_tx_complete && i_tx_complete_flags[nic_pkg::FlagAbort];
  assign tx_err = i_tx_complete && i_tx_complete_flags[nic_pkg::FlagErr] && !tx_abort;
  logic rx_clean, tx_clean;
  assign rx_clean = i_rx_complete && !rx_abort && !rx_err && !rx_trunc;
  assign tx_clean = i_tx_complete && !tx_abort && !tx_err;
  logic mac_overflow_event;
  assign mac_overflow_event = i_mac_totals[0] != rx_overflow_seen_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      promisc_q  <= 1'b0;
      mac_q      <= '0;
      phy_ctrl_q <= '0;
    end else if (wr_ctrl && !reset_write) begin
      promisc_q <= i_wr_data[nic_pkg::CtrlBitPromisc];
    end else begin
      if (wr && (i_wr_offset == nic_pkg::MacLoOffset)) mac_q[31:0] <= i_wr_data;
      if (wr && (i_wr_offset == nic_pkg::MacHiOffset)) mac_q[47:32] <= i_wr_data[15:0];
      if (wr && (i_wr_offset == nic_pkg::PhyCtrlOffset)) phy_ctrl_q <= i_wr_data[3:0];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_soft_rst) begin
      rx_en_q            <= 1'b0;
      tx_en_q            <= 1'b0;
      rx_cfg_err_q       <= 1'b0;
      tx_cfg_err_q       <= 1'b0;
      rx_base_q          <= '0;
      tx_base_q          <= '0;
      rx_size_q          <= '0;
      tx_size_q          <= '0;
      rx_tail_q          <= '0;
      tx_tail_q          <= '0;
      o_rx_restart       <= 1'b0;
      o_tx_restart       <= 1'b0;
      o_reset_req        <= 1'b0;
      o_link_change      <= 1'b0;
      o_desc_err         <= 1'b0;
      o_rx_drop          <= 1'b0;
      carrier_q          <= 1'b0;
      rx_overflow_seen_q <= '0;
      for (int i = 0; i < 10; i++) cnt_q[i] <= '0;
    end else begin
      o_rx_restart <= 1'b0;
      o_tx_restart <= 1'b0;
      o_reset_req <= reset_write;
      o_link_change <= carrier != carrier_q;
      carrier_q <= carrier;
      o_desc_err    <= rx_err || rx_abort || tx_err || tx_abort ||
          (rx_enable_try && !rx_enable_ok) ||
          (tx_enable_try && !tx_enable_ok);
      o_rx_drop <= i_rx_filtered || rx_err || rx_abort || mac_overflow_event;
      rx_overflow_seen_q <= i_mac_totals[0];

      // Enables.
      if (rx_enable_try) begin
        rx_en_q      <= rx_enable_ok;
        rx_cfg_err_q <= !rx_enable_ok;
      end else if (wr_ctrl && !reset_write && !i_wr_data[nic_pkg::CtrlBitRxEn]) begin
        rx_en_q      <= 1'b0;
        rx_cfg_err_q <= 1'b0;
      end
      if (tx_enable_try) begin
        tx_en_q      <= tx_enable_ok;
        tx_cfg_err_q <= !tx_enable_ok;
      end else if (wr_ctrl && !reset_write && !i_wr_data[nic_pkg::CtrlBitTxEn]) begin
        tx_en_q      <= 1'b0;
        tx_cfg_err_q <= 1'b0;
      end
      // A direction whose MAC domain is resetting is disabled.
      if (!i_rx_ready) rx_en_q <= 1'b0;
      if (!i_tx_ready) tx_en_q <= 1'b0;

      // Rings.
      if (rx_ring_writable && (i_wr_offset == nic_pkg::RxBaseOffset)) begin
        rx_base_q    <= {i_wr_data[ADDR_WIDTH-1:5], 5'b0};
        rx_tail_q    <= '0;
        o_rx_restart <= 1'b1;
      end
      if (rx_ring_writable && (i_wr_offset == nic_pkg::RxSizeOffset)) begin
        rx_size_q    <= i_wr_data[4:0];
        rx_tail_q    <= '0;
        o_rx_restart <= 1'b1;
      end
      if (wr && (i_wr_offset == nic_pkg::RxTailOffset)) rx_tail_q <= i_wr_data[15:0];
      if (tx_ring_writable && (i_wr_offset == nic_pkg::TxBaseOffset)) begin
        tx_base_q    <= {i_wr_data[ADDR_WIDTH-1:5], 5'b0};
        tx_tail_q    <= '0;
        o_tx_restart <= 1'b1;
      end
      if (tx_ring_writable && (i_wr_offset == nic_pkg::TxSizeOffset)) begin
        tx_size_q    <= i_wr_data[4:0];
        tx_tail_q    <= '0;
        o_tx_restart <= 1'b1;
      end
      if (wr && (i_wr_offset == nic_pkg::TxTailOffset)) tx_tail_q <= i_wr_data[15:0];

      // Counters.
      if (rx_clean) begin
        cnt_q[nic_pkg::CntRxFrames] <= cnt_q[nic_pkg::CntRxFrames] + 64'd1;
        cnt_q[nic_pkg::CntRxBytes]  <= cnt_q[nic_pkg::CntRxBytes] + 64'(i_rx_complete_bytes);
      end
      if (i_rx_filtered) cnt_q[nic_pkg::CntRxFiltered] <= cnt_q[nic_pkg::CntRxFiltered] + 64'd1;
      if (rx_trunc) cnt_q[nic_pkg::CntRxTruncated] <= cnt_q[nic_pkg::CntRxTruncated] + 64'd1;
      if (rx_err) cnt_q[nic_pkg::CntRxDescErr] <= cnt_q[nic_pkg::CntRxDescErr] + 64'd1;
      if (rx_abort) cnt_q[nic_pkg::CntRxAborted] <= cnt_q[nic_pkg::CntRxAborted] + 64'd1;
      if (tx_clean) begin
        cnt_q[nic_pkg::CntTxFrames] <= cnt_q[nic_pkg::CntTxFrames] + 64'd1;
        cnt_q[nic_pkg::CntTxBytes]  <= cnt_q[nic_pkg::CntTxBytes] + 64'(i_tx_complete_bytes);
      end
      if (tx_err) cnt_q[nic_pkg::CntTxDescErr] <= cnt_q[nic_pkg::CntTxDescErr] + 64'd1;
      if (tx_abort) cnt_q[nic_pkg::CntTxAborted] <= cnt_q[nic_pkg::CntTxAborted] + 64'd1;
    end
  end

  // ---- reads ---------------------------------------------------------------------------
  logic [31:0] status_word, link_word;
  assign status_word = {
    24'b0,
    tx_cfg_err_q,
    rx_cfg_err_q,
    i_tx_ready,
    i_rx_ready,
    i_rx_fifo_empty,
    reset_busy,
    i_tx_idle,
    i_rx_idle
  };
  assign link_word = {23'b0, carrier, i_link};

  function automatic logic [31:0] reg_word(input logic [11:0] off);
    case (off)
      nic_pkg::IdOffset:        reg_word = nic_pkg::IdValue;
      nic_pkg::CtrlOffset:      reg_word = {23'b0, reset_busy, 5'b0, promisc_q, tx_en_q, rx_en_q};
      nic_pkg::StatusOffset:    reg_word = status_word;
      nic_pkg::MacLoOffset:     reg_word = mac_q[31:0];
      nic_pkg::MacHiOffset:     reg_word = {16'b0, mac_q[47:32]};
      nic_pkg::RxBaseOffset:    reg_word = rx_base_q;
      nic_pkg::RxSizeOffset:    reg_word = {27'b0, rx_size_q};
      nic_pkg::RxTailOffset:    reg_word = {16'b0, rx_tail_q};
      nic_pkg::RxHeadOffset:    reg_word = {16'b0, i_rx_head};
      nic_pkg::TxBaseOffset:    reg_word = tx_base_q;
      nic_pkg::TxSizeOffset:    reg_word = {27'b0, tx_size_q};
      nic_pkg::TxTailOffset:    reg_word = {16'b0, tx_tail_q};
      nic_pkg::TxHeadOffset:    reg_word = {16'b0, i_tx_head};
      nic_pkg::IrqStatusOffset: reg_word = i_irq_status;
      nic_pkg::IrqMaskOffset:   reg_word = i_irq_mask;
      nic_pkg::RxItrOffset:     reg_word = i_rx_itr;
      nic_pkg::TxItrOffset:     reg_word = i_tx_itr;
      nic_pkg::TickOffset:      reg_word = i_tick;
      nic_pkg::LinkOffset:      reg_word = link_word;
      nic_pkg::PhyCtrlOffset:   reg_word = {28'b0, phy_ctrl_q};
      nic_pkg::PhyStatusOffset: reg_word = {27'b0, i_phy_status};
      default:                  reg_word = '0;
    endcase
  endfunction

  logic [63:0] counters[nic_pkg::NumCounters];
  always_comb begin
    for (int i = 0; i < 10; i++) counters[i] = cnt_q[i];
    for (int i = 0; i < 6; i++) counters[10+i] = i_mac_totals[i];
  end

  always_comb begin
    if (i_rd_offset[11:7] == nic_pkg::CounterBaseOffset[11:7]) begin
      o_rd_pair = counters[i_rd_offset[6:3]];
    end else begin
      o_rd_pair = {reg_word({i_rd_offset[11:3], 3'b100}), reg_word({i_rd_offset[11:3], 3'b000})};
    end
  end
endmodule : nic_csr
