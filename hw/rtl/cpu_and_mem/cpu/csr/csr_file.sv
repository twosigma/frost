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
  RISC-V Zicsr, Zicntr, M/S/U-mode, F-extension, and custom Tomasulo profiling CSRs.

  Supervisor mode (Phase 3, plan D1/D2):
    - sstatus (0x100), sie (0x104), sip (0x144): restricted VIEWS of the
      mstatus/mie/mip storage. sie/sip expose the supervisor interrupt bits
      (SSI/STI/SEI) only where mideleg delegates them (non-delegated bits
      read 0 and discard writes); sip.SSIP is the only S-writable pending
      bit. The view definition is reader-privilege-independent (M reading
      sie sees the same mideleg-masked view).
    - stvec (0x105), sscratch (0x140), sepc (0x141), scause (0x142),
      stval (0x143): dedicated registers, WARL rules mirroring their M twins.
    - scounteren (0x106): CY/TM/IR gate for U-mode below S; 3-bit WARL like
      mcounteren, reset 0x7 (same platform choice: counters U-readable out
      of reset, preserving pre-S bare-metal behavior).
    - satp (0x180): MODE/ASID/PPN storage. ASID is WARL-0 (no ASID tagging
      this phase); the PPN field stores all 44 bits (WARL keep).
      A write with an unsupported MODE leaves the whole register unchanged
      (privileged-spec rule). The supported MODE set is {Bare, Sv39}.
    - medeleg (0x302) / mideleg (0x303): delegation registers, WARL to
      riscv_pkg::MedelegMask / MidelegMask (ecall-from-M and the machine
      interrupt classes are read-only zero per the spec).
    - menvcfg (0x30A) / senvcfg (0x10A): present (S/U-mode make them
      mandatory) with no implemented fields yet — RAZ/WI.
    - mstatus gains SIE/SPIE/SPP and SUM/MXR/TVM/TW/TSR; MPRV is now
      architecturally live (the data-side effective privilege consumes it
      from Phase 3 M4). MPP is WARL over {U, S, M}; the reserved encoding
      2'b10 folds to U (matches the pinned Spike).
    - Trap entry steers by i_trap_to_s: the S side saves sepc/scause/stval
      and SPIE<-SIE, SIE<-0, SPP<-(priv==S), priv<-S; the M side keeps the
      existing behavior (MPP now records S too). SRET (i_sret_taken)
      restores SIE<-SPIE, SPIE<-1, priv<-SPP?S:U, SPP<-U, and clears MPRV
      (xRET to below M always clears MPRV per the spec; MRET keeps its
      conditional clear).
    - o_csr_translation_flush_req (plan D10): one-cycle invalidate pulse for
      any enabled committed satp access, or for an mstatus/sstatus commit whose
      computed result CHANGES SUM/MXR/MPRV (or MPP while MPRV is set). The ROB
      serializer independently owns conservative pre-retirement committed-store
      drain and the subsequent pipeline recovery.

  Debug Mode CSRs (RISC-V Debug Spec 0.13.2, Phase 3 M3, plan D14):
    - dcsr (0x7B0): xdebugver=4; ebreakm/ebreaks/ebreaku, step and prv are
      writable (prv WARL over {U, S, M}, 2'b10 folds to U like MPP); cause
      is read-only (set on entry: 1 ebreak, 3 haltreq, 4 step);
      stepie/stopcount/stoptime read 0, mprven reads 1 (MPRV keeps its
      M-mode meaning in Debug Mode), nmip 0.
    - dpc (0x7B1): the resume PC (2-byte aligned like mepc).
    - dscratch0/1 (0x7B2/0x7B3): plain 64-bit scratch registers.
    - ddata (0x7B4, custom): the debug module's {data1,data0} pair as one
      64-bit CSR (hartinfo dataaccess=0 / dataaddr=0x7B4); the storage is
      the DM's, forwarded through i_dbg_data / o_dbg_data_we like mtime.
    All five are legal only in Debug Mode (the reorder buffer captures an
    illegal-instruction exception when such an entry allocates outside Debug
    Mode). Debug entry (i_trap_taken &&
    i_trap_to_d) saves dpc <- trap PC, dcsr.cause/prv, and installs priv=M
    (Debug Mode executes with M privilege: every privilege consumer sees M)
    without touching mstatus/mepc/mcause/mtval; DRET (i_dret_taken)
    restores priv <- dcsr.prv, leaves Debug Mode, and clears MPRV when the
    new privilege is below M (the pinned Spike's dret).

  F extension CSRs (floating-point control/status):
    - fflags (0x001): FP exception flags (NV, DZ, OF, UF, NX) - sticky, accumulated
    - frm (0x002): FP rounding mode (RNE, RTZ, RDN, RUP, RMM)
    - fcsr (0x003): Combined FP control/status (frm[7:5] | fflags[4:0])

  Zicntr base counters (read-only):
    - cycle/cycleh (0xC00/0xC80): Clock cycle counter (64-bit)
    - mcycle/mcycleh (0xB00/0xB80): Machine-mode alias for cycle counter
    - time/timeh (0xC01/0xC81): Wall-clock time (from mtime input)
    - instret/instreth (0xC02/0xC82): Instructions retired counter (64-bit)
    - minstret/minstreth (0xB02/0xB82): Machine-mode alias for instret counter
  At XLEN=64 the counters are single 64-bit CSRs and every *h address
  (cycleh/timeh/instreth/mcycleh/minstreth) raises illegal-instruction at
  any privilege (captured by the reorder buffer at allocation).
  U-mode access to the 0xCxx counter CSRs is gated by mcounteren; the
  reorder buffer snapshots the illegal-instruction check at allocation using
  the privilege-resolved o_counter_blocked bits, so this module only stores
  the register and exports the gate state.

  Machine-mode CSRs (for trap/interrupt handling; M, S, and U privilege modes):
    - mstatus (0x300): Machine status (MIE, MPIE bits; MPP WARL field
      {M, S, U}; live MPRV data-privilege override; FS [14:13] writable with
      hardware Dirty-setting and SD mirroring FS==Dirty at the top bit — D15;
      resets to FS=Initial)
    - misa (0x301): Machine ISA (read-only, GCB + U at the built XLEN:
      0x4010_112F at 32, 0x8000_0000_0010_112F at 64)
    - mie (0x304): Machine interrupt enable (MEIE, MTIE, MSIE)
    - mtvec (0x305): Machine trap vector base address
    - mcounteren (0x306): U-mode counter enable; WARL, only CY/TM/IR exist
      (no hpmcounters), resets to 0x7 (counters U-readable out of reset)
    - mscratch (0x340): Machine scratch register
    - mepc (0x341): Machine exception PC
    - mcause (0x342): Machine trap cause
    - mtval (0x343): Machine trap value
    - mip (0x344): Machine interrupt pending (read-only, directly wired to inputs)

  Machine information registers (read-only):
    - mhartid (0xF14): Hardware thread ID (always 0 for single-core)

  Custom profiling CSRs (Tomasulo performance counters):
    - mperfsel (0x7C0): Profiling counter selector
    - mperfctl (0x7C1): Bit 0 triggers a counter snapshot; bit 1 selects the
      previous cache snapshot for readback; reads return 0
    - mperfdata/mperfdatah (0xFC0/0xFC1): Selected counter value (low/high 32 bits)
    - mperfcount (0xFC2): Number of profiling counters

  The module supports all six Zicsr instructions:
    - CSRRW/CSRRWI: Atomic read/write
    - CSRRS/CSRRSI: Atomic read and set bits
    - CSRRC/CSRRCI: Atomic read and clear bits
*/
module csr_file #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    // CSR access interface (directly from ID/EX stage)
    input  logic            i_csr_read_enable,    // CSR instruction in EX stage
    input  logic [    11:0] i_csr_address,        // CSR address
    input  logic [     2:0] i_csr_op,             // CSR operation (funct3)
    input  logic [XLEN-1:0] i_csr_write_data,     // rs1 value or zero-extended immediate
    input  logic            i_csr_write_enable,   // Actually perform write (not stalled/flushed)
    output logic [XLEN-1:0] o_csr_read_data,      // CSR read value (registered, 1-cycle latency)
    output logic [XLEN-1:0] o_csr_read_data_comb, // CSR read value (combinational, same cycle)

    // Instruction retire count: 0, 1, or 2 per cycle.  For widen-commit
    // the OOO core can retire two entries in a single cycle; the instret
    // counter must increment by the retire count.
    input logic [1:0] i_instruction_retired_count,

    // Interrupt pending inputs (meip/mtip registered upstream in cpu_and_mem; msip direct)
    input riscv_pkg::interrupt_t i_interrupts,

    // mtime input (from memory-mapped timer)
    input logic [63:0] i_mtime,

    // PLIC S-context external-interrupt line (Phase 3 M6, plan D11): ORed
    // into the SEIP readback and the S-pending exports; mip.SEIP writes
    // still touch only the software-injection bit (D2's rule).
    input logic i_seip_line,

    // Trap entry signals (from trap unit)
    input logic            i_trap_taken,  // Trap is being taken
    input logic            i_trap_to_s,   // Trap targets S (delegated); else M
    input logic [XLEN-1:0] i_trap_pc,     // PC to save to mepc/sepc
    input logic [XLEN-1:0] i_trap_cause,  // Cause to save to mcause/scause
    input logic [XLEN-1:0] i_trap_value,  // Value to save to mtval/stval

    // xRET signals (from trap unit); mutually exclusive pulses
    input  logic        i_mret_taken,      // MRET is being executed
    input  logic        i_sret_taken,      // SRET is being executed
    // Debug Mode (Phase 3 M3). i_trap_taken && i_trap_to_d is a Debug Mode
    // entry (cpu_ooo withholds i_trap_taken for the trap unit's CSR-free
    // Debug Mode redirects). i_trap_dbg_cause is the dcsr.cause to record.
    input  logic        i_trap_to_d,
    input  logic [ 2:0] i_trap_dbg_cause,
    input  logic        i_dret_taken,      // DRET is being executed
    // ddata (0x7B4): the debug module's data0/data1 pair, forwarded.
    input  logic [63:0] i_dbg_data,
    output logic        o_dbg_data_we,
    output logic [63:0] o_dbg_data_wdata,

    // CSR outputs for trap/interrupt handling
    output logic [XLEN-1:0] o_mstatus,
    output logic [XLEN-1:0] o_mie,
    output logic [XLEN-1:0] o_mtvec,
    // |mtvec[XLEN-1:2] ("a trap vector is installed, so misaligned accesses
    // trap"), registered with mtvec from the same write data. TIMING: the
    // LSU consumed a live 62-bit reduce of the register, routed across the
    // die into its issue-time misalignment decision.
    output logic o_mtvec_traps_misaligned,
    output logic [XLEN-1:0] o_mepc,
    output logic [XLEN-1:0] o_stvec,
    output logic [XLEN-1:0] o_sepc,

    // Direct output of mstatus MIE bit for timing and simpler consumers.
    output logic o_mstatus_mie_direct,
    // Direct output of mstatus SIE bit (S-target interrupt global enable).
    output logic o_sstatus_sie_direct,

    // Delegation registers for the trap unit's routing decisions.
    // o_mideleg_s packs the supervisor classes as {SEI, STI, SSI}.
    output logic [15:0] o_medeleg,
    output logic [ 2:0] o_mideleg_s,

    // Effective supervisor interrupt-pending bits {SEIP, STIP, SSIP}:
    // the software-writable mip bits (M6 ORs the PLIC S-context line into
    // SEIP). Consumed by the trap unit and the WFI wake OR.
    output logic [2:0] o_s_pending,

    // Current privilege mode (PrivM/PrivS/PrivU): consumed by trap_unit
    // (per-target interrupt enables), the commit-time ECALL cause select,
    // and the reorder buffer's allocation legality snapshot. Changes only
    // on trap entry and xRET.
    output logic [1:0] o_priv,

    // mcounteren counter-enable bits ([0]=CY/cycle, [1]=TM/time,
    // [2]=IR/instret): raw state export; o_counter_blocked below resolves the
    // S/U-mode counter-CSR legality seen by ROB allocation. Changes only on a
    // committed CSR write.
    output logic [2:0] o_mcounteren,
    // scounteren counter-enable bits (same layout): gates U-mode below S.
    output logic [2:0] o_scounteren,

    // Pre-composed legality bits sampled by the reorder buffer at allocation.
    // All inputs are registered, serialized state (priv, mstatus.TSR/TVM/TW,
    // mcounteren/scounteren). CSR writes stop younger allocation, and any
    // privilege change interposes a flushing trap/xRET, so each stored verdict
    // remains exact until retirement.
    //   o_counter_blocked[2:0]: a CY/TM/IR counter access is illegal at the
    //     CURRENT privilege (U: needs mcounteren AND scounteren; S: needs
    //     mcounteren; M: never blocked).
    //   o_sret_illegal:   SRET illegal here (U always; S when TSR).
    //   o_sfence_illegal: SFENCE.VMA/satp access illegal here (U always;
    //     S when TVM).
    //   o_wfi_illegal:    WFI illegal here (U always; S when TW).
    //   o_priv_is_u:      priv == U (the needs-S CSR arm).
    output logic [2:0] o_counter_blocked,
    // Sstc (M6, D12): an S-mode stimecmp access with menvcfg.STCE=0 is an
    // illegal instruction (M is never blocked; U faults via the generic
    // needs-S rule). Same pre-composed-gate contract as o_counter_blocked.
    output logic o_stimecmp_blocked,
    output logic o_sret_illegal,
    output logic o_sfence_illegal,
    output logic o_wfi_illegal,
    output logic o_priv_is_u,

    // Plan D10: one-cycle TLB/PTW invalidate pulse for any enabled committed
    // satp access, or an mstatus/sstatus commit whose computed result changes
    // SUM/MXR/MPRV (or MPP while MPRV=1). The ROB serializer independently
    // owns conservative pipeline recovery.
    output logic o_csr_translation_flush_req,

    // Phase 3 M4: the data-translation state bundle, registered here so the
    // whole bundle is quasi-static and coherent — every input change (satp
    // write, SUM/MXR/MPRV/MPP-under-MPRV write, trap entry, xret) rides a
    // D10 or trap/xret flush whose refetch shadow outlasts the one-cycle
    // registration lag, so no memory op can consume a mixed view.
    output logic o_translation_active,  // satp Sv39 && effective data priv < M
    output logic o_mmu_sum,
    output logic o_mmu_mxr,
    output logic o_mmu_eff_priv_u,  // effective data privilege == U
    // Phase 3 M5: the FETCH side translates on the CURRENT privilege (MPRV
    // affects data only). Unlike the data bundle these are NOT re-registered:
    // they decode straight off priv_q / satp so a privilege or mode change
    // immediately hides any old tagged fetch result. The following redirect
    // resolves its registered target under the new state; Bare remains a
    // direct combinational path.
    output logic o_fetch_translation_active,  // satp Sv39 && priv != M
    output logic o_fetch_priv_u,  // current privilege == U
    // Root PPN for the walker (satp.PPN, registered storage; stable across
    // any live walk — a satp write's D10 flush also discards the walk).
    output logic [43:0] o_satp_root_ppn,

    // D15: mstatus.FS == Off. Sampled by the reorder buffer's FP-op legality
    // check at allocation. Changes only on a committed CSR write
    // (Dirty-setting only moves it further from Off).
    output logic o_mstatus_fs_off,

    // Debug Mode state exports (Phase 3 M3): the live Debug-Mode bit (the
    // reorder buffer's DRET / debug-CSR allocation check, the trap unit's
    // interrupt mask and cause routing, the debug module's halted view),
    // dcsr.step / dcsr.ebreak{m,s,u} for the trap unit and the step arming,
    // and dpc as the DRET target. Change only through a flushing trap/DRET
    // or a head-serialized CSR write.
    output logic            o_debug_mode,
    output logic            o_dcsr_step,
    output logic [     2:0] o_dcsr_ebreak,  // {ebreakm, ebreaks, ebreaku}
    output logic [XLEN-1:0] o_dpc,

    // F extension: FP exception flags from FPU (to accumulate in fflags)
    input riscv_pkg::fp_flags_t i_fp_flags,
    input logic i_fp_flags_valid,  // Valid when a committing FP instruction has flags

    // D15: a committing instruction writes the FP regfile this cycle
    // (either commit slot). Together with i_fp_flags_valid and the internal
    // fflags/frm/fcsr write decode this drives hardware FS=Dirty setting.
    input logic i_fp_dest_write,

    // F extension: same-cycle read-forwarding qualifier. In cpu_ooo this is driven by the
    // same ROB-commit signal as i_fp_flags_valid, so a CSR fflags/fcsr read sees the flags
    // of an FP instruction committing in the same cycle.
    input logic i_fp_flags_wb_valid,

    // F extension: FP flags from MA stage (legacy in-order forwarding path; tied off in cpu_ooo)
    input riscv_pkg::fp_flags_t i_fp_flags_ma,
    input logic                 i_fp_flags_ma_valid, // Valid when FP instruction in MA stage

    // F extension: Rounding mode output for FPU
    output logic [2:0] o_frm,

    // Tomasulo profiling counters
    output logic [ 7:0] o_perf_counter_select,
    output logic        o_perf_snapshot_capture,
    output logic        o_perf_cache_previous_select,
    input  logic [63:0] i_perf_counter_data,
    input  logic [31:0] i_perf_counter_count
);

  // ==========================================================================
  // CSR Registers
  // ==========================================================================

  // 64-bit counters for Zicntr
  logic [    63:0] cycle_counter;
  logic [    63:0] instret_counter;

  // F extension CSRs
  logic [     4:0] fflags;  // FP exception flags: {NV, DZ, OF, UF, NX}
  logic [     2:0] frm;  // FP rounding mode

  // fcsr is a composite view: {24'b0, frm[2:0], fflags[4:0]}
  logic [XLEN-1:0] fcsr;
  assign fcsr  = XLEN'({24'b0, frm, fflags});

  // Output rounding mode for FPU
  assign o_frm = frm;

  // Machine-mode CSRs
  // mstatus: store MIE and MPIE as separate registers so hot-path bit updates
  // do not require read/modify/write of the full CSR word.
  logic       mstatus_mie;  // Machine Interrupt Enable (bit 3)
  logic       mstatus_mpie;  // Machine Previous Interrupt Enable (bit 7)
  logic [1:0] mstatus_mpp;  // Previous Privilege [12:11]; WARL {PrivM,PrivS,PrivU}
  logic       mstatus_mprv;  // Modify PRiV (bit 17); consumed by the D-side
                             // effective privilege from Phase 3 M4
  // Supervisor trap-stack fields (Phase 3): live in the mstatus storage and
  // are exposed through both mstatus and the sstatus view.
  logic       mstatus_sie;  // Supervisor Interrupt Enable (bit 1)
  logic       mstatus_spie;  // Supervisor Previous Interrupt Enable (bit 5)
  logic       mstatus_spp;  // Supervisor Previous Privilege (bit 8; 0=U 1=S)
  // Virtualization/translation control fields (Phase 3).
  logic       mstatus_sum;  // permit Supervisor User-Memory access (bit 18)
  logic       mstatus_mxr;  // Make eXecutable Readable (bit 19)
  logic       mstatus_tvm;  // Trap Virtual Memory (bit 20)
  logic       mstatus_tw;  // Timeout Wait (bit 21)
  logic       mstatus_tsr;  // Trap SRET (bit 22)
  // FS [14:13] (D15): FP context status. Writable 2-bit field; hardware
  // sets Dirty on any FP architectural-state write (FP regfile dest,
  // FP-flag accrual, fflags/frm/fcsr CSR write); the reorder buffer samples
  // o_mstatus_fs_off at allocation and marks FP instructions illegal when
  // Off. Resets to Initial so FP works without OS setup.
  logic [1:0] mstatus_fs;
  localparam logic [1:0] FsOff = 2'b00;
  localparam logic [1:0] FsInitial = 2'b01;
  localparam logic [1:0] FsDirty = 2'b11;
  logic fs_dirty;
  assign fs_dirty = (mstatus_fs == FsDirty);
  logic [1:0] priv_q;  // Current privilege mode (resets to PrivM)
  // Debug Mode state (Phase 3 M3). dcsr's writable fields are stored
  // individually; the read value is composed below.
  logic       debug_mode_q;
  logic dcsr_ebreakm, dcsr_ebreaks, dcsr_ebreaku;
  logic            dcsr_step;
  logic [     2:0] dcsr_cause;
  logic [     1:0] dcsr_prv;
  logic [XLEN-1:0] dpc;
  logic [XLEN-1:0] dscratch0, dscratch1;
  logic [XLEN-1:0] dcsr;
  always_comb begin
    dcsr = '0;
    dcsr[31:28] = 4'd4;  // xdebugver: 0.13
    dcsr[riscv_pkg::DcsrEbreakMBit] = dcsr_ebreakm;
    dcsr[riscv_pkg::DcsrEbreakSBit] = dcsr_ebreaks;
    dcsr[riscv_pkg::DcsrEbreakUBit] = dcsr_ebreaku;
    dcsr[riscv_pkg::DcsrCauseLo+:3] = dcsr_cause;
    dcsr[4] = 1'b1;  // mprven
    dcsr[riscv_pkg::DcsrStepBit] = dcsr_step;
    dcsr[riscv_pkg::DcsrPrvLo+:2] = dcsr_prv;
  end
  assign o_debug_mode = debug_mode_q;
  assign o_dcsr_step = dcsr_step;
  assign o_dcsr_ebreak = {dcsr_ebreakm, dcsr_ebreaks, dcsr_ebreaku};
  assign o_dpc = dpc;
  logic [XLEN-1:0] mstatus;  // Constructed from the fields above
  logic [XLEN-1:0] sstatus;  // Restricted view of the same fields
  logic [    31:0] mstatus_low;
  // Low-word field map (bit 31 stays 0 here; SD is applied per-XLEN below).
  always_comb begin
    mstatus_low = '0;
    mstatus_low[riscv_pkg::MstatusSieBit] = mstatus_sie;
    mstatus_low[riscv_pkg::MstatusMieBit] = mstatus_mie;
    mstatus_low[riscv_pkg::MstatusSpieBit] = mstatus_spie;
    mstatus_low[riscv_pkg::MstatusMpieBit] = mstatus_mpie;
    mstatus_low[riscv_pkg::MstatusSppBit] = mstatus_spp;
    mstatus_low[14:13] = mstatus_fs;
    mstatus_low[12:11] = mstatus_mpp;
    mstatus_low[riscv_pkg::MstatusMprvBit] = mstatus_mprv;
    mstatus_low[riscv_pkg::MstatusSumBit] = mstatus_sum;
    mstatus_low[riscv_pkg::MstatusMxrBit] = mstatus_mxr;
    mstatus_low[riscv_pkg::MstatusTvmBit] = mstatus_tvm;
    mstatus_low[riscv_pkg::MstatusTwBit] = mstatus_tw;
    mstatus_low[riscv_pkg::MstatusTsrBit] = mstatus_tsr;
  end
  // SD (FS==Dirty mirror, D15) at 63, SXL/UXL hardwired to 2 (64-bit) at
  // [35:34]/[33:32]; the low word keeps the base field map with bit 31
  // reserved-0.
  assign mstatus = {fs_dirty, 27'b0, 2'd2, 2'd2, mstatus_low};
  // sstatus view: SD, UXL, MXR, SUM, FS, SPP, SPIE, SIE (UBE/VS/XS zero).
  logic [31:0] sstatus_low;
  always_comb begin
    sstatus_low = '0;
    sstatus_low[riscv_pkg::MstatusSieBit] = mstatus_sie;
    sstatus_low[riscv_pkg::MstatusSpieBit] = mstatus_spie;
    sstatus_low[riscv_pkg::MstatusSppBit] = mstatus_spp;
    sstatus_low[14:13] = mstatus_fs;
    sstatus_low[riscv_pkg::MstatusSumBit] = mstatus_sum;
    sstatus_low[riscv_pkg::MstatusMxrBit] = mstatus_mxr;
  end
  assign sstatus = {fs_dirty, 29'b0, 2'd2, sstatus_low};
  assign o_priv = priv_q;
  assign o_mstatus_fs_off = (mstatus_fs == FsOff);
  assign o_sstatus_sie_direct = mstatus_sie;
  // Pre-composed allocation-legality exports (see the port comment):
  // single-LUT functions of registered state, quasi-static between
  // serialized CSR writes / xRETs.
  logic gate_priv_is_u, gate_priv_is_s;
  assign gate_priv_is_u = (priv_q == riscv_pkg::PrivU);
  assign gate_priv_is_s = (priv_q == riscv_pkg::PrivS);
  assign o_priv_is_u = gate_priv_is_u;
  assign o_sret_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tsr);
  assign o_sfence_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tvm);
  assign o_wfi_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tw);

  // mie CSR: store each interrupt enable as separate register.
  // The supervisor enables exist regardless of delegation (an undelegated
  // supervisor-class interrupt is a machine-target interrupt); mideleg only
  // gates their VISIBILITY through the sie view.
  logic mie_msie;  // Machine Software Interrupt Enable (bit 3)
  logic mie_mtie;  // Machine Timer Interrupt Enable (bit 7)
  logic mie_meie;  // Machine External Interrupt Enable (bit 11)
  logic mie_ssie;  // Supervisor Software Interrupt Enable (bit 1)
  logic mie_stie;  // Supervisor Timer Interrupt Enable (bit 5)
  logic mie_seie;  // Supervisor External Interrupt Enable (bit 9)
  logic [XLEN-1:0] mie;  // Constructed from individual enables
  assign mie = XLEN'({
    20'b0,
    mie_meie,
    1'b0,
    mie_seie,
    1'b0,
    mie_mtie,
    1'b0,
    mie_stie,
    1'b0,
    mie_msie,
    1'b0,
    mie_ssie,
    1'b0
  });

  // Delegation registers (WARL to the package masks).
  logic [15:0] medeleg_q;
  logic mideleg_ssi, mideleg_sti, mideleg_sei;
  logic [XLEN-1:0] mideleg;
  assign mideleg = XLEN'({mideleg_sei, 3'b0, mideleg_sti, 3'b0, mideleg_ssi, 1'b0});
  assign o_medeleg = medeleg_q;
  assign o_mideleg_s = {mideleg_sei, mideleg_sti, mideleg_ssi};

  // sie view: supervisor enables where delegated; everything else reads 0.
  logic [XLEN-1:0] sie_view;
  always_comb begin
    sie_view = '0;
    sie_view[riscv_pkg::MieSsiBit] = mie_ssie && mideleg_ssi;
    sie_view[riscv_pkg::MieStiBit] = mie_stie && mideleg_sti;
    sie_view[riscv_pkg::MieSeiBit] = mie_seie && mideleg_sei;
  end

  // Next-state signals for mstatus bits (computed combinationally)
  logic next_mstatus_mie;
  logic next_mstatus_mpie;
  logic [1:0] next_mstatus_mpp;
  logic next_mstatus_mprv;
  logic [1:0] next_mstatus_fs;
  logic next_mstatus_sie;
  logic next_mstatus_spie;
  logic next_mstatus_spp;
  logic next_mstatus_sum;
  logic next_mstatus_mxr;
  logic next_mstatus_tvm;
  logic next_mstatus_tw;
  logic next_mstatus_tsr;
  logic [1:0] next_priv;
  // Next-state signals for mie bits
  logic next_mie_msie;
  logic next_mie_mtie;
  logic next_mie_meie;
  logic next_mie_ssie;
  logic next_mie_stie;
  logic next_mie_seie;

  logic [XLEN-1:0] mtvec;  // Trap vector base (MODE in bits [1:0], BASE in [31:2])
  // mcounteren: WARL — only the Zicntr enables CY/TM/IR are implemented (no
  // hpmcounters), so 3 bits of storage; the other 29 bits read as zero and
  // discard writes. Resets to 3'b111, a platform choice keeping
  // cycle/time/instret U-readable out of reset (Linux userspace reads them
  // directly and the no-MMU kernel never writes mcounteren).
  logic [2:0] mcounteren_q;
  assign o_mcounteren = mcounteren_q;
  logic [XLEN-1:0] mscratch;  // Scratch register for trap handlers
  logic [XLEN-1:0] mepc;  // Exception PC
  logic [XLEN-1:0] mcause;  // Trap cause
  logic [XLEN-1:0] mtval;  // Trap value
  logic [XLEN-1:0] perf_counter_select;
  logic perf_cache_previous_select;

  // Supervisor trap CSRs (Phase 3).
  logic [XLEN-1:0] stvec;  // Supervisor trap vector (MODE bit 1 forced 0, like mtvec)
  logic [2:0] scounteren_q;  // WARL CY/TM/IR like mcounteren; reset 0x7 (see header)
  assign o_scounteren = scounteren_q;
  // Counter-access block bits at the CURRENT privilege (see the port
  // comment), sampled when a ROB entry allocates. M is never blocked; S
  // needs mcounteren; U needs both.
  assign o_counter_blocked = gate_priv_is_u ? ~(mcounteren_q & scounteren_q) :
      gate_priv_is_s ? ~mcounteren_q : 3'b000;
  // Sstc: S-mode stimecmp access requires menvcfg.STCE (see the port
  // comment; race-free by the same allocation-serialization argument).
  assign o_stimecmp_blocked = gate_priv_is_s && !menvcfg_stce;
  logic [XLEN-1:0] sscratch;
  logic [XLEN-1:0] sepc;  // bit 0 forced 0, like mepc
  logic [XLEN-1:0] scause;
  logic [XLEN-1:0] stval;
  // satp: MODE is WARL over the supported set {Bare, Sv39}; ASID is
  // WARL-0; the PPN field stores all 44 written bits (WARL keep — the
  // translation logic consumes only the physically-reachable bits and
  // PMA-faults walks above them). A write carrying an unsupported MODE
  // leaves the whole register unchanged (privileged-spec satp rule).
  localparam bit SatpSv39Supported = 1'b1;
  localparam logic [3:0] SatpModeBare = 4'd0;
  localparam logic [3:0] SatpModeSv39 = 4'd8;
  // The full 44-bit PPN is stored (WARL keep-what-was-written — the most
  // Spike-compatible choice); the M4 translation logic consumes only the
  // bits the 32-bit physical map can reach and PMA-faults walks above it.
  localparam int unsigned SatpPpnBits = 44;
  logic satp_mode_sv39;  // 0 = Bare, 1 = Sv39
  logic [SatpPpnBits-1:0] satp_ppn;
  logic [XLEN-1:0] satp;
  assign satp = {
    satp_mode_sv39 ? SatpModeSv39 : SatpModeBare,  // MODE [63:60]
    16'b0,  // ASID [59:44] (WARL-0)
    satp_ppn  // PPN [43:0]
  };

  // mip: the machine bits are read-only reflections of the interrupt inputs;
  // the supervisor bits are software-writable state (SSIP/STIP/SEIP — the
  // M-mode injection path for supervisor interrupts pre-Sstc/PLIC; the PLIC
  // S-context line ORs into the SEIP readback at M6).
  logic mip_ssip, mip_stip, mip_seip;
  // Sstc (M6, D12): stimecmp + menvcfg.STCE. While STCE=1, STIP is the
  // REGISTERED mtime >= stimecmp compare in every consumer (mip/sip
  // readback and the trap-side S-pending export) and the software STIP
  // bit is dormant; with STCE=0 the pre-Sstc software-injection behavior
  // is unchanged. The compare is registered to keep the 64-bit magnitude
  // compare off the interrupt-arming cones.
  logic menvcfg_stce;
  logic [63:0] stimecmp;
  logic stimecmp_pending_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) stimecmp_pending_q <= 1'b0;
    else stimecmp_pending_q <= (i_mtime >= stimecmp);
  end
  logic stip_eff, seip_eff;
  assign stip_eff = menvcfg_stce ? stimecmp_pending_q : mip_stip;
  assign seip_eff = mip_seip || i_seip_line;
  logic [XLEN-1:0] mip;
  assign mip = XLEN'({
    20'b0,
    i_interrupts.meip,
    1'b0,
    seip_eff,
    1'b0,
    i_interrupts.mtip,
    1'b0,
    stip_eff,
    1'b0,
    i_interrupts.msip,
    1'b0,
    mip_ssip,
    1'b0
  });
  assign o_s_pending = {seip_eff, stip_eff, mip_ssip};

  // sip view: supervisor pending bits where delegated; everything else 0.
  logic [XLEN-1:0] sip_view;
  always_comb begin
    sip_view = '0;
    sip_view[riscv_pkg::MieSsiBit] = mip_ssip && mideleg_ssi;
    sip_view[riscv_pkg::MieStiBit] = stip_eff && mideleg_sti;
    sip_view[riscv_pkg::MieSeiBit] = seip_eff && mideleg_sei;
  end

  // misa is read-only: IMAFDC + B + S + U (= GCB with Supervisor and User
  // modes). Bit 0 (A), Bit 1 (B), Bit 2 (C), Bit 3 (D), Bit 5 (F),
  // Bit 8 (I), Bit 12 (M), Bit 18 (S), Bit 20 (U) = 0x0014_112F; MXL sits
  // in the top two bits (2 = 64-bit at [63:62]).
  localparam logic [XLEN-1:0] MisaValue = XLEN'(64'h8000_0000_0014_112F);

  // Output CSRs for trap unit
  assign o_mstatus = mstatus;
  assign o_mie = mie;
  assign o_mtvec = mtvec;
  logic mtvec_traps_misaligned_q;
  assign o_mtvec_traps_misaligned = mtvec_traps_misaligned_q;
  assign o_mepc = mepc;
  assign o_stvec = stvec;
  assign o_sepc = sepc;

  // Direct output of mstatus_mie register bypasses full-word CSR concatenation.
  assign o_mstatus_mie_direct = mstatus_mie;

  // ==========================================================================
  // CSR Write Data Calculation
  // ==========================================================================

  logic [XLEN-1:0] csr_current_value;
  logic [XLEN-1:0] csr_new_value;

  // Get current value of addressed CSR (for read-modify-write operations).
  // The view CSRs (sstatus/sie/sip) present their VIEW here so csrrs/csrrc
  // read-modify-write over exactly the architecturally visible bits.
  always_comb begin
    csr_current_value = '0;
    unique case (i_csr_address)
      // F extension CSRs
      riscv_pkg::CsrFflags: csr_current_value = XLEN'({27'b0, fflags});
      riscv_pkg::CsrFrm: csr_current_value = XLEN'({29'b0, frm});
      riscv_pkg::CsrFcsr: csr_current_value = fcsr;
      // Machine-mode CSRs
      riscv_pkg::CsrMstatus: csr_current_value = mstatus;
      riscv_pkg::CsrMedeleg: csr_current_value = XLEN'(medeleg_q);
      riscv_pkg::CsrMideleg: csr_current_value = mideleg;
      riscv_pkg::CsrMie: csr_current_value = mie;
      riscv_pkg::CsrMtvec: csr_current_value = mtvec;
      riscv_pkg::CsrMcounteren: csr_current_value = XLEN'({29'b0, mcounteren_q});
      riscv_pkg::CsrMscratch: csr_current_value = mscratch;
      riscv_pkg::CsrMepc: csr_current_value = mepc;
      riscv_pkg::CsrMcause: csr_current_value = mcause;
      riscv_pkg::CsrMtval: csr_current_value = mtval;
      riscv_pkg::CsrMip: csr_current_value = mip;
      // Supervisor CSRs (views and dedicated registers)
      riscv_pkg::CsrSstatus: csr_current_value = sstatus;
      riscv_pkg::CsrSie: csr_current_value = sie_view;
      riscv_pkg::CsrSip: csr_current_value = sip_view;
      riscv_pkg::CsrStvec: csr_current_value = stvec;
      riscv_pkg::CsrScounteren: csr_current_value = XLEN'({29'b0, scounteren_q});
      riscv_pkg::CsrSscratch: csr_current_value = sscratch;
      riscv_pkg::CsrSepc: csr_current_value = sepc;
      riscv_pkg::CsrScause: csr_current_value = scause;
      riscv_pkg::CsrStval: csr_current_value = stval;
      riscv_pkg::CsrSatp: csr_current_value = satp;
      riscv_pkg::CsrMenvcfg: csr_current_value = XLEN'(menvcfg_stce) << riscv_pkg::MenvcfgStceBit;
      riscv_pkg::CsrStimecmp: csr_current_value = stimecmp;
      riscv_pkg::CsrMperfSel: csr_current_value = perf_counter_select;
      // Debug Mode CSRs (Phase 3 M3)
      riscv_pkg::CsrDcsr: csr_current_value = dcsr;
      riscv_pkg::CsrDpc: csr_current_value = dpc;
      riscv_pkg::CsrDscratch0: csr_current_value = dscratch0;
      riscv_pkg::CsrDscratch1: csr_current_value = dscratch1;
      riscv_pkg::CsrDdata: csr_current_value = XLEN'(i_dbg_data);
      default: csr_current_value = '0;
    endcase
  end

  // Calculate new value based on CSR operation.
  //
  // mip RMW base (priv spec, the mip.SEIP note; M6): the read value of
  // SEIP/STIP is composed with the PLIC S-context line / the Sstc compare,
  // but the value used in a CSRRS/CSRRC read-modify-write is the SOFTWARE
  // bit alone — otherwise a set/clear (or a csrr's suppressed-write shape)
  // captures the transient line into the software-injection bit and it
  // sticks after the line drops (plic_test's H seip-drops case).
  logic [XLEN-1:0] csr_rmw_base;
  always_comb begin
    csr_rmw_base = csr_current_value;
    if (i_csr_address == riscv_pkg::CsrMip) begin
      csr_rmw_base[riscv_pkg::MieSeiBit] = mip_seip;
      csr_rmw_base[riscv_pkg::MieStiBit] = mip_stip;
    end
  end
  always_comb begin
    csr_new_value = csr_current_value;
    unique case (i_csr_op)
      riscv_pkg::CSR_RW, riscv_pkg::CSR_RWI: csr_new_value = i_csr_write_data;
      riscv_pkg::CSR_RS, riscv_pkg::CSR_RSI: csr_new_value = csr_rmw_base | i_csr_write_data;
      riscv_pkg::CSR_RC, riscv_pkg::CSR_RCI: csr_new_value = csr_rmw_base & ~i_csr_write_data;
      default:                               csr_new_value = csr_current_value;
    endcase
  end

  // ==========================================================================
  // Cycle Counter
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_counter <= 64'd0;
    end else begin
      cycle_counter <= cycle_counter + 64'd1;
    end
  end

  // ==========================================================================
  // Instructions Retired Counter
  // ==========================================================================
  // TIMING RETIME (+1 cycle, architecturally invisible — analysis below):
  // the per-cycle retire count arrives late (its !trap_taken suppression sits
  // at the end of the commit/trap serialization cone) and previously entered
  // the LSB of a 64-bit carry chain, making instret[63]/D the post-opt WNS
  // (-0.94 ns at 300 MHz).  Stage the FULLY-GATED count through
  // instruction_retired_count_q so the late cone terminates at a 2-bit
  // register; the 64-bit add then runs register-to-register.
  //
  // Invariant: instret_counter at cycle T equals the total retire count
  // through cycle T-2 (one staging cycle) instead of T-1.  Architecturally
  // invisible because the ONLY observation of instret is a CSR read of
  // instret/instreth/minstret{,h}, and CSR reads are commit-serialized:
  //   cycle C:   the youngest instruction OLDER than the CSR read commits
  //              (commit_en); its count is computed at C+1 from the
  //              REGISTERED commit bus (commit_actions), staged into
  //              instruction_retired_count_q at the C+1->C+2 edge, and
  //              accumulated into instret_counter at the C+2->C+3 edge;
  //   cycle C+1: the CSR reaches the ROB head; rob_serializer asserts
  //              commit_stall and requests CSR execution (o_csr_start);
  //   cycle C+2: earliest csr_done_ack (1-cycle handshake in cpu_ooo) ->
  //              earliest CSR commit_en;
  //   cycle C+3: csr_commit_fire (registered commit) performs the actual
  //              csr_file read -> observes a counter that already includes
  //              cycle C's commits.
  // Every stall (head not ready, commit_hold, later csr_done) only adds
  // margin, and the reading instruction itself is never included — exactly
  // as in the un-retimed design, whose own count also landed after the read.
  // The staged count preserves the !trap_taken suppression bit-for-bit (the
  // gated count is registered as-is: the same instructions are counted, one
  // cycle later).  Proven in the FORMAL section (p_instret_stage_follows /
  // p_instret_applies_staged_count).
  logic [1:0] instruction_retired_count_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      instruction_retired_count_q <= 2'd0;
      instret_counter <= 64'd0;
    end else begin
      instruction_retired_count_q <= i_instruction_retired_count;
      instret_counter <= instret_counter + 64'(instruction_retired_count_q);
    end
  end

  // ==========================================================================
  // F Extension CSR Updates (fflags, frm)
  // ==========================================================================
  // fflags is sticky: new exception flags are ORed with existing flags.
  // CSR writes can clear flags explicitly.
  //
  // Pipeline hazard: When fsflags/csrrw writes to fflags and its read used
  // forwarded FP flags, that same FP instruction may still advance into the
  // WB path on the next cycle. Suppress only that forwarded replay; OOO commit
  // may retire a distinct younger FP instruction in the following cycle.

  logic fflags_suppress_forwarded_wb;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fflags_suppress_forwarded_wb <= 1'b0;
    end else begin
      fflags_suppress_forwarded_wb <= i_csr_write_enable && i_csr_read_enable &&
                                      (i_csr_address == riscv_pkg::CsrFflags ||
                                       i_csr_address == riscv_pkg::CsrFcsr) &&
                                      (i_fp_flags_ma_valid || i_fp_flags_wb_valid);
    end
  end

  // Effective FP flags valid: suppress accumulation for one cycle after CSR
  // write to fflags/fcsr only if the CSR read actually forwarded pending flags.
  logic fp_flags_valid_eff;
  assign fp_flags_valid_eff = i_fp_flags_valid && ~fflags_suppress_forwarded_wb;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      fflags <= 5'b0;
      frm    <= 3'b0;  // Default: RNE (round to nearest, ties to even)
    end else begin
      // Priority: CSR write > FP flag accumulation
      if (i_csr_write_enable && i_csr_read_enable) begin
        unique case (i_csr_address)
          riscv_pkg::CsrFflags: fflags <= csr_new_value[4:0];
          riscv_pkg::CsrFrm:    frm <= csr_new_value[2:0];
          riscv_pkg::CsrFcsr: begin
            fflags <= csr_new_value[4:0];
            frm    <= csr_new_value[7:5];
          end
          default: begin
            // No CSR write to FP CSRs, accumulate flags if valid
            if (fp_flags_valid_eff) begin
              fflags <= fflags | {i_fp_flags.nv, i_fp_flags.dz,
                                  i_fp_flags.of, i_fp_flags.uf, i_fp_flags.nx};
            end
          end
        endcase
      end else if (fp_flags_valid_eff) begin
        // Accumulate FP exception flags (sticky OR)
        fflags <= fflags | {i_fp_flags.nv, i_fp_flags.dz,
                            i_fp_flags.of, i_fp_flags.uf, i_fp_flags.nx};
      end
    end
  end

  // ==========================================================================
  // Machine-Mode CSR Updates - Next-State Logic
  // ==========================================================================

  // Compute next-state values for mstatus/mie bits in a combinational block.
  // Keep the next-state logic explicit and easy for synthesis/formal tools.
  // The always block below just registers these values unconditionally.
  // Note: old-style sensitivity keeps this block accepted by all supported tools.

  always_comb begin
    // Default: keep current values
    next_mstatus_mie = mstatus_mie;
    next_mstatus_mpie = mstatus_mpie;
    next_mstatus_mpp = mstatus_mpp;
    next_mstatus_mprv = mstatus_mprv;
    next_mstatus_fs = mstatus_fs;
    next_mstatus_sie = mstatus_sie;
    next_mstatus_spie = mstatus_spie;
    next_mstatus_spp = mstatus_spp;
    next_mstatus_sum = mstatus_sum;
    next_mstatus_mxr = mstatus_mxr;
    next_mstatus_tvm = mstatus_tvm;
    next_mstatus_tw = mstatus_tw;
    next_mstatus_tsr = mstatus_tsr;
    next_priv = priv_q;
    next_mie_msie = mie_msie;
    next_mie_mtie = mie_mtie;
    next_mie_meie = mie_meie;
    next_mie_ssie = mie_ssie;
    next_mie_stie = mie_stie;
    next_mie_seie = mie_seie;

    if (i_trap_taken && i_trap_to_d) begin
      // Debug Mode entry (Phase 3 M3): the hart runs with M privilege; the
      // M/S trap stacks are untouched (dpc/dcsr record the resume state).
      next_priv = riscv_pkg::PrivM;
    end else if (i_trap_taken) begin
      // FS is untouched by either target: the trap-time image is exactly
      // what the OS reads to decide whether FP state needs saving (D15).
      if (i_trap_to_s) begin
        // Delegated trap entry: save SIE->SPIE, clear SIE, save priv->SPP,
        // enter S-mode. The trap unit only asserts i_trap_to_s from
        // priv <= S (delegation never applies to M-mode traps), so SPP's
        // 1-bit encoding (0=U, 1=S) covers every reachable priv.
        next_mstatus_spie = mstatus_sie;
        next_mstatus_sie  = 1'b0;
        next_mstatus_spp  = (priv_q == riscv_pkg::PrivS);
        next_priv         = riscv_pkg::PrivS;
      end else begin
        // Machine trap entry: save MIE->MPIE, clear MIE, save priv->MPP
        // (which now records S as well), enter M-mode.
        next_mstatus_mpie = mstatus_mie;
        next_mstatus_mie  = 1'b0;
        next_mstatus_mpp  = priv_q;
        next_priv         = riscv_pkg::PrivM;
      end
    end else if (i_mret_taken) begin
      // MRET: restore MIE<-MPIE, MPIE=1, return to MPP's privilege, set MPP=U,
      // and clear MPRV if returning below M (per the privileged spec).
      next_mstatus_mie  = mstatus_mpie;
      next_mstatus_mpie = 1'b1;
      next_priv         = mstatus_mpp;
      if (mstatus_mpp != riscv_pkg::PrivM) next_mstatus_mprv = 1'b0;
      next_mstatus_mpp = riscv_pkg::PrivU;
    end else if (i_sret_taken) begin
      // SRET: restore SIE<-SPIE, SPIE=1, return to SPP's privilege, set
      // SPP=U. SRET always lands at or below S, so MPRV clears
      // unconditionally (per the privileged spec's xRET rule).
      next_mstatus_sie  = mstatus_spie;
      next_mstatus_spie = 1'b1;
      next_priv         = mstatus_spp ? riscv_pkg::PrivS : riscv_pkg::PrivU;
      next_mstatus_spp  = 1'b0;
      next_mstatus_mprv = 1'b0;
    end else if (i_dret_taken) begin
      // DRET: return to dcsr.prv; MPRV clears when leaving M (Spike's dret).
      next_priv = dcsr_prv;
      if (dcsr_prv != riscv_pkg::PrivM) next_mstatus_mprv = 1'b0;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      if (i_csr_address == riscv_pkg::CsrMstatus) begin
        next_mstatus_sie = csr_new_value[riscv_pkg::MstatusSieBit];
        next_mstatus_mie = csr_new_value[3];
        next_mstatus_spie = csr_new_value[riscv_pkg::MstatusSpieBit];
        next_mstatus_mpie = csr_new_value[7];
        next_mstatus_spp = csr_new_value[riscv_pkg::MstatusSppBit];
        // MPP is WARL over {U, S, M}: the reserved encoding 2'b10 folds to
        // U (matches the pinned Spike's legalization).
        next_mstatus_mpp = (csr_new_value[12:11] == 2'b10) ? riscv_pkg::PrivU
                                                           : csr_new_value[12:11];
        next_mstatus_mprv = csr_new_value[riscv_pkg::MstatusMprvBit];
        next_mstatus_sum = csr_new_value[riscv_pkg::MstatusSumBit];
        next_mstatus_mxr = csr_new_value[riscv_pkg::MstatusMxrBit];
        next_mstatus_tvm = csr_new_value[riscv_pkg::MstatusTvmBit];
        next_mstatus_tw = csr_new_value[riscv_pkg::MstatusTwBit];
        next_mstatus_tsr = csr_new_value[riscv_pkg::MstatusTsrBit];
        // FS is WARL with all four values storable (Off/Initial/Clean/Dirty).
        next_mstatus_fs = csr_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrSstatus) begin
        // sstatus view write: only the S-visible fields move; the machine
        // fields are untouched by construction.
        next_mstatus_sie  = csr_new_value[riscv_pkg::MstatusSieBit];
        next_mstatus_spie = csr_new_value[riscv_pkg::MstatusSpieBit];
        next_mstatus_spp  = csr_new_value[riscv_pkg::MstatusSppBit];
        next_mstatus_sum  = csr_new_value[riscv_pkg::MstatusSumBit];
        next_mstatus_mxr  = csr_new_value[riscv_pkg::MstatusMxrBit];
        next_mstatus_fs   = csr_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrMie) begin
        next_mie_ssie = csr_new_value[riscv_pkg::MieSsiBit];
        next_mie_msie = csr_new_value[3];
        next_mie_stie = csr_new_value[riscv_pkg::MieStiBit];
        next_mie_mtie = csr_new_value[7];
        next_mie_seie = csr_new_value[riscv_pkg::MieSeiBit];
        next_mie_meie = csr_new_value[11];
      end else if (i_csr_address == riscv_pkg::CsrSie) begin
        // sie view write: delegated bits write through to the mie storage;
        // non-delegated bits are read-only-zero in the view and discard
        // writes (csr_new_value was computed over the masked view, so a
        // set/clear op cannot leak a non-delegated enable through either).
        if (mideleg_ssi) next_mie_ssie = csr_new_value[riscv_pkg::MieSsiBit];
        if (mideleg_sti) next_mie_stie = csr_new_value[riscv_pkg::MieStiBit];
        if (mideleg_sei) next_mie_seie = csr_new_value[riscv_pkg::MieSeiBit];
      end
    end

    // D15 hardware Dirty-setting: any FP architectural-state write. Fires
    // on (a) a committing FP-regfile dest write (i_fp_dest_write, covers FP
    // loads and f-dest computes), (b) a committing flag-producing FP op
    // (i_fp_flags_valid, covers x-dest computes like FCMP/FCVT), (c) a CSR
    // write to fflags/frm/fcsr. Mutually exclusive with an explicit mstatus
    // write in the same cycle (CSR ops are head-serialized and are not FP
    // ops), and impossible while FS==Off (the ROB gate traps FP ops and FP
    // CSR accesses before they commit), so plain priority-after-write is
    // safe. Pessimistic Dirty (e.g. on a flag op that raises no flags) is
    // architecturally permitted.
    if ((i_csr_write_enable && i_csr_read_enable &&
         (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFrm ||
          i_csr_address == riscv_pkg::CsrFcsr)) ||
        i_fp_dest_write || i_fp_flags_valid) begin
      next_mstatus_fs = FsDirty;
    end
  end

  // Simple flip-flops for mstatus/mie bits.
  // Note: old-style always is used here because this block predates the OOO refactor.
  always @(posedge i_clk) begin
    if (i_rst) begin
      mstatus_mie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_mpp <= riscv_pkg::PrivU;
      mstatus_mprv <= 1'b0;
      // D15: reset to Initial (not Off) so FP executes without any OS/crt0
      // FS enable — matches pre-D15 boot behavior for all existing software.
      mstatus_fs <= FsInitial;
      mstatus_sie <= 1'b0;
      mstatus_spie <= 1'b0;
      mstatus_spp <= 1'b0;
      mstatus_sum <= 1'b0;
      mstatus_mxr <= 1'b0;
      mstatus_tvm <= 1'b0;
      mstatus_tw <= 1'b0;
      mstatus_tsr <= 1'b0;
      priv_q <= riscv_pkg::PrivM;
      mie_msie <= 1'b0;
      mie_mtie <= 1'b0;
      mie_meie <= 1'b0;
      mie_ssie <= 1'b0;
      mie_stie <= 1'b0;
      mie_seie <= 1'b0;
    end else begin
      mstatus_mie <= next_mstatus_mie;
      mstatus_mpie <= next_mstatus_mpie;
      mstatus_mpp <= next_mstatus_mpp;
      mstatus_mprv <= next_mstatus_mprv;
      mstatus_fs <= next_mstatus_fs;
      mstatus_sie <= next_mstatus_sie;
      mstatus_spie <= next_mstatus_spie;
      mstatus_spp <= next_mstatus_spp;
      mstatus_sum <= next_mstatus_sum;
      mstatus_mxr <= next_mstatus_mxr;
      mstatus_tvm <= next_mstatus_tvm;
      mstatus_tw <= next_mstatus_tw;
      mstatus_tsr <= next_mstatus_tsr;
      priv_q <= next_priv;
      mie_msie <= next_mie_msie;
      mie_mtie <= next_mie_mtie;
      mie_meie <= next_mie_meie;
      mie_ssie <= next_mie_ssie;
      mie_stie <= next_mie_stie;
      mie_seie <= next_mie_seie;
    end
  end

  // ==========================================================================
  // Other Machine-Mode CSR Updates
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mtvec                      <= '0;
      mtvec_traps_misaligned_q   <= 1'b0;
      mcounteren_q               <= 3'b111;
      mscratch                   <= '0;
      mepc                       <= '0;
      mcause                     <= '0;
      mtval                      <= '0;
      stvec                      <= '0;
      scounteren_q               <= 3'b111;
      sscratch                   <= '0;
      sepc                       <= '0;
      scause                     <= '0;
      stval                      <= '0;
      medeleg_q                  <= '0;
      mideleg_ssi                <= 1'b0;
      mideleg_sti                <= 1'b0;
      mideleg_sei                <= 1'b0;
      mip_ssip                   <= 1'b0;
      mip_stip                   <= 1'b0;
      mip_seip                   <= 1'b0;
      satp_mode_sv39             <= 1'b0;
      satp_ppn                   <= '0;
      menvcfg_stce               <= 1'b0;
      stimecmp                   <= 64'hFFFF_FFFF_FFFF_FFFF;
      perf_counter_select        <= '0;
      perf_cache_previous_select <= 1'b0;
    end else if (i_trap_taken && !i_trap_to_d) begin
      // Trap entry: save state on the target-mode side only (a Debug Mode
      // entry saves dpc/dcsr instead — see the debug block below).
      if (i_trap_to_s) begin
        sepc   <= i_trap_pc;
        scause <= i_trap_cause;
        stval  <= i_trap_value;
      end else begin
        mepc   <= i_trap_pc;
        mcause <= i_trap_cause;
        mtval  <= i_trap_value;
      end
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrMtvec: begin
          mtvec                    <= {csr_new_value[XLEN-1:2], 1'b0, csr_new_value[0]};
          mtvec_traps_misaligned_q <= |csr_new_value[XLEN-1:2];
        end
        riscv_pkg::CsrMcounteren: mcounteren_q <= csr_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrMscratch: mscratch <= csr_new_value;
        riscv_pkg::CsrMepc: mepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C ext
        riscv_pkg::CsrMcause: mcause <= csr_new_value;
        riscv_pkg::CsrMtval: mtval <= csr_new_value;
        riscv_pkg::CsrMedeleg: medeleg_q <= csr_new_value[15:0] & riscv_pkg::MedelegMask[15:0];
        riscv_pkg::CsrMideleg: begin
          mideleg_ssi <= csr_new_value[riscv_pkg::MieSsiBit];
          mideleg_sti <= csr_new_value[riscv_pkg::MieStiBit];
          mideleg_sei <= csr_new_value[riscv_pkg::MieSeiBit];
        end
        // mip: the machine bits are read-only (input reflections); the
        // supervisor pending bits are the M-mode software-injection state.
        riscv_pkg::CsrMip: begin
          mip_ssip <= csr_new_value[riscv_pkg::MieSsiBit];
          mip_stip <= csr_new_value[riscv_pkg::MieStiBit];
          mip_seip <= csr_new_value[riscv_pkg::MieSeiBit];
        end
        // sip: SSIP is the only S-writable pending bit, and only where
        // delegated (the RMW base was the masked view, so set/clear forms
        // cannot leak through a non-delegated bit either).
        riscv_pkg::CsrSip: begin
          if (mideleg_ssi) mip_ssip <= csr_new_value[riscv_pkg::MieSsiBit];
        end
        riscv_pkg::CsrStvec: stvec <= {csr_new_value[XLEN-1:2], 1'b0, csr_new_value[0]};
        riscv_pkg::CsrScounteren: scounteren_q <= csr_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrSscratch: sscratch <= csr_new_value;
        riscv_pkg::CsrSepc: sepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C
        riscv_pkg::CsrScause: scause <= csr_new_value;
        riscv_pkg::CsrStval: stval <= csr_new_value;
        // satp: a write carrying an unsupported MODE leaves the whole
        // register unchanged (privileged-spec rule). ASID is WARL-0; the
        // PPN field stores all written bits.
        riscv_pkg::CsrSatp: begin
          if (csr_new_value[63:60] == SatpModeBare) begin
            satp_mode_sv39 <= 1'b0;
            satp_ppn <= csr_new_value[SatpPpnBits-1:0];
          end else if (SatpSv39Supported && (csr_new_value[63:60] == SatpModeSv39)) begin
            satp_mode_sv39 <= 1'b1;
            satp_ppn <= csr_new_value[SatpPpnBits-1:0];
          end
        end
        // Sstc (M6): menvcfg implements STCE only (the rest stays WARL-0);
        // stimecmp is the full 64-bit compare value.
        riscv_pkg::CsrMenvcfg: menvcfg_stce <= csr_new_value[riscv_pkg::MenvcfgStceBit];
        riscv_pkg::CsrStimecmp: stimecmp <= csr_new_value;
        riscv_pkg::CsrMperfSel: perf_counter_select <= csr_new_value;
        riscv_pkg::CsrMperfCtl: perf_cache_previous_select <= csr_new_value[1];
        default: ;
      endcase
    end
  end

  // ==========================================================================
  // Debug Mode registers (Phase 3 M3)
  // ==========================================================================
  // Entry records the resume state; DRET clears the mode; committed CSR
  // writes (only reachable in Debug Mode — enforced by ROB allocation
  // legality) install the writable dcsr fields, dpc and the scratch
  // registers. dcsr.prv is WARL
  // over {U, S, M} (2'b10 folds to U, like MPP).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      debug_mode_q <= 1'b0;
      dcsr_ebreakm <= 1'b0;
      dcsr_ebreaks <= 1'b0;
      dcsr_ebreaku <= 1'b0;
      dcsr_step    <= 1'b0;
      dcsr_cause   <= 3'd0;
      dcsr_prv     <= riscv_pkg::PrivM;
      dpc          <= '0;
      dscratch0    <= '0;
      dscratch1    <= '0;
    end else if (i_trap_taken && i_trap_to_d) begin
      debug_mode_q <= 1'b1;
      dpc          <= {i_trap_pc[XLEN-1:1], 1'b0};
      dcsr_cause   <= i_trap_dbg_cause;
      dcsr_prv     <= priv_q;
    end else if (i_dret_taken) begin
      debug_mode_q <= 1'b0;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrDcsr: begin
          dcsr_ebreakm <= csr_new_value[riscv_pkg::DcsrEbreakMBit];
          dcsr_ebreaks <= csr_new_value[riscv_pkg::DcsrEbreakSBit];
          dcsr_ebreaku <= csr_new_value[riscv_pkg::DcsrEbreakUBit];
          dcsr_step    <= csr_new_value[riscv_pkg::DcsrStepBit];
          dcsr_prv     <= (csr_new_value[1:0] == 2'b10) ? riscv_pkg::PrivU : csr_new_value[1:0];
        end
        riscv_pkg::CsrDpc: dpc <= {csr_new_value[XLEN-1:1], 1'b0};
        riscv_pkg::CsrDscratch0: dscratch0 <= csr_new_value;
        riscv_pkg::CsrDscratch1: dscratch1 <= csr_new_value;
        default: ;
      endcase
    end
  end
  // ddata: the write lands in the debug module's data0/data1 storage.
  assign o_dbg_data_we = i_csr_write_enable && i_csr_read_enable &&
      (i_csr_address == riscv_pkg::CsrDdata);
  assign o_dbg_data_wdata = csr_new_value[63:0];

  // Plan D10: post-commit invalidate request for translation-relevant CSRs.
  // Every enabled satp commit-port access invalidates conservatively,
  // including architecturally non-writing set/clear-zero and Bare-to-Bare
  // no-ops. An mstatus/sstatus commit invalidates only when its computed result
  // CHANGES SUM/MXR/MPRV — or MPP while MPRV is set (MPRV=1 makes MPP part of
  // the effective data privilege). The registered pulse aligns with the cycle
  // after the commit-port access, where the TLB/PTW consumer samples it. The
  // serializer independently owns conservative pipeline recovery.
  logic csr_translation_flush_req_d;
  assign csr_translation_flush_req_d = i_csr_write_enable && i_csr_read_enable &&
      ((i_csr_address == riscv_pkg::CsrSatp) ||
       (((i_csr_address == riscv_pkg::CsrMstatus) ||
         (i_csr_address == riscv_pkg::CsrSstatus)) &&
        ((next_mstatus_sum != mstatus_sum) ||
         (next_mstatus_mxr != mstatus_mxr) ||
         (next_mstatus_mprv != mstatus_mprv) ||
         (mstatus_mprv && (next_mstatus_mpp != mstatus_mpp)))));

  logic csr_translation_flush_req_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      csr_translation_flush_req_q <= 1'b0;
    end else begin
      csr_translation_flush_req_q <= csr_translation_flush_req_d;
    end
  end
  assign o_csr_translation_flush_req = csr_translation_flush_req_q;

  // The M4 translation-state bundle (see the port comment for the
  // coherence argument). Effective data privilege honors MPRV.
  logic [1:0] eff_data_priv;
  assign eff_data_priv = mstatus_mprv ? mstatus_mpp : priv_q;

  logic translation_active_q, mmu_sum_q, mmu_mxr_q, mmu_eff_priv_u_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      translation_active_q <= 1'b0;
      mmu_sum_q <= 1'b0;
      mmu_mxr_q <= 1'b0;
      mmu_eff_priv_u_q <= 1'b0;
    end else begin
      translation_active_q <= satp_mode_sv39 && (eff_data_priv != riscv_pkg::PrivM);
      mmu_sum_q <= mstatus_sum;
      mmu_mxr_q <= mstatus_mxr;
      mmu_eff_priv_u_q <= (eff_data_priv == riscv_pkg::PrivU);
    end
  end
  assign o_translation_active = translation_active_q;
  assign o_mmu_sum = mmu_sum_q;
  assign o_mmu_mxr = mmu_mxr_q;
  assign o_mmu_eff_priv_u = mmu_eff_priv_u_q;
  // Fetch side: straight off the registers (see the port comment).
  assign o_fetch_translation_active = satp_mode_sv39 && (priv_q != riscv_pkg::PrivM);
  assign o_fetch_priv_u = (priv_q == riscv_pkg::PrivU);
  assign o_satp_root_ppn = satp_ppn;

  // ==========================================================================
  // CSR Read Multiplexer
  // ==========================================================================
  // For fflags and fcsr reads, forward pending FP flags when an FP instruction
  // commits in the same cycle. This handles the case where the CSR read and
  // flag accumulation happen in the same cycle - the read should include the
  // flags being accumulated, not just the old registered value.
  //
  // TIMING OPTIMIZATION: CSR read data is registered to break the timing path
  // from instruction decode through CSR address decode to ALU result.
  // This adds one cycle of latency to CSR reads but significantly improves timing.

  // Compute forwarded fflags value (current OR flags being accumulated this cycle).
  // In cpu_ooo both i_fp_flags_valid and i_fp_flags_wb_valid are driven by the same
  // ROB-commit signal, so this forwards the flags of the FP instruction(s) committing
  // in the same cycle as the CSR read. The MA-stage inputs are tied off there, so the
  // MA term reduces to zero.
  logic [4:0] fflags_forwarded;
  logic [4:0] ma_flags_packed;
  logic [4:0] wb_flags_packed;
  assign ma_flags_packed = {
    i_fp_flags_ma.nv, i_fp_flags_ma.dz, i_fp_flags_ma.of, i_fp_flags_ma.uf, i_fp_flags_ma.nx
  };
  assign wb_flags_packed = {
    i_fp_flags.nv, i_fp_flags.dz, i_fp_flags.of, i_fp_flags.uf, i_fp_flags.nx
  };
  assign fflags_forwarded = fflags |
      (i_fp_flags_ma_valid ? ma_flags_packed : 5'b0) |
      (i_fp_flags_wb_valid ? wb_flags_packed : 5'b0);

  // Combinational CSR read data (before registering)
  logic [XLEN-1:0] csr_read_data_comb;

  always_comb begin
    csr_read_data_comb = '0;  // Default: return 0 for non-implemented CSRs

    if (i_csr_read_enable) begin
      unique case (i_csr_address)
        // F extension CSRs (with forwarding for pending flags)
        riscv_pkg::CsrFflags: csr_read_data_comb = XLEN'({27'b0, fflags_forwarded});
        riscv_pkg::CsrFrm: csr_read_data_comb = XLEN'({29'b0, frm});
        riscv_pkg::CsrFcsr: csr_read_data_comb = XLEN'({24'b0, frm, fflags_forwarded});
        // Zicntr counters (read-only, user-mode and machine-mode aliases):
        // single 64-bit CSRs. The RV32 high-half addresses (cycleh &c.)
        // are captured as illegal-instruction at ROB allocation.
        riscv_pkg::CsrCycle, riscv_pkg::CsrMcycle:
        csr_read_data_comb = XLEN'(cycle_counter[XLEN-1:0]);
        riscv_pkg::CsrTime: csr_read_data_comb = XLEN'(i_mtime[XLEN-1:0]);
        riscv_pkg::CsrInstret, riscv_pkg::CsrMinstret:
        csr_read_data_comb = XLEN'(instret_counter[XLEN-1:0]);
        // Machine-mode CSRs
        riscv_pkg::CsrMstatus: csr_read_data_comb = mstatus;
        riscv_pkg::CsrMisa: csr_read_data_comb = MisaValue;
        riscv_pkg::CsrMedeleg: csr_read_data_comb = XLEN'(medeleg_q);
        riscv_pkg::CsrMideleg: csr_read_data_comb = mideleg;
        riscv_pkg::CsrMie: csr_read_data_comb = mie;
        riscv_pkg::CsrMtvec: csr_read_data_comb = mtvec;
        riscv_pkg::CsrMcounteren: csr_read_data_comb = XLEN'({29'b0, mcounteren_q});
        riscv_pkg::CsrMscratch: csr_read_data_comb = mscratch;
        riscv_pkg::CsrMepc: csr_read_data_comb = mepc;
        riscv_pkg::CsrMcause: csr_read_data_comb = mcause;
        riscv_pkg::CsrMtval: csr_read_data_comb = mtval;
        riscv_pkg::CsrMip: csr_read_data_comb = mip;
        // Supervisor CSRs (views and dedicated registers)
        riscv_pkg::CsrSstatus: csr_read_data_comb = sstatus;
        riscv_pkg::CsrSie: csr_read_data_comb = sie_view;
        riscv_pkg::CsrSip: csr_read_data_comb = sip_view;
        riscv_pkg::CsrStvec: csr_read_data_comb = stvec;
        riscv_pkg::CsrScounteren: csr_read_data_comb = XLEN'({29'b0, scounteren_q});
        riscv_pkg::CsrSscratch: csr_read_data_comb = sscratch;
        riscv_pkg::CsrSepc: csr_read_data_comb = sepc;
        riscv_pkg::CsrScause: csr_read_data_comb = scause;
        riscv_pkg::CsrStval: csr_read_data_comb = stval;
        riscv_pkg::CsrSatp: csr_read_data_comb = satp;
        riscv_pkg::CsrMenvcfg:
        csr_read_data_comb = XLEN'(menvcfg_stce) << riscv_pkg::MenvcfgStceBit;
        riscv_pkg::CsrStimecmp: csr_read_data_comb = stimecmp;
        // menvcfg/senvcfg exist (S/U make them mandatory) with no
        // implemented fields: RAZ/WI via the default arm.
        riscv_pkg::CsrMperfSel: csr_read_data_comb = perf_counter_select;
        riscv_pkg::CsrMperfCtl: csr_read_data_comb = '0;
        // Custom profiling CSRs stay split 32-bit halves even at rv64
        // (host-side tooling reads them pairwise); zero-extend to the bus.
        riscv_pkg::CsrMperfData: csr_read_data_comb = XLEN'(i_perf_counter_data[31:0]);
        riscv_pkg::CsrMperfDataH: csr_read_data_comb = XLEN'(i_perf_counter_data[63:32]);
        riscv_pkg::CsrMperfCount: csr_read_data_comb = XLEN'(i_perf_counter_count);
        // Debug Mode CSRs (Phase 3 M3)
        riscv_pkg::CsrDcsr: csr_read_data_comb = dcsr;
        riscv_pkg::CsrDpc: csr_read_data_comb = dpc;
        riscv_pkg::CsrDscratch0: csr_read_data_comb = dscratch0;
        riscv_pkg::CsrDscratch1: csr_read_data_comb = dscratch1;
        riscv_pkg::CsrDdata: csr_read_data_comb = XLEN'(i_dbg_data);
        // Machine information registers (read-only)
        riscv_pkg::CsrMhartid:
        csr_read_data_comb = '0;  // Hardware thread ID (always 0 for single-core)
        default: csr_read_data_comb = '0;
      endcase
    end
  end

  // Register CSR read data for timing optimization
  logic [XLEN-1:0] csr_read_data_reg;

  always_ff @(posedge i_clk) begin
    csr_read_data_reg <= csr_read_data_comb;
  end

  assign o_csr_read_data = csr_read_data_reg;
  assign o_csr_read_data_comb = csr_read_data_comb;
  assign o_perf_counter_select = perf_counter_select[7:0];
  assign o_perf_cache_previous_select = perf_cache_previous_select;
  assign o_perf_snapshot_capture = i_csr_write_enable && i_csr_read_enable &&
                                   (i_csr_address == riscv_pkg::CsrMperfCtl) &&
                                   csr_new_value[0];

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL

  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Structural constraints
  always_comb begin
    assume (!(i_trap_taken && i_mret_taken));
    assume (!(i_trap_taken && i_sret_taken));
    // Debug Mode (M3): DRET is one of the mutually exclusive xRETs and only
    // executes in Debug Mode (the ROB allocation check); a Debug Mode entry
    // never steers to S; D entries are impossible from Debug Mode (the trap
    // unit re-parks without a CSR write instead).
    assume (!(i_dret_taken && (i_trap_taken || i_mret_taken || i_sret_taken)));
    assume (!(i_dret_taken && i_csr_write_enable));
    assume (!(i_dret_taken && !debug_mode_q));
    assume (!(i_trap_taken && i_trap_to_d && i_trap_to_s));
    assume (!(i_trap_taken && i_trap_to_d && debug_mode_q));
    assume (!(i_mret_taken && i_sret_taken));
    assume (!(i_trap_taken && i_csr_write_enable));
    assume (!(i_mret_taken && i_csr_write_enable));
    assume (!(i_sret_taken && i_csr_write_enable));
    // Delegated traps only enter from below M (the trap unit never asserts
    // i_trap_to_s for an M-mode trap: medeleg applies only when priv < M and
    // S-target interrupts are never taken in M).
    assume (!(i_trap_taken && i_trap_to_s && (priv_q == riscv_pkg::PrivM)));
    // SRET only executes from S or M (a U-mode SRET is captured as illegal at
    // ROB allocation and never reaches the trap unit).
    assume (!(i_sret_taken && (priv_q == riscv_pkg::PrivU)));
    // FP-state commit pulses never coincide with a CSR commit: CSR ops are
    // head-serialized and retire 1-wide in cpu_ooo, so no FP instruction
    // commits in the same cycle (the D15 Dirty-set logic relies on this).
    assume (!(i_fp_dest_write && i_csr_write_enable));
    assume (!(i_fp_flags_valid && i_csr_write_enable));
    // PCs are at least 2-byte aligned (compressed extension minimum)
    assume (i_trap_pc[0] == 1'b0);
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // Privilege register invariant: 2'b10 is unreachable (trap entry
      // installs M or S, xRET installs a folded MPP / 1-bit SPP, and the
      // MPP WARL fold never stores 2'b10).
      p_priv_valid : assert (priv_q != 2'b10);

      // Debug Mode entry (M3): dpc/dcsr record the resume state, priv
      // becomes M, and NO M/S trap-stack register moves.
      if ($past(i_trap_taken && i_trap_to_d)) begin
        p_dentry_sets_mode : assert (debug_mode_q);
        p_dentry_saves_dpc : assert (dpc == {$past(i_trap_pc[XLEN-1:1]), 1'b0});
        p_dentry_saves_cause : assert (dcsr_cause == $past(i_trap_dbg_cause));
        p_dentry_saves_prv : assert (dcsr_prv == $past(priv_q));
        p_dentry_enters_m : assert (priv_q == riscv_pkg::PrivM);
        p_dentry_keeps_mepc : assert (mepc == $past(mepc));
        p_dentry_keeps_sepc : assert (sepc == $past(sepc));
        p_dentry_keeps_mie : assert (mstatus_mie == $past(mstatus_mie));
        p_dentry_keeps_mpp : assert (mstatus_mpp == $past(mstatus_mpp));
        p_dentry_keeps_mcause : assert (mcause == $past(mcause));
      end
      // DRET: leave Debug Mode, restore dcsr.prv, clear MPRV below M.
      if ($past(i_dret_taken)) begin
        p_dret_clears_mode : assert (!debug_mode_q);
        p_dret_restores_priv : assert (priv_q == $past(dcsr_prv));
        if ($past(dcsr_prv != riscv_pkg::PrivM)) begin
          p_dret_clears_mprv : assert (!mstatus_mprv);
        end
        p_dret_keeps_mie : assert (mstatus_mie == $past(mstatus_mie));
        p_dret_keeps_mpp : assert (mstatus_mpp == $past(mstatus_mpp));
      end
      // The mode only moves on entry/DRET.
      if ($past(!(i_trap_taken && i_trap_to_d) && !i_dret_taken)) begin
        p_debug_mode_stable : assert (debug_mode_q == $past(debug_mode_q));
      end
      // M-target trap saves state: mepc/mcause/mtval and the M trap stack.
      if ($past(i_trap_taken && !i_trap_to_s && !i_trap_to_d)) begin
        p_trap_saves_mepc : assert (mepc == $past(i_trap_pc));
        p_trap_saves_mcause : assert (mcause == $past(i_trap_cause));
        p_trap_saves_mtval : assert (mtval == $past(i_trap_value));
        p_trap_clears_mie : assert (!mstatus_mie);
        p_trap_saves_mpie : assert (mstatus_mpie == $past(mstatus_mie));
        p_trap_saves_mpp : assert (mstatus_mpp == $past(priv_q));
        p_trap_enters_m : assert (priv_q == riscv_pkg::PrivM);
        // The S trap stack is untouched by an M-target entry.
        p_trap_m_keeps_sepc : assert (sepc == $past(sepc));
        p_trap_m_keeps_sie : assert (mstatus_sie == $past(mstatus_sie));
      end

      // Delegated (S-target) trap saves the S side and leaves the M side.
      if ($past(i_trap_taken && i_trap_to_s)) begin
        p_strap_saves_sepc : assert (sepc == $past(i_trap_pc));
        p_strap_saves_scause : assert (scause == $past(i_trap_cause));
        p_strap_saves_stval : assert (stval == $past(i_trap_value));
        p_strap_clears_sie : assert (!mstatus_sie);
        p_strap_saves_spie : assert (mstatus_spie == $past(mstatus_sie));
        p_strap_saves_spp : assert (mstatus_spp == $past(priv_q == riscv_pkg::PrivS));
        p_strap_enters_s : assert (priv_q == riscv_pkg::PrivS);
        p_strap_keeps_mepc : assert (mepc == $past(mepc));
        p_strap_keeps_mie : assert (mstatus_mie == $past(mstatus_mie));
        p_strap_keeps_mpp : assert (mstatus_mpp == $past(mstatus_mpp));
      end

      // MRET restores MIE: after MRET, MIE = old MPIE, MPIE = 1, priv = old
      // MPP, MPP = U; MPRV clears when leaving M.
      if ($past(i_mret_taken)) begin
        p_mret_restores_mie : assert (mstatus_mie == $past(mstatus_mpie));
        p_mret_sets_mpie : assert (mstatus_mpie);
        p_mret_restores_priv : assert (priv_q == $past(mstatus_mpp));
        p_mret_clears_mpp : assert (mstatus_mpp == riscv_pkg::PrivU);
        if ($past(mstatus_mpp != riscv_pkg::PrivM)) begin
          p_mret_clears_mprv : assert (!mstatus_mprv);
        end
      end

      // SRET restores SIE: after SRET, SIE = old SPIE, SPIE = 1, priv =
      // SPP?S:U, SPP = U, MPRV = 0 (always leaves to <= S).
      if ($past(i_sret_taken)) begin
        p_sret_restores_sie : assert (mstatus_sie == $past(mstatus_spie));
        p_sret_sets_spie : assert (mstatus_spie);
        p_sret_restores_priv :
        assert (priv_q == ($past(mstatus_spp) ? riscv_pkg::PrivS : riscv_pkg::PrivU));
        p_sret_clears_spp : assert (!mstatus_spp);
        p_sret_clears_mprv : assert (!mstatus_mprv);
        // The M trap stack is untouched by SRET.
        p_sret_keeps_mie : assert (mstatus_mie == $past(mstatus_mie));
        p_sret_keeps_mpp : assert (mstatus_mpp == $past(mstatus_mpp));
      end

      // Cycle counter increments every cycle (not in reset).
      p_cycle_increments : assert (cycle_counter == $past(cycle_counter) + 64'd1);

      // Instret retime invariants (see the Instructions Retired Counter
      // comment): the staging register follows the input by one cycle, and
      // the accumulator applies the staged count.  Composed:
      //   instret_counter(T) == instret_counter(T-1) + retired_count(T-2)
      // i.e. instret equals the running total of retired instructions delayed
      // by exactly one staging cycle; the delay is architecturally invisible
      // because commit-serialized CSR reads sample the counter no earlier
      // than <last counted commit> + 3 cycles.
      p_instret_stage_follows :
      assert (instruction_retired_count_q == $past(i_instruction_retired_count));
      p_instret_applies_staged_count :
      assert (instret_counter == $past(instret_counter) + 64'($past(instruction_retired_count_q)));

      // fflags sticky: when no CSR write to fflags/fcsr and no effective fp_flags_valid,
      // fflags does not shrink.
      if ($past(
              !fp_flags_valid_eff && !(i_csr_write_enable && i_csr_read_enable &&
          (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFcsr))
          )) begin
        p_fflags_sticky : assert (fflags == $past(fflags));
      end

      // mcounteren: a committed CSR write installs exactly csr_new_value[2:0]
      // (WARL — the register is 3 bits, so upper write bits are discarded);
      // nothing else ever changes it (trap entry and MRET are excluded by the
      // structural assumptions above and touch other registers anyway).
      if ($past(
              i_csr_write_enable && i_csr_read_enable && (i_csr_address == riscv_pkg::CsrMcounteren)
          )) begin
        p_mcounteren_write : assert (mcounteren_q == $past(csr_new_value[2:0]));
      end else begin
        p_mcounteren_stable : assert (mcounteren_q == $past(mcounteren_q));
      end

      // D15 FS: an FP-state write (regfile dest, flag accrual, or an
      // fflags/frm/fcsr CSR write) sets Dirty; an explicit mstatus OR
      // sstatus write installs its FS field (Phase 3: sstatus exposes FS to
      // S-mode context switching — the pulses are excluded by the structural
      // assumption above); otherwise FS holds (trap entry and xRET leave it
      // untouched by design — the trap-time image is what the OS reads).
      if ($past(
              i_fp_dest_write || i_fp_flags_valid ||
                (i_csr_write_enable && i_csr_read_enable &&
                 (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFrm ||
                  i_csr_address == riscv_pkg::CsrFcsr))
          )) begin
        p_fs_dirty_set : assert (mstatus_fs == FsDirty);
      end else if ($past(
              i_csr_write_enable && i_csr_read_enable &&
              ((i_csr_address == riscv_pkg::CsrMstatus) ||
               (i_csr_address == riscv_pkg::CsrSstatus))
          )) begin
        p_fs_csr_write : assert (mstatus_fs == $past(csr_new_value[14:13]));
      end else begin
        p_fs_stable : assert (mstatus_fs == $past(mstatus_fs));
      end
    end

    // Reset establishes the architectural reset values (sampled on the first
    // cycle after reset deasserts; the previous guard's $past(!i_rst) term
    // made these vacuous).
    if (f_past_valid && !i_rst && $past(i_rst)) begin
      p_reset_cycle : assert (cycle_counter == 64'd0);
      p_reset_instret : assert (instret_counter == 64'd0);
      p_reset_instret_stage : assert (instruction_retired_count_q == 2'd0);
      p_reset_mie : assert (!mstatus_mie);
      p_reset_mpie : assert (!mstatus_mpie);
      p_reset_fflags : assert (fflags == 5'b0);
      p_reset_frm : assert (frm == 3'b0);
      p_reset_mcounteren : assert (mcounteren_q == 3'b111);
      p_reset_scounteren : assert (scounteren_q == 3'b111);
      // D15: FS resets to Initial (not Off) so FP runs without OS setup.
      p_reset_fs : assert (mstatus_fs == FsInitial);
      p_reset_priv : assert (priv_q == riscv_pkg::PrivM);
      p_reset_sie : assert (!mstatus_sie && !mstatus_spie && !mstatus_spp);
      p_reset_deleg : assert ((medeleg_q == '0) && !mideleg_ssi && !mideleg_sti && !mideleg_sei);
      p_reset_sp_pending : assert (!mip_ssip && !mip_stip && !mip_seip);
      p_reset_satp : assert (!satp_mode_sv39 && (satp_ppn == '0));
      p_reset_flush_req : assert (!csr_translation_flush_req_q);
      p_reset_debug : assert (!debug_mode_q && !dcsr_step && (dcsr_prv == riscv_pkg::PrivM));
    end

    if (!i_rst) begin
      // mepc alignment: bit 0 always clear (2-byte aligned for C extension).
      p_mepc_aligned : assert (mepc[0] == 1'b0);
      p_dpc_aligned : assert (dpc[0] == 1'b0);
      p_dcsr_prv_valid : assert (dcsr_prv != 2'b10);

      // D15: SD (mstatus top bit) mirrors FS==Dirty, and the
      // exported gate signal is exactly FS==Off.
      p_sd_mirrors_fs : assert (mstatus[XLEN-1] == (mstatus_fs == FsDirty));
      p_fs_off_export : assert (o_mstatus_fs_off == (mstatus_fs == FsOff));

      // mtvec MODE: bit 1 always 0, bit 0 can be 0 (Direct) or 1 (Vectored).
      p_mtvec_aligned : assert (mtvec[1] == 1'b0);
      // The registered misaligned-trap config bit mirrors the register.
      p_mtvec_traps_misaligned_mirror : assert (mtvec_traps_misaligned_q == (|mtvec[XLEN-1:2]));

      // mip's machine bits are read-only and reflect the inputs; the
      // supervisor SEIP/STIP readbacks compose the PLIC S-context line and
      // the Sstc compare with the software-injection registers (M6).
      p_mip_reflects_inputs :
      assert (mip == {20'b0, i_interrupts.meip, 1'b0, seip_eff, 1'b0,
          i_interrupts.mtip, 1'b0, stip_eff, 1'b0,
          i_interrupts.msip, 1'b0, mip_ssip, 1'b0});
      // The sie/sip views expose only delegated bits.
      p_sie_view_masked : assert ((sie_view & ~mideleg) == '0);
      p_sip_view_masked : assert ((sip_view & ~mideleg) == '0);
      // Delegation registers honor their WARL masks.
      p_medeleg_warl : assert ((XLEN'(medeleg_q) & ~riscv_pkg::MedelegMask) == '0);
      p_mideleg_warl : assert ((mideleg & ~riscv_pkg::MidelegMask) == '0);
      // sepc/stvec keep the same alignment invariants as their M twins.
      p_sepc_aligned : assert (sepc[0] == 1'b0);
      p_stvec_aligned : assert (stvec[1] == 1'b0);
      // satp invariants: ASID reads zero; Sv39 cannot be stored until the
      // translation milestone flips SatpSv39Supported.
      p_satp_asid_zero : assert (satp[59:44] == '0);
      if (!SatpSv39Supported) begin
        p_satp_bare_only : assert (!satp_mode_sv39);
      end
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_trap_entry : cover (f_past_valid && $past(i_trap_taken));
      cover_trap_to_s : cover (f_past_valid && $past(i_trap_taken && i_trap_to_s));
      cover_trap_from_s_to_m :
      cover (f_past_valid && $past(i_trap_taken && !i_trap_to_s && priv_q == riscv_pkg::PrivS));
      cover_mret : cover (f_past_valid && $past(i_mret_taken));
      cover_mret_to_s :
      cover (f_past_valid && $past(i_mret_taken && mstatus_mpp == riscv_pkg::PrivS));
      cover_sret : cover (f_past_valid && $past(i_sret_taken));
      cover_sret_to_u : cover (f_past_valid && $past(i_sret_taken && !mstatus_spp));
      cover_debug_entry : cover (f_past_valid && $past(i_trap_taken && i_trap_to_d));
      cover_debug_entry_from_u :
      cover (f_past_valid && $past(i_trap_taken && i_trap_to_d && priv_q == riscv_pkg::PrivU));
      cover_dret : cover (f_past_valid && $past(i_dret_taken));
      cover_dret_to_u : cover (f_past_valid && $past(i_dret_taken && dcsr_prv == riscv_pkg::PrivU));
      cover_ddata_write : cover (o_dbg_data_we);
      cover_delegated_bits : cover (mideleg_ssi && mideleg_sti && mideleg_sei);
      cover_translation_flush_req : cover (csr_translation_flush_req_q);
      cover_csr_write : cover (i_csr_write_enable && i_csr_read_enable);
      cover_mcounteren_cleared : cover (mcounteren_q == 3'b000);
      // D15: FS reaches both interesting endpoints (Off gates FP illegal;
      // Dirty drives the SD mirror the OS keys context saves on).
      cover_fs_off : cover (mstatus_fs == FsOff);
      cover_fs_dirty : cover (mstatus_fs == FsDirty);
      cover_fp_flags : cover (i_fp_flags_valid);
      cover_instret : cover (f_past_valid && instret_counter > 64'd0);
    end
  end

`endif  // FORMAL

endmodule : csr_file
