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
 * Cache Hit Detector
 *
 * Determines whether a load instruction can be satisfied from the L0 cache.
 * This module evaluates cache tag matches, valid bits, and access type to
 * produce a single cache_hit_on_load signal.
 *
 * Timing Optimization:
 * ====================
 * This module is structured to minimize logic depth for the cache hit signal:
 *   - Pre-compute validity checks for each access type in parallel
 *   - Tag comparison runs in parallel with validity checks
 *   - Final hit is a flat AND of three terms
 *
 * Late-arriving signals (from cache RAM read):
 *   - Tag bits (for tag_match comparison)
 *   - Valid bits (for data_valid_for_access_type)
 *
 * Early-arriving signals (registered from previous stage):
 *   - is_load_instruction, is_load_byte, is_load_halfword
 *
 * Related Modules:
 *   - l0_cache.sv: Instantiates this module
 *   - load_unit.sv: Uses cached data when hit occurs
 */
module cache_hit_detector #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned CacheTagWidth = 7,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000
) (
    // Cache entry from RAM (late-arriving)
    input logic [CacheTagWidth-1:0] i_cache_tag,
    input logic [XLEN/8-1:0] i_cache_valid_bits,

    // Address information (late-arriving, from EX stage)
    input logic [CacheTagWidth-1:0] i_address_tag,
    input logic [1:0] i_byte_offset,
    input logic [XLEN-1:0] i_full_address,

    // Load type flags (early-arriving, registered from ID stage)
    input logic i_is_load_instruction,
    input logic i_is_load_byte,
    input logic i_is_load_halfword,

    // Output
    output logic o_cache_hit_on_load
);

  // ===========================================================================
  // Address Checks
  // ===========================================================================
  logic is_memory_mapped_io;

  assign is_memory_mapped_io = i_full_address >= MMIO_ADDR;

  // ===========================================================================
  // Validity Checks (parallel with tag comparison)
  // ===========================================================================
  // Pre-compute validity checks for each access type.
  // These can start as soon as cache read completes, in parallel with tag comparison.

  logic all_bytes_valid;
  logic selected_byte_valid;
  logic upper_halfword_valid;
  logic lower_halfword_valid;

  assign all_bytes_valid = &i_cache_valid_bits;
  assign upper_halfword_valid = &i_cache_valid_bits[3:2];
  assign lower_halfword_valid = &i_cache_valid_bits[1:0];

  // Byte validity: 4:1 mux based on address offset (flat structure)
  always_comb begin
    unique case (i_byte_offset)
      2'b00:   selected_byte_valid = i_cache_valid_bits[0];
      2'b01:   selected_byte_valid = i_cache_valid_bits[1];
      2'b10:   selected_byte_valid = i_cache_valid_bits[2];
      2'b11:   selected_byte_valid = i_cache_valid_bits[3];
      default: selected_byte_valid = 1'b0;  // X-propagation safety for 4-state simulators
    endcase
  end

  // ===========================================================================
  // Access Type Validity (AND-OR structure for timing)
  // ===========================================================================
  // Compute hit-valid terms in parallel using AND-OR structure.
  // Early signals (is_load_byte, is_load_halfword) are registered, available immediately.
  // Late signals (selected_byte_valid, etc.) depend on address and arrive at the same time.

  logic byte_hit_valid;
  logic upper_halfword_hit_valid;
  logic lower_halfword_hit_valid;
  logic word_hit_valid;
  logic data_valid_for_access_type;

  assign byte_hit_valid = i_is_load_byte && selected_byte_valid;
  assign upper_halfword_hit_valid = i_is_load_halfword && i_byte_offset[1] && upper_halfword_valid;
  assign lower_halfword_hit_valid = i_is_load_halfword && !i_byte_offset[1] && lower_halfword_valid;
  assign word_hit_valid = !i_is_load_byte && !i_is_load_halfword && all_bytes_valid;

  // Flat OR - all terms computed in parallel, then combined
  assign data_valid_for_access_type = byte_hit_valid ||
                                      upper_halfword_hit_valid ||
                                      lower_halfword_hit_valid ||
                                      word_hit_valid;

  // ===========================================================================
  // Tag Comparison (late-arriving signal, minimize logic after this)
  // ===========================================================================
  logic tag_match;
  assign tag_match = (i_cache_tag == i_address_tag);

  // ===========================================================================
  // Cache Access Eligibility
  // ===========================================================================
  // Combine conditions that don't depend on cache RAM read (tag/valid bits).
  // is_load_instruction is registered from ID stage and available early.
  logic cache_access_eligible;
  assign cache_access_eligible = i_is_load_instruction &&
                                  !is_memory_mapped_io;

  // ===========================================================================
  // Final Cache Hit
  // ===========================================================================
  // AND of three terms (flat structure):
  // - cache_access_eligible: depends on address (for MMIO check) + registered is_load_instruction
  // - tag_match: depends on address + cache tag RAM read
  // - data_valid_for_access_type: depends on address + cache valid RAM read + registered load type
  assign o_cache_hit_on_load = cache_access_eligible && tag_match && data_valid_for_access_type;

endmodule : cache_hit_detector
