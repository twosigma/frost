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
 * Composed PD -> ID formal harness for slot-2 prediction overrides
 * (formal/pd_id_slot2_redirect.sby).
 *
 * Instantiates pd_stage and id_stage with every slot-1 and slot-2 packet field,
 * backing BTB result, privilege gate, and pipeline control input left free.
 * pd_stage's own FORMAL block supplies only the initial reset and the IF -> PD
 * predecode/candidate alignment assumptions. rvc_predecode and
 * if_slot2_precompute prove the expansion and candidate relations; IF and PD
 * simulation assertions check raw-parcel size and non-control pairing.
 *
 * Proves that slot 2's dispatched prediction (btb_predicted_taken,
 * btb_predicted_target, and btb_correct_non_jalr) equals PD's slot-2 redirect
 * when one fires, keeps IF's metadata otherwise, leaves slot 1 untouched, and
 * holds across pipeline stalls. Covers taken overrides (native and compressed),
 * not-taken vetoes, backing-BTB jump redirects, and stalled veto release.
 */
module pd_id_slot2_redirect_formal #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd,
    input riscv_pkg::from_if_to_pd_t i_from_if_to_pd_2,
    input logic [1:0] i_backing_hit,
    input logic [1:0] i_backing_compressed,
    input logic [1:0] i_backing_return,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target,
    input logic [1:0] i_backing_slot2_return_by_size,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_slot2_target_by_size,
    input logic i_mstatus_fs_off,
    input logic i_mstatus_vs_off,
    input logic i_cbo_zero_illegal,
    input logic i_cbo_cf_illegal,
    input logic i_cbo_inval_illegal,
    input logic i_cbo_inval_flush,
    input logic i_wrs_nto_illegal,
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex,
    output riscv_pkg::from_id_to_ex_t o_from_id_to_ex_2
);

  riscv_pkg::from_pd_to_id_t            from_pd_to_id;
  riscv_pkg::from_pd_to_id_t            from_pd_to_id_2;
  riscv_pkg::from_id_to_ex_t            id_next;
  riscv_pkg::from_id_to_ex_t            id_next_go;
  riscv_pkg::from_id_to_ex_t            id_next_hold;
  riscv_pkg::from_id_to_ex_t            id_next_2;
  riscv_pkg::from_id_to_ex_t            id_next_go_2;
  riscv_pkg::from_id_to_ex_t            id_next_hold_2;
  logic                                 pd_redirect;
  logic                                 pd_redirect_taken;
  logic                      [XLEN-1:0] pd_redirect_target;
  logic                                 pd_redirect_slot2;
  logic                                 pd_redirect_ras_push;
  logic                                 pd_redirect_ras_pop;
  logic                      [XLEN-1:0] pd_redirect_ras_link;
  logic                                 pd_backing_refresh;
  logic                      [XLEN-1:0] pd_backing_refresh_pc;
  logic                      [     1:0] pd_cond_branch;

  pd_stage #(
      .XLEN(XLEN)
  ) u_pd_stage (
      .i_clk,
      .i_pipeline_ctrl,
      .i_from_if_to_pd,
      .o_from_pd_to_id        (from_pd_to_id),
      .i_from_if_to_pd_2,
      .o_from_pd_to_id_2      (from_pd_to_id_2),
      .i_backing_hit,
      .i_backing_compressed,
      .i_backing_return,
      .i_backing_target,
      .i_backing_slot2_return_by_size,
      .i_backing_slot2_target_by_size,
      .o_pd_redirect          (pd_redirect),
      .o_pd_redirect_taken    (pd_redirect_taken),
      .o_pd_redirect_target   (pd_redirect_target),
      .o_pd_redirect_slot2    (pd_redirect_slot2),
      .o_pd_redirect_ras_push (pd_redirect_ras_push),
      .o_pd_redirect_ras_pop  (pd_redirect_ras_pop),
      .o_pd_redirect_ras_link (pd_redirect_ras_link),
      .o_pd_backing_refresh   (pd_backing_refresh),
      .o_pd_backing_refresh_pc(pd_backing_refresh_pc),
      .o_cond_branch          (pd_cond_branch)
  );

  id_stage #(
      .XLEN(XLEN)
  ) u_id_stage (
      .i_clk,
      .i_pipeline_ctrl,
      .i_from_pd_to_id            (from_pd_to_id),
      .i_pd_redirect              (pd_redirect),
      .i_pd_redirect_taken        (pd_redirect_taken),
      .i_pd_redirect_target       (pd_redirect_target),
      .i_pd_redirect_slot2        (pd_redirect_slot2),
      .i_mstatus_fs_off,
      .i_mstatus_vs_off,
      .i_cbo_zero_illegal,
      .i_cbo_cf_illegal,
      .i_cbo_inval_illegal,
      .i_cbo_inval_flush,
      .i_wrs_nto_illegal,
      .o_from_id_to_ex,
      .o_from_id_to_ex_next       (id_next),
      .o_from_id_to_ex_next_go    (id_next_go),
      .o_from_id_to_ex_next_hold  (id_next_hold),
      .i_from_pd_to_id_2          (from_pd_to_id_2),
      .o_from_id_to_ex_2,
      .o_from_id_to_ex_next_2     (id_next_2),
      .o_from_id_to_ex_next_go_2  (id_next_go_2),
      .o_from_id_to_ex_next_hold_2(id_next_hold_2)
  );

  logic            f_past_valid = 1'b0;
  logic            f_id_armed_q = 1'b0;
  logic            f_prev_flush_q = 1'b0;
  logic            f_prev_slot2_redirect_q = 1'b0;
  logic            f_prev_slot2_dir_redirect_q = 1'b0;
  logic            f_prev_slot2_backing_redirect_q = 1'b0;
  logic            f_prev_redirect_taken_q = 1'b0;
  logic [XLEN-1:0] f_prev_redirect_target_q = '0;
  logic            f_prev_pd_btb_taken_2_q = 1'b0;
  logic [XLEN-1:0] f_prev_pd_btb_target_2_q = '0;
  logic            f_prev_slot1_redirect_q = 1'b0;
  logic            f_prev_pd_btb_taken_1_q = 1'b0;
  logic [XLEN-1:0] f_prev_pd_btb_target_1_q = '0;
  logic            f_stalled_slot2_redirect_seen_q = 1'b0;

  logic            slot2_redirect_now;
  logic            slot1_redirect_now;
  logic            slot2_dir_redirect_now;
  logic            slot2_backing_redirect_now;
  assign slot2_redirect_now = pd_redirect && pd_redirect_slot2;
  assign slot1_redirect_now = pd_redirect && !pd_redirect_slot2;
  // A slot-2 conditional-branch direction redirect never refreshes the backing
  // BTB; a slot-2 backing-BTB jump redirect always asserts pd_backing_refresh.
  assign slot2_dir_redirect_now = slot2_redirect_now && !pd_backing_refresh;
  assign slot2_backing_redirect_now = slot2_redirect_now && pd_backing_refresh;

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_pipeline_ctrl.reset);

    if (i_pipeline_ctrl.reset) begin
      f_id_armed_q <= 1'b0;
      f_prev_flush_q <= 1'b0;
      f_prev_slot2_redirect_q <= 1'b0;
      f_prev_slot2_dir_redirect_q <= 1'b0;
      f_prev_slot2_backing_redirect_q <= 1'b0;
      f_prev_redirect_taken_q <= 1'b0;
      f_prev_redirect_target_q <= '0;
      f_prev_pd_btb_taken_2_q <= 1'b0;
      f_prev_pd_btb_target_2_q <= '0;
      f_prev_slot1_redirect_q <= 1'b0;
      f_prev_pd_btb_taken_1_q <= 1'b0;
      f_prev_pd_btb_target_1_q <= '0;
      f_stalled_slot2_redirect_seen_q <= 1'b0;
    end else begin
      if (i_pipeline_ctrl.stall && slot2_dir_redirect_now) begin
        f_stalled_slot2_redirect_seen_q <= 1'b1;
      end else if (!i_pipeline_ctrl.stall) begin
        f_stalled_slot2_redirect_seen_q <= 1'b0;
      end

      if (!i_pipeline_ctrl.stall) begin
        f_id_armed_q <= 1'b1;
        f_prev_flush_q <= i_pipeline_ctrl.flush;
        f_prev_slot2_redirect_q <= slot2_redirect_now;
        f_prev_slot2_dir_redirect_q <= slot2_dir_redirect_now;
        f_prev_slot2_backing_redirect_q <= slot2_backing_redirect_now;
        f_prev_redirect_taken_q <= pd_redirect_taken;
        f_prev_redirect_target_q <= pd_redirect_target;
        f_prev_pd_btb_taken_2_q <= from_pd_to_id_2.btb_predicted_taken;
        f_prev_pd_btb_target_2_q <= from_pd_to_id_2.btb_predicted_target;
        f_prev_slot1_redirect_q <= slot1_redirect_now;
        f_prev_pd_btb_taken_1_q <= from_pd_to_id.btb_predicted_taken;
        f_prev_pd_btb_target_1_q <= from_pd_to_id.btb_predicted_target;
      end
    end
  end

  always_comb begin
    if (f_past_valid && !i_pipeline_ctrl.reset) begin
      // Same-cycle ID combinational go-packet check: slot 2's effective
      // prediction matches PD's slot-2 redirect, and slot 1 is untouched by a
      // slot-2 redirect.
      if (!i_pipeline_ctrl.flush) begin
        p_id_go_slot2_taken_matches_pd_redirect :
        assert (id_next_go_2.btb_predicted_taken ==
                (slot2_redirect_now ? pd_redirect_taken :
                                      from_pd_to_id_2.btb_predicted_taken));
        p_id_go_slot2_target_matches_pd_redirect :
        assert (id_next_go_2.btb_predicted_target ==
                ((slot2_redirect_now && pd_redirect_taken) ?
                 pd_redirect_target : from_pd_to_id_2.btb_predicted_target));
        if (slot2_redirect_now) begin
          p_id_go_slot2_redirect_leaves_slot1_untouched :
          assert ((id_next_go.btb_predicted_taken == from_pd_to_id.btb_predicted_taken) &&
                  (id_next_go.btb_predicted_target == from_pd_to_id.btb_predicted_target));
        end
        if (slot2_dir_redirect_now && pd_redirect_taken) begin
          p_id_go_slot2_dir_taken_target_is_branch_target :
          assert (id_next_go_2.is_real &&
                  id_next_go_2.btb_predicted_taken &&
                  (id_next_go_2.btb_predicted_target ==
                   id_next_go_2.branch_target_precomputed) &&
                  id_next_go_2.btb_correct_non_jalr);
        end
        if (slot2_dir_redirect_now && !pd_redirect_taken) begin
          p_id_go_slot2_dir_veto_clears_taken_keeps_target :
          assert (id_next_go_2.is_real &&
                  !id_next_go_2.btb_predicted_taken &&
                  (id_next_go_2.btb_predicted_target ==
                   from_pd_to_id_2.btb_predicted_target));
        end
      end

      // Registered ID -> EX dispatched packet check across stalls and flushes.
      if (f_id_armed_q) begin
        if (f_prev_flush_q) begin
          p_id_reg_flush_clears_slot2_taken :
          assert (!o_from_id_to_ex_2.is_real && !o_from_id_to_ex_2.btb_predicted_taken);
        end else begin
          p_id_reg_slot2_taken_matches_pd_redirect :
          assert (o_from_id_to_ex_2.btb_predicted_taken ==
                  (f_prev_slot2_redirect_q ? f_prev_redirect_taken_q :
                                             f_prev_pd_btb_taken_2_q));
          p_id_reg_slot2_target_matches_pd_redirect :
          assert (o_from_id_to_ex_2.btb_predicted_target ==
                  ((f_prev_slot2_redirect_q && f_prev_redirect_taken_q) ?
                   f_prev_redirect_target_q : f_prev_pd_btb_target_2_q));
          if (f_prev_slot2_redirect_q) begin
            p_id_reg_slot2_redirect_leaves_slot1_untouched :
            assert ((o_from_id_to_ex.btb_predicted_taken == f_prev_pd_btb_taken_1_q) &&
                    (o_from_id_to_ex.btb_predicted_target == f_prev_pd_btb_target_1_q));
          end
          if (f_prev_slot2_dir_redirect_q && f_prev_redirect_taken_q) begin
            p_id_reg_slot2_dir_taken_dispatches_exact_branch_target :
            assert (o_from_id_to_ex_2.is_real &&
                    o_from_id_to_ex_2.btb_predicted_taken &&
                    (o_from_id_to_ex_2.btb_predicted_target ==
                     o_from_id_to_ex_2.branch_target_precomputed) &&
                    o_from_id_to_ex_2.btb_correct_non_jalr);
          end
          if (f_prev_slot2_dir_redirect_q && !f_prev_redirect_taken_q) begin
            p_id_reg_slot2_dir_veto_dispatches_not_taken :
            assert (o_from_id_to_ex_2.is_real &&
                    !o_from_id_to_ex_2.btb_predicted_taken &&
                    (o_from_id_to_ex_2.btb_predicted_target == f_prev_pd_btb_target_2_q));
          end
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_pipeline_ctrl.reset && f_id_armed_q && !f_prev_flush_q) begin
      // Native slot-2 conditional branch taken override dispatched from ID.
      cover (f_prev_slot2_dir_redirect_q && f_prev_redirect_taken_q &&
             !o_from_id_to_ex_2.is_compressed && o_from_id_to_ex_2.btb_correct_non_jalr);
      // Compressed slot-2 conditional branch taken override dispatched from ID.
      cover (f_prev_slot2_dir_redirect_q && f_prev_redirect_taken_q &&
             o_from_id_to_ex_2.is_compressed && o_from_id_to_ex_2.btb_correct_non_jalr);
      // Slot-2 conditional branch not-taken veto dispatched from ID with a
      // non-zero IF target preserved alongside cleared btb_predicted_taken.
      cover (f_prev_slot2_dir_redirect_q && !f_prev_redirect_taken_q &&
             !o_from_id_to_ex_2.btb_predicted_taken &&
             (o_from_id_to_ex_2.btb_predicted_target != '0));
      // Slot-2 backing-BTB jump redirect dispatched from ID.
      cover (f_prev_slot2_backing_redirect_q && o_from_id_to_ex_2.btb_predicted_taken);
      // Slot-2 direction redirect held across a stall before dispatching.
      cover (!i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush &&
             f_stalled_slot2_redirect_seen_q && slot2_dir_redirect_now);
      // A not-taken veto survives a stall and reaches its release edge.
      cover_slot2_veto_after_stall :
      cover (!i_pipeline_ctrl.stall && !i_pipeline_ctrl.flush &&
             f_stalled_slot2_redirect_seen_q && slot2_dir_redirect_now && !pd_redirect_taken);
    end
  end

endmodule : pd_id_slot2_redirect_formal
