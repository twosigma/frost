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
 * if_stage_stage2 -- the stage-2 front end (PARCEL_QUEUE_DESIGN.md).  Wires
 * the fill engine + parcel queue + consume engine + consume-side RAS together
 * with the BTB / direction predictor, replacing the pending-prediction /
 * aligner / c_ext-buffer / stall-replay machinery of the original if_stage.
 *
 * DATAFLOW: the fill engine walks the served fetch windows into pq_entry_t
 * bundles (with prediction metadata bound at enqueue); the parcel queue holds
 * them (FWFT); the consume engine forms the two IF->PD packets and the dequeue
 * count; the consume-side RAS drives the slot-1 ras_* fields and the return
 * redirect.
 *
 * PROVIDER SEAM (design 7.1): `o_pc` is the fill ask; `o_core_redirect` pulses
 * on every resteer; `o_fetch_backpressure` is queue-full.  The window arrives on
 * i_instr / i_served_addr / i_instr_valid and is tag-checked in the fill engine.
 *
 * This is the rewire artifact; the atomic swap (cpu_ooo instantiating this in
 * place of if_stage, plus the fetch_provider seam changes) is a separate step,
 * so the original if_stage stays intact for now.
 */
module if_stage_stage2 #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,

    // ---- Provider window in ----
    input logic [63:0] i_instr,
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    input logic i_instr_bank_sel_r,  // stage-2 self-aligned: unused (kept for contract)
    input logic [XLEN-1:0] i_served_addr,
    input logic i_instr_valid,

    // ---- Pipeline / trap / flush control ----
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    input logic i_frontend_state_flush,
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,

    // ---- Branch-prediction control / training ----
    input logic i_disable_branch_prediction,
    input logic i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic i_dir_update_taken,

    // ---- PD redirect ----
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,

    // ---- Provider seam out ----
    output logic [XLEN-1:0] o_pc,
    output logic o_core_redirect,
    output logic o_fetch_backpressure,

    // ---- IF->PD packets ----
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd_2
);

  logic rst;
  assign rst = i_pipeline_ctrl.reset;

  // ===========================================================================
  // Fill engine <-> BTB / direction predictor (fill-side lookups)
  // ===========================================================================
  logic [XLEN-1:1] fill_lookup_pc, fill_lookup_pc_2;
  logic [XLEN-1:1] fill_ask_pc;

  // Slot-1 BTB lookup at the ask address; slot-2 at the walk address.
  logic btb_hit_1, btb_taken_1, btb_compressed_1;
  logic [XLEN-1:0] btb_target_1;
  logic btb_hit_2, btb_taken_2, btb_compressed_2;
  logic [XLEN-1:0] btb_target_2;
  branch_predictor #(
      .XLEN(XLEN)
  ) u_btb (
      .i_clk,
      .i_rst(rst),
      .i_pc({fill_lookup_pc, 1'b0}),
      .o_btb_hit(btb_hit_1),
      .o_predicted_taken(btb_taken_1),
      .o_predicted_target(btb_target_1),
      .o_btb_compressed(btb_compressed_1),
      .o_btb_requires_pc_reg_handoff(),
      .i_pc_2({fill_lookup_pc_2, 1'b0}),
      .o_btb_hit_2(btb_hit_2),
      .o_predicted_taken_2(btb_taken_2),
      .o_predicted_target_2(btb_target_2),
      .o_btb_compressed_2(btb_compressed_2),
      .o_btb_requires_pc_reg_handoff_2(),
      .i_update(i_from_ex_comb.btb_update),
      .i_update_pc(i_from_ex_comb.btb_update_pc),
      .i_update_target(i_from_ex_comb.btb_update_target),
      .i_update_taken(i_from_ex_comb.btb_update_taken),
      .i_update_compressed(i_from_ex_comb.btb_update_compressed),
      .i_update_requires_pc_reg_handoff(i_from_ex_comb.btb_update_requires_pc_reg_handoff)
  );

  // Direction predictor: slot-1 lookup at the ask; slot-2 index is the walk-pc
  // hash (as today's bpc), and slot-2 dir_taken is unused (packet holds it 0).
  logic                               dir_taken_1;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_idx_1;
  direction_predictor #(
      .XLEN(XLEN)
  ) u_dir (
      .i_clk,
      .i_rst(rst),
      .i_pc({fill_lookup_pc, 1'b0}),
      .o_taken(dir_taken_1),
      .o_pred_idx(dir_idx_1),
      .i_update_valid(i_dir_update_valid),
      .i_update_idx(i_dir_update_idx),
      .i_update_taken(i_dir_update_taken)
  );

  // Prediction gates: global disable + halfword gate (a 32-bit op at a halfword
  // PC is predicted only when the BTB entry is compressed).
  logic pred_en;
  assign pred_en = !i_disable_branch_prediction;
  logic gate_1, gate_2;
  assign gate_1 = pred_en && (!fill_lookup_pc[1] || btb_compressed_1);
  assign gate_2 = pred_en && (!fill_lookup_pc_2[1] || btb_compressed_2);

  // ===========================================================================
  // Redirect matrix (design 2.5): reset > trap/MRET > FENCE.I > backend branch
  //   > PD redirect > RAS return.  Only the RAS return is a partial flush.
  // ===========================================================================
  logic            ras_redirect_valid;
  logic [XLEN-1:1] ras_redirect_target;

  logic trap_redirect, higher_than_ras, redirect_valid, redirect_partial;
  logic [XLEN-1:0] redirect_target;
  assign trap_redirect = i_trap_ctrl.trap_taken || i_trap_ctrl.mret_taken;
  assign higher_than_ras = trap_redirect || i_fence_i_flush || i_from_ex_comb.branch_taken ||
      i_pd_redirect;
  assign redirect_valid = higher_than_ras || ras_redirect_valid;
  assign redirect_partial = ras_redirect_valid && !higher_than_ras;
  always_comb begin
    if (trap_redirect) redirect_target = i_trap_ctrl.trap_target;
    else if (i_fence_i_flush) redirect_target = i_fence_i_target;
    else if (i_from_ex_comb.branch_taken) redirect_target = i_from_ex_comb.branch_target_address;
    else if (i_pd_redirect) redirect_target = i_pd_redirect_target;
    else redirect_target = {ras_redirect_target, 1'b0};
  end

  // ===========================================================================
  // Fill engine
  // ===========================================================================
  logic [1:0] enq_valid;
  riscv_pkg::pq_entry_t enq_entry0, enq_entry1;
  logic flush_full, flush_partial;
  logic queue_backpressure;

  parcel_fill_engine #(
      .XLEN(XLEN)
  ) u_fill (
      .i_clk,
      .i_rst(rst),
      .i_redirect_valid(redirect_valid),
      .i_redirect_target(redirect_target[XLEN-1:1]),
      .i_redirect_partial(redirect_partial),
      .i_win_valid(i_instr_valid),
      .i_win_served_addr(i_served_addr),
      .i_win_instr(i_instr),
      .i_win_sideband(i_instr_sideband),
      .o_lookup_pc(fill_lookup_pc),
      .i_btb_hit(btb_hit_1 && gate_1),
      .i_btb_taken(btb_taken_1 && gate_1),
      .i_btb_target(btb_target_1[XLEN-1:1]),
      .i_dir_taken(dir_taken_1 && pred_en),
      .i_dir_idx(dir_idx_1),
      .o_lookup_pc_2(fill_lookup_pc_2),
      .i_btb_hit_2(btb_hit_2 && gate_2),
      .i_btb_taken_2(btb_taken_2 && gate_2),
      .i_btb_target_2(btb_target_2[XLEN-1:1]),
      .i_dir_taken_2(1'b0),
      .i_dir_idx_2(fill_lookup_pc_2[riscv_pkg::BpDirIdxBits:1]),
      .o_ask_pc(fill_ask_pc),
      .o_core_redirect(o_core_redirect),
      .o_enq_valid(enq_valid),
      .o_enq_entry0(enq_entry0),
      .o_enq_entry1(enq_entry1),
      .o_flush_full(flush_full),
      .o_flush_partial(flush_partial),
      .i_queue_backpressure(queue_backpressure)
  );

  assign o_pc = {fill_ask_pc, 1'b0};
  assign o_fetch_backpressure = queue_backpressure;

  // ===========================================================================
  // Parcel queue
  // ===========================================================================
  logic [1:0] entry_valid;
  riscv_pkg::pq_entry_t entry0, entry1;
  logic [1:0] deq_count;

  parcel_queue u_queue (
      .i_clk,
      .i_rst(rst),
      .i_enq_valid(enq_valid),
      .i_enq_entry0(enq_entry0),
      .i_enq_entry1(enq_entry1),
      .i_deq_count(deq_count),
      .i_flush_full(flush_full),
      .i_flush_partial(flush_partial),
      .o_entry_valid(entry_valid),
      .o_entry0(entry0),
      .o_entry1(entry1),
      .o_count(),
      .o_backpressure(queue_backpressure)
  );

  // ===========================================================================
  // Consume side (bundle former + packet formation + RAS)
  // ===========================================================================
  // A full flush NOPs the consume side.  Use `higher_than_ras` (the full-flush
  // external redirects) rather than the fill's `flush_full`: the two are equal
  // (the RAS's own partial redirect never raises flush_full), and this keeps the
  // consume-flush cone independent of the RAS output (no combinational loop).
  logic consume_flush;
  assign consume_flush = i_pipeline_ctrl.flush || i_frontend_state_flush || higher_than_ras;

  logic                             ras_predicted;
  logic [                 XLEN-1:0] ras_predicted_target;
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos;
  logic [  riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count;

  parcel_consume_ras #(
      .XLEN(XLEN)
  ) u_ras (
      .i_clk,
      .i_rst(rst),
      .i_stall(i_pipeline_ctrl.stall),
      .i_entry0(entry0),
      .i_entry_valid(entry_valid),
      .i_flush(consume_flush),
      .i_prediction_allowed(pred_en),
      .i_ras_misprediction(i_from_ex_comb.ras_misprediction),
      .i_ras_restore_tos(i_from_ex_comb.ras_restore_tos),
      .i_ras_restore_valid_count(i_from_ex_comb.ras_restore_valid_count),
      .i_ras_pop_after_restore(i_from_ex_comb.ras_pop_after_restore),
      .i_ras_push_after_restore(i_from_ex_comb.ras_push_after_restore),
      .i_ras_push_address_after_restore(i_from_ex_comb.ras_push_address_after_restore),
      .o_ras_predicted(ras_predicted),
      .o_ras_predicted_target(ras_predicted_target),
      .o_ras_checkpoint_tos(ras_checkpoint_tos),
      .o_ras_checkpoint_valid_count(ras_checkpoint_valid_count),
      .o_ras_redirect_valid(ras_redirect_valid),
      .o_ras_redirect_target(ras_redirect_target)
  );

  parcel_consume_engine #(
      .XLEN(XLEN)
  ) u_consume (
      .i_entry_valid(entry_valid),
      .i_entry0(entry0),
      .i_entry1(entry1),
      .i_stall(i_pipeline_ctrl.stall),
      .i_flush(consume_flush),
      .i_slot1_ras_predicted(ras_predicted),
      .i_slot1_ras_predicted_target(ras_predicted_target),
      .i_slot1_ras_checkpoint_tos(ras_checkpoint_tos),
      .i_slot1_ras_checkpoint_valid_count(ras_checkpoint_valid_count),
      .o_slot1(o_from_if_to_pd),
      .o_slot2(o_from_if_to_pd_2),
      .o_deq_count(deq_count)
  );

  // Sink the bits not used by the stage-2 front end: the stage-1 parity input
  // (self-aligned frame), the registered/trap-check pipeline-ctrl fields (the
  // fill freeze / redirect matrix use the live signals), and the always-zero
  // bit 0 of the word-aligned targets.
  wire _unused = &{1'b0, i_instr_bank_sel_r, i_pipeline_ctrl.stall_registered,
                   i_pipeline_ctrl.stall_for_trap_check,
                   i_pipeline_ctrl.trap_taken_registered,
                   i_pipeline_ctrl.mret_taken_registered, btb_target_1[0],
                   btb_target_2[0], redirect_target[0]};

endmodule : if_stage_stage2
