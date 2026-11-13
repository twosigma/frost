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

// Compare line_align with a byte-by-byte reference for arbitrary lines, data,
// offsets and byte counts up to DATA_BYTES, and check that extracting a
// placed access returns its bytes.
module line_align_check #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned DATA_BYTES = 8
) (
    input logic [$clog2(LINE_BYTES)-1:0] offset,
    input logic [$clog2(DATA_BYTES + 1)-1:0] nbytes,
    input logic [8*LINE_BYTES-1:0] lo_line,
    input logic [8*LINE_BYTES-1:0] hi_line,
    input logic [8*DATA_BYTES-1:0] data
);
  logic [8*DATA_BYTES-1:0] extract;
  logic [8*LINE_BYTES-1:0] lo_data, hi_data;
  logic [LINE_BYTES-1:0] lo_mask, hi_mask;
  logic crosses;

  line_align #(
      .LINE_BYTES(LINE_BYTES),
      .DATA_BYTES(DATA_BYTES)
  ) dut (
      .i_offset (offset),
      .i_nbytes (nbytes),
      .i_lo_line(lo_line),
      .i_hi_line(hi_line),
      .o_extract(extract),
      .i_data   (data),
      .o_lo_data(lo_data),
      .o_hi_data(hi_data),
      .o_lo_mask(lo_mask),
      .o_hi_mask(hi_mask),
      .o_crosses(crosses)
  );

  // Placed access read back through a second instance.
  logic [8*DATA_BYTES-1:0] round_trip;
  line_align #(
      .LINE_BYTES(LINE_BYTES),
      .DATA_BYTES(DATA_BYTES)
  ) back (
      .i_offset (offset),
      .i_nbytes (nbytes),
      .i_lo_line(lo_data),
      .i_hi_line(hi_data),
      .o_extract(round_trip),
      .i_data   ('0),
      .o_lo_data(),
      .o_hi_data(),
      .o_lo_mask(),
      .o_hi_mask(),
      .o_crosses()
  );

  logic [8*DATA_BYTES-1:0] ref_extract, ref_data;
  logic [8*LINE_BYTES-1:0] ref_lo_data, ref_hi_data;
  logic [LINE_BYTES-1:0] ref_lo_mask, ref_hi_mask;
  always_comb begin
    ref_extract = '0;
    ref_data = '0;
    ref_lo_data = '0;
    ref_hi_data = '0;
    ref_lo_mask = '0;
    ref_hi_mask = '0;
    for (int unsigned k = 0; k < DATA_BYTES; k++) begin
      if (k < nbytes) begin
        ref_data[8*k+:8] = data[8*k+:8];
        if (offset + k < LINE_BYTES) begin
          ref_extract[8*k+:8] = lo_line[8*(offset+k)+:8];
          ref_lo_data[8*(offset+k)+:8] = data[8*k+:8];
          ref_lo_mask[offset+k] = 1'b1;
        end else begin
          ref_extract[8*k+:8] = hi_line[8*(offset+k-LINE_BYTES)+:8];
          ref_hi_data[8*(offset+k-LINE_BYTES)+:8] = data[8*k+:8];
          ref_hi_mask[offset+k-LINE_BYTES] = 1'b1;
        end
      end
    end
  end

  always_comb begin
    if (nbytes <= DATA_BYTES) begin
      p_extract : assert (extract == ref_extract);
      p_lo_data : assert (lo_data == ref_lo_data);
      p_hi_data : assert (hi_data == ref_hi_data);
      p_lo_mask : assert (lo_mask == ref_lo_mask);
      p_hi_mask : assert (hi_mask == ref_hi_mask);
      p_crosses : assert (crosses == ((nbytes != 0) && (offset + nbytes > LINE_BYTES)));
      p_round_trip : assert (round_trip == ref_data);
    end
  end
endmodule
