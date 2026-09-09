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
 * nic_byte_pack: places a frame's 8-byte beats into 32-byte line writes at
 * any byte address.
 *
 * Contract: input byte j of the frame lands at address A + j for
 * j < LIMIT, with no other strobe set (A = i_addr, LIMIT = i_limit,
 * both taken at i_start). Beats arrive on the valid/ready input, each with
 * its byte count (1..8, only the last beat may be short) and a last flag.
 * The engine keeps at most one frame in the packer at a time.
 *
 * Mechanism: a two-line staging window whose base is the line of A. A
 * beat is rotated once by A mod 8 (the rotation is the same for every beat
 * of the frame: positions advance by 8) into a 16-byte pattern and placed
 * at chunk pos/8 and pos/8 + 1 of the window with per-byte enables; pos is
 * the byte position of the next byte relative to the window base. When the
 * next byte belongs to the upper line the lower line is complete and is
 * issued as a line write with the strobes it accumulated (full for
 * interior lines, partial at both ends), and the window shifts down a
 * line. At the last beat the lower line is flushed, and the upper line too
 * if it holds any byte. Bytes at or beyond LIMIT are dropped (the engine
 * reports the truncation). Output writes go through a register that holds
 * the line until the front-end accepts it; the input stalls while a
 * completed line waits.
 */
