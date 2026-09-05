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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Two Sigma Open Source, LLC

module gearbox_tb (
    input logic i_clk,
    input logic i_rst,
    input logic [65:0] i_block,
    input logic i_block_valid,
    output logic o_block_ready,
    output logic [63:0] o_raw_data,
    output logic o_raw_valid,
    input logic [63:0] i_raw_data,
    input logic i_raw_valid,
    input logic i_slip,
    output logic [65:0] o_block,
    output logic o_block_valid
);
  eth10g_tx_gearbox tx (.*);
  eth10g_rx_gearbox rx (.*);
endmodule
