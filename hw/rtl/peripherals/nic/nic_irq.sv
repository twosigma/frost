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
 * nic_irq: the NIC's interrupt status, mask and completion moderation.
 *
 * IRQ_STATUS is sticky: bits set by events, cleared by writing 1 (W1C); a
 * set in the same cycle as a clear wins. IRQ_MASK gates the level output,
 * o_irq = |(status & mask), and has atomic IRQ_MASK_SET / IRQ_MASK_CLR
 * views so two contexts never read-modify-write it. Masking never loses an
 * event: counting, timing and latching go on while masked.
 *
 * The RX and TX bits are moderated notifications, not "unreaped descriptors
 * exist". Per direction, an acknowledgement (W1C of the bit, effective even
 * when it reads 0) starts a new interval: it clears the notification, the
 * completion count and the timer. Within an interval every completion
 * (i_rx_done / i_tx_done, one pulse per DD write response) counts,
 * saturating; the first one snapshots the direction's ITR fields and TICK
 * and starts the deadline, which never restarts on later completions. The
 * bit raises when the count reaches max (max = 0 disables the comparator)
 * or the deadline passes; delay = 0 means immediate notification on a
 * completion whatever max says, so a count threshold always carries a
 * finite deadline. A raise stops the timer; completions while the bit is
 * set belong to the same, already-notified interval; a completion in the
 * cycle of the acknowledgement belongs to the new interval. TICK = 0 counts
 * as 1. Configuration changes apply from the next interval.
 *
 * The driver's rule that makes this lossless: acknowledge BEFORE scanning
 * the rings (flushed by a status read), never after the final scan.
 *
 * RX_DROP, LINK and DESC_ERR are plain event latches (pulse in, W1C out).
 */
