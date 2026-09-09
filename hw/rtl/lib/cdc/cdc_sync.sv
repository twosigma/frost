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
 * cdc_sync: two-flop level synchronizer.
 *
 * Each bit of i_async is an independent level from another clock domain,
 * never a multi-bit value that must arrive atomically (Gray coding or a
 * handshake covers those). STAGES flops carry ASYNC_REG so the tools keep
 * them adjacent; o_sync lags the input by STAGES cycles plus metastability
 * resolution. The reset is synchronous, to RESET_VALUE.
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
