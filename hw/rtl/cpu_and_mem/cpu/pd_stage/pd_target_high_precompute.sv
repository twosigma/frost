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
 * Pre-compute the two possible non-zero corrections for the high portion of
 * a PC-relative branch target.  The PD-stage instruction bits arrive from
 * BRAM late in the cycle, while i_pc_high is registered and available early.
 * Keeping these carry chains behind a hard synthesis boundary prevents Vivado
 * from folding the late branch-immediate select back into a full-XLEN adder.
 * PD captures both results beside the unchanged PC-high bank at its existing
 * redirect-target boundary.
 */
(* keep_hierarchy = "yes" *)
module pd_target_high_precompute #(
    parameter int unsigned HIGH_WIDTH = riscv_pkg::XLEN - 13
) (
    input  logic [HIGH_WIDTH-1:0] i_pc_high,
    output logic [HIGH_WIDTH-1:0] o_pc_high_plus_one,
    output logic [HIGH_WIDTH-1:0] o_pc_high_minus_one
);

  localparam logic [HIGH_WIDTH-1:0] One = {{(HIGH_WIDTH - 1) {1'b0}}, 1'b1};

  assign o_pc_high_plus_one  = i_pc_high + One;
  assign o_pc_high_minus_one = i_pc_high - One;

endmodule : pd_target_high_precompute
