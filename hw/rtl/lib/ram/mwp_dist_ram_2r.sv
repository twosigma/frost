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
 * Multi-write-port distributed RAM with two asynchronous read ports.
 *
 * Functionally identical to two mwp_dist_ram instances driven by the same
 * writes (the LVT and per-write-port banks are shared between the two read
 * mux trees), but presented as a single module so the banks can use the
 * 2-read-port distributed RAM primitive instead of duplicating storage.
 *
 * Write semantics match mwp_dist_ram: highest-numbered write port wins on
 * simultaneous same-address writes.
 */
module mwp_dist_ram_2r #(
    parameter int unsigned ADDR_WIDTH      = 5,   // Address width in bits
    parameter int unsigned DATA_WIDTH      = 32,  // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS = 2    // Number of write ports (>= 2)
) (
    input logic i_clk,

    // Write ports (active-high enables, independent addresses and data)
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,

    // Two independent asynchronous read ports
    input  logic [ADDR_WIDTH-1:0] i_read_address_a,
    output logic [DATA_WIDTH-1:0] o_read_data_a,
    input  logic [ADDR_WIDTH-1:0] i_read_address_b,
    output logic [DATA_WIDTH-1:0] o_read_data_b
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port — each bank exposes both read ports.
  // ---------------------------------------------------------------------------
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data_a;
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data_b;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : g_banks
    sdp_dist_ram_2r #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank (
        .i_clk,
        .i_write_enable  (i_write_enable[wp]),
        .i_write_address (i_write_address[wp]),
        .i_write_data    (i_write_data[wp]),
        .i_read_address_a(i_read_address_a),
        .o_read_data_a   (bank_read_data_a[wp]),
        .i_read_address_b(i_read_address_b),
        .o_read_data_b   (bank_read_data_b[wp])
    );
  end : g_banks

  // ---------------------------------------------------------------------------
  // Live Value Table (register-based) — shared across both read ports.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  always_ff @(posedge i_clk) begin
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (i_write_enable[wp]) lvt[i_write_address[wp]] <= SelWidth'(wp);
    end
  end

  // ---------------------------------------------------------------------------
  // Per-port read mux — selects the bank indicated by the LVT entry.
  // ---------------------------------------------------------------------------
  assign o_read_data_a = bank_read_data_a[lvt[i_read_address_a]];
  assign o_read_data_b = bank_read_data_b[lvt[i_read_address_b]];

endmodule : mwp_dist_ram_2r
