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
 * Branch and jump instructions issue from INT_RS and resolve here
 * combinationally, in a wrapper around branch_jump_unit. The output is the
 * reorder_buffer_branch_update_t the ROB uses to decide misprediction.
 * Conditional branches have no other completion path: the INT RS predecodes
 * their CDB writeback hint clear, so int_alu_shim never completes them.
 *
 * The architectural update is suppressed for entries the pipeline is
 * discarding: any valid entry during a trap, mret or fence.i flush, the
 * mispredicting branch and anything younger during an early recovery, and any
 * valid entry during a commit-time recovery. The issuing branch's checkpoint
 * owner is checked as well, so a branch holding a stale or reused checkpoint
 * id produces no update.
 *
 * Condition and target resolve from the registered class bits in parallel
 * with that qualification, which gates only update validity and the
 * misprediction flag. The checkpoint-owner and age predicates read
 * i_branch_predicate_tag, a same-edge twin of the INT stage2 tag. The branch
 * update and the ROB path keep the architectural issue tag.
 *
 * Purely combinational.
 */

module branch_resolution #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input riscv_pkg::rs_issue_t i_rs_issue_int,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_branch_predicate_tag,
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

  // --- Port aliases preserve the signal names used by the extracted body.
  riscv_pkg::rs_issue_t rs_issue_int;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] branch_predicate_tag;
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
  assign branch_predicate_tag           = i_branch_predicate_tag;
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
  // muxed the 5-bit owner tag by checkpoint_id and then compared it against
  // rob_tag: an 8:1 x 5b mux and a 5b compare in series.  Computing the
  // per-checkpoint live bit first lets all eight in_use plus owner-tag
  // compares run in parallel straight out of the checkpoint registers,
  // leaving only a 1-bit 8:1 select behind checkpoint_id.  The two forms are
  // boolean identities: for every checkpoint_id value the selected bit is the
  // original expression.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_live_per_id;
  always_comb begin
    for (int i = 0; i < riscv_pkg::NumCheckpoints; i++) begin
      // Use the registered checkpoint state here to avoid a feedback loop
      // through execute-time checkpoint free.  The owner-tag check still
      // filters out stale/reused checkpoint IDs.
      checkpoint_live_per_id[i] =
          checkpoint_in_use[i] && (checkpoint_owner_tag[i] == branch_predicate_tag);
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
  // Suppress only the entries that are being flushed.  Suppressing all branch
  // resolution during a partial recovery can drop an older surviving branch
  // that issues in the recovery cycle, leaving its ROB entry permanently
  // unresolved.
  assign branch_issue_age = {1'b0, branch_predicate_tag} - {1'b0, head_tag};
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
    // rob_head_commit_misprediction_candidate is not used here to suppress
    // branch resolution.  Routing the candidate signal through
    // suppress_branch_resolution → is_branch_issue → branch comparison (CARRY8)
    // → branch_update → commit_en created a 16-level combinational chain that
    // was the WNS critical path (-0.739 ns).  Removing it is safe because:
    //   (a) a resolving branch can never be the committing head.  Branches have
    //       no CDB done-bypass (reorder_buffer head_cdb_bypass excludes
    //       head_is_branch), so a branch's done bit is registered and it can
    //       only be head_ready the cycle after its branch_update.
    //   (b) resolution writes to entries that will be flushed are harmless:
    //       flush-after-head invalidates them next cycle, allocation re-inits
    //       the branch bits, and the unresolved-branch counter resets on
    //       flush_pipeline.
    //   (c) an early_mispredict_fire coinciding with a head-mispredict commit
    //       is dropped one cycle later.  early_mispredict_active gates on
    //       !mispredict_recovery_pending (early_misprediction_recovery.sv),
    //       which registers the commit-time recovery launch, so the early
    //       pulse dies before any redirect, RAT restore, rob_early_recovered
    //       write or backend flush.  The fire-time candidate gate that used to
    //       do this was removed for timing, and
    //       o_head_commit_misprediction_candidate is now an unconsumed
    //       observation output.
  end

  assign suppress_branch_resolution = branch_issue_is_flushed;

  // TIMING: the branch class and the branch_taken_op_e select are pre-decoded
  // at dispatch and registered through the RS payload and stage2 register
  // (rs_issue_t.is_branch_class/is_jal/is_jalr/branch_op). Consuming the
  // registered bits here keeps the instr_op_e equality trees out of the
  // stage2_op -> branch_mispredicted -> early-mispredict-capture cycle. The
  // decode is bit-identical: reservation_station's rs_is_branch_class_op and
  // rs_branch_op_of mirror the former inline forms.
  logic is_branch_issue;
  assign is_branch_issue = rs_issue_int.valid && branch_issue_checkpoint_live &&
                           !suppress_branch_resolution && rs_issue_int.is_branch_class;

  logic is_jalr_issue;
  assign is_jalr_issue = is_branch_issue && rs_issue_int.is_jalr;
  logic is_branch_update_issue;
  assign is_branch_update_issue = is_branch_issue && !rs_issue_int.is_jal;

  // Pre-decoded instr_op_e → branch_taken_op_e select for branch_jump_unit
  riscv_pkg::branch_taken_op_e branch_op_resolved;
  assign branch_op_resolved = rs_issue_int.branch_op;

  // Branch/jump condition evaluation and target computation
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) u_branch_resolve (
      .i_branch_operation         (branch_op_resolved),
      // TIMING: is_jal/is_jalr are registered members of the INT stage2
      // payload.  Resolve from those raw class bits in parallel with the
      // checkpoint-owner and flush qualification above.  Qualification
      // matters only where the result becomes an architectural branch_update.
      // Putting it on these selects serialized every condition and target
      // cone behind the checkpoint-owner compare.  For a valid update JAL is
      // already excluded and the qualified JALR bit equals the raw bit, so
      // the observed update is bit-identical to the former gated datapath.
      .i_is_jump_and_link         (rs_issue_int.is_jal),
      .i_is_jump_and_link_register(rs_issue_int.is_jalr),
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

  // Misprediction detection.  The ROB trusts this flag.
  // Preserve the raw mismatch boundary so synthesis cannot duplicate the
  // checkpoint-qualified final AND back into the target comparator cone.
  (* keep = "true" *) logic prediction_wrong;
  always_comb begin
    if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      // Direction misprediction (taken vs not-taken)
      prediction_wrong = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 branch_target_resolved != rs_issue_int.predicted_target) begin
      // Target misprediction (both taken but different targets)
      prediction_wrong = 1'b1;
    end else begin
      prediction_wrong = 1'b0;
    end
  end

  // Keep the raw prediction comparison independent of checkpoint state, then
  // apply the issue qualification once at the observed flag.
  // This is the Shannon factorization of the former leading
  // `if (!is_branch_update_issue)`: Q ? prediction_wrong : 1'b0.
  logic branch_mispredicted;
  assign branch_mispredicted = is_branch_update_issue && prediction_wrong;

  // Generate branch_update for the ROB
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  always_comb begin
    branch_update              = '0;
    // JAL is resolved architecturally at ROB allocation time, so its later
    // branch-unit issue must not write back into a possibly already-committed
    // ROB slot.
    branch_update.valid        = is_branch_update_issue;
    // Keep the architectural tag on the update/ROB path.  The physical twin
    // above drives the qualification predicates only.
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

