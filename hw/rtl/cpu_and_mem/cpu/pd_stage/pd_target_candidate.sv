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
 * One format-specific PC-relative branch-target candidate.  The late branch
 * immediate drives only a narrow low add and a two-bit correction code.  PD
 * instantiates independent native and compressed candidates, selects their
 * low result/code, and captures that selection at its existing redirect
 * boundary.  The full-width PC-high banks never enter this late carry cone.
 */
(* keep_hierarchy = "yes" *)
module pd_target_candidate #(
    parameter int unsigned SPLIT = 13
) (
    input  logic [SPLIT-1:0] i_pc_low,
    input  logic [SPLIT-1:0] i_imm_low,
    output logic [SPLIT-1:0] o_target_low,
    output logic [      1:0] o_high_select
);

  (* keep = "true" *) logic [SPLIT:0] low_sum;

  assign low_sum = {1'b0, i_pc_low} + {1'b0, i_imm_low};
  assign o_target_low = low_sum[SPLIT-1:0];

  always_comb begin
    case ({
      i_imm_low[SPLIT-1], low_sum[SPLIT]
    })
      2'b00, 2'b11: o_high_select = 2'b00;  // PC high unchanged
      2'b01: o_high_select = 2'b01;  // PC high + 1
      2'b10: o_high_select = 2'b10;  // PC high - 1
      default: o_high_select = 2'bxx;
    endcase
  end

endmodule : pd_target_candidate
