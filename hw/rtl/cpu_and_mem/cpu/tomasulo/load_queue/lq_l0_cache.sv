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
 * Direct-mapped L0 data cache for the load queue: dword-granule (aligned
 * 8-byte) lines, valid bits in flip-flops, tag and data arrays in LUTRAM
 * (hw/rtl/README.md, "Data-tier bus contract").
 *
 * Lookup is combinational, so a hit lands in the same cycle as the address.
 * A line holds the whole aligned dword and consumers extract by addr[2:0].
 * Each fill writes one full memory-response beat; a lookup sees it from the
 * next cycle.
 *
 * MMIO addresses always miss (the addr[31:30] == 2'b01 quadrant; DDR at
 * 0x8000_0000+ is cacheable).
 *
 * i_flush_all clears every valid bit, but the LQ ties it to 0: L0 contents
 * always reflect architectural memory, so lines stay hot across pipeline
 * flushes.
 *
 * Invalidation has two per-address ports, one for SQ store-write launch and
 * one for AMO completion, plus a tag-blind line port for DMA writes. A store
 * invalidates the whole dword line that contains it, which is conservative
 * for sub-dword stores.
 */

module lq_l0_cache #(
    parameter int unsigned DEPTH = riscv_pkg::LqL0Depth,
    parameter int unsigned XLEN  = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst_n,

    // Lookup (combinational read)
    input  logic [                  XLEN-1:0] i_lookup_addr,
    output logic                              o_lookup_hit,
    output logic [riscv_pkg::MemDataBits-1:0] o_lookup_data,  // aligned dword line

    // Fill (write on memory response)
    input logic                              i_fill_valid,
    input logic [                  XLEN-1:0] i_fill_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_fill_data,

    // Invalidate valid bits on the clock edge.
    input logic            i_invalidate_valid,
    input logic [XLEN-1:0] i_invalidate_addr,

    // Second invalidate port (AMO write completion).  It is structurally
    // independent from port 1 so the LQ never muxes the two sources'
    // addresses in front of the tag read + compare, which would put the late
    // AMO write-done acknowledge in series with the whole invalidate cone
    // (amo_state -> L0 valid).  AMO serialization keeps the two sources
    // mutually exclusive (asserted in load_queue), but nothing here relies
    // on that.
    input logic            i_invalidate2_valid,
    input logic [XLEN-1:0] i_invalidate2_addr,

    // Same-cycle lookup-hit suppression for stores.  AMO write completion is
    // serialized by the LQ, so it can use the sequential invalidation above
    // and keep the AMO write address out of the lookup-hit cone.
    input logic            i_lookup_invalidate_valid,
    input logic [XLEN-1:0] i_lookup_invalidate_addr,
    // Line invalidate (DMA coherence): clear the four dword entries of a
    // 32-byte line, tag-blind, and suppress a same-cycle hit on any of them.
    input logic            i_invalidate_line_valid,
    input logic [XLEN-1:0] i_invalidate_line_addr,

    // Flush all (pipeline flush)
    input logic i_flush_all
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned IndexWidth = $clog2(DEPTH);
  // Tags cover the physical address above the dword index: bits
  // [31 : 3+IndexWidth], at any XLEN.  The physical map is 32-bit
  // (riscv_pkg::PhysAddrBits), and the LQ never uses a hit for an address
  // outside it (such a load takes an access fault), so higher bits would only
  // lengthen the lookup-hit compare, which feeds the LQ's memory-launch
  // decision.
  localparam int unsigned TagWidth   = 32 - 3 - IndexWidth;

  // Four adjacent dwords form one DMA line. The index needs at least one
  // bit above that line, and at least one physical tag bit must remain.
  initial begin
    if (DEPTH < 8 || DEPTH > 2 ** 28 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "L0 DEPTH must be a power of two in [8, 2**28]");
    if (XLEN < 32) $fatal(1, "L0 requires at least 32 physical address bits");
  end

  // ===========================================================================
  // Storage
  // ===========================================================================
  logic [DEPTH-1:0] valid;
  logic [TagWidth-1:0] tag_lookup_rd;
  logic [TagWidth-1:0] tag_inv_rd;
  logic [riscv_pkg::MemDataBits-1:0] data_lookup_rd;

  // ===========================================================================
  // Address decomposition
  // ===========================================================================
  // Dword-granule: addr[2:0] ignored, index = addr[3 +: IndexWidth],
  // tag = addr[(3+IndexWidth) +: TagWidth]

  wire [IndexWidth-1:0] lookup_index = i_lookup_addr[3+:IndexWidth];
  wire [TagWidth-1:0] lookup_tag = i_lookup_addr[(3+IndexWidth)+:TagWidth];
  // MMIO is the 01 address quadrant.  The DDR region (10 quadrant) is
  // cacheable here just like the low BRAM range (stores invalidate; reset clears).
  // The decode uses fixed physical bits [31:30], never [XLEN-1:XLEN-2]: at
  // XLEN=64 the relative form tests always-zero bits 63:62, so MMIO would
  // become cacheable and device registers would return stale L0 hits.
  wire lookup_mmio = (i_lookup_addr[31:30] == 2'b01);

  wire [IndexWidth-1:0] fill_index = i_fill_addr[3+:IndexWidth];
  wire [TagWidth-1:0] fill_tag = i_fill_addr[(3+IndexWidth)+:TagWidth];

  wire [IndexWidth-1:0] inv_index = i_invalidate_addr[3+:IndexWidth];
  wire [TagWidth-1:0] inv_tag = i_invalidate_addr[(3+IndexWidth)+:TagWidth];

  wire [IndexWidth-1:0] inv2_index = i_invalidate2_addr[3+:IndexWidth];
  wire [TagWidth-1:0] inv2_tag = i_invalidate2_addr[(3+IndexWidth)+:TagWidth];

  wire [IndexWidth-1:0] lookup_inv_index = i_lookup_invalidate_addr[3+:IndexWidth];
  wire [TagWidth-1:0] lookup_inv_tag = i_lookup_invalidate_addr[(3+IndexWidth)+:TagWidth];
  logic invalidate_fill_entry;
  logic invalidate_existing_entry;
  logic invalidate2_fill_entry;
  logic invalidate2_existing_entry;
  logic lookup_hit_array;
  logic lookup_fill_bypass;
  logic lookup_invalidated;

  // Tags are written only on fill and read at independent addresses (lookup,
  // port-1 invalidate, and port-2 invalidate below), so the tag array is a
  // simple dual-port RAM duplicated once per read port instead of a bank of
  // flip-flops.
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

  // Port-2 invalidate gets its own tag replica for the same reason the
  // lookup and port-1 invalidate each have one: independent read addresses
  // on LUTRAM copies instead of a shared read port behind an address mux.
  logic [TagWidth-1:0] tag_inv2_rd;
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_inv2_ram (
      .i_clk,
      .i_write_enable (i_fill_valid),
      .i_write_address(fill_index),
      .i_read_address (inv2_index),
      .i_write_data   (fill_tag),
      .o_read_data    (tag_inv2_rd)
  );

  // Data has one write port and one lookup read port, so it maps to a small
  // LUTRAM rather than a bank of flip-flops.
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(riscv_pkg::MemDataBits)
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
  assign invalidate2_fill_entry =
      i_invalidate2_valid && i_fill_valid &&
      (fill_index == inv2_index) && (fill_tag == inv2_tag);
  assign invalidate2_existing_entry =
      i_invalidate2_valid &&
      valid[inv2_index] &&
      (tag_inv2_rd == inv2_tag) &&
      !(i_fill_valid && (fill_index == inv2_index) && (fill_tag != inv2_tag));
  assign lookup_hit_array = valid[lookup_index] && (tag_lookup_rd == lookup_tag);
  // lookup_fill_bypass (same-cycle fill-to-lookup forwarding) is tied to 0.
  // Forwarding the fill would put the response-accept and flush logic
  // (cache_fill_valid in load_queue) in front of o_lookup_hit, and from there
  // on the path to the data-memory read address. Without it o_lookup_hit does
  // not depend on the fill inputs. It would only help a load looked up in the
  // exact cycle another load's response fills its line, which misses instead.
  assign lookup_fill_bypass = 1'b0;
  assign lookup_invalidated =
      i_lookup_invalidate_valid &&
      (lookup_inv_index == lookup_index) &&
      (lookup_inv_tag == lookup_tag);
  logic lookup_line_invalidated;
  assign lookup_line_invalidated = i_invalidate_line_valid &&
      (i_invalidate_line_addr[5+:(IndexWidth-2)] == lookup_index[IndexWidth-1:2]);
  assign o_lookup_hit =
      !lookup_mmio && lookup_hit_array && !lookup_invalidated && !lookup_line_invalidated;
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
      if (i_fill_valid) begin
        valid[fill_index] <= 1'b1;
      end

      // Invalidate, one address per port.
      //
      // A concurrent fill to the same index wins only when it replaces a
      // different tag in that direct-mapped slot. If the fill and the
      // invalidate target the same tag, the invalidate wins; otherwise a load
      // response can reinsert stale data in the same cycle that a committed
      // store is invalidating that dword.
      if (invalidate_fill_entry || invalidate_existing_entry) begin
        valid[inv_index] <= 1'b0;
      end
      if (invalidate2_fill_entry || invalidate2_existing_entry) begin
        valid[inv2_index] <= 1'b0;
      end
      // Line invalidate: tag-blind clear of the line's four dword entries,
      // after the fill so it wins a same-cycle fill of any of them.
      if (i_invalidate_line_valid) begin
        for (int k = 0; k < 4; k++) begin
          valid[{i_invalidate_line_addr[5+:(IndexWidth-2)], 2'(k)}] <= 1'b0;
        end
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
    if (i_rst_n && (i_lookup_addr[31:30] == 2'b01)) begin
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

  // After a flush, every valid bit is clear
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_flush_all)) begin
      p_flush_clears_all : assert (valid == '0);
    end
  end

  // A fill followed by a lookup at the same dword-aligned address hits.
  // The fill address is tracked across one cycle so the assertion can name it.
  reg [                  XLEN-1:0] f_fill_addr_q;
  reg [riscv_pkg::MemDataBits-1:0] f_fill_data_q;
  reg                              f_fill_valid_q;
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_fill_valid_q <= 1'b0;
      f_fill_addr_q  <= '0;
    end else begin
      f_fill_valid_q <= i_fill_valid & ~i_flush_all & !invalidate_fill_entry &
                        !invalidate2_fill_entry &
                        !(i_invalidate_line_valid &&
                          (i_invalidate_line_addr[5+:(IndexWidth-2)] ==
                           i_fill_addr[5+:(IndexWidth-2)]));
      f_fill_addr_q <= i_fill_addr;
      f_fill_data_q <= i_fill_data;
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && f_fill_valid_q
        && !i_flush_all
        && i_lookup_addr[XLEN-1:3] == f_fill_addr_q[XLEN-1:3]
        && !(i_lookup_addr[31:30] == 2'b01)
        && !(i_lookup_invalidate_valid
             && i_lookup_invalidate_addr[3+:IndexWidth]
                == f_fill_addr_q[3+:IndexWidth])
        && !(i_invalidate_line_valid
             && i_invalidate_line_addr[5+:(IndexWidth-2)]
                == f_fill_addr_q[5+:(IndexWidth-2)])
        && !(i_fill_valid
             && i_fill_addr[3+:IndexWidth]
                == f_fill_addr_q[3+:IndexWidth]
             && i_fill_addr[(3+IndexWidth)+:TagWidth]
                != f_fill_addr_q[(3+IndexWidth)+:TagWidth])) begin
      p_fill_then_hit : assert (o_lookup_hit);
      p_fill_data_preserved : assert (o_lookup_data == f_fill_data_q);
    end
  end

  // DMA invalidation is tag-blind and wins even over a simultaneous fill.
  // Check each dword independently at every supported capacity.
  for (genvar k = 0; k < 4; k++) begin : gen_formal_line_invalidate
    always @(posedge i_clk) begin
      if (f_past_valid && $past(i_rst_n && i_invalidate_line_valid)) begin
        assert (!valid[{$past(i_invalidate_line_addr[5+:(IndexWidth-2)]), 2'(k)}]);
      end
    end
  end

  always_comb begin
    if (i_invalidate_line_valid &&
        (i_lookup_addr[5+:(IndexWidth-2)] == i_invalidate_line_addr[5+:(IndexWidth-2)])) begin
      p_dma_suppresses_same_cycle_lookup : assert (!o_lookup_hit);
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
      cover_invalidate2 : cover (i_invalidate2_valid && valid[inv2_index]);
      cover_invalidate_line : cover (i_invalidate_line_valid);
    end
  end

`endif  // FORMAL

endmodule
