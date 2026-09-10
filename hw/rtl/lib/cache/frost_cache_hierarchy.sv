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
 * frost_cache_hierarchy: the configurable cache hierarchy as one module.
 *
 * Instantiates the data-side L1, the instruction-side L1I, the arbiter tree
 * below them, the DMA coherence sequencer, and, when HAS_L2 != 0, L2 (URAM
 * data and tags) behind the arbiters. Four upstream line-port slaves feed one
 * downstream master. wup is the page-table walker's port, uncached at this
 * level; dma is the DMA agent's port, made coherent with the L1D and the
 * load queue by dma_coherence_sequencer before it reaches the shared level.
 *
 *   L1-only (HAS_L2=0):   up  -> L1(BRAM) <-probes-\
 *                         wup -------------\        \
 *                                           arbiter --> arbiter -> down
 *                         iup -> L1I(BRAM) /        /
 *                         dma -> sequencer --------/
 *   L1 + L2 (HAS_L2=1):  the same tree, with L2(URAM) between the top
 *                         arbiter and down.
 *
 * The arbiter tree is a 2:1 sub-arbiter (walker > L1I) under a 3:1 top
 * arbiter (L1D > that pair > DMA), all pure combinational pass-throughs, so
 * the composition behaves like a 4:1 priority arbiter with the order
 * L1D > walker > L1I > DMA: a data miss stalls committed work, a walk
 * unblocks a load that is stalling commit, fetch runs ahead through its
 * buffer, and DMA drains the device's buffers. The top arbiter carries a
 * starvation bound (DMA_STARVATION_LIMIT) so the DMA port keeps a progress
 * guarantee under a sustained stream of CPU-side misses.
 *
 * DMA coherence (Phase 4). The L1D is write-back and the load queue keeps
 * its own dword copies, so a DMA agent below the L1D would neither see the
 * CPU's dirty data nor invalidate the CPU's stale copies. The sequencer
 * (dma_coherence_sequencer.sv, which also states the contract) probes the
 * L1D per line through a mux in front of the L1D's upstream port: the L1D is
 * elaborated with one more upstream id bit than the up port carries, and
 * probes use the ids with that bit set, so the CPU adapter's id space is
 * untouched and probe acknowledgements are steered back by that bit. The
 * probe crosses into the L1D through a register stage, so the CPU adapter's
 * ready and the L1D's request path see flops. For a DMA write the L1D itself
 * withholds fills of the line from the probe's decision until the sequencer
 * releases the probe, after the shared level has accepted the write. The
 * load-queue handshake (admit, inval, release) terminates in the core's
 * lq_coherence_port (tomasulo_wrapper/coherence/); a system without the
 * core-side interface ties admit_ready and inval_done high.
 *
 * L1I and the walker sit above the shared level (L2 or main memory), so data
 * written back from the L1D is visible to instruction fetch and to
 * page-table walks once it reaches that level. fence.i relies on that for
 * code, and sfence.vma's L1D writeback-all relies on it for page-table
 * stores. The L1I is a plain frost_cache used read-only: the instruction
 * side never issues writes, so its dirty/evict logic stays idle. The walker
 * port is a bare line port with no cache in front of it, because walks are
 * short dependent reads that hit the L2 when one exists.
 *
 * Each cache exports a source-registered performance-event bundle. The L1D's
 * writeback-all requests carry passive maintenance provenance through the
 * arbiters into L2, so fence.i traffic is excluded from all ordinary-traffic
 * statistics. Walker traffic carries maintenance=0 and counts as ordinary.
 *
 * Every port speaks the tagged line protocol (hw/rtl/lib/cache/README.md).
 * The id tree is prefix-free within UP_ID_BITS+2 (= DownIdBits) total bits:
 *   L1D    {2'b00, UP_ID_BITS-bit local id}
 *   walker {2'b01, 1'b0, (UP_ID_BITS-1)-bit local id}
 *   L1I    {2'b01, 1'b1, (UP_ID_BITS-1)-bit local id}
 *   DMA    {2'b10, UP_ID_BITS-bit DMA-port id}
 * The upstream up/iup/dma ports keep UP_ID_BITS. The L1I's downstream ids
 * and the wup port carry UP_ID_BITS-1, a 2-slot budget. That is what the L1I
 * is elaborated with, and it suits its master, the two-line fetch provider,
 * which never has more than 2 requests in flight. The walker keeps one walk
 * in flight and ties its id to 0, so its half of the budget is headroom.
 * The DMA port may have up to NUM_DMA_LOCK requests between acceptance and
 * response; the rest wait at the port.
 *
 * The top arbiter's downstream id is one bit wider than the historical
 * two-port shape, so the AXI id the hardware DDR integration provides is
 * 5 bits (fpga/build/x3_ddr_bd.tcl).
 *
 * Both shapes are exercised by the cocotb cache unit tests.
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
    // DMA coherence sequencer: lock entries (DMA requests in flight between
    // acceptance and response, and the L1D's probe slots) and the top
    // arbiter's starvation bound in competing grants (0 = pure fixed priority).
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

    // Upstream line port (slave): page-table walker. No cache in front of
    // it, so requests go straight into the arbiter tree between the L1D and
    // the L1I and read through the shared level. Read-only per the walker
    // contract; the write pins exist for protocol symmetry. Its ids carry
    // UP_ID_BITS-1 bits, the WalkIdBits localparam in the body.
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
    // DMA port (Phase 4): a fourth upstream line-port slave with UP_ID_BITS
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
    // admit fires on ready, inval fires on done, release is a pulse).
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
    // stays high while the request is held). The order is owned here. The
    // data L1 writes back every dirty line first, then the L1I invalidates,
    // so an instruction fill racing the sync can never leave pre-writeback
    // data in a freshly invalidated L1I. The L2 needs no maintenance: it sits
    // below the arbiter, so everything the L1D writes back is already visible
    // to L1I fills.
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
  // one bit wider than the up port; a probe carries {1'b1, entry} and the CPU
  // adapter's request {1'b0, id}. The sequencer's probe is captured into a
  // register stage (one probe at a time; its count is bounded by
  // NUM_DMA_LOCK), which wins the port while it holds one; the adapter holds
  // its request, as the protocol requires, and its ready is qualified by the
  // stage's flop alone. Responses are steered by the top id bit: probe
  // acknowledgements to the sequencer, the rest to the up port. wdata/wstrb
  // need no mux: a probe never writes.
  // ---------------------------------------------------------------------------
  localparam int unsigned L1dIdBits = UP_ID_BITS + 1;
  logic probe_req_valid, probe_req_ready, probe_req_inval;
  logic [ADDR_WIDTH-1:0] probe_req_addr;
  logic [ L1dIdBits-1:0] probe_req_id;
  logic pinj_valid_q, pinj_inval_q;
  logic [ADDR_WIDTH-1:0] pinj_addr_q;
  logic [ L1dIdBits-1:0] pinj_id_q;
  logic l1d_up_req_valid, l1d_up_req_ready, l1d_up_req_write;
  logic [ADDR_WIDTH-1:0] l1d_up_req_addr;
  logic [L1dIdBits-1:0] l1d_up_req_id;
  logic l1d_up_resp_valid;
  logic [L1dIdBits-1:0] l1d_up_resp_id;
  logic probe_ack_valid;
  logic probe_release_valid;
  logic [L1dIdBits-1:0] probe_release_id;
  assign probe_req_ready = !pinj_valid_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pinj_valid_q <= 1'b0;
    end else if (!pinj_valid_q) begin
      if (probe_req_valid) begin
        pinj_valid_q <= 1'b1;
        pinj_addr_q  <= probe_req_addr;
        pinj_inval_q <= probe_req_inval;
        pinj_id_q    <= probe_req_id;
      end
    end else if (l1d_up_req_ready) begin
      pinj_valid_q <= 1'b0;
    end
  end
  assign l1d_up_req_valid = pinj_valid_q || i_up_req_valid;
  assign l1d_up_req_write = !pinj_valid_q && i_up_req_write;
  assign l1d_up_req_addr  = pinj_valid_q ? pinj_addr_q : i_up_req_addr;
  assign l1d_up_req_id    = pinj_valid_q ? pinj_id_q : {1'b0, i_up_req_id};
  assign o_up_req_ready   = l1d_up_req_ready && !pinj_valid_q;
  assign probe_ack_valid  = l1d_up_resp_valid && l1d_up_resp_id[L1dIdBits-1];
  assign o_up_resp_valid  = l1d_up_resp_valid && !l1d_up_resp_id[L1dIdBits-1];
  assign o_up_resp_id     = l1d_up_resp_id[UP_ID_BITS-1:0];

  // The sequencer's downstream port into the top arbiter.
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
      .PROBE_ID_BASE(1 << UP_ID_BITS)
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
      .o_probe_req_valid(probe_req_valid),
      .i_probe_req_ready(probe_req_ready),
      .o_probe_req_addr(probe_req_addr),
      .o_probe_req_inval(probe_req_inval),
      .o_probe_req_id(probe_req_id),
      .i_probe_ack_valid(probe_ack_valid),
      .i_probe_ack_id(l1d_up_resp_id),
      .o_probe_release_valid(probe_release_valid),
      .o_probe_release_id(probe_release_id),
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
      // One more upstream id bit than the up port: probes use the ids with
      // that bit set (see the header), the CPU adapter the ids below.
      .UP_ID_BITS(L1dIdBits),
      .DOWN_ID_BITS(UP_ID_BITS),
      .NUM_PROBE(NUM_DMA_LOCK),
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
      // which caps the miss/writeback slots at 2 each. The fetch provider is
      // a two-line buffer with at most 2 requests in flight, so 2 miss slots
      // lose nothing; the L1I is read-only so its writeback slots stay idle.
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

  // Arbiter tree below the three masters, built from two 2:1 fixed-priority
  // instances whose id prefixes compose to the prefix-free code in the
  // header.
  //
  // Sub-arbiter: walker on port 0 (a walk unblocks a load that is stalling
  // commit), instruction side on port 1 (fetch runs ahead through its
  // buffer). Neither issues maintenance traffic.
  line_port_arbiter #(
      .NUM_PORTS (2),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .UP_ID_BITS(WalkIdBits)
  ) walk_i_arbiter (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_up_req_valid({l1i_down_req_valid, i_wup_req_valid}),
      .o_up_req_ready({l1i_down_req_ready, o_wup_req_ready}),
      .i_up_req_write({l1i_down_req_write, i_wup_req_write}),
      .i_up_req_addr({l1i_down_req_addr, i_wup_req_addr}),
      .i_up_req_wdata({l1i_down_req_wdata, i_wup_req_wdata}),
      .i_up_req_wstrb({l1i_down_req_wstrb, i_wup_req_wstrb}),
      .i_up_req_id({l1i_down_req_id, i_wup_req_id}),
      .i_up_req_maintenance({1'b0, 1'b0}),
      .o_up_resp_valid({l1i_down_resp_valid, o_wup_resp_valid}),
      .o_up_resp_id({l1i_down_resp_id, o_wup_resp_id}),
      .o_up_resp_rdata({l1i_down_resp_rdata, o_wup_resp_rdata}),
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

  // Top arbiter: data side on port 0, which priority favours because its
  // misses stall committed work; the walker/L1I pair on port 1; the DMA
  // sequencer on port 2 with the starvation bound. The L1D's maintenance
  // provenance rides its requests.
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
        // Once started the sequence always completes: the sweeps are not
        // abortable. A requester that vanished mid-way (pipeline flush)
        // finds done already low again on its next request.
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
        // Without this the L2's reset sweep walks all 65,536 tags at boot
        // and refuses upstream traffic for that long. Every simulated boot
        // paid that dead window and no test needs it; the L1s already take
        // the fast path.
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
  // Seam watchdog: the data L1 holding a downstream request unaccepted for
  // this long means the level below wedged. Print every seam so the log alone
  // locates it.
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
        $display("  wup{v=%0d rdy=%0d} wi_down{v=%0d rdy=%0d id=%0d}", i_wup_req_valid,
                 o_wup_req_ready, wi_down_req_valid, wi_down_req_ready, wi_down_req_id);
        $display("  arb_down{v=%0d rdy=%0d w=%0d id=%0d} down_resp{v=%0d id=%0d}",
                 arb_down_req_valid, arb_down_req_ready, arb_down_req_write, arb_down_req_id,
                 arb_down_resp_valid, arb_down_resp_id);
        $error("frost_cache_hierarchy: data L1 refused downstream for 2048 cycles");
      end
    end
  end
`endif

endmodule : frost_cache_hierarchy
