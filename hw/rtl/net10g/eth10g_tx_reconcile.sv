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

// Reconciliation transmit fault response. XGMII words are consumed only when
// i_enable is asserted. Local fault immediately sends remote-fault ordered
// sets; remote fault sends idles. Fault assertion has priority over recovery.
//
// The MAC may finish a packet internally during a fault. After a fault clears,
// continue sending idles until an enabled, complete MAC idle word is observed,
// so a suppressed packet can never resume on the wire halfway through. Faults
// are remembered on every i_clk edge, including disabled XGMII clocks. Reset
// similarly suppresses output until an enabled idle word establishes a boundary.
module eth10g_tx_reconcile (
    input logic i_clk,
    input logic i_rst,
    input logic i_enable,
    input logic i_local_fault,
    input logic i_remote_fault,
    input logic [63:0] i_xgmii_data,
    input logic [7:0] i_xgmii_ctrl,
    output logic [63:0] o_xgmii_data,
    output logic [7:0] o_xgmii_ctrl,
    output logic o_link_ready
);
  localparam logic [63:0] IdleWord = 64'h0707070707070707;
  localparam logic [63:0] RemoteFaultWord = 64'h0200009c0200009c;
  logic suppress_frame;
  logic idle_boundary;

  assign idle_boundary = i_xgmii_ctrl == 8'hff && i_xgmii_data == IdleWord;
  assign o_link_ready  = !i_rst && !i_local_fault && !i_remote_fault && !suppress_frame;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_local_fault || i_remote_fault) begin
      suppress_frame <= 1'b1;
    end else if (i_enable && idle_boundary) begin
      suppress_frame <= 1'b0;
    end
  end

  always_comb begin
    o_xgmii_data = IdleWord;
    o_xgmii_ctrl = 8'hff;
    if (!i_rst) begin
      if (i_local_fault) begin
        o_xgmii_data = RemoteFaultWord;
        o_xgmii_ctrl = 8'h11;
      end else if (!i_remote_fault && !suppress_frame) begin
        o_xgmii_data = i_xgmii_data;
        o_xgmii_ctrl = i_xgmii_ctrl;
      end
    end
  end
endmodule
