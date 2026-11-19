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

// The two elaborations have independent state and the same fetch and retirement inputs.
module pd_history_twin_side (
    input logic i_clk,
    input pd_history_twin_pkg::inputs_t i,
    output pd_history_twin_pkg::outputs_t o,
    output pd_history_twin_pkg::state_t state
);
  logic [1:0] cond_branch, jalr, itt_eligible, cf, pred_taken;
  logic [1:0] jump;
  logic pd_redirect_taken, pd_redirect_slot2;
  logic [riscv_pkg::XLEN-1:0] pd_redirect_target, pd_redirect_ras_link, pd_backing_refresh_pc;
  logic [1:0] live_slot;
  assign live_slot = {
    !i.from_if_to_pd_2.sel_nop && !i.from_if_to_pd_2.fetch_fault,
    !i.from_if_to_pd.sel_nop && !i.from_if_to_pd.fetch_fault
  };
  pd_stage pd (
      .i_clk,
      .i_pipeline_ctrl(i.pipeline_ctrl),
      .i_from_if_to_pd(i.from_if_to_pd),
      .i_from_if_to_pd_2(i.from_if_to_pd_2),
      .i_backing_hit(i.backing_hit),
      .i_backing_compressed(i.backing_compressed),
      .i_backing_return(i.backing_return),
      .i_backing_target(i.backing_target),
      .i_backing_slot2_return_by_size(i.backing_slot2_return_by_size),
      .i_backing_slot2_target_by_size(i.backing_slot2_target_by_size),
      .i_itt_hit(i.itt_hit),
      .i_itt_target(i.itt_target),
      .o_from_pd_to_id(o.from_pd_to_id),
      .o_from_pd_to_id_2(o.from_pd_to_id_2),
      .o_pd_redirect(o.pd_redirect),
      .o_pd_redirect_taken(pd_redirect_taken),
      .o_pd_redirect_target(pd_redirect_target),
      .o_pd_redirect_slot2(pd_redirect_slot2),
      .o_pd_redirect_ras_push(o.pd_redirect_ras_push),
      .o_pd_redirect_ras_pop(o.pd_redirect_ras_pop),
      .o_pd_redirect_ras_link(pd_redirect_ras_link),
      .o_pd_backing_refresh(o.pd_backing_refresh),
      .o_pd_backing_refresh_pc(pd_backing_refresh_pc),
`ifdef PREDICTOR_TWIN_REFERENCE
      .o_cond_branch(cond_branch),
      .o_jalr(jalr),
      .o_itt_eligible(itt_eligible),
      .o_jump(jump),
      .o_pred_taken(pred_taken)
`else
      .o_cond_branch(),
      .o_jalr(),
      .o_itt_eligible(),
      .o_jump(),
      .o_pred_taken(),
      .o_q_cond_branch(cond_branch),
      .o_q_jalr(jalr),
      .o_q_itt_eligible(itt_eligible),
      .o_q_cf(cf),
      .o_q_pred_taken(pred_taken)
`endif
  );
  assign o.pd_redirect_taken = o.pd_redirect ? pd_redirect_taken : '0;
  assign o.pd_redirect_target = o.pd_redirect ? pd_redirect_target : '0;
  assign o.pd_redirect_slot2 = o.pd_redirect ? pd_redirect_slot2 : '0;
  assign o.pd_redirect_ras_link = o.pd_redirect_ras_push ? pd_redirect_ras_link : '0;
  assign o.pd_backing_refresh_pc = o.pd_backing_refresh ? pd_backing_refresh_pc : '0;

  // The packet acceptance, bank and base direction are the cpu_ooo connections.
  wire accept = !i.pipeline_ctrl.stall && !i.pipeline_ctrl.flush && !o.pd_redirect;
  wire [1:0] bank = {i.from_if_to_pd_2.program_counter[2], i.from_if_to_pd.program_counter[2]};
  wire [1:0] base_taken = {
    i.from_if_to_pd_2.btb_predicted_taken,
    i.from_if_to_pd.btb_predicted_taken || i.from_if_to_pd.bp_dir_taken
  };
  riscv_pkg::tage_lookup_t train_lookup;
  logic train_bank;
  logic train_alt_taken;
  logic train_taken;
  logic train_mispredicted;
  riscv_pkg::itt_lookup_t itt_train_lookup;
  logic itt_train_bank;
  logic [riscv_pkg::PhysAddrBits-2:0] itt_train_target;
  logic itt_train_mispredicted;

  tage_history history (
      .i_clk,
      .i_rst(i.pipeline_ctrl.reset),
      .i_pd_accept(accept),
      .i_tage_slot_bank(bank),
      .i_base_taken(base_taken),
      .i_pd_redirect_taken(pd_redirect_taken),
`ifdef PREDICTOR_TWIN_REFERENCE
      .i_pd_cond_branch(cond_branch & live_slot),
      .i_pd_jalr(jalr & live_slot),
      .i_pd_cf((cond_branch | jump) & live_slot),
      .i_pd_pred_taken(pred_taken),
      .i_itt_slot_valid(i.tage_slot_valid & itt_eligible),
`else
      .i_pd_q_cond_branch(cond_branch),
      .i_pd_q_jalr(jalr),
      .i_pd_q_cf(cf),
      .i_pd_q_pred_taken(pred_taken),
      .i_pd_q_itt_eligible(itt_eligible),
      .o_lookup_dir_fold(o.lookup_dir_fold),
`endif
      .i_hist_push(i.hist_push),
      .i_hist_restore_arm(i.hist_restore_arm),
      .i_fetch_pc_path_bits(i.fetch_pc_path_bits),
      .i_tage_slot_valid(i.tage_slot_valid),
      .i_tage_slot_lookup(i.tage_slot_lookup),
      .i_tage_slot_lookup_2(i.tage_slot_lookup_2),
      .i_tage_lookup_hist(i.tage_lookup_hist),
      .i_itt_slot_lookup(i.itt_slot_lookup),
      .i_itt_slot_lookup_2(i.itt_slot_lookup_2),
      .i_early_active(i.early_active),
      .i_early_tag(i.early_tag),
      .i_early_taken(i.early_taken),
      .i_flush_full(i.flush_full),
      .i_alloc_tag(i.alloc_tag),
      .i_alloc_cond_branch(i.alloc_cond_branch),
      .i_alloc_jalr(i.alloc_jalr),
      .i_alloc_q(i.alloc_q),
      .i_commit_valid(i.commit_valid),
      .i_commit_tag(i.commit_tag),
      .i_commit_cond_branch(i.commit_cond_branch),
      .i_commit_taken_cf(i.commit_taken_cf),
      .i_commit_taken(i.commit_taken),
      .i_commit_mispredicted(i.commit_mispredicted),
      .i_commit_target_bits(i.commit_target_bits),
      .i_commit_jalr(i.commit_jalr),
      .i_commit_cf(i.commit_cf),
      .i_commit_target(i.commit_target),
      .o_lookup_hist(o.lookup_hist),
      .o_lookup_dir_hist(o.lookup_dir_hist),
      .o_train_valid(o.train_valid),
      .o_train_lookup(train_lookup),
      .o_train_bank(train_bank),
      .o_train_alt_taken(train_alt_taken),
      .o_train_taken(train_taken),
      .o_train_mispredicted(train_mispredicted),
      .o_itt_train_valid(o.itt_train_valid),
      .o_itt_train_lookup(itt_train_lookup),
      .o_itt_train_bank(itt_train_bank),
      .o_itt_train_target(itt_train_target),
      .o_itt_train_mispredicted(itt_train_mispredicted)
  );
  assign o.train_lookup = o.train_valid ? train_lookup : '0;
  assign o.train_bank = o.train_valid ? train_bank : '0;
  assign o.train_alt_taken = o.train_valid ? train_alt_taken : '0;
  assign o.train_taken = o.train_valid ? train_taken : '0;
  assign o.train_mispredicted = o.train_valid ? train_mispredicted : '0;
  assign o.itt_train_lookup = o.itt_train_valid ? itt_train_lookup : '0;
  assign o.itt_train_bank = o.itt_train_valid ? itt_train_bank : '0;
  assign o.itt_train_target = o.itt_train_valid ? itt_train_target : '0;
  assign o.itt_train_mispredicted = o.itt_train_valid ? itt_train_mispredicted : '0;

  assign history.u_ftq_early.twin_read = i.ftq_read[0];
  assign o.write_enable[0] = history.u_ftq_early.i_write_enable;
  assign o.write_index[0] = history.u_ftq_early.i_write_address;
  assign o.read_index[0] = history.u_ftq_early.i_read_address;
  assign o.write_data[0] = o.write_enable[0] ? history.u_ftq_early.i_write_data : '0;

  assign history.u_ftq_train.twin_read = i.ftq_read[1];
  assign o.write_enable[1] = history.u_ftq_train.i_write_enable;
  assign o.write_index[1] = history.u_ftq_train.i_write_address;
  assign o.read_index[1] = history.u_ftq_train.i_read_address;
  assign o.write_data[1] = o.write_enable[1] ? history.u_ftq_train.i_write_data : '0;

  for (genvar k = 0; k < riscv_pkg::ReorderBufferDepth; k++) begin : gen_tag
    assign state.tag_indices[k] = history.ftq_idx_by_tag[k];
  end
  assign state.pd_accept_q = history.pd_accept_q;
  assign state.pd_slot_valid_q = history.pd_slot_valid_q;
  assign state.pd_slot_bank_q = history.pd_slot_bank_q;
  assign state.pd_base_taken_q = history.pd_base_taken_q;
  assign state.pd_lookup_q = history.pd_lookup_q;
  assign state.pd_lookup_2_q = history.pd_lookup_2_q;
  assign state.pd_itt_lookup_q = history.pd_itt_lookup_q;
  assign state.pd_itt_lookup_2_q = history.pd_itt_lookup_2_q;
  assign state.pd_lookup_hist_q = history.pd_lookup_hist_q;
  assign state.ftq_write_ptr = history.ftq_write_ptr;
  assign state.ftq_dispatch_ptr = history.ftq_dispatch_ptr;
  assign state.ftq_commit_ptr = history.ftq_commit_ptr;
  assign state.alloc_cond_branch_q = history.alloc_cond_branch_q;
  assign state.alloc_tag_q = history.alloc_tag_q;
  assign state.hist_q = history.hist_q;
  assign state.retired_hist = history.retired_hist;
  assign state.dir_hist_q = history.dir_hist_q;
  assign state.retired_dir_hist = history.retired_dir_hist;
  assign state.pd_hist_q = history.pd_hist_q;
  assign state.early_hist_q = history.early_hist_q;
  assign state.early_dir_hist_q = history.early_dir_hist_q;
  assign state.early_q = history.early_q;
  assign state.early_taken_q = history.early_taken_q;
  assign state.held_valid = history.held_valid;
  assign state.held_idx = history.held_idx;
  assign state.held_taken = history.held_taken;
  assign state.held_mispredicted = history.held_mispredicted;
  assign state.held_target = history.held_target;
