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
 * Wrapper (instantiated by cpu_ooo) that instantiates ROB + RAT + six RS instances
 * (INT_RS, MUL_RS, MEM_RS, FP_RS, FMUL_RS, FDIV_RS), LQ, SQ, CDB arbiter,
 * FU shims, and hardwires the internal commit bus, dispatch routing,
 * SQ↔LQ forwarding, and shared CDB/flush signals.
 *
 * Dispatch routing:
 *   The full CPU uses per-RS dispatch payloads so unrelated source-family
 *   lookup cones do not feed every RS instance.  Wrapper-level tests can use
 *   the single-slot i_rs_dispatch bus by leaving SPLIT_RS_DISPATCH at 0.
 *
 * Internal wiring:
 *   ROB.o_commit_comb --> commit_bus --> cpu_ooo same-cycle mispredict detect
 *   ROB.o_commit_comb --> commit_bus --> commit_bus_pipeline --> o_commit
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

module tomasulo_wrapper #(
    parameter bit SPLIT_RS_DISPATCH = 1'b0,
    parameter bit ENABLE_DISPATCH_DONE_REPAIR = 1'b0,
    // Cached memory tier (high-address region). The load queue uses these to
    // decode is_cached and arm its single-outstanding launch gate only while
    // a cached load is in flight; the store queue uses them to tag cached
    // stores so the router can steer their write enables to the cached tier.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
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

    // Slot-2 allocation port for 2-wide dispatch.
    // Contract: alloc_valid_2 only asserts when alloc_valid is also set.
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req_2,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp_2,

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
    input riscv_pkg::fu_complete_t i_fu_complete_7,

    // =========================================================================
    // CDB Grant (back-pressure to FUs)
    // =========================================================================
    output logic [riscv_pkg::NumFus-1:0] o_cdb_grant,

    // =========================================================================
    // CDB Broadcast Output (for testbench observation; both lanes)
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
    // Commit Observation (tapped from internal commit bus)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb,
    output logic                              o_commit_valid_raw,
    output logic                              o_commit_misprediction_raw,
    output logic                              o_commit_correct_branch_raw,
    output logic                              o_commit_correct_branch_2_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // Widen-commit slot 2 observation (head+1).  Non-null only when the
    // 2-wide gate inside the ROB fires; otherwise valid bits are low and
    // payload is '0.  cpu_ooo consumes these in parallel with slot 1 for
    // two-wide architectural retirement.
    output riscv_pkg::reorder_buffer_commit_t o_commit_2,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb_2,
    output logic                              o_commit_2_valid_raw,
    output logic                              o_commit_2_store_like_raw,

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
    // Regfile-bypass field pre-decodes (see reorder_buffer port comment;
    // pure timing restructure of cpu_ooo's bypass_p*_we_q qualifiers).
    output logic                                        o_head_bypass_int_we_early,
    output logic                                        o_head_bypass_fp_we_early,
    output logic                                        o_head_next_bypass_int_we_early,
    output logic                                        o_head_next_bypass_fp_we_early,
    output logic                                        o_head_dir_train_early,
    output logic                                        o_head_branch_taken_early,
    output logic                                        o_head_next_dir_train_early,
    output logic                                        o_head_next_branch_taken_early,
    // Retired-next-PC precompute for cpu_ooo's interrupt_resume_pc (see
    // reorder_buffer port comment; pure timing restructure).
    output logic                  [riscv_pkg::XLEN-1:0] o_head_retired_next_pc,
    output logic                  [riscv_pkg::XLEN-1:0] o_head_next_retired_next_pc,
    output riscv_pkg::exc_cause_t                       o_trap_cause,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_value,
    input  logic                                        i_trap_taken,
    output logic                                        o_mret_start,
    input  logic                                        i_mret_done,
    input  logic                  [riscv_pkg::XLEN-1:0] i_mepc,
    input  logic                                        i_interrupt_pending,

    // Current privilege (PrivM/PrivU), forwarded to the ROB for U-mode
    // CSR/MRET illegal-instruction checks.
    input logic [1:0] i_priv,

    // mcounteren CY/TM/IR bits, forwarded to the ROB for the U-mode
    // counter-CSR illegal-instruction gate.
    input logic [2:0] i_mcounteren,
    // D15: mstatus.FS == Off, forwarded to the ROB for the FP-op
    // illegal-instruction gate at commit.
    input logic       i_mstatus_fs_off,
    input logic       i_trap_misaligned_accesses,

    // Widen-commit back-pressure: asserted when the downstream slot-2
    // retire path can accept a second commit this cycle.  cpu_ooo ties this
    // high because it has a dedicated second regfile write port.
    input logic i_widen_commit_ok,
    input logic i_commit_hold,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,
    // Flat recompute of i_flush_all (bit-identical; see
    // misprediction_flush_controller.o_flush_all_flat). Consumed only by the
    // commit-bus pipeline's registered-writeback valid mask so the ARF write
    // qualify does not ride the shared flush_all priority/broadcast cone.
    input logic                                        i_flush_all_wb_mask,
    input logic                                        i_flush_after_head_commit,
    input logic                                        i_backend_recovery_hold,
    // A slow-tier (cached-region) store is in flight between the memory
    // request router and the cache hierarchy. Folded into the LQ bus-busy
    // gate so load launches wait instead of piling into the router's
    // one-entry queued-load register (which can hold exactly ONE blocked
    // load; handshake-latency stores would otherwise overwrite it).
    input logic                                        i_slow_write_inflight,
    // Registered pending bit from the data-memory router's one-entry LQ hold.
    // Feed it directly into the LQ bus-busy gate, with no added register: a
    // mandatory-staged device request must block the very next LQ handoff and
    // remain blocked through terminal accept. The LQ also consumes this exact
    // Q separately during full flush, so cancellation of an unaccepted request
    // cannot be mistaken for an owed stale response.
    input logic                                        i_lq_mem_request_pending,

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

    // Shared committed-store drain status for trap/MRET, fence/AMO, and
    // router-accepted device reads.
    output logic                                        o_sq_committed_empty,
    output logic                                        o_rob_full,
    output logic                                        o_rob_full_for_2,
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
    // Channels 1-3: slot-1 source tags.  Channels 4-6: slot-2 source tags.
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
    // Slot-2-branch checkpoint flag: RAT overlays
    // slot-1's same-cycle rename onto the snapshot when this asserts.
    input logic                                        i_checkpoint_save_for_slot2,

    // =========================================================================
    // RAT Checkpoint Restore (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    input  logic                                    i_checkpoint_restore_reclaim_all,
    input  logic [   riscv_pkg::NumCheckpoints-1:0] i_checkpoint_flush_free_mask,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Free (from ROB on correct branch commit)
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
    input riscv_pkg::rs_dispatch_t i_fmul_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_fdiv_rs_dispatch,
    // Slot-2 RS dispatch ports (2-wide dispatch).  The dispatch unit drives
    // the slot-2 packet on the port for the RS family matching slot-2's
    // rs_type, asserting .valid only there when slot-2 fires.
    input riscv_pkg::rs_dispatch_t i_int_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fp_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fmul_rs_dispatch_2,
    input riscv_pkg::rs_dispatch_t i_fdiv_rs_dispatch_2,
    output logic o_rs_full,

    // =========================================================================
    // RS Issue (to Functional Unit)
    // =========================================================================
    output riscv_pkg::rs_issue_t o_rs_issue,
    // Same-edge INT stage2 tag copy consumed only by branch-resolution
    // checkpoint-owner and age predicates in cpu_ooo.
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_rs_issue_branch_predicate_tag,
    input logic i_rs_fu_ready,

    // =========================================================================
    // RS Status (INT_RS)
    // =========================================================================
    output logic                                       o_int_rs_full,
    output logic                                       o_int_rs_full_for_2,
    output logic                                       o_rs_empty,
    output logic [$clog2(riscv_pkg::IntRsDepth+1)-1:0] o_rs_count,

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
    // FP_RS (FP add/sub/cmp/cvt/classify/sgnj, depth 6)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                          o_fp_rs_issue,
    input  logic                                                          i_fp_rs_fu_ready,
    output logic                                                          o_fp_rs_full,
    output logic                                                          o_fp_rs_full_for_2,
    output logic                                                          o_fp_rs_empty,
    output logic                 [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] o_fp_rs_count,

    // =========================================================================
    // FMUL_RS (FP multiply/FMA, depth 4)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fmul_rs_issue,
    input  logic                                                            i_fmul_rs_fu_ready,
    output logic                                                            o_fmul_rs_full,
    output logic                                                            o_fmul_rs_full_for_2,
    output logic                                                            o_fmul_rs_empty,
    output logic                 [$clog2(riscv_pkg::FmulRsDepth + 1) - 1:0] o_fmul_rs_count,

    // =========================================================================
    // FDIV_RS (FP divide/sqrt, depth 2)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                            o_fdiv_rs_issue,
    input  logic                                                            i_fdiv_rs_fu_ready,
    output logic                                                            o_fdiv_rs_full,
    output logic                                                            o_fdiv_rs_full_for_2,
    output logic                                                            o_fdiv_rs_empty,
    output logic                 [$clog2(riscv_pkg::FdivRsDepth + 1) - 1:0] o_fdiv_rs_count,

    // =========================================================================
    // CSR Read Data (for ALU shim — CSR operations return old CSR value)
    // =========================================================================
    input logic [riscv_pkg::XLEN-1:0] i_csr_read_data,

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
    output logic                                              o_lq_mem_read_en,
    output logic                                              o_lq_mem_addr_valid,
    output logic                 [       riscv_pkg::XLEN-1:0] o_lq_mem_read_addr,
    output riscv_pkg::mem_size_e                              o_lq_mem_read_size,
    input  logic                 [riscv_pkg::MemDataBits-1:0] i_lq_mem_read_data,
    input  logic                                              i_lq_mem_read_valid,

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

  // ===========================================================================
  // Internal commit bus: ROB -> RAT / SQ / SC
  // ===========================================================================
  // commit_bus is the combinational output from the ROB. It stays on the
  // zero-cycle control path for cpu_ooo misprediction detection.
  //
  // commit_bus_q is a one-cycle pipeline register that breaks the critical
  // timing path from ROB head_ready/commit_en through SQ/RAT to LQ.
  // Internal consumers (RAT, SQ commit, SC logic) use the registered
  // version, except the SQ same-cycle flush-race guard, which taps the raw
  // ROB commit pulses.  The valid bit is cleared on full flush for safety —
  // although overlapping pipelined commits with flush_all only occurs for
  // non-store instructions (traps, MRET, FENCE.I), so SQ/SC are unaffected.
  riscv_pkg::reorder_buffer_commit_t commit_bus;
  // Split commit_bus_q into separate valid + data to prevent Vivado from
  // dragging the reset net onto payload register bits.
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

  // Widen-commit slot 2 parallel to commit_bus / commit_bus_q.  Slot 2 is
  // never SC/AMO/LR by construction (excluded by the ROB hazard gate), so
  // we only need the retire/store-like fields a cpu_ooo regfile-write +
  // SQ-release consumer uses.  Like commit_bus_q, split the valid bit out
  // so the reset cone does not touch the payload register bits.
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

  // The commit-bus pipeline registers (4 always_ff) now live in
  // commit_bus/commit_bus_pipeline.sv (pure boundary move).  Declarations above
  // and the reset-qualified reconstruction below stay in the wrapper.
  commit_bus_pipeline commit_bus_pipeline_inst (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all_wb_mask),
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

  // Reconstruct commit bus with reset-qualified valid for downstream consumers
  riscv_pkg::reorder_buffer_commit_t commit_bus_q_qualified;
  always_comb begin
    commit_bus_q_qualified       = commit_bus_q;
    commit_bus_q_qualified.valid = commit_bus_q_valid;
  end
  assign o_commit_valid_raw = commit_valid_raw;

  // Same trick for slot 2: expose a reset-qualified view of the registered
  // slot-2 commit for cpu_ooo's step-5 consumer.
  riscv_pkg::reorder_buffer_commit_t commit_bus_2_q_qualified;
  always_comb begin
    commit_bus_2_q_qualified       = commit_bus_2_q;
    commit_bus_2_q_qualified.valid = commit_bus_2_q_valid;
  end
  assign o_commit_2_valid_raw      = commit_2_valid_raw;
  assign o_commit_2_store_like_raw = commit_2_store_like_raw;

  // Back-end profiling counters (params, storage, accumulate/snapshot/mux) live
  // in tomasulo_perf_counters; instantiated below.

  // Expose both the raw and registered commit buses.
  assign o_commit_comb             = commit_bus;
  assign o_commit                  = commit_bus_q_qualified;
  assign o_commit_comb_2           = commit_bus_2;
  assign o_commit_2                = commit_bus_2_q_qualified;

  // ROB entry valid/done vectors: ROB -> RAT/dispatch
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_valid;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done;
  assign o_rob_entry_done_vec = rob_entry_done;

  // Dispatch done-repair: dispatch registers up to six renamed source ROB
  // tags (three per dispatch slot). One cycle later, already-done values return
  // to the indexed immediate-RS targets and SQ repair path. FP/FDIV pending
  // buffers are permanently slot-1-only and therefore consume channels 1/2.
  logic [riscv_pkg::FLEN-1:0] bypass_value_1, bypass_value_2, bypass_value_3;
  logic [riscv_pkg::FLEN-1:0] bypass_value_4, bypass_value_5, bypass_value_6;
  logic                       done_repair_valid_1;
  logic                       done_repair_valid_2;
  logic                       done_repair_valid_3;
  logic                       done_repair_valid_4;
  logic                       done_repair_valid_5;
  logic                       done_repair_valid_6;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_1;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_2;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_3;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_4;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_5;
  (* max_fanout = 32 *)logic                       int_done_repair_valid_6;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_1;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_2;
  logic [riscv_pkg::FLEN-1:0] fmul_pending_bypass_value_3;

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

  // Registered flush snapshot for the deep FP shims (fp_mul / fp_div).
  //
  // The live flush pulses fan out into hundreds of per-entry marking bits
  // inside the multi-cycle FP pipelines (32-entry FMUL/FMA tag queues,
  // 36/65-stage divider tag shift registers, hold buffers, result FIFOs) —
  // on x3 this net-dominated cone was ~1k failing endpoints post-place.
  // Those shims therefore consume a one-cycle-registered copy of the pulse
  // TOGETHER WITH the flush references snapshotted on the pulse cycle
  // (flush_tag/head move on later cycles as commits proceed; the age
  // compares must use the values that were live with the pulse).
  //
  // Legality contract (see the stale-CDB probes in the tomasulo_wrapper
  // bench and the fp_div_shim FORMAL flushed-tag discipline section):
  //  - The shims' ENTIRE kill logic shifts uniformly to the pulse+1 cycle:
  //    per-entry sweeps mark at the registered edge and the shims' own
  //    same-cycle head/tail guards evaluate against the registered pulse,
  //    so a squashed result is never PRESENTED from the pulse+1 cycle on.
  //  - The pulse+0 boundary is held by the (still live-flushed) adapters:
  //    partial flush age-kills the presented input / held result at the
  //    adapter, and both FP adapters are REGISTER_OUTPUT (no combinational
  //    pass-through), so nothing squashed can be granted on the pulse cycle.
  //  - For full-flush kinds the FP adapters' i_flush window is extended by
  //    one cycle (below) so a completion that pops into a shim FIFO on the
  //    pulse cycle and is presented on pulse+1 (before the registered clear
  //    lands) cannot be captured into the adapter holding register.
  //  - Occupancy/credit counts see squashed entries one cycle longer, which
  //    only adds back-pressure (no FIFO-overflow risk).
  // CoreMark is FP-free, so this retime is cycle-neutral there by
  // construction; int_muldiv/fp_add/alu shims keep live flushes.
  logic fp_shim_flush_all_q;
  logic fp_shim_flush_en_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_shim_flush_tag_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] fp_shim_flush_head_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fp_shim_flush_all_q <= 1'b0;
      fp_shim_flush_en_q  <= 1'b0;
    end else begin
      fp_shim_flush_all_q <= speculative_flush_all;
      fp_shim_flush_en_q  <= speculative_flush_en;
    end
  end
  always_ff @(posedge i_clk) begin
    fp_shim_flush_tag_q  <= i_flush_tag;
    fp_shim_flush_head_q <= head_tag;
  end


  // ===========================================================================
  // CDB Arbiter: FU completions → 2-lane CDB broadcast (o_cdb + o_cdb_2)
  // ===========================================================================
  riscv_pkg::cdb_broadcast_t cdb_bus_comb;  // combinational from arbiter
  // Registered metadata plus the merge-tree fallback value.  cdb_bus is the
  // phase-identical reconstructed view after the live-value restore below.
  (* equivalent_register_removal = "no" *)riscv_pkg::cdb_broadcast_t cdb_bus_q;
  riscv_pkg::cdb_broadcast_t cdb_bus;
  // SQ-only, phase-identical CDB copies.  The selected depth8+BRAM placement
  // spent 1.478 ns routing lane 1's generic value register from X133 to the
  // early-address repair logic at X51.  Keep exactly one narrow copy per lane
  // beside that consumer: only valid/tag/XLEN value are used by the SQ repair
  // path.  These copies intentionally have no max_fanout attribute; an earlier
  // wide three-way automatic replication experiment multiplied the routed
  // payload bundles and caused a severe congestion collapse.
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
  // TIMING: these four INT_RS-local copies previously carried dont_touch,
  // which makes Vivado IGNORE the max_fanout on the same declaration (no
  // replication of dont_touch nets) — they routed as single flops into the
  // whole INT_RS wakeup/capture fabric and were the worst path of the rv64
  // X3 route.  keep + equivalent_register_removal="no" retain the
  // anti-merge intent; the tightened cap lets synthesis replicate per
  // entry bank.
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 24 *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_int_rs_tag;
  // XLEN wide, not FLEN: INT_RS only consumes value[XLEN-1:0] (its ops are
  // integer ALU/branch/CSR), and dont_touch would pin the unused FLEN upper
  // half as 64 dead-but-routed flops inside the X3 congestion hotspot (they
  // showed up among the worst failing endpoints of the routed design).  The
  // qualified-struct assembly below zero-extends back to FLEN.
  //
  // dont_touch RESTORED on the VALUE copies (only): freeing them alongside
  // the tags let synthesis replicate 64-bit-wide registers inside the
  // int-RS capture fabric, and each replica drags a duplicate 64-bit wire
  // bundle through the exact X3 congestion hotspot this declaration was
  // originally shaped for -- the placer sweep collapsed to congestion
  // level 5 on 21/24 seeds and the surviving seeds quick-routed ~1ns
  // short.  The TAG copies stay replicable: 6-bit replicas are the
  // post-route wakeup timing win at negligible wiring cost.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::XLEN-1:0] cdb_bus_int_rs_value;
  riscv_pkg::cdb_broadcast_t cdb_bus_2_comb;  // 2-wide CDB lane-1, combinational
  // Registered lane-1 metadata/fallback and its reconstructed view.
  (* equivalent_register_removal = "no" *) riscv_pkg::cdb_broadcast_t cdb_bus_2_q;
  riscv_pkg::cdb_broadcast_t cdb_bus_2;
  // FMUL-only lane-1 tag anchor.  This five-bit copy samples the arbiter on
  // the same edge as cdb_bus_2; only u_fmul_rs consumes the reconstructed
  // packet below.  Keep it physically distinct without inviting replication
  // or duplicating the wide value payload.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_fmul_tag;
  // same-cycle INT_RS-local copy
  (* equivalent_register_removal = "no" *) riscv_pkg::cdb_broadcast_t cdb_bus_2_int_rs;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 24 *)
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] cdb_bus_2_int_rs_tag;
  // XLEN wide for the same reason as cdb_bus_int_rs_value above; value
  // copy pinned against replication for the same congestion reason.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic [riscv_pkg::XLEN-1:0] cdb_bus_2_int_rs_value;

  // Forward declarations: adapter→arbiter signals (used here, defined below)
  riscv_pkg::fu_complete_t alu_adapter_to_arbiter;
  riscv_pkg::fu_complete_t mul_adapter_to_arbiter;
  riscv_pkg::fu_complete_t div_adapter_to_arbiter;
  riscv_pkg::fu_complete_t mem_adapter_to_arbiter;
  riscv_pkg::fu_complete_t fp_add_adapter_to_arbiter;
  riscv_pkg::fu_complete_t fp_mul_adapter_to_arbiter;
  riscv_pkg::fu_complete_t fp_div_adapter_to_arbiter;
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

  // Arbiter-side pre-restore values/selects.  Only these auxiliaries, never
  // cdb_bus{,_2}_comb.value, feed the registered CDB value D inputs.
  logic [riscv_pkg::FLEN-1:0] cdb_lane0_tree_fallback_value_comb;
  logic [riscv_pkg::FLEN-1:0] cdb_lane1_tree_fallback_value_comb;
  logic cdb_lane0_select_alu_live_comb;
  logic cdb_lane0_select_alu2_live_comb;
  logic cdb_lane1_select_alu_live_comb;
  logic cdb_lane1_select_alu2_live_comb;

  // The four scalar selectors cross the existing CDB register boundary.
  // Their post-Q restore muxes reuse the ALU adapters' held payload registers;
  // there is deliberately no duplicate wide live-value register bank here.
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
    cdb_arb_in_4 = fp_add_adapter_to_arbiter.valid ? fp_add_adapter_to_arbiter : i_fu_complete_4;
    cdb_arb_in_5 = fp_mul_adapter_to_arbiter.valid ? fp_mul_adapter_to_arbiter : i_fu_complete_5;
    cdb_arb_in_6 = fp_div_adapter_to_arbiter.valid ? fp_div_adapter_to_arbiter : i_fu_complete_6;
    cdb_arb_in_7 = alu2_adapter_to_arbiter.valid ? alu2_adapter_to_arbiter : i_fu_complete_7;
  end

  // Split each ALU value into mutually exclusive live and fallback paths.
  // Adapter-valid while non-pending is precisely the qualified shim
  // pass-through case; partial-flush suppression clears adapter-valid.  The
  // fallback contains only a held adapter value or test-injection value and
  // therefore has no selected live-shim arm.  Name the exposed held-register
  // Q directly in the pending arm: although it equals the adapter output value
  // in that state, using the effective pending/live output mux there lets
  // synthesis retain a current live-shim dependency in the fallback D cone.
  // cdb_arb_in_* remains the exact generic effective packet and serves as the
  // compositional specification.
  assign alu_value_is_live = alu_adapter_to_arbiter.valid && !alu_adapter_result_pending;
  assign alu2_value_is_live = alu2_adapter_to_arbiter.valid && !alu2_adapter_result_pending;
  assign alu_tree_fallback_value =
      (alu_adapter_result_pending && alu_adapter_to_arbiter.valid) ?
      alu_adapter_held_value : i_fu_complete_0.value;
  assign alu2_tree_fallback_value =
      (alu2_adapter_result_pending && alu2_adapter_to_arbiter.valid) ?
      alu2_adapter_held_value : i_fu_complete_7.value;

  // Width-funnel perf observer (profiling only): >=3 FU completions request
  // the 2-lane CDB this cycle, so at least one requester must hold its
  // result and retry.  Registered so the tap adds no load to the arbiter
  // cone; drives nothing but a perf counter.
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

  // Pipeline register: break the CDB arbiter → RS/ROB wakeup critical path.
  // Grants stay combinational (back to adapters); only the broadcast fanout
  // to RS snoop + ROB CDB-write is registered.
  // Split valid from data to prevent Vivado from dragging reset onto payload.
  // max_fanout forces replication across the RS snoop / ROB-write consumers —
  // the high-fanout report (609 loads) showed this net being one of the top
  // drivers into the flush-recovery cone that failed timing at -0.947 ns.
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
    cdb_bus_int_rs_value         <= cdb_lane0_tree_fallback_value_comb[riscv_pkg::XLEN-1:0];
    cdb_lane0_select_alu_live_q  <= cdb_lane0_select_alu_live_comb;
    cdb_lane0_select_alu2_live_q <= cdb_lane0_select_alu2_live_comb;
  end

  // Restore a live ALU value after the register edge from the value captured
  // into that ALU adapter's pre-existing held_result register on the same
  // edge.  Fallback values, metadata, and selectors all retain the original
  // CDB phase.  Separate muxes preserve the existing generic/INT/SQ placement
  // domains without introducing any new wide live-value registers.
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

  // Expose combinational CDB for testbench observation (grant timing matches)
  assign o_cdb   = cdb_bus_comb;
  assign o_cdb_2 = cdb_bus_2_comb;

  // Reconstruct CDB broadcast with reset-qualified valid for downstream consumers
  riscv_pkg::cdb_broadcast_t cdb_bus_qualified;
  always_comb begin
    cdb_bus_qualified       = cdb_bus;
    cdb_bus_qualified.valid = cdb_bus_valid;
  end

  // INT_RS is physically far from the shared CDB register on Genesys2 and
  // snoops many value bits in parallel.  Give it an equivalent same-cycle CDB
  // register so placement can keep that high-fanout payload local without
  // changing wakeup latency.
  riscv_pkg::cdb_broadcast_t cdb_bus_int_rs_qualified;
  always_comb begin
    cdb_bus_int_rs_qualified = cdb_bus_int_rs;
    cdb_bus_int_rs_qualified.valid = cdb_bus_int_rs_valid;
    cdb_bus_int_rs_qualified.tag = cdb_bus_int_rs_tag;
    // Upper FLEN half is zero, not the broadcast value: INT_RS never reads
    // it, and the local copy register is deliberately XLEN wide (see decl).
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

  // Private CDB tag copies for the ROB head-match compares (the same-cycle
  // commit CDB bypass). The shared cdb_bus.tag replica inside the ROB also
  // drives every distributed-RAM write address (fo ~230 post-synth), so the
  // head_cdb_match compare started ~0.2 ns late and headed straight into the
  // commit -> SQ/trap arc. These duplicates load only the two 5-bit
  // comparators, keeping the compare source local. Same pattern as
  // cdb_bus_int_rs; values are identical to cdb_bus.tag / cdb_bus_2.tag.
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
    cdb_bus_2_fmul_tag           <= cdb_bus_2_comb.tag;
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
  // Preserve the generic lane's valid, value, FU type, and exception metadata;
  // replace only its tag with the phase-identical FMUL-local anchor.
  riscv_pkg::cdb_broadcast_t cdb_bus_2_fmul_qualified;
  always_comb begin
    cdb_bus_2_fmul_qualified = cdb_bus_2_qualified;
    cdb_bus_2_fmul_qualified.tag = cdb_bus_2_fmul_tag;
  end
  riscv_pkg::cdb_broadcast_t cdb_bus_2_int_rs_qualified;
  always_comb begin
    cdb_bus_2_int_rs_qualified = cdb_bus_2_int_rs;
    cdb_bus_2_int_rs_qualified.valid = cdb_bus_2_int_rs_valid;
    cdb_bus_2_int_rs_qualified.tag = cdb_bus_2_int_rs_tag;
    // Zero upper half, matching lane 0's XLEN-wide local value copy.
    cdb_bus_2_int_rs_qualified.value = {
      {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, cdb_bus_2_int_rs_restored_value
    };
  end

  // Reconstruct the standard port type with only the fields consumed by
  // sq_early_addr_pipeline populated.  Both local copies sample the same
  // combinational broadcasts on the same edges as the generic CDB registers,
  // so this changes placement only, never the observed completion cycle.
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
  // Cycle-exact identity contracts for the placement-only local copies and
  // post-Q restore muxes.  Qualify after reset because payload/select
  // registers intentionally carry no reset and are hidden by registered valid.
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
      p_fmul_cdb_lane1_tag_phase_identity : assert (cdb_bus_2_fmul_tag == cdb_bus_2.tag);

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
  // Dispatch Routing -> dispatch_routing/dispatch_rs_router.sv (boundary move).
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
  (* max_fanout = 32 *) logic fmul_rs_dispatch_valid;
  (* max_fanout = 32 *) logic fdiv_rs_dispatch_valid;
  (* max_fanout = 32 *) logic int_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic mem_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fp_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fmul_rs_dispatch_valid_2;
  (* max_fanout = 32 *) logic fdiv_rs_dispatch_valid_2;
  logic int_rs_intent_1;
  logic mul_rs_intent_1;
  logic mem_rs_intent_1;
  logic fp_rs_intent_1;
  logic fmul_rs_intent_1;
  logic fdiv_rs_intent_1;

  dispatch_rs_router #(
      .SPLIT_RS_DISPATCH(SPLIT_RS_DISPATCH)
  ) dispatch_rs_router_inst (
      .i_rs_dispatch(i_rs_dispatch),
      .i_int_rs_dispatch(i_int_rs_dispatch),
      .i_mul_rs_dispatch(i_mul_rs_dispatch),
      .i_mem_rs_dispatch(i_mem_rs_dispatch),
      .i_fp_rs_dispatch(i_fp_rs_dispatch),
      .i_fmul_rs_dispatch(i_fmul_rs_dispatch),
      .i_fdiv_rs_dispatch(i_fdiv_rs_dispatch),
      .i_int_rs_dispatch_2(i_int_rs_dispatch_2),
      .i_mul_rs_dispatch_2(i_mul_rs_dispatch_2),
      .i_mem_rs_dispatch_2(i_mem_rs_dispatch_2),
      .i_fp_rs_dispatch_2(i_fp_rs_dispatch_2),
      .i_fmul_rs_dispatch_2(i_fmul_rs_dispatch_2),
      .i_fdiv_rs_dispatch_2(i_fdiv_rs_dispatch_2),
      .i_backend_recovery_hold(i_backend_recovery_hold),
      .o_int_rs_dispatch_valid(int_rs_dispatch_valid),
      .o_mul_rs_dispatch_valid(mul_rs_dispatch_valid),
      .o_mem_rs_dispatch_valid(mem_rs_dispatch_valid),
      .o_fp_rs_dispatch_valid(fp_rs_dispatch_valid),
      .o_fmul_rs_dispatch_valid(fmul_rs_dispatch_valid),
      .o_fdiv_rs_dispatch_valid(fdiv_rs_dispatch_valid),
      .o_int_rs_dispatch_valid_2(int_rs_dispatch_valid_2),
      .o_mul_rs_dispatch_valid_2(mul_rs_dispatch_valid_2),
      .o_mem_rs_dispatch_valid_2(mem_rs_dispatch_valid_2),
      .o_fp_rs_dispatch_valid_2(fp_rs_dispatch_valid_2),
      .o_fmul_rs_dispatch_valid_2(fmul_rs_dispatch_valid_2),
      .o_fdiv_rs_dispatch_valid_2(fdiv_rs_dispatch_valid_2),
      .o_int_rs_intent_1(int_rs_intent_1),
      .o_mul_rs_intent_1(mul_rs_intent_1),
      .o_mem_rs_intent_1(mem_rs_intent_1),
      .o_fp_rs_intent_1(fp_rs_intent_1),
      .o_fmul_rs_intent_1(fmul_rs_intent_1),
      .o_fdiv_rs_intent_1(fdiv_rs_intent_1)
  );

  // Internal full signals for mux
  logic int_rs_full_w;
  logic mul_rs_full_w;
  logic mem_rs_full_w;
  logic fp_rs_full_w;
  logic fp_rs_full_raw;
  logic fp_rs_dispatch_full_q;
  logic fp_rs_empty_raw;
  logic [$clog2(riscv_pkg::FpRsDepth + 1) - 1:0] fp_rs_count_raw;
  logic fmul_rs_full_w;
  logic fmul_rs_full_raw;
  logic fmul_rs_empty_raw;
  logic [$clog2(riscv_pkg::FmulRsDepth + 1) - 1:0] fmul_rs_count_raw;
  logic fdiv_rs_full_w;
  logic fdiv_rs_full_raw;
  logic fdiv_rs_empty_raw;
  logic [$clog2(riscv_pkg::FdivRsDepth + 1) - 1:0] fdiv_rs_count_raw;

  // Per-RS full_for_2 outputs.  Plumbed through to consumers so dispatch
  // can independently gate slot-2.  FP-family RS instances buffer
  // dispatch through a 1-deep pending stage, so their effective full_for_2
  // also accounts for the pending slot.
  logic int_rs_full_for_2_w;
  logic mul_rs_full_for_2_w;
  logic mem_rs_full_for_2_w;
  logic fp_rs_full_for_2_raw;
  logic fmul_rs_full_for_2_raw;
  logic fdiv_rs_full_for_2_raw;
  // TIMING: the FP pending-stage valid gates the pending-payload capture and
  // folds into full_for_2 backpressure (measured post-place: a 1359-path
  // failing family into ROB alloc gating, ~260-fanout nets).  Cap it — and
  // its fmul/fdiv siblings — like the other 1-bit dispatch-control nets.
  (* max_fanout = 32 *) logic fp_dispatch_pending_valid;
  riscv_pkg::rs_dispatch_t fp_dispatch_pending;
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_to_rs;
  logic fp_dispatch_dequeue;
  logic fp_dispatch_slot_available;
  logic fp_dispatch_pending_flushed;
  (* max_fanout = 32 *) logic fmul_dispatch_pending_valid;
  riscv_pkg::rs_dispatch_t fmul_dispatch_pending;
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch_to_rs;
  logic fmul_dispatch_dequeue;
  logic fmul_dispatch_dequeue_room;
  logic fmul_dispatch_slot_available;
  logic fmul_dispatch_pending_flushed;
  (* max_fanout = 32 *) logic fdiv_dispatch_pending_valid;
  riscv_pkg::rs_dispatch_t fdiv_dispatch_pending;
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch_to_rs;
  logic fdiv_dispatch_dequeue;
  logic fdiv_dispatch_slot_available;
  logic fdiv_dispatch_pending_flushed;

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

  // Per-RS full_for_2 output ports.  For FP family RSes
  // the pending-buffer occupies an extra "virtual" slot, so dispatch must
  // treat the FP RS as full_for_2 whenever pending is occupied (the bypass
  // path for slot-2 has no buffer of its own).  The non-FP RSes simply
  // forward the RS-internal full_for_2 signal.
  assign o_int_rs_full_for_2 = int_rs_full_for_2_w;
  assign o_mul_rs_full_for_2 = mul_rs_full_for_2_w;
  assign o_mem_rs_full_for_2 = mem_rs_full_for_2_w;
  assign o_fp_rs_full_for_2 = fp_rs_dispatch_full_q || fp_dispatch_pending_valid;
  assign o_fmul_rs_full_for_2 = fmul_rs_full_for_2_raw || fmul_dispatch_pending_valid;
  assign o_fdiv_rs_full_for_2 = fdiv_rs_full_for_2_raw || fdiv_dispatch_pending_valid;

  assign fp_dispatch_dequeue = fp_dispatch_pending_valid &&
      !fp_rs_full_raw &&
      !speculative_flush_all &&
      !speculative_flush_en &&
      !i_backend_recovery_hold;
  assign fp_dispatch_slot_available = !fp_dispatch_pending_valid && !fp_rs_full_raw;
  assign fp_dispatch_pending_flushed = speculative_flush_all ||
      (speculative_flush_en &&
       fp_dispatch_pending_valid &&
       is_younger(
      fp_dispatch_pending.rob_tag, i_flush_tag, head_tag
  ));
  // FP add/cvt/class dispatch is not Coremark-sensitive, but its raw RS count
  // otherwise feeds the shared dispatch/ROB allocation cone.  Export a
  // registered, one-slot-conservative full signal; q==0 still guarantees room
  // for the 1-deep FP pending buffer to absorb one dispatch.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) begin
      fp_rs_dispatch_full_q <= 1'b0;
    end else begin
      fp_rs_dispatch_full_q <= fp_rs_full_for_2_raw || fp_dispatch_pending_valid;
    end
  end

  assign fp_rs_full_w = fp_rs_dispatch_full_q || fp_dispatch_pending_valid;
  assign o_fp_rs_empty = fp_rs_empty_raw && !fp_dispatch_pending_valid;
  assign o_fp_rs_count = fp_rs_count_raw + {{($bits(
      o_fp_rs_count
  ) - 1) {1'b0}}, fp_dispatch_pending_valid};

  assign fmul_dispatch_dequeue_room = fmul_dispatch_pending_valid && !fmul_rs_full_raw;
  assign fmul_dispatch_dequeue = fmul_dispatch_dequeue_room &&
      !speculative_flush_all &&
      !speculative_flush_en &&
      !i_backend_recovery_hold;
  assign fmul_dispatch_slot_available = !fmul_dispatch_pending_valid || fmul_dispatch_dequeue_room;
  assign fmul_dispatch_pending_flushed = speculative_flush_all ||
      (speculative_flush_en &&
       fmul_dispatch_pending_valid &&
       is_younger(
      fmul_dispatch_pending.rob_tag, i_flush_tag, head_tag
  ));
  assign fmul_rs_full_w = fmul_rs_full_raw ||
                         (fmul_dispatch_pending_valid && !fmul_dispatch_dequeue_room);
  assign o_fmul_rs_empty = fmul_rs_empty_raw && !fmul_dispatch_pending_valid;
  assign o_fmul_rs_count = fmul_rs_count_raw + {{($bits(
      o_fmul_rs_count
  ) - 1) {1'b0}}, fmul_dispatch_pending_valid};

  assign fdiv_dispatch_dequeue = fdiv_dispatch_pending_valid &&
      !fdiv_rs_full_raw &&
      !speculative_flush_all &&
      !speculative_flush_en &&
      !i_backend_recovery_hold;
  assign fdiv_dispatch_slot_available = !fdiv_dispatch_pending_valid && !fdiv_rs_full_raw;
  assign fdiv_dispatch_pending_flushed = speculative_flush_all ||
      (speculative_flush_en &&
       fdiv_dispatch_pending_valid &&
       is_younger(
      fdiv_dispatch_pending.rob_tag, i_flush_tag, head_tag
  ));
  assign fdiv_rs_full_w = fdiv_rs_full_raw || fdiv_dispatch_pending_valid;
  assign o_fdiv_rs_empty = fdiv_rs_empty_raw && !fdiv_dispatch_pending_valid;
  assign o_fdiv_rs_count = fdiv_rs_count_raw + {{($bits(
      o_fdiv_rs_count
  ) - 1) {1'b0}}, fdiv_dispatch_pending_valid};

  // ===========================================================================
  // ALU Pipeline: INT_RS issue → shim → adapter → CDB arbiter slot 0
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
  logic int_rs_fu_ready_2;
  logic int_rs_issue_writes_cdb_hint_2;
  logic alu2_fu_busy;

  assign int_rs_fu_ready = i_rs_fu_ready & ~alu_adapter_result_pending & ~i_backend_recovery_hold;
  assign int_rs_fu_ready_2 = i_rs_fu_ready & ~alu2_adapter_result_pending &
      ~i_backend_recovery_hold;

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

  // Pipelined MUL + DIV: back-pressure is governed by muldiv_busy (credit-based
  // FIFO occupancy in the shim). Adapter-pending bits no longer gate new issues,
  // since the shim FIFOs absorb transient CDB stalls.
  assign mul_rs_fu_ready = i_mul_rs_fu_ready & ~muldiv_busy & ~i_backend_recovery_hold;

  // FIFO-backed shims only pop when their adapter is idle.  If an adapter is
  // pending and receives a CDB grant, it drains first; the shim head is consumed
  // on the following cycle.  That avoids feeding the cross-FU CDB priority
  // encoder back into FIFO count CEs.
  logic mul_result_accepted;
  assign mul_result_accepted = !mul_adapter_result_pending && mul_shim_out.valid;

  logic div_result_accepted;
  assign div_result_accepted = !div_adapter_result_pending && div_shim_out.valid;

  // ===========================================================================
  // MEM (Load) Pipeline: LQ → adapter → CDB arbiter slot 3
  // ===========================================================================
  riscv_pkg::fu_complete_t lq_fu_complete;  // LQ → adapter
  // mem_adapter_to_arbiter declared above (forward declaration)
  logic mem_adapter_result_pending;
  logic lq_result_accepted;
  logic lq_l0_hit;  // LQ L0 cache fast-path completion (perf counter)
  logic lq_l0_fill;  // LQ L0 cache fill from memory response (perf counter)
  logic lq_mem_outstanding;  // LQ has a memory response in flight (perf counter)
  // Head-load sub-bucket state (from LQ, split head_wait_load_no_outstanding)
  logic lq_head_load_addr_pending;
  logic lq_head_load_sq_disambig;
  logic lq_head_load_bus_blocked;
  logic lq_head_load_cdb_wait;
  logic lq_head_load_post_lq;
  // bus_blocked sub-buckets (mutually exclusive partition of bus_blocked)
  logic lq_head_load_bb_issued;
  logic lq_head_load_bb_bus_busy;
  logic lq_head_load_bb_amo;
  logic lq_head_load_bb_sq_wait;
  logic lq_head_load_bb_staging;
  logic lq_head_load_bbs_other_in_staging;
  logic lq_head_load_bbs_launch_gated;
  logic lq_head_load_bbs_slow_outstanding;
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
  // SQ ↔ LQ Internal Wiring (store-to-load forwarding)
  // ===========================================================================
  logic sq_check_valid;
  logic sq_check_capture_valid;  // flush-free capture-enable variant
  logic [riscv_pkg::XLEN-1:0] sq_check_addr;
  // Port-split replicas of sq_check_addr. These are phase-identical LQ-side
  // registers kept distinct through the wrapper so each two-entry quarter of
  // the SQ CAM has an independent physical anchor.
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
  // Reservation register (LQ → ROB)
  logic lq_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] lq_reservation_addr;

  // SQ committed-empty (SQ → LQ, ROB)
  logic sq_committed_empty;
  assign o_sq_committed_empty = sq_committed_empty;

  // SC clear reservation: on any SC commit (success or failure clears reservation)
  // Uses pipelined commit bus to break ROB → LQ/SQ critical path.
  logic sc_clear_reservation;
  assign sc_clear_reservation = commit_bus_q_valid && commit_q_is_sc;

  // Reservation snoop invalidation: SQ write to reservation address. The
  // reservation covers a doubleword (RV64A — LR.D reserves it, and a
  // granule may exceed the LR width), so any store in the dword kills it.
  logic reservation_snoop_invalidate;
  assign reservation_snoop_invalidate = sq_cache_invalidate_valid &&
      lq_reservation_valid &&
      (sq_cache_invalidate_addr[riscv_pkg::XLEN-1:3] ==
       lq_reservation_addr[riscv_pkg::XLEN-1:3]);

  // SC discard: failed SC invalidates its SQ entry
  // Uses pipelined commit bus to break ROB → SQ critical path.
  logic sc_discard;
  assign sc_discard = commit_bus_q_valid && commit_q_sc_failed;

  // Store commit pulses.  These are also consumed by the LQ bus-busy gate
  // before the SQ instance, so keep the declarations near the commit-bus
  // derived SC/SQ wires instead of at the store_queue instantiation.
  logic sq_commit_valid;
  assign sq_commit_valid = commit_bus_q_valid && commit_q_is_store_like && !sc_discard;
  // Widen-commit slot 2: a second simultaneous store retire.  Slot 2 can
  // never be an SC, so no sc_discard gate.
  logic sq_commit_valid_2;
  assign sq_commit_valid_2 = commit_bus_2_q_valid && commit_q_2_is_store_like;

  // SCAN-ONLY commit pulses for the SQ forwarding probe (trap-cone-free).
  // Identical to sq_commit_valid/_2 except built from the RAW (pre-flush-mask)
  // registered valids: the !i_flush_all mask is the registered trap/MRET/
  // FENCE.I pulse, and routing it into the forwarding scan put the trap cone
  // on every o_sq_forward capture D-pin (x3 post-opt -0.138, 65 endpoints).
  // The variants differ from the architectural pulses ONLY on the full-flush
  // cycle, where the probe's captured result is structurally unconsumable
  // (o_sq_check_valid is flush-gated low, sq_check_phase2 is cleared, and
  // every consumer requires phase-2 lineage) — the same capture-then-kill
  // contract that lets the capture ENABLE omit its flush terms.  Never use
  // these for an architectural side effect (sq_committed, committed_empty,
  // flush_kill exemptions keep the masked pulses).
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

  // Age comparison for the FP-family pending-dispatch and store-misalign flush
  // guards (identical to the load_queue / reservation_station / sc_pending_unit copies)
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


  // Store completion: stores are "done" immediately after MEM_RS issue
  // (address + data go to SQ; ROB just needs to know the store completed).
  // SC_W is excluded — it has its own completion path above.
  assign store_misalign_issue =
      i_trap_misaligned_accesses &&
      o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
      (o_mem_rs_issue.op != riscv_pkg::SC_W) &&
                            (o_mem_rs_issue.op != riscv_pkg::SC_D) &&
      is_mem_access_misaligned(
      riscv_pkg::mem_size_e'(o_mem_rs_issue.mem_size), sq_effective_addr
  );
  assign store_issue_fire = o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
                            (o_mem_rs_issue.op != riscv_pkg::SC_W) &&
                            (o_mem_rs_issue.op != riscv_pkg::SC_D) &&
                            !store_misalign_issue;
  assign store_complete_tag = o_mem_rs_issue.rob_tag;

  // TIMING: sc_fu_complete is registered before reaching mem_fu_to_adapter.
  // The combinational chain
  //   fence_i_committed_reg → speculative_flush_all → sc_fire_now
  //     → mem_fu_to_adapter → MEM adapter bypass → cdb_arb_in[3]
  //     → cdb_bus_reg[tag][3]
  // was the post-IntRsDepth-bump worst-violating path (-0.710 ns WNS). SC is
  // rare (LR/SC atomic sequences only; 0 in CoreMark), so the resulting
  // 1-cycle delay on SC CDB broadcast is negligible. Plain loads still get
  // the fast combinational path via lq_fu_complete.
  riscv_pkg::fu_complete_t sc_fu_complete_reg;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all) sc_fu_complete_reg.valid <= 1'b0;
    else sc_fu_complete_reg.valid <= sc_fu_complete.valid;

    sc_fu_complete_reg.tag <= sc_fu_complete.tag;
    sc_fu_complete_reg.value <= sc_fu_complete.value;
    sc_fu_complete_reg.exception <= sc_fu_complete.exception;
    sc_fu_complete_reg.exc_cause <= sc_fu_complete.exc_cause;
    sc_fu_complete_reg.fp_flags <= sc_fu_complete.fp_flags;
  end

  riscv_pkg::fu_complete_t store_misalign_fu_complete;
  always_comb begin
    store_misalign_fu_complete = '0;
    store_misalign_fu_complete.valid = store_misalign_issue;
    store_misalign_fu_complete.tag = o_mem_rs_issue.rob_tag;
    store_misalign_fu_complete.exception = 1'b1;
    store_misalign_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(
        riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]);
    // Park the faulting address in the (otherwise unused) value slot so the
    // ROB can forward it as mtval at trap entry (RISC-V requires mtval = the
    // misaligned virtual address for a store-address-misaligned trap).
    store_misalign_fu_complete.value = {
      {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, sq_effective_addr
    };
  end

  // TIMING: Mirror the sc_fu_complete_reg pattern.  The combinational chain
  //   stage2_src1_bypassed → src1+imm → align check → store_misalign_fu_complete
  //   .valid → mem_fu_to_adapter → mem adapter passthrough → cdb_arb_in[3]
  //   → cdb_bus_reg[tag]
  // was the second-worst path family on x3.  Misaligned stores are exceptions
  // (CoreMark has none), so the resulting 1-cycle delay on the misalign-CDB
  // path is negligible.  Plain LQ results still take the fast combinational
  // path through mem_fu_to_adapter below.
  // Partial-flush kill: if the misaligned store's tag is younger than a
  // partial flush boundary, drop it.  Mirrors the partial_flush_input /
  // partial_flush_held checks inside fu_cdb_adapter so the registered version
  // never delivers a CDB completion for a flushed ROB entry.
  logic store_misalign_input_flushed;
  logic store_misalign_held_flushed;
  assign store_misalign_input_flushed = speculative_flush_en &&
      store_misalign_fu_complete.valid &&
      is_younger(
      store_misalign_fu_complete.tag, i_flush_tag, head_tag
  );
  riscv_pkg::fu_complete_t store_misalign_fu_complete_reg;
  assign store_misalign_held_flushed = speculative_flush_en &&
      store_misalign_fu_complete_reg.valid &&
      is_younger(
      store_misalign_fu_complete_reg.tag, i_flush_tag, head_tag
  );
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || speculative_flush_all || store_misalign_held_flushed) begin
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

  // MUX: SC > misaligned store exception > LQ for MEM adapter input.
  // Aligned plain stores mark the ROB done directly and do not occupy CDB.
  riscv_pkg::fu_complete_t mem_fu_to_adapter;
  always_comb begin
    if (sc_fu_complete_reg.valid) mem_fu_to_adapter = sc_fu_complete_reg;
    else if (store_misalign_fu_complete_reg.valid)
      mem_fu_to_adapter = store_misalign_fu_complete_reg;
    else mem_fu_to_adapter = lq_fu_complete;
  end

  // LQ is blocked while the registered SC completion owns MEM.  SC arming only
  // occurs when LQ is not presenting a result, avoiding a combinational SC
  // head-tag compare on the LQ/CDB backpressure cone.
  //
  // The accept term must match the PRESENTATION mux above exactly: whenever
  // the LQ result is the one presented, it is also granted that cycle (MEM
  // outranks everything but MUL and the CDB is 2-wide, so a presented MEM
  // result always wins a lane), so it must pop.  A live store_misalign_issue
  // used to block the accept here without blocking the presentation — the
  // granted-and-broadcast load then stayed in cdb_stage, the registered
  // misalign exception took the next cycle, and the leftover load was
  // presented and GRANTED A SECOND TIME one cycle later.  The duplicate
  // broadcast landed after the first delivery had already committed the load
  // through the CDB->head-done bypass, writing a freed ROB entry (the
  // "stale CDB delivery" events observed in Linux boot, one per few hundred
  // k cycles; a duplicate landing after the entry's index is REALLOCATED
  // would corrupt the new instruction — the tag-ABA hazard).  The same-cycle
  // misalign capture into store_misalign_fu_complete_reg needs no yield from
  // the load: it owns the MEM slot the NEXT cycle via the register either
  // way.
  assign lq_result_accepted = lq_fu_complete.valid &&
                              !sc_fu_complete_reg.valid &&
                              !store_misalign_fu_complete_reg.valid &&
                              !mem_adapter_result_pending;

  // SC resolution + pending-register FSM -> atomics/sc_pending_unit.sv.
  // store-misalign, the MEM mux, and lq_result_accepted stay in the wrapper.
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
      .i_store_misalign_issue          (store_misalign_issue),
      .i_store_misalign_fu_complete_reg(store_misalign_fu_complete_reg),
      .i_mem_rs_issue                  (o_mem_rs_issue),
      .i_sq_effective_addr             (sq_effective_addr),
      .i_speculative_flush_all         (speculative_flush_all),
      .i_speculative_flush_en          (speculative_flush_en),
      .i_speculative_partial_flush     (speculative_partial_flush),
      .o_sc_pending                    (sc_pending),
      .o_sc_fu_complete                (sc_fu_complete)
  );

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
  logic                    fp_mul_result_accepted;
  logic                    fmul_rs_fu_ready;

  assign fp_mul_result_accepted = !fp_mul_adapter_result_pending && fp_mul_shim_out.valid;

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
  logic                    fp_div_result_accepted;
  logic                    fdiv_rs_fu_ready_raw;
  logic                    fdiv_rs_fu_ready_q;
  logic                    fdiv_rs_fu_ready;

  assign fp_div_result_accepted = !fp_div_adapter_result_pending && fp_div_shim_out.valid;

  assign fdiv_rs_fu_ready_raw = i_fdiv_rs_fu_ready & ~fp_div_busy &
                                ~fp_div_adapter_result_pending & ~i_backend_recovery_hold;

  // FDIV/FSQRT are not CoreMark-critical, so allow one extra issue bubble here
  // to keep the fp_div_busy/result-pending cone off the FDIV RS control pins.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fdiv_rs_fu_ready_q <= 1'b0;
    end else begin
      fdiv_rs_fu_ready_q <= fdiv_rs_fu_ready_raw &&
                            !fdiv_rs_issue_w.valid &&
                            !fp_div_result_accepted;
    end
  end

  assign fdiv_rs_fu_ready = fdiv_rs_fu_ready_q & i_fdiv_rs_fu_ready & ~i_backend_recovery_hold;

  riscv_pkg::rs_issue_t mem_rs_issue_raw;
  riscv_pkg::rs_issue_t mem_rs_issue_w;
  logic mem_rs_next_is_sc;
  logic mem_rs_next_issue_valid;
  logic mem_rs_next_issue_needs_lq;
  logic mem_rs_fu_ready_base;
  logic mem_rs_fu_ready;

  // Do NOT gate SC issue on (sc_pending && next_is_sc). That single-SC
  // serialization deadlocked Linux: under speculation a YOUNGER SC issues
  // out-of-order, sets sc_pending, and then this gate blocked the OLDER head SC
  // from ever issuing -- so it never fired, sc_pending never cleared, and the
  // core hung at _prb_commit. sc_pending_unit now tracks multiple in-flight SCs
  // (a table keyed by ROB tag), so several SCs may legitimately be in flight.
  assign mem_rs_fu_ready_base = i_mem_rs_fu_ready &&
                                !sc_fu_complete_reg.valid &&
                                !mem_adapter_result_pending &&
                                !i_backend_recovery_hold;

  // Registered SC completion is already included in mem_rs_fu_ready_base.  The
  // arming cycle is kept off the MEM_RS ready cone to avoid feeding SC tag
  // compare into ordinary issue timing.
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

    fmul_rs_issue_w = fmul_rs_issue_raw;
    if (i_backend_recovery_hold) fmul_rs_issue_w.valid = 1'b0;

    fdiv_rs_issue_w = fdiv_rs_issue_raw;
    if (i_backend_recovery_hold) fdiv_rs_issue_w.valid = 1'b0;
  end

  // FP DIV uses the same no-refill adapter contract as integer MUL/DIV so
  // CDB arbitration does not feed back into the FP-div FIFO pop/count cone.
  // ===========================================================================
  // Reorder Buffer Instance
  // ===========================================================================
  reorder_buffer u_rob (
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

      // Commit output -> internal bus + registered observation
      .o_commit                             (),
      .o_commit_comb                        (commit_bus),
      .o_commit_valid_raw                   (commit_valid_raw),
      .o_commit_store_like_raw              (commit_store_like_raw),
      .o_commit_misprediction_raw           (o_commit_misprediction_raw),
      .o_commit_correct_branch_raw          (o_commit_correct_branch_raw),
      .o_commit_correct_branch_2_raw        (o_commit_correct_branch_2_raw),
      .o_head_commit_misprediction_candidate(o_head_commit_misprediction_candidate),

      // Widen-commit slot 2 — tapped into a parallel commit_bus_2 / _q
      // pair.  Registered observation goes to o_commit_2, and the
      // combinational view is exposed as o_commit_comb_2 for the same-cycle
      // path cpu_ooo consumes.
      .o_commit_2               (),
      .o_commit_comb_2          (commit_bus_2),
      .o_commit_2_valid_raw     (commit_2_valid_raw),
      .o_commit_2_store_like_raw(commit_2_store_like_raw),
      .i_widen_commit_ok        (i_widen_commit_ok),

      // External coordination
      .i_sq_committed_empty           (sq_committed_empty),
      .i_fence_i_sync_done            (i_fence_i_sync_done),
      .o_fence_i_sync_req             (o_fence_i_sync_req),
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
      .i_mret_done                    (i_mret_done),
      .i_mepc                         (i_mepc),
      .i_interrupt_pending            (i_interrupt_pending),
      .i_priv                         (i_priv),
      .i_mcounteren                   (i_mcounteren),
      .i_mstatus_fs_off               (i_mstatus_fs_off),
      .i_commit_hold                  (i_commit_hold),

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
      .o_full_for_2   (o_rob_full_for_2),
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
      .i_bypass_tag_4  (i_bypass_tag_4),
      .o_bypass_value_4(bypass_value_4),
      .i_bypass_tag_5  (i_bypass_tag_5),
      .o_bypass_value_5(bypass_value_5),
      .i_bypass_tag_6  (i_bypass_tag_6),
      .o_bypass_value_6(bypass_value_6),

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

      // Commit clear (pipelined — breaks ROB → RAT critical path)
      .i_commit_valid     (commit_bus_q_valid),
      .i_commit_dest_valid(commit_q_dest_valid),
      .i_commit_dest_rf   (commit_q_dest_rf),
      .i_commit_dest_reg  (commit_q_dest_reg),
      .i_commit_tag       (commit_q_tag),

      // Widen-commit slot 2 retire — identical pipelined pattern.
      .i_commit_valid_2     (commit_bus_2_q_valid),
      .i_commit_dest_valid_2(commit_q_2_dest_valid),
      .i_commit_dest_rf_2   (commit_q_2_dest_rf),
      .i_commit_dest_reg_2  (commit_q_2_dest_reg),
      .i_commit_tag_2       (commit_q_2_tag),

      // Checkpoint save
      .i_checkpoint_save          (i_checkpoint_save),
      .i_checkpoint_id            (i_checkpoint_id),
      .i_checkpoint_branch_tag    (i_checkpoint_branch_tag),
      .i_ras_tos                  (i_ras_tos),
      .i_ras_valid_count          (i_ras_valid_count),
      .i_checkpoint_save_for_slot2(i_checkpoint_save_for_slot2),

      // Checkpoint restore
      .i_checkpoint_restore            (i_checkpoint_restore),
      .i_checkpoint_restore_id         (i_checkpoint_restore_id),
      .i_checkpoint_restore_reclaim_all(i_checkpoint_restore_reclaim_all),
      .i_checkpoint_flush_free_mask    (i_checkpoint_flush_free_mask),
      .o_ras_tos                       (o_ras_tos),
      .o_ras_valid_count               (o_ras_valid_count),

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
  // INT_RS (depth 8): Integer ALU ops, branches, CSR
  // ---------------------------------------------------------------------------
  // Packed struct port connections.

  // INT_RS dispatch with routed valid
  riscv_pkg::rs_dispatch_t                                        int_rs_dispatch;
  riscv_pkg::rs_dispatch_t                                        int_rs_dispatch_2;
  logic                                                           int_rs_issue_writes_cdb_hint;
  // Issue-only phase-identical CDB metadata anchors.  These twelve FFs in the
  // current five-bit-tag configuration sample the same arbiter outputs on the
  // same edge as the ordinary INT-local CDB packets.  Only u_int_rs's live
  // issue/readiness compares consume them; there is no wide value duplicate.
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                                                           int_rs_issue_cdb_valid;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] int_rs_issue_cdb_tag;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                                                           int_rs_issue_cdb_2_valid;
  (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] int_rs_issue_cdb_2_tag;
  // Head-wait diagnostic observation from INT_RS (combinational scan of
  // rs_valid/rs_rob_tag against head_tag). Used to decompose head_wait_int
  // into sub-buckets: operand_wait / rs_ready_not_issued / stage2 / post_rs.
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
      .DEPTH(riscv_pkg::IntRsDepth),
      .HAS_SRC3(1'b0),
      .DISPATCH_REPAIR_BYPASS(1'b0),
      // ISSUE_REPAIR_BYPASS disabled on INT_RS: the in-issue
      //   rob_done_reg → done_repair_valid → src*_repair_sel → entry_ready
      //   → issue_idx → entry-select mux → stage2_src*_value/D
      // chain is the post-mem_rs-fix worst path.  Removing it means an entry
      // whose source becomes done-via-repair waits one extra cycle (until the
      // registered repair sets rs_src_ready) before it can issue.
      // For Coremark-relevant INT ops this case is rare — the common wakeup
      // is a same-cycle CDB broadcast (handled by src*_cdb_bypass), not a
      // missed-CDB repair.
      .ISSUE_REPAIR_BYPASS(1'b0),
      // The ROB response is exactly one cycle behind this immediate RS
      // allocation.  Remember the local entry and update its fixed source
      // directly instead of broadcasting six tags through every entry.
      .ALLOC_INDEXED_REPAIR(1'b1),
      .TRACK_INT_WRITEBACK_HINT(1'b1),
      // SPECULATIVE_DATA_WRITES decouples the per-entry data CE from the slow
      // dispatch_fire.  Without it, INT_RS rs_*_value_reg/CE inherits the
      // bundle_fire_ok cone and (when slot-1 is FDIV) the fdiv_rs/count_reg
      // → fdiv_rs_full chain.  Pairs with i_intent_1 below.
      .SPECULATIVE_DATA_WRITES(1'b1),
      // Prefill every free entry's wide source-value flops, then select the
      // slot-2 payload only on alloc_idx_2.  rs_valid remains the sole commit
      // point.  This keeps the free-entry priority decoder out of the 64-bit
      // value-flop clock enables without changing dispatch or issue timing.
      .BROADCAST_FREE_SOURCE_VALUES(1'b1),
      // Keep issue-time CDB tag matches physically separate from the identical
      // comparisons that control the resident source-value writes.  Shadow
      // tags use the existing speculative indexed writes, differ only for
      // non-targeting slots, and equal the architectural tags for every valid
      // entry.
      .ISSUE_CDB_TAG_SHADOW(1'b1),
      .ISSUE_CDB_META_ANCHORS(1'b1),
      .CAPTURE_PRIMARY_EFFECTIVE_OPERANDS(1'b1),
      .BRANCH_PREDICATE_TAG_ANCHOR(1'b1),
      .DUAL_ISSUE(1'b1)
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
      .o_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint),
      .o_branch_predicate_tag(int_rs_branch_predicate_tag),
      .o_issue_2(int_rs_issue_2_raw),
      .i_fu_ready_2(int_rs_fu_ready_2),
      .o_issue_writes_cdb_hint_2(int_rs_issue_writes_cdb_hint_2),
      .o_next_issue_valid(),
      .o_next_issue_is_sc(),  // unused — no SC ops in INT_RS
      .o_next_issue_needs_lq(),
      .o_pre_issue_rob_tag(),
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

  // Observation port: expose INT_RS issue for testbench
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
      // Keep current RAT source tags out of the ROB-done repair value mux on
      // the MUL dispatch write path. Already-done operands are repaired by the
      // allocation-indexed registered response one cycle later.
      .DISPATCH_REPAIR_BYPASS(1'b0),
      // Match INT/MEM timing: do not let live ROB-done repair participate in
      // the MUL issue-select/stage2 operand mux cone. The indexed response
      // wakes the entry for the following cycle.
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      // SPECULATIVE_DATA_WRITES + i_intent_1 keep the data CE off the slow
      // dispatch_fire chain (same rationale as INT_RS / MEM_RS).
      .SPECULATIVE_DATA_WRITES(1'b1)
  ) u_mul_rs (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_dispatch                 (mul_rs_dispatch),
      .i_dispatch_2               (mul_rs_dispatch_2),
      .i_intent_1                 (mul_rs_intent_1),
      .o_full                     (mul_rs_full_w),
      .o_full_for_2               (mul_rs_full_for_2_w),
      .i_cdb                      (cdb_bus_qualified),
      .i_cdb_2                    (cdb_bus_2_qualified),
      .i_issue_cdb_valid          (cdb_bus_qualified.valid),
      .i_issue_cdb_tag            (cdb_bus_qualified.tag),
      .i_issue_cdb_2_valid        (cdb_bus_2_qualified.valid),
      .i_issue_cdb_2_tag          (cdb_bus_2_qualified.tag),
      .i_repair_valid_1           (done_repair_valid_1),
      .i_repair_tag_1             (i_bypass_tag_1),
      .i_repair_value_1           (bypass_value_1),
      .i_repair_valid_2           (done_repair_valid_2),
      .i_repair_tag_2             (i_bypass_tag_2),
      .i_repair_value_2           (bypass_value_2),
      .i_repair_valid_3           (done_repair_valid_3),
      .i_repair_tag_3             (i_bypass_tag_3),
      .i_repair_value_3           (bypass_value_3),
      .i_repair_valid_4           (done_repair_valid_4),
      .i_repair_tag_4             (i_bypass_tag_4),
      .i_repair_value_4           (bypass_value_4),
      .i_repair_valid_5           (done_repair_valid_5),
      .i_repair_tag_5             (i_bypass_tag_5),
      .i_repair_value_5           (bypass_value_5),
      .i_repair_valid_6           (done_repair_valid_6),
      .i_repair_tag_6             (i_bypass_tag_6),
      .i_repair_value_6           (bypass_value_6),
      .o_issue                    (mul_rs_issue_raw),
      .i_fu_ready                 (mul_rs_fu_ready),
      .o_issue_writes_cdb_hint    (),
      .o_branch_predicate_tag     (),
      .o_issue_2                  (),
      .i_fu_ready_2               (1'b0),
      .o_issue_writes_cdb_hint_2  (),
      .o_next_issue_valid         (),
      .o_next_issue_is_sc         (),                           // unused — no SC ops in MUL_RS
      .o_next_issue_needs_lq      (),
      .o_pre_issue_rob_tag        (),
      .o_pre_issue_needs_lq       (),
      .i_flush_en                 (speculative_flush_en),
      .i_flush_tag                (i_flush_tag),
      .i_rob_head_tag             (head_tag),
      .i_flush_all                (speculative_flush_all),
      .o_empty                    (o_mul_rs_empty),
      .o_count                    (o_mul_rs_count),
      .i_head_query_tag           (head_tag),
      .o_head_query_in_rs         (),
      .o_head_query_rs_ready      (),
      .o_head_query_in_stage2     (),
      .o_perf_two_ready_one_issued()
  );

  // Observation port: expose MUL_RS issue for testbench
  assign o_mul_rs_issue = mul_rs_issue_w;

  // ---------------------------------------------------------------------------
  // MEM_RS (depth 8): Loads/stores (both INT and FP)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t                                        mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t                                        mem_rs_dispatch_2;
  logic                    [riscv_pkg::ReorderBufferTagWidth-1:0] mem_rs_pre_issue_rob_tag;
  logic                                                           mem_rs_pre_issue_needs_lq;

  always_comb begin
    mem_rs_dispatch         = SPLIT_RS_DISPATCH ? i_mem_rs_dispatch : i_rs_dispatch;
    mem_rs_dispatch.valid   = mem_rs_dispatch_valid;

    mem_rs_dispatch_2       = SPLIT_RS_DISPATCH ? i_mem_rs_dispatch_2 : '0;
    mem_rs_dispatch_2.valid = mem_rs_dispatch_valid_2;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::MemRsDepth),
      .HAS_SRC3(1'b0),
      .DISPATCH_REPAIR_BYPASS(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      .SPECULATIVE_DATA_WRITES(1'b1),
      // Dispatch has already checked MEM_RS exact full/full_for_2 status
      // before asserting these per-RS valid bits. Avoid re-feeding full into
      // the MEM_RS count update, which sits on the post-synth WNS path.
      .TRUST_DISPATCH_VALID(1'b1)
  ) u_mem_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(mem_rs_dispatch),
      .i_dispatch_2(mem_rs_dispatch_2),
      .i_intent_1(mem_rs_intent_1),
      .o_full(mem_rs_full_w),
      .o_full_for_2(mem_rs_full_for_2_w),
      .i_cdb(cdb_bus_qualified),
      .i_cdb_2(cdb_bus_2_qualified),
      .i_issue_cdb_valid(cdb_bus_qualified.valid),
      .i_issue_cdb_tag(cdb_bus_qualified.tag),
      .i_issue_cdb_2_valid(cdb_bus_2_qualified.valid),
      .i_issue_cdb_2_tag(cdb_bus_2_qualified.tag),
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
      .o_issue_writes_cdb_hint(),
      .o_branch_predicate_tag(),
      .o_issue_2(),
      .i_fu_ready_2(1'b0),
      .o_issue_writes_cdb_hint_2(),
      .o_next_issue_valid(mem_rs_next_issue_valid),
      .o_next_issue_is_sc(mem_rs_next_is_sc),
      .o_next_issue_needs_lq(mem_rs_next_issue_needs_lq),
      .o_pre_issue_rob_tag(mem_rs_pre_issue_rob_tag),
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
  // Resolve FRM_DYN at dispatch time (shared by all FP RS)
  // Clamp reserved frm CSR values (5–7) to RNE for safety.
  // ---------------------------------------------------------------------------
  wire [2:0] frm_safe = (i_frm_csr > riscv_pkg::FRM_RMM) ? riscv_pkg::FRM_RNE : i_frm_csr;
  function automatic logic [2:0] resolve_dispatch_rm(input logic [2:0] rm);
    begin
      resolve_dispatch_rm = (rm == riscv_pkg::FRM_DYN) ? frm_safe : rm;
    end
  endfunction

  // FP/FDIV packets are two-source, slot-1-only dispatches.  Their registered
  // repair response therefore lives exclusively on channels 1/2; keep the
  // slot-1 source-3 and all slot-2 channels out of these pending-packet cones.
  function automatic logic wrapper_done_repair_match(
      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag);
    begin
      wrapper_done_repair_match =
          (done_repair_valid_1 && tag == i_bypass_tag_1) ||
          (done_repair_valid_2 && tag == i_bypass_tag_2);
    end
  endfunction

  function automatic logic [riscv_pkg::FLEN-1:0] wrapper_done_repair_value(
      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag);
    begin
      if (done_repair_valid_1 && tag == i_bypass_tag_1) begin
        wrapper_done_repair_value = bypass_value_1;
      end else if (done_repair_valid_2 && tag == i_bypass_tag_2) begin
        wrapper_done_repair_value = bypass_value_2;
      end else begin
        wrapper_done_repair_value = '0;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // FP_RS (depth 6): FP add/sub/cmp/cvt/classify/sgnj
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fp_rs_dispatch;
  always_comb begin
    fp_rs_dispatch             = SPLIT_RS_DISPATCH ? i_fp_rs_dispatch : i_rs_dispatch;
    fp_rs_dispatch.valid       = fp_rs_dispatch_valid;
    fp_rs_dispatch.rm          = resolve_dispatch_rm(fp_rs_dispatch.rm);

    fp_rs_dispatch_to_rs       = fp_dispatch_pending;
    fp_rs_dispatch_to_rs.valid = fp_dispatch_dequeue;

    // The pending packet can dequeue on the same edge as its registered
    // done-repair response.  Present a repaired combinational view to the RS
    // on that edge; the sequential pending update below remains necessary
    // when recovery/back-pressure holds the packet for longer.
    if (fp_dispatch_pending_valid && !fp_dispatch_pending.src1_ready) begin
      if (cdb_bus_qualified.valid && fp_dispatch_pending.src1_tag == cdb_bus_qualified.tag) begin
        fp_rs_dispatch_to_rs.src1_ready = 1'b1;
        fp_rs_dispatch_to_rs.src1_value = cdb_bus_qualified.value;
      end else if (cdb_bus_2_qualified.valid &&
                   fp_dispatch_pending.src1_tag == cdb_bus_2_qualified.tag) begin
        fp_rs_dispatch_to_rs.src1_ready = 1'b1;
        fp_rs_dispatch_to_rs.src1_value = cdb_bus_2_qualified.value;
      end else if (wrapper_done_repair_match(fp_dispatch_pending.src1_tag)) begin
        fp_rs_dispatch_to_rs.src1_ready = 1'b1;
        fp_rs_dispatch_to_rs.src1_value = wrapper_done_repair_value(fp_dispatch_pending.src1_tag);
      end
    end
    if (fp_dispatch_pending_valid && !fp_dispatch_pending.src2_ready) begin
      if (cdb_bus_qualified.valid && fp_dispatch_pending.src2_tag == cdb_bus_qualified.tag) begin
        fp_rs_dispatch_to_rs.src2_ready = 1'b1;
        fp_rs_dispatch_to_rs.src2_value = cdb_bus_qualified.value;
      end else if (cdb_bus_2_qualified.valid &&
                   fp_dispatch_pending.src2_tag == cdb_bus_2_qualified.tag) begin
        fp_rs_dispatch_to_rs.src2_ready = 1'b1;
        fp_rs_dispatch_to_rs.src2_value = cdb_bus_2_qualified.value;
      end else if (wrapper_done_repair_match(fp_dispatch_pending.src2_tag)) begin
        fp_rs_dispatch_to_rs.src2_ready = 1'b1;
        fp_rs_dispatch_to_rs.src2_value = wrapper_done_repair_value(fp_dispatch_pending.src2_tag);
      end
    end
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

  always_ff @(posedge i_clk) begin
    if (fp_rs_dispatch.valid && fp_dispatch_slot_available &&
        !speculative_flush_all && !speculative_flush_en) begin
      // Capture the raw FP dispatch packet.  Renamed operands that just
      // completed are repaired on the next cycle by the existing
      // sequential pending update, or by the repaired dequeue view above
      // when this pending entry immediately drains. Keeping repair out of
      // this capture path avoids routing RAT tag lookup into the 64-bit FP
      // operand value flops.
      fp_dispatch_pending <= fp_rs_dispatch;
    end else if (fp_dispatch_pending_valid &&
                 (cdb_bus_qualified.valid || cdb_bus_2_qualified.valid || done_repair_valid_1 ||
                  done_repair_valid_2)) begin
      if (!fp_dispatch_pending.src1_ready && cdb_bus_qualified.valid &&
          fp_dispatch_pending.src1_tag == cdb_bus_qualified.tag) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= cdb_bus_qualified.value;
      end else if (!fp_dispatch_pending.src1_ready && cdb_bus_2_qualified.valid &&
          fp_dispatch_pending.src1_tag == cdb_bus_2_qualified.tag) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= cdb_bus_2_qualified.value;
      end else if (!fp_dispatch_pending.src1_ready && wrapper_done_repair_match(
              fp_dispatch_pending.src1_tag
          )) begin
        fp_dispatch_pending.src1_ready <= 1'b1;
        fp_dispatch_pending.src1_value <= wrapper_done_repair_value(fp_dispatch_pending.src1_tag);
      end

      if (!fp_dispatch_pending.src2_ready && cdb_bus_qualified.valid &&
          fp_dispatch_pending.src2_tag == cdb_bus_qualified.tag) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= cdb_bus_qualified.value;
      end else if (!fp_dispatch_pending.src2_ready && cdb_bus_2_qualified.valid &&
          fp_dispatch_pending.src2_tag == cdb_bus_2_qualified.tag) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= cdb_bus_2_qualified.value;
      end else if (!fp_dispatch_pending.src2_ready && wrapper_done_repair_match(
              fp_dispatch_pending.src2_tag
          )) begin
        fp_dispatch_pending.src2_ready <= 1'b1;
        fp_dispatch_pending.src2_value <= wrapper_done_repair_value(fp_dispatch_pending.src2_tag);
      end
    end
  end

  // Slot-2 FP dispatch is permanently held off by slot2_fp_compute_serialized
  // in dispatch.sv — fp_rs_dispatch_fire_2 is always 0.  Hard-zero the entire
  // slot-2 packet to the FP RS so Vivado does NOT trace the dispatch unit's
  // slot-2 bypass cone (RAT tag → ROB-done bypass → bypass mux) into the FP
  // RS rs_src*_value FF D inputs.  This dead-but-wired combinational path
  // was the 14-15 LUT-level critical path (~76% routing) hitting WNS at the
  // FP RAT lookup.  Coremark uses no FP, and slot-2 FP dispatch is dormant,
  // so suppressing the wires is functionally a no-op.
  riscv_pkg::rs_dispatch_t fp_rs_dispatch_to_rs_2;
  assign fp_rs_dispatch_to_rs_2 = '0;

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth),
      .HAS_SRC3(1'b0),
      // Repair is completed in the pending packet before insertion; keep it
      // out of the resident issue/stage2 source-value cone.
      .ISSUE_REPAIR_BYPASS(1'b0)
  ) u_fp_rs (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_dispatch                 (fp_rs_dispatch_to_rs),
      .i_dispatch_2               (fp_rs_dispatch_to_rs_2),
      // FP-family RSes have slot-2 dispatch held off (see slot2_fp_compute_serialized
      // in dispatch.sv), so dispatch_fire_2 is always 0 and alloc_idx_2 never
      // chooses a real commit target.  i_intent_1 is wired anyway for symmetry
      // — there is no alternate "always free_idx" code path.
      .i_intent_1                 (fp_rs_intent_1),
      .o_full                     (fp_rs_full_raw),
      .o_full_for_2               (fp_rs_full_for_2_raw),
      .i_cdb                      (cdb_bus_qualified),
      .i_cdb_2                    (cdb_bus_2_qualified),
      .i_issue_cdb_valid          (cdb_bus_qualified.valid),
      .i_issue_cdb_tag            (cdb_bus_qualified.tag),
      .i_issue_cdb_2_valid        (cdb_bus_2_qualified.valid),
      .i_issue_cdb_2_tag          (cdb_bus_2_qualified.tag),
      // FP operands are repaired while in fp_dispatch_pending, including a
      // response coincident with dequeue.  Once resident, normal CDB snooping
      // suffices; disconnect the all-entry repair-tag CAM.
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
      .o_issue_writes_cdb_hint    (),
      .o_branch_predicate_tag     (),
      .o_issue_2                  (),
      .i_fu_ready_2               (1'b0),
      .o_issue_writes_cdb_hint_2  (),
      .o_next_issue_valid         (),
      .o_next_issue_is_sc         (),                           // unused — no SC ops in FP_RS
      .o_next_issue_needs_lq      (),
      .o_pre_issue_rob_tag        (),
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

  // ---------------------------------------------------------------------------
  // FMUL_RS (depth 4): FP multiply/FMA (3 sources)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch;
  always_comb begin
    fmul_rs_dispatch             = SPLIT_RS_DISPATCH ? i_fmul_rs_dispatch : i_rs_dispatch;
    fmul_rs_dispatch.valid       = fmul_rs_dispatch_valid;
    fmul_rs_dispatch.rm          = resolve_dispatch_rm(fmul_rs_dispatch.rm);

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

  // Slot-2 FMUL is permanently held off by slot2_fp_compute_serialized.
  // Hard-zero the slot-2 packet so Vivado cuts the dead combinational cone
  // from RAT/ROB-bypass into u_fmul_rs/rs_src*_value/D — same rationale as
  // fp_rs_dispatch_to_rs_2 above.
  riscv_pkg::rs_dispatch_t fmul_rs_dispatch_to_rs_2;
  assign fmul_rs_dispatch_to_rs_2 = '0;

  reservation_station #(
      .DEPTH(riscv_pkg::FmulRsDepth),
      .HAS_SRC3(1'b1),
      .ISSUE_REPAIR_BYPASS(1'b0)
  ) u_fmul_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(fmul_rs_dispatch_to_rs),
      .i_dispatch_2(fmul_rs_dispatch_to_rs_2),
      .i_intent_1(fmul_rs_intent_1),
      .o_full(fmul_rs_full_raw),
      .o_full_for_2(fmul_rs_full_for_2_raw),
      .i_cdb(cdb_bus_qualified),
      .i_cdb_2(cdb_bus_2_fmul_qualified),
      .i_issue_cdb_valid(cdb_bus_qualified.valid),
      .i_issue_cdb_tag(cdb_bus_qualified.tag),
      .i_issue_cdb_2_valid(cdb_bus_2_fmul_qualified.valid),
      .i_issue_cdb_2_tag(cdb_bus_2_fmul_qualified.tag),
      // FMUL rereads ROB done/value by the buffered packet's own tags on
      // dequeue, so resident all-entry repair snooping is redundant.
      .i_repair_valid_1(1'b0),
      .i_repair_tag_1('0),
      .i_repair_value_1('0),
      .i_repair_valid_2(1'b0),
      .i_repair_tag_2('0),
      .i_repair_value_2('0),
      .i_repair_valid_3(1'b0),
      .i_repair_tag_3('0),
      .i_repair_value_3('0),
      .i_repair_valid_4(1'b0),
      .i_repair_tag_4('0),
      .i_repair_value_4('0),
      .i_repair_valid_5(1'b0),
      .i_repair_tag_5('0),
      .i_repair_value_5('0),
      .i_repair_valid_6(1'b0),
      .i_repair_tag_6('0),
      .i_repair_value_6('0),
      .o_issue(fmul_rs_issue_raw),
      .i_fu_ready(fmul_rs_fu_ready),
      .o_issue_writes_cdb_hint(),
      .o_branch_predicate_tag(),
      .o_issue_2(),
      .i_fu_ready_2(1'b0),
      .o_issue_writes_cdb_hint_2(),
      .o_next_issue_valid(),
      .o_next_issue_is_sc(),  // unused — no SC ops in FMUL_RS
      .o_next_issue_needs_lq(),
      .o_pre_issue_rob_tag(),
      .o_pre_issue_needs_lq(),
      .i_flush_en(speculative_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all(speculative_flush_all),
      .o_empty(fmul_rs_empty_raw),
      .o_count(fmul_rs_count_raw),
      .i_head_query_tag(head_tag),
      .o_head_query_in_rs(),
      .o_head_query_rs_ready(),
      .o_head_query_in_stage2(),
      .o_perf_two_ready_one_issued()
  );

  // ---------------------------------------------------------------------------
  // FDIV_RS (depth 2): FP divide/sqrt (long latency)
  // ---------------------------------------------------------------------------
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch;
  always_comb begin
    fdiv_rs_dispatch             = SPLIT_RS_DISPATCH ? i_fdiv_rs_dispatch : i_rs_dispatch;
    fdiv_rs_dispatch.valid       = fdiv_rs_dispatch_valid;
    fdiv_rs_dispatch.rm          = resolve_dispatch_rm(fdiv_rs_dispatch.rm);

    fdiv_rs_dispatch_to_rs       = fdiv_dispatch_pending;
    fdiv_rs_dispatch_to_rs.valid = fdiv_dispatch_dequeue;

    // Preserve a response that coincides with dequeue before disconnecting
    // the resident FDIV RS from the global repair-tag CAM.
    if (fdiv_dispatch_pending_valid && !fdiv_dispatch_pending.src1_ready) begin
      if (cdb_bus_qualified.valid && fdiv_dispatch_pending.src1_tag == cdb_bus_qualified.tag) begin
        fdiv_rs_dispatch_to_rs.src1_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src1_value = cdb_bus_qualified.value;
      end else if (cdb_bus_2_qualified.valid &&
                   fdiv_dispatch_pending.src1_tag == cdb_bus_2_qualified.tag) begin
        fdiv_rs_dispatch_to_rs.src1_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src1_value = cdb_bus_2_qualified.value;
      end else if (wrapper_done_repair_match(fdiv_dispatch_pending.src1_tag)) begin
        fdiv_rs_dispatch_to_rs.src1_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src1_value =
            wrapper_done_repair_value(fdiv_dispatch_pending.src1_tag);
      end
    end
    if (fdiv_dispatch_pending_valid && !fdiv_dispatch_pending.src2_ready) begin
      if (cdb_bus_qualified.valid && fdiv_dispatch_pending.src2_tag == cdb_bus_qualified.tag) begin
        fdiv_rs_dispatch_to_rs.src2_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src2_value = cdb_bus_qualified.value;
      end else if (cdb_bus_2_qualified.valid &&
                   fdiv_dispatch_pending.src2_tag == cdb_bus_2_qualified.tag) begin
        fdiv_rs_dispatch_to_rs.src2_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src2_value = cdb_bus_2_qualified.value;
      end else if (wrapper_done_repair_match(fdiv_dispatch_pending.src2_tag)) begin
        fdiv_rs_dispatch_to_rs.src2_ready = 1'b1;
        fdiv_rs_dispatch_to_rs.src2_value =
            wrapper_done_repair_value(fdiv_dispatch_pending.src2_tag);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fdiv_dispatch_pending_valid <= 1'b0;
    end else if (fdiv_dispatch_pending_flushed) begin
      fdiv_dispatch_pending_valid <= 1'b0;
    end else if (fdiv_rs_dispatch.valid && fdiv_dispatch_slot_available &&
                 !speculative_flush_all && !speculative_flush_en) begin
      fdiv_dispatch_pending_valid <= 1'b1;
    end else if (fdiv_dispatch_dequeue) begin
      fdiv_dispatch_pending_valid <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (fdiv_rs_dispatch.valid && fdiv_dispatch_slot_available &&
        !speculative_flush_all && !speculative_flush_en) begin
      // Same timing tradeoff as FP_RS pending capture: let the existing
      // repair path fill just-completed operands after the packet is parked.
      fdiv_dispatch_pending <= fdiv_rs_dispatch;
    end else if (fdiv_dispatch_pending_valid &&
                 (cdb_bus_qualified.valid || cdb_bus_2_qualified.valid || done_repair_valid_1 ||
                  done_repair_valid_2)) begin
      if (!fdiv_dispatch_pending.src1_ready && cdb_bus_qualified.valid &&
          fdiv_dispatch_pending.src1_tag == cdb_bus_qualified.tag) begin
        fdiv_dispatch_pending.src1_ready <= 1'b1;
        fdiv_dispatch_pending.src1_value <= cdb_bus_qualified.value;
      end else if (!fdiv_dispatch_pending.src1_ready && cdb_bus_2_qualified.valid &&
          fdiv_dispatch_pending.src1_tag == cdb_bus_2_qualified.tag) begin
        fdiv_dispatch_pending.src1_ready <= 1'b1;
        fdiv_dispatch_pending.src1_value <= cdb_bus_2_qualified.value;
      end else if (!fdiv_dispatch_pending.src1_ready && wrapper_done_repair_match(
              fdiv_dispatch_pending.src1_tag
          )) begin
        fdiv_dispatch_pending.src1_ready <= 1'b1;
        fdiv_dispatch_pending.src1_value <= wrapper_done_repair_value(
            fdiv_dispatch_pending.src1_tag
        );
      end

      if (!fdiv_dispatch_pending.src2_ready && cdb_bus_qualified.valid &&
          fdiv_dispatch_pending.src2_tag == cdb_bus_qualified.tag) begin
        fdiv_dispatch_pending.src2_ready <= 1'b1;
        fdiv_dispatch_pending.src2_value <= cdb_bus_qualified.value;
      end else if (!fdiv_dispatch_pending.src2_ready && cdb_bus_2_qualified.valid &&
          fdiv_dispatch_pending.src2_tag == cdb_bus_2_qualified.tag) begin
        fdiv_dispatch_pending.src2_ready <= 1'b1;
        fdiv_dispatch_pending.src2_value <= cdb_bus_2_qualified.value;
      end else if (!fdiv_dispatch_pending.src2_ready && wrapper_done_repair_match(
              fdiv_dispatch_pending.src2_tag
          )) begin
        fdiv_dispatch_pending.src2_ready <= 1'b1;
        fdiv_dispatch_pending.src2_value <= wrapper_done_repair_value(
            fdiv_dispatch_pending.src2_tag
        );
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The production dispatch contract registers a slot-1 packet's source-1/2
  // repair queries onto channels 1/2 for exactly the following cycle.  Keep a
  // simulation-only phase bit so held packets are not compared against later,
  // unrelated dispatch queries.  These registers do not exist in synthesis or
  // formal builds.
  logic fp_pending_repair_capture_q;
  logic fdiv_pending_repair_capture_q;

  function automatic logic pending_cdb_match(
      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag);
    begin
      pending_cdb_match =
          (cdb_bus_qualified.valid && tag == cdb_bus_qualified.tag) ||
          (cdb_bus_2_qualified.valid && tag == cdb_bus_2_qualified.tag);
    end
  endfunction

  function automatic logic pending_omitted_done_repair_match(
      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag);
    begin
      pending_omitted_done_repair_match =
          (done_repair_valid_3 && tag == i_bypass_tag_3) ||
          (done_repair_valid_4 && tag == i_bypass_tag_4) ||
          (done_repair_valid_5 && tag == i_bypass_tag_5) ||
          (done_repair_valid_6 && tag == i_bypass_tag_6);
    end
  endfunction

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fp_pending_repair_capture_q   <= 1'b0;
      fdiv_pending_repair_capture_q <= 1'b0;
    end else begin
      fp_pending_repair_capture_q <=
          ENABLE_DISPATCH_DONE_REPAIR && fp_rs_dispatch.valid && fp_dispatch_slot_available &&
          !speculative_flush_all && !speculative_flush_en;
      fdiv_pending_repair_capture_q <=
          ENABLE_DISPATCH_DONE_REPAIR && fdiv_rs_dispatch.valid && fdiv_dispatch_slot_available &&
          !speculative_flush_all && !speculative_flush_en;

      if (fp_pending_repair_capture_q) begin
        p_fp_pending_repair_packet_phase : assert (fp_dispatch_pending_valid);
        p_fp_pending_repair_channel1_phase :
        assert (!i_bypass_valid_1 || i_bypass_tag_1 == fp_dispatch_pending.src1_tag);
        p_fp_pending_repair_channel2_phase :
        assert (!i_bypass_valid_2 || i_bypass_tag_2 == fp_dispatch_pending.src2_tag);

        if (!fp_dispatch_pending.src1_ready) begin
          p_fp_pending_src1_no_omitted_only_repair :
          assert (!pending_omitted_done_repair_match(
              fp_dispatch_pending.src1_tag
          ) || wrapper_done_repair_match(
              fp_dispatch_pending.src1_tag
          ) || pending_cdb_match(
              fp_dispatch_pending.src1_tag
          ));
        end
        if (!fp_dispatch_pending.src2_ready) begin
          p_fp_pending_src2_no_omitted_only_repair :
          assert (!pending_omitted_done_repair_match(
              fp_dispatch_pending.src2_tag
          ) || wrapper_done_repair_match(
              fp_dispatch_pending.src2_tag
          ) || pending_cdb_match(
              fp_dispatch_pending.src2_tag
          ));
        end
      end

      if (fdiv_pending_repair_capture_q) begin
        p_fdiv_pending_repair_packet_phase : assert (fdiv_dispatch_pending_valid);
        p_fdiv_pending_repair_channel1_phase :
        assert (!i_bypass_valid_1 || i_bypass_tag_1 == fdiv_dispatch_pending.src1_tag);
        p_fdiv_pending_repair_channel2_phase :
        assert (!i_bypass_valid_2 || i_bypass_tag_2 == fdiv_dispatch_pending.src2_tag);

        if (!fdiv_dispatch_pending.src1_ready) begin
          p_fdiv_pending_src1_no_omitted_only_repair :
          assert (!pending_omitted_done_repair_match(
              fdiv_dispatch_pending.src1_tag
          ) || wrapper_done_repair_match(
              fdiv_dispatch_pending.src1_tag
          ) || pending_cdb_match(
              fdiv_dispatch_pending.src1_tag
          ));
        end
        if (!fdiv_dispatch_pending.src2_ready) begin
          p_fdiv_pending_src2_no_omitted_only_repair :
          assert (!pending_omitted_done_repair_match(
              fdiv_dispatch_pending.src2_tag
          ) || wrapper_done_repair_match(
              fdiv_dispatch_pending.src2_tag
          ) || pending_cdb_match(
              fdiv_dispatch_pending.src2_tag
          ));
        end
      end
    end
  end
`endif
`endif

  // Slot-2 FDIV is permanently held off by slot2_fp_compute_serialized.
  // Hard-zero the slot-2 packet so Vivado cuts the dead combinational cone
  // from RAT/ROB-bypass into u_fdiv_rs/rs_src*_value/D — same rationale as
  // fp_rs_dispatch_to_rs_2 above.
  riscv_pkg::rs_dispatch_t fdiv_rs_dispatch_to_rs_2;
  assign fdiv_rs_dispatch_to_rs_2 = '0;

  reservation_station #(
      .DEPTH(riscv_pkg::FdivRsDepth),
      .HAS_SRC3(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0)
  ) u_fdiv_rs (
      .i_clk                      (i_clk),
      .i_rst_n                    (i_rst_n),
      .i_dispatch                 (fdiv_rs_dispatch_to_rs),
      .i_dispatch_2               (fdiv_rs_dispatch_to_rs_2),
      .i_intent_1                 (fdiv_rs_intent_1),
      .o_full                     (fdiv_rs_full_raw),
      .o_full_for_2               (fdiv_rs_full_for_2_raw),
      .i_cdb                      (cdb_bus_qualified),
      .i_cdb_2                    (cdb_bus_2_qualified),
      .i_issue_cdb_valid          (cdb_bus_qualified.valid),
      .i_issue_cdb_tag            (cdb_bus_qualified.tag),
      .i_issue_cdb_2_valid        (cdb_bus_2_qualified.valid),
      .i_issue_cdb_2_tag          (cdb_bus_2_qualified.tag),
      // FDIV operands are repaired in the pending packet and in its dequeue
      // view; a resident entry only needs the live CDB lanes.
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
      .o_issue                    (fdiv_rs_issue_raw),
      .i_fu_ready                 (fdiv_rs_fu_ready),
      .o_issue_writes_cdb_hint    (),
      .o_branch_predicate_tag     (),
      .o_issue_2                  (),
      .i_fu_ready_2               (1'b0),
      .o_issue_writes_cdb_hint_2  (),
      .o_next_issue_valid         (),
      .o_next_issue_is_sc         (),                           // unused — no SC ops in FDIV_RS
      .o_next_issue_needs_lq      (),
      .o_pre_issue_rob_tag        (),
      .o_pre_issue_needs_lq       (),
      .i_flush_en                 (speculative_flush_en),
      .i_flush_tag                (i_flush_tag),
      .i_rob_head_tag             (head_tag),
      .i_flush_all                (speculative_flush_all),
      .o_empty                    (fdiv_rs_empty_raw),
      .o_count                    (fdiv_rs_count_raw),
      .i_head_query_tag           (head_tag),
      .o_head_query_in_rs         (),
      .o_head_query_rs_ready      (),
      .o_head_query_in_stage2     (),
      .o_perf_two_ready_one_issued()
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
  fu_cdb_adapter #(
      // A pending ALU adapter deasserts int_rs_fu_ready, so the shim-valid
      // and pending states are mutually exclusive (asserted below).  Keep the
      // grant-refill state transition, but remove pending/grant from the wide
      // held-result write enable.
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
  // ALU2 Shim + CDB Adapter: second integer pipe (plain ALU ops only —
  // branch-class entries are steered to port 0 inside the INT RS, so this
  // pipe never resolves a branch and needs no branch_resolution tap).
  // ===========================================================================
  int_alu_shim u_alu2_shim (
      .i_clk                  (i_clk),
      .i_rst_n                (i_rst_n),
      .i_rs_issue             (int_rs_issue_2_w),
      .i_issue_writes_cdb_hint(int_rs_issue_writes_cdb_hint_2),
      .i_csr_read_data        (i_csr_read_data),
      .o_fu_complete          (alu2_shim_out),
      .o_fu_busy              (alu2_fu_busy)
  );

  fu_cdb_adapter #(
      // A pending ALU2 adapter deasserts int_rs_fu_ready_2, so the shim-valid
      // and pending states are mutually exclusive (asserted below).  Keep the
      // grant-refill state transition, but remove pending/grant from the wide
      // held-result write enable.
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
  // These integration invariants are the contracts that permit both ALU
  // adapters' simplified held-result write enables.  Each matching INT-RS
  // ready input is gated by adapter-pending, and the RS qualifies its stage-2
  // issue valid with that ready input.
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
      .i_mul_accepted   (mul_result_accepted),
      .i_div_accepted   (div_result_accepted)
  );

  // ===========================================================================
  // MUL CDB Adapter: result holding register → CDB arbiter slot 1
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
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
  // DIV CDB Adapter: result holding register → CDB arbiter slot 2
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
  // Helper to derive an lq_alloc_req from a per-slot mem_rs_dispatch packet.
  // Same logic for slot-1 and slot-2; the only difference is which packet
  // and which routed valid signal feeds in.
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
  // AGU output is canonicalized to the physical address space (masks bits
  // [63:32] - plan decision D3) so region
  // decodes, CAM compares, and mtval capture all see sub-4-GiB addresses.
  assign lq_effective_addr = riscv_pkg::canonical_paddr(
      o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm
  );

  // MMIO detection: the 01 address quadrant [0x4000_0000, 0x8000_0000).
  // The cached (DDR) region is the 10 quadrant [0x8000_0000, 0xC000_0000)
  // and must NOT be flagged MMIO -- the old ">= MmioBase" shortcut predates
  // the cached tier (when nothing was mapped above MMIO).
  localparam logic [riscv_pkg::XLEN-1:0] MmioBase = 64'h4000_0000;
  logic lq_addr_is_mmio;
  assign lq_addr_is_mmio = (lq_effective_addr[31:30] == 2'b01);

  riscv_pkg::lq_addr_update_t lq_addr_update;
  always_comb begin
    lq_addr_update.valid   = mem_rs_next_issue_valid && mem_rs_next_issue_needs_lq &&
                              mem_rs_fu_ready_base;
    lq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    lq_addr_update.address = lq_effective_addr;
    lq_addr_update.is_mmio = lq_addr_is_mmio;
    lq_addr_update.amo_rs2 = o_mem_rs_issue.src2_value[riscv_pkg::XLEN-1:0];
  end

  // ===========================================================================
  // Load Queue Instance
  // ===========================================================================
  load_queue #(
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

      // Address update (from MEM_RS issue)
      .i_addr_update(lq_addr_update),

      // Pre-issue look-ahead (from MEM_RS, 1 cycle before i_addr_update)
      .i_pre_issue_rob_tag (mem_rs_pre_issue_rob_tag),
      .i_pre_issue_needs_lq(mem_rs_pre_issue_needs_lq),

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
      .i_mem_read_data(i_lq_mem_read_data),
      .i_mem_read_valid(i_lq_mem_read_valid),
      // Keep the exact router Q separate from the composite busy expression:
      // full-flush bookkeeping uses it to distinguish a canceled staged read
      // from an accepted read whose stale response is still owed.
      .i_mem_request_pending(i_lq_mem_request_pending),
      // AMO writes share the same external data-memory port as load reads.
      // Treat them as bus-busy so the LQ cannot issue a younger load or
      // take a stale L0-cache fast path in the AMO write-completion cycle.
      // A slow-tier (cached) store in flight is also bus-busy: the router's
      // queued-load register holds exactly ONE blocked load, so launches
      // during the (arbitrarily long) handshake write flight must be held
      // here -- with only the fire-cycle skew load able to queue.
      .i_mem_bus_busy  (o_sq_mem_write_en || o_amo_mem_write_en || i_backend_recovery_hold ||
                        i_slow_write_inflight || i_lq_mem_request_pending),

      // CDB result (to MEM adapter; back-pressured when SC or store uses the slot)
      .o_fu_complete(lq_fu_complete),
      // Deliberately-retained dead hint; see the i_adapter_result_pending port
      // comment in load_queue.sv (removing this pair regresses closed x3
      // post-opt timing).
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
      .i_sq_committed_empty(sq_committed_empty),
      .i_trap_misaligned_accesses(i_trap_misaligned_accesses),

      // AMO memory write interface
      .o_amo_mem_write_en(o_amo_mem_write_en),
      .o_amo_mem_write_addr(o_amo_mem_write_addr),
      .o_amo_mem_write_data(o_amo_mem_write_data),
      .o_amo_mem_write_is_dword(o_amo_mem_write_is_dword),
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
      .o_head_load_bb_issued           (lq_head_load_bb_issued),
      .o_head_load_bb_bus_busy         (lq_head_load_bb_bus_busy),
      .o_head_load_bb_amo              (lq_head_load_bb_amo),
      .o_head_load_bb_sq_wait          (lq_head_load_bb_sq_wait),
      .o_head_load_bb_staging          (lq_head_load_bb_staging),
      .o_head_load_bbs_other_in_staging(lq_head_load_bbs_other_in_staging),
      .o_head_load_bbs_launch_gated    (lq_head_load_bbs_launch_gated),
      .o_head_load_bbs_slow_outstanding(lq_head_load_bbs_slow_outstanding),
      .o_head_load_bbs_capture_gap     (lq_head_load_bbs_capture_gap)
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
  // Helper to derive an sq_alloc_req from a per-slot mem_rs_dispatch packet.
  // Address is computed in a pipelined stage (see early_addr_update below) to
  // break the critical RAT → dispatch → XLEN-wide adder → SQ path, so it stays
  // empty at alloc time for both slots.
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
  // Extracted to store_addr/sq_early_addr_pipeline.sv (pure boundary move).
  // Breaks the RAT -> ROB bypass -> dispatch value -> CARRY8 adder -> SQ critical
  // path by deferring the XLEN-wide addition by one cycle.  Dual-ported (slot-1 /
  // slot-2): each slot has its own register set, adders, and SQ update packet.
  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  riscv_pkg::sq_addr_update_t sq_early_addr_update_2;
  sq_early_addr_pipeline sq_early_addr_pipeline_inst (
      .i_clk                   (i_clk),
      .i_rst_n                 (i_rst_n),
      .i_flush_all             (i_flush_all),
      .i_flush_en              (i_flush_en),
      // Live CDB lanes (registered) for the persistent-repair snoop, and the
      // MEM_RS issue tap that retires candidates whose store is issuing.
      .i_cdb                   (sq_cdb_bus),
      .i_cdb_2                 (sq_cdb_bus_2),
      .i_mem_rs_issue_valid    (o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq),
      .i_mem_rs_issue_rob_tag  (o_mem_rs_issue.rob_tag),
      .i_done_repair_valid_1   (done_repair_valid_1),
      .i_done_repair_valid_2   (done_repair_valid_2),
      .i_done_repair_valid_3   (done_repair_valid_3),
      .i_done_repair_valid_4   (done_repair_valid_4),
      .i_done_repair_valid_5   (done_repair_valid_5),
      .i_done_repair_valid_6   (done_repair_valid_6),
      .i_bypass_tag_1          (i_bypass_tag_1),
      .i_bypass_tag_2          (i_bypass_tag_2),
      .i_bypass_tag_3          (i_bypass_tag_3),
      .i_bypass_tag_4          (i_bypass_tag_4),
      .i_bypass_tag_5          (i_bypass_tag_5),
      .i_bypass_tag_6          (i_bypass_tag_6),
      .i_bypass_value_1        (bypass_value_1),
      .i_bypass_value_2        (bypass_value_2),
      .i_bypass_value_3        (bypass_value_3),
      .i_bypass_value_4        (bypass_value_4),
      .i_bypass_value_5        (bypass_value_5),
      .i_bypass_value_6        (bypass_value_6),
      .i_mem_rs_dispatch       (mem_rs_dispatch),
      .i_mem_rs_dispatch_2     (mem_rs_dispatch_2),
      .i_sq_alloc_req          (sq_alloc_req),
      .i_sq_alloc_req_2        (sq_alloc_req_2),
      .i_sq_full               (o_sq_full),
      .i_sq_full_for_2         (o_sq_full_for_2),
      .o_sq_early_addr_update  (sq_early_addr_update),
      .o_sq_early_addr_update_2(sq_early_addr_update_2)
  );

  // ===========================================================================
  // Store Queue: Address + Data Update from MEM_RS Issue
  // ===========================================================================
  // Effective address: base (src1) + immediate (declared above near SC pending).
  // Canonicalized like the LQ AGU output above (plan decision D3).
  assign sq_effective_addr = riscv_pkg::canonical_paddr(
      o_mem_rs_issue.src1_value[riscv_pkg::XLEN-1:0] + o_mem_rs_issue.imm
  );

  logic sq_addr_is_mmio;
  // MMIO quadrant test; see lq_addr_is_mmio above.
  assign sq_addr_is_mmio = (sq_effective_addr[31:30] == 2'b01);

  riscv_pkg::sq_addr_update_t sq_addr_update;
  always_comb begin
    sq_addr_update.valid   = o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
                             !store_misalign_issue;
    sq_addr_update.rob_tag = o_mem_rs_issue.rob_tag;
    sq_addr_update.address = sq_effective_addr;
    sq_addr_update.is_mmio = sq_addr_is_mmio;
  end

  // Data update: store data from src2_value
  riscv_pkg::sq_data_update_t sq_data_update;
  always_comb begin
    sq_data_update.valid   = o_mem_rs_issue.valid && o_mem_rs_issue.mem_needs_sq &&
                             !store_misalign_issue;
    sq_data_update.rob_tag = o_mem_rs_issue.rob_tag;
    sq_data_update.data = o_mem_rs_issue.src2_value;
  end

  // ===========================================================================
  // Store Queue Instance
  // ===========================================================================
  store_queue #(
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
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

      // Early address update (pipelined dispatch-time base+imm).
      // Dual-ported — slot-1 and slot-2 each emit their own packet.  CAM-by-
      // rob_tag in SQ targets distinct entries (different rob_tags), so no NBA
      // collision across the two updates.
      .i_early_addr_update  (sq_early_addr_update),
      .i_early_addr_update_2(sq_early_addr_update_2),

      // Address update (from MEM_RS issue)
      .i_addr_update(sq_addr_update),

      // Data update (from MEM_RS issue)
      .i_data_update(sq_data_update),

      // Commit (pipelined — breaks ROB → SQ critical path)
      .i_commit_valid  (sq_commit_valid),
      .i_commit_rob_tag(commit_q_tag),

      // Widen-commit slot 2 retire, pipelined the same way.  commit_q_2_tag
      // is the head+1 tag when 2-wide commit fires and zero otherwise.
      .i_commit_valid_2  (sq_commit_valid_2),
      .i_commit_rob_tag_2(commit_q_2_tag),

      // Trap-cone-free commit pulses for the forwarding probe's scan only
      // (see the sq_commit_valid_scan definition above for the contract).
      .i_commit_valid_scan  (sq_commit_valid_scan),
      .i_commit_valid_scan_2(sq_commit_valid_scan_2),

      // Same-cycle commit guard (combinational, for flush race protection).
      // Use the narrow raw ROB pulse instead of the wide commit bus so the
      // SQ flush-exemption path does not inherit full commit payload logic.
      .i_commit_valid_comb  (commit_store_like_raw),
      .i_commit_rob_tag_comb(head_tag),

      // Slot 2 has the same raw commit race as slot 1 for full-trap drains:
      // commit_bus_2_q_valid is still one cycle away from SQ, so a timer IRQ
      // must not observe committed-empty and full-flush the entry before SQ
      // sees the registered commit.
      .i_commit_valid_comb_2  (commit_2_store_like_raw),
      .i_commit_rob_tag_comb_2(commit_bus_2.tag),

      // Store-to-load forwarding (from LQ)
      .i_sq_check_valid          (sq_check_valid),
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
      .o_empty          (sq_empty_exact),
      .o_dispatch_empty (o_sq_empty),
      .o_committed_empty(sq_committed_empty),
      .o_count          (sq_count_exact),
      .o_dispatch_count (o_sq_count)
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
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .REGISTER_OUTPUT(1'b1)
  ) u_fp_add_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_add_shim_out),
      .o_fu_complete   (fp_add_adapter_to_arbiter),
      .o_held_value    (),
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
  // Deep-pipeline shim: consumes the registered flush snapshot (see the
  // fp_shim_flush_*_q block) — per-entry squash marking lands one cycle
  // after the live pulse with pulse-cycle tag/head references.
  fp_mul_shim u_fp_mul_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fmul_rs_issue_w),
      .o_fu_complete (fp_mul_shim_out),
      .o_fu_busy     (fp_mul_busy),
      .i_flush       (fp_shim_flush_all_q),
      .i_flush_en    (fp_shim_flush_en_q),
      .i_flush_tag   (fp_shim_flush_tag_q),
      .i_rob_head_tag(fp_shim_flush_head_q),
      .i_mul_accepted(fp_mul_result_accepted)
  );

  // ===========================================================================
  // FP Multiply CDB Adapter: result holding register → CDB arbiter slot 5
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .REGISTER_OUTPUT(1'b1)
  ) u_fp_mul_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_mul_shim_out),
      .o_fu_complete   (fp_mul_adapter_to_arbiter),
      .o_held_value    (),
      .i_grant         (o_cdb_grant[5]),
      .o_result_pending(fp_mul_adapter_result_pending),
      // Full-flush window extended one cycle: the shim's registered clear
      // lands on pulse+1, so a squashed completion pushed into the shim FIFO
      // on the pulse cycle is still presented during pulse+1 — the extended
      // window keeps it out of the holding register (REGISTER_OUTPUT means
      // it is never passed through combinationally).  Partial flush stays
      // live: the age compare is the pulse-cycle boundary guard.
      .i_flush         (speculative_flush_all || fp_shim_flush_all_q),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // FP Divide/Sqrt Shim: translate rs_issue_t → FPU div/sqrt → fu_complete_t
  // ===========================================================================
  // Deep-pipeline shim: registered flush snapshot, same contract as
  // u_fp_mul_shim above.
  fp_div_shim u_fp_div_shim (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .i_rs_issue    (fdiv_rs_issue_w),
      .o_fu_complete (fp_div_shim_out),
      .o_fu_busy     (fp_div_busy),
      .i_flush       (fp_shim_flush_all_q),
      .i_flush_en    (fp_shim_flush_en_q),
      .i_flush_tag   (fp_shim_flush_tag_q),
      .i_rob_head_tag(fp_shim_flush_head_q),
      .i_div_accepted(fp_div_result_accepted)
  );

  // ===========================================================================
  // FP Divide CDB Adapter: result holding register → CDB arbiter slot 6
  // ===========================================================================
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0),
      .REGISTER_OUTPUT(1'b1)
  ) u_fp_div_adapter (
      .i_clk           (i_clk),
      .i_rst_n         (i_rst_n),
      .i_fu_result     (fp_div_shim_out),
      .o_fu_complete   (fp_div_adapter_to_arbiter),
      .o_held_value    (),
      .i_grant         (o_cdb_grant[6]),
      .o_result_pending(fp_div_adapter_result_pending),
      // Full-flush window extended one cycle — same contract as
      // u_fp_mul_adapter above.
      .i_flush         (speculative_flush_all || fp_shim_flush_all_q),
      .i_flush_en      (speculative_flush_en),
      .i_flush_tag     (i_flush_tag),
      .i_rob_head_tag  (head_tag)
  );

  // ===========================================================================
  // Backend Profiling Counters
  // ===========================================================================
  // The 64 back-end profiling counters live in tomasulo_perf_counters.
  tomasulo_perf_counters tomasulo_perf_counters_inst (
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
      .i_fmul_rs_fu_ready(fmul_rs_fu_ready),
      .i_o_fmul_rs_empty(o_fmul_rs_empty),
      .i_fdiv_rs_fu_ready(fdiv_rs_fu_ready),
      .i_o_fdiv_rs_empty(o_fdiv_rs_empty),
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
      .i_o_fmul_rs_count(o_fmul_rs_count),
      .i_o_fdiv_rs_count(o_fdiv_rs_count),
      .i_lq_l0_hit(lq_l0_hit),
      .i_lq_l0_fill(lq_l0_fill),
      .i_lq_mem_outstanding(lq_mem_outstanding),
      .i_lq_head_load_addr_pending(lq_head_load_addr_pending),
      .i_lq_head_load_sq_disambig(lq_head_load_sq_disambig),
      .i_lq_head_load_bus_blocked(lq_head_load_bus_blocked),
      .i_lq_head_load_cdb_wait(lq_head_load_cdb_wait),
      .i_lq_head_load_post_lq(lq_head_load_post_lq),
      .i_lq_head_load_bb_issued(lq_head_load_bb_issued),
      .i_lq_head_load_bb_bus_busy(lq_head_load_bb_bus_busy),
      .i_lq_head_load_bb_amo(lq_head_load_bb_amo),
      .i_lq_head_load_bb_sq_wait(lq_head_load_bb_sq_wait),
      .i_lq_head_load_bb_staging(lq_head_load_bb_staging),
      .i_lq_head_load_bbs_other_in_staging(lq_head_load_bbs_other_in_staging),
      .i_lq_head_load_bbs_launch_gated(lq_head_load_bbs_launch_gated),
      .i_lq_head_load_bbs_slow_outstanding(lq_head_load_bbs_slow_outstanding),
      .i_lq_head_load_bbs_capture_gap(lq_head_load_bbs_capture_gap),
      .i_int_rs_head_in_rs(int_rs_head_in_rs),
      .i_int_rs_head_rs_ready(int_rs_head_rs_ready),
      .i_int_rs_head_in_stage2(int_rs_head_in_stage2),
      .i_perf_snapshot_capture(i_perf_snapshot_capture),
      .i_perf_counter_select(i_perf_counter_select),
      .o_perf_counter_data(o_perf_counter_data)
  );

`ifndef SYNTHESIS
`ifndef FORMAL
  // Integration bookkeeping invariant: the router can only raise pending for
  // a handoff the LQ already recorded as its sole response owner. Full-flush
  // cancellation relies on this correspondence to distinguish an unaccepted
  // staged request from genuine stale-response debt.
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

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // Assume/guarantee half of the router's one-entry conservation contract.
  // The router proves its held payload is conserved assuming no second live
  // request while its pending Q is set; this wrapper guarantees that producer
  // discipline for every value of the otherwise-unconstrained formal input.
  always_comb begin
    if (i_rst_n && i_lq_mem_request_pending) begin
      // The router is outside this standalone formal top. Constrain its input
      // to the same integration contract checked by the simulation tripwire.
      a_router_pending_has_lq_response_owner : assume (lq_mem_outstanding);
      p_router_pending_blocks_lq_handoff : assert (!o_lq_mem_read_en);
    end
  end

  // Prove the live/fallback split against the unchanged generic effective
  // packets.  These assertions discharge the cdb_arbiter interface contract;
  // that instance has its standalone contract assumptions disabled above.
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
  // Structural constraints (from rob_rat_wrapper)
  // -------------------------------------------------------------------------

  // No allocation during flush
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // i_flush_all_wb_mask is a flat recompute of i_flush_all, bit-identical by
  // construction (misprediction_flush_controller.o_flush_all_flat; asserted
  // there in simulation). Model the equality for the standalone formal top
  // so the commit-writeback mask cannot fire independently of flush_all.
  always_comb begin
    assume (i_flush_all_wb_mask == i_flush_all);
  end

  // No rename during full flush
  always_comb assume (!(i_rat_alloc_valid && i_flush_all));
  always_comb assume (!(i_rat_alloc_valid_2 && i_flush_all));

  // No rename during checkpoint restore
  always_comb assume (!(i_rat_alloc_valid && i_checkpoint_restore));
  always_comb assume (!(i_rat_alloc_valid_2 && i_checkpoint_restore));

  // Slot-2 RAT alloc can fire without slot-1 RAT alloc when slot-1 has no
  // destination (no formal assumption needed).

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
      // Slot 2 identity + subordination to slot 1: slot 2 can only be
      // valid when slot 1 is also valid (2-wide never fires alone).
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

      // Both registers sample the same retiring-FENCE.I predicate. The ROB's
      // global pulse uses its fast head-class replica; commit_bus_q carries
      // the bit-identical registered commit payload used as the low-fanout
      // early-recovery copy in cpu_ooo.
      p_registered_fence_copy_matches_flush : assert (commit_bus_q.is_fence_i == o_fence_i_flush);

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
      // cover depth is 6.  Covered by reservation_station.sby at depth 20.

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

      // SQ allocation
      cover_sq_alloc : cover (sq_alloc_req.valid);

`ifdef FORMAL_DEEP_COVER
      // Deep integration paths, intentionally kept out of the default
      // wrapper cover task because the LQ/SQ module targets already cover
      // the same events (load_queue.cover_mem_issue, SQ write covers) and
      // these chains dominate CI runtime: each needs the deepest unrolling
      // of the whole wrapper (the LQ read chain is dispatch -> LQ alloc ->
      // MEM RS issue -> SQ disambiguation -> launch, reachable only at
      // step 5 — a single SAT query that alone blew the runner's 40-minute
      // backstop while every other cover finishes by step 4 in ~2 minutes).
      cover_lq_mem_issue : cover (o_lq_mem_read_en);
      cover_sq_mem_write : cover (o_sq_mem_write_en);
`endif

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

  // ===========================================================================
  // Simulation-only: stale-CDB producer diagnostics.
  //
  // The ROB's own diagnostics (reorder_buffer.sv, drain-window section) report
  // deliveries to free entries but cannot name the producer — fu_type does not
  // cross the reorder_buffer_cdb_write_t boundary.  Here both registered CDB
  // lanes still carry it, so a delivery targeting a free ROB entry is logged
  // with the FU slot that produced it.  Any hit is a producer discipline
  // escape — a flushed-tag kill miss (adapter age-kill, shim flush-marking,
  // LQ cdb_stage kill, arbiter kill) or a duplicate broadcast (single-
  // delivery accept/present divergence; the MEM-slot instance of this was
  // traced with exactly these diagnostics and fixed at lq_result_accepted).
  // Expected silent; the design absorbs an escape unless it lands in the
  // drain window (fatal there, see the ROB tripwire).
  // ===========================================================================
  int unsigned dbg_stale_cyc_since_flush;
  int unsigned dbg_stale_logged;
  always @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) dbg_stale_cyc_since_flush <= 0;
    else dbg_stale_cyc_since_flush <= dbg_stale_cyc_since_flush + 1;
  end
  // Benign-delivery filter: a broadcast whose tag committed within the last
  // two cycles is the known JALR double-completion (the link value is stored
  // at alloc and done comes from branch_update, so the commit can beat the
  // CDB wakeup broadcast by a cycle when the ALU adapter is contended; the
  // write lands on the just-committed entry, which cannot be reallocated
  // that fast — tail wrap needs >=32 net allocations).  Deliveries beyond
  // that window stay loud: they approach the reallocation wrap window.
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
  // Grant-cycle snapshot of the MEM-slot sources: the registered broadcast
  // lands one cycle after the grant, so when a stale MEM delivery is
  // detected these name which sub-source (SC reg / misalign reg / LQ
  // cdb_stage passthrough / adapter held) supplied it.
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

  // Capture-time check on the LQ cdb_stage: a captured completion whose tag
  // the ROB no longer tracks means a Phase-A / bypass-path escape (dead at
  // capture); if deliveries above are stale but captures here are clean, the
  // escape is instead in the cdb_stage kill between capture and grant.
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
