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
 * Combinational branch resolution.
 *
 * Conditional branches and JALR resolve from INT_RS; JAL resolves at ROB
 * allocation. Conditional branches have no CDB completion: the RS clears
 * their writeback hint, so this update is their only completion path.
 *
 * Flush and checkpoint checks qualify the update. Registered class bits
 * select the condition and target. Conditional branches carry a precomputed
 * target and target-match bit; JALR compares its computed target with the
 * INT station's tag-indexed prediction. i_branch_predicate_tag duplicates
 * the issue tag for checkpoint and age compares, for fanout.
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
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_fence_i_flush,
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0]
        i_checkpoint_owner_tag,

    output riscv_pkg::reorder_buffer_branch_update_t            o_branch_update,
    output logic                                                o_branch_resolved_correct,
    output logic                                                o_is_jalr_issue,
    output logic                                                o_branch_taken_resolved,
    output logic                                     [XLEN-1:0] o_branch_target_resolved
);

  // Port aliases.
  riscv_pkg::rs_issue_t rs_issue_int;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] branch_predicate_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic early_mispredict_active;
  logic early_backend_recovery_pending;
  logic mispredict_recovery_pending;
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
  // Compare each checkpoint tag before selecting the live bit, for timing.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_live_per_id;
  always_comb begin
    for (int i = 0; i < riscv_pkg::NumCheckpoints; i++) begin
      // Use registered checkpoint state to avoid feedback through execute-time
      // checkpoint free. The tag check rejects stale or reused checkpoint IDs.
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

  // The INT RS can present a flushed stage2 entry for one cycle. Suppress
  // only flushed entries: an older branch can survive partial recovery and
  // must resolve or its ROB entry will remain unfinished.
  assign branch_issue_age = {1'b0, branch_predicate_tag} - {1'b0, head_tag};
  assign early_flush_age  = {1'b0, early_mispredict_tag} - {1'b0, head_tag};

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
    // The ROB's head-commit misprediction candidate does not suppress resolution:
    //   (a) A resolving branch cannot commit that cycle. Branches have no CDB
    //       done bypass, so head_ready waits for the registered branch update.
    //   (b) Updates to entries about to be flushed are harmless: flush-after-head
    //       invalidates them next cycle, allocation resets their branch bits,
    //       and their unresolved bits in ooo_pipeline_control can be cleared.
    //   (c) If early recovery fires with a head-mispredict commit,
    //       mispredict_recovery_pending suppresses early_mispredict_active in
    //       the next cycle, before any redirect, RAT restore, early-recovered
    //       write, or backend flush.
  end

  assign suppress_branch_resolution = branch_issue_is_flushed;

  // The RS decodes branch class and branch_op at dispatch and registers them
  // through stage2.
  logic is_branch_issue;
  assign is_branch_issue = rs_issue_int.valid && branch_issue_checkpoint_live &&
                           !suppress_branch_resolution && rs_issue_int.is_branch_class;

  logic is_jalr_issue;
  assign is_jalr_issue = is_branch_issue && rs_issue_int.is_jalr;
  logic is_branch_update_issue;
  assign is_branch_update_issue = is_branch_issue && !rs_issue_int.is_jal;

  // Predecoded branch operation for branch_jump_unit.
  riscv_pkg::branch_taken_op_e branch_op_resolved;
  assign branch_op_resolved = rs_issue_int.branch_op;

  // Branch/jump condition evaluation and target computation
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) u_branch_resolve (
      .i_branch_operation         (branch_op_resolved),
      // Resolve from raw registered class bits; qualify the update below. For a
      // valid update, JAL is excluded and the raw JALR bit equals the qualified bit.
      .i_is_jump_and_link         (rs_issue_int.is_jal),
      .i_is_jump_and_link_register(rs_issue_int.is_jalr),
      .i_operand_a                (rs_issue_int.src1_value[XLEN-1:0]),
      .i_operand_b                (rs_issue_int.src2_value[XLEN-1:0]),
      // Dispatch carries the precomputed PC-relative target in imm for
      // conditional branches (and JAL, which never issues here).  JALR's imm
      // holds its link address; the unit computes its target from jalr_imm.
      .i_branch_target_precomputed(rs_issue_int.imm),
      .i_jal_target_precomputed   (rs_issue_int.imm),
      // JALR's I-immediate travels in its own 12-bit field; its imm word
      // carries the link address for the ALU.
      .i_immediate_i_type         (XLEN'(signed'(rs_issue_int.jalr_imm))),
      .o_branch_taken             (branch_taken_resolved),
      .o_branch_target_address    (branch_target_resolved)
  );

  // Misprediction detection. Keep the raw comparison separate for timing.
  (* keep = "true" *) logic prediction_wrong;
  always_comb begin
    if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      prediction_wrong = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 (rs_issue_int.is_jalr ?
                      (branch_target_resolved != rs_issue_int.predicted_target) :
                      !rs_issue_int.predicted_target_ok)) begin
      // Target misprediction (both taken but different targets).  A direct
      // branch's target is PC-relative, so ID compared it with the prediction
      // and dispatch forwarded the one-bit result; JALR compares its computed
      // target against the side-RAM predicted_target here.
      prediction_wrong = 1'b1;
    end else begin
      prediction_wrong = 1'b0;
    end
  end

  // Qualifying the raw mismatch here equals a priority check of issue validity
  // before direction and target.
  logic branch_mispredicted;
  assign branch_mispredicted = is_branch_update_issue && prediction_wrong;

  // Generate branch_update for the ROB
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  always_comb begin
    branch_update              = '0;
    // JAL resolves at ROB allocation and never issues here; it is excluded
    // anyway so that a JAL packet cannot write back into a possibly
    // committed ROB entry.
    branch_update.valid        = is_branch_update_issue;
    // Use the architectural tag for the update; the duplicate feeds predicates.
    branch_update.tag          = rs_issue_int.rob_tag;
    branch_update.taken        = branch_taken_resolved;
    branch_update.target       = branch_target_resolved;
    branch_update.mispredicted = branch_mispredicted;
  end

  // Set when a branch resolves as correctly predicted. It clears the branch's
  // unresolved bit in ooo_pipeline_control, so front_end_cf_serialize_stall
  // can drop before the branch commits. A JAL resolves at allocation and never
  // sets it.
  logic branch_resolved_correct;
  assign branch_resolved_correct   = branch_update.valid && !branch_update.mispredicted;

  // --- Output wiring.
  assign o_branch_update           = branch_update;
  assign o_branch_resolved_correct = branch_resolved_correct;
  assign o_is_jalr_issue           = is_jalr_issue;
  assign o_branch_taken_resolved   = branch_taken_resolved;
  assign o_branch_target_resolved  = branch_target_resolved;

