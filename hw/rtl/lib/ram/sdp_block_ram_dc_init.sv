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
 * Dual-clock simple dual-port block RAM with a read enable and an optional
 * initial image. Writes are synchronous to i_write_clock. A read is
 * registered on i_read_clock in a cycle with i_read_enable, so it costs one
 * cycle, and o_read_data holds while i_read_enable is low. That register is
 * the block RAM's own output latch. A read of the word that the write port
 * writes in the same cycle is undefined.
 *
 * With USE_INIT_FILE, the array starts with the first 2**ADDR_WIDTH words of
 * the hex image INIT_FILE. Without it, the array has no initial contents,
 * and a simulation may fill ram directly. imem_predecode keeps its block
 * RAMs here.
 *
 * The ASIC flow defines FROST_SRAM_MACROS and keeps the array in
 * frost_sram_1w1r (asic/sram), in SRAM macros or flip-flops, with no initial
 * contents; simulations of the macros start them with INIT_FILE. The macros'
 * read data is undefined after a cycle without a read, so a register of the
 * last word read holds o_read_data instead; with i_read_enable tied high,
 * synthesis removes it. A macro completes a write half a write-clock period
 * after the write's edge, where the block RAM completes it at the edge, so a
 * read of the word before then is undefined.
 */
module sdp_block_ram_dc_init #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width in bits
    parameter int unsigned DATA_WIDTH = 32,  // Data width in bits
    parameter bit USE_INIT_FILE = 1'b0,
    // Hex image name, at most 40 characters to fit these 320 bits.
    parameter bit [319:0] INIT_FILE = ""
) (
    input logic                  i_write_clock,
    input logic                  i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [DATA_WIDTH-1:0] i_write_data,

    input  logic                  i_read_clock,
    input  logic                  i_read_enable,
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

`ifdef FROST_SRAM_MACROS
  logic [DATA_WIDTH-1:0] memory_read_data;
  frost_sram_1w1r #(
      .ADDR_WIDTH   (ADDR_WIDTH),
      .DATA_WIDTH   (DATA_WIDTH),
      .COMMON_CLOCK (1'b0),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE    (INIT_FILE)
  ) u_sram (
      .i_write_clock,
      .i_bulk_clear(1'b0),
      .i_write_mask(i_write_enable),
      .i_write_address,
      .i_write_data,
      .i_read_clock,
      .i_read_enable,
      .i_read_address,
      .o_read_data (memory_read_data)
  );

  // Hold the last word read through cycles without a read.
  logic                  read_enable_q;
  logic [DATA_WIDTH-1:0] held_read_data_q;
  always_ff @(posedge i_read_clock) begin
    read_enable_q    <= i_read_enable;
    held_read_data_q <= o_read_data;
  end
  assign o_read_data = read_enable_q ? memory_read_data : held_read_data_q;
`else
  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;

  // A simulation that fills the array writes it from outside this module.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram[RamDepth];
  /* verilator lint_on MULTIDRIVEN */

  initial if (USE_INIT_FILE) $readmemh(INIT_FILE, ram, 0, RamDepth - 1);

  always_ff @(posedge i_write_clock) if (i_write_enable) ram[i_write_address] <= i_write_data;

  // The read register permits block RAM inference; its enable holds it.
  always_ff @(posedge i_read_clock) if (i_read_enable) o_read_data <= ram[i_read_address];
`endif

endmodule : sdp_block_ram_dc_init
