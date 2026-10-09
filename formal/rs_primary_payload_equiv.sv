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

module rs_primary_payload_equiv #(
    parameter int unsigned AW = 4,
    parameter int unsigned DW =
        riscv_pkg::InstrOpWidth + riscv_pkg::XLEN + 12 + 3 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 1 + 12 +
        5 + 1 + riscv_pkg::CheckpointIdWidth + 1 + 1 + 1 + 1 + 1 + 3,
    localparam int unsigned Groups = 1 << (AW - 2)
) (
    input logic clk,
    input logic [1:0] we,
    input logic [1:0][AW-1:0] wa,
    input logic [1:0][DW-1:0] wd
);
  // Arbitrary constant address: the result holds for every address for all
  // time, hence for any sequence of combinational read addresses as well.
  // Reads do not affect state in either implementation.
  (* anyconst *) logic [AW-1:0] watched_address;
  wire [AW-3:0] read_group = watched_address[AW-1:2];
  wire [Groups-1:0][1:0] group_pick = {Groups{watched_address[1:0]}};
  logic [DW-1:0] original_data;
  logic [DW-1:0] group_data[Groups];
  wire [AW-1:0] original_addr = {read_group, group_pick[read_group]};
  mwp_dist_ram #(
      .ADDR_WIDTH(AW),
      .DATA_WIDTH(DW),
      .NUM_WRITE_PORTS(2)
  ) u_original (
      .i_clk(clk),
      .i_write_enable(we),
      .i_write_address(wa),
      .i_write_data(wd),
      .i_read_address(original_addr),
      .o_read_data(original_data)
  );
  for (genvar g = 0; g < Groups; g++) begin : gen_group
    mwp_dist_ram #(
        .ADDR_WIDTH(2),
        .DATA_WIDTH(DW),
        .NUM_WRITE_PORTS(2)
    ) u_group (
        .i_clk(clk),
        .i_write_enable({we[1] && ((int'(wa[1]) >> 2) == g), we[0] && ((int'(wa[0]) >> 2) == g)}),
        .i_write_address({2'(wa[1]), 2'(wa[0])}),
        .i_write_data(wd),
        .i_read_address(group_pick[g]),
        .o_read_data(group_data[g])
    );
  end
  always_comb assert (original_data == group_data[read_group]);
endmodule