`ifndef SYNTHESIS
  // Simulation checks for the late qualification. The reference is the plain
  // priority form, with the qualification first.
  logic branch_mispredicted_reference;
  always_comb begin
    if (!is_branch_update_issue) begin
      branch_mispredicted_reference = 1'b0;
    end else if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      branch_mispredicted_reference = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 (rs_issue_int.is_jalr ?
                      (branch_target_resolved != rs_issue_int.predicted_target) :
                      !rs_issue_int.predicted_target_ok)) begin
      branch_mispredicted_reference = 1'b1;
    end else begin
      branch_mispredicted_reference = 1'b0;
    end
  end

  // For a qualified direct branch predicted taken, the precomputed target
  // check must match the full comparison against the tag-indexed prediction.
  always_comb begin
    if (!$isunknown(
            {
              is_branch_update_issue,
              rs_issue_int.is_jalr,
              rs_issue_int.predicted_taken,
              rs_issue_int.predicted_target_ok,
              rs_issue_int.imm,
              rs_issue_int.predicted_target
            }
        )) begin
      p_direct_target_check_matches_side_ram :
      assert (!(is_branch_update_issue && !rs_issue_int.is_jalr && rs_issue_int.predicted_taken) ||
              (rs_issue_int.predicted_target_ok ==
               (rs_issue_int.imm == rs_issue_int.predicted_target)));
    end
  end

  // JALR has no independent copy of predicted_target: a target mismatch is
  // an ordinary misprediction. Check the side-RAM row using its link_addr
  // against the packet imm and its pc plus instruction length. These checks
  // apply regardless of predicted_taken. The reservation station separately
  // checks all three side-RAM words against the dispatched packet.
  always_comb begin
    if (!$isunknown(
            {
              is_branch_update_issue,
              rs_issue_int.is_jalr,
              rs_issue_int.is_compressed,
              rs_issue_int.imm,
              rs_issue_int.pc,
              rs_issue_int.link_addr
            }
        )) begin
      p_jalr_link_matches_side_ram :
      assert (!(is_branch_update_issue && rs_issue_int.is_jalr) ||
              (rs_issue_int.link_addr == rs_issue_int.imm));
      p_jalr_link_follows_row_pc :
      assert (!(is_branch_update_issue && rs_issue_int.is_jalr) ||
              (rs_issue_int.link_addr ==
               (rs_issue_int.pc + (rs_issue_int.is_compressed ?
                                       riscv_pkg::PcIncrementCompressed :
                                       riscv_pkg::PcIncrement32bit))));
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
