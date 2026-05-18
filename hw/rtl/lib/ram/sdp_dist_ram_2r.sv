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
 * Distributed RAM with one synchronous write port and two independent
 * asynchronous read ports.
 *
 * Functionally identical to two sdp_dist_ram instances driven by the same
 * writes, but presented as a single backing array so synthesis can pack the
 * two read ports into a multi-port LUTRAM primitive (e.g. RAM32M/RAM64M)
 * instead of duplicating storage across two RAM32X1D groups.
 *
 * Same caveat as sdp_dist_ram: reads are combinational, write is synchronous.
 */
module sdp_dist_ram_2r #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width in bits
    parameter int unsigned DATA_WIDTH = 32  // Data width in bits
) (
    input logic                  i_clk,
    input logic                  i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [DATA_WIDTH-1:0] i_write_data,

    // Two independent asynchronous read ports
    input  logic [ADDR_WIDTH-1:0] i_read_address_a,
    output logic [DATA_WIDTH-1:0] o_read_data_a,
    input  logic [ADDR_WIDTH-1:0] i_read_address_b,
    output logic [DATA_WIDTH-1:0] o_read_data_b
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] ram[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) ram[i] = '0;

  always_ff @(posedge i_clk) if (i_write_enable) ram[i_write_address] <= i_write_data;

  assign o_read_data_a = ram[i_read_address_a];
  assign o_read_data_b = ram[i_read_address_b];

endmodule : sdp_dist_ram_2r
