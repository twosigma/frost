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
 * parcel_consume_ras -- the stage-2 front end's consume-side return-address
 * stack (PARCEL_QUEUE_DESIGN.md section 2.4).  Wraps the (unchanged)
 * `ras_detector` + `return_address_stack` and drives them from the head/slot-1
 * queue entry, with ALL side effects edge-triggered on DEQUEUE-FIRE.
 *
 * DEQUEUE-FIRE (design 2.4 / panel finding 3): the RAS push/pop and the return
 * redirect fire only on `slot1_present && !stall` -- the cycle the head return
 * entry actually retires.  A return sitting at the head under a stall is inert
 * (a level-sensitive formulation would re-fire every stall cycle, thrashing the
 * fill walk and burning epochs).  Because the head advances the cycle it
 * retires, each return fires exactly once.
 *
 * PACKET FIELDS (stable under stall): `o_ras_predicted` / `_target` /
 * `_checkpoint_*` describe the head instruction and are held level -- the queue
 * re-presents the identical bundle under stall (downstream invariant 9), so the
 * lookup gate is stall-free; only the SIDE EFFECTS carry the dequeue-fire term.
 * The checkpoints are the pre-instruction stack state (for backend recovery).
 *
 * RETURN REDIRECT: on the dequeue-fire of a predicted return, `o_ras_redirect_*`
 * pulses the fill engine's redirect port (a PARTIAL flush + resteer to the RAS
 * target -- the §2.5 RAS row).  Everything younger in the queue was wrong-path
 * and is discarded by the partial flush.
 */
