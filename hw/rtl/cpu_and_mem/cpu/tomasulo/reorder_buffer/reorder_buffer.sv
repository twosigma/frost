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
 * Reorder Buffer - Complete Implementation
 *
 * Implements a circular buffer for in-order instruction commit in the
 * Tomasulo out-of-order execution engine. Supports unified INT/FP entries.
 *
 * Features:
 *   - 32-entry circular buffer with head/tail pointers
 *   - Allocation interface for dispatch unit
 *   - CDB write interface for functional unit results
 *   - Branch update interface for branch resolution
 *   - In-order commit with INT/FP destination writeback
 *   - Exception handling with trap signaling
 *   - Serializing instruction support:
 *       * WFI: stall at head until interrupt pending
 *       * CSR: reads execute speculatively, side effects applied at commit
 *       * FENCE: wait for store queue to drain
 *       * FENCE.I: drain SQ + signal pipeline/icache flush
 *       * MRET: signal trap unit, redirect to mepc
 *   - Atomic instruction ordering (AMO/LR/SC at head with SQ empty)
 *   - Branch misprediction detection and flush
 *   - FP exception flag propagation for fcsr accumulation
 *
 * Storage:
 *   Multi-bit fields use distributed RAM (LUTRAM) to reduce FF usage.
 *   Single-write-port fields (written only at allocation) use sdp_dist_ram.
 *   Multi-write-port fields (allocation + CDB/branch) use mwp_dist_ram
 *   with a Live Value Table. 1-bit packed vectors that need per-entry
 *   flush/reset remain in flip-flops.
 *
 * External Coordination:
 *   The Reorder Buffer coordinates with several external units via handshake signals:
 *   - Store Queue: i_sq_empty for FENCE/AMO ordering
 *   - CSR Unit: o_csr_start/i_csr_done for CSR side effects at commit
 *   - Trap Unit: o_trap_pending/i_trap_taken for exception handling
 *   - Interrupt Controller: i_interrupt_pending for WFI
 */

