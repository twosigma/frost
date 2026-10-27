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
  localparam int unsigned Leaves = 1 << $clog2(DEPTH);
  localparam int unsigned Nodes  = 2 * Leaves - 1;
  (* keep = "true" *) logic [Nodes-1:0] ready_present, nonbranch_present, pair_present;
  for (genvar leaf = 0; leaf < Leaves; leaf++) begin : gen_presence_leaf
    localparam int unsigned Node = Leaves - 1 + leaf;
    if (leaf < DEPTH) begin : gen_entry
      assign ready_present[Node] = i_ready[leaf];
      assign nonbranch_present[Node] = i_ready[leaf] && !i_branch_class[leaf];
    end else begin : gen_padding
      assign ready_present[Node] = 1'b0;
      assign nonbranch_present[Node] = 1'b0;
    end
    assign pair_present[Node] = 1'b0;
  end
  for (genvar node = 0; node < Leaves - 1; node++) begin : gen_presence_node
    localparam int unsigned Left  = 2 * node + 1;
    localparam int unsigned Right = 2 * node + 2;
    assign ready_present[node] = ready_present[Left] || ready_present[Right];
    assign nonbranch_present[node] = nonbranch_present[Left] || nonbranch_present[Right];
    assign pair_present[node] = pair_present[Left] || pair_present[Right] ||
        (ready_present[Left] && nonbranch_present[Right]);
  end
  assign o_issue_2_valid = pair_present[0];
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
