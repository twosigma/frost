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
 * MMIO addresses in the zero-extended 01 quadrant always miss; DDR is
 * cacheable even when its upper addresses share those low quadrant bits.
 *
 * i_flush_all clears every valid bit, but the LQ ties it to 0: L0 contents
 * always reflect architectural memory, so lines stay hot across pipeline
 * flushes.
 *
 * Invalidation has two per-address ports, one for SQ store-write launch and
 * one for AMO completion, plus a tag-blind line port for DMA writes. A store
 * invalidates its dword unless i_store_strb supplies committed data. Then a
 * matching cached word updates exactly those bytes; a full dword may allocate.
 * A store update owns the RAM write port over a coincident read fill. AMO and
 * DMA invalidation still win over both kinds of write.
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
    // The same value as i_fill_valid, for the RAM write enables only.
    input logic                              i_fill_write,
    input logic [                  XLEN-1:0] i_fill_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_fill_data,

    // Invalidate valid bits on the clock edge.
    input logic            i_invalidate_valid,
    input logic [XLEN-1:0] i_invalidate_addr,
    input logic [    63:0] i_store_data = '0,
    input logic [     7:0] i_store_strb = '0,

    // AMO write completion uses a separate port for timing. LQ serialization
    // makes the two invalidate sources exclusive, but this cache does not
    // require that.
    input logic            i_invalidate2_valid,
    input logic [XLEN-1:0] i_invalidate2_addr,

    // Suppress same-cycle store hits. LQ serialization lets AMO completion
    // use only the sequential invalidation above.
    input logic            i_lookup_invalidate_valid,
    input logic [XLEN-1:0] i_lookup_invalidate_addr,
    // Line invalidate (DMA coherence): clear the four dword entries of a
    // 32-byte line, tag-blind, and suppress a same-cycle hit on any of them.
    input logic            i_invalidate_line_valid,
    input logic [XLEN-1:0] i_invalidate_line_addr,

    // Clear all valid bits.
    input logic i_flush_all
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (!i_rst_n) reset_seen_q <= 1'b1;
`endif

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned IndexWidth = $clog2(DEPTH);
  // Include every configured physical address bit in the tag; otherwise
  // upper DDR lines can falsely hit a low-address L0 entry.
  localparam int unsigned TagWidth   = riscv_pkg::PhysAddrBits - 3 - IndexWidth;

  // Four adjacent dwords form one DMA line. The index needs at least one
  // bit above that line, and at least one physical tag bit must remain.
  initial begin
    if (DEPTH < 8 || DEPTH > 2 ** 28 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "L0 DEPTH must be a power of two in [8, 2**28]");
    if (XLEN < riscv_pkg::PhysAddrBits)
      $fatal(1, "L0 XLEN must cover the configured physical address width");
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
  // Decode the full zero-extended MMIO quadrant. Upper DDR addresses can
  // share bits [31:30] and must remain cacheable.
  // BRAM and DDR are cacheable; stores invalidate their lines.
  wire lookup_mmio = riscv_pkg::pma_device_quadrant(i_lookup_addr);

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

  // Known committed stores update matching L0 bytes; full
  // dwords may allocate. A coincident response fill can be dropped safely.
  wire store_update = i_invalidate_valid && (|i_store_strb) &&
      ((&i_store_strb) || (valid[inv_index] && inv_tag_match));
  wire ram_write = store_update || i_fill_valid;
  // The data and tag RAMs take the write through i_fill_write, which the LQ
  // forms so the memory response enters at its last gate; the valid bits and
  // invalidation checks keep i_fill_valid.
  wire ram_write_en = store_update || i_fill_write;
  wire [IndexWidth-1:0] ram_index = store_update ? inv_index : fill_index;
  wire [TagWidth-1:0] ram_tag = store_update ? inv_tag : fill_tag;
  wire [63:0] ram_data = store_update ? i_store_data : i_fill_data;
  wire [7:0] ram_strobe = store_update ? i_store_strb : {8{i_fill_write}};

  // Duplicate the tag LUTRAM for independent lookup and invalidate reads.
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_lookup_ram (
      .i_clk,
      .i_write_enable (ram_write_en),
      .i_write_address(ram_index),
      .i_read_address (lookup_index),
      .i_write_data   (ram_tag),
      .o_read_data    (tag_lookup_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_inv_ram (
      .i_clk,
      .i_write_enable (ram_write_en),
      .i_write_address(ram_index),
      .i_read_address (inv_index),
      .i_write_data   (ram_tag),
      .o_read_data    (tag_inv_rd)
  );

  logic [TagWidth-1:0] tag_inv2_rd;
  sdp_dist_ram #(
      .ADDR_WIDTH(IndexWidth),
      .DATA_WIDTH(TagWidth)
  ) u_tag_inv2_ram (
      .i_clk,
      .i_write_enable (ram_write_en),
      .i_write_address(ram_index),
      .i_read_address (inv2_index),
      .i_write_data   (ram_tag),
      .o_read_data    (tag_inv2_rd)
  );

  // Independent byte enables avoid a read/modify/write mux on the store path.
  for (genvar byte_idx = 0; byte_idx < 8; byte_idx++) begin : gen_data_bytes
    sdp_dist_ram #(
        .ADDR_WIDTH(IndexWidth),
        .DATA_WIDTH(8)
    ) u_data_ram (
        .i_clk,
        .i_write_enable(ram_strobe[byte_idx]),
        .i_write_address(ram_index),
        .i_read_address(lookup_index),
        .i_write_data(ram_data[8*byte_idx+:8]),
        .o_read_data(data_lookup_rd[8*byte_idx+:8])
    );
  end

  // ===========================================================================
  // Combinational Lookup
  // ===========================================================================
  // Compare the fill and store candidates independently of the late store
  // tag hit. Selecting the RAM's address/tag before comparing them again
  // puts two tag comparisons in series on the valid-bit path.
  wire fill_at_inv = i_fill_valid && fill_index == inv_index;
  wire fill_at_inv2 = i_fill_valid && fill_index == inv2_index;
  wire store_at_inv2 = inv_index == inv2_index;
  wire inv2_store_fill = store_at_inv2 && inv_tag == inv2_tag;
  wire inv2_read_fill = fill_at_inv2 && fill_tag == inv2_tag;
  wire inv2_store_replaces = store_at_inv2 && inv_tag != inv2_tag;
  wire inv2_read_replaces = fill_at_inv2 && fill_tag != inv2_tag;
  assign invalidate_fill_entry = i_invalidate_valid && !store_update &&
      fill_at_inv && fill_tag == inv_tag;
  assign invalidate_existing_entry = i_invalidate_valid && !store_update &&
      valid[inv_index] && inv_tag_match && !(fill_at_inv && fill_tag != inv_tag);
  assign invalidate2_fill_entry = i_invalidate2_valid &&
      (store_update ? inv2_store_fill : inv2_read_fill);
  assign invalidate2_existing_entry = i_invalidate2_valid &&
      valid[inv2_index] && inv2_tag_match &&
      !(store_update ? inv2_store_replaces : inv2_read_replaces);
  // Three-bit comparisons fit one LUT6. Keep two balanced reduction levels
  // instead of allowing the wide tag equality to become a carry chain after
  // the asynchronous tag RAM, on the same-cycle load-launch path.
  localparam int unsigned TagChunks = (TagWidth + 2) / 3;
  localparam int unsigned TagGroups = (TagChunks + 5) / 6;
  (* keep = "true" *)logic [TagChunks-1:0] lookup_tag_chunks;
  (* keep = "true" *)logic [TagGroups-1:0] lookup_tag_groups;
  (* keep = "true" *) logic [TagChunks-1:0] inv_tag_chunks, inv2_tag_chunks;
  (* keep = "true" *) logic [TagGroups-1:0] inv_tag_groups, inv2_tag_groups;
  wire inv_tag_match = &inv_tag_groups;
  wire inv2_tag_match = &inv2_tag_groups;
  for (genvar c = 0; c < TagChunks; c++) begin : gen_lookup_tag_chunk
    localparam int unsigned Bits = (TagWidth - 3 * c < 3) ? TagWidth - 3 * c : 3;
    assign lookup_tag_chunks[c] = tag_lookup_rd[3*c+:Bits] == lookup_tag[3*c+:Bits];
    assign inv_tag_chunks[c] = tag_inv_rd[3*c+:Bits] == inv_tag[3*c+:Bits];
    assign inv2_tag_chunks[c] = tag_inv2_rd[3*c+:Bits] == inv2_tag[3*c+:Bits];
  end
  for (genvar g = 0; g < TagGroups; g++) begin : gen_lookup_tag_group
    localparam int unsigned Chunks = (TagChunks - 6 * g < 6) ? TagChunks - 6 * g : 6;
    assign lookup_tag_groups[g] = &lookup_tag_chunks[6*g+:Chunks];
    assign inv_tag_groups[g] = &inv_tag_chunks[6*g+:Chunks];
    assign inv2_tag_groups[g] = &inv2_tag_chunks[6*g+:Chunks];
  end
`ifndef SYNTHESIS
  always_comb begin
    if (reset_seen_q && i_rst_n) begin
      p_fill_write_matches_fill_valid : assert (i_fill_write == i_fill_valid);
    end
  end
