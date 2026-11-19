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

// The captured fields and slot-1 backing selection together equal the
// original redirect expressions, for any decode, packet, candidates, backing
// BTB result and stack state. In the replaced form the slot selects come
// first, slot 1's size enters the slot-2 PC adder as its addend, and the
// backing target reads slot 2's return type and target as IF's slot-2
// outputs, which are its per-size outputs at the packet's sel_compressed
// (formal/if_slot2_precompute.sby, formal/backing_btb.sby). The module is
// combinational, so one step with every input free covers every value.
module pd_redirect_next_equiv #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic pd_native_branch,
    input logic pd_compressed_branch,
    input logic pd_native_jump,
    input logic pd_rvc_jump,
    input logic pd_sel_compressed,
    input logic pd_cond_branch_2,
    input logic pd_sel_compressed_2,
    input logic pd_not_taken_candidate,
    input logic pd_not_taken_candidate_2,
    input logic [XLEN-1:0] program_counter,
    input logic [riscv_pkg::PdTargetSplit-1:0] pd_target_native_low_candidate,
    input logic [1:0] pd_target_native_high_select,
    input logic [riscv_pkg::PdTargetSplit-1:0] pd_target_compressed_low_candidate,
    input logic [1:0] pd_target_compressed_high_select,
    input logic [riscv_pkg::PdTargetSplit-1:0] slot2_pd_target_native_low,
    input logic [1:0] slot2_pd_target_native_high_select,
    input logic [riscv_pkg::PdTargetSplit-1:0] slot2_pd_target_compressed_low,
    input logic [1:0] slot2_pd_target_compressed_high_select,
    input logic backing_hit_0,
    input logic backing_return_0,
    input logic [riscv_pkg::PhysAddrBits-2:0] backing_target_0,
    input logic [1:0] backing_slot2_return_by_size,
    input logic [1:0][riscv_pkg::PhysAddrBits-2:0] backing_slot2_target_by_size,
    input logic sel_compressed,
    input logic [riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count,
    input logic [XLEN-1:0] ras_checkpoint_top
);
  localparam int unsigned PdTargetSplit = riscv_pkg::PdTargetSplit;
  localparam int unsigned PdTargetHighWidth = XLEN - PdTargetSplit;

  function automatic logic [1:0] fold_slot2_pc_carry(input logic slot2_pc_carry,
                                                     input logic [1:0] high_select);
    if (slot2_pc_carry) begin
      fold_slot2_pc_carry = (high_select == 2'b10) ? 2'b00 : 2'b01;
    end else begin
      fold_slot2_pc_carry = high_select;
    end
  endfunction

  // IF's slot-2 backing outputs: the per-size entries at the packet's size.
  logic [1:0] i_backing_hit;
  logic [1:0] i_backing_return;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] i_backing_target;
  assign i_backing_hit[0] = backing_hit_0;
  assign i_backing_hit[1] = 1'b0;
  assign i_backing_return = {backing_slot2_return_by_size[sel_compressed], backing_return_0};
  assign i_backing_target = {backing_slot2_target_by_size[sel_compressed], backing_target_0};

  // The replaced form.
  logic pd_cond_branch;
  logic pd_slot1_jump;
  logic pd_slot2_target_select;
  logic pd_backing_low_select;
  logic pd_backing_high_select;
  logic pd_backing_target_return;
  logic [XLEN-1:0] pd_backing_target;
  logic [PdTargetSplit:0] pd_slot2_pc_sum;
  logic pd_slot2_pc_carry;
  logic [PdTargetSplit-1:0] pd_slot2_pc_low;
  logic [1:0] pd_slot2_target_native_high_select;
  logic [1:0] pd_slot2_target_compressed_high_select;
  assign pd_cond_branch = pd_native_branch || pd_compressed_branch;
  assign pd_slot1_jump = pd_sel_compressed ? pd_rvc_jump : pd_native_jump;
  assign pd_slot2_target_select = !pd_cond_branch && !pd_slot1_jump && pd_cond_branch_2;
  assign pd_backing_low_select = !pd_cond_branch && (pd_slot1_jump || !pd_cond_branch_2);
  assign pd_backing_high_select = !pd_cond_branch && (pd_slot1_jump || !pd_cond_branch_2);
  assign pd_backing_target_return =
      (i_backing_hit[0] ? i_backing_return[0] : i_backing_return[1]) &&
      (ras_checkpoint_valid_count != '0);
  assign pd_backing_target = pd_backing_target_return ? ras_checkpoint_top : {
    program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
    i_backing_hit[0] ? i_backing_target[0] : i_backing_target[1],
    1'b0
  };
  assign pd_slot2_pc_sum = {1'b0, program_counter[PdTargetSplit-1:0]} +
      (pd_sel_compressed ? (PdTargetSplit + 1)'(riscv_pkg::PcIncrementCompressed) :
                           (PdTargetSplit + 1)'(riscv_pkg::PcIncrement32bit));
  assign pd_slot2_pc_carry = pd_slot2_pc_sum[PdTargetSplit];
  assign pd_slot2_pc_low = pd_slot2_pc_sum[PdTargetSplit-1:0];
  assign pd_slot2_target_native_high_select = fold_slot2_pc_carry(
      pd_slot2_pc_carry, slot2_pd_target_native_high_select
  );
  assign pd_slot2_target_compressed_high_select = fold_slot2_pc_carry(
      pd_slot2_pc_carry, slot2_pd_target_compressed_high_select
  );

  logic [PdTargetSplit-1:0] reference_native_low;
  logic [PdTargetSplit-1:0] reference_compressed_low;
  logic [1:0] reference_native_high_select;
  logic [1:0] reference_compressed_high_select;
  logic reference_compressed;
  logic [PdTargetSplit-1:0] reference_pc_low;
  logic reference_slot2_pc_carry;
  logic reference_fall_through_select;
  logic [PdTargetHighWidth-1:0] reference_pc_high;
  assign reference_native_low = pd_slot2_target_select ? slot2_pd_target_native_low :
      (pd_backing_low_select ? pd_backing_target[PdTargetSplit-1:0] :
                               pd_target_native_low_candidate);
  assign reference_compressed_low = pd_slot2_target_select ?
      slot2_pd_target_compressed_low : pd_target_compressed_low_candidate;
  assign reference_native_high_select = pd_slot2_target_select ?
      pd_slot2_target_native_high_select :
      (pd_backing_low_select ? 2'b00 : pd_target_native_high_select);
  assign reference_compressed_high_select = pd_slot2_target_select ?
      pd_slot2_target_compressed_high_select : pd_target_compressed_high_select;
  assign reference_compressed = pd_slot2_target_select ? pd_sel_compressed_2 : pd_compressed_branch;
  assign reference_pc_low = pd_slot2_target_select ? pd_slot2_pc_low :
                                                     program_counter[PdTargetSplit-1:0];
  assign reference_slot2_pc_carry = pd_slot2_target_select && pd_slot2_pc_carry;
  assign reference_fall_through_select = pd_slot2_target_select ? pd_not_taken_candidate_2 :
                                                                  pd_not_taken_candidate;
  assign reference_pc_high = pd_backing_high_select ? pd_backing_target[XLEN-1:PdTargetSplit] :
                                                      program_counter[XLEN-1:PdTargetSplit];

  logic [PdTargetSplit-1:0] next_native_low;
  logic [PdTargetSplit-1:0] next_compressed_low;
  logic [1:0] next_native_high_select;
  logic [1:0] next_compressed_high_select;
  logic next_compressed;
  logic [PdTargetSplit-1:0] next_pc_low;
  logic next_slot2_pc_carry;
  logic next_fall_through_select;
  logic [PdTargetHighWidth-1:0] next_pc_high;
  logic [PdTargetSplit-1:0] alternate_native_low;
  logic [PdTargetHighWidth-1:0] alternate_pc_high;
  logic slot1_backing_select;
  logic [XLEN-1:0] slot1_backing_target;
  assign next_native_low = slot1_backing_select ? slot1_backing_target[PdTargetSplit-1:0] :
                                                  alternate_native_low;
  assign next_pc_high = slot1_backing_select ? slot1_backing_target[XLEN-1:PdTargetSplit] :
                                               alternate_pc_high;
  pd_redirect_next #(
      .XLEN(XLEN)
  ) dut (
      .i_slot1_native_branch(pd_native_branch),
      .i_slot1_compressed_branch(pd_compressed_branch),
      .i_slot1_native_jump(pd_native_jump),
      .i_slot1_rvc_jump(pd_rvc_jump),
      .i_slot1_compressed(pd_sel_compressed),
      .i_slot2_cond_branch(pd_cond_branch_2),
      .i_slot2_compressed(pd_sel_compressed_2),
      .i_slot1_not_taken(pd_not_taken_candidate),
      .i_slot2_not_taken(pd_not_taken_candidate_2),
      .i_pc(program_counter),
      .i_slot1_native_low(pd_target_native_low_candidate),
      .i_slot1_native_high_select(pd_target_native_high_select),
      .i_slot1_compressed_low(pd_target_compressed_low_candidate),
      .i_slot1_compressed_high_select(pd_target_compressed_high_select),
      .i_slot2_native_low(slot2_pd_target_native_low),
      .i_slot2_native_high_select(slot2_pd_target_native_high_select),
      .i_slot2_compressed_low(slot2_pd_target_compressed_low),
      .i_slot2_compressed_high_select(slot2_pd_target_compressed_high_select),
      .i_backing_hit(backing_hit_0),
      .i_backing_return(backing_return_0),
      .i_backing_target(backing_target_0),
      .i_backing_slot2_return_by_size(backing_slot2_return_by_size),
      .i_backing_slot2_target_by_size(backing_slot2_target_by_size),
      .i_backing_size_select(sel_compressed),
      .i_stack_count(ras_checkpoint_valid_count),
      .i_stack_top(ras_checkpoint_top),
      .o_target_native_low(alternate_native_low),
      .o_target_compressed_low(next_compressed_low),
      .o_target_native_high_select(next_native_high_select),
      .o_target_compressed_high_select(next_compressed_high_select),
      .o_target_compressed(next_compressed),
      .o_pc_low(next_pc_low),
      .o_slot2_pc_carry(next_slot2_pc_carry),
      .o_fall_through_select(next_fall_through_select),
      .o_pc_high(alternate_pc_high),
      .o_slot1_backing_select(slot1_backing_select),
      .o_slot1_backing_target(slot1_backing_target)
  );

  always_comb begin
    p_native_low_equal : assert (next_native_low == reference_native_low);
    p_compressed_low_equal : assert (next_compressed_low == reference_compressed_low);
    p_native_high_select_equal : assert (next_native_high_select == reference_native_high_select);
    p_compressed_high_select_equal :
    assert (next_compressed_high_select == reference_compressed_high_select);
    p_compressed_equal : assert (next_compressed == reference_compressed);
    p_pc_low_equal : assert (next_pc_low == reference_pc_low);
    p_slot2_pc_carry_equal : assert (next_slot2_pc_carry == reference_slot2_pc_carry);
    p_fall_through_select_equal :
    assert (next_fall_through_select == reference_fall_through_select);
    p_pc_high_equal : assert (next_pc_high == reference_pc_high);
  end
endmodule
