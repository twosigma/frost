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
 * Direct-mapped, non-blocking, write-back/write-allocate line cache.
 * Both ports speak the tagged line protocol (hw/rtl/lib/cache/README.md),
 * allowing stacked levels:
 *   CPU adapter -> frost_cache(L1, BRAM) -> DDR
 *   CPU adapter -> frost_cache(L1, BRAM) -> frost_cache(L2, URAM) -> DDR
 *
 * Pipeline. A request is accepted into a one-entry skid (so upstream ready
 * is registered state), resolved in the tag stage T one cycle later, and its
 * side effects land in the write stage W the cycle after that:
 *   - read hit:  the data array is read from T; the response leaves with the
 *                array's output DATA_READ_LATENCY cycles later, one hit per
 *                cycle in steady state;
 *   - write hit: W writes the strobed bytes and sets dirty; the
 *                acknowledgement is queued from T;
 *   - miss:      T reads the dirty victim (if any) into a writeback slot, W
 *                invalidates the victim's tag and allocates a miss-status
 *                slot (MSHR) that fetches the line downstream; a write miss
 *                is acknowledged from T -- the store is ordered here -- and
 *                its bytes are merged into the fill when it lands;
 *   - secondary: a write to a line whose write-allocate MSHR is pending
 *                merges into it; a read takes the MSHR's single waiter seat;
 *                anything else that targets an index in transition waits.
 * Hits flow past pending misses; several MSHRs may be fetching at once and
 * writebacks drain independently, ordered only by the rule that a fill for a
 * line still sitting in a writeback slot waits for that writeback's ack.
 *
 * Ordering contract (the slave side of the protocol): requests to the same
 * line take effect in acceptance order, so a write accepted before a read of
 * the line is visible to it (responses themselves may be delivered in a
 * different order). The mechanisms: the tag of a line in transition is
 * invalid and its index is guarded by the MSHR until the fill's tag write is
 * visible; a request whose index matches the entry in T or W waits one cycle
 * before its tag is read (tag-RAM write-to-read latency); merges are refused
 * once a read waiter is attached and never applied to a read MSHR; a stalled
 * request re-reads its tag before deciding again.
 *
 * Downstream ids are {type, slot}: type 0 = fill of MSHR slot, 1 = writeback
 * of writeback slot. Responses are matched by that id.
 *
 * Geometry: CACHE_SIZE_BYTES / LINE_BYTES direct-mapped lines; a 32-byte line
 * is exactly one 256-bit data-array row (sdp_ram_byte_en: BRAM or URAM via
 * MEMORY_PRIMITIVE). Tags+valid+dirty live in a block RAM (sdp_block_ram).
 *
 * Reset: a sweep FSM walks the tag array clearing every valid bit
 * (NUM_LINES cycles) before asserting req_ready. This re-invalidates the
 * cache on every reset, including image load, so stale lines from a previous
 * program are discarded rather than written back.
 *
 * Maintenance (fence.i): accepted only once every slot and pipeline stage is
 * empty (ready stays low while a request is held, so the cache drains).
 * INVALIDATE_ALL re-runs the reset sweep -- dirty contents are DISCARDED,
 * which is only correct for caches used read-only (the L1I).
 * WRITEBACK_ALL writes each valid+dirty line downstream through the
 * writeback slots and clears its dirty bit (lines stay valid and servable) --
 * the L1D's fence.i operation, making store-produced code visible at the
 * level the L1I fills from. The real FSM walks only the [wb_lo_q, wb_hi_q]
 * index span dirtied since the last writeback-all; the SIM_FAST_MAINT path
 * hops dirty line to dirty line through the dirty shadow. o_maint_busy covers
 * the walk and the drain of its writebacks.
 *
 * Performance observers: non-maintenance access / hit / miss /
 * dirty-victim-writeback pulses, the outstanding-miss count, hit-under-miss
 * pulses and the two stall classes are registered at the owning cache. The
 * one-cycle observer lag keeps raw tag/stage decisions off the path toward
 * cpu_ooo. Maintenance traffic, and requests carrying maintenance
 * provenance, are excluded.
 */
