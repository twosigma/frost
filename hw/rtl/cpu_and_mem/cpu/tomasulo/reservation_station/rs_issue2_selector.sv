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

// Balanced selector for the INT reservation station's second issue port. It
// returns the lowest-index ready nonbranch entry other than the globally
// lowest-index ready entry. Port 0 stays on reservation_station's serial
// priority encoder and does not depend on this tree.
//
// The exclusion of the global winner is unconditional: it holds even when
// port 0 is back-pressured and does not fire, which is what the serial
// reference in the FORMAL block below checks. Each subtree carries only:
//   * whether it contains any ready entry,
//   * its first ready nonbranch entry, and
//   * its first ready nonbranch entry after excluding its first ready entry.
//
// Pairwise merges of those three give the exact serial result in
// ceil(log2(DEPTH)) levels, without feeding port 0's issue_idx into another
// priority encoder.
module rs_issue2_selector #(
    parameter int unsigned DEPTH = 16
) (
    input logic [DEPTH-1:0] i_ready,
    input logic [DEPTH-1:0] i_branch_class,

    output logic                     o_issue_2_valid,
    output logic [$clog2(DEPTH)-1:0] o_issue_2_idx,
    output logic [        DEPTH-1:0] o_issue_2_onehot
);

  localparam int unsigned IdxWidth = $clog2(DEPTH);
  localparam int unsigned TreeLeaves = 1 << $clog2(DEPTH);
  localparam int unsigned TreeNodes = 2 * TreeLeaves - 1;

  // Heap layout: root [0], children of node n at [2*n+1]/[2*n+2], and padded
  // leaves at [TreeLeaves-1 .. 2*TreeLeaves-2]. The node state lives in
  // parallel arrays rather than an unpacked array of structs, because
  // Vivado, Verilator, and Yosys all elaborate parallel arrays consistently.
  logic [TreeNodes-1:0] tree_any_ready;
  logic [TreeNodes-1:0] tree_first_nonbranch_valid;
  logic [IdxWidth-1:0] tree_first_nonbranch_idx[TreeNodes];
  logic [DEPTH-1:0] tree_first_nonbranch_onehot[TreeNodes];
  logic [TreeNodes-1:0] tree_issue2_valid;
  logic [IdxWidth-1:0] tree_issue2_idx[TreeNodes];
  logic [DEPTH-1:0] tree_issue2_onehot[TreeNodes];

  for (genvar leaf = 0; leaf < TreeLeaves; leaf++) begin : gen_select_leaf
    localparam int unsigned LeafNode = TreeLeaves - 1 + leaf;

    if (leaf < DEPTH) begin : gen_real_leaf
      localparam logic [IdxWidth-1:0] LeafIdx = IdxWidth'(leaf);
      localparam logic [DEPTH-1:0] LeafOnehot = ({{(DEPTH - 1) {1'b0}}, 1'b1} << leaf);

      assign tree_any_ready[LeafNode] = i_ready[leaf];
      assign tree_first_nonbranch_valid[LeafNode] = i_ready[leaf] && !i_branch_class[leaf];
      assign tree_first_nonbranch_idx[LeafNode] =
          tree_first_nonbranch_valid[LeafNode] ? LeafIdx : '0;
      assign tree_first_nonbranch_onehot[LeafNode] =
          tree_first_nonbranch_valid[LeafNode] ? LeafOnehot : '0;
      assign tree_issue2_valid[LeafNode] = 1'b0;
      assign tree_issue2_idx[LeafNode] = '0;
      assign tree_issue2_onehot[LeafNode] = '0;
    end else begin : gen_padding_leaf
      assign tree_any_ready[LeafNode] = 1'b0;
      assign tree_first_nonbranch_valid[LeafNode] = 1'b0;
      assign tree_first_nonbranch_idx[LeafNode] = '0;
      assign tree_first_nonbranch_onehot[LeafNode] = '0;
      assign tree_issue2_valid[LeafNode] = 1'b0;
      assign tree_issue2_idx[LeafNode] = '0;
      assign tree_issue2_onehot[LeafNode] = '0;
    end
  end

  for (genvar node = 0; node < TreeLeaves - 1; node++) begin : gen_select_merge
    localparam int unsigned LeftNode = 2 * node + 1;
    localparam int unsigned RightNode = 2 * node + 2;

    assign tree_any_ready[node] = tree_any_ready[LeftNode] || tree_any_ready[RightNode];

    assign tree_first_nonbranch_valid[node] =
        tree_first_nonbranch_valid[LeftNode] ||
        tree_first_nonbranch_valid[RightNode];
    assign tree_first_nonbranch_idx[node] =
        tree_first_nonbranch_valid[LeftNode] ?
        tree_first_nonbranch_idx[LeftNode] : tree_first_nonbranch_idx[RightNode];
    assign tree_first_nonbranch_onehot[node] =
        tree_first_nonbranch_valid[LeftNode] ?
        tree_first_nonbranch_onehot[LeftNode] : tree_first_nonbranch_onehot[RightNode];

    // If the left subtree is empty, the global first ready entry lives in the
    // right subtree and its already-excluded result is exact. Otherwise the
    // global winner lives on the left: prefer that subtree's alternate, then
    // fall through to the right subtree's first nonbranch.
    assign tree_issue2_valid[node] =
        !tree_any_ready[LeftNode] ? tree_issue2_valid[RightNode] :
        (tree_issue2_valid[LeftNode] || tree_first_nonbranch_valid[RightNode]);
    assign tree_issue2_idx[node] =
        !tree_any_ready[LeftNode] ? tree_issue2_idx[RightNode] :
        (tree_issue2_valid[LeftNode] ?
         tree_issue2_idx[LeftNode] : tree_first_nonbranch_idx[RightNode]);
    assign tree_issue2_onehot[node] =
        !tree_any_ready[LeftNode] ? tree_issue2_onehot[RightNode] :
        (tree_issue2_valid[LeftNode] ?
         tree_issue2_onehot[LeftNode] : tree_first_nonbranch_onehot[RightNode]);
  end

  assign o_issue_2_valid = tree_issue2_valid[0];
  assign o_issue_2_idx = tree_issue2_idx[0];
  assign o_issue_2_onehot = tree_issue2_onehot[0];

`ifndef SYNTHESIS
`ifndef FORMAL
  initial begin
    if (DEPTH < 2) $fatal(1, "rs_issue2_selector requires DEPTH >= 2");
  end
`endif
`endif

`ifdef FORMAL
  // Serial reference model, asserted equivalent below. The ready and branch
  // vectors are unconstrained, so the depth-one proof at the standalone
  // default DEPTH covers the selector's whole combinational input space.
  logic reference_issue_valid;
  logic [IdxWidth-1:0] reference_issue_idx;
  logic reference_issue_2_valid;
  logic [IdxWidth-1:0] reference_issue_2_idx;
  logic [DEPTH-1:0] reference_issue_2_onehot;

  always_comb begin
    reference_issue_valid = 1'b0;
    reference_issue_idx = '0;
    reference_issue_2_valid = 1'b0;
    reference_issue_2_idx = '0;
    reference_issue_2_onehot = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (i_ready[i] && !reference_issue_valid) begin
        reference_issue_valid = 1'b1;
        reference_issue_idx   = IdxWidth'(i);
      end
    end

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (i_ready[i] && !i_branch_class[i] &&
          (IdxWidth'(i) != reference_issue_idx) &&
          !reference_issue_2_valid) begin
        reference_issue_2_valid = 1'b1;
        reference_issue_2_idx = IdxWidth'(i);
        reference_issue_2_onehot[i] = 1'b1;
      end
    end

    p_issue_2_valid_equivalent : assert (o_issue_2_valid == reference_issue_2_valid);
    p_issue_2_idx_equivalent : assert (o_issue_2_idx == reference_issue_2_idx);
    p_issue_2_onehot_equivalent : assert (o_issue_2_onehot == reference_issue_2_onehot);
  end
`endif

endmodule : rs_issue2_selector
