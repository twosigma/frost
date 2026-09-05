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

// Stateless XGMII-to-64b/66b block formatter. Lane zero occupies data[7:0].
// Padding is zero. Unrepresentable XGMII words become eight /E/ characters;
// o_bad_block identifies malformed input, not an explicitly supplied /E/.
// Packet-sequence validation belongs to the PCS receive state machine.
module eth10g_encode (
    input  logic [63:0] i_xgmii_data,
    input  logic [ 7:0] i_xgmii_ctrl,
    output logic [63:0] o_payload,
    output logic [ 1:0] o_header,
    output logic        o_bad_block
);
  import eth10g_pcs_pkg::*;
  logic [7:0] c_code[8];
  logic [7:0] c_valid;
  logic [7:0] octet[8];
  logic os0, os4, start0, start4;
  logic matched;

  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      octet[lane]   = i_xgmii_data[8*lane+:8];
      c_code[lane]  = encode_control(octet[lane]);
      c_valid[lane] = i_xgmii_ctrl[lane] && c_code[lane][7];
    end
    os0 = i_xgmii_ctrl[0] && is_ordered_set(octet[0]);
    os4 = i_xgmii_ctrl[4] && is_ordered_set(octet[4]);
    start0 = i_xgmii_ctrl[0] && octet[0] == XgmiiStart;
    start4 = i_xgmii_ctrl[4] && octet[4] == XgmiiStart;
    o_header = SyncCtrl;
    o_payload = '0;
    matched = 1'b1;

    if (i_xgmii_ctrl == 8'h00) begin
      o_header  = SyncData;
      o_payload = i_xgmii_data;
    end else if (&c_valid) begin
      o_payload[7:0] = BlockCtrl;
      for (int lane = 0; lane < 8; lane++) o_payload[8+7*lane+:7] = c_code[lane][6:0];
    end else if (start0 && i_xgmii_ctrl == 8'h01) begin
      o_payload = {i_xgmii_data[63:8], BlockStart0};
    end else if ((&c_valid[3:0]) && (os4 || start4) && i_xgmii_ctrl == 8'h1f) begin
      o_payload[7:0] = start4 ? BlockStart4 : BlockOs4;
      for (int lane = 0; lane < 4; lane++) o_payload[8+7*lane+:7] = c_code[lane][6:0];
      if (os4) o_payload[39:36] = encode_ordered_set(octet[4]);
      o_payload[63:40] = i_xgmii_data[63:40];
    end else if (os0 && (os4 || start4) && i_xgmii_ctrl == 8'h11) begin
      o_payload[7:0]   = start4 ? BlockOsStart : BlockOs04;
      o_payload[31:8]  = i_xgmii_data[31:8];
      o_payload[35:32] = encode_ordered_set(octet[0]);
      if (os4) o_payload[39:36] = encode_ordered_set(octet[4]);
      o_payload[63:40] = i_xgmii_data[63:40];
    end else if (os0 && (&c_valid[7:4]) && i_xgmii_ctrl == 8'hf1) begin
      o_payload[7:0]   = BlockOs0;
      o_payload[31:8]  = i_xgmii_data[31:8];
      o_payload[35:32] = encode_ordered_set(octet[0]);
      for (int lane = 4; lane < 8; lane++) o_payload[8+7*lane+:7] = c_code[lane][6:0];
    end else begin
      matched = 1'b0;
      for (int term_lane = 0; term_lane < 8; term_lane++) begin
        if (i_xgmii_ctrl == (8'hff << term_lane) && octet[term_lane] == XgmiiTerm &&
            (({1'b0, c_valid} >> (term_lane + 1)) == (9'h0ff >> (term_lane + 1)))) begin
          matched = 1'b1;
          o_payload[7:0] = termination_type(term_lane);
          for (int lane = 0; lane < 8; lane++) begin
            if (lane < term_lane) o_payload[8+8*lane+:8] = octet[lane];
            if (lane > term_lane) o_payload[8+7*lane+:7] = c_code[lane][6:0];
          end
        end
      end
    end
    o_bad_block = !matched;
    if (!matched) o_payload = ErrorPayload;
  end
endmodule
