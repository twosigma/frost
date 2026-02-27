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
 * LQ L0 Data Cache
 *
 * Simplified OoO-compatible L0 data cache for the Load Queue.
 * Direct-mapped, word-aligned entries with FF-based tag+valid
 * and LUTRAM data array.
 *
 * The existing l0_cache.sv uses in-order pipeline types; this module
 * uses simple address/data ports suitable for the LQ's OoO issue path.
 *
 * Features:
 *   - Combinational lookup (hit in same cycle as address)
 *   - Fill on memory response
 *   - MMIO addresses always miss (>= MMIO_ADDR)
 *   - Flush all valid bits on pipeline flush
 *   - Per-address invalidation port (for future SQ integration)
 */

module lq_l0_cache #(
    parameter int unsigned DEPTH     = 128,
    parameter int unsigned XLEN      = 32,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst_n,

    // Lookup (combinational read)
    input  logic [XLEN-1:0] i_lookup_addr,
    output logic            o_lookup_hit,
    output logic [XLEN-1:0] o_lookup_data,  // raw word at word-aligned addr

    // Fill (write on memory response)
    input logic            i_fill_valid,
    input logic [XLEN-1:0] i_fill_addr,
    input logic [XLEN-1:0] i_fill_data,

    // Invalidate (for future SQ integration)
    input logic            i_invalidate_valid,
    input logic [XLEN-1:0] i_invalidate_addr,

    // Flush all (pipeline flush)
    input logic i_flush_all
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned IndexWidth = $clog2(DEPTH);
  localparam int unsigned TagWidth = XLEN - 2 - IndexWidth;  // word-aligned: skip bit[1:0]

  // ===========================================================================
  // Storage
  // ===========================================================================
  logic [     DEPTH-1:0] valid;
  logic [  TagWidth-1:0] tags                                                  [DEPTH];
  logic [      XLEN-1:0] data                                                  [DEPTH];

  // ===========================================================================
  // Address decomposition
  // ===========================================================================
  // Word-aligned: addr[1:0] ignored, index = addr[2 +: IndexWidth],
  // tag = addr[(2+IndexWidth) +: TagWidth]

  wire  [IndexWidth-1:0] lookup_index = i_lookup_addr[2+:IndexWidth];
  wire  [  TagWidth-1:0] lookup_tag = i_lookup_addr[(2+IndexWidth)+:TagWidth];
  wire                   lookup_mmio = (i_lookup_addr >= MMIO_ADDR[XLEN-1:0]);

  wire  [IndexWidth-1:0] fill_index = i_fill_addr[2+:IndexWidth];
  wire  [  TagWidth-1:0] fill_tag = i_fill_addr[(2+IndexWidth)+:TagWidth];

  wire  [IndexWidth-1:0] inv_index = i_invalidate_addr[2+:IndexWidth];
  wire  [  TagWidth-1:0] inv_tag = i_invalidate_addr[(2+IndexWidth)+:TagWidth];

  // ===========================================================================
  // Combinational Lookup
  // ===========================================================================
  assign o_lookup_hit  = valid[lookup_index] && (tags[lookup_index] == lookup_tag) && !lookup_mmio;
  assign o_lookup_data = data[lookup_index];

  // ===========================================================================
  // Sequential: Fill, Invalidate, Flush
  // ===========================================================================
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      valid <= '0;
    end else if (i_flush_all) begin
      valid <= '0;
    end else begin
      // Fill
      if (i_fill_valid) begin
        valid[fill_index] <= 1'b1;
        tags[fill_index]  <= fill_tag;
        data[fill_index]  <= i_fill_data;
      end

      // Invalidate (single address).
      // Suppress when a concurrent fill targets the same index — the fill
      // takes priority since it writes a fresh tag+data.
      if (i_invalidate_valid && valid[inv_index] && tags[inv_index] == inv_tag
          && !(i_fill_valid && fill_index == inv_index)) begin
        valid[inv_index] <= 1'b0;
      end
    end
  end

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Assertions
  // -------------------------------------------------------------------------

  // MMIO addresses never hit
  always_comb begin
    if (i_rst_n && (i_lookup_addr >= MMIO_ADDR[XLEN-1:0])) begin
      p_mmio_never_hits : assert (!o_lookup_hit);
    end
  end

  // Hit implies valid and tag match
  always_comb begin
    if (i_rst_n && o_lookup_hit) begin
      p_hit_implies_valid : assert (valid[lookup_index]);
      p_hit_implies_tag_match : assert (tags[lookup_index] == lookup_tag);
    end
  end

  // After flush, no hits
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_flush_all)) begin
      p_flush_clears_all : assert (valid == '0);
    end
  end

  // Fill followed by lookup at same word-aligned address should hit.
  // Track a single fill address across one cycle for a cleaner assertion.
  reg [XLEN-1:0] f_fill_addr_q;
  reg            f_fill_valid_q;
  always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      f_fill_valid_q <= 1'b0;
      f_fill_addr_q  <= '0;
    end else begin
      f_fill_valid_q <= i_fill_valid & ~i_flush_all;
      f_fill_addr_q  <= i_fill_addr;
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && f_fill_valid_q
        && !i_flush_all
        && i_lookup_addr[XLEN-1:2] == f_fill_addr_q[XLEN-1:2]
        && !(i_lookup_addr >= MMIO_ADDR[XLEN-1:0])
        && !(i_invalidate_valid
             && i_invalidate_addr[2+:IndexWidth]
                == f_fill_addr_q[2+:IndexWidth])
        && !(i_fill_valid
             && i_fill_addr[2+:IndexWidth]
                == f_fill_addr_q[2+:IndexWidth]
             && i_fill_addr[(2+IndexWidth)+:TagWidth]
                != f_fill_addr_q[(2+IndexWidth)+:TagWidth])) begin
      p_fill_then_hit : assert (o_lookup_hit);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_hit : cover (o_lookup_hit);
      cover_miss : cover (!o_lookup_hit && valid[lookup_index]);
      cover_fill : cover (i_fill_valid);
      cover_invalidate : cover (i_invalidate_valid && valid[inv_index]);
    end
  end

`endif  // FORMAL

endmodule
