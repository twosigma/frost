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
 * Privileged trap handling for M- and U-mode sources; all traps enter M-mode
 * through mtvec. Machine interrupts may preempt U-mode regardless of MIE.
 * Interrupt-take gating covers committed-store drain, irrevocable device reads,
 * and AMOs that own the ROB head; see the corresponding port comments.
 *
 * Interrupt/trap priority:
 *   1. External interrupt (MEIP && MEIE && MIE)
 *   2. Software interrupt (MSIP && MSIE && MIE)
 *   3. Timer interrupt   (MTIP && MTIE && MIE)
 *   4. Synchronous exceptions (ECALL, EBREAK, etc.)
 *
 * Entry saves mepc/mcause/mtval, moves MIE to MPIE, redirects to mtvec, and
 * flushes for two cycles. MRET restores MIE, sets MPIE, returns to mepc, and
 * also flushes for two cycles.
 *
 * mtvec modes:
 *   MODE=0 (Direct):   All traps → mtvec.BASE
 *   MODE=1 (Vectored): Interrupts → mtvec.BASE + 4*cause_code
 *                      Exceptions → mtvec.BASE
 *
 * WFI behavior:
 *   - Stall pipeline until any interrupt is pending
 *   - Resume at next instruction if interrupt not taken
 *   - Take trap if interrupt is both pending and enabled
 *   - Unused in cpu_ooo: i_wfi_start is tied low and o_stall_for_wfi
 *     is unconnected; WFI stalling is handled by ROB serialization at the head
 *
 * See csr_file, cpu_ooo, and ooo_pipeline_control for state and redirects.
 */
