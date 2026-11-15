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
  The vector memory table (vec_vmt) against a ghost program.

  The environment is a reorder buffer: instructions take consecutive ghost
  sequence numbers (the ROB tag is the low bits), a vector memory instruction
  is the first of its dispatch group and allocates only while the table is not
  full, the head passes instructions in order and passes a vector memory
  instruction alone through the combinational commit bus, nothing allocates or
  commits during a flush, a full flush removes everything behind the head, a
  partial flush everything younger than its tag, the window from the head to
  the newest tag stays inside the tag space, and the memory unit completes an
  entry only after it has retired. Range writes are unconstrained, so writes to
  a known or free entry are tried too. The sequence starts anywhere, so tags
  wrap within a few frames.

  The properties are the lifecycle the range-ordering holds rely on
  (formal/vec_hold_rows_formal.sv assumes them of its table):
    p_alloc_free     an index is allocated only when it was free before the
                     edge, so a freed index has an invalid cycle before reuse;
    p_live           an entry is live exactly from its allocation until its
                     completion or a flush that removes its instruction;
  and, per entry (gen_entry_props), a live entry carries its instruction's tag
  (program order), is retired exactly when the head has passed its
  instruction (so an unretired live entry is never behind the head), and has
  its range written once while live and then fixed;
    p_quiet          the registered "no live retired entry" output is exact
                     on every cycle (V-O4);
    p_full           the dispatch stall term is exact.
