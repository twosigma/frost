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

module coherent_rs_issue2_selector #(
    parameter int unsigned DEPTH = 16
) (
    input logic [DEPTH-1:0] i_ready,
    input logic [DEPTH-1:0] i_branch_class,
    output logic o_issue_2_valid,
    output logic [$clog2(DEPTH)-1:0] o_issue_2_idx,
    output logic [DEPTH-1:0] o_issue_2_onehot
);
  localparam int unsigned IdxWidth = $clog2(DEPTH);
  (* keep = "true" *) logic [DEPTH-1:0] first_ready, eligible;
  assign first_ready = i_ready & (~i_ready + DEPTH'(1));
  assign eligible = i_ready & ~i_branch_class & ~first_ready;
  assign o_issue_2_onehot = eligible & (~eligible + DEPTH'(1));
  logic [DEPTH-1:0] later_nonbranch_ready;
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_presence
    if (entry == 0) begin : gen_first
      assign later_nonbranch_ready[entry] = 1'b0;
    end else begin : gen_later
      (* keep = "true" *) logic earlier_ready;
      assign earlier_ready = |i_ready[entry-1:0];
      assign later_nonbranch_ready[entry] =
          i_ready[entry] && !i_branch_class[entry] && earlier_ready;
    end
  end
  assign o_issue_2_valid = |later_nonbranch_ready;
  always_comb begin
    o_issue_2_idx = '0;
    for (int entry = 0; entry < DEPTH; entry++) begin
      o_issue_2_idx |= IdxWidth'(entry) & {IdxWidth{o_issue_2_onehot[entry]}};
    end
  end
`ifdef FORMAL
  logic reference_valid;
  logic [IdxWidth-1:0] reference_index;
  logic [DEPTH-1:0] reference_onehot;
  rs_issue2_selector #(
      .DEPTH(DEPTH)
  ) reference_selector (
      .i_ready,
      .i_branch_class,
      .o_issue_2_valid(reference_valid),
      .o_issue_2_idx(reference_index),
      .o_issue_2_onehot(reference_onehot)
  );
  always_comb begin
    p_issue_valid_exact : assert (o_issue_2_valid == reference_valid);
    p_issue_index_exact : assert (o_issue_2_idx == reference_index);
    p_issue_onehot_exact : assert (o_issue_2_onehot == reference_onehot);
  end
`endif
endmodule
