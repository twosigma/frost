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
 * Simple dual-port distributed RAM with asynchronous read.
 * This module implements a small, fast memory using distributed logic resources (LUTs)
 * rather than dedicated block RAM. It provides separate read and write ports with
 * combinational (zero-cycle) read access, making it ideal for small memories requiring
 * low latency like register files, small caches, and FIFOs. The write operation is
 * synchronous to prevent glitches, while reads are asynchronous for immediate access.
 * The memory is initialized to all zeros at startup. Distributed RAM is typically
 * synthesized using FPGA lookup tables, providing faster access than block RAM for
 * small memories.
 */
module sdp_dist_ram #(
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
  (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] ram[RamDepth];

  // Initialize all memory locations to zero
  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  // Synchronous write operation
  always_ff @(posedge i_clk) if (i_write_enable) ram[i_write_address] <= i_write_data;

  // Asynchronous read operation (combinational, zero latency)
  assign o_read_data = ram[i_read_address];

endmodule : sdp_dist_ram
