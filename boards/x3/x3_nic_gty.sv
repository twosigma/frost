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
 * x3_nic_gty_supervisor: the transceiver supervisor of x3_nic_gty, without
 * vendor primitives.
 *
 * Everything but the receive signal-OK register runs on the free-running
 * clock. Every input is a level from another domain or from the transceiver
 * and is synchronized here: the QPLL0 lock, power good and raw RX reset done
 * (transceiver outputs), the reset helper's TX and RX reset done and the user
 * clocking helpers' active flags (their USRCLK2 domains), the PCS block lock
 * and the PHY_RESET and PMA_LOOPBACK bits (the NIC's core domain).
 *
 * The states:
 * - POWERUP: nothing is asserted, so the reset helper runs its own start-up
 *   sequence once the transceiver reports power good. Then WAIT for that
 *   sequence.
 * - RUN: the only state with receive signal allowed. A PHY_RESET, a PLL lock
 *   loss or a TX or RX reset done that drops unasked starts a full reset; a
 *   PMA_LOOPBACK change starts an RX datapath reset (a loopback change);
 *   block lock absent for LOCK_RETRY_MS starts a lock retry, and again every
 *   LOCK_RETRY_MS while it stays absent. A lock retry is an RX PCS reset,
 *   except that every LOCK_RETRIES_PER_RX_RESET-th retry in a row is an RX
 *   datapath reset: UG578 Table 2-34 asks for GTRXRESET after RXP/RXN are
 *   connected or the remote end powers up, which a PCS reset does not do,
 *   so a link partner that arrives after start-up may otherwise never lock.
 *   Block lock, or any reset other than the PCS reset, restarts the count.
 * - DRAIN: the receive signal permission and the clock-OK of every direction
 *   the coming reset stops are withdrawn, and held for one millisecond while
 *   the clocks still run. The NIC's MAC receive domain registers signal-OK
 *   low (its status register has no reset and would otherwise keep a stale
 *   carrier through a stopped clock), and its core side starts a new reset
 *   generation for each affected domain.
 * - SETTLE (RX datapath reset only): LOOPBACK takes the requested value
 *   (3'b010 near-end PMA or 3'b000; a lock retry keeps the current one unless
 *   PMA_LOOPBACK changed during its drain), then a short settle before the
 *   reset.
 * - ASSERT: the action's reset input is held: reset_all (both directions,
 *   held for as long as PHY_RESET is set and until power good), the RX
 *   datapath reset (the helper input that asserts GTRXRESET, which UG578
 *   p.83 requires after entering or leaving near-end PMA loopback), or
 *   RXPCSRESET (the PCS and the RX elastic buffer, leaving the PMA and the
 *   recovered clock running).
 * - WAIT: completion is the affected reset-done levels seen low after the
 *   request and high again. In a full reset RX counts as low only once TX is
 *   done again, since its RX phase follows the TX phase; for the PCS reset
 *   the level is the raw RX reset done, or one millisecond passes when its
 *   low phase is too short to see. A wait that does not complete within
 *   RESET_TIMEOUT_MS becomes a full reset, and so does an RX-only action
 *   during which the PLL lock or a reset done it does not touch drops. A
 *   PHY_RESET pre-empts the wait; a loopback change waits for it and then
 *   runs without signal being allowed in between.
 *
 * Clock-OK: a direction's user clocking helper is active and no reset of that
 * direction is draining, asserted or awaited. Every low interval is stretched
 * by one millisecond so the NIC's core-domain synchronizers see it. Signal-OK
 * (receive clock domain): the permission from RUN, synchronized, and the
 * reset helper's RX reset done. The PCS reset leaves the receive clock-OK up,
 * so it does not cost the NIC its RX READY; the RX datapath reset does, so
 * while block lock stays absent (no link partner, say) the NIC loses RX READY
 * once every LOCK_RETRIES_PER_RX_RESET lock retries, about once a second.
 */
