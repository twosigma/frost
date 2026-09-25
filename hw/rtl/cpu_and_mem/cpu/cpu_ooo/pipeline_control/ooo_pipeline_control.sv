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
 * Front-end pipeline control for the out-of-order core.
 *
 * The back end stalls the pipeline almost entirely at dispatch, so this block
 * combines the front-end stall and serialization sources and the registered
 * trap and xRET state into the pipeline_ctrl_t that IF, PD, and ID consume.
 * It holds:
 *   - the CSR in-flight state (csr_in_flight, serializing_alloc_fire) and
 *     the per-checkpoint unresolved-branch bits;
 *   - the CSR and control-flow serialization stalls and their registered
 *     stall and replay signals (stall_q, id_stall_q, replay_*);
 *   - the post-flush BRAM holdoff;
 *   - the registered trap and xRET pulses and trap target;
 *   - the prediction-disable gate and the pipeline_ctrl assembly.
 */

module ooo_pipeline_control #(
    parameter bit QUEUED_FRONTEND = 1'b0,
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::reorder_buffer_alloc_req_t i_rob_alloc_req,
    // Slot 2's allocation request. With slot 1's, it tells whether the
    // checkpoint saved this cycle belongs to a conditional branch or JALR.
    input riscv_pkg::reorder_buffer_alloc_req_t i_rob_alloc_req_2,
    // Checkpoint save from dispatch (either slot) and its checkpoint id.
    input logic i_rob_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_rob_checkpoint_id,
    // Checkpoints held by in-flight branches (cpu_ooo's checkpoint_in_use).
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_in_use,
    input logic i_csr_commit_fire,
    input riscv_pkg::reorder_buffer_commit_t i_rob_commit,
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,
    input logic i_dispatch_stall,
    input logic i_frontend_resource_stall,
    input logic i_csr_wb_pending,
    // A branch resolved as correctly predicted, and its checkpoint id.
    input logic i_branch_resolved_correct,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_branch_resolved_checkpoint_id,
    input logic i_front_end_indirect_control_flow_pending,
    input logic i_disable_branch_prediction,
    input logic i_flush_pipeline,
    // High while the translation of the fetch PC is not yet visible: the Sv39
    // bubble after the fetch PC moves, a second bubble on a page crossing, or
    // an ITLB miss. It is an ordinary front-end stall: IF captures the
    // presented bundle and replays it, and the fetch provider keeps its
    // outstanding request. A flush overrides it like the other stalls, so
    // trap, xRET, and misprediction redirects land.
    input logic i_fetch_pa_hold,

    output riscv_pkg::pipeline_ctrl_t o_pipeline_ctrl,
    output logic o_serializing_alloc_fire,
    output logic o_csr_in_flight,
    output logic o_disable_branch_prediction_ooo,
    output logic o_front_end_cf_serialize_stall,
    output logic o_stall_q,
    output logic o_id_stall_q,
    output logic o_replay_after_dispatch_stall_q,
    output logic o_replay_after_serialize_stall_q,
    output logic [1:0] o_post_flush_holdoff_q,
    output logic o_trap_taken_reg,
    output logic o_mret_taken_reg,
    output logic [XLEN-1:0] o_trap_target_reg
);

  // --- Port aliases.
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req;
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2;
  logic rob_checkpoint_valid;
  logic [riscv_pkg::CheckpointIdWidth-1:0] rob_checkpoint_id;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;
  logic csr_commit_fire;
  riscv_pkg::reorder_buffer_commit_t rob_commit;
  logic trap_taken;
  logic mret_taken;
  logic [XLEN-1:0] trap_target;
  logic dispatch_stall;
  logic csr_wb_pending;
  logic branch_resolved_correct;
  logic [riscv_pkg::CheckpointIdWidth-1:0] branch_resolved_checkpoint_id;
  logic front_end_indirect_control_flow_pending;
  logic flush_pipeline;
  assign rob_alloc_req                           = i_rob_alloc_req;
  assign rob_alloc_req_2                         = i_rob_alloc_req_2;
  assign rob_checkpoint_valid                    = i_rob_checkpoint_valid;
  assign rob_checkpoint_id                       = i_rob_checkpoint_id;
  assign checkpoint_in_use                       = i_checkpoint_in_use;
  assign csr_commit_fire                         = i_csr_commit_fire;
  assign rob_commit                              = i_rob_commit;
  assign trap_taken                              = i_trap_taken;
  assign mret_taken                              = i_mret_taken;
  assign trap_target                             = i_trap_target;
  assign dispatch_stall                          = i_dispatch_stall;
  assign csr_wb_pending                          = i_csr_wb_pending;
  assign branch_resolved_correct                 = i_branch_resolved_correct;
  assign branch_resolved_checkpoint_id           = i_branch_resolved_checkpoint_id;
  assign front_end_indirect_control_flow_pending = i_front_end_indirect_control_flow_pending;
  assign flush_pipeline                          = i_flush_pipeline;

  // Signals produced here (also read internally); wired to o_* at the end.
  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  (* max_fanout = 32 *) logic frontend_stall;
  logic csr_in_flight;
  logic disable_branch_prediction_ooo;
  (* max_fanout = 32 *) logic serializing_alloc_fire;

  // CSR results are only architecturally available at commit, so hold the
  // front-end after dispatching a CSR until it completes.  serializing_alloc_fire
  // is registered to break the dispatch->stall->IF->dispatch UNOPTFLAT loop.
  logic serializing_alloc_fire_comb;
  assign serializing_alloc_fire_comb = rob_alloc_req.alloc_valid && rob_alloc_req.is_csr;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) serializing_alloc_fire <= 1'b0;
    else serializing_alloc_fire <= serializing_alloc_fire_comb;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) csr_in_flight <= 1'b0;
    else if (serializing_alloc_fire_comb) csr_in_flight <= 1'b1;
    else if (csr_commit_fire) csr_in_flight <= 1'b0;
  end

  // Unresolved branches, one bit per checkpoint. Every branch or jump saves a
  // checkpoint when it dispatches, from either slot (at most one per bundle),
  // and holds it until it commits or is flushed. The save marks the
  // checkpoint unresolved for a conditional branch or JALR (a JAL resolves at
  // allocation), and a correct resolution clears it. A mispredicted branch
  // keeps its bit until its recovery frees the checkpoint (a JALR recovers
  // only at commit), since everything younger is on the wrong path. Masking
  // with checkpoint_in_use drops flushed branches, so an early recovery keeps
  // the older unresolved branches it does not flush. The mask trails a
  // partial flush by a few cycles, while the flushed front end refills.
  // TIMING: the late correct-resolution pulse only clears a bit, so no
  // counter arithmetic sits behind it; the checkpoint ids and the save come
  // from dispatch and the issue payload.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_unresolved_q;
  logic checkpoint_save_unresolved;
  logic branch_unresolved;
  // A bundle holds at most one branch, so slot 1's class picks the saver.
  assign checkpoint_save_unresolved =
      rob_alloc_req.is_branch ? !rob_alloc_req.is_jal : !rob_alloc_req_2.is_jal;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      checkpoint_unresolved_q <= '0;
    end else begin
      if (branch_resolved_correct) checkpoint_unresolved_q[branch_resolved_checkpoint_id] <= 1'b0;
      if (rob_checkpoint_valid)
        checkpoint_unresolved_q[rob_checkpoint_id] <= checkpoint_save_unresolved;
    end
  end
  assign branch_unresolved = |(checkpoint_unresolved_q & checkpoint_in_use);