*/
module vec_vmt_formal (
    input logic i_clk
);
  localparam int unsigned V  = riscv_pkg::VmtDepth;
  localparam int unsigned TW = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned IW = $clog2(riscv_pkg::VmtDepth);
  localparam int unsigned SW = 1 + riscv_pkg::VmtPpnBits + 14;
  localparam int unsigned EW = riscv_pkg::VmtEntryBits;

  logic rst = 1'b1;
  always_ff @(posedge i_clk) rst <= 1'b0;

  (* anyconst *) logic [7:0] seq_start;
  always_comb assume (seq_start < 8'd200);

  // Free choices each cycle
  (* anyseq *) logic alloc_en, flush_all, flush_en, rng_en, done_en;
  (* anyseq *) logic [1:0] n_other, head_step;
  (* anyseq *) logic [7:0] flush_seq;
  (* anyseq *) logic [IW-1:0] rng_idx, done_idx;
  // Narrow range values, zero-extended (wide free inputs only slow the check)
  (* anyseq *) logic [3:0] rng_a, rng_b;
  wire [SW-1:0] seg0_in = SW'(rng_a);
  wire [SW-1:0] seg1_in = SW'(rng_b);

  // Ghost program state
  logic [7:0] gseq, gh;
  logic [V-1:0] g_live, g_ret, g_known;
  logic [V-1:0][7:0] g_seq;
  logic [V-1:0][SW-1:0] g_seg0, g_seg1;

  // The module
  logic full, quiet;
  logic [IW-1:0] alloc_idx;
  riscv_pkg::vmt_view_t view;
  logic [V-1:0][1:0] gen;
  logic commit_valid;
  vec_vmt dut (
      .i_clk         (i_clk),
      .i_rst         (rst),
      .i_alloc_valid (alloc_en),
      .i_alloc_tag   (gseq[TW-1:0]),
      .o_full        (full),
      .o_alloc_idx   (alloc_idx),
      .i_commit_valid(commit_valid),
      .i_commit_tag  (gh[TW-1:0]),
      .i_flush_all   (flush_all),
      .i_flush_en    (flush_en),
      .i_flush_tag   (flush_seq[TW-1:0]),
      .i_head_tag    (gh[TW-1:0]),
      .i_range_valid (rng_en),
      .i_range_idx   (rng_idx),
      .i_range_seg0  (seg0_in),
      .i_range_seg1  (seg1_in),
      .i_done_valid  (done_en),
      .i_done_idx    (done_idx),
      .o_view        (view),
      .o_gen         (gen),
      .o_quiet_q     (quiet)
  );

  // The head passes a live unretired entry's instruction only by committing
  // it alone.
  logic [V-1:0] passing;
  always_comb
    for (int t = 0; t < V; t++)
      passing[t] = g_live[t] && !g_ret[t] && (g_seq[t] < 8'(gh + 8'(head_step)));
  assign commit_valid = |passing;

  // Environment
  always_comb begin
    if (!rst) begin
      assume (!(flush_all && flush_en));
      if (flush_all || flush_en) assume (!alloc_en && n_other == 2'd0 && head_step == 2'd0);
      if (flush_en) assume (flush_seq >= gh && flush_seq < gseq);
      if (alloc_en) assume (!full);
      assume (8'(gh + 8'(head_step)) <= gseq);
      assume (8'(gseq + 8'(alloc_en) + 8'(n_other) - gh) <= 8'(1 << TW));
      for (int t = 0; t < V; t++) if (passing[t]) assume (head_step == 2'd1 && g_seq[t] == gh);
      if (done_en) assume (g_live[done_idx] && g_ret[done_idx]);
    end
  end

  always_ff @(posedge i_clk) begin
    if (rst) begin
      gseq <= seq_start;
      gh <= seq_start;
      g_live <= '0;
      g_ret <= '0;
      g_known <= '0;
    end else begin
      gh <= gh + 8'(head_step);
      if (flush_all) gseq <= gh;
      else if (flush_en) gseq <= flush_seq + 8'd1;
      else gseq <= gseq + 8'(alloc_en) + 8'(n_other);
      for (int t = 0; t < V; t++) begin
        if (passing[t]) g_ret[t] <= 1'b1;
        if (g_live[t] && !g_ret[t] && (flush_all || (flush_en && g_seq[t] > flush_seq))) begin
          g_live[t]  <= 1'b0;
          g_known[t] <= 1'b0;
        end
        if (rng_en && rng_idx == IW'(t) && g_live[t] && !g_known[t]) begin
          g_known[t] <= 1'b1;
          g_seg0[t]  <= seg0_in;
          g_seg1[t]  <= seg1_in;
        end
      end
      if (done_en) begin
        g_live[done_idx]  <= 1'b0;
        g_ret[done_idx]   <= 1'b0;
        g_known[done_idx] <= 1'b0;
      end
      if (alloc_en) begin
        g_live[alloc_idx]  <= 1'b1;
        g_ret[alloc_idx]   <= 1'b0;
        g_known[alloc_idx] <= 1'b0;
        g_seq[alloc_idx]   <= gseq;
      end
    end
  end

  // The table's fields by offset (riscv_pkg::vmt_entry_t)
  logic [V-1:0] live, retired, known;
  logic [V-1:0][TW-1:0] tag;
  logic [V-1:0][SW-1:0] seg0, seg1;
  for (genvar t = 0; t < V; t++) begin : gen_fields
    assign live[t] = view[EW*t+2*SW+TW+2];
    assign retired[t] = view[EW*t+2*SW+TW+1];
    assign tag[t] = view[EW*t+2*SW+1+:TW];
    assign known[t] = view[EW*t+2*SW];
    assign seg1[t] = view[EW*t+SW+:SW];
    assign seg0[t] = view[EW*t+:SW];
  end

  always_comb begin
    if (!rst) begin
      if (alloc_en) p_alloc_free : assert (!g_live[alloc_idx]);
      p_live : assert (live == g_live);
      p_full : assert (full == &g_live);
      p_quiet : assert (quiet == !(|(g_live & g_ret)));
    end
  end
  for (genvar t = 0; t < V; t++) begin : gen_entry_props
    always_comb begin
      if (!rst && g_live[t]) begin
        assert (tag[t] == g_seq[t][TW-1:0]);
        assert (retired[t] == (g_seq[t] < gh));
        assert (known[t] == g_known[t]);
        if (g_known[t]) assert (seg0[t] == g_seg0[t] && seg1[t] == g_seg1[t]);
      end
    end
  end

  // Reachability
  logic quiet_p, full_seen;
  always_ff @(posedge i_clk) begin
    quiet_p   <= rst ? 1'b1 : quiet;
    full_seen <= !rst && (full_seen || full);
  end
  always_comb begin
    if (!rst) begin
      // The table fills, and an entry later completes and is reused.
      c_full_then_reuse : cover (full_seen && alloc_en && g_live != '0);
      // A partial flush removes one entry and keeps an older one.
      c_partial_keeps_older :
      cover (flush_en && |(g_live & ~g_ret & {V{1'b1}}) && g_live[0] && g_live[1] &&
             g_seq[0] <= flush_seq && g_seq[1] > flush_seq);
      // V-O4: quiet falls when an entry retires and rises at its completion.
      c_quiet_cycle : cover (!quiet_p && quiet && |gen);
      // An unretired entry whose tag is numerically below the head's (wrapped)
      // survives a partial flush.
      c_tag_wrap :
      cover (flush_en && g_live[0] && !g_ret[0] && g_seq[0] <= flush_seq &&
                          g_seq[0][TW-1:0] < gh[TW-1:0]);
    end
  end

endmodule
