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
// The hart owns its machine and supervisor IMSIC files.
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

  localparam int unsigned LineIdBits   = 4;
  localparam int unsigned DdrAxiIdBits = 5;
  localparam int unsigned L1LineBytes  = 32;
  logic [riscv_pkg::XLEN-1:0] program_counter;
  logic [63:0] instruction, bram_fetch_instr_by_parity, instruction_high;
  logic instruction_window_high;
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] instruction_sideband;
  logic [7:0] instruction_pc_metadata;
  logic instruction_bank_sel_r, instruction_valid;
  logic [riscv_pkg::XLEN-3:0] instruction_served_word_low, instruction_served_last_word_low;
  logic [riscv_pkg::XLEN-3:0] instruction_served_prev_word_low;
  logic instruction_served_prev_word_valid_low;
  logic [riscv_pkg::XLEN-3:0] instruction_served_word_high, instruction_served_last_word_high;
  logic [riscv_pkg::XLEN-3:0] instruction_served_prev_word_high;
  logic instruction_served_prev_word_valid_high;
  logic [riscv_pkg::PhysAddrBits-1:0] fetch_pa0, fetch_pa1;
  logic fetch_pa0_is_cached, fetch_pa_valid;
  assign fetch_pa0_is_cached = riscv_pkg::pma_cached_ok(riscv_pkg::XLEN'(fetch_pa0));
  logic fetch_fault0, fetch_fault0_page, fetch_fault1, fetch_fault1_page;
  logic fetch_line_after_ok, fetch_redirect, fetch_cached_retarget;
  logic instruction_fault0, instruction_fault0_page, instruction_fault1, instruction_fault1_page;
  logic instruction_served_high, instruction_pc_metadata_served_high;
  logic fetch_replay_consume, fetch_live_claim, pipeline_stall;
  logic fence_i_sync_req, fence_i_sync_done, fence_i_flush;
  logic [7:0] high_fetch_pc_metadata_by_parity, bram_fetch_pc_metadata_by_parity;
  logic [3:0] high_fetch_pc_pairability_by_parity, bram_fetch_pc_pairability_by_parity;
  logic [1:0] high_fetch_slot2_start_valid_lo_by_parity, bram_fetch_slot2_start_valid_lo_by_parity;
  logic [15:0] fetch_pc_metadata_by_provider_parity;
  logic [ 7:0] fetch_pc_pairability_by_provider_parity;
  logic [ 3:0] fetch_slot2_start_valid_lo_by_provider_parity;
  assign fetch_pc_metadata_by_provider_parity = {
    high_fetch_pc_metadata_by_parity, bram_fetch_pc_metadata_by_parity
  };
  assign fetch_pc_pairability_by_provider_parity = {
    high_fetch_pc_pairability_by_parity, bram_fetch_pc_pairability_by_parity
  };
  assign fetch_slot2_start_valid_lo_by_provider_parity = {
    high_fetch_slot2_start_valid_lo_by_parity, bram_fetch_slot2_start_valid_lo_by_parity
  };
  logic coh_admit_valid, coh_admit_ready, coh_inval_valid, coh_inval_done, coh_release_valid;
  logic [riscv_pkg::DmaCoherenceLockBits-1:0] coh_admit_slot, coh_inval_slot, coh_release_slot;
  logic [riscv_pkg::PhysAddrBits-1:0] coh_admit_addr;
  logic iup_req_valid, iup_req_ready, iup_req_write, iup_resp_valid;
  logic [riscv_pkg::PhysAddrBits-1:0] iup_req_addr;
  logic [L1LineBytes*8-1:0] iup_req_wdata, iup_resp_rdata;
  logic [L1LineBytes-1:0] iup_req_wstrb;
  logic [LineIdBits-1:0] iup_req_id, iup_resp_id;
  logic walk_line_req_valid, walk_line_req_ready, walk_line_resp_valid;
  logic [riscv_pkg::PhysAddrBits-1:0] walk_line_req_addr;
  logic [LineIdBits-2:0] walk_line_req_id, walk_line_resp_id;
  logic [1:0] ptw_line_req_id;
  assign walk_line_req_id = (LineIdBits - 1)'(ptw_line_req_id);
  logic [L1LineBytes*8-1:0] walk_line_resp_rdata;
  logic [riscv_pkg::PhysAddrBits-1:0] data_memory_address;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_write_data;
  logic [riscv_pkg::MemStrbBits-1:0] data_memory_cached_byte_write_enable;
  logic data_memory_cached_read_enable, data_memory_cached_read_sel;
  logic data_memory_cached_read_if_sel, data_memory_cached_read_if_clear;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] data_memory_cached_read_id, data_memory_cached_resp_id;
  logic data_memory_cached_read_no_merge;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_cached_read_data, data_memory_cached_write_data;
  logic data_memory_cached_read_valid, data_memory_cached_read_ready;
  logic data_memory_cached_write_done, data_memory_cached_write_inflight;
  cache_perf_pkg::cache_hierarchy_perf_events_t cache_hierarchy_perf_events;
  cache_perf_pkg::cache_perf_events_t cache_perf_events;
  logic l1i_fetch_miss_stall;
  assign cache_perf_events.hierarchy = cache_hierarchy_perf_events;
  assign cache_perf_events.l1i_fetch_miss_stall = l1i_fetch_miss_stall;

  localparam longint unsigned CachedBase = riscv_pkg::DdrBase;
  localparam longint unsigned CachedSizeBytes = riscv_pkg::DdrCapacityBytes;
  logic [riscv_pkg::XLEN-1:0] cpu_pc_xlen, cpu_data_mem_addr_xlen;
  assign program_counter = cpu_pc_xlen;
  assign data_memory_address = cpu_data_mem_addr_xlen[riscv_pkg::PhysAddrBits-1:0];
  logic data_memory_cached_read_error, walk_line_resp_error, iup_resp_error;
  logic uncached_read_request_ready, uncached_read_enable, uncached_read_ready;
  logic uncached_read_valid, uncached_write_done, uncached_write_inflight;
  riscv_pkg::mem_size_e uncached_read_size, uncached_write_size;
  logic [63:0] uncached_read_data;
  logic [1:0] uncached_read_status, uncached_write_status;
  logic [7:0] uncached_write_strb;
  logic data_req_valid, data_req_ready, data_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] data_req_addr;
  logic [2:0] data_req_size, data_req_prot;
  logic [3:0] data_req_cache;
  logic [L2_LINE_BYTES*8-1:0] data_req_wdata, data_resp_data;
  logic [L2_LINE_BYTES-1:0] data_req_wstrb;
  logic data_resp_valid;
  logic uncached_write_buffered;
  logic [1:0] data_resp_status;
  logic data_resp_ok;
  logic low_req_valid, low_req_ready, low_req_id;
  logic [riscv_pkg::PhysAddrBits-1:0] low_req_addr;
  logic low_resp_valid, low_resp_id, low_resp_error;
  localparam int unsigned NormalFetchBytes = CACHE_NORMAL_MEMORY ? 32 : 8;
  logic [NormalFetchBytes*8-1:0] low_resp_data;
  logic cache_fatal;
  logic uncached_fatal;
  logic [riscv_pkg::PhysAddrBits-1:0] uncached_fatal_addr;
  logic [riscv_pkg::PhysAddrBits-1:0] cache_fatal_addr;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_fatal_error <= 1'b0;
      o_fatal_addr  <= '0;
    end else if ((cache_fatal || uncached_fatal) && !o_fatal_error) begin
      o_fatal_error <= 1'b1;
      o_fatal_addr  <= uncached_fatal ? uncached_fatal_addr : cache_fatal_addr;
    end
  end
  cpu_ooo #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .MEM_BYTE_ADDR_WIDTH(riscv_pkg::LowBramAddrBits),
      .VARIABLE_UNCACHED(1'b1),
      .MMIO_ADDR(riscv_pkg::MmioWindowAddr),
      .CACHED_BASE(CachedBase),
      .CACHED_SIZE_BYTES(CachedSizeBytes),
      .PERF_COUNTERS(PERF_COUNTERS),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .DECODED_QUEUE_DEPTH(DECODED_QUEUE_DEPTH)
  ) cpu_inst (
      .i_clk,
      .i_boot_addr,
      .i_fatal_stop(o_fatal_error || cache_fatal || uncached_fatal),
      .i_rst(i_rst),
      .o_pc(cpu_pc_xlen),
      .i_instr(instruction),
      .i_instr_low_by_parity(bram_fetch_instr_by_parity),
      .i_instr_high(instruction_high),
      .i_instr_window_high(instruction_window_high),
      .i_instr_sideband(instruction_sideband),
      .i_instr_pc_metadata(instruction_pc_metadata),
      .i_instr_pc_metadata_by_provider_parity(fetch_pc_metadata_by_provider_parity),
      .i_pc_pairability_by_provider_parity(fetch_pc_pairability_by_provider_parity),
      .i_slot2_start_valid_lo_by_provider_parity(fetch_slot2_start_valid_lo_by_provider_parity),
      .i_instr_pc_metadata_served_high(instruction_pc_metadata_served_high),
      .i_instr_bank_sel_r(instruction_bank_sel_r),
      .i_served_word_low(instruction_served_word_low),
      .i_served_last_word_low(instruction_served_last_word_low),
      .i_served_prev_word_low(instruction_served_prev_word_low),
      .i_served_prev_word_valid_low(instruction_served_prev_word_valid_low),
      .i_served_word_high(instruction_served_word_high),
      .i_served_last_word_high(instruction_served_last_word_high),
      .i_served_prev_word_high(instruction_served_prev_word_high),
      .i_served_prev_word_valid_high(instruction_served_prev_word_valid_high),
      .i_instr_valid(instruction_valid),
      .i_instr_fault0(instruction_fault0),
      .i_instr_fault0_page(instruction_fault0_page),
      .i_instr_fault1(instruction_fault1),
      .i_instr_fault1_page(instruction_fault1_page),
      .i_served_high(instruction_served_high),
      .o_fetch_replay_consume(fetch_replay_consume),
      .o_fetch_live_claim(fetch_live_claim),
      .o_fetch_pa0(fetch_pa0),
      .o_fetch_pa1(fetch_pa1),
      .o_fetch_pa_valid(fetch_pa_valid),
      .o_fetch_fault0(fetch_fault0),
      .o_fetch_fault0_page(fetch_fault0_page),
      .o_fetch_fault1(fetch_fault1),
      .o_fetch_fault1_page(fetch_fault1_page),
      .o_fetch_line_after_ok(fetch_line_after_ok),
      .o_fetch_redirect(fetch_redirect),
      .o_fetch_cached_retarget(fetch_cached_retarget),
      .o_pipeline_stall(pipeline_stall),
      .o_fence_i_sync_req(fence_i_sync_req),
      .i_fence_i_sync_done(fence_i_sync_done),
      .o_walk_line_req_valid(walk_line_req_valid),
      .i_walk_line_req_ready(walk_line_req_ready),
      .o_walk_line_req_addr(walk_line_req_addr),
      .o_walk_line_req_id(ptw_line_req_id),
      .i_walk_line_resp_valid(walk_line_resp_valid),
      .i_walk_line_resp_error(walk_line_resp_error),
      .i_walk_line_resp_id(walk_line_resp_id[1:0]),
      .i_walk_line_resp_rdata(walk_line_resp_rdata),
      .o_fence_i_flush(fence_i_flush),
      .o_data_mem_addr(cpu_data_mem_addr_xlen),
      .o_data_mem_wr_data(data_memory_write_data),
      .o_data_mem_per_byte_wr_en(),
      .o_data_mem_bram_byte_wr_en(),
      .o_data_mem_read_enable(),
      // Cached tier ports (high-address region).
      .o_data_mem_cached_byte_wr_en(data_memory_cached_byte_write_enable),
      .o_data_mem_cached_wr_data(data_memory_cached_write_data),
      .o_data_mem_cached_read_enable(data_memory_cached_read_enable),
      .o_data_mem_cached_read_sel(data_memory_cached_read_sel),
      .o_data_mem_cached_read_if_sel(data_memory_cached_read_if_sel),
      .o_data_mem_cached_read_if_clear(data_memory_cached_read_if_clear),
      .o_data_mem_cached_read_id(data_memory_cached_read_id),
      .o_data_mem_cached_read_no_merge(data_memory_cached_read_no_merge),
      .i_cached_read_data(data_memory_cached_read_data),
      .i_cached_read_id(data_memory_cached_resp_id),
      .i_cached_read_valid(data_memory_cached_read_valid),
      .i_cached_read_error(data_memory_cached_read_error),
      .o_cached_read_ready(data_memory_cached_read_ready),
      .i_cached_write_done(data_memory_cached_write_done),
      .i_cached_write_inflight(data_memory_cached_write_inflight),
      .i_uncached_read_request_ready(uncached_read_request_ready),
      .o_uncached_read_enable(uncached_read_enable),
      .o_uncached_read_size(uncached_read_size),
      .i_uncached_read_valid(uncached_read_valid),
      .o_uncached_read_ready(uncached_read_ready),
      .i_uncached_read_data(uncached_read_data),
      .i_uncached_read_status(uncached_read_status),
      .o_uncached_write_byte_en(uncached_write_strb),
      .o_uncached_write_size(uncached_write_size),
      .o_uncached_write_buffered(uncached_write_buffered),
      .i_uncached_write_done(uncached_write_done),
      .i_uncached_write_status(uncached_write_status),
      .i_uncached_write_inflight(uncached_write_inflight),
      // DMA coherence handshake
      .i_coh_admit_valid(coh_admit_valid),
      .i_coh_admit_slot(coh_admit_slot),
      .i_coh_admit_addr(riscv_pkg::XLEN'(coh_admit_addr)),
      .o_coh_admit_ready(coh_admit_ready),
      .i_coh_inval_valid(coh_inval_valid),
      .i_coh_inval_slot(coh_inval_slot),
      .o_coh_inval_done(coh_inval_done),
      .i_coh_release_valid(coh_release_valid),
      .i_coh_release_slot(coh_release_slot),
      .i_cache_perf_events(cache_perf_events),
      .o_mmio_read_pulse(),
      .o_mmio_load_addr(),
      .o_mmio_load_valid(),
      .o_mmio_fifo0_read_pulse(),
      .o_mmio_fifo1_read_pulse(),
      .o_mmio_uart_rx_ready_pulse(),
      .i_data_mem_rd_data('0),
      .o_rst_done(o_rst_done),
      .o_vld(o_commit_valid),
      .o_pc_vld(),
      // Interrupt and timer interface
      .i_interrupts(i_interrupts),
      .i_seip_line(i_seip),
      .i_msi_valid,
      .i_msi_level,
      .i_msi_id,

      .i_mtime(i_mtime),
      .o_debug_irq_status(o_debug_irq_status),
      .o_debug_commit_pc(o_debug_commit_pc),
      .o_debug_commit_2_pc(o_debug_commit_2_pc),
      .o_debug_commit_valid(o_debug_commit_valid),
      // Branch prediction enabled by default in production. TestRIG
      // instruction injection requires fetch to stay on the sequential path
      // between redirects (hw/sim/frost_rvfi_dii.sv).
      .i_disable_branch_prediction(i_disable_branch_prediction),

      // Debug module interface
      .i_dbg_haltreq(i_dbg_haltreq),
      .i_dbg_go(i_dbg_go),
      .i_dbg_go_addr(i_dbg_go_addr),
      .i_dbg_data(i_dbg_data),
      .o_dbg_data_we(o_dbg_data_we),
      .o_dbg_data_wdata(o_dbg_data_wdata),
      .o_debug_mode(o_debug_mode),
      .o_dbg_parked(o_dbg_parked),
      .o_dbg_cmd_err(o_dbg_cmd_err),
      .o_dbg_go_taken(o_dbg_go_taken),
      .o_dbg_bram_store(),
      .o_dbg_bram_store_addr(),
      .o_dbg_bram_store_strb()
  );
  logic [1:0][63:0] fetch_instr;
  logic [1:0][riscv_pkg::ImemFetchSidebandWidth-1:0] fetch_sideband;
  logic [1:0][7:0] fetch_metadata;
  logic [1:0][3:0] fetch_pairability;
  logic [1:0][1:0] fetch_slot2_valid;
  logic [1:0] fetch_bank, fetch_valid;
  logic [1:0][riscv_pkg::XLEN-3:0] served_word, served_last, served_prev;
  logic [1:0] served_prev_valid, served_fault0, served_fault1, served_page0, served_page1;
  logic provider_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) provider_q <= 1'b0;
    else provider_q <= fetch_pa0_is_cached;
  end
  assign instruction_valid = (provider_q == fetch_pa0_is_cached) &&
      fetch_valid[provider_q] && !o_fatal_error;
  assign instruction = fetch_instr[provider_q];
  assign instruction_high = fetch_instr[1];
  assign instruction_window_high = provider_q;
  assign instruction_sideband = fetch_sideband[provider_q];
  assign instruction_pc_metadata = {
    instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
    instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
    instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
    instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
    instruction_sideband[riscv_pkg::ImemSbPairableNativeHi],
    instruction_sideband[riscv_pkg::ImemSbPairableCompressedHi],
    instruction_sideband[riscv_pkg::ImemSbIsCompressedHi],
    instruction_sideband[riscv_pkg::ImemSbIsCompressedLo]
  };
  assign bram_fetch_instr_by_parity = fetch_bank[0] ?
      {fetch_instr[0][31:0], fetch_instr[0][63:32]} : fetch_instr[0];
  assign {high_fetch_pc_metadata_by_parity, bram_fetch_pc_metadata_by_parity} = fetch_metadata;
  assign {high_fetch_pc_pairability_by_parity, bram_fetch_pc_pairability_by_parity} =
      fetch_pairability;
  assign {high_fetch_slot2_start_valid_lo_by_parity, bram_fetch_slot2_start_valid_lo_by_parity} =
      fetch_slot2_valid;
  assign instruction_bank_sel_r = fetch_bank[provider_q];
  assign instruction_pc_metadata_served_high = provider_q;
  assign instruction_served_high = provider_q;
  assign {instruction_served_word_high, instruction_served_word_low} = served_word;
  assign {instruction_served_last_word_high, instruction_served_last_word_low} = served_last;
  assign {instruction_served_prev_word_high, instruction_served_prev_word_low} = served_prev;
  assign {instruction_served_prev_word_valid_high, instruction_served_prev_word_valid_low} =
      served_prev_valid;
  assign instruction_fault0 = served_fault0[provider_q];
  assign instruction_fault1 = served_fault1[provider_q];
  assign instruction_fault0_page = served_page0[provider_q];
  assign instruction_fault1_page = served_page1[provider_q];
  wire normal_fetch_invalidate = fence_i_flush ||
      (CACHE_NORMAL_MEMORY ? o_dbg_go_taken : fetch_cached_retarget);
  fetch_provider #(
      .LINE_BYTES(NormalFetchBytes),
      .LINE_ID_BITS(1),
      .VICTIM_LINES(CACHE_NORMAL_MEMORY ? NORMAL_FETCH_LINES : 0),
      .DIRECT_LOOKUP(CACHE_NORMAL_MEMORY),
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .CACHED_PROVIDER(1'b0)
  ) uncached_fetch (
      .i_clk,
      .i_rst,
      .i_pc(program_counter),
      .i_pa0(fetch_pa0),
      .i_pa1(fetch_pa1),
      .i_pa_valid(fetch_pa_valid),
      .i_fault0(fetch_fault0),
      .i_fault0_page(fetch_fault0_page),
      .i_fault1(fetch_fault1),
      .i_fault1_page(fetch_fault1_page),
      .i_line_after_ok(CACHE_NORMAL_MEMORY && fetch_line_after_ok),
      .i_retarget(fetch_cached_retarget),
      .i_fetch_replay_consume(fetch_replay_consume),
      .i_pipeline_stall(pipeline_stall || o_fatal_error),
      .o_instr(fetch_instr[0]),
      .o_instr_sideband(fetch_sideband[0]),
      .o_pc_metadata_by_parity(fetch_metadata[0]),
      .o_pc_pairability_by_parity(fetch_pairability[0]),
      .o_slot2_start_valid_lo_by_parity(fetch_slot2_valid[0]),
      .o_instr_bank_sel_r(fetch_bank[0]),
      .o_served_word(served_word[0]),
      .o_served_last_word(served_last[0]),
      .o_served_prev_word(served_prev[0]),
      .o_served_prev_word_valid(served_prev_valid[0]),
      .o_served_fault0(served_fault0[0]),
      .o_served_fault0_page(served_page0[0]),
      .o_served_fault1(served_fault1[0]),
      .o_served_fault1_page(served_page1[0]),
      .o_instr_valid(fetch_valid[0]),
      .o_instr_valid_next(),
      .i_invalidate(normal_fetch_invalidate),
      .i_l1i_miss_outstanding(1'b0),
      .o_perf_miss_stall(),
      .o_line_req_valid(low_req_valid),
      .i_line_req_ready(low_req_ready),
      .o_line_req_write(),
      .o_line_req_addr(low_req_addr),
      .o_line_req_wdata(),
      .o_line_req_wstrb(),
      .o_line_req_id(low_req_id),
      .i_line_resp_valid(low_resp_valid),
      .i_line_resp_error(low_resp_error),
      .i_line_resp_id(low_resp_id),
      .i_line_resp_rdata(low_resp_data)
  );
  fetch_provider #(
      .LINE_BYTES(32),
      .LINE_ID_BITS(4),
      .VICTIM_LINES(6),
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .CACHED_PROVIDER(1'b1)
  ) cached_fetch (
      .i_clk,
      .i_rst,
      .i_pc(program_counter),
      .i_pa0(fetch_pa0),
      .i_pa1(fetch_pa1),
      .i_pa_valid(fetch_pa_valid),
      .i_fault0(fetch_fault0),
      .i_fault0_page(fetch_fault0_page),
      .i_fault1(fetch_fault1),
      .i_fault1_page(fetch_fault1_page),
      .i_line_after_ok(fetch_line_after_ok),
      .i_retarget(fetch_cached_retarget),
      .i_fetch_replay_consume(fetch_replay_consume),
      .i_pipeline_stall(pipeline_stall || o_fatal_error),
      .o_instr(fetch_instr[1]),
      .o_instr_sideband(fetch_sideband[1]),
      .o_pc_metadata_by_parity(fetch_metadata[1]),
      .o_pc_pairability_by_parity(fetch_pairability[1]),
      .o_slot2_start_valid_lo_by_parity(fetch_slot2_valid[1]),
      .o_instr_bank_sel_r(fetch_bank[1]),
      .o_served_word(served_word[1]),
      .o_served_last_word(served_last[1]),
      .o_served_prev_word(served_prev[1]),
      .o_served_prev_word_valid(served_prev_valid[1]),
      .o_served_fault0(served_fault0[1]),
      .o_served_fault0_page(served_page0[1]),
      .o_served_fault1(served_fault1[1]),
      .o_served_fault1_page(served_page1[1]),
      .o_instr_valid(fetch_valid[1]),
      .o_instr_valid_next(),
      .i_invalidate(fence_i_flush),
      .i_l1i_miss_outstanding(|cache_hierarchy_perf_events.l1i.miss_outstanding),
      .o_perf_miss_stall(l1i_fetch_miss_stall),
      .o_line_req_valid(iup_req_valid),
      .i_line_req_ready(iup_req_ready),
      .o_line_req_write(iup_req_write),
      .o_line_req_addr(iup_req_addr),
      .o_line_req_wdata(iup_req_wdata),
      .o_line_req_wstrb(iup_req_wstrb),
      .o_line_req_id(iup_req_id),
      .i_line_resp_valid(iup_resp_valid),
      .i_line_resp_error(iup_resp_error),
      .i_line_resp_id(iup_resp_id),
      .i_line_resp_rdata(iup_resp_rdata)
  );

  logic dma_req_ready, dma_resp_valid, dma_resp_error;
  logic [3:0] dma_resp_id;
  logic [255:0] dma_resp_rdata;
  wire coherent_address_ok = riscv_pkg::pma_cached_ok(
      riscv_pkg::XLEN'(i_coherent_req_addr)
  ) && i_coherent_req_addr[4:0] == 0;
  // Register ingress ownership before the hierarchy's same-line checks.
  // This separates a wrapper's arbitration/address mux from the cache
  // admission path, while permitting dequeue and replacement on one edge.
  logic coherent_pending_q;
  logic dma_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] dma_req_addr;
  logic [255:0] dma_req_wdata;
  logic [31:0] dma_req_wstrb;
  logic [3:0] dma_req_id;
  wire dma_req_valid = ENABLE_COHERENCE && !i_rst && !o_fatal_error && coherent_pending_q;
  assign o_coherent_req_ready = ENABLE_COHERENCE && (ENABLE_CACHED_TIER != 0) &&
      !i_rst && !o_fatal_error && coherent_address_ok &&
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
    logic line_req_valid, line_req_ready, line_req_write;
    logic [riscv_pkg::PhysAddrBits-1:0] line_req_addr;
    logic [L1LineBytes*8-1:0] line_req_wdata;
    logic [L1LineBytes-1:0] line_req_wstrb;
    logic [LineIdBits-1:0] line_req_id;
    logic line_resp_valid, line_resp_error;
    logic [LineIdBits-1:0] line_resp_id;
    logic [L1LineBytes*8-1:0] line_resp_rdata;

    cached_tier_adapter #(
        .XLEN(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L1LineBytes),
        .LINE_ID_BITS(LineIdBits),
        .SPLIT_READ_REQ(1'b1)
    ) cached_adapter (
        .o_read_error(data_memory_cached_read_error),
        .i_line_resp_error(line_resp_error),

        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_read_req(data_memory_cached_read_enable),
        .i_read_req_sel(data_memory_cached_read_sel),
        .i_read_req_if_sel(data_memory_cached_read_if_sel),
        .i_read_req_if_clear(data_memory_cached_read_if_clear),
        .i_read_id(data_memory_cached_read_id),
        .i_read_no_merge(data_memory_cached_read_no_merge),
        .i_req_addr(data_memory_address),
        .i_write_byte_en(data_memory_cached_byte_write_enable),
        .i_write_data(data_memory_cached_write_data),
        .o_read_data(data_memory_cached_read_data),
        .o_read_id(data_memory_cached_resp_id),
        .o_read_valid(data_memory_cached_read_valid),
        .i_read_ready(data_memory_cached_read_ready),
        .o_write_done(data_memory_cached_write_done),
        .o_write_inflight(data_memory_cached_write_inflight),
        .o_line_req_valid(line_req_valid),
        .i_line_req_ready(line_req_ready),
        .o_line_req_write(line_req_write),
        .o_line_req_addr(line_req_addr),
        .o_line_req_wdata(line_req_wdata),
        .o_line_req_wstrb(line_req_wstrb),
        .o_line_req_id(line_req_id),
        .i_line_resp_valid(line_resp_valid),
        .i_line_resp_id(line_resp_id),
        .i_line_resp_rdata(line_resp_rdata)
    );

    frost_cache_hierarchy #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .ENABLE_RESPONSE_ERRORS(1'b1),
        .L1_LINE_BYTES(L1LineBytes),
        .L2_LINE_BYTES(L2_LINE_BYTES),
        .UP_ID_BITS(LineIdBits),
        .L1_CACHE_BYTES(L1_CACHE_BYTES),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L2_CACHE_BYTES(L2_CACHE_BYTES),
        .L1D_WAYS(L1D_WAYS),
        .L1I_WAYS(L1I_WAYS),
        .L2_WAYS(L2_WAYS),
        .L1D_NUM_MSHR(L1D_NUM_MSHR),
        .L2_NUM_MSHR(L2_NUM_MSHR),
        .L2_NUM_WAITERS(L2_NUM_WAITERS),
        .L2_PREFETCH(L2_PREFETCH),
        .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
        .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
        .L2_NUM_WB(L2_NUM_WB),
        .L2_DOWN_ID_BITS(DdrAxiIdBits),
        .SIM_FAST_MAINT(SIM_FAST_MAINT),
        .NUM_DMA_LOCK(riscv_pkg::DmaCoherenceLocks)
    ) cache_hierarchy (
        .o_up_resp_error(line_resp_error),
        .o_iup_resp_error(iup_resp_error),
        .o_wup_resp_error(walk_line_resp_error),
        .o_dma_resp_error(dma_resp_error),
        .o_fatal_error(cache_fatal),
        .o_fatal_addr(cache_fatal_addr),

        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_up_req_valid(line_req_valid),
        .o_up_req_ready(line_req_ready),
        .i_up_req_write(line_req_write),
        .i_up_req_addr(line_req_addr),
        .i_up_req_wdata(line_req_wdata),
        .i_up_req_wstrb(line_req_wstrb),
        .i_up_req_id(line_req_id),
        .o_up_resp_valid(line_resp_valid),
        .o_up_resp_id(line_resp_id),
        .o_up_resp_rdata(line_resp_rdata),
        .i_iup_req_valid(iup_req_valid),
        .o_iup_req_ready(iup_req_ready),
        .i_iup_req_write(iup_req_write),
        .i_iup_req_addr(iup_req_addr),
        .i_iup_req_wdata(iup_req_wdata),
        .i_iup_req_wstrb(iup_req_wstrb),
        .i_iup_req_id(iup_req_id),
        .o_iup_resp_valid(iup_resp_valid),
        .o_iup_resp_id(iup_resp_id),
        .o_iup_resp_rdata(iup_resp_rdata),
        // Page-table walker port: the core's ptw line master (read-only).
        .i_wup_req_valid(walk_line_req_valid),
        .o_wup_req_ready(walk_line_req_ready),
        .i_wup_req_write(1'b0),
        .i_wup_req_addr(walk_line_req_addr),
        .i_wup_req_wdata('0),
        .i_wup_req_wstrb('0),
        .i_wup_req_id(walk_line_req_id),
        .o_wup_resp_valid(walk_line_resp_valid),
        .o_wup_resp_id(walk_line_resp_id),
        .o_wup_resp_rdata(walk_line_resp_rdata),
        // DMA port: the NIC and the DMA test engine through dma_arbiter below.
        // The coherence handshake runs to the core's lq_coherence_port.
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
        .o_coh_admit_valid(coh_admit_valid),
        .o_coh_admit_slot(coh_admit_slot),
        .o_coh_admit_addr(coh_admit_addr),
        .i_coh_admit_ready(coh_admit_ready),
        .o_coh_inval_valid(coh_inval_valid),
        .o_coh_inval_slot(coh_inval_slot),
        .i_coh_inval_done(coh_inval_done),
        .o_coh_release_valid(coh_release_valid),
        .o_coh_release_slot(coh_release_slot),
        .i_fence_sync(fence_i_sync_req),
        .o_fence_done(fence_i_sync_done),
        .o_perf_events(cache_hierarchy_perf_events),
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
    assign cache_fatal = 1'b0;
    assign cache_fatal_addr = '0;
    assign dma_req_ready = 1'b0;
    assign dma_resp_valid = 1'b0;
    assign dma_resp_id = '0;
    assign dma_resp_rdata = '0;
    assign dma_resp_error = 1'b0;
    assign coh_admit_valid = 1'b0;
    assign coh_admit_slot = '0;
    assign coh_admit_addr = '0;
    assign coh_inval_valid = 1'b0;
    assign coh_inval_slot = '0;
    assign coh_release_valid = 1'b0;
    assign coh_release_slot = '0;
    assign cache_hierarchy_perf_events = '0;
    assign iup_req_ready = 1'b0;
    assign iup_resp_valid = 1'b0;
    assign iup_resp_error = 1'b0;
    assign iup_resp_id = '0;
    assign iup_resp_rdata = '0;
    assign walk_line_req_ready = 1'b0;
    assign walk_line_resp_valid = 1'b0;
    assign walk_line_resp_error = 1'b0;
    assign walk_line_resp_id = '0;
    assign walk_line_resp_rdata = '0;
    assign fence_i_sync_done = fence_i_sync_req;
    assign down_req_valid = 1'b0;
    assign down_req_write = 1'b0;
    assign down_req_addr = '0;
    assign down_req_wdata = '0;
    assign down_req_wstrb = '0;
    assign down_req_id = '0;
    // Legacy BRAM-only simulation behavior: cached data reads return zero,
    // while cached instruction fetch and walks are unavailable.
    logic [riscv_pkg::CachedLoadSlots-1:0] stub_read_pending_q;
    always_comb begin
      data_memory_cached_resp_id = '0;
      for (int slot = int'(riscv_pkg::CachedLoadSlots) - 1; slot >= 0; slot--) begin
        if (stub_read_pending_q[slot])
          data_memory_cached_resp_id = riscv_pkg::CachedLoadSlotBits'(slot);
      end
    end
    assign data_memory_cached_read_valid = |stub_read_pending_q;
    assign data_memory_cached_read_error = 1'b0;
    assign data_memory_cached_read_data = '0;
    assign data_memory_cached_write_inflight = 1'b0;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        stub_read_pending_q <= '0;
        data_memory_cached_write_done <= 1'b0;
      end else begin
        if (data_memory_cached_read_valid && data_memory_cached_read_ready)
          stub_read_pending_q[data_memory_cached_resp_id] <= 1'b0;
        if (data_memory_cached_read_enable) stub_read_pending_q[data_memory_cached_read_id] <= 1'b1;
        data_memory_cached_write_done <= |data_memory_cached_byte_write_enable;
      end
    end
  end

  cpu_uncached_adapter #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
      .DATA_BYTES(L2_LINE_BYTES),
      .DATA_PROT(AXI_MEMORY_PROT)
  ) uncached_adapter (
      .o_fatal_error(uncached_fatal),
      .o_fatal_addr(uncached_fatal_addr),
      .i_clk,
      .i_rst,
      .i_read_enable(uncached_read_enable && !o_fatal_error),
      .o_read_ready(uncached_read_request_ready),
      .i_read_addr(data_memory_address),
      .i_read_size(uncached_read_size),
      .i_read_device(!riscv_pkg::pma_memory_ok(cpu_data_mem_addr_xlen)),
      .o_read_valid(uncached_read_valid),
      .i_read_resp_ready(uncached_read_ready),
      .o_read_data(uncached_read_data),
      .o_read_status(uncached_read_status),
      .i_write_enable((|uncached_write_strb) && !o_fatal_error),
      .o_write_ready(),
      .i_write_addr(data_memory_address),
      .i_write_size(uncached_write_size),
      .i_write_buffered(uncached_write_buffered),
      .i_write_device(!riscv_pkg::pma_memory_ok(cpu_data_mem_addr_xlen)),
      .i_write_data(data_memory_write_data),
      .i_write_strb(uncached_write_strb),
      .o_write_done(uncached_write_done),
      .o_write_status(uncached_write_status),
      .o_write_inflight(uncached_write_inflight),
      .o_idle(),
      .o_req_valid(data_req_valid),
      .i_req_ready(data_req_ready),
      .o_req_write(data_req_write),
      .o_req_addr(data_req_addr),
      .o_req_size(data_req_size),
      .o_req_cache(data_req_cache),
      .o_req_prot(data_req_prot),
      .o_req_wdata(data_req_wdata),
      .o_req_wstrb(data_req_wstrb),
      .i_resp_valid(data_resp_valid),
      .i_resp_rdata(data_resp_data),
      .i_resp_status(data_resp_status),
      .i_resp_ok(data_resp_ok)
  );

  cpu_memory_fabric #(
      .FETCH_BYTES(NormalFetchBytes),
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
      .i_data_valid(data_req_valid),
      .o_data_ready(data_req_ready),
      .i_data_write(data_req_write),
      .i_data_addr(data_req_addr),
      .i_data_size(data_req_size),
      .i_data_cache(data_req_cache),
      .i_data_prot(data_req_prot),
      .i_data_wdata(data_req_wdata),
      .i_data_wstrb(data_req_wstrb),
      .o_data_resp_valid(data_resp_valid),
      .o_data_resp_data(data_resp_data),
      .o_data_resp_status(data_resp_status),
      .o_data_resp_ok(data_resp_ok),
      .i_fetch_valid(low_req_valid),
      .o_fetch_ready(low_req_ready),
      .i_fetch_addr(low_req_addr),
      .i_fetch_id(low_req_id),
      .o_fetch_resp_valid(low_resp_valid),
      .o_fetch_resp_id(low_resp_id),
      .o_fetch_resp_data(low_resp_data),
      .o_fetch_resp_error(low_resp_error),
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
  always @(posedge i_clk) begin
    if (i_rst)
      assert (!i_boot_addr[0])
      else $error("cpu_top: boot address must be halfword aligned");
    if (!i_rst && ENABLE_COHERENCE && i_coherent_req_valid)
      assert (coherent_address_ok)
      else $error("cpu_top: coherent request outside cached memory");
  end
`endif
endmodule
