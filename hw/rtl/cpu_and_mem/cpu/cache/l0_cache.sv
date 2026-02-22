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
 * Level-0 Data Cache - Fast memory access in the EX stage
 *
 * This direct-mapped cache reduces memory access latency by storing recently accessed
 * data close to the CPU. The cache uses distributed RAM for single-cycle access and
 * supports byte-level write granularity through separate byte-wide RAMs.
 *
 * Submodules:
 * ===========
 *   l0_cache
 *   ├── cache_hit_detector      Cache hit detection logic
 *   └── cache_write_controller  Cache write enable and data muxing
 *
 * Features:
 * =========
 *   - Direct-mapped, write-through cache
 *   - Byte-level write granularity (separate RAMs per byte)
 *   - MMIO address bypass for peripheral access
 *   - Sequential valid bit clearing on reset
 *   - AMO (atomic) operation support
 *
 * Related Modules:
 *   - cache_hit_detector.sv: Determines cache hits for load instructions
 *   - cache_write_controller.sv: Manages write enable priority and data selection
 *   - load_unit.sv: Extracts and sign-extends cached data
 */
module l0_cache #(
    parameter int unsigned CACHE_DEPTH = 128,
    parameter int unsigned XLEN = 32,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input riscv_pkg::from_ma_comb_t i_from_ma_comb,
    // FP store write interface (MA stage override)
    input logic i_fp_mem_write_active,
    input logic [XLEN-1:0] i_fp_mem_address,
    input logic [XLEN-1:0] i_fp_mem_write_data,
    input logic [XLEN/8-1:0] i_fp_mem_byte_write_enable,
    // A extension: AMO write interface for cache coherence
    input riscv_pkg::amo_interface_t i_amo,
    // Outputs to Forwarding Unit, Hazard Resolution Unit
    output riscv_pkg::from_cache_t o_from_cache
);

  logic is_memory_mapped_io_ex, is_memory_mapped_io_ma;

  // Cache sizing parameters
  localparam int unsigned CacheIndexWidth = $clog2(CACHE_DEPTH);
  logic [CacheIndexWidth-1:0] cache_reset_index;  // Counter for sequential reset
  logic cache_reset_in_progress;

  // Cache addressing - bottom 2 bits ignored (word-aligned 32-bit access)
  localparam int unsigned CacheTagWidth = (MEM_BYTE_ADDR_WIDTH - 2) - CacheIndexWidth;

  // Cache entry structure: data + tag + valid bits
  typedef struct packed {
    logic [XLEN/8-1:0][7:0]   data;   // 4 bytes of data
    logic [CacheTagWidth-1:0] tag;    // Tag (upper address bits)
    logic [XLEN/8-1:0]        valid;  // Valid bit per byte (4 bits)
  } cache_entry_t;

  cache_entry_t cache_read_entry_ex, cache_read_entry_ma;
  // Workaround for Icarus Verilog simulator compatibility
  logic [XLEN/8-1:0][7:0] cache_read_entry_ex_data_bytes;
  assign cache_read_entry_ex.data = cache_read_entry_ex_data_bytes;

  logic cache_hit_on_load_comb;
  logic [XLEN-1:0] data_loaded_from_cache_comb;
  logic cache_hit_on_load_reg;
  logic [XLEN-1:0] data_loaded_from_cache_reg;

  logic [CacheIndexWidth-1:0] cache_index_ex, cache_index_ma;
  logic [CacheTagWidth-1:0] tag_ex, tag_ma;
  logic cache_write_enable;
  logic [XLEN/8-1:0] cache_byte_write_enable;
  logic [CacheIndexWidth-1:0] cache_write_index, cache_read_index;
  logic [XLEN-1:0] cache_write_data;
  logic [CacheTagWidth-1:0] cache_write_tag;
  logic [XLEN/8-1:0] cache_write_valid;

  // Extract cache index and tag from memory address
  assign cache_index_ex = i_from_ex_comb.data_memory_address[2+:CacheIndexWidth];
  assign tag_ex = i_from_ex_comb.data_memory_address[(2+CacheIndexWidth)+:CacheTagWidth];
  // Check if address is memory-mapped I/O (bypass cache for peripherals)
  assign is_memory_mapped_io_ex = i_from_ex_comb.data_memory_address >= MMIO_ADDR;

  // ===========================================================================
  // Cache Write Controller
  // ===========================================================================
  // Handles write enable priority (AMO > Store > Load) and data/tag/valid muxing.
  // See cache_write_controller.sv for timing optimization details.

  cache_write_controller #(
      .XLEN(XLEN),
      .CacheIndexWidth(CacheIndexWidth),
      .CacheTagWidth(CacheTagWidth),
      .MMIO_ADDR(MMIO_ADDR)
  ) cache_write_controller_inst (
      .i_clk,
      .i_rst,
      // Pipeline control
      .i_stall(i_pipeline_ctrl.stall),
      .i_stall_for_trap_check(i_pipeline_ctrl.stall_for_trap_check),
      .i_flush(i_pipeline_ctrl.flush),
      // From EX stage (store path)
      .i_data_memory_address_ex(i_from_ex_comb.data_memory_address),
      .i_data_memory_write_data_ex(i_from_ex_comb.data_memory_write_data),
      .i_data_memory_byte_write_enable_ex(i_from_ex_comb.data_memory_byte_write_enable),
      .i_cache_index_ex(cache_index_ex),
      .i_tag_ex(tag_ex),
      // From MA stage (load path)
      .i_is_load_instruction_ma(i_from_ex_to_ma.is_load_instruction),
      .i_is_memory_mapped_io_ma(is_memory_mapped_io_ma),
      .i_cache_hit_on_load(cache_hit_on_load_reg),
      .i_data_memory_read_data_ma(i_from_ma_comb.data_memory_read_data),
      .i_cache_index_ma(cache_index_ma),
      .i_tag_ma(tag_ma),
      // AMO interface
      .i_amo,
      // FP store override
      .i_fp_mem_write_active,
      .i_fp_mem_address,
      .i_fp_mem_write_data,
      .i_fp_mem_byte_write_enable,
      // Current cache entry (for valid bit merging)
      .i_cache_read_tag(cache_read_entry_ex.tag),
      .i_cache_read_valid(cache_read_entry_ex.valid),
      // Outputs
      .o_cache_write_enable(cache_write_enable),
      .o_cache_byte_write_enable(cache_byte_write_enable),
      .o_cache_write_index(cache_write_index),
      .o_cache_write_data(cache_write_data),
      .o_cache_write_tag(cache_write_tag),
      .o_cache_write_valid(cache_write_valid)
  );

  // ===========================================================================
  // Cache Hit Detection
  // ===========================================================================
  // See cache_hit_detector.sv for detailed implementation and timing optimization.

  cache_hit_detector #(
      .XLEN(XLEN),
      .CacheTagWidth(CacheTagWidth),
      .MEM_BYTE_ADDR_WIDTH(MEM_BYTE_ADDR_WIDTH),
      .MMIO_ADDR(MMIO_ADDR)
  ) cache_hit_detector_inst (
      // Cache entry from RAM
      .i_cache_tag(cache_read_entry_ex.tag),
      .i_cache_valid_bits(cache_read_entry_ex.valid),

      // Address information
      .i_address_tag (tag_ex),
      .i_byte_offset (i_from_ex_comb.data_memory_address[1:0]),
      .i_full_address(i_from_ex_comb.data_memory_address),

      // Load type flags
      .i_is_load_instruction(i_from_id_to_ex.is_load_instruction),
      .i_is_load_byte(i_from_id_to_ex.is_load_byte),
      .i_is_load_halfword(i_from_id_to_ex.is_load_halfword),

      // Output
      .o_cache_hit_on_load(cache_hit_on_load_comb)
  );

  // Cache data storage - separate distributed RAM per byte for granular writes
  // This allows writing individual bytes without read-modify-write cycles
  generate
    for (genvar byte_index = 0; byte_index < XLEN / 8; ++byte_index) begin : gen_cache_data_rams
      // RAM for data byte storage (one per byte position)
      sdp_dist_ram #(
          .ADDR_WIDTH(CacheIndexWidth),
          .DATA_WIDTH(8)
      ) cache_data_byte_ram (
          .i_clk,
          .i_write_enable(cache_write_enable & cache_byte_write_enable[byte_index]),
          .i_write_address(cache_write_index),
          .i_read_address(cache_read_index),
          .i_write_data(cache_write_data[byte_index*8+:8]),
          .o_read_data(cache_read_entry_ex_data_bytes[byte_index])
      );
      // RAM for valid bit storage (one per byte position)
      sdp_dist_ram #(
          .ADDR_WIDTH(CacheIndexWidth),
          .DATA_WIDTH(1)
      ) cache_valid_bit_ram (
          .i_clk,
          .i_write_enable(cache_write_enable | cache_reset_in_progress),
          .i_write_address(cache_reset_in_progress ? cache_reset_index : cache_write_index),
          .i_read_address(cache_read_index),
          .i_write_data(cache_reset_in_progress ? 1'b0 : cache_write_valid[byte_index]),
          .o_read_data(cache_read_entry_ex.valid[byte_index])
      );
    end
  endgenerate
  // Cache tag storage - holds address tags for cache line validation
  sdp_dist_ram #(
      .ADDR_WIDTH(CacheIndexWidth),
      .DATA_WIDTH(CacheTagWidth)
  ) cache_tag_ram (
      .i_clk,
      .i_write_enable(cache_write_enable),
      .i_write_address(cache_write_index),
      .i_read_address(cache_read_index),
      .i_write_data(cache_write_tag),
      .o_read_data(cache_read_entry_ex.tag)
  );

  // Cache initialization - sequentially clear all valid bits on reset
  // This ensures no false cache hits during startup
  always_ff @(posedge i_clk)
    if (i_rst) begin
      cache_reset_in_progress <= 1'b1;
      cache_reset_index <= '0;
    end else if (cache_reset_index == CacheIndexWidth'(CACHE_DEPTH - 1)) begin
      cache_reset_in_progress <= 1'b0;
      cache_reset_index <= '0;
    end else if (cache_reset_in_progress) begin
      cache_reset_in_progress <= 1'b1;
      cache_reset_index <= cache_reset_index + 1;
    end

  // Cache read addressing
  assign cache_read_index = cache_index_ex;

  // Pipeline cache information from Execute to Memory stage
  always_ff @(posedge i_clk)
    if (~i_pipeline_ctrl.stall) begin
      tag_ma <= tag_ex;
      cache_index_ma <= cache_index_ex;
      cache_read_entry_ma <= cache_read_entry_ex;
    end

  // Process cached data through load unit for proper byte/halfword extraction and sign-extension
  load_unit load_unit_for_cache_data (
      .i_is_load_halfword(i_from_id_to_ex.is_load_halfword),
      .i_is_load_byte(i_from_id_to_ex.is_load_byte),
      .i_is_load_unsigned(i_from_id_to_ex.is_load_unsigned),
      .i_data_memory_address(i_from_ex_comb.data_memory_address),
      .i_data_memory_read_data(cache_read_entry_ex.data),
      .o_data_loaded_from_memory(data_loaded_from_cache_comb)
  );

  // Register cache hit/data for forwarding (timing optimization)
  // These registers capture the cache lookup result when an instruction is in EX.
  // When the instruction moves to MA, these registered values are used for:
  //   1. Hazard detection (cache_hit_on_load_reg in hazard_resolution_unit.sv)
  //   2. Data forwarding (data_loaded_from_cache_reg in forwarding_unit.sv)
  // By using registered signals for both, we ensure consistency and break the
  // critical timing path from cache lookup to stall/forwarding decisions.
  //
  always_ff @(posedge i_clk)
    if (i_rst) begin
      cache_hit_on_load_reg <= 1'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      cache_hit_on_load_reg <= cache_hit_on_load_comb;
    end
  always_ff @(posedge i_clk)
    if (~i_pipeline_ctrl.stall) begin
      data_loaded_from_cache_reg <= data_loaded_from_cache_comb;
    end

  always_ff @(posedge i_clk)
    if (i_rst) is_memory_mapped_io_ma <= 1'b0;
    else if (~i_pipeline_ctrl.stall) is_memory_mapped_io_ma <= is_memory_mapped_io_ex;

  assign o_from_cache.cache_hit_on_load = cache_hit_on_load_comb;
  assign o_from_cache.data_loaded_from_cache = data_loaded_from_cache_comb;
  assign o_from_cache.cache_hit_on_load_reg = cache_hit_on_load_reg;
  assign o_from_cache.data_loaded_from_cache_reg = data_loaded_from_cache_reg;
  assign o_from_cache.cache_reset_in_progress = cache_reset_in_progress;

endmodule : l0_cache