`ifndef SYNTHESIS
  // The bits rely on a save taking a free checkpoint and a resolution
  // naming a live one.
  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown(
            {rob_checkpoint_valid, branch_resolved_correct, checkpoint_in_use}
        )) begin
      p_unresolved_save_takes_free_checkpoint :
      assert (!rob_checkpoint_valid || !checkpoint_in_use[rob_checkpoint_id]);
      p_unresolved_clear_names_live_checkpoint :
      assert (!branch_resolved_correct || checkpoint_in_use[branch_resolved_checkpoint_id]);
    end
  end
`endif

  assign disable_branch_prediction_ooo = i_disable_branch_prediction ||
                                         csr_in_flight ||
                                         serializing_alloc_fire;

  // Control-flow serialization. While a conditional branch or JALR is
  // unresolved, hold IF, PD, and ID once an unpredicted indirect jump shows up
  // in slot 1 of IF (under a stall), PD, or ID, or in either slot of a bundle
  // in the decoded queue. Fetch runs on sequentially past such a jump: a JALR
  // fetched without a prediction always resolves as mispredicted and recovers
  // when it commits. The hold limits that wrong-path fetch. It is a
  // performance measure: recovery squashes everything younger than a
  // mispredicted branch or jump, so architectural state does not depend on it.
  // The stall is registered and does not gate queued dispatch. ID keeps
  // showing a held jump after dispatch takes it, so the jump's own unresolved
  // bit can keep the hold until the jump recovers.
  logic front_end_cf_serialize_stall_comb;
  logic front_end_cf_serialize_stall  /* verilator isolate_assignments */;
  assign front_end_cf_serialize_stall_comb =
      branch_unresolved && front_end_indirect_control_flow_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) front_end_cf_serialize_stall <= 1'b0;
    else front_end_cf_serialize_stall <= front_end_cf_serialize_stall_comb;
  end

  // Registered stall for IF stage stall-capture registers.
  logic stall_q;
  // TIMING: the registered ID stall drives the dispatch and allocation clock
  // enables across the design plus the width-funnel observer replay bits.
  // max_fanout bounds its replicas so the split is deterministic rather than
  // left to Vivado's replication heuristic, as on other 1-bit control nets.
  (* max_fanout = 64 *)logic id_stall_q;
  logic replay_after_dispatch_stall_q;
  logic replay_after_serialize_stall_q;
  logic replay_after_serialize_stall_next;
  // Normally a CSR allocation advances ID before csr_in_flight raises, so the
  // image held through serialization is the younger instruction that must be
  // replayed on release. An independent front-end stall can already be high
  // on the allocation cycle, most often the Sv39 translation bubble
  // (i_fetch_pa_hold), and ID then still holds the CSR itself. Remember that
  // case so release gives ID one advance-only cycle instead of allocating the
  // same CSR twice.
  logic csr_alloc_held_id_q;
  assign frontend_stall =
      ((QUEUED_FRONTEND ? i_frontend_resource_stall : dispatch_stall) ||
       csr_in_flight || csr_wb_pending || serializing_alloc_fire ||
       front_end_cf_serialize_stall || i_fetch_pa_hold) && !flush_pipeline;
  always_ff @(posedge i_clk) begin
    if (i_rst) stall_q <= 1'b0;
    else stall_q <= frontend_stall;
  end

  // Keep dispatch-valid replay gating off the high-fanout IF stall-capture flop.
  // A successful CSR allocation is the one cycle in which the ordinary
  // frontend_stall register chain has not caught up yet: csr_in_flight and
  // serializing_alloc_fire rise only after the allocating edge. Capture that
  // successful fire directly into this local register so the held ID image is
  // suppressed immediately without carrying csr_in_flight through every
  // dispatch/RS/LSQ allocation enable. Do not put the combinational fire into
  // frontend_stall itself; that would create the dispatch->stall->IF->dispatch
  // combinational loop that registering serializing_alloc_fire avoids. If
  // allocation and release coincide, the allocation wins: a newly allocated
  // CSR must not lose its first-cycle dispatch shield.
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) id_stall_q <= 1'b0;
    else if (serializing_alloc_fire_comb) id_stall_q <= 1'b1;
    else if (replay_after_serialize_stall_next && !csr_alloc_held_id_q) id_stall_q <= 1'b0;
    else id_stall_q <= frontend_stall;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_dispatch_stall_q <= 1'b0;
    else replay_after_dispatch_stall_q <= dispatch_stall && !flush_pipeline;
  end

  // Serialization release: the CSR's delayed register-writeback cycle
  // (csr_wb_pending), or its commit cycle if it writes no register.
  assign replay_after_serialize_stall_next =
      (csr_wb_pending || (csr_commit_fire && !rob_commit.dest_valid)) && !flush_pipeline;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) begin
      csr_alloc_held_id_q <= 1'b0;
    end else if (serializing_alloc_fire_comb && frontend_stall) begin
      csr_alloc_held_id_q <= 1'b1;
    end else if (replay_after_serialize_stall_next) begin
      csr_alloc_held_id_q <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_serialize_stall_q <= 1'b0;
    else replay_after_serialize_stall_q <= replay_after_serialize_stall_next;
  end

