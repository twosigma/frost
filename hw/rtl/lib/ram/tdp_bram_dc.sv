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
 * Simple true dual-port block RAM with dual clocks.
 * This is a simplified version of tdp_bram_dc_byte_en without byte-level write
 * enables. Each port has a single write enable for full-word writes.
 * Uses write-first behavior to match the pattern Yosys recognizes for 7-series.
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

  // Memory array
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory[MemDepthInWords];
  /* verilator lint_on MULTIDRIVEN */

  // Initialize memory contents
  initial
    if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);
    else for (int i = 0; i < MemDepthInWords; ++i) memory[i] = i;

  // Address conversion from byte-addressing to word-addressing
  logic [ADDR_WIDTH-1:0] port_a_word_address, port_b_word_address;
  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];

  // Port A: Write-first behavior (matches pattern Yosys recognizes for 7-series)
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

  // Port B: Write-first behavior (matches pattern Yosys recognizes for 7-series)
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
