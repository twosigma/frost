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
    parameter int unsigned DATA_WIDTH = 32,  // Data width in bits
    // Simulation-only bulk-clear support. 0 (FPGA/synthesis): this module is
    // byte-for-byte the plain single-write block RAM -- the clear path is not
    // elaborated, so inference is unchanged. Non-zero: a sim-only path lets
    // i_bulk_clear zero every entry in one cycle (frost_cache's fast
    // invalidate-all). The clear branch lives in a generate that is elaborated
    // only when this is set, so no synthesis flow ever sees the array-wide
    // reset.
    parameter int unsigned SUPPORT_BULK_CLEAR = 0
) (
    input logic i_clk,
    input logic i_write_enable,
    // Sim-only one-cycle clear of every entry (see SUPPORT_BULK_CLEAR). Tied
    // low / unused on FPGA builds (SUPPORT_BULK_CLEAR = 0).
    input logic i_bulk_clear,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram[RamDepth];

  // Initialize all memory locations to zero
  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  // Synchronous write. SUPPORT_BULK_CLEAR picks the write block at elaboration:
  // the FPGA path is exactly the original single-port write (so block-RAM
  // inference is unchanged); the sim-only path adds a one-cycle clear-all that
  // takes priority over a write. Only one branch ever exists in a build.
  if (SUPPORT_BULK_CLEAR != 0) begin : gen_clearable_write
    always_ff @(posedge i_clk) begin
      if (i_bulk_clear) for (int i = 0; i < int'(RamDepth); ++i) ram[i] <= '0;
      else if (i_write_enable) ram[i_write_address] <= i_write_data;
    end
  end else begin : gen_plain_write
    always_ff @(posedge i_clk) if (i_write_enable) ram[i_write_address] <= i_write_data;
  end

  // Synchronous read - output registered for block RAM inference and timing
  always_ff @(posedge i_clk) o_read_data <= ram[i_read_address];

endmodule : sdp_block_ram