module nic_irq #(
    parameter logic [31:0] TICK_DEFAULT = 32'd300  // core cycles per microsecond
) (
    input logic i_clk,
    input logic i_rst,

    // Register writes: 32-bit lane writes decoded by window offset.
    input  logic        i_wr_en,
    input  logic [11:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    // Register values for the window's read mux.
    output logic [31:0] o_status,
    output logic [31:0] o_mask,
    output logic [31:0] o_rx_itr,
    output logic [31:0] o_tx_itr,
    output logic [31:0] o_tick,

    // Events (one-cycle pulses).
    input logic i_rx_done,
    input logic i_tx_done,
    input logic i_rx_drop,
    input logic i_link_change,
    input logic i_desc_err,

    output logic o_irq
);
  logic wr_status, wr_mask, wr_rx_itr, wr_tx_itr, wr_tick, wr_mask_set, wr_mask_clr;
  assign wr_status   = i_wr_en && (i_wr_offset == nic_pkg::IrqStatusOffset);
  assign wr_mask     = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskOffset);
  assign wr_rx_itr   = i_wr_en && (i_wr_offset == nic_pkg::RxItrOffset);
  assign wr_tx_itr   = i_wr_en && (i_wr_offset == nic_pkg::TxItrOffset);
  assign wr_tick     = i_wr_en && (i_wr_offset == nic_pkg::TickOffset);
  assign wr_mask_set = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskSetOffset);
  assign wr_mask_clr = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskClrOffset);

  // ---- configuration registers ----------------------------------------------
  logic [nic_pkg::IrqBits-1:0] mask_q;
  logic [31:0] rx_itr_q, tx_itr_q, tick_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mask_q   <= '0;
      rx_itr_q <= '0;
      tx_itr_q <= '0;
      tick_q   <= TICK_DEFAULT;
    end else begin
      if (wr_mask) mask_q <= i_wr_data[nic_pkg::IrqBits-1:0];
      if (wr_mask_set) mask_q <= mask_q | i_wr_data[nic_pkg::IrqBits-1:0];
      if (wr_mask_clr) mask_q <= mask_q & ~i_wr_data[nic_pkg::IrqBits-1:0];
      if (wr_rx_itr) rx_itr_q <= {8'b0, i_wr_data[23:0]};
      if (wr_tx_itr) tx_itr_q <= {8'b0, i_wr_data[23:0]};
      if (wr_tick) tick_q <= i_wr_data;
    end
  end

  // ---- per-direction moderation ---------------------------------------------
  logic [1:0] done, ack, raise;
  assign done = {i_tx_done, i_rx_done};
  assign ack = {
    wr_status && i_wr_data[nic_pkg::IrqBitTx], wr_status && i_wr_data[nic_pkg::IrqBitRx]
  };

  for (genvar d = 0; d < 2; d++) begin : gen_moderator
    logic [23:0] itr;
    assign itr = (d == 0) ? rx_itr_q[23:0] : tx_itr_q[23:0];
    logic [7:0] count_q, max_s;
    logic [15:0] delay_s, ticks_q;
    logic [31:0] tick_s, tick_cnt_q;
    logic armed_q;  // an interval has started and has not raised yet
    logic tick_wrap;
    assign tick_wrap = (tick_cnt_q + 32'd1) >= tick_s;
    assign raise[d] = armed_q && ((delay_s == 16'd0) ||
                                  ((max_s != 8'd0) && (count_q >= max_s)) ||
                                  ((delay_s != 16'd0) && (ticks_q >= delay_s)));
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        count_q    <= '0;
        armed_q    <= 1'b0;
        max_s      <= '0;
        delay_s    <= '0;
        tick_s     <= 32'd1;
        tick_cnt_q <= '0;
        ticks_q    <= '0;
      end else begin
        // Timer of an armed interval.
        if (armed_q) begin
          if (tick_wrap) begin
            tick_cnt_q <= '0;
            if (ticks_q != 16'hFFFF) ticks_q <= ticks_q + 16'd1;
          end else begin
            tick_cnt_q <= tick_cnt_q + 32'd1;
          end
        end
        if (raise[d]) armed_q <= 1'b0;
        // The acknowledgement starts a new interval; a completion in the
        // same cycle is that interval's first.
        if (ack[d]) begin
          count_q <= '0;
          armed_q <= 1'b0;
        end
        if (done[d]) begin
          count_q <= ack[d] ? 8'd1 : ((count_q == 8'hFF) ? 8'hFF : count_q + 8'd1);
          if (ack[d] || (!armed_q && !raise[d] && (count_q == 8'd0))) begin
            // First completion of an interval: snapshot and arm.
            armed_q    <= 1'b1;
            max_s      <= itr[23:16];
            delay_s    <= itr[15:0];
            tick_s     <= (tick_q == 32'd0) ? 32'd1 : tick_q;
            tick_cnt_q <= '0;
            ticks_q    <= '0;
          end
        end
      end
    end
  end

  // ---- status ------------------------------------------------------------------
  logic [nic_pkg::IrqBits-1:0] status_q, set_now, clr_now;
  assign set_now = {i_desc_err, i_link_change, i_rx_drop, raise[1], raise[0]};
  assign clr_now = wr_status ? i_wr_data[nic_pkg::IrqBits-1:0] : '0;
  always_ff @(posedge i_clk) begin
    if (i_rst) status_q <= '0;
    else status_q <= (status_q & ~clr_now) | set_now;  // set wins over a same-cycle clear
  end

  logic irq_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) irq_q <= 1'b0;
    else irq_q <= |(status_q & mask_q);
  end
  assign o_irq    = irq_q;
  assign o_status = {{(32 - nic_pkg::IrqBits) {1'b0}}, status_q};
  assign o_mask   = {{(32 - nic_pkg::IrqBits) {1'b0}}, mask_q};
  assign o_rx_itr = rx_itr_q;
  assign o_tx_itr = tx_itr_q;
  assign o_tick   = tick_q;
endmodule : nic_irq
