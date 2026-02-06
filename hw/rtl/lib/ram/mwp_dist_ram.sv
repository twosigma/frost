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
 * Multi-write-port distributed RAM using the Live Value Table (LVT) technique.
 *
 * Provides NUM_WRITE_PORTS independent write ports and a single asynchronous
 * read port backed by distributed (LUT) RAM. Internally, one sdp_dist_ram
 * instance is allocated per write port, each exclusively written by its
 * corresponding port. A small register-based Live Value Table tracks which
 * RAM copy holds the most recent value for every address, steering the read
 * mux accordingly.
 *
 * Write-port priority: when multiple ports write the same address in the same
 * cycle, the highest-numbered port wins (index NUM_WRITE_PORTS-1 has the
 * highest priority).
 *
 * For multiple read ports, instantiate multiple copies of this module with
 * identical write connections; each copy may use a different i_read_address.
 *
 * Resource cost (approximate, for DEPTH entries):
 *   - NUM_WRITE_PORTS x sdp_dist_ram instances (DATA_WIDTH-wide each)
 *   - DEPTH x $clog2(NUM_WRITE_PORTS) flip-flops for the LVT
 *   - One NUM_WRITE_PORTS-to-1 DATA_WIDTH-wide read mux
 *
 * Scales well up to ~4 write ports; beyond that the read mux depth and LVT
 * size start to matter for timing.
 */
module mwp_dist_ram #(
    parameter int unsigned ADDR_WIDTH      = 5,   // Address width in bits
    parameter int unsigned DATA_WIDTH      = 32,  // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS = 2    // Number of write ports (>= 2)
) (
    input logic i_clk,

    // Write ports (active-high enables, independent addresses and data)
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,

    // Read port (asynchronous / combinational)
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port
  // ---------------------------------------------------------------------------
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : g_banks
    sdp_dist_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank (
        .i_clk,
        .i_write_enable (i_write_enable[wp]),
        .i_write_address(i_write_address[wp]),
        .i_read_address (i_read_address),
        .i_write_data   (i_write_data[wp]),
        .o_read_data    (bank_read_data[wp])
    );
  end : g_banks

  // ---------------------------------------------------------------------------
  // Live Value Table (register-based)
  //
  // Tracks which bank holds the most recent write for each address.
  // Highest-indexed write port wins on simultaneous same-address writes.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  always_ff @(posedge i_clk) begin
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (i_write_enable[wp]) lvt[i_write_address[wp]] <= SelWidth'(wp);
    end
  end

  // ---------------------------------------------------------------------------
  // Read mux — select the bank indicated by the LVT
  // ---------------------------------------------------------------------------
  assign o_read_data = bank_read_data[lvt[i_read_address]];

endmodule : mwp_dist_ram
