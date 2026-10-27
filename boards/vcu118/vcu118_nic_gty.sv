/*
 *    Copyright 2026 John Goodacre
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
 * vcu118_nic_gty_supervisor: transceiver supervisor for vcu118_nic_gty.
 *
 * Runs on the 150 MHz free-running clock and sequences GTY power-up, full
 * resets, RX datapath resets (for near-end PMA loopback transitions), and
 * RX PCS/datapath lock retries while providing stretched clock-OK and
 * synchronized receive signal-OK levels to the FROST 10G NIC.
 */
module vcu118_nic_gty_supervisor #(
    parameter int unsigned MS_CYCLES = 150_000,
    parameter int unsigned LOCK_RETRY_MS = 100,
    parameter int unsigned LOCK_RETRIES_PER_RX_RESET = 10,
    parameter int unsigned RESET_TIMEOUT_MS = 500,
    parameter int unsigned PULSE_CYCLES = 16
) (
    input logic i_clk,     // 150 MHz free-running
    input logic i_rx_clk,  // RX USRCLK2 (recovered)

    // Transceiver and helper levels (asynchronous to i_clk)
    input logic i_power_good,
    input logic i_pll_lock,
    input logic i_rx_pcs_done,
    input logic i_tx_done,
    input logic i_rx_done,
    input logic i_tx_active,
    input logic i_rx_active,

    // NIC core domain levels
    input logic i_block_lock,
    input logic i_phy_reset,
    input logic i_pma_loopback,

    // Toward the transceiver (free-running registers)
    output logic o_reset_all,
    output logic o_reset_rx_datapath,
    output logic o_rx_pcs_reset,
    output logic o_pma_loopback,

    // Toward the NIC
    output logic o_tx_clk_ok,
    output logic o_rx_clk_ok,
    output logic o_cdr_lock,
    output logic o_gt_reset_done,
    output logic o_rx_signal_ok
);
  localparam int unsigned DrainCycles = MS_CYCLES;
  localparam int unsigned StretchCycles = MS_CYCLES;
  localparam int unsigned LockRetryCycles = LOCK_RETRY_MS * MS_CYCLES;
  localparam int unsigned ResetTimeoutCycles = RESET_TIMEOUT_MS * MS_CYCLES;
  localparam int unsigned TimerBits = $clog2(ResetTimeoutCycles + 1);
  localparam int unsigned LockBits = $clog2(LockRetryCycles + 1);
  localparam int unsigned StretchBits = $clog2(StretchCycles + 1);
  localparam int unsigned RetryBits = $clog2(LOCK_RETRIES_PER_RX_RESET + 1);

  logic power_good, pll_lock, pcs_done, tx_done, rx_done, tx_active, rx_active;
  logic block_lock, phy_reset, loop_req;
  cdc_sync #(
      .WIDTH(3)
  ) u_gt_sync (
      .i_clk  (i_clk),
      .i_rst  (1'b0),
      .i_async({i_power_good, i_pll_lock, i_rx_pcs_done}),
      .o_sync ({power_good, pll_lock, pcs_done})
  );
  cdc_sync #(
      .WIDTH(2)
  ) u_tx_sync (
      .i_clk  (i_clk),
      .i_rst  (1'b0),
      .i_async({i_tx_done, i_tx_active}),
      .o_sync ({tx_done, tx_active})
  );
  cdc_sync #(
      .WIDTH(2)
  ) u_rx_sync (
      .i_clk  (i_clk),
      .i_rst  (1'b0),
      .i_async({i_rx_done, i_rx_active}),
      .o_sync ({rx_done, rx_active})
  );
  cdc_sync #(
      .WIDTH(3)
  ) u_core_sync (
      .i_clk  (i_clk),
      .i_rst  (1'b0),
      .i_async({i_block_lock, i_phy_reset, i_pma_loopback}),
      .o_sync ({block_lock, phy_reset, loop_req})
  );

  typedef enum logic [2:0] {
    S_POWERUP = 3'd0,
    S_WAIT    = 3'd1,
    S_RUN     = 3'd2,
    S_DRAIN   = 3'd3,
    S_SETTLE  = 3'd4,
    S_ASSERT  = 3'd5
  } state_e;
  typedef enum logic [1:0] {
    A_ALL = 2'd0,
    A_RX  = 2'd1,
    A_PCS = 2'd2
  } action_e;

  state_e state_q = S_POWERUP, state_d;
  action_e act_q = A_ALL, act_d;
  logic [TimerBits-1:0] timer_q = '0, timer_d;
  logic [LockBits-1:0] lock_timer_q = '0, lock_timer_d;
  logic [RetryBits-1:0] retries_q = '0, retries_d;
  logic loop_q = 1'b0, loop_d;
  logic seen_tx_low_q = 1'b0, seen_rx_low_q = 1'b0, seen_pcs_low_q = 1'b0;
  logic clear_seen;

  logic fault, unexpected, loop_change, lock_due, complete;
  assign fault = !pll_lock || !tx_done || !rx_done;
  assign unexpected = act_q != A_ALL && (!pll_lock || !tx_done || (act_q == A_PCS && !rx_done));
  assign loop_change = loop_req != loop_q;
  assign lock_due = lock_timer_q == LockBits'(LockRetryCycles - 1);
  always_comb begin
    unique case (act_q)
      A_ALL: complete = seen_tx_low_q && seen_rx_low_q && tx_done && rx_done;
      A_RX: complete = seen_rx_low_q && tx_done && rx_done;
      default:
      complete = (seen_pcs_low_q || (timer_q >= TimerBits'(MS_CYCLES))) &&
          pcs_done && tx_done && rx_done;
    endcase
  end

  always_comb begin
    state_d = state_q;
    act_d = act_q;
    timer_d = (timer_q == TimerBits'(ResetTimeoutCycles)) ? timer_q : timer_q + 1'b1;
    lock_timer_d = '0;
    retries_d = retries_q;
    loop_d = loop_q;
    clear_seen = 1'b0;
    unique case (state_q)
      S_POWERUP: begin
        act_d = A_ALL;
        timer_d = '0;
        clear_seen = 1'b1;
        if (power_good) state_d = S_WAIT;
      end
      S_WAIT: begin
        if (phy_reset) begin
          state_d = S_DRAIN;
          act_d   = A_ALL;
          timer_d = '0;
        end else if (complete) begin
          timer_d = '0;
          if (loop_change) begin
            state_d = S_DRAIN;
            act_d   = A_RX;
          end else begin
            state_d = S_RUN;
          end
        end else if (unexpected || timer_q == TimerBits'(ResetTimeoutCycles)) begin
          state_d = S_DRAIN;
          act_d   = A_ALL;
          timer_d = '0;
        end
      end
      S_RUN: begin
        timer_d = '0;
        if (!block_lock && rx_done && !lock_due) lock_timer_d = lock_timer_q + 1'b1;
        if (phy_reset || fault) begin
          state_d = S_DRAIN;
          act_d   = A_ALL;
        end else if (loop_change) begin
          state_d = S_DRAIN;
          act_d   = A_RX;
        end else if (lock_due) begin
          state_d = S_DRAIN;
          if (retries_q == RetryBits'(LOCK_RETRIES_PER_RX_RESET - 1)) begin
            act_d = A_RX;
          end else begin
            act_d = A_PCS;
            retries_d = retries_q + 1'b1;
          end
        end
      end
      S_DRAIN: begin
        if (act_q != A_ALL && phy_reset) begin
          act_d   = A_ALL;
          timer_d = '0;
        end else if (act_q == A_PCS && loop_change) begin
          act_d   = A_RX;
          timer_d = '0;
        end else if (timer_q == TimerBits'(DrainCycles - 1)) begin
          timer_d = '0;
          unique case (act_q)
            A_ALL: begin
              if (!power_good) begin
                state_d = S_POWERUP;
              end else begin
                state_d = S_ASSERT;
                loop_d = loop_req;
                clear_seen = 1'b1;
              end
            end
            A_RX: begin
              state_d = S_SETTLE;
              loop_d  = loop_req;
            end
            default: begin
              state_d = S_ASSERT;
              clear_seen = 1'b1;
            end
          endcase
        end
      end
      S_SETTLE: begin
        if (phy_reset) begin
          state_d = S_DRAIN;
          act_d   = A_ALL;
          timer_d = '0;
        end else if (timer_q == TimerBits'(PULSE_CYCLES - 1)) begin
          state_d = S_ASSERT;
          timer_d = '0;
          clear_seen = 1'b1;
        end
      end
      S_ASSERT: begin
        if (act_q == A_ALL) begin
          loop_d = loop_req;
          if (timer_q >= TimerBits'(PULSE_CYCLES - 1) && !phy_reset && power_good) begin
            state_d = S_WAIT;
            timer_d = '0;
          end
        end else if (timer_q == TimerBits'(PULSE_CYCLES - 1)) begin
          state_d = S_WAIT;
          timer_d = '0;
        end
      end
      default: begin
        state_d = S_POWERUP;
        act_d   = A_ALL;
        timer_d = '0;
      end
    endcase
    if (block_lock || state_q == S_POWERUP || (state_q == S_ASSERT && act_q != A_PCS)) begin
      retries_d = '0;
    end
  end

  logic sig_permit_q = 1'b0, tx_permit_q = 1'b0, rx_permit_q = 1'b0;
  logic stopping_tx, stopping_rx;
  assign stopping_tx = (state_d == S_POWERUP) || (act_d == A_ALL && state_d != S_RUN);
  assign stopping_rx = (state_d == S_POWERUP) ||
      ((act_d == A_ALL || act_d == A_RX) && state_d != S_RUN);

  always_ff @(posedge i_clk) begin
    state_q <= state_d;
    act_q <= act_d;
    timer_q <= timer_d;
    lock_timer_q <= lock_timer_d;
    retries_q <= retries_d;
    loop_q <= loop_d;
    if (clear_seen) begin
      seen_tx_low_q  <= 1'b0;
      seen_rx_low_q  <= 1'b0;
      seen_pcs_low_q <= 1'b0;
    end else if (state_q == S_WAIT || state_q == S_ASSERT) begin
      if (!tx_done) seen_tx_low_q <= 1'b1;
      if (!rx_done && (act_q != A_ALL || (seen_tx_low_q && tx_done))) seen_rx_low_q <= 1'b1;
      if (!pcs_done) seen_pcs_low_q <= 1'b1;
    end
    sig_permit_q <= state_d == S_RUN;
    tx_permit_q  <= !stopping_tx;
    rx_permit_q  <= !stopping_rx;
  end

  logic reset_all_q = 1'b0, reset_rx_datapath_q = 1'b0, rx_pcs_reset_q = 1'b0;
  always_ff @(posedge i_clk) begin
    reset_all_q <= state_d == S_ASSERT && act_d == A_ALL;
    reset_rx_datapath_q <= state_d == S_ASSERT && act_d == A_RX;
    rx_pcs_reset_q <= state_d == S_ASSERT && act_d == A_PCS;
  end
  assign o_reset_all = reset_all_q;
  assign o_reset_rx_datapath = reset_rx_datapath_q;
  assign o_rx_pcs_reset = rx_pcs_reset_q;
  assign o_pma_loopback = loop_q;

  logic [StretchBits-1:0] tx_stretch_q = StretchBits'(StretchCycles);
  logic [StretchBits-1:0] rx_stretch_q = StretchBits'(StretchCycles);
  logic tx_clk_ok_q = 1'b0, rx_clk_ok_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (!(tx_active && tx_permit_q)) begin
      tx_stretch_q <= StretchBits'(StretchCycles);
      tx_clk_ok_q  <= 1'b0;
    end else if (tx_stretch_q != '0) begin
      tx_stretch_q <= tx_stretch_q - 1'b1;
    end else begin
      tx_clk_ok_q <= 1'b1;
    end
    if (!(rx_active && rx_permit_q)) begin
      rx_stretch_q <= StretchBits'(StretchCycles);
      rx_clk_ok_q  <= 1'b0;
    end else if (rx_stretch_q != '0) begin
      rx_stretch_q <= rx_stretch_q - 1'b1;
    end else begin
      rx_clk_ok_q <= 1'b1;
    end
  end
  assign o_tx_clk_ok = tx_clk_ok_q;
  assign o_rx_clk_ok = rx_clk_ok_q;

  logic cdr_lock_q = 1'b0, gt_reset_done_q = 1'b0;
  always_ff @(posedge i_clk) begin
    cdr_lock_q <= rx_done;
    gt_reset_done_q <= tx_done && rx_done;
  end
  assign o_cdr_lock = cdr_lock_q;
  assign o_gt_reset_done = gt_reset_done_q;

  logic sig_permit_rx;
  cdc_sync u_permit_sync (
      .i_clk  (i_rx_clk),
      .i_rst  (1'b0),
      .i_async(sig_permit_q),
      .o_sync (sig_permit_rx)
  );
  logic rx_signal_ok_q = 1'b0;
  always_ff @(posedge i_rx_clk) rx_signal_ok_q <= sig_permit_rx && i_rx_done;
  assign o_rx_signal_ok = rx_signal_ok_q;
endmodule : vcu118_nic_gty_supervisor

/*
 * vcu118_nic_gty: VCU118 QSFP1 Lane 0 (Quad 231, GTYE4_CHANNEL_X1Y48) GTY
 * transceiver wrapper for FROST's 10GBASE-R NIC (hw/rtl/net10g).
 *
 * Clocked by MGTREFCLK0_231 (W9/W8, 156.25 MHz Si570 U38). Supports both
 * physical QSFP28 optical/DAC cabling on Lane 0 (TX V7/V6, RX Y2/Y1) and
 * internal near-end PMA loopback (3'b010) for self-contained board verification.
 */
module vcu118_nic_gty (
    input logic i_freerun_clk,  // 150 MHz free-running clock
    input logic i_refclk_p,     // Quad 231 MGTREFCLK0_P (W9, 156.25 MHz)
    input logic i_refclk_n,     // Quad 231 MGTREFCLK0_N (W8, 156.25 MHz)

    // QSFP1 Lane 0 serial pins (Quad 231, X1Y48)
    input  logic i_rxp,
    input  logic i_rxn,
    output logic o_txp,
    output logic o_txn,

    // NIC PHY-side ports (frost.sv)
    output logic        o_tx_clk,
    output logic        o_rx_clk,
    output logic        o_tx_clk_ok,
    output logic        o_rx_clk_ok,
    input  logic [63:0] i_tx_raw_data,
    input  logic        i_tx_raw_valid,
    output logic [63:0] o_rx_raw_data,
    output logic        o_rx_raw_valid,
    output logic        o_rx_signal_ok,
    input  logic [ 3:1] i_phy_ctrl,
    output logic [ 4:0] o_phy_status,
    input  logic        i_rx_block_lock
);
  logic gty_refclk;
  IBUFDS_GTE4 #(
      .REFCLK_EN_TX_PATH (1'b0),
      .REFCLK_HROW_CK_SEL(2'b00),
      .REFCLK_ICNTL_RX   (2'b00)
  ) u_gty_refclk_buf (
      .I    (i_refclk_p),
      .IB   (i_refclk_n),
      .CEB  (1'b0),
      .O    (gty_refclk),
      .ODIV2()
  );

  logic tx_usrclk2, rx_usrclk2, tx_active, rx_active, tx_done, rx_done;
  logic power_good, pll_lock, rx_pcs_done, tx_prgdiv_done, rx_pma_done;
  logic reset_all, reset_rx_datapath, rx_pcs_reset, pma_loopback;
  logic [63:0] tx_word_q, rx_word;

  vcu118_nic_gty_wiz u_wiz (
      .gtwiz_userclk_tx_reset_in         (!tx_prgdiv_done),
      .gtwiz_userclk_tx_srcclk_out       (),
      .gtwiz_userclk_tx_usrclk_out       (),
      .gtwiz_userclk_tx_usrclk2_out      (tx_usrclk2),
      .gtwiz_userclk_tx_active_out       (tx_active),
      .gtwiz_userclk_rx_reset_in         (!rx_pma_done),
      .gtwiz_userclk_rx_srcclk_out       (),
      .gtwiz_userclk_rx_usrclk_out       (),
      .gtwiz_userclk_rx_usrclk2_out      (rx_usrclk2),
      .gtwiz_userclk_rx_active_out       (rx_active),
      .gtwiz_reset_clk_freerun_in        (i_freerun_clk),
      .gtwiz_reset_all_in                (reset_all),
      .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_tx_datapath_in        (1'b0),
      .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_rx_datapath_in        (reset_rx_datapath),
      .gtwiz_reset_rx_cdr_stable_out     (),
      .gtwiz_reset_tx_done_out           (tx_done),
      .gtwiz_reset_rx_done_out           (rx_done),
      .gtwiz_userdata_tx_in              (tx_word_q),
      .gtwiz_userdata_rx_out             (rx_word),
      .gtrefclk00_in                     (gty_refclk),
      .qpll0lock_out                     (pll_lock),
      .qpll0outclk_out                   (),
      .qpll0outrefclk_out                (),
      .gtyrxn_in                         (i_rxn),
      .gtyrxp_in                         (i_rxp),
      .loopback_in                       ({1'b0, pma_loopback, 1'b0}),
      .rxpcsreset_in                     (rx_pcs_reset),
      .rxpolarity_in                     (1'b0),
      .txpolarity_in                     (1'b0),
      .gtpowergood_out                   (power_good),
      .gtytxn_out                        (o_txn),
      .gtytxp_out                        (o_txp),
      .rxpmaresetdone_out                (rx_pma_done),
      .rxresetdone_out                   (rx_pcs_done),
      .txpmaresetdone_out                (),
      .txprgdivresetdone_out             (tx_prgdiv_done)
  );

  logic cdr_lock, gt_reset_done;
  vcu118_nic_gty_supervisor u_supervisor (
      .i_clk              (i_freerun_clk),
      .i_rx_clk           (rx_usrclk2),
      .i_power_good       (power_good),
      .i_pll_lock         (pll_lock),
      .i_rx_pcs_done      (rx_pcs_done),
      .i_tx_done          (tx_done),
      .i_rx_done          (rx_done),
      .i_tx_active        (tx_active),
      .i_rx_active        (rx_active),
      .i_block_lock       (i_rx_block_lock),
      .i_phy_reset        (i_phy_ctrl[nic_pkg::PhyCtrlBitPhyReset]),
      .i_pma_loopback     (i_phy_ctrl[nic_pkg::PhyCtrlBitPmaLoopback]),
      .o_reset_all        (reset_all),
      .o_reset_rx_datapath(reset_rx_datapath),
      .o_rx_pcs_reset     (rx_pcs_reset),
      .o_pma_loopback     (pma_loopback),
      .o_tx_clk_ok        (o_tx_clk_ok),
      .o_rx_clk_ok        (o_rx_clk_ok),
      .o_cdr_lock         (cdr_lock),
      .o_gt_reset_done    (gt_reset_done),
      .o_rx_signal_ok     (o_rx_signal_ok)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic tx_raw_valid_unused;
  logic tx_disable_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign tx_raw_valid_unused = i_tx_raw_valid;
  assign tx_disable_unused   = i_phy_ctrl[nic_pkg::PhyCtrlBitTxDisable];
  always_ff @(posedge tx_usrclk2) tx_word_q <= i_tx_raw_data;
  logic [63:0] rx_word_q;
  always_ff @(posedge rx_usrclk2) rx_word_q <= rx_word;

  assign o_tx_clk = tx_usrclk2;
  assign o_rx_clk = rx_usrclk2;
  assign o_rx_raw_data = rx_word_q;
  assign o_rx_raw_valid = 1'b1;

  always_comb begin
    o_phy_status = '0;
    o_phy_status[nic_pkg::PhyStatusBitClkShared] = 1'b0;
    o_phy_status[nic_pkg::PhyStatusBitGtResetDone] = gt_reset_done;
    o_phy_status[nic_pkg::PhyStatusBitCdrLock] = cdr_lock;
    o_phy_status[nic_pkg::PhyStatusBitModulePresent] = 1'b1;
    o_phy_status[nic_pkg::PhyStatusBitLos] = 1'b0;
  end
endmodule : vcu118_nic_gty

