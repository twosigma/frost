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
 * Simple dual-port block RAM with synchronous (registered) read.
 * This module implements memory using dedicated block RAM resources available in FPGAs.
 * Unlike distributed RAM, block RAM uses specialized memory blocks that offer higher
 * density for larger memories. The read operation is synchronous (registered), introducing
 * one cycle of latency but allowing for higher clock frequencies and better timing.
 * Write operations are also synchronous. This module is ideal for larger memories where
 * density is more important than access latency, such as data/instruction memory and
 * large buffers. The registered read ensures clean timing paths in high-speed designs.
 */
module sdp_block_ram #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width in bits
    parameter int unsigned DATA_WIDTH = 32  // Data width in bits
) (
    input logic i_clk,
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram[RamDepth];

  // Initialize all memory locations to zero
  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  // Synchronous write operation
  always_ff @(posedge i_clk) if (i_write_enable) ram[i_write_address] <= i_write_data;

  // Synchronous read - output registered for block RAM inference and timing
  always_ff @(posedge i_clk) o_read_data <= ram[i_read_address];

endmodule : sdp_block_ram