module trap_unit #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    // Pipeline control
    input logic i_pipeline_stall,

    // Full flushes must wait for committed stores to drain or the SQ would
    // discard architectural writes. o_trap_drain_wait also holds commit so a
    // continuing store stream cannot starve the trap.
    input  logic i_sq_committed_empty,
    output logic o_trap_drain_wait,

    // AMO interrupt shield (registered in cpu_ooo). An interrupt during the
    // [read-issue, commit] window could flush AMO_WRITE_ACTIVE after launch,
    // while amo_cached_inflight masks its completion from the SQ. Re-execution
    // then double-applies the AMO; a colliding handler store can also leave
    // write_inflight_cnt permanently nonzero. Deferral is bounded: AMOs issue
    // with an empty SQ and commit remains enabled, so the pending interrupt
    // follows commit. The registered image arrives before the earliest write
    // launch (at least three cycles after head); an earlier flush safely uses
    // drop_mem_response_pending. Exceptions remain enabled because an AMO
    // fault precedes memory effects.
    input logic i_amo_at_head,

    // Device-read interrupt shield (registered in cpu_ooo). An interrupt from
    // pre-accept through commit could re-execute an irrevocable FIFO-pop or
    // clear-on-read access. The router waits a full shielded cycle before
    // arming the read. Deferral is bounded: arming requires an empty SQ and
    // interrupt_take_armed_q is already latched, so neither
    // o_trap_drain_wait term holds commit. The pending interrupt follows load
    // commit. Misalignment exceptions remain enabled and perform no device
    // access.
    input logic i_device_read_at_head,

    // CSR values from csr_file
    input logic [XLEN-1:0] i_mstatus,
    input logic [XLEN-1:0] i_mie,
    input logic [XLEN-1:0] i_mtvec,
    input logic [XLEN-1:0] i_mepc,

    // Direct MIE bit input keeps mstatus bit extraction out of this path.
    input logic i_mstatus_mie_direct,

    // Current privilege mode. Machine interrupts are taken whenever running
    // below M (priv != PrivM) regardless of mstatus.MIE (RISC-V privileged spec).
    input logic [1:0] i_priv,

    // Interrupt pending inputs
    input riscv_pkg::interrupt_t i_interrupts,

    // Exception inputs from ROB commit/trap arbitration
    input logic i_exception_valid,
    input logic [XLEN-1:0] i_exception_cause,
    input logic [XLEN-1:0] i_exception_tval,
    input logic [XLEN-1:0] i_exception_pc,
    input logic [XLEN-1:0] i_interrupt_pc,

    // MRET trap-return request
    input logic i_mret_start,

    // WFI wait request
    input logic i_wfi_start,

    // Trap control outputs
    output logic            o_trap_taken,  // Trap is being taken this cycle
    output logic            o_mret_taken,  // MRET is being executed
    output logic [XLEN-1:0] o_trap_target, // Target PC (mtvec or mepc)

    // To CSR file for trap entry
    output logic [XLEN-1:0] o_trap_pc,     // PC to save to mepc
    output logic [XLEN-1:0] o_trap_cause,  // Cause to save to mcause
    output logic [XLEN-1:0] o_trap_value,  // Value to save to mtval

    // WFI stall output
    output logic o_stall_for_wfi  // Stall pipeline for WFI
);

  // Use direct mstatus_mie input instead of re-extracting from mstatus.
  logic mstatus_mie;
  assign mstatus_mie = i_mstatus_mie_direct;

  // Extract individual interrupt enable bits from mie
  logic mie_meie, mie_mtie, mie_msie;
  assign mie_meie = i_mie[riscv_pkg::MieMeiBit];
  assign mie_mtie = i_mie[riscv_pkg::MieMtiBit];
  assign mie_msie = i_mie[riscv_pkg::MieMsiBit];

  // Register trap_taken for one cycle to prevent it from re-asserting immediately
  // after CSR update (breaks combinational loop with mstatus_mie).  Also keep
  // a one-cycle MRET recovery marker: CSR privilege/MIE state changes on the
  // raw MRET pulse, while the OOO front/back-end flush is registered one cycle
  // later.  During that handoff, an old registered interrupt must not trap with
  // mepc equal to the MRET instruction itself.
  // TIMING: both one-cycle markers broadcast into the RS/LQ/SQ fabric and the
  // front end as recovery qualifiers (a top failing-cone family on the rv64 X3
  // route).  Cap the fanout so synthesis replicates the registers per consumer
  // region — replication only, the D inputs and reset are untouched.
  // keep + equivalent_register_removal: without them synthesis merges these
  // into the identical registered pulses in ooo_pipeline_control -- one
  // merged flop then serves every consumer and the max_fanout is lost with
  // the merge (netlist-verified: zero cells survived under these names).
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 32 *)
  logic trap_taken_prev;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 32 *)
  logic mret_taken_prev;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      trap_taken_prev <= 1'b0;
      mret_taken_prev <= 1'b0;
    end else begin
      trap_taken_prev <= o_trap_taken;
      mret_taken_prev <= o_mret_taken;
    end
  end

  // TIMING: inhibit off the REGISTERED image of i_mret_start. i_mret_start is
  // the ROB's o_mret_start (head_ready -> serializer cone, carrying the
  // same-cycle CDB head-done bypass); feeding it combinationally into
  // interrupt_pending_eligible put that whole cone in front of take_trap and
  // every trap-side CSR write. With the registered image, an interrupt that
  // is eligible in the FIRST i_mret_start cycle may now win take_trap; that
  // is architecturally clean: take_mret already yields to take_trap, the
  // interrupt's mepc is the MRET's own PC (i_interrupt_pc has not advanced
  // past the uncommitted MRET), the trap flush_all resets the serializer out
  // of SERIAL_MRET_EXEC, and the handler returns to re-execute the MRET.
  // From the second cycle on the inhibit behaves exactly as before.
  logic mret_start_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) mret_start_q <= 1'b0;
    else mret_start_q <= i_mret_start;
  end
  logic mret_interrupt_inhibit;
  assign mret_interrupt_inhibit = mret_start_q || mret_taken_prev;

  // Interrupt pending and enabled (gate by !trap_taken_prev to prevent re-entry).
  // Global M-interrupt enable: mstatus.MIE while in M, but ALWAYS enabled while
  // running below M (priv != PrivM) so a machine timer/SW/ext interrupt can
  // preempt U-mode even with MIE=0 (RISC-V privileged spec).
  logic m_int_globally_enabled;
  assign m_int_globally_enabled = mstatus_mie || (i_priv != riscv_pkg::PrivM);
  logic meip_enabled, mtip_enabled, msip_enabled;
  assign meip_enabled = i_interrupts.meip && mie_meie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign mtip_enabled = i_interrupts.mtip && mie_mtie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign msip_enabled = i_interrupts.msip && mie_msie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;

  // TIMING OPTIMIZATION: Register interrupt_pending to break critical path.
  // The combinational path from msip -> interrupt_pending -> take_trap -> stall -> cache
  // was the WNS path. Registering interrupt_pending adds 1-cycle latency to interrupt
  // detection, which is acceptable since interrupts are asynchronous events.
  // Note: mtip is already registered in cpu_and_mem.sv for similar timing reasons.
  logic interrupt_pending_comb;
  logic interrupt_pending;
  // Gate with !o_trap_taken so a still-pending interrupt is NOT re-latched on
  // the cycle its own trap is taken. interrupt_pending is registered, so
  // otherwise the latched value fires a second, spurious trap entry the next
  // cycle (re-saving mstatus.MPP=M and corrupting a U-mode trap). NOT a comb
  // loop: o_trap_taken derives from the REGISTERED interrupt_pending, so the
  // feedback path passes through a flop.
  assign interrupt_pending_comb = (meip_enabled || mtip_enabled || msip_enabled) && !o_trap_taken;

  // Source-level qualification: pending AND locally enabled (mie.x) and not in a
  // trap/MRET recovery window -- but NOT gated by the live global mstatus.MIE.
  //
  // Once interrupt_pending has been LATCHED (while fully eligible, MIE=1), a
  // YOUNGER csr clear of mstatus.MIE (e.g. the kernel idle `csrsi; ...; csrci`)
  // must not retroactively erase it: the interrupt was eligible at an instruction
  // boundary the csr-clear is younger than, so per the spec it is taken (the
  // csr-clear is squashed by the trap). interrupt_pending is registered (1-cycle
  // late) and interrupt_pending_eligible re-checks the LIVE global enable, so
  // without a hold a csr-clear's delayed mstatus.MIE side-effect lands in the
  // sample-to-service gap, drops interrupt_pending_comb, and clears the
  // already-qualified bit -> the interrupt is LOST. On the no-MMU kernel that
  // dropped machine-timer tick freezes jiffies and hangs the boot. (Usually the
  // service is delayed one cycle by a draining store via i_sq_committed_empty,
  // widening the window.) Hold across a global-MIE drop; still release when the
  // source itself de-qualifies (mtip/meip/msip drops or mie.x cleared) or the
  // trap is taken, so masking and acks behave normally.
  // interrupt_source_live: a REAL, current interrupt source exists -- pending AND
  // locally enabled (mie.x), gated ONLY by !trap_taken_prev. NOT gated by the live
  // global mstatus.MIE and NOT by mret_interrupt_inhibit, so a persistent timer is
  // HELD across both a global-MIE drop AND the MRET-recovery window rather than
  // erased. It is still never TAKEN there (interrupt_pending_eligible keeps
  // !mret_interrupt_inhibit + live m_int_globally_enabled), and the 0x80388bba
  // panic stays guarded by the cpu_ooo interrupt_resume_pc seed on mret_taken (not
  // by this latch) -- per commit 718f8cc the seed is THE panic fix and the old
  // trap_unit MRET/interrupt cancel was incidental bring-up timing. A stale sample
  // whose source has dropped (source_live=0) is still cleared, preserving the
  // "cancel a stale one-cycle sample before MRET" property.
  logic interrupt_source_live;
  assign interrupt_source_live =
      ((i_interrupts.meip && mie_meie) || (i_interrupts.mtip && mie_mtie) ||
       (i_interrupts.msip && mie_msie)) && !trap_taken_prev;

  always_ff @(posedge i_clk) begin
    if (i_rst) interrupt_pending <= 1'b0;
    else if (interrupt_pending_comb) interrupt_pending <= 1'b1;  // latch when fully eligible
    else if (interrupt_pending && interrupt_source_live && !o_trap_taken)
      interrupt_pending <= 1'b1;  // hold a live source across a global-MIE drop AND MRET inhibit
    else interrupt_pending <= 1'b0;  // clear stale (no live source) / on take
  end

  // Register synchronous exceptions from the ROB head before trap entry.
  // This adds one cycle to synchronous-exception handling, but removes the
  // ROB-head exception -> trap_taken -> front-end redirect cone from the
  // same cycle. Interrupts stay on their existing registered path.
  logic            exception_pending;
  logic [XLEN-1:0] exception_cause_q;
  logic [XLEN-1:0] exception_tval_q;
  logic [XLEN-1:0] exception_pc_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      exception_pending <= 1'b0;
    end else if (o_trap_taken) begin
      exception_pending <= 1'b0;
    end else if (trap_taken_prev) begin
      // Hold cleared one extra cycle: i_exception_valid (the ROB's trap_pending)
      // stays high until the trap is acked (~1 cycle after o_trap_taken), so
      // without this the exception re-arms and the trap is taken a second time
      // (now in M, corrupting mstatus.MPP / mcause for a U-mode trap).
      exception_pending <= 1'b0;
    end else if (i_exception_valid) begin
      exception_pending <= 1'b1;
      exception_cause_q <= i_exception_cause;
      exception_tval_q  <= i_exception_tval;
      exception_pc_q    <= i_exception_pc;
    end
  end

  // Vectored mode offset: 4 * cause_code (fits in 6 bits, enables small/fast adder)
  // MEI=11*4=44, MTI=7*4=28, MSI=3*4=12
  // TIMING OPTIMIZATION: Register vectored_offset to stay synchronized with interrupt_pending
  logic [5:0] vectored_offset_comb;
  logic [5:0] vectored_offset;
  always_comb begin
    if (meip_enabled) vectored_offset_comb = 6'd44;
    else if (msip_enabled) vectored_offset_comb = 6'd12;
    else if (mtip_enabled) vectored_offset_comb = 6'd28;
    else vectored_offset_comb = 6'd0;
  end

  always_ff @(posedge i_clk) begin
    vectored_offset <= vectored_offset_comb;
  end

  // WFI state machine
  logic wfi_active;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wfi_active <= 1'b0;
    end else if (i_wfi_start && !i_pipeline_stall) begin
      // Enter WFI wait state
      wfi_active <= 1'b1;
    end else if (interrupt_pending || i_interrupts.meip ||
                 i_interrupts.mtip || i_interrupts.msip) begin
      // Exit WFI when any interrupt is pending (even if not enabled)
      wfi_active <= 1'b0;
    end
  end

  // Stall pipeline during WFI
  // TIMING OPTIMIZATION: Register the WFI stall signal to break the critical path
  // from interrupt_pending through stall computation to cache writes. Adding 1-cycle
  // latency to WFI stall release is acceptable since we're already in a stall state.
  logic stall_for_wfi_comb;
  assign stall_for_wfi_comb = wfi_active && !interrupt_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst) o_stall_for_wfi <= 1'b0;
    else o_stall_for_wfi <= stall_for_wfi_comb;
  end

  // Determine trap cause with priority
  // TIMING OPTIMIZATION: Register interrupt_cause to stay synchronized with interrupt_pending
  logic [XLEN-1:0] interrupt_cause_comb;
  logic [XLEN-1:0] interrupt_cause;
  always_comb begin
    if (meip_enabled) interrupt_cause_comb = riscv_pkg::IntMachineExternal;
    else if (msip_enabled) interrupt_cause_comb = riscv_pkg::IntMachineSoftware;
    else if (mtip_enabled) interrupt_cause_comb = riscv_pkg::IntMachineTimer;
    else interrupt_cause_comb = '0;
  end

  always_ff @(posedge i_clk) begin
    // Hold the cause while interrupt_pending is held (across a global-MIE drop or
    // the MRET inhibit); interrupt_cause_comb is built from the gated *_enabled so
    // it decays to 0 there, which would default interrupt_latched_source_enabled
    // false and leave the held interrupt ineligible when it can finally trap.
    if (interrupt_cause_comb != '0) interrupt_cause <= interrupt_cause_comb;
    else if (interrupt_pending && interrupt_source_live) interrupt_cause <= interrupt_cause;
    else interrupt_cause <= '0;
  end

  // A registered interrupt request must still be enabled when it reaches the
  // trap decision. This keeps raw interrupt inputs out of the take_trap cone,
  // while allowing CSR writes such as Linux's ret_from_exception mstatus
  // restore to cancel a stale one-cycle interrupt sample before MRET.
  logic interrupt_latched_source_enabled;
  always_comb begin
    unique case (interrupt_cause)
      riscv_pkg::IntMachineExternal: interrupt_latched_source_enabled = mie_meie;
      riscv_pkg::IntMachineSoftware: interrupt_latched_source_enabled = mie_msie;
      riscv_pkg::IntMachineTimer:    interrupt_latched_source_enabled = mie_mtie;
      default:                       interrupt_latched_source_enabled = 1'b0;
    endcase
  end

  logic interrupt_pending_eligible;
  assign interrupt_pending_eligible = interrupt_pending &&
      interrupt_latched_source_enabled &&
      m_int_globally_enabled &&
      !trap_taken_prev &&
      !mret_interrupt_inhibit;

  // Interrupt arming: an interrupt may only take a trap the cycle AFTER it
  // first became eligible. The arming cycle raises o_trap_drain_wait (below),
  // which lands in the registered commit hold — so on the take cycle no new
  // ROB commit can fire, and any store-like commit from the arming cycle has
  // already pessimistically cleared the SQ's registered committed-empty
  // status. This removes the need for the same-cycle raw commit guards
  // (formerly sq_committed_empty_for_trap in cpu_ooo) on the take_trap cone,
  // at the cost of one extra cycle of interrupt entry latency.
  // Exceptions need no arming: an exception at the ROB head already blocks
  // every commit (commit_ready_early), so no store commit can race the take.
  logic interrupt_take_armed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) interrupt_take_armed_q <= 1'b0;
    else interrupt_take_armed_q <= interrupt_pending_eligible && !o_trap_taken;
  end

  // Trap taken: either interrupt or exception, the pipeline not stalled
  // (except for WFI stall, which should be broken by interrupt), and no
  // committed store still draining (see i_sq_committed_empty).
  logic take_trap;
  assign take_trap = ((interrupt_pending_eligible && interrupt_take_armed_q &&
                       !i_amo_at_head && !i_device_read_at_head) ||
                      exception_pending) &&
      !i_pipeline_stall &&
      i_sq_committed_empty;

  // MRET execution.  Synchronous exceptions are structurally impossible with
  // MRET at the ROB head; pending interrupts are deferred across the MRET
  // recovery window above so the return redirect stays precise.
  logic take_mret;
  assign take_mret = i_mret_start && !i_pipeline_stall && !take_trap && i_sq_committed_empty;

  // Hold commit while a trap/MRET waits out the store drain, so the
  // committed set shrinks monotonically and the wait is bounded. The
  // interrupt arming window also holds commit (see interrupt_take_armed_q):
  // by the take cycle the hold is registered-active, so no commit can race
  // the full flush. The raw sample (interrupt_pending_comb) is included
  // because the ROB observes the interrupt one cycle before the registered
  // eligibility (e.g. releasing a WFI's commit_stall) — without it the
  // instruction after a WFI could retire in the arming gap and advance the
  // interrupt resume PC past the architectural boundary (mepc = wfi_pc+8
  // instead of wfi_pc+4 in the wfi_mepc regression).
  assign o_trap_drain_wait = ((interrupt_pending_eligible || exception_pending || i_mret_start) &&
      !i_sq_committed_empty) ||
      ((interrupt_pending_comb || interrupt_pending_eligible) && !interrupt_take_armed_q);

  // Output trap signals
  assign o_trap_taken = take_trap;
  assign o_mret_taken = take_mret;

  // Trap target: mtvec for trap entry, mepc for MRET
  // mtvec MODE (bits [1:0]): 0 = Direct (all traps go to BASE)
  //                          1 = Vectored (interrupts go to BASE + 4*cause)
  logic [XLEN-1:0] trap_target_selected;
  always_comb begin
    if (take_mret) begin
      trap_target_selected = i_mepc;
    end else if (take_trap) begin
      // Check mtvec mode
      if (i_mtvec[1:0] == 2'b01 && interrupt_pending_eligible) begin
        // Vectored mode for interrupts: BASE + 4*cause_code
        // Use pre-computed small offset (6 bits) for faster timing than
        // extracting from full interrupt_cause which synthesis can't optimize
        trap_target_selected = {i_mtvec[XLEN-1:2], 2'b00} + {{(XLEN - 6) {1'b0}}, vectored_offset};
      end else begin
        // Direct mode: all traps go to BASE (aligned to 4 bytes)
        trap_target_selected = {i_mtvec[XLEN-1:2], 2'b00};
      end
    end else begin
      trap_target_selected = '0;
    end

    // Canonicalize the redirect to the physical address space.
    // mepc/mtvec themselves keep full-width storage in csr_file
    // (WARL round-trip fidelity); only the fetch redirect derived from them
    // is masked - plan decision D3.
    o_trap_target = riscv_pkg::canonical_paddr(trap_target_selected);
  end

  // Trap entry information for CSR file
  // Interrupts have priority over synchronous exceptions
  always_comb begin
    if (interrupt_pending_eligible) begin
      o_trap_cause = interrupt_cause;
      o_trap_value = '0;  // Interrupts have mtval = 0
      // For interrupts, save the precise architectural resume PC.  The live
      // ROB head PC can be transient or stale while an async interrupt drains
      // through the registered commit path.
      o_trap_pc = i_interrupt_pc;
    end else begin
      o_trap_cause = exception_cause_q;
      o_trap_value = exception_tval_q;
      o_trap_pc = exception_pc_q;
    end
  end

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL

  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Structural constraints: these combos can't happen in real pipeline.
  // In the real pipeline, only one instruction type can be in EX at a time.
  always_comb begin
    assume (!(i_mret_start && i_exception_valid));
    assume (!(i_wfi_start && i_mret_start));
    assume (!(i_wfi_start && i_exception_valid));
    // Note: MRET + interrupt_pending is NOT assumed away. An interrupt that is
    // already ARMED (eligible since the previous cycle) may preempt the MRET
    // in its FIRST i_mret_start cycle (take_mret yields to take_trap and the
    // MRET re-executes after the handler); from the second cycle on the
    // registered inhibit (mret_start_q) defers the interrupt until after the
    // return redirect has retired the MRET precisely.
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // Trap/MRET mutex: cannot both fire simultaneously.
      p_trap_mret_mutex : assert (!(o_trap_taken && o_mret_taken));

      // Trap needs source: trap_taken requires interrupt or exception.
      p_trap_needs_source :
      assert (!o_trap_taken || (interrupt_pending_eligible || exception_pending));

      // Trap not during stall: traps only fire when pipeline not stalled.
      p_trap_not_stalled : assert (!o_trap_taken || !i_pipeline_stall);

      // MRET not during stall.
      p_mret_not_stalled : assert (!o_mret_taken || !i_pipeline_stall);

      // Neither traps nor MRET may fire while committed stores drain.
      p_trap_waits_drain : assert (!o_trap_taken || i_sq_committed_empty);

      // Interrupt shields. A shielded head keeps the INTERRUPT arm of the trap
      // out of the take decision; an exception at the head still takes, which
      // is what makes both shields bounded rather than blocking.
      p_device_shield_blocks_interrupt :
      assert (!(o_trap_taken && i_device_read_at_head) || exception_pending);
      p_amo_shield_blocks_interrupt :
      assert (!(o_trap_taken && i_amo_at_head) || exception_pending);
      p_mret_waits_drain : assert (!o_mret_taken || i_sq_committed_empty);

      // MRET target is mepc through the D3 consumer-side canonicalization:
      // mepc is stored full-width (csr_file), and every fetch redirect is
      // canonicalized at this single consumer (o_trap_target above), so the
      // target equals canonical_paddr(mepc) — bits [63:32] masked, so a
      // bit-exact mepc compare would not hold.
      p_mret_target :
      assert (!o_mret_taken || (o_trap_target == riscv_pkg::canonical_paddr(i_mepc)));

      // A pending interrupt must not preempt an MRET that has been in flight
      // for a full cycle (the registered inhibit window). The FIRST
      // i_mret_start cycle is exempt: an already-armed interrupt may win
      // there — take_mret yields to take_trap and the MRET re-executes after
      // the handler (see mret_interrupt_inhibit).
      if (mret_start_q && i_mret_start && !exception_pending) begin
        p_mret_defers_interrupt : assert (!o_trap_taken);
      end

      // WFI stall contract: if stall_for_wfi_comb, wfi must be active.
      p_wfi_stall_needs_active : assert (!stall_for_wfi_comb || wfi_active);
    end

    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // Interrupt priority: external > software > timer.
      // If external interrupt was enabled, cause must be external.
      if ($past(meip_enabled)) begin
        p_meip_priority : assert (interrupt_cause == riscv_pkg::IntMachineExternal);
      end

      // Software interrupt: if external not enabled but software is.
      if ($past(!meip_enabled && msip_enabled)) begin
        p_msip_priority : assert (interrupt_cause == riscv_pkg::IntMachineSoftware);
      end

      // Timer interrupt: if neither external nor software enabled but timer is.
      if ($past(!meip_enabled && !msip_enabled && mtip_enabled)) begin
        p_mtip_priority : assert (interrupt_cause == riscv_pkg::IntMachineTimer);
      end

      // Vectored offset correctness for external interrupt.
      if ($past(meip_enabled)) begin
        p_vectored_meip : assert (vectored_offset == 6'd44);
      end

      // Vectored offset correctness for software interrupt.
      if ($past(!meip_enabled && msip_enabled)) begin
        p_vectored_msip : assert (vectored_offset == 6'd12);
      end

      // Vectored offset correctness for timer interrupt.
      if ($past(!meip_enabled && !msip_enabled && mtip_enabled)) begin
        p_vectored_mtip : assert (vectored_offset == 6'd28);
      end

      // Re-entry prevention: after trap_taken, interrupt enables are blocked
      // for one cycle via trap_taken_prev.
      if (trap_taken_prev) begin
        p_reentry_prevention : assert (!meip_enabled && !mtip_enabled && !msip_enabled);
      end

      // Reset clears all state.
      if ($past(i_rst)) begin
        p_reset_trap_prev : assert (!trap_taken_prev);
        p_reset_wfi : assert (!wfi_active);
        p_reset_int_pending : assert (!interrupt_pending);
      end
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_trap_taken : cover (o_trap_taken);
      cover_mret_taken : cover (o_mret_taken);
      cover_wfi_stall : cover (stall_for_wfi_comb);
      cover_wfi_wakeup : cover (f_past_valid && !wfi_active && $past(wfi_active));
      cover_external_interrupt :
      cover (interrupt_pending_eligible && interrupt_cause == riscv_pkg::IntMachineExternal);
      cover_exception : cover (o_trap_taken && i_exception_valid && !interrupt_pending_eligible);
      cover_trap_after_drain : cover (f_past_valid && o_trap_taken && $past(o_trap_drain_wait));
      // The device shield defers a ready interrupt, then it takes as soon as
      // the shield drops -- the liveness shape the bounded argument relies on.
      cover_device_shield_defers_interrupt :
      cover (i_device_read_at_head && interrupt_pending_eligible && interrupt_take_armed_q &&
             i_sq_committed_empty && !o_trap_taken);
      cover_device_shield_release_takes_interrupt :
      cover (f_past_valid && o_trap_taken && $past(
          i_device_read_at_head && interrupt_pending_eligible
      ) && !i_device_read_at_head);
      // While the device shield defers, commit must NOT be held (that is the
      // forward-progress half of the bounded argument).
      cover_device_shield_defers_without_commit_hold :
      cover (i_device_read_at_head && interrupt_pending_eligible && !o_trap_drain_wait);
    end
  end

`endif  // FORMAL

endmodule : trap_unit
