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

// The production merge drives the normal issue path; raw inputs separately
// drive the pre-issue cofactors. RS_PRETAG_LOCAL_PROOF compares their selected
// ROB tags for arbitrary current RS state, tags, occupancy and eligibility.
module rs_raw_pretag_equiv (
    input logic i_clk
);
  (* anyseq *) riscv_pkg::fu_complete_t early_load;
  (* anyseq *) riscv_pkg::cdb_broadcast_t registered_0, registered_1;
  (* anyseq *) logic enable;
  riscv_pkg::cdb_broadcast_t merged_0, merged_1;
  mem_wakeup_merge #(
      .FORMAL_STANDALONE_ENV(1'b0)
  ) merger (
      .i_enable(enable),
      .i_load(early_load),
      .i_registered_0(registered_0),
      .i_registered_1(registered_1),
      .o_wakeup_0(merged_0),
      .o_wakeup_1(merged_1),
      .o_injected()
  );
  reservation_station #(
      .PREISSUE_VALID_COFACTOR(1'b1),
      .PREISSUE_RAW_WAKEUP(1'b1),
      .HAS_SRC3(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      .DISPATCH_REPAIR_BYPASS(1'b0)
  ) station (
      .i_clk(i_clk),
      .i_cdb(merged_0),
      .i_cdb_2(merged_1),
      .i_pre_issue_raw_valid({
        enable && early_load.valid && !early_load.exception, registered_1.valid, registered_0.valid
      }),
      .i_pre_issue_raw_tags({early_load.tag, registered_1.tag, registered_0.tag})
  );
endmodule
