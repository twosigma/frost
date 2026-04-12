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
 * Tomasulo Integration Wrapper
 *
 * Verification wrapper that instantiates ROB + RAT + six RS instances
 * (INT_RS, MUL_RS, MEM_RS, FP_RS, FMUL_RS, FDIV_RS), LQ, SQ, CDB arbiter,
 * FU shims, and hardwires the internal commit bus, dispatch routing,
 * SQ↔LQ forwarding, and shared CDB/flush signals.
 *
 * Dispatch routing:
 *   i_rs_dispatch.rs_type is decoded to per-RS dispatch valid signals.
 *   All RS instances share the same dispatch data bus; only the valid
 *   signal is gated per RS type.
 *
 * Internal wiring:
 *   ROB.o_commit_comb --> commit_bus --> cpu_ooo same-cycle mispredict detect
 *   ROB.o_commit      --> o_commit   (registered testbench observation)
 *   commit_bus_q      --> RAT commit-clear signals
 *   FU adapters --> cdb_arbiter --> cdb_bus --> ROB.i_cdb_write (derived)
 *                                           --> all RS .i_cdb (broadcast for wakeup)
 *   cdb_arbiter.o_grant --> o_cdb_grant (back-pressure to FUs)
 *   LQ.o_sq_check --> SQ.i_sq_check (store-to-load forwarding)
 *   SQ.o_sq_forward --> LQ.i_sq_forward
 *   SQ.o_cache_invalidate --> LQ.i_cache_invalidate
 *   ROB.commit (store/sc subset) --> SQ commit inputs
 *   Flush --> all modules
 *   ROB.o_head_tag --> all RS/LQ/SQ .i_rob_head_tag
 */

