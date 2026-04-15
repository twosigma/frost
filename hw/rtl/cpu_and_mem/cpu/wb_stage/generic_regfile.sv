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
  Generic RISC-V register file parameterized by data width, number of read ports,
  and whether register 0 is hardwired to zero.

  Used for both the integer register file (2 read ports, x0 hardwired zero, 32-bit)
  and the FP register file (3 read ports, no hardwired zero, 64-bit for D extension).

  Each read port is implemented as a separate mwp_dist_ram instance with
  NUM_WRITE_PORTS shared write ports. Read data is combinational (zero-latency).
  For widen-commit, both slot 1 (primary) and slot 2 (widen) can drive
  independent write ports in the same cycle.

  Parameters:
    DATA_WIDTH      - Register width in bits (e.g. 32 for integer, 64 for FP)
    NUM_READ_PORTS  - Number of simultaneous read ports (2 for integer, 3 for FP/FMA)
    NUM_WRITE_PORTS - Number of simultaneous write ports (1 for in-order, 2 for widen-commit)
    HARDWIRE_ZERO   - When 1, writes to register 0 are blocked (RISC-V x0 convention)
*/
module generic_regfile #(
    parameter  int unsigned DATA_WIDTH      = 32,
    parameter  int unsigned NUM_READ_PORTS  = 2,
    parameter  int unsigned NUM_WRITE_PORTS = 1,
    parameter  bit          HARDWIRE_ZERO   = 1,
    parameter  int unsigned DEPTH           = 32,
    localparam int unsigned AddrWidth       = $clog2(DEPTH)
) (
    input  logic                                  i_clk,
    // Packed write ports.  Bit/lane index 0 is the primary (slot 1) writer;
    // higher indices are auxiliary writers (slot 2 in the widen-commit case).
    // Highest-indexed port wins on simultaneous same-address writes.
    input  logic [           NUM_WRITE_PORTS-1:0] i_write_enable,
    input  logic [ NUM_WRITE_PORTS*AddrWidth-1:0] i_write_addr,
    input  logic [NUM_WRITE_PORTS*DATA_WIDTH-1:0] i_write_data,
    input  logic                                  i_stall,
    // Packed vectors for Icarus Verilog compatibility
    // (Icarus does not support unpacked arrays as module ports)
    input  logic [  NUM_READ_PORTS*AddrWidth-1:0] i_read_addr,
    output logic [ NUM_READ_PORTS*DATA_WIDTH-1:0] o_read_data
);

  // Per-port write enables: gated by stall, and also by nonzero write
  // address when HARDWIRE_ZERO is set (RISC-V x0 always reads zero).
  logic [NUM_WRITE_PORTS-1:0] write_enable;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : gen_write_enable
    logic [AddrWidth-1:0] wp_addr;
    assign wp_addr = i_write_addr[wp*AddrWidth+:AddrWidth];
    if (HARDWIRE_ZERO) begin : gen_hardwire_zero
      assign write_enable[wp] = i_write_enable[wp] & ~i_stall & |wp_addr;
    end else begin : gen_no_hardwire_zero
      assign write_enable[wp] = i_write_enable[wp] & ~i_stall;
    end
  end : gen_write_enable

  // Pack the packed write arrays into the mwp_dist_ram-shaped 2D format.
  logic [NUM_WRITE_PORTS-1:0][ AddrWidth-1:0] mwp_addrs;
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] mwp_data;
  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : gen_mwp_pack
    assign mwp_addrs[wp] = i_write_addr[wp*AddrWidth+:AddrWidth];
    assign mwp_data[wp]  = i_write_data[wp*DATA_WIDTH+:DATA_WIDTH];
  end : gen_mwp_pack

  // For NUM_WRITE_PORTS == 1, fall back to sdp_dist_ram per read port (the
  // baseline path). For NUM_WRITE_PORTS >= 2, use mwp_dist_ram per read
  // port with a Live Value Table steering reads to the most recent writer.
  for (genvar i = 0; i < NUM_READ_PORTS; i++) begin : gen_read_port
    logic [DATA_WIDTH-1:0] rd;
    if (NUM_WRITE_PORTS == 1) begin : gen_single_write
      sdp_dist_ram #(
          .ADDR_WIDTH(AddrWidth),
          .DATA_WIDTH(DATA_WIDTH)
      ) read_port_ram (
          .i_clk,
          .i_write_enable (write_enable[0]),
          .i_write_address(mwp_addrs[0]),
          .i_write_data   (mwp_data[0]),
          .i_read_address (i_read_addr[i*AddrWidth+:AddrWidth]),
          .o_read_data    (rd)
      );
    end else begin : gen_multi_write
      mwp_dist_ram #(
          .ADDR_WIDTH     (AddrWidth),
          .DATA_WIDTH     (DATA_WIDTH),
          .NUM_WRITE_PORTS(NUM_WRITE_PORTS)
      ) read_port_ram (
          .i_clk,
          .i_write_enable (write_enable),
          .i_write_address(mwp_addrs),
          .i_write_data   (mwp_data),
          .i_read_address (i_read_addr[i*AddrWidth+:AddrWidth]),
          .o_read_data    (rd)
      );
    end
    assign o_read_data[i*DATA_WIDTH+:DATA_WIDTH] = rd;
  end : gen_read_port

endmodule : generic_regfile
