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
 * async_fifo: valid/ready FIFO between unrelated clocks.
 *
 * Gray-coded pointers cross through two-flop synchronizers (cdc_sync), so
 * the clocks may have any ratio and phase; storage is the dual-clock block
 * RAM sdp_block_ram_dc. The RAM's read is registered, so the read side runs
 * a two-entry output skid over it: a read is issued (the read pointer
 * advances) only when the skid can absorb the word that arrives one cycle
 * later, o_data/o_valid come from the skid's head and stay stable while
 * i_ready is low, and a word is never presented twice or skipped.
 *
 * o_ready is computed from the write pointer and the synchronized read
 * pointer, which lags: the writer sees at most the true occupancy, never
 * less, so the FIFO cannot overflow. READY_MARGIN entries are kept free
 * below full for a writer whose valid trails its ready decision.
 *
 * Resets are per side and synchronous in their domain; each side's reset
 * clears its pointer, its synchronizer copies, and (on the read side) the
 * skid and any read in flight, so no old word can reappear. Both sides
 * must be reset for one overlapping window with no traffic, which the
 * NIC's reset controller sequences (a side that leaves reset first sees the
 * other's pointer at zero and its own at zero: empty).
 */
module async_fifo #(
    parameter int unsigned DATA_WIDTH = 68,
    parameter int unsigned DEPTH = 512,
    parameter int unsigned READY_MARGIN = 2
) (
    // Write side.
    input  logic                  i_clk,
    input  logic                  i_rst,
    input  logic [DATA_WIDTH-1:0] i_data,
    input  logic                  i_valid,
    output logic                  o_ready,
    // Read side.
    input  logic                  o_clk,
    input  logic                  o_rst,
    output logic [DATA_WIDTH-1:0] o_data,
    output logic                  o_valid,
    input  logic                  i_ready
);
  localparam int unsigned AddrBits = $clog2(DEPTH);
  localparam int unsigned PtrBits = AddrBits + 1;

  initial begin
    if ((1 << AddrBits) != DEPTH) $fatal(1, "async_fifo: DEPTH must be a power of two");
    if (DEPTH < 4) $fatal(1, "async_fifo: DEPTH must be >= 4");
    if (READY_MARGIN + 1 >= DEPTH) $fatal(1, "async_fifo: READY_MARGIN too large");
  end

  function automatic logic [PtrBits-1:0] bin2gray(input logic [PtrBits-1:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic logic [PtrBits-1:0] gray2bin(input logic [PtrBits-1:0] g);
    logic [PtrBits-1:0] b;
    b[PtrBits-1] = g[PtrBits-1];
    for (int i = int'(PtrBits) - 2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    gray2bin = b;
  endfunction

  // ---- write side ------------------------------------------------------------
  logic [PtrBits-1:0] wptr_bin_q, wptr_gray_q;
  logic [PtrBits-1:0] rptr_gray_w, rptr_bin_w;
  cdc_sync #(
      .WIDTH(PtrBits)
  ) sync_rptr (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_async(rptr_gray_q),
      .o_sync (rptr_gray_w)
  );
  assign rptr_bin_w = gray2bin(rptr_gray_w);
  logic [PtrBits-1:0] occupancy_w;
  assign occupancy_w = wptr_bin_q - rptr_bin_w;
  assign o_ready = !i_rst && (occupancy_w < PtrBits'(DEPTH - READY_MARGIN));
  logic push;
  assign push = i_valid && o_ready;
  logic [PtrBits-1:0] wptr_next;
  assign wptr_next = wptr_bin_q + 1'b1;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wptr_bin_q  <= '0;
      wptr_gray_q <= '0;
    end else if (push) begin
      wptr_bin_q  <= wptr_next;
      wptr_gray_q <= bin2gray(wptr_next);
    end
  end

  // ---- storage -----------------------------------------------------------------
  logic [PtrBits-1:0] rptr_bin_q, rptr_gray_q;
  logic [DATA_WIDTH-1:0] ram_rdata;
  sdp_block_ram_dc #(
      .ADDR_WIDTH(AddrBits),
      .DATA_WIDTH(DATA_WIDTH)
  ) storage (
      .i_write_clock  (i_clk),
      .i_read_clock   (o_clk),
      .i_write_enable (push),
      .i_write_address(wptr_bin_q[AddrBits-1:0]),
      .i_read_address (rptr_bin_q[AddrBits-1:0]),
      .i_write_data   (i_data),
      .o_read_data    (ram_rdata)
  );

  // ---- read side -------------------------------------------------------------
  logic [PtrBits-1:0] wptr_gray_r, wptr_bin_r;
  cdc_sync #(
      .WIDTH(PtrBits)
  ) sync_wptr (
      .i_clk  (o_clk),
      .i_rst  (o_rst),
      .i_async(wptr_gray_q),
      .o_sync (wptr_gray_r)
  );
  assign wptr_bin_r = gray2bin(wptr_gray_r);
  logic empty;
  assign empty = (rptr_bin_q == wptr_bin_r);

  // Output skid: entry 0 is the head (o_data), entry 1 the tail. A read
  // issued this cycle lands one cycle later (rd_issued_q), and is issued
  // only when the skid will have room for it.
  logic [1:0] skid_valid_q;
  logic [DATA_WIDTH-1:0] skid_data_q[2];
  logic rd_issued_q;
  logic [1:0] skid_count;
  assign skid_count = {1'b0, skid_valid_q[0]} + {1'b0, skid_valid_q[1]};
  logic rd_issue, pop;
  assign rd_issue = !empty && ((skid_count + {1'b0, rd_issued_q}) < 2'd2);
  assign pop = skid_valid_q[0] && i_ready;

  logic [1:0] skid_valid_n;
  logic [DATA_WIDTH-1:0] skid_data_n[2];
  always_comb begin
    skid_valid_n = skid_valid_q;
    skid_data_n  = skid_data_q;
    if (pop) begin
      skid_valid_n[0] = skid_valid_q[1];
      skid_data_n[0]  = skid_data_q[1];
      skid_valid_n[1] = 1'b0;
    end
    if (rd_issued_q) begin
      if (!skid_valid_n[0]) begin
        skid_valid_n[0] = 1'b1;
        skid_data_n[0]  = ram_rdata;
      end else begin
        skid_valid_n[1] = 1'b1;
        skid_data_n[1]  = ram_rdata;
      end
    end
  end

  logic [PtrBits-1:0] rptr_next;
  assign rptr_next = rptr_bin_q + 1'b1;
  always_ff @(posedge o_clk) begin
    if (o_rst) begin
      rptr_bin_q   <= '0;
      rptr_gray_q  <= '0;
      rd_issued_q  <= 1'b0;
      skid_valid_q <= '0;
    end else begin
      rd_issued_q  <= rd_issue;
      skid_valid_q <= skid_valid_n;
      skid_data_q  <= skid_data_n;
      if (rd_issue) begin
        rptr_bin_q  <= rptr_next;
        rptr_gray_q <= bin2gray(rptr_next);
      end
    end
  end
  assign o_valid = skid_valid_q[0];
  assign o_data  = skid_data_q[0];

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge o_clk) begin
    if (!o_rst && rd_issued_q && (skid_count == 2'd2) && !pop)
      $error("async_fifo: read arrived with no skid room");
  end
`endif
`endif
`ifdef FORMAL
  // Bounded proof under free-running unrelated clocks (sby: multiclock on).
  // Both resets are held for the first steps and then released for good;
  // the checks are on the true pointers and a watched word. The registers
  // start at their reset values: a synchronous reset needs an edge of its
  // clock, and formal may schedule none during the reset window.
  initial begin
    wptr_bin_q   = '0;
    wptr_gray_q  = '0;
    rptr_bin_q   = '0;
    rptr_gray_q  = '0;
    rd_issued_q  = 1'b0;
    skid_valid_q = '0;
  end
  logic [3:0] f_step;
  initial f_step = '0;
  always @($global_clock) if (f_step != 4'hF) f_step <= f_step + 1'b1;
  always_comb begin
    if (f_step < 4'd6)
      assume (i_rst && o_rst);
      else assume (!i_rst && !o_rst);
  end

  logic [PtrBits-1:0] f_occupancy;
  assign f_occupancy = wptr_bin_q - rptr_bin_q;
  always_comb begin
    if (f_step >= 4'd6) begin
      // Never more words in the RAM than it holds, never a read of an
      // empty RAM (the synchronized write pointer only lags the true one).
      f_occupancy_bound : assert (f_occupancy <= PtrBits'(DEPTH));
      f_no_underflow : assert (!(rd_issue && (wptr_bin_q == rptr_bin_q)));
      // Gray codes always decode back to the binary pointers.
      f_wgray : assert (wptr_gray_q == bin2gray(wptr_bin_q));
      f_rgray : assert (rptr_gray_q == bin2gray(rptr_bin_q));
      // The skid never holds a tail without a head.
      f_skid_shape : assert (!(skid_valid_q[1] && !skid_valid_q[0]));
    end
  end

  // Watched word: the f_watch-th word pushed must be the f_watch-th word
  // popped, with its data intact.
  (* anyconst *) logic [PtrBits-1:0] f_watch;
  logic [PtrBits-1:0] f_pushes, f_pops;
  logic f_seen, f_delivered;
  logic [DATA_WIDTH-1:0] f_data;
  initial begin
    f_pushes = '0;
    f_pops = '0;
    f_seen = 1'b0;
    f_delivered = 1'b0;
  end
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_pushes <= '0;
      f_seen   <= 1'b0;
    end else if (push) begin
      f_pushes <= f_pushes + 1'b1;
      if (f_pushes == f_watch) begin
        f_seen <= 1'b1;
        f_data <= i_data;
      end
    end
  end
  always @(posedge o_clk) begin
    if (o_rst) begin
      f_pops      <= '0;
      f_delivered <= 1'b0;
    end else if (pop) begin
      f_pops <= f_pops + 1'b1;
      if (f_pops == f_watch) begin
        f_delivered <= 1'b1;
        f_watched_word_in_order : assert (f_seen);
        f_watched_word_intact : assert (o_data == f_data);
      end
    end
  end
  always_comb begin
    if (f_step >= 4'd6) begin
      f_pops_never_lead :
      assert (f_pops - f_pushes == '0 || f_pushes - f_pops <= PtrBits'(DEPTH + 2));
    end
  end
  always @(posedge o_clk) begin
    if (!o_rst) begin
      cover_watched_delivered : cover (f_delivered);
      // The writer stops READY_MARGIN below the RAM's capacity.
      cover_full_and_stalled : cover ((f_occupancy == PtrBits'(DEPTH - READY_MARGIN)) && !i_ready);
    end
  end
`endif
endmodule : async_fifo
