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
 * The ASIC flow's true dual-port memory: two ports that each read or write,
 * on their own clocks. Under FROST_SRAM_MACROS, which the ASIC flow
 * (asic/config.mk) and the simulations of the macros' models define,
 * tdp_bram_dc_byte_en keeps its storage here, in a
 * column of OpenRAM macros of 4,096 64-bit words with byte write masks
 * (asic/openram.py). No other shape has a macro, and flip-flops cannot build
 * a memory written from two clocks, so any other shape is an error.
 *
 * In a cycle whose write mask has a bit set, a port writes the lanes those
 * bits select; in any other cycle it reads. In the cycle after a read,
 * o_port_*_read_data holds the word read; after a write it is undefined, as
 * the macros do not read and write a port in the same cycle.
 *
 * Simulation starts the macros with the image a block RAM holds: INIT_FILE
 * when USE_INIT_FILE is set, else each word's index. A chip loads its
 * program through a port.
 */
module frost_sram_2rw #(
    parameter int unsigned ADDR_WIDTH = 12,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned MASK_GRANULE = 8,
    parameter bit USE_INIT_FILE = 1'b0,
    parameter bit [63:0] INIT_FILE = "sw.mem"
) (
    input  logic                               i_port_a_clock,
    input  logic [DATA_WIDTH/MASK_GRANULE-1:0] i_port_a_write_mask,
    input  logic [             ADDR_WIDTH-1:0] i_port_a_address,
    input  logic [             DATA_WIDTH-1:0] i_port_a_write_data,
    output logic [             DATA_WIDTH-1:0] o_port_a_read_data,

    input  logic                               i_port_b_clock,
    input  logic [DATA_WIDTH/MASK_GRANULE-1:0] i_port_b_write_mask,
    input  logic [             ADDR_WIDTH-1:0] i_port_b_address,
    input  logic [             DATA_WIDTH-1:0] i_port_b_write_data,
    output logic [             DATA_WIDTH-1:0] o_port_b_read_data
);

  localparam int unsigned TileAddrWidth   = 12;
  localparam int unsigned TileDataWidth   = 64;
  localparam int unsigned TileMaskGranule = 8;

  initial begin
    if ((ADDR_WIDTH < TileAddrWidth) || (DATA_WIDTH != TileDataWidth) ||
        (MASK_GRANULE != TileMaskGranule))
      $fatal(
          1,
          "frost_sram_2rw: no macro builds a %0d x %0d memory with %0d-bit lanes",
          2 ** ADDR_WIDTH,
          DATA_WIDTH,
          MASK_GRANULE
      );
  end

  localparam int unsigned Rows = 2 ** (ADDR_WIDTH - TileAddrWidth);
  localparam int unsigned RowBits = (Rows > 1) ? $clog2(Rows) : 1;

  logic [RowBits-1:0] port_a_row, port_b_row, port_a_row_q, port_b_row_q;
  if (Rows > 1) begin : gen_row_select
    assign port_a_row = i_port_a_address[ADDR_WIDTH-1-:RowBits];
    assign port_b_row = i_port_b_address[ADDR_WIDTH-1-:RowBits];
  end else begin : gen_one_row
    assign port_a_row = '0;
    assign port_b_row = '0;
  end
  // The row whose words the macros' outputs hold, captured on reads.
  always_ff @(posedge i_port_a_clock) if (!(|i_port_a_write_mask)) port_a_row_q <= port_a_row;
  always_ff @(posedge i_port_b_clock) if (!(|i_port_b_write_mask)) port_b_row_q <= port_b_row;

  // Row r's words in bits [r*DATA_WIDTH +: DATA_WIDTH].
  logic [Rows*DATA_WIDTH-1:0] port_a_row_data, port_b_row_data;
  assign o_port_a_read_data = port_a_row_data[port_a_row_q*DATA_WIDTH+:DATA_WIDTH];
  assign o_port_b_read_data = port_b_row_data[port_b_row_q*DATA_WIDTH+:DATA_WIDTH];

`ifndef SYNTHESIS
  logic sim_load_image = 1'b0;
`endif
  for (genvar row = 0; row < int'(Rows); row++) begin : gen_row
    // A port selects the row it addresses, to read or to write.
    logic port_a_select, port_b_select;
    assign port_a_select = (port_a_row == RowBits'(row));
    assign port_b_select = (port_b_row == RowBits'(row));

    // OpenRAM ports: chip selects and write enables are active low.
    sram_2rw_4096x64_m8 u_macro (
        .clk0  (i_port_a_clock),
        .csb0  (!port_a_select),
        .web0  (!(|i_port_a_write_mask)),
        .wmask0(i_port_a_write_mask),
        .addr0 (i_port_a_address[TileAddrWidth-1:0]),
        .din0  (i_port_a_write_data),
        .dout0 (port_a_row_data[row*DATA_WIDTH+:DATA_WIDTH]),
        .clk1  (i_port_b_clock),
        .csb1  (!port_b_select),
        .web1  (!(|i_port_b_write_mask)),
        .wmask1(i_port_b_write_mask),
        .addr1 (i_port_b_address[TileAddrWidth-1:0]),
        .din1  (i_port_b_write_data),
        .dout1 (port_b_row_data[row*DATA_WIDTH+:DATA_WIDTH])
    );

`ifndef SYNTHESIS
    always @(posedge sim_load_image) begin
      logic [DATA_WIDTH-1:0] image[2**ADDR_WIDTH];
      if (USE_INIT_FILE) begin
        $readmemh(INIT_FILE, image);
        for (int i = 0; i < 2 ** TileAddrWidth; i++)
        u_macro.mem[i] = image[row*(2**TileAddrWidth)+i];
      end
    end
    initial begin
      logic [DATA_WIDTH-1:0] image[2**ADDR_WIDTH];
      if (USE_INIT_FILE) begin
        // The loaded image has no writes pending before either port's first
        // rising edge, including when its clock starts high.
        u_macro.csb0_reg = 1'b1;
        u_macro.csb1_reg = 1'b1;
        $readmemh(INIT_FILE, image);
      end else begin
`ifdef FROST_RANDOM_START
        for (int i = 0; i < 2 ** ADDR_WIDTH; i++)
        for (int chunk = 0; chunk < (DATA_WIDTH + 31) / 32; chunk++)
        image[i] = (image[i] << 32) | DATA_WIDTH'($urandom);
`else
        for (int i = 0; i < 2 ** ADDR_WIDTH; i++) image[i] = DATA_WIDTH'(i);
`endif
      end
      for (int i = 0; i < 2 ** TileAddrWidth; i++) u_macro.mem[i] = image[row*(2**TileAddrWidth)+i];
    end
`endif
  end

endmodule : frost_sram_2rw
