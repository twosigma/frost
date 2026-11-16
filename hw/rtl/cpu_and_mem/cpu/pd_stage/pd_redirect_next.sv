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
 * The values PD's shared redirect target registers load: slot 1's
 * conditional-branch candidates, slot 2's, or the backing BTB target (see
 * pd_stage.sv, "PD Redirect"). Which slot owns the registers comes from the
 * packet's decode, which arrives last, so every candidate is complete
 * without it and the slot selects choose between finished values in one
 * step:
 *   - slot 2's low PC and the carry into the high part are formed for both
 *     sizes of slot 1 from slot 1's PC alone, and slot 1's raw-parcel size
 *     picks one;
 *   - the backing target is formed from slot 2's return type and target for
 *     each size of slot 1, and the packet's size picks one inside the
 *     stack-return select;
 *   - the slot selects are single gates over the decode terms, and each
 *     register bit is one select over them and its candidates.
 * The kept nets hold that order: no slot select reaches a candidate's adder
 * or the backing target's select.
 */
module pd_redirect_next #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned SPLIT = riscv_pkg::PdTargetSplit,
    parameter int unsigned TARGET_BITS = riscv_pkg::PhysAddrBits,
    parameter int unsigned STACK_COUNT_BITS = riscv_pkg::RasPtrBits + 1
) (
    // Slot 1's decode: a native B-type or a compressed C.BEQZ/C.BNEZ, a
    // native or RV64C JAL or JALR (funct3 000), and its raw-parcel size.
    input logic i_slot1_native_branch,
    input logic i_slot1_compressed_branch,
    input logic i_slot1_native_jump,
    input logic i_slot1_rvc_jump,
    input logic i_slot1_compressed,
    // Slot 2's conditional-branch decode and size.
    input logic i_slot2_cond_branch,
    input logic i_slot2_compressed,
    // Each slot's not-taken direction candidate.
    input logic i_slot1_not_taken,
    input logic i_slot2_not_taken,
    // Slot 1's PC.
    input logic [XLEN-1:0] i_pc,
    // IF's PC-relative candidates: each format's low sum and {sign, carry}
    // high select, slot 1's relative to its PC and slot 2's relative to slot
    // 2's PC.
    input logic [SPLIT-1:0] i_slot1_native_low,
    input logic [1:0] i_slot1_native_high_select,
    input logic [SPLIT-1:0] i_slot1_compressed_low,
    input logic [1:0] i_slot1_compressed_high_select,
    input logic [SPLIT-1:0] i_slot2_native_low,
    input logic [1:0] i_slot2_native_high_select,
    input logic [SPLIT-1:0] i_slot2_compressed_low,
    input logic [1:0] i_slot2_compressed_high_select,
    // The backing BTB: slot 1's hit, return type and target bits
    // [TARGET_BITS-1:1], slot 2's return type and target for each size of
    // slot 1 (index 1 compressed), and the size that picks between them.
    input logic i_backing_hit,
    input logic i_backing_return,
    input logic [TARGET_BITS-2:0] i_backing_target,
    input logic [1:0] i_backing_slot2_return_by_size,
    input logic [1:0][TARGET_BITS-2:0] i_backing_slot2_target_by_size,
    input logic i_backing_size_select,
    // The packet's return address stack recovery point.
    input logic [STACK_COUNT_BITS-1:0] i_stack_count,
    input logic [XLEN-1:0] i_stack_top,
    // The registers' next values.
    output logic [SPLIT-1:0] o_target_native_low,
    output logic [SPLIT-1:0] o_target_compressed_low,
    output logic [1:0] o_target_native_high_select,
    output logic [1:0] o_target_compressed_high_select,
    output logic o_target_compressed,
    output logic [SPLIT-1:0] o_pc_low,
    output logic o_slot2_pc_carry,
    output logic o_fall_through_select,
    output logic [XLEN-SPLIT-1:0] o_pc_high
);

  // A carry out of slot 2's low PC moves slot 1's high select one step, as
  // fold_slot2_pc_carry in pd_stage.sv.
  function automatic logic [1:0] fold_pc_carry(input logic carry, input logic [1:0] high_select);
    if (carry) begin
      fold_pc_carry = (high_select == 2'b10) ? 2'b00 : 2'b01;
    end else begin
      fold_pc_carry = high_select;
    end
  endfunction

  // Slot selects. Slot 1's conditional branch owns the registers first, then
  // a slot-1 jump (for its backing target), then slot 2's conditional
  // branch, and otherwise the backing target. Each is one gate over the
  // decode terms; the high copy serves the PC-high bits.
  logic slot1_cond_branch;
  logic slot1_jump;
  (* keep = "true", max_fanout = 32 *)logic slot2_select;
  (* keep = "true" *)logic backing_low_select;
  (* keep = "true", max_fanout = 32 *)logic backing_high_select;
  assign slot1_cond_branch = i_slot1_native_branch || i_slot1_compressed_branch;
  assign slot1_jump = i_slot1_compressed ? i_slot1_rvc_jump : i_slot1_native_jump;
  assign slot2_select = !slot1_cond_branch && !slot1_jump && i_slot2_cond_branch;
  assign backing_low_select = !slot1_cond_branch && (slot1_jump || !i_slot2_cond_branch);
  assign backing_high_select = !slot1_cond_branch && (slot1_jump || !i_slot2_cond_branch);

  // Slot 2's low PC, slot 1's low PC plus its size, with the carry out of
  // bit SPLIT-1, for each size of slot 1.
  (* keep = "true" *)logic [SPLIT:0] slot2_pc_sum_after_compressed;
  (* keep = "true" *)logic [SPLIT:0] slot2_pc_sum_after_native;
  logic [SPLIT:0] slot2_pc_sum;
  assign slot2_pc_sum_after_compressed = {1'b0, i_pc[SPLIT-1:0]} +
      (SPLIT + 1)'(riscv_pkg::PcIncrementCompressed);
  assign slot2_pc_sum_after_native = {1'b0, i_pc[SPLIT-1:0]} +
      (SPLIT + 1)'(riscv_pkg::PcIncrement32bit);
  assign slot2_pc_sum = i_slot1_compressed ? slot2_pc_sum_after_compressed :
                                             slot2_pc_sum_after_native;

  // Slot 2's candidates with that carry folded into their high selects, so
  // both slots share slot 1's high PC and its +/-1 values.
  (* keep = "true" *) logic [SPLIT-1:0] slot2_native_low;
  (* keep = "true" *) logic [SPLIT-1:0] slot2_compressed_low;
  (* keep = "true" *) logic [1:0] slot2_native_high_select;
  (* keep = "true" *) logic [1:0] slot2_compressed_high_select;
  assign slot2_native_low = i_slot2_native_low;
  assign slot2_compressed_low = i_slot2_compressed_low;
  assign slot2_native_high_select = fold_pc_carry(slot2_pc_sum[SPLIT], i_slot2_native_high_select);
  assign slot2_compressed_high_select = fold_pc_carry(
      slot2_pc_sum[SPLIT], i_slot2_compressed_high_select
  );

  // The backing target: the stack's top for an entry trained on a return
  // while the stack holds an entry, otherwise the entry's target in slot 1's
  // 4 GiB region. Slot 1's hit takes slot 1's entry; otherwise slot 2's, at
  // the packet's size.
  (* keep = "true" *) logic stack_holds_entry;
  (* keep = "true", max_fanout = 32 *) logic backing_return_select;
  logic [TARGET_BITS-2:0] backing_slot2_target;
  (* keep = "true" *) logic [XLEN-1:0] backing_target;
  assign stack_holds_entry = i_stack_count != '0;
  assign backing_return_select = (i_backing_hit ? i_backing_return :
      i_backing_slot2_return_by_size[i_backing_size_select]) && stack_holds_entry;
  assign backing_slot2_target = i_backing_slot2_target_by_size[i_backing_size_select];
  assign backing_target = backing_return_select ? i_stack_top : {
    i_pc[XLEN-1:TARGET_BITS], i_backing_hit ? i_backing_target : backing_slot2_target, 1'b0
  };

  assign o_target_native_low = slot2_select ? slot2_native_low :
      (backing_low_select ? backing_target[SPLIT-1:0] : i_slot1_native_low);
  assign o_target_compressed_low = slot2_select ? slot2_compressed_low : i_slot1_compressed_low;
  assign o_target_native_high_select = slot2_select ? slot2_native_high_select :
      (backing_low_select ? 2'b00 : i_slot1_native_high_select);
  assign o_target_compressed_high_select = slot2_select ? slot2_compressed_high_select :
                                                          i_slot1_compressed_high_select;
  assign o_target_compressed = slot2_select ? i_slot2_compressed : i_slot1_compressed_branch;
  assign o_pc_low = slot2_select ? slot2_pc_sum[SPLIT-1:0] : i_pc[SPLIT-1:0];
  assign o_slot2_pc_carry = slot2_select && slot2_pc_sum[SPLIT];
  assign o_fall_through_select = slot2_select ? i_slot2_not_taken : i_slot1_not_taken;
  assign o_pc_high = backing_high_select ? backing_target[XLEN-1:SPLIT] : i_pc[XLEN-1:SPLIT];

endmodule : pd_redirect_next
