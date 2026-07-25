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
 * The write port operates on i_write_clock while the read port operates on i_read_clock.
 * Both ports have registered (single-cycle latency) access to ensure clean timing and
 * proper block RAM inference; the array is zero-initialized at time 0 for simulation.
 * Storage only -- it provides no synchronization: the crossing is made safe by dc_fifo's
 * 2-FF pointer synchronizers, and dc_fifo is the sole user.
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

  // Initialize all memory locations to zero
  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  // Write port - synchronous to write clock domain
  always_ff @(posedge i_write_clock) if (i_write_enable) ram[i_write_address] <= i_write_data;

  // Read port - synchronous to read clock domain with registered output
  always_ff @(posedge i_read_clock) o_read_data <= ram[i_read_address];

endmodule : sdp_block_ram_dc
