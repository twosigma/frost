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
 * fetch_provider -- the variable-latency fetch window provider.
 *
 * Serves the high-address side of the core's fetch seam
 * ({instr64, sideband16, bank_sel_r} + valid) from a two-line fetch buffer
 * over the L1I line port.  The low instruction BRAM fast path is selected in
 * cpu_and_mem and drives imem_predecode directly from o_pc; this block never
 * drives the low-BRAM address pins.  Each filled line carries per-word
 * predecode sideband computed on fill (imem_predecode_line), so DDR code
 * predecodes bit-identically to BRAM code.  The buffer's two slots are
 * parity-mapped (line address bit 0), so the current line and the prefetched
 * next line can never collide, and a window spanning a line boundary always
 * has both halves resident before valid asserts.
 *
 * FETCH CONTRACT (established with the core in if_stage):
 *   The provider owns the 1-deep OWED-ASK register.  Each served cycle
 *   latches the live PC as the next owed ask; while unserved the ask holds,
 *   retargeting only when the PC moves between two unserved cycles AND the
 *   movement was not a stall-replay consumption (the registered
 *   i_fetch_replay_consume classifies that) -- every other unserved-cycle
 *   movement is a backend redirect, because the core holds the PC otherwise.
 *   The window data and the address it was fetched for are registered
 *   together.  A window publishes valid only when that served-address tag still
 *   matches the owed ask (with the same registered-stall lag as the simulation
 *   fuzz wrapper in cpu_and_mem), so redirected stale data can sit on the
 *   payload wires without being accepted as the new ask's instruction.
 *
 * MISS ENGINE: single-outstanding line-port master.  Wanted line = the
 * window's first absent line, else the following line (prefetch) -- one rule
 * covers both straddle completion and next-line prefetch.  A fill that is in
 * flight when the ask retargets completes into its slot (the line protocol
 * has no abort); a fill in flight across i_invalidate completes DISCARDED so
 * pre-invalidate data can never re-validate a slot (fence.i relies on this).
 */
