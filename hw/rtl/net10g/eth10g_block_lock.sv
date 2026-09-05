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

// Clause 49 block synchronization: 64 consecutive good headers to acquire;
// 16 invalid headers in a 64-block observation window to lose lock.
module eth10g_block_lock (
    input logic i_clk,
    input logic i_rst,
    input logic i_signal_ok,
    input logic i_block_valid,
    input logic [1:0] i_header,
    output logic o_slip,
    output logic o_locked
);
  logic [5:0] checked;
  logic [3:0] invalid;
  logic header_good;
  assign header_good = i_header[0] ^ i_header[1];
  // Combinational with the candidate, so the gearbox never tests stale
  // pipelined candidates after a slip.
  assign o_slip = !i_rst && i_signal_ok && i_block_valid && !header_good &&
                  (!o_locked || invalid == 4'd15);

  always_ff @(posedge i_clk) begin
    if (i_rst || !i_signal_ok) begin
      checked  <= '0;
      invalid  <= '0;
      o_locked <= 1'b0;
    end else if (i_block_valid) begin
      if (!o_locked) begin
        invalid <= '0;
        if (!header_good) checked <= '0;
        else if (checked == 6'd63) begin
          checked  <= '0;
          o_locked <= 1'b1;
        end else checked <= checked + 1'b1;
      end else if (!header_good && invalid == 4'd15) begin
        checked  <= '0;
        invalid  <= '0;
        o_locked <= 1'b0;
      end else if (checked == 6'd63) begin
        checked <= '0;
        invalid <= '0;
      end else begin
        checked <= checked + 1'b1;
        if (!header_good) invalid <= invalid + 1'b1;
      end
    end
  end
endmodule
