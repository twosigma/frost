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
 * The out-of-order back end, instantiated once by cpu_ooo: the ROB, RAT, four
 * reservation stations (INT, MUL, MEM, FP), LQ, SQ, data MMU, the two-lane CDB
 * arbiter, the FU shims and CDB adapters, and the logic that connects them.
 * The README in this directory describes each part.
 *
 * cpu_ooo sets SPLIT_RS_DISPATCH=1 and drives one dispatch packet per
 * station, so a station's inputs carry only the source lookups it uses;
 * wrapper tests can leave it at 0 and use the single-slot i_rs_dispatch bus.
 * The ROB's commit outputs are combinational: o_commit_comb/_2 export them
 * for cpu_ooo's same-cycle misprediction detection, while the internal
 * consumers (RAT, SQ commit, SC logic, coherence port) use the registered
 * copies, which also drive o_commit/_2.
 */

module tomasulo_wrapper #(
    parameter bit SPLIT_RS_DISPATCH = 1'b0,
    parameter bit ENABLE_DISPATCH_DONE_REPAIR = 1'b0,
    // Address range for tagged cached-load slots and cached-store routing.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    // Share the ROB value RAM's link bank only when at most one branch allocates
    // per cycle, as cpu_ooo dispatch guarantees. The default allows any pair.
    parameter bit ROB_SHARED_LINK_BANK = 1'b0,
    // Disable back-end profiling counters and return zero when 0. cpu_ooo
    // passes its build option; the standalone default enables counters.
    parameter int unsigned PERF_COUNTERS = 1
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // FRM CSR (dynamic rounding-mode resolution at dispatch, and the ROB's
    // reserved-frm legality check)
    // =========================================================================
    input logic [2:0] i_frm_csr,

    // =========================================================================
    // ROB Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // Slot-2 allocation port for 2-wide dispatch.  alloc_valid_2 asserts only
    // when alloc_valid is also set.
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req_2,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp_2,

    // =========================================================================
    // FU Completion Test Injection (active when internal adapter is idle;
    // slots 5 and 6 have no adapter, so their injection is always active)
    // =========================================================================
    input riscv_pkg::fu_complete_t i_fu_complete_0,
    input riscv_pkg::fu_complete_t i_fu_complete_1,
    input riscv_pkg::fu_complete_t i_fu_complete_2,
    input riscv_pkg::fu_complete_t i_fu_complete_3,
    input riscv_pkg::fu_complete_t i_fu_complete_4,
    input riscv_pkg::fu_complete_t i_fu_complete_5,
    input riscv_pkg::fu_complete_t i_fu_complete_6,
    input riscv_pkg::fu_complete_t i_fu_complete_7,

    // =========================================================================
    // CDB Grant (back-pressure to FUs)
    // =========================================================================
    output logic [riscv_pkg::NumFus-1:0] o_cdb_grant,

    // =========================================================================
    // CDB Broadcast Output (observation only: test benches and debug; both lanes)
    // =========================================================================
    output riscv_pkg::cdb_broadcast_t o_cdb,
    output riscv_pkg::cdb_broadcast_t o_cdb_2,

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
    // Commit Outputs (the internal commit buses, registered and combinational)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb,
    output logic                              o_commit_valid_raw,
    output logic                              o_commit_misprediction_raw,
    output logic                              o_commit_correct_branch_raw,
    output logic                              o_commit_correct_branch_2_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // Commit slot 2 (head+1), valid only for two-wide retirement. Registered
    // outputs follow one cycle later; full flush masks valid. Consumers must
    // ignore invalid payloads.
    output riscv_pkg::reorder_buffer_commit_t o_commit_2,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb_2,
    output logic                              o_commit_2_valid_raw,

    // =========================================================================
    // ROB External Coordination
    // =========================================================================
    output logic                                        o_csr_start,
    input  logic                                        i_csr_done,
    output logic                                        o_trap_pending,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_pc,
    output logic                                        o_head_is_wfi,
    // Head is an AMO (trap unit's AMO interrupt shield; see reorder_buffer).
    output logic                                        o_head_is_amo,
    // Regfile-bypass field pre-decodes for cpu_ooo's bypass_p*_we_q
    // qualifiers, for timing only (see the reorder_buffer port comment).
    output logic                                        o_head_bypass_int_we_early,
    output logic                                        o_head_bypass_fp_we_early,
    output logic                                        o_head_next_bypass_int_we_early,
    output logic                                        o_head_next_bypass_fp_we_early,
    output logic                                        o_head_dir_train_early,
    output logic                                        o_head_branch_taken_early,
    output logic                                        o_head_next_dir_train_early,
    output logic                                        o_head_next_branch_taken_early,
    // Retired-next-PC precompute for cpu_ooo's interrupt_resume_pc, for
    // timing only (see the reorder_buffer port comment).
    output logic                  [riscv_pkg::XLEN-1:0] o_head_retired_next_pc,
    output logic                  [riscv_pkg::XLEN-1:0] o_head_next_retired_next_pc,
    output riscv_pkg::exc_cause_t                       o_trap_cause,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_value,
    input  logic                                        i_trap_taken,
    output logic                                        o_mret_start,
    output logic                                        o_mret_start_is_sret,
    output logic                                        o_mret_start_is_dret,
    input  logic                                        i_mret_done,
    input  logic                  [riscv_pkg::XLEN-1:0] i_mepc,
    input  logic                  [riscv_pkg::XLEN-1:0] i_sepc,
    input  logic                  [riscv_pkg::XLEN-1:0] i_dpc,
    input  logic                                        i_interrupt_pending,

    // Current privilege (PrivM/PrivS/PrivU), forwarded to the ROB for its
    // allocation-time CSR/xRET legality snapshot.
    input logic [1:0] i_priv,

    // Pre-composed privilege-legality bits from csr_file, sampled at ROB
    // allocation (see reorder_buffer).
    input logic [2:0] i_counter_blocked,
    input logic i_stimecmp_blocked,
    input logic i_sret_illegal,
    input logic i_sfence_illegal,
    input logic i_wfi_illegal,
    input logic i_priv_is_u,
    input logic i_debug_mode,

    // Raw mcounteren CY/TM/IR bits forwarded across the CSR/ROB interface;
    // allocation legality uses the privilege-resolved i_counter_blocked.
    input logic [2:0] i_mcounteren,
    // mstatus.FS == Off, sampled by the ROB's FP-op legality check at
    // allocation.
    input logic       i_mstatus_fs_off,
    input logic       i_trap_misaligned_accesses,

    // =========================================================================
    // Data translation. The state inputs are registered in csr_file and
    // change only with a full flush (translation CSR write, trap, or xRET).
    // The page-table walker is in cpu_ooo, reached through the walk ports.
    // =========================================================================
    input  logic                                              i_translation_active,
    input  logic                                              i_mmu_sum,
    input  logic                                              i_mmu_mxr,
    input  logic                                              i_mmu_eff_priv_u,
    // The CSR file's registered translation-invalidate pulse. With the ROB's
    // SFENCE.VMA window it invalidates the DTLB and walker. Pipeline recovery
    // for the CSR write is separate: the ROB serializer classifies the CSR at
    // allocation and drains committed stores before it retires.
    input  logic                                              i_csr_translation_flush_req,
    // The DTLB flash-invalidate, exported for the walker's discard input:
    // the SFENCE.VMA window OR i_csr_translation_flush_req.
    output logic                                              o_tlb_invalidate,
    output logic                                              o_walk_req_valid,
    input  logic                                              i_walk_req_ready,
    output logic                 [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input  logic                                              i_walk_resp_valid,
    input  riscv_pkg::ptw_resp_t                              i_walk_resp,

    // Widen-commit back-pressure: asserted when the downstream slot-2
    // retire path can accept a second commit this cycle.  cpu_ooo holds it
    // high, since slot 2 has its own register-file write ports, except during
    // debug single step, which forces one-wide commit.
    input logic i_widen_commit_ok,
    input logic i_commit_hold,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,
    input logic                                        i_flush_after_head_commit,
    input logic                                        i_backend_recovery_hold,
    // A cached store is in flight. Block LQ launches throughout its handshake
    // to avoid overwriting the router's single pending-load register.
    input logic                                        i_slow_write_inflight,
    // A cached load response is held behind the fast tier's fixed-latency
    // beat this cycle (router). The LQ registers it into its launch hold so
    // one launch is skipped and the held response gets the port.
    input logic                                        i_cached_read_held,
    // Router pending status must block the next LQ handoff through acceptance,
    // without another register. On full flush it distinguishes canceled pending
    // requests from accepted requests whose responses must still drain.
    input logic                                        i_lq_mem_request_pending,

    // DMA coherence handshake: the cache hierarchy's sequencer to
    // lq_coherence_port. Admit fires on ready, inval fires on done, release
    // is a pulse.
    input  logic                                       i_coh_admit_valid,
    input  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_admit_slot,
    input  logic [                riscv_pkg::XLEN-1:0] i_coh_admit_addr,
    output logic                                       o_coh_admit_ready,
    input  logic                                       i_coh_inval_valid,
    input  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_inval_slot,
    output logic                                       o_coh_inval_done,
    input  logic                                       i_coh_release_valid,
    input  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_release_slot,

    // =========================================================================
    // Early Misprediction Recovery
    // =========================================================================
    input logic                                        i_early_recovery_flush,
    input logic                                        i_early_recovery_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_recovery_tag,

    // =========================================================================
    // ROB Status
    // =========================================================================
    // FENCE.I cache-sync handshake (rob_serializer <-> the cache hierarchy).
    input  logic i_fence_i_sync_done,
    output logic o_fence_i_sync_req,
    output logic o_fence_i_flush,
    output logic o_fence_class_flush_event,
    output logic o_translation_csr_commit_shadow,

    // Shared committed-store drain status for trap/xRET, fence/AMO, and
    // router-accepted device reads, plus the store queue's copy of it for the
    // trap unit (equal on every cycle).
    output logic                                        o_sq_committed_empty,
    output logic                                        o_sq_committed_empty_trap,
    output logic                                        o_rob_full,
    output logic                                        o_rob_full_for_2,
    output logic                                        o_rob_empty,
    output logic [  riscv_pkg::ReorderBufferTagWidth:0] o_rob_count,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // ROB Entry State
    // =========================================================================
    output logic [riscv_pkg::ReorderBufferDepth-1:0] o_rob_entry_done_vec,
    input  logic [riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_epoch,

    // =========================================================================
    // Dispatch Done-Entry Bypass (generic source ports)
    // =========================================================================
    // Channels 1-3: slot-1 source tags. Channels 4-6: slot-2 source tags.
    // Production dispatch presents a valid query for every unresolved source;
    // the FP capture-edge wait register relies on that interface contract.
    input  logic                                        i_bypass_valid_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_1,
    input  logic                                        i_bypass_valid_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_2,
    input  logic                                        i_bypass_valid_3,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_3,
    input  logic                                        i_bypass_valid_4,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_4,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_4,
    input  logic                                        i_bypass_valid_5,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_5,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_5,
    input  logic                                        i_bypass_valid_6,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_6,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_6,

    // =========================================================================
    // RAT Source Lookups (combinational)
    // =========================================================================
    // Slot-1 source lookups
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

    // Slot-2 source lookups (2-wide dispatch).  Driven with slot-2's source
    // addresses; the integer results feed slot-2 rename in dispatch.
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr_2,
    output riscv_pkg::rat_lookup_t                               o_int_src1_2,
    output riscv_pkg::rat_lookup_t                               o_int_src2_2,

    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src1_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src2_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3_2,

    // RAT Regfile data - slot 1
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // RAT Regfile data - slot 2 (2-wide dispatch)
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1_2,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3_2,

    // =========================================================================
    // RAT Rename (from Dispatch)
    // =========================================================================
    // Slot 1
    input logic                                        i_rat_alloc_valid,
    input logic                                        i_rat_alloc_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag,

    // Slot 2 (2-wide dispatch).  valid_2 asserts when slot-2 renames a dest.
    input logic                                        i_rat_alloc_valid_2,
    input logic                                        i_rat_alloc_dest_rf_2,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag_2,

    // =========================================================================
    // RAT Checkpoint Save (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,
    input logic [                 riscv_pkg::XLEN-1:0] i_ras_top,
    // Slot-2-branch checkpoint flag: RAT overlays
    // slot-1's same-cycle rename onto the snapshot when this asserts.
    input logic                                        i_checkpoint_save_for_slot2,

    // Dispatch candidates are qualified by atomic bundle fire:
    // i_rat_alloc_valid = i_alloc_fire && i_alloc_has_dest, likewise for slot 2.
    // A saved checkpoint's slot-2 flag equals i_checkpoint_slot2_candidate.
    // The RAT applies fire after selecting candidates for timing.
    input logic i_alloc_fire,
    input logic i_alloc_has_dest,
    input logic i_alloc_has_dest_2,
    input logic i_checkpoint_slot2_candidate,

    // =========================================================================
    // RAT Checkpoint Restore (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    input  logic                                    i_checkpoint_restore_reclaim_all,
    input  logic [   riscv_pkg::NumCheckpoints-1:0] i_checkpoint_flush_free_mask,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,
    output logic [             riscv_pkg::XLEN-1:0] o_ras_top,

    // =========================================================================
    // RAT Checkpoint Free (from the flush controller, when a branch releases
    // its checkpoint at commit or recovery)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,
    input logic                                    i_checkpoint_free_2,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id_2,

    // =========================================================================
    // RAT Checkpoint Availability
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id,

    // =========================================================================
    // RS Dispatch (from Dispatch)
    // =========================================================================
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch,
    // Slot-2 RS dispatch ports (2-wide dispatch).  The dispatch unit drives
    // the slot-2 packet on the port for the RS family matching slot-2's
    // rs_type, asserting .valid only there when slot-2 fires.
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch_2,
    output logic o_rs_full,

    // =========================================================================
    // RS Issue (to Functional Unit)
    // =========================================================================
    output riscv_pkg::rs_issue_t o_rs_issue,
    // Separate register copy of INT_RS's port-0 stage-2 tag, loaded on the
    // same edge; branch resolution in cpu_ooo uses it only for its checkpoint
    // and age compares.
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rs_issue_branch_predicate_tag,
    input logic i_rs_fu_ready,

    // =========================================================================
    // RS Status (INT_RS)
    // =========================================================================
    output logic                              o_int_rs_full,
    output logic                              o_int_rs_full_for_2,
    output logic                              o_rs_empty,
    output logic [$clog2(INT_RS_DEPTH+1)-1:0] o_rs_count,

    // =========================================================================
    // MUL_RS (Integer multiply/divide, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mul_rs_issue,
    input  logic                                                           i_mul_rs_fu_ready,
    output logic                                                           o_mul_rs_full,
    output logic                                                           o_mul_rs_full_for_2,
    output logic                                                           o_mul_rs_empty,
    output logic                 [$clog2(riscv_pkg::MulRsDepth + 1) - 1:0] o_mul_rs_count,

    // =========================================================================
    // MEM_RS (Load/store, depth 8)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                           o_mem_rs_issue,
    input  logic                                                           i_mem_rs_fu_ready,
    output logic                                                           o_mem_rs_full,
    output logic                                                           o_mem_rs_full_for_2,
    output logic                                                           o_mem_rs_empty,
    output logic                 [$clog2(riscv_pkg::MemRsDepth + 1) - 1:0] o_mem_rs_count,

    // =========================================================================
    // FP_RS (every FP compute operation, riscv_pkg::FpRsDepth entries)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                          o_fp_rs_issue,
    input  logic                                                          i_fp_rs_fu_ready,
    output logic                                                          o_fp_rs_full,
    output logic                                                          o_fp_rs_full_for_2,
    output logic                                                          o_fp_rs_empty,
    output logic                 [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] o_fp_rs_count,

    // =========================================================================
    // Store Queue: Memory Write Interface
    // =========================================================================
    output logic                              o_sq_mem_write_en,
    output logic [       riscv_pkg::XLEN-1:0] o_sq_mem_write_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_sq_mem_write_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_sq_mem_write_byte_en,
    output logic                              o_sq_mem_write_is_mmio,
    output logic                              o_sq_mem_write_is_cached,
    input  logic                              i_sq_mem_write_done,

    // =========================================================================
    // Load Queue: Memory Interface
    // =========================================================================
    output logic                                                     o_lq_mem_read_en,
    output logic                                                     o_lq_mem_addr_valid,
    output logic                 [              riscv_pkg::XLEN-1:0] o_lq_mem_read_addr,
    output riscv_pkg::mem_size_e                                     o_lq_mem_read_size,
    // Cached-tier slot id of the launching load; responses come back tagged
    // (is_cached + id) so the LQ knows which outstanding load they answer.
    output logic                 [riscv_pkg::CachedLoadSlotBits-1:0] o_lq_mem_read_id,
    input  logic                 [       riscv_pkg::MemDataBits-1:0] i_lq_mem_read_data,
    input  logic                                                     i_lq_mem_read_valid,
    input  logic                                                     i_lq_mem_read_is_cached,
    input  logic                 [riscv_pkg::CachedLoadSlotBits-1:0] i_lq_mem_read_id,

    // =========================================================================
    // Load Queue: Status
    // =========================================================================
    output logic                                    o_lq_full,
    output logic                                    o_lq_full_for_2,
    output logic                                    o_lq_empty,
    output logic [$clog2(riscv_pkg::LqDepth+1)-1:0] o_lq_count,

    // =========================================================================
    // Store Queue: Status
    // =========================================================================
    output logic                                    o_sq_full,
    output logic                                    o_sq_full_for_2,
    output logic                                    o_sq_empty,
    output logic [$clog2(riscv_pkg::SqDepth+1)-1:0] o_sq_count,

    // =========================================================================
    // AMO Memory Write Interface (from LQ)
    // =========================================================================
    output logic                              o_amo_mem_write_en,
    output logic [       riscv_pkg::XLEN-1:0] o_amo_mem_write_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_amo_mem_write_data,
    output logic                              o_amo_mem_write_is_dword,
    // Registered cached-tier flag of o_amo_mem_write_addr (load_queue).
    output logic                              o_amo_mem_write_is_cached,
    input  logic                              i_amo_mem_write_done,

    // =========================================================================
    // Profiling Snapshot Interface
    // =========================================================================
    input  logic        i_perf_snapshot_capture,
    input  logic [ 7:0] i_perf_counter_select,
    output logic [63:0] o_perf_counter_data,

    // Width-funnel perf observers (registered at their sources, profiling
    // only).  Counted as top-level counters in perf_counter_aggregator, not
    // in this wrapper's back-end counter block.
    output logic o_perf_mem_rs_two_ready_one_issued,
    output logic o_perf_cdb_oversubscribed
);

  initial begin
    if (INT_RS_DEPTH < 2 || INT_RS_DEPTH > riscv_pkg::ReorderBufferDepth ||
        (INT_RS_DEPTH & (INT_RS_DEPTH - 1)) != 0)
      $fatal(1, "INT_RS_DEPTH must be a power of two between 2 and ROB depth");
  end

  // ===========================================================================
  // Internal commit bus: ROB -> RAT / SQ / SC
  // ===========================================================================
  // The combinational bus supports same-cycle misprediction detection.
  // Registered commits feed RAT, SQ, SC, and coherence for timing, with valid
  // masked during full flush. Only non-stores overlap a full flush. The SQ
  // also uses raw ROB store-commit pulses to clear committed-empty early.
  riscv_pkg::reorder_buffer_commit_t commit_bus;
  // Separate valid from payload so only valid resets.
  logic commit_bus_q_valid;
  // Pre-flush-mask registered valid (scan-only consumers; see
  // commit_bus_pipeline port comment).
  logic commit_bus_q_valid_raw;
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

  // Slot 2 never carries SC, AMO, or LR, so it needs no SC fields. Reset its
  // valid separately from payload, as for slot 1.
  riscv_pkg::reorder_buffer_commit_t commit_bus_2;
  riscv_pkg::reorder_buffer_commit_t commit_bus_2_q;
  logic commit_bus_2_q_valid;
  logic commit_bus_2_q_valid_raw;
  logic commit_q_2_dest_valid;
  logic commit_q_2_dest_rf;
  logic [riscv_pkg::RegAddrWidth-1:0] commit_q_2_dest_reg;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] commit_q_2_tag;
  logic commit_q_2_is_store_like;
  logic commit_2_valid_raw;
  logic commit_2_store_like_raw;

  // Registers for both commit slots (commit_bus/commit_bus_pipeline.sv).
  commit_bus_pipeline commit_bus_pipeline_inst (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_commit_bus              (commit_bus),
      .i_commit_bus_2            (commit_bus_2),
      .o_commit_bus_q            (commit_bus_q),
      .o_commit_bus_q_valid      (commit_bus_q_valid),
      .o_commit_bus_q_valid_raw  (commit_bus_q_valid_raw),
      .o_commit_q_dest_valid     (commit_q_dest_valid),
      .o_commit_q_dest_rf        (commit_q_dest_rf),
      .o_commit_q_dest_reg       (commit_q_dest_reg),
      .o_commit_q_tag            (commit_q_tag),
      .o_commit_q_is_sc          (commit_q_is_sc),
      .o_commit_q_is_store_like  (commit_q_is_store_like),
      .o_commit_q_sc_failed      (commit_q_sc_failed),
      .o_commit_bus_2_q          (commit_bus_2_q),
      .o_commit_bus_2_q_valid    (commit_bus_2_q_valid),
      .o_commit_bus_2_q_valid_raw(commit_bus_2_q_valid_raw),
      .o_commit_q_2_dest_valid   (commit_q_2_dest_valid),
      .o_commit_q_2_dest_rf      (commit_q_2_dest_rf),
      .o_commit_q_2_dest_reg     (commit_q_2_dest_reg),
      .o_commit_q_2_tag          (commit_q_2_tag),
      .o_commit_q_2_is_store_like(commit_q_2_is_store_like)
  );

  // Reconstruct the commit bus with the qualified valid (reset and full-flush
  // masked) for downstream consumers.
  riscv_pkg::reorder_buffer_commit_t commit_bus_q_qualified;
  always_comb begin
    commit_bus_q_qualified       = commit_bus_q;
    commit_bus_q_qualified.valid = commit_bus_q_valid;
  end
  assign o_commit_valid_raw = commit_valid_raw;

  // Slot 2 likewise: a qualified view of the registered slot-2 commit for
  // cpu_ooo's slot-2 retirement (commit_actions).
  riscv_pkg::reorder_buffer_commit_t commit_bus_2_q_qualified;
  always_comb begin
    commit_bus_2_q_qualified       = commit_bus_2_q;
    commit_bus_2_q_qualified.valid = commit_bus_2_q_valid;
  end
  assign o_commit_2_valid_raw = commit_2_valid_raw;

  // Back-end profiling counters (params, storage, accumulate/snapshot/mux) live
  // in tomasulo_perf_counters; instantiated below.

  // Expose both the raw and registered commit buses.
  assign o_commit_comb        = commit_bus;
  assign o_commit             = commit_bus_q_qualified;
  assign o_commit_comb_2      = commit_bus_2;
  assign o_commit_2           = commit_bus_2_q_qualified;

  // ROB entry valid/done vectors: valid to the RAT (stale-rename check), done
  // to the dispatch done-repair below. o_rob_entry_done_vec exports the done
  // vector for the unit bench; cpu_ooo leaves it unconnected.
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_valid;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done;
  assign o_rob_entry_done_vec = rob_entry_done;

  // Dispatch done-repair: dispatch registers up to six renamed source ROB
  // tags (three per dispatch slot). One cycle later, the ROB's done bits and
  // values for those tags go to INT_RS, MUL_RS, and MEM_RS (each updates the
  // entry it allocated), to the FP dispatch buffer, and to the store
  // early-address repair. Only slot 1 carries FP compute ops, so the
  // three-source FP buffer uses channels 1 to 3.
  logic [riscv_pkg::FLEN-1:0] bypass_value_1, bypass_value_2, bypass_value_3;
  logic [riscv_pkg::FLEN-1:0] bypass_value_4, bypass_value_5, bypass_value_6;
  logic done_repair_valid_1;
  logic done_repair_valid_2;
  logic done_repair_valid_3;
  logic done_repair_valid_4;
  logic done_repair_valid_5;
  logic done_repair_valid_6;
  (* max_fanout = 32 *)logic int_done_repair_valid_1;
  (* max_fanout = 32 *)logic int_done_repair_valid_2;
  (* max_fanout = 32 *)logic int_done_repair_valid_3;
  (* max_fanout = 32 *)logic int_done_repair_valid_4;
  (* max_fanout = 32 *)logic int_done_repair_valid_5;
  (* max_fanout = 32 *)logic int_done_repair_valid_6;
  assign done_repair_valid_1 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_1 && rob_entry_done[i_bypass_tag_1];
  assign done_repair_valid_2 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_2 && rob_entry_done[i_bypass_tag_2];
  assign done_repair_valid_3 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_3 && rob_entry_done[i_bypass_tag_3];
  assign done_repair_valid_4 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_4 && rob_entry_done[i_bypass_tag_4];
  assign done_repair_valid_5 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_5 && rob_entry_done[i_bypass_tag_5];
  assign done_repair_valid_6 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_6 && rob_entry_done[i_bypass_tag_6];

  assign int_done_repair_valid_1 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_1 && rob_entry_done[i_bypass_tag_1];
  assign int_done_repair_valid_2 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_2 && rob_entry_done[i_bypass_tag_2];
  assign int_done_repair_valid_3 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_3 && rob_entry_done[i_bypass_tag_3];
  assign int_done_repair_valid_4 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_4 && rob_entry_done[i_bypass_tag_4];
  assign int_done_repair_valid_5 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_5 && rob_entry_done[i_bypass_tag_5];
  assign int_done_repair_valid_6 =
      ENABLE_DISPATCH_DONE_REPAIR && i_bypass_valid_6 && rob_entry_done[i_bypass_tag_6];

  // Head tag for RS partial flush
  (* max_fanout = 32 *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  riscv_pkg::rob_perf_events_t rob_perf_events;
  assign head_tag = o_head_tag;

  // Early misprediction recovery flushes by age (i_flush_en, i_flush_tag):
  // its branch need not be at the ROB head and older instructions must
  // survive, so every speculative structure takes the partial flush.  Full
  // flushes (trap, xRET, FENCE-class recovery) clear everything.
  //
  // i_flush_after_head_commit marks commit-time recovery, where the
  // offending branch has already retired at the ROB head; only that case is
  // promoted to a speculative full flush, and no head/tag relationship is
  // recomputed here.
  (* max_fanout = 32 *)logic full_flush_all;
  (* max_fanout = 32 *)logic speculative_flush_all;
  logic speculative_flush_en;
  logic lq_partial_flush_en;
  // Keep a local CDB kill copy for fanout.
  (* keep = "true" *)logic cdb_kill;
  assign full_flush_all = i_flush_all;
  assign speculative_flush_all = full_flush_all || i_flush_after_head_commit;
  assign speculative_flush_en = i_flush_en && !i_flush_after_head_commit;
  // Only early recovery reaches the LQ as partial flush. Feed it directly for
  // timing; commit recovery and architectural flush use speculative_flush_all.
  // If the partial signals differ, full flush clears every visible LQ update,
  // so any coincident payload capture is unused.
  assign lq_partial_flush_en = i_early_recovery_flush;
  assign cdb_kill = speculative_flush_all;

`ifndef SYNTHESIS
`ifndef FORMAL
  always_comb begin
    if (!$isunknown({lq_partial_flush_en, speculative_flush_en, speculative_flush_all})) begin
      p_lq_partial_flush_exact_when_observable :
      assert (speculative_flush_all || (lq_partial_flush_en == speculative_flush_en));
    end
  end
`endif
`endif

  // ===========================================================================
  // CDB Arbiter: FU completions -> 2-lane CDB broadcast (o_cdb + o_cdb_2)
  // ===========================================================================
  riscv_pkg::cdb_broadcast_t cdb_bus_comb;  // combinational from arbiter
  // Registered metadata plus the arbiter's value-tree fallback value.
  // cdb_bus is the same registered packet with the live ALU value restored
  // (below).
  (* equivalent_register_removal = "no" *)riscv_pkg::cdb_broadcast_t cdb_bus_q;
  riscv_pkg::cdb_broadcast_t cdb_bus;
  // CDB copies for early store-address repair, sampled with cdb_bus_q. Keep
  // one XLEN value, tag, and valid copy per lane for fanout; avoid replicating
  // the wide payload further.
  typedef struct packed {
    logic                                        valid;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic [riscv_pkg::XLEN-1:0]                  value;
  } sq_cdb_local_t;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  sq_cdb_local_t sq_cdb_bus_q;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  sq_cdb_local_t sq_cdb_bus_2_q;
  riscv_pkg::cdb_broadcast_t sq_cdb_bus;
  riscv_pkg::cdb_broadcast_t sq_cdb_bus_2;
  // same-cycle INT_RS-local copy
  (* equivalent_register_removal = "no" *) riscv_pkg::cdb_broadcast_t cdb_bus_int_rs;
  // Preserve separate INT_RS copies while allowing max_fanout replication.
  // Do not use dont_touch here; it prevents that replication.
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 24 *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_int_rs_tag;
  // INT_RS reads only value[XLEN-1:0]; its packet zero-extends to FLEN.
  // Keep value copies unreplicated to limit wiring; tag copies may replicate.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::XLEN-1:0] cdb_bus_int_rs_value;
  riscv_pkg::cdb_broadcast_t cdb_bus_2_comb;  // 2-wide CDB lane-1, combinational
  // Registered lane-1 metadata/fallback and its reconstructed view.
  (* equivalent_register_removal = "no" *) riscv_pkg::cdb_broadcast_t cdb_bus_2_q;
  riscv_pkg::cdb_broadcast_t cdb_bus_2;
  // Same-edge tag copies for FP_RS, for fanout. Keep one per lane without
  // replicating the wide value.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_fp_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_fp_tag;
  // Same-edge tag copies for MUL_RS and MEM_RS, for fanout.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_mul_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_mul_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_mem_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_mem_tag;
  // same-cycle INT_RS-local copy
  (* equivalent_register_removal = "no" *) riscv_pkg::cdb_broadcast_t cdb_bus_2_int_rs;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 24 *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_int_rs_tag;
  // XLEN-wide lane-1 value copy, kept unreplicated to limit wiring.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::XLEN-1:0] cdb_bus_2_int_rs_value;

  // Forward declarations: adapter->arbiter signals (used here, defined below)
  riscv_pkg::fu_complete_t alu_adapter_to_arbiter;
  riscv_pkg::fu_complete_t mul_adapter_to_arbiter;
  riscv_pkg::fu_complete_t div_adapter_to_arbiter;
  riscv_pkg::fu_complete_t mem_adapter_to_arbiter;
  riscv_pkg::fu_complete_t fp_adapter_to_arbiter;
  riscv_pkg::fu_complete_t alu2_adapter_to_arbiter;
  riscv_pkg::fu_complete_t alu_shim_out;
  riscv_pkg::fu_complete_t alu2_shim_out;
  logic alu_adapter_result_pending;
  logic alu2_adapter_result_pending;
  logic [riscv_pkg::FLEN-1:0] alu_adapter_held_value;
  logic [riscv_pkg::FLEN-1:0] alu2_adapter_held_value;
  logic alu_value_is_live;
  logic alu2_value_is_live;
  logic [riscv_pkg::FLEN-1:0] alu_tree_fallback_value;
  logic [riscv_pkg::FLEN-1:0] alu2_tree_fallback_value;

  // Only fallback values feed the CDB value registers; live ALU values use
  // the registered restore selects below.
  logic [riscv_pkg::FLEN-1:0] cdb_lane0_tree_fallback_value_comb;
  logic [riscv_pkg::FLEN-1:0] cdb_lane1_tree_fallback_value_comb;
  logic cdb_lane0_select_alu_live_comb;
  logic cdb_lane0_select_alu2_live_comb;
  logic cdb_lane1_select_alu_live_comb;
  logic cdb_lane1_select_alu2_live_comb;

  // Register the selects with the CDB. Restore live ALU values from the
  // adapters' held payloads after the edge, avoiding duplicate value registers.
  logic cdb_lane0_select_alu_live_q;
  logic cdb_lane0_select_alu2_live_q;
  logic cdb_lane1_select_alu_live_q;
  logic cdb_lane1_select_alu2_live_q;
  logic [riscv_pkg::FLEN-1:0] cdb_bus_restored_value;
  logic [riscv_pkg::FLEN-1:0] cdb_bus_2_restored_value;
  logic [riscv_pkg::XLEN-1:0] cdb_bus_int_rs_restored_value;
  logic [riscv_pkg::XLEN-1:0] cdb_bus_2_int_rs_restored_value;
  logic [riscv_pkg::XLEN-1:0] sq_cdb_bus_restored_value;
  logic [riscv_pkg::XLEN-1:0] sq_cdb_bus_2_restored_value;

  // Route FU adapter outputs to CDB arbiter inputs.  Internal adapters
  // take priority; test-injection ports (i_fu_complete_*) fall through
  // when the adapter is idle.  In production cpu_ooo ties them to '0.
  riscv_pkg::fu_complete_t cdb_arb_in_0;
  riscv_pkg::fu_complete_t cdb_arb_in_1;
  riscv_pkg::fu_complete_t cdb_arb_in_2;
  riscv_pkg::fu_complete_t cdb_arb_in_3;
  riscv_pkg::fu_complete_t cdb_arb_in_4;
  riscv_pkg::fu_complete_t cdb_arb_in_5;
  riscv_pkg::fu_complete_t cdb_arb_in_6;
  riscv_pkg::fu_complete_t cdb_arb_in_7;
  always_comb begin
    cdb_arb_in_0 = alu_adapter_to_arbiter.valid ? alu_adapter_to_arbiter : i_fu_complete_0;
    cdb_arb_in_1 = mul_adapter_to_arbiter.valid ? mul_adapter_to_arbiter : i_fu_complete_1;
    cdb_arb_in_2 = div_adapter_to_arbiter.valid ? div_adapter_to_arbiter : i_fu_complete_2;
    cdb_arb_in_3 = mem_adapter_to_arbiter.valid ? mem_adapter_to_arbiter : i_fu_complete_3;
    cdb_arb_in_4 = fp_adapter_to_arbiter.valid ? fp_adapter_to_arbiter : i_fu_complete_4;
    // Slots 5 and 6 have no unit behind them.
    cdb_arb_in_5 = i_fu_complete_5;
    cdb_arb_in_6 = i_fu_complete_6;
    cdb_arb_in_7 = alu2_adapter_to_arbiter.valid ? alu2_adapter_to_arbiter : i_fu_complete_7;
  end

  // Split ALU values into live and fallback paths. Valid with no pending
  // result selects the shim; partial flush suppresses valid. Fallback selects
  // held adapter data or test injection. Read held-register Q directly to
  // avoid a live-shim dependency for timing.
  assign alu_value_is_live = alu_adapter_to_arbiter.valid && !alu_adapter_result_pending;
  assign alu2_value_is_live = alu2_adapter_to_arbiter.valid && !alu2_adapter_result_pending;
  assign alu_tree_fallback_value =
      (alu_adapter_result_pending && alu_adapter_to_arbiter.valid) ?
      alu_adapter_held_value : i_fu_complete_0.value;
  assign alu2_tree_fallback_value =
      (alu2_adapter_result_pending && alu2_adapter_to_arbiter.valid) ?
      alu2_adapter_held_value : i_fu_complete_7.value;

  // Register CDB oversubscription for profiling: three or more completions
  // request two lanes, so at least one must wait.
  logic [3:0] perf_cdb_request_count;
  logic       perf_cdb_oversubscribed_q;
  assign perf_cdb_request_count =
      4'(cdb_arb_in_0.valid) + 4'(cdb_arb_in_1.valid) + 4'(cdb_arb_in_2.valid) +
      4'(cdb_arb_in_3.valid) + 4'(cdb_arb_in_4.valid) + 4'(cdb_arb_in_5.valid) +
      4'(cdb_arb_in_6.valid) + 4'(cdb_arb_in_7.valid);
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      perf_cdb_oversubscribed_q <= 1'b0;
    end else begin
      perf_cdb_oversubscribed_q <= (perf_cdb_request_count >= 4'd3);
    end
  end
  assign o_perf_cdb_oversubscribed = perf_cdb_oversubscribed_q;

  cdb_arbiter #(
      // Wrapper formal proves the auxiliary value contract without relying on
      // the standalone arbiter's environment assumption.
      .FORMAL_ASSUME_VALUE_SOURCE_CONTRACT(1'b0)
  ) u_cdb_arbiter (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_fu_complete_0            (cdb_arb_in_0),
      .i_fu_complete_1            (cdb_arb_in_1),
      .i_fu_complete_2            (cdb_arb_in_2),
      .i_fu_complete_3            (cdb_arb_in_3),
      .i_fu_complete_4            (cdb_arb_in_4),
      .i_fu_complete_5            (cdb_arb_in_5),
      .i_fu_complete_6            (cdb_arb_in_6),
      .i_fu_complete_7            (cdb_arb_in_7),
      .i_alu_value_is_live        (alu_value_is_live),
      .i_alu_live_value           (alu_shim_out.value),
      .i_alu_tree_fallback_value  (alu_tree_fallback_value),
      .i_alu2_value_is_live       (alu2_value_is_live),
      .i_alu2_live_value          (alu2_shim_out.value),
      .i_alu2_tree_fallback_value (alu2_tree_fallback_value),
      .i_kill                     (cdb_kill),
      .o_cdb                      (cdb_bus_comb),
      .o_cdb_2                    (cdb_bus_2_comb),
      .o_lane0_tree_fallback_value(cdb_lane0_tree_fallback_value_comb),
      .o_lane1_tree_fallback_value(cdb_lane1_tree_fallback_value_comb),
      .o_lane0_select_alu_live    (cdb_lane0_select_alu_live_comb),
      .o_lane0_select_alu2_live   (cdb_lane0_select_alu2_live_comb),
      .o_lane1_select_alu_live    (cdb_lane1_select_alu_live_comb),
      .o_lane1_select_alu2_live   (cdb_lane1_select_alu2_live_comb),
      .o_grant                    (o_cdb_grant),
      .o_grant_raw                ()
  );

  // Register broadcasts to RS and ROB for timing; grants remain combinational.
  // Reset only valid, with max_fanout for its consumers.
  (* max_fanout = 32 *)logic cdb_bus_valid;
  (* equivalent_register_removal = "no", max_fanout = 32 *)logic cdb_bus_int_rs_valid;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) cdb_bus_valid <= 1'b0;
    else cdb_bus_valid <= cdb_bus_comb.valid;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) cdb_bus_int_rs_valid <= 1'b0;
    else cdb_bus_int_rs_valid <= cdb_bus_comb.valid;
  end

  always_ff @(posedge i_clk) begin
    cdb_bus_q.valid              <= cdb_bus_comb.valid;
    cdb_bus_q.tag                <= cdb_bus_comb.tag;
    cdb_bus_q.value              <= cdb_lane0_tree_fallback_value_comb;
    cdb_bus_q.exception          <= cdb_bus_comb.exception;
    cdb_bus_q.exc_cause          <= cdb_bus_comb.exc_cause;
    cdb_bus_q.fp_flags           <= cdb_bus_comb.fp_flags;
    cdb_bus_q.fu_type            <= cdb_bus_comb.fu_type;
    sq_cdb_bus_q.valid           <= cdb_bus_comb.valid;
    sq_cdb_bus_q.tag             <= cdb_bus_comb.tag;
    sq_cdb_bus_q.value           <= cdb_lane0_tree_fallback_value_comb[riscv_pkg::XLEN-1:0];
    cdb_bus_int_rs.valid         <= cdb_bus_comb.valid;
    cdb_bus_int_rs.tag           <= cdb_bus_comb.tag;
    cdb_bus_int_rs.value         <= cdb_lane0_tree_fallback_value_comb;
    cdb_bus_int_rs.exception     <= cdb_bus_comb.exception;
    cdb_bus_int_rs.exc_cause     <= cdb_bus_comb.exc_cause;
    cdb_bus_int_rs.fp_flags      <= cdb_bus_comb.fp_flags;
    cdb_bus_int_rs.fu_type       <= cdb_bus_comb.fu_type;
    cdb_bus_int_rs_tag           <= cdb_bus_comb.tag;
    cdb_bus_fp_tag               <= cdb_bus_comb.tag;
    cdb_bus_mul_tag              <= cdb_bus_comb.tag;
    cdb_bus_mem_tag              <= cdb_bus_comb.tag;
    cdb_bus_int_rs_value         <= cdb_lane0_tree_fallback_value_comb[riscv_pkg::XLEN-1:0];
    cdb_lane0_select_alu_live_q  <= cdb_lane0_select_alu_live_comb;
    cdb_lane0_select_alu2_live_q <= cdb_lane0_select_alu2_live_comb;
  end

  // Restore live ALU data from the adapter's held_result, captured on the same
  // edge as CDB metadata, fallback values, and selectors. Use separate restore
  // muxes for shared, INT_RS, and SQ consumers for fanout.
  cdb_live_value_restore u_cdb_lane0_registered_live_value_restore (
      .i_tree_fallback_value(cdb_bus_q.value),
      .i_select_alu_live    (cdb_lane0_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value),
      .i_select_alu2_live   (cdb_lane0_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value),
      .o_value              (cdb_bus_restored_value)
  );

  cdb_live_value_restore #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_cdb_lane0_int_rs_live_value_restore (
      .i_tree_fallback_value(cdb_bus_int_rs_value),
      .i_select_alu_live    (cdb_lane0_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .i_select_alu2_live   (cdb_lane0_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .o_value              (cdb_bus_int_rs_restored_value)
  );

  cdb_live_value_restore #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_cdb_lane0_sq_live_value_restore (
      .i_tree_fallback_value(sq_cdb_bus_q.value),
      .i_select_alu_live    (cdb_lane0_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .i_select_alu2_live   (cdb_lane0_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .o_value              (sq_cdb_bus_restored_value)
  );

  always_comb begin
    cdb_bus       = cdb_bus_q;
    cdb_bus.value = cdb_bus_restored_value;
  end

  // Expose combinational CDB for observation (grant timing matches)
  assign o_cdb   = cdb_bus_comb;
  assign o_cdb_2 = cdb_bus_2_comb;

  // Reconstruct CDB broadcast with reset-qualified valid for downstream consumers
  riscv_pkg::cdb_broadcast_t cdb_bus_qualified;
  always_comb begin
    cdb_bus_qualified       = cdb_bus;
    cdb_bus_qualified.valid = cdb_bus_valid;
  end

  // Per-station views of lane 0: the shared lane's valid, value, FU type, and
  // exception metadata, with only the tag replaced by that station's local
  // copy (registered on the same edge, so it always equals the shared tag).
  riscv_pkg::cdb_broadcast_t cdb_bus_fp_qualified;
  always_comb begin
    cdb_bus_fp_qualified     = cdb_bus_qualified;
    cdb_bus_fp_qualified.tag = cdb_bus_fp_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_mul_qualified;
  always_comb begin
    cdb_bus_mul_qualified     = cdb_bus_qualified;
    cdb_bus_mul_qualified.tag = cdb_bus_mul_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_mem_qualified;
  always_comb begin
    cdb_bus_mem_qualified     = cdb_bus_qualified;
    cdb_bus_mem_qualified.tag = cdb_bus_mem_tag;
  end

  // Use an equivalent same-edge CDB copy for INT_RS fanout.
  riscv_pkg::cdb_broadcast_t cdb_bus_int_rs_qualified;
  always_comb begin
    cdb_bus_int_rs_qualified = cdb_bus_int_rs;
    cdb_bus_int_rs_qualified.valid = cdb_bus_int_rs_valid;
    cdb_bus_int_rs_qualified.tag = cdb_bus_int_rs_tag;
    // Bits above XLEN are zero, not the broadcast value: INT_RS never reads
    // them, and the local copy register is XLEN wide (see its declaration).
    cdb_bus_int_rs_qualified.value = {
      {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, cdb_bus_int_rs_restored_value
    };
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

  // Identical CDB tag copies for ROB head-match bypass comparisons, for fanout.
  (* equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_rob_match_tag;
  (* equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_rob_match_tag_2;
  always_ff @(posedge i_clk) begin
    cdb_rob_match_tag   <= cdb_bus_comb.tag;
    cdb_rob_match_tag_2 <= cdb_bus_2_comb.tag;
  end

  // ---- 2-wide CDB lane-1: registered mirror of the lane-0 pipeline above.
  (* max_fanout = 32 *)logic cdb_bus_2_valid;
  (* equivalent_register_removal = "no", max_fanout = 32 *)logic cdb_bus_2_int_rs_valid;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) cdb_bus_2_valid <= 1'b0;
    else cdb_bus_2_valid <= cdb_bus_2_comb.valid;
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) cdb_bus_2_int_rs_valid <= 1'b0;
    else cdb_bus_2_int_rs_valid <= cdb_bus_2_comb.valid;
  end
  always_ff @(posedge i_clk) begin
    cdb_bus_2_q.valid            <= cdb_bus_2_comb.valid;
    cdb_bus_2_q.tag              <= cdb_bus_2_comb.tag;
    cdb_bus_2_q.value            <= cdb_lane1_tree_fallback_value_comb;
    cdb_bus_2_q.exception        <= cdb_bus_2_comb.exception;
    cdb_bus_2_q.exc_cause        <= cdb_bus_2_comb.exc_cause;
    cdb_bus_2_q.fp_flags         <= cdb_bus_2_comb.fp_flags;
    cdb_bus_2_q.fu_type          <= cdb_bus_2_comb.fu_type;
    cdb_bus_2_fp_tag             <= cdb_bus_2_comb.tag;
    cdb_bus_2_mul_tag            <= cdb_bus_2_comb.tag;
    cdb_bus_2_mem_tag            <= cdb_bus_2_comb.tag;
    sq_cdb_bus_2_q.valid         <= cdb_bus_2_comb.valid;
    sq_cdb_bus_2_q.tag           <= cdb_bus_2_comb.tag;
    sq_cdb_bus_2_q.value         <= cdb_lane1_tree_fallback_value_comb[riscv_pkg::XLEN-1:0];
    cdb_bus_2_int_rs.valid       <= cdb_bus_2_comb.valid;
    cdb_bus_2_int_rs.tag         <= cdb_bus_2_comb.tag;
    cdb_bus_2_int_rs.value       <= cdb_lane1_tree_fallback_value_comb;
    cdb_bus_2_int_rs.exception   <= cdb_bus_2_comb.exception;
    cdb_bus_2_int_rs.exc_cause   <= cdb_bus_2_comb.exc_cause;
    cdb_bus_2_int_rs.fp_flags    <= cdb_bus_2_comb.fp_flags;
    cdb_bus_2_int_rs.fu_type     <= cdb_bus_2_comb.fu_type;
    cdb_bus_2_int_rs_tag         <= cdb_bus_2_comb.tag;
    cdb_bus_2_int_rs_value       <= cdb_lane1_tree_fallback_value_comb[riscv_pkg::XLEN-1:0];
    cdb_lane1_select_alu_live_q  <= cdb_lane1_select_alu_live_comb;
    cdb_lane1_select_alu2_live_q <= cdb_lane1_select_alu2_live_comb;
  end

  cdb_live_value_restore u_cdb_lane1_registered_live_value_restore (
      .i_tree_fallback_value(cdb_bus_2_q.value),
      .i_select_alu_live    (cdb_lane1_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value),
      .i_select_alu2_live   (cdb_lane1_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value),
      .o_value              (cdb_bus_2_restored_value)
  );

  cdb_live_value_restore #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_cdb_lane1_int_rs_live_value_restore (
      .i_tree_fallback_value(cdb_bus_2_int_rs_value),
      .i_select_alu_live    (cdb_lane1_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .i_select_alu2_live   (cdb_lane1_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .o_value              (cdb_bus_2_int_rs_restored_value)
  );

  cdb_live_value_restore #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_cdb_lane1_sq_live_value_restore (
      .i_tree_fallback_value(sq_cdb_bus_2_q.value),
      .i_select_alu_live    (cdb_lane1_select_alu_live_q),
      .i_alu_live_value     (alu_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .i_select_alu2_live   (cdb_lane1_select_alu2_live_q),
      .i_alu2_live_value    (alu2_adapter_held_value[riscv_pkg::XLEN-1:0]),
      .o_value              (sq_cdb_bus_2_restored_value)
  );

  always_comb begin
    cdb_bus_2       = cdb_bus_2_q;
    cdb_bus_2.value = cdb_bus_2_restored_value;
  end

  riscv_pkg::cdb_broadcast_t cdb_bus_2_qualified;
  always_comb begin
    cdb_bus_2_qualified       = cdb_bus_2;
    cdb_bus_2_qualified.valid = cdb_bus_2_valid;
  end
  // Per-station views of lane 1, built like the lane-0 views above.
  riscv_pkg::cdb_broadcast_t cdb_bus_2_fp_qualified;
  always_comb begin
    cdb_bus_2_fp_qualified = cdb_bus_2_qualified;
    cdb_bus_2_fp_qualified.tag = cdb_bus_2_fp_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_2_mul_qualified;
  always_comb begin
    cdb_bus_2_mul_qualified = cdb_bus_2_qualified;
    cdb_bus_2_mul_qualified.tag = cdb_bus_2_mul_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_2_mem_qualified;
  always_comb begin
    cdb_bus_2_mem_qualified = cdb_bus_2_qualified;
    cdb_bus_2_mem_qualified.tag = cdb_bus_2_mem_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_2_int_rs_qualified;
  always_comb begin
    cdb_bus_2_int_rs_qualified = cdb_bus_2_int_rs;
    cdb_bus_2_int_rs_qualified.valid = cdb_bus_2_int_rs_valid;
    cdb_bus_2_int_rs_qualified.tag = cdb_bus_2_int_rs_tag;
    // Bits above XLEN are zero, as for lane 0's XLEN-wide local value copy.
    cdb_bus_2_int_rs_qualified.value = {
      {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, cdb_bus_2_int_rs_restored_value
    };
  end

  // Populate only fields used by sq_early_addr_pipeline. These copies sample
  // the same broadcasts on the same edges as the shared CDB registers.
  always_comb begin
    sq_cdb_bus = '0;
    sq_cdb_bus.valid = sq_cdb_bus_q.valid;
    sq_cdb_bus.tag = sq_cdb_bus_q.tag;
    sq_cdb_bus.value[riscv_pkg::XLEN-1:0] = sq_cdb_bus_restored_value;

    sq_cdb_bus_2 = '0;
    sq_cdb_bus_2.valid = sq_cdb_bus_2_q.valid;
    sq_cdb_bus_2.tag = sq_cdb_bus_2_q.tag;
    sq_cdb_bus_2.value[riscv_pkg::XLEN-1:0] = sq_cdb_bus_2_restored_value;
  end

`ifndef SYNTHESIS
  // Check local copies against shared CDB registers and restore selection.
  // Skip pre-reset payload checks because payload/select registers are unreset.
  always_comb begin
    if (i_rst_n) begin
      p_cdb_lane0_post_q_restore_mux :
      assert (
        cdb_bus.value ==
        (cdb_lane0_select_alu_live_q ? alu_adapter_held_value :
         cdb_lane0_select_alu2_live_q ? alu2_adapter_held_value : cdb_bus_q.value)
      );
      p_cdb_lane1_post_q_restore_mux :
      assert (
        cdb_bus_2.value ==
        (cdb_lane1_select_alu_live_q ? alu_adapter_held_value :
         cdb_lane1_select_alu2_live_q ? alu2_adapter_held_value : cdb_bus_2_q.value)
      );

      p_sq_cdb_lane0_phase_identity :
      assert (sq_cdb_bus_q.valid == cdb_bus.valid && sq_cdb_bus_q.tag == cdb_bus.tag);
      p_sq_cdb_lane1_phase_identity :
      assert (sq_cdb_bus_2_q.valid == cdb_bus_2.valid && sq_cdb_bus_2_q.tag == cdb_bus_2.tag);
      p_int_rs_cdb_lane0_phase_identity :
      assert (cdb_bus_int_rs.valid == cdb_bus.valid && cdb_bus_int_rs_tag == cdb_bus.tag);
      p_int_rs_cdb_lane1_phase_identity :
      assert (cdb_bus_2_int_rs.valid == cdb_bus_2.valid && cdb_bus_2_int_rs_tag == cdb_bus_2.tag);
      p_fp_cdb_lane0_tag_phase_identity : assert (cdb_bus_fp_tag == cdb_bus.tag);
      p_fp_cdb_lane1_tag_phase_identity : assert (cdb_bus_2_fp_tag == cdb_bus_2.tag);
      p_mul_cdb_lane0_tag_phase_identity : assert (cdb_bus_mul_tag == cdb_bus.tag);
      p_mul_cdb_lane1_tag_phase_identity : assert (cdb_bus_2_mul_tag == cdb_bus_2.tag);
      p_mem_cdb_lane0_tag_phase_identity : assert (cdb_bus_mem_tag == cdb_bus.tag);
      p_mem_cdb_lane1_tag_phase_identity : assert (cdb_bus_2_mem_tag == cdb_bus_2.tag);

      if (cdb_bus.valid) begin
        p_sq_cdb_lane0_value_identity :
        assert (sq_cdb_bus_restored_value == cdb_bus.value[riscv_pkg::XLEN-1:0]);
        p_int_rs_cdb_lane0_value_identity :
        assert (cdb_bus_int_rs_restored_value == cdb_bus.value[riscv_pkg::XLEN-1:0]);
      end
      if (cdb_bus_2.valid) begin
        p_sq_cdb_lane1_value_identity :
        assert (sq_cdb_bus_2_restored_value == cdb_bus_2.value[riscv_pkg::XLEN-1:0]);
        p_int_rs_cdb_lane1_value_identity :
        assert (cdb_bus_2_int_rs_restored_value == cdb_bus_2.value[riscv_pkg::XLEN-1:0]);
      end
    end
  end

  // Independent one-cycle oracle: compare each valid reconstructed registered
  // packet against the exact combinational packet observed at the prior edge.
  logic cdb_post_q_phase_oracle_valid;
  riscv_pkg::cdb_broadcast_t cdb_lane0_phase_oracle;
  riscv_pkg::cdb_broadcast_t cdb_lane1_phase_oracle;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      cdb_post_q_phase_oracle_valid <= 1'b0;
    end else begin
      if (cdb_post_q_phase_oracle_valid) begin
        p_cdb_lane0_registered_valid_phase : assert (cdb_bus.valid == cdb_lane0_phase_oracle.valid);
        p_cdb_lane1_registered_valid_phase :
        assert (cdb_bus_2.valid == cdb_lane1_phase_oracle.valid);
        if (cdb_lane0_phase_oracle.valid) begin
          p_cdb_lane0_registered_packet_phase : assert (cdb_bus == cdb_lane0_phase_oracle);
        end
        if (cdb_lane1_phase_oracle.valid) begin
          p_cdb_lane1_registered_packet_phase : assert (cdb_bus_2 == cdb_lane1_phase_oracle);
        end
      end
      cdb_lane0_phase_oracle        <= cdb_bus_comb;
      cdb_lane1_phase_oracle        <= cdb_bus_2_comb;
      cdb_post_q_phase_oracle_valid <= 1'b1;
    end
  end
`endif
  riscv_pkg::reorder_buffer_cdb_write_t cdb_write_from_arbiter_2;
  always_comb begin
    cdb_write_from_arbiter_2.valid     = cdb_bus_2_valid;
    cdb_write_from_arbiter_2.tag       = cdb_bus_2.tag;
    cdb_write_from_arbiter_2.value     = cdb_bus_2.value;
    cdb_write_from_arbiter_2.exception = cdb_bus_2.exception;
    cdb_write_from_arbiter_2.exc_cause = cdb_bus_2.exc_cause;
    cdb_write_from_arbiter_2.fp_flags  = cdb_bus_2.fp_flags;
  end

  // ===========================================================================
  // Dispatch routing -> dispatch_routing/dispatch_rs_router.sv.
  // Receiving nets keep (* max_fanout = 32 *): the fanout to the RS instances
  // happens here, so the constraint must live on the wrapper-side net.
  // ===========================================================================
  // dispatch_rs_type is also read by the rs_type case below, so keep a wrapper
  // copy (the router computes its own internally from the same i_rs_dispatch).
  wire [2:0] dispatch_rs_type = i_rs_dispatch.rs_type;
  (* max_fanout = 32 *) logic int_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid;
  (* max_fanout = 32 *) logic int_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid_2;
  logic int_rs_intent_1;
  logic mul_rs_intent_1;
  logic mem_rs_intent_1;
  logic fp_rs_intent_1;

  dispatch_rs_router #(
      .SPLIT_RS_DISPATCH(SPLIT_RS_DISPATCH)
  ) dispatch_rs_router_inst (
      .i_rs_dispatch(i_rs_dispatch),
      .i_int_rs_dispatch(i_int_rs_dispatch),
      .i_mul_rs_dispatch(i_mul_rs_dispatch),
      .i_mem_rs_dispatch(i_mem_rs_dispatch),
      .i_fp_rs_dispatch(i_fp_rs_dispatch),
      .i_int_rs_dispatch_2(i_int_rs_dispatch_2),
      .i_mul_rs_dispatch_2(i_mul_rs_dispatch_2),
      .i_mem_rs_dispatch_2(i_mem_rs_dispatch_2),
      .i_fp_rs_dispatch_2(i_fp_rs_dispatch_2),
      .i_backend_recovery_hold(i_backend_recovery_hold),
      .o_int_rs_dispatch_valid(int_rs_dispatch_valid),
      .o_mul_rs_dispatch_valid(mul_rs_dispatch_valid),
      .o_mem_rs_dispatch_valid(mem_rs_dispatch_valid),
      .o_fp_rs_dispatch_valid(fp_rs_dispatch_valid),
      .o_int_rs_dispatch_valid_2(int_rs_dispatch_valid_2),
      .o_mul_rs_dispatch_valid_2(mul_rs_dispatch_valid_2),
      .o_mem_rs_dispatch_valid_2(mem_rs_dispatch_valid_2),
      .o_fp_rs_dispatch_valid_2(fp_rs_dispatch_valid_2),
      .o_int_rs_intent_1(int_rs_intent_1),
      .o_mul_rs_intent_1(mul_rs_intent_1),
      .o_mem_rs_intent_1(mem_rs_intent_1),
      .o_fp_rs_intent_1(fp_rs_intent_1)
  );

  // Internal full signals for mux
  logic int_rs_full_w;
  logic mul_rs_full_w;
  logic mem_rs_full_w;
  logic fp_rs_full_w;
  logic fp_rs_full_raw;
  logic fp_rs_empty_raw;
  logic [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] fp_rs_count_raw;

  // Per-RS full_for_2 outputs.  Plumbed through to consumers so dispatch
  // can independently gate slot-2.  FP_RS buffers dispatch through a 1-deep
  // pending stage, so its effective full_for_2 also accounts for the pending
  // slot.
  logic int_rs_full_for_2_w;
  logic mul_rs_full_for_2_w;
  logic mem_rs_full_for_2_w;
  logic fp_rs_full_for_2_raw;
  // Limit FP pending-valid fanout to capture and dispatch back-pressure.
  (* max_fanout = 32 *) logic fp_dispatch_pending_valid;
  riscv_pkg::rs_dispatch_t fp_dispatch_pending;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_to_rs;
  logic fp_dispatch_dequeue;
  logic fp_dispatch_dequeue_room;
  logic fp_dispatch_slot_available;
  logic fp_dispatch_pending_flushed;
  // High in E1, the cycle after an FP packet is captured, when the done-repair
  // response to its source queries (channels 1 to 3) arrives.
  logic fp_pending_repair_capture_q;
  // Register whether the packet has unresolved sources at capture for timing.
  // Production dispatch queries every unresolved source. Keep such a packet
  // through E1, then pass the repaired packet into FP_RS on a later edge.
  (* max_fanout = 32 *) logic fp_pending_repair_wait_q;
  logic fp_repair_window_block;

  // o_rs_full: dispatch-target mux (not the INT_RS full; use o_int_rs_full)
  always_comb begin
    case (dispatch_rs_type)
      riscv_pkg::RS_INT: o_rs_full = int_rs_full_w;
      riscv_pkg::RS_MUL: o_rs_full = mul_rs_full_w;
      riscv_pkg::RS_MEM: o_rs_full = mem_rs_full_w;
      riscv_pkg::RS_FP:  o_rs_full = fp_rs_full_w;
      default:           o_rs_full = 1'b0;
    endcase
  end

  // Per-RS full output ports (dedicated, not muxed)
  assign o_int_rs_full = int_rs_full_w;
  assign o_mul_rs_full = mul_rs_full_w;
  assign o_mem_rs_full = mem_rs_full_w;
  assign o_fp_rs_full = fp_rs_full_w;

  // Per-RS full_for_2 output ports.  For FP_RS the pending buffer occupies an
  // extra "virtual" slot, so it reports full_for_2 whenever its buffer is
  // occupied.  The other RSes forward the RS-internal full_for_2 signal.
  assign o_int_rs_full_for_2 = int_rs_full_for_2_w;
  assign o_mul_rs_full_for_2 = mul_rs_full_for_2_w;
  assign o_mem_rs_full_for_2 = mem_rs_full_for_2_w;
  assign o_fp_rs_full_for_2 = fp_rs_full_for_2_raw || fp_dispatch_pending_valid;

  assign fp_repair_window_block = fp_pending_repair_wait_q;
  assign fp_dispatch_dequeue_room = fp_dispatch_pending_valid &&
      !fp_rs_full_raw &&
      !fp_repair_window_block;
  assign fp_dispatch_dequeue = fp_dispatch_dequeue_room &&
      !speculative_flush_all &&
      !speculative_flush_en &&
      !i_backend_recovery_hold;
  assign fp_dispatch_slot_available = !fp_dispatch_pending_valid || fp_dispatch_dequeue_room;
  assign fp_dispatch_pending_flushed = speculative_flush_all ||
      (speculative_flush_en &&
       fp_dispatch_pending_valid &&
       is_younger(
      fp_dispatch_pending.rob_tag, i_flush_tag, head_tag
  ));
  assign fp_rs_full_w = fp_rs_full_raw || (fp_dispatch_pending_valid && !fp_dispatch_dequeue_room);
  assign o_fp_rs_empty = fp_rs_empty_raw && !fp_dispatch_pending_valid;
  assign o_fp_rs_count = fp_rs_count_raw + {{($bits(
      o_fp_rs_count
  ) - 1) {1'b0}}, fp_dispatch_pending_valid};

  // ===========================================================================
  // ALU Pipeline: INT_RS issue -> shim -> adapter -> CDB arbiter slot 0
  // ===========================================================================
  riscv_pkg::rs_issue_t int_rs_issue_raw;  // INT_RS issue output
  riscv_pkg::rs_issue_t int_rs_issue_w;  // INT_RS issue output
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] int_rs_branch_predicate_tag;
  // alu_shim_out, alu_adapter_to_arbiter, and its pending bit are declared
  // above because the effective CDB packet uses them before this pipeline.
  logic alu_fu_busy;  // always 0 for single-cycle ALU
  logic int_rs_fu_ready;
  // Second INT issue pipe (ALU2): its own adapter back-pressure gate.
  riscv_pkg::rs_issue_t int_rs_issue_2_raw;
  riscv_pkg::rs_issue_t int_rs_issue_2_w;
  logic [5:0] int_rs_issue_shift_amount_2;
  logic int_rs_fu_ready_2;
  logic int_rs_issue_writes_cdb_hint_2;
  logic alu2_fu_busy;

  assign int_rs_fu_ready = i_rs_fu_ready & ~alu_adapter_result_pending & ~i_backend_recovery_hold;
  assign int_rs_fu_ready_2 = i_rs_fu_ready & ~alu2_adapter_result_pending &
      ~i_backend_recovery_hold;

  // ===========================================================================
  // MUL/DIV Pipeline: MUL_RS issue -> shim -> adapters -> CDB arbiter slots 1,2
  // ===========================================================================
  riscv_pkg::rs_issue_t    mul_rs_issue_raw;  // MUL_RS issue output (internal)
  riscv_pkg::rs_issue_t    mul_rs_issue_w;  // MUL_RS issue output (internal)
  riscv_pkg::fu_complete_t mul_shim_out;  // shim MUL -> adapter
  riscv_pkg::fu_complete_t div_shim_out;  // shim DIV -> adapter
  // mul/div_adapter_to_arbiter declared above (forward declaration)
  logic                    mul_adapter_result_pending;
  logic                    div_adapter_result_pending;
  logic                    muldiv_busy;
  logic                    div_busy;
  logic                    mul_rs_fu_ready;

  // muldiv_busy is the multiplier path's credit-based back-pressure (FIFO
  // occupancy in the shim). Adapter-pending bits do not gate new issues: the
  // MUL FIFO absorbs transient CDB stalls, and the divider holds its result
  // until the DIV adapter is free. Divides do not lower this ready: MUL_RS
  // holds them back itself while div_busy is high.
  assign mul_rs_fu_ready = i_mul_rs_fu_ready & ~muldiv_busy & ~i_backend_recovery_hold;

  // Accept a shim result only when its adapter is idle. A pending result
  // drains first, then the FIFO/divider result transfers next cycle, for timing.
  logic mul_result_accepted;
  assign mul_result_accepted = !mul_adapter_result_pending && mul_shim_out.valid;

  logic div_result_accepted;
  assign div_result_accepted = !div_adapter_result_pending && div_shim_out.valid;

  // ===========================================================================
  // MEM (Load) Pipeline: LQ -> adapter -> CDB arbiter slot 3
  // ===========================================================================
  riscv_pkg::fu_complete_t lq_fu_complete;  // LQ -> adapter
  logic lq_fu_complete_staged;  // registered LQ CDB-stage occupancy, flush-free
  // mem_adapter_to_arbiter declared above (forward declaration)
  logic mem_adapter_result_pending;
  logic lq_result_accepted;
  logic lq_l0_hit;  // LQ L0 cache fast-path completion (perf counter)
  logic lq_l0_fill;  // LQ L0 cache fill from memory response (perf counter)
  logic lq_mem_outstanding;  // LQ has a memory response in flight (perf, router checks)
  // Head-load sub-bucket state (from LQ, split head_wait_load_no_outstanding)
  logic lq_head_load_addr_pending;
  logic lq_head_load_sq_disambig;
  logic lq_head_load_bus_blocked;
  logic lq_head_load_cdb_wait;
  logic lq_head_load_post_lq;
  // bus_blocked sub-buckets (mutually exclusive partition of bus_blocked)
  logic lq_head_load_bb_bus_busy;
  logic lq_head_load_bb_sq_wait;
  logic lq_head_load_bb_staging;
  logic lq_head_load_bbs_other_in_staging;
  logic lq_head_load_bbs_launch_gated;
  logic lq_head_load_bbs_capture_gap;

  function automatic logic is_mem_access_misaligned(input riscv_pkg::mem_size_e size,
                                                    input logic [riscv_pkg::XLEN-1:0] addr);
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF:   is_mem_access_misaligned = addr[0];
      riscv_pkg::MEM_SIZE_WORD:   is_mem_access_misaligned = |addr[1:0];
      riscv_pkg::MEM_SIZE_DOUBLE: is_mem_access_misaligned = |addr[2:0];
      default:                    is_mem_access_misaligned = 1'b0;
    endcase
  endfunction

  // ===========================================================================
  // SQ <-> LQ Internal Wiring (store-to-load forwarding)
  // ===========================================================================
  logic sq_check_valid;
  logic sq_check_capture_valid;  // flush-free capture-enable variant
  logic [riscv_pkg::XLEN-1:0] sq_check_addr;
  // Identical same-edge LQ address copies, one per SQ CAM quarter, for fanout.
  logic [riscv_pkg::XLEN-1:0] sq_check_addr_b;
  logic [riscv_pkg::XLEN-1:0] sq_check_addr_c;
  logic [riscv_pkg::XLEN-1:0] sq_check_addr_d;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_check_rob_tag;
  riscv_pkg::mem_size_e sq_check_size;
  logic sq_all_older_addrs_known;
  riscv_pkg::sq_forward_result_t sq_forward;

  logic lq_full_exact;
  logic lq_full_for_2_exact;
  logic lq_empty_exact;
  logic [$clog2(riscv_pkg::LqDepth+1)-1:0] lq_count_exact;
  logic sq_full_exact;
  logic sq_full_for_2_exact;
  logic sq_empty_exact;
  logic [$clog2(riscv_pkg::SqDepth+1)-1:0] sq_count_exact;

  logic sq_cache_invalidate_valid;
  logic [riscv_pkg::XLEN-1:0] sq_cache_invalidate_addr;

  // ===========================================================================
  // Atomics Wiring (LR/SC/AMO support)
  // ===========================================================================
  // Reservation register (LQ -> SC resolution and the snoop invalidate below)
  logic lq_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] lq_reservation_addr;

  // SQ committed-empty (SQ -> SC resolution, coherence port, and
  // o_sq_committed_empty). The ROB, the LQ, and the trap unit take the store
  // queue's placement copies of the same register.
  logic sq_committed_empty;
  logic sq_committed_empty_rob;
  logic sq_committed_empty_lq;
  assign o_sq_committed_empty = sq_committed_empty;

  // Any SC commit, success or failure, clears the reservation via registered commit.
  logic sc_clear_reservation;
  assign sc_clear_reservation = commit_bus_q_valid && commit_q_is_sc;

  // Reservation snoop invalidation: SQ write to the reservation address. The
  // reservation covers a doubleword (RV64A: LR.D reserves one, and a granule
  // may exceed the LR width), so any store in the dword kills it.
  logic reservation_snoop_invalidate;
  assign reservation_snoop_invalidate = sq_cache_invalidate_valid &&
      lq_reservation_valid &&
      (sq_cache_invalidate_addr[riscv_pkg::XLEN-1:3] ==
       lq_reservation_addr[riscv_pkg::XLEN-1:3]);

  // A failed SC invalidates its SQ entry via registered commit.
  logic sc_discard;
  assign sc_discard = commit_bus_q_valid && commit_q_sc_failed;

  // Store commits feed both the LQ commit interlock and the SQ.
  logic sq_commit_valid;
  assign sq_commit_valid = commit_bus_q_valid && commit_q_is_store_like && !sc_discard;
  // Widen-commit slot 2: a second simultaneous store retire.  Slot 2 can
  // never be an SC, so no sc_discard gate.
  logic sq_commit_valid_2;
  assign sq_commit_valid_2 = commit_bus_2_q_valid && commit_q_2_is_store_like;

  // Forwarding scan pulses omit the full-flush mask for timing. LQ phase-2
  // state clears on that edge, making the captured result unused. Architectural
  // side effects, committed-empty, and flush exemptions must use masked pulses.
  logic sc_discard_raw;
  assign sc_discard_raw = commit_bus_q_valid_raw && commit_q_sc_failed;
  logic sq_commit_valid_scan;
  assign sq_commit_valid_scan = commit_bus_q_valid_raw && commit_q_is_store_like && !sc_discard_raw;
  logic sq_commit_valid_scan_2;
  assign sq_commit_valid_scan_2 = commit_bus_2_q_valid_raw && commit_q_2_is_store_like;

  // ===========================================================================
  // SC completion hand-off: sc_pending_unit tracks in-flight SCs in a ROB-tag
  // table and fires the one at the ROB head once the SQ is committed-empty
  // ===========================================================================
  logic sc_pending;
  // Forward declaration (assigned in SQ address section below)
  logic [riscv_pkg::XLEN-1:0] sq_effective_addr;

  // Compare ROB ages for FP pending-dispatch and store-fault flush guards.
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
  riscv_pkg::fu_complete_t sc_fu_complete;  // driven by sc_pending_unit
  logic store_issue_fire;
  logic store_misalign_issue;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] store_complete_tag;

  // Plain stores mark the ROB done at MEM_RS issue without translation, or
  // at a successful MMU S2 result with translation. SC completes through
  // sc_pending_unit, but still takes issue-time faults: the specs require
  // misaligned and permission-faulting SCs to raise exceptions even if their
  // reservations fail. Spike follows this rule; Linux futex COW depends on it.
  //
  // PMA faults (cause 7) share the misalignment strobe. Faulting stores never
  // commit or drain. Without translation, PMA faults outrank misalignment
  // (the privileged spec allows either order; the MMU checks alignment first).
  // PMA checks apply even when i_trap_misaligned_accesses is clear. SC uses the
  // atomic map, which excludes the device quadrant.
  //
  // With translation, all store faults come from MMU S2: VA misalignment,
  // page faults, or PA access faults. The legacy strobe is disabled, and SQ
  // address updates require an MMU-checked PA.
  logic store_pma_issue;
  logic store_misalign_issue_legacy;
  logic dmmu_store_fault;
  logic dmmu_store_ok;

  // Store immediates are sign-extended S-immediates or zero (SC), so they can
  // move the base by at most one 4 KiB page. The low 13-bit sum supplies the
  // page carry and alignment bits. Legal store pages are [0, 0x3f] and
  // [0x40000, 0xbffff], as in riscv_pkg::pma_store_ok. The device quadrant
  // includes unserved addresses, whose writes the device bus ignores.
  //
  // A one-page move changes membership only at interval boundaries. The
  // boundary checks below compute pma_store_ok(src1 + sext12(imm)). SC has a
  // zero immediate and excludes device pages, yielding pma_atomic_ok(src1).
  // Keep the 13-bit tap explicit for synthesis; sq_effective_addr retains the
  // full address for the SQ and xtval.
  (* keep = "true" *) logic [12:0] store_page_offset_sum;
  logic store_base_z18;
  logic store_base_z19;
  logic store_base_z30;
  logic store_base_z32;
  logic store_base_page_lo6_zero;
  logic store_base_page_lo6_ones;
  logic store_base_page_tail_zero;
  logic store_base_page_tail_ones;
  logic store_base_pma_ok;
  logic store_base_page_eq_0;
  logic store_base_page_eq_3f;
  logic store_base_page_eq_40;
  logic store_base_page_eq_3ffff;
  logic store_base_page_eq_40000;
  logic store_base_page_eq_bffff;
  logic store_base_page_eq_c0000;
  logic store_base_page_eq_max;
  logic store_page_inc_toggle;
  logic store_page_dec_toggle;
  (* keep = "true" *) logic store_pma_without_page_carry;
  (* keep = "true" *) logic store_pma_with_page_carry;
  logic store_addr_pma_ok;
  logic store_addr_misaligned;
  logic mem_rs_issue_is_sc;

  assign store_page_offset_sum =
      {1'b0, o_mem_rs_issue.src1_value[11:0]} + {1'b0, o_mem_rs_issue.imm[11:0]};
  assign store_base_z18 = !(|o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:18]);
  assign store_base_z19 = !(|o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:19]);
  assign store_base_z30 = !(|o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:30]);
  assign store_base_z32 = !(|o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:32]);
  assign store_base_page_lo6_zero = !(|o_mem_rs_issue.src1_value[17:12]);
  assign store_base_page_lo6_ones = &o_mem_rs_issue.src1_value[17:12];
  assign store_base_page_tail_zero = !(|o_mem_rs_issue.src1_value[29:12]);
  assign store_base_page_tail_ones = &o_mem_rs_issue.src1_value[29:12];

  assign mem_rs_issue_is_sc = (o_mem_rs_issue.op == riscv_pkg::SC_W) ||
      (o_mem_rs_issue.op == riscv_pkg::SC_D);
  assign store_base_pma_ok = store_base_z18 ||
      (store_base_z32 && ((o_mem_rs_issue.src1_value[31:30] == 2'b10) ||
                          ((o_mem_rs_issue.src1_value[31:30] == 2'b01) &&
                           !mem_rs_issue_is_sc)));
  assign store_base_page_eq_0 = store_base_z18 && store_base_page_lo6_zero;
  assign store_base_page_eq_3f = store_base_z18 && store_base_page_lo6_ones;
  assign store_base_page_eq_40 = store_base_z19 && o_mem_rs_issue.src1_value[18] &&
      store_base_page_lo6_zero;
  assign store_base_page_eq_3ffff = store_base_z30 && store_base_page_tail_ones;
  assign store_base_page_eq_40000 = store_base_z32 &&
      (o_mem_rs_issue.src1_value[31:30] == 2'b01) && store_base_page_tail_zero;
  assign store_base_page_eq_bffff = store_base_z32 &&
      (o_mem_rs_issue.src1_value[31:30] == 2'b10) && store_base_page_tail_ones;
  assign store_base_page_eq_c0000 = store_base_z32 &&
      (o_mem_rs_issue.src1_value[31:30] == 2'b11) && store_base_page_tail_zero;
  assign store_base_page_eq_max = &o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:12];

  assign store_page_inc_toggle = store_base_page_eq_max || store_base_page_eq_3f ||
      store_base_page_eq_3ffff || store_base_page_eq_bffff;
  assign store_page_dec_toggle = store_base_page_eq_0 || store_base_page_eq_40 ||
      store_base_page_eq_40000 || store_base_page_eq_c0000;
  // Without a carry, only a negative immediate changes the page. With a
  // carry, only a nonnegative immediate does. Select between both cases.
  assign store_pma_without_page_carry = store_base_pma_ok ^
      (o_mem_rs_issue.imm[11] && store_page_dec_toggle);
  assign store_pma_with_page_carry = store_base_pma_ok ^
      (!o_mem_rs_issue.imm[11] && store_page_inc_toggle);
  assign store_addr_pma_ok = store_page_offset_sum[12] ? store_pma_with_page_carry :
      store_pma_without_page_carry;
  assign store_addr_misaligned = is_mem_access_misaligned(
      riscv_pkg::mem_size_e'(o_mem_rs_issue.mem_size),
      {
        {(riscv_pkg::XLEN - 3) {1'b0}}, store_page_offset_sum[2:0]
      }
  );

  assign store_pma_issue =
      !i_translation_active &&
      o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
      !store_addr_pma_ok;
  assign store_misalign_issue_legacy =
      store_pma_issue ||
      (!i_translation_active && i_trap_misaligned_accesses &&
       o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
       store_addr_misaligned);
  assign store_misalign_issue = i_translation_active ? dmmu_store_fault
                                                     : store_misalign_issue_legacy;
  // Declared here, driven in the dmmu section below (the MMU's issue-out
  // pulse split by fault/ok and routed by its needs_sq echo).
  logic dmmu_out_is_sc;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dmmu_out_tag;
  // Factor the untranslated done predicate for timing. It uses the same PMA
  // and alignment checks as store_misalign_issue; fault priority is unchanged.
  (* keep = "true" *) logic store_issue_translated;
  (* keep = "true" *) logic store_issue_untranslated_without_pma;
  assign store_issue_translated = dmmu_store_ok && !dmmu_out_is_sc;
  assign store_issue_untranslated_without_pma =
      o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq && !mem_rs_issue_is_sc &&
      (!i_trap_misaligned_accesses || !store_addr_misaligned);
  assign store_issue_fire = i_translation_active ? store_issue_translated :
      (store_issue_untranslated_without_pma && store_addr_pma_ok);
  assign store_complete_tag = i_translation_active ? dmmu_out_tag : o_mem_rs_issue.rob_tag;

`ifndef SYNTHESIS
`ifndef FORMAL
  // Full-address reference versions of the 4 KiB page split and the
  // untranslated store-fire reduction, compared with four-state equality.
  // The check applies only while translation is off; the translated DMMU
  // sidebands may be don't-care then.
  logic store_addr_pma_ok_full_ref;
  logic store_addr_misaligned_full_ref;
  logic store_misalign_issue_full_ref;
  logic store_issue_fire_full_ref;
  assign store_addr_pma_ok_full_ref = mem_rs_issue_is_sc ? riscv_pkg::pma_atomic_ok(
      sq_effective_addr
  ) : riscv_pkg::pma_store_ok(
      sq_effective_addr
  );
  assign store_addr_misaligned_full_ref = is_mem_access_misaligned(
      riscv_pkg::mem_size_e'(o_mem_rs_issue.mem_size), sq_effective_addr
  );
  assign store_misalign_issue_full_ref =
      !i_translation_active && o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
      (!store_addr_pma_ok_full_ref ||
       (i_trap_misaligned_accesses && store_addr_misaligned_full_ref));
  assign store_issue_fire_full_ref = i_translation_active ?
      (dmmu_store_ok && !dmmu_out_is_sc) :
      (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
       (o_mem_rs_issue.op != riscv_pkg::SC_W) &&
       (o_mem_rs_issue.op != riscv_pkg::SC_D) &&
       store_addr_pma_ok_full_ref &&
       (!i_trap_misaligned_accesses || !store_addr_misaligned_full_ref));
  always_comb begin
    if (i_rst_n && (i_translation_active === 1'b0) && !$isunknown(
            {o_mem_rs_issue.valid,
             o_mem_rs_issue.mem_needs_sq,
             o_mem_rs_issue.op,
             o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0],
             o_mem_rs_issue.imm,
             i_trap_misaligned_accesses,
             o_mem_rs_issue.mem_size}
        )) begin
      if (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq) begin
        p_store_simm12_contract :
        assert (
            o_mem_rs_issue.imm[riscv_pkg::XLEN-1:12] ==
            {(riscv_pkg::XLEN - 12) {o_mem_rs_issue.imm[11]}}
        );
        p_store_sc_imm_zero : assert (!mem_rs_issue_is_sc || (o_mem_rs_issue.imm == '0));
        if (o_mem_rs_issue.imm[riscv_pkg::XLEN-1:12] ==
            {(riscv_pkg::XLEN - 12) {o_mem_rs_issue.imm[11]}}) begin
          p_store_page_pma_exact : assert (store_addr_pma_ok === store_addr_pma_ok_full_ref);
          p_store_page_align_exact :
          assert (store_addr_misaligned === store_addr_misaligned_full_ref);
          p_store_misalign_exact :
          assert (store_misalign_issue_legacy === store_misalign_issue_full_ref);
        end
      end
      if (!o_mem_rs_issue.valid || !o_mem_rs_issue.mem_needs_sq ||
          (o_mem_rs_issue.imm[riscv_pkg::XLEN-1:12] ==
           {(riscv_pkg::XLEN - 12) {o_mem_rs_issue.imm[11]}})) begin
        p_store_issue_fire_flatten_exact : assert (store_issue_fire === store_issue_fire_full_ref);
      end
    end
  end
`endif
`endif

  riscv_pkg::fu_complete_t store_misalign_fu_complete_reg;

  // Register SC completion for timing, adding one cycle. A registered store
  // fault has priority because it cannot wait and another fault may follow.
  // SC holds its completion and cannot fire again until that result is consumed.
  //
  // Capture payload whenever no completion waits. Valid rises only on SC fire,
  // so the visible payload belongs to that SC and stays fixed until consumed.
  riscv_pkg::fu_complete_t sc_fu_complete_reg;
  logic sc_completion_held;
  assign sc_completion_held = sc_fu_complete_reg.valid && store_misalign_fu_complete_reg.valid;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) sc_fu_complete_reg.valid <= 1'b0;
    else sc_fu_complete_reg.valid <= sc_fu_complete.valid || sc_completion_held;

    if (!sc_fu_complete_reg.valid) begin
      sc_fu_complete_reg.tag <= sc_fu_complete.tag;
      sc_fu_complete_reg.value <= sc_fu_complete.value;
      sc_fu_complete_reg.exception <= sc_fu_complete.exception;
      sc_fu_complete_reg.exc_cause <= sc_fu_complete.exc_cause;
      sc_fu_complete_reg.fp_flags <= sc_fu_complete.fp_flags;
    end
  end

`ifndef SYNTHESIS
  // Reference payload with the fire enable, for p_sc_completion_payload_exact
  // in the SC completion checks below.
  riscv_pkg::fu_complete_t sc_fu_complete_payload_ref_q;
  always_ff @(posedge i_clk) begin
    if (sc_fu_complete.valid) sc_fu_complete_payload_ref_q <= sc_fu_complete;
  end
`endif

  // Copies of sc_fu_complete_reg.valid for fanout. Each has the same reset
  // and transition function, so all copies stay equal. DONT_TOUCH prevents
  // synthesis from merging them.
  (* dont_touch = "true" *)logic sc_valid_adapter_q;
  (* dont_touch = "true" *)logic sc_valid_lq_q;
  (* dont_touch = "true" *)logic sc_valid_issue_q;
  (* dont_touch = "true" *)logic sc_valid_wakeup_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      sc_valid_adapter_q <= 1'b0;
      sc_valid_lq_q      <= 1'b0;
      sc_valid_issue_q   <= 1'b0;
      sc_valid_wakeup_q  <= 1'b0;
    end else begin
      sc_valid_adapter_q <= sc_fu_complete.valid ||
          (sc_valid_adapter_q && store_misalign_fu_complete_reg.valid);
      sc_valid_lq_q <= sc_fu_complete.valid ||
          (sc_valid_lq_q && store_misalign_fu_complete_reg.valid);
      sc_valid_issue_q <= sc_fu_complete.valid ||
          (sc_valid_issue_q && store_misalign_fu_complete_reg.valid);
      sc_valid_wakeup_q <= sc_fu_complete.valid ||
          (sc_valid_wakeup_q && store_misalign_fu_complete_reg.valid);
    end
  end

  // Fault-kind echo and address from the dmmu (driven in its section below).
  riscv_pkg::data_fault_kind_e dmmu_out_fault;
  logic [riscv_pkg::XLEN-1:0] dmmu_out_addr;

  riscv_pkg::fu_complete_t store_misalign_fu_complete;
  always_comb begin
    store_misalign_fu_complete = '0;
    store_misalign_fu_complete.valid = store_misalign_issue;
    store_misalign_fu_complete.exception = 1'b1;
    if (i_translation_active) begin
      // Store-family causes from the MMU's fault kind: misalign (6), page
      // fault (15), access fault (7). SC rides the same strobe.
      store_misalign_fu_complete.tag = dmmu_out_tag;
      unique case (dmmu_out_fault)
        riscv_pkg::DFAULT_PAGE:
        store_misalign_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
            riscv_pkg::ExcStorePageFault[riscv_pkg::ExcCauseWidth-1:0]);
        riscv_pkg::DFAULT_ACCESS:
        store_misalign_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
            riscv_pkg::ExcStoreAccessFault[riscv_pkg::ExcCauseWidth-1:0]);
        default:
        store_misalign_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
            riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]);
      endcase
      // The MMU parks the virtual address for xtval on every fault.
      store_misalign_fu_complete.value = {
        {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, dmmu_out_addr
      };
    end else begin
      store_misalign_fu_complete.tag = o_mem_rs_issue.rob_tag;
      store_misalign_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
          store_pma_issue ? riscv_pkg::ExcStoreAccessFault[riscv_pkg::ExcCauseWidth-1:0] :
                            riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]);
      // Carry the faulting VA in value for the ROB's xtval. The privileged spec
      // allows zero; a nonzero xtval must be the faulting VA.
      store_misalign_fu_complete.value = {
        {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, sq_effective_addr
      };
    end
  end

  // Register store faults for timing, adding one cycle. Reject faults younger
  // than a partial flush. The adapter filters a killed held packet; still
  // capture a new fault, which may be older and survive that flush.
  logic store_misalign_input_flushed;
  assign store_misalign_input_flushed = speculative_flush_en &&
      store_misalign_fu_complete.valid &&
      is_younger(
      store_misalign_fu_complete.tag, i_flush_tag, head_tag
  );
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      store_misalign_fu_complete_reg.valid <= 1'b0;
    end else begin
      store_misalign_fu_complete_reg.valid <=
          store_misalign_fu_complete.valid && !store_misalign_input_flushed;
    end

    store_misalign_fu_complete_reg.tag <= store_misalign_fu_complete.tag;
    store_misalign_fu_complete_reg.value <= store_misalign_fu_complete.value;
    store_misalign_fu_complete_reg.exception <= store_misalign_fu_complete.exception;
    store_misalign_fu_complete_reg.exc_cause <= store_misalign_fu_complete.exc_cause;
    store_misalign_fu_complete_reg.fp_flags <= store_misalign_fu_complete.fp_flags;
  end

  // MEM priority is store fault, then SC, then LQ. Store faults cannot wait;
  // SC holds while a fault is present. Giving SC priority would broadcast it
  // while also holding it for a duplicate delivery.
  // Nonfaulting plain stores mark the ROB done directly without using the CDB.
  riscv_pkg::fu_complete_t mem_fu_to_adapter;
  always_comb begin
    if (store_misalign_fu_complete_reg.valid) begin
      mem_fu_to_adapter = store_misalign_fu_complete_reg;
    end else if (sc_valid_adapter_q) begin
      mem_fu_to_adapter = sc_fu_complete_reg;
      mem_fu_to_adapter.valid = 1'b1;
    end else begin
      mem_fu_to_adapter = lq_fu_complete;
    end
  end

  // LQ yields to registered SC completions and store faults. SC fires only
  // when the LQ has no result. Acceptance must match the presentation mux.
  // Unless cdb_kill is set, MEM always wins one of two CDB lanes: only MUL
  // outranks it. Pop each result once to avoid rebroadcasting a recycled tag.
  // A live store fault takes the MEM slot next cycle and needs no yield yet.
  assign lq_result_accepted = lq_fu_complete.valid &&
                              !sc_valid_lq_q &&
                              !store_misalign_fu_complete_reg.valid &&
                              !mem_adapter_result_pending;

`ifndef SYNTHESIS
  // ---------------------------------------------------------------------------
  // SC completion must broadcast exactly once. Observe the actual MEM packet
  // and grant: inferring delivery from mux priority could hide an SC broadcast
  // while a store fault holds it, followed by a duplicate on release.
  //
  // The MEM adapter must be idle on release; ALLOW_GRANT_REFILL=0 cannot accept
  // input while pending. A granted MEM packet with the SC tag completes the
  // handoff. Other MEM sources cannot carry this tag: faulting SCs lose their
  // table entries before they can fire, and LQ results belong to loads.
  logic sc_cdb_transfer;
  assign sc_cdb_transfer = sc_fu_complete_reg.valid && mem_adapter_to_arbiter.valid &&
      o_cdb_grant[riscv_pkg::FU_MEM] &&
      (mem_adapter_to_arbiter.tag == sc_fu_complete_reg.tag);

  // Use shadow registers so these checks work in simulation and formal.
  // sc_check_armed suppresses checks until reset initializes the state.
  /* verilator lint_off MULTIDRIVEN */  // power-up value plus the reset arm below
  logic sc_check_armed;
  /* verilator lint_on MULTIDRIVEN */
  logic sc_completion_valid_q;
  logic sc_completion_fire_q;
  logic sc_completion_flush_all_q;
  logic sc_cdb_transfer_q;
  initial sc_check_armed = 1'b0;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sc_check_armed            <= 1'b1;
      sc_completion_valid_q     <= 1'b0;
      sc_completion_fire_q      <= 1'b0;
      sc_completion_flush_all_q <= 1'b0;
      sc_cdb_transfer_q         <= 1'b0;
    end else begin
      sc_completion_valid_q     <= sc_fu_complete_reg.valid;
      sc_completion_fire_q      <= sc_fu_complete.valid;
      sc_completion_flush_all_q <= speculative_flush_all;
      sc_cdb_transfer_q         <= sc_cdb_transfer;
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n && sc_check_armed) begin
      // 1. A new SC must not overwrite an undelivered completion.
      if (sc_fu_complete.valid) begin
        p_sc_fire_needs_free_completion_reg : assert (!sc_fu_complete_reg.valid);
      end

      // 2. Release requires an idle adapter. MEM is second in priority on a
      //    two-lane CDB, so every presented packet wins a lane unless cdb_kill
      //    also flushes the adapter. Recheck this if arbitration changes.
      if (sc_fu_complete_reg.valid && !store_misalign_fu_complete_reg.valid) begin
        p_sc_completion_release_adapter_idle : assert (!mem_adapter_result_pending);
      end

      // 3. A waiting SC is still the ROB head: it cannot retire before its
      //    result arrives. No partial-flush boundary can be older than it.
      if (sc_fu_complete_reg.valid && speculative_flush_en && !speculative_flush_all) begin
        p_sc_completion_partial_flush_cannot_kill :
        assert (!is_younger(sc_fu_complete_reg.tag, i_flush_tag, head_tag));
      end

      // 4. Without a higher-priority fault or full flush, the SC must broadcast.
      if (sc_fu_complete_reg.valid && !store_misalign_fu_complete_reg.valid &&
          !speculative_flush_all) begin
        p_sc_completion_release_is_granted : assert (sc_cdb_transfer);
      end

      // 5. A completion stays valid until broadcast or full flush. Clearing it
      //    early loses a result; holding it after broadcast duplicates one.
      p_sc_completion_token_conserved :
      assert (sc_fu_complete_reg.valid ==
              (!sc_completion_flush_all_q &&
               (sc_completion_fire_q || (sc_completion_valid_q && !sc_cdb_transfer_q))));

      // 6. All completion-valid copies must agree.
      p_sc_valid_copies_match :
      assert ({sc_valid_adapter_q, sc_valid_lq_q, sc_valid_issue_q, sc_valid_wakeup_q} ==
              {4{sc_fu_complete_reg.valid}});

      // 7. Idle payload capture must match capture enabled only by SC fire.
      if (sc_fu_complete_reg.valid) begin
        p_sc_completion_payload_exact :
        assert (sc_fu_complete_reg.tag == sc_fu_complete_payload_ref_q.tag &&
                sc_fu_complete_reg.value == sc_fu_complete_payload_ref_q.value &&
                sc_fu_complete_reg.exception == sc_fu_complete_payload_ref_q.exception &&
                sc_fu_complete_reg.exc_cause == sc_fu_complete_payload_ref_q.exc_cause &&
                sc_fu_complete_reg.fp_flags == sc_fu_complete_payload_ref_q.fp_flags);
      end
    end
  end
`endif

  // SC resolution and its pending table are in atomics/sc_pending_unit.sv
  // (instantiated below); the store-fault register, the MEM mux, and
  // lq_result_accepted are above.
  // ===========================================================================
  // DMA coherence port: admitted-line mirror, SC window, validation
  // table and the ROB's replay mask.
  // ===========================================================================
  logic coh_sc_hold, coh_sc_head_addr_valid, coh_sc_fire_success;
  logic coh_sc_head_query_match;
  logic [riscv_pkg::XLEN-1:0] coh_sc_head_addr;
  logic [riscv_pkg::XLEN-1:0] coh_lq_query_addr, coh_lq_inval_addr, coh_observe_addr;
  logic coh_lq_query_busy, coh_lq_inval_valid, coh_observe_valid;
  logic [riscv_pkg::DmaCoherenceLocks-1:0] coh_lq_block_valid;
  logic coh_lq_admit_pulse;
  logic [riscv_pkg::DmaCoherenceLocks-1:0][riscv_pkg::XLEN-1:0] coh_lq_block_addr;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] coh_observe_rob_tag;
  logic [riscv_pkg::ReorderBufferDepth-1:0] coh_replay_set_mask;

  lq_coherence_port #(
      .NUM_LOCK(riscv_pkg::DmaCoherenceLocks)
  ) u_coherence_port (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_admit_valid(i_coh_admit_valid),
      .i_admit_slot(i_coh_admit_slot),
      .i_admit_addr(i_coh_admit_addr),
      .o_admit_ready(o_coh_admit_ready),
      .i_inval_valid(i_coh_inval_valid),
      .i_inval_slot(i_coh_inval_slot),
      .o_inval_done(o_coh_inval_done),
      .i_release_valid(i_coh_release_valid),
      .i_release_slot(i_coh_release_slot),
      .o_lq_query_addr(coh_lq_query_addr),
      .i_lq_query_busy(coh_lq_query_busy),
      .o_lq_inval_valid(coh_lq_inval_valid),
      .o_lq_inval_addr(coh_lq_inval_addr),
      .o_lq_block_valid(coh_lq_block_valid),
      .o_lq_block_addr(coh_lq_block_addr),
      .o_lq_admit_pulse(coh_lq_admit_pulse),
      .i_observe_valid(coh_observe_valid),
      .i_observe_rob_tag(coh_observe_rob_tag),
      .i_observe_addr(coh_observe_addr),
      .i_sc_head_addr_valid(coh_sc_head_addr_valid),
      .i_sc_head_addr(coh_sc_head_addr),
      .i_sc_head_query_match(coh_sc_head_query_match),
      .i_sc_fire_success(coh_sc_fire_success),
      .i_sc_commit(sc_clear_reservation),
      .i_sq_committed_empty(sq_committed_empty),
      .o_sc_hold(coh_sc_hold),
      .i_commit_valid(commit_bus_q_valid),
      .i_commit_tag(commit_q_tag),
      .i_commit_valid_2(commit_bus_2_q_valid),
      .i_commit_tag_2(commit_q_2_tag),
      .i_flush_all(speculative_flush_all),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_head_tag(head_tag),
      .o_replay_set_mask(coh_replay_set_mask)
  );

  sc_pending_unit sc_pending_unit_inst (
      .i_clk                           (i_clk),
      .i_rst_n                         (i_rst_n),
      .i_flush_en                      (i_flush_en),
      .i_flush_tag                     (i_flush_tag),
      .i_head_tag                      (head_tag),
      .i_sq_committed_empty            (sq_committed_empty),
      .i_lq_reservation_valid          (lq_reservation_valid),
      .i_lq_reservation_addr           (lq_reservation_addr),
      .i_mem_adapter_result_pending    (mem_adapter_result_pending),
      .i_lq_fu_complete                (lq_fu_complete),
      .i_sc_completion_pending         (sc_fu_complete_reg.valid),
      .i_store_misalign_fu_complete_reg(store_misalign_fu_complete_reg),
      .i_mem_rs_issue                  (o_mem_rs_issue),
      .i_sq_effective_addr             (sq_effective_addr),
      .i_sct_alloc_addr_valid          (!i_translation_active),
      .i_sct_addr_fill_valid           (dmmu_store_ok && dmmu_out_is_sc),
      .i_sct_addr_fill_tag             (dmmu_out_tag),
      .i_sct_addr_fill_addr            (dmmu_out_addr),
      .i_speculative_flush_all         (speculative_flush_all),
      .i_speculative_flush_en          (speculative_flush_en),
      .i_coh_sc_hold                   (coh_sc_hold),
      .i_coh_query_addr                (coh_lq_query_addr),
      .o_sc_head_query_match           (coh_sc_head_query_match),
      .o_sc_head_addr_valid            (coh_sc_head_addr_valid),
      .o_sc_head_addr                  (coh_sc_head_addr),
      .o_sc_fire_success               (coh_sc_fire_success),
      .o_sc_pending                    (sc_pending),
      .o_sc_fu_complete                (sc_fu_complete)
  );

  // ===========================================================================
  // FP Pipeline: FP_RS issue -> fp_shim -> adapter -> CDB arbiter slot 4
  // ===========================================================================
  riscv_pkg::rs_issue_t fp_rs_issue_raw;  // FP_RS issue output (internal)
  riscv_pkg::rs_issue_t fp_rs_issue_w;  // FP_RS issue output (internal)
  riscv_pkg::fu_complete_t fp_shim_out;  // shim -> adapter
  // fp_adapter_to_arbiter declared above (forward declaration)
  logic fp_adapter_result_pending;
  logic fp_busy;
  logic fp_rs_fu_ready;

  assign fp_rs_fu_ready = i_fp_rs_fu_ready & ~fp_busy &
                          ~fp_adapter_result_pending & ~i_backend_recovery_hold;

  riscv_pkg::rs_issue_t mem_rs_issue_raw;
  riscv_pkg::rs_issue_t mem_rs_issue_w;
  logic mem_rs_next_is_sc;
  logic mem_rs_next_issue_valid;
  logic mem_rs_next_issue_needs_lq;
  logic mem_rs_fu_ready_base;
  logic mem_rs_fu_ready;

  // Multiple SCs may issue out of order; sc_pending_unit tracks each by ROB
  // tag. Gating all SC issue on sc_pending would let a younger SC block the
  // older head SC that must complete first.
  // dmmu_stall holds MEM_RS issue while the data MMU's skid register is
  // occupied (an op waiting behind a DTLB miss). It is zero while translation
  // is inactive.
  logic dmmu_stall;
  assign mem_rs_fu_ready_base = i_mem_rs_fu_ready &&
                                !sc_valid_issue_q &&
                                !mem_adapter_result_pending &&
                                !i_backend_recovery_hold &&
                                !dmmu_stall;

  // mem_rs_fu_ready_base includes registered SC completion, avoiding the live
  // SC tag comparison for timing.
  assign mem_rs_fu_ready = mem_rs_fu_ready_base;

  always_comb begin
    int_rs_issue_w = int_rs_issue_raw;
    if (i_backend_recovery_hold) int_rs_issue_w.valid = 1'b0;
    int_rs_issue_2_w = int_rs_issue_2_raw;
    if (i_backend_recovery_hold) int_rs_issue_2_w.valid = 1'b0;

    mul_rs_issue_w = mul_rs_issue_raw;
    if (i_backend_recovery_hold) mul_rs_issue_w.valid = 1'b0;

    mem_rs_issue_w = mem_rs_issue_raw;
    if (i_backend_recovery_hold) mem_rs_issue_w.valid = 1'b0;

    fp_rs_issue_w = fp_rs_issue_raw;
    if (i_backend_recovery_hold) fp_rs_issue_w.valid = 1'b0;
  end

  // ===========================================================================
  // Reorder Buffer Instance
  // ===========================================================================
  // SFENCE serialized-window level from the ROB; with csr_file's registered
  // translation-invalidate pulse it forms the DTLB/walker invalidate.
  logic rob_sfence_window;
  assign o_tlb_invalidate = rob_sfence_window || i_csr_translation_flush_req;

  reorder_buffer #(
      .SharedLinkBank(ROB_SHARED_LINK_BANK)
  ) u_rob (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation
      .i_alloc_req(i_alloc_req),
      .o_alloc_resp(o_alloc_resp),
      .i_alloc_req_2(i_alloc_req_2),
      .o_alloc_resp_2(o_alloc_resp_2),

      // CDB (from arbiter)
      .i_cdb_write(cdb_write_from_arbiter),
      .i_cdb_write_2(cdb_write_from_arbiter_2),
      .i_cdb_match_tag(cdb_rob_match_tag),
      .i_cdb_match_tag_2(cdb_rob_match_tag_2),
      .i_store_complete_valid(store_issue_fire),
      .i_store_complete_tag(store_complete_tag),

      // Branch
      .i_branch_update(i_branch_update),

      // Checkpoint recording
      .i_checkpoint_valid(i_rob_checkpoint_valid),
      .i_checkpoint_id   (i_rob_checkpoint_id),

      // Memory-order replay flags (DMA coherence port)
      .i_replay_set_mask(coh_replay_set_mask),

      // Commit output -> internal bus + registered observation
      .o_commit                             (),
      .o_commit_comb                        (commit_bus),
      .o_commit_valid_raw                   (commit_valid_raw),
      .o_commit_store_like_raw              (commit_store_like_raw),
      .o_commit_misprediction_raw           (o_commit_misprediction_raw),
      .o_commit_correct_branch_raw          (o_commit_correct_branch_raw),
      .o_commit_correct_branch_2_raw        (o_commit_correct_branch_2_raw),
      .o_head_commit_misprediction_candidate(o_head_commit_misprediction_candidate),

      // Slot 2 has matching registered and combinational commit outputs.
      .o_commit_2               (),
      .o_commit_comb_2          (commit_bus_2),
      .o_commit_2_valid_raw     (commit_2_valid_raw),
      .o_commit_2_store_like_raw(commit_2_store_like_raw),
      .i_widen_commit_ok        (i_widen_commit_ok),

      // External coordination
      .i_sq_committed_empty           (sq_committed_empty_rob),
      .i_fence_i_sync_done            (i_fence_i_sync_done),
      .o_fence_i_sync_req             (o_fence_i_sync_req),
      .o_sfence_window                (rob_sfence_window),
      .o_csr_start                    (o_csr_start),
      .i_csr_done                     (i_csr_done),
      .o_trap_pending                 (o_trap_pending),
      .o_trap_pc                      (o_trap_pc),
      .o_head_is_wfi                  (o_head_is_wfi),
      .o_head_is_amo                  (o_head_is_amo),
      .o_head_bypass_int_we_early     (o_head_bypass_int_we_early),
      .o_head_bypass_fp_we_early      (o_head_bypass_fp_we_early),
      .o_head_next_bypass_int_we_early(o_head_next_bypass_int_we_early),
      .o_head_next_bypass_fp_we_early (o_head_next_bypass_fp_we_early),
      .o_head_dir_train_early         (o_head_dir_train_early),
      .o_head_branch_taken_early      (o_head_branch_taken_early),
      .o_head_next_dir_train_early    (o_head_next_dir_train_early),
      .o_head_next_branch_taken_early (o_head_next_branch_taken_early),
      .o_head_retired_next_pc         (o_head_retired_next_pc),
      .o_head_next_retired_next_pc    (o_head_next_retired_next_pc),
      .o_trap_cause                   (o_trap_cause),
      .o_trap_value                   (o_trap_value),
      .i_trap_taken                   (i_trap_taken),
      .o_mret_start                   (o_mret_start),
      .o_mret_start_is_sret           (o_mret_start_is_sret),
      .o_mret_start_is_dret           (o_mret_start_is_dret),
      .i_mret_done                    (i_mret_done),
      .i_mepc                         (i_mepc),
      .i_sepc                         (i_sepc),
      .i_dpc                          (i_dpc),
      .i_interrupt_pending            (i_interrupt_pending),
      .i_priv                         (i_priv),
      .i_counter_blocked              (i_counter_blocked),
      .i_stimecmp_blocked             (i_stimecmp_blocked),
      .i_sret_illegal                 (i_sret_illegal),
      .i_sfence_illegal               (i_sfence_illegal),
      .i_wfi_illegal                  (i_wfi_illegal),
      .i_priv_is_u                    (i_priv_is_u),
      .i_debug_mode                   (i_debug_mode),
      .i_mcounteren                   (i_mcounteren),
      .i_mstatus_fs_off               (i_mstatus_fs_off),
      .i_frm                          (i_frm_csr),
      .i_commit_hold                  (i_commit_hold),

      // Flush
      .i_flush_en(i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(full_flush_all),
      .i_flush_after_head_commit(i_flush_after_head_commit),

      // Early misprediction recovery
      .i_early_recovery_en (i_early_recovery_en),
      .i_early_recovery_tag(i_early_recovery_tag),

      // Status
      .o_fence_i_flush                (o_fence_i_flush),
      .o_fence_class_flush_event      (o_fence_class_flush_event),
      .o_translation_csr_commit_shadow(o_translation_csr_commit_shadow),
      .o_full                         (o_rob_full),
      .o_full_for_2                   (o_rob_full_for_2),
      .o_empty                        (o_rob_empty),
      .o_count                        (o_rob_count),
      .o_head_tag                     (o_head_tag),
      .o_head_valid                   (o_head_valid),
      .o_head_done                    (o_head_done),
      .o_entry_valid                  (rob_entry_valid),
      .o_entry_done                   (rob_entry_done),
      .o_perf_events                  (rob_perf_events),

      // Dispatch bypass value read
      .i_bypass_tag_1  (i_bypass_tag_1),
      .o_bypass_value_1(bypass_value_1),
      .i_bypass_tag_2  (i_bypass_tag_2),
      .o_bypass_value_2(bypass_value_2),
      .i_bypass_tag_3  (i_bypass_tag_3),
      .o_bypass_value_3(bypass_value_3),
      .i_bypass_tag_4  (i_bypass_tag_4),
      .o_bypass_value_4(bypass_value_4),
      .i_bypass_tag_5  (i_bypass_tag_5),
      .o_bypass_value_5(bypass_value_5),
      .i_bypass_tag_6  (i_bypass_tag_6),
      .o_bypass_value_6(bypass_value_6)
  );

  assign o_bypass_value_1 = bypass_value_1;
  assign o_bypass_value_2 = bypass_value_2;
  assign o_bypass_value_3 = bypass_value_3;
  assign o_bypass_value_4 = bypass_value_4;
  assign o_bypass_value_5 = bypass_value_5;
  assign o_bypass_value_6 = bypass_value_6;

  // ===========================================================================
  // Register Alias Table Instance
  // ===========================================================================
  register_alias_table u_rat (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Source lookups - slot 1
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

      // Source lookups - slot 2 (2-wide dispatch)
      .i_int_src1_addr_2(i_int_src1_addr_2),
      .i_int_src2_addr_2(i_int_src2_addr_2),
      .o_int_src1_2     (o_int_src1_2),
      .o_int_src2_2     (o_int_src2_2),
      .i_fp_src1_addr_2 (i_fp_src1_addr_2),
      .i_fp_src2_addr_2 (i_fp_src2_addr_2),
      .i_fp_src3_addr_2 (i_fp_src3_addr_2),
      .o_fp_src1_2      (o_fp_src1_2),
      .o_fp_src2_2      (o_fp_src2_2),
      .o_fp_src3_2      (o_fp_src3_2),

      // Regfile data - slot 1
      .i_int_regfile_data1(i_int_regfile_data1),
      .i_int_regfile_data2(i_int_regfile_data2),
      .i_fp_regfile_data1 (i_fp_regfile_data1),
      .i_fp_regfile_data2 (i_fp_regfile_data2),
      .i_fp_regfile_data3 (i_fp_regfile_data3),

      // Regfile data - slot 2 (2-wide dispatch)
      .i_int_regfile_data1_2(i_int_regfile_data1_2),
      .i_int_regfile_data2_2(i_int_regfile_data2_2),
      .i_fp_regfile_data1_2 (i_fp_regfile_data1_2),
      .i_fp_regfile_data2_2 (i_fp_regfile_data2_2),
      .i_fp_regfile_data3_2 (i_fp_regfile_data3_2),

      // Rename - slot 1
      .i_alloc_valid   (i_rat_alloc_valid),
      .i_alloc_dest_rf (i_rat_alloc_dest_rf),
      .i_alloc_dest_reg(i_rat_alloc_dest_reg),
      .i_alloc_rob_tag (i_rat_alloc_rob_tag),

      // Rename - slot 2 (2-wide dispatch)
      .i_alloc_valid_2   (i_rat_alloc_valid_2),
      .i_alloc_dest_rf_2 (i_rat_alloc_dest_rf_2),
      .i_alloc_dest_reg_2(i_rat_alloc_dest_reg_2),
      .i_alloc_rob_tag_2 (i_rat_alloc_rob_tag_2),

      // Registered RAT commit clear, delayed one cycle for timing.
      .i_commit_valid     (commit_bus_q_valid),
      .i_commit_dest_valid(commit_q_dest_valid),
      .i_commit_dest_rf   (commit_q_dest_rf),
      .i_commit_dest_reg  (commit_q_dest_reg),
      .i_commit_tag       (commit_q_tag),

      // Widen-commit slot 2 retire, same pipelined pattern.
      .i_commit_valid_2     (commit_bus_2_q_valid),
      .i_commit_dest_valid_2(commit_q_2_dest_valid),
      .i_commit_dest_rf_2   (commit_q_2_dest_rf),
      .i_commit_dest_reg_2  (commit_q_2_dest_reg),
      .i_commit_tag_2       (commit_q_2_tag),

      // Checkpoint save
      .i_checkpoint_save           (i_checkpoint_save),
      .i_checkpoint_id             (i_checkpoint_id),
      .i_checkpoint_branch_tag     (i_checkpoint_branch_tag),
      .i_ras_tos                   (i_ras_tos),
      .i_ras_valid_count           (i_ras_valid_count),
      .i_ras_top                   (i_ras_top),
      .i_checkpoint_save_for_slot2 (i_checkpoint_save_for_slot2),
      .i_alloc_fire                (i_alloc_fire),
      .i_alloc_has_dest            (i_alloc_has_dest),
      .i_alloc_has_dest_2          (i_alloc_has_dest_2),
      .i_checkpoint_slot2_candidate(i_checkpoint_slot2_candidate),

      // Checkpoint restore
      .i_checkpoint_restore            (i_checkpoint_restore),
      .i_checkpoint_restore_id         (i_checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(i_checkpoint_restore_reclaim_all),
      .i_checkpoint_flush_free_mask    (i_checkpoint_flush_free_mask),
      .o_ras_tos                       (o_ras_tos),
      .o_ras_valid_count               (o_ras_valid_count),
      .o_ras_top                       (o_ras_top),

      // Checkpoint free
      .i_checkpoint_free   (i_checkpoint_free),
      .i_checkpoint_free_id(i_checkpoint_free_id),
      .i_checkpoint_free_2   (i_checkpoint_free_2),
      .i_checkpoint_free_id_2(i_checkpoint_free_id_2),

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
  // INT_RS (INT_RS_DEPTH entries, default 16): Integer ALU ops, branches, CSR
  // ---------------------------------------------------------------------------
  // INT_RS dispatch with routed valid
  riscv_pkg::rs_dispatch_t                                        int_rs_dispatch;
  riscv_pkg::rs_dispatch_t                                        int_rs_dispatch_2;
  logic                                                           int_rs_issue_writes_cdb_hint;
  // CDB valid/tag copies for INT_RS issue compares, for fanout. They sample
  // the same edge as the INT-local packets; values are not duplicated.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                                                           int_rs_issue_cdb_valid;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] int_rs_issue_cdb_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                                                           int_rs_issue_cdb_2_valid;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] int_rs_issue_cdb_2_tag;
  // INT_RS head-tag scan splits head_wait_int into operand wait, ready but
  // not issued, stage2, and post-RS cycles.
  logic                                                           int_rs_head_in_rs;
  logic                                                           int_rs_head_rs_ready;
  logic                                                           int_rs_head_in_stage2;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      int_rs_issue_cdb_valid   <= 1'b0;
      int_rs_issue_cdb_2_valid <= 1'b0;
    end else begin
      int_rs_issue_cdb_valid   <= cdb_bus_comb.valid;
      int_rs_issue_cdb_2_valid <= cdb_bus_2_comb.valid;
    end
  end
  always_ff @(posedge i_clk) begin
    int_rs_issue_cdb_tag   <= cdb_bus_comb.tag;
    int_rs_issue_cdb_2_tag <= cdb_bus_2_comb.tag;
  end

`ifndef SYNTHESIS
  always_comb begin
    if (i_rst_n) begin
      p_int_rs_issue_cdb_lane0_anchor_phase_identity :
      assert (
        int_rs_issue_cdb_valid == cdb_bus_int_rs_valid &&
        int_rs_issue_cdb_tag == cdb_bus_int_rs_tag
      );
      p_int_rs_issue_cdb_lane1_anchor_phase_identity :
      assert (
        int_rs_issue_cdb_2_valid == cdb_bus_2_int_rs_valid &&
        int_rs_issue_cdb_2_tag == cdb_bus_2_int_rs_tag
      );
    end
  end
`endif

  always_comb begin
    int_rs_dispatch         = SPLIT_RS_DISPATCH ? i_int_rs_dispatch : i_rs_dispatch;
    int_rs_dispatch.valid   = int_rs_dispatch_valid;

    // Slot-2 only carries a meaningful packet in SPLIT mode; the single-slot
    // i_rs_dispatch port hard-zeros slot-2 otherwise.
    int_rs_dispatch_2       = SPLIT_RS_DISPATCH ? i_int_rs_dispatch_2 : '0;
    int_rs_dispatch_2.valid = int_rs_dispatch_valid_2;
  end

  reservation_station #(
      .DEPTH(INT_RS_DEPTH),
      .HAS_SRC3(1'b0),
      .DISPATCH_REPAIR_BYPASS(1'b0),
      // Disable issue-time repair for timing. A source completed through repair
      // waits one extra cycle for registered rs_src_ready before issue.
      .ISSUE_REPAIR_BYPASS(1'b0),
      // The ROB repair response follows allocation by one cycle. Save the local
      // entry index and update its source directly.
      .ALLOC_INDEXED_REPAIR(1'b1),
      .TRACK_INT_WRITEBACK_HINT(1'b1),
      // Speculative data writes use i_intent_1 for timing; rs_valid gates visibility.
      .SPECULATIVE_DATA_WRITES(1'b1),
      // Prefill free entries for timing, selecting slot-2 payload only at
      // alloc_idx_2. rs_valid alone makes an entry visible.
      .BROADCAST_FREE_SOURCE_VALUES(1'b1),
      // Separate issue-time CDB tag matches from resident-value writes for timing.
      // Shadow tags may differ in unused entries but must match in every valid entry.
      .ISSUE2_WINDOW(riscv_pkg::IntRsIssue2Window),
      .ISSUE_CDB_TAG_SHADOW(1'b1),
      .ISSUE_CDB_META_ANCHORS(1'b1),
      .CAPTURE_PRIMARY_EFFECTIVE_OPERANDS(1'b1),
      .BRANCH_PREDICATE_TAG_ANCHOR(1'b1),
      // Dispatch checks full for slot 1 and full_for_2 when both slots target
      // INT_RS. Trust those checks when accepting per-RS valid bits.
      .TRUST_DISPATCH_VALID(1'b1),
      .DUAL_ISSUE(1'b1),
      // Keep the branch PC, link address, and predicted target in a ROB-tag-indexed
      // side RAM, read with port 0's stage2 tag, to reduce resident payload width.
      .TAG_INDEXED_BRANCH_PAYLOAD(1'b1),
      // tomasulo_wrapper.sby reads reservation_station.sv with -formal. Disable
      // its standalone environment assumptions: this wrapper includes the ROB
      // and routing logic. Dispatch is outside this boundary; the "RS dispatch
      // tag coordination" assumptions below model its tag handling.
      .FORMAL_STANDALONE_ENV(1'b0)
  ) u_int_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch
      .i_dispatch  (int_rs_dispatch),
      .i_dispatch_2(int_rs_dispatch_2),
      .i_intent_1  (int_rs_intent_1),
      .o_full      (int_rs_full_w),
      .o_full_for_2(int_rs_full_for_2_w),

      // CDB snoop (from arbiter)
      .i_cdb(cdb_bus_int_rs_qualified),
      .i_cdb_2(cdb_bus_2_int_rs_qualified),
      .i_issue_cdb_valid(int_rs_issue_cdb_valid),
      .i_issue_cdb_tag(int_rs_issue_cdb_tag),
      .i_issue_cdb_2_valid(int_rs_issue_cdb_2_valid),
      .i_issue_cdb_2_tag(int_rs_issue_cdb_2_tag),
      .i_repair_valid_1(int_done_repair_valid_1),
      .i_repair_tag_1(i_bypass_tag_1),
      .i_repair_value_1(bypass_value_1),
      .i_repair_valid_2(int_done_repair_valid_2),
      .i_repair_tag_2(i_bypass_tag_2),
      .i_repair_value_2(bypass_value_2),
      .i_repair_valid_3(int_done_repair_valid_3),
      .i_repair_tag_3(i_bypass_tag_3),
      .i_repair_value_3(bypass_value_3),
      .i_repair_valid_4(int_done_repair_valid_4),
      .i_repair_tag_4(i_bypass_tag_4),
      .i_repair_value_4(bypass_value_4),
      .i_repair_valid_5(int_done_repair_valid_5),
      .i_repair_tag_5(i_bypass_tag_5),
      .i_repair_value_5(bypass_value_5),
      .i_repair_valid_6(int_done_repair_valid_6),
      .i_repair_tag_6(i_bypass_tag_6),
      .i_repair_value_6(bypass_value_6),

      // Issue (to internal wire for ALU shim)
      .o_issue(int_rs_issue_raw),
      .i_fu_ready(int_rs_fu_ready),
      .i_divider_busy(1'b0),
      .o_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint),
      .o_branch_predicate_tag(int_rs_branch_predicate_tag),
      .o_issue_2(int_rs_issue_2_raw),
      .i_fu_ready_2(int_rs_fu_ready_2),
      .o_issue_writes_cdb_hint_2(int_rs_issue_writes_cdb_hint_2),
      .o_issue_shift_amount_2(int_rs_issue_shift_amount_2),
      .o_next_issue_valid(),
      .o_next_issue_is_sc(),  // unused: no SC ops in INT_RS
      .o_next_issue_needs_lq(),
      .o_pre_issue_rob_tag(),
      .o_pre_issue_rob_tags(),
      .o_pre_issue_sel(),
      .o_pre_issue_ready(),
      .o_pre_issue_entry_tags(),
      .i_pre_issue_raw_valid('0),
      .i_pre_issue_raw_tags('0),
      .o_pre_issue_needs_lq(),

      // Flush (shared with ROB)
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (speculative_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count),

      // Head-wait diagnostic (only the INT_RS drives real counters)
      .i_head_query_tag           (head_tag),
      .o_head_query_in_rs         (int_rs_head_in_rs),
      .o_head_query_rs_ready      (int_rs_head_rs_ready),
      .o_head_query_in_stage2     (int_rs_head_in_stage2),
      .o_perf_two_ready_one_issued()
  );

  // INT_RS port-0 issue, for branch resolution in cpu_ooo and for test benches
  assign o_rs_issue                      = int_rs_issue_w;
  assign o_rs_issue_branch_predicate_tag = int_rs_branch_predicate_tag;

  // ---------------------------------------------------------------------------
  // MUL_RS (depth 4): Integer multiply/divide
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mul_rs_dispatch;
  riscv_pkg::rs_dispatch_t mul_rs_dispatch_2;
  always_comb begin
    mul_rs_dispatch         = SPLIT_RS_DISPATCH ? i_mul_rs_dispatch : i_rs_dispatch;
    mul_rs_dispatch.valid   = mul_rs_dispatch_valid;

    mul_rs_dispatch_2       = SPLIT_RS_DISPATCH ? i_mul_rs_dispatch_2 : '0;
    mul_rs_dispatch_2.valid = mul_rs_dispatch_valid_2;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MulRsDepth),
      .HAS_SRC3(1'b0),
      // Repair already-done operands through the indexed response one cycle
      // after allocation, for timing.
      .DISPATCH_REPAIR_BYPASS(1'b0),
      // Register repair before issue, as in INT_RS and MEM_RS.
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      // Use the integrated formal environment, as in u_int_rs.
      .FORMAL_STANDALONE_ENV(1'b0),
      .SPECULATIVE_DATA_WRITES(1'b1),
      // The divider takes one divide at a time: divides wait in the station
      // while it is busy, and multiplies issue past them.
      .DIVIDE_ISSUE_GATE(1'b1)
  ) u_mul_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(mul_rs_dispatch),
      .i_dispatch_2(mul_rs_dispatch_2),
      .i_intent_1(mul_rs_intent_1),
      .o_full(mul_rs_full_w),
      .o_full_for_2(mul_rs_full_for_2_w),
      .i_cdb(cdb_bus_mul_qualified),
      .i_cdb_2(cdb_bus_2_mul_qualified),
      .i_issue_cdb_valid(cdb_bus_mul_qualified.valid),
      .i_issue_cdb_tag(cdb_bus_mul_qualified.tag),
      .i_issue_cdb_2_valid(cdb_bus_2_mul_qualified.valid),
      .i_issue_cdb_2_tag(cdb_bus_2_mul_qualified.tag),
      .i_repair_valid_1(done_repair_valid_1),
      .i_repair_tag_1(i_bypass_tag_1),
      .i_repair_value_1(bypass_value_1),
      .i_repair_valid_2(done_repair_valid_2),
      .i_repair_tag_2(i_bypass_tag_2),
      .i_repair_value_2(bypass_value_2),
      .i_repair_valid_3(done_repair_valid_3),
      .i_repair_tag_3(i_bypass_tag_3),
      .i_repair_value_3(bypass_value_3),
      .i_repair_valid_4(done_repair_valid_4),
      .i_repair_tag_4(i_bypass_tag_4),
      .i_repair_value_4(bypass_value_4),
      .i_repair_valid_5(done_repair_valid_5),
      .i_repair_tag_5(i_bypass_tag_5),
      .i_repair_value_5(bypass_value_5),
      .i_repair_valid_6(done_repair_valid_6),
      .i_repair_tag_6(i_bypass_tag_6),
      .i_repair_value_6(bypass_value_6),
      .o_issue(mul_rs_issue_raw),
      .i_fu_ready(mul_rs_fu_ready),
      .i_divider_busy(div_busy),
      .o_issue_writes_cdb_hint(),
      .o_branch_predicate_tag(),
      .o_issue_2(),
      .i_fu_ready_2(1'b0),
      .o_issue_writes_cdb_hint_2(),
      .o_issue_shift_amount_2(),
      .o_next_issue_valid(),
      .o_next_issue_is_sc(),  // unused: no SC ops in MUL_RS
      .o_next_issue_needs_lq(),
      .o_pre_issue_rob_tag(),
      .o_pre_issue_rob_tags(),
      .o_pre_issue_sel(),
      .o_pre_issue_ready(),
      .o_pre_issue_entry_tags(),
      .i_pre_issue_raw_valid('0),
      .i_pre_issue_raw_tags('0),
      .o_pre_issue_needs_lq(),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all(speculative_flush_all),
      .o_empty(o_mul_rs_empty),
      .o_count(o_mul_rs_count),
      .i_head_query_tag(head_tag),
      .o_head_query_in_rs(),
      .o_head_query_rs_ready(),
      .o_head_query_in_stage2(),
      .o_perf_two_ready_one_issued()
  );

  // Observation port: expose MUL_RS issue for testbench
  assign o_mul_rs_issue = mul_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MEM_RS (depth 8): Loads/stores (both INT and FP)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch_2;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_rob_tag;
  logic mem_rs_pre_issue_needs_lq;
  logic [8*riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_rob_tags;
  logic [8*riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_rob_tags_final;
  logic [2:0] mem_rs_pre_issue_sel;
  logic [8*riscv_pkg::MemRsDepth-1:0] mem_rs_pre_issue_ready;
  logic [riscv_pkg::MemRsDepth*riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_entry_tags;

  riscv_pkg::cdb_broadcast_t mem_rs_wakeup_0, mem_rs_wakeup_1;
  riscv_pkg::cdb_broadcast_t mem_rs_cdb_0, mem_rs_cdb_1;
  logic mem_rs_early_load_injected;
  logic mem_rs_early_wakeup_enable;
  logic [2:0] mem_rs_pre_issue_raw_valid;
  assign mem_rs_early_wakeup_enable = EARLY_LOAD_WAKEUP && !sc_valid_wakeup_q &&
      !store_misalign_fu_complete_reg.valid && !mem_adapter_result_pending;
  assign mem_rs_pre_issue_raw_valid = {
    mem_rs_early_wakeup_enable && lq_fu_complete_staged && !lq_fu_complete.exception,
    cdb_bus_2_mem_qualified.valid,
    cdb_bus_mem_qualified.valid
  };
  // With EARLY_LOAD_WAKEUP off, MEM_RS takes the registered lanes directly,
  // bit for bit (invalid payloads included), with no merge logic between.
  assign mem_rs_cdb_0 = EARLY_LOAD_WAKEUP ? mem_rs_wakeup_0 : cdb_bus_mem_qualified;
  assign mem_rs_cdb_1 = EARLY_LOAD_WAKEUP ? mem_rs_wakeup_1 : cdb_bus_2_mem_qualified;
  // The early token uses registered state and omits recovery gating for timing.
  // MEM_RS blocks new issue selection and dispatch during recovery. A retained
  // wakeup belongs to a surviving consumer, whose producer load is older and
  // also survives. That load's staged value is final, even if broadcast is
  // delayed: cdb_stage clears only on acceptance or recovery. Consumers of
  // killed loads are younger and die too. Unique live ROB tags prevent a
  // surviving consumer from matching a killed load.
  riscv_pkg::fu_complete_t lq_early_wakeup_load;
  always_comb begin
    lq_early_wakeup_load       = lq_fu_complete;
    lq_early_wakeup_load.valid = lq_fu_complete_staged;
  end
  mem_wakeup_merge #(
      .FORMAL_STANDALONE_ENV(1'b0)
  ) u_mem_wakeup_merge (
      // No reset gate is needed: MEM_RS entries, stage2, pending flags, and LQ
      // pre-issue state clear on reset, so a reset-cycle token has no lasting effect.
      .i_enable(mem_rs_early_wakeup_enable),
      .i_load(lq_early_wakeup_load),
      .i_registered_0(cdb_bus_mem_qualified),
      .i_registered_1(cdb_bus_2_mem_qualified),
      .o_wakeup_0(mem_rs_wakeup_0),
      .o_wakeup_1(mem_rs_wakeup_1),
      .o_injected(mem_rs_early_load_injected)
  );

`ifndef SYNTHESIS
  // Outside recovery, the early token observes a real CDB broadcast; it is
  // neither a prediction nor a second completion. During recovery it may
  // precede that broadcast, while MEM_RS blocks new issue selection.
  always @(posedge i_clk) begin
    if (i_rst_n && mem_rs_early_load_injected) begin
      p_early_load_accepted_or_recovering :
      assert (lq_result_accepted || speculative_flush_all || speculative_flush_en ||
              lq_partial_flush_en);
    end
    if (i_rst_n && mem_rs_early_load_injected && !speculative_flush_all &&
        !speculative_flush_en && !lq_partial_flush_en) begin
      p_early_load_really_broadcasts :
      assert (
          (cdb_bus_comb.valid && cdb_bus_comb.tag == lq_fu_complete.tag &&
           cdb_bus_comb.value == lq_fu_complete.value) ||
          (cdb_bus_2_comb.valid && cdb_bus_2_comb.tag == lq_fu_complete.tag &&
           cdb_bus_2_comb.value == lq_fu_complete.value));
    end
  end
`endif

  always_comb begin
    mem_rs_dispatch         = SPLIT_RS_DISPATCH ? i_mem_rs_dispatch : i_rs_dispatch;
    mem_rs_dispatch.valid   = mem_rs_dispatch_valid;

    mem_rs_dispatch_2       = SPLIT_RS_DISPATCH ? i_mem_rs_dispatch_2 : '0;
    mem_rs_dispatch_2.valid = mem_rs_dispatch_valid_2;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MemRsDepth),
      .PREISSUE_VALID_COFACTOR(EARLY_LOAD_WAKEUP),
      .PREISSUE_RAW_WAKEUP(1'b1),
      .PREISSUE_READY_EXPORT(EARLY_LOAD_WAKEUP),
      .HAS_SRC3(1'b0),
      .DISPATCH_REPAIR_BYPASS(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      .SPECULATIVE_DATA_WRITES(1'b1),
      // Dispatch checks MEM_RS full and full_for_2 before asserting valid.
      // Use the integrated formal environment, as in u_int_rs.
      .FORMAL_STANDALONE_ENV(1'b0),
      .TRUST_DISPATCH_VALID(1'b1)
  ) u_mem_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(mem_rs_dispatch),
      .i_dispatch_2(mem_rs_dispatch_2),
      .i_intent_1(mem_rs_intent_1),
      .o_full(mem_rs_full_w),
      .o_full_for_2(mem_rs_full_for_2_w),
      .i_cdb(mem_rs_cdb_0),
      .i_cdb_2(mem_rs_cdb_1),
      .i_issue_cdb_valid(mem_rs_cdb_0.valid),
      .i_issue_cdb_tag(mem_rs_cdb_0.tag),
      .i_issue_cdb_2_valid(mem_rs_cdb_1.valid),
      .i_issue_cdb_2_tag(mem_rs_cdb_1.tag),
      .i_repair_valid_1(done_repair_valid_1),
      .i_repair_tag_1(i_bypass_tag_1),
      .i_repair_value_1(bypass_value_1),
      .i_repair_valid_2(done_repair_valid_2),
      .i_repair_tag_2(i_bypass_tag_2),
      .i_repair_value_2(bypass_value_2),
      .i_repair_valid_3(done_repair_valid_3),
      .i_repair_tag_3(i_bypass_tag_3),
      .i_repair_value_3(bypass_value_3),
      .i_repair_valid_4(done_repair_valid_4),
      .i_repair_tag_4(i_bypass_tag_4),
      .i_repair_value_4(bypass_value_4),
      .i_repair_valid_5(done_repair_valid_5),
      .i_repair_tag_5(i_bypass_tag_5),
      .i_repair_value_5(bypass_value_5),
      .i_repair_valid_6(done_repair_valid_6),
      .i_repair_tag_6(i_bypass_tag_6),
      .i_repair_value_6(bypass_value_6),
      .o_issue(mem_rs_issue_raw),
      .i_fu_ready(mem_rs_fu_ready),
      .i_divider_busy(1'b0),
      .o_issue_writes_cdb_hint(),
      .o_branch_predicate_tag(),
      .o_issue_2(),
      .i_fu_ready_2(1'b0),
      .o_issue_writes_cdb_hint_2(),
      .o_issue_shift_amount_2(),
      .o_next_issue_valid(mem_rs_next_issue_valid),
      .o_next_issue_is_sc(mem_rs_next_is_sc),
      .o_next_issue_needs_lq(mem_rs_next_issue_needs_lq),
      .o_pre_issue_rob_tag(mem_rs_pre_issue_rob_tag),
      .o_pre_issue_rob_tags(mem_rs_pre_issue_rob_tags),
      .o_pre_issue_sel(mem_rs_pre_issue_sel),
      .o_pre_issue_ready(mem_rs_pre_issue_ready),
      .o_pre_issue_entry_tags(mem_rs_pre_issue_entry_tags),
      .i_pre_issue_raw_valid(mem_rs_pre_issue_raw_valid),
      .i_pre_issue_raw_tags({
        lq_fu_complete.tag, cdb_bus_2_mem_qualified.tag, cdb_bus_mem_qualified.tag
      }),
      .o_pre_issue_needs_lq(mem_rs_pre_issue_needs_lq),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all(speculative_flush_all),
      .o_empty(o_mem_rs_empty),
      .o_count(o_mem_rs_count),
      .i_head_query_tag(head_tag),
      .o_head_query_in_rs(),
      .o_head_query_rs_ready(),
      .o_head_query_in_stage2(),
      // Width-funnel perf observer: >=2 MEM_RS entries ready, single issue
      // port fired (registered inside the RS).
      .o_perf_two_ready_one_issued(o_perf_mem_rs_two_ready_one_issued)
  );

  assign o_mem_rs_issue = mem_rs_issue_w;

  // ---------------------------------------------------------------------------
  // Resolve FRM_DYN before FP_RS. Production dispatch substitutes frm first,
  // so DYN arrives here only when frm is 7. Reserved frm values (5 to 7) used
  // through DYN fault at ROB allocation, so their results and flags cannot
  // retire. Clamp DYN to RNE for the station; values 5 and 6 pass unchanged.
  // ---------------------------------------------------------------------------
  wire [2:0] frm_safe = (i_frm_csr > riscv_pkg::FRM_RMM) ? riscv_pkg::FRM_RNE : i_frm_csr;
  function automatic logic [2:0] resolve_dispatch_rm(input logic [2:0] rm);
    begin
      resolve_dispatch_rm = (rm == riscv_pkg::FRM_DYN) ? frm_safe : rm;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // FP_RS (riscv_pkg::FpRsDepth entries): every FP compute operation
  // (3 sources)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  always_comb begin
    fp_rs_dispatch             = SPLIT_RS_DISPATCH ? i_fp_rs_dispatch : i_rs_dispatch;
    fp_rs_dispatch.valid       = fp_rs_dispatch_valid;
    fp_rs_dispatch.rm          = resolve_dispatch_rm(fp_rs_dispatch.rm);

    fp_rs_dispatch_to_rs       = fp_dispatch_pending;
    fp_rs_dispatch_to_rs.valid = fp_dispatch_dequeue;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fp_dispatch_pending_valid <= 1'b0;
    end else if (fp_dispatch_pending_flushed) begin
      fp_dispatch_pending_valid <= 1'b0;
    end else if (fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                 !speculative_flush_all && !speculative_flush_en) begin
      fp_dispatch_pending_valid <= 1'b1;
    end else if (fp_dispatch_dequeue) begin
      fp_dispatch_pending_valid <= 1'b0;
    end
  end

  // Capture the FP dispatch payload without reset; pending-valid gates its use.
  // Before RS insertion, update it from E1 done repair and the CDB. Lane 0 wins
  // over lane 1, and both beat repair, matching resident-RS wakeup priority.
  // Source k uses repair channel k.
  always_ff @(posedge i_clk) begin
    if (fp_rs_dispatch.valid && fp_dispatch_slot_available &&
        !speculative_flush_all && !speculative_flush_en) begin
      fp_dispatch_pending <= fp_rs_dispatch;
    end else if (fp_dispatch_pending_valid &&
                 (cdb_bus_fp_qualified.valid || cdb_bus_2_fp_qualified.valid ||
                  (fp_pending_repair_capture_q &&
                   (done_repair_valid_1 || done_repair_valid_2 || done_repair_valid_3)))) begin
      if (!fp_dispatch_pending.src1_ready && cdb_bus_fp_qualified.valid &&
          fp_dispatch_pending.src1_tag == cdb_bus_fp_qualified.tag) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= cdb_bus_fp_qualified.value;
      end else if (!fp_dispatch_pending.src1_ready && cdb_bus_2_fp_qualified.valid &&
          fp_dispatch_pending.src1_tag == cdb_bus_2_fp_qualified.tag) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= cdb_bus_2_fp_qualified.value;
      end else if (!fp_dispatch_pending.src1_ready && fp_pending_repair_capture_q &&
                   done_repair_valid_1 &&
                   fp_dispatch_pending.src1_tag == i_bypass_tag_1) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= bypass_value_1;
      end

      if (!fp_dispatch_pending.src2_ready && cdb_bus_fp_qualified.valid &&
          fp_dispatch_pending.src2_tag == cdb_bus_fp_qualified.tag) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= cdb_bus_fp_qualified.value;
      end else if (!fp_dispatch_pending.src2_ready && cdb_bus_2_fp_qualified.valid &&
          fp_dispatch_pending.src2_tag == cdb_bus_2_fp_qualified.tag) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= cdb_bus_2_fp_qualified.value;
      end else if (!fp_dispatch_pending.src2_ready && fp_pending_repair_capture_q &&
                   done_repair_valid_2 &&
                   fp_dispatch_pending.src2_tag == i_bypass_tag_2) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= bypass_value_2;
      end

      if (!fp_dispatch_pending.src3_ready && cdb_bus_fp_qualified.valid &&
          fp_dispatch_pending.src3_tag == cdb_bus_fp_qualified.tag) begin
        fp_dispatch_pending.src3_ready <= 1'b1;
        fp_dispatch_pending.src3_value <= cdb_bus_fp_qualified.value;
      end else if (!fp_dispatch_pending.src3_ready && cdb_bus_2_fp_qualified.valid &&
          fp_dispatch_pending.src3_tag == cdb_bus_2_fp_qualified.tag) begin
        fp_dispatch_pending.src3_ready <= 1'b1;
        fp_dispatch_pending.src3_value <= cdb_bus_2_fp_qualified.value;
      end else if (!fp_dispatch_pending.src3_ready && fp_pending_repair_capture_q &&
                   done_repair_valid_3 &&
                   fp_dispatch_pending.src3_tag == i_bypass_tag_3) begin
        fp_dispatch_pending.src3_ready <= 1'b1;
        fp_dispatch_pending.src3_value <= bypass_value_3;
      end
    end
  end

  // Dispatch registers source queries on channels 1/2/3 for E1, the cycle
  // after packet capture. An unresolved queried packet waits through E1;
  // queries from later cycles must not update it.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fp_pending_repair_capture_q <= 1'b0;
      fp_pending_repair_wait_q    <= 1'b0;
    end else begin
      fp_pending_repair_capture_q <=
          ENABLE_DISPATCH_DONE_REPAIR && fp_rs_dispatch.valid && fp_dispatch_slot_available &&
          !speculative_flush_all && !speculative_flush_en;
      // These source-ready bits also drive dispatch's registered bypass-valid.
      // Capture whether this packet must wait for its E1 response.
      fp_pending_repair_wait_q <=
          ENABLE_DISPATCH_DONE_REPAIR && fp_rs_dispatch.valid && fp_dispatch_slot_available &&
          !speculative_flush_all && !speculative_flush_en &&
          (!fp_rs_dispatch.src1_ready || !fp_rs_dispatch.src2_ready ||
           !fp_rs_dispatch.src3_ready);
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      if (fp_pending_repair_capture_q) begin
        p_fp_pending_repair_packet_phase : assert (fp_dispatch_pending_valid);
        if (!$isunknown(
                {
                  fp_pending_repair_wait_q,
                  fp_dispatch_pending.src1_ready,
                  fp_dispatch_pending.src2_ready,
                  fp_dispatch_pending.src3_ready
                }
            )) begin
          p_fp_pending_repair_wait_matches_packet :
          assert (fp_pending_repair_wait_q ==
                  (!fp_dispatch_pending.src1_ready ||
                   !fp_dispatch_pending.src2_ready ||
                   !fp_dispatch_pending.src3_ready));
        end
        p_fp_pending_repair_channel1_phase :
        assert (!i_bypass_valid_1 || i_bypass_tag_1 == fp_dispatch_pending.src1_tag);
        p_fp_pending_repair_channel2_phase :
        assert (!i_bypass_valid_2 || i_bypass_tag_2 == fp_dispatch_pending.src2_tag);
        p_fp_pending_repair_channel3_phase :
        assert (!i_bypass_valid_3 || i_bypass_tag_3 == fp_dispatch_pending.src3_tag);
      end

      p_fp_pending_repair_wait_has_phase :
      assert (!fp_pending_repair_wait_q || fp_pending_repair_capture_q);
      p_fp_repair_window_blocks_dequeue : assert (!(fp_repair_window_block && fp_dispatch_dequeue));
      p_fp_repair_window_blocks_refill :
      assert (!(fp_repair_window_block && fp_dispatch_slot_available));
    end
  end
`endif
`endif

  // dispatch.sv serializes slot-2 FP compute, so fp_rs_dispatch_fire_2 is
  // always zero. Tie the unused packet to zero for timing.
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_to_rs_2;
  assign fp_rs_dispatch_to_rs_2 = '0;

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth),
      .HAS_SRC3(1'b1),
      // Capture ROB-done repair in the pending packet before insertion; resident
      // entries use CDB wakeup. Use the integrated formal environment, as in u_int_rs.
      .FORMAL_STANDALONE_ENV(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0)
  ) u_fp_rs (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_dispatch                 (fp_rs_dispatch_to_rs),
      .i_dispatch_2               (fp_rs_dispatch_to_rs_2),
      // FP dispatch is single-slot, so alloc_idx_2 never selects a real allocation.
      // i_intent_1 follows the other stations' wiring.
      .i_intent_1                 (fp_rs_intent_1),
      .o_full                     (fp_rs_full_raw),
      .o_full_for_2               (fp_rs_full_for_2_raw),
      .i_cdb                      (cdb_bus_fp_qualified),
      .i_cdb_2                    (cdb_bus_2_fp_qualified),
      .i_issue_cdb_valid          (cdb_bus_fp_qualified.valid),
      .i_issue_cdb_tag            (cdb_bus_fp_qualified.tag),
      .i_issue_cdb_2_valid        (cdb_bus_2_fp_qualified.valid),
      .i_issue_cdb_2_tag          (cdb_bus_2_fp_qualified.tag),
      // Repair is complete before dequeue; resident entries need only CDB snooping.
      .i_repair_valid_1           (1'b0),
      .i_repair_tag_1             ('0),
      .i_repair_value_1           ('0),
      .i_repair_valid_2           (1'b0),
      .i_repair_tag_2             ('0),
      .i_repair_value_2           ('0),
      .i_repair_valid_3           (1'b0),
      .i_repair_tag_3             ('0),
      .i_repair_value_3           ('0),
      .i_repair_valid_4           (1'b0),
      .i_repair_tag_4             ('0),
      .i_repair_value_4           ('0),
      .i_repair_valid_5           (1'b0),
      .i_repair_tag_5             ('0),
      .i_repair_value_5           ('0),
      .i_repair_valid_6           (1'b0),
      .i_repair_tag_6             ('0),
      .i_repair_value_6           ('0),
      .o_issue                    (fp_rs_issue_raw),
      .i_fu_ready                 (fp_rs_fu_ready),
      .i_divider_busy             (1'b0),
      .o_issue_writes_cdb_hint    (),
      .o_branch_predicate_tag     (),
      .o_issue_2                  (),
      .i_fu_ready_2               (1'b0),
      .o_issue_writes_cdb_hint_2  (),
      .o_issue_shift_amount_2     (),
      .o_next_issue_valid         (),
      .o_next_issue_is_sc         (),                              // unused: no SC ops in FP_RS
      .o_next_issue_needs_lq      (),
      .o_pre_issue_rob_tag        (),
      .o_pre_issue_rob_tags       (),
      .o_pre_issue_sel            (),
      .o_pre_issue_ready          (),
      .o_pre_issue_entry_tags     (),
      .i_pre_issue_raw_valid      ('0),
      .i_pre_issue_raw_tags       ('0),
      .o_pre_issue_needs_lq       (),
      .i_flush_en                 (speculative_flush_en),
      .i_flush_tag                (i_flush_tag),
      .i_rob_head_tag             (head_tag),
      .i_flush_all                (speculative_flush_all),
      .o_empty                    (fp_rs_empty_raw),
      .o_count                    (fp_rs_count_raw),
      .i_head_query_tag           (head_tag),
      .o_head_query_in_rs         (),
      .o_head_query_rs_ready      (),
      .o_head_query_in_stage2     (),
      .o_perf_two_ready_one_issued()
  );

  // Observation port: expose FP RS issue for testbench
  assign o_fp_rs_issue = fp_rs_issue_w;

  // ===========================================================================
  // ALU Shim: translate rs_issue_t -> ALU -> fu_complete_t
  // ===========================================================================
  int_alu_shim u_alu_shim (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_rs_issue             (int_rs_issue_w),
      .i_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint),
      .i_shift_amount_hint    (6'b0),
      .o_fu_complete          (alu_shim_out),
      .o_fu_busy              (alu_fu_busy)
  );

  // ===========================================================================
  // ALU CDB Adapter: result holding register between ALU and CDB arbiter
  // ===========================================================================
  fu_cdb_adapter #(
      // Pending deasserts int_rs_fu_ready, so shim-valid and pending are mutually
      // exclusive. The held-payload write enable can omit grant-refill checks.
      .ALLOW_GRANT_REFILL_PAYLOAD_WRITE(1'b0)
  ) u_alu_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (alu_shim_out),
      .o_fu_complete   (alu_adapter_to_arbiter),
      .o_held_value    (alu_adapter_held_value),
      .i_grant         (o_cdb_grant[0]),
      .o_result_pending(alu_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // ALU2 Shim + CDB Adapter: second integer pipe.
  // Branch-class entries are steered to port 0 inside the INT RS, so this
  // pipe never resolves a branch and needs no branch_resolution tap.
  // ===========================================================================
  int_alu_shim #(
      .USE_SHIFT_AMOUNT_HINT(1'b1)
  ) u_alu2_shim (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_rs_issue             (int_rs_issue_2_w),
      .i_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint_2),
      .i_shift_amount_hint    (int_rs_issue_shift_amount_2),
      .o_fu_complete          (alu2_shim_out),
      .o_fu_busy              (alu2_fu_busy)
  );

  fu_cdb_adapter #(
      // Pending deasserts int_rs_fu_ready_2, so shim-valid and pending are mutually
      // exclusive. The held-payload write enable can omit grant-refill checks.
      .ALLOW_GRANT_REFILL_PAYLOAD_WRITE(1'b0)
  ) u_alu2_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (alu2_shim_out),
      .o_fu_complete   (alu2_adapter_to_arbiter),
      .o_held_value    (alu2_adapter_held_value),
      .i_grant         (o_cdb_grant[riscv_pkg::FU_ALU2]),
      .o_result_pending(alu2_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

`ifndef SYNTHESIS
  // Pending gates each INT_RS ready input, which qualifies stage2 issue valid.
  // These checks protect the ALU adapters' simplified payload write enables.
  always_comb begin
    if (i_rst_n) begin
      p_alu_pending_blocks_payload_refill :
      assert (!(alu_adapter_result_pending && alu_shim_out.valid));
      p_alu2_pending_blocks_payload_refill :
      assert (!(alu2_adapter_result_pending && alu2_shim_out.valid));
    end
  end
`endif

  // ===========================================================================
  // MUL/DIV Shim: translate rs_issue_t -> multiplier/divider -> fu_complete_t
  // ===========================================================================
  int_muldiv_shim u_muldiv_shim (
      .i_clk            (i_clk),
      .i_rst_n          (i_rst_n),
      .i_rs_issue       (mul_rs_issue_w),
      .o_mul_fu_complete(mul_shim_out),
      .o_div_fu_complete(div_shim_out),
      .o_fu_busy        (muldiv_busy),
      .o_div_busy       (div_busy),
      .i_flush          (speculative_flush_all),
      .i_flush_en       (speculative_flush_en),
      .i_flush_tag      (i_flush_tag),
      .i_rob_head_tag   (head_tag),
      .i_mul_accepted   (mul_result_accepted),
      .i_div_accepted   (div_result_accepted)
  );

  // ===========================================================================
  // MUL CDB Adapter: result pass-through -> CDB arbiter slot 1
  // ===========================================================================
  // MUL always wins lane 0 unless full flush discards its result on the same
  // edge, so adapter pending state is unreachable.
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .ALWAYS_GRANTED(1'b1)
  ) u_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mul_shim_out),
      .o_fu_complete   (mul_adapter_to_arbiter),
      .o_held_value    (),
      .i_grant         (o_cdb_grant[1]),
      .o_result_pending(mul_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // DIV CDB Adapter: result holding register -> CDB arbiter slot 2
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .REGISTER_OUTPUT(1'b1)
  ) u_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (div_shim_out),
      .o_fu_complete   (div_adapter_to_arbiter),
      .o_held_value    (),
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
  // Build either slot's LQ allocation from its routed MEM_RS packet.
  function automatic riscv_pkg::lq_alloc_req_t make_lq_alloc(
      input logic valid_routed, input riscv_pkg::rs_dispatch_t dispatch);
    riscv_pkg::lq_alloc_req_t r;
    begin
      r.valid = valid_routed && dispatch.mem_needs_lq;
      r.rob_tag = dispatch.rob_tag;
      r.is_fp = dispatch.is_fp_mem;
      r.size = dispatch.mem_size;
      r.sign_ext = dispatch.mem_signed;
      r.is_lr = (dispatch.op == riscv_pkg::LR_W) || (dispatch.op == riscv_pkg::LR_D);
      r.is_amo   = (dispatch.op == riscv_pkg::AMOSWAP_W)
                || (dispatch.op == riscv_pkg::AMOADD_W)
                || (dispatch.op == riscv_pkg::AMOXOR_W)
                || (dispatch.op == riscv_pkg::AMOAND_W)
                || (dispatch.op == riscv_pkg::AMOOR_W)
                || (dispatch.op == riscv_pkg::AMOMIN_W)
                || (dispatch.op == riscv_pkg::AMOMAX_W)
                || (dispatch.op == riscv_pkg::AMOMINU_W)
                || (dispatch.op == riscv_pkg::AMOMAXU_W)
                || (dispatch.op == riscv_pkg::AMOSWAP_D)
                || (dispatch.op == riscv_pkg::AMOADD_D)
                || (dispatch.op == riscv_pkg::AMOXOR_D)
                || (dispatch.op == riscv_pkg::AMOAND_D)
                || (dispatch.op == riscv_pkg::AMOOR_D)
                || (dispatch.op == riscv_pkg::AMOMIN_D)
                || (dispatch.op == riscv_pkg::AMOMAX_D)
                || (dispatch.op == riscv_pkg::AMOMINU_D)
                || (dispatch.op == riscv_pkg::AMOMAXU_D);
      r.amo_op = dispatch.op;
      make_lq_alloc = r;
    end
  endfunction

  riscv_pkg::lq_alloc_req_t lq_alloc_req;
  riscv_pkg::lq_alloc_req_t lq_alloc_req_2;
  always_comb begin
    lq_alloc_req   = make_lq_alloc(mem_rs_dispatch_valid, mem_rs_dispatch);
    // Slot-2 LQ alloc derived from slot-2's mem_rs_dispatch packet; valid when
    // slot-2 is a load.
    lq_alloc_req_2 = make_lq_alloc(mem_rs_dispatch_valid_2, mem_rs_dispatch_2);
  end

  // ===========================================================================
  // Load Queue: Address Update from MEM_RS Issue
  // ===========================================================================
  logic [riscv_pkg::XLEN-1:0] lq_effective_addr;
  // Keep the full AGU address for xtval. The LQ checks PMA and alignment
  // before launch, so downstream decodes see only in-map addresses.
  assign lq_effective_addr = o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm;

  // MMIO detection: the 01 address quadrant [0x4000_0000, 0x8000_0000),
  // decoded from bits [31:30]. The cached (DDR) region is the 10 quadrant
  // [0x8000_0000, 0xC000_0000) and must not be flagged MMIO, so a lower-bound
  // test alone would be wrong.
  logic lq_addr_is_mmio;
  assign lq_addr_is_mmio = (lq_effective_addr[31:30] == 2'b01);

  riscv_pkg::lq_addr_update_t lq_addr_update;
  always_comb begin
    lq_addr_update.valid   = mem_rs_next_issue_valid && mem_rs_next_issue_needs_lq &&
                              mem_rs_fu_ready_base;
    lq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    lq_addr_update.address = lq_effective_addr;
    lq_addr_update.is_mmio = lq_addr_is_mmio;
    // Translation-stage faults arrive only from the data MMU; this
    // untranslated producer never faults (the LQ's own staged checks do).
    lq_addr_update.fault_kind = riscv_pkg::DFAULT_NONE;
    lq_addr_update.amo_rs2 = o_mem_rs_issue.src2_value[riscv_pkg::XLEN-1:0];
  end

  // Forward declarations (assigned in the data-MMU section below): the
  // packet and pre-issue pair the LQ consumes.  They are the combinational
  // MEM_RS path when translation is inactive, and the data MMU's S2 packet
  // and S1 look-ahead when it is active.
  riscv_pkg::lq_addr_update_t lq_addr_update_final;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dmmu_pre_rob_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_rob_tag_final;
  logic mem_rs_pre_issue_needs_lq_final;

  // ===========================================================================
  // Load Queue Instance
  // ===========================================================================
  load_queue #(
      .PREISSUE_CANDIDATES(EARLY_LOAD_WAKEUP),
      .PREISSUE_SEL_WIDTH(3),
      .PREISSUE_READY_PICK(EARLY_LOAD_WAKEUP),
      .PREISSUE_RS_DEPTH(riscv_pkg::MemRsDepth),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .ENABLE_SQ_FORWARD_FAST_PATH(1'b1)
  ) u_lq (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation (from dispatch)
      .i_alloc(lq_alloc_req),
      .i_alloc_2(lq_alloc_req_2),
      .o_full(lq_full_exact),
      .o_full_for_2(lq_full_for_2_exact),
      .o_dispatch_full(o_lq_full),
      .o_dispatch_full_for_2(o_lq_full_for_2),

      // Address update (from MEM_RS issue; under active translation it is
      // the data MMU's S2 packet: a PA, or the VA with a fault)
      .i_addr_update(lq_addr_update_final),

      // Pre-issue look-ahead (from MEM_RS, 1 cycle before i_addr_update;
      // under active translation it is the data MMU's S1 op, still one
      // cycle before its packet)
      .i_pre_issue_rob_tag(mem_rs_pre_issue_rob_tag_final),
      .i_pre_issue_rob_tags(mem_rs_pre_issue_rob_tags_final),
      .i_pre_issue_sel(mem_rs_pre_issue_sel),
      .i_pre_issue_needs_lq(mem_rs_pre_issue_needs_lq_final),
      // Match MEM_RS ready vectors and tags directly; the MMU look-ahead has a
      // separate port. Candidate tags above feed only simulation checks.
      .i_pre_issue_ready(mem_rs_pre_issue_ready),
      .i_pre_issue_entry_tags(mem_rs_pre_issue_entry_tags),
      .i_pre_issue_direct(i_translation_active),
      .i_pre_issue_direct_tag(dmmu_pre_rob_tag),

      // SQ disambiguation (internal wiring to store_queue)
      .o_sq_check_valid          (sq_check_valid),
      .o_sq_check_capture_valid  (sq_check_capture_valid),
      .o_sq_check_addr           (sq_check_addr),
      .o_sq_check_addr_b         (sq_check_addr_b),
      .o_sq_check_addr_c         (sq_check_addr_c),
      .o_sq_check_addr_d         (sq_check_addr_d),
      .o_sq_check_rob_tag        (sq_check_rob_tag),
      .o_sq_check_size           (sq_check_size),
      .i_sq_all_older_addrs_known(sq_all_older_addrs_known),
      .i_sq_forward              (sq_forward),
      .i_sq_commit_pending       (sq_commit_valid || sq_commit_valid_2),

      // Memory interface (external)
      .o_mem_read_en(o_lq_mem_read_en),
      .o_mem_addr_valid(o_lq_mem_addr_valid),
      .o_mem_read_addr(o_lq_mem_read_addr),
      .o_mem_read_size(o_lq_mem_read_size),
      .o_mem_read_id(o_lq_mem_read_id),
      .i_mem_read_data(i_lq_mem_read_data),
      .i_mem_read_valid(i_lq_mem_read_valid),
      .i_mem_read_is_cached(i_lq_mem_read_is_cached),
      .i_mem_read_id(i_lq_mem_read_id),
      // Keep the exact router Q separate from the composite busy expression:
      // full-flush bookkeeping uses it to distinguish a canceled staged read
      // from an accepted read whose stale response is still owed.
      .i_mem_request_pending(i_lq_mem_request_pending),
      // AMO writes share the load port. Block younger loads and L0 hits through
      // AMO completion to avoid stale data. Cached stores hold busy throughout
      // their variable-latency handshake.
      // Cover every router write-busy term so read handoff cannot overlap a busy
      // write port. The router's one-entry hold is reserved for device reads.
      .i_mem_bus_busy  (o_sq_mem_write_en || o_amo_mem_write_en || i_backend_recovery_hold ||
                        i_slow_write_inflight || i_lq_mem_request_pending),
      .i_cached_resp_held(i_cached_read_held),

      // CDB result (to MEM adapter; back-pressured when SC or store uses the slot)
      .o_fu_complete(lq_fu_complete),
      .o_fu_complete_staged(lq_fu_complete_staged),
      // Unused by the LQ but kept for Vivado mapping stability; see the
      // i_adapter_result_pending port comment in load_queue.sv before
      // removing it.
      .i_adapter_result_pending(mem_adapter_result_pending || sc_fu_complete_reg.valid ||
                                store_misalign_issue ||
                                store_misalign_fu_complete_reg.valid),
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
      .i_sq_committed_empty(sq_committed_empty_lq),
      .i_trap_misaligned_accesses(i_trap_misaligned_accesses),

      // AMO memory write interface
      .o_amo_mem_write_en(o_amo_mem_write_en),
      .o_amo_mem_write_addr(o_amo_mem_write_addr),
      .o_amo_mem_write_data(o_amo_mem_write_data),
      .o_amo_mem_write_is_dword(o_amo_mem_write_is_dword),
      .o_amo_mem_write_is_cached(o_amo_mem_write_is_cached),
      .i_amo_mem_write_done(i_amo_mem_write_done),

      // L0 cache invalidation (from SQ)
      .i_cache_invalidate_valid(sq_cache_invalidate_valid),
      .i_cache_invalidate_addr (sq_cache_invalidate_addr),

      // DMA coherence (lq_coherence_port)
      .i_coh_inval_valid(coh_lq_inval_valid),
      .i_coh_inval_addr(coh_lq_inval_addr),
      .i_coh_block_valid(coh_lq_block_valid),
      .i_coh_block_addr(coh_lq_block_addr),
      .i_coh_admit_pulse(coh_lq_admit_pulse),
      .i_coh_query_addr(coh_lq_query_addr),
      .o_coh_query_busy(coh_lq_query_busy),
      .o_coh_observe_valid(coh_observe_valid),
      .o_coh_observe_rob_tag(coh_observe_rob_tag),
      .o_coh_observe_addr(coh_observe_addr),

      // Flush
      .i_flush_en(lq_partial_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(speculative_flush_all),
      .i_early_recovery_flush(i_early_recovery_flush),

      // Status
      .o_empty(lq_empty_exact),
      .o_dispatch_empty(o_lq_empty),
      .o_count(lq_count_exact),
      .o_dispatch_count(o_lq_count),

      // L0 cache profile pulses
      .o_l0_hit(lq_l0_hit),
      .o_l0_fill(lq_l0_fill),
      .o_mem_outstanding(lq_mem_outstanding),

      // Head-load sub-bucket diagnostics
      .o_head_load_addr_pending(lq_head_load_addr_pending),
      .o_head_load_sq_disambig (lq_head_load_sq_disambig),
      .o_head_load_bus_blocked (lq_head_load_bus_blocked),
      .o_head_load_cdb_wait    (lq_head_load_cdb_wait),
      .o_head_load_post_lq     (lq_head_load_post_lq),

      // bus_blocked sub-bucket decomposition
      .o_head_load_bb_bus_busy         (lq_head_load_bb_bus_busy),
      .o_head_load_bb_sq_wait          (lq_head_load_bb_sq_wait),
      .o_head_load_bb_staging          (lq_head_load_bb_staging),
      .o_head_load_bbs_other_in_staging(lq_head_load_bbs_other_in_staging),
      .o_head_load_bbs_launch_gated    (lq_head_load_bbs_launch_gated),
      .o_head_load_bbs_capture_gap     (lq_head_load_bbs_capture_gap)
  );

  // ===========================================================================
  // MEM CDB Adapter: result pass-through -> CDB arbiter slot 3
  // ===========================================================================
  // Only MUL outranks MEM on the two-lane bus. MEM always wins a grant unless
  // full flush discards it, so pending state is unreachable.
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .ALWAYS_GRANTED(1'b1)
  ) u_mem_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (mem_fu_to_adapter),
      .o_fu_complete   (mem_adapter_to_arbiter),
      .o_held_value    (),
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
  // Build either slot's SQ allocation with the address invalid.
  // sq_early_addr_pipeline supplies it a cycle later when the base is ready;
  // otherwise it waits for operand repair or MEM_RS issue.
  function automatic riscv_pkg::sq_alloc_req_t make_sq_alloc(
      input logic valid_routed, input riscv_pkg::rs_dispatch_t dispatch);
    riscv_pkg::sq_alloc_req_t r;
    begin
      r.valid       = valid_routed && dispatch.mem_needs_sq;
      r.rob_tag     = dispatch.rob_tag;
      r.is_fp       = dispatch.is_fp_mem;
      r.size        = dispatch.mem_size;
      r.is_sc       = (dispatch.op == riscv_pkg::SC_W) || (dispatch.op == riscv_pkg::SC_D);
      r.addr_valid  = 1'b0;
      r.address     = '0;
      r.is_mmio     = 1'b0;
      make_sq_alloc = r;
    end
  endfunction

  riscv_pkg::sq_alloc_req_t sq_alloc_req;
  riscv_pkg::sq_alloc_req_t sq_alloc_req_2;
  always_comb begin
    sq_alloc_req   = make_sq_alloc(mem_rs_dispatch_valid, mem_rs_dispatch);
    // Slot-2 SQ alloc derived from slot-2's mem_rs_dispatch packet; valid when
    // slot-2 is a store.
    sq_alloc_req_2 = make_sq_alloc(mem_rs_dispatch_valid_2, mem_rs_dispatch_2);
  end

  // ===========================================================================
  // Pipelined early store address: register dispatch base+imm, compute next cycle
  // ===========================================================================
  // store_addr/sq_early_addr_pipeline.sv registers each slot's base and
  // immediate, then adds them the next cycle for timing.
  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  riscv_pkg::sq_addr_update_t sq_early_addr_update_2;
  logic sq_early_addr_capture_valid;
  logic sq_early_addr_capture_valid_2;
  sq_early_addr_pipeline sq_early_addr_pipeline_inst (
      .i_clk                          (i_clk),
      .i_rst_n                        (i_rst_n),
      .i_flush_all                    (i_flush_all),
      .i_flush_en                     (i_flush_en),
      // The SQ-local registered CDB lanes for the persistent-repair snoop, and
      // the MEM_RS issue tap that cancels a candidate whose store is issuing.
      .i_cdb                          (sq_cdb_bus),
      .i_cdb_2                        (sq_cdb_bus_2),
      .i_mem_rs_issue_valid           (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq),
      .i_mem_rs_issue_rob_tag         (o_mem_rs_issue.rob_tag),
      .i_done_repair_valid_1          (done_repair_valid_1),
      .i_done_repair_valid_2          (done_repair_valid_2),
      .i_done_repair_valid_3          (done_repair_valid_3),
      .i_done_repair_valid_4          (done_repair_valid_4),
      .i_done_repair_valid_5          (done_repair_valid_5),
      .i_done_repair_valid_6          (done_repair_valid_6),
      .i_bypass_tag_1                 (i_bypass_tag_1),
      .i_bypass_tag_2                 (i_bypass_tag_2),
      .i_bypass_tag_3                 (i_bypass_tag_3),
      .i_bypass_tag_4                 (i_bypass_tag_4),
      .i_bypass_tag_5                 (i_bypass_tag_5),
      .i_bypass_tag_6                 (i_bypass_tag_6),
      .i_bypass_value_1               (bypass_value_1),
      .i_bypass_value_2               (bypass_value_2),
      .i_bypass_value_3               (bypass_value_3),
      .i_bypass_value_4               (bypass_value_4),
      .i_bypass_value_5               (bypass_value_5),
      .i_bypass_value_6               (bypass_value_6),
      .i_mem_rs_dispatch              (mem_rs_dispatch),
      .i_mem_rs_dispatch_2            (mem_rs_dispatch_2),
      .i_sq_alloc_req                 (sq_alloc_req),
      .i_sq_alloc_req_2               (sq_alloc_req_2),
      .i_sq_full                      (o_sq_full),
      .i_sq_full_for_2                (o_sq_full_for_2),
      .o_sq_early_addr_update         (sq_early_addr_update),
      .o_sq_early_addr_update_2       (sq_early_addr_update_2),
      .o_sq_early_addr_capture_valid  (sq_early_addr_capture_valid),
      .o_sq_early_addr_capture_valid_2(sq_early_addr_capture_valid_2)
  );

  // ===========================================================================
  // Data MMU translation stage. Inactive translation selects the bypass
  // packets. i_translation_active changes only under a translation-CSR,
  // trap, or xRET flush.
  // ===========================================================================
  // The MMU takes LQ issue from lq_addr_update and SQ issue from MEM_RS
  // stage2 valid, which includes fu_ready. Both use the same base+imm sum.
  logic dmmu_iss_valid;
  assign dmmu_iss_valid = i_translation_active &&
      ((mem_rs_next_issue_valid && mem_rs_next_issue_needs_lq && mem_rs_fu_ready_base) ||
       (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq));

  logic [riscv_pkg::XLEN-1:0] dmmu_out_store_data;

  // AMOs and SC require write permission and D; LR needs read permission.
  // Inline enum comparisons work around Yosys package-function elaboration.
  logic dmmu_iss_is_amo;
  assign dmmu_iss_is_amo =
      (o_mem_rs_issue.op == riscv_pkg::AMOSWAP_W) || (o_mem_rs_issue.op == riscv_pkg::AMOADD_W) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOXOR_W) || (o_mem_rs_issue.op == riscv_pkg::AMOAND_W) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOOR_W) || (o_mem_rs_issue.op == riscv_pkg::AMOMIN_W) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOMAX_W) || (o_mem_rs_issue.op == riscv_pkg::AMOMINU_W) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOMAXU_W) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOSWAP_D) || (o_mem_rs_issue.op == riscv_pkg::AMOADD_D) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOXOR_D) || (o_mem_rs_issue.op == riscv_pkg::AMOAND_D) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOOR_D) || (o_mem_rs_issue.op == riscv_pkg::AMOMIN_D) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOMAX_D) || (o_mem_rs_issue.op == riscv_pkg::AMOMINU_D) ||
      (o_mem_rs_issue.op == riscv_pkg::AMOMAXU_D);
  // LR joins AMOs and SC in the MMU's atomic class (no device access).
  logic dmmu_iss_is_lr;
  assign dmmu_iss_is_lr = (o_mem_rs_issue.op == riscv_pkg::LR_W) ||
      (o_mem_rs_issue.op == riscv_pkg::LR_D);

  logic dmmu_out_valid;
  logic dmmu_out_lq_capture_valid;
  logic dmmu_out_sq_capture_valid;
  logic dmmu_out_is_mmio;
  logic dmmu_out_needs_sq;
  logic [riscv_pkg::XLEN-1:0] dmmu_out_amo_rs2;

  // Early opportunistic results (used by the packet muxes below).
  logic dmmu_early_ok, dmmu_early2_ok;
  logic [riscv_pkg::XLEN-1:0] dmmu_early_pa, dmmu_early2_pa;
  logic dmmu_early_is_mmio, dmmu_early2_is_mmio;
  // The MMU's pre-issue pair (its S1 stage's held op); the tag is declared
  // with the LQ's forward declarations.
  logic dmmu_pre_needs_lq;

  dmmu u_dmmu (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_active(i_translation_active),
      .i_sum(i_mmu_sum),
      .i_mxr(i_mmu_mxr),
      .i_eff_priv_u(i_mmu_eff_priv_u),
      .i_trap_misaligned(i_trap_misaligned_accesses),
      .i_flush_all(speculative_flush_all),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_head_tag(head_tag),
      .i_tlb_invalidate(o_tlb_invalidate),
      .i_iss_valid(dmmu_iss_valid),
      .i_iss_rob_tag(o_mem_rs_issue.rob_tag),
      .i_iss_va(lq_effective_addr),
      .i_iss_size(riscv_pkg::mem_size_e'(o_mem_rs_issue.mem_size)),
      .i_iss_needs_sq(o_mem_rs_issue.mem_needs_sq),
      .i_iss_store_perms(o_mem_rs_issue.mem_needs_sq || dmmu_iss_is_amo),
      .i_iss_is_sc(mem_rs_issue_is_sc),
      .i_iss_atomic(dmmu_iss_is_amo || dmmu_iss_is_lr || mem_rs_issue_is_sc),
      .i_iss_store_data(o_mem_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .i_iss_amo_rs2(o_mem_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .o_iss_out_valid(dmmu_out_valid),
      .o_iss_out_lq_capture_valid(dmmu_out_lq_capture_valid),
      .o_iss_out_sq_capture_valid(dmmu_out_sq_capture_valid),
      .o_iss_out_rob_tag(dmmu_out_tag),
      .o_iss_out_addr(dmmu_out_addr),
      .o_iss_out_is_mmio(dmmu_out_is_mmio),
      .o_iss_out_fault(dmmu_out_fault),
      .o_iss_out_needs_sq(dmmu_out_needs_sq),
      .o_iss_out_is_sc(dmmu_out_is_sc),
      .o_iss_out_store_data(dmmu_out_store_data),
      .o_iss_out_amo_rs2(dmmu_out_amo_rs2),
      .o_pre_rob_tag(dmmu_pre_rob_tag),
      .o_pre_needs_lq(dmmu_pre_needs_lq),
      .o_stall(dmmu_stall),
      .i_early_valid(sq_early_addr_update.valid),
      .i_early_va(sq_early_addr_update.address),
      .i_early2_valid(sq_early_addr_update_2.valid),
      .i_early2_va(sq_early_addr_update_2.address),
      .o_early_ok(dmmu_early_ok),
      .o_early_pa(dmmu_early_pa),
      .o_early_is_mmio(dmmu_early_is_mmio),
      .o_early2_ok(dmmu_early2_ok),
      .o_early2_pa(dmmu_early2_pa),
      .o_early2_is_mmio(dmmu_early2_is_mmio),
      .o_walk_req_valid(o_walk_req_valid),
      .i_walk_req_ready(i_walk_req_ready),
      .o_walk_vpn(o_walk_vpn),
      .i_walk_resp_valid(i_walk_resp_valid),
      .i_walk_resp(i_walk_resp)
  );

  // Store-family split of the issue-out pulse.
  assign dmmu_store_fault = dmmu_out_valid && dmmu_out_needs_sq &&
      (dmmu_out_fault != riscv_pkg::DFAULT_NONE);
  assign dmmu_store_ok = dmmu_out_valid && dmmu_out_needs_sq &&
      (dmmu_out_fault == riscv_pkg::DFAULT_NONE);

  // Delay early packets two cycles to align with registered MMU lookups.
  // Flush drops delayed valids: otherwise a stale address could reach a
  // reused ROB tag, and the SQ keeps the first address written. Dropping a
  // surviving store's early packet is safe because issue translates every
  // store and supplies its address. Payload shifts unconditionally.
  riscv_pkg::sq_addr_update_t sq_early_addr_update_q, sq_early_addr_update_2_q;
  riscv_pkg::sq_addr_update_t sq_early_addr_update_q2, sq_early_addr_update_2_q2;
  logic sq_early_delay_drop;
  assign sq_early_delay_drop = speculative_flush_all || speculative_flush_en;
  always_ff @(posedge i_clk) begin
    sq_early_addr_update_q <= sq_early_addr_update;
    sq_early_addr_update_2_q <= sq_early_addr_update_2;
    sq_early_addr_update_q2 <= sq_early_addr_update_q;
    sq_early_addr_update_2_q2 <= sq_early_addr_update_2_q;
    if (!i_rst_n || sq_early_delay_drop) begin
      sq_early_addr_update_q.valid <= 1'b0;
      sq_early_addr_update_2_q.valid <= 1'b0;
      sq_early_addr_update_q2.valid <= 1'b0;
      sq_early_addr_update_2_q2.valid <= 1'b0;
    end
  end

  // Without translation, early packets pass through. With translation, accept
  // the delayed packet and PA only on a permitted, dirty, in-map hit. Drop
  // other results; issue re-translates every store and reports faults.
  riscv_pkg::sq_addr_update_t sq_early_addr_update_final, sq_early_addr_update_2_final;
  logic sq_early_addr_capture_valid_final, sq_early_addr_capture_valid_2_final;
  always_comb begin
    if (i_translation_active) begin
      sq_early_addr_update_final.valid = sq_early_addr_update_q2.valid && dmmu_early_ok;
      sq_early_addr_update_final.rob_tag = sq_early_addr_update_q2.rob_tag;
      sq_early_addr_update_final.address = dmmu_early_pa;
      sq_early_addr_update_final.is_mmio = dmmu_early_is_mmio;
      sq_early_addr_update_2_final.valid = sq_early_addr_update_2_q2.valid && dmmu_early2_ok;
      sq_early_addr_update_2_final.rob_tag = sq_early_addr_update_2_q2.rob_tag;
      sq_early_addr_update_2_final.address = dmmu_early2_pa;
      sq_early_addr_update_2_final.is_mmio = dmmu_early2_is_mmio;
      // The opportunistic translation result is delayed relative to the raw
      // repair sideband. Only a real translated hit has phase-aligned data.
      sq_early_addr_capture_valid_final = sq_early_addr_update_final.valid;
      sq_early_addr_capture_valid_2_final = sq_early_addr_update_2_final.valid;
    end else begin
      sq_early_addr_update_final = sq_early_addr_update;
      sq_early_addr_update_2_final = sq_early_addr_update_2;
      sq_early_addr_capture_valid_final = sq_early_addr_capture_valid;
      sq_early_addr_capture_valid_2_final = sq_early_addr_capture_valid_2;
    end
  end

  // The translated LQ packet carries the S2 PA, or VA and fault kind. Its
  // valid omits recovery kills for timing: killed updates may write payload,
  // but LQ visibility and SQ-check control clear or block on that edge. Only
  // LQ and SQ payload capture use raw pulses; other consumers use dmmu_out_valid.
  //
  // S1 holds the operation until S2 delivery, preserving the LQ pre-issue
  // T-1/T pairing through hits and variable-latency misses.
  always_comb begin
    if (i_translation_active) begin
      lq_addr_update_final.valid = dmmu_out_lq_capture_valid;
      lq_addr_update_final.rob_tag = dmmu_out_tag;
      lq_addr_update_final.address = dmmu_out_addr;
      lq_addr_update_final.is_mmio = dmmu_out_is_mmio;
      lq_addr_update_final.fault_kind = dmmu_out_fault;
      lq_addr_update_final.amo_rs2 = dmmu_out_amo_rs2;
    end else begin
      lq_addr_update_final = lq_addr_update;
    end
  end

  assign mem_rs_pre_issue_rob_tag_final =
      i_translation_active ? dmmu_pre_rob_tag : mem_rs_pre_issue_rob_tag;
  assign mem_rs_pre_issue_rob_tags_final =
      i_translation_active ? {8{dmmu_pre_rob_tag}} : mem_rs_pre_issue_rob_tags;
  assign mem_rs_pre_issue_needs_lq_final =
      i_translation_active ? dmmu_pre_needs_lq : mem_rs_pre_issue_needs_lq;



  // ===========================================================================
  // Store Queue: Address + Data Update from MEM_RS Issue
  // ===========================================================================
  // Keep the full store address for xtval. Without translation, store_pma_issue
  // rejects out-of-map stores before their SQ entries can drain.
  assign sq_effective_addr = o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm;

  logic sq_addr_is_mmio;
  // MMIO quadrant test; see lq_addr_is_mmio above.
  assign sq_addr_is_mmio = (sq_effective_addr[31:30] == 2'b01);

  // With translation, MMU S2 supplies the checked PA and aligned store data.
  // Faulting updates set neither address-valid nor data-valid. Early prefill
  // may already have set address-valid, but data stays invalid and the store
  // never commits or drains.
  riscv_pkg::sq_addr_update_t sq_addr_update;
  logic sq_addr_update_capture_valid;
  always_comb begin
    if (i_translation_active) begin
      sq_addr_update.valid   = dmmu_store_ok;
      sq_addr_update.rob_tag = dmmu_out_tag;
      sq_addr_update.address = dmmu_out_addr;
      sq_addr_update.is_mmio = dmmu_out_is_mmio;
    end else begin
      sq_addr_update.valid   = o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
                               !store_misalign_issue;
      sq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
      sq_addr_update.address = sq_effective_addr;
      sq_addr_update.is_mmio = sq_addr_is_mmio;
    end
  end
  // Capture payload even on faults and flushes for timing. Faults leave data
  // invalid even if early prefill set address-valid; flush invalidates killed
  // entries, so neither can drain. Under translation, raw S2 drives capture
  // while dmmu_store_ok controls visibility.
  assign sq_addr_update_capture_valid = i_translation_active ?
      dmmu_out_sq_capture_valid :
      (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq);

  // Data update: store data from src2_value (the MMU sideband's delayed
  // copy when translation is active).
  riscv_pkg::sq_data_update_t sq_data_update;
  logic sq_data_update_capture_valid;
  always_comb begin
    if (i_translation_active) begin
      sq_data_update.valid   = dmmu_store_ok;
      sq_data_update.rob_tag = dmmu_out_tag;
      sq_data_update.data    = dmmu_out_store_data;
    end else begin
      sq_data_update.valid   = o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
                               !store_misalign_issue;
      sq_data_update.rob_tag = o_mem_rs_issue.rob_tag;
      sq_data_update.data = o_mem_rs_issue.src2_value;
    end
  end
  // Visibility is governed by sq_data_update.valid.  This broader write
  // enable only refreshes payload storage that a fault leaves invalid.
  assign sq_data_update_capture_valid = sq_addr_update_capture_valid;

`ifndef SYNTHESIS
`ifndef FORMAL
  // The raw translated-store pulse omits recovery kills, so it may write
  // payload only.  These checks keep any consumer from turning it into
  // architectural visibility or a completion side effect.
  always_comb begin
    if (i_rst_n && (i_translation_active === 1'b1) && !$isunknown(
            {dmmu_out_valid, dmmu_out_sq_capture_valid, dmmu_out_needs_sq,
             sq_addr_update.valid, sq_data_update.valid, dmmu_store_ok,
             dmmu_store_fault, store_issue_fire, dmmu_out_is_sc}
        )) begin
      if (dmmu_out_valid && dmmu_out_needs_sq) begin
        a_dmmu_store_valid_implies_raw_capture :
        assert (dmmu_out_sq_capture_valid)
        else $error("tomasulo_wrapper: translated store valid escaped raw SQ capture");
      end
      if (dmmu_out_sq_capture_valid && !dmmu_out_valid) begin
        a_dmmu_raw_sq_capture_has_no_visibility :
        assert (!sq_addr_update.valid && !sq_data_update.valid)
        else $error("tomasulo_wrapper: killed translated store set SQ visibility");
        a_dmmu_raw_sq_capture_has_no_side_effect :
        assert (!dmmu_store_ok && !dmmu_store_fault && !store_issue_fire &&
                !(dmmu_store_ok && dmmu_out_is_sc))
        else $error("tomasulo_wrapper: killed translated store escaped payload-only capture");
      end
    end
  end
`endif
`endif

  // ===========================================================================
  // Store Queue Instance
  // ===========================================================================
  store_queue #(
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      // sq_alloc_req.valid derives from mem_rs_dispatch_valid(_2), which
      // dispatch gates on the SQ's registered conservative room flags, so the
      // local re-checks are redundant (see the parameter comment).
      .TRUST_DISPATCH_VALID(1'b1)
  ) u_sq (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation (from dispatch)
      .i_alloc(sq_alloc_req),
      .i_alloc_2(sq_alloc_req_2),
      .o_full(sq_full_exact),
      .o_full_for_2(sq_full_for_2_exact),
      .o_dispatch_full(o_sq_full),
      .o_dispatch_full_for_2(o_sq_full_for_2),

      // The slots have distinct ROB tags, so early updates target distinct SQ
      // entries. Translation adds two cycles and requires a permitted MMU hit.
      .i_early_addr_update(sq_early_addr_update_final),
      .i_early_addr_update_2(sq_early_addr_update_2_final),
      .i_early_addr_capture_valid(sq_early_addr_capture_valid_final),
      .i_early_addr_capture_valid_2(sq_early_addr_capture_valid_2_final),

      // Address update (from MEM_RS issue)
      .i_addr_update              (sq_addr_update),
      .i_addr_update_capture_valid(sq_addr_update_capture_valid),

      // Data update (from MEM_RS issue)
      .i_data_update              (sq_data_update),
      .i_data_update_capture_valid(sq_data_update_capture_valid),

      // Registered SQ commit, delayed one cycle for timing.
      .i_commit_valid  (sq_commit_valid),
      .i_commit_rob_tag(commit_q_tag),

      // Registered slot-2 commit; the tag is meaningful only when valid.
      .i_commit_valid_2  (sq_commit_valid_2),
      .i_commit_rob_tag_2(commit_q_2_tag),

      // Commit pulses without the full-flush mask, for the forwarding probe's
      // scan only (see the sq_commit_valid_scan definition above for the
      // contract).
      .i_commit_valid_scan  (sq_commit_valid_scan),
      .i_commit_valid_scan_2(sq_commit_valid_scan_2),

      // Raw ROB store commits clear committed-empty one cycle before registered
      // commit reaches the SQ. Otherwise a trap could see an empty SQ and flush
      // a retired store. ROB commit is suppressed during flush.
      .i_commit_valid_comb(commit_store_like_raw),

      // Slot 2 likewise: commit_bus_2_q_valid is still one cycle away from
      // the SQ.
      .i_commit_valid_comb_2(commit_2_store_like_raw),

      // Store-to-load forwarding (from LQ)
      .i_sq_check_capture_valid  (sq_check_capture_valid),
      .i_sq_check_addr           (sq_check_addr),
      .i_sq_check_addr_b         (sq_check_addr_b),
      .i_sq_check_addr_c         (sq_check_addr_c),
      .i_sq_check_addr_d         (sq_check_addr_d),
      .i_sq_check_rob_tag        (sq_check_rob_tag),
      .i_sq_check_size           (sq_check_size),
      .o_sq_all_older_addrs_known(sq_all_older_addrs_known),
      .o_sq_forward              (sq_forward),

      // Memory write interface (external)
      .o_mem_write_en       (o_sq_mem_write_en),
      .o_mem_write_addr     (o_sq_mem_write_addr),
      .o_mem_write_data     (o_sq_mem_write_data),
      .o_mem_write_byte_en  (o_sq_mem_write_byte_en),
      .o_mem_write_is_mmio  (o_sq_mem_write_is_mmio),
      .o_mem_write_is_cached(o_sq_mem_write_is_cached),
      .i_mem_write_done     (i_sq_mem_write_done),

      // L0 cache invalidation (to LQ)
      .o_cache_invalidate_valid(sq_cache_invalidate_valid),
      .o_cache_invalidate_addr (sq_cache_invalidate_addr),

      // SC discard (pipelined: uses commit_bus_q)
      .i_sc_discard        (sc_discard),
      .i_sc_discard_rob_tag(commit_q_tag),

      // ROB head tag
      .i_rob_head_tag(head_tag),

      // Flush
      .i_flush_en(i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(full_flush_all),
      .i_flush_after_head_commit(i_flush_after_head_commit),

      // Status
      .o_empty               (sq_empty_exact),
      .o_dispatch_empty      (o_sq_empty),
      .o_committed_empty     (sq_committed_empty),
      .o_committed_empty_rob (sq_committed_empty_rob),
      .o_committed_empty_trap(o_sq_committed_empty_trap),
      .o_committed_empty_lq  (sq_committed_empty_lq),
      .o_count               (sq_count_exact),
      .o_dispatch_count      (o_sq_count)
  );

  // ===========================================================================
  // FP Shim: FP_RS issue -> fp_engine (every FP compute operation) ->
  // fu_complete_t
  // ===========================================================================
  // FP_RS guarantees a bubble after an issue covered by a flush.
  // The shim uses that bubble to squash a launch without delaying its enables.
  fp_shim #(
      .LAUNCH_SQUASH(1'b1)
  ) u_fp_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fp_rs_issue_w),
      .o_fu_complete (fp_shim_out),
      .o_fu_busy     (fp_busy),
      .i_flush       (speculative_flush_all),
      .i_flush_en    (speculative_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag)
  );

  // ===========================================================================
  // FP CDB Adapter: result holding register -> CDB arbiter slot 4
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .REGISTER_OUTPUT(1'b1)
  ) u_fp_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_shim_out),
      .o_fu_complete   (fp_adapter_to_arbiter),
      .o_held_value    (),
      .i_grant         (o_cdb_grant[4]),
      .o_result_pending(fp_adapter_result_pending),
      .i_flush         (speculative_flush_all),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // Backend Profiling Counters
  // ===========================================================================
  // PERF_COUNTERS enables tomasulo_perf_counters.
  generate
    if (PERF_COUNTERS != 0) begin : gen_perf_counters
      tomasulo_perf_counters #(
          .INT_RS_DEPTH(INT_RS_DEPTH)
      ) tomasulo_perf_counters_inst (
          .i_clk,
          .i_rst_n,
          .i_rob_perf_events(rob_perf_events),
          .i_int_rs_fu_ready(int_rs_fu_ready),
          .i_o_rs_empty(o_rs_empty),
          .i_mul_rs_fu_ready(mul_rs_fu_ready),
          .i_o_mul_rs_empty(o_mul_rs_empty),
          .i_mem_fu_to_adapter(mem_fu_to_adapter),
          .i_mem_adapter_result_pending(mem_adapter_result_pending),
          .i_fp_rs_fu_ready(fp_rs_fu_ready),
          .i_o_fp_rs_empty(o_fp_rs_empty),
          .i_sq_check_valid(sq_check_valid),
          .i_sq_all_older_addrs_known(sq_all_older_addrs_known),
          .i_sq_committed_empty(sq_committed_empty),
          .i_o_sq_mem_write_en(o_sq_mem_write_en),
          .i_o_lq_mem_read_en(o_lq_mem_read_en),
          .i_o_rob_count(o_rob_count),
          .i_o_lq_count(o_lq_count),
          .i_o_sq_count(o_sq_count),
          .i_o_rs_count(o_rs_count),
          .i_o_mul_rs_count(o_mul_rs_count),
          .i_o_mem_rs_count(o_mem_rs_count),
          .i_o_fp_rs_count(o_fp_rs_count),
          .i_lq_l0_hit(lq_l0_hit),
          .i_lq_l0_fill(lq_l0_fill),
          .i_lq_mem_outstanding(lq_mem_outstanding),
          .i_lq_head_load_addr_pending(lq_head_load_addr_pending),
          .i_lq_head_load_sq_disambig(lq_head_load_sq_disambig),
          .i_lq_head_load_bus_blocked(lq_head_load_bus_blocked),
          .i_lq_head_load_cdb_wait(lq_head_load_cdb_wait),
          .i_lq_head_load_post_lq(lq_head_load_post_lq),
          .i_lq_head_load_bb_bus_busy(lq_head_load_bb_bus_busy),
          .i_lq_head_load_bb_sq_wait(lq_head_load_bb_sq_wait),
          .i_lq_head_load_bb_staging(lq_head_load_bb_staging),
          .i_lq_head_load_bbs_other_in_staging(lq_head_load_bbs_other_in_staging),
          .i_lq_head_load_bbs_launch_gated(lq_head_load_bbs_launch_gated),
          .i_lq_head_load_bbs_capture_gap(lq_head_load_bbs_capture_gap),
          .i_int_rs_head_in_rs(int_rs_head_in_rs),
          .i_int_rs_head_rs_ready(int_rs_head_rs_ready),
          .i_int_rs_head_in_stage2(int_rs_head_in_stage2),
          .i_perf_snapshot_capture(i_perf_snapshot_capture),
          .i_perf_counter_select(i_perf_counter_select),
          .o_perf_counter_data(o_perf_counter_data)
      );
    end else begin : gen_no_perf_counters
      // No counters: the read port is zero; the event sources keep their
      // registers in their own modules and nothing reads them.
      assign o_perf_counter_data = '0;
      logic unused_perf_events;
      assign unused_perf_events = &{
          1'b0, i_perf_snapshot_capture, i_perf_counter_select, rob_perf_events,
          int_rs_fu_ready, o_rs_empty, mul_rs_fu_ready, o_mul_rs_empty, mem_fu_to_adapter,
          mem_adapter_result_pending, fp_rs_fu_ready, o_fp_rs_empty, sq_check_valid,
          sq_all_older_addrs_known, sq_committed_empty, o_sq_mem_write_en, o_lq_mem_read_en,
          o_rob_count, o_lq_count, o_sq_count, o_rs_count, o_mul_rs_count, o_mem_rs_count,
          o_fp_rs_count, lq_l0_hit, lq_l0_fill,
          lq_mem_outstanding, lq_head_load_addr_pending, lq_head_load_sq_disambig,
          lq_head_load_bus_blocked, lq_head_load_cdb_wait, lq_head_load_post_lq,
          lq_head_load_bb_bus_busy, lq_head_load_bb_sq_wait, lq_head_load_bb_staging,
          lq_head_load_bbs_other_in_staging, lq_head_load_bbs_launch_gated,
          lq_head_load_bbs_capture_gap, int_rs_head_in_rs, int_rs_head_rs_ready,
          int_rs_head_in_stage2
      };
    end
  endgenerate

`ifndef SYNTHESIS
`ifndef FORMAL
  // Router pending requires an LQ-tracked request. Full-flush cancellation
  // uses this to distinguish an unaccepted staged request from an accepted
  // one whose stale response is still due.
  always @(posedge i_clk) begin
    if (i_rst_n && i_lq_mem_request_pending && !lq_mem_outstanding)
      $error("tomasulo_wrapper: router pending request has no LQ response owner");
  end
`endif
`endif


  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  // The integrated wakeup merger's reachable-tag contract starts after this
  // initial reset edge; its combinational identities also hold before reset.
  initial assume (!i_rst_n);

  // These checks constrain translation to the inactive bypass path.
  always_comb assume (!i_translation_active);
  always_comb assume (!i_csr_translation_flush_req);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // Model dispatch's registered query channels to check that E1 repair
  // updates only the matching pending packet.
  generate
    if (ENABLE_DISPATCH_DONE_REPAIR) begin : g_formal_fp_pending_repair
      always_comb begin
        if (fp_pending_repair_capture_q) begin
          // dispatch.sv registers a ROB query for each renamed FP source on the
          // packet-capture edge. The E1 wait decision must match these queries.
          a_fp_repair_channel1_valid_matches_src1 :
          assume (i_bypass_valid_1 == !fp_dispatch_pending.src1_ready);
          a_fp_repair_channel2_valid_matches_src2 :
          assume (i_bypass_valid_2 == !fp_dispatch_pending.src2_ready);
          a_fp_repair_channel3_valid_matches_src3 :
          assume (i_bypass_valid_3 == !fp_dispatch_pending.src3_ready);
          if (i_bypass_valid_1) begin
            a_fp_repair_channel1_owns_src1 :
            assume (i_bypass_tag_1 == fp_dispatch_pending.src1_tag);
          end
          if (i_bypass_valid_2) begin
            a_fp_repair_channel2_owns_src2 :
            assume (i_bypass_tag_2 == fp_dispatch_pending.src2_tag);
          end
          if (i_bypass_valid_3) begin
            a_fp_repair_channel3_owns_src3 :
            assume (i_bypass_tag_3 == fp_dispatch_pending.src3_tag);
          end
        end
      end

      always @(posedge i_clk) begin
        if (i_rst_n) begin
          p_fp_repair_phase_has_packet :
          assert (!fp_pending_repair_capture_q || fp_dispatch_pending_valid);
          p_fp_repair_wait_has_phase :
          assert (!fp_pending_repair_wait_q || fp_pending_repair_capture_q);
          if (fp_pending_repair_capture_q) begin
            p_fp_repair_wait_matches_packet :
            assert (fp_pending_repair_wait_q ==
                    (!fp_dispatch_pending.src1_ready ||
                     !fp_dispatch_pending.src2_ready ||
                     !fp_dispatch_pending.src3_ready));
          end
          p_fp_repair_wait_matches_retired_query_gate :
          assert (fp_pending_repair_wait_q ==
                  (fp_pending_repair_capture_q &&
                   ((!fp_dispatch_pending.src1_ready && i_bypass_valid_1) ||
                    (!fp_dispatch_pending.src2_ready && i_bypass_valid_2) ||
                    (!fp_dispatch_pending.src3_ready && i_bypass_valid_3))));
          p_fp_repair_hold_prevents_dequeue :
          assert (!fp_repair_window_block || !fp_dispatch_dequeue);
          p_fp_repair_hold_prevents_refill :
          assert (!fp_repair_window_block || !fp_dispatch_slot_available);
        end

        if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
          p_fp_repair_phase_is_exactly_one_cycle :
          assert (fp_pending_repair_capture_q == $past(
              fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                !speculative_flush_all && !speculative_flush_en
          ));
          p_fp_repair_wait_is_capture_edge_unresolved :
          assert (fp_pending_repair_wait_q == $past(
              fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                !speculative_flush_all && !speculative_flush_en &&
                (!fp_rs_dispatch.src1_ready || !fp_rs_dispatch.src2_ready ||
                 !fp_rs_dispatch.src3_ready)
          ));

          if ($past(fp_dispatch_pending_flushed)) begin
            p_fp_pending_flush_clears_packet : assert (!fp_dispatch_pending_valid);
          end

          // CDB wakeup updates a buffered packet in every cycle it waits, not
          // only in E1. A cycle that captures a replacement packet is excluded
          // because the capture overwrites the packet register on that edge.
          if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src1_ready && cdb_bus_fp_qualified.valid &&
                  fp_dispatch_pending.src1_tag == cdb_bus_fp_qualified.tag
              )) begin
            p_fp_src1_cdb0_sets_ready : assert (fp_dispatch_pending.src1_ready);
            p_fp_src1_cdb0_value :
            assert (fp_dispatch_pending.src1_value == $past(cdb_bus_fp_qualified.value));
          end else if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src1_ready &&
                  !(cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src1_tag == cdb_bus_fp_qualified.tag) &&
                  cdb_bus_2_fp_qualified.valid &&
                  fp_dispatch_pending.src1_tag == cdb_bus_2_fp_qualified.tag
              )) begin
            p_fp_src1_cdb1_sets_ready : assert (fp_dispatch_pending.src1_ready);
            p_fp_src1_cdb1_value :
            assert (fp_dispatch_pending.src1_value == $past(cdb_bus_2_fp_qualified.value));
          end

          if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src2_ready && cdb_bus_fp_qualified.valid &&
                  fp_dispatch_pending.src2_tag == cdb_bus_fp_qualified.tag
              )) begin
            p_fp_src2_cdb0_sets_ready : assert (fp_dispatch_pending.src2_ready);
            p_fp_src2_cdb0_value :
            assert (fp_dispatch_pending.src2_value == $past(cdb_bus_fp_qualified.value));
          end else if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src2_ready &&
                  !(cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src2_tag == cdb_bus_fp_qualified.tag) &&
                  cdb_bus_2_fp_qualified.valid &&
                  fp_dispatch_pending.src2_tag == cdb_bus_2_fp_qualified.tag
              )) begin
            p_fp_src2_cdb1_sets_ready : assert (fp_dispatch_pending.src2_ready);
            p_fp_src2_cdb1_value :
            assert (fp_dispatch_pending.src2_value == $past(cdb_bus_2_fp_qualified.value));
          end

          if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src3_ready && cdb_bus_fp_qualified.valid &&
                  fp_dispatch_pending.src3_tag == cdb_bus_fp_qualified.tag
              )) begin
            p_fp_src3_cdb0_sets_ready : assert (fp_dispatch_pending.src3_ready);
            p_fp_src3_cdb0_value :
            assert (fp_dispatch_pending.src3_value == $past(cdb_bus_fp_qualified.value));
          end else if ($past(
                  fp_dispatch_pending_valid && !fp_dispatch_pending_flushed &&
                  !(fp_rs_dispatch.valid && fp_dispatch_slot_available &&
                    !speculative_flush_all && !speculative_flush_en) &&
                  !fp_dispatch_pending.src3_ready &&
                  !(cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src3_tag == cdb_bus_fp_qualified.tag) &&
                  cdb_bus_2_fp_qualified.valid &&
                  fp_dispatch_pending.src3_tag == cdb_bus_2_fp_qualified.tag
              )) begin
            p_fp_src3_cdb1_sets_ready : assert (fp_dispatch_pending.src3_ready);
            p_fp_src3_cdb1_value :
            assert (fp_dispatch_pending.src3_value == $past(cdb_bus_2_fp_qualified.value));
          end

          if ($past(
                  fp_dispatch_pending_valid && fp_pending_repair_capture_q &&
                  !fp_dispatch_pending_flushed && !fp_dispatch_pending.src1_ready &&
                  done_repair_valid_1 &&
                  fp_dispatch_pending.src1_tag == i_bypass_tag_1
              )) begin
            p_fp_src1_repair_retains_packet : assert (fp_dispatch_pending_valid);
            p_fp_src1_repair_sets_ready : assert (fp_dispatch_pending.src1_ready);
            if ($past(
                    cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src1_tag == cdb_bus_fp_qualified.tag
                )) begin
              p_fp_src1_cdb0_priority :
              assert (fp_dispatch_pending.src1_value == $past(cdb_bus_fp_qualified.value));
            end else if ($past(
                    cdb_bus_2_fp_qualified.valid &&
                             fp_dispatch_pending.src1_tag == cdb_bus_2_fp_qualified.tag
                )) begin
              p_fp_src1_cdb1_priority :
              assert (fp_dispatch_pending.src1_value == $past(cdb_bus_2_fp_qualified.value));
            end else begin
              p_fp_src1_done_repair_value :
              assert (fp_dispatch_pending.src1_value == $past(bypass_value_1));
            end
          end

          if ($past(
                  fp_dispatch_pending_valid && fp_pending_repair_capture_q &&
                  !fp_dispatch_pending_flushed && !fp_dispatch_pending.src2_ready &&
                  done_repair_valid_2 &&
                  fp_dispatch_pending.src2_tag == i_bypass_tag_2
              )) begin
            p_fp_src2_repair_retains_packet : assert (fp_dispatch_pending_valid);
            p_fp_src2_repair_sets_ready : assert (fp_dispatch_pending.src2_ready);
            if ($past(
                    cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src2_tag == cdb_bus_fp_qualified.tag
                )) begin
              p_fp_src2_cdb0_priority :
              assert (fp_dispatch_pending.src2_value == $past(cdb_bus_fp_qualified.value));
            end else if ($past(
                    cdb_bus_2_fp_qualified.valid &&
                             fp_dispatch_pending.src2_tag == cdb_bus_2_fp_qualified.tag
                )) begin
              p_fp_src2_cdb1_priority :
              assert (fp_dispatch_pending.src2_value == $past(cdb_bus_2_fp_qualified.value));
            end else begin
              p_fp_src2_done_repair_value :
              assert (fp_dispatch_pending.src2_value == $past(bypass_value_2));
            end
          end

          if ($past(
                  fp_dispatch_pending_valid && fp_pending_repair_capture_q &&
                  !fp_dispatch_pending_flushed && !fp_dispatch_pending.src3_ready &&
                  done_repair_valid_3 &&
                  fp_dispatch_pending.src3_tag == i_bypass_tag_3
              )) begin
            p_fp_src3_repair_retains_packet : assert (fp_dispatch_pending_valid);
            p_fp_src3_repair_sets_ready : assert (fp_dispatch_pending.src3_ready);
            if ($past(
                    cdb_bus_fp_qualified.valid &&
                    fp_dispatch_pending.src3_tag == cdb_bus_fp_qualified.tag
                )) begin
              p_fp_src3_cdb0_priority :
              assert (fp_dispatch_pending.src3_value == $past(cdb_bus_fp_qualified.value));
            end else if ($past(
                    cdb_bus_2_fp_qualified.valid &&
                             fp_dispatch_pending.src3_tag == cdb_bus_2_fp_qualified.tag
                )) begin
              p_fp_src3_cdb1_priority :
              assert (fp_dispatch_pending.src3_value == $past(cdb_bus_2_fp_qualified.value));
            end else begin
              p_fp_src3_done_repair_value :
              assert (fp_dispatch_pending.src3_value == $past(bypass_value_3));
            end
          end
        end
      end
    end
  endgenerate

  // The router holds one request. While pending, the LQ must not hand off
  // another; otherwise the held payload could be overwritten.
  always_comb begin
    if (i_rst_n && i_lq_mem_request_pending) begin
      // The router is outside this standalone formal top. Constrain its input
      // to the same integration invariant the simulation check above tests.
      a_router_pending_has_lq_response_owner : assume (lq_mem_outstanding);
      p_router_pending_blocks_lq_handoff : assert (!o_lq_mem_read_en);
    end
  end

  // Check live/fallback values against the effective adapter or test-injection
  // packet. These checks replace the arbiter's standalone input assumptions.
  riscv_pkg::fu_complete_t f_cdb_arb_in_0_generic;
  riscv_pkg::fu_complete_t f_cdb_arb_in_7_generic;
  always_comb begin
    f_cdb_arb_in_0_generic =
        alu_adapter_to_arbiter.valid ? alu_adapter_to_arbiter : i_fu_complete_0;
    f_cdb_arb_in_7_generic =
        alu2_adapter_to_arbiter.valid ? alu2_adapter_to_arbiter : i_fu_complete_7;

    p_cdb_alu_effective_packet_equiv : assert (cdb_arb_in_0 == f_cdb_arb_in_0_generic);
    p_cdb_alu_live_packet_valid : assert (!alu_value_is_live || cdb_arb_in_0.valid);
    p_cdb_alu_live_value_contract :
    assert (!alu_value_is_live || alu_shim_out.value == cdb_arb_in_0.value);
    p_cdb_alu_fallback_value_contract :
    assert (alu_value_is_live || alu_tree_fallback_value == cdb_arb_in_0.value);

    if (alu_value_is_live) begin
      p_cdb_alu_live_is_shim_valid : assert (alu_shim_out.valid);
      p_cdb_alu_live_adapter_identity : assert (alu_adapter_to_arbiter.value == alu_shim_out.value);
    end
    if (alu_adapter_result_pending && alu_adapter_to_arbiter.valid) begin
      p_cdb_alu_pending_output_is_held :
      assert (alu_adapter_to_arbiter.value == alu_adapter_held_value);
      p_cdb_alu_held_fallback_source : assert (alu_tree_fallback_value == alu_adapter_held_value);
    end else begin
      p_cdb_alu_injection_fallback_source :
      assert (alu_tree_fallback_value == i_fu_complete_0.value);
    end

    p_cdb_alu2_effective_packet_equiv : assert (cdb_arb_in_7 == f_cdb_arb_in_7_generic);
    p_cdb_alu2_live_packet_valid : assert (!alu2_value_is_live || cdb_arb_in_7.valid);
    p_cdb_alu2_live_value_contract :
    assert (!alu2_value_is_live || alu2_shim_out.value == cdb_arb_in_7.value);
    p_cdb_alu2_fallback_value_contract :
    assert (alu2_value_is_live || alu2_tree_fallback_value == cdb_arb_in_7.value);

    if (alu2_value_is_live) begin
      p_cdb_alu2_live_is_shim_valid : assert (alu2_shim_out.valid);
      p_cdb_alu2_live_adapter_identity :
      assert (alu2_adapter_to_arbiter.value == alu2_shim_out.value);
    end
    if (alu2_adapter_result_pending && alu2_adapter_to_arbiter.valid) begin
      p_cdb_alu2_pending_output_is_held :
      assert (alu2_adapter_to_arbiter.value == alu2_adapter_held_value);
      p_cdb_alu2_held_fallback_source :
      assert (alu2_tree_fallback_value == alu2_adapter_held_value);
    end else begin
      p_cdb_alu2_injection_fallback_source :
      assert (alu2_tree_fallback_value == i_fu_complete_7.value);
    end

  end

  // -------------------------------------------------------------------------
  // Structural constraints
  // -------------------------------------------------------------------------

  // No allocation during flush
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // No rename during full flush
  always_comb assume (!(i_rat_alloc_valid && i_flush_all));
  always_comb assume (!(i_rat_alloc_valid_2 && i_flush_all));

  // No rename during checkpoint restore
  always_comb assume (!(i_rat_alloc_valid && i_checkpoint_restore));
  always_comb assume (!(i_rat_alloc_valid_2 && i_checkpoint_restore));

  // Slot-2 RAT alloc can fire without slot-1 RAT alloc when slot-1 has no
  // destination (no formal assumption needed).

  // Dispatch qualifies early allocation candidates with bundle fire.
  always_comb begin
    assume (i_alloc_fire == i_alloc_req.alloc_valid);
    assume (i_rat_alloc_valid == (i_alloc_fire && i_alloc_has_dest));
    assume (i_rat_alloc_valid_2 == (i_alloc_fire && i_alloc_has_dest_2));
    if (i_checkpoint_save) assume (i_checkpoint_save_for_slot2 == i_checkpoint_slot2_candidate);
  end

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
      if (i_checkpoint_free_2) f_cp_valid[i_checkpoint_free_id_2] <= 1'b0;
    end
  end

  always_comb begin
    if (i_checkpoint_restore) assume (f_cp_valid[i_checkpoint_restore_id]);
  end

  // Dispatch never renames x0 to INT (either slot)
  always_comb begin
    if (i_rat_alloc_valid && !i_rat_alloc_dest_rf) assume (i_rat_alloc_dest_reg != '0);
    if (i_rat_alloc_valid_2 && !i_rat_alloc_dest_rf_2) assume (i_rat_alloc_dest_reg_2 != '0);
  end

  // Dispatch tag coordination
  always_comb begin
    if (i_alloc_req.alloc_valid && i_rat_alloc_valid) begin
      assume (i_rat_alloc_rob_tag == o_alloc_resp.alloc_tag);
    end
  end

  // dispatch.sv routes an RS packet only with allocation and uses that cycle's
  // allocated ROB tag. Model this to check the side RAM against real allocation.
  always_comb begin
    if (i_rs_dispatch.valid) begin
      assume (i_alloc_req.alloc_valid);
      assume (i_rs_dispatch.rob_tag == o_alloc_resp.alloc_tag);
    end
  end

  // This formal environment requires a live ROB tag for partial flush. Tail
  // rewinds to tag + 1; an arbitrary out-of-window tag could alias retained
  // entries. Production commit-time recovery can instead name a retired head
  // and sets i_flush_after_head_commit.
  always_comb begin
    if (i_flush_en && !i_flush_all) begin
      assume (!o_rob_empty);
      assume ({1'b0, i_flush_tag - head_tag} < o_rob_count);
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
    if (o_lq_full && i_rs_dispatch.mem_needs_lq) assume (!mem_rs_dispatch_valid);
  end

  // No MEM_RS store dispatch when SQ is full
  always_comb begin
    if (o_sq_full && i_rs_dispatch.mem_needs_sq) assume (!mem_rs_dispatch_valid);
  end

  // No LQ memory response during a flush
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
  // Commit bus assertions
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_commit_output_identity : assert (o_commit_comb == commit_bus);
      p_commit_observation_identity : assert (o_commit == commit_bus_q_qualified);
      p_commit_requires_head_ready : assert (!commit_bus.valid || (o_head_valid && o_head_done));
      p_commit_tag_is_head : assert (!commit_bus.valid || (commit_bus.tag == o_head_tag));
      // Slot 2 cannot retire without slot 1.
      p_commit_2_output_identity : assert (o_commit_comb_2 == commit_bus_2);
      p_commit_2_observation_identity : assert (o_commit_2 == commit_bus_2_q_qualified);
      p_commit_2_implies_commit_1 : assert (!commit_bus_2.valid || commit_bus.valid);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: commit propagation and flush
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // o_fence_i_flush registers two mutually exclusive ROB events:
      //   native: FENCE.I/SFENCE.VMA retires from SERIAL_FENCE_I_SYNC.
      //   translation: satp or mstatus/sstatus writes retire from
      //     SERIAL_CSR_TRANSLATION_DRAIN. An extra register lets csr_file
      //     consume the registered commit before flush.
      //
      // A native FENCE.I commit implies flush, but the converse is false:
      // translation CSR commits have no is_fence_i bit and precede flush by
      // an extra cycle. A satp write retiring at T appears in commit_bus_q
      // with o_translation_csr_commit_shadow at T+1, then raises flush at
      // T+2 with commit_bus_q.is_fence_i low.
      p_registered_native_fence_implies_flush :
      assert (!commit_bus_q.is_fence_i || o_fence_i_flush);

      // The translation shadow leads flush by one cycle. Excluding that event
      // leaves exactly the native FENCE.I commit and rejects unexplained pulses.
      p_native_fence_copy_matches_non_translation_flush :
      assert (commit_bus_q.is_fence_i == (o_fence_i_flush && !$past(
          o_translation_csr_commit_shadow
      )));

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

      // INT WAW: commit does not clear when the tag mismatches (newer rename)
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
      // CDB simultaneously present with RS dispatch
      cover_cdb_and_rs_dispatch : cover (cdb_bus_valid && i_rs_dispatch.valid);

      // flush_all while RS non-empty
      cover_flush_while_rs_nonempty : cover (i_flush_all && !o_rs_empty);

      // Commit fires
      cover_commit : cover (commit_bus.valid);


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

      // LQ allocation
      cover_lq_alloc : cover (lq_alloc_req.valid);

      // SQ allocation
      cover_sq_alloc : cover (sq_alloc_req.valid);

`ifdef FORMAL_DEEP_COVER
      // Optional deep covers for memory issue.
      cover_lq_mem_issue : cover (o_lq_mem_read_en);
      cover_sq_mem_write : cover (o_sq_mem_write_en);

      // Optional deep covers for RS issue and SQ commit.
      cover_rs_issue : cover (o_rs_issue.valid);
      cover_sq_commit : cover (sq_commit_valid);
`endif
    end
  end

`endif  // FORMAL

  // ===========================================================================
  // Simulation-only: assert FRM_DYN is resolved before entering FP RS
  // ===========================================================================
`ifdef VERILATOR
  always @(posedge i_clk)
    if (i_rst_n) begin
      if (fp_rs_dispatch.valid) assert (fp_rs_dispatch.rm != riscv_pkg::FRM_DYN);
    end

  // ===========================================================================
  // Simulation-only: stale-CDB producer diagnostics.
  //
  // reorder_buffer.sv detects free-entry deliveries but loses fu_type at its
  // input. Registered CDB lanes retain the producer here. A delivery outside
  // the recent-commit exception below indicates a missed flush kill or a
  // duplicate broadcast. Even if the ROB absorbs it, the same error after
  // tag reuse could corrupt a live entry; delivery in its drain window is fatal.
  // ===========================================================================
  int unsigned dbg_stale_cyc_since_flush;
  int unsigned dbg_stale_logged;
  always @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) dbg_stale_cyc_since_flush <= 0;
    else dbg_stale_cyc_since_flush <= dbg_stale_cyc_since_flush + 1;
  end
  // Filter tags committed in the last two cycles for JALR's double completion:
  // its link value is stored at allocation and branch_update marks it done,
  // so commit can precede a contended ALU broadcast. A full ROB can reuse a
  // tag within this window; the filter may also hide a stray write on that
  // allocation cycle, which the ROB absorbs. Report later free-entry writes.
  logic [3:0] dbg_recent_commit_valid;
  logic [3:0][riscv_pkg::ReorderBufferTagWidth-1:0] dbg_recent_commit_tag;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_recent_commit_valid <= '0;
    else begin
      dbg_recent_commit_valid <= {
        dbg_recent_commit_valid[1:0], commit_bus_2.valid, commit_bus.valid
      };
      dbg_recent_commit_tag <= {dbg_recent_commit_tag[1:0], commit_bus_2.tag, commit_bus.tag};
    end
  end
  function automatic logic dbg_recently_committed(
      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag);
    dbg_recently_committed = 1'b0;
    for (int k = 0; k < 4; k++) begin
      if (dbg_recent_commit_valid[k] && dbg_recent_commit_tag[k] == tag) begin
        dbg_recently_committed = 1'b1;
      end
    end
  endfunction
  // Snapshot MEM sources at grant: the broadcast arrives one cycle later.
  // This identifies whether a stale result came from SC, a store fault,
  // LQ cdb_stage, or the held adapter packet.
  logic dbg_prev_sc_valid, dbg_prev_mis_valid, dbg_prev_lq_valid;
  logic dbg_prev_adapter_pending;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] dbg_prev_lq_tag, dbg_prev_adapter_tag;
  always @(posedge i_clk) begin
    dbg_prev_sc_valid        <= sc_fu_complete_reg.valid;
    dbg_prev_mis_valid       <= store_misalign_fu_complete_reg.valid;
    dbg_prev_lq_valid        <= lq_fu_complete.valid;
    dbg_prev_lq_tag          <= lq_fu_complete.tag;
    dbg_prev_adapter_pending <= mem_adapter_result_pending;
    dbg_prev_adapter_tag     <= u_mem_adapter.held_result.tag;
  end
  always @(posedge i_clk) begin
    if (i_rst_n && dbg_stale_logged < 16) begin
      if (cdb_bus_valid && !u_rob.rob_valid[cdb_bus.tag] && !dbg_recently_committed(
              cdb_bus.tag
          )) begin
        dbg_stale_logged <= dbg_stale_logged + 1;
        $warning("tomasulo_wrapper: stale CDB lane0 tag=%0d fu_type=%0d (%0d cyc after last flush)",
                 cdb_bus.tag, cdb_bus.fu_type, dbg_stale_cyc_since_flush);
        if (cdb_bus.fu_type == riscv_pkg::FU_MEM) begin
          $warning(
              "  MEM sources at grant: sc=%0d mis=%0d lq_v=%0d lq_tag=%0d adp_held=%0d adp_tag=%0d",
              dbg_prev_sc_valid, dbg_prev_mis_valid, dbg_prev_lq_valid, dbg_prev_lq_tag,
              dbg_prev_adapter_pending, dbg_prev_adapter_tag);
        end
      end
      if (cdb_bus_2_valid && !u_rob.rob_valid[cdb_bus_2.tag] && !dbg_recently_committed(
              cdb_bus_2.tag
          )) begin
        dbg_stale_logged <= dbg_stale_logged + 1;
        $warning("tomasulo_wrapper: stale CDB lane1 tag=%0d fu_type=%0d (%0d cyc after last flush)",
                 cdb_bus_2.tag, cdb_bus_2.fu_type, dbg_stale_cyc_since_flush);
      end
    end
  end

  // A stale tag at cdb_stage capture points to the LQ issue or bypass path.
  // If capture is live but delivery is stale, check the kill before grant.
  always @(posedge i_clk) begin
    if (i_rst_n && dbg_stale_logged < 16) begin
      if (u_lq.issue_cdb_fire && !u_rob.rob_valid[u_lq.issue_cdb_result.tag]) begin
        $warning("tomasulo_wrapper: LQ captured DEAD tag=%0d via issue path (idx=%0d)",
                 u_lq.issue_cdb_result.tag, u_lq.issue_cdb_idx);
      end
      if (u_lq.bypass_fire && !u_rob.rob_valid[u_lq.bypass_tag]) begin
        $warning("tomasulo_wrapper: LQ captured DEAD tag=%0d via bypass (r=%0d h=%0d f=%0d m=%0d)",
                 u_lq.bypass_tag, u_lq.resp_bypass_fire, u_lq.cache_hit_bypass_fire,
                 u_lq.fwd_bypass_fire, u_lq.misalign_bypass_fire);
      end
    end
  end
`endif

endmodule
