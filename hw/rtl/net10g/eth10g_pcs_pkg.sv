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

// IEEE 802.3 Clause 49: Figure 49-7 and Table 49-1.
// The standard prints sync headers in wire order. Packed vectors below put
// the FIRST transmitted bit in bit zero: data serial 01, control serial 10.
package eth10g_pcs_pkg;
  localparam logic [1:0] SyncData = 2'b10;
  localparam logic [1:0] SyncCtrl = 2'b01;
  localparam logic [7:0] XgmiiIdle = 8'h07;
  localparam logic [7:0] XgmiiLpi = 8'h06;
  localparam logic [7:0] XgmiiError = 8'hfe;
  localparam logic [7:0] XgmiiStart = 8'hfb;
  localparam logic [7:0] XgmiiTerm = 8'hfd;
  localparam logic [7:0] XgmiiSeq = 8'h9c;
  localparam logic [7:0] XgmiiSig = 8'h5c;
  localparam logic [7:0] BlockCtrl = 8'h1e;
  localparam logic [7:0] BlockOs4 = 8'h2d;
  localparam logic [7:0] BlockStart4 = 8'h33;
  localparam logic [7:0] BlockOsStart = 8'h66;
  localparam logic [7:0] BlockOs04 = 8'h55;
  localparam logic [7:0] BlockStart0 = 8'h78;
  localparam logic [7:0] BlockOs0 = 8'h4b;
  localparam logic [7:0] BlockTerm0 = 8'h87;
  localparam logic [7:0] BlockTerm1 = 8'h99;
  localparam logic [7:0] BlockTerm2 = 8'haa;
  localparam logic [7:0] BlockTerm3 = 8'hb4;
  localparam logic [7:0] BlockTerm4 = 8'hcc;
  localparam logic [7:0] BlockTerm5 = 8'hd2;
  localparam logic [7:0] BlockTerm6 = 8'he1;
  localparam logic [7:0] BlockTerm7 = 8'hff;
  localparam logic [63:0] ErrorPayload = {{8{7'h1e}}, BlockCtrl};

  // Return {valid, C-code}; O, S and T are encoded by the block format.
  function automatic logic [7:0] encode_control(input logic [7:0] value);
    case (value)
      XgmiiIdle:  return {1'b1, 7'h00};
      XgmiiLpi:   return {1'b1, 7'h06};
      XgmiiError: return {1'b1, 7'h1e};
      8'h1c:      return {1'b1, 7'h2d};
      8'h3c:      return {1'b1, 7'h33};
      8'h7c:      return {1'b1, 7'h4b};
      8'hbc:      return {1'b1, 7'h55};
      8'hdc:      return {1'b1, 7'h66};
      8'hf7:      return {1'b1, 7'h78};
      default:    return {1'b0, 7'h1e};
    endcase
  endfunction

  // Return {valid, XGMII-byte}; invalid fields decode to /E/.
  function automatic logic [8:0] decode_control(input logic [6:0] value);
    case (value)
      7'h00:   return {1'b1, XgmiiIdle};
      7'h06:   return {1'b1, XgmiiLpi};
      7'h1e:   return {1'b1, XgmiiError};
      7'h2d:   return {1'b1, 8'h1c};
      7'h33:   return {1'b1, 8'h3c};
      7'h4b:   return {1'b1, 8'h7c};
      7'h55:   return {1'b1, 8'hbc};
      7'h66:   return {1'b1, 8'hdc};
      7'h78:   return {1'b1, 8'hf7};
      default: return {1'b0, XgmiiError};
    endcase
  endfunction

  function automatic logic is_ordered_set(input logic [7:0] value);
    return value == XgmiiSeq || value == XgmiiSig;
  endfunction

  function automatic logic [3:0] encode_ordered_set(input logic [7:0] value);
    return value == XgmiiSeq ? 4'h0 : 4'hf;
  endfunction

  function automatic logic [8:0] decode_ordered_set(input logic [3:0] value);
    case (value)
      4'h0: return {1'b1, XgmiiSeq};
      4'hf: return {1'b1, XgmiiSig};
      default: return {1'b0, XgmiiError};
    endcase
  endfunction

  function automatic logic [7:0] termination_type(input integer lane);
    case (lane)
      0: return BlockTerm0;
      1: return BlockTerm1;
      2: return BlockTerm2;
      3: return BlockTerm3;
      4: return BlockTerm4;
      5: return BlockTerm5;
      6: return BlockTerm6;
      default: return BlockTerm7;
    endcase
  endfunction
endpackage
