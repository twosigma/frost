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
 * FROST CPU top level (RV64GCB). The in-order IF/PD/ID front end fetches and
 * decodes up to two instructions per cycle; dispatch renames them into the
 * Tomasulo back end (tomasulo_wrapper), which executes out of order and
 * commits in program order. Register-file writes and CSR instructions take
 * effect only at ROB commit. Mispredicted conditional branches normally
 * recover as soon as they resolve, and every other misprediction at commit;
 * traps, xRETs, and FENCE-class instructions flush the whole pipeline. The
 * "Inside cpu_ooo" section of the CPU README lists the glue logic kept in
 * this file.
 */

// A simulation build selects CBO_INVAL_AS_FLUSH with
// -DFROST_CBO_INVAL_AS_FLUSH=1 (cbo.inval then always executes as cbo.flush).
`ifndef FROST_CBO_INVAL_AS_FLUSH
`define FROST_CBO_INVAL_AS_FLUSH 0
`endif
module cpu_ooo #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b0,
    // Zicbom CMOs of cached DDR go to the hierarchy (store_queue CMO_HOME).
    parameter bit CMO_HOME = 1'b0,
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter bit VARIABLE_UNCACHED = 1'b0,
    // MMIO register window base, by default the PMA's (riscv_pkg).
    parameter int unsigned MMIO_ADDR = riscv_pkg::MmioWindowAddr,
    // Cached tier: loads and stores to [CACHED_BASE, CACHED_BASE +
    // CACHED_SIZE_BYTES) go to the cache hierarchy and complete by handshake,
    // with variable latency. VARIABLE_UNCACHED likewise waits for the external
    // uncached response; its zero setting retains the one-cycle test profile.
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    // 1 when the hart's coherence line client is present for cached DDR
    // (frost_hart ENABLE_CACHED_TIER != 0). Standalone cpu_ooo benches leave
    // it 0 so vector memory ops fault cleanly instead of waiting on an unwired
    // line client.
    parameter bit CACHED_TIER_EN = 1'b0,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    // Cached loads read memory during the store-queue probe (load_queue
    // PROBE_LAUNCH); gated by CACHED_TIER_EN below so non-cached builds stay off.
    parameter bit LQ_PROBE_LAUNCH = 1'b1,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    // Profiling counters: perf_counter_aggregator, the wrapper's
    // tomasulo_perf_counters and the CSR file's mperf* state. With 0, the
    // mperf* CSRs read zero. Architectural HPM3..10 consume their events
    // independently of this profiling option.
    parameter int unsigned PERF_COUNTERS = 0,
    // Sets of the second-level TLB in front of the walker (four ways each:
    // 512 sets are 2,048 entries). Zero removes it and sends every L1 miss to
    // the walker.
    parameter int unsigned L2TLB_SETS = 512,
    // Vector unit: VECTOR=1 adds the vector state, VLEN is the vector
    // register width (128, 256 or 512), and VECTOR_ADVERTISE sets misa.V.
    parameter bit VECTOR = 1'b0,
    parameter int unsigned VLEN = 256,
    parameter bit VECTOR_ADVERTISE = 1'b0,
    // Misaligned plain loads and stores to cached DDR run on the
    // misaligned-access engine instead of trapping (misaligned/ma_engine.sv).
    // Its sector requests leave through the o_ma_line_* port.
    parameter bit MISALIGNED_HW = 1'b0,
    // Zicbom: execute cbo.inval as cbo.flush at every privilege (csr_file).
    parameter bit CBO_INVAL_AS_FLUSH = 1'(`FROST_CBO_INVAL_AS_FLUSH),
    // The walker's line port carries the L1s' 32-byte lines.
    localparam int unsigned WalkLineBytes = 32
) (
    // Coherent store ownership and selected atomic context.
    input logic i_coherent_store_pending = 1'b0,
    input logic i_coherent_store_ready = 1'b1,
    // The L1D's cbo.zero twin record, which counts as a store push of its own.
    input logic i_coherent_twin_push = 1'b0,
    input logic [riscv_pkg::XLEN-1:0] i_coherent_twin_push_addr = '0,
    input logic i_coherent_sc_pending = 1'b0,
    input logic i_coherent_atomic_live = 1'b0,
    input logic [3:0] i_coherent_block_valid = '0,
    input logic [3:0][riscv_pkg::XLEN-1:0] i_coherent_block_addr = '0,
    input logic i_coherent_cut_hold = 1'b0,
    output logic o_coherent_sc_valid,
    input logic i_coherent_sc_ready = 1'b0,
    output logic [riscv_pkg::XLEN-1:0] o_coherent_sc_addr,
    output logic [2:0] o_coherent_sc_size,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_sc_tag,
    input logic i_coherent_sc_result_valid = 1'b0,
    output logic o_coherent_sc_result_ready,
    input logic i_coherent_sc_success = 1'b0,
    input logic i_coherent_sc_error = 1'b0,
    input logic i_coherent_sc_write_done = 1'b0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_coherent_sc_write_tag = '0,
    output logic o_coherent_reservation_valid,
    output logic [riscv_pkg::XLEN-1:0] o_coherent_reservation_addr,
    output logic [2:0] o_coherent_reservation_size,
    output logic [1:0] o_coherent_read_kind,
    output logic [2:0] o_coherent_read_size,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_read_tag,
    output logic o_coherent_write_atomic,
    output logic o_coherent_write_sc,
    // A cached cbo.zero write (see coherence_l1d).
    output logic o_coherent_write_zero,
    // Zicbom requests for the coherent hierarchy (store_queue CMO_HOME).
    output logic o_cmo_valid,
    output riscv_pkg::cmo_kind_e o_cmo_kind,
    output logic [riscv_pkg::XLEN-1:0] o_cmo_addr,
    input logic i_cmo_ready = 1'b0,
    input logic i_cmo_done = 1'b0,
    output logic o_coherent_write_more,
    output logic o_coherent_next_same,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_write_tag,
    output logic o_coherent_atomic_protected,
    output logic o_coherent_sc_commit,
    input logic i_clk,
    input logic i_rst,
    input logic [XLEN-1:0] i_boot_addr = '0,
    input logic i_fatal_stop = 1'b0,
    // Instruction memory interface. o_pc is the virtual fetch address (the
    // providers tag and match windows by it); the o_fetch_* results below are
    // its physical side (see if_stage / mmu/immu).
    output logic [XLEN-1:0] o_pc,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa0,  // PA of the window's word 0
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa1,  // PA of the next word
    output logic o_fetch_pa_valid,  // always with translation off; Sv39: o_pc's result is visible
    output logic o_fetch_fault0,  // word 0 unfetchable (deliver a fault-tagged window)
    output logic o_fetch_fault0_page,  // ...page fault (else access fault)
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_fetch_line_after_ok,  // the line after word 0's line is physically next
    output logic o_fetch_redirect,  // registered: retarget the low-BRAM presenter's stale request
    output logic o_fetch_cached_retarget,  // registered: redirect or FENCE-class flush
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    // i_instr's sources kept apart: the low BRAM's words in physical bank
    // order ({odd, even}), the cached provider's {next, current} window, and
    // which of the two i_instr carries (1: the cached window).
    input logic [63:0] i_instr_low_by_parity,
    input logic [63:0] i_instr_high,
    input logic i_instr_window_high,
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    // PC-only metadata replica. Each fetched word is ordered as
    // {pairable_native_hi, pairable_compressed_hi, compressed_hi, compressed_lo}.
    input logic [7:0] i_instr_pc_metadata,
    // Timing replicas in {cached odd, cached even, BRAM odd, BRAM even}
    // provider/parity order. IF chooses the active lane directly from the live
    // provider and PC parity.
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    // Same-cycle provider-select copy for PC metadata and served-window
    // selects, for fanout.
    input logic i_instr_pc_metadata_served_high,
    input logic i_instr_bank_sel_r,  // Fetch-word parity (for spanning select)
    // Word tags (address bits [31:2]) that each provider registers beside its
    // window, with the next and previous word, for IF's served-window check.
    // IF compares against both providers in parallel and selects the results.
    input logic [riscv_pkg::XLEN-3:0] i_served_word_low,
    input logic [riscv_pkg::XLEN-3:0] i_served_last_word_low,
    input logic [riscv_pkg::XLEN-3:0] i_served_prev_word_low,
    input logic i_served_prev_word_valid_low,
    input logic [riscv_pkg::XLEN-3:0] i_served_word_high,
    input logic [riscv_pkg::XLEN-3:0] i_served_last_word_high,
    input logic [riscv_pkg::XLEN-3:0] i_served_prev_word_high,
    input logic i_served_prev_word_valid_high,
    // Fetch window valid (see if_stage). Low BRAM may withhold it for a
    // metadata fallback miss or a captured-response publication hold.
    input logic i_instr_valid,
    // Served window's per-word fault flags and its provider (see if_stage).
    input logic i_instr_fault0,
    input logic i_instr_fault0_page,
    input logic i_instr_fault1,
    input logic i_instr_fault1_page,
    input logic i_served_high,
    // Registered: IF consumed its stall-replay bundle last cycle (see
    // if_stage). The fetch provider uses it to classify the PC movement it
    // then sees as normal flow rather than a redirect.
    output logic o_fetch_replay_consume,
    // Live provider response consumed or captured by IF this cycle. Slow low-
    // BRAM responses use this to distinguish publication from a squash.
    output logic o_fetch_live_claim,
    // Front-end stall (pipeline_ctrl.stall) for the fetch providers. The
    // low-BRAM path holds publication on a registered copy, because IF
    // captures the live window on the first stall cycle and replays it once.
    output logic o_pipeline_stall,
    // FENCE-class support. The cache-sync handshake is for FENCE.I and
    // SFENCE.VMA only: the request is held while the ROB serializer stalls
    // the head, and done is a level while the request is high. The registered
    // flush pulse also follows a translation CSR's retirement, and it drops
    // the fetch provider's buffered lines before the refetch.
    output logic o_fence_i_sync_req,
    input logic i_fence_i_sync_done,
    output logic o_fence_i_flush,
    // Page-table walker line port: read-only master to the wup port of the
    // hart's caches (frost_hart wires it through and zero-extends the 2-bit
    // ids to the port's width); the walker issues one walk at a time.
    output logic o_walk_line_req_valid,
    input logic i_walk_line_req_ready,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_walk_line_req_addr,
    output logic [1:0] o_walk_line_req_id,
    input logic i_walk_line_resp_valid,
    input logic i_walk_line_resp_error = 1'b0,
    input logic [1:0] i_walk_line_resp_id,
    input logic [WalkLineBytes*8-1:0] i_walk_line_resp_rdata,
    // Misaligned-access engine's line-client port (MISALIGNED_HW): 32-byte
    // sector reads and masked writes, request identities 0 and 1.
    output logic o_ma_line_req_valid,
    input logic i_ma_line_req_ready = 1'b0,
    output logic o_ma_line_req_write,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_ma_line_req_addr,
    output logic [255:0] o_ma_line_req_data,
    output logic [31:0] o_ma_line_req_mask,
    output logic [3:0] o_ma_line_req_id,
    input logic i_ma_line_resp_valid = 1'b0,
    input logic [3:0] i_ma_line_resp_id = '0,
    input logic [255:0] i_ma_line_resp_data = '0,
    input logic i_ma_line_resp_error = 1'b0,
    // A failed engine write: sticky until reset.
    output logic o_ma_fatal,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_ma_fatal_addr,
    // Data memory interface
    input logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    // BRAM write strobes exclude MMIO and cached writes using registered tier
    // flags. Peripherals use the unmasked o_data_mem_per_byte_wr_en.
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    output logic o_data_mem_read_enable,
    // Cached tier (high-address region). Tier-routed write/read requests
    // (already qualified by is_cached in the router) plus the handshake
    // completion inputs from coherent_hart_cache.
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    // Cached write data is the SQ drain value or the AMO result on its single
    // launch cycle. Cached AMOs run at the ROB head.
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic o_data_mem_cached_read_enable,
    // The cached read enable split on its late term, the live LQ launch:
    // enable == (sel ? if_sel : if_clear), with early cofactors.
    output logic o_data_mem_cached_read_sel,
    output logic o_data_mem_cached_read_if_sel,
    output logic o_data_mem_cached_read_if_clear,
    // Slot id of a cached read (several may be in flight); the adapter tags
    // its responses with it and holds a response while a fast-tier response
    // is using the LQ response port.
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id,
    // The cached read is an LR or an AMO: the adapter gives it a line request
    // of its own.
    output logic o_data_mem_cached_read_no_merge,
    input logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id,
    input logic i_cached_read_valid,
    input logic i_cached_read_error = 1'b0,
    output logic o_cached_read_ready,
    input logic i_cached_write_done,
    input logic i_cached_write_inflight,
    // Single-cycle handoffs to frost_hart's variable-latency uncached adapter.
    // Write data shares o_data_mem_wr_data; o_uncached_addr carries the
    // uncached request address without adding logic to the cached-tier address.
    input logic i_uncached_read_request_ready = 1'b1,
    output logic [XLEN-1:0] o_uncached_addr,
    output logic o_uncached_read_enable,
    output riscv_pkg::mem_size_e o_uncached_read_size,
    input logic i_uncached_read_valid = 1'b0,
    output logic o_uncached_read_ready,
    input logic [riscv_pkg::MemDataBits-1:0] i_uncached_read_data = '0,
    input logic [1:0] i_uncached_read_status = 2'b00,
    output logic [riscv_pkg::MemStrbBits-1:0] o_uncached_write_byte_en,
    output riscv_pkg::mem_size_e o_uncached_write_size,
    output logic o_uncached_write_buffered,
    input logic i_uncached_write_done = 1'b0,
    input logic [1:0] i_uncached_write_status = 2'b00,
    input logic i_uncached_write_inflight = 1'b0,
    // DMA coherence handshake: the cache hierarchy's sequencer to
    // the load queue's coherence port inside tomasulo_wrapper.
    input logic i_coh_admit_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_admit_slot,
    input logic [XLEN-1:0] i_coh_admit_addr,
    output logic o_coh_admit_ready,
    output logic o_coh_admit_clean,
    input logic i_coh_inval_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_inval_slot,
    output logic o_coh_inval_done,
    input logic i_coh_release_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_release_slot,
    // Passive, source-registered cache-hierarchy performance events.
    input cache_perf_pkg::cache_perf_events_t i_cache_perf_events,
    output logic o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic o_mmio_load_valid,
    output logic o_mmio_fifo0_read_pulse,
    output logic o_mmio_fifo1_read_pulse,
    output logic o_mmio_uart_rx_ready_pulse,
    // Status
    output logic o_rst_done,
    output logic o_vld,
    output logic o_pc_vld,
    // Interrupts
    input riscv_pkg::interrupt_t i_interrupts,
    input logic [63:0] i_mtime,
    // Supervisor external-interrupt line. csr_file ORs it into the SEIP
    // readback and the S-pending exports.
    input logic i_seip_line,
    input logic i_msi_valid = 1'b0,
    input logic i_msi_level = 1'b0,
    input logic [10:0] i_msi_id = '0,
    output logic [5:0] o_debug_irq_status,
    output logic [XLEN-1:0] o_debug_commit_pc,
    output logic [XLEN-1:0] o_debug_commit_2_pc,
    output logic [1:0] o_debug_commit_valid,
    // Debug
    input logic i_disable_branch_prediction,

    // Debug module interface: levels and pulses in the core clock domain.
    input  logic        i_dbg_haltreq,          // dmcontrol.haltreq
    input  logic        i_dbg_go,               // redirect a parked hart to i_dbg_go_addr
    input  logic [31:0] i_dbg_go_addr,
    input  logic [63:0] i_dbg_data,             // data0/data1 as the ddata CSR
    output logic        o_dbg_data_we,
    output logic [63:0] o_dbg_data_wdata,
    output logic        o_debug_mode,           // hart is in Debug Mode (halted)
    output logic        o_dbg_parked,           // ...and sits in the park loop (no command running)
    output logic        o_dbg_cmd_err,          // the last command ended in an exception
    output logic        o_dbg_go_taken,         // the go redirect fired (drop i_dbg_go)
    output logic        o_dbg_bram_store,       // a low-BRAM store landed this cycle (mirror)
    output logic [31:0] o_dbg_bram_store_addr,
    output logic [ 7:0] o_dbg_bram_store_strb
);

  // Active-low reset for Tomasulo modules
  logic rst_n;
  assign rst_n = ~i_rst;

  // ===========================================================================
  // Pipeline Control
  // ===========================================================================
  // ooo_pipeline_control builds pipeline_ctrl for IF/PD/ID. The stall comes
  // from dispatch back-pressure (with a decoded queue, from the queue being
  // full), CSR and control-flow serialization, and the fetch translation
  // hold. The flush controller registers the fetch flush alongside recovery.

  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  logic dispatch_stall;
  logic direct_id_valid_preflush, direct_id_valid_2_preflush;
  logic direct_id_valid, direct_id_valid_2;
  logic decoded_queue_full;
  // The decoded queue offers a bundle (its head) this cycle
  logic decoded_queue_valid;
  logic decoded_queue_indirect_pending;
  (* max_fanout = 32 *) logic flush_pipeline;
  logic fetch_flush;
  logic dispatch_flush;
  logic full_flush_side_effect_kill;
  logic flush_for_trap;
  logic flush_for_mret;
  riscv_pkg::dispatch_status_t dispatch_status;

  // Performance-counter interface between CSR, wrapper, and aggregator.
  logic [7:0] perf_counter_select;
  logic perf_snapshot_capture;
  logic perf_cache_previous_select;
  logic [63:0] perf_counter_data_q;
  logic [31:0] perf_counter_csr_half_q;
  logic [31:0] perf_counter_count;
  logic [7:0] wrapper_perf_counter_select;
  logic [63:0] wrapper_perf_counter_data;
  // Width-funnel perf observers from the tomasulo_wrapper (registered at
  // their sources): MEM_RS single-issue-port limiter and CDB oversubscription.
  logic perf_mem_rs_two_ready_one_issued;
  logic perf_cdb_oversubscribed;

  // CSR dispatch fence: the CDB carries rs1 (write operand) for CSR ops,
  // not the CSR read result (which is only available at commit). Stall
  // dispatch after a CSR until it commits and its register result is written
  // back, so no dependent instruction picks up the wrong CDB value.
  logic csr_in_flight;
  logic csr_wb_pending;
  // Front-end control-flow classification from frontend_validity_tracker,
  // for ooo_pipeline_control and the perf counters.
  logic front_end_indirect_control_flow_pending;
  logic prediction_fence_branch;
  logic prediction_fence_jal;
  logic prediction_fence_indirect;
  logic disable_branch_prediction_ooo;
  logic if_slot1_has_control_flow;
  logic if_slot1_is_indirect;
  (* max_fanout = 32 *) logic serializing_alloc_fire;
  logic csr_commit_fire;  // driven by commit_actions below
  logic csr_irq_update_q;
  logic branch_resolved_correct;  // branch resolved correctly at execute time
  logic [riscv_pkg::CheckpointIdWidth-1:0] branch_resolved_checkpoint_id;  // its checkpoint

  // Outputs of ooo_pipeline_control used elsewhere in this file.
  logic front_end_cf_serialize_stall;
  logic stall_q;
  logic id_stall_q;
  logic replay_after_dispatch_stall_q;
  logic replay_after_serialize_stall_q;
  logic [1:0] post_flush_holdoff_q;
  logic trap_taken_reg, mret_taken_reg;
  // High when no committed store is still waiting to write memory. Trap and
  // xRET entry, fences, atomics, and the router's device reads wait for it.
  logic sq_committed_empty;
  logic trap_drain_wait;
  logic [XLEN-1:0] trap_target_reg;

  logic fetch_pa_hold;  // if_stage: no visible result for the selected fetch VA yet
  // fetch_pa_hold from separate IMMU copies, for the decoded queue's shadow
  // select only.
  logic [riscv_pkg::FetchPaHoldCopies-1:0] fetch_pa_hold_copy;
  // The front-end stall without fetch_pa_hold, for the same select.
  logic frontend_stall_without_pa_hold;

  // Trap control
  riscv_pkg::trap_ctrl_t trap_ctrl;
  logic trap_taken, mret_taken;
  logic sret_taken;  // SRET pulse from the trap unit (rides the MRET machinery)
  logic trap_to_s;  // Trap targets S (delegated)
  // Any xRET (MRET, SRET, or DRET). Pipeline control, recovery, and the ROB
  // acknowledge treat the three alike; csr_file, the resume-PC seed, and the
  // debug logic use the separate pulses.
  logic xret_taken;
  logic [XLEN-1:0] trap_target;

  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req;
  riscv_pkg::reorder_buffer_commit_t rob_commit;  // registered: drives CSR/regfile/bypass

  // Slot-2 ROB allocation request + response.
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2_raw;
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp_2;
  logic [1:0] rob_alloc_q;  // ROB allocations on the last edge (bit 1: slot 2)

  logic rob_checkpoint_valid;
  logic [riscv_pkg::CheckpointIdWidth-1:0] rob_checkpoint_id;

  // Track checkpoint tags to reclaim younger checkpoints on partial flush.
  // Use packed arrays for module ports; Yosys rejects unpacked-array ports.
  logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;
  // Live checkpoints whose branch or JALR is unresolved (ooo_pipeline_control).
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_unresolved;

  ooo_pipeline_control #(
      .QUEUED_FRONTEND(DECODED_QUEUE_DEPTH != 0),
      .XLEN(XLEN)
  ) ooo_pipeline_control_inst (
      .i_clk,
      .i_rst,
      .i_rob_alloc_req(rob_alloc_req),
      .i_rob_alloc_req_2(rob_alloc_req_2),
      .i_rob_checkpoint_valid(rob_checkpoint_valid),
      .i_rob_checkpoint_id(rob_checkpoint_id),
      .i_checkpoint_in_use(checkpoint_in_use),
      .i_csr_commit_fire(csr_commit_fire),
      .i_rob_commit(rob_commit),
      .i_trap_taken(trap_taken),
      .i_mret_taken(xret_taken),
      .i_trap_target(trap_target),
      .i_dispatch_stall(dispatch_stall),
      .i_frontend_resource_stall(decoded_queue_full || i_fatal_stop),
      .i_csr_wb_pending(csr_wb_pending),
      .i_branch_resolved_correct(branch_resolved_correct),
      .i_branch_resolved_checkpoint_id(branch_resolved_checkpoint_id),
      .i_front_end_indirect_control_flow_pending(
          front_end_indirect_control_flow_pending || decoded_queue_indirect_pending),
      .i_disable_branch_prediction(i_disable_branch_prediction),
      .i_flush_pipeline(fetch_flush),
      .i_fetch_pa_hold(fetch_pa_hold),
      .o_pipeline_ctrl(pipeline_ctrl),
      .o_serializing_alloc_fire(serializing_alloc_fire),
      .o_csr_in_flight(csr_in_flight),
      .o_disable_branch_prediction_ooo(disable_branch_prediction_ooo),
      .o_front_end_cf_serialize_stall(front_end_cf_serialize_stall),
      .o_stall_q(stall_q),
      .o_frontend_stall_without_pa_hold(frontend_stall_without_pa_hold),
      .o_id_stall_q(id_stall_q),
      .o_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .o_replay_after_serialize_stall_q(replay_after_serialize_stall_q),
      .o_post_flush_holdoff_q(post_flush_holdoff_q),
      .o_trap_taken_reg(trap_taken_reg),
      .o_mret_taken_reg(mret_taken_reg),
      .o_trap_target_reg(trap_target_reg),
      .o_checkpoint_unresolved(checkpoint_unresolved)
  );

  // ===========================================================================
  // Inter-stage signals
  // ===========================================================================
  // Fetch translation state from csr_file (combinational), and the
  // instruction MMU's walker port, muxed onto the shared ptw with the data
  // MMU's port (declared with the CSR wiring below).
  logic csr_fetch_translation_active, csr_fetch_priv_u;
  logic iwalk_req_valid, iwalk_req_ready;
  logic [riscv_pkg::Sv39VpnBits-1:0] iwalk_vpn;
  logic iwalk_resp_valid;
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_pd_to_id_t from_pd_to_id;
  logic pd_redirect;
  logic pd_redirect_taken;
  logic [XLEN-1:0] pd_redirect_target;
  logic pd_redirect_slot2;
  logic pd_redirect_ras_push;
  logic pd_redirect_ras_pop;
  logic [XLEN-1:0] pd_redirect_ras_link;
  logic pd_backing_refresh;
  logic [XLEN-1:0] pd_backing_refresh_pc;
  // IF's backing BTB result for each slot, for PD's redirect
  logic [1:0] if_backing_hit;
  logic [1:0] if_backing_compressed;
  logic [1:0] if_backing_return;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] if_backing_target;
  // Slot 2's backing type and target for each size of slot 1
  logic [1:0] if_backing_slot2_return_by_size;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] if_backing_slot2_target_by_size;

  // Tagged direction predictor: lookup history, events, per-slot lookups,
  // saved-lookup index, and training (see tage_history).
  logic [riscv_pkg::TageHistBits-1:0] tage_lookup_hist;
  logic [riscv_pkg::TageHistBits-1:0] tage_packet_hist;
  logic tage_hist_push;
  logic [4:1] tage_hist_restore_arm;
  logic [riscv_pkg::TagePathBits-1:0] tage_fetch_path_bits;
  logic [1:0] tage_slot_valid;
  riscv_pkg::tage_lookup_t tage_slot_lookup;
  riscv_pkg::tage_lookup_t tage_slot_lookup_2;
  logic tage_train_valid;
  riscv_pkg::tage_lookup_t tage_train_lookup;
  logic tage_train_bank;
  logic tage_train_alt_taken;
  logic tage_train_taken;
  logic tage_train_mispredicted;
  riscv_pkg::from_id_to_ex_t from_id_to_ex;
  // Dispatch source fields for RAT lookups and commit-bypass compares. Queued
  // builds use same-edge shadow copies per consumer; direct builds use the
  // bundle fields. rf_bypass_src_addr packs slot-2 rs3, rs2, rs1, then slot 1.
  logic [29:0] rf_bypass_src_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] rat_int_src1_addr, rat_int_src2_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] rat_int_src1_addr_2, rat_int_src2_addr_2;
  logic [riscv_pkg::RegAddrWidth-1:0] rat_fp_src1_addr, rat_fp_src2_addr, rat_fp_src3_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] rat_fp_src1_addr_2, rat_fp_src2_addr_2, rat_fp_src3_addr_2;
  riscv_pkg::from_id_to_ex_t decoded_packet, decoded_packet_2;
  // The ID instruction registers' next-edge values (queued frontend only).
  /* verilator lint_off UNUSEDSIGNAL */
  riscv_pkg::from_id_to_ex_t decoded_packet_next, decoded_packet_next_2;
  // ID's next-edge values if it advances and if it holds; decoded_packet_next
  // is the one the stall selects.
  riscv_pkg::from_id_to_ex_t decoded_packet_next_go, decoded_packet_next_go_2;
  riscv_pkg::from_id_to_ex_t decoded_packet_next_hold, decoded_packet_next_hold_2;
  /* verilator lint_on UNUSEDSIGNAL */

  // Slot 2 carries a paired instruction or sel_nop=1 (CPU README, "Two-wide
  // fetch and dispatch"). It dispatches only with slot 1; done-repair channels
  // 4, 5, and 6 recover missed CDB broadcasts for its renamed sources.
  riscv_pkg::from_if_to_pd_t from_if_to_pd_2;
  riscv_pkg::from_pd_to_id_t from_pd_to_id_2;
  riscv_pkg::from_id_to_ex_t from_id_to_ex_2;

  // Debug mirrors that the cocotb tests read.
  logic [riscv_pkg::RasPtrBits-1:0] dbg_if_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_if_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits-1:0] dbg_pd_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_pd_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits-1:0] dbg_id_ras_checkpoint_tos  /* verilator public_flat_rd */;
  logic [riscv_pkg::RasPtrBits:0] dbg_id_ras_checkpoint_valid_count  /* verilator public_flat_rd */;
  logic dbg_commit_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_pc  /* verilator public_flat_rd */;
  logic dbg_commit_is_return  /* verilator public_flat_rd */;
  logic dbg_commit_is_call  /* verilator public_flat_rd */;
  logic [riscv_pkg::CheckpointIdWidth-1:0] dbg_commit_checkpoint_id  /* verilator public_flat_rd */;
  logic dbg_commit_has_checkpoint  /* verilator public_flat_rd */;
  logic dbg_commit_predicted_taken  /* verilator public_flat_rd */;
  logic dbg_commit_branch_taken  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_pd_pc  /* verilator public_flat_rd */;
  logic [31:0] dbg_pd_instr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_id_pc  /* verilator public_flat_rd */;
  logic [31:0] dbg_id_instr  /* verilator public_flat_rd */;
  logic dbg_id_is_mret  /* verilator public_flat_rd */;
  logic dbg_if_valid_q  /* verilator public_flat_rd */;
  logic dbg_pd_valid_q  /* verilator public_flat_rd */;
  logic dbg_id_valid  /* verilator public_flat_rd */;
  logic [1:0] dbg_post_flush_holdoff_q  /* verilator public_flat_rd */;
  logic dbg_csr_in_flight  /* verilator public_flat_rd */;
  logic dbg_pipeline_stall  /* verilator public_flat_rd */;
  logic dbg_pipeline_stall_registered  /* verilator public_flat_rd */;
  logic dbg_dispatch_stall  /* verilator public_flat_rd */;
  logic dbg_front_end_cf_serialize_stall  /* verilator public_flat_rd */;
  logic dbg_stall_q  /* verilator public_flat_rd */;
  logic dbg_replay_after_dispatch_stall_q  /* verilator public_flat_rd */;
  logic dbg_replay_after_serialize_stall_q  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_alloc_pc  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_is_csr  /* verilator public_flat_rd */;
  logic dbg_rob_alloc_is_mret  /* verilator public_flat_rd */;
  logic dbg_btb_update  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_btb_update_pc  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_btb_update_target  /* verilator public_flat_rd */;
  logic dbg_btb_update_taken  /* verilator public_flat_rd */;
  logic dbg_btb_update_compressed  /* verilator public_flat_rd */;
  logic dbg_issue_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_issue_pc  /* verilator public_flat_rd */;
  logic dbg_issue_predicted_taken  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rs_dispatch_pc  /* verilator public_flat_rd */;
  // verilog_lint: waive-start line-length
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_rob_tag  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_src1_ready  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_src1_tag  /* verilator public_flat_rd */;
  logic dbg_rs_dispatch_src2_ready  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rs_dispatch_src2_tag  /* verilator public_flat_rd */;
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  logic dbg_rat_alloc_valid  /* verilator public_flat_rd */;
  logic dbg_rat_alloc_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rat_alloc_dest_reg  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_rat_alloc_rob_tag  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_last_a0_alloc_pc  /* verilator public_flat_rd */;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_last_a0_alloc_tag  /* verilator public_flat_rd */;
  logic dbg_trap_taken_raw  /* verilator public_flat_rd */;
  logic dbg_trap_taken_q  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_trap_cause_internal  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_trap_pc_internal  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_interrupt_resume_pc  /* verilator public_flat_rd */;
  logic dbg_port0_int_we  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_port0_int_addr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_port0_int_data  /* verilator public_flat_rd */;
  logic dbg_port1_int_we  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_port1_int_addr  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_port1_int_data  /* verilator public_flat_rd */;
  logic dbg_commit_dest_valid  /* verilator public_flat_rd */;
  logic dbg_commit_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_commit_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_value  /* verilator public_flat_rd */;
  logic dbg_commit_2_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_2_pc  /* verilator public_flat_rd */;
  logic dbg_commit_2_dest_valid  /* verilator public_flat_rd */;
  logic dbg_commit_2_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_commit_2_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_commit_2_value  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_reg_pc  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_dest_valid  /* verilator public_flat_rd */;
  logic dbg_rob_commit_reg_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rob_commit_reg_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_reg_value  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_valid  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_2_reg_pc  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_dest_valid  /* verilator public_flat_rd */;
  logic dbg_rob_commit_2_reg_dest_rf  /* verilator public_flat_rd */;
  logic [riscv_pkg::RegAddrWidth-1:0] dbg_rob_commit_2_reg_dest_reg  /* verilator public_flat_rd */;
  logic [XLEN-1:0] dbg_rob_commit_2_reg_value  /* verilator public_flat_rd */;
  // verilog_lint: waive-stop line-length
`endif

  // Synthesized from_ex_comb for IF stage (branch redirect, BTB update, RAS restore)
  riscv_pkg::from_ex_comb_t                     from_ex_comb_synth;
  riscv_pkg::from_ex_comb_t                     from_ex_branch_recovery;
  logic                              [XLEN-1:0] btb_late_update_pc;
  logic                                         btb_late_update_taken;

  riscv_pkg::reorder_buffer_commit_t            rob_commit_comb;  // combinational from ROB

  // RS dispatch
  riscv_pkg::rs_dispatch_t                      int_rs_dispatch;
  riscv_pkg::rs_dispatch_t                      mul_rs_dispatch;
  riscv_pkg::rs_dispatch_t                      mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t                      fp_rs_dispatch;
  riscv_pkg::rs_dispatch_t                      split_rs_dispatch_dbg;

  // RS issue. Exposed but not externally driven: the FU shims are inside the wrapper.
  riscv_pkg::rs_issue_t rs_issue_int, rs_issue_mul, rs_issue_mem;
  riscv_pkg::rs_issue_t rs_issue_fp;
  // Same-edge copy of rs_issue_int.rob_tag for branch predicates, for fanout.
  // ROB, recovery, and FU consumers use the architectural issue tag.
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rs_issue_int_branch_predicate_tag;

  assign dbg_if_ras_checkpoint_tos = from_if_to_pd.ras_checkpoint_tos;
  assign dbg_if_ras_checkpoint_valid_count = from_if_to_pd.ras_checkpoint_valid_count;
  assign dbg_pd_ras_checkpoint_tos = from_pd_to_id.ras_checkpoint_tos;
  assign dbg_pd_ras_checkpoint_valid_count = from_pd_to_id.ras_checkpoint_valid_count;
  assign dbg_id_ras_checkpoint_tos = from_id_to_ex.ras_checkpoint_tos;
  assign dbg_id_ras_checkpoint_valid_count = from_id_to_ex.ras_checkpoint_valid_count;
  assign dbg_commit_valid = rob_commit_comb.valid;
  assign dbg_commit_pc = rob_commit_comb.pc;
  assign dbg_commit_is_return = rob_commit_comb.is_return;
  assign dbg_commit_is_call = rob_commit_comb.is_call;
  assign dbg_commit_checkpoint_id = rob_commit_comb.checkpoint_id;
  assign dbg_commit_has_checkpoint = rob_commit_comb.has_checkpoint;
  assign dbg_commit_predicted_taken = rob_commit_comb.predicted_taken;
  assign dbg_commit_branch_taken = rob_commit_comb.branch_taken;
  assign dbg_pd_pc = XLEN'(from_pd_to_id.program_counter);
  assign dbg_pd_instr = from_pd_to_id.instruction;
  assign dbg_id_pc = XLEN'(from_id_to_ex.program_counter);
  assign dbg_id_instr = from_id_to_ex.instruction;
  assign dbg_id_is_mret = from_id_to_ex.is_mret;
  assign dbg_post_flush_holdoff_q = post_flush_holdoff_q;
  assign dbg_csr_in_flight = csr_in_flight;
  assign dbg_pipeline_stall = pipeline_ctrl.stall;
  assign o_pipeline_stall = pipeline_ctrl.stall;
  assign dbg_pipeline_stall_registered = pipeline_ctrl.stall_registered;
  assign dbg_dispatch_stall = dispatch_stall;
  assign dbg_front_end_cf_serialize_stall = front_end_cf_serialize_stall;
  assign dbg_stall_q = stall_q;
  assign dbg_replay_after_dispatch_stall_q = replay_after_dispatch_stall_q;
  assign dbg_replay_after_serialize_stall_q = replay_after_serialize_stall_q;
  assign dbg_btb_update = from_ex_comb_synth.btb_update;
  assign dbg_btb_update_pc = from_ex_comb_synth.btb_update_pc;
  assign dbg_btb_update_target = from_ex_comb_synth.btb_update_target;
  assign dbg_btb_update_taken = from_ex_comb_synth.btb_update_taken;
  assign dbg_btb_update_compressed = from_ex_comb_synth.btb_update_compressed;
  assign dbg_issue_valid = rs_issue_int.valid;
  assign dbg_issue_pc = rs_issue_int.pc;
  assign dbg_issue_predicted_taken = rs_issue_int.predicted_taken;
  always_comb begin
    split_rs_dispatch_dbg = '0;
    if (int_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = int_rs_dispatch;
    end else if (mul_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = mul_rs_dispatch;
    end else if (mem_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = mem_rs_dispatch;
    end else if (fp_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fp_rs_dispatch;
    end
  end

  assign dbg_rs_dispatch_valid = split_rs_dispatch_dbg.valid;
  assign dbg_rs_dispatch_pc = split_rs_dispatch_dbg.pc;
  assign dbg_rs_dispatch_rob_tag = split_rs_dispatch_dbg.rob_tag;
  assign dbg_rs_dispatch_src1_ready = split_rs_dispatch_dbg.src1_ready;
  assign dbg_rs_dispatch_src1_tag = split_rs_dispatch_dbg.src1_tag;
  assign dbg_rs_dispatch_src2_ready = split_rs_dispatch_dbg.src2_ready;
  assign dbg_rs_dispatch_src2_tag = split_rs_dispatch_dbg.src2_tag;

  // RAT rename - slot 1
  logic                                        rat_alloc_valid_raw;
  logic                                        rat_alloc_valid;
  logic                                        rat_alloc_dest_rf;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag;

`ifndef SYNTHESIS
  assign dbg_rat_alloc_valid = rat_alloc_valid;
  assign dbg_rat_alloc_dest_rf = rat_alloc_dest_rf;
  assign dbg_rat_alloc_dest_reg = rat_alloc_dest_reg;
  assign dbg_rat_alloc_rob_tag = rat_alloc_rob_tag;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dbg_last_a0_alloc_pc  <= '0;
      dbg_last_a0_alloc_tag <= '0;
    end else if (rat_alloc_valid && !rat_alloc_dest_rf && (rat_alloc_dest_reg == 5'd10)) begin
      dbg_last_a0_alloc_pc  <= rob_alloc_req.pc;
      dbg_last_a0_alloc_tag <= rat_alloc_rob_tag;
    end
  end
`endif

  assign trap_ctrl.trap_taken  = trap_taken_reg;
  assign trap_ctrl.mret_taken  = mret_taken_reg;
  assign trap_ctrl.trap_target = trap_target_reg;

  // ===========================================================================
  // Stage 1: Instruction Fetch (IF)
  // ===========================================================================

  // IF-to-PD delivery-width events for profiling.
  riscv_pkg::if_width_events_t if_width_events;

  logic dir_update_valid;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx;
  logic dir_update_taken;
  logic flush_all;
  logic frontend_state_flush;
  logic fence_i_flush;
  logic [XLEN-1:0] fence_i_target_pc;
  logic btb_invalidate_q;
  // IF's BTB invalidate, and the fetch translation state of the last cycle
  // it compares (see the BTB invalidate below).
  logic btb_invalidate;
  logic fetch_translation_active_prev_q;

  logic early_mispredict_active;
  logic early_mispredict_pending;
  logic early_mispredict_fire;
  logic early_backend_recovery_pending;
  logic early_backend_recovery_pending_next;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [XLEN-1:0] early_mispredict_redirect_pc;
  logic [riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic early_mispredict_is_compressed;
  logic [XLEN-1:0] early_mispredict_pc;
  logic [XLEN-1:0] early_mispredict_branch_target;
  logic early_mispredict_branch_taken;
  logic early_mispredict_is_jalr;
  logic early_mispredict_is_call;
  logic early_mispredict_is_return;
  logic early_mispredict_is_jal;
  logic early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  logic early_backend_recovery_hold;
  logic backend_recovery_hold;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic early_recovery_trap_taken_reg;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic early_recovery_mret_taken_reg;

  // csr_file's outputs, and the translation, walker and Debug Mode nets wired
  // with them (see CSR File below).
  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mepc;
  logic [XLEN-1:0] csr_stvec, csr_sepc;
  logic csr_sstatus_sie_direct;
  logic [15:0] csr_medeleg;
  logic [2:0] csr_mideleg_s;
  logic [2:0] csr_s_pending;
  logic [riscv_pkg::CounterMaskBits-1:0] csr_scounteren;
  logic [riscv_pkg::CounterMaskBits-1:0] csr_counter_blocked;
  logic csr_lcof_pending, csr_mideleg_lcof;
  logic csr_stimecmp_blocked;
  logic csr_mireg_illegal, csr_sireg_illegal, csr_stopei_illegal;
  logic csr_sret_illegal, csr_sfence_illegal, csr_wfi_illegal, csr_priv_is_u;
  // Registered translation-invalidate pulse from csr_file: every satp access,
  // and an mstatus write only when it changes MPRV, or MPP under MPRV. Through
  // tlb_invalidate it clears the IMMU result, suppresses direct DMMU hits
  // and discards the walk in flight. TLB entries leave through tlb_flush.
  // The ROB serializer handles pipeline recovery separately.
  logic csr_translation_flush_req;
  // Registered pulse beside it for a satp root switch or MPRV change: the
  // TLBs drop every entry. A satp write that keeps the root (an ASID change)
  // leaves the entries in place; the ASID tag separates the address spaces.
  logic csr_tlb_flush_all_req;
  logic [riscv_pkg::AsidBits-1:0] csr_mmu_asid, csr_fetch_asid;
  riscv_pkg::tlb_flush_t tlb_flush;
  // Registered translation state from csr_file, and the data MMU's walker
  // port between the wrapper and the ptw below.
  logic csr_translation_active, csr_mmu_sum, csr_mmu_mxr, csr_mmu_eff_priv_u;
  riscv_pkg::pm_mode_t csr_mmu_pm_mode;
  logic [43:0] csr_satp_root_ppn;
  logic csr_menvcfg_pbmte;
  logic tlb_invalidate;
  // HPM translation events: the walker is busy, and an SFENCE.VMA invalidate
  // window begins. The CSR request and the SFENCE window never overlap: each
  // is separated from the other by a full flush.
  logic ptw_busy;
  logic sfence_tlb_flush_active, sfence_tlb_flush_active_q, sfence_tlb_flush_start;
  assign sfence_tlb_flush_active = tlb_invalidate && !csr_translation_flush_req;
  assign sfence_tlb_flush_start  = sfence_tlb_flush_active && !sfence_tlb_flush_active_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) sfence_tlb_flush_active_q <= 1'b0;
    else sfence_tlb_flush_active_q <= sfence_tlb_flush_active;
  end
  logic walk_req_valid, walk_req_ready, walk_hold;
  logic [riscv_pkg::Sv39VpnBits-1:0] walk_vpn;
  logic walk_resp_valid;
  riscv_pkg::ptw_resp_t walk_resp;
  logic mret_start_is_sret;
  logic mret_start_is_dret;
  // Debug Mode state exports and the single-step engine.
  logic csr_debug_mode, csr_dcsr_step;
  logic [2:0] csr_dcsr_ebreak;
  logic [XLEN-1:0] csr_dpc;
  logic dret_taken;
  logic trap_to_d, trap_no_csr, dbg_go_taken, dbg_park_entry, dbg_park_exception;
  logic trap_save_m, trap_save_s, trap_enter_d;  // csr_file's entry enables
  logic [2:0] trap_dbg_cause;
  logic csr_mstatus_mie_direct;

  // Indirect target predictor: IF's per-slot results and saved lookups, PD's
  // registered-packet history outputs, and the training port from tage_history.
  logic [1:0] if_itt_hit;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] if_itt_target;
  riscv_pkg::itt_lookup_t itt_slot_lookup;
  riscv_pkg::itt_lookup_t itt_slot_lookup_2;
  logic [1:0] pd_q_cond_branch;
  logic [1:0] pd_q_jalr;
  logic [1:0] pd_q_itt_eligible;
  logic [1:0] pd_q_cf;
  logic [1:0] pd_q_pred_taken;
  logic [riscv_pkg::TageDirHistBits-1:0] tage_dir_hist;
  logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] tage_dir_fold;
  logic itt_train_valid;
  riscv_pkg::itt_lookup_t itt_train_lookup;
  logic itt_train_bank;
  logic [riscv_pkg::PhysAddrBits-2:0] itt_train_target;
  logic itt_train_mispredicted;

  if_stage #(
      .XLEN(XLEN),
      .USE_EXTERNAL_TAGE_FOLD(1'b1)
  ) if_stage_inst (
      .i_clk,
      .i_boot_addr,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_instr,
      .i_instr_low_by_parity,
      .i_instr_high,
      .i_instr_window_high,
      .i_instr_sideband,
      .i_instr_pc_metadata,
      .i_instr_pc_metadata_by_provider_parity,
      .i_pc_pairability_by_provider_parity,
      .i_slot2_start_valid_lo_by_provider_parity,
      .i_instr_pc_metadata_served_high,
      .i_instr_bank_sel_r,
      .i_served_word_low,
      .i_served_last_word_low,
      .i_served_prev_word_low,
      .i_served_prev_word_valid_low,
      .i_served_word_high,
      .i_served_last_word_high,
      .i_served_prev_word_high,
      .i_served_prev_word_valid_high,
      .i_instr_valid,
      .i_instr_fault0,
      .i_instr_fault0_page,
      .i_instr_fault1,
      .i_instr_fault1_page,
      .i_served_high,
      .o_fetch_replay_consume,
      .o_fetch_live_claim,
      .o_fetch_pa0,
      .o_fetch_pa1,
      .o_fetch_pa_valid,
      .o_fetch_fault0,
      .o_fetch_fault0_page,
      .o_fetch_fault1,
      .o_fetch_fault1_page,
      .o_fetch_line_after_ok,
      .o_fetch_redirect,
      .o_fetch_cached_retarget,
      .o_fetch_pa_hold(fetch_pa_hold),
      .o_fetch_pa_hold_copy(fetch_pa_hold_copy),
      .i_fetch_translation_active(csr_fetch_translation_active),
      .i_fetch_priv_u(csr_fetch_priv_u),
      .i_tlb_invalidate(tlb_invalidate),
      .i_tlb_flush(tlb_flush),
      .i_fetch_asid(csr_fetch_asid),
      .o_walk_req_valid(iwalk_req_valid),
      .i_walk_req_ready(iwalk_req_ready),
      .o_walk_vpn(iwalk_vpn),
      .i_walk_resp_valid(iwalk_resp_valid),
      .i_walk_resp(walk_resp),
      .i_from_ex_comb(from_ex_comb_synth),
      // The captured early-recovery branch goes straight to the BTB's
      // parallel counter read-modify-write. The write itself (enable,
      // address, tag, target, metadata) still comes only from from_ex_comb.
      .i_btb_early_update_active(early_mispredict_active),
      .i_btb_early_update_pc(early_mispredict_pc),
      .i_btb_early_update_taken(early_mispredict_branch_taken),
      // Lower-priority read-modify-write candidate, selected without the
      // early-active qualifier. It never controls a BTB write.
      .i_btb_late_update_pc(btb_late_update_pc),
      .i_btb_late_update_taken(btb_late_update_taken),
      .i_trap_ctrl(trap_ctrl),
      .i_frontend_state_flush(fetch_flush),
      .i_flush_all(flush_all),
      .i_fence_i_flush(fence_i_flush),
      .i_fence_i_target(fence_i_target_pc),
      .i_btb_invalidate(btb_invalidate),
      .i_disable_branch_prediction(disable_branch_prediction_ooo),
      // Bimodal direction-predictor training (conditional branches only, see
      // dir_update_* below).
      .i_dir_update_valid(dir_update_valid),
      .i_dir_update_idx(dir_update_idx),
      .i_dir_update_taken(dir_update_taken),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_taken(pd_redirect_taken),
      .i_pd_redirect_target(pd_redirect_target),
      .i_pd_redirect_ras_push(pd_redirect_ras_push),
      .i_pd_redirect_ras_pop(pd_redirect_ras_pop),
      .i_pd_redirect_ras_link(pd_redirect_ras_link),
      .i_pd_backing_refresh(pd_backing_refresh),
      .i_pd_backing_refresh_pc(pd_backing_refresh_pc),
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd),
      .o_from_if_to_pd_2(from_if_to_pd_2),
      .o_backing_hit(if_backing_hit),
      .o_backing_compressed(if_backing_compressed),
      .o_backing_return(if_backing_return),
      .o_backing_target(if_backing_target),
      .o_backing_slot2_return_by_size(if_backing_slot2_return_by_size),
      .o_backing_slot2_target_by_size(if_backing_slot2_target_by_size),
      .o_slot1_has_control_flow(if_slot1_has_control_flow),
      .o_slot1_is_indirect(if_slot1_is_indirect),
      .o_width_events(if_width_events),
      .i_tage_hist(tage_dir_hist),
      .i_tage_hist_fold(tage_dir_fold),
      .i_itt_hist(tage_lookup_hist),
      .i_tage_train_valid(tage_train_valid),
      .i_tage_train_lookup(tage_train_lookup),
      .i_tage_train_bank(tage_train_bank),
      .i_tage_train_alt_taken(tage_train_alt_taken),
      .i_tage_train_taken(tage_train_taken),
      .i_tage_train_mispredicted(tage_train_mispredicted),
      .o_tage_hist_push(tage_hist_push),
      .o_tage_hist_restore_arm(tage_hist_restore_arm),
      .o_tage_fetch_path_bits(tage_fetch_path_bits),
      .o_tage_slot_valid(tage_slot_valid),
      .o_tage_slot_lookup(tage_slot_lookup),
      .o_tage_slot_lookup_2(tage_slot_lookup_2),
      .o_tage_lookup_hist(tage_packet_hist),
      .i_itt_train_valid(itt_train_valid),
      .i_itt_train_lookup(itt_train_lookup),
      .i_itt_train_bank(itt_train_bank),
      .i_itt_train_target(itt_train_target),
      .i_itt_train_mispredicted(itt_train_mispredicted),
      .o_itt_slot_lookup(itt_slot_lookup),
      .o_itt_slot_lookup_2(itt_slot_lookup_2),
      .o_itt_hit(if_itt_hit),
      .o_itt_target(if_itt_target)
  );

  // ===========================================================================
  // Stage 2: Pre-Decode (PD)
  // ===========================================================================

  pd_stage #(
      .XLEN(XLEN)
  ) pd_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .o_from_pd_to_id(from_pd_to_id),
      .i_from_if_to_pd_2(from_if_to_pd_2),
      .o_from_pd_to_id_2(from_pd_to_id_2),
      // A build that disables branch prediction, such as TestRIG's, gets no
      // backing BTB redirects.
      .i_backing_hit(if_backing_hit & {2{!i_disable_branch_prediction}}),
      .i_backing_compressed(if_backing_compressed),
      .i_backing_return(if_backing_return),
      .i_backing_target(if_backing_target),
      .i_backing_slot2_return_by_size(if_backing_slot2_return_by_size),
      .i_backing_slot2_target_by_size(if_backing_slot2_target_by_size),
      .i_itt_hit(if_itt_hit & {2{!i_disable_branch_prediction}}),
      .i_itt_target(if_itt_target),
      .o_pd_redirect(pd_redirect),
      .o_pd_redirect_taken(pd_redirect_taken),
      .o_pd_redirect_target(pd_redirect_target),
      .o_pd_redirect_slot2(pd_redirect_slot2),
      .o_pd_redirect_ras_push(pd_redirect_ras_push),
      .o_pd_redirect_ras_pop(pd_redirect_ras_pop),
      .o_pd_redirect_ras_link(pd_redirect_ras_link),
      .o_pd_backing_refresh(pd_backing_refresh),
      .o_pd_backing_refresh_pc(pd_backing_refresh_pc),
      .o_cond_branch(),
      .o_jalr(),
      .o_itt_eligible(),
      .o_jump(),
      .o_pred_taken(),
      .o_q_cond_branch(pd_q_cond_branch),
      .o_q_jalr(pd_q_jalr),
      .o_q_itt_eligible(pd_q_itt_eligible),
      .o_q_cf(pd_q_cf),
      .o_q_pred_taken(pd_q_pred_taken)
  );

  // ===========================================================================
  // Register Files (read at dispatch, write from ROB commit)
  // ===========================================================================

  // ooo_register_files reads both dispatch slots and bypasses same-cycle
  // commits. Port 0 writes slot 1; port 1 writes slot 2.

  // FP data width, also used below by the commit-side write-port packing.
  localparam int unsigned FpW = riscv_pkg::FpWidth;

  logic [              XLEN-1:0] int_rf_dispatch_rs1_data;
  logic [              XLEN-1:0] int_rf_dispatch_rs2_data;
  logic [              XLEN-1:0] int_rf_dispatch_rs1_data_2;
  logic [              XLEN-1:0] int_rf_dispatch_rs2_data_2;
  logic [               FpW-1:0] fp_rf_dispatch_rs1_data;
  logic [               FpW-1:0] fp_rf_dispatch_rs2_data;
  logic [               FpW-1:0] fp_rf_dispatch_rs3_data;
  logic [               FpW-1:0] fp_rf_dispatch_rs1_data_2;
  logic [               FpW-1:0] fp_rf_dispatch_rs2_data_2;
  logic [               FpW-1:0] fp_rf_dispatch_rs3_data_2;

  // Registered write enables and addresses for the register-file bypass,
  // computed below after commit_actions.
  logic                          bypass_p0_int_we_q;
  logic                          bypass_p1_int_we_q;
  logic                          bypass_p0_fp_we_q;
  logic                          bypass_p1_fp_we_q;
  // Cap bypass-address fanout for replication.
  (* max_fanout = 48 *)logic [                   4:0] bypass_p0_addr_q;
  (* max_fanout = 48 *)logic [                   4:0] bypass_p1_addr_q;

  // Extra register-file read port, shared between the misaligned-access engine
  // (MISALIGNED_HW) and head-executed vector memory base reads (VECTOR).
  logic [                   4:0] ma_rf_read_addr;
  logic                          vec_rf_read_en;
  logic [                   4:0] vec_rf_read_addr;
  logic [                   4:0] extra_rf_read_addr;
  logic [              XLEN-1:0] ma_extra_int_read_data;
  logic [riscv_pkg::FpWidth-1:0] ma_extra_fp_read_data;

  // Regfile write ports (driven by commit_actions, consumed by
  // ooo_register_files) and retire status.
  logic                          port0_int_we;
  logic [                   4:0] port0_int_addr;
  logic [              XLEN-1:0] port0_int_data;
  logic                          port0_fp_we;
  logic [                   4:0] port0_fp_addr;
  logic [               FpW-1:0] port0_fp_data;
  logic                          port1_int_we;
  logic [                   4:0] port1_int_addr;
  logic [              XLEN-1:0] port1_int_data;
  logic                          port1_fp_we;
  logic [                   4:0] port1_fp_addr;
  logic [               FpW-1:0] port1_fp_data;
  logic [                   1:0] instruction_retired_count;
  // An instruction retired without a registered ROB commit in the previous
  // cycle: xRET, a taken-over WFI, FENCE.I, or SFENCE.VMA.
  logic                          retired_without_commit_q;

  ooo_register_files #(
      .XLEN(XLEN),
      .SEPARATE_BYPASS_ADDR(1'b1),
      .EXTRA_READ_PORT(MISALIGNED_HW || VECTOR)
  ) ooo_register_files_inst (
      .i_clk,
      .i_port0_int_we  (port0_int_we),
      .i_port0_int_addr(port0_int_addr),
      .i_port0_int_data(port0_int_data),
      .i_port1_int_we  (port1_int_we),
      .i_port1_int_addr(port1_int_addr),
      .i_port1_int_data(port1_int_data),
      .i_port0_fp_we   (port0_fp_we),
      .i_port0_fp_addr (port0_fp_addr),
      .i_port0_fp_data (port0_fp_data),
      .i_port1_fp_we   (port1_fp_we),
      .i_port1_fp_addr (port1_fp_addr),
      .i_port1_fp_data (port1_fp_data),
      .i_bypass_p0_int_we(bypass_p0_int_we_q),
      .i_bypass_p1_int_we(bypass_p1_int_we_q),
      .i_bypass_p0_fp_we (bypass_p0_fp_we_q),
      .i_bypass_p1_fp_we (bypass_p1_fp_we_q),
      .i_bypass_p0_addr  (bypass_p0_addr_q),
      .i_bypass_p1_addr  (bypass_p1_addr_q),
      .i_from_id_to_ex  (from_id_to_ex),
      .i_from_id_to_ex_2(from_id_to_ex_2),
      .i_bypass_src_addr(rf_bypass_src_addr),
      .o_int_rf_dispatch_rs1_data  (int_rf_dispatch_rs1_data),
      .o_int_rf_dispatch_rs2_data  (int_rf_dispatch_rs2_data),
      .o_int_rf_dispatch_rs1_data_2(int_rf_dispatch_rs1_data_2),
      .o_int_rf_dispatch_rs2_data_2(int_rf_dispatch_rs2_data_2),
      .o_fp_rf_dispatch_rs1_data  (fp_rf_dispatch_rs1_data),
      .o_fp_rf_dispatch_rs2_data  (fp_rf_dispatch_rs2_data),
      .o_fp_rf_dispatch_rs3_data  (fp_rf_dispatch_rs3_data),
      .o_fp_rf_dispatch_rs1_data_2(fp_rf_dispatch_rs1_data_2),
      .o_fp_rf_dispatch_rs2_data_2(fp_rf_dispatch_rs2_data_2),
      .o_fp_rf_dispatch_rs3_data_2(fp_rf_dispatch_rs3_data_2),
      .i_extra_read_addr(extra_rf_read_addr),
      .o_extra_int_read_data(ma_extra_int_read_data),
      .o_extra_fp_read_data(ma_extra_fp_read_data)
  );

  // ===========================================================================
  // Stage 3: Instruction Decode (ID)
  // ===========================================================================

  // mstatus.FS == Off from csr_file. ID decodes every F/D instruction as
  // illegal while it is set; the ROB's allocation check reads it too.
  logic csr_mstatus_fs_off;
  logic csr_mstatus_vs_off;
  // vl/vtype update of a committing vector-config instruction (registered
  // commit bus), from the wrapper to the CSR file
  riscv_pkg::vcfg_commit_t vcfg_commit;
  // Vector unit (VECTOR): the vtype at dispatch and whether it is known, the
  // ROB's vector-config-in-flight bit, the architectural vector state, the
  // retirement of vector arithmetic, the unit's commit hold and idle state.
  logic [8:0] vec_vtype_spec;
  // vec_lmul_legality's classes of the dispatch slot-1 instruction, and
  // slot 2's vector-encoding flag for dispatch's slot-2 interlock
  logic [3:0] dispatch_vec_lmul_illegal;
  logic [3:0] dispatch_slot1_rs_select;
  logic dispatch_slot2_is_vector;
  // Vector arithmetic may dispatch: the vtype is known and, with the unit,
  // the queue head's registered arithmetic legality (vec_arith_illegal) is
  // ready
  logic vec_vtype_valid;
  logic vec_arith_illegal;
  logic [1:0] vec_restart_ok;
  logic vec_vcfg_in_flight;
  logic [15:0] csr_vec_vl, csr_vec_vstart;
  logic [8:0] csr_vec_vtype;
  logic vec_varith_commit;
  logic vec_vstore_commit;
  logic vec_vmem_fault_vstart_valid;
  logic [15:0] vec_vmem_fault_vstart;
  logic vec_vmem_vs_dirty;
  logic vec_vl_trim_valid;
  logic [15:0] vec_vl_trim;
  logic vec_head_shield;
  logic vec_walk_req_valid, vec_walk_req_ready, vec_walk_resp_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] vec_walk_vpn;
  logic vec_lc_req_valid, vec_lc_req_ready, vec_lc_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] vec_lc_req_addr;
  logic [255:0] vec_lc_req_data;
  logic [31:0] vec_lc_req_mask;
  logic [3:0] vec_lc_req_id;
  logic vec_unc_port_ready, vec_unc_bus_busy;
  logic vec_unc_req_valid, vec_unc_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] vec_unc_req_addr;
  riscv_pkg::mem_size_e vec_unc_req_size;
  logic [riscv_pkg::MemDataBits-1:0] vec_unc_req_wdata;
  logic [riscv_pkg::MemStrbBits-1:0] vec_unc_req_wstrb;
  logic vec_unc_resp_valid, vec_unc_resp_error;
  logic [riscv_pkg::MemDataBits-1:0] vec_unc_resp_data;
  logic vec_l0_inval_valid;
  logic [XLEN-1:0] vec_l0_inval_addr;
  logic vec_vmu_fatal;
  logic [riscv_pkg::PhysAddrBits-1:0] vec_vmu_fatal_addr;
  logic vec_commit_hold;
  logic vec_idle;
  logic vec_vstart_nonzero, vec_vxsat_set, vec_vtox_commit;
  // FP exception flags of a committed vector instruction's active elements,
  // one registered pulse when the engine finishes it, sent only if one is set
  logic vec_fp_flags_valid;
  logic [4:0] vec_fp_flags;
  logic [1:0] csr_vec_vxrm;
  riscv_pkg::fu_complete_t vec_vtox_complete;  // CDB slot 6
  // The vector memory table as the load and store queues see it, and its
  // registered "no live retired entry" (rule V-O4: FENCE, FENCE.I,
  // SFENCE.VMA, SC and the misaligned-access engine wait for it).
  riscv_pkg::vmt_view_t vec_vmt_view;
  logic vec_vmem_quiet;
  // Every vector memory table entry is live (registered): a vector load or
  // store waits at dispatch.
  logic vec_vmt_full;
  // Register FS-Off for decode timing. It differs from CSR state only when
  // FS enters or leaves Off, whose full flush discards that cycle's decode.
  logic id_mstatus_fs_off_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_mstatus_fs_off_q <= 1'b0;
    else id_mstatus_fs_off_q <= csr_mstatus_fs_off;
  end
  // VS-Off for decode, registered the same way; VS enters or leaves Off only
  // through mstatus writes, whose full flush discards that cycle's decode.
  logic id_mstatus_vs_off_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_mstatus_vs_off_q <= 1'b1;
    else id_mstatus_vs_off_q <= csr_mstatus_vs_off;
  end
  // The Zicboz gate takes the same registered path. A legal envcfg write
  // affects only lower privilege, so the executing mode's permission changes
  // only across trap, xRET or debug privilege transitions. Their full flush
  // discards the decode under the old value.
  logic csr_cbo_zero_illegal;
  logic id_cbo_zero_illegal_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_cbo_zero_illegal_q <= 1'b0;
    else id_cbo_zero_illegal_q <= csr_cbo_zero_illegal;
  end
  // The Zicbom gates (CBCFE, CBIE) take it too, with the same change rule.
  logic csr_cbo_cf_illegal, csr_cbo_inval_illegal, csr_cbo_inval_flush;
  logic id_cbo_cf_illegal_q, id_cbo_inval_illegal_q, id_cbo_inval_flush_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      id_cbo_cf_illegal_q    <= 1'b0;
      id_cbo_inval_illegal_q <= 1'b0;
      id_cbo_inval_flush_q   <= 1'b0;
    end else begin
      id_cbo_cf_illegal_q    <= csr_cbo_cf_illegal;
      id_cbo_inval_illegal_q <= csr_cbo_inval_illegal;
      id_cbo_inval_flush_q   <= csr_cbo_inval_flush;
    end
  end
  // Zawrs: wrs.nto is illegal below M while mstatus.TW is set. TW changes only
  // through an mstatus write (translation class), the privilege only on a trap
  // or xRET; each is a full flush.
  logic csr_wrs_nto_illegal;
  logic id_wrs_nto_illegal_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_wrs_nto_illegal_q <= 1'b0;
    else id_wrs_nto_illegal_q <= csr_wrs_nto_illegal;
  end
  // Svinval: sfence.w.inval and sfence.inval.ir trap in U-mode and ignore
  // mstatus.TVM; privilege changes only on a full-flush trap or xRET.
  logic id_priv_is_u_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_priv_is_u_q <= 1'b0;
    else id_priv_is_u_q <= csr_priv_is_u;
  end

  id_stage #(
      .XLEN  (XLEN),
      .VECTOR(VECTOR)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_taken(pd_redirect_taken),
      .i_pd_redirect_target(pd_redirect_target),
      .i_pd_redirect_slot2(pd_redirect_slot2),
      .i_mstatus_fs_off(id_mstatus_fs_off_q),
      .i_mstatus_vs_off(id_mstatus_vs_off_q),
      .i_cbo_zero_illegal(id_cbo_zero_illegal_q),
      .i_wrs_nto_illegal(id_wrs_nto_illegal_q),
      .i_priv_is_u(id_priv_is_u_q),
      .i_cbo_cf_illegal(id_cbo_cf_illegal_q),
      .i_cbo_inval_illegal(id_cbo_inval_illegal_q),
      .i_cbo_inval_flush(id_cbo_inval_flush_q),
      .o_from_id_to_ex(decoded_packet),
      .o_from_id_to_ex_next(decoded_packet_next),
      .o_from_id_to_ex_next_go(decoded_packet_next_go),
      .o_from_id_to_ex_next_hold(decoded_packet_next_hold),
      // Slot 2 (2-wide dispatch). i_from_pd_to_id_2 carries the second
      // instruction plus its inject_nop bubble marker, which ID applies before
      // producing o_from_id_to_ex_2.
      .i_from_pd_to_id_2(from_pd_to_id_2),
      .o_from_id_to_ex_2(decoded_packet_2),
      .o_from_id_to_ex_next_2(decoded_packet_next_2),
      .o_from_id_to_ex_next_go_2(decoded_packet_next_go_2),
      .o_from_id_to_ex_next_hold_2(decoded_packet_next_hold_2)
  );

  // ===========================================================================
  // Instruction Validity (pipeline valid tracking)
  // ===========================================================================
  // Track real frontend packets through flush and reset bubbles. Dispatch
  // applies recovery kill to preflush candidates; id_valid and id_valid_2 are
  // flush-qualified debug copies.
  logic if_valid_q;
  logic pd_valid_q;
  logic id_valid_preflush;
  logic id_valid_2_preflush;
  logic id_valid;
  logic id_valid_2;
  // Debug Mode single-step state. These declarations must precede their first
  // use: Vivado otherwise creates an implicit wire for step_armed_q and emits
  // use-before-declaration warnings for the done state and pulse.
  logic step_armed_q;
  logic step_done_q;
  logic step_done_set;
  // Same-edge step_armed_q copy for the ROB commit-width gate, for fanout.
  (* keep = "true", equivalent_register_removal = "no" *)logic step_armed_rob_q;

  frontend_validity_tracker frontend_validity_tracker_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .i_if_has_control_flow(if_slot1_has_control_flow),
      .i_if_is_indirect(if_slot1_is_indirect),
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(decoded_packet),
      .i_from_id_to_ex_2(decoded_packet_2),
      .i_post_flush_holdoff_q(post_flush_holdoff_q),
      .i_dispatch_flush(dispatch_flush),
      .i_id_stall_q(id_stall_q),
      .i_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .i_flush_pipeline(frontend_state_flush),
      .o_if_valid_q(if_valid_q),
      .o_pd_valid_q(pd_valid_q),
      .o_id_valid_preflush(direct_id_valid_preflush),
      .o_id_valid_2_preflush(direct_id_valid_2_preflush),
      .o_id_valid(direct_id_valid),
      .o_id_valid_2(direct_id_valid_2),
      .o_front_end_indirect_control_flow_pending(front_end_indirect_control_flow_pending),
      .o_prediction_fence_branch(prediction_fence_branch),
      .o_prediction_fence_jal(prediction_fence_jal),
      .o_prediction_fence_indirect(prediction_fence_indirect)
  );

  // With a decoded queue, decode runs ahead of dispatch without caching
  // operand values: the register-file and RAT ports are addressed by the
  // queue head each cycle.
  generate
    if (DECODED_QUEUE_DEPTH != 0) begin : gen_decoded_queue
      logic queue_valid;
      logic input_indirect;
      riscv_pkg::from_id_to_ex_t queue_packet, queue_packet_2;
      riscv_pkg::id_dispatch_ctrl_t queue_ctrl, queue_ctrl_2;
      riscv_pkg::id_dispatch_ctrl_t queue_ctrl_next, queue_ctrl_next_2;
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl, producer_ctrl_2;
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl_next, producer_ctrl_next_2;
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl_next_go, producer_ctrl_next_go_2;
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl_next_hold, producer_ctrl_next_hold_2;
      // Slot 1's four vector LMUL legality classes and slot 2's vector-presence
      // flag beside the shadow slice, from each producer copy's own packet
      logic [3:0] producer_vlc, producer_vlc_next, producer_vlc_next_go, producer_vlc_next_hold;
      logic [3:0] queue_vlc, queue_vlc_next;
      logic producer_s2_vec, producer_s2_vec_next;
      logic producer_s2_vec_next_go, producer_s2_vec_next_hold;
      /* verilator lint_off UNUSEDSIGNAL */
      logic queue_s2_vec, queue_s2_vec_next;
      /* verilator lint_on UNUSEDSIGNAL */
      vec_lmul_legality u_vlc (
          .i_insn   (32'(decoded_packet.instruction)),
          .o_illegal(producer_vlc)
      );
      vec_lmul_legality u_vlc_next (
          .i_insn   (32'(decoded_packet_next.instruction)),
          .o_illegal(producer_vlc_next)
      );
      vec_lmul_legality u_vlc_next_go (
          .i_insn   (32'(decoded_packet_next_go.instruction)),
          .o_illegal(producer_vlc_next_go)
      );
      vec_lmul_legality u_vlc_next_hold (
          .i_insn   (32'(decoded_packet_next_hold.instruction)),
          .o_illegal(producer_vlc_next_hold)
      );
      function automatic logic id_is_varith(input riscv_pkg::instr_t insn);
        id_is_varith = ((insn.opcode == riscv_pkg::OPC_OP_V) && (insn.funct3 != 3'b111)) ||
            (VECTOR && (insn.opcode == riscv_pkg::OPC_OP_VE));
      endfunction
      function automatic logic id_is_vec_any(input riscv_pkg::from_id_to_ex_t d);
        id_is_vec_any = d.is_real &&
            ((d.instruction.opcode == riscv_pkg::OPC_OP_V) ||
             (VECTOR && (d.instruction.opcode == riscv_pkg::OPC_OP_VE)) ||
             riscv_pkg::is_vector_mem(d.instruction.opcode, d.instruction.funct3));
      endfunction
      assign producer_s2_vec           = id_is_vec_any(decoded_packet_2);
      assign producer_s2_vec_next      = id_is_vec_any(decoded_packet_next_2);
      assign producer_s2_vec_next_go   = id_is_vec_any(decoded_packet_next_go_2);
      assign producer_s2_vec_next_hold = id_is_vec_any(decoded_packet_next_hold_2);
      // The shadow slice of an ID packet: the same field copy as
      // producer_ctrl_next, for the go and hold outcomes.
      function automatic riscv_pkg::id_dispatch_ctrl_t id_ctrl_of(
          input riscv_pkg::from_id_to_ex_t d);
        riscv_pkg::id_dispatch_ctrl_t c;
        c = '0;
        c.is_load_instruction = d.is_load_instruction;
        c.is_load_unsigned = d.is_load_unsigned;
        c.instruction_operation = d.instruction_operation;
        c.rs_type = d.rs_type;
        c.is_int_store = d.is_int_store;
        c.is_branch_or_jump = d.is_branch_or_jump;
        c.is_fence = d.is_fence;
        c.is_fence_i = d.is_fence_i;
        c.is_csr_imm = d.is_csr_imm;
        c.has_fp_flags = d.has_fp_flags;
        c.needs_lq = d.needs_lq;
        c.needs_sq = d.needs_sq;
        c.is_jump_and_link = d.is_jump_and_link;
        c.is_jump_and_link_register = d.is_jump_and_link_register;
        c.is_csr_instruction = d.is_csr_instruction;
        c.is_amo_instruction = d.is_amo_instruction;
        c.is_lr = d.is_lr;
        c.is_sc = d.is_sc;
        c.is_mret = d.is_mret;
        c.is_sret = d.is_sret;
        c.is_dret = d.is_dret;
        c.is_sfence_vma = d.is_sfence_vma;
        c.is_wfi = d.is_wfi;
        c.is_illegal_instruction = d.is_illegal_instruction;
        c.is_fetch_fault = d.is_fetch_fault;
        c.is_fetch_fault_page = d.is_fetch_fault_page;
        c.is_fp_instruction = d.is_fp_instruction;
        c.is_fp_load = d.is_fp_load;
        c.is_fp_store = d.is_fp_store;
        c.is_compressed = d.is_compressed;
        c.instruction = d.instruction;
        c.btb_predicted_taken = d.btb_predicted_taken;
        c.is_ras_return = d.is_ras_return;
        c.is_ras_call = d.is_ras_call;
        c.has_int_dest = d.has_int_dest;
        c.has_fp_dest = d.has_fp_dest;
        c.uses_int_rs1 = d.uses_int_rs1;
        c.uses_int_rs2 = d.uses_int_rs2;
        c.uses_fp_rs1 = d.uses_fp_rs1;
        c.uses_fp_rs2 = d.uses_fp_rs2;
        c.uses_fp_rs3 = d.uses_fp_rs3;
        c.is_real = d.is_real;
        c.is_varith = id_is_varith(d.instruction);
        c.is_vmem = riscv_pkg::is_vector_mem(d.instruction.opcode, d.instruction.funct3);
        id_ctrl_of = c;
      endfunction
      assign producer_ctrl_next_go = id_ctrl_of(decoded_packet_next_go);
      assign producer_ctrl_next_go_2 = id_ctrl_of(decoded_packet_next_go_2);
      assign producer_ctrl_next_hold = id_ctrl_of(decoded_packet_next_hold);
      assign producer_ctrl_next_hold_2 = id_ctrl_of(decoded_packet_next_hold_2);
      // The queue's shadow slice: the id_dispatch_ctrl_t fields of ID's output
      // registers (producer_ctrl) and of their next-edge values
      // (producer_ctrl_next).
      always_comb begin
        producer_ctrl.is_load_instruction = decoded_packet.is_load_instruction;
        producer_ctrl.is_load_unsigned = decoded_packet.is_load_unsigned;
        producer_ctrl.instruction_operation = decoded_packet.instruction_operation;
        producer_ctrl.rs_type = decoded_packet.rs_type;
        producer_ctrl.is_int_store = decoded_packet.is_int_store;
        producer_ctrl.is_branch_or_jump = decoded_packet.is_branch_or_jump;
        producer_ctrl.is_fence = decoded_packet.is_fence;
        producer_ctrl.is_fence_i = decoded_packet.is_fence_i;
        producer_ctrl.is_csr_imm = decoded_packet.is_csr_imm;
        producer_ctrl.has_fp_flags = decoded_packet.has_fp_flags;
        producer_ctrl.needs_lq = decoded_packet.needs_lq;
        producer_ctrl.needs_sq = decoded_packet.needs_sq;
        producer_ctrl.is_jump_and_link = decoded_packet.is_jump_and_link;
        producer_ctrl.is_jump_and_link_register = decoded_packet.is_jump_and_link_register;
        producer_ctrl.is_csr_instruction = decoded_packet.is_csr_instruction;
        producer_ctrl.is_amo_instruction = decoded_packet.is_amo_instruction;
        producer_ctrl.is_lr = decoded_packet.is_lr;
        producer_ctrl.is_sc = decoded_packet.is_sc;
        producer_ctrl.is_mret = decoded_packet.is_mret;
        producer_ctrl.is_sret = decoded_packet.is_sret;
        producer_ctrl.is_dret = decoded_packet.is_dret;
        producer_ctrl.is_sfence_vma = decoded_packet.is_sfence_vma;
        producer_ctrl.is_wfi = decoded_packet.is_wfi;
        producer_ctrl.is_illegal_instruction = decoded_packet.is_illegal_instruction;
        producer_ctrl.is_fetch_fault = decoded_packet.is_fetch_fault;
        producer_ctrl.is_fetch_fault_page = decoded_packet.is_fetch_fault_page;
        producer_ctrl.is_fp_instruction = decoded_packet.is_fp_instruction;
        producer_ctrl.is_fp_load = decoded_packet.is_fp_load;
        producer_ctrl.is_fp_store = decoded_packet.is_fp_store;
        producer_ctrl.is_compressed = decoded_packet.is_compressed;
        producer_ctrl.instruction = decoded_packet.instruction;
        producer_ctrl.btb_predicted_taken = decoded_packet.btb_predicted_taken;
        producer_ctrl.is_ras_return = decoded_packet.is_ras_return;
        producer_ctrl.is_ras_call = decoded_packet.is_ras_call;
        producer_ctrl.has_int_dest = decoded_packet.has_int_dest;
        producer_ctrl.has_fp_dest = decoded_packet.has_fp_dest;
        producer_ctrl.uses_int_rs1 = decoded_packet.uses_int_rs1;
        producer_ctrl.uses_int_rs2 = decoded_packet.uses_int_rs2;
        producer_ctrl.uses_fp_rs1 = decoded_packet.uses_fp_rs1;
        producer_ctrl.uses_fp_rs2 = decoded_packet.uses_fp_rs2;
        producer_ctrl.uses_fp_rs3 = decoded_packet.uses_fp_rs3;
        producer_ctrl.is_real = decoded_packet.is_real;
        producer_ctrl.is_varith = id_is_varith(decoded_packet.instruction);
        producer_ctrl.is_vmem = riscv_pkg::is_vector_mem(decoded_packet.instruction.opcode,
                                                         decoded_packet.instruction.funct3);
        producer_ctrl_2.is_load_instruction = decoded_packet_2.is_load_instruction;
        producer_ctrl_2.is_load_unsigned = decoded_packet_2.is_load_unsigned;
        producer_ctrl_2.instruction_operation = decoded_packet_2.instruction_operation;
        producer_ctrl_2.rs_type = decoded_packet_2.rs_type;
        producer_ctrl_2.is_int_store = decoded_packet_2.is_int_store;
        producer_ctrl_2.is_branch_or_jump = decoded_packet_2.is_branch_or_jump;
        producer_ctrl_2.is_fence = decoded_packet_2.is_fence;
        producer_ctrl_2.is_fence_i = decoded_packet_2.is_fence_i;
        producer_ctrl_2.is_csr_imm = decoded_packet_2.is_csr_imm;
        producer_ctrl_2.has_fp_flags = decoded_packet_2.has_fp_flags;
        producer_ctrl_2.needs_lq = decoded_packet_2.needs_lq;
        producer_ctrl_2.needs_sq = decoded_packet_2.needs_sq;
        producer_ctrl_2.is_jump_and_link = decoded_packet_2.is_jump_and_link;
        producer_ctrl_2.is_jump_and_link_register = decoded_packet_2.is_jump_and_link_register;
        producer_ctrl_2.is_csr_instruction = decoded_packet_2.is_csr_instruction;
        producer_ctrl_2.is_amo_instruction = decoded_packet_2.is_amo_instruction;
        producer_ctrl_2.is_lr = decoded_packet_2.is_lr;
        producer_ctrl_2.is_sc = decoded_packet_2.is_sc;
        producer_ctrl_2.is_mret = decoded_packet_2.is_mret;
        producer_ctrl_2.is_sret = decoded_packet_2.is_sret;
        producer_ctrl_2.is_dret = decoded_packet_2.is_dret;
        producer_ctrl_2.is_sfence_vma = decoded_packet_2.is_sfence_vma;
        producer_ctrl_2.is_wfi = decoded_packet_2.is_wfi;
        producer_ctrl_2.is_illegal_instruction = decoded_packet_2.is_illegal_instruction;
        producer_ctrl_2.is_fetch_fault = decoded_packet_2.is_fetch_fault;
        producer_ctrl_2.is_fetch_fault_page = decoded_packet_2.is_fetch_fault_page;
        producer_ctrl_2.is_fp_instruction = decoded_packet_2.is_fp_instruction;
        producer_ctrl_2.is_fp_load = decoded_packet_2.is_fp_load;
        producer_ctrl_2.is_fp_store = decoded_packet_2.is_fp_store;
        producer_ctrl_2.is_compressed = decoded_packet_2.is_compressed;
        producer_ctrl_2.instruction = decoded_packet_2.instruction;
        producer_ctrl_2.btb_predicted_taken = decoded_packet_2.btb_predicted_taken;
        producer_ctrl_2.is_ras_return = decoded_packet_2.is_ras_return;
        producer_ctrl_2.is_ras_call = decoded_packet_2.is_ras_call;
        producer_ctrl_2.has_int_dest = decoded_packet_2.has_int_dest;
        producer_ctrl_2.has_fp_dest = decoded_packet_2.has_fp_dest;
        producer_ctrl_2.uses_int_rs1 = decoded_packet_2.uses_int_rs1;
        producer_ctrl_2.uses_int_rs2 = decoded_packet_2.uses_int_rs2;
        producer_ctrl_2.uses_fp_rs1 = decoded_packet_2.uses_fp_rs1;
        producer_ctrl_2.uses_fp_rs2 = decoded_packet_2.uses_fp_rs2;
        producer_ctrl_2.uses_fp_rs3 = decoded_packet_2.uses_fp_rs3;
        producer_ctrl_2.is_real = decoded_packet_2.is_real;
        producer_ctrl_2.is_varith = id_is_varith(decoded_packet_2.instruction);
        producer_ctrl_2.is_vmem = riscv_pkg::is_vector_mem(decoded_packet_2.instruction.opcode,
                                                           decoded_packet_2.instruction.funct3);
        producer_ctrl_next.is_load_instruction = decoded_packet_next.is_load_instruction;
        producer_ctrl_next.is_load_unsigned = decoded_packet_next.is_load_unsigned;
        producer_ctrl_next.instruction_operation = decoded_packet_next.instruction_operation;
        producer_ctrl_next.rs_type = decoded_packet_next.rs_type;
        producer_ctrl_next.is_int_store = decoded_packet_next.is_int_store;
        producer_ctrl_next.is_branch_or_jump = decoded_packet_next.is_branch_or_jump;
        producer_ctrl_next.is_fence = decoded_packet_next.is_fence;
        producer_ctrl_next.is_fence_i = decoded_packet_next.is_fence_i;
        producer_ctrl_next.is_csr_imm = decoded_packet_next.is_csr_imm;
        producer_ctrl_next.has_fp_flags = decoded_packet_next.has_fp_flags;
        producer_ctrl_next.needs_lq = decoded_packet_next.needs_lq;
        producer_ctrl_next.needs_sq = decoded_packet_next.needs_sq;
        producer_ctrl_next.is_jump_and_link = decoded_packet_next.is_jump_and_link;
        producer_ctrl_next.is_jump_and_link_register =
            decoded_packet_next.is_jump_and_link_register;
        producer_ctrl_next.is_csr_instruction = decoded_packet_next.is_csr_instruction;
        producer_ctrl_next.is_amo_instruction = decoded_packet_next.is_amo_instruction;
        producer_ctrl_next.is_lr = decoded_packet_next.is_lr;
        producer_ctrl_next.is_sc = decoded_packet_next.is_sc;
        producer_ctrl_next.is_mret = decoded_packet_next.is_mret;
        producer_ctrl_next.is_sret = decoded_packet_next.is_sret;
        producer_ctrl_next.is_dret = decoded_packet_next.is_dret;
        producer_ctrl_next.is_sfence_vma = decoded_packet_next.is_sfence_vma;
        producer_ctrl_next.is_wfi = decoded_packet_next.is_wfi;
        producer_ctrl_next.is_illegal_instruction = decoded_packet_next.is_illegal_instruction;
        producer_ctrl_next.is_fetch_fault = decoded_packet_next.is_fetch_fault;
        producer_ctrl_next.is_fetch_fault_page = decoded_packet_next.is_fetch_fault_page;
        producer_ctrl_next.is_fp_instruction = decoded_packet_next.is_fp_instruction;
        producer_ctrl_next.is_fp_load = decoded_packet_next.is_fp_load;
        producer_ctrl_next.is_fp_store = decoded_packet_next.is_fp_store;
        producer_ctrl_next.is_compressed = decoded_packet_next.is_compressed;
        producer_ctrl_next.instruction = decoded_packet_next.instruction;
        producer_ctrl_next.btb_predicted_taken = decoded_packet_next.btb_predicted_taken;
        producer_ctrl_next.is_ras_return = decoded_packet_next.is_ras_return;
        producer_ctrl_next.is_ras_call = decoded_packet_next.is_ras_call;
        producer_ctrl_next.has_int_dest = decoded_packet_next.has_int_dest;
        producer_ctrl_next.has_fp_dest = decoded_packet_next.has_fp_dest;
        producer_ctrl_next.uses_int_rs1 = decoded_packet_next.uses_int_rs1;
        producer_ctrl_next.uses_int_rs2 = decoded_packet_next.uses_int_rs2;
        producer_ctrl_next.uses_fp_rs1 = decoded_packet_next.uses_fp_rs1;
        producer_ctrl_next.uses_fp_rs2 = decoded_packet_next.uses_fp_rs2;
        producer_ctrl_next.uses_fp_rs3 = decoded_packet_next.uses_fp_rs3;
        producer_ctrl_next.is_real = decoded_packet_next.is_real;
        producer_ctrl_next.is_varith = id_is_varith(decoded_packet_next.instruction);
        producer_ctrl_next.is_vmem = riscv_pkg::is_vector_mem(
            decoded_packet_next.instruction.opcode, decoded_packet_next.instruction.funct3);
        producer_ctrl_next_2.is_load_instruction = decoded_packet_next_2.is_load_instruction;
        producer_ctrl_next_2.is_load_unsigned = decoded_packet_next_2.is_load_unsigned;
        producer_ctrl_next_2.instruction_operation = decoded_packet_next_2.instruction_operation;
        producer_ctrl_next_2.rs_type = decoded_packet_next_2.rs_type;
        producer_ctrl_next_2.is_int_store = decoded_packet_next_2.is_int_store;
        producer_ctrl_next_2.is_branch_or_jump = decoded_packet_next_2.is_branch_or_jump;
        producer_ctrl_next_2.is_fence = decoded_packet_next_2.is_fence;
        producer_ctrl_next_2.is_fence_i = decoded_packet_next_2.is_fence_i;
        producer_ctrl_next_2.is_csr_imm = decoded_packet_next_2.is_csr_imm;
        producer_ctrl_next_2.has_fp_flags = decoded_packet_next_2.has_fp_flags;
        producer_ctrl_next_2.needs_lq = decoded_packet_next_2.needs_lq;
        producer_ctrl_next_2.needs_sq = decoded_packet_next_2.needs_sq;
        producer_ctrl_next_2.is_jump_and_link = decoded_packet_next_2.is_jump_and_link;
        producer_ctrl_next_2.is_jump_and_link_register =
            decoded_packet_next_2.is_jump_and_link_register;
        producer_ctrl_next_2.is_csr_instruction = decoded_packet_next_2.is_csr_instruction;
        producer_ctrl_next_2.is_amo_instruction = decoded_packet_next_2.is_amo_instruction;
        producer_ctrl_next_2.is_lr = decoded_packet_next_2.is_lr;
        producer_ctrl_next_2.is_sc = decoded_packet_next_2.is_sc;
        producer_ctrl_next_2.is_mret = decoded_packet_next_2.is_mret;
        producer_ctrl_next_2.is_sret = decoded_packet_next_2.is_sret;
        producer_ctrl_next_2.is_dret = decoded_packet_next_2.is_dret;
        producer_ctrl_next_2.is_sfence_vma = decoded_packet_next_2.is_sfence_vma;
        producer_ctrl_next_2.is_wfi = decoded_packet_next_2.is_wfi;
        producer_ctrl_next_2.is_illegal_instruction = decoded_packet_next_2.is_illegal_instruction;
        producer_ctrl_next_2.is_fetch_fault = decoded_packet_next_2.is_fetch_fault;
        producer_ctrl_next_2.is_fetch_fault_page = decoded_packet_next_2.is_fetch_fault_page;
        producer_ctrl_next_2.is_fp_instruction = decoded_packet_next_2.is_fp_instruction;
        producer_ctrl_next_2.is_fp_load = decoded_packet_next_2.is_fp_load;
        producer_ctrl_next_2.is_fp_store = decoded_packet_next_2.is_fp_store;
        producer_ctrl_next_2.is_compressed = decoded_packet_next_2.is_compressed;
        producer_ctrl_next_2.instruction = decoded_packet_next_2.instruction;
        producer_ctrl_next_2.btb_predicted_taken = decoded_packet_next_2.btb_predicted_taken;
        producer_ctrl_next_2.is_ras_return = decoded_packet_next_2.is_ras_return;
        producer_ctrl_next_2.is_ras_call = decoded_packet_next_2.is_ras_call;
        producer_ctrl_next_2.has_int_dest = decoded_packet_next_2.has_int_dest;
        producer_ctrl_next_2.has_fp_dest = decoded_packet_next_2.has_fp_dest;
        producer_ctrl_next_2.uses_int_rs1 = decoded_packet_next_2.uses_int_rs1;
        producer_ctrl_next_2.uses_int_rs2 = decoded_packet_next_2.uses_int_rs2;
        producer_ctrl_next_2.uses_fp_rs1 = decoded_packet_next_2.uses_fp_rs1;
        producer_ctrl_next_2.uses_fp_rs2 = decoded_packet_next_2.uses_fp_rs2;
        producer_ctrl_next_2.uses_fp_rs3 = decoded_packet_next_2.uses_fp_rs3;
        producer_ctrl_next_2.is_real = decoded_packet_next_2.is_real;
        producer_ctrl_next_2.is_varith = id_is_varith(decoded_packet_next_2.instruction);
        producer_ctrl_next_2.is_vmem = riscv_pkg::is_vector_mem(
            decoded_packet_next_2.instruction.opcode, decoded_packet_next_2.instruction.funct3);
      end
      // An unpredicted JALR in either slot. While it is queued it counts as
      // pending for the control-flow serialization stall.
      assign input_indirect =
          (decoded_packet.is_jump_and_link_register && !decoded_packet.btb_predicted_taken) ||
          (decoded_packet_2.is_real && decoded_packet_2.is_jump_and_link_register &&
           !decoded_packet_2.btb_predicted_taken);
      decoded_bundle_queue #(
          .DEPTH(DECODED_QUEUE_DEPTH),
          .WIDTH(2 * $bits(decoded_packet)),
          .SHADOW_WIDTH(2 * $bits(producer_ctrl) + $bits(producer_vlc) + 1),
          .SPLIT_SHADOW_STALL(1'b1),
          .STALL_LATE_COPIES(riscv_pkg::FetchPaHoldCopies)
      ) u_queue (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_flush(flush_pipeline),
          .i_advance(!pipeline_ctrl.stall),
          .i_valid(pd_valid_q && (decoded_packet.is_real || decoded_packet_2.is_real)),
          .i_packet({decoded_packet_2, decoded_packet}),
          .i_shadow({producer_s2_vec, producer_vlc, producer_ctrl_2, producer_ctrl}),
          .i_shadow_next({
            producer_s2_vec_next, producer_vlc_next, producer_ctrl_next_2, producer_ctrl_next
          }),
          .i_shadow_next_go({
            producer_s2_vec_next_go,
            producer_vlc_next_go,
            producer_ctrl_next_go_2,
            producer_ctrl_next_go
          }),
          .i_shadow_next_hold({
            producer_s2_vec_next_hold,
            producer_vlc_next_hold,
            producer_ctrl_next_hold_2,
            producer_ctrl_next_hold
          }),
          .i_stall_early(frontend_stall_without_pa_hold),
          .i_stall_late(fetch_pa_hold_copy),
          .i_stall_flush(flush_pipeline),
          .i_indirect(input_indirect),
          .i_pop(rob_alloc_req.alloc_valid),
          .o_full(decoded_queue_full),
          .o_valid(queue_valid),
          .o_packet({queue_packet_2, queue_packet}),
          .o_shadow({queue_s2_vec, queue_vlc, queue_ctrl_2, queue_ctrl}),
          .o_shadow_next({queue_s2_vec_next, queue_vlc_next, queue_ctrl_next_2, queue_ctrl_next}),
          .o_indirect_pending(decoded_queue_indirect_pending)
      );
`ifndef SYNTHESIS
      // The queue's split shadow select rebuilds the stall from its terms and
      // takes ID's two outcomes; both must match what ID itself uses.
      always_comb begin
        if (reset_seen_q && !i_rst && !$isunknown(
                {
                  frontend_stall_without_pa_hold,
                  fetch_pa_hold,
                  fetch_pa_hold_copy,
                  flush_pipeline,
                  pipeline_ctrl.stall
                }
            )) begin
          p_queue_stall_terms_exact :
          assert ((((frontend_stall_without_pa_hold || fetch_pa_hold) && !flush_pipeline) ==
                   pipeline_ctrl.stall) &&
                  (fetch_pa_hold_copy == {riscv_pkg::FetchPaHoldCopies{fetch_pa_hold}}));
        end
        if (reset_seen_q && !i_rst && !$isunknown(
                {
                  pipeline_ctrl.stall,
                  producer_s2_vec_next,
                  producer_s2_vec_next_go,
                  producer_s2_vec_next_hold,
                  producer_ctrl_next,
                  producer_ctrl_next_2,
                  producer_ctrl_next_go,
                  producer_ctrl_next_go_2,
                  producer_ctrl_next_hold,
                  producer_ctrl_next_hold_2
                }
            )) begin
          p_queue_shadow_outcomes_exact :
          assert ({producer_s2_vec_next, producer_ctrl_next_2, producer_ctrl_next} ==
                  (pipeline_ctrl.stall ?
                   {producer_s2_vec_next_hold, producer_ctrl_next_hold_2, producer_ctrl_next_hold} :
                   {producer_s2_vec_next_go, producer_ctrl_next_go_2, producer_ctrl_next_go}));
        end
      end
`endif
      assign dispatch_vec_lmul_illegal = queue_vlc;
      assign dispatch_slot2_is_vector = queue_s2_vec;
      assign decoded_queue_valid = queue_valid;
      if (VECTOR) begin : gen_slot1_rs_select
        // Sample the station selects on the same edge as the head shadow so
        // paired admission does not decode the station again at checkpoint save.
        (* keep = "true" *) logic [3:0] select_q;
        for (genvar s = 0; s < 4; s++) begin : gen_station
          always_ff @(posedge i_clk) select_q[s] <= queue_ctrl_next.rs_type == 3'(s);
        end
        assign dispatch_slot1_rs_select = select_q;
`ifndef SYNTHESIS
        always_ff @(posedge i_clk) begin
          if (reset_seen_q && !i_rst && queue_valid) begin
            p_slot1_station_select_current : assert (select_q == (4'b0001 << queue_ctrl.rs_type));
          end
        end
`endif
      end else begin : gen_no_slot1_rs_select
        assign dispatch_slot1_rs_select = '0;
      end
`ifndef SYNTHESIS
      // The shadow moves whole words, so its legality and slot-2 vector bits
      // stay those of its own instructions once reset has loaded it.
      logic [3:0] queue_vlc_check;
      vec_lmul_legality u_vlc_check (
          .i_insn   (32'(queue_ctrl.instruction)),
          .o_illegal(queue_vlc_check)
      );
      always_ff @(posedge i_clk) begin
        if (reset_seen_q && !i_rst && !$isunknown(queue_ctrl.instruction)) begin
          p_queue_vlc_matches_instruction : assert (queue_vlc == queue_vlc_check);
        end
        if (reset_seen_q && !i_rst && !$isunknown(
                {queue_ctrl_2.is_real, queue_ctrl_2.instruction}
            )) begin
          p_queue_s2_vec_matches_instruction :
          assert (queue_s2_vec == (queue_ctrl_2.is_real &&
                  ((queue_ctrl_2.instruction.opcode == riscv_pkg::OPC_OP_V) ||
             (VECTOR && (queue_ctrl_2.instruction.opcode == riscv_pkg::OPC_OP_VE)) ||
                   riscv_pkg::is_vector_mem(
              queue_ctrl_2.instruction.opcode, queue_ctrl_2.instruction.funct3
          ))));
        end
      end
`endif
      // Same-edge shadow source-address copies for INT RAT, FP RAT, and bypass
      // fanout. Each loads the shadow's next value; the original fields still
      // address register-file RAMs and dispatch.
      (* dont_touch = "true" *)logic [19:0] rat_int_src_addr_q;
      (* dont_touch = "true" *)logic [29:0] rat_fp_src_addr_q;
      (* dont_touch = "true" *)logic [29:0] rf_bypass_src_addr_q;
      logic [29:0] shadow_src_addr_next;
      assign shadow_src_addr_next = {
        queue_ctrl_next_2.instruction.funct7[6:2],
        queue_ctrl_next_2.instruction.source_reg_2,
        queue_ctrl_next_2.instruction.source_reg_1,
        queue_ctrl_next.instruction.funct7[6:2],
        queue_ctrl_next.instruction.source_reg_2,
        queue_ctrl_next.instruction.source_reg_1
      };
      always_ff @(posedge i_clk) begin
        rat_int_src_addr_q   <= {shadow_src_addr_next[24:15], shadow_src_addr_next[9:0]};
        rat_fp_src_addr_q    <= shadow_src_addr_next;
        rf_bypass_src_addr_q <= shadow_src_addr_next;
      end
      assign {rat_int_src2_addr_2, rat_int_src1_addr_2, rat_int_src2_addr, rat_int_src1_addr} =
          rat_int_src_addr_q;
      assign {rat_fp_src3_addr_2, rat_fp_src2_addr_2, rat_fp_src1_addr_2,
              rat_fp_src3_addr, rat_fp_src2_addr, rat_fp_src1_addr} = rat_fp_src_addr_q;
      assign rf_bypass_src_addr = rf_bypass_src_addr_q;
`ifndef SYNTHESIS
      logic shadow_src_copies_armed_q = 1'b0;
      logic [29:0] shadow_src_addr;
      assign shadow_src_addr = {
        queue_ctrl_2.instruction.funct7[6:2],
        queue_ctrl_2.instruction.source_reg_2,
        queue_ctrl_2.instruction.source_reg_1,
        queue_ctrl.instruction.funct7[6:2],
        queue_ctrl.instruction.source_reg_2,
        queue_ctrl.instruction.source_reg_1
      };
      always_ff @(posedge i_clk) begin
        if (i_rst) shadow_src_copies_armed_q <= 1'b1;
        if (shadow_src_copies_armed_q && !i_rst) begin
          p_shadow_src_copies_exact :
          assert (rat_fp_src_addr_q == shadow_src_addr && rf_bypass_src_addr_q == shadow_src_addr &&
                  rat_int_src_addr_q == {shadow_src_addr[24:15], shadow_src_addr[9:0]});
        end
      end
`endif
      // Use the registered shadow for narrow control fields, for timing. It must
      // equal those fields in queue_packet; wide payload and
      // btb_correct_non_jalr use the bypass mux.
      always_comb begin
        from_id_to_ex = queue_packet;
        from_id_to_ex_2 = queue_packet_2;
        from_id_to_ex.is_load_instruction = queue_ctrl.is_load_instruction;
        from_id_to_ex.is_load_unsigned = queue_ctrl.is_load_unsigned;
        from_id_to_ex.instruction_operation = queue_ctrl.instruction_operation;
        from_id_to_ex.rs_type = queue_ctrl.rs_type;
        from_id_to_ex.is_int_store = queue_ctrl.is_int_store;
        from_id_to_ex.is_branch_or_jump = queue_ctrl.is_branch_or_jump;
        from_id_to_ex.is_fence = queue_ctrl.is_fence;
        from_id_to_ex.is_fence_i = queue_ctrl.is_fence_i;
        from_id_to_ex.is_csr_imm = queue_ctrl.is_csr_imm;
        from_id_to_ex.has_fp_flags = queue_ctrl.has_fp_flags;
        from_id_to_ex.needs_lq = queue_ctrl.needs_lq;
        from_id_to_ex.needs_sq = queue_ctrl.needs_sq;
        from_id_to_ex.is_jump_and_link = queue_ctrl.is_jump_and_link;
        from_id_to_ex.is_jump_and_link_register = queue_ctrl.is_jump_and_link_register;
        from_id_to_ex.is_csr_instruction = queue_ctrl.is_csr_instruction;
        from_id_to_ex.is_amo_instruction = queue_ctrl.is_amo_instruction;
        from_id_to_ex.is_lr = queue_ctrl.is_lr;
        from_id_to_ex.is_sc = queue_ctrl.is_sc;
        from_id_to_ex.is_mret = queue_ctrl.is_mret;
        from_id_to_ex.is_sret = queue_ctrl.is_sret;
        from_id_to_ex.is_dret = queue_ctrl.is_dret;
        from_id_to_ex.is_sfence_vma = queue_ctrl.is_sfence_vma;
        from_id_to_ex.is_wfi = queue_ctrl.is_wfi;
        from_id_to_ex.is_illegal_instruction = queue_ctrl.is_illegal_instruction;
        from_id_to_ex.is_fetch_fault = queue_ctrl.is_fetch_fault;
        from_id_to_ex.is_fetch_fault_page = queue_ctrl.is_fetch_fault_page;
        from_id_to_ex.is_fp_instruction = queue_ctrl.is_fp_instruction;
        from_id_to_ex.is_fp_load = queue_ctrl.is_fp_load;
        from_id_to_ex.is_fp_store = queue_ctrl.is_fp_store;
        from_id_to_ex.is_compressed = queue_ctrl.is_compressed;
        from_id_to_ex.instruction = queue_ctrl.instruction;
        from_id_to_ex.btb_predicted_taken = queue_ctrl.btb_predicted_taken;
        from_id_to_ex.is_ras_return = queue_ctrl.is_ras_return;
        from_id_to_ex.is_ras_call = queue_ctrl.is_ras_call;
        from_id_to_ex.has_int_dest = queue_ctrl.has_int_dest;
        from_id_to_ex.has_fp_dest = queue_ctrl.has_fp_dest;
        from_id_to_ex.uses_int_rs1 = queue_ctrl.uses_int_rs1;
        from_id_to_ex.uses_int_rs2 = queue_ctrl.uses_int_rs2;
        from_id_to_ex.uses_fp_rs1 = queue_ctrl.uses_fp_rs1;
        from_id_to_ex.uses_fp_rs2 = queue_ctrl.uses_fp_rs2;
        from_id_to_ex.uses_fp_rs3 = queue_ctrl.uses_fp_rs3;
        from_id_to_ex.is_real = queue_ctrl.is_real;
        from_id_to_ex_2.is_load_instruction = queue_ctrl_2.is_load_instruction;
        from_id_to_ex_2.is_load_unsigned = queue_ctrl_2.is_load_unsigned;
        from_id_to_ex_2.instruction_operation = queue_ctrl_2.instruction_operation;
        from_id_to_ex_2.rs_type = queue_ctrl_2.rs_type;
        from_id_to_ex_2.is_int_store = queue_ctrl_2.is_int_store;
        from_id_to_ex_2.is_branch_or_jump = queue_ctrl_2.is_branch_or_jump;
        from_id_to_ex_2.is_fence = queue_ctrl_2.is_fence;
        from_id_to_ex_2.is_fence_i = queue_ctrl_2.is_fence_i;
        from_id_to_ex_2.is_csr_imm = queue_ctrl_2.is_csr_imm;
        from_id_to_ex_2.has_fp_flags = queue_ctrl_2.has_fp_flags;
        from_id_to_ex_2.needs_lq = queue_ctrl_2.needs_lq;
        from_id_to_ex_2.needs_sq = queue_ctrl_2.needs_sq;
        from_id_to_ex_2.is_jump_and_link = queue_ctrl_2.is_jump_and_link;
        from_id_to_ex_2.is_jump_and_link_register = queue_ctrl_2.is_jump_and_link_register;
        from_id_to_ex_2.is_csr_instruction = queue_ctrl_2.is_csr_instruction;
        from_id_to_ex_2.is_amo_instruction = queue_ctrl_2.is_amo_instruction;
        from_id_to_ex_2.is_lr = queue_ctrl_2.is_lr;
        from_id_to_ex_2.is_sc = queue_ctrl_2.is_sc;
        from_id_to_ex_2.is_mret = queue_ctrl_2.is_mret;
        from_id_to_ex_2.is_sret = queue_ctrl_2.is_sret;
        from_id_to_ex_2.is_dret = queue_ctrl_2.is_dret;
        from_id_to_ex_2.is_sfence_vma = queue_ctrl_2.is_sfence_vma;
        from_id_to_ex_2.is_wfi = queue_ctrl_2.is_wfi;
        from_id_to_ex_2.is_illegal_instruction = queue_ctrl_2.is_illegal_instruction;
        from_id_to_ex_2.is_fetch_fault = queue_ctrl_2.is_fetch_fault;
        from_id_to_ex_2.is_fetch_fault_page = queue_ctrl_2.is_fetch_fault_page;
        from_id_to_ex_2.is_fp_instruction = queue_ctrl_2.is_fp_instruction;
        from_id_to_ex_2.is_fp_load = queue_ctrl_2.is_fp_load;
        from_id_to_ex_2.is_fp_store = queue_ctrl_2.is_fp_store;
        from_id_to_ex_2.is_compressed = queue_ctrl_2.is_compressed;
        from_id_to_ex_2.instruction = queue_ctrl_2.instruction;
        from_id_to_ex_2.btb_predicted_taken = queue_ctrl_2.btb_predicted_taken;
        from_id_to_ex_2.is_ras_return = queue_ctrl_2.is_ras_return;
        from_id_to_ex_2.is_ras_call = queue_ctrl_2.is_ras_call;
        from_id_to_ex_2.has_int_dest = queue_ctrl_2.has_int_dest;
        from_id_to_ex_2.has_fp_dest = queue_ctrl_2.has_fp_dest;
        from_id_to_ex_2.uses_int_rs1 = queue_ctrl_2.uses_int_rs1;
        from_id_to_ex_2.uses_int_rs2 = queue_ctrl_2.uses_int_rs2;
        from_id_to_ex_2.uses_fp_rs1 = queue_ctrl_2.uses_fp_rs1;
        from_id_to_ex_2.uses_fp_rs2 = queue_ctrl_2.uses_fp_rs2;
        from_id_to_ex_2.uses_fp_rs3 = queue_ctrl_2.uses_fp_rs3;
        from_id_to_ex_2.is_real = queue_ctrl_2.is_real;
      end
      // Vector arithmetic also waits while the vtype at dispatch is unknown,
      // and a vector load or store while the vector memory table is full.
      assign id_valid_preflush = queue_valid &&
          !(csr_in_flight || csr_wb_pending || serializing_alloc_fire) &&
          !(queue_ctrl.is_varith && !vec_vtype_valid) && !(queue_ctrl.is_vmem && vec_vmt_full);
      assign id_valid_2_preflush = id_valid_preflush && from_id_to_ex_2.is_real;
      assign id_valid = id_valid_preflush && !dispatch_flush;
      assign id_valid_2 = id_valid_2_preflush && !dispatch_flush;
`ifndef SYNTHESIS
      always_ff @(posedge i_clk) begin
        if (reset_seen_q && !i_rst) begin
          p_queue_dispatch_recovery_discards_producer : assert (!dispatch_flush || flush_pipeline);
          if (!flush_pipeline) begin
            p_queue_full_holds_id : assert (!decoded_queue_full || pipeline_ctrl.stall);
            p_queue_pop_has_candidate : assert (!rob_alloc_req.alloc_valid || queue_valid);
            p_queue_pop_has_resources : assert (!rob_alloc_req.alloc_valid || !dispatch_stall);
            p_queue_bundle_is_atomic :
            assert (!(rob_alloc_req.alloc_valid && id_valid_2_preflush) ||
                    rob_alloc_req_2.alloc_valid);
          end
        end
      end
`ifndef FORMAL
      p_queue_held_id_is_stable :
      assert property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst || flush_pipeline)
          pipeline_ctrl.stall |=> $stable(
          {decoded_packet, decoded_packet_2, pd_valid_q}
      ));
`endif
`endif
    end else begin : gen_no_decoded_queue
      assign decoded_queue_full = 1'b0;
      assign decoded_queue_indirect_pending = 1'b0;
      assign decoded_queue_valid = 1'b0;
      assign dispatch_slot1_rs_select = '0;
      assign from_id_to_ex = decoded_packet;
      assign from_id_to_ex_2 = decoded_packet_2;
      vec_lmul_legality u_vlc (
          .i_insn   (32'(decoded_packet.instruction)),
          .o_illegal(dispatch_vec_lmul_illegal)
      );
      assign dispatch_slot2_is_vector = from_id_to_ex_2.is_real &&
          ((from_id_to_ex_2.instruction.opcode == riscv_pkg::OPC_OP_V) ||
             (VECTOR && (from_id_to_ex_2.instruction.opcode == riscv_pkg::OPC_OP_VE)) ||
           riscv_pkg::is_vector_mem(
          from_id_to_ex_2.instruction.opcode, from_id_to_ex_2.instruction.funct3
      ));
      assign rf_bypass_src_addr = {
        from_id_to_ex_2.instruction.funct7[6:2],
        from_id_to_ex_2.instruction.source_reg_2,
        from_id_to_ex_2.instruction.source_reg_1,
        from_id_to_ex.instruction.funct7[6:2],
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1
      };
      assign id_valid_preflush = direct_id_valid_preflush;
      assign id_valid_2_preflush = direct_id_valid_2_preflush;
      assign id_valid = direct_id_valid;
      assign id_valid_2 = direct_id_valid_2;
    end
  endgenerate

  assign dbg_if_valid_q = if_valid_q;
  assign dbg_pd_valid_q = pd_valid_q;
  assign dbg_id_valid   = id_valid;

  // ===========================================================================
  // Tomasulo Wrapper Instance
  // ===========================================================================

  // ROB interface
  riscv_pkg::reorder_buffer_alloc_req_t  rob_alloc_req_raw;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp;
  assign dbg_rob_alloc_valid = rob_alloc_req.alloc_valid;
  assign dbg_rob_alloc_pc = rob_alloc_req.pc;
  assign dbg_rob_alloc_is_csr = rob_alloc_req.is_csr;
  assign dbg_rob_alloc_is_mret = rob_alloc_req.is_mret;
  logic rob_commit_valid;
  logic rob_commit_valid_raw;

  // Slot 2 has independent write ports and needs no commit backpressure.
  // Single step still forces one-wide commit through i_widen_commit_ok.
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb_2;
  riscv_pkg::reorder_buffer_commit_t rob_commit_2;
  logic rob_commit_2_valid_raw;
  logic rob_commit_2_valid;
  assign rob_commit_2_valid = rob_commit_2.valid;
  logic sq_committed_empty_for_trap;
  // Same-cycle sq_committed_empty copy for trap-unit fanout.
  logic sq_committed_empty_trap;
  logic widen_commit_ok;
  assign widen_commit_ok = 1'b1;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_epoch;

  // Save each branch's prediction index by ROB tag and train that entry at
  // commit. No reset is needed: only allocated, committing entries are read.
  logic [riscv_pkg::BpDirIdxBits-1:0] branch_dir_idx_table[riscv_pkg::ReorderBufferDepth];

  // RAT lookup - slot 1. Dispatch's lookup-address outputs drive the RAT
  // only without the decoded queue (gen_rat_addr_from_dispatch); with it the
  // RAT takes the rat_*_addr copies, and these are unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr, int_src2_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr, fp_src2_addr, fp_src3_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  riscv_pkg::rat_lookup_t int_src1_lookup, int_src2_lookup;
  riscv_pkg::rat_lookup_t fp_src1_lookup, fp_src2_lookup, fp_src3_lookup;

  // Slot-2 RAT lookups feed dispatch. FP rs2 supplies store data; FP rs1 and
  // rs3 are unused because bundle rules exclude FP computation from slot 2.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr_2, int_src2_addr_2;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr_2, fp_src2_addr_2, fp_src3_addr_2;
  /* verilator lint_on UNUSEDSIGNAL */
  // Without the decoded queue the RAT lookups take dispatch's address
  // outputs (the bundle's own source fields).
  if (DECODED_QUEUE_DEPTH == 0) begin : gen_rat_addr_from_dispatch
    assign rat_int_src1_addr = int_src1_addr;
    assign rat_int_src2_addr = int_src2_addr;
    assign rat_int_src1_addr_2 = int_src1_addr_2;
    assign rat_int_src2_addr_2 = int_src2_addr_2;
    assign rat_fp_src1_addr = fp_src1_addr;
    assign rat_fp_src2_addr = fp_src2_addr;
    assign rat_fp_src3_addr = fp_src3_addr;
    assign rat_fp_src1_addr_2 = fp_src1_addr_2;
    assign rat_fp_src2_addr_2 = fp_src2_addr_2;
    assign rat_fp_src3_addr_2 = fp_src3_addr_2;
  end
  /* verilator lint_off UNUSEDSIGNAL */
  riscv_pkg::rat_lookup_t int_src1_lookup_2, int_src2_lookup_2;
  riscv_pkg::rat_lookup_t fp_src1_lookup_2, fp_src2_lookup_2, fp_src3_lookup_2;
  /* verilator lint_on UNUSEDSIGNAL */

  // RAT rename - slot 2 (2-wide dispatch).  Dispatch drives these when slot-2
  // fires with a register destination.
  logic                                        rat_alloc_valid_2_raw;
  logic                                        rat_alloc_valid_2;
  logic                                        rat_alloc_dest_rf_2;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg_2;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag_2;

  always_comb begin
    rob_alloc_req = rob_alloc_req_raw;
    rob_alloc_req.alloc_valid = rob_alloc_req_raw.alloc_valid && !full_flush_side_effect_kill;
  end

  assign rat_alloc_valid   = rat_alloc_valid_raw && !full_flush_side_effect_kill;
  assign rat_alloc_valid_2 = rat_alloc_valid_2_raw && !full_flush_side_effect_kill;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rob_entry_epoch <= '0;
    end else begin
      if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready) begin
        rob_entry_epoch[rob_alloc_resp.alloc_tag] <= ~rob_entry_epoch[rob_alloc_resp.alloc_tag];
      end
      if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready) begin
        rob_entry_epoch[rob_alloc_resp_2.alloc_tag] <= ~rob_entry_epoch[rob_alloc_resp_2.alloc_tag];
      end
    end
  end

  // Save each slot's prediction index; the slots predicted different PCs.
  always_ff @(posedge i_clk) begin
    if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp.alloc_tag] <= from_id_to_ex.bp_dir_idx;
    end
    if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp_2.alloc_tag] <= from_id_to_ex_2.bp_dir_idx;
    end
  end

  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic                                        rob_head_dir_train_early;
  logic                                        rob_head_branch_taken_early;

  // ===========================================================================
  // Direction Predictor Commit-Time Training (bimodal)
  // ===========================================================================
  // Train conditional branches at their saved prediction index. Slot-1
  // training has priority over a one-entry slot-2 hold; newer slot-2 training
  // may replace a held update under contention.
  logic                                        dir_update_valid_comb;
  logic [         riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_comb;
  logic                                        dir_update_taken_comb;
  // ROB predecodes equal the commit fields when raw fire is high. Other
  // values are unused because predictor writes require i_update_valid.
  assign dir_update_valid_comb = rob_commit_valid_raw && rob_head_dir_train_early;
  // Use ungated head_tag for the index read, for timing. It equals the commit
  // tag whenever training fires; otherwise the index is unused. Slot 2 uses
  // head_tag+1 by the same argument.
  wire [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag_p1 = head_tag + 1'b1;
  assign dir_update_idx_comb   = branch_dir_idx_table[head_tag];
  assign dir_update_taken_comb = rob_head_branch_taken_early;

  logic                               rob_head_next_dir_train_early;

  // Slot-2 training goes straight through when slot 1 is not training and
  // nothing is held. Otherwise it waits in a one-deep hold (a newer slot-2
  // commit overwrites it) that drains on the next cycle in which slot 1 does
  // not train.
  logic                               dir_update_valid_2_comb;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_2_comb;
  logic                               dir_update_held_valid;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_held_idx;
  logic                               dir_update_held_taken;
  logic                               dir_slot2_pass;
  assign dir_update_valid_2_comb = rob_commit_2_valid_raw && rob_head_next_dir_train_early;
  assign dir_update_idx_2_comb = branch_dir_idx_table[head_tag_p1];
  assign dir_slot2_pass = dir_update_valid_2_comb && !dir_update_valid_comb &&
                          !dir_update_held_valid;

  logic rob_head_next_branch_taken_early;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dir_update_held_valid <= 1'b0;
    end else if (dir_update_valid_2_comb && !dir_slot2_pass) begin
      dir_update_held_valid <= 1'b1;
    end else if (dir_update_held_valid && !dir_update_valid_comb) begin
      dir_update_held_valid <= 1'b0;
    end
  end
  // Capture every slot-2 training payload. A pass-through update requires an
  // empty hold and leaves it empty; all other captures set held valid, so
  // extra captures cannot overwrite an entry that must be retained.
  always_ff @(posedge i_clk) begin
    if (dir_update_valid_2_comb) begin
      dir_update_held_idx   <= dir_update_idx_2_comb;
      dir_update_held_taken <= rob_head_next_branch_taken_early;
    end
  end
`ifndef SYNTHESIS
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_held_idx_ref;
  logic dir_update_held_taken_ref;
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && dir_update_valid_2_comb && !dir_slot2_pass) begin
      dir_update_held_idx_ref   <= dir_update_idx_2_comb;
      dir_update_held_taken_ref <= rob_head_next_branch_taken_early;
    end
  end
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && dir_update_held_valid) begin
      p_dir_update_held_payload_exact :
      assert ((dir_update_held_idx == dir_update_held_idx_ref) &&
              (dir_update_held_taken == dir_update_held_taken_ref));
    end
  end
`endif

  // Select the fallback index before slot-1 arbitration, for timing. A slot-2
  // pass requires an empty hold; a valid hold selects held_idx. With neither,
  // no update fires and the index is unused.
  wire [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_fallback =
      dir_update_held_valid ? dir_update_held_idx : dir_update_idx_2_comb;

  // Register the selected update before IF, adding one cycle. Slot-1 priority
  // can delay an older held slot-2 update past newer slot-1 training.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dir_update_valid <= 1'b0;
      dir_update_idx   <= '0;
      dir_update_taken <= 1'b0;
    end else begin
      dir_update_valid <= dir_update_valid_comb || dir_slot2_pass ||
                          (dir_update_held_valid && !dir_update_valid_comb);
      dir_update_idx <= dir_update_valid_comb ? dir_update_idx_comb : dir_update_idx_fallback;
      dir_update_taken <= dir_update_valid_comb ? dir_update_taken_comb :
                          (dir_slot2_pass ? rob_commit_comb_2.branch_taken :
                           dir_update_held_taken);
    end
  end

  // Slot-2 RS dispatch packets (2-wide dispatch, back-end side).
  // Driven by dispatch and consumed by the wrapper.  A packet's valid asserts
  // when slot-2 fires and routes to that RS family.
  riscv_pkg::rs_dispatch_t int_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_2;

  always_comb begin
    rob_alloc_req_2 = rob_alloc_req_2_raw;
    rob_alloc_req_2.alloc_valid = rob_alloc_req_2_raw.alloc_valid && !full_flush_side_effect_kill;
  end

  // Checkpoint
  logic checkpoint_available;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_alloc_id;
  logic checkpoint_save_raw;
  logic checkpoint_save;
  logic checkpoint_save_for_slot2_raw;
  logic checkpoint_save_for_slot2;
  // Dispatch's early allocation candidates (see dispatch.sv o_alloc_*). The
  // RAT builds its write selects from them and applies the bundle fire
  // (rob_alloc_req.alloc_valid) last.
  logic alloc_has_dest;
  logic alloc_has_dest_2;
  logic checkpoint_slot2_candidate;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_branch_tag;
  logic [riscv_pkg::RasPtrBits-1:0] dispatch_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] dispatch_ras_valid_count;
  logic [XLEN-1:0] dispatch_ras_top;
  logic rob_checkpoint_valid_raw;

  assign checkpoint_save = checkpoint_save_raw && !full_flush_side_effect_kill;
  assign checkpoint_save_for_slot2 = checkpoint_save_for_slot2_raw && !full_flush_side_effect_kill;
  assign rob_checkpoint_valid = rob_checkpoint_valid_raw && !full_flush_side_effect_kill;

  // Resource status
  logic rob_full, rob_empty;
  logic int_rs_full, mul_rs_full, mem_rs_full;
  logic fp_rs_full;
  logic lq_full, sq_full;

  // Slot-2 "room for 2" status from the wrapper.  Used by dispatch to gate
  // slot-2 fire when slot-1 is also targeting the same structure.
  logic rob_full_for_2;
  logic int_rs_full_for_2, mul_rs_full_for_2, mem_rs_full_for_2;
  logic fp_rs_full_for_2;
  logic lq_full_for_2, sq_full_for_2;

  // Branch update
  riscv_pkg::reorder_buffer_branch_update_t branch_update;
  logic rob_commit_misprediction_raw;
  logic rob_commit_correct_branch_raw;
  logic rob_commit_correct_branch_2_raw;
  // Held slot-2 correct-branch training from misprediction_flush_controller.
  // Unlike that module's internal served pulse, it does not depend
  // combinationally on early_mispredict_active.
  logic correct_branch_commit_pending_2_raw;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q_2;
  logic checkpoint_free_2;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id_2;
  logic rob_head_commit_misprediction_candidate;

  // Flush
  logic flush_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag;
  logic commit_recovery_flush_after_head;
  // The flush that clears the LQ: a full flush, or commit-time recovery,
  // which the LQ also treats as a full flush. The router must cancel a held,
  // unaccepted request on the same flush, because the LQ then expects no
  // response for it.
  logic lq_router_flush_all;
  (* max_fanout = 32 *) logic mispredict_recovery_pending;
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;

  // CDB
  riscv_pkg::cdb_broadcast_t cdb_out;
  riscv_pkg::cdb_broadcast_t cdb_out_2;
  logic [riscv_pkg::NumFus-1:0] cdb_grant;

  // ROB status
  logic [riscv_pkg::ReorderBufferTagWidth:0] rob_count;
  logic head_valid, head_done;
  logic fence_class_flush_event;
  logic translation_csr_commit_shadow;
  // Quiet window for the trap unit (its i_pipeline_stall, below): a
  // translation CSR's write cycle and every FENCE-class flush cycle. Built
  // only from registers, so the takes it blocks cannot feed back into it.
  logic fence_class_quiesce;
  assign fence_class_quiesce = translation_csr_commit_shadow || fence_i_flush;
  assign o_fence_i_flush = fence_i_flush;

  // Invalidate the BTB wherever the code or the address space under its
  // entries may have changed, always in a full-flush cycle:
  //   - the FENCE-class flush of a FENCE.I, an SFENCE.VMA or a satp write
  //     (btb_invalidate_q). The frequent mstatus/sstatus writes (SUM/MXR
  //     around user copies) keep the BTB. The translation CSR's commit is on
  //     rob_commit during its shadow cycle; registering here aligns the pulse
  //     with fence_i_flush;
  //   - a trap or xRET that switched fetch between bare and Sv39 addresses
  //     (M-mode fetch is untranslated, so one address can name other code
  //     there);
  //   - a take into or within Debug Mode, whose go runs program-buffer and
  //     abstract-command words the debug module may have rewritten.
  // The last two use the registered take strobes in their flush_all cycle,
  // when the fetch translation and Debug Mode registers already hold the
  // take's result, so the take logic itself reaches no register here.
  always_ff @(posedge i_clk) begin
    if (i_rst) btb_invalidate_q <= 1'b0;
    else
      btb_invalidate_q <= fence_class_flush_event &&
          (!translation_csr_commit_shadow || (rob_commit.csr_addr == riscv_pkg::CsrSatp));
  end
  // A copy of the fetch translation register one cycle late. It needs no
  // reset: it samples a reset register during reset, and only a take reads it.
  always_ff @(posedge i_clk) fetch_translation_active_prev_q <= csr_fetch_translation_active;
  assign btb_invalidate = btb_invalidate_q || (trap_taken_reg && csr_debug_mode) ||
      ((trap_taken_reg || mret_taken_reg) &&
       (csr_fetch_translation_active != fetch_translation_active_prev_q));

  // CSR coordination
  logic csr_start, csr_done_ack;
  logic trap_pending;
  logic trap_mret_commit_hold_q;
  logic [XLEN-1:0] rob_trap_pc;
  logic rob_head_is_wfi;  // ROB head decodes as WFI (drives the WFI interrupt-resume-PC seed)
  logic rob_head_is_amo;  // ROB head decodes as AMO (drives the trap unit's AMO interrupt shield)
  // The head memory instruction's fields, for the misaligned-access engine.
  logic [2:0] rob_head_mem_funct3;
  logic [4:0] rob_head_mem_rs2;
  logic [riscv_pkg::RegAddrWidth-1:0] rob_head_dest_reg;
  logic rob_head_dest_rf, rob_head_dest_valid, rob_head_mem_store, rob_head_mem_fp_store;
  logic rob_head_mem_atomic;
  logic [XLEN-1:0] rob_head_fallthrough_pc;
  // Misaligned-access engine state (declared here, driven with the engine).
  logic ma_busy, ma_hold, ma_shield, ma_done, ma_wb_arm, ma_wb_fp_arm, ma_walk_req_valid;
  // Registered: completion as seen by single step, and the dispatch hold.
  logic ma_done_q, ma_hold_q;
  logic ma_walk_req_ready, ma_walk_resp_valid, ma_rf_read_fp, ma_assist_start;
  logic ma_fault_pending_q, ma_exception_assist, ma_wb_valid_q, ma_wb_fp_q;
  logic [4:0] ma_wb_rd_arm, ma_wb_rd_q;
  logic [riscv_pkg::FpWidth-1:0] ma_wb_data_arm, ma_wb_data_q;
  logic [riscv_pkg::Sv39VpnBits-1:0] ma_walk_vpn;
  logic [XLEN-1:0] ma_fault_tval_q, ma_fault_pc_q;
  riscv_pkg::exc_cause_t ma_fault_cause_q;
  assign extra_rf_read_addr = ma_busy ? ma_rf_read_addr : vec_rf_read_addr;
  // Register-bypass and direction-training field pre-decodes from the ROB
  // (early head/head+1 field conjunctions; see the reorder_buffer ports).
  logic rob_head_bypass_int_we_early;
  logic rob_head_bypass_fp_we_early;
  logic rob_head_next_bypass_int_we_early;
  logic rob_head_next_bypass_fp_we_early;
  // Registered valid AMO-at-head indication (trap_unit.i_amo_at_head).
  // The AMO's at least three-cycle head-to-write delay covers the one-cycle lag.
  logic amo_at_head_shield_q;
  // Hold interrupts from a pending device request through its commit. The
  // router uses device_request_pending_q to check staging; only trap_unit
  // consumes this shield.
  logic device_read_shield_q;
  // An armed interrupt take holds the next device access while the shield is
  // down. Without it, a device access a few instructions behind a store (two
  // device stores, or a cached store and then a device read) re-raises the
  // shield in the cycle the previous access releases it, while the store's
  // commit still clears the SQ's registered committed-empty status. The take
  // then never finds both open, and every interrupt (D, M or S) starves for
  // as long as the loop runs. The hold applies only while the AMO-class
  // shield is down: under that shield the take waits for the head anyway, and
  // an SC at the head may be a precise uncached store that needs the shield
  // to complete. See trap_amo_shield below.
  logic int_take_armed;
  logic device_start_hold;
  // Precomputed next PCs from ungated ROB fields, for timing. Each equals
  // retired_next_pc of its commit packet whenever that commit is valid.
  logic [XLEN-1:0] rob_head_retired_next_pc;
  logic [XLEN-1:0] rob_head_next_retired_next_pc;
  riscv_pkg::exc_cause_t rob_trap_cause;
  riscv_pkg::exc_cause_t rob_trap_cause_remapped;
  logic [1:0] csr_priv;  // current privilege from csr_file (PrivM/PrivS/PrivU)
  // mcounteren CY/TM/IR/HPM3..10 from csr_file (S/U-mode counter gate)
  logic [riscv_pkg::CounterMaskBits-1:0] csr_mcounteren;
  // Arbitrated trap cause for csr_file: interrupt code with bit XLEN-1 set,
  // or the remapped synchronous exception cause.
  logic [XLEN-1:0] trap_cause_internal;
  logic [XLEN-1:0] rob_trap_value;
  logic [31:0] rob_trap_insn;
  // The head's exception is a bus-response access fault, and its virtual
  // address (tomasulo_wrapper).
  logic rob_head_bus_fault;
  logic [XLEN-1:0] rob_head_bus_fault_va;
  logic rob_trap_taken_ack;
  logic mret_start, mret_done_ack;
  logic [XLEN-1:0] mepc_value;
  logic interrupt_pending;
`ifdef FROST_RVFI_DII
`ifdef FROST_RVFI_DII_WFI_TIMEOUT
  logic dii_wfi_wake;
  localparam int unsigned DiiWfiTimeoutCycles = `FROST_RVFI_DII_WFI_TIMEOUT;
`endif
`endif

  // Memory interfaces
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] sq_mem_write_data;
  logic [riscv_pkg::MemStrbBits-1:0] sq_mem_write_byte_en;
  logic sq_mem_write_is_mmio, sq_mem_write_buffered;
  // Registered SQ tier flag routes cached stores away from BRAM.
  logic sq_mem_write_is_cached;
  logic sq_mem_write_done;
  logic sq_mem_write_error;
  riscv_pkg::mem_size_e sq_mem_write_size;
  // C2b: decouple buffered cached store_ack (i_cached_write_inflight &&
  // i_cached_write_done) from bus-busy so cached loads can launch on the
  // store_ack cycle, guarded by load_queue's registered push_prev_q sector
  // hold. Atomic writes still hold i_cached_write_inflight without
  // i_cached_write_done until completion.
  wire cached_write_busy = i_cached_write_inflight && !i_cached_write_done;
  logic slow_write_inflight;
  assign slow_write_inflight = cached_write_busy ||
      (VARIABLE_UNCACHED && i_uncached_write_inflight);

  logic lq_mem_read_en;
  logic lq_mem_addr_valid;
  logic [XLEN-1:0] lq_mem_read_addr;
  riscv_pkg::mem_size_e lq_mem_read_size;
  logic [riscv_pkg::MemDataBits-1:0] lq_mem_read_data;
  logic lq_mem_read_valid;
  logic lq_mem_read_error;
  logic lq_mem_read_is_cached;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_read_id;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_read_launch_id;
  logic lq_mem_read_no_merge;
  logic lq_mem_request_valid;
  logic cached_read_held;
  logic lq_device_request_pending;
  logic uncached_store_pending;

  // AMO memory interface
  logic amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] amo_mem_write_data;
  logic amo_mem_write_is_dword;
  logic amo_mem_write_is_cached;
  logic amo_mem_write_done;
  logic amo_mem_write_error;
  // Router-derived |o_data_mem_bram_byte_wr_en for the debug store mirror.
  logic data_mem_bram_write_any;

  // Slot-1 done-repair channels.
  logic dispatch_bypass_valid_1, dispatch_bypass_valid_2, dispatch_bypass_valid_3;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_1, dispatch_bypass_tag_2, dispatch_bypass_tag_3;
  // Slot-2 done-repair channels.
  logic dispatch_bypass_valid_4, dispatch_bypass_valid_5, dispatch_bypass_valid_6;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_4, dispatch_bypass_tag_5, dispatch_bypass_tag_6;

  // Checkpoint restore (from flush controller)
  logic checkpoint_restore;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_restore_id;
  logic checkpoint_restore_reclaim_all;
  logic [riscv_pkg::RasPtrBits-1:0] restored_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] restored_ras_valid_count;
  logic [XLEN-1:0] restored_ras_top;

  // Checkpoint free (from commit or flush-time reclaim)
  logic checkpoint_free;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id;

  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask;

  // Next checkpoint_in_use, with the same update priorities as the RAT's
  // checkpoint_valid
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use_next;
  always_comb begin
    if (flush_all || checkpoint_restore_reclaim_all) checkpoint_in_use_next = '0;
    else begin
      checkpoint_in_use_next = checkpoint_in_use;
      checkpoint_in_use_next = checkpoint_in_use_next & ~checkpoint_flush_free_mask;
      if (checkpoint_free) checkpoint_in_use_next[checkpoint_free_id] = 1'b0;
      if (checkpoint_free_2) checkpoint_in_use_next[checkpoint_free_id_2] = 1'b0;
      // Save wins over all clears
      if (rob_checkpoint_valid) checkpoint_in_use_next[rob_checkpoint_id] = 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) checkpoint_in_use <= '0;
    else checkpoint_in_use <= checkpoint_in_use_next;
  end

  // Save checkpoint_branch_tag so slot-2 branches record their own ROB tag.
  // Using slot 1's tag would fail checkpoint checks and block branch resolution.
  always_ff @(posedge i_clk) begin
    if (rob_checkpoint_valid) checkpoint_owner_tag[rob_checkpoint_id] <= checkpoint_branch_tag;
  end

  // Reclaim checkpoints for entries younger than flush_tag.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_younger_than_flush;
  logic [riscv_pkg::ReorderBufferTagWidth:0] ckpt_owner_age[riscv_pkg::NumCheckpoints];
  logic [riscv_pkg::ReorderBufferTagWidth:0] ckpt_flush_age;
  always_comb begin
    ckpt_flush_age = {1'b0, flush_tag} - {1'b0, head_tag};
    for (int i = 0; i < riscv_pkg::NumCheckpoints; i++) begin
      ckpt_owner_age[i] = {1'b0, checkpoint_owner_tag[i]} - {1'b0, head_tag};
      // > excludes the restoring checkpoint (freed via checkpoint_free separately)
      checkpoint_younger_than_flush[i] = checkpoint_in_use[i] &&
                                          (ckpt_owner_age[i] > ckpt_flush_age);
    end
  end

  logic flush_after_head;

  // Debug view, read by cocotb checkpoint traces: the checkpoints a partial
  // flush targeted, for the cycle after it. Functional reclaim happens through
  // checkpoint_flush_free_mask, registered inside misprediction_flush_controller;
  // re-freeing the same IDs later from this bitmap would clear newly
  // reallocated checkpoints.
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_pending;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) checkpoint_flush_pending <= '0;
    else if (flush_en)
      checkpoint_flush_pending <= flush_after_head ? checkpoint_in_use
                                                   : checkpoint_younger_than_flush;
    else checkpoint_flush_pending <= '0;
  end

  // LQ/SQ status
  logic lq_empty, sq_empty;
  logic [$clog2(riscv_pkg::LqDepth+1)-1:0] lq_count;
  logic [$clog2(riscv_pkg::SqDepth+1)-1:0] sq_count;
  logic rs_empty;
  logic [$clog2(INT_RS_DEPTH+1)-1:0] rs_count;

  // FRM CSR
  logic [2:0] frm_csr;

  // CSR read data
  logic [XLEN-1:0] csr_read_data;  // registered (1-cycle latency)
  logic [XLEN-1:0] csr_mtvec;
  logic csr_mtvec_traps_misaligned;  // |mtvec[XLEN-1:2], registered in csr_file

  logic coherent_arm_valid, coherent_atomic_active, coherent_atomic_retired;
  logic coherent_exception_valid;
  logic coherent_head_protected, coherent_retire_hold;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_arm_tag, coherent_atomic_tag;
  logic [1:0] coherent_lq_kind;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_lq_tag;
  logic coherent_sq_sc;
  logic coherent_sq_zero, coherent_sq_more, coherent_sq_next_same;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_sq_tag, coherent_amo_tag;
  // An active, unretired context identifies the valid ROB head.
  assign coherent_head_protected = coherent_atomic_active && !coherent_atomic_retired;
  assign coherent_retire_hold = coherent_atomic_active && coherent_atomic_retired &&
      i_coherent_atomic_live;
  assign o_coherent_atomic_protected = coherent_atomic_active;
  assign coherent_exception_valid = trap_pending && !fence_class_quiesce &&
      (!coherent_atomic_active || !i_coherent_atomic_live);
  // The ROB commits its head: its commit tag is head_tag whenever
  // rob_commit_valid_raw is set, so the commit compares here and in the guard
  // read head_tag, a register, and the commit valid applies last. A check
  // below pins the identity.
  assign o_coherent_sc_commit = coherent_atomic_active &&
      rob_commit_valid_raw && head_tag == coherent_atomic_tag &&
      rob_commit_comb.is_sc && !rob_commit_comb.value[0];

  if (1'b1) begin : gen_coherent_atomic
    coherent_atomic_guard #(
        .TAG_BITS(riscv_pkg::ReorderBufferTagWidth)
    ) guard (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_arm_valid(coherent_arm_valid),
        .i_arm_tag(coherent_arm_tag),
        .i_head_valid(head_valid),
        .i_head_tag(head_tag),
        .i_entry_wins(flush_all || lq_router_flush_all || trap_taken || xret_taken ||
            i_fatal_stop || step_done_set || step_done_q),
        .i_commit_valid(rob_commit_valid_raw),
        .i_commit_tag(head_tag),
        .i_home_live(i_coherent_atomic_live),
        .i_own_fault(trap_taken),
        .o_active(coherent_atomic_active),
        .o_retired(coherent_atomic_retired),
        .o_tag(coherent_atomic_tag)
    );
`ifndef SYNTHESIS
    // The trap unit captures the exception before its entry edge.
    logic exception_pending_q, trap_taken_q;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] exception_tag_q;
    always_ff @(posedge i_clk) begin
      trap_taken_q <= !i_rst && trap_taken;
      if (i_rst || trap_taken || trap_taken_q) begin
        exception_pending_q <= 1'b0;
      end else if (coherent_exception_valid) begin
        exception_pending_q <= 1'b1;
        exception_tag_q <= head_tag;
      end
      if (reset_seen_q && !i_rst && rob_commit_valid_raw)
        p_commit_tag_is_head_tag : assert (rob_commit_comb.tag == head_tag);
      if (reset_seen_q && !i_rst && coherent_atomic_active && !i_fatal_stop) begin
        if (!coherent_atomic_retired) assert (head_valid && head_tag == coherent_atomic_tag);
        if (trap_taken) begin
          assert (exception_pending_q && exception_tag_q == coherent_atomic_tag);
          assert (!coherent_atomic_retired && !i_coherent_atomic_live);
        end
        if (lq_router_flush_all) assert (trap_taken);
      end
    end
`endif
  end

  // The coherent L1D pushes a store into its store buffer when the write
  // port carries a mask without an atomic write; the LQ matches the pushed
  // line against its entries for the next cycle's same-sector hold.
  wire coherent_store_push = (|o_data_mem_cached_byte_wr_en && !o_coherent_write_atomic) ||
      i_coherent_twin_push;
  tomasulo_wrapper #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .CMO_HOME(CMO_HOME),
      .MEM_RESPONSE_ERRORS(VARIABLE_UNCACHED),
      .SPLIT_RS_DISPATCH(1'b1),
      .ENABLE_DISPATCH_DONE_REPAIR(1'b1),
      // u_dispatch never fires slot 2 behind a slot-1 branch
      // (slot2_resources_ok), and the requests below reach the ROB with only
      // alloc_valid cleared, so the ROB value RAMs can share one link bank.
      .ROB_SHARED_LINK_BANK(1'b1),
      .PERF_COUNTERS(PERF_COUNTERS),
      .VECTOR(VECTOR),
      .VLEN(VLEN),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .LQ_PROBE_LAUNCH(LQ_PROBE_LAUNCH && CACHED_TIER_EN),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .REGISTERED_SECTOR_MATCH(1'b1)
  ) u_tomasulo (
      .i_coherent_store_pending(i_coherent_store_pending),
      .i_coherent_store_ready(i_coherent_store_ready),
      .i_coherent_sc_pending(i_coherent_sc_pending),
      .i_coherent_atomic_live(i_coherent_atomic_live),
      .i_coherent_block_valid(i_coherent_block_valid),
      .i_coherent_block_addr(i_coherent_block_addr),
      .i_coherent_store_push(coherent_store_push),
      .i_coherent_store_push_addr(i_coherent_twin_push ? i_coherent_twin_push_addr :
                                  o_data_mem_addr),
      .i_coherent_cut_hold(i_coherent_cut_hold),
      .o_coherent_sc_valid(o_coherent_sc_valid),
      .i_coherent_sc_ready(i_coherent_sc_ready),
      .o_coherent_sc_addr(o_coherent_sc_addr),
      .o_coherent_sc_size(o_coherent_sc_size),
      .o_coherent_sc_tag(o_coherent_sc_tag),
      .i_coherent_sc_result_valid(i_coherent_sc_result_valid),
      .o_coherent_sc_result_ready(o_coherent_sc_result_ready),
      .i_coherent_sc_success(i_coherent_sc_success),
      .i_coherent_sc_error(i_coherent_sc_error),
      .i_coherent_sc_write_done(i_coherent_sc_write_done),
      .i_coherent_sc_write_tag(i_coherent_sc_write_tag),
      .o_coherent_reservation_valid(o_coherent_reservation_valid),
      .o_coherent_reservation_addr(o_coherent_reservation_addr),
      .o_coherent_reservation_size(o_coherent_reservation_size),
      .i_coherent_atomic_protected(coherent_head_protected),
      .o_coherent_arm_valid(coherent_arm_valid),
      .o_coherent_arm_tag(coherent_arm_tag),
      .o_coherent_read_kind(coherent_lq_kind),
      .o_coherent_read_tag(coherent_lq_tag),
      .o_coherent_write_sc(coherent_sq_sc),
      .o_coherent_write_zero(coherent_sq_zero),
      .o_cmo_valid(o_cmo_valid),
      .o_cmo_kind(o_cmo_kind),
      .o_cmo_addr(o_cmo_addr),
      .i_cmo_ready(i_cmo_ready),
      .i_cmo_done(i_cmo_done),
      .o_coherent_write_more(coherent_sq_more),
      .o_coherent_next_same(coherent_sq_next_same),
      .o_coherent_sq_write_tag(coherent_sq_tag),
      .o_coherent_amo_write_tag(coherent_amo_tag),
      .i_clk,
      .i_rst_n(rst_n),

      .i_frm_csr(frm_csr),

      // FU completion test injection (unused in production)
      .i_fu_complete_0('0),
      .i_fu_complete_1('0),
      .i_fu_complete_2('0),
      .i_fu_complete_3('0),
      .i_fu_complete_4('0),
      .i_fu_complete_5('0),
      .i_fu_complete_6(vec_vtox_complete),
      .i_fu_complete_7('0),

      // ROB allocation
      .i_alloc_req(rob_alloc_req),
      .o_alloc_resp(rob_alloc_resp),
      // Slot-2 allocation: dispatch raises alloc_valid_2 when slot 2 fires,
      // allocating a second ROB entry (tail+1) in the same cycle as slot 1.
      .i_alloc_req_2(rob_alloc_req_2),
      .o_alloc_resp_2(rob_alloc_resp_2),

      // Current privilege (PrivM/PrivS/PrivU) for the ROB allocation legality check
      .i_priv(csr_priv),
      // Privilege-check bits that csr_file precomputes from its registered
      // state
      .i_counter_blocked(csr_counter_blocked),
      .i_stimecmp_blocked(csr_stimecmp_blocked),
      .i_mireg_illegal(csr_mireg_illegal),
      .i_sireg_illegal(csr_sireg_illegal),
      .i_stopei_illegal(csr_stopei_illegal),
      .i_sret_illegal(csr_sret_illegal),
      .i_sfence_illegal(csr_sfence_illegal),
      .i_wfi_illegal(csr_wfi_illegal),
      .i_priv_is_u(csr_priv_is_u),
      .i_debug_mode(csr_debug_mode),
      // mcounteren CY/TM/IR for the S/U counter-CSR illegal check
      .i_mcounteren(csr_mcounteren),
      // mstatus.FS == Off, sampled for FP legality at ROB allocation
      .i_mstatus_fs_off(csr_mstatus_fs_off),
      .i_mstatus_vs_off(csr_mstatus_vs_off),

      .o_cdb_grant(cdb_grant),
      .o_cdb(cdb_out),
      .o_cdb_2(cdb_out_2),

      // Branch update
      .i_branch_update(branch_update),

      // ROB checkpoint recording
      .i_rob_checkpoint_valid(rob_checkpoint_valid),
      .i_rob_checkpoint_id(rob_checkpoint_id),

      // Commit
      .o_commit(rob_commit),
      .o_vcfg_commit(vcfg_commit),
      .o_vcfg_in_flight(vec_vcfg_in_flight),
      .i_vmt(vec_vmt_view),
      .i_vmem_quiet(vec_vmem_quiet),
      .i_vec_inval_valid(vec_l0_inval_valid),
      .i_vec_inval_addr(vec_l0_inval_addr),
      .o_commit_comb(rob_commit_comb),
      .o_commit_valid_raw(rob_commit_valid_raw),
      .o_commit_misprediction_raw(rob_commit_misprediction_raw),
      .o_commit_correct_branch_raw(rob_commit_correct_branch_raw),
      .o_commit_correct_branch_2_raw(rob_commit_correct_branch_2_raw),
      .o_head_commit_misprediction_candidate(rob_head_commit_misprediction_candidate),

      // Commit slot 2. Its downstream-ready gate (widen_commit_ok) is high
      // because slot 2 has its own register-file write ports.
      .o_commit_2(rob_commit_2),
      .o_commit_comb_2(rob_commit_comb_2),
      .o_commit_2_valid_raw(rob_commit_2_valid_raw),
      // Single step: retire one instruction at a time while a step is armed,
      // so exactly one instruction executes before the halt.
      .i_widen_commit_ok(widen_commit_ok && !step_armed_rob_q),
      // Commit-time branch recovery is registered for timing; hold the ROB
      // during that recovery cycle so younger wrong-path entries cannot retire.
      .i_commit_hold(csr_commit_fire || trap_mret_commit_hold_q ||
                     mispredict_recovery_pending || i_fatal_stop || coherent_retire_hold ||
                     vec_commit_hold),

      // ROB external coordination
      .o_csr_start(csr_start),
      .i_csr_done(csr_done_ack),
      .o_trap_pending(trap_pending),
      .o_trap_pc(rob_trap_pc),
      .o_head_is_wfi(rob_head_is_wfi),
      .o_head_is_amo(rob_head_is_amo),
      .o_head_mem_funct3(rob_head_mem_funct3),
      .o_head_mem_rs2(rob_head_mem_rs2),
      .o_head_dest_reg(rob_head_dest_reg),
      .o_head_dest_rf(rob_head_dest_rf),
      .o_head_dest_valid(rob_head_dest_valid),
      .o_head_mem_store(rob_head_mem_store),
      .o_head_mem_fp_store(rob_head_mem_fp_store),
      .o_head_mem_atomic(rob_head_mem_atomic),
      .o_head_fallthrough_pc(rob_head_fallthrough_pc),
      .o_head_bypass_int_we_early(rob_head_bypass_int_we_early),
      .o_head_bypass_fp_we_early(rob_head_bypass_fp_we_early),
      .o_head_next_bypass_int_we_early(rob_head_next_bypass_int_we_early),
      .o_head_next_bypass_fp_we_early(rob_head_next_bypass_fp_we_early),
      .o_head_dir_train_early(rob_head_dir_train_early),
      .o_head_branch_taken_early(rob_head_branch_taken_early),
      .o_head_next_dir_train_early(rob_head_next_dir_train_early),
      .o_head_next_branch_taken_early(rob_head_next_branch_taken_early),
      .o_head_retired_next_pc(rob_head_retired_next_pc),
      .o_head_next_retired_next_pc(rob_head_next_retired_next_pc),
      .o_trap_cause(rob_trap_cause),
      .o_trap_value(rob_trap_value),
      .o_trap_insn(rob_trap_insn),
      .o_head_bus_fault(rob_head_bus_fault),
      .o_head_bus_fault_va(rob_head_bus_fault_va),
      .i_trap_taken(rob_trap_taken_ack),
      .o_mret_start(mret_start),
      .o_mret_start_is_sret(mret_start_is_sret),
      .o_mret_start_is_dret(mret_start_is_dret),
      .i_mret_done(mret_done_ack),
      .i_mepc(mepc_value),
      .i_sepc(csr_sepc),
      .i_dpc(csr_dpc),
      // WFI wake: any raw pending interrupt, or Debug Mode or an armed single
      // step, where WFI executes as a nop (interrupts are masked there, so a
      // real wait would deadlock the debugger).
`ifdef FROST_RVFI_DII
      // TestRIG selects a bounded WFI wait at build time.
`ifdef FROST_RVFI_DII_WFI_TIMEOUT
      .i_interrupt_pending(dii_wfi_wake),
`else
      .i_interrupt_pending(1'b1),
`endif
      // Misaligned accesses trap whatever mtvec holds.
      .i_trap_misaligned_accesses(1'b1),
`else
      .i_interrupt_pending(interrupt_pending || csr_debug_mode || step_armed_q),
      // The AXI integration never emits misaligned accesses, including
      // speculative accesses before firmware has installed mtvec. Keep the
      // legacy local-memory policy only for the fixed-latency test interface.
      .i_trap_misaligned_accesses(VARIABLE_UNCACHED || csr_mtvec_traps_misaligned),
`endif

      // Flush
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_flush_all(flush_all),
      .i_flush_after_head_commit(commit_recovery_flush_after_head),
      .i_backend_recovery_hold(backend_recovery_hold || (step_done_q) || ma_hold_q),
      .i_slow_write_inflight(slow_write_inflight),
      .i_uncached_read_busy(
          (VARIABLE_UNCACHED && !i_uncached_read_request_ready) || vec_unc_bus_busy
      ),
      .i_coh_admit_valid(i_coh_admit_valid),
      .i_coh_admit_slot(i_coh_admit_slot),
      .i_coh_admit_addr(i_coh_admit_addr),
      .o_coh_admit_ready(o_coh_admit_ready),
      .o_coh_admit_clean(o_coh_admit_clean),
      .i_coh_inval_valid(i_coh_inval_valid),
      .i_coh_inval_slot(i_coh_inval_slot),
      .o_coh_inval_done(o_coh_inval_done),
      .i_coh_release_valid(i_coh_release_valid),
      .i_coh_release_slot(i_coh_release_slot),
      .i_cached_read_held(cached_read_held),
      .i_lq_mem_request_pending(lq_mem_request_valid),

      // Early misprediction recovery
      .i_early_recovery_flush(early_backend_recovery_pending),
      .i_early_recovery_en(early_recovery_en),
      .i_early_recovery_tag(early_recovery_tag),

      // ROB status
      .o_fence_i_flush(fence_i_flush),
      .o_fence_class_flush_event(fence_class_flush_event),
      .o_translation_csr_commit_shadow(translation_csr_commit_shadow),
      .o_sq_committed_empty(sq_committed_empty),
      .o_sq_committed_empty_trap(sq_committed_empty_trap),
      .i_fence_i_sync_done(i_fence_i_sync_done),
      .o_fence_i_sync_req(o_fence_i_sync_req),
      .i_translation_active(csr_translation_active),
      .i_mmu_sum(csr_mmu_sum),
      .i_mmu_mxr(csr_mmu_mxr),
      .i_mmu_eff_priv_u(csr_mmu_eff_priv_u),
      .i_mmu_pm_mode(csr_mmu_pm_mode),
      .i_csr_translation_flush_req(csr_translation_flush_req),
      .o_tlb_invalidate(tlb_invalidate),
      .i_csr_tlb_flush_all_req(csr_tlb_flush_all_req),
      .o_tlb_flush(tlb_flush),
      .i_mmu_asid(csr_mmu_asid),
      .o_walk_req_valid(walk_req_valid),
      .i_walk_req_ready(walk_req_ready),
      .o_walk_vpn(walk_vpn),
      .o_walk_hold(walk_hold),
      .i_walk_resp_valid(walk_resp_valid),
      .i_walk_resp(walk_resp),
      .o_rob_full(rob_full),
      .o_rob_full_for_2(rob_full_for_2),
      .o_rob_empty(rob_empty),
      .o_rob_count(rob_count),
      .o_head_tag(head_tag),
      .o_head_valid(head_valid),
      .o_head_done(head_done),

      // ROB entry state and dispatch done-repair reads
      .o_rob_entry_done_vec(),
      .i_rob_entry_epoch(rob_entry_epoch),
      .i_bypass_valid_1(dispatch_bypass_valid_1),
      .i_bypass_tag_1(dispatch_bypass_tag_1),
      .o_bypass_value_1(),
      .i_bypass_valid_2(dispatch_bypass_valid_2),
      .i_bypass_tag_2(dispatch_bypass_tag_2),
      .o_bypass_value_2(),
      .i_bypass_valid_3(dispatch_bypass_valid_3),
      .i_bypass_tag_3(dispatch_bypass_tag_3),
      .o_bypass_value_3(),
      .i_bypass_valid_4(dispatch_bypass_valid_4),
      .i_bypass_tag_4(dispatch_bypass_tag_4),
      .o_bypass_value_4(),
      .i_bypass_valid_5(dispatch_bypass_valid_5),
      .i_bypass_tag_5(dispatch_bypass_tag_5),
      .o_bypass_value_5(),
      .i_bypass_valid_6(dispatch_bypass_valid_6),
      .i_bypass_tag_6(dispatch_bypass_tag_6),
      .o_bypass_value_6(),

      // RAT source lookups - slot 1 (addresses: rat_*_addr, the
      // consumer-local copies of the bundle's source fields)
      .i_int_src1_addr(rat_int_src1_addr),
      .i_int_src2_addr(rat_int_src2_addr),
      .o_int_src1(int_src1_lookup),
      .o_int_src2(int_src2_lookup),
      .i_fp_src1_addr(rat_fp_src1_addr),
      .i_fp_src2_addr(rat_fp_src2_addr),
      .i_fp_src3_addr(rat_fp_src3_addr),
      .o_fp_src1(fp_src1_lookup),
      .o_fp_src2(fp_src2_lookup),
      .o_fp_src3(fp_src3_lookup),

      // RAT source lookups - slot 2 (2-wide dispatch)
      .i_int_src1_addr_2(rat_int_src1_addr_2),
      .i_int_src2_addr_2(rat_int_src2_addr_2),
      .o_int_src1_2(int_src1_lookup_2),
      .o_int_src2_2(int_src2_lookup_2),
      .i_fp_src1_addr_2(rat_fp_src1_addr_2),
      .i_fp_src2_addr_2(rat_fp_src2_addr_2),
      .i_fp_src3_addr_2(rat_fp_src3_addr_2),
      .o_fp_src1_2(fp_src1_lookup_2),
      .o_fp_src2_2(fp_src2_lookup_2),
      .o_fp_src3_2(fp_src3_lookup_2),

      // RAT regfile data - slot 1
      .i_int_regfile_data1(int_rf_dispatch_rs1_data),
      .i_int_regfile_data2(int_rf_dispatch_rs2_data),
      .i_fp_regfile_data1 (fp_rf_dispatch_rs1_data),
      .i_fp_regfile_data2 (fp_rf_dispatch_rs2_data),
      .i_fp_regfile_data3 (fp_rf_dispatch_rs3_data),

      // RAT regfile data for slot 2, wired through dispatch-stage reads with
      // widen-commit bypass.
      .i_int_regfile_data1_2(int_rf_dispatch_rs1_data_2),
      .i_int_regfile_data2_2(int_rf_dispatch_rs2_data_2),
      .i_fp_regfile_data1_2 (fp_rf_dispatch_rs1_data_2),
      .i_fp_regfile_data2_2 (fp_rf_dispatch_rs2_data_2),
      .i_fp_regfile_data3_2 (fp_rf_dispatch_rs3_data_2),

      // RAT rename - slot 1
      .i_rat_alloc_valid(rat_alloc_valid),
      .i_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .i_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .i_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT rename - slot 2 (2-wide dispatch; dispatch raises valid_2 on fire)
      .i_rat_alloc_valid_2(rat_alloc_valid_2),
      .i_rat_alloc_dest_rf_2(rat_alloc_dest_rf_2),
      .i_rat_alloc_dest_reg_2(rat_alloc_dest_reg_2),
      .i_rat_alloc_rob_tag_2(rat_alloc_rob_tag_2),

      // RAT checkpoint save
      .i_checkpoint_save(checkpoint_save),
      .i_checkpoint_id(checkpoint_id),
      .i_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(dispatch_ras_tos),
      .i_ras_valid_count(dispatch_ras_valid_count),
      .i_ras_top(dispatch_ras_top),
      .i_checkpoint_save_for_slot2(checkpoint_save_for_slot2),

      // Early allocation candidates and the bundle fire they combine with
      .i_alloc_fire(rob_alloc_req.alloc_valid),
      .i_alloc_has_dest(alloc_has_dest),
      .i_alloc_has_dest_2(alloc_has_dest_2),
      .i_checkpoint_slot2_candidate(checkpoint_slot2_candidate),

      // RAT checkpoint restore
      .i_checkpoint_restore(checkpoint_restore),
      .i_checkpoint_restore_id(checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
      .i_checkpoint_flush_free_mask(checkpoint_flush_free_mask),
      .o_ras_tos(restored_ras_tos),
      .o_ras_valid_count(restored_ras_valid_count),
      .o_ras_top(restored_ras_top),

      // RAT checkpoint free
      .i_checkpoint_free(checkpoint_free),
      .i_checkpoint_free_id(checkpoint_free_id),
      .i_checkpoint_free_2(checkpoint_free_2),
      .i_checkpoint_free_id_2(checkpoint_free_id_2),

      // RAT checkpoint availability
      .o_checkpoint_available(checkpoint_available),
      .o_checkpoint_alloc_id (checkpoint_alloc_id),

      // RS dispatch
      .i_rs_dispatch('0),
      .i_int_rs_dispatch(int_rs_dispatch),
      .i_mul_rs_dispatch(mul_rs_dispatch),
      .i_mem_rs_dispatch(mem_rs_dispatch),
      .i_fp_rs_dispatch(fp_rs_dispatch),
      // Slot-2 RS dispatch, driven by the dispatch unit. The wrapper
      // forwards what dispatch produces; valids assert when slot-2 fires.
      .i_int_rs_dispatch_2(int_rs_dispatch_2),
      .i_mul_rs_dispatch_2(mul_rs_dispatch_2),
      .i_mem_rs_dispatch_2(mem_rs_dispatch_2),
      .i_fp_rs_dispatch_2(fp_rs_dispatch_2),
      .o_rs_full(),

      // RS issue + status (INT_RS)
      .o_rs_issue(rs_issue_int),
      .o_rs_issue_branch_predicate_tag(rs_issue_int_branch_predicate_tag),
      .i_rs_fu_ready(1'b1),
      .o_int_rs_full(int_rs_full),
      .o_int_rs_full_for_2(int_rs_full_for_2),
      .o_rs_empty(rs_empty),
      .o_rs_count(rs_count),

      // MUL_RS
      .o_mul_rs_issue(rs_issue_mul),
      .i_mul_rs_fu_ready(1'b1),
      .o_mul_rs_full(mul_rs_full),
      .o_mul_rs_full_for_2(mul_rs_full_for_2),
      .o_mul_rs_empty(),
      .o_mul_rs_count(),

      // MEM_RS
      .o_mem_rs_issue(rs_issue_mem),
      .i_mem_rs_fu_ready(1'b1),
      .o_mem_rs_full(mem_rs_full),
      .o_mem_rs_full_for_2(mem_rs_full_for_2),
      .o_mem_rs_empty(),
      .o_mem_rs_count(),

      // FP_RS
      .o_fp_rs_issue(rs_issue_fp),
      .i_fp_rs_fu_ready(1'b1),
      .o_fp_rs_full(fp_rs_full),
      .o_fp_rs_full_for_2(fp_rs_full_for_2),
      .o_fp_rs_empty(),
      .o_fp_rs_count(),

      // Store queue memory interface
      .o_sq_mem_write_en(sq_mem_write_en),
      .o_sq_mem_write_addr(sq_mem_write_addr),
      .o_sq_mem_write_data(sq_mem_write_data),
      .o_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .o_sq_mem_write_buffered(sq_mem_write_buffered),
      .o_sq_mem_write_size(sq_mem_write_size),
      .o_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .o_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_sq_mem_write_done(sq_mem_write_done),
      .i_sq_mem_write_error(sq_mem_write_error),
      .o_uncached_store_pending(uncached_store_pending),
      .i_uncached_store_shield(device_read_shield_q),

      // Load queue memory interface
      .o_lq_mem_read_en(lq_mem_read_en),
      .o_lq_mem_addr_valid(lq_mem_addr_valid),
      .o_lq_mem_read_addr(lq_mem_read_addr),
      .o_lq_mem_read_size(lq_mem_read_size),
      .o_lq_mem_read_id(lq_mem_read_launch_id),
      .o_lq_mem_read_no_merge(lq_mem_read_no_merge),
      .i_lq_mem_read_data(lq_mem_read_data),
      .i_lq_mem_read_valid(lq_mem_read_valid),
      .i_lq_mem_read_error(lq_mem_read_error),
      .i_lq_mem_read_is_cached(lq_mem_read_is_cached),
      .i_lq_mem_read_id(lq_mem_read_id),

      // LQ/SQ status
      .o_lq_full(lq_full),
      .o_lq_full_for_2(lq_full_for_2),
      .o_lq_empty(lq_empty),
      .o_lq_count(lq_count),
      .o_sq_full(sq_full),
      .o_sq_full_for_2(sq_full_for_2),
      .o_sq_empty(sq_empty),
      .o_sq_count(sq_count),

      // AMO memory interface
      .o_amo_mem_write_en(amo_mem_write_en),
      .o_amo_mem_write_addr(amo_mem_write_addr),
      .o_amo_mem_write_data(amo_mem_write_data),
      .o_amo_mem_write_is_dword(amo_mem_write_is_dword),
      .o_amo_mem_write_is_cached(amo_mem_write_is_cached),
      .i_amo_mem_write_done(amo_mem_write_done),
      .i_amo_mem_write_error(amo_mem_write_error),

      // Profiling snapshot
      .i_perf_snapshot_capture(perf_snapshot_capture),
      .i_perf_counter_select (wrapper_perf_counter_select),
      .o_perf_counter_data   (wrapper_perf_counter_data),

      // Width-funnel perf observers (registered inside the wrapper; counted
      // as top-level counters by perf_counter_aggregator).
      .o_perf_mem_rs_two_ready_one_issued(perf_mem_rs_two_ready_one_issued),
      .o_perf_cdb_oversubscribed(perf_cdb_oversubscribed)
  );

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) trap_mret_commit_hold_q <= 1'b0;
    // A drain holds younger retirement. The protected cached SC retires
    // before its pending write can complete.
    else
      trap_mret_commit_hold_q <= trap_pending || mret_start ||
      (trap_drain_wait && !coherent_head_protected) ||
      // Single step: after the stepped instruction retires, hold the next
      // head until the debug halt lands (registered: the first retirement
      // decides this cycle, the hold blocks the next one).
      step_done_set || step_done_q;
  end

  // Single-step engine. DRET with dcsr.step arms the step. The first
  // retirement event afterwards marks it done: a commit, an xRET, or a trap
  // into M or S (the stepped instruction faulting, in which case dpc lands on
  // its handler's first instruction, per the spec). Done raises the trap
  // unit's step request, which halts at the next head. Both bits clear on the
  // Debug Mode entry, whatever its cause: an ebreak stepped into, or a
  // simultaneous haltreq, wins its own cause.
  assign step_done_set = step_armed_q && !step_done_q &&
      (rob_commit_valid_raw || xret_taken || (trap_taken && !trap_to_d && !trap_no_csr) ||
       ma_done_q);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      step_armed_q     <= 1'b0;
      step_armed_rob_q <= 1'b0;
      step_done_q      <= 1'b0;
    end else if (trap_taken && trap_to_d) begin
      step_armed_q     <= 1'b0;
      step_armed_rob_q <= 1'b0;
      step_done_q      <= 1'b0;
    end else begin
      if (dret_taken && csr_dcsr_step) begin
        step_armed_q     <= 1'b1;
        step_armed_rob_q <= 1'b1;
      end
      if (step_done_set) step_done_q <= 1'b1;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      assert (step_armed_rob_q == step_armed_q)
      else $error("step_armed_rob_q diverged from step_armed_q");
    end
  end
`endif

  // Debug Mode bookkeeping for the debug module: parked = in Debug Mode with
  // no command running (a go starts one; the re-park on its ebreak or
  // exception ends it); the exception flag is sticky until the next go.
  logic dbg_cmd_active_q, dbg_cmd_err_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dbg_cmd_active_q <= 1'b0;
      dbg_cmd_err_q    <= 1'b0;
    end else begin
      if (dbg_go_taken) begin
        dbg_cmd_active_q <= 1'b1;
        dbg_cmd_err_q    <= 1'b0;
      end else if (dbg_park_entry || dret_taken) begin
        dbg_cmd_active_q <= 1'b0;
        if (dbg_park_exception) dbg_cmd_err_q <= 1'b1;
      end
    end
  end
  assign o_debug_mode = csr_debug_mode;
  assign o_dbg_parked = csr_debug_mode && !dbg_cmd_active_q;
  assign o_dbg_cmd_err = dbg_cmd_err_q;
  assign o_dbg_go_taken = dbg_go_taken;
  // Low-BRAM store snoop for the debug instruction mirror. Use the router's
  // any-byte flag for timing.
  assign o_dbg_bram_store = data_mem_bram_write_any;
  assign o_dbg_bram_store_addr = o_data_mem_addr[31:0];
  assign o_dbg_bram_store_strb = o_data_mem_bram_byte_wr_en;

  // ===========================================================================
  // Dispatch Unit
  // ===========================================================================

  dispatch #(
      .VECTOR(VECTOR),
      .SLOT2_VALID_FROM_BUNDLE(DECODED_QUEUE_DEPTH > 0),
      .REGISTERED_QUEUE_CLASSES(VECTOR && DECODED_QUEUE_DEPTH > 0),
      // The int_rf_dispatch_* reads below also feed the RAT's regfile-data
      // inputs, which is the contract RAW_INT_RF_VALUES needs.
      .RAW_INT_RF_VALUES(1'b1)
  ) u_dispatch (
      .i_vtype_spec(vec_vtype_spec),
      .i_vec_arith_illegal(vec_arith_illegal),
      .i_vec_restart_ok(vec_restart_ok),
      .i_slot1_rs_select(dispatch_slot1_rs_select),
      .i_vec_lmul_illegal(dispatch_vec_lmul_illegal),
      .i_vec_vstart_nonzero(vec_vstart_nonzero),
      .i_slot2_is_vector(dispatch_slot2_is_vector),
      .i_clk,
      .i_rst_n(rst_n),

      .i_from_id_to_ex(from_id_to_ex),
      // Preflush candidate: dispatch applies the recovery kill itself,
      // through i_flush below.
      .i_valid(id_valid_preflush),

      // Slot 2 is valid when the bundle is a candidate and slot 2 is real,
      // including a program NOP. i_flush suppresses both slots on recovery.
      .i_from_id_to_ex_2(from_id_to_ex_2),
      .i_valid_2(id_valid_2_preflush),

      .i_rs1_addr(from_id_to_ex.instruction.source_reg_1),
      .i_rs2_addr(from_id_to_ex.instruction.source_reg_2),
      .i_fp_rs3_addr(from_id_to_ex.instruction.funct7[6:2]),

      // Slot-2 source register addresses (2-wide dispatch).
      .i_rs1_addr_2(from_id_to_ex_2.instruction.source_reg_1),
      .i_rs2_addr_2(from_id_to_ex_2.instruction.source_reg_2),
      .i_fp_rs3_addr_2(from_id_to_ex_2.instruction.funct7[6:2]),

      .i_frm_csr(frm_csr),

      // ROB
      .o_rob_alloc_req (rob_alloc_req_raw),
      .i_rob_alloc_resp(rob_alloc_resp),

      // Slot-2 ROB alloc (2-wide dispatch)
      .o_rob_alloc_req_2 (rob_alloc_req_2_raw),
      .i_rob_alloc_resp_2(rob_alloc_resp_2),

      // RAT lookups - slot 1
      .o_int_src1_addr(int_src1_addr),
      .o_int_src2_addr(int_src2_addr),
      .o_fp_src1_addr (fp_src1_addr),
      .o_fp_src2_addr (fp_src2_addr),
      .o_fp_src3_addr (fp_src3_addr),

      .i_int_src1(int_src1_lookup),
      .i_int_src2(int_src2_lookup),
      .i_fp_src1 (fp_src1_lookup),
      .i_fp_src2 (fp_src2_lookup),
      .i_fp_src3 (fp_src3_lookup),

      // RAT lookups - slot 2 (2-wide dispatch)
      .o_int_src1_addr_2(int_src1_addr_2),
      .o_int_src2_addr_2(int_src2_addr_2),
      .o_fp_src1_addr_2 (fp_src1_addr_2),
      .o_fp_src2_addr_2 (fp_src2_addr_2),
      .o_fp_src3_addr_2 (fp_src3_addr_2),

      .i_int_src1_2(int_src1_lookup_2),
      .i_int_src2_2(int_src2_lookup_2),
      .i_fp_src1_2 (fp_src1_lookup_2),
      .i_fp_src2_2 (fp_src2_lookup_2),
      .i_fp_src3_2 (fp_src3_lookup_2),

      // Bypassed INT register-file reads (the RAT lookups' value source).
      .i_int_rf_rs1_data  (int_rf_dispatch_rs1_data),
      .i_int_rf_rs2_data  (int_rf_dispatch_rs2_data),
      .i_int_rf_rs1_data_2(int_rf_dispatch_rs1_data_2),
      .i_int_rf_rs2_data_2(int_rf_dispatch_rs2_data_2),

      // RAT rename - slot 1
      .o_rat_alloc_valid(rat_alloc_valid_raw),
      .o_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .o_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .o_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT rename - slot 2 (dispatch asserts valid_2 when slot-2 fires)
      .o_rat_alloc_valid_2(rat_alloc_valid_2_raw),
      .o_rat_alloc_dest_rf_2(rat_alloc_dest_rf_2),
      .o_rat_alloc_dest_reg_2(rat_alloc_dest_reg_2),
      .o_rat_alloc_rob_tag_2(rat_alloc_rob_tag_2),

      // ROB done-entry repair read request
      .o_bypass_valid_1(dispatch_bypass_valid_1),
      .o_bypass_tag_1  (dispatch_bypass_tag_1),
      .o_bypass_valid_2(dispatch_bypass_valid_2),
      .o_bypass_tag_2  (dispatch_bypass_tag_2),
      .o_bypass_valid_3(dispatch_bypass_valid_3),
      .o_bypass_tag_3  (dispatch_bypass_tag_3),
      .o_bypass_valid_4(dispatch_bypass_valid_4),
      .o_bypass_tag_4  (dispatch_bypass_tag_4),
      .o_bypass_valid_5(dispatch_bypass_valid_5),
      .o_bypass_tag_5  (dispatch_bypass_tag_5),
      .o_bypass_valid_6(dispatch_bypass_valid_6),
      .o_bypass_tag_6  (dispatch_bypass_tag_6),

      // RS dispatch
      .o_rs_dispatch(),
      .o_int_rs_dispatch(int_rs_dispatch),
      .o_mul_rs_dispatch(mul_rs_dispatch),
      .o_mem_rs_dispatch(mem_rs_dispatch),
      .o_fp_rs_dispatch(fp_rs_dispatch),

      // Slot-2 RS dispatch (2-wide dispatch). At most one packet has .valid=1
      // per cycle: the RS family slot-2 routes to when it fires.
      .o_int_rs_dispatch_2(int_rs_dispatch_2),
      .o_mul_rs_dispatch_2(mul_rs_dispatch_2),
      .o_mem_rs_dispatch_2(mem_rs_dispatch_2),
      .o_fp_rs_dispatch_2 (fp_rs_dispatch_2),

      // Checkpoint management
      .i_checkpoint_available(checkpoint_available),
      .i_checkpoint_alloc_id(checkpoint_alloc_id),
      .o_checkpoint_save(checkpoint_save_raw),
      .o_checkpoint_save_for_slot2(checkpoint_save_for_slot2_raw),
      .o_alloc_has_dest(alloc_has_dest),
      .o_alloc_has_dest_2(alloc_has_dest_2),
      .o_checkpoint_slot2_candidate(checkpoint_slot2_candidate),
      .o_checkpoint_id(checkpoint_id),
      .o_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(from_if_to_pd.ras_checkpoint_tos),
      .i_ras_valid_count(from_if_to_pd.ras_checkpoint_valid_count),
      .o_ras_tos(dispatch_ras_tos),
      .o_ras_valid_count(dispatch_ras_valid_count),
      .o_ras_top(dispatch_ras_top),
      .o_rob_checkpoint_valid(rob_checkpoint_valid_raw),
      .o_rob_checkpoint_id(rob_checkpoint_id),

      // Resource status
      .i_rob_full(rob_full),
      .i_int_rs_full(int_rs_full),
      .i_mul_rs_full(mul_rs_full),
      .i_mem_rs_full(mem_rs_full),
      .i_fp_rs_full(fp_rs_full),
      .i_lq_full(lq_full),
      .i_sq_full(sq_full),

      // Slot-2 "room for 2" status from the wrapper.
      .i_rob_full_for_2(rob_full_for_2),
      .i_int_rs_full_for_2(int_rs_full_for_2),
      .i_mul_rs_full_for_2(mul_rs_full_for_2),
      .i_mem_rs_full_for_2(mem_rs_full_for_2),
      .i_fp_rs_full_for_2(fp_rs_full_for_2),
      .i_lq_full_for_2(lq_full_for_2),
      .i_sq_full_for_2(sq_full_for_2),

      // Flush / early-recovery hold
      .i_flush(dispatch_flush),
      // The misaligned-access engine also holds dispatch: the router's hold
      // alone drops the RS write but still allocates the ROB entry.
      .i_hold (early_backend_recovery_hold || ma_hold_q),

      // Dispatch profiling status
      .o_status(dispatch_status),

      // Stall output
      .o_stall(dispatch_stall)
  );

  // ===========================================================================
  // Branch Resolution Unit
  // ===========================================================================
  // INT_RS conditional branches complete through branch_resolution only;
  // JALR also writes its link through the ALU shim. A same-edge tag copy
  // feeds the branch checkpoint and age predicates.
  logic            is_jalr_issue;
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;
  // Every branch holds a checkpoint, so this is the resolving branch's own.
  assign branch_resolved_checkpoint_id = rs_issue_int.checkpoint_id;

  branch_resolution #(
      .XLEN(XLEN)
  ) branch_resolution_inst (
`ifndef SYNTHESIS
      .i_check_enable(reset_seen_q && !i_rst),
`endif
      .i_rs_issue_int(rs_issue_int),
      .i_branch_predicate_tag(rs_issue_int_branch_predicate_tag),
      .i_head_tag(head_tag),
      .i_early_mispredict_tag(early_mispredict_tag),
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_backend_recovery_pending(early_backend_recovery_pending),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_flush_for_trap(flush_for_trap),
      .i_flush_for_mret(flush_for_mret),
      .i_fence_i_flush(fence_i_flush),
      .i_checkpoint_in_use(checkpoint_in_use),
      .i_checkpoint_owner_tag(checkpoint_owner_tag),
      .o_branch_update(branch_update),
      .o_branch_resolved_correct(branch_resolved_correct),
      .o_is_jalr_issue(is_jalr_issue),
      .o_branch_taken_resolved(branch_taken_resolved),
      .o_branch_target_resolved(branch_target_resolved)
  );

`ifndef SYNTHESIS
`ifndef FORMAL
  // LQ bus-busy includes router write-port terms and pending valid, so a
  // handoff cannot meet a busy write port or an occupied hold. Device reads
  // use the hold for staging; full flush cancels them before acceptance.
  // The fixed-latency profile returns accepted MMIO reads next cycle;
  // cpu_top uses the explicit variable-latency response handshake.
  //
  // Use explicit one-cycle histories below; Verilator rejects $past outside
  // assertions.
  logic device_request_pending_q;
  logic router_flush_all_q;
  always @(posedge i_clk) begin
    device_request_pending_q <= !i_rst && lq_device_request_pending;
    router_flush_all_q <= !i_rst && lq_router_flush_all;
  end

  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en || slow_write_inflight))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: LQ read handoff overlapped router write_port_busy");
`else
        $error("cpu_ooo: LQ read handoff overlapped router write_port_busy");
`endif
      if (lq_mem_request_valid && lq_mem_read_en)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: LQ read handoff overlapped held router request");
`else
        $error("cpu_ooo: LQ read handoff overlapped held router request");
`endif
      // A full flush already on its way (trap, xRET, FENCE-class) may overlap
      // the held request's staging cycle; that is where the router cancels
      // it. Commit-time recovery is in the router's flush only to match the
      // LQ's full-flush condition. It never overlaps a held request, because
      // a commit-time recovery cannot overtake an older device read at the
      // ROB head.
      if (lq_mem_request_valid && commit_recovery_flush_after_head)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: commit recovery overlapped a held LQ router request");
`else
        $error("cpu_ooo: commit recovery overlapped a held LQ router request");
`endif
      if (lq_mem_request_valid && lq_router_flush_all &&
          (o_data_mem_read_enable || o_data_mem_cached_read_enable ||
           o_mmio_read_pulse || o_mmio_load_valid))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: owner flush did not suppress held LQ read effects");
`else
        $error("cpu_ooo: owner flush did not suppress held LQ read effects");
`endif
      // Once sq_committed_empty is high, no older SQ or cached store can
      // still hold the write port, and device reads launch only at the ROB
      // head, so no AMO can be writing either.
      if (lq_mem_request_valid && sq_committed_empty &&
          (sq_mem_write_en || amo_mem_write_en || slow_write_inflight))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: drained held LQ request remained write-blocked");
`else
        $error("cpu_ooo: drained held LQ request remained write-blocked");
`endif
      // Device-read interrupt shield (trap_unit.i_device_read_at_head or
      // vec_head_shield for head-executed vector device reads): a device read
      // must never happen before a shield is up.
      if (o_mmio_read_pulse && !device_read_shield_q && !vec_head_shield)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: MMIO read pulse fired without the device interrupt shield");
`else
        $error("cpu_ooo: MMIO read pulse fired without the device interrupt shield");
`endif
      // The hold must not lapse while the request is still parked. The first
      // pending cycle is exempt: that cycle is what raises the shield, and
      // the router cannot arm until the cycle after it is visible.
      if (lq_device_request_pending && device_request_pending_q && !device_read_shield_q &&
          !lq_router_flush_all && !router_flush_all_q)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: device request pending without the interrupt shield");
`else
        $error("cpu_ooo: device request pending without the interrupt shield");
`endif
      // An interrupt must never be taken inside the shielded window.
      // Exceptions stay ungated by both shields, so only an interrupt take is
      // a violation. The trap unit takes an exception from its own latch
      // (exception_pending), which can outlive the ROB's trap_pending: when a
      // partial flush coincides with the faulting head becoming ready, the
      // ROB raises trap_pending for that cycle but stays in SERIAL_IDLE, and
      // the commit hold the pulse raises clears it on the next edge, the edge
      // on which the trap unit takes the latched exception. Qualify with the
      // latch, as trap_unit's p_device_shield_blocks_interrupt does.
      if (device_read_shield_q && trap_taken && !trap_unit_inst.exception_pending)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: interrupt taken inside the device-read shield window");
`else
        $error("cpu_ooo: interrupt taken inside the device-read shield window");
`endif
    end
  end

  // While the device shield defers interrupts, trap_drain_wait must not block
  // commit. The load must commit and release the shield; detect a stuck shield.
  localparam int unsigned DeviceShieldWatchdogCycles = 4096;
  localparam int unsigned DeviceShieldDrainWatchdogCycles = 65536;
  int unsigned device_shield_stuck_cnt;
  int unsigned device_shield_drain_cnt;
  always @(posedge i_clk) begin
    // A parked Device read waits for older committed writes, including cache
    // initialization and external memory. Its service bound starts after drain.
    if (!reset_seen_q || i_rst || !device_read_shield_q) begin
      device_shield_stuck_cnt <= 0;
    end else if (!(lq_device_request_pending && !sq_committed_empty)) begin
      device_shield_stuck_cnt <= device_shield_stuck_cnt + 1;
      if (device_shield_stuck_cnt == DeviceShieldWatchdogCycles)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: device-read interrupt shield held for %0d cycles (forward progress lost)",
              DeviceShieldWatchdogCycles
          );
`else
        $error("cpu_ooo: device-read interrupt shield held for %0d cycles (forward progress lost)",
               DeviceShieldWatchdogCycles);
`endif
    end
  end
  always @(posedge i_clk) begin
    if (!reset_seen_q || i_rst || !device_read_shield_q) begin
      device_shield_drain_cnt <= 0;
    end else if (lq_device_request_pending && !sq_committed_empty) begin
      device_shield_drain_cnt <= device_shield_drain_cnt + 1;
      if (device_shield_drain_cnt == DeviceShieldDrainWatchdogCycles)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: device-read interrupt shield waited for older writes for %0d cycles",
              DeviceShieldDrainWatchdogCycles
          );
`else
        $error("cpu_ooo: device-read interrupt shield waited for older writes for %0d cycles",
               DeviceShieldDrainWatchdogCycles);
`endif
    end
  end
`endif
`endif

  // ===========================================================================
  // Early Misprediction Recovery
  // ===========================================================================
  // A mispredicted conditional branch or JALR that holds a checkpoint starts
  // recovery as soon as it resolves, unless another recovery or flush is in
  // progress, instead of at commit:
  //   Cycle N:   branch_update reports the misprediction; capture its data
  //   Cycle N+1: early_mispredict_active: redirect fetch, restore the RAT,
  //              hold dispatch and issue (early_backend_recovery_hold)
  //   Cycle N+2: early_backend_recovery_pending: back-end partial flush
  // A mispredicted JAL is known when it allocates (no BTB prediction, or a
  // stale BTB target): it is staged at allocation and launches the same
  // recovery from the next cycle (riscv_pkg::EarlyJalRecovery).
  //
  // JAL launch candidates per slot. A bundle holds at most one branch or jump,
  // so at most one slot carries a JAL. The capture superset needs no dispatch
  // fire; the launch adds the fire and the misprediction (the ROB's own
  // allocation-time rule, from ID's registered target-match bit).
  logic jal_capture_1, jal_capture_2;
  logic jal_launch;
  logic jal_launch_slot2;
  assign jal_capture_1 = rob_alloc_req_raw.is_jal;
  assign jal_capture_2 = rob_alloc_req_2_raw.is_jal;
  assign jal_launch_slot2 = !jal_capture_1;
  assign jal_launch =
      (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready && rob_alloc_req.is_jal &&
       !(rob_alloc_req.predicted_taken && from_id_to_ex.btb_correct_non_jalr)) ||
      (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready && rob_alloc_req_2.is_jal &&
       !(rob_alloc_req_2.predicted_taken && from_id_to_ex_2.btb_correct_non_jalr));
`ifndef SYNTHESIS
  // The launch rule equals the ROB's allocation-time JAL misprediction.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready && rob_alloc_req.is_jal)
        p_jal_launch_matches_rob_mispredict_1 :
        assert ((rob_alloc_req.predicted_taken && from_id_to_ex.btb_correct_non_jalr) ==
                (rob_alloc_req.predicted_taken &&
                 (rob_alloc_req.predicted_target == rob_alloc_req.branch_target)));
      if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready && rob_alloc_req_2.is_jal)
        p_jal_launch_matches_rob_mispredict_2 :
        assert ((rob_alloc_req_2.predicted_taken && from_id_to_ex_2.btb_correct_non_jalr) ==
                (rob_alloc_req_2.predicted_taken &&
                 (rob_alloc_req_2.predicted_target == rob_alloc_req_2.branch_target)));
      p_jal_launch_one_slot : assert (!(jal_capture_1 && jal_capture_2));
    end
  end
`endif

  // Same-cycle trap and xRET copies for early-recovery kill fanout.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      early_recovery_trap_taken_reg <= 1'b0;
      early_recovery_mret_taken_reg <= 1'b0;
    end else begin
      early_recovery_trap_taken_reg <= trap_taken;
      early_recovery_mret_taken_reg <= xret_taken;
    end
  end

  early_misprediction_recovery #(
      .XLEN(XLEN)
  ) early_misprediction_recovery_inst (
      .i_clk,
      .i_rst,
      .i_fatal_stop,
      .i_branch_update(branch_update),
      .i_rs_issue_int(rs_issue_int),
      .i_is_jalr_issue(is_jalr_issue),
      .i_branch_taken_resolved(branch_taken_resolved),
      .i_branch_target_resolved(branch_target_resolved),
      .i_fence_i_flush(fence_i_flush),
      // rob_commit.is_fence_i copies the native FENCE.I/SFENCE.VMA flush for
      // fanout. It implies fence_i_flush; translation-CSR recovery raises
      // fence_i_flush without this bit.
      .i_active_fence_i_flush(rob_commit.is_fence_i),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_flush_all(flush_all),
      .i_flush_for_trap(early_recovery_trap_taken_reg),
      .i_flush_for_mret(early_recovery_mret_taken_reg),
      .i_trap_taken_reg(early_recovery_trap_taken_reg),
      .i_mret_taken_reg(early_recovery_mret_taken_reg),
      .i_jal_launch(jal_launch),
      .i_checkpoint_unresolved(checkpoint_unresolved),
      .i_head_tag(head_tag),
      .i_jal_capture(jal_capture_1 || jal_capture_2),
      .i_jal_tag(jal_launch_slot2 ? rob_alloc_resp_2.alloc_tag : rob_alloc_resp.alloc_tag),
      .i_jal_checkpoint_id(rob_checkpoint_id),
      .i_jal_pc(jal_launch_slot2 ? rob_alloc_req_2_raw.pc : rob_alloc_req_raw.pc),
      .i_jal_target(jal_launch_slot2 ? rob_alloc_req_2_raw.branch_target :
                                       rob_alloc_req_raw.branch_target),
      .i_jal_is_compressed(jal_launch_slot2 ? rob_alloc_req_2_raw.is_compressed :
                                              rob_alloc_req_raw.is_compressed),
      .i_jal_is_call(jal_launch_slot2 ? rob_alloc_req_2_raw.is_call : rob_alloc_req_raw.is_call),
      .o_early_mispredict_active(early_mispredict_active),
      .o_early_mispredict_pending(early_mispredict_pending),
      .o_early_mispredict_fire(early_mispredict_fire),
      .o_early_backend_recovery_pending(early_backend_recovery_pending),
      .o_early_backend_recovery_pending_next(early_backend_recovery_pending_next),
      .o_early_backend_flush_tag(early_backend_flush_tag),
      .o_early_mispredict_tag(early_mispredict_tag),
      .o_early_mispredict_redirect_pc(early_mispredict_redirect_pc),
      .o_early_mispredict_checkpoint_id(early_mispredict_checkpoint_id),
      .o_early_mispredict_is_compressed(early_mispredict_is_compressed),
      .o_early_mispredict_pc(early_mispredict_pc),
      .o_early_mispredict_branch_target(early_mispredict_branch_target),
      .o_early_mispredict_branch_taken(early_mispredict_branch_taken),
      .o_early_mispredict_is_jalr(early_mispredict_is_jalr),
      .o_early_mispredict_is_call(early_mispredict_is_call),
      .o_early_mispredict_is_return(early_mispredict_is_return),
      .o_early_mispredict_is_jal(early_mispredict_is_jal),
      .o_early_recovery_en(early_recovery_en),
      .o_early_recovery_tag(early_recovery_tag),
      .o_early_backend_recovery_hold(early_backend_recovery_hold),
      .o_backend_recovery_hold(backend_recovery_hold)
  );

  // ===========================================================================
  // Commit-Time Actions
  // ===========================================================================

  commit_actions #(
      .XLEN(XLEN)
  ) commit_actions_inst (
      .i_clk,
      .i_rst,
      .i_rob_commit(rob_commit),
      .i_rob_commit_2(rob_commit_2),
      .i_rob_commit_valid(rob_commit_valid),
      .i_csr_read_data(csr_read_data),
      .i_retired_without_commit(retired_without_commit_q),
      .i_aux_wb_valid(ma_wb_valid_q),
      .i_aux_wb_fp(ma_wb_fp_q),
      .i_aux_wb_rd(ma_wb_rd_q),
      .i_aux_wb_data(ma_wb_data_q),
      .o_port0_int_we(port0_int_we),
      .o_port0_int_addr(port0_int_addr),
      .o_port0_int_data(port0_int_data),
      .o_port0_fp_we(port0_fp_we),
      .o_port0_fp_addr(port0_fp_addr),
      .o_port0_fp_data(port0_fp_data),
      .o_port1_int_we(port1_int_we),
      .o_port1_int_addr(port1_int_addr),
      .o_port1_int_data(port1_int_data),
      .o_port1_fp_we(port1_fp_we),
      .o_port1_fp_addr(port1_fp_addr),
      .o_port1_fp_data(port1_fp_data),
      .o_csr_commit_fire(csr_commit_fire),
      .o_csr_wb_pending(csr_wb_pending),
      .o_vld(o_vld),
      .o_pc_vld(o_pc_vld),
      .o_instruction_retired_count(instruction_retired_count)
  );

  // ===========================================================================
  // Register-File Bypass Qualifiers (declared with the register files above)
  // ===========================================================================
  // Capture bypass qualifiers with the ROB commit bus and delayed CSR result.
  // They equal architectural write enables, excluding x0, except during full
  // flush. A stale bypass hit during full flush is harmless: dispatch is killed.
  logic csr_wb_arm;
  assign csr_wb_arm = csr_commit_fire && rob_commit.dest_valid;

  // CSR storage consumes the registered commit bus. On that same edge the
  // trap unit still samples the old interrupt priorities. Keep its M/S take
  // quiet for the following cycle, so a write enabling a higher source cannot
  // enter under the old cause or vector. This adds no ordinary CSR stall.
  always_ff @(posedge i_clk) begin
    if (i_rst) csr_irq_update_q <= 1'b0;
    else csr_irq_update_q <= csr_commit_fire;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) begin
      bypass_p0_int_we_q <= 1'b0;
      bypass_p1_int_we_q <= 1'b0;
      bypass_p0_fp_we_q  <= 1'b0;
      bypass_p1_fp_we_q  <= 1'b0;
    end else begin
      // Use ROB predecodes for timing. They equal commit fields whenever raw
      // fire is high.
      bypass_p0_int_we_q <= (csr_wb_arm && |rob_commit.dest_reg) ||
          (rob_commit_valid_raw && rob_head_bypass_int_we_early) ||
          (ma_wb_arm && !ma_wb_fp_arm && |ma_wb_rd_arm);
      bypass_p0_fp_we_q <= (rob_commit_valid_raw && rob_head_bypass_fp_we_early) ||
          (ma_wb_arm && ma_wb_fp_arm);
      bypass_p1_int_we_q <= rob_commit_2_valid_raw && rob_head_next_bypass_int_we_early;
      bypass_p1_fp_we_q <= rob_commit_2_valid_raw && rob_head_next_bypass_fp_we_early;
    end
  end

  // Address payloads: no reset (don't-care while the matching we_q is low).
  // The CSR delayed writeback never overlaps a commit write (asserted in
  // commit_actions), so the csr arm can take priority on port 0.
  always_ff @(posedge i_clk) begin
    bypass_p0_addr_q <= csr_wb_arm ? rob_commit.dest_reg :
        ma_wb_arm ? ma_wb_rd_arm : rob_commit_comb.dest_reg;
    bypass_p1_addr_q <= rob_commit_comb_2.dest_reg;
  end

`ifndef SYNTHESIS
  // The bypass qualifiers must track the architectural write enables
  // cycle-for-cycle outside reset/full-flush cycles.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && !flush_all) begin
      assert (bypass_p0_int_we_q == (port0_int_we && |port0_int_addr))
      else $error("bypass_p0_int_we_q mismatch");
      assert (bypass_p0_fp_we_q == port0_fp_we)
      else $error("bypass_p0_fp_we_q mismatch");
      assert (bypass_p1_int_we_q == (port1_int_we && |port1_int_addr))
      else $error("bypass_p1_int_we_q mismatch");
      assert (bypass_p1_fp_we_q == port1_fp_we)
      else $error("bypass_p1_fp_we_q mismatch");
      if (bypass_p0_int_we_q) begin
        assert (bypass_p0_addr_q == port0_int_addr)
        else $error("bypass_p0_addr_q != port0_int_addr");
      end
      if (bypass_p0_fp_we_q) begin
        assert (bypass_p0_addr_q == port0_fp_addr)
        else $error("bypass_p0_addr_q != port0_fp_addr");
      end
      if (bypass_p1_int_we_q) begin
        assert (bypass_p1_addr_q == port1_int_addr)
        else $error("bypass_p1_addr_q != port1_int_addr");
      end
      if (bypass_p1_fp_we_q) begin
        assert (bypass_p1_addr_q == port1_fp_addr)
        else $error("bypass_p1_addr_q != port1_fp_addr");
      end
    end
  end
`endif

  // ===========================================================================
  // Commit-Bus Pipeline Register
  // ===========================================================================
  // Register ROB commit before CSR and regfile writes. Recovery uses narrow
  // raw ROB status so flush initiation does not wait for this register.
  assign rob_commit_valid = rob_commit.valid;

  logic [XLEN-1:0] trap_target_internal, trap_pc_internal;
  logic [XLEN-1:0] trap_value_internal;
  logic [XLEN-1:0] interrupt_resume_pc;
  logic [XLEN-1:0] trap_entry_target;
  logic            trap_or_xret_taken;
  // A legal WFI waits at the ROB head (see the seed arm below).
  logic            wfi_resume_seed;
  // The seed arm was the last to write interrupt_resume_pc, so a take now
  // saves wfi_pc+4: the WFI retires with it.
  logic            resume_pc_past_wfi_q;

`ifndef SYNTHESIS
  assign dbg_trap_taken_raw = trap_taken;
  assign dbg_trap_taken_q = trap_taken_reg;
  assign dbg_trap_cause_internal = trap_cause_internal;
  assign dbg_trap_pc_internal = trap_pc_internal;
  assign dbg_interrupt_resume_pc = interrupt_resume_pc;
  assign dbg_port0_int_we = port0_int_we;
  assign dbg_port0_int_addr = port0_int_addr;
  assign dbg_port0_int_data = port0_int_data;
  assign dbg_port1_int_we = port1_int_we;
  assign dbg_port1_int_addr = port1_int_addr;
  assign dbg_port1_int_data = port1_int_data;
  assign dbg_commit_dest_valid = rob_commit_comb.dest_valid;
  assign dbg_commit_dest_rf = rob_commit_comb.dest_rf;
  assign dbg_commit_dest_reg = rob_commit_comb.dest_reg;
  assign dbg_commit_value = rob_commit_comb.value[XLEN-1:0];
  assign dbg_commit_2_valid = rob_commit_comb_2.valid;
  assign dbg_commit_2_pc = rob_commit_comb_2.pc;
  assign dbg_commit_2_dest_valid = rob_commit_comb_2.dest_valid;
  assign dbg_commit_2_dest_rf = rob_commit_comb_2.dest_rf;
  assign dbg_commit_2_dest_reg = rob_commit_comb_2.dest_reg;
  assign dbg_commit_2_value = rob_commit_comb_2.value[XLEN-1:0];
  assign dbg_rob_commit_reg_valid = rob_commit.valid;
  assign dbg_rob_commit_reg_pc = rob_commit.pc;
  assign dbg_rob_commit_reg_dest_valid = rob_commit.dest_valid;
  assign dbg_rob_commit_reg_dest_rf = rob_commit.dest_rf;
  assign dbg_rob_commit_reg_dest_reg = rob_commit.dest_reg;
  assign dbg_rob_commit_reg_value = rob_commit.value[XLEN-1:0];
  assign dbg_rob_commit_2_reg_valid = rob_commit_2.valid;
  assign dbg_rob_commit_2_reg_pc = rob_commit_2.pc;
  assign dbg_rob_commit_2_reg_dest_valid = rob_commit_2.dest_valid;
  assign dbg_rob_commit_2_reg_dest_rf = rob_commit_2.dest_rf;
  assign dbg_rob_commit_2_reg_dest_reg = rob_commit_2.dest_reg;
  assign dbg_rob_commit_2_reg_value = rob_commit_2.value[XLEN-1:0];
`endif

  // ===========================================================================
  // Misprediction & Flush Controller
  // ===========================================================================
  // The controller ignores a commit-time misprediction only for the branch
  // that early recovery is handling, found by tag: rob_early_recovered is not
  // yet written when early_mispredict_pending first rises. A blanket
  // !early_mispredict_pending gate would also drop the recovery of a
  // different branch committing in the same cycle.
  //
  // More controller outputs (mispredict_commit_q and the flush and checkpoint
  // controls are declared near the top).
  logic correct_branch_commit_pending;
  riscv_pkg::correct_branch_commit_capture_t correct_branch_commit_q;

  misprediction_flush_controller #(
      .XLEN(XLEN)
  ) misprediction_flush_controller_inst (
      .i_clk,
      .i_rst,
      .i_rob_commit_misprediction_raw(rob_commit_misprediction_raw),
      .i_rob_commit_correct_branch_raw(rob_commit_correct_branch_raw),
      .i_rob_commit_comb(rob_commit_comb),
      .i_rob_commit_correct_branch_2_raw(rob_commit_correct_branch_2_raw),
      .i_rob_commit_comb_2(rob_commit_comb_2),
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_mispredict_pending(early_mispredict_pending),
      .i_early_mispredict_fire(early_mispredict_fire),
      .i_early_backend_recovery_pending(early_backend_recovery_pending),
      .i_early_backend_recovery_pending_next(early_backend_recovery_pending_next),
      .i_head_tag(head_tag),
      .i_early_mispredict_tag(early_mispredict_tag),
      .i_early_backend_flush_tag(early_backend_flush_tag),
      .i_early_mispredict_checkpoint_id(early_mispredict_checkpoint_id),
      .i_trap_taken_reg(trap_taken_reg),
      .i_mret_taken_reg(mret_taken_reg),
      .i_flush_for_trap(flush_for_trap),
      .i_flush_for_mret(flush_for_mret),
      .i_fence_i_flush(fence_i_flush),
      .i_active_fence_i_flush(rob_commit.is_fence_i),
      .i_trap_taken(trap_taken),
      .i_mret_taken(xret_taken),
      .i_fence_class_flush_event(fence_class_flush_event),
      .i_fence_i_target_pc(rob_head_retired_next_pc),
      .i_checkpoint_in_use(checkpoint_in_use),
      .i_checkpoint_younger_than_flush(checkpoint_younger_than_flush),
      .i_checkpoint_owner_tag(checkpoint_owner_tag),
      .o_mispredict_commit_q(mispredict_commit_q),
      .o_mispredict_recovery_pending(mispredict_recovery_pending),
      .o_fence_i_target_pc(fence_i_target_pc),
      .o_correct_branch_commit_pending(correct_branch_commit_pending),
      .o_correct_branch_commit_q(correct_branch_commit_q),
      .o_correct_branch_commit_pending_2_raw(correct_branch_commit_pending_2_raw),
      .o_correct_branch_commit_q_2(correct_branch_commit_q_2),
      .o_checkpoint_free_2(checkpoint_free_2),
      .o_checkpoint_free_id_2(checkpoint_free_id_2),
      .o_flush_pipeline(flush_pipeline),
      .o_dispatch_flush(dispatch_flush),
      .o_full_flush_side_effect_kill(full_flush_side_effect_kill),
      .o_frontend_state_flush(frontend_state_flush),
      .o_fetch_flush(fetch_flush),
      .o_flush_en(flush_en),
      .o_flush_tag(flush_tag),
      .o_flush_all(flush_all),
      .o_commit_recovery_flush_after_head(commit_recovery_flush_after_head),
      .o_flush_after_head(flush_after_head),
      .o_checkpoint_restore(checkpoint_restore),
      .o_checkpoint_restore_id(checkpoint_restore_id),
      .o_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
      .o_checkpoint_flush_free_mask(checkpoint_flush_free_mask),
      .o_checkpoint_free(checkpoint_free),
      .o_checkpoint_free_id(checkpoint_free_id)
  );

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      p_fetch_flush_matches_recovery :
      assert (fetch_flush == frontend_state_flush && fetch_flush == flush_pipeline);
      // A full flush discards every entry. A partial flush must carry the
      // tag of the redirect accepted on the preceding edge.
      if ($past(reset_seen_q && !i_rst && early_mispredict_active && !flush_all)) begin
        p_early_redirect_completes :
        assert (flush_all || (flush_en && flush_tag == $past(early_mispredict_tag)));
      end
    end
  end
`endif

  // ===========================================================================
  // Tagged Direction Predictor History and Training
  // ===========================================================================
  // PD hands ID a real packet when the PD-to-ID register loads without a
  // flush, PD redirect, or reset (the redirect's younger packet becomes a
  // bubble). Lookup metadata is captured on tage_pd_accept; PD's registered-
  // packet decode outputs (pd_q_*) qualify the FTQ write and direction push
  // on the following cycle.
  logic tage_pd_accept;
  logic [1:0] tage_slot_bank;
  logic [1:0] tage_base_taken;
  assign tage_pd_accept = !pipeline_ctrl.stall && !pipeline_ctrl.flush && !pd_redirect;
  assign tage_slot_bank[0] = from_if_to_pd.program_counter[2];
  assign tage_slot_bank[1] = from_if_to_pd_2.program_counter[2];
  assign tage_base_taken[0] = from_if_to_pd.btb_predicted_taken || from_if_to_pd.bp_dir_taken;
  assign tage_base_taken[1] = from_if_to_pd_2.btb_predicted_taken;

  // Dispatch's tags and branch types, and its allocations registered.
  always_ff @(posedge i_clk) begin
    if (i_rst) rob_alloc_q <= '0;
    else
      rob_alloc_q <= {
        rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready,
        rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready
      };
  end
  logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] tage_alloc_tag;
  logic [1:0] tage_alloc_cond_branch;
  assign tage_alloc_tag[0] = rob_alloc_resp.alloc_tag;
  assign tage_alloc_tag[1] = rob_alloc_resp_2.alloc_tag;
  assign tage_alloc_cond_branch[0] = rob_alloc_req.is_branch && !rob_alloc_req.is_jal &&
                                     !rob_alloc_req.is_jalr;
  assign tage_alloc_cond_branch[1] = rob_alloc_req_2.is_branch && !rob_alloc_req_2.is_jal &&
                                     !rob_alloc_req_2.is_jalr;
  logic [1:0] tage_alloc_jalr;
  assign tage_alloc_jalr[0] = rob_alloc_req.is_branch && rob_alloc_req.is_jalr;
  assign tage_alloc_jalr[1] = rob_alloc_req_2.is_branch && rob_alloc_req_2.is_jalr;
  logic [1:0] tage_alloc_jal;
  assign tage_alloc_jal[0] = rob_alloc_req.is_branch && rob_alloc_req.is_jal;
  assign tage_alloc_jal[1] = rob_alloc_req_2.is_branch && rob_alloc_req_2.is_jal;

  // The registered commit bus: retired conditional branches train, and every
  // retired taken control-flow instruction extends the retirement history.
  logic [1:0] tage_commit_valid;
  logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] tage_commit_tag;
  logic [1:0] tage_commit_cond_branch;
  logic [1:0] tage_commit_taken_cf;
  logic [1:0] tage_commit_taken;
  logic [1:0] tage_commit_mispredicted;
  logic [1:0][riscv_pkg::TagePathBits-1:0] tage_commit_target_bits;
  assign tage_commit_valid[0] = rob_commit.valid && !rob_commit.exception;
  assign tage_commit_valid[1] = rob_commit_2.valid && !rob_commit_2.exception;
  assign tage_commit_tag[0] = rob_commit.tag;
  assign tage_commit_tag[1] = rob_commit_2.tag;
  assign tage_commit_cond_branch[0] = rob_commit.is_branch && !rob_commit.is_jal &&
                                      !rob_commit.is_jalr;
  assign tage_commit_cond_branch[1] = rob_commit_2.is_branch && !rob_commit_2.is_jal &&
                                      !rob_commit_2.is_jalr;
  assign tage_commit_taken_cf[0] = rob_commit.is_branch && rob_commit.branch_taken;
  assign tage_commit_taken_cf[1] = rob_commit_2.is_branch && rob_commit_2.branch_taken;
  assign tage_commit_taken[0] = rob_commit.branch_taken;
  assign tage_commit_taken[1] = rob_commit_2.branch_taken;
  assign tage_commit_mispredicted[0] = rob_commit.misprediction;
  assign tage_commit_mispredicted[1] = rob_commit_2.misprediction;
  assign tage_commit_target_bits[0] = rob_commit.branch_target[3:2];
  assign tage_commit_target_bits[1] = rob_commit_2.branch_target[3:2];
  logic [1:0] tage_commit_jalr;
  logic [1:0] tage_commit_cf;
  assign tage_commit_cf[0] = rob_commit.is_branch;
  assign tage_commit_cf[1] = rob_commit_2.is_branch;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] tage_commit_target;
  assign tage_commit_jalr[0] = rob_commit.is_branch && rob_commit.is_jalr;
  assign tage_commit_jalr[1] = rob_commit_2.is_branch && rob_commit_2.is_jalr;
  logic [1:0] tage_commit_jal;
  assign tage_commit_jal[0] = rob_commit.is_branch && rob_commit.is_jal;
  assign tage_commit_jal[1] = rob_commit_2.is_branch && rob_commit_2.is_jal;
  assign tage_commit_target[0] = rob_commit.branch_target[riscv_pkg::PhysAddrBits-1:1];
  assign tage_commit_target[1] = rob_commit_2.branch_target[riscv_pkg::PhysAddrBits-1:1];

  tage_history u_tage_history (
      .i_clk,
      .i_rst,
      .i_hist_push(tage_hist_push),
      .i_hist_restore_arm(tage_hist_restore_arm),
      .i_fetch_pc_path_bits(tage_fetch_path_bits),
      .o_lookup_hist(tage_lookup_hist),
      .i_pd_accept(tage_pd_accept),
      .i_tage_slot_valid(tage_slot_valid),
      .i_tage_slot_lookup(tage_slot_lookup),
      .i_tage_slot_lookup_2(tage_slot_lookup_2),
      .i_tage_slot_bank(tage_slot_bank),
      .i_base_taken(tage_base_taken),
      .i_tage_lookup_hist(tage_packet_hist),
      .i_itt_slot_lookup(itt_slot_lookup),
      .i_itt_slot_lookup_2(itt_slot_lookup_2),
      .i_pd_q_cond_branch(pd_q_cond_branch),
      .i_pd_q_jalr(pd_q_jalr),
      .i_pd_q_itt_eligible(pd_q_itt_eligible),
      .i_pd_q_cf(pd_q_cf),
      .i_pd_q_pred_taken(pd_q_pred_taken),
      .o_lookup_dir_hist(tage_dir_hist),
      .o_lookup_dir_fold(tage_dir_fold),
      .i_pd_redirect_taken(pd_redirect_taken),
      .i_early_active(early_mispredict_active),
      .i_early_tag(early_mispredict_tag),
      .i_early_taken(early_mispredict_branch_taken),
      .i_early_dir_bit((early_mispredict_is_jalr || early_mispredict_is_jal) ?
                       early_mispredict_branch_target[2] : early_mispredict_branch_taken),
      .i_flush_full(flush_all || mispredict_recovery_pending),
      .i_alloc_q(rob_alloc_q),
      .i_alloc_tag(tage_alloc_tag),
      .i_alloc_cond_branch(tage_alloc_cond_branch),
      .i_alloc_jalr(tage_alloc_jalr),
      .i_alloc_jal(tage_alloc_jal),
      .i_commit_valid(tage_commit_valid),
      .i_commit_tag(tage_commit_tag),
      .i_commit_cond_branch(tage_commit_cond_branch),
      .i_commit_taken_cf(tage_commit_taken_cf),
      .i_commit_taken(tage_commit_taken),
      .i_commit_mispredicted(tage_commit_mispredicted),
      .i_commit_target_bits(tage_commit_target_bits),
      .i_commit_jalr(tage_commit_jalr),
      .i_commit_jal(tage_commit_jal),
      .i_commit_cf(tage_commit_cf),
      .i_commit_target(tage_commit_target),
      .o_train_valid(tage_train_valid),
      .o_train_lookup(tage_train_lookup),
      .o_train_bank(tage_train_bank),
      .o_train_alt_taken(tage_train_alt_taken),
      .o_train_taken(tage_train_taken),
      .o_train_mispredicted(tage_train_mispredicted),
      .o_itt_train_valid(itt_train_valid),
      .o_itt_train_lookup(itt_train_lookup),
      .o_itt_train_bank(itt_train_bank),
      .o_itt_train_target(itt_train_target),
      .o_itt_train_mispredicted(itt_train_mispredicted)
  );

`ifndef SYNTHESIS
  // Record the PC that supplied each FTQ entry. Check branch, JALR and JAL
  // ownership when early recovery restores history and when retirement trains
  // or frees the entry.
  // A JAL owns an entry only with EarlyJalRecovery (tage_history JAL_ENTRIES).
  logic [XLEN-1:0] tage_entry_pc[2**riscv_pkg::TageFtqIdxBits];
  always_ff @(posedge i_clk) begin
    if (u_tage_history.pd_entry_pending)
      tage_entry_pc[u_tage_history.ftq_write_ptr] <= !u_tage_history.pd_branch_slot ?
          from_pd_to_id.program_counter : from_pd_to_id_2.program_counter;
  end
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (early_mispredict_active)
        p_tage_entry_matches_early_branch :
        assert (tage_entry_pc[u_tage_history.early_ftq_idx] == early_mispredict_pc);
      if (tage_commit_valid[0] &&
          (tage_commit_cond_branch[0] || tage_commit_jalr[0] ||
           (riscv_pkg::EarlyJalRecovery && tage_commit_jal[0])))
        p_tage_entry_matches_branch_0 :
        assert (tage_entry_pc[u_tage_history.commit_ftq_idx[0]] == rob_commit.pc);
      if (tage_commit_valid[1] &&
          (tage_commit_cond_branch[1] || tage_commit_jalr[1] ||
           (riscv_pkg::EarlyJalRecovery && tage_commit_jal[1])))
        p_tage_entry_matches_branch_1 :
        assert (tage_entry_pc[u_tage_history.commit_ftq_idx[1]] == rob_commit_2.pc);
    end
  end
`endif


`ifndef SYNTHESIS
  // Commit-time recovery kills dispatch in one place, dispatch's i_flush: the
  // preflush candidates carry no recovery term, and id_valid/id_valid_2 exist
  // for debug and these checks. When recovery ends, its flush has already
  // cleared pd_valid_q (and emptied the decoded queue), so even the preflush
  // candidates are low.
  logic mispredict_recovery_pending_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reset_seen_q <= 1'b1;
      mispredict_recovery_pending_seen_q <= 1'b0;
    end else mispredict_recovery_pending_seen_q <= mispredict_recovery_pending;
  end

  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && !$isunknown(
            {
              mispredict_recovery_pending,
              mispredict_recovery_pending_seen_q,
              id_valid_preflush,
              id_valid_2_preflush,
              id_valid,
              id_valid_2,
              dispatch_flush,
              flush_en,
              commit_recovery_flush_after_head
            }
        )) begin
      if (mispredict_recovery_pending) begin
        p_commit_recovery_dispatch_gate_is_direct :
        assert (!id_valid && !id_valid_2 && dispatch_flush && flush_en &&
                commit_recovery_flush_after_head);
      end
      if (mispredict_recovery_pending_seen_q && !mispredict_recovery_pending) begin
        p_commit_recovery_release_cannot_dispatch :
        assert (!id_valid_preflush && !id_valid_2_preflush && !id_valid && !id_valid_2);
      end
    end
  end
`endif

  // ===========================================================================
  // Synthesize from_ex_comb for IF Stage
  // ===========================================================================
  // IF takes branch redirects, BTB updates, and RAS restores as a
  // from_ex_comb_t. They come from early recovery (highest priority),
  // commit-time misprediction, or a correctly predicted branch commit.

  ex_comb_synthesizer #(
      .XLEN(XLEN)
  ) ex_comb_synthesizer_inst (
      .i_early_mispredict_active(early_mispredict_active),
      .i_early_mispredict_redirect_pc(early_mispredict_redirect_pc),
      .i_early_mispredict_pc(early_mispredict_pc),
      .i_early_mispredict_branch_target(early_mispredict_branch_target),
      .i_early_mispredict_branch_taken(early_mispredict_branch_taken),
      .i_early_mispredict_is_compressed(early_mispredict_is_compressed),
      .i_early_mispredict_is_jalr(early_mispredict_is_jalr),
      .i_early_mispredict_is_call(early_mispredict_is_call),
      .i_early_mispredict_is_return(early_mispredict_is_return),
      .i_early_mispredict_is_jal(early_mispredict_is_jal),
      .i_restored_ras_tos(restored_ras_tos),
      .i_restored_ras_valid_count(restored_ras_valid_count),
      .i_restored_ras_top(restored_ras_top),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_mispredict_commit_q(mispredict_commit_q),
      .i_correct_branch_commit_pending(correct_branch_commit_pending),
      .i_correct_branch_commit_q(correct_branch_commit_q),
      .i_correct_branch_commit_pending_2_raw(correct_branch_commit_pending_2_raw),
      .i_correct_branch_commit_q_2(correct_branch_commit_q_2),
      .o_btb_late_update_pc(btb_late_update_pc),
      .o_btb_late_update_taken(btb_late_update_taken),
      .o_from_ex_comb(from_ex_branch_recovery)
  );

  if (riscv_pkg::EarlyJalrRecovery || riscv_pkg::EarlyJalRecovery) begin : gen_full_flush_ras
    ras_flush_checkpoint u_ras_flush_checkpoint (
        .i_clk,
        .i_allocate({
          rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready,
          rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready
        }),
        .i_alloc_tag({rob_alloc_resp_2.alloc_tag, rob_alloc_resp.alloc_tag}),
        .i_snapshot({
          from_id_to_ex_2.ras_checkpoint_tos,
          from_id_to_ex_2.ras_checkpoint_valid_count,
          from_id_to_ex_2.ras_checkpoint_top,
          from_id_to_ex.ras_checkpoint_tos,
          from_id_to_ex.ras_checkpoint_valid_count,
          from_id_to_ex.ras_checkpoint_top
        }),
        .i_restore_head(flush_all && head_valid),
        .i_head_tag(head_tag),
        .i_recovery(from_ex_branch_recovery),
        .o_recovery(from_ex_comb_synth)
    );
  end else begin : gen_commit_ras
    assign from_ex_comb_synth = from_ex_branch_recovery;
  end

  // ===========================================================================
  // Memory Interface
  // ===========================================================================
  // Route LQ/SQ memory requests to the external data memory port.
  // Priority: SQ writes > AMO writes > queued LQ reads
  // The L0 cache is inside the tomasulo_wrapper (lq_l0_cache).

  // The LQ's own full-flush condition (see lq_router_flush_all's declaration).
  assign lq_router_flush_all = flush_all || commit_recovery_flush_after_head;

`ifndef SYNTHESIS
  // tomasulo_wrapper feeds the LQ early_backend_recovery_pending as its
  // partial flush in place of flush_en. This checks what that relies on:
  // outside a full flush and a commit-time recovery (which the LQ treats as a
  // full flush), the only back-end partial flush is the early-recovery pulse.
  always_comb begin
    if (reset_seen_q && !i_rst && !$isunknown(
            {flush_all, commit_recovery_flush_after_head, flush_en, early_backend_recovery_pending}
        )) begin
      p_lq_partial_flush_identity_when_observable :
      assert (flush_all || commit_recovery_flush_after_head ||
              (early_backend_recovery_pending == flush_en));
    end
  end
`endif

  logic [XLEN-1:0] router_data_mem_addr;
  logic [riscv_pkg::MemDataBits-1:0] router_data_mem_wr_data;
  logic [riscv_pkg::MemStrbBits-1:0] router_data_mem_per_byte_wr_en;
  logic [riscv_pkg::MemStrbBits-1:0] router_data_mem_bram_byte_wr_en;
  logic router_data_mem_bram_write_any;
  logic router_data_mem_read_enable;
  logic router_cached_read_ready;
  logic router_uncached_read_enable;
  riscv_pkg::mem_size_e router_uncached_read_size;
  logic router_uncached_read_ready;
  logic [riscv_pkg::MemStrbBits-1:0] router_uncached_write_byte_en;
  riscv_pkg::mem_size_e router_uncached_write_size;
  logic router_uncached_write_buffered;
  logic router_mmio_read_pulse;
  logic [XLEN-1:0] router_mmio_load_addr;
  logic router_mmio_load_valid;
  logic router_mmio_fifo0_read_pulse;
  logic router_mmio_fifo1_read_pulse;
  logic router_mmio_uart_rx_ready_pulse;
  logic router_i_uncached_read_valid;
  logic router_i_uncached_write_done;

  data_mem_request_router #(
      .VARIABLE_UNCACHED(VARIABLE_UNCACHED),
      .XLEN(XLEN),
      .MMIO_ADDR(MMIO_ADDR),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) data_mem_request_router_inst (
      .i_coherent_read_kind(coherent_lq_kind),
      .i_coherent_read_tag(coherent_lq_tag),
      .i_coherent_sq_sc(coherent_sq_sc),
      .i_coherent_sq_zero(coherent_sq_zero),
      .i_coherent_sq_more(coherent_sq_more),
      .i_coherent_sq_next_same(coherent_sq_next_same),
      .i_coherent_sq_tag(coherent_sq_tag),
      .i_coherent_amo_tag(coherent_amo_tag),
      .o_coherent_read_kind(o_coherent_read_kind),
      .o_coherent_read_size(o_coherent_read_size),
      .o_coherent_read_tag(o_coherent_read_tag),
      .o_coherent_write_atomic(o_coherent_write_atomic),
      .o_coherent_write_sc(o_coherent_write_sc),
      .o_coherent_write_zero(o_coherent_write_zero),
      .o_coherent_write_more(o_coherent_write_more),
      .o_coherent_next_same(o_coherent_next_same),
      .o_coherent_write_tag(o_coherent_write_tag),
      .i_clk,
      .i_rst,
      .i_block_new_requests(i_fatal_stop),
      .i_flush_all(lq_router_flush_all || i_fatal_stop),
      .i_sq_mem_write_en(sq_mem_write_en),
      .i_sq_mem_write_addr(sq_mem_write_addr),
      .i_sq_mem_write_data(sq_mem_write_data),
      .i_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .i_sq_mem_write_buffered(sq_mem_write_buffered),
      .i_sq_mem_write_size(sq_mem_write_size),
      .i_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .i_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_amo_mem_write_en(amo_mem_write_en),
      .i_amo_mem_write_addr(amo_mem_write_addr),
      .i_amo_mem_write_data(amo_mem_write_data),
      .i_amo_mem_write_is_dword(amo_mem_write_is_dword),
      .i_amo_mem_write_is_cached(amo_mem_write_is_cached),
      .i_lq_mem_read_en(lq_mem_read_en),
      .i_lq_mem_read_addr(lq_mem_read_addr),
      .i_lq_mem_addr_valid(lq_mem_addr_valid),
      .i_lq_mem_read_id(lq_mem_read_launch_id),
      .i_lq_mem_read_no_merge(lq_mem_read_no_merge),
      .i_lq_mem_read_size(lq_mem_read_size),
      .i_sq_committed_empty(sq_committed_empty),
      .i_data_mem_rd_data(i_data_mem_rd_data),
      .i_cached_read_data(i_cached_read_data),
      .i_cached_read_id(i_cached_read_id),
      .i_cached_read_valid(i_cached_read_valid),
      .i_cached_read_error(i_cached_read_error),
      .o_cached_read_ready(router_cached_read_ready),
      .o_cached_read_held(cached_read_held),
      .i_cached_write_done(i_cached_write_done),
      .i_cached_write_inflight(cached_write_busy),
      .i_uncached_read_request_ready,
      .o_uncached_read_enable(router_uncached_read_enable),
      .o_uncached_read_size(router_uncached_read_size),
      .i_uncached_read_valid(router_i_uncached_read_valid),
      .o_uncached_read_ready(router_uncached_read_ready),
      .i_uncached_read_data,
      .i_uncached_read_status,
      .o_uncached_write_byte_en(router_uncached_write_byte_en),
      .o_uncached_write_size(router_uncached_write_size),
      .o_uncached_write_buffered(router_uncached_write_buffered),
      .i_uncached_write_done(router_i_uncached_write_done),
      .i_uncached_write_status,
      .i_uncached_write_inflight,
      .o_data_mem_addr(router_data_mem_addr),
      .o_data_mem_wr_data(router_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(router_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(router_data_mem_bram_byte_wr_en),
      .o_data_mem_bram_write_any(router_data_mem_bram_write_any),
      .o_data_mem_read_enable(router_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(o_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(o_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(o_data_mem_cached_read_enable),
      .o_data_mem_cached_read_sel(o_data_mem_cached_read_sel),
      .o_data_mem_cached_read_if_sel(o_data_mem_cached_read_if_sel),
      .o_data_mem_cached_read_if_clear(o_data_mem_cached_read_if_clear),
      .o_data_mem_cached_read_id(o_data_mem_cached_read_id),
      .o_data_mem_cached_read_no_merge(o_data_mem_cached_read_no_merge),
      .o_mmio_read_pulse(router_mmio_read_pulse),
      .o_mmio_load_addr(router_mmio_load_addr),
      .o_mmio_load_valid(router_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(router_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(router_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(router_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(sq_mem_write_done),
      .o_sq_mem_write_error(sq_mem_write_error),
      .o_amo_mem_write_done(amo_mem_write_done),
      .o_amo_mem_write_error(amo_mem_write_error),
      .o_lq_mem_request_valid(lq_mem_request_valid),
      .o_device_request_pending(lq_device_request_pending),
      .i_device_start_hold(device_start_hold),
      .o_lq_mem_read_data(lq_mem_read_data),
      .o_lq_mem_read_valid(lq_mem_read_valid),
      .o_lq_mem_read_error(lq_mem_read_error),
      .o_lq_mem_read_is_cached(lq_mem_read_is_cached),
      .o_lq_mem_read_id(lq_mem_read_id)
  );

  // Share the uncached data port with head-executed vector uncached elements
  // when VECTOR=1. Cached-tier requests (o_data_mem_cached_* and, in
  // VARIABLE_UNCACHED mode, o_data_mem_addr) stay connected directly to the
  // router. When VECTOR=0 every output is wired directly from the router.
  if (VECTOR) begin : gen_vec_uncached_bus
    localparam logic [XLEN-1:0] VecUartRxDataMmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h4);
    localparam logic [XLEN-1:0] VecFifo0MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h8);
    localparam logic [XLEN-1:0] VecFifo1MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'hC);

    logic [XLEN-1:0] vec_unc_addr_xlen;
    logic vec_unc_launch, vec_unc_read_launch, vec_unc_write_launch;
    logic vec_unc_is_dev, vec_unc_is_mem;
    logic vec_unc_read_active_q, vec_unc_write_active_q;
    logic vec_unc_fast_read_q, vec_unc_fast_write_done_q;
    logic vec_mmio_fifo0_pulse_q, vec_mmio_fifo1_pulse_q, vec_mmio_uart_rx_pulse_q;
    logic vec_l0_inval_valid_q;
    logic [XLEN-1:0] vec_l0_inval_addr_q;

    assign vec_unc_addr_xlen = XLEN'(vec_unc_req_addr);
    assign vec_unc_launch = vec_unc_req_valid && !i_fatal_stop;
    assign vec_unc_read_launch = vec_unc_launch && !vec_unc_req_write;
    assign vec_unc_write_launch = vec_unc_launch && vec_unc_req_write;
    assign vec_unc_is_dev = riscv_pkg::pma_device_quadrant(vec_unc_addr_xlen);
    assign vec_unc_is_mem = riscv_pkg::pma_memory_ok(vec_unc_addr_xlen);

    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        vec_unc_read_active_q     <= 1'b0;
        vec_unc_write_active_q    <= 1'b0;
        vec_unc_fast_read_q       <= 1'b0;
        vec_unc_fast_write_done_q <= 1'b0;
        vec_mmio_fifo0_pulse_q    <= 1'b0;
        vec_mmio_fifo1_pulse_q    <= 1'b0;
        vec_mmio_uart_rx_pulse_q  <= 1'b0;
        vec_l0_inval_valid_q      <= 1'b0;
      end else begin
        if (VARIABLE_UNCACHED) begin
          if (vec_unc_read_launch) vec_unc_read_active_q <= 1'b1;
          else if (vec_unc_read_active_q && i_uncached_read_valid) vec_unc_read_active_q <= 1'b0;

          if (vec_unc_write_launch) vec_unc_write_active_q <= 1'b1;
          else if (vec_unc_write_active_q && i_uncached_write_done) vec_unc_write_active_q <= 1'b0;
        end
        vec_unc_fast_read_q <= !VARIABLE_UNCACHED && vec_unc_read_launch;
        vec_unc_fast_write_done_q <= !VARIABLE_UNCACHED && vec_unc_write_launch;
        vec_mmio_fifo0_pulse_q    <= !VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev &&
                                     (vec_unc_addr_xlen == VecFifo0MmioAddr);
        vec_mmio_fifo1_pulse_q    <= !VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev &&
                                     (vec_unc_addr_xlen == VecFifo1MmioAddr);
        vec_mmio_uart_rx_pulse_q  <= !VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev &&
                                     (vec_unc_addr_xlen == VecUartRxDataMmioAddr);
        vec_l0_inval_valid_q <= vec_unc_write_launch && vec_unc_is_mem;
      end
      if (vec_unc_write_launch && vec_unc_is_mem) vec_l0_inval_addr_q <= vec_unc_addr_xlen;
    end

    assign vec_l0_inval_valid = vec_l0_inval_valid_q;
    assign vec_l0_inval_addr = vec_l0_inval_addr_q;

    assign vec_unc_bus_busy = vec_unc_launch || vec_unc_read_active_q || vec_unc_write_active_q ||
        vec_unc_fast_read_q || vec_unc_fast_write_done_q;
    assign vec_unc_port_ready = !i_fatal_stop &&
        !vec_unc_read_active_q && !vec_unc_write_active_q &&
        !vec_unc_fast_read_q && !vec_unc_fast_write_done_q &&
        !sq_mem_write_en && !amo_mem_write_en &&
        !lq_mem_read_en && !lq_mem_request_valid &&
        (VARIABLE_UNCACHED ?
            (i_uncached_read_request_ready && !i_uncached_write_inflight &&
             !i_uncached_read_valid && !i_uncached_write_done) :
            (router_cached_read_ready && !router_data_mem_read_enable));

    assign router_i_uncached_read_valid = i_uncached_read_valid && !vec_unc_read_active_q;
    assign router_i_uncached_write_done = i_uncached_write_done && !vec_unc_write_active_q;

    assign vec_unc_resp_valid = VARIABLE_UNCACHED ?
        ((vec_unc_read_active_q && i_uncached_read_valid) ||
         (vec_unc_write_active_q && i_uncached_write_done)) :
        (vec_unc_fast_read_q || vec_unc_fast_write_done_q);
    assign vec_unc_resp_data = VARIABLE_UNCACHED ? i_uncached_read_data : i_data_mem_rd_data;
    assign vec_unc_resp_error = VARIABLE_UNCACHED &&
        ((vec_unc_read_active_q && i_uncached_read_valid && (i_uncached_read_status != 2'b00)) ||
         (vec_unc_write_active_q && i_uncached_write_done && (i_uncached_write_status != 2'b00)));

    assign o_data_mem_addr = VARIABLE_UNCACHED ? router_data_mem_addr :
                             (vec_unc_launch ? vec_unc_addr_xlen : router_data_mem_addr);
    assign o_uncached_addr = vec_unc_launch ? vec_unc_addr_xlen : router_data_mem_addr;
    assign o_data_mem_wr_data = vec_unc_write_launch ? vec_unc_req_wdata : router_data_mem_wr_data;
    assign o_data_mem_per_byte_wr_en = (!VARIABLE_UNCACHED && vec_unc_write_launch) ?
        vec_unc_req_wstrb : router_data_mem_per_byte_wr_en;
    assign o_data_mem_bram_byte_wr_en = (!VARIABLE_UNCACHED && vec_unc_write_launch) ?
        (vec_unc_is_dev ? '0 : vec_unc_req_wstrb) : router_data_mem_bram_byte_wr_en;
    assign data_mem_bram_write_any = (!VARIABLE_UNCACHED && vec_unc_write_launch) ?
        (!vec_unc_is_dev && (|vec_unc_req_wstrb)) : router_data_mem_bram_write_any;
    assign o_data_mem_read_enable = router_data_mem_read_enable ||
        (!VARIABLE_UNCACHED && vec_unc_read_launch);
    assign o_cached_read_ready = router_cached_read_ready && !vec_unc_fast_read_q;
    assign o_uncached_read_enable = router_uncached_read_enable ||
        (VARIABLE_UNCACHED && vec_unc_read_launch);
    assign o_uncached_read_size = vec_unc_read_launch ?
        vec_unc_req_size : router_uncached_read_size;
    assign o_uncached_read_ready = router_uncached_read_ready ||
        (VARIABLE_UNCACHED && vec_unc_read_active_q);
    assign o_uncached_write_byte_en = (VARIABLE_UNCACHED && vec_unc_write_launch) ?
        vec_unc_req_wstrb : router_uncached_write_byte_en;
    assign o_uncached_write_size = vec_unc_write_launch ?
        vec_unc_req_size : router_uncached_write_size;
    assign o_uncached_write_buffered = vec_unc_write_launch ? 1'b0 : router_uncached_write_buffered;
    assign o_mmio_read_pulse = router_mmio_read_pulse ||
        (!VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev);
    assign o_mmio_load_addr = (!VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev) ?
        vec_unc_addr_xlen : router_mmio_load_addr;
    assign o_mmio_load_valid = router_mmio_load_valid ||
        (!VARIABLE_UNCACHED && vec_unc_read_launch && vec_unc_is_dev);
    assign o_mmio_fifo0_read_pulse = router_mmio_fifo0_read_pulse || vec_mmio_fifo0_pulse_q;
    assign o_mmio_fifo1_read_pulse = router_mmio_fifo1_read_pulse || vec_mmio_fifo1_pulse_q;
    assign o_mmio_uart_rx_ready_pulse = router_mmio_uart_rx_ready_pulse || vec_mmio_uart_rx_pulse_q;

`ifndef SYNTHESIS
    always @(posedge i_clk) begin
      if (reset_seen_q && !i_rst && vec_unc_launch) begin
        assert (vec_head_shield)
        else $error("cpu_ooo: vector uncached beat launched without vec_head_shield");
        assert (!sq_mem_write_en && !amo_mem_write_en && !lq_mem_read_en && !lq_mem_request_valid)
        else $error("cpu_ooo: vector uncached beat overlapped scalar memory request");
        assert (!(vec_unc_read_active_q || vec_unc_write_active_q))
        else $error("cpu_ooo: vector uncached beat overlapped active vector beat");
      end
    end
`endif
  end else begin : gen_no_vec_uncached_bus
    assign vec_unc_bus_busy = 1'b0;
    assign vec_unc_port_ready = 1'b0;
    assign vec_unc_resp_valid = 1'b0;
    assign vec_unc_resp_data = '0;
    assign vec_unc_resp_error = 1'b0;
    assign vec_l0_inval_valid = 1'b0;
    assign vec_l0_inval_addr = '0;
    assign router_i_uncached_read_valid = i_uncached_read_valid;
    assign router_i_uncached_write_done = i_uncached_write_done;
    assign o_data_mem_addr = router_data_mem_addr;
    assign o_uncached_addr = router_data_mem_addr;
    assign o_data_mem_wr_data = router_data_mem_wr_data;
    assign o_data_mem_per_byte_wr_en = router_data_mem_per_byte_wr_en;
    assign o_data_mem_bram_byte_wr_en = router_data_mem_bram_byte_wr_en;
    assign data_mem_bram_write_any = router_data_mem_bram_write_any;
    assign o_data_mem_read_enable = router_data_mem_read_enable;
    assign o_cached_read_ready = router_cached_read_ready;
    assign o_uncached_read_enable = router_uncached_read_enable;
    assign o_uncached_read_size = router_uncached_read_size;
    assign o_uncached_read_ready = router_uncached_read_ready;
    assign o_uncached_write_byte_en = router_uncached_write_byte_en;
    assign o_uncached_write_size = router_uncached_write_size;
    assign o_uncached_write_buffered = router_uncached_write_buffered;
    assign o_mmio_read_pulse = router_mmio_read_pulse;
    assign o_mmio_load_addr = router_mmio_load_addr;
    assign o_mmio_load_valid = router_mmio_load_valid;
    assign o_mmio_fifo0_read_pulse = router_mmio_fifo0_read_pulse;
    assign o_mmio_fifo1_read_pulse = router_mmio_fifo1_read_pulse;
    assign o_mmio_uart_rx_ready_pulse = router_mmio_uart_rx_ready_pulse;
  end

  // ===========================================================================
  // CSR File
  // ===========================================================================
  // CSR instructions execute at commit, one at a time: the ROB serializer
  // holds the CSR at the head and raises csr_start, csr_done_ack answers a
  // cycle later (below), and the ROB retires the CSR. csr_file then reads and
  // writes the CSR from the registered commit bus (csr_commit_fire).

  // CSR write data: for register ops (CSRRW/CSRRS/CSRRC), the ALU shim
  // stored rs1 in rob_commit.value. For immediate ops (CSRRWI/CSRRSI/CSRRCI),
  // the ALU shim stored zero_extend(csr_imm) in rob_commit.value.
  logic [XLEN-1:0] csr_write_data_from_commit;
  assign csr_write_data_from_commit = rob_commit.value[XLEN-1:0];
  logic rob_commit_fp_flags_nonzero;
  logic rob_commit_2_fp_flags_nonzero;
  logic rob_commit_fp_flags_valid;
  logic rob_commit_2_fp_flags_valid;
  logic rob_commit_any_fp_flags_valid;
  riscv_pkg::fp_flags_t rob_commit_fp_flags_merged;

  assign rob_commit_fp_flags_nonzero = rob_commit.fp_flags.nv | rob_commit.fp_flags.dz |
                                       rob_commit.fp_flags.of | rob_commit.fp_flags.uf |
                                       rob_commit.fp_flags.nx;
  assign rob_commit_2_fp_flags_nonzero = rob_commit_2.fp_flags.nv | rob_commit_2.fp_flags.dz |
                                         rob_commit_2.fp_flags.of | rob_commit_2.fp_flags.uf |
                                         rob_commit_2.fp_flags.nx;
  // Only OP-FP and FMA entries accumulate flags. Allocation clears all flags;
  // only FP CDB completions supply nonzero flags.
  assign rob_commit_fp_flags_valid = rob_commit_valid && rob_commit_fp_flags_nonzero &&
                                     !rob_commit.exception && rob_commit.has_fp_flags;
  assign rob_commit_2_fp_flags_valid = rob_commit_2_valid && rob_commit_2_fp_flags_nonzero &&
                                       !rob_commit_2.exception && rob_commit_2.has_fp_flags;
  assign rob_commit_any_fp_flags_valid = rob_commit_fp_flags_valid || rob_commit_2_fp_flags_valid;

  // Either FP register write marks FS Dirty. Integer-destination FP operations
  // modify FP state only through nonzero flags; zero-flag reads leave it clean.
  logic rob_commit_any_fp_dest_write;
  assign rob_commit_any_fp_dest_write =
      (rob_commit_valid && rob_commit.dest_valid && rob_commit.dest_rf &&
       !rob_commit.exception) ||
      (rob_commit_2_valid && rob_commit_2.dest_valid && rob_commit_2.dest_rf &&
       !rob_commit_2.exception);

  always_comb begin
    rob_commit_fp_flags_merged.nv = (rob_commit_fp_flags_valid && rob_commit.fp_flags.nv) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.nv);
    rob_commit_fp_flags_merged.dz = (rob_commit_fp_flags_valid && rob_commit.fp_flags.dz) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.dz);
    rob_commit_fp_flags_merged.of = (rob_commit_fp_flags_valid && rob_commit.fp_flags.of) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.of);
    rob_commit_fp_flags_merged.uf = (rob_commit_fp_flags_valid && rob_commit.fp_flags.uf) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.uf);
    rob_commit_fp_flags_merged.nx = (rob_commit_fp_flags_valid && rob_commit.fp_flags.nx) ||
                                    (rob_commit_2_fp_flags_valid && rob_commit_2.fp_flags.nx);
  end

  // xtval for synchronous exceptions, per the RISC-V privileged spec:
  //   - Breakpoint (EBREAK): the breakpoint instruction's virtual address
  //     (the faulting PC, which equals xepc).
  //   - Instruction access/page faults and data misaligned/access/page
  //     faults: the faulting virtual address, parked in the head entry's CDB
  //     value slot (unused for an exception) and exposed as rob_trap_value.
  //     The per-cause comments below say who parks it. A data access fault
  //     from a bus response takes the address from the wrapper instead
  //     (rob_head_bus_fault).
  //   - Illegal instruction (Sstvala), from any source: decode, PD's RVC
  //     check, ID's FS/CBO/Svinval/Zawrs gates, and the privilege, CSR and
  //     rounding-mode faults the ROB raises at allocation: the faulting
  //     instruction's bits, a compressed instruction's 16 bits zero-extended,
  //     stored with the ROB entry at allocation (rob_trap_insn).
  //   - Everything else FROST raises here: 0, which the privileged spec
  //     permits. That is ECALL and the ExcMemReplay pseudo-cause, which
  //     writes no CSR.
  // The INT ALU shim parks an instruction fault's address (the PC, or PC + 2
  // for a page-straddling instruction whose second halfword faulted); the LQ
  // bypass or the store fault strobe parks a misaligned or data page fault's
  // address. Under Ssnpm pointer masking a data fault reports the
  // transformed address (riscv_pkg "Pointer masking"); the mode and
  // translation state are those the access used: both change only at
  // serializing points, and none lies between an access and its trap.
  // riscv_pkg::exception_tval selects the value for each cause.
  logic [XLEN-1:0] csr_trap_value;
  assign csr_trap_value = riscv_pkg::exception_tval(
      rob_trap_cause,
      rob_trap_pc,
      rob_trap_value,
      rob_head_bus_fault,
      rob_head_bus_fault_va,
      rob_trap_insn,
      csr_mmu_pm_mode,
      csr_translation_active
  );
  // The trap unit registers the value before the pointer-masking transform,
  // with the mode the transform uses, and applies the transform after its
  // register; the result is csr_trap_value. A misaligned-engine fault's value
  // is final.
  logic [XLEN-1:0] trap_exception_tval;
  riscv_pkg::pm_mode_t trap_exception_tval_pm_mode;
  assign trap_exception_tval = ma_fault_pending_q ? ma_fault_tval_q : riscv_pkg::exception_tval(
      rob_trap_cause,
      rob_trap_pc,
      rob_trap_value,
      rob_head_bus_fault,
      rob_head_bus_fault_va,
      rob_trap_insn,
      riscv_pkg::EnvcfgPmmOff,
      csr_translation_active
  );
  assign trap_exception_tval_pm_mode = ma_fault_pending_q ? riscv_pkg::EnvcfgPmmOff :
      riscv_pkg::exception_tval_pm_mode(
      rob_trap_cause, csr_mmu_pm_mode
  );

  // Remap the shim's ExcEcallMmode at commit: U=8, S=9, M=11. trap_unit
  // arbitrates this cause with interrupts before csr_file writes xcause.
  // The tval mux uses the original cause; every ECALL has tval=0.
  //
  // Code 11 cannot be an external interrupt here: rob_trap_cause contains only
  // synchronous exceptions or ExcMemReplay. ROB interrupt_pending only wakes WFI.
  assign rob_trap_cause_remapped =
      ((rob_trap_cause == riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0]) &&
       (csr_priv == riscv_pkg::PrivU)) ?
          riscv_pkg::ExcEcallUmode[riscv_pkg::ExcCauseWidth-1:0] :
      ((rob_trap_cause == riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0]) &&
       (csr_priv == riscv_pkg::PrivS)) ?
          riscv_pkg::ExcEcallSmode[riscv_pkg::ExcCauseWidth-1:0] : rob_trap_cause;

  // The hart owns both IMSIC files beside its CSR storage. The ingress
  // register expands the identity before pending/priority logic uses it.
  riscv_pkg::interrupt_t file_interrupts;
  logic file_seip;
  logic [1:0] msi_valid_q;
  logic [10:0] msi_id_q;
  logic [63:0] msi_onehot_q[2];
  logic [7:0] imsic_select[2];
  logic [3:0] imsic_select_onehot[2];
  logic [63:0] imsic_ireg[2];
  logic [31:0] imsic_topei[2];
  logic [1:0] imsic_we, imsic_claim, imsic_eip;
  logic [63:0] imsic_keep, imsic_set;
  always_ff @(posedge i_clk) begin
    msi_id_q <= i_msi_id;
    for (int level = 0; level < 2; level++) begin
      msi_valid_q[level] <= !i_rst && i_msi_valid && (i_msi_level == 1'(level));
      for (int id = 0; id < 64; id++)
      msi_onehot_q[level][id] <= !i_rst && (id != 0) && i_msi_valid &&
            (i_msi_level == 1'(level)) && (i_msi_id == 11'(id));
    end
  end
  for (genvar level = 0; level < 2; level++) begin : gen_imsic
    imsic_file #(
        .NUM_IDS(63),
        .APLIC_DELIVERY(1'b1),
        .PREDECODED_SELECT(1'b1),
        .PREDECODED_MSI(1'b1)
    ) interrupt_file (
        .i_clk,
        .i_rst,
        .i_msi_valid(msi_valid_q[level]),
        .i_msi_id(msi_id_q),
        .i_msi_onehot(msi_onehot_q[level]),
        .i_iselect(imsic_select[level]),
        .i_select_onehot(imsic_select_onehot[level]),
        .o_ireg(imsic_ireg[level]),
        .o_ireg_illegal(),
        .i_ireg_we(imsic_we[level]),
        .i_ireg_keep(imsic_keep),
        .i_ireg_set(imsic_set),
        .o_topei(imsic_topei[level]),
        .i_topei_claim(imsic_claim[level]),
        .i_aplic_eip(level == 0 ? i_interrupts.meip : i_seip_line),
        .o_eip(imsic_eip[level])
    );
  end
  assign file_interrupts = {imsic_eip[0], i_interrupts.mtip, i_interrupts.msip};
  assign file_seip = imsic_eip[1];

`ifndef SYNTHESIS
  // The files report *topei from their registers a cycle late, so a claim or
  // *ireg write must not be followed by a file access in the next cycle. Only
  // CSR commits access the files, one strobe at a time, and the commit hold
  // keeps CSR commits apart.
  logic imsic_access_checks_armed = 1'b0;
  logic csr_commit_fire_q;
  always_ff @(posedge i_clk) begin
    imsic_access_checks_armed <= !i_rst;
    csr_commit_fire_q <= csr_commit_fire;
    if (reset_seen_q && !i_rst) begin
      p_imsic_access_is_csr_commit : assert (!(|{imsic_we, imsic_claim}) || csr_commit_fire);
      p_imsic_one_strobe : assert ($onehot0({imsic_we, imsic_claim}));
      if (imsic_access_checks_armed) begin
        p_csr_commits_apart : assert (!(csr_commit_fire && csr_commit_fire_q));
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifndef FORMAL
  // Store allocation and memory issue must use the current pointer mode.
  // RS stage 2 can present a packet during full flush; its consumers discard it.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && !flush_all &&
        ((rs_issue_mem.valid && (rs_issue_mem.mem_needs_lq || rs_issue_mem.mem_needs_sq)) ||
         u_tomasulo.sq_alloc_req.valid || u_tomasulo.sq_alloc_req_2.valid)) begin
      p_memory_pointer_mode_current :
      assert (csr_mmu_pm_mode ==
          (((csr_file_inst.mstatus_mprv ? csr_file_inst.mstatus_mpp : csr_priv) ==
             riscv_pkg::PrivU && !csr_file_inst.mstatus_mxr) ?
            csr_file_inst.senvcfg_pmm : riscv_pkg::EnvcfgPmmOff));
    end
    // The trap unit's untransformed value and mode give the transformed one.
    if (reset_seen_q && !i_rst && !$isunknown(
            {trap_exception_tval, trap_exception_tval_pm_mode, csr_translation_active}
        )) begin
      p_trap_tval_transform_after_register :
      assert (riscv_pkg::pm_tval(
          trap_exception_tval, trap_exception_tval_pm_mode, csr_translation_active
      ) == (ma_fault_pending_q ? ma_fault_tval_q : csr_trap_value));
    end
  end
`endif
`endif

  logic [1:0] commit_branch_retired_count;
  logic [1:0] commit_branch_mispredict_count;
  always_comb begin
    commit_branch_retired_count = 2'd0;
    commit_branch_mispredict_count = 2'd0;
    if (rob_commit_valid && !rob_commit.exception) begin
      if (rob_commit.is_branch) commit_branch_retired_count = commit_branch_retired_count + 2'd1;
      if (rob_commit.misprediction)
        commit_branch_mispredict_count = commit_branch_mispredict_count + 2'd1;
      if (rob_commit_2.valid && rob_commit_2.is_branch)
        commit_branch_retired_count = commit_branch_retired_count + 2'd1;
      if (rob_commit_2.valid && rob_commit_2.misprediction)
        commit_branch_mispredict_count = commit_branch_mispredict_count + 2'd1;
    end
  end

  // Cache refill events for the HPM counters, registered here so that the
  // route from the L1I and the home to the counters ends at a flop. csr_file
  // inhibits counting until a selector write, so the flops need no reset.
  logic hpm_l1i_refill_q, hpm_l2_demand_miss_q, hpm_l2_prefetch_miss_q;
  always_ff @(posedge i_clk) begin
    hpm_l1i_refill_q <= i_cache_perf_events.hierarchy.l1i.fill;
    hpm_l2_demand_miss_q <= i_cache_perf_events.hierarchy.l2.fill;
    hpm_l2_prefetch_miss_q <= i_cache_perf_events.hierarchy.l2.fill_prefetch;
  end

  csr_file #(
      .XLEN(XLEN),
      .COMMIT_EXCLUDES_CONTROL_TAKE(1'b1),
      .CBO_INVAL_AS_FLUSH(CBO_INVAL_AS_FLUSH),
      .UsePerfCsrHalf(1'b1),
      .PERF_COUNTERS(PERF_COUNTERS),
      .VECTOR(VECTOR),
      .VLEN(VLEN),
      .VECTOR_ADVERTISE(VECTOR_ADVERTISE)
  ) csr_file_inst (
      .i_clk,
      .i_rst,
      .i_csr_read_enable(csr_commit_fire),
      .i_csr_address(rob_commit.csr_addr),
      .i_csr_op(rob_commit.csr_op),
      .i_csr_write_data(csr_write_data_from_commit),
      .i_csr_write_enable(csr_commit_fire),
      .o_csr_read_data(csr_read_data),
      .o_csr_read_data_comb(),
      .i_instruction_retired_count(instruction_retired_count),
      .i_branch_retired_count(commit_branch_retired_count),
      .i_branch_mispredict_count(commit_branch_mispredict_count),
      .i_itlb_miss(iwalk_req_valid && iwalk_req_ready),
      .i_dtlb_miss(walk_req_valid && walk_req_ready),
      .i_walk_busy(ptw_busy),
      .i_sfence_tlb_flush(sfence_tlb_flush_start),
      .i_l1i_refill(hpm_l1i_refill_q),
      .i_l2_demand_miss(hpm_l2_demand_miss_q),
      .i_l2_prefetch_miss(hpm_l2_prefetch_miss_q),
      .i_l1d_miss(i_cache_perf_events.hierarchy.l1d.miss),
      .i_sq_full_stall(dispatch_status.sq_full ||
          (dispatch_status.slot2_block_lsq_full2 && from_id_to_ex_2.needs_sq &&
           (from_id_to_ex.needs_sq ? sq_full_for_2 : sq_full))),
      .i_interrupts(file_interrupts),
      .i_mtime(i_mtime),
      .i_seip_line(file_seip),
      // Takes with no CSR side effect (Debug Mode go and re-park redirects,
      // memory-order replays) do not reach csr_file.
      .i_trap_taken(trap_taken && !trap_no_csr),
      .i_trap_to_s(trap_to_s),
      .i_trap_to_d(trap_to_d),
      .i_trap_save_m(trap_save_m),
      .i_trap_save_s(trap_save_s),
      .i_trap_enter_d(trap_enter_d),
      .i_trap_dbg_cause(trap_dbg_cause),
      .i_dret_taken(dret_taken),
      .i_dbg_data(i_dbg_data),
      .o_dbg_data_we(o_dbg_data_we),
      .o_dbg_data_wdata(o_dbg_data_wdata),
      .i_trap_pc(trap_pc_internal),
      // xcause from trap_unit's arbitrated cause: interrupt cause (with the
      // interrupt bit) for interrupts, or the remapped exception cause (which
      // carries the ECALL priv remap via trap_unit.i_exception_cause below).
      .i_trap_cause(trap_cause_internal),
      // xtval from the trap unit's registered capture (zero for interrupts).
      .i_trap_value(trap_value_internal),
      .i_mret_taken(mret_taken),
      .i_sret_taken(sret_taken),
      .o_mstatus(csr_mstatus),
      .o_mie(csr_mie),
      .o_mtvec(csr_mtvec),
      .o_mtvec_traps_misaligned(csr_mtvec_traps_misaligned),
      .o_mepc(csr_mepc),
      .o_stvec(csr_stvec),
      .o_sepc(csr_sepc),
      .o_mstatus_mie_direct(csr_mstatus_mie_direct),
      .o_sstatus_sie_direct(csr_sstatus_sie_direct),
      .o_medeleg(csr_medeleg),
      .o_mideleg_s(csr_mideleg_s),
      .o_s_pending(csr_s_pending),
      .o_lcof_pending(csr_lcof_pending),
      .o_mideleg_lcof(csr_mideleg_lcof),
      .o_priv(csr_priv),
      .o_mcounteren(csr_mcounteren),
      .o_scounteren(csr_scounteren),
      .o_counter_blocked(csr_counter_blocked),
      .o_stimecmp_blocked(csr_stimecmp_blocked),
      .o_mireg_illegal(csr_mireg_illegal),
      .o_sireg_illegal(csr_sireg_illegal),
      .o_stopei_illegal(csr_stopei_illegal),
      .o_m_iselect(imsic_select[0]),
      .o_s_iselect(imsic_select[1]),
      .o_m_select_onehot(imsic_select_onehot[0]),
      .o_s_select_onehot(imsic_select_onehot[1]),
      .i_m_ireg(imsic_ireg[0]),
      .i_s_ireg(imsic_ireg[1]),
      .i_m_topei(imsic_topei[0]),
      .i_s_topei(imsic_topei[1]),
      .o_m_ireg_we(imsic_we[0]),
      .o_s_ireg_we(imsic_we[1]),
      .o_m_topei_claim(imsic_claim[0]),
      .o_s_topei_claim(imsic_claim[1]),
      .o_ireg_keep(imsic_keep),
      .o_ireg_set(imsic_set),
      .o_sret_illegal(csr_sret_illegal),
      .o_sfence_illegal(csr_sfence_illegal),
      .o_wfi_illegal(csr_wfi_illegal),
      .o_priv_is_u(csr_priv_is_u),
      .o_csr_translation_flush_req(csr_translation_flush_req),
      .o_csr_tlb_flush_all_req(csr_tlb_flush_all_req),
      .o_mmu_asid(csr_mmu_asid),
      .o_fetch_asid(csr_fetch_asid),
      .o_translation_active(csr_translation_active),
      .o_mmu_sum(csr_mmu_sum),
      .o_mmu_mxr(csr_mmu_mxr),
      .o_mmu_eff_priv_u(csr_mmu_eff_priv_u),
      .o_mmu_pm_mode(csr_mmu_pm_mode),
      .o_fetch_translation_active(csr_fetch_translation_active),
      .o_fetch_priv_u(csr_fetch_priv_u),
      .o_satp_root_ppn(csr_satp_root_ppn),
      .o_menvcfg_pbmte(csr_menvcfg_pbmte),
      .o_mstatus_fs_off(csr_mstatus_fs_off),
      .o_mstatus_vs_off(csr_mstatus_vs_off),
      .i_vcfg_commit(vcfg_commit),
      .i_varith_commit(vec_varith_commit),
      .i_vtox_commit(vec_vtox_commit),
      .i_vec_vxsat_set(vec_vxsat_set),
      .i_vec_fp_flags_valid(vec_fp_flags_valid),
      .i_vec_fp_flags(vec_fp_flags),
      .o_vec_vxrm(csr_vec_vxrm),
      .i_vstore_commit(vec_vstore_commit),
      .i_vmem_fault_vstart_valid(vec_vmem_fault_vstart_valid),
      .i_vmem_fault_vstart(vec_vmem_fault_vstart),
      .i_vmem_vs_dirty(vec_vmem_vs_dirty),
      .i_vl_trim_valid(vec_vl_trim_valid),
      .i_vl_trim(vec_vl_trim),
      .o_vec_vl(csr_vec_vl),
      .o_vec_vtype(csr_vec_vtype),
      .o_vec_vstart(csr_vec_vstart),
      .o_cbo_zero_illegal(csr_cbo_zero_illegal),
      .o_wrs_nto_illegal(csr_wrs_nto_illegal),
      .o_cbo_cf_illegal(csr_cbo_cf_illegal),
      .o_cbo_inval_illegal(csr_cbo_inval_illegal),
      .o_cbo_inval_flush(csr_cbo_inval_flush),
      .o_debug_mode(csr_debug_mode),
      .o_dcsr_step(csr_dcsr_step),
      .o_dcsr_ebreak(csr_dcsr_ebreak),
      .o_dpc(csr_dpc),
      // FP flags: accumulated from ROB commit
      .i_fp_flags(rob_commit_fp_flags_merged),
      .i_fp_flags_valid(rob_commit_any_fp_flags_valid),
      .i_fp_flags_wb_valid(rob_commit_any_fp_flags_valid),
      .i_fp_dest_write(rob_commit_any_fp_dest_write || (ma_wb_valid_q && ma_wb_fp_q)),
      .i_fp_flags_ma('0),
      .i_fp_flags_ma_valid(1'b0),
      .o_frm(frm_csr),
      .o_perf_counter_select(perf_counter_select),
      .o_perf_snapshot_capture(perf_snapshot_capture),
      .o_perf_cache_previous_select(perf_cache_previous_select),
      .i_perf_counter_data(perf_counter_data_q),
      .i_perf_counter_csr_half(perf_counter_csr_half_q),
      .i_perf_counter_count(perf_counter_count)
  );

`ifndef SYNTHESIS
  // ID sees FS-Off one cycle late. Writes to mstatus/sstatus that enter or
  // leave Off are translation CSRs, whose full flush discards decode under
  // the old value. Hardware Dirty-setting never changes FS from Off.
  logic fs_off_checks_armed = 1'b0;
  always_ff @(posedge i_clk) begin
    fs_off_checks_armed <= !i_rst;
    if (reset_seen_q && fs_off_checks_armed && !i_rst &&
        (csr_mstatus_fs_off != id_mstatus_fs_off_q)) begin
      p_fs_off_change_flushes_decode : assert (flush_all);
    end
    if (reset_seen_q && fs_off_checks_armed && !i_rst &&
        (csr_mstatus_vs_off != id_mstatus_vs_off_q)) begin
      p_vs_off_change_flushes_decode : assert (flush_all);
    end
    if (reset_seen_q && fs_off_checks_armed && !i_rst &&
        (csr_cbo_zero_illegal != id_cbo_zero_illegal_q)) begin
      p_cbo_zero_gate_change_flushes_decode : assert (flush_all);
    end
    if (reset_seen_q && fs_off_checks_armed && !i_rst &&
        ({csr_cbo_cf_illegal, csr_cbo_inval_illegal, csr_cbo_inval_flush} !=
         {id_cbo_cf_illegal_q, id_cbo_inval_illegal_q, id_cbo_inval_flush_q})) begin
      p_cbo_mgmt_gates_change_flushes_decode : assert (flush_all);
    end
    if (reset_seen_q && fs_off_checks_armed && !i_rst &&
        (csr_wrs_nto_illegal != id_wrs_nto_illegal_q)) begin
      p_wrs_nto_gate_change_flushes_decode : assert (flush_all);
    end
    if (reset_seen_q && fs_off_checks_armed && !i_rst && (csr_priv_is_u != id_priv_is_u_q)) begin
      p_priv_is_u_gate_change_flushes_decode : assert (flush_all);
    end
  end
`endif

  // ===========================================================================
  // Page-Table Walker
  // ===========================================================================
  // Data MMU requests take priority over instruction MMU requests. The VPN
  // select comes from registered state (walk_hold: the data MMU's S1 holds an
  // op without an accepted walk), so the ROB-dependent data request valid
  // stays off the L2 TLB read address; see walk_request_select. The select
  // records the requesting side (core_walk_owner_i) so only it receives the
  // response; VPN alone cannot distinguish requesters. TLB invalidate also
  // discards the walk and clears the routing bits. The line port goes to
  // cache wup.
  logic ptw_req_valid, ptw_req_ready, ptw_resp_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] ptw_req_vpn;
  // The misaligned-access engine and vector head translator are the third
  // and fourth requesters. When no data op waits in S1 (walk_hold), the
  // misaligned engine has priority, followed by the vector head translator,
  // then the core's data/fetch selection. Both engines run at the ROB head
  // with the data MMU empty. Request-owner bits route each accepted walk's
  // response, including walks whose instruction was flushed.
  logic core_ptw_req_valid, core_ptw_req_ready;
  logic [riscv_pkg::Sv39VpnBits-1:0] core_ptw_req_vpn;
  logic core_walk_owner_i;
  walk_request_select u_walk_select (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_invalidate(tlb_invalidate),
      .i_d_hold(walk_hold),
      .i_d_valid(walk_req_valid),
      .o_d_ready(walk_req_ready),
      .i_d_vpn(walk_vpn),
      .i_i_valid(iwalk_req_valid),
      .o_i_ready(iwalk_req_ready),
      .i_i_vpn(iwalk_vpn),
      .o_valid(core_ptw_req_valid),
      .i_ready(core_ptw_req_ready),
      .o_vpn(core_ptw_req_vpn),
      .o_owner_i(core_walk_owner_i)
  );

  logic ma_walk_select, vec_walk_select;
  assign ma_walk_select = MISALIGNED_HW && ma_walk_req_valid && !walk_hold;
  assign vec_walk_select = VECTOR && vec_walk_req_valid && !walk_hold && !ma_walk_select;
  assign ptw_req_valid = ma_walk_select || vec_walk_select || core_ptw_req_valid;
  assign ptw_req_vpn = ma_walk_select ? ma_walk_vpn :
      vec_walk_select ? vec_walk_vpn : core_ptw_req_vpn;
  assign core_ptw_req_ready = ptw_req_ready && !ma_walk_select && !vec_walk_select;
  assign ma_walk_req_ready = ptw_req_ready && ma_walk_select;
  assign vec_walk_req_ready = ptw_req_ready && vec_walk_select;

  logic walk_owner_ma_q, walk_owner_vec_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || tlb_invalidate) begin
      walk_owner_ma_q  <= 1'b0;
      walk_owner_vec_q <= 1'b0;
    end else if (ptw_req_valid && ptw_req_ready) begin
      walk_owner_ma_q  <= ma_walk_select;
      walk_owner_vec_q <= vec_walk_select;
    end
  end

  assign walk_resp_valid    = ptw_resp_valid && !core_walk_owner_i && !walk_owner_ma_q &&
                              !walk_owner_vec_q;
  assign iwalk_resp_valid   = ptw_resp_valid && core_walk_owner_i && !walk_owner_ma_q &&
                              !walk_owner_vec_q;
  assign ma_walk_resp_valid = ptw_resp_valid && walk_owner_ma_q;
  assign vec_walk_resp_valid = ptw_resp_valid && walk_owner_vec_q;

  // Speculative L2 TLB pre-read from the registered fetch PC when no real walk
  // request is offered. !walk_hold guarantees the data MMU is not requesting,
  // and excluding iwalk_req_valid, ma_walk_select and vec_walk_select keeps
  // l2_spec_valid disjoint from ptw_req_valid.
  logic l2_spec_en, l2_spec_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] l2_spec_vpn;
  assign l2_spec_en = !walk_hold && !iwalk_req_valid && !ma_walk_select && !vec_walk_select;
  assign l2_spec_valid = l2_spec_en && csr_fetch_translation_active;
  assign l2_spec_vpn = riscv_pkg::Sv39VpnBits'({{riscv_pkg::Sv39VpnBits{1'b0}}, o_pc} >> 12);

  // The second-level TLB answers repeat translations before the walker sees
  // them and stores the clean 4 KiB translations the walker returns. With
  // L2TLB_SETS = 0 the requests pass to the walker unchanged.
  logic l2_ptw_req_valid, l2_ptw_req_ready, l2_ptw_resp_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] l2_ptw_req_vpn;
  riscv_pkg::ptw_resp_t l2_ptw_resp;
  if (L2TLB_SETS > 0) begin : g_l2tlb
    l2tlb #(
        .SETS(L2TLB_SETS)
    ) u_l2tlb (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_asid(csr_mmu_asid),
        .i_flush(tlb_flush),
        .i_discard(tlb_invalidate),
        .i_req_valid(ptw_req_valid),
        .o_req_ready(ptw_req_ready),
        .i_req_vpn(ptw_req_vpn),
        .i_spec_valid(l2_spec_valid),
        .i_spec_vpn(l2_spec_vpn),
        .o_resp_valid(ptw_resp_valid),
        .o_resp(walk_resp),
        .o_ptw_req_valid(l2_ptw_req_valid),
        .i_ptw_req_ready(l2_ptw_req_ready),
        .o_ptw_req_vpn(l2_ptw_req_vpn),
        .i_ptw_resp_valid(l2_ptw_resp_valid),
        .i_ptw_resp(l2_ptw_resp)
    );
  end else begin : g_no_l2tlb
    assign l2_ptw_req_valid = ptw_req_valid;
    assign ptw_req_ready    = l2_ptw_req_ready;
    assign l2_ptw_req_vpn   = ptw_req_vpn;
    assign ptw_resp_valid   = l2_ptw_resp_valid;
    assign walk_resp        = l2_ptw_resp;
  end

  ptw #(
      .ENABLE_RESPONSE_ERRORS(VARIABLE_UNCACHED),
      .LINE_BYTES(WalkLineBytes)
  ) u_ptw (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_root_ppn(csr_satp_root_ppn),
      .i_pbmte(csr_menvcfg_pbmte),
      .i_req_valid(l2_ptw_req_valid),
      .o_req_ready(l2_ptw_req_ready),
      .i_req_vpn(l2_ptw_req_vpn),
      .i_discard(tlb_invalidate),
      .o_busy(ptw_busy),
      .o_resp_valid(l2_ptw_resp_valid),
      .o_resp(l2_ptw_resp),
      .o_line_req_valid(o_walk_line_req_valid),
      .i_line_req_ready(i_walk_line_req_ready),
      .o_line_req_addr(o_walk_line_req_addr),
      .o_line_req_id(o_walk_line_req_id),
      .i_line_resp_valid(i_walk_line_resp_valid),
      .i_line_resp_error(i_walk_line_resp_error),
      .i_line_resp_id(i_walk_line_resp_id),
      .i_line_resp_rdata(i_walk_line_resp_rdata)
  );

  // CSR acknowledgment waits for committed vector effects. With the unit
  // idle it arrives one cycle after csr_start: csr_start fires in
  // cycle N (the ROB serializer enters SERIAL_CSR_EXEC at its end) and
  // csr_done_ack in cycle N+1 lets the ROB commit an ordinary CSR. A CSR that
  // may change translation moves to SERIAL_CSR_TRANSLATION_DRAIN instead and
  // retires only after committed stores drain.
  logic csr_done_q, csr_vec_wait_q;
  logic vec_csr_quiet;
  assign vec_csr_quiet = !VECTOR || (vec_idle && !vec_varith_commit);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      csr_done_q <= 1'b0;
      csr_vec_wait_q <= 1'b0;
    end else if (flush_all) begin
      csr_done_q <= 1'b0;
      csr_vec_wait_q <= 1'b0;
    end else begin
      csr_done_q <= (csr_start || csr_vec_wait_q) && vec_csr_quiet;
      csr_vec_wait_q <= (csr_start || csr_vec_wait_q) && !vec_csr_quiet;
    end
  end
  assign csr_done_ack = csr_done_q;

  // ===========================================================================
  // Misaligned-Access Engine (MISALIGNED_HW)
  // ===========================================================================
  // A plain load or store whose address-misaligned exception reaches the ROB
  // head is an assist: the trap unit takes it without CSR effects, flushes,
  // redirects fetch past it and starts the engine with the head's fields.
  // While the engine runs, dispatch is held and interrupts and halt requests
  // wait (the AMO shield input). On completion the engine writes the load's
  // register through commit_actions' port 0 and the instruction counts as
  // retired; on a fault its exception is taken as the instruction's own.
  // LR, SC and AMOs keep their exceptions.
  logic ma_lc_req_valid_out, ma_lc_req_write_out, ma_fatal_out;
  logic [riscv_pkg::PhysAddrBits-1:0] ma_lc_req_addr_out, ma_fatal_addr_out;
  logic [255:0] ma_lc_req_data_out;
  logic [ 31:0] ma_lc_req_mask_out;
  logic [  3:0] ma_lc_req_id_out;
  if (MISALIGNED_HW) begin : gen_misaligned
    logic ma_fault, ma_wb_valid, ma_wb_fp, ma_lc_req_valid, ma_lc_req_id, ma_fatal_error;
    logic [4:0] ma_wb_rd;
    logic [XLEN-1:0] ma_wb_data, ma_fault_tval, ma_lc_req_addr;
    logic [ma_pkg::CauseBits-1:0] ma_fault_cause;
    logic [riscv_pkg::PhysAddrBits-1:0] ma_fatal_addr_q;
    // Debug Mode keeps the exception, so a program-buffer access parks.
    // Vector memory misaligned traps keep vec_head_shield raised in
    // HM_WAIT_TRAP and take their architectural exception directly with vstart.
    assign ma_exception_assist = coherent_exception_valid && !ma_fault_pending_q &&
        !rob_head_mem_atomic && !vec_head_shield && !csr_debug_mode &&
        ((rob_trap_cause == riscv_pkg::ExcLoadAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]) ||
         (rob_trap_cause == riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]));
    ma_engine #(
        .LC_ID_BITS(1)
    ) engine (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_start(ma_assist_start),
        // An assist uses the exact transformed address, including faults
        // whose MEM_RS sum crossed the pointer mask's sign boundary.
        .i_va(csr_trap_value),
        .i_size(riscv_pkg::mem_size_e'(rob_head_mem_funct3[1:0])),
        .i_unsigned(rob_head_mem_funct3[2]),
        // The ROB marks integer and FP stores with separate flags.
        .i_store(rob_head_mem_store || rob_head_mem_fp_store),
        .i_fp(rob_head_mem_fp_store || (!rob_head_mem_store && rob_head_dest_rf)),
        .i_rd(rob_head_dest_reg),
        .i_rd_valid(rob_head_dest_valid),
        .i_rs2(rob_head_mem_rs2),
        .i_older_vector_mem_done(vec_vmem_quiet),
        .i_translate(csr_translation_active),
        .i_eff_priv_u(csr_mmu_eff_priv_u),
        .i_sum(csr_mmu_sum),
        .i_mxr(csr_mmu_mxr),
        .i_fatal_stop(i_fatal_stop),
        .o_busy(ma_busy),
        .o_done(ma_done),
        .o_fault(ma_fault),
        .o_fault_cause(ma_fault_cause),
        .o_fault_tval(ma_fault_tval),
        .o_fatal_error(ma_fatal_error),
        .o_rf_read_en(),
        .o_rf_read_fp(ma_rf_read_fp),
        .o_rf_read_addr(ma_rf_read_addr),
        // The integer file's RAM does not hold x0 at zero; readers substitute it.
        .i_rf_read_data(ma_rf_read_fp ? ma_extra_fp_read_data[XLEN-1:0] :
                        (ma_rf_read_addr == 5'd0) ? '0 : ma_extra_int_read_data),
        .o_wb_valid(ma_wb_valid),
        .o_wb_fp(ma_wb_fp),
        .o_wb_rd(ma_wb_rd),
        .o_wb_data(ma_wb_data),
        .o_walk_req_valid(ma_walk_req_valid),
        .i_walk_req_ready(ma_walk_req_ready),
        .o_walk_vpn(ma_walk_vpn),
        .i_walk_resp_valid(ma_walk_resp_valid),
        .i_walk_resp(walk_resp),
        .o_lc_req_valid(ma_lc_req_valid),
        .i_lc_req_ready(i_ma_line_req_ready),
        .o_lc_req_write(ma_lc_req_write_out),
        .o_lc_req_addr(ma_lc_req_addr),
        .o_lc_req_data(ma_lc_req_data_out),
        .o_lc_req_mask(ma_lc_req_mask_out),
        .o_lc_req_id(ma_lc_req_id),
        .i_lc_resp_valid(i_ma_line_resp_valid && (i_ma_line_resp_id < 4'd2)),
        .i_lc_resp_id(i_ma_line_resp_id[0]),
        .i_lc_resp_error(i_ma_line_resp_error),
        .i_lc_resp_data(i_ma_line_resp_data)
    );
    assign ma_lc_req_valid_out = ma_lc_req_valid;
    assign ma_lc_req_addr_out = ma_lc_req_addr[riscv_pkg::PhysAddrBits-1:0];
    assign ma_lc_req_id_out = 4'(ma_lc_req_id);
    assign ma_wb_arm = ma_wb_valid;
    assign ma_wb_fp_arm = ma_wb_fp;
    assign ma_wb_rd_arm = ma_wb_rd;
    assign ma_wb_data_arm = riscv_pkg::FpWidth'(ma_wb_data);
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        ma_fault_pending_q <= 1'b0;
        ma_wb_valid_q <= 1'b0;
        ma_done_q <= 1'b0;
        ma_hold_q <= 1'b0;
      end else begin
        if (ma_fault) ma_fault_pending_q <= 1'b1;
        else if (trap_taken) ma_fault_pending_q <= 1'b0;
        ma_wb_valid_q <= ma_wb_arm;
        ma_done_q <= ma_done;
        ma_hold_q <= ma_assist_start || ma_hold || i_fatal_stop;
      end
    end
    // Payloads: no reset; each is read only with its valid.
    always_ff @(posedge i_clk) begin
      if (ma_fault) begin
        ma_fault_cause_q <= riscv_pkg::exc_cause_t'(ma_fault_cause);
        ma_fault_tval_q  <= ma_fault_tval;
      end
      if (ma_assist_start) ma_fault_pc_q <= rob_trap_pc;
      if (ma_wb_arm) begin
        ma_wb_fp_q   <= ma_wb_fp_arm;
        ma_wb_rd_q   <= ma_wb_rd_arm;
        ma_wb_data_q <= ma_wb_data_arm;
      end
      if (ma_lc_req_valid && i_ma_line_req_ready && ma_lc_req_write_out)
        ma_fatal_addr_q <= ma_lc_req_addr_out;
    end
    assign ma_fatal_out = ma_fatal_error;
    assign ma_fatal_addr_out = ma_fatal_addr_q;
    // Dispatch waits from the take until the register write has landed;
    // interrupts and halts wait while the engine runs or its fault is
    // pending. Dispatch sees ma_hold_q, a flop that covers ma_hold from the
    // cycle after the take and holds one cycle longer. It also samples a
    // fatal stop on the same edge as the engine, which enters its terminal
    // busy state even from idle, so no decode reaches the allocation enables.
    assign ma_hold = ma_busy || ma_fault_pending_q || ma_wb_valid_q || ma_done_q;
    assign ma_shield = ma_busy || ma_fault_pending_q;
`ifndef SYNTHESIS
    logic ma_reset_seen_q = 1'b0;
    always_ff @(posedge i_clk) begin
      if (i_rst) ma_reset_seen_q <= 1'b1;
      if (ma_reset_seen_q && !i_rst) begin
        // The engine starts only from an idle state with an empty ROB behind
        // the flush, and its register read follows every commit write.
        if (ma_assist_start) p_ma_start_idle : assert (!ma_busy && !ma_fault_pending_q);
        if (ma_busy) p_ma_no_commit : assert (!rob_commit_valid_raw && !csr_wb_pending);
        // Dispatch allocates nothing while the engine holds it, so no ROB
        // entry is left without its reservation-station or queue entry.
        if (ma_hold_q)
          p_ma_no_alloc : assert (!rob_alloc_req.alloc_valid && !rob_alloc_req_2.alloc_valid);
        if (ma_hold) p_ma_hold_registered : assert (ma_hold_q);
      end
    end
`endif
  end else begin : gen_no_misaligned
    assign ma_exception_assist = 1'b0;
    assign ma_busy = 1'b0;
    assign ma_done = 1'b0;
    assign ma_hold = 1'b0;
    assign ma_hold_q = 1'b0;
    assign ma_shield = 1'b0;
    assign ma_walk_req_valid = 1'b0;
    assign ma_walk_vpn = '0;
    assign ma_rf_read_fp = 1'b0;
    assign ma_rf_read_addr = '0;
    assign ma_wb_arm = 1'b0;
    assign ma_wb_fp_arm = 1'b0;
    assign ma_wb_rd_arm = '0;
    assign ma_wb_data_arm = '0;
    assign ma_fault_pending_q = 1'b0;
    assign ma_wb_valid_q = 1'b0;
    assign ma_done_q = 1'b0;
    assign ma_wb_fp_q = 1'b0;
    assign ma_wb_rd_q = '0;
    assign ma_wb_data_q = '0;
    assign ma_fault_cause_q = '0;
    assign ma_fault_tval_q = '0;
    assign ma_fault_pc_q = '0;
    assign ma_lc_req_valid_out = 1'b0;
    assign ma_lc_req_write_out = 1'b0;
    assign ma_lc_req_addr_out = '0;
    assign ma_lc_req_data_out = '0;
    assign ma_lc_req_mask_out = '0;
    assign ma_lc_req_id_out = '0;
    assign ma_fatal_out = 1'b0;
    assign ma_fatal_addr_out = '0;
  end

  // Ownership is sampled while the misaligned engine waits for older vector
  // memory work. Its translation and decision states precede any request;
  // the owner therefore settles before either lower or upper sector issues.
  logic ma_lc_owner_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) ma_lc_owner_q <= 1'b0;
    else ma_lc_owner_q <= ma_hold_q && vec_vmem_quiet;
  end
  assign o_ma_line_req_valid = ma_lc_owner_q ? ma_lc_req_valid_out : vec_lc_req_valid;
  assign o_ma_line_req_write = ma_lc_owner_q ? ma_lc_req_write_out : vec_lc_req_write;
  assign o_ma_line_req_addr  = ma_lc_owner_q ? ma_lc_req_addr_out : vec_lc_req_addr;
  assign o_ma_line_req_data  = ma_lc_owner_q ? ma_lc_req_data_out : vec_lc_req_data;
  assign o_ma_line_req_mask  = ma_lc_owner_q ? ma_lc_req_mask_out : vec_lc_req_mask;
  assign o_ma_line_req_id    = ma_lc_owner_q ? ma_lc_req_id_out : vec_lc_req_id;
  assign vec_lc_req_ready    = i_ma_line_req_ready && !ma_lc_owner_q;
  assign o_ma_fatal          = ma_fatal_out || vec_vmu_fatal;
  assign o_ma_fatal_addr     = ma_fatal_out ? ma_fatal_addr_out : vec_vmu_fatal_addr;
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      p_lc_ma_vec_disjoint : assert (!(ma_lc_req_valid_out && vec_lc_req_valid));
      p_lc_ma_owner : assert (!ma_lc_req_valid_out || ma_lc_owner_q);
      p_lc_vec_owner : assert (!vec_lc_req_valid || !ma_lc_owner_q);
      // The engine sees the client's ready directly. Its acceptance must
      // transfer the same request identity at the shared client port.
      if (ma_lc_req_valid_out && i_ma_line_req_ready)
        p_lc_ma_accept_reaches_client :
        assert (o_ma_line_req_valid && (o_ma_line_req_id == ma_lc_req_id_out));
      p_rf_ma_vec_disjoint : assert (!(ma_busy && vec_rf_read_en));
    end
  end
`endif

  // MEPC for MRET
  assign mepc_value = csr_mepc;

  // ===========================================================================
  // Trap Unit
  // ===========================================================================
  // Takes exceptions from the ROB head, interrupts, xRETs, and Debug Mode
  // halts and redirects.

  // Raw pending interrupts, gated by neither mstatus nor mie, for the WFI
  // wake. WFI resumes on any of them, which the spec permits (it requires
  // resuming even while interrupts are globally disabled); the trap unit
  // separately decides whether to take the interrupt.
  assign interrupt_pending = file_interrupts.meip || file_interrupts.mtip || file_interrupts.msip ||
      (|csr_s_pending) || csr_lcof_pending;

`ifdef FROST_RVFI_DII
`ifdef FROST_RVFI_DII_WFI_TIMEOUT
  if (DiiWfiTimeoutCycles != 0) begin : g_dii_wfi
    logic [31:0] wait_cycles_q;
    logic in_wait, in_wait_q, timeout_due, waking, woke_q, wfi_commit;
    logic [31:0] wait_entries_q  /* verilator public_flat_rd */;
    logic [31:0] source_wakes_q  /* verilator public_flat_rd */;
    logic [31:0] timeout_wakes_q  /* verilator public_flat_rd */;
    logic [31:0] retired_after_wake_q  /* verilator public_flat_rd */;
    logic [31:0] commit_while_waiting_q  /* verilator public_flat_rd */;
    logic [ 2:0] pending_q  /* verilator public_flat_rd */;

    // Observe the serializer state directly to distinguish wait entry from
    // other stalls at the head.
    assign in_wait = u_tomasulo.u_rob.serial_state == riscv_pkg::SERIAL_WFI_WAIT;
    assign timeout_due = wait_cycles_q == DiiWfiTimeoutCycles;
    assign dii_wfi_wake = interrupt_pending || csr_debug_mode || step_armed_q || timeout_due;
    assign waking = in_wait && dii_wfi_wake && !flush_all;
    assign wfi_commit = rob_commit_valid_raw && rob_head_is_wfi &&
        (rob_commit_comb.pc == rob_trap_pc);

    // The harness resets these observations for each trace. Keep a timeout
    // asserted through retirement, even if another condition holds commit.
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        in_wait_q <= 1'b0;
        woke_q <= 1'b0;
        wait_cycles_q <= '0;
        wait_entries_q <= '0;
        source_wakes_q <= '0;
        timeout_wakes_q <= '0;
        retired_after_wake_q <= '0;
        commit_while_waiting_q <= '0;
        pending_q <= '0;
      end else begin
        in_wait_q <= in_wait;
        if (in_wait && !in_wait_q) wait_entries_q <= wait_entries_q + 1'b1;
        if (waking) begin
          woke_q <= 1'b1;
          pending_q <= csr_s_pending;
          if (interrupt_pending) source_wakes_q <= source_wakes_q + 1'b1;
          else if (timeout_due) timeout_wakes_q <= timeout_wakes_q + 1'b1;
        end
        if ((in_wait || woke_q) && (rob_commit_valid_raw || rob_commit_2_valid_raw) &&
            !(wfi_commit && (waking || woke_q))) begin
          commit_while_waiting_q <= commit_while_waiting_q + 1'b1;
        end
        if (wfi_commit) begin
          if (woke_q || waking) retired_after_wake_q <= retired_after_wake_q + 1'b1;
          else pending_q <= csr_s_pending;
        end
        if (flush_all || wfi_commit) begin
          woke_q <= 1'b0;
          wait_cycles_q <= '0;
        end else if (in_wait && !dii_wfi_wake) begin
          wait_cycles_q <= wait_cycles_q + 1'b1;
        end
      end
    end
  end else begin : g_dii_wfi_nop
    assign dii_wfi_wake = 1'b1;
  end
`endif
`endif

  function automatic logic [XLEN-1:0] retired_next_pc(
      input riscv_pkg::reorder_buffer_commit_t commit);
    logic [XLEN-1:0] step;
    begin
      step = commit.is_compressed ? {{(XLEN - 2) {1'b0}}, 2'b10} : {{(XLEN - 3) {1'b0}}, 3'b100};
      if (commit.is_branch || commit.is_mret) begin
        retired_next_pc = commit.redirect_pc;
      end else begin
        retired_next_pc = commit.pc + step;
      end
    end
  endfunction

  // Register resume-PC candidates and selects separately, then mux for timing.
  // interrupt_resume_prev_q retains the result when no arm fires. Priority is
  // take, slot-2 commit, slot-1 commit, then WFI seed.
  logic resume_take_q, resume_commit_2_q, resume_commit_q, resume_wfi_q;
  logic [XLEN-1:0] resume_take_pc_q, resume_commit_2_pc_q, resume_commit_pc_q, resume_wfi_pc_q;
  logic [XLEN-1:0] interrupt_resume_prev_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      resume_take_q           <= 1'b0;
      resume_commit_2_q       <= 1'b0;
      resume_commit_q         <= 1'b0;
      resume_wfi_q            <= 1'b0;
      interrupt_resume_prev_q <= '0;
    end else begin
      resume_take_q           <= trap_or_xret_taken;
      resume_commit_2_q       <= rob_commit_2_valid_raw;
      resume_commit_q         <= rob_commit_valid_raw;
      resume_wfi_q            <= wfi_resume_seed;
      interrupt_resume_prev_q <= interrupt_resume_pc;
    end
    // Trap/xRET has highest priority. Select the xRET target using the ROB
    // head's return flavor, which must match the taken flavor.
    //
    // xRET retires through full flush, not the raw commit bus. Seed its target
    // (mepc, sepc, or dpc) so an interrupt before the target's first commit
    // cannot save and later re-execute the xRET at lower privilege. MRET leaves
    // mepc unchanged and cannot coincide with a trap that writes it.
    //
    // A trap also seeds its redirect target: an M interrupt after S delegation
    // must resume in the handler, and a single step that traps must halt at the
    // handler's first instruction (debug spec). Debug redirects use this arm;
    // interrupts are masked in Debug Mode. trap_entry_target equals trap_target
    // on a trap take. Trap and xRET takes are mutually exclusive.
    resume_take_pc_q <= trap_taken ? trap_entry_target :
                        mret_start_is_dret ? csr_dpc :
                        mret_start_is_sret ? csr_sepc : csr_mepc;
    // Slot-2 commit uses the precomputed next PC, equal to
    // retired_next_pc(rob_commit_comb_2) whenever this arm is selected.
    resume_commit_2_pc_q <= rob_head_next_retired_next_pc;
    // Slot-1 commit uses the corresponding precomputed next PC.
    resume_commit_pc_q <= rob_head_retired_next_pc;
    // Seed a waiting legal WFI's PC+4 so an interrupt resumes after it, even
    // when store drain finishes before WFI commits. WFI is never compressed;
    // real commits take priority.
    //
    // An illegal WFI gets no seed: it must trap after the handler returns.
    // Full flush and commit recovery remove the head, so seeding then would
    // overwrite the take or retirement PC. WFI acts as a NOP in Debug Mode and
    // during single step; seeding would skip a WFI after the stepped instruction.
    resume_wfi_pc_q <= rob_trap_pc + 64'd4;
  end
  assign interrupt_resume_pc = resume_take_q ? resume_take_pc_q :
      resume_commit_2_q ? resume_commit_2_pc_q :
      resume_commit_q ? resume_commit_pc_q :
      resume_wfi_q ? resume_wfi_pc_q : interrupt_resume_prev_q;

`ifndef SYNTHESIS
  // Reference resume-PC register with the same update priority.
  logic [XLEN-1:0] resume_pc_reference_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) resume_pc_reference_q <= '0;
    else if (trap_or_xret_taken)
      resume_pc_reference_q <= trap_taken ? trap_entry_target :
                               mret_start_is_dret ? csr_dpc :
                               mret_start_is_sret ? csr_sepc : csr_mepc;
    else if (rob_commit_2_valid_raw) resume_pc_reference_q <= rob_head_next_retired_next_pc;
    else if (rob_commit_valid_raw) resume_pc_reference_q <= rob_head_retired_next_pc;
    else if (wfi_resume_seed) resume_pc_reference_q <= rob_trap_pc + 64'd4;
  end
  logic resume_pc_reference_armed_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) resume_pc_reference_armed_q <= 1'b1;
    if (resume_pc_reference_armed_q && !i_rst && interrupt_resume_pc != resume_pc_reference_q) begin
`ifdef FROST_SIM_ASSERTIONS
      assert (1'b0)
      else
        $error(
            "cpu_ooo: interrupt_resume_pc %08x != reference %08x",
            interrupt_resume_pc,
            resume_pc_reference_q
        );
`else
      $error("cpu_ooo: interrupt_resume_pc %08x != reference %08x", interrupt_resume_pc,
             resume_pc_reference_q);
`endif
    end
  end
`endif

`ifndef SYNTHESIS
`ifndef FORMAL
  // Architectural next-PC check over every retirement. Each slot-1 retirement
  // must sit at the next PC of the previous retirement or trap/xRET take, and
  // slot 2 at slot 1's next PC. Any instruction retired from a wrong path
  // fails here, whatever the front end did to reach it: a stale prediction,
  // a lost redirect, or a fetch that skipped or repeated code.
  //
  // A take is checked the same way through the PC it acts on: an xRET's own
  // PC, and the PC a trap or Debug Mode entry saves (the trapping
  // instruction, or the interrupted or halted successor) must equal the
  // architectural next PC, with two exceptions. An interrupt or halt request
  // taken while a legal WFI waits at the head saves the PC past the WFI: this
  // check tracks the waiting WFI in a register of its own and requires the
  // core's resume-past-WFI flag to agree with it at every take. A
  // misaligned-access engine fault saves the PC of the instruction its assist
  // took, the PC before the assist's redirect, and only while that assist is
  // the last take. A Debug Mode go discards its saved PC and is not checked.
  //
  // These checks require local reset history. System assertions arm after
  // the testbench's driven reset reaches the active clock domains. The
  // next-PC check then arms at the first retirement; WFI seeding does not
  // move it.
  logic next_pc_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) next_pc_reset_seen_q <= 1'b1;
  logic next_pc_check_armed_q;
  logic [XLEN-1:0] next_pc_expected_q;
  // The PC of the instruction the last misaligned-access assist took, valid
  // until the engine finishes or another retirement or take.
  logic next_pc_assist_valid_q;
  logic [XLEN-1:0] next_pc_assist_pc_q;
  // A legal WFI at the architectural next PC waits at the ROB head.
  logic next_pc_wfi_waiting_q;
  // The take is an M or S interrupt or a Debug Mode halt request.
  logic next_pc_take_async;
  assign next_pc_take_async = (trap_cause_internal[XLEN-1] && !trap_to_d && !trap_no_csr) ||
      (trap_to_d && (trap_dbg_cause == riscv_pkg::DcsrCauseHaltreq));
  logic [XLEN-1:0] next_pc_take_expected;
  assign next_pc_take_expected = (ma_fault_pending_q && next_pc_assist_valid_q) ?
      next_pc_assist_pc_q :
      (next_pc_wfi_waiting_q && next_pc_take_async) ? next_pc_expected_q + 64'd4 :
      next_pc_expected_q;
  // The last retirements, printed when the check fails.
  localparam int unsigned NextPcHistory = 8;
  logic [NextPcHistory-1:0][XLEN-1:0] next_pc_hist_pc_q;
  logic [NextPcHistory-1:0][XLEN-1:0] next_pc_hist_next_q;
  logic [NextPcHistory-1:0][2:0] next_pc_hist_flags_q;  // {slot 2, misprediction, compressed}
  task automatic next_pc_dump();
    for (int i = NextPcHistory - 1; i >= 0; i--) begin
      $display("cpu_ooo:   retired pc %016x next %016x slot2 %0d mispredict %0d rvc %0d",
               next_pc_hist_pc_q[i], next_pc_hist_next_q[i], next_pc_hist_flags_q[i][2],
               next_pc_hist_flags_q[i][1], next_pc_hist_flags_q[i][0]);
    end
  endtask
  always_ff @(posedge i_clk) begin
    if (i_rst || !next_pc_reset_seen_q) begin
      next_pc_check_armed_q  <= 1'b0;
      next_pc_assist_valid_q <= 1'b0;
      next_pc_wfi_waiting_q  <= 1'b0;
    end else begin
      if (next_pc_check_armed_q && rob_commit_valid_raw &&
          rob_commit_comb.pc != next_pc_expected_q) begin
        next_pc_dump();
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: retired pc %016x, architectural next pc %016x",
              rob_commit_comb.pc,
              next_pc_expected_q
          );
`else
        $error("cpu_ooo: retired pc %016x, architectural next pc %016x", rob_commit_comb.pc,
               next_pc_expected_q);
`endif
      end
      if (rob_commit_valid_raw && rob_commit_2_valid_raw &&
          rob_commit_comb_2.pc != rob_head_retired_next_pc) begin
        next_pc_dump();
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: slot-2 retired pc %016x, slot-1 next pc %016x",
              rob_commit_comb_2.pc,
              rob_head_retired_next_pc
          );
`else
        $error("cpu_ooo: slot-2 retired pc %016x, slot-1 next pc %016x", rob_commit_comb_2.pc,
               rob_head_retired_next_pc);
`endif
      end
      if (next_pc_check_armed_q && trap_taken) begin
        p_take_counts_waiting_wfi :
        assert ((resume_pc_past_wfi_q && !trap_no_csr) ==
                (next_pc_wfi_waiting_q && next_pc_take_async))
        else
          $error(
              "cpu_ooo: take at %0t: resume-past-WFI flag %0d, waiting WFI %0d, async take %0d",
              $time,
              resume_pc_past_wfi_q,
              next_pc_wfi_waiting_q,
              next_pc_take_async
          );
      end
      if (next_pc_check_armed_q && trap_taken && !dbg_go_taken &&
          trap_pc_internal != next_pc_take_expected) begin
        next_pc_dump();
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: trap at %0t saved pc %016x, architectural next pc %016x",
              $time,
              trap_pc_internal,
              next_pc_take_expected
          );
`else
        $error("cpu_ooo: trap at %0t saved pc %016x, architectural next pc %016x", $time,
               trap_pc_internal, next_pc_take_expected);
`endif
      end
      if (next_pc_check_armed_q && xret_taken && rob_trap_pc != next_pc_expected_q) begin
        next_pc_dump();
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: xRET at %0t at pc %016x, architectural next pc %016x",
              $time,
              rob_trap_pc,
              next_pc_expected_q
          );
`else
        $error("cpu_ooo: xRET at %0t at pc %016x, architectural next pc %016x", $time, rob_trap_pc,
               next_pc_expected_q);
`endif
      end
      if (trap_taken && ma_assist_start) begin
        next_pc_assist_valid_q <= 1'b1;
        next_pc_assist_pc_q <= trap_pc_internal;
      end else if (ma_done || rob_commit_valid_raw || xret_taken || trap_taken) begin
        next_pc_assist_valid_q <= 1'b0;
      end
      // Mirrors the seeding rule independently, with the head at the
      // architectural next PC.
      if (trap_or_xret_taken || rob_commit_2_valid_raw || rob_commit_valid_raw) begin
        next_pc_wfi_waiting_q <= 1'b0;
      end else if (rob_head_is_wfi && head_valid && (rob_trap_cause == '0) && !flush_all &&
                   !mispredict_recovery_pending && !csr_debug_mode && !step_armed_q &&
                   next_pc_check_armed_q && (rob_trap_pc == next_pc_expected_q)) begin
        next_pc_wfi_waiting_q <= 1'b1;
      end
      if (rob_commit_valid_raw) begin
        next_pc_hist_pc_q <= {next_pc_hist_pc_q[NextPcHistory-2:0], rob_commit_comb.pc};
        next_pc_hist_next_q <= {next_pc_hist_next_q[NextPcHistory-2:0], rob_head_retired_next_pc};
        next_pc_hist_flags_q <= {
          next_pc_hist_flags_q[NextPcHistory-2:0],
          {1'b0, rob_commit_comb.misprediction, rob_commit_comb.is_compressed}
        };
        if (rob_commit_2_valid_raw) begin
          next_pc_hist_pc_q <= {
            next_pc_hist_pc_q[NextPcHistory-3:0], rob_commit_comb.pc, rob_commit_comb_2.pc
          };
          next_pc_hist_next_q <= {
            next_pc_hist_next_q[NextPcHistory-3:0],
            rob_head_retired_next_pc,
            rob_head_next_retired_next_pc
          };
          next_pc_hist_flags_q <= {
            next_pc_hist_flags_q[NextPcHistory-3:0],
            {1'b0, rob_commit_comb.misprediction, rob_commit_comb.is_compressed},
            {1'b1, rob_commit_comb_2.misprediction, rob_commit_comb_2.is_compressed}
          };
        end
      end
      if (trap_or_xret_taken) begin
        next_pc_check_armed_q <= 1'b1;
        next_pc_expected_q <= trap_taken ? trap_entry_target :
                              mret_start_is_dret ? csr_dpc :
                              mret_start_is_sret ? csr_sepc : csr_mepc;
      end else if (rob_commit_2_valid_raw) begin
        next_pc_check_armed_q <= 1'b1;
        next_pc_expected_q <= rob_head_next_retired_next_pc;
      end else if (rob_commit_valid_raw) begin
        next_pc_check_armed_q <= 1'b1;
        next_pc_expected_q <= rob_head_retired_next_pc;
      end
    end
  end

  // The reorder buffer's side of the next-PC check is proved by
  // formal/rob_retire_successor.sby, which assumes these contracts on the
  // ROB's own ports:
  //  - each allocation is at the predicted next PC of the allocation before
  //    it: the predicted target of a branch predicted taken, otherwise the
  //    fall-through. The first allocation after a partial flush is at the
  //    resolved next PC of the entry the flush keeps last, and a full flush
  //    leaves the next allocation free. The front end keeps allocating
  //    behind an instruction that traps or carries a fetch fault (an illegal
  //    or ebreak compressed slot 1 drops its slot-2 partner, and fetch steps
  //    past a faulting instruction by a size taken from arbitrary bytes,
  //    whatever its parcel decodes to), so a slot-1 allocation may leave this
  //    order when the allocation before it is a valid entry that has not
  //    completed without an exception, and a slot-2 allocation when slot 1
  //    does not allocate done without a fault. That entry is then a barrier:
  //    it never completes without an exception while it is valid, and every
  //    allocation is free until a flush removes the barrier. A partial flush
  //    that keeps it, the early recovery of a younger branch, leaves the
  //    barrier in force;
  //  - a branch update completes a conditional branch or JALR, once, and sets its
  //    misprediction flag exactly when the outcome, or the taken target,
  //    differs from the prediction the entry was allocated with;
  //  - no CDB write without an exception, and no store completion, reaches a
  //    conditional branch or JALR until the cycle after its branch update.
  //    The head+1 CDB bypass would otherwise retire it in slot 2 before its
  //    misprediction flag is written.
  // It also checks the two contracts of the ROB's own formal block that no
  // other check covers: the private CDB match tags equal the shared tags, and
  // a memory-order replay never flags a serializing head.
  localparam int unsigned RobDepth = riscv_pkg::ReorderBufferDepth;
  localparam int unsigned RobTagWidth = riscv_pkg::ReorderBufferTagWidth;
  function automatic logic [XLEN-1:0] alloc_predicted_next_pc(
      input riscv_pkg::reorder_buffer_alloc_req_t req);
    alloc_predicted_next_pc =
        (req.is_branch && req.predicted_taken) ? req.predicted_target : req.link_addr;
  endfunction
  // The ROB's own allocation, update and completion signals.
  riscv_pkg::reorder_buffer_alloc_req_t rob_chk_req, rob_chk_req_2;
  riscv_pkg::reorder_buffer_branch_update_t rob_chk_update;
  riscv_pkg::reorder_buffer_cdb_write_t rob_chk_cdb, rob_chk_cdb_2;
  logic rob_chk_alloc, rob_chk_alloc_2, rob_chk_update_en, rob_chk_flush_all, rob_chk_flush_en;
  logic [RobTagWidth-1:0] rob_chk_tail, rob_chk_tail_2, rob_chk_flush_tag;
  logic [XLEN-1:0] rob_chk_pred_next, rob_chk_pred_next_2;
  assign rob_chk_req = u_tomasulo.u_rob.i_alloc_req;
  assign rob_chk_req_2 = u_tomasulo.u_rob.i_alloc_req_2;
  assign rob_chk_alloc = u_tomasulo.u_rob.alloc_en;
  assign rob_chk_alloc_2 = u_tomasulo.u_rob.alloc_en_2;
  assign rob_chk_tail = u_tomasulo.u_rob.tail_idx;
  assign rob_chk_tail_2 = u_tomasulo.u_rob.tail_idx_2;
  assign rob_chk_update = u_tomasulo.u_rob.i_branch_update;
  assign rob_chk_update_en = u_tomasulo.u_rob.branch_wr_en;
  assign rob_chk_cdb = u_tomasulo.u_rob.i_cdb_write;
  assign rob_chk_cdb_2 = u_tomasulo.u_rob.i_cdb_write_2;
  assign rob_chk_flush_all = u_tomasulo.u_rob.i_flush_all;
  assign rob_chk_flush_en = u_tomasulo.u_rob.i_flush_en;
  assign rob_chk_flush_tag = u_tomasulo.u_rob.i_flush_tag;
  assign rob_chk_pred_next = alloc_predicted_next_pc(rob_chk_req);
  assign rob_chk_pred_next_2 = alloc_predicted_next_pc(rob_chk_req_2);
  logic rob_chain_valid_q;
  logic [XLEN-1:0] rob_chain_pc_q;
  logic [RobDepth-1:0] rob_shadow_pred_taken_q, rob_shadow_needs_update_q, rob_shadow_updated_q;
  logic [RobDepth-1:0][XLEN-1:0] rob_shadow_pred_target_q, rob_shadow_link_q, rob_shadow_next_q;
  logic [RobDepth-1:0] rob_chk_completes;
  // The last allocation and whether it allocated done without a fault or
  // has completed without an exception; the barrier, and the number of
  // allocations it frees from the chain.
  logic rob_last_valid_q, rob_last_normal_q, rob_broken_q;
  logic [RobTagWidth-1:0] rob_last_tag_q, rob_barrier_tag_q;
  logic [RobDepth-1:0] rob_chk_normal_done;
  logic rob_chk_off_chain, rob_chk_pair_off;
  int unsigned rob_barrier_count_q = 0, rob_barrier_free_count_q = 0, rob_barrier_off_count_q = 0;
  assign rob_chk_off_chain = rob_chk_alloc && rob_chain_valid_q && !rob_broken_q &&
      (rob_chk_req.pc != rob_chain_pc_q);
  // Slot 2 away from slot 1's predicted next PC. For a fetch fault, fetch
  // steps by slot 1's predecode sideband and PD sizes slot 1 from its parcel,
  // both arbitrary bytes, so slot 2 may sit two bytes before or after slot
  // 1's link address. Slot 1 is then the barrier.
  assign rob_chk_pair_off = rob_chk_alloc_2 && !rob_broken_q && !rob_chk_off_chain &&
      (rob_chk_req_2.pc != rob_chk_pred_next);
  // The entries a flush removes this cycle, as the ROB clears them: all on a
  // full flush or a commit-time recovery, those younger than the flush tag on
  // an early recovery.
  logic [RobDepth-1:0] rob_chk_flush_clear;
  for (genvar e = 0; e < RobDepth; e++) begin : g_rob_chk_flush_clear
    assign rob_chk_flush_clear[e] = u_tomasulo.u_rob.gen_valid_next[e].flush_clear;
  end
  always_comb begin
    for (int i = 0; i < RobDepth; i++) begin
      rob_chk_normal_done[i] = rob_chk_completes[i] ||
          (rob_chk_update_en && (rob_chk_update.tag == RobTagWidth'(i)));
    end
  end
  final begin
    if (rob_barrier_count_q != 0)
      $display(
          "cpu_ooo: %0d ROB barriers behind a trap or fetch fault freed %0d allocations, %0d off",
          rob_barrier_count_q,
          rob_barrier_free_count_q,
          rob_barrier_off_count_q
      );
  end
  always_comb begin
    for (int i = 0; i < RobDepth; i++) begin
      rob_chk_completes[i] =
          (rob_chk_cdb.valid && !rob_chk_cdb.exception && (rob_chk_cdb.tag == RobTagWidth'(i))) ||
          (rob_chk_cdb_2.valid && !rob_chk_cdb_2.exception &&
           (rob_chk_cdb_2.tag == RobTagWidth'(i))) ||
          (u_tomasulo.u_rob.i_store_complete_valid &&
           (u_tomasulo.u_rob.i_store_complete_tag == RobTagWidth'(i)));
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst || !next_pc_reset_seen_q) begin
      rob_chain_valid_q <= 1'b0;
      rob_last_valid_q  <= 1'b0;
      rob_broken_q      <= 1'b0;
    end else begin
      if (rob_chk_off_chain) begin
        p_rob_alloc_follows_prediction :
        assert (rob_last_valid_q && u_tomasulo.u_rob.rob_valid[rob_last_tag_q] &&
                !rob_last_normal_q && !rob_chk_normal_done[rob_last_tag_q])
        else
          $error(
              "cpu_ooo: ROB allocation at %0t at pc %016x, predicted next pc %016x",
              $time,
              rob_chk_req.pc,
              rob_chain_pc_q
          );
      end
      if (rob_broken_q && u_tomasulo.u_rob.rob_valid[rob_barrier_tag_q] && !rob_chk_flush_all) begin
        p_rob_barrier_never_completes : assert (!rob_chk_normal_done[rob_barrier_tag_q]);
      end
      if (rob_chk_off_chain || rob_chk_pair_off) rob_barrier_count_q <= rob_barrier_count_q + 1;
      if (rob_chk_alloc && (rob_broken_q || rob_chk_off_chain))
        rob_barrier_free_count_q <= rob_barrier_free_count_q + (rob_chk_alloc_2 ? 2 : 1);
      else if (rob_chk_pair_off) rob_barrier_free_count_q <= rob_barrier_free_count_q + 1;
      if (rob_chk_alloc && (rob_broken_q || rob_chk_off_chain) && rob_chain_valid_q &&
          (rob_chk_req.pc != rob_chain_pc_q))
        rob_barrier_off_count_q <= rob_barrier_off_count_q + 1;
      if (rob_chk_flush_all || rob_chk_flush_en) begin
        rob_last_valid_q <= 1'b0;
        // Only a flush that removes the barrier entry ends the barrier.
        if (rob_chk_flush_clear[rob_barrier_tag_q]) rob_broken_q <= 1'b0;
      end else begin
        if (rob_chk_off_chain) begin
          rob_broken_q <= 1'b1;
          rob_barrier_tag_q <= rob_last_tag_q;
        end else if (rob_chk_pair_off) begin
          rob_broken_q <= 1'b1;
          rob_barrier_tag_q <= rob_chk_tail;
        end
        if (rob_chk_alloc) begin
          rob_last_valid_q <= 1'b1;
          rob_last_tag_q <= rob_chk_alloc_2 ? rob_chk_tail_2 : rob_chk_tail;
          rob_last_normal_q <= rob_chk_alloc_2 ?
              (u_tomasulo.u_rob.alloc_done_value_2 &&
               !u_tomasulo.u_rob.alloc_legality_fault_data_2) :
              (u_tomasulo.u_rob.alloc_done_value && !u_tomasulo.u_rob.alloc_legality_fault_data);
        end else if (rob_chk_normal_done[rob_last_tag_q]) begin
          rob_last_normal_q <= 1'b1;
        end
      end
      if (rob_chk_pair_off) begin
        p_rob_alloc_slot2_follows_slot1 :
        assert (!(u_tomasulo.u_rob.alloc_done_value && !u_tomasulo.u_rob.alloc_legality_fault_data))
        else
          $error(
              "cpu_ooo: slot-2 ROB allocation at %0t at pc %016x, predicted next pc %016x",
              $time,
              rob_chk_req_2.pc,
              rob_chk_pred_next
          );
      end
      if (rob_chk_update_en) begin
        p_rob_branch_update_targets_branch :
        assert (rob_shadow_needs_update_q[rob_chk_update.tag] &&
                !rob_shadow_updated_q[rob_chk_update.tag]);
        p_rob_branch_update_matches_prediction :
        assert (rob_chk_update.mispredicted ==
                ((rob_chk_update.taken != rob_shadow_pred_taken_q[rob_chk_update.tag]) ||
                 (rob_chk_update.taken &&
                  (rob_chk_update.target != rob_shadow_pred_target_q[rob_chk_update.tag]))));
      end
      if (!rob_chk_flush_all) begin
        p_rob_branch_completed_by_update :
        assert ((u_tomasulo.u_rob.rob_valid & rob_shadow_needs_update_q & ~rob_shadow_updated_q &
                 rob_chk_completes) == '0);
      end
      p_rob_cdb_match_tags_equal :
      assert ((u_tomasulo.u_rob.i_cdb_match_tag == rob_chk_cdb.tag) &&
              (u_tomasulo.u_rob.i_cdb_match_tag_2 == rob_chk_cdb_2.tag));
      p_rob_replay_spares_serial_head :
      assert (!(|(u_tomasulo.u_rob.i_replay_set_mask & u_tomasulo.u_rob.head_clear_mask) &&
                (u_tomasulo.u_rob.head_f_is_csr || u_tomasulo.u_rob.head_f_is_mret ||
                 u_tomasulo.u_rob.head_f_is_fence || u_tomasulo.u_rob.head_f_is_fence_i ||
                 u_tomasulo.u_rob.head_f_is_wfi)));
      if (rob_chk_flush_all) begin
        rob_chain_valid_q <= 1'b0;
      end else if (rob_chk_flush_en) begin
        rob_chain_valid_q <= 1'b1;
        rob_chain_pc_q <= rob_shadow_next_q[rob_chk_flush_tag];
      end else if (rob_chk_alloc_2) begin
        rob_chain_valid_q <= 1'b1;
        rob_chain_pc_q <= rob_chk_pred_next_2;
      end else if (rob_chk_alloc) begin
        rob_chain_valid_q <= 1'b1;
        rob_chain_pc_q <= rob_chk_pred_next;
      end
    end
  end
  // Per-entry shadows, written at allocation and branch update.
  always_ff @(posedge i_clk) begin
    if (rob_chk_alloc) begin
      rob_shadow_pred_taken_q[rob_chk_tail] <= rob_chk_req.is_branch && rob_chk_req.predicted_taken;
      rob_shadow_pred_target_q[rob_chk_tail] <= rob_chk_req.predicted_target;
      rob_shadow_needs_update_q[rob_chk_tail] <= rob_chk_req.is_branch && !rob_chk_req.is_jal;
      rob_shadow_updated_q[rob_chk_tail] <= 1'b0;
      rob_shadow_link_q[rob_chk_tail] <= rob_chk_req.link_addr;
      rob_shadow_next_q[rob_chk_tail] <=
          rob_chk_req.is_jal ? rob_chk_req.branch_target : rob_chk_req.link_addr;
    end
    if (rob_chk_alloc_2) begin
      rob_shadow_pred_taken_q[rob_chk_tail_2] <=
          rob_chk_req_2.is_branch && rob_chk_req_2.predicted_taken;
      rob_shadow_pred_target_q[rob_chk_tail_2] <= rob_chk_req_2.predicted_target;
      rob_shadow_needs_update_q[rob_chk_tail_2] <= rob_chk_req_2.is_branch && !rob_chk_req_2.is_jal;
      rob_shadow_updated_q[rob_chk_tail_2] <= 1'b0;
      rob_shadow_link_q[rob_chk_tail_2] <= rob_chk_req_2.link_addr;
      rob_shadow_next_q[rob_chk_tail_2] <=
          rob_chk_req_2.is_jal ? rob_chk_req_2.branch_target : rob_chk_req_2.link_addr;
    end
    if (rob_chk_update_en) begin
      rob_shadow_updated_q[rob_chk_update.tag] <= 1'b1;
      rob_shadow_next_q[rob_chk_update.tag] <= rob_chk_update.taken ? rob_chk_update.target :
          rob_shadow_link_q[rob_chk_update.tag];
    end
  end

  // Every BTB invalidate lands in a full-flush cycle, so the flush cancels
  // the pending training that the controller's hold must outlast.
  always_ff @(posedge i_clk) begin
    if (!i_rst && next_pc_reset_seen_q) begin
      p_btb_invalidate_with_full_flush : assert (!btb_invalidate || flush_all);
    end
  end
`endif
`endif

  assign wfi_resume_seed = rob_head_is_wfi && head_valid && (rob_trap_cause == '0) &&
      !flush_all && !mispredict_recovery_pending && !csr_debug_mode && !step_armed_q;

  // Mirrors the arms above: only the seed sets the flag, and every
  // higher-priority arm clears it.
  always_ff @(posedge i_clk) begin
    if (i_rst || xret_taken || trap_taken || rob_commit_2_valid_raw || rob_commit_valid_raw)
      resume_pc_past_wfi_q <= 1'b0;
    else if (wfi_resume_seed) resume_pc_past_wfi_q <= 1'b1;
  end

  // Instructions that retire without a registered commit, for instret
  // (commit_actions adds this bit a cycle later):
  //  - an xRET, which retires through the full flush after it;
  //  - a legal WFI that a halt or an M/S interrupt takes over at the ROB head:
  //    the take saves the seeded wfi_pc+4, so the WFI has executed. A WFI that
  //    commits first clears resume_pc_past_wfi_q, so it never counts twice. A
  //    Debug Mode go redirect or re-park (trap_no_csr) saves no PC and is
  //    left out;
  //  - a FENCE.I or SFENCE.VMA (the native FENCE-class event): it commits, but
  //    the full flush it raises masks its own registered commit. A trap taken
  //    in the same cycle would squash that commit instead, and the fence
  //    would run again after the handler.
  always_ff @(posedge i_clk) begin
    retired_without_commit_q <= !i_rst &&
        (xret_taken || (trap_taken && !trap_no_csr && resume_pc_past_wfi_q) ||
         (fence_class_flush_event && !translation_csr_commit_shadow && !trap_taken) || ma_done);
  end

`ifndef SYNTHESIS
  // A take that counts a waiting WFI saves the seeded resume PC past it.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && trap_taken && !trap_no_csr && resume_pc_past_wfi_q) begin
      p_counted_wfi_take_saves_seed :
      assert (trap_pc_internal == interrupt_resume_pc)
      else
        $error(
            "cpu_ooo: a take counted the waiting WFI but saved PC %08x, not the seed %08x",
            trap_pc_internal,
            interrupt_resume_pc
        );
    end
  end
`endif

`ifndef SYNTHESIS
  // Equivalence check for the ROB retired-next-PC precompute: whenever a
  // commit fires, the precomputed value must match retired_next_pc() of the
  // (gated) commit payload.
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (trap_or_xret_taken != (trap_taken || xret_taken)) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: combined trap/xRET take differs from individual takes");
`else
        $error("cpu_ooo: combined trap/xRET take differs from individual takes");
`endif
      end
      if (xret_taken &&
          (mret_start_is_dret ? csr_dpc : mret_start_is_sret ? csr_sepc : csr_mepc) !=
          (dret_taken ? csr_dpc : sret_taken ? csr_sepc : csr_mepc)) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: ROB head return flavor differs from the taken xRET");
`else
        $error("cpu_ooo: ROB head return flavor differs from the taken xRET");
`endif
      end
      if (trap_taken && trap_entry_target != trap_target) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: trap-entry target differs from its redirect");
`else
        $error("cpu_ooo: trap-entry target differs from its redirect");
`endif
      end
      if (rob_commit_valid_raw && rob_head_retired_next_pc != retired_next_pc(
              rob_commit_comb
          )) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: rob_head_retired_next_pc %08x != retired_next_pc(commit) %08x",
              rob_head_retired_next_pc,
              retired_next_pc(
                  rob_commit_comb
              )
          );
`else
        $error("cpu_ooo: rob_head_retired_next_pc %08x != retired_next_pc(commit) %08x",
               rob_head_retired_next_pc, retired_next_pc(rob_commit_comb));
`endif
      end
      if (rob_commit_2_valid_raw && rob_head_next_retired_next_pc != retired_next_pc(
              rob_commit_comb_2
          )) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else
          $error(
              "cpu_ooo: rob_head_next_retired_next_pc %08x != retired_next_pc(commit_2) %08x",
              rob_head_next_retired_next_pc,
              retired_next_pc(
                  rob_commit_comb_2
              )
          );
`else
        $error("cpu_ooo: rob_head_next_retired_next_pc %08x != retired_next_pc(commit_2) %08x",
               rob_head_next_retired_next_pc, retired_next_pc(rob_commit_comb_2));
`endif
      end
      // An xRET retires through the full flush that follows it, never on the
      // raw commit path, so the ROB's retired next-PC outputs need no xRET arm.
      if (rob_commit_valid_raw && rob_commit_comb.is_mret) begin
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0)
        else $error("cpu_ooo: an xRET retired on the raw commit path");
`else
        $error("cpu_ooo: an xRET retired on the raw commit path");
`endif
      end
    end
  end

  // An interrupt at a waiting legal WFI must save PC+4. An illegal WFI must
  // remain at its own PC so it traps after return. Require the same head to
  // have waited a cycle without retirement, trap, or flush, allowing the seed
  // to settle. WFI has a nonzero cause only when allocation marks it illegal.
  logic wfi_waiting_q;
  logic wfi_waiting_legal_q;
  logic [XLEN-1:0] wfi_waiting_pc_q;
  always_ff @(posedge i_clk) begin
    wfi_waiting_q <= !i_rst && rob_head_is_wfi && head_valid &&
                     !rob_commit_valid_raw && !trap_taken && !xret_taken &&
                     !flush_all && !flush_en && !mispredict_recovery_pending;
    wfi_waiting_legal_q <= (rob_trap_cause == '0);
    wfi_waiting_pc_q <= rob_trap_pc;
  end
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && wfi_waiting_q && trap_taken && !trap_to_d && !trap_no_csr &&
        trap_cause_internal[XLEN-1] && rob_head_is_wfi && head_valid &&
        (rob_trap_pc == wfi_waiting_pc_q)) begin
      if (wfi_waiting_legal_q) begin
        p_wfi_interrupt_resumes_after_wfi :
        assert (trap_pc_internal == wfi_waiting_pc_q + XLEN'(4))
        else
          $error(
              "cpu_ooo: interrupt at a waiting WFI (pc %08x) saved resume PC %08x, want %08x",
              wfi_waiting_pc_q,
              trap_pc_internal,
              wfi_waiting_pc_q + XLEN'(4)
          );
      end else begin
        p_illegal_wfi_interrupt_keeps_wfi :
        assert (trap_pc_internal != wfi_waiting_pc_q + XLEN'(4))
        else
          $error(
              "cpu_ooo: interrupt at a waiting illegal WFI (pc %08x) saved resume PC %08x",
              wfi_waiting_pc_q,
              trap_pc_internal
          );
      end
    end
  end
`endif

  // Use SQ's registered committed-empty copy and VMT's registered quiet flag
  // for trap fanout: traps, interrupts, xRETs, and debug halts wait for both
  // committed scalar stores and retired vector memory ops to drain.
  assign sq_committed_empty_for_trap = sq_committed_empty_trap && vec_vmem_quiet;

  // AMO interrupt shield register (see trap_unit.i_amo_at_head port comment
  // for the hazard and the lag-safety argument).
  always_ff @(posedge i_clk) begin
    if (i_rst) amo_at_head_shield_q <= 1'b0;
    else amo_at_head_shield_q <= rob_head_is_amo && head_valid;
  end

  // The trap unit's AMO-class shield: an AMO, LR or SC at the head, a coherent
  // atomic, the misaligned-access engine, or head-executed vector memory.
  logic trap_amo_shield;
  assign trap_amo_shield = (amo_at_head_shield_q && !(step_done_q)) || coherent_atomic_active ||
      ma_shield || vec_head_shield;
  // The shield counts as down in the cycle a commit clears it. The commit is
  // the shielded access's own, so nothing launched still needs the shield,
  // and a device store right behind it would otherwise keep it up.
  assign device_start_hold = int_take_armed && !trap_amo_shield &&
      (!device_read_shield_q || rob_commit_valid);

  // Hold interrupts from before a device read or uncached store is accepted
  // through its commit. Uncached stores arm their shield in the SQ;
  // (see trap_unit.i_device_read_at_head). The router stages the request before
  // arming a device read. Both launch only at the ROB head; a pending response blocks
  // both commit slots, so the first later commit is this access's. Set wins over
  // clear. Flush before arming cancels the request; the shield prevents an
  // interrupt flush after arming.
  always_ff @(posedge i_clk) begin
    if (i_rst || lq_router_flush_all) device_read_shield_q <= 1'b0;
    else if ((lq_device_request_pending || (uncached_store_pending && !device_start_hold)) &&
             !(step_done_q))
      device_read_shield_q <= 1'b1;
    else if (rob_commit_valid) device_read_shield_q <= 1'b0;
  end

  assign xret_taken = mret_taken || sret_taken || dret_taken;

  trap_unit #(
      .XLEN(XLEN)
  ) trap_unit_inst (
      .i_clk,
      .i_rst,
      // A translation CSR retires at T, csr_file writes it from the registered
      // commit bus at T+1, and its full flush follows at T+2. Block every
      // trap, Debug Mode, and xRET take on both cycles, so no take coincides
      // with the CSR write (csr_file relies on that) and no stale younger
      // xRET can execute on the flush edge.
      .i_pipeline_stall(fence_class_quiesce),
      .i_csr_irq_update(csr_irq_update_q),
      .i_sq_committed_empty(sq_committed_empty_for_trap),
      .o_trap_drain_wait(trap_drain_wait),
      .i_amo_at_head(trap_amo_shield),
      .i_device_read_at_head(device_read_shield_q),
      .o_int_take_armed(int_take_armed),
      .i_mstatus(csr_mstatus),
      // The engine's terminal state shields interrupts when built. Use the
      // registered hart stop to inhibit interrupt entry in the other
      // configuration. The CSR retains its enables and pending bits.
      .i_mie((MISALIGNED_HW || !i_fatal_stop) ? csr_mie : '0),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_stvec(csr_stvec),
      .i_sepc(csr_sepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      .i_sstatus_sie_direct(csr_sstatus_sie_direct),
      .i_mideleg_s(csr_mideleg_s),
      .i_medeleg(csr_medeleg),
      .i_priv(csr_priv),
`ifdef FROST_RVFI_DII
      // TestRIG: no interrupt is ever taken, including the supervisor ones
      // that mip writes can raise.
      .i_interrupts('0),
      .i_s_pending('0),
      .i_lcof_pending(1'b0),
`else
      .i_interrupts(file_interrupts),
      .i_s_pending(csr_s_pending),
      .i_lcof_pending(csr_lcof_pending),
`endif
      .i_mideleg_lcof(csr_mideleg_lcof),
      // Exception from the ROB head. i_pipeline_stall does not gate the trap
      // unit's exception latch, so mask the exception over the same T+1/T+2
      // window; otherwise a stale younger exception could survive the full
      // flush and be taken at T+3.
      // An engine fault is the misaligned instruction's exception; the ROB
      // holds nothing then.
      .i_exception_valid(coherent_exception_valid || ma_fault_pending_q),
      .i_exception_cause(ma_fault_pending_q ? {{(XLEN - $bits(
          ma_fault_cause_q
      )) {1'b0}}, ma_fault_cause_q} : {{(XLEN - $bits(
          rob_trap_cause_remapped
      )) {1'b0}}, rob_trap_cause_remapped}),
      .i_exception_tval(trap_exception_tval),
      .i_exception_tval_pm_mode(trap_exception_tval_pm_mode),
      .i_exception_tval_virt(csr_translation_active),
      .i_exception_pc(ma_fault_pending_q ? ma_fault_pc_q : rob_trap_pc),
      .i_exception_assist(ma_exception_assist),
      .i_exception_next_pc(rob_head_fallthrough_pc),
      .o_assist_start(ma_assist_start),
      .i_interrupt_pc(interrupt_resume_pc),
      .i_mret_start(mret_start && !mret_start_is_sret && !mret_start_is_dret),
      .i_sret_start(mret_start && mret_start_is_sret),
      .i_wfi_start(1'b0),  // WFI handled by ROB serialization
      // Debug Mode
      .i_debug_mode(csr_debug_mode),
      // A fatal stop refuses Debug Mode entry in every configuration: the
      // engine's terminal state already shields it when the engine is built.
      // The debug module reports the hart as unavailable meanwhile.
      .i_dbg_haltreq((MISALIGNED_HW || !i_fatal_stop) ? i_dbg_haltreq : 1'b0),
      .i_dbg_step_req((MISALIGNED_HW || !i_fatal_stop) ? step_done_q : 1'b0),
      .i_dbg_step_armed(step_armed_q),
      .i_dbg_go(i_dbg_go),
      .i_dbg_go_target(XLEN'(i_dbg_go_addr)),
      .i_dcsr_ebreak(csr_dcsr_ebreak),
      .i_dpc(csr_dpc),
      .i_dret_start(mret_start && mret_start_is_dret),
      .o_trap_taken(trap_taken),
      .o_trap_to_s(trap_to_s),
      .o_mret_taken(mret_taken),
      .o_sret_taken(sret_taken),
      .o_trap_or_xret_taken(trap_or_xret_taken),
      .o_trap_target(trap_target),
      .o_trap_entry_target(trap_entry_target),
      .o_trap_pc(trap_pc_internal),
      .o_trap_cause(trap_cause_internal),
      .o_trap_value(trap_value_internal),
      .o_trap_save_m(trap_save_m),
      .o_trap_save_s(trap_save_s),
      .o_trap_enter_d(trap_enter_d),
      .o_trap_to_d(trap_to_d),
      .o_trap_no_csr(trap_no_csr),
      .o_dbg_cause(trap_dbg_cause),
      .o_dret_taken(dret_taken),
      .o_dbg_go_taken(dbg_go_taken),
      .o_dbg_park_entry(dbg_park_entry),
      .o_dbg_park_exception(dbg_park_exception),
      .o_stall_for_wfi()  // WFI stall handled at ROB head
  );

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && !$isunknown(
            {translation_csr_commit_shadow, fence_class_quiesce, csr_commit_fire,
             rob_commit.valid, rob_commit.is_csr, rob_commit.csr_addr, trap_taken, xret_taken}
        )) begin
      p_translation_shadow_owns_csr_write :
      assert (!translation_csr_commit_shadow ||
              (csr_commit_fire && rob_commit.valid && rob_commit.is_csr));
      p_translation_shadow_owns_translation_csr :
      assert (!translation_csr_commit_shadow ||
              (rob_commit.csr_addr == riscv_pkg::CsrSatp) ||
              (rob_commit.csr_addr == riscv_pkg::CsrMstatus) ||
              (rob_commit.csr_addr == riscv_pkg::CsrSstatus));
      p_fence_class_quiesce_blocks_control_take :
      assert (!fence_class_quiesce || !(trap_taken || xret_taken));
      p_csr_write_excludes_control_take : assert (!(csr_commit_fire && (trap_taken || xret_taken)));
    end
  end
`endif

  // Frontend and backend flushes use the same registered trap and xRET
  // pulses, aligned with trap_target_reg and ROB acknowledgment.
  assign flush_for_trap = trap_taken_reg;
  assign flush_for_mret = mret_taken_reg;

  // Acknowledge a trap or xRET to the ROB on the registered recovery pulse.
  // This keeps the head trap metadata stable through the CSR trap-entry
  // update; the commit hold above blocks younger retirement during the delay.
  assign rob_trap_taken_ack = trap_taken_reg;
  // mret_taken_reg is the registered image of xret_taken (pipeline control's
  // i_mret_taken input), so this ack also covers SRET and DRET.
  assign mret_done_ack = mret_taken_reg;

  // Status bits for the hang-triage report (hang_triage in soc_top).
  // Packed as: [5]=xRET, [4]=trap, [3:2]=priv, [1]=mstatus.MIE, [0]=mie.MTIE.
  assign o_debug_irq_status = {
    xret_taken, trap_taken, csr_priv, csr_mstatus_mie_direct, csr_mie[riscv_pkg::MieMtiBit]
  };
  assign o_debug_commit_pc = rob_commit.pc;
  assign o_debug_commit_2_pc = rob_commit_2.pc;
  assign o_debug_commit_valid = {rob_commit_2.valid, rob_commit.valid};

  // ===========================================================================
  // Profiling Counter Aggregation (PERF_COUNTERS build option)
  // ===========================================================================
  generate
    if (PERF_COUNTERS != 0) begin : gen_perf_counters
      perf_counter_aggregator #(
          .PreselectCsrHalf(1'b1)
      ) perf_counter_aggregator_inst (
          .i_clk,
          .i_rst,
          .i_rob_alloc_req(rob_alloc_req),
          .i_dispatch_fire_2(rob_alloc_req_2.alloc_valid),
          .i_if_width_events(if_width_events),
          .i_mem_rs_two_ready_one_issued(perf_mem_rs_two_ready_one_issued),
          .i_cdb_oversubscribed(perf_cdb_oversubscribed),
          .i_dispatch_status(dispatch_status),
          .i_rob_commit_comb(rob_commit_comb),
          .i_flush_pipeline(flush_pipeline),
          .i_post_flush_holdoff_q(post_flush_holdoff_q),
          .i_csr_in_flight(csr_in_flight),
          .i_csr_wb_pending(csr_wb_pending),
          .i_serializing_alloc_fire(serializing_alloc_fire),
          .i_front_end_cf_serialize_stall(front_end_cf_serialize_stall),
          .i_rob_empty(rob_empty),
          .i_disable_branch_prediction_ooo(disable_branch_prediction_ooo),
          .i_disable_branch_prediction(i_disable_branch_prediction),
          .i_prediction_fence_branch(prediction_fence_branch),
          .i_prediction_fence_jal(prediction_fence_jal),
          .i_prediction_fence_indirect(prediction_fence_indirect),
          .i_cache_perf_events(i_cache_perf_events),
          .i_perf_counter_select(perf_counter_select),
          .i_perf_snapshot_capture(perf_snapshot_capture),
          .i_perf_cache_previous_select(perf_cache_previous_select),
          .i_wrapper_perf_counter_data(wrapper_perf_counter_data),
          .o_wrapper_perf_counter_select(wrapper_perf_counter_select),
          .o_perf_counter_data_q(perf_counter_data_q),
          .o_perf_counter_csr_half_q(perf_counter_csr_half_q),
          .o_perf_counter_count(perf_counter_count)
      );
    end else begin : gen_no_perf_counters
      // With counters disabled, mperf CSRs read zero and never trigger a snapshot.
      // Unused event registers are removed except those marked keep.
      assign wrapper_perf_counter_select = '0;
      assign perf_counter_data_q = '0;
      assign perf_counter_csr_half_q = '0;
      assign perf_counter_count = '0;
      logic unused_perf_events;
      assign unused_perf_events = &{
          1'b0, if_width_events, dispatch_status, perf_mem_rs_two_ready_one_issued,
          perf_cdb_oversubscribed,
          i_cache_perf_events, perf_counter_select, perf_snapshot_capture,
          perf_cache_previous_select, wrapper_perf_counter_data, post_flush_holdoff_q,
          csr_in_flight, csr_wb_pending, serializing_alloc_fire, front_end_cf_serialize_stall,
          rob_empty, disable_branch_prediction_ooo, i_disable_branch_prediction,
          prediction_fence_branch, prediction_fence_jal, prediction_fence_indirect
      };
    end
  endgenerate

  // ===========================================================================
  // Reset Done
  // ===========================================================================
  // o_rst_done rises when an 8-bit counter saturates, 255 cycles after reset.
  logic [7:0] rst_counter;
  always_ff @(posedge i_clk) begin
    if (i_rst) rst_counter <= '0;
    else if (!o_rst_done) rst_counter <= rst_counter + 8'd1;
  end
  assign o_rst_done = (rst_counter == 8'hFF);

`ifdef FROST_DEBUG_FETCH_ILA
  // Fetch ILA probes (build.py --debug-ila): marked copies that the debug core
  // samples. Nothing here feeds the design. The low 16 PC bits suffice because
  // the capture triggers on a page offset.
  (* mark_debug = "true" *) logic dbg_ila_ooo_commit_valid;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_ooo_commit_pc;
  (* mark_debug = "true" *) logic dbg_ila_ooo_trap_taken;
  (* mark_debug = "true" *) logic dbg_ila_ooo_mret_taken;
  (* mark_debug = "true" *) logic dbg_ila_ooo_flush_all;
  assign dbg_ila_ooo_commit_valid = dbg_commit_valid;
  assign dbg_ila_ooo_commit_pc = dbg_commit_pc[15:0];
  assign dbg_ila_ooo_trap_taken = trap_taken;
  assign dbg_ila_ooo_mret_taken = mret_taken;
  assign dbg_ila_ooo_flush_all = flush_all;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_ooo_alloc_pc;
  (* mark_debug = "true" *) logic dbg_ila_ooo_alloc_valid;
  (* mark_debug = "true" *) logic dbg_ila_ooo_commit_exc;
  (* mark_debug = "true" *) logic [4:0] dbg_ila_ooo_commit_cause;
  assign dbg_ila_ooo_alloc_pc = rob_alloc_req.pc[15:0];
  assign dbg_ila_ooo_alloc_valid = rob_alloc_req.alloc_valid;
  assign dbg_ila_ooo_commit_exc = rob_commit_comb.exception;
  assign dbg_ila_ooo_commit_cause = rob_commit_comb.exc_cause[4:0];
  // CDB and ROB tags and the ID-to-dispatch fetch-fault flag (id_stage clears
  // it on a flush), to follow a faulting instruction from allocation through
  // its CDB completion to commit.
  localparam int unsigned DbgTagW = $bits(rob_alloc_resp.alloc_tag);
  (* mark_debug = "true" *) logic dbg_ila_ooo_cdb_v;
  (* mark_debug = "true" *) logic dbg_ila_ooo_cdb_exc;
  (* mark_debug = "true" *) logic [DbgTagW-1:0] dbg_ila_ooo_cdb_tag;
  (* mark_debug = "true" *) logic dbg_ila_ooo_cdb2_v;
  (* mark_debug = "true" *) logic dbg_ila_ooo_cdb2_exc;
  (* mark_debug = "true" *) logic [DbgTagW-1:0] dbg_ila_ooo_cdb2_tag;
  (* mark_debug = "true" *) logic [DbgTagW-1:0] dbg_ila_ooo_alloc_tag;
  (* mark_debug = "true" *) logic [DbgTagW-1:0] dbg_ila_ooo_commit_tag;
  (* mark_debug = "true" *) logic dbg_ila_ooo_idex_fetch_fault;
  assign dbg_ila_ooo_cdb_v = cdb_out.valid;
  assign dbg_ila_ooo_cdb_exc = cdb_out.exception;
  assign dbg_ila_ooo_cdb_tag = cdb_out.tag;
  assign dbg_ila_ooo_cdb2_v = cdb_out_2.valid;
  assign dbg_ila_ooo_cdb2_exc = cdb_out_2.exception;
  assign dbg_ila_ooo_cdb2_tag = cdb_out_2.tag;
  assign dbg_ila_ooo_alloc_tag = rob_alloc_resp.alloc_tag;
  assign dbg_ila_ooo_commit_tag = rob_commit_comb.tag;
  assign dbg_ila_ooo_idex_fetch_fault = from_id_to_ex.is_fetch_fault;
`endif

  // ===========================================================================
  // Vector unit (VECTOR): the vtype tracker for dispatch and the unit that
  // takes vector arithmetic at retirement
  // ===========================================================================
  if (VECTOR) begin : gen_vector_unit
    if (DECODED_QUEUE_DEPTH == 0) begin : gen_vector_needs_queue
      initial $fatal(1, "cpu_ooo: VECTOR needs the decoded queue (DECODED_QUEUE_DEPTH > 0)");
    end
    localparam int unsigned VecVmtIdxW = $clog2(riscv_pkg::VmtDepth);
    localparam int unsigned VecSegW = 1 + riscv_pkg::VmtPpnBits + 14;
    logic vec_alloc, vec_eff_valid;
    logic vec_alloc_is_varith, vec_alloc_is_vtox, vec_alloc_is_vmem;
    logic [VecVmtIdxW-1:0] vec_vmt_alloc_idx;
    logic vec_vmt_range_valid, vec_vmt_done_valid;
    logic [VecVmtIdxW-1:0] vec_vmt_range_idx, vec_vmt_done_idx;
    logic [VecSegW-1:0] vec_vmt_range_seg0, vec_vmt_range_seg1;

    assign vec_alloc = rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready;
    assign vec_eff_valid = !from_id_to_ex.is_fetch_fault && !from_id_to_ex.is_illegal_instruction;
    // Vector arithmetic, including FP and cryptographic groups, runs in the engine after it retires;
    // the vector-to-scalar moves (vmv.x.s, vcpop.m, vfirst.m, vfmv.f.s)
    // execute at the ROB head
    assign vec_alloc_is_varith = vec_eff_valid &&
        ((from_id_to_ex.instruction_operation == riscv_pkg::VARITH) ||
         (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_X) ||
         (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_F) ||
         (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_C));
    assign vec_alloc_is_vtox = vec_eff_valid &&
        ((from_id_to_ex.instruction_operation == riscv_pkg::VTOX) ||
         (from_id_to_ex.instruction_operation == riscv_pkg::VTOF));
    assign vec_alloc_is_vmem = vec_eff_valid &&
        ((from_id_to_ex.instruction_operation == riscv_pkg::VLOAD) ||
         (from_id_to_ex.instruction_operation == riscv_pkg::VSTORE));

    logic vec_tracker_valid, vec_arith_ready;
    vec_vtype_tracker #(
        .VLEN(VLEN)
    ) u_vtype_tracker (
        .i_clk                (i_clk),
        .i_rst                (i_rst),
        .i_alloc              (vec_alloc),
        .i_alloc_op           (from_id_to_ex.instruction_operation),
        .i_alloc_imm          (from_id_to_ex.csr_address),
        .i_ckpt_save          (checkpoint_save),
        .i_ckpt_id            (checkpoint_id),
        .i_restore            (checkpoint_restore),
        .i_restore_id         (checkpoint_restore_id),
        .i_flush_all          (flush_all),
        .i_vcfg_in_flight     (vec_vcfg_in_flight),
        .i_arch_vtype         (csr_vec_vtype),
        .i_arch_vstart_nonzero(|csr_vec_vstart),
        .i_arch_reload        (csr_commit_fire),
        .o_vstart_nonzero     (vec_vstart_nonzero),
        .o_vtype              (vec_vtype_spec),
        .o_valid              (vec_tracker_valid)
    );
    // Arithmetic legality of the queue head under the tracked vtype, from
    // registers to a register; vector arithmetic waits one cycle at the
    // head for it
    vec_dispatch_legality #(
        .VLEN(VLEN)
    ) u_dispatch_legality (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_head_valid (decoded_queue_valid),
        .i_head_insn  (32'(from_id_to_ex.instruction)),
        .i_vtype      (vec_vtype_spec),
        .i_vtype_valid(vec_tracker_valid),
        .i_pop        (rob_alloc_req.alloc_valid),
        .i_flush      (flush_pipeline),
        .o_ready      (vec_arith_ready),
        .o_illegal    (vec_arith_illegal),
        .o_restart_ok (vec_restart_ok)
    );
    assign vec_vtype_valid = vec_tracker_valid && vec_arith_ready;
    vec_unit #(
        .VLEN          (VLEN),
        .CACHED_TIER_EN(CACHED_TIER_EN)
    ) u_vec_unit (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_stop),
        .i_alloc(vec_alloc),
        .i_alloc_tag(rob_alloc_resp.alloc_tag),
        .i_alloc_is_varith(vec_alloc_is_varith),
        .i_alloc_is_vtox(vec_alloc_is_vtox),
        .i_alloc_is_vmem(vec_alloc_is_vmem),
        .i_alloc_vmt_idx(vec_vmt_alloc_idx),
        .i_alloc_insn(32'(from_id_to_ex.instruction)),
        .i_alloc_2(rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready),
        .i_alloc_tag_2(rob_alloc_resp_2.alloc_tag),
        .i_commit_valid(rob_commit.valid),
        .i_commit_tag(rob_commit.tag),
        .i_commit_exception(rob_commit.exception),
        .i_commit_value(rob_commit.value[63:0]),
        .i_vl(csr_vec_vl),
        .i_vtype(csr_vec_vtype),
        .i_vstart(csr_vec_vstart),
        .i_vxrm(csr_vec_vxrm),
        .o_vxsat_set(vec_vxsat_set),
        .o_vtox_commit(vec_vtox_commit),
        .i_frm(frm_csr),
        .o_fp_flags_valid(vec_fp_flags_valid),
        .o_fp_flags(vec_fp_flags),
        .i_alloc_is_vfscalar(vec_eff_valid &&
                             (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_F)),
        .i_fp_read_data(ma_extra_fp_read_data),
        .i_head_tag(head_tag),
        .i_rob_empty(rob_empty),
        .i_head_safe              (!flush_all && !commit_recovery_flush_after_head &&
                                   !mispredict_recovery_pending),
        .i_flush_all(flush_all),
        .i_csr_wb_pending(csr_wb_pending),
        .i_sq_committed_empty(sq_committed_empty),
        .i_int_take_armed(int_take_armed),
        .o_rf_read_en(vec_rf_read_en),
        .o_rf_read_addr(vec_rf_read_addr),
        .i_rf_read_data((vec_rf_read_addr == 5'd0) ? '0 : ma_extra_int_read_data),
        .i_translate(csr_translation_active),
        .i_eff_priv_u(csr_mmu_eff_priv_u),
        .i_sum(csr_mmu_sum),
        .i_mxr(csr_mmu_mxr),
        .i_pm_mode(csr_mmu_pm_mode),
        .i_tlb_invalidate(tlb_invalidate),
        .o_walk_req_valid(vec_walk_req_valid),
        .i_walk_req_ready(vec_walk_req_ready),
        .o_walk_vpn(vec_walk_vpn),
        .i_walk_resp_valid(vec_walk_resp_valid),
        .i_walk_resp(walk_resp),
        .o_vmt_range_valid(vec_vmt_range_valid),
        .o_vmt_range_idx(vec_vmt_range_idx),
        .o_vmt_range_seg0(vec_vmt_range_seg0),
        .o_vmt_range_seg1(vec_vmt_range_seg1),
        .o_vmt_done_valid(vec_vmt_done_valid),
        .o_vmt_done_idx(vec_vmt_done_idx),
        .o_lc_req_valid(vec_lc_req_valid),
        .i_lc_req_ready(vec_lc_req_ready),
        .o_lc_req_write(vec_lc_req_write),
        .o_lc_req_addr(vec_lc_req_addr),
        .o_lc_req_data(vec_lc_req_data),
        .o_lc_req_mask(vec_lc_req_mask),
        .o_lc_req_id(vec_lc_req_id),
        .i_lc_resp_valid(i_ma_line_resp_valid && (i_ma_line_resp_id >= 4'd2)),
        .i_lc_resp_id(i_ma_line_resp_id),
        .i_lc_resp_data(i_ma_line_resp_data),
        .i_lc_resp_error(i_ma_line_resp_error),
        .i_unc_port_ready(vec_unc_port_ready),
        .o_unc_req_valid(vec_unc_req_valid),
        .o_unc_req_write(vec_unc_req_write),
        .o_unc_req_addr(vec_unc_req_addr),
        .o_unc_req_size(vec_unc_req_size),
        .o_unc_req_wdata(vec_unc_req_wdata),
        .o_unc_req_wstrb(vec_unc_req_wstrb),
        .i_unc_resp_valid(vec_unc_resp_valid),
        .i_unc_resp_data(vec_unc_resp_data),
        .i_unc_resp_error(vec_unc_resp_error),
        .i_grant(cdb_grant[riscv_pkg::FU_FP_DIV]),
        .o_vtox_complete(vec_vtox_complete),
        .o_varith_commit(vec_varith_commit),
        .o_vstore_commit(vec_vstore_commit),
        .o_vmem_fault_vstart_valid(vec_vmem_fault_vstart_valid),
        .o_vmem_fault_vstart(vec_vmem_fault_vstart),
        .o_vmem_vs_dirty(vec_vmem_vs_dirty),
        .o_vl_trim_valid(vec_vl_trim_valid),
        .o_vl_trim(vec_vl_trim),
        .o_vmem_head_shield(vec_head_shield),
        .o_vmu_fatal(vec_vmu_fatal),
        .o_vmu_fatal_addr(vec_vmu_fatal_addr),
        .o_commit_hold(vec_commit_hold),
        .o_idle(vec_idle)
    );
    // A vector load or store takes a VMT entry when it dispatches (slot 1
    // only), receives its translated page segments at the ROB head before
    // retirement, retires alone on the combinational ROB commit edge, and is
    // freed on VMU completion (or by flush if squashed or faulting).
    vec_vmt u_vmt (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_alloc_valid(vec_alloc && vec_alloc_is_vmem),
        .i_alloc_tag(rob_alloc_resp.alloc_tag),
        .o_full(vec_vmt_full),
        .o_alloc_idx(vec_vmt_alloc_idx),
        .i_commit_valid(rob_commit_comb.valid && !rob_commit_comb.exception),
        // Slot 1 commits the current head. Use that registered tag directly;
        // the commit packet's tag is qualified by the serializer's decision.
        .i_commit_tag(head_tag),
        // Commit-time recovery flushes behind a branch that has already
        // retired, so its tag is not a live instruction: it removes every
        // unretired entry, as in the wrapper's speculative full flush.
        .i_flush_all(flush_all || commit_recovery_flush_after_head),
        .i_flush_en(flush_en && !commit_recovery_flush_after_head),
        .i_flush_tag(flush_tag),
        .i_head_tag(head_tag),
        .i_range_valid(vec_vmt_range_valid),
        .i_range_idx(vec_vmt_range_idx),
        .i_range_seg0(vec_vmt_range_seg0),
        .i_range_seg1(vec_vmt_range_seg1),
        .i_done_valid(vec_vmt_done_valid),
        .i_done_idx(vec_vmt_done_idx),
        .o_view(vec_vmt_view),
        .o_gen(),
        .o_quiet_q(vec_vmem_quiet)
    );
`ifndef SYNTHESIS
    logic vmt_head_retiring, vmt_head_retiring_q;
    always_comb begin
      vmt_head_retiring = 1'b0;
      for (int t = 0; t < riscv_pkg::VmtDepth; t++) begin
        logic [riscv_pkg::VmtEntryBits-1:0] ve;
        ve = vec_vmt_view[riscv_pkg::VmtEntryBits*t+:riscv_pkg::VmtEntryBits];
        if (rob_commit_comb.valid && !rob_commit_comb.exception &&
            ve[riscv_pkg::VmtEntryBits-1] && !ve[riscv_pkg::VmtEntryBits-2] &&
            (ve[riscv_pkg::VmtEntryBits-3-:riscv_pkg::ReorderBufferTagWidth] ==
             rob_commit_comb.tag)) begin
          vmt_head_retiring = 1'b1;
        end
      end
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) vmt_head_retiring_q <= 1'b0;
      else vmt_head_retiring_q <= vmt_head_retiring;
      if (reset_seen_q && !i_rst) begin
        if (rob_commit_comb.valid) p_vmt_commit_head_tag : assert (rob_commit_comb.tag == head_tag);
        if (vmt_head_retiring) begin
          p_vmem_no_trap_cancelled_retire : assert (!trap_taken && !xret_taken && !flush_all);
          p_vmem_retires_alone : assert (!rob_commit_comb_2.valid);
        end
        // The VMT retires a cycle before the head unit sees the registered
        // commit. A full flush then would mask the commit needed by that unit.
        if (vmt_head_retiring_q) p_vmem_no_flush_after_retire : assert (!flush_all);
        p_vmem_fault_vstart_exclusive :
        assert (!(vec_vmem_fault_vstart_valid &&
                  (csr_commit_fire || vcfg_commit.valid || vec_varith_commit ||
                   vec_vstore_commit)));
        // The flags of committed vector FP elements never meet a CSR
        // write: every CSR access waits for the unit to drain
        p_vec_fp_flags_not_with_csr_write : assert (!(vec_fp_flags_valid && csr_commit_fire));
        p_vtox_commit_exclusive :
        assert (!(vec_vtox_commit &&
                  (csr_commit_fire || vcfg_commit.valid || vec_varith_commit ||
                   vec_vstore_commit || vec_vmem_fault_vstart_valid)));
        // The tracker writes a checkpoint from the allocation's next state
        // and applies a restore only in a cycle without an allocation:
        // bundles dispatch whole, and recovery holds dispatch.
        p_vec_tracker_save_allocates : assert (!checkpoint_save || vec_alloc);
        p_vec_tracker_restore_without_allocation : assert (!(checkpoint_restore && vec_alloc));
        // Dispatch takes the registered legality: it belongs to the
        // allocating instruction under the vtype in effect.
        if (vec_alloc && (vec_alloc_is_varith || vec_alloc_is_vtox)) begin
          p_vec_restart_class_current :
          assert (vec_arith_ready && vec_restart_ok == riscv_pkg::vector_restart_ok(
              from_id_to_ex.insn_bits
          ));
        end
        if (vec_alloc && ((from_id_to_ex.instruction_operation == riscv_pkg::VARITH) ||
                          (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_X) ||
                          (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_F) ||
                          (from_id_to_ex.instruction_operation == riscv_pkg::VARITH_C) ||
                          (from_id_to_ex.instruction_operation == riscv_pkg::VTOF))) begin
          p_vec_arith_alloc_ready : assert (vec_arith_ready && vec_tracker_valid);
          p_vec_arith_legality_registered :
          assert (vec_arith_illegal == riscv_pkg::vector_arith_illegal(
              vec_vtype_spec, 32'(from_id_to_ex.instruction), VLEN, 0, 0
          ));
        end
      end
    end
    // The tracker's vtype at the allocation of each vector arithmetic
    // instruction (including cryptographic groups and scalar operands) and each
    // vector-to-scalar instruction (vmv.x.s, vcpop.m, vfirst.m, vfmv.f.s), by
    // ROB tag. It must be known and equal the CSR file's vtype when the
    // instruction retires on the registered commit bus, where the unit takes
    // vector arithmetic's vtype. A vector-to-scalar instruction reads vtype at
    // the head, and it cannot change before that instruction retires. (An
    // instruction that traps does not retire.) Every allocation of a tag
    // rewrites its flag, as in the unit, and these instructions never retire
    // in slot 2.
    logic [riscv_pkg::ReorderBufferDepth-1:0] vtype_check_q;
    logic [9:0] vtype_at_alloc_q[riscv_pkg::ReorderBufferDepth];  // {valid, vtype}
    always_ff @(posedge i_clk) begin
      if (vec_alloc)
        vtype_at_alloc_q[rob_alloc_resp.alloc_tag] <= {vec_tracker_valid, vec_vtype_spec};
      if (i_rst) begin
        vtype_check_q <= '0;
      end else begin
        if (vec_alloc)
          vtype_check_q[rob_alloc_resp.alloc_tag] <= vec_alloc_is_varith || vec_alloc_is_vtox;
        if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready)
          vtype_check_q[rob_alloc_resp_2.alloc_tag] <= 1'b0;
      end
      if (reset_seen_q && !i_rst) begin
        if (rob_commit.valid && vtype_check_q[rob_commit.tag])
          p_vec_vtype_prediction_at_commit :
          assert (vtype_at_alloc_q[rob_commit.tag] == {1'b1, csr_vec_vtype});
        if (rob_commit_2.valid)
          p_vec_vtype_checked_in_slot_1 : assert (!vtype_check_q[rob_commit_2.tag]);
      end
    end
`endif
  end else begin : gen_no_vector_unit
    assign vec_vmt_view = '0;
    assign vec_vmem_quiet = 1'b1;
    assign vec_vmt_full = 1'b0;
    assign vec_vtype_spec = '0;
    assign vec_vtype_valid = 1'b1;
    assign vec_arith_illegal = 1'b0;
    assign vec_restart_ok = '0;
    assign vec_varith_commit = 1'b0;
    assign vec_vstore_commit = 1'b0;
    assign vec_vmem_fault_vstart_valid = 1'b0;
    assign vec_vmem_fault_vstart = '0;
    assign vec_vmem_vs_dirty = 1'b0;
    assign vec_vl_trim_valid = 1'b0;
    assign vec_vl_trim = '0;
    assign vec_head_shield = 1'b0;
    assign vec_rf_read_en = 1'b0;
    assign vec_rf_read_addr = '0;
    assign vec_walk_req_valid = 1'b0;
    assign vec_walk_vpn = '0;
    assign vec_lc_req_valid = 1'b0;
    assign vec_lc_req_write = 1'b0;
    assign vec_lc_req_addr = '0;
    assign vec_lc_req_data = '0;
    assign vec_lc_req_mask = '0;
    assign vec_lc_req_id = '0;
    assign vec_unc_req_valid = 1'b0;
    assign vec_unc_req_write = 1'b0;
    assign vec_unc_req_addr = '0;
    assign vec_unc_req_size = riscv_pkg::MEM_SIZE_BYTE;
    assign vec_unc_req_wdata = '0;
    assign vec_unc_req_wstrb = '0;
    assign vec_vmu_fatal = 1'b0;
    assign vec_vmu_fatal_addr = '0;
    assign vec_commit_hold = 1'b0;
    assign vec_idle = 1'b1;
    assign vec_vstart_nonzero = 1'b0;
    assign vec_vxsat_set = 1'b0;
    assign vec_fp_flags_valid = 1'b0;
    assign vec_fp_flags = '0;
    assign vec_vtox_commit = 1'b0;
    assign vec_vtox_complete = '0;
    logic unused_no_vec;
    assign unused_no_vec = &{1'b0, vec_walk_req_ready, vec_walk_resp_valid, vec_lc_req_ready};
  end

endmodule : cpu_ooo
