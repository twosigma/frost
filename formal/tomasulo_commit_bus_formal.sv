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

module tomasulo_commit_bus_formal (
    input logic i_clk,
    input logic i_rst_n,
    input riscv_pkg::reorder_buffer_alloc_req_t i_alloc_req,
    input riscv_pkg::reorder_buffer_alloc_req_t i_alloc_req_2,
    input logic i_widen_commit_ok,
    input logic i_commit_hold,
    input logic i_cache_sync_ready,
    input logic i_external_flush
);
  riscv_pkg::reorder_buffer_alloc_resp_t alloc_resp, alloc_resp_2;
  riscv_pkg::reorder_buffer_commit_t commit_q, commit_2_q;
  riscv_pkg::rat_lookup_t int_src1, fp_src1;
  (* anyconst *)logic [riscv_pkg::RegAddrWidth-1:0] int_reg;
  (* anyconst *)logic [riscv_pkg::RegAddrWidth-1:0] fp_reg;
  logic rename, rename_2;
  logic fence_sync_req, fence_i_flush, translation_shadow, sfence_flush;
  logic csr_start, csr_done;
  logic flush_all;

  function automatic logic legal_dest(input riscv_pkg::reorder_buffer_alloc_req_t req);
    // Decode supplies no destination for fences, WFI or xRET. CSR results
    // and jump links rename only integer registers. Integer x0 has no rename.
    legal_dest = !req.alloc_valid ||
        (!(req.is_jal || req.is_jalr) || req.is_branch) &&
        (!req.dest_valid ||
         (!(req.is_fence || req.is_fence_i || req.is_wfi || req.is_mret) &&
          (req.dest_rf ? !(req.is_csr || req.is_jal || req.is_jalr) : req.dest_reg != '0)));
  endfunction

  // Dispatch renames each allocated destination with the tag returned by the ROB.
  assign rename   = i_alloc_req.alloc_valid && i_alloc_req.dest_valid;
  assign rename_2 = i_alloc_req_2.alloc_valid && i_alloc_req_2.dest_valid;

  // SharedLinkBank is enabled in cpu_ooo. Dispatch blocks slot 2 behind a
  // slot-1 branch, so that allocation never needs both link-bank writes.
  always_comb begin
    assume (!i_alloc_req_2.alloc_valid || !i_alloc_req.is_branch);
    assume (legal_dest(i_alloc_req));
    assume (legal_dest(i_alloc_req_2));
    // Dispatch inhibits both rename lanes during a full flush.
    assume (!flush_all || !(rename || rename_2));
  end

  // The scalar CSR execution acknowledgement follows start by one cycle.
  // The cache responds during the sync request. The flush controller sends
  // the ROB's flush pulse back as a full flush, along with other full flushes.
  assign flush_all = fence_i_flush || i_external_flush;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || flush_all) csr_done <= 1'b0;
    else csr_done <= csr_start;
  end

  tomasulo_wrapper dut (
      .i_clk,
      .i_rst_n,
      .i_alloc_req,
      .i_alloc_req_2,
      .o_alloc_resp(alloc_resp),
      .o_alloc_resp_2(alloc_resp_2),
      .i_alloc_fire(i_alloc_req.alloc_valid),
      .i_alloc_has_dest(i_alloc_req.dest_valid),
      .i_alloc_has_dest_2(rename_2),
      .i_rat_alloc_valid(rename),
      .i_rat_alloc_dest_rf(i_alloc_req.dest_rf),
      .i_rat_alloc_dest_reg(i_alloc_req.dest_reg),
      .i_rat_alloc_rob_tag(alloc_resp.alloc_tag),
      .i_rat_alloc_valid_2(rename_2),
      .i_rat_alloc_dest_rf_2(i_alloc_req_2.dest_rf),
      .i_rat_alloc_dest_reg_2(i_alloc_req_2.dest_reg),
      .i_rat_alloc_rob_tag_2(alloc_resp_2.alloc_tag),
      .i_int_src1_addr(int_reg),
      .i_fp_src1_addr(fp_reg),
      .i_int_regfile_data1('0),
      .i_fp_regfile_data1('0),
      .o_int_src1(int_src1),
      .o_fp_src1(fp_src1),
      .i_widen_commit_ok,
      .i_commit_hold,
      .o_commit(commit_q),
      .o_commit_2(commit_2_q),
      .o_csr_start(csr_start),
      .i_csr_done(csr_done),
      .o_fence_i_sync_req(fence_sync_req),
      .i_fence_i_sync_done(fence_sync_req && i_cache_sync_ready),
      .o_fence_i_flush(fence_i_flush),
      .o_translation_csr_commit_shadow(translation_shadow),
      .o_tlb_invalidate(sfence_flush),
      .i_flush_all(flush_all),
      .i_flush_en(1'b0),
      .i_flush_tag('0),
      .i_flush_after_head_commit(1'b0),
      .i_early_recovery_en(1'b0),
      .i_early_recovery_tag('0),
      .i_checkpoint_save(1'b0),
      .i_checkpoint_branch_tag('0),
      .i_checkpoint_slot2_candidate(1'b0),
      .i_checkpoint_restore(1'b0),
      .i_checkpoint_restore_id('0),
      .i_checkpoint_restore_reclaim_all(1'b0),
      .i_checkpoint_free(1'b0),
      .i_checkpoint_free_2(1'b0),
      .i_branch_update('0),
      .i_rob_checkpoint_valid(1'b0),
      .i_rob_entry_epoch('0),
      .i_translation_active(1'b0),
      .i_csr_translation_flush_req(1'b0),
      .i_vmem_quiet(1'b1),
      .i_priv(riscv_pkg::PrivM),
      .i_priv_is_u(1'b0),
      .i_counter_blocked('0),
      .i_stimecmp_blocked(1'b0),
      .i_sret_illegal(1'b0),
      .i_sfence_illegal(1'b0),
      .i_wfi_illegal(1'b0),
      .i_debug_mode(1'b0),
      .i_mstatus_fs_off(1'b0),
      .i_frm_csr('0),
      .i_interrupt_pending(1'b0),
      .i_trap_taken(1'b0),
      .i_mret_done(1'b0),
      .i_mepc('0),
      .i_sepc('0),
      .i_dpc('0)
  );

  // The SBY script connects these observation wires to the RAT's stored
  // valid bits. The lookup ports return the indexed tags, but qualify
  // renamed with ROB liveness. The ROB retires the tag one cycle before
  // the registered commit reaches the RAT's clear logic.
  wire [(2**riscv_pkg::RegAddrWidth)-1:0] int_rat_valid, fp_rat_valid;
  logic int_mapping_valid, fp_mapping_valid;
  assign int_mapping_valid = int_rat_valid[int_reg];
  assign fp_mapping_valid  = fp_rat_valid[fp_reg];

  logic watched_commit, watched_commit_2, watched_commit_fp, watched_commit_2_fp;
  logic watched_rename, watched_rename_2, watched_rename_fp;
  assign watched_commit = commit_q.valid && commit_q.dest_valid &&
                          !commit_q.dest_rf && commit_q.dest_reg == int_reg;
  assign watched_commit_2 = commit_2_q.valid && commit_2_q.dest_valid &&
                            !commit_2_q.dest_rf && commit_2_q.dest_reg == int_reg;
  assign watched_commit_fp = commit_q.valid && commit_q.dest_valid &&
                             commit_q.dest_rf && commit_q.dest_reg == fp_reg;
  assign watched_commit_2_fp = commit_2_q.valid && commit_2_q.dest_valid &&
                               commit_2_q.dest_rf && commit_2_q.dest_reg == fp_reg;
  assign watched_rename = rename && !i_alloc_req.dest_rf && i_alloc_req.dest_reg == int_reg;
  assign watched_rename_2 = rename_2 && !i_alloc_req_2.dest_rf && i_alloc_req_2.dest_reg == int_reg;
  assign watched_rename_fp = (rename && i_alloc_req.dest_rf && i_alloc_req.dest_reg == fp_reg) ||
      (rename_2 && i_alloc_req_2.dest_rf && i_alloc_req_2.dest_reg == fp_reg);

  logic int_commit_only, slot2_matches_int;
  logic fp_commit_only, slot1_matches_fp, slot2_matches_fp;
  logic fp_slot2_clear, fp_commit_mismatch;
  assign int_commit_only = watched_commit && int_mapping_valid &&
                           !watched_rename && !watched_rename_2;
  assign slot2_matches_int = watched_commit_2 && int_src1.tag == commit_2_q.tag;
  assign fp_commit_only = (watched_commit_fp || watched_commit_2_fp) &&
                          fp_mapping_valid && !watched_rename_fp;
  assign slot1_matches_fp = watched_commit_fp && fp_src1.tag == commit_q.tag;
  assign slot2_matches_fp = watched_commit_2_fp && fp_src1.tag == commit_2_q.tag;
  assign fp_slot2_clear = fp_commit_only && !slot1_matches_fp && slot2_matches_fp;
  assign fp_commit_mismatch = fp_commit_only && !slot1_matches_fp && !slot2_matches_fp;

  logic past_valid = 1'b0;
  always @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (past_valid && i_rst_n && $past(i_rst_n)) begin
      if ($past(int_commit_only && int_src1.tag == commit_q.tag)) begin
        p_commit_clears_int_via_bus : assert (!int_mapping_valid);
      end
      if ($past(int_commit_only && int_src1.tag != commit_q.tag && slot2_matches_int)) begin
        p_commit_2_clears_int_via_bus : assert (!int_mapping_valid);
      end
      if ($past(int_commit_only && int_src1.tag != commit_q.tag && !slot2_matches_int)) begin
        p_waw_preserves_newer_int :
        assert (int_mapping_valid && int_src1.tag == $past(int_src1.tag));
      end
      if ($past(fp_commit_only && slot1_matches_fp)) begin
        p_commit_clears_fp_via_bus : assert (!fp_mapping_valid);
      end
      if ($past(fp_slot2_clear)) begin
        p_commit_2_clears_fp_via_bus : assert (!fp_mapping_valid);
      end
      if ($past(fp_commit_mismatch)) begin
        p_waw_preserves_newer_fp : assert (fp_mapping_valid && fp_src1.tag == $past(fp_src1.tag));
      end

      // The FENCE.I payload remains observable on the full-flush cycle.
      c_fence_i : cover (commit_q.is_fence_i && !$past(sfence_flush));
      c_sfence_vma : cover (commit_q.is_fence_i && $past(sfence_flush));
      c_translation_flush :
      cover (fence_i_flush && $past(
          translation_shadow &&
          commit_q.valid && commit_q.is_csr && commit_q.csr_addr == riscv_pkg::CsrSatp &&
          commit_q.csr_op[1:0] != '0
      ));

      // Exercise both choices of the winning rename and the case where
      // slot 2 commits the very mapping that the older slot 1 must leave alone.
      c_slot1_rename : cover ($past(watched_commit && watched_rename && !watched_rename_2));
      c_slot2_rename : cover ($past(watched_commit && watched_rename && watched_rename_2));
      c_younger_slot2_commit :
      cover ($past(
          int_commit_only && int_src1.tag != commit_q.tag && slot2_matches_int
      ) && !int_mapping_valid);
      c_waw_after_younger_retire :
      cover ($past(
          int_commit_only && int_src1.tag != commit_q.tag && !slot2_matches_int && int_src1.renamed
      ) && !int_src1.renamed && int_mapping_valid);

      // Both FP retirement lanes target the watched register in these cases.
      c_younger_slot2_fp_commit :
      cover ($past(fp_slot2_clear && watched_commit_fp) && !fp_mapping_valid);
      c_fp_waw_both_commits :
      cover ($past(
          fp_commit_mismatch && watched_commit_fp && watched_commit_2_fp
      ) && fp_mapping_valid && fp_src1.tag == $past(
          fp_src1.tag
      ));
    end
  end
endmodule
