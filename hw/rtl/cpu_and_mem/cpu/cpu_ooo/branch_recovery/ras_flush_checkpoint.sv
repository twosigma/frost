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

// Save the return-stack state from each packet until its ROB entry is
// released. A full flush discards the head and all younger instructions.
// The head's checkpoint therefore precedes their stack operations.
module ras_flush_checkpoint #(
    localparam int unsigned TagBits = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned SnapshotBits = riscv_pkg::XLEN + 2 * riscv_pkg::RasPtrBits + 1
) (
    input logic i_clk,
    input logic [1:0] i_allocate,
    input logic [1:0][TagBits-1:0] i_alloc_tag,
    input logic [1:0][SnapshotBits-1:0] i_snapshot,
    input logic i_restore_head,
    input logic [TagBits-1:0] i_head_tag,
    input riscv_pkg::from_ex_comb_t i_recovery,
    output riscv_pkg::from_ex_comb_t o_recovery
);
  logic [1:0][SnapshotBits-1:0] head_snapshot;
  // Adjacent allocations write opposite banks. A live head has a snapshot
  // from its most recent allocation, including when a tag wraps to zero.
  for (genvar bank = 0; bank < 2; bank++) begin : gen_bank
    logic write_first, write_second;
    assign write_first  = i_allocate[0] && i_alloc_tag[0][0] == 1'(bank);
    assign write_second = i_allocate[1] && i_alloc_tag[1][0] == 1'(bank);
    sdp_dist_ram #(
        .ADDR_WIDTH(TagBits - 1),
        .DATA_WIDTH(SnapshotBits)
    ) u_snapshot (
        .i_clk,
        .i_write_enable(write_first || write_second),
        .i_write_address(write_first ? i_alloc_tag[0][TagBits-1:1] : i_alloc_tag[1][TagBits-1:1]),
        .i_read_address(i_head_tag[TagBits-1:1]),
        .i_write_data(write_first ? i_snapshot[0] : i_snapshot[1]),
        .o_read_data(head_snapshot[bank])
    );
  end

  always_comb begin
    o_recovery = i_recovery;
    if (i_restore_head) begin
      o_recovery.ras_misprediction = 1'b1;
      {o_recovery.ras_restore_tos, o_recovery.ras_restore_valid_count,
       o_recovery.ras_restore_top} = head_snapshot[i_head_tag[0]];
      o_recovery.ras_pop_after_restore = 1'b0;
      o_recovery.ras_push_after_restore = 1'b0;
    end
  end
endmodule : ras_flush_checkpoint
