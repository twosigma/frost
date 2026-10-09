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

// fp_launch_squash producer proof: the REAL reservation_station, instantiated
// with u_fp_rs's parameters and tie-offs from tomasulo_wrapper.sv, plus the
// wrapper's backend-recovery-hold gate that forms the shim's issue valid.
// Every other RS input is a free top-level input; there are no assumptions.
// The RS is read without FORMAL, so none of its own assumptions are present.
//
// The shim and FP_RS share their flush inputs in the wrapper:
//   shim i_flush        = speculative_flush_all = RS i_flush_all
//   shim i_flush_en     = speculative_flush_en  = RS i_flush_en
//   shim i_flush_tag    = i_flush_tag           = RS i_flush_tag
//   shim i_rob_head_tag = head_tag              = RS i_rob_head_tag
module fp_launch_squash_rs_producer (
    input logic i_clk,
    input logic i_rst_n,

    input riscv_pkg::rs_dispatch_t   i_dispatch,
    input logic                      i_intent_1,
    input riscv_pkg::cdb_broadcast_t i_cdb,
    input riscv_pkg::cdb_broadcast_t i_cdb_2,
    input logic                      i_fu_ready,
    input logic                      i_backend_recovery_hold,

    input logic                                        i_flush_all,
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);
  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;

  riscv_pkg::rs_issue_t rs_issue_raw;

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth),
      .HAS_SRC3(1'b1),
      .FORMAL_STANDALONE_ENV(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0)
  ) u_fp_rs (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_dispatch                 (i_dispatch),
      .i_dispatch_2               ('0),
      .i_intent_1                 (i_intent_1),
      .o_full                     (),
      .o_full_for_2               (),
      .i_cdb                      (i_cdb),
      .i_cdb_2                    (i_cdb_2),
      .i_issue_cdb_valid          (i_cdb.valid),
      .i_issue_cdb_tag            (i_cdb.tag),
      .i_issue_cdb_2_valid        (i_cdb_2.valid),
      .i_issue_cdb_2_tag          (i_cdb_2.tag),
      .i_repair_valid_1           (1'b0),
      .i_repair_tag_1             ('0),
      .i_repair_value_1           ('0),
      .i_repair_valid_2           (1'b0),
      .i_repair_tag_2             ('0),
      .i_repair_value_2           ('0),
      .i_repair_valid_3           (1'b0),
      .i_repair_tag_3             ('0),
      .i_repair_value_3           ('0),
      .i_repair_valid_4           (1'b0),
      .i_repair_tag_4             ('0),
      .i_repair_value_4           ('0),
      .i_repair_valid_5           (1'b0),
      .i_repair_tag_5             ('0),
      .i_repair_value_5           ('0),
      .i_repair_valid_6           (1'b0),
      .i_repair_tag_6             ('0),
      .i_repair_value_6           ('0),
      .o_issue                    (rs_issue_raw),
      .i_fu_ready                 (i_fu_ready),
      .i_divider_busy             (1'b0),
      .o_issue_writes_cdb_hint    (),
      .o_branch_predicate_tag     (),
      .o_issue_2                  (),
      .i_fu_ready_2               (1'b0),
      .o_issue_writes_cdb_hint_2  (),
      .o_issue_shift_amount_2     (),
      .o_next_issue_valid         (),
      .o_next_issue_is_sc         (),
      .o_next_issue_needs_lq      (),
      .o_pre_issue_rob_tag        (),
      .o_pre_issue_rob_tags       (),
      .o_pre_issue_sel            (),
      .o_pre_issue_ready          (),
      .o_pre_issue_entry_tags     (),
      .i_pre_issue_raw_valid      ('0),
      .i_pre_issue_raw_tags       ('0),
      .o_pre_issue_needs_lq       (),
      .i_flush_en                 (i_flush_en),
      .i_flush_tag                (i_flush_tag),
      .i_rob_head_tag             (i_rob_head_tag),
      .i_flush_all                (i_flush_all),
      .o_empty                    (),
      .o_count                    (),
      .i_head_query_tag           (i_rob_head_tag),
      .o_head_query_in_rs         (),
      .o_head_query_rs_ready      (),
      .o_head_query_in_stage2     (),
      .o_perf_two_ready_one_issued()
  );

  // tomasulo_wrapper: fp_rs_issue_w.valid is cleared under the hold.
  logic shim_issue_valid;
  assign shim_issue_valid = rs_issue_raw.valid && !i_backend_recovery_hold;

  // fp_shim's launch_flushed, on the shim's (shared) flush inputs.
  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age, flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  logic launch_flushed;
  assign launch_flushed = i_flush_all || (i_flush_en && is_younger(
      rs_issue_raw.rob_tag, i_flush_tag, i_rob_head_tag
  ));

  logic f_prev_rs_issue_in_flush = 1'b0;  // RS issue during any flush
  logic f_prev_flushed_issue = 1'b0;  // exactly the miter's A3 trigger
  always_ff @(posedge i_clk) begin
    f_prev_rs_issue_in_flush <= rs_issue_raw.valid && (i_flush_all || i_flush_en);
    f_prev_flushed_issue <= i_rst_n && shim_issue_valid && launch_flushed;
  end

  always_comb begin
    // Stronger, reset-independent: no FP_RS issue the cycle after an issue in
    // any flush cycle.
    if (f_prev_rs_issue_in_flush) p_rs_bubble_after_flush : assert (!rs_issue_raw.valid);
    // The contract fp_shim's LAUNCH_SQUASH needs (miter assumption A3).
    if (i_rst_n && f_prev_flushed_issue) p_shim_contract : assert (!shim_issue_valid);
  end

`ifdef FP_LS_COVER_FROM_RESET
  // Cover task only (the proof has no assumptions): start from reset.
  logic f_init = 1'b1;
  logic f_prev2_flushed_issue = 1'b0;
  always_ff @(posedge i_clk) begin
    f_init <= 1'b0;
    f_prev2_flushed_issue <= f_prev_flushed_issue;
  end
  always_comb if (f_init) assume (!i_rst_n);

  always_ff @(posedge i_clk) begin
    if (!f_init) begin
      // A partial-flush-covered issue happened in the previous cycle.
      c_flushed_issue : cover (f_prev_flushed_issue && i_rst_n);
      // FP_RS issues again two cycles after a flushed issue.
      c_issue_after_flush_gap : cover (f_prev2_flushed_issue && i_rst_n && shim_issue_valid);
    end
  end
`endif

endmodule
