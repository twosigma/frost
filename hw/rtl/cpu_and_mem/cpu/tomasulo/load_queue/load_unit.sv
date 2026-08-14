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
 * Load Unit - Data extraction and sign/zero extension for RISC-V load instructions
 *
 * Consumes one aligned MemDataBits (64-bit) beat carrying the addressed dword
 * (docs/rv64/m1_data_tier.md) and extracts the addressed byte / halfword /
 * word for the integer load types:
 *
 *   LB  - Load Byte (sign-extended)
 *   LBU - Load Byte Unsigned (zero-extended)
 *   LH  - Load Halfword (sign-extended)
 *   LHU - Load Halfword Unsigned (zero-extended)
 *   LW  - Load Word (addr[2] selects the beat's word; sign-extended at RV64)
 *   LWU - Load Word Unsigned (RV64; zero-extended)
 *
 * Doubles do not pass through this unit: the load queue consumes the full
 * beat directly for FLD and LD.
 *
 * Byte Selection Logic:
 *   - LB/LBU: addr[2:0] selects one of eight beat bytes
 *   - LH/LHU: addr[2:1] selects one of four beat halfwords
 *   - LW: addr[2] selects the low or high beat word
 *
 * Related Modules:
 *   - load_queue.sv: Instantiates this unit for memory and L0-cache result paths
 *   - lq_l0_cache.sv: Provides cached beats that this unit extracts/sign-extends
 */
module load_unit #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Load type flags (from instruction decode)
    input logic i_is_load_byte,      // LB or LBU instruction
    input logic i_is_load_halfword,  // LH or LHU instruction
    input logic i_is_load_unsigned,  // LBU or LHU (zero-extend instead of sign-extend)

    // Memory interface
    input logic [XLEN-1:0] i_data_memory_address,  // Address for lane selection
    input logic [riscv_pkg::MemDataBits-1:0] i_data_memory_read_data,  // Aligned beat

    // Output
    output logic [XLEN-1:0] o_data_loaded_from_memory  // Extracted and extended result
);

  // ===========================================================================
  // Byte/Halfword/Word Extraction and Sign/Zero Extension
  // ===========================================================================
  //
  // Beat layout (little-endian): byte lane i is byte address {addr[31:3], i}.
  //
  // TIMING OPTIMIZATION (preserved from the 32-bit version): pre-compute
  // sign-extended results for every lane in PARALLEL. The late-arriving
  // address (from a CARRY8 chain) only controls the final muxes, not the
  // sign-extension logic.

  localparam int unsigned BeatBytes = riscv_pkg::MemStrbBits;
  localparam int unsigned BeatHalves = riscv_pkg::MemDataBits / 16;
  localparam int unsigned BeatWords = riscv_pkg::MemDataBits / 32;

  // Pre-compute sign-extended bytes (all lanes in parallel)
  logic [XLEN-1:0] byte_ext[BeatBytes];
  for (genvar b = 0; b < BeatBytes; b++) begin : gen_byte_ext
    assign byte_ext[b] = {
      {(XLEN - 8) {i_is_load_unsigned ? 1'b0 : i_data_memory_read_data[b*8+7]}},
      i_data_memory_read_data[b*8+:8]
    };
  end

  // Pre-compute sign-extended halfwords (all lanes in parallel)
  logic [XLEN-1:0] half_ext[BeatHalves];
  for (genvar h = 0; h < BeatHalves; h++) begin : gen_half_ext
    assign half_ext[h] = {
      {(XLEN - 16) {i_is_load_unsigned ? 1'b0 : i_data_memory_read_data[h*16+15]}},
      i_data_memory_read_data[h*16+:16]
    };
  end

  // Word lanes with pre-computed extension (all lanes in parallel). At
  // XLEN=64 the addressed word sign-extends for LW and zero-extends for LWU
  // (i_is_load_unsigned); FP word loads arrive unsigned and their upper bits
  // are ignored at the NaN-boxing consumers.
  logic [XLEN-1:0] word_ext[BeatWords];
  for (genvar w = 0; w < BeatWords; w++) begin : gen_word_ext
    assign word_ext[w] = {
      {(XLEN - 32) {i_is_load_unsigned ? 1'b0 : i_data_memory_read_data[w*32+31]}},
      i_data_memory_read_data[w*32+:32]
    };
  end

  // Final muxes: the late-arriving address selects pre-computed results.
  logic [XLEN-1:0] byte_result;
  logic [XLEN-1:0] halfword_result;
  logic [XLEN-1:0] word_result;

  assign byte_result = byte_ext[i_data_memory_address[2:0]];
  assign halfword_result = half_ext[i_data_memory_address[2:1]];
  assign word_result = word_ext[i_data_memory_address[2]];

  // Type selection: is_load_byte and is_load_halfword are registered (early)
  assign o_data_loaded_from_memory =
      i_is_load_byte     ? byte_result :
      i_is_load_halfword ? halfword_result :
      word_result;

endmodule : load_unit
