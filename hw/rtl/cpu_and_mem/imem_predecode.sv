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
 * Instruction Memory with Predecode Sideband
 *
 * Wraps a true dual-port BRAM that stores 32 bits of instruction data plus
 * 2 bits of predecode metadata per word.  The sideband bits encode whether
 * each 16-bit halfword is a compressed (C-extension) instruction:
 *
 *   sideband[0] = (word[1:0]   != 2'b11)  -- low  halfword is compressed
 *   sideband[1] = (word[17:16] != 2'b11)  -- high halfword is compressed
 *
 * These bits are computed at write time (Port A) and stored alongside the
 * instruction data.  On the fetch side (Port B) they arrive from the BRAM
 * output register at the same Tco as instruction data, eliminating the
 * combinational LUT that would otherwise compute is_compressed from the
 * instruction bits.
 *
 * BRAM resource impact: Xilinx UltraScale+ RAMB36E2 provides 36 data +
 * 4 parity bits per word in 32-wide mode.  A 34-bit behavioral array maps
 * to the same primitives — zero additional BRAM cost.
 *
 * Port A: Instruction programming (slow clock domain, write + read)
 * Port B: Instruction fetch (fast clock domain, read only)
 */
module imem_predecode #(
    parameter int unsigned ADDR_WIDTH = 14,
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem"
) (
    // Port A: Programming interface (slow clock)
    input  logic        i_port_a_clk,
    input  logic        i_port_a_enable,
    input  logic [31:0] i_port_a_byte_address,
    input  logic [31:0] i_port_a_write_data,
    input  logic        i_port_a_write_enable,
    output logic [31:0] o_port_a_read_data,

    // Port B: Instruction fetch (fast clock)
    input  logic        i_port_b_clk,
    input  logic        i_port_b_enable,
    input  logic [31:0] i_port_b_byte_address,
    output logic [31:0] o_port_b_read_data,
    output logic [ 1:0] o_port_b_sideband       // {is_compressed_hi, is_compressed_lo}
);

  localparam int unsigned DataWidth = 34;  // 32 data + 2 sideband
  localparam int unsigned MemDepthInWords = 2 ** ADDR_WIDTH;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment

  // Memory array — 34 bits: {sideband[1:0], instruction[31:0]}
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DataWidth-1:0] memory[MemDepthInWords];
  /* verilator lint_on MULTIDRIVEN */

  // Initialize memory contents with sideband computed from instruction data
  initial begin
    if (USE_INIT_FILE) begin
      // $readmemh reads 32-bit hex values; the upper 2 bits are zero-filled
      $readmemh(INIT_FILE, memory);
      // Recompute sideband from instruction data for every word
      for (int i = 0; i < MemDepthInWords; i++) begin
        memory[i][33] = (memory[i][17:16] != 2'b11);  // is_compressed_hi
        memory[i][32] = (memory[i][1:0] != 2'b11);  // is_compressed_lo
      end
    end else begin
      for (int i = 0; i < MemDepthInWords; i++) memory[i] = DataWidth'(i);
    end
  end

  // Address conversion: byte address -> word address
  logic [ADDR_WIDTH-1:0] port_a_word_address, port_b_word_address;
  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];

  // Compute sideband from write data at write time
  logic [1:0] write_sideband;
  assign write_sideband[0] = (i_port_a_write_data[1:0] != 2'b11);  // is_compressed_lo
  assign write_sideband[1] = (i_port_a_write_data[17:16] != 2'b11);  // is_compressed_hi

  // Port A: Write-first behavior (matches synthesis recognition pattern)
  logic [DataWidth-1:0] port_a_read_data_wide;
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable) begin
        memory[port_a_word_address] <= {write_sideband, i_port_a_write_data};
        port_a_read_data_wide <= {write_sideband, i_port_a_write_data};
      end else begin
        port_a_read_data_wide <= memory[port_a_word_address];
      end
    end
  end
  assign o_port_a_read_data = port_a_read_data_wide[31:0];

  // Port B: Read-only, write-first pattern preserved for synthesis
  logic [DataWidth-1:0] port_b_read_data_wide;
  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      port_b_read_data_wide <= memory[port_b_word_address];
    end
  end
  assign o_port_b_read_data = port_b_read_data_wide[31:0];
  assign o_port_b_sideband  = port_b_read_data_wide[33:32];

endmodule : imem_predecode
