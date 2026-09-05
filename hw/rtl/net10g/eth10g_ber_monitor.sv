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

// Default observation window is 125 us at the raw 161.1328125 MHz clock.
// Timer advances on EVERY clock, irrespective of block-valid pauses.
module eth10g_ber_monitor #(
    parameter int unsigned WINDOW_CYCLES = 20142
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_locked,
    input logic i_block_valid,
    input logic [1:0] i_header,
    output logic o_high_ber
);
  localparam int TimerWidth = $clog2(WINDOW_CYCLES + 1);
  logic [TimerWidth-1:0] timer;
  logic [4:0] errors, errors_now;
  always_comb begin
    errors_now = errors;
    if (i_locked && i_block_valid && !(i_header[0] ^ i_header[1]) && errors < 5'd16)
      errors_now = errors + 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst || !i_locked) begin
      timer <= '0;
      errors <= '0;
      o_high_ber <= 1'b0;
    end else begin
      if (timer == TimerWidth'(WINDOW_CYCLES - 1)) begin
        timer <= '0;
        errors <= '0;
        o_high_ber <= errors_now >= 5'd16;
      end else begin
        timer  <= timer + 1'b1;
        errors <= errors_now;
        if (errors_now >= 5'd16) o_high_ber <= 1'b1;
      end
    end
  end
endmodule
