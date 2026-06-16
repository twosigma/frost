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
 * this two-phase FSM starts recovery immediately instead of waiting for the
 * branch to reach the ROB head, cutting the penalty from ~15 to ~2 cycles:
 *   cycle N   : capture the mispredicting branch's redirect/BTB/checkpoint data;
 *   cycle N+1 : early_mispredict_active -> front-end redirect + RAT restore;
 *   cycle N+2 : early_backend_recovery_pending -> backend partial flush + hold.
 * JALR mispredictions stay on the commit-time path. One recovery at a time.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Early Misprediction Recovery" section, with the parent's signals
 * presented as ports and aliased back to their original names.
 */

module early_misprediction_recovery #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,
    input riscv_pkg::rs_issue_t i_rs_issue_int,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,
    input logic i_is_jalr_issue,
    input logic i_branch_taken_resolved,
    input logic [XLEN-1:0] i_branch_target_resolved,
    input logic i_fence_i_flush,
    input logic i_mispredict_recovery_pending,
    input logic i_flush_all,
    input logic i_flush_for_trap,
    input logic i_flush_for_mret,
    input logic i_trap_taken_reg,
    input logic i_mret_taken_reg,

    output logic                                        o_early_mispredict_active,
    output logic                                        o_early_backend_recovery_pending,
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

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  riscv_pkg::rs_issue_t rs_issue_int;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic is_jalr_issue;
  logic branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;
  logic fence_i_flush;
  logic mispredict_recovery_pending;
  logic flush_all;
  logic flush_for_trap;
  logic flush_for_mret;
  logic trap_taken_reg;
  logic mret_taken_reg;
  assign branch_update               = i_branch_update;
  assign rs_issue_int                = i_rs_issue_int;
  assign head_tag                    = i_head_tag;
  assign is_jalr_issue               = i_is_jalr_issue;
  assign branch_taken_resolved       = i_branch_taken_resolved;
  assign branch_target_resolved      = i_branch_target_resolved;
  assign fence_i_flush               = i_fence_i_flush;
  assign mispredict_recovery_pending = i_mispredict_recovery_pending;
  assign flush_all                   = i_flush_all;
  assign flush_for_trap              = i_flush_for_trap;
  assign flush_for_mret              = i_flush_for_mret;
  assign trap_taken_reg              = i_trap_taken_reg;
  assign mret_taken_reg              = i_mret_taken_reg;

  (* max_fanout = 32 *) logic early_mispredict_capture;
  logic early_mispredict_fire;
  logic early_mispredict_pending;
  logic early_mispredict_active;
  logic early_backend_recovery_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;

  // Captured data from the mispredicting branch
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic early_mispredict_is_compressed;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;

  // Fire when a conditional-branch misprediction is detected at execute time.
  // JALR remains on the older commit-time recovery path for now.
  logic [riscv_pkg::ReorderBufferTagWidth:0] early_branch_age;
  assign early_branch_age = {1'b0, branch_update.tag} - {1'b0, head_tag};
  assign early_mispredict_capture = branch_update.mispredicted && !early_mispredict_pending &&
                                    !early_backend_recovery_pending;
  assign early_mispredict_fire = early_mispredict_capture &&
                                  rs_issue_int.has_checkpoint && !is_jalr_issue &&
                                  !fence_i_flush && !mispredict_recovery_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) early_mispredict_pending <= 1'b0;
    else early_mispredict_pending <= early_mispredict_fire;
  end

  assign early_mispredict_active = early_mispredict_pending &&
                                   !mispredict_recovery_pending &&
                                   !trap_taken_reg && !mret_taken_reg &&
                                   !fence_i_flush;

  // Delay the high-fanout backend partial flush one cycle behind the fast
  // frontend redirect and RAT restore.
  always_ff @(posedge i_clk) begin
    if (i_rst) early_backend_recovery_pending <= 1'b0;
    else if (flush_for_trap || flush_for_mret || fence_i_flush) begin
      early_backend_recovery_pending <= 1'b0;
    end else begin
      early_backend_recovery_pending <= early_mispredict_active;
    end
  end

  // The backend partial flush already trails the fast redirect by one cycle,
  // so re-register the flush tag locally instead of reusing the N-cycle
  // capture register across the whole Tomasulo flush network.
  always_ff @(posedge i_clk) begin
    if (early_mispredict_active) begin
      early_backend_flush_tag <= early_mispredict_tag;
    end
  end

  // Capture recovery data on the fire cycle
  always_ff @(posedge i_clk) begin
    if (early_mispredict_capture) begin
      early_mispredict_tag <= branch_update.tag;

      // Redirect PC: taken → actual target, not taken → fallthrough (link_addr)
      early_mispredict_redirect_pc <= branch_taken_resolved ?
          branch_target_resolved : rs_issue_int.link_addr;

      // Early recovery only fires for checkpointed conditional branches.
      early_mispredict_checkpoint_id <= rs_issue_int.checkpoint_id;

      // BTB update data
      early_mispredict_pc <= rs_issue_int.pc;
      early_mispredict_branch_target <= branch_target_resolved;
      early_mispredict_branch_taken <= branch_taken_resolved;
      early_mispredict_is_compressed <= (rs_issue_int.link_addr == rs_issue_int.pc + 32'd2);
    end
  end

  // Mark the branch as early-recovered before it can commit. The delayed
  // backend flush uses a separate qualifier so speculative structures can
  // still distinguish early recovery from commit-time flush-after-head.
  logic early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  assign early_recovery_en  = early_mispredict_active;
  assign early_recovery_tag = early_mispredict_tag;

  // Hold dispatch/issue/dequeue while the frontend redirects and the RAT
  // restores.  The following backend phase is a real partial flush
  // (flush_en + early_backend_flush_tag), which already blocks stage1 issue
  // and squashes younger side effects in the RS/FU paths.  Keeping the global
  // hold out of that delayed phase avoids a backend-pending -> INT issue ready
  // -> branch_update -> early-capture timing loop.
  logic early_backend_recovery_hold;
  assign early_backend_recovery_hold = early_mispredict_pending;

  // --- Output wiring.
  assign o_early_mispredict_active = early_mispredict_active;
  assign o_early_backend_recovery_pending = early_backend_recovery_pending;
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

endmodule : early_misprediction_recovery
