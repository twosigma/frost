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
 * Branch resolution unit (purely combinational).
 *
 * Conditional branches and JALRs issue from INT_RS and resolve here, in a
 * wrapper around branch_jump_unit; JAL resolves when the ROB allocates it. The
 * output is the reorder_buffer_branch_update_t the ROB uses to decide
 * misprediction. Conditional branches have no other completion path: the INT
 * RS predecodes their CDB writeback hint clear, so int_alu_shim never
 * completes them.
 *
 * The update is suppressed for entries the pipeline is discarding: any valid
 * entry during a trap, xRET, or FENCE-class flush, the mispredicting branch
 * and anything younger during an early recovery, and any valid entry during
 * a commit-time recovery. The issuing branch's checkpoint owner is checked as
 * well, so a branch holding a stale or reused checkpoint id produces no
 * update.
 *
 * Condition and target resolve from the registered class bits in parallel
 * with that qualification, which gates only update validity and the
 * misprediction flag. A conditional branch's precomputed target arrives in
 * the issue immediate, and its target check is the one-bit compare ID made
 * against the prediction; only JALR compares its computed target against
 * predicted_target, which the INT station reads from its tag-indexed side
 * RAM behind the stage2 tag. The checkpoint-owner and age predicates read
 * i_branch_predicate_tag, a same-edge twin of the INT stage2 tag. The branch
 * update and the ROB path keep the architectural issue tag.
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

  // --- Port aliases: the body uses these unprefixed names.
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
  // TIMING: compare, then mux. Computing each checkpoint's live bit first
  // lets all eight in_use and owner-tag compares run in parallel straight out
  // of the checkpoint registers, leaving only a 1-bit 8:1 select behind
  // checkpoint_id instead of a 5-bit 8:1 mux followed by a compare. For every
  // checkpoint_id the selected bit equals the mux-then-compare expression.
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
    // The ROB's head-commit misprediction candidate
    // (o_head_commit_misprediction_candidate, an unconsumed observation
    // output) does not suppress branch resolution: routing it through
    // suppress_branch_resolution → is_branch_issue → branch comparison
    // (CARRY8) → branch_update → commit_en would make a 16-level
    // combinational chain. Leaving it out is safe because:
    //   (a) a resolving branch can never be the committing head.  Branches have
    //       no CDB done-bypass (reorder_buffer head_cdb_bypass excludes
    //       head_is_branch), so a branch's done bit is registered and it can
    //       only be head_ready the cycle after its branch_update.
    //   (b) resolution writes to entries that will be flushed are harmless:
    //       flush-after-head invalidates them next cycle, allocation re-inits
    //       the branch bits, and the unresolved-branch bit such a write
    //       clears in ooo_pipeline_control belongs to a flushed branch.
    //   (c) an early_mispredict_fire coinciding with a head-mispredict commit
    //       is dropped one cycle later.  early_mispredict_active gates on
    //       !mispredict_recovery_pending (early_misprediction_recovery.sv),
    //       which registers the commit-time recovery launch, so the early
    //       pulse dies before any redirect, RAT restore, rob_early_recovered
    //       write or backend flush.
  end

  assign suppress_branch_resolution = branch_issue_is_flushed;

  // TIMING: the branch class and the branch_taken_op_e select are pre-decoded
  // at dispatch and registered through the RS payload and stage2 register
  // (rs_issue_t.is_branch_class/is_jal/is_jalr/branch_op). Consuming the
  // registered bits here keeps the instr_op_e equality trees out of the
  // stage2_op -> branch_mispredicted -> early-mispredict-capture cycle.
  // reservation_station's rs_is_branch_class_op and rs_branch_op_of compute
  // them from the operation.
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
      // matters only where the result becomes an architectural branch_update;
      // putting it on these selects would serialize every condition and
      // target cone behind the checkpoint-owner compare.  For a valid update
      // JAL is already excluded and the qualified JALR bit equals the raw
      // bit, so the update is bit-identical to one resolved from the
      // qualified bits.
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

  // Misprediction detection.  The ROB trusts this flag.
  // Preserve the raw mismatch boundary so synthesis cannot duplicate the
  // checkpoint-qualified final AND back into the target comparator cone.
  (* keep = "true" *) logic prediction_wrong;
  always_comb begin
    if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      // Direction misprediction (taken vs not-taken)
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

  // Keep the raw prediction comparison independent of checkpoint state, then
  // apply the issue qualification once at the observed flag. This equals the
  // priority form with a leading `if (!is_branch_update_issue)`
  // (Q ? prediction_wrong : 1'b0), which the simulation reference below keeps.
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
    // Keep the architectural tag on the update/ROB path.  The physical twin
    // above drives the qualification predicates only.
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

  // The one-bit direct-branch target check must agree with the full compare
  // against the side-RAM prediction for every qualified direct-branch update
  // that was predicted taken: this ties the station's tag-indexed read to the
  // packet it serves.
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

  // The JALR side of the same check.  JALR's predicted_target is the only
  // word of the side-RAM row this module uses, and the packet carries no
  // independent copy of it, so it cannot be compared the way the direct
  // branch's target is: a JALR whose prediction differs from its computed
  // target is an ordinary misprediction, not a fault.  The packet does carry
  // the link address twice (in imm, from the per-entry payload, and in
  // link_addr, from the same row as predicted_target), and the row's own pc
  // sits a fixed instruction length below it.  Check both, so a JALR that
  // resolves against a row whose words disagree with the packet beside them
  // is caught here at the consumer.  Neither check pins predicted_target's
  // value; reservation_station's simulation check does, comparing every
  // stage-2 read with a copy of the packet's own three words.  No
  // predicted_taken qualifier: both link copies are valid for every JALR,
  // predicted or not.
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
