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
 * Precompute pc_high+1 and pc_high-1 for a PC-relative branch target. The
 * synthesis boundary keeps Vivado from merging these with the immediate
 * select, for timing. PD captures both results and the unmodified high bits.
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
