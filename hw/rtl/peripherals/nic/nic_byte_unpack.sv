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
 * nic_byte_unpack: turns 32-byte lines at any byte alignment into a frame's
 * contiguous 8-byte beats.
 *
 * Contract: the frame is the LEN bytes starting at byte offset OFF inside
 * its first line (i_offset, i_len at i_start; the engine keeps the line
 * addresses); the engine feeds the lines that cover
 * [A, A + LEN) in address order through the valid/ready line input; the
 * output presents beats of 8 bytes, the last one carrying the remaining
 * 1..8 bytes and the last flag. o_beat_data lane 0 is the lowest address.
 *
 * Mechanism: the mirror of nic_byte_pack. A two-line window holds the
 * current and the next line; a beat takes the 16 bytes of the chunk pair
 * at pos/8 and rotates them down by A mod 8 (constant per frame), so no
 * barrel shifter is needed. The window advances a line when pos crosses it,
 * consuming the next line from the input; a beat is offered only when every
 * chunk it needs is present. The last beat frees the window.
 */
module nic_byte_unpack #(
    parameter int unsigned LINE_BYTES = 32
) (
    input logic i_clk,
    input logic i_rst,

    input logic                          i_flush,   // abandon the frame, drop the window
    input logic                          i_start,
    input logic [$clog2(LINE_BYTES)-1:0] i_offset,
    input logic [                  15:0] i_len,

    // Lines, in address order.
    input  logic                    i_line_valid,
    output logic                    o_line_ready,
    input  logic [LINE_BYTES*8-1:0] i_line_data,

    // Beats.
    output logic        o_beat_valid,
    input  logic        i_beat_ready,
    output logic [63:0] o_beat_data,
    output logic [ 3:0] o_beat_bytes,
    output logic        o_beat_last,

    output logic o_busy
);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned WindowBytes = 2 * LINE_BYTES;

  logic active_q;
  logic [2:0] rot_q;
  logic [OffsetBits:0] pos_q;  // next byte's position in the window
  logic [15:0] remaining_q;  // bytes still to deliver
  logic [1:0] have_q;  // window halves present (bit 0 lower, bit 1 upper)
  logic [7:0] win_q[WindowBytes];

  // The next beat needs the chunk at pos and, when it straddles, the next
  // chunk; both must be in a half the window holds.
  logic [OffsetBits:0] chunk_base;
  assign chunk_base = {pos_q[OffsetBits:3], 3'b000};
  logic [3:0] beat_bytes;
  assign beat_bytes = (remaining_q >= 16'd8) ? 4'd8 : 4'(remaining_q);
  logic [OffsetBits+1:0] beat_end;  // position after this beat
  assign beat_end = (OffsetBits + 2)'(pos_q) + (OffsetBits + 2)'(beat_bytes);
  logic needs_upper, needs_lower;
  assign needs_lower = (chunk_base < (OffsetBits + 1)'(LINE_BYTES));
  assign needs_upper = (beat_end > (OffsetBits + 2)'(LINE_BYTES));
  logic present;
  assign present = (!needs_lower || have_q[0]) && (!needs_upper || have_q[1]);

  // Take the next line into the first missing half.
  assign o_line_ready = active_q && !(&have_q);
  logic line_fire;
  assign line_fire = i_line_valid && o_line_ready;

  // Beat extraction: 16 bytes from the chunk pair, rotated down by rot.
  logic [7:0] pair[16];
  always_comb begin
    for (int i = 0; i < 16; i++) begin
      pair[i] = ((int'(chunk_base) + i) < int'(WindowBytes)) ? win_q[int'(chunk_base)+i] : 8'h00;
    end
    for (int j = 0; j < 8; j++) o_beat_data[j*8+:8] = pair[int'(rot_q)+j];
  end
  assign o_beat_valid = active_q && present && (remaining_q != 16'd0);
  assign o_beat_bytes = beat_bytes;
  assign o_beat_last  = (remaining_q <= 16'd8);
  logic beat_fire;
  assign beat_fire = o_beat_valid && i_beat_ready;
  logic crosses;  // the beat ends in the upper line: the lower line is done
  assign crosses = (beat_end >= (OffsetBits + 2)'(LINE_BYTES));

  assign o_busy  = active_q;

  // The window after this cycle's line fill (a line landing in the upper
  // half while a crossing beat shifts the window must survive the shift).
  logic [7:0] win_n  [WindowBytes];
  logic [1:0] have_n;
  always_comb begin
    win_n  = win_q;
    have_n = have_q;
    if (line_fire) begin
      if (!have_q[0]) begin
        for (int b = 0; b < int'(LINE_BYTES); b++) win_n[b] = i_line_data[b*8+:8];
        have_n[0] = 1'b1;
      end else begin
        for (int b = 0; b < int'(LINE_BYTES); b++) win_n[LINE_BYTES+b] = i_line_data[b*8+:8];
        have_n[1] = 1'b1;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      active_q    <= 1'b0;
      have_q      <= '0;
      pos_q       <= '0;
      remaining_q <= '0;
    end else begin
      if (i_flush) begin
        active_q    <= 1'b0;
        have_q      <= '0;
        remaining_q <= '0;
      end else if (i_start) begin
        active_q    <= 1'b1;
        rot_q       <= i_offset[2:0];
        pos_q       <= (OffsetBits + 1)'(i_offset);
        remaining_q <= i_len;
        have_q      <= '0;
      end else if (beat_fire) begin
        remaining_q <= remaining_q - 16'(beat_bytes);
        if (o_beat_last) begin
          active_q <= 1'b0;
          have_q   <= '0;
        end else if (crosses) begin
          // Shift the window down a line; the upper half becomes lower.
          for (int b = 0; b < int'(LINE_BYTES); b++) win_q[b] <= win_n[LINE_BYTES+b];
          have_q <= {1'b0, have_n[1]};
          pos_q  <= (OffsetBits + 1)'(beat_end - (OffsetBits + 2)'(LINE_BYTES));
        end else begin
          for (int b = 0; b < int'(WindowBytes); b++) win_q[b] <= win_n[b];
          have_q <= have_n;
          pos_q  <= (OffsetBits + 1)'(beat_end);
        end
      end else begin
        for (int b = 0; b < int'(WindowBytes); b++) win_q[b] <= win_n[b];
        have_q <= have_n;
      end
    end
  end
endmodule : nic_byte_unpack