`ifndef SYNTHESIS
  // Reference ID-stall register without the local CSR-allocation term, for
  // simulation and formal checks. id_stall_q may differ from it only by
  // including csr_in_flight; both apply the held-CSR release exception.
  logic id_stall_legacy_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) id_stall_legacy_q <= 1'b0;
    else if (replay_after_serialize_stall_next && !csr_alloc_held_id_q) id_stall_legacy_q <= 1'b0;
    else id_stall_legacy_q <= frontend_stall;
  end

  // id_stall_q stands in for a live !csr_in_flight term on ID validity. Check
  // the state relation, and that the ID-valid gate equals the reference gate
  // ANDed with !csr_in_flight, through allocation, held-ID release, ordinary
  // replay, and release collisions.
  always_ff @(posedge i_clk) begin
    if (!i_rst && !flush_pipeline && !$isunknown(
            {serializing_alloc_fire_comb, dispatch_stall, csr_in_flight,
             id_stall_q, id_stall_legacy_q, replay_after_dispatch_stall_q}
        )) begin
      p_csr_alloc_is_successful_dispatch : assert (!serializing_alloc_fire_comb || !dispatch_stall);
      p_csr_in_flight_owns_id_stall :
      assert (!csr_in_flight || (id_stall_q && !replay_after_dispatch_stall_q));
      p_id_stall_matches_legacy_owner : assert (id_stall_q == (id_stall_legacy_q || csr_in_flight));
      p_id_valid_gate_matches_legacy :
      assert ((!id_stall_q || replay_after_dispatch_stall_q) ==
              (!csr_in_flight &&
               (!id_stall_legacy_q || replay_after_dispatch_stall_q)));
    end
  end

`ifndef FORMAL
  // A CSR allocated while ID was independently held must get one release
  // cycle in which ID advances but dispatch remains invalid; otherwise a
  // change to id_stall_q's priority could dispatch the CSR twice. Queued
  // dispatch removes a CSR immediately, independently of ID advance, and its
  // consumed-image guard covers this case instead.
  if (!QUEUED_FRONTEND) begin : gen_direct_csr_release
    p_held_csr_release_is_advance_only :
    assert property (@(posedge i_clk) disable iff (i_rst || flush_pipeline)
      (replay_after_serialize_stall_next && csr_alloc_held_id_q)
      |=> (id_stall_q && !serializing_alloc_fire_comb));
  end
