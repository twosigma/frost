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

module scrambler_tb (
    input logic clk,
    input logic rst,
    input logic enable,
    input logic [63:0] tx_data,
    input logic [63:0] rx_data,
    output logic [63:0] scrambled,
    output logic [63:0] descrambled
);
  eth10g_scrambler tx (
      .i_clk(clk),
      .i_rst(rst),
      .i_enable(enable),
      .i_data(tx_data),
      .o_data(scrambled)
  );
  eth10g_descrambler rx (
      .i_clk(clk),
      .i_rst(rst),
      .i_enable(enable),
      .i_data(rx_data),
      .o_data(descrambled)
  );
endmodule
