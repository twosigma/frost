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
 * frost_cache: set-associative, non-blocking, write-back, write-allocate line
 * cache, one module for the L1D, L1I, and L2. Both ports speak the tagged
 * line protocol, so levels stack (hw/rtl/lib/cache/README.md, "The line
 * cache").
 *
 * Geometry. The address bits above the line offset pick a set, and a line
 * may sit in any of its set's WAYS ways (WAYS=1 is direct-mapped). Each way
 * has a tag entry {valid, dirty, tag}; T reads every way of a set at once.
 * With one-cycle tags (the L1s) the data array has a bank per way, rows by
 * set, and T's decision reads every way's row: the hit way's, or the
 * victim's, lands in a fabric register after the block RAMs, the last cycle
 * of the read latency. With delayed tags (the L2) it holds one line per row,
 * addressed {way, set}, and W reads the way T picked, from registers. Each
 * set keeps a tree pseudo-LRU state of WAYS-1 bits in its own small array,
 * read with the tags.
 *
 * Pipeline. A fired request goes straight to the tag stage T, or waits in a
 * one-entry skid until T can take it. Ready uses skid state and maintenance.
 * T decides when the tag read returns (TAG_READ_LATENCY cycles), and the side
 * effects land in the write stage W the cycle after the decision:
 *   - read hit:  the response carries the hit way's row DATA_READ_LATENCY
 *                cycles after the read, which T issues in the L1s and W in
 *                the L2. One-cycle tags decide one request per cycle;
 *                delayed tags serialize T;
 *   - write hit: W writes the strobed bytes and sets dirty; the
 *                acknowledgement is queued from T;
 *   - miss:      T picks a victim way: the lowest way that is invalid and no
 *                miss is filling, else the pseudo-LRU way among the ways no
 *                miss is filling. W invalidates the victim's tag, moves a
 *                dirty victim's row, read as a hit's is, into a writeback
 *                slot, and allocates a miss-status slot (MSHR) that owns the
 *                way until it frees.
 *                The MSHR fetches the line downstream unless a write covers
 *                the whole line. A write miss is acknowledged from T, where
 *                the store is ordered, and its bytes merge into the fill;
 *   - secondary: a write to a line whose write-allocate MSHR is pending
 *                merges into it; a read takes one of the MSHR's NUM_WAITERS
 *                waiter seats; anything else aimed at a line in transition
 *                waits, and so does a miss whose set has every way owned by
 *                an MSHR.
 * Hits and misses on other lines proceed past pending misses, including
 * lines of the same set, several MSHRs fetch at once, and writebacks drain
 * independently. Hits and allocations touch their set's pseudo-LRU state in
 * W, allocations only one time in 32 with BIMODAL_INSERT (an untouched fill
 * stays the set's next victim); probes, merges, and waiters leave it alone.
 *
 * Ordering (the slave side of the protocol): requests to the same line take
 * effect in acceptance order, though responses may leave in another order.
 * The tag of a line in transition is invalid and its MSHR guards the line
 * until the fill's tag write is visible; a request whose set matches the
 * entry in T or W waits for those stages to drain before reading its tags;
 * merges are refused once a read waiter is attached and never go to a read
 * MSHR; a stalled request reads its tags again before deciding again. A line
 * is in at most one way: it is allocated only by a miss, which finds no way
 * holding it and no MSHR fetching it.
 *
 * Writebacks. A line still in a writeback slot is neither fetched nor
 * installed again until that writeback is acknowledged, and a write hit on a
 * copy of it that stayed valid, or any probe of it, waits as well. No line
 * therefore has two writebacks in flight, which the level below could apply
 * older-last. These waits rely on the bounded writeback turn in the
 * downstream request arbitration below. Downstream ids are {type, slot}:
 * type 0 is an MSHR's fill, type 1 a writeback slot's write.
 *
 * Each line is one data-array row (sdp_ram_byte_en), in its way's bank in
 * the L1s. Tags use one block RAM per way with a one-cycle read, or for the
 * X3 L2 packed UltraRAM, one set per row, with a TAG_READ_LATENCY-cycle
 * lookup.
 *
 * Reset runs a sweep that clears every set's tags and replacement state
 * (NumSets cycles) before ready rises, so every reset, including an image
 * load, discards stale lines instead of writing them back. Maintenance
 * (fence.i) starts only once every slot and stage is empty; ready stays low
 * while it is requested. Invalidate-all reruns the sweep and discards dirty
 * data, so only a read-only cache (the L1I) may use it. Writeback-all walks
 * the set span dirtied since the previous writeback-all, writes each dirty
 * line back through the writeback slots, and leaves it valid and clean.
 * o_maint_busy covers the walk and the drain of its writebacks.
 * SIM_FAST_MAINT (simulation only) makes the sweep one cycle and has
 * writeback-all visit only the sets with dirty lines.
 *
 * Probes (NUM_PROBE > 0, the L1D) are per-line coherence requests on the
 * upstream port. PROBE_CLEAN writes a dirty copy back and leaves it valid and
 * clean; PROBE_INVAL writes a dirty copy back and invalidates the line. A
 * probe compares every way of the line's set, like any request. It returns no
 * data: its response is the acknowledgement, sent once the level below has
 * acknowledged any writeback the probe caused, so the requester can order its
 * own access behind that writeback. Probes go through the pipeline like other
 * requests but never merge or take a waiter seat. See the probe slots below
 * for the release and fill withholding.
 *
 * Performance events register one cycle after the stage that produces them:
 * hits, misses, and writebacks from W, stalls from T. Probes and maintenance
 * traffic are excluded. The write-cost events (o_write_perf_events) count
 * write misses that fetch their line, from W, and writes that wait in T for
 * a read of their line.
 */
module frost_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
    parameter int unsigned CACHE_SIZE_BYTES = 128 * 1024,
    parameter int unsigned LINE_BYTES = 32,
    // Ways per set, a power of 2; 1 is direct-mapped. The cache must have at
    // least two sets.
    parameter int unsigned WAYS = 4,
    // 1: bimodal insertion, where a fill becomes its set's most recently
    // used only one time in 32 (see the replacement state below); 0: every
    // fill does.
    parameter bit BIMODAL_INSERT = 1'b0,
    // Transaction id widths of the upstream (slave) and downstream (master)
    // line ports. DOWN_ID_BITS must hold {type, max(NUM_MSHR, NUM_WB) slots}.
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned DOWN_ID_BITS = 4,
    // Miss-status slots (outstanding fills) and writeback slots.
    parameter int unsigned NUM_MSHR = 4,
    parameter int unsigned NUM_WB = 2,
    // Read waiter seats per MSHR, for reads of its line after the request
    // that allocated it. A read that finds every seat taken waits in T.
    parameter int unsigned NUM_WAITERS = 1,
    // Probe slots: in-flight per-line coherence probes (see the header). 0
    // removes the probe machinery; only the L1D takes probes.
    parameter int unsigned NUM_PROBE = 0,
    // Data-array primitive + latencies (see sdp_ram_byte_en). "block" for L1,
    // "ultra" for the X3 L2. Simulation behaviour is primitive-agnostic.
    // Untyped because Vivado fails to resolve string-typed parameters
    // propagated into the XPM macro (see sdp_ram_byte_en). The read latency
    // counts from the read: T's decision in the L1s, W in the L2 (see the
    // data array).
    // verilog_lint: waive explicit-parameter-storage-type
    parameter DATA_MEMORY_PRIMITIVE = "block",
    parameter int unsigned DATA_READ_LATENCY = 2,
    // Latencies 1 and 2 are supported (the instantiated L1/L2 values).
    parameter int unsigned DATA_WRITE_LATENCY = 1,
    // Tag-array primitive and total logical read latency: "block" (one-cycle
    // block RAM per way) for the L1s, "ultra" (the packed UltraRAM wrapper)
    // for the X3 L2. Untyped for the same Vivado/XPM parameter-propagation
    // reason as the data primitive above.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter TAG_MEMORY_PRIMITIVE = "block",
    parameter int unsigned TAG_READ_LATENCY = 1,
    // Simulation only: bulk-clear tags in one cycle and walk only dirty sets
    // for writeback-all. The resulting invalidation/writeback behavior matches
    // the hardware sweep. Keep 0 for synthesis.
    parameter int unsigned SIM_FAST_MAINT = 0
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave).
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [  UP_ID_BITS-1:0] i_up_req_id,
    // Passive observer provenance. Functional request handling is identical
    // for ordinary and maintenance traffic.
    input  logic                    i_up_req_maintenance,
    // Per-line coherence probes (NUM_PROBE > 0; see the header). Sampled
    // with the request; write must be 0. The response pulse carrying the
    // probe's id is its acknowledgement (rdata is don't-care).
    input  logic                    i_up_req_probe,
    input  logic                    i_up_req_probe_inval,
    // Release of a probe slot by the requester (its id), which ends the
    // fill withholding of a PROBE_INVAL. Every acknowledged probe is
    // released once.
    input  logic                    i_probe_release_valid,
    input  logic [  UP_ID_BITS-1:0] i_probe_release_id,
    output logic                    o_up_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_up_resp_id,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,
    output logic                    o_up_resp_error,
    // Buffered stores can have retired before a refill/writeback fails.
    // Preserve their dirty state, stop accepting requests, and require the
    // integrating CPU to stop retirement until system recovery/reset.
    output logic                    o_fatal_error,
    output logic [  ADDR_WIDTH-1:0] o_fatal_addr,

    // Maintenance requests (see header). Hold the request until o_maint_busy
    // rises; the walk completes when it falls.
    input  logic i_writeback_all,
    input  logic i_invalidate_all,
    output logic o_maint_busy,

    // Downstream line port (master).
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [DOWN_ID_BITS-1:0] o_down_req_id,
    output logic                    o_down_req_maintenance,
    input  logic                    i_down_resp_valid,
    input  logic                    i_down_resp_error = 1'b0,
    input  logic [DOWN_ID_BITS-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata,

    // Source-registered performance observer bundles: the cache's traffic and
    // stalls, and the costs of writes narrower than its line.
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
    output cache_perf_pkg::cache_write_perf_events_t o_write_perf_events
);

  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned NumLines = CACHE_SIZE_BYTES / LINE_BYTES;
  localparam int unsigned NumSets = NumLines / WAYS;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned SetBits = $clog2(NumSets);
  // WaySelBits address a way (0 when direct-mapped); WayBits sizes way
  // signals, which keep one constant-zero bit then.
  localparam int unsigned WaySelBits = $clog2(WAYS);
  localparam int unsigned WayBits = (WAYS > 1) ? WaySelBits : 1;
  // Data-array rows are {way, set}.
  localparam int unsigned RowBits = SetBits + WaySelBits;
  localparam int unsigned TagBits = ADDR_WIDTH - SetBits - OffsetBits;
  localparam int unsigned LineAddrBits = ADDR_WIDTH - OffsetBits;
  // Tag entry layout: {valid, dirty, tag}
  localparam int unsigned TagEntryBits = TagBits + 2;
  // Tree pseudo-LRU state per set: one bit per internal node of a binary
  // tree over the ways (bit n-1 for node n, root 1, children 2n and 2n+1).
  localparam int unsigned PlruBits = (WAYS > 1) ? WAYS - 1 : 1;
  localparam bit TrackDelayedTagWrites = TAG_READ_LATENCY > 1;
  // A miss or probe hit needs a free writeback slot if its victim is dirty.
  // With one-cycle tags it needs one whatever its victim, so T's decision
  // does not wait on the victim's dirty bit, which needs the tag compare and
  // the victim choice. Delayed tags keep the exact rule.
  localparam bit ExactVictimWb = TrackDelayedTagWrites;
  // The L1s (one-cycle block RAM tags and data) read every way's data row at
  // T's decision; other configurations read the picked way from W (see the
  // data array).
  localparam bit ParallelWayRead =
      (DATA_MEMORY_PRIMITIVE == "block") && (DATA_WRITE_LATENCY == 1) && !TrackDelayedTagWrites;
  localparam int unsigned MshrBits = (NUM_MSHR > 1) ? $clog2(NUM_MSHR) : 1;
  localparam int unsigned WbBits = (NUM_WB > 1) ? $clog2(NUM_WB) : 1;
  localparam int unsigned SeatBits = (NUM_WAITERS > 1) ? $clog2(NUM_WAITERS) : 1;
  localparam int unsigned ProbeSlots = (NUM_PROBE > 0) ? NUM_PROBE : 1;
  localparam int unsigned ProbeBits = (NUM_PROBE > 1) ? $clog2(NUM_PROBE) : 1;
  localparam int unsigned DownSlotBits = DOWN_ID_BITS - 1;
  localparam int unsigned AckDepth = 1 << UP_ID_BITS;
  localparam int unsigned AckPtrBits = UP_ID_BITS + 1;

  initial begin
    if (NumLines * LINE_BYTES != CACHE_SIZE_BYTES)
      $fatal(1, "frost_cache: CACHE_SIZE_BYTES must be a multiple of LINE_BYTES");
    if (2 ** OffsetBits != LINE_BYTES) $fatal(1, "frost_cache: LINE_BYTES must be a power of 2");
    if ((WAYS < 1) || (2 ** WaySelBits != WAYS))
      $fatal(1, "frost_cache: WAYS must be a power of 2");
    if ((NumSets < 2) || (NumSets * WAYS != NumLines) || (2 ** SetBits != NumSets))
      $fatal(1, "frost_cache: the cache must hold a power-of-2 number of sets, at least 2");
    if (DATA_WRITE_LATENCY < 1 || DATA_WRITE_LATENCY > 2)
      $fatal(1, "frost_cache: DATA_WRITE_LATENCY must be 1 or 2");
    if (ParallelWayRead && (DATA_READ_LATENCY < 2))
      $fatal(1, "frost_cache: reading every way at T needs DATA_READ_LATENCY >= 2");
    if ((TAG_MEMORY_PRIMITIVE != "block") && (TAG_MEMORY_PRIMITIVE != "ultra"))
      $fatal(1, "frost_cache: TAG_MEMORY_PRIMITIVE must be block or ultra");
    if ((TAG_MEMORY_PRIMITIVE == "block") && (TAG_READ_LATENCY != 1))
      $fatal(1, "frost_cache: block tags require TAG_READ_LATENCY=1");
    if ((TAG_MEMORY_PRIMITIVE == "ultra") && (TAG_READ_LATENCY < 3))
      $fatal(1, "frost_cache: packed ultra tags require TAG_READ_LATENCY>=3");
    if (DOWN_ID_BITS < 2) $fatal(1, "frost_cache: DOWN_ID_BITS must be >= 2");
    if (NUM_WAITERS < 1) $fatal(1, "frost_cache: NUM_WAITERS must be >= 1");
    if ((1 << DownSlotBits) < NUM_MSHR || (1 << DownSlotBits) < NUM_WB)
      $fatal(1, "frost_cache: DOWN_ID_BITS cannot address every MSHR / writeback slot");
  end

  // ===========================================================================
  // Way helpers
  // ===========================================================================
  // Data-array row of a line in a way: {way, set}.
  function automatic logic [RowBits-1:0] row_of(input logic [WayBits-1:0] way,
                                                input logic [SetBits-1:0] set);
    row_of = RowBits'(set);
    if (WAYS > 1) row_of = RowBits'({way, set});
  endfunction

  function automatic logic [WAYS-1:0] way_onehot(input logic [WayBits-1:0] way);
    way_onehot = '0;
    for (int w = 0; w < int'(WAYS); w++) if (int'(way) == w) way_onehot[w] = 1'b1;
  endfunction

  // The lowest way set in a mask (0 if none).
  function automatic logic [WayBits-1:0] lowest_way(input logic [WAYS-1:0] mask);
    lowest_way = '0;
    for (int w = int'(WAYS) - 1; w >= 0; w--) if (mask[w]) lowest_way = WayBits'(w);
  endfunction

  // Tree pseudo-LRU. Bit n-1 holds node n; 1 sends the victim to the right
  // child 2n+1, 0 to the left child 2n. The leaves WAYS..2*WAYS-1 are the
  // ways. An access sets every bit on its path to point away from it.
  function automatic logic [WayBits-1:0] plru_victim(input logic [PlruBits-1:0] state);
    int node;
    node = 1;
    for (int level = 0; level < int'(WaySelBits); level++) node = 2 * node + int'(state[node-1]);
    plru_victim = WayBits'(node - int'(WAYS));
  endfunction

  // The pseudo-LRU way among the ways in avail: the walk follows the state
  // but turns away from a subtree with no way in avail. When the pseudo-LRU
  // way is in avail this is that way. (Unspecified when avail is empty.)
  function automatic logic [WayBits-1:0] plru_victim_among(input logic [PlruBits-1:0] state,
                                                           input logic [WAYS-1:0] avail);
    int node, lo, half;
    logic left_ok, right_ok, go_right;
    node = 1;
    lo   = 0;
    half = int'(WAYS) / 2;
    for (int level = 0; level < int'(WaySelBits); level++) begin
      left_ok  = 1'b0;
      right_ok = 1'b0;
      for (int w = 0; w < int'(WAYS); w++) begin
        if ((w >= lo) && (w < lo + half)) left_ok = left_ok | avail[w];
        if ((w >= lo + half) && (w < lo + 2 * half)) right_ok = right_ok | avail[w];
      end
      go_right = (left_ok && right_ok) ? state[node-1] : right_ok;
      node = 2 * node + int'(go_right);
      if (go_right) lo = lo + half;
      half = half / 2;
    end
    plru_victim_among = WayBits'(node - int'(WAYS));
  endfunction

  function automatic logic [PlruBits-1:0] plru_touch(input logic [PlruBits-1:0] state,
                                                     input logic [WayBits-1:0] way);
    int node;
    plru_touch = state;
    node = int'(way) + int'(WAYS);
    for (int level = 0; level < int'(WaySelBits); level++) begin
      // Reached from the left child: point the parent right, and vice versa.
      plru_touch[node/2-1] = (node % 2) == 0;
      node = node / 2;
    end
  endfunction

  // ===========================================================================
  // Maintenance / sweep control (drives the tag and data ports while active)
  // ===========================================================================
  typedef enum logic [2:0] {
    M_SWEEP,        // reset/invalidate-all: clear every set's tags
    M_IDLE,         // the request pipeline runs
    M_FLUSH_SCAN,   // writeback-all: present the walk's set to the tags
    M_FLUSH_CHECK,  // examine the set; pick its lowest dirty way, if any
    M_FLUSH_WRITE,  // read the picked dirty line out, mark it clean
    M_FLUSH_DRAIN   // wait for the walk's writebacks to be acknowledged
  } mstate_e;

  mstate_e mstate_q;
  logic [SetBits-1:0] sweep_idx_q;
  logic [SetBits-1:0] flush_idx_q;

  logic pipeline_idle;  // nothing in flight anywhere (maintenance may start)
  logic flush_active;
  assign flush_active = (mstate_q == M_FLUSH_SCAN) || (mstate_q == M_FLUSH_CHECK) ||
      (mstate_q == M_FLUSH_WRITE) || (mstate_q == M_FLUSH_DRAIN);
  assign o_maint_busy = flush_active || (mstate_q == M_SWEEP);

  // Fast maintenance: the tag bulk clear replaces the sweep, which then lasts
  // one cycle.
  logic tag_bulk_clear;
  assign tag_bulk_clear = (SIM_FAST_MAINT != 0) && (mstate_q == M_SWEEP);

  // ===========================================================================
  // Tag array: every way of a set read at once (one-cycle block RAM per way,
  // or packed/pipelined UltraRAM with a set per row)
  // ===========================================================================
  logic [            WAYS-1:0] tag_we;  // the ways written at tag_waddr
  logic [         SetBits-1:0] tag_waddr;
  logic [    TagEntryBits-1:0] tag_wdata;
  logic [         SetBits-1:0] tag_raddr;
  logic [    TagEntryBits-1:0] tag_rdata                                [WAYS];
  logic                        tag_re;
  logic [TAG_READ_LATENCY-1:0] tag_response_valid_q;
  logic                        tag_response_valid;
  logic [WAYS-1:0] tag_rdata_valid, tag_rdata_dirty;
  logic [TagBits-1:0] tag_rdata_tag[WAYS];
  for (genvar gw = 0; gw < int'(WAYS); gw++) begin : gen_tag_unpack
    assign {tag_rdata_valid[gw], tag_rdata_dirty[gw], tag_rdata_tag[gw]} = tag_rdata[gw];
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      tag_response_valid_q <= '0;
    end else begin
      tag_response_valid_q[0] <= tag_re;
      for (int unsigned k = 1; k < TAG_READ_LATENCY; k++)
      tag_response_valid_q[k] <= tag_response_valid_q[k-1];
    end
  end
  assign tag_response_valid = tag_response_valid_q[TAG_READ_LATENCY-1];

  if (TAG_MEMORY_PRIMITIVE == "ultra") begin : gen_tag_ultra
    // A row holds one set: its ways are the packed slots, and a read returns
    // all of them. Addresses are entries {set, way}.
    localparam int unsigned TagAddrBits = SetBits + WaySelBits;
    logic [WAYS*TagEntryBits-1:0] tag_row;
    sdp_packed_tag_uram #(
        .ADDR_WIDTH(TagAddrBits),
        .DATA_WIDTH(TagEntryBits),
        .READ_LATENCY(TAG_READ_LATENCY),
        .READ_WORDS(WAYS),
        .SUPPORT_BULK_CLEAR(SIM_FAST_MAINT)
    ) tag_array (
        .i_clk(i_clk),
        .i_write_enable(|tag_we),
        .i_bulk_clear(tag_bulk_clear),
        .i_write_address(TagAddrBits'(tag_waddr) << WaySelBits),
        .i_write_word_mask(tag_we),
        .i_write_data(tag_wdata),
        .i_read_enable(tag_re),
        .i_read_address(TagAddrBits'(tag_raddr) << WaySelBits),
        .o_read_data(tag_row)
    );
    for (genvar gw = 0; gw < int'(WAYS); gw++) begin : gen_way
      assign tag_rdata[gw] = tag_row[gw*TagEntryBits+:TagEntryBits];
    end
  end else begin : gen_tag_block
    for (genvar gw = 0; gw < int'(WAYS); gw++) begin : gen_way
      sdp_block_ram #(
          .ADDR_WIDTH(SetBits),
          .DATA_WIDTH(TagEntryBits),
          .SUPPORT_BULK_CLEAR(SIM_FAST_MAINT)
      ) tag_array (
          .i_clk(i_clk),
          .i_write_enable(tag_we[gw]),
          .i_bulk_clear(tag_bulk_clear),
          .i_write_address(tag_waddr),
          .i_read_address(tag_raddr),
          .i_write_data(tag_wdata),
          .o_read_data(tag_rdata[gw])
      );
    end
  end

  // ===========================================================================
  // Replacement state: one tree pseudo-LRU word per set, read with the tags
  // and aligned with their response; W writes the touched state back
  // ===========================================================================
  logic [PlruBits-1:0] plru_rdata;
  logic                plru_we;
  logic [ SetBits-1:0] plru_waddr;
  logic [PlruBits-1:0] plru_wdata;
  // With BIMODAL_INSERT, a fill makes its line the set's most recently used
  // one time in 32, chosen by a free-running LFSR, and otherwise leaves the
  // state alone, so the line stays the set's next victim until a hit touches
  // it (bimodal insertion). A working set somewhat larger than the cache then
  // keeps part of itself resident, where touching on every fill would evict
  // each line before its next use.
  logic                fill_touch;
  if (WAYS > 1) begin : gen_plru
    logic [PlruBits-1:0] plru_ram_rdata;
    if (BIMODAL_INSERT) begin : gen_bimodal
      logic [15:0] insert_lfsr_q;
      always_ff @(posedge i_clk) begin
        if (i_rst) insert_lfsr_q <= 16'hACE1;
        else
          insert_lfsr_q <= {
            insert_lfsr_q[14:0],
            insert_lfsr_q[15] ^ insert_lfsr_q[13] ^ insert_lfsr_q[12] ^ insert_lfsr_q[10]
          };
      end
      assign fill_touch = (insert_lfsr_q[4:0] == 5'd0);
    end else begin : gen_mru_insert
      assign fill_touch = 1'b1;
    end
    sdp_block_ram #(
        .ADDR_WIDTH(SetBits),
        .DATA_WIDTH(PlruBits),
        .SUPPORT_BULK_CLEAR(SIM_FAST_MAINT)
    ) plru_array (
        .i_clk(i_clk),
        .i_write_enable(plru_we),
        .i_bulk_clear(tag_bulk_clear),
        .i_write_address(plru_waddr),
        .i_read_address(tag_raddr),
        .i_write_data(plru_wdata),
        .o_read_data(plru_ram_rdata)
    );
    if (TAG_READ_LATENCY > 1) begin : gen_delay
      logic [PlruBits-1:0] plru_pipe_q[TAG_READ_LATENCY-1];
      always_ff @(posedge i_clk) begin
        plru_pipe_q[0] <= plru_ram_rdata;
        for (int unsigned k = 1; k < TAG_READ_LATENCY - 1; k++) plru_pipe_q[k] <= plru_pipe_q[k-1];
      end
      assign plru_rdata = plru_pipe_q[TAG_READ_LATENCY-2];
    end else begin : gen_direct
      assign plru_rdata = plru_ram_rdata;
    end
  end else begin : gen_no_plru
    assign plru_rdata = '0;
    assign fill_touch = 1'b1;
    /* verilator lint_off UNUSEDSIGNAL */
    logic plru_unused;
    assign plru_unused = plru_we ^ (^plru_waddr) ^ (^plru_wdata);
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ===========================================================================
  // Data array: a bank per way, rows by set (the L1s), or one row per line,
  // {way, set} (the L2)
  // ===========================================================================
  logic                  data_re;
  logic [   RowBits-1:0] data_raddr;  // the row W reads (the L2)
  logic [   SetBits-1:0] data_rset;  // the set T reads in every bank (the L1s)
  logic [  LineBits-1:0] data_rdata;
  logic                  data_row_we;
  logic [   RowBits-1:0] data_waddr;
  logic [LINE_BYTES-1:0] data_wbyte_en;
  logic [  LineBits-1:0] data_wdata;
  // The way whose row a read returns, and whether its line is used, from the
  // read pipeline below.
  logic [   WayBits-1:0] rp_push_way;
  logic                  rp_push_used;

  // An UltraRAM row spreads over several UltraRAM columns, far from the
  // response and writeback logic. The last read cycle is a fabric register,
  // so the memory's own last stage can stay beside the columns.
  localparam bit DataReadOutputReg = (DATA_MEMORY_PRIMITIVE == "ultra");
  if (ParallelWayRead) begin : gen_data_banks
    // T's decision reads its set in every bank, straight from T's address
    // register. The banks' read latches feed a way multiplexer and the fabric
    // register that ends the read latency, so a hit answers as soon as a
    // direct-mapped one would. A read never meets a same-edge write of the row
    // it returns: W writes another set (a_hold kept this request out of T
    // while T or W held its set), and a fill installs only into the way its
    // miss slot owns, which allocations do not take and which a request for
    // that line does not hit (it meets the slot as same_line). Another bank
    // may be written in the same cycle; its row goes unused. Each bank's read
    // enable qualifies only its collision check.
    logic [LineBits-1:0] bank_rdata[WAYS];
    logic [ SetBits-1:0] data_wset;
    logic [ WayBits-1:0] data_wway;
    assign data_wset = data_waddr[SetBits-1:0];
    if (WAYS > 1) begin : gen_wway
      assign data_wway = data_waddr[RowBits-1:SetBits];
    end else begin : gen_wway_single
      assign data_wway = '0;
    end
    for (genvar gw = 0; gw < int'(WAYS); gw++) begin : gen_bank
      sdp_ram_byte_en #(
          .DATA_WIDTH(LineBits),
          .ADDR_WIDTH(SetBits),
          .READ_LATENCY(DATA_READ_LATENCY - 1),
          .WRITE_LATENCY(DATA_WRITE_LATENCY),
          .MEMORY_PRIMITIVE(DATA_MEMORY_PRIMITIVE),
          .REGISTER_READ_INPUT(1'b0),
          .REGISTER_READ_OUTPUT(1'b0)
      ) data_bank (
`ifndef SYNTHESIS
          .i_check_enable(reset_seen_q && !i_rst),
`endif
          .i_clk(i_clk),
          .i_waddr(data_wset),
          .i_wdata(data_wdata),
          .i_wbyte_en(data_wbyte_en & {LINE_BYTES{data_row_we && (data_wway == WayBits'(gw))}}),
          .i_re(rp_push_used && (rp_push_way == WayBits'(gw))),
          .i_raddr(data_rset),
          .o_rdata(bank_rdata[gw])
      );
    end
    // The way each read returns, aligned with the banks' latency.
    logic [WayBits-1:0] rd_way_q[DATA_READ_LATENCY-1];
    always_ff @(posedge i_clk) begin
      rd_way_q[0] <= rp_push_way;
      for (int k = 1; k < int'(DATA_READ_LATENCY) - 1; k++) rd_way_q[k] <= rd_way_q[k-1];
    end
    logic [LineBits-1:0] data_rdata_q;
    always_ff @(posedge i_clk) data_rdata_q <= bank_rdata[rd_way_q[DATA_READ_LATENCY-2]];
    assign data_rdata = data_rdata_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic data_raddr_unused;
    assign data_raddr_unused = data_re ^ (^data_raddr);
    /* verilator lint_on UNUSEDSIGNAL */
  end else begin : gen_data_array
    // W issues reads from registers. A read never meets a same-edge write of
    // its row: W reads a valid way or the victim it is taking, and no fill
    // can be installing into either. Maintenance reads have no writes.
    localparam bit DataReadDirect = (DATA_MEMORY_PRIMITIVE == "block") && (DATA_WRITE_LATENCY == 1);
    sdp_ram_byte_en #(
        .DATA_WIDTH(LineBits),
        .ADDR_WIDTH(RowBits),
        .READ_LATENCY(DATA_READ_LATENCY),
        .WRITE_LATENCY(DATA_WRITE_LATENCY),
        .MEMORY_PRIMITIVE(DATA_MEMORY_PRIMITIVE),
        .REGISTER_READ_INPUT(!DataReadDirect),
        .REGISTER_READ_OUTPUT(DataReadOutputReg)
    ) data_array (
`ifndef SYNTHESIS
        .i_check_enable(reset_seen_q && !i_rst),
`endif
        .i_clk(i_clk),
        .i_waddr(data_waddr),
        .i_wdata(data_wdata),
        .i_wbyte_en(data_wbyte_en & {LINE_BYTES{data_row_we}}),
        .i_re(data_re),
        .i_raddr(data_raddr),
        .o_rdata(data_rdata)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    logic data_rset_unused;
    assign data_rset_unused = (^data_rset) ^ rp_push_used ^ (^rp_push_way);
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ===========================================================================
  // Miss-status and writeback slots
  // ===========================================================================
  typedef enum logic [2:0] {
    MS_FREE,
    MS_PEND,      // fill needed, not yet issued
    MS_SENT,      // fill issued, response outstanding
    MS_MERGE,     // fill data captured; a same-cycle W merge settles
    MS_WRITE,     // ready to write (victim captured); waits to be picked
    MS_WRITING,   // picked into the write stage; waits for the write ports
    MS_RESP,      // written; responding (primary, then waiter)
    MS_FREE_WAIT  // one cycle so the tag write is visible to readers
  } mshr_state_e;

  mshr_state_e mshr_state_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_valid;
  logic [LineAddrBits-1:0] mshr_line_q[NUM_MSHR];
  // The way a valid MSHR owns in its line's set, from its allocation until it
  // frees: the fill installs there, and no other miss takes it meanwhile.
  logic [WayBits-1:0] mshr_way_q[NUM_MSHR];
  logic [UP_ID_BITS-1:0] mshr_id_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_write_q;
  logic [NUM_MSHR-1:0] mshr_maint_q;
  logic [NUM_MSHR-1:0] mshr_has_victim_q;
  logic [WbBits-1:0] mshr_victim_wb_q[NUM_MSHR];
  // Waiter seats fill from seat 0 up, and answered waiters leave from seat 0,
  // the others moving down, so the response always reads seat 0.
  logic [NUM_WAITERS-1:0] mshr_waiter_valid_q[NUM_MSHR];
  logic [NUM_WAITERS-1:0][UP_ID_BITS-1:0] mshr_waiter_id_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_has_waiter;  // seat 0 taken
  logic [NUM_MSHR-1:0] mshr_seats_full;  // the last seat taken
  logic [NUM_MSHR-1:0] mshr_more_waiters;  // a waiter behind seat 0
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      mshr_has_waiter[i] = mshr_waiter_valid_q[i][0];
      mshr_seats_full[i] = mshr_waiter_valid_q[i][NUM_WAITERS-1];
    end
  end
  if (NUM_WAITERS > 1) begin : gen_more_waiters
    always_comb begin
      for (int i = 0; i < int'(NUM_MSHR); i++) mshr_more_waiters[i] = mshr_waiter_valid_q[i][1];
    end
  end else begin : gen_one_waiter
    assign mshr_more_waiters = '0;
  end
  logic [LINE_BYTES-1:0] mshr_wstrb_q[NUM_MSHR];
  logic [LineBits-1:0] mshr_data_q[NUM_MSHR];
  logic [NUM_WB-1:0] mshr_wb_wait_q[NUM_MSHR];  // writebacks of the same line
  logic [NUM_MSHR-1:0] mshr_resp_primary_done_q;
  logic [NUM_MSHR-1:0] mshr_error_q;

  typedef enum logic [1:0] {
    WB_FREE,
    WB_FILLING,  // victim read in flight through the data pipeline
    WB_PEND,     // data captured, request not yet issued
    WB_SENT      // request issued, acknowledgement outstanding
  } wb_state_e;

  wb_state_e                    wb_state_q                                            [NUM_WB];
  logic      [      NUM_WB-1:0] wb_valid;
  logic      [LineAddrBits-1:0] wb_line_q                                             [NUM_WB];
  logic      [    LineBits-1:0] wb_data_q                                             [NUM_WB];
  logic      [      NUM_WB-1:0] wb_maint_q;
  logic      [      NUM_WB-1:0] wb_probe_q;  // a probe's victim: acknowledge its slot
  logic      [   ProbeBits-1:0] wb_probe_slot_q                                       [NUM_WB];

  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) mshr_valid[i] = (mshr_state_q[i] != MS_FREE);
    for (int j = 0; j < int'(NUM_WB); j++) wb_valid[j] = (wb_state_q[j] != WB_FREE);
  end

  // ---- Probe slots (NUM_PROBE > 0).
  // Hold a slot from the probe decision until release, after the requester's
  // access is ordered below. PROBE_INVAL withholds later fills of its line so
  // they cannot reload old data. Earlier fills must finish before the probe
  // decides, avoiding a deadlock.
  // Whole-line writes bypass fills and cannot be withheld: a probed cache
  // must not receive them. L1D writes cover only an 8-byte beat.
  // ProbeSlots keeps arrays legal when probes are disabled.
  logic [ProbeSlots-1:0] probe_valid_q;  // slot held (decision to the requester's release)
  logic [ProbeSlots-1:0] probe_ack_q;  // acknowledgement waiting for the response port
  logic [ProbeSlots-1:0] probe_inval_q;
  logic [LineAddrBits-1:0] probe_line_q[ProbeSlots];
  logic [UP_ID_BITS-1:0] probe_id_q[ProbeSlots];
  logic probe_free_any, probe_ack_any;
  logic [ProbeBits-1:0] probe_free_idx, probe_ack_sel;
  logic [NUM_MSHR-1:0] mshr_fill_held;  // fill withheld by a held PROBE_INVAL slot
  always_comb begin
    probe_free_any = 1'b0;
    probe_free_idx = '0;
    probe_ack_any  = 1'b0;
    probe_ack_sel  = '0;
    for (int k = int'(ProbeSlots) - 1; k >= 0; k--) begin
      if (!probe_valid_q[k]) begin
        probe_free_any = 1'b1;
        probe_free_idx = ProbeBits'(k);
      end
      if (probe_ack_q[k]) begin
        probe_ack_any = 1'b1;
        probe_ack_sel = ProbeBits'(k);
      end
    end
    if (NUM_PROBE == 0) begin
      probe_free_any = 1'b0;
      probe_ack_any  = 1'b0;
    end
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      mshr_fill_held[i] = 1'b0;
      for (int k = 0; k < int'(ProbeSlots); k++) begin
        if ((NUM_PROBE > 0) && probe_valid_q[k] && probe_inval_q[k] &&
            (probe_line_q[k] == mshr_line_q[i])) begin
          mshr_fill_held[i] = 1'b1;
        end
      end
    end
  end

  // ===========================================================================
  // Stage A: input skid and the tag read
  // ===========================================================================
  logic                  sk_valid_q;
  logic                  sk_write_q;
  logic [ADDR_WIDTH-1:0] sk_addr_q;
  logic [  LineBits-1:0] sk_wdata_q;
  logic [LINE_BYTES-1:0] sk_wstrb_q;
  logic [UP_ID_BITS-1:0] sk_id_q;
  logic                  sk_maint_q;
  logic                  sk_probe_q;
  logic                  sk_probe_inval_q;

  // Ready requires an empty skid and idle maintenance state. A maintenance
  // request masks ready immediately so the pipeline can drain.
  assign o_up_req_ready = (mstate_q == M_IDLE) && !sk_valid_q && !i_invalidate_all &&
      !i_writeback_all && !o_fatal_error;

  logic up_req_fire;
  assign up_req_fire = i_up_req_valid && o_up_req_ready;

  // The request presented to T: the skid entry, else the live input.
  logic                  in_valid;
  logic                  in_write;
  logic [ADDR_WIDTH-1:0] in_addr;
  logic [  LineBits-1:0] in_wdata;
  logic [LINE_BYTES-1:0] in_wstrb;
  logic [UP_ID_BITS-1:0] in_id;
  logic                  in_maint;
  assign in_valid = sk_valid_q || up_req_fire;
  assign in_write = sk_valid_q ? sk_write_q : i_up_req_write;
  assign in_addr  = sk_valid_q ? sk_addr_q : i_up_req_addr;
  assign in_wdata = sk_valid_q ? sk_wdata_q : i_up_req_wdata;
  assign in_wstrb = sk_valid_q ? sk_wstrb_q : i_up_req_wstrb;
  assign in_id    = sk_valid_q ? sk_id_q : i_up_req_id;
  assign in_maint = sk_valid_q ? sk_maint_q : i_up_req_maintenance;
  logic in_probe;
  logic in_probe_inval;
  assign in_probe       = (NUM_PROBE > 0) && (sk_valid_q ? sk_probe_q : i_up_req_probe);
  assign in_probe_inval = sk_valid_q ? sk_probe_inval_q : i_up_req_probe_inval;

  logic [     SetBits-1:0] in_set;
  logic [LineAddrBits-1:0] in_line;
  assign in_set  = in_addr[OffsetBits+:SetBits];
  assign in_line = in_addr[ADDR_WIDTH-1:OffsetBits];

  // ===========================================================================
  // Stage T: tag compare and decision
  // ===========================================================================
  logic                    t_valid_q;
  logic                    reread_q;  // issue a retry of T's tag read this cycle
  logic                    t_tag_stale_q;  // a pending read was crossed by a tag write
  logic                    t_write_q;
  logic [  ADDR_WIDTH-1:0] t_addr_q;
  logic [    LineBits-1:0] t_wdata_q;
  logic [  LINE_BYTES-1:0] t_wstrb_q;
  logic [  UP_ID_BITS-1:0] t_id_q;
  logic                    t_maint_q;
  logic                    t_probe_q;
  logic                    t_probe_inval_q;
  logic [    NUM_MSHR-1:0] t_set_match_q;  // MSHR with this set
  logic [    NUM_MSHR-1:0] t_line_match_q;  // MSHR with this line
  logic [      NUM_WB-1:0] t_wb_match_q;  // writeback slot with this line

  logic [     SetBits-1:0] t_set;
  logic [     TagBits-1:0] t_tag;
  logic [LineAddrBits-1:0] t_line;
  assign t_set  = t_addr_q[OffsetBits+:SetBits];
  assign t_tag  = t_addr_q[ADDR_WIDTH-1-:TagBits];
  assign t_line = t_addr_q[ADDR_WIDTH-1:OffsetBits];

  // ===========================================================================
  // Stage W: registered side effects of T's decision
  // ===========================================================================
  typedef enum logic [2:0] {
    W_NONE,         // nothing, or a probe that missed
    W_READ_HIT,     // touch replacement (the L2 also reads the hit way here)
    W_WRITE_HIT,    // strobed array write + dirty tag; touch replacement
    W_ALLOC,        // invalidate the victim way, allocate an MSHR (+ writeback slot)
    W_MERGE,        // merge a write into a pending write MSHR
    W_WAITER,       // attach a read waiter to a pending MSHR
    W_PROBE_CLEAN,  // probe hit: tag valid+clean, a dirty copy to a writeback slot
    W_PROBE_INVAL   // probe hit: invalidate, a dirty copy to a writeback slot
  } w_op_e;

  logic                     w_valid_q;
  w_op_e                    w_op_q;
  logic                     w_tag_write_q;  // w_writes_tag, registered for T's set checks
  logic                     w_data_write_q;  // w_writes_data, likewise
  logic  [     SetBits-1:0] w_set_q;
  logic  [     TagBits-1:0] w_tag_q;
  logic  [LineAddrBits-1:0] w_line_q;
  logic                     w_write_q;
  logic  [    LineBits-1:0] w_wdata_q;
  logic  [  LINE_BYTES-1:0] w_wstrb_q;
  logic  [  UP_ID_BITS-1:0] w_id_q;
  logic                     w_maint_q;
  logic                     w_probe_q;
  logic  [    MshrBits-1:0] w_mshr_q;
  logic  [      WbBits-1:0] w_wb_q;
  // The way W acts on: the hit way, or an allocation's victim way.
  logic  [     WayBits-1:0] w_way_q;
  // Dirty bits of the hit way and of the victim way, and the victim's tag.
  logic                     w_hit_dirty_q;
  logic                     w_victim_dirty_q;
  logic  [     TagBits-1:0] w_victim_tag_q;
  logic  [    PlruBits-1:0] w_plru_q;  // the set's replacement state at T's decision
  logic                     w_needs_fill_q;
  logic  [      NUM_WB-1:0] w_wb_wait_q;
  logic  [   ProbeBits-1:0] w_probe_slot_q;

  // A dirty victim leaves through a writeback slot: an allocation's victim
  // way, or a probed line's own copy.
  logic w_is_alloc, w_is_probe_hit, w_has_victim;
  logic [LineAddrBits-1:0] w_victim_line;
  assign w_is_alloc = (w_op_q == W_ALLOC);
  assign w_is_probe_hit = (w_op_q == W_PROBE_CLEAN) || (w_op_q == W_PROBE_INVAL);
  assign w_has_victim = (w_is_alloc && w_victim_dirty_q) || (w_is_probe_hit && w_hit_dirty_q);
  assign w_victim_line = {w_is_alloc ? w_victim_tag_q : w_tag_q, w_set_q};

  // W-stage allocations not yet in the slot valid bits: an MSHR (W_ALLOC),
  // and a writeback slot for an allocation's dirty victim or a probe's.
  logic w_allocs_mshr, w_allocs_wb;
  assign w_allocs_mshr = w_valid_q && w_is_alloc;
  assign w_allocs_wb   = w_valid_q && w_has_victim;

  // Hold A while its set matches T or W so their tag and replacement writes
  // become visible before its read. Compare skid and live sets separately,
  // for timing.
  logic [SetBits-1:0] sk_set, up_set;
  assign sk_set = sk_addr_q[OffsetBits+:SetBits];
  assign up_set = i_up_req_addr[OffsetBits+:SetBits];
  localparam int unsigned SetCmpGroups = (SetBits + 2) / 3;
  (* dont_touch = "true" *) logic [SetCmpGroups-1:0] up_t_match_group, up_w_match_group;
  for (genvar gg = 0; gg < int'(SetCmpGroups); gg++) begin : gen_set_hold_compare
    localparam int unsigned Lo = gg * 3;
    localparam int unsigned Hi = (Lo + 3 <= SetBits) ? Lo + 3 : SetBits;
    assign up_t_match_group[gg] = (up_set[Hi-1:Lo] == t_set[Hi-1:Lo]);
    assign up_w_match_group[gg] = (up_set[Hi-1:Lo] == w_set_q[Hi-1:Lo]);
  end
  logic sk_hold, up_hold, a_hold;
  assign sk_hold = (t_valid_q && (sk_set == t_set)) || (w_valid_q && (sk_set == w_set_q));
  assign up_hold = (t_valid_q && (&up_t_match_group)) || (w_valid_q && (&up_w_match_group));
  assign a_hold  = sk_valid_q ? sk_hold : up_hold;

  // A-stage comparators against the slots, registered into T with the entry
  // and masked there by the live valid bits. A slot being allocated by W this
  // cycle still holds its previous line, so its match is meaningless and is
  // cleared: if the new line is a true set match, a_hold keeps the request
  // in A and it compares again next cycle.
  logic [NUM_MSHR-1:0] in_set_match, in_line_match;
  logic [NUM_WB-1:0] in_wb_match;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      in_set_match[i]  = (mshr_line_q[i][SetBits-1:0] == in_set);
      in_line_match[i] = (mshr_line_q[i] == in_line);
    end
    for (int j = 0; j < int'(NUM_WB); j++) in_wb_match[j] = (wb_line_q[j] == in_line);
    if (w_allocs_mshr) begin
      in_set_match[w_mshr_q]  = 1'b0;
      in_line_match[w_mshr_q] = 1'b0;
    end
    if (w_allocs_wb) in_wb_match[w_wb_q] = 1'b0;
  end

  // ---- Per-way tag compare in three-bit equality groups, preserved for
  // timing. The valid bit joins the last group when it is shorter than three
  // bits. The decision acts in T; RAM writes use W's registers one cycle
  // later.
  localparam int unsigned TagCmpGroups = (TagBits + 2) / 3;
  localparam bit ValidInLastGroup = (TagBits % 3) != 0;
  logic [WAYS-1:0] way_hit;
  for (genvar gw = 0; gw < int'(WAYS); gw++) begin : gen_way_compare
    (* dont_touch = "true" *) logic [TagCmpGroups-1:0] tag_match_group;
    for (genvar gg = 0; gg < int'(TagCmpGroups); gg++) begin : gen_tag_compare
      localparam int unsigned Lo = gg * 3;
      localparam int unsigned Hi = (Lo + 3 <= TagBits) ? Lo + 3 : TagBits;
      if (ValidInLastGroup && (gg == int'(TagCmpGroups) - 1)) begin : gen_with_valid
        assign tag_match_group[gg] = tag_rdata_valid[gw] &&
            (tag_rdata_tag[gw][Hi-1:Lo] == t_tag[Hi-1:Lo]);
      end else begin : gen_tag_only
        assign tag_match_group[gg] = (tag_rdata_tag[gw][Hi-1:Lo] == t_tag[Hi-1:Lo]);
      end
    end
    // Preserve each way's hit for timing.
    (* dont_touch = "true" *) logic way_hit_d;
    if (ValidInLastGroup) begin : gen_hit_groups
      assign way_hit_d = &tag_match_group;
    end else begin : gen_hit_groups_valid
      assign way_hit_d = tag_rdata_valid[gw] && (&tag_match_group);
    end
    assign way_hit[gw] = way_hit_d;
  end
  logic hit;
  assign hit = |way_hit;

  // ---- Slot availability (a W-stage allocation is not yet in the valid bits).
  logic [NUM_MSHR-1:0] mshr_free_mask;
  logic [  NUM_WB-1:0] wb_free_mask;
  logic mshr_free_any, wb_free_any;
  logic [MshrBits-1:0] mshr_free_idx;
  logic [  WbBits-1:0] wb_free_idx;
  always_comb begin
    mshr_free_mask = ~mshr_valid;
    wb_free_mask   = ~wb_valid;
    if (w_allocs_mshr) mshr_free_mask[w_mshr_q] = 1'b0;
    if (w_allocs_wb) wb_free_mask[w_wb_q] = 1'b0;
    mshr_free_any = 1'b0;
    mshr_free_idx = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if (mshr_free_mask[i]) begin
        mshr_free_any = 1'b1;
        mshr_free_idx = MshrBits'(i);
      end
    end
    wb_free_any = 1'b0;
    wb_free_idx = '0;
    for (int j = int'(NUM_WB) - 1; j >= 0; j--) begin
      if (wb_free_mask[j]) begin
        wb_free_any = 1'b1;
        wb_free_idx = WbBits'(j);
      end
    end
  end

  // ---- Refresh slot matches while T is held: slots can retire and be
  // reallocated. A stale match could merge across lines or skip a writeback.
  // Forward W's incoming slot identity because the slot still holds its old
  // line. New A captures use a_hold and exclude W allocations instead.
  // Maintenance needs neither rule: A and T stay empty until its writebacks drain.
  logic [NUM_MSHR-1:0] t_set_live_match, t_line_live_match;
  logic [NUM_WB-1:0] t_wb_live_match;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      t_set_live_match[i]  = (mshr_line_q[i][SetBits-1:0] == t_set);
      t_line_live_match[i] = (mshr_line_q[i] == t_line);
    end
    for (int j = 0; j < int'(NUM_WB); j++) t_wb_live_match[j] = (wb_line_q[j] == t_line);
    if (w_allocs_mshr) begin
      t_set_live_match[w_mshr_q]  = (w_line_q[SetBits-1:0] == t_set);
      t_line_live_match[w_mshr_q] = (w_line_q == t_line);
    end
    if (w_allocs_wb) t_wb_live_match[w_wb_q] = (w_victim_line == t_line);
  end

  // ---- Ways of T's set owned by valid MSHRs. A miss never takes one: its
  // tag is invalid while the MSHR fetches, and its fill installs there.
  logic [WAYS-1:0] way_reserved;
  logic unreserved_any;
  always_comb begin
    way_reserved = '0;
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      if (t_set_match_q[i] && mshr_valid[i])
        way_reserved = way_reserved | way_onehot(mshr_way_q[i]);
    end
    unreserved_any = !(&way_reserved);
  end

  // ---- Victim choice: the lowest way that is invalid and unowned, else the
  // pseudo-LRU way among the unowned ways. Taking the lowest unowned way
  // instead could keep one way from ever being replaced while misses own the
  // others' subtree. With one-cycle tags the choice and the dirty bits feed
  // only W's registers; delayed tags also use the dirty bits in T's
  // writeback-slot check (ExactVictimWb).
  logic [WAYS-1:0] free_ways;
  logic [WayBits-1:0] victim_way, hit_way;
  logic victim_dirty, hit_dirty;
  always_comb begin
    free_ways  = ~tag_rdata_valid & ~way_reserved;
    victim_way = plru_victim_among(plru_rdata, ~way_reserved);
    if (|free_ways) victim_way = lowest_way(free_ways);
    victim_dirty = tag_rdata_valid[victim_way] && tag_rdata_dirty[victim_way];
    // At most one way hits, so the hit way is an OR of the hit bits.
    hit_way = '0;
    for (int w = 0; w < int'(WAYS); w++) if (way_hit[w]) hit_way = hit_way | WayBits'(w);
    hit_dirty = |(way_hit & tag_rdata_dirty);
  end

  // ---- The T decision.
  logic                decide;
  logic                same_line;  // an MSHR fetches this very line
  logic [MshrBits-1:0] match_mshr;
  logic match_mergeable, match_waitable, same_line_ok;
  logic alloc_needs_wb, probe_needs_wb, alloc_ok, probe_hit_ok;
  logic clear_hit, clear_miss;  // T completes if it hits / misses
  logic tag_write_t_set, tag_write_in_set;  // the tag port writes T's / the incoming set
  logic t_stall, t_done;
  logic t_tag_write_collision, t_tag_response, t_tag_retry;
  logic t_is_read_hit, t_is_write_hit, t_is_alloc, t_is_merge, t_is_waiter;
  logic t_plain, t_wb_pending, t_is_probe_hit, t_is_probe_miss;
  logic stall_conflict, stall_conflict_any, stall_ways, stall_full, stall_wb_snapshot;

  // Discard a delayed tag response if a write to the same set crossed its
  // read, including an install on the response cycle. This prevents
  // old-tag/new-data hits. One-cycle BRAM tags are covered by a_hold and the
  // MSHR guards; only delayed reads need the sticky stale bit.
  assign t_tag_write_collision = TrackDelayedTagWrites && t_valid_q && tag_write_t_set;
  assign t_tag_response = (mstate_q == M_IDLE) && t_valid_q && tag_response_valid;
  assign t_tag_retry =
      t_tag_response && ((TrackDelayedTagWrites && t_tag_stale_q) || t_tag_write_collision);
  assign decide =
      t_tag_response && !((TrackDelayedTagWrites && t_tag_stale_q) || t_tag_write_collision);
  always_comb begin
    same_line  = |(t_line_match_q & mshr_valid);
    match_mshr = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if (t_line_match_q[i] && mshr_valid[i]) match_mshr = MshrBits'(i);
    end
    match_mergeable = mshr_write_q[match_mshr] && !mshr_has_waiter[match_mshr] &&
        ((mshr_state_q[match_mshr] == MS_PEND) || (mshr_state_q[match_mshr] == MS_SENT));
    match_waitable = !mshr_seats_full[match_mshr] &&
        ((mshr_state_q[match_mshr] == MS_PEND) || (mshr_state_q[match_mshr] == MS_SENT));
    same_line_ok = t_write_q ? match_mergeable : match_waitable;

    // Probes and stores wait for a pending writeback of their line: a store
    // that re-dirtied the copy could create a second writeback whose newer
    // snapshot arrives first, leaving stale data below. Preventing it keeps
    // at most one writeback per line in flight.
    t_plain = !t_probe_q;
    t_wb_pending = |(t_wb_match_q & wb_valid);
    alloc_needs_wb = ExactVictimWb ? victim_dirty : 1'b1;
    probe_needs_wb = ExactVictimWb ? hit_dirty : 1'b1;
    alloc_ok = unreserved_any && mshr_free_any && (!alloc_needs_wb || wb_free_any);
    probe_hit_ok = probe_free_any && (!probe_needs_wb || wb_free_any);

    // Whether T completes, by the compare's outcome. A request for a line in
    // transition merges, waits on a seat, or stalls whatever the tags say.
    // A pending probe acknowledgement holds off new read hits: hit data takes
    // the response port whenever it appears, so the port has to go quiet for
    // the acknowledgement to leave.
    clear_hit = t_plain ?
        (same_line ? same_line_ok : (t_write_q ? !t_wb_pending : !probe_ack_any)) :
        (!same_line && !t_wb_pending && probe_hit_ok);
    clear_miss = t_plain ? (same_line ? same_line_ok : alloc_ok) :
        (!same_line && !t_wb_pending && probe_free_any);

    t_is_read_hit = decide && t_plain && !same_line && hit && !t_write_q;
    t_is_write_hit = decide && t_plain && !same_line && hit && t_write_q;
    t_is_alloc = decide && t_plain && !same_line && !hit;
    t_is_merge = decide && t_plain && same_line && t_write_q;
    t_is_waiter = decide && t_plain && same_line && !t_write_q;
    t_is_probe_hit = decide && t_probe_q && !same_line && !t_wb_pending && hit;
    t_is_probe_miss = decide && t_probe_q && !same_line && !t_wb_pending && !hit;

    // The stall classes (reference and performance events).
    stall_conflict_any = t_plain ? (same_line && !same_line_ok) : (same_line || t_wb_pending);
    stall_conflict = decide && stall_conflict_any;
    stall_ways = t_is_alloc && !unreserved_any;
    stall_full = (t_is_alloc && unreserved_any &&
                  (!mshr_free_any || (alloc_needs_wb && !wb_free_any))) ||
        (t_is_probe_hit && !probe_hit_ok) || (t_is_probe_miss && !probe_free_any);
    stall_wb_snapshot = t_is_write_hit && t_wb_pending;
    t_stall = stall_conflict || stall_ways || stall_full || stall_wb_snapshot ||
        (t_is_read_hit && probe_ack_any);
  end

  // With one-cycle tags, factor decide && !t_stall by the compare: both
  // outcomes' clears are known before the tags return, so the final selects
  // between them by the way hits. Delayed tags use the direct expression.
  if (TrackDelayedTagWrites) begin : gen_t_done_direct
    assign t_done = decide && !t_stall;
  end else begin : gen_t_done_factored
    (* dont_touch = "true" *) logic t_ok_hit, t_ok_miss;
    assign t_ok_hit  = decide && clear_hit;
    assign t_ok_miss = decide && clear_miss;
    assign t_done    = (|way_hit) ? t_ok_hit : t_ok_miss;
  end

`ifdef CACHE_WAY_PROOF
  // The way choice, the factored completion, and the pseudo-LRU, for every
  // state (formal/cache_way_choice.sby).
  (* anyseq *)logic [PlruBits-1:0] proof_plru_state;
  (* anyseq *)logic [ WayBits-1:0] proof_touched_way;
  (* anyseq *)logic [    WAYS-1:0] proof_avail;
  always_comb begin
    // A completing allocation takes a way no valid MSHR owns.
    if (t_done && t_is_alloc) assert (!way_reserved[victim_way]);
    // The completion equals its reference form.
    assert (t_done == (decide && !t_stall));
    // A lone hit names its way.
    if ($onehot(way_hit)) assert (way_hit[hit_way]);
    if (WAYS > 1) begin
      // The way an access touches is never the set's next victim.
      assert (plru_victim(plru_touch(proof_plru_state, proof_touched_way)) != proof_touched_way);
      // The restricted walk picks a way in its set, and the pseudo-LRU way
      // whenever that one is in the set.
      if (|proof_avail) assert (proof_avail[plru_victim_among(proof_plru_state, proof_avail)]);
      if (proof_avail[plru_victim(proof_plru_state)])
        assert (plru_victim_among(proof_plru_state, proof_avail) == plru_victim(proof_plru_state));
    end
  end
`endif

  // T accepts when empty or completing, without a set hold or reread.
  // Skid and upstream offers are disjoint because ready excludes a full skid;
  // their OR is in_valid && !a_hold.
  logic sk_go, up_go, t_open, t_accept;
  assign sk_go    = sk_valid_q && !sk_hold;
  assign up_go    = up_req_fire && !up_hold;
  assign t_open   = !reread_q && (!t_valid_q || t_done);
  assign t_accept = (sk_go || up_go) && t_open;

  // ---- Read tags for a new T entry, a retry, or maintenance SCAN.
  // T holds one entry and CHECK waits for its response, so no response queue
  // is needed.
  logic tag_re_maint_or_retry, tag_re_open;
  assign tag_re_maint_or_retry = (mstate_q == M_FLUSH_SCAN) || ((mstate_q == M_IDLE) && reread_q);
  assign tag_re_open = (mstate_q == M_IDLE) && t_open;
  assign tag_re = tag_re_maint_or_retry || (tag_re_open && (sk_go || up_go));
  assign tag_raddr = (mstate_q == M_FLUSH_SCAN) ? flush_idx_q : (reread_q ? t_set : in_set);

  // ===========================================================================
  // Data-array read purpose pipeline (aligned with the array's read latency)
  // ===========================================================================
  // Each array read is either a hit response (kind 0) or a victim read bound
  // for a writeback slot (kind 1), from T (the L1s) or W (the L2), or the
  // flush walk.
  logic [DATA_READ_LATENCY-1:0] rp_valid_q;
  logic [DATA_READ_LATENCY-1:0] rp_victim_q;
  logic [UP_ID_BITS-1:0] rp_id_q[DATA_READ_LATENCY];
  logic [WbBits-1:0] rp_wb_q[DATA_READ_LATENCY];

  logic rp_push, rp_push_victim;
  logic [WbBits-1:0] rp_push_wb;
  logic [UP_ID_BITS-1:0] rp_push_id;
  // The stage that keeps or drops an L1 read (1; ParallelWayRead needs
  // DATA_READ_LATENCY >= 2).
  localparam int unsigned RpKeepStage = (DATA_READ_LATENCY > 1) ? 1 : 0;
  logic rp_out_valid, rp_out_victim;
  logic [UP_ID_BITS-1:0] rp_out_id;
  logic [WbBits-1:0] rp_out_wb;
  assign rp_out_valid = rp_valid_q[DATA_READ_LATENCY-1];
  assign rp_out_victim = rp_victim_q[DATA_READ_LATENCY-1];
  assign rp_out_id = rp_id_q[DATA_READ_LATENCY-1];
  assign rp_out_wb = rp_wb_q[DATA_READ_LATENCY-1];

  // Flush walk: CHECK waits for the set's tag response and picks its lowest
  // dirty way; WRITE reads that line into a writeback slot and marks it
  // clean, from registers. A multi-cycle tag array keeps CHECK self-held
  // until flush_tag_ready.
  logic [WAYS-1:0] flush_dirty;
  logic flush_tag_ready, flush_set_clean, flush_pick, flush_read;
  logic [WayBits-1:0] flush_way_q;
  logic [TagBits-1:0] flush_tag_q;
  logic [ WbBits-1:0] flush_wb_q;
  assign flush_dirty = tag_rdata_valid & tag_rdata_dirty;
  assign flush_tag_ready = (mstate_q == M_FLUSH_CHECK) && tag_response_valid;
  assign flush_set_clean = (flush_dirty == '0);
  assign flush_pick = flush_tag_ready && !flush_set_clean && wb_free_any;
  assign flush_read = (mstate_q == M_FLUSH_WRITE);

  // W's operation needs a line: a read hit's, or a dirty victim's.
  logic w_reads_data;
  assign w_reads_data = w_valid_q && ((w_op_q == W_READ_HIT) || w_has_victim);

  // The L1s read at T's decision, before its outcome is known: every
  // completed decision pushes a read, and the next stage, where W holds the
  // operation, keeps only those whose line W needs. The L2 reads from W, for
  // exactly those operations. The flush walk reads from WRITE in both.
  // Whether a read's line is used: it qualifies the L1 banks' collision
  // checks.
  assign rp_push_used = flush_read ||
      (t_done && (t_is_read_hit || (t_is_alloc && victim_dirty) || (t_is_probe_hit && hit_dirty)));
  always_comb begin
    rp_push        = 1'b0;
    rp_push_victim = 1'b0;
    rp_push_wb     = w_wb_q;
    rp_push_id     = w_id_q;
    rp_push_way    = flush_read ? flush_way_q : (hit ? hit_way : victim_way);
    data_re        = 1'b0;
    data_raddr     = flush_active ? row_of(flush_way_q, flush_idx_q) : row_of(w_way_q, w_set_q);
    data_rset      = flush_active ? flush_idx_q : t_set;
    if (ParallelWayRead) begin
      rp_push        = flush_read || t_done;
      rp_push_victim = flush_read;
      rp_push_wb     = flush_read ? flush_wb_q : wb_free_idx;
      rp_push_id     = t_id_q;
      data_re        = flush_read || decide;
    end else if (flush_read) begin
      rp_push        = 1'b1;
      rp_push_victim = 1'b1;
      rp_push_wb     = flush_wb_q;
      data_re        = 1'b1;
    end else if (w_reads_data) begin
      rp_push        = 1'b1;
      rp_push_victim = (w_op_q != W_READ_HIT);
      data_re        = 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rp_valid_q  <= '0;
      rp_victim_q <= '0;
    end else begin
      rp_valid_q[0]  <= rp_push;
      rp_victim_q[0] <= rp_push_victim;
      rp_id_q[0]     <= rp_push_id;
      rp_wb_q[0]     <= rp_push_wb;
      for (int k = 1; k < int'(DATA_READ_LATENCY); k++) begin
        rp_valid_q[k]  <= rp_valid_q[k-1];
        rp_victim_q[k] <= rp_victim_q[k-1];
        rp_id_q[k]     <= rp_id_q[k-1];
        rp_wb_q[k]     <= rp_wb_q[k-1];
      end
      // The L1s' stage after a T read, where W holds its operation: keep a
      // read hit's line and a dirty victim's, and mark the victims.
      if (ParallelWayRead) begin
        rp_valid_q[RpKeepStage]  <= rp_valid_q[0] && (rp_victim_q[0] || w_reads_data);
        rp_victim_q[RpKeepStage] <= rp_victim_q[0] || (w_op_q != W_READ_HIT);
      end
    end
  end

  // ===========================================================================
  // Acknowledgement queue (write hits, write misses, merges)
  // ===========================================================================
  // At most one push per cycle; outstanding IDs bound queue depth.
  // When not full, the write-pointer entry is outside the queue and may
  // capture T's ID every cycle. A push makes that captured ID visible.
  // ack_nonempty must equal (ack_wr_q != ack_rd_q). Every ordinary write
  // that completes T is a write hit, an allocation, or a merge.
  (* ram_style = "registers" *) logic [UP_ID_BITS-1:0] ack_id_q[AckDepth];
  logic [AckPtrBits-1:0] ack_wr_q, ack_rd_q;
  logic ack_nonempty, ack_push, ack_pop, ack_full, ack_last;
  assign ack_push = t_done && t_plain && t_write_q;
  assign ack_full = (ack_wr_q[AckPtrBits-1] != ack_rd_q[AckPtrBits-1]) &&
      (ack_wr_q[UP_ID_BITS-1:0] == ack_rd_q[UP_ID_BITS-1:0]);
  // One entry queued: a pop without a push empties the queue.
  assign ack_last = (ack_wr_q == ack_rd_q + 1'b1);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ack_wr_q     <= '0;
      ack_rd_q     <= '0;
      ack_nonempty <= 1'b0;
    end else begin
      if (ack_push) ack_wr_q <= ack_wr_q + 1'b1;
      if (ack_pop) ack_rd_q <= ack_rd_q + 1'b1;
      ack_nonempty <= ack_push || (ack_nonempty && !(ack_pop && ack_last));
    end
  end
  always_ff @(posedge i_clk) begin
    if (!ack_full) ack_id_q[ack_wr_q[UP_ID_BITS-1:0]] <= t_id_q;
  end

  // ===========================================================================
  // Response port: hit data (cannot wait) > probe acknowledgements >
  // acknowledgements > fill responses
  // ===========================================================================
  // Register the lowest next-cycle MS_RESP slot as a one-hot, for timing.
  // mshr_in_resp_next must track the slot state transitions exactly.
  logic                mshr_resp_any;
  logic [MshrBits-1:0] mshr_resp_sel;
  logic                mshr_resp_fire;
  logic [NUM_MSHR-1:0] mshr_resp_onehot_q, mshr_in_resp_next;
  always_comb begin
    mshr_resp_any = |mshr_resp_onehot_q;
    mshr_resp_sel = '0;
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      if (mshr_resp_onehot_q[i]) mshr_resp_sel = mshr_resp_sel | MshrBits'(i);
    end
  end

  logic resp_data_now, probe_ack_fire;
  assign resp_data_now  = rp_out_valid && !rp_out_victim;
  assign probe_ack_fire = !resp_data_now && probe_ack_any;
  assign ack_pop        = !resp_data_now && !probe_ack_any && ack_nonempty;
  assign mshr_resp_fire = !resp_data_now && !probe_ack_any && !ack_nonempty && mshr_resp_any;

  // A read MSHR answers its primary first, then its waiters in seat order; a
  // write MSHR only has waiters to answer.
  logic mshr_resp_is_waiter;
  assign mshr_resp_is_waiter =
      mshr_write_q[mshr_resp_sel] || mshr_resp_primary_done_q[mshr_resp_sel];

  assign o_up_resp_valid = resp_data_now || probe_ack_any || ack_nonempty || mshr_resp_any;
  assign o_up_resp_id = resp_data_now ? rp_out_id :
      probe_ack_any ? probe_id_q[probe_ack_sel] :
      ack_nonempty ? ack_id_q[ack_rd_q[UP_ID_BITS-1:0]] :
      (mshr_resp_is_waiter ? mshr_waiter_id_q[mshr_resp_sel][0] : mshr_id_q[mshr_resp_sel]);
  assign o_up_resp_rdata = resp_data_now ? data_rdata : mshr_data_q[mshr_resp_sel];
  assign o_up_resp_error = mshr_resp_fire && mshr_error_q[mshr_resp_sel];

  // ===========================================================================
  // Downstream request arbitration: fills first, then writebacks, with a
  // bounded turn for a writeback that fills keep out
  // ===========================================================================
  logic fill_req_any, wb_req_any;
  logic [MshrBits-1:0] fill_req_sel;
  logic [  WbBits-1:0] wb_req_sel;
  logic [MshrBits-1:0] fill_next_q;  // the miss slot the fill pick starts from
  logic [  WbBits-1:0] wb_next_q;  // the writeback slot the pick starts from
  logic [NUM_MSHR-1:0] fill_req_mask;  // miss slots whose fill can issue
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      fill_req_mask[i] = (mshr_state_q[i] == MS_PEND) && (mshr_wb_wait_q[i] == '0) &&
          !mshr_fill_held[i];
    end
    // Both picks rotate after the last slot they loaded, so each pending fill
    // wins within NUM_MSHR fill loads and each pending writeback within NUM_WB
    // writeback loads; a fixed order would let low slots that keep
    // reallocating starve a high one. Scan lower-priority indices first so
    // later assignments from the start slot upward win.
    fill_req_any = |fill_req_mask;
    fill_req_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((i < int'(fill_next_q)) && fill_req_mask[i]) fill_req_sel = MshrBits'(i);
    end
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((i >= int'(fill_next_q)) && fill_req_mask[i]) fill_req_sel = MshrBits'(i);
    end
    wb_req_any = 1'b0;
    wb_req_sel = '0;
    for (int j = int'(NUM_WB) - 1; j >= 0; j--) begin
      if ((j < int'(wb_next_q)) && (wb_state_q[j] == WB_PEND)) begin
        wb_req_any = 1'b1;
        wb_req_sel = WbBits'(j);
      end
    end
    for (int j = int'(NUM_WB) - 1; j >= 0; j--) begin
      if ((j >= int'(wb_next_q)) && (wb_state_q[j] == WB_PEND)) begin
        wb_req_any = 1'b1;
        wb_req_sel = WbBits'(j);
      end
    end
  end

  // Repeated fills could starve writebacks and every request waiting on them.
  // Count request-register loads lost to fills, then give a writeback the next
  // turn. A pending writeback wins within WbStarveLimit + 1 loads; rotation
  // bounds any slot's wait by NUM_WB * (WbStarveLimit + 1) loads. A fill
  // that can issue loses at most one load in every WbStarveLimit + 1 to a
  // writeback, and rotation loads it within NUM_MSHR fill loads.
  localparam int unsigned WbStarveLimit = 3;
  localparam int unsigned WbStarveBits  = $clog2(WbStarveLimit + 1);
  logic [WbStarveBits-1:0] wb_lost_q;
  logic                    wb_turn_q;

  // A slot leaves PEND when loaded into this request register, which holds
  // the payload until the downstream handshake.
  logic                    dq_valid_q;
  logic                    dq_is_wb_q;
  logic [LineAddrBits-1:0] dq_line_q;
  logic [    LineBits-1:0] dq_data_q;
  logic [DOWN_ID_BITS-1:0] dq_id_q;
  logic                    dq_maint_q;
  logic down_fire, dq_load, dq_load_is_wb;
  assign down_fire     = dq_valid_q && i_down_req_ready;
  assign dq_load       = (fill_req_any || wb_req_any) && (!dq_valid_q || down_fire);
  assign dq_load_is_wb = wb_req_any && (wb_turn_q || !fill_req_any);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wb_lost_q <= '0;
      wb_turn_q <= 1'b0;
      wb_next_q <= '0;
    end else if (dq_load && dq_load_is_wb) begin
      wb_lost_q <= '0;
      wb_turn_q <= 1'b0;
      wb_next_q <= (wb_req_sel == WbBits'(NUM_WB - 1)) ? '0 : wb_req_sel + 1'b1;
    end else if (dq_load && wb_req_any) begin
      // A fill loaded over a pending writeback. wb_turn_q is clear here (set,
      // it would have made this load a writeback's), so the count is below
      // the limit and cannot wrap.
      wb_lost_q <= wb_lost_q + 1'b1;
      if (wb_lost_q == WbStarveBits'(WbStarveLimit - 1)) wb_turn_q <= 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fill_next_q <= '0;
    end else if (dq_load && !dq_load_is_wb) begin
      fill_next_q <= (fill_req_sel == MshrBits'(NUM_MSHR - 1)) ? '0 : fill_req_sel + 1'b1;
    end
  end

  assign o_down_req_valid       = dq_valid_q;
  assign o_down_req_write       = dq_is_wb_q;
  assign o_down_req_addr        = {dq_line_q, {OffsetBits{1'b0}}};
  assign o_down_req_wdata       = dq_data_q;
  assign o_down_req_wstrb       = dq_is_wb_q ? {LINE_BYTES{1'b1}} : '0;
  assign o_down_req_id          = dq_id_q;
  assign o_down_req_maintenance = dq_valid_q && dq_maint_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dq_valid_q <= 1'b0;
    end else begin
      if (dq_load) begin
        dq_valid_q <= 1'b1;
        dq_is_wb_q <= dq_load_is_wb;
        dq_line_q <= dq_load_is_wb ? wb_line_q[wb_req_sel] : mshr_line_q[fill_req_sel];
        dq_data_q <= wb_data_q[wb_req_sel];
        dq_id_q    <= dq_load_is_wb ?
            {1'b1, DownSlotBits'(wb_req_sel)} : {1'b0, DownSlotBits'(fill_req_sel)};
        dq_maint_q <= dq_load_is_wb ? wb_maint_q[wb_req_sel] : mshr_maint_q[fill_req_sel];
      end else if (down_fire) begin
        dq_valid_q <= 1'b0;
      end
    end
  end

  // Downstream responses, decoded by id type.
  logic resp_is_fill, resp_is_wb;
  logic [MshrBits-1:0] resp_fill_slot;
  logic [  WbBits-1:0] resp_wb_slot;
  logic response_error, fatal_fill_error, fatal_writeback_error;
  assign response_error = ENABLE_RESPONSE_ERRORS && i_down_resp_error;
  assign fatal_fill_error = i_down_resp_valid && response_error &&
      !i_down_resp_id[DOWN_ID_BITS-1] && mshr_write_q[resp_fill_slot];
  assign fatal_writeback_error = i_down_resp_valid && response_error &&
      i_down_resp_id[DOWN_ID_BITS-1];
  // A failed buffered write is not an acknowledgement and a failed RMW
  // refill must not overwrite the MSHR's dirty bytes or byte-valid mask.
  assign resp_is_fill = i_down_resp_valid && !i_down_resp_id[DOWN_ID_BITS-1] && !fatal_fill_error;
  assign resp_is_wb = i_down_resp_valid && i_down_resp_id[DOWN_ID_BITS-1] && !response_error;
  assign resp_fill_slot = MshrBits'(i_down_resp_id[DownSlotBits-1:0]);
  assign resp_wb_slot = WbBits'(i_down_resp_id[DownSlotBits-1:0]);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_fatal_error <= 1'b0;
      o_fatal_addr  <= '0;
    end else if (!o_fatal_error && (fatal_fill_error || fatal_writeback_error)) begin
      o_fatal_error <= 1'b1;
      o_fatal_addr <= fatal_fill_error ?
          {mshr_line_q[resp_fill_slot], {OffsetBits{1'b0}}} :
          {wb_line_q[resp_wb_slot], {OffsetBits{1'b0}}};
    end
  end

  // ===========================================================================
  // Write-port arbitration: the sweep or the flush walk's clean marks while
  // maintenance runs; otherwise W's committed writes, then MSHR fill writes
  // (which wait).
  // ===========================================================================
  logic w_writes_data, w_writes_tag;
  assign w_writes_data = w_valid_q && (w_op_q == W_WRITE_HIT);
  assign w_writes_tag  = w_valid_q && ((w_op_q == W_WRITE_HIT) || w_is_alloc || w_is_probe_hit);

  // MSHR fill/allocate write: the lowest slot ready to write whose victim (if
  // any) has been captured, when both ports are free this cycle. A slot
  // still waiting for a writeback of its own line (mshr_wb_wait_q) is not
  // ready: a fill already waited for it before fetching, and an allocation
  // that needs no fetch must wait here, or it would install the line dirty
  // beside its older copy and a later eviction could put a second writeback
  // of the line in flight.
  logic                mshr_write_any;
  logic [MshrBits-1:0] mshr_write_sel;
  logic                mshr_write_fire;
  always_comb begin
    mshr_write_any = 1'b0;
    mshr_write_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((mshr_state_q[i] == MS_WRITE) && (mshr_wb_wait_q[i] == '0) &&
          (!mshr_has_victim_q[i] || (wb_state_q[mshr_victim_wb_q[i]] != WB_FILLING))) begin
        mshr_write_any = 1'b1;
        mshr_write_sel = MshrBits'(i);
      end
    end
  end
  // Register the selected slot one cycle before its RAM write, for timing.
  // Its set and way come along: a slot keeps its line and way until it is
  // free again, so fw_set_q and fw_way_q name the slot's row whenever
  // fw_valid_q, and neither the write ports nor the set checks below need a
  // slot mux for it.
  logic                fw_valid_q;
  logic [MshrBits-1:0] fw_sel_q;
  logic [ SetBits-1:0] fw_set_q;
  logic [ WayBits-1:0] fw_way_q;
  assign mshr_write_fire = fw_valid_q && !w_writes_data && !w_writes_tag;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fw_valid_q <= 1'b0;
    end else if (!fw_valid_q || mshr_write_fire) begin
      // Pick the next slot as the current one fires (or when idle). A picked
      // slot moves to MS_WRITING so it is not picked twice.
      fw_valid_q <= (mstate_q == M_IDLE) && mshr_write_any;
      fw_sel_q   <= mshr_write_sel;
      fw_set_q   <= mshr_line_q[mshr_write_sel][SetBits-1:0];
      fw_way_q   <= mshr_way_q[mshr_write_sel];
    end
  end

  // Whether the tag port writes T's set, or the incoming request's, this
  // cycle (the delayed-tag stale tracking). These matter only while the
  // pipeline holds a request, which is in M_IDLE, where the port writes W's
  // set or a fill's set. Each source's set is compared and the result
  // selected by a registered copy of W's tag-write decode, so T's decision
  // does not wait on the write-port muxes.
  logic w_set_is_t, fw_set_is_t, w_set_is_in, fw_set_is_in;
  assign w_set_is_t = (w_set_q == t_set);
  assign fw_set_is_t = (fw_set_q == t_set);
  assign w_set_is_in = (w_set_q == in_set);
  assign fw_set_is_in = (fw_set_q == in_set);
  assign tag_write_t_set = w_tag_write_q ? w_set_is_t : (fw_valid_q && fw_set_is_t);
  assign tag_write_in_set = w_tag_write_q ? w_set_is_in : (fw_valid_q && fw_set_is_in);

  // Next cycle's MS_RESP slots and the registered responder (see the
  // response port).
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      mshr_in_resp_next[i] =
          !(w_valid_q && w_is_alloc && (w_mshr_q == MshrBits'(i))) &&
          (((mshr_state_q[i] == MS_WRITING) && mshr_write_fire && (fw_sel_q == MshrBits'(i)) &&
            (!mshr_write_q[i] || mshr_has_waiter[i])) ||
           ((mshr_state_q[i] == MS_MERGE) && mshr_error_q[i]) ||
           ((mshr_state_q[i] == MS_RESP) &&
            !(mshr_resp_fire && (mshr_resp_sel == MshrBits'(i)) &&
              (mshr_resp_is_waiter ? !mshr_more_waiters[i] : !mshr_has_waiter[i]))));
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mshr_resp_onehot_q <= '0;
    end else begin
      // The lowest slot of the next cycle's MS_RESP set.
      mshr_resp_onehot_q <= mshr_in_resp_next & ~(mshr_in_resp_next - 1'b1);
    end
  end

  // Store bytes from W win over a same-cycle fill. While MS_SENT, unstored
  // bytes capture response data every cycle, for timing. No consumer reads
  // them until install or response; leaving MS_SENT captures the actual fill.
  // Strobed bytes remain protected, and strobes are used only before the fill.
  logic [  LineBits-1:0] mshr_data_d [NUM_MSHR];
  logic [LINE_BYTES-1:0] mshr_wstrb_d[NUM_MSHR];
  for (genvar gm = 0; gm < int'(NUM_MSHR); gm++) begin : gen_mshr_payload
    logic alloc_here, merge_here, fill_window;
    assign alloc_here  = w_valid_q && (w_op_q == W_ALLOC) && (w_mshr_q == MshrBits'(gm));
    assign merge_here  = w_valid_q && (w_op_q == W_MERGE) && (w_mshr_q == MshrBits'(gm));
    assign fill_window = (mshr_state_q[gm] == MS_SENT);
    for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_byte
      logic take_store_byte, take_fill_byte;
      assign take_store_byte = alloc_here || (merge_here && w_wstrb_q[gb]);
      assign take_fill_byte = fill_window && !(mshr_write_q[gm] && mshr_wstrb_q[gm][gb]);
      assign mshr_data_d[gm][gb*8+:8] = take_store_byte ? w_wdata_q[gb*8+:8] :
          (take_fill_byte ? i_down_resp_rdata[gb*8+:8] : mshr_data_q[gm][gb*8+:8]);
      assign mshr_wstrb_d[gm][gb] = alloc_here ? (w_write_q && w_wstrb_q[gb]) :
          ((merge_here && w_wstrb_q[gb]) || mshr_wstrb_q[gm][gb]);
    end
    always_ff @(posedge i_clk) begin
      if (!i_rst) begin
        mshr_data_q[gm]  <= mshr_data_d[gm];
        mshr_wstrb_q[gm] <= mshr_wstrb_d[gm];
      end
    end
  end

`ifdef CACHE_MSHR_PAYLOAD_PROOF
  // Reference captures only on the matching fill response. Compare every
  // readable byte; exclude unstored bytes still awaiting a fill, post-fill
  // strobes, and responses to slots not awaiting a fill.
  logic [LineBits-1:0] fill_merged;
  for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_fill_merge
    assign fill_merged[gb*8+:8] =
        (mshr_write_q[resp_fill_slot] && mshr_wstrb_q[resp_fill_slot][gb]) ?
        mshr_data_q[resp_fill_slot][gb*8+:8] : i_down_resp_rdata[gb*8+:8];
  end

  // A W-stage merge overlays its bytes on the MSHR's data, or on the fill
  // being captured this cycle if the response lands now.
  logic w_merge_on_fill;
  assign w_merge_on_fill = resp_is_fill && (resp_fill_slot == w_mshr_q);
  logic [LineBits-1:0] merge_base, merge_data;
  assign merge_base = w_merge_on_fill ? fill_merged : mshr_data_q[w_mshr_q];
  for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_w_merge
    assign merge_data[gb*8+:8] = w_wstrb_q[gb] ? w_wdata_q[gb*8+:8] : merge_base[gb*8+:8];
  end
  for (genvar gm = 0; gm < int'(NUM_MSHR); gm++) begin : gen_payload_reference
    logic [  LineBits-1:0] data_ref;
    logic [LINE_BYTES-1:0] strb_ref;
    logic fill_lands, waiting, ref_alloc, ref_merge, data_ok;
    always_comb begin
      data_ref = mshr_data_q[gm];
      strb_ref = mshr_wstrb_q[gm];
      fill_lands = resp_is_fill && (resp_fill_slot == MshrBits'(gm));
      waiting = (mshr_state_q[gm] == MS_SENT);
      ref_alloc = w_valid_q && (w_op_q == W_ALLOC) && (w_mshr_q == MshrBits'(gm));
      ref_merge = w_valid_q && (w_op_q == W_MERGE) && (w_mshr_q == MshrBits'(gm));
      if (waiting && fill_lands) begin
        data_ref = fill_merged;
        strb_ref = '1;
      end
      if (ref_alloc) begin
        data_ref = w_wdata_q;
        strb_ref = w_write_q ? w_wstrb_q : '0;
      end
      if (ref_merge) begin
        data_ref = merge_data;
        strb_ref = (w_merge_on_fill ? {LINE_BYTES{1'b1}} : mshr_wstrb_q[gm]) | w_wstrb_q;
      end
      // A byte is compared unless a response lands on a slot that is not
      // waiting for one, or the slot is still waiting and the byte holds
      // neither its store's data nor a store written this cycle.
      data_ok = 1'b1;
      for (int b = 0; b < int'(LINE_BYTES); b++) begin
        if (!(fill_lands && !waiting) &&
            !(waiting && !fill_lands && !ref_alloc && !(ref_merge && w_wstrb_q[b]) &&
              !(mshr_write_q[gm] && mshr_wstrb_q[gm][b])) &&
            (mshr_data_d[gm][b*8+:8] != data_ref[b*8+:8])) begin
          data_ok = 1'b0;
        end
      end
      assert (data_ok);
      assert (fill_lands || (mshr_wstrb_d[gm] == strb_ref));
    end
  end
`endif

  // Writeback slots still pending after this cycle's acknowledgement: the
  // mask a newly allocated MSHR must wait for.
  logic [NUM_WB-1:0] resp_wb_onehot, wb_still_pending;
  always_comb begin
    resp_wb_onehot = '0;
    if (resp_is_wb) resp_wb_onehot[resp_wb_slot] = 1'b1;
    wb_still_pending = wb_valid & ~resp_wb_onehot;
  end

  always_comb begin
    tag_we        = '0;
    tag_waddr     = w_set_q;
    tag_wdata     = '0;
    data_row_we   = 1'b0;
    data_waddr    = row_of(w_way_q, w_set_q);
    data_wbyte_en = '0;
    data_wdata    = w_wdata_q;
    plru_we       = 1'b0;
    plru_waddr    = w_set_q;
    plru_wdata    = plru_touch(w_plru_q, w_way_q);

    if (mstate_q == M_SWEEP) begin
      // FPGA: clear every way of one set, and its replacement state, per
      // cycle. Fast (sim): the bulk clear zeroes every entry this single
      // cycle, so no per-set write is issued.
      if (SIM_FAST_MAINT == 0) begin
        tag_we     = '1;
        tag_waddr  = sweep_idx_q;
        tag_wdata  = '0;
        plru_we    = 1'b1;
        plru_waddr = sweep_idx_q;
        plru_wdata = '0;
      end
    end else if (flush_read) begin
      // Written back (via a writeback slot): keep the line valid, clear dirty.
      tag_we    = way_onehot(flush_way_q);
      tag_waddr = flush_idx_q;
      tag_wdata = {1'b1, 1'b0, flush_tag_q};
    end else begin
      // Hits and allocations touch the set's replacement state, allocations
      // only one time in 32 with BIMODAL_INSERT.
      plru_we = w_valid_q && ((w_op_q == W_READ_HIT) || (w_op_q == W_WRITE_HIT) ||
                              (w_is_alloc && fill_touch));
      if (w_valid_q && (w_op_q == W_WRITE_HIT)) begin
        data_row_we   = 1'b1;
        data_wbyte_en = w_wstrb_q;
        tag_we        = way_onehot(w_way_q);
        tag_wdata     = {1'b1, 1'b1, w_tag_q};
      end else if (w_valid_q && (w_is_alloc || (w_op_q == W_PROBE_INVAL))) begin
        // The victim's or the probed line's tag: valid=0, dirty=0.
        tag_we    = way_onehot(w_way_q);
        tag_wdata = '0;
      end else if (w_valid_q && (w_op_q == W_PROBE_CLEAN)) begin
        // Written back through a slot if it was dirty: valid, clean.
        tag_we    = way_onehot(w_way_q);
        tag_wdata = {1'b1, 1'b0, w_tag_q};
      end else if (mshr_write_fire) begin
        data_row_we = 1'b1;
        data_waddr = row_of(fw_way_q, fw_set_q);
        data_wbyte_en = '1;
        data_wdata = mshr_data_q[fw_sel_q];
        tag_we = way_onehot(fw_way_q);
        tag_waddr = fw_set_q;
        tag_wdata = {1'b1, mshr_write_q[fw_sel_q], mshr_line_q[fw_sel_q][LineAddrBits-1-:TagBits]};
      end
    end
  end

  // W's operation if T completes this cycle.
  w_op_e w_op_next;
  assign w_op_next = t_is_read_hit ? W_READ_HIT : t_is_write_hit ? W_WRITE_HIT :
      t_is_alloc ? W_ALLOC : t_is_merge ? W_MERGE : t_is_waiter ? W_WAITER :
      t_is_probe_hit ? (t_probe_inval_q ? W_PROBE_INVAL : W_PROBE_CLEAN) : W_NONE;

  // ===========================================================================
  // Stage A/T/W registers
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sk_valid_q     <= 1'b0;
      t_valid_q      <= 1'b0;
      reread_q       <= 1'b0;
      t_tag_stale_q  <= 1'b0;
      w_valid_q      <= 1'b0;
      w_op_q         <= W_NONE;
      w_tag_write_q  <= 1'b0;
      w_data_write_q <= 1'b0;
    end else begin
      // Skid validity records only a fired request T cannot take this cycle;
      // release it when T takes it.
      if (up_req_fire && !t_accept) begin
        sk_valid_q <= 1'b1;
      end else if (sk_valid_q && t_accept) begin
        sk_valid_q <= 1'b0;
      end

      // Capture every fired payload for timing. Direct T acceptance leaves
      // sk_valid_q clear, so that unused skid copy cannot become visible.
      if (up_req_fire) begin
        sk_write_q <= i_up_req_write;
        sk_addr_q  <= i_up_req_addr;
        sk_wdata_q <= i_up_req_wdata;
        sk_wstrb_q <= i_up_req_wstrb;
        sk_id_q    <= i_up_req_id;
        sk_maint_q <= i_up_req_maintenance;
        sk_probe_q <= i_up_req_probe;
        sk_probe_inval_q <= i_up_req_probe_inval;
      end

      // T: take the presented request, or hold while its response/retry is in
      // flight. Slot identities are refreshed every held cycle because a slot
      // can retire and be reallocated during a multi-cycle tag lookup.
      if (t_accept) begin
        t_valid_q      <= 1'b1;
        t_set_match_q  <= in_set_match;
        t_line_match_q <= in_line_match;
        t_wb_match_q   <= in_wb_match;
      end else if (t_done) begin
        t_valid_q <= 1'b0;
      end else if (t_valid_q) begin
        t_set_match_q  <= t_set_live_match;
        t_line_match_q <= t_line_live_match;
        t_wb_match_q   <= t_wb_live_match;
      end
      // decide && !t_done is decide && t_stall.
      reread_q <= t_tag_retry || (decide && !t_done);

      // Capture whenever T is empty or completing. Every accept meets this
      // condition; other captures remain invisible because T stays invalid.
      // Decisions, write effects, and data reads require a valid T entry.
      if (!t_valid_q || t_done) begin
        t_write_q       <= in_write;
        t_addr_q        <= in_addr;
        t_wdata_q       <= in_wdata;
        t_wstrb_q       <= in_wstrb;
        t_id_q          <= in_id;
        t_maint_q       <= in_maint;
        t_probe_q       <= in_probe;
        t_probe_inval_q <= in_probe_inval;
      end

      // Read-first memory returns the old lane on a same-address write. Track
      // every same-set write from issue through response and discard the
      // response if crossed. A retry starts a fresh observation window; a
      // same-edge collision wins over that clear.
      if (t_accept) begin
        t_tag_stale_q <= TrackDelayedTagWrites && tag_write_in_set;
      end else if (reread_q) begin
        t_tag_stale_q <= TrackDelayedTagWrites && tag_write_t_set;
      end else if (t_tag_write_collision) begin
        t_tag_stale_q <= 1'b1;
      end else if (t_done) begin
        t_tag_stale_q <= 1'b0;
      end

      // W: the committed decision.
      w_valid_q <= t_done;
      w_op_q <= t_done ? w_op_next : W_NONE;
      w_tag_write_q <= t_done && ((w_op_next == W_WRITE_HIT) || (w_op_next == W_ALLOC) ||
                                  (w_op_next == W_PROBE_CLEAN) || (w_op_next == W_PROBE_INVAL));
      w_data_write_q <= t_done && (w_op_next == W_WRITE_HIT);
    end
  end

  // Capture W unconditionally for timing. All effects require w_valid_q or
  // a W operation; w_op_q is W_NONE when empty, so unused captures are invisible.
  always_ff @(posedge i_clk) begin
    w_set_q <= t_set;
    w_tag_q <= t_tag;
    w_line_q <= t_line;
    w_write_q <= t_write_q;
    w_wdata_q <= t_wdata_q;
    w_wstrb_q <= t_wstrb_q;
    w_id_q <= t_id_q;
    w_maint_q <= t_maint_q;
    w_probe_q <= t_probe_q;
    w_mshr_q <= t_is_alloc ? mshr_free_idx : match_mshr;
    w_wb_q <= wb_free_idx;
    w_way_q <= hit ? hit_way : victim_way;
    w_hit_dirty_q <= hit_dirty;
    w_victim_dirty_q <= victim_dirty;
    w_victim_tag_q <= tag_rdata_tag[victim_way];
    w_plru_q <= plru_rdata;
    w_probe_slot_q <= probe_free_idx;
    w_needs_fill_q <= !(t_write_q && (&t_wstrb_q));
    w_wb_wait_q <= t_wb_match_q & wb_valid;
  end

  // The seat a W-stage waiter takes: the lowest free one.
  logic [SeatBits-1:0] w_seat;
  always_comb begin
    w_seat = '0;
    for (int s = int'(NUM_WAITERS) - 1; s >= 0; s--) begin
      if (!mshr_waiter_valid_q[w_mshr_q][s]) w_seat = SeatBits'(s);
    end
  end

  // ===========================================================================
  // MSHR and writeback slot state
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < int'(NUM_MSHR); i++) begin
        mshr_state_q[i]        <= MS_FREE;
        mshr_waiter_valid_q[i] <= '0;
        mshr_wb_wait_q[i]      <= '0;
      end
      for (int j = 0; j < int'(NUM_WB); j++) wb_state_q[j] <= WB_FREE;
      wb_probe_q    <= '0;
      probe_valid_q <= '0;
      probe_ack_q   <= '0;
      mshr_error_q <= '0;
    end else begin
      // ---- Writeback slots ------------------------------------------------
      // Victim data arrives through the read pipeline; the ack frees the slot
      // and releases any fill that waited for this line's writeback.
      if (rp_out_valid && rp_out_victim) begin
        wb_data_q[rp_out_wb]  <= data_rdata;
        wb_state_q[rp_out_wb] <= WB_PEND;
      end
      if (dq_load && dq_load_is_wb) wb_state_q[wb_req_sel] <= WB_SENT;
      if (resp_is_wb) begin
        wb_state_q[resp_wb_slot] <= WB_FREE;
        for (int i = 0; i < int'(NUM_MSHR); i++)
        mshr_wb_wait_q[i] <= mshr_wb_wait_q[i] & ~resp_wb_onehot;
      end
      // Allocation: W's victim, or the flush walk's dirty line.
      if (w_allocs_wb) begin
        wb_state_q[w_wb_q]      <= WB_FILLING;
        wb_line_q[w_wb_q]       <= w_victim_line;
        wb_maint_q[w_wb_q]      <= w_maint_q;
        wb_probe_q[w_wb_q]      <= !w_is_alloc;
        wb_probe_slot_q[w_wb_q] <= w_probe_slot_q;
      end
      if (flush_read) begin
        wb_state_q[flush_wb_q] <= WB_FILLING;
        wb_line_q[flush_wb_q]  <= {flush_tag_q, flush_idx_q};
        wb_maint_q[flush_wb_q] <= 1'b1;
        wb_probe_q[flush_wb_q] <= 1'b0;
      end

      // ---- Probe slots ------------------------------------------------------
      // Taken at the probe's decision; acknowledged from W unless a dirty
      // copy is being written back, then when that writeback is acknowledged;
      // freed by the requester's release.
      if (probe_ack_fire) probe_ack_q[probe_ack_sel] <= 1'b0;
      for (int k = 0; k < int'(ProbeSlots); k++) begin
        if ((NUM_PROBE > 0) && i_probe_release_valid && probe_valid_q[k] &&
            (probe_id_q[k] == i_probe_release_id)) begin
          probe_valid_q[k] <= 1'b0;
        end
      end
      if (resp_is_wb && wb_probe_q[resp_wb_slot]) begin
        probe_ack_q[wb_probe_slot_q[resp_wb_slot]] <= 1'b1;
      end
      // The slot's line, id and kind are captured below while it is free.
      if (t_done && t_probe_q) probe_valid_q[probe_free_idx] <= 1'b1;
      if (w_valid_q && w_probe_q && !w_has_victim) probe_ack_q[w_probe_slot_q] <= 1'b1;

      // ---- MSHRs ------------------------------------------------------------
      for (int i = 0; i < int'(NUM_MSHR); i++) begin
        unique case (mshr_state_q[i])
          MS_PEND:
          if (dq_load && !dq_load_is_wb && (fill_req_sel == MshrBits'(i)))
            mshr_state_q[i] <= MS_SENT;
          MS_SENT:
          if (resp_is_fill && (resp_fill_slot == MshrBits'(i))) begin
            mshr_state_q[i] <= MS_MERGE;
            mshr_error_q[i] <= response_error;
            mshr_resp_primary_done_q[i] <= 1'b0;
          end
          // Keep the merge cycle so a read waiter accepted with the response
          // reaches its seat before primary completion. Failed data never
          // enters the array or installs a valid tag.
          MS_MERGE: mshr_state_q[i] <= mshr_error_q[i] ? MS_RESP : MS_WRITE;
          MS_WRITE:
          if ((!fw_valid_q || mshr_write_fire) && (mstate_q == M_IDLE) && mshr_write_any &&
              (mshr_write_sel == MshrBits'(i)))
            mshr_state_q[i] <= MS_WRITING;
          MS_WRITING:
          if (mshr_write_fire && (fw_sel_q == MshrBits'(i))) begin
            mshr_state_q[i] <= (!mshr_write_q[i] || mshr_has_waiter[i]) ? MS_RESP : MS_FREE_WAIT;
            mshr_resp_primary_done_q[i] <= 1'b0;
          end
          MS_RESP:
          if (mshr_resp_fire && (mshr_resp_sel == MshrBits'(i))) begin
            if (mshr_resp_is_waiter ? !mshr_more_waiters[i] : !mshr_has_waiter[i]) begin
              mshr_state_q[i] <= MS_FREE_WAIT;
            end else if (!mshr_resp_is_waiter) begin
              mshr_resp_primary_done_q[i] <= 1'b1;
            end else begin
              // Seat 0 is answered; the waiters behind it move down.
              for (int s = 0; s < int'(NUM_WAITERS) - 1; s++) begin
                mshr_waiter_valid_q[i][s] <= mshr_waiter_valid_q[i][s+1];
                mshr_waiter_id_q[i][s]    <= mshr_waiter_id_q[i][s+1];
              end
              mshr_waiter_valid_q[i][NUM_WAITERS-1] <= 1'b0;
            end
          end
          MS_FREE_WAIT: begin
            mshr_state_q[i]        <= MS_FREE;
            mshr_waiter_valid_q[i] <= '0;
          end
          default: ;
        endcase
      end

      // W-stage effects on the MSHRs (an allocation targets a free slot; a
      // merge/waiter targets a pending one).
      if (w_valid_q && w_is_alloc) begin
        mshr_state_q[w_mshr_q]             <= w_needs_fill_q ? MS_PEND : MS_WRITE;
        mshr_line_q[w_mshr_q]              <= w_line_q;
        mshr_way_q[w_mshr_q]               <= w_way_q;
        mshr_id_q[w_mshr_q]                <= w_id_q;
        mshr_write_q[w_mshr_q]             <= w_write_q;
        mshr_maint_q[w_mshr_q]             <= w_maint_q;
        mshr_has_victim_q[w_mshr_q]        <= w_has_victim;
        mshr_victim_wb_q[w_mshr_q]         <= w_wb_q;
        mshr_waiter_valid_q[w_mshr_q]      <= '0;
        mshr_wb_wait_q[w_mshr_q]           <= w_wb_wait_q & wb_still_pending;
        mshr_resp_primary_done_q[w_mshr_q] <= 1'b0;
        mshr_error_q[w_mshr_q]             <= 1'b0;
      end
      if (w_valid_q && (w_op_q == W_WAITER)) begin
        mshr_waiter_valid_q[w_mshr_q][w_seat] <= 1'b1;
        mshr_waiter_id_q[w_mshr_q][w_seat]    <= w_id_q;
      end
    end
  end

  // Free slots capture T every cycle, including the edge allocating them.
  // Only held slots are read: fill and release checks require probe_valid_q,
  // and a pending acknowledgement implies a held slot.
  always_ff @(posedge i_clk) begin
    for (int k = 0; k < int'(ProbeSlots); k++) begin
      if (!probe_valid_q[k]) begin
        probe_inval_q[k] <= t_probe_inval_q;
        probe_line_q[k]  <= t_line;
        probe_id_q[k]    <= t_id_q;
      end
    end
  end

  // ===========================================================================
  // Maintenance: sweep and writeback-all walk
  // ===========================================================================
  // Real-FSM (FPGA) writeback-all acceleration: bound the set walk to the
  // [wb_lo_q, wb_hi_q] span of sets dirtied since the last writeback-all.
  // wb_any_q == 0 means no dirty lines. Dirty lines are created only by W's
  // write hits and by write-allocate fills, both of which pass through tag_we
  // with the dirty bit set.
  logic [SetBits-1:0] wb_lo_q, wb_hi_q;
  logic wb_any_q;
  logic dirty_set;
  assign dirty_set = (|tag_we) && tag_wdata[TagBits];

  // Fast maintenance (SIM_FAST_MAINT, simulation only): a shadow of the tag
  // array's dirty bits, entry {set, way}, updated by the same writes that
  // update the tag RAM, so writeback-all can jump straight to dirty sets.
  logic any_dirty_full;
  logic [SetBits-1:0] first_dirty_full;
  if (SIM_FAST_MAINT != 0) begin : gen_fast_maint
    logic [NumLines-1:0] dirty_shadow_q;
    // The 2 MiB L2's shadow is 32,768 bits; clearing it replicates past the
    // advisory limit of Verilator. Simulation-only state, so the width is fine.
    /* verilator lint_off WIDTHCONCAT */
    always_ff @(posedge i_clk) begin
      if (i_rst) dirty_shadow_q <= '0;
      else if (tag_bulk_clear) dirty_shadow_q <= '0;
      else
        for (int w = 0; w < int'(WAYS); w++)
        if (tag_we[w]) dirty_shadow_q[int'(tag_waddr)*int'(WAYS)+w] <= tag_wdata[TagBits];
    end
    /* verilator lint_on WIDTHCONCAT */
    always_comb begin
      any_dirty_full   = 1'b0;
      first_dirty_full = '0;
      if ((mstate_q == M_IDLE && i_writeback_all) || flush_active) begin
        for (int set = int'(NumSets) - 1; set >= 0; set--) begin
          if (dirty_shadow_q[set*int'(WAYS)+:WAYS] != '0) begin
            any_dirty_full   = 1'b1;
            first_dirty_full = SetBits'(set);
          end
        end
      end
    end
  end else begin : gen_no_fast_maint
    assign any_dirty_full   = 1'b0;
    assign first_dirty_full = '0;
  end

  // The walk is complete once CHECK finds the last set of its span (or, fast,
  // the last dirty set) clean; the maintenance state then drains the
  // writeback slots. A set with a dirty way is scanned again after each
  // writeback until it is clean.
  logic walk_done;
  assign walk_done = flush_tag_ready && flush_set_clean &&
      ((SIM_FAST_MAINT != 0) ? !any_dirty_full : (!wb_any_q || (flush_idx_q == wb_hi_q)));

  assign pipeline_idle = !sk_valid_q && !t_valid_q && !w_valid_q && !reread_q &&
      (tag_response_valid_q == '0) && (mshr_valid == '0) && (wb_valid == '0) &&
      (rp_valid_q == '0) && !ack_nonempty && (probe_valid_q == '0);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mstate_q    <= M_SWEEP;
      sweep_idx_q <= '0;
      wb_lo_q     <= {SetBits{1'b1}};
      wb_hi_q     <= '0;
      wb_any_q    <= 1'b0;
    end else begin
      // Dirty-span tracker.
      if (dirty_set) begin
        wb_lo_q  <= (!wb_any_q || (tag_waddr < wb_lo_q)) ? tag_waddr : wb_lo_q;
        wb_hi_q  <= (!wb_any_q || (tag_waddr > wb_hi_q)) ? tag_waddr : wb_hi_q;
        wb_any_q <= 1'b1;
      end

      unique case (mstate_q)
        M_SWEEP: begin
          if (SIM_FAST_MAINT != 0) begin
            mstate_q <= M_IDLE;
          end else begin
            sweep_idx_q <= sweep_idx_q + 1'b1;
            if (sweep_idx_q == {SetBits{1'b1}}) mstate_q <= M_IDLE;
          end
        end

        M_IDLE: begin
          // Maintenance has priority and waits for the pipeline to drain
          // (ready is masked while it is requested).
          if (i_invalidate_all && pipeline_idle) begin
            sweep_idx_q <= '0;
            mstate_q    <= M_SWEEP;
          end else if (i_writeback_all && pipeline_idle) begin
            flush_idx_q <= (SIM_FAST_MAINT != 0) ? first_dirty_full : (wb_any_q ? wb_lo_q : '0);
            mstate_q    <= M_FLUSH_SCAN;
          end
        end

        M_FLUSH_SCAN: mstate_q <= M_FLUSH_CHECK;

        M_FLUSH_CHECK: begin
          if (flush_tag_ready) begin
            if (walk_done) begin
              mstate_q <= M_FLUSH_DRAIN;
            end else if (flush_pick) begin
              // Write the lowest dirty way back next cycle, then scan the set
              // again for the others.
              flush_way_q <= lowest_way(flush_dirty);
              flush_tag_q <= tag_rdata_tag[lowest_way(flush_dirty)];
              flush_wb_q  <= wb_free_idx;
              mstate_q    <= M_FLUSH_WRITE;
            end else begin
              // A clean set moves the walk on; a dirty one with no writeback
              // slot free is scanned again.
              if (flush_set_clean) begin
                flush_idx_q <= (SIM_FAST_MAINT != 0) ? first_dirty_full : flush_idx_q + 1'b1;
              end
              mstate_q <= M_FLUSH_SCAN;
            end
          end
        end

        M_FLUSH_WRITE: mstate_q <= M_FLUSH_SCAN;

        M_FLUSH_DRAIN: begin
          if (wb_valid == '0) begin
            // Every dirty line in the span has been written back and lines
            // outside it were never dirty, so clearing wb_any_q keeps it
            // meaning "no dirty line".
            wb_lo_q  <= {SetBits{1'b1}};
            wb_hi_q  <= '0;
            wb_any_q <= 1'b0;
            mstate_q <= M_IDLE;
          end
        end

        default: mstate_q <= M_SWEEP;
      endcase
    end
  end

  // ===========================================================================
  // Source-registered performance observers
  // ===========================================================================
  (* keep = "true" *) cache_perf_pkg::cache_instance_perf_events_t perf_events_q;
  logic [cache_perf_pkg::MissOutstandingBits-1:0] miss_count;
  always_comb begin
    miss_count = '0;
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      if (mshr_valid[i] && !mshr_maint_q[i]) miss_count = miss_count + 1'b1;
    end
  end
  logic w_counts_hit, w_counts_miss;
  assign w_counts_hit = w_valid_q && !w_maint_q &&
      ((w_op_q == W_READ_HIT) || (w_op_q == W_WRITE_HIT));
  assign w_counts_miss = w_valid_q && !w_maint_q &&
      (w_is_alloc || (w_op_q == W_MERGE) || (w_op_q == W_WAITER));
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_events_q <= '0;
    end else begin
      perf_events_q.access <= up_req_fire && !i_up_req_maintenance && !i_up_req_probe;
      perf_events_q.hit <= w_counts_hit;
      perf_events_q.miss <= w_counts_miss;
      perf_events_q.writeback <= w_counts_miss && w_is_alloc && w_victim_dirty_q;
      perf_events_q.miss_outstanding <= miss_count;
      perf_events_q.hit_under_miss <= w_counts_hit && (miss_count != '0);
      perf_events_q.slot_full_stall <= stall_full && t_plain && !t_maint_q;
      perf_events_q.conflict_stall <= (stall_conflict || stall_ways || stall_wb_snapshot) &&
          t_plain && !t_maint_q;
    end
  end
  assign o_perf_events = perf_events_q;

  // The write costs. A slot records at its allocation whether its write miss
  // fetches the line, so the slots such misses hold are counted until they
  // free. A write whose line's slot fetches for a read, or holds a read
  // waiter, can neither merge nor proceed, and t_write_read_waiting_q keeps
  // whether T's request was such a write at its last decision. These
  // registers drive only o_write_perf_events and carry no keep, so they are
  // removed when nothing counts the events.
  logic [NUM_MSHR-1:0] mshr_write_fill_q;
  always_ff @(posedge i_clk) begin
    if (w_valid_q && w_is_alloc) begin
      mshr_write_fill_q[w_mshr_q] <= w_write_q && w_needs_fill_q && !w_maint_q;
    end
  end
  logic [cache_perf_pkg::MissOutstandingBits-1:0] write_fill_count;
  always_comb begin
    write_fill_count = '0;
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      if (mshr_valid[i] && mshr_write_fill_q[i]) write_fill_count = write_fill_count + 1'b1;
    end
  end
  logic t_write_read_wait, t_write_read_waiting_q;
  assign t_write_read_wait = decide && t_plain && !t_maint_q && t_write_q && same_line &&
      (!mshr_write_q[match_mshr] || mshr_has_waiter[match_mshr]);
  always_ff @(posedge i_clk) begin
    if (i_rst) t_write_read_waiting_q <= 1'b0;
    else if (decide) t_write_read_waiting_q <= t_write_read_wait;
  end
  cache_perf_pkg::cache_write_perf_events_t write_perf_events_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      write_perf_events_q <= '0;
    end else begin
      write_perf_events_q.write_fill <= w_counts_miss && w_is_alloc && w_write_q && w_needs_fill_q;
      write_perf_events_q.write_fill_outstanding <= write_fill_count;
      write_perf_events_q.write_read_wait <= t_write_read_wait && !t_write_read_waiting_q;
      write_perf_events_q.write_read_waiting <= t_write_read_waiting_q;
    end
  end
  assign o_write_perf_events = write_perf_events_q;

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;

  // ---- Compare visible captures with references written only when enabled.
  localparam int unsigned WPayloadBits = SetBits + TagBits + LineAddrBits + 1 + LineBits +
      LINE_BYTES + UP_ID_BITS + 1 + 1 + MshrBits + WbBits + WayBits + 1 + 1 + TagBits +
      PlruBits + ProbeBits + 1 + NUM_WB;
  logic [WPayloadBits-1:0] ref_w_payload_q;
  logic [ProbeSlots-1:0] ref_probe_inval_q;
  logic [LineAddrBits-1:0] ref_probe_line_q[ProbeSlots];
  logic [UP_ID_BITS-1:0] ref_probe_id_q[ProbeSlots];
  logic [UP_ID_BITS-1:0] ref_ack_id_q[AckDepth];
  always_ff @(posedge i_clk) begin
    if (!i_rst && t_done) begin
      ref_w_payload_q <= {
        t_set,
        t_tag,
        t_line,
        t_write_q,
        t_wdata_q,
        t_wstrb_q,
        t_id_q,
        t_maint_q,
        t_probe_q,
        (t_is_alloc ? mshr_free_idx : match_mshr),
        wb_free_idx,
        (hit ? hit_way : victim_way),
        hit_dirty,
        victim_dirty,
        tag_rdata_tag[victim_way],
        plru_rdata,
        probe_free_idx,
        !(t_write_q && (&t_wstrb_q)),
        (t_wb_match_q & wb_valid)
      };
    end
    if (!i_rst && t_done && t_probe_q) begin
      ref_probe_inval_q[probe_free_idx] <= t_probe_inval_q;
      ref_probe_line_q[probe_free_idx]  <= t_line;
      ref_probe_id_q[probe_free_idx]    <= t_id_q;
    end
    if (!i_rst && ack_push) ref_ack_id_q[ack_wr_q[UP_ID_BITS-1:0]] <= t_id_q;
  end

  // MSHR payload with the fill captured on its response.
  logic [LineBits-1:0] ref_mshr_data_q[NUM_MSHR];
  logic [LINE_BYTES-1:0] ref_mshr_wstrb_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_payload_mismatch;
  for (genvar gm = 0; gm < int'(NUM_MSHR); gm++) begin : gen_mshr_payload_reference
    logic ref_alloc, ref_merge, ref_capture;
    logic [  LineBits-1:0] ref_data_d;
    logic [LINE_BYTES-1:0] ref_wstrb_d;
    always_comb begin
      ref_alloc = w_valid_q && (w_op_q == W_ALLOC) && (w_mshr_q == MshrBits'(gm));
      ref_merge = w_valid_q && (w_op_q == W_MERGE) && (w_mshr_q == MshrBits'(gm));
      ref_capture = resp_is_fill && (resp_fill_slot == MshrBits'(gm)) &&
          ((mshr_state_q[gm] == MS_SENT) || ref_merge);
      for (int b = 0; b < int'(LINE_BYTES); b++) begin
        ref_data_d[b*8+:8] = (ref_alloc || (ref_merge && w_wstrb_q[b])) ? w_wdata_q[b*8+:8] :
            ((ref_capture && !(mshr_write_q[gm] && ref_mshr_wstrb_q[gm][b])) ?
             i_down_resp_rdata[b*8+:8] : ref_mshr_data_q[gm][b*8+:8]);
        ref_wstrb_d[b] = ref_alloc ? (w_write_q && w_wstrb_q[b]) :
            (ref_capture || (ref_merge && w_wstrb_q[b]) || ref_mshr_wstrb_q[gm][b]);
      end
      // Before the fill (MS_PEND, MS_SENT) only the store's bytes are read.
      mshr_payload_mismatch[gm] = 1'b0;
      if ((mshr_state_q[gm] == MS_PEND) || (mshr_state_q[gm] == MS_SENT)) begin
        if (mshr_wstrb_q[gm] != ref_mshr_wstrb_q[gm]) mshr_payload_mismatch[gm] = 1'b1;
        for (int b = 0; b < int'(LINE_BYTES); b++) begin
          if (mshr_write_q[gm] && ref_mshr_wstrb_q[gm][b] &&
              (mshr_data_q[gm][b*8+:8] != ref_mshr_data_q[gm][b*8+:8])) begin
            mshr_payload_mismatch[gm] = 1'b1;
          end
        end
      end else if (mshr_state_q[gm] != MS_FREE) begin
        if (mshr_data_q[gm] != ref_mshr_data_q[gm]) mshr_payload_mismatch[gm] = 1'b1;
      end
    end
    always_ff @(posedge i_clk) begin
      if (!i_rst) begin
        ref_mshr_data_q[gm]  <= ref_data_d;
        ref_mshr_wstrb_q[gm] <= ref_wstrb_d;
      end
    end
  end

  // The slots in MS_RESP, decoded from the state.
  logic [NUM_MSHR-1:0] mshr_in_resp_ref;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) mshr_in_resp_ref[i] = (mshr_state_q[i] == MS_RESP);
  end

  logic probe_slot_mismatch, ack_queue_mismatch;
  always_comb begin
    probe_slot_mismatch = 1'b0;
    for (int k = 0; k < int'(ProbeSlots); k++) begin
      if ((NUM_PROBE > 0) && probe_valid_q[k] &&
          ({probe_inval_q[k], probe_line_q[k], probe_id_q[k]} !=
           {ref_probe_inval_q[k], ref_probe_line_q[k], ref_probe_id_q[k]})) begin
        probe_slot_mismatch = 1'b1;
      end
      // The acknowledgement implies a held slot (its id is read then).
      if ((NUM_PROBE > 0) && probe_ack_q[k] && !probe_valid_q[k]) probe_slot_mismatch = 1'b1;
    end
    ack_queue_mismatch = 1'b0;
    for (int unsigned n = 0; n < AckDepth; n++) begin
      logic [AckPtrBits-1:0] slot_ptr;
      slot_ptr = ack_rd_q + AckPtrBits'(n);
      if ((AckPtrBits'(n) < AckPtrBits'(ack_wr_q - ack_rd_q)) &&
          (ack_id_q[slot_ptr[UP_ID_BITS-1:0]] != ref_ack_id_q[slot_ptr[UP_ID_BITS-1:0]])) begin
        ack_queue_mismatch = 1'b1;
      end
    end
  end

  // Way invariants: a valid MSHR owns a way no other valid MSHR owns, its
  // line is in no way of its set while it fetches, at most one way of a set
  // holds a line, and an allocation takes a way no MSHR owns.
  logic way_owner_conflict;
  always_comb begin
    way_owner_conflict = 1'b0;
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      for (int j = i + 1; j < int'(NUM_MSHR); j++) begin
        if (mshr_valid[i] && mshr_valid[j] &&
            (mshr_line_q[i][SetBits-1:0] == mshr_line_q[j][SetBits-1:0]) &&
            (mshr_way_q[i] == mshr_way_q[j])) begin
          way_owner_conflict = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      p_t_done_factored : assert (t_done == (decide && !t_stall));
      p_ack_push_is_write_decode :
      assert (ack_push == (t_done && (t_is_write_hit || (t_is_alloc && t_write_q) || t_is_merge)));
      p_mshr_resp_onehot_exact :
      assert (mshr_resp_onehot_q == (mshr_in_resp_ref & ~(mshr_in_resp_ref - 1'b1)));
      if (w_valid_q) begin
        p_w_payload_exact :
        assert ({w_set_q, w_tag_q, w_line_q, w_write_q, w_wdata_q, w_wstrb_q, w_id_q, w_maint_q,
                 w_probe_q, w_mshr_q, w_wb_q, w_way_q, w_hit_dirty_q, w_victim_dirty_q,
                 w_victim_tag_q, w_plru_q, w_probe_slot_q, w_needs_fill_q, w_wb_wait_q} ==
                ref_w_payload_q);
      end
      p_probe_slot_exact : assert (!probe_slot_mismatch);
      p_ack_nonempty_exact : assert (ack_nonempty == (ack_wr_q != ack_rd_q));
      p_ack_queue_exact : assert (!ack_queue_mismatch);
      p_mshr_payload_exact : assert (mshr_payload_mismatch == '0);
      p_way_owned_once : assert (!way_owner_conflict);
      if (decide) begin
        p_one_way_hits : assert ($onehot0(way_hit));
        // A line whose MSHR has not installed it yet is in no way.
        if (same_line && (mshr_state_q[match_mshr] != MS_RESP) &&
            (mshr_state_q[match_mshr] != MS_FREE_WAIT)) begin
          p_line_in_transition_misses : assert (!hit);
        end
      end
      if (w_valid_q && w_is_alloc) begin
        for (int i = 0; i < int'(NUM_MSHR); i++) begin
          p_alloc_takes_unowned_way :
          assert (!(mshr_valid[i] && (mshr_line_q[i][SetBits-1:0] == w_set_q) &&
                    (mshr_way_q[i] == w_way_q)));
        end
      end
    end
  end

  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (up_req_fire && i_up_req_write && i_up_req_wstrb == '0)
        $error("frost_cache: write request with empty strobes");
      if (up_req_fire && i_up_req_probe && (NUM_PROBE == 0))
        $error("frost_cache: probe request on a cache without probe slots");
      if (up_req_fire && i_up_req_probe && i_up_req_write)
        $error("frost_cache: probe request with write set");
      if (resp_is_wb && wb_probe_q[resp_wb_slot] && !probe_valid_q[wb_probe_slot_q[resp_wb_slot]])
        $error("frost_cache: probe writeback acknowledged for an unmanned probe slot");
      for (int k = 0; k < int'(ProbeSlots); k++) begin
        if ((NUM_PROBE > 0) && i_probe_release_valid && probe_valid_q[k] &&
            (probe_id_q[k] == i_probe_release_id) && probe_ack_q[k])
          $error("frost_cache: probe slot %0d released before its acknowledgement left", k);
      end
      if (resp_is_fill && (mshr_state_q[resp_fill_slot] != MS_SENT))
        $error("frost_cache: fill response for MSHR %0d not in flight", resp_fill_slot);
      if (resp_is_wb && (wb_state_q[resp_wb_slot] != WB_SENT))
        $error("frost_cache: writeback ack for slot %0d not in flight", resp_wb_slot);
      if (ack_push && ((ack_wr_q - ack_rd_q) == AckPtrBits'(AckDepth)))
        $error("frost_cache: acknowledgement queue overflow");
      if (w_valid_q && w_is_alloc && (mshr_state_q[w_mshr_q] != MS_FREE))
        $error("frost_cache: allocation into busy MSHR %0d", w_mshr_q);
      if (w_allocs_wb && (wb_state_q[w_wb_q] != WB_FREE))
        $error("frost_cache: victim into busy writeback slot %0d", w_wb_q);
      if (flush_read && (wb_state_q[flush_wb_q] != WB_FREE))
        $error("frost_cache: flush writeback into busy slot %0d", flush_wb_q);
      if (w_valid_q && (w_op_q == W_MERGE) &&
          !((mshr_state_q[w_mshr_q] == MS_PEND) || (mshr_state_q[w_mshr_q] == MS_SENT) ||
            (mshr_state_q[w_mshr_q] == MS_MERGE)))
        $error("frost_cache: merge into MSHR %0d in state %0d", w_mshr_q, mshr_state_q[w_mshr_q]);
      // A W read of the data array never meets a same-edge write of its row
      // (see the data array): one W operation per cycle, and fills install
      // only into ways that neither hit nor are being taken. The L1s' banks
      // check their own reads.
      if (!ParallelWayRead && data_re && data_row_we && (data_raddr == data_waddr))
        $error("frost_cache: data row 0x%0h read and written in the same cycle", data_raddr);
      p_tag_response_has_owner :
      assert (!tag_response_valid ||
                                        ((mstate_q == M_IDLE) && t_valid_q) ||
                                        (mstate_q == M_FLUSH_CHECK));
      p_tag_retry_keeps_t : assert (!t_tag_retry || (t_valid_q && !t_done));
      p_poisoned_tag_never_decides :
      assert (!(t_tag_response && (t_tag_stale_q || t_tag_write_collision) && t_done));
      p_reread_owns_t_set : assert (!reread_q || ((mstate_q == M_IDLE) && t_valid_q));
      // No request is in A, T, or W while the sweep or a walk runs, so the
      // slot comparators never see the walk's writeback slots.
      p_pipeline_empty_during_maintenance :
      assert ((mstate_q == M_IDLE) || (!sk_valid_q && !t_valid_q && !w_valid_q));
      // A picked fill owns its slot in MS_WRITING, which keeps maintenance
      // from starting. The fill's registered set and way and W's registered
      // write decode match what they copy, and in M_IDLE the per-source set
      // checks equal their write-port forms.
      p_fill_owns_writing_slot :
      assert (!fw_valid_q || ((mstate_q == M_IDLE) && (mshr_state_q[fw_sel_q] == MS_WRITING)));
      p_fill_row_is_slot_row :
      assert (!fw_valid_q || ((fw_set_q == mshr_line_q[fw_sel_q][SetBits-1:0]) &&
                              (fw_way_q == mshr_way_q[fw_sel_q])));
      p_w_write_copies :
      assert ((w_tag_write_q == w_writes_tag) && (w_data_write_q == w_writes_data));
      p_set_checks_are_port_forms :
      assert ((mstate_q != M_IDLE) ||
              ((tag_write_t_set == ((|tag_we) && (tag_waddr == t_set))) &&
               (tag_write_in_set == ((|tag_we) && (tag_waddr == in_set)))));
      // The per-source accept and tag read enable equal their reference forms.
      p_accept_is_hold_gated :
      assert (t_accept == (in_valid && !a_hold && !reread_q && (!t_valid_q || t_done)));
      p_tag_re_is_accept_gated :
      assert (tag_re == ((mstate_q == M_FLUSH_SCAN) ||
                         ((mstate_q == M_IDLE) && (t_accept || reread_q))));
      p_cache_perf_hit_miss_onehot : assert (!(perf_events_q.hit && perf_events_q.miss));
      // The write costs are subsets of the misses and the conflict stalls,
      // and write fills hold no more slots than misses do.
      p_cache_perf_write_fill_is_miss :
      assert (!write_perf_events_q.write_fill || perf_events_q.miss);
      p_cache_perf_write_wait_is_conflict :
      assert (!write_perf_events_q.write_read_wait || perf_events_q.conflict_stall);
      p_cache_perf_write_fill_slots :
      assert (write_perf_events_q.write_fill_outstanding <= perf_events_q.miss_outstanding);
      // Two writebacks of one line could reach AXI in reverse age order.
      // Check uniqueness and forbid writes or installs while a snapshot is held.
      for (int j = 0; j < int'(NUM_WB); j++) begin
        for (int k = j + 1; k < int'(NUM_WB); k++) begin
          if (wb_valid[j] && wb_valid[k] && (wb_line_q[j] == wb_line_q[k]))
            $error(
                "frost_cache: writeback slots %0d and %0d both hold line 0x%0h", j, k, wb_line_q[j]
            );
        end
        if (wb_valid[j] && w_valid_q && (w_op_q == W_WRITE_HIT) && (wb_line_q[j] == w_line_q))
          $error(
              "frost_cache: write hit commits to line 0x%0h while writeback slot %0d holds it",
              w_line_q,
              j
          );
        if (wb_valid[j] && mshr_write_fire && (wb_line_q[j] == mshr_line_q[fw_sel_q]))
          $error(
              "frost_cache: install of line 0x%0h while writeback slot %0d holds it",
              mshr_line_q[fw_sel_q],
              j
          );
      end
      // The writeback turn follows its count exactly and is never owed with
      // no writeback pending: a slot leaves WB_PEND only through the load
      // that clears both.
      if (wb_turn_q != (wb_lost_q == WbStarveBits'(WbStarveLimit)))
        $error(
            "frost_cache: writeback turn %0d disagrees with its count %0d", wb_turn_q, wb_lost_q
        );
      if (wb_turn_q && !wb_req_any) $error("frost_cache: writeback turn owed with none pending");
      if (dq_load && dq_load_is_wb && (wb_state_q[wb_req_sel] != WB_PEND))
        $error("frost_cache: writeback load picked slot %0d, which is not pending", wb_req_sel);
    end
  end

  // Count request-register loads, not backpressure cycles. The threshold is
  // four times the arbitration bound of NUM_WB * (WbStarveLimit + 1) loads.
  localparam int unsigned WbStarveTripLoads = 4 * NUM_WB * (WbStarveLimit + 1);
  int unsigned wb_pend_loads [NUM_WB];
  int unsigned wb_pend_cycles[NUM_WB];
  always_ff @(posedge i_clk) begin
    for (int j = 0; j < int'(NUM_WB); j++) begin
      if (!reset_seen_q || i_rst || (wb_state_q[j] != WB_PEND)) begin
        wb_pend_loads[j]  <= 0;
        wb_pend_cycles[j] <= 0;
      end else begin
        wb_pend_cycles[j] <= wb_pend_cycles[j] + 1;
        if (dq_load && !(dq_load_is_wb && (wb_req_sel == WbBits'(j)))) begin
          wb_pend_loads[j] <= wb_pend_loads[j] + 1;
          if (wb_pend_loads[j] == WbStarveTripLoads) begin
            $error("frost_cache: writeback slot %0d (line 0x%0h) starved: %0d loads, %0d cycles",
                   j, wb_line_q[j], wb_pend_loads[j] + 1, wb_pend_cycles[j] + 1);
          end
        end
      end
    end
  end

  // The fill pick's exact bound: while a fill can issue, the pick passes it
  // over at most NUM_MSHR - 1 times before loading it.
  int unsigned fill_passed[NUM_MSHR];
  always_ff @(posedge i_clk) begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      if (!reset_seen_q || i_rst || !fill_req_mask[i]) begin
        fill_passed[i] <= 0;
      end else if (dq_load && !dq_load_is_wb && (fill_req_sel != MshrBits'(i))) begin
        fill_passed[i] <= fill_passed[i] + 1;
        if (fill_passed[i] + 1 == NUM_MSHR) begin
          $error("frost_cache: fill of MSHR %0d (line 0x%0h) passed over by %0d fill loads", i,
                 mshr_line_q[i], fill_passed[i] + 1);
        end
      end
    end
  end

  // Dump state if a held request makes no progress for this many cycles.
  localparam int unsigned WedgeWatchdogCycles = 2048;
  // A waiter or merge must land on an MSHR fetching its own line; a
  // cross-line attach silently serves one line's data for another's address.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && w_valid_q && ((w_op_q == W_WAITER) || (w_op_q == W_MERGE))) begin
      p_secondary_targets_own_line : assert (mshr_line_q[w_mshr_q] == w_line_q);
    end
  end

  int unsigned wedge_cnt;
  logic wedge_live;
  // Anything held without advancing: a request waiting in A, or one parked
  // in T that has not retired (decide/re-read loop).
  assign wedge_live = (in_valid && !t_accept) || (t_valid_q && !t_done);
  always_ff @(posedge i_clk) begin
    if (!reset_seen_q || i_rst || !wedge_live) begin
      wedge_cnt <= 0;
    end else begin
      wedge_cnt <= wedge_cnt + 1;
      if (wedge_cnt == WedgeWatchdogCycles) begin
        $display("frost_cache WEDGE: in{v=%0d w=%0d addr=%h id=%0d} a_hold=%0d reread=%0d",
                 in_valid, in_write, in_addr, in_id, a_hold, reread_q);
        $display("  down: valid=%0d ready=%0d write=%0d id=%0d resp_v=%0d up_resp{v=%0d id=%0d}",
                 o_down_req_valid, i_down_req_ready, o_down_req_write, o_down_req_id,
                 i_down_resp_valid, o_up_resp_valid, o_up_resp_id);
        $display({"  mstate=%0d t{v=%0d resp=%0d stale=%0d set=%h reserved=%b} ",
                  "w{v=%0d op=%0d set=%h} dq{v=%0d wb=%0d id=%0d}"}, mstate_q, t_valid_q,
                   tag_response_valid, t_tag_stale_q, t_set, way_reserved, w_valid_q, w_op_q,
                   w_set_q, dq_valid_q, dq_is_wb_q, dq_id_q);
        for (int i = 0; i < int'(NUM_MSHR); i++)
        $display(
            "  mshr[%0d]: state=%0d line=%h way=%0d id=%0d write=%0d wb_wait=%b waiters=%b",
            i,
            mshr_state_q[i],
            mshr_line_q[i],
            mshr_way_q[i],
            mshr_id_q[i],
            mshr_write_q[i],
            mshr_wb_wait_q[i],
            mshr_waiter_valid_q[i]
        );
        for (int j = 0; j < int'(NUM_WB); j++)
        $display(
            "  wb[%0d]: state=%0d line=%h probe=%0d", j, wb_state_q[j], wb_line_q[j], wb_probe_q[j]
        );
        for (int k = 0; k < int'(ProbeSlots); k++)
        $display(
            "  probe[%0d]: valid=%0d ack=%0d inval=%0d line=%h id=%0d",
            k,
            probe_valid_q[k],
            probe_ack_q[k],
            probe_inval_q[k],
            probe_line_q[k],
            probe_id_q[k]
        );
        $error("frost_cache: request stuck for %0d cycles (forward progress lost)",
               WedgeWatchdogCycles);
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // ===========================================================================
  // Cover points for simulation coverage (tests/README.md)
  // ===========================================================================
  // The L1D, L1I, and L2 instances add to the same points. Only the L2 has
  // two waiter seats, and only the L1D takes probes.
  // A read of a line with a pending miss takes a waiter seat.
  cover_read_takes_waiter_seat :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      w_valid_q && (w_op_q == W_WAITER));
  // A read waits because every seat of its line's miss slot is taken.
  cover_read_waits_for_waiter_seat :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      decide && t_plain && same_line && !t_write_q && mshr_seats_full[match_mshr] &&
      ((mshr_state_q[match_mshr] == MS_PEND) || (mshr_state_q[match_mshr] == MS_SENT)));
  // A miss waits because a miss slot owns every way of its set.
  cover_miss_waits_for_way :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst) stall_ways);
  // A write merges into the pending write-allocate miss of its line.
  cover_write_merges_into_miss :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      w_valid_q && (w_op_q == W_MERGE));
  // Store bytes win when a merge and its miss's fill arrive together.
  cover_write_merge_on_fill :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      w_valid_q && (w_op_q == W_MERGE) && resp_is_fill &&
      (resp_fill_slot == w_mshr_q) && !response_error);
  // A reader attaches on the edge that captures its miss's fill.
  cover_waiter_on_fill :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      w_valid_q && (w_op_q == W_WAITER) && resp_is_fill &&
      (resp_fill_slot == w_mshr_q) && !response_error);
  // A fill installation crosses a delayed tag lookup of the same set.
  cover_fill_retries_tag_lookup :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      t_tag_retry && mshr_write_fire && (fw_set_q == t_set));
  // A failed read fill owes an error to attached readers as well as its owner.
  cover_read_error_with_waiter :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      resp_is_fill && response_error && mshr_has_waiter[resp_fill_slot]);
  // A writeback takes the request register from a pending fill on its
  // starvation turn.
  cover_writeback_takes_starvation_turn :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      dq_load && dq_load_is_wb && wb_turn_q && fill_req_any);
  for (genvar i = 0; i < int'(NUM_MSHR); i++) begin : gen_mshr_cover
    // A miss waits to fetch until a writeback of its own line is acknowledged.
    cover_fill_waits_for_writeback :
    cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
        (mshr_state_q[i] == MS_PEND) && (mshr_wb_wait_q[i] != '0));
  end
  if (NUM_WAITERS > 1) begin : gen_seat_cover
    // A second read joins a miss slot that already has a waiter.
    cover_read_takes_later_waiter_seat :
    cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
        w_valid_q && (w_op_q == W_WAITER) && (w_seat != '0));
  end
  if (NUM_PROBE > 0) begin : gen_probe_cover
    for (genvar i = 0; i < int'(NUM_MSHR); i++) begin : gen_mshr
      // A held PROBE_INVAL withholds the fill of a miss on its line.
      cover_fill_withheld_by_probe :
      cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
          (mshr_state_q[i] == MS_PEND) && mshr_fill_held[i]);
    end
    // A probe waits for a writeback of its line.
    cover_probe_waits_for_writeback :
    cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
        decide && t_probe_q && !same_line && t_wb_pending);
  end
`endif
`endif

endmodule : frost_cache
