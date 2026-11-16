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
  Range-ordering holds (vec_hold_rows) against a ghost program.

  Scalar entries and vector memory table entries are allocated in program
  order, up to two per cycle (slot 1 older), into entries that are invalid, so
  every reuse has an invalid cycle. Each carries a ghost sequence number; its
  ROB tag is the low bits. The head only passes a table entry by retiring it,
  the window from the head to the newest tag stays inside the tag space, a
  table entry's range is set once and then fixed, and a scalar entry's address
  is written once. Frees are unconstrained (completion, flush), and a flush
  may roll the next tag back to just after the surviving entries, with no
  allocation in its cycle. A table entry younger than that point may stay
  live and unretired for the cycle after the flush and is then freed, as
  the table frees a flushed entry (formal/vec_vmt_formal.sv proves that
  lifecycle, with the entry keeping its tag). Addresses and
  ranges are confined to four pages. Each scalar index keeps one address,
  while a vector range can change until published and after index reuse. The sequence starts anywhere, so tags wrap within a few
  frames. Two scalar and two table entries (D, V) keep the bounded check
  tractable; the rule is per pair, and both sizes still give an older and a
  younger neighbour and index reuse.

  For every valid scalar entry i and live table entry t older than it in
  program order:
    p_hold:      atomic, unknown address, unknown range or a shared byte
                 implies a hold;
  and conversely
    p_no_spurious: a hold has such a cause, with the address and range known
                 for the cycles the registered overlap needs (one edge for
                 the update port, two for per-entry address inputs).
  Overlap is checked as byte ranges, independently of the module's sector
  compare.
