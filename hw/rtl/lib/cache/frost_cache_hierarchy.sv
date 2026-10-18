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
 * frost_cache_hierarchy: the cache hierarchy as one module
 * (hw/rtl/lib/cache/README.md, "The hierarchy").
 *
 * Four upstream line-port slaves share one downstream master:
 *   up   the data side, through the L1D;
 *   iup  instruction fetch, through the read-only L1I;
 *   wup  the page-table walker, uncached, through walker_coherence_sequencer;
 *   dma  a DMA agent, through dma_coherence_sequencer.
 * The two sequencers probe the L1D before their traffic reaches the shared
 * level, so walks and DMA see dirty L1D data, and each DMA write also goes
 * through the load queue. A 2:1 arbiter (walker > L1I) feeds a 3:1 arbiter
 * (L1D > that pair > DMA). Both are combinational pass-throughs, so the tree
 * acts as one fixed-priority arbiter ordered L1D, walker, L1I, DMA, and the
 * top arbiter adds a starvation bound. It feeds the L2, which drives the
 * downstream port.
 *
 * Everything above the L2 uses L1_LINE_BYTES lines. The L2 and the
 * downstream port use L2_LINE_BYTES lines, L2_NUM_MSHR miss-status slots,
 * L2_NUM_WB writeback slots, and L2_DOWN_ID_BITS-wide downstream ids. When
 * L2 lines are wider, each holds several L1 lines as sectors, and
 * line_size_adapter, between the top arbiter and the L2, places each request
 * in its sector and returns that sector of the response.
 *
 * Each arbiter prefixes its port index to the ids it forwards, which gives a
 * prefix-free code in DownIdBits = UP_ID_BITS + 2 bits below the top arbiter:
 *   L1D    {2'b00, UP_ID_BITS-bit local id}
 *   walker {2'b01, 1'b0, (UP_ID_BITS-1)-bit local id}
 *   L1I    {2'b01, 1'b1, (UP_ID_BITS-1)-bit local id}
 *   DMA    {2'b10, UP_ID_BITS-bit DMA-port id}
 * With the stream prefetcher (L2_PREFETCH), a 2:1 arbiter splits the DMA
 * port's ids between DMA and the prefetcher:
 *   DMA        {2'b10, 1'b0, (UP_ID_BITS-1)-bit DMA-port id}
 *   prefetcher {2'b10, 1'b1, (UP_ID_BITS-1)-bit local id}
 * The up, iup, and dma ports carry UP_ID_BITS; the wup port and the L1I's
 * downstream carry UP_ID_BITS-1. With the default UP_ID_BITS=3, that leaves
 * the L1I 2 miss slots, all its master (the two-line fetch provider) ever
 * uses, and DownIdBits is 5. cpu_and_mem uses UP_ID_BITS=4, which the L1D's
 * {type, slot} ids need for 8 miss slots (L1D_NUM_MSHR), so DownIdBits is 6
 * there. The walker keeps one walk in flight with id 0.
 * The L2 takes DownIdBits ids and gives its own downstream requests
 * {type, slot} ids, L2_DOWN_ID_BITS wide: 5 on the X3, the AXI id width of
 * its DDR block design (fpga/build/x3_ddr_bd.tcl), enough for 16 slots of
 * each type.
 *
 * Each cache exports a registered performance-event bundle. The L1D's
 * writeback-all traffic carries the maintenance bit through the arbiters, so
 * the L2 leaves fence.i writebacks out of every event. Walker traffic carries
 * maintenance=0 and counts as ordinary.
 */
module frost_cache_hierarchy #(
    parameter int unsigned ADDR_WIDTH = 32,
    // Lines above the L2 (the L1s and every upstream port), and in the L2 and
    // its downstream port.
    parameter int unsigned L1_LINE_BYTES = 32,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L1_DATA_WRITE_LATENCY = 1,
    // L1D miss-status slots. The L1D's downstream ids are UP_ID_BITS wide and
    // must hold {type, slot}.
    parameter int unsigned L1D_NUM_MSHR = 4,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1I_DATA_READ_LATENCY = 2,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Ways per set of each cache (frost_cache WAYS): a power of 2, 1 for
    // direct-mapped.
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned L2_WAYS = 4,
    // Total logical latency of the X3 L2's packed URAM tag lookup.
    parameter int unsigned L2_TAG_READ_LATENCY = 3,
    parameter int unsigned L2_DATA_READ_LATENCY = 6,
    parameter int unsigned L2_DATA_WRITE_LATENCY = 2,
    // L2 miss-status and writeback slots, and its downstream id width, which
    // must hold {type, slot} for the larger count.
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    parameter int unsigned L2_DOWN_ID_BITS = 5,
    // Read waiter seats per L2 miss slot (frost_cache NUM_WAITERS). A
    // prefetch that allocates a slot holds its primary seat, so the L1D's
    // reads of both halves of that line need two waiter seats.
    parameter int unsigned L2_NUM_WAITERS = 1,
    // The stream prefetcher (l2_stream_prefetcher), sharing the DMA port of
    // the top arbiter: 0 removes it. Its distance ahead of a stream in L2
    // lines, and its outstanding reads.
    parameter int unsigned L2_PREFETCH = 0,
    parameter int unsigned L2_PREFETCH_DISTANCE = 8,
    parameter int unsigned L2_PREFETCH_INFLIGHT = 4,
    // Simulation-only fast cache maintenance for fence.i (see frost_cache).
    // 0 = FPGA cycle-accurate FSM; non-zero = sim fast path. Passed to every
    // cache so reset can bulk-clear its tag array; fence.i maintenance requests
    // are driven only into the two L1s.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // DMA coherence sequencer lock entries (DMA requests in flight between
    // acceptance and response; the L1D gets one probe slot per entry plus the
    // walker's) and the top arbiter's starvation bound in competing grants
    // (0 = pure fixed priority).
    parameter int unsigned NUM_DMA_LOCK = 3,
    parameter int unsigned DMA_STARVATION_LIMIT = 16,
    localparam int unsigned DownIdBits = UP_ID_BITS + 2,
    localparam int unsigned DmaLockBits = (NUM_DMA_LOCK > 1) ? $clog2(NUM_DMA_LOCK) : 1
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave): data side.
    input  logic                       i_up_req_valid,
    output logic                       o_up_req_ready,
    input  logic                       i_up_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [     UP_ID_BITS-1:0] i_up_req_id,
    output logic                       o_up_resp_valid,
    output logic [     UP_ID_BITS-1:0] o_up_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Upstream line port (slave): instruction side, used read-only. FROST
    // never issues writes here; wdata/wstrb exist for protocol symmetry.
    input  logic                       i_iup_req_valid,
    output logic                       o_iup_req_ready,
    input  logic                       i_iup_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_iup_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_iup_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_iup_req_wstrb,
    input  logic [     UP_ID_BITS-1:0] i_iup_req_id,
    output logic                       o_iup_resp_valid,
    output logic [     UP_ID_BITS-1:0] o_iup_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_iup_resp_rdata,

    // Walker reads probe L1D, then go to L2 without a private cache. Write
    // inputs are ignored and flagged in simulation. IDs have UP_ID_BITS-1 bits.
    input  logic                       i_wup_req_valid,
    output logic                       o_wup_req_ready,
    input  logic                       i_wup_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_wup_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_wup_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_wup_req_wstrb,
    input  logic [     UP_ID_BITS-2:0] i_wup_req_id,
    output logic                       o_wup_resp_valid,
    output logic [     UP_ID_BITS-2:0] o_wup_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_wup_resp_rdata,
    // DMA port: a fourth upstream line-port slave with UP_ID_BITS
    // ids, coherent with the L1D and the load queue (see the header). With
    // L2_PREFETCH, the ids' top bit must be clear.
    input  logic                       i_dma_req_valid,
    output logic                       o_dma_req_ready,
    input  logic                       i_dma_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_dma_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_dma_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_dma_req_wstrb,
    input  logic [     UP_ID_BITS-1:0] i_dma_req_id,
    output logic                       o_dma_resp_valid,
    output logic [     UP_ID_BITS-1:0] o_dma_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_dma_resp_rdata,
    // Load-queue coherence handshake for DMA writes (dma_coherence_sequencer:
    // admit fires on ready, inval fires on done, release is a pulse). The
    // core's lq_coherence_port (tomasulo_wrapper/coherence/) answers it; a
    // system without that interface ties i_coh_admit_ready and
    // i_coh_inval_done high.
    output logic                       o_coh_admit_valid,
    output logic [    DmaLockBits-1:0] o_coh_admit_slot,
    output logic [     ADDR_WIDTH-1:0] o_coh_admit_addr,
    input  logic                       i_coh_admit_ready,
    output logic                       o_coh_inval_valid,
    output logic [    DmaLockBits-1:0] o_coh_inval_slot,
    input  logic                       i_coh_inval_done,
    output logic                       o_coh_release_valid,
    output logic [    DmaLockBits-1:0] o_coh_release_slot,

    // fence.i cache sync: hold i_fence_sync until o_fence_done rises (done
    // stays high while the request is held). The L1D writes back every dirty
    // line first, then the L1I invalidates, so an instruction fill racing the
    // sync cannot leave pre-writeback data in the freshly invalidated L1I.
    // The L2 needs no maintenance: it sits below both L1s, so everything the
    // L1D writes back is visible to L1I fills. Done answers only a request
    // held since its sequence started (see the sequencer below).
    input  logic i_fence_sync,
    output logic o_fence_done,

    // Downstream line port (master), L2_LINE_BYTES lines: to the AXI bridge
    // and main memory.
    output logic                       o_down_req_valid,
    input  logic                       i_down_req_ready,
    output logic                       o_down_req_write,
    output logic [     ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [L2_LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  L2_LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [L2_DOWN_ID_BITS-1:0] o_down_req_id,
    input  logic                       i_down_resp_valid,
    input  logic [L2_DOWN_ID_BITS-1:0] i_down_resp_id,
    input  logic [L2_LINE_BYTES*8-1:0] i_down_resp_rdata,

    // Source-registered per-instance performance observers.
    output cache_perf_pkg::cache_hierarchy_perf_events_t o_perf_events
);

  // Walker/L1I local id width under the 2-bit prefix (see the id tree in
  // the header).
  localparam int unsigned WalkIdBits = UP_ID_BITS - 1;

  initial begin
    // The id tree needs one prefix bit above the walker/L1I local ids.
    if (UP_ID_BITS < 2) $fatal(1, "frost_cache_hierarchy: UP_ID_BITS must be >= 2");
    if ((L2_LINE_BYTES < L1_LINE_BYTES) || (L2_LINE_BYTES % L1_LINE_BYTES != 0))
      $fatal(1, "frost_cache_hierarchy: L2_LINE_BYTES must be a multiple of L1_LINE_BYTES");
  end

  // Per-L1 downstream wires into the arbiter tree, and the top arbiter's
  // downstream into the L2.
  logic                       l1_down_req_valid;
  logic                       l1_down_req_ready;
  logic                       l1_down_req_write;
  logic                       l1_down_req_maintenance;
  logic [     ADDR_WIDTH-1:0] l1_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] l1_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] l1_down_req_wstrb;
  logic [     UP_ID_BITS-1:0] l1_down_req_id;
  logic                       l1_down_resp_valid;
  logic [     UP_ID_BITS-1:0] l1_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] l1_down_resp_rdata;

  logic                       l1i_down_req_valid;
  logic                       l1i_down_req_ready;
  logic                       l1i_down_req_write;
  logic [     ADDR_WIDTH-1:0] l1i_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] l1i_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] l1i_down_req_wstrb;
  logic [     WalkIdBits-1:0] l1i_down_req_id;
  logic                       l1i_down_resp_valid;
  logic [     WalkIdBits-1:0] l1i_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] l1i_down_resp_rdata;

  // Walker/L1I sub-arbiter downstream (port 1 of the top arbiter).
  logic                       wi_down_req_valid;
  logic                       wi_down_req_ready;
  logic                       wi_down_req_write;
  logic [     ADDR_WIDTH-1:0] wi_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] wi_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] wi_down_req_wstrb;
  logic [     UP_ID_BITS-1:0] wi_down_req_id;
  logic                       wi_down_req_maintenance;
  logic                       wi_down_resp_valid;
  logic [     UP_ID_BITS-1:0] wi_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] wi_down_resp_rdata;

  logic                       arb_down_req_valid;
  logic                       arb_down_req_ready;
  logic                       arb_down_req_write;
  logic [     ADDR_WIDTH-1:0] arb_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] arb_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] arb_down_req_wstrb;
  logic [     DownIdBits-1:0] arb_down_req_id;
  logic                       arb_down_req_maintenance;
  logic                       arb_down_resp_valid;
  logic [     DownIdBits-1:0] arb_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] arb_down_resp_rdata;

  // fence.i sequencer handshakes (FSM below, after the arbiter).
  logic l1d_maint_busy, l1i_maint_busy;
  logic l1d_writeback_req, l1i_invalidate_req;

  // ---------------------------------------------------------------------------
  // Probe injection before L1D. IDs use a high probe bit, with DMA entry k
  // at ProbeIdBase + k and the walker at WalkProbeId. CPU IDs are zero-extended.
  // The index has at least UP_ID_BITS bits and room for NUM_DMA_LOCK + 1 probes.
  //
  // A held probe blocks CPU requests. The walker wins capture, but has at
  // most one probe per read round trip, leaving capture opportunities for DMA.
  // Response IDs route acknowledgements to their sequencer. Probes never
  // write, so wdata and wstrb need no mux.
  // ---------------------------------------------------------------------------
  localparam int unsigned ProbeIdxBitsMin = $clog2(NUM_DMA_LOCK + 1);
  localparam int unsigned ProbeIdxBits =
      (UP_ID_BITS > ProbeIdxBitsMin) ? UP_ID_BITS : ProbeIdxBitsMin;
  localparam int unsigned L1dIdBits = ProbeIdxBits + 1;
  localparam int unsigned ProbeIdBase = 1 << ProbeIdxBits;
  localparam int unsigned WalkProbeId = ProbeIdBase + NUM_DMA_LOCK;
  // L1D probe slots: one per DMA entry plus the walker's.
  localparam int unsigned NumL1dProbe = NUM_DMA_LOCK + 1;
  logic dma_probe_req_valid, dma_probe_req_ready, dma_probe_req_inval;
  logic [ADDR_WIDTH-1:0] dma_probe_req_addr;
  logic [ L1dIdBits-1:0] dma_probe_req_id;
  logic walk_probe_req_valid, walk_probe_req_ready;
  logic [ADDR_WIDTH-1:0] walk_probe_req_addr;
  logic [ L1dIdBits-1:0] walk_probe_req_id;
  logic pinj_valid_q, pinj_inval_q;
  logic [ADDR_WIDTH-1:0] pinj_addr_q;
  logic [ L1dIdBits-1:0] pinj_id_q;
  logic l1d_up_req_valid, l1d_up_req_ready, l1d_up_req_write;
  logic [ADDR_WIDTH-1:0] l1d_up_req_addr;
  logic [L1dIdBits-1:0] l1d_up_req_id;
  logic l1d_up_resp_valid;
  logic [L1dIdBits-1:0] l1d_up_resp_id;
  logic probe_ack_valid, dma_probe_ack_valid, walk_probe_ack_valid;
  logic dma_probe_release_valid, walk_probe_release_valid;
  logic [L1dIdBits-1:0] dma_probe_release_id;
  logic probe_release_valid;
  logic [L1dIdBits-1:0] probe_release_id;
  assign walk_probe_req_ready = !pinj_valid_q;
  assign dma_probe_req_ready  = !pinj_valid_q && !walk_probe_req_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pinj_valid_q <= 1'b0;
    end else if (!pinj_valid_q) begin
      if (walk_probe_req_valid) begin
        pinj_valid_q <= 1'b1;
        pinj_addr_q  <= walk_probe_req_addr;
        pinj_inval_q <= 1'b0;
        pinj_id_q    <= walk_probe_req_id;
      end else if (dma_probe_req_valid) begin
        pinj_valid_q <= 1'b1;
        pinj_addr_q  <= dma_probe_req_addr;
        pinj_inval_q <= dma_probe_req_inval;
        pinj_id_q    <= dma_probe_req_id;
      end
    end else if (l1d_up_req_ready) begin
      pinj_valid_q <= 1'b0;
    end
  end
  assign l1d_up_req_valid = pinj_valid_q || i_up_req_valid;
  assign l1d_up_req_write = !pinj_valid_q && i_up_req_write;
  assign l1d_up_req_addr = pinj_valid_q ? pinj_addr_q : i_up_req_addr;
  assign l1d_up_req_id =
      pinj_valid_q ? pinj_id_q : {{(L1dIdBits - UP_ID_BITS) {1'b0}}, i_up_req_id};
  assign o_up_req_ready = l1d_up_req_ready && !pinj_valid_q;
  assign probe_ack_valid = l1d_up_resp_valid && l1d_up_resp_id[L1dIdBits-1];
  assign walk_probe_ack_valid = probe_ack_valid && (l1d_up_resp_id == L1dIdBits'(WalkProbeId));
  assign dma_probe_ack_valid = probe_ack_valid && (l1d_up_resp_id != L1dIdBits'(WalkProbeId));
  assign o_up_resp_valid = l1d_up_resp_valid && !l1d_up_resp_id[L1dIdBits-1];
  assign o_up_resp_id = l1d_up_resp_id[UP_ID_BITS-1:0];

  // Probe release merge onto the L1D's single release port. The DMA
  // sequencer's registered pulse goes through at once; a walker pulse that
  // collides with it waits one cycle in a holding flop. DMA pulses are at
  // least two cycles apart (its request register refills only once empty)
  // and the walker's a whole read apart, so the flop never has to hold two.
  logic walk_release_hold_q, walk_release_pending;
  assign walk_release_pending = walk_probe_release_valid || walk_release_hold_q;
  assign probe_release_valid = dma_probe_release_valid || walk_release_pending;
  assign probe_release_id =
      dma_probe_release_valid ? dma_probe_release_id : L1dIdBits'(WalkProbeId);
  always_ff @(posedge i_clk) begin
    if (i_rst) walk_release_hold_q <= 1'b0;
    else walk_release_hold_q <= walk_release_pending && dma_probe_release_valid;
  end

  // The walker sequencer's downstream port into the walker/L1I sub-arbiter.
  logic walk_down_req_valid, walk_down_req_ready;
  logic [ADDR_WIDTH-1:0] walk_down_req_addr;
  logic [WalkIdBits-1:0] walk_down_req_id;
  logic walk_down_resp_valid;
  logic [WalkIdBits-1:0] walk_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] walk_down_resp_rdata;

  walker_coherence_sequencer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(L1_LINE_BYTES),
      .ID_BITS(WalkIdBits),
      .PROBE_ID_BITS(L1dIdBits),
      .PROBE_ID(WalkProbeId)
  ) walk_sequencer (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_walk_req_valid(i_wup_req_valid),
      .o_walk_req_ready(o_wup_req_ready),
      .i_walk_req_addr(i_wup_req_addr),
      .i_walk_req_id(i_wup_req_id),
      .o_walk_resp_valid(o_wup_resp_valid),
      .o_walk_resp_id(o_wup_resp_id),
      .o_walk_resp_rdata(o_wup_resp_rdata),
      .o_probe_req_valid(walk_probe_req_valid),
      .i_probe_req_ready(walk_probe_req_ready),
      .o_probe_req_addr(walk_probe_req_addr),
      .o_probe_req_id(walk_probe_req_id),
      .i_probe_ack_valid(walk_probe_ack_valid),
      .o_probe_release_valid(walk_probe_release_valid),
      .o_down_req_valid(walk_down_req_valid),
      .i_down_req_ready(walk_down_req_ready),
      .o_down_req_addr(walk_down_req_addr),
      .o_down_req_id(walk_down_req_id),
      .i_down_resp_valid(walk_down_resp_valid),
      .i_down_resp_id(walk_down_resp_id),
      .i_down_resp_rdata(walk_down_resp_rdata)
  );

  // The DMA sequencer's downstream port into the top arbiter.
  logic dma_down_req_valid, dma_down_req_ready, dma_down_req_write;
  logic [ADDR_WIDTH-1:0] dma_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] dma_down_req_wdata;
  logic [L1_LINE_BYTES-1:0] dma_down_req_wstrb;
  logic [UP_ID_BITS-1:0] dma_down_req_id;
  logic dma_down_resp_valid;
  logic [UP_ID_BITS-1:0] dma_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] dma_down_resp_rdata;

  dma_coherence_sequencer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(L1_LINE_BYTES),
      .ID_BITS(UP_ID_BITS),
      .NUM_LOCK(NUM_DMA_LOCK),
      .PROBE_ID_BITS(L1dIdBits),
      .PROBE_ID_BASE(ProbeIdBase)
  ) dma_sequencer (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_dma_req_valid(i_dma_req_valid),
      .o_dma_req_ready(o_dma_req_ready),
      .i_dma_req_write(i_dma_req_write),
      .i_dma_req_addr(i_dma_req_addr),
      .i_dma_req_wdata(i_dma_req_wdata),
      .i_dma_req_wstrb(i_dma_req_wstrb),
      .i_dma_req_id(i_dma_req_id),
      .o_dma_resp_valid(o_dma_resp_valid),
      .o_dma_resp_id(o_dma_resp_id),
      .o_dma_resp_rdata(o_dma_resp_rdata),
      .o_probe_req_valid(dma_probe_req_valid),
      .i_probe_req_ready(dma_probe_req_ready),
      .o_probe_req_addr(dma_probe_req_addr),
      .o_probe_req_inval(dma_probe_req_inval),
      .o_probe_req_id(dma_probe_req_id),
      .i_probe_ack_valid(dma_probe_ack_valid),
      .i_probe_ack_id(l1d_up_resp_id),
      .o_probe_release_valid(dma_probe_release_valid),
      .o_probe_release_id(dma_probe_release_id),
      .o_coh_admit_valid(o_coh_admit_valid),
      .o_coh_admit_slot(o_coh_admit_slot),
      .o_coh_admit_addr(o_coh_admit_addr),
      .i_coh_admit_ready(i_coh_admit_ready),
      .o_coh_inval_valid(o_coh_inval_valid),
      .o_coh_inval_slot(o_coh_inval_slot),
      .i_coh_inval_done(i_coh_inval_done),
      .o_coh_release_valid(o_coh_release_valid),
      .o_coh_release_slot(o_coh_release_slot),
      .o_down_req_valid(dma_down_req_valid),
      .i_down_req_ready(dma_down_req_ready),
      .o_down_req_write(dma_down_req_write),
      .o_down_req_addr(dma_down_req_addr),
      .o_down_req_wdata(dma_down_req_wdata),
      .o_down_req_wstrb(dma_down_req_wstrb),
      .o_down_req_id(dma_down_req_id),
      .i_down_resp_valid(dma_down_resp_valid),
      .i_down_resp_id(dma_down_resp_id),
      .i_down_resp_rdata(dma_down_resp_rdata)
  );

  cache_perf_pkg::cache_instance_perf_events_t l1d_perf_events;
  cache_perf_pkg::cache_instance_perf_events_t l1i_perf_events;
  cache_perf_pkg::cache_instance_perf_events_t l2_perf_events;
  assign o_perf_events.l1d = l1d_perf_events;
  assign o_perf_events.l1i = l1i_perf_events;
  assign o_perf_events.l2  = l2_perf_events;

  frost_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1_CACHE_BYTES),
      .LINE_BYTES(L1_LINE_BYTES),
      .WAYS(L1D_WAYS),
      // The high ID bit distinguishes probes from CPU requests.
      .UP_ID_BITS(L1dIdBits),
      .DOWN_ID_BITS(UP_ID_BITS),
      .NUM_MSHR(L1D_NUM_MSHR),
      .NUM_PROBE(NumL1dProbe),
      .TAG_MEMORY_PRIMITIVE("block"),
      .TAG_READ_LATENCY(1),
      .DATA_MEMORY_PRIMITIVE("block"),
      .DATA_READ_LATENCY(L1_DATA_READ_LATENCY),
      .DATA_WRITE_LATENCY(L1_DATA_WRITE_LATENCY),
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
  ) l1_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_writeback_all(l1d_writeback_req),
      .i_invalidate_all(1'b0),
      .o_maint_busy(l1d_maint_busy),
      .i_up_req_valid(l1d_up_req_valid),
      .o_up_req_ready(l1d_up_req_ready),
      .i_up_req_write(l1d_up_req_write),
      .i_up_req_addr(l1d_up_req_addr),
      .i_up_req_wdata(i_up_req_wdata),
      .i_up_req_wstrb(i_up_req_wstrb),
      .i_up_req_id(l1d_up_req_id),
      .i_up_req_maintenance(1'b0),
      .i_up_req_probe(pinj_valid_q),
      .i_up_req_probe_inval(pinj_inval_q),
      .i_probe_release_valid(probe_release_valid),
      .i_probe_release_id(probe_release_id),
      .o_up_resp_valid(l1d_up_resp_valid),
      .o_up_resp_id(l1d_up_resp_id),
      .o_up_resp_rdata(o_up_resp_rdata),
      .o_down_req_valid(l1_down_req_valid),
      .i_down_req_ready(l1_down_req_ready),
      .o_down_req_write(l1_down_req_write),
      .o_down_req_addr(l1_down_req_addr),
      .o_down_req_wdata(l1_down_req_wdata),
      .o_down_req_wstrb(l1_down_req_wstrb),
      .o_down_req_id(l1_down_req_id),
      .o_down_req_maintenance(l1_down_req_maintenance),
      .i_down_resp_valid(l1_down_resp_valid),
      .i_down_resp_id(l1_down_resp_id),
      .i_down_resp_rdata(l1_down_resp_rdata),
      .o_perf_events(l1d_perf_events)
  );

  frost_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1I_CACHE_BYTES),
      .LINE_BYTES(L1_LINE_BYTES),
      .WAYS(L1I_WAYS),
      .UP_ID_BITS(UP_ID_BITS),
      // One fewer ID bit than L1D. At the default width, two miss slots cover
      // both fetch-provider fills. Read-only L1I never uses its writeback slots.
      .DOWN_ID_BITS(WalkIdBits),
      .NUM_MSHR(2),
      .NUM_WB(2),
      .TAG_MEMORY_PRIMITIVE("block"),
      .TAG_READ_LATENCY(1),
      .DATA_MEMORY_PRIMITIVE("block"),
      .DATA_READ_LATENCY(L1I_DATA_READ_LATENCY),
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
  ) l1i_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_writeback_all(1'b0),
      .i_invalidate_all(l1i_invalidate_req),
      .o_maint_busy(l1i_maint_busy),
      .i_up_req_valid(i_iup_req_valid),
      .o_up_req_ready(o_iup_req_ready),
      .i_up_req_write(i_iup_req_write),
      .i_up_req_addr(i_iup_req_addr),
      .i_up_req_wdata(i_iup_req_wdata),
      .i_up_req_wstrb(i_iup_req_wstrb),
      .i_up_req_id(i_iup_req_id),
      .i_up_req_maintenance(1'b0),
      .i_up_req_probe(1'b0),
      .i_up_req_probe_inval(1'b0),
      .i_probe_release_valid(1'b0),
      .i_probe_release_id('0),
      .o_up_resp_valid(o_iup_resp_valid),
      .o_up_resp_id(o_iup_resp_id),
      .o_up_resp_rdata(o_iup_resp_rdata),
      .o_down_req_valid(l1i_down_req_valid),
      .i_down_req_ready(l1i_down_req_ready),
      .o_down_req_write(l1i_down_req_write),
      .o_down_req_addr(l1i_down_req_addr),
      .o_down_req_wdata(l1i_down_req_wdata),
      .o_down_req_wstrb(l1i_down_req_wstrb),
      .o_down_req_id(l1i_down_req_id),
      .o_down_req_maintenance(),
      .i_down_resp_valid(l1i_down_resp_valid),
      .i_down_resp_id(l1i_down_resp_id),
      .i_down_resp_rdata(l1i_down_resp_rdata),
      .o_perf_events(l1i_perf_events)
  );

  // Prioritize walker reads, which unblock demand accesses, over buffered
  // instruction fetches. Neither port carries maintenance traffic.
  line_port_arbiter #(
      .NUM_PORTS (2),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(L1_LINE_BYTES),
      .UP_ID_BITS(WalkIdBits)
  ) walk_i_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid({l1i_down_req_valid, walk_down_req_valid}),
      .o_up_req_ready({l1i_down_req_ready, walk_down_req_ready}),
      .i_up_req_write({l1i_down_req_write, 1'b0}),
      .i_up_req_addr({l1i_down_req_addr, walk_down_req_addr}),
      .i_up_req_wdata({l1i_down_req_wdata, {(L1_LINE_BYTES * 8) {1'b0}}}),
      .i_up_req_wstrb({l1i_down_req_wstrb, {L1_LINE_BYTES{1'b0}}}),
      .i_up_req_id({l1i_down_req_id, walk_down_req_id}),
      .i_up_req_maintenance({1'b0, 1'b0}),
      .o_up_resp_valid({l1i_down_resp_valid, walk_down_resp_valid}),
      .o_up_resp_id({l1i_down_resp_id, walk_down_resp_id}),
      .o_up_resp_rdata({l1i_down_resp_rdata, walk_down_resp_rdata}),
      .o_down_req_valid(wi_down_req_valid),
      .i_down_req_ready(wi_down_req_ready),
      .o_down_req_write(wi_down_req_write),
      .o_down_req_addr(wi_down_req_addr),
      .o_down_req_wdata(wi_down_req_wdata),
      .o_down_req_wstrb(wi_down_req_wstrb),
      .o_down_req_id(wi_down_req_id),
      .o_down_req_maintenance(wi_down_req_maintenance),
      .i_down_resp_valid(wi_down_resp_valid),
      .i_down_resp_id(wi_down_resp_id),
      .i_down_resp_rdata(wi_down_resp_rdata)
  );

  // ---------------------------------------------------------------------------
  // Stream prefetcher: reads the lines ahead of L1D miss streams into the L2.
  // It shares the top arbiter's DMA port through a 2:1 arbiter, DMA first,
  // which splits the DMA port's ids: {1'b0, DMA id} and {1'b1, prefetch id},
  // each UP_ID_BITS-1 bits, so DMA ids keep their top bit clear. The top
  // arbiter keeps three ports (and its explicit-LUT grant on the X3), and
  // the ids below it keep their width. The prefetcher's responses only free
  // its ids.
  // ---------------------------------------------------------------------------
  logic dp_down_req_valid, dp_down_req_ready, dp_down_req_write;
  logic [ADDR_WIDTH-1:0] dp_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] dp_down_req_wdata;
  logic [L1_LINE_BYTES-1:0] dp_down_req_wstrb;
  logic [UP_ID_BITS-1:0] dp_down_req_id;
  logic dp_down_resp_valid;
  logic [UP_ID_BITS-1:0] dp_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] dp_down_resp_rdata;
  if (L2_PREFETCH != 0) begin : gen_prefetch
    localparam int unsigned SharedIdBits = UP_ID_BITS - 1;
    logic pf_down_req_valid, pf_down_req_ready;
    logic [ADDR_WIDTH-1:0] pf_down_req_addr;
    logic [SharedIdBits-1:0] pf_down_req_id;
    logic pf_down_resp_valid;
    logic [SharedIdBits-1:0] pf_down_resp_id, dma_shared_resp_id;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [L1_LINE_BYTES*8-1:0] pf_down_resp_rdata;
    logic dp_maintenance_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    l2_stream_prefetcher #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .L2_LINE_BYTES(L2_LINE_BYTES),
        .DISTANCE(L2_PREFETCH_DISTANCE),
        .MAX_INFLIGHT(L2_PREFETCH_INFLIGHT),
        .ID_BITS(SharedIdBits)
    ) prefetcher (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_miss_valid(l1_down_req_valid && l1_down_req_ready && !l1_down_req_write),
        .i_miss_addr(l1_down_req_addr),
        .o_req_valid(pf_down_req_valid),
        .i_req_ready(pf_down_req_ready),
        .o_req_addr(pf_down_req_addr),
        .o_req_id(pf_down_req_id),
        .i_resp_valid(pf_down_resp_valid),
        .i_resp_id(pf_down_resp_id)
    );
    line_port_arbiter #(
        .NUM_PORTS(2),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(L1_LINE_BYTES),
        .UP_ID_BITS(SharedIdBits),
        .STARVATION_LIMIT(0)
    ) dma_prefetch_arbiter (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_up_req_valid({pf_down_req_valid, dma_down_req_valid}),
        .o_up_req_ready({pf_down_req_ready, dma_down_req_ready}),
        .i_up_req_write({1'b0, dma_down_req_write}),
        .i_up_req_addr({pf_down_req_addr, dma_down_req_addr}),
        .i_up_req_wdata({(L1_LINE_BYTES * 8)'(0), dma_down_req_wdata}),
        .i_up_req_wstrb({L1_LINE_BYTES'(0), dma_down_req_wstrb}),
        .i_up_req_id({pf_down_req_id, dma_down_req_id[SharedIdBits-1:0]}),
        .i_up_req_maintenance(2'b00),
        .o_up_resp_valid({pf_down_resp_valid, dma_down_resp_valid}),
        .o_up_resp_id({pf_down_resp_id, dma_shared_resp_id}),
        .o_up_resp_rdata({pf_down_resp_rdata, dma_down_resp_rdata}),
        .o_down_req_valid(dp_down_req_valid),
        .i_down_req_ready(dp_down_req_ready),
        .o_down_req_write(dp_down_req_write),
        .o_down_req_addr(dp_down_req_addr),
        .o_down_req_wdata(dp_down_req_wdata),
        .o_down_req_wstrb(dp_down_req_wstrb),
        .o_down_req_id(dp_down_req_id),
        .o_down_req_maintenance(dp_maintenance_unused),
        .i_down_resp_valid(dp_down_resp_valid),
        .i_down_resp_id(dp_down_resp_id),
        .i_down_resp_rdata(dp_down_resp_rdata)
    );
    assign dma_down_resp_id = UP_ID_BITS'(dma_shared_resp_id);
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) begin
      if (!i_rst && dma_down_req_valid && dma_down_req_id[UP_ID_BITS-1])
        $error(
            "frost_cache_hierarchy: DMA id %0d has its top bit set beside the prefetcher",
            dma_down_req_id
        );
    end
`endif
  end else begin : gen_no_prefetch
    assign dp_down_req_valid   = dma_down_req_valid;
    assign dma_down_req_ready  = dp_down_req_ready;
    assign dp_down_req_write   = dma_down_req_write;
    assign dp_down_req_addr    = dma_down_req_addr;
    assign dp_down_req_wdata   = dma_down_req_wdata;
    assign dp_down_req_wstrb   = dma_down_req_wstrb;
    assign dp_down_req_id      = dma_down_req_id;
    assign dma_down_resp_valid = dp_down_resp_valid;
    assign dma_down_resp_id    = dp_down_resp_id;
    assign dma_down_resp_rdata = dp_down_resp_rdata;
  end

  // Prioritize data misses, then walker/L1I, then DMA and prefetches. The
  // starvation bound permits DMA progress under sustained CPU traffic;
  // maintenance follows L1D.
  line_port_arbiter #(
      .NUM_PORTS(3),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(L1_LINE_BYTES),
      .UP_ID_BITS(UP_ID_BITS),
      .STARVATION_LIMIT(DMA_STARVATION_LIMIT)
  ) l1_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid({dp_down_req_valid, wi_down_req_valid, l1_down_req_valid}),
      .o_up_req_ready({dp_down_req_ready, wi_down_req_ready, l1_down_req_ready}),
      .i_up_req_write({dp_down_req_write, wi_down_req_write, l1_down_req_write}),
      .i_up_req_addr({dp_down_req_addr, wi_down_req_addr, l1_down_req_addr}),
      .i_up_req_wdata({dp_down_req_wdata, wi_down_req_wdata, l1_down_req_wdata}),
      .i_up_req_wstrb({dp_down_req_wstrb, wi_down_req_wstrb, l1_down_req_wstrb}),
      .i_up_req_id({dp_down_req_id, wi_down_req_id, l1_down_req_id}),
      .i_up_req_maintenance({1'b0, wi_down_req_maintenance, l1_down_req_maintenance}),
      .o_up_resp_valid({dp_down_resp_valid, wi_down_resp_valid, l1_down_resp_valid}),
      .o_up_resp_id({dp_down_resp_id, wi_down_resp_id, l1_down_resp_id}),
      .o_up_resp_rdata({dp_down_resp_rdata, wi_down_resp_rdata, l1_down_resp_rdata}),
      .o_down_req_valid(arb_down_req_valid),
      .i_down_req_ready(arb_down_req_ready),
      .o_down_req_write(arb_down_req_write),
      .o_down_req_addr(arb_down_req_addr),
      .o_down_req_wdata(arb_down_req_wdata),
      .o_down_req_wstrb(arb_down_req_wstrb),
      .o_down_req_id(arb_down_req_id),
      .o_down_req_maintenance(arb_down_req_maintenance),
      .i_down_resp_valid(arb_down_resp_valid),
      .i_down_resp_id(arb_down_resp_id),
      .i_down_resp_rdata(arb_down_resp_rdata)
  );

  // ---------------------------------------------------------------------------
  // fence.i sync sequencer: L1D writeback-all, then L1I invalidate-all.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    FENCE_IDLE,      // waiting for a sync request
    FENCE_L1D_REQ,   // request the L1D writeback-all (until its busy rises)
    FENCE_L1D_WAIT,  // wait out the writeback walk
    FENCE_L1I_REQ,   // request the L1I invalidate-all (until its busy rises)
    FENCE_L1I_WAIT,  // wait out the invalidate sweep
    FENCE_DONE       // hold done until the requester drops the request
  } fence_state_e;

  fence_state_e fence_state_q;
  // The request dropped after this sequence left FENCE_IDLE.
  logic         fence_req_dropped_q;
  // The request has stayed high since this sequence started.
  logic         fence_held;
  assign fence_held = i_fence_sync && !fence_req_dropped_q;

  assign l1d_writeback_req = (fence_state_q == FENCE_L1D_REQ);
  assign l1i_invalidate_req = (fence_state_q == FENCE_L1I_REQ);
  assign o_fence_done = (fence_state_q == FENCE_DONE);

  // Sweeps cannot abort. Complete only a request held throughout the sequence.
  // If it drops, later stores may miss this writeback walk; a re-executed
  // fence.i therefore needs a fresh sequence, even if it arrives before this
  // one ends. Finish the abandoned sequence without raising done.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fence_state_q       <= FENCE_IDLE;
      fence_req_dropped_q <= 1'b0;
    end else begin
      if (fence_state_q == FENCE_IDLE) fence_req_dropped_q <= 1'b0;
      else if (!i_fence_sync) fence_req_dropped_q <= 1'b1;
      unique case (fence_state_q)
        FENCE_IDLE:     if (i_fence_sync) fence_state_q <= FENCE_L1D_REQ;
        FENCE_L1D_REQ:  if (l1d_maint_busy) fence_state_q <= FENCE_L1D_WAIT;
        FENCE_L1D_WAIT: if (!l1d_maint_busy) fence_state_q <= FENCE_L1I_REQ;
        FENCE_L1I_REQ:  if (l1i_maint_busy) fence_state_q <= FENCE_L1I_WAIT;
        FENCE_L1I_WAIT: if (!l1i_maint_busy) fence_state_q <= fence_held ? FENCE_DONE : FENCE_IDLE;
        FENCE_DONE:     if (!i_fence_sync) fence_state_q <= FENCE_IDLE;
        default:        fence_state_q <= FENCE_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // The L2. With lines wider than the L1s', it sits behind the line-size
  // adapter, whose ready is the L2's, so the top arbiter's traffic is
  // accepted, and ordered, exactly when the L2 takes it.
  // ---------------------------------------------------------------------------
  logic                       l2_up_req_valid;
  logic                       l2_up_req_ready;
  logic                       l2_up_req_write;
  logic                       l2_up_req_maintenance;
  logic [     ADDR_WIDTH-1:0] l2_up_req_addr;
  logic [L2_LINE_BYTES*8-1:0] l2_up_req_wdata;
  logic [  L2_LINE_BYTES-1:0] l2_up_req_wstrb;
  logic [     DownIdBits-1:0] l2_up_req_id;
  logic                       l2_up_resp_valid;
  logic [     DownIdBits-1:0] l2_up_resp_id;
  logic [L2_LINE_BYTES*8-1:0] l2_up_resp_rdata;

  if (L2_LINE_BYTES == L1_LINE_BYTES) begin : gen_l2_same_lines
    assign l2_up_req_valid = arb_down_req_valid;
    assign arb_down_req_ready = l2_up_req_ready;
    assign l2_up_req_write = arb_down_req_write;
    assign l2_up_req_maintenance = arb_down_req_maintenance;
    assign l2_up_req_addr = arb_down_req_addr;
    assign l2_up_req_wdata = arb_down_req_wdata;
    assign l2_up_req_wstrb = arb_down_req_wstrb;
    assign l2_up_req_id = arb_down_req_id;
    assign arb_down_resp_valid = l2_up_resp_valid;
    assign arb_down_resp_id = l2_up_resp_id;
    assign arb_down_resp_rdata = l2_up_resp_rdata;
  end else begin : gen_l2_wide_lines
    line_size_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .UP_LINE_BYTES(L1_LINE_BYTES),
        .DOWN_LINE_BYTES(L2_LINE_BYTES),
        .ID_BITS(DownIdBits)
    ) l2_adapter (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_up_req_valid(arb_down_req_valid),
        .o_up_req_ready(arb_down_req_ready),
        .i_up_req_write(arb_down_req_write),
        .i_up_req_addr(arb_down_req_addr),
        .i_up_req_wdata(arb_down_req_wdata),
        .i_up_req_wstrb(arb_down_req_wstrb),
        .i_up_req_id(arb_down_req_id),
        .i_up_req_maintenance(arb_down_req_maintenance),
        .o_up_resp_valid(arb_down_resp_valid),
        .o_up_resp_id(arb_down_resp_id),
        .o_up_resp_rdata(arb_down_resp_rdata),
        .o_down_req_valid(l2_up_req_valid),
        .i_down_req_ready(l2_up_req_ready),
        .o_down_req_write(l2_up_req_write),
        .o_down_req_addr(l2_up_req_addr),
        .o_down_req_wdata(l2_up_req_wdata),
        .o_down_req_wstrb(l2_up_req_wstrb),
        .o_down_req_id(l2_up_req_id),
        .o_down_req_maintenance(l2_up_req_maintenance),
        .i_down_resp_valid(l2_up_resp_valid),
        .i_down_resp_id(l2_up_resp_id),
        .i_down_resp_rdata(l2_up_resp_rdata)
    );
  end

  frost_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L2_CACHE_BYTES),
      .LINE_BYTES(L2_LINE_BYTES),
      .WAYS(L2_WAYS),
      .UP_ID_BITS(DownIdBits),
      .DOWN_ID_BITS(L2_DOWN_ID_BITS),
      .NUM_MSHR(L2_NUM_MSHR),
      .NUM_WB(L2_NUM_WB),
      .NUM_WAITERS(L2_NUM_WAITERS),
      .TAG_MEMORY_PRIMITIVE("ultra"),
      .TAG_READ_LATENCY(L2_TAG_READ_LATENCY),
      .DATA_MEMORY_PRIMITIVE("ultra"),
      .DATA_READ_LATENCY(L2_DATA_READ_LATENCY),
      .DATA_WRITE_LATENCY(L2_DATA_WRITE_LATENCY),
      // Fast simulation reset bulk-clears tags; hardware sweeps one per cycle.
      .SIM_FAST_MAINT(SIM_FAST_MAINT)
  ) l2_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_writeback_all(1'b0),
      .i_invalidate_all(1'b0),
      .o_maint_busy(),
      .i_up_req_valid(l2_up_req_valid),
      .o_up_req_ready(l2_up_req_ready),
      .i_up_req_write(l2_up_req_write),
      .i_up_req_addr(l2_up_req_addr),
      .i_up_req_wdata(l2_up_req_wdata),
      .i_up_req_wstrb(l2_up_req_wstrb),
      .i_up_req_id(l2_up_req_id),
      // Provenance muxed per fire by the arbiter.
      .i_up_req_maintenance(l2_up_req_maintenance),
      .i_up_req_probe(1'b0),
      .i_up_req_probe_inval(1'b0),
      .i_probe_release_valid(1'b0),
      .i_probe_release_id('0),
      .o_up_resp_valid(l2_up_resp_valid),
      .o_up_resp_id(l2_up_resp_id),
      .o_up_resp_rdata(l2_up_resp_rdata),
      .o_down_req_valid(o_down_req_valid),
      .i_down_req_ready(i_down_req_ready),
      .o_down_req_write(o_down_req_write),
      .o_down_req_addr(o_down_req_addr),
      .o_down_req_wdata(o_down_req_wdata),
      .o_down_req_wstrb(o_down_req_wstrb),
      .o_down_req_id(o_down_req_id),
      .o_down_req_maintenance(),
      .i_down_resp_valid(i_down_resp_valid),
      .i_down_resp_id(i_down_resp_id),
      .i_down_resp_rdata(i_down_resp_rdata),
      .o_perf_events(l2_perf_events)
  );

`ifndef SYNTHESIS
  // The walker port is read-only; the sequencer in front of it has no write
  // path, so a write here would be silently turned into a read.
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_wup_req_valid && i_wup_req_write)
      $error(
          "frost_cache_hierarchy: write on the walker port (addr=0x%0h, wstrb=0x%0h)",
          i_wup_req_addr,
          i_wup_req_wstrb
      );
    if (!i_rst && walk_probe_release_valid && walk_release_hold_q)
      $error("frost_cache_hierarchy: walker probe release while one is still held");
  end

  // Dump the links if L1D remains blocked downstream for 2048 cycles.
  int unsigned down_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(l1_down_req_valid && !l1_down_req_ready)) begin
      down_stall_cnt <= 0;
    end else begin
      down_stall_cnt <= down_stall_cnt + 1;
      if (down_stall_cnt == 2048) begin
        $display("hierarchy DOWNSTREAM STALL: l1d{v=%0d rdy=%0d w=%0d} l1i{v=%0d rdy=%0d w=%0d}",
                 l1_down_req_valid, l1_down_req_ready, l1_down_req_write, l1i_down_req_valid,
                 l1i_down_req_ready, l1i_down_req_write);
        $display("  wup{v=%0d rdy=%0d} walk_down{v=%0d rdy=%0d} wi_down{v=%0d rdy=%0d id=%0d}",
                 i_wup_req_valid, o_wup_req_ready, walk_down_req_valid, walk_down_req_ready,
                 wi_down_req_valid, wi_down_req_ready, wi_down_req_id);
        $display("  arb_down{v=%0d rdy=%0d w=%0d id=%0d} down_resp{v=%0d id=%0d}",
                 arb_down_req_valid, arb_down_req_ready, arb_down_req_write, arb_down_req_id,
                 arb_down_resp_valid, arb_down_resp_id);
        $error("frost_cache_hierarchy: data L1 refused downstream for 2048 cycles");
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // Cover point for simulation coverage (tests/README.md): an L1D read
  // reaches the L2 while the prefetcher's read of the same L2 line is still
  // outstanding, so the demand read has caught up with the prefetch. The
  // prefetches in flight are tracked by id on the DMA port, where the top id
  // bit marks the prefetcher's requests and responses.
  if (L2_PREFETCH != 0) begin : gen_prefetch_cover
    localparam int unsigned CoverLineLsb = $clog2(L2_LINE_BYTES);
    localparam int unsigned CoverPfIds   = 1 << (UP_ID_BITS - 1);
    logic [CoverPfIds-1:0] cover_pf_busy_q;
    logic [ADDR_WIDTH-1:CoverLineLsb] cover_pf_line_q[CoverPfIds];
    logic cover_pf_line_match;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        cover_pf_busy_q <= '0;
      end else begin
        if (dp_down_resp_valid && dp_down_resp_id[UP_ID_BITS-1])
          cover_pf_busy_q[dp_down_resp_id[UP_ID_BITS-2:0]] <= 1'b0;
        if (dp_down_req_valid && dp_down_req_ready && dp_down_req_id[UP_ID_BITS-1]) begin
          cover_pf_busy_q[dp_down_req_id[UP_ID_BITS-2:0]] <= 1'b1;
          cover_pf_line_q[dp_down_req_id[UP_ID_BITS-2:0]] <=
              dp_down_req_addr[ADDR_WIDTH-1:CoverLineLsb];
        end
      end
    end
    always_comb begin
      cover_pf_line_match = 1'b0;
      for (int k = 0; k < int'(CoverPfIds); k++) begin
        if (cover_pf_busy_q[k] &&
            (cover_pf_line_q[k] == l1_down_req_addr[ADDR_WIDTH-1:CoverLineLsb]))
          cover_pf_line_match = 1'b1;
      end
    end
    cover_demand_read_meets_prefetch :
    cover property (@(posedge i_clk) disable iff (i_rst)
        l1_down_req_valid && l1_down_req_ready && !l1_down_req_write && cover_pf_line_match);
  end
`endif
`endif

endmodule : frost_cache_hierarchy
