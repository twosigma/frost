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
 * Early misprediction recovery.
 *
 * When branch_resolution flags a checkpointed conditional-branch misprediction,
 * this two-phase FSM starts recovery in the cycle after the branch resolves
 * instead of waiting for the branch to reach the ROB head:
 *   cycle N   : capture the mispredicting branch's redirect/BTB/checkpoint data;
 *   cycle N+1 : early_mispredict_active -> front-end redirect + RAT restore,
 *               with dispatch and issue held (early_backend_recovery_hold);
 *   cycle N+2 : early_backend_recovery_pending -> backend partial flush.
 * JALR mispredictions recover at commit. The wide payload registers capture
 * on an issue-local superset of the fire condition, but only the
 * checkpoint-qualified misprediction launches a recovery, and only one
 * recovery runs at a time.
 */

module early_misprediction_recovery #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,
    input riscv_pkg::rs_issue_t i_rs_issue_int,
    input logic i_is_jalr_issue,
    input logic i_branch_taken_resolved,
    input logic [XLEN-1:0] i_branch_target_resolved,
    input logic i_fence_i_flush,
    // Same-cycle copy of the native FENCE.I/SFENCE.VMA pulse, for fanout.
    // Translation-CSR recovery uses i_fence_i_flush only. That shared pulse
    // suppresses fire and cancels pending backend recovery.
    input logic i_active_fence_i_flush,
    input logic i_mispredict_recovery_pending,
    input logic i_flush_all,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_trap_taken_reg,
    input logic i_mret_taken_reg,

    output logic                                        o_early_mispredict_active,
    output logic                                        o_early_mispredict_pending,
    output logic                                        o_early_backend_recovery_pending,
    // Next state of o_early_backend_recovery_pending, for the flush
    // controller's registered flush_en.
    output logic                                        o_early_backend_recovery_pending_next,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_early_backend_flush_tag,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_early_mispredict_tag,
    output logic [                            XLEN-1:0] o_early_mispredict_redirect_pc,
    output logic [    riscv_pkg::CheckpointIdWidth-1:0] o_early_mispredict_checkpoint_id,
    output logic                                        o_early_mispredict_is_compressed,
    output logic [                            XLEN-1:0] o_early_mispredict_pc,
    output logic [                            XLEN-1:0] o_early_mispredict_branch_target,
    output logic                                        o_early_mispredict_branch_taken,
    output logic                                        o_early_recovery_en,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_early_recovery_tag,
    output logic                                        o_early_backend_recovery_hold
);

  // Port aliases.
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  riscv_pkg::rs_issue_t rs_issue_int;
  logic is_jalr_issue;
  logic branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;
  logic fence_i_flush;
  logic active_fence_i_flush;
  logic mispredict_recovery_pending;
  logic flush_all;
  logic flush_for_trap;
  logic flush_for_mret;
  logic trap_taken_reg;
  logic mret_taken_reg;
  assign branch_update               = i_branch_update;
  assign rs_issue_int                = i_rs_issue_int;
  assign is_jalr_issue               = i_is_jalr_issue;
  assign branch_taken_resolved       = i_branch_taken_resolved;
  assign branch_target_resolved      = i_branch_target_resolved;
  assign fence_i_flush               = i_fence_i_flush;
  assign active_fence_i_flush        = i_active_fence_i_flush;
  assign mispredict_recovery_pending = i_mispredict_recovery_pending;
  assign flush_all                   = i_flush_all;
  assign flush_for_trap              = i_flush_for_trap;
  assign flush_for_mret              = i_flush_for_mret;
  assign trap_taken_reg              = i_trap_taken_reg;
  assign mret_taken_reg              = i_mret_taken_reg;

  (* max_fanout = 32 *) logic early_mispredict_capture;
  logic early_mispredict_payload_capture;
  logic early_mispredict_fire;
  // Fanout caps allow replication of recovery controls and tags.
  (* max_fanout = 32 *) logic early_mispredict_pending;
  (* max_fanout = 64 *) logic early_mispredict_active;
  (* max_fanout = 48 *) logic early_backend_recovery_pending;
  (* max_fanout = 48 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;

  // Captured data from the mispredicting branch
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic early_mispredict_is_compressed;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;

  // Only conditional branches recover at execute; JALR recovers at commit.
  // For non-JALR updates, the mux below equals the direction-or-target
  // mismatch in branch_update.mispredicted. The later fire gate excludes JALR.
  logic branch_mispredicted_direct;
  assign branch_mispredicted_direct = branch_update.valid && (branch_taken_resolved ?
      !(rs_issue_int.predicted_taken && rs_issue_int.predicted_target_ok) :
      rs_issue_int.predicted_taken);
  assign early_mispredict_capture = branch_mispredicted_direct && !early_mispredict_pending &&
                                    !early_backend_recovery_pending;
  // Capture checkpointed conditional-branch payloads while recovery can
  // launch. This includes every fire on the same edge. Extra captures are
  // inert because only early_mispredict_pending exposes the payload.
  assign early_mispredict_payload_capture =
      rs_issue_int.valid && rs_issue_int.is_branch_class && rs_issue_int.has_checkpoint &&
      !rs_issue_int.is_jal && !rs_issue_int.is_jalr &&
      !early_mispredict_pending && !early_backend_recovery_pending;
  assign early_mispredict_fire = early_mispredict_capture &&
                                  rs_issue_int.has_checkpoint && !rs_issue_int.is_jalr &&
                                  !fence_i_flush && !mispredict_recovery_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) early_mispredict_pending <= 1'b0;
    else early_mispredict_pending <= early_mispredict_fire;
  end

  assign early_mispredict_active = early_mispredict_pending &&
                                   !mispredict_recovery_pending &&
                                   !trap_taken_reg && !mret_taken_reg &&
                                   !active_fence_i_flush;

  // The backend partial flush follows the frontend redirect and RAT restore
  // by one cycle.
  logic early_backend_recovery_pending_next;
  always_comb begin
    if (i_rst) early_backend_recovery_pending_next = 1'b0;
    else if (flush_for_trap || flush_for_mret || fence_i_flush)
      early_backend_recovery_pending_next = 1'b0;
    else early_backend_recovery_pending_next = early_mispredict_active;
  end
  always_ff @(posedge i_clk) begin
    early_backend_recovery_pending <= early_backend_recovery_pending_next;
  end

  // Register the tag with the delayed backend partial flush.
  always_ff @(posedge i_clk) begin
    if (early_mispredict_active) begin
      early_backend_flush_tag <= early_mispredict_tag;
    end
  end

  // Capture recovery data on the issue-local superset of the fire cycle.  The
  // pending bit above is the only launch.
  always_ff @(posedge i_clk) begin
    if (early_mispredict_payload_capture) begin
      early_mispredict_tag <= branch_update.tag;

      // Redirect to the taken target or fallthrough (link_addr). The INT
      // station reads pc and link_addr from its tag-indexed side RAM.
      early_mispredict_redirect_pc <= branch_taken_resolved ?
          branch_target_resolved : rs_issue_int.link_addr;

      early_mispredict_checkpoint_id <= rs_issue_int.checkpoint_id;

      // BTB update data
      early_mispredict_pc <= rs_issue_int.pc;
      early_mispredict_branch_target <= branch_target_resolved;
      early_mispredict_branch_taken <= branch_taken_resolved;
      early_mispredict_is_compressed <= rs_issue_int.is_compressed;
    end
  end

  // Mark the branch as early-recovered before it can commit. The delayed
  // backend flush uses a separate qualifier so speculative structures can
  // still distinguish early recovery from commit-time flush-after-head.
  logic early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  assign early_recovery_en  = early_mispredict_active;
  assign early_recovery_tag = early_mispredict_tag;

  // Hold dispatch, issue, and dequeue during redirect and RAT restore. The
  // following backend phase blocks stage1 issue and squashes younger RS/FU
  // effects through flush_en and early_backend_flush_tag.
  logic early_backend_recovery_hold;
  assign early_backend_recovery_hold = early_mispredict_pending;

  // --- Output wiring.
  assign o_early_mispredict_active = early_mispredict_active;
  assign o_early_mispredict_pending = early_mispredict_pending;
  assign o_early_backend_recovery_pending = early_backend_recovery_pending;
  assign o_early_backend_recovery_pending_next = early_backend_recovery_pending_next;
  assign o_early_backend_flush_tag = early_backend_flush_tag;
  assign o_early_mispredict_tag = early_mispredict_tag;
  assign o_early_mispredict_redirect_pc = early_mispredict_redirect_pc;
  assign o_early_mispredict_checkpoint_id = early_mispredict_checkpoint_id;
  assign o_early_mispredict_is_compressed = early_mispredict_is_compressed;
  assign o_early_mispredict_pc = early_mispredict_pc;
  assign o_early_mispredict_branch_target = early_mispredict_branch_target;
  assign o_early_mispredict_branch_taken = early_mispredict_branch_taken;
  assign o_early_recovery_en = early_recovery_en;
  assign o_early_recovery_tag = early_recovery_tag;
  assign o_early_backend_recovery_hold = early_backend_recovery_hold;

