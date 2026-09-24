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
 * (hw/rtl/lib/cache/README.md, "Hierarchy shapes").
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
 * top arbiter adds a starvation bound. It feeds the L2 when HAS_L2 != 0, and
 * the downstream port directly otherwise. The cocotb cache benches cover
 * both shapes.
 *
 * Each arbiter prefixes its port index to the ids it forwards, which gives a
 * prefix-free code in DownIdBits = UP_ID_BITS + 2 bits:
 *   L1D    {2'b00, UP_ID_BITS-bit local id}
 *   walker {2'b01, 1'b0, (UP_ID_BITS-1)-bit local id}
 *   L1I    {2'b01, 1'b1, (UP_ID_BITS-1)-bit local id}
 *   DMA    {2'b10, UP_ID_BITS-bit DMA-port id}
 * The up, iup, and dma ports carry UP_ID_BITS; the wup port and the L1I's
 * downstream carry UP_ID_BITS-1. With the default UP_ID_BITS=3, that leaves
 * the L1I 2 miss slots, all its master (the two-line fetch provider) ever
 * uses, and DownIdBits is 5, the AXI id width of the X3 DDR block design
 * (fpga/build/x3_ddr_bd.tcl). The walker keeps one walk in flight with id 0.
 *
 * Each cache exports a registered performance-event bundle. The L1D's
 * writeback-all traffic carries the maintenance bit through the arbiters, so
 * the L2 leaves fence.i writebacks out of every event except the two stall
 * classes. Walker traffic carries maintenance=0 and counts as ordinary.
 */
module frost_cache_hierarchy #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned UP_ID_BITS = 3,
    parameter int unsigned HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1_DATA_READ_LATENCY = 2,
    parameter int unsigned L1_DATA_WRITE_LATENCY = 1,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1I_DATA_READ_LATENCY = 2,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Total logical latency of the X3 L2's packed URAM tag lookup.
    parameter int unsigned L2_TAG_READ_LATENCY = 3,
    parameter int unsigned L2_DATA_READ_LATENCY = 6,
    parameter int unsigned L2_DATA_WRITE_LATENCY = 2,
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
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [  UP_ID_BITS-1:0] i_up_req_id,
    output logic                    o_up_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_up_resp_id,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Upstream line port (slave): instruction side, used read-only. FROST
    // never issues writes here; wdata/wstrb exist for protocol symmetry.
    input  logic                    i_iup_req_valid,
    output logic                    o_iup_req_ready,
    input  logic                    i_iup_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_iup_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_iup_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_iup_req_wstrb,
    input  logic [  UP_ID_BITS-1:0] i_iup_req_id,
    output logic                    o_iup_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_iup_resp_id,
    output logic [LINE_BYTES*8-1:0] o_iup_resp_rdata,

    // Upstream line port (slave): page-table walker. It has no cache of its
    // own, because walks are short chains of dependent reads that the L2,
    // when present, serves. Each read probes the L1D through
    // walker_coherence_sequencer, then enters the arbiter tree between the
    // L1D and the L1I in priority. Read-only: the write pins exist for
    // protocol symmetry and are ignored (simulation flags a write). Its ids
    // carry UP_ID_BITS-1 bits, the WalkIdBits localparam in the body.
    input  logic                    i_wup_req_valid,
    output logic                    o_wup_req_ready,
    input  logic                    i_wup_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_wup_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_wup_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_wup_req_wstrb,
    input  logic [  UP_ID_BITS-2:0] i_wup_req_id,
    output logic                    o_wup_resp_valid,
    output logic [  UP_ID_BITS-2:0] o_wup_resp_id,
    output logic [LINE_BYTES*8-1:0] o_wup_resp_rdata,
    // DMA port: a fourth upstream line-port slave with UP_ID_BITS
    // ids, coherent with the L1D and the load queue (see the header).
    input  logic                    i_dma_req_valid,
    output logic                    o_dma_req_ready,
    input  logic                    i_dma_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_dma_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_dma_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_dma_req_wstrb,
    input  logic [  UP_ID_BITS-1:0] i_dma_req_id,
    output logic                    o_dma_resp_valid,
    output logic [  UP_ID_BITS-1:0] o_dma_resp_id,
    output logic [LINE_BYTES*8-1:0] o_dma_resp_rdata,
    // Load-queue coherence handshake for DMA writes (dma_coherence_sequencer:
    // admit fires on ready, inval fires on done, release is a pulse). The
    // core's lq_coherence_port (tomasulo_wrapper/coherence/) answers it; a
    // system without that interface ties i_coh_admit_ready and
    // i_coh_inval_done high.
    output logic                    o_coh_admit_valid,
    output logic [ DmaLockBits-1:0] o_coh_admit_slot,
    output logic [  ADDR_WIDTH-1:0] o_coh_admit_addr,
    input  logic                    i_coh_admit_ready,
    output logic                    o_coh_inval_valid,
    output logic [ DmaLockBits-1:0] o_coh_inval_slot,
    input  logic                    i_coh_inval_done,
    output logic                    o_coh_release_valid,
    output logic [ DmaLockBits-1:0] o_coh_release_slot,

    // fence.i cache sync: hold i_fence_sync until o_fence_done rises (done
    // stays high while the request is held). The L1D writes back every dirty
    // line first, then the L1I invalidates, so an instruction fill racing the
    // sync cannot leave pre-writeback data in the freshly invalidated L1I.
    // The L2 needs no maintenance: it sits below both L1s, so everything the
    // L1D writes back is visible to L1I fills.
    input  logic i_fence_sync,
    output logic o_fence_done,

    // Downstream line port (master): to the AXI bridge / main memory.
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [  DownIdBits-1:0] o_down_req_id,
    input  logic                    i_down_resp_valid,
    input  logic [  DownIdBits-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata,

    // Source-registered per-instance performance observers.
    output cache_perf_pkg::cache_hierarchy_perf_events_t o_perf_events
);

  // Walker/L1I local id width under the 2-bit prefix (see the id tree in
  // the header).
  localparam int unsigned WalkIdBits = UP_ID_BITS - 1;

  initial begin
    // The id tree needs one prefix bit above the walker/L1I local ids.
    if (UP_ID_BITS < 2) $fatal(1, "frost_cache_hierarchy: UP_ID_BITS must be >= 2");
  end

  // Per-L1 downstream wires into the arbiter tree, and the top arbiter's
  // downstream (to L2 or straight to the hierarchy's downstream port).
  logic                    l1_down_req_valid;
  logic                    l1_down_req_ready;
  logic                    l1_down_req_write;
  logic                    l1_down_req_maintenance;
  logic [  ADDR_WIDTH-1:0] l1_down_req_addr;
  logic [LINE_BYTES*8-1:0] l1_down_req_wdata;
  logic [  LINE_BYTES-1:0] l1_down_req_wstrb;
  logic [  UP_ID_BITS-1:0] l1_down_req_id;
  logic                    l1_down_resp_valid;
  logic [  UP_ID_BITS-1:0] l1_down_resp_id;
  logic [LINE_BYTES*8-1:0] l1_down_resp_rdata;

  logic                    l1i_down_req_valid;
  logic                    l1i_down_req_ready;
  logic                    l1i_down_req_write;
  logic [  ADDR_WIDTH-1:0] l1i_down_req_addr;
  logic [LINE_BYTES*8-1:0] l1i_down_req_wdata;
  logic [  LINE_BYTES-1:0] l1i_down_req_wstrb;
  logic [  WalkIdBits-1:0] l1i_down_req_id;
  logic                    l1i_down_resp_valid;
  logic [  WalkIdBits-1:0] l1i_down_resp_id;
  logic [LINE_BYTES*8-1:0] l1i_down_resp_rdata;

  // Walker/L1I sub-arbiter downstream (port 1 of the top arbiter).
  logic                    wi_down_req_valid;
  logic                    wi_down_req_ready;
  logic                    wi_down_req_write;
  logic [  ADDR_WIDTH-1:0] wi_down_req_addr;
  logic [LINE_BYTES*8-1:0] wi_down_req_wdata;
  logic [  LINE_BYTES-1:0] wi_down_req_wstrb;
  logic [  UP_ID_BITS-1:0] wi_down_req_id;
  logic                    wi_down_req_maintenance;
  logic                    wi_down_resp_valid;
  logic [  UP_ID_BITS-1:0] wi_down_resp_id;
  logic [LINE_BYTES*8-1:0] wi_down_resp_rdata;

  logic                    arb_down_req_valid;
  logic                    arb_down_req_ready;
  logic                    arb_down_req_write;
  logic [  ADDR_WIDTH-1:0] arb_down_req_addr;
  logic [LINE_BYTES*8-1:0] arb_down_req_wdata;
  logic [  LINE_BYTES-1:0] arb_down_req_wstrb;
  logic [  DownIdBits-1:0] arb_down_req_id;
  logic                    arb_down_req_maintenance;
  logic                    arb_down_resp_valid;
  logic [  DownIdBits-1:0] arb_down_resp_id;
  logic [LINE_BYTES*8-1:0] arb_down_resp_rdata;

  // fence.i sequencer handshakes (FSM below, after the arbiter).
  logic l1d_maint_busy, l1i_maint_busy;
  logic l1d_writeback_req, l1i_invalidate_req;

  // ---------------------------------------------------------------------------
  // Probe injection in front of the L1D's upstream port. The L1D takes ids
  // with one more bit than the up port: a probe carries {1'b1, index}, the
  // CPU adapter's request {1'b0, id}. Index k < NUM_DMA_LOCK is DMA entry k
  // (id ProbeIdBase + k) and index NUM_DMA_LOCK is the walker (WalkProbeId);
  // the index field is UP_ID_BITS wide unless NUM_DMA_LOCK + 1 ids need
  // more. A probe is captured into a one-entry register stage, which takes
  // the port while it holds a probe, so the probe reaches the L1D from flops,
  // the CPU adapter's ready is qualified by the stage's valid flop alone, and
  // the adapter's request waits. The walker wins the stage: with one read in
  // flight it presents at most one probe per round trip, so it cannot starve
  // the DMA entries, which can present back to back. Responses are steered
  // by the top id bit: probe acknowledgements to the sequencer whose id they
  // carry, the rest to the up port. wdata/wstrb need no mux: a probe never
  // writes.
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
  logic [LINE_BYTES*8-1:0] walk_down_resp_rdata;

  walker_coherence_sequencer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
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
  logic [LINE_BYTES*8-1:0] dma_down_req_wdata;
  logic [LINE_BYTES-1:0] dma_down_req_wstrb;
  logic [UP_ID_BITS-1:0] dma_down_req_id;
  logic dma_down_resp_valid;
  logic [UP_ID_BITS-1:0] dma_down_resp_id;
  logic [LINE_BYTES*8-1:0] dma_down_resp_rdata;

  dma_coherence_sequencer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
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
      .LINE_BYTES(LINE_BYTES),
      // At least one more upstream id bit than the up port (L1dIdBits): probes
      // use the ids with the top bit set (see the probe injection above), the
      // CPU adapter the ids below.
      .UP_ID_BITS(L1dIdBits),
      .DOWN_ID_BITS(UP_ID_BITS),
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
      .LINE_BYTES(LINE_BYTES),
      .UP_ID_BITS(UP_ID_BITS),
      // One prefix bit narrower than the L1D (see the id tree in the header),
      // which at the default UP_ID_BITS caps the miss/writeback slots at 2
      // each. The fetch provider is a two-line buffer with at most 2 requests
      // in flight, so 2 miss slots lose nothing; the L1I is read-only so its
      // writeback slots stay idle.
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

  // Arbiter tree: a 2:1 walker/instruction arbiter feeds a 3:1 arbiter
  // shared with data and DMA. Their id prefixes compose to the prefix-free
  // code in the header; the top arbiter also bounds starvation.
  //
  // Sub-arbiter: the walker sequencer on port 0 (a walk unblocks a load that
  // is stalling commit), instruction side on port 1 (fetch runs ahead through
  // its buffer). Neither issues maintenance traffic, and the walker never
  // writes.
  line_port_arbiter #(
      .NUM_PORTS (2),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .UP_ID_BITS(WalkIdBits)
  ) walk_i_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid({l1i_down_req_valid, walk_down_req_valid}),
      .o_up_req_ready({l1i_down_req_ready, walk_down_req_ready}),
      .i_up_req_write({l1i_down_req_write, 1'b0}),
      .i_up_req_addr({l1i_down_req_addr, walk_down_req_addr}),
      .i_up_req_wdata({l1i_down_req_wdata, {(LINE_BYTES * 8) {1'b0}}}),
      .i_up_req_wstrb({l1i_down_req_wstrb, {LINE_BYTES{1'b0}}}),
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

  // Top arbiter: the data side on port 0, first because its misses stall
  // committed work; the walker/L1I pair on port 1; the DMA sequencer on port
  // 2. The starvation bound (DMA_STARVATION_LIMIT) guarantees the DMA port
  // progress under a sustained stream of CPU-side misses. The L1D's
  // maintenance bit rides its requests.
  line_port_arbiter #(
      .NUM_PORTS(3),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .UP_ID_BITS(UP_ID_BITS),
      .STARVATION_LIMIT(DMA_STARVATION_LIMIT)
  ) l1_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid({dma_down_req_valid, wi_down_req_valid, l1_down_req_valid}),
      .o_up_req_ready({dma_down_req_ready, wi_down_req_ready, l1_down_req_ready}),
      .i_up_req_write({dma_down_req_write, wi_down_req_write, l1_down_req_write}),
      .i_up_req_addr({dma_down_req_addr, wi_down_req_addr, l1_down_req_addr}),
      .i_up_req_wdata({dma_down_req_wdata, wi_down_req_wdata, l1_down_req_wdata}),
      .i_up_req_wstrb({dma_down_req_wstrb, wi_down_req_wstrb, l1_down_req_wstrb}),
      .i_up_req_id({dma_down_req_id, wi_down_req_id, l1_down_req_id}),
      .i_up_req_maintenance({1'b0, wi_down_req_maintenance, l1_down_req_maintenance}),
      .o_up_resp_valid({dma_down_resp_valid, wi_down_resp_valid, l1_down_resp_valid}),
      .o_up_resp_id({dma_down_resp_id, wi_down_resp_id, l1_down_resp_id}),
      .o_up_resp_rdata({dma_down_resp_rdata, wi_down_resp_rdata, l1_down_resp_rdata}),
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

  assign l1d_writeback_req = (fence_state_q == FENCE_L1D_REQ);
  assign l1i_invalidate_req = (fence_state_q == FENCE_L1I_REQ);
  assign o_fence_done = (fence_state_q == FENCE_DONE);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fence_state_q <= FENCE_IDLE;
    end else begin
      unique case (fence_state_q)
        FENCE_IDLE:     if (i_fence_sync) fence_state_q <= FENCE_L1D_REQ;
        FENCE_L1D_REQ:  if (l1d_maint_busy) fence_state_q <= FENCE_L1D_WAIT;
        FENCE_L1D_WAIT: if (!l1d_maint_busy) fence_state_q <= FENCE_L1I_REQ;
        FENCE_L1I_REQ:  if (l1i_maint_busy) fence_state_q <= FENCE_L1I_WAIT;
        FENCE_L1I_WAIT: if (!l1i_maint_busy) fence_state_q <= FENCE_DONE;
        // Once started the sequence always completes: the sweeps cannot be
        // aborted. If the requester drops i_fence_sync mid-sequence (a full
        // flush), the sequence still finishes, raises done for one cycle, and
        // returns to idle; a request raised again before then is answered by
        // the sequence already running.
        FENCE_DONE:     if (!i_fence_sync) fence_state_q <= FENCE_IDLE;
        default:        fence_state_q <= FENCE_IDLE;
      endcase
    end
  end

  if (HAS_L2 != 0) begin : gen_l2
    frost_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_SIZE_BYTES(L2_CACHE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .UP_ID_BITS(DownIdBits),
        .DOWN_ID_BITS(DownIdBits),
        .TAG_MEMORY_PRIMITIVE("ultra"),
        .TAG_READ_LATENCY(L2_TAG_READ_LATENCY),
        .DATA_MEMORY_PRIMITIVE("ultra"),
        .DATA_READ_LATENCY(L2_DATA_READ_LATENCY),
        .DATA_WRITE_LATENCY(L2_DATA_WRITE_LATENCY),
        // With SIM_FAST_MAINT the L2's reset sweep takes one cycle. The full
        // sweep walks every tag (65,536 at 2 MiB) and refuses upstream
        // traffic meanwhile, which no test needs.
        .SIM_FAST_MAINT(SIM_FAST_MAINT)
    ) l2_cache (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_writeback_all(1'b0),
        .i_invalidate_all(1'b0),
        .o_maint_busy(),
        .i_up_req_valid(arb_down_req_valid),
        .o_up_req_ready(arb_down_req_ready),
        .i_up_req_write(arb_down_req_write),
        .i_up_req_addr(arb_down_req_addr),
        .i_up_req_wdata(arb_down_req_wdata),
        .i_up_req_wstrb(arb_down_req_wstrb),
        .i_up_req_id(arb_down_req_id),
        // Provenance muxed per fire by the arbiter.
        .i_up_req_maintenance(arb_down_req_maintenance),
        .i_up_req_probe(1'b0),
        .i_up_req_probe_inval(1'b0),
        .i_probe_release_valid(1'b0),
        .i_probe_release_id('0),
        .o_up_resp_valid(arb_down_resp_valid),
        .o_up_resp_id(arb_down_resp_id),
        .o_up_resp_rdata(arb_down_resp_rdata),
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
  end else begin : gen_no_l2
    // Generate-time tie-off: in the optional L1-only topology, the L2 observer
    // bundle is a hard zero rather than a runtime mux or X source.
    assign l2_perf_events      = '0;
    assign o_down_req_valid    = arb_down_req_valid;
    assign arb_down_req_ready  = i_down_req_ready;
    assign o_down_req_write    = arb_down_req_write;
    assign o_down_req_addr     = arb_down_req_addr;
    assign o_down_req_wdata    = arb_down_req_wdata;
    assign o_down_req_wstrb    = arb_down_req_wstrb;
    assign o_down_req_id       = arb_down_req_id;
    assign arb_down_resp_valid = i_down_resp_valid;
    assign arb_down_resp_id    = i_down_resp_id;
    assign arb_down_resp_rdata = i_down_resp_rdata;
  end

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

  // Downstream watchdog: the L1D holding a downstream request unaccepted for
  // this long means the level below has wedged. Print the L1, walker, and
  // arbiter links so the log alone locates it.
  int unsigned seam_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(l1_down_req_valid && !l1_down_req_ready)) begin
      seam_stall_cnt <= 0;
    end else begin
      seam_stall_cnt <= seam_stall_cnt + 1;
      if (seam_stall_cnt == 2048) begin
        $display("hierarchy SEAM STALL: l1d{v=%0d rdy=%0d w=%0d} l1i{v=%0d rdy=%0d w=%0d}",
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

endmodule : frost_cache_hierarchy
