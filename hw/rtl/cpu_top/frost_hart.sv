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

// One hart: the pipeline with its MMUs, walker, L0 and IMSIC files
// (cpu_ooo), the cached and uncached instruction fetch providers, the private
// L1D and L1I (frost_hart_cache), and the uncached data adapter. Cached data
// accesses reach the L1D through cached_tier_adapter, and the cached fetch
// provider requests lines from the L1I directly. Its line, probe, coherence,
// uncached data and uncached fetch ports lead to frost_cluster_memory, and
// cpu_top composes the two. See cpu_top/README.md.
module frost_hart #(
    parameter bit COHERENT_CLUSTER = 1'b0,
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
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned L1D_NUM_MSHR = 8,
    parameter int unsigned SIM_FAST_MAINT = 0,
    parameter int unsigned PERF_COUNTERS = 0,
    // The uncached data port: one beat of the outgoing AXI data bus (cpu_top
    // L2_LINE_BYTES), and the tile's AXI protection domain.
    parameter int unsigned DATA_BYTES = 64,
    parameter logic [2:0] DATA_PROT = 3'b011,
    // Line ports to the shared level: 32-byte lines and 4-bit ids, which the
    // L1D's {type, slot} ids need for 8 miss slots.
    localparam int unsigned L1LineBytes = 32,
    localparam int unsigned LineIdBits = 4,
    // L1D upstream ids, which carry the DMA probes (frost_hart_cache).
    localparam int unsigned ProbeIdxBitsMin = $clog2(riscv_pkg::DmaCoherenceLocks + 1),
    localparam int unsigned ProbeIdxBits =
        (LineIdBits > ProbeIdxBitsMin) ? LineIdBits : ProbeIdxBitsMin,
    localparam int unsigned L1dIdBits = ProbeIdxBits + 1,
    // Bytes per uncached instruction fetch: a 32-byte line with the Normal
    // read cache, else an aligned 8-byte block.
    localparam int unsigned NormalFetchBytes = CACHE_NORMAL_MEMORY ? 32 : 8
) (
    input logic i_clk,
    input logic i_rst,
    input logic [riscv_pkg::XLEN-1:0] i_boot_addr,
    input riscv_pkg::interrupt_t i_interrupts,
    input logic i_seip,
    // One MSI per cycle; level 0 is machine, level 1 supervisor.
    input logic i_msi_valid,
    input logic i_msi_level,
    input logic [10:0] i_msi_id,
    input logic [63:0] i_mtime,
    input logic i_disable_branch_prediction,
    input logic i_dbg_haltreq,
    input logic i_dbg_go,
    input logic [31:0] i_dbg_go_addr,
    input logic [63:0] i_dbg_data,
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

    // Fatal stop. i_fatal_error is the tile's sticky fatal indication, and
    // i_fatal_stop adds the failures reported in this cycle, the hart's own
    // and the shared level's. The hart reports its caches' and its uncached
    // adapter's failures separately.
    input logic i_fatal_error,
    input logic i_fatal_stop,
    output logic o_cache_fatal,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_cache_fatal_addr,
    output logic o_uncached_fatal,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_uncached_fatal_addr,

    // Source-registered performance observers of the L1s and the cached fetch
    // provider, and the assembled cache events for the hart's counters.
    output cache_perf_pkg::cache_instance_perf_events_t o_l1d_perf_events,
    output cache_perf_pkg::cache_instance_perf_events_t o_l1i_perf_events,
    output logic o_l1i_fetch_miss_stall,
    input cache_perf_pkg::cache_perf_events_t i_cache_perf_events,

    output logic o_coherent_d_valid,
    input logic i_coherent_d_ready,
    output logic [riscv_pkg::PhysAddrBits+311:0] o_coherent_d,
    input logic i_coherent_p_valid,
    output logic o_coherent_p_ready,
    input logic [riscv_pkg::PhysAddrBits+29:0] i_coherent_p,
    output logic o_coherent_r_valid,
    input logic i_coherent_r_ready,
    output logic [riscv_pkg::PhysAddrBits+274:0] o_coherent_r,
    output logic o_coherent_w_valid,
    input logic i_coherent_w_ready,
    output logic [riscv_pkg::PhysAddrBits+259:0] o_coherent_w,
    input logic i_coherent_wa_valid,
    output logic o_coherent_wa_ready,
    input logic [riscv_pkg::PhysAddrBits+10:0] i_coherent_wa,
    input logic i_coherent_g_valid,
    output logic o_coherent_g_ready,
    input logic [riscv_pkg::PhysAddrBits+274:0] i_coherent_g,
    output logic o_coherent_c_valid,
    input logic i_coherent_c_ready,
    output logic [riscv_pkg::PhysAddrBits+17:0] o_coherent_c,
    input logic i_coherent_u_valid,
    output logic o_coherent_u_ready,
    input logic [riscv_pkg::PhysAddrBits+14:0] i_coherent_u,

    // The L1D's downstream line port (master).
    output logic o_l1d_down_req_valid,
    input logic i_l1d_down_req_ready,
    output logic o_l1d_down_req_write,
    output logic o_l1d_down_req_maintenance,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_l1d_down_req_addr,
    output logic [L1LineBytes*8-1:0] o_l1d_down_req_wdata,
    output logic [L1LineBytes-1:0] o_l1d_down_req_wstrb,
    output logic [LineIdBits-1:0] o_l1d_down_req_id,
    input logic i_l1d_down_resp_valid,
    input logic [LineIdBits-1:0] i_l1d_down_resp_id,
    input logic [L1LineBytes*8-1:0] i_l1d_down_resp_rdata,
    input logic i_l1d_down_resp_error,

    // The L1I's downstream line port (master).
    output logic o_l1i_down_req_valid,
    input logic i_l1i_down_req_ready,
    output logic o_l1i_down_req_write,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_l1i_down_req_addr,
    output logic [L1LineBytes*8-1:0] o_l1i_down_req_wdata,
    output logic [L1LineBytes-1:0] o_l1i_down_req_wstrb,
    output logic [LineIdBits-2:0] o_l1i_down_req_id,
    input logic i_l1i_down_resp_valid,
    input logic [LineIdBits-2:0] i_l1i_down_resp_id,
    input logic [L1LineBytes*8-1:0] i_l1i_down_resp_rdata,
    input logic i_l1i_down_resp_error,

    // The walker sequencer's line port (master).
    output logic o_walk_down_req_valid,
    input logic i_walk_down_req_ready,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_walk_down_req_addr,
    output logic [LineIdBits-2:0] o_walk_down_req_id,
    input logic i_walk_down_resp_valid,
    input logic [LineIdBits-2:0] i_walk_down_resp_id,
    input logic [L1LineBytes*8-1:0] i_walk_down_resp_rdata,
    input logic i_walk_down_resp_error,

    // DMA probes into the L1D, with their acknowledgements and releases.
    input logic i_dma_probe_req_valid,
    output logic o_dma_probe_req_ready,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_dma_probe_req_addr,
    input logic i_dma_probe_req_inval,
    input logic [L1dIdBits-1:0] i_dma_probe_req_id,
    output logic o_dma_probe_ack_valid,
    output logic [L1dIdBits-1:0] o_dma_probe_ack_id,
    input logic i_dma_probe_release_valid,
    input logic [L1dIdBits-1:0] i_dma_probe_release_id,

    // Load-queue coherence handshake for DMA writes.
    input logic i_coh_admit_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_admit_slot,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_coh_admit_addr,
    output logic o_coh_admit_ready,
    input logic i_coh_inval_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_inval_slot,
    output logic o_coh_inval_done,
    input logic i_coh_release_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_release_slot,

    // Uncached and Device data, from the uncached adapter.
    output logic o_data_req_valid,
    input logic i_data_req_ready,
    output logic o_data_req_write,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_data_req_addr,
    output logic [2:0] o_data_req_size,
    output logic [3:0] o_data_req_cache,
    output logic [2:0] o_data_req_prot,
    output logic [DATA_BYTES*8-1:0] o_data_req_wdata,
    output logic [DATA_BYTES-1:0] o_data_req_wstrb,
    input logic i_data_resp_valid,
    input logic [DATA_BYTES*8-1:0] i_data_resp_data,
    input logic [1:0] i_data_resp_status,
    input logic i_data_resp_ok,

    // Uncached instruction fetch, from the uncached fetch provider.
    output logic o_fetch_req_valid,
    input logic i_fetch_req_ready,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_req_addr,
    output logic o_fetch_req_id,
    input logic i_fetch_resp_valid,
    input logic i_fetch_resp_id,
    input logic [NormalFetchBytes*8-1:0] i_fetch_resp_data,
    input logic i_fetch_resp_error
);
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
  logic uncached_write_buffered;
  logic coherent_store_pending;
  logic coherent_store_ready;
  logic coherent_sc_pending;
  logic coherent_atomic_live;
  logic [1:0] coherent_block_valid;
  logic [1:0][riscv_pkg::XLEN-1:0] coherent_block_addr;
  logic coherent_cut_hold;
  logic coherent_sc_valid;
  logic coherent_sc_ready;
  logic [riscv_pkg::XLEN-1:0] coherent_sc_addr;
  logic [2:0] coherent_sc_size;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_sc_tag;
  logic coherent_sc_result_valid;
  logic coherent_sc_result_ready;
  logic coherent_sc_success;
  logic coherent_sc_error;
  logic coherent_sc_write_done;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_sc_write_tag;
  logic coherent_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] coherent_reservation_addr;
  logic [2:0] coherent_reservation_size;
  logic [1:0] coherent_read_kind;
  logic [2:0] coherent_read_size;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_read_tag;
  logic coherent_write_atomic;
  logic coherent_write_sc;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_write_tag;
  logic coherent_atomic_protected;
  logic coherent_sc_commit;
  logic cut_admit, cut_inval, cut_release;
  logic [riscv_pkg::PhysAddrBits-1:0] cut_addr;
  logic [1:0][riscv_pkg::PhysAddrBits-1:0] block_addr;
  assign coherent_block_addr = {riscv_pkg::XLEN'(block_addr[1]), riscv_pkg::XLEN'(block_addr[0])};
  localparam longint unsigned CachedBase = riscv_pkg::DdrBase;
  localparam longint unsigned CachedSizeBytes = riscv_pkg::DdrCapacityBytes;
  cpu_ooo #(
      .COHERENT_CLUSTER(COHERENT_CLUSTER && ENABLE_CACHED_TIER != 0),
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
      .i_coherent_store_pending(coherent_store_pending),
      .i_coherent_store_ready(coherent_store_ready),
      .i_coherent_sc_pending(coherent_sc_pending),
      .i_coherent_atomic_live(coherent_atomic_live),
      .i_coherent_block_valid(coherent_block_valid),
      .i_coherent_block_addr(coherent_block_addr),
      .i_coherent_cut_hold(coherent_cut_hold),
      .o_coherent_sc_valid(coherent_sc_valid),
      .i_coherent_sc_ready(coherent_sc_ready),
      .o_coherent_sc_addr(coherent_sc_addr),
      .o_coherent_sc_size(coherent_sc_size),
      .o_coherent_sc_tag(coherent_sc_tag),
      .i_coherent_sc_result_valid(coherent_sc_result_valid),
      .o_coherent_sc_result_ready(coherent_sc_result_ready),
      .i_coherent_sc_success(coherent_sc_success),
      .i_coherent_sc_error(coherent_sc_error),
      .i_coherent_sc_write_done(coherent_sc_write_done),
      .i_coherent_sc_write_tag(coherent_sc_write_tag),
      .o_coherent_reservation_valid(coherent_reservation_valid),
      .o_coherent_reservation_addr(coherent_reservation_addr),
      .o_coherent_reservation_size(coherent_reservation_size),
      .o_coherent_read_kind(coherent_read_kind),
      .o_coherent_read_size(coherent_read_size),
      .o_coherent_read_tag(coherent_read_tag),
      .o_coherent_write_atomic(coherent_write_atomic),
      .o_coherent_write_sc(coherent_write_sc),
      .o_coherent_write_tag(coherent_write_tag),
      .o_coherent_atomic_protected(coherent_atomic_protected),
      .o_coherent_sc_commit(coherent_sc_commit),
      .i_clk,
      .i_boot_addr,
      .i_fatal_stop(i_fatal_stop),
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
      .i_coh_admit_valid(COHERENT_CLUSTER ? cut_admit : i_coh_admit_valid),
      .i_coh_admit_slot(COHERENT_CLUSTER ? '0 : i_coh_admit_slot),
      .i_coh_admit_addr(riscv_pkg::XLEN'(COHERENT_CLUSTER ? cut_addr : i_coh_admit_addr)),
      .o_coh_admit_ready(o_coh_admit_ready),
      .i_coh_inval_valid(COHERENT_CLUSTER ? cut_inval : i_coh_inval_valid),
      .i_coh_inval_slot(COHERENT_CLUSTER ? '0 : i_coh_inval_slot),
      .o_coh_inval_done(o_coh_inval_done),
      .i_coh_release_valid(COHERENT_CLUSTER ? cut_release : i_coh_release_valid),
      .i_coh_release_slot(COHERENT_CLUSTER ? '0 : i_coh_release_slot),
      .i_cache_perf_events(i_cache_perf_events),
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
      fetch_valid[provider_q] && !i_fatal_error;
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
      .i_pipeline_stall(pipeline_stall || i_fatal_error),
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
      .o_line_req_valid(o_fetch_req_valid),
      .i_line_req_ready(i_fetch_req_ready),
      .o_line_req_write(),
      .o_line_req_addr(o_fetch_req_addr),
      .o_line_req_wdata(),
      .o_line_req_wstrb(),
      .o_line_req_id(o_fetch_req_id),
      .i_line_resp_valid(i_fetch_resp_valid),
      .i_line_resp_error(i_fetch_resp_error),
      .i_line_resp_id(i_fetch_resp_id),
      .i_line_resp_rdata(i_fetch_resp_data)
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
      .i_pipeline_stall(pipeline_stall || i_fatal_error),
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
      .i_l1i_miss_outstanding(|o_l1i_perf_events.miss_outstanding),
      .o_perf_miss_stall(o_l1i_fetch_miss_stall),
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

  if (ENABLE_CACHED_TIER != 0 && !COHERENT_CLUSTER) begin : gen_cached_tier
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

    frost_hart_cache #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .ENABLE_RESPONSE_ERRORS(1'b1),
        .L1_LINE_BYTES(L1LineBytes),
        .UP_ID_BITS(LineIdBits),
        .L1_CACHE_BYTES(L1_CACHE_BYTES),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1D_WAYS(L1D_WAYS),
        .L1I_WAYS(L1I_WAYS),
        .L1D_NUM_MSHR(L1D_NUM_MSHR),
        .SIM_FAST_MAINT(SIM_FAST_MAINT),
        .NUM_DMA_LOCK(riscv_pkg::DmaCoherenceLocks)
    ) hart_cache (
        .o_up_resp_error(line_resp_error),
        .o_iup_resp_error(iup_resp_error),
        .o_wup_resp_error(walk_line_resp_error),
        .o_fatal_error(o_cache_fatal),
        .o_fatal_addr(o_cache_fatal_addr),

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
        .i_fence_sync(fence_i_sync_req),
        .o_fence_done(fence_i_sync_done),
        .o_l1d_down_req_valid(o_l1d_down_req_valid),
        .i_l1d_down_req_ready(i_l1d_down_req_ready),
        .o_l1d_down_req_write(o_l1d_down_req_write),
        .o_l1d_down_req_maintenance(o_l1d_down_req_maintenance),
        .o_l1d_down_req_addr(o_l1d_down_req_addr),
        .o_l1d_down_req_wdata(o_l1d_down_req_wdata),
        .o_l1d_down_req_wstrb(o_l1d_down_req_wstrb),
        .o_l1d_down_req_id(o_l1d_down_req_id),
        .i_l1d_down_resp_valid(i_l1d_down_resp_valid),
        .i_l1d_down_resp_id(i_l1d_down_resp_id),
        .i_l1d_down_resp_rdata(i_l1d_down_resp_rdata),
        .i_l1d_down_resp_error(i_l1d_down_resp_error),
        .o_l1i_down_req_valid(o_l1i_down_req_valid),
        .i_l1i_down_req_ready(i_l1i_down_req_ready),
        .o_l1i_down_req_write(o_l1i_down_req_write),
        .o_l1i_down_req_addr(o_l1i_down_req_addr),
        .o_l1i_down_req_wdata(o_l1i_down_req_wdata),
        .o_l1i_down_req_wstrb(o_l1i_down_req_wstrb),
        .o_l1i_down_req_id(o_l1i_down_req_id),
        .i_l1i_down_resp_valid(i_l1i_down_resp_valid),
        .i_l1i_down_resp_id(i_l1i_down_resp_id),
        .i_l1i_down_resp_rdata(i_l1i_down_resp_rdata),
        .i_l1i_down_resp_error(i_l1i_down_resp_error),
        .o_walk_down_req_valid(o_walk_down_req_valid),
        .i_walk_down_req_ready(i_walk_down_req_ready),
        .o_walk_down_req_addr(o_walk_down_req_addr),
        .o_walk_down_req_id(o_walk_down_req_id),
        .i_walk_down_resp_valid(i_walk_down_resp_valid),
        .i_walk_down_resp_id(i_walk_down_resp_id),
        .i_walk_down_resp_rdata(i_walk_down_resp_rdata),
        .i_walk_down_resp_error(i_walk_down_resp_error),
        // DMA probes from the shared level's DMA sequencer.
        .i_dma_probe_req_valid(i_dma_probe_req_valid),
        .o_dma_probe_req_ready(o_dma_probe_req_ready),
        .i_dma_probe_req_addr(i_dma_probe_req_addr),
        .i_dma_probe_req_inval(i_dma_probe_req_inval),
        .i_dma_probe_req_id(i_dma_probe_req_id),
        .o_dma_probe_ack_valid(o_dma_probe_ack_valid),
        .o_dma_probe_ack_id(o_dma_probe_ack_id),
        .i_dma_probe_release_valid(i_dma_probe_release_valid),
        .i_dma_probe_release_id(i_dma_probe_release_id),
        .o_l1d_perf_events(o_l1d_perf_events),
        .o_l1i_perf_events(o_l1i_perf_events)
    );


  end else if (ENABLE_CACHED_TIER != 0) begin : gen_coherent_tier
    coherent_hart_cache #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .CACHE_BYTES(L1_CACHE_BYTES),
        .WAYS(L1D_WAYS),
        .TAG_BITS(riscv_pkg::ReorderBufferTagWidth),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1I_WAYS(L1I_WAYS),
        .SIM_FAST_MAINT(SIM_FAST_MAINT)
    ) hart_cache (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_stop),
        .i_read_valid(data_memory_cached_read_enable),
        .i_read_id(data_memory_cached_read_id),
        .i_read_kind(coherent_read_kind),
        .i_read_size(coherent_read_size),
        .i_read_tag(coherent_read_tag),
        .i_address(data_memory_address),
        .o_read_valid(data_memory_cached_read_valid),
        .i_read_ready(data_memory_cached_read_ready),
        .o_read_id(data_memory_cached_resp_id),
        .o_read_data(data_memory_cached_read_data),
        .o_read_error(data_memory_cached_read_error),
        .i_write_mask(data_memory_cached_byte_write_enable),
        .i_write_data(data_memory_cached_write_data),
        .i_write_atomic(coherent_write_atomic),
        .i_write_sc(coherent_write_sc),
        .i_write_tag(coherent_write_tag),
        .o_write_done(data_memory_cached_write_done),
        .o_write_inflight(data_memory_cached_write_inflight),
        .o_store_ready(coherent_store_ready),
        .o_pending_store(coherent_store_pending),
        .o_sc_write_pending(coherent_sc_pending),
        .o_atomic_live(coherent_atomic_live),
        .o_block_valid(coherent_block_valid),
        .o_block_addr(block_addr),
        .i_atomic_protected(coherent_atomic_protected),
        .i_sc_valid(coherent_sc_valid),
        .o_sc_ready(coherent_sc_ready),
        .i_sc_address(coherent_sc_addr[riscv_pkg::PhysAddrBits-1:0]),
        .i_sc_size(coherent_sc_size),
        .i_sc_tag(coherent_sc_tag),
        .i_sc_commit(coherent_sc_commit),
        .o_sc_result_valid(coherent_sc_result_valid),
        .i_sc_result_ready(coherent_sc_result_ready),
        .o_sc_success(coherent_sc_success),
        .o_sc_error(coherent_sc_error),
        .o_sc_write_done(coherent_sc_write_done),
        .o_sc_write_tag(coherent_sc_write_tag),
        .i_reservation_valid(coherent_reservation_valid),
        .i_reservation_addr(coherent_reservation_addr[riscv_pkg::PhysAddrBits-1:0]),
        .i_reservation_size(coherent_reservation_size),
        .o_cut_hold(coherent_cut_hold),
        .o_cut_admit_valid(cut_admit),
        .i_cut_admit_ready(o_coh_admit_ready),
        .o_cut_address(cut_addr),
        .o_cut_inval_valid(cut_inval),
        .i_cut_inval_done(o_coh_inval_done),
        .o_cut_release(cut_release),
        .o_d_valid(o_coherent_d_valid),
        .i_d_ready(i_coherent_d_ready),
        .o_d(o_coherent_d),
        .i_p_valid(i_coherent_p_valid),
        .o_p_ready(o_coherent_p_ready),
        .i_p(i_coherent_p),
        .o_r_valid(o_coherent_r_valid),
        .i_r_ready(i_coherent_r_ready),
        .o_r(o_coherent_r),
        .o_w_valid(o_coherent_w_valid),
        .i_w_ready(i_coherent_w_ready),
        .o_w(o_coherent_w),
        .i_wa_valid(i_coherent_wa_valid),
        .o_wa_ready(o_coherent_wa_ready),
        .i_wa(i_coherent_wa),
        .i_g_valid(i_coherent_g_valid),
        .o_g_ready(o_coherent_g_ready),
        .i_g(i_coherent_g),
        .o_c_valid(o_coherent_c_valid),
        .i_c_ready(i_coherent_c_ready),
        .o_c(o_coherent_c),
        .i_u_valid(i_coherent_u_valid),
        .o_u_ready(o_coherent_u_ready),
        .i_u(i_coherent_u),
        .i_iup_req_valid(iup_req_valid),
        .o_iup_req_ready(iup_req_ready),
        .i_iup_req_addr(iup_req_addr),
        .i_iup_req_id(iup_req_id),
        .o_iup_resp_valid(iup_resp_valid),
        .o_iup_resp_id(iup_resp_id),
        .o_iup_resp_data(iup_resp_rdata),
        .o_iup_resp_error(iup_resp_error),
        .i_walk_req_valid(walk_line_req_valid),
        .o_walk_req_ready(walk_line_req_ready),
        .i_walk_req_addr(walk_line_req_addr),
        .i_walk_req_id(walk_line_req_id),
        .o_walk_resp_valid(walk_line_resp_valid),
        .o_walk_resp_id(walk_line_resp_id),
        .o_walk_resp_data(walk_line_resp_rdata),
        .o_walk_resp_error(walk_line_resp_error),
        .i_fence_sync(fence_i_sync_req),
        .o_fence_done(fence_i_sync_done),
        .o_l1i_perf_events(o_l1i_perf_events),
        .o_fatal(o_cache_fatal),
        .o_fatal_addr(o_cache_fatal_addr)
    );
    assign o_l1d_perf_events = '0;
    assign o_l1d_down_req_valid = 1'b0;
    assign o_l1d_down_req_write = 1'b0;
    assign o_l1d_down_req_maintenance = 1'b0;
    assign o_l1d_down_req_addr = '0;
    assign o_l1d_down_req_wdata = '0;
    assign o_l1d_down_req_wstrb = '0;
    assign o_l1d_down_req_id = '0;
    assign o_l1i_down_req_valid = 1'b0;
    assign o_l1i_down_req_write = 1'b0;
    assign o_l1i_down_req_addr = '0;
    assign o_l1i_down_req_wdata = '0;
    assign o_l1i_down_req_wstrb = '0;
    assign o_l1i_down_req_id = '0;
    assign o_walk_down_req_valid = 1'b0;
    assign o_walk_down_req_addr = '0;
    assign o_walk_down_req_id = '0;
    assign o_dma_probe_req_ready = 1'b0;
    assign o_dma_probe_ack_valid = 1'b0;
    assign o_dma_probe_ack_id = '0;
  end else begin : gen_no_cached_tier
    assign o_cache_fatal = 1'b0;
    assign o_cache_fatal_addr = '0;
    assign o_l1d_perf_events = '0;
    assign o_l1i_perf_events = '0;
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
    assign o_l1d_down_req_valid = 1'b0;
    assign o_l1d_down_req_write = 1'b0;
    assign o_l1d_down_req_maintenance = 1'b0;
    assign o_l1d_down_req_addr = '0;
    assign o_l1d_down_req_wdata = '0;
    assign o_l1d_down_req_wstrb = '0;
    assign o_l1d_down_req_id = '0;
    assign o_l1i_down_req_valid = 1'b0;
    assign o_l1i_down_req_write = 1'b0;
    assign o_l1i_down_req_addr = '0;
    assign o_l1i_down_req_wdata = '0;
    assign o_l1i_down_req_wstrb = '0;
    assign o_l1i_down_req_id = '0;
    assign o_walk_down_req_valid = 1'b0;
    assign o_walk_down_req_addr = '0;
    assign o_walk_down_req_id = '0;
    assign o_dma_probe_req_ready = 1'b0;
    assign o_dma_probe_ack_valid = 1'b0;
    assign o_dma_probe_ack_id = '0;
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

  if (!COHERENT_CLUSTER || ENABLE_CACHED_TIER == 0) begin : gen_no_coherent_channels
    assign o_coherent_d_valid = '0;
    assign o_coherent_d = '0;
    assign o_coherent_p_ready = '0;
    assign o_coherent_r_valid = '0;
    assign o_coherent_r = '0;
    assign o_coherent_w_valid = '0;
    assign o_coherent_w = '0;
    assign o_coherent_wa_ready = '0;
    assign o_coherent_g_ready = '0;
    assign o_coherent_c_valid = '0;
    assign o_coherent_c = '0;
    assign o_coherent_u_ready = '0;
    assign coherent_store_pending = '0;
    assign coherent_store_ready = 1;
    assign coherent_sc_pending = '0;
    assign coherent_atomic_live = '0;
    assign coherent_block_valid = '0;
    assign coherent_cut_hold = '0;
    assign coherent_sc_ready = '0;
    assign coherent_sc_result_valid = '0;
    assign coherent_sc_success = '0;
    assign coherent_sc_error = '0;
    assign coherent_sc_write_done = '0;
    assign coherent_sc_write_tag = '0;
    assign block_addr = '0;
    assign cut_admit = '0;
    assign cut_inval = '0;
    assign cut_release = '0;
    assign cut_addr = '0;
  end

  cpu_uncached_adapter #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
      .DATA_BYTES(DATA_BYTES),
      .DATA_PROT(DATA_PROT)
  ) uncached_adapter (
      .o_fatal_error(o_uncached_fatal),
      .o_fatal_addr(o_uncached_fatal_addr),
      .i_clk,
      .i_rst,
      .i_read_enable(uncached_read_enable && !i_fatal_error),
      .o_read_ready(uncached_read_request_ready),
      .i_read_addr(data_memory_address),
      .i_read_size(uncached_read_size),
      .i_read_device(!riscv_pkg::pma_memory_ok(cpu_data_mem_addr_xlen)),
      .o_read_valid(uncached_read_valid),
      .i_read_resp_ready(uncached_read_ready),
      .o_read_data(uncached_read_data),
      .o_read_status(uncached_read_status),
      .i_write_enable((|uncached_write_strb) && !i_fatal_error),
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
      .o_req_valid(o_data_req_valid),
      .i_req_ready(i_data_req_ready),
      .o_req_write(o_data_req_write),
      .o_req_addr(o_data_req_addr),
      .o_req_size(o_data_req_size),
      .o_req_cache(o_data_req_cache),
      .o_req_prot(o_data_req_prot),
      .o_req_wdata(o_data_req_wdata),
      .o_req_wstrb(o_data_req_wstrb),
      .i_resp_valid(i_data_resp_valid),
      .i_resp_rdata(i_data_resp_data),
      .i_resp_status(i_data_resp_status),
      .i_resp_ok(i_data_resp_ok)
  );
`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (i_rst)
      assert (!i_boot_addr[0])
      else $error("frost_hart: boot address must be halfword aligned");
  end
`endif
endmodule
