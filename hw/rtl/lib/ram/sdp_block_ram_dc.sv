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
 * Dual-clock simple dual-port block RAM for clock domain crossing.
 * Writes are synchronous to i_write_clock. The read output is registered on
 * i_read_clock, so a read costs one cycle. That register is also what makes
 * the array infer block RAM. The array is zeroed at time 0 for simulation.
 *
 * This is storage with no synchronization of its own. dc_fifo is its sole
 * user, and dc_fifo's 2-FF pointer synchronizers are what make the crossing
 * safe.
 */
module sdp_block_ram_dc #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width in bits
    parameter int unsigned DATA_WIDTH = 32  // Data width in bits
) (
    input logic i_write_clock,  // Clock domain for write port
    input logic i_read_clock,  // Clock domain for read port
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  always_ff @(posedge i_write_clock) if (i_write_enable) ram[i_write_address] <= i_write_data;

  always_ff @(posedge i_read_clock) o_read_data <= ram[i_read_address];

endmodule : sdp_block_ram_dc
