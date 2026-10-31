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

// Two dispatch ports write a register bank selected by a one-hot issue mask.
module coherent_rs_payload_store #(
    parameter int unsigned ADDR_WIDTH = 4,
    parameter int unsigned DATA_WIDTH = 32,
    localparam int unsigned DEPTH = 1 << ADDR_WIDTH
) (
    input logic i_clk,
    input logic [1:0] i_write_enable,
    input logic [1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [1:0][DATA_WIDTH-1:0] i_write_data,
    input logic [DEPTH-1:0] i_read_onehot,
    output logic [DATA_WIDTH-1:0] o_read_data
);
  logic [DATA_WIDTH-1:0] selected[DEPTH];
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_entry
    logic [DATA_WIDTH-1:0] payload = '0;
    always_ff @(posedge i_clk) begin
      if (i_write_enable[1] && i_write_address[1] == ADDR_WIDTH'(entry)) payload <= i_write_data[1];
      else if (i_write_enable[0] && i_write_address[0] == ADDR_WIDTH'(entry))
        payload <= i_write_data[0];
    end
    assign selected[entry] = payload & {DATA_WIDTH{i_read_onehot[entry]}};
  end
  always_comb begin
    o_read_data = '0;
    for (int entry = 0; entry < DEPTH; entry++) o_read_data |= selected[entry];
  end
endmodule
