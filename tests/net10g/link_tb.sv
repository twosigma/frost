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

// Independent clocked controls for block synchronization, BER and RS faults.
module link_tb (
    input logic clk,
    input logic rst,
    input logic signal_ok,
    input logic block_valid,
    input logic [1:0] header,
    output logic slip,
    output logic locked,
    input logic ber_locked,
    input logic ber_valid,
    input logic [1:0] ber_header,
    output logic high_ber_fast,
    output logic high_ber_default,
    input logic fault_enable,
    input logic pcs_ok,
    input logic [63:0] xgmii_data,
    input logic [7:0] xgmii_ctrl,
    output logic local_fault,
    output logic remote_fault
);
  eth10g_block_lock block_sync (
      .i_clk(clk),
      .i_rst(rst),
      .i_signal_ok(signal_ok),
      .i_block_valid(block_valid),
      .i_header(header),
      .o_slip(slip),
      .o_locked(locked)
  );
  eth10g_ber_monitor #(
      .WINDOW_CYCLES(128)
  ) fast_ber (
      .i_clk(clk),
      .i_rst(rst),
      .i_locked(ber_locked),
      .i_block_valid(ber_valid),
      .i_header(ber_header),
      .o_high_ber(high_ber_fast)
  );
  eth10g_ber_monitor default_ber (
      .i_clk(clk),
      .i_rst(rst),
      .i_locked(ber_locked),
      .i_block_valid(ber_valid),
      .i_header(ber_header),
      .o_high_ber(high_ber_default)
  );
  eth10g_fault_monitor faults (
      .i_clk(clk),
      .i_rst(rst),
      .i_enable(fault_enable),
      .i_pcs_ok(pcs_ok),
      .i_xgmii_data(xgmii_data),
      .i_xgmii_ctrl(xgmii_ctrl),
      .o_local_fault(local_fault),
      .o_remote_fault(remote_fault)
  );
endmodule
