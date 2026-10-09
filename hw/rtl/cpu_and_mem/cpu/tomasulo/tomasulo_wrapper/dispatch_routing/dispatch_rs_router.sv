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
// Decode dispatch packets into per-RS valid and slot-1 intent signals.
//
// SPLIT_RS_DISPATCH selects between the dispatch unit pre-routing per-RS packets
// (i_*_rs_dispatch.valid) and the single-bus rs_type decode.
//
// Per-RS dispatch-valid nets carry (* max_fanout = 32 *). This module and the
// wrapper receiving nets both keep the attribute so the constraint survives
// flattened and hierarchical synthesis.
// =============================================================================
module dispatch_rs_router #(
    parameter bit SPLIT_RS_DISPATCH = 1'b0
) (
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch_2,
    input logic i_backend_recovery_hold,

    output logic o_int_rs_dispatch_valid,
    output logic o_mul_rs_dispatch_valid,
    output logic o_mem_rs_dispatch_valid,
    output logic o_fp_rs_dispatch_valid,
    output logic o_int_rs_dispatch_valid_2,
    output logic o_mul_rs_dispatch_valid_2,
    output logic o_mem_rs_dispatch_valid_2,
    output logic o_fp_rs_dispatch_valid_2,
    output logic o_int_rs_intent_1,
    output logic o_mul_rs_intent_1,
    output logic o_mem_rs_intent_1,
    output logic o_fp_rs_intent_1
);

  (* max_fanout = 32 *) logic int_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid;

  // Only the station matching slot 2's rs_type receives a valid packet.
  (* max_fanout = 32 *) logic int_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid_2;

  wire [2:0] dispatch_rs_type = i_rs_dispatch.rs_type;
  (* max_fanout = 32 *) logic single_bus_dispatch_valid;
  assign single_bus_dispatch_valid = i_rs_dispatch.valid && !i_backend_recovery_hold;

  always_comb begin
    if (SPLIT_RS_DISPATCH) begin
      int_rs_dispatch_valid = i_int_rs_dispatch.valid && !i_backend_recovery_hold;
      mul_rs_dispatch_valid = i_mul_rs_dispatch.valid && !i_backend_recovery_hold;
      mem_rs_dispatch_valid = i_mem_rs_dispatch.valid && !i_backend_recovery_hold;
      fp_rs_dispatch_valid  = i_fp_rs_dispatch.valid && !i_backend_recovery_hold;
    end else begin
      int_rs_dispatch_valid = single_bus_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_INT);
      mul_rs_dispatch_valid = single_bus_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MUL);
      mem_rs_dispatch_valid = single_bus_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MEM);
      fp_rs_dispatch_valid  = single_bus_dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FP);
    end
  end

  // Slot 2 requires split dispatch and is held during recovery.
  always_comb begin
    if (SPLIT_RS_DISPATCH) begin
      int_rs_dispatch_valid_2 = i_int_rs_dispatch_2.valid && !i_backend_recovery_hold;
      mul_rs_dispatch_valid_2 = i_mul_rs_dispatch_2.valid && !i_backend_recovery_hold;
      mem_rs_dispatch_valid_2 = i_mem_rs_dispatch_2.valid && !i_backend_recovery_hold;
      fp_rs_dispatch_valid_2  = i_fp_rs_dispatch_2.valid && !i_backend_recovery_hold;
    end else begin
      int_rs_dispatch_valid_2 = 1'b0;
      mul_rs_dispatch_valid_2 = 1'b0;
      mem_rs_dispatch_valid_2 = 1'b0;
      fp_rs_dispatch_valid_2  = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Fast slot-1 "intent" signals for every RS instance.
  // ---------------------------------------------------------------------------
  // Intent decodes the registered slot-1 rs_type, gated only by recovery. It
  // omits resource availability checks so each RS can preselect alloc_idx_2.
  // This is safe because bundles are atomic: whenever dispatch_fire_2 commits,
  // i_intent_1 equals dispatch_fire.
  wire [2:0] dispatch_slot1_rs_type_w =
      SPLIT_RS_DISPATCH ? i_int_rs_dispatch.rs_type : i_rs_dispatch.rs_type;
  logic int_rs_intent_1;
  logic mul_rs_intent_1;
  logic mem_rs_intent_1;
  logic fp_rs_intent_1;
  assign int_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_INT) && !i_backend_recovery_hold;
  assign mul_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_MUL) && !i_backend_recovery_hold;
  assign mem_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_MEM) && !i_backend_recovery_hold;
  // dispatch.sv serializes FP compute (slot2_fp_compute_serialized), so FP_RS
  // never commits slot 2. Compute its intent to keep the RS interfaces uniform.
  assign fp_rs_intent_1 =
      (dispatch_slot1_rs_type_w == riscv_pkg::RS_FP) && !i_backend_recovery_hold;

  assign o_int_rs_dispatch_valid = int_rs_dispatch_valid;
  assign o_mul_rs_dispatch_valid = mul_rs_dispatch_valid;
  assign o_mem_rs_dispatch_valid = mem_rs_dispatch_valid;
  assign o_fp_rs_dispatch_valid = fp_rs_dispatch_valid;
  assign o_int_rs_dispatch_valid_2 = int_rs_dispatch_valid_2;
  assign o_mul_rs_dispatch_valid_2 = mul_rs_dispatch_valid_2;
  assign o_mem_rs_dispatch_valid_2 = mem_rs_dispatch_valid_2;
  assign o_fp_rs_dispatch_valid_2 = fp_rs_dispatch_valid_2;
  assign o_int_rs_intent_1 = int_rs_intent_1;
  assign o_mul_rs_intent_1 = mul_rs_intent_1;
  assign o_mem_rs_intent_1 = mem_rs_intent_1;
  assign o_fp_rs_intent_1 = fp_rs_intent_1;

endmodule
