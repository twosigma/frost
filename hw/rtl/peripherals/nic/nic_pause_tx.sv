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
 * nic_pause_tx: the transmit half of IEEE 802.3x flow control, in the TX MAC clock domain,
 * between the TX FIFO and the transmit MAC.
 *
 * Honouring received pause. A pause event from the receive half (i_pause_tog toggling, with
 * i_pause_quanta) loads a timer with pause_time quanta of 512 bit times: QTICKS = 8 words at
 * 10GBASE-R, 64 byte times on GMII (i_tick marks one byte time at 10, 100 or 1000 Mb/s). Quanta 0
 * clears it. While the timer runs, no new frame leaves the TX FIFO; a frame already started
 * finishes (and the MAC may still hold up to two complete frames it took earlier). The timer only
 * runs while i_rx_en (honour pause) is set. Frames generated here are exempt.
 *
 * Generating pause. i_want_pause (a level from the receive half) while i_tx_en is set sends one
 * pause request frame (pause_time = i_interval_cfg) and then repeats it every pause_time / 2 while the level
 * stays high, so the peer is held without gaps; when the level falls (or i_tx_en clears) after a
 * pause request, one release frame (pause_time 0) follows. Pause frames go out between frames, never inside
 * one. Nothing is sent without i_tx_en, except the release frame that ends a pause already sent.
 *
 * The MAC side is registered (a one-entry pipeline stage), so the multiplexing between FIFO and
 * pause frames stays out of the MAC's input timing.
 *
 * o_paused is high for every MAC clock the timer runs (the tx_paused_cycles counter's event);
 * o_tx_pause_ev pulses when a pause frame's last beat is accepted.
 */
module nic_pause_tx #(
    // 1 = GMII (64 byte times per quantum), 0 = 10GBASE-R (8 words per quantum)
    parameter bit GMII_MODE = 1'b0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_tick,

    input logic [47:0] i_mac,
    input logic        i_rx_en,
    input logic        i_tx_en,
    input logic [15:0] i_interval_cfg,
    input logic        i_want_pause,
    input logic        i_pause_tog,
    input logic [15:0] i_pause_interval,

    // TX FIFO side: {abort, csum[14:0], code[3:0], data[63:0]}.
    input  logic [83:0] i_f_word,
    input  logic        i_f_valid,
    output logic        o_f_ready,
    // MAC side.
    output logic [83:0] o_t_word,
    output logic        o_t_valid,
    input  logic        i_t_ready,

    output logic o_paused,
    output logic o_tx_pause_ev
);
  localparam int unsigned QShift = GMII_MODE ? 6 : 3;
  localparam int unsigned TimerBits = 16 + QShift;

  // ---- received pause: the timer -----------------------------------------------------------
  logic tog_q, ev1_q, ev2_q, ev3_q;
  logic [TimerBits-1:0] timer_q;
  logic paused;
  assign paused   = (timer_q != '0);
  assign o_paused = paused;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      // The RX domain may survive a TX-only reset. Its last event is the new baseline,
      // so an old odd toggle must not restart an already expired pause timer.
      tog_q   <= i_pause_tog;
      ev1_q   <= 1'b0;
      ev2_q   <= 1'b0;
      ev3_q   <= 1'b0;
      timer_q <= '0;
    end else begin
      tog_q <= i_pause_tog;
      ev1_q <= (i_pause_tog != tog_q);
      ev2_q <= ev1_q;
      ev3_q <= ev2_q;
      if (!i_rx_en) timer_q <= '0;
      // The interval bus has settled two cycles after the toggle is seen.
      else if (ev3_q) timer_q <= TimerBits'(i_pause_interval) << QShift;
      else if (paused && i_tick) timer_q <= timer_q - 1'b1;
    end
  end

  // ---- generated pause --------------------------------------------------------------------
  typedef enum logic [1:0] {
    G_IDLE,
    G_B0,
    G_B1,
    G_B2
  } gen_e;
  gen_e gen_q;
  logic pause_sent_q, kind_release_q;
  logic [TimerBits-2:0] refresh_q;
  logic [15:0] cfg_interval_q, interval_q;
  logic f_at_start_q;

  // The configured pause interval crosses as a plain bus: use it once two consecutive samples agree.
  always_ff @(posedge i_clk) begin
    cfg_interval_q <= i_interval_cfg;
    if (i_interval_cfg == cfg_interval_q && i_interval_cfg != '0) interval_q <= i_interval_cfg;
    if (i_rst) interval_q <= 16'hFFFF;
  end

  logic want, refresh_zero, pend_pause, pend_release, pending;
  assign want         = i_want_pause && i_tx_en;
  assign refresh_zero = (refresh_q == '0);
  assign pend_pause   = want && (!pause_sent_q || refresh_zero);
  assign pend_release = pause_sent_q && !want;
  assign pending      = pend_pause || pend_release;

  logic sel_gen, blk, up_ready, m_valid, out_valid_q;
  logic [$bits(o_t_word)-1:0] m_word, out_word_q;
  assign sel_gen   = (gen_q != G_IDLE);
  // A frame is held back at its first beat while paused or while a pause frame is due.
  assign blk       = f_at_start_q && (paused || pending);
  // The pipeline stage takes a beat when it is empty or the MAC takes its beat.
  assign up_ready  = !out_valid_q || i_t_ready;
  assign o_f_ready = !sel_gen && !blk && up_ready;

  logic [15:0] interval_sent;
  assign interval_sent = kind_release_q ? 16'h0 : interval_q;
  always_comb begin
    m_word  = i_f_word;
    m_valid = i_f_valid && !blk && !sel_gen;
    unique case (gen_q)
      G_B0: begin
        m_word  = {16'b0, 4'h7, i_mac[15:8], i_mac[7:0], 8'h01, 8'h00, 8'h00, 8'hC2, 8'h80, 8'h01};
        m_valid = 1'b1;
      end
      G_B1: begin
        m_word = {
          16'b0,
          4'h7,
          8'h01,
          8'h00,
          8'h08,
          8'h88,
          i_mac[47:40],
          i_mac[39:32],
          i_mac[31:24],
          i_mac[23:16]
        };
        m_valid = 1'b1;
      end
      G_B2: begin
        // Two bytes of pause_time, high byte first; the MAC pads the frame to 60 bytes.
        m_word  = {16'b0, 4'h9, 48'b0, interval_sent[7:0], interval_sent[15:8]};
        m_valid = 1'b1;
      end
      default: begin
      end
    endcase
    // The checksum request fields are don't-cares for a pause frame (its enable bit is 0), so
    // they bypass the multiplexer and stay off the MAC's checksum timing paths.
    m_word[82:69] = i_f_word[82:69];
  end

  assign o_t_valid = out_valid_q;
  assign o_t_word  = out_word_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      out_valid_q <= 1'b0;
    end else if (up_ready) begin
      out_valid_q <= m_valid;
      out_word_q  <= m_word;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      gen_q          <= G_IDLE;
      pause_sent_q   <= 1'b0;
      kind_release_q <= 1'b0;
      refresh_q      <= '0;
      f_at_start_q   <= 1'b1;
      o_tx_pause_ev  <= 1'b0;
    end else begin
      o_tx_pause_ev <= 1'b0;
      if (refresh_q != '0 && i_tick) refresh_q <= refresh_q - 1'b1;
      if (i_f_valid && o_f_ready) f_at_start_q <= i_f_word[67];
      unique case (gen_q)
        G_IDLE: begin
          if (f_at_start_q && pending) begin
            kind_release_q <= pend_release && !pend_pause;
            gen_q          <= G_B0;
          end
        end
        G_B0:    if (up_ready) gen_q <= G_B1;
        G_B1:    if (up_ready) gen_q <= G_B2;
        G_B2: begin
          if (up_ready) begin
            gen_q         <= G_IDLE;
            o_tx_pause_ev <= 1'b1;
            if (kind_release_q) begin
              pause_sent_q <= 1'b0;
            end else begin
              pause_sent_q <= 1'b1;
              // Refresh at half the pause time
              refresh_q    <= (TimerBits - 1)'(interval_q) << (QShift - 1);
            end
          end
        end
        default: gen_q <= G_IDLE;
      endcase
    end
  end
endmodule : nic_pause_tx