module tomasulo_wrapper (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // FRM CSR (dynamic rounding-mode resolution at dispatch)
    // =========================================================================
    input logic [2:0] i_frm_csr,

    // =========================================================================
    // ROB Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // =========================================================================
    // FU Completion Test Injection (active when internal adapter is idle)
    // =========================================================================
    input riscv_pkg::fu_complete_t i_fu_complete_0,
    input riscv_pkg::fu_complete_t i_fu_complete_1,
    input riscv_pkg::fu_complete_t i_fu_complete_2,
    input riscv_pkg::fu_complete_t i_fu_complete_3,
    input riscv_pkg::fu_complete_t i_fu_complete_4,
    input riscv_pkg::fu_complete_t i_fu_complete_5,
    input riscv_pkg::fu_complete_t i_fu_complete_6,

    // =========================================================================
    // CDB Grant (back-pressure to FUs)
    // =========================================================================
    output logic [riscv_pkg::NumFus-1:0] o_cdb_grant,

    // =========================================================================
    // CDB Broadcast Output (for testbench observation)
    // =========================================================================
    output riscv_pkg::cdb_broadcast_t o_cdb,

    // =========================================================================
    // ROB Branch Update Interface (from Branch Unit)
    // =========================================================================
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // ROB Checkpoint Recording (from Dispatch)
    // =========================================================================
    input logic                                    i_rob_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_rob_checkpoint_id,

    // =========================================================================
    // Commit Observation (tapped from internal commit bus)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb,
    output logic                              o_commit_valid_raw,
    output logic                              o_commit_misprediction_raw,
    output logic                              o_commit_correct_branch_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // =========================================================================
    // ROB External Coordination
    // =========================================================================
    output logic                                        o_csr_start,
    input  logic                                        i_csr_done,
    output logic                                        o_trap_pending,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_pc,
    output riscv_pkg::exc_cause_t                       o_trap_cause,
    input  logic                                        i_trap_taken,
    output logic                                        o_mret_start,
    input  logic                                        i_mret_done,
    input  logic                  [riscv_pkg::XLEN-1:0] i_mepc,
    input  logic                                        i_interrupt_pending,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,
    input logic                                        i_flush_after_head_commit,
    input logic                                        i_backend_recovery_hold,

    // =========================================================================
    // Early Misprediction Recovery
    // =========================================================================
    input logic                                        i_early_recovery_flush,
    input logic                                        i_early_recovery_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_recovery_tag,

    // =========================================================================
    // ROB Status
    // =========================================================================
    output logic                                        o_fence_i_flush,
    output logic                                        o_rob_full,
    output logic                                        o_rob_empty,
    output logic [  riscv_pkg::ReorderBufferTagWidth:0] o_rob_count,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // ROB Bypass Read
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,
    output logic [   riscv_pkg::ReorderBufferDepth-1:0] o_rob_entry_done_vec,
    input  logic [   riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_epoch,

    // =========================================================================
    // Dispatch Done-Entry Bypass (generic source ports)
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_3,

    // =========================================================================
    // RAT Source Lookups (combinational)
    // =========================================================================
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr,
    output riscv_pkg::rat_lookup_t                               o_int_src1,
    output riscv_pkg::rat_lookup_t                               o_int_src2,

    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr,
    output riscv_pkg::rat_lookup_t                               o_fp_src1,
    output riscv_pkg::rat_lookup_t                               o_fp_src2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3,

    // RAT Regfile data
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // =========================================================================
    // RAT Rename (from Dispatch)
    // =========================================================================
    input logic                                        i_rat_alloc_valid,
    input logic                                        i_rat_alloc_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag,

    // =========================================================================
    // RAT Checkpoint Save (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Restore (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    input  logic                                    i_checkpoint_restore_reclaim_all,
    input  logic [   riscv_pkg::NumCheckpoints-1:0] i_checkpoint_reclaim_mask,
    input  logic [   riscv_pkg::NumCheckpoints-1:0] i_checkpoint_flush_free_mask,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Free (from ROB on correct branch commit)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,

    // =========================================================================
    // RAT Checkpoint Availability
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id,

    // =========================================================================
    // RS Dispatch (from Dispatch)
    // =========================================================================
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
    output logic o_rs_full,

    // =========================================================================
    // RS Issue (to Functional Unit)
    // =========================================================================
    output riscv_pkg::rs_issue_t o_rs_issue,
    input  logic                 i_rs_fu_ready,

    // =========================================================================
    // RS Status (INT_RS)
    // =========================================================================
    output logic       o_int_rs_full,
    output logic       o_rs_empty,
    output logic [3:0] o_rs_count,

    // =========================================================================
    // MUL_RS (Integer multiply/divide, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mul_rs_issue,
    input  logic                                                           i_mul_rs_fu_ready,
    output logic                                                           o_mul_rs_full,
    output logic                                                           o_mul_rs_empty,
    output logic                 [$clog2(riscv_pkg::MulRsDepth + 1) - 1:0] o_mul_rs_count,

    // =========================================================================
    // MEM_RS (Load/store, depth 8)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mem_rs_issue,
    input  logic                                                           i_mem_rs_fu_ready,
    output logic                                                           o_mem_rs_full,
    output logic                                                           o_mem_rs_empty,
    output logic                 [$clog2(riscv_pkg::MemRsDepth + 1) - 1:0] o_mem_rs_count,

    // =========================================================================
    // FP_RS (FP add/sub/cmp/cvt/classify/sgnj, depth 6)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                          o_fp_rs_issue,
    input  logic                                                          i_fp_rs_fu_ready,
    output logic                                                          o_fp_rs_full,
    output logic                                                          o_fp_rs_empty,
    output logic                 [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] o_fp_rs_count,

    // =========================================================================
    // FMUL_RS (FP multiply/FMA, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fmul_rs_issue,
    input  logic                                                            i_fmul_rs_fu_ready,
    output logic                                                            o_fmul_rs_full,
    output logic                                                            o_fmul_rs_empty,
    output logic                 [$clog2(riscv_pkg::FmulRsDepth + 1) - 1:0] o_fmul_rs_count,

    // =========================================================================
    // FDIV_RS (FP divide/sqrt, depth 2)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fdiv_rs_issue,
    input  logic                                                            i_fdiv_rs_fu_ready,
    output logic                                                            o_fdiv_rs_full,
    output logic                                                            o_fdiv_rs_empty,
    output logic                 [$clog2(riscv_pkg::FdivRsDepth + 1) - 1:0] o_fdiv_rs_count,

    // =========================================================================
    // CSR Read Data (for ALU shim — CSR operations return old CSR value)
    // =========================================================================
    input logic [riscv_pkg::XLEN-1:0] i_csr_read_data,

    // =========================================================================
    // Store Queue: Memory Write Interface
    // =========================================================================
    output logic                       o_sq_mem_write_en,
    output logic [riscv_pkg::XLEN-1:0] o_sq_mem_write_addr,
    output logic [riscv_pkg::XLEN-1:0] o_sq_mem_write_data,
    output logic [                3:0] o_sq_mem_write_byte_en,
    output logic                       o_sq_mem_write_is_mmio,
    input  logic                       i_sq_mem_write_done,

    // =========================================================================
    // Load Queue: Memory Interface
    // =========================================================================
    output logic                                       o_lq_mem_read_en,
    output logic                 [riscv_pkg::XLEN-1:0] o_lq_mem_read_addr,
    output riscv_pkg::mem_size_e                       o_lq_mem_read_size,
    input  logic                 [riscv_pkg::XLEN-1:0] i_lq_mem_read_data,
    input  logic                                       i_lq_mem_read_valid,

    // =========================================================================
    // Load Queue: Status
    // =========================================================================
    output logic                                    o_lq_full,
    output logic                                    o_lq_empty,
    output logic [$clog2(riscv_pkg::LqDepth+1)-1:0] o_lq_count,

    // =========================================================================
    // Store Queue: Status
    // =========================================================================
    output logic                                    o_sq_full,
    output logic                                    o_sq_empty,
    output logic [$clog2(riscv_pkg::SqDepth+1)-1:0] o_sq_count,

    // =========================================================================
    // AMO Memory Write Interface (from LQ)
    // =========================================================================
    output logic                       o_amo_mem_write_en,
    output logic [riscv_pkg::XLEN-1:0] o_amo_mem_write_addr,
    output logic [riscv_pkg::XLEN-1:0] o_amo_mem_write_data,
    input  logic                       i_amo_mem_write_done,

    // =========================================================================
    // Profiling Snapshot Interface
    // =========================================================================
    input  logic        i_perf_snapshot_capture,
    input  logic [ 7:0] i_perf_counter_select,
    output logic [63:0] o_perf_counter_data
);

  // ===========================================================================
  // Internal commit bus: ROB -> RAT / SQ / SC
  // ===========================================================================
  // commit_bus is the combinational output from the ROB. It stays on the
  // zero-cycle control path for cpu_ooo misprediction detection.
  //
  // commit_bus_q is a one-cycle pipeline register that breaks the critical
  // timing path from ROB head_ready/commit_en through SQ/RAT to LQ.
  // All internal consumers (RAT, SQ commit, SC logic) use the registered
  // version.  The valid bit is cleared on full flush for safety — although
  // overlapping pipelined commits with flush_all only occurs for non-store
  // instructions (traps, MRET, FENCE.I), so SQ/SC are unaffected.
  riscv_pkg::reorder_buffer_commit_t commit_bus;
  // Split commit_bus_q into separate valid + data to prevent Vivado from
  // dragging the reset net onto payload register bits.
  logic commit_bus_q_valid;
  riscv_pkg::reorder_buffer_commit_t commit_bus_q;
  logic commit_q_dest_valid;
  logic commit_q_dest_rf;
  logic [riscv_pkg::RegAddrWidth-1:0] commit_q_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] commit_q_tag;
  logic commit_q_is_sc;
  logic commit_q_is_store_like;
  logic commit_q_sc_failed;
  logic commit_valid_raw;
  logic commit_store_like_raw;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) commit_bus_q_valid <= 1'b0;
    else commit_bus_q_valid <= commit_bus.valid;
  end

  always_ff @(posedge i_clk) begin
    commit_bus_q <= commit_bus;
    commit_q_dest_valid <= commit_bus.dest_valid;
    commit_q_dest_rf <= commit_bus.dest_rf;
    commit_q_dest_reg <= commit_bus.dest_reg;
    commit_q_tag <= commit_bus.tag;
    commit_q_is_sc <= commit_bus.is_sc;
    commit_q_is_store_like <= commit_bus.is_store || commit_bus.is_fp_store || commit_bus.is_sc;
    commit_q_sc_failed <= commit_bus.is_sc && commit_bus.value[0];
  end

  // Reconstruct commit bus with reset-qualified valid for downstream consumers
  riscv_pkg::reorder_buffer_commit_t commit_bus_q_qualified;
  always_comb begin
    commit_bus_q_qualified       = commit_bus_q;
    commit_bus_q_qualified.valid = commit_bus_q_valid;
  end
  assign o_commit_valid_raw = commit_valid_raw;

  localparam int unsigned WrapperPerfCounterCount = 34;
  localparam int unsigned PerfHeadWaitTotal = 0;
  localparam int unsigned PerfHeadWaitInt = 1;
  localparam int unsigned PerfHeadWaitBranch = 2;
  localparam int unsigned PerfHeadWaitMul = 3;
  localparam int unsigned PerfHeadWaitMemLoad = 4;
  localparam int unsigned PerfHeadWaitMemStore = 5;
  localparam int unsigned PerfHeadWaitMemAmo = 6;
  localparam int unsigned PerfHeadWaitFp = 7;
  localparam int unsigned PerfHeadWaitFmul = 8;
  localparam int unsigned PerfHeadWaitFdiv = 9;
  localparam int unsigned PerfCommitBlockedCsr = 10;
  localparam int unsigned PerfCommitBlockedFence = 11;
  localparam int unsigned PerfCommitBlockedWfi = 12;
  localparam int unsigned PerfCommitBlockedMret = 13;
  localparam int unsigned PerfCommitBlockedTrap = 14;
  localparam int unsigned PerfIntBackpressure = 15;
  localparam int unsigned PerfMulBackpressure = 16;
  localparam int unsigned PerfMemResultBackpressure = 17;
  localparam int unsigned PerfFpAddBackpressure = 18;
  localparam int unsigned PerfFmulBackpressure = 19;
  localparam int unsigned PerfFdivBackpressure = 20;
  localparam int unsigned PerfMemDisambiguationWait = 21;
  localparam int unsigned PerfSqCommittedPending = 22;
  localparam int unsigned PerfSqMemWriteFire = 23;
  localparam int unsigned PerfLqMemReadFire = 24;
  localparam int unsigned PerfRobOccupancySum = 25;
  localparam int unsigned PerfLqOccupancySum = 26;
  localparam int unsigned PerfSqOccupancySum = 27;
  localparam int unsigned PerfIntRsOccupancySum = 28;
  localparam int unsigned PerfMulRsOccupancySum = 29;
  localparam int unsigned PerfMemRsOccupancySum = 30;
  localparam int unsigned PerfFpRsOccupancySum = 31;
  localparam int unsigned PerfFmulRsOccupancySum = 32;
  localparam int unsigned PerfFdivRsOccupancySum = 33;

  logic [63:0] perf_live[WrapperPerfCounterCount];
  logic [63:0] perf_snapshot[WrapperPerfCounterCount];
  logic [63:0] perf_inc[WrapperPerfCounterCount];
  logic [63:0] perf_inc_q[WrapperPerfCounterCount];
  localparam int unsigned PerfSnapshotBankSpan = (WrapperPerfCounterCount + 3) / 4;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank0;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank1;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank2;
  (* max_fanout = 768 *)logic perf_snapshot_capture_bank3;

  // Expose both the raw and registered commit buses.
  assign o_commit_comb = commit_bus;
  assign o_commit = commit_bus_q_qualified;
  assign perf_snapshot_capture_bank0 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank1 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank2 = i_perf_snapshot_capture;
  assign perf_snapshot_capture_bank3 = i_perf_snapshot_capture;

  // ROB entry valid/done vectors: ROB -> RAT/dispatch
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_valid;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done;
  assign o_rob_entry_done_vec = rob_entry_done;

  // Dispatch bypass: dispatch selects up to three source ROB tags and the ROB
  // returns their values asynchronously for done-entry forwarding.
  logic [riscv_pkg::FLEN-1:0] bypass_value_1, bypass_value_2, bypass_value_3;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_1;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_2;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_3;

  // Head tag for RS partial flush
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  riscv_pkg::rob_perf_events_t rob_perf_events;
  assign head_tag = o_head_tag;

  // With early misprediction recovery, partial flushes (flush_en + flush_tag)
  // target branches that are NOT at the ROB head. Older instructions must be
  // preserved. Pass age-based partial flush to all speculative structures.
  // Full flushes (trap/MRET/FENCE.I) still clear everything.
  //
  // Commit-time mispredict recovery already tells us explicitly when the
  // offending branch retired at the ROB head, so promote only that case to a
  // speculative full flush without recomputing head/tag relationships here.
  (* max_fanout = 32 *)logic full_flush_all;
  (* max_fanout = 32 *)logic speculative_partial_flush;
  (* max_fanout = 32 *)logic speculative_flush_all;
  logic speculative_flush_en;
  // Keep the CDB kill as a small, local copy so speculative full-flush does
  // not have to route back through every adapter output-valid cone.
  (* keep = "true" *)logic cdb_kill;
  assign full_flush_all = i_flush_all;
  assign speculative_partial_flush = i_flush_en;
  assign speculative_flush_all = full_flush_all || i_flush_after_head_commit;
  assign speculative_flush_en = i_flush_en && !i_flush_after_head_commit;
  assign cdb_kill = speculative_flush_all;


  // ===========================================================================
  // CDB Arbiter: FU completions → single CDB broadcast
  // ===========================================================================
  riscv_pkg::cdb_broadcast_t cdb_bus_comb;  // combinational from arbiter
  riscv_pkg::cdb_broadcast_t cdb_bus;  // registered — feeds RS/ROB wakeup

  // Forward declarations: adapter→arbiter signals (used here, defined below)
  riscv_pkg::fu_complete_t   alu_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   mul_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   div_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   mem_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   fp_add_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   fp_mul_adapter_to_arbiter;
  riscv_pkg::fu_complete_t   fp_div_adapter_to_arbiter;

  // Route FU adapter outputs to CDB arbiter inputs.  Internal adapters
  // take priority; test-injection ports (i_fu_complete_*) fall through
  // when the adapter is idle.  In production cpu_ooo ties them to '0.
  riscv_pkg::fu_complete_t   cdb_arb_in                                     [riscv_pkg::NumFus];
  always_comb begin
    cdb_arb_in[0] = alu_adapter_to_arbiter.valid ? alu_adapter_to_arbiter : i_fu_complete_0;
    cdb_arb_in[1] = mul_adapter_to_arbiter.valid ? mul_adapter_to_arbiter : i_fu_complete_1;
    cdb_arb_in[2] = div_adapter_to_arbiter.valid ? div_adapter_to_arbiter : i_fu_complete_2;
    cdb_arb_in[3] = mem_adapter_to_arbiter.valid ? mem_adapter_to_arbiter : i_fu_complete_3;
    cdb_arb_in[4] = fp_add_adapter_to_arbiter.valid ? fp_add_adapter_to_arbiter : i_fu_complete_4;
    cdb_arb_in[5] = fp_mul_adapter_to_arbiter.valid ? fp_mul_adapter_to_arbiter : i_fu_complete_5;
    cdb_arb_in[6] = fp_div_adapter_to_arbiter.valid ? fp_div_adapter_to_arbiter : i_fu_complete_6;
  end

  cdb_arbiter u_cdb_arbiter (
      .i_clk          (i_clk),
      .i_rst_n        (i_rst_n),
      .i_fu_complete_0(cdb_arb_in[0]),
      .i_fu_complete_1(cdb_arb_in[1]),
      .i_fu_complete_2(cdb_arb_in[2]),
      .i_fu_complete_3(cdb_arb_in[3]),
      .i_fu_complete_4(cdb_arb_in[4]),
      .i_fu_complete_5(cdb_arb_in[5]),
      .i_fu_complete_6(cdb_arb_in[6]),
      .i_kill         (cdb_kill),
      .o_cdb          (cdb_bus_comb),
      .o_grant        (o_cdb_grant)
  );

  // Pipeline register: break the CDB arbiter → RS/ROB wakeup critical path.
  // Grants stay combinational (back to adapters); only the broadcast fanout
  // to RS snoop + ROB CDB-write is registered.
  // Split valid from data to prevent Vivado from dragging reset onto payload.
  // max_fanout forces replication across the RS snoop / ROB-write consumers —
  // the high-fanout report (609 loads) showed this net being one of the top
  // drivers into the flush-recovery cone that failed timing at -0.947 ns.
  (* max_fanout = 32 *) logic cdb_bus_valid;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) cdb_bus_valid <= 1'b0;
    else cdb_bus_valid <= cdb_bus_comb.valid;
  end

  always_ff @(posedge i_clk) begin
    cdb_bus <= cdb_bus_comb;
  end

  // Expose combinational CDB for testbench observation (grant timing matches)
  assign o_cdb = cdb_bus_comb;

  // Reconstruct CDB broadcast with reset-qualified valid for downstream consumers
  riscv_pkg::cdb_broadcast_t cdb_bus_qualified;
  always_comb begin
    cdb_bus_qualified       = cdb_bus;
    cdb_bus_qualified.valid = cdb_bus_valid;
  end

  // Derive ROB CDB write from CDB broadcast
  riscv_pkg::reorder_buffer_cdb_write_t cdb_write_from_arbiter;
  always_comb begin
    cdb_write_from_arbiter.valid     = cdb_bus_valid;
    cdb_write_from_arbiter.tag       = cdb_bus.tag;
    cdb_write_from_arbiter.value     = cdb_bus.value;
    cdb_write_from_arbiter.exception = cdb_bus.exception;
    cdb_write_from_arbiter.exc_cause = cdb_bus.exc_cause;
    cdb_write_from_arbiter.fp_flags  = cdb_bus.fp_flags;
  end

  // ===========================================================================
  // Dispatch Routing: decode rs_type to per-RS dispatch valid signals
  // ===========================================================================
  (* max_fanout = 32 *) logic int_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fmul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fdiv_rs_dispatch_valid;

  wire [2:0] dispatch_rs_type = i_rs_dispatch.rs_type;
  (* max_fanout = 32 *) logic dispatch_valid;
  assign dispatch_valid = i_rs_dispatch.valid && !i_backend_recovery_hold;

  always_comb begin
    int_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_INT);
    mul_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MUL);
    mem_rs_dispatch_valid  = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_MEM);
    fp_rs_dispatch_valid   = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FP);
    fmul_rs_dispatch_valid = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FMUL);
    fdiv_rs_dispatch_valid = dispatch_valid && (dispatch_rs_type == riscv_pkg::RS_FDIV);
  end

  // Internal full signals for mux
  logic int_rs_full_w;
  logic mul_rs_full_w;
  logic mem_rs_full_w;
  logic fp_rs_full_w;
  logic fmul_rs_full_w;
  logic fmul_rs_full_raw;
  logic fmul_rs_empty_raw;
  logic [$clog2(riscv_pkg::FmulRsDepth + 1) - 1:0] fmul_rs_count_raw;
  logic fdiv_rs_full_w;
  logic fmul_dispatch_pending_valid;
  riscv_pkg::rs_dispatch_t fmul_dispatch_pending;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch_to_rs;
  logic fmul_dispatch_dequeue;
  logic fmul_dispatch_slot_available;
  logic fmul_dispatch_pending_flushed;

  // o_rs_full: dispatch-target mux (NOT dedicated INT_RS full; use o_int_rs_full)
  always_comb begin
    case (dispatch_rs_type)
      riscv_pkg::RS_INT:  o_rs_full = int_rs_full_w;
      riscv_pkg::RS_MUL:  o_rs_full = mul_rs_full_w;
      riscv_pkg::RS_MEM:  o_rs_full = mem_rs_full_w;
      riscv_pkg::RS_FP:   o_rs_full = fp_rs_full_w;
      riscv_pkg::RS_FMUL: o_rs_full = fmul_rs_full_w;
      riscv_pkg::RS_FDIV: o_rs_full = fdiv_rs_full_w;
      default:            o_rs_full = 1'b0;
    endcase
  end

  // Per-RS full output ports (dedicated, not muxed)
  assign o_int_rs_full = int_rs_full_w;
  assign o_mul_rs_full = mul_rs_full_w;
  assign o_mem_rs_full = mem_rs_full_w;
  assign o_fp_rs_full = fp_rs_full_w;
  assign o_fmul_rs_full = fmul_rs_full_w;
  assign o_fdiv_rs_full = fdiv_rs_full_w;

  assign fmul_dispatch_dequeue = fmul_dispatch_pending_valid &&
      !fmul_rs_full_raw &&
      !speculative_flush_all &&
      !speculative_flush_en &&
      !i_backend_recovery_hold;
  assign fmul_dispatch_slot_available = !fmul_dispatch_pending_valid || fmul_dispatch_dequeue;
  assign fmul_dispatch_pending_flushed = speculative_flush_all ||
      (speculative_flush_en &&
       fmul_dispatch_pending_valid &&
       is_younger(
      fmul_dispatch_pending.rob_tag, i_flush_tag, head_tag
  ));
  assign fmul_rs_full_w = fmul_rs_full_raw ||
                         (fmul_dispatch_pending_valid && !fmul_dispatch_dequeue);
  assign o_fmul_rs_empty = fmul_rs_empty_raw && !fmul_dispatch_pending_valid;
  assign o_fmul_rs_count = fmul_rs_count_raw + {{($bits(
      o_fmul_rs_count
  ) - 1) {1'b0}}, fmul_dispatch_pending_valid};

  // ===========================================================================
  // ALU Pipeline: INT_RS issue → shim → adapter → CDB arbiter slot 0
  // ===========================================================================
  riscv_pkg::rs_issue_t    int_rs_issue_raw;  // INT_RS issue output
  riscv_pkg::rs_issue_t    int_rs_issue_w;  // INT_RS issue output
  riscv_pkg::fu_complete_t alu_shim_out;  // ALU shim → adapter
  // alu_adapter_to_arbiter declared above (forward declaration)
  logic                    alu_adapter_result_pending;
  logic                    alu_fu_busy;  // always 0 for single-cycle ALU
  logic                    int_rs_fu_ready;

  assign int_rs_fu_ready = i_rs_fu_ready & ~alu_adapter_result_pending & ~i_backend_recovery_hold;

  // ===========================================================================
  // MUL/DIV Pipeline: MUL_RS issue → shim → adapters → CDB arbiter slots 1,2
  // ===========================================================================
  riscv_pkg::rs_issue_t    mul_rs_issue_raw;  // MUL_RS issue output (internal)
  riscv_pkg::rs_issue_t    mul_rs_issue_w;  // MUL_RS issue output (internal)
  riscv_pkg::fu_complete_t mul_shim_out;  // shim MUL → adapter
  riscv_pkg::fu_complete_t div_shim_out;  // shim DIV → adapter
  // mul/div_adapter_to_arbiter declared above (forward declaration)
  logic                    mul_adapter_result_pending;
  logic                    div_adapter_result_pending;
  logic                    muldiv_busy;
  logic                    mul_rs_fu_ready;

  assign mul_rs_fu_ready = i_mul_rs_fu_ready & ~muldiv_busy
                           & ~mul_adapter_result_pending & ~div_adapter_result_pending
                           & ~i_backend_recovery_hold;

  // DIV result accepted: the adapter consumes the shim's output this cycle.
  // Either the adapter is idle and the shim presents a valid result (pass-through),
  // or the adapter is pending, gets granted, and the shim presents a new valid result.
  logic div_result_accepted;
  assign div_result_accepted =
      !speculative_flush_all &&
      ((!div_adapter_result_pending && div_shim_out.valid) ||
      (div_adapter_result_pending && o_cdb_grant[2] && div_shim_out.valid));

  // ===========================================================================
  // MEM (Load) Pipeline: LQ → adapter → CDB arbiter slot 3
  // ===========================================================================
  riscv_pkg::fu_complete_t lq_fu_complete;  // LQ → adapter
  // mem_adapter_to_arbiter declared above (forward declaration)
  logic mem_adapter_result_pending;
  logic lq_result_accepted;

  // ===========================================================================
  // SQ ↔ LQ Internal Wiring (store-to-load forwarding)
  // ===========================================================================
  logic sq_check_valid;
  logic [riscv_pkg::XLEN-1:0] sq_check_addr;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_check_rob_tag;
  riscv_pkg::mem_size_e sq_check_size;
  logic sq_all_older_addrs_known;
  riscv_pkg::sq_forward_result_t sq_forward;

  logic sq_cache_invalidate_valid;
  logic [riscv_pkg::XLEN-1:0] sq_cache_invalidate_addr;

  // ===========================================================================
  // Atomics Wiring (LR/SC/AMO support)
  // ===========================================================================
  // Reservation register (LQ → ROB)
  logic lq_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] lq_reservation_addr;

  // SQ committed-empty (SQ → LQ, ROB)
  logic sq_committed_empty;

  // SC clear reservation: on any SC commit (success or failure clears reservation)
  // Uses pipelined commit bus to break ROB → LQ/SQ critical path.
  logic sc_clear_reservation;
  assign sc_clear_reservation = commit_bus_q_valid && commit_q_is_sc;

  // Reservation snoop invalidation: SQ write to reservation address
  logic reservation_snoop_invalidate;
  assign reservation_snoop_invalidate = sq_cache_invalidate_valid &&
      lq_reservation_valid &&
      (sq_cache_invalidate_addr[riscv_pkg::XLEN-1:2] == lq_reservation_addr[riscv_pkg::XLEN-1:2]);

  // SC discard: failed SC invalidates its SQ entry
  // Uses pipelined commit bus to break ROB → SQ critical path.
  logic sc_discard;
  assign sc_discard = commit_bus_q_valid && commit_q_sc_failed;

  // ===========================================================================
  // SC Pending Register: SC waits for ROB head + SQ committed-empty
  // ===========================================================================
  logic sc_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sc_pending_rob_tag;
  logic [riscv_pkg::XLEN-1:0] sc_pending_addr;
  logic mem_rs_next_is_sc;
  // Forward declaration (assigned in SQ address section below)
  logic [riscv_pkg::XLEN-1:0] sq_effective_addr;

  // Age comparison for SC flush guard (identical to load_queue/reservation_station)
  function automatic logic is_younger(input logic [riscv_pkg::ReorderBufferTagWidth-1:0] entry_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] head);
    logic [riscv_pkg::ReorderBufferTagWidth:0] entry_age;
    logic [riscv_pkg::ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // SC result computation (combinational)
  logic sc_can_fire;
  logic sc_success;
  logic sc_fu_complete_valid;
  logic store_issue_fire;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] store_complete_tag;

  assign sc_can_fire = sc_pending && (sc_pending_rob_tag == head_tag) && sq_committed_empty;
  assign sc_success = lq_reservation_valid
      && (lq_reservation_addr[riscv_pkg::XLEN-1:2] == sc_pending_addr[riscv_pkg::XLEN-1:2]);
  assign sc_fu_complete_valid = sc_can_fire && !mem_adapter_result_pending &&
                                !speculative_flush_all;

  // SC fu_complete generation
  riscv_pkg::fu_complete_t sc_fu_complete;
  always_comb begin
    sc_fu_complete       = '0;
    sc_fu_complete.valid = sc_fu_complete_valid;
    sc_fu_complete.tag   = sc_pending_rob_tag;
    sc_fu_complete.value = {{(riscv_pkg::FLEN - 1) {1'b0}}, ~sc_success};
  end

  // Store completion: stores are "done" immediately after MEM_RS issue
  // (address + data go to SQ; ROB just needs to know the store completed).
  // SC_W is excluded — it has its own completion path above.
  assign store_issue_fire = o_mem_rs_issue.valid && sq_issue_is_store &&
                            (o_mem_rs_issue.op != riscv_pkg::SC_W);
  assign store_complete_tag = o_mem_rs_issue.rob_tag;

  // MUX: SC > LQ for MEM adapter input. Plain stores mark the ROB done
  // directly and do not need to occupy the shared MEM adapter/CDB slot.
  riscv_pkg::fu_complete_t mem_fu_to_adapter;
  always_comb begin
    if (sc_fu_complete.valid) mem_fu_to_adapter = sc_fu_complete;
    else mem_fu_to_adapter = lq_fu_complete;
  end

  assign lq_result_accepted = !speculative_flush_all &&
                              lq_fu_complete.valid &&
                              !sc_fu_complete_valid &&
                              !mem_adapter_result_pending;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sc_pending <= 1'b0;
    end else if (speculative_flush_all) begin
      sc_pending <= 1'b0;
    end else begin
      // Set when MEM_RS issues SC.  Gate with flush signals because
      // the RS output valid is no longer suppressed during flush for
      // timing closure — a phantom SC set during partial flush would
      // leave sc_pending stuck (the flushed tag never reaches head).
      if (o_mem_rs_issue.valid && !speculative_flush_all && !speculative_flush_en
          && (o_mem_rs_issue.op == riscv_pkg::SC_W)) begin
        sc_pending <= 1'b1;
      end
      // Clear when SC fu_complete fires (accepted by adapter)
      if (sc_fu_complete_valid) begin
        sc_pending <= 1'b0;
      end
      // A pending SC is speculative if it is younger than the flush boundary,
      // or if recovery is draining everything younger than the current/just-
      // retired head.
      if (i_flush_en && sc_pending && (speculative_partial_flush || is_younger(
              sc_pending_rob_tag, i_flush_tag, head_tag
          ))) begin
        sc_pending <= 1'b0;
      end
    end
  end

  // SC data capture (no reset - gated by sc_pending)
  always_ff @(posedge i_clk) begin
    if (o_mem_rs_issue.valid && !speculative_flush_all && !speculative_flush_en
        && (o_mem_rs_issue.op == riscv_pkg::SC_W)) begin
      sc_pending_rob_tag <= o_mem_rs_issue.rob_tag;
      sc_pending_addr    <= sq_effective_addr;
    end
  end

  // ===========================================================================
  // FP_ADD Pipeline: FP_RS issue → fp_add_shim → adapter → CDB arbiter slot 4
  // ===========================================================================
  riscv_pkg::rs_issue_t fp_rs_issue_raw;  // FP_RS issue output (internal)
  riscv_pkg::rs_issue_t fp_rs_issue_w;  // FP_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_add_shim_out;  // shim → adapter
  // fp_add_adapter_to_arbiter declared above (forward declaration)
  logic fp_add_adapter_result_pending;
  logic fp_add_busy;
  logic fp_rs_fu_ready;

  assign fp_rs_fu_ready = i_fp_rs_fu_ready & ~fp_add_busy &
                          ~fp_add_adapter_result_pending & ~i_backend_recovery_hold;

  // ===========================================================================
  // FP_MUL Pipeline: FMUL_RS issue → fp_mul_shim → adapter → CDB arbiter slot 5
  // ===========================================================================
  riscv_pkg::rs_issue_t    fmul_rs_issue_raw;  // FMUL_RS issue output (internal)
  riscv_pkg::rs_issue_t    fmul_rs_issue_w;  // FMUL_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_mul_shim_out;
  // fp_mul_adapter_to_arbiter declared above (forward declaration)
  logic                    fp_mul_adapter_result_pending;
  logic                    fp_mul_busy;
  logic                    fmul_rs_fu_ready;

  assign fmul_rs_fu_ready = i_fmul_rs_fu_ready & ~fp_mul_busy &
                            ~fp_mul_adapter_result_pending & ~i_backend_recovery_hold;

  // ===========================================================================
  // FP_DIV Pipeline: FDIV_RS issue → fp_div_shim → adapter → CDB arbiter slot 6
  // ===========================================================================
  riscv_pkg::rs_issue_t    fdiv_rs_issue_raw;  // FDIV_RS issue output (internal)
  riscv_pkg::rs_issue_t    fdiv_rs_issue_w;  // FDIV_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_div_shim_out;
  // fp_div_adapter_to_arbiter declared above (forward declaration)
  logic                    fp_div_adapter_result_pending;
  logic                    fp_div_busy;
  logic                    fdiv_rs_fu_ready;

  assign fdiv_rs_fu_ready = i_fdiv_rs_fu_ready & ~fp_div_busy &
                            ~fp_div_adapter_result_pending & ~i_backend_recovery_hold;

  riscv_pkg::rs_issue_t mem_rs_issue_raw;
  riscv_pkg::rs_issue_t mem_rs_issue_w;

  always_comb begin
    int_rs_issue_w = int_rs_issue_raw;
    if (i_backend_recovery_hold) int_rs_issue_w.valid = 1'b0;

    mul_rs_issue_w = mul_rs_issue_raw;
    if (i_backend_recovery_hold) mul_rs_issue_w.valid = 1'b0;

    mem_rs_issue_w = mem_rs_issue_raw;
    if (i_backend_recovery_hold) mem_rs_issue_w.valid = 1'b0;

    fp_rs_issue_w = fp_rs_issue_raw;
    if (i_backend_recovery_hold) fp_rs_issue_w.valid = 1'b0;

    fmul_rs_issue_w = fmul_rs_issue_raw;
    if (i_backend_recovery_hold) fmul_rs_issue_w.valid = 1'b0;

    fdiv_rs_issue_w = fdiv_rs_issue_raw;
    if (i_backend_recovery_hold) fdiv_rs_issue_w.valid = 1'b0;
  end

  // FP DIV result accepted: the adapter consumes the shim's output this cycle.
  // Either the adapter is idle and the shim presents a valid result (pass-through),
  // or the adapter is pending, gets granted, and the shim presents a new valid result.
  logic fp_div_result_accepted;
  assign fp_div_result_accepted =
      !speculative_flush_all &&
      ((!fp_div_adapter_result_pending && fp_div_shim_out.valid) ||
      (fp_div_adapter_result_pending && o_cdb_grant[6] && fp_div_shim_out.valid));

  // ===========================================================================
  // Reorder Buffer Instance
  // ===========================================================================
  reorder_buffer u_rob (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation
      .i_alloc_req (i_alloc_req),
      .o_alloc_resp(o_alloc_resp),

      // CDB (from arbiter)
      .i_cdb_write(cdb_write_from_arbiter),
      .i_store_complete_valid(store_issue_fire),
      .i_store_complete_tag(store_complete_tag),

      // Branch
      .i_branch_update(i_branch_update),

      // Checkpoint recording
      .i_checkpoint_valid(i_rob_checkpoint_valid),
      .i_checkpoint_id   (i_rob_checkpoint_id),

      // Commit output -> internal bus + registered observation
      .o_commit                             (),
      .o_commit_comb                        (commit_bus),
      .o_commit_valid_raw                   (commit_valid_raw),
      .o_commit_store_like_raw              (commit_store_like_raw),
      .o_commit_misprediction_raw           (o_commit_misprediction_raw),
      .o_commit_correct_branch_raw          (o_commit_correct_branch_raw),
      .o_head_commit_misprediction_candidate(o_head_commit_misprediction_candidate),

      // External coordination
      .i_sq_empty          (o_sq_empty),
      .i_sq_committed_empty(sq_committed_empty),
      .o_csr_start         (o_csr_start),
      .i_csr_done          (i_csr_done),
      .o_trap_pending      (o_trap_pending),
      .o_trap_pc           (o_trap_pc),
      .o_trap_cause        (o_trap_cause),
      .i_trap_taken        (i_trap_taken),
      .o_mret_start        (o_mret_start),
      .i_mret_done         (i_mret_done),
      .i_mepc              (i_mepc),
      .i_interrupt_pending (i_interrupt_pending),

      // Flush
      .i_flush_en(i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(full_flush_all),
      .i_flush_after_head_commit(i_flush_after_head_commit),

      // Early misprediction recovery
      .i_early_recovery_flush(i_early_recovery_flush),
      .i_early_recovery_en(i_early_recovery_en),
      .i_early_recovery_tag(i_early_recovery_tag),

      // Status
      .o_fence_i_flush(o_fence_i_flush),
      .o_full         (o_rob_full),
      .o_empty        (o_rob_empty),
      .o_count        (o_rob_count),
      .o_head_tag     (o_head_tag),
      .o_head_valid   (o_head_valid),
      .o_head_done    (o_head_done),
      .o_entry_valid  (rob_entry_valid),
      .o_entry_done   (rob_entry_done),
      .o_perf_events  (rob_perf_events),

      // Bypass read
      .i_read_tag  (i_read_tag),
      .o_read_done (o_read_done),
      .o_read_value(o_read_value),

      // Dispatch bypass value read
      .i_bypass_tag_1  (i_bypass_tag_1),
      .o_bypass_value_1(bypass_value_1),
      .i_bypass_tag_2  (i_bypass_tag_2),
      .o_bypass_value_2(bypass_value_2),
      .i_bypass_tag_3  (i_bypass_tag_3),
      .o_bypass_value_3(bypass_value_3),

      // Buffered FMUL repair reads
      .i_fmul_pending_bypass_tag_1  (fmul_dispatch_pending.src1_tag),
      .o_fmul_pending_bypass_value_1(fmul_pending_bypass_value_1),
      .i_fmul_pending_bypass_tag_2  (fmul_dispatch_pending.src2_tag),
      .o_fmul_pending_bypass_value_2(fmul_pending_bypass_value_2),
      .i_fmul_pending_bypass_tag_3  (fmul_dispatch_pending.src3_tag),
      .o_fmul_pending_bypass_value_3(fmul_pending_bypass_value_3)
  );

  assign o_bypass_value_1 = bypass_value_1;
  assign o_bypass_value_2 = bypass_value_2;
  assign o_bypass_value_3 = bypass_value_3;

  // ===========================================================================
  // Register Alias Table Instance
  // ===========================================================================
  register_alias_table u_rat (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Source lookups
      .i_int_src1_addr(i_int_src1_addr),
      .i_int_src2_addr(i_int_src2_addr),
      .o_int_src1     (o_int_src1),
      .o_int_src2     (o_int_src2),
      .i_fp_src1_addr (i_fp_src1_addr),
      .i_fp_src2_addr (i_fp_src2_addr),
      .i_fp_src3_addr (i_fp_src3_addr),
      .o_fp_src1      (o_fp_src1),
      .o_fp_src2      (o_fp_src2),
      .o_fp_src3      (o_fp_src3),

      // Regfile data
      .i_int_regfile_data1(i_int_regfile_data1),
      .i_int_regfile_data2(i_int_regfile_data2),
      .i_fp_regfile_data1 (i_fp_regfile_data1),
      .i_fp_regfile_data2 (i_fp_regfile_data2),
      .i_fp_regfile_data3 (i_fp_regfile_data3),

      // Rename
      .i_alloc_valid   (i_rat_alloc_valid),
      .i_alloc_dest_rf (i_rat_alloc_dest_rf),
      .i_alloc_dest_reg(i_rat_alloc_dest_reg),
      .i_alloc_rob_tag (i_rat_alloc_rob_tag),

      // Commit clear (pipelined — breaks ROB → RAT critical path)
      .i_commit_valid     (commit_bus_q_valid),
      .i_commit_dest_valid(commit_q_dest_valid),
      .i_commit_dest_rf   (commit_q_dest_rf),
      .i_commit_dest_reg  (commit_q_dest_reg),
      .i_commit_tag       (commit_q_tag),

      // Checkpoint save
      .i_checkpoint_save      (i_checkpoint_save),
      .i_checkpoint_id        (i_checkpoint_id),
      .i_checkpoint_branch_tag(i_checkpoint_branch_tag),
      .i_ras_tos              (i_ras_tos),
      .i_ras_valid_count      (i_ras_valid_count),

      // Checkpoint restore
      .i_checkpoint_restore            (i_checkpoint_restore),
      .i_checkpoint_restore_id         (i_checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(i_checkpoint_restore_reclaim_all),
      .i_checkpoint_reclaim_mask       (i_checkpoint_reclaim_mask),
      .i_checkpoint_flush_free_mask    (i_checkpoint_flush_free_mask),
      .o_ras_tos                       (o_ras_tos),
      .o_ras_valid_count               (o_ras_valid_count),

      // Checkpoint free
      .i_checkpoint_free   (i_checkpoint_free),
      .i_checkpoint_free_id(i_checkpoint_free_id),

      // ROB entry valid (stale rename detection)
      .i_rob_entry_valid(rob_entry_valid),
      .i_rob_entry_epoch(i_rob_entry_epoch),
      .i_rob_head_tag   (head_tag),

      // Flush
      .i_flush_all(full_flush_all),

      // Checkpoint availability
      .o_checkpoint_available(o_checkpoint_available),
      .o_checkpoint_alloc_id (o_checkpoint_alloc_id)
  );

  // ===========================================================================
  // Reservation Station Instances
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // INT_RS (depth 8): Integer ALU ops, branches, CSR
  // ---------------------------------------------------------------------------
  // Packed struct port connections.

  // INT_RS dispatch with routed valid
  riscv_pkg::rs_dispatch_t int_rs_dispatch;
  logic                    int_rs_issue_writes_cdb_hint;
  always_comb begin
    int_rs_dispatch       = i_rs_dispatch;
    int_rs_dispatch.valid = int_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::IntRsDepth),
      .TRACK_INT_WRITEBACK_HINT(1'b1)
  ) u_int_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch
      .i_dispatch(int_rs_dispatch),
      .o_full    (int_rs_full_w),

      // CDB snoop (from arbiter)
      .i_cdb(cdb_bus_qualified),

      // Issue (to internal wire for ALU shim)
      .o_issue(int_rs_issue_raw),
      .i_fu_ready(int_rs_fu_ready),
      .o_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint),
      .o_next_issue_is_sc(),  // unused — no SC ops in INT_RS

      // Flush (shared with ROB)
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (speculative_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count)
  );

  // Observation port: expose INT_RS issue for testbench
  assign o_rs_issue = int_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MUL_RS (depth 4): Integer multiply/divide
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mul_rs_dispatch;
  always_comb begin
    mul_rs_dispatch       = i_rs_dispatch;
    mul_rs_dispatch.valid = mul_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MulRsDepth)
  ) u_mul_rs (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_dispatch             (mul_rs_dispatch),
      .o_full                 (mul_rs_full_w),
      .i_cdb                  (cdb_bus_qualified),
      .o_issue                (mul_rs_issue_raw),
      .i_fu_ready             (mul_rs_fu_ready),
      .o_issue_writes_cdb_hint(),
      .o_next_issue_is_sc     (),                       // unused — no SC ops in MUL_RS
      .i_flush_en             (speculative_flush_en),
      .i_flush_tag            (i_flush_tag),
      .i_rob_head_tag         (head_tag),
      .i_flush_all            (speculative_flush_all),
      .o_empty                (o_mul_rs_empty),
      .o_count                (o_mul_rs_count)
  );

  // Observation port: expose MUL_RS issue for testbench
  assign o_mul_rs_issue = mul_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MEM_RS (depth 8): Loads/stores (both INT and FP)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  always_comb begin
    mem_rs_dispatch       = i_rs_dispatch;
    mem_rs_dispatch.valid = mem_rs_dispatch_valid;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MemRsDepth),
      .BYPASS_STAGE2(1'b0)
  ) u_mem_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(mem_rs_dispatch),
      .o_full(mem_rs_full_w),
      .i_cdb(cdb_bus_qualified),
      .o_issue(mem_rs_issue_raw),
      .i_fu_ready             (i_mem_rs_fu_ready && !(sc_pending && mem_rs_next_is_sc) &&
                               !i_backend_recovery_hold),
      .o_issue_writes_cdb_hint(),
      .o_next_issue_is_sc(mem_rs_next_is_sc),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all(speculative_flush_all),
      .o_empty(o_mem_rs_empty),
      .o_count(o_mem_rs_count)
  );

  assign o_mem_rs_issue = mem_rs_issue_w;

  // ---------------------------------------------------------------------------
  // Resolve FRM_DYN at dispatch time (shared by all FP RS)
  // Clamp reserved frm CSR values (5–7) to RNE for safety.
  // ---------------------------------------------------------------------------
  wire [2:0] frm_safe = (i_frm_csr > riscv_pkg::FRM_RMM) ? riscv_pkg::FRM_RNE : i_frm_csr;
  wire [2:0] rm_resolved = (i_rs_dispatch.rm == riscv_pkg::FRM_DYN) ? frm_safe : i_rs_dispatch.rm;

  // ---------------------------------------------------------------------------
  // FP_RS (depth 6): FP add/sub/cmp/cvt/classify/sgnj
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  always_comb begin
    fp_rs_dispatch       = i_rs_dispatch;
    fp_rs_dispatch.valid = fp_rs_dispatch_valid;
    fp_rs_dispatch.rm    = rm_resolved;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth)
  ) u_fp_rs (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_dispatch             (fp_rs_dispatch),
      .o_full                 (fp_rs_full_w),
      .i_cdb                  (cdb_bus_qualified),
      .o_issue                (fp_rs_issue_raw),
      .i_fu_ready             (fp_rs_fu_ready),
      .o_issue_writes_cdb_hint(),
      .o_next_issue_is_sc     (),                       // unused — no SC ops in FP_RS
      .i_flush_en             (speculative_flush_en),
      .i_flush_tag            (i_flush_tag),
      .i_rob_head_tag         (head_tag),
      .i_flush_all            (speculative_flush_all),
      .o_empty                (o_fp_rs_empty),
      .o_count                (o_fp_rs_count)
  );

  // ---------------------------------------------------------------------------
  // FMUL_RS (depth 4): FP multiply/FMA (3 sources)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch;
  always_comb begin
    fmul_rs_dispatch             = i_rs_dispatch;
    fmul_rs_dispatch.valid       = fmul_rs_dispatch_valid;
    fmul_rs_dispatch.rm          = rm_resolved;

    fmul_rs_dispatch_to_rs       = fmul_dispatch_pending;
    fmul_rs_dispatch_to_rs.valid = fmul_dispatch_dequeue;

    // Repair operands that completed while buffered outside the RS by
    // re-reading the ROB value store at dequeue time.
    //
    // Do not require rob_entry_valid here: an older producer can commit while a
    // younger FMUL is still buffered outside the RS, but its value remains in
    // the ROB value RAM until that tag is reused.
    if (fmul_dispatch_pending_valid && !fmul_dispatch_pending.src1_ready &&
        rob_entry_done[fmul_dispatch_pending.src1_tag]) begin
      fmul_rs_dispatch_to_rs.src1_ready = 1'b1;
      fmul_rs_dispatch_to_rs.src1_value = fmul_pending_bypass_value_1;
    end
    if (fmul_dispatch_pending_valid && !fmul_dispatch_pending.src2_ready &&
        rob_entry_done[fmul_dispatch_pending.src2_tag]) begin
      fmul_rs_dispatch_to_rs.src2_ready = 1'b1;
      fmul_rs_dispatch_to_rs.src2_value = fmul_pending_bypass_value_2;
    end
    if (fmul_dispatch_pending_valid && !fmul_dispatch_pending.src3_ready &&
        rob_entry_done[fmul_dispatch_pending.src3_tag]) begin
      fmul_rs_dispatch_to_rs.src3_ready = 1'b1;
      fmul_rs_dispatch_to_rs.src3_value = fmul_pending_bypass_value_3;
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fmul_dispatch_pending_valid <= 1'b0;
    end else if (fmul_dispatch_pending_flushed) begin
      fmul_dispatch_pending_valid <= 1'b0;
    end else if (fmul_rs_dispatch.valid && fmul_dispatch_slot_available &&
                 !speculative_flush_all && !speculative_flush_en) begin
      fmul_dispatch_pending_valid <= 1'b1;
    end else if (fmul_dispatch_dequeue) begin
      fmul_dispatch_pending_valid <= 1'b0;
    end
  end

  // FMUL dispatch data capture (no reset - gated by fmul_dispatch_pending_valid)
  always_ff @(posedge i_clk) begin
    if (fmul_rs_dispatch.valid && fmul_dispatch_slot_available &&
        !speculative_flush_all && !speculative_flush_en) begin
      fmul_dispatch_pending <= fmul_rs_dispatch;
    end
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FmulRsDepth)
  ) u_fmul_rs (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_dispatch             (fmul_rs_dispatch_to_rs),
      .o_full                 (fmul_rs_full_raw),
      .i_cdb                  (cdb_bus_qualified),
      .o_issue                (fmul_rs_issue_raw),
      .i_fu_ready             (fmul_rs_fu_ready),
      .o_issue_writes_cdb_hint(),
      .o_next_issue_is_sc     (),                        // unused — no SC ops in FMUL_RS
      .i_flush_en             (speculative_flush_en),
      .i_flush_tag            (i_flush_tag),
      .i_rob_head_tag         (head_tag),
      .i_flush_all            (speculative_flush_all),
      .o_empty                (fmul_rs_empty_raw),
      .o_count                (fmul_rs_count_raw)
  );

  // ---------------------------------------------------------------------------
  // FDIV_RS (depth 2): FP divide/sqrt (long latency)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch;
  always_comb begin
    fdiv_rs_dispatch       = i_rs_dispatch;
    fdiv_rs_dispatch.valid = fdiv_rs_dispatch_valid;
    fdiv_rs_dispatch.rm    = rm_resolved;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FdivRsDepth)
  ) u_fdiv_rs (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_dispatch             (fdiv_rs_dispatch),
      .o_full                 (fdiv_rs_full_w),
      .i_cdb                  (cdb_bus_qualified),
      .o_issue                (fdiv_rs_issue_raw),
      .i_fu_ready             (fdiv_rs_fu_ready),
      .o_issue_writes_cdb_hint(),
      .o_next_issue_is_sc     (),                       // unused — no SC ops in FDIV_RS
      .i_flush_en             (speculative_flush_en),
      .i_flush_tag            (i_flush_tag),
      .i_rob_head_tag         (head_tag),
      .i_flush_all            (speculative_flush_all),
      .o_empty                (o_fdiv_rs_empty),
      .o_count                (o_fdiv_rs_count)
  );

  // Observation ports: expose FP RS issue for testbench
  assign o_fp_rs_issue   = fp_rs_issue_w;
  assign o_fmul_rs_issue = fmul_rs_issue_w;
  assign o_fdiv_rs_issue = fdiv_rs_issue_w;

  // ===========================================================================
  // ALU Shim: translate rs_issue_t → ALU → fu_complete_t
  // ===========================================================================
  int_alu_shim u_alu_shim (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_rs_issue             (int_rs_issue_w),
      .i_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint),
      .i_csr_read_data        (i_csr_read_data),
      .o_fu_complete          (alu_shim_out),
      .o_fu_busy              (alu_fu_busy)
  );

  // ===========================================================================
  // ALU CDB Adapter: result holding register between ALU and CDB arbiter
  // ===========================================================================
  fu_cdb_adapter u_alu_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (alu_shim_out),
      .o_fu_complete   (alu_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[0]),
      .o_result_pending(alu_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // MUL/DIV Shim: translate rs_issue_t → multiplier/divider → fu_complete_t
  // ===========================================================================
  int_muldiv_shim u_muldiv_shim (
      .i_clk            (i_clk),
      .i_rst_n          (i_rst_n),
      .i_rs_issue       (mul_rs_issue_w),
      .o_mul_fu_complete(mul_shim_out),
      .o_div_fu_complete(div_shim_out),
      .o_fu_busy        (muldiv_busy),
      .i_flush          (speculative_flush_all),
      .i_flush_en       (speculative_flush_en),
      .i_flush_tag      (i_flush_tag),
      .i_rob_head_tag   (head_tag),
      .i_div_accepted   (div_result_accepted)
  );

  // ===========================================================================
  // MUL CDB Adapter: result holding register → CDB arbiter slot 1
  // ===========================================================================
  fu_cdb_adapter u_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mul_shim_out),
      .o_fu_complete   (mul_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[1]),
      .o_result_pending(mul_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // DIV CDB Adapter: result holding register → CDB arbiter slot 2
  // ===========================================================================
  fu_cdb_adapter u_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (div_shim_out),
      .o_fu_complete   (div_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[2]),
      .o_result_pending(div_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // Load Queue: Allocation from Dispatch
  // ===========================================================================
  // Determine if the dispatched MEM_RS instruction is a load
  logic lq_alloc_is_load;
  always_comb begin
    case (i_rs_dispatch.op)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LR_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W, riscv_pkg::AMOXOR_W,
      riscv_pkg::AMOAND_W,  riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W,  riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      lq_alloc_is_load = 1'b1;
      default: lq_alloc_is_load = 1'b0;
    endcase
  end

  riscv_pkg::lq_alloc_req_t lq_alloc_req;
  always_comb begin
    lq_alloc_req.valid = mem_rs_dispatch_valid && lq_alloc_is_load;
    lq_alloc_req.rob_tag = i_rs_dispatch.rob_tag;
    lq_alloc_req.is_fp = i_rs_dispatch.is_fp_mem;
    lq_alloc_req.size = i_rs_dispatch.mem_size;
    lq_alloc_req.sign_ext = i_rs_dispatch.mem_signed;
    lq_alloc_req.is_lr = (i_rs_dispatch.op == riscv_pkg::LR_W);
    lq_alloc_req.is_amo   = (i_rs_dispatch.op == riscv_pkg::AMOSWAP_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOADD_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOXOR_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOAND_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOOR_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOMIN_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOMAX_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOMINU_W)
                           || (i_rs_dispatch.op == riscv_pkg::AMOMAXU_W);
    lq_alloc_req.amo_op = i_rs_dispatch.op;
  end

  // ===========================================================================
  // Load Queue: Address Update from MEM_RS Issue
  // ===========================================================================
  logic lq_issue_is_load;
  always_comb begin
    case (o_mem_rs_issue.op)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LR_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W, riscv_pkg::AMOXOR_W,
      riscv_pkg::AMOAND_W,  riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W,  riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W:
      lq_issue_is_load = 1'b1;
      default: lq_issue_is_load = 1'b0;
    endcase
  end

  logic [riscv_pkg::XLEN-1:0] lq_effective_addr;
  assign lq_effective_addr = o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm;

  // MMIO detection: address >= MMIO base
  localparam logic [riscv_pkg::XLEN-1:0] MmioBase = 32'h4000_0000;
  logic lq_addr_is_mmio;
  assign lq_addr_is_mmio = (lq_effective_addr >= MmioBase);

  riscv_pkg::lq_addr_update_t lq_addr_update;
  always_comb begin
    lq_addr_update.valid   = o_mem_rs_issue.valid && lq_issue_is_load;
    lq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    lq_addr_update.address = lq_effective_addr;
    lq_addr_update.is_mmio = lq_addr_is_mmio;
    lq_addr_update.amo_rs2 = o_mem_rs_issue.src2_value[riscv_pkg::XLEN-1:0];
  end

  // ===========================================================================
  // Load Queue Instance
  // ===========================================================================
  load_queue u_lq (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation (from dispatch)
      .i_alloc(lq_alloc_req),
      .o_full (o_lq_full),

      // Address update (from MEM_RS issue)
      .i_addr_update(lq_addr_update),

      // SQ disambiguation (internal wiring to store_queue)
      .o_sq_check_valid          (sq_check_valid),
      .o_sq_check_addr           (sq_check_addr),
      .o_sq_check_rob_tag        (sq_check_rob_tag),
      .o_sq_check_size           (sq_check_size),
      .i_sq_all_older_addrs_known(sq_all_older_addrs_known),
      .i_sq_forward              (sq_forward),

      // Memory interface (external)
      .o_mem_read_en   (o_lq_mem_read_en),
      .o_mem_read_addr (o_lq_mem_read_addr),
      .o_mem_read_size (o_lq_mem_read_size),
      .i_mem_read_data (i_lq_mem_read_data),
      .i_mem_read_valid(i_lq_mem_read_valid),
      // AMO writes share the same external data-memory port as load reads.
      // Treat them as bus-busy so the LQ cannot issue a younger load or
      // take a stale L0-cache fast path in the AMO write-completion cycle.
      .i_mem_bus_busy  (o_sq_mem_write_en || o_amo_mem_write_en || i_backend_recovery_hold),

      // CDB result (to MEM adapter; back-pressured when SC or store uses the slot)
      .o_fu_complete(lq_fu_complete),
      .i_adapter_result_pending(mem_adapter_result_pending || sc_fu_complete_valid),
      .i_result_accepted(lq_result_accepted),

      // ROB head tag (for MMIO ordering)
      .i_rob_head_tag(head_tag),

      // Reservation register (LR/SC)
      .o_reservation_valid           (lq_reservation_valid),
      .o_reservation_addr            (lq_reservation_addr),
      .i_sc_clear_reservation        (sc_clear_reservation),
      .i_reservation_snoop_invalidate(reservation_snoop_invalidate),

      // SQ empty / committed-empty (for issue gating)
      .i_sq_empty(o_sq_empty),
      .i_sq_committed_empty(sq_committed_empty),

      // AMO memory write interface
      .o_amo_mem_write_en  (o_amo_mem_write_en),
      .o_amo_mem_write_addr(o_amo_mem_write_addr),
      .o_amo_mem_write_data(o_amo_mem_write_data),
      .i_amo_mem_write_done(i_amo_mem_write_done),

      // L0 cache invalidation (from SQ)
      .i_cache_invalidate_valid(sq_cache_invalidate_valid),
      .i_cache_invalidate_addr (sq_cache_invalidate_addr),

      // Flush
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(speculative_flush_all),
      .i_early_recovery_flush(i_early_recovery_flush),

      // Status
      .o_empty(o_lq_empty),
      .o_count(o_lq_count)
  );

  // ===========================================================================
  // MEM CDB Adapter: result holding register → CDB arbiter slot 3
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
  ) u_mem_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mem_fu_to_adapter),
      .o_fu_complete   (mem_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[3]),
      .o_result_pending(mem_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // Store Queue: Allocation from Dispatch
  // ===========================================================================
  // Determine if the dispatched MEM_RS instruction is a store
  logic sq_alloc_is_store;
  always_comb begin
    case (i_rs_dispatch.op)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::FSW, riscv_pkg::FSD, riscv_pkg::SC_W:
      sq_alloc_is_store = 1'b1;
      default: sq_alloc_is_store = 1'b0;
    endcase
  end

  riscv_pkg::sq_alloc_req_t sq_alloc_req;
  always_comb begin
    sq_alloc_req.valid   = mem_rs_dispatch_valid && sq_alloc_is_store;
    sq_alloc_req.rob_tag = i_rs_dispatch.rob_tag;
    sq_alloc_req.is_fp   = i_rs_dispatch.is_fp_mem;
    sq_alloc_req.size    = i_rs_dispatch.mem_size;
    sq_alloc_req.is_sc   = (i_rs_dispatch.op == riscv_pkg::SC_W);
    // Address is computed in a pipelined stage (see early_addr_update below)
    // to break the critical RAT → dispatch → 32-bit adder → SQ path.
    sq_alloc_req.addr_valid = 1'b0;
    sq_alloc_req.address    = '0;
    sq_alloc_req.is_mmio    = 1'b0;
  end

  // ===========================================================================
  // Pipelined early store address: register dispatch base+imm, compute next cycle
  // ===========================================================================
  // Breaks the 20-level RAT → ROB bypass → dispatch value → CARRY8 adder → SQ
  // critical path by deferring the 32-bit addition by one cycle.
  logic sq_early_addr_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_rob_tag_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_base_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_imm_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      sq_early_addr_valid_q <= 1'b0;
    end else begin
      sq_early_addr_valid_q   <= sq_alloc_req.valid && !o_sq_full && i_rs_dispatch.src1_ready;
      sq_early_addr_rob_tag_q <= i_rs_dispatch.rob_tag;
      sq_early_addr_base_q    <= i_rs_dispatch.src1_value[riscv_pkg::XLEN-1:0];
      sq_early_addr_imm_q     <= i_rs_dispatch.imm;
    end
  end

  // Adder now runs on registered inputs — off the dispatch critical path
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr;
  assign sq_early_effective_addr = sq_early_addr_base_q + sq_early_addr_imm_q;

  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  always_comb begin
    sq_early_addr_update.valid   = sq_early_addr_valid_q;
    sq_early_addr_update.rob_tag = sq_early_addr_rob_tag_q;
    sq_early_addr_update.address = sq_early_effective_addr;
    sq_early_addr_update.is_mmio = (sq_early_effective_addr >= MmioBase);
  end

  // ===========================================================================
  // Store Queue: Address + Data Update from MEM_RS Issue
  // ===========================================================================
  logic sq_issue_is_store;
  always_comb begin
    case (o_mem_rs_issue.op)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::FSW, riscv_pkg::FSD, riscv_pkg::SC_W:
      sq_issue_is_store = 1'b1;
      default: sq_issue_is_store = 1'b0;
    endcase
  end

  // Effective address: base (src1) + immediate (declared above near SC pending)
  assign sq_effective_addr = o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm;

  // MMIO detection: address >= MMIO base
  logic sq_addr_is_mmio;
  assign sq_addr_is_mmio = (sq_effective_addr >= MmioBase);

  riscv_pkg::sq_addr_update_t sq_addr_update;
  always_comb begin
    sq_addr_update.valid   = o_mem_rs_issue.valid && sq_issue_is_store;
    sq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    sq_addr_update.address = sq_effective_addr;
    sq_addr_update.is_mmio = sq_addr_is_mmio;
  end

  // Data update: store data from src2_value
  riscv_pkg::sq_data_update_t sq_data_update;
  always_comb begin
    sq_data_update.valid   = o_mem_rs_issue.valid && sq_issue_is_store;
    sq_data_update.rob_tag = o_mem_rs_issue.rob_tag;
    sq_data_update.data    = o_mem_rs_issue.src2_value;
  end

  // ===========================================================================
  // Store Queue: Commit from ROB
  // ===========================================================================
  // Uses pipelined commit bus to break ROB → SQ critical path.
  logic sq_commit_valid;
  assign sq_commit_valid = commit_bus_q_valid && commit_q_is_store_like && !sc_discard;

  // ===========================================================================
  // Store Queue Instance
  // ===========================================================================
  store_queue u_sq (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation (from dispatch)
      .i_alloc(sq_alloc_req),
      .o_full (o_sq_full),

      // Early address update (pipelined dispatch-time base+imm)
      .i_early_addr_update(sq_early_addr_update),

      // Address update (from MEM_RS issue)
      .i_addr_update(sq_addr_update),

      // Data update (from MEM_RS issue)
      .i_data_update(sq_data_update),

      // Commit (pipelined — breaks ROB → SQ critical path)
      .i_commit_valid  (sq_commit_valid),
      .i_commit_rob_tag(commit_q_tag),

      // Same-cycle commit guard (combinational, for flush race protection).
      // Use the narrow raw ROB pulse instead of the wide commit bus so the
      // SQ flush-exemption path does not inherit full commit payload logic.
      .i_commit_valid_comb  (commit_store_like_raw),
      .i_commit_rob_tag_comb(head_tag),

      // Store-to-load forwarding (from LQ)
      .i_sq_check_valid          (sq_check_valid),
      .i_sq_check_addr           (sq_check_addr),
      .i_sq_check_rob_tag        (sq_check_rob_tag),
      .i_sq_check_size           (sq_check_size),
      .o_sq_all_older_addrs_known(sq_all_older_addrs_known),
      .o_sq_forward              (sq_forward),

      // Memory write interface (external)
      .o_mem_write_en     (o_sq_mem_write_en),
      .o_mem_write_addr   (o_sq_mem_write_addr),
      .o_mem_write_data   (o_sq_mem_write_data),
      .o_mem_write_byte_en(o_sq_mem_write_byte_en),
      .o_mem_write_is_mmio(o_sq_mem_write_is_mmio),
      .i_mem_write_done   (i_sq_mem_write_done),

      // L0 cache invalidation (to LQ)
      .o_cache_invalidate_valid(sq_cache_invalidate_valid),
      .o_cache_invalidate_addr (sq_cache_invalidate_addr),

      // SC discard (pipelined — uses commit_bus_q)
      .i_sc_discard        (sc_discard),
      .i_sc_discard_rob_tag(commit_q_tag),

      // ROB head tag
      .i_rob_head_tag(head_tag),

      // Flush
      .i_flush_en(i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(full_flush_all),
      .i_flush_after_head_commit(i_flush_after_head_commit),
      .i_early_recovery_flush(i_early_recovery_flush),

      // Status
      .o_empty          (o_sq_empty),
      .o_committed_empty(sq_committed_empty),
      .o_count          (o_sq_count)
  );

  // ===========================================================================
  // FP Add Shim: translate rs_issue_t → FPU subunits → fu_complete_t
  // ===========================================================================
  fp_add_shim u_fp_add_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fp_rs_issue_w),
      .o_fu_complete (fp_add_shim_out),
      .o_fu_busy     (fp_add_busy),
      .i_flush       (speculative_flush_all),
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP Add CDB Adapter: result holding register → CDB arbiter slot 4
  // ===========================================================================
  fu_cdb_adapter u_fp_add_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_add_shim_out),
      .o_fu_complete   (fp_add_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[4]),
      .o_result_pending(fp_add_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Multiply Shim: translate rs_issue_t → FPU mult/FMA → fu_complete_t
  // ===========================================================================
  fp_mul_shim u_fp_mul_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fmul_rs_issue_w),
      .o_fu_complete (fp_mul_shim_out),
      .o_fu_busy     (fp_mul_busy),
      .i_flush       (speculative_flush_all),
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP Multiply CDB Adapter: result holding register → CDB arbiter slot 5
  // ===========================================================================
  fu_cdb_adapter u_fp_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_mul_shim_out),
      .o_fu_complete   (fp_mul_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[5]),
      .o_result_pending(fp_mul_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Divide/Sqrt Shim: translate rs_issue_t → FPU div/sqrt → fu_complete_t
  // ===========================================================================
  fp_div_shim u_fp_div_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fdiv_rs_issue_w),
      .o_fu_complete (fp_div_shim_out),
      .o_fu_busy     (fp_div_busy),
      .i_flush       (speculative_flush_all),
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_div_accepted(fp_div_result_accepted)
  );

  // ===========================================================================
  // FP Divide CDB Adapter: result holding register → CDB arbiter slot 6
  // ===========================================================================
  fu_cdb_adapter u_fp_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_div_shim_out),
      .o_fu_complete   (fp_div_adapter_to_arbiter),
      .i_grant         (o_cdb_grant[6]),
      .o_result_pending(fp_div_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // Backend Profiling Counters
  // ===========================================================================
  always_comb begin
    for (int i = 0; i < WrapperPerfCounterCount; i++) begin
      perf_inc[i] = '0;
    end

    perf_inc[PerfHeadWaitTotal] = {{63{1'b0}}, rob_perf_events.head_wait_total};
    perf_inc[PerfHeadWaitInt] = {{63{1'b0}}, rob_perf_events.head_wait_int};
    perf_inc[PerfHeadWaitBranch] = {{63{1'b0}}, rob_perf_events.head_wait_branch};
    perf_inc[PerfHeadWaitMul] = {{63{1'b0}}, rob_perf_events.head_wait_mul};
    perf_inc[PerfHeadWaitMemLoad] = {{63{1'b0}}, rob_perf_events.head_wait_mem_load};
    perf_inc[PerfHeadWaitMemStore] = {{63{1'b0}}, rob_perf_events.head_wait_mem_store};
    perf_inc[PerfHeadWaitMemAmo] = {{63{1'b0}}, rob_perf_events.head_wait_mem_amo};
    perf_inc[PerfHeadWaitFp] = {{63{1'b0}}, rob_perf_events.head_wait_fp};
    perf_inc[PerfHeadWaitFmul] = {{63{1'b0}}, rob_perf_events.head_wait_fmul};
    perf_inc[PerfHeadWaitFdiv] = {{63{1'b0}}, rob_perf_events.head_wait_fdiv};
    perf_inc[PerfCommitBlockedCsr] = {{63{1'b0}}, rob_perf_events.commit_blocked_csr};
    perf_inc[PerfCommitBlockedFence] = {{63{1'b0}}, rob_perf_events.commit_blocked_fence};
    perf_inc[PerfCommitBlockedWfi] = {{63{1'b0}}, rob_perf_events.commit_blocked_wfi};
    perf_inc[PerfCommitBlockedMret] = {{63{1'b0}}, rob_perf_events.commit_blocked_mret};
    perf_inc[PerfCommitBlockedTrap] = {{63{1'b0}}, rob_perf_events.commit_blocked_trap};

    perf_inc[PerfIntBackpressure] = {{63{1'b0}}, (!int_rs_fu_ready && !o_rs_empty)};
    perf_inc[PerfMulBackpressure] = {{63{1'b0}}, (!mul_rs_fu_ready && !o_mul_rs_empty)};
    perf_inc[PerfMemResultBackpressure] = {
      {63{1'b0}}, (mem_fu_to_adapter.valid && mem_adapter_result_pending)
    };
    perf_inc[PerfFpAddBackpressure] = {{63{1'b0}}, (!fp_rs_fu_ready && !o_fp_rs_empty)};
    perf_inc[PerfFmulBackpressure] = {{63{1'b0}}, (!fmul_rs_fu_ready && !o_fmul_rs_empty)};
    perf_inc[PerfFdivBackpressure] = {{63{1'b0}}, (!fdiv_rs_fu_ready && !o_fdiv_rs_empty)};
    perf_inc[PerfMemDisambiguationWait] = {
      {63{1'b0}}, (sq_check_valid && !sq_all_older_addrs_known)
    };
    perf_inc[PerfSqCommittedPending] = {{63{1'b0}}, !sq_committed_empty};
    perf_inc[PerfSqMemWriteFire] = {{63{1'b0}}, o_sq_mem_write_en};
    perf_inc[PerfLqMemReadFire] = {{63{1'b0}}, o_lq_mem_read_en};
    perf_inc[PerfRobOccupancySum] = {{(64 - $bits(o_rob_count)) {1'b0}}, o_rob_count};
    perf_inc[PerfLqOccupancySum] = {{(64 - $bits(o_lq_count)) {1'b0}}, o_lq_count};
    perf_inc[PerfSqOccupancySum] = {{(64 - $bits(o_sq_count)) {1'b0}}, o_sq_count};
    perf_inc[PerfIntRsOccupancySum] = {{(64 - $bits(o_rs_count)) {1'b0}}, o_rs_count};
    perf_inc[PerfMulRsOccupancySum] = {{(64 - $bits(o_mul_rs_count)) {1'b0}}, o_mul_rs_count};
    perf_inc[PerfMemRsOccupancySum] = {{(64 - $bits(o_mem_rs_count)) {1'b0}}, o_mem_rs_count};
    perf_inc[PerfFpRsOccupancySum] = {{(64 - $bits(o_fp_rs_count)) {1'b0}}, o_fp_rs_count};
    perf_inc[PerfFmulRsOccupancySum] = {{(64 - $bits(o_fmul_rs_count)) {1'b0}}, o_fmul_rs_count};
    perf_inc[PerfFdivRsOccupancySum] = {{(64 - $bits(o_fdiv_rs_count)) {1'b0}}, o_fdiv_rs_count};
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      for (int i = 0; i < WrapperPerfCounterCount; i++) begin
        perf_inc_q[i] <= '0;
        perf_live[i] <= '0;
        perf_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < WrapperPerfCounterCount; i++) begin
        perf_inc_q[i] <= perf_inc[i];
        perf_live[i]  <= perf_live[i] + perf_inc_q[i];
        if (i < PerfSnapshotBankSpan) begin
          if (perf_snapshot_capture_bank0) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (i < (2 * PerfSnapshotBankSpan)) begin
          if (perf_snapshot_capture_bank1) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (i < (3 * PerfSnapshotBankSpan)) begin
          if (perf_snapshot_capture_bank2) begin
            perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
          end
        end else if (perf_snapshot_capture_bank3) begin
          perf_snapshot[i] <= perf_live[i] + perf_inc_q[i];
        end
      end
    end
  end

  always_comb begin
    o_perf_counter_data = '0;
    if (i_perf_counter_select < 8'd34) begin
      o_perf_counter_data = perf_snapshot[i_perf_counter_select[5:0]];
    end
  end


  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (from rob_rat_wrapper)
  // -------------------------------------------------------------------------

  // CDB write and branch update cannot target same tag simultaneously
  always_comb begin
  end

  // No allocation during flush
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // No rename during full flush
  always_comb assume (!(i_rat_alloc_valid && i_flush_all));

  // No rename during checkpoint restore
  always_comb assume (!(i_rat_alloc_valid && i_checkpoint_restore));

  // Checkpoint save and restore are mutually exclusive
  always_comb assume (!(i_checkpoint_save && i_checkpoint_restore));

  always_comb begin
    if (i_checkpoint_restore_reclaim_all) assume (i_checkpoint_restore);
  end

  // Shadow-track checkpoint validity
  reg [riscv_pkg::NumCheckpoints-1:0] f_cp_valid;

  initial f_cp_valid = '0;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_cp_valid <= '0;
    end else if (i_flush_all) begin
      f_cp_valid <= '0;
    end else if (i_checkpoint_restore_reclaim_all) begin
      f_cp_valid <= '0;
    end else begin
      if (i_checkpoint_save) f_cp_valid[i_checkpoint_id] <= 1'b1;
      if (i_checkpoint_free) f_cp_valid[i_checkpoint_free_id] <= 1'b0;
    end
  end

  always_comb begin
    if (i_checkpoint_restore) assume (f_cp_valid[i_checkpoint_restore_id]);
  end

  // Dispatch never renames x0 to INT
  always_comb begin
    if (i_rat_alloc_valid && !i_rat_alloc_dest_rf) assume (i_rat_alloc_dest_reg != '0);
  end

  // Dispatch tag coordination
  always_comb begin
    if (i_alloc_req.alloc_valid && i_rat_alloc_valid) begin
      assume (i_rat_alloc_rob_tag == o_alloc_resp.alloc_tag);
    end
  end

  // Checkpoint ID coordination
  always_comb begin
    if (i_rob_checkpoint_valid && i_checkpoint_save) begin
      assume (i_rob_checkpoint_id == i_checkpoint_id);
    end
  end

  // No RS dispatch during flush
  always_comb begin
    assume (!(i_rs_dispatch.valid && (i_flush_en || i_flush_all)));
  end

  // No RS dispatch when targeted RS is full
  always_comb begin
    if (o_rs_full) assume (!i_rs_dispatch.valid);
  end

  // No MEM_RS load dispatch when LQ is full
  always_comb begin
    if (o_lq_full && lq_alloc_is_load) assume (!mem_rs_dispatch_valid);
  end

  // No MEM_RS store dispatch when SQ is full
  always_comb begin
    if (o_sq_full && sq_alloc_is_store) assume (!mem_rs_dispatch_valid);
  end

  // LQ memory response only after read was issued
  always_comb begin
    assume (!(i_lq_mem_read_valid && (i_flush_en || i_flush_all)));
  end

  // SQ memory write done not during flush
  always_comb begin
    assume (!(i_sq_mem_write_done && i_flush_all));
  end

  // Dispatch routing mutual exclusion: at most one RS receives valid
  always_comb begin
    if (i_rs_dispatch.valid) begin
      p_dispatch_routes_to_exactly_one :
      assert ($onehot0(
          {
            fdiv_rs_dispatch_valid,
            fmul_rs_dispatch_valid,
            fp_rs_dispatch_valid,
            mem_rs_dispatch_valid,
            mul_rs_dispatch_valid,
            int_rs_dispatch_valid
          }
      ));
    end
  end

  // -------------------------------------------------------------------------
  // Observation: track an arbitrary INT register via lookups
  // -------------------------------------------------------------------------
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_int_track;
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_fp_track;

  always_comb begin
    assume (f_int_track != '0);
    assume (i_int_src1_addr == f_int_track);
    assume (i_fp_src1_addr == f_fp_track);
  end

  // -------------------------------------------------------------------------
  // Commit bus assertions (from rob_rat_wrapper)
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_commit_output_identity : assert (o_commit_comb == commit_bus);
      p_commit_observation_identity : assert (o_commit == commit_bus_q_qualified);
      p_commit_requires_head_ready : assert (!commit_bus.valid || (o_head_valid && o_head_done));
      p_commit_tag_is_head : assert (!commit_bus.valid || (commit_bus.tag == o_head_tag));
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: commit propagation and flush
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // INT commit clears RAT entry when tag matches.
      // RAT receives commit_bus_q (1-cycle pipelined), so check $past of
      // the registered version rather than the combinational commit_bus.
      if ($past(
              commit_bus_q_valid
          ) && $past(
              commit_bus_q.dest_valid
          ) && !$past(
              commit_bus_q.dest_rf
          ) && $past(
              commit_bus_q.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) == $past(
              commit_bus_q.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_commit_clears_int_via_bus : assert (!o_int_src1.renamed);
      end

      // INT WAW: commit does NOT clear when tag mismatches (newer rename)
      if ($past(
              commit_bus_q_valid
          ) && $past(
              commit_bus_q.dest_valid
          ) && !$past(
              commit_bus_q.dest_rf
          ) && $past(
              commit_bus_q.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) != $past(
              commit_bus_q.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_waw_preserves_newer_int : assert (o_int_src1.renamed);
      end

      // FP commit clears RAT entry when tag matches
      if ($past(
              commit_bus_q_valid
          ) && $past(
              commit_bus_q.dest_valid
          ) && $past(
              commit_bus_q.dest_rf
          ) && $past(
              commit_bus_q.dest_reg
          ) == f_fp_track && $past(
              o_fp_src1.renamed
          ) && $past(
              o_fp_src1.tag
          ) == $past(
              commit_bus_q.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && $past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_fp_track)) begin
        p_commit_clears_fp_via_bus : assert (!o_fp_src1.renamed);
      end

    end
  end

  // -------------------------------------------------------------------------
  // Sequential: rename-vs-commit same-cycle precedence
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // RAT receives commit_bus_q, so same-cycle precedence is rename
      // vs pipelined commit.
      if ($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track && $past(
              commit_bus_q_valid
          ) && $past(
              commit_bus_q.dest_valid
          ) && !$past(
              commit_bus_q.dest_rf
          ) && $past(
              commit_bus_q.dest_reg
          ) == f_int_track && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          )) begin
        p_rename_wins_over_commit :
        assert (o_int_src1.renamed && o_int_src1.tag == $past(i_rat_alloc_rob_tag));
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: flush / recovery composition
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // flush_all empties ROB
      if ($past(i_flush_all)) begin
        p_flush_all_empties_rob : assert (o_rob_empty);
      end

      // flush_all empties all RS
      if ($past(i_flush_all)) begin
        p_flush_all_empties_int_rs : assert (o_rs_empty);
        p_flush_all_empties_mul_rs : assert (o_mul_rs_empty);
        p_flush_all_empties_mem_rs : assert (o_mem_rs_empty);
        p_flush_all_empties_fp_rs : assert (o_fp_rs_empty);
        p_flush_all_empties_fmul_rs : assert (o_fmul_rs_empty);
        p_flush_all_empties_fdiv_rs : assert (o_fdiv_rs_empty);
      end

      // flush_all frees all checkpoints
      if ($past(i_flush_all)) begin
        p_flush_all_frees_checkpoints : assert (o_checkpoint_available);
      end

      // flush_all clears INT rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_int_rename : assert (!o_int_src1.renamed);
      end

      // flush_all clears FP rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_fp_rename : assert (!o_fp_src1.renamed);
      end

      // flush_all empties LQ
      if ($past(i_flush_all)) begin
        p_flush_all_empties_lq : assert (o_lq_empty);
      end

      // flush_all empties SQ
      if ($past(i_flush_all)) begin
        p_flush_all_empties_sq : assert (o_sq_empty);
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_rob_empty : assert (o_rob_empty);
      p_reset_int_rs_empty : assert (o_rs_empty);
      p_reset_mul_rs_empty : assert (o_mul_rs_empty);
      p_reset_mem_rs_empty : assert (o_mem_rs_empty);
      p_reset_fp_rs_empty : assert (o_fp_rs_empty);
      p_reset_fmul_rs_empty : assert (o_fmul_rs_empty);
      p_reset_fdiv_rs_empty : assert (o_fdiv_rs_empty);
      p_reset_checkpoints_available : assert (o_checkpoint_available);
      p_reset_int_not_renamed : assert (!o_int_src1.renamed);
      p_reset_fp_not_renamed : assert (!o_fp_src1.renamed);
      p_reset_lq_empty : assert (o_lq_empty);
      p_reset_sq_empty : assert (o_sq_empty);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // RS issue fires
      cover_rs_issue : cover (o_rs_issue.valid);

      // CDB simultaneously present with RS dispatch
      cover_cdb_and_rs_dispatch : cover (cdb_bus_valid && i_rs_dispatch.valid);

      // flush_all while RS non-empty
      cover_flush_while_rs_nonempty : cover (i_flush_all && !o_rs_empty);

      // Commit fires
      cover_commit : cover (commit_bus.valid);

      // RS full: removed -- needs 9+ steps (8 dispatches + reset) but wrapper
      // cover depth is 8.  Covered by reservation_station.sby at depth 20.

      // Commit clears tracked INT register
      cover_commit_clears_int :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag == commit_bus.tag
      );

      // Rename and commit target same INT register in same cycle
      cover_rename_commit_same_cycle :
      cover (
        i_rat_alloc_valid && !i_rat_alloc_dest_rf &&
        i_rat_alloc_dest_reg == f_int_track &&
        commit_bus.valid && commit_bus.dest_valid &&
        !commit_bus.dest_rf && commit_bus.dest_reg == f_int_track
      );

      // WAW: commit for tracked register with tag mismatch
      cover_waw_tag_mismatch :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag != commit_bus.tag
      );

      // flush_all while tracked INT register is renamed
      cover_flush_while_renamed : cover (i_flush_all && o_int_src1.renamed);

      // Checkpoint save + ROB checkpoint recording in same cycle
      cover_checkpoint_save : cover (i_checkpoint_save && i_rob_checkpoint_valid);

      // Checkpoint restore (misprediction recovery)
      cover_checkpoint_restore : cover (i_checkpoint_restore);

      // FP commit via internal bus
      cover_fp_commit_via_bus :
      cover (commit_bus.valid && commit_bus.dest_valid && commit_bus.dest_rf);

      // Dispatch routing: dispatch to each RS type
      cover_dispatch_to_mul_rs : cover (mul_rs_dispatch_valid);
      cover_dispatch_to_mem_rs : cover (mem_rs_dispatch_valid);
      cover_dispatch_to_fp_rs : cover (fp_rs_dispatch_valid);
      cover_dispatch_to_fmul_rs : cover (fmul_rs_dispatch_valid);
      cover_dispatch_to_fdiv_rs : cover (fdiv_rs_dispatch_valid);

      // LQ allocation
      cover_lq_alloc : cover (lq_alloc_req.valid);

      // LQ memory read issued
      cover_lq_mem_issue : cover (o_lq_mem_read_en);

      // SQ allocation
      cover_sq_alloc : cover (sq_alloc_req.valid);

      // SQ memory write issued
      cover_sq_mem_write : cover (o_sq_mem_write_en);

      // SQ commit
      cover_sq_commit : cover (sq_commit_valid);
    end
  end

`endif  // FORMAL

  // ===========================================================================
  // Simulation-only: assert FRM_DYN is resolved before entering FP RS
  // (FP RS dispatch signals only exist under VERILATOR)
  // ===========================================================================
`ifdef VERILATOR
  always @(posedge i_clk)
    if (i_rst_n) begin
      if (fp_rs_dispatch.valid) assert (fp_rs_dispatch.rm != riscv_pkg::FRM_DYN);
      if (fmul_rs_dispatch.valid) assert (fmul_rs_dispatch.rm != riscv_pkg::FRM_DYN);
      if (fdiv_rs_dispatch.valid) assert (fdiv_rs_dispatch.rm != riscv_pkg::FRM_DYN);
    end
`endif

endmodule
