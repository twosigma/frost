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
 * frost_cluster_cache: the shared level of the cache hierarchy, below a
 * hart's private caches (hw/rtl/lib/cache/README.md, "The hierarchy").
 *
 * Four upstream line-port slaves share one downstream master:
 *   l1d_down   the L1D's misses and writebacks (frost_hart_cache);
 *   l1i_down   the L1I's fills;
 *   walk_down  the walker sequencer's reads, already probed in the L1D;
 *   dma        a DMA agent, through dma_coherence_sequencer.
 * The DMA sequencer probes the L1D through the hart's probe injection
 * register (the dma_probe ports) before its traffic reaches the L2, so DMA
 * sees dirty L1D data, and each DMA write also goes through the load queue.
 * A 2:1 arbiter (walker > L1I) feeds a 3:1 arbiter (L1D > that pair > DMA).
 * Both are combinational pass-throughs, so the tree acts as one
 * fixed-priority arbiter ordered L1D, walker, L1I, DMA, and the top arbiter
 * adds a starvation bound. It feeds the L2, which drives the downstream port.
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
 * The l1d_down and dma ports carry UP_ID_BITS; the walk_down and l1i_down
 * ports carry UP_ID_BITS-1. With the default UP_ID_BITS=3, DownIdBits is 5;
 * cpu_top uses UP_ID_BITS=4, so DownIdBits is 6 there.
 * The L2 takes DownIdBits ids and gives its own downstream requests
 * {type, slot} ids, L2_DOWN_ID_BITS wide: 5 on the X3, the AXI id width of
 * its DDR block design (fpga/build/x3_ddr_bd.tcl), enough for 16 slots of
 * each type.
 *
 * The L2 exports a registered performance-event bundle. The L1D's
 * writeback-all traffic carries the maintenance bit through the arbiters, so
 * the L2 leaves fence.i writebacks out of every event. Walker traffic carries
 * maintenance=0 and counts as ordinary.
 */
