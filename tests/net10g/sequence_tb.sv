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

module sequence_tb (
    input logic clk,
    input logic rst,
    input logic enable,
    input logic [63:0] xgmii_data,
    input logic [7:0] xgmii_ctrl,
    input logic bad_block,
    output logic [63:0] checked_data,
    output logic [7:0] checked_ctrl,
    output logic valid,
    output logic bad_sequence
);
  eth10g_rx_sequence sequence_check (
      .i_clk(clk),
      .i_rst(rst),
      .i_enable(enable),
      .i_xgmii_data(xgmii_data),
      .i_xgmii_ctrl(xgmii_ctrl),
      .i_bad_block(bad_block),
      .o_xgmii_data(checked_data),
      .o_xgmii_ctrl(checked_ctrl),
      .o_valid(valid),
      .o_bad_sequence(bad_sequence)
  );
endmodule
