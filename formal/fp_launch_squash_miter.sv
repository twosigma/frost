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

// fp_launch_squash miter: pre-squash fp_shim reference and the
// production fp_shim, each with its own copy of the REAL fp_engine, driven by
// the same inputs. Read with -formal; the shims and engine are read without
// FORMAL, so neither shim uses its abstract engine model.
//
// The b_*/c_* probe wires are left undriven here and connected after flatten
// by `connect -set` in fp_launch_squash.sby to the engine/shim registers.
// `check -assert` there fails the run if any probe stays undriven.
//
// Defines:
//   FP_LS_ON        candidate built with LAUNCH_SQUASH=1 and the added
//                   no-issue-after-flushed-issue contract assumed.
//   FP_LS_NO_CONTRACT  with FP_LS_ON, drop that assumption (expected FAIL).
module fp_launch_squash_miter (
    input logic                                                        i_clk,
    input logic                                                        i_rst_n,
    input riscv_pkg::rs_issue_t                                        i_rs_issue,
    input logic                                                        i_flush,
    input logic                                                        i_flush_en,
    input logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);
  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;
  localparam logic [5:0] StIdle = 6'd0;  // fp_engine state_e encoding
  localparam logic [5:0] StDec1 = 6'd1;

`ifdef FP_LS_ON
  localparam bit LaunchSquash = 1'b1;
`else
  localparam bit LaunchSquash = 1'b0;
`endif

  riscv_pkg::fu_complete_t b_out, c_out;
  logic b_busy, c_busy;

  fp_launch_squash_reference u_base (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (i_rs_issue),
      .o_fu_complete (b_out),
      .o_fu_busy     (b_busy),
      .i_flush       (i_flush),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(i_rob_head_tag)
  );

  fp_shim #(
      .LAUNCH_SQUASH(LaunchSquash)
  ) u_cand (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (i_rs_issue),
      .o_fu_complete (c_out),
      .o_fu_busy     (c_busy),
      .i_flush       (i_flush),
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(i_rob_head_tag)
  );

  // Probes (connected after flatten).
  logic [5:0] b_state, c_state;  // u_*.u_engine.state_q
  logic c_squash;  // u_cand.squash_q
  logic [TagW-1:0] b_tag, c_tag;  // u_*.tag_q
  logic [207:0] b_payload, c_payload;  // dec_q rm_q opa_q opb_q opc_q
  logic [65:0] b_dec1, c_dec1;  // ca/cb/cc ea/eb/ec f2i_over f2i_edge int_zero
  logic [410:0] b_dp, c_dp;  // every other engine register

  // The age compare both shims use, from the inputs.
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

  logic f_launch_flushed;
  assign f_launch_flushed = i_flush || (i_flush_en && is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  ));

  logic f_init = 1'b1;
  logic f_prev_flushed_issue = 1'b0;
  always_ff @(posedge i_clk) begin
    f_init <= 1'b0;
    f_prev_flushed_issue <= i_rst_n && i_rs_issue.valid && f_launch_flushed;
  end

  // ---------------------------------------------------------------------------
  // Assumptions
  // ---------------------------------------------------------------------------
  // A1: both designs power up with identical register contents and no
  // pending squash. i_rst_n is otherwise unconstrained (any reset pattern).
  always_comb begin
    if (f_init) begin
      a_equal_init :
      assume (b_state == c_state && !c_squash && b_tag == c_tag &&
              b_payload == c_payload && b_dec1 == c_dec1 && b_dp == c_dp);
    end
  end

  // A2: the existing generic fp_shim issue contract.
  always_comb begin
    if (i_rst_n) a_issue_not_busy : assume (!i_rs_issue.valid || !b_busy);
  end

`ifdef FP_LS_ON
`ifndef FP_LS_NO_CONTRACT
  // A3: the added LAUNCH_SQUASH contract: no issue on the cycle after an
  // issue that a flush covered (proved for FP_RS in fp_launch_squash_rs.sby).
  always_comb begin
    if (i_rst_n && f_prev_flushed_issue)
      a_no_issue_after_flushed_issue : assume (!i_rs_issue.valid);
  end
`endif
`endif

  // ---------------------------------------------------------------------------
  // Equivalence: busy and valid every cycle, the full completion when valid.
  // ---------------------------------------------------------------------------
  always_comb begin
    p_busy_equal : assert (b_busy == c_busy);
    p_valid_equal : assert (b_out.valid == c_out.valid);
    if (b_out.valid) p_complete_equal : assert (b_out == c_out);
  end

  // ---------------------------------------------------------------------------
  // Inductive relation between the two register sets.
  // ---------------------------------------------------------------------------
  always_comb begin
    if (c_squash) begin
      p_squash_state : assert (c_state == StDec1 && b_state == StIdle);
    end else begin
      p_state_equal : assert (c_state == b_state);
    end
    p_datapath_equal : assert (b_dp == c_dp);
    if (b_state != StIdle) begin
      p_payload_equal : assert (b_payload == c_payload && b_tag == c_tag);
    end
    if (b_state != StIdle && b_state != StDec1) begin
      p_dec1_equal : assert (b_dec1 == c_dec1);
    end
`ifdef FP_LS_ON
    if (c_squash) p_squash_follows_flushed_issue : assert (f_prev_flushed_issue);
`else
    p_no_squash_when_off : assert (!c_squash);
`endif
  end

  // ---------------------------------------------------------------------------
  // Covers (non-vacuity of the corners).
  // ---------------------------------------------------------------------------
  logic [TagW-1:0] f_phantom_tag;
  logic f_seen_phantom, f_restart_after_phantom, f_same_tag_restart;
  initial f_seen_phantom = 1'b0;
  initial f_restart_after_phantom = 1'b0;
  initial f_same_tag_restart = 1'b0;
  always_ff @(posedge i_clk) begin
    if (c_squash) begin
      f_seen_phantom <= 1'b1;
      f_phantom_tag  <= c_tag;
    end
    // A real start in the cycle right after the squash cycle.
    if (f_seen_phantom && !c_squash && $past(
            c_squash
        ) && i_rs_issue.valid && !f_launch_flushed && i_rst_n) begin
      f_restart_after_phantom <= 1'b1;
      if (i_rs_issue.rob_tag == f_phantom_tag) f_same_tag_restart <= 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (!f_init) begin
      c_phantom : cover (c_squash);
      c_phantom_then_issue_blocked_window : cover (c_squash && i_rst_n);
      c_back_to_back_complete : cover (f_restart_after_phantom && b_out.valid);
      c_duplicate_tag_complete :
      cover (f_same_tag_restart && b_out.valid && b_out.tag == f_phantom_tag);
      c_phantom_during_reset : cover (c_squash && !i_rst_n);
      c_kill_real_op : cover (b_state != StIdle && b_state != StDec1 && i_flush_en && !i_flush);
    end
  end

endmodule
