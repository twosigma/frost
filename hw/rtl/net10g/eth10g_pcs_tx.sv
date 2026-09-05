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

// One elastic pipeline stage. XGMII and scrambler state advance together.
// The caller must supply idles when no packet is available.
module eth10g_pcs_tx (
    input logic i_clk,
    input logic i_rst,
    input logic [63:0] i_xgmii_data,
    input logic [7:0] i_xgmii_ctrl,
    output logic o_xgmii_ready,
    output logic [65:0] o_block,
    output logic o_block_valid,
    input logic i_block_ready,
    output logic o_bad_block
);
  logic [63:0] payload, scrambled;
  logic [1:0] header, header_reg;
  logic bad_block;
  assign o_xgmii_ready = !i_rst && (!o_block_valid || i_block_ready);
  assign o_block = {scrambled, header_reg};
  eth10g_encode encoder (
      .i_xgmii_data(i_xgmii_data),
      .i_xgmii_ctrl(i_xgmii_ctrl),
      .o_payload(payload),
      .o_header(header),
      .o_bad_block(bad_block)
  );
  eth10g_scrambler scrambler (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_enable(o_xgmii_ready),
      .i_data(payload),
      .o_data(scrambled)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      header_reg <= '0;
      o_block_valid <= 1'b0;
      o_bad_block <= 1'b0;
    end else begin
      o_bad_block <= o_xgmii_ready && bad_block;
      if (o_xgmii_ready) begin
        header_reg <= header;
        o_block_valid <= 1'b1;
      end
    end
  end
endmodule
