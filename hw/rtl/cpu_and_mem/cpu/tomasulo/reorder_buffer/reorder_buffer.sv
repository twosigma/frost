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
 * 32-entry circular unified INT/FP reorder buffer with two-wide allocation and commit,
 * CDB completion, branch resolution, precise exceptions, and misprediction
 * recovery. Serializing instructions wait at the head:
 *       * WFI: stall at head until interrupt pending
 *       * CSR: reads execute speculatively, side effects applied at commit;
 *         translation-class accesses then drain the SQ and refetch
 *       * FENCE: wait for store queue to drain
 *       * FENCE.I/SFENCE.VMA: drain SQ + sync caches/TLBs + refetch
 *       * MRET: signal trap unit, redirect to mepc
 * AMO/LR/SC also require the head and an empty SQ. FP exception flags reach
 * fcsr at commit.
 *
 * Multi-bit fields use distributed RAM. Allocation-only fields have two write
 * ports; CDB-written fields have four through an LVT. Resolved targets use the
 * remaining sdp_dist_ram. Per-entry reset/flush bits remain in FFs.
 *
 * Coordination: i_sq_committed_empty orders FENCE/FENCE.I/MRET; CSR side
 * effects use o_csr_start/i_csr_done; traps use o_trap_pending/i_trap_taken;
 * i_interrupt_pending releases WFI.
 */

