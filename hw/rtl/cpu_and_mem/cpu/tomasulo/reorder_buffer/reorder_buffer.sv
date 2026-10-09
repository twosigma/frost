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
 * Reorder buffer: 32 entries shared by integer and FP instructions, allocated
 * and retired up to two per cycle in program order. An entry's index is its
 * ROB tag. Entries complete at allocation (JAL, FENCE, FENCE.I, WFI, xRET), on
 * either CDB lane, on a branch update, or, for plain stores, on the
 * store-completion port. rob_serializer holds the following at the head:
 *   - CSR: raises o_csr_start and retires on i_csr_done. A translation CSR
 *     retires in a later cycle, once committed stores have drained, and ends
 *     in a full flush. The CSR file reads and writes the register the cycle
 *     after retirement, from the registered commit bus.
 *   - FENCE: waits for committed stores to drain (i_sq_committed_empty).
 *   - FENCE.I, SFENCE.VMA: drain, cache sync (SFENCE.VMA also invalidates the
 *     TLBs), then a full flush and refetch.
 *   - MRET/SRET/DRET: once committed stores drain, o_mret_start; the trap
 *     unit redirects to mepc/sepc/dpc.
 *   - WFI: waits for i_interrupt_pending.
 *   - Exception: o_trap_pending until the trap unit takes it.
 * LR executes only at the head, AMO and SC only at the head with committed
 * stores drained. FP exception flags reach fcsr at retirement.
 *
 * Multi-bit fields and the packed head metadata live in distributed RAM; a
 * RAM with several write ports keeps one bank per port and a live value
 * table (LVT). Per-entry bits that reset or a flush must clear stay in
 * flip-flops, as do the class bits the commit logic reads early.
 */

