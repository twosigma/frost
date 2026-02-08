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
 * Cache Write Controller
 *
 * Manages cache write operations for the L0 cache, handling three write sources:
 *   1. Store instructions (EX stage timing, combinational)
 *   2. Load instructions (WB stage timing, pipelined for timing optimization)
 *   3. AMO instructions (during stall, highest priority)
 *
 * Timing Optimization:
 * ====================
 * Load cache writes are pipelined by one cycle to break the critical path:
 *   forwarding -> trap -> stall -> cache_write_enable_from_load -> cache WE
 *
 * This is safe because:
 *   1. Load data is captured in forwarding_unit's register_write_data_ma
 *   2. Load-use hazards cause stalls, so dependent instructions wait
 *   3. The cache update being one cycle late doesn't affect correctness
 *
 * Store cache writes remain combinational because:
 *   1. Pipelining causes race conditions in 4-state simulators
 *   2. Store timing is less critical (stores don't stall waiting for cache)
 *
 * Write Priority:
 * ===============
 *   AMO > Store > Load (AMO occurs during stalls when store/load can't happen)
 *
 * Related Modules:
 *   - l0_cache.sv: Instantiates this module
 *   - amo_unit.sv: Generates AMO write interface
 */
module cache_write_controller #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned CacheIndexWidth = 7,
    parameter int unsigned CacheTagWidth = 7,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Pipeline control
    input logic i_stall,
    input logic i_stall_for_trap_check,
    input logic i_flush,

    // From EX stage (store path)
    input logic [XLEN-1:0] i_data_memory_address_ex,
    input logic [XLEN-1:0] i_data_memory_write_data_ex,
    input logic [XLEN/8-1:0] i_data_memory_byte_write_enable_ex,
    input logic [CacheIndexWidth-1:0] i_cache_index_ex,
    input logic [CacheTagWidth-1:0] i_tag_ex,

    // From MA stage (load path)
    input logic i_is_load_instruction_ma,
    input logic i_is_memory_mapped_io_ma,
    input logic [XLEN-1:0] i_data_memory_read_data_ma,
    input logic [CacheIndexWidth-1:0] i_cache_index_ma,
    input logic [CacheTagWidth-1:0] i_tag_ma,

    // AMO interface
    input riscv_pkg::amo_interface_t i_amo,

    // FP store write interface (MA stage override)
    input logic i_fp_mem_write_active,
    input logic [XLEN-1:0] i_fp_mem_address,
    input logic [XLEN-1:0] i_fp_mem_write_data,
    input logic [XLEN/8-1:0] i_fp_mem_byte_write_enable,

    // Current cache entry (for valid bit merging on stores)
    input logic [CacheTagWidth-1:0] i_cache_read_tag,
    input logic [XLEN/8-1:0] i_cache_read_valid,

    // Outputs
    output logic o_cache_write_enable,
    output logic [XLEN/8-1:0] o_cache_byte_write_enable,
    output logic [CacheIndexWidth-1:0] o_cache_write_index,
    output logic [XLEN-1:0] o_cache_write_data,
    output logic [CacheTagWidth-1:0] o_cache_write_tag,
    output logic [XLEN/8-1:0] o_cache_write_valid
);

  // ===========================================================================
  // MMIO Detection for AMO
  // ===========================================================================
  logic is_memory_mapped_io_amo;
  assign is_memory_mapped_io_amo = i_amo.write_address >= MMIO_ADDR;

  // MMIO Detection for FP store
  logic is_memory_mapped_io_fp;
  assign is_memory_mapped_io_fp = i_fp_mem_address >= MMIO_ADDR;

  // ===========================================================================
  // Store Write Enable (Combinational - EX Stage Timing)
  // ===========================================================================
  // NOTE: Pipelining store cache writes was attempted but causes race conditions
  // in 4-state simulators. Keep stores combinational for correctness.
  logic is_memory_mapped_io_ex;
  assign is_memory_mapped_io_ex = i_data_memory_address_ex >= MMIO_ADDR;

  logic cache_write_enable_from_store;
  // Don't gate store writes with stall here; repeated writes while stalled are
  // idempotent, and the external memory write is already stall-gated.
  assign cache_write_enable_from_store = |i_data_memory_byte_write_enable_ex &
                                         ~is_memory_mapped_io_ex;

  // Select store index independent of stall to avoid pulling stall logic into the
  // cache write address path. Write enable still gates the actual write.
  logic store_write_select;
  assign store_write_select = |i_data_memory_byte_write_enable_ex & ~is_memory_mapped_io_ex;

  // ===========================================================================
  // FP Store Write Enable (MA Stage Override)
  // ===========================================================================
  logic cache_write_enable_from_fp_store;
  assign cache_write_enable_from_fp_store = i_fp_mem_write_active &
                                            (|i_fp_mem_byte_write_enable) &
                                            ~is_memory_mapped_io_fp;

  // ===========================================================================
  // Load Write Enable (Pipelined - WB Stage Timing)
  // ===========================================================================
  logic cache_write_enable_from_load_registered;
  logic [XLEN-1:0] load_write_data_registered;
  logic [CacheIndexWidth-1:0] cache_index_load_registered;
  logic [CacheTagWidth-1:0] tag_load_registered;

  // Load write enable - needs flush gating (uses flush on critical path)
  always_ff @(posedge i_clk)
    if (i_rst || i_flush) cache_write_enable_from_load_registered <= 1'b0;
    else if (~i_stall)
      cache_write_enable_from_load_registered <= i_is_load_instruction_ma &
                                        ~i_is_memory_mapped_io_ma;

  // Load data, index, tag - don't need flush gating (enable is cleared)
  always_ff @(posedge i_clk)
    if (~i_stall) begin
      load_write_data_registered <= i_data_memory_read_data_ma;
      cache_index_load_registered <= i_cache_index_ma;
      tag_load_registered <= i_tag_ma;
    end

  logic cache_write_enable_from_load;
  assign cache_write_enable_from_load = cache_write_enable_from_load_registered;

  // ===========================================================================
  // AMO Write Enable
  // ===========================================================================
  logic cache_write_enable_from_amo;
  assign cache_write_enable_from_amo = i_amo.write_enable & ~is_memory_mapped_io_amo;

  // Track previous cycle's AMO write enable to block stale load writes.
  // When AMO stall ends, the frozen load write enable would fire on the same
  // cycle. This register allows us to block the load write for one cycle
  // after AMO completes.
  logic amo_write_enable_prev;
  always_ff @(posedge i_clk)
    if (i_rst) amo_write_enable_prev <= 1'b0;
    else amo_write_enable_prev <= i_amo.write_enable;

  // ===========================================================================
  // Combined Write Enable and Byte Enable
  // ===========================================================================
  // Block load write on the cycle immediately after AMO write to prevent
  // stale load data (frozen during AMO stall) from overwriting AMO result.
  assign o_cache_write_enable = cache_write_enable_from_store ||
                                cache_write_enable_from_amo ||
                                cache_write_enable_from_fp_store ||
                                (cache_write_enable_from_load && ~amo_write_enable_prev);

  // For stores, use EX stage per-byte write enables; for loads/AMO/FP stores, write all bytes
  assign o_cache_byte_write_enable =
      cache_write_enable_from_amo ? '1 :
      cache_write_enable_from_fp_store ? i_fp_mem_byte_write_enable :
      cache_write_enable_from_store ? i_data_memory_byte_write_enable_ex :
      '1;

  // ===========================================================================
  // Write Index Selection (Priority: AMO > Store > Load)
  // ===========================================================================
  logic [CacheIndexWidth-1:0] cache_index_amo;
  assign cache_index_amo = i_amo.write_address[2+:CacheIndexWidth];
  logic [CacheIndexWidth-1:0] cache_index_fp;
  assign cache_index_fp = i_fp_mem_address[2+:CacheIndexWidth];

  assign o_cache_write_index = i_amo.write_enable ? cache_index_amo :
                               cache_write_enable_from_fp_store ? cache_index_fp :
                               store_write_select ? i_cache_index_ex :
                               cache_index_load_registered;

  // ===========================================================================
  // Write Data Selection
  // ===========================================================================
  assign o_cache_write_data = cache_write_enable_from_amo ? i_amo.write_data :
                              cache_write_enable_from_fp_store ? i_fp_mem_write_data :
                              cache_write_enable_from_store ? i_data_memory_write_data_ex :
                              load_write_data_registered;

  // ===========================================================================
  // Write Tag Selection
  // ===========================================================================
  logic [CacheTagWidth-1:0] tag_amo;
  assign tag_amo = i_amo.write_address[(2+CacheIndexWidth)+:CacheTagWidth];
  logic [CacheTagWidth-1:0] tag_fp;
  assign tag_fp = i_fp_mem_address[(2+CacheIndexWidth)+:CacheTagWidth];

  assign o_cache_write_tag = cache_write_enable_from_amo ? tag_amo :
                             cache_write_enable_from_fp_store ? tag_fp :
                             cache_write_enable_from_store ? i_tag_ex :
                             tag_load_registered;

  // ===========================================================================
  // Write Valid Bits Selection
  // ===========================================================================
  // For AMO: all bytes are valid (word-only access)
  // For stores: if tag matches, OR new bytes with existing; otherwise only new bytes
  // For loads/FP stores: all bytes become valid
  assign o_cache_write_valid = cache_write_enable_from_amo ?
      '1 : cache_write_enable_from_fp_store ?
      '1 : cache_write_enable_from_store ?
      (i_cache_read_tag == i_tag_ex ?
      (o_cache_byte_write_enable | i_cache_read_valid) :
      o_cache_byte_write_enable) :
    '1;

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL

  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // MMIO stores don't write cache: if address is in MMIO range and
      // byte write enables are active, cache store write must be off.
      p_mmio_store_no_cache :
      assert (!(is_memory_mapped_io_ex &&
          |i_data_memory_byte_write_enable_ex) || !cache_write_enable_from_store);

      // MMIO AMO doesn't write cache.
      p_mmio_amo_no_cache : assert (!is_memory_mapped_io_amo || !cache_write_enable_from_amo);

      // AMO byte enable is all-ones when AMO write is active.
      p_amo_byte_enable_all :
      assert (!cache_write_enable_from_amo || (o_cache_byte_write_enable == '1));

      // Store valid bit merging: on tag match, new valid bits include old.
      // When store writes and tags match, output valid bits OR old with new.
      p_store_valid_merge :
      assert (!(cache_write_enable_from_store &&
          !cache_write_enable_from_amo && !cache_write_enable_from_fp_store &&
          (i_cache_read_tag == i_tag_ex)) ||
          (o_cache_write_valid == (o_cache_byte_write_enable | i_cache_read_valid)));
    end

    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // AMO stale load prevention: after AMO write, load write is blocked.
      if ($past(i_amo.write_enable)) begin
        p_amo_stale_prevention : assert (amo_write_enable_prev);
      end

      // Reset clears pipelined load write enable and amo_write_enable_prev.
      if ($past(i_rst)) begin
        p_reset_load_we : assert (!cache_write_enable_from_load_registered);
        p_reset_amo_prev : assert (!amo_write_enable_prev);
      end
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_store_write : cover (cache_write_enable_from_store);
      cover_load_write : cover (cache_write_enable_from_load);
      cover_amo_write : cover (cache_write_enable_from_amo);
      cover_fp_store_write : cover (cache_write_enable_from_fp_store);
      cover_stale_load_blocked : cover (cache_write_enable_from_load && amo_write_enable_prev);
    end
  end

`endif  // FORMAL

endmodule : cache_write_controller