module nic_byte_pack #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Frame start: latches the address and the byte limit, clears the window.
    // Flush: the frame is abandoned; the window and a waiting write are dropped.
    input logic                  i_flush,
    input logic                  i_start,
    input logic [ADDR_WIDTH-1:0] i_addr,
    input logic [          15:0] i_limit,

    // Beats.
    input  logic        i_beat_valid,
    output logic        o_beat_ready,
    input  logic [63:0] i_beat_data,
    input  logic [ 3:0] i_beat_bytes,  // 1..8
    input  logic        i_beat_last,

    // Line writes.
    output logic                    o_wr_valid,
    input  logic                    i_wr_ready,
    output logic [  ADDR_WIDTH-1:0] o_wr_addr,
    output logic [LINE_BYTES*8-1:0] o_wr_wdata,
    output logic [  LINE_BYTES-1:0] o_wr_wstrb,

    output logic o_busy  // a frame is in the packer (until its last write left)
);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned WindowBytes = 2 * LINE_BYTES;

  // ---- frame state ---------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] win_base_q;  // line address of window byte 0
  logic [2:0] rot_q;  // A mod 8
  logic [OffsetBits:0] pos_q;  // next byte's position in the window (0..63)
  logic [15:0] limit_q, placed_q;  // bytes allowed, bytes placed
  logic active_q, flushing_q;
  logic [7:0] win_data_q[WindowBytes];
  logic [WindowBytes-1:0] win_strb_q;

  // ---- beat rotation and placement -------------------------------------------------
  // rotated16[rot + j] = beat[j]; enables cover the bytes inside the limit.
  logic [7:0] rot16[16];
  logic [15:0] rot16_en;
  logic [15:0] room;  // bytes still allowed
  assign room = limit_q - placed_q;
  always_comb begin
    for (int i = 0; i < 16; i++) begin
      rot16[i]    = '0;
      rot16_en[i] = 1'b0;
    end
    for (int j = 0; j < 8; j++) begin
      if ((j < int'(i_beat_bytes)) && (16'(j) < room)) begin
        rot16[int'(rot_q)+j]    = i_beat_data[j*8+:8];
        rot16_en[int'(rot_q)+j] = 1'b1;
      end
    end
  end
  logic [3:0] bytes_kept_now;  // bytes of this beat that fit under the limit
  always_comb begin
    bytes_kept_now = '0;
    for (int j = 0; j < 8; j++) begin
      if ((j < int'(i_beat_bytes)) && (16'(j) < room)) bytes_kept_now = 4'(j + 1);
    end
  end

  // Next window after placing this beat: the rotated pattern lands on the
  // chunk pair starting at the chunk that holds pos.
  logic [OffsetBits:0] chunk_base;
  assign chunk_base = {pos_q[OffsetBits:3], 3'b000};
  logic [7:0] win_data_n[WindowBytes];
  logic [WindowBytes-1:0] win_strb_n;
  always_comb begin
    // The window as if the offered beat were placed (used only on the fire).
    win_data_n = win_data_q;
    win_strb_n = win_strb_q;
    for (int i = 0; i < 16; i++) begin
      if (rot16_en[i] && ((int'(chunk_base) + i) < int'(WindowBytes))) begin
        win_data_n[int'(chunk_base)+i] = rot16[i];
        win_strb_n[int'(chunk_base)+i] = 1'b1;
      end
    end
  end

  // ---- output register -------------------------------------------------------------
  logic out_valid_q;
  logic [ADDR_WIDTH-1:0] out_addr_q;
  logic [LINE_BYTES*8-1:0] out_wdata_q;
  logic [LINE_BYTES-1:0] out_wstrb_q;
  assign o_wr_valid = out_valid_q;
  assign o_wr_addr  = out_addr_q;
  assign o_wr_wdata = out_wdata_q;
  assign o_wr_wstrb = out_wstrb_q;
  // A line is issued only into an empty output register: the beat interface's
  // ready then depends on this block's own state, not on the front-end's
  // acceptance in the same cycle (the register empties the cycle after a
  // write is taken, which a four-beat line never waits for).
  logic out_free;
  assign out_free = !out_valid_q;

  // A beat is taken when the packer is active, not flushing, and the lower
  // line can be issued this cycle if the beat completes it.
  logic lower_complete_after;  // the lower line is complete once this beat is placed
  logic [OffsetBits:0] pos_after;
  assign pos_after = pos_q + (OffsetBits + 1)'(i_beat_bytes);
  assign lower_complete_after = (pos_after >= (OffsetBits + 1)'(LINE_BYTES)) || i_beat_last;
  // A completed lower line is issued only when it holds a byte (after the
  // limit, lines complete empty and are skipped).
  logic lower_issue;
  assign lower_issue  = lower_complete_after && (|win_strb_n[LINE_BYTES-1:0]);
  assign o_beat_ready = active_q && !flushing_q && (!lower_issue || out_free);
  logic beat_fire;
  assign beat_fire = i_beat_valid && o_beat_ready;

  assign o_busy = active_q || flushing_q || out_valid_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      active_q    <= 1'b0;
      flushing_q  <= 1'b0;
      out_valid_q <= 1'b0;
      win_strb_q  <= '0;
      pos_q       <= '0;
      placed_q    <= '0;
      limit_q     <= '0;
    end else begin
      if (out_valid_q && i_wr_ready) out_valid_q <= 1'b0;

      if (i_flush) begin
        active_q    <= 1'b0;
        flushing_q  <= 1'b0;
        out_valid_q <= 1'b0;
        win_strb_q  <= '0;
      end else if (i_start) begin
        active_q   <= 1'b1;
        flushing_q <= 1'b0;
        win_base_q <= {i_addr[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
        rot_q      <= i_addr[2:0];
        pos_q      <= (OffsetBits + 1)'(i_addr[OffsetBits-1:0]);
        limit_q    <= i_limit;
        placed_q   <= '0;
        win_strb_q <= '0;
      end else if (beat_fire) begin
        placed_q <= placed_q + 16'(bytes_kept_now);
        if (lower_complete_after) begin
          // Issue the lower line if it holds a byte; shift the window down one line.
          if (lower_issue) begin
            out_valid_q <= 1'b1;
            out_addr_q  <= win_base_q;
            for (int b = 0; b < int'(LINE_BYTES); b++) out_wdata_q[b*8+:8] <= win_data_n[b];
            out_wstrb_q <= win_strb_n[LINE_BYTES-1:0];
          end
          for (int b = 0; b < int'(LINE_BYTES); b++) win_data_q[b] <= win_data_n[LINE_BYTES+b];
          win_strb_q <= {{LINE_BYTES{1'b0}}, win_strb_n[WindowBytes-1:LINE_BYTES]};
          win_base_q <= win_base_q + ADDR_WIDTH'(LINE_BYTES);
          pos_q      <= pos_after - (OffsetBits + 1)'(LINE_BYTES);
          if (i_beat_last) begin
            // The upper half may still hold bytes: flush it next.
            active_q   <= 1'b0;
            flushing_q <= |win_strb_n[WindowBytes-1:LINE_BYTES];
          end
        end else begin
          for (int b = 0; b < int'(WindowBytes); b++) win_data_q[b] <= win_data_n[b];
          win_strb_q <= win_strb_n;
          pos_q      <= pos_after;
        end
      end else if (flushing_q && out_free) begin
        out_valid_q <= 1'b1;
        out_addr_q  <= win_base_q;
        for (int b = 0; b < int'(LINE_BYTES); b++) out_wdata_q[b*8+:8] <= win_data_q[b];
        out_wstrb_q <= win_strb_q[LINE_BYTES-1:0];
        win_strb_q  <= '0;
        flushing_q  <= 1'b0;
      end
    end
  end
endmodule : nic_byte_pack
