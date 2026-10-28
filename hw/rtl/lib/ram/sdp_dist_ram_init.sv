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
 * Simple dual-port distributed RAM with synchronous write, asynchronous read,
 * and an optional initial image. With USE_INIT_FILE, the array starts with
 * the first 2**ADDR_WIDTH words of the hex image INIT_FILE. Without it, the
 * array has no initial contents, and a simulation may fill ram directly.
 * imem_predecode's PC-metadata overlays keep their arrays here.
 */
module sdp_dist_ram_init #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width in bits
    parameter int unsigned DATA_WIDTH = 32,  // Data width in bits
    parameter bit USE_INIT_FILE = 1'b0,
    // The caller loads ram directly during simulation.
    parameter bit SIM_EXTERNAL_INIT = 1'b0,
    // Hex image name, at most 40 characters to fit these 320 bits.
    parameter bit [319:0] INIT_FILE = ""
) (
    input logic i_clk,
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;

  // A simulation that fills the array writes it from outside this module.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] ram[RamDepth];
  /* verilator lint_on MULTIDRIVEN */

  initial begin
    if (USE_INIT_FILE) $readmemh(INIT_FILE, ram, 0, RamDepth - 1);
`ifdef FROST_RANDOM_START
    if (!USE_INIT_FILE && !SIM_EXTERNAL_INIT)
      for (int row = 0; row < RamDepth; row++)
      for (int chunk = 0; chunk < (DATA_WIDTH + 31) / 32; chunk++)
      ram[row] = (ram[row] << 32) | DATA_WIDTH'($urandom);
`endif
  end

  always_ff @(posedge i_clk) if (i_write_enable) ram[i_write_address] <= i_write_data;

  assign o_read_data = ram[i_read_address];

endmodule : sdp_dist_ram_init
