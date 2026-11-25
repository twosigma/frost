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
 * Decoupled front-end parcel queue with zero-cycle empty and partial bypass.
 *
 * Stores up to DEPTH (16) halfword parcels in four parity-interleaved FF banks
 * (four entries per bank) so up to four parcels push and four head parcels
 * read concurrently without multi-port RAMs. Per-bank read and write row
 * indices are registered so read addresses have no adder on the lookup path.
 *
 * Window-level metadata (META_DEPTH = 8 entries) is stored in two even/odd
 * distributed RAM banks (four entries per bank), exposing both the head
 * window's metadata (o_meta0) and the following window's metadata (o_meta1)
 * simultaneously with zero-cycle bypass when queued windows are empty or one
 * deep. Each parcel carries a last-of-window marker; popping a marked parcel
 * frees its metadata entry.
 *
 * Registered backpressure o_stop_fetch asserts when next occupancy reaches
 * STOP_PARCEL_THRESH (8) or STOP_META_THRESH (6), leaving headroom for both
 * the arriving window and one in-flight fetch. Flush clears all pointers,
 * counts, and o_stop_fetch synchronously.
 */
module fetch_parcel_queue #(
    parameter int unsigned PARCEL_WIDTH = 96,
    parameter int unsigned META_WIDTH = 64,
    parameter int unsigned DEPTH = 16,
    parameter int unsigned META_DEPTH = 8,
    parameter int unsigned STOP_PARCEL_THRESH = 8,
    parameter int unsigned STOP_META_THRESH = 6
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,

    // Push interface (up to 4 packed halfword parcels + 1 window metadata entry)
    input logic                         i_push_valid,
    input logic [                  2:0] i_push_count,   // 1..4 when i_push_valid
    input logic [3:0][PARCEL_WIDTH-1:0] i_push_parcels,
    input logic [       META_WIDTH-1:0] i_push_meta,

    // Pop interface (0..4 parcels consumed by drain this cycle)
    input logic [2:0] i_pop_count,

    // Head view (0..3) with zero-cycle empty and partial bypass
    output logic [                  4:0] o_avail,
    output logic [                  3:0] o_avail_ge,     // [k]: o_avail >= k + 1
    output logic [3:0][PARCEL_WIDTH-1:0] o_view_parcels,
    output logic [                  3:0] o_view_last,
    // Ring-only last-of-window flags and occupancy qualifiers for metadata select
    output logic [                  1:0] o_ring_last,
    output logic                         o_count_eq1,
    output logic                         o_count_ge2,

    // Head window metadata and next-window metadata (with bypass)
    output logic [META_WIDTH-1:0] o_meta0,
    output logic [META_WIDTH-1:0] o_meta1,

    // Registered fetch backpressure (cleared synchronously on flush/reset)
    output logic o_stop_fetch
);

  localparam int unsigned PtrBits = $clog2(DEPTH);            // 4
  localparam int unsigned CountBits = PtrBits + 1;            // 5
  localparam int unsigned BankRows = DEPTH / 4;               // 4
  localparam int unsigned RowBits = $clog2(BankRows);         // 2
  localparam int unsigned EntryBits = PARCEL_WIDTH + 1;       // {last_of_window, parcel}

  localparam int unsigned MetaPtrBits = $clog2(META_DEPTH);   // 3
  localparam int unsigned MetaCountBits = MetaPtrBits + 1;    // 4
  localparam int unsigned MetaBankBits = MetaPtrBits - 1;     // 2

  // ===========================================================================
  // Parcel Ring State (4 banks x BankRows entries in FFs, no reset on data)
  // ===========================================================================
  (* ram_style = "registers" *) logic [EntryBits-1:0] ring_q[4][BankRows];
  logic [PtrBits-1:0] head_q;
  logic [PtrBits-1:0] tail_q;
  logic [CountBits-1:0] count_q;
  logic [3:0][RowBits-1:0] rd_row_q;
  logic [3:0][RowBits-1:0] wr_row_q;

  // ===========================================================================
  // Window Metadata Ring State (2 banks x META_DEPTH/2 entries in dist RAM)
  // ===========================================================================
  logic [MetaPtrBits-1:0] meta_head_q;
  logic [MetaPtrBits-1:0] meta_tail_q;
  logic [MetaCountBits-1:0] meta_count_q;
  logic [MetaBankBits-1:0] meta_head_even_idx_q;
  logic stop_fetch_q;

  logic [META_WIDTH-1:0] meta_bank_rd[2];
  logic [MetaBankBits-1:0] meta_bank_raddr[2];
  assign meta_bank_raddr[0] = meta_head_even_idx_q;
  assign meta_bank_raddr[1] = meta_head_q[MetaPtrBits-1:1];

  for (genvar mb = 0; mb < 2; mb++) begin : gen_meta_bank
    logic mb_we;
    // Flush clears meta_count_q and meta_tail_q on the same edge, so writes
    // during a flush target unused slots and need not gate on !i_flush.
    assign mb_we = i_push_valid && (meta_tail_q[0] == 1'(mb));

    sdp_dist_ram #(
        .ADDR_WIDTH(MetaBankBits),
        .DATA_WIDTH(META_WIDTH)
    ) u_meta_ram (
        .i_clk,
        .i_write_enable(mb_we),
        .i_write_address(meta_tail_q[MetaPtrBits-1:1]),
        .i_write_data(i_push_meta),
        .i_read_address(meta_bank_raddr[mb]),
        .o_read_data(meta_bank_rd[mb])
    );
  end

  // ===========================================================================
  // Combinational Head View with Zero-Cycle Empty and Partial Bypass
  // ===========================================================================
  // Keep i_flush off the combinational count/view/next-state paths: flush
  // synchronously clears all pointers, counts, and stop_fetch_q at the flop.
  logic [2:0] push_cnt_eff;
  assign push_cnt_eff = i_push_valid ? i_push_count : 3'd0;

  logic [CountBits-1:0] avail_sum;
  assign avail_sum = count_q + CountBits'(push_cnt_eff);
  assign o_avail   = avail_sum;

  for (genvar k = 0; k < 4; k++) begin : gen_avail_ge
    assign o_avail_ge[k] = avail_sum >= CountBits'(k + 1);
  end

  // Read one entry per bank using precomputed row pointers from the FF ring,
  // then rotate by head_q[1:0].
  logic [EntryBits-1:0] bank_rd[4];
  for (genvar b = 0; b < 4; b++) begin : gen_bank_rd
    assign bank_rd[b] = ring_q[b][rd_row_q[b]];
  end

  logic [EntryBits-1:0] ring_view[4];
  logic [EntryBits-1:0] push_entries[4];
  for (genvar k = 0; k < 4; k++) begin : gen_view
    logic [1:0] src_bank;
    logic [1:0] push_idx;
    logic from_ring;
    logic is_push_last;

    assign src_bank = head_q[1:0] + 2'(k);
    assign ring_view[k] = bank_rd[src_bank];

    assign is_push_last = (3'(k) == (i_push_count - 3'd1));
    assign push_entries[k] = {is_push_last, i_push_parcels[k]};

    assign from_ring = CountBits'(k) < count_q;
    // When !from_ring, count_q is in 0..k <= 3, so k - count_q[1:0] selects the bypassed parcel.
    assign push_idx = 2'(k) - count_q[1:0];

    assign o_view_parcels[k] = from_ring ?
        ring_view[k][PARCEL_WIDTH-1:0] : i_push_parcels[push_idx];
    assign o_view_last[k] = from_ring ?
        ring_view[k][PARCEL_WIDTH] : push_entries[push_idx][PARCEL_WIDTH];
  end

  assign o_ring_last = {ring_view[1][PARCEL_WIDTH], ring_view[0][PARCEL_WIDTH]};
  assign o_count_eq1 = (count_q == CountBits'(1));
  assign o_count_ge2 = (count_q >= CountBits'(2));

  // Head and next-window metadata with zero-cycle bypass when queued windows <= 1.
  logic [META_WIDTH-1:0] meta_ring0;
  logic [META_WIDTH-1:0] meta_ring1;
  assign meta_ring0 = meta_head_q[0] ? meta_bank_rd[1] : meta_bank_rd[0];
  assign meta_ring1 = meta_head_q[0] ? meta_bank_rd[0] : meta_bank_rd[1];

  assign o_meta0 = (meta_count_q == '0) ? i_push_meta : meta_ring0;
  assign o_meta1 = (meta_count_q <= MetaCountBits'(1)) ? i_push_meta : meta_ring1;

  assign o_stop_fetch = stop_fetch_q;

  // ===========================================================================
  // Next-State Pointers, Counts, and Backpressure
  // ===========================================================================
  logic [2:0] pop_cnt_eff;
  assign pop_cnt_eff = i_pop_count;

  logic [3:0] pop_last_mask;
  logic [2:0] meta_freed;
  for (genvar k = 0; k < 4; k++) begin : gen_pop_last
    assign pop_last_mask[k] = (3'(k) < pop_cnt_eff) && o_view_last[k];
  end
  assign meta_freed = 3'(pop_last_mask[0]) + 3'(pop_last_mask[1]) +
                      3'(pop_last_mask[2]) + 3'(pop_last_mask[3]);

  logic [PtrBits-1:0] head_next;
  logic [PtrBits-1:0] tail_next;
  logic [CountBits-1:0] count_next;
  assign head_next  = head_q + PtrBits'(pop_cnt_eff);
  assign tail_next  = tail_q + PtrBits'(push_cnt_eff);
  assign count_next = avail_sum - CountBits'(pop_cnt_eff);

  logic meta_push_eff;
  logic [MetaPtrBits-1:0] meta_head_next;
  logic [MetaPtrBits-1:0] meta_head_plus1_next;
  logic [MetaPtrBits-1:0] meta_tail_next;
  logic [MetaCountBits-1:0] meta_count_next;
  assign meta_push_eff        = i_push_valid;
  assign meta_head_next       = meta_head_q + MetaPtrBits'(meta_freed);
  assign meta_head_plus1_next = meta_head_q + MetaPtrBits'(meta_freed) + MetaPtrBits'(1);
  assign meta_tail_next       = meta_tail_q + MetaPtrBits'(meta_push_eff);
  assign meta_count_next      = meta_count_q + MetaCountBits'(meta_push_eff) - MetaCountBits'(meta_freed);

  // Keep meta_freed off stop_fetch_q by using pre-pop metadata occupancy while
  // keeping exact post-pop parcel occupancy (count_next >= STOP_PARCEL_THRESH)
  // so steady-state two-wide draining never triggers spurious fetch pauses.
  logic stop_fetch_next;
  assign stop_fetch_next = (count_next >= CountBits'(STOP_PARCEL_THRESH)) ||
                           ((meta_count_q + MetaCountBits'(meta_push_eff)) >=
                            MetaCountBits'(STOP_META_THRESH));

  // Per-bank write controls (at most one write per bank per cycle since push_count <= 4).
  logic [3:0] bank_we;
  logic [EntryBits-1:0] bank_wdata[4];
  for (genvar b = 0; b < 4; b++) begin : gen_bank_wr
    logic [1:0] wr_off;
    assign wr_off = 2'(b) - tail_q[1:0];
    // Flush clears count_q and tail_q on the same edge; keep !i_flush off the write enables.
    assign bank_we[b] = i_push_valid && (3'(wr_off) < i_push_count);
    assign bank_wdata[b] = push_entries[wr_off];
  end

  always_ff @(posedge i_clk) begin
    for (int b = 0; b < 4; b++) begin
      if (bank_we[b]) begin
        ring_q[b][wr_row_q[b]] <= bank_wdata[b];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      head_q               <= '0;
      tail_q               <= '0;
      count_q              <= '0;
      rd_row_q             <= '0;
      wr_row_q             <= '0;
      meta_head_q          <= '0;
      meta_tail_q          <= '0;
      meta_count_q         <= '0;
      meta_head_even_idx_q <= '0;
      stop_fetch_q         <= 1'b0;
    end else begin
      head_q               <= head_next;
      tail_q               <= tail_next;
      count_q              <= count_next;
      meta_head_q          <= meta_head_next;
      meta_tail_q          <= meta_tail_next;
      meta_count_q         <= meta_count_next;
      meta_head_even_idx_q <= meta_head_plus1_next[MetaPtrBits-1:1];
      stop_fetch_q         <= stop_fetch_next;
      for (int b = 0; b < 4; b++) begin
        rd_row_q[b] <= head_next[PtrBits-1:2] + ((2'(b) < head_next[1:0]) ? RowBits'(1) : '0);
        wr_row_q[b] <= tail_next[PtrBits-1:2] + ((2'(b) < tail_next[1:0]) ? RowBits'(1) : '0);
      end
    end
  end

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst && !i_flush) begin
      if (!$isunknown({i_push_valid, i_push_count, count_q, i_pop_count, meta_count_q})) begin
        p_push_count_range : assert (!i_push_valid || (i_push_count >= 3'd1 && i_push_count <= 3'd4));
        p_pop_within_avail : assert (CountBits'(i_pop_count) <= avail_sum);
        p_no_parcel_overflow : assert (avail_sum <= CountBits'(DEPTH));
        p_no_meta_overflow :
        assert ((meta_count_q + MetaCountBits'(i_push_valid)) <= MetaCountBits'(META_DEPTH));
        p_no_meta_underflow :
        assert (MetaCountBits'(meta_freed) <= (meta_count_q + MetaCountBits'(i_push_valid)));
      end
    end
  end
`endif

`ifdef FORMAL
  // ===========================================================================
  // Formal Model (formal/fetch_parcel_queue.sby)
  // ===========================================================================
  // Track an arbitrary watched parcel slot and an arbitrary watched window
  // metadata slot with (* anyconst *) indices against the banked FF/dist-RAM
  // implementation across arbitrary pushes, pops, bypasses, and flushes.
  logic f_past_valid = 1'b0;
  logic [PtrBits-1:0] f_watch_idx;
  logic [MetaPtrBits-1:0] f_watch_midx;
  always_ff @(posedge i_clk) begin
    f_watch_idx  <= f_watch_idx;
    f_watch_midx <= f_watch_midx;
  end

  logic f_watch_valid_q;
  logic [PARCEL_WIDTH-1:0] f_watch_parcel_q;
  logic f_watch_last_q;
  logic [PtrBits-1:0] f_head_q;
  logic [PtrBits-1:0] f_tail_q;
  logic [CountBits-1:0] f_count_q;

  logic f_mwatch_valid_q;
  logic [META_WIDTH-1:0] f_mwatch_meta_q;
  logic [MetaPtrBits-1:0] f_mhead_q;
  logic [MetaPtrBits-1:0] f_mtail_q;
  logic [MetaCountBits-1:0] f_mcount_q;

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
  end

  // Legal environment protocol
  always_comb begin
    if (!i_rst) begin
      if (i_push_valid) assume (i_push_count >= 3'd1 && i_push_count <= 3'd4);
      assume (i_pop_count <= 3'd4);
      if (!i_flush) begin
        assume (CountBits'(i_pop_count) <= avail_sum);
        // Backpressure contract: caller respects headroom so ring never overflows.
        assume (avail_sum <= CountBits'(DEPTH));
        assume ((f_mcount_q + MetaCountBits'(i_push_valid)) <= MetaCountBits'(META_DEPTH));
      end
    end
  end

  logic f_watch_popped;
  logic f_mwatch_popped;
  assign f_watch_popped = f_watch_valid_q &&
      (CountBits'(PtrBits'(f_watch_idx - f_head_q)) < CountBits'(pop_cnt_eff));
  assign f_mwatch_popped = f_mwatch_valid_q &&
      (MetaCountBits'(MetaPtrBits'(f_watch_midx - f_mhead_q)) < MetaCountBits'(meta_freed));

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      f_head_q         <= '0;
      f_tail_q         <= '0;
      f_count_q        <= '0;
      f_watch_valid_q  <= 1'b0;
      f_watch_parcel_q <= '0;
      f_watch_last_q   <= 1'b0;
      f_mhead_q        <= '0;
      f_mtail_q        <= '0;
      f_mcount_q       <= '0;
      f_mwatch_valid_q <= 1'b0;
      f_mwatch_meta_q  <= '0;
    end else begin
      if (f_watch_popped) f_watch_valid_q <= 1'b0;
      if (f_mwatch_popped) f_mwatch_valid_q <= 1'b0;
      if (i_push_valid) begin
        for (int k = 0; k < 4; k++) begin
          if ((3'(k) < i_push_count) && (PtrBits'(f_tail_q + PtrBits'(k)) == f_watch_idx)) begin
            // If this pushed parcel is bypassed and popped in the same cycle,
            // it does not remain resident in the ring.
            if ((f_count_q + CountBits'(k)) >= CountBits'(pop_cnt_eff)) begin
              f_watch_valid_q  <= 1'b1;
              f_watch_parcel_q <= i_push_parcels[k];
              f_watch_last_q   <= (3'(k) == (i_push_count - 3'd1));
            end
          end
        end
        if (f_mtail_q == f_watch_midx) begin
          if ((f_mcount_q + MetaCountBits'(1)) > MetaCountBits'(meta_freed)) begin
            f_mwatch_valid_q <= 1'b1;
            f_mwatch_meta_q  <= i_push_meta;
          end
        end
      end
      f_head_q   <= f_head_q + PtrBits'(pop_cnt_eff);
      f_tail_q   <= f_tail_q + PtrBits'(push_cnt_eff);
      f_count_q  <= f_count_q + CountBits'(push_cnt_eff) - CountBits'(pop_cnt_eff);
      f_mhead_q  <= f_mhead_q + MetaPtrBits'(meta_freed);
      f_mtail_q  <= f_mtail_q + MetaPtrBits'(meta_push_eff);
      f_mcount_q <= f_mcount_q + MetaCountBits'(meta_push_eff) - MetaCountBits'(meta_freed);
    end
  end

  always_comb begin
    if (f_past_valid && !i_rst) begin
      p_f_counts_match : assert (count_q == f_count_q && meta_count_q == f_mcount_q);
      p_f_ptrs_match :
      assert (head_q == f_head_q && tail_q == f_tail_q &&
              meta_head_q == f_mhead_q && meta_tail_q == f_mtail_q);
      p_f_avail_exact :
      assert (o_avail == (f_count_q + CountBits'(push_cnt_eff)));
      p_f_meta_even_idx :
      assert (meta_head_even_idx_q ==
              (meta_head_q[MetaPtrBits-1:1] + MetaBankBits'(meta_head_q[0])));
      if (f_mcount_q >= MetaCountBits'(1)) begin
        if (f_mhead_q == f_watch_midx) begin
          p_f_meta0_ring : assert (f_mwatch_valid_q && (o_meta0 == f_mwatch_meta_q));
        end
      end else if (meta_push_eff) begin
        p_f_meta0_bypass : assert (o_meta0 == i_push_meta);
      end
      if (f_mcount_q >= MetaCountBits'(2)) begin
        if (MetaPtrBits'(f_mhead_q + MetaPtrBits'(1)) == f_watch_midx) begin
          p_f_meta1_ring : assert (f_mwatch_valid_q && (o_meta1 == f_mwatch_meta_q));
        end
      end else if (meta_push_eff) begin
        p_f_meta1_bypass : assert (o_meta1 == i_push_meta);
      end
    end
  end

  for (genvar b = 0; b < 4; b++) begin : gen_f_row_check
    always_comb begin
      if (f_past_valid && !i_rst) begin
        p_f_rd_row :
        assert (rd_row_q[b] ==
                (head_q[PtrBits-1:2] + ((2'(b) < head_q[1:0]) ? RowBits'(1) : '0)));
        p_f_wr_row :
        assert (wr_row_q[b] ==
                (tail_q[PtrBits-1:2] + ((2'(b) < tail_q[1:0]) ? RowBits'(1) : '0)));
      end
    end
  end

  for (genvar k = 0; k < 4; k++) begin : gen_f_view_check
    always_comb begin
      if (f_past_valid && !i_rst && o_avail_ge[k]) begin
        if (CountBits'(k) < f_count_q) begin
          if (PtrBits'(f_head_q + PtrBits'(k)) == f_watch_idx) begin
            p_f_view_ring_exact :
            assert (f_watch_valid_q &&
                    o_view_parcels[k] == f_watch_parcel_q &&
                    o_view_last[k] == f_watch_last_q);
          end
        end else begin
          p_f_view_bypass_exact :
          assert (o_view_parcels[k] == i_push_parcels[2'(k) - f_count_q[1:0]] &&
                  o_view_last[k] == (3'(2'(k) - f_count_q[1:0]) == (i_push_count - 3'd1)));
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && $past(i_flush || i_rst)) begin
      p_f_flush_clears_stop_fetch : assert (!o_stop_fetch && count_q == '0 && meta_count_q == '0);
    end
    if (f_past_valid && !i_rst && !i_flush) begin
      // Cover zero-cycle empty bypass, partial bypass, wraparound, and backpressure.
      cover (count_q == '0 && i_push_valid && i_pop_count == 3'd2);
      cover (count_q == 5'd1 && i_push_valid && i_pop_count == 3'd3);
      cover (meta_freed == 3'd2);
      cover (o_stop_fetch);
      cover (head_q == 4'd15 && o_avail_ge[3]);
    end
  end
`endif

endmodule : fetch_parcel_queue
