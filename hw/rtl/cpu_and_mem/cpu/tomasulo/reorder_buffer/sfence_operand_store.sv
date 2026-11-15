/*
 *    Copyright (c) 2026 John Goodacre.
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
 * sfence_operand_store: the SFENCE.VMA filters, held per ROB entry.
 *
 * An SFENCE.VMA waits in the MEM_RS for rs1 (address) and rs2 (ASID) like any
 * other operation and, when it issues, hands both values to this store under
 * its ROB tag. The ROB keeps the retiring SFENCE.VMA at the head until its
 * operands are here, so by the time it opens its TLB window the head entry's
 * filters are readable. Each entry holds the page number rs1[38:12], the ASID
 * rs2[8:0], and two bits that say whether rs1 and rs2 were registers other than
 * x0 (x0 means "any").
 *
 * An entry's ready bit clears when the ROB allocates the tag, so a flushed
 * SFENCE.VMA leaves nothing behind for the next occupant; a capture for a tag
 * that holds no live SFENCE.VMA is ignored.
 */
module sfence_operand_store #(
    parameter int unsigned DEPTH = riscv_pkg::ReorderBufferDepth,
    localparam int unsigned TagWidth = $clog2(DEPTH),
    localparam int unsigned DataWidth = riscv_pkg::Sv39VpnBits + riscv_pkg::AsidBits + 2
) (
    input logic i_clk,
    input logic i_rst_n,

    // The ROB allocated these tags this cycle (one or two entries).
    input logic                i_alloc_valid,
    input logic [TagWidth-1:0] i_alloc_tag,
    input logic                i_alloc_valid_2,
    input logic [TagWidth-1:0] i_alloc_tag_2,

    // An SFENCE.VMA issued from the MEM_RS with its operands. i_cap_live is
    // the ROB's view that the tag holds a live SFENCE.VMA.
    input logic                 i_cap_valid,
    input logic                 i_cap_live,
    input logic [ TagWidth-1:0] i_cap_tag,
    input logic [DataWidth-1:0] i_cap_data,

    // The head entry. Ready is combinational in the head index; the data is
    // valid when ready is.
    input  logic [ TagWidth-1:0] i_head_idx,
    output logic                 o_head_ready,
    output logic [DataWidth-1:0] o_head_data
);

  logic [DEPTH-1:0] ready_q;
  logic [DataWidth-1:0] data_q[DEPTH];

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      ready_q <= '0;
    end else begin
      // A capture from an older, flushed occupant never outlives the new
      // allocation: the allocation clear wins.
      if (i_cap_valid && i_cap_live) ready_q[i_cap_tag] <= 1'b1;
      if (i_alloc_valid) ready_q[i_alloc_tag] <= 1'b0;
      if (i_alloc_valid_2) ready_q[i_alloc_tag_2] <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_cap_valid && i_cap_live) data_q[i_cap_tag] <= i_cap_data;
  end

  assign o_head_ready = ready_q[i_head_idx];
  assign o_head_data  = data_q[i_head_idx];

endmodule : sfence_operand_store
