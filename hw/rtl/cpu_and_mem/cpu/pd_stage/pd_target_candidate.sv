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
 * immediate drives only a narrow low add.  PD captures the low result and the
 * raw {immediate sign, low-add carry} state at its existing redirect boundary;
 * the following cycle decodes that state as H, H+1, or H-1.  Keeping the
 * correction decode after the boundary removes a logic level from the late
 * carry cone, while the full-width PC-high banks remain outside it.
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

  // Raw boundary state.  If s is the sign-extended immediate's sign and c is
  // the low-add carry, the high result is exactly H+c-s: 00/11 keep H, 01
  // selects H+1, and 10 selects H-1.  Decode only after the redirect FFs.
  assign o_high_select = {i_imm_low[SPLIT-1], low_sum[SPLIT]};

endmodule : pd_target_candidate
