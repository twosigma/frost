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
 * frost_hart_cache: one hart's private caches (hw/rtl/lib/cache/README.md,
 * "The hierarchy").
 *
 * Three upstream line-port slaves:
 *   up   the data side, through the L1D;
 *   iup  instruction fetch, through the read-only L1I;
 *   wup  the page-table walker, uncached, through walker_coherence_sequencer,
 *        which probes the L1D before each read leaves on the walker line.
 * Three downstream line-port masters, the L1D's (l1d_down), the L1I's
 * (l1i_down), and the walker sequencer's (walk_down), lead to the shared
 * level (frost_cluster_cache), which orders them at the L2. The shared
 * level's DMA sequencer probes the L1D through this module's probe injection
 * register (the dma_probe ports), so DMA sees dirty L1D data.
 *
 * The up and iup ports and the L1D's downstream ids carry UP_ID_BITS; the
 * wup port and the L1I's and walker's downstream ids carry UP_ID_BITS-1,
 * which the shared level's sub-arbiter widens by its port index. With the
 * default UP_ID_BITS=3, that leaves the L1I 2 miss slots, all its master (the
 * two-line fetch provider) ever uses. cpu_top uses UP_ID_BITS=4, which the
 * L1D's {type, slot} ids need for 8 miss slots (L1D_NUM_MSHR). The walker
 * keeps one walk in flight with id 0.
 *
 * Each L1 exports a registered performance-event bundle. The L1D's
 * writeback-all traffic carries the maintenance bit on its downstream port,
 * so the L2 leaves fence.i writebacks out of every event. Walker traffic
 * carries no maintenance bit and counts as ordinary.
 */
