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
 * Variable-latency provider for the high-address fetch seam
 * ({instr64, sideband36, hi_rd_is_x2[1:0], bank_sel_r, served word tags} +
 * valid) from a two-line fetch buffer over the L1I line
 * port. cpu_and_mem derives the two hi_rd_is_x2 bits directly from this
 * block's registered instruction payload; this block supplies the other
 * high-address fields. The low instruction BRAM fast path is selected in
 * cpu_and_mem and drives imem_predecode directly from o_pc; this block never
 * drives the low-BRAM address pins. The registered valid also exports its
 * exact non-reset combinational next value so cpu_and_mem can sample a
 * cycle-identical timing twin beside IF without pulling this provider's state
 * flop into the low/default fetch recurrence. Each filled line carries per-word
 * predecode sideband computed on fill (imem_predecode_line), so DDR code
 * predecodes bit-identically to BRAM code. The buffer's two slots are
 * parity-mapped (line address bit 0), so the current line and the prefetched
 * next line can never collide, and a window spanning a line boundary always
 * has both halves resident before valid asserts.
 *
 * Fetch contract (with if_stage):
 *   The provider owns the 1-deep OWED-ASK register.  Each served cycle
 *   latches the live PC as the next owed ask; while unserved the ask holds,
 *   retargeting only when the PC moves on a cycle whose predecessor was not
 *   ACCEPTED (o_instr_valid AND not i_pipeline_stall: a window presented on a
 *   stalled cycle was not consumed) AND the movement was not a stall-replay
 *   consumption (the registered i_fetch_replay_consume classifies that) --
 *   other movement is a backend redirect because the core otherwise holds PC.
 *   The window data and the address it was fetched for are registered
 *   together.  Readiness and the served-address/next-ask match are collapsed
 *   into one registered publishability bit on that same edge.  A redirected
 *   stale window can therefore sit on the payload wires without being accepted
 *   as the new ask's instruction, while the wide tag comparison stays off the
 *   same-cycle fetch-progress -> PC path.
 *
 *   Phase 3 M5 -- physical side.  i_pc is the VIRTUAL fetch address and stays
 *   the window's identity (ask/served tags, retarget compare); the core's
 *   current physical result (i_pa0/i_pa1 for the window's two words,
 *   i_pa_valid, per-word fault flags, i_line_after_ok) is latched with the ask
 *   and is what the buffer lookup and fills use. An ask whose result is not yet
 *   visible forms no window and starts no fill; the core holds its PC at such
 *   an ask, so the ask keeps re-sampling the live pair until it resolves. A
 *   faulted word needs no fill at all: the window is "ready" with the flag set
 *   and IF delivers the fault-tagged bundle. Ordinary redirects are detected
 *   from unaccepted live-PC movement. i_retarget is the narrower registered
 *   architectural/epoch pulse: it covers landed EX/PD recovery, slot-2
 *   prediction, already-emitted no-lead slot-1 prediction, and served-window
 *   resteer following an accepted window, plus trap/xRET/FENCE state changes.
 *   It excludes leading slot-1 prediction so a leading fetch PC cannot abandon
 *   the predicted branch response still owed to pc_reg. The pulse also forces
 *   a re-latch when the VA did not move, so a
 *   translation or cache-state change cannot leave the old physical request in
 *   the ask. With translation off the physical window is derived directly from
 *   the VA with no added bubble.
 *
 * The miss engine is one line-port master per buffer slot, so the window's
 * line and the following line (the straddle's second half when the window
 * crosses, the prefetch otherwise) fill concurrently: each slot's engine
 * fetches the absent candidate of its parity, tagged with the slot number.
 * A fill that is in flight when the ask retargets completes into its slot
 * (the line protocol has no abort); a fill in flight across i_invalidate
 * completes DISCARDED so pre-invalidate data can never re-validate a slot
 * (fence.i relies on this).
 *
 * Behind the two slots sits a VICTIM_LINES-deep victim store: a line a slot
 * replaces is kept there, and a wanted line found there is copied back into
 * its slot in one cycle instead of taking the L1I round trip. Loop bodies of
 * up to 2 + VICTIM_LINES lines therefore re-enter without touching the L1I
 * (with two slots alone, every re-entered line cost a hit round trip even at
 * a 99.8% L1I hit rate). The store is looked up from the registered
 * candidate lines only -- nothing of it reaches the window path -- and an
 * invalidate drops it with the slots.
 */