`ifndef SYNTHESIS
  // Executable equivalence checks for the late qualification cut.  The
  // reference expression is the former priority form.  Keeping it here catches
  // qualification drifting back into the raw resolution cone.
  logic branch_mispredicted_reference;
  always_comb begin
    if (!is_branch_update_issue) begin
      branch_mispredicted_reference = 1'b0;
    end else if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      branch_mispredicted_reference = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 branch_target_resolved != rs_issue_int.predicted_target) begin
      branch_mispredicted_reference = 1'b1;
    end else begin
      branch_mispredicted_reference = 1'b0;
    end
  end

  always_comb begin
    if (!$isunknown(
            {
              is_branch_issue,
              is_branch_update_issue,
              is_jalr_issue,
              rs_issue_int.is_jal,
              rs_issue_int.is_jalr,
              branch_update.valid,
              branch_update.mispredicted,
              branch_mispredicted_reference
            }
        )) begin
      p_branch_update_qualification_exact : assert (branch_update.valid == is_branch_update_issue);
      p_prediction_wrong_late_factor_exact :
      assert (branch_update.mispredicted == branch_mispredicted_reference);
      p_qualified_update_uses_raw_jump_class :
      assert (!is_branch_update_issue ||
              (!rs_issue_int.is_jal && (is_jalr_issue == rs_issue_int.is_jalr)));
    end
  end
`endif

endmodule : branch_resolution