module reorder_buffer #(
    // Simulation-only: fatal check that no CDB write lands on an entry
    // allocated in the previous cycle (the staged-LVT drain window; see the
    // debug section).  True for the full machine, where alloc -> dispatch ->
    // issue -> FU -> registered CDB always exceeds one cycle.  The
    // reorder_buffer UNIT bench drives i_cdb_write directly without that
    // latency, so its build disables the check (tests/Makefile, -G override).
    parameter bit DrainWindowCheck = 1'b1
) (
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
    // Private duplicate copies of i_cdb_write.tag / i_cdb_write_2.tag
    // (registered in tomasulo_wrapper with equivalent_register_removal="no").
    // Used ONLY by the head/head+1 CDB-bypass match compares so they do not
    // ride the shared tag replica that also drives every RAM write address.
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_cdb_match_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_cdb_match_tag_2,

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
    // Slot-2 mirror: a correctly-predicted checkpointed branch retiring at
    // head+1 this cycle (drives the second checkpoint-free / BTB-training
    // capture path).
    output logic                              o_commit_correct_branch_2_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // Widen-commit slot 2 (head+1).  When the 2-wide gate fires, these
    // carry the second retiring entry for the same cycle; otherwise valid
    // is low and the payload is '0.  Slot 2 can never be a mispredicting
    // (or early-recovered) branch, serial op, FENCE.I, exception, or
    // AMO/LR/SC by construction; a correctly-predicted branch MAY retire
    // here, so the branch/checkpoint fields carry real values (redirect_pc
    // holds the architectural next-PC) while misprediction stays hardwired
    // 0 — slot 2 never triggers redirect recovery.
    output riscv_pkg::reorder_buffer_commit_t o_commit_2,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb_2,
    output logic                              o_commit_2_valid_raw,
    output logic                              o_commit_2_store_like_raw,

    // Slot-2 accept indication from cpu_ooo.  Asserted when the second
    // retiring entry can write the regfile this cycle.  With the dedicated
    // second regfile write port cpu_ooo ties this permanently high (1'b1);
    // the gate plumbing is kept so the signal path stays symmetric with
    // the earlier back-pressure approach.
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
    // Head decodes as AMO (drives the trap unit's AMO interrupt shield in
    // cpu_ooo: interrupts must not flush an AMO whose memory write may
    // already be in flight -- see trap_unit.i_amo_at_head).
    output logic o_head_is_amo,
    // TIMING pre-decodes for cpu_ooo's regfile-bypass qualifiers (x3 post-opt
    // -0.271 head_clear -> bypass_p*_we_q cone): dest-write field
    // conjunctions computed from the head/head+1 field nets, which are
    // one-hot/LUTRAM reads off REGISTERED masks/pointers and so arrive early
    // in the cycle. The consumer ANDs them with the 1-bit raw commit fires
    // (o_commit_valid_raw / o_commit_2_valid_raw) instead of decoding the
    // full combinational commit structs, which put the whole field mux
    // BEHIND the late commit gate. Deliberately UNGATED by commit_en /
    // commit_2_fire: the consumer's AND restores the gate, and the bits are
    // don't-care while the fires are low.
    output logic o_head_bypass_int_we_early,
    output logic o_head_bypass_fp_we_early,
    output logic o_head_next_bypass_int_we_early,
    output logic o_head_next_bypass_fp_we_early,
    // Same pattern for the direction-predictor commit-time training
    // qualifiers (the dir_update_held_* capture was another -0.227 endpoint
    // of the same cone): conditional-branch class and resolved direction of
    // head / head+1, from the early field nets, don't-care while the raw
    // fires are low.
    output logic o_head_dir_train_early,
    output logic o_head_branch_taken_early,
    output logic o_head_next_dir_train_early,
    output logic o_head_next_branch_taken_early,
    // TIMING precompute of the architectural next-PC of the head / head+1
    // entry, for cpu_ooo's interrupt_resume_pc capture.  Contract: whenever
    // o_commit_valid_raw (resp. o_commit_2_valid_raw) is high,
    // o_head_retired_next_pc (resp. o_head_next_retired_next_pc) equals
    // retired_next_pc(o_commit_comb) (resp. (o_commit_comb_2)) as computed in
    // cpu_ooo.  Computed from UNGATED head fields so the RAM read + 32-bit add
    // run in parallel with (not after) the late commit_en gating; in cycles
    // without a commit the value is unused (checked in cpu_ooo simulation).
    output logic [riscv_pkg::XLEN-1:0] o_head_retired_next_pc,
    output logic [riscv_pkg::XLEN-1:0] o_head_next_retired_next_pc,
    output riscv_pkg::exc_cause_t o_trap_cause,  // Exception cause
    // Head entry's CDB value at trap time. For a misaligned load/store the
    // load_queue/SQ path parks the faulting address here (the value slot is
    // unused for an exception), so cpu_ooo can write it to mtval.
    output logic [riscv_pkg::XLEN-1:0] o_trap_value,
    input logic i_trap_taken,  // Trap unit has taken the trap

    // xRET coordination. o_mret_start covers both xRETs (SRET rides the MRET
    // machinery); o_mret_start_is_sret qualifies which one so cpu_ooo can
    // split the trap unit's i_mret_start/i_sret_start.
    output logic                       o_mret_start,          // Signal trap unit to handle xRET
    output logic                       o_mret_start_is_sret,
    output logic                       o_mret_start_is_dret,  // ...DRET (Phase 3 M3)
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
    // Sstc (M6): S-mode stimecmp access with menvcfg.STCE=0 is illegal.
    input logic i_stimecmp_blocked,
    input logic i_sret_illegal,
    input logic i_sfence_illegal,
    input logic i_wfi_illegal,
    input logic i_priv_is_u,
    // Debug Mode (Phase 3 M3): DRET and the debug CSRs (dcsr/dpc/dscratch/
    // ddata) are legal ONLY in Debug Mode. The registered bit is sampled by
    // the allocation legality check; changes only occur through a flushing
    // trap/DRET.
    input logic i_debug_mode,

    // mcounteren counter-enable bits from csr_file ([0]=CY/cycle, [1]=TM/time,
    // [2]=IR/instret). Retained on this interface for the raw CSR-state seam;
    // allocation legality consumes the privilege-resolved i_counter_blocked.
    input logic [2:0] i_mcounteren,

    // D15: mstatus.FS == Off from csr_file. The allocation legality snapshot
    // marks any FP instruction or fflags/frm/fcsr access illegal while it is
    // set. CSR writes serialize; hardware Dirty-setting only moves FS away
    // from Off.
    input logic i_mstatus_fs_off,

    // =========================================================================
    // Pipeline Flush Control
    // =========================================================================
    // Flush requests can come from:
    // 1. Branch misprediction (partial flush via i_flush_en)
    // 2. Exception (full flush via i_flush_all)
    // 3. FENCE-class retirement (FENCE.I, SFENCE.VMA, or a
    //    translation-class CSR; full flush after commit)
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,  // Flush entries after this tag
    input logic i_flush_all,  // Flush entire Reorder Buffer (exception)
    input logic i_flush_after_head_commit,

    // FENCE-class operations trigger a pipeline and frontend flush after
    // commit. o_fence_class_flush_event is the serializer-owned semantic
    // event sampled by both the pulse register here and the flush controller's
    // replicated kill register; it is not a raw register-D interface.
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
    // Channels 1-3: slot-1 sources.  Channels 4-6: slot-2 sources.
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
  localparam int unsigned ReorderBufferCountWidth = ReorderBufferTagWidth + 1;
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
  // after all downstream consumers (RAT, SQ, cpu_ooo second regfile write
  // port, instret) were in place.
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

  // TIMING helper: read one bit of a per-entry packed FF vector using a
  // registered ONE-HOT select instead of a binary index.  Given the invariant
  // onehot == (1 << idx), |(vec & onehot) === vec[idx] bit-for-bit; the win is
  // physical only: the select bits come pre-decoded out of registers (no
  // 5-bit high-fanout head_idx net feeding a 32:1 mux tree on the commit
  // critical path).
  function automatic logic onehot_read(input logic [ReorderBufferDepth-1:0] vec,
                                       input logic [ReorderBufferDepth-1:0] onehot);
    onehot_read = |(vec & onehot);
  endfunction

  // mcounteren-bit one-hot {IR, TM, CY} for a CSR access to a Zicntr user
  // counter: cycle/time/instret and their high halves (0xC00-0xC02 /
  // 0xC80-0xC82). addr[7] (the high-half select) is ignored — both halves
  // share one enable bit; addr[1:0] picks the bit; 0xC03/0xC83 (addr[1:0]
  // == 2'b11) and the hpmcounter range (addr[6:2] != 0) stay unmatched, while
  // the separate existence check marks those unimplemented CSRs illegal. The
  // machine aliases (0xBxx) and every other privileged address are never
  // matched here; their privilege checks are separate arms of
  // alloc_legality_fault.
  function automatic logic [2:0] ucounter_onehot(input logic is_csr, input logic [11:0] addr);
    logic m;
    // Function-name assignment (not a return statement): Yosys's SV frontend
    // rejects `return {...}` concatenations, and the synth/formal targets
    // read this file.
    // At XLEN=64 the high-half addresses (addr[7]=1) are not counters at
    // all — they raise illegal via csr_static_illegal below — so only
    // the low forms reach the mcounteren gate.
    m = is_csr && (addr[11:8] == 4'hC) && (addr[6:2] == 5'b0) && !addr[7];
    ucounter_onehot = {
      m && (addr[1:0] == 2'b10), m && (addr[1:0] == 2'b01), m && (addr[1:0] == 2'b00)
    };
  endfunction

  // CSR existence map (Phase 3, plan D1): accessing an address outside this
  // set raises illegal-instruction at every privilege, per the privileged
  // spec. This replaced the historical RAZ/WI convention for unimplemented
  // CSRs — S-mode firmware (OpenSBI) probes optional CSRs by catching the
  // illegal trap, so RAZ/WI would silently mis-advertise features.
  // menvcfg/senvcfg exist as RAZ/WI (mandatory with S/U); the read-only id
  // registers mvendorid/marchid/mimpid/mconfigptr exist and read 0.
  function automatic logic csr_addr_exists(input logic [11:0] addr);
    unique case (addr)
      // F extension
      riscv_pkg::CsrFflags, riscv_pkg::CsrFrm, riscv_pkg::CsrFcsr,
      // Zicntr user counters (64-bit; high halves deliberately absent)
      riscv_pkg::CsrCycle, riscv_pkg::CsrTime, riscv_pkg::CsrInstret,
      // Supervisor CSRs
      riscv_pkg::CsrSstatus, riscv_pkg::CsrSie, riscv_pkg::CsrStvec,
      riscv_pkg::CsrScounteren, riscv_pkg::CsrSenvcfg, riscv_pkg::CsrSscratch,
      riscv_pkg::CsrSepc, riscv_pkg::CsrScause, riscv_pkg::CsrStval,
      riscv_pkg::CsrSip, riscv_pkg::CsrSatp, riscv_pkg::CsrStimecmp,
      // Machine CSRs
      riscv_pkg::CsrMstatus, riscv_pkg::CsrMisa, riscv_pkg::CsrMedeleg,
      riscv_pkg::CsrMideleg, riscv_pkg::CsrMie, riscv_pkg::CsrMtvec,
      riscv_pkg::CsrMcounteren, riscv_pkg::CsrMenvcfg, riscv_pkg::CsrMscratch,
      riscv_pkg::CsrMepc, riscv_pkg::CsrMcause, riscv_pkg::CsrMtval,
      riscv_pkg::CsrMip,
      // Debug-mode CSRs (Phase 3 M3; legal only in Debug Mode — allocation
      // legality raises illegal-instruction elsewhere)
      riscv_pkg::CsrDcsr, riscv_pkg::CsrDpc, riscv_pkg::CsrDscratch0,
      riscv_pkg::CsrDscratch1, riscv_pkg::CsrDdata,
      // Machine counters (M aliases; writes absorbed as before)
      riscv_pkg::CsrMcycle, riscv_pkg::CsrMinstret,
      // Machine id registers (read-only zero) + mhartid
      12'hF11, 12'hF12, 12'hF13, riscv_pkg::CsrMhartid, 12'hF15,
      // Custom profiling CSRs
      riscv_pkg::CsrMperfSel, riscv_pkg::CsrMperfCtl, riscv_pkg::CsrMperfData,
      riscv_pkg::CsrMperfDataH, riscv_pkg::CsrMperfCount:
      csr_addr_exists = 1'b1;
      default: csr_addr_exists = 1'b0;
    endcase
  endfunction

  // Statically-illegal CSR accesses (alloc-time pre-decode, any privilege):
  //  - An address absent from the existence map below does not exist and
  //    raises illegal-instruction at EVERY privilege (the privileged-spec
  //    rule; also what OpenSBI's trap-probing of optional CSRs relies on).
  //    This subsumes the historical RV64 Zicntr high-half rule
  //    (cycleh/timeh/instreth 0xC80-0xC82, mcycleh/minstreth 0xB80/0xB82).
  //  - A write-intending access to a read-only CSR
  //    (addr[11:10] == 2'b11) is illegal per the Zicsr spec — riscv-tests
  //    rv64mi csr test 14 (csrrw to cycle) asserts exactly this.
  function automatic logic csr_static_illegal(input logic is_csr, input logic [11:0] addr,
                                              input logic write_intent);
    csr_static_illegal =
        (is_csr && write_intent && (addr[11:10] == 2'b11)) || (is_csr && !csr_addr_exists(addr));
  endfunction


  // D15 FS gate pre-decode: instructions that touch FP architectural state
  // and therefore raise illegal-instruction when mstatus.FS == Off — every
  // F/D instruction (dispatch's is_fp_instruction covers loads/stores/
  // computes/FMAs including the x-dest flagless FMV.X/FCLASS) plus the FP
  // CSR addresses fflags/frm/fcsr (0x001-0x003).
  function automatic logic fs_gated_op(input logic is_fp, input logic is_csr,
                                       input logic [11:0] addr);
    fs_gated_op = is_fp || (is_csr && (addr[11:2] == 10'b0) && (addr[1:0] != 2'b00));
  endfunction

  // Complete allocation-time legality check. The live CSR-file inputs are a
  // cycle-exact snapshot for every instruction that can survive to the head:
  // CSR writes stop younger allocation until they commit, while trap/xRET and
  // Debug-Mode transitions flush every younger entry. Hardware FS Dirty-setting
  // only moves FS away from Off. Capturing the result in rob_exception therefore
  // removes the live privilege/CSR-state cone from commit without changing which
  // instruction traps.
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
          (fs_gated_op(req.is_fp_instruction, req.is_csr, req.csr_addr) && i_mstatus_fs_off);
    end
  endfunction

  // Forward declarations (used in debug assigns before main decl)
  // TIMING: head_ptr (via head_idx) drives every head RAM read address plus
  // pointer arithmetic — post-synth fanout was ~650 with only 4 tool-chosen
  // replicas. Cap the per-replica load so each copy can be placed next to its
  // RAM/consumer cluster. Pure register replication; semantics unchanged.
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

  // TIMING: alloc-time pre-decoded commit/perf-class FF vectors.  The commit
  // decision spine (head_ready -> commit_stall -> commit_en / store-like)
  // formerly read its instruction-class conjuncts out of the head-meta
  // LVT LUTRAM (one-hot bank select + data mux, ~3-4 LUT levels before the
  // first decision gate).  Storing the decision-relevant class bits as plain
  // per-entry FF vectors written once at allocation turns each of those
  // reads into a 2-level onehot_read straight off registers, cutting the
  // front of every commit-side critical path (ROB->SQ sq_valid guard,
  // ROB->trap/CSR arcs).  Values are bit-identical to the meta-RAM fields;
  // the meta RAM keeps carrying the payload copies consumed by the commit
  // record.  Entries are only read under head_valid, so no reset is needed
  // (same contract as the data RAMs).
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
  // Final priority-resolved classes for the two high-fanout head-wait
  // observers. Keeping these as alloc-written FF vectors avoids sending the
  // registered head mask through the head-meta LVT/classifier on the way to
  // the performance-counter increment registers. These are observer-only;
  // they do not feed commit or any other architectural decision.
  logic [ReorderBufferDepth-1:0] rob_f_perf_wait_int;
  logic [ReorderBufferDepth-1:0] rob_f_perf_wait_mem_load;
  // !(is_branch|is_csr|is_fence|is_fence_i|is_wfi|is_mret) — the head CDB
  // bypass exclusion set folded into one bit.
  logic [ReorderBufferDepth-1:0] rob_f_cdb_bypass_ok;
  // !(is_csr|is_fence|is_fence_i|is_wfi|is_mret|is_amo|is_lr|is_sc) — the
  // static (allocation-known) part of the 2-wide commit hazard gates.
  logic [ReorderBufferDepth-1:0] rob_f_ok_2wide_static;
  // Phase 3 sidebands retained after the allocation-time legality fold: SRET
  // steers the xRET start, while SFENCE.VMA steers the serializer window.
  logic [ReorderBufferDepth-1:0] rob_f_is_sret;
  // Phase 3 M3: DRET rides is_mret and steers the xRET start.
  logic [ReorderBufferDepth-1:0] rob_f_is_dret;
  logic [ReorderBufferDepth-1:0] rob_f_is_sfence;
  // Conservative allocation-time ownership for CSR writes that can affect
  // address translation. satp accesses preserve the historical conservative
  // flush behavior; mstatus/sstatus require architectural write intent.
  logic [ReorderBufferDepth-1:0] rob_f_csr_may_change_translation;

  // Head and tail pointers (declared above for forward ref)

  // Derived pointer values (without wrap bit)
  logic [ReorderBufferTagWidth-1:0] head_idx;
  logic [ReorderBufferTagWidth-1:0] tail_idx;
  // Slot-2 alloc target, wraps within ReorderBufferTagWidth modulus.
  logic [ReorderBufferTagWidth-1:0] tail_idx_2;
  // Registered ONE-HOT images of head_idx / head_next_idx.  Invariant (by
  // construction, checked by assertions below):
  //   head_clear_mask      == ReorderBufferDepth'(1) << head_idx
  //   head_next_clear_mask == ReorderBufferDepth'(1) << head_next_idx
  // Both are written ONLY in the Head Pointer Management block, in lockstep
  // with head_ptr: reset loads {1, 2} while head_ptr loads 0; commit rotates
  // them by the same 1/2 steps head_ptr advances; flushes touch neither
  // (flushes only move the tail).  TIMING: besides gating the rob_valid
  // commit-clear, they now also replace the binary head_idx as the select of
  // every head-side 32:1 read (packed FF vectors + LVT bank selects), turning
  // a high-fanout 5-bit select into per-entry registered one-hot bits.
  (* max_fanout = 16 *) logic [ReorderBufferDepth-1:0] head_clear_mask;
  (* max_fanout = 16 *) logic [ReorderBufferDepth-1:0] head_next_clear_mask;

  // Status signals (full and empty declared above for forward ref)
  logic [ReorderBufferTagWidth:0] count;

  // Head entry fields for commit — RAM-backed fields are driven by RAM
  // read ports directly; FF-backed fields are assigned from packed vectors.
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
  logic head_next_f_has_checkpoint;
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
  // NOTE: deliberately NO synthesis attributes on commit_stall or the
  // *_early aggregates below.  Three measured rounds on this spine: every
  // attribute-based constraint made it worse — round-1 (* max_fanout *) on
  // commit_en/commit_2_fire fragmented the interrupt arc (WNS -1.17);
  // round-3 (* keep *) on commit_stall + the early aggregates pinned fusion
  // boundaries in the MIDDLE of the true critical cone (commit_stall is NOT
  // a late external input — its serializer cone itself reads the head
  // metadata through the one-hot masks, so mask -> is_csr/store-like ->
  // FSM stall -> take_trap is one deep register-to-register cone; WNS
  // -0.938).  Every real structural change (one-hot head reads, ohread LVT
  // select, meip register, compare-then-mux) helped.  The two-term
  // factoring below stays as plain RTL only — synthesis is free to refuse
  // it back into the baseline-style fused tree.
  logic commit_stall;  // Stall commit for serializing instructions
  // Early/late factoring of the commit gates (pure AND re-association,
  // bit-identical conjunct sets — see Commit Enable Logic).
  logic commit_ready_early;
  logic commit_2_ready_early;
  logic commit_store_like_early;
  logic commit_mispredict_early;
  logic commit_correct_branch_early;
  logic commit_correct_branch_2_early;
  logic head_mispredict_candidate_early;
  logic commit_2_store_like_early;

  // Fast head / head+1 class reads off the alloc-time pre-decoded FF vectors
  // (registered one-hot selects, ~2 fewer LUT levels). The individual class
  // bits match their corresponding meta-RAM fields; the two final perf fields
  // match the complete priority classifier. Most feed the commit DECISION
  // spine; the perf-wait fields feed observers only. The meta-RAM reads keep
  // feeding the commit-record payload and the remaining perf classes.
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
  // NOTE: no max_fanout on commit_en.  A (* max_fanout = 96 *) was tried and
  // measured WORSE overall: the attribute forces the commit_en net to keep its
  // identity, which blocks opt_design from collapsing the serialization spine
  // (interrupt_pending -> commit_stall -> commit_en -> store-like ->
  // sq_committed_empty_for_trap -> trap_taken) into shared LUTs, adding
  // levels to the late UART/interrupt-pending arc (933 new failing paths,
  // WNS -1.17).  With the one-hot head reads the head-side arrival is early
  // enough that the un-split ~655-load net is no longer the limiter.
  logic commit_en;  // Actually commit this cycle

  // Widen-commit ("2-wide") gate. Asserted when commit_en is high this
  // cycle AND the entry immediately behind head is also retirable AND
  // neither slot hits a hazard that forces 1-wide commit (serial ops,
  // head mispredict, head+1 mispredicting branch, FENCE.I, exceptions, AMO/LR/SC).
  // commit_2_gate is the ungated opportunity signal (perf-counter input);
  // commit_2_fire (gate && EnableWidenCommit && i_widen_commit_ok) drives
  // the actual 2-wide retire: head_ptr advances by 2, rob_valid clears at
  // head+1, and o_commit_comb_2 carries the second entry.
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

  // Head entry fields from FF-backed packed vectors / distributed RAM.
  // TIMING: indexed with the registered one-hot head image (see onehot_read);
  // identical value to rob_*[head_idx] under the head_clear_mask invariant.
  assign head_valid = onehot_read(rob_valid, head_clear_mask);
  assign head_done = onehot_read(rob_done, head_clear_mask);
  // Execution exceptions and allocation-time legality faults share this
  // stored bit. Keeping legality out of the live head cone makes every commit,
  // serializer and trap consumer start from the same early one-hot FF read.
  assign head_exception = onehot_read(rob_exception, head_clear_mask);
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
  assign head_fallthrough_pc = head_pc + (head_is_compressed ? 64'd2 : 64'd4);

  // Head+1 entry fields from FF-backed packed vectors / distributed RAM.
  // The RAM-backed multi-bit fields (pc, dest_reg, value, branch_target_*,
  // predicted_target, checkpoint_id, meta, csr_*, exc_cause, fp_flags) are
  // driven by dedicated read-port replicas instantiated alongside the head
  // RAMs below.  1-bit packed-vector fields share the existing FF storage
  // and are indexed at head_next_idx for free.
  assign head_next_idx = head_idx + 1'b1;
  // TIMING: same one-hot substitution as the head fields, using the
  // registered head_next_clear_mask (== 1 << head_next_idx by construction).
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

  // Widen-commit hazard gates.  Head may be a correctly-predicted branch;
  // head+1 may also be a correctly-predicted one (see below).  Both must be
  // plain non-serial instructions for 2-wide to fire.
  assign head_ok_2wide = head_f_ok_2wide_static &&
      !head_exception && !(head_f_is_branch && head_mispredicted);
  // head+1 MAY be a correctly-predicted branch: the second checkpoint-free
  // RAT port and the slot-2 correct-branch training capture handle its
  // retire side effects.  Mispredicted (or early-recovered) branches still
  // retire 1-wide at the head so the single recovery path is preserved.
  // Allocation-time legality is already stored in head_next_exception, so an
  // FS-Off FP operation cannot retire through slot 2.
  assign head_next_ok_2wide = head_next_f_ok_2wide_static &&
      !head_next_exception &&
      !(head_next_f_is_branch && (head_next_mispredicted || head_next_early_recovered));

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
  // TIMING: matches compare the private duplicate tag copies (identical
  // values to i_cdb_write.tag / i_cdb_write_2.tag — asserted below).
  assign head_cdb_match = i_cdb_write.valid && (i_cdb_match_tag == head_idx);
  assign head_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_match_tag_2 == head_idx);
  // TIMING: per-lane bypass structure. The former shape computed one shared
  // head_cdb_bypass select ((match||match2) && !exc_sel && ok, exc_sel a
  // match-steered mux) that fanned to BOTH the 1-bit control side
  // (head_done_eff -> head_ready -> commit/mret/trap decisions) and the
  // 64-bit value/fp-flags muxes; opt_design fused the control bit into the
  // wide value-mux LUT cone, adding ~3 levels to every commit-side arc.
  // Splitting per lane gives the value muxes their own selects and keeps the
  // control OR flat. Bit-identical: the CDB lanes carry distinct tags, so at
  // most one lane matches the head (resp. head+1).
  logic head_cdb_bypass_l1;
  logic head_cdb_bypass_l2;
  assign head_cdb_bypass_l1 = head_cdb_match && !i_cdb_write.exception && head_f_cdb_bypass_ok;
  assign head_cdb_bypass_l2 = head_cdb_match_l2 && !i_cdb_write_2.exception && head_f_cdb_bypass_ok;
  assign head_cdb_bypass = head_cdb_bypass_l1 || head_cdb_bypass_l2;

  assign head_next_cdb_match = i_cdb_write.valid && (i_cdb_match_tag == head_next_idx);
  assign head_next_cdb_match_l2 = i_cdb_write_2.valid && (i_cdb_match_tag_2 == head_next_idx);
  // head_next_cdb_bypass is gated further by head_next_ok_2wide at its only
  // consumer (commit_2_gate), so the bypass itself only needs the exception
  // exclusion to cover the trap path. Per-lane structure as for the head.
  logic head_next_cdb_bypass_l1;
  logic head_next_cdb_bypass_l2;
  assign head_next_cdb_bypass_l1 = head_next_cdb_match && !i_cdb_write.exception;
  assign head_next_cdb_bypass_l2 = head_next_cdb_match_l2 && !i_cdb_write_2.exception;
  assign head_next_cdb_bypass = head_next_cdb_bypass_l1 || head_next_cdb_bypass_l2;

  logic head_done_eff;
  logic head_next_done_eff;
  assign head_done_eff = head_done || head_cdb_bypass;
  assign head_next_done_eff = head_next_done || head_next_cdb_bypass;

  // Value / fp_flags forwarding only applies to the CDB bypass (stores don't
  // write these fields). Per-lane selects (see the head_cdb_bypass TIMING
  // note): the wide muxes never see a combined bypass bit, so the control
  // side cannot be fused into their LUT cone. At most one lane matches, so
  // the priority order is immaterial.
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

  // Head is ready to potentially commit
  assign head_ready = head_valid && head_done_eff;

  // 2-wide commit gate.  commit_2_gate is the "opportunity" signal — it
  // fires whenever the ROB could theoretically retire two entries this
  // cycle, independent of the master enable and the slot-2 accept input.
  // This feeds the perf counter so we can keep measuring upper bound
  // even when widen-commit is gated off.  commit_2_fire is what the
  // output / retire logic actually acts on — it ANDs the opportunity with
  // the master enable and the cpu_ooo slot-2 accept signal
  // (i_widen_commit_ok, currently tied high).
  // TIMING (late-side factoring, see Commit Enable Logic): commit_en && X
  // == (commit_ready_early && X) && !commit_stall — same conjunct set,
  // re-associated so the late commit_stall enters one final LUT.
  assign commit_2_ready_early = commit_ready_early && head_next_valid && head_next_done_eff &&
                                head_ok_2wide && head_next_ok_2wide;
  assign commit_2_gate = commit_2_ready_early && !commit_stall;
  // NOTE: no max_fanout on commit_2_fire — a forced net boundary here sat
  // mid-spine on the late UART/interrupt-pending -> trap_taken arc (it
  // appeared as a distinct fo=40 level in the round-1 -1.17 post-opt path).
  logic commit_2_fire;
  assign commit_2_fire = commit_2_gate && EnableWidenCommit && i_widen_commit_ok;

  // ===========================================================================
  // Distributed RAM Write Enables and Data
  // ===========================================================================

  logic alloc_en;
  logic alloc_en_2;
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

  // Exception causes differ from the ordinary value/fp-flags payloads:
  // allocation may already have installed an illegal-instruction cause, so a
  // non-exception CDB completion must leave it untouched. Qualifying with
  // rob_valid also makes an exceptional stale CDB harmless in the entry's own
  // reallocation cycle; otherwise the cause RAM's higher-numbered CDB LVT port
  // would beat the allocation port and poison the new entry.
  logic cdb_exc_cause_wr_en;
  logic cdb_exc_cause_wr_en_2;
  assign cdb_exc_cause_wr_en   = cdb_state_wr_en && i_cdb_write.exception;
  assign cdb_exc_cause_wr_en_2 = cdb_state_wr_en_2 && i_cdb_write_2.exception;

  logic branch_wr_en;
  assign branch_wr_en = i_branch_update.valid && !i_flush_all && rob_valid[i_branch_update.tag];

  // Capture the complete legality verdict and its cause beside the other
  // allocation data. Legal entries start with exception/cause zero; a later
  // exceptional CDB completion sets the flag and replaces the cause.
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

  // Only one slot in a bundle can be a branch, so
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

  // Alloc-time write of the pre-decoded commit-class FF vectors (see decl).
  // Written once per entry at allocation, in lockstep with the meta RAM;
  // no reset / no flush clear needed because every consumer is gated by
  // head_valid (rob_valid), which does reset and flush-clear.
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
  // Alloc-written fields (read at head / head+1).  Since 2-wide dispatch
  // these use mwp_dist_ram_ohread with 2 write ports (slot-1 + slot-2 alloc).
  // ---------------------------------------------------------------------------

  // 2-write port: slot-1 alloc (port 0) + slot-2 alloc (port 1).  Port 1
  // writes when slot-2 allocates its ROB entry in the same cycle as slot-1.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_pc (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_pc)
  );

  // Widen-commit replica: head+1 read port for pc.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_pc_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_pc)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_dest_reg (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_dest_reg)
  );

  // Widen-commit replica: head+1 read port for dest_reg.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_dest_reg_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_dest_reg)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_predicted_target (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.predicted_target, i_alloc_req.predicted_target}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_predicted_target)
  );

  // Widen-commit replica: head+1 read port for predicted_target.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_predicted_target_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.predicted_target, i_alloc_req.predicted_target}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_predicted_target)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_checkpoint_id (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_checkpoint_id)
  );

  // Widen-commit replica: head+1 read port for checkpoint_id.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_checkpoint_id_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_checkpoint_id)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_head_meta (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_meta_rd_data)
  );

  // Widen-commit replica: head+1 read port for head_meta.  This feeds the
  // head_next_* hazard flags consumed by the 2-wide commit gate.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_head_meta_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_meta_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Multi-write-port fields (allocation + CDB).
  // These use mwp_dist_ram (mwp_dist_ram_ohread for head-side reads) with
  // 4 write ports: Port 0 = slot-1 alloc, Port 1 = slot-2 alloc,
  // Port 2 = CDB lane 0, Port 3 = CDB lane 1 (highest pri; the arbiter
  // guarantees the two CDB lanes never collide on an address).
  // ---------------------------------------------------------------------------

  // rob_value: 4 write ports (alloc1 + alloc2 + CDB lane 0 + CDB lane 1).
  // Twelve instances with identical writes, different read addresses
  // (head, head+1, RAT, dispatch bypass x6, fmul-pending x3).
  //
  // ROUTABILITY -- NUM_NARROW_WRITE_PORTS(2)/NARROW_DATA_WIDTH(XLEN) on every
  // value instance: the two alloc ports only ever write zero-extended XLEN
  // link addresses (see alloc_value_data), so their banks store just the low
  // XLEN bits and reads reconstruct zero upper halves.  This deletes the
  // alloc banks' FLEN upper halves (a quarter of each value RAM's LUTRAM,
  // x12 replicas) plus the matching alloc write-address/data fanout -- part
  // of the X3 backend-band congestion relief.  The RAM modules assert the
  // zero-upper contract in simulation.
  //
  // TIMING -- NUM_STAGED_LVT_PORTS(2) on every value instance: the alloc
  // enables arrive late (the id_stall -> id_valid -> dispatch-gate cone) and
  // previously drove every LVT bit of all 12 replicas plus the alloc bank
  // write enables -- one ~850-load net, the x3 post-opt WNS (-0.363, 578
  // failing endpoints, 72% of TNS).  With staging, the alloc ports (0/1)
  // still write their banks in the alloc cycle, but the LVT update runs one
  // cycle later from registers inside the RAM module, so the late enables
  // load only the staging flops and the bank WE pins (which have ~0.9 ns of
  // slack -- they carry no downstream decode).  Reads stay cycle-exact via
  // the module's per-entry effective-LVT correction.  The load-bearing case
  // is JAL, which is done-at-alloc and whose link value may be read (head
  // commit or dispatch bypass) at alloc+1.  CDB lanes (2/3) stay live: a CDB
  // write in an older allocation's drain cycle wins the LVT because a live
  // write beats a staged drain.  A stale CDB write colliding with a new
  // allocation in the SAME cycle is legal and loses to the allocation via
  // the lvt_eff override;
  // the drain-window tripwire below checks the one unsafe window.
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(head_next_idx),
      .i_read_onehot(head_next_clear_mask),
      .o_read_data(head_next_value)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH            (ReorderBufferTagWidth),
      .DATA_WIDTH            (FLEN),
      .NUM_WRITE_PORTS       (4),
      .NUM_STAGED_LVT_PORTS  (2),
      .NUM_NARROW_WRITE_PORTS(2),
      .NARROW_DATA_WIDTH     (XLEN)
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
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
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_bypass_tag_6),
      .o_read_data(o_bypass_value_6)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH            (ReorderBufferTagWidth),
      .DATA_WIDTH            (FLEN),
      .NUM_WRITE_PORTS       (4),
      .NUM_STAGED_LVT_PORTS  (2),
      .NUM_NARROW_WRITE_PORTS(2),
      .NARROW_DATA_WIDTH     (XLEN)
  ) u_rob_value_fmul_pending_1 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_1),
      .o_read_data(o_fmul_pending_bypass_value_1)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH            (ReorderBufferTagWidth),
      .DATA_WIDTH            (FLEN),
      .NUM_WRITE_PORTS       (4),
      .NUM_STAGED_LVT_PORTS  (2),
      .NUM_NARROW_WRITE_PORTS(2),
      .NARROW_DATA_WIDTH     (XLEN)
  ) u_rob_value_fmul_pending_2 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_2),
      .o_read_data(o_fmul_pending_bypass_value_2)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH            (ReorderBufferTagWidth),
      .DATA_WIDTH            (FLEN),
      .NUM_WRITE_PORTS       (4),
      .NUM_STAGED_LVT_PORTS  (2),
      .NUM_NARROW_WRITE_PORTS(2),
      .NARROW_DATA_WIDTH     (XLEN)
  ) u_rob_value_fmul_pending_3 (
      .i_clk,
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({i_cdb_write_2.value, i_cdb_write.value, alloc_value_data_2, alloc_value_data}),
      .i_read_address(i_fmul_pending_bypass_tag_3),
      .o_read_data(o_fmul_pending_bypass_value_3)
  );

  // rob_exc_cause: allocation installs zero or IllegalInstr; only exceptional,
  // valid-qualified CDB completions replace it. CDB ports remain highest
  // priority so a real execution exception overrides an allocation-time fault.
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

  // Widen-commit replica: head+1 read port for exc_cause.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(4)
  ) u_rob_exc_cause_next (
      .i_clk,
      .i_write_enable({cdb_exc_cause_wr_en_2, cdb_exc_cause_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.exc_cause, i_cdb_write.exc_cause, alloc_exc_cause_data_2, alloc_exc_cause_data
      }),
      .i_read_address(head_next_idx),
      .i_read_onehot(head_next_clear_mask),
      .o_read_data(head_next_exc_cause)
  );

  // rob_fp_flags: 4 write ports (alloc1='0 + alloc2='0 + CDB lanes 0/1), 1 read port (head)
  mwp_dist_ram_ohread #(
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
      .i_write_enable({cdb_ram_wr_en_2, cdb_ram_wr_en, alloc_en_2, alloc_en}),
      .i_write_address({i_cdb_write_2.tag, i_cdb_write.tag, tail_idx_2, tail_idx}),
      .i_write_data({
        i_cdb_write_2.fp_flags, i_cdb_write.fp_flags, FpFlagsWidth'(0), FpFlagsWidth'(0)
      }),
      .i_read_address(head_next_idx),
      .i_read_onehot(head_next_clear_mask),
      .o_read_data(head_next_fp_flags)
  );

  // Branch target storage only needs one writer per producer class:
  // JAL writes its architectural target at allocation, while conditional
  // branches/JALR write their resolved target on branch update. Split the
  // field across two single-write memories and select at the head instead of
  // paying the timing cost of a 2-write-port LVT RAM here.
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

  // CSR address RAM (12-bit, written at allocation)
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (12),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_addr (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_addr, i_alloc_req.csr_addr}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_addr)
  );

  // Widen-commit replica: head+1 read port for csr_addr.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (12),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_addr_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_addr, i_alloc_req.csr_addr}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_csr_addr)
  );

  // CSR op RAM (3-bit funct3, written at allocation)
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (3),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_op (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_op, i_alloc_req.csr_op}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_op)
  );

  // Widen-commit replica: head+1 read port for csr_op.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (3),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_op_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_op, i_alloc_req.csr_op}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_csr_op)
  );

  // CSR write data RAM (32-bit, written at allocation)
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_write_data (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_write_data, i_alloc_req.csr_write_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_write_data)
  );

  // Widen-commit replica: head+1 read port for csr_write_data.
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_csr_write_data_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_write_data, i_alloc_req.csr_write_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
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
  // occupancy that includes allocation but not same-cycle commit. Internal
  // allocation still uses the exact combinational full/full_for_2 signals above.
  //
  // TIMING: the accepted request valids are a hard interface contract (asserted
  // below): dispatch never presents slot 1 while full/flushing, and slot 2 also
  // requires slot 1 plus !full_for_2. Use those raw valids only for this small
  // status cone. Reusing alloc_en would put the fullness flops behind the same
  // high-fanout enable that writes every ROB RAM replica.
  //
  // Likewise, precompute the three possible occupancy thresholds in parallel.
  // The late dispatch valid then selects width 0/1/2 instead of feeding an
  // occupancy add followed by a compare. This is exactly the former
  // count+allocation result for every legal request and changes no cycle.
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
      // Preserve the exact pointer-derived flush occupancy calculation.
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
        // Legality is complete at allocation; execution may later add a
        // higher-priority exception through an exceptional CDB completion.
        rob_exception[tail_idx] <= alloc_legality_fault_data;

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
        rob_exception[tail_idx_2] <= alloc_legality_fault_data_2;

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
      // Value and fp_flags are written on every CDB completion. Exception
      // state/cause are sticky across a non-exception completion so an
      // allocation-time legality fault cannot be erased. An exceptional
      // completion sets the bit and its cause RAM port replaces the cause.
      if (cdb_state_wr_en) begin
        rob_done[i_cdb_write.tag] <= 1'b1;
        if (i_cdb_write.exception) rob_exception[i_cdb_write.tag] <= 1'b1;
      end
      // Lane-1 (2-wide CDB): distinct tag from lane 0, so these non-blocking
      // writes target a different rob_done/rob_exception index — no collision.
      if (cdb_state_wr_en_2) begin
        rob_done[i_cdb_write_2.tag] <= 1'b1;
        if (i_cdb_write_2.exception) rob_exception[i_cdb_write_2.tag] <= 1'b1;
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
      // TIMING: class inputs come from the alloc-time pre-decoded FF vectors
      // (bit-identical to the meta-RAM fields) so the commit_stall cone
      // starts from registers, not the LVT meta read.
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
      .o_commit_stall                  (commit_stall)
  );

  // ===========================================================================
  // Commit Enable Logic
  // ===========================================================================

  // Commit when head is ready, no stall, and no flush in progress.
  // The old branch_update collision guard (which delayed commit when a
  // mispredicted branch resolved via CDB in the same cycle as commit) is
  // removed: (a) JAL — the stated motivation — never produces branch_update
  // (is_jal_issue is excluded); (b) a conditional branch cannot resolve and
  // commit in the same cycle (head_cdb_bypass excludes branches, so its done
  // bit trails branch_update by one cycle), and an early_mispredict_fire
  // coinciding with a head-mispredict commit is dropped one cycle later by
  // the !mispredict_recovery_pending term in early_mispredict_active
  // (early_misprediction_recovery.sv) — the fire-time candidate gate this
  // comment used to cite no longer exists; (c) removing the guard breaks
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
  // TIMING (late-side factoring): commit_en and every commit_stall-qualified
  // derivative are written as <kept early aggregate> && !commit_stall.  The
  // conjunct SETS are identical to the flat originals (pure AND
  // re-association; AND is associative/commutative, so the value is
  // bit-identical for every input combination).  All early conjuncts are
  // register-sourced and settle well before commit_stall's interrupt arc, so
  // the late arc traverses exactly one LUT per gate — restoring (and slightly
  // beating) the baseline netlist's shape, where commit_stall entered the
  // second-to-last commit_en LUT and the derivatives chained behind the
  // commit_en broadcast.
  assign commit_ready_early = head_ready && !head_exception && !i_commit_hold &&
                              !i_early_recovery_en && !i_flush_en && !i_flush_all &&
                              !flush_after_head_commit;
  assign commit_en = commit_ready_early && !commit_stall;

  // Raw misprediction at commit (early_recovered handled externally by cpu_ooo)
  assign commit_misprediction = head_f_is_branch && head_mispredicted;
  assign o_commit_valid_raw = commit_en;
  assign commit_store_like_early = commit_ready_early && head_f_store_like;
  assign o_commit_store_like_raw = commit_store_like_early && !commit_stall;
  assign commit_mispredict_early =
      commit_ready_early && commit_misprediction && !head_early_recovered;
  assign o_commit_misprediction_raw = commit_mispredict_early && !commit_stall;
  assign commit_correct_branch_early = commit_ready_early && head_f_has_checkpoint &&
                                       !commit_misprediction && !head_early_recovered;
  assign o_commit_correct_branch_raw = commit_correct_branch_early && !commit_stall;
  // Slot-2 correct-branch strobe: qualified on the full widen-commit fire
  // (same late-side factoring as commit_2_store_like_early below).  The
  // mispredicted/early-recovered exclusions are already inside
  // head_next_ok_2wide (hence commit_2_ready_early); kept explicit here for
  // symmetry with the slot-1 strobe.
  assign commit_correct_branch_2_early =
      commit_2_ready_early && EnableWidenCommit && i_widen_commit_ok &&
      head_next_f_has_checkpoint && !head_next_mispredicted && !head_next_early_recovered;
  assign o_commit_correct_branch_2_raw = commit_correct_branch_2_early && !commit_stall;
  // Same-cycle head-mispredict indicator without the branch_update collision
  // term. Outer control logic uses this to suppress younger branch resolution
  // without feeding branch_update back into commit_en.
  // (Same factoring; note the original conjunct set has no !head_exception.)
  assign head_mispredict_candidate_early =
      head_ready && !i_commit_hold && !i_early_recovery_en &&
      !i_flush_en && !i_flush_all && !flush_after_head_commit &&
      commit_misprediction && !head_early_recovered;
  assign o_head_commit_misprediction_candidate = head_mispredict_candidate_early && !commit_stall;

  // ===========================================================================
  // External Coordination Outputs
  // ===========================================================================

  // CSR execution signal - asserted when entering CSR_EXEC state
  assign o_csr_start = (serial_state == riscv_pkg::SERIAL_IDLE) && head_ready &&
                       !i_commit_hold &&
                       !i_early_recovery_en &&
                       head_f_is_csr && !head_exception &&
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
                        head_f_is_mret && !head_exception &&
                        i_sq_committed_empty;
  // Which xRET: cpu_ooo splits o_mret_start into the trap unit's
  // i_mret_start/i_sret_start with this qualifier (don't-care while
  // o_mret_start is low).
  assign o_mret_start_is_sret = head_f_is_sret;
  assign o_mret_start_is_dret = head_f_is_dret;

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
      ((serial_state == riscv_pkg::SERIAL_TRAP_WAIT) ||
       (head_ready && !i_commit_hold && !i_early_recovery_en && head_exception));
  assign o_trap_pc = head_pc;
  // WFI interrupt-resume-PC seed (Bug#2): expose that the ROB head is a WFI so
  // cpu_ooo can seed interrupt_resume_pc = wfi_pc+4 while the WFI stalls at the
  // head. A machine interrupt taken at a *drain-gated* WFI (a committed store
  // still draining) otherwise flushes the WFI before it commits, leaving
  // interrupt_resume_pc at the pre-WFI instruction's next-PC (== the WFI's own
  // PC) -> mepc=wfi_pc instead of the spec-required wfi_pc+4.
  assign o_head_is_wfi = head_f_is_wfi;
  // AMO interrupt shield source: the f-partition one-hot read of the head's
  // is_amo flag, valid-qualified and registered in cpu_ooo before use.
  assign o_head_is_amo = head_f_is_amo;
  assign o_trap_cause = head_exc_cause;
  assign o_trap_value = head_value[XLEN-1:0];

  // Regfile-bypass pre-decodes (see port comment). Field-equivalent to the
  // o_commit_comb / o_commit_comb_2 struct fields whenever the corresponding
  // raw fire is high: same head/head+1 nets, same conjunctions as cpu_ooo's
  // previous struct-decoded expressions (p0 keeps the !exception && !is_csr
  // defensive terms; p1 never had them -- the commit_2 gate excludes
  // exceptions and serial classes at head+1 by construction).
  assign o_head_bypass_int_we_early = head_dest_valid && !head_exception &&
      !head_is_csr && !head_dest_rf && |head_dest_reg;
  assign o_head_bypass_fp_we_early = head_dest_valid && !head_exception &&
      !head_is_csr && head_dest_rf;
  assign o_head_next_bypass_int_we_early =
      head_next_dest_valid && !head_next_dest_rf && |head_next_dest_reg;
  assign o_head_next_bypass_fp_we_early = head_next_dest_valid && head_next_dest_rf;
  // Direction-predictor training pre-decodes (see port comment). is_branch is
  // true for branches AND jumps in the commit structs, so the conditional
  // class excludes JAL/JALR -- identical conjunction to the previous
  // struct-decoded expressions in cpu_ooo.
  assign o_head_dir_train_early = head_is_branch && !head_is_jal && !head_is_jalr;
  assign o_head_branch_taken_early = head_branch_taken;
  assign o_head_next_dir_train_early =
      head_next_f_is_branch && !head_next_is_jal && !head_next_is_jalr;
  assign o_head_next_branch_taken_early = head_next_branch_taken;

  // TIMING: retired-next-PC precompute (see port comment).  Equivalence with
  // cpu_ooo's retired_next_pc(o_commit_comb) whenever o_commit_comb.valid:
  //  - head MRET:  retired_next_pc returns redirect_pc, and the o_commit_comb
  //    redirect chain puts i_mepc there for MRET (highest priority);
  //  - head branch: retired_next_pc returns redirect_pc = taken ?
  //    head_branch_target : head_fallthrough_pc;
  //  - otherwise:  retired_next_pc returns pc + (is_compressed ? 2 : 4) with
  //    is_compressed == head_is_compressed == head_fallthrough_pc.
  // Slot 2 may retire a correctly-predicted branch (never MRET — serial
  // class); its next-PC arm below mirrors the head's taken-branch handling.
  // xRET return PC: mepc for MRET, sepc for SRET, dpc for DRET (the is_sret/
  // is_dret sidebands qualify the shared is_mret class).
  logic [XLEN-1:0] xret_return_pc;
  assign xret_return_pc = head_f_is_dret ? i_dpc : head_f_is_sret ? i_sepc : i_mepc;
  assign o_head_retired_next_pc =
      head_f_is_mret ? xret_return_pc :
      (head_f_is_branch && head_branch_taken) ? head_branch_target :
      head_fallthrough_pc;
  // A correctly-predicted TAKEN branch may now retire at head+1; the
  // architectural next-PC (interrupt resume point after a dual commit) must
  // then be the branch target, mirroring the head slot above.  MRET cannot
  // sit at head+1 (serial class), so no mepc arm is needed.
  assign o_head_next_retired_next_pc =
      (head_next_f_is_branch && head_next_branch_taken) ? head_next_branch_target :
      head_next_pc + (head_next_is_compressed ? 64'd2 : 64'd4);

  // FENCE-class flush signal. Native FENCE.I/SFENCE.VMA and translation CSR
  // retirement are owned by registered serializer states, so this D cone no
  // longer rediscovers either event through the live ROB-head/commit spine.
  //
  // The translation event is already delayed one cycle inside the serializer:
  // cycle T retires and captures the CSR into the registered commit bus;
  // cycle T+1 writes csr_file while this register samples the semantic event;
  // cycle T+2 exposes the flush alongside any corresponding registered
  // csr_file TLB-invalidate request. Native FENCE.I keeps its historical
  // commit-to-flush latency.
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

  // The serializer exports the phase-identical registered SFENCE window.
  // Capturing it from the serializer's next state keeps the live head onehot
  // read out of the DTLB/PTW invalidate cone; plain FENCE.I remains excluded.

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
        // The xepc is guaranteed stable here: the xRET handshake
        // (o_mret_start/i_mret_done) completes before commit_en asserts,
        // so the trap unit has finished consuming mepc/sepc by this point.
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
      // TIMING: the stored per-entry bit, unconditionally. The historical
      // branch arm reconstructed compressedness from the alloc-written link
      // value (head_value == head_pc + 2) -- a one-hot value-RAM read, a
      // 64-bit add, and a 64-bit compare (two CARRY8 chains in series) on the
      // commit-record D cone, the deepest logic path of the placed design
      // (15 levels into mispredict_commit_q). It is redundant by
      // construction: id_stage computes link_address = pc + (is_compressed ?
      // 2 : 4) from the SAME decode bit dispatch stores into
      // rob_is_compressed, dispatch/JALR write only that link into the value
      // RAM, and both slot-2 commit and head_fallthrough_pc already trust the
      // stored bit for branches. A sim tripwire below re-derives the link
      // form on every branch commit and $error's on divergence.
      o_commit_comb.is_compressed   = head_is_compressed;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Equivalence tripwire for the is_compressed simplification above: the
  // retired link-derived view must agree with the stored per-entry bit on
  // every branch-class commit. head_value holds the alloc-written (JALR:
  // CDB-rewritten) link = pc + (is_compressed ? 2 : 4), so divergence here
  // means a producer stopped honoring that contract and the simplification
  // must be revisited.
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
`endif
`endif

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
  // Slot 2 is populated whenever commit_2_fire fires.  By construction slot
  // 2 can never be a mispredicting branch/serial/exception/AMO/LR/SC; a
  // correctly-predicted branch may retire here, so the branch/checkpoint
  // fields (is_branch, branch_taken, branch_target, is_call/return/jal/jalr,
  // has_checkpoint, checkpoint_id, redirect_pc) carry real data alongside
  // the regfile-writeback + SQ-release fields (dest_*, value, pc, is_store,
  // is_fp_store, fp_flags, tag, is_compressed, early_recovered); the
  // CSR/serial flags and misprediction stay zeroed.
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
      // Slot 2 may retire a CORRECTLY-PREDICTED branch (mispredicted /
      // early-recovered branches are excluded by head_next_ok_2wide, so
      // misprediction stays hardwired 0 and no redirect is ever needed).
      // Branch/checkpoint fields carry real values for the slot-2
      // correct-branch training capture and checkpoint release.
      o_commit_comb_2.misprediction = 1'b0;
      o_commit_comb_2.early_recovered = head_next_early_recovered;
      o_commit_comb_2.has_checkpoint = head_next_f_has_checkpoint;
      o_commit_comb_2.checkpoint_id = head_next_checkpoint_id;
      // For branches, redirect_pc carries the architectural next-PC (target
      // if taken, fall-through otherwise) — the retired_next_pc() contract.
      // MRET can never sit at head+1, so no mepc arm is needed.
      o_commit_comb_2.redirect_pc     = head_next_f_is_branch ?
          (head_next_branch_taken ? head_next_branch_target :
           head_next_pc + (head_next_is_compressed ? 64'd2 : 64'd4)) : '0;
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
  // TIMING (late-side factoring): commit_2_fire && X == (commit_2_ready_early
  // && EnableWidenCommit && i_widen_commit_ok && X) && !commit_stall — same
  // conjunct set, one late LUT.  This output feeds sq_committed_empty_for_trap
  // (the trap arc of the uart spine) and the SQ same-cycle commit guard.
  assign commit_2_store_like_early =
      commit_2_ready_early && EnableWidenCommit && i_widen_commit_ok &&
      // head_next_f_store_like also covers is_sc, which is excluded by
      // head_next_ok_2wide inside commit_2_ready_early — bit-identical here.
      head_next_f_store_like;
  assign o_commit_2_store_like_raw = commit_2_store_like_early && !commit_stall;

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

  // Cycle-exact qualifier shared by every head-wait bucket. The class bits
  // are allocation-time state, but the done/CDB-bypass/flush terms remain
  // live so the observer pulse boundaries are unchanged.
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
          riscv_pkg::RS_FMUL: o_perf_events.head_wait_fmul = 1'b1;
          riscv_pkg::RS_FDIV: o_perf_events.head_wait_fdiv = 1'b1;
          default: ;
        endcase
      end
    end

    // commit_stall's IDLE arm is exported gate-free from rob_serializer (see
    // the TIMING note there); re-apply the dropped IDLE-only gate conjuncts
    // here so these counters keep their original values (non-IDLE stall
    // never carried the gate).
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
    // because the hazard gate (serial ops, head+1 mispredicting branches, FENCE.I,
    // exceptions, AMO/LR/SC, head-mispredicting-branches) is already
    // applied.  commit_2_fire_actual additionally folds in the master
    // enable and the cpu_ooo slot-2 accept term (i_widen_commit_ok,
    // currently tied high) — this is what the head_ptr increment and
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
        head_next_is_branch && !head_next_mispredicted && !head_next_ok_2wide;
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

  // One-hot head-image invariant (load-bearing for TIMING reads): the
  // registered masks must mirror the binary pointers every cycle, since
  // onehot_read() and the mwp_dist_ram_ohread LVT selects substitute them for
  // binary head_idx / head_next_idx indexing.  Only check once reset has been
  // observed asserted at least once: at sim time 0 the full-chip bench can
  // present i_rst_n=1 before the reset synchronizer fires, while the mask FFs
  // still hold their uninitialized all-zero value (which reads identically to
  // the pre-fix binary indexing of the equally-uninitialized state).
  logic dbg_mask_seen_reset;
  initial dbg_mask_seen_reset = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_mask_seen_reset <= 1'b1;
    if (i_rst_n && dbg_mask_seen_reset) begin
      if (head_clear_mask != (ReorderBufferDepth'(1) << head_idx)) begin
        $error("Reorder Buffer: head_clear_mask (0x%08x) != 1 << head_idx (%0d)", head_clear_mask,
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

  // Retire trace: log every committed instruction (for debugging).
  // Full 16-digit PCs/values: a %08x slice would silently truncate the
  // debug artifact bring-up leans on.
  integer retire_trace_fd;
  // NOTE: the format must be a $fwrite literal — Verilator does not
  // format through a localparam-string argument (it prints the format
  // text itself), which silently mangles this trace. Width-select via
  // branches instead.
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

  // Dispatch carries one decoded instruction class per allocation. SFENCE.VMA
  // and SRET/DRET are subtypes of is_fence_i and is_mret respectively, so the
  // subtype bits are intentionally outside this one-hot contract.
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

  // CDB staleness tripwires.  A CDB write whose tag the ROB no longer tracks
  // ("stale delivery") has two conceivable sources: a completion for a
  // FLUSHED tag escaping a producer's kill discipline, or a DUPLICATE
  // broadcast of a completion whose first delivery already committed the
  // instruction.  (A third class — duplicate-tag LQ/SQ pairs seeded by a
  // flush-cycle ghost allocation, which would complete the same tag twice —
  // is closed structurally: the queue alloc enables carry this module's
  // !i_flush_all && !i_flush_en gate, see load_queue/store_queue.)  The events observed in CoreMark-PRO and Linux-boot runs
  // (previously misattributed here to FDIV/FSQRT-latency flushed-tag
  // arrivals; the "cycles after last flush" distances pointed at unrelated
  // flushes) were forensically traced to the second kind: the MEM-slot
  // accept/present divergence duplicated a load completion one cycle after a
  // colliding misaligned-store issue — fixed at lq_result_accepted in
  // tomasulo_wrapper.sv.  Flushed-tag escapes have never been observed; the
  // producer kill discipline is pinned by the tomasulo_wrapper stale-CDB
  // probes and the fp_div_shim FORMAL flushed-tag assert.  Both diagnostics
  // below are expected to stay silent; the design still absorbs a stale
  // arrival defensively:
  //   - state-FF and exception-cause writes are rob_valid-gated; a normal
  //     completion never writes the cause, so it cannot erase an
  //     allocation-time legality fault;
  //   - a value-RAM write to a still-free entry is invisible (nothing reads
  //     invalid entries) and healed by the next allocation's LVT takeover;
  //   - in the entry's OWN reallocation cycle, old rob_valid suppresses the
  //     state/cause write while value alloc wins via staged-LVT resolution
  //     (see mwp_dist_ram).
  // The one arrival with NO defense is the cycle AFTER reallocation — the
  // staged-LVT drain cycle, where a live CDB write wins the LVT and would
  // poison the new instruction's value AND (rob_valid now set) its done
  // state.  No legitimate completion can exist that early (alloc ->
  // dispatch -> issue -> FU -> registered CDB always exceeds one cycle), so
  // that window is a fatal error below.  Stale arrivals >=2 cycles after
  // REALLOCATION (tag ABA) would be accepted as legitimate at this boundary;
  // ruling those out is the job of the producer-side kill discipline
  // (adapter age-kill, shim flush-marking, LQ cdb_stage kill, arbiter kill)
  // plus the MEM-slot single-delivery discipline (each completion pops the
  // cycle it is granted; see lq_result_accepted).  Both are pinned by the
  // directed stale-CDB/single-delivery tests in the tomasulo_wrapper bench,
  // the fp_div_shim FORMAL flushed-tag assert, and the wrapper's
  // fu_type-carrying stale-delivery diagnostics; any escape that does occur
  // remains loudly visible here (free-entry warnings + the fatal
  // drain-window tripwire).
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

  // Informational (rate-limited, non-sticky): stale deliveries to still-free
  // entries, with distance since the most recent flush.  Expected and
  // harmless per the analysis above; logged for producer-discipline
  // diagnostics.
  int unsigned dbg_cyc_since_flush;
  int unsigned dbg_stale_cdb_logged;
  always @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) dbg_cyc_since_flush <= 0;
    else dbg_cyc_since_flush <= dbg_cyc_since_flush + 1;
  end
  // Benign-delivery filter (mirrors the wrapper diagnostic): a write whose
  // tag committed within the last two cycles is the JALR wakeup broadcast
  // trailing its branch_update-driven commit — value stored at alloc, entry
  // not reallocatable that fast (tail wrap needs >=32 net allocations).
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

  // Serializer ownership contracts. A commit-time recovery flush cannot
  // overlap an already-owned head. Once a serializer-class head is ready,
  // its sole execution completion has either already been consumed (CSR) or
  // never exists (the remaining classes), so no CDB producer can rewrite it
  // on the entry edge or while the serializer owns it. These integration
  // invariants justify the serializer's head-independent retirement events.
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

  // The private CDB match-tag duplicates are registered copies of the shared
  // tags (driven by tomasulo_wrapper from the same arbiter output; checked by
  // the simulation assertion above). Model that invariant for the standalone
  // formal top so the solver cannot desynchronize the match compares.
  always_comb begin
    assume (i_cdb_match_tag == i_cdb_write.tag);
    assume (i_cdb_match_tag_2 == i_cdb_write_2.tag);
    if (head_ready &&
        (head_f_is_csr || head_f_is_fence || head_f_is_fence_i ||
         head_f_is_wfi || head_f_is_mret)) begin
      // A CSR's CDB completion is already stored before head_ready can rise;
      // the other serializer classes have no CDB producer. This also covers
      // the IDLE -> owned-state edge, before the state-only contract below
      // becomes active.
      assume (!(i_cdb_write.valid && (i_cdb_write.tag == head_idx)));
      assume (!(i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)));
    end
    if (serial_state != riscv_pkg::SERIAL_IDLE) begin
      // Serialized classes have either no CDB producer or have already
      // consumed their sole completion before state entry.
      assume (!(i_cdb_write.valid && (i_cdb_write.tag == head_idx)));
      assume (!(i_cdb_write_2.valid && (i_cdb_write_2.tag == head_idx)));
      // Commit-time branch recovery can only be pending after an IDLE branch
      // owner retired; it cannot overlap an older serialized head.
      assume (!i_flush_after_head_commit);
    end
  end

  // alloc_valid not asserted during flush (matches existing simulation assertion)
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
    assume (!(i_alloc_req.alloc_valid && full));
    assume (!(i_alloc_req_2.alloc_valid && !i_alloc_req.alloc_valid));
    assume (!(i_alloc_req_2.alloc_valid && full_for_2));
    assume (!(i_alloc_req_2.alloc_valid && (i_flush_en || i_flush_all)));
    // The controller's flush-after-head qualifier is a subtype of recovery:
    // it always arrives with the partial flush, unless a simultaneous
    // full-flush owner suppresses that lower-priority output.
    assume (!i_flush_after_head_commit || i_flush_en || i_flush_all);
    // These bits are mutually exclusive products of ID's single decoded op
    // (is_sfence is a subtype of is_fence_i and is intentionally omitted).
    // Encoding the dispatch contract prevents malformed multi-class entries
    // from selecting one serializer priority while retaining another class
    // bit in the commit payload.
    assume (!i_alloc_req.alloc_valid || $onehot0(
        {i_alloc_req.is_wfi, i_alloc_req.is_csr, i_alloc_req.is_fence,
                      i_alloc_req.is_fence_i, i_alloc_req.is_mret}
    ));
    assume (!i_alloc_req_2.alloc_valid || $onehot0(
        {i_alloc_req_2.is_wfi, i_alloc_req_2.is_csr, i_alloc_req_2.is_fence,
                      i_alloc_req_2.is_fence_i, i_alloc_req_2.is_mret}
    ));
  end

  // Reference form of the former serial add/compare implementation. The
  // interface assumptions above make raw alloc_valid exactly the accepted
  // width used by the production predecoded status cone.
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

  // CDB drain-window contract.  Stale CDB writes (a tag the ROB no longer
  // tracks) have reached this boundary in real runs — forensically traced to
  // MEM-slot DUPLICATE deliveries (the accept/present divergence fixed at
  // lq_result_accepted in tomasulo_wrapper.sv), historically misread as
  // FDIV/FSQRT-latency flushed-tag arrivals.  A stale write may even
  // coincide with the same entry's REALLOCATION cycle (that collision is
  // legal: the staged LVT of the rob_value RAMs resolves it alloc-wins, and
  // rob_valid gates the state-FF writes).  The single arrival the design
  // cannot absorb is a CDB write to an entry allocated in the PREVIOUS
  // cycle — the staged-LVT drain cycle, where a live write wins the LVT and
  // rob_valid no longer gates it.  No legitimate completion can exist that
  // early (alloc -> dispatch -> issue -> FU -> registered CDB always exceeds
  // one cycle), so it is assumed away here as the environment contract; the
  // sim tripwire in the debug section errors on any violation in every
  // simulation.  Stale writes >=2 cycles after reallocation (tag ABA) are
  // NOT excluded by this contract; they are ruled out by the producer-side
  // kill discipline and the MEM single-delivery discipline, pinned by the
  // tomasulo_wrapper stale-CDB/single-delivery tests and the fp_div_shim
  // FORMAL flushed-tag assert.
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
      // full and empty cannot both be true
      p_full_empty_mutex : assert (!(full && empty));

      // count == tail_ptr - head_ptr
      p_count_consistent : assert (count == (tail_ptr - head_ptr));

      // Parallel threshold selection must remain bit-identical to the original
      // conservative next-occupancy add/compare for every legal request/flush.
      p_dispatch_full_predecode_equiv :
      assert (dispatch_full_next ==
              (f_dispatch_count_next_reference ==
               ReorderBufferDepth[ReorderBufferTagWidth:0]));
      p_dispatch_full_for_2_predecode_equiv :
      assert (dispatch_full_for_2_next ==
              (f_dispatch_count_next_reference >=
               (ReorderBufferDepth[ReorderBufferTagWidth:0] - 1'b1)));

      // full iff pointers match with different MSB
      p_full_matches_ptrs :
      assert (full ==
        ((head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
         (head_idx == tail_idx)));

      // empty iff pointers exactly equal
      p_empty_matches_ptrs : assert (empty == (head_ptr == tail_ptr));

      // Registered one-hot head images track the binary pointers exactly.
      // The one-hot reads (onehot_read / mwp_dist_ram_ohread) rely on this.
      p_head_mask_onehot : assert (head_clear_mask == (ReorderBufferDepth'(1) << head_idx));
      p_head_next_mask_onehot :
      assert (head_next_clear_mask == (ReorderBufferDepth'(1) << head_next_idx));

      // The alloc-time final perf classes are equivalent to the original
      // head-meta priority classifier for every live entry.
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

      // The class assertions above prove correspondence with the original
      // priority classifier.  Keep the event properties local to the output
      // boundary: duplicating the full classifier in these two assertions is
      // logically redundant and makes btormc solve the same wide relation a
      // second time.  Together these properties prove the original event
      // equations transitively, including done/CDB-bypass/flush timing.
      p_perf_wait_int_event_equiv :
      assert (o_perf_events.head_wait_int == (head_wait_active && head_f_perf_wait_int));
      p_perf_wait_mem_load_event_equiv :
      assert (o_perf_events.head_wait_mem_load == (head_wait_active && head_f_perf_wait_mem_load));

      // alloc_en implies !full
      p_alloc_not_when_full : assert (!alloc_en || !full);

      // Allocation only targets free (not currently valid) entries.  Proven
      // from the ROB's own pointer/flush/commit bookkeeping (no environment
      // assumption involved).  Together with the drain-window CDB assume
      // above, this gives the staged-LVT of the rob_value RAMs everything it
      // needs: a same-cycle alloc-vs-CDB collision on one entry is LEGAL and
      // resolves alloc-wins inside the RAM (lvt_eff override + drain), and
      // the one dangerous arrival — a CDB write in the entry's drain cycle —
      // is excluded by the environment contract (mirrored by the sim
      // tripwire in the debug section).
      p_alloc_targets_free : assert (!alloc_en || !rob_valid[tail_idx]);
      p_alloc_2_targets_free : assert (!alloc_en_2 || !rob_valid[tail_idx_2]);

      // commit_en implies head_valid && head_done_eff (head_done_eff folds in the
      // same-cycle CDB bypass: when commit fires from a CDB write arriving this
      // cycle, the stored rob_done is still 0 until the next clock edge).
      p_commit_requires_valid_done : assert (!commit_en || (head_valid && head_done_eff));

      // commit output tag equals head_idx
      p_commit_only_at_head : assert (!commit_en || (o_commit_comb.tag == head_idx));

      // commit_stall implies !commit_en
      p_serial_stall_blocks_commit : assert (!commit_stall || !commit_en);

      // The serializer owns a pinned, completed head. TRAP_WAIT owns the one
      // exceptional class; every other owned state remains non-exceptional.
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

      // o_mret_start is asserted when MRET first reaches the ready head and is
      // sustained in MRET_EXEC so trap_unit can retry after committed SQ drain.
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

      // Both FENCE-class event flavors are exact retirement witnesses. The
      // native flavor is combinational from the owned sync state; the
      // translation flavor is registered once so csr_file receives the
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

      // o_fence_i_flush is the one-cycle registered image of the semantic
      // event, for both native and translation-CSR owners.
      p_fence_i_flush_delayed : assert (o_fence_i_flush == $past(o_fence_class_flush_event));

      if (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN && !i_sq_committed_empty) begin
        p_translation_drain_blocks_commit : assert (!commit_en);
      end
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

      // Alloc and a raw CDB RAM write in the same cycle is reachable — the
      // drain-window assume does not empty the overlap (same-cycle
      // collisions on one entry are legal and resolve alloc-wins in the
      // staged-LVT RAMs).
      cover_alloc_with_cdb_write : cover (alloc_en && cdb_ram_wr_en);
      cover_alloc_2_with_cdb_write_2 : cover (alloc_en_2 && cdb_ram_wr_en_2);

      // Buffer reaches full state
      cover_buffer_full : cover (full);

      // Partial flush occurs
      cover_partial_flush : cover (i_flush_en);

      // CSR serialization completes
      cover_csr_serialize : cover (serial_state == riscv_pkg::SERIAL_CSR_EXEC && i_csr_done);

      // The conservative translation-CSR classification remains reachable;
      // directed tests pin its retirement event and delayed flush phases.
      cover_translation_csr_drain : cover (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN);

      // WFI wakes on interrupt
      cover_wfi_wakeup : cover (serial_state == riscv_pkg::SERIAL_WFI_WAIT && i_interrupt_pending);

      // MRET completes
      cover_mret_complete : cover (serial_state == riscv_pkg::SERIAL_MRET_EXEC && i_mret_done);

      // FENCE.I cache sync completes
      cover_fence_i_sync_complete :
      cover (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC && i_fence_i_sync_done);

      // Exception triggers trap
      cover_exception_trap : cover (serial_state == riscv_pkg::SERIAL_TRAP_WAIT);

      // A FENCE-class owner reaches its semantic event. The delayed-pulse
      // assertion above proves that o_fence_i_flush follows on the next cycle;
      // covering the source avoids another expensive solver depth whose only
      // new state is that already-proven register image.
      cover_fence_class_flush_event : cover (o_fence_class_flush_event);
    end
  end

`endif  // FORMAL

endmodule : reorder_buffer