// Preserve the hierarchy to keep commit-strobe synthesis local.
(* keep_hierarchy = "yes" *)
module reorder_buffer #(
    // Check for CDB writes in the cycle after allocation, while the LVT drains.
    // The full pipeline cannot complete that soon. Direct-drive unit tests can
    // disable the check through tests/Makefile.
    parameter bit DrainWindowCheck = 1'b1,
    // Share one allocation link bank per value RAM. Requires at most one
    // branch allocation per cycle, since the slots target different entries.
    // cpu_ooo enables this; its dispatch blocks slot 2 behind a slot-1 branch.
    // The default per-slot banks accept any allocation pair.
    parameter bit SharedLinkBank   = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // Slot 2 follows slot 1 at tail_idx+1 and requires slot 1 to allocate.
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req_2,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp_2,

    // =========================================================================
    // CDB Write Interface (from Functional Units via CDB)
    // =========================================================================
    // Functional-unit results (ALU, MUL, DIV, MEM, FP). Conditional branches
    // complete on i_branch_update instead.
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write,
    // Second CDB lane, handled like the first in the same cycle. The arbiter
    // grants the two lanes to different functional units, and an in-flight
    // tag has only one producer, so the lane tags differ and the lanes never
    // collide on a RAM address or a rob_done bit.
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write_2,
    // Duplicates of the CDB tags, registered in tomasulo_wrapper for fanout.
    // They must equal the shared tags; only head and head+1 bypass compares use them.
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_cdb_match_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_cdb_match_tag_2,

    // Direct non-CDB completion for plain stores. Stores do not need wakeup or
    // a CDB value broadcast; the ROB only needs to know the entry is done.
    input logic                                        i_store_complete_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_store_complete_tag,

    // =========================================================================
    // Branch Update Interface (from Branch Unit)
    // =========================================================================
    // Separate from the CDB: branch/jump resolution only.
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
    // Slot-2 mirror: a correctly-predicted checkpointed branch retiring at
    // head+1 this cycle (drives the second checkpoint-free / BTB-training
    // capture path).
    output logic                              o_commit_correct_branch_2_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // Slot-2 commit at head+1; valid and payload are zero when it does not fire.
    // It excludes serial ops, exceptions, AMO/LR/SC and mispredicted or
    // early-recovered branches. Correctly predicted branches may retire here;
    // redirect_pc carries the architectural next PC, but misprediction is zero.
    output riscv_pkg::reorder_buffer_commit_t o_commit_2,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb_2,
    output logic                              o_commit_2_valid_raw,
    output logic                              o_commit_2_store_like_raw,

    // Slot-2 permission from cpu_ooo. It is low only during a debugger single
    // step, so exactly one instruction retires before the halt.
    input logic i_widen_commit_ok,
    input logic i_commit_hold,

    // =========================================================================
    // Store Queue Coordination
    // =========================================================================
    input  logic i_sq_committed_empty,  // No committed entries pending write (for FENCE)
    // FENCE.I cache-sync handshake (see rob_serializer): request held while
    // the serializer waits; done is a level while the request is high.
    input  logic i_fence_i_sync_done,
    output logic o_fence_i_sync_req,

    // =========================================================================
    // CSR Unit Coordination
    // =========================================================================
    // Start a ready CSR head on entry to CSR_EXEC; see the serialization rules above.
    output logic o_csr_start,
    input  logic i_csr_done,

    // =========================================================================
    // Trap/Exception Handling
    // =========================================================================
    // Exception at head: signal the trap unit.
    output logic o_trap_pending,  // Exception needs handling
    output logic [riscv_pkg::XLEN-1:0] o_trap_pc,  // PC of excepting instruction
    // Head decodes as WFI (drives WFI interrupt-resume-PC seed in cpu_ooo)
    output logic o_head_is_wfi,
    // Head decodes as AMO. Drives the trap unit's AMO interrupt shield in
    // cpu_ooo: an interrupt must not flush an AMO whose memory write may
    // already be in flight (see trap_unit.i_amo_at_head).
    output logic o_head_is_amo,
    // Register-file bypass enables, qualified externally by the corresponding
    // raw commit fire. They are unspecified when that fire is low.
    output logic o_head_bypass_int_we_early,
    output logic o_head_bypass_fp_we_early,
    output logic o_head_next_bypass_int_we_early,
    output logic o_head_next_bypass_fp_we_early,
    // Same pattern for the direction-predictor training qualifiers: the
    // conditional-branch class and resolved direction of head and head+1.
    output logic o_head_dir_train_early,
    output logic o_head_branch_taken_early,
    output logic o_head_next_dir_train_early,
    output logic o_head_next_branch_taken_early,
    // Architectural next PC for interrupt resume and FENCE-class refetch.
    // Valid on the corresponding raw commit fire for non-xRET entries, when
    // it equals cpu_ooo's retired_next_pc() of the commit packet. In the full
    // core, xRET uses a full flush and never retires on these raw fires.
    output logic [riscv_pkg::XLEN-1:0] o_head_retired_next_pc,
    output logic [riscv_pkg::XLEN-1:0] o_head_next_retired_next_pc,
    output riscv_pkg::exc_cause_t o_trap_cause,  // Exception cause
    // The head entry's value field. For instruction access and page faults,
    // and for data misaligned, access, and page faults, the producer parks the
    // faulting virtual address here and cpu_ooo writes it to mtval or stval.
    output logic [riscv_pkg::XLEN-1:0] o_trap_value,
    input logic i_trap_taken,  // Trap unit has taken the trap

    // xRET coordination. o_mret_start covers MRET, SRET, and DRET;
    // o_mret_start_is_sret and o_mret_start_is_dret say which, so cpu_ooo can
    // split it into the trap unit's i_mret_start, i_sret_start, and
    // i_dret_start.
    output logic                       o_mret_start,          // Signal trap unit to handle xRET
    output logic                       o_mret_start_is_sret,
    output logic                       o_mret_start_is_dret,
    input  logic                       i_mret_done,           // xRET handling complete
    input  logic [riscv_pkg::XLEN-1:0] i_mepc,                // MRET return PC from csr_file
    input  logic [riscv_pkg::XLEN-1:0] i_sepc,                // SRET return PC from csr_file
    input  logic [riscv_pkg::XLEN-1:0] i_dpc,                 // DRET return PC from csr_file

    // =========================================================================
    // Interrupt Interface (for WFI)
    // =========================================================================
    input logic i_interrupt_pending,  // Interrupt is pending (wake from WFI)

    // Current privilege (PrivM/PrivS/PrivU). The allocation legality snapshot
    // marks an xRET or CSR requiring more privilege as illegal.
    input logic [1:0] i_priv,

    // Pre-composed legality bits from csr_file (see its port comment). They are
    // sampled when each ROB entry allocates. CSR writes serialize younger
    // allocation, and privilege/Debug-Mode changes interpose a flushing
    // trap/xRET, so the snapshot remains exact for every surviving entry.
    input logic [2:0] i_counter_blocked,
    // Sstc: S-mode stimecmp access with menvcfg.STCE=0 is illegal.
    input logic i_stimecmp_blocked,
    input logic i_sret_illegal,
    input logic i_sfence_illegal,
    input logic i_wfi_illegal,
    input logic i_priv_is_u,
    // Debug Mode: DRET and the debug CSRs (dcsr, dpc, dscratch0/1, ddata) are
    // legal only in Debug Mode. The allocation legality check samples this
    // registered bit; it changes only through a flushing trap or DRET.
    input logic i_debug_mode,

    // mcounteren counter-enable bits from csr_file ([0]=CY/cycle, [1]=TM/time,
    // [2]=IR/instret). Unused here: allocation legality uses the
    // privilege-resolved i_counter_blocked instead.
    input logic [2:0] i_mcounteren,

    // mstatus.FS == Off from csr_file. The allocation legality snapshot
    // marks any FP instruction or fflags/frm/fcsr access illegal while it is
    // set; ID also marks F/D instructions illegal then, which keeps FP loads
    // and stores out of the memory pipeline. CSR writes serialize; hardware
    // Dirty-setting only moves FS away from Off.
    input logic i_mstatus_fs_off,

    // frm from csr_file. An FP instruction whose rm field selects the dynamic
    // rounding mode (dispatch pre-decodes it as the request's fp_dyn_rm)
    // reads it, and frm values 5 to 7 are reserved: the allocation legality
    // snapshot marks such an instruction illegal. Only CSR writes change frm,
    // and they serialize.
    input logic [2:0] i_frm,

    // =========================================================================
    // Pipeline Flush Control
    // =========================================================================
    // i_flush_en: branch recovery, a partial flush of the entries younger than
    // i_flush_tag. With i_flush_after_head_commit (commit-time recovery: the
    // branch retired the cycle before) every entry is flushed.
    // i_flush_all: full flush for a trap, an xRET, or FENCE-class recovery.
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,  // Flush entries after this tag
    input logic i_flush_all,  // Flush every entry
    input logic i_flush_after_head_commit,
    // Memory-order replay: loads to flag when a DMA write invalidates a line
    // they observed, from the wrapper's lq_coherence_port. A flagged entry is
    // exceptional at the head with cause ExcMemReplay; the trap unit restarts
    // it at its own PC.
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_replay_set_mask,

    // FENCE-class recovery (FENCE.I, SFENCE.VMA, translation CSRs) ends in a
    // full flush. o_fence_class_flush_event marks the event and
    // o_fence_i_flush is the same signal a cycle later; the flush controller
    // also registers the event into its full-flush pulse.
    output logic o_fence_i_flush,
    output logic o_fence_class_flush_event,
    // One-cycle registered shadow between a translation CSR's raw retirement
    // and its final flush. cpu_ooo uses it only to defer trap entry until the
    // registered commit bus has written the CSR file.
    output logic o_translation_csr_commit_shadow,
    // Head SFENCE.VMA is holding the cache-sync window (TLB invalidate).
    output logic o_sfence_window,

    // =========================================================================
    // Early Misprediction Recovery
    // =========================================================================
    // Marks the entry as early-recovered so commit skips re-triggering flush
    input logic                                        i_early_recovery_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_recovery_tag,

    // =========================================================================
    // Status Outputs
    // =========================================================================
    output logic                                      o_full,
    // Registered: fewer than two entries free, so a two-slot bundle cannot
    // fit. It counts this cycle's allocations but not its commits, so it can
    // stay set for a cycle after retirement frees room.
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
    // Dispatch Bypass Read Ports (async value read for renamed-but-done sources)
    // =========================================================================
    // Channels 1-3: slot-1 sources. Channels 4-6: slot-2 sources.
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
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_6
);

  // ===========================================================================
  // Local Parameters (from package)
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned ReorderBufferDepth = riscv_pkg::ReorderBufferDepth;
  localparam int unsigned ReorderBufferCountWidth = ReorderBufferTagWidth + 1;
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned ExcCauseWidth = riscv_pkg::ExcCauseWidth;
  localparam int unsigned FpFlagsWidth = 5;  // $bits(riscv_pkg::fp_flags_t): nv,dz,of,uf,nx
  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;
  localparam int unsigned RsTypeWidth = 3;
  localparam int unsigned HeadMetaWidth = 21 + RsTypeWidth;

  // Two-wide commit enable. With 0 the ROB retires at most one entry per
  // cycle: commit_2_fire stays low, so o_commit_comb_2 never goes valid,
  // while the commit_2_opportunity perf counter still counts.
  localparam bit EnableWidenCommit = 1'b1;

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // True when entry_idx is younger than flush_tag, measured from head.
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
      advance_onehot_mask[(i+(advance_two ? 2 : 1))%ReorderBufferDepth] = mask[i];
    end
  endfunction

  // Read a packed FF vector with a registered one-hot select. Requires
  // onehot == (1 << idx), under which the result equals vec[idx].
  function automatic logic onehot_read(input logic [ReorderBufferDepth-1:0] vec,
                                       input logic [ReorderBufferDepth-1:0] onehot);
    onehot_read = |(vec & onehot);
  endfunction

  // One-hot {IR, TM, CY}, in mcounteren bit order, for a CSR access to the
  // Zicntr user counters cycle, time, or instret (0xC00-0xC02); addr[1:0]
  // picks the bit. Nothing else matches. The RV32 high halves and the user
  // hpmcounters (0xC03-0xC1F; no Zihpm) do not exist here, so
  // csr_static_illegal rejects them, and the machine aliases (0xBxx) have
  // their own privilege check in alloc_legality_fault.
  function automatic logic [2:0] ucounter_onehot(input logic is_csr, input logic [11:0] addr);
    logic m;
    // Assign the function name: the Yosys SV frontend rejects return concatenations.
    m = is_csr && (addr[11:8] == 4'hC) && (addr[6:2] == 5'b0) && !addr[7];
    ucounter_onehot = {
      m && (addr[1:0] == 2'b10), m && (addr[1:0] == 2'b01), m && (addr[1:0] == 2'b00)
    };
  endfunction

  // The machine HPM counters mhpmcounter3..31 (0xB03-0xB1F) and their event
  // selectors mhpmevent3..31 (0x323-0x33F). FROST counts no HPM events, but
  // the privileged spec defines all 29 pairs and makes a read-only-zero pair
  // the minimum legal implementation, so they exist: csr_file's read mux
  // returns 0 for them and no write arm matches them. Both ranges are M-only
  // by address. OpenSBI finds a counter by writing 1 and reading it back, so
  // a zero counter is not advertised.
  function automatic logic csr_is_mhpm(input logic [11:0] addr);
    csr_is_mhpm = ((addr[11:5] == 7'b1011_000) || (addr[11:5] == 7'b0011_001)) &&
                  (addr[4:0] >= 5'd3);
  endfunction

  // CSR existence map. An access to an address outside this set raises
  // illegal-instruction at every privilege, as the privileged spec requires.
  // OpenSBI probes optional CSRs by catching that trap, so reading
  // unimplemented CSRs as zero would advertise missing features.
  // senvcfg exists with no fields (RAZ/WI; S/U make it mandatory), and the
  // read-only id registers mvendorid/marchid/mimpid/mconfigptr exist and
  // read 0. The machine HPM counters and event selectors (csr_is_mhpm) exist
  // and read 0 with writes ignored.
  function automatic logic csr_addr_exists(input logic [11:0] addr);
    unique case (addr)
      // F extension
      riscv_pkg::CsrFflags, riscv_pkg::CsrFrm, riscv_pkg::CsrFcsr,
      // Zicntr user counters (64-bit; the RV32 high halves do not exist)
      riscv_pkg::CsrCycle, riscv_pkg::CsrTime, riscv_pkg::CsrInstret,
      // Supervisor CSRs
      riscv_pkg::CsrSstatus, riscv_pkg::CsrSie, riscv_pkg::CsrStvec,
      riscv_pkg::CsrScounteren, riscv_pkg::CsrSenvcfg, riscv_pkg::CsrSscratch,
      riscv_pkg::CsrSepc, riscv_pkg::CsrScause, riscv_pkg::CsrStval,
      riscv_pkg::CsrSip, riscv_pkg::CsrSatp, riscv_pkg::CsrStimecmp,
      // Machine CSRs
      riscv_pkg::CsrMstatus, riscv_pkg::CsrMisa, riscv_pkg::CsrMedeleg,
      riscv_pkg::CsrMideleg, riscv_pkg::CsrMie, riscv_pkg::CsrMtvec,
      riscv_pkg::CsrMcounteren, riscv_pkg::CsrMcountinhibit, riscv_pkg::CsrMenvcfg,
      riscv_pkg::CsrMscratch,
      riscv_pkg::CsrMepc, riscv_pkg::CsrMcause, riscv_pkg::CsrMtval,
      riscv_pkg::CsrMip,
      // Debug-mode CSRs (legal only in Debug Mode; allocation legality
      // raises illegal-instruction elsewhere)
      riscv_pkg::CsrDcsr, riscv_pkg::CsrDpc, riscv_pkg::CsrDscratch0,
      riscv_pkg::CsrDscratch1, riscv_pkg::CsrDdata,
      // Machine counters (M aliases, writable from M-mode)
      riscv_pkg::CsrMcycle, riscv_pkg::CsrMinstret,
      // Machine id registers (read-only zero) + mhartid
      12'hF11, 12'hF12, 12'hF13, riscv_pkg::CsrMhartid, 12'hF15,
      // Custom profiling CSRs
      riscv_pkg::CsrMperfSel, riscv_pkg::CsrMperfCtl, riscv_pkg::CsrMperfData,
      riscv_pkg::CsrMperfDataH, riscv_pkg::CsrMperfCount:
      csr_addr_exists = 1'b1;
      default: csr_addr_exists = csr_is_mhpm(addr);
    endcase
  endfunction

  // The privileged spec requires unimplemented CSRs to trap in every mode,
  // including RV32-only counter high halves (0xC80-0xC82, 0xB80, 0xB82).
  // Zicsr also forbids write-intending accesses to read-only CSRs
  // (addr[11:10] == 2'b11).
  function automatic logic csr_static_illegal(input logic is_csr, input logic [11:0] addr,
                                              input logic write_intent);
    csr_static_illegal =
        (is_csr && write_intent && (addr[11:10] == 2'b11)) || (is_csr && !csr_addr_exists(addr));
  endfunction


  // FS Off forbids every F/D instruction, including flagless integer-result
  // ops, and accesses to fflags, frm and fcsr (0x001-0x003).
  function automatic logic fs_gated_op(input logic is_fp, input logic is_csr,
                                       input logic [11:0] addr);
    fs_gated_op = is_fp || (is_csr && (addr[11:2] == 10'b0) && (addr[1:0] != 2'b00));
  endfunction

  // Allocation legality remains valid until retirement: CSRs block younger
  // dispatch until their write, and trap, xRET and Debug-Mode transitions
  // flush younger entries. Hardware only changes FS toward Dirty; only CSR
  // writes change frm. Store the result in rob_exception for commit.
  function automatic logic alloc_legality_fault(input riscv_pkg::reorder_buffer_alloc_req_t req);
    logic needs_m_priv;
    logic needs_s_priv;
    logic is_debug_csr;
    logic is_satp_csr;
    logic is_stimecmp_csr;
    logic [2:0] ucounter_sel;
    begin
      needs_m_priv =
          (req.is_mret && !req.is_sret && !req.is_dret) ||
          (req.is_csr && (req.csr_addr[9:8] == 2'b11));
      needs_s_priv = req.is_sret || req.is_sfence_vma ||
          (req.is_csr && (req.csr_addr[9:8] == 2'b01));
      is_debug_csr = req.is_csr && (req.csr_addr[11:4] == 8'h7B);
      is_satp_csr = req.is_csr && (req.csr_addr == riscv_pkg::CsrSatp);
      is_stimecmp_csr = req.is_csr && (req.csr_addr == riscv_pkg::CsrStimecmp);
      ucounter_sel = ucounter_onehot(req.is_csr, req.csr_addr);

      alloc_legality_fault =
          (needs_m_priv && (i_priv != riscv_pkg::PrivM)) ||
          (needs_s_priv && i_priv_is_u) ||
          (is_stimecmp_csr && i_stimecmp_blocked) ||
          (|(ucounter_sel & i_counter_blocked)) ||
          (req.is_sret && i_sret_illegal) ||
          (req.is_dret && !i_debug_mode) ||
          (is_debug_csr && !i_debug_mode) ||
          ((req.is_sfence_vma || is_satp_csr) && i_sfence_illegal) ||
          (req.is_wfi && i_wfi_illegal) ||
          csr_static_illegal(req.is_csr, req.csr_addr, req.csr_write_intent) ||
          (fs_gated_op(req.is_fp_instruction, req.is_csr, req.csr_addr) && i_mstatus_fs_off) ||
          (req.fp_dyn_rm && (i_frm > riscv_pkg::FRM_RMM));
    end
  endfunction

  // Forward declarations for debug outputs; limit head-pointer fanout.
  (* max_fanout = 96 *) logic [ReorderBufferTagWidth:0] head_ptr;
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

  // Bits needing reset or flush stay in FFs; multi-bit fields use RAM.
  // Limit rob_valid fanout to the RAT, stations and core control.
  (* max_fanout = 32 *) logic [ReorderBufferDepth-1:0] rob_valid;
  logic [ReorderBufferDepth-1:0] rob_done;
  logic [ReorderBufferDepth-1:0] rob_exception;
  logic [ReorderBufferDepth-1:0] rob_replay;  // memory-order replay flags
  logic [ReorderBufferDepth-1:0] rob_branch_taken;
  logic [ReorderBufferDepth-1:0] rob_mispredicted;
  logic [ReorderBufferDepth-1:0] rob_early_recovered;

  // Allocation-written class bits duplicate the metadata RAM for commit.
  // They need no reset: consumers qualify them with rob_valid.
  logic [ReorderBufferDepth-1:0] rob_f_store_like;  // is_store|is_fp_store|is_sc
  logic [ReorderBufferDepth-1:0] rob_f_is_branch;
  logic [ReorderBufferDepth-1:0] rob_f_has_checkpoint;
  logic [ReorderBufferDepth-1:0] rob_f_is_csr;
  logic [ReorderBufferDepth-1:0] rob_f_is_fence;
  logic [ReorderBufferDepth-1:0] rob_f_is_fence_i;
  logic [ReorderBufferDepth-1:0] rob_f_is_wfi;
  logic [ReorderBufferDepth-1:0] rob_f_is_mret;
  logic [ReorderBufferDepth-1:0] rob_f_is_amo;
  logic [ReorderBufferDepth-1:0] rob_f_is_lr;
  // Predecoded performance-counter classes. They do not affect retirement
  // or any other architectural decision.
  logic [ReorderBufferDepth-1:0] rob_f_perf_wait_int;
  logic [ReorderBufferDepth-1:0] rob_f_perf_wait_mem_load;
  // !(is_branch|is_csr|is_fence|is_fence_i|is_wfi|is_mret): the head CDB
  // bypass exclusion set folded into one bit.
  logic [ReorderBufferDepth-1:0] rob_f_cdb_bypass_ok;
  // !(is_csr|is_fence|is_fence_i|is_wfi|is_mret|is_amo|is_lr|is_sc): the
  // static (allocation-known) part of the 2-wide commit hazard gates.
  logic [ReorderBufferDepth-1:0] rob_f_ok_2wide_static;
  // Subtype bits. SRET and DRET also set is_mret and select the xRET start
  // and return PC; SFENCE.VMA also sets is_fence_i and opens the serializer's
  // o_sfence_window.
  logic [ReorderBufferDepth-1:0] rob_f_is_sret;
  logic [ReorderBufferDepth-1:0] rob_f_is_dret;
  logic [ReorderBufferDepth-1:0] rob_f_is_sfence;
  // Conservative allocation-time class of CSRs that may change address
  // translation: any satp access, and an mstatus/sstatus access with
  // architectural write intent. id_stage's mstatus.FS=Off check also relies
  // on this class: the full flush that ends every such write discards whatever
  // ID decoded under the old FS value.
  logic [ReorderBufferDepth-1:0] rob_f_csr_may_change_translation;


  // Derived pointer values (without wrap bit)
  logic [ReorderBufferTagWidth-1:0] head_idx;
  logic [ReorderBufferTagWidth-1:0] tail_idx;
  // Slot-2 alloc target, wraps within ReorderBufferTagWidth modulus.
  logic [ReorderBufferTagWidth-1:0] tail_idx_2;
  // Registered pointer images must satisfy:
  //   head_clear_mask      == ReorderBufferDepth'(1) << head_idx
  //   head_next_clear_mask == ReorderBufferDepth'(1) << head_next_idx
  // Reset loads masks 1 and 2 with head_ptr=0. Commit rotates them by the
  // same one or two entries as head_ptr; flush changes only the tail.
  (* max_fanout = 16 *) logic [ReorderBufferDepth-1:0] head_clear_mask;
  (* max_fanout = 16 *) logic [ReorderBufferDepth-1:0] head_next_clear_mask;
  // Registered head_idx+1: reset to 1 and advance with head_ptr.
  (* max_fanout = 96 *) logic [ReorderBufferTagWidth-1:0] head_next_idx_q;

  // Status signals
  logic [ReorderBufferTagWidth:0] count;

  // Head entry fields for commit. RAM read ports drive the RAM-backed fields
  // directly; FF-backed fields are assigned from the packed vectors.
  logic head_valid;
  logic head_done;
  logic head_exception;
  riscv_pkg::exc_cause_t head_exc_cause;  // from RAM
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

  // Head+1 ("slot 2") fields for widen-commit, read by parallel distributed
  // RAM instances at head_next_idx.
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
  logic [XLEN-1:0] head_next_fallthrough_pc;
  logic [XLEN-1:0] head_next_branch_target;
  logic [XLEN-1:0] head_next_branch_target_jal;
  logic [XLEN-1:0] head_next_branch_target_resolved;
  logic head_next_predicted_taken;
  logic head_next_mispredicted;
  logic head_next_early_recovered;
  logic head_next_f_has_checkpoint;
  logic head_next_is_call;
  logic head_next_is_return;
  logic head_next_is_jal;
  logic head_next_is_jalr;
  logic head_next_has_checkpoint;
  logic [CheckpointIdWidth-1:0] head_next_checkpoint_id;
  riscv_pkg::fp_flags_t head_next_fp_flags;
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

  // Commit control signals
  logic head_ready;  // Head is valid and done
  // Allow synthesis to combine the stall and commit gates for timing.
  logic commit_stall;  // Full serializer stall, for perf counters and assertions.
  logic commit_stall_for_retire;  // Consumers also apply retirement permission.
  // Separate retirement permission from the serializer stall for timing.
  (* keep = "true" *) logic commit_ready_early;
  (* keep = "true" *) logic commit_2_ready_early;
  logic commit_store_like_early;
  logic commit_mispredict_early;
  logic commit_correct_branch_early;
  (* keep = "true" *) logic commit_correct_branch_2_early;
  logic head_mispredict_candidate_early;
  logic commit_2_store_like_early;

  // One-hot reads of allocation-written class bits. They match the metadata
  // RAM fields; the performance-only fields match the priority classifier.
  logic head_f_store_like;
  logic head_f_is_branch;
  logic head_f_has_checkpoint;
  logic head_f_is_csr;
  logic head_f_is_fence;
  logic head_f_is_fence_i;
  logic head_f_is_wfi;
  logic head_f_is_mret;
  logic head_f_is_amo;
  logic head_f_is_lr;
  logic head_f_perf_wait_int;
  logic head_f_perf_wait_mem_load;
  logic head_f_cdb_bypass_ok;
  logic head_f_ok_2wide_static;
  logic head_f_is_sret;
  logic head_f_is_dret;
  logic head_f_is_sfence;
  logic head_f_csr_may_change_translation;
  logic head_next_f_store_like;
  logic head_next_f_is_branch;
  logic head_next_f_ok_2wide_static;
  assign head_f_store_like = onehot_read(rob_f_store_like, head_clear_mask);
  assign head_f_is_branch = onehot_read(rob_f_is_branch, head_clear_mask);
  assign head_f_has_checkpoint = onehot_read(rob_f_has_checkpoint, head_clear_mask);
  assign head_next_f_has_checkpoint = onehot_read(rob_f_has_checkpoint, head_next_clear_mask);
  assign head_f_is_csr = onehot_read(rob_f_is_csr, head_clear_mask);
  assign head_f_is_fence = onehot_read(rob_f_is_fence, head_clear_mask);
  assign head_f_is_fence_i = onehot_read(rob_f_is_fence_i, head_clear_mask);
  assign head_f_is_wfi = onehot_read(rob_f_is_wfi, head_clear_mask);
  assign head_f_is_mret = onehot_read(rob_f_is_mret, head_clear_mask);
  assign head_f_is_amo = onehot_read(rob_f_is_amo, head_clear_mask);
  assign head_f_is_lr = onehot_read(rob_f_is_lr, head_clear_mask);
  assign head_f_perf_wait_int = onehot_read(rob_f_perf_wait_int, head_clear_mask);
  assign head_f_perf_wait_mem_load = onehot_read(rob_f_perf_wait_mem_load, head_clear_mask);
  assign head_f_cdb_bypass_ok = onehot_read(rob_f_cdb_bypass_ok, head_clear_mask);
  assign head_f_ok_2wide_static = onehot_read(rob_f_ok_2wide_static, head_clear_mask);
  assign head_f_is_sret = onehot_read(rob_f_is_sret, head_clear_mask);
  assign head_f_is_dret = onehot_read(rob_f_is_dret, head_clear_mask);
  assign head_f_is_sfence = onehot_read(rob_f_is_sfence, head_clear_mask);
  assign head_f_csr_may_change_translation = onehot_read(
      rob_f_csr_may_change_translation, head_clear_mask
  );
  assign head_next_f_store_like = onehot_read(rob_f_store_like, head_next_clear_mask);
  assign head_next_f_is_branch = onehot_read(rob_f_is_branch, head_next_clear_mask);
  assign head_next_f_ok_2wide_static = onehot_read(rob_f_ok_2wide_static, head_next_clear_mask);
  // Leave commit_en free of forced net boundaries for timing.
  logic commit_en;  // Commit fires this cycle

  // Both entries must be ready and pass the two-wide hazard checks.
  // commit_2_gate counts opportunities; commit_2_fire also requires
  // EnableWidenCommit and i_widen_commit_ok to retire the second entry.
  logic head_ok_2wide;
  logic head_next_ok_2wide;
  logic commit_2_gate;

  // Serializing instruction state machine.
  riscv_pkg::serial_state_e serial_state;  // driven by rob_serializer

  // Misprediction detection at commit
  logic commit_misprediction;

  // Shared FENCE-class flush tracking
  (* max_fanout = 32 *) logic fence_i_committed;

  // ===========================================================================
  // Pointer Logic
  // ===========================================================================

  assign head_idx = head_ptr[ReorderBufferTagWidth-1:0];
  assign tail_idx = tail_ptr[ReorderBufferTagWidth-1:0];
  assign tail_idx_2 = tail_idx + 1'b1;

  assign full = (head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
                (head_idx == tail_idx);

  // Capacity checks ignore same-cycle commits, conservatively.
  assign full_for_2 = full || (count == ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1);

  assign empty = (head_ptr == tail_ptr);

  assign count = tail_ptr - head_ptr;

  // Read head fields using the registered one-hot pointer image.
  assign head_valid = onehot_read(rob_valid, head_clear_mask);
  assign head_done = onehot_read(rob_done, head_clear_mask);
  // Execution faults, allocation faults and replay share rob_exception.
  // rob_replay selects ExcMemReplay as the cause.
  logic head_replay;
  assign head_exception = onehot_read(rob_exception, head_clear_mask);
  assign head_replay = onehot_read(rob_replay, head_clear_mask);
  assign head_branch_taken = onehot_read(rob_branch_taken, head_clear_mask);
  assign head_mispredicted = onehot_read(rob_mispredicted, head_clear_mask);
  assign head_early_recovered = onehot_read(rob_early_recovered, head_clear_mask);
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
  // head_fallthrough_pc (pc + 2 or pc + 4) comes from u_rob_alloc_head.

  // Head+1 has separate RAM read ports but shares the FF vectors. It never
  // retires a CSR or exception, so it needs no CSR or cause RAM read.
  assign head_next_idx = head_next_idx_q;
  assign head_next_valid = onehot_read(rob_valid, head_next_clear_mask);
  assign head_next_done = onehot_read(rob_done, head_next_clear_mask);
  assign head_next_exception = onehot_read(rob_exception, head_next_clear_mask);
  assign head_next_branch_taken = onehot_read(rob_branch_taken, head_next_clear_mask);
  assign head_next_mispredicted = onehot_read(rob_mispredicted, head_next_clear_mask);
  assign head_next_early_recovered = onehot_read(rob_early_recovered, head_next_clear_mask);
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

  // Both slots must be nonserial and nonexceptional; either may be a
  // correctly predicted branch. Qualifying fields before their one-hot read
  // is equivalent to qualifying the selected fields while the masks stay one-hot.
  (* keep = "true" *)logic [ReorderBufferDepth-1:0] entry_ok_2wide;
  (* keep = "true" *)logic [ReorderBufferDepth-1:0] entry_next_ok_2wide;
  assign entry_ok_2wide = rob_f_ok_2wide_static & ~rob_exception &
                         ~(rob_f_is_branch & rob_mispredicted);
  assign entry_next_ok_2wide = rob_f_ok_2wide_static & ~rob_exception &
                              ~(rob_f_is_branch & (rob_mispredicted | rob_early_recovered));
  assign head_ok_2wide = onehot_read(entry_ok_2wide, head_clear_mask);
  // Head+1 uses separate checkpoint-free and branch-training ports.
  // Mispredicted or early-recovered branches retire only at the head, through
  // one recovery path. Stored legality faults also block slot 2.
  assign head_next_ok_2wide = onehot_read(entry_next_ok_2wide, head_next_clear_mask);

  // CDB bypass lets the head or head+1 retire in the completion cycle, before
  // RAM and rob_done update. Branches, serial ops and exceptions keep their
  // branch-update, serializer or trap paths. Plain stores have no bypass.
  // The downstream commit gate already applies i_flush_all.
  logic head_cdb_match;
  logic head_cdb_match_l2;  // lane-1 hits the head
  logic head_cdb_bypass;
  logic head_next_cdb_match;
  logic head_next_cdb_match_l2;  // lane-1 hits head+1
  logic head_next_cdb_bypass;

  // Distinct CDB tags allow at most one match per head. The private match
  // tags must equal the shared tags.
  assign head_cdb_match = i_cdb_write.valid && (i_cdb_match_tag == head_idx);
  assign head_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_match_tag_2 == head_idx);
  // Per-lane selects forward payloads; completion combines successful matches
  // separately. The control equations also hold if both lanes match.
  logic head_cdb_bypass_l1;
  logic head_cdb_bypass_l2;
  assign head_cdb_bypass_l1 = head_cdb_match && !i_cdb_write.exception && head_f_cdb_bypass_ok;
  assign head_cdb_bypass_l2 = head_cdb_match_l2 && !i_cdb_write_2.exception && head_f_cdb_bypass_ok;
  assign head_cdb_bypass = head_cdb_bypass_l1 || head_cdb_bypass_l2;

  assign head_next_cdb_match = i_cdb_write.valid && (i_cdb_match_tag == head_next_idx);
  assign head_next_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_match_tag_2 == head_next_idx);
  // head_next_ok_2wide checks classes before retirement, so head+1 bypass
  // needs only to exclude exceptional CDB completions.
  logic head_next_cdb_bypass_l1;
  logic head_next_cdb_bypass_l2;
  assign head_next_cdb_bypass_l1 = head_next_cdb_match && !i_cdb_write.exception;
  assign head_next_cdb_bypass_l2 = head_next_cdb_match_l2 && !i_cdb_write_2.exception;
  assign head_next_cdb_bypass = head_next_cdb_bypass_l1 || head_next_cdb_bypass_l2;

  logic head_done_eff;
  logic head_next_done_eff;
  // Combine successful CDB matches before qualifying the head class.
  (* keep = "true" *)logic head_successful_cdb;
  assign head_successful_cdb = (head_cdb_match && !i_cdb_write.exception) ||
      (head_cdb_match_l2 && !i_cdb_write_2.exception);
  assign head_done_eff = head_done || (head_f_cdb_bypass_ok && head_successful_cdb);
  assign head_next_done_eff = head_next_done || head_next_cdb_bypass;

  // Forward value and FP flags from CDB, with lane 0 priority. Plain stores
  // do not write these fields.
  logic [FLEN-1:0] head_value_eff;
  riscv_pkg::fp_flags_t head_fp_flags_eff;
  logic [FLEN-1:0] head_next_value_eff;
  riscv_pkg::fp_flags_t head_next_fp_flags_eff;
  assign head_value_eff = head_cdb_bypass_l1 ? i_cdb_write.value :
      head_cdb_bypass_l2 ? i_cdb_write_2.value : head_value;
  assign head_fp_flags_eff = head_cdb_bypass_l1 ? i_cdb_write.fp_flags :
      head_cdb_bypass_l2 ? i_cdb_write_2.fp_flags : head_fp_flags;
  assign head_next_value_eff = head_next_cdb_bypass_l1 ? i_cdb_write.value :
      head_next_cdb_bypass_l2 ? i_cdb_write_2.value : head_next_value;
  assign head_next_fp_flags_eff = head_next_cdb_bypass_l1 ? i_cdb_write.fp_flags :
      head_next_cdb_bypass_l2 ? i_cdb_write_2.fp_flags : head_next_fp_flags;

  assign head_ready = head_valid && head_done_eff;

  // Count two-wide opportunities before applying the enable and debug-step
  // permission. Factor the serializer stall separately for timing.
  assign commit_2_ready_early = commit_ready_early && head_next_valid && head_next_done_eff &&
                                head_ok_2wide && head_next_ok_2wide;
  assign commit_2_gate = commit_2_ready_early && !commit_stall_for_retire;
  // Leave commit_2_fire free of forced net boundaries for timing.
  logic commit_2_fire;
  assign commit_2_fire = commit_2_gate && EnableWidenCommit && i_widen_commit_ok;

  // ===========================================================================
  // Distributed RAM Write Enables and Data
  // ===========================================================================

  // alloc_en drives RAMs and the tail. Identical copies drive the valid,
  // control and branch FF groups, with separate fanout limits.
  logic alloc_en;
  logic alloc_en_2;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_valid;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_valid;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_control;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_control;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_branch_bits;
  (* keep = "true", max_fanout = 16 *)logic alloc_en_2_branch_bits;
  // Precompute capacity and flush gates before applying request valids.
  (* keep = "true" *) logic alloc_gate, alloc_gate_2;
  assign alloc_gate = !full && !i_flush_all && !i_flush_en;
  assign alloc_gate_2 = !full_for_2 && !i_flush_all && !i_flush_en;
  assign alloc_en = i_alloc_req.alloc_valid && alloc_gate;
  // Slot 2 requires slot 1 and two free entries.
  assign alloc_en_2 = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid && alloc_gate_2;
  assign alloc_en_valid = i_alloc_req.alloc_valid && alloc_gate;
  assign alloc_en_2_valid = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid && alloc_gate_2;
  assign alloc_en_control = i_alloc_req.alloc_valid && alloc_gate;
  assign alloc_en_2_control = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid && alloc_gate_2;
  assign alloc_en_branch_bits = i_alloc_req.alloc_valid && alloc_gate;
  assign alloc_en_2_branch_bits = i_alloc_req_2.alloc_valid && i_alloc_req.alloc_valid &&
                                  alloc_gate_2;

  // Value and FP-flag RAMs accept CDB writes outside full flush. State and
  // exception-cause writes also require a live entry; see the staleness checks.
  logic cdb_ram_wr_en;
  logic cdb_state_wr_en;
  assign cdb_ram_wr_en   = i_cdb_write.valid && !i_flush_all;
  assign cdb_state_wr_en = cdb_ram_wr_en && rob_valid[i_cdb_write.tag];

  logic cdb_ram_wr_en_2;
  logic cdb_state_wr_en_2;
  assign cdb_ram_wr_en_2   = i_cdb_write_2.valid && !i_flush_all;
  assign cdb_state_wr_en_2 = cdb_ram_wr_en_2 && rob_valid[i_cdb_write_2.tag];

  // Nonexceptional CDB completions must preserve allocation-time faults.
  // Exceptional completions replace the cause; only fetch faults can replace
  // an allocation fault with a different cause, and they outrank illegal
  // instructions. FS Off routes F/D ops to INT as ILLEGAL, preventing memory
  // faults from those loads and stores. rob_valid blocks stale cause writes
  // in a reallocation cycle, where the CDB LVT port would otherwise win.
  logic cdb_exc_cause_wr_en;
  logic cdb_exc_cause_wr_en_2;
  assign cdb_exc_cause_wr_en   = cdb_state_wr_en && i_cdb_write.exception;
  assign cdb_exc_cause_wr_en_2 = cdb_state_wr_en_2 && i_cdb_write_2.exception;

  logic branch_wr_en;
  assign branch_wr_en = i_branch_update.valid && !i_flush_all && rob_valid[i_branch_update.tag];

  // Allocation initializes the legality fault and cause. Exceptional CDB
  // completions can replace the cause.
  logic alloc_legality_fault_data;
  logic alloc_legality_fault_data_2;
  riscv_pkg::exc_cause_t alloc_exc_cause_data;
  riscv_pkg::exc_cause_t alloc_exc_cause_data_2;
  assign alloc_legality_fault_data = alloc_legality_fault(i_alloc_req);
  assign alloc_legality_fault_data_2 = alloc_legality_fault(i_alloc_req_2);
  assign alloc_exc_cause_data = alloc_legality_fault_data ?
      riscv_pkg::exc_cause_t'(riscv_pkg::ExcIllegalInstr) : '0;
  assign alloc_exc_cause_data_2 = alloc_legality_fault_data_2 ?
      riscv_pkg::exc_cause_t'(riscv_pkg::ExcIllegalInstr) : '0;

  // Allocation data for fields whose value depends on the instruction type.
  logic [FLEN-1:0] alloc_value_data;
  logic [FLEN-1:0] alloc_value_data_2;
  always_comb begin
    // Store each branch or jump link (pc + 2 or pc + 4) at allocation.
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

  // The bundle has at most one branch; only that slot records the checkpoint.
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

  // Write class FFs alongside metadata at allocation. rob_valid qualifies
  // all uses, so the class bits need no reset or flush clear.
  always_ff @(posedge i_clk) begin
    if (alloc_en_control) begin
      rob_f_store_like[tail_idx] <= i_alloc_req.is_store || i_alloc_req.is_fp_store ||
                                    i_alloc_req.is_sc;
      rob_f_is_branch[tail_idx] <= i_alloc_req.is_branch;
      rob_f_has_checkpoint[tail_idx] <= alloc_has_checkpoint_data;
      rob_f_is_csr[tail_idx] <= i_alloc_req.is_csr;
      rob_f_is_fence[tail_idx] <= i_alloc_req.is_fence;
      rob_f_is_fence_i[tail_idx] <= i_alloc_req.is_fence_i;
      rob_f_is_wfi[tail_idx] <= i_alloc_req.is_wfi;
      rob_f_is_mret[tail_idx] <= i_alloc_req.is_mret;
      rob_f_is_amo[tail_idx] <= i_alloc_req.is_amo;
      rob_f_is_lr[tail_idx] <= i_alloc_req.is_lr;
      rob_f_perf_wait_int[tail_idx] <=
          !(i_alloc_req.is_branch || i_alloc_req.is_amo || i_alloc_req.is_lr ||
            i_alloc_req.is_store || i_alloc_req.is_fp_store || i_alloc_req.is_sc) &&
          (i_alloc_req.rs_type == riscv_pkg::RS_INT);
      rob_f_perf_wait_mem_load[tail_idx] <=
          !(i_alloc_req.is_branch || i_alloc_req.is_amo || i_alloc_req.is_lr ||
            i_alloc_req.is_store || i_alloc_req.is_fp_store || i_alloc_req.is_sc) &&
          (i_alloc_req.rs_type == riscv_pkg::RS_MEM);
      rob_f_cdb_bypass_ok[tail_idx] <=
          !(i_alloc_req.is_branch || i_alloc_req.is_csr || i_alloc_req.is_fence ||
            i_alloc_req.is_fence_i || i_alloc_req.is_wfi || i_alloc_req.is_mret);
      rob_f_ok_2wide_static[tail_idx] <=
          !(i_alloc_req.is_csr || i_alloc_req.is_fence || i_alloc_req.is_fence_i ||
            i_alloc_req.is_wfi || i_alloc_req.is_mret || i_alloc_req.is_amo ||
            i_alloc_req.is_lr || i_alloc_req.is_sc);
      rob_f_is_sret[tail_idx] <= i_alloc_req.is_sret;
      rob_f_is_dret[tail_idx] <= i_alloc_req.is_dret;
      rob_f_is_sfence[tail_idx] <= i_alloc_req.is_sfence_vma;
      rob_f_csr_may_change_translation[tail_idx] <= i_alloc_req.is_csr &&
          ((i_alloc_req.csr_addr == riscv_pkg::CsrSatp) ||
           (i_alloc_req.csr_write_intent &&
            ((i_alloc_req.csr_addr == riscv_pkg::CsrMstatus) ||
             (i_alloc_req.csr_addr == riscv_pkg::CsrSstatus))));
    end
    if (alloc_en_2_control) begin
      rob_f_store_like[tail_idx_2] <= i_alloc_req_2.is_store || i_alloc_req_2.is_fp_store ||
                                      i_alloc_req_2.is_sc;
      rob_f_is_branch[tail_idx_2] <= i_alloc_req_2.is_branch;
      rob_f_has_checkpoint[tail_idx_2] <= alloc_has_checkpoint_data_2;
      rob_f_is_csr[tail_idx_2] <= i_alloc_req_2.is_csr;
      rob_f_is_fence[tail_idx_2] <= i_alloc_req_2.is_fence;
      rob_f_is_fence_i[tail_idx_2] <= i_alloc_req_2.is_fence_i;
      rob_f_is_wfi[tail_idx_2] <= i_alloc_req_2.is_wfi;
      rob_f_is_mret[tail_idx_2] <= i_alloc_req_2.is_mret;
      rob_f_is_amo[tail_idx_2] <= i_alloc_req_2.is_amo;
      rob_f_is_lr[tail_idx_2] <= i_alloc_req_2.is_lr;
      rob_f_perf_wait_int[tail_idx_2] <=
          !(i_alloc_req_2.is_branch || i_alloc_req_2.is_amo || i_alloc_req_2.is_lr ||
            i_alloc_req_2.is_store || i_alloc_req_2.is_fp_store || i_alloc_req_2.is_sc) &&
          (i_alloc_req_2.rs_type == riscv_pkg::RS_INT);
      rob_f_perf_wait_mem_load[tail_idx_2] <=
          !(i_alloc_req_2.is_branch || i_alloc_req_2.is_amo || i_alloc_req_2.is_lr ||
            i_alloc_req_2.is_store || i_alloc_req_2.is_fp_store || i_alloc_req_2.is_sc) &&
          (i_alloc_req_2.rs_type == riscv_pkg::RS_MEM);
      rob_f_cdb_bypass_ok[tail_idx_2] <=
          !(i_alloc_req_2.is_branch || i_alloc_req_2.is_csr || i_alloc_req_2.is_fence ||
            i_alloc_req_2.is_fence_i || i_alloc_req_2.is_wfi || i_alloc_req_2.is_mret);
      rob_f_ok_2wide_static[tail_idx_2] <=
          !(i_alloc_req_2.is_csr || i_alloc_req_2.is_fence || i_alloc_req_2.is_fence_i ||
            i_alloc_req_2.is_wfi || i_alloc_req_2.is_mret || i_alloc_req_2.is_amo ||
            i_alloc_req_2.is_lr || i_alloc_req_2.is_sc);
      rob_f_is_sret[tail_idx_2] <= i_alloc_req_2.is_sret;
      rob_f_is_dret[tail_idx_2] <= i_alloc_req_2.is_dret;
      rob_f_is_sfence[tail_idx_2] <= i_alloc_req_2.is_sfence_vma;
      rob_f_csr_may_change_translation[tail_idx_2] <= i_alloc_req_2.is_csr &&
          ((i_alloc_req_2.csr_addr == riscv_pkg::CsrSatp) ||
           (i_alloc_req_2.csr_write_intent &&
            ((i_alloc_req_2.csr_addr == riscv_pkg::CsrMstatus) ||
             (i_alloc_req_2.csr_addr == riscv_pkg::CsrSstatus))));
    end
  end

  // ===========================================================================
  // Distributed RAM Instances
  // ===========================================================================
  // Allocation fields share an LVT because their write enables, addresses,
  // initial contents and priorities match. Slot 2 wins address collisions.
  // Head+1 omits CSR fields, since slot 2 cannot retire a CSR.
  //
  // ID supplies link_addr = pc + (is_compressed ? 2 : 4). Store it as the
  // fall-through PC for interrupt resume, FENCE.I and branch redirects.
  localparam int unsigned AllocNextWidth =
      2 * XLEN + RegAddrWidth + CheckpointIdWidth + HeadMetaWidth;
  localparam int unsigned AllocHeadWidth = AllocNextWidth + 12 + 3 + XLEN;

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(AllocHeadWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_alloc_head (
      .i_clk,
      .i_write_enable({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data({
        {
          i_alloc_req_2.pc,
          i_alloc_req_2.link_addr,
          i_alloc_req_2.dest_reg,
          alloc_checkpoint_id_data_2,
          alloc_head_meta_data_2,
          i_alloc_req_2.csr_addr,
          i_alloc_req_2.csr_op,
          i_alloc_req_2.csr_write_data
        },
        {
          i_alloc_req.pc,
          i_alloc_req.link_addr,
          i_alloc_req.dest_reg,
          alloc_checkpoint_id_data,
          alloc_head_meta_data,
          i_alloc_req.csr_addr,
          i_alloc_req.csr_op,
          i_alloc_req.csr_write_data
        }
      }),
      .i_read_address(head_idx),
      .i_read_onehot(head_clear_mask),
      .o_read_data({
        head_pc,
        head_fallthrough_pc,
        head_dest_reg,
        head_checkpoint_id,
        head_meta_rd_data,
        head_csr_addr,
        head_csr_op,
        head_csr_write_data
      })
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(AllocNextWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_alloc_head_next (
      .i_clk,
      .i_write_enable({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data({
        {
          i_alloc_req_2.pc,
          i_alloc_req_2.link_addr,
          i_alloc_req_2.dest_reg,
          alloc_checkpoint_id_data_2,
          alloc_head_meta_data_2
        },
        {
          i_alloc_req.pc,
          i_alloc_req.link_addr,
          i_alloc_req.dest_reg,
          alloc_checkpoint_id_data,
          alloc_head_meta_data
        }
      }),
      .i_read_address(head_next_idx),
      .i_read_onehot(head_next_clear_mask),
      .o_read_data({
        head_next_pc,
        head_next_fallthrough_pc,
        head_next_dest_reg,
        head_next_checkpoint_id,
        head_next_meta_rd_data
      })
  );

  // ---------------------------------------------------------------------------
  // Multi-write-port fields (allocation + CDB).
  // These use mwp_dist_ram (mwp_dist_ram_ohread for head-side reads) with
  // 4 write ports. The value and exception-cause RAMs number them port 0 =
  // slot-1 alloc, port 1 = slot-2 alloc, port 2 = CDB lane 0, port 3 = CDB
  // lane 1; the FP-flag RAMs put the CDB lanes first. Without LVT staging
  // the highest-numbered port wins a same-cycle write to one address.
  // Allocation targets only free entries, so it collides with a CDB write
  // only when that write is stale; each RAM lets the allocation win (see the
  // CDB staleness checks). The two CDB lanes never carry the same tag (see
  // i_cdb_write_2), so they never collide on an address.
  // ---------------------------------------------------------------------------

  // Value ports 0 and 1 allocate; ports 2 and 3 take CDB lanes 0 and 1.
  // Read replicas serve head, head+1 and six dispatch-repair channels.
  // Allocation banks store zero-extended XLEN links, saving upper bits when
  // FLEN > XLEN.
  //
  // Allocation writes bank data immediately and stages the LVT update one
  // cycle. Staged read overrides expose the value at alloc+1, when a JAL
  // may commit or supply done-entry repair. CDB LVT updates remain live.
  // A stale CDB write in the allocation cycle loses to the staged override
  // and drain. A CDB write in the following drain cycle would win the LVT,
  // so no CDB may target the entry then.
  if (!SharedLinkBank) begin : g_value_lvt
    mwp_dist_ram_ohread #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_head (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(head_idx),
        .i_read_onehot(head_clear_mask),
        .o_read_data(head_value)
    );

    // Widen-commit replica: head+1 read port for value.
    mwp_dist_ram_ohread #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_head_next (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(head_next_idx),
        .i_read_onehot(head_next_clear_mask),
        .o_read_data(head_next_value)
    );

    // Dispatch bypass value read ports (same write data as above, different read addresses)
    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_1 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_1),
        .o_read_data(o_bypass_value_1)
    );

    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_2 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_2),
        .o_read_data(o_bypass_value_2)
    );

    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_3 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_3),
        .o_read_data(o_bypass_value_3)
    );

    // Slot-2 done-repair bypass read ports.
    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_4 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_4),
        .o_read_data(o_bypass_value_4)
    );

    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_5 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_5),
        .o_read_data(o_bypass_value_5)
    );

    mwp_dist_ram #(
        .ADDR_WIDTH            (ReorderBufferTagWidth),
        .DATA_WIDTH            (FLEN),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (XLEN)
    ) u_rob_value_bypass_6 (
        .i_clk,
        .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
        .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
        .i_write_data({
          i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data
        }),
        .i_read_address(i_bypass_tag_6),
        .o_read_data(o_bypass_value_6)
    );
  end else begin : g_value_shared_link
    // The shared-bank variant selects a link for branches and zero otherwise.
    // It keeps the same LVT staging and drain rule. Its single link write port
    // forbids two branch allocations at different entries.
    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b1)
    ) u_rob_value_head (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (head_idx),
        .i_read_onehot  (head_clear_mask),
        .o_read_data    (head_value)
    );

    // Widen-commit replica: head+1 read port for value.
    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b1)
    ) u_rob_value_head_next (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (head_next_idx),
        .i_read_onehot  (head_next_clear_mask),
        .o_read_data    (head_next_value)
    );

    // Dispatch bypass value read ports (same write data as above, different read addresses)
    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_1 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_1),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_1)
    );

    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_2 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_2),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_2)
    );

    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_3 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_3),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_3)
    );

    // Slot-2 done-repair bypass read ports.
    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_4 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_4),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_4)
    );

    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_5 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_5),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_5)
    );

    rob_link_value_ram #(
        .ADDR_WIDTH (ReorderBufferTagWidth),
        .DATA_WIDTH (FLEN),
        .LINK_WIDTH (XLEN),
        .ONEHOT_READ(1'b0)
    ) u_rob_value_bypass_6 (
        .i_clk,
        .i_alloc_enable ({alloc_en_2, alloc_en}),
        .i_alloc_address({tail_idx_2, tail_idx}),
        .i_alloc_branch ({i_alloc_req_2.is_branch, i_alloc_req.is_branch}),
        .i_alloc_link   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
        .i_cdb_enable   ({cdb_ram_wr_en_2, cdb_ram_wr_en}),
        .i_cdb_address  ({i_cdb_write_2.tag, i_cdb_write.tag}),
        .i_cdb_data     ({i_cdb_write_2.value, i_cdb_write.value}),
        .i_read_address (i_bypass_tag_6),
        .i_read_onehot  ('0),
        .o_read_data    (o_bypass_value_6)
    );
  end : g_value_shared_link

  // Cause RAM: allocation writes zero or IllegalInstr; exceptional CDB
  // completions replace it only on live entries.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_exc_cause (
      .i_clk,
      .i_write_enable({cdb_exc_cause_wr_en_2, cdb_exc_cause_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.exc_cause, i_cdb_write.exc_cause, alloc_exc_cause_data_2, alloc_exc_cause_data
      }),
      .i_read_address(head_idx),
      .i_read_onehot(head_clear_mask),
      .o_read_data(head_exc_cause)
  );

  // FP-flag allocation ports 2 and 3 write zero and outrank CDB ports 0 and 1,
  // so allocation beats a stale CDB write without a rob_valid gate. Plain
  // stores, conditional branches, JAL and FENCE retain zero flags. JALR also
  // gets zero flags from the ALU shim.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FpFlagsWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_fp_flags (
      .i_clk,
      .i_write_enable({alloc_en_2, alloc_en, cdb_ram_wr_en_2, cdb_ram_wr_en}),
      .i_write_address({tail_idx_2, tail_idx, i_cdb_write_2.tag, i_cdb_write.tag}),
      .i_write_data({
        FpFlagsWidth'(0), FpFlagsWidth'(0), i_cdb_write_2.fp_flags, i_cdb_write.fp_flags
      }),
      .i_read_address(head_idx),
      .i_read_onehot(head_clear_mask),
      .o_read_data(head_fp_flags)
  );

  // Widen-commit replica: head+1 read port for fp_flags.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FpFlagsWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_fp_flags_next (
      .i_clk,
      .i_write_enable({alloc_en_2, alloc_en, cdb_ram_wr_en_2, cdb_ram_wr_en}),
      .i_write_address({tail_idx_2, tail_idx, i_cdb_write_2.tag, i_cdb_write.tag}),
      .i_write_data({
        FpFlagsWidth'(0), FpFlagsWidth'(0), i_cdb_write_2.fp_flags, i_cdb_write.fp_flags
      }),
      .i_read_address(head_next_idx),
      .i_read_onehot(head_next_clear_mask),
      .o_read_data(head_next_fp_flags)
  );

  // JAL targets are written at allocation; conditional-branch and JALR
  // targets arrive on branch update. Separate memories avoid a two-port LVT.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_branch_target_jal (
      .i_clk,
      .i_write_enable ({alloc_en_2 && i_alloc_req_2.is_jal, alloc_en && i_alloc_req.is_jal}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_branch_target_data_2, alloc_branch_target_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_branch_target_jal)
  );

  // Widen-commit replica: head+1 read port for branch_target_jal.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_branch_target_jal_next (
      .i_clk,
      .i_write_enable ({alloc_en_2 && i_alloc_req_2.is_jal, alloc_en && i_alloc_req.is_jal}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_branch_target_data_2, alloc_branch_target_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
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

  // ===========================================================================
  // Allocation Logic
  // ===========================================================================

  // Allocation response
  assign o_alloc_resp.alloc_ready = !full && !i_flush_all && !i_flush_en;
  assign o_alloc_resp.alloc_tag = tail_idx;
  assign o_alloc_resp.full = dispatch_full_q;

  // Slot-2 tag is tail_idx+1. alloc_ready and full report two-entry capacity.
  assign o_alloc_resp_2.alloc_ready = !full_for_2 && !i_flush_all && !i_flush_en;
  assign o_alloc_resp_2.alloc_tag = tail_idx_2;
  assign o_alloc_resp_2.full = dispatch_full_for_2_q;

  // Flush age calculation for generic partial flush (computed combinationally).
  logic [ReorderBufferTagWidth-1:0] flush_age;
  assign flush_age = i_flush_tag - head_idx;

  logic flush_after_head_commit;
  assign flush_after_head_commit = i_flush_after_head_commit;

  // Register dispatch capacity from occupancy plus allocations, ignoring
  // same-cycle commits. Internal allocation uses exact pointer-derived full
  // flags. Raw request valids equal accepted requests: dispatch must not
  // request during flush or without space, and slot 2 requires slot 1.
  // Precompute thresholds for zero, one or two allocations, then select by
  // request width.
  logic [ReorderBufferTagWidth:0] dispatch_flush_tail_next;
  logic [ReorderBufferTagWidth:0] dispatch_flush_count_next;
  logic                           dispatch_full_next;
  logic                           dispatch_full_for_2_next;
  logic [                    2:0] dispatch_full_by_width;
  logic [                    2:0] dispatch_full_for_2_by_width;

  assign dispatch_full_by_width[0] = count == ReorderBufferDepth[ReorderBufferTagWidth:0];
  assign dispatch_full_by_width[1] = count == ReorderBufferCountWidth'(ReorderBufferDepth - 1);
  assign dispatch_full_by_width[2] = count == ReorderBufferCountWidth'(ReorderBufferDepth - 2);

  assign dispatch_full_for_2_by_width[0] =
      count >= ReorderBufferCountWidth'(ReorderBufferDepth - 1);
  assign dispatch_full_for_2_by_width[1] =
      count >= ReorderBufferCountWidth'(ReorderBufferDepth - 2);
  assign dispatch_full_for_2_by_width[2] =
      count >= ReorderBufferCountWidth'(ReorderBufferDepth - 3);

  always_comb begin
    dispatch_flush_tail_next = tail_ptr;

    if (i_flush_all || i_flush_en) begin
      if (i_flush_all) begin
        dispatch_flush_tail_next = head_ptr;
      end else if (flush_after_head_commit) begin
        dispatch_flush_tail_next = head_ptr;
      end else begin
        dispatch_flush_tail_next = head_ptr + {1'b0, flush_age} + 1'b1;
      end
    end
    dispatch_flush_count_next = dispatch_flush_tail_next - head_ptr;
  end

  always_comb begin
    if (i_flush_all || i_flush_en) begin
      // On a flush, use the exact pointer-derived surviving occupancy.
      dispatch_full_next = dispatch_flush_count_next == ReorderBufferDepth[ReorderBufferTagWidth:0];
      dispatch_full_for_2_next = dispatch_flush_count_next >=
          (ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1);
    end else begin
      // 2'b01 is forbidden by the slot-2-implies-slot-1 contract. Map it to
      // width zero so an illegal slot-2 request cannot perturb status state.
      case ({
        i_alloc_req.alloc_valid, i_alloc_req_2.alloc_valid
      })
        2'b10: begin
          dispatch_full_next       = dispatch_full_by_width[1];
          dispatch_full_for_2_next = dispatch_full_for_2_by_width[1];
        end
        2'b11: begin
          dispatch_full_next       = dispatch_full_by_width[2];
          dispatch_full_for_2_next = dispatch_full_for_2_by_width[2];
        end
        default: begin
          dispatch_full_next       = dispatch_full_by_width[0];
          dispatch_full_for_2_next = dispatch_full_for_2_by_width[0];
        end
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      dispatch_full_q       <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      dispatch_full_q       <= dispatch_full_next;
      dispatch_full_for_2_q <= dispatch_full_for_2_next;
    end
  end

  // Allocation write - tail pointer management
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      tail_ptr <= '0;
    end else if (i_flush_all) begin
      tail_ptr <= head_ptr;
    end else if (i_flush_en) begin
      if (flush_after_head_commit) begin
        // Delayed recovery: the mispredicted head already retired last cycle,
        // so every remaining live entry is younger and the ROB becomes empty.
        tail_ptr <= head_ptr;
      end else begin
        // Generic partial flush: tail becomes flush_tag + 1. Age-based
        // arithmetic (5-bit age extended to 6 bits) handles the wrap.
        tail_ptr <= head_ptr + {1'b0, flush_age} + 1'b1;
      end
    end else if (alloc_en) begin
      // alloc_en_2 implies alloc_en; advance by the accepted width.
      tail_ptr <= tail_ptr + {{ReorderBufferTagWidth - 1{1'b0}}, alloc_en_2, !alloc_en_2};
    end
  end

  // ===========================================================================
  // Reorder Buffer FF Storage (1-bit packed vectors)
  // ===========================================================================

  // Control fields in FFs
  // -------------------------------------------------------------------------
  // Compute done and exception for all four allocation combinations before
  // selecting by enables. Live completions override allocation; store
  // completion sets done last. Reset clears both fields.
  logic alloc_done_value, alloc_done_value_2;
  assign alloc_done_value = i_alloc_req.is_jal || (!i_alloc_req.is_jalr &&
      (i_alloc_req.is_wfi || i_alloc_req.is_fence ||
       i_alloc_req.is_fence_i || i_alloc_req.is_mret));
  assign alloc_done_value_2 = i_alloc_req_2.is_jal || (!i_alloc_req_2.is_jalr &&
      (i_alloc_req_2.is_wfi || i_alloc_req_2.is_fence ||
       i_alloc_req_2.is_fence_i || i_alloc_req_2.is_mret));
  logic [ReorderBufferDepth-1:0] done_next, exception_next;
  for (genvar entry = 0; entry < ReorderBufferDepth; entry++) begin : gen_control_next
    wire alloc_here = tail_idx == ReorderBufferTagWidth'(entry);
    wire alloc_here_2 = tail_idx_2 == ReorderBufferTagWidth'(entry);
    wire cdb_here = i_cdb_write.valid && i_cdb_write.tag == ReorderBufferTagWidth'(entry);
    wire cdb_here_2 = i_cdb_write_2.valid && i_cdb_write_2.tag == ReorderBufferTagWidth'(entry);
    wire branch_here = i_branch_update.valid &&
        i_branch_update.tag == ReorderBufferTagWidth'(entry);
    wire completion_live = rob_valid[entry] && !i_flush_all;
    wire done_completion = completion_live && (cdb_here || cdb_here_2 || branch_here);
    wire exception_completion = completion_live &&
        ((cdb_here && i_cdb_write.exception) || (cdb_here_2 && i_cdb_write_2.exception));
    wire exception_hold = rob_exception[entry] || (i_replay_set_mask[entry] && rob_valid[entry]);
    (* keep = "true" *) logic [3:0] done_alloc_cases, exception_alloc_cases;
    for (genvar choice = 0; choice < 4; choice++) begin : gen_alloc_case
      localparam bit Alloc1 = (choice & 1) != 0;
      localparam bit Alloc2 = (choice & 2) != 0;
      assign done_alloc_cases[choice] = done_completion ||
          ((Alloc2 && alloc_here_2) ? alloc_done_value_2 :
           (Alloc1 && alloc_here) ? alloc_done_value : rob_done[entry]);
      assign exception_alloc_cases[choice] = exception_completion ||
          ((Alloc2 && alloc_here_2) ? alloc_legality_fault_data_2 :
           (Alloc1 && alloc_here) ? alloc_legality_fault_data : exception_hold);
    end
    (* keep = "true" *) logic store_completion_eligible;
    assign store_completion_eligible = completion_live &&
        i_store_complete_tag == ReorderBufferTagWidth'(entry);
    wire done_without_store = alloc_en_2_control ?
        (alloc_en_control ? done_alloc_cases[3] : done_alloc_cases[2]) :
        (alloc_en_control ? done_alloc_cases[1] : done_alloc_cases[0]);
    wire exception_selected = alloc_en_2_control ?
        (alloc_en_control ? exception_alloc_cases[3] : exception_alloc_cases[2]) :
        (alloc_en_control ? exception_alloc_cases[1] : exception_alloc_cases[0]);
    assign done_next[entry] = i_rst_n &&
        (done_without_store || (i_store_complete_valid && store_completion_eligible));
    assign exception_next[entry] = i_rst_n && exception_selected;
  end
  always_ff @(posedge i_clk) begin
    rob_done <= done_next;
    rob_exception <= exception_next;
  end

`ifdef ROB_CONTROL_NEXT_LOCAL_PROOF
  // Reference: the indexed-write form of the transitions, built from the
  // actual current state. All inputs and current bits are unconstrained; no
  // reset or admission assumption.
  logic [ReorderBufferDepth-1:0] f_done_next, f_exception_next;
  always_comb begin
    f_done_next = rob_done;
    f_exception_next = rob_exception;
    if (!i_rst_n) begin
      f_done_next      = '0;
      f_exception_next = '0;
    end else begin
      // Memory-order replay flags make their entries exceptional
      // through the same stored bit as execution exceptions.
      f_exception_next = rob_exception | (i_replay_set_mask & rob_valid);
      // ---------------------------------------------------------------------
      // Allocation Write (control fields only)
      // ---------------------------------------------------------------------
      if (alloc_en_control) begin
        // Legality is complete at allocation; an exceptional CDB completion
        // may still set the bit later.
        f_exception_next[tail_idx] = alloc_legality_fault_data;

        // JAL's link and target are both known at allocation. JALR and
        // conditional branches wait for branch resolution.
        if (i_alloc_req.is_jal) begin
          f_done_next[tail_idx] = 1'b1;
        end else if (i_alloc_req.is_jalr) begin
          // JALR: link address known, target unknown until execute
          f_done_next[tail_idx] = 1'b0;
        end else if (i_alloc_req.is_wfi || i_alloc_req.is_fence ||
                     i_alloc_req.is_fence_i || i_alloc_req.is_mret) begin
          // Done from the execution side at dispatch; the serializer gates
          // their commit.
          f_done_next[tail_idx] = 1'b1;
        end else begin
          f_done_next[tail_idx] = 1'b0;
        end
      end

      // The allocation slots target distinct entries, so their writes cannot collide.
      if (alloc_en_2_control) begin
        f_exception_next[tail_idx_2] = alloc_legality_fault_data_2;

        if (i_alloc_req_2.is_jal) begin
          f_done_next[tail_idx_2] = 1'b1;
        end else if (i_alloc_req_2.is_jalr) begin
          f_done_next[tail_idx_2] = 1'b0;
        end else if (i_alloc_req_2.is_wfi || i_alloc_req_2.is_fence ||
                     i_alloc_req_2.is_fence_i || i_alloc_req_2.is_mret) begin
          f_done_next[tail_idx_2] = 1'b1;
        end else begin
          f_done_next[tail_idx_2] = 1'b0;
        end
      end

      // ---------------------------------------------------------------------
      // CDB Write (mark entry done with result)
      // ---------------------------------------------------------------------
      // A nonexceptional CDB completion preserves an allocation fault. An
      // exceptional completion sets the bit and replaces the cause.
      if (cdb_state_wr_en) begin
        f_done_next[i_cdb_write.tag] = 1'b1;
        if (i_cdb_write.exception) f_exception_next[i_cdb_write.tag] = 1'b1;
      end
      // The CDB lanes carry distinct tags, so these writes cannot collide.
      if (cdb_state_wr_en_2) begin
        f_done_next[i_cdb_write_2.tag] = 1'b1;
        if (i_cdb_write_2.exception) f_exception_next[i_cdb_write_2.tag] = 1'b1;
      end

      // ---------------------------------------------------------------------
      // Direct store completion (mark plain store entry done)
      // ---------------------------------------------------------------------
      if (i_store_complete_valid && !i_flush_all && rob_valid[i_store_complete_tag]) begin
        f_done_next[i_store_complete_tag] = 1'b1;
      end

      // ---------------------------------------------------------------------
      // Branch Update (mark branch done)
      // ---------------------------------------------------------------------
      if (branch_wr_en) begin
        f_done_next[i_branch_update.tag] = 1'b1;
      end
    end
  end

  always_comb begin
    assert (done_next == f_done_next);
    assert (exception_next == f_exception_next);
  end
`endif

  // Replay marks live entries without a stored exception and selects
  // ExcMemReplay at the head. rob_exception holds their exceptional state.
  // An exceptional completion, allocation, commit or flush clears replay.
  // All updates after the set only clear it, so their order is immaterial.
  logic [ReorderBufferDepth-1:0] replay_next;
  for (genvar entry = 0; entry < ReorderBufferDepth; entry++) begin : gen_replay_next
    wire alloc_here = tail_idx == ReorderBufferTagWidth'(entry);
    wire alloc_here_2 = tail_idx_2 == ReorderBufferTagWidth'(entry);
    wire cdb_clear =
        (cdb_state_wr_en && i_cdb_write.exception &&
         i_cdb_write.tag == ReorderBufferTagWidth'(entry)) ||
        (cdb_state_wr_en_2 && i_cdb_write_2.exception &&
         i_cdb_write_2.tag == ReorderBufferTagWidth'(entry));
    wire flush_clear = i_flush_all || (i_flush_en && (flush_after_head_commit || should_flush_entry(
        ReorderBufferTagWidth'(entry), i_flush_tag, head_idx
    )));
    wire commit_clear = !i_flush_all &&
        ((commit_en && head_clear_mask[entry]) ||
         (commit_2_fire && head_next_clear_mask[entry]));
    wire replay_without_alloc = i_rst_n && !cdb_clear && !flush_clear &&
        (rob_replay[entry] ||
         (i_replay_set_mask[entry] && rob_valid[entry] && !rob_exception[entry]));
    (* keep = "true" *) logic [3:0] replay_alloc_cases;
    for (genvar choice = 0; choice < 4; choice++) begin : gen_alloc_case
      localparam bit Alloc1 = (choice & 1) != 0;
      localparam bit Alloc2 = (choice & 2) != 0;
      assign replay_alloc_cases[choice] = replay_without_alloc &&
          !(Alloc1 && alloc_here) && !(Alloc2 && alloc_here_2);
    end
    (* keep = "true" *) logic replay_after_alloc;
    assign replay_after_alloc = alloc_en_2_valid ?
        (alloc_en_valid ? replay_alloc_cases[3] : replay_alloc_cases[2]) :
        (alloc_en_valid ? replay_alloc_cases[1] : replay_alloc_cases[0]);
    assign replay_next[entry] = replay_after_alloc && !commit_clear;
  end
  always_ff @(posedge i_clk) begin
    rob_replay <= replay_next;
  end

`ifdef ROB_CONTROL_NEXT_LOCAL_PROOF
  logic [ReorderBufferDepth-1:0] f_replay_next;
  always_comb begin
    f_replay_next = rob_replay;
    if (!i_rst_n) begin
      f_replay_next = '0;
    end else begin
      f_replay_next = rob_replay | (i_replay_set_mask & rob_valid & ~rob_exception);
      if (cdb_state_wr_en && i_cdb_write.exception) f_replay_next[i_cdb_write.tag] = 1'b0;
      if (cdb_state_wr_en_2 && i_cdb_write_2.exception) f_replay_next[i_cdb_write_2.tag] = 1'b0;
      if (i_flush_all) begin
        f_replay_next = '0;
      end else if (i_flush_en) begin
        if (flush_after_head_commit) begin
          f_replay_next = '0;
        end else begin
          for (int i = 0; i < ReorderBufferDepth; i++) begin
            if (should_flush_entry(i[ReorderBufferTagWidth-1:0], i_flush_tag, head_idx)) begin
              f_replay_next[i] = 1'b0;
            end
          end
        end
      end
      if (alloc_en_valid) f_replay_next[tail_idx] = 1'b0;
      if (alloc_en_2_valid) f_replay_next[tail_idx_2] = 1'b0;
      if (commit_en && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_clear_mask[i]) f_replay_next[i] = 1'b0;
        end
      end
      if (commit_2_fire && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_next_clear_mask[i]) f_replay_next[i] = 1'b0;
        end
      end
    end
  end

  always_comb begin
    assert (replay_next == f_replay_next);
  end
`endif

  // Keep valid state separate for timing. Priority is flush clear, then
  // allocation set, then commit clear; reset overrides all three.
  logic [ReorderBufferDepth-1:0] valid_next;
  for (genvar entry = 0; entry < ReorderBufferDepth; entry++) begin : gen_valid_next
    wire alloc_here = tail_idx == ReorderBufferTagWidth'(entry);
    wire alloc_here_2 = tail_idx_2 == ReorderBufferTagWidth'(entry);
    wire flush_clear = i_flush_all || (i_flush_en && (flush_after_head_commit || should_flush_entry(
        ReorderBufferTagWidth'(entry), i_flush_tag, head_idx
    )));
    wire commit_clear = !i_flush_all &&
        ((commit_en && head_clear_mask[entry]) ||
         (commit_2_fire && head_next_clear_mask[entry]));
    wire valid_without_alloc = rob_valid[entry] && !flush_clear;
    (* keep = "true" *) logic [3:0] valid_alloc_cases;
    for (genvar choice = 0; choice < 4; choice++) begin : gen_alloc_case
      localparam bit Alloc1 = (choice & 1) != 0;
      localparam bit Alloc2 = (choice & 2) != 0;
      assign valid_alloc_cases[choice] = valid_without_alloc ||
          (Alloc1 && alloc_here) || (Alloc2 && alloc_here_2);
    end
    (* keep = "true" *) logic valid_after_alloc;
    assign valid_after_alloc = alloc_en_2_valid ?
        (alloc_en_valid ? valid_alloc_cases[3] : valid_alloc_cases[2]) :
        (alloc_en_valid ? valid_alloc_cases[1] : valid_alloc_cases[0]);
    assign valid_next[entry] = i_rst_n && valid_after_alloc && !commit_clear;
  end
  always_ff @(posedge i_clk) begin
    rob_valid <= valid_next;
  end

`ifdef ROB_CONTROL_NEXT_LOCAL_PROOF
  logic [ReorderBufferDepth-1:0] f_valid_next;
  always_comb begin
    f_valid_next = rob_valid;
    if (!i_rst_n) begin
      f_valid_next = '0;
    end else begin
      if (i_flush_all) begin
        f_valid_next = '0;
      end else if (i_flush_en) begin
        if (flush_after_head_commit) begin
          f_valid_next = '0;
        end else begin
          for (int i = 0; i < ReorderBufferDepth; i++) begin
            if (rob_valid[i] && should_flush_entry(
                    i[ReorderBufferTagWidth-1:0], i_flush_tag, head_idx
                )) begin
              f_valid_next[i] = 1'b0;
            end
          end
        end
      end
      if (alloc_en_valid) f_valid_next[tail_idx] = 1'b1;
      if (alloc_en_2_valid) f_valid_next[tail_idx_2] = 1'b1;
      if (commit_en && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_clear_mask[i]) f_valid_next[i] = 1'b0;
        end
      end
      if (commit_2_fire && !i_flush_all) begin
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          if (head_next_clear_mask[i]) f_valid_next[i] = 1'b0;
        end
      end
    end
  end

  always_comb begin
    assert (valid_next == f_valid_next);
  end
`endif

  // -------------------------------------------------------------------------
  // Data signals: no reset needed, gated by alloc_en / branch_wr_en
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    // -------------------------------------------------------------------
    // Allocation Write (multi-write/head-independent data fields)
    // -------------------------------------------------------------------
    if (alloc_en_branch_bits) begin
      rob_branch_taken[tail_idx]    <= 1'b0;
      rob_mispredicted[tail_idx]    <= 1'b0;
      rob_early_recovered[tail_idx] <= 1'b0;

      // JAL is always taken with a target known at allocation, so its
      // misprediction is resolved here.
      if (i_alloc_req.is_jal) begin
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
    // Use the branch unit's misprediction result; it includes RAS and indirect
    // prediction information absent from the ROB. The target is stored in RAM.
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
      head_next_idx_q      <= ReorderBufferTagWidth'(1);
      head_clear_mask      <= ReorderBufferDepth'(1);
      head_next_clear_mask <= ReorderBufferDepth'(2);
    end else if (i_flush_all) begin
      // Full flush: head stays (tail resets to head)
    end else if (commit_en) begin
      // commit_2_fire implies commit_en; advance pointers and masks together.
      head_ptr <= head_ptr + ({{ReorderBufferTagWidth - 1{1'b0}}, commit_2_fire, !commit_2_fire});
      head_next_idx_q <= head_next_idx_q +
          ({{ReorderBufferTagWidth - 2{1'b0}}, commit_2_fire, !commit_2_fire});
      head_clear_mask <= advance_onehot_mask(head_clear_mask, commit_2_fire);
      head_next_clear_mask <= advance_onehot_mask(head_next_clear_mask, commit_2_fire);
    end
  end

  // ===========================================================================
  // Serializing Instruction State Machine
  // ===========================================================================
  // Serialize CSR, fence, WFI, xRET and exceptional heads.

  // rob_serializer supplies the state and stall signals.
  logic native_fence_commit_event;
  logic translation_csr_commit_event_q;
  rob_serializer rob_serializer_inst (
      .i_clk                           (i_clk),
      .i_rst_n                         (i_rst_n),
      .i_flush_all                     (i_flush_all),
      .i_flush_en                      (i_flush_en),
      .i_commit_hold                   (i_commit_hold),
      .i_early_recovery_en             (i_early_recovery_en),
      .i_interrupt_pending             (i_interrupt_pending),
      .i_sq_committed_empty            (i_sq_committed_empty),
      .i_fence_i_sync_done             (i_fence_i_sync_done),
      .o_fence_i_sync_req              (o_fence_i_sync_req),
      .i_csr_done                      (i_csr_done),
      .i_mret_done                     (i_mret_done),
      .i_trap_taken                    (i_trap_taken),
      // Class FFs duplicate the metadata RAM for serializer control.
      .head_ready                      (head_ready),
      .head_exception                  (head_exception),
      .head_is_wfi                     (head_f_is_wfi),
      .head_is_csr                     (head_f_is_csr),
      .head_is_fence                   (head_f_is_fence),
      .head_is_fence_i                 (head_f_is_fence_i),
      .head_is_mret                    (head_f_is_mret),
      .head_is_amo                     (head_f_is_amo),
      .head_is_lr                      (head_f_is_lr),
      .head_is_sfence                  (head_f_is_sfence),
      .head_csr_may_change_translation (head_f_csr_may_change_translation),
      .o_serial_state                  (serial_state),
      .o_sfence_window                 (o_sfence_window),
      .o_native_fence_commit_event     (native_fence_commit_event),
      .o_translation_csr_commit_event_q(translation_csr_commit_event_q),
      .o_commit_stall                  (commit_stall),
      .o_commit_stall_for_retire       (commit_stall_for_retire)
  );

  // ===========================================================================
  // Commit Enable Logic
  // ===========================================================================

  // Commit requires a ready, nonexceptional head, serializer permission,
  // and no hold or recovery. Nothing retires during flush: the SQ flush
  // logic relies on this to exclude a simultaneous store commit.
  //
  // No same-cycle branch-update guard is needed. JAL is done at allocation
  // and branch_resolution emits no update for it. Other branches cannot
  // bypass CDB into commit, so done trails branch_update by a cycle.
  // early_misprediction_recovery drops an overlapping early recovery on the
  // next cycle when mispredict_recovery_pending is set.
  //
  // The serializer applies the same permission terms before leaving IDLE.
  // Recovery bubbles do not wait for head commit, so a surviving head can
  // serialize afterward without deadlock.
  //
  // commit_stall_for_retire omits permission terms in FENCE_I_SYNC and
  // CSR_TRANSLATION_DRAIN. Every retirement aggregate must apply them;
  // performance counters use the full stall. Qualify stored readiness per
  // entry before the one-hot read, then include same-cycle CDB success.
  (* keep = "true" *) logic [ReorderBufferDepth-1:0] entry_stored_ready;
  (* keep = "true" *) logic [ReorderBufferDepth-1:0] entry_bypass_ready;
  (* keep = "true" *) logic head_stored_ready;
  (* keep = "true" *) logic head_bypass_ready;
  assign entry_stored_ready = rob_valid & rob_done & ~rob_exception;
  assign entry_bypass_ready = rob_valid & rob_f_cdb_bypass_ok & ~rob_exception;
  assign head_stored_ready = onehot_read(entry_stored_ready, head_clear_mask);
  assign head_bypass_ready = onehot_read(entry_bypass_ready, head_clear_mask);
  assign commit_ready_early =
      (head_stored_ready || (head_bypass_ready && head_successful_cdb)) && !i_commit_hold &&
      !i_early_recovery_en && !i_flush_en && !i_flush_all && !flush_after_head_commit;
  assign commit_en = commit_ready_early && !commit_stall_for_retire;

  // Raw misprediction at commit (early_recovered handled externally by cpu_ooo)
  (* keep = "true" *) logic [ReorderBufferDepth-1:0] entry_misprediction;
  assign entry_misprediction = rob_f_is_branch & rob_mispredicted;
  assign commit_misprediction = onehot_read(entry_misprediction, head_clear_mask);
  assign o_commit_valid_raw = commit_en;
  assign commit_store_like_early = commit_ready_early && head_f_store_like;
  assign o_commit_store_like_raw = commit_store_like_early && !commit_stall_for_retire;
  // Branches at the head cannot use the head CDB bypass, so the slot-1
  // branch strobes need only the stored done bit. Allocation records class
  // and bypass eligibility together. (Head+1 has its own bypass and two-wide
  // checks.)
  (* keep = "true" *) logic commit_branch_ready_early;
  assign commit_branch_ready_early = head_valid && head_done && !head_exception &&
                                     !i_commit_hold && !i_early_recovery_en && !i_flush_en &&
                                     !i_flush_all && !flush_after_head_commit;
  assign commit_mispredict_early =
      commit_branch_ready_early && commit_misprediction && !head_early_recovered;
  assign o_commit_misprediction_raw = commit_mispredict_early && !commit_stall_for_retire;
  assign commit_correct_branch_early = commit_branch_ready_early && head_f_has_checkpoint &&
                                       !commit_misprediction && !head_early_recovered;
  assign o_commit_correct_branch_raw = commit_correct_branch_early && !commit_stall_for_retire;
  // The full two-wide gate already excludes mispredicted and early-recovered
  // branches; these repeated checks match the slot-1 strobe.
  assign commit_correct_branch_2_early =
      commit_2_ready_early && EnableWidenCommit && i_widen_commit_ok &&
      head_next_f_has_checkpoint && !head_next_mispredicted && !head_next_early_recovered;
  assign o_commit_correct_branch_2_raw = commit_correct_branch_2_early && !commit_stall_for_retire;
  // Unused by cpu_ooo; branch_resolution explains why this does not suppress
  // resolution. Unlike commit_ready_early, it does not exclude exceptions.
  assign head_mispredict_candidate_early =
      head_valid && head_done && !i_commit_hold && !i_early_recovery_en &&
      !i_flush_en && !i_flush_all && !flush_after_head_commit &&
      commit_misprediction && !head_early_recovered;
  assign o_head_commit_misprediction_candidate =
      head_mispredict_candidate_early && !commit_stall_for_retire;

  // ===========================================================================
  // External Coordination Outputs
  // ===========================================================================

  // CSR and xRET cannot use CDB bypass, so their starts read stored done.
  // CSR start asserts on entry to CSR_EXEC.
  assign o_csr_start = (serial_state == riscv_pkg::SERIAL_IDLE) && head_valid && head_done &&
                       !i_commit_hold &&
                       !i_early_recovery_en &&
                       head_f_is_csr && !head_exception &&
                       !i_flush_en && !i_flush_all;

  // xRET enters MRET_EXEC before stores necessarily drain. Allow start in
  // both IDLE and MRET_EXEC so a delayed drain cannot strand it. Gate start
  // with i_sq_committed_empty to prevent feedback through the trap unit from
  // alternating o_mret_start and i_commit_hold during the wait.
  assign o_mret_start = ((serial_state == riscv_pkg::SERIAL_IDLE) ||
                         (serial_state == riscv_pkg::SERIAL_MRET_EXEC)) &&
                        head_valid && head_done &&
                        !i_commit_hold &&
                        !i_early_recovery_en &&
                        head_f_is_mret && !head_exception &&
                        i_sq_committed_empty;
  // xRET subtype qualifiers are used only while o_mret_start is high.
  assign o_mret_start_is_sret = head_f_is_sret;
  assign o_mret_start_is_dret = head_f_is_dret;

  // Trap pending: asserted while an exception sits at the head. The
  // combinational term detects it in the same cycle; the state term sustains
  // it across clock edges.
  assign o_trap_pending =
      ((serial_state == riscv_pkg::SERIAL_TRAP_WAIT) ||
       (head_ready && !i_commit_hold && !i_early_recovery_en && head_exception));
  assign o_trap_pc = head_pc;
  // Seed interrupt resume with wfi_pc+4 while WFI waits. If an interrupt
  // flushes WFI before it commits, the previous resume PC would point to WFI
  // itself instead of the next instruction required by the spec.
  assign o_head_is_wfi = head_f_is_wfi;
  // AMO interrupt shield source: the one-hot FF read of the head's is_amo
  // flag, valid-qualified and registered in cpu_ooo before use.
  assign o_head_is_amo = head_f_is_amo;
  // A replay flag is only set on an entry without a stored exception (and
  // an exceptional completion clears it), so it selects the cause outright.
  assign o_trap_cause = head_replay ?
      riscv_pkg::ExcMemReplay[riscv_pkg::ExcCauseWidth-1:0] : head_exc_cause;
  assign o_trap_value = head_value[XLEN-1:0];

  // These match commit-packet write enables on a raw fire. Slot 2 needs no
  // CSR or exception exclusion here because its retirement gate applies them.
  assign o_head_bypass_int_we_early = head_dest_valid && !head_exception &&
      !head_is_csr && !head_dest_rf && |head_dest_reg;
  assign o_head_bypass_fp_we_early = head_dest_valid && !head_exception &&
      !head_is_csr && head_dest_rf;
  assign o_head_next_bypass_int_we_early =
      head_next_dest_valid && !head_next_dest_rf && |head_next_dest_reg;
  assign o_head_next_bypass_fp_we_early = head_next_dest_valid && head_next_dest_rf;
  // is_branch includes jumps; direction training excludes JAL and JALR.
  assign o_head_dir_train_early = head_is_branch && !head_is_jal && !head_is_jalr;
  assign o_head_branch_taken_early = head_branch_taken;
  assign o_head_next_dir_train_early =
      head_next_f_is_branch && !head_next_is_jal && !head_next_is_jalr;
  assign o_head_next_branch_taken_early = head_next_branch_taken;

  // For a retiring non-xRET, next PC is the taken branch target or the
  // stored fall-through PC. In the full core, xRET uses a full flush, so
  // interrupt resume and FENCE refetch never sample its value here.
  // xret_return_pc supplies the commit packet: mepc, sepc or dpc.
  logic [XLEN-1:0] xret_return_pc;
  assign xret_return_pc = head_f_is_dret ? i_dpc : head_f_is_sret ? i_sepc : i_mepc;
  assign o_head_retired_next_pc =
      (head_f_is_branch && head_branch_taken) ? head_branch_target : head_fallthrough_pc;
  // A taken branch retiring in slot 2 makes its target the interrupt resume
  // PC. xRET cannot retire in slot 2.
  assign o_head_next_retired_next_pc =
      (head_next_f_is_branch && head_next_branch_taken) ? head_next_branch_target :
      head_next_fallthrough_pc;

  // FENCE.I and SFENCE.VMA retire and raise their event in cycle T;
  // o_fence_i_flush follows in T+1. A translation CSR retires in T, writes
  // csr_file from the registered commit bus in T+1, then flushes in T+2,
  // alongside any registered CSR-file TLB invalidation.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fence_i_committed <= 1'b0;
    end else begin
      fence_i_committed <= o_fence_class_flush_event;
    end
  end
  assign o_fence_class_flush_event = native_fence_commit_event || translation_csr_commit_event_q;
  assign o_translation_csr_commit_shadow = translation_csr_commit_event_q;
  assign o_fence_i_flush = fence_i_committed;

  // The registered SFENCE window covers its FENCE_I_SYNC cycles only;
  // plain FENCE.I leaves it low.

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
      // - xRET: redirect to mepc/sepc/dpc
      // - Taken branch/jump: redirect to resolved target
      // - Not-taken branch: redirect to architectural fall-through
      if (head_is_mret) begin
        // The xRET handshake finishes before commit_en, so xepc is stable. In
        // the full core, the flush arrives with i_mret_done and prevents this commit.
        o_commit_comb.redirect_pc = xret_return_pc;
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
      // ID computes the link and is_compressed from the same decode. Branch
      // values remain that link, including JALR CDB writes, so the stored bit
      // equals (head_value == head_pc + 2).
      o_commit_comb.is_compressed   = head_is_compressed;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // A retired branch's link must equal pc + (is_compressed ? 2 : 4).
  always @(posedge i_clk) begin
    if (i_rst_n && o_commit_comb.valid && head_is_branch) begin
      if ((head_value[XLEN-1:0] == (head_pc + 64'd2)) != head_is_compressed)
        $error(
            "reorder_buffer: stored is_compressed diverged from link view (pc=%h val=%h q=%b)",
            head_pc,
            head_value[XLEN-1:0],
            head_is_compressed
        );
    end
  end

  // The fall-through RAMs hold pc + (is_compressed ? 2 : 4) for every entry:
  // each allocation's link_addr must equal that sum, and a valid head or
  // head+1 entry must read it back.
  function automatic logic [XLEN-1:0] expected_fallthrough(input logic [XLEN-1:0] pc,
                                                           input logic is_compressed);
    expected_fallthrough = XLEN'(pc + (is_compressed ? XLEN'(2) : XLEN'(4)));
  endfunction

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      if (alloc_en && i_alloc_req.link_addr != expected_fallthrough(
              i_alloc_req.pc, i_alloc_req.is_compressed
          ))
        $error(
            "reorder_buffer: slot-1 link_addr %h is not the fall-through of pc %h (c=%b)",
            i_alloc_req.link_addr,
            i_alloc_req.pc,
            i_alloc_req.is_compressed
        );
      if (alloc_en_2 && i_alloc_req_2.link_addr != expected_fallthrough(
              i_alloc_req_2.pc, i_alloc_req_2.is_compressed
          ))
        $error(
            "reorder_buffer: slot-2 link_addr %h is not the fall-through of pc %h (c=%b)",
            i_alloc_req_2.link_addr,
            i_alloc_req_2.pc,
            i_alloc_req_2.is_compressed
        );
      if (head_valid && head_fallthrough_pc != expected_fallthrough(head_pc, head_is_compressed))
        $error(
            "reorder_buffer: head fall-through %h is not pc %h + 2/4 (c=%b)",
            head_fallthrough_pc,
            head_pc,
            head_is_compressed
        );
      if (head_next_valid && head_next_fallthrough_pc != expected_fallthrough(
              head_next_pc, head_next_is_compressed
          ))
        $error(
            "reorder_buffer: head+1 fall-through %h is not pc %h + 2/4 (c=%b)",
            head_next_fallthrough_pc,
            head_next_pc,
            head_next_is_compressed
        );
    end
  end
`endif
`endif

  // Registered copy of the commit bus, visible for the cycle after the
  // retiring edge. The full core leaves it unconnected; the wrapper registers
  // o_commit_comb itself in commit_bus_pipeline.
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
  // Slot 2 carries ordinary retirement data and correctly predicted branch
  // metadata. Exception, CSR, serializing, predicted_taken and misprediction
  // fields remain zero.
  always_comb begin
    o_commit_comb_2 = '0;

    if (commit_2_fire) begin
      o_commit_comb_2.valid = 1'b1;
      o_commit_comb_2.tag = head_next_idx;
      o_commit_comb_2.dest_rf = head_next_dest_rf;
      o_commit_comb_2.dest_reg = head_next_dest_reg;
      o_commit_comb_2.dest_valid = head_next_dest_valid;
      o_commit_comb_2.value = head_next_value_eff;
      o_commit_comb_2.is_store = head_next_is_store;
      o_commit_comb_2.is_fp_store = head_next_is_fp_store;
      o_commit_comb_2.exception = 1'b0;  // gate excludes exceptions
      o_commit_comb_2.pc = head_next_pc;
      o_commit_comb_2.exc_cause = '0;
      o_commit_comb_2.fp_flags = head_next_fp_flags_eff;
      o_commit_comb_2.has_fp_flags = head_next_has_fp_flags;
      // Correct branch metadata drives training and checkpoint release;
      // head_next_ok_2wide excludes branches needing recovery.
      o_commit_comb_2.misprediction = 1'b0;
      o_commit_comb_2.early_recovered = head_next_early_recovered;
      o_commit_comb_2.has_checkpoint = head_next_f_has_checkpoint;
      o_commit_comb_2.checkpoint_id = head_next_checkpoint_id;
      // redirect_pc carries the architectural next PC for branches. xRET
      // cannot retire in slot 2.
      o_commit_comb_2.redirect_pc     = head_next_f_is_branch ?
          (head_next_branch_taken ? head_next_branch_target : head_next_fallthrough_pc) : '0;
      o_commit_comb_2.predicted_taken = 1'b0;
      o_commit_comb_2.branch_taken = head_next_branch_taken;
      o_commit_comb_2.branch_target = head_next_branch_target;
      o_commit_comb_2.is_branch = head_next_f_is_branch;
      o_commit_comb_2.is_call = head_next_is_call;
      o_commit_comb_2.is_return = head_next_is_return;
      o_commit_comb_2.is_jal = head_next_is_jal;
      o_commit_comb_2.is_jalr = head_next_is_jalr;
      o_commit_comb_2.csr_addr = '0;
      o_commit_comb_2.csr_op = '0;
      o_commit_comb_2.csr_write_data = '0;
      o_commit_comb_2.is_csr = 1'b0;
      o_commit_comb_2.is_fence = 1'b0;
      o_commit_comb_2.is_fence_i = 1'b0;
      o_commit_comb_2.is_wfi = 1'b0;
      o_commit_comb_2.is_mret = 1'b0;
      o_commit_comb_2.is_amo = 1'b0;
      o_commit_comb_2.is_lr = 1'b0;
      o_commit_comb_2.is_sc = 1'b0;
      o_commit_comb_2.is_compressed = head_next_is_compressed;
    end
  end

  assign o_commit_2_valid_raw = commit_2_fire;
  // Apply the serializer stall last for timing. This output coordinates the
  // SQ commit guard and trap drain check.
  assign commit_2_store_like_early =
      commit_2_ready_early && EnableWidenCommit && i_widen_commit_ok &&
      // head_next_f_store_like also covers is_sc, which head_next_ok_2wide
      // inside commit_2_ready_early excludes, so the result is bit-identical.
      head_next_f_store_like;
  assign o_commit_2_store_like_raw = commit_2_store_like_early && !commit_stall_for_retire;

  // Registered copy of the slot-2 commit, like o_commit (unconnected in the
  // full core).
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

  // Widen-commit diagnostic: the entry immediately behind the head is also
  // valid and done, so an extra commit slot would have work this cycle.
  logic head_next_valid_done;
  assign head_next_valid_done = head_next_valid && head_next_done_eff;

  // Head-wait counters stop in the cycle a completion takes the CDB bypass.
  logic head_wait_active;
  assign head_wait_active = head_valid && !head_done_eff && !i_flush_all;

  always_comb begin
    o_perf_events = '0;

    o_perf_events.rob_empty = empty;
    o_perf_events.head_wait_int = head_wait_active && head_f_perf_wait_int;
    o_perf_events.head_wait_mem_load = head_wait_active && head_f_perf_wait_mem_load;

    if (head_wait_active) begin
      o_perf_events.head_wait_total = 1'b1;

      if (head_is_branch) begin
        o_perf_events.head_wait_branch = 1'b1;
      end else if (head_is_amo || head_is_lr) begin
        o_perf_events.head_wait_mem_amo = 1'b1;
      end else if (head_is_store || head_is_fp_store || head_is_sc) begin
        o_perf_events.head_wait_mem_store = 1'b1;
      end else begin
        unique case (head_rs_type)
          riscv_pkg::RS_INT: ;
          riscv_pkg::RS_MUL: o_perf_events.head_wait_mul = 1'b1;
          riscv_pkg::RS_MEM: ;
          riscv_pkg::RS_FP: o_perf_events.head_wait_fp = 1'b1;
          default: ;
        endcase
      end
    end

    // The IDLE stall omits readiness and permission, so reapply them here.
    // Use the full stall to count blocked sync and drain cycles.
    if (head_ready && commit_stall && !i_flush_all &&
        ((serial_state != riscv_pkg::SERIAL_IDLE) ||
         (!i_commit_hold && !i_early_recovery_en && !i_flush_en))) begin
      o_perf_events.commit_blocked_csr =
          head_is_csr || (serial_state == riscv_pkg::SERIAL_CSR_EXEC) ||
          (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN);
      o_perf_events.commit_blocked_fence =
          head_is_fence || head_is_fence_i || (serial_state == riscv_pkg::SERIAL_WAIT_SQ);
      o_perf_events.commit_blocked_wfi =
          head_is_wfi || (serial_state == riscv_pkg::SERIAL_WFI_WAIT);
      o_perf_events.commit_blocked_mret =
          head_is_mret || (serial_state == riscv_pkg::SERIAL_MRET_EXEC);
      o_perf_events.commit_blocked_trap =
          head_exception || (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);
    end

    // Count a retiring head with a done successor, before two-wide hazards.
    o_perf_events.head_and_next_done = commit_en && head_next_valid_done;
    // Count a done successor even while the head stalls. Subtract
    // head_and_next_done to count done successors behind a stalled head.
    o_perf_events.head_plus_one_done = head_next_valid_done && !i_flush_all;
    // Count opportunities after hazard checks; actual fires also require
    // EnableWidenCommit and i_widen_commit_ok.
    o_perf_events.commit_2_opportunity = commit_2_gate;
    o_perf_events.commit_2_fire_actual = commit_2_fire;

    // Widen-commit blocker decomposition. Gated on commit_en &&
    // head_next_valid_done so these fire only on cycles where
    // head_and_next_done is also 1; the sum equals head_and_next_done -
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
        head_next_is_branch && !head_next_mispredicted && !head_next_ok_2wide;
  end

  // CSR, xRET and branch entries at the head cannot take the head CDB bypass,
  // so their stored-done start and commit equations must equal the
  // head_ready forms.
`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_start_class_excludes_bypass :
      assert ((rob_valid & rob_f_cdb_bypass_ok & (rob_f_is_csr | rob_f_is_mret)) == '0);
      p_branch_class_excludes_bypass :
      assert ((rob_valid & rob_f_cdb_bypass_ok & (rob_f_is_branch | rob_f_has_checkpoint)) == '0);
      p_branch_strobes_legacy_equiv :
      assert ((commit_mispredict_early ==
               (commit_ready_early && commit_misprediction && !head_early_recovered)) &&
              (commit_correct_branch_early ==
               (commit_ready_early && head_f_has_checkpoint && !commit_misprediction &&
                !head_early_recovered)) &&
              (head_mispredict_candidate_early ==
               (head_ready && !i_commit_hold && !i_early_recovery_en && !i_flush_en &&
                !i_flush_all && !flush_after_head_commit && commit_misprediction &&
                !head_early_recovered)));
      p_csr_start_legacy_equiv :
      assert (o_csr_start == ((serial_state == riscv_pkg::SERIAL_IDLE) && head_ready &&
              !i_commit_hold && !i_early_recovery_en && head_f_is_csr &&
              !head_exception && !i_flush_en && !i_flush_all));
      p_mret_start_legacy_equiv :
      assert (o_mret_start == (((serial_state == riscv_pkg::SERIAL_IDLE) ||
              (serial_state == riscv_pkg::SERIAL_MRET_EXEC)) && head_ready &&
              !i_commit_hold && !i_early_recovery_en && head_f_is_mret &&
              !head_exception && i_sq_committed_empty));
    end
  end
`endif

`ifdef ROB_RETIRE_STALL_LOCAL_PROOF
  // Reference retirement equations, using the full serializer stall
  // (commit_stall).
  logic f_commit_en, f_commit_2_gate, f_commit_2_fire;
  assign f_commit_en = commit_ready_early && !commit_stall;
  assign f_commit_2_gate = commit_2_ready_early && !commit_stall;
  assign f_commit_2_fire = f_commit_2_gate && EnableWidenCommit && i_widen_commit_ok;
  riscv_pkg::rob_perf_events_t f_perf_events;
  always_comb begin
    f_perf_events = '0;

    f_perf_events.rob_empty = empty;
    f_perf_events.head_wait_int = head_wait_active && head_f_perf_wait_int;
    f_perf_events.head_wait_mem_load = head_wait_active && head_f_perf_wait_mem_load;

    if (head_wait_active) begin
      f_perf_events.head_wait_total = 1'b1;

      if (head_is_branch) begin
        f_perf_events.head_wait_branch = 1'b1;
      end else if (head_is_amo || head_is_lr) begin
        f_perf_events.head_wait_mem_amo = 1'b1;
      end else if (head_is_store || head_is_fp_store || head_is_sc) begin
        f_perf_events.head_wait_mem_store = 1'b1;
      end else begin
        unique case (head_rs_type)
          riscv_pkg::RS_INT: ;
          riscv_pkg::RS_MUL: f_perf_events.head_wait_mul = 1'b1;
          riscv_pkg::RS_MEM: ;
          riscv_pkg::RS_FP: f_perf_events.head_wait_fp = 1'b1;
          default: ;
        endcase
      end
    end

    // Same IDLE gate re-application as the production block; the full
    // commit_stall keeps its sync/drain retirement guards.
    if (head_ready && commit_stall && !i_flush_all &&
        ((serial_state != riscv_pkg::SERIAL_IDLE) ||
         (!i_commit_hold && !i_early_recovery_en && !i_flush_en))) begin
      f_perf_events.commit_blocked_csr =
          head_is_csr || (serial_state == riscv_pkg::SERIAL_CSR_EXEC) ||
          (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN);
      f_perf_events.commit_blocked_fence =
          head_is_fence || head_is_fence_i || (serial_state == riscv_pkg::SERIAL_WAIT_SQ);
      f_perf_events.commit_blocked_wfi =
          head_is_wfi || (serial_state == riscv_pkg::SERIAL_WFI_WAIT);
      f_perf_events.commit_blocked_mret =
          head_is_mret || (serial_state == riscv_pkg::SERIAL_MRET_EXEC);
      f_perf_events.commit_blocked_trap =
          head_exception || (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);
    end

    // Widen-commit events, as in the production block.
    f_perf_events.head_and_next_done = f_commit_en && head_next_valid_done;
    f_perf_events.head_plus_one_done = head_next_valid_done && !i_flush_all;
    f_perf_events.commit_2_opportunity = f_commit_2_gate;
    f_perf_events.commit_2_fire_actual = f_commit_2_fire;

    f_perf_events.commit_2_blocked_head_serial =
        f_commit_en && head_next_valid_done && !head_ok_2wide;
    f_perf_events.commit_2_blocked_next_serial =
        f_commit_en && head_next_valid_done && head_ok_2wide &&
        !head_next_ok_2wide && !head_next_is_branch;
    f_perf_events.commit_2_blocked_next_branch_mispred =
        f_commit_en && head_next_valid_done && head_ok_2wide &&
        head_next_is_branch && head_next_mispredicted;
    f_perf_events.commit_2_blocked_next_branch_correct =
        f_commit_en && head_next_valid_done && head_ok_2wide &&
        head_next_is_branch && !head_next_mispredicted && !head_next_ok_2wide;
  end
  always_comb begin
    assert (commit_2_gate == (commit_2_ready_early && !commit_stall));
    assert (commit_en == (commit_ready_early && !commit_stall));
    assert (o_commit_store_like_raw == (commit_store_like_early && !commit_stall));
    assert (o_commit_misprediction_raw == (commit_mispredict_early && !commit_stall));
    assert (o_commit_correct_branch_raw == (commit_correct_branch_early && !commit_stall));
    assert (o_commit_correct_branch_2_raw == (commit_correct_branch_2_early && !commit_stall));
    assert (o_head_commit_misprediction_candidate ==
        (head_mispredict_candidate_early && !commit_stall));
    assert (o_commit_2_store_like_raw == (commit_2_store_like_early && !commit_stall));
    assert (commit_2_fire == f_commit_2_fire);
    assert (o_perf_events == f_perf_events);
  end
`endif

`ifdef ROB_START_LOCAL_PROOF
  // Prove the actual producer FFs, one-hot selector, and start equations by
  // induction. No dispatch/CDB/flush traffic contracts are needed here.
  initial assume (!i_rst_n);
  always @(posedge i_clk) begin
    if (i_rst_n) p_start_head_mask_onehot : assert ($onehot(head_clear_mask));
  end
`endif

  // ===========================================================================
  // Assertions (Simulation Only)
  // ===========================================================================

`ifndef SYNTHESIS
`ifndef FORMAL

  // The registered masks must mirror the binary pointers for FF and LVT
  // one-hot reads. Wait until reset has been observed: full-core simulation
  // may begin with i_rst_n high and uninitialized masks.
  logic dbg_mask_seen_reset;
  initial dbg_mask_seen_reset = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_mask_seen_reset <= 1'b1;
    if (i_rst_n && dbg_mask_seen_reset) begin
      if (head_clear_mask != (ReorderBufferDepth'(1) << head_idx)) begin
        $error("Reorder Buffer: head_clear_mask (0x%08x) != 1 << head_idx (%0d)", head_clear_mask,
               head_idx);
      end
      if (head_next_idx_q != head_idx + 1'b1) begin
        $error("Reorder Buffer: head_next_idx_q (%0d) != head_idx + 1 (%0d)", head_next_idx_q,
               head_idx);
      end
      if (head_next_clear_mask != (ReorderBufferDepth'(1) << head_next_idx)) begin
        $error("Reorder Buffer: head_next_clear_mask (0x%08x) != 1 << head_next_idx (%0d)",
               head_next_clear_mask, head_next_idx);
      end
      // Allocation-time privilege legality assumes the current mode has a
      // valid architectural encoding.
      if (!(i_priv inside {riscv_pkg::PrivM, riscv_pkg::PrivS, riscv_pkg::PrivU})) begin
        $error("Reorder Buffer: unexpected privilege mode %0b", i_priv);
      end
      // The private CDB match-tag duplicates must track the shared tags.
      if (i_cdb_write.valid && (i_cdb_match_tag != i_cdb_write.tag)) begin
        $error("Reorder Buffer: i_cdb_match_tag (%0d) != i_cdb_write.tag (%0d)", i_cdb_match_tag,
               i_cdb_write.tag);
      end
      if (i_cdb_write_2.valid && (i_cdb_match_tag_2 != i_cdb_write_2.tag)) begin
        $error("Reorder Buffer: i_cdb_match_tag_2 (%0d) != i_cdb_write_2.tag (%0d)",
               i_cdb_match_tag_2, i_cdb_write_2.tag);
      end
      // Fast class reads must track the meta-RAM fields bit-for-bit while
      // the head entry is live.
      if (head_valid) begin
        if (head_f_store_like != (head_is_store || head_is_fp_store || head_is_sc))
          $error("Reorder Buffer: rob_f_store_like mismatch at head");
        if (head_f_is_branch != head_is_branch)
          $error("Reorder Buffer: rob_f_is_branch mismatch at head");
        if (head_f_is_csr != head_is_csr) $error("Reorder Buffer: rob_f_is_csr mismatch at head");
        if (head_f_is_fence_i != head_is_fence_i)
          $error("Reorder Buffer: rob_f_is_fence_i mismatch at head");
        if (head_f_is_wfi != head_is_wfi) $error("Reorder Buffer: rob_f_is_wfi mismatch at head");
        if (head_f_is_mret != head_is_mret)
          $error("Reorder Buffer: rob_f_is_mret mismatch at head");
        if (head_f_perf_wait_int !=
            (!head_is_branch && !head_is_amo && !head_is_lr && !head_is_store &&
             !head_is_fp_store && !head_is_sc && (head_rs_type == riscv_pkg::RS_INT))) begin
          $error("Reorder Buffer: rob_f_perf_wait_int mismatch at head");
        end
        if (head_f_perf_wait_mem_load !=
            (!head_is_branch && !head_is_amo && !head_is_lr && !head_is_store &&
             !head_is_fp_store && !head_is_sc && (head_rs_type == riscv_pkg::RS_MEM))) begin
          $error("Reorder Buffer: rob_f_perf_wait_mem_load mismatch at head");
        end
      end
    end
  end

  // Retire trace for debugging: one retire_trace.log line per retirement, in
  // program order (head, then head+1 when slot 2 retires in the same cycle).
  // PCs and values print as full 16 hex digits.
  integer retire_trace_fd;
  // Each format must be a $fwrite literal. Verilator does not format through
  // a localparam-string argument (it prints the format text itself).
  initial begin
    retire_trace_fd = $fopen("retire_trace.log", "w");
  end
  always @(posedge i_clk) begin
    if (i_rst_n && commit_en) begin
      if (head_dest_valid && !head_dest_rf && head_dest_reg != 5'd0) begin
        $fwrite(retire_trace_fd, "%0t pc=%016x rd=x%0d val=%016x\n", $time, head_pc, head_dest_reg,
                head_value_eff[riscv_pkg::XLEN-1:0]);
      end else begin
        $fwrite(retire_trace_fd, "%0t pc=%016x\n", $time, head_pc);
      end
    end
    if (i_rst_n && commit_2_fire) begin
      if (head_next_dest_valid && !head_next_dest_rf && head_next_dest_reg != 5'd0) begin
        $fwrite(retire_trace_fd, "%0t pc=%016x rd=x%0d val=%016x\n", $time, head_next_pc,
                head_next_dest_reg, head_next_value_eff[riscv_pkg::XLEN-1:0]);
      end else begin
        $fwrite(retire_trace_fd, "%0t pc=%016x\n", $time, head_next_pc);
      end
    end
  end

  // Dispatch must not allocate when full.
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

  // Dispatch carries one decoded instruction class per allocation. SFENCE.VMA
  // and SRET/DRET are subtypes of is_fence_i and is_mret respectively, so the
  // subtype bits sit outside this one-hot contract.
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && !$onehot0(
            {i_alloc_req.is_wfi, i_alloc_req.is_csr, i_alloc_req.is_fence,
                   i_alloc_req.is_fence_i, i_alloc_req.is_mret}
        )) begin
      $error("Reorder Buffer: slot-1 allocation has conflicting serializer classes");
    end
    if (i_rst_n && i_alloc_req_2.alloc_valid && !$onehot0(
            {i_alloc_req_2.is_wfi, i_alloc_req_2.is_csr, i_alloc_req_2.is_fence,
                   i_alloc_req_2.is_fence_i, i_alloc_req_2.is_mret}
        )) begin
      $error("Reorder Buffer: slot-2 allocation has conflicting serializer classes");
    end
  end

  // Dispatch must not allocate during a flush. alloc_ready also deasserts
  // then, but dispatch is required to stall on its own.
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

  // A CDB result for an invalid tag is stale, except for a late JALR link
  // broadcast (filtered below). Producers must suppress squashed and duplicate
  // results. Queue allocation is flush-gated, and the wrapper pops a memory
  // result on grant, preventing duplicate LQ/SQ deliveries.
  //
  // A stale write has these effects:
  //   - State and cause writes require rob_valid. Nonexceptional completions
  //     never overwrite an allocation-time cause.
  //   - Value and FP-flag writes to a free entry are invisible and overwritten
  //     by allocation.
  //   - During reallocation, old rob_valid blocks state/cause writes. Staged
  //     value selection and FP-flag port priority let allocation win.
  //   - In the next cycle, a CDB write wins the draining LVT and can corrupt
  //     value, flags and done. Real completions take more than one cycle from
  //     allocation; g_drain_window_check rejects this arrival.
  //   - After that, the ROB cannot distinguish a stale result from a reused
  //     tag. Producer flush and single-delivery rules must prevent it.
  logic dbg_flush_prev_cycle;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_flush_prev_cycle <= 1'b0;
    else dbg_flush_prev_cycle <= i_flush_all || i_flush_en || dbg_flush_prev_cycle;
  end

  logic [1:0] dbg_prev_alloc_valid_q;
  logic [1:0][ReorderBufferTagWidth-1:0] dbg_prev_alloc_idx_q;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_prev_alloc_valid_q <= '0;
    else begin
      dbg_prev_alloc_valid_q  <= {alloc_en_2, alloc_en};
      dbg_prev_alloc_idx_q[0] <= tail_idx;
      dbg_prev_alloc_idx_q[1] <= tail_idx_2;
    end
  end

  if (DrainWindowCheck) begin : g_drain_window_check
    always @(posedge i_clk) begin
      if (i_rst_n) begin
        for (int lane = 0; lane < 2; lane++) begin
          if (dbg_prev_alloc_valid_q[lane]) begin
            if (cdb_ram_wr_en && (i_cdb_write.tag == dbg_prev_alloc_idx_q[lane])) begin
              $error("Reorder Buffer: CDB lane0 wrote entry %0d in its staged-LVT drain window",
                     i_cdb_write.tag);
            end
            if (cdb_ram_wr_en_2 && (i_cdb_write_2.tag == dbg_prev_alloc_idx_q[lane])) begin
              $error("Reorder Buffer: CDB lane1 wrote entry %0d in its staged-LVT drain window",
                     i_cdb_write_2.tag);
            end
          end
        end
      end
    end
  end : g_drain_window_check

  // The shared link bank has one write port. Accepted slots target distinct
  // entries, so at most one may be a branch. Rejected requests do not count.
  if (SharedLinkBank) begin : g_shared_link_bank_check
    always @(posedge i_clk) begin
      if (alloc_en && alloc_en_2 && i_alloc_req.is_branch && i_alloc_req_2.is_branch &&
          (tail_idx != tail_idx_2)) begin
        $error("Reorder Buffer: branch allocations at entries %0d and %0d in one cycle", tail_idx,
               tail_idx_2);
      end
    end
  end : g_shared_link_bank_check

  // Rate-limited diagnostics for stale writes to free entries, with cycles
  // since the last flush. These should be silent apart from the filter below.
  int unsigned dbg_cyc_since_flush;
  int unsigned dbg_stale_cdb_logged;
  always @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) dbg_cyc_since_flush <= 0;
    else dbg_cyc_since_flush <= dbg_cyc_since_flush + 1;
  end
  // Treat tags committed in the last two cycles as late JALR broadcasts.
  // JALR can commit from branch_update before its link wakeup reaches CDB.
  // This filter checks only tags, so it also hides stray writes in that
  // window. Allocation absorbs a write in the reallocation cycle.
  logic [3:0] dbg_recent_commit_valid;
  logic [3:0][ReorderBufferTagWidth-1:0] dbg_recent_commit_tag;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_recent_commit_valid <= '0;
    else begin
      dbg_recent_commit_valid <= {
        dbg_recent_commit_valid[1:0], o_commit_comb_2.valid, o_commit_comb.valid
      };
      dbg_recent_commit_tag <= {dbg_recent_commit_tag[1:0], o_commit_comb_2.tag, o_commit_comb.tag};
    end
  end
  function automatic logic dbg_recently_committed(input logic [ReorderBufferTagWidth-1:0] tag);
    dbg_recently_committed = 1'b0;
    for (int k = 0; k < 4; k++) begin
      if (dbg_recent_commit_valid[k] && dbg_recent_commit_tag[k] == tag) begin
        dbg_recently_committed = 1'b1;
      end
    end
  endfunction
  always @(posedge i_clk) begin
    if (i_rst_n && dbg_stale_cdb_logged < 8) begin
      if (i_cdb_write.valid && !rob_valid[i_cdb_write.tag] && !dbg_recently_committed(
              i_cdb_write.tag
          )) begin
        dbg_stale_cdb_logged <= dbg_stale_cdb_logged + 1;
        $warning(
            "Reorder Buffer: stale CDB lane0 write tag=%0d (%0d cycles after last flush; absorbed)",
            i_cdb_write.tag, dbg_cyc_since_flush);
      end else if (i_cdb_write_2.valid && !rob_valid[i_cdb_write_2.tag] && !dbg_recently_committed(
              i_cdb_write_2.tag
          )) begin
        dbg_stale_cdb_logged <= dbg_stale_cdb_logged + 1;
        $warning(
            "Reorder Buffer: stale CDB lane1 write tag=%0d (%0d cycles after last flush; absorbed)",
            i_cdb_write_2.tag, dbg_cyc_since_flush);
      end
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

  // i_flush_after_head_commit requires a flush and cannot overlap a head
  // held by the serializer. A ready serializing head has consumed its only
  // CDB completion (CSR), or has none. No producer may rewrite it on state
  // entry or while held. Head-independent retirement events rely on this.
  always @(posedge i_clk) begin
    if (i_rst_n && i_flush_after_head_commit && !(i_flush_en || i_flush_all)) begin
      $error("Reorder Buffer: flush-after-head arrived without a recovery flush");
    end
    if (i_rst_n && serial_state != riscv_pkg::SERIAL_IDLE) begin
      if (!head_ready) begin
        $error("Reorder Buffer: serialization state %0d but head not ready", serial_state);
      end
      if (i_flush_after_head_commit) begin
        $error("Reorder Buffer: flush-after-head overlapped serializer ownership");
      end
      if (i_cdb_write.valid && (i_cdb_write.tag == head_idx)) begin
        $error("Reorder Buffer: CDB lane0 rewrote serializer-owned head %0d", head_idx);
      end
      if (i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)) begin
        $error("Reorder Buffer: CDB lane1 rewrote serializer-owned head %0d", head_idx);
      end
      if (serial_state == riscv_pkg::SERIAL_TRAP_WAIT) begin
        if (!head_exception) $error("Reorder Buffer: trap-wait owner lost its exception");
      end else if (head_exception) begin
        $error("Reorder Buffer: non-trap serializer owner acquired an exception");
      end
    end
    if (i_rst_n && head_ready &&
        (head_f_is_csr || head_f_is_fence || head_f_is_fence_i ||
         head_f_is_wfi || head_f_is_mret)) begin
      if (i_cdb_write.valid && (i_cdb_write.tag == head_idx)) begin
        $error("Reorder Buffer: CDB lane0 rewrote ready serializer head %0d", head_idx);
      end
      if (i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)) begin
        $error("Reorder Buffer: CDB lane1 rewrote ready serializer head %0d", head_idx);
      end
    end
  end


`endif  // FORMAL

`endif  // SYNTHESIS

  // ===========================================================================
  // Formal Verification
  // ===========================================================================

`ifdef FORMAL
`ifndef ROB_RETIRE_STALL_LOCAL_PROOF
`ifndef ROB_START_LOCAL_PROOF
`ifndef ROB_CONTROL_NEXT_LOCAL_PROOF
`ifndef ROB_ALLOC_LVT_LOCAL_PROOF
`ifndef ROB_BYPASS_CONTROL_LOCAL_PROOF
`ifndef ROB_RETIRE_READY_LOCAL_PROOF

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Require reset to deassert after one cycle so reset-gated assertions
  // cannot pass vacuously.
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------
  // Assume the upstream dispatch, CDB and branch interface requirements.

  // The wrapper registers match tags from the same values as the shared
  // tags. Preserve that relationship in this standalone model.
  always_comb begin
    assume (i_cdb_match_tag == i_cdb_write.tag);
    assume (i_cdb_match_tag_2 == i_cdb_write_2.tag);
    if (head_ready &&
        (head_f_is_csr || head_f_is_fence || head_f_is_fence_i ||
         head_f_is_wfi || head_f_is_mret)) begin
      // A CSR must consume its CDB completion before head_ready. Other
      // serializing classes have no producer, including on state entry.
      assume (!(i_cdb_write.valid && (i_cdb_write.tag == head_idx)));
      assume (!(i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)));
    end
    if (serial_state != riscv_pkg::SERIAL_IDLE) begin
      // Serialized classes have either no CDB producer or have already
      // consumed their sole completion before state entry.
      assume (!(i_cdb_write.valid && (i_cdb_write.tag == head_idx)));
      assume (!(i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)));
      // Commit-time branch recovery can only be pending after a branch
      // retired from IDLE; it cannot overlap an older serialized head.
      assume (!i_flush_after_head_commit);
    end
  end

  // Dispatch, flush, and replay contracts. Each except the replay rule
  // matches a simulation assertion above.
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
    assume (!(i_alloc_req.alloc_valid && full));
    assume (!(i_alloc_req_2.alloc_valid && !i_alloc_req.alloc_valid));
    assume (!(i_alloc_req_2.alloc_valid && full_for_2));
    assume (!(i_alloc_req_2.alloc_valid && (i_flush_en || i_flush_all)));
    // The controller's flush-after-head qualifier is a subtype of recovery:
    // it always arrives with the partial flush, unless a simultaneous full
    // flush suppresses that lower-priority output.
    assume (!i_flush_after_head_commit || i_flush_en || i_flush_all);
    // Memory-order replay flags only ever target loads (the wrapper's
    // validation table is written by load observations), so the head is
    // never flagged while it is a serializing-class instruction the
    // serializer may already hold.
    assume (!(|(i_replay_set_mask & head_clear_mask) &&
              (head_f_is_csr || head_f_is_mret || head_f_is_fence || head_f_is_fence_i ||
               head_f_is_wfi)));
    // ID supplies one decoded serializing class. SFENCE is a FENCE.I subtype
    // and is excluded from this check. Mixed classes could make serializer
    // priority disagree with the commit payload.
    assume (!i_alloc_req.alloc_valid || $onehot0(
        {i_alloc_req.is_wfi, i_alloc_req.is_csr, i_alloc_req.is_fence,
                      i_alloc_req.is_fence_i, i_alloc_req.is_mret}
    ));
    assume (!i_alloc_req_2.alloc_valid || $onehot0(
        {i_alloc_req_2.is_wfi, i_alloc_req_2.is_csr, i_alloc_req_2.is_fence,
                      i_alloc_req_2.is_fence_i, i_alloc_req_2.is_mret}
    ));
  end

  // Reference occupancy includes accepted allocations. Interface assumptions
  // make raw alloc_valid equal the accepted width.
  logic [ReorderBufferTagWidth:0] f_dispatch_count_next_reference;
  always_comb begin
    if (i_flush_all || i_flush_en) begin
      f_dispatch_count_next_reference = dispatch_flush_count_next;
    end else if (i_alloc_req.alloc_valid) begin
      f_dispatch_count_next_reference = count + (i_alloc_req_2.alloc_valid ? 2'd2 : 1'b1);
    end else begin
      f_dispatch_count_next_reference = count;
    end
  end

  // Forbid CDB writes to entries allocated in the previous cycle: the live
  // write would win the draining LVT and could set done. Real completions
  // cannot arrive that soon. Same-cycle reallocation collisions are allowed;
  // allocation wins and rob_valid blocks state/cause writes. Later stale
  // writes require producer-side flush and single-delivery protection.
  logic [1:0] f_prev_alloc_valid;
  logic [1:0][ReorderBufferTagWidth-1:0] f_prev_alloc_idx;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_prev_alloc_valid <= '0;
    else begin
      f_prev_alloc_valid  <= {alloc_en_2, alloc_en};
      f_prev_alloc_idx[0] <= tail_idx;
      f_prev_alloc_idx[1] <= tail_idx_2;
    end
  end
  always_comb begin
    assume (!(f_prev_alloc_valid[0] && i_cdb_write.valid &&
              (i_cdb_write.tag == f_prev_alloc_idx[0])));
    assume (!(f_prev_alloc_valid[0] && i_cdb_write_2.valid &&
              (i_cdb_write_2.tag == f_prev_alloc_idx[0])));
    assume (!(f_prev_alloc_valid[1] && i_cdb_write.valid &&
              (i_cdb_write.tag == f_prev_alloc_idx[1])));
    assume (!(f_prev_alloc_valid[1] && i_cdb_write_2.valid &&
              (i_cdb_write_2.tag == f_prev_alloc_idx[1])));
  end

  // -------------------------------------------------------------------------
  // Combinational properties (asserts, active when i_rst_n)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_full_empty_mutex : assert (!(full && empty));

      p_count_consistent : assert (count == (tail_ptr - head_ptr));

      // Parallel threshold selection must remain bit-identical to the
      // reference next-occupancy add/compare for every legal request/flush.
      p_dispatch_full_predecode_equiv :
      assert (dispatch_full_next ==
              (f_dispatch_count_next_reference ==
               ReorderBufferDepth[ReorderBufferTagWidth:0]));
      p_dispatch_full_for_2_predecode_equiv :
      assert (dispatch_full_for_2_next ==
              (f_dispatch_count_next_reference >=
               (ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1)));

      p_full_matches_ptrs :
      assert (full ==
        ((head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
         (head_idx == tail_idx)));

      p_empty_matches_ptrs : assert (empty == (head_ptr == tail_ptr));

      // Registered one-hot head images track the binary pointers exactly.
      // The one-hot reads (onehot_read / mwp_dist_ram_ohread) rely on this.
      p_head_mask_onehot : assert (head_clear_mask == (ReorderBufferDepth'(1) << head_idx));
      p_head_next_mask_onehot :
      assert (head_next_clear_mask == (ReorderBufferDepth'(1) << head_next_idx));
      p_head_next_idx_matches : assert (head_next_idx_q == head_idx + 1'b1);

      // The alloc-time final perf classes are equivalent to the head-meta
      // priority classifier for every live entry.
      if (head_valid) begin
        p_perf_wait_int_fast_class_equiv :
        assert (head_f_perf_wait_int ==
                (!head_is_branch && !head_is_amo && !head_is_lr && !head_is_store &&
                 !head_is_fp_store && !head_is_sc && (head_rs_type == riscv_pkg::RS_INT)));
        p_perf_wait_mem_load_fast_class_equiv :
        assert (head_f_perf_wait_mem_load ==
                (!head_is_branch && !head_is_amo && !head_is_lr && !head_is_store &&
                 !head_is_fp_store && !head_is_sc && (head_rs_type == riscv_pkg::RS_MEM)));
      end

      // The class properties above and these event equations together check
      // classification and same-cycle completion, bypass and flush behavior.
      p_perf_wait_int_event_equiv :
      assert (o_perf_events.head_wait_int == (head_wait_active && head_f_perf_wait_int));
      p_perf_wait_mem_load_event_equiv :
      assert (o_perf_events.head_wait_mem_load == (head_wait_active && head_f_perf_wait_mem_load));

      p_alloc_not_when_full : assert (!alloc_en || !full);

      // Allocations must target free entries. This lets allocation beat a stale
      // CDB collision; the drain-window assumption excludes the following cycle.
      p_alloc_targets_free : assert (!alloc_en || !rob_valid[tail_idx]);
      p_alloc_2_targets_free : assert (!alloc_en_2 || !rob_valid[tail_idx_2]);

      // A bypassed commit may see stored rob_done=0 until the next edge.
      p_commit_requires_valid_done : assert (!commit_en || (head_valid && head_done_eff));

      p_commit_only_at_head : assert (!commit_en || (o_commit_comb.tag == head_idx));

      p_serial_stall_blocks_commit : assert (!commit_stall || !commit_en);

      // Outside IDLE the serializer holds a pinned, completed head. In
      // TRAP_WAIT that head is exceptional; in every other state it is not.
      if (serial_state != riscv_pkg::SERIAL_IDLE) begin
        p_serial_owner_head_ready : assert (head_ready);
        if (serial_state == riscv_pkg::SERIAL_TRAP_WAIT) begin
          p_trap_wait_owns_exception : assert (head_exception);
        end else begin
          p_nontrap_serial_owner_is_clean : assert (!head_exception);
        end
      end
      if (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC) begin
        p_fence_sync_owns_fence_class : assert (head_f_is_fence_i);
      end
      if ((serial_state == riscv_pkg::SERIAL_CSR_EXEC) ||
          (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN)) begin
        p_csr_state_owns_csr_class : assert (head_f_is_csr);
      end
      if (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN) begin
        p_translation_drain_owns_translation_class : assert (head_f_csr_may_change_translation);
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential properties (asserts, require f_past_valid)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      if ($past(alloc_en)) begin
        p_alloc_sets_valid : assert (rob_valid[$past(tail_idx)]);
      end

      if ($past(commit_en) && !$past(i_flush_all)) begin
        p_commit_clears_valid : assert (!rob_valid[$past(head_idx)]);
      end

      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (empty);
      end

      if ($past(o_csr_start)) begin
        p_csr_start_contract :
        assert ($past(serial_state) == riscv_pkg::SERIAL_IDLE && $past(head_is_csr));
      end

      // o_mret_start rises only in IDLE or MRET_EXEC, with a ready xRET at the
      // head and committed stores drained.
      if ($past(o_mret_start)) begin
        p_mret_start_contract :
        assert (($past(
            serial_state
        ) == riscv_pkg::SERIAL_IDLE || $past(
            serial_state
        ) == riscv_pkg::SERIAL_MRET_EXEC) && $past(
            head_is_mret
        ) && $past(
            i_sq_committed_empty
        ));
      end

      // Both FENCE-class events mark a retirement exactly. The FENCE.I /
      // SFENCE.VMA event is combinational from the FENCE_I_SYNC state; the
      // translation-CSR event is registered once so csr_file receives the
      // registered commit payload before the final flush.
      p_native_fence_event_matches_commit :
      assert (native_fence_commit_event == (commit_en && head_f_is_fence_i));
      p_fence_class_event_is_exact_or :
      assert (o_fence_class_flush_event ==
              (native_fence_commit_event || translation_csr_commit_event_q));
      p_fence_event_flavors_are_exclusive :
      assert (!(native_fence_commit_event && translation_csr_commit_event_q));

      p_translation_event_matches_owned_commit :
      assert (translation_csr_commit_event_q == $past(
          commit_en &&
                    (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN) &&
                    head_f_is_csr && head_f_csr_may_change_translation
      ));

      // o_fence_i_flush is the event registered once, for both FENCE.I /
      // SFENCE.VMA and translation CSRs.
      p_fence_i_flush_delayed : assert (o_fence_i_flush == $past(o_fence_class_flush_event));

      if (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN && !i_sq_committed_empty) begin
        p_translation_drain_blocks_commit : assert (!commit_en);
      end
    end

    // Reset properties (check state after reset deasserts)
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_clears_valid : assert (rob_valid == '0);

      p_reset_clears_ptrs : assert (head_ptr == '0 && tail_ptr == '0);

      p_reset_serial_idle : assert (serial_state == riscv_pkg::SERIAL_IDLE);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_alloc_and_commit : cover (alloc_en && commit_en);

      // Allocation may overlap a raw CDB write, including a same-entry collision
      // where allocation wins. The drain-window assumption must allow this.
      cover_alloc_with_cdb_write : cover (alloc_en && cdb_ram_wr_en);
      cover_alloc_2_with_cdb_write_2 : cover (alloc_en_2 && cdb_ram_wr_en_2);

      cover_buffer_full : cover (full);

      cover_partial_flush : cover (i_flush_en);

      cover_csr_serialize : cover (serial_state == riscv_pkg::SERIAL_CSR_EXEC && i_csr_done);

      cover_translation_csr_drain : cover (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN);

      cover_wfi_wakeup : cover (serial_state == riscv_pkg::SERIAL_WFI_WAIT && i_interrupt_pending);

      cover_mret_complete : cover (serial_state == riscv_pkg::SERIAL_MRET_EXEC && i_mret_done);

      cover_fence_i_sync_complete :
      cover (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC && i_fence_i_sync_done);

      cover_exception_trap : cover (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);

      // Cover the event; the delayed-pulse assertion checks the following flush.
      cover_fence_class_flush_event : cover (o_fence_class_flush_event);
    end
  end

`endif  // ROB_RETIRE_READY_LOCAL_PROOF
`endif  // ROB_BYPASS_CONTROL_LOCAL_PROOF
`endif  // ROB_ALLOC_LVT_LOCAL_PROOF
`endif  // ROB_CONTROL_NEXT_LOCAL_PROOF
`endif  // ROB_START_LOCAL_PROOF
`endif  // ROB_RETIRE_STALL_LOCAL_PROOF
`endif  // FORMAL

`ifdef ROB_ALLOC_LVT_LOCAL_PROOF
  logic [AllocHeadWidth-1:0] f_alloc_head_reference;
  logic [AllocNextWidth-1:0] f_alloc_next_reference;
  // Reference uses separate field memories with the production controls,
  // without traffic or one-hot assumptions.
  rob_alloc_lvt_reference #(
      .HeadMetaWidth(HeadMetaWidth)
  ) u_alloc_lvt_reference (
      .i_clk,
      .alloc_en,
      .alloc_en_2,
      .tail_idx,
      .tail_idx_2,
      .head_idx,
      .head_next_idx,
      .head_clear_mask,
      .head_next_clear_mask,
      .i_alloc_req,
      .i_alloc_req_2,
      .alloc_checkpoint_id_data,
      .alloc_checkpoint_id_data_2,
      .alloc_head_meta_data,
      .alloc_head_meta_data_2,
      .o_head(f_alloc_head_reference),
      .o_next(f_alloc_next_reference)
  );
  always_comb begin
    assert ({head_pc, head_fallthrough_pc, head_dest_reg, head_checkpoint_id,
             head_meta_rd_data, head_csr_addr, head_csr_op, head_csr_write_data} ==
            f_alloc_head_reference);
    assert ({head_next_pc, head_next_fallthrough_pc, head_next_dest_reg,
             head_next_checkpoint_id, head_next_meta_rd_data} == f_alloc_next_reference);
  end
`endif

`ifdef ROB_BYPASS_CONTROL_LOCAL_PROOF
  always_comb assert (head_done_eff == (head_done || head_cdb_bypass));
`endif

`ifdef ROB_RETIRE_READY_LOCAL_PROOF
  initial assume (!i_rst_n);
  // Check masks and read equations together from reset, without assumptions
  // on dispatch, CDB, masks or entry state.
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      assert ($onehot(head_clear_mask));
      assert ($onehot(head_next_clear_mask));
      assert (head_ok_2wide == (head_f_ok_2wide_static &&
          !head_exception && !(head_f_is_branch && head_mispredicted)));
      assert (head_next_ok_2wide == (head_next_f_ok_2wide_static &&
          !head_next_exception &&
          !(head_next_f_is_branch && (head_next_mispredicted || head_next_early_recovered))));
      assert (commit_misprediction == (head_f_is_branch && head_mispredicted));
      assert (commit_ready_early == (head_ready && !head_exception && !i_commit_hold &&
          !i_early_recovery_en && !i_flush_en && !i_flush_all && !flush_after_head_commit));
    end
  end
`endif

endmodule : reorder_buffer
