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

// Proves fetch_pc_decoupled's next-PC priority arms (1..13), PC load/hold
// update, registered TAGE history push/restore events, and registered
// provider retarget pulses by unbounded induction with zero assumptions.
module pc_tage_events_formal #(
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned BtbIndexBits = 8,
    localparam int unsigned BimBits = riscv_pkg::BpDirIdxBits,
    localparam int unsigned NPcArms = riscv_pkg::PcNextArms
) (
    input logic               i_clk,
    input logic [   XLEN-1:0] i_boot_addr,
    input logic               i_reset,
    input logic               i_trap_taken,
    input logic               i_mret_taken,
    input logic [   XLEN-1:0] i_trap_target,
    input logic               i_fence_i_flush,
    input logic [   XLEN-1:0] i_fence_i_target,
    input logic               i_branch_taken,
    input logic [   XLEN-1:0] i_branch_target,
    input logic               i_pd_redirect,
    input logic [   XLEN-1:0] i_pd_redirect_target,
    input logic               i_extra_flush,
    input logic               i_f1_resteer,
    input logic [   XLEN-1:0] i_f1_resteer_target,
    input logic               i_f0_launch,
    input logic               i_f1_collapsed_accept,
    input logic               i_span_btb_fire,
    input logic [   XLEN-1:0] i_span_btb_target,
    input logic [BimBits-3:0] i_span_btb_even_dir_idx,
    input logic               i_collapsed_btb_taken,
    input logic [   XLEN-1:0] i_collapsed_btb_target,
    input logic [BimBits-3:0] i_collapsed_btb_even_dir_idx,
    input logic               i_btb_en,
    input logic               i_btb_taken,
    input logic [   XLEN-1:0] i_btb_target,
    input logic [BimBits-3:0] i_btb_even_dir_idx
);
  logic [XLEN-1:0] o_pc;
  logic [XLEN-1:0] o_next_pc;
  logic o_pc_update_en;
  logic o_tage_hist_push;
  logic [4:1] o_tage_hist_restore_arm;
  logic o_fetch_redirect;
  logic o_fetch_cached_retarget;
  logic [NPcArms-1:0] o_npc_sel;
  logic [NPcArms-1:0][XLEN-1:0] o_npc_val;

  logic any_redirect;
  assign any_redirect = i_extra_flush || i_trap_taken || i_mret_taken || i_fence_i_flush ||
                        i_branch_taken || i_pd_redirect;

  fetch_pc_decoupled #(
      .XLEN(XLEN),
      .BTB_INDEX_BITS(BtbIndexBits),
      .BIM_BITS(BimBits)
  ) u_dut (
      .i_clk,
      .i_boot_addr,
      .i_reset,
      .i_trap_taken,
      .i_mret_taken,
      .i_trap_target,
      .i_fence_i_flush,
      .i_fence_i_target,
      .i_branch_taken,
      .i_branch_target,
      .i_pd_redirect,
      .i_pd_redirect_target,
      .i_any_redirect(any_redirect),
      .i_f1_resteer,
      .i_f1_resteer_target,
      .i_f0_launch,
      .i_f1_collapsed_accept,
      .i_span_btb_fire,
      .i_span_btb_target,
      .i_span_btb_even_dir_idx,
      .i_collapsed_btb_taken,
      .i_collapsed_btb_target,
      .i_collapsed_btb_even_dir_idx,
      .i_btb_en,
      .i_btb_taken,
      .i_btb_target,
      .i_btb_even_dir_idx,
      .o_pc,
      .o_pc_tage_lookup(),
      .o_pc_even_btb_idx(),
      .o_pc_even_dir_idx(),
      .o_next_pc,
      .o_pc_update_en,
      .o_f0_self_loop(),
      .o_tage_hist_push,
      .o_tage_hist_restore_arm,
      .o_fetch_redirect,
      .o_fetch_cached_retarget,
      .o_npc_sel,
      .o_npc_val
  );

  // Direct priority-ordered reference for next-PC arm, update enable, target,
  // and registered TAGE/retarget outputs.
  logic ref_step_raw;
  logic ref_f1_resteer;
  logic ref_step;
  logic [NPcArms-1:0] ref_sel;
  logic ref_update_en;
  logic [XLEN-1:0] ref_next_pc;

  assign ref_step_raw   = i_f0_launch || i_f1_collapsed_accept;
  assign ref_f1_resteer = !any_redirect && i_f1_resteer;
  assign ref_step       = !any_redirect && !i_f1_resteer && ref_step_raw;

  always_comb begin
    ref_sel       = '0;
    ref_update_en = 1'b1;
    ref_next_pc   = o_pc;
    if (i_trap_taken || i_mret_taken) begin
      ref_sel[1]  = 1'b1;
      ref_next_pc = i_trap_target;
    end else if (i_fence_i_flush) begin
      ref_sel[2]  = 1'b1;
      ref_next_pc = i_fence_i_target;
    end else if (i_branch_taken) begin
      ref_sel[3]  = 1'b1;
      ref_next_pc = i_branch_target;
    end else if (i_pd_redirect) begin
      ref_sel[4]  = 1'b1;
      ref_next_pc = i_pd_redirect_target;
    end else if (ref_f1_resteer) begin
      ref_sel[5]  = 1'b1;
      ref_next_pc = i_f1_resteer_target;
    end else if (!ref_step) begin
      ref_sel[6]    = 1'b1;
      ref_update_en = 1'b0;
      ref_next_pc   = o_pc;
    end else if (i_span_btb_fire) begin
      ref_sel[7]  = 1'b1;
      ref_next_pc = i_span_btb_target;
    end else if (i_f1_collapsed_accept ? i_collapsed_btb_taken : (i_btb_en && i_btb_taken)) begin
      ref_sel[8]  = 1'b1;
      ref_next_pc = i_f1_collapsed_accept ? i_collapsed_btb_target : i_btb_target;
    end else begin
      ref_sel[13] = 1'b1;
      ref_next_pc = {o_pc[XLEN-1:2] + (XLEN - 2)'(2), 2'b00};
    end
  end

  logic prev_valid_q = 1'b0;
  logic prev_reset_q = 1'b0;
  logic [XLEN-1:0] prev_boot_q = '0;
  logic [NPcArms-1:0] prev_sel_q = '0;
  logic prev_update_en_q = 1'b0;
  logic [XLEN-1:0] prev_next_pc_q = '0;

  always_ff @(posedge i_clk) begin
    prev_valid_q     <= 1'b1;
    prev_reset_q     <= i_reset;
    prev_boot_q      <= i_boot_addr;
    prev_sel_q       <= ref_sel;
    prev_update_en_q <= ref_update_en;
    prev_next_pc_q   <= ref_next_pc;

    p_npc_sel_matches_ref : assert (o_npc_sel == ref_sel);
    p_update_en_matches_ref : assert (o_pc_update_en == ref_update_en);
    p_next_pc_matches_ref : assert (o_next_pc == ref_next_pc);

    if (prev_valid_q) begin
      p_pc_register_matches_ref : assert (o_pc == (prev_reset_q ? prev_boot_q : prev_next_pc_q));
      p_tage_events_match_ref :
      assert ((o_tage_hist_restore_arm == (prev_reset_q ? 4'b0 : prev_sel_q[4:1])) &&
              (o_tage_hist_push ==
               (!prev_reset_q && prev_update_en_q && (prev_sel_q[7] || prev_sel_q[8]))));
      p_retarget_pulses_match_ref :
      assert ((o_fetch_redirect == (!prev_reset_q && (|prev_sel_q[5:1]))) &&
              (o_fetch_cached_retarget == (!prev_reset_q && (|prev_sel_q[5:1]))));

      c_restore_arm1 :
      cover (!prev_reset_q && o_tage_hist_restore_arm == 4'b0001 && o_fetch_redirect);
      c_restore_arm4 :
      cover (!prev_reset_q && o_tage_hist_restore_arm == 4'b1000 && o_fetch_redirect);
      c_resteer_arm5 :
      cover (!prev_reset_q && o_fetch_redirect && (o_tage_hist_restore_arm == 4'b0) &&
             !o_tage_hist_push);
      c_hold_arm6 :
      cover (!prev_reset_q && !prev_update_en_q && !o_fetch_redirect && !o_tage_hist_push &&
             (o_tage_hist_restore_arm == 4'b0));
      c_push_span_arm7 :
      cover (!prev_reset_q && prev_sel_q[7] && o_tage_hist_push && !o_fetch_redirect);
      c_push_btb_arm8 :
      cover (!prev_reset_q && prev_sel_q[8] && o_tage_hist_push && !o_fetch_redirect);
      c_seq_arm13 :
      cover (!prev_reset_q && prev_sel_q[13] && !o_tage_hist_push && !o_fetch_redirect);
    end
  end
endmodule