`ifdef PREDICTOR_TWIN_REFERENCE
  assign state.accepted_cond = history.pd_accept_q ? history.pd_cond_branch_q : '0;
  assign state.accepted_jalr = history.pd_accept_q ? history.pd_jalr_q : '0;
  assign state.accepted_itt_valid = state.accepted_jalr & history.pd_itt_valid_q;
  assign state.accepted_cf = history.pd_accept_q ? history.pd_cf_q : '0;
  assign state.accepted_taken = state.accepted_cf & history.pd_pred_taken_q;

  for (genvar t = 0; t < riscv_pkg::TageTables; t++) begin : gen_fold
    assign o.lookup_dir_fold[t] = predictor_twin_fold_pkg::history_index(o.lookup_dir_hist, t);
    assign state.spec_fold[t] = predictor_twin_fold_pkg::history_index(history.dir_hist_q, t);
    assign state.retired_fold[t] = predictor_twin_fold_pkg::history_index(
        history.retired_dir_hist, t
    );
    assign state.early_fold[t] = predictor_twin_fold_pkg::history_index(
        history.early_dir_hist_q, t
    );
  end
`else
  assign state.accepted_cond = history.pd_accept_q ? cond_branch : '0;
  assign state.accepted_jalr = history.pd_accept_q ? jalr : '0;
  assign state.accepted_itt_valid = state.accepted_jalr & history.pd_itt_valid;
  assign state.accepted_cf = history.pd_accept_q ? cf : '0;
  assign state.accepted_taken = state.accepted_cf & pred_taken;
  assign state.spec_fold = history.dir_fold_q;
  assign state.retired_fold = history.retired_dir_fold_q;
  assign state.early_fold = history.early_dir_fold_q;
`endif
endmodule
