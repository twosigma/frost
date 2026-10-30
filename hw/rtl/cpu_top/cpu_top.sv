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

// Reusable CPU tile. See cpu_top/README.md for reset, AXI, PMA, and coherence.
// Board memory, debug transport, the APLIC, and DMA agents belong to the SoC.
// The hart owns its machine and supervisor IMSIC files. The tile composes one
// frost_hart with frost_cluster_memory, which holds the shared L2 and the AXI
// master; it latches the fatal indication and assembles the cache performance
// events for the hart's counters.
module cpu_top #(
    // Optional private Normal-memory read caches and buffered write-through
    // stores. Device accesses retain precise, narrow AXI completion.
    parameter bit CACHE_NORMAL_MEMORY = 1'b0,
    parameter int unsigned NORMAL_FETCH_LINES = 256,
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned L0_CACHE_DEPTH = CACHE_NORMAL_MEMORY ?
        riscv_pkg::NormalLqL0Depth : riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned L2_WAYS = 4,
    parameter int unsigned L1D_NUM_MSHR = 8,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    parameter int unsigned L2_NUM_WAITERS = 2,
    parameter int unsigned L2_PREFETCH = 1,
    parameter int unsigned L2_PREFETCH_DISTANCE = 8,
    parameter int unsigned L2_PREFETCH_INFLIGHT = 4,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned SIM_FAST_MAINT = 0,
    parameter int unsigned PERF_COUNTERS = 0,
    parameter bit ENABLE_COHERENCE = 1'b0,
    parameter int unsigned AXI_ID_BITS = 6,
    parameter int unsigned AXI_USER_BITS = 1,
    parameter logic [2:0] AXI_MEMORY_PROT = 3'b011
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axi_rst,
    input logic [riscv_pkg::XLEN-1:0] i_boot_addr,
    input riscv_pkg::interrupt_t i_interrupts,
    input logic i_seip,
    // One MSI per cycle; level 0 is machine, level 1 supervisor.
    input logic i_msi_valid = 1'b0,
    input logic i_msi_level = 1'b0,
    input logic [10:0] i_msi_id = '0,
    input logic [63:0] i_mtime,
    input logic i_disable_branch_prediction = 1'b0,
    input logic i_dbg_haltreq = 1'b0,
    input logic i_dbg_go = 1'b0,
    input logic [31:0] i_dbg_go_addr = '0,
    input logic [63:0] i_dbg_data = '0,
    output logic o_dbg_data_we,
    output logic [63:0] o_dbg_data_wdata,
    output logic o_debug_mode,
    output logic o_dbg_parked,
    output logic o_dbg_cmd_err,
    output logic o_dbg_go_taken,
    output logic o_rst_done,
    output logic o_commit_valid,
    output logic [5:0] o_debug_irq_status,
    output logic [riscv_pkg::XLEN-1:0] o_debug_commit_pc,
    output logic [riscv_pkg::XLEN-1:0] o_debug_commit_2_pc,
    output logic [1:0] o_debug_commit_valid,
    output logic o_fatal_error,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fatal_addr,
    output logic o_axi_idle,
    // Optional FROST line-coherence port. All inputs may be zero when disabled.
    input logic i_coherent_req_valid = 1'b0,
    output logic o_coherent_req_ready,
    input logic i_coherent_req_write = 1'b0,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_coherent_req_addr = '0,
    input logic [255:0] i_coherent_req_wdata = '0,
    input logic [31:0] i_coherent_req_wstrb = '0,
    input logic [3:0] i_coherent_req_id = '0,
    output logic o_coherent_resp_valid,
    output logic [3:0] o_coherent_resp_id,
    output logic [255:0] o_coherent_resp_rdata,
    output logic o_coherent_resp_error,
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
  function automatic logic regions_overlap(
      input longint unsigned base_a, input longint unsigned size_a, input longint unsigned base_b,
      input longint unsigned size_b);
    regions_overlap = size_a != 0 && size_b != 0 &&
        base_a < base_b + size_b && base_b < base_a + size_a;
  endfunction

  initial begin
    if (riscv_pkg::PhysAddrBits > 56)
      $fatal(1, "cpu_top: configured physical address width exceeds the Sv39 PTE format");
    if (L2_LINE_BYTES != 32 && L2_LINE_BYTES != 64)
      $fatal(1, "cpu_top: supported L2/AXI beat sizes are 32 and 64 bytes");
    if ((riscv_pkg::DdrBase & 4095) != 0 ||
        (riscv_pkg::PmaUncachedBase & 4095) != 0 ||
        (riscv_pkg::PmaUncachedBytes & 4095) != 0 ||
        (riscv_pkg::PmaUncachedExecBytes & 4095) != 0 ||
        (riscv_pkg::PmaDevice0Base & 4095) != 0 ||
        (riscv_pkg::PmaDevice0Bytes & 4095) != 0 ||
        (riscv_pkg::PmaDevice1Base & 4095) != 0 ||
        (riscv_pkg::PmaDevice1Bytes & 4095) != 0 ||
        (riscv_pkg::PmaDevice2Base & 4095) != 0 ||
        (riscv_pkg::PmaDevice2Bytes & 4095) != 0 ||
        riscv_pkg::DdrCapacityLog2Bytes < 12 || riscv_pkg::DdrCapacityLog2Bytes > 55)
      $fatal(1, "cpu_top: PMA regions must use whole pages");
    if (riscv_pkg::DdrLimit <= riscv_pkg::DdrBase ||
        (riscv_pkg::PmaUncachedBytes != 0 &&
         riscv_pkg::PmaUncachedLimit <= riscv_pkg::PmaUncachedBase) ||
        (riscv_pkg::PmaDevice0Bytes != 0 &&
         riscv_pkg::PmaDevice0Limit <= riscv_pkg::PmaDevice0Base) ||
        (riscv_pkg::PmaDevice1Bytes != 0 &&
         riscv_pkg::PmaDevice1Limit <= riscv_pkg::PmaDevice1Base) ||
        (riscv_pkg::PmaDevice2Bytes != 0 &&
         riscv_pkg::PmaDevice2Limit <= riscv_pkg::PmaDevice2Base))
      $fatal(1, "cpu_top: PMA region overflows the address space");
    if (regions_overlap(
            riscv_pkg::DdrBase,
            riscv_pkg::DdrCapacityBytes,
            riscv_pkg::PmaUncachedBase,
            riscv_pkg::PmaUncachedBytes
        ) || regions_overlap(
            riscv_pkg::DdrBase,
            riscv_pkg::DdrCapacityBytes,
            riscv_pkg::PmaDevice0Base,
            riscv_pkg::PmaDevice0Bytes
        ) || regions_overlap(
            riscv_pkg::DdrBase,
            riscv_pkg::DdrCapacityBytes,
            riscv_pkg::PmaDevice1Base,
            riscv_pkg::PmaDevice1Bytes
        ) || regions_overlap(
            riscv_pkg::PmaUncachedBase,
            riscv_pkg::PmaUncachedBytes,
            riscv_pkg::PmaDevice0Base,
            riscv_pkg::PmaDevice0Bytes
        ) || regions_overlap(
            riscv_pkg::PmaUncachedBase,
            riscv_pkg::PmaUncachedBytes,
            riscv_pkg::PmaDevice1Base,
            riscv_pkg::PmaDevice1Bytes
        ) || regions_overlap(
            riscv_pkg::PmaDevice0Base,
            riscv_pkg::PmaDevice0Bytes,
            riscv_pkg::PmaDevice1Base,
            riscv_pkg::PmaDevice1Bytes
        ))
      $fatal(1, "cpu_top: PMA regions overlap");
    if (regions_overlap(
            riscv_pkg::PmaDevice2Base,
            riscv_pkg::PmaDevice2Bytes,
            riscv_pkg::DdrBase,
            riscv_pkg::DdrCapacityBytes
        ) || regions_overlap(
            riscv_pkg::PmaDevice2Base,
            riscv_pkg::PmaDevice2Bytes,
            riscv_pkg::PmaUncachedBase,
            riscv_pkg::PmaUncachedBytes
        ) || regions_overlap(
            riscv_pkg::PmaDevice2Base,
            riscv_pkg::PmaDevice2Bytes,
            riscv_pkg::PmaDevice0Base,
            riscv_pkg::PmaDevice0Bytes
        ) || regions_overlap(
            riscv_pkg::PmaDevice2Base,
            riscv_pkg::PmaDevice2Bytes,
            riscv_pkg::PmaDevice1Base,
            riscv_pkg::PmaDevice1Bytes
        ))
      $fatal(1, "cpu_top: third device region overlaps another PMA region");
    if (riscv_pkg::PmaUncachedExecBytes > riscv_pkg::PmaUncachedBytes)
      $fatal(1, "cpu_top: executable uncached prefix exceeds the memory region");
  end

  localparam int unsigned NormalFetchBytes = CACHE_NORMAL_MEMORY ? 32 : 8;

  // The hart's uncached data and instruction requests.
  logic data_req_valid, data_req_ready, data_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] data_req_addr;
  logic [2:0] data_req_size, data_req_prot;
  logic [3:0] data_req_cache;
  logic [L2_LINE_BYTES*8-1:0] data_req_wdata, data_resp_data;
  logic [L2_LINE_BYTES-1:0] data_req_wstrb;
  logic data_resp_valid;
  logic [1:0] data_resp_status;
  logic data_resp_ok;
  logic low_req_valid, low_req_ready, low_req_id;
  logic [riscv_pkg::PhysAddrBits-1:0] low_req_addr;
  logic low_resp_valid, low_resp_id, low_resp_error;
  logic [NormalFetchBytes*8-1:0] low_resp_data;

  // A failure in the hart's caches, the L2, or the uncached adapter latches
  // the fatal indication with its address: the uncached adapter's first, then
  // the L2's, the L1D's, and the L1I's. The hart stops on the failure's
  // cycle; the fetch, uncached and coherent paths stop on the latched flag.
  logic hart_cache_fatal, cluster_cache_fatal, cache_fatal, uncached_fatal, fatal_stop;
  logic [riscv_pkg::PhysAddrBits-1:0] hart_cache_fatal_addr, cluster_cache_fatal_addr;
  logic [riscv_pkg::PhysAddrBits-1:0] cache_fatal_addr, uncached_fatal_addr;
  assign cache_fatal = hart_cache_fatal || cluster_cache_fatal;
  assign cache_fatal_addr = cluster_cache_fatal ? cluster_cache_fatal_addr : hart_cache_fatal_addr;
  assign fatal_stop = o_fatal_error || cache_fatal || uncached_fatal;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_fatal_error <= 1'b0;
      o_fatal_addr  <= '0;
    end else if ((cache_fatal || uncached_fatal) && !o_fatal_error) begin
      o_fatal_error <= 1'b1;
      o_fatal_addr  <= uncached_fatal ? uncached_fatal_addr : cache_fatal_addr;
    end
  end