module fetch_provider #(
    parameter int unsigned LINE_BYTES   = 32,
    // Line-port transaction id width. Each slot's fill engine keeps one fill
    // in flight, tagged with the slot number (ids 0 and 1); the echo is
    // checked in simulation.
    parameter int unsigned LINE_ID_BITS = 3,
    // Victim store behind the two window slots: lines a slot evicts are kept
    // here and copied back in one cycle when wanted again, so a loop body of
    // up to 2 + VICTIM_LINES lines re-enters without an L1I round trip. 0
    // disables the store.
    parameter int unsigned VICTIM_LINES = 6
) (
    input logic i_clk,
    input logic i_rst,

    // Core fetch seam.  i_fetch_replay_consume is REGISTERED by the core
    // (the consume happened LAST cycle): it only classifies the PC movement
    // observed this cycle as flow rather than redirect -- the owed ask
    // itself needs no update because o_pc stays frozen at it through any
    // stall the replay bundle survives.
    input logic [31:0] i_pc,
    // Physical side of the ask (Phase 3 M5, see the contract above).
    input logic [31:0] i_pa0,
    input logic [31:0] i_pa1,
    input logic i_pa_valid,
    input logic i_fault0,
    input logic i_fault0_page,
    input logic i_fault1,
    input logic i_fault1_page,
    input logic i_line_after_ok,
    // Registered landed recovery/emitted-prediction/resteer or
    // translation/cache epoch pulse. Leading slot-1 prediction stays on the
    // movement detector below.
    input logic i_retarget,
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
    // Payload-aligned word tags. IF compares the provider-local S/S+1/S-1
    // registers without rebuilding address arithmetic in its PC cone.
    output logic [29:0] o_served_word,
    output logic [29:0] o_served_last_word,
    output logic [29:0] o_served_prev_word,
    output logic o_served_prev_word_valid,
    // Per-word fault flags of the served window ({fault, page kind}).
    output logic o_served_fault0,
    output logic o_served_fault0_page,
    output logic o_served_fault1,
    output logic o_served_fault1_page,
    output logic o_instr_valid,
    // Exact non-reset D input of the registered publish-valid result.
    // cpu_and_mem mirrors reset/invalidate around its same-edge physical timing
    // twin; this signal does not add a fetch cycle or change this provider's
    // owed-ask bookkeeping.
    output logic o_instr_valid_next,
    // Passive performance observer: the cache supplies a source-registered
    // "demand miss outstanding" level. This block adds the fetch-progress
    // qualifier so prefetch misses hidden behind a ready window do not count.
    input logic i_l1i_miss_outstanding,
    output logic o_perf_miss_stall,

    // L1I line port (master; read-only -- write/wdata/wstrb tied inactive).
    output logic o_line_req_valid,
    input logic i_line_req_ready,
    output logic o_line_req_write,
    output logic [31:0] o_line_req_addr,
    output logic [LINE_BYTES*8-1:0] o_line_req_wdata,
    output logic [LINE_BYTES-1:0] o_line_req_wstrb,
    output logic [LINE_ID_BITS-1:0] o_line_req_id,
    input logic i_line_resp_valid,
    input logic [LINE_ID_BITS-1:0] i_line_resp_id,
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
  // i_fetch_replay_consume) -- or the core's registered translation/cache
  // epoch pulse. Slot-1 prediction movement deliberately uses the first arm: a
  // broad explicit pulse could abandon the predicted branch response that
  // pc_reg still owes while the fetch PC is already running at its target.
  // Slot-2 and served-window movement are explicit because they can follow an
  // accepted window, where accepted_prev_q deliberately masks movement.
  // RE-SYNC arm (Phase 3 M5): the owed-ask contract is "while unserved the
  // core holds o_pc AT the ask".  A cross-tier page-straddle can break it:
  // o_pc runs one word ahead into a faulting second page, this provider
  // serves the covering straddle window and advances its ask to that lead,
  // then the core resteers o_pc back -- but that resteer rides the cycle
  // after an accepted serve, so accepted_prev_q masks the redirect arm and
  // the ask is stranded on the faulted lead.  A faulted-word0 ask is the
  // ONLY address the cached provider can never make ready (its PA is a low
  // VA -> fetch_high=0), so when this provider's latched ask has a faulted
  // word0 yet o_pc has moved off it, re-sync the ask to o_pc.  A clean ask
  // is served or filled normally (never stranded), and when o_pc == the
  // faulted ask the low-BRAM arm delivers the fault -- so this fires only on
  // the genuine cross-tier strand.
  logic retarget_now;
  assign retarget_now = (!accepted_prev_q && !i_fetch_replay_consume && (i_pc != pc_prev_q)) ||
      i_retarget || (!o_instr_valid && ask_fault0_q && (i_pc != ask_q));

  // Exact next value of ask_q.  Besides keeping the state transition in one
  // place, this lets the window capture below decide on the SAME edge whether
  // the candidate served address will still match the owed ask after both
  // registers advance.
  logic [31:0] ask_d;
  assign ask_d = (o_instr_valid || retarget_now) ? i_pc : ask_q;

  // The ask presented this cycle; its window is due (and its validity is
  // decided) for the next cycle.
  logic [31:0] fetch_addr;
  // SERVE RATE (regression fix): on a serving cycle (o_instr_valid) the window
  // for the core's LIVE next PC must be formed in the SAME cycle, so the next
  // window publishes back-to-back (1 window/cycle).  Forming the window from
  // the registered ask alone (fetch_addr = ask_q, the x3 timing experiment)
  // inserts a dead tag-mismatch cycle after every consume -- HALVING the
  // high/DDR fetch bandwidth.  DDR-resident straight-line code (the no-MMU
  // Linux machine-timer handler, the linux_clksrc_faithful/linux_irq_* /
  // mtimer_stress-in-DDR programs) is fetch-bound: at half rate the
  // trap->handler->MRET round trip and the preempted foreground both slow to
  // the point that a Linux-cadence re-arming timer (deadline ~256..760 cycles)
  // saturates the core and the foreground crawls -> CI timeouts and the
  // hardware IRQ failure.  The x3 WNS cone this reopens (live i_pc ->
  // window_ready_q/ddr_instr_q) must be re-closed by pipelining candidate
  // windows + a late narrow select, not by degrading the serve rate.
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

  // The physical pair of the window being formed (same select as fetch_addr).
  logic [31:0] fetch_pa0, fetch_pa1;
  logic fetch_pa_valid, fetch_fault0, fetch_fault0_page, fetch_fault1, fetch_fault1_page;
  assign fetch_pa0 = o_instr_valid ? i_pa0 : ask_pa0_q;
  assign fetch_pa1 = o_instr_valid ? i_pa1 : ask_pa1_q;
  assign fetch_pa_valid = o_instr_valid ? i_pa_valid : ask_pa_valid_q;
  assign fetch_fault0 = o_instr_valid ? i_fault0 : ask_fault0_q;
  assign fetch_fault0_page = o_instr_valid ? i_fault0_page : ask_fault0_page_q;
  assign fetch_fault1 = o_instr_valid ? i_fault1 : ask_fault1_q;
  assign fetch_fault1_page = o_instr_valid ? i_fault1_page : ask_fault1_page_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ask_q           <= '0;
      pc_prev_q       <= '0;
      accepted_prev_q <= 1'b0;
    end else begin
      ask_q           <= ask_d;
      pc_prev_q       <= i_pc;
      accepted_prev_q <= accepted_now;
    end
  end

  // The ask's physical side: latched with the ask and re-sampled every cycle
  // until the selected-VA result is visible (the core holds o_pc at the ask
  // then, so the live pair is the ask's).
  logic [31:0] ask_pa0_q, ask_pa1_q;
  logic ask_pa_valid_q;
  logic ask_fault0_q, ask_fault0_page_q, ask_fault1_q, ask_fault1_page_q;
  logic ask_after_ok_q;
  logic ask_pa_load;
  assign ask_pa_load = o_instr_valid || retarget_now || !ask_pa_valid_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ask_pa0_q         <= '0;
      ask_pa1_q         <= 32'd4;
      ask_pa_valid_q    <= 1'b0;
      ask_fault0_q      <= 1'b0;
      ask_fault0_page_q <= 1'b0;
      ask_fault1_q      <= 1'b0;
      ask_fault1_page_q <= 1'b0;
      ask_after_ok_q    <= 1'b1;
    end else if (ask_pa_load) begin
      ask_pa0_q         <= i_pa0;
      ask_pa1_q         <= i_pa1;
      ask_pa_valid_q    <= i_pa_valid;
      ask_fault0_q      <= i_fault0;
      ask_fault0_page_q <= i_fault0_page;
      ask_fault1_q      <= i_fault1;
      ask_fault1_page_q <= i_fault1_page;
      ask_after_ok_q    <= i_line_after_ok;
    end
  end

  // ===========================================================================
  // Two-line fetch buffer (parity-mapped slots) + per-word sideband
  // ===========================================================================
  logic [1:0] slot_valid_q;
  logic [1:0][LineAddrBits-1:0] slot_line_q;
  logic [1:0][LineBits-1:0] slot_data_q;
  logic [1:0][LineSbBits-1:0] slot_sb_q;

  // The window's two word addresses (current word + next word), physical.
  // Inside one physical page, aligned word 1 is aligned word 0 + 4; across a
  // translated page boundary it is the mapped next page's base and may be far
  // away.
  logic [31:0] win_addr0, win_addr1;
  assign win_addr0 = {fetch_pa0[31:2], 2'b00};
  assign win_addr1 = {fetch_pa1[31:2], 2'b00};

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
  assign fetch_high = fetch_pa0[31];

  // A faulted word needs no line (its bytes are never used); an unresolved
  // pair forms no window at all.
  logic window_ready;
  assign window_ready = fetch_high && fetch_pa_valid &&
      (fetch_fault0 || (present0 && (fetch_fault1 || present1)));

  // Registered high-address window.  An invalidate kills the in-flight
  // validity so a pre-invalidate window is never consumed. window_ready_q is
  // deliberately the folded "ready AND served tag matches next ask" bit: at
  // the capture edge served_addr_q becomes fetch_addr and ask_q becomes ask_d,
  // so this is bit-identical to comparing those two registers a cycle later.
  logic [63:0] ddr_instr_q;
  logic [2*SbWidth-1:0] ddr_sb_pair_q;
  logic bank_sel_q;
  logic [31:0] served_addr_q;
  logic [29:0] served_last_word_q;
  logic [29:0] served_prev_word_q;
  logic served_prev_word_valid_q;
  logic served_fault0_q, served_fault0_page_q, served_fault1_q, served_fault1_page_q;
  logic window_ready_q;
  logic pipeline_stall_q;

  // Withhold publish-valid while the front end is stalled (above): the owed
  // window stays parked (fetch_addr holds ask_q) and is published only when
  // the decode can accept it, so a miss that completes mid-stall delivers the
  // owed window on release rather than flashing it for one unconsumable cycle
  // and then drifting to the leading PC.  The registered stall preserves the
  // IF stage's first-cycle stall capture; the replay path holds fetch_progress
  // for the rest of the stall.
  // window_ready already contains fetch_addr[31], and the registered folded
  // match below proves that served_addr_q is the address whose readiness was
  // captured.  No live served_addr_q == ask_q comparison is needed here.
  assign o_instr_valid = window_ready_q && !pipeline_stall_q;
  assign o_instr_valid_next = window_ready && (fetch_addr == ask_d) && !i_pipeline_stall;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      window_ready_q   <= 1'b0;
      pipeline_stall_q <= 1'b0;
    end else begin
      window_ready_q   <= window_ready && (fetch_addr == ask_d);
      pipeline_stall_q <= i_pipeline_stall;
    end
    served_addr_q            <= fetch_addr;
    // Window identity stays virtual: word 1 is always VA word 0 + 1.
    served_last_word_q       <= fetch_addr[31:2] + 1'b1;
    served_prev_word_q       <= fetch_addr[31:2] - 1'b1;
    served_prev_word_valid_q <= |fetch_addr[31:2];
    served_fault0_q          <= fetch_fault0;
    served_fault0_page_q     <= fetch_fault0_page;
    served_fault1_q          <= fetch_fault1;
    served_fault1_page_q     <= fetch_fault1_page;
    bank_sel_q               <= fetch_addr[2];
    ddr_instr_q              <= {ddr_word1, ddr_word0};
    ddr_sb_pair_q            <= {ddr_sb1, ddr_sb0};
  end

  assign o_instr = ddr_instr_q;
  assign o_instr_sideband = ddr_sb_pair_q;
  assign o_instr_bank_sel_r = bank_sel_q;
  assign o_served_word = served_addr_q[31:2];
  assign o_served_last_word = served_last_word_q;
  assign o_served_prev_word = served_prev_word_q;
  assign o_served_prev_word_valid = served_prev_word_valid_q;
  assign o_served_fault0 = served_fault0_q;
  assign o_served_fault0_page = served_fault0_page_q;
  assign o_served_fault1 = served_fault1_q;
  assign o_served_fault1_page = served_fault1_page_q;

  // ===========================================================================
  // Miss engines: one fill in flight per slot (window line + following line)
  // ===========================================================================
  // The window's line L and the following line L+1 have opposite parity, so
  // they map to different slots: slot p's engine fetches whichever of the
  // two has parity p when that line is absent. Both may be in flight at once,
  // which hides the second round trip after a redirect to a cold line or a
  // straddling window. The engines work from the REGISTERED ask only (their
  // own presence comparators), so the o_pc/served muxing never reaches the
  // line-port request logic. On ask transitions the wanted line lags one
  // cycle -- noise against a multi-cycle miss.
  // The following line is word 1's line when the window straddles a line
  // boundary (the next page's first line when it also crosses a page --
  // the two always have opposite parity, a page holding an even number of
  // lines), else the physically next line, which may be prefetched only
  // while the core vouches it is inside the page (i_line_after_ok).
  logic [LineAddrBits-1:0] fill_line0, fill_line_after;
  logic fill_straddle;
  assign fill_line0 = ask_pa0_q[31:OffsetBits];
  assign fill_straddle = &ask_pa0_q[OffsetBits-1:2];
  assign fill_line_after = fill_straddle ? ask_pa1_q[31:OffsetBits] : fill_line0 + 1'b1;

  // Candidate line per slot parity, its presence, and whether it may be
  // fetched at all (a faulted word's line never is; the prefetch line only
  // inside the page).
  logic [1:0][LineAddrBits-1:0] cand_line;
  logic [1:0] cand_present;
  logic [1:0] cand_fetchable;
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      if (fill_line0[0] == 1'(p)) begin
        cand_line[p] = fill_line0;
        cand_fetchable[p] = !ask_fault0_q;
      end else begin
        cand_line[p] = fill_line_after;
        cand_fetchable[p] = !ask_fault0_q && (fill_straddle ? !ask_fault1_q : ask_after_ok_q);
      end
      cand_present[p] = slot_valid_q[p] && (slot_line_q[p] == cand_line[p]);
    end
  end

  logic [1:0] fill_busy_q;
  logic [1:0] fill_sent_q;
  logic [1:0] fill_discard_q;
  logic [1:0][LineAddrBits-1:0] fill_line_q;
  (* keep = "true" *) logic perf_miss_stall_q;

  // ---- Victim store ----------------------------------------------------------
  // Lines evicted from a window slot are kept here (round-robin); a wanted
  // line found here is copied into its slot in one cycle instead of being
  // refetched. Lookups use the registered candidate lines only, so nothing
  // here touches the window path. Each line lives in one place: a copied
  // entry is invalidated, and a slot's old line is stored when replaced.
  localparam int unsigned VictimLines = (VICTIM_LINES > 0) ? VICTIM_LINES : 1;
  localparam int unsigned VictimPtrBits = (VictimLines > 1) ? $clog2(VictimLines) : 1;
  logic [VictimLines-1:0] vs_valid_q;
  logic [LineAddrBits-1:0] vs_line_q[VictimLines];
  logic [LineBits-1:0] vs_data_q[VictimLines];
  logic [LineSbBits-1:0] vs_sb_q[VictimLines];
  logic [VictimPtrBits-1:0] vs_wr_ptr_q;
  // Shadow of each slot's previous content, captured by the slot write
  // itself and written into the store a cycle later, so the store's write
  // enable is a registered bit rather than the fill-response cone.
  logic [1:0] ev_pending_q;
  logic [1:0][LineAddrBits-1:0] ev_line_q;
  logic [1:0][LineBits-1:0] ev_data_q;
  logic [1:0][LineSbBits-1:0] ev_sb_q;

  logic [1:0] vs_hit;
  logic [1:0][VictimPtrBits-1:0] vs_hit_idx;
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      vs_hit[p] = 1'b0;
      vs_hit_idx[p] = '0;
      for (int v = 0; v < int'(VictimLines); v++) begin
        if ((VICTIM_LINES > 0) && vs_valid_q[v] && (vs_line_q[v] == cand_line[p])) begin
          vs_hit[p] = 1'b1;
          vs_hit_idx[p] = VictimPtrBits'(v);
        end
      end
    end
  end

  // A wanted candidate: absent from its slot with the slot's engine free.
  // From the store it is copied (one slot per cycle, never in a cycle a
  // fill response lands or an invalidate fires, so the single victim write
  // port and the slot write are uncontended); otherwise it is fetched.
  logic [1:0] want_cand, want_fill, copy_now;
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      want_cand[p] = ask_pa_valid_q && ask_pa0_q[31] && cand_fetchable[p] && !cand_present[p] &&
          !fill_busy_q[p];
      want_fill[p] = want_cand[p] && !vs_hit[p];
    end
    copy_now = '0;
    if (!i_line_resp_valid && !i_invalidate) begin
      if (want_cand[fill_line0[0]] && vs_hit[fill_line0[0]] && !ev_pending_q[fill_line0[0]])
        copy_now[fill_line0[0]] = 1'b1;
      else if (want_cand[~fill_line0[0]] && vs_hit[~fill_line0[0]] && !ev_pending_q[~fill_line0[0]])
        copy_now[~fill_line0[0]] = 1'b1;
    end
  end
  logic copy_slot;
  assign copy_slot = copy_now[1];

  // Request presentation: the window's own line (parity of L) first, then
  // the following line. One request per cycle on the port.
  logic [1:0] req_pending;
  logic req_sel;
  assign req_pending       = fill_busy_q & ~fill_sent_q;
  assign req_sel           = req_pending[fill_line0[0]] ? fill_line0[0] : ~fill_line0[0];

  assign o_line_req_valid  = |req_pending;
  assign o_line_req_write  = 1'b0;
  assign o_line_req_addr   = {fill_line_q[req_sel], {OffsetBits{1'b0}}};
  assign o_line_req_wdata  = '0;
  assign o_line_req_wstrb  = '0;
  assign o_line_req_id     = LINE_ID_BITS'(req_sel);
  assign o_perf_miss_stall = perf_miss_stall_q;

  // Response routing by the echoed id (the slot number).
  logic resp_slot;
  assign resp_slot = i_line_resp_id[0];

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
      fill_busy_q     <= '0;
      fill_sent_q     <= '0;
      fill_discard_q  <= '0;
      slot_valid_q[0] <= 1'b0;
      slot_valid_q[1] <= 1'b0;
    end else begin
      if (i_invalidate) begin
        slot_valid_q[0] <= 1'b0;
        slot_valid_q[1] <= 1'b0;
        // In-flight fills must complete (the line port has no abort), but
        // their pre-invalidate data must not re-validate a slot.
        fill_discard_q  <= fill_discard_q | fill_busy_q;
      end

      for (int p = 0; p < 2; p++) begin
        if (!fill_busy_q[p]) begin
          if (want_fill[p]) begin
            fill_busy_q[p] <= 1'b1;
            fill_sent_q[p] <= 1'b0;
            fill_line_q[p] <= cand_line[p];
          end
        end else begin
          if (o_line_req_valid && i_line_req_ready && (req_sel == 1'(p))) fill_sent_q[p] <= 1'b1;
          if (i_line_resp_valid && (resp_slot == 1'(p))) begin
            fill_busy_q[p] <= 1'b0;
            fill_sent_q[p] <= 1'b0;
            if (!fill_discard_q[p] && !i_invalidate) begin
              slot_valid_q[p] <= 1'b1;
              slot_line_q[p]  <= fill_line_q[p];
              slot_data_q[p]  <= i_line_resp_rdata;
              slot_sb_q[p]    <= fill_sideband;
            end
            fill_discard_q[p] <= 1'b0;
          end
        end
        // Copy from the victim store into the slot (exclusive of a response
        // and of an invalidate by construction of copy_now).
        if (copy_now[p]) begin
          slot_valid_q[p] <= 1'b1;
          slot_line_q[p]  <= cand_line[p];
          slot_data_q[p]  <= vs_data_q[vs_hit_idx[p]];
          slot_sb_q[p]    <= vs_sb_q[vs_hit_idx[p]];
        end
      end
    end
  end

  // Victim store bookkeeping. A slot write (installed fill response or
  // store copy) shadows the slot's previous content with the SAME enable the
  // slot registers use; the shadow is written into the store on a later
  // cycle (one write per cycle, slot 0 first) by a registered pending bit.
  // A slot whose shadow is still pending is not copied into (copy_now), and
  // consecutive responses to one slot are impossible (the engine must be
  // re-issued), so a shadow is never overwritten before it is stored. A
  // copied entry is released; an invalidate drops the store and the shadows.
  logic [1:0] slot_write;
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      slot_write[p] = copy_now[p] ||
          (i_line_resp_valid && (resp_slot == 1'(p)) && !fill_discard_q[p] && !i_invalidate);
    end
  end

  logic ev_write;
  logic ev_sel;
  assign ev_write = |ev_pending_q;
  assign ev_sel   = ~ev_pending_q[0];

  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      ev_pending_q <= '0;
    end else begin
      if (ev_write) ev_pending_q[ev_sel] <= 1'b0;
      for (int p = 0; p < 2; p++) begin
        if (slot_write[p]) begin
          ev_pending_q[p] <= slot_valid_q[p];
          ev_line_q[p]    <= slot_line_q[p];
          ev_data_q[p]    <= slot_data_q[p];
          ev_sb_q[p]      <= slot_sb_q[p];
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      vs_valid_q  <= '0;
      vs_wr_ptr_q <= '0;
    end else begin
      // Release first so a same-cycle store write to that entry (the
      // round-robin pointer happening to sit there) wins.
      if (|copy_now) vs_valid_q[vs_hit_idx[copy_slot]] <= 1'b0;
      if (ev_write && (VICTIM_LINES > 0)) begin
        vs_valid_q[vs_wr_ptr_q] <= 1'b1;
        vs_line_q[vs_wr_ptr_q] <= ev_line_q[ev_sel];
        vs_data_q[vs_wr_ptr_q] <= ev_data_q[ev_sel];
        vs_sb_q[vs_wr_ptr_q] <= ev_sb_q[ev_sel];
        vs_wr_ptr_q <= (vs_wr_ptr_q == VictimPtrBits'(VictimLines - 1)) ? '0 : vs_wr_ptr_q + 1'b1;
      end
    end
  end

  // Register at the fetch seam so the observer cannot extend either the L1I
  // tag path or the window-ready -> PC progress cone. A cycle counts only when
  // a confirmed L1I demand miss is outstanding, the live fetch still selects
  // the high/cached tier, and its missing line prevents publication. Backend
  // stalls, low-BRAM progress, and discarded pre-fence fills are excluded.
  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      perf_miss_stall_q <= 1'b0;
    end else begin
      perf_miss_stall_q <=
          i_pa_valid && i_pa0[31] && i_l1i_miss_outstanding && !window_ready_q &&
          !i_pipeline_stall && !pipeline_stall_q && !(|fill_discard_q);
    end
  end

`ifndef SYNTHESIS
  // Equivalence oracle for the folded publishability register.  Keep a
  // simulation-only copy of the OLD raw readiness state and prove that the new
  // bit equals the retired live expression on every initialized cycle:
  //   served-high && raw-ready && served-address == current owed ask.
  // This covers ordinary sequential service, redirects/retargets, stalls, and
  // invalidate recovery without recreating the comparison in synthesized RTL.
  logic window_ready_reference_q;
  logic publishability_oracle_valid_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      window_ready_reference_q      <= 1'b0;
      publishability_oracle_valid_q <= 1'b0;
    end else begin
      window_ready_reference_q      <= window_ready;
      publishability_oracle_valid_q <= 1'b1;
    end

    if (!i_rst && publishability_oracle_valid_q) begin
      p_folded_publishability_matches_live_tags :
      assert (window_ready_q == (window_ready_reference_q && (served_addr_q == ask_q)));
    end
  end

  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_line_resp_valid && i_line_resp_id[LINE_ID_BITS-1:1] != '0)
        $error("fetch_provider: line response id %0d (expected 0 or 1)", i_line_resp_id);
      if (i_line_resp_valid && !(fill_busy_q[resp_slot] && fill_sent_q[resp_slot]))
        $error("fetch_provider: line response for slot %0d with no fill in flight", resp_slot);
    end
  end
`endif

endmodule : fetch_provider
