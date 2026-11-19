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

module pd_history_twin (
    input logic i_clk,
    input pd_history_twin_pkg::inputs_t i
);
  pd_history_twin_pkg::outputs_t ref_out, new_out;
  pd_history_twin_pkg::state_t ref_state, new_state;
  logic started = 1'b0;
  pd_history_twin_pkg::inputs_t fetch;

  // The core starts in reset. The input contract begins on the following
  // cycle. Both compared stages receive the arbitrary real input on every edge.
  always_comb begin
    fetch = i;
    if (!started) begin
      fetch = '0;
      fetch.pipeline_ctrl.reset = i.pipeline_ctrl.reset;
      fetch.from_if_to_pd.sel_nop = 1'b1;
      fetch.from_if_to_pd.sel_compressed = 1'b1;
      fetch.from_if_to_pd_2.sel_nop = 1'b1;
      fetch.from_if_to_pd_2.program_counter = riscv_pkg::PcIncrementCompressed;
    end
  end
  pd_fetch_contract fetch_inputs (
      .i_clk,
      .i_pipeline_ctrl(fetch.pipeline_ctrl),
      .i_from_if_to_pd(fetch.from_if_to_pd),
      .i_from_if_to_pd_2(fetch.from_if_to_pd_2),
      .i_backing_hit(fetch.backing_hit),
      .i_backing_compressed(fetch.backing_compressed),
      .i_backing_return(fetch.backing_return),
      .i_backing_target(fetch.backing_target),
      .i_backing_slot2_return_by_size(fetch.backing_slot2_return_by_size),
      .i_backing_slot2_target_by_size(fetch.backing_slot2_target_by_size),
      .i_itt_hit(fetch.itt_hit),
      .i_itt_target(fetch.itt_target)
  );
  pd_history_reference reference (
      .i_clk,
      .i,
      .o(ref_out),
      .state(ref_state)
  );
  pd_history_candidate candidate (
      .i_clk,
      .i,
      .o(new_out),
      .state(new_state)
  );

  always @(posedge i_clk) begin
    started <= 1'b1;
    // The PC controller registers the selected redirect arm and clears it on reset.
    if (started)
      a_pd_restore_follows_redirect :
      assume (!i.hist_restore_arm[4] || $past(!i.pipeline_ctrl.reset && ref_out.pd_redirect));
    if (!started) begin
      // Corresponding unreset storage starts with the same arbitrary contents.
      assume (ref_state == new_state);
      assume (ref_out.pd_redirect == new_out.pd_redirect);
      assume (ref_out.from_pd_to_id == new_out.from_pd_to_id);
      assume (ref_out.from_pd_to_id_2 == new_out.from_pd_to_id_2);
    end else begin
      p_from_pd_to_id : assert (ref_out.from_pd_to_id == new_out.from_pd_to_id);
      p_from_pd_to_id_2 : assert (ref_out.from_pd_to_id_2 == new_out.from_pd_to_id_2);
      p_pd_redirect : assert (ref_out.pd_redirect == new_out.pd_redirect);
      p_pd_redirect_taken : assert (ref_out.pd_redirect_taken == new_out.pd_redirect_taken);
      p_pd_redirect_target : assert (ref_out.pd_redirect_target == new_out.pd_redirect_target);
      p_pd_redirect_slot2 : assert (ref_out.pd_redirect_slot2 == new_out.pd_redirect_slot2);
      p_pd_redirect_ras_push :
      assert (ref_out.pd_redirect_ras_push == new_out.pd_redirect_ras_push);
      p_pd_redirect_ras_pop : assert (ref_out.pd_redirect_ras_pop == new_out.pd_redirect_ras_pop);
      p_pd_redirect_ras_link :
      assert (ref_out.pd_redirect_ras_link == new_out.pd_redirect_ras_link);
      p_pd_backing_refresh : assert (ref_out.pd_backing_refresh == new_out.pd_backing_refresh);
      p_pd_backing_refresh_pc :
      assert (ref_out.pd_backing_refresh_pc == new_out.pd_backing_refresh_pc);
      p_lookup_hist : assert (ref_out.lookup_hist == new_out.lookup_hist);
      p_lookup_dir_hist : assert (ref_out.lookup_dir_hist == new_out.lookup_dir_hist);
      p_train_valid : assert (ref_out.train_valid == new_out.train_valid);
      p_train_lookup : assert (ref_out.train_lookup == new_out.train_lookup);
      p_train_bank : assert (ref_out.train_bank == new_out.train_bank);
      p_train_alt_taken : assert (ref_out.train_alt_taken == new_out.train_alt_taken);
      p_train_taken : assert (ref_out.train_taken == new_out.train_taken);
      p_train_mispredicted : assert (ref_out.train_mispredicted == new_out.train_mispredicted);
      p_itt_train_valid : assert (ref_out.itt_train_valid == new_out.itt_train_valid);
      p_itt_train_lookup : assert (ref_out.itt_train_lookup == new_out.itt_train_lookup);
      p_itt_train_bank : assert (ref_out.itt_train_bank == new_out.itt_train_bank);
      p_itt_train_target : assert (ref_out.itt_train_target == new_out.itt_train_target);
      p_itt_train_mispredicted :
      assert (ref_out.itt_train_mispredicted == new_out.itt_train_mispredicted);
      p_lookup_dir_fold : assert (ref_out.lookup_dir_fold == new_out.lookup_dir_fold);
      p_write_enable : assert (ref_out.write_enable == new_out.write_enable);
      p_write_index : assert (ref_out.write_index == new_out.write_index);
      p_read_index : assert (ref_out.read_index == new_out.read_index);
      p_write_data : assert (ref_out.write_data == new_out.write_data);
      p_state_pd_accept_q : assert (ref_state.pd_accept_q == new_state.pd_accept_q);
      p_state_pd_slot_valid_q : assert (ref_state.pd_slot_valid_q == new_state.pd_slot_valid_q);
      p_state_pd_slot_bank_q : assert (ref_state.pd_slot_bank_q == new_state.pd_slot_bank_q);
      p_state_pd_base_taken_q : assert (ref_state.pd_base_taken_q == new_state.pd_base_taken_q);
      p_state_pd_lookup_q : assert (ref_state.pd_lookup_q == new_state.pd_lookup_q);
      p_state_pd_lookup_2_q : assert (ref_state.pd_lookup_2_q == new_state.pd_lookup_2_q);
      p_state_pd_itt_lookup_q : assert (ref_state.pd_itt_lookup_q == new_state.pd_itt_lookup_q);
      p_state_pd_itt_lookup_2_q :
      assert (ref_state.pd_itt_lookup_2_q == new_state.pd_itt_lookup_2_q);
      p_state_pd_lookup_hist_q : assert (ref_state.pd_lookup_hist_q == new_state.pd_lookup_hist_q);
      p_state_ftq_write_ptr : assert (ref_state.ftq_write_ptr == new_state.ftq_write_ptr);
      p_state_ftq_dispatch_ptr : assert (ref_state.ftq_dispatch_ptr == new_state.ftq_dispatch_ptr);
      p_state_ftq_commit_ptr : assert (ref_state.ftq_commit_ptr == new_state.ftq_commit_ptr);
      p_state_alloc_cond_branch_q :
      assert (ref_state.alloc_cond_branch_q == new_state.alloc_cond_branch_q);
      p_state_alloc_tag_q : assert (ref_state.alloc_tag_q == new_state.alloc_tag_q);
      p_state_hist_q : assert (ref_state.hist_q == new_state.hist_q);
      p_state_retired_hist : assert (ref_state.retired_hist == new_state.retired_hist);
      p_state_dir_hist_q : assert (ref_state.dir_hist_q == new_state.dir_hist_q);
      p_state_retired_dir_hist : assert (ref_state.retired_dir_hist == new_state.retired_dir_hist);
      p_state_pd_hist_q : assert (ref_state.pd_hist_q == new_state.pd_hist_q);
      p_state_early_hist_q : assert (ref_state.early_hist_q == new_state.early_hist_q);
      p_state_early_dir_hist_q : assert (ref_state.early_dir_hist_q == new_state.early_dir_hist_q);
      p_state_early_q : assert (ref_state.early_q == new_state.early_q);
      p_state_early_taken_q : assert (ref_state.early_taken_q == new_state.early_taken_q);
      p_state_early_dir_bit_q : assert (ref_state.early_dir_bit_q == new_state.early_dir_bit_q);
      p_state_held_valid : assert (ref_state.held_valid == new_state.held_valid);
      p_state_held_idx : assert (ref_state.held_idx == new_state.held_idx);
      p_state_held_taken : assert (ref_state.held_taken == new_state.held_taken);
      p_state_held_mispredicted :
      assert (ref_state.held_mispredicted == new_state.held_mispredicted);
      p_state_held_target : assert (ref_state.held_target == new_state.held_target);
      p_state_tag_indices : assert (ref_state.tag_indices == new_state.tag_indices);
      p_state_accepted_cond : assert (ref_state.accepted_cond == new_state.accepted_cond);
      p_state_accepted_jalr : assert (ref_state.accepted_jalr == new_state.accepted_jalr);
      p_state_accepted_itt_valid :
      assert (ref_state.accepted_itt_valid == new_state.accepted_itt_valid);
      p_state_accepted_cf : assert (ref_state.accepted_cf == new_state.accepted_cf);
      p_state_accepted_taken : assert (ref_state.accepted_taken == new_state.accepted_taken);
      p_state_spec_fold : assert (ref_state.spec_fold == new_state.spec_fold);
      p_state_retired_fold : assert (ref_state.retired_fold == new_state.retired_fold);
      p_state_early_fold : assert (ref_state.early_fold == new_state.early_fold);
      c_redirect : cover (ref_out.pd_redirect);
      c_train : cover (ref_out.train_valid);
      c_indirect_train : cover (ref_out.itt_train_valid);
      c_write : cover (ref_out.write_enable[0]);
    end
  end
endmodule

// Filled with the independently elaborated designs by the proof script.
(* blackbox *)
module pd_history_reference (
    input logic i_clk,
    input pd_history_twin_pkg::inputs_t i,
    output pd_history_twin_pkg::outputs_t o,
    output pd_history_twin_pkg::state_t state
);
endmodule

(* blackbox *) module pd_history_candidate (
    input logic i_clk,
    input pd_history_twin_pkg::inputs_t i,
    output pd_history_twin_pkg::outputs_t o,
    output pd_history_twin_pkg::state_t state
);
endmodule

(* blackbox *) module pd_fetch_contract (
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
    input logic [1:0] i_itt_hit,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_itt_target
);
endmodule
