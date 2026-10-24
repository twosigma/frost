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
 * Dual-clock true dual-port block RAM with byte write enables and optional
 * hex initialization. Ports accept byte addresses and have one-cycle,
 * write-first reads.
 *
 * The ASIC flow defines FROST_SRAM_MACROS and keeps the array in SRAM
 * macros, frost_sram_2rw (asic/sram), which build only 64-bit words with
 * byte enables. There a port's read data after a cycle that writes it is
 * undefined, not write-first: the macros do not read and write a port in the
 * same cycle. The data memory's users read a port only in cycles that do not
 * write it. As with the block RAM, a read of a word that the other port
 * writes at the same time is undefined.
 */
module tdp_bram_dc_byte_en #(
    parameter int unsigned DATA_WIDTH = 32,  // Data width in bits (must be multiple of 8)
    parameter int unsigned ADDR_WIDTH = 14,  // Word address width (memory depth = 2^ADDR_WIDTH)
    parameter bit USE_INIT_FILE = 1'b1,
    // Hex image name, at most 8 characters to fit these 64 bits. The 64-bit
    // data tier passes "sw64.mem", its dword-token image.
    parameter bit [63:0] INIT_FILE = "sw.mem"
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

  initial begin
    if (DATA_WIDTH % 8 != 0)
      $fatal(1, "DATA_WIDTH must be a multiple of 8 for byte-enable functionality");
  end

  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned ByteAddrBits = $clog2(NumBytes);  // Bits for byte offset within word
  localparam int unsigned MemDepthInWords = 2 ** ADDR_WIDTH;

`ifndef FROST_SRAM_MACROS
  // Both ports drive this array, which some simulators flag as multiply driven.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory[MemDepthInWords];
  /* verilator lint_on MULTIDRIVEN */

  initial begin
    if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);
    else begin
`ifdef FROST_RANDOM_START
      for (int row = 0; row < MemDepthInWords; row++)
      for (int chunk = 0; chunk < (DATA_WIDTH + 31) / 32; chunk++)
      memory[row] = (memory[row] << 32) | DATA_WIDTH'($urandom);
`else
      // The non-zero fill catches code that assumes zero-initialized memory.
      for (int i = 0; i < MemDepthInWords; ++i) memory[i] = DATA_WIDTH'(i);
`endif
    end
  end
`endif

  // Byte address to word address: drop the low ByteAddrBits byte-offset bits.
  logic [ADDR_WIDTH-1:0] port_a_word_address, port_b_word_address;
  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];

`ifdef FROST_SRAM_MACROS
  frost_sram_2rw #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .MASK_GRANULE(8),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE)
  ) u_sram (
      .i_port_a_clock(i_port_a_clk),
      .i_port_a_write_mask(i_port_a_byte_write_enable),
      .i_port_a_address(port_a_word_address),
      .i_port_a_write_data,
      .o_port_a_read_data,
      .i_port_b_clock(i_port_b_clk),
      .i_port_b_write_mask(i_port_b_byte_write_enable),
      .i_port_b_address(port_b_word_address),
      .i_port_b_write_data,
      .o_port_b_read_data
  );
`else
  // Port A: written bytes bypass the RAM to provide write-first reads.
  generate
    for (genvar byte_index = 0; byte_index < NumBytes; ++byte_index) begin : gen_port_a_byte_logic
      always @(posedge i_port_a_clk)
        if (i_port_a_byte_write_enable[byte_index]) begin
          memory[port_a_word_address][byte_index*8+:8] <= i_port_a_write_data[byte_index*8+:8];
          o_port_a_read_data[byte_index*8+:8] <= i_port_a_write_data[byte_index*8+:8];
        end else begin
          o_port_a_read_data[byte_index*8+:8] <= memory[port_a_word_address][byte_index*8+:8];
        end
    end
  endgenerate

  // Port B: write-first reads.
  generate
    for (genvar byte_index = 0; byte_index < NumBytes; ++byte_index) begin : gen_port_b_byte_logic
      always @(posedge i_port_b_clk)
        if (i_port_b_byte_write_enable[byte_index]) begin
          memory[port_b_word_address][byte_index*8+:8] <= i_port_b_write_data[byte_index*8+:8];
          o_port_b_read_data[byte_index*8+:8] <= i_port_b_write_data[byte_index*8+:8];
        end else begin
          o_port_b_read_data[byte_index*8+:8] <= memory[port_b_word_address][byte_index*8+:8];
        end
    end
  endgenerate
`endif

endmodule : tdp_bram_dc_byte_en
