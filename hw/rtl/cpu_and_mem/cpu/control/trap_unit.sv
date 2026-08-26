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
 * Privileged trap handling for M/S/U-mode sources with delegation (Phase 3,
 * plan D2). Traps enter M through mtvec, or S through stvec when delegated
 * (medeleg[cause] for exceptions from priv < M; mideleg[i] retargets the
 * supervisor interrupt classes to S). Interrupt-take gating covers
 * committed-store drain, irrevocable device reads, and AMOs that own the ROB
 * head; see the corresponding port comments.
 *
 * Interrupt eligibility is evaluated PER TARGET CLASS, never as one global
 * chain over raw pending bits (the spec's ordering rule: anything destined
 * for M is taken before anything destined for S, and cause priority applies
 * within a target):
 *   M-target (mideleg[i]=0, including all machine classes):
 *     pending && mie[i] && (priv < M || mstatus.MIE)
 *   S-target (mideleg[i]=1, supervisor classes only):
 *     pending && mie[i] && (priv == U || (priv == S && sstatus.SIE));
 *     never taken while in M.
 * Within a class the cause priority is MEI > MSI > MTI (machine) and
 * SEI > SSI > STI (supervisor); across classes an armed M-target take always
 * precedes an armed S-target take.
 *
 * Entry saves xepc/xcause/xtval on the TARGET side, moves xIE to xPIE, and
 * redirects to xtvec (o_trap_to_s tells csr_file which side). MRET/SRET
 * restore their side and redirect to mepc/sepc; SRET follows the exact MRET
 * inhibit/drain protocol.
 *
 * xtvec modes (both sides):
 *   MODE=0 (Direct):   All traps → BASE
 *   MODE=1 (Vectored): Interrupts → BASE + 4*cause_code
 *                      Exceptions → BASE
 *
 * Debug Mode (RISC-V Debug Spec 0.13.2, Phase 3 M3) is a THIRD take class,
 * D, with the same latch/arm/shield/drain shape as M and S:
 *   halt sources (dmcontrol.haltreq, the single-step completion request)
 *     are eligible only outside Debug Mode and take precedence over both
 *     interrupt classes; entry (o_trap_to_d) saves dpc/dcsr in csr_file and
 *     redirects to the debug module's park word;
 *   ebreak with dcsr.ebreak{m,s,u} set for the current privilege routes the
 *     cause-3 exception to D (dpc = the ebreak's PC, nothing else saved);
 *   in Debug Mode every exception re-parks the hart with NO CSR side effect
 *     (o_trap_no_csr): the terminating ebreak of a debug command, or a
 *     command exception (o_dbg_park_exception) — and the M/S interrupt
 *     classes are masked (also while a single step is armed: stepie=0);
 *   go (i_dbg_go, Debug Mode only) is the debug module's CSR-free redirect
 *     into its abstract-command / resume words;
 *   DRET follows the exact MRET protocol (inhibit, drain) and redirects to
 *     dpc; csr_file restores dcsr.prv on o_dret_taken.
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
    input logic [XLEN-1:0] i_stvec,
    input logic [XLEN-1:0] i_sepc,

    // Direct MIE/SIE bit inputs keep mstatus bit extraction out of this path.
    input logic i_mstatus_mie_direct,
    input logic i_sstatus_sie_direct,

    // Delegation state. i_mideleg_s packs {SEI, STI, SSI}; i_medeleg indexes
    // by the synchronous cause code (bits 15:0).
    input logic [ 2:0] i_mideleg_s,
    input logic [15:0] i_medeleg,

    // Current privilege mode. An interrupt targeting mode x is taken whenever
    // running below x regardless of x's global enable, and never when running
    // above x (RISC-V privileged spec).
    input logic [1:0] i_priv,

    // Interrupt pending inputs: machine classes from the platform, supervisor
    // classes from csr_file's effective sip bits {SEIP, STIP, SSIP}.
    input riscv_pkg::interrupt_t i_interrupts,
    input logic [2:0] i_s_pending,

    // Exception inputs from ROB commit/trap arbitration
    input logic i_exception_valid,
    input logic [XLEN-1:0] i_exception_cause,
    input logic [XLEN-1:0] i_exception_tval,
    input logic [XLEN-1:0] i_exception_pc,
    input logic [XLEN-1:0] i_interrupt_pc,

    // xRET trap-return requests (mutually exclusive; SRET follows the exact
    // MRET protocol including the registered inhibit window)
    input logic i_mret_start,
    input logic i_sret_start,

    // WFI wait request
    input logic i_wfi_start,

    // Debug Mode (Phase 3 M3). All are registered core-side state or levels
    // held until acknowledged by the take they request.
    input logic            i_debug_mode,
    input logic            i_dbg_haltreq,     // dmcontrol.haltreq (level)
    input logic            i_dbg_step_req,    // step done: halt at the next head (level)
    input logic            i_dbg_step_armed,  // a single step is running: mask M/S
    input logic            i_dbg_go,          // DM redirect request (level, Debug Mode)
    input logic [XLEN-1:0] i_dbg_go_target,
    input logic [     2:0] i_dcsr_ebreak,     // {ebreakm, ebreaks, ebreaku}
    input logic [XLEN-1:0] i_dpc,
    input logic            i_dret_start,

    // Trap control outputs
    output logic            o_trap_taken,  // Trap is being taken this cycle
    output logic            o_trap_to_s,   // ...targeting S (delegated); else M
    output logic            o_mret_taken,  // MRET is being executed
    output logic            o_sret_taken,  // SRET is being executed
    output logic [XLEN-1:0] o_trap_target, // Target PC (mtvec/stvec or mepc/sepc)

    // To CSR file for trap entry (written to the o_trap_to_s side)
    output logic [XLEN-1:0] o_trap_pc,     // PC to save to mepc/sepc
    output logic [XLEN-1:0] o_trap_cause,  // Cause to save to mcause/scause
    output logic [XLEN-1:0] o_trap_value,  // Value to save to mtval/stval

    // Debug Mode take qualifiers (Phase 3 M3), valid with o_trap_taken:
    //   o_trap_to_d:   Debug Mode entry (csr_file saves dpc/dcsr, priv <- M)
    //   o_trap_no_csr: a Debug Mode redirect with no CSR side effect (go, or
    //                  an exception re-parking the hart) — cpu_ooo withholds
    //                  csr_file's i_trap_taken for these
    //   o_dbg_cause:   dcsr.cause for an entry (1 ebreak, 3 haltreq, 4 step)
    output logic       o_trap_to_d,
    output logic       o_trap_no_csr,
    output logic [2:0] o_dbg_cause,
    output logic       o_dret_taken,         // DRET is being executed
    output logic       o_dbg_go_taken,       // the go redirect fired
    output logic       o_dbg_park_entry,     // a Debug Mode exception re-parked
    output logic       o_dbg_park_exception, // ...and it was not the ebreak

    // WFI stall output
    output logic o_stall_for_wfi  // Stall pipeline for WFI
);

  // Use direct mstatus_mie/sstatus_sie inputs instead of re-extracting.
  logic mstatus_mie;
  assign mstatus_mie = i_mstatus_mie_direct;
  logic sstatus_sie;
  assign sstatus_sie = i_sstatus_sie_direct;

  // Extract individual interrupt enable bits from mie (the supervisor
  // enables live in the same storage; sie is only a view).
  logic mie_meie, mie_mtie, mie_msie;
  logic mie_seie, mie_stie, mie_ssie;
  assign mie_meie = i_mie[riscv_pkg::MieMeiBit];
  assign mie_mtie = i_mie[riscv_pkg::MieMtiBit];
  assign mie_msie = i_mie[riscv_pkg::MieMsiBit];
  assign mie_seie = i_mie[riscv_pkg::MieSeiBit];
  assign mie_stie = i_mie[riscv_pkg::MieStiBit];
  assign mie_ssie = i_mie[riscv_pkg::MieSsiBit];

  // Supervisor pending bits and delegation selects.
  logic seip, stip, ssip;
  assign {seip, stip, ssip} = i_s_pending;
  logic deleg_sei, deleg_sti, deleg_ssi;
  assign {deleg_sei, deleg_sti, deleg_ssi} = i_mideleg_s;

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
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 32 *)
  logic sret_taken_prev;
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 32 *)
  logic dret_taken_prev;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      trap_taken_prev <= 1'b0;
      mret_taken_prev <= 1'b0;
      sret_taken_prev <= 1'b0;
      dret_taken_prev <= 1'b0;
    end else begin
      trap_taken_prev <= o_trap_taken;
      mret_taken_prev <= o_mret_taken;
      sret_taken_prev <= o_sret_taken;
      dret_taken_prev <= o_dret_taken;
    end
  end

  // TIMING: inhibit off the REGISTERED image of i_mret_start/i_sret_start.
  // i_mret_start is the ROB's o_mret_start (head_ready -> serializer cone,
  // carrying the same-cycle CDB head-done bypass); feeding it combinationally
  // into interrupt_pending_eligible put that whole cone in front of take_trap
  // and every trap-side CSR write. With the registered image, an interrupt
  // that is eligible in the FIRST xret-start cycle may now win take_trap;
  // that is architecturally clean: take_xret already yields to take_trap, the
  // interrupt's xepc is the xRET's own PC (i_interrupt_pc has not advanced
  // past the uncommitted xRET), the trap flush_all resets the serializer out
  // of SERIAL_MRET_EXEC, and the handler returns to re-execute the xRET.
  // From the second cycle on the inhibit behaves exactly as before. SRET
  // shares the window: both xRETs redirect through the same recovery
  // machinery, so a single combined inhibit is exact.
  logic mret_start_q;
  logic sret_start_q;
  logic dret_start_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mret_start_q <= 1'b0;
      sret_start_q <= 1'b0;
      dret_start_q <= 1'b0;
    end else begin
      mret_start_q <= i_mret_start;
      sret_start_q <= i_sret_start;
      dret_start_q <= i_dret_start;
    end
  end
  // DRET (M3) shares the window: it redirects through the same recovery
  // machinery as the other xRETs.
  logic mret_interrupt_inhibit;
  assign mret_interrupt_inhibit = mret_start_q || mret_taken_prev ||
      sret_start_q || sret_taken_prev || dret_start_q || dret_taken_prev;

  // Per-target-class interrupt qualification (gate by !trap_taken_prev to
  // prevent re-entry). Never one global chain over raw pending bits: the
  // spec's rule is per-target eligibility, M-target before S-target.
  //
  // M-target global enable: mstatus.MIE while in M, ALWAYS enabled below M.
  // Debug Mode (M3): interrupts are never taken in Debug Mode, nor while a
  // single step is armed (dcsr.stepie is hardwired 0). The masks sit in the
  // global enables so the latch/hold logic treats them like a disabled xIE.
  logic debug_int_mask;
  assign debug_int_mask = i_debug_mode || i_dbg_step_armed;
  logic m_int_globally_enabled;
  assign m_int_globally_enabled = (mstatus_mie || (i_priv != riscv_pkg::PrivM)) && !debug_int_mask;
  // S-target global enable: sstatus.SIE while in S, ALWAYS enabled in U,
  // NEVER in M (an S-target interrupt cannot preempt M-mode).
  logic s_int_globally_enabled;
  assign s_int_globally_enabled = ((i_priv == riscv_pkg::PrivU) ||
      ((i_priv == riscv_pkg::PrivS) && sstatus_sie)) && !debug_int_mask;

  // Machine-class sources are M-target always (mideleg's machine bits are
  // read-only zero). Supervisor-class sources target S when delegated, M
  // otherwise.
  logic meip_enabled, mtip_enabled, msip_enabled;
  logic seip_m_enabled, stip_m_enabled, ssip_m_enabled;
  logic seip_s_enabled, stip_s_enabled, ssip_s_enabled;
  assign meip_enabled = i_interrupts.meip && mie_meie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign mtip_enabled = i_interrupts.mtip && mie_mtie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign msip_enabled = i_interrupts.msip && mie_msie && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign seip_m_enabled = seip && mie_seie && !deleg_sei && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign stip_m_enabled = stip && mie_stie && !deleg_sti && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign ssip_m_enabled = ssip && mie_ssie && !deleg_ssi && m_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign seip_s_enabled = seip && mie_seie && deleg_sei && s_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign stip_s_enabled = stip && mie_stie && deleg_sti && s_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  assign ssip_s_enabled = ssip && mie_ssie && deleg_ssi && s_int_globally_enabled &&
      !trap_taken_prev && !mret_interrupt_inhibit;

  // TIMING OPTIMIZATION: Register the per-class interrupt_pending latches to
  // break the critical path. The combinational path from msip ->
  // interrupt_pending -> take_trap -> stall -> cache was the WNS path.
  // Registering adds 1-cycle latency to interrupt detection, which is
  // acceptable since interrupts are asynchronous events.
  // Note: mtip/meip are already registered in cpu_and_mem.sv for the same
  // reason; the supervisor pending bits are registered CSR state.
  logic m_int_pending_comb, s_int_pending_comb;
  logic m_int_pending, s_int_pending;
  // Gate with !take_trap_m/!take_trap_s so a still-pending interrupt is NOT
  // re-latched on the cycle its own class's trap is taken (a latched value
  // would otherwise fire a second, spurious entry the next cycle). NOT a
  // comb loop: the takes derive from the REGISTERED latches, so the feedback
  // passes through a flop. A class that loses the take mux to the other
  // class is NOT retained through the entry (trap_taken_prev drops its
  // source-live for one cycle, clearing the latch); delivery relies on the
  // source being LEVEL (every FROST supervisor source is: the mip software
  // bits, and later the PLIC/Sstc lines) so it re-latches as soon as its
  // class is eligible again — inside the winning handler where permitted,
  // or after its xRET.
  logic take_trap_m, take_trap_s;
  assign m_int_pending_comb =
      (meip_enabled || mtip_enabled || msip_enabled ||
       seip_m_enabled || ssip_m_enabled || stip_m_enabled) && !take_trap_m;
  assign s_int_pending_comb = (seip_s_enabled || ssip_s_enabled || stip_s_enabled) && !take_trap_s;

  // Source-level qualification: pending AND locally enabled (mie.x) AND
  // targeting this class, not in a trap/xRET recovery window -- but NOT
  // gated by the live per-class global enable.
  //
  // Once a class latch has been set (while fully eligible), a YOUNGER csr
  // clear of that class's global enable (M: the kernel idle
  // `csrsi mstatus,MIE; ...; csrci`; S: the identical sstatus.SIE shape)
  // must not retroactively erase it: the interrupt was eligible at an
  // instruction boundary the csr-clear is younger than, so per the spec it
  // is taken (the csr-clear is squashed by the trap). The latch is
  // registered (1-cycle late) and the eligible term re-checks the LIVE
  // global enable, so without a hold the csr-clear's delayed side effect
  // lands in the sample-to-service gap and the interrupt is LOST (the
  // no-MMU boot hang of the M-class original). Hold across a global-enable
  // drop; still release when the source itself de-qualifies (pending drops,
  // mie.x cleared, or DELEGATION RETARGETS the source to the other class —
  // the mideleg term keeps a retargeted source from being taken with the
  // old class's CSRs) or when this class's trap is taken.
  logic m_int_source_live, s_int_source_live;
  assign m_int_source_live =
      ((i_interrupts.meip && mie_meie) || (i_interrupts.mtip && mie_mtie) ||
       (i_interrupts.msip && mie_msie) ||
       (seip && mie_seie && !deleg_sei) || (stip && mie_stie && !deleg_sti) ||
       (ssip && mie_ssie && !deleg_ssi)) && !trap_taken_prev;
  assign s_int_source_live =
      ((seip && mie_seie && deleg_sei) || (stip && mie_stie && deleg_sti) ||
       (ssip && mie_ssie && deleg_ssi)) && !trap_taken_prev;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      m_int_pending <= 1'b0;
      s_int_pending <= 1'b0;
    end else begin
      if (m_int_pending_comb) m_int_pending <= 1'b1;  // latch when fully eligible
      else if (m_int_pending && m_int_source_live && !take_trap_m)
        m_int_pending <= 1'b1;  // hold a live source across a global-enable drop AND xRET inhibit
      else m_int_pending <= 1'b0;  // clear stale (no live source) / on take
      if (s_int_pending_comb) s_int_pending <= 1'b1;
      else if (s_int_pending && s_int_source_live && !take_trap_s) s_int_pending <= 1'b1;
      else s_int_pending <= 1'b0;
    end
  end

  // Debug Mode take class D (M3). The halt sources (haltreq, step-done) are
  // live only outside Debug Mode; go is live only in Debug Mode — the two
  // never overlap. Every source is a LEVEL held by its owner until the take
  // it requests lands (the debug module drops go on o_dbg_go_taken, the
  // step request clears on entry, haltreq is the debugger's), so the latch
  // needs no hold-across-disable term: it re-latches while the source is
  // live and clears on its own take.
  logic take_trap_d;
  logic d_halt_source_live, d_go_source_live, d_source_live;
  assign d_halt_source_live = (i_dbg_haltreq || i_dbg_step_req) && !i_debug_mode;
  assign d_go_source_live = i_dbg_go && i_debug_mode;
  assign d_source_live = (d_halt_source_live || d_go_source_live) &&
      !trap_taken_prev && !mret_interrupt_inhibit;
  logic d_int_pending_comb, d_int_pending;
  assign d_int_pending_comb = d_source_live && !take_trap_d;
  always_ff @(posedge i_clk) begin
    if (i_rst) d_int_pending <= 1'b0;
    else d_int_pending <= d_int_pending_comb;
  end
  logic d_int_eligible;
  assign d_int_eligible = d_int_pending && d_source_live;
  logic d_take_armed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) d_take_armed_q <= 1'b0;
    else d_take_armed_q <= d_int_eligible && !o_trap_taken;
  end
  logic d_int_take_ready;
  assign d_int_take_ready = d_int_eligible && d_take_armed_q &&
      !i_amo_at_head && !i_device_read_at_head;
  // dcsr.ebreak{m,s,u} for the CURRENT privilege: an ebreak here enters
  // Debug Mode instead of trapping.
  logic dcsr_ebreak_here;
  assign dcsr_ebreak_here = (i_priv == riscv_pkg::PrivM) ? i_dcsr_ebreak[2] :
                            (i_priv == riscv_pkg::PrivS) ? i_dcsr_ebreak[1] : i_dcsr_ebreak[0];

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

  // Vectored mode offset: 4 * cause_code (fits in 6 bits, enables small/fast
  // adders). M side: MEI=44, MSI=12, MTI=28, plus the undelegated supervisor
  // classes SEI=36, SSI=4, STI=20. S side: SEI=36, SSI=4, STI=20.
  // TIMING OPTIMIZATION: registered to stay synchronized with the pending
  // latches.
  logic [5:0] m_vectored_offset_comb, s_vectored_offset_comb;
  logic [5:0] m_vectored_offset, s_vectored_offset;
  always_comb begin
    if (meip_enabled) m_vectored_offset_comb = 6'd44;
    else if (msip_enabled) m_vectored_offset_comb = 6'd12;
    else if (mtip_enabled) m_vectored_offset_comb = 6'd28;
    else if (seip_m_enabled) m_vectored_offset_comb = 6'd36;
    else if (ssip_m_enabled) m_vectored_offset_comb = 6'd4;
    else if (stip_m_enabled) m_vectored_offset_comb = 6'd20;
    else m_vectored_offset_comb = 6'd0;
    if (seip_s_enabled) s_vectored_offset_comb = 6'd36;
    else if (ssip_s_enabled) s_vectored_offset_comb = 6'd4;
    else if (stip_s_enabled) s_vectored_offset_comb = 6'd20;
    else s_vectored_offset_comb = 6'd0;
  end

  always_ff @(posedge i_clk) begin
    m_vectored_offset <= m_vectored_offset_comb;
    s_vectored_offset <= s_vectored_offset_comb;
  end

  // WFI state machine
  logic wfi_active;
  logic any_int_pending_raw;
  // WFI wakes on ANY pending interrupt source, even if not enabled (per the
  // spec); the supervisor software-pending bits count like the platform bits.
  assign any_int_pending_raw = i_interrupts.meip || i_interrupts.mtip ||
      i_interrupts.msip || seip || stip || ssip;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wfi_active <= 1'b0;
    end else if (i_wfi_start && !i_pipeline_stall) begin
      // Enter WFI wait state
      wfi_active <= 1'b1;
    end else if (m_int_pending || s_int_pending || any_int_pending_raw) begin
      // Exit WFI when any interrupt is pending (even if not enabled)
      wfi_active <= 1'b0;
    end
  end

  // Stall pipeline during WFI
  // TIMING OPTIMIZATION: Register the WFI stall signal to break the critical path
  // from interrupt_pending through stall computation to cache writes. Adding 1-cycle
  // latency to WFI stall release is acceptable since we're already in a stall state.
  logic stall_for_wfi_comb;
  assign stall_for_wfi_comb = wfi_active && !(m_int_pending || s_int_pending);

  always_ff @(posedge i_clk) begin
    if (i_rst) o_stall_for_wfi <= 1'b0;
    else o_stall_for_wfi <= stall_for_wfi_comb;
  end

  // Determine trap cause with per-class priority (M: MEI>MSI>MTI then the
  // undelegated supervisor classes SEI>SSI>STI; S: SEI>SSI>STI).
  // TIMING OPTIMIZATION: registered to stay synchronized with the latches.
  logic [XLEN-1:0] m_int_cause_comb, s_int_cause_comb;
  logic [XLEN-1:0] m_int_cause, s_int_cause;
  always_comb begin
    if (meip_enabled) m_int_cause_comb = riscv_pkg::IntMachineExternal;
    else if (msip_enabled) m_int_cause_comb = riscv_pkg::IntMachineSoftware;
    else if (mtip_enabled) m_int_cause_comb = riscv_pkg::IntMachineTimer;
    else if (seip_m_enabled) m_int_cause_comb = riscv_pkg::IntSupervisorExternal;
    else if (ssip_m_enabled) m_int_cause_comb = riscv_pkg::IntSupervisorSoftware;
    else if (stip_m_enabled) m_int_cause_comb = riscv_pkg::IntSupervisorTimer;
    else m_int_cause_comb = '0;
    if (seip_s_enabled) s_int_cause_comb = riscv_pkg::IntSupervisorExternal;
    else if (ssip_s_enabled) s_int_cause_comb = riscv_pkg::IntSupervisorSoftware;
    else if (stip_s_enabled) s_int_cause_comb = riscv_pkg::IntSupervisorTimer;
    else s_int_cause_comb = '0;
  end

  // Held-cause source-pending recheck: the registered cause may only be HELD
  // while its own source is still pending (and still targeting this class).
  // The class latch is held by an aggregate source-live OR, so without this
  // per-cause term a latched cause whose source dropped could ride a
  // DIFFERENT still-pending source through a globally-disabled window and be
  // taken later as a spurious stale cause (independent-review finding,
  // 2026-08-24). With it, a dropped source zeroes the held cause; the comb
  // priority re-resolves to the live source as soon as the class is
  // globally enabled again, so the held-tick delivery shape is preserved.
  logic m_int_cause_source_pending;
  always_comb begin
    unique case (m_int_cause)
      riscv_pkg::IntMachineExternal:    m_int_cause_source_pending = i_interrupts.meip;
      riscv_pkg::IntMachineSoftware:    m_int_cause_source_pending = i_interrupts.msip;
      riscv_pkg::IntMachineTimer:       m_int_cause_source_pending = i_interrupts.mtip;
      riscv_pkg::IntSupervisorExternal: m_int_cause_source_pending = seip && !deleg_sei;
      riscv_pkg::IntSupervisorSoftware: m_int_cause_source_pending = ssip && !deleg_ssi;
      riscv_pkg::IntSupervisorTimer:    m_int_cause_source_pending = stip && !deleg_sti;
      default:                          m_int_cause_source_pending = 1'b0;
    endcase
  end
  logic s_int_cause_source_pending;
  always_comb begin
    unique case (s_int_cause)
      riscv_pkg::IntSupervisorExternal: s_int_cause_source_pending = seip && deleg_sei;
      riscv_pkg::IntSupervisorSoftware: s_int_cause_source_pending = ssip && deleg_ssi;
      riscv_pkg::IntSupervisorTimer:    s_int_cause_source_pending = stip && deleg_sti;
      default:                          s_int_cause_source_pending = 1'b0;
    endcase
  end

  always_ff @(posedge i_clk) begin
    // Hold each cause while its class latch is held (across a global-enable
    // drop or the xRET inhibit) AND its own source remains pending; the comb
    // causes are built from the gated *_enabled so they decay to 0 there,
    // which would leave the held interrupt ineligible when it can finally
    // trap.
    if (m_int_cause_comb != '0) m_int_cause <= m_int_cause_comb;
    else if (m_int_pending && m_int_source_live && m_int_cause_source_pending)
      m_int_cause <= m_int_cause;
    else m_int_cause <= '0;
    if (s_int_cause_comb != '0) s_int_cause <= s_int_cause_comb;
    else if (s_int_pending && s_int_source_live && s_int_cause_source_pending)
      s_int_cause <= s_int_cause;
    else s_int_cause <= '0;
  end

  // A registered interrupt request must still be enabled — and still
  // targeting the same class — when it reaches the trap decision. This keeps
  // raw interrupt inputs out of the take_trap cone, while allowing CSR
  // writes (an mstatus restore, an mie/mideleg rewrite) to cancel a stale
  // one-cycle sample before an xRET.
  logic m_latched_source_enabled;
  always_comb begin
    unique case (m_int_cause)
      riscv_pkg::IntMachineExternal:    m_latched_source_enabled = mie_meie;
      riscv_pkg::IntMachineSoftware:    m_latched_source_enabled = mie_msie;
      riscv_pkg::IntMachineTimer:       m_latched_source_enabled = mie_mtie;
      riscv_pkg::IntSupervisorExternal: m_latched_source_enabled = mie_seie && !deleg_sei;
      riscv_pkg::IntSupervisorSoftware: m_latched_source_enabled = mie_ssie && !deleg_ssi;
      riscv_pkg::IntSupervisorTimer:    m_latched_source_enabled = mie_stie && !deleg_sti;
      default:                          m_latched_source_enabled = 1'b0;
    endcase
  end
  logic s_latched_source_enabled;
  always_comb begin
    unique case (s_int_cause)
      riscv_pkg::IntSupervisorExternal: s_latched_source_enabled = mie_seie && deleg_sei;
      riscv_pkg::IntSupervisorSoftware: s_latched_source_enabled = mie_ssie && deleg_ssi;
      riscv_pkg::IntSupervisorTimer:    s_latched_source_enabled = mie_stie && deleg_sti;
      default:                          s_latched_source_enabled = 1'b0;
    endcase
  end

  logic m_int_eligible, s_int_eligible;
  assign m_int_eligible = m_int_pending &&
      m_latched_source_enabled &&
      m_int_globally_enabled &&
      !trap_taken_prev &&
      !mret_interrupt_inhibit;
  assign s_int_eligible = s_int_pending &&
      s_latched_source_enabled &&
      s_int_globally_enabled &&
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
  logic m_take_armed_q, s_take_armed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      m_take_armed_q <= 1'b0;
      s_take_armed_q <= 1'b0;
    end else begin
      m_take_armed_q <= m_int_eligible && !o_trap_taken;
      s_take_armed_q <= s_int_eligible && !o_trap_taken;
    end
  end

  // Trap taken: either interrupt or exception, the pipeline not stalled
  // (except for WFI stall, which should be broken by interrupt), and no
  // committed store still draining (see i_sq_committed_empty). An armed
  // M-target take always precedes an armed S-target take (the spec's
  // cross-class ordering); the S latch survives losing the mux and delivers
  // once eligibility returns (inside the M handler after mideleg'd sources
  // re-qualify, or after MRET).
  logic m_int_take_ready, s_int_take_ready;
  assign m_int_take_ready = m_int_eligible && m_take_armed_q &&
      !i_amo_at_head && !i_device_read_at_head;
  assign s_int_take_ready = s_int_eligible && s_take_armed_q &&
      !i_amo_at_head && !i_device_read_at_head;

  // Exception delegation: decided from the REGISTERED exception cause (the
  // exception waits at the head with commit held, so priv and medeleg are
  // stable across the wait). Exceptions from M never delegate.
  logic exception_to_s;
  // Debug Mode (M3): an ebreak whose dcsr.ebreak bit is set for the current
  // privilege enters Debug Mode; every exception raised IN Debug Mode
  // re-parks the hart with no CSR side effect. Both take precedence over
  // delegation (priv is M in Debug Mode, so exception_to_s is 0 there).
  logic exception_ebreak_to_d, exception_in_debug;
  assign exception_ebreak_to_d = exception_pending && !i_debug_mode && dcsr_ebreak_here &&
      (exception_cause_q == riscv_pkg::ExcBreakpoint);
  assign exception_in_debug = exception_pending && i_debug_mode;
  assign exception_to_s = (i_priv != riscv_pkg::PrivM) && i_medeleg[exception_cause_q[3:0]] &&
      !exception_ebreak_to_d;

  logic take_trap;
  assign take_trap = (d_int_take_ready || m_int_take_ready || s_int_take_ready ||
                      exception_pending) &&
      !i_pipeline_stall &&
      i_sq_committed_empty;
  // Interrupt-only take strobes for the per-class latch guards: a class
  // latch clears only when ITS OWN interrupt is the one being taken. An
  // exception take never erases a held interrupt (eligibility gating alone
  // prevents a spurious post-entry take: the entry's priv/xIE update makes
  // the held class ineligible until software re-enables it), and a cross-
  // class interrupt take leaves the loser latched for delivery once its
  // eligibility returns.
  // Class D precedes both interrupt classes (a halt is precise at any
  // instruction boundary; a go/park redirect has nothing else pending).
  assign take_trap_d = take_trap && d_int_take_ready;
  assign take_trap_m = take_trap && !d_int_take_ready && m_int_take_ready;
  assign take_trap_s = take_trap && !d_int_take_ready && !m_int_take_ready && s_int_take_ready;

  // Which side's CSRs the entry writes. Interrupt takes steer by the winning
  // class; an exception steers by delegation.
  logic trap_to_s;
  assign trap_to_s = take_trap && !d_int_take_ready && !m_int_take_ready &&
      (s_int_take_ready || (exception_to_s && !exception_in_debug));
  // Debug Mode steering (see the port comments).
  logic exception_take;
  assign exception_take = take_trap && !d_int_take_ready && !m_int_take_ready && !s_int_take_ready;
  assign o_trap_to_d = (take_trap_d && !i_debug_mode) || (exception_take && exception_ebreak_to_d);
  assign o_trap_no_csr = (take_trap_d && i_debug_mode) || (exception_take && exception_in_debug);
  assign o_dbg_go_taken = take_trap_d && i_debug_mode;
  assign o_dbg_park_entry = exception_take && exception_in_debug;
  assign o_dbg_park_exception = o_dbg_park_entry && (exception_cause_q != riscv_pkg::ExcBreakpoint);
  // dcsr.cause: haltreq beats step (spec priority); an ebreak entry is 1.
  assign o_dbg_cause = d_int_take_ready ? (i_dbg_haltreq ? riscv_pkg::DcsrCauseHaltreq :
                                                          riscv_pkg::DcsrCauseStep) :
                                          riscv_pkg::DcsrCauseEbreak;

  // xRET execution.  Synchronous exceptions are structurally impossible with
  // an xRET at the ROB head; pending interrupts are deferred across the xRET
  // recovery window above so the return redirect stays precise. MRET and
  // SRET are mutually exclusive at the head (one instruction).
  logic take_mret, take_sret, take_dret;
  assign take_mret = i_mret_start && !i_pipeline_stall && !take_trap && i_sq_committed_empty;
  assign take_sret = i_sret_start && !i_pipeline_stall && !take_trap && i_sq_committed_empty;
  assign take_dret = i_dret_start && !i_pipeline_stall && !take_trap && i_sq_committed_empty;

  // Hold commit while a trap/xRET waits out the store drain, so the
  // committed set shrinks monotonically and the wait is bounded. The
  // interrupt arming windows also hold commit (see *_take_armed_q): by the
  // take cycle the hold is registered-active, so no commit can race the full
  // flush. The raw samples (*_int_pending_comb) are included because the ROB
  // observes the interrupt one cycle before the registered eligibility
  // (e.g. releasing a WFI's commit_stall) — without them the instruction
  // after a WFI could retire in the arming gap and advance the interrupt
  // resume PC past the architectural boundary (mepc = wfi_pc+8 instead of
  // wfi_pc+4 in the wfi_mepc regression).
  assign o_trap_drain_wait =
      ((d_int_eligible || m_int_eligible || s_int_eligible || exception_pending ||
        i_mret_start || i_sret_start || i_dret_start) && !i_sq_committed_empty) ||
      ((d_int_pending_comb || d_int_eligible) && !d_take_armed_q) ||
      ((m_int_pending_comb || m_int_eligible) && !m_take_armed_q) ||
      ((s_int_pending_comb || s_int_eligible) && !s_take_armed_q);

  // Output trap signals
  assign o_trap_taken = take_trap;
  assign o_trap_to_s = trap_to_s;
  assign o_mret_taken = take_mret;
  assign o_sret_taken = take_sret;
  assign o_dret_taken = take_dret;

  // Trap target: xtvec for trap entry, xepc for xRET.
  // xtvec MODE (bits [1:0]): 0 = Direct (all traps go to BASE)
  //                          1 = Vectored (interrupts go to BASE + 4*cause)
  logic [XLEN-1:0] trap_target_selected;
  logic interrupt_wins;
  assign interrupt_wins = m_int_take_ready || s_int_take_ready;
  always_comb begin
    if (take_mret) begin
      trap_target_selected = i_mepc;
    end else if (take_sret) begin
      trap_target_selected = i_sepc;
    end else if (take_dret) begin
      trap_target_selected = i_dpc;
    end else if (take_trap) begin
      if (d_int_take_ready) begin
        // Debug Mode: a halt entry parks the hart; go redirects where the
        // debug module asked.
        trap_target_selected = i_debug_mode ? i_dbg_go_target : XLEN'(riscv_pkg::DebugParkAddr);
      end else if (exception_ebreak_to_d || exception_in_debug) begin
        trap_target_selected = XLEN'(riscv_pkg::DebugParkAddr);
      end else if (trap_to_s) begin
        if (i_stvec[1:0] == 2'b01 && interrupt_wins) begin
          trap_target_selected =
              {i_stvec[XLEN-1:2], 2'b00} + {{(XLEN - 6) {1'b0}}, s_vectored_offset};
        end else begin
          trap_target_selected = {i_stvec[XLEN-1:2], 2'b00};
        end
      end else begin
        if (i_mtvec[1:0] == 2'b01 && interrupt_wins) begin
          // Vectored mode for interrupts: BASE + 4*cause_code. Use the
          // pre-computed small offset (6 bits) for faster timing than
          // extracting from the full cause.
          trap_target_selected =
              {i_mtvec[XLEN-1:2], 2'b00} + {{(XLEN - 6) {1'b0}}, m_vectored_offset};
        end else begin
          // Direct mode: all traps go to BASE (aligned to 4 bytes)
          trap_target_selected = {i_mtvec[XLEN-1:2], 2'b00};
        end
      end
    end else begin
      trap_target_selected = '0;
    end

    // Phase 3 M2: the redirect flows FULL-WIDTH. A wild xtvec/xepc reaches
    // the PC unchanged and raises a precise instruction access fault at
    // fetch (a wild trap vector then loops on that fault, which is the
    // architecturally-correct outcome of the software bug).
    o_trap_target = trap_target_selected;
  end

  // Trap entry information for CSR file (written to the o_trap_to_s side).
  // Interrupts have priority over synchronous exceptions; M-target over
  // S-target.
  always_comb begin
    if (d_int_take_ready) begin
      // Debug Mode entry: dpc = the precise resume PC (the interrupt
      // path's); no cause/value is written (o_dbg_cause carries dcsr.cause).
      o_trap_cause = '0;
      o_trap_value = '0;
      o_trap_pc = i_interrupt_pc;
    end else if (m_int_take_ready) begin
      o_trap_cause = m_int_cause;
      o_trap_value = '0;  // Interrupts have xtval = 0
      // For interrupts, save the precise architectural resume PC.  The live
      // ROB head PC can be transient or stale while an async interrupt drains
      // through the registered commit path.
      o_trap_pc = i_interrupt_pc;
    end else if (s_int_take_ready) begin
      o_trap_cause = s_int_cause;
      o_trap_value = '0;
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
    assume (!(i_sret_start && i_exception_valid));
    assume (!(i_mret_start && i_sret_start));
    assume (!(i_wfi_start && i_mret_start));
    assume (!(i_wfi_start && i_sret_start));
    assume (!(i_wfi_start && i_exception_valid));
    // Debug Mode (M3): DRET is one of the mutually exclusive head
    // instructions and only reaches the trap unit from Debug Mode (the
    // ROB's live head gate); the debug module never asserts go outside
    // Debug Mode (masked here anyway).
    assume (!(i_dret_start && (i_mret_start || i_sret_start || i_exception_valid || i_wfi_start)));
    assume (!(i_dret_start && !i_debug_mode));
    // The privilege register never holds the reserved encoding (proven in
    // csr_file's own target).
    assume (i_priv != 2'b10);
    // Note: xRET + a pending interrupt is NOT assumed away. An interrupt that
    // is already ARMED (eligible since the previous cycle) may preempt the
    // xRET in its FIRST start cycle (take_xret yields to take_trap and the
    // xRET re-executes after the handler); from the second cycle on the
    // registered inhibit defers the interrupt until after the return
    // redirect has retired the xRET precisely.
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // Trap/xRET mutex: cannot fire simultaneously.
      p_trap_mret_mutex : assert (!(o_trap_taken && o_mret_taken));
      p_trap_dret_mutex : assert (!(o_trap_taken && o_dret_taken));
      p_dret_mret_mutex : assert (!(o_dret_taken && (o_mret_taken || o_sret_taken)));
      p_trap_sret_mutex : assert (!(o_trap_taken && o_sret_taken));
      p_mret_sret_mutex : assert (!(o_mret_taken && o_sret_taken));

      // Trap needs source: trap_taken requires an interrupt or exception.
      p_trap_needs_source :
      assert (!o_trap_taken || (d_int_take_ready || m_int_take_ready || s_int_take_ready ||
                                exception_pending));
      // Debug Mode (M3) steering invariants.
      p_no_int_in_debug :
      assert (!(o_trap_taken && (m_int_take_ready || s_int_take_ready) && i_debug_mode));
      p_no_int_while_stepping :
      assert (!(o_trap_taken && (m_int_take_ready || s_int_take_ready) && i_dbg_step_armed));
      p_d_over_m : assert (!(o_trap_taken && d_int_take_ready && (o_trap_to_s || trap_to_s)));
      p_d_take_is_d :
      assert (!(o_trap_taken && d_int_take_ready) || (o_trap_to_d || o_trap_no_csr));
      p_to_d_no_csr_mutex : assert (!(o_trap_to_d && o_trap_no_csr));
      p_to_d_needs_take : assert (!(o_trap_to_d || o_trap_no_csr) || o_trap_taken);
      p_halt_only_outside_debug : assert (!o_trap_to_d || !i_debug_mode);
      p_go_only_in_debug : assert (!o_dbg_go_taken || i_debug_mode);
      p_go_target : assert (!o_dbg_go_taken || (o_trap_target == i_dbg_go_target));
      p_halt_target :
      assert (!(o_trap_to_d && d_int_take_ready) ||
              (o_trap_target == XLEN'(riscv_pkg::DebugParkAddr)));
      p_debug_exception_no_csr :
      assert (!(o_trap_taken && exception_in_debug && !d_int_take_ready) ||
              (o_trap_no_csr && (o_trap_target == XLEN'(riscv_pkg::DebugParkAddr))));
      p_ebreak_routes_to_d :
      assert (!(o_trap_taken && exception_ebreak_to_d && !d_int_take_ready &&
                !m_int_take_ready && !s_int_take_ready) ||
              (o_trap_to_d && !o_trap_to_s && (o_trap_target == XLEN'(riscv_pkg::DebugParkAddr))));
      p_park_entry_is_exception :
      assert (!o_dbg_park_entry || (o_trap_taken && exception_in_debug));
      p_dret_target : assert (!o_dret_taken || (o_trap_target == i_dpc));
      p_dret_not_stalled : assert (!o_dret_taken || !i_pipeline_stall);
      p_dret_waits_drain : assert (!o_dret_taken || i_sq_committed_empty);
      p_d_shield_blocks_halt :
      assert (!(o_trap_taken && (i_device_read_at_head || i_amo_at_head)) || !d_int_take_ready);

      // Trap not during stall: traps only fire when pipeline not stalled.
      p_trap_not_stalled : assert (!o_trap_taken || !i_pipeline_stall);

      // xRET not during stall.
      p_mret_not_stalled : assert (!o_mret_taken || !i_pipeline_stall);
      p_sret_not_stalled : assert (!o_sret_taken || !i_pipeline_stall);

      // Neither traps nor xRETs may fire while committed stores drain.
      p_trap_waits_drain : assert (!o_trap_taken || i_sq_committed_empty);

      // Interrupt shields. A shielded head keeps the INTERRUPT arm of the trap
      // out of the take decision; an exception at the head still takes, which
      // is what makes both shields bounded rather than blocking.
      p_device_shield_blocks_interrupt :
      assert (!(o_trap_taken && i_device_read_at_head) || exception_pending);
      p_amo_shield_blocks_interrupt :
      assert (!(o_trap_taken && i_amo_at_head) || exception_pending);
      p_mret_waits_drain : assert (!o_mret_taken || i_sq_committed_empty);
      p_sret_waits_drain : assert (!o_sret_taken || i_sq_committed_empty);

      // xRET targets are exactly xepc (Phase 3 M2: full-width, unmasked).
      p_mret_target : assert (!o_mret_taken || (o_trap_target == i_mepc));
      p_sret_target : assert (!o_sret_taken || (o_trap_target == i_sepc));

      // A pending interrupt must not preempt an xRET that has been in flight
      // for a full cycle (the registered inhibit window). The FIRST start
      // cycle is exempt: an already-armed interrupt may win there — the
      // take yields and the xRET re-executes after the handler.
      if (mret_start_q && i_mret_start && !exception_pending) begin
        p_mret_defers_interrupt : assert (!o_trap_taken);
      end
      if (sret_start_q && i_sret_start && !exception_pending) begin
        p_sret_defers_interrupt : assert (!o_trap_taken);
      end
      if (dret_start_q && i_dret_start && !exception_pending) begin
        p_dret_defers_interrupt : assert (!o_trap_taken);
      end

      // Cross-class ordering (the spec rule delegation introduces): an
      // interrupt destined for M is taken before one destined for S — an
      // S-target take never fires while an M-target take is ready.
      p_m_over_s : assert (!(o_trap_taken && o_trap_to_s && m_int_take_ready));

      // Target-side steering invariants: an S-target interrupt take always
      // steers to S, and an S-target interrupt is NEVER taken while in M.
      p_s_take_steers_s :
      assert (!(o_trap_taken && !d_int_take_ready && !m_int_take_ready && s_int_take_ready) ||
              o_trap_to_s);
      p_s_never_in_m : assert (!(o_trap_taken && o_trap_to_s && (i_priv == riscv_pkg::PrivM)));
      // Delegated exceptions steer to S exactly per medeleg and priv — except
      // in Debug Mode, where every exception re-parks the hart (M3).
      if (o_trap_taken && !d_int_take_ready && !m_int_take_ready && !s_int_take_ready) begin
        p_exception_delegation_exact :
        assert (o_trap_to_s == (exception_to_s && !exception_in_debug));
      end

      // WFI stall contract: if stall_for_wfi_comb, wfi must be active.
      p_wfi_stall_needs_active : assert (!stall_for_wfi_comb || wfi_active);
    end

    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // M-class priority: MEI > MSI > MTI > (undelegated) SEI > SSI > STI.
      if ($past(meip_enabled)) begin
        p_meip_priority : assert (m_int_cause == riscv_pkg::IntMachineExternal);
      end
      if ($past(!meip_enabled && msip_enabled)) begin
        p_msip_priority : assert (m_int_cause == riscv_pkg::IntMachineSoftware);
      end
      if ($past(!meip_enabled && !msip_enabled && mtip_enabled)) begin
        p_mtip_priority : assert (m_int_cause == riscv_pkg::IntMachineTimer);
      end
      if ($past(!meip_enabled && !msip_enabled && !mtip_enabled && seip_m_enabled)) begin
        p_seip_m_priority : assert (m_int_cause == riscv_pkg::IntSupervisorExternal);
      end
      // S-class priority: SEI > SSI > STI.
      if ($past(seip_s_enabled)) begin
        p_seip_s_priority : assert (s_int_cause == riscv_pkg::IntSupervisorExternal);
      end
      if ($past(!seip_s_enabled && ssip_s_enabled)) begin
        p_ssip_s_priority : assert (s_int_cause == riscv_pkg::IntSupervisorSoftware);
      end
      if ($past(!seip_s_enabled && !ssip_s_enabled && stip_s_enabled)) begin
        p_stip_s_priority : assert (s_int_cause == riscv_pkg::IntSupervisorTimer);
      end

      // Vectored offset correctness (spot checks per class).
      if ($past(meip_enabled)) begin
        p_vectored_meip : assert (m_vectored_offset == 6'd44);
      end
      if ($past(!meip_enabled && msip_enabled)) begin
        p_vectored_msip : assert (m_vectored_offset == 6'd12);
      end
      if ($past(!meip_enabled && !msip_enabled && mtip_enabled)) begin
        p_vectored_mtip : assert (m_vectored_offset == 6'd28);
      end
      if ($past(seip_s_enabled)) begin
        p_vectored_seip : assert (s_vectored_offset == 6'd36);
      end
      if ($past(!seip_s_enabled && ssip_s_enabled)) begin
        p_vectored_ssip : assert (s_vectored_offset == 6'd4);
      end
      if ($past(!seip_s_enabled && !ssip_s_enabled && stip_s_enabled)) begin
        p_vectored_stip : assert (s_vectored_offset == 6'd20);
      end

      // Re-entry prevention: after trap_taken, interrupt enables are blocked
      // for one cycle via trap_taken_prev.
      if (trap_taken_prev) begin
        p_reentry_prevention :
        assert (!meip_enabled && !mtip_enabled && !msip_enabled &&
                !seip_m_enabled && !ssip_m_enabled && !stip_m_enabled &&
                !seip_s_enabled && !ssip_s_enabled && !stip_s_enabled);
      end

      // A retargeted source (mideleg flipped while latched) can never be
      // taken with the old class: the latched-source-enabled recheck carries
      // the live mideleg term.
      if ($past(deleg_sei && deleg_sti && deleg_ssi) && deleg_sei && deleg_sti && deleg_ssi) begin
        p_m_latch_no_delegated_take :
        assert (!(take_trap_m && (m_int_cause == riscv_pkg::IntSupervisorExternal ||
                                  m_int_cause == riscv_pkg::IntSupervisorSoftware ||
                                  m_int_cause == riscv_pkg::IntSupervisorTimer)));
      end

      // Reset clears all state.
      if ($past(i_rst)) begin
        p_reset_trap_prev : assert (!trap_taken_prev && !sret_taken_prev);
        p_reset_wfi : assert (!wfi_active);
        p_reset_int_pending : assert (!m_int_pending && !s_int_pending && !d_int_pending);
      end
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_trap_taken : cover (o_trap_taken);
      cover_trap_taken_to_s : cover (o_trap_taken && o_trap_to_s);
      cover_mret_taken : cover (o_mret_taken);
      cover_sret_taken : cover (o_sret_taken);
      cover_dret_taken : cover (o_dret_taken);
      cover_debug_halt : cover (o_trap_to_d && d_int_take_ready && i_dbg_haltreq);
      cover_debug_step_halt : cover (o_trap_to_d && d_int_take_ready && !i_dbg_haltreq);
      cover_debug_ebreak_entry : cover (o_trap_to_d && !d_int_take_ready);
      cover_debug_go : cover (o_dbg_go_taken);
      cover_debug_park_exception : cover (o_dbg_park_exception);
      cover_debug_park_ebreak : cover (o_dbg_park_entry && !o_dbg_park_exception);
      cover_debug_halt_after_shield :
      cover (f_past_valid && take_trap_d && $past(
          d_int_eligible && d_take_armed_q && i_device_read_at_head
      ));
      cover_wfi_stall : cover (stall_for_wfi_comb);
      cover_wfi_wakeup : cover (f_past_valid && !wfi_active && $past(wfi_active));
      cover_external_interrupt :
      cover (m_int_eligible && m_int_cause == riscv_pkg::IntMachineExternal);
      cover_s_interrupt_take : cover (take_trap_s);
      cover_undelegated_s_source_to_m :
      cover (take_trap_m && (m_int_cause == riscv_pkg::IntSupervisorExternal));
      cover_m_wins_over_armed_s : cover (take_trap_m && s_take_armed_q && s_int_eligible);
      cover_s_take_after_losing_to_m :
      cover (f_past_valid && take_trap_s && $past(s_int_pending, 2));
      cover_exception :
      cover (o_trap_taken && i_exception_valid && !m_int_take_ready && !s_int_take_ready);
      cover_delegated_exception : cover (o_trap_taken && o_trap_to_s && exception_to_s);
      cover_trap_after_drain : cover (f_past_valid && o_trap_taken && $past(o_trap_drain_wait));
      // The device shield defers a ready interrupt, then it takes as soon as
      // the shield drops -- the liveness shape the bounded argument relies on.
      cover_device_shield_defers_interrupt :
      cover (i_device_read_at_head && m_int_eligible && m_take_armed_q &&
             i_sq_committed_empty && !o_trap_taken);
      cover_device_shield_release_takes_interrupt :
      cover (f_past_valid && o_trap_taken && $past(
          i_device_read_at_head && m_int_eligible
      ) && !i_device_read_at_head);
      // While the device shield defers, commit must NOT be held (that is the
      // forward-progress half of the bounded argument).
      cover_device_shield_defers_without_commit_hold :
      cover (i_device_read_at_head && m_int_eligible && !o_trap_drain_wait);
    end
  end

`endif  // FORMAL

endmodule : trap_unit
