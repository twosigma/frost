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

  Each read port is implemented as a separate sdp_dist_ram instance sharing the same
  write port. Read addresses are provided externally (from PD stage for early source
  register reads in ID stage). Read data is combinational (zero-latency).

  Parameters:
    DATA_WIDTH     - Register width in bits (e.g. 32 for integer, 64 for FP)
    NUM_READ_PORTS - Number of simultaneous read ports (2 for integer, 3 for FP/FMA)
    HARDWIRE_ZERO  - When 1, writes to register 0 are blocked (RISC-V x0 convention)
*/
module generic_regfile #(
    parameter int unsigned DATA_WIDTH     = 32,
    parameter int unsigned NUM_READ_PORTS = 2,
    parameter bit          HARDWIRE_ZERO  = 1,
    parameter int unsigned DEPTH          = 32
) (
    input  logic                                 i_clk,
    input  logic                                 i_write_enable,
    input  logic [                          4:0] i_write_addr,
    input  logic [               DATA_WIDTH-1:0] i_write_data,
    input  logic                                 i_stall,
    // Packed vectors for Icarus Verilog compatibility
    // (Icarus does not support unpacked arrays as module ports)
    input  logic [         NUM_READ_PORTS*5-1:0] i_read_addr,
    output logic [NUM_READ_PORTS*DATA_WIDTH-1:0] o_read_data
);

  // Write enable: gated by stall, and also by nonzero write address when HARDWIRE_ZERO is set
  logic write_enable;

  if (HARDWIRE_ZERO) begin : gen_hardwire_zero
    assign write_enable = i_write_enable & ~i_stall & |i_write_addr;
  end else begin : gen_no_hardwire_zero
    assign write_enable = i_write_enable & ~i_stall;
  end

  // Generate one sdp_dist_ram per read port, all sharing the same write port
  for (genvar i = 0; i < NUM_READ_PORTS; i++) begin : gen_read_port
    logic [DATA_WIDTH-1:0] rd;
    sdp_dist_ram #(
        .ADDR_WIDTH($clog2(DEPTH)),
        .DATA_WIDTH(DATA_WIDTH)
    ) read_port_ram (
        .i_clk,
        .i_write_enable(write_enable),
        .i_write_address(i_write_addr),
        .i_write_data(i_write_data),
        .i_read_address(i_read_addr[i*5+:5]),
        .o_read_data(rd)
    );
    assign o_read_data[i*DATA_WIDTH+:DATA_WIDTH] = rd;
  end

endmodule : generic_regfile
