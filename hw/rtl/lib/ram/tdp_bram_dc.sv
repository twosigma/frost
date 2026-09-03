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
 * True dual-port block RAM with independent port clocks. This is
 * tdp_bram_dc_byte_en without byte write enables: each port writes a full word
 * under a single write enable, and i_port_*_enable gates both the write and the
 * registered read. Reads are write-first, the pattern Yosys recognizes for
 * Xilinx block RAM inference.
 */
module tdp_bram_dc #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 14,  // Word address width (memory depth = 2^ADDR_WIDTH)
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem"
) (
    // Port A
    input  logic                  i_port_a_clk,
    input  logic                  i_port_a_enable,
    input  logic [DATA_WIDTH-1:0] i_port_a_byte_address,
    input  logic [DATA_WIDTH-1:0] i_port_a_write_data,
    input  logic                  i_port_a_write_enable,
    output logic [DATA_WIDTH-1:0] o_port_a_read_data,

    // Port B
    input  logic                  i_port_b_clk,
    input  logic                  i_port_b_enable,
    input  logic [DATA_WIDTH-1:0] i_port_b_byte_address,
    input  logic [DATA_WIDTH-1:0] i_port_b_write_data,
    input  logic                  i_port_b_write_enable,
    output logic [DATA_WIDTH-1:0] o_port_b_read_data
);

  // Derived parameters
  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned ByteAddrBits = $clog2(NumBytes);
  localparam int unsigned MemDepthInWords = 2 ** ADDR_WIDTH;

  // Both ports drive this array, which some simulators flag as multiply driven.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory[MemDepthInWords];
  /* verilator lint_on MULTIDRIVEN */

  // Contents come from INIT_FILE when USE_INIT_FILE is set. Otherwise the array
  // holds a non-zero pattern, which catches code that assumes zero-init.
  initial
    if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);
    else for (int i = 0; i < MemDepthInWords; ++i) memory[i] = i;

  // Address conversion from byte-addressing to word-addressing
  logic [ADDR_WIDTH-1:0] port_a_word_address, port_b_word_address;
  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];

  // Port A: Write-first behavior (matches Xilinx block RAM inference)
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable) begin
        memory[port_a_word_address] <= i_port_a_write_data;
        o_port_a_read_data <= i_port_a_write_data;
      end else begin
        o_port_a_read_data <= memory[port_a_word_address];
      end
    end
  end

  // Port B: Write-first behavior (matches Xilinx block RAM inference)
  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      if (i_port_b_write_enable) begin
        memory[port_b_word_address] <= i_port_b_write_data;
        o_port_b_read_data <= i_port_b_write_data;
      end else begin
        o_port_b_read_data <= memory[port_b_word_address];
      end
    end
  end

endmodule : tdp_bram_dc