*/
module vec_hold_rows_formal #(
    parameter bit DIRECT_ADDR = 1'b0,
    parameter int unsigned D = 2,
    parameter int unsigned V = 2
) (
    input logic i_clk
);
  localparam int unsigned IW   = D > 1 ? $clog2(D) : 1;
  localparam int unsigned TW   = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned PA   = riscv_pkg::PhysAddrBits;
  localparam int unsigned PW   = riscv_pkg::VmtPpnBits;
  localparam int unsigned EW   = riscv_pkg::VmtEntryBits;
  localparam int unsigned SW   = 1 + PW + 14;
  localparam int unsigned XLEN = riscv_pkg::XLEN;

  logic rst = 1'b1;
  always_ff @(posedge i_clk) rst <= 1'b0;

  // The ghost sequence starts anywhere (below the 8-bit wrap for the depth
  // run), so ROB tags wrap from the first frames.
  (* anyconst *) logic [7:0] seq_start;
  always_comb assume (seq_start < 8'd200);

  // Free choices each cycle
  (* anyseq *) logic a1_en, a1_vec, a2_en, a2_vec, a1_atomic, a2_atomic, a1_block, a2_block;
  (* anyseq *) logic [1:0] a1_idx, a2_idx;
  (* anyseq *) logic [D-1:0] s_free;
  (* anyseq *) logic [V-1:0] v_free, v_retire, v_rng;
  // A range can change before publication and between allocations.
  (* anyseq *) logic [V-1:0] rng_v0, rng_v1;
  // Four pages, built narrow so the high address bits are constant zero.
  (* anyseq *) logic [V-1:0][1:0] rng_p0n, rng_p1n;
  logic [V-1:0][PW-1:0] rng_p0, rng_p1;
  always_comb
    for (int t = 0; t < V; t++) begin
      rng_p0[t] = PW'(rng_p0n[t]);
      rng_p1[t] = PW'(rng_p1n[t]);
    end
  (* anyseq *) logic [V-1:0][6:0] rng_lo0, rng_hi0, rng_lo1, rng_hi1;
  (* anyseq *) logic [1:0] head_step;
  // Address updates: one per cycle through the update port, any subset at
  // once with per-entry addresses (the SQ has two early ports and the MEM_RS
  // port).
  (* anyseq *) logic [D-1:0] upd_mask;
  // A flush rolls the next tag back to any point after the surviving entries.
  (* anyseq *) logic rb_en;
  (* anyseq *) logic [7:0] rb_to;
  logic upd_en;
  logic [IW-1:0] upd_idx;
  always_comb begin
    upd_en  = |upd_mask;
    upd_idx = '0;
    for (int i = 0; i < D; i++) if (upd_mask[i]) upd_idx = IW'(i);
  end
  (* anyconst *)logic [D-1:0][  13:0] addr_n;
  logic [D-1:0][PA-1:0] addr_c;
  always_comb for (int i = 0; i < D; i++) addr_c[i] = PA'(addr_n[i]);
  (* anyconst *) logic [D-1:0][1:0] size_c;
  wire [PA-1:0] upd_addr = addr_c[upd_idx];
  wire [1:0] upd_size = size_c[upd_idx];

  // Ghost state
  logic [7:0] gseq, gh;
  logic [D-1:0] s_valid, s_atomic, s_block, s_ak, s_valid_p, s_ak_p, s_ak_pp;
  logic [D-1:0][7:0] s_seq;
  logic [V-1:0] v_live, v_ret, v_known, v_known_p;
  // A table entry the last flush removed, live for its cleanup cycle.
  logic [V-1:0] v_pend;
  logic [V-1:0][7:0] v_seq;

  wire a2_go = a1_en && a2_en;
  wire [1:0] n_alloc = {1'b0, a1_en} + {1'b0, a2_go};

  // Allocation and event legality
  always_comb begin
    if (!rst) begin
      if (a1_en) assume (a1_idx < 2'(a1_vec ? V : D));
      if (a2_go) assume (a2_idx < 2'(a2_vec ? V : D));
      if (a1_en) assume (a1_vec ? !v_live[a1_idx] : !s_valid[a1_idx]);
      if (a2_go) assume (a2_vec ? !v_live[a2_idx] : !s_valid[a2_idx]);
      if (a2_go && a1_vec == a2_vec) assume (a1_idx != a2_idx);
      // The newest tag stays inside the tag space from this cycle's head (the
      // module compares against it in the new entry's first cycle): at most
      // 2**TW entries from the head to the newest.
      if (a1_en) assume (8'(gseq + 8'(n_alloc) - 8'd1 - gh) < 8'(1 << TW));
      if (rb_en) begin
        assume (!a1_en);
        assume (rb_to <= gseq && rb_to >= 8'(gh + head_step));
        for (int i = 0; i < D; i++) if (s_valid[i] && !s_free[i]) assume (s_seq[i] < rb_to);
      end
      // A table entry the flush removes is freed on that edge or the next.
      for (int t = 0; t < V; t++) if (v_pend[t]) assume (v_free[t]);
      for (int i = 0; i < D; i++) if (s_free[i]) assume (s_valid[i]);
      for (int t = 0; t < V; t++) begin
        if (v_free[t]) assume (v_live[t]);
        // Retire on the edge the head passes the entry (commit).
        if (v_retire[t]) assume (v_live[t] && !v_ret[t] && v_seq[t] < 8'(gh + head_step));
        if (v_rng[t]) assume (v_live[t] && !v_known[t]);
        assume (rng_lo0[t] <= rng_hi0[t] && rng_lo1[t] <= rng_hi1[t]);
        // The head never passes an unretired live entry.
        if (v_live[t] && !v_ret[t] && !v_retire[t]) assume (v_seq[t] >= 8'(gh + head_step));
      end
      assume (8'(gh + head_step) <= gseq);
      if (!DIRECT_ADDR) assume ($onehot0(upd_mask));
      for (int i = 0; i < D; i++) if (upd_mask[i]) assume (s_valid[i] && !s_ak[i]);
    end
  end

  always_ff @(posedge i_clk) begin
    if (rst) begin
      gseq <= seq_start;
      gh <= seq_start;
      s_valid <= '0;
      s_ak <= '0;
      s_valid_p <= '0;
      s_ak_p <= '0;
      s_ak_pp <= '0;
      v_live <= '0;
      v_ret <= '0;
      v_known <= '0;
      v_known_p <= '0;
      v_pend <= '0;
    end else begin
      gseq <= rb_en ? rb_to : gseq + 8'(n_alloc);
      gh <= gh + 8'(head_step);
      s_valid_p <= s_valid;
      s_ak_p <= s_ak;
      s_ak_pp <= s_ak_p;
      v_known_p <= v_known;
      for (int i = 0; i < D; i++) begin
        if (s_free[i]) begin
          s_valid[i] <= 1'b0;
          s_ak[i] <= 1'b0;
        end else if (upd_mask[i]) begin
          s_ak[i] <= 1'b1;
        end
      end
      for (int t = 0; t < V; t++) begin
        v_pend[t] <= rb_en && v_live[t] && !v_free[t] && v_seq[t] >= rb_to;
        if (v_free[t]) begin
          v_live[t]  <= 1'b0;
          v_ret[t]   <= 1'b0;
          v_known[t] <= 1'b0;
        end else begin
          if (v_retire[t]) v_ret[t] <= 1'b1;
          if (v_rng[t]) begin
            v_known[t] <= 1'b1;
          end
        end
      end
      if (a1_en) begin
        if (a1_vec) begin
          v_live[a1_idx]  <= 1'b1;
          v_ret[a1_idx]   <= 1'b0;
          v_known[a1_idx] <= 1'b0;
          v_seq[a1_idx]   <= gseq;
        end else begin
          s_valid[a1_idx] <= 1'b1;
          s_ak[a1_idx] <= 1'b0;
          s_atomic[a1_idx] <= a1_atomic;
          s_block[a1_idx] <= DIRECT_ADDR && a1_block;
          s_seq[a1_idx] <= gseq;
        end
      end
      if (a2_go) begin
        if (a2_vec) begin
          v_live[a2_idx]  <= 1'b1;
          v_ret[a2_idx]   <= 1'b0;
          v_known[a2_idx] <= 1'b0;
          v_seq[a2_idx]   <= gseq + 8'd1;
        end else begin
          s_valid[a2_idx] <= 1'b1;
          s_ak[a2_idx] <= 1'b0;
          s_atomic[a2_idx] <= a2_atomic;
          s_block[a2_idx] <= DIRECT_ADDR && a2_block;
          s_seq[a2_idx] <= gseq + 8'd1;
        end
      end
    end
  end

  // Published ranges remain fixed until the entry is freed. Unknown ranges
  // and reuse are unconstrained, so the overlap pipeline sees changing input.
  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (past_valid && !rst && !$past(rst)) begin
      for (int t = 0; t < V; t++) begin
        if (v_live[t] && $past(v_live[t] && v_known[t])) begin
          assume ($stable(
              {
                rng_v0[t],
                rng_v1[t],
                rng_p0n[t],
                rng_p1n[t],
                rng_lo0[t],
                rng_hi0[t],
                rng_lo1[t],
                rng_hi1[t]
              }
          ));
        end
      end
    end
  end

  // The module's inputs
  logic [D*TW-1:0] tag_flat;
  logic [D*XLEN-1:0] addr_flat;
  logic [D*2-1:0] size_flat;
  logic [V*EW-1:0] vmt;
  for (genvar i = 0; i < D; i++) begin : gen_s
    assign tag_flat[TW*i+:TW] = s_seq[i][TW-1:0];
    assign addr_flat[XLEN*i+:XLEN] = XLEN'(addr_c[i]);
    assign size_flat[2*i+:2] = size_c[i];
  end
  for (genvar t = 0; t < V; t++) begin : gen_v
    assign vmt[EW*t+:EW] = {
      v_live[t],
      v_ret[t],
      v_seq[t][TW-1:0],
      v_known[t],
      rng_v1[t],
      rng_p1[t],
      rng_lo1[t],
      rng_hi1[t],
      rng_v0[t],
      rng_p0[t],
      rng_lo0[t],
      rng_hi0[t]
    };
  end

  logic [D-1:0] hold;
  vec_hold_rows #(
      .DEPTH(D),
      .DIRECT_ADDR(DIRECT_ADDR),
      .VMT(V)
  ) dut (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid(s_valid),
      .i_tag_flat(tag_flat),
      .i_atomic(s_atomic),
      .i_block_flat(s_block),
      .i_head_tag(gh[TW-1:0]),
      .i_upd_valid(!DIRECT_ADDR && upd_en),
      .i_upd_idx(upd_idx),
      .i_upd_addr(XLEN'(upd_addr)),
      .i_upd_size(upd_size),
      .i_addr_flat(addr_flat),
      .i_size_flat(size_flat),
      .i_addr_valid(s_ak & s_valid),
      .i_vmt(vmt),
      .o_hold_d(hold)
  );

  // Byte-range overlap of scalar entry i with table entry t.
  function automatic logic seg_hit(input logic [PA-1:0] a, input logic [1:0] sz,
                                   input logic block_access, input logic v, input logic [PW-1:0] p,
                                   input logic [6:0] lo, input logic [6:0] hi);
    logic [PA-1:0] a_start, a_end, r_start, r_end;
    a_start = block_access ? a - (a % 64) : a;
    a_end   = block_access ? a_start + 63 : a + PA'((1 << sz) - 1);
    r_start = {p, lo, 5'd0};
    r_end   = {p, hi, 5'd31};
    seg_hit = v && a_start <= r_end && a_end >= r_start;
  endfunction

  logic [D-1:0][V-1:0] older, cause, cause_settled;
  logic [D-1:0] ak_settled;
  always_comb begin
    for (int i = 0; i < D; i++) begin
      ak_settled[i] = DIRECT_ADDR ? (s_valid_p[i] && s_ak_pp[i]) : (s_valid_p[i] && s_ak_p[i]);
      for (int t = 0; t < V; t++) begin
        logic ovl;
        ovl = seg_hit(addr_c[i], size_c[i], s_block[i], rng_v0[t], rng_p0[t], rng_lo0[t],
                      rng_hi0[t]) ||
            seg_hit(addr_c[i], size_c[i], s_block[i], rng_v1[t], rng_p1[t], rng_lo1[t], rng_hi1[t]);
        older[i][t] = s_valid[i] && v_live[t] && v_seq[t] < s_seq[i];
        cause[i][t] = older[i][t] && (s_atomic[i] || !s_ak[i] || !v_known[t] || ovl);
        cause_settled[i][t] = older[i][t] &&
            (s_atomic[i] || !ak_settled[i] || !v_known_p[t] || ovl);
      end
    end
  end

  logic [D-1:0] cause_any, cause_settled_any;
  always_comb
    for (int i = 0; i < D; i++) begin
      cause_any[i] = |cause[i];
      cause_settled_any[i] = |cause_settled[i];
    end
  always_comb begin
    if (!rst) begin
      p_hold : assert ((cause_any & ~hold) == '0);
      p_no_spurious : assert ((hold & ~cause_settled_any) == '0);
      // Conditional progress: once every vector entry is free, no scalar
      // row can retain a hold. Completion itself requires memory fairness.
      p_release_after_free : assert (|v_live || hold == '0);
    end
  end

  // Row cases
  logic [D-1:0] hold_p, hold_pp;
  always_ff @(posedge i_clk) begin
    hold_p  <= rst ? '0 : hold;
    hold_pp <= rst ? '0 : hold_p;
  end
  logic freed_known_q = 1'b0;
  logic [6:0] freed_lo_q;
  always_ff @(posedge i_clk) begin
    if (rst) freed_known_q <= 1'b0;
    else if (v_free[0] && v_known[0]) begin
      freed_known_q <= 1'b1;
      freed_lo_q <= rng_lo0[0];
    end
  end
  logic slot2_pair_q;
  always_ff @(posedge i_clk) slot2_pair_q <= !rst && a2_go && a1_vec && !a2_vec && a2_idx == 2'd0;
  always_comb begin
    if (!rst) begin
      c_range_reuse : cover (freed_known_q && v_live[0] && v_known[0] && rng_lo0[0] != freed_lo_q);
      if (DIRECT_ADDR)
        c_block_neighbor :
        cover (s_block[0] && hold[0] && !s_atomic[0] && ak_settled[0] && v_known_p[0] &&
          older[0][0] && rng_v0[0] && addr_c[0][PA-1:12] == rng_p0[0] &&
          (addr_c[0][11:5] ^ 7'd1) == rng_lo0[0] && rng_lo0[0] == rng_hi0[0] &&
          !seg_hit(
            addr_c[0], size_c[0], 1'b0, rng_v0[0], rng_p0[0], rng_lo0[0], rng_hi0[0]
        ));
      // A table entry in slot 1 holds a scalar entry allocated in slot 2.
      c_same_cycle_slot2 : cover (slot2_pair_q && hold[0]);
      // An entry that was held is freed and reallocated behind a younger
      // live table entry, and is not held.
      c_free_realloc : cover (s_valid[0] && !s_valid_p[0] && hold_pp[0] && !hold[0] && |v_live);
      // A held entry is released while its older table entry is still live
      // (range and address now known, no overlap).
      c_unknown_to_known : cover (s_valid_p[0] && hold_p[0] && !hold[0] && |older[0]);
      // An older unretired table entry whose tag is numerically larger
      // (wrapped) holds the entry.
      c_tag_wrap :
      cover (hold[0] && older[0][0] && !v_ret[0] && v_seq[0][TW-1:0] > s_seq[0][TW-1:0]);
      // A retired table entry holds an entry allocated after it retired.
      c_retired : cover (hold[1] && older[1][1] && v_ret[1] && !s_valid_p[1] && s_valid[1]);
      // A flushed table entry in its cleanup cycle overlaps a scalar entry
      // whose address has settled, and does not hold it.
      c_late_free :
      cover (v_pend[0] && v_known_p[0] && s_valid[0] && ak_settled[0] && !s_atomic[0] &&
             !hold[0] && (seg_hit(
          addr_c[0], size_c[0], s_block[0], rng_v0[0], rng_p0[0], rng_lo0[0], rng_hi0[0]
      ) || seg_hit(
          addr_c[0], size_c[0], s_block[0], rng_v1[0], rng_p1[0], rng_lo1[0], rng_hi1[0]
      )));
      // A scalar entry is allocated in the cleanup cycle.
      c_cleanup_alloc : cover (|v_pend && a1_en && !a1_vec);
    end
  end

endmodule
