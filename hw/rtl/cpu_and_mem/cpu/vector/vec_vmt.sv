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
  The vector memory table: one entry per vector memory instruction in flight,
  in program order.

  An entry is allocated at dispatch (slot 1 only, at most one a cycle) into the
  lowest index that is free in the pre-edge state, so an index freed on one
  edge stays invalid for a full cycle before it is reused. Its `retired` bit is
  set on the edge its instruction commits (from the ROB's combinational commit
  bus, so on the edge the head passes it); a retired entry is older than every
  instruction still in the ROB and is never flushed. An unretired entry is
  freed one cycle after a full flush, or after a partial flush when it is
  younger than the flush tag. The pending per-entry removal is sampled with
  the flush-cycle head and tag; it cannot remove a reused index. Any entry is
  freed when the memory unit reports it complete. The range is written once,
  when it is known, and stays fixed while the entry is live. `gen` advances on
  every allocation of an index.

  o_quiet_q is 1 when no retired entry is live. It is registered from the
  next-state bits, so on the edge an instruction retires the term already
  reads 0: a FENCE, SFENCE.VMA, SC or misaligned access that reaches the ROB
  head after a vector memory instruction waits for that instruction's
  accesses to finish before it drains, arms or accesses memory (rule V-O4).
*/
module vec_vmt #(
    localparam int unsigned VMT  = riscv_pkg::VmtDepth,
    localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned IdxW = $clog2(riscv_pkg::VmtDepth),
    localparam int unsigned SegW = 1 + riscv_pkg::VmtPpnBits + 14,
    localparam int unsigned EntW = riscv_pkg::VmtEntryBits
) (
    input  logic                                 i_clk,
    input  logic                                 i_rst,
    // Dispatch: allocate an entry for the instruction with this ROB tag.
    // Only while !o_full and no full flush is being taken.
    input  logic                                 i_alloc_valid,
    input  logic                 [TagW-1:0]      i_alloc_tag,
    output logic                                 o_full,
    output logic                 [IdxW-1:0]      o_alloc_idx,
    // Commit, combinational from the ROB (slot 1; vector memory
    // instructions retire alone)
    input  logic                                 i_commit_valid,
    input  logic                 [TagW-1:0]      i_commit_tag,
    // Flush: full, or partial (entries younger than i_flush_tag, which is a
    // live instruction at or after the head; a recovery behind an instruction
    // that has already retired arrives as a full flush)
    input  logic                                 i_flush_all,
    input  logic                                 i_flush_en,
    input  logic                 [TagW-1:0]      i_flush_tag,
    input  logic                 [TagW-1:0]      i_head_tag,
    // The memory unit: range write and completion, by index
    input  logic                                 i_range_valid,
    input  logic                 [IdxW-1:0]      i_range_idx,
    // Each segment as riscv_pkg::vmt_seg_t bits: valid, page, first and last sector
    input  logic                 [SegW-1:0]      i_range_seg0,
    input  logic                 [SegW-1:0]      i_range_seg1,
    input  logic                                 i_done_valid,
    input  logic                 [IdxW-1:0]      i_done_idx,
    // The table as the load and store queues see it, and V-O4's term
    output riscv_pkg::vmt_view_t                 o_view,
    output logic                 [ VMT-1:0][1:0] o_gen,
    output logic                                 o_quiet_q
);

  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age, flush_age;
    entry_age  = {1'b0, entry_tag} - {1'b0, head};
    flush_age  = {1'b0, flush_tag} - {1'b0, head};
    is_younger = entry_age > flush_age;
  endfunction

  logic [VMT-1:0] live_q, retired_q, known_q;
  logic [VMT-1:0][TagW-1:0] tag_q;
  logic [VMT-1:0][1:0] gen_q;
  logic [VMT-1:0][SegW-1:0] seg0_q, seg1_q;

  // Lowest free index in the pre-edge state.
  always_comb begin
    o_alloc_idx = '0;
    for (int t = VMT - 1; t >= 0; t--) if (!live_q[t]) o_alloc_idx = IdxW'(t);
  end
  assign o_full = &live_q;

  logic [VMT-1:0] live_d, retired_d, flush_pending_q, flush_pending_d;
  logic [VMT-1:0] retiring;
  for (genvar t = 0; t < VMT; t++) begin : gen_retiring
    assign retiring[t] = i_commit_valid && live_q[t] && !retired_q[t] &&
                         !flush_pending_q[t] && tag_q[t] == i_commit_tag;
  end
  always_comb begin
    for (int t = 0; t < VMT; t++) begin
      flush_pending_d[t] = live_q[t] && !retired_q[t] && !flush_pending_q[t] &&
          (i_flush_all || (i_flush_en && is_younger(tag_q[t], i_flush_tag, i_head_tag)));
      // Retirement on the flush-sampling edge wins over its pending removal.
      live_d[t] = live_q[t] && !(flush_pending_q[t] && !retired_q[t]) &&
                  !(i_done_valid && i_done_idx == IdxW'(t));
      // Retired entries cannot be flushed. Quiet depends only on retirement
      // and completion, including a retirement on this edge.
      retired_d[t] = (retired_q[t] || retiring[t]) && !(i_done_valid && i_done_idx == IdxW'(t));
      if (i_alloc_valid && !o_full && o_alloc_idx == IdxW'(t)) begin
        live_d[t] = 1'b1;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      live_q <= '0;
      flush_pending_q <= '0;
      retired_q <= '0;
      known_q <= '0;
      gen_q <= '0;
      o_quiet_q <= 1'b1;
    end else begin
      live_q <= live_d;
      flush_pending_q <= flush_pending_d;
      retired_q <= retired_d;
      o_quiet_q <= !(|retired_d);
      for (int t = 0; t < VMT; t++) begin
        if (i_alloc_valid && !o_full && o_alloc_idx == IdxW'(t)) begin
          tag_q[t]   <= i_alloc_tag;
          gen_q[t]   <= gen_q[t] + 2'd1;
          known_q[t] <= 1'b0;
        end else if (i_range_valid && i_range_idx == IdxW'(t) && live_q[t] && !known_q[t]) begin
          known_q[t] <= 1'b1;
          seg0_q[t]  <= i_range_seg0;
          seg1_q[t]  <= i_range_seg1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // Dispatch holds a vector load or store while the table is full.
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      p_vmt_alloc_not_full : assert (!(i_alloc_valid && o_full));
      p_vmt_alloc_not_flushed : assert (!(i_alloc_valid && i_flush_all));
    end
  end
`endif

  for (genvar t = 0; t < VMT; t++) begin : gen_view
    assign o_view[EntW*t+:EntW] = {
      live_q[t], retired_q[t], tag_q[t], known_q[t], seg1_q[t], seg0_q[t]
    };
  end
  assign o_gen = gen_q;

endmodule
