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

// Unbounded formal harness for register_alias_table coupled to a 32-entry
// circular ROB, cpu_ooo's per-allocation epoch toggle, 1-cycle pipelined
// commit clears, and 2-phase early / commit-time branch recovery.
//
// An independent ROB-sequence architectural oracle (with zero epoch state)
// verifies watched INT and FP registers chosen as symbolic constants across
// all 31 non-zero INT registers, all 32 FP registers, and all 8 checkpoint
// slots to unbounded depth by k-induction.
module rat_checkpoint_restore_formal #(
    parameter bit          CHECK_INT       = 1'b1,
    parameter bit          CHECK_FP        = 1'b1,
    parameter bit          CHECK_ACTIVE    = 1'b1,
    parameter int unsigned CHECK_CKPT_MASK = 255
) (
    input logic                                    i_clk,
    input logic                                    i_rst_n,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_watch_int_reg,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_watch_fp_reg,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_watch_ckpt_id,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_probe_int_addr,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_probe_int_addr_2,
    input logic                                    i_probe_rf_fill,
    input logic                                    i_probe_rf_fill_2,
    input logic                                    i_dispatch_req,
    input logic                                    i_dispatch_slot2_req,
    input logic                                    i_slot1_has_dest,
    input logic                                    i_slot1_dest_rf,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_slot1_dest_reg,
    input logic                                    i_slot1_is_branch,
    input logic                                    i_slot2_has_dest,
    input logic                                    i_slot2_dest_rf,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_slot2_dest_reg,
    input logic                                    i_slot2_is_branch,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_save_ckpt_id,
    input logic [       riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [         riscv_pkg::RasPtrBits:0] i_ras_valid_count,
    input logic [             riscv_pkg::XLEN-1:0] i_ras_top,
    input logic                                    i_other_commit_dest_valid,
    input logic                                    i_other_commit_dest_rf,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_other_commit_dest_reg,
    input logic                                    i_other_commit2_dest_valid,
    input logic                                    i_other_commit2_dest_rf,
    input logic [     riscv_pkg::RegAddrWidth-1:0] i_other_commit2_dest_reg,
    input logic                                    i_retire_req_1,
    input logic                                    i_retire_req_2,
    input logic                                    i_commit_mispredict_req,
    input logic                                    i_early_mispredict_req,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_early_mispredict_ckpt_id,
    input logic                                    i_reclaim_all_on_restore,
    input logic                                    i_flush_all
);

  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;
  localparam int unsigned NumIntRegs = riscv_pkg::NumIntRegs;
  localparam int unsigned TagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned RobDepth = riscv_pkg::ReorderBufferDepth;
  localparam int unsigned NumCheckpoints = riscv_pkg::NumCheckpoints;
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned SeqWidth = TagWidth + 1;
  localparam int unsigned RatEntryWidth = TagWidth + 2;
  localparam int unsigned IntRatSnapshotWidth = NumIntRegs * RatEntryWidth;
  localparam int unsigned MetaRasLsb = TagWidth + 1;
  localparam int unsigned MetaRasWidth = XLEN + (RasPtrBits + 1) + RasPtrBits;

  // Symbolic-constant watched non-zero INT register, FP register, and RAS checkpoint slot:
  // unconstrained on step 0 and held constant across every subsequent clock edge.
  wire [RegAddrWidth-1:0] watch_int_reg = i_watch_int_reg;
  wire [RegAddrWidth-1:0] watch_fp_reg = i_watch_fp_reg;
  wire [CheckpointIdWidth-1:0] watch_ckpt_id = i_watch_ckpt_id;

  logic f_past_valid = 1'b0;
  logic [RegAddrWidth-1:0] watch_int_reg_q = 5'd1;
  logic [RegAddrWidth-1:0] watch_fp_reg_q = '0;
  logic [CheckpointIdWidth-1:0] watch_ckpt_id_q = '0;

  always_ff @(posedge i_clk) begin
    f_past_valid    <= 1'b1;
    watch_int_reg_q <= i_watch_int_reg;
    watch_fp_reg_q  <= i_watch_fp_reg;
    watch_ckpt_id_q <= i_watch_ckpt_id;
  end

  always_comb begin
    assume (watch_int_reg != '0);
    if (!f_past_valid) begin
      assume (!i_rst_n);
    end else begin
      assume (i_watch_int_reg == watch_int_reg_q);
      assume (i_watch_fp_reg == watch_fp_reg_q);
      assume (i_watch_ckpt_id == watch_ckpt_id_q);
    end
  end

  // ===========================================================================
  // Circular ROB, cpu_ooo Epoch Toggle, Commit Pipeline, and Recovery Model
  // ===========================================================================
  logic [SeqWidth-1:0] rob_head_seq = '0;
  logic [SeqWidth-1:0] rob_tail_seq = '0;
  logic [RobDepth-1:0] rob_entry_epoch = '0;
  logic [RobDepth-1:0] rob_writes_watch_int = '0;
  logic [RobDepth-1:0] rob_writes_watch_fp = '0;

  logic [TagWidth-1:0] head_idx;
  logic [TagWidth-1:0] head_next_idx;
  logic [TagWidth-1:0] tail_idx;
  logic [TagWidth-1:0] tail_idx_2;
  logic [SeqWidth-1:0] rob_count;
  logic rob_full;
  logic rob_full_for_2;

  assign head_idx = rob_head_seq[TagWidth-1:0];
  assign head_next_idx = head_idx + TagWidth'(1);
  assign tail_idx = rob_tail_seq[TagWidth-1:0];
  assign tail_idx_2 = tail_idx + TagWidth'(1);
  assign rob_count = rob_tail_seq - rob_head_seq;
  assign rob_full = (rob_count == SeqWidth'(RobDepth));
  assign rob_full_for_2 = (rob_count >= SeqWidth'(RobDepth - 1));

  logic [RobDepth-1:0] rob_valid;
  genvar e_idx;
  generate
    for (e_idx = 0; e_idx < RobDepth; e_idx++) begin : g_rob_valid
      wire [TagWidth-1:0] dist_from_head = e_idx[TagWidth-1:0] - head_idx;
      assign rob_valid[e_idx] = SeqWidth'(dist_from_head) < rob_count;
    end
  endgenerate

  // Checkpoint pool tracking in the core environment.
  logic [NumCheckpoints-1:0] env_ckpt_in_use = '0;
  logic [NumCheckpoints-1:0] env_ckpt_branch_live = '0;
  logic [SeqWidth-1:0] env_ckpt_branch_seq[NumCheckpoints];
  logic [NumCheckpoints-1:0] env_ckpt_branch_has_dest = '0;

  // Two-phase early recovery and 1-cycle commit recovery state.
  logic early_backend_flush_q = 1'b0;
  logic [CheckpointIdWidth-1:0] early_flush_ckpt_q = '0;
  logic [SeqWidth-1:0] early_flush_seq_q = '0;

  logic commit_recovery_q = 1'b0;
  logic [CheckpointIdWidth-1:0] commit_recovery_ckpt_q = '0;

  logic [NumCheckpoints-1:0] ckpt_flush_free_mask_q = '0;
  logic correct_free_1_q = 1'b0;
  logic [CheckpointIdWidth-1:0] correct_free_1_id_q = '0;
  logic correct_free_2_q = 1'b0;
  logic [CheckpointIdWidth-1:0] correct_free_2_id_q = '0;

  // 1-cycle pipelined commit bus (commit_bus_pipeline.sv).
  logic commit_valid_q = 1'b0;
  logic commit_dest_valid_q = 1'b0;
  logic commit_dest_rf_q = 1'b0;
  logic [RegAddrWidth-1:0] commit_dest_reg_q = '0;
  logic [TagWidth-1:0] commit_tag_q = '0;

  logic commit_valid_2_q = 1'b0;
  logic commit_dest_valid_2_q = 1'b0;
  logic commit_dest_rf_2_q = 1'b0;
  logic [RegAddrWidth-1:0] commit_dest_reg_2_q = '0;
  logic [TagWidth-1:0] commit_tag_2_q = '0;

  // Head/head+1 checkpoint ownership decode directly from the 8-entry checkpoint pool.
  logic [CheckpointIdWidth-1:0] head_ckpt_id;
  logic head_has_ckpt;
  logic [CheckpointIdWidth-1:0] head_next_ckpt_id;
  logic head_next_has_ckpt;
  logic [SeqWidth-1:0] head_next_seq;
  assign head_next_seq = rob_head_seq + SeqWidth'(1);

  always_comb begin
    head_has_ckpt      = 1'b0;
    head_ckpt_id       = '0;
    head_next_has_ckpt = 1'b0;
    head_next_ckpt_id  = '0;
    for (int k = 0; k < NumCheckpoints; k++) begin
      if ((rob_count != '0) && env_ckpt_in_use[k] && env_ckpt_branch_live[k] &&
          (env_ckpt_branch_seq[k] == rob_head_seq)) begin
        head_has_ckpt = 1'b1;
        head_ckpt_id  = k[CheckpointIdWidth-1:0];
      end
      if ((rob_count >= SeqWidth'(2)) && env_ckpt_in_use[k] && env_ckpt_branch_live[k] &&
          (env_ckpt_branch_seq[k] == head_next_seq)) begin
        head_next_has_ckpt = 1'b1;
        head_next_ckpt_id  = k[CheckpointIdWidth-1:0];
      end
    end
  end

  // Legal destination register encoding: INT x0 never sets has_dest, and free
  // non-watched commit destinations target registers other than watch_int_reg / watch_fp_reg.
  always_comb begin
    if (i_slot1_has_dest && !i_slot1_dest_rf) assume (i_slot1_dest_reg != '0);
    if (i_slot2_has_dest && !i_slot2_dest_rf) assume (i_slot2_dest_reg != '0);
    if (!i_other_commit_dest_rf) begin
      assume ((i_other_commit_dest_reg != '0) && (i_other_commit_dest_reg != watch_int_reg));
    end else begin
      assume (i_other_commit_dest_reg != watch_fp_reg);
    end
    if (!i_other_commit2_dest_rf) begin
      assume ((i_other_commit2_dest_reg != '0) && (i_other_commit2_dest_reg != watch_int_reg));
    end else begin
      assume (i_other_commit2_dest_reg != watch_fp_reg);
    end
  end

  // Early misprediction triggers only on a live conditional branch (!has_dest)
  // that is not retiring in the same cycle.
  logic [SeqWidth-1:0] early_cand_seq;
  logic early_cand_valid;
  assign early_cand_seq = env_ckpt_branch_seq[i_early_mispredict_ckpt_id];
  assign early_cand_valid = env_ckpt_in_use[i_early_mispredict_ckpt_id] &&
      env_ckpt_branch_live[i_early_mispredict_ckpt_id] &&
      !env_ckpt_branch_has_dest[i_early_mispredict_ckpt_id];

  // Retirement fire decode.
  logic retire_1;
  logic retire_2;
  logic commit_mispredict_fire;
  assign retire_1 = !i_flush_all && !commit_recovery_q && (rob_count != '0) && i_retire_req_1;
  assign commit_mispredict_fire = retire_1 && head_has_ckpt && i_commit_mispredict_req &&
      !early_backend_flush_q;
  assign retire_2 = retire_1 && !commit_mispredict_fire &&
      !(early_backend_flush_q && (rob_head_seq == early_flush_seq_q)) &&
      (rob_count >= SeqWidth'(2)) && i_retire_req_2 &&
      !(head_next_has_ckpt && i_commit_mispredict_req);

  logic early_restore_active;
  assign early_restore_active = !i_flush_all && !early_backend_flush_q && !commit_recovery_q &&
      !commit_mispredict_fire && i_early_mispredict_req && early_cand_valid &&
      !(retire_1 && (rob_head_seq == early_cand_seq)) &&
      !(retire_2 && (head_next_seq == early_cand_seq));

  // Dispatch admission (dispatch.sv): blocked during flushes and recovery holds;
  // slot-1 branch ends the bundle; checkpoint-saving bundle needs a free checkpoint.
  logic slot2_present;
  logic need_ckpt_1;
  logic need_ckpt_2;
  logic ckpt_slot2_cand;
  logic ckpt_req_any;
  logic save_ckpt_free;
  logic dispatch_hold;
  logic alloc_fire;
  logic slot2_fire;

  assign slot2_present = i_dispatch_slot2_req && !i_slot1_is_branch;
  assign need_ckpt_1 = i_slot1_is_branch;
  assign need_ckpt_2 = slot2_present && i_slot2_is_branch;
  assign ckpt_slot2_cand = need_ckpt_2;
  assign ckpt_req_any = need_ckpt_1 || need_ckpt_2;
  assign save_ckpt_free = !env_ckpt_in_use[i_save_ckpt_id];
  assign dispatch_hold = i_flush_all || early_restore_active || early_backend_flush_q ||
      commit_recovery_q;

  assign alloc_fire = i_dispatch_req && !dispatch_hold && !rob_full &&
      (!slot2_present || !rob_full_for_2) && (!ckpt_req_any || save_ckpt_free);
  assign slot2_fire = alloc_fire && slot2_present;

  logic dut_alloc_has_dest;
  logic dut_alloc_has_dest_2;
  logic dut_alloc_valid;
  logic dut_alloc_valid_2;
  logic dut_checkpoint_save;
  logic dut_checkpoint_save_for_slot2;
  logic [TagWidth-1:0] dut_checkpoint_branch_tag;
  logic dut_checkpoint_restore;
  logic [CheckpointIdWidth-1:0] dut_checkpoint_restore_id;
  logic dut_checkpoint_restore_reclaim_all;
  logic dut_checkpoint_free;
  logic [CheckpointIdWidth-1:0] dut_checkpoint_free_id;
  logic dut_checkpoint_free_2;
  logic [CheckpointIdWidth-1:0] dut_checkpoint_free_id_2;

  assign dut_alloc_has_dest = i_slot1_has_dest;
  assign dut_alloc_has_dest_2 = slot2_present && i_slot2_has_dest;
  assign dut_alloc_valid = alloc_fire && dut_alloc_has_dest;
  assign dut_alloc_valid_2 = alloc_fire && dut_alloc_has_dest_2;
  assign dut_checkpoint_save = alloc_fire && ckpt_req_any;
  assign dut_checkpoint_save_for_slot2 = slot2_fire && need_ckpt_2;
  assign dut_checkpoint_branch_tag = ckpt_slot2_cand ? tail_idx_2 : tail_idx;

  assign dut_checkpoint_restore = !i_flush_all && (early_restore_active || commit_recovery_q);
  assign dut_checkpoint_restore_id = commit_recovery_q ? commit_recovery_ckpt_q :
      i_early_mispredict_ckpt_id;
  assign dut_checkpoint_restore_reclaim_all = dut_checkpoint_restore && i_reclaim_all_on_restore;

  always_comb begin
    dut_checkpoint_free = 1'b0;
    dut_checkpoint_free_id = '0;
    if (!i_flush_all) begin
      if (early_backend_flush_q) begin
        dut_checkpoint_free = 1'b1;
        dut_checkpoint_free_id = early_flush_ckpt_q;
      end else if (commit_recovery_q) begin
        dut_checkpoint_free = 1'b1;
        dut_checkpoint_free_id = commit_recovery_ckpt_q;
      end else if (correct_free_1_q && env_ckpt_in_use[correct_free_1_id_q]) begin
        dut_checkpoint_free = 1'b1;
        dut_checkpoint_free_id = correct_free_1_id_q;
      end
    end
  end

  assign dut_checkpoint_free_2 = !i_flush_all && !early_restore_active &&
      !early_backend_flush_q && !commit_recovery_q && !correct_free_1_q &&
      correct_free_2_q && env_ckpt_in_use[correct_free_2_id_q];
  assign dut_checkpoint_free_id_2 = correct_free_2_id_q;

  // ===========================================================================
  // DUT Instantiation
  // ===========================================================================
  riscv_pkg::rat_lookup_t o_int_src1;
  riscv_pkg::rat_lookup_t o_int_src2;
  riscv_pkg::rat_lookup_t o_fp_src1;
  riscv_pkg::rat_lookup_t o_fp_src2;
  riscv_pkg::rat_lookup_t o_fp_src3;
  riscv_pkg::rat_lookup_t o_int_src1_2;
  riscv_pkg::rat_lookup_t o_int_src2_2;
  riscv_pkg::rat_lookup_t o_fp_src1_2;
  riscv_pkg::rat_lookup_t o_fp_src2_2;
  riscv_pkg::rat_lookup_t o_fp_src3_2;
  logic [RasPtrBits-1:0] o_ras_tos;
  logic [RasPtrBits:0] o_ras_valid_count;
  logic [XLEN-1:0] o_ras_top;
  logic o_checkpoint_available;
  logic [CheckpointIdWidth-1:0] o_checkpoint_alloc_id;

  register_alias_table dut (
      .i_clk                           (i_clk),
      .i_rst_n                         (i_rst_n),
      .i_int_src1_addr                 (watch_int_reg),
      .i_int_src2_addr                 (i_probe_int_addr),
      .o_int_src1                      (o_int_src1),
      .o_int_src2                      (o_int_src2),
      .i_fp_src1_addr                  (watch_fp_reg),
      .i_fp_src2_addr                  (5'd0),
      .i_fp_src3_addr                  (5'd0),
      .o_fp_src1                       (o_fp_src1),
      .o_fp_src2                       (o_fp_src2),
      .o_fp_src3                       (o_fp_src3),
      .i_int_src1_addr_2               (watch_int_reg),
      .i_int_src2_addr_2               (i_probe_int_addr_2),
      .o_int_src1_2                    (o_int_src1_2),
      .o_int_src2_2                    (o_int_src2_2),
      .i_fp_src1_addr_2                (watch_fp_reg),
      .i_fp_src2_addr_2                (5'd0),
      .i_fp_src3_addr_2                (5'd0),
      .o_fp_src1_2                     (o_fp_src1_2),
      .o_fp_src2_2                     (o_fp_src2_2),
      .o_fp_src3_2                     (o_fp_src3_2),
      .i_int_regfile_data1             ('0),
      .i_int_regfile_data2             ({XLEN{i_probe_rf_fill}}),
      .i_fp_regfile_data1              ('0),
      .i_fp_regfile_data2              ('0),
      .i_fp_regfile_data3              ('0),
      .i_int_regfile_data1_2           ('0),
      .i_int_regfile_data2_2           ({XLEN{i_probe_rf_fill_2}}),
      .i_fp_regfile_data1_2            ('0),
      .i_fp_regfile_data2_2            ('0),
      .i_fp_regfile_data3_2            ('0),
      .i_alloc_valid                   (dut_alloc_valid),
      .i_alloc_dest_rf                 (i_slot1_dest_rf),
      .i_alloc_dest_reg                (i_slot1_dest_reg),
      .i_alloc_rob_tag                 (tail_idx),
      .i_alloc_valid_2                 (dut_alloc_valid_2),
      .i_alloc_dest_rf_2               (i_slot2_dest_rf),
      .i_alloc_dest_reg_2              (i_slot2_dest_reg),
      .i_alloc_rob_tag_2               (tail_idx_2),
      .i_commit_valid                  (commit_valid_q),
      .i_commit_dest_valid             (commit_dest_valid_q),
      .i_commit_dest_rf                (commit_dest_rf_q),
      .i_commit_dest_reg               (commit_dest_reg_q),
      .i_commit_tag                    (commit_tag_q),
      .i_commit_valid_2                (commit_valid_2_q),
      .i_commit_dest_valid_2           (commit_dest_valid_2_q),
      .i_commit_dest_rf_2              (commit_dest_rf_2_q),
      .i_commit_dest_reg_2             (commit_dest_reg_2_q),
      .i_commit_tag_2                  (commit_tag_2_q),
      .i_checkpoint_save               (dut_checkpoint_save),
      .i_checkpoint_id                 (i_save_ckpt_id),
      .i_checkpoint_branch_tag         (dut_checkpoint_branch_tag),
      .i_ras_tos                       (i_ras_tos),
      .i_ras_valid_count               (i_ras_valid_count),
      .i_ras_top                       (i_ras_top),
      .i_checkpoint_save_for_slot2     (dut_checkpoint_save_for_slot2),
      .i_alloc_fire                    (alloc_fire),
      .i_alloc_has_dest                (dut_alloc_has_dest),
      .i_alloc_has_dest_2              (dut_alloc_has_dest_2),
      .i_checkpoint_slot2_candidate    (ckpt_slot2_cand),
      .i_checkpoint_restore            (dut_checkpoint_restore),
      .i_checkpoint_restore_id         (dut_checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(dut_checkpoint_restore_reclaim_all),
      .o_ras_tos                       (o_ras_tos),
      .o_ras_valid_count               (o_ras_valid_count),
      .o_ras_top                       (o_ras_top),
      .i_checkpoint_free               (dut_checkpoint_free),
      .i_checkpoint_free_id            (dut_checkpoint_free_id),
      .i_checkpoint_free_2             (dut_checkpoint_free_2),
      .i_checkpoint_free_id_2          (dut_checkpoint_free_id_2),
      .i_checkpoint_flush_free_mask    (ckpt_flush_free_mask_q),
      .i_rob_entry_valid               (rob_valid),
      .i_rob_entry_epoch               (rob_entry_epoch),
      .i_rob_head_tag                  (head_idx),
      .i_flush_all                     (i_flush_all),
      .o_checkpoint_available          (o_checkpoint_available),
      .o_checkpoint_alloc_id           (o_checkpoint_alloc_id)
  );

  // ===========================================================================
  // Sequential ROB, Epoch, Recovery, and Independent Instruction-Seq Oracle
  // ===========================================================================
  logic [SeqWidth-1:0] slot1_seq;
  logic [SeqWidth-1:0] slot2_seq;
  assign slot1_seq = rob_tail_seq;
  assign slot2_seq = rob_tail_seq + SeqWidth'(1);

  // Architectural oracle state for watch_int_reg and watch_fp_reg:
  // stores ONLY whether an unretired ROB producer is active and its 6-bit ROB sequence.
  logic arch_int_has_prod = 1'b0;
  logic [SeqWidth-1:0] arch_int_seq = '0;
  logic arch_fp_has_prod = 1'b0;
  logic [SeqWidth-1:0] arch_fp_seq = '0;

  logic [NumCheckpoints-1:0] ckpt_int_has_prod = '0;
  logic [SeqWidth-1:0] ckpt_int_seq[NumCheckpoints];
  logic [NumCheckpoints-1:0] ckpt_fp_has_prod = '0;
  logic [SeqWidth-1:0] ckpt_fp_seq[NumCheckpoints];

  logic watch_ckpt_written = 1'b0;
  logic [RasPtrBits-1:0] watch_ckpt_ras_tos = '0;
  logic [RasPtrBits:0] watch_ckpt_ras_valid_count = '0;
  logic [1:0] watch_ckpt_ras_top_ends = '0;

  initial begin
    for (int c = 0; c < NumCheckpoints; c++) begin
      env_ckpt_branch_seq[c] = '0;
      ckpt_int_seq[c]        = '0;
      ckpt_fp_seq[c]         = '0;
    end
  end

  function automatic logic seq_retiring_now(input logic [SeqWidth-1:0] s);
    seq_retiring_now = (retire_1 && (s == rob_head_seq)) || (retire_2 && (s == head_next_seq));
  endfunction

  logic arch_int_after_retire;
  logic arch_fp_after_retire;
  logic [NumCheckpoints-1:0] ckpt_int_after_retire;
  logic [NumCheckpoints-1:0] ckpt_fp_after_retire;

  always_comb begin
    arch_int_after_retire = arch_int_has_prod && !seq_retiring_now(arch_int_seq);
    arch_fp_after_retire  = arch_fp_has_prod && !seq_retiring_now(arch_fp_seq);
    for (int c = 0; c < NumCheckpoints; c++) begin
      ckpt_int_after_retire[c] = ckpt_int_has_prod[c] && !seq_retiring_now(ckpt_int_seq[c]);
      ckpt_fp_after_retire[c]  = ckpt_fp_has_prod[c] && !seq_retiring_now(ckpt_fp_seq[c]);
    end
  end

  logic [NumCheckpoints-1:0] younger_ckpt_mask;
  genvar y_idx;
  generate
    for (y_idx = 0; y_idx < NumCheckpoints; y_idx++) begin : g_younger_ckpt
      wire [SeqWidth-1:0] c_age = env_ckpt_branch_seq[y_idx] - rob_head_seq;
      wire [SeqWidth-1:0] fl_age = early_flush_seq_q - rob_head_seq;
      assign younger_ckpt_mask[y_idx] = env_ckpt_in_use[y_idx] && env_ckpt_branch_live[y_idx] &&
          (c_age > fl_age);
    end
  endgenerate

  logic [NumCheckpoints-1:0] env_ckpt_in_use_next;
  always_comb begin
    if (i_flush_all || dut_checkpoint_restore_reclaim_all) begin
      env_ckpt_in_use_next = '0;
    end else begin
      env_ckpt_in_use_next = env_ckpt_in_use & ~ckpt_flush_free_mask_q;
      if (dut_checkpoint_free) env_ckpt_in_use_next[dut_checkpoint_free_id] = 1'b0;
      if (dut_checkpoint_free_2) env_ckpt_in_use_next[dut_checkpoint_free_id_2] = 1'b0;
      if (dut_checkpoint_save) env_ckpt_in_use_next[i_save_ckpt_id] = 1'b1;
    end
  end

  logic [SeqWidth-1:0] rob_head_seq_next;
  always_comb begin
    rob_head_seq_next = rob_head_seq;
    if (!i_flush_all && retire_1) begin
      rob_head_seq_next = rob_head_seq + (retire_2 ? SeqWidth'(2) : SeqWidth'(1));
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rob_head_seq             <= '0;
      rob_tail_seq             <= '0;
      rob_entry_epoch          <= '0;
      rob_writes_watch_int     <= '0;
      rob_writes_watch_fp      <= '0;
      env_ckpt_in_use          <= '0;
      env_ckpt_branch_live     <= '0;
      env_ckpt_branch_has_dest <= '0;
      early_backend_flush_q    <= 1'b0;
      commit_recovery_q        <= 1'b0;
      ckpt_flush_free_mask_q   <= '0;
      correct_free_1_q         <= 1'b0;
      correct_free_2_q         <= 1'b0;
      commit_valid_q           <= 1'b0;
      commit_dest_valid_q      <= 1'b0;
      commit_valid_2_q         <= 1'b0;
      commit_dest_valid_2_q    <= 1'b0;
      arch_int_has_prod        <= 1'b0;
      arch_int_seq             <= '0;
      arch_fp_has_prod         <= 1'b0;
      arch_fp_seq              <= '0;
      ckpt_int_has_prod        <= '0;
      ckpt_fp_has_prod         <= '0;
      watch_ckpt_written       <= 1'b0;
    end else begin
      env_ckpt_in_use <= env_ckpt_in_use_next;
      rob_head_seq    <= rob_head_seq_next;

      // 1-cycle pipelined commit bus to RAT (cleared on full flush, commit_bus_pipeline.sv).
      if (i_flush_all) begin
        commit_valid_q        <= 1'b0;
        commit_dest_valid_q   <= 1'b0;
        commit_valid_2_q      <= 1'b0;
        commit_dest_valid_2_q <= 1'b0;
      end else begin
        commit_valid_q <= retire_1;
        commit_tag_q   <= head_idx;
        if (CHECK_INT && rob_writes_watch_int[head_idx]) begin
          commit_dest_valid_q <= retire_1;
          commit_dest_rf_q    <= 1'b0;
          commit_dest_reg_q   <= watch_int_reg;
        end else if (CHECK_FP && rob_writes_watch_fp[head_idx]) begin
          commit_dest_valid_q <= retire_1;
          commit_dest_rf_q    <= 1'b1;
          commit_dest_reg_q   <= watch_fp_reg;
        end else begin
          commit_dest_valid_q <= retire_1 && i_other_commit_dest_valid;
          commit_dest_rf_q    <= i_other_commit_dest_rf;
          commit_dest_reg_q   <= i_other_commit_dest_reg;
        end

        commit_valid_2_q <= retire_2;
        commit_tag_2_q   <= head_next_idx;
        if (CHECK_INT && rob_writes_watch_int[head_next_idx]) begin
          commit_dest_valid_2_q <= retire_2;
          commit_dest_rf_2_q    <= 1'b0;
          commit_dest_reg_2_q   <= watch_int_reg;
        end else if (CHECK_FP && rob_writes_watch_fp[head_next_idx]) begin
          commit_dest_valid_2_q <= retire_2;
          commit_dest_rf_2_q    <= 1'b1;
          commit_dest_reg_2_q   <= watch_fp_reg;
        end else begin
          commit_dest_valid_2_q <= retire_2 && i_other_commit2_dest_valid;
          commit_dest_rf_2_q    <= i_other_commit2_dest_rf;
          commit_dest_reg_2_q   <= i_other_commit2_dest_reg;
        end
      end

      // Recovery pipeline sequencing.
      if (i_flush_all) begin
        early_backend_flush_q  <= 1'b0;
        commit_recovery_q      <= 1'b0;
        ckpt_flush_free_mask_q <= '0;
        correct_free_1_q       <= 1'b0;
        correct_free_2_q       <= 1'b0;
      end else begin
        early_backend_flush_q <= early_restore_active;
        if (early_restore_active) begin
          early_flush_ckpt_q <= i_early_mispredict_ckpt_id;
          early_flush_seq_q  <= early_cand_seq;
        end

        commit_recovery_q <= commit_mispredict_fire;
        if (commit_mispredict_fire) begin
          commit_recovery_ckpt_q <= head_ckpt_id;
        end

        if (dut_checkpoint_restore_reclaim_all) begin
          ckpt_flush_free_mask_q <= '0;
        end else if (early_backend_flush_q) begin
          ckpt_flush_free_mask_q <= younger_ckpt_mask;
        end else if (commit_recovery_q) begin
          ckpt_flush_free_mask_q <= env_ckpt_in_use_next;
        end else begin
          ckpt_flush_free_mask_q <= '0;
        end

        correct_free_1_q    <= retire_1 && head_has_ckpt && !commit_mispredict_fire;
        correct_free_1_id_q <= head_ckpt_id;
        correct_free_2_q    <= retire_2 && head_next_has_ckpt;
        correct_free_2_id_q <= head_next_ckpt_id;
      end

      // ROB tail and cpu_ooo per-allocation epoch toggle (cpu_ooo.sv:1918-1928).
      if (i_flush_all || commit_recovery_q) begin
        rob_tail_seq <= rob_head_seq_next;
      end else if (early_backend_flush_q) begin
        rob_tail_seq <= early_flush_seq_q + SeqWidth'(1);
      end else if (alloc_fire) begin
        rob_tail_seq <= rob_tail_seq + (slot2_fire ? SeqWidth'(2) : SeqWidth'(1));
        rob_entry_epoch[tail_idx] <= ~rob_entry_epoch[tail_idx];
        rob_writes_watch_int[tail_idx] <= dut_alloc_valid && !i_slot1_dest_rf &&
            (i_slot1_dest_reg == watch_int_reg);
        rob_writes_watch_fp[tail_idx] <= dut_alloc_valid && i_slot1_dest_rf &&
            (i_slot1_dest_reg == watch_fp_reg);

        if (slot2_fire) begin
          rob_entry_epoch[tail_idx_2] <= ~rob_entry_epoch[tail_idx_2];
          rob_writes_watch_int[tail_idx_2] <= dut_alloc_valid_2 && !i_slot2_dest_rf &&
              (i_slot2_dest_reg == watch_int_reg);
          rob_writes_watch_fp[tail_idx_2] <= dut_alloc_valid_2 && i_slot2_dest_rf &&
              (i_slot2_dest_reg == watch_fp_reg);
        end
      end

      // Checkpoint liveness and oracle snapshot updates.
      if (i_flush_all || commit_recovery_q || dut_checkpoint_restore_reclaim_all) begin
        env_ckpt_branch_live <= '0;
        ckpt_int_has_prod    <= '0;
        ckpt_fp_has_prod     <= '0;
      end else begin
        for (int c = 0; c < NumCheckpoints; c++) begin
          ckpt_int_has_prod[c] <= ckpt_int_after_retire[c];
          ckpt_fp_has_prod[c]  <= ckpt_fp_after_retire[c];
          if (!env_ckpt_in_use_next[c] || seq_retiring_now(
                  env_ckpt_branch_seq[c]
              ) || (early_backend_flush_q && younger_ckpt_mask[c])) begin
            env_ckpt_branch_live[c] <= 1'b0;
          end
        end

        if (dut_checkpoint_save) begin
          env_ckpt_branch_live[i_save_ckpt_id] <= 1'b1;
          env_ckpt_branch_seq[i_save_ckpt_id] <= ckpt_slot2_cand ? slot2_seq : slot1_seq;
          env_ckpt_branch_has_dest[i_save_ckpt_id] <= ckpt_slot2_cand ? dut_alloc_has_dest_2 :
              dut_alloc_has_dest;

          if (ckpt_slot2_cand && dut_alloc_valid && !i_slot1_dest_rf &&
              (i_slot1_dest_reg == watch_int_reg)) begin
            ckpt_int_has_prod[i_save_ckpt_id] <= 1'b1;
            ckpt_int_seq[i_save_ckpt_id]      <= slot1_seq;
          end else begin
            ckpt_int_has_prod[i_save_ckpt_id] <= arch_int_after_retire;
            ckpt_int_seq[i_save_ckpt_id]      <= arch_int_seq;
          end

          if (ckpt_slot2_cand && dut_alloc_valid && i_slot1_dest_rf &&
              (i_slot1_dest_reg == watch_fp_reg)) begin
            ckpt_fp_has_prod[i_save_ckpt_id] <= 1'b1;
            ckpt_fp_seq[i_save_ckpt_id]      <= slot1_seq;
          end else begin
            ckpt_fp_has_prod[i_save_ckpt_id] <= arch_fp_after_retire;
            ckpt_fp_seq[i_save_ckpt_id]      <= arch_fp_seq;
          end

          if (i_save_ckpt_id == watch_ckpt_id) begin
            watch_ckpt_written         <= 1'b1;
            watch_ckpt_ras_tos         <= i_ras_tos;
            watch_ckpt_ras_valid_count <= i_ras_valid_count;
            watch_ckpt_ras_top_ends    <= {i_ras_top[XLEN-1], i_ras_top[0]};
          end
        end
      end

      // Independent sequence oracle active rename updates (zero epoch arithmetic).
      if (dut_checkpoint_restore) begin
        if (commit_recovery_q) begin
          arch_int_has_prod <= 1'b0;
          arch_fp_has_prod  <= 1'b0;
        end else begin
          arch_int_has_prod <= ckpt_int_after_retire[dut_checkpoint_restore_id];
          arch_int_seq      <= ckpt_int_seq[dut_checkpoint_restore_id];
          arch_fp_has_prod  <= ckpt_fp_after_retire[dut_checkpoint_restore_id];
          arch_fp_seq       <= ckpt_fp_seq[dut_checkpoint_restore_id];
        end
      end else if (i_flush_all) begin
        arch_int_has_prod <= 1'b0;
        arch_fp_has_prod  <= 1'b0;
      end else begin
        arch_int_has_prod <= arch_int_after_retire;
        arch_fp_has_prod  <= arch_fp_after_retire;
        if (alloc_fire) begin
          if (dut_alloc_valid_2 && !i_slot2_dest_rf && (i_slot2_dest_reg == watch_int_reg)) begin
            arch_int_has_prod <= 1'b1;
            arch_int_seq      <= slot2_seq;
          end else if (dut_alloc_valid && !i_slot1_dest_rf &&
                       (i_slot1_dest_reg == watch_int_reg)) begin
            arch_int_has_prod <= 1'b1;
            arch_int_seq      <= slot1_seq;
          end

          if (dut_alloc_valid_2 && i_slot2_dest_rf && (i_slot2_dest_reg == watch_fp_reg)) begin
            arch_fp_has_prod <= 1'b1;
            arch_fp_seq      <= slot2_seq;
          end else if (dut_alloc_valid && i_slot1_dest_rf &&
                       (i_slot1_dest_reg == watch_fp_reg)) begin
            arch_fp_has_prod <= 1'b1;
            arch_fp_seq      <= slot1_seq;
          end
        end
      end
    end
  end

  // ===========================================================================
  // Safety Properties and Inductive Invariants
  // ===========================================================================
  logic oracle_int_renamed;
  logic oracle_fp_renamed;
  logic [TagWidth-1:0] oracle_int_tag;
  logic [TagWidth-1:0] oracle_fp_tag;

  assign oracle_int_renamed = arch_int_has_prod;
  assign oracle_fp_renamed = arch_fp_has_prod;
  assign oracle_int_tag = arch_int_seq[TagWidth-1:0];
  assign oracle_fp_tag = arch_fp_seq[TagWidth-1:0];

  logic ckpt_lower_all_used;
  always_comb begin
    ckpt_lower_all_used = 1'b1;
    for (int k = 0; k < NumCheckpoints; k++) begin
      if ((k[CheckpointIdWidth-1:0] < o_checkpoint_alloc_id) && !env_ckpt_in_use[k]) begin
        ckpt_lower_all_used = 1'b0;
      end
    end
  end

  // Helper signals for inductive invariants relating DUT storage to sequence oracle.
  wire commit_clears_watch_int =
      (commit_valid_q && commit_dest_valid_q && !commit_dest_rf_q &&
       (commit_dest_reg_q == watch_int_reg) && (commit_tag_q == dut.int_rat_tag[watch_int_reg])) ||
      (commit_valid_2_q && commit_dest_valid_2_q && !commit_dest_rf_2_q &&
       (commit_dest_reg_2_q == watch_int_reg) &&
       (commit_tag_2_q == dut.int_rat_tag[watch_int_reg]));

  wire commit_clears_watch_fp =
      (commit_valid_q && commit_dest_valid_q && commit_dest_rf_q &&
       (commit_dest_reg_q == watch_fp_reg) && (commit_tag_q == dut.fp_rat_tag[watch_fp_reg])) ||
      (commit_valid_2_q && commit_dest_valid_2_q && commit_dest_rf_2_q &&
       (commit_dest_reg_2_q == watch_fp_reg) &&
       (commit_tag_2_q == dut.fp_rat_tag[watch_fp_reg]));

  wire ok_dyn_x0_slot1 = !o_int_src2.renamed && (o_int_src2.value == '0);
  wire ok_dyn_x0_slot2 = !o_int_src2_2.renamed && (o_int_src2_2.value == '0);
  wire ok_ckpt_avail = (o_checkpoint_available == (env_ckpt_in_use != {NumCheckpoints{1'b1}}));
  wire ok_ckpt_alloc_free = !env_ckpt_in_use[o_checkpoint_alloc_id];
  wire ok_restore_ras = (o_ras_tos == watch_ckpt_ras_tos) &&
      (o_ras_valid_count == watch_ckpt_ras_valid_count) &&
      ({o_ras_top[XLEN-1], o_ras_top[0]} == watch_ckpt_ras_top_ends);
  wire ok_int_lookup_ren = (o_int_src1.renamed == oracle_int_renamed) &&
      (o_int_src1_2.renamed == oracle_int_renamed);
  wire ok_int_lookup_tag = (o_int_src1.tag == oracle_int_tag) &&
      (o_int_src1_2.tag == oracle_int_tag);
  wire ok_fp_lookup_ren = (o_fp_src1.renamed == oracle_fp_renamed) &&
      (o_fp_src1_2.renamed == oracle_fp_renamed);
  wire ok_fp_lookup_tag = (o_fp_src1.tag == oracle_fp_tag) && (o_fp_src1_2.tag == oracle_fp_tag);

  wire ok_rob_count_bound = (rob_count <= SeqWidth'(RobDepth));
  wire ok_ckpt_valid_eq = (dut.checkpoint_valid == env_ckpt_in_use);
  wire ok_x0_unrenamed = !dut.int_rat_valid[0];
  wire ok_rob_rf_disjoint = ((rob_writes_watch_int & rob_writes_watch_fp) == '0);
  wire ok_recovery_mutex = !(early_backend_flush_q && commit_recovery_q);
  wire ok_ckpt_free_disjoint = ((ckpt_flush_free_mask_q & env_ckpt_branch_live) == '0);
  wire ok_correct_free1_dead = !env_ckpt_branch_live[correct_free_1_id_q];
  wire ok_correct_free2_dead = !env_ckpt_branch_live[correct_free_2_id_q];
  wire ok_commit2_req_1 = !commit_valid_2_q;
  wire ok_commit1_dead = !rob_valid[commit_tag_q];
  wire ok_commit2_dead = !rob_valid[commit_tag_2_q] &&
      (commit_tag_2_q == (commit_tag_q + TagWidth'(1)));
  wire ok_early_in_rob = (SeqWidth'(early_flush_seq_q - rob_head_seq) < rob_count);
  wire ok_early_int_older =
      (SeqWidth'(arch_int_seq - rob_head_seq) < SeqWidth'(early_flush_seq_q - rob_head_seq));
  wire ok_early_fp_older =
      (SeqWidth'(arch_fp_seq - rob_head_seq) < SeqWidth'(early_flush_seq_q - rob_head_seq));
  wire ok_commit_rec_used = env_ckpt_in_use[commit_recovery_ckpt_q];
  wire ok_commit_rec_dead =
      !rob_valid[dut.u_ckpt_metadata.ram[commit_recovery_ckpt_q][TagWidth-1:0]];
  wire ok_watch_ras_ram =
      (dut.u_ckpt_metadata.ram[watch_ckpt_id][MetaRasLsb+:(2*RasPtrBits+1)] ==
       {watch_ckpt_ras_valid_count, watch_ckpt_ras_tos}) &&
      ({dut.u_ckpt_metadata.ram[watch_ckpt_id][MetaRasLsb+MetaRasWidth-1],
        dut.u_ckpt_metadata.ram[watch_ckpt_id][MetaRasLsb+2*RasPtrBits+1]} ==
       watch_ckpt_ras_top_ends);
  wire ok_active_int_live = (SeqWidth'(arch_int_seq - rob_head_seq) < rob_count) &&
      dut.int_rat_valid[watch_int_reg] && (dut.int_rat_tag[watch_int_reg] == oracle_int_tag) &&
      rob_writes_watch_int[oracle_int_tag];
  wire ok_active_int_dead = !dut.int_rat_valid[watch_int_reg] ||
      (!rob_valid[dut.int_rat_tag[watch_int_reg]] &&
       (commit_clears_watch_int || commit_recovery_q));
  wire ok_active_fp_live = (SeqWidth'(arch_fp_seq - rob_head_seq) < rob_count) &&
      dut.fp_rat_valid[watch_fp_reg] && (dut.fp_rat_tag[watch_fp_reg] == oracle_fp_tag) &&
      rob_writes_watch_fp[oracle_fp_tag];
  wire ok_active_fp_dead = !dut.fp_rat_valid[watch_fp_reg] ||
      (!rob_valid[dut.fp_rat_tag[watch_fp_reg]] &&
       (commit_clears_watch_fp || commit_recovery_q));

  wire inv_active_int_ok = !CHECK_INT || (
      ((i_probe_int_addr != '0) || ok_dyn_x0_slot1) &&
      ((i_probe_int_addr_2 != '0) || ok_dyn_x0_slot2) &&
      ok_ckpt_avail &&
      (!o_checkpoint_available || (ok_ckpt_alloc_free && ckpt_lower_all_used)) &&
      (!(dut_checkpoint_restore && (dut_checkpoint_restore_id == watch_ckpt_id) &&
         watch_ckpt_written) || ok_restore_ras) &&
      ok_int_lookup_ren &&
      (!oracle_int_renamed || ok_int_lookup_tag) &&
      ok_x0_unrenamed &&
      (!(early_backend_flush_q && arch_int_has_prod) || ok_early_int_older) &&
      (!watch_ckpt_written || ok_watch_ras_ram) &&
      (arch_int_has_prod ? ok_active_int_live : ok_active_int_dead));

  wire inv_active_fp_ok = !CHECK_FP || (
      ok_fp_lookup_ren &&
      (!oracle_fp_renamed || ok_fp_lookup_tag) &&
      (!(early_backend_flush_q && arch_fp_has_prod) || ok_early_fp_older) &&
      (arch_fp_has_prod ? ok_active_fp_live : ok_active_fp_dead));

  wire inv_active_shared_ok =
      ok_rob_count_bound &&
      ok_ckpt_valid_eq &&
      (!(CHECK_INT && CHECK_FP) || ok_rob_rf_disjoint) &&
      ok_recovery_mutex &&
      ok_ckpt_free_disjoint &&
      (!correct_free_1_q || ok_correct_free1_dead) &&
      (!correct_free_2_q || ok_correct_free2_dead) &&
      (commit_valid_q ? ok_commit1_dead : ok_commit2_req_1) &&
      (!commit_valid_2_q || ok_commit2_dead) &&
      (!early_backend_flush_q || ok_early_in_rob) &&
      (!commit_recovery_q || (ok_commit_rec_used && ok_commit_rec_dead));

  wire inv_active_ok = !(f_past_valid && i_rst_n) ||
      (inv_active_int_ok && inv_active_fp_ok && inv_active_shared_ok);

  if (CHECK_ACTIVE) begin : g_active_asserts
    always_comb begin
      if (f_past_valid && i_rst_n) begin
        if (CHECK_INT) begin
          // Dynamic probe ports report unrenamed zero whenever selecting x0.
          if (i_probe_int_addr == '0) begin
            p_dynamic_x0_slot1_zero : assert (ok_dyn_x0_slot1);
          end
          if (i_probe_int_addr_2 == '0) begin
            p_dynamic_x0_slot2_zero : assert (ok_dyn_x0_slot2);
          end

          // Checkpoint availability and lowest-index free-slot priority encoder match occupancy.
          p_ckpt_avail_exact : assert (ok_ckpt_avail);
          if (o_checkpoint_available) begin
            p_ckpt_alloc_id_free : assert (ok_ckpt_alloc_free);
            p_ckpt_alloc_id_lowest : assert (ckpt_lower_all_used);
          end

          // Combinational RAS recovery outputs match the saved checkpoint metadata during restore.
          if (dut_checkpoint_restore && (dut_checkpoint_restore_id == watch_ckpt_id) &&
              watch_ckpt_written) begin
            p_restore_ras_metadata_exact : assert (ok_restore_ras);
          end

          // Watched INT lookups on both dispatch slots match the sequence oracle.
          p_int_lookup_renamed_exact : assert (ok_int_lookup_ren);
          if (oracle_int_renamed) begin
            p_int_lookup_tag_exact : assert (ok_int_lookup_tag);
          end
        end

        if (CHECK_FP) begin
          // Watched FP lookups on both dispatch slots match the sequence oracle.
          p_fp_lookup_renamed_exact : assert (ok_fp_lookup_ren);
          if (oracle_fp_renamed) begin
            p_fp_lookup_tag_exact : assert (ok_fp_lookup_tag);
          end
        end

        // ---------------------------------------------------------------------
        // Inductive invariants
        // ---------------------------------------------------------------------
        p_inv_rob_count_bound : assert (ok_rob_count_bound);
        p_inv_ckpt_valid_eq : assert (ok_ckpt_valid_eq);
        if (CHECK_INT) begin
          p_inv_x0_rat_unrenamed : assert (ok_x0_unrenamed);
        end
        if (CHECK_INT && CHECK_FP) begin
          p_inv_rob_rf_disjoint : assert (ok_rob_rf_disjoint);
        end
        p_inv_recovery_mutex : assert (ok_recovery_mutex);
        p_inv_ckpt_free_disjoint : assert (ok_ckpt_free_disjoint);

        if (correct_free_1_q) begin
          p_inv_correct_free1_dead : assert (ok_correct_free1_dead);
        end
        if (correct_free_2_q) begin
          p_inv_correct_free2_dead : assert (ok_correct_free2_dead);
        end

        if (!commit_valid_q) begin
          p_inv_commit2_requires_1 : assert (ok_commit2_req_1);
        end else begin
          p_inv_commit1_dead : assert (ok_commit1_dead);
        end
        if (commit_valid_2_q) begin
          p_inv_commit2_dead : assert (ok_commit2_dead);
        end

        if (early_backend_flush_q) begin
          p_inv_early_flush_in_rob : assert (ok_early_in_rob);
          if (CHECK_INT && arch_int_has_prod) begin
            p_inv_early_flush_int_older : assert (ok_early_int_older);
          end
          if (CHECK_FP && arch_fp_has_prod) begin
            p_inv_early_flush_fp_older : assert (ok_early_fp_older);
          end
        end

        if (commit_recovery_q) begin
          p_inv_commit_rec_ckpt_used : assert (ok_commit_rec_used);
          p_inv_commit_rec_br_dead : assert (ok_commit_rec_dead);
        end

        if (CHECK_INT && watch_ckpt_written) begin
          p_inv_watch_ras_ram : assert (ok_watch_ras_ram);
        end

        if (CHECK_INT) begin
          if (arch_int_has_prod) begin
            p_inv_active_int_live : assert (ok_active_int_live);
          end else begin
            p_inv_active_int_dead : assert (ok_active_int_dead);
          end
        end

        if (CHECK_FP) begin
          if (arch_fp_has_prod) begin
            p_inv_active_fp_live : assert (ok_active_fp_live);
          end else begin
            p_inv_active_fp_dead : assert (ok_active_fp_dead);
          end
        end
      end
    end
  end

  function automatic logic [RatEntryWidth-1:0] slice_rat_entry(
      input logic [IntRatSnapshotWidth-1:0] snap, input logic [RegAddrWidth-1:0] idx);
    case (idx)
      5'd0:    slice_rat_entry = snap[0*RatEntryWidth+:RatEntryWidth];
      5'd1:    slice_rat_entry = snap[1*RatEntryWidth+:RatEntryWidth];
      5'd2:    slice_rat_entry = snap[2*RatEntryWidth+:RatEntryWidth];
      5'd3:    slice_rat_entry = snap[3*RatEntryWidth+:RatEntryWidth];
      5'd4:    slice_rat_entry = snap[4*RatEntryWidth+:RatEntryWidth];
      5'd5:    slice_rat_entry = snap[5*RatEntryWidth+:RatEntryWidth];
      5'd6:    slice_rat_entry = snap[6*RatEntryWidth+:RatEntryWidth];
      5'd7:    slice_rat_entry = snap[7*RatEntryWidth+:RatEntryWidth];
      5'd8:    slice_rat_entry = snap[8*RatEntryWidth+:RatEntryWidth];
      5'd9:    slice_rat_entry = snap[9*RatEntryWidth+:RatEntryWidth];
      5'd10:   slice_rat_entry = snap[10*RatEntryWidth+:RatEntryWidth];
      5'd11:   slice_rat_entry = snap[11*RatEntryWidth+:RatEntryWidth];
      5'd12:   slice_rat_entry = snap[12*RatEntryWidth+:RatEntryWidth];
      5'd13:   slice_rat_entry = snap[13*RatEntryWidth+:RatEntryWidth];
      5'd14:   slice_rat_entry = snap[14*RatEntryWidth+:RatEntryWidth];
      5'd15:   slice_rat_entry = snap[15*RatEntryWidth+:RatEntryWidth];
      5'd16:   slice_rat_entry = snap[16*RatEntryWidth+:RatEntryWidth];
      5'd17:   slice_rat_entry = snap[17*RatEntryWidth+:RatEntryWidth];
      5'd18:   slice_rat_entry = snap[18*RatEntryWidth+:RatEntryWidth];
      5'd19:   slice_rat_entry = snap[19*RatEntryWidth+:RatEntryWidth];
      5'd20:   slice_rat_entry = snap[20*RatEntryWidth+:RatEntryWidth];
      5'd21:   slice_rat_entry = snap[21*RatEntryWidth+:RatEntryWidth];
      5'd22:   slice_rat_entry = snap[22*RatEntryWidth+:RatEntryWidth];
      5'd23:   slice_rat_entry = snap[23*RatEntryWidth+:RatEntryWidth];
      5'd24:   slice_rat_entry = snap[24*RatEntryWidth+:RatEntryWidth];
      5'd25:   slice_rat_entry = snap[25*RatEntryWidth+:RatEntryWidth];
      5'd26:   slice_rat_entry = snap[26*RatEntryWidth+:RatEntryWidth];
      5'd27:   slice_rat_entry = snap[27*RatEntryWidth+:RatEntryWidth];
      5'd28:   slice_rat_entry = snap[28*RatEntryWidth+:RatEntryWidth];
      5'd29:   slice_rat_entry = snap[29*RatEntryWidth+:RatEntryWidth];
      5'd30:   slice_rat_entry = snap[30*RatEntryWidth+:RatEntryWidth];
      default: slice_rat_entry = snap[31*RatEntryWidth+:RatEntryWidth];
    endcase
  endfunction

  // Snapshot RAM invariants across all 8 checkpoints for watched INT and FP lanes.
  logic [NumCheckpoints-1:0] inv_ckpt_ok;
  genvar c;
  generate
    for (c = 0; c < NumCheckpoints; c++) begin : g_ckpt_inv
      wire [SeqWidth-1:0] br_seq = env_ckpt_branch_seq[c];
      wire [TagWidth-1:0] br_tag = br_seq[TagWidth-1:0];
      wire [TagWidth-1:0] br_dist = br_tag - head_idx;
      wire [IntRatSnapshotWidth-1:0] ram_int_half =
          dut.u_ckpt_rat_snapshot.ram[c][IntRatSnapshotWidth-1:0];
      wire [IntRatSnapshotWidth-1:0] ram_fp_half =
          dut.u_ckpt_rat_snapshot.ram[c][2*IntRatSnapshotWidth-1:IntRatSnapshotWidth];
      wire [RatEntryWidth-1:0] snap_int = CHECK_INT ? slice_rat_entry(
          ram_int_half, watch_int_reg
      ) : '0;
      wire [RatEntryWidth-1:0] snap_fp = CHECK_FP ? slice_rat_entry(ram_fp_half, watch_fp_reg) : '0;
      wire [TagWidth-1:0] snap_int_tag = snap_int[TagWidth-1:0];
      wire [TagWidth-1:0] snap_fp_tag = snap_fp[TagWidth-1:0];
      wire [TagWidth-1:0] snap_int_dist = snap_int_tag - head_idx;
      wire [TagWidth-1:0] snap_fp_dist = snap_fp_tag - head_idx;
      wire [SeqWidth-1:0] p_seq = ckpt_int_seq[c];
      wire [TagWidth-1:0] p_tag = p_seq[TagWidth-1:0];
      wire [SeqWidth-1:0] fp_seq = ckpt_fp_seq[c];
      wire [TagWidth-1:0] fp_tag = fp_seq[TagWidth-1:0];

      logic other_live_same_seq;
      always_comb begin
        other_live_same_seq = 1'b0;
        for (int d = 0; d < NumCheckpoints; d++) begin
          if ((d != c) && env_ckpt_branch_live[d] && (env_ckpt_branch_seq[d] == br_seq)) begin
            other_live_same_seq = 1'b1;
          end
        end
      end

      wire ok_ckpt_live_used = env_ckpt_in_use[c] &&
          (SeqWidth'(br_seq - rob_head_seq) < rob_count) && !other_live_same_seq;
      wire ok_ckpt_meta_br = (dut.u_ckpt_metadata.ram[c][TagWidth-1:0] == br_tag) &&
          (dut.u_ckpt_metadata.ram[c][TagWidth] == rob_entry_epoch[br_tag]);
      wire ok_ckpt_x0 = !dut.u_ckpt_rat_snapshot.ram[c][TagWidth+1];
      wire ok_ckpt_int_live = (SeqWidth'(p_seq - rob_head_seq) < br_dist) &&
          (snap_int == {1'b1, rob_entry_epoch[p_tag], p_tag}) && rob_writes_watch_int[p_tag];
      wire ok_ckpt_int_dead = !snap_int[TagWidth+1] || !(snap_int_dist < br_dist) ||
          (snap_int[TagWidth] != rob_entry_epoch[snap_int_tag]);
      wire ok_ckpt_fp_live = (SeqWidth'(fp_seq - rob_head_seq) < br_dist) &&
          (snap_fp == {1'b1, rob_entry_epoch[fp_tag], fp_tag}) && rob_writes_watch_fp[fp_tag];
      wire ok_ckpt_fp_dead = !snap_fp[TagWidth+1] || !(snap_fp_dist < br_dist) ||
          (snap_fp[TagWidth] != rob_entry_epoch[snap_fp_tag]);
      wire ok_ckpt_int_part = !CHECK_INT ||
          (ok_ckpt_x0 && (ckpt_int_has_prod[c] ? ok_ckpt_int_live : ok_ckpt_int_dead));
      wire ok_ckpt_fp_part = !CHECK_FP || (ckpt_fp_has_prod[c] ? ok_ckpt_fp_live : ok_ckpt_fp_dead);

      assign inv_ckpt_ok[c] = !(f_past_valid && i_rst_n && env_ckpt_branch_live[c]) ||
          (ok_ckpt_live_used && ok_ckpt_meta_br && ok_ckpt_int_part && ok_ckpt_fp_part);

      if (((CHECK_CKPT_MASK >> c) & 1) != 0) begin : g_ckpt_asserts
        always_comb begin
          if (f_past_valid && i_rst_n && env_ckpt_branch_live[c]) begin
            p_inv_ckpt_live_used : assert (ok_ckpt_live_used);
            p_inv_ckpt_meta_branch : assert (ok_ckpt_meta_br);

            if (CHECK_INT) begin
              p_inv_ckpt_x0_unrenamed : assert (ok_ckpt_x0);
              if (ckpt_int_has_prod[c]) begin
                p_inv_ckpt_int_live : assert (ok_ckpt_int_live);
              end else begin
                p_inv_ckpt_int_dead : assert (ok_ckpt_int_dead);
              end
            end

            if (CHECK_FP) begin
              if (ckpt_fp_has_prod[c]) begin
                p_inv_ckpt_fp_live : assert (ok_ckpt_fp_live);
              end else begin
                p_inv_ckpt_fp_dead : assert (ok_ckpt_fp_dead);
              end
            end
          end
        end
      end
    end
  endgenerate

  // Partitioned induction tasks share only the preceding cycle's assertion
  // results (initialized true), so a first failure on any cycle satisfies
  // prior_all_inv_ok and fails in its owning partition.
  if (!CHECK_ACTIVE || (CHECK_CKPT_MASK != 255)) begin : g_partition_history
    logic prior_all_inv_ok = 1'b1;
    always_ff @(posedge i_clk) begin
      prior_all_inv_ok <= inv_active_ok && (&inv_ckpt_ok);
    end
    always_comb begin
      assume (prior_all_inv_ok);
    end
  end

  // ===========================================================================
  // Reachability Covers
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (f_past_valid && i_rst_n) begin
      if (CHECK_INT) begin
        // Reach checkpoint pool exhaustion (all 8 checkpoints simultaneously live).
        c_all_checkpoints_full : cover (!o_checkpoint_available);

        // Reach highest priority-encoder slot selection (ids 0..6 occupied, id 7 free).
        c_alloc_id_7 : cover (o_checkpoint_available && (o_checkpoint_alloc_id == 3'd7));

        // Reach slot-2 branch overlay save, wrong-path overwrite, and early restore of slot-1 tag.
        c_slot2_overlay_save_clobber_restore :
        cover ($past(
            i_rst_n && early_restore_active && (i_early_mispredict_ckpt_id == watch_ckpt_id) &&
            ckpt_int_after_retire[watch_ckpt_id] &&
            (!arch_int_has_prod || (arch_int_seq != ckpt_int_seq[watch_ckpt_id]))
        ) && o_int_src1.renamed);

        // Reach commit-time jump recovery clearing active rename state after branch retirement.
        c_commit_recovery_clears_rat :
        cover ($past(i_rst_n && commit_recovery_q && arch_int_has_prod) && !o_int_src1.renamed);
      end

      if (CHECK_FP) begin
        // Reach slot-2 FP commit clearing a matching FP rename mapping.
        c_slot2_fp_commit_clear :
        cover ($past(
            i_rst_n && commit_valid_2_q && commit_dest_valid_2_q && commit_dest_rf_2_q &&
            (commit_dest_reg_2_q == watch_fp_reg) && !dut_checkpoint_restore && !i_flush_all
        ) && !o_fp_src1.renamed);
      end
    end
  end

endmodule
