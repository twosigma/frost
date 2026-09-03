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
 * Combinational two-lane fixed-priority arbitration for functional unit
 * completions, built as a balanced top-two merge tree:
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
 * requests.  One shared three-stage tree computes both winners and drops the
 * old serial primary-encoder -> availability-mask -> secondary-encoder
 * dependency.
 *
 * A live, non-pending value from either combinational integer ALU travels
 * beside the tree and is restored once its winner is known.  Held adapter
 * values and test-injected values stay ordinary tree payloads.  The wrapper
 * supplies the live/fallback partition documented with the ports below and
 * proves that contract at its own level rather than assuming it here (see
 * FORMAL_ASSUME_VALUE_SOURCE_CONTRACT).  The split keeps the timing-dominant
 * stage2 -> ALU -> CDB live-value path to one final three-arm value mux, and
 * leaves packet and arbitration semantics unchanged.
 *
 * Exact priority:
 *   MUL > MEM > ALU > ALU2 > DIV > FP_DIV > FP_MUL > FP_ADD
 *
 * i_clk/i_rst_n exist only for the formal harness.  Arbitration has no state
 * and adds no result latency.
 */

// Preserve this small boundary so synthesis cannot algebraically fold either
// live ALU value back into the merge tree.  With two pre-qualified selects,
// each output bit is a three-data/two-select function that fits one LUT6.
(* keep_hierarchy = "yes" *)
module cdb_live_value_restore #(
    parameter int unsigned WIDTH = riscv_pkg::FLEN
) (
    input  logic [WIDTH-1:0] i_tree_fallback_value,
    input  logic             i_select_alu_live,
    input  logic [WIDTH-1:0] i_alu_live_value,
    input  logic             i_select_alu2_live,
    input  logic [WIDTH-1:0] i_alu2_live_value,
    output logic [WIDTH-1:0] o_value
);

  (* keep = "true" *) logic [WIDTH-1:0] restored_value;
  always_comb begin
    if (i_select_alu_live) restored_value = i_alu_live_value;
    else if (i_select_alu2_live) restored_value = i_alu2_live_value;
    else restored_value = i_tree_fallback_value;
  end
  assign o_value = restored_value;

endmodule : cdb_live_value_restore

