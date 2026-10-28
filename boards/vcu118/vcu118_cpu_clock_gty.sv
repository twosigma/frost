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

// Copyright (c) 2026 John Goodacre.

// Optional GTY CPU clock source on quad 231 in SLR2.
// The board file list selects vcu118_clock instead.
module vcu118_cpu_clock_gty #(
    parameter int unsigned CPU_CLK_DIV = 1,
    // Free-running clock cycles per millisecond.
    parameter int unsigned MS_CYCLES = 150_000,
    parameter int unsigned START_TIMEOUT_MS = 100,
    // Width of a reset-all request.
    parameter int unsigned PULSE_CYCLES = 16
) (
    input logic i_refclk,      // Quad 231 MGTREFCLK0 (IBUFDS_GTE4 O on W9/W8)
    input logic i_freerun_clk, // Free-running supervisor clock

    // Board transceiver pins for Quad 231 Channel 0 (V7/V6, Y2/Y1)
    input  logic i_rxp,
    input  logic i_rxn,
    output logic o_txp,
    output logic o_txn,

    output logic o_clk,
    output logic o_clk_div4,
    output logic o_locked
);
  localparam bit DriveCpuClocks = CPU_CLK_DIV <= 2;
  localparam int unsigned StartTimeoutCycles = START_TIMEOUT_MS * MS_CYCLES;
  localparam int unsigned TimerBits = $clog2(StartTimeoutCycles + 1);

  initial begin
    if (CPU_CLK_DIV < 1 || CPU_CLK_DIV > 4)
      $fatal(1, "vcu118_cpu_clock_gty: CPU_CLK_DIV must be 1..4");
    if (PULSE_CYCLES < 1 || PULSE_CYCLES > StartTimeoutCycles) begin
      $fatal(1, "vcu118_cpu_clock_gty: PULSE_CYCLES out of range");
    end
  end

  logic txoutclk, usrclk, tx_prgdiv_done, cpll_lock, power_good, tx_done;

  // Glitch-free clock buffer clear on free-running clock
  logic userclk_clear_q = 1'b1;
  always_ff @(posedge i_freerun_clk) userclk_clear_q <= !(tx_prgdiv_done && cpll_lock);

  if (DriveCpuClocks) begin : gen_cpu_clocks
    BUFG_GT cpu_clock_buffer (
        .I      (txoutclk),
        .CE     (1'b1),
        .CEMASK (1'b0),
        .CLR    (userclk_clear_q),
        .CLRMASK(1'b0),
        .DIV    (3'(CPU_CLK_DIV - 1)),
        .O      (o_clk)
    );
    BUFG_GT cpu_clock_div4_buffer (
        .I      (txoutclk),
        .CE     (1'b1),
        .CEMASK (1'b0),
        .CLR    (userclk_clear_q),
        .CLRMASK(1'b0),
        .DIV    (3'(4 * CPU_CLK_DIV - 1)),
        .O      (o_clk_div4)
    );
  end else begin : gen_no_cpu_clocks
    assign o_clk = 1'b0;
    assign o_clk_div4 = 1'b0;
  end

  if (CPU_CLK_DIV == 1) begin : gen_usrclk_shared
    assign usrclk = o_clk;
  end else begin : gen_usrclk_own
    BUFG_GT usrclk_buffer (
        .I      (txoutclk),
        .CE     (1'b1),
        .CEMASK (1'b0),
        .CLR    (userclk_clear_q),
        .CLRMASK(1'b0),
        .DIV    (3'd0),
        .O      (usrclk)
    );
  end

  logic userclk_inactive;
  cdc_reset_sync u_userclk_active (
      .i_clk (usrclk),
      .i_arst(userclk_clear_q),
      .o_rst (userclk_inactive)
  );

  logic reset_all_q = 1'b0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [19:0] rx_word_unused;
  logic rx_done_unused, rx_cdr_stable_unused, rxoutclk_unused, rx_pma_done_unused;
  logic tx_pma_done_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  vcu118_cpu_clock_gty_wiz u_wiz (
      .gtwiz_userclk_tx_reset_in         (userclk_clear_q),
      .gtwiz_userclk_tx_active_in        (!userclk_inactive),
      .gtwiz_userclk_rx_active_in        (!userclk_inactive),
      .gtwiz_reset_clk_freerun_in        (i_freerun_clk),
      .gtwiz_reset_all_in                (reset_all_q),
      .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_tx_datapath_in        (1'b0),
      .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_rx_datapath_in        (1'b0),
      .gtwiz_reset_rx_cdr_stable_out     (rx_cdr_stable_unused),
      .gtwiz_reset_tx_done_out           (tx_done),
      .gtwiz_reset_rx_done_out           (rx_done_unused),
      .gtwiz_userdata_tx_in              (20'd0),
      .gtwiz_userdata_rx_out             (rx_word_unused),
      .drpclk_in                         (i_freerun_clk),
      .gtrefclk0_in                      (i_refclk),
      .gtyrxn_in                         (i_rxn),
      .gtyrxp_in                         (i_rxp),
      .rxusrclk_in                       (usrclk),
      .rxusrclk2_in                      (usrclk),
      .txelecidle_in                     (1'b1),
      .txusrclk_in                       (usrclk),
      .txusrclk2_in                      (usrclk),
      .cplllock_out                      (cpll_lock),
      .gtpowergood_out                   (power_good),
      .gtytxn_out                        (o_txn),
      .gtytxp_out                        (o_txp),
      .rxoutclk_out                      (rxoutclk_unused),
      .rxpmaresetdone_out                (rx_pma_done_unused),
      .txoutclk_out                      (txoutclk),
      .txpmaresetdone_out                (tx_pma_done_unused),
      .txprgdivresetdone_out             (tx_prgdiv_done)
  );

  // Supervisor state machine on free-running clock
  logic power_good_fr, tx_done_fr;
  cdc_sync #(
      .WIDTH(2)
  ) u_status_sync (
      .i_clk  (i_freerun_clk),
      .i_rst  (1'b0),
      .i_async({power_good, tx_done}),
      .o_sync ({power_good_fr, tx_done_fr})
  );

  typedef enum logic [1:0] {
    S_WAIT,
    S_RUN,
    S_RESET
  } state_e;
  state_e state_q = S_WAIT;
  logic [TimerBits-1:0] timer_q = '0;
  logic seen_low_q = 1'b0, clock_ok_q = 1'b0;

  always_ff @(posedge i_freerun_clk) begin
    unique case (state_q)
      S_WAIT: begin
        if (!tx_done_fr) seen_low_q <= 1'b1;
        if (tx_done_fr && seen_low_q) begin
          state_q    <= S_RUN;
          clock_ok_q <= 1'b1;
        end else if (!power_good_fr) begin
          timer_q <= '0;
        end else if (timer_q == TimerBits'(StartTimeoutCycles)) begin
          state_q     <= S_RESET;
          timer_q     <= '0;
          reset_all_q <= 1'b1;
        end else begin
          timer_q <= timer_q + 1'b1;
        end
      end
      S_RUN: begin
        if (!tx_done_fr) begin
          state_q     <= S_RESET;
          timer_q     <= '0;
          reset_all_q <= 1'b1;
          clock_ok_q  <= 1'b0;
        end
      end
      default: begin  // S_RESET
        seen_low_q <= 1'b0;
        if (timer_q == TimerBits'(PULSE_CYCLES - 1)) begin
          state_q     <= S_WAIT;
          timer_q     <= '0;
          reset_all_q <= 1'b0;
        end else begin
          timer_q <= timer_q + 1'b1;
        end
      end
    endcase
  end

  if (DriveCpuClocks) begin : gen_locked
    logic cpu_clock_reset;
    cdc_reset_sync u_locked_reset (
        .i_clk (o_clk),
        .i_arst(!clock_ok_q),
        .o_rst (cpu_clock_reset)
    );
    assign o_locked = !cpu_clock_reset;
  end else begin : gen_no_locked
    assign o_locked = 1'b0;
  end
endmodule : vcu118_cpu_clock_gty