`endif
`endif

  // Post-flush holdoff: BRAM has 1-cycle read latency, so i_instr is stale for
  // one cycle after a flush/redirect.
  logic [1:0] post_flush_holdoff_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) post_flush_holdoff_q <= '0;
    else if (!pipeline_ctrl.stall)
      if (flush_pipeline) post_flush_holdoff_q <= 2'd1;
      else if (post_flush_holdoff_q != 2'd0) post_flush_holdoff_q <= post_flush_holdoff_q - 2'd1;
  end

  // Delay the trap and xRET (mret_taken) recovery pulses seen by IF and the
  // back end by one cycle. trap_taken_reg and mret_taken_reg both fan out to
  // the same redirect and flush selects across IF and the recovery and flush
  // units, so both carry a fanout cap and synthesis replicates them instead of
  // routing one copy everywhere.
  (* max_fanout = 32 *) logic trap_taken_reg;
  (* max_fanout = 32 *) logic mret_taken_reg;
  logic [XLEN-1:0] trap_target_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      trap_taken_reg <= 1'b0;
      mret_taken_reg <= 1'b0;
    end else begin
      trap_taken_reg <= trap_taken;
      mret_taken_reg <= mret_taken;
    end
  end

  always_ff @(posedge i_clk) begin
    if (trap_taken || mret_taken) trap_target_reg <= trap_target;
  end

  always_comb begin
    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_rst;
    pipeline_ctrl.stall = frontend_stall;
    pipeline_ctrl.stall_registered = stall_q;
    pipeline_ctrl.stall_for_trap_check = dispatch_stall;
    pipeline_ctrl.flush = flush_pipeline;
    pipeline_ctrl.trap_taken_registered = trap_taken_reg;
    pipeline_ctrl.mret_taken_registered = mret_taken_reg;
  end

  // --- Output wiring.
  assign o_pipeline_ctrl                  = pipeline_ctrl;
  assign o_serializing_alloc_fire         = serializing_alloc_fire;
  assign o_csr_in_flight                  = csr_in_flight;
  assign o_disable_branch_prediction_ooo  = disable_branch_prediction_ooo;
  assign o_front_end_cf_serialize_stall   = front_end_cf_serialize_stall;
  assign o_stall_q                        = stall_q;
  assign o_id_stall_q                     = id_stall_q;
  assign o_replay_after_dispatch_stall_q  = replay_after_dispatch_stall_q;
  assign o_replay_after_serialize_stall_q = replay_after_serialize_stall_q;
  assign o_post_flush_holdoff_q           = post_flush_holdoff_q;
  assign o_trap_taken_reg                 = trap_taken_reg;
  assign o_mret_taken_reg                 = mret_taken_reg;
  assign o_trap_target_reg                = trap_target_reg;

endmodule : ooo_pipeline_control