module parcel_consume_ras #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stall,

    // ---- Head/slot-1 entry + consume state ----
    input riscv_pkg::pq_entry_t       i_entry0,       // head entry
    input logic                 [1:0] i_entry_valid,  // [0] = head valid
    input logic                       i_flush,        // queue-emptying flush

    // ---- Prediction gate (global: !disable_branch_prediction; NOT stall) ----
    input logic i_prediction_allowed,

    // ---- Misprediction recovery (from the backend, i_from_ex_comb) ----
    input logic                             i_ras_misprediction,
    input logic [riscv_pkg::RasPtrBits-1:0] i_ras_restore_tos,
    input logic [  riscv_pkg::RasPtrBits:0] i_ras_restore_valid_count,
    input logic                             i_ras_pop_after_restore,
    input logic                             i_ras_push_after_restore,
    input logic [                 XLEN-1:0] i_ras_push_address_after_restore,

    // ---- RAS metadata for the slot-1 packet ----
    output logic                             o_ras_predicted,
    output logic [                 XLEN-1:0] o_ras_predicted_target,
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_checkpoint_tos,
    output logic [  riscv_pkg::RasPtrBits:0] o_ras_checkpoint_valid_count,

    // ---- Return redirect to the fill engine (partial flush, §2.5) ----
    output logic            o_ras_redirect_valid,
    output logic [XLEN-1:1] o_ras_redirect_target
);

  // ===========================================================================
  // Consume state: present head + dequeue-fire edge
  // ===========================================================================
  logic slot1_present, dequeue_fire;
  assign slot1_present = i_entry_valid[0] && !i_flush;
  assign dequeue_fire  = slot1_present && !i_stall;  // the head retires this cycle

  // The RAS reads only the head's instruction bytes / is_compressed / pc; the
  // prediction-metadata fields and the head+1 valid bit are not RAS inputs.
  wire _unused = &{1'b0, i_entry0[45:0], i_entry_valid[1]};

  // ===========================================================================
  // Return-class detection on the head instruction (unchanged ras_detector)
  // ===========================================================================
  logic is_call, is_return, is_coroutine;
  ras_detector u_ras_detector (
      .i_instruction      (i_entry0.instr_bytes),
      .i_raw_parcel       (i_entry0.instr_bytes[15:0]),
      .i_is_compressed    (i_entry0.is_compressed),
      .i_instruction_valid(slot1_present),
      .o_is_call          (is_call),
      .o_is_return        (is_return),
      .o_is_coroutine     (is_coroutine)
  );

  logic [XLEN-1:0] link_address;
  assign link_address = {i_entry0.pc, 1'b0} +
      (i_entry0.is_compressed ? riscv_pkg::PcIncrementCompressed
                              : riscv_pkg::PcIncrement32bit);

  // Lookup gate: the global gate plus the halfword gate (a 32-bit op at a
  // halfword PC must not be predicted; a compressed one is safe).  Stall-free so
  // the packet re-presents identically under stall.
  logic ras_lookup_allowed;
  assign ras_lookup_allowed = i_prediction_allowed && (!i_entry0.pc[1] || i_entry0.is_compressed);

  // Side effects (push/pop) fire only on dequeue-fire (design 2.4).  The stack
  // pushes on `!stall_registered` by its own design, so to keep push ALSO on
  // dequeue-fire we gate the call input here and tie the stack's stall gate off
  // (`i_stall_registered = 0`); the return/coroutine inputs stay ungated so the
  // level prediction `o_ras_valid` re-presents under stall, with the pop gated
  // by `i_prediction_allowed = ras_effect_allowed`.
  logic ras_effect_allowed;
  assign ras_effect_allowed = ras_lookup_allowed && dequeue_fire;
  logic push_call;
  assign push_call = is_call && ras_effect_allowed;

  // ===========================================================================
  // Registered recovery inputs (breaks the backend -> consume path, as bpc)
  // ===========================================================================
  logic                             ras_mispred_r;
  logic [riscv_pkg::RasPtrBits-1:0] ras_restore_tos_r;
  logic [  riscv_pkg::RasPtrBits:0] ras_restore_vc_r;
  logic                             ras_pop_after_r;
  logic                             ras_push_after_r;
  logic [                 XLEN-1:0] ras_push_addr_r;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ras_mispred_r    <= 1'b0;
      ras_pop_after_r  <= 1'b0;
      ras_push_after_r <= 1'b0;
    end else begin
      ras_mispred_r    <= i_ras_misprediction;
      ras_pop_after_r  <= i_ras_pop_after_restore;
      ras_push_after_r <= i_ras_push_after_restore;
    end
  end
  always_ff @(posedge i_clk) begin
    ras_restore_tos_r <= i_ras_restore_tos;
    ras_restore_vc_r  <= i_ras_restore_valid_count;
    ras_push_addr_r   <= i_ras_push_address_after_restore;
  end

  // ===========================================================================
  // The stack (unchanged return_address_stack)
  // ===========================================================================
  logic            ras_valid;
  logic [XLEN-1:0] ras_target;
  return_address_stack #(
      .RAS_DEPTH   (riscv_pkg::RasDepth),
      .RAS_PTR_BITS(riscv_pkg::RasPtrBits)
  ) u_ras (
      .i_clk,
      .i_rst,
      .i_stall_registered(1'b0),  // external dequeue-fire gate instead
      .i_is_call(push_call),
      .i_is_return(is_return),
      .i_is_coroutine(is_coroutine),
      .i_link_address(link_address),
      .i_prediction_allowed(ras_effect_allowed),
      .i_prediction_allowed_for_write(ras_effect_allowed),
      .i_btb_only_prediction_holdoff(1'b0),
      .i_misprediction(ras_mispred_r),
      .i_restore_tos(ras_restore_tos_r),
      .i_restore_valid_count(ras_restore_vc_r),
      .i_pop_after_restore(ras_pop_after_r),
      .i_push_after_restore(ras_push_after_r),
      .i_push_address_after_restore(ras_push_addr_r),
      .o_ras_valid(ras_valid),
      .o_ras_target(ras_target),
      .o_checkpoint_tos(o_ras_checkpoint_tos),
      .o_checkpoint_valid_count(o_ras_checkpoint_valid_count)
  );

  // ===========================================================================
  // Packet metadata (level) and the return redirect (dequeue-fire edge)
  // ===========================================================================
  assign o_ras_predicted = slot1_present && ras_lookup_allowed && ras_valid;
  assign o_ras_predicted_target = ras_target;
  assign o_ras_redirect_valid = o_ras_predicted && dequeue_fire;
  assign o_ras_redirect_target = ras_target[XLEN-1:1];

endmodule : parcel_consume_ras