module frost_cluster_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
    // Lines above the L2 (every upstream port), and in the L2 and its
    // downstream port.
    parameter int unsigned L1_LINE_BYTES = 32,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Ways per set of the L2 (frost_cache WAYS): a power of 2, 1 for
    // direct-mapped.
    parameter int unsigned L2_WAYS = 4,
    // Bimodal insertion in the L2 (frost_cache BIMODAL_INSERT).
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
    // Simulation-only fast cache maintenance (see frost_cache). Non-zero
    // lets reset bulk-clear the L2's tag array; the L2 takes no fence.i
    // maintenance.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // DMA coherence sequencer lock entries (DMA requests in flight between
    // acceptance and response; the L1D has one probe slot per entry plus the
    // walker's) and the top arbiter's starvation bound in competing grants
    // (0 = pure fixed priority).
    parameter int unsigned NUM_DMA_LOCK = 3,
    parameter int unsigned DMA_STARVATION_LIMIT = 16,
    localparam int unsigned DownIdBits = UP_ID_BITS + 2,
    localparam int unsigned DmaLockBits = (NUM_DMA_LOCK > 1) ? $clog2(NUM_DMA_LOCK) : 1,
    // L1D upstream ids, which carry the probes (frost_hart_cache): a high
    // probe bit above an index that holds the UP_ID_BITS-bit CPU ids and
    // NUM_DMA_LOCK + 1 probe ids.
    localparam int unsigned ProbeIdxBitsMin = $clog2(NUM_DMA_LOCK + 1),
    localparam int unsigned ProbeIdxBits =
        (UP_ID_BITS > ProbeIdxBitsMin) ? UP_ID_BITS : ProbeIdxBitsMin,
    localparam int unsigned L1dIdBits = ProbeIdxBits + 1
) (
    input logic i_clk,
    input logic i_rst,

    // The L1D's downstream line port (slave).
    input  logic                       i_l1d_down_req_valid,
    output logic                       o_l1d_down_req_ready,
    input  logic                       i_l1d_down_req_write,
    input  logic                       i_l1d_down_req_maintenance,
    input  logic [     ADDR_WIDTH-1:0] i_l1d_down_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_l1d_down_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_l1d_down_req_wstrb,
    input  logic [     UP_ID_BITS-1:0] i_l1d_down_req_id,
    output logic                       o_l1d_down_resp_valid,
    output logic [     UP_ID_BITS-1:0] o_l1d_down_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_l1d_down_resp_rdata,
    output logic                       o_l1d_down_resp_error,

    // The L1I's downstream line port (slave), with UP_ID_BITS-1-bit ids.
    input  logic                       i_l1i_down_req_valid,
    output logic                       o_l1i_down_req_ready,
    input  logic                       i_l1i_down_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_l1i_down_req_addr,
    input  logic [L1_LINE_BYTES*8-1:0] i_l1i_down_req_wdata,
    input  logic [  L1_LINE_BYTES-1:0] i_l1i_down_req_wstrb,
    input  logic [     UP_ID_BITS-2:0] i_l1i_down_req_id,
    output logic                       o_l1i_down_resp_valid,
    output logic [     UP_ID_BITS-2:0] o_l1i_down_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_l1i_down_resp_rdata,
    output logic                       o_l1i_down_resp_error,

    // The walker sequencer's line port (slave): reads only, with
    // UP_ID_BITS-1-bit ids.
    input  logic                       i_walk_down_req_valid,
    output logic                       o_walk_down_req_ready,
    input  logic [     ADDR_WIDTH-1:0] i_walk_down_req_addr,
    input  logic [     UP_ID_BITS-2:0] i_walk_down_req_id,
    output logic                       o_walk_down_resp_valid,
    output logic [     UP_ID_BITS-2:0] o_walk_down_resp_id,
    output logic [L1_LINE_BYTES*8-1:0] o_walk_down_resp_rdata,
    output logic                       o_walk_down_resp_error,

    // DMA port: an upstream line-port slave with UP_ID_BITS ids, coherent
    // with the L1D and the load queue (see the header). With L2_PREFETCH,
    // the ids' top bit must be clear.
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

    // The DMA sequencer's probes into the L1D, through the hart's probe
    // injection register (frost_hart_cache): a probe request with its
    // invalidate selector and probe id, the L1D's acknowledgement with its
    // response id, and the release that frees the probe slot.
    output logic                  o_dma_probe_req_valid,
    input  logic                  i_dma_probe_req_ready,
    output logic [ADDR_WIDTH-1:0] o_dma_probe_req_addr,
    output logic                  o_dma_probe_req_inval,
    output logic [ L1dIdBits-1:0] o_dma_probe_req_id,
    input  logic                  i_dma_probe_ack_valid,
    input  logic [ L1dIdBits-1:0] i_dma_probe_ack_id,
    output logic                  o_dma_probe_release_valid,
    output logic [ L1dIdBits-1:0] o_dma_probe_release_id,

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

    // Fatal buffered-store failures in the L2 require external recovery.
    // Read-only refill errors instead return to the matching upstream
    // requester.
    output logic o_fatal_error,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr,

    // Source-registered performance observer of the L2.
    output cache_perf_pkg::cache_instance_perf_events_t o_l2_perf_events
);

  // Walker/L1I local id width under the 2-bit prefix (see the id tree in
  // the header).
  localparam int unsigned WalkIdBits  = UP_ID_BITS - 1;
  // First DMA probe id in the L1D's id space (frost_hart_cache).
  localparam int unsigned ProbeIdBase = 1 << ProbeIdxBits;

  initial begin
    // The id tree needs one prefix bit above the walker/L1I local ids.
    if (UP_ID_BITS < 2) $fatal(1, "frost_cluster_cache: UP_ID_BITS must be >= 2");
    if ((L2_LINE_BYTES < L1_LINE_BYTES) || (L2_LINE_BYTES % L1_LINE_BYTES != 0))
      $fatal(1, "frost_cluster_cache: L2_LINE_BYTES must be a multiple of L1_LINE_BYTES");
  end

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
  logic                       wi_down_resp_error;

  // The top arbiter's downstream into the L2.
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
  logic                       arb_down_resp_error;

  // The DMA sequencer's downstream port into the top arbiter.
  logic dma_down_req_valid, dma_down_req_ready, dma_down_req_write;
  logic [ADDR_WIDTH-1:0] dma_down_req_addr;
  logic [L1_LINE_BYTES*8-1:0] dma_down_req_wdata;
  logic [L1_LINE_BYTES-1:0] dma_down_req_wstrb;
  logic [UP_ID_BITS-1:0] dma_down_req_id;
  logic dma_down_resp_valid;
  logic [UP_ID_BITS-1:0] dma_down_resp_id;
  logic [L1_LINE_BYTES*8-1:0] dma_down_resp_rdata;
  logic dma_down_resp_error;

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
      .o_dma_resp_error(o_dma_resp_error),
      .o_dma_resp_rdata(o_dma_resp_rdata),
      .o_probe_req_valid(o_dma_probe_req_valid),
      .i_probe_req_ready(i_dma_probe_req_ready),
      .o_probe_req_addr(o_dma_probe_req_addr),
      .o_probe_req_inval(o_dma_probe_req_inval),
      .o_probe_req_id(o_dma_probe_req_id),
      .i_probe_ack_valid(i_dma_probe_ack_valid),
      .i_probe_ack_id(i_dma_probe_ack_id),
      .o_probe_release_valid(o_dma_probe_release_valid),
      .o_probe_release_id(o_dma_probe_release_id),
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
      .i_down_resp_error(dma_down_resp_error),
      .i_down_resp_rdata(dma_down_resp_rdata)
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
      .i_up_req_valid({i_l1i_down_req_valid, i_walk_down_req_valid}),
      .o_up_req_ready({o_l1i_down_req_ready, o_walk_down_req_ready}),
      .i_up_req_write({i_l1i_down_req_write, 1'b0}),
      .i_up_req_addr({i_l1i_down_req_addr, i_walk_down_req_addr}),
      .i_up_req_wdata({i_l1i_down_req_wdata, {(L1_LINE_BYTES * 8) {1'b0}}}),
      .i_up_req_wstrb({i_l1i_down_req_wstrb, {L1_LINE_BYTES{1'b0}}}),
      .i_up_req_id({i_l1i_down_req_id, i_walk_down_req_id}),
      .i_up_req_maintenance({1'b0, 1'b0}),
      .o_up_resp_valid({o_l1i_down_resp_valid, o_walk_down_resp_valid}),
      .o_up_resp_id({o_l1i_down_resp_id, o_walk_down_resp_id}),
      .o_up_resp_error({o_l1i_down_resp_error, o_walk_down_resp_error}),
      .o_up_resp_rdata({o_l1i_down_resp_rdata, o_walk_down_resp_rdata}),
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
      .i_down_resp_error(wi_down_resp_error),
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
  logic dp_down_resp_error;
  if (L2_PREFETCH != 0) begin : gen_prefetch
    localparam int unsigned SharedIdBits = UP_ID_BITS - 1;
    logic pf_down_req_valid, pf_down_req_ready;
    logic [ADDR_WIDTH-1:0] pf_down_req_addr;
    logic [SharedIdBits-1:0] pf_down_req_id;
    logic pf_down_resp_valid;
    logic [SharedIdBits-1:0] pf_down_resp_id, dma_shared_resp_id;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [L1_LINE_BYTES*8-1:0] pf_down_resp_rdata;
    logic pf_down_resp_error;
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
        .i_miss_valid(i_l1d_down_req_valid && o_l1d_down_req_ready && !i_l1d_down_req_write),
        .i_miss_addr(i_l1d_down_req_addr),
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
        .o_up_resp_error({pf_down_resp_error, dma_down_resp_error}),
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
        .i_down_resp_error(dp_down_resp_error),
        .i_down_resp_rdata(dp_down_resp_rdata)
    );
    assign dma_down_resp_id = UP_ID_BITS'(dma_shared_resp_id);
`ifndef SYNTHESIS
    always_ff @(posedge i_clk) begin
      if (!i_rst && dma_down_req_valid && dma_down_req_id[UP_ID_BITS-1])
        $error(
            "frost_cluster_cache: DMA id %0d has its top bit set beside the prefetcher",
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
    assign dma_down_resp_error = dp_down_resp_error;
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
      .i_up_req_valid({dp_down_req_valid, wi_down_req_valid, i_l1d_down_req_valid}),
      .o_up_req_ready({dp_down_req_ready, wi_down_req_ready, o_l1d_down_req_ready}),
      .i_up_req_write({dp_down_req_write, wi_down_req_write, i_l1d_down_req_write}),
      .i_up_req_addr({dp_down_req_addr, wi_down_req_addr, i_l1d_down_req_addr}),
      .i_up_req_wdata({dp_down_req_wdata, wi_down_req_wdata, i_l1d_down_req_wdata}),
      .i_up_req_wstrb({dp_down_req_wstrb, wi_down_req_wstrb, i_l1d_down_req_wstrb}),
      .i_up_req_id({dp_down_req_id, wi_down_req_id, i_l1d_down_req_id}),
      .i_up_req_maintenance({1'b0, wi_down_req_maintenance, i_l1d_down_req_maintenance}),
      .o_up_resp_valid({dp_down_resp_valid, wi_down_resp_valid, o_l1d_down_resp_valid}),
      .o_up_resp_id({dp_down_resp_id, wi_down_resp_id, o_l1d_down_resp_id}),
      .o_up_resp_error({dp_down_resp_error, wi_down_resp_error, o_l1d_down_resp_error}),
      .o_up_resp_rdata({dp_down_resp_rdata, wi_down_resp_rdata, o_l1d_down_resp_rdata}),
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
      .i_down_resp_error(arb_down_resp_error),
      .i_down_resp_rdata(arb_down_resp_rdata)
  );

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
  logic                       l2_up_resp_error;

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
    assign arb_down_resp_error = l2_up_resp_error;
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
        .o_up_resp_error(arb_down_resp_error),
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
        .i_down_resp_error(l2_up_resp_error),
        .i_down_resp_rdata(l2_up_resp_rdata)
    );
  end

  frost_cache #(
      .ENABLE_RESPONSE_ERRORS(ENABLE_RESPONSE_ERRORS),
      .ADDR_WIDTH(ADDR_WIDTH),
      .CACHE_SIZE_BYTES(L2_CACHE_BYTES),
      .LINE_BYTES(L2_LINE_BYTES),
      .WAYS(L2_WAYS),
      .BIMODAL_INSERT(L2_BIMODAL_INSERT),
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
      .o_fatal_error(o_fatal_error),
      .o_fatal_addr(o_fatal_addr),
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
      .o_up_resp_error(l2_up_resp_error),
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
      .i_down_resp_error(i_down_resp_error),
      .i_down_resp_rdata(i_down_resp_rdata),
      .o_perf_events(o_l2_perf_events)
  );

`ifndef SYNTHESIS
  // Dump the links if the L1D's port remains refused for 2048 cycles.
  int unsigned down_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(i_l1d_down_req_valid && !o_l1d_down_req_ready)) begin
      down_stall_cnt <= 0;
    end else begin
      down_stall_cnt <= down_stall_cnt + 1;
      if (down_stall_cnt == 2048) begin
        $display("hierarchy DOWNSTREAM STALL: l1d{v=%0d rdy=%0d w=%0d} l1i{v=%0d rdy=%0d w=%0d}",
                 i_l1d_down_req_valid, o_l1d_down_req_ready, i_l1d_down_req_write,
                 i_l1i_down_req_valid, o_l1i_down_req_ready, i_l1i_down_req_write);
        $display("  walk_down{v=%0d rdy=%0d} wi_down{v=%0d rdy=%0d id=%0d}", i_walk_down_req_valid,
                 o_walk_down_req_ready, wi_down_req_valid, wi_down_req_ready, wi_down_req_id);
        $display("  arb_down{v=%0d rdy=%0d w=%0d id=%0d} down_resp{v=%0d id=%0d}",
                 arb_down_req_valid, arb_down_req_ready, arb_down_req_write, arb_down_req_id,
                 arb_down_resp_valid, arb_down_resp_id);
        $error("frost_cluster_cache: data L1 refused downstream for 2048 cycles");
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
            (cover_pf_line_q[k] == i_l1d_down_req_addr[ADDR_WIDTH-1:CoverLineLsb]))
          cover_pf_line_match = 1'b1;
      end
    end
    cover_demand_read_meets_prefetch :
    cover property (@(posedge i_clk) disable iff (i_rst)
        i_l1d_down_req_valid && o_l1d_down_req_ready && !i_l1d_down_req_write &&
        cover_pf_line_match);
  end
`endif
`endif

endmodule : frost_cluster_cache