module frost_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_SIZE_BYTES = 128 * 1024,
    parameter int unsigned LINE_BYTES = 32,
    // Transaction id widths of the upstream (slave) and downstream (master)
    // line ports. DOWN_ID_BITS must hold {type, max(NUM_MSHR, NUM_WB) slots}.
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned DOWN_ID_BITS = 4,
    // Miss-status slots (outstanding fills) and writeback slots.
    parameter int unsigned NUM_MSHR = 4,
    parameter int unsigned NUM_WB = 2,
    // Data-array primitive + latencies (see sdp_ram_byte_en). "block" for L1,
    // "ultra" for the X3 L2. Simulation behaviour is primitive-agnostic.
    // Untyped on purpose: Vivado fails to resolve string-typed parameters
    // propagated into the XPM macro (see sdp_ram_byte_en).
    // verilog_lint: waive explicit-parameter-storage-type
    parameter DATA_MEMORY_PRIMITIVE = "block",
    parameter int unsigned DATA_READ_LATENCY = 2,
    // Latencies 1 and 2 are supported (the instantiated L1/L2 values).
    parameter int unsigned DATA_WRITE_LATENCY = 1,
    // Simulation-only fast cache maintenance (fence.i). 0 = FPGA: the
    // cycle-accurate maintenance FSM below is byte-for-byte unchanged. Non-zero
    // = simulation: invalidate-all completes in a single cycle (a tag bulk
    // clear) and writeback-all iterates only the dirty lines -- O(dirty) rather
    // than O(NumLines) -- guided by a sim-only shadow of the dirty bits. The
    // functional effect is identical to the slow path: every line is left
    // invalid after invalidate-all, and every valid+dirty line is still written
    // downstream and marked clean by writeback-all. Threaded in only for the
    // cocotb sim build; never set for board/synthesis builds.
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
    output logic                    o_up_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_up_resp_id,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,

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
    input  logic [DOWN_ID_BITS-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata,

    // Source-registered performance observer bundle.
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events
);

  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned NumLines = CACHE_SIZE_BYTES / LINE_BYTES;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned IndexBits = $clog2(NumLines);
  localparam int unsigned TagBits = ADDR_WIDTH - IndexBits - OffsetBits;
  localparam int unsigned LineAddrBits = ADDR_WIDTH - OffsetBits;
  // Tag entry layout: {valid, dirty, tag}
  localparam int unsigned TagEntryBits = TagBits + 2;
  localparam int unsigned MshrBits = (NUM_MSHR > 1) ? $clog2(NUM_MSHR) : 1;
  localparam int unsigned WbBits = (NUM_WB > 1) ? $clog2(NUM_WB) : 1;
  localparam int unsigned DownSlotBits = DOWN_ID_BITS - 1;
  localparam int unsigned AckDepth = 1 << UP_ID_BITS;
  localparam int unsigned AckPtrBits = UP_ID_BITS + 1;

  initial begin
    if (NumLines * LINE_BYTES != CACHE_SIZE_BYTES)
      $fatal(1, "frost_cache: CACHE_SIZE_BYTES must be a multiple of LINE_BYTES");
    if (2 ** IndexBits != NumLines) $fatal(1, "frost_cache: line count must be a power of 2");
    if (2 ** OffsetBits != LINE_BYTES) $fatal(1, "frost_cache: LINE_BYTES must be a power of 2");
    if (DATA_WRITE_LATENCY < 1 || DATA_WRITE_LATENCY > 2)
      $fatal(1, "frost_cache: DATA_WRITE_LATENCY must be 1 or 2");
    if (DOWN_ID_BITS < 2) $fatal(1, "frost_cache: DOWN_ID_BITS must be >= 2");
    if ((1 << DownSlotBits) < NUM_MSHR || (1 << DownSlotBits) < NUM_WB)
      $fatal(1, "frost_cache: DOWN_ID_BITS cannot address every MSHR / writeback slot");
  end

  // ===========================================================================
  // Maintenance / sweep control (owns the tag and data ports while active)
  // ===========================================================================
  typedef enum logic [2:0] {
    M_SWEEP,        // reset/invalidate-all: clear every tag entry
    M_IDLE,         // the request pipeline runs
    M_FLUSH_SCAN,   // writeback-all: present the walk index to the tags
    M_FLUSH_CHECK,  // examine the entry; skip clean, read out dirty
    M_FLUSH_DRAIN   // wait for the walk's writebacks to be acknowledged
  } mstate_e;

  mstate_e mstate_q;
  logic [IndexBits-1:0] sweep_idx_q;
  logic [IndexBits-1:0] flush_idx_q;

  logic pipeline_idle;  // nothing in flight anywhere (maintenance may start)
  logic flush_active;
  assign flush_active = (mstate_q == M_FLUSH_SCAN) || (mstate_q == M_FLUSH_CHECK) ||
      (mstate_q == M_FLUSH_DRAIN);
  assign o_maint_busy = flush_active || (mstate_q == M_SWEEP);

  // Fast invalidate-all: hold the tag bulk clear for the (now one-cycle) sweep.
  logic tag_bulk_clear;
  assign tag_bulk_clear = (SIM_FAST_MAINT != 0) && (mstate_q == M_SWEEP);

  // ===========================================================================
  // Tag array (sync 1-cycle read)
  // ===========================================================================
  logic                    tag_we;
  logic [   IndexBits-1:0] tag_waddr;
  logic [TagEntryBits-1:0] tag_wdata;
  logic [   IndexBits-1:0] tag_raddr;
  logic [TagEntryBits-1:0] tag_rdata;
  logic tag_rdata_valid, tag_rdata_dirty;
  logic [TagBits-1:0] tag_rdata_tag;
  assign {tag_rdata_valid, tag_rdata_dirty, tag_rdata_tag} = tag_rdata;

  sdp_block_ram #(
      .ADDR_WIDTH(IndexBits),
      .DATA_WIDTH(TagEntryBits),
      .SUPPORT_BULK_CLEAR(SIM_FAST_MAINT)
  ) tag_array (
      .i_clk(i_clk),
      .i_write_enable(tag_we),
      .i_bulk_clear(tag_bulk_clear),
      .i_write_address(tag_waddr),
      .i_read_address(tag_raddr),
      .i_write_data(tag_wdata),
      .o_read_data(tag_rdata)
  );

  // ===========================================================================
  // Data array (one row per line)
  // ===========================================================================
  logic                  data_re;
  logic [ IndexBits-1:0] data_raddr;
  logic [  LineBits-1:0] data_rdata;
  logic                  data_row_we;
  logic [ IndexBits-1:0] data_waddr;
  logic [LINE_BYTES-1:0] data_wbyte_en;
  logic [  LineBits-1:0] data_wdata;

  sdp_ram_byte_en #(
      .DATA_WIDTH(LineBits),
      .ADDR_WIDTH(IndexBits),
      .READ_LATENCY(DATA_READ_LATENCY),
      .WRITE_LATENCY(DATA_WRITE_LATENCY),
      .MEMORY_PRIMITIVE(DATA_MEMORY_PRIMITIVE)
  ) data_array (
      .i_clk(i_clk),
      .i_waddr(data_waddr),
      .i_wdata(data_wdata),
      .i_wbyte_en(data_wbyte_en & {LINE_BYTES{data_row_we}}),
      .i_re(data_re),
      .i_raddr(data_raddr),
      .o_rdata(data_rdata)
  );

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
  logic [UP_ID_BITS-1:0] mshr_id_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_write_q;
  logic [NUM_MSHR-1:0] mshr_maint_q;
  logic [NUM_MSHR-1:0] mshr_has_victim_q;
  logic [WbBits-1:0] mshr_victim_wb_q[NUM_MSHR];
  logic [NUM_MSHR-1:0] mshr_waiter_valid_q;
  logic [UP_ID_BITS-1:0] mshr_waiter_id_q[NUM_MSHR];
  logic [LINE_BYTES-1:0] mshr_wstrb_q[NUM_MSHR];
  logic [LineBits-1:0] mshr_data_q[NUM_MSHR];
  logic [NUM_WB-1:0] mshr_wb_wait_q[NUM_MSHR];  // writebacks of the same line
  logic [NUM_MSHR-1:0] mshr_resp_primary_done_q;

  typedef enum logic [1:0] {
    WB_FREE,
    WB_FILLING,  // victim read in flight through the data pipeline
    WB_PEND,     // data captured, request not yet issued
    WB_SENT      // request issued, acknowledgement outstanding
  } wb_state_e;

  wb_state_e                    wb_state_q [NUM_WB];
  logic      [      NUM_WB-1:0] wb_valid;
  logic      [LineAddrBits-1:0] wb_line_q  [NUM_WB];
  logic      [    LineBits-1:0] wb_data_q  [NUM_WB];
  logic      [      NUM_WB-1:0] wb_maint_q;

  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) mshr_valid[i] = (mshr_state_q[i] != MS_FREE);
    for (int j = 0; j < int'(NUM_WB); j++) wb_valid[j] = (wb_state_q[j] != WB_FREE);
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

  // Upstream ready is registered state only: the skid is empty, the request
  // pipeline is enabled, and no maintenance request is waiting (masking ready
  // lets the pipeline drain so maintenance can start).
  assign o_up_req_ready = (mstate_q == M_IDLE) && !sk_valid_q && !i_invalidate_all &&
      !i_writeback_all;

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

  logic [   IndexBits-1:0] in_index;
  logic [LineAddrBits-1:0] in_line;
  assign in_index = in_addr[OffsetBits+:IndexBits];
  assign in_line  = in_addr[ADDR_WIDTH-1:OffsetBits];

  // ===========================================================================
  // Stage T: tag compare and decision
  // ===========================================================================
  logic                    t_valid_q;
  logic                    t_fresh_q;  // the tag-array output is this entry's
  logic                    reread_q;  // re-issue T's tag read this cycle
  logic                    t_write_q;
  logic [  ADDR_WIDTH-1:0] t_addr_q;
  logic [    LineBits-1:0] t_wdata_q;
  logic [  LINE_BYTES-1:0] t_wstrb_q;
  logic [  UP_ID_BITS-1:0] t_id_q;
  logic                    t_maint_q;
  logic [    NUM_MSHR-1:0] t_idx_match_q;  // MSHR with this index
  logic [    NUM_MSHR-1:0] t_line_match_q;  // MSHR with this line
  logic [      NUM_WB-1:0] t_wb_match_q;  // writeback slot with this line

  logic [   IndexBits-1:0] t_index;
  logic [     TagBits-1:0] t_tag;
  logic [LineAddrBits-1:0] t_line;
  assign t_index = t_addr_q[OffsetBits+:IndexBits];
  assign t_tag   = t_addr_q[ADDR_WIDTH-1-:TagBits];
  assign t_line  = t_addr_q[ADDR_WIDTH-1:OffsetBits];

  // ===========================================================================
  // Stage W: registered side effects of T's decision
  // ===========================================================================
  typedef enum logic [2:0] {
    W_NONE,
    W_WRITE_HIT,  // strobed array write + dirty tag
    W_ALLOC,      // invalidate victim tag, allocate MSHR (+ writeback slot)
    W_MERGE,      // merge a write into a pending write MSHR
    W_WAITER      // attach a read waiter to a pending MSHR
  } w_op_e;

  logic                     w_valid_q;
  w_op_e                    w_op_q;
  logic  [   IndexBits-1:0] w_index_q;
  logic  [     TagBits-1:0] w_tag_q;
  logic  [LineAddrBits-1:0] w_line_q;
  logic                     w_write_q;
  logic  [    LineBits-1:0] w_wdata_q;
  logic  [  LINE_BYTES-1:0] w_wstrb_q;
  logic  [  UP_ID_BITS-1:0] w_id_q;
  logic                     w_maint_q;
  logic  [    MshrBits-1:0] w_mshr_q;
  logic  [      WbBits-1:0] w_wb_q;
  logic                     w_has_victim_q;
  logic  [     TagBits-1:0] w_victim_tag_q;
  logic                     w_needs_fill_q;
  logic  [      NUM_WB-1:0] w_wb_wait_q;

  // Hold a request in A while its index matches the entry in T or W: their
  // tag writes (dirty, invalidate) must be visible to this request's tag read.
  logic                     a_hold;
  assign a_hold = (t_valid_q && (in_index == t_index)) || (w_valid_q && (in_index == w_index_q));

  // A-stage comparators against the slots, registered into T with the entry
  // and masked there by the live valid bits. A slot being allocated by W this
  // cycle still holds its previous line, so it is excluded: if it is a true
  // index match the request is held in A by a_hold and compares again next
  // cycle; a stale match would otherwise stall the request forever.
  logic [NUM_MSHR-1:0] in_idx_match, in_line_match;
  logic [NUM_WB-1:0] in_wb_match;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      in_idx_match[i]  = (mshr_line_q[i][IndexBits-1:0] == in_index);
      in_line_match[i] = (mshr_line_q[i] == in_line);
    end
    for (int j = 0; j < int'(NUM_WB); j++) in_wb_match[j] = (wb_line_q[j] == in_line);
    if (w_valid_q && (w_op_q == W_ALLOC)) begin
      in_idx_match[w_mshr_q]  = 1'b0;
      in_line_match[w_mshr_q] = 1'b0;
      if (w_has_victim_q) in_wb_match[w_wb_q] = 1'b0;
    end
  end

  // ---- Tag compare, explicitly balanced: 3-bit equality groups (one LUT6
  // each) whose nets synthesis must keep, then a flat reduce. A plain == has
  // been seen re-packed into a deeper LUT tree under context pressure. The
  // cone terminates at the T decision; every RAM write control it influences
  // is taken from W's registers a cycle later.
  localparam int unsigned TagCmpGroups = (TagBits + 2) / 3;
  (* dont_touch = "true" *) logic [TagCmpGroups-1:0] tag_match_group;
  for (genvar gg = 0; gg < int'(TagCmpGroups); gg++) begin : gen_tag_compare
    localparam int unsigned Lo = gg * 3;
    localparam int unsigned Hi = (Lo + 3 <= TagBits) ? Lo + 3 : TagBits;
    assign tag_match_group[gg] = (tag_rdata_tag[Hi-1:Lo] == t_tag[Hi-1:Lo]);
  end
  logic hit;
  assign hit = tag_rdata_valid && (&tag_match_group);

  // ---- Slot availability (a W-stage allocation is not yet in the valid bits).
  logic [NUM_MSHR-1:0] mshr_free_mask;
  logic [  NUM_WB-1:0] wb_free_mask;
  logic mshr_free_any, wb_free_any;
  logic [MshrBits-1:0] mshr_free_idx;
  logic [  WbBits-1:0] wb_free_idx;
  always_comb begin
    mshr_free_mask = ~mshr_valid;
    wb_free_mask   = ~wb_valid;
    if (w_valid_q && (w_op_q == W_ALLOC)) begin
      mshr_free_mask[w_mshr_q] = 1'b0;
      if (w_has_victim_q) wb_free_mask[w_wb_q] = 1'b0;
    end
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

  // ---- The T decision.
  logic                decide;
  logic                conflict;  // an MSHR guards this index
  logic                same_line;  // ... and it is this very line
  logic [MshrBits-1:0] match_mshr;
  logic match_mergeable, match_waitable;
  logic victim_dirty;
  logic raw_hazard;  // the row is being written this cycle
  logic t_stall, t_done;
  logic t_is_read_hit, t_is_write_hit, t_is_alloc, t_is_merge, t_is_waiter;
  logic stall_conflict, stall_full;

  assign decide = (mstate_q == M_IDLE) && t_valid_q && t_fresh_q;
  always_comb begin
    conflict   = |(t_idx_match_q & mshr_valid);
    same_line  = |(t_line_match_q & mshr_valid);
    match_mshr = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if (t_line_match_q[i] && mshr_valid[i]) match_mshr = MshrBits'(i);
    end
    match_mergeable = mshr_write_q[match_mshr] && !mshr_waiter_valid_q[match_mshr] &&
        ((mshr_state_q[match_mshr] == MS_PEND) || (mshr_state_q[match_mshr] == MS_SENT));
    match_waitable = !mshr_waiter_valid_q[match_mshr] &&
        ((mshr_state_q[match_mshr] == MS_PEND) || (mshr_state_q[match_mshr] == MS_SENT));
    victim_dirty = tag_rdata_valid && tag_rdata_dirty;
    raw_hazard = data_row_we && (data_waddr == t_index);

    t_is_read_hit = decide && !conflict && hit && !t_write_q;
    t_is_write_hit = decide && !conflict && hit && t_write_q;
    t_is_alloc = decide && !conflict && !hit;
    t_is_merge = decide && conflict && same_line && t_write_q;
    t_is_waiter = decide && conflict && same_line && !t_write_q;

    stall_conflict = decide && conflict &&
        (!same_line || (t_write_q ? !match_mergeable : !match_waitable));
    stall_full = t_is_alloc && (!mshr_free_any || (victim_dirty && !wb_free_any));
    t_stall = stall_conflict || stall_full || ((t_is_read_hit || (t_is_alloc && victim_dirty)) &&
                                                raw_hazard);
    t_done = decide && !t_stall;
  end

  // T accepts the presented request when it is empty or completing.
  logic t_accept;
  assign t_accept  = in_valid && !a_hold && !reread_q && (!t_valid_q || t_done);

  // ---- Tag read address: the walk index during writeback-all, T's own index
  // on a re-read cycle, else the presented request's index.
  assign tag_raddr = (mstate_q == M_FLUSH_SCAN) ? flush_idx_q : (reread_q ? t_index : in_index);

  // ===========================================================================
  // Data-array read purpose pipeline (aligned with the array's read latency)
  // ===========================================================================
  // Each T-issued read is either a hit response (kind 0) or a victim read
  // bound for a writeback slot (kind 1).
  logic [DATA_READ_LATENCY-1:0] rp_valid_q;
  logic [DATA_READ_LATENCY-1:0] rp_victim_q;
  logic [UP_ID_BITS-1:0] rp_id_q[DATA_READ_LATENCY];
  logic [WbBits-1:0] rp_wb_q[DATA_READ_LATENCY];

  logic rp_push, rp_push_victim;
  logic [WbBits-1:0] rp_push_wb;
  logic rp_out_valid, rp_out_victim;
  logic [UP_ID_BITS-1:0] rp_out_id;
  logic [WbBits-1:0] rp_out_wb;
  assign rp_out_valid  = rp_valid_q[DATA_READ_LATENCY-1];
  assign rp_out_victim = rp_victim_q[DATA_READ_LATENCY-1];
  assign rp_out_id     = rp_id_q[DATA_READ_LATENCY-1];
  assign rp_out_wb     = rp_wb_q[DATA_READ_LATENCY-1];

  // Flush walk: victim read of a dirty line into a writeback slot.
  logic flush_read;
  assign flush_read = (mstate_q == M_FLUSH_CHECK) && tag_rdata_valid && tag_rdata_dirty &&
      wb_free_any;

  always_comb begin
    rp_push        = 1'b0;
    rp_push_victim = 1'b0;
    rp_push_wb     = wb_free_idx;
    data_re        = 1'b0;
    data_raddr     = flush_active ? flush_idx_q : t_index;
    if (flush_read) begin
      rp_push        = 1'b1;
      rp_push_victim = 1'b1;
      data_re        = 1'b1;
    end else if (t_done && t_is_read_hit) begin
      rp_push = 1'b1;
      data_re = 1'b1;
    end else if (t_done && t_is_alloc && victim_dirty) begin
      rp_push        = 1'b1;
      rp_push_victim = 1'b1;
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
      rp_id_q[0]     <= t_id_q;
      rp_wb_q[0]     <= rp_push_wb;
      for (int k = 1; k < int'(DATA_READ_LATENCY); k++) begin
        rp_valid_q[k]  <= rp_valid_q[k-1];
        rp_victim_q[k] <= rp_victim_q[k-1];
        rp_id_q[k]     <= rp_id_q[k-1];
        rp_wb_q[k]     <= rp_wb_q[k-1];
      end
    end
  end

  // ===========================================================================
  // Acknowledgement queue (write hits, write misses, merges)
  // ===========================================================================
  // At most one push per cycle; never deeper than the upstream's id space,
  // which bounds its outstanding requests.
  logic [UP_ID_BITS-1:0] ack_id_q[AckDepth];
  logic [AckPtrBits-1:0] ack_wr_q, ack_rd_q;
  logic ack_nonempty, ack_push, ack_pop;
  assign ack_nonempty = (ack_wr_q != ack_rd_q);
  assign ack_push = t_done && (t_is_write_hit || (t_is_alloc && t_write_q) || t_is_merge);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ack_wr_q <= '0;
      ack_rd_q <= '0;
    end else begin
      if (ack_push) begin
        ack_id_q[ack_wr_q[UP_ID_BITS-1:0]] <= t_id_q;
        ack_wr_q <= ack_wr_q + 1'b1;
      end
      if (ack_pop) ack_rd_q <= ack_rd_q + 1'b1;
    end
  end

  // ===========================================================================
  // Response port: hit data (cannot wait) > acknowledgements > fill responses
  // ===========================================================================
  logic                mshr_resp_any;
  logic [MshrBits-1:0] mshr_resp_sel;
  logic                mshr_resp_fire;
  always_comb begin
    mshr_resp_any = 1'b0;
    mshr_resp_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if (mshr_state_q[i] == MS_RESP) begin
        mshr_resp_any = 1'b1;
        mshr_resp_sel = MshrBits'(i);
      end
    end
  end

  logic resp_data_now;
  assign resp_data_now  = rp_out_valid && !rp_out_victim;
  assign ack_pop        = !resp_data_now && ack_nonempty;
  assign mshr_resp_fire = !resp_data_now && !ack_nonempty && mshr_resp_any;

  // A read MSHR answers its primary first, then its waiter; a write MSHR only
  // has a waiter to answer.
  logic mshr_resp_is_waiter;
  assign mshr_resp_is_waiter =
      mshr_write_q[mshr_resp_sel] || mshr_resp_primary_done_q[mshr_resp_sel];

  assign o_up_resp_valid = resp_data_now || ack_nonempty || mshr_resp_any;
  assign o_up_resp_id = resp_data_now ? rp_out_id :
      ack_nonempty ? ack_id_q[ack_rd_q[UP_ID_BITS-1:0]] :
      (mshr_resp_is_waiter ? mshr_waiter_id_q[mshr_resp_sel] : mshr_id_q[mshr_resp_sel]);
  assign o_up_resp_rdata = resp_data_now ? data_rdata : mshr_data_q[mshr_resp_sel];

  // ===========================================================================
  // Downstream request arbitration: fills first, then writebacks
  // ===========================================================================
  logic fill_req_any, wb_req_any;
  logic [MshrBits-1:0] fill_req_sel;
  logic [  WbBits-1:0] wb_req_sel;
  always_comb begin
    fill_req_any = 1'b0;
    fill_req_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((mshr_state_q[i] == MS_PEND) && (mshr_wb_wait_q[i] == '0)) begin
        fill_req_any = 1'b1;
        fill_req_sel = MshrBits'(i);
      end
    end
    wb_req_any = 1'b0;
    wb_req_sel = '0;
    for (int j = int'(NUM_WB) - 1; j >= 0; j--) begin
      if (wb_state_q[j] == WB_PEND) begin
        wb_req_any = 1'b1;
        wb_req_sel = WbBits'(j);
      end
    end
  end

  // The winner is loaded into a request register and presented from there,
  // so the downstream port (and everything it fans into: the arbiter, the
  // next level's skid) sees flop-sourced valid/payload. A slot leaves PEND
  // when it is loaded; the register holds the request until it fires.
  logic                    dq_valid_q;
  logic                    dq_is_wb_q;
  logic [LineAddrBits-1:0] dq_line_q;
  logic [    LineBits-1:0] dq_data_q;
  logic [DOWN_ID_BITS-1:0] dq_id_q;
  logic                    dq_maint_q;
  logic down_fire, dq_load, dq_load_is_wb;
  assign down_fire              = dq_valid_q && i_down_req_ready;
  assign dq_load                = (fill_req_any || wb_req_any) && (!dq_valid_q || down_fire);
  assign dq_load_is_wb          = !fill_req_any && wb_req_any;

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
  assign resp_is_fill   = i_down_resp_valid && !i_down_resp_id[DOWN_ID_BITS-1];
  assign resp_is_wb     = i_down_resp_valid && i_down_resp_id[DOWN_ID_BITS-1];
  assign resp_fill_slot = MshrBits'(i_down_resp_id[DownSlotBits-1:0]);
  assign resp_wb_slot   = WbBits'(i_down_resp_id[DownSlotBits-1:0]);

  // ===========================================================================
  // Write-port arbitration: W's committed writes, then the flush walk's clean
  // marks, then MSHR fill writes (which wait).
  // ===========================================================================
  logic w_writes_data, w_writes_tag;
  assign w_writes_data = w_valid_q && (w_op_q == W_WRITE_HIT);
  assign w_writes_tag  = w_valid_q && ((w_op_q == W_WRITE_HIT) || (w_op_q == W_ALLOC));

  // MSHR fill/allocate write: the lowest slot ready to write whose victim (if
  // any) has been captured, when both ports are free this cycle.
  logic                mshr_write_any;
  logic [MshrBits-1:0] mshr_write_sel;
  logic                mshr_write_fire;
  always_comb begin
    mshr_write_any = 1'b0;
    mshr_write_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((mshr_state_q[i] == MS_WRITE) &&
          (!mshr_has_victim_q[i] || (wb_state_q[mshr_victim_wb_q[i]] != WB_FILLING))) begin
        mshr_write_any = 1'b1;
        mshr_write_sel = MshrBits'(i);
      end
    end
  end
  // The picked slot moves into a write-stage register one cycle ahead of
  // the write itself, so the RAM write enables see only flop-sourced terms.
  logic                fw_valid_q;
  logic [MshrBits-1:0] fw_sel_q;
  assign mshr_write_fire = fw_valid_q && !w_writes_data && !w_writes_tag;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fw_valid_q <= 1'b0;
    end else if (!fw_valid_q || mshr_write_fire) begin
      // Pick the next slot as the current one fires (or when idle). A picked
      // slot moves to MS_WRITING so it is not picked twice.
      fw_valid_q <= (mstate_q == M_IDLE) && mshr_write_any;
      fw_sel_q   <= mshr_write_sel;
    end
  end

  // The fill merged with the write bytes the MSHR accumulated.
  logic [LineBits-1:0] fill_merged;
  for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_fill_merge
    assign fill_merged[gb*8+:8] =
        (mshr_write_q[resp_fill_slot] && mshr_wstrb_q[resp_fill_slot][gb]) ?
        mshr_data_q[resp_fill_slot][gb*8+:8] : i_down_resp_rdata[gb*8+:8];
  end

  // A W-stage merge overlays its bytes on the MSHR's data -- on the fill
  // being captured this very cycle if the response lands now.
  logic w_merge_on_fill;
  assign w_merge_on_fill = resp_is_fill && (resp_fill_slot == w_mshr_q);
  logic [LineBits-1:0] merge_base, merge_data;
  assign merge_base = w_merge_on_fill ? fill_merged : mshr_data_q[w_mshr_q];
  for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_w_merge
    assign merge_data[gb*8+:8] = w_wstrb_q[gb] ? w_wdata_q[gb*8+:8] : merge_base[gb*8+:8];
  end

  // Writeback slots still pending after this cycle's acknowledgement: the
  // mask a newly allocated MSHR must wait for.
  logic [NUM_WB-1:0] resp_wb_onehot, wb_still_pending;
  always_comb begin
    resp_wb_onehot = '0;
    if (resp_is_wb) resp_wb_onehot[resp_wb_slot] = 1'b1;
    wb_still_pending = wb_valid & ~resp_wb_onehot;
  end

  always_comb begin
    tag_we        = 1'b0;
    tag_waddr     = w_index_q;
    tag_wdata     = '0;
    data_row_we   = 1'b0;
    data_waddr    = w_index_q;
    data_wbyte_en = '0;
    data_wdata    = w_wdata_q;

    if (mstate_q == M_SWEEP) begin
      // FPGA: clear one tag entry per cycle. Fast (sim): the tag bulk clear
      // zeroes every entry this single cycle, so no per-index write is issued.
      if (SIM_FAST_MAINT == 0) begin
        tag_we    = 1'b1;
        tag_waddr = sweep_idx_q;
        tag_wdata = '0;
      end
    end else if (mstate_q == M_FLUSH_CHECK) begin
      // Written back (via a writeback slot): keep the line valid, clear dirty.
      if (flush_read) begin
        tag_we    = 1'b1;
        tag_waddr = flush_idx_q;
        tag_wdata = {1'b1, 1'b0, tag_rdata_tag};
      end
    end else if (w_valid_q && (w_op_q == W_WRITE_HIT)) begin
      data_row_we   = 1'b1;
      data_wbyte_en = w_wstrb_q;
      tag_we        = 1'b1;
      tag_wdata     = {1'b1, 1'b1, w_tag_q};
    end else if (w_valid_q && (w_op_q == W_ALLOC)) begin
      tag_we    = 1'b1;
      tag_wdata = '0;  // the victim's tag: valid=0, dirty=0
    end else if (mshr_write_fire) begin
      data_row_we = 1'b1;
      data_waddr = mshr_line_q[fw_sel_q][IndexBits-1:0];
      data_wbyte_en = '1;
      data_wdata = mshr_data_q[fw_sel_q];
      tag_we = 1'b1;
      tag_waddr = mshr_line_q[fw_sel_q][IndexBits-1:0];
      tag_wdata = {1'b1, mshr_write_q[fw_sel_q], mshr_line_q[fw_sel_q][LineAddrBits-1-:TagBits]};
    end
  end

  // ===========================================================================
  // Stage A/T/W registers
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sk_valid_q <= 1'b0;
      t_valid_q  <= 1'b0;
      t_fresh_q  <= 1'b0;
      reread_q   <= 1'b0;
      w_valid_q  <= 1'b0;
      w_op_q     <= W_NONE;
    end else begin
      // Skid: capture a fired request T cannot take this cycle; release it
      // when T takes it.
      if (up_req_fire && !t_accept) begin
        sk_valid_q <= 1'b1;
        sk_write_q <= i_up_req_write;
        sk_addr_q  <= i_up_req_addr;
        sk_wdata_q <= i_up_req_wdata;
        sk_wstrb_q <= i_up_req_wstrb;
        sk_id_q    <= i_up_req_id;
        sk_maint_q <= i_up_req_maintenance;
      end else if (sk_valid_q && t_accept) begin
        sk_valid_q <= 1'b0;
      end

      // T: take the presented request, or hold / re-read.
      if (t_accept) begin
        t_valid_q      <= 1'b1;
        t_fresh_q      <= 1'b1;
        t_write_q      <= in_write;
        t_addr_q       <= in_addr;
        t_wdata_q      <= in_wdata;
        t_wstrb_q      <= in_wstrb;
        t_id_q         <= in_id;
        t_maint_q      <= in_maint;
        t_idx_match_q  <= in_idx_match;
        t_line_match_q <= in_line_match;
        t_wb_match_q   <= in_wb_match;
      end else if (t_done) begin
        t_valid_q <= 1'b0;
        t_fresh_q <= 1'b0;
      end else if (t_valid_q) begin
        // Stalled: one re-read cycle, then a fresh decision.
        t_fresh_q <= reread_q;
      end
      reread_q  <= t_valid_q && t_fresh_q && t_stall && (mstate_q == M_IDLE);

      // W: the committed decision.
      w_valid_q <= t_done;
      if (t_done) begin
        w_op_q <= t_is_write_hit ? W_WRITE_HIT :
            t_is_alloc ? W_ALLOC : t_is_merge ? W_MERGE : t_is_waiter ? W_WAITER : W_NONE;
        w_index_q <= t_index;
        w_tag_q <= t_tag;
        w_line_q <= t_line;
        w_write_q <= t_write_q;
        w_wdata_q <= t_wdata_q;
        w_wstrb_q <= t_wstrb_q;
        w_id_q <= t_id_q;
        w_maint_q <= t_maint_q;
        w_mshr_q <= t_is_alloc ? mshr_free_idx : match_mshr;
        w_wb_q <= wb_free_idx;
        w_has_victim_q <= t_is_alloc && victim_dirty;
        w_victim_tag_q <= tag_rdata_tag;
        w_needs_fill_q <= !(t_write_q && (&t_wstrb_q));
        w_wb_wait_q <= t_wb_match_q & wb_valid;
      end else begin
        w_op_q <= W_NONE;
      end
    end
  end

  // ===========================================================================
  // MSHR and writeback slot state
  // ===========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < int'(NUM_MSHR); i++) begin
        mshr_state_q[i]        <= MS_FREE;
        mshr_waiter_valid_q[i] <= 1'b0;
        mshr_wb_wait_q[i]      <= '0;
      end
      for (int j = 0; j < int'(NUM_WB); j++) wb_state_q[j] <= WB_FREE;
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
      if (w_valid_q && (w_op_q == W_ALLOC) && w_has_victim_q) begin
        wb_state_q[w_wb_q] <= WB_FILLING;
        wb_line_q[w_wb_q]  <= {w_victim_tag_q, w_index_q};
        wb_maint_q[w_wb_q] <= w_maint_q;
      end
      if (flush_read) begin
        wb_state_q[wb_free_idx] <= WB_FILLING;
        wb_line_q[wb_free_idx]  <= {tag_rdata_tag, flush_idx_q};
        wb_maint_q[wb_free_idx] <= 1'b1;
      end

      // ---- MSHRs ------------------------------------------------------------
      for (int i = 0; i < int'(NUM_MSHR); i++) begin
        unique case (mshr_state_q[i])
          MS_PEND:
          if (dq_load && !dq_load_is_wb && (fill_req_sel == MshrBits'(i)))
            mshr_state_q[i] <= MS_SENT;
          MS_SENT:
          if (resp_is_fill && (resp_fill_slot == MshrBits'(i))) begin
            mshr_data_q[i]  <= fill_merged;
            mshr_wstrb_q[i] <= '1;
            mshr_state_q[i] <= MS_MERGE;
          end
          MS_MERGE: mshr_state_q[i] <= MS_WRITE;
          MS_WRITE:
          if ((!fw_valid_q || mshr_write_fire) && (mstate_q == M_IDLE) && mshr_write_any &&
              (mshr_write_sel == MshrBits'(i)))
            mshr_state_q[i] <= MS_WRITING;
          MS_WRITING:
          if (mshr_write_fire && (fw_sel_q == MshrBits'(i))) begin
            mshr_state_q[i] <=
                (!mshr_write_q[i] || mshr_waiter_valid_q[i]) ? MS_RESP : MS_FREE_WAIT;
            mshr_resp_primary_done_q[i] <= 1'b0;
          end
          MS_RESP:
          if (mshr_resp_fire && (mshr_resp_sel == MshrBits'(i))) begin
            if (mshr_resp_is_waiter || !mshr_waiter_valid_q[i]) begin
              mshr_state_q[i] <= MS_FREE_WAIT;
            end else begin
              mshr_resp_primary_done_q[i] <= 1'b1;
            end
          end
          MS_FREE_WAIT: begin
            mshr_state_q[i]        <= MS_FREE;
            mshr_waiter_valid_q[i] <= 1'b0;
          end
          default: ;
        endcase
      end

      // W-stage effects on the MSHRs (an allocation targets a free slot; a
      // merge/waiter targets a pending one).
      if (w_valid_q && (w_op_q == W_ALLOC)) begin
        mshr_state_q[w_mshr_q]             <= w_needs_fill_q ? MS_PEND : MS_WRITE;
        mshr_line_q[w_mshr_q]              <= w_line_q;
        mshr_id_q[w_mshr_q]                <= w_id_q;
        mshr_write_q[w_mshr_q]             <= w_write_q;
        mshr_maint_q[w_mshr_q]             <= w_maint_q;
        mshr_has_victim_q[w_mshr_q]        <= w_has_victim_q;
        mshr_victim_wb_q[w_mshr_q]         <= w_wb_q;
        mshr_waiter_valid_q[w_mshr_q]      <= 1'b0;
        mshr_wstrb_q[w_mshr_q]             <= w_write_q ? w_wstrb_q : '0;
        mshr_data_q[w_mshr_q]              <= w_wdata_q;
        mshr_wb_wait_q[w_mshr_q]           <= w_wb_wait_q & wb_still_pending;
        mshr_resp_primary_done_q[w_mshr_q] <= 1'b0;
      end
      if (w_valid_q && (w_op_q == W_MERGE)) begin
        mshr_wstrb_q[w_mshr_q] <= (w_merge_on_fill ? {LINE_BYTES{1'b1}} : mshr_wstrb_q[w_mshr_q]) |
            w_wstrb_q;
        mshr_data_q[w_mshr_q] <= merge_data;
      end
      if (w_valid_q && (w_op_q == W_WAITER)) begin
        mshr_waiter_valid_q[w_mshr_q] <= 1'b1;
        mshr_waiter_id_q[w_mshr_q]    <= w_id_q;
      end
    end
  end

  // ===========================================================================
  // Maintenance: sweep and writeback-all walk
  // ===========================================================================
  // Real-FSM (FPGA) writeback-all acceleration: bound the index walk to the
  // [wb_lo_q, wb_hi_q] span of lines made dirty since the last writeback-all.
  // wb_any_q == 0 means no dirty lines. Dirty lines are created only by W's
  // write hits and by write-allocate fills, both of which pass through tag_we
  // with the dirty bit set.
  logic [IndexBits-1:0] wb_lo_q, wb_hi_q;
  logic wb_any_q;
  logic dirty_set;
  assign dirty_set = tag_we && tag_wdata[TagBits];

  // Fast maintenance (SIM_FAST_MAINT, simulation only): a shadow of the tag
  // array's dirty bits, updated by the exact same writes that update the tag
  // RAM, so writeback-all can jump straight to dirty lines.
  logic any_dirty_full, any_dirty_excl;
  logic [IndexBits-1:0] first_dirty_full, first_dirty_excl;
  if (SIM_FAST_MAINT != 0) begin : gen_fast_maint
    logic [NumLines-1:0] dirty_shadow_q;
    always_ff @(posedge i_clk) begin
      if (i_rst) dirty_shadow_q <= '0;
      else if (tag_bulk_clear) dirty_shadow_q <= '0;
      else if (tag_we) dirty_shadow_q[tag_waddr] <= tag_wdata[TagBits];
    end
    always_comb begin
      any_dirty_full   = 1'b0;
      first_dirty_full = '0;
      any_dirty_excl   = 1'b0;
      first_dirty_excl = '0;
      if ((mstate_q == M_IDLE && i_writeback_all) || flush_active) begin
        for (int idx = int'(NumLines) - 1; idx >= 0; idx--) begin
          if (dirty_shadow_q[idx]) begin
            any_dirty_full   = 1'b1;
            first_dirty_full = IndexBits'(idx);
            if (IndexBits'(idx) != flush_idx_q) begin
              any_dirty_excl   = 1'b1;
              first_dirty_excl = IndexBits'(idx);
            end
          end
        end
      end
    end
  end else begin : gen_no_fast_maint
    assign any_dirty_full   = 1'b0;
    assign first_dirty_full = '0;
    assign any_dirty_excl   = 1'b0;
    assign first_dirty_excl = '0;
  end

  // The walk is complete once it has scanned its span (or hopped every dirty
  // line); the maintenance state then drains the writeback slots.
  logic walk_done;
  assign walk_done = (mstate_q == M_FLUSH_CHECK) &&
      ((SIM_FAST_MAINT != 0) ?
       (flush_read ? !any_dirty_excl : !(tag_rdata_valid && tag_rdata_dirty)) :
                               ((!(tag_rdata_valid && tag_rdata_dirty) || flush_read) &&
                                (!wb_any_q || (flush_idx_q == wb_hi_q))));

  assign pipeline_idle = !sk_valid_q && !t_valid_q && !w_valid_q && !reread_q &&
      (mshr_valid == '0) && (wb_valid == '0) && (rp_valid_q == '0) && !ack_nonempty;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mstate_q    <= M_SWEEP;
      sweep_idx_q <= '0;
      wb_lo_q     <= {IndexBits{1'b1}};
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
            if (sweep_idx_q == {IndexBits{1'b1}}) mstate_q <= M_IDLE;
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
          if (walk_done) begin
            mstate_q <= M_FLUSH_DRAIN;
          end else if (tag_rdata_valid && tag_rdata_dirty && !flush_read) begin
            // Dirty but no writeback slot free: re-scan this index.
            mstate_q <= M_FLUSH_SCAN;
          end else begin
            flush_idx_q <= (SIM_FAST_MAINT != 0) ? first_dirty_excl : flush_idx_q + 1'b1;
            mstate_q    <= M_FLUSH_SCAN;
          end
        end

        M_FLUSH_DRAIN: begin
          if (wb_valid == '0) begin
            // Every dirty line in the span has been written back and lines
            // outside it were never dirty -> wb_any_q==0 iff no dirty line.
            wb_lo_q  <= {IndexBits{1'b1}};
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
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_events_q <= '0;
    end else begin
      perf_events_q.access <= up_req_fire && !i_up_req_maintenance;
      perf_events_q.hit <= t_done && !t_maint_q && (t_is_read_hit || t_is_write_hit);
      perf_events_q.miss <= t_done && !t_maint_q && (t_is_alloc || t_is_merge || t_is_waiter);
      perf_events_q.writeback <= t_done && !t_maint_q && t_is_alloc && victim_dirty;
      perf_events_q.miss_outstanding <= miss_count;
      perf_events_q.hit_under_miss <= t_done && !t_maint_q && (t_is_read_hit || t_is_write_hit) &&
          (miss_count != '0);
      perf_events_q.slot_full_stall <= stall_full;
      perf_events_q.conflict_stall <= stall_conflict;
    end
  end
  assign o_perf_events = perf_events_q;

`ifndef SYNTHESIS
  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (up_req_fire && i_up_req_write && i_up_req_wstrb == '0)
        $error("frost_cache: write request with empty strobes");
      if (resp_is_fill && (mshr_state_q[resp_fill_slot] != MS_SENT))
        $error("frost_cache: fill response for MSHR %0d not in flight", resp_fill_slot);
      if (resp_is_wb && (wb_state_q[resp_wb_slot] != WB_SENT))
        $error("frost_cache: writeback ack for slot %0d not in flight", resp_wb_slot);
      if (ack_push && ((ack_wr_q - ack_rd_q) == AckPtrBits'(AckDepth)))
        $error("frost_cache: acknowledgement queue overflow");
      if (w_valid_q && (w_op_q == W_ALLOC) && (mshr_state_q[w_mshr_q] != MS_FREE))
        $error("frost_cache: allocation into busy MSHR %0d", w_mshr_q);
      if (w_valid_q && (w_op_q == W_ALLOC) && w_has_victim_q && (wb_state_q[w_wb_q] != WB_FREE))
        $error("frost_cache: victim into busy writeback slot %0d", w_wb_q);
      if (w_valid_q && (w_op_q == W_MERGE) &&
          !((mshr_state_q[w_mshr_q] == MS_PEND) || (mshr_state_q[w_mshr_q] == MS_SENT) ||
            (mshr_state_q[w_mshr_q] == MS_MERGE)))
        $error("frost_cache: merge into MSHR %0d in state %0d", w_mshr_q, mshr_state_q[w_mshr_q]);
      p_cache_perf_hit_miss_onehot : assert (!(perf_events_q.hit && perf_events_q.miss));
    end
  end
`endif

endmodule : frost_cache