`endif
  assign lookup_hit_array = valid[lookup_index] && (&lookup_tag_groups);
  // No same-cycle fill forwarding, for timing. A filled line is visible
  // on the next cycle.
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
      if (ram_write) begin
        valid[ram_index] <= 1'b1;
      end

      // A fill at the invalidated index wins only if it has a different tag.
      // For matching tags, invalidation wins to prevent stale response data
      // from refilling a dword written by a concurrent store.
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
`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    p_tag_reduction_exact :
    assert (lookup_hit_array == (valid[lookup_index] && (tag_lookup_rd == lookup_tag)));
    p_store_tag_reduction_exact : assert (inv_tag_match == (tag_inv_rd == inv_tag));
    p_amo_tag_reduction_exact : assert (inv2_tag_match == (tag_inv2_rd == inv2_tag));
    p_store_fill_invalidate_exact :
    assert (invalidate_fill_entry ==
        (i_invalidate_valid && !store_update && ram_write &&
         ram_index == inv_index && ram_tag == inv_tag));
    p_store_existing_invalidate_exact :
    assert (invalidate_existing_entry ==
        (i_invalidate_valid && !store_update && valid[inv_index] && tag_inv_rd == inv_tag &&
         !(ram_write && ram_index == inv_index && ram_tag != inv_tag)));
    p_amo_fill_invalidate_exact :
    assert (invalidate2_fill_entry ==
        (i_invalidate2_valid && ram_write && ram_index == inv2_index && ram_tag == inv2_tag));
    p_amo_existing_invalidate_exact :
    assert (invalidate2_existing_entry ==
        (i_invalidate2_valid && valid[inv2_index] && tag_inv2_rd == inv2_tag &&
         !(ram_write && ram_index == inv2_index && ram_tag != inv2_tag)));
  end
