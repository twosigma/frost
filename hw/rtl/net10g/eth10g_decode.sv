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

// Stateless 64b/66b-to-XGMII block formatter. Reserved padding is ignored
// per 49.2.4.3. Any invalid header, block type, C code or O code produces
// eight /E/ characters and o_bad_block. Valid explicit /E/ remains valid.
module eth10g_decode (
    input  logic [63:0] i_payload,
    input  logic [ 1:0] i_header,
    output logic [63:0] o_xgmii_data,
    output logic [ 7:0] o_xgmii_ctrl,
    output logic        o_bad_block
);
  import eth10g_pcs_pkg::*;
  logic [8:0] c_octet[8];
  logic [8:0] os0, os4;
  integer term_lane;

  always_comb begin
    for (int lane = 0; lane < 8; lane++) c_octet[lane] = decode_control(i_payload[8+7*lane+:7]);
    os0 = decode_ordered_set(i_payload[35:32]);
    os4 = decode_ordered_set(i_payload[39:36]);
    o_xgmii_data = '0;
    o_xgmii_ctrl = '0;
    o_bad_block = 1'b0;
    term_lane = -1;

    if (i_header == SyncData) begin
      o_xgmii_data = i_payload;
    end else if (i_header == SyncCtrl) begin
      case (i_payload[7:0])
        BlockCtrl: begin
          o_xgmii_ctrl = 8'hff;
          for (int lane = 0; lane < 8; lane++) begin
            o_xgmii_data[8*lane+:8] = c_octet[lane][7:0];
            o_bad_block |= !c_octet[lane][8];
          end
        end
        BlockStart0: begin
          o_xgmii_ctrl = 8'h01;
          o_xgmii_data = {i_payload[63:8], XgmiiStart};
        end
        BlockStart4, BlockOs4: begin
          o_xgmii_ctrl = 8'h1f;
          for (int lane = 0; lane < 4; lane++) begin
            o_xgmii_data[8*lane+:8] = c_octet[lane][7:0];
            o_bad_block |= !c_octet[lane][8];
          end
          if (i_payload[7:0] == BlockOs4) begin
            o_xgmii_data[39:32] = os4[7:0];
            o_bad_block |= !os4[8];
          end else o_xgmii_data[39:32] = XgmiiStart;
          o_xgmii_data[63:40] = i_payload[63:40];
        end
        BlockOs04, BlockOsStart: begin
          o_xgmii_ctrl = 8'h11;
          o_xgmii_data[7:0] = os0[7:0];
          o_bad_block |= !os0[8];
          o_xgmii_data[31:8] = i_payload[31:8];
          if (i_payload[7:0] == BlockOs04) begin
            o_xgmii_data[39:32] = os4[7:0];
            o_bad_block |= !os4[8];
          end else o_xgmii_data[39:32] = XgmiiStart;
          o_xgmii_data[63:40] = i_payload[63:40];
        end
        BlockOs0: begin
          o_xgmii_ctrl = 8'hf1;
          o_xgmii_data[7:0] = os0[7:0];
          o_bad_block |= !os0[8];
          o_xgmii_data[31:8] = i_payload[31:8];
          for (int lane = 4; lane < 8; lane++) begin
            o_xgmii_data[8*lane+:8] = c_octet[lane][7:0];
            o_bad_block |= !c_octet[lane][8];
          end
        end
        BlockTerm0: term_lane = 0;
        BlockTerm1: term_lane = 1;
        BlockTerm2: term_lane = 2;
        BlockTerm3: term_lane = 3;
        BlockTerm4: term_lane = 4;
        BlockTerm5: term_lane = 5;
        BlockTerm6: term_lane = 6;
        BlockTerm7: term_lane = 7;
        default: o_bad_block = 1'b1;
      endcase
      if (term_lane >= 0) begin
        o_xgmii_ctrl = 8'hff << term_lane;
        // At most seven data bytes precede /T/. Keep the source slice
        // structurally within the 64-bit payload even before optimization.
        for (int lane = 0; lane < 7; lane++) begin
          if (lane < term_lane) o_xgmii_data[8*lane+:8] = i_payload[8+8*lane+:8];
        end
        for (int lane = 0; lane < 8; lane++) begin
          if (lane == term_lane) o_xgmii_data[8*lane+:8] = XgmiiTerm;
          else if (lane > term_lane) begin
            o_xgmii_data[8*lane+:8] = c_octet[lane][7:0];
            o_bad_block |= !c_octet[lane][8];
          end
        end
      end
    end else o_bad_block = 1'b1;
    if (o_bad_block) begin
      o_xgmii_ctrl = 8'hff;
      o_xgmii_data = {8{XgmiiError}};
    end
  end
endmodule
