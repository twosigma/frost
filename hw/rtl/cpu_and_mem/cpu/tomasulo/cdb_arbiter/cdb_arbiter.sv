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
 * CDB Arbiter
 *
 * Purely-combinational, two-lane fixed-priority arbitration for functional
 * unit completions.  The implementation is a balanced top-two merge tree:
 *
 *   [MUL, MEM] [ALU, ALU2] [DIV, FP_DIV] [FP_MUL, FP_ADD]
 *        \          /             \              /
 *          high four                low four
 *                    \             /
 *                         root
 *
 * Every node carries its two highest-priority packets and their one-hot FU
 * identities.  A merge of a higher-priority list A with a lower-priority
 * list B chooses A.first/B.first for lane 0, then A.second, B.first, or
 * B.second for lane 1 according to whether A contains two, one, or zero
 * requests.  This computes both winners in one shared three-stage tree,
 * avoiding the old serial primary-encoder -> availability-mask -> secondary-
 * encoder dependency.
 *
 * Exact priority:
 *   MUL > MEM > ALU > ALU2 > DIV > FP_DIV > FP_MUL > FP_ADD
 *
 * i_clk/i_rst_n are present only for the formal harness; arbitration itself
 * has no state and adds no result latency.
 */

module cdb_arbiter (
    input logic i_clk,
    input logic i_rst_n,

    input riscv_pkg::fu_complete_t i_fu_complete_0,  // ALU
    input riscv_pkg::fu_complete_t i_fu_complete_1,  // MUL
    input riscv_pkg::fu_complete_t i_fu_complete_2,  // DIV
    input riscv_pkg::fu_complete_t i_fu_complete_3,  // MEM
    input riscv_pkg::fu_complete_t i_fu_complete_4,  // FP_ADD
    input riscv_pkg::fu_complete_t i_fu_complete_5,  // FP_MUL
    input riscv_pkg::fu_complete_t i_fu_complete_6,  // FP_DIV
    input riscv_pkg::fu_complete_t i_fu_complete_7,  // ALU2

    // Suppress visible broadcasts/grants during speculative full recovery.
    // Payload selection and o_grant_raw remain independent of this kill.
    input logic i_kill,

    output riscv_pkg::cdb_broadcast_t o_cdb,
    output riscv_pkg::cdb_broadcast_t o_cdb_2,

    // Kill-gated grant and the otherwise-identical pre-kill grant.
    output logic [riscv_pkg::NumFus-1:0] o_grant,
    output logic [riscv_pkg::NumFus-1:0] o_grant_raw
);

  typedef struct packed {
    riscv_pkg::fu_complete_t                request;
    riscv_pkg::fu_type_e                    fu_type;
    logic                    [riscv_pkg::NumFus-1:0] grant;
  } ranked_result_t;

  typedef struct packed {
    ranked_result_t first;
    ranked_result_t second;
  } top_two_t;

  // A leaf is already a sorted top-two list: its sole request followed by an
  // invalid entry.  Carry the valid-qualified one-hot source with the packet
  // so grant generation needs no final FU-index decoder.
  function automatic top_two_t make_leaf(input riscv_pkg::fu_complete_t request,
                                         input riscv_pkg::fu_type_e fu_type);
    top_two_t leaf;
    begin
      leaf               = '0;
      leaf.first.request = request;
      leaf.first.fu_type = fu_type;
      leaf.first.grant[fu_type] = request.valid;
      make_leaf = leaf;
    end
  endfunction

  // Merge two sorted lists where every entry in higher outranks every entry
  // in lower.  The second-result mux has three data arms and two select bits,
  // fitting one LUT6 per payload bit on the X3's UltraScale fabric.
  function automatic top_two_t merge_top_two(input top_two_t higher, input top_two_t lower);
    top_two_t merged;
    begin
      merged = '0;

      if (higher.first.request.valid) begin
        merged.first = higher.first;
      end else begin
        merged.first = lower.first;
      end

      if (higher.second.request.valid) begin
        merged.second = higher.second;
      end else if (higher.first.request.valid) begin
        merged.second = lower.first;
      end else begin
        merged.second = lower.second;
      end

      merge_top_two = merged;
    end
  endfunction

  top_two_t leaf_mul;
  top_two_t leaf_mem;
  top_two_t leaf_alu;
  top_two_t leaf_alu2;
  top_two_t leaf_div;
  top_two_t leaf_fp_div;
  top_two_t leaf_fp_mul;
  top_two_t leaf_fp_add;

  top_two_t pair_mul_mem;
  top_two_t pair_alu_alu2;
  top_two_t pair_div_fp_div;
  top_two_t pair_fp_mul_add;
  top_two_t high_four;
  top_two_t low_four;
  top_two_t tree_root;

  // Spell out the priority leaves rather than relying on fu_type_e's numeric
  // order, which deliberately differs from arbitration priority.
  assign leaf_mul    = make_leaf(i_fu_complete_1, riscv_pkg::FU_MUL);
  assign leaf_mem    = make_leaf(i_fu_complete_3, riscv_pkg::FU_MEM);
  assign leaf_alu    = make_leaf(i_fu_complete_0, riscv_pkg::FU_ALU);
  assign leaf_alu2   = make_leaf(i_fu_complete_7, riscv_pkg::FU_ALU2);
  assign leaf_div    = make_leaf(i_fu_complete_2, riscv_pkg::FU_DIV);
  assign leaf_fp_div = make_leaf(i_fu_complete_6, riscv_pkg::FU_FP_DIV);
  assign leaf_fp_mul = make_leaf(i_fu_complete_5, riscv_pkg::FU_FP_MUL);
  assign leaf_fp_add = make_leaf(i_fu_complete_4, riscv_pkg::FU_FP_ADD);

  assign pair_mul_mem    = merge_top_two(leaf_mul, leaf_mem);
  assign pair_alu_alu2   = merge_top_two(leaf_alu, leaf_alu2);
  assign pair_div_fp_div = merge_top_two(leaf_div, leaf_fp_div);
  assign pair_fp_mul_add = merge_top_two(leaf_fp_mul, leaf_fp_add);
  assign high_four       = merge_top_two(pair_mul_mem, pair_alu_alu2);
  assign low_four        = merge_top_two(pair_div_fp_div, pair_fp_mul_add);
  assign tree_root       = merge_top_two(high_four, low_four);

  logic [riscv_pkg::NumFus-1:0] lane0_grant_raw;
  logic [riscv_pkg::NumFus-1:0] lane1_grant_raw;

  assign lane0_grant_raw = tree_root.first.grant;
  assign lane1_grant_raw = tree_root.second.grant;
  assign o_grant_raw     = lane0_grant_raw | lane1_grant_raw;
  assign o_grant         = i_kill ? '0 : o_grant_raw;

  always_comb begin
    o_cdb.valid     = tree_root.first.request.valid && !i_kill;
    o_cdb.tag       = tree_root.first.request.tag;
    o_cdb.value     = tree_root.first.request.value;
    o_cdb.exception = tree_root.first.request.exception;
    o_cdb.exc_cause = tree_root.first.request.exc_cause;
    o_cdb.fp_flags  = tree_root.first.request.fp_flags;
    o_cdb.fu_type   = tree_root.first.fu_type;
  end

  always_comb begin
    o_cdb_2.valid     = tree_root.second.request.valid && !i_kill;
    o_cdb_2.tag       = tree_root.second.request.tag;
    o_cdb_2.value     = tree_root.second.request.value;
    o_cdb_2.exception = tree_root.second.request.exception;
    o_cdb_2.exc_cause = tree_root.second.request.exc_cause;
    o_cdb_2.fp_flags  = tree_root.second.request.fp_flags;
    o_cdb_2.fu_type   = tree_root.second.fu_type;
  end

  // ===========================================================================
  // Formal verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  logic [riscv_pkg::NumFus-1:0] valid_vec;
  always_comb begin
    valid_vec[riscv_pkg::FU_ALU]    = i_fu_complete_0.valid;
    valid_vec[riscv_pkg::FU_MUL]    = i_fu_complete_1.valid;
    valid_vec[riscv_pkg::FU_DIV]    = i_fu_complete_2.valid;
    valid_vec[riscv_pkg::FU_MEM]    = i_fu_complete_3.valid;
    valid_vec[riscv_pkg::FU_FP_ADD] = i_fu_complete_4.valid;
    valid_vec[riscv_pkg::FU_FP_MUL] = i_fu_complete_5.valid;
    valid_vec[riscv_pkg::FU_FP_DIV] = i_fu_complete_6.valid;
    valid_vec[riscv_pkg::FU_ALU2]   = i_fu_complete_7.valid;
  end

  // Independent flat reference: this is the previous implementation's
  // primary encoder, lane-0 subtraction, and secondary encoder.  Equivalence
  // below proves that the balanced tree changes topology only.
  logic                                            f_ref_found0;
  logic                                            f_ref_found1;
  riscv_pkg::fu_complete_t                         f_ref_data0;
  riscv_pkg::fu_complete_t                         f_ref_data1;
  riscv_pkg::fu_type_e                             f_ref_type0;
  riscv_pkg::fu_type_e                             f_ref_type1;
  logic                    [riscv_pkg::NumFus-1:0] f_ref_g0;
  logic                    [riscv_pkg::NumFus-1:0] f_ref_g1;
  logic                    [riscv_pkg::NumFus-1:0] f_ref_avail1;

  always_comb begin
    f_ref_found0 = 1'b0;
    f_ref_data0  = '0;
    f_ref_type0  = riscv_pkg::FU_ALU;
    f_ref_g0     = '0;

    if (i_fu_complete_1.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_1;
      f_ref_type0                     = riscv_pkg::FU_MUL;
      f_ref_g0[riscv_pkg::FU_MUL]     = 1'b1;
    end else if (i_fu_complete_3.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_3;
      f_ref_type0                     = riscv_pkg::FU_MEM;
      f_ref_g0[riscv_pkg::FU_MEM]     = 1'b1;
    end else if (i_fu_complete_0.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_0;
      f_ref_type0                     = riscv_pkg::FU_ALU;
      f_ref_g0[riscv_pkg::FU_ALU]     = 1'b1;
    end else if (i_fu_complete_7.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_7;
      f_ref_type0                     = riscv_pkg::FU_ALU2;
      f_ref_g0[riscv_pkg::FU_ALU2]    = 1'b1;
    end else if (i_fu_complete_2.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_2;
      f_ref_type0                     = riscv_pkg::FU_DIV;
      f_ref_g0[riscv_pkg::FU_DIV]     = 1'b1;
    end else if (i_fu_complete_6.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_6;
      f_ref_type0                     = riscv_pkg::FU_FP_DIV;
      f_ref_g0[riscv_pkg::FU_FP_DIV]  = 1'b1;
    end else if (i_fu_complete_5.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_5;
      f_ref_type0                     = riscv_pkg::FU_FP_MUL;
      f_ref_g0[riscv_pkg::FU_FP_MUL]  = 1'b1;
    end else if (i_fu_complete_4.valid) begin
      f_ref_found0                    = 1'b1;
      f_ref_data0                     = i_fu_complete_4;
      f_ref_type0                     = riscv_pkg::FU_FP_ADD;
      f_ref_g0[riscv_pkg::FU_FP_ADD]  = 1'b1;
    end
  end

  always_comb begin
    f_ref_avail1[riscv_pkg::FU_ALU] =
        i_fu_complete_0.valid && !f_ref_g0[riscv_pkg::FU_ALU];
    f_ref_avail1[riscv_pkg::FU_MUL] =
        i_fu_complete_1.valid && !f_ref_g0[riscv_pkg::FU_MUL];
    f_ref_avail1[riscv_pkg::FU_DIV] =
        i_fu_complete_2.valid && !f_ref_g0[riscv_pkg::FU_DIV];
    f_ref_avail1[riscv_pkg::FU_MEM] =
        i_fu_complete_3.valid && !f_ref_g0[riscv_pkg::FU_MEM];
    f_ref_avail1[riscv_pkg::FU_FP_ADD] =
        i_fu_complete_4.valid && !f_ref_g0[riscv_pkg::FU_FP_ADD];
    f_ref_avail1[riscv_pkg::FU_FP_MUL] =
        i_fu_complete_5.valid && !f_ref_g0[riscv_pkg::FU_FP_MUL];
    f_ref_avail1[riscv_pkg::FU_FP_DIV] =
        i_fu_complete_6.valid && !f_ref_g0[riscv_pkg::FU_FP_DIV];
    f_ref_avail1[riscv_pkg::FU_ALU2] =
        i_fu_complete_7.valid && !f_ref_g0[riscv_pkg::FU_ALU2];
  end

  always_comb begin
    f_ref_found1 = 1'b0;
    f_ref_data1  = '0;
    f_ref_type1  = riscv_pkg::FU_ALU;
    f_ref_g1     = '0;

    if (f_ref_avail1[riscv_pkg::FU_MUL]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_1;
      f_ref_type1                     = riscv_pkg::FU_MUL;
      f_ref_g1[riscv_pkg::FU_MUL]     = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_MEM]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_3;
      f_ref_type1                     = riscv_pkg::FU_MEM;
      f_ref_g1[riscv_pkg::FU_MEM]     = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_ALU]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_0;
      f_ref_type1                     = riscv_pkg::FU_ALU;
      f_ref_g1[riscv_pkg::FU_ALU]     = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_ALU2]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_7;
      f_ref_type1                     = riscv_pkg::FU_ALU2;
      f_ref_g1[riscv_pkg::FU_ALU2]    = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_DIV]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_2;
      f_ref_type1                     = riscv_pkg::FU_DIV;
      f_ref_g1[riscv_pkg::FU_DIV]     = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_DIV]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_6;
      f_ref_type1                     = riscv_pkg::FU_FP_DIV;
      f_ref_g1[riscv_pkg::FU_FP_DIV]  = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_MUL]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_5;
      f_ref_type1                     = riscv_pkg::FU_FP_MUL;
      f_ref_g1[riscv_pkg::FU_FP_MUL]  = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_ADD]) begin
      f_ref_found1                    = 1'b1;
      f_ref_data1                     = i_fu_complete_4;
      f_ref_type1                     = riscv_pkg::FU_FP_ADD;
      f_ref_g1[riscv_pkg::FU_FP_ADD]  = 1'b1;
    end
  end

  always_comb begin
    p_tree_lane0_grant_equiv : assert (lane0_grant_raw == f_ref_g0);
    p_tree_lane1_grant_equiv : assert (lane1_grant_raw == f_ref_g1);
    p_tree_lane0_valid_equiv : assert (tree_root.first.request.valid == f_ref_found0);
    p_tree_lane1_valid_equiv : assert (tree_root.second.request.valid == f_ref_found1);
    p_raw_grant_equiv : assert (o_grant_raw == (f_ref_g0 | f_ref_g1));
    p_kill_grant_equiv : assert (o_grant == (i_kill ? '0 : (f_ref_g0 | f_ref_g1)));
    p_lane0_visible_valid_equiv : assert (o_cdb.valid == (f_ref_found0 && !i_kill));
    p_lane1_visible_valid_equiv : assert (o_cdb_2.valid == (f_ref_found1 && !i_kill));

    if (f_ref_found0) begin
      p_tree_lane0_data_equiv : assert (tree_root.first.request == f_ref_data0);
      p_tree_lane0_type_equiv : assert (tree_root.first.fu_type == f_ref_type0);
      p_output_lane0_data_equiv :
      assert (
        o_cdb.tag == f_ref_data0.tag &&
        o_cdb.value == f_ref_data0.value &&
        o_cdb.exception == f_ref_data0.exception &&
        o_cdb.exc_cause == f_ref_data0.exc_cause &&
        o_cdb.fp_flags == f_ref_data0.fp_flags &&
        o_cdb.fu_type == f_ref_type0
      );
    end

    if (f_ref_found1) begin
      p_tree_lane1_data_equiv : assert (tree_root.second.request == f_ref_data1);
      p_tree_lane1_type_equiv : assert (tree_root.second.fu_type == f_ref_type1);
      p_output_lane1_data_equiv :
      assert (
        o_cdb_2.tag == f_ref_data1.tag &&
        o_cdb_2.value == f_ref_data1.value &&
        o_cdb_2.exception == f_ref_data1.exception &&
        o_cdb_2.exc_cause == f_ref_data1.exc_cause &&
        o_cdb_2.fp_flags == f_ref_data1.fp_flags &&
        o_cdb_2.fu_type == f_ref_type1
      );
    end
  end

  always_comb begin
    p_lane0_onehot0 : assert ($onehot0(lane0_grant_raw));
    p_lane1_onehot0 : assert ($onehot0(lane1_grant_raw));
    p_lane_grants_disjoint : assert ((lane0_grant_raw & lane1_grant_raw) == '0);
    p_grant_at_most_two : assert ($countones(o_grant_raw) <= 2);
    p_lane1_implies_lane0 :
    assert (!tree_root.second.request.valid || tree_root.first.request.valid);
    p_grant_visible_matches_lane0 : assert ((|o_grant) == o_cdb.valid);

    if (i_kill) begin
      p_kill_blocks_visible_outputs :
      assert (!o_cdb.valid && !o_cdb_2.valid && o_grant == '0);
    end

    p_grants_only_valid : assert ((o_grant_raw & ~valid_vec) == '0);
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_single_fu : cover (o_cdb.valid && $onehot(o_grant));
      cover_all_valid : cover (&valid_vec);
      cover_contention_2 : cover ($countones(valid_vec) >= 2 && o_cdb_2.valid);
      cover_no_valid : cover (!o_cdb.valid && o_grant == '0);
      cover_dual_alu :
      cover (o_grant[riscv_pkg::FU_ALU] && o_grant[riscv_pkg::FU_ALU2]);
      cover_killed_with_raw_grants : cover (i_kill && (|o_grant_raw) && !(|o_grant));
    end
  end

`endif  // FORMAL

endmodule