`endif
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end
  // The LQ drives both fill inputs with the same value.
  always_comb assume (i_fill_write == i_fill_valid);

  // -------------------------------------------------------------------------
  // Assertions
  // -------------------------------------------------------------------------

  // MMIO addresses never hit
  always_comb begin
    if (i_rst_n && lookup_mmio) begin
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

  // A cacheable fill hits on the next cycle unless invalidated or replaced.
  reg [                  XLEN-1:0] f_fill_addr_q;
  reg [riscv_pkg::MemDataBits-1:0] f_fill_data_q;
  reg                              f_fill_valid_q;
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_fill_valid_q <= 1'b0;
      f_fill_addr_q  <= '0;
    end else begin
      f_fill_valid_q <= i_fill_valid & !store_update & ~i_flush_all & !invalidate_fill_entry &
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
        && !lookup_mmio
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

  // A store updating a known dword changes exactly its selected byte lanes.
  // Observe the pre-store word through the independent lookup port; the
  // antecedent requires that port to name this store's address.
  logic f_store_valid_q;
  logic [XLEN-1:0] f_store_addr_q;
  logic [63:0] f_store_expected_q;
  always_ff @(posedge i_clk) begin
    f_store_valid_q <= i_rst_n && store_update && !i_flush_all &&
        (i_lookup_addr[riscv_pkg::PhysAddrBits-1:3] ==
         i_invalidate_addr[riscv_pkg::PhysAddrBits-1:3]) &&
        !invalidate2_fill_entry &&
        !(i_invalidate_line_valid &&
          (i_invalidate_line_addr[5+:(IndexWidth-2)] ==
           i_invalidate_addr[5+:(IndexWidth-2)]));
    f_store_addr_q <= i_invalidate_addr;
    for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
      f_store_expected_q[byte_idx*8+:8] <= i_store_strb[byte_idx] ?
          i_store_data[byte_idx*8+:8] : data_lookup_rd[byte_idx*8+:8];
    end
    if (f_past_valid && i_rst_n && f_store_valid_q && !i_flush_all &&
        i_lookup_addr[riscv_pkg::PhysAddrBits-1:3] == f_store_addr_q[riscv_pkg::PhysAddrBits-1:3] &&
        !lookup_mmio && !lookup_invalidated && !lookup_line_invalidated) begin
      p_store_then_hit : assert (o_lookup_hit);
      p_store_bytes_exact : assert (o_lookup_data == f_store_expected_q);
    end
    cover (f_store_valid_q && !(&i_store_strb));
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

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // DMA clears all four indexed dwords even when a response fills one.
  cover_dma_invalidation_overrides_fill :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      !i_flush_all && i_fill_valid && i_invalidate_line_valid &&
      (fill_index[IndexWidth-1:2] == i_invalidate_line_addr[5+:(IndexWidth-2)]));
  // AMO completion invalidates a matching response fill on the same edge.
  cover_amo_invalidation_overrides_fill :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      !i_flush_all && i_fill_valid && !store_update && invalidate2_fill_entry);
  // A store takes the RAM write port while an unrelated response fills.
  cover_store_update_displaces_fill :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      !i_flush_all && store_update && i_fill_valid && (inv_index != fill_index));
`endif
`endif

endmodule