module fetch_provider #(
    parameter int unsigned LINE_BYTES = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Core fetch seam.  i_fetch_replay_consume is REGISTERED by the core
    // (the consume happened LAST cycle): it only classifies the PC movement
    // observed this cycle as flow rather than redirect -- the owed ask
    // itself needs no update because o_pc stays frozen at it through any
    // stall the replay bundle survives.
    input logic [31:0] i_pc,
    input logic i_fetch_replay_consume,
    // Front-end pipeline stall (cpu_ooo pipeline_ctrl.stall).  While high the
    // decode cannot consume a window: publish-valid is withheld and the owed
    // ask is held, so a window the stalled decode cannot accept is never
    // presented (nor drifted to the leading PC).  Feeds publish-valid and the
    // owed-ask bookkeeping only -- never the imem/fill address path.
    input logic i_pipeline_stall,
    output logic [63:0] o_instr,
    output logic [riscv_pkg::ImemFetchSidebandWidth-1:0] o_instr_sideband,
    output logic o_instr_bank_sel_r,
    output logic o_instr_valid,

    // L1I line port (master; read-only -- write/wdata/wstrb tied inactive).
    output logic o_line_req_valid,
    input logic i_line_req_ready,
    output logic o_line_req_write,
    output logic [31:0] o_line_req_addr,
    output logic [LINE_BYTES*8-1:0] o_line_req_wdata,
    output logic [LINE_BYTES-1:0] o_line_req_wstrb,
    input logic i_line_resp_valid,
    input logic [LINE_BYTES*8-1:0] i_line_resp_rdata,

    // Drop both buffer lines (fence.i; reset also invalidates).
    input logic i_invalidate
);

  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);  // 5 for 32 B
  localparam int unsigned LineAddrBits = 32 - OffsetBits;
  localparam int unsigned WordsPerLine = LINE_BYTES / 4;
  localparam int unsigned WordSelBits = $clog2(WordsPerLine);
  localparam int unsigned SbWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned LineSbBits = WordsPerLine * SbWidth;

  // ===========================================================================
  // Owed-ask tracking
  // ===========================================================================
  logic [31:0] ask_q;  // the address whose window is owed/presented
  logic [31:0] pc_prev_q;
  logic accepted_prev_q;

  // ACCEPTED, not merely served: a window presented (o_instr_valid high) on a
  // cycle the front end was stalled was NOT consumed.  Keying the owed-ask
  // bookkeeping off "accepted" (valid AND not stalled) keeps a redirect that
  // lands the cycle after a stall-presented window from being misread as flow
  // -- see retarget_now.
  logic accepted_now;
  assign accepted_now = o_instr_valid && !i_pipeline_stall;

  // Retarget: the PC moved between two un-accepted cycles -- a backend redirect
  // (the core's hold arms keep the PC still on every other un-accepted cycle,
  // and a replay consumption's advance is classified out by the registered
  // i_fetch_replay_consume).
  logic retarget_now;
  assign retarget_now = !accepted_prev_q && !i_fetch_replay_consume && (i_pc != pc_prev_q);

  // The ask presented this cycle; its window is due (and its validity is
  // decided) for the next cycle.
  logic [31:0] fetch_addr;
  // TIMING: neither the retarget 32-bit compare nor the pipeline stall lives in
  // this combinational mux; both would otherwise stack with the presence
  // compares into the fill path.  The low BRAM address pins are not driven from
  // this mux: cpu_and_mem keeps that path direct from o_pc.  The stall gates
  // only publish-valid (below): while stalled o_instr_valid is held low, so
  // this mux holds ask_q and the owed window persists for the stalled decode
  // instead of advancing to the leading PC.  On a retarget cycle this address
  // is the stale old ask for one extra cycle; the window it yields is squashed
  // by the core's control-flow holdoff, which the redirect that caused the
  // retarget has already armed and which extends through no-progress cycles.
  assign fetch_addr = o_instr_valid ? i_pc : ask_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ask_q           <= '0;
      pc_prev_q       <= '0;
      accepted_prev_q <= 1'b0;
    end else begin
      ask_q           <= (o_instr_valid || retarget_now) ? i_pc : ask_q;
      pc_prev_q       <= i_pc;
      accepted_prev_q <= accepted_now;
    end
  end

  // ===========================================================================
  // Two-line fetch buffer (parity-mapped slots) + per-word sideband
  // ===========================================================================
  logic [1:0] slot_valid_q;
  logic [1:0][LineAddrBits-1:0] slot_line_q;
  logic [1:0][LineBits-1:0] slot_data_q;
  logic [1:0][LineSbBits-1:0] slot_sb_q;

  // The window's two word addresses (current word + next word).
  logic [31:0] win_addr0, win_addr1;
  assign win_addr0 = {fetch_addr[31:2], 2'b00};
  assign win_addr1 = win_addr0 + 32'd4;

  logic [LineAddrBits-1:0] win_line0, win_line1;
  assign win_line0 = win_addr0[31:OffsetBits];
  assign win_line1 = win_addr1[31:OffsetBits];

  logic present0, present1;
  assign present0 = slot_valid_q[win_line0[0]] && (slot_line_q[win_line0[0]] == win_line0);
  assign present1 = slot_valid_q[win_line1[0]] && (slot_line_q[win_line1[0]] == win_line1);

  // Word extraction for the (about to be registered) DDR window.
  logic [WordSelBits-1:0] word_sel0, word_sel1;
  assign word_sel0 = win_addr0[2+:WordSelBits];
  assign word_sel1 = win_addr1[2+:WordSelBits];

  logic [31:0] ddr_word0, ddr_word1;
  logic [SbWidth-1:0] ddr_sb0, ddr_sb1;
  assign ddr_word0 = slot_data_q[win_line0[0]][word_sel0*32+:32];
  assign ddr_word1 = slot_data_q[win_line1[0]][word_sel1*32+:32];
  assign ddr_sb0   = slot_sb_q[win_line0[0]][word_sel0*SbWidth+:SbWidth];
  assign ddr_sb1   = slot_sb_q[win_line1[0]][word_sel1*SbWidth+:SbWidth];

  // ===========================================================================
  // Window readiness (computed for the presented ask, registered with its tag)
  // ===========================================================================
  logic fetch_high;
  assign fetch_high = fetch_addr[31];

  logic window_ready;
  assign window_ready = fetch_high && present0 && present1;

  // Registered high-address window.  An invalidate kills the in-flight
  // validity so a pre-invalidate window is never consumed.
  logic [63:0] ddr_instr_q;
  logic [2*SbWidth-1:0] ddr_sb_pair_q;
  logic bank_sel_q;
  logic [31:0] served_addr_q;
  logic window_ready_q;
  logic pipeline_stall_q;

  // Withhold publish-valid while the front end is stalled (above): the owed
  // window stays parked (fetch_addr holds ask_q) and is published only when
  // the decode can accept it, so a miss that completes mid-stall delivers the
  // owed window on release rather than flashing it for one unconsumable cycle
  // and then drifting to the leading PC.  The registered stall preserves the
  // IF stage's first-cycle stall capture; the replay path holds fetch_progress
  // for the rest of the stall.
  assign o_instr_valid = served_addr_q[31] && window_ready_q && (served_addr_q == ask_q) &&
      !pipeline_stall_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      window_ready_q   <= 1'b0;
      pipeline_stall_q <= 1'b0;
    end else begin
      window_ready_q   <= window_ready;
      pipeline_stall_q <= i_pipeline_stall;
    end
    served_addr_q <= fetch_addr;
    bank_sel_q    <= fetch_addr[2];
    ddr_instr_q   <= {ddr_word1, ddr_word0};
    ddr_sb_pair_q <= {ddr_sb1, ddr_sb0};
  end

  assign o_instr = ddr_instr_q;
  assign o_instr_sideband = ddr_sb_pair_q;
  assign o_instr_bank_sel_r = bank_sel_q;

  // ===========================================================================
  // Miss engine: single-outstanding line fills + next-line prefetch
  // ===========================================================================
  // One rule covers straddle completion and prefetch: fetch the window's
  // first line if absent, else the following line (which is the straddle's
  // second half when the window crosses, and the prefetch otherwise).
  // The fill engine works from the REGISTERED ask only (its own presence
  // comparators), so the o_pc/served muxing never reaches the line-port
  // request logic.  On ask transitions the wanted line lags one cycle --
  // noise against a multi-cycle miss.
  logic [LineAddrBits-1:0] fill_line0, fill_line_after;
  assign fill_line0 = ask_q[31:OffsetBits];
  assign fill_line_after = fill_line0 + 1'b1;

  logic fill_present0, fill_present_after;
  assign fill_present0 = slot_valid_q[fill_line0[0]] && (slot_line_q[fill_line0[0]] == fill_line0);
  assign fill_present_after = slot_valid_q[fill_line_after[0]] &&
      (slot_line_q[fill_line_after[0]] == fill_line_after);

  logic [LineAddrBits-1:0] want_line;
  logic want_fill;
  always_comb begin
    want_line = fill_line0;
    want_fill = 1'b0;
    if (ask_q[31]) begin
      if (!fill_present0) begin
        want_line = fill_line0;
        want_fill = 1'b1;
      end else if (!fill_present_after) begin
        // First ask line resident: fetch the following line -- the
        // straddle's second half when the window crosses, the prefetch
        // otherwise.
        want_line = fill_line_after;
        want_fill = 1'b1;
      end
    end
  end

  logic fill_busy_q;
  logic fill_sent_q;
  logic fill_discard_q;
  logic [LineAddrBits-1:0] fill_line_q;

  assign o_line_req_valid = fill_busy_q && !fill_sent_q;
  assign o_line_req_write = 1'b0;
  assign o_line_req_addr  = {fill_line_q, {OffsetBits{1'b0}}};
  assign o_line_req_wdata = '0;
  assign o_line_req_wstrb = '0;

  // Per-word predecode sideband for the arriving line (combinational on the
  // response data, registered with the line -- the fill is multi-cycle and
  // not latency-critical).
  logic [LineSbBits-1:0] fill_sideband;
  imem_predecode_line #(
      .LINE_BYTES(LINE_BYTES)
  ) fill_predecode (
      .i_line(i_line_resp_rdata),
      .o_sideband(fill_sideband)
  );

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fill_busy_q     <= 1'b0;
      fill_sent_q     <= 1'b0;
      fill_discard_q  <= 1'b0;
      slot_valid_q[0] <= 1'b0;
      slot_valid_q[1] <= 1'b0;
    end else begin
      if (i_invalidate) begin
        slot_valid_q[0] <= 1'b0;
        slot_valid_q[1] <= 1'b0;
        // An in-flight fill must complete (the line port has no abort), but
        // its pre-invalidate data must not re-validate a slot.
        if (fill_busy_q) fill_discard_q <= 1'b1;
      end

      if (!fill_busy_q) begin
        if (want_fill) begin
          fill_busy_q <= 1'b1;
          fill_sent_q <= 1'b0;
          fill_line_q <= want_line;
        end
      end else begin
        if (o_line_req_valid && i_line_req_ready) fill_sent_q <= 1'b1;
        if (i_line_resp_valid) begin
          fill_busy_q <= 1'b0;
          fill_sent_q <= 1'b0;
          if (!fill_discard_q && !i_invalidate) begin
            slot_valid_q[fill_line_q[0]] <= 1'b1;
            slot_line_q[fill_line_q[0]]  <= fill_line_q;
            slot_data_q[fill_line_q[0]]  <= i_line_resp_rdata;
            slot_sb_q[fill_line_q[0]]    <= fill_sideband;
          end
          fill_discard_q <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_line_resp_valid && !fill_busy_q)
        $error("fetch_provider: line response with no fill in flight");
    end
  end
`endif

endmodule : fetch_provider
