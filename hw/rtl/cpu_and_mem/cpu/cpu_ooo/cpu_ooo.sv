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

module cpu_ooo #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    // MMIO register window, by default the PMA's (riscv_pkg).
    parameter int unsigned MMIO_ADDR = riscv_pkg::MmioWindowAddr,
    parameter int unsigned MMIO_SIZE_BYTES = riscv_pkg::MmioWindowBytes,
    // Cached tier: loads and stores to [CACHED_BASE, CACHED_BASE +
    // CACHED_SIZE_BYTES) go to the cache hierarchy and complete by handshake,
    // with variable latency. Low-BRAM data accesses take one cycle.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    // Profiling counters: perf_counter_aggregator, the wrapper's
    // tomasulo_perf_counters and the CSR file's mperf* state. 0 = absent (the
    // mperf* CSRs read zero and the event sources are unread); the production
    // build leaves them out, analysis builds set the board top's generic.
    parameter int unsigned PERF_COUNTERS = 0
) (
    input logic i_clk,
    input logic i_rst,
    // Instruction memory interface. o_pc is the virtual fetch address (the
    // providers tag and match windows by it); the o_fetch_* results below are
    // its physical side (see if_stage / mmu/immu).
    output logic [XLEN-1:0] o_pc,
    output logic [31:0] o_fetch_pa0,  // PA of the window's word 0
    output logic [31:0] o_fetch_pa1,  // PA of the window's aligned successor word
    output logic o_fetch_pa_valid,  // always with translation off; Sv39: o_pc's result is visible
    output logic o_fetch_fault0,  // word 0 unfetchable (deliver a fault-tagged window)
    output logic o_fetch_fault0_page,  // ...page fault (else access fault)
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_fetch_line_after_ok,  // the line after word 0's line is physically next
    output logic o_fetch_redirect,  // registered: retarget the low-BRAM presenter's stale request
    output logic o_fetch_cached_retarget,  // registered: redirect or FENCE-class flush
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
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
    // Separate register holding the same provider select as i_served_high. It
    // steers only the PC-metadata and served-window selects, off the fanout of
    // the register that drives the window valid.
    input logic i_instr_pc_metadata_served_high,
    input logic i_instr_bank_sel_r,  // Fetch-word parity (for spanning select)
    // Word tags (address bits [31:2]) that each provider registers beside its
    // window, with the next and previous word, for IF's served-window check.
    // IF compares against both providers in parallel and selects the results.
    input logic [29:0] i_served_word_low,
    input logic [29:0] i_served_last_word_low,
    input logic [29:0] i_served_prev_word_low,
    input logic i_served_prev_word_valid_low,
    input logic [29:0] i_served_word_high,
    input logic [29:0] i_served_last_word_high,
    input logic [29:0] i_served_prev_word_high,
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
    // Page-table walker line port: read-only master to the
    // hierarchy's wup port (cpu_and_mem wires it through). 2-bit local ids
    // per the fabric's id tree; the walker issues one walk at a time.
    output logic o_walk_line_req_valid,
    input logic i_walk_line_req_ready,
    output logic [31:0] o_walk_line_req_addr,
    output logic [1:0] o_walk_line_req_id,
    input logic i_walk_line_resp_valid,
    input logic [1:0] i_walk_line_resp_id,
    input logic [255:0] i_walk_line_resp_rdata,
    // Data memory interface
    input logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    // BRAM-only byte write enables: o_data_mem_per_byte_wr_en with MMIO and
    // cached-tier writes masked by their registered tier flags, so no
    // address-range compare sits on the BRAM write-enable path. Peripherals
    // use the unmasked o_data_mem_per_byte_wr_en, so MMIO writes stay visible
    // to the UART/FIFO/timer logic.
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    output logic o_data_mem_read_enable,
    // Cached tier (high-address region). Tier-routed write/read requests
    // (already qualified by is_cached in the router) plus the handshake
    // completion inputs from the cached_tier_adapter.
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    // Cached-tier write data: SQ drain data, or an AMO's new value in the one
    // cycle a cached AMO write launches to the adapter. The router muxes the
    // two on this cached-only path, away from the wide BRAM write-data mux,
    // and the AMO ALU reaches it only through a cached AMO, which runs at the
    // ROB head.
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic o_data_mem_cached_read_enable,
    // Slot id of a cached read (several may be in flight); the adapter tags
    // its responses with it and holds a response while a fast-tier response
    // is using the LQ response port.
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id,
    input logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id,
    input logic i_cached_read_valid,
    output logic o_cached_read_ready,
    input logic i_cached_write_done,
    input logic i_cached_write_inflight,
    // DMA coherence handshake: the cache hierarchy's sequencer to
    // the load queue's coherence port inside tomasulo_wrapper.
    input logic i_coh_admit_valid,
    input logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_admit_slot,
    input logic [XLEN-1:0] i_coh_admit_addr,
    output logic o_coh_admit_ready,
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
    // PLIC S-context external-interrupt line. csr_file ORs it into the SEIP
    // readback and the S-pending exports.
    input logic i_plic_seip,
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
  // hold; the flush is flush_pipeline from misprediction_flush_controller.

  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  logic dispatch_stall;
  logic direct_id_valid_preflush, direct_id_valid_2_preflush;
  logic direct_id_valid, direct_id_valid_2;
  logic decoded_queue_full;
  logic decoded_queue_indirect_pending;
  (* max_fanout = 32 *) logic flush_pipeline;
  logic dispatch_flush;
  logic full_flush_side_effect_kill;
  logic flush_for_trap;
  logic flush_for_mret;
  riscv_pkg::dispatch_status_t dispatch_status;

  // Top-level perf-counter interface. The counters and aggregation logic live
  // in perf_counter_aggregator; these signals cross its boundary: selector and
  // snapshot pulse from the CSR file, wrapper counter data from the
  // tomasulo_wrapper, and the muxed result/count back to the CSR read port.
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
  (* max_fanout = 32 *) logic serializing_alloc_fire;
  logic csr_commit_fire;  // driven by commit_actions below
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
      .i_frontend_resource_stall(decoded_queue_full),
      .i_csr_wb_pending(csr_wb_pending),
      .i_branch_resolved_correct(branch_resolved_correct),
      .i_branch_resolved_checkpoint_id(branch_resolved_checkpoint_id),
      .i_front_end_indirect_control_flow_pending(
          front_end_indirect_control_flow_pending || decoded_queue_indirect_pending),
      .i_disable_branch_prediction(i_disable_branch_prediction),
      .i_flush_pipeline(flush_pipeline),
      .i_fetch_pa_hold(fetch_pa_hold),
      .o_pipeline_ctrl(pipeline_ctrl),
      .o_serializing_alloc_fire(serializing_alloc_fire),
      .o_csr_in_flight(csr_in_flight),
      .o_disable_branch_prediction_ooo(disable_branch_prediction_ooo),
      .o_front_end_cf_serialize_stall(front_end_cf_serialize_stall),
      .o_stall_q(stall_q),
      .o_id_stall_q(id_stall_q),
      .o_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .o_replay_after_serialize_stall_q(replay_after_serialize_stall_q),
      .o_post_flush_holdoff_q(post_flush_holdoff_q),
      .o_trap_taken_reg(trap_taken_reg),
      .o_mret_taken_reg(mret_taken_reg),
      .o_trap_target_reg(trap_target_reg)
  );

  // ===========================================================================
  // Inter-stage signals
  // ===========================================================================
  // Fetch translation state from csr_file (combinational), and the
  // instruction MMU's walker port, muxed onto the shared ptw with the data
  // MMU's port (declared with the CSR wiring below).
  logic csr_fetch_translation_active, csr_fetch_priv_u;
  logic fetch_pa_hold;  // if_stage: no visible result for the selected fetch VA yet
  logic iwalk_req_valid, iwalk_req_ready;
  logic [riscv_pkg::Sv39VpnBits-1:0] iwalk_vpn;
  logic iwalk_resp_valid;
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_pd_to_id_t from_pd_to_id;
  logic pd_redirect;
  logic [XLEN-1:0] pd_redirect_target;
  riscv_pkg::from_id_to_ex_t from_id_to_ex;
  riscv_pkg::from_id_to_ex_t decoded_packet, decoded_packet_2;
  // The ID instruction registers' next-edge values (queued frontend only).
  /* verilator lint_off UNUSEDSIGNAL */
  riscv_pkg::from_id_to_ex_t decoded_packet_next, decoded_packet_next_2;
  /* verilator lint_on UNUSEDSIGNAL */

  // Slot-2 inter-stage signals (2-wide dispatch). from_if_to_pd_2 carries
  // IF's second instruction whenever the pairing rules allow one (see "Two-wide
  // fetch and dispatch" in the CPU README), with sel_nop=1 when there is none
  // this cycle. PD and ID pass it to dispatch, which fires slot 2 only
  // together with slot 1; slot-2 renamed sources use done-repair channels
  // 4/5/6 for a missed CDB broadcast.
  riscv_pkg::from_if_to_pd_t from_if_to_pd_2;
  riscv_pkg::from_pd_to_id_t from_pd_to_id_2;
  riscv_pkg::from_id_to_ex_t from_id_to_ex_2;

  // Debug mirrors that the cocotb tests read.
  logic dbg_if_ras_predicted  /* verilator public_flat_rd */;
  logic dbg_pd_ras_predicted  /* verilator public_flat_rd */;
  logic dbg_id_ras_predicted  /* verilator public_flat_rd */;
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

  assign dbg_if_ras_predicted = from_if_to_pd.ras_predicted;
  assign dbg_pd_ras_predicted = from_pd_to_id.ras_predicted;
  assign dbg_id_ras_predicted = from_id_to_ex.ras_predicted;
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
    end else if (fmul_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fmul_rs_dispatch;
    end else if (fdiv_rs_dispatch.valid) begin
      split_rs_dispatch_dbg = fdiv_rs_dispatch;
    end
  end

  assign dbg_rs_dispatch_valid = split_rs_dispatch_dbg.valid;
  assign dbg_rs_dispatch_pc = split_rs_dispatch_dbg.pc;
  assign dbg_rs_dispatch_rob_tag = split_rs_dispatch_dbg.rob_tag;
  assign dbg_rs_dispatch_src1_ready = split_rs_dispatch_dbg.src1_ready;
  assign dbg_rs_dispatch_src1_tag = split_rs_dispatch_dbg.src1_tag;
  assign dbg_rs_dispatch_src2_ready = split_rs_dispatch_dbg.src2_ready;
  assign dbg_rs_dispatch_src2_tag = split_rs_dispatch_dbg.src2_tag;
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

  // Synthesized from_ex_comb for IF stage (branch redirect, BTB update, RAS restore)
  riscv_pkg::from_ex_comb_t            from_ex_comb_synth;
  logic                     [XLEN-1:0] btb_late_update_pc;
  logic                                btb_late_update_taken;

  // Trap control
  riscv_pkg::trap_ctrl_t               trap_ctrl;
  logic trap_taken, mret_taken;
  logic sret_taken;  // SRET pulse from the trap unit (rides the MRET machinery)
  logic trap_to_s;  // Trap targets S (delegated): steers csr_file's entry side
  // Any xRET (MRET, SRET, or DRET). Pipeline control, recovery, and the ROB
  // acknowledge treat the three alike; csr_file, the resume-PC seed, and the
  // debug logic use the separate pulses.
  logic xret_taken;
  logic [XLEN-1:0] trap_target;

  assign trap_ctrl.trap_taken  = trap_taken_reg;
  assign trap_ctrl.mret_taken  = mret_taken_reg;
  assign trap_ctrl.trap_target = trap_target_reg;

  // ===========================================================================
  // Stage 1: Instruction Fetch (IF)
  // ===========================================================================

  // 2-wide width-funnel profiling events (IF→PD boundary → perf counters).
  riscv_pkg::if_width_events_t if_width_events;

  if_stage #(
      .XLEN(XLEN)
  ) if_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_instr,
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
      .i_fetch_translation_active(csr_fetch_translation_active),
      .i_fetch_priv_u(csr_fetch_priv_u),
      .i_tlb_invalidate(tlb_invalidate),
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
      .i_frontend_state_flush(frontend_state_flush),
      .i_flush_all(flush_all),
      .i_fence_i_flush(fence_i_flush),
      .i_fence_i_target(fence_i_target_pc),
      .i_disable_branch_prediction(disable_branch_prediction_ooo),
      // Bimodal direction-predictor training (conditional branches only, see
      // dir_update_* below).
      .i_dir_update_valid(dir_update_valid),
      .i_dir_update_idx(dir_update_idx),
      .i_dir_update_taken(dir_update_taken),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_target(pd_redirect_target),
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd),
      .o_from_if_to_pd_2(from_if_to_pd_2),
      .o_slot1_has_control_flow(if_slot1_has_control_flow),
      .o_width_events(if_width_events)
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
      .o_pd_redirect(pd_redirect),
      .o_pd_redirect_target(pd_redirect_target)
  );

  // ===========================================================================
  // Register Files (read at dispatch, write from ROB commit)
  // ===========================================================================

  // Both architectural register files (integer + FP) and the widen-commit
  // write-back bypass live in ooo_register_files. Write ports come from ROB
  // commit (port 0 = slot 1, port 1 = slot 2); read addresses come from the
  // dispatch source fields of both bundle slots. The resolved (post-bypass)
  // read results feed dispatch and the RAT.

  // FP data width, also used below by the commit-side write-port packing.
  localparam int unsigned FpW = riscv_pkg::FpWidth;

  logic [XLEN-1:0] int_rf_dispatch_rs1_data;
  logic [XLEN-1:0] int_rf_dispatch_rs2_data;
  logic [XLEN-1:0] int_rf_dispatch_rs1_data_2;
  logic [XLEN-1:0] int_rf_dispatch_rs2_data_2;
  logic [ FpW-1:0] fp_rf_dispatch_rs1_data;
  logic [ FpW-1:0] fp_rf_dispatch_rs2_data;
  logic [ FpW-1:0] fp_rf_dispatch_rs3_data;
  logic [ FpW-1:0] fp_rf_dispatch_rs1_data_2;
  logic [ FpW-1:0] fp_rf_dispatch_rs2_data_2;
  logic [ FpW-1:0] fp_rf_dispatch_rs3_data_2;

  // Registered write enables and addresses for the register-file bypass,
  // computed below after commit_actions.
  logic            bypass_p0_int_we_q;
  logic            bypass_p1_int_we_q;
  logic            bypass_p0_fp_we_q;
  logic            bypass_p1_fp_we_q;
  logic [     4:0] bypass_p0_addr_q;
  logic [     4:0] bypass_p1_addr_q;

  ooo_register_files #(
      .XLEN(XLEN)
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
      .o_int_rf_dispatch_rs1_data  (int_rf_dispatch_rs1_data),
      .o_int_rf_dispatch_rs2_data  (int_rf_dispatch_rs2_data),
      .o_int_rf_dispatch_rs1_data_2(int_rf_dispatch_rs1_data_2),
      .o_int_rf_dispatch_rs2_data_2(int_rf_dispatch_rs2_data_2),
      .o_fp_rf_dispatch_rs1_data  (fp_rf_dispatch_rs1_data),
      .o_fp_rf_dispatch_rs2_data  (fp_rf_dispatch_rs2_data),
      .o_fp_rf_dispatch_rs3_data  (fp_rf_dispatch_rs3_data),
      .o_fp_rf_dispatch_rs1_data_2(fp_rf_dispatch_rs1_data_2),
      .o_fp_rf_dispatch_rs2_data_2(fp_rf_dispatch_rs2_data_2),
      .o_fp_rf_dispatch_rs3_data_2(fp_rf_dispatch_rs3_data_2)
  );

  // ===========================================================================
  // Stage 3: Instruction Decode (ID)
  // ===========================================================================

  // mstatus.FS == Off from csr_file. ID decodes every F/D instruction as
  // illegal while it is set; the ROB's allocation check reads it too.
  logic csr_mstatus_fs_off;
  // TIMING: ID reads a registered copy, so the route from csr_file stays off
  // the ID class-register and decoded-queue shadow D paths. The copy differs
  // from the CSR only in the cycle FS enters or leaves Off, and that cycle
  // carries the full flush, which discards everything ID decodes then
  // (p_fs_off_change_flushes_decode below).
  logic id_mstatus_fs_off_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) id_mstatus_fs_off_q <= 1'b0;
    else id_mstatus_fs_off_q <= csr_mstatus_fs_off;
  end

  id_stage #(
      .XLEN(XLEN)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_target(pd_redirect_target),
      .i_mstatus_fs_off(id_mstatus_fs_off_q),
      .o_from_id_to_ex(decoded_packet),
      .o_from_id_to_ex_next(decoded_packet_next),
      // Slot 2 (2-wide dispatch). i_from_pd_to_id_2 carries the second
      // instruction plus its inject_nop bubble marker, which ID applies before
      // producing o_from_id_to_ex_2.
      .i_from_pd_to_id_2(from_pd_to_id_2),
      .o_from_id_to_ex_2(decoded_packet_2),
      .o_from_id_to_ex_next_2(decoded_packet_next_2)
  );

  // ===========================================================================
  // Instruction Validity (pipeline valid tracking)
  // ===========================================================================
  // frontend_validity_tracker marks which IF/PD/ID packets are real
  // instructions. Its if_valid_q/pd_valid_q chain follows IF's sel_nop and the
  // one-cycle post-flush holdoff, so the NOP bubbles after a flush or reset
  // are never dispatched. Dispatch takes the preflush candidates and applies
  // the recovery kill itself (its i_flush); id_valid and id_valid_2 are
  // flush-qualified copies for debug and assertions.
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
  // Duplicate registers of step_armed_q for its two wide consumers, the front
  // end's keep-NOPs term and the ROB's commit-width gate. They load the same
  // next state and are kept from merging so placement can put each next to
  // its consumer.
  (* keep = "true", equivalent_register_removal = "no" *)logic step_armed_fe_q;
  (* keep = "true", equivalent_register_removal = "no" *)logic step_armed_rob_q;

  frontend_validity_tracker frontend_validity_tracker_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .i_if_has_control_flow(if_slot1_has_control_flow),
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(decoded_packet),
      .i_from_id_to_ex_2(decoded_packet_2),
      .i_post_flush_holdoff_q(post_flush_holdoff_q),
      .i_dispatch_flush(dispatch_flush),
      .i_id_stall_q(id_stall_q),
      .i_replay_after_dispatch_stall_q(replay_after_dispatch_stall_q),
      .i_flush_pipeline(flush_pipeline),
      .i_keep_nops(step_armed_fe_q),
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
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl, producer_ctrl_2;
      riscv_pkg::id_dispatch_ctrl_t producer_ctrl_next, producer_ctrl_next_2;
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
        producer_ctrl.ras_predicted = decoded_packet.ras_predicted;
        producer_ctrl.is_ras_return = decoded_packet.is_ras_return;
        producer_ctrl.is_ras_call = decoded_packet.is_ras_call;
        producer_ctrl.btb_correct_non_jalr = decoded_packet.btb_correct_non_jalr;
        producer_ctrl.ras_correct_non_jalr = decoded_packet.ras_correct_non_jalr;
        producer_ctrl.has_int_dest = decoded_packet.has_int_dest;
        producer_ctrl.has_fp_dest = decoded_packet.has_fp_dest;
        producer_ctrl.uses_int_rs1 = decoded_packet.uses_int_rs1;
        producer_ctrl.uses_int_rs2 = decoded_packet.uses_int_rs2;
        producer_ctrl.uses_fp_rs1 = decoded_packet.uses_fp_rs1;
        producer_ctrl.uses_fp_rs2 = decoded_packet.uses_fp_rs2;
        producer_ctrl.uses_fp_rs3 = decoded_packet.uses_fp_rs3;
        producer_ctrl.is_not_nop = decoded_packet.is_not_nop;
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
        producer_ctrl_2.ras_predicted = decoded_packet_2.ras_predicted;
        producer_ctrl_2.is_ras_return = decoded_packet_2.is_ras_return;
        producer_ctrl_2.is_ras_call = decoded_packet_2.is_ras_call;
        producer_ctrl_2.btb_correct_non_jalr = decoded_packet_2.btb_correct_non_jalr;
        producer_ctrl_2.ras_correct_non_jalr = decoded_packet_2.ras_correct_non_jalr;
        producer_ctrl_2.has_int_dest = decoded_packet_2.has_int_dest;
        producer_ctrl_2.has_fp_dest = decoded_packet_2.has_fp_dest;
        producer_ctrl_2.uses_int_rs1 = decoded_packet_2.uses_int_rs1;
        producer_ctrl_2.uses_int_rs2 = decoded_packet_2.uses_int_rs2;
        producer_ctrl_2.uses_fp_rs1 = decoded_packet_2.uses_fp_rs1;
        producer_ctrl_2.uses_fp_rs2 = decoded_packet_2.uses_fp_rs2;
        producer_ctrl_2.uses_fp_rs3 = decoded_packet_2.uses_fp_rs3;
        producer_ctrl_2.is_not_nop = decoded_packet_2.is_not_nop;
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
        producer_ctrl_next.ras_predicted = decoded_packet_next.ras_predicted;
        producer_ctrl_next.is_ras_return = decoded_packet_next.is_ras_return;
        producer_ctrl_next.is_ras_call = decoded_packet_next.is_ras_call;
        producer_ctrl_next.btb_correct_non_jalr = decoded_packet_next.btb_correct_non_jalr;
        producer_ctrl_next.ras_correct_non_jalr = decoded_packet_next.ras_correct_non_jalr;
        producer_ctrl_next.has_int_dest = decoded_packet_next.has_int_dest;
        producer_ctrl_next.has_fp_dest = decoded_packet_next.has_fp_dest;
        producer_ctrl_next.uses_int_rs1 = decoded_packet_next.uses_int_rs1;
        producer_ctrl_next.uses_int_rs2 = decoded_packet_next.uses_int_rs2;
        producer_ctrl_next.uses_fp_rs1 = decoded_packet_next.uses_fp_rs1;
        producer_ctrl_next.uses_fp_rs2 = decoded_packet_next.uses_fp_rs2;
        producer_ctrl_next.uses_fp_rs3 = decoded_packet_next.uses_fp_rs3;
        producer_ctrl_next.is_not_nop = decoded_packet_next.is_not_nop;
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
        producer_ctrl_next_2.ras_predicted = decoded_packet_next_2.ras_predicted;
        producer_ctrl_next_2.is_ras_return = decoded_packet_next_2.is_ras_return;
        producer_ctrl_next_2.is_ras_call = decoded_packet_next_2.is_ras_call;
        producer_ctrl_next_2.btb_correct_non_jalr = decoded_packet_next_2.btb_correct_non_jalr;
        producer_ctrl_next_2.ras_correct_non_jalr = decoded_packet_next_2.ras_correct_non_jalr;
        producer_ctrl_next_2.has_int_dest = decoded_packet_next_2.has_int_dest;
        producer_ctrl_next_2.has_fp_dest = decoded_packet_next_2.has_fp_dest;
        producer_ctrl_next_2.uses_int_rs1 = decoded_packet_next_2.uses_int_rs1;
        producer_ctrl_next_2.uses_int_rs2 = decoded_packet_next_2.uses_int_rs2;
        producer_ctrl_next_2.uses_fp_rs1 = decoded_packet_next_2.uses_fp_rs1;
        producer_ctrl_next_2.uses_fp_rs2 = decoded_packet_next_2.uses_fp_rs2;
        producer_ctrl_next_2.uses_fp_rs3 = decoded_packet_next_2.uses_fp_rs3;
        producer_ctrl_next_2.is_not_nop = decoded_packet_next_2.is_not_nop;
      end
      // An unpredicted JALR in either slot. While it is queued it counts as
      // pending for the control-flow serialization stall.
      assign input_indirect =
          (decoded_packet.is_jump_and_link_register &&
           !(decoded_packet.ras_predicted || decoded_packet.btb_predicted_taken)) ||
          (decoded_packet_2.is_not_nop && decoded_packet_2.is_jump_and_link_register &&
           !(decoded_packet_2.ras_predicted || decoded_packet_2.btb_predicted_taken));
      decoded_bundle_queue #(
          .DEPTH(DECODED_QUEUE_DEPTH),
          .WIDTH(2 * $bits(decoded_packet)),
          .SHADOW_WIDTH(2 * $bits(producer_ctrl))
      ) u_queue (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_flush(flush_pipeline),
          .i_advance(!pipeline_ctrl.stall),
          .i_valid(pd_valid_q &&
              (decoded_packet.is_not_nop || decoded_packet_2.is_not_nop || step_armed_fe_q)),
          .i_packet({decoded_packet_2, decoded_packet}),
          .i_shadow({producer_ctrl_2, producer_ctrl}),
          .i_shadow_next({producer_ctrl_next_2, producer_ctrl_next}),
          .i_indirect(input_indirect),
          .i_pop(rob_alloc_req.alloc_valid),
          .o_full(decoded_queue_full),
          .o_valid(queue_valid),
          .o_packet({queue_packet_2, queue_packet}),
          .o_shadow({queue_ctrl_2, queue_ctrl}),
          .o_indirect_pending(decoded_queue_indirect_pending)
      );
      // TIMING: every narrow control field (the RS route, the operation and
      // classification flags that gate dispatch_fire, and the instruction
      // word whose register fields address the RAT and register files) comes
      // from the queue's registered shadow, which equals the same queue_packet
      // fields. Only the wide payload keeps the bypass select.
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
        from_id_to_ex.ras_predicted = queue_ctrl.ras_predicted;
        from_id_to_ex.is_ras_return = queue_ctrl.is_ras_return;
        from_id_to_ex.is_ras_call = queue_ctrl.is_ras_call;
        from_id_to_ex.btb_correct_non_jalr = queue_ctrl.btb_correct_non_jalr;
        from_id_to_ex.ras_correct_non_jalr = queue_ctrl.ras_correct_non_jalr;
        from_id_to_ex.has_int_dest = queue_ctrl.has_int_dest;
        from_id_to_ex.has_fp_dest = queue_ctrl.has_fp_dest;
        from_id_to_ex.uses_int_rs1 = queue_ctrl.uses_int_rs1;
        from_id_to_ex.uses_int_rs2 = queue_ctrl.uses_int_rs2;
        from_id_to_ex.uses_fp_rs1 = queue_ctrl.uses_fp_rs1;
        from_id_to_ex.uses_fp_rs2 = queue_ctrl.uses_fp_rs2;
        from_id_to_ex.uses_fp_rs3 = queue_ctrl.uses_fp_rs3;
        from_id_to_ex.is_not_nop = queue_ctrl.is_not_nop;
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
        from_id_to_ex_2.ras_predicted = queue_ctrl_2.ras_predicted;
        from_id_to_ex_2.is_ras_return = queue_ctrl_2.is_ras_return;
        from_id_to_ex_2.is_ras_call = queue_ctrl_2.is_ras_call;
        from_id_to_ex_2.btb_correct_non_jalr = queue_ctrl_2.btb_correct_non_jalr;
        from_id_to_ex_2.ras_correct_non_jalr = queue_ctrl_2.ras_correct_non_jalr;
        from_id_to_ex_2.has_int_dest = queue_ctrl_2.has_int_dest;
        from_id_to_ex_2.has_fp_dest = queue_ctrl_2.has_fp_dest;
        from_id_to_ex_2.uses_int_rs1 = queue_ctrl_2.uses_int_rs1;
        from_id_to_ex_2.uses_int_rs2 = queue_ctrl_2.uses_int_rs2;
        from_id_to_ex_2.uses_fp_rs1 = queue_ctrl_2.uses_fp_rs1;
        from_id_to_ex_2.uses_fp_rs2 = queue_ctrl_2.uses_fp_rs2;
        from_id_to_ex_2.uses_fp_rs3 = queue_ctrl_2.uses_fp_rs3;
        from_id_to_ex_2.is_not_nop = queue_ctrl_2.is_not_nop;
      end
      assign id_valid_preflush = queue_valid &&
          !(csr_in_flight || csr_wb_pending || serializing_alloc_fire);
      assign id_valid_2_preflush = id_valid_preflush && from_id_to_ex_2.is_not_nop;
      assign id_valid = id_valid_preflush && !dispatch_flush;
      assign id_valid_2 = id_valid_2_preflush && !dispatch_flush;
