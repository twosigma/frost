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

// =============================================================================
// dispatch_rs_router
// =============================================================================
// Extracted verbatim from tomasulo_wrapper.sv (pure RTL boundary move, zero
// functional change).  Pure combinational decode of the dispatch packet(s) into
// per-RS dispatch-valid signals (slot 1 + slot 2) and the fast slot-1 "intent"
// signals each RS uses to pre-select alloc_idx_2 off the dispatch critical path.
//
// SPLIT_RS_DISPATCH selects between the dispatch unit pre-routing per-RS packets
// (i_*_rs_dispatch.valid) and the legacy single-bus rs_type decode.
//
// TIMING NOTE: the per-RS dispatch-valid nets carry (* max_fanout = 32 *).  The
// body below keeps that attribute verbatim, AND the wrapper keeps it on the
// receiving nets (where the fanout to the RS instances actually occurs), so the
// constraint is preserved under both flattened and hierarchical synthesis.
// =============================================================================
module dispatch_rs_router #(
    parameter bit SPLIT_RS_DISPATCH = 1'b0
) (
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fmul_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fdiv_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fmul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fdiv_rs_dispatch_2,
    input logic i_backend_recovery_hold,

    output logic o_int_rs_dispatch_valid,
    output logic o_mul_rs_dispatch_valid,
    output logic o_mem_rs_dispatch_valid,
    output logic o_fp_rs_dispatch_valid,
    output logic o_fmul_rs_dispatch_valid,
    output logic o_fdiv_rs_dispatch_valid,
    output logic o_int_rs_dispatch_valid_2,
    output logic o_mul_rs_dispatch_valid_2,
    output logic o_mem_rs_dispatch_valid_2,
    output logic o_fp_rs_dispatch_valid_2,
    output logic o_fmul_rs_dispatch_valid_2,
    output logic o_fdiv_rs_dispatch_valid_2,
    output logic o_int_rs_intent_1,
    output logic o_mul_rs_intent_1,
    output logic o_mem_rs_intent_1,
    output logic o_fp_rs_intent_1,
    output logic o_fmul_rs_intent_1,
    output logic o_fdiv_rs_intent_1
);

  (* max_fanout = 32 *) logic int_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fmul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fdiv_rs_dispatch_valid;

  // Slot-2 per-RS dispatch valid signals (2-wide dispatch, Session C plumbing).
  // The dispatch unit drives only one of the slot-2 inputs (the one for slot-2's
  // rs_type); the rest are inactive.
  (* max_fanout = 32 *) logic int_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fmul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fdiv_rs_dispatch_valid_2;

  wire [2:0] dispatch_rs_type = i_rs_dispatch.rs_type;
  (* max_fanout = 32 *) logic legacy_dispatch_valid;
  assign legacy_dispatch_valid = i_rs_dispatch.valid && !i_backend_recovery_hold;

  always_comb begin
    if (SPLIT_RS_DISPATCH) begin
      int_rs_dispatch_valid  = i_int_rs_dispatch.valid && !i_backend_recovery_hold;
      mul_rs_dispatch_valid  = i_mul_rs_dispatch.valid && !i_backend_recovery_hold;
      mem_rs_dispatch_valid  = i_mem_rs_dispatch.valid && !i_backend_recovery_hold;
      fp_rs_dispatch_valid   = i_fp_rs_dispatch.valid && !i_backend_recovery_hold;
      fmul_rs_dispatch_valid = i_fmul_rs_dispatch.valid && !i_backend_recovery_hold;
      fdiv_rs_dispatch_valid = i_fdiv_rs_dispatch.valid && !i_backend_recovery_hold;
    end else begin
      int_rs_dispatch_valid  = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_INT);
      mul_rs_dispatch_valid  = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MUL);
      mem_rs_dispatch_valid  = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MEM);
      fp_rs_dispatch_valid   = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FP);
      fmul_rs_dispatch_valid = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FMUL);
      fdiv_rs_dispatch_valid = legacy_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FDIV);
    end
  end

  // Slot-2 dispatch routing.  The dispatch unit decodes slot-2's rs_type and
  // asserts the matching i_*_rs_dispatch_2.valid; the wrapper simply gates each
  // by !backend_recovery_hold.  Legacy non-split mode does not support slot-2,
  // so all slot-2 valids are zero in that case.
  always_comb begin
    if (SPLIT_RS_DISPATCH) begin
      int_rs_dispatch_valid_2  = i_int_rs_dispatch_2.valid && !i_backend_recovery_hold;
      mul_rs_dispatch_valid_2  = i_mul_rs_dispatch_2.valid && !i_backend_recovery_hold;
      mem_rs_dispatch_valid_2  = i_mem_rs_dispatch_2.valid && !i_backend_recovery_hold;
      fp_rs_dispatch_valid_2   = i_fp_rs_dispatch_2.valid && !i_backend_recovery_hold;
      fmul_rs_dispatch_valid_2 = i_fmul_rs_dispatch_2.valid && !i_backend_recovery_hold;
      fdiv_rs_dispatch_valid_2 = i_fdiv_rs_dispatch_2.valid && !i_backend_recovery_hold;
    end else begin
      int_rs_dispatch_valid_2  = 1'b0;
      mul_rs_dispatch_valid_2  = 1'b0;
      mem_rs_dispatch_valid_2  = 1'b0;
      fp_rs_dispatch_valid_2   = 1'b0;
      fmul_rs_dispatch_valid_2 = 1'b0;
      fdiv_rs_dispatch_valid_2 = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Fast slot-1 "intent" signals for every RS instance.
  // ---------------------------------------------------------------------------
  // Each *_rs_intent_1 says "slot-1's instruction is heading for this RS",
  // derived from the registered rs_type field on the slot-1 dispatch packet
  // and gated only by !i_backend_recovery_hold.  These signals do NOT include
  // any RS-full / bundle_fire_ok / rob_full / lq_full / sq_full term, so they
  // never pull e.g. fdiv_rs/count_reg or rob/tail_ptr into another RS's
  // alloc_idx_2 / rs_valid commit cone.  Inside each RS, alloc_idx_2 selects
  // off i_intent_1 instead of the slow dispatch_fire.  Architecturally safe:
  // whenever dispatch_fire_2 actually commits a slot-2 entry, the bundle is
  // atomic, so i_intent_1 == dispatch_fire by construction.
  wire [2:0] dispatch_slot1_rs_type_w =
      SPLIT_RS_DISPATCH ? i_int_rs_dispatch.rs_type : i_rs_dispatch.rs_type;
  logic int_rs_intent_1;
  logic mul_rs_intent_1;
  logic mem_rs_intent_1;
  logic fp_rs_intent_1;
  logic fmul_rs_intent_1;
  logic fdiv_rs_intent_1;
  assign int_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_INT) && !i_backend_recovery_hold;
  assign mul_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_MUL) && !i_backend_recovery_hold;
  assign mem_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_MEM) && !i_backend_recovery_hold;
  // FP-family slot-2 dispatch is held off by dispatch.sv (slot2_fp_compute_serialized),
  // so dispatch_fire_2 is always 0 in these RSes — alloc_idx_2 never affects
  // a real commit.  Compute the intent anyway for clarity / consistency.
  assign fp_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_FP) && !i_backend_recovery_hold;
  assign fmul_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_FMUL) && !i_backend_recovery_hold;
  assign fdiv_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_FDIV) && !i_backend_recovery_hold;

  // Drive the output ports from the locally-computed signals.
  assign o_int_rs_dispatch_valid = int_rs_dispatch_valid;
  assign o_mul_rs_dispatch_valid = mul_rs_dispatch_valid;
  assign o_mem_rs_dispatch_valid = mem_rs_dispatch_valid;
  assign o_fp_rs_dispatch_valid = fp_rs_dispatch_valid;
  assign o_fmul_rs_dispatch_valid = fmul_rs_dispatch_valid;
  assign o_fdiv_rs_dispatch_valid = fdiv_rs_dispatch_valid;
  assign o_int_rs_dispatch_valid_2 = int_rs_dispatch_valid_2;
  assign o_mul_rs_dispatch_valid_2 = mul_rs_dispatch_valid_2;
  assign o_mem_rs_dispatch_valid_2 = mem_rs_dispatch_valid_2;
  assign o_fp_rs_dispatch_valid_2 = fp_rs_dispatch_valid_2;
  assign o_fmul_rs_dispatch_valid_2 = fmul_rs_dispatch_valid_2;
  assign o_fdiv_rs_dispatch_valid_2 = fdiv_rs_dispatch_valid_2;
  assign o_int_rs_intent_1 = int_rs_intent_1;
  assign o_mul_rs_intent_1 = mul_rs_intent_1;
  assign o_mem_rs_intent_1 = mem_rs_intent_1;
  assign o_fp_rs_intent_1 = fp_rs_intent_1;
  assign o_fmul_rs_intent_1 = fmul_rs_intent_1;
  assign o_fdiv_rs_intent_1 = fdiv_rs_intent_1;

endmodule
