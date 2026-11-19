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

// Each side wrapper drives twin_read from the same free word for this read port.
// The twin compares the actual addresses, write enables and written words.
module sdp_dist_ram #(
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned DATA_WIDTH = 32
) (
    input logic i_clk,
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic [DATA_WIDTH-1:0] i_write_data,
    output wire [DATA_WIDTH-1:0] o_read_data
);
  wire [DATA_WIDTH-1:0] twin_read;
  assign o_read_data = twin_read;
endmodule
