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
 * cdc_reset_sync: asynchronous-assert, synchronous-release reset.
 *
 * i_arst is a reset request level from any domain, or from none: o_rst
 * rises with i_arst without a clock edge, so a domain whose clock is absent
 * is still held in reset. o_rst falls STAGES clocks after i_arst falls,
 * aligned to i_clk, so every consumer leaves reset on the same edge. The
 * chain carries ASYNC_REG; the request must be glitch-free (a register in
 * its own domain).
 */
module cdc_reset_sync #(
    parameter int unsigned STAGES = 2
) (
    input  logic i_clk,
    input  logic i_arst,
    output logic o_rst
);
  initial begin
    if (STAGES < 2) $fatal(1, "cdc_reset_sync: STAGES must be >= 2");
  end

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] chain_q;

  // The request is, by design, a level that other logic uses as a
  // synchronous reset and this chain as an asynchronous one.
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge i_clk or posedge i_arst) begin
    if (i_arst) chain_q <= '1;
    else chain_q <= {chain_q[STAGES-2:0], 1'b0};
  end
  /* verilator lint_on SYNCASYNCNET */
  assign o_rst = chain_q[STAGES-1];
endmodule : cdc_reset_sync
