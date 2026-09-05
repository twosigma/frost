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

module codec_tb (
    input logic [63:0] tx_data,
    input logic [7:0] tx_ctrl,
    output logic [63:0] tx_payload,
    output logic [1:0] tx_header,
    output logic tx_bad,
    input logic [63:0] rx_payload,
    input logic [1:0] rx_header,
    output logic [63:0] rx_data,
    output logic [7:0] rx_ctrl,
    output logic rx_bad
);
  eth10g_encode encoder (
      .i_xgmii_data(tx_data),
      .i_xgmii_ctrl(tx_ctrl),
      .o_payload(tx_payload),
      .o_header(tx_header),
      .o_bad_block(tx_bad)
  );
  eth10g_decode decoder (
      .i_payload(rx_payload),
      .i_header(rx_header),
      .o_xgmii_data(rx_data),
      .o_xgmii_ctrl(rx_ctrl),
      .o_bad_block(rx_bad)
  );
endmodule