module reorder_buffer (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // Slot-2 allocation (2-wide dispatch).  Slot 2 is the second-in-program-
    // order entry of a dispatch bundle: tail_idx+1.
    // Contract from dispatch: i_alloc_req_2.alloc_valid only asserts when
    // i_alloc_req.alloc_valid is also set this cycle.
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req_2,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp_2,

    // =========================================================================
    // CDB Write Interface (from Functional Units via CDB)
    // =========================================================================
    // For non-branch results (ALU, MUL, DIV, MEM, FP)
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write,
    // Second CDB lane (2-wide CDB): a distinct completed entry, marked done +
    // value/exc/fp written the same cycle as i_cdb_write. The arbiter
    // guarantees tag != i_cdb_write.tag, so the two never collide on a RAM
    // address or a rob_done bit.
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write_2,

    // Direct non-CDB completion for plain stores. Stores do not need wakeup or
    // a CDB value broadcast; the ROB only needs to know the entry is done.
    input logic                                        i_store_complete_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_store_complete_tag,

    // =========================================================================
    // Branch Update Interface (from Branch Unit)
    // =========================================================================
    // Separate from CDB - only for branch/jump resolution
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // Checkpoint Interface (from/to RAT Checkpoint Unit)
    // =========================================================================
    // When a branch is allocated and needs a checkpoint
    input logic                                    i_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,

    // =========================================================================
    // Commit Output (to Regfiles, SQ, Trap Unit)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb,
    output logic                              o_commit_valid_raw,
    output logic                              o_commit_store_like_raw,
    output logic                              o_commit_misprediction_raw,
    output logic                              o_commit_correct_branch_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // Widen-commit slot 2 (head+1).  When the 2-wide gate fires, these
    // carry the second retiring entry for the same cycle; otherwise valid
    // is low and the payload is '0.  Slot 2 can never be a branch,
    // mispredict, serial op, FENCE.I, exception, or AMO/LR/SC by
    // construction, so the recovery/mispredict fields are zeroed here —
    // only the retire/regfile/store-commit consumers need slot 2.
    output riscv_pkg::reorder_buffer_commit_t o_commit_2,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb_2,
    output logic                              o_commit_2_valid_raw,
    output logic                              o_commit_2_store_like_raw,

    // Back-pressure from the cpu_ooo pending-write FIFO.  Asserted when
    // there is room for a slot-2 regfile write this cycle; deasserted when
    // the pending register holds a prior slot-2 write that has not yet
    // drained AND rob_commit (slot 1) also wants the port this cycle.
    // Driven from a registered cpu_ooo signal, so the feedback path
    // closes at a flop (no combinational loop).
    input logic i_widen_commit_ok,
    input logic i_commit_hold,

    // =========================================================================
    // Store Queue Coordination
    // =========================================================================
    input  logic i_sq_empty,            // Store queue has no entries at all
    input  logic i_sq_committed_empty,  // No committed entries pending write (for FENCE)
    // FENCE.I cache-sync handshake (see rob_serializer): request held while
    // the serializer waits; done is a level while the request is high.
    input  logic i_fence_i_sync_done,
    output logic o_fence_i_sync_req,

    // =========================================================================
    // CSR Unit Coordination
    // =========================================================================
    // CSR reads execute speculatively; o_csr_start triggers side effects at commit
    output logic o_csr_start,  // Signal CSR unit to apply side effects at commit
    input  logic i_csr_done,   // CSR unit has completed

    // =========================================================================
    // Trap/Exception Handling
    // =========================================================================
    // Exception detected at head - signal trap unit
    output logic o_trap_pending,  // Exception needs handling
    output logic [riscv_pkg::XLEN-1:0] o_trap_pc,  // PC of excepting instruction
    // Head decodes as WFI (drives WFI interrupt-resume-PC seed in cpu_ooo)
    output logic o_head_is_wfi,
    output riscv_pkg::exc_cause_t o_trap_cause,  // Exception cause
    // Head entry's CDB value at trap time. For a misaligned load/store the
    // load_queue/SQ path parks the faulting address here (the value slot is
    // unused for an exception), so cpu_ooo can write it to mtval.
    output logic [riscv_pkg::XLEN-1:0] o_trap_value,
    input logic i_trap_taken,  // Trap unit has taken the trap

    // MRET coordination
    output logic                       o_mret_start,  // Signal trap unit to handle MRET
    input  logic                       i_mret_done,   // MRET handling complete
    input  logic [riscv_pkg::XLEN-1:0] i_mepc,        // Return PC from trap unit

    // =========================================================================
    // Interrupt Interface (for WFI)
    // =========================================================================
    input logic i_interrupt_pending,  // Interrupt is pending (wake from WFI)

    // Current privilege (PrivM/PrivU). A U-mode access to MRET or to a CSR that
    // requires more privilege is an illegal instruction, detected at the head.
    input logic [1:0] i_priv,

    // =========================================================================
    // Pipeline Flush Control
    // =========================================================================
    // Flush requests can come from:
    // 1. Branch misprediction (partial flush via i_flush_en)
    // 2. Exception (full flush via i_flush_all)
    // 3. FENCE.I (full flush after commit)
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,  // Flush entries after this tag
    input logic i_flush_all,  // Flush entire Reorder Buffer (exception)
    input logic i_flush_after_head_commit,

    // FENCE.I triggers pipeline and icache flush after commit
    output logic o_fence_i_flush,  // FENCE.I committed, flush pipeline/icache

    // =========================================================================
    // Early Misprediction Recovery
    // =========================================================================
    // Qualifies the current partial flush as an execute-time early recovery
    input logic                                        i_early_recovery_flush,
    // Marks the entry as early-recovered so commit skips re-triggering flush
    input logic                                        i_early_recovery_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_recovery_tag,

    // =========================================================================
    // Status Outputs
    // =========================================================================
    output logic                                      o_full,
    // Asserted when there is room for at most 1 more entry (i.e., a 2-wide
    // dispatch bundle would not fit).  Distinct from o_full so dispatch can
    // independently gate slot-2 while still allowing slot-1 to fire.
    output logic                                      o_full_for_2,
    output logic                                      o_empty,
    output logic [riscv_pkg::ReorderBufferTagWidth:0] o_count,       // Number of valid entries

    // Head entry information (for external commit coordination)
    output logic                        [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                                               o_head_valid,
    output logic                                                               o_head_done,
    output logic                        [   riscv_pkg::ReorderBufferDepth-1:0] o_entry_valid,
    output logic                        [   riscv_pkg::ReorderBufferDepth-1:0] o_entry_done,
    output riscv_pkg::rob_perf_events_t                                        o_perf_events,

    // =========================================================================
    // Reorder Buffer Entry Read Interface (for RAT lookup of in-flight values)
    // =========================================================================
    // Allows RAT to check if a Reorder Buffer entry has completed (for bypass)
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,

    // =========================================================================
    // Dispatch Bypass Read Ports (async value read for renamed-but-done sources)
    // =========================================================================
    // Channels 1-3: slot-1 sources.  Channels 4-6: slot-2 sources (Session M).
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_3,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_4,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_4,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_5,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_5,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_6,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_6,

    // Buffered FMUL dispatch repair ports (wrapper-local async reads)
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_3
);

  // ===========================================================================
  // Local Parameters (from package)
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned ReorderBufferDepth = riscv_pkg::ReorderBufferDepth;
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned ExcCauseWidth = riscv_pkg::ExcCauseWidth;
  localparam int unsigned FpFlagsWidth = 5;  // $bits(riscv_pkg::fp_flags_t) — nv,dz,of,uf,nx
  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;
  localparam int unsigned RsTypeWidth = 3;
  localparam int unsigned HeadMetaWidth = 21 + RsTypeWidth;

  // Widen-commit master enable.  While 0 the ROB behaves exactly as the
  // 1-wide baseline: head_ptr always advances by 1, rob_valid only clears
  // head, and o_commit_comb_2.valid is forced low (so no downstream
  // consumer sees slot 2 even though the plumbing exists).  The
  // commit_2_opportunity perf counter is still updated so we can keep
  // measuring the upper bound across incremental steps.  Flipped to 1
  // after all downstream consumers (RAT, SQ, cpu_ooo FIFO, instret) are
  // in place.
  localparam bit EnableWidenCommit = 1'b1;

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // Check if entry_idx is younger than flush_tag (relative to head)
  function automatic logic should_flush_entry(input logic [ReorderBufferTagWidth-1:0] entry_idx,
                                              input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                              input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age = {1'b0, entry_idx} - {1'b0, head};
      flush_age = {1'b0, flush_tag} - {1'b0, head};
      should_flush_entry = entry_age > flush_age;
    end
  endfunction

  function automatic logic [ReorderBufferDepth-1:0] advance_onehot_mask(
      input logic [ReorderBufferDepth-1:0] mask, input logic advance_two);
    advance_onehot_mask = '0;
    for (int unsigned i = 0; i < ReorderBufferDepth; i++) begin
      advance_onehot_mask[(i+(advance_two?2 : 1))%ReorderBufferDepth] = mask[i];
    end
  endfunction

  // Forward declarations (used in debug assigns before main decl)
  logic [ReorderBufferTagWidth:0] head_ptr;
  logic [ReorderBufferTagWidth:0] tail_ptr;
  logic full;
  logic full_for_2;
  logic dispatch_full_q;
  logic dispatch_full_for_2_q;
  logic empty;

  // ===========================================================================
  // Debug Signals (for verification)
  // ===========================================================================
  logic [ReorderBufferTagWidth:0] dbg_tail_ptr  /* verilator public_flat_rd */;
  assign dbg_tail_ptr = tail_ptr;

  logic [ReorderBufferTagWidth:0] dbg_head_ptr  /* verilator public_flat_rd */;
  assign dbg_head_ptr = head_ptr;

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  // Reorder Buffer storage — 1-bit packed vectors remain in FFs for
  // per-entry flush/reset.  Multi-bit fields are in distributed RAM below.
  // rob_valid broadcasts to the RAT rename muxes, per-RS CDB wake, and
  // cpu_ooo flush/commit control. Post-synth shows bit[27] at ~80 fanout
  // driving an 18-level cone into the pd_stage BTB register. Force Vivado
  // to replicate each bit before the net exceeds 32 loads so the commit/
  // flush broadcast no longer rides on a single per-bit driver.
  (* max_fanout = 32 *) logic [ReorderBufferDepth-1:0] rob_valid;
  logic [ReorderBufferDepth-1:0] rob_done;
  logic [ReorderBufferDepth-1:0] rob_exception;
  logic [ReorderBufferDepth-1:0] rob_branch_taken;
  logic [ReorderBufferDepth-1:0] rob_mispredicted;
  logic [ReorderBufferDepth-1:0] rob_early_recovered;

  // Head and tail pointers (declared above for forward ref)

  // Derived pointer values (without wrap bit)
  logic [ReorderBufferTagWidth-1:0] head_idx;
  logic [ReorderBufferTagWidth-1:0] tail_idx;
  // Slot-2 alloc target, wraps within ReorderBufferTagWidth modulus.
  logic [ReorderBufferTagWidth-1:0] tail_idx_2;
  logic [ReorderBufferDepth-1:0] head_clear_mask;
  logic [ReorderBufferDepth-1:0] head_next_clear_mask;

  // Status signals (full and empty declared above for forward ref)
  logic [ReorderBufferTagWidth:0] count;

  // Head entry fields for commit — RAM-backed fields are driven by RAM
  // read ports directly; FF-backed fields are assigned from packed vectors.
  logic head_valid;
  logic head_done;
  logic head_exception;
  logic head_exception_raw;  // stored ROB exception flag (before U-mode priv fault)
  logic head_priv_fault;  // U-mode access to MRET / an M-CSR -> illegal instruction
  riscv_pkg::exc_cause_t head_exc_cause;  // effective cause (includes priv fault)
  riscv_pkg::exc_cause_t head_exc_cause_raw;  // from RAM
  logic [XLEN-1:0] head_pc;  // from RAM
  logic head_dest_rf;
  logic [RegAddrWidth-1:0] head_dest_reg;  // from RAM
  logic head_dest_valid;
  logic [FLEN-1:0] head_value;  // from RAM
  logic head_is_store;
  logic head_is_fp_store;
  logic head_is_branch;
  logic head_branch_taken;
  logic [XLEN-1:0] head_branch_target;
  logic [XLEN-1:0] head_branch_target_jal;  // JAL target written at allocation
  logic [XLEN-1:0] head_branch_target_resolved;  // branch/JALR target written at resolution
  logic head_predicted_taken;
  logic [XLEN-1:0] head_predicted_target;  // from RAM
  logic head_mispredicted;
  logic head_early_recovered;
  logic head_is_call;  // for BTB/RAS update at commit
  logic head_is_return;  // for BTB/RAS update at commit
  logic head_is_jal;
  logic head_is_jalr;
  logic head_has_checkpoint;
  logic [CheckpointIdWidth-1:0] head_checkpoint_id;  // from RAM
  riscv_pkg::fp_flags_t head_fp_flags;  // from RAM
  logic head_is_csr;
  logic head_is_fence;
  logic head_is_fence_i;
  logic head_is_wfi;
  logic head_is_mret;
  logic head_is_amo;
  logic head_is_lr;
  logic head_is_sc;
  logic head_is_compressed;
  logic head_has_fp_flags;
  riscv_pkg::rs_type_e head_rs_type;
  logic [RsTypeWidth-1:0] head_rs_type_bits;
  logic [HeadMetaWidth-1:0] head_meta_rd_data;
  // CSR fields (from RAM)
  logic [11:0] head_csr_addr;
  logic [2:0] head_csr_op;
  logic [XLEN-1:0] head_csr_write_data;
  logic [XLEN-1:0] head_fallthrough_pc;

  // Head+1 ("slot 2") fields for widen-commit. Populated by parallel
  // distributed RAM instances reading at head_next_idx. Only the flags that
  // feed the 2-wide hazard gate are strictly required for step 1; the value/
  // branch/CSR/PC fields are filled in when slot 2 is exposed externally.
  logic [ReorderBufferTagWidth-1:0] head_next_idx;
  logic head_next_valid;
  logic head_next_done;
  logic head_next_exception;
  logic head_next_dest_rf;
  logic [RegAddrWidth-1:0] head_next_dest_reg;
  logic head_next_dest_valid;
  logic [FLEN-1:0] head_next_value;
  logic head_next_is_store;
  logic head_next_is_fp_store;
  logic head_next_is_branch;
  logic head_next_branch_taken;
  logic [XLEN-1:0] head_next_pc;
  logic [XLEN-1:0] head_next_branch_target;
  logic [XLEN-1:0] head_next_branch_target_jal;
  logic [XLEN-1:0] head_next_branch_target_resolved;
  logic head_next_predicted_taken;
  logic [XLEN-1:0] head_next_predicted_target;
  logic head_next_mispredicted;
  logic head_next_early_recovered;
  logic head_next_is_call;
  logic head_next_is_return;
  logic head_next_is_jal;
  logic head_next_is_jalr;
  logic head_next_has_checkpoint;
  logic [CheckpointIdWidth-1:0] head_next_checkpoint_id;
  riscv_pkg::fp_flags_t head_next_fp_flags;
  riscv_pkg::exc_cause_t head_next_exc_cause;
  logic head_next_is_csr;
  logic head_next_is_fence;
  logic head_next_is_fence_i;
  logic head_next_is_wfi;
  logic head_next_is_mret;
  logic head_next_is_amo;
  logic head_next_is_lr;
  logic head_next_is_sc;
  logic head_next_is_compressed;
  logic head_next_has_fp_flags;
  riscv_pkg::rs_type_e head_next_rs_type;
  logic [RsTypeWidth-1:0] head_next_rs_type_bits;
  logic [HeadMetaWidth-1:0] head_next_meta_rd_data;
  logic [11:0] head_next_csr_addr;
  logic [2:0] head_next_csr_op;
  logic [XLEN-1:0] head_next_csr_write_data;

  // Commit control signals
  logic head_ready;  // Head is valid and done
  logic commit_stall;  // Stall commit for serializing instructions
  logic commit_en;  // Actually commit this cycle

  // Widen-commit ("2-wide") gate. Asserted when commit_en is high this
  // cycle AND the entry immediately behind head is also retirable AND
  // neither slot hits a hazard that forces 1-wide commit (serial ops,
  // head mispredict, head+1 branch, FENCE.I, exceptions, AMO/LR/SC).
  // Step 1 uses this only as a perf-counter input — it does NOT yet
  // change head_ptr advancement, rob_valid clearing, or the commit
  // output struct.
  logic head_ok_2wide;
  logic head_next_ok_2wide;
  logic commit_2_gate;

  // Serializing instruction state machine.
  riscv_pkg::serial_state_e serial_state;  // driven by rob_serializer

  // Misprediction detection at commit
  logic commit_misprediction;

  // FENCE.I commit tracking
  (* max_fanout = 32 *) logic fence_i_committed;

  // ===========================================================================
  // Pointer Logic
  // ===========================================================================

  assign head_idx = head_ptr[ReorderBufferTagWidth-1:0];
  assign tail_idx = tail_ptr[ReorderBufferTagWidth-1:0];
  assign tail_idx_2 = tail_idx + 1'b1;

  // Full when pointers are equal except for MSB (wrap bit differs)
  assign full = (head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
                (head_idx == tail_idx);

  // full_for_2: there is room for at most 1 more entry, so a 2-wide bundle
  // would not fit.  Used to gate slot-2 alloc independently from slot-1.
  // Excludes commit-this-cycle gains (matches o_full's conservative model).
  assign full_for_2 = full || (count == ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1);

  // Empty when pointers are exactly equal (including wrap bit)
  assign empty = (head_ptr == tail_ptr);

  // Count of valid entries
  assign count = tail_ptr - head_ptr;

  // Head entry fields from FF-backed packed vectors / distributed RAM
  assign head_valid = rob_valid[head_idx];
  assign head_done = rob_done[head_idx];
  assign head_exception_raw = rob_exception[head_idx];
  // U-mode privilege fault: MRET, or a CSR access requiring more privilege than
  // the current mode (csr_addr[9:8] > priv), is an illegal instruction. Folding
  // it into head_exception/head_exc_cause makes every consumer (commit_en,
  // o_csr_start/o_mret_start, o_trap_pending, the serial FSM, the commit record)
  // treat it as a precise exception, so the faulting op never executes or
  // retires. The faulting op rides the same single-cycle exception path, so the
  // double-trap guard in trap_unit already covers it.
  assign head_priv_fault = (head_is_mret && (i_priv != riscv_pkg::PrivM)) ||
                           (head_is_csr && (head_csr_addr[9:8] > i_priv));
  assign head_exception = head_exception_raw || head_priv_fault;
  assign head_exc_cause   = (head_priv_fault && !head_exception_raw) ?
      riscv_pkg::exc_cause_t'(riscv_pkg::ExcIllegalInstr) : head_exc_cause_raw;
  assign head_branch_taken = rob_branch_taken[head_idx];
  assign head_mispredicted = rob_mispredicted[head_idx];
  assign head_early_recovered = rob_early_recovered[head_idx];
  assign {
    head_dest_rf,
    head_dest_valid,
    head_is_store,
    head_is_fp_store,
    head_is_branch,
    head_predicted_taken,
    head_is_call,
    head_is_return,
    head_is_jal,
    head_is_jalr,
    head_has_checkpoint,
    head_is_csr,
    head_is_fence,
    head_is_fence_i,
    head_is_wfi,
    head_is_mret,
    head_is_amo,
    head_is_lr,
    head_is_sc,
    head_is_compressed,
    head_has_fp_flags,
    head_rs_type_bits
  } = head_meta_rd_data;
  assign head_rs_type = riscv_pkg::rs_type_e'(head_rs_type_bits);
  assign head_branch_target = head_is_jal ? head_branch_target_jal : head_branch_target_resolved;
  logic head_link_is_compressed;
  assign head_link_is_compressed = (head_value[XLEN-1:0] == (head_pc + 32'd2));
  assign head_fallthrough_pc = head_pc + (head_is_compressed ? 32'd2 : 32'd4);

  // Head+1 entry fields from FF-backed packed vectors / distributed RAM.
  // The RAM-backed multi-bit fields (pc, dest_reg, value, branch_target_*,
  // predicted_target, checkpoint_id, meta, csr_*, exc_cause, fp_flags) are
  // driven by dedicated read-port replicas instantiated alongside the head
  // RAMs below.  1-bit packed-vector fields share the existing FF storage
  // and are indexed at head_next_idx for free.
  assign head_next_idx = head_idx + 1'b1;
  assign head_next_valid = rob_valid[head_next_idx];
  assign head_next_done = rob_done[head_next_idx];
  assign head_next_exception = rob_exception[head_next_idx];
  assign head_next_branch_taken = rob_branch_taken[head_next_idx];
  assign head_next_mispredicted = rob_mispredicted[head_next_idx];
  assign head_next_early_recovered = rob_early_recovered[head_next_idx];
  assign {
    head_next_dest_rf,
    head_next_dest_valid,
    head_next_is_store,
    head_next_is_fp_store,
    head_next_is_branch,
    head_next_predicted_taken,
    head_next_is_call,
    head_next_is_return,
    head_next_is_jal,
    head_next_is_jalr,
    head_next_has_checkpoint,
    head_next_is_csr,
    head_next_is_fence,
    head_next_is_fence_i,
    head_next_is_wfi,
    head_next_is_mret,
    head_next_is_amo,
    head_next_is_lr,
    head_next_is_sc,
    head_next_is_compressed,
    head_next_has_fp_flags,
    head_next_rs_type_bits
  } = head_next_meta_rd_data;
  assign head_next_rs_type = riscv_pkg::rs_type_e'(head_next_rs_type_bits);
  assign head_next_branch_target =
      head_next_is_jal ? head_next_branch_target_jal : head_next_branch_target_resolved;

  // Widen-commit hazard gates.  Head may be a correctly-predicted branch;
  // head+1 may never be a branch (BTB update arbitration).  Both must be
  // plain non-serial instructions for 2-wide to fire.
  assign head_ok_2wide =
      !head_is_csr && !head_is_fence && !head_is_fence_i && !head_is_wfi &&
      !head_is_mret && !head_is_amo && !head_is_lr && !head_is_sc &&
      !head_exception && !(head_is_branch && head_mispredicted);
  assign head_next_ok_2wide =
      !head_next_is_csr && !head_next_is_fence && !head_next_is_fence_i &&
      !head_next_is_wfi && !head_next_is_mret && !head_next_is_amo &&
      !head_next_is_lr && !head_next_is_sc &&
      !head_next_exception && !head_next_is_branch;

  // Same-cycle CDB bypass for head / head+1.  rob_done / rob_value /
  // rob_fp_flags update at the clock edge from i_cdb_write; without a bypass
  // the head can't commit until the cycle after the CDB write lands, leaving
  // ~1 cycle of drain on every FU completion.  Forward i_cdb_write directly
  // when it targets the head (or head+1) tag so commit fires the same cycle
  // the arbiter broadcasts.  Excluded cases (exception, branch/JAL/JALR,
  // CSR, FENCE, FENCE.I, WFI, MRET) fall through to the existing
  // branch_update / serial / trap paths — the bypass only shortcircuits
  // ordinary completions, which dominate the CoreMark head-wait buckets.
  //
  // An analogous bypass for i_store_complete_valid was tried and dropped:
  // cutting the store-drain reduced head_wait_mem_store but pushed the
  // bubble into SQ-drain / load-disambig, netting essentially zero cycles.
  //
  // i_flush_all is already on the downstream commit_en gate, so the bypass
  // doesn't need to recheck it here — leaving it off keeps the ROB's
  // full_flush_all cone (the current -0.495 ns critical path) off the
  // commit-side bypass path.
  logic head_cdb_match;
  logic head_cdb_match_l2;  // lane-1 hits the head
  logic head_cdb_bypass;
  logic head_next_cdb_match;
  logic head_next_cdb_match_l2;  // lane-1 hits head+1
  logic head_next_cdb_bypass;

  // The two CDB lanes carry distinct tags, so at most one lane hits the head
  // (and independently at most one hits head+1). Select that lane's payload.
  assign head_cdb_match = i_cdb_write.valid && (i_cdb_write.tag == head_idx);
  assign head_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx);
  logic head_cdb_exc_sel;
  logic [FLEN-1:0] head_cdb_value_sel;
  riscv_pkg::fp_flags_t head_cdb_fp_flags_sel;
  assign head_cdb_exc_sel = head_cdb_match ? i_cdb_write.exception : i_cdb_write_2.exception;
  assign head_cdb_value_sel = head_cdb_match ? i_cdb_write.value : i_cdb_write_2.value;
  assign head_cdb_fp_flags_sel = head_cdb_match ? i_cdb_write.fp_flags : i_cdb_write_2.fp_flags;
  assign head_cdb_bypass = (head_cdb_match || head_cdb_match_l2) && !head_cdb_exc_sel &&
      !head_is_branch && !head_is_csr && !head_is_fence && !head_is_fence_i &&
      !head_is_wfi && !head_is_mret;

  assign head_next_cdb_match = i_cdb_write.valid && (i_cdb_write.tag == head_next_idx);
  assign head_next_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_write_2.tag == head_next_idx);
  logic head_next_cdb_exc_sel;
  logic [FLEN-1:0] head_next_cdb_value_sel;
  riscv_pkg::fp_flags_t head_next_cdb_fp_flags_sel;
  assign head_next_cdb_exc_sel =
      head_next_cdb_match ? i_cdb_write.exception : i_cdb_write_2.exception;
  assign head_next_cdb_value_sel = head_next_cdb_match ? i_cdb_write.value : i_cdb_write_2.value;
  assign head_next_cdb_fp_flags_sel =
      head_next_cdb_match ? i_cdb_write.fp_flags : i_cdb_write_2.fp_flags;
  // head_next_cdb_bypass is gated further by head_next_ok_2wide at its only
  // consumer (commit_2_gate), so the bypass itself only needs the exception
  // exclusion to cover the trap path.
  assign head_next_cdb_bypass = (head_next_cdb_match || head_next_cdb_match_l2) &&
      !head_next_cdb_exc_sel;

  logic head_done_eff;
  logic head_next_done_eff;
  assign head_done_eff = head_done || head_cdb_bypass;
  assign head_next_done_eff = head_next_done || head_next_cdb_bypass;

  // Value / fp_flags forwarding only applies to the CDB bypass (stores don't
  // write these fields).
  logic [FLEN-1:0] head_value_eff;
  riscv_pkg::fp_flags_t head_fp_flags_eff;
  logic [FLEN-1:0] head_next_value_eff;
  riscv_pkg::fp_flags_t head_next_fp_flags_eff;
  assign head_value_eff = head_cdb_bypass ? head_cdb_value_sel : head_value;
  assign head_fp_flags_eff = head_cdb_bypass ? head_cdb_fp_flags_sel : head_fp_flags;
  assign head_next_value_eff = head_next_cdb_bypass ? head_next_cdb_value_sel : head_next_value;
  assign head_next_fp_flags_eff =
      head_next_cdb_bypass ? head_next_cdb_fp_flags_sel : head_next_fp_flags;

  // Head is ready to potentially commit
  assign head_ready = head_valid && head_done_eff;

  // 2-wide commit gate.  commit_2_gate is the "opportunity" signal — it
  // fires whenever the ROB could theoretically retire two entries this
  // cycle, independent of the master enable and the FIFO back-pressure.
  // This feeds the perf counter so we can keep measuring upper bound
  // even when widen-commit is gated off.  commit_2_fire is what the
  // output / retire logic actually acts on — it ANDs the opportunity with
  // the master enable and the cpu_ooo pending-write FIFO back-pressure.
  assign commit_2_gate = commit_en && head_next_valid && head_next_done_eff &&
                         head_ok_2wide && head_next_ok_2wide;
  logic commit_2_fire;
  assign commit_2_fire = commit_2_gate && EnableWidenCommit && i_widen_commit_ok;

  // ===========================================================================
  // Distributed RAM Write Enables and Data
  // ===========================================================================

  logic alloc_en;
  logic alloc_en_2;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_status;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_status;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_valid;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_valid;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_control;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_control;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_branch_bits;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_branch_bits;
  assign alloc_en = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;
  // Slot-2 alloc requires slot-1 to also fire (slot-2 lives at tail_idx+1
  // by construction).  full_for_2 covers the "only 1 free slot" case.
  assign alloc_en_2 = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                      !full_for_2 && !i_flush_all && !i_flush_en;
  assign alloc_en_status = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;
  assign alloc_en_2_status = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                             !full_for_2 && !i_flush_all && !i_flush_en;
  assign alloc_en_valid = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;
  assign alloc_en_2_valid = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                            !full_for_2 && !i_flush_all && !i_flush_en;
  assign alloc_en_control = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;
  assign alloc_en_2_control = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                              !full_for_2 && !i_flush_all && !i_flush_en;
  assign alloc_en_branch_bits = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;
  assign alloc_en_2_branch_bits = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                                  !full_for_2 && !i_flush_all && !i_flush_en;

  logic cdb_ram_wr_en;
  logic cdb_state_wr_en;
  assign cdb_ram_wr_en   = i_cdb_write.valid && !i_flush_all;
  assign cdb_state_wr_en = cdb_ram_wr_en && rob_valid[i_cdb_write.tag];

  // Lane-1 (2-wide CDB) write enables — symmetric with lane 0.
  logic cdb_ram_wr_en_2;
  logic cdb_state_wr_en_2;
  assign cdb_ram_wr_en_2   = i_cdb_write_2.valid && !i_flush_all;
  assign cdb_state_wr_en_2 = cdb_ram_wr_en_2 && rob_valid[i_cdb_write_2.tag];

  logic branch_wr_en;
  assign branch_wr_en = i_branch_update.valid && !i_flush_all && rob_valid[i_branch_update.tag];

  // Allocation data precomputation for fields with instruction-type-dependent values
  logic [FLEN-1:0] alloc_value_data;
  logic [FLEN-1:0] alloc_value_data_2;
  always_comb begin
    // Save the sequential fall-through/link address for all branches and jumps.
    // Commit-time redirect can then use the exact saved address instead of
    // recomputing from compressed-length metadata.
    if (i_alloc_req.is_branch) alloc_value_data = {{(FLEN - XLEN) {1'b0}}, i_alloc_req.link_addr};
    else alloc_value_data = '0;
  end
  always_comb begin
    if (i_alloc_req_2.is_branch)
      alloc_value_data_2 = {{(FLEN - XLEN) {1'b0}}, i_alloc_req_2.link_addr};
    else alloc_value_data_2 = '0;
  end

  logic [XLEN-1:0] alloc_branch_target_data;
  logic [XLEN-1:0] alloc_branch_target_data_2;
  assign alloc_branch_target_data   = i_alloc_req.is_jal ? i_alloc_req.branch_target : '0;
  assign alloc_branch_target_data_2 = i_alloc_req_2.is_jal ? i_alloc_req_2.branch_target : '0;

  // Per design decision #1, only one slot in a bundle can be a branch, so
  // i_checkpoint_valid (single-port) applies to whichever slot is the branch.
  // alloc_has_checkpoint_data fires only for that slot; the other gets '0.
  logic [CheckpointIdWidth-1:0] alloc_checkpoint_id_data;
  logic [CheckpointIdWidth-1:0] alloc_checkpoint_id_data_2;
  assign alloc_checkpoint_id_data = (i_checkpoint_valid && i_alloc_req.is_branch) ?
                                     i_checkpoint_id : '0;
  assign alloc_checkpoint_id_data_2 = (i_checkpoint_valid && i_alloc_req_2.is_branch) ?
                                      i_checkpoint_id : '0;
  logic alloc_has_checkpoint_data;
  logic alloc_has_checkpoint_data_2;
  assign alloc_has_checkpoint_data   = i_checkpoint_valid && i_alloc_req.is_branch;
  assign alloc_has_checkpoint_data_2 = i_checkpoint_valid && i_alloc_req_2.is_branch;

  logic [HeadMetaWidth-1:0] alloc_head_meta_data;
  logic [HeadMetaWidth-1:0] alloc_head_meta_data_2;
  assign alloc_head_meta_data = {
    i_alloc_req.dest_rf,
    i_alloc_req.dest_valid,
    i_alloc_req.is_store,
    i_alloc_req.is_fp_store,
    i_alloc_req.is_branch,
    i_alloc_req.predicted_taken,
    i_alloc_req.is_call,
    i_alloc_req.is_return,
    i_alloc_req.is_jal,
    i_alloc_req.is_jalr,
    alloc_has_checkpoint_data,
    i_alloc_req.is_csr,
    i_alloc_req.is_fence,
    i_alloc_req.is_fence_i,
    i_alloc_req.is_wfi,
    i_alloc_req.is_mret,
    i_alloc_req.is_amo,
    i_alloc_req.is_lr,
    i_alloc_req.is_sc,
    i_alloc_req.is_compressed,
    i_alloc_req.has_fp_flags,
    RsTypeWidth'(i_alloc_req.rs_type)
  };
  assign alloc_head_meta_data_2 = {
    i_alloc_req_2.dest_rf,
    i_alloc_req_2.dest_valid,
    i_alloc_req_2.is_store,
    i_alloc_req_2.is_fp_store,
    i_alloc_req_2.is_branch,
    i_alloc_req_2.predicted_taken,
    i_alloc_req_2.is_call,
    i_alloc_req_2.is_return,
    i_alloc_req_2.is_jal,
    i_alloc_req_2.is_jalr,
    alloc_has_checkpoint_data_2,
    i_alloc_req_2.is_csr,
    i_alloc_req_2.is_fence,
    i_alloc_req_2.is_fence_i,
    i_alloc_req_2.is_wfi,
    i_alloc_req_2.is_mret,
    i_alloc_req_2.is_amo,
    i_alloc_req_2.is_lr,
    i_alloc_req_2.is_sc,
    i_alloc_req_2.is_compressed,
    i_alloc_req_2.has_fp_flags,
    RsTypeWidth'(i_alloc_req_2.rs_type)
  };

  // ===========================================================================
  // Distributed RAM Instances
  // ===========================================================================
  // Single-write-port fields (written only at allocation, read at head).
  // These use sdp_dist_ram — one write port, one async read port.
  // ---------------------------------------------------------------------------

  // 2-write port: slot-1 alloc (port 0) + slot-2 alloc (port 1).  Port 1
  // writes when slot-2 allocates its ROB entry in the same cycle as slot-1.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_pc (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_idx),
      .o_read_data    (head_pc)
  );

  // Widen-commit replica: head+1 read port for pc.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_pc_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_pc)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_dest_reg (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_idx),
      .o_read_data    (head_dest_reg)
  );

  // Widen-commit replica: head+1 read port for dest_reg.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_dest_reg_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_dest_reg)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_predicted_target (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.predicted_target, i_alloc_req.predicted_target}),
      .i_read_address (head_idx),
      .o_read_data    (head_predicted_target)
  );

  // Widen-commit replica: head+1 read port for predicted_target.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_predicted_target_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.predicted_target, i_alloc_req.predicted_target}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_predicted_target)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_checkpoint_id (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_checkpoint_id)
  );

  // Widen-commit replica: head+1 read port for checkpoint_id.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_checkpoint_id_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_checkpoint_id)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_head_meta (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_meta_rd_data)
  );

  // Widen-commit replica: head+1 read port for head_meta.  This feeds the
  // head_next_* hazard flags consumed by the 2-wide commit gate.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_head_meta_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_meta_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Multi-write-port fields (allocation + CDB or branch update).
  // These use mwp_dist_ram with 3 write ports for 2-wide alloc support.
  // Port 0 = slot-1 alloc, Port 1 = slot-2 alloc, Port 2 = CDB (highest pri).
  // ---------------------------------------------------------------------------

  // rob_value: 3 write ports (alloc1 + alloc2 + CDB), 2 read ports (head + RAT bypass).
  // Two instances with identical writes, different read addresses.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_head (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(head_idx),
      .o_read_data(head_value)
  );

  // Widen-commit replica: head+1 read port for value.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_head_next (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(head_next_idx),
      .o_read_data(head_next_value)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_rat (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_read_tag),
      .o_read_data(o_read_value)
  );

  // Dispatch bypass value read ports (same write data as above, different read addresses)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_1 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_1),
      .o_read_data(o_bypass_value_1)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_2 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_2),
      .o_read_data(o_bypass_value_2)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_3 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_3),
      .o_read_data(o_bypass_value_3)
  );

  // Slot-2 done-repair bypass read ports (Session M).
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_4 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_4),
      .o_read_data(o_bypass_value_4)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_5 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_5),
      .o_read_data(o_bypass_value_5)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_bypass_6 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_6),
      .o_read_data(o_bypass_value_6)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_fmul_pending_1 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_1),
      .o_read_data(o_fmul_pending_bypass_value_1)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_fmul_pending_2 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_2),
      .o_read_data(o_fmul_pending_bypass_value_2)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(4)
  ) u_rob_value_fmul_pending_3 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_3),
      .o_read_data(o_fmul_pending_bypass_value_3)
  );

  // rob_exc_cause: 3 write ports (alloc1='0 + alloc2='0 + CDB), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_exc_cause (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.exc_cause, i_cdb_write.exc_cause, ExcCauseWidth'(0), ExcCauseWidth'(0)
      }),
      .i_read_address(head_idx),
      .o_read_data(head_exc_cause_raw)
  );

  // Widen-commit replica: head+1 read port for exc_cause.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_exc_cause_next (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.exc_cause, i_cdb_write.exc_cause, ExcCauseWidth'(0), ExcCauseWidth'(0)
      }),
      .i_read_address(head_next_idx),
      .o_read_data(head_next_exc_cause)
  );

  // rob_fp_flags: 3 write ports (alloc1='0 + alloc2='0 + CDB), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FpFlagsWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_fp_flags (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.fp_flags, i_cdb_write.fp_flags, FpFlagsWidth'(0), FpFlagsWidth'(0)
      }),
      .i_read_address(head_idx),
      .o_read_data(head_fp_flags)
  );

  // Widen-commit replica: head+1 read port for fp_flags.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FpFlagsWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_fp_flags_next (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.fp_flags, i_cdb_write.fp_flags, FpFlagsWidth'(0), FpFlagsWidth'(0)
      }),
      .i_read_address(head_next_idx),
      .o_read_data(head_next_fp_flags)
  );

  // Branch target storage only needs one writer per producer class:
  // JAL writes its architectural target at allocation, while conditional
  // branches/JALR write their resolved target on branch update. Split the
  // field across two single-write memories and select at the head instead of
  // paying the timing cost of a 2-write-port LVT RAM here.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_branch_target_jal (
      .i_clk,
      .i_write_enable ({alloc_en_2 && i_alloc_req_2.is_jal, alloc_en && i_alloc_req.is_jal}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_branch_target_data_2, alloc_branch_target_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_branch_target_jal)
  );

  // Widen-commit replica: head+1 read port for branch_target_jal.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_branch_target_jal_next (
      .i_clk,
      .i_write_enable ({alloc_en_2 && i_alloc_req_2.is_jal, alloc_en && i_alloc_req.is_jal}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_branch_target_data_2, alloc_branch_target_data}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_branch_target_jal)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_branch_target_resolved (
      .i_clk,
      .i_write_enable (branch_wr_en),
      .i_write_address(i_branch_update.tag),
      .i_write_data   (i_branch_update.target),
      .i_read_address (head_idx),
      .o_read_data    (head_branch_target_resolved)
  );

  // Widen-commit replica: head+1 read port for branch_target_resolved.
  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_branch_target_resolved_next (
      .i_clk,
      .i_write_enable (branch_wr_en),
      .i_write_address(i_branch_update.tag),
      .i_write_data   (i_branch_update.target),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_branch_target_resolved)
  );

  // CSR address RAM (12-bit, written at allocation)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (12),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_addr (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_addr, i_alloc_req.csr_addr}),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_addr)
  );

  // Widen-commit replica: head+1 read port for csr_addr.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (12),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_addr_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_addr, i_alloc_req.csr_addr}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_csr_addr)
  );

  // CSR op RAM (3-bit funct3, written at allocation)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (3),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_op (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_op, i_alloc_req.csr_op}),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_op)
  );

  // Widen-commit replica: head+1 read port for csr_op.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (3),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_op_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_op, i_alloc_req.csr_op}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_csr_op)
  );

  // CSR write data RAM (32-bit, written at allocation)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_write_data (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_write_data, i_alloc_req.csr_write_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_write_data)
  );

  // Widen-commit replica: head+1 read port for csr_write_data.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_write_data_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_write_data, i_alloc_req.csr_write_data}),
      .i_read_address (head_next_idx),
      .o_read_data    (head_next_csr_write_data)
  );

  // ===========================================================================
  // Allocation Logic
  // ===========================================================================

  // Allocation response
  assign o_alloc_resp.alloc_ready = !full && !i_flush_all && !i_flush_en;
  assign o_alloc_resp.alloc_tag = tail_idx;
  assign o_alloc_resp.full = dispatch_full_q;

  // Slot-2 response: tag is tail_idx+1 (only meaningful when slot-1 also fires).
  // alloc_ready/full are slot-2 specific so dispatch can independently gate
  // slot-2.
  assign o_alloc_resp_2.alloc_ready = !full_for_2 && !i_flush_all && !i_flush_en;
  assign o_alloc_resp_2.alloc_tag = tail_idx_2;
  assign o_alloc_resp_2.full = dispatch_full_for_2_q;

  // Flush age calculation for generic partial flush (computed combinationally).
  logic [ReorderBufferTagWidth-1:0] flush_age;
  assign flush_age = i_flush_tag - head_idx;

  logic flush_after_head_commit;
  assign flush_after_head_commit = i_flush_after_head_commit;

  // Exported dispatch back-pressure is registered from conservative next ROB
  // occupancy that includes allocation but not same-cycle commit.  This keeps
  // CDB/head-done -> commit_en off the dispatch-full flop D path.  Internal
  // allocation still uses the exact combinational full/full_for_2 signals above.
  logic [ReorderBufferTagWidth:0] dispatch_tail_next;
  logic [ReorderBufferTagWidth:0] dispatch_head_next;
  logic [ReorderBufferTagWidth:0] dispatch_count_next;
  logic [ReorderBufferTagWidth:0] dispatch_alloc_delta;
  assign dispatch_alloc_delta = {
    {ReorderBufferTagWidth - 1{1'b0}}, alloc_en_2_status, !alloc_en_2_status
  };
  always_comb begin
    dispatch_tail_next  = tail_ptr;
    dispatch_head_next  = head_ptr;
    dispatch_count_next = count;

    if (i_flush_all || i_flush_en) begin
      if (i_flush_all) begin
        dispatch_tail_next = head_ptr;
      end else if (flush_after_head_commit) begin
        dispatch_tail_next = head_ptr;
      end else begin
        dispatch_tail_next = head_ptr + {1'b0, flush_age} + 1'b1;
      end

      dispatch_count_next = dispatch_tail_next - dispatch_head_next;
    end else begin
      if (alloc_en_status) begin
        dispatch_count_next = dispatch_count_next + dispatch_alloc_delta;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      dispatch_full_q       <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      dispatch_full_q <= (dispatch_count_next == ReorderBufferDepth[ReorderBufferTagWidth:0]);
      dispatch_full_for_2_q <=
          dispatch_count_next >= (ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1);
    end
  end

  // Allocation write - tail pointer management
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      tail_ptr <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset tail to head
      tail_ptr <= head_ptr;
    end else if (i_flush_en) begin
      if (flush_after_head_commit) begin
        // Delayed recovery: the mispredicted head already retired last cycle,
        // so every remaining live entry is younger and the ROB becomes empty.
        tail_ptr <= head_ptr;
      end else begin
        // Generic partial flush: set tail to flush_tag + 1
        // Use age-based arithmetic to handle wrap correctly (extend 5-bit age to 6-bit)
        tail_ptr <= head_ptr + {1'b0, flush_age} + 1'b1;
      end
    end else if (alloc_en) begin
      // Normal allocation: advance tail by 1 (slot-1 only) or 2 (both slots).
      // alloc_en_2 implies alloc_en by construction, so the OR is implicit.
      tail_ptr <= tail_ptr + {{ReorderBufferTagWidth - 1{1'b0}}, alloc_en_2, !alloc_en_2};
    end
  end

  // ===========================================================================
  // Reorder Buffer FF Storage (1-bit packed vectors)
  // ===========================================================================

  // Handle allocation, CDB writes, branch updates, and flush for FF-backed fields.
  // Multi-bit fields (pc, dest_reg, value, branch_target, predicted_target,
  // checkpoint_id, exc_cause, fp_flags, head-only metadata) are handled by
  // distributed RAM above.
  // -------------------------------------------------------------------------
  // Control signals (rob_valid, rob_done, rob_exception) -- need reset
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rob_done      <= '0;
      rob_exception <= '0;
    end else begin
      // ---------------------------------------------------------------------
      // Allocation Write (control fields only)
      // ---------------------------------------------------------------------
      if (alloc_en_control) begin
        // Initialize control fields for new entry
        rob_exception[tail_idx] <= 1'b0;

        // JAL has fully known link/target information at allocation time.
        // JALR and conditional branches still wait for branch resolution.
        if (i_alloc_req.is_jal) begin
          rob_done[tail_idx] <= 1'b1;
        end else if (i_alloc_req.is_jalr) begin
          // JALR: target unknown until execute, but link addr is known
          rob_done[tail_idx] <= 1'b0;
        end else if (i_alloc_req.is_wfi || i_alloc_req.is_fence ||
                     i_alloc_req.is_fence_i || i_alloc_req.is_mret) begin
          // These instructions are "done" from execution perspective at dispatch
          // but commit is gated by serialization logic.
          rob_done[tail_idx] <= 1'b1;
        end else begin
          rob_done[tail_idx] <= 1'b0;
        end
      end

      // Slot-2 alloc — same logic at tail_idx_2.  Different write addresses
      // (tail_idx vs tail_idx_2) so no priority arbitration needed.
      if (alloc_en_2_control) begin
        rob_exception[tail_idx_2] <= 1'b0;

        if (i_alloc_req_2.is_jal) begin
          rob_done[tail_idx_2] <= 1'b1;
        end else if (i_alloc_req_2.is_jalr) begin
          rob_done[tail_idx_2] <= 1'b0;
        end else if (i_alloc_req_2.is_wfi || i_alloc_req_2.is_fence ||
                     i_alloc_req_2.is_fence_i || i_alloc_req_2.is_mret) begin
          rob_done[tail_idx_2] <= 1'b1;
        end else begin
          rob_done[tail_idx_2] <= 1'b0;
        end
      end

      // ---------------------------------------------------------------------
      // CDB Write (mark entry done with result)
      // ---------------------------------------------------------------------
      // For non-branch instructions (ALU, MUL, DIV, MEM, FP)
      // Value, exc_cause, fp_flags are written via distributed RAM.
      if (cdb_state_wr_en) begin
        rob_done[i_cdb_write.tag]      <= 1'b1;
        rob_exception[i_cdb_write.tag] <= i_cdb_write.exception;
      end
      // Lane-1 (2-wide CDB): distinct tag from lane 0, so these non-blocking
      // writes target a different rob_done/rob_exception index — no collision.
      if (cdb_state_wr_en_2) begin
        rob_done[i_cdb_write_2.tag]      <= 1'b1;
        rob_exception[i_cdb_write_2.tag] <= i_cdb_write_2.exception;
      end

      // ---------------------------------------------------------------------
      // Direct store completion (mark plain store entry done)
      // ---------------------------------------------------------------------
      if (i_store_complete_valid && !i_flush_all && rob_valid[i_store_complete_tag]) begin
        rob_done[i_store_complete_tag] <= 1'b1;
      end

      // ---------------------------------------------------------------------
      // Branch Update (mark branch done)
      // ---------------------------------------------------------------------
      if (branch_wr_en) begin
        rob_done[i_branch_update.tag] <= 1'b1;
      end
    end
  end

  // Keep rob_valid separate so full-flush does not share a single next-state
  // cone with unrelated ROB done/exception updates.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rob_valid <= '0;
    end else begin
      if (i_flush_all) begin
        // Full flush: invalidate all entries
        rob_valid <= '0;
      end else if (i_flush_en) begin
        if (flush_after_head_commit) begin
          // Head-driven recovery leaves no architecturally-live entries in the
          // ROB after the branch boundary.
          rob_valid <= '0;
        end else begin
          // Partial flush: invalidate entries after flush_tag
          for (int i = 0; i < ReorderBufferDepth; i++) begin
            if (rob_valid[i] && should_flush_entry(
                    i[ReorderBufferTagWidth-1:0], i_flush_tag, head_idx
                )) begin
              rob_valid[i] <= 1'b0;
            end
          end
        end
      end

      if (alloc_en_valid) begin
        rob_valid[tail_idx] <= 1'b1;
      end
      if (alloc_en_2_valid) begin
        rob_valid[tail_idx_2] <= 1'b1;
      end

      // Commit deallocation: invalidate the committed entry (head pointer
      // advances separately).  Widen-commit also clears head+1 when the
      // 2-wide gate (commit_2_fire) fires.
      if (commit_en && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_clear_mask[i]) rob_valid[i] <= 1'b0;
        end
      end
      if (commit_2_fire && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_next_clear_mask[i]) rob_valid[i] <= 1'b0;
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Data signals -- no reset needed, gated by alloc_en / branch_wr_en
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    // -------------------------------------------------------------------
    // Allocation Write (multi-write/head-independent data fields)
    // -------------------------------------------------------------------
    if (alloc_en_branch_bits) begin
      rob_branch_taken[tail_idx]    <= 1'b0;
      rob_mispredicted[tail_idx]    <= 1'b0;
      rob_early_recovered[tail_idx] <= 1'b0;

      // JAL has fully known link/target information at allocation time.
      if (i_alloc_req.is_jal) begin
        // For JAL, branch is always taken with known target
        rob_branch_taken[tail_idx] <= 1'b1;
        rob_mispredicted[tail_idx] <= !i_alloc_req.predicted_taken ||
                                      (i_alloc_req.predicted_target != i_alloc_req.branch_target);
      end
    end

    if (alloc_en_2_branch_bits) begin
      rob_branch_taken[tail_idx_2]    <= 1'b0;
      rob_mispredicted[tail_idx_2]    <= 1'b0;
      rob_early_recovered[tail_idx_2] <= 1'b0;

      if (i_alloc_req_2.is_jal) begin
        rob_branch_taken[tail_idx_2] <= 1'b1;
        rob_mispredicted[tail_idx_2] <=
            !i_alloc_req_2.predicted_taken ||
            (i_alloc_req_2.predicted_target != i_alloc_req_2.branch_target);
      end
    end

    // -------------------------------------------------------------------
    // Branch Update (record branch resolution data)
    // -------------------------------------------------------------------
    // For branch/jump instructions only.
    // The mispredicted field from branch unit is authoritative - it knows about
    // RAS/indirect predictor specifics that the ROB doesn't track.
    // branch_target is written via distributed RAM.
    if (branch_wr_en) begin
      rob_branch_taken[i_branch_update.tag] <= i_branch_update.taken;
      rob_mispredicted[i_branch_update.tag] <= i_branch_update.mispredicted;
    end

    // Mark entry as early-recovered (suppresses commit-time re-trigger)
    if (i_early_recovery_en) rob_early_recovered[i_early_recovery_tag] <= 1'b1;
  end

  // ===========================================================================
  // Head Pointer Management
  // ===========================================================================

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      head_ptr             <= '0;
      head_clear_mask      <= ReorderBufferDepth'(1);
      head_next_clear_mask <= ReorderBufferDepth'(2);
    end else if (i_flush_all) begin
      // Full flush: head stays (tail resets to head)
    end else if (commit_en) begin
      // Normal commit: advance head.  Widen-commit advances by 2 when the
      // 2-wide gate fires; otherwise by 1 as before.  commit_2_fire is a
      // strict subset of commit_en so the OR is implicit.
      head_ptr <= head_ptr + ({{ReorderBufferTagWidth - 1{1'b0}}, commit_2_fire, !commit_2_fire});
      head_clear_mask <= advance_onehot_mask(head_clear_mask, commit_2_fire);
      head_next_clear_mask <= advance_onehot_mask(head_next_clear_mask, commit_2_fire);
    end
  end

  // ===========================================================================
  // Serializing Instruction State Machine
  // ===========================================================================
  // Handles WFI, CSR, FENCE, FENCE.I, MRET, and exceptions at Reorder Buffer head

  // Serializing-instruction FSM -> reorder_buffer/rob_serializer.sv (boundary
  // move).  serial_state + commit_stall are received below; consumers (perf,
  // o_csr_start/o_mret_start, asserts) read serial_state via the pkg enum.
  rob_serializer rob_serializer_inst (
      .i_clk               (i_clk),
      .i_rst_n             (i_rst_n),
      .i_flush_all         (i_flush_all),
      .i_flush_en          (i_flush_en),
      .i_commit_hold       (i_commit_hold),
      .i_early_recovery_en (i_early_recovery_en),
      .i_interrupt_pending (i_interrupt_pending),
      .i_sq_committed_empty(i_sq_committed_empty),
      .i_fence_i_sync_done (i_fence_i_sync_done),
      .o_fence_i_sync_req  (o_fence_i_sync_req),
      .i_csr_done          (i_csr_done),
      .i_mret_done         (i_mret_done),
      .i_trap_taken        (i_trap_taken),
      .head_ready          (head_ready),
      .head_exception      (head_exception),
      .head_is_wfi         (head_is_wfi),
      .head_is_csr         (head_is_csr),
      .head_is_fence       (head_is_fence),
      .head_is_fence_i     (head_is_fence_i),
      .head_is_mret        (head_is_mret),
      .head_is_amo         (head_is_amo),
      .head_is_lr          (head_is_lr),
      .o_serial_state      (serial_state),
      .o_commit_stall      (commit_stall)
  );

  // ===========================================================================
  // Commit Enable Logic
  // ===========================================================================

  // Commit when head is ready, no stall, and no flush in progress.
  // The old branch_update collision guard (which delayed commit when a
  // mispredicted branch resolved via CDB in the same cycle as commit) is
  // removed: (a) JAL — the stated motivation — never produces branch_update
  // (is_jal_issue is excluded); (b) for conditional branches, the
  // rob_head_commit_misprediction_candidate check in early_mispredict_fire
  // already blocks the early-recovery race; (c) removing the guard breaks
  // the commit_en ↔ branch_update critical path (19 LUT levels through the
  // CARRY8 branch-target comparison).
  // !i_flush_en is REQUIRED for serializing correctness, not just a flush guard.
  // rob_serializer only recognizes a serial head (CSR/FENCE/FENCE.I/WFI/MRET)
  // while !i_flush_en (rob_serializer.sv SERIAL_IDLE guard).  During an
  // early-backend-recovery / mispredict-recovery bubble (i_flush_en=1) the
  // serializer therefore leaves commit_stall=0 for a head FENCE.I, so without
  // this term commit_en would RETIRE the FENCE.I unserialized -- skipping the
  // cache sync (L1D writeback-all + L1I invalidate-all) entirely and letting a
  // post-fence fetch read pre-fence code (the SMC bug).  Gating commit on
  // !i_flush_en keeps commit_en a subset of the serializer's guard, so a serial
  // head can never RETIRE during the bubble; it commits (and is serialized)
  // after the bubble clears.  The bubble is a fixed hold (early-backend /
  // mispredict recovery), never waiting on the head committing -> no deadlock.
  assign commit_en = head_ready && !head_exception && !commit_stall && !i_commit_hold &&
                     !i_early_recovery_en && !i_flush_en && !i_flush_all &&
                     !flush_after_head_commit;

  // Raw misprediction at commit (early_recovered handled externally by cpu_ooo)
  assign commit_misprediction = head_is_branch && head_mispredicted;
  assign o_commit_valid_raw = commit_en;
  assign o_commit_store_like_raw = commit_en && (head_is_store || head_is_fp_store || head_is_sc);
  assign o_commit_misprediction_raw = commit_en && commit_misprediction && !head_early_recovered;
  assign o_commit_correct_branch_raw = commit_en && head_has_checkpoint &&
                                       !commit_misprediction && !head_early_recovered;
  // Same-cycle head-mispredict indicator without the branch_update collision
  // term. Outer control logic uses this to suppress younger branch resolution
  // without feeding branch_update back into commit_en.
  assign o_head_commit_misprediction_candidate =
      head_ready && !commit_stall && !i_commit_hold && !i_early_recovery_en &&
      !i_flush_en && !i_flush_all && !flush_after_head_commit &&
      commit_misprediction && !head_early_recovered;

  // ===========================================================================
  // External Coordination Outputs
  // ===========================================================================

  // CSR execution signal - asserted when entering CSR_EXEC state
  assign o_csr_start = (serial_state == riscv_pkg::SERIAL_IDLE) && head_ready &&
                       !i_commit_hold &&
                       !i_early_recovery_en &&
                       head_is_csr && !head_exception &&
                       !i_flush_en && !i_flush_all;

  // MRET execution signal - asserted when entering MRET_EXEC and SUSTAINED while
  // waiting there for committed stores to drain.
  //
  // take_mret (trap_unit) only fires when i_sq_committed_empty is high IN THE
  // SAME CYCLE as o_mret_start, and it has no retry. Without the
  // SERIAL_MRET_EXEC sustaining term o_mret_start is a one-cycle pulse on the
  // IDLE->MRET_EXEC cycle: if a committed store is still draining then, take_mret
  // misses its only chance and the serializer wedges in SERIAL_MRET_EXEC forever
  // (no later flush can rescue it -- the stuck MRET never restores MIE, so no
  // interrupt becomes eligible to flush it). The sustaining term mirrors
  // o_trap_pending (below) and lets take_mret retry every cycle until the SQ
  // drains.
  //
  // The i_sq_committed_empty gate keeps o_mret_start (hence i_mret_start ->
  // trap_drain_wait -> i_commit_hold) low during the drain wait, which (a)
  // prevents a commit-hold/o_mret_start f/2 oscillation and (b) keeps mret_taken
  // a single-cycle pulse so flush_all fires exactly once. It is free on the
  // common path: a retiring MRET normally finds the committed SQ already empty.
  //
  // Note: !i_flush_en/!i_flush_all intentionally omitted — flush signals are
  // derived from mret_taken which is derived from o_mret_start, so gating
  // by them creates an oscillating combinational loop.
  assign o_mret_start = ((serial_state == riscv_pkg::SERIAL_IDLE) ||
                         (serial_state == riscv_pkg::SERIAL_MRET_EXEC)) &&
                        head_ready &&
                        !i_commit_hold &&
                        !i_early_recovery_en &&
                        head_is_mret && !head_exception &&
                        i_sq_committed_empty;

  // Trap pending signal - asserted when exception at head.
  // Note: during the IDLE->TRAP_WAIT transition, both the state check and the
  // combinational path assert o_trap_pending simultaneously. This overlap is
  // intentional and benign (result is still 1'b1); the state check sustains
  // the signal while the combinational term covers the initial detection cycle.
  // Note: !i_flush_all intentionally omitted from the combinational term.
  // flush_all is derived from trap_taken which is derived from o_trap_pending;
  // gating by !i_flush_all creates an oscillating combinational loop.
  // The registered term sustains the signal
  // across clock edges; the combinational term provides same-cycle detection.
  assign o_trap_pending =
      (serial_state == riscv_pkg::SERIAL_TRAP_WAIT) ||
      (head_ready && !i_commit_hold && !i_early_recovery_en && head_exception);
  assign o_trap_pc = head_pc;
  // WFI interrupt-resume-PC seed (Bug#2): expose that the ROB head is a WFI so
  // cpu_ooo can seed interrupt_resume_pc = wfi_pc+4 while the WFI stalls at the
  // head. A machine interrupt taken at a *drain-gated* WFI (a committed store
  // still draining) otherwise flushes the WFI before it commits, leaving
  // interrupt_resume_pc at the pre-WFI instruction's next-PC (== the WFI's own
  // PC) -> mepc=wfi_pc instead of the spec-required wfi_pc+4.
  assign o_head_is_wfi = head_is_wfi;
  assign o_trap_cause = head_exc_cause;
  assign o_trap_value = head_value[XLEN-1:0];

  // FENCE.I flush signal - pulse when FENCE.I commits
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fence_i_committed <= 1'b0;
    end else begin
      fence_i_committed <= commit_en && head_is_fence_i;
    end
  end
  assign o_fence_i_flush = fence_i_committed;

  // ===========================================================================
  // Commit Output
  // ===========================================================================

  always_comb begin
    o_commit_comb = '0;

    if (commit_en) begin
      o_commit_comb.valid = 1'b1;
      o_commit_comb.tag = head_idx;
      o_commit_comb.dest_rf = head_dest_rf;
      o_commit_comb.dest_reg = head_dest_reg;
      o_commit_comb.dest_valid = head_dest_valid;
      o_commit_comb.value = head_value_eff;
      o_commit_comb.is_store = head_is_store;
      o_commit_comb.is_fp_store = head_is_fp_store;
      o_commit_comb.exception = head_exception;
      o_commit_comb.pc = head_pc;
      o_commit_comb.exc_cause = head_exc_cause;
      o_commit_comb.fp_flags = head_fp_flags_eff;
      o_commit_comb.has_fp_flags = head_has_fp_flags;

      // Branch misprediction recovery
      o_commit_comb.misprediction = commit_misprediction;
      o_commit_comb.early_recovered = head_early_recovered;
      o_commit_comb.has_checkpoint = head_has_checkpoint;
      o_commit_comb.checkpoint_id = head_checkpoint_id;
      // Redirect PC:
      // - MRET: redirect to mepc
      // - Taken branch/jump: redirect to resolved target
      // - Not-taken branch: redirect to architectural fall-through
      if (head_is_mret) begin
        // i_mepc is guaranteed stable here: the MRET handshake
        // (o_mret_start/i_mret_done) completes before commit_en asserts,
        // so the trap unit has finished updating mepc by this point.
        o_commit_comb.redirect_pc = i_mepc;
      end else if (head_is_branch) begin
        if (head_branch_taken) begin
          o_commit_comb.redirect_pc = head_branch_target;
        end else begin
          o_commit_comb.redirect_pc = head_fallthrough_pc;
        end
      end

      // Branch info (for BTB update and RAS restore at commit)
      o_commit_comb.predicted_taken = head_predicted_taken;
      o_commit_comb.branch_taken    = head_branch_taken;
      o_commit_comb.branch_target   = head_branch_target;
      o_commit_comb.is_branch       = head_is_branch;
      o_commit_comb.is_call         = head_is_call;
      o_commit_comb.is_return       = head_is_return;
      o_commit_comb.is_jal          = head_is_jal;
      o_commit_comb.is_jalr         = head_is_jalr;

      // CSR info (for commit-time serialized CSR execution)
      o_commit_comb.csr_addr        = head_csr_addr;
      o_commit_comb.csr_op          = head_csr_op;
      o_commit_comb.csr_write_data  = head_csr_write_data;

      // Serializing instruction flags (for external units)
      o_commit_comb.is_csr          = head_is_csr;
      o_commit_comb.is_fence        = head_is_fence;
      o_commit_comb.is_fence_i      = head_is_fence_i;
      o_commit_comb.is_wfi          = head_is_wfi;
      o_commit_comb.is_mret         = head_is_mret;
      o_commit_comb.is_amo          = head_is_amo;
      o_commit_comb.is_lr           = head_is_lr;
      o_commit_comb.is_sc           = head_is_sc;
      o_commit_comb.is_compressed   = head_is_branch ? head_link_is_compressed : head_is_compressed;
    end
  end

  // Keep commit visible for a full cycle after the retiring edge so external
  // observers can sample it after the head pointer advances.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) o_commit.valid <= 1'b0;
    else o_commit.valid <= o_commit_comb.valid;

    o_commit.tag <= o_commit_comb.tag;
    o_commit.dest_rf <= o_commit_comb.dest_rf;
    o_commit.dest_reg <= o_commit_comb.dest_reg;
    o_commit.dest_valid <= o_commit_comb.dest_valid;
    o_commit.value <= o_commit_comb.value;
    o_commit.is_store <= o_commit_comb.is_store;
    o_commit.is_fp_store <= o_commit_comb.is_fp_store;
    o_commit.exception <= o_commit_comb.exception;
    o_commit.pc <= o_commit_comb.pc;
    o_commit.exc_cause <= o_commit_comb.exc_cause;
    o_commit.fp_flags <= o_commit_comb.fp_flags;
    o_commit.has_fp_flags <= o_commit_comb.has_fp_flags;
    o_commit.misprediction <= o_commit_comb.misprediction;
    o_commit.early_recovered <= o_commit_comb.early_recovered;
    o_commit.has_checkpoint <= o_commit_comb.has_checkpoint;
    o_commit.checkpoint_id <= o_commit_comb.checkpoint_id;
    o_commit.redirect_pc <= o_commit_comb.redirect_pc;
    o_commit.predicted_taken <= o_commit_comb.predicted_taken;
    o_commit.branch_taken <= o_commit_comb.branch_taken;
    o_commit.branch_target <= o_commit_comb.branch_target;
    o_commit.is_branch <= o_commit_comb.is_branch;
    o_commit.is_call <= o_commit_comb.is_call;
    o_commit.is_return <= o_commit_comb.is_return;
    o_commit.is_jal <= o_commit_comb.is_jal;
    o_commit.is_jalr <= o_commit_comb.is_jalr;
    o_commit.csr_addr <= o_commit_comb.csr_addr;
    o_commit.csr_op <= o_commit_comb.csr_op;
    o_commit.csr_write_data <= o_commit_comb.csr_write_data;
    o_commit.is_csr <= o_commit_comb.is_csr;
    o_commit.is_fence <= o_commit_comb.is_fence;
    o_commit.is_fence_i <= o_commit_comb.is_fence_i;
    o_commit.is_wfi <= o_commit_comb.is_wfi;
    o_commit.is_mret <= o_commit_comb.is_mret;
    o_commit.is_amo <= o_commit_comb.is_amo;
    o_commit.is_lr <= o_commit_comb.is_lr;
    o_commit.is_sc <= o_commit_comb.is_sc;
    o_commit.is_compressed <= o_commit_comb.is_compressed;
  end

  // ===========================================================================
  // Widen-Commit Slot 2 Output (head+1)
  // ===========================================================================
  // Slot 2 is populated whenever commit_2_gate fires.  By construction slot
  // 2 can never be a branch/mispredict/serial/exception/AMO/LR/SC, so most
  // control fields are zeroed; only the regfile-writeback + SQ-release
  // fields (dest_*, value, pc, is_store, is_fp_store, fp_flags, tag,
  // is_compressed, early_recovered) need to carry real data.
  always_comb begin
    o_commit_comb_2 = '0;

    if (commit_2_fire) begin
      o_commit_comb_2.valid           = 1'b1;
      o_commit_comb_2.tag             = head_next_idx;
      o_commit_comb_2.dest_rf         = head_next_dest_rf;
      o_commit_comb_2.dest_reg        = head_next_dest_reg;
      o_commit_comb_2.dest_valid      = head_next_dest_valid;
      o_commit_comb_2.value           = head_next_value_eff;
      o_commit_comb_2.is_store        = head_next_is_store;
      o_commit_comb_2.is_fp_store     = head_next_is_fp_store;
      o_commit_comb_2.exception       = 1'b0;  // gate excludes exceptions
      o_commit_comb_2.pc              = head_next_pc;
      o_commit_comb_2.exc_cause       = '0;
      o_commit_comb_2.fp_flags        = head_next_fp_flags_eff;
      o_commit_comb_2.has_fp_flags    = head_next_has_fp_flags;
      // Slot 2 is never a branch, never mispredicts, never has a checkpoint,
      // never redirects PC.  early_recovered carried for RAT consistency.
      o_commit_comb_2.misprediction   = 1'b0;
      o_commit_comb_2.early_recovered = head_next_early_recovered;
      o_commit_comb_2.has_checkpoint  = 1'b0;
      o_commit_comb_2.checkpoint_id   = '0;
      o_commit_comb_2.redirect_pc     = '0;
      o_commit_comb_2.predicted_taken = 1'b0;
      o_commit_comb_2.branch_taken    = 1'b0;
      o_commit_comb_2.branch_target   = '0;
      o_commit_comb_2.is_branch       = 1'b0;
      o_commit_comb_2.is_call         = 1'b0;
      o_commit_comb_2.is_return       = 1'b0;
      o_commit_comb_2.is_jal          = 1'b0;
      o_commit_comb_2.is_jalr         = 1'b0;
      o_commit_comb_2.csr_addr        = '0;
      o_commit_comb_2.csr_op          = '0;
      o_commit_comb_2.csr_write_data  = '0;
      o_commit_comb_2.is_csr          = 1'b0;
      o_commit_comb_2.is_fence        = 1'b0;
      o_commit_comb_2.is_fence_i      = 1'b0;
      o_commit_comb_2.is_wfi          = 1'b0;
      o_commit_comb_2.is_mret         = 1'b0;
      o_commit_comb_2.is_amo          = 1'b0;
      o_commit_comb_2.is_lr           = 1'b0;
      o_commit_comb_2.is_sc           = 1'b0;
      o_commit_comb_2.is_compressed   = head_next_is_compressed;
    end
  end

  assign o_commit_2_valid_raw = commit_2_fire;
  assign o_commit_2_store_like_raw = commit_2_fire && (head_next_is_store || head_next_is_fp_store);

  // Registered copy of slot 2 commit so external observers can sample it
  // after the head pointer advances.  Mirrors the o_commit register.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) o_commit_2.valid <= 1'b0;
    else o_commit_2.valid <= o_commit_comb_2.valid;

    o_commit_2.tag <= o_commit_comb_2.tag;
    o_commit_2.dest_rf <= o_commit_comb_2.dest_rf;
    o_commit_2.dest_reg <= o_commit_comb_2.dest_reg;
    o_commit_2.dest_valid <= o_commit_comb_2.dest_valid;
    o_commit_2.value <= o_commit_comb_2.value;
    o_commit_2.is_store <= o_commit_comb_2.is_store;
    o_commit_2.is_fp_store <= o_commit_comb_2.is_fp_store;
    o_commit_2.exception <= o_commit_comb_2.exception;
    o_commit_2.pc <= o_commit_comb_2.pc;
    o_commit_2.exc_cause <= o_commit_comb_2.exc_cause;
    o_commit_2.fp_flags <= o_commit_comb_2.fp_flags;
    o_commit_2.has_fp_flags <= o_commit_comb_2.has_fp_flags;
    o_commit_2.misprediction <= o_commit_comb_2.misprediction;
    o_commit_2.early_recovered <= o_commit_comb_2.early_recovered;
    o_commit_2.has_checkpoint <= o_commit_comb_2.has_checkpoint;
    o_commit_2.checkpoint_id <= o_commit_comb_2.checkpoint_id;
    o_commit_2.redirect_pc <= o_commit_comb_2.redirect_pc;
    o_commit_2.predicted_taken <= o_commit_comb_2.predicted_taken;
    o_commit_2.branch_taken <= o_commit_comb_2.branch_taken;
    o_commit_2.branch_target <= o_commit_comb_2.branch_target;
    o_commit_2.is_branch <= o_commit_comb_2.is_branch;
    o_commit_2.is_call <= o_commit_comb_2.is_call;
    o_commit_2.is_return <= o_commit_comb_2.is_return;
    o_commit_2.is_jal <= o_commit_comb_2.is_jal;
    o_commit_2.is_jalr <= o_commit_comb_2.is_jalr;
    o_commit_2.csr_addr <= o_commit_comb_2.csr_addr;
    o_commit_2.csr_op <= o_commit_comb_2.csr_op;
    o_commit_2.csr_write_data <= o_commit_comb_2.csr_write_data;
    o_commit_2.is_csr <= o_commit_comb_2.is_csr;
    o_commit_2.is_fence <= o_commit_comb_2.is_fence;
    o_commit_2.is_fence_i <= o_commit_comb_2.is_fence_i;
    o_commit_2.is_wfi <= o_commit_comb_2.is_wfi;
    o_commit_2.is_mret <= o_commit_comb_2.is_mret;
    o_commit_2.is_amo <= o_commit_comb_2.is_amo;
    o_commit_2.is_lr <= o_commit_comb_2.is_lr;
    o_commit_2.is_sc <= o_commit_comb_2.is_sc;
    o_commit_2.is_compressed <= o_commit_comb_2.is_compressed;
  end

  // ===========================================================================
  // Status Outputs
  // ===========================================================================

  assign o_full = dispatch_full_q;
  assign o_full_for_2 = dispatch_full_for_2_q;
  assign o_empty = empty;
  assign o_count = count;

  // Head entry information for external coordination
  assign o_head_tag = head_idx;
  assign o_head_valid = head_valid;
  assign o_head_done = head_valid && head_done_eff;
  assign o_entry_valid = rob_valid;
  assign o_entry_done = rob_done;

  // Widen-commit diagnostic: compute whether the entry immediately behind
  // the head is also valid and done, so an extra commit slot would have
  // work to do this cycle. head_next_idx is declared with the other
  // head_next_* signals near the top of the module.
  logic head_next_valid_done;
  assign head_next_valid_done = head_next_valid && head_next_done_eff;

  always_comb begin
    o_perf_events = '0;

    o_perf_events.rob_empty = empty;

    if (head_valid && !head_done_eff && !i_flush_all) begin
      o_perf_events.head_wait_total = 1'b1;

      if (head_is_branch) begin
        o_perf_events.head_wait_branch = 1'b1;
      end else if (head_is_amo || head_is_lr) begin
        o_perf_events.head_wait_mem_amo = 1'b1;
      end else if (head_is_store || head_is_fp_store || head_is_sc) begin
        o_perf_events.head_wait_mem_store = 1'b1;
      end else begin
        unique case (head_rs_type)
          riscv_pkg::RS_INT: o_perf_events.head_wait_int = 1'b1;
          riscv_pkg::RS_MUL: o_perf_events.head_wait_mul = 1'b1;
          riscv_pkg::RS_MEM: o_perf_events.head_wait_mem_load = 1'b1;
          riscv_pkg::RS_FP: o_perf_events.head_wait_fp = 1'b1;
          riscv_pkg::RS_FMUL: o_perf_events.head_wait_fmul = 1'b1;
          riscv_pkg::RS_FDIV: o_perf_events.head_wait_fdiv = 1'b1;
          default: ;
        endcase
      end
    end

    if (head_ready && commit_stall && !i_flush_all) begin
      o_perf_events.commit_blocked_csr =
          head_is_csr || (serial_state == riscv_pkg::SERIAL_CSR_EXEC);
      o_perf_events.commit_blocked_fence =
          head_is_fence || head_is_fence_i || (serial_state == riscv_pkg::SERIAL_WAIT_SQ);
      o_perf_events.commit_blocked_wfi =
          head_is_wfi || (serial_state == riscv_pkg::SERIAL_WFI_WAIT);
      o_perf_events.commit_blocked_mret =
          head_is_mret || (serial_state == riscv_pkg::SERIAL_MRET_EXEC);
      o_perf_events.commit_blocked_trap =
          head_exception || (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);
    end

    // Widen-commit viability: single-wide commit is firing this cycle AND
    // the next ROB entry would also be ready to retire. This is an upper
    // bound — the actual win is slightly lower because head+1 being a
    // serial op (CSR/fence/trap) or a mispredicting branch would still
    // force commit to stay 1-wide on that cycle.
    o_perf_events.head_and_next_done = commit_en && head_next_valid_done;
    // Ungated version: the entry behind head is done whether or not commit
    // is firing this cycle. Subtract head_and_next_done to see how often
    // the ROB is sitting on a done entry behind a stalled head.
    o_perf_events.head_plus_one_done = head_next_valid_done && !i_flush_all;
    // Widen-commit fire-rate predictor: tighter than head_and_next_done
    // because the hazard gate (serial ops, head+1 branches, FENCE.I,
    // exceptions, AMO/LR/SC, head-mispredicting-branches) is already
    // applied.  commit_2_fire_actual additionally folds in the master
    // enable and the cpu_ooo pending-write FIFO back-pressure term
    // (i_widen_commit_ok) — this is what the head_ptr increment and
    // rob_valid clear actually use.
    o_perf_events.commit_2_opportunity = commit_2_gate;
    o_perf_events.commit_2_fire_actual = commit_2_fire;

    // Widen-commit blocker decomposition. Gated on commit_en &&
    // head_next_valid_done so these only fire on cycles where head_and_
    // next_done is also 1 — the sum equals head_and_next_done -
    // commit_2_opportunity (the hazard-blocked gap).
    o_perf_events.commit_2_blocked_head_serial =
        commit_en && head_next_valid_done && !head_ok_2wide;
    o_perf_events.commit_2_blocked_next_serial =
        commit_en && head_next_valid_done && head_ok_2wide &&
        !head_next_ok_2wide && !head_next_is_branch;
    o_perf_events.commit_2_blocked_next_branch_mispred =
        commit_en && head_next_valid_done && head_ok_2wide &&
        head_next_is_branch && head_next_mispredicted;
    o_perf_events.commit_2_blocked_next_branch_correct =
        commit_en && head_next_valid_done && head_ok_2wide &&
        head_next_is_branch && !head_next_mispredicted;
  end

  // ===========================================================================
  // Reorder Buffer Entry Read Interface (for RAT bypass)
  // ===========================================================================

  assign o_read_done = rob_valid[i_read_tag] && rob_done[i_read_tag];
  // o_read_value is driven by u_rob_value_rat distributed RAM instance

  // ===========================================================================
  // Assertions (Simulation Only)
  // ===========================================================================

`ifndef SYNTHESIS
`ifndef FORMAL

  // Retire trace: log every committed instruction (for debugging)
  integer retire_trace_fd;
  initial begin
    retire_trace_fd = $fopen("retire_trace.log", "w");
  end
  always @(posedge i_clk) begin
    if (i_rst_n && commit_en) begin
      if (head_dest_valid && !head_dest_rf && head_dest_reg != 5'd0)
        $fwrite(
            retire_trace_fd,
            "%0t pc=%08x rd=x%0d val=%08x\n",
            $time,
            head_pc,
            head_dest_reg,
            head_value_eff[31:0]
        );
      else $fwrite(retire_trace_fd, "%0t pc=%08x\n", $time, head_pc);
    end
  end

  // Check that we don't allocate when full
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && full) begin
      $error("Reorder Buffer: Allocation attempted when full!");
    end
  end

  // Slot-2 must respect the "slot-1 also valid" contract and the full_for_2 gate.
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req_2.alloc_valid && !i_alloc_req.alloc_valid) begin
      $error("Reorder Buffer: Slot-2 alloc valid without slot-1!");
    end
  end
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req_2.alloc_valid && full_for_2) begin
      $error("Reorder Buffer: Slot-2 alloc attempted when full_for_2!");
    end
  end

  // Check that dispatch doesn't allocate during flush (invariant: dispatch must be stalled)
  // Note: alloc_ready also deasserts during flush, but dispatch should be independently stalled
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)) begin
      $error("Reorder Buffer: Allocation attempted during flush!");
    end
  end
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req_2.alloc_valid && (i_flush_en || i_flush_all)) begin
      $error("Reorder Buffer: Slot-2 alloc attempted during flush!");
    end
  end

  // Check that CDB writes target valid entries (unless a flush just happened).
  // The CDB is pipelined (registered in tomasulo_wrapper), so the CDB may
  // present results for entries that were flushed between capture and delivery.
  // This is harmless: cdb_state_wr_en gates all FF/RAM writes on rob_valid.
  logic dbg_flush_prev_cycle;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_flush_prev_cycle <= 1'b0;
    else dbg_flush_prev_cycle <= i_flush_all || i_flush_en || dbg_flush_prev_cycle;
  end
  // With age-based partial flush, stale CDB results from younger-flushed
  // instructions can arrive 2+ cycles after flush. The actual write is
  // gated by rob_valid, so this is functionally harmless.
  always @(posedge i_clk) begin
    if (i_rst_n && i_cdb_write.valid && !rob_valid[i_cdb_write.tag] &&
        !dbg_flush_prev_cycle && !i_flush_all && !i_flush_en) begin
      $warning("Reorder Buffer: CDB write to invalid entry tag=%0d (ignored)", i_cdb_write.tag);
    end
  end

  // Check that branch updates target valid entries
  always @(posedge i_clk) begin
    if (i_rst_n && i_branch_update.valid && !rob_valid[i_branch_update.tag] &&
        !dbg_flush_prev_cycle && !i_flush_all && !i_flush_en) begin
      $warning("Reorder Buffer: Branch update to invalid entry tag=%0d (ignored)",
               i_branch_update.tag);
    end
  end

  // Check serialization state transitions are valid
  always @(posedge i_clk) begin
    if (i_rst_n && serial_state != riscv_pkg::SERIAL_IDLE && !head_ready) begin
      $warning("Reorder Buffer: Serialization state %0d but head not ready", serial_state);
    end
  end

`endif  // FORMAL

`endif  // SYNTHESIS

  // ===========================================================================
  // Formal Verification
  // ===========================================================================

`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Force reset to deassert after the initial cycle and stay deasserted.
  // Without this, the solver can hold i_rst_n low forever, making all
  // i_rst_n-gated asserts vacuously true.
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------
  // These are interface contracts — the upstream dispatch/CDB/branch units
  // guarantee these conditions. They are intentionally kept as assumes
  // (not relaxed) because the ROB's correctness depends on them.

  // CDB write and branch update cannot target the same tag simultaneously
  always_comb begin
  end

  // alloc_valid not asserted during flush (matches existing simulation assertion)
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
    assume (!(i_alloc_req.alloc_valid && full));
    assume (!(i_alloc_req_2.alloc_valid && !i_alloc_req.alloc_valid));
    assume (!(i_alloc_req_2.alloc_valid && full_for_2));
    assume (!(i_alloc_req_2.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // -------------------------------------------------------------------------
  // Combinational properties (asserts, active when i_rst_n)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // full and empty cannot both be true
      p_full_empty_mutex : assert (!(full && empty));

      // count == tail_ptr - head_ptr
      p_count_consistent : assert (count == (tail_ptr - head_ptr));

      // full iff pointers match with different MSB
      p_full_matches_ptrs :
      assert (full ==
        ((head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
         (head_idx == tail_idx)));

      // empty iff pointers exactly equal
      p_empty_matches_ptrs : assert (empty == (head_ptr == tail_ptr));

      // alloc_en implies !full
      p_alloc_not_when_full : assert (!alloc_en || !full);

      // commit_en implies head_valid && head_done_eff (head_done_eff folds in the
      // same-cycle CDB bypass: when commit fires from a CDB write arriving this
      // cycle, the stored rob_done is still 0 until the next clock edge).
      p_commit_requires_valid_done : assert (!commit_en || (head_valid && head_done_eff));

      // commit output tag equals head_idx
      p_commit_only_at_head : assert (!commit_en || (o_commit_comb.tag == head_idx));

      // commit_stall implies !commit_en
      p_serial_stall_blocks_commit : assert (!commit_stall || !commit_en);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential properties (asserts, require f_past_valid)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // After allocation, rob_valid at $past(tail_idx) is set
      if ($past(alloc_en)) begin
        p_alloc_sets_valid : assert (rob_valid[$past(tail_idx)]);
      end

      // After commit, rob_valid at $past(head_idx) is cleared
      if ($past(commit_en) && !$past(i_flush_all)) begin
        p_commit_clears_valid : assert (!rob_valid[$past(head_idx)]);
      end

      // After flush_all, buffer is empty
      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (empty);
      end

      // o_csr_start only in IDLE with CSR at head
      if ($past(o_csr_start)) begin
        p_csr_start_contract :
        assert ($past(serial_state) == riscv_pkg::SERIAL_IDLE && $past(head_is_csr));
      end

      // o_mret_start only in IDLE with MRET at head
      if ($past(o_mret_start)) begin
        p_mret_start_contract :
        assert ($past(serial_state) == riscv_pkg::SERIAL_IDLE && $past(head_is_mret));
      end

      // o_fence_i_flush is registered (one cycle after commit of FENCE.I)
      p_fence_i_flush_delayed :
      assert (o_fence_i_flush == ($past(commit_en) && $past(head_is_fence_i)));
    end

    // Reset properties (check state after reset deasserts)
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      // After reset, all rob_valid bits are 0
      p_reset_clears_valid : assert (rob_valid == '0);

      // After reset, head_ptr and tail_ptr are 0
      p_reset_clears_ptrs : assert (head_ptr == '0 && tail_ptr == '0);

      // After reset, serial_state is IDLE
      p_reset_serial_idle : assert (serial_state == riscv_pkg::SERIAL_IDLE);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Allocation and commit in same cycle
      cover_alloc_and_commit : cover (alloc_en && commit_en);

      // Buffer reaches full state
      cover_buffer_full : cover (full);

      // Partial flush occurs
      cover_partial_flush : cover (i_flush_en);

      // CSR serialization completes
      cover_csr_serialize : cover (serial_state == riscv_pkg::SERIAL_CSR_EXEC && i_csr_done);

      // WFI wakes on interrupt
      cover_wfi_wakeup : cover (serial_state == riscv_pkg::SERIAL_WFI_WAIT && i_interrupt_pending);

      // MRET completes
      cover_mret_complete : cover (serial_state == riscv_pkg::SERIAL_MRET_EXEC && i_mret_done);

      // FENCE.I cache sync completes
      cover_fence_i_sync_complete :
      cover (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC && i_fence_i_sync_done);

      // Exception triggers trap
      cover_exception_trap : cover (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);

      // FENCE.I commit generates flush pulse
      cover_fence_i_flush : cover (o_fence_i_flush);
    end
  end

`endif  // FORMAL

endmodule : reorder_buffer
