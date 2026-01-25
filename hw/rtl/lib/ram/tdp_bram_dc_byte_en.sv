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
 * True dual-port block RAM with dual clocks and byte-level write enables.
 * This memory module provides two independent ports (A and B) with separate clocks,
 * allowing operation across clock domains or with the same clock for both ports.
 * Each port supports byte-granular writes through per-byte write enable signals,
 * allowing partial word updates without read-modify-write cycles. The memory is
 * word-addressed internally but accepts byte addresses, automatically extracting the
 * word address. The module supports optional initialization from a hex file.
 * Both ports have single-cycle read latency with registered outputs and implement
 * write-first behavior (read returns new data immediately after write to same address).
 */
module tdp_bram_dc_byte_en #(
    parameter int unsigned DATA_WIDTH = 32,  // Data width in bits (must be multiple of 8)
    parameter int unsigned ADDR_WIDTH = 14,  // Word address width (memory depth = 2^ADDR_WIDTH)
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem"  // Optional hex file for initialization
) (
    // Port A
    input  logic                    i_port_a_clk,
    input  logic [  DATA_WIDTH-1:0] i_port_a_byte_address,
    input  logic [  DATA_WIDTH-1:0] i_port_a_write_data,
    input  logic [DATA_WIDTH/8-1:0] i_port_a_byte_write_enable,  // One bit per byte
    output logic [  DATA_WIDTH-1:0] o_port_a_read_data,

    // Port B
    input  logic                    i_port_b_clk,
    input  logic [  DATA_WIDTH-1:0] i_port_b_byte_address,
    input  logic [  DATA_WIDTH-1:0] i_port_b_write_data,
    input  logic [DATA_WIDTH/8-1:0] i_port_b_byte_write_enable,  // One bit per byte
    output logic [  DATA_WIDTH-1:0] o_port_b_read_data
);

  // Validate DATA_WIDTH is a multiple of 8 (required for byte enables)
  initial begin
    if (DATA_WIDTH % 8 != 0)
      $fatal(1, "DATA_WIDTH must be a multiple of 8 for byte-enable functionality");
  end

  // Derived parameters
  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned ByteAddrBits = $clog2(NumBytes);  // Bits for byte offset within word
  localparam int unsigned MemDepthInWords = 2 ** ADDR_WIDTH;

  // Memory array.
  // Not all simulators support dual clock memory without warning about driven by multiple clocks.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory[MemDepthInWords];
  /* verilator lint_on MULTIDRIVEN */

  // Initialize memory contents
  initial
    if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);
    // Initialize with non-zero pattern to catch bugs where code assumes zero-init
    else
      for (int i = 0; i < MemDepthInWords; ++i) memory[i] = i;

  // Address conversion from byte-addressing to word-addressing
  // Lower bits are byte offset within word, remaining bits are word address
  logic [ADDR_WIDTH-1:0] port_a_word_address, port_b_word_address;
  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];

  // Port A: Write-first behavior (read returns new data immediately after write)
  // Generate separate logic for each byte to enable byte-level writes
  generate
    for (genvar byte_index = 0; byte_index < NumBytes; ++byte_index) begin : gen_port_a_byte_logic
      always @(posedge i_port_a_clk)
        if (i_port_a_byte_write_enable[byte_index]) begin
          // Write this byte to memory
          memory[port_a_word_address][byte_index*8+:8] <= i_port_a_write_data[byte_index*8+:8];
          // Write-first: forward written data directly to output
          o_port_a_read_data[byte_index*8+:8] <= i_port_a_write_data[byte_index*8+:8];
        end else begin
          // Read this byte from memory
          o_port_a_read_data[byte_index*8+:8] <= memory[port_a_word_address][byte_index*8+:8];
        end
    end
  endgenerate

  // Port B: Write-first behavior (read returns new data immediately after write)
  // Generate separate logic for each byte to enable byte-level writes
  generate
    for (genvar byte_index = 0; byte_index < NumBytes; ++byte_index) begin : gen_port_b_byte_logic
      always @(posedge i_port_b_clk)
        if (i_port_b_byte_write_enable[byte_index]) begin
          // Write this byte to memory
          memory[port_b_word_address][byte_index*8+:8] <= i_port_b_write_data[byte_index*8+:8];
          // Write-first: forward written data directly to output
          o_port_b_read_data[byte_index*8+:8] <= i_port_b_write_data[byte_index*8+:8];
        end else begin
          // Read this byte from memory
          o_port_b_read_data[byte_index*8+:8] <= memory[port_b_word_address][byte_index*8+:8];
        end
    end
  endgenerate

endmodule : tdp_bram_dc_byte_en
