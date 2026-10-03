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

/*
 * cdc_sync: level synchronizer, STAGES flops deep (two by default).
 *
 * Each bit of i_async is synchronized independently, so a multi-bit value
 * must change one bit at a time (Gray code) or cross under a handshake. The
 * STAGES flops carry ASYNC_REG so the tools keep them adjacent. A change
 * reaches o_sync STAGES or STAGES + 1 clock edges later, depending on how the
 * first flop resolves. The reset is synchronous, to RESET_VALUE.
 */
module cdc_sync #(
    parameter int unsigned WIDTH = 1,
    parameter int unsigned STAGES = 2,
    parameter logic [WIDTH-1:0] RESET_VALUE = '0
) (
    input  logic             i_clk,
    input  logic             i_rst,
    input  logic [WIDTH-1:0] i_async,
    output logic [WIDTH-1:0] o_sync
);
  initial begin
    if (STAGES < 2) $fatal(1, "cdc_sync: STAGES must be >= 2");
  end

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stage_q[STAGES];
`ifdef FORMAL
  initial for (int s = 0; s < int'(STAGES); s++) stage_q[s] = RESET_VALUE;
`endif

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int s = 0; s < int'(STAGES); s++) stage_q[s] <= RESET_VALUE;
    end else begin
      stage_q[0] <= i_async;
      for (int s = 1; s < int'(STAGES); s++) stage_q[s] <= stage_q[s-1];
    end
  end
  assign o_sync = stage_q[STAGES-1];
endmodule : cdc_sync
