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
 * through the load queue.
 *
 * The module composes one hart's private caches, frost_hart_cache (the L1D,
 * the L1I, the walker sequencer, the probe injection into the L1D, and
 * fence.i sequencing), with the shared level, frost_cluster_cache (the
 * arbiter tree, the DMA sequencer, the stream prefetcher, the line-size
 * adapter, and the L2). The two connect by wires: the L1D's, the L1I's, and
 * the walker sequencer's line ports, and the DMA sequencer's probes into the
 * L1D with their acknowledgements and releases. Each documents its ids and
 * line sizes. The cache unit benches and the TestRIG platform use this
 * module; cpu_top instantiates the two parts itself, in frost_hart and
 * frost_cluster_memory.
 */
module frost_cache_hierarchy #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
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
    // Bimodal insertion per cache (frost_cache BIMODAL_INSERT). The L1D uses
    // it, so that a working set somewhat larger than the L1D keeps part of
    // itself resident.
    parameter bit L1D_BIMODAL_INSERT = 1'b1,
    parameter bit L1I_BIMODAL_INSERT = 1'b0,
    parameter bit L2_BIMODAL_INSERT = 1'b0,
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
    output logic                       o_wup_resp_error,
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
    output logic                       o_dma_resp_error,
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
    // held since its sequence started (see the sequencer in frost_hart_cache).
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
    input  logic                       i_down_resp_error = 1'b0,

    // Fatal buffered-store failures require external recovery. Read-only
    // refill errors instead return to the matching upstream requester.
    output logic o_fatal_error,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr,

    // Source-registered per-instance performance observers.
    output cache_perf_pkg::cache_hierarchy_perf_events_t o_perf_events
);

  // Width of the L1D's upstream ids, which carry the DMA probes (see
  // frost_hart_cache).
  localparam int unsigned ProbeIdxBitsMin = $clog2(NUM_DMA_LOCK + 1);
  localparam int unsigned ProbeIdxBits =
      (UP_ID_BITS > ProbeIdxBitsMin) ? UP_ID_BITS : ProbeIdxBitsMin;
  localparam int unsigned L1dIdBits = ProbeIdxBits + 1;

  // The L1D's, the L1I's, and the walker sequencer's line ports into the
  // shared level.
  logic                       l1d_down_req_valid;
  logic                       l1d_down_req_ready;
  logic                       l1d_down_req_write;
  logic                       l1d_down_req_maintenance;
  logic [     ADDR_WIDTH-1:0] l1d_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] l1d_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] l1d_down_req_wstrb;
  logic [     UP_ID_BITS-1:0] l1d_down_req_id;
  logic                       l1d_down_resp_valid;
  logic [     UP_ID_BITS-1:0] l1d_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] l1d_down_resp_rdata;
  logic                       l1d_down_resp_error;

  logic                       l1i_down_req_valid;
  logic                       l1i_down_req_ready;
  logic                       l1i_down_req_write;
  logic [     ADDR_WIDTH-1:0] l1i_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] l1i_down_req_wdata;
  logic [  L1_LINE_BYTES-1:0] l1i_down_req_wstrb;
  logic [     UP_ID_BITS-2:0] l1i_down_req_id;
  logic                       l1i_down_resp_valid;
  logic [     UP_ID_BITS-2:0] l1i_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] l1i_down_resp_rdata;
  logic                       l1i_down_resp_error;

  logic                       walk_down_req_valid;
  logic                       walk_down_req_ready;
  logic [     ADDR_WIDTH-1:0] walk_down_req_addr;
  logic [     UP_ID_BITS-2:0] walk_down_req_id;
  logic                       walk_down_resp_valid;
  logic [     UP_ID_BITS-2:0] walk_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] walk_down_resp_rdata;
  logic                       walk_down_resp_error;

  // The DMA sequencer's probes into the L1D.
  logic dma_probe_req_valid, dma_probe_req_ready, dma_probe_req_inval;
  logic [ADDR_WIDTH-1:0] dma_probe_req_addr;
  logic [L1dIdBits-1:0] dma_probe_req_id;
  logic dma_probe_ack_valid;
  logic [L1dIdBits-1:0] dma_probe_ack_id;
  logic dma_probe_release_valid;
  logic [L1dIdBits-1:0] dma_probe_release_id;

  logic hart_fatal, cluster_fatal;
  logic [ADDR_WIDTH-1:0] hart_fatal_addr, cluster_fatal_addr;
  // The L2's address first, then the L1D's, then the L1I's.
  assign o_fatal_error = hart_fatal || cluster_fatal;
  assign o_fatal_addr  = cluster_fatal ? cluster_fatal_addr : hart_fatal_addr;
  cache_perf_pkg::cache_instance_perf_events_t l1d_perf_events;
  cache_perf_pkg::cache_instance_perf_events_t l1i_perf_events;
  cache_perf_pkg::cache_instance_perf_events_t l2_perf_events;
  assign o_perf_events.l1d = l1d_perf_events;
  assign o_perf_events.l1i = l1i_perf_events;
  assign o_perf_events.l2  = l2_perf_events;

  frost_hart_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .ENABLE_RESPONSE_ERRORS(ENABLE_RESPONSE_ERRORS),
      .L1_LINE_BYTES(L1_LINE_BYTES),
      .UP_ID_BITS(UP_ID_BITS),
      .L1_CACHE_BYTES(L1_CACHE_BYTES),
      .L1_DATA_READ_LATENCY(L1_DATA_READ_LATENCY),
      .L1_DATA_WRITE_LATENCY(L1_DATA_WRITE_LATENCY),
      .L1D_NUM_MSHR(L1D_NUM_MSHR),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .L1I_DATA_READ_LATENCY(L1I_DATA_READ_LATENCY),
      .L1D_WAYS(L1D_WAYS),
      .L1I_WAYS(L1I_WAYS),
      .L1D_BIMODAL_INSERT(L1D_BIMODAL_INSERT),
      .L1I_BIMODAL_INSERT(L1I_BIMODAL_INSERT),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .NUM_DMA_LOCK(NUM_DMA_LOCK)
  ) hart_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid(i_up_req_valid),
      .o_up_req_ready(o_up_req_ready),
      .i_up_req_write(i_up_req_write),
      .i_up_req_addr(i_up_req_addr),
      .i_up_req_wdata(i_up_req_wdata),
      .i_up_req_wstrb(i_up_req_wstrb),
      .i_up_req_id(i_up_req_id),
      .o_up_resp_valid(o_up_resp_valid),
      .o_up_resp_id(o_up_resp_id),
      .o_up_resp_rdata(o_up_resp_rdata),
      .o_up_resp_error(o_up_resp_error),
      .i_iup_req_valid(i_iup_req_valid),
      .o_iup_req_ready(o_iup_req_ready),
      .i_iup_req_write(i_iup_req_write),
      .i_iup_req_addr(i_iup_req_addr),
      .i_iup_req_wdata(i_iup_req_wdata),
      .i_iup_req_wstrb(i_iup_req_wstrb),
      .i_iup_req_id(i_iup_req_id),
      .o_iup_resp_valid(o_iup_resp_valid),
      .o_iup_resp_id(o_iup_resp_id),
      .o_iup_resp_rdata(o_iup_resp_rdata),
      .o_iup_resp_error(o_iup_resp_error),
      .i_wup_req_valid(i_wup_req_valid),
      .o_wup_req_ready(o_wup_req_ready),
      .i_wup_req_write(i_wup_req_write),
      .i_wup_req_addr(i_wup_req_addr),
      .i_wup_req_wdata(i_wup_req_wdata),
      .i_wup_req_wstrb(i_wup_req_wstrb),
      .i_wup_req_id(i_wup_req_id),
      .o_wup_resp_valid(o_wup_resp_valid),
      .o_wup_resp_id(o_wup_resp_id),
      .o_wup_resp_rdata(o_wup_resp_rdata),
      .o_wup_resp_error(o_wup_resp_error),
      .i_fence_sync(i_fence_sync),
      .o_fence_done(o_fence_done),
      .o_l1d_down_req_valid(l1d_down_req_valid),
      .i_l1d_down_req_ready(l1d_down_req_ready),
      .o_l1d_down_req_write(l1d_down_req_write),
      .o_l1d_down_req_maintenance(l1d_down_req_maintenance),
      .o_l1d_down_req_addr(l1d_down_req_addr),
      .o_l1d_down_req_wdata(l1d_down_req_wdata),
      .o_l1d_down_req_wstrb(l1d_down_req_wstrb),
      .o_l1d_down_req_id(l1d_down_req_id),
      .i_l1d_down_resp_valid(l1d_down_resp_valid),
      .i_l1d_down_resp_id(l1d_down_resp_id),
      .i_l1d_down_resp_rdata(l1d_down_resp_rdata),
      .i_l1d_down_resp_error(l1d_down_resp_error),
      .o_l1i_down_req_valid(l1i_down_req_valid),
      .i_l1i_down_req_ready(l1i_down_req_ready),
      .o_l1i_down_req_write(l1i_down_req_write),
      .o_l1i_down_req_addr(l1i_down_req_addr),
      .o_l1i_down_req_wdata(l1i_down_req_wdata),
      .o_l1i_down_req_wstrb(l1i_down_req_wstrb),
      .o_l1i_down_req_id(l1i_down_req_id),
      .i_l1i_down_resp_valid(l1i_down_resp_valid),
      .i_l1i_down_resp_id(l1i_down_resp_id),
      .i_l1i_down_resp_rdata(l1i_down_resp_rdata),
      .i_l1i_down_resp_error(l1i_down_resp_error),
      .o_walk_down_req_valid(walk_down_req_valid),
      .i_walk_down_req_ready(walk_down_req_ready),
      .o_walk_down_req_addr(walk_down_req_addr),
      .o_walk_down_req_id(walk_down_req_id),
      .i_walk_down_resp_valid(walk_down_resp_valid),
      .i_walk_down_resp_id(walk_down_resp_id),
      .i_walk_down_resp_rdata(walk_down_resp_rdata),
      .i_walk_down_resp_error(walk_down_resp_error),
      .i_dma_probe_req_valid(dma_probe_req_valid),
      .o_dma_probe_req_ready(dma_probe_req_ready),
      .i_dma_probe_req_addr(dma_probe_req_addr),
      .i_dma_probe_req_inval(dma_probe_req_inval),
      .i_dma_probe_req_id(dma_probe_req_id),
      .o_dma_probe_ack_valid(dma_probe_ack_valid),
      .o_dma_probe_ack_id(dma_probe_ack_id),
      .i_dma_probe_release_valid(dma_probe_release_valid),
      .i_dma_probe_release_id(dma_probe_release_id),
      .o_fatal_error(hart_fatal),
      .o_fatal_addr(hart_fatal_addr),
      .o_l1d_perf_events(l1d_perf_events),
      .o_l1i_perf_events(l1i_perf_events)
  );

  frost_cluster_cache #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .ENABLE_RESPONSE_ERRORS(ENABLE_RESPONSE_ERRORS),
      .L1_LINE_BYTES(L1_LINE_BYTES),
      .L2_LINE_BYTES(L2_LINE_BYTES),
      .UP_ID_BITS(UP_ID_BITS),
      .L2_CACHE_BYTES(L2_CACHE_BYTES),
      .L2_WAYS(L2_WAYS),
      .L2_BIMODAL_INSERT(L2_BIMODAL_INSERT),
      .L2_TAG_READ_LATENCY(L2_TAG_READ_LATENCY),
      .L2_DATA_READ_LATENCY(L2_DATA_READ_LATENCY),
      .L2_DATA_WRITE_LATENCY(L2_DATA_WRITE_LATENCY),
      .L2_NUM_MSHR(L2_NUM_MSHR),
      .L2_NUM_WB(L2_NUM_WB),
      .L2_DOWN_ID_BITS(L2_DOWN_ID_BITS),
      .L2_NUM_WAITERS(L2_NUM_WAITERS),
      .L2_PREFETCH(L2_PREFETCH),
      .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
      .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .NUM_DMA_LOCK(NUM_DMA_LOCK),
      .DMA_STARVATION_LIMIT(DMA_STARVATION_LIMIT)
  ) cluster_cache (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_l1d_down_req_valid(l1d_down_req_valid),
      .o_l1d_down_req_ready(l1d_down_req_ready),
      .i_l1d_down_req_write(l1d_down_req_write),
      .i_l1d_down_req_maintenance(l1d_down_req_maintenance),
      .i_l1d_down_req_addr(l1d_down_req_addr),
      .i_l1d_down_req_wdata(l1d_down_req_wdata),
      .i_l1d_down_req_wstrb(l1d_down_req_wstrb),
      .i_l1d_down_req_id(l1d_down_req_id),
      .o_l1d_down_resp_valid(l1d_down_resp_valid),
      .o_l1d_down_resp_id(l1d_down_resp_id),
      .o_l1d_down_resp_rdata(l1d_down_resp_rdata),
      .o_l1d_down_resp_error(l1d_down_resp_error),
      .i_l1i_down_req_valid(l1i_down_req_valid),
      .o_l1i_down_req_ready(l1i_down_req_ready),
      .i_l1i_down_req_write(l1i_down_req_write),
      .i_l1i_down_req_addr(l1i_down_req_addr),
      .i_l1i_down_req_wdata(l1i_down_req_wdata),
      .i_l1i_down_req_wstrb(l1i_down_req_wstrb),
      .i_l1i_down_req_id(l1i_down_req_id),
      .o_l1i_down_resp_valid(l1i_down_resp_valid),
      .o_l1i_down_resp_id(l1i_down_resp_id),
      .o_l1i_down_resp_rdata(l1i_down_resp_rdata),
      .o_l1i_down_resp_error(l1i_down_resp_error),
      .i_walk_down_req_valid(walk_down_req_valid),
      .o_walk_down_req_ready(walk_down_req_ready),
      .i_walk_down_req_addr(walk_down_req_addr),
      .i_walk_down_req_id(walk_down_req_id),
      .o_walk_down_resp_valid(walk_down_resp_valid),
      .o_walk_down_resp_id(walk_down_resp_id),
      .o_walk_down_resp_rdata(walk_down_resp_rdata),
      .o_walk_down_resp_error(walk_down_resp_error),
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
      .o_dma_resp_error(o_dma_resp_error),
      .o_coh_admit_valid(o_coh_admit_valid),
      .o_coh_admit_slot(o_coh_admit_slot),
      .o_coh_admit_addr(o_coh_admit_addr),
      .i_coh_admit_ready(i_coh_admit_ready),
      .o_coh_inval_valid(o_coh_inval_valid),
      .o_coh_inval_slot(o_coh_inval_slot),
      .i_coh_inval_done(i_coh_inval_done),
      .o_coh_release_valid(o_coh_release_valid),
      .o_coh_release_slot(o_coh_release_slot),
      .o_dma_probe_req_valid(dma_probe_req_valid),
      .i_dma_probe_req_ready(dma_probe_req_ready),
      .o_dma_probe_req_addr(dma_probe_req_addr),
      .o_dma_probe_req_inval(dma_probe_req_inval),
      .o_dma_probe_req_id(dma_probe_req_id),
      .i_dma_probe_ack_valid(dma_probe_ack_valid),
      .i_dma_probe_ack_id(dma_probe_ack_id),
      .o_dma_probe_release_valid(dma_probe_release_valid),
      .o_dma_probe_release_id(dma_probe_release_id),
      .o_down_req_valid(o_down_req_valid),
      .i_down_req_ready(i_down_req_ready),
      .o_down_req_write(o_down_req_write),
      .o_down_req_addr(o_down_req_addr),
      .o_down_req_wdata(o_down_req_wdata),
      .o_down_req_wstrb(o_down_req_wstrb),
      .o_down_req_id(o_down_req_id),
      .i_down_resp_valid(i_down_resp_valid),
      .i_down_resp_id(i_down_resp_id),
      .i_down_resp_rdata(i_down_resp_rdata),
      .i_down_resp_error(i_down_resp_error),
      .o_fatal_error(cluster_fatal),
      .o_fatal_addr(cluster_fatal_addr),
      .o_l2_perf_events(l2_perf_events)
  );

endmodule : frost_cache_hierarchy