`ifndef SYNTHESIS
  // The caches read the stop with a register of delay in places, which
  // relies on the stop staying set until reset once it is set.
  logic fatal_stop_q = 1'b0;
  always_ff @(posedge i_clk) begin
    fatal_stop_q <= !i_rst && fatal_stop;
    if (!i_rst && fatal_stop_q) assert (fatal_stop);
  end
`endif

  // The caches' source-registered events and the fetch-provider stall event
  // for the hart's performance counters.
  cache_perf_pkg::cache_instance_perf_events_t l1d_perf_events, l1i_perf_events, l2_perf_events;
  cache_perf_pkg::cache_write_perf_events_t l2_write_perf_events;
  cache_perf_pkg::cache_hierarchy_perf_events_t cache_hierarchy_perf_events;
  cache_perf_pkg::cache_perf_events_t cache_perf_events;
  logic l1i_fetch_miss_stall;
  assign cache_hierarchy_perf_events.l1d = l1d_perf_events;
  assign cache_hierarchy_perf_events.l1i = l1i_perf_events;
  assign cache_hierarchy_perf_events.l2 = l2_perf_events;
  assign cache_hierarchy_perf_events.l2_write = l2_write_perf_events;
  assign cache_perf_events.hierarchy = cache_hierarchy_perf_events;
  assign cache_perf_events.l1i_fetch_miss_stall = l1i_fetch_miss_stall;

  logic coherent_d_valid;
  logic coherent_d_ready;
  logic [riscv_pkg::PhysAddrBits+311:0] coherent_d;
  logic coherent_p_valid;
  logic coherent_p_ready;
  logic [riscv_pkg::PhysAddrBits+29:0] coherent_p;
  logic coherent_r_valid;
  logic coherent_r_ready;
  logic [riscv_pkg::PhysAddrBits+274:0] coherent_r;
  logic coherent_w_valid;
  logic coherent_w_ready;
  logic [riscv_pkg::PhysAddrBits+259:0] coherent_w;
  logic coherent_wa_valid;
  logic coherent_wa_ready;
  logic [riscv_pkg::PhysAddrBits+10:0] coherent_wa;
  logic coherent_g_valid;
  logic coherent_g_ready;
  logic [riscv_pkg::PhysAddrBits+274:0] coherent_g;
  logic coherent_c_valid;
  logic coherent_c_ready;
  logic [riscv_pkg::PhysAddrBits+17:0] coherent_c;
  logic coherent_u_valid;
  logic coherent_u_ready;
  logic [riscv_pkg::PhysAddrBits+14:0] coherent_u;

  frost_hart #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .NORMAL_FETCH_LINES(NORMAL_FETCH_LINES),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .DECODED_QUEUE_DEPTH(DECODED_QUEUE_DEPTH),
      .L1_CACHE_BYTES(L1_CACHE_BYTES),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .L1D_WAYS(L1D_WAYS),
      .L1I_WAYS(L1I_WAYS),
      .L1D_NUM_MSHR(L1D_NUM_MSHR),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .PERF_COUNTERS(PERF_COUNTERS),
      .DATA_BYTES(L2_LINE_BYTES),
      .DATA_PROT(AXI_MEMORY_PROT)
  ) hart (
      .o_coherent_d_valid(coherent_d_valid),
      .i_coherent_d_ready(coherent_d_ready),
      .o_coherent_d(coherent_d),
      .i_coherent_p_valid(coherent_p_valid),
      .o_coherent_p_ready(coherent_p_ready),
      .i_coherent_p(coherent_p),
      .o_coherent_r_valid(coherent_r_valid),
      .i_coherent_r_ready(coherent_r_ready),
      .o_coherent_r(coherent_r),
      .o_coherent_w_valid(coherent_w_valid),
      .i_coherent_w_ready(coherent_w_ready),
      .o_coherent_w(coherent_w),
      .i_coherent_wa_valid(coherent_wa_valid),
      .o_coherent_wa_ready(coherent_wa_ready),
      .i_coherent_wa(coherent_wa),
      .i_coherent_g_valid(coherent_g_valid),
      .o_coherent_g_ready(coherent_g_ready),
      .i_coherent_g(coherent_g),
      .o_coherent_c_valid(coherent_c_valid),
      .i_coherent_c_ready(coherent_c_ready),
      .o_coherent_c(coherent_c),
      .i_coherent_u_valid(coherent_u_valid),
      .o_coherent_u_ready(coherent_u_ready),
      .i_coherent_u(coherent_u),
      .i_clk,
      .i_rst,
      .i_boot_addr,
      .i_interrupts,
      .i_seip,
      .i_msi_valid,
      .i_msi_level,
      .i_msi_id,
      .i_mtime,
      .i_disable_branch_prediction,
      .i_dbg_haltreq,
      .i_dbg_go,
      .i_dbg_go_addr,
      .i_dbg_data,
      .o_dbg_data_we,
      .o_dbg_data_wdata,
      .o_debug_mode,
      .o_dbg_parked,
      .o_dbg_cmd_err,
      .o_dbg_go_taken,
      .o_rst_done,
      .o_commit_valid,
      .o_debug_irq_status,
      .o_debug_commit_pc,
      .o_debug_commit_2_pc,
      .o_debug_commit_valid,
      .i_fatal_error(o_fatal_error),
      .i_fatal_stop(fatal_stop),
      .o_cache_fatal(hart_cache_fatal),
      .o_cache_fatal_addr(hart_cache_fatal_addr),
      .o_uncached_fatal(uncached_fatal),
      .o_uncached_fatal_addr(uncached_fatal_addr),
      .o_l1d_perf_events(l1d_perf_events),
      .o_l1i_perf_events(l1i_perf_events),
      .o_l1i_fetch_miss_stall(l1i_fetch_miss_stall),
      .i_cache_perf_events(cache_perf_events),
      .o_data_req_valid(data_req_valid),
      .i_data_req_ready(data_req_ready),
      .o_data_req_write(data_req_write),
      .o_data_req_addr(data_req_addr),
      .o_data_req_size(data_req_size),
      .o_data_req_cache(data_req_cache),
      .o_data_req_prot(data_req_prot),
      .o_data_req_wdata(data_req_wdata),
      .o_data_req_wstrb(data_req_wstrb),
      .i_data_resp_valid(data_resp_valid),
      .i_data_resp_data(data_resp_data),
      .i_data_resp_status(data_resp_status),
      .i_data_resp_ok(data_resp_ok),
      .o_fetch_req_valid(low_req_valid),
      .i_fetch_req_ready(low_req_ready),
      .o_fetch_req_addr(low_req_addr),
      .o_fetch_req_id(low_req_id),
      .i_fetch_resp_valid(low_resp_valid),
      .i_fetch_resp_id(low_resp_id),
      .i_fetch_resp_data(low_resp_data),
      .i_fetch_resp_error(low_resp_error)
  );

  frost_cluster_memory #(
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .ENABLE_COHERENCE(ENABLE_COHERENCE),
      .L2_CACHE_BYTES(L2_CACHE_BYTES),
      .L2_WAYS(L2_WAYS),
      .L2_NUM_MSHR(L2_NUM_MSHR),
      .L2_NUM_WB(L2_NUM_WB),
      .L2_NUM_WAITERS(L2_NUM_WAITERS),
      .L2_PREFETCH(L2_PREFETCH),
      .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
      .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
      .L2_LINE_BYTES(L2_LINE_BYTES),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .FETCH_BYTES(NormalFetchBytes),
      .AXI_ID_BITS(AXI_ID_BITS),
      .AXI_USER_BITS(AXI_USER_BITS),
      .AXI_MEMORY_PROT(AXI_MEMORY_PROT)
  ) cluster_memory (
      .i_coherent_d_valid(coherent_d_valid),
      .o_coherent_d_ready(coherent_d_ready),
      .i_coherent_d(coherent_d),
      .o_coherent_p_valid(coherent_p_valid),
      .i_coherent_p_ready(coherent_p_ready),
      .o_coherent_p(coherent_p),
      .i_coherent_r_valid(coherent_r_valid),
      .o_coherent_r_ready(coherent_r_ready),
      .i_coherent_r(coherent_r),
      .i_coherent_w_valid(coherent_w_valid),
      .o_coherent_w_ready(coherent_w_ready),
      .i_coherent_w(coherent_w),
      .o_coherent_wa_valid(coherent_wa_valid),
      .i_coherent_wa_ready(coherent_wa_ready),
      .o_coherent_wa(coherent_wa),
      .o_coherent_g_valid(coherent_g_valid),
      .i_coherent_g_ready(coherent_g_ready),
      .o_coherent_g(coherent_g),
      .i_coherent_c_valid(coherent_c_valid),
      .o_coherent_c_ready(coherent_c_ready),
      .i_coherent_c(coherent_c),
      .o_coherent_u_valid(coherent_u_valid),
      .i_coherent_u_ready(coherent_u_ready),
      .o_coherent_u(coherent_u),
      .i_clk,
      .i_rst,
      .i_axi_rst,
      .i_fatal_error(o_fatal_error),
      .i_coherent_req_valid,
      .o_coherent_req_ready,
      .i_coherent_req_write,
      .i_coherent_req_addr,
      .i_coherent_req_wdata,
      .i_coherent_req_wstrb,
      .i_coherent_req_id,
      .o_coherent_resp_valid,
      .o_coherent_resp_id,
      .o_coherent_resp_rdata,
      .o_coherent_resp_error,
      .i_data_req_valid(data_req_valid),
      .o_data_req_ready(data_req_ready),
      .i_data_req_write(data_req_write),
      .i_data_req_addr(data_req_addr),
      .i_data_req_size(data_req_size),
      .i_data_req_cache(data_req_cache),
      .i_data_req_prot(data_req_prot),
      .i_data_req_wdata(data_req_wdata),
      .i_data_req_wstrb(data_req_wstrb),
      .o_data_resp_valid(data_resp_valid),
      .o_data_resp_data(data_resp_data),
      .o_data_resp_status(data_resp_status),
      .o_data_resp_ok(data_resp_ok),
      .i_fetch_req_valid(low_req_valid),
      .o_fetch_req_ready(low_req_ready),
      .i_fetch_req_addr(low_req_addr),
      .i_fetch_req_id(low_req_id),
      .o_fetch_resp_valid(low_resp_valid),
      .o_fetch_resp_id(low_resp_id),
      .o_fetch_resp_data(low_resp_data),
      .o_fetch_resp_error(low_resp_error),
      .o_cache_fatal(cluster_cache_fatal),
      .o_cache_fatal_addr(cluster_cache_fatal_addr),
      .o_l2_perf_events(l2_perf_events),
      .o_l2_write_perf_events(l2_write_perf_events),
      .o_axi_idle,
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
endmodule
