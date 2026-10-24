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

// The memory side shared below a hart: the shared cache level
// (frost_cluster_cache) with its DMA sequencer and the coherent ingress
// register in front of it, and cpu_memory_fabric with its AXI master, which
// combines the L2's line traffic with the hart's uncached data and
// instruction requests. cpu_top composes it with frost_hart. See
// cpu_top/README.md.
module frost_cluster_memory #(
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter bit ENABLE_COHERENCE = 1'b0,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned L2_WAYS = 4,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    parameter int unsigned L2_NUM_WAITERS = 2,
    parameter int unsigned L2_PREFETCH = 1,
    parameter int unsigned L2_PREFETCH_DISTANCE = 8,
    parameter int unsigned L2_PREFETCH_INFLIGHT = 4,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned SIM_FAST_MAINT = 0,
    // The hart's uncached instruction fetch block (cpu_memory_fabric
    // FETCH_BYTES).
    parameter int unsigned FETCH_BYTES = 8,
    parameter int unsigned AXI_ID_BITS = 6,
    parameter int unsigned AXI_USER_BITS = 1,
    parameter logic [2:0] AXI_MEMORY_PROT = 3'b011,
    // Line ports from the hart: 32-byte lines and 4-bit ids.
    localparam int unsigned L1LineBytes = 32,
    localparam int unsigned LineIdBits = 4,
    // L1D upstream ids, which carry the DMA probes (frost_hart_cache).
    localparam int unsigned ProbeIdxBitsMin = $clog2(riscv_pkg::DmaCoherenceLocks + 1),
    localparam int unsigned ProbeIdxBits =
        (LineIdBits > ProbeIdxBitsMin) ? LineIdBits : ProbeIdxBitsMin,
    localparam int unsigned L1dIdBits = ProbeIdxBits + 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axi_rst,
    // The tile's sticky fatal indication: the coherent ingress accepts and
    // presents nothing while it is set.
    input logic i_fatal_error,

    // Coherent ingress (cpu_top's i_coherent_req_* / o_coherent_resp_*).
    input logic i_coherent_req_valid,
    output logic o_coherent_req_ready,
    input logic i_coherent_req_write,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_coherent_req_addr,
    input logic [L1LineBytes*8-1:0] i_coherent_req_wdata,
    input logic [L1LineBytes-1:0] i_coherent_req_wstrb,
    input logic [LineIdBits-1:0] i_coherent_req_id,
    output logic o_coherent_resp_valid,
    output logic [LineIdBits-1:0] o_coherent_resp_id,
    output logic [L1LineBytes*8-1:0] o_coherent_resp_rdata,
    output logic o_coherent_resp_error,

    // The hart's L1D downstream line port (slave).
    input logic i_l1d_down_req_valid,
    output logic o_l1d_down_req_ready,
    input logic i_l1d_down_req_write,
    input logic i_l1d_down_req_maintenance,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_l1d_down_req_addr,
    input logic [L1LineBytes*8-1:0] i_l1d_down_req_wdata,
    input logic [L1LineBytes-1:0] i_l1d_down_req_wstrb,
    input logic [LineIdBits-1:0] i_l1d_down_req_id,
    output logic o_l1d_down_resp_valid,
    output logic [LineIdBits-1:0] o_l1d_down_resp_id,
    output logic [L1LineBytes*8-1:0] o_l1d_down_resp_rdata,
    output logic o_l1d_down_resp_error,

    // The hart's L1I downstream line port (slave).
    input logic i_l1i_down_req_valid,
    output logic o_l1i_down_req_ready,
    input logic i_l1i_down_req_write,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_l1i_down_req_addr,
    input logic [L1LineBytes*8-1:0] i_l1i_down_req_wdata,
    input logic [L1LineBytes-1:0] i_l1i_down_req_wstrb,
    input logic [LineIdBits-2:0] i_l1i_down_req_id,
    output logic o_l1i_down_resp_valid,
    output logic [LineIdBits-2:0] o_l1i_down_resp_id,
    output logic [L1LineBytes*8-1:0] o_l1i_down_resp_rdata,
    output logic o_l1i_down_resp_error,

    // The hart's walker sequencer line port (slave).
    input logic i_walk_down_req_valid,
    output logic o_walk_down_req_ready,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_walk_down_req_addr,
    input logic [LineIdBits-2:0] i_walk_down_req_id,
    output logic o_walk_down_resp_valid,
    output logic [LineIdBits-2:0] o_walk_down_resp_id,
    output logic [L1LineBytes*8-1:0] o_walk_down_resp_rdata,
    output logic o_walk_down_resp_error,

    // The DMA sequencer's probes into the hart's L1D.
    output logic o_dma_probe_req_valid,
    input logic i_dma_probe_req_ready,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_dma_probe_req_addr,
    output logic o_dma_probe_req_inval,
    output logic [L1dIdBits-1:0] o_dma_probe_req_id,
    input logic i_dma_probe_ack_valid,
    input logic [L1dIdBits-1:0] i_dma_probe_ack_id,
    output logic o_dma_probe_release_valid,
    output logic [L1dIdBits-1:0] o_dma_probe_release_id,

    // Load-queue coherence handshake for DMA writes, to the hart.
    output logic o_coh_admit_valid,
    output logic [riscv_pkg::DmaCoherenceLockBits-1:0] o_coh_admit_slot,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_coh_admit_addr,
    input logic i_coh_admit_ready,
    output logic o_coh_inval_valid,
    output logic [riscv_pkg::DmaCoherenceLockBits-1:0] o_coh_inval_slot,
    input logic i_coh_inval_done,
    output logic o_coh_release_valid,
    output logic [riscv_pkg::DmaCoherenceLockBits-1:0] o_coh_release_slot,

    // The hart's uncached and Device data requests.
    input logic i_data_req_valid,
    output logic o_data_req_ready,
    input logic i_data_req_write,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_data_req_addr,
    input logic [2:0] i_data_req_size,
    input logic [3:0] i_data_req_cache,
    input logic [2:0] i_data_req_prot,
    input logic [L2_LINE_BYTES*8-1:0] i_data_req_wdata,
    input logic [L2_LINE_BYTES-1:0] i_data_req_wstrb,
    output logic o_data_resp_valid,
    output logic [L2_LINE_BYTES*8-1:0] o_data_resp_data,
    output logic [1:0] o_data_resp_status,
    output logic o_data_resp_ok,

    // The hart's uncached instruction fetch requests.
    input logic i_fetch_req_valid,
    output logic o_fetch_req_ready,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_fetch_req_addr,
    input logic i_fetch_req_id,
    output logic o_fetch_resp_valid,
    output logic o_fetch_resp_id,
    output logic [FETCH_BYTES*8-1:0] o_fetch_resp_data,
    output logic o_fetch_resp_error,

    // Fatal buffered-store failures in the L2, and its source-registered
    // performance observers.
    output logic o_cache_fatal,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_cache_fatal_addr,
    output cache_perf_pkg::cache_instance_perf_events_t o_l2_perf_events,
    output cache_perf_pkg::cache_write_perf_events_t o_l2_write_perf_events,

    // Outgoing AXI4 master (cpu_top's o_axi_* / i_axi_*).
    output logic o_axi_idle,
    output logic o_axi_awvalid,
    input logic i_axi_awready,
    output logic [AXI_ID_BITS-1:0] o_axi_awid,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_axi_awaddr,
    output logic [7:0] o_axi_awlen,
    output logic [2:0] o_axi_awsize,
    output logic [1:0] o_axi_awburst,
    output logic o_axi_awlock,
    output logic [3:0] o_axi_awcache,
    output logic [2:0] o_axi_awprot,
    output logic [3:0] o_axi_awqos,
    output logic [3:0] o_axi_awregion,
    output logic [AXI_USER_BITS-1:0] o_axi_awuser,
    output logic o_axi_wvalid,
    input logic i_axi_wready,
    output logic [L2_LINE_BYTES*8-1:0] o_axi_wdata,
    output logic [L2_LINE_BYTES-1:0] o_axi_wstrb,
    output logic o_axi_wlast,
    output logic [AXI_USER_BITS-1:0] o_axi_wuser,
    input logic i_axi_bvalid,
    output logic o_axi_bready,
    input logic [AXI_ID_BITS-1:0] i_axi_bid,
    input logic [1:0] i_axi_bresp,
    input logic [AXI_USER_BITS-1:0] i_axi_buser,
    output logic o_axi_arvalid,
    input logic i_axi_arready,
    output logic [AXI_ID_BITS-1:0] o_axi_arid,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_axi_araddr,
    output logic [7:0] o_axi_arlen,
    output logic [2:0] o_axi_arsize,
    output logic [1:0] o_axi_arburst,
    output logic o_axi_arlock,
    output logic [3:0] o_axi_arcache,
    output logic [2:0] o_axi_arprot,
    output logic [3:0] o_axi_arqos,
    output logic [3:0] o_axi_arregion,
    output logic [AXI_USER_BITS-1:0] o_axi_aruser,
    input logic i_axi_rvalid,
    output logic o_axi_rready,
    input logic [AXI_ID_BITS-1:0] i_axi_rid,
    input logic [L2_LINE_BYTES*8-1:0] i_axi_rdata,
    input logic [1:0] i_axi_rresp,
    input logic i_axi_rlast,
    input logic [AXI_USER_BITS-1:0] i_axi_ruser
);
  localparam int unsigned DdrAxiIdBits = 5;

  logic dma_req_ready, dma_resp_valid, dma_resp_error;
  logic [LineIdBits-1:0] dma_resp_id;
  logic [L1LineBytes*8-1:0] dma_resp_rdata;
  wire coherent_address_ok = riscv_pkg::pma_cached_ok(
      riscv_pkg::XLEN'(i_coherent_req_addr)
  ) && i_coherent_req_addr[4:0] == 0;
  // Register ingress ownership before the shared level's same-line checks.
  // This separates a wrapper's arbitration/address mux from the cache
  // admission path, while permitting dequeue and replacement on one edge.
  logic coherent_pending_q;
  logic dma_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] dma_req_addr;
  logic [L1LineBytes*8-1:0] dma_req_wdata;
  logic [L1LineBytes-1:0] dma_req_wstrb;
  logic [LineIdBits-1:0] dma_req_id;
  wire dma_req_valid = ENABLE_COHERENCE && !i_rst && !i_fatal_error && coherent_pending_q;
  assign o_coherent_req_ready = ENABLE_COHERENCE && (ENABLE_CACHED_TIER != 0) &&
      !i_rst && !i_fatal_error && coherent_address_ok &&
      (!coherent_pending_q || dma_req_ready);
  always_ff @(posedge i_clk) begin
    if (i_rst) coherent_pending_q <= 1'b0;
    else begin
      if (dma_req_valid && dma_req_ready) coherent_pending_q <= 1'b0;
      if (i_coherent_req_valid && o_coherent_req_ready) begin
        coherent_pending_q <= 1'b1;
        dma_req_write <= i_coherent_req_write;
        dma_req_addr <= i_coherent_req_addr;
        dma_req_wdata <= i_coherent_req_wdata;
        dma_req_wstrb <= i_coherent_req_wstrb;
        dma_req_id <= i_coherent_req_id;
      end
    end
  end
  assign o_coherent_resp_valid = ENABLE_COHERENCE && dma_resp_valid;
  assign o_coherent_resp_id = ENABLE_COHERENCE ? dma_resp_id : '0;
  assign o_coherent_resp_rdata = ENABLE_COHERENCE ? dma_resp_rdata : '0;
  assign o_coherent_resp_error = ENABLE_COHERENCE && dma_resp_error;
  logic down_req_valid, down_req_ready, down_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] down_req_addr;
  logic [L2_LINE_BYTES*8-1:0] down_req_wdata;
  logic [L2_LINE_BYTES-1:0] down_req_wstrb;
  logic [DdrAxiIdBits-1:0] down_req_id;
  logic down_resp_valid, down_resp_error;
  logic [DdrAxiIdBits-1:0] down_resp_id;
  logic [L2_LINE_BYTES*8-1:0] down_resp_rdata;

  if (ENABLE_CACHED_TIER != 0) begin : gen_cached_tier
    frost_cluster_cache #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .ENABLE_RESPONSE_ERRORS(1'b1),
        .L1_LINE_BYTES(L1LineBytes),
        .L2_LINE_BYTES(L2_LINE_BYTES),
        .UP_ID_BITS(LineIdBits),
        .L2_CACHE_BYTES(L2_CACHE_BYTES),
        .L2_WAYS(L2_WAYS),
        .L2_NUM_MSHR(L2_NUM_MSHR),
        .L2_NUM_WAITERS(L2_NUM_WAITERS),
        .L2_PREFETCH(L2_PREFETCH),
        .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
        .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
        .L2_NUM_WB(L2_NUM_WB),
        .L2_DOWN_ID_BITS(DdrAxiIdBits),
        .SIM_FAST_MAINT(SIM_FAST_MAINT),
        .NUM_DMA_LOCK(riscv_pkg::DmaCoherenceLocks)
    ) cluster_cache (
        .o_dma_resp_error(dma_resp_error),
        .o_fatal_error(o_cache_fatal),
        .o_fatal_addr(o_cache_fatal_addr),

        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_l1d_down_req_valid(i_l1d_down_req_valid),
        .o_l1d_down_req_ready(o_l1d_down_req_ready),
        .i_l1d_down_req_write(i_l1d_down_req_write),
        .i_l1d_down_req_maintenance(i_l1d_down_req_maintenance),
        .i_l1d_down_req_addr(i_l1d_down_req_addr),
        .i_l1d_down_req_wdata(i_l1d_down_req_wdata),
        .i_l1d_down_req_wstrb(i_l1d_down_req_wstrb),
        .i_l1d_down_req_id(i_l1d_down_req_id),
        .o_l1d_down_resp_valid(o_l1d_down_resp_valid),
        .o_l1d_down_resp_id(o_l1d_down_resp_id),
        .o_l1d_down_resp_rdata(o_l1d_down_resp_rdata),
        .o_l1d_down_resp_error(o_l1d_down_resp_error),
        .i_l1i_down_req_valid(i_l1i_down_req_valid),
        .o_l1i_down_req_ready(o_l1i_down_req_ready),
        .i_l1i_down_req_write(i_l1i_down_req_write),
        .i_l1i_down_req_addr(i_l1i_down_req_addr),
        .i_l1i_down_req_wdata(i_l1i_down_req_wdata),
        .i_l1i_down_req_wstrb(i_l1i_down_req_wstrb),
        .i_l1i_down_req_id(i_l1i_down_req_id),
        .o_l1i_down_resp_valid(o_l1i_down_resp_valid),
        .o_l1i_down_resp_id(o_l1i_down_resp_id),
        .o_l1i_down_resp_rdata(o_l1i_down_resp_rdata),
        .o_l1i_down_resp_error(o_l1i_down_resp_error),
        .i_walk_down_req_valid(i_walk_down_req_valid),
        .o_walk_down_req_ready(o_walk_down_req_ready),
        .i_walk_down_req_addr(i_walk_down_req_addr),
        .i_walk_down_req_id(i_walk_down_req_id),
        .o_walk_down_resp_valid(o_walk_down_resp_valid),
        .o_walk_down_resp_id(o_walk_down_resp_id),
        .o_walk_down_resp_rdata(o_walk_down_resp_rdata),
        .o_walk_down_resp_error(o_walk_down_resp_error),
        // DMA port: the NIC and the DMA test engine through the ingress
        // register above. The coherence handshake runs to the hart's
        // lq_coherence_port, and the probes to its L1D.
        .i_dma_req_valid(dma_req_valid),
        .o_dma_req_ready(dma_req_ready),
        .i_dma_req_write(dma_req_write),
        .i_dma_req_addr(dma_req_addr),
        .i_dma_req_wdata(dma_req_wdata),
        .i_dma_req_wstrb(dma_req_wstrb),
        .i_dma_req_id(dma_req_id),
        .o_dma_resp_valid(dma_resp_valid),
        .o_dma_resp_id(dma_resp_id),
        .o_dma_resp_rdata(dma_resp_rdata),
        .o_coh_admit_valid(o_coh_admit_valid),
        .o_coh_admit_slot(o_coh_admit_slot),
        .o_coh_admit_addr(o_coh_admit_addr),
        .i_coh_admit_ready(i_coh_admit_ready),
        .o_coh_inval_valid(o_coh_inval_valid),
        .o_coh_inval_slot(o_coh_inval_slot),
        .i_coh_inval_done(i_coh_inval_done),
        .o_coh_release_valid(o_coh_release_valid),
        .o_coh_release_slot(o_coh_release_slot),
        .o_dma_probe_req_valid(o_dma_probe_req_valid),
        .i_dma_probe_req_ready(i_dma_probe_req_ready),
        .o_dma_probe_req_addr(o_dma_probe_req_addr),
        .o_dma_probe_req_inval(o_dma_probe_req_inval),
        .o_dma_probe_req_id(o_dma_probe_req_id),
        .i_dma_probe_ack_valid(i_dma_probe_ack_valid),
        .i_dma_probe_ack_id(i_dma_probe_ack_id),
        .o_dma_probe_release_valid(o_dma_probe_release_valid),
        .o_dma_probe_release_id(o_dma_probe_release_id),
        .o_l2_perf_events(o_l2_perf_events),
        .o_l2_write_perf_events(o_l2_write_perf_events),
        .o_down_req_valid(down_req_valid),
        .i_down_req_ready(down_req_ready),
        .o_down_req_write(down_req_write),
        .o_down_req_addr(down_req_addr),
        .o_down_req_wdata(down_req_wdata),
        .o_down_req_wstrb(down_req_wstrb),
        .o_down_req_id(down_req_id),
        .i_down_resp_valid(down_resp_valid),
        .i_down_resp_id(down_resp_id),
        .i_down_resp_rdata(down_resp_rdata),
        .i_down_resp_error(down_resp_error)
    );


  end else begin : gen_no_cached_tier
    assign o_cache_fatal = 1'b0;
    assign o_cache_fatal_addr = '0;
    assign o_l2_perf_events = '0;
    assign o_l2_write_perf_events = '0;
    assign dma_req_ready = 1'b0;
    assign dma_resp_valid = 1'b0;
    assign dma_resp_id = '0;
    assign dma_resp_rdata = '0;
    assign dma_resp_error = 1'b0;
    assign o_coh_admit_valid = 1'b0;
    assign o_coh_admit_slot = '0;
    assign o_coh_admit_addr = '0;
    assign o_coh_inval_valid = 1'b0;
    assign o_coh_inval_slot = '0;
    assign o_coh_release_valid = 1'b0;
    assign o_coh_release_slot = '0;
    assign o_dma_probe_req_valid = 1'b0;
    assign o_dma_probe_req_addr = '0;
    assign o_dma_probe_req_inval = 1'b0;
    assign o_dma_probe_req_id = '0;
    assign o_dma_probe_release_valid = 1'b0;
    assign o_dma_probe_release_id = '0;
    assign o_l1d_down_req_ready = 1'b0;
    assign o_l1d_down_resp_valid = 1'b0;
    assign o_l1d_down_resp_id = '0;
    assign o_l1d_down_resp_rdata = '0;
    assign o_l1d_down_resp_error = 1'b0;
    assign o_l1i_down_req_ready = 1'b0;
    assign o_l1i_down_resp_valid = 1'b0;
    assign o_l1i_down_resp_id = '0;
    assign o_l1i_down_resp_rdata = '0;
    assign o_l1i_down_resp_error = 1'b0;
    assign o_walk_down_req_ready = 1'b0;
    assign o_walk_down_resp_valid = 1'b0;
    assign o_walk_down_resp_id = '0;
    assign o_walk_down_resp_rdata = '0;
    assign o_walk_down_resp_error = 1'b0;
    assign down_req_valid = 1'b0;
    assign down_req_write = 1'b0;
    assign down_req_addr = '0;
    assign down_req_wdata = '0;
    assign down_req_wstrb = '0;
    assign down_req_id = '0;
  end

  cpu_memory_fabric #(
      .FETCH_BYTES(FETCH_BYTES),
      .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
      .DATA_BYTES(L2_LINE_BYTES),
      .ID_BITS(AXI_ID_BITS),
      .USER_BITS(AXI_USER_BITS),
      .MEMORY_PROT(AXI_MEMORY_PROT)
  ) memory_fabric (
      .i_clk,
      .i_rst,
      .i_axi_rst,
      .i_cache_valid(down_req_valid),
      .o_cache_ready(down_req_ready),
      .i_cache_write(down_req_write),
      .i_cache_addr(down_req_addr),
      .i_cache_wdata(down_req_wdata),
      .i_cache_wstrb(down_req_wstrb),
      .i_cache_id(down_req_id),
      .o_cache_resp_valid(down_resp_valid),
      .o_cache_resp_id(down_resp_id),
      .o_cache_resp_data(down_resp_rdata),
      .o_cache_resp_error(down_resp_error),
      .i_data_valid(i_data_req_valid),
      .o_data_ready(o_data_req_ready),
      .i_data_write(i_data_req_write),
      .i_data_addr(i_data_req_addr),
      .i_data_size(i_data_req_size),
      .i_data_cache(i_data_req_cache),
      .i_data_prot(i_data_req_prot),
      .i_data_wdata(i_data_req_wdata),
      .i_data_wstrb(i_data_req_wstrb),
      .o_data_resp_valid(o_data_resp_valid),
      .o_data_resp_data(o_data_resp_data),
      .o_data_resp_status(o_data_resp_status),
      .o_data_resp_ok(o_data_resp_ok),
      .i_fetch_valid(i_fetch_req_valid),
      .o_fetch_ready(o_fetch_req_ready),
      .i_fetch_addr(i_fetch_req_addr),
      .i_fetch_id(i_fetch_req_id),
      .o_fetch_resp_valid(o_fetch_resp_valid),
      .o_fetch_resp_id(o_fetch_resp_id),
      .o_fetch_resp_data(o_fetch_resp_data),
      .o_fetch_resp_error(o_fetch_resp_error),
      .o_idle(o_axi_idle),
      .o_axi_awvalid,
      .i_axi_awready,
      .o_axi_awid,
      .o_axi_awaddr,
      .o_axi_awlen,
      .o_axi_awsize,
      .o_axi_awburst,
      .o_axi_awlock,
      .o_axi_awcache,
      .o_axi_awprot,
      .o_axi_awqos,
      .o_axi_awregion,
      .o_axi_awuser,
      .o_axi_wvalid,
      .i_axi_wready,
      .o_axi_wdata,
      .o_axi_wstrb,
      .o_axi_wlast,
      .o_axi_wuser,
      .i_axi_bvalid,
      .o_axi_bready,
      .i_axi_bid,
      .i_axi_bresp,
      .i_axi_buser,
      .o_axi_arvalid,
      .i_axi_arready,
      .o_axi_arid,
      .o_axi_araddr,
      .o_axi_arlen,
      .o_axi_arsize,
      .o_axi_arburst,
      .o_axi_arlock,
      .o_axi_arcache,
      .o_axi_arprot,
      .o_axi_arqos,
      .o_axi_arregion,
      .o_axi_aruser,
      .i_axi_rvalid,
      .o_axi_rready,
      .i_axi_rid,
      .i_axi_rdata,
      .i_axi_rresp,
      .i_axi_rlast,
      .i_axi_ruser
  );
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst && ENABLE_COHERENCE && i_coherent_req_valid)
      assert (coherent_address_ok)
      else $error("frost_cluster_memory: coherent request outside cached memory");
  end
`endif
endmodule