`ifndef SYNTHESIS
      always_ff @(posedge i_clk) begin
        if (!i_rst) begin
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
      assert property (@(posedge i_clk) disable iff (i_rst || flush_pipeline)
          pipeline_ctrl.stall |=> $stable(
          {decoded_packet, decoded_packet_2, pd_valid_q}
      ));
`endif
`endif
    end else begin : gen_no_decoded_queue
      assign decoded_queue_full = 1'b0;
      assign decoded_queue_indirect_pending = 1'b0;
      assign from_id_to_ex = decoded_packet;
      assign from_id_to_ex_2 = decoded_packet_2;
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
  riscv_pkg::reorder_buffer_alloc_req_t  rob_alloc_req;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp;
  assign dbg_rob_alloc_valid = rob_alloc_req.alloc_valid;
  assign dbg_rob_alloc_pc = rob_alloc_req.pc;
  assign dbg_rob_alloc_is_csr = rob_alloc_req.is_csr;
  assign dbg_rob_alloc_is_mret = rob_alloc_req.is_mret;
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb;  // combinational from ROB
  riscv_pkg::reorder_buffer_commit_t rob_commit;  // registered: drives CSR/regfile/bypass
  logic rob_commit_valid;
  logic rob_commit_valid_raw;

  // Commit slot 2, valid when the ROB retires a second instruction
  // (commit_2_fire). Slots 1 and 2 write the register files in the same cycle
  // through separate ports, so slot 2 needs no back-pressure and
  // widen_commit_ok is tied high; single step still uses the ROB's gate to
  // force one-wide commit (see i_widen_commit_ok below).
  riscv_pkg::reorder_buffer_commit_t rob_commit_comb_2;
  riscv_pkg::reorder_buffer_commit_t rob_commit_2;
  logic rob_commit_2_valid_raw;
  logic rob_commit_2_valid;
  assign rob_commit_2_valid = rob_commit_2.valid;
  logic sq_committed_empty_for_trap;
  logic widen_commit_ok;
  assign widen_commit_ok = 1'b1;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_epoch;

  // Per-ROB-entry predict-time bimodal index for the direction predictor.  Written
  // at ROB allocation (mirroring rob_entry_epoch) and read at commit to train the
  // exact bimodal entry the branch's prediction read.  No reset: only entries
  // allocated for a committing conditional branch are ever used.
  logic [riscv_pkg::BpDirIdxBits-1:0] branch_dir_idx_table[riscv_pkg::ReorderBufferDepth];

  // RAT lookup - slot 1
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr, int_src2_addr;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr, fp_src2_addr, fp_src3_addr;
  riscv_pkg::rat_lookup_t int_src1_lookup, int_src2_lookup;
  riscv_pkg::rat_lookup_t fp_src1_lookup, fp_src2_lookup, fp_src3_lookup;

  // RAT lookup - slot 2 (2-wide dispatch). The integer lookups feed slot-2
  // rename in dispatch; the FP lookups feed dispatch's slot-2 source muxes,
  // where rs2 supplies FP-store data while src1/src3 only matter for
  // FP-compute ops, which the bundle rules keep out of slot 2. The lint
  // waiver below covers the struct fields dispatch doesn't read.
  logic [riscv_pkg::RegAddrWidth-1:0] int_src1_addr_2, int_src2_addr_2;
  logic [riscv_pkg::RegAddrWidth-1:0] fp_src1_addr_2, fp_src2_addr_2, fp_src3_addr_2;
  /* verilator lint_off UNUSEDSIGNAL */
  riscv_pkg::rat_lookup_t int_src1_lookup_2, int_src2_lookup_2;
  riscv_pkg::rat_lookup_t fp_src1_lookup_2, fp_src2_lookup_2, fp_src3_lookup_2;
  /* verilator lint_on UNUSEDSIGNAL */

  // RAT rename - slot 1
  logic                                        rat_alloc_valid_raw;
  logic                                        rat_alloc_valid;
  logic                                        rat_alloc_dest_rf;
  logic [         riscv_pkg::RegAddrWidth-1:0] rat_alloc_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rat_alloc_rob_tag;

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

  // Record each allocated entry's predict-time bimodal index, keyed by ROB tag,
  // using the same alloc signals as rob_entry_epoch. Each slot stores its own
  // predict index, since slot-1 and slot-2 looked up different PCs.
  always_ff @(posedge i_clk) begin
    if (rob_alloc_req.alloc_valid && rob_alloc_resp.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp.alloc_tag] <= from_id_to_ex.bp_dir_idx;
    end
    if (rob_alloc_req_2.alloc_valid && rob_alloc_resp_2.alloc_ready) begin
      branch_dir_idx_table[rob_alloc_resp_2.alloc_tag] <= from_id_to_ex_2.bp_dir_idx;
    end
  end

  // ===========================================================================
  // Direction Predictor Commit-Time Training (bimodal)
  // ===========================================================================
  // Train the bimodal predictor at commit, conditional branches only (the
  // ROB's is_branch also covers JAL and JALR; rob_head_dir_train_early
  // excludes them). A correctly predicted branch can also retire in slot 2;
  // its training shares the single update port through a one-deep hold that
  // drains on a cycle when slot 1 does not train (lossy under sustained
  // contention, like the BTB correct-branch channel). The training index is
  // the branch's predict-time bimodal index, read from branch_dir_idx_table
  // at the committing tag, so training updates the exact entry the
  // prediction read.
  logic                               dir_update_valid_comb;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_comb;
  logic                               dir_update_taken_comb;
  // TIMING: the conditional-branch class and taken direction come from the
  // ROB's early field pre-decodes ANDed with the 1-bit raw fire, not from the
  // combinational commit structs, which would put the whole field mux behind
  // the late commit gate. They equal the struct fields whenever the raw fire
  // is high and are don't-cares otherwise, because the predictor writes only
  // under i_update_valid.
  assign dir_update_valid_comb = rob_commit_valid_raw && rob_head_dir_train_early;
  // TIMING: address branch_dir_idx_table with the ungated registered head tag
  // rather than rob_commit_comb.tag (= commit_en ? head_idx : '0). When the
  // read value matters (dir_update_valid_comb=1), commit_en=1, so
  // tag==head_idx==head_tag; when commit_en=0, dir_update_idx is a don't-care
  // because direction_predictor writes both BIM RAMs only under
  // i_update_valid. This keeps commit_en off the LUTRAM read address. Slot 2
  // reads head_tag+1 == commit_2's head_next_idx by the same argument.
  wire [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag_p1 = head_tag + 1'b1;
  assign dir_update_idx_comb   = branch_dir_idx_table[head_tag];
  assign dir_update_taken_comb = rob_head_branch_taken_early;

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

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dir_update_held_valid <= 1'b0;
    end else if (dir_update_valid_2_comb && !dir_slot2_pass) begin
      dir_update_held_valid <= 1'b1;
      dir_update_held_idx   <= dir_update_idx_2_comb;
      dir_update_held_taken <= rob_head_next_branch_taken_early;
    end else if (dir_update_held_valid && !dir_update_valid_comb) begin
      dir_update_held_valid <= 1'b0;
    end
  end

  // TIMING: precompute the non-slot-1 fallback so the update-index register
  // mux is a single 2:1 selected by dir_update_valid_comb, without the
  // dir_slot2_pass priority level. Equivalent to the priority form:
  // dir_slot2_pass implies !held_valid, where the fallback is idx2; with
  // held_valid the fallback is held_idx; and !held_valid without
  // dir_slot2_pass means no slot-2 training, so dir_update_valid is 0 and the
  // index is a don't-care.
  wire [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx_fallback =
      dir_update_held_valid ? dir_update_held_idx : dir_update_idx_2_comb;

  // Register the predictor update before it enters IF. This removes the
  // ROB-head/serializer path from the distributed-RAM read-modify-write timing
  // arc; training is still in commit order, one cycle later.
  logic dir_update_valid;
  logic [riscv_pkg::BpDirIdxBits-1:0] dir_update_idx;
  logic dir_update_taken;
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

  // RS dispatch
  riscv_pkg::rs_dispatch_t int_rs_dispatch;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch;
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch;
  riscv_pkg::rs_dispatch_t split_rs_dispatch_dbg;

  // Slot-2 RS dispatch packets (2-wide dispatch, back-end side).
  // Driven by dispatch and consumed by the wrapper.  A packet's valid asserts
  // when slot-2 fires and routes to that RS family.
  riscv_pkg::rs_dispatch_t int_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch_2;
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch_2;

  // Slot-2 ROB allocation request + response.
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2_raw;
  riscv_pkg::reorder_buffer_alloc_req_t rob_alloc_req_2;
  riscv_pkg::reorder_buffer_alloc_resp_t rob_alloc_resp_2;

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
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_branch_tag;
  logic [riscv_pkg::RasPtrBits-1:0] dispatch_ras_tos;
  logic [riscv_pkg::RasPtrBits:0] dispatch_ras_valid_count;
  logic rob_checkpoint_valid_raw;
  logic rob_checkpoint_valid;
  logic [riscv_pkg::CheckpointIdWidth-1:0] rob_checkpoint_id;

  assign checkpoint_save = checkpoint_save_raw && !full_flush_side_effect_kill;
  assign checkpoint_save_for_slot2 = checkpoint_save_for_slot2_raw && !full_flush_side_effect_kill;
  assign rob_checkpoint_valid = rob_checkpoint_valid_raw && !full_flush_side_effect_kill;

  // Resource status
  logic rob_full, rob_empty;
  logic int_rs_full, mul_rs_full, mem_rs_full;
  logic fp_rs_full, fmul_rs_full, fdiv_rs_full;
  logic lq_full, sq_full;

  // Slot-2 "room for 2" status from the wrapper.  Used by dispatch to gate
  // slot-2 fire when slot-1 is also targeting the same structure.
  logic rob_full_for_2;
  logic int_rs_full_for_2, mul_rs_full_for_2, mem_rs_full_for_2;
  logic fp_rs_full_for_2, fmul_rs_full_for_2, fdiv_rs_full_for_2;
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
  logic flush_all;
  logic commit_recovery_flush_after_head;
  // The flush that clears the LQ: a full flush, or commit-time recovery,
  // which the LQ also treats as a full flush. The router must cancel a held,
  // unaccepted request on the same flush, because the LQ then expects no
  // response for it.
  logic lq_router_flush_all;
  (* max_fanout = 32 *) logic mispredict_recovery_pending;
  riscv_pkg::mispredict_commit_capture_t mispredict_commit_q;
  logic frontend_state_flush;

  // CDB
  riscv_pkg::cdb_broadcast_t cdb_out;
  riscv_pkg::cdb_broadcast_t cdb_out_2;
  logic [riscv_pkg::NumFus-1:0] cdb_grant;

  // ROB status
  logic [riscv_pkg::ReorderBufferTagWidth:0] rob_count;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  logic head_valid, head_done;
  logic fence_i_flush;
  logic fence_class_flush_event;
  logic translation_csr_commit_shadow;
  // Quiet window for the trap unit (its i_pipeline_stall, below): a
  // translation CSR's write cycle and every FENCE-class flush cycle. Built
  // only from registers, so the takes it blocks cannot feed back into it.
  logic fence_class_quiesce;
  assign fence_class_quiesce = translation_csr_commit_shadow || fence_i_flush;
  assign o_fence_i_flush = fence_i_flush;
  logic [XLEN-1:0] fence_i_target_pc;

  // CSR coordination
  logic csr_start, csr_done_ack;
  logic trap_pending;
  logic trap_mret_commit_hold_q;
  logic [XLEN-1:0] rob_trap_pc;
  logic rob_head_is_wfi;  // ROB head decodes as WFI (drives the WFI interrupt-resume-PC seed)
  logic rob_head_is_amo;  // ROB head decodes as AMO (drives the trap unit's AMO interrupt shield)
  // Register-bypass and direction-training field pre-decodes from the ROB
  // (early head/head+1 field conjunctions; see the reorder_buffer ports).
  logic rob_head_bypass_int_we_early;
  logic rob_head_bypass_fp_we_early;
  logic rob_head_next_bypass_int_we_early;
  logic rob_head_next_bypass_fp_we_early;
  logic rob_head_dir_train_early;
  logic rob_head_branch_taken_early;
  logic rob_head_next_dir_train_early;
  logic rob_head_next_branch_taken_early;
  // AMO interrupt shield (see trap_unit.i_amo_at_head): registered image of
  // "a valid AMO occupies the ROB head", off the take_trap timing cone. The
  // 1-cycle lag is covered by the AMO's >=3-cycle head-to-write-launch delay.
  logic amo_at_head_shield_q;
  // Device-read interrupt shield (see trap_unit.i_device_read_at_head): a
  // registered image of "the data-memory router holds a device-quadrant
  // request", extended to the load's commit. Its only functional consumer is
  // the trap unit; the router derives the same "held for a full cycle" fact
  // from its own device_request_pending_q rather than taking this bit back as
  // an input, so no feedback net runs back into the router.
  logic device_read_shield_q;
  // Retired-next-PC precompute from the ROB, for timing: equals
  // retired_next_pc(rob_commit_comb) / (rob_commit_comb_2) whenever the
  // corresponding commit valid is high, but computed from ungated head fields
  // so the RAM read + adder are off the late commit_en cone.
  logic [XLEN-1:0] rob_head_retired_next_pc;
  logic [XLEN-1:0] rob_head_next_retired_next_pc;
  riscv_pkg::exc_cause_t rob_trap_cause;
  riscv_pkg::exc_cause_t rob_trap_cause_remapped;
  logic [1:0] csr_priv;  // current privilege from csr_file (PrivM/PrivS/PrivU)
  logic [2:0] csr_mcounteren;  // mcounteren CY/TM/IR from csr_file (S/U-mode counter gate)
  // Arbitrated trap cause from trap_unit (an interrupt cause with bit XLEN-1
  // set, or the remapped synchronous-exception cause) -> csr_file's xcause.
  // Declared here so it is visible above the trap_unit instantiation that
  // drives it.
  logic [XLEN-1:0] trap_cause_internal;
  logic [XLEN-1:0] rob_trap_value;
  logic rob_trap_taken_ack;
  logic mret_start, mret_done_ack;
  logic [XLEN-1:0] mepc_value;
  logic interrupt_pending;

  // Memory interfaces
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] sq_mem_write_data;
  logic [riscv_pkg::MemStrbBits-1:0] sq_mem_write_byte_en;
  logic sq_mem_write_is_mmio;
  // Registered cached-tier flag for the SQ write (parallels is_mmio). Used by
  // the router to steer the store's byte-write enables to the cached tier and
  // mask them off the BRAM, keeping the late address-range test off the BRAM
  // WEA cone.
  logic sq_mem_write_is_cached;
  logic sq_mem_write_done;

  logic lq_mem_read_en;
  logic lq_mem_addr_valid;
  logic [XLEN-1:0] lq_mem_read_addr;
  riscv_pkg::mem_size_e lq_mem_read_size;
  logic [riscv_pkg::MemDataBits-1:0] lq_mem_read_data;
  logic lq_mem_read_valid;
  logic lq_mem_read_is_cached;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_read_id;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_read_launch_id;
  logic lq_mem_request_valid;
  logic cached_read_held;
  logic lq_device_request_pending;

  // AMO memory interface
  logic amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] amo_mem_write_data;
  logic amo_mem_write_is_dword;
  logic amo_mem_write_is_cached;
  logic amo_mem_write_done;
  // Router-derived |o_data_mem_bram_byte_wr_en for the debug store mirror.
  logic data_mem_bram_write_any;

  // RS issue. Exposed but not externally driven: the FU shims are inside the wrapper.
  riscv_pkg::rs_issue_t rs_issue_int, rs_issue_mul, rs_issue_mem;
  riscv_pkg::rs_issue_t rs_issue_fp, rs_issue_fmul, rs_issue_fdiv;
  // Duplicate register of rs_issue_int.rob_tag, loaded on the same edge and
  // used only by the branch-resolution predicates; branch_update.tag and
  // every ROB, recovery, and FU consumer use rs_issue_int.rob_tag itself.
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rs_issue_int_branch_predicate_tag;

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

  // Checkpoint free (from commit or flush-time reclaim)
  logic checkpoint_free;
  logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_free_id;

  // Track checkpoint → ROB tag mapping for flush-time reclaim.
  // When a partial flush fires, checkpoints belonging to younger-than-flush-tag
  // branches must be freed to prevent checkpoint slot exhaustion.
  // Packed 2D (not unpacked) so it can cross module ports to branch_resolution /
  // misprediction_flush_controller (yosys read_verilog -sv rejects unpacked-array
  // ports).
  logic [riscv_pkg::NumCheckpoints-1:0][riscv_pkg::ReorderBufferTagWidth-1:0] checkpoint_owner_tag;
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_in_use;

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

  // Owner tags update only on a save. Record checkpoint_branch_tag, not
  // rob_alloc_resp.alloc_tag, so a slot-2 branch stores its own ROB tag rather
  // than slot 1's. Otherwise the owner checks in branch_resolution and in the
  // flush controller's correct-branch checkpoint free fail for slot-2
  // branches, suppressing branch resolution and deadlocking the ROB head.
  always_ff @(posedge i_clk) begin
    if (rob_checkpoint_valid) checkpoint_owner_tag[rob_checkpoint_id] <= checkpoint_branch_tag;
  end

  // Flush-time checkpoint reclaim: free checkpoints owned by flushed entries.
  // Compute which checkpoints are younger than flush_tag (combinational).
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

  tomasulo_wrapper #(
      .SPLIT_RS_DISPATCH(1'b1),
      .ENABLE_DISPATCH_DONE_REPAIR(1'b1),
      .PERF_COUNTERS(PERF_COUNTERS),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) u_tomasulo (
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
      .i_fu_complete_6('0),
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
      .i_sret_illegal(csr_sret_illegal),
      .i_sfence_illegal(csr_sfence_illegal),
      .i_wfi_illegal(csr_wfi_illegal),
      .i_priv_is_u(csr_priv_is_u),
      .i_debug_mode(csr_debug_mode),
      // mcounteren CY/TM/IR for the S/U counter-CSR illegal check
      .i_mcounteren(csr_mcounteren),
      // mstatus.FS == Off, sampled for FP legality at ROB allocation
      .i_mstatus_fs_off(csr_mstatus_fs_off),

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
      .i_commit_hold(csr_commit_fire || trap_mret_commit_hold_q || mispredict_recovery_pending),

      // ROB external coordination
      .o_csr_start(csr_start),
      .i_csr_done(csr_done_ack),
      .o_trap_pending(trap_pending),
      .o_trap_pc(rob_trap_pc),
      .o_head_is_wfi(rob_head_is_wfi),
      .o_head_is_amo(rob_head_is_amo),
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
      .i_interrupt_pending(interrupt_pending || csr_debug_mode || step_armed_q),
      .i_trap_misaligned_accesses(csr_mtvec_traps_misaligned),

      // Flush
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_flush_all(flush_all),
      .i_flush_after_head_commit(commit_recovery_flush_after_head),
      .i_backend_recovery_hold(early_backend_recovery_hold),
      .i_slow_write_inflight(i_cached_write_inflight),
      .i_coh_admit_valid(i_coh_admit_valid),
      .i_coh_admit_slot(i_coh_admit_slot),
      .i_coh_admit_addr(i_coh_admit_addr),
      .o_coh_admit_ready(o_coh_admit_ready),
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
      .i_fence_i_sync_done(i_fence_i_sync_done),
      .o_fence_i_sync_req(o_fence_i_sync_req),
      .i_translation_active(csr_translation_active),
      .i_mmu_sum(csr_mmu_sum),
      .i_mmu_mxr(csr_mmu_mxr),
      .i_mmu_eff_priv_u(csr_mmu_eff_priv_u),
      .i_csr_translation_flush_req(csr_translation_flush_req),
      .o_tlb_invalidate(tlb_invalidate),
      .o_walk_req_valid(walk_req_valid),
      .i_walk_req_ready(walk_req_ready),
      .o_walk_vpn(walk_vpn),
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

      // RAT source lookups - slot 1
      .i_int_src1_addr(int_src1_addr),
      .i_int_src2_addr(int_src2_addr),
      .o_int_src1(int_src1_lookup),
      .o_int_src2(int_src2_lookup),
      .i_fp_src1_addr(fp_src1_addr),
      .i_fp_src2_addr(fp_src2_addr),
      .i_fp_src3_addr(fp_src3_addr),
      .o_fp_src1(fp_src1_lookup),
      .o_fp_src2(fp_src2_lookup),
      .o_fp_src3(fp_src3_lookup),

      // RAT source lookups - slot 2 (2-wide dispatch)
      .i_int_src1_addr_2(int_src1_addr_2),
      .i_int_src2_addr_2(int_src2_addr_2),
      .o_int_src1_2(int_src1_lookup_2),
      .o_int_src2_2(int_src2_lookup_2),
      .i_fp_src1_addr_2(fp_src1_addr_2),
      .i_fp_src2_addr_2(fp_src2_addr_2),
      .i_fp_src3_addr_2(fp_src3_addr_2),
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
      .i_checkpoint_save_for_slot2(checkpoint_save_for_slot2),

      // RAT checkpoint restore
      .i_checkpoint_restore(checkpoint_restore),
      .i_checkpoint_restore_id(checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(checkpoint_restore_reclaim_all),
      .i_checkpoint_flush_free_mask(checkpoint_flush_free_mask),
      .o_ras_tos(restored_ras_tos),
      .o_ras_valid_count(restored_ras_valid_count),

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
      .i_fmul_rs_dispatch(fmul_rs_dispatch),
      .i_fdiv_rs_dispatch(fdiv_rs_dispatch),
      // Slot-2 RS dispatch, driven by the dispatch unit. The wrapper
      // forwards what dispatch produces; valids assert when slot-2 fires.
      .i_int_rs_dispatch_2(int_rs_dispatch_2),
      .i_mul_rs_dispatch_2(mul_rs_dispatch_2),
      .i_mem_rs_dispatch_2(mem_rs_dispatch_2),
      .i_fp_rs_dispatch_2(fp_rs_dispatch_2),
      .i_fmul_rs_dispatch_2(fmul_rs_dispatch_2),
      .i_fdiv_rs_dispatch_2(fdiv_rs_dispatch_2),
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

      // FMUL_RS
      .o_fmul_rs_issue(rs_issue_fmul),
      .i_fmul_rs_fu_ready(1'b1),
      .o_fmul_rs_full(fmul_rs_full),
      .o_fmul_rs_full_for_2(fmul_rs_full_for_2),
      .o_fmul_rs_empty(),
      .o_fmul_rs_count(),

      // FDIV_RS
      .o_fdiv_rs_issue(rs_issue_fdiv),
      .i_fdiv_rs_fu_ready(1'b1),
      .o_fdiv_rs_full(fdiv_rs_full),
      .o_fdiv_rs_full_for_2(fdiv_rs_full_for_2),
      .o_fdiv_rs_empty(),
      .o_fdiv_rs_count(),

      // Store queue memory interface
      .o_sq_mem_write_en(sq_mem_write_en),
      .o_sq_mem_write_addr(sq_mem_write_addr),
      .o_sq_mem_write_data(sq_mem_write_data),
      .o_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .o_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .o_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_sq_mem_write_done(sq_mem_write_done),

      // Load queue memory interface
      .o_lq_mem_read_en(lq_mem_read_en),
      .o_lq_mem_addr_valid(lq_mem_addr_valid),
      .o_lq_mem_read_addr(lq_mem_read_addr),
      .o_lq_mem_read_size(lq_mem_read_size),
      .o_lq_mem_read_id(lq_mem_read_launch_id),
      .i_lq_mem_read_data(lq_mem_read_data),
      .i_lq_mem_read_valid(lq_mem_read_valid),
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
    // trap_drain_wait: a trap or xRET is waiting for committed stores to
    // drain (see trap_unit). Hold commit so the wait is bounded.
    else
      trap_mret_commit_hold_q <= trap_pending || mret_start || trap_drain_wait ||
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
      (rob_commit_valid_raw || xret_taken || (trap_taken && !trap_to_d && !trap_no_csr));
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      step_armed_q     <= 1'b0;
      step_armed_fe_q  <= 1'b0;
      step_armed_rob_q <= 1'b0;
      step_done_q      <= 1'b0;
    end else if (trap_taken && trap_to_d) begin
      step_armed_q     <= 1'b0;
      step_armed_fe_q  <= 1'b0;
      step_armed_rob_q <= 1'b0;
      step_done_q      <= 1'b0;
    end else begin
      if (dret_taken && csr_dcsr_step) begin
        step_armed_q     <= 1'b1;
        step_armed_fe_q  <= 1'b1;
        step_armed_rob_q <= 1'b1;
      end
      if (step_done_set) step_done_q <= 1'b1;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      assert (step_armed_fe_q == step_armed_q && step_armed_rob_q == step_armed_q)
      else $error("step_armed_q twins diverged");
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
  // Low-BRAM store snoop for the debug module's instruction-copy mirror.
  // TIMING: the any-byte flag feeds the mirror's slice-writer FIFO write
  // enable, so it comes from the router, built from its arbitration terms;
  // OR-reducing the eight strobes here would lengthen the amo_state -> FIFO
  // path.
  assign o_dbg_bram_store = data_mem_bram_write_any;
  assign o_dbg_bram_store_addr = o_data_mem_addr[31:0];
  assign o_dbg_bram_store_strb = o_data_mem_bram_byte_wr_en;

  // ===========================================================================
  // Dispatch Unit
  // ===========================================================================

  dispatch #(
      .SLOT2_VALID_FROM_BUNDLE(DECODED_QUEUE_DEPTH > 0)
  ) u_dispatch (
      .i_clk,
      .i_rst_n(rst_n),

      .i_from_id_to_ex(from_id_to_ex),
      // Preflush candidate: dispatch applies the recovery kill itself,
      // through i_flush below.
      .i_valid(id_valid_preflush),

      // Slot 2 (2-wide dispatch). Its preflush candidate is high when the
      // bundle is a candidate and slot 2 holds a non-NOP instruction; i_flush
      // suppresses both slots together during recovery.
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
      .o_fmul_rs_dispatch(fmul_rs_dispatch),
      .o_fdiv_rs_dispatch(fdiv_rs_dispatch),

      // Slot-2 RS dispatch (2-wide dispatch). At most one packet has .valid=1
      // per cycle: the RS family slot-2 routes to when it fires.
      .o_int_rs_dispatch_2 (int_rs_dispatch_2),
      .o_mul_rs_dispatch_2 (mul_rs_dispatch_2),
      .o_mem_rs_dispatch_2 (mem_rs_dispatch_2),
      .o_fp_rs_dispatch_2  (fp_rs_dispatch_2),
      .o_fmul_rs_dispatch_2(fmul_rs_dispatch_2),
      .o_fdiv_rs_dispatch_2(fdiv_rs_dispatch_2),

      // Checkpoint management
      .i_checkpoint_available(checkpoint_available),
      .i_checkpoint_alloc_id(checkpoint_alloc_id),
      .o_checkpoint_save(checkpoint_save_raw),
      .o_checkpoint_save_for_slot2(checkpoint_save_for_slot2_raw),
      .o_checkpoint_id(checkpoint_id),
      .o_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(from_if_to_pd.ras_checkpoint_tos),
      .i_ras_valid_count(from_if_to_pd.ras_checkpoint_valid_count),
      .o_ras_tos(dispatch_ras_tos),
      .o_ras_valid_count(dispatch_ras_valid_count),
      .o_rob_checkpoint_valid(rob_checkpoint_valid_raw),
      .o_rob_checkpoint_id(rob_checkpoint_id),

      // Resource status
      .i_rob_full(rob_full),
      .i_int_rs_full(int_rs_full),
      .i_mul_rs_full(mul_rs_full),
      .i_mem_rs_full(mem_rs_full),
      .i_fp_rs_full(fp_rs_full),
      .i_fmul_rs_full(fmul_rs_full),
      .i_fdiv_rs_full(fdiv_rs_full),
      .i_lq_full(lq_full),
      .i_sq_full(sq_full),

      // Slot-2 "room for 2" status from the wrapper.
      .i_rob_full_for_2(rob_full_for_2),
      .i_int_rs_full_for_2(int_rs_full_for_2),
      .i_mul_rs_full_for_2(mul_rs_full_for_2),
      .i_mem_rs_full_for_2(mem_rs_full_for_2),
      .i_fp_rs_full_for_2(fp_rs_full_for_2),
      .i_fmul_rs_full_for_2(fmul_rs_full_for_2),
      .i_fdiv_rs_full_for_2(fdiv_rs_full_for_2),
      .i_lq_full_for_2(lq_full_for_2),
      .i_sq_full_for_2(sq_full_for_2),

      // Flush / early-recovery hold
      .i_flush(dispatch_flush),
      .i_hold (early_backend_recovery_hold),

      // Dispatch profiling status
      .o_status(dispatch_status),

      // Stall output
      .o_stall(dispatch_stall)
  );

  // ===========================================================================
  // Branch Resolution Unit
  // ===========================================================================
  // Conditional branches and JALRs issue from INT_RS and resolve in
  // branch_resolution, which drives the ROB's branch_update. A conditional
  // branch never writes the CDB (the INT RS predecodes its writeback hint
  // clear); a JALR writes its link through the ALU shim. A same-edge tag twin
  // drives only the checkpoint-owner and recovery-age predicates inside that
  // block.
  logic            is_jalr_issue;
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;
  // Every branch holds a checkpoint, so this is the resolving branch's own.
  assign branch_resolved_checkpoint_id = rs_issue_int.checkpoint_id;

  branch_resolution #(
      .XLEN(XLEN)
  ) branch_resolution_inst (
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
  // Router/LQ one-entry hold contract. The router's write_port_busy terms are
  // a subset of the LQ's i_mem_bus_busy input, so a read handoff never meets a
  // busy write port and the router's write-conflict hold goes unused in this
  // core. Every device read uses the hold for at least one cycle, and the
  // router's registered pending bit feeds back into the LQ's bus-busy input,
  // so no second handoff can arrive before the router accepts. A full flush
  // in that window cancels the held request before it has any read effect.
  // An accepted MMIO read returns a fixed one cycle later.
  //
  // One-cycle histories for the device-read shield checks below (Verilator
  // does not accept $past outside an assertion context).
  logic device_request_pending_q;
  logic router_flush_all_q;
  always @(posedge i_clk) begin
    device_request_pending_q <= !i_rst && lq_device_request_pending;
    router_flush_all_q <= !i_rst && lq_router_flush_all;
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight))
        $error("cpu_ooo: LQ read handoff overlapped router write_port_busy");
      if (lq_mem_request_valid && lq_mem_read_en)
        $error("cpu_ooo: LQ read handoff overlapped held router request");
      // A full flush already on its way (trap, xRET, FENCE-class) may overlap
      // the held request's staging cycle; that is where the router cancels
      // it. Commit-time recovery is in the router's flush only to match the
      // LQ's full-flush condition. It never overlaps a held request, because
      // a commit-time recovery cannot overtake an older device read at the
      // ROB head.
      if (lq_mem_request_valid && commit_recovery_flush_after_head)
        $error("cpu_ooo: commit recovery overlapped a held LQ router request");
      if (lq_mem_request_valid && lq_router_flush_all &&
          (o_data_mem_read_enable || o_data_mem_cached_read_enable ||
           o_mmio_read_pulse || o_mmio_load_valid))
        $error("cpu_ooo: owner flush did not suppress held LQ read effects");
      // Once sq_committed_empty is high, no older SQ or cached store can
      // still hold the write port, and device reads launch only at the ROB
      // head, so no AMO can be writing either.
      if (lq_mem_request_valid && sq_committed_empty &&
          (sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight))
        $error("cpu_ooo: drained held LQ request remained write-blocked");
      // Device-read interrupt shield (trap_unit.i_device_read_at_head): the
      // device read must never happen before the shield is up.
      if (o_mmio_read_pulse && !device_read_shield_q)
        $error("cpu_ooo: MMIO read pulse fired without the device interrupt shield");
      // The hold must not lapse while the request is still parked. The first
      // pending cycle is exempt: that cycle is what raises the shield, and
      // the router cannot arm until the cycle after it is visible.
      if (lq_device_request_pending && device_request_pending_q && !device_read_shield_q &&
          !lq_router_flush_all && !router_flush_all_q)
        $error("cpu_ooo: device request pending without the interrupt shield");
      // An interrupt must never be taken inside the shielded window.
      // (trap_pending is the trap unit's exception input; exceptions stay
      // ungated by both shields, so only an interrupt take is a violation.)
      if (device_read_shield_q && trap_taken && !trap_pending)
        $error("cpu_ooo: interrupt taken inside the device-read shield window");
    end
  end

  // Device-read shield forward-progress watchdog. While the shield defers an
  // interrupt, commit is not held (neither o_trap_drain_wait term is set), so
  // the load commits and the shield drops. A shield stuck high means that
  // argument is broken; report it here as a hang rather than letting the test
  // time out.
  localparam int unsigned DeviceShieldWatchdogCycles = 4096;
  int unsigned device_shield_stuck_cnt;
  always @(posedge i_clk) begin
    if (i_rst || !device_read_shield_q) begin
      device_shield_stuck_cnt <= 0;
    end else begin
      device_shield_stuck_cnt <= device_shield_stuck_cnt + 1;
      if (device_shield_stuck_cnt == DeviceShieldWatchdogCycles)
        $error(
            "cpu_ooo: device-read interrupt shield held for %0d cycles (forward progress lost)",
            DeviceShieldWatchdogCycles
        );
    end
  end
`endif
`endif

  // ===========================================================================
  // Early Misprediction Recovery
  // ===========================================================================
  // A mispredicted conditional branch that holds a checkpoint starts recovery
  // as soon as it resolves, unless another recovery or flush is in progress,
  // instead of at commit (JAL and JALR mispredictions recover at commit):
  //   Cycle N:   branch_update reports the misprediction; capture its data
  //   Cycle N+1: early_mispredict_active: redirect fetch, restore the RAT,
  //              hold dispatch and issue (early_backend_recovery_hold)
  //   Cycle N+2: early_backend_recovery_pending: back-end partial flush

  logic                                        early_mispredict_active;
  logic                                        early_mispredict_pending;
  logic                                        early_backend_recovery_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_backend_flush_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_mispredict_tag;
  logic [                            XLEN-1:0] early_mispredict_redirect_pc;
  logic [    riscv_pkg::CheckpointIdWidth-1:0] early_mispredict_checkpoint_id;
  logic                                        early_mispredict_is_compressed;
  logic [                            XLEN-1:0] early_mispredict_pc;
  logic [                            XLEN-1:0] early_mispredict_branch_target;
  logic                                        early_mispredict_branch_taken;
  logic                                        early_recovery_en;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_recovery_tag;
  logic                                        early_backend_recovery_hold;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic                                        early_recovery_trap_taken_reg;
  (* keep = "true", dont_touch = "true", max_fanout = 16 *)
  logic                                        early_recovery_mret_taken_reg;

  // Local copies of the registered trap and xRET pulses, equal cycle for
  // cycle to trap_taken_reg and mret_taken_reg in ooo_pipeline_control. Those
  // also drive IF and the global flush; these low-fanout copies feed only
  // early_misprediction_recovery's kill terms.
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
      .i_branch_update(branch_update),
      .i_rs_issue_int(rs_issue_int),
      .i_is_jalr_issue(is_jalr_issue),
      .i_branch_taken_resolved(branch_taken_resolved),
      .i_branch_target_resolved(branch_target_resolved),
      .i_fence_i_flush(fence_i_flush),
      // rob_commit.is_fence_i serves as a low-fanout copy of fence_i_flush's
      // native part for the active pulse's late kill gate: for a FENCE.I or
      // SFENCE.VMA, commit_bus_pipeline registers it from the same retiring
      // predicate. A translation-CSR recovery raises fence_i_flush without
      // it; tomasulo_wrapper formally checks that is_fence_i implies
      // fence_i_flush.
      .i_active_fence_i_flush(rob_commit.is_fence_i),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_flush_all(flush_all),
      .i_flush_for_trap(early_recovery_trap_taken_reg),
      .i_flush_for_mret(early_recovery_mret_taken_reg),
      .i_trap_taken_reg(early_recovery_trap_taken_reg),
      .i_mret_taken_reg(early_recovery_mret_taken_reg),
      .o_early_mispredict_active(early_mispredict_active),
      .o_early_mispredict_pending(early_mispredict_pending),
      .o_early_backend_recovery_pending(early_backend_recovery_pending),
      .o_early_backend_flush_tag(early_backend_flush_tag),
      .o_early_mispredict_tag(early_mispredict_tag),
      .o_early_mispredict_redirect_pc(early_mispredict_redirect_pc),
      .o_early_mispredict_checkpoint_id(early_mispredict_checkpoint_id),
      .o_early_mispredict_is_compressed(early_mispredict_is_compressed),
      .o_early_mispredict_pc(early_mispredict_pc),
      .o_early_mispredict_branch_target(early_mispredict_branch_target),
      .o_early_mispredict_branch_taken(early_mispredict_branch_taken),
      .o_early_recovery_en(early_recovery_en),
      .o_early_recovery_tag(early_recovery_tag),
      .o_early_backend_recovery_hold(early_backend_recovery_hold)
  );

  // ===========================================================================
  // Commit-Time Actions
  // ===========================================================================

  // Regfile write ports (driven by commit_actions, consumed by
  // ooo_register_files), CSR serialization handshakes, and retire status.
  logic            port0_int_we;
  logic [     4:0] port0_int_addr;
  logic [XLEN-1:0] port0_int_data;
  logic            port0_fp_we;
  logic [     4:0] port0_fp_addr;
  logic [ FpW-1:0] port0_fp_data;
  logic            port1_int_we;
  logic [     4:0] port1_int_addr;
  logic [XLEN-1:0] port1_int_data;
  logic            port1_fp_we;
  logic [     4:0] port1_fp_addr;
  logic [ FpW-1:0] port1_fp_data;
  logic [     1:0] instruction_retired_count;

  commit_actions #(
      .XLEN(XLEN)
  ) commit_actions_inst (
      .i_clk,
      .i_rst,
      .i_rob_commit(rob_commit),
      .i_rob_commit_2(rob_commit_2),
      .i_rob_commit_valid(rob_commit_valid),
      .i_csr_read_data(csr_read_data),
      .i_trap_taken(trap_taken),
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
  // Registered one cycle early from the ROB's combinational commit buses (the
  // values commit_bus_pipeline registers into rob_commit / rob_commit_2) plus
  // the delayed CSR writeback, and cleared by the full flush exactly like
  // commit_bus_q_valid, so the wide hit compares in ooo_register_files start
  // at registers instead of the trap/xRET/FENCE-class flush-mask logic. Each
  // equals its commit_actions write enable (with |dest_reg folded in for the
  // INT file's x0 exclusion) in every cycle except a full-flush cycle, where
  // the bypass may still claim a commit whose architectural write was masked
  // off; the dispatch that could use that hit is squashed by the same flush.
  logic csr_wb_arm;
  assign csr_wb_arm = csr_commit_fire && rob_commit.dest_valid;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) begin
      bypass_p0_int_we_q <= 1'b0;
      bypass_p1_int_we_q <= 1'b0;
      bypass_p0_fp_we_q  <= 1'b0;
      bypass_p1_fp_we_q  <= 1'b0;
    end else begin
      // TIMING: the field conjunctions come from the ROB's early pre-decodes
      // (rob_head*_bypass_*_we_early, equal to the commit-struct fields
      // whenever the raw fire is high; see reorder_buffer), so each D is the
      // 1-bit raw fire ANDed with one early bit. Decoding the combinational
      // commit structs instead would put the whole head/head+1 field mux
      // behind the late commit gate.
      bypass_p0_int_we_q <= (csr_wb_arm && |rob_commit.dest_reg) ||
          (rob_commit_valid_raw && rob_head_bypass_int_we_early);
      bypass_p0_fp_we_q <= rob_commit_valid_raw && rob_head_bypass_fp_we_early;
      bypass_p1_int_we_q <= rob_commit_2_valid_raw && rob_head_next_bypass_int_we_early;
      bypass_p1_fp_we_q <= rob_commit_2_valid_raw && rob_head_next_bypass_fp_we_early;
    end
  end

  // Address payloads: no reset (don't-care while the matching we_q is low).
  // The CSR delayed writeback never overlaps a commit write (asserted in
  // commit_actions), so the csr arm can take priority on port 0.
  always_ff @(posedge i_clk) begin
    bypass_p0_addr_q <= csr_wb_arm ? rob_commit.dest_reg : rob_commit_comb.dest_reg;
    bypass_p1_addr_q <= rob_commit_comb_2.dest_reg;
  end

`ifndef SYNTHESIS
  // The bypass qualifiers must track the architectural write enables
  // cycle-for-cycle outside reset/full-flush cycles.
  always_ff @(posedge i_clk) begin
    if (!i_rst && !flush_all) begin
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
  // The ROB commit bus is registered (commit_bus_pipeline, inside the
  // wrapper), cutting the path from commit_en through the commit bus to the
  // CSR read and the register-file write. Misprediction and branch detection
  // use the narrow raw ROB status bits instead, so flush initiation pays no
  // extra latency and the full commit payload stays off the branch-recovery
  // logic.
  assign rob_commit_valid = rob_commit.valid;

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
  logic [riscv_pkg::NumCheckpoints-1:0] checkpoint_flush_free_mask;
  logic flush_after_head;

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
      .i_early_backend_recovery_pending(early_backend_recovery_pending),
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
  // Commit-time recovery kills dispatch in one place, dispatch's i_flush: the
  // preflush candidates carry no recovery term, and id_valid/id_valid_2 exist
  // for debug and these checks. When recovery ends, its flush has already
  // cleared pd_valid_q (and emptied the decoded queue), so even the preflush
  // candidates are low.
  logic mispredict_recovery_pending_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) mispredict_recovery_pending_seen_q <= 1'b0;
    else mispredict_recovery_pending_seen_q <= mispredict_recovery_pending;
  end

  always_comb begin
    if (!$isunknown(
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
      .i_restored_ras_tos(restored_ras_tos),
      .i_restored_ras_valid_count(restored_ras_valid_count),
      .i_mispredict_recovery_pending(mispredict_recovery_pending),
      .i_mispredict_commit_q(mispredict_commit_q),
      .i_correct_branch_commit_pending(correct_branch_commit_pending),
      .i_correct_branch_commit_q(correct_branch_commit_q),
      .i_correct_branch_commit_pending_2_raw(correct_branch_commit_pending_2_raw),
      .i_correct_branch_commit_q_2(correct_branch_commit_q_2),
      .o_btb_late_update_pc(btb_late_update_pc),
      .o_btb_late_update_taken(btb_late_update_taken),
      .o_from_ex_comb(from_ex_comb_synth)
  );

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
    if (!$isunknown(
            {flush_all, commit_recovery_flush_after_head, flush_en, early_backend_recovery_pending}
        )) begin
      p_lq_partial_flush_identity_when_observable :
      assert (flush_all || commit_recovery_flush_after_head ||
              (early_backend_recovery_pending == flush_en));
    end
  end
`endif

  data_mem_request_router #(
      .XLEN(XLEN),
      .MMIO_ADDR(MMIO_ADDR),
      .MMIO_SIZE_BYTES(MMIO_SIZE_BYTES),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) data_mem_request_router_inst (
      .i_clk,
      .i_rst,
      .i_flush_all(lq_router_flush_all),
      .i_sq_mem_write_en(sq_mem_write_en),
      .i_sq_mem_write_addr(sq_mem_write_addr),
      .i_sq_mem_write_data(sq_mem_write_data),
      .i_sq_mem_write_byte_en(sq_mem_write_byte_en),
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
      .i_sq_committed_empty(sq_committed_empty),
      .i_data_mem_rd_data(i_data_mem_rd_data),
      .i_cached_read_data(i_cached_read_data),
      .i_cached_read_id(i_cached_read_id),
      .i_cached_read_valid(i_cached_read_valid),
      .o_cached_read_ready(o_cached_read_ready),
      .o_cached_read_held(cached_read_held),
      .i_cached_write_done(i_cached_write_done),
      .i_cached_write_inflight(i_cached_write_inflight),
      .o_data_mem_addr(o_data_mem_addr),
      .o_data_mem_wr_data(o_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(o_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(o_data_mem_bram_byte_wr_en),
      .o_data_mem_bram_write_any(data_mem_bram_write_any),
      .o_data_mem_read_enable(o_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(o_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(o_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(o_data_mem_cached_read_enable),
      .o_data_mem_cached_read_id(o_data_mem_cached_read_id),
      .o_mmio_read_pulse(o_mmio_read_pulse),
      .o_mmio_load_addr(o_mmio_load_addr),
      .o_mmio_load_valid(o_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(o_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(o_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(o_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(sq_mem_write_done),
      .o_amo_mem_write_done(amo_mem_write_done),
      .o_lq_mem_request_valid(lq_mem_request_valid),
      .o_device_request_pending(lq_device_request_pending),
      .o_lq_mem_read_data(lq_mem_read_data),
      .o_lq_mem_read_valid(lq_mem_read_valid),
      .o_lq_mem_read_is_cached(lq_mem_read_is_cached),
      .o_lq_mem_read_id(lq_mem_read_id)
  );

  // ===========================================================================
  // CSR File
  // ===========================================================================
  // CSR instructions execute at commit, one at a time: the ROB serializer
  // holds the CSR at the head and raises csr_start, csr_done_ack answers a
  // cycle later (below), and the ROB retires the CSR. csr_file then reads and
  // writes the CSR from the registered commit bus (csr_commit_fire).

  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mepc;
  logic [XLEN-1:0] csr_stvec, csr_sepc;
  logic csr_sstatus_sie_direct;
  logic [15:0] csr_medeleg;
  logic [2:0] csr_mideleg_s;
  logic [2:0] csr_s_pending;
  logic [2:0] csr_scounteren;
  logic [2:0] csr_counter_blocked;
  logic csr_stimecmp_blocked;
  logic csr_sret_illegal, csr_sfence_illegal, csr_wfi_illegal, csr_priv_is_u;
  // Registered translation-invalidate pulse from csr_file: every satp access,
  // and an mstatus/sstatus write only when it changes translation. Through
  // tlb_invalidate it clears both TLBs and discards the walk in flight; the
  // ROB serializer handles pipeline recovery separately.
  logic csr_translation_flush_req;
  // Registered translation state from csr_file, and the data MMU's walker
  // port between the wrapper and the ptw below.
  logic csr_translation_active, csr_mmu_sum, csr_mmu_mxr, csr_mmu_eff_priv_u;
  logic [43:0] csr_satp_root_ppn;
  logic tlb_invalidate;
  logic walk_req_valid, walk_req_ready;
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
  logic [2:0] trap_dbg_cause;
  logic csr_mstatus_mie_direct;

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
  // Only entries with has_fp_flags (the OP-FP and FMA opcodes) accumulate
  // flags. Every other entry retires zero flags: allocation writes zero and
  // only the FP units send nonzero flags on the CDB, so the has_fp_flags term
  // matters only if a stray CDB write reached a store, branch, or integer
  // entry.
  assign rob_commit_fp_flags_valid = rob_commit_valid && rob_commit_fp_flags_nonzero &&
                                     !rob_commit.exception && rob_commit.has_fp_flags;
  assign rob_commit_2_fp_flags_valid = rob_commit_2_valid && rob_commit_2_fp_flags_nonzero &&
                                       !rob_commit_2.exception && rob_commit_2.has_fp_flags;
  assign rob_commit_any_fp_flags_valid = rob_commit_fp_flags_valid || rob_commit_2_fp_flags_valid;

  // FP regfile write at commit (either slot) -> csr_file sets
  // mstatus.FS = Dirty. Covers FP loads and f-dest computes; x-dest FP ops
  // that modify FP state do so only via nonzero flags, which the
  // i_fp_flags_valid term already carries (zero-flag FP reads leave state
  // unmodified, so precise no-Dirty is architecturally correct there).
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
  //     The per-cause comments below say who parks it.
  //   - Everything else FROST raises here: 0, which the privileged spec
  //     permits. That is ECALL, illegal instruction (including the MRET/CSR
  //     privilege faults the ROB re-causes as ExcIllegalInstr), and the
  //     ExcMemReplay pseudo-cause, which writes no CSR.
  logic [XLEN-1:0] csr_trap_value;
  always_comb begin
    unique case (rob_trap_cause)
      // Breakpoint: tval = the breakpoint instruction's own (virtual) address.
      riscv_pkg::ExcBreakpoint[$bits(rob_trap_cause)-1:0]: csr_trap_value = rob_trap_pc;
      // Instruction access/page faults: tval = the virtual
      // address of the faulting portion of the instruction (the PC, or PC + 2
      // for a page-straddling instruction whose second halfword faulted),
      // parked in the value slot by the INT ALU shim.
      // Misaligned and PMA access faults on data, and data
      // page faults: tval = the faulting data virtual
      // address, parked in the entry's value slot by the LQ bypass or the
      // store fault strobe.
      riscv_pkg::ExcInstrAccessFault[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcInstrPageFault[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcLoadAddrMisalign[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcStoreAddrMisalign[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcLoadAccessFault[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcStoreAccessFault[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcLoadPageFault[$bits(
          rob_trap_cause
      )-1:0], riscv_pkg::ExcStorePageFault[$bits(
          rob_trap_cause
      )-1:0]:
      csr_trap_value = rob_trap_value;
      default: csr_trap_value = '0;
    endcase
  end

  // ECALL cause is privilege-dependent (U-mode = 8, S-mode = 9, M-mode = 11).
  // The FU shim tags every ECALL as ExcEcallMmode (it has no architectural
  // privilege), so remap at commit using the current privilege. The remapped
  // cause enters trap_unit.i_exception_cause, and trap_unit's arbitrated
  // o_trap_cause (trap_cause_internal) is what csr_file writes to xcause. The
  // csr_trap_value mux above keys on the unremapped cause (ECALL tval is 0
  // either way).
  //
  // Safe against the cause==11 / IntMachineExternal (interrupt bit plus code
  // 11) low-bit collision: rob_trap_cause holds only synchronous causes (the
  // head's exception cause, or the ExcMemReplay pseudo-cause; the ROB's
  // i_interrupt_pending only wakes WFI and is never a cause source), so a
  // value of 11 here is always an M-mode ECALL.
  assign rob_trap_cause_remapped =
      ((rob_trap_cause == riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0]) &&
       (csr_priv == riscv_pkg::PrivU)) ?
          riscv_pkg::ExcEcallUmode[riscv_pkg::ExcCauseWidth-1:0] :
      ((rob_trap_cause == riscv_pkg::ExcEcallMmode[riscv_pkg::ExcCauseWidth-1:0]) &&
       (csr_priv == riscv_pkg::PrivS)) ?
          riscv_pkg::ExcEcallSmode[riscv_pkg::ExcCauseWidth-1:0] : rob_trap_cause;

  csr_file #(
      .XLEN(XLEN),
      .COMMIT_EXCLUDES_CONTROL_TAKE(1'b1),
      .UsePerfCsrHalf(1'b1),
      .PERF_COUNTERS(PERF_COUNTERS)
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
      .i_interrupts(i_interrupts),
      .i_mtime(i_mtime),
      .i_seip_line(i_plic_seip),
      // Takes with no CSR side effect (Debug Mode go and re-park redirects,
      // memory-order replays) do not reach csr_file.
      .i_trap_taken(trap_taken && !trap_no_csr),
      .i_trap_to_s(trap_to_s),
      .i_trap_to_d(trap_to_d),
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
      .o_priv(csr_priv),
      .o_mcounteren(csr_mcounteren),
      .o_scounteren(csr_scounteren),
      .o_counter_blocked(csr_counter_blocked),
      .o_stimecmp_blocked(csr_stimecmp_blocked),
      .o_sret_illegal(csr_sret_illegal),
      .o_sfence_illegal(csr_sfence_illegal),
      .o_wfi_illegal(csr_wfi_illegal),
      .o_priv_is_u(csr_priv_is_u),
      .o_csr_translation_flush_req(csr_translation_flush_req),
      .o_translation_active(csr_translation_active),
      .o_mmu_sum(csr_mmu_sum),
      .o_mmu_mxr(csr_mmu_mxr),
      .o_mmu_eff_priv_u(csr_mmu_eff_priv_u),
      .o_fetch_translation_active(csr_fetch_translation_active),
      .o_fetch_priv_u(csr_fetch_priv_u),
      .o_satp_root_ppn(csr_satp_root_ppn),
      .o_mstatus_fs_off(csr_mstatus_fs_off),
      .o_debug_mode(csr_debug_mode),
      .o_dcsr_step(csr_dcsr_step),
      .o_dcsr_ebreak(csr_dcsr_ebreak),
      .o_dpc(csr_dpc),
      // FP flags: accumulated from ROB commit
      .i_fp_flags(rob_commit_fp_flags_merged),
      .i_fp_flags_valid(rob_commit_any_fp_flags_valid),
      .i_fp_flags_wb_valid(rob_commit_any_fp_flags_valid),
      .i_fp_dest_write(rob_commit_any_fp_dest_write),
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
  // id_stage decodes F/D instructions against id_mstatus_fs_off_q, one cycle
  // behind mstatus.FS, so an instruction decoded under the old value, before
  // or in the cycle FS enters or leaves Off, must not survive the change. FS
  // enters or leaves Off only through a write-intending mstatus/sstatus access
  // (hardware Dirty-setting starts from a value other than Off), which the ROB
  // classes as a translation CSR: its FENCE-class full flush lands in the
  // cycle the new value first shows here.
  logic fs_off_checks_armed = 1'b0;
  always_ff @(posedge i_clk) begin
    fs_off_checks_armed <= !i_rst;
    if (fs_off_checks_armed && !i_rst && (csr_mstatus_fs_off != id_mstatus_fs_off_q)) begin
      p_fs_off_change_flushes_decode : assert (flush_all);
    end
  end
`endif

  // ===========================================================================
  // Page-Table Walker
  // ===========================================================================
  // One ptw serves the wrapper's data MMU and if_stage's instruction MMU, and
  // the data side wins when both ask. walk_owner_i_q records which side
  // started the walk in flight so the response goes only to that side (the
  // vpn echo alone would let the other TLB install a leaf it never asked
  // for). The line port goes out to the cache hierarchy's walker port.
  // tlb_invalidate, which flash-clears both TLBs, also makes the ptw discard
  // the walk in flight, which then never responds, and clears walk_owner_i_q.
  logic ptw_req_valid, ptw_req_ready, ptw_resp_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] ptw_req_vpn;
  logic walk_owner_i_q;  // the walk in flight belongs to the instruction side
  assign ptw_req_valid = walk_req_valid || iwalk_req_valid;
  assign ptw_req_vpn = walk_req_valid ? walk_vpn : iwalk_vpn;
  assign walk_req_ready = ptw_req_ready;
  assign iwalk_req_ready = ptw_req_ready && !walk_req_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst || tlb_invalidate) walk_owner_i_q <= 1'b0;
    else if (ptw_req_valid && ptw_req_ready) walk_owner_i_q <= !walk_req_valid;
  end
  assign walk_resp_valid  = ptw_resp_valid && !walk_owner_i_q;
  assign iwalk_resp_valid = ptw_resp_valid && walk_owner_i_q;

  ptw u_ptw (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_root_ppn(csr_satp_root_ppn),
      .i_req_valid(ptw_req_valid),
      .o_req_ready(ptw_req_ready),
      .i_req_vpn(ptw_req_vpn),
      .i_discard(tlb_invalidate),
      .o_resp_valid(ptw_resp_valid),
      .o_resp(walk_resp),
      .o_line_req_valid(o_walk_line_req_valid),
      .i_line_req_ready(i_walk_line_req_ready),
      .o_line_req_addr(o_walk_line_req_addr),
      .o_line_req_id(o_walk_line_req_id),
      .i_line_resp_valid(i_walk_line_resp_valid),
      .i_line_resp_id(i_walk_line_resp_id),
      .i_line_resp_rdata(i_walk_line_resp_rdata)
  );

  // CSR done acknowledgment, one cycle after csr_start: csr_start fires in
  // cycle N (the ROB serializer enters SERIAL_CSR_EXEC at its end) and
  // csr_done_ack in cycle N+1 lets the ROB commit an ordinary CSR. A CSR that
  // may change translation moves to SERIAL_CSR_TRANSLATION_DRAIN instead and
  // retires only after committed stores drain.
  logic csr_done_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) csr_done_q <= 1'b0;
    else csr_done_q <= csr_start;
  end
  assign csr_done_ack = csr_done_q;

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
  assign interrupt_pending = i_interrupts.meip || i_interrupts.mtip || i_interrupts.msip ||
      (|csr_s_pending);

  logic [XLEN-1:0] trap_target_internal, trap_pc_internal;
  logic [XLEN-1:0] trap_value_internal;
  logic [XLEN-1:0] interrupt_resume_pc;

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

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      interrupt_resume_pc <= '0;
    end else if (xret_taken) begin
      // An xRET never appears on rob_commit_valid_raw, so the arms below never
      // see it: it retires through the full flush that follows it (flush_all,
      // from mret_taken_reg, clears the ROB head and gates commit_en). Without
      // this seed the resume PC would stay at the xRET's own PC until the
      // first instruction at the target commits. An M-level interrupt taken
      // in that window (possible once privilege has dropped and the trap
      // unit's inhibit lifts, a few cycles after the xRET) would then save the
      // xRET's PC as mepc, and the handler's MRET would re-execute the xRET at
      // the lower privilege. The seed is the xRET target (mepc, sepc, or dpc),
      // which is the redirect target. csr_mepc is stable here: MRET does not
      // write mepc and cannot coincide with a trap entry that would.
      interrupt_resume_pc <= dret_taken ? csr_dpc : sret_taken ? csr_sepc : csr_mepc;
    end else if (trap_taken) begin
      // Every trap take also seeds the resume PC with its redirect target, for
      // two cases that arise before the handler's first instruction retires:
      //  - an M-level interrupt taken just after a trap delegated to S
      //    (privilege is now S, so M interrupts are enabled regardless of
      //    MIE, and the take can arm a few cycles after the entry) would
      //    otherwise save the trapping instruction's PC as mepc and, after
      //    the MRET, re-execute it in S;
      //  - a single step whose instruction traps must halt with dpc at the
      //    handler's first instruction, as the debug spec requires.
      // Debug Mode entries and redirects also land here; nothing uses the
      // value then, because interrupts are masked in Debug Mode.
      interrupt_resume_pc <= trap_target;
    end else if (rob_commit_2_valid_raw) begin
      // Timing: identical value to retired_next_pc(rob_commit_comb_2) in every
      // cycle this arm is taken (checked below in simulation), but the ROB
      // precomputes it from ungated head+1 fields so the PC RAM read and add
      // do not sit behind the late commit gating.
      interrupt_resume_pc <= rob_head_next_retired_next_pc;
    end else if (rob_commit_valid_raw) begin
      // Timing: identical value to retired_next_pc(rob_commit_comb); see above.
      interrupt_resume_pc <= rob_head_retired_next_pc;
    end else if (rob_head_is_wfi && head_valid && (rob_trap_cause == '0) && !flush_all &&
                 !mispredict_recovery_pending) begin
      // While a WFI waits at the ROB head, the architectural resume PC is
      // wfi_pc+4 (WFI never redirects). Seed it so that an interrupt taken at
      // the WFI saves the spec-required wfi_pc+4 rather than the pre-WFI
      // instruction's next-PC (== wfi_pc). That includes the narrow window
      // where a committed store finishes draining and take_trap fires the
      // same cycle, before the WFI's own commit can advance
      // interrupt_resume_pc. Lowest priority: a real commit always wins, and
      // WFI is never compressed, so +4 is exact.
      //
      // Only a legal WFI that stays in the ROB seeds. A WFI's cause is zero
      // unless allocation marked it illegal; an illegal WFI has not executed,
      // so an interrupt taken there must not resume past it (it traps once
      // the handler returns). A full flush (after a trap taken at the WFI, or
      // a FENCE-class retirement) and commit-time recovery (a wrong-path
      // head) remove the head at the end of the cycle; seeding then would
      // overwrite the resume PC installed by the take or by the last
      // retirement.
      interrupt_resume_pc <= rob_trap_pc + 64'd4;
    end
  end

`ifndef SYNTHESIS
  // Equivalence check for the ROB retired-next-PC precompute: whenever a
  // commit fires, the precomputed value must match retired_next_pc() of the
  // (gated) commit payload.
  always @(posedge i_clk) begin
    if (!i_rst) begin
      if (rob_commit_valid_raw && rob_head_retired_next_pc != retired_next_pc(
              rob_commit_comb
          )) begin
        $error("cpu_ooo: rob_head_retired_next_pc %08x != retired_next_pc(commit) %08x",
               rob_head_retired_next_pc, retired_next_pc(rob_commit_comb));
      end
      if (rob_commit_2_valid_raw && rob_head_next_retired_next_pc != retired_next_pc(
              rob_commit_comb_2
          )) begin
        $error("cpu_ooo: rob_head_next_retired_next_pc %08x != retired_next_pc(commit_2) %08x",
               rob_head_next_retired_next_pc, retired_next_pc(rob_commit_comb_2));
      end
    end
  end

  // An M/S interrupt taken while a WFI waits at the ROB head resumes after a
  // legal WFI: the saved PC must be wfi_pc+4. An illegal WFI has not
  // executed and gets no seed, so the interrupt saves the resume PC held
  // while it waited (the WFI's own PC, or that of a dropped NOP before it),
  // never wfi_pc+4, and the WFI traps once the handler returns. Waiting means
  // the same WFI was the valid head in the previous cycle with nothing
  // retiring, trapping or being flushed, so the resume-PC seed has had its
  // cycle. A WFI's cause field is zero unless allocation marked it illegal
  // (a WFI never completes on the CDB).
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
    if (!i_rst && wfi_waiting_q && trap_taken && !trap_to_d && !trap_no_csr &&
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

  // The trap unit takes sq_committed_empty without a same-cycle store-commit
  // guard: the SQ's registered committed-empty already folds the raw commit
  // pulses into its D (one cycle pessimistic), and trap_unit's interrupt
  // arming and exception commit block keep any commit off the take cycle.
  // Leaving the guard out keeps the ROB head-commit logic out of the
  // take_trap -> trap_target/CSR-write timing.
  assign sq_committed_empty_for_trap = sq_committed_empty;

  // AMO interrupt shield register (see trap_unit.i_amo_at_head port comment
  // for the hazard and the lag-safety argument).
  always_ff @(posedge i_clk) begin
    if (i_rst) amo_at_head_shield_q <= 1'b0;
    else amo_at_head_shield_q <= rob_head_is_amo && head_valid;
  end

  // Device-read interrupt shield register (see trap_unit.i_device_read_at_head).
  //
  // The window must span from before the irrevocable device read to the
  // load's commit. It opens from the router's registered device-pending bit,
  // which is high for at least one staging cycle before the request can be
  // armed, and closes at the first ROB commit afterwards.
  //
  // "First commit" is exact: a device request leaves the LQ only at the ROB
  // head, and a head entry still waiting on its memory response is not done
  // (commit_ready_early is low, and slot 2 is gated by it), so no commit of
  // any kind can fire between the launch and this load's own. Set beats
  // clear, so the accept cycle itself cannot open a hole. A full flush before
  // arming cancels the request with no response owed, and the shield rules
  // out an interrupt flush after arming, so clearing the shield on a flush
  // never exposes a device read.
  always_ff @(posedge i_clk) begin
    if (i_rst || lq_router_flush_all) device_read_shield_q <= 1'b0;
    else if (lq_device_request_pending) device_read_shield_q <= 1'b1;
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
      // trap, Debug Mode, and xRET take on both cycles, so csr_file's
      // higher-priority trap and xRET updates cannot overwrite the CSR write
      // and no stale younger xRET can execute on the flush edge.
      .i_pipeline_stall(fence_class_quiesce),
      .i_sq_committed_empty(sq_committed_empty_for_trap),
      .o_trap_drain_wait(trap_drain_wait),
      .i_amo_at_head(amo_at_head_shield_q),
      .i_device_read_at_head(device_read_shield_q),
      .i_mstatus(csr_mstatus),
      .i_mie(csr_mie),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_stvec(csr_stvec),
      .i_sepc(csr_sepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      .i_sstatus_sie_direct(csr_sstatus_sie_direct),
      .i_mideleg_s(csr_mideleg_s),
      .i_medeleg(csr_medeleg),
      .i_priv(csr_priv),
      .i_interrupts(i_interrupts),
      .i_s_pending(csr_s_pending),
      // Exception from the ROB head. i_pipeline_stall does not gate the trap
      // unit's exception latch, so mask the exception over the same T+1/T+2
      // window; otherwise a stale younger exception could survive the full
      // flush and be taken at T+3.
      .i_exception_valid(trap_pending && !fence_class_quiesce),
      .i_exception_cause({
        {(XLEN - $bits(rob_trap_cause_remapped)) {1'b0}}, rob_trap_cause_remapped
      }),
      .i_exception_tval(csr_trap_value),
      .i_exception_pc(rob_trap_pc),
      .i_interrupt_pc(interrupt_resume_pc),
      .i_mret_start(mret_start && !mret_start_is_sret && !mret_start_is_dret),
      .i_sret_start(mret_start && mret_start_is_sret),
      .i_wfi_start(1'b0),  // WFI handled by ROB serialization
      // Debug Mode
      .i_debug_mode(csr_debug_mode),
      .i_dbg_haltreq(i_dbg_haltreq),
      .i_dbg_step_req(step_done_q),
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
      .o_trap_target(trap_target),
      .o_trap_pc(trap_pc_internal),
      .o_trap_cause(trap_cause_internal),
      .o_trap_value(trap_value_internal),
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
    if (!i_rst && !$isunknown(
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

  // The front-end flush uses the registered trap and xRET pulses, keeping
  // flush_pipeline off the combinational
  //   rob_valid[head_idx] -> commit_en -> trap_unit -> trap_taken
  // path. The back end's flush_all is the same registered pulses ORed with
  // fence_i_flush (see misprediction_flush_controller), so the front-end
  // flush lines up with it instead of leading it. A trap pays one extra cycle
  // of front-end squash, negligible for workloads that rarely trap; the
  // redirect already waits for the registered trap_target_reg and
  // rob_trap_taken_ack.
  assign flush_for_trap = trap_taken_reg;
  assign flush_for_mret = mret_taken_reg;

  // Acknowledge a trap or xRET to the ROB on the registered recovery pulse.
  // This keeps the head trap metadata stable through the CSR trap-entry
  // update; the commit hold above blocks younger retirement during the delay.
  assign rob_trap_taken_ack = trap_taken_reg;
  // mret_taken_reg is the registered image of xret_taken (pipeline control's
  // i_mret_taken input), so this ack also covers SRET and DRET.
  assign mret_done_ack = mret_taken_reg;

  // Status bits for the hang-triage report (hang_triage in cpu_and_mem).
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
      // No counters: the CSR file reads zero for every mperf* address and
      // never raises the snapshot pulse. The event registers stay in their
      // source modules; nothing reads them, so synthesis drops them along
      // with the counters, except the few marked keep (the cache and
      // fetch-provider event registers).
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

endmodule : cpu_ooo
