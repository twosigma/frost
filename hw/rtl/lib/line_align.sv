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
 * Line Align
 *
 * Moves an access of up to DATA_BYTES bytes between register order and a
 * window of two consecutive LINE_BYTES-byte lines, for an access that starts
 * at byte i_offset of the lower line. Byte k of the access is byte
 * i_offset + k of the window; bytes from LINE_BYTES on belong to the upper
 * line.
 *
 * Extract: o_extract holds the access's bytes, read from {i_hi_line,
 * i_lo_line}, in its low i_nbytes bytes and zero above.
 *
 * Place: o_lo_data/o_hi_data hold the low i_nbytes bytes of i_data at their
 * window positions, and o_lo_mask/o_hi_mask mark exactly those bytes. Unmarked
 * data bytes are zero. o_crosses is set when the access reaches the upper
 * line.
 *
 * Combinational. i_nbytes must be at most DATA_BYTES.
 */
module line_align #(
    parameter  int unsigned LINE_BYTES = 32,
    parameter  int unsigned DATA_BYTES = 8,
    localparam int unsigned OffsetBits = $clog2(LINE_BYTES),
    localparam int unsigned CountBits  = $clog2(DATA_BYTES + 1)
) (
    input logic [OffsetBits-1:0] i_offset,
    input logic [ CountBits-1:0] i_nbytes,

    input  logic [8*LINE_BYTES-1:0] i_lo_line,
    input  logic [8*LINE_BYTES-1:0] i_hi_line,
    output logic [8*DATA_BYTES-1:0] o_extract,

    input  logic [8*DATA_BYTES-1:0] i_data,
    output logic [8*LINE_BYTES-1:0] o_lo_data,
    output logic [8*LINE_BYTES-1:0] o_hi_data,
    output logic [  LINE_BYTES-1:0] o_lo_mask,
    output logic [  LINE_BYTES-1:0] o_hi_mask,
    output logic                    o_crosses
);

  localparam int unsigned WindowBytes = 2 * LINE_BYTES;

  // Byte mask of the access in register order.
  logic [DATA_BYTES-1:0] count_mask;
  always_comb begin
    for (int unsigned k = 0; k < DATA_BYTES; k++) count_mask[k] = (k < i_nbytes);
  end

  logic [8*DATA_BYTES-1:0] data_bits_mask;
  always_comb begin
    for (int unsigned k = 0; k < DATA_BYTES; k++) data_bits_mask[8*k+:8] = {8{count_mask[k]}};
  end

  // Extract: shift the window down by the offset.
  logic [8*WindowBytes-1:0] window_down;
  assign window_down = {i_hi_line, i_lo_line} >> {i_offset, 3'b000};
  assign o_extract   = window_down[8*DATA_BYTES-1:0] & data_bits_mask;

  // Place: shift the masked data and its byte mask up by the offset.
  logic [8*WindowBytes-1:0] window_data;
  logic [  WindowBytes-1:0] window_mask;
  assign window_data = {{(8 * (WindowBytes - DATA_BYTES)) {1'b0}}, i_data & data_bits_mask}
      << {i_offset, 3'b000};
  assign window_mask = {{(WindowBytes - DATA_BYTES) {1'b0}}, count_mask} << i_offset;

  assign o_lo_data = window_data[8*LINE_BYTES-1:0];
  assign o_hi_data = window_data[8*WindowBytes-1:8*LINE_BYTES];
  assign o_lo_mask = window_mask[LINE_BYTES-1:0];
  assign o_hi_mask = window_mask[WindowBytes-1:LINE_BYTES];
  assign o_crosses = |o_hi_mask;

endmodule
