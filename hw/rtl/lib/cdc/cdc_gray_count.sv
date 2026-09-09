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
 * cdc_gray_count: event counter crossing clock domains.
 *
 * The source domain counts i_src_event pulses (they may arrive on
 * consecutive cycles) in a WIDTH-bit binary counter and registers its Gray
 * code; the destination synchronizes the Gray value, decodes it, and adds
 * each delta to a TOTAL_WIDTH-bit total. Every synchronized value is one the
 * source counter actually held (one bit changes per increment), so no
 * increment is lost or duplicated as long as fewer than 2^WIDTH events
 * occur between two destination samples; the destination samples every
 * cycle, so with the destination clock at or above the source rate the
 * bound is a few events per sample.
 *
 * Epochs. A reset of the source domain zeroes its counter while the total
 * lives on; the destination would read that as a wrap and invent
 * 2^WIDTH - old events. i_dst_rebase is the level "the source is in reset"
 * (synchronized into the destination by the caller): while it is high the
 * total is frozen and the baseline is cleared, and the caller must hold it
 * long enough for the synchronizers to flush (the reset handshake does).
 * i_dst_rst clears the total.
 */
module cdc_gray_count #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned TOTAL_WIDTH = 64
) (
    input  logic                   i_src_clk,
    input  logic                   i_src_rst,
    input  logic                   i_src_event,
    input  logic                   i_dst_clk,
    input  logic                   i_dst_rst,
    input  logic                   i_dst_rebase,
    output logic [TOTAL_WIDTH-1:0] o_dst_total
);
  // ---- source domain ---------------------------------------------------------
  logic [WIDTH-1:0] src_bin_q, src_gray_q;
  logic [WIDTH-1:0] src_bin_next;
  assign src_bin_next = src_bin_q + WIDTH'(i_src_event);
  always_ff @(posedge i_src_clk) begin
    if (i_src_rst) begin
      src_bin_q  <= '0;
      src_gray_q <= '0;
    end else begin
      src_bin_q  <= src_bin_next;
      src_gray_q <= src_bin_next ^ (src_bin_next >> 1);
    end
  end

  // ---- destination domain ----------------------------------------------------
  logic [WIDTH-1:0] gray_s;
  cdc_sync #(
      .WIDTH(WIDTH)
  ) sync_gray (
      .i_clk  (i_dst_clk),
      .i_rst  (i_dst_rst),
      .i_async(src_gray_q),
      .o_sync (gray_s)
  );
  logic [WIDTH-1:0] bin_s;
  always_comb begin
    bin_s[WIDTH-1] = gray_s[WIDTH-1];
    for (int i = int'(WIDTH) - 2; i >= 0; i--) bin_s[i] = bin_s[i+1] ^ gray_s[i];
  end

  logic [WIDTH-1:0] last_q;
  logic [WIDTH-1:0] delta;
  assign delta = bin_s - last_q;
  logic [TOTAL_WIDTH-1:0] total_q;
  always_ff @(posedge i_dst_clk) begin
    if (i_dst_rst) begin
      last_q  <= '0;
      total_q <= '0;
    end else if (i_dst_rebase) begin
      last_q <= '0;
    end else begin
      last_q  <= bin_s;
      total_q <= total_q + TOTAL_WIDTH'(delta);
    end
  end
  assign o_dst_total = total_q;
endmodule : cdc_gray_count