module frost_hart_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
    // Lines of the L1s and of every port.
    parameter int unsigned L1_LINE_BYTES = 32,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L1_DATA_WRITE_LATENCY = 1,
    // L1D miss-status slots. The L1D's downstream ids are UP_ID_BITS wide and
    // must hold {type, slot}.
    parameter int unsigned L1D_NUM_MSHR = 4,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1I_DATA_READ_LATENCY = 2,
    // Ways per set of each L1 (frost_cache WAYS): a power of 2, 1 for
    // direct-mapped.
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    // Bimodal insertion per L1 (frost_cache BIMODAL_INSERT). The L1D uses
    // it, so that a working set somewhat larger than the L1D keeps part of
    // itself resident.
    parameter bit L1D_BIMODAL_INSERT = 1'b1,
    parameter bit L1I_BIMODAL_INSERT = 1'b0,
    // Simulation-only fast cache maintenance for fence.i (see frost_cache).
    // 0 = FPGA cycle-accurate FSM; non-zero = sim fast path. Passed to both
    // L1s so reset can bulk-clear their tag arrays.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // Lock entries of the shared level's DMA coherence sequencer: the L1D
    // gets one probe slot per entry plus the walker's.
    parameter int unsigned NUM_DMA_LOCK = 3,
    // L1D upstream ids: a high probe bit above an index that holds the
    // UP_ID_BITS-bit CPU ids and NUM_DMA_LOCK + 1 probe ids.
    localparam int unsigned ProbeIdxBitsMin = $clog2(NUM_DMA_LOCK + 1),
    localparam int unsigned ProbeIdxBits =
        (UP_ID_BITS > ProbeIdxBitsMin) ? UP_ID_BITS : ProbeIdxBitsMin,
    localparam int unsigned L1dIdBits = ProbeIdxBits + 1
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
    output logic                       o_up_resp_error,

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
    output logic                       o_iup_resp_error,

    // Walker reads probe L1D, then leave on the walker line without a private
    // cache. Write inputs are ignored and flagged in simulation. IDs have
    // UP_ID_BITS-1 bits.
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
    output logic                       o_wup_resp_error,

    // fence.i cache sync: hold i_fence_sync until o_fence_done rises (done
    // stays high while the request is held). The L1D writes back every dirty
    // line first, then the L1I invalidates, so an instruction fill racing the
    // sync cannot leave pre-writeback data in the freshly invalidated L1I.
    // The shared level needs no maintenance: it sits below both L1s, so
    // everything the L1D writes back is visible to L1I fills. Done answers
    // only a request held since its sequence started (see the sequencer
    // below).
    input  logic i_fence_sync,
    output logic o_fence_done,

    // L1D downstream line port (master): misses, writebacks, and fence.i
    // writebacks, which carry the maintenance bit.
    output logic                       o_l1d_down_req_valid,
    input  logic                       i_l1d_down_req_ready,
    output logic                       o_l1d_down_req_write,
    output logic                       o_l1d_down_req_maintenance,
    output logic [     ADDR_WIDTH-1:0] o_l1d_down_req_addr,
    output logic [L1_LINE_BYTES*8-1:0] o_l1d_down_req_wdata,
    output logic [  L1_LINE_BYTES-1:0] o_l1d_down_req_wstrb,
    output logic [     UP_ID_BITS-1:0] o_l1d_down_req_id,
    input  logic                       i_l1d_down_resp_valid,
    input  logic [     UP_ID_BITS-1:0] i_l1d_down_resp_id,
    input  logic [L1_LINE_BYTES*8-1:0] i_l1d_down_resp_rdata,
    input  logic                       i_l1d_down_resp_error,

    // L1I downstream line port (master): fills, with UP_ID_BITS-1-bit ids.
    output logic                       o_l1i_down_req_valid,
    input  logic                       i_l1i_down_req_ready,
    output logic                       o_l1i_down_req_write,
    output logic [     ADDR_WIDTH-1:0] o_l1i_down_req_addr,
    output logic [L1_LINE_BYTES*8-1:0] o_l1i_down_req_wdata,
    output logic [  L1_LINE_BYTES-1:0] o_l1i_down_req_wstrb,
    output logic [     UP_ID_BITS-2:0] o_l1i_down_req_id,
    input  logic                       i_l1i_down_resp_valid,
    input  logic [     UP_ID_BITS-2:0] i_l1i_down_resp_id,
    input  logic [L1_LINE_BYTES*8-1:0] i_l1i_down_resp_rdata,
    input  logic                       i_l1i_down_resp_error,

    // Walker line port (master): the walker sequencer's reads, each issued
    // once its L1D probe is acknowledged, with UP_ID_BITS-1-bit ids.
    output logic                       o_walk_down_req_valid,
    input  logic                       i_walk_down_req_ready,
    output logic [     ADDR_WIDTH-1:0] o_walk_down_req_addr,
    output logic [     UP_ID_BITS-2:0] o_walk_down_req_id,
    input  logic                       i_walk_down_resp_valid,
    input  logic [     UP_ID_BITS-2:0] i_walk_down_resp_id,
    input  logic [L1_LINE_BYTES*8-1:0] i_walk_down_resp_rdata,
    input  logic                       i_walk_down_resp_error,

    // DMA probes into the L1D (slave), from the shared level's
    // dma_coherence_sequencer: a probe request with its invalidate selector
    // and probe id, the acknowledgement with the L1D's response id, and the
    // release that frees the probe slot.
    input  logic                  i_dma_probe_req_valid,
    output logic                  o_dma_probe_req_ready,
    input  logic [ADDR_WIDTH-1:0] i_dma_probe_req_addr,
    input  logic                  i_dma_probe_req_inval,
    input  logic [ L1dIdBits-1:0] i_dma_probe_req_id,
    output logic                  o_dma_probe_ack_valid,
    output logic [ L1dIdBits-1:0] o_dma_probe_ack_id,
    input  logic                  i_dma_probe_release_valid,
    input  logic [ L1dIdBits-1:0] i_dma_probe_release_id,

    // Fatal buffered-store failures in either L1 require external recovery.
    // Read-only refill errors instead return to the matching upstream
    // requester.
    output logic o_fatal_error,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr,

    // Source-registered per-instance performance observers.
    output cache_perf_pkg::cache_instance_perf_events_t o_l1d_perf_events,
    output cache_perf_pkg::cache_instance_perf_events_t o_l1i_perf_events
);

  // Walker and L1I downstream id width: one bit fewer than the L1D's, which
  // the shared level's walker/L1I sub-arbiter adds back as its port index.
  localparam int unsigned WalkIdBits = UP_ID_BITS - 1;

  initial begin
    // The shared level's id tree needs one prefix bit above the walker/L1I
    // local ids.
    if (UP_ID_BITS < 2) $fatal(1, "frost_hart_cache: UP_ID_BITS must be >= 2");
  end

  // fence.i sequencer handshakes (FSM below).
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
  localparam int unsigned ProbeIdBase = 1 << ProbeIdxBits;
  localparam int unsigned WalkProbeId = ProbeIdBase + NUM_DMA_LOCK;
  // L1D probe slots: one per DMA entry plus the walker's.
  localparam int unsigned NumL1dProbe = NUM_DMA_LOCK + 1;
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
  logic probe_ack_valid, walk_probe_ack_valid;
  logic walk_probe_release_valid;
  logic probe_release_valid;
  logic [L1dIdBits-1:0] probe_release_id;
  assign walk_probe_req_ready  = !pinj_valid_q;
  assign o_dma_probe_req_ready = !pinj_valid_q && !walk_probe_req_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pinj_valid_q <= 1'b0;
    end else if (!pinj_valid_q) begin
      if (walk_probe_req_valid) begin
        pinj_valid_q <= 1'b1;
        pinj_addr_q  <= walk_probe_req_addr;
        pinj_inval_q <= 1'b0;
        pinj_id_q    <= walk_probe_req_id;
      end else if (i_dma_probe_req_valid) begin
        pinj_valid_q <= 1'b1;
        pinj_addr_q  <= i_dma_probe_req_addr;
        pinj_inval_q <= i_dma_probe_req_inval;
        pinj_id_q    <= i_dma_probe_req_id;
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
  assign o_dma_probe_ack_valid = probe_ack_valid && (l1d_up_resp_id != L1dIdBits'(WalkProbeId));
  assign o_dma_probe_ack_id = l1d_up_resp_id;
  assign o_up_resp_valid = l1d_up_resp_valid && !l1d_up_resp_id[L1dIdBits-1];
  assign o_up_resp_id = l1d_up_resp_id[UP_ID_BITS-1:0];

  // Probe release merge onto the L1D's single release port. The DMA
  // sequencer's registered pulse goes through at once; a walker pulse that
  // collides with it waits one cycle in a holding flop. DMA pulses are at
  // least two cycles apart (its request register refills only once empty)
  // and the walker's a whole read apart, so the flop never has to hold two.
  logic walk_release_hold_q, walk_release_pending;
  assign walk_release_pending = walk_probe_release_valid || walk_release_hold_q;
  assign probe_release_valid = i_dma_probe_release_valid || walk_release_pending;
  assign probe_release_id =
      i_dma_probe_release_valid ? i_dma_probe_release_id : L1dIdBits'(WalkProbeId);
  always_ff @(posedge i_clk) begin
    if (i_rst) walk_release_hold_q <= 1'b0;
    else walk_release_hold_q <= walk_release_pending && i_dma_probe_release_valid;
  end

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
      .o_walk_resp_error(o_wup_resp_error),
      .o_walk_resp_rdata(o_wup_resp_rdata),
      .o_probe_req_valid(walk_probe_req_valid),
      .i_probe_req_ready(walk_probe_req_ready),
      .o_probe_req_addr(walk_probe_req_addr),
      .o_probe_req_id(walk_probe_req_id),
      .i_probe_ack_valid(walk_probe_ack_valid),
      .o_probe_release_valid(walk_probe_release_valid),
      .o_down_req_valid(o_walk_down_req_valid),
      .i_down_req_ready(i_walk_down_req_ready),
      .o_down_req_addr(o_walk_down_req_addr),
      .o_down_req_id(o_walk_down_req_id),
      .i_down_resp_valid(i_walk_down_resp_valid),
      .i_down_resp_id(i_walk_down_resp_id),
      .i_down_resp_error(i_walk_down_resp_error),
      .i_down_resp_rdata(i_walk_down_resp_rdata)
  );

  logic [1:0] cache_fatal;
  logic [1:0][ADDR_WIDTH-1:0] cache_fatal_addr;
  assign o_fatal_error = |cache_fatal;
  assign o_fatal_addr  = cache_fatal[0] ? cache_fatal_addr[0] : cache_fatal_addr[1];

  frost_cache #(
      .ENABLE_RESPONSE_ERRORS(ENABLE_RESPONSE_ERRORS),
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1_CACHE_BYTES),
      .LINE_BYTES(L1_LINE_BYTES),
      .WAYS(L1D_WAYS),
      .BIMODAL_INSERT(L1D_BIMODAL_INSERT),
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
      .o_fatal_error(cache_fatal[0]),
      .o_fatal_addr(cache_fatal_addr[0]),
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
      .o_up_resp_error(o_up_resp_error),
      .o_up_resp_rdata(o_up_resp_rdata),
      .o_down_req_valid(o_l1d_down_req_valid),
      .i_down_req_ready(i_l1d_down_req_ready),
      .o_down_req_write(o_l1d_down_req_write),
      .o_down_req_addr(o_l1d_down_req_addr),
      .o_down_req_wdata(o_l1d_down_req_wdata),
      .o_down_req_wstrb(o_l1d_down_req_wstrb),
      .o_down_req_id(o_l1d_down_req_id),
      .o_down_req_maintenance(o_l1d_down_req_maintenance),
      .i_down_resp_valid(i_l1d_down_resp_valid),
      .i_down_resp_id(i_l1d_down_resp_id),
      .i_down_resp_error(i_l1d_down_resp_error),
      .i_down_resp_rdata(i_l1d_down_resp_rdata),
      .o_perf_events(o_l1d_perf_events)
  );

  frost_cache #(
      .ENABLE_RESPONSE_ERRORS(ENABLE_RESPONSE_ERRORS),
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L1I_CACHE_BYTES),
      .LINE_BYTES(L1_LINE_BYTES),
      .WAYS(L1I_WAYS),
      .BIMODAL_INSERT(L1I_BIMODAL_INSERT),
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
      .o_fatal_error(cache_fatal[1]),
      .o_fatal_addr(cache_fatal_addr[1]),
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
      .o_up_resp_error(o_iup_resp_error),
      .o_up_resp_rdata(o_iup_resp_rdata),
      .o_down_req_valid(o_l1i_down_req_valid),
      .i_down_req_ready(i_l1i_down_req_ready),
      .o_down_req_write(o_l1i_down_req_write),
      .o_down_req_addr(o_l1i_down_req_addr),
      .o_down_req_wdata(o_l1i_down_req_wdata),
      .o_down_req_wstrb(o_l1i_down_req_wstrb),
      .o_down_req_id(o_l1i_down_req_id),
      .o_down_req_maintenance(),
      .i_down_resp_valid(i_l1i_down_resp_valid),
      .i_down_resp_id(i_l1i_down_resp_id),
      .i_down_resp_error(i_l1i_down_resp_error),
      .i_down_resp_rdata(i_l1i_down_resp_rdata),
      .o_perf_events(o_l1i_perf_events)
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

`ifndef SYNTHESIS
  // The walker port is read-only; the sequencer in front of it has no write
  // path, so a write here would be silently turned into a read.
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_wup_req_valid && i_wup_req_write)
      $error(
          "frost_hart_cache: write on the walker port (addr=0x%0h, wstrb=0x%0h)",
          i_wup_req_addr,
          i_wup_req_wstrb
      );
    if (!i_rst && walk_probe_release_valid && walk_release_hold_q)
      $error("frost_hart_cache: walker probe release while one is still held");
  end
`endif

endmodule : frost_hart_cache
