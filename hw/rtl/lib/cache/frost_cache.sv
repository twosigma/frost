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
 * frost_cache: direct-mapped, non-blocking, write-back, write-allocate line
 * cache, one module for the L1D, L1I, and L2. Both ports speak the tagged
 * line protocol, so levels stack (hw/rtl/lib/cache/README.md, "The line
 * cache").
 *
 * Pipeline. A fired request goes straight to the tag stage T, or waits in a
 * one-entry skid until T can take it, so upstream ready is registered state.
 * T decides when the tag read returns (TAG_READ_LATENCY cycles), and the side
 * effects land in the write stage W the cycle after the decision:
 *   - read hit:  T reads the data array; the response carries its output
 *                DATA_READ_LATENCY cycles later. One-cycle tags decide one
 *                request per cycle; delayed tags serialize T;
 *   - write hit: W writes the strobed bytes and sets dirty; the
 *                acknowledgement is queued from T;
 *   - miss:      T reads a dirty victim into a writeback slot; W invalidates
 *                the victim's tag and allocates a miss-status slot (MSHR),
 *                which fetches the line downstream unless a write covers the
 *                whole line. A write miss is acknowledged from T, where the
 *                store is ordered, and its bytes merge into the fill;
 *   - secondary: a write to a line whose write-allocate MSHR is pending
 *                merges into it; a read takes the MSHR's single waiter seat;
 *                anything else aimed at an index in transition waits.
 * Hits proceed past pending misses, several MSHRs fetch at once, and
 * writebacks drain independently.
 *
 * Ordering (the slave side of the protocol): requests to the same line take
 * effect in acceptance order, though responses may leave in another order.
 * The tag of a line in transition is invalid and its MSHR guards the index
 * until the fill's tag write is visible; a request whose index matches the
 * entry in T or W waits for those stages to drain before reading its tag;
 * merges are refused once a read waiter is attached and never go to a read
 * MSHR; a stalled request reads its tag again before deciding again.
 *
 * Writebacks. A line still in a writeback slot is neither fetched nor
 * installed again until that writeback is acknowledged, and a write hit on a
 * copy of it that stayed valid, or any probe of it, waits as well. No line
 * therefore has two writebacks in flight, which the level below could apply
 * older-last. These waits rely on the bounded writeback turn in the
 * downstream request arbitration below. Downstream ids are {type, slot}:
 * type 0 is an MSHR's fill, type 1 a writeback slot's write.
 *
 * Each line is one data-array row (sdp_ram_byte_en). Tags use one-cycle
 * block RAM, or for the X3 L2 packed UltraRAM with a TAG_READ_LATENCY-cycle
 * lookup.
 *
 * Reset runs a sweep that clears every tag (NumLines cycles) before ready
 * rises, so every reset, including an image load, discards stale lines
 * instead of writing them back. Maintenance (fence.i) starts only once every
 * slot and stage is empty; ready stays low while it is requested.
 * Invalidate-all reruns the sweep and discards dirty data, so only a
 * read-only cache (the L1I) may use it. Writeback-all walks the index span
 * dirtied since the previous writeback-all, writes each dirty line back
 * through the writeback slots, and leaves it valid and clean. o_maint_busy
 * covers the walk and the drain of its writebacks. SIM_FAST_MAINT
 * (simulation only) makes the sweep one cycle and has writeback-all visit
 * only the dirty lines.
 *
 * Probes (NUM_PROBE > 0, the L1D) are per-line coherence requests on the
 * upstream port. PROBE_CLEAN writes a dirty copy back and leaves it valid and
 * clean; PROBE_INVAL writes a dirty copy back and invalidates the line. A
 * probe returns no data: its response is the acknowledgement, sent once the
 * level below has acknowledged any writeback the probe caused, so the
 * requester can order its own access behind that writeback. Probes go
 * through the pipeline like other requests but never merge or take a waiter
 * seat. See the probe slots below for the release and fill withholding.
 *
 * Performance events are registered here, one cycle after the decisions they
 * report, which keeps the tag and stage decisions off the path toward
 * cpu_ooo. Probes are left out of every event, and maintenance-provenance
 * requests out of every event except the two stall classes.
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
    // Probe slots: in-flight per-line coherence probes (see the header). 0
    // removes the probe machinery; only the L1D takes probes.
    parameter int unsigned NUM_PROBE = 0,
    // Data-array primitive + latencies (see sdp_ram_byte_en). "block" for L1,
    // "ultra" for the X3 L2. Simulation behaviour is primitive-agnostic.
    // Untyped because Vivado fails to resolve string-typed parameters
    // propagated into the XPM macro (see sdp_ram_byte_en).
    // verilog_lint: waive explicit-parameter-storage-type
    parameter DATA_MEMORY_PRIMITIVE = "block",
    parameter int unsigned DATA_READ_LATENCY = 2,
    // Latencies 1 and 2 are supported (the instantiated L1/L2 values).
    parameter int unsigned DATA_WRITE_LATENCY = 1,
    // Tag-array primitive and total logical read latency: "block" (one-cycle
    // block RAM) for the L1s, "ultra" (the packed UltraRAM wrapper) for the
    // X3 L2. Untyped for the same Vivado/XPM parameter-propagation reason as
    // the data primitive above.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter TAG_MEMORY_PRIMITIVE = "block",
    parameter int unsigned TAG_READ_LATENCY = 1,
    // Simulation-only fast cache maintenance (fence.i). 0 selects the
    // cycle-accurate FPGA maintenance path. Non-zero makes invalidate-all
    // complete in a single cycle (a tag bulk clear) and makes writeback-all
    // visit only the dirty lines, O(dirty) rather than O(NumLines), guided by
    // a sim-only shadow of the dirty bits. The functional effect is identical
    // to the slow path: every line is left invalid after invalidate-all, and
    // every valid+dirty line is still written downstream and marked clean by
    // writeback-all. Only the cocotb sim build sets it; board and synthesis
    // builds never do.
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
  localparam bit TrackDelayedTagWrites = TAG_READ_LATENCY > 1;
  localparam int unsigned MshrBits = (NUM_MSHR > 1) ? $clog2(NUM_MSHR) : 1;
  localparam int unsigned WbBits = (NUM_WB > 1) ? $clog2(NUM_WB) : 1;
  localparam int unsigned ProbeSlots = (NUM_PROBE > 0) ? NUM_PROBE : 1;
  localparam int unsigned ProbeBits = (NUM_PROBE > 1) ? $clog2(NUM_PROBE) : 1;
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
    if ((TAG_MEMORY_PRIMITIVE != "block") && (TAG_MEMORY_PRIMITIVE != "ultra"))
      $fatal(1, "frost_cache: TAG_MEMORY_PRIMITIVE must be block or ultra");
    if ((TAG_MEMORY_PRIMITIVE == "block") && (TAG_READ_LATENCY != 1))
      $fatal(1, "frost_cache: block tags require TAG_READ_LATENCY=1");
    if ((TAG_MEMORY_PRIMITIVE == "ultra") && (TAG_READ_LATENCY < 3))
      $fatal(1, "frost_cache: packed ultra tags require TAG_READ_LATENCY>=3");
    if (DOWN_ID_BITS < 2) $fatal(1, "frost_cache: DOWN_ID_BITS must be >= 2");
    if ((1 << DownSlotBits) < NUM_MSHR || (1 << DownSlotBits) < NUM_WB)
      $fatal(1, "frost_cache: DOWN_ID_BITS cannot address every MSHR / writeback slot");
  end

  // ===========================================================================
  // Maintenance / sweep control (drives the tag and data ports while active)
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

  // Fast maintenance: the tag bulk clear replaces the sweep, which then lasts
  // one cycle.
  logic tag_bulk_clear;
  assign tag_bulk_clear = (SIM_FAST_MAINT != 0) && (mstate_q == M_SWEEP);

  // ===========================================================================
  // Tag array (one-cycle block RAM or packed/pipelined UltraRAM)
  // ===========================================================================
  logic                        tag_we;
  logic [       IndexBits-1:0] tag_waddr;
  logic [    TagEntryBits-1:0] tag_wdata;
  logic [       IndexBits-1:0] tag_raddr;
  logic [    TagEntryBits-1:0] tag_rdata;
  logic                        tag_re;
  logic [TAG_READ_LATENCY-1:0] tag_response_valid_q;
  logic                        tag_response_valid;
  logic tag_rdata_valid, tag_rdata_dirty;
  logic [TagBits-1:0] tag_rdata_tag;
  assign {tag_rdata_valid, tag_rdata_dirty, tag_rdata_tag} = tag_rdata;

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
    sdp_packed_tag_uram #(
        .ADDR_WIDTH(IndexBits),
        .DATA_WIDTH(TagEntryBits),
        .READ_LATENCY(TAG_READ_LATENCY),
        .SUPPORT_BULK_CLEAR(SIM_FAST_MAINT)
    ) tag_array (
        .i_clk(i_clk),
        .i_write_enable(tag_we),
        .i_bulk_clear(tag_bulk_clear),
        .i_write_address(tag_waddr),
        .i_write_data(tag_wdata),
        .i_read_enable(tag_re),
        .i_read_address(tag_raddr),
        .o_read_data(tag_rdata)
    );
  end else begin : gen_tag_block
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
  end

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

  // ---- Probe slots (NUM_PROBE > 0). A probe holds a slot from its decision
  // until the requester releases it (i_probe_release_*), after the level below
  // has ordered the requester's own access. While a PROBE_INVAL slot is held,
  // no fill of its line is issued (mshr_fill_held): a miss that follows the
  // invalidation waits in its MSHR and fetches the line after the release,
  // instead of fetching the old data again. A probe cannot decide while an
  // MSHR guards its index, so it waits for a fill already pending and
  // invalidates what that fill installs; a slot withholds only fills
  // allocated after its decision. ProbeSlots keeps the arrays legal when the
  // machinery is absent; every use is then constant.
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
  logic in_probe;
  logic in_probe_inval;
  assign in_probe       = (NUM_PROBE > 0) && (sk_valid_q ? sk_probe_q : i_up_req_probe);
  assign in_probe_inval = sk_valid_q ? sk_probe_inval_q : i_up_req_probe_inval;

  logic [   IndexBits-1:0] in_index;
  logic [LineAddrBits-1:0] in_line;
  assign in_index = in_addr[OffsetBits+:IndexBits];
  assign in_line  = in_addr[ADDR_WIDTH-1:OffsetBits];

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
    W_WRITE_HIT,    // strobed array write + dirty tag
    W_ALLOC,        // invalidate victim tag, allocate MSHR (+ writeback slot)
    W_MERGE,        // merge a write into a pending write MSHR
    W_WAITER,       // attach a read waiter to a pending MSHR
    W_PROBE_CLEAN,  // probe hit a dirty line: victim to a writeback slot, tag valid+clean
    W_PROBE_INVAL   // probe invalidates the line (a dirty victim goes to a writeback slot)
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
  logic  [   ProbeBits-1:0] w_probe_slot_q;

  // W-stage allocations not yet in the slot valid bits: an MSHR (W_ALLOC),
  // and a writeback slot for an allocation's dirty victim or a probe's.
  logic w_allocs_mshr, w_allocs_wb;
  assign w_allocs_mshr = w_valid_q && (w_op_q == W_ALLOC);
  assign w_allocs_wb = w_valid_q && w_has_victim_q &&
      ((w_op_q == W_ALLOC) || (w_op_q == W_PROBE_CLEAN) || (w_op_q == W_PROBE_INVAL));

  // Hold a request in A while its index matches the entry in T or W: their
  // tag writes (dirty, invalidate) must be visible to this request's tag read.
  // The hold is decided once per source and the skid state picks between
  // them: the skid's index is registered, so its hold settles early, while the
  // live upstream index is an arbiter's mux of several requesters and arrives
  // late. Selecting after the compares keeps the skid mux out of the late
  // cone, and the upstream compares are balanced by hand into 3-bit equality
  // groups (one LUT6 each) whose nets synthesis must keep, then reduced flat,
  // as for the tag compare below: synthesis can re-pack a plain == on the
  // late index into a serial chain that reaches the tag read enable.
  logic [IndexBits-1:0] sk_index, up_index;
  assign sk_index = sk_addr_q[OffsetBits+:IndexBits];
  assign up_index = i_up_req_addr[OffsetBits+:IndexBits];
  localparam int unsigned IdxCmpGroups = (IndexBits + 2) / 3;
  (* dont_touch = "true" *) logic [IdxCmpGroups-1:0] up_t_match_group, up_w_match_group;
  for (genvar gg = 0; gg < int'(IdxCmpGroups); gg++) begin : gen_index_hold_compare
    localparam int unsigned Lo = gg * 3;
    localparam int unsigned Hi = (Lo + 3 <= IndexBits) ? Lo + 3 : IndexBits;
    assign up_t_match_group[gg] = (up_index[Hi-1:Lo] == t_index[Hi-1:Lo]);
    assign up_w_match_group[gg] = (up_index[Hi-1:Lo] == w_index_q[Hi-1:Lo]);
  end
  logic sk_hold, up_hold, a_hold;
  assign sk_hold = (t_valid_q && (sk_index == t_index)) || (w_valid_q && (sk_index == w_index_q));
  assign up_hold = (t_valid_q && (&up_t_match_group)) || (w_valid_q && (&up_w_match_group));
  assign a_hold  = sk_valid_q ? sk_hold : up_hold;

  // A-stage comparators against the slots, registered into T with the entry
  // and masked there by the live valid bits. A slot being allocated by W this
  // cycle still holds its previous line, so its match is meaningless and is
  // cleared: if the new line is a true index match, a_hold keeps the request
  // in A and it compares again next cycle.
  logic [NUM_MSHR-1:0] in_idx_match, in_line_match;
  logic [NUM_WB-1:0] in_wb_match;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      in_idx_match[i]  = (mshr_line_q[i][IndexBits-1:0] == in_index);
      in_line_match[i] = (mshr_line_q[i] == in_line);
    end
    for (int j = 0; j < int'(NUM_WB); j++) in_wb_match[j] = (wb_line_q[j] == in_line);
    if (w_allocs_mshr) begin
      in_idx_match[w_mshr_q]  = 1'b0;
      in_line_match[w_mshr_q] = 1'b0;
    end
    if (w_allocs_wb) in_wb_match[w_wb_q] = 1'b0;
  end

  // ---- Tag compare, balanced by hand: 3-bit equality groups (one LUT6
  // each) whose nets synthesis must keep, then a flat reduce. Synthesis can
  // re-pack a plain == into a deeper LUT tree under context pressure. The
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

  // ---- Live slot re-compare for the T-resident entry. The match bits
  // captured in A go stale while a request is parked in T: an MSHR or
  // writeback slot can retire and be reallocated for a different line, and a
  // captured bit re-validated by the live valid mask alone would attach a
  // read waiter or merge a write across lines, or let a fill skip the
  // writeback of its own line. The captured bits are therefore refreshed
  // every held cycle from the live slot lines. A slot being allocated this
  // cycle (a W allocation or its victim's writeback slot) still reads its old
  // line, so its incoming identity is forwarded instead. Excluding it would
  // leave the next decision blind to a real conflict with, or writeback of,
  // the line being installed. Fresh captures get the same treatment from
  // a_hold and the A-stage exclusion above. The flush walk's writeback slots
  // need neither: no request is in A or T while a walk runs, and the walk
  // returns to M_IDLE only once its writebacks are acknowledged.
  logic [NUM_MSHR-1:0] t_idx_live_match, t_line_live_match;
  logic [NUM_WB-1:0] t_wb_live_match;
  always_comb begin
    for (int i = 0; i < int'(NUM_MSHR); i++) begin
      t_idx_live_match[i]  = (mshr_line_q[i][IndexBits-1:0] == t_index);
      t_line_live_match[i] = (mshr_line_q[i] == t_line);
    end
    for (int j = 0; j < int'(NUM_WB); j++) t_wb_live_match[j] = (wb_line_q[j] == t_line);
    if (w_allocs_mshr) begin
      t_idx_live_match[w_mshr_q]  = (w_line_q[IndexBits-1:0] == t_index);
      t_line_live_match[w_mshr_q] = (w_line_q == t_line);
    end
    if (w_allocs_wb) t_wb_live_match[w_wb_q] = ({w_victim_tag_q, w_index_q} == t_line);
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
  logic t_tag_write_collision, t_tag_response, t_tag_retry;
  logic t_is_read_hit, t_is_write_hit, t_is_alloc, t_is_merge, t_is_waiter;
  logic t_plain, t_wb_pending, t_is_probe_hit, t_is_probe_miss, t_probe_dirty;
  logic stall_conflict, stall_full, stall_wb_snapshot;

  // A delayed tag response is usable only if no write to this exact logical
  // index crossed the request, including a fill's tag install in the response
  // cycle; discarding it prevents old-tag/new-data alias hits. The one-cycle
  // BRAM path already resolves write hazards through a_hold, conflict and
  // raw_hazard, so TrackDelayedTagWrites disables the comparator there at
  // elaboration, keeping it off the L1 timing paths; delayed L2 reads need
  // the sticky t_tag_stale_q protocol.
  assign t_tag_write_collision =
      TrackDelayedTagWrites && t_valid_q && tag_we && (tag_waddr == t_index);
  assign t_tag_response = (mstate_q == M_IDLE) && t_valid_q && tag_response_valid;
  assign t_tag_retry =
      t_tag_response && ((TrackDelayedTagWrites && t_tag_stale_q) || t_tag_write_collision);
  assign decide =
      t_tag_response && !((TrackDelayedTagWrites && t_tag_stale_q) || t_tag_write_collision);
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

    t_plain = !t_probe_q;
    t_is_read_hit = decide && t_plain && !conflict && hit && !t_write_q;
    t_is_write_hit = decide && t_plain && !conflict && hit && t_write_q;
    t_is_alloc = decide && t_plain && !conflict && !hit;
    t_is_merge = decide && t_plain && conflict && same_line && t_write_q;
    t_is_waiter = decide && t_plain && conflict && same_line && !t_write_q;

    // A copy still sitting in a writeback slot (left valid and clean by
    // writeback-all or a PROBE_CLEAN) must reach the level below before a
    // probe of the line is acknowledged, so the probe waits for that slot.
    // A store to such a line waits for the slot as well: it would re-dirty
    // the copy, a later eviction would snapshot that into a second slot, and
    // the slot pick below takes no account of age, so the two writebacks
    // could reach the level below older-last and leave it holding the stale
    // copy. Stores are the only way to re-dirty a valid line, so no line ever
    // has two writebacks in flight (checked in simulation at the end of the
    // file).
    t_wb_pending = |(t_wb_match_q & wb_valid);
    t_is_probe_hit = decide && t_probe_q && !conflict && !t_wb_pending && hit;
    t_is_probe_miss = decide && t_probe_q && !conflict && !t_wb_pending && !hit;
    t_probe_dirty = t_is_probe_hit && victim_dirty;

    stall_conflict = decide && (t_plain ?
        (conflict && (!same_line || (t_write_q ? !match_mergeable : !match_waitable))) :
        (conflict || t_wb_pending));
    stall_full = (t_is_alloc && (!mshr_free_any || (victim_dirty && !wb_free_any))) ||
        ((t_is_probe_hit || t_is_probe_miss) && !probe_free_any) ||
        (t_probe_dirty && !wb_free_any);
    stall_wb_snapshot = t_is_write_hit && t_wb_pending;
    // A pending probe acknowledgement holds off new read hits: hit data takes
    // the response port whenever it appears, so the port has to go quiet for
    // the acknowledgement to leave.
    t_stall = stall_conflict || stall_full || stall_wb_snapshot ||
        ((t_is_read_hit || (t_is_alloc && victim_dirty) || t_probe_dirty) && raw_hazard) ||
        (t_is_read_hit && probe_ack_any);
    t_done = decide && !t_stall;
  end

  // T accepts the presented request when it is empty or completing, i.e.
  // in_valid && !a_hold && !reread_q && (!t_valid_q || t_done). Written per
  // source: the skid's offer (sk_go) is registered state, the upstream's
  // (up_go) carries the late request valid and index hold, and up_req_fire
  // already excludes the skid-held case through o_up_req_ready, so the two
  // offers are disjoint and their OR is in_valid && !a_hold. The late terms
  // then meet T's availability in a single level, and p_accept_is_hold_gated
  // checks this form against the reference expression every cycle.
  logic sk_go, up_go, t_open, t_accept;
  assign sk_go    = sk_valid_q && !sk_hold;
  assign up_go    = up_req_fire && !up_hold;
  assign t_open   = !reread_q && (!t_valid_q || t_done);
  assign t_accept = (sk_go || up_go) && t_open;

  // ---- Tag request: issue once for a new T entry, once per retry, or once
  // when maintenance enters SCAN. CHECK waits for the matching response and
  // T holds one entry, so one read is in flight at a time and no queue has
  // to record whose response returns. The accept's offers enter the enable
  // beside the maintenance and retry terms rather than through t_accept, so
  // the upstream request adds no level here.
  logic tag_re_maint_or_retry, tag_re_open;
  assign tag_re_maint_or_retry = (mstate_q == M_FLUSH_SCAN) || ((mstate_q == M_IDLE) && reread_q);
  assign tag_re_open = (mstate_q == M_IDLE) && t_open;
  assign tag_re = tag_re_maint_or_retry || (tag_re_open && (sk_go || up_go));
  assign tag_raddr = (mstate_q == M_FLUSH_SCAN) ? flush_idx_q : (reread_q ? t_index : in_index);

  // ===========================================================================
  // Data-array read purpose pipeline (aligned with the array's read latency)
  // ===========================================================================
  // Each array read is either a hit response (kind 0) or a victim read bound
  // for a writeback slot (kind 1), from T or the flush walk.
  logic [DATA_READ_LATENCY-1:0] rp_valid_q;
  logic [DATA_READ_LATENCY-1:0] rp_victim_q;
  logic [UP_ID_BITS-1:0] rp_id_q[DATA_READ_LATENCY];
  logic [WbBits-1:0] rp_wb_q[DATA_READ_LATENCY];

  logic rp_push, rp_push_victim;
  logic [WbBits-1:0] rp_push_wb;
  logic rp_out_valid, rp_out_victim;
  logic [UP_ID_BITS-1:0] rp_out_id;
  logic [WbBits-1:0] rp_out_wb;
  assign rp_out_valid = rp_valid_q[DATA_READ_LATENCY-1];
  assign rp_out_victim = rp_victim_q[DATA_READ_LATENCY-1];
  assign rp_out_id = rp_id_q[DATA_READ_LATENCY-1];
  assign rp_out_wb = rp_wb_q[DATA_READ_LATENCY-1];

  // Flush walk: wait for this index's tag response, then read a dirty victim
  // into a writeback slot. A multi-cycle tag array keeps CHECK self-held until
  // flush_tag_ready.
  logic flush_tag_ready, flush_read;
  assign flush_tag_ready = (mstate_q == M_FLUSH_CHECK) && tag_response_valid;
  assign flush_read = flush_tag_ready && tag_rdata_valid && tag_rdata_dirty && wb_free_any;

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
    end else if (t_done && ((t_is_alloc && victim_dirty) || t_probe_dirty)) begin
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
  // The small ID queue uses flops so the late tag-hit decision drives a
  // register enable instead of a distributed-RAM write-enable setup path.
  (* ram_style = "registers" *) logic [UP_ID_BITS-1:0] ack_id_q[AckDepth];
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
  // Response port: hit data (cannot wait) > probe acknowledgements >
  // acknowledgements > fill responses
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

  logic resp_data_now, probe_ack_fire;
  assign resp_data_now  = rp_out_valid && !rp_out_victim;
  assign probe_ack_fire = !resp_data_now && probe_ack_any;
  assign ack_pop        = !resp_data_now && !probe_ack_any && ack_nonempty;
  assign mshr_resp_fire = !resp_data_now && !probe_ack_any && !ack_nonempty && mshr_resp_any;

  // A read MSHR answers its primary first, then its waiter; a write MSHR only
  // has a waiter to answer.
  logic mshr_resp_is_waiter;
  assign mshr_resp_is_waiter =
      mshr_write_q[mshr_resp_sel] || mshr_resp_primary_done_q[mshr_resp_sel];

  assign o_up_resp_valid = resp_data_now || probe_ack_any || ack_nonempty || mshr_resp_any;
  assign o_up_resp_id = resp_data_now ? rp_out_id :
      probe_ack_any ? probe_id_q[probe_ack_sel] :
      ack_nonempty ? ack_id_q[ack_rd_q[UP_ID_BITS-1:0]] :
      (mshr_resp_is_waiter ? mshr_waiter_id_q[mshr_resp_sel] : mshr_id_q[mshr_resp_sel]);
  assign o_up_resp_rdata = resp_data_now ? data_rdata : mshr_data_q[mshr_resp_sel];

  // ===========================================================================
  // Downstream request arbitration: fills first, then writebacks, with a
  // bounded turn for a writeback that fills keep out
  // ===========================================================================
  logic fill_req_any, wb_req_any;
  logic [MshrBits-1:0] fill_req_sel;
  logic [  WbBits-1:0] wb_req_sel;
  logic [  WbBits-1:0] wb_next_q;  // the writeback slot the pick starts from
  always_comb begin
    fill_req_any = 1'b0;
    fill_req_sel = '0;
    for (int i = int'(NUM_MSHR) - 1; i >= 0; i--) begin
      if ((mshr_state_q[i] == MS_PEND) && (mshr_wb_wait_q[i] == '0) && !mshr_fill_held[i]) begin
        fill_req_any = 1'b1;
        fill_req_sel = MshrBits'(i);
      end
    end
    // Between writeback slots the pick rotates: the scan starts at the slot
    // after the last one loaded (wb_next_q), then wraps, so a pending slot is
    // loaded within NUM_WB writeback loads. With lowest-index-first, a slot
    // could lose every writeback load to a lower neighbour that is
    // acknowledged, and taken again by a parked dirty-victim miss, between
    // loads. The lower-priority slots (below wb_next_q) are scanned first so
    // the later assignment, from wb_next_q upward, wins.
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

  // Fills first is not starvation-free on its own. A slot leaves WB_PEND only
  // by being loaded, and a load goes to a fill whenever one is pending, so
  // under a level below that accepts slowly, fills that complete and
  // re-allocate between its acceptances keep a fill pending at every load
  // and a pending writeback never leaves its slot; a store to its line, an
  // install of its line, a probe of it and a fill of it (the waits in the
  // header) then wait with it. wb_lost_q counts the loads a pending
  // writeback has lost to fills; at WbStarveLimit the registered wb_turn_q
  // hands the next load to a writeback, and both clear when a writeback
  // loads. Bound: a writeback loses at most WbStarveLimit loads and takes the
  // next, so it is loaded within WbStarveLimit + 1 loads of becoming pending
  // and fires on the acceptance after that. Only wb_turn_q, a flop, reaches
  // the pick, as one more input to dq_load_is_wb; the count stays off it.
  // With the rotation above, any one slot is loaded within
  // NUM_WB * (WbStarveLimit + 1) loads. Among fills the pick stays
  // lowest-index-first.
  localparam int unsigned WbStarveLimit = 3;
  localparam int unsigned WbStarveBits  = $clog2(WbStarveLimit + 1);
  logic [WbStarveBits-1:0] wb_lost_q;
  logic                    wb_turn_q;

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
  // Write-port arbitration: the sweep or the flush walk's clean marks while
  // maintenance runs; otherwise W's committed writes, then MSHR fill writes
  // (which wait).
  // ===========================================================================
  logic w_writes_data, w_writes_tag;
  assign w_writes_data = w_valid_q && (w_op_q == W_WRITE_HIT);
  assign w_writes_tag  = w_valid_q && ((w_op_q == W_WRITE_HIT) || (w_op_q == W_ALLOC) ||
                                       (w_op_q == W_PROBE_CLEAN) || (w_op_q == W_PROBE_INVAL));

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

  // Each MSHR merges response bytes with its own stored data. The response id
  // only selects which slot updates, so no slot's whole line passes through
  // an id-indexed mux on its way back to the same slot. Bytes from W (an
  // allocation's line, or a merge's strobed bytes) win over a fill landing in
  // the same cycle.
  logic [  LineBits-1:0] mshr_data_d [NUM_MSHR];
  logic [LINE_BYTES-1:0] mshr_wstrb_d[NUM_MSHR];
  for (genvar gm = 0; gm < int'(NUM_MSHR); gm++) begin : gen_mshr_payload
    logic alloc_here, merge_here, fill_here, capture_fill;
    assign alloc_here = w_valid_q && (w_op_q == W_ALLOC) && (w_mshr_q == MshrBits'(gm));
    assign merge_here = w_valid_q && (w_op_q == W_MERGE) && (w_mshr_q == MshrBits'(gm));
    assign fill_here = resp_is_fill && (resp_fill_slot == MshrBits'(gm));
    assign capture_fill = fill_here && ((mshr_state_q[gm] == MS_SENT) || merge_here);
    for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_byte
      logic take_store_byte, take_fill_byte;
      assign take_store_byte = alloc_here || (merge_here && w_wstrb_q[gb]);
      assign take_fill_byte = capture_fill && !(mshr_write_q[gm] && mshr_wstrb_q[gm][gb]);
      assign mshr_data_d[gm][gb*8+:8] = take_store_byte ? w_wdata_q[gb*8+:8] :
          (take_fill_byte ? i_down_resp_rdata[gb*8+:8] : mshr_data_q[gm][gb*8+:8]);
      assign mshr_wstrb_d[gm][gb] = alloc_here ? (w_write_q && w_wstrb_q[gb]) :
          (capture_fill || (merge_here && w_wstrb_q[gb]) || mshr_wstrb_q[gm][gb]);
    end
    always_ff @(posedge i_clk) begin
      if (!i_rst) begin
        mshr_data_q[gm]  <= mshr_data_d[gm];
        mshr_wstrb_q[gm] <= mshr_wstrb_d[gm];
      end
    end
  end

`ifdef CACHE_MSHR_PAYLOAD_PROOF
  // Reference next state in the id-indexed form. The formal target
  // cache_mshr_payload checks the per-slot logic above against it from an
  // arbitrary state.
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
    always_comb begin
      data_ref = mshr_data_q[gm];
      strb_ref = mshr_wstrb_q[gm];
      if ((mshr_state_q[gm] == MS_SENT) && resp_is_fill && (resp_fill_slot == MshrBits'(gm))) begin
        data_ref = fill_merged;
        strb_ref = '1;
      end
      if (w_valid_q && (w_op_q == W_ALLOC) && (w_mshr_q == MshrBits'(gm))) begin
        data_ref = w_wdata_q;
        strb_ref = w_write_q ? w_wstrb_q : '0;
      end
      if (w_valid_q && (w_op_q == W_MERGE) && (w_mshr_q == MshrBits'(gm))) begin
        data_ref = merge_data;
        strb_ref = (w_merge_on_fill ? {LINE_BYTES{1'b1}} : mshr_wstrb_q[gm]) | w_wstrb_q;
      end
      assert (mshr_data_d[gm] == data_ref);
      assert (mshr_wstrb_d[gm] == strb_ref);
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
    end else if (w_valid_q && (w_op_q == W_PROBE_INVAL)) begin
      tag_we    = 1'b1;
      tag_wdata = '0;  // the probed line: valid=0, dirty=0
    end else if (w_valid_q && (w_op_q == W_PROBE_CLEAN)) begin
      tag_we    = 1'b1;
      tag_wdata = {1'b1, 1'b0, w_tag_q};  // written back through a slot: valid, clean
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
      sk_valid_q    <= 1'b0;
      t_valid_q     <= 1'b0;
      reread_q      <= 1'b0;
      t_tag_stale_q <= 1'b0;
      w_valid_q     <= 1'b0;
      w_op_q        <= W_NONE;
    end else begin
      // Skid validity records only a fired request T cannot take this cycle;
      // release it when T takes it.
      if (up_req_fire && !t_accept) begin
        sk_valid_q <= 1'b1;
      end else if (sk_valid_q && t_accept) begin
        sk_valid_q <= 1'b0;
      end

      // Capture every fired payload, including a direct T accept.  In the
      // direct case sk_valid_q remains clear, so these shadow bits are dead;
      // separating their enable from t_accept removes the tag/decision cone
      // from the wide skid payload without changing request visibility.
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
        t_idx_match_q  <= in_idx_match;
        t_line_match_q <= in_line_match;
        t_wb_match_q   <= in_wb_match;
      end else if (t_done) begin
        t_valid_q <= 1'b0;
      end else if (t_valid_q) begin
        t_idx_match_q  <= t_idx_live_match;
        t_line_match_q <= t_line_live_match;
        t_wb_match_q   <= t_wb_live_match;
      end
      reread_q <= t_tag_retry || (decide && t_stall);

      // T's request fields are read only while T holds a valid entry: every
      // decision is qualified by t_valid_q (decide, a_hold, the retry and
      // collision terms), W and the probe/ack/response captures take them on
      // t_done, and an idle-cycle data-array address has no read enable. Load
      // them whenever T is not holding a live entry: every accept is such a
      // cycle, and any other load is dead because T is empty afterwards. This
      // keeps the accept decision (the upstream request valid, the index hold
      // and the tag decision) off these clock enables, as for the skid payload.
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
      // every exact-index write from issue through response and discard the
      // response if crossed. A retry starts a fresh observation window; a
      // same-edge collision wins over that clear.
      if (t_accept) begin
        t_tag_stale_q <= TrackDelayedTagWrites && tag_we && (tag_waddr == in_index);
      end else if (reread_q) begin
        t_tag_stale_q <= TrackDelayedTagWrites && tag_we && (tag_waddr == t_index);
      end else if (t_tag_write_collision) begin
        t_tag_stale_q <= 1'b1;
      end else if (t_done) begin
        t_tag_stale_q <= 1'b0;
      end

      // W: the committed decision.
      w_valid_q <= t_done;
      if (t_done) begin
        w_op_q <= t_is_write_hit ? W_WRITE_HIT :
            t_is_alloc ? W_ALLOC : t_is_merge ? W_MERGE : t_is_waiter ? W_WAITER :
            (t_is_probe_hit && t_probe_inval_q) ? W_PROBE_INVAL :
            t_probe_dirty ? W_PROBE_CLEAN : W_NONE;
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
        w_has_victim_q <= (t_is_alloc || t_is_probe_hit) && victim_dirty;
        w_probe_slot_q <= probe_free_idx;
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
      wb_probe_q    <= '0;
      probe_valid_q <= '0;
      probe_ack_q   <= '0;
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
        wb_line_q[w_wb_q]       <= {w_victim_tag_q, w_index_q};
        wb_maint_q[w_wb_q]      <= w_maint_q;
        wb_probe_q[w_wb_q]      <= (w_op_q != W_ALLOC);
        wb_probe_slot_q[w_wb_q] <= w_probe_slot_q;
      end
      if (flush_read) begin
        wb_state_q[wb_free_idx] <= WB_FILLING;
        wb_line_q[wb_free_idx]  <= {tag_rdata_tag, flush_idx_q};
        wb_maint_q[wb_free_idx] <= 1'b1;
        wb_probe_q[wb_free_idx] <= 1'b0;
      end

      // ---- Probe slots ------------------------------------------------------
      // Taken at the probe's decision; acknowledged at once unless a dirty
      // victim is being written back, then when that writeback is
      // acknowledged; freed by the requester's release.
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
      if (t_done && t_probe_q) begin
        probe_valid_q[probe_free_idx] <= 1'b1;
        probe_ack_q[probe_free_idx]   <= !t_probe_dirty;
        probe_inval_q[probe_free_idx] <= t_probe_inval_q;
        probe_line_q[probe_free_idx]  <= t_line;
        probe_id_q[probe_free_idx]    <= t_id_q;
      end

      // ---- MSHRs ------------------------------------------------------------
      for (int i = 0; i < int'(NUM_MSHR); i++) begin
        unique case (mshr_state_q[i])
          MS_PEND:
          if (dq_load && !dq_load_is_wb && (fill_req_sel == MshrBits'(i)))
            mshr_state_q[i] <= MS_SENT;
          MS_SENT:
          if (resp_is_fill && (resp_fill_slot == MshrBits'(i))) begin
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
        mshr_wb_wait_q[w_mshr_q]           <= w_wb_wait_q & wb_still_pending;
        mshr_resp_primary_done_q[w_mshr_q] <= 1'b0;
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
  // array's dirty bits, updated by the same writes that update the tag RAM,
  // so writeback-all can jump straight to dirty lines.
  logic any_dirty_full, any_dirty_excl;
  logic [IndexBits-1:0] first_dirty_full, first_dirty_excl;
  if (SIM_FAST_MAINT != 0) begin : gen_fast_maint
    logic [NumLines-1:0] dirty_shadow_q;
    // The L2's shadow is 65,536 bits; clearing it replicates past Verilator's
    // advisory limit. Simulation-only state, so the width is fine.
    /* verilator lint_off WIDTHCONCAT */
    always_ff @(posedge i_clk) begin
      if (i_rst) dirty_shadow_q <= '0;
      else if (tag_bulk_clear) dirty_shadow_q <= '0;
      else if (tag_we) dirty_shadow_q[tag_waddr] <= tag_wdata[TagBits];
    end
    /* verilator lint_on WIDTHCONCAT */
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
  assign walk_done = flush_tag_ready &&
      ((SIM_FAST_MAINT != 0) ?
       (flush_read ? !any_dirty_excl : !(tag_rdata_valid && tag_rdata_dirty)) :
                               ((!(tag_rdata_valid && tag_rdata_dirty) || flush_read) &&
                                (!wb_any_q || (flush_idx_q == wb_hi_q))));

  assign pipeline_idle = !sk_valid_q && !t_valid_q && !w_valid_q && !reread_q &&
      (tag_response_valid_q == '0) && (mshr_valid == '0) && (wb_valid == '0) &&
      (rp_valid_q == '0) && !ack_nonempty && (probe_valid_q == '0);

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
          if (flush_tag_ready) begin
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
        end

        M_FLUSH_DRAIN: begin
          if (wb_valid == '0) begin
            // Every dirty line in the span has been written back and lines
            // outside it were never dirty, so clearing wb_any_q keeps it
            // meaning "no dirty line".
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
      perf_events_q.access <= up_req_fire && !i_up_req_maintenance && !i_up_req_probe;
      perf_events_q.hit <= t_done && !t_maint_q && (t_is_read_hit || t_is_write_hit);
      perf_events_q.miss <= t_done && !t_maint_q && (t_is_alloc || t_is_merge || t_is_waiter);
      perf_events_q.writeback <= t_done && !t_maint_q && t_is_alloc && victim_dirty;
      perf_events_q.miss_outstanding <= miss_count;
      perf_events_q.hit_under_miss <= t_done && !t_maint_q && (t_is_read_hit || t_is_write_hit) &&
          (miss_count != '0);
      perf_events_q.slot_full_stall <= stall_full && t_plain;
      perf_events_q.conflict_stall <= (stall_conflict || stall_wb_snapshot) && t_plain;
    end
  end
  assign o_perf_events = perf_events_q;

`ifndef SYNTHESIS
  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
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
      if (w_valid_q && (w_op_q == W_ALLOC) && (mshr_state_q[w_mshr_q] != MS_FREE))
        $error("frost_cache: allocation into busy MSHR %0d", w_mshr_q);
      if (w_valid_q && (w_op_q == W_ALLOC) && w_has_victim_q && (wb_state_q[w_wb_q] != WB_FREE))
        $error("frost_cache: victim into busy writeback slot %0d", w_wb_q);
      if (w_valid_q && (w_op_q == W_MERGE) &&
          !((mshr_state_q[w_mshr_q] == MS_PEND) || (mshr_state_q[w_mshr_q] == MS_SENT) ||
            (mshr_state_q[w_mshr_q] == MS_MERGE)))
        $error("frost_cache: merge into MSHR %0d in state %0d", w_mshr_q, mshr_state_q[w_mshr_q]);
      p_tag_response_has_owner :
      assert (!tag_response_valid ||
                                        ((mstate_q == M_IDLE) && t_valid_q) ||
                                        (mstate_q == M_FLUSH_CHECK));
      p_tag_retry_keeps_t : assert (!t_tag_retry || (t_valid_q && !t_done));
      p_poisoned_tag_never_decides :
      assert (!(t_tag_response && (t_tag_stale_q || t_tag_write_collision) && t_done));
      p_reread_owns_t_index : assert (!reread_q || ((mstate_q == M_IDLE) && t_valid_q));
      // No request is in A, T, or W while the sweep or a walk runs, so the
      // slot comparators never see the walk's writeback slots.
      p_pipeline_empty_during_maintenance :
      assert ((mstate_q == M_IDLE) || (!sk_valid_q && !t_valid_q && !w_valid_q));
      // The per-source accept and tag read enable equal their reference forms.
      p_accept_is_hold_gated :
      assert (t_accept == (in_valid && !a_hold && !reread_q && (!t_valid_q || t_done)));
      p_tag_re_is_accept_gated :
      assert (tag_re == ((mstate_q == M_FLUSH_SCAN) ||
                         ((mstate_q == M_IDLE) && (t_accept || reread_q))));
      p_cache_perf_hit_miss_onehot : assert (!(perf_events_q.hit && perf_events_q.miss));
      // No line has two writebacks in flight (see the T decision): the slot
      // pick takes no account of age, and an AXI level below may apply
      // same-line writes in either order, so two snapshots could land
      // older-last. The two rules that keep it so are checked at their
      // effect: a write hit never commits to, and an install never fires for,
      // a line a writeback slot still holds.
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

  // Writeback progress check: a slot pending through more loads of the
  // downstream request register than this is starved. The pick bounds a
  // slot's wait at NUM_WB * (WbStarveLimit + 1) loads (8 with two slots), so
  // the threshold is four times anything it allows. Backpressure alone never
  // trips it: it counts loads, not cycles; the cycles are for the log.
  localparam int unsigned WbStarveTripLoads = 8 * (WbStarveLimit + 1);
  int unsigned wb_pend_loads [NUM_WB];
  int unsigned wb_pend_cycles[NUM_WB];
  always_ff @(posedge i_clk) begin
    for (int j = 0; j < int'(NUM_WB); j++) begin
      if (i_rst || (wb_state_q[j] != WB_PEND)) begin
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

  // Wedge watchdog (simulation only): a live request that makes no progress
  // for this long means some slot state machine is stuck. Dump every state
  // register so the wedge is diagnosable from the log alone.
  localparam int unsigned WedgeWatchdogCycles = 2048;
  // A waiter or merge must land on an MSHR fetching its own line; a
  // cross-line attach silently serves one line's data for another's address.
  always_ff @(posedge i_clk) begin
    if (!i_rst && w_valid_q && ((w_op_q == W_WAITER) || (w_op_q == W_MERGE))) begin
      p_secondary_targets_own_line : assert (mshr_line_q[w_mshr_q] == w_line_q);
    end
  end

  int unsigned wedge_cnt;
  logic wedge_live;
  // Anything held without advancing: a request waiting in A, or one parked
  // in T that has not retired (decide/re-read loop).
  assign wedge_live = (in_valid && !t_accept) || (t_valid_q && !t_done);
  always_ff @(posedge i_clk) begin
    if (i_rst || !wedge_live) begin
      wedge_cnt <= 0;
    end else begin
      wedge_cnt <= wedge_cnt + 1;
      if (wedge_cnt == WedgeWatchdogCycles) begin
        $display("frost_cache WEDGE: in{v=%0d w=%0d addr=%h id=%0d} a_hold=%0d reread=%0d",
                 in_valid, in_write, in_addr, in_id, a_hold, reread_q);
        $display("  down: valid=%0d ready=%0d write=%0d id=%0d resp_v=%0d up_resp{v=%0d id=%0d}",
                 o_down_req_valid, i_down_req_ready, o_down_req_write, o_down_req_id,
                 i_down_resp_valid, o_up_resp_valid, o_up_resp_id);
        $display({"  mstate=%0d t{v=%0d resp=%0d stale=%0d idx=%h} ",
                  "w{v=%0d op=%0d idx=%h} dq{v=%0d wb=%0d id=%0d}"}, mstate_q, t_valid_q,
                   tag_response_valid, t_tag_stale_q, t_index, w_valid_q, w_op_q, w_index_q,
                   dq_valid_q, dq_is_wb_q, dq_id_q);
        for (int i = 0; i < int'(NUM_MSHR); i++)
        $display(
            "  mshr[%0d]: state=%0d line=%h id=%0d write=%0d wb_wait=%b waiter=%0d",
            i,
            mshr_state_q[i],
            mshr_line_q[i],
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

endmodule : frost_cache
