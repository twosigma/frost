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
 * This module processes raw 32-bit memory read data and extracts the appropriate
 * byte(s) based on load instruction type and address alignment. It handles all
 * RISC-V base integer load instructions:
 *
 *   LB  - Load Byte (sign-extended to 32 bits)
 *   LBU - Load Byte Unsigned (zero-extended to 32 bits)
 *   LH  - Load Halfword (sign-extended to 32 bits)
 *   LHU - Load Halfword Unsigned (zero-extended to 32 bits)
 *   LW  - Load Word (full 32 bits, no extension)
 *
 * Byte Selection Logic:
 *   - LB/LBU: addr[1:0] selects one of four bytes (0, 1, 2, or 3)
 *   - LH/LHU: addr[1] selects lower or upper halfword
 *   - LW: uses full 32-bit word
 *
 * Related Modules:
 *   - load_queue.sv: Instantiates this unit for memory and L0-cache result paths
 *   - lq_l0_cache.sv: Provides cached words that this unit extracts/sign-extends
 */
module load_unit #(
    parameter int unsigned XLEN = 32
) (
    // Load type flags (from instruction decode)
    input logic i_is_load_byte,      // LB or LBU instruction
    input logic i_is_load_halfword,  // LH or LHU instruction
    input logic i_is_load_unsigned,  // LBU or LHU (zero-extend instead of sign-extend)

    // Memory interface
    input logic [XLEN-1:0] i_data_memory_address,   // Address for byte selection
    input logic [XLEN-1:0] i_data_memory_read_data, // Raw 32-bit data from memory

    // Output
    output logic [XLEN-1:0] o_data_loaded_from_memory  // Extracted and extended result
);

  // ===========================================================================
  // Byte/Halfword Extraction and Sign/Zero Extension
  // ===========================================================================
  //
  // Memory word layout (little-endian):
  //   Byte:     [  3  |  2  |  1  |  0  ]
  //   Halfword: [   high   |   low     ]
  //   Bit:      [31:24|23:16|15:8 | 7:0]
  //
  // Address bits select position:
  //   addr[1:0] = 00 -> byte 0 (bits 7:0)
  //   addr[1:0] = 01 -> byte 1 (bits 15:8)
  //   addr[1:0] = 10 -> byte 2 (bits 23:16)
  //   addr[1:0] = 11 -> byte 3 (bits 31:24)
  //   addr[1]   = 0  -> lower halfword (bits 15:0)
  //   addr[1]   = 1  -> upper halfword (bits 31:16)
  //
  // TIMING OPTIMIZATION: Pre-compute sign-extended results for all byte/halfword
  // positions in PARALLEL. The late-arriving address (from CARRY8 chain) only
  // controls the final mux, not the sign extension logic. This breaks the path:
  //   address -> byte_select -> sign_bit_select -> sign_extension
  // Into:
  //   address -> final_mux (short)
  //   data -> sign_extension (parallel, doesn't wait for address)

  // Extract individual bytes
  logic [7:0] byte0, byte1, byte2, byte3;
  assign byte0 = i_data_memory_read_data[7:0];
  assign byte1 = i_data_memory_read_data[15:8];
  assign byte2 = i_data_memory_read_data[23:16];
  assign byte3 = i_data_memory_read_data[31:24];

  // Pre-compute sign-extended bytes (all 4 in parallel)
  logic [XLEN-1:0] byte0_ext, byte1_ext, byte2_ext, byte3_ext;
  assign byte0_ext = {{(XLEN - 8) {i_is_load_unsigned ? 1'b0 : byte0[7]}}, byte0};
  assign byte1_ext = {{(XLEN - 8) {i_is_load_unsigned ? 1'b0 : byte1[7]}}, byte1};
  assign byte2_ext = {{(XLEN - 8) {i_is_load_unsigned ? 1'b0 : byte2[7]}}, byte2};
  assign byte3_ext = {{(XLEN - 8) {i_is_load_unsigned ? 1'b0 : byte3[7]}}, byte3};

  // Extract halfwords
  logic [15:0] half_lo, half_hi;
  assign half_lo = i_data_memory_read_data[15:0];
  assign half_hi = i_data_memory_read_data[31:16];

  // Pre-compute sign-extended halfwords (both in parallel)
  logic [XLEN-1:0] half_lo_ext, half_hi_ext;
  assign half_lo_ext = {{(XLEN - 16) {i_is_load_unsigned ? 1'b0 : half_lo[15]}}, half_lo};
  assign half_hi_ext = {{(XLEN - 16) {i_is_load_unsigned ? 1'b0 : half_hi[15]}}, half_hi};

  // Final mux: address selects pre-computed result
  // Late-arriving address only controls this final selection
  logic [XLEN-1:0] byte_result;
  logic [XLEN-1:0] halfword_result;

  always_comb begin
    case (i_data_memory_address[1:0])
      2'b00:   byte_result = byte0_ext;
      2'b01:   byte_result = byte1_ext;
      2'b10:   byte_result = byte2_ext;
      2'b11:   byte_result = byte3_ext;
      default: byte_result = byte0_ext;
    endcase
  end

  assign halfword_result = i_data_memory_address[1] ? half_hi_ext : half_lo_ext;

  // Type selection: is_load_byte and is_load_halfword are registered (early)
  assign o_data_loaded_from_memory =
      i_is_load_byte     ? byte_result :
      i_is_load_halfword ? halfword_result :
      i_data_memory_read_data;

endmodule : load_unit
