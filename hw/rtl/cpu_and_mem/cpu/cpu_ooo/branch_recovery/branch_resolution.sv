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
 * Branch resolution unit.
 *
 * Branch/jump instructions issue from INT_RS with their CDB broadcast
 * suppressed by the ALU shim; this block resolves them combinationally
 * (wrapping branch_jump_unit) and produces the reorder_buffer_branch_update_t
 * the ROB trusts for misprediction. It suppresses resolution for entries that
 * are actually being flushed (trap/mret/fence.i, or younger than an in-flight
 * early/commit recovery) and validates the issuing branch's checkpoint owner.
 *
 * Purely combinational. Extracted verbatim from cpu_ooo (no functional change):
 * the body below is the former "Branch Resolution Unit" section, with the
 * parent's signals presented as ports and aliased back to their original names.
 */

module branch_resolution #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input riscv_pkg::rs_issue_t i_rs_issue_int,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_mispredict_tag,
    input logic i_early_mispredict_active,
    input logic i_early_backend_recovery_pending,
    input logic i_mispredict_recovery_pending,
    input riscv_pkg::mispredict_commit_capture_t i_mispredict_commit_q,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_fence_i_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0]
        i_checkpoint_owner_tag,

    output riscv_pkg::reorder_buffer_branch_update_t            o_branch_update,
    output logic                                                o_branch_resolved_correct,
    output logic                                                o_branch_unresolved_decrement,
    output logic                                                o_is_jalr_issue,
    output logic                                                o_branch_taken_resolved,
    output logic                                     [XLEN-1:0] o_branch_target_resolved
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::rs_issue_t rs_issue_int;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic early_mispredict_active;
  logic early_backend_recovery_pending;
  logic mispredict_recovery_pending;
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic flush_for_trap;
  logic flush_for_mret;
  logic fence_i_flush;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;
  logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag;
  assign rs_issue_int                   = i_rs_issue_int;
  assign head_tag                       = i_head_tag;
  assign early_mispredict_tag           = i_early_mispredict_tag;
  assign early_mispredict_active        = i_early_mispredict_active;
  assign early_backend_recovery_pending = i_early_backend_recovery_pending;
  assign mispredict_recovery_pending    = i_mispredict_recovery_pending;
  assign mispredict_commit_q            = i_mispredict_commit_q;
  assign flush_for_trap                 = i_flush_for_trap;
  assign flush_for_mret                 = i_flush_for_mret;
  assign fence_i_flush                  = i_fence_i_flush;
  assign checkpoint_in_use              = i_checkpoint_in_use;
  assign checkpoint_owner_tag           = i_checkpoint_owner_tag;

  logic suppress_branch_resolution;
  logic branch_issue_is_flushed;
  logic branch_issue_checkpoint_live;
  logic [riscv_pkg::ReorderBufferTagWidth:0] branch_issue_age;
  logic [riscv_pkg::ReorderBufferTagWidth:0] early_flush_age;
  logic [riscv_pkg::ReorderBufferTagWidth:0] commit_flush_age;
  // TIMING: compare-then-mux instead of mux-then-compare.  The original form
  // muxed the 5-bit owner tag by checkpoint_id and THEN compared against
  // rob_tag (8:1 x 5b mux + 5b compare in series).  Computing the per-
  // checkpoint live bit first lets all eight in_use+owner-tag compares run in
  // parallel straight out of the checkpoint registers, leaving only a 1-bit
  // 8:1 select behind checkpoint_id.  Pure boolean identity — for every
  // checkpoint_id value the selected bit is exactly the original expression.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_live_per_id;
  always_comb begin
    for (int i = 0; i < riscv_pkg::NumCheckpoints; i++) begin
      // Use the registered checkpoint state here to avoid a feedback loop
      // through execute-time checkpoint free.  The owner-tag check still
      // filters out stale/reused checkpoint IDs.
      checkpoint_live_per_id[i] =
          checkpoint_in_use[i] && (checkpoint_owner_tag[i] == rs_issue_int.rob_tag);
    end
  end
  always_comb begin
    branch_issue_checkpoint_live = 1'b1;
    if (rs_issue_int.has_checkpoint) begin
      branch_issue_checkpoint_live = checkpoint_live_per_id[rs_issue_int.checkpoint_id];
    end
  end

  // The INT RS leaves o_issue.valid ungated for one cycle around flushes so a
  // just-flushed stage2 entry can still appear at the branch-resolution input.
  // Suppress only entries that are actually being flushed.  Suppressing all
  // branch resolution during a partial recovery can drop an older surviving
  // branch if it happens to issue in the recovery cycle, leaving its ROB entry
  // permanently unresolved.
  assign branch_issue_age = {1'b0, rs_issue_int.rob_tag} - {1'b0, head_tag};
  assign early_flush_age  = {1'b0, early_mispredict_tag} - {1'b0, head_tag};
  assign commit_flush_age = {1'b0, mispredict_commit_q.tag} - {1'b0, head_tag};

  always_comb begin
    branch_issue_is_flushed = 1'b0;

    if (flush_for_trap || flush_for_mret || fence_i_flush) begin
      branch_issue_is_flushed = rs_issue_int.valid;
    end else if (early_mispredict_active) begin
      // Partial early recovery keeps only entries strictly older than the
      // mispredicting branch.  The flush-tag branch itself has already
      // generated recovery data and must not re-resolve.
      branch_issue_is_flushed = rs_issue_int.valid && (branch_issue_age >= early_flush_age);
    end else if (early_backend_recovery_pending) begin
      branch_issue_is_flushed = rs_issue_int.valid && (branch_issue_age >= early_flush_age);
    end else if (mispredict_recovery_pending) begin
      // Commit-time recovery only fires when the mispredicted branch commits at
      // the ROB head, so there are no older survivors to preserve here. Using
      // a head-relative age compare in this cycle is incorrect because head_tag
      // has already advanced past the mispredicting branch, which can let a
      // just-flushed younger branch re-resolve for one cycle.
      branch_issue_is_flushed = rs_issue_int.valid;
    end
    // NOTE: rob_head_commit_misprediction_candidate is intentionally NOT used
    // here to suppress branch resolution.  Routing the candidate signal through
    // suppress_branch_resolution → is_branch_issue → branch comparison (CARRY8)
    // → branch_update → commit_en created a 16-level combinational chain that
    // was the WNS critical path (-0.739 ns).  Removing it is safe because:
    //   (a) a resolving branch can never BE the committing head: branches have
    //       no CDB done-bypass (reorder_buffer head_cdb_bypass excludes
    //       head_is_branch), so a branch's done bit is registered and it can
    //       only be head_ready the cycle AFTER its branch_update;
    //   (b) resolution writes to entries that will be flushed are harmless --
    //       flush-after-head invalidates them next cycle, allocation re-inits
    //       the branch bits, and the unresolved-branch counter resets on
    //       flush_pipeline;
    //   (c) an early_mispredict_fire coinciding with a head-mispredict commit
    //       is DROPPED one cycle later: early_mispredict_active gates on
    //       !mispredict_recovery_pending (early_misprediction_recovery.sv),
    //       which registers the commit-time recovery launch, so the early
    //       pulse dies before any redirect / RAT restore / rob_early_recovered
    //       write / backend flush.  (The former fire-time candidate gate was
    //       removed for timing; o_head_commit_misprediction_candidate is now
    //       an unconsumed observation output.)
  end

  assign suppress_branch_resolution = branch_issue_is_flushed;

  logic is_branch_issue;
  assign is_branch_issue = rs_issue_int.valid && branch_issue_checkpoint_live &&
                           !suppress_branch_resolution && (
      rs_issue_int.op == riscv_pkg::BEQ  || rs_issue_int.op == riscv_pkg::BNE  ||
      rs_issue_int.op == riscv_pkg::BLT  || rs_issue_int.op == riscv_pkg::BGE  ||
      rs_issue_int.op == riscv_pkg::BLTU || rs_issue_int.op == riscv_pkg::BGEU ||
      rs_issue_int.op == riscv_pkg::JAL  || rs_issue_int.op == riscv_pkg::JALR);

  logic is_jal_issue, is_jalr_issue;
  assign is_jal_issue  = is_branch_issue && (rs_issue_int.op == riscv_pkg::JAL);
  assign is_jalr_issue = is_branch_issue && (rs_issue_int.op == riscv_pkg::JALR);
  logic is_branch_update_issue;
  assign is_branch_update_issue = is_branch_issue && !is_jal_issue;

  // Map instr_op_e → branch_taken_op_e for branch_jump_unit
  riscv_pkg::branch_taken_op_e branch_op_resolved;

  always_comb begin
    case (rs_issue_int.op)
      riscv_pkg::BEQ:                  branch_op_resolved = riscv_pkg::BREQ;
      riscv_pkg::BNE:                  branch_op_resolved = riscv_pkg::BRNE;
      riscv_pkg::BLT:                  branch_op_resolved = riscv_pkg::BRLT;
      riscv_pkg::BGE:                  branch_op_resolved = riscv_pkg::BRGE;
      riscv_pkg::BLTU:                 branch_op_resolved = riscv_pkg::BRLTU;
      riscv_pkg::BGEU:                 branch_op_resolved = riscv_pkg::BRGEU;
      riscv_pkg::JAL, riscv_pkg::JALR: branch_op_resolved = riscv_pkg::JUMP;
      default:                         branch_op_resolved = riscv_pkg::NULL;
    endcase
  end

  // Branch/jump condition evaluation and target computation
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) u_branch_resolve (
      .i_branch_operation         (branch_op_resolved),
      .i_is_jump_and_link         (is_jal_issue),
      .i_is_jump_and_link_register(is_jalr_issue),
      .i_operand_a                (rs_issue_int.src1_value[XLEN-1:0]),
      .i_operand_b                (rs_issue_int.src2_value[XLEN-1:0]),
      // Dispatch stores the correct pre-computed target in branch_target
      // (jal_target_precomputed for JAL, branch_target_precomputed for branches)
      .i_branch_target_precomputed(rs_issue_int.branch_target),
      .i_jal_target_precomputed   (rs_issue_int.branch_target),
      .i_immediate_i_type         (rs_issue_int.imm),
      .o_branch_taken             (branch_taken_resolved),
      .o_branch_target_address    (branch_target_resolved)
  );

  // Misprediction detection (authoritative — the ROB trusts this flag)
  logic branch_mispredicted;
  always_comb begin
    if (!is_branch_update_issue) begin
      branch_mispredicted = 1'b0;
    end else if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      // Direction misprediction (taken vs not-taken)
      branch_mispredicted = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 branch_target_resolved != rs_issue_int.predicted_target) begin
      // Target misprediction (both taken but different targets)
      branch_mispredicted = 1'b1;
    end else begin
      branch_mispredicted = 1'b0;
    end
  end

  // Generate branch_update for the ROB
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  always_comb begin
    branch_update              = '0;
    // JAL is resolved architecturally at ROB allocation time, so its later
    // branch-unit issue must not write back into a possibly already-committed
    // ROB slot.
    branch_update.valid        = is_branch_update_issue;
    branch_update.tag          = rs_issue_int.rob_tag;
    branch_update.taken        = branch_taken_resolved;
    branch_update.target       = branch_target_resolved;
    branch_update.mispredicted = branch_mispredicted;
  end

  // Early branch resolution: signals when a branch resolves as correctly
  // predicted.  Used to drop front_end_cf_serialize_stall early.
  logic branch_resolved_correct;
  assign branch_resolved_correct = branch_update.valid && !branch_update.mispredicted;

  // Direct JALs are architecturally resolved at dispatch/rename time and
  // therefore never enter the unresolved-branch tracker.
  logic branch_unresolved_decrement;
  assign branch_unresolved_decrement   = branch_resolved_correct;

  // --- Output wiring.
  assign o_branch_update               = branch_update;
  assign o_branch_resolved_correct     = branch_resolved_correct;
  assign o_branch_unresolved_decrement = branch_unresolved_decrement;
  assign o_is_jalr_issue               = is_jalr_issue;
  assign o_branch_taken_resolved       = branch_taken_resolved;
  assign o_branch_target_resolved      = branch_target_resolved;

endmodule : branch_resolution