module cdb_arbiter #(
    // The standalone formal top assumes the documented auxiliary-value
    // contract.  The wrapper sets this to 0 and proves the contract itself,
    // avoiding a submodule assumption that could make that proof vacuous.
    parameter bit FORMAL_ASSUME_VALUE_SOURCE_CONTRACT = 1'b1
) (
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

    // Auxiliary value paths for the two combinational ALUs.  Exactly one side
    // of each partition is meaningful for a valid packet:
    //   value_is_live  -> live_value == i_fu_complete_N.value
    //   !value_is_live -> tree_fallback_value == i_fu_complete_N.value
    // The wrapper uses live only for a valid, non-pending shim pass-through;
    // held adapter and test-injection values use the fallback side.  The held
    // fallback comes from the adapter payload-register Q, not from its
    // effective pending/live output mux.
    input logic                       i_alu_value_is_live,
    input logic [riscv_pkg::FLEN-1:0] i_alu_live_value,
    input logic [riscv_pkg::FLEN-1:0] i_alu_tree_fallback_value,
    input logic                       i_alu2_value_is_live,
    input logic [riscv_pkg::FLEN-1:0] i_alu2_live_value,
    input logic [riscv_pkg::FLEN-1:0] i_alu2_tree_fallback_value,

    // Suppress visible broadcasts/grants during speculative full recovery.
    // Payload selection and o_grant_raw remain independent of this kill.
    input logic i_kill,

    output riscv_pkg::cdb_broadcast_t o_cdb,
    output riscv_pkg::cdb_broadcast_t o_cdb_2,

    // Pre-restore lane values and valid-qualified live-source selects.  These
    // are exact aliases of the merge-tree outputs and the selectors used by
    // o_cdb/o_cdb_2.  The wrapper captures them at its existing CDB edge and
    // performs the same value restore after Q for registered consumers.
    output logic [riscv_pkg::FLEN-1:0] o_lane0_tree_fallback_value,
    output logic [riscv_pkg::FLEN-1:0] o_lane1_tree_fallback_value,
    output logic                       o_lane0_select_alu_live,
    output logic                       o_lane0_select_alu2_live,
    output logic                       o_lane1_select_alu_live,
    output logic                       o_lane1_select_alu2_live,

    // Kill-gated grant and the otherwise-identical pre-kill grant.
    output logic [riscv_pkg::NumFus-1:0] o_grant,
    output logic [riscv_pkg::NumFus-1:0] o_grant_raw
);

  typedef struct packed {
    riscv_pkg::fu_complete_t      request;
    riscv_pkg::fu_type_e          fu_type;
    logic [riscv_pkg::NumFus-1:0] grant;
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
      leaf                      = '0;
      leaf.first.request        = request;
      leaf.first.fu_type        = fu_type;
      leaf.first.grant[fu_type] = request.valid;
      make_leaf                 = leaf;
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

  // The tree always sees the independently constructed fallback value.  In a
  // live-shim cycle that value goes unused, and it carries no dependency on
  // the live ALU data.  Held and test-injected values remain ordinary payloads
  // and keep the generic tree behavior.
  riscv_pkg::fu_complete_t alu_tree_request;
  riscv_pkg::fu_complete_t alu2_tree_request;
  always_comb begin
    alu_tree_request        = i_fu_complete_0;
    alu_tree_request.value  = i_alu_tree_fallback_value;
    alu2_tree_request       = i_fu_complete_7;
    alu2_tree_request.value = i_alu2_tree_fallback_value;
  end

  // Spell out the priority leaves rather than relying on fu_type_e's numeric
  // order, which does not match arbitration priority.
  assign leaf_mul        = make_leaf(i_fu_complete_1, riscv_pkg::FU_MUL);
  assign leaf_mem        = make_leaf(i_fu_complete_3, riscv_pkg::FU_MEM);
  assign leaf_alu        = make_leaf(alu_tree_request, riscv_pkg::FU_ALU);
  assign leaf_alu2       = make_leaf(alu2_tree_request, riscv_pkg::FU_ALU2);
  assign leaf_div        = make_leaf(i_fu_complete_2, riscv_pkg::FU_DIV);
  assign leaf_fp_div     = make_leaf(i_fu_complete_6, riscv_pkg::FU_FP_DIV);
  assign leaf_fp_mul     = make_leaf(i_fu_complete_5, riscv_pkg::FU_FP_MUL);
  assign leaf_fp_add     = make_leaf(i_fu_complete_4, riscv_pkg::FU_FP_ADD);

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

  // Raw grants are already valid-qualified and stay active during kill, which
  // keeps i_kill out of the payload path.  Pre-qualify the two live choices
  // per lane so the protected restore boundary is one three-arm mux on each
  // payload bit.
  logic lane0_select_alu_live;
  logic lane0_select_alu2_live;
  logic lane1_select_alu_live;
  logic lane1_select_alu2_live;
  assign lane0_select_alu_live       = lane0_grant_raw[riscv_pkg::FU_ALU] && i_alu_value_is_live;
  assign lane0_select_alu2_live      = lane0_grant_raw[riscv_pkg::FU_ALU2] && i_alu2_value_is_live;
  assign lane1_select_alu_live       = lane1_grant_raw[riscv_pkg::FU_ALU] && i_alu_value_is_live;
  assign lane1_select_alu2_live      = lane1_grant_raw[riscv_pkg::FU_ALU2] && i_alu2_value_is_live;

  assign o_lane0_tree_fallback_value = tree_root.first.request.value;
  assign o_lane1_tree_fallback_value = tree_root.second.request.value;
  assign o_lane0_select_alu_live     = lane0_select_alu_live;
  assign o_lane0_select_alu2_live    = lane0_select_alu2_live;
  assign o_lane1_select_alu_live     = lane1_select_alu_live;
  assign o_lane1_select_alu2_live    = lane1_select_alu2_live;

  (* keep = "true" *)logic [riscv_pkg::FLEN-1:0] lane0_restored_value;
  (* keep = "true" *)logic [riscv_pkg::FLEN-1:0] lane1_restored_value;

  (* dont_touch = "yes" *) cdb_live_value_restore u_lane0_live_value_restore (
      .i_tree_fallback_value(tree_root.first.request.value),
      .i_select_alu_live    (lane0_select_alu_live),
      .i_alu_live_value     (i_alu_live_value),
      .i_select_alu2_live   (lane0_select_alu2_live),
      .i_alu2_live_value    (i_alu2_live_value),
      .o_value              (lane0_restored_value)
  );

  (* dont_touch = "yes" *) cdb_live_value_restore u_lane1_live_value_restore (
      .i_tree_fallback_value(tree_root.second.request.value),
      .i_select_alu_live    (lane1_select_alu_live),
      .i_alu_live_value     (i_alu_live_value),
      .i_select_alu2_live   (lane1_select_alu2_live),
      .i_alu2_live_value    (i_alu2_live_value),
      .o_value              (lane1_restored_value)
  );

  always_comb begin
    o_cdb.valid     = tree_root.first.request.valid && !i_kill;
    o_cdb.tag       = tree_root.first.request.tag;
    o_cdb.value     = lane0_restored_value;
    o_cdb.exception = tree_root.first.request.exception;
    o_cdb.exc_cause = tree_root.first.request.exc_cause;
    o_cdb.fp_flags  = tree_root.first.request.fp_flags;
    o_cdb.fu_type   = tree_root.first.fu_type;
  end

  always_comb begin
    o_cdb_2.valid     = tree_root.second.request.valid && !i_kill;
    o_cdb_2.tag       = tree_root.second.request.tag;
    o_cdb_2.value     = lane1_restored_value;
    o_cdb_2.exception = tree_root.second.request.exception;
    o_cdb_2.exc_cause = tree_root.second.request.exc_cause;
    o_cdb_2.fp_flags  = tree_root.second.request.fp_flags;
    o_cdb_2.fu_type   = tree_root.second.fu_type;
  end

  // ===========================================================================
  // Formal verification
  // ===========================================================================
`ifdef FORMAL

  generate
    if (FORMAL_ASSUME_VALUE_SOURCE_CONTRACT) begin : gen_assume_value_source_contract
      always_comb begin
        if (i_alu_value_is_live) begin
          a_alu_live_packet_valid : assume (i_fu_complete_0.valid);
          a_alu_live_value_contract : assume (i_alu_live_value == i_fu_complete_0.value);
        end else begin
          a_alu_fallback_value_contract :
          assume (i_alu_tree_fallback_value == i_fu_complete_0.value);
        end

        if (i_alu2_value_is_live) begin
          a_alu2_live_packet_valid : assume (i_fu_complete_7.valid);
          a_alu2_live_value_contract : assume (i_alu2_live_value == i_fu_complete_7.value);
        end else begin
          a_alu2_fallback_value_contract :
          assume (i_alu2_tree_fallback_value == i_fu_complete_7.value);
        end
      end
    end
  endgenerate

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

  // Independent flat reference: the previous implementation's primary
  // encoder, lane-0 subtraction, and secondary encoder.  The equivalence
  // assertions below prove that the balanced tree changes topology only.
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
      f_ref_found0                = 1'b1;
      f_ref_data0                 = i_fu_complete_1;
      f_ref_type0                 = riscv_pkg::FU_MUL;
      f_ref_g0[riscv_pkg::FU_MUL] = 1'b1;
    end else if (i_fu_complete_3.valid) begin
      f_ref_found0                = 1'b1;
      f_ref_data0                 = i_fu_complete_3;
      f_ref_type0                 = riscv_pkg::FU_MEM;
      f_ref_g0[riscv_pkg::FU_MEM] = 1'b1;
    end else if (i_fu_complete_0.valid) begin
      f_ref_found0                = 1'b1;
      f_ref_data0                 = i_fu_complete_0;
      f_ref_type0                 = riscv_pkg::FU_ALU;
      f_ref_g0[riscv_pkg::FU_ALU] = 1'b1;
    end else if (i_fu_complete_7.valid) begin
      f_ref_found0                 = 1'b1;
      f_ref_data0                  = i_fu_complete_7;
      f_ref_type0                  = riscv_pkg::FU_ALU2;
      f_ref_g0[riscv_pkg::FU_ALU2] = 1'b1;
    end else if (i_fu_complete_2.valid) begin
      f_ref_found0                = 1'b1;
      f_ref_data0                 = i_fu_complete_2;
      f_ref_type0                 = riscv_pkg::FU_DIV;
      f_ref_g0[riscv_pkg::FU_DIV] = 1'b1;
    end else if (i_fu_complete_6.valid) begin
      f_ref_found0                   = 1'b1;
      f_ref_data0                    = i_fu_complete_6;
      f_ref_type0                    = riscv_pkg::FU_FP_DIV;
      f_ref_g0[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (i_fu_complete_5.valid) begin
      f_ref_found0                   = 1'b1;
      f_ref_data0                    = i_fu_complete_5;
      f_ref_type0                    = riscv_pkg::FU_FP_MUL;
      f_ref_g0[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (i_fu_complete_4.valid) begin
      f_ref_found0                   = 1'b1;
      f_ref_data0                    = i_fu_complete_4;
      f_ref_type0                    = riscv_pkg::FU_FP_ADD;
      f_ref_g0[riscv_pkg::FU_FP_ADD] = 1'b1;
    end
  end

  always_comb begin
    f_ref_avail1[riscv_pkg::FU_ALU] = i_fu_complete_0.valid && !f_ref_g0[riscv_pkg::FU_ALU];
    f_ref_avail1[riscv_pkg::FU_MUL] = i_fu_complete_1.valid && !f_ref_g0[riscv_pkg::FU_MUL];
    f_ref_avail1[riscv_pkg::FU_DIV] = i_fu_complete_2.valid && !f_ref_g0[riscv_pkg::FU_DIV];
    f_ref_avail1[riscv_pkg::FU_MEM] = i_fu_complete_3.valid && !f_ref_g0[riscv_pkg::FU_MEM];
    f_ref_avail1[riscv_pkg::FU_FP_ADD] = i_fu_complete_4.valid && !f_ref_g0[riscv_pkg::FU_FP_ADD];
    f_ref_avail1[riscv_pkg::FU_FP_MUL] = i_fu_complete_5.valid && !f_ref_g0[riscv_pkg::FU_FP_MUL];
    f_ref_avail1[riscv_pkg::FU_FP_DIV] = i_fu_complete_6.valid && !f_ref_g0[riscv_pkg::FU_FP_DIV];
    f_ref_avail1[riscv_pkg::FU_ALU2] = i_fu_complete_7.valid && !f_ref_g0[riscv_pkg::FU_ALU2];
  end

  always_comb begin
    f_ref_found1 = 1'b0;
    f_ref_data1  = '0;
    f_ref_type1  = riscv_pkg::FU_ALU;
    f_ref_g1     = '0;

    if (f_ref_avail1[riscv_pkg::FU_MUL]) begin
      f_ref_found1                = 1'b1;
      f_ref_data1                 = i_fu_complete_1;
      f_ref_type1                 = riscv_pkg::FU_MUL;
      f_ref_g1[riscv_pkg::FU_MUL] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_MEM]) begin
      f_ref_found1                = 1'b1;
      f_ref_data1                 = i_fu_complete_3;
      f_ref_type1                 = riscv_pkg::FU_MEM;
      f_ref_g1[riscv_pkg::FU_MEM] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_ALU]) begin
      f_ref_found1                = 1'b1;
      f_ref_data1                 = i_fu_complete_0;
      f_ref_type1                 = riscv_pkg::FU_ALU;
      f_ref_g1[riscv_pkg::FU_ALU] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_ALU2]) begin
      f_ref_found1                 = 1'b1;
      f_ref_data1                  = i_fu_complete_7;
      f_ref_type1                  = riscv_pkg::FU_ALU2;
      f_ref_g1[riscv_pkg::FU_ALU2] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_DIV]) begin
      f_ref_found1                = 1'b1;
      f_ref_data1                 = i_fu_complete_2;
      f_ref_type1                 = riscv_pkg::FU_DIV;
      f_ref_g1[riscv_pkg::FU_DIV] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_DIV]) begin
      f_ref_found1                   = 1'b1;
      f_ref_data1                    = i_fu_complete_6;
      f_ref_type1                    = riscv_pkg::FU_FP_DIV;
      f_ref_g1[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_MUL]) begin
      f_ref_found1                   = 1'b1;
      f_ref_data1                    = i_fu_complete_5;
      f_ref_type1                    = riscv_pkg::FU_FP_MUL;
      f_ref_g1[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (f_ref_avail1[riscv_pkg::FU_FP_ADD]) begin
      f_ref_found1                   = 1'b1;
      f_ref_data1                    = i_fu_complete_4;
      f_ref_type1                    = riscv_pkg::FU_FP_ADD;
      f_ref_g1[riscv_pkg::FU_FP_ADD] = 1'b1;
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
      p_tree_lane0_metadata_equiv :
      assert (
        tree_root.first.request.valid == f_ref_data0.valid &&
        tree_root.first.request.tag == f_ref_data0.tag &&
        tree_root.first.request.exception == f_ref_data0.exception &&
        tree_root.first.request.exc_cause == f_ref_data0.exc_cause &&
        tree_root.first.request.fp_flags == f_ref_data0.fp_flags
      );
      if (f_ref_type0 == riscv_pkg::FU_ALU) begin
        p_tree_lane0_alu_fallback_value :
        assert (tree_root.first.request.value == i_alu_tree_fallback_value);
      end else if (f_ref_type0 == riscv_pkg::FU_ALU2) begin
        p_tree_lane0_alu2_fallback_value :
        assert (tree_root.first.request.value == i_alu2_tree_fallback_value);
      end else begin
        p_tree_lane0_non_alu_value_equiv :
        assert (tree_root.first.request.value == f_ref_data0.value);
      end
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
      p_tree_lane1_metadata_equiv :
      assert (
        tree_root.second.request.valid == f_ref_data1.valid &&
        tree_root.second.request.tag == f_ref_data1.tag &&
        tree_root.second.request.exception == f_ref_data1.exception &&
        tree_root.second.request.exc_cause == f_ref_data1.exc_cause &&
        tree_root.second.request.fp_flags == f_ref_data1.fp_flags
      );
      if (f_ref_type1 == riscv_pkg::FU_ALU) begin
        p_tree_lane1_alu_fallback_value :
        assert (tree_root.second.request.value == i_alu_tree_fallback_value);
      end else if (f_ref_type1 == riscv_pkg::FU_ALU2) begin
        p_tree_lane1_alu2_fallback_value :
        assert (tree_root.second.request.value == i_alu2_tree_fallback_value);
      end else begin
        p_tree_lane1_non_alu_value_equiv :
        assert (tree_root.second.request.value == f_ref_data1.value);
      end
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
      p_kill_blocks_visible_outputs : assert (!o_cdb.valid && !o_cdb_2.valid && o_grant == '0);
    end

    p_grants_only_valid : assert ((o_grant_raw & ~valid_vec) == '0);

    // The output payload is selected from raw grants, so kill changes only
    // visibility.  When neither live select fires, including on an invalid
    // lane, the payload is the merge tree's fallback value.
    p_lane0_restore_mux_contract :
    assert (
      o_cdb.value ==
      (lane0_select_alu_live ? i_alu_live_value :
       lane0_select_alu2_live ? i_alu2_live_value : tree_root.first.request.value)
    );
    p_lane1_restore_mux_contract :
    assert (
      o_cdb_2.value ==
      (lane1_select_alu_live ? i_alu_live_value :
       lane1_select_alu2_live ? i_alu2_live_value : tree_root.second.request.value)
    );
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_single_fu : cover (o_cdb.valid && $onehot(o_grant));
      cover_all_valid : cover (&valid_vec);
      cover_contention_2 : cover ($countones(valid_vec) >= 2 && o_cdb_2.valid);
      cover_no_valid : cover (!o_cdb.valid && o_grant == '0);
      cover_dual_alu : cover (o_grant[riscv_pkg::FU_ALU] && o_grant[riscv_pkg::FU_ALU2]);
      cover_killed_with_raw_grants : cover (i_kill && (|o_grant_raw) && !(|o_grant));
    end
  end

`endif  // FORMAL

endmodule