module x3_nic_gty_supervisor #(
    // Free-running clock cycles per millisecond (150 MHz).
    parameter int unsigned MS_CYCLES = 150_000,
    parameter int unsigned LOCK_RETRY_MS = 100,
    // One lock retry in this many in a row is an RX datapath reset.
    parameter int unsigned LOCK_RETRIES_PER_RX_RESET = 10,
    parameter int unsigned RESET_TIMEOUT_MS = 500,
    // Width of a reset request pulse and of the loopback settle interval.
    parameter int unsigned PULSE_CYCLES = 16
) (
    input logic i_clk,    // free-running
    input logic i_rx_clk, // RX USRCLK2 (recovered)

    // Transceiver and helper levels (asynchronous to i_clk).
    input logic i_power_good,
    input logic i_pll_lock,
    input logic i_rx_pcs_done,  // raw RXRESETDONE
    input logic i_tx_done,      // reset helper, TX USRCLK2 domain
    input logic i_rx_done,      // reset helper, RX USRCLK2 domain
    input logic i_tx_active,    // user clocking helpers, their USRCLK2 domains
    input logic i_rx_active,

    // NIC core domain levels.
    input logic i_block_lock,
    input logic i_phy_reset,
    input logic i_pma_loopback,

    // Toward the transceiver (free-running registers).
    output logic o_reset_all,
    output logic o_reset_rx_datapath,
    output logic o_rx_pcs_reset,
    output logic o_pma_loopback,

    // Toward the NIC.
    output logic o_tx_clk_ok,      // free-running registers
    output logic o_rx_clk_ok,
    output logic o_cdr_lock,
    output logic o_gt_reset_done,
    output logic o_rx_signal_ok    // i_rx_clk register
);
  localparam int unsigned DrainCycles = MS_CYCLES;
  localparam int unsigned StretchCycles = MS_CYCLES;
  localparam int unsigned LockRetryCycles = LOCK_RETRY_MS * MS_CYCLES;
  localparam int unsigned ResetTimeoutCycles = RESET_TIMEOUT_MS * MS_CYCLES;
  localparam int unsigned TimerBits = $clog2(ResetTimeoutCycles + 1);
  localparam int unsigned LockBits = $clog2(LockRetryCycles + 1);
  localparam int unsigned StretchBits = $clog2(StretchCycles + 1);
  localparam int unsigned RetryBits = $clog2(LOCK_RETRIES_PER_RX_RESET + 1);

  initial begin
    if (MS_CYCLES < 2 * PULSE_CYCLES) $fatal(1, "x3_nic_gty_supervisor: MS_CYCLES too small");
    if (RESET_TIMEOUT_MS < 2) $fatal(1, "x3_nic_gty_supervisor: RESET_TIMEOUT_MS too small");
    if (LOCK_RETRIES_PER_RX_RESET < 1) begin
      $fatal(1, "x3_nic_gty_supervisor: LOCK_RETRIES_PER_RX_RESET too small");
    end
  end

  // ---- synchronizers into the free-running domain ------------------------------------------
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

  // ---- the sequencer ------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_POWERUP = 3'd0,
    S_WAIT    = 3'd1,
    S_RUN     = 3'd2,
    S_DRAIN   = 3'd3,
    S_SETTLE  = 3'd4,
    S_ASSERT  = 3'd5
  } state_e;
  typedef enum logic [1:0] {
    A_ALL = 2'd0,  // reset_all
    A_RX  = 2'd1,  // the RX datapath reset: a loopback change or a lock retry
    A_PCS = 2'd2   // RXPCSRESET: a lock retry
  } action_e;

  // The power-up values below are the configuration state; nothing resets
  // this logic afterwards.
  state_e state_q = S_POWERUP, state_d;
  action_e act_q = A_ALL, act_d;
  logic [TimerBits-1:0] timer_q = '0, timer_d;
  logic [LockBits-1:0] lock_timer_q = '0, lock_timer_d;
  logic [RetryBits-1:0] retries_q = '0, retries_d;  // lock retries in a row
  logic loop_q = 1'b0, loop_d;
  logic seen_tx_low_q = 1'b0, seen_rx_low_q = 1'b0, seen_pcs_low_q = 1'b0;
  logic clear_seen;

  logic fault, unexpected, loop_change, lock_due, complete;
  assign fault = !pll_lock || !tx_done || !rx_done;
  // While an RX-only action completes, the PLL and TX stay up (and for the
  // PCS reset, the helper's RX reset done as well).
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
          // Now both directions stop: restart the drain for the TX side.
          act_d   = A_ALL;
          timer_d = '0;
        end else if (act_q == A_PCS && loop_change) begin
          act_d   = A_RX;
          timer_d = '0;
        end else if (timer_q == TimerBits'(DrainCycles - 1)) begin
          timer_d = '0;
          unique case (act_q)
            A_ALL: begin
              // The helper must not see a reset before power good.
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
          // The full reset's RX datapath phase comes after its TX phase, so
          // a loopback change up to the release is covered by it.
          loop_d = loop_req;
          // Its release starts the sequence without the power-good wait of
          // the configuration start, so it waits for power good as well.
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
    // The lock retry count restarts on block lock and on every reset but the
    // PCS reset (in POWERUP, the helper's own start-up sequence).
    if (block_lock || state_q == S_POWERUP || (state_q == S_ASSERT && act_q != A_PCS)) begin
      retries_d = '0;
    end
  end

  // Signal and clock permissions follow the next state, so they fall on the
  // same edge that leaves RUN.
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
      // A full reset's RX phase follows its TX phase; an RX reset done that
      // an earlier RX sequence raises during the TX phase must not count.
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

  // ---- clock-OK, stretched ------------------------------------------------------------------
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

  // ---- PHY_STATUS levels ---------------------------------------------------------------------
  logic cdr_lock_q = 1'b0, gt_reset_done_q = 1'b0;
  always_ff @(posedge i_clk) begin
    cdr_lock_q <= rx_done;
    gt_reset_done_q <= tx_done && rx_done;
  end
  assign o_cdr_lock = cdr_lock_q;
  assign o_gt_reset_done = gt_reset_done_q;

  // ---- signal-OK in the receive clock domain -------------------------------------------------
  // The helper's RX reset done falls without a clock edge when its reset
  // starts, so an unrequested RX reset also clears signal-OK on the next
  // receive clock edge.
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
endmodule : x3_nic_gty_supervisor

/*
 * x3_nic_gty: the X3's GTY transceiver for the NIC, a raw 64-bit
 * 10GBASE-R PMA under the soft MAC/PCS (hw/rtl/net10g).
 *
 * The wizard core x3_nic_gty_wiz (fpga/build/x3_gty_ip.tcl) holds one channel
 * at GTYE4_CHANNEL_X0Y28 with QPLL0 from quad 231's MGTREFCLK0 (161.1328125
 * MHz), its reset controller and its TX and RX user clocking helpers. This
 * wrapper adds the refclk buffer, the free-running clock, the user clocking
 * helper resets, the supervisor above, a register on each raw data path and
 * the NIC's PHY status.
 *
 * Free-running clock: a BUFGCE_DIV halves the 300 MHz system clock input
 * (the IBUFDS output the board top also feeds its MMCM with, both in the
 * input's clock region), so the reset controller's clock runs from
 * configuration and depends neither on the MMCM nor on the transceiver.
 *
 * User clocking helper resets: each BUFG_GT pair is held clear until its
 * source's reset is done: TXPRGDIVRESETDONE for TXOUTCLK from the TX
 * programmable divider (whose reset the helper already asserts on a PLL lock
 * loss) and RXPMARESETDONE for the recovered RXOUTCLKPMA. The PLL lock is
 * deliberately not a term: an unplanned lock loss then leaves the recovered
 * clock toggling, so the NIC's receive domain still registers signal-OK low
 * when the reset helper drops RX reset done, instead of keeping a stale
 * carrier behind a stopped clock; and a short lock glitch cannot stop the
 * user clocks unseen by the synchronizers. Every reset that interrupts these
 * clocks on purpose is drained first.
 *
 * Toward the NIC: o_tx_clk and o_rx_clk are TX and RX USRCLK2 (161.13 MHz,
 * the RX one recovered from the line); clock-OK, signal-OK and PHY_STATUS
 * come from the supervisor. The raw TX word goes to TXDATA every TX clock,
 * RXDATA comes back as a raw word that is valid every RX clock; both are
 * registered once, bit 0 first on the line. PHY_STATUS: LOS 0 and
 * MODULE_PRESENT 1 (no module status reaches the FPGA on this card),
 * CDR_LOCK = RX reset done (RXCDRLOCK is reserved in UG578), GT_RESET_DONE =
 * TX and RX reset done, CLK_SHARED 0. PHY_CTRL: while PHY_RESET is set the
 * reset controller's reset-all input is held and the NIC sees both MAC clocks
 * absent and no receive signal (the transceiver itself keeps running), and
 * clearing it runs the full reset sequence;
 * PMA_LOOPBACK selects near-end PMA loopback (the line TX still transmits);
 * TX_DISABLE has no effect, since the module's transmit disable is not an
 * FPGA pin on this card and electrical idle does not turn off an optical
 * module's laser.
 */
module x3_nic_gty (
    input logic i_sysclk_300,  // the board's buffered 300 MHz system clock input

    // Board pins (quad 231).
    input  logic i_refclk_p,
    input  logic i_refclk_n,
    input  logic i_rxp,
    input  logic i_rxn,
    output logic o_txp,
    output logic o_txn,

    // The NIC's PHY-side ports (frost.sv).
    output logic        o_tx_clk,
    output logic        o_rx_clk,
    output logic        o_tx_clk_ok,
    output logic        o_rx_clk_ok,
    input  logic [63:0] i_tx_raw_data,   // o_tx_clk
    input  logic        i_tx_raw_valid,
    output logic [63:0] o_rx_raw_data,   // o_rx_clk
    output logic        o_rx_raw_valid,
    output logic        o_rx_signal_ok,  // o_rx_clk
    input  logic [ 3:1] i_phy_ctrl,      // core-clock register bits
    output logic [ 4:0] o_phy_status,    // nic_pkg PhyStatusBit* order
    input  logic        i_rx_block_lock  // core-clock register
);
  // ---- clocks ------------------------------------------------------------------------------
  logic freerun_clk, refclk;
  BUFGCE_DIV #(
      .BUFGCE_DIVIDE  (2),
      .IS_CE_INVERTED (1'b0),
      .IS_CLR_INVERTED(1'b0),
      .IS_I_INVERTED  (1'b0)
  ) freerun_clock_buffer (
      .O  (freerun_clk),
      .CE (1'b1),
      .CLR(1'b0),
      .I  (i_sysclk_300)
  );

  IBUFDS_GTE4 #(
      .REFCLK_EN_TX_PATH (1'b0),
      .REFCLK_HROW_CK_SEL(2'b00),
      .REFCLK_ICNTL_RX   (2'b00)
  ) refclk_buffer (
      .I    (i_refclk_p),
      .IB   (i_refclk_n),
      .CEB  (1'b0),
      .O    (refclk),
      .ODIV2()
  );

  // ---- the wizard core -----------------------------------------------------------------------
  logic tx_usrclk2, rx_usrclk2, tx_active, rx_active, tx_done, rx_done;
  logic power_good, pll_lock, rx_pcs_done, tx_prgdiv_done, rx_pma_done;
  logic reset_all, reset_rx_datapath, rx_pcs_reset, pma_loopback;
  logic [63:0] tx_word_q, rx_word;
  x3_nic_gty_wiz u_wiz (
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
      .gtwiz_reset_clk_freerun_in        (freerun_clk),
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
      .gtrefclk00_in                     (refclk),
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

  // ---- supervisor ----------------------------------------------------------------------------
  logic cdr_lock, gt_reset_done;
  x3_nic_gty_supervisor u_supervisor (
      .i_clk              (freerun_clk),
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

  // ---- raw data ------------------------------------------------------------------------------
  // The raw TX stream is continuous once the MAC's gearbox has started; the
  // word it presents before that (zero in reset) is sent as it is, so its
  // valid is not needed here.
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
endmodule : x3_nic_gty
