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
 * Direct-mapped, word-aligned entries with FF-based valid bits and
 * LUTRAM-backed tag/data arrays.
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
  logic [  TagWidth-1:0] tag_lookup_rd;
  logic [  TagWidth-1:0] tag_inv_rd;
  logic [      XLEN-1:0] data_lookup_rd;

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
  logic                  invalidate_fill_entry;
  logic                  invalidate_existing_entry;
  logic                  lookup_hit_array;
  logic                  lookup_fill_bypass;
  logic                  lookup_invalidated;

  // Tags are written only on fill and read at two independent addresses
  // (lookup and invalidate), so duplicate the simple dual-port RAM once
  // per read port instead of keeping the tag array in flip-flops.
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_lookup_ram (
      .i_clk,
      .i_write_enable (i_fill_valid),
      .i_write_address(fill_index),
      .i_read_address (lookup_index),
      .i_write_data   (fill_tag),
      .o_read_data    (tag_lookup_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_inv_ram (
      .i_clk,
      .i_write_enable (i_fill_valid),
      .i_write_address(fill_index),
      .i_read_address (inv_index),
      .i_write_data   (fill_tag),
      .o_read_data    (tag_inv_rd)
  );

  // Data has a single write port and a single lookup read port, making it
  // an ideal fit for a small LUTRAM rather than a bank of FFs.
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(XLEN)
  ) u_data_ram (
      .i_clk,
      .i_write_enable (i_fill_valid),
      .i_write_address(fill_index),
      .i_read_address (lookup_index),
      .i_write_data   (i_fill_data),
      .o_read_data    (data_lookup_rd)
  );

  // ===========================================================================
  // Combinational Lookup
  // ===========================================================================
  assign invalidate_fill_entry =
      i_invalidate_valid && i_fill_valid &&
      (fill_index == inv_index) && (fill_tag == inv_tag);
  assign invalidate_existing_entry =
      i_invalidate_valid &&
      valid[inv_index] &&
      (tag_inv_rd == inv_tag) &&
      !(i_fill_valid && (fill_index == inv_index) && (fill_tag != inv_tag));
  assign lookup_hit_array = valid[lookup_index] && (tag_lookup_rd == lookup_tag);
  // lookup_fill_bypass (same-cycle fill/lookup forwarding) used to be combined
  // into o_lookup_hit. That created a long combinational chain
  //   i_flush_en (← mispredict_recovery_pending) → accept_mem_response
  //   → cache_fill_valid → lookup_fill_bypass → o_lookup_hit
  //   → cache_hit_fast_path → o_mem_read_en → o_mmio_load_valid (wrapper FIFO)
  //   → data_memory ADDRARDADDR
  // that became the new -0.944 ns critical path after the issued_idx →
  // lq_*_rd cone was removed. The bypass only helps the (rare) case where a
  // load is staged for lookup the exact cycle its address is being filled by
  // a sibling load's response; in every other case the LUTRAM is already
  // updated by next cycle and the normal lookup_hit_array path wins. Drop
  // the bypass term so o_lookup_hit depends only on registered signals
  // (sq_check_addr_q, valid[], tag LUTRAM, i_invalidate_valid). Cost: a
  // missed bypass forces one extra memory cycle for the same-cycle case.
  assign lookup_fill_bypass = 1'b0;
  assign lookup_invalidated =
      i_invalidate_valid && (inv_index == lookup_index) && (inv_tag == lookup_tag);
  assign o_lookup_hit = !lookup_mmio && lookup_hit_array && !lookup_invalidated;
  assign o_lookup_data = data_lookup_rd;

  // ===========================================================================
  // Sequential: Fill, Invalidate, Flush
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      valid <= '0;
    end else if (i_flush_all) begin
      valid <= '0;
    end else begin
      // Fill
      if (i_fill_valid) begin
        valid[fill_index] <= 1'b1;
      end

      // Invalidate (single address).
      //
      // A concurrent fill to the same index is only allowed to win when it
      // replaces a DIFFERENT tag in that direct-mapped slot. If the fill and
      // invalidate target the same tag, the invalidate must win; otherwise a
      // load response can reinsert stale data into the cache in the same cycle
      // that a committed store is trying to invalidate that word.
      if (invalidate_fill_entry || invalidate_existing_entry) begin
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
      p_hit_implies_tag_match : assert (tag_lookup_rd == lookup_tag);
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
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_fill_valid_q <= 1'b0;
      f_fill_addr_q  <= '0;
    end else begin
      f_fill_valid_q <= i_fill_valid & ~i_flush_all & !invalidate_fill_entry;
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
