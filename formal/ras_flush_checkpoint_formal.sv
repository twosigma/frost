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

// Track one arbitrary ROB tag from its first reset and compare every bit of
// its latest dispatch checkpoint with the snapshot selected by a full flush.
module ras_flush_checkpoint_formal #(
    localparam int unsigned TagBits = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned SnapshotBits = riscv_pkg::XLEN + 2 * riscv_pkg::RasPtrBits + 1
) (
    input logic i_clk,
    input logic i_reset,
    input logic [1:0] i_allocate,
    input logic [TagBits-1:0] i_first_tag,
    i_watch_tag,
    i_head_tag,
    input logic [1:0][SnapshotBits-1:0] i_snapshot,
    input logic i_full_flush,
    i_head_valid,
    input riscv_pkg::from_ex_comb_t i_recovery
);
  logic [1:0][TagBits-1:0] tag;
  assign tag[0] = i_first_tag;
  assign tag[1] = i_first_tag + 1'b1;
  wire restore_head = i_full_flush && i_head_valid;
  riscv_pkg::from_ex_comb_t recovery;

  ras_flush_checkpoint dut (
      .i_clk,
      .i_allocate,
      .i_alloc_tag(tag),
      .i_snapshot,
      .i_restore_head(restore_head),
      .i_head_tag,
      .i_recovery,
      .o_recovery(recovery)
  );

  logic seen_reset = 0;
  logic known = 0;
  logic [TagBits-1:0] watch_tag;
  logic [SnapshotBits-1:0] reference;
  logic from_second, wrapped;
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      if (!seen_reset) watch_tag <= i_watch_tag;
      seen_reset <= 1;
      known <= 0;
    end else if (seen_reset) begin
      if (i_allocate[0] && tag[0] == watch_tag) begin
        reference <= i_snapshot[0];
        known <= 1;
        from_second <= 0;
        wrapped <= 0;
      end else if (i_allocate[1] && tag[1] == watch_tag) begin
        reference <= i_snapshot[1];
        known <= 1;
        from_second <= 1;
        wrapped <= &i_first_tag;
      end
    end
  end

  // Induction must relate the RAM row to the reference even before a flush.
  wire [SnapshotBits-1:0] even_row = dut.gen_bank[0].u_snapshot.ram[watch_tag[TagBits-1:1]];
  wire [SnapshotBits-1:0] odd_row = dut.gen_bank[1].u_snapshot.ram[watch_tag[TagBits-1:1]];
  always_comb begin
    p_initialized : assert (!known || seen_reset);
    if (known) p_stored_checkpoint : assert ((watch_tag[0] ? odd_row : even_row) == reference);
  end

  riscv_pkg::from_ex_comb_t expected;
  always_comb begin
    expected = i_recovery;
    if (restore_head) begin
      expected.ras_misprediction = 1;
      {expected.ras_restore_tos, expected.ras_restore_valid_count, expected.ras_restore_top} =
          reference;
      expected.ras_push_after_restore = 0;
      expected.ras_pop_after_restore = 0;
    end
    if (!restore_head || (known && i_head_tag == watch_tag)) begin
      p_recovery_bus : assert (recovery == expected);
    end
  end

  always @(posedge i_clk) begin
    if (seen_reset && !i_reset && known && i_head_tag == watch_tag && restore_head) begin
      c_first_even : cover (!from_second && !watch_tag[0] && reference[riscv_pkg::XLEN-1]);
      c_first_odd : cover (!from_second && watch_tag[0] && reference[riscv_pkg::XLEN-1]);
      c_second_even : cover (from_second && !watch_tag[0] && reference[riscv_pkg::XLEN-1]);
      c_second_odd : cover (from_second && watch_tag[0] && reference[riscv_pkg::XLEN-1]);
      c_wrap_replay : cover (wrapped && (&reference) && i_recovery.ras_push_after_restore);
    end
  end
endmodule : ras_flush_checkpoint_formal
