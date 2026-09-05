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

// Reconciliation sublayer receive fault qualification. Observe both 32-bit
// XGMII columns in order. Four equal fault sequences qualify; 128 columns
// without a fault sequence clear both the qualification and fault status.
module eth10g_fault_monitor (
    input logic i_clk,
    input logic i_rst,
    input logic i_enable,
    input logic i_pcs_ok,
    input logic [63:0] i_xgmii_data,
    input logic [7:0] i_xgmii_ctrl,
    output logic o_local_fault,
    output logic o_remote_fault
);
  logic [1:0] fault, fault_next, sequence_type, sequence_type_next;
  logic [2:0] sequence_count, sequence_count_next;
  logic [7:0] quiet_columns, quiet_columns_next;
  logic [1:0] column_fault;
  assign o_local_fault  = !i_pcs_ok || fault == 2'd1;
  assign o_remote_fault = i_pcs_ok && fault == 2'd2;

  always_comb begin
    fault_next = fault;
    sequence_type_next = sequence_type;
    sequence_count_next = sequence_count;
    quiet_columns_next = quiet_columns;
    column_fault = '0;
    for (int column = 0; column < 2; column++) begin
      column_fault = '0;
      if (i_xgmii_ctrl[column*4+:4] == 4'b0001) begin
        case (i_xgmii_data[column*32+:32])
          32'h0100009c: column_fault = 2'd1;
          32'h0200009c: column_fault = 2'd2;
          default: column_fault = '0;
        endcase
      end
      if (column_fault != 0) begin
        quiet_columns_next = '0;
        if (column_fault != sequence_type_next) begin
          sequence_type_next  = column_fault;
          sequence_count_next = 3'd1;
        end else if (sequence_count_next < 3'd4) begin
          sequence_count_next = sequence_count_next + 1'b1;
        end
        if (sequence_count_next == 3'd4) fault_next = column_fault;
      end else if (quiet_columns_next < 8'd128) begin
        quiet_columns_next = quiet_columns_next + 1'b1;
        if (quiet_columns_next == 8'd128) begin
          fault_next = '0;
          sequence_type_next = '0;
          sequence_count_next = '0;
        end
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fault <= '0;
      sequence_type <= '0;
      sequence_count <= '0;
      quiet_columns <= '0;
    end else if (i_enable) begin
      fault <= fault_next;
      sequence_type <= sequence_type_next;
      sequence_count <= sequence_count_next;
      quiet_columns <= quiet_columns_next;
    end
  end
endmodule