`ifndef SYNTHESIS
  // Compare against the full misprediction flag and qualified JALR bit.
  // A misprediction requires a valid branch update, where the raw and
  // qualified JALR bits agree.
  logic early_mispredict_fire_reference;
  assign early_mispredict_fire_reference = branch_update.mispredicted &&
                                            !early_mispredict_pending &&
                                            !early_backend_recovery_pending &&
                                            rs_issue_int.has_checkpoint && !is_jalr_issue &&
                                            !fence_i_flush && !mispredict_recovery_pending;

  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown(
            {branch_update.mispredicted, is_jalr_issue,
                              rs_issue_int.is_jalr, early_mispredict_fire,
                              early_mispredict_fire_reference,
                              branch_mispredicted_direct,
                              early_mispredict_payload_capture}
        )) begin
      p_qualified_jalr_matches_raw_on_mispredict :
      assert (!branch_update.mispredicted || is_jalr_issue == rs_issue_int.is_jalr);
      p_raw_jalr_fire_substitution_exact :
      assert (early_mispredict_fire == early_mispredict_fire_reference);
      // The conditional-branch form equals the flag on every non-JALR issue.
      p_branch_mispredicted_direct_exact :
      assert (rs_issue_int.is_jalr || (branch_mispredicted_direct == branch_update.mispredicted));
      p_fire_implies_payload_capture :
      assert (!early_mispredict_fire || early_mispredict_payload_capture);
    end
  end
`endif

endmodule : early_misprediction_recovery
