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
  CSR storage for Zicsr, Zicntr, Sstc, M/S/U privilege, Debug Mode, FP state,
  and FROST profiling. cpu_ooo serializes CSR instructions on the registered
  commit bus (see "CSR writes" in the CPU README). The ROB checks access
  legality at allocation; this module exports the required state.

  sstatus, sie, and sip are views of M-mode storage. sie/sip expose only
  delegated supervisor bits at every privilege; sip permits writes only to
  delegated SSIP. medeleg/mideleg use the package WARL masks: M-mode ECALL
  and machine interrupts cannot delegate. senvcfg is present as required
  for S/U support, but implements no fields and reads zero.

  mstatus.MPRV makes data accesses use MPP. MPP and dcsr.prv fold reserved
  2'b10 to U. FS resets to Initial and becomes Dirty on FP state writes;
  SD mirrors Dirty. misa is read-only RV64 IMAFDC+B+S+U.

  Debug CSRs follow RISC-V Debug Spec 0.13.2 and require Debug Mode.
  dcsr implements ebreakm/ebreaks/ebreaku, step, and prv as writable fields;
  cause records entry, xdebugver=4, and mprven=1. stepie, stopcount,
  stoptime, and nmip read zero. dpc is 2-byte aligned. Custom ddata (0x7B4)
  forwards the debug module's {data1, data0}, with hartinfo dataaccess=0.

  cycle/time/instret are read-only Zicntr counters. mcycle/minstret are
  writable aliases; writes replace the coincident increment. The instret
  input also counts xRET, WFI taken over by a trap, FENCE.I, and SFENCE.VMA,
  whose retirements bypass the registered commit bus. See the counter
  logic for the staging and CSR-serialization timing.

  mcountinhibit implements CY and IR and resets to zero. OpenSBI requires
  it before enabling Sstc and uses it with writable counters for SBI PMU.
  mhpmcounter3..31 and mhpmevent3..31 implement the privileged spec's
  read-zero minimum, without storage. Their Zihpm user aliases are absent.
  RV32 high-half counter addresses are illegal at every privilege.
  mcounteren/scounteren implement CY/TM/IR and reset to 0x7.

  Profiling CSR layout (see "CSR interface" in cpu_ooo/perf/README.md):
    mperfsel (0x7C0): counter index.
    mperfctl (0x7C1): bit 0 captures a snapshot; bit 1 selects the preceding
      cache snapshot for readback. Reads zero.
    mperfdata/mperfdatah (0xFC0/0xFC1): low/high 32-bit counter halves.
    mperfcount (0xFC2): counter count.
  PERF_COUNTERS=0 makes all profiling CSRs read zero and ignore writable
  accesses. Writes to read-only profiling CSRs still trap.
*/
// Keep local CSR decoding separate from commit and serializer logic, for timing.
(* keep_hierarchy = "yes" *)
module csr_file #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    // Requires CSR commits to exclude trap and xRET takes, as cpu_ooo does.
    // This removes redundant trap priority from write paths. The default
    // retains trap-over-write priority.
    parameter bit COMMIT_EXCLUDES_CONTROL_TAKE = 1'b0,
    // 1: i_perf_counter_csr_half already holds the counter half that the
    // current i_csr_address reads (cpu_ooo's aggregator selects it on the
    // edge that registers the address), and mperfdata/mperfdatah return it.
    parameter bit UsePerfCsrHalf = 1'b0,
    // 0 removes profiling state: mperf* reads return zero, writes have no
    // effect, and o_perf_* stays constant. cpu_ooo passes its build option.
    parameter int unsigned PERF_COUNTERS = 1
) (
    input logic i_clk,
    input logic i_rst,

    // CSR access interface, driven from the ROB commit port in cpu_ooo.
    input  logic            i_csr_read_enable,    // A CSR access is committing
    input  logic [    11:0] i_csr_address,        // CSR address
    input  logic [     2:0] i_csr_op,             // funct3; [1:0] = 0 marks a pure read
    input  logic [XLEN-1:0] i_csr_write_data,     // rs1 value or zero-extended immediate
    input  logic            i_csr_write_enable,   // Commit the write (not stalled/flushed)
    output logic [XLEN-1:0] o_csr_read_data,      // CSR read value (registered, 1-cycle latency)
    output logic [XLEN-1:0] o_csr_read_data_comb, // CSR read value (combinational, same cycle)

    // Number of instructions retired this cycle: 0, 1, or 2.
    input logic [1:0] i_instruction_retired_count,

    // Interrupt pending inputs (meip/mtip registered upstream in cpu_and_mem; msip direct)
    input riscv_pkg::interrupt_t i_interrupts,

    // mtime input (from memory-mapped timer)
    input logic [63:0] i_mtime,

    // PLIC S-context external-interrupt line: ORed into the SEIP readback and
    // o_s_pending; mip.SEIP writes change only the software-injection bit.
    input logic i_seip_line,

    // Trap entry signals (from trap unit)
    input logic            i_trap_taken,  // Trap is being taken
    input logic            i_trap_to_s,   // Entry targets S-mode CSRs
    input logic [XLEN-1:0] i_trap_pc,     // PC to save to mepc, sepc, or dpc
    input logic [XLEN-1:0] i_trap_cause,  // Cause to save to mcause/scause
    input logic [XLEN-1:0] i_trap_value,  // Value to save to mtval/stval

    // Entry enables from the trap unit, at most one set, built for timing.
    // They equal i_trap_taken && !i_trap_to_d with !i_trap_to_s (M-side save)
    // or i_trap_to_s (S-side save), and i_trap_taken && i_trap_to_d (Debug
    // Mode entry). State updates use them; the checks use the other inputs.
    input logic i_trap_save_m,
    input logic i_trap_save_s,
    input logic i_trap_enter_d,

    // xRET signals (from trap unit); mutually exclusive pulses
    input  logic        i_mret_taken,      // MRET is being executed
    input  logic        i_sret_taken,      // SRET is being executed
    // i_trap_taken && i_trap_to_d enters Debug Mode. cpu_ooo withholds
    // i_trap_taken for CSR-free redirects, including memory replays.
    // i_trap_dbg_cause supplies dcsr.cause.
    input  logic        i_trap_to_d,
    input  logic [ 2:0] i_trap_dbg_cause,
    input  logic        i_dret_taken,      // DRET is being executed
    // ddata (0x7B4): the debug module's data0/data1 pair, forwarded. The
    // write data is valid while o_dbg_data_we is set.
    input  logic [63:0] i_dbg_data,
    output logic        o_dbg_data_we,
    output logic [63:0] o_dbg_data_wdata,

    // CSR outputs for trap/interrupt handling
    output logic [XLEN-1:0] o_mstatus,
    output logic [XLEN-1:0] o_mie,
    output logic [XLEN-1:0] o_mtvec,
    // Registered |mtvec[XLEN-1:2]: a nonzero trap base enables load/store
    // misalignment traps. Updated with mtvec from the same write data.
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

    // Effective supervisor interrupt-pending bits {SEIP, STIP, SSIP}, as mip
    // reads them: SEIP includes the PLIC S-context line, and STIP is the Sstc
    // compare while menvcfg.STCE is set. Consumed by the trap unit and the
    // WFI wake OR.
    output logic [2:0] o_s_pending,

    // Current privilege mode (PrivM/PrivS/PrivU): consumed by trap_unit
    // (per-target interrupt enables), the commit-time ECALL cause select,
    // and the reorder buffer's allocation legality snapshot. Changes only
    // on trap entry and xRET.
    output logic [1:0] o_priv,

    // mcounteren bits: [0]=CY, [1]=TM, [2]=IR. Updated on committed CSR
    // writes; o_counter_blocked resolves access restrictions at allocation.
    output logic [2:0] o_mcounteren,
    // scounteren uses the same bit layout and gates U-mode access.
    output logic [2:0] o_scounteren,

    // Legality bits sampled by the ROB at allocation. CSR writes stop younger
    // allocation, and privilege changes flush the pipeline, so each sample
    // remains valid until retirement.
    //   o_counter_blocked[2:0]: CY/TM/IR access is illegal (U needs both
    //     mcounteren and scounteren; S needs mcounteren; M is never blocked).
    //   o_sret_illegal: U, or S with TSR set.
    //   o_sfence_illegal: SFENCE.VMA/satp in U, or S with TVM set.
    //   o_wfi_illegal: U, or S with TW set.
    //   o_priv_is_u: current privilege is U, for CSRs requiring S.
    output logic [2:0] o_counter_blocked,
    // Sstc: stimecmp access in S requires menvcfg.STCE. M is never blocked;
    // U fails the generic needs-S check. Sampled at allocation as above.
    output logic o_stimecmp_blocked,
    output logic o_sret_illegal,
    output logic o_sfence_illegal,
    output logic o_wfi_illegal,
    output logic o_priv_is_u,

    // One-cycle TLB/PTW invalidate pulse for any enabled committed satp
    // access, or an mstatus/sstatus commit whose computed result changes
    // SUM/MXR/MPRV (or MPP while MPRV=1). The ROB serializer separately
    // drains committed stores and flushes the pipeline.
    output logic o_csr_translation_flush_req,

    // Data-translation state, delayed one cycle. Every input change (satp,
    // status, privilege) is followed by a full flush whose refetch outlasts
    // the delay, so memory operations cannot mix old and new state.
    output logic o_translation_active,  // satp Sv39 && effective data priv < M
    output logic o_mmu_sum,
    output logic o_mmu_mxr,
    output logic o_mmu_eff_priv_u,  // effective data privilege == U
    // Fetch uses current privilege; MPRV affects data only. These outputs
    // decode from fetch_priv_q, which equals priv_q on every cycle. There
    // is no extra delay: a privilege or mode change immediately hides old
    // tagged fetch results. The redirect resolves under the new state.
    // With translation off, the IMMU is combinational.
    output logic o_fetch_translation_active,  // satp Sv39 && priv != M
    output logic o_fetch_priv_u,  // current privilege == U
    // Root PPN for the walker (satp.PPN, registered storage). A satp write
    // also raises o_csr_translation_flush_req, which discards any walk in
    // flight.
    output logic [43:0] o_satp_root_ppn,

    // mstatus.FS == Off. id_stage decodes every F/D instruction as illegal
    // while it is set, and the reorder buffer's allocation check traps them
    // and fflags/frm/fcsr accesses. Changes only on a committed CSR write
    // (hardware only sets Dirty, never Off).
    output logic o_mstatus_fs_off,

    // Debug Mode state for allocation legality, trap routing, halt reporting,
    // and single stepping. Changes require a flushing trap/DRET or a
    // head-serialized CSR write.
    output logic            o_debug_mode,
    output logic            o_dcsr_step,
    output logic [     2:0] o_dcsr_ebreak,  // {ebreakm, ebreaks, ebreaku}
    output logic [XLEN-1:0] o_dpc,

    // F extension: FP exception flags from FPU (to accumulate in fflags)
    input riscv_pkg::fp_flags_t i_fp_flags,
    input logic i_fp_flags_valid,  // Valid when a committing FP instruction has flags

    // A committing instruction writes the FP regfile this cycle (either
    // commit slot). Together with i_fp_flags_valid and the internal
    // fflags/frm/fcsr write decode this drives hardware FS=Dirty setting.
    input logic i_fp_dest_write,

    // Forward flags into same-cycle fflags/fcsr reads. cpu_ooo drives this
    // from the same ROB-commit signal as i_fp_flags_valid.
    input logic i_fp_flags_wb_valid,

    // F extension: FP flags from an in-order pipeline's MA stage, for read
    // forwarding; cpu_ooo ties them off.
    input riscv_pkg::fp_flags_t i_fp_flags_ma,
    input logic                 i_fp_flags_ma_valid, // Valid when FP instruction in MA stage

    // F extension: Rounding mode output for FPU
    output logic [2:0] o_frm,

    // Profiling counters
    output logic [ 7:0] o_perf_counter_select,
    output logic        o_perf_snapshot_capture,
    output logic        o_perf_cache_previous_select,
    input  logic [63:0] i_perf_counter_data,
    input  logic [31:0] i_perf_counter_csr_half,
    input  logic [31:0] i_perf_counter_count
);

  // ==========================================================================
  // CSR Registers
  // ==========================================================================

  // 64-bit counters for Zicntr
  logic [    63:0] cycle_counter;
  logic [    63:0] instret_counter;
  // mcountinhibit: the two implemented inhibit bits.
  logic            mcountinhibit_cy;
  logic            mcountinhibit_ir;

  // F extension CSRs
  logic [     4:0] fflags;  // FP exception flags: {NV, DZ, OF, UF, NX}
  logic [     2:0] frm;  // FP rounding mode

  // fcsr is a composite view: {24'b0, frm[2:0], fflags[4:0]}
  logic [XLEN-1:0] fcsr;
  assign fcsr  = XLEN'({24'b0, frm, fflags});

  assign o_frm = frm;

  // Machine-mode CSRs
  // Separate mstatus fields allow local bit updates.
  logic       mstatus_mie;  // Machine Interrupt Enable (bit 3)
  logic       mstatus_mpie;  // Machine Previous Interrupt Enable (bit 7)
  logic [1:0] mstatus_mpp;  // Previous Privilege [12:11]; WARL {PrivM,PrivS,PrivU}
  logic       mstatus_mprv;  // Modify PRiV (bit 17); consumed by the D-side
                             // effective data privilege
  // Supervisor trap-stack fields: live in the mstatus storage and
  // are exposed through both mstatus and the sstatus view.
  logic       mstatus_sie;  // Supervisor Interrupt Enable (bit 1)
  logic       mstatus_spie;  // Supervisor Previous Interrupt Enable (bit 5)
  logic       mstatus_spp;  // Supervisor Previous Privilege (bit 8; 0=U 1=S)
  // Virtualization/translation control fields.
  logic       mstatus_sum;  // permit Supervisor User-Memory access (bit 18)
  logic       mstatus_mxr;  // Make eXecutable Readable (bit 19)
  logic       mstatus_tvm;  // Trap Virtual Memory (bit 20)
  logic       mstatus_tw;  // Timeout Wait (bit 21)
  logic       mstatus_tsr;  // Trap SRET (bit 22)
  // FS [14:13] stores all four status values. Hardware sets Dirty on FP
  // state writes; Off makes F/D instructions and FP CSR accesses illegal.
  // Reset uses Initial so FP works without OS setup.
  logic [1:0] mstatus_fs;
  localparam logic [1:0] FsOff = 2'b00;
  localparam logic [1:0] FsInitial = 2'b01;
  localparam logic [1:0] FsDirty = 2'b11;
  logic fs_dirty;
  assign fs_dirty = (mstatus_fs == FsDirty);
  logic [1:0] priv_q;  // Current privilege mode (resets to PrivM)
  // Duplicate of priv_q for fanout, with the same reset and enable.
  // It must equal priv_q every cycle.
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 16 *)
  logic [1:0] fetch_priv_q;
  // Debug Mode state. dcsr's writable fields are stored
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
  // Low-word field map (bit 31 stays 0 here; SD is bit 63, applied below).
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
  // SD (FS==Dirty mirror) at 63, SXL/UXL hardwired to 2 (64-bit) at
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
  // Allocation legality, stable between serialized state changes.
  logic gate_priv_is_u, gate_priv_is_s;
  assign gate_priv_is_u = (priv_q == riscv_pkg::PrivU);
  assign gate_priv_is_s = (priv_q == riscv_pkg::PrivS);
  assign o_priv_is_u = gate_priv_is_u;
  assign o_sret_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tsr);
  assign o_sfence_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tvm);
  assign o_wfi_illegal = gate_priv_is_u || (gate_priv_is_s && mstatus_tw);

  // mie CSR: each interrupt enable is a separate register.
  // The supervisor enables exist regardless of delegation (an undelegated
  // supervisor-class interrupt is a machine-target interrupt); mideleg only
  // gates their visibility through the sie view.
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

  logic [XLEN-1:0] mtvec;  // Trap vector (MODE in bits [1:0], BASE in [XLEN-1:2])
  // mcounteren implements only CY/TM/IR; other bits read zero and ignore
  // writes. Reset 3'b111 permits cycle/time/instret access below M.
  logic [2:0] mcounteren_q;
  assign o_mcounteren = mcounteren_q;
  logic [XLEN-1:0] mscratch;  // Scratch register for trap handlers
  logic [XLEN-1:0] mepc;  // Exception PC
  logic [XLEN-1:0] mcause;  // Trap cause
  logic [XLEN-1:0] mtval;  // Trap value
  logic [XLEN-1:0] perf_counter_select;
  logic perf_cache_previous_select;
  localparam bit PerfCountersPresent = (PERF_COUNTERS != 0);

  logic menvcfg_stce;

  // Supervisor trap CSRs.
  logic [XLEN-1:0] stvec;  // Supervisor trap vector (MODE bit 1 forced 0, like mtvec)
  logic [2:0] scounteren_q;  // WARL CY/TM/IR like mcounteren; reset 0x7 (see header)
  assign o_scounteren = scounteren_q;
  assign o_counter_blocked = gate_priv_is_u ? ~(mcounteren_q & scounteren_q) :
      gate_priv_is_s ? ~mcounteren_q : 3'b000;
  assign o_stimecmp_blocked = gate_priv_is_s && !menvcfg_stce;
  logic [XLEN-1:0] sscratch;
  logic [XLEN-1:0] sepc;  // bit 0 forced 0, like mepc
  logic [XLEN-1:0] scause;
  logic [XLEN-1:0] stval;
  // satp supports Bare and Sv39; an unsupported MODE leaves the whole
  // register unchanged (privileged spec). ASID is WARL-0. All 44 PPN bits
  // are stored so the walker can fault on roots outside cached DDR.
  localparam bit SatpSv39Supported = 1'b1;
  localparam logic [3:0] SatpModeBare = 4'd0;
  localparam logic [3:0] SatpModeSv39 = 4'd8;
  localparam int unsigned SatpPpnBits = 44;
  logic satp_mode_sv39;  // 0 = Bare, 1 = Sv39
  logic [SatpPpnBits-1:0] satp_ppn;
  logic [XLEN-1:0] satp;
  assign satp = {
    satp_mode_sv39 ? SatpModeSv39 : SatpModeBare,  // MODE [63:60]
    16'b0,  // ASID [59:44] (WARL-0)
    satp_ppn  // PPN [43:0]
  };

  // mip: the machine bits are read-only reflections of the interrupt inputs.
  // The supervisor bits SSIP/STIP/SEIP are software-writable state that
  // M-mode uses to inject supervisor interrupts; the PLIC S-context line ORs
  // into the SEIP readback.
  logic mip_ssip, mip_stip, mip_seip;
  // With STCE=1, STIP uses registered mtime >= stimecmp in every consumer.
  // With STCE=0, it uses the software bit. Registration adds one cycle to
  // the compare, for timing.
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

  assign o_mstatus_mie_direct = mstatus_mie;

  // ==========================================================================
  // CSR Write Data Calculation
  // ==========================================================================

  logic [XLEN-1:0] csr_current_value;
  logic [XLEN-1:0] csr_new_value;

  // Use the sstatus/sie/sip views as RMW bases so set/clear operations see
  // exactly the architecturally visible bits.
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
      riscv_pkg::CsrMcountinhibit:
      csr_current_value = XLEN'({29'b0, mcountinhibit_ir, 1'b0, mcountinhibit_cy});
      // The machine counter aliases are writable: their RMW base is the
      // live counter so csrrs/csrrc compose over the current value.
      riscv_pkg::CsrMcycle: csr_current_value = cycle_counter[XLEN-1:0];
      riscv_pkg::CsrMinstret: csr_current_value = instret_counter[XLEN-1:0];
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
      // Debug Mode CSRs
      riscv_pkg::CsrDcsr: csr_current_value = dcsr;
      riscv_pkg::CsrDpc: csr_current_value = dpc;
      riscv_pkg::CsrDscratch0: csr_current_value = dscratch0;
      riscv_pkg::CsrDscratch1: csr_current_value = dscratch1;
      riscv_pkg::CsrDdata: csr_current_value = XLEN'(i_dbg_data);
      default: csr_current_value = '0;
    endcase
  end

  // Dispatch sets op[1:0]=0 for set/clear with rs1/uimm field zero. These
  // pure reads still reach most write paths with the unchanged RMW base.
  // Counter writes and mperfctl separately require write intent.
  //
  // For mip RMW (privileged spec, mip.SEIP note), use the software SEIP/STIP
  // bits alone. Readback also includes the PLIC line or Sstc compare; using
  // that readback would latch a transient pending signal into software state.
  logic [XLEN-1:0] csr_rmw_base;
  always_comb begin
    csr_rmw_base = csr_current_value;
    if (i_csr_address == riscv_pkg::CsrMip) begin
      csr_rmw_base[riscv_pkg::MieSeiBit] = mip_seip;
      csr_rmw_base[riscv_pkg::MieStiBit] = mip_stip;
    end
  end
  always_comb begin
    csr_new_value = csr_rmw_base;
    unique case (i_csr_op)
      riscv_pkg::CSR_RW, riscv_pkg::CSR_RWI: csr_new_value = i_csr_write_data;
      riscv_pkg::CSR_RS, riscv_pkg::CSR_RSI: csr_new_value = csr_rmw_base | i_csr_write_data;
      riscv_pkg::CSR_RC, riscv_pkg::CSR_RCI: csr_new_value = csr_rmw_base & ~i_csr_write_data;
      default:                               csr_new_value = csr_rmw_base;
    endcase
  end

  // Local mtvec RMW, for timing. On an mtvec access, both generic bases
  // equal mtvec; only mip substitutes software pending bits.
  logic [XLEN-1:0] mtvec_new_value;
  always_comb begin
    unique case (i_csr_op)
      riscv_pkg::CSR_RW, riscv_pkg::CSR_RWI: mtvec_new_value = i_csr_write_data;
      riscv_pkg::CSR_RS, riscv_pkg::CSR_RSI: mtvec_new_value = mtvec | i_csr_write_data;
      riscv_pkg::CSR_RC, riscv_pkg::CSR_RCI: mtvec_new_value = mtvec & ~i_csr_write_data;
      default:                               mtvec_new_value = mtvec;
    endcase
  end

  // Local RMW copies use each CSR's register or masked view, for timing.
  // They must equal csr_new_value when their address is selected.
  // Shared masks implement new = (base & keep) | set from funct3[1:0]:
  //   01 writes data; 10 sets data bits; 11 clears data bits; 00 retains all.
  (* keep = "true" *) logic [XLEN-1:0] csr_rmw_keep, csr_rmw_set;
  always_comb begin
    unique case (i_csr_op[1:0])
      2'b01: begin
        csr_rmw_keep = '0;
        csr_rmw_set  = i_csr_write_data;
      end
      2'b10: begin
        csr_rmw_keep = '1;
        csr_rmw_set  = i_csr_write_data;
      end
      2'b11: begin
        csr_rmw_keep = ~i_csr_write_data;
        csr_rmw_set  = '0;
      end
      default: begin
        csr_rmw_keep = '1;
        csr_rmw_set  = '0;
      end
    endcase
  end
  function automatic logic [XLEN-1:0] zicsr_rmw(
      input logic [XLEN-1:0] keep, input logic [XLEN-1:0] set, input logic [XLEN-1:0] base);
    zicsr_rmw = (base & keep) | set;
  endfunction
  logic [XLEN-1:0] mip_rmw_base;
  always_comb begin
    mip_rmw_base = mip;
    mip_rmw_base[riscv_pkg::MieSeiBit] = mip_seip;
    mip_rmw_base[riscv_pkg::MieStiBit] = mip_stip;
  end
  logic [XLEN-1:0] fflags_new_value, frm_new_value, fcsr_new_value;
  logic [XLEN-1:0] mstatus_new_value, sstatus_new_value, mie_new_value, sie_new_value;
  logic [XLEN-1:0] mcounteren_new_value, mcountinhibit_new_value;
  logic [XLEN-1:0] mcycle_new_value, minstret_new_value;
  logic [XLEN-1:0] mscratch_new_value, mepc_new_value, mcause_new_value, mtval_new_value;
  logic [XLEN-1:0] medeleg_new_value, mideleg_new_value, mip_new_value, sip_new_value;
  logic [XLEN-1:0] stvec_new_value, scounteren_new_value, sscratch_new_value;
  logic [XLEN-1:0] sepc_new_value, scause_new_value, stval_new_value, satp_new_value;
  logic [XLEN-1:0] menvcfg_new_value, stimecmp_new_value;
  logic [XLEN-1:0] mperfsel_new_value, mperfctl_new_value;
  logic [XLEN-1:0] dcsr_new_value, dpc_new_value, dscratch0_new_value, dscratch1_new_value;
  logic [XLEN-1:0] ddata_new_value;
  assign fflags_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'({27'b0, fflags}));
  assign frm_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'({29'b0, frm}));
  assign fcsr_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, fcsr);
  assign mstatus_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mstatus);
  assign sstatus_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, sstatus);
  assign mie_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mie);
  assign sie_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, sie_view);
  assign mcounteren_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'({29'b0, mcounteren_q}));
  assign mcountinhibit_new_value = zicsr_rmw(
      csr_rmw_keep, csr_rmw_set, XLEN'({29'b0, mcountinhibit_ir, 1'b0, mcountinhibit_cy})
  );
  assign mcycle_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, cycle_counter[XLEN-1:0]);
  assign minstret_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, instret_counter[XLEN-1:0]);
  assign mscratch_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mscratch);
  assign mepc_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mepc);
  assign mcause_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mcause);
  assign mtval_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mtval);
  assign medeleg_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'(medeleg_q));
  assign mideleg_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mideleg);
  assign mip_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, mip_rmw_base);
  assign sip_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, sip_view);
  assign stvec_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, stvec);
  assign scounteren_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'({29'b0, scounteren_q}));
  assign sscratch_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, sscratch);
  assign sepc_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, sepc);
  assign scause_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, scause);
  assign stval_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, stval);
  assign satp_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, satp);
  assign menvcfg_new_value = zicsr_rmw(
      csr_rmw_keep, csr_rmw_set, XLEN'(menvcfg_stce) << riscv_pkg::MenvcfgStceBit
  );
  assign stimecmp_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, stimecmp);
  assign mperfsel_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, perf_counter_select);
  // mperfctl reads 0, so its base is 0.
  assign mperfctl_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, '0);
  assign dcsr_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, dcsr);
  assign dpc_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, dpc);
  assign dscratch0_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, dscratch0);
  assign dscratch1_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, dscratch1);
  assign ddata_new_value = zicsr_rmw(csr_rmw_keep, csr_rmw_set, XLEN'(i_dbg_data));

`ifndef SYNTHESIS
  // The local mtvec RMW must equal the generic result when mtvec is
  // addressed, even without a commit. Simulation excludes unknown inputs;
  // the two-state formal check needs only the address condition.
  always_comb begin
`ifdef FORMAL
    if (i_csr_address == riscv_pkg::CsrMtvec) begin
      p_mtvec_local_rmw_matches_generic : assert (mtvec_new_value == csr_new_value);
    end
`else
    if (!$isunknown(
            {i_csr_address, i_csr_op, i_csr_write_data, mtvec, csr_new_value, mtvec_new_value}
        ) && (i_csr_address == riscv_pkg::CsrMtvec)) begin
      p_mtvec_local_rmw_matches_generic : assert (mtvec_new_value == csr_new_value);
    end
`endif
  end

  // The same check for every other local copy: under each CSR's address its
  // copy equals csr_new_value.
  logic [XLEN-1:0] csr_local_new_value;
  always_comb begin
    case (i_csr_address)
      riscv_pkg::CsrFflags: csr_local_new_value = fflags_new_value;
      riscv_pkg::CsrFrm: csr_local_new_value = frm_new_value;
      riscv_pkg::CsrFcsr: csr_local_new_value = fcsr_new_value;
      riscv_pkg::CsrMstatus: csr_local_new_value = mstatus_new_value;
      riscv_pkg::CsrSstatus: csr_local_new_value = sstatus_new_value;
      riscv_pkg::CsrMie: csr_local_new_value = mie_new_value;
      riscv_pkg::CsrSie: csr_local_new_value = sie_new_value;
      riscv_pkg::CsrMcounteren: csr_local_new_value = mcounteren_new_value;
      riscv_pkg::CsrMcountinhibit: csr_local_new_value = mcountinhibit_new_value;
      riscv_pkg::CsrMcycle: csr_local_new_value = mcycle_new_value;
      riscv_pkg::CsrMinstret: csr_local_new_value = minstret_new_value;
      riscv_pkg::CsrMscratch: csr_local_new_value = mscratch_new_value;
      riscv_pkg::CsrMepc: csr_local_new_value = mepc_new_value;
      riscv_pkg::CsrMcause: csr_local_new_value = mcause_new_value;
      riscv_pkg::CsrMtval: csr_local_new_value = mtval_new_value;
      riscv_pkg::CsrMedeleg: csr_local_new_value = medeleg_new_value;
      riscv_pkg::CsrMideleg: csr_local_new_value = mideleg_new_value;
      riscv_pkg::CsrMip: csr_local_new_value = mip_new_value;
      riscv_pkg::CsrSip: csr_local_new_value = sip_new_value;
      riscv_pkg::CsrStvec: csr_local_new_value = stvec_new_value;
      riscv_pkg::CsrScounteren: csr_local_new_value = scounteren_new_value;
      riscv_pkg::CsrSscratch: csr_local_new_value = sscratch_new_value;
      riscv_pkg::CsrSepc: csr_local_new_value = sepc_new_value;
      riscv_pkg::CsrScause: csr_local_new_value = scause_new_value;
      riscv_pkg::CsrStval: csr_local_new_value = stval_new_value;
      riscv_pkg::CsrSatp: csr_local_new_value = satp_new_value;
      riscv_pkg::CsrMenvcfg: csr_local_new_value = menvcfg_new_value;
      riscv_pkg::CsrStimecmp: csr_local_new_value = stimecmp_new_value;
      riscv_pkg::CsrMperfSel: csr_local_new_value = mperfsel_new_value;
      riscv_pkg::CsrMperfCtl: csr_local_new_value = mperfctl_new_value;
      riscv_pkg::CsrDcsr: csr_local_new_value = dcsr_new_value;
      riscv_pkg::CsrDpc: csr_local_new_value = dpc_new_value;
      riscv_pkg::CsrDscratch0: csr_local_new_value = dscratch0_new_value;
      riscv_pkg::CsrDscratch1: csr_local_new_value = dscratch1_new_value;
      riscv_pkg::CsrDdata: csr_local_new_value = ddata_new_value;
      default: csr_local_new_value = csr_new_value;
    endcase
`ifdef FORMAL
    p_csr_local_rmw_matches_generic : assert (csr_local_new_value == csr_new_value);
`else
    if (!$isunknown(
            {i_csr_address, i_csr_op, i_csr_write_data, csr_new_value, csr_local_new_value}
        )) begin
      p_csr_local_rmw_matches_generic : assert (csr_local_new_value == csr_new_value);
    end
`endif
  end
`endif

  // ==========================================================================
  // Cycle Counter
  // ==========================================================================
  // Counter writes require CSR commit enables and Zicsr write intent.
  // A pure read must not overwrite the counter and swallow its increment.
  // Intent comes from the rs1/uimm encoding, even when its value is zero:
  // dispatch clears op[1:0] only for set/clear with a zero register/immediate
  // field. Generic M/S trap entry takes priority unless the parameter
  // guarantees exclusion.
  logic csr_write_intent;
  logic csr_counter_write;
  logic mcycle_write;
  logic minstret_write;
  assign csr_write_intent = (i_csr_op[1:0] != 2'b00);
  assign csr_counter_write = i_csr_write_enable && i_csr_read_enable &&
      csr_write_intent &&
      (COMMIT_EXCLUDES_CONTROL_TAKE || !(i_trap_save_m || i_trap_save_s));
  assign mcycle_write = csr_counter_write && (i_csr_address == riscv_pkg::CsrMcycle);
  assign minstret_write = csr_counter_write && (i_csr_address == riscv_pkg::CsrMinstret);

  // mcountinhibit.CY stops cycle increments; writes replace the increment.
  // Keep the increment separate from write selection, for timing.
  (* keep = "true" *) logic [63:0] cycle_counter_incremented;
  assign cycle_counter_incremented = cycle_counter + 64'd1;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_counter <= 64'd0;
    end else if (mcycle_write) begin
      cycle_counter <= mcycle_new_value;
    end else if (!mcountinhibit_cy) begin
      cycle_counter <= cycle_counter_incremented;
    end
  end

  // ==========================================================================
  // Instructions Retired Counter
  // ==========================================================================
  // Stage the retire count for timing. At cycle T, instret_counter includes
  // input counts through T-2. Serialized CSR reads cannot observe the delay:
  //   C:   the last older instruction commits on the ROB's commit_en.
  //   C+1: commit_actions computes its count from the registered commit bus;
  //        the CSR reaches the head and starts its serialized handshake.
  //   C+2: the count is staged; the earliest csr_done_ack permits CSR commit.
  //   C+3: the count reaches instret_counter as the registered CSR commit
  //        reads it.
  // Stalls add margin. The reading instruction is not included. xRET, WFI
  // taken over by a trap, FENCE.I, and SFENCE.VMA supply their counts one
  // cycle after retirement; refetch keeps later readers beyond this delay.
  //
  // mcountinhibit.IR stages zero. The write setting IR still counts itself:
  // its count stages before IR changes and accumulates one edge later.
  // A minstret write replaces the accumulator and stages zero for its own
  // retirement, as Zicsr requires. CSR commits are single-wide, and the
  // handshake leaves the previous staged count zero at the write edge.
  // Thus the next instruction after csrw minstret, V reads exactly V.
  logic [ 1:0] instruction_retired_count_q;
  // Select writes after the addition, for timing. This preserves
  // (w ? V : C) + (w ? 0 : Q) == w ? V : C + Q.
  (* keep = "true" *)logic [63:0] instret_counter_accumulated;
  assign instret_counter_accumulated = instret_counter + 64'(instruction_retired_count_q);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      instruction_retired_count_q <= 2'd0;
      instret_counter <= 64'd0;
    end else begin
      instruction_retired_count_q <= (mcountinhibit_ir || minstret_write) ? 2'd0 :
                                     i_instruction_retired_count;
      instret_counter <= minstret_write ? minstret_new_value : instret_counter_accumulated;
    end
  end

  // ==========================================================================
  // F Extension CSR Updates (fflags, frm)
  // ==========================================================================
  // fflags accumulates flags; only fflags/fcsr CSR writes can clear them.
  // After a CSR write forwards pending FP flags, suppress the following
  // WB cycle so those flags are not replayed. A write without forwarding
  // leaves later FP flag accumulation enabled.

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

  // Effective FP flags valid: accumulation is suppressed for one cycle after
  // a CSR write to fflags/fcsr whose read forwarded pending flags.
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
          riscv_pkg::CsrFflags: fflags <= fflags_new_value[4:0];
          riscv_pkg::CsrFrm:    frm <= frm_new_value[2:0];
          riscv_pkg::CsrFcsr: begin
            fflags <= fcsr_new_value[4:0];
            frm    <= fcsr_new_value[7:5];
          end
          default: begin
            // The write targets a non-FP CSR, so flags still accumulate.
            if (fp_flags_valid_eff) begin
              fflags <= fflags | {i_fp_flags.nv, i_fp_flags.dz,
                                  i_fp_flags.of, i_fp_flags.uf, i_fp_flags.nx};
            end
          end
        endcase
      end else if (fp_flags_valid_eff) begin
        fflags <= fflags | {i_fp_flags.nv, i_fp_flags.dz,
                            i_fp_flags.of, i_fp_flags.uf, i_fp_flags.nx};
      end
    end
  end

  // ==========================================================================
  // Machine-Mode CSR Updates - Next-State Logic
  // ==========================================================================

  // The CSR write arm comes first. With COMMIT_EXCLUDES_CONTROL_TAKE it wins
  // over a coincident take, so the write path carries no take; otherwise a
  // take suppresses the write. Among the takes, debug entry wins, then trap
  // entry, MRET, SRET, and DRET.
  logic status_csr_write;
  assign status_csr_write = i_csr_write_enable && i_csr_read_enable &&
      (COMMIT_EXCLUDES_CONTROL_TAKE ||
       !(i_trap_save_m || i_trap_save_s || i_trap_enter_d || i_mret_taken || i_sret_taken ||
         i_dret_taken));

  always_comb begin
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

    if (status_csr_write) begin
      if (i_csr_address == riscv_pkg::CsrMstatus) begin
        next_mstatus_sie = mstatus_new_value[riscv_pkg::MstatusSieBit];
        next_mstatus_mie = mstatus_new_value[3];
        next_mstatus_spie = mstatus_new_value[riscv_pkg::MstatusSpieBit];
        next_mstatus_mpie = mstatus_new_value[7];
        next_mstatus_spp = mstatus_new_value[riscv_pkg::MstatusSppBit];
        // MPP is WARL over {U, S, M}; reserved 2'b10 folds to U, as in Spike.
        next_mstatus_mpp = (mstatus_new_value[12:11] == 2'b10) ? riscv_pkg::PrivU
                                                               : mstatus_new_value[12:11];
        next_mstatus_mprv = mstatus_new_value[riscv_pkg::MstatusMprvBit];
        next_mstatus_sum = mstatus_new_value[riscv_pkg::MstatusSumBit];
        next_mstatus_mxr = mstatus_new_value[riscv_pkg::MstatusMxrBit];
        next_mstatus_tvm = mstatus_new_value[riscv_pkg::MstatusTvmBit];
        next_mstatus_tw = mstatus_new_value[riscv_pkg::MstatusTwBit];
        next_mstatus_tsr = mstatus_new_value[riscv_pkg::MstatusTsrBit];
        // FS is WARL with all four values storable (Off/Initial/Clean/Dirty).
        next_mstatus_fs = mstatus_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrSstatus) begin
        // sstatus writes only the S-visible fields.
        next_mstatus_sie  = sstatus_new_value[riscv_pkg::MstatusSieBit];
        next_mstatus_spie = sstatus_new_value[riscv_pkg::MstatusSpieBit];
        next_mstatus_spp  = sstatus_new_value[riscv_pkg::MstatusSppBit];
        next_mstatus_sum  = sstatus_new_value[riscv_pkg::MstatusSumBit];
        next_mstatus_mxr  = sstatus_new_value[riscv_pkg::MstatusMxrBit];
        next_mstatus_fs   = sstatus_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrMie) begin
        next_mie_ssie = mie_new_value[riscv_pkg::MieSsiBit];
        next_mie_msie = mie_new_value[3];
        next_mie_stie = mie_new_value[riscv_pkg::MieStiBit];
        next_mie_mtie = mie_new_value[7];
        next_mie_seie = mie_new_value[riscv_pkg::MieSeiBit];
        next_mie_meie = mie_new_value[11];
      end else if (i_csr_address == riscv_pkg::CsrSie) begin
        // Only delegated bits write through to mie. The masked RMW base and
        // write guards prevent set/clear operations from changing other bits.
        if (mideleg_ssi) next_mie_ssie = sie_new_value[riscv_pkg::MieSsiBit];
        if (mideleg_sti) next_mie_stie = sie_new_value[riscv_pkg::MieStiBit];
        if (mideleg_sei) next_mie_seie = sie_new_value[riscv_pkg::MieSeiBit];
      end
    end else if (i_trap_enter_d) begin
      // Debug Mode entry: the hart runs with M privilege; the
      // M/S trap stacks are untouched (dpc/dcsr record the resume state).
      next_priv = riscv_pkg::PrivM;
    end else if (i_trap_save_s) begin
      // Trap entry leaves FS alone on either side: the trap-time image is
      // exactly what the OS reads to decide whether FP state needs saving.
      // Delegated trap entry: save SIE->SPIE, clear SIE, save priv->SPP,
      // enter S-mode. The trap unit only steers to S from priv <= S
      // (delegation never applies to M-mode traps), so SPP's 1-bit encoding
      // (0=U, 1=S) covers every reachable priv.
      next_mstatus_spie = mstatus_sie;
      next_mstatus_sie  = 1'b0;
      next_mstatus_spp  = (priv_q == riscv_pkg::PrivS);
      next_priv         = riscv_pkg::PrivS;
    end else if (i_trap_save_m) begin
      // Machine trap entry: save MIE->MPIE, clear MIE, save priv->MPP
      // (U, S, or M), enter M-mode.
      next_mstatus_mpie = mstatus_mie;
      next_mstatus_mie  = 1'b0;
      next_mstatus_mpp  = priv_q;
      next_priv         = riscv_pkg::PrivM;
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
    end

    // FP register writes, flag commits, and FP CSR writes set FS=Dirty.
    // CSR serialization excludes concurrent mstatus writes. FS=Off prevents
    // F/D instructions and FP CSR accesses from committing, so this priority
    // cannot overwrite Off. Setting Dirty when no flags change is permitted.
    if ((i_csr_write_enable && i_csr_read_enable &&
         (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFrm ||
          i_csr_address == riscv_pkg::CsrFcsr)) ||
        i_fp_dest_write || i_fp_flags_valid) begin
      next_mstatus_fs = FsDirty;
    end
  end

  // mstatus/mie/priv registers.
  always @(posedge i_clk) begin
    if (i_rst) begin
      mstatus_mie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_mpp <= riscv_pkg::PrivU;
      mstatus_mprv <= 1'b0;
      // Initial permits FP execution without OS/crt0 setup.
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
      fetch_priv_q <= riscv_pkg::PrivM;
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
      fetch_priv_q <= next_priv;
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
  // The CSR write arm comes first. With COMMIT_EXCLUDES_CONTROL_TAKE it wins
  // over a coincident trap entry, so the write path carries no take;
  // otherwise an entry suppresses the write.
  logic storage_csr_write;
  assign storage_csr_write = i_csr_write_enable && i_csr_read_enable &&
      (COMMIT_EXCLUDES_CONTROL_TAKE || !(i_trap_save_m || i_trap_save_s));

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mtvec                      <= '0;
      mtvec_traps_misaligned_q   <= 1'b0;
      mcounteren_q               <= 3'b111;
      mcountinhibit_cy           <= 1'b0;
      mcountinhibit_ir           <= 1'b0;
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
    end else if (storage_csr_write) begin
      unique case (i_csr_address)
        riscv_pkg::CsrMtvec: begin
          mtvec                    <= {mtvec_new_value[XLEN-1:2], 1'b0, mtvec_new_value[0]};
          mtvec_traps_misaligned_q <= |mtvec_new_value[XLEN-1:2];
        end
        riscv_pkg::CsrMcounteren: mcounteren_q <= mcounteren_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrMcountinhibit: begin  // WARL: CY and IR only (TM/HPM bits read 0)
          mcountinhibit_cy <= mcountinhibit_new_value[0];
          mcountinhibit_ir <= mcountinhibit_new_value[2];
        end
        riscv_pkg::CsrMscratch: mscratch <= mscratch_new_value;
        riscv_pkg::CsrMepc: mepc <= {mepc_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C ext
        riscv_pkg::CsrMcause: mcause <= mcause_new_value;
        riscv_pkg::CsrMtval: mtval <= mtval_new_value;
        riscv_pkg::CsrMedeleg: medeleg_q <= medeleg_new_value[15:0] & riscv_pkg::MedelegMask[15:0];
        riscv_pkg::CsrMideleg: begin
          mideleg_ssi <= mideleg_new_value[riscv_pkg::MieSsiBit];
          mideleg_sti <= mideleg_new_value[riscv_pkg::MieStiBit];
          mideleg_sei <= mideleg_new_value[riscv_pkg::MieSeiBit];
        end
        // mip: the machine bits are read-only (input reflections); the
        // supervisor pending bits are the M-mode software-injection state.
        riscv_pkg::CsrMip: begin
          mip_ssip <= mip_new_value[riscv_pkg::MieSsiBit];
          mip_stip <= mip_new_value[riscv_pkg::MieStiBit];
          mip_seip <= mip_new_value[riscv_pkg::MieSeiBit];
        end
        // sip: SSIP is the only S-writable pending bit, and only where
        // delegated (the RMW base was the masked view, so set/clear forms
        // cannot leak through a non-delegated bit either).
        riscv_pkg::CsrSip: begin
          if (mideleg_ssi) mip_ssip <= sip_new_value[riscv_pkg::MieSsiBit];
        end
        riscv_pkg::CsrStvec: stvec <= {stvec_new_value[XLEN-1:2], 1'b0, stvec_new_value[0]};
        riscv_pkg::CsrScounteren: scounteren_q <= scounteren_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrSscratch: sscratch <= sscratch_new_value;
        riscv_pkg::CsrSepc: sepc <= {sepc_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C
        riscv_pkg::CsrScause: scause <= scause_new_value;
        riscv_pkg::CsrStval: stval <= stval_new_value;
        // satp: a write carrying an unsupported MODE leaves the whole
        // register unchanged (privileged-spec rule). ASID is WARL-0; the
        // PPN field stores all written bits.
        riscv_pkg::CsrSatp: begin
          if (satp_new_value[63:60] == SatpModeBare) begin
            satp_mode_sv39 <= 1'b0;
            satp_ppn <= satp_new_value[SatpPpnBits-1:0];
          end else if (SatpSv39Supported && (satp_new_value[63:60] == SatpModeSv39)) begin
            satp_mode_sv39 <= 1'b1;
            satp_ppn <= satp_new_value[SatpPpnBits-1:0];
          end
        end
        // Sstc: menvcfg implements STCE only (the rest stays WARL-0);
        // stimecmp is the full 64-bit compare value.
        riscv_pkg::CsrMenvcfg: menvcfg_stce <= menvcfg_new_value[riscv_pkg::MenvcfgStceBit];
        riscv_pkg::CsrStimecmp: stimecmp <= stimecmp_new_value;
        // Without counters the profiling state keeps its reset value.
        // mperfctl reads 0, so a pure read's write-back would clear the bank
        // select; only a write with intent sets it.
        riscv_pkg::CsrMperfSel: if (PerfCountersPresent) perf_counter_select <= mperfsel_new_value;
        riscv_pkg::CsrMperfCtl:
        if (PerfCountersPresent && csr_write_intent)
          perf_cache_previous_select <= mperfctl_new_value[1];
        default: ;
      endcase
    end else if (i_trap_save_s) begin
      // Trap entry: save state on the target-mode side only. A Debug Mode
      // entry saves dpc/dcsr instead (see the debug block below).
      sepc   <= i_trap_pc;
      scause <= i_trap_cause;
      stval  <= i_trap_value;
    end else if (i_trap_save_m) begin
      mepc   <= i_trap_pc;
      mcause <= i_trap_cause;
      mtval  <= i_trap_value;
    end
  end

  // ==========================================================================
  // Debug Mode registers
  // ==========================================================================
  // Entry records the resume state; DRET clears the mode; committed CSR
  // writes install the writable dcsr fields, dpc and the scratch registers.
  // Those writes are only reachable in Debug Mode (ROB allocation legality).
  // dcsr.prv is WARL over {U, S, M}; 2'b10 folds to U, like MPP. The CSR
  // write arm comes first. With COMMIT_EXCLUDES_CONTROL_TAKE it wins over a
  // coincident entry or DRET, so the write path carries no take; otherwise
  // those suppress the write.
  logic debug_csr_write;
  assign debug_csr_write = i_csr_write_enable && i_csr_read_enable &&
      (COMMIT_EXCLUDES_CONTROL_TAKE || !(i_trap_enter_d || i_dret_taken));
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
    end else if (debug_csr_write) begin
      unique case (i_csr_address)
        riscv_pkg::CsrDcsr: begin
          dcsr_ebreakm <= dcsr_new_value[riscv_pkg::DcsrEbreakMBit];
          dcsr_ebreaks <= dcsr_new_value[riscv_pkg::DcsrEbreakSBit];
          dcsr_ebreaku <= dcsr_new_value[riscv_pkg::DcsrEbreakUBit];
          dcsr_step    <= dcsr_new_value[riscv_pkg::DcsrStepBit];
          dcsr_prv     <= (dcsr_new_value[1:0] == 2'b10) ? riscv_pkg::PrivU : dcsr_new_value[1:0];
        end
        riscv_pkg::CsrDpc: dpc <= {dpc_new_value[XLEN-1:1], 1'b0};
        riscv_pkg::CsrDscratch0: dscratch0 <= dscratch0_new_value;
        riscv_pkg::CsrDscratch1: dscratch1 <= dscratch1_new_value;
        default: ;
      endcase
    end else if (i_trap_enter_d) begin
      debug_mode_q <= 1'b1;
      dpc          <= {i_trap_pc[XLEN-1:1], 1'b0};
      dcsr_cause   <= i_trap_dbg_cause;
      dcsr_prv     <= priv_q;
    end else if (i_dret_taken) begin
      debug_mode_q <= 1'b0;
    end
  end
  // ddata: the write lands in the debug module's data0/data1 storage.
  assign o_dbg_data_we = i_csr_write_enable && i_csr_read_enable &&
      (i_csr_address == riscv_pkg::CsrDdata);
  assign o_dbg_data_wdata = ddata_new_value[63:0];

  // Invalidate one cycle after every enabled satp access, including pure
  // reads and Bare-to-Bare writes. For mstatus/sstatus, invalidate on changes
  // to SUM/MXR/MPRV, or to MPP while MPRV is set.
  // COMMIT_EXCLUDES_CONTROL_TAKE permits comparing the CSR result directly;
  // otherwise compare next state, where traps and xRET take priority.
  logic csr_translation_flush_req_d;
  logic csr_status_write_changes_translation;
  logic [1:0] csr_written_mpp;
  assign csr_written_mpp = (mstatus_new_value[12:11] == 2'b10) ? riscv_pkg::PrivU :
      mstatus_new_value[12:11];
  // With control takes excluded, compare the complete CSR result before
  // commit qualification, including MPP's WARL mapping and old MPRV.
  assign csr_status_write_changes_translation =
      (mstatus_new_value[riscv_pkg::MstatusSumBit] != mstatus_sum) ||
      (mstatus_new_value[riscv_pkg::MstatusMxrBit] != mstatus_mxr) ||
      ((i_csr_address == riscv_pkg::CsrMstatus) &&
       ((mstatus_new_value[riscv_pkg::MstatusMprvBit] != mstatus_mprv) ||
        (mstatus_mprv && (csr_written_mpp != mstatus_mpp))));
  assign csr_translation_flush_req_d = i_csr_write_enable && i_csr_read_enable &&
      ((i_csr_address == riscv_pkg::CsrSatp) ||
       (((i_csr_address == riscv_pkg::CsrMstatus) ||
         (i_csr_address == riscv_pkg::CsrSstatus)) &&
        (COMMIT_EXCLUDES_CONTROL_TAKE ? csr_status_write_changes_translation :
         ((next_mstatus_sum != mstatus_sum) ||
          (next_mstatus_mxr != mstatus_mxr) ||
          (next_mstatus_mprv != mstatus_mprv) ||
          (mstatus_mprv && (next_mstatus_mpp != mstatus_mpp))))));

  logic csr_translation_flush_req_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      csr_translation_flush_req_q <= 1'b0;
    end else begin
      csr_translation_flush_req_q <= csr_translation_flush_req_d;
    end
  end
  assign o_csr_translation_flush_req = csr_translation_flush_req_q;

  // The data-translation state bundle (see the port comment for why its
  // one-cycle delay is safe). Effective data privilege honors MPRV.
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
  // Fetch decodes from fetch_priv_q; the attributes limit fanout.
  (* keep = "true", max_fanout = 16 *) logic fetch_translation_active;
  assign fetch_translation_active = satp_mode_sv39 && (fetch_priv_q != riscv_pkg::PrivM);
  assign o_fetch_translation_active = fetch_translation_active;
  assign o_fetch_priv_u = (fetch_priv_q == riscv_pkg::PrivU);
  assign o_satp_root_ppn = satp_ppn;

  // ==========================================================================
  // CSR Read Multiplexer
  // ==========================================================================
  // fflags/fcsr reads include pending FP flags. Read data is registered
  // with one-cycle latency for commit_actions' delayed CSR writeback.

  // cpu_ooo ties MA inputs low and drives both FP-valid inputs from commit.
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

  // Reads return zero when disabled or when no listed address matches.
  // For timing, decode each address nibble one-hot, then combine the
  // selects with read enable. Addresses must be distinct so the masked
  // OR equals an address mux. ReadCsrAddrs[k] corresponds to read_csr_value[k].
  logic [XLEN-1:0] csr_read_data_comb;
  localparam int unsigned NumReadCsrs = 42;
  localparam logic [12*NumReadCsrs-1:0] ReadCsrAddrs = {
    riscv_pkg::CsrDdata,  // 41
    riscv_pkg::CsrDscratch1,  // 40
    riscv_pkg::CsrDscratch0,  // 39
    riscv_pkg::CsrDpc,  // 38
    riscv_pkg::CsrDcsr,  // 37
    riscv_pkg::CsrMperfCount,  // 36
    riscv_pkg::CsrMperfDataH,  // 35
    riscv_pkg::CsrMperfData,  // 34
    riscv_pkg::CsrMperfSel,  // 33
    riscv_pkg::CsrStimecmp,  // 32
    riscv_pkg::CsrMenvcfg,  // 31
    riscv_pkg::CsrSatp,  // 30
    riscv_pkg::CsrStval,  // 29
    riscv_pkg::CsrScause,  // 28
    riscv_pkg::CsrSepc,  // 27
    riscv_pkg::CsrSscratch,  // 26
    riscv_pkg::CsrScounteren,  // 25
    riscv_pkg::CsrStvec,  // 24
    riscv_pkg::CsrSip,  // 23
    riscv_pkg::CsrSie,  // 22
    riscv_pkg::CsrSstatus,  // 21
    riscv_pkg::CsrMip,  // 20
    riscv_pkg::CsrMtval,  // 19
    riscv_pkg::CsrMcause,  // 18
    riscv_pkg::CsrMepc,  // 17
    riscv_pkg::CsrMscratch,  // 16
    riscv_pkg::CsrMcountinhibit,  // 15
    riscv_pkg::CsrMcounteren,  // 14
    riscv_pkg::CsrMtvec,  // 13
    riscv_pkg::CsrMie,  // 12
    riscv_pkg::CsrMideleg,  // 11
    riscv_pkg::CsrMedeleg,  // 10
    riscv_pkg::CsrMisa,  // 9
    riscv_pkg::CsrMstatus,  // 8
    riscv_pkg::CsrMinstret,  // 7
    riscv_pkg::CsrInstret,  // 6
    riscv_pkg::CsrTime,  // 5
    riscv_pkg::CsrMcycle,  // 4
    riscv_pkg::CsrCycle,  // 3
    riscv_pkg::CsrFcsr,  // 2
    riscv_pkg::CsrFrm,  // 1
    riscv_pkg::CsrFflags  // 0
  };
  (* keep = "true" *) logic [15:0] read_addr_hi_onehot, read_addr_mid_onehot, read_addr_lo_onehot;
  assign read_addr_hi_onehot  = 16'(1) << i_csr_address[11:8];
  assign read_addr_mid_onehot = 16'(1) << i_csr_address[7:4];
  assign read_addr_lo_onehot  = 16'(1) << i_csr_address[3:0];
  (* keep = "true" *) logic [NumReadCsrs-1:0] read_csr_select;
  for (genvar k = 0; k < int'(NumReadCsrs); k++) begin : gen_read_select
    localparam logic [11:0] Addr = ReadCsrAddrs[12*k+:12];
    assign read_csr_select[k] = i_csr_read_enable && read_addr_hi_onehot[Addr[11:8]] &&
        read_addr_mid_onehot[Addr[7:4]] && read_addr_lo_onehot[Addr[3:0]];
  end
  logic [XLEN-1:0] read_csr_value[NumReadCsrs];
  always_comb begin
    // F extension CSRs (with forwarding for pending flags).
    read_csr_value[0] = XLEN'({27'b0, fflags_forwarded});  // CsrFflags
    read_csr_value[1] = XLEN'({29'b0, frm});  // CsrFrm
    read_csr_value[2] = XLEN'({24'b0, frm, fflags_forwarded});  // CsrFcsr
    // Zicntr uses one 64-bit CSR per counter. ROB allocation rejects RV32
    // high-half addresses.
    read_csr_value[3] = XLEN'(cycle_counter[XLEN-1:0]);  // CsrCycle
    read_csr_value[4] = XLEN'(cycle_counter[XLEN-1:0]);  // CsrMcycle
    read_csr_value[5] = XLEN'(i_mtime[XLEN-1:0]);  // CsrTime
    read_csr_value[6] = XLEN'(instret_counter[XLEN-1:0]);  // CsrInstret
    read_csr_value[7] = XLEN'(instret_counter[XLEN-1:0]);  // CsrMinstret
    // Machine-mode CSRs.
    read_csr_value[8] = mstatus;  // CsrMstatus
    read_csr_value[9] = MisaValue;  // CsrMisa
    read_csr_value[10] = XLEN'(medeleg_q);  // CsrMedeleg
    read_csr_value[11] = mideleg;  // CsrMideleg
    read_csr_value[12] = mie;  // CsrMie
    read_csr_value[13] = mtvec;  // CsrMtvec
    read_csr_value[14] = XLEN'({29'b0, mcounteren_q});  // CsrMcounteren
    // CsrMcountinhibit
    read_csr_value[15] = XLEN'({29'b0, mcountinhibit_ir, 1'b0, mcountinhibit_cy});
    read_csr_value[16] = mscratch;  // CsrMscratch
    read_csr_value[17] = mepc;  // CsrMepc
    read_csr_value[18] = mcause;  // CsrMcause
    read_csr_value[19] = mtval;  // CsrMtval
    read_csr_value[20] = mip;  // CsrMip
    // Supervisor CSRs (views and dedicated registers).
    read_csr_value[21] = sstatus;  // CsrSstatus
    read_csr_value[22] = sie_view;  // CsrSie
    read_csr_value[23] = sip_view;  // CsrSip
    read_csr_value[24] = stvec;  // CsrStvec
    read_csr_value[25] = XLEN'({29'b0, scounteren_q});  // CsrScounteren
    read_csr_value[26] = sscratch;  // CsrSscratch
    read_csr_value[27] = sepc;  // CsrSepc
    read_csr_value[28] = scause;  // CsrScause
    read_csr_value[29] = stval;  // CsrStval
    read_csr_value[30] = satp;  // CsrSatp
    read_csr_value[31] = XLEN'(menvcfg_stce) << riscv_pkg::MenvcfgStceBit;  // CsrMenvcfg
    read_csr_value[32] = stimecmp;  // CsrStimecmp
    // The profiling data CSRs are 32-bit halves even at RV64 (software
    // reads them in pairs), zero-extended to the bus. With UsePerfCsrHalf
    // the half was selected upstream when the commit address was
    // registered. Without counters (PERF_COUNTERS = 0) these read zero.
    read_csr_value[33] = perf_counter_select;  // CsrMperfSel
    // CsrMperfData
    read_csr_value[34] = !PerfCountersPresent ? '0 :
        XLEN'(UsePerfCsrHalf ? i_perf_counter_csr_half : i_perf_counter_data[31:0]);
    // CsrMperfDataH
    read_csr_value[35] = !PerfCountersPresent ? '0 :
        XLEN'(UsePerfCsrHalf ? i_perf_counter_csr_half : i_perf_counter_data[63:32]);
    read_csr_value[36] = !PerfCountersPresent ? '0 : XLEN'(i_perf_counter_count);  // CsrMperfCount
    // Debug Mode CSRs.
    read_csr_value[37] = dcsr;  // CsrDcsr
    read_csr_value[38] = dpc;  // CsrDpc
    read_csr_value[39] = dscratch0;  // CsrDscratch0
    read_csr_value[40] = dscratch1;  // CsrDscratch1
    read_csr_value[41] = XLEN'(i_dbg_data);  // CsrDdata
  end
  always_comb begin
    csr_read_data_comb = '0;
    for (int k = 0; k < int'(NumReadCsrs); k++) begin
      csr_read_data_comb = csr_read_data_comb | ({XLEN{read_csr_select[k]}} & read_csr_value[k]);
    end
  end

  logic [XLEN-1:0] csr_read_data_reg;

  always_ff @(posedge i_clk) begin
    csr_read_data_reg <= csr_read_data_comb;
  end

  assign o_csr_read_data = csr_read_data_reg;
  assign o_csr_read_data_comb = csr_read_data_comb;
  assign o_perf_counter_select = perf_counter_select[7:0];
  assign o_perf_cache_previous_select = perf_cache_previous_select;
  assign o_perf_snapshot_capture = PerfCountersPresent && i_csr_write_enable &&
                                   i_csr_read_enable &&
                                   (i_csr_address == riscv_pkg::CsrMperfCtl) &&
                                   mperfctl_new_value[0];

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL
`ifndef CSR_COMMIT_LOCAL_PROOF

  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // A committed minstret write in the previous cycle, and the value it wrote.
  logic f_minstret_written_q = 1'b0;
  logic [XLEN-1:0] f_minstret_value_q;
  always @(posedge i_clk) begin
    f_minstret_written_q <= !i_rst && minstret_write;
    f_minstret_value_q   <= csr_new_value;
  end

  // Structural constraints
  always_comb begin
    assume (!(i_trap_taken && i_mret_taken));
    assume (!(i_trap_taken && i_sret_taken));
    // Debug Mode: DRET is one of the mutually exclusive xRETs and only
    // executes in Debug Mode (the ROB allocation check); a Debug Mode entry
    // never steers to S and never happens in Debug Mode (the trap unit
    // re-parks without a CSR write instead).
    assume (!(i_dret_taken && (i_trap_taken || i_mret_taken || i_sret_taken)));
    assume (!(i_dret_taken && i_csr_write_enable));
    assume (!(i_dret_taken && !debug_mode_q));
    assume (!(i_trap_taken && i_trap_to_d && i_trap_to_s));
    assume (!(i_trap_taken && i_trap_to_d && debug_mode_q));
    // The trap unit builds the entry enables from the same take as the trap
    // inputs.
    assume (i_trap_save_m == (i_trap_taken && !i_trap_to_d && !i_trap_to_s));
    assume (i_trap_save_s == (i_trap_taken && !i_trap_to_d && i_trap_to_s));
    assume (i_trap_enter_d == (i_trap_taken && i_trap_to_d));
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
    // commits in the same cycle (the FS Dirty-setting logic relies on this).
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
      // The fetch duplicate must equal architectural privilege.
      p_fetch_priv_replica_exact : assert (fetch_priv_q == priv_q);

      // Debug Mode entry: dpc/dcsr record the resume state, priv
      // becomes M, and no M/S trap-stack register moves.
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

      // A counter write replaces the increment; a pure read preserves it.
      // Write intent depends on the encoding, even with zero write data.
      p_counter_pure_read_is_not_a_write :
      assert (!($past(
          i_csr_write_enable && i_csr_read_enable && (i_csr_op[1:0] == 2'b00)
      ) && ($past(
          mcycle_write
      ) || $past(
          minstret_write
      ))));
      p_counter_zero_set_clear_is_a_write :
      assert (!$past(
          i_csr_write_enable && i_csr_read_enable && i_csr_op[1] && (i_csr_write_data == '0) &&
          (i_csr_address == riscv_pkg::CsrMinstret)
      ) || $past(
          minstret_write
      ));
      if ($past(mcycle_write)) begin
        p_mcycle_write : assert (cycle_counter == $past(csr_new_value));
      end else if ($past(mcountinhibit_cy)) begin
        p_cycle_inhibited : assert (cycle_counter == $past(cycle_counter));
      end else begin
        p_cycle_increments : assert (cycle_counter == $past(cycle_counter) + 64'd1);
      end

      // Staging preserves every count except those inhibited or replaced by
      // a minstret write. Without writes or inhibit:
      //   instret_counter(T) == instret_counter(T-1) + retired_count(T-2)
      // CSR serialization hides this delay; see Instructions Retired Counter.
      p_instret_stage_follows :
      assert (instruction_retired_count_q == (($past(
          mcountinhibit_ir
      ) || $past(
          minstret_write
      )) ? 2'd0 : $past(
          i_instruction_retired_count
      )));
      // Zicsr: the write takes the place of the writer's own increment, so
      // one edge after the write, with no second write, the counter still
      // holds the written value.
      if ($past(f_minstret_written_q) && !$past(minstret_write)) begin
        p_minstret_write_replaces_own_count : assert (instret_counter == $past(f_minstret_value_q));
      end
      if ($past(minstret_write)) begin
        p_minstret_write : assert (instret_counter == $past(csr_new_value));
      end else begin
        p_instret_applies_staged_count :
        assert (instret_counter == $past(
            instret_counter
        ) + 64'($past(
            instruction_retired_count_q
        )));
      end

      // mcountinhibit: a committed write installs {IR, CY} from
      // csr_new_value bits 2 and 0; nothing else changes it.
      if ($past(
              i_csr_write_enable && i_csr_read_enable &&
              (i_csr_address == riscv_pkg::CsrMcountinhibit)
          )) begin
        p_mcountinhibit_write :
        assert ({mcountinhibit_ir, mcountinhibit_cy} == {$past(
            csr_new_value[2]
        ), $past(
            csr_new_value[0]
        )});
      end else begin
        p_mcountinhibit_stable :
        assert ({mcountinhibit_ir, mcountinhibit_cy} == $past(
            {mcountinhibit_ir, mcountinhibit_cy}
        ));
      end

      // Without a CSR write or effective flag input, fflags stays unchanged.
      if ($past(
              !fp_flags_valid_eff && !(i_csr_write_enable && i_csr_read_enable &&
          (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFcsr))
          )) begin
        p_fflags_sticky : assert (fflags == $past(fflags));
      end

      // Only CSR writes change mcounteren; WARL discards bits above [2:0].
      if ($past(
              i_csr_write_enable && i_csr_read_enable && (i_csr_address == riscv_pkg::CsrMcounteren)
          )) begin
        p_mcounteren_write : assert (mcounteren_q == $past(csr_new_value[2:0]));
      end else begin
        p_mcounteren_stable : assert (mcounteren_q == $past(mcounteren_q));
      end

      // FP-state writes set Dirty. Status CSR writes install FS; trap entry
      // and xRET preserve it for the OS's context-save decision.
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

    // Check reset values on deassertion; $past(!i_rst) would be vacuous here.
    if (f_past_valid && !i_rst && $past(i_rst)) begin
      p_reset_cycle : assert (cycle_counter == 64'd0);
      p_reset_instret : assert (instret_counter == 64'd0);
      p_reset_instret_stage : assert (instruction_retired_count_q == 2'd0);
      p_reset_mie : assert (!mstatus_mie);
      p_reset_mpie : assert (!mstatus_mpie);
      p_reset_fflags : assert (fflags == 5'b0);
      p_reset_frm : assert (frm == 3'b0);
      p_reset_mcounteren : assert (mcounteren_q == 3'b111);
      p_reset_mcountinhibit : assert (!mcountinhibit_cy && !mcountinhibit_ir);
      p_reset_scounteren : assert (scounteren_q == 3'b111);
      // FS resets to Initial (not Off) so FP runs without OS setup.
      p_reset_fs : assert (mstatus_fs == FsInitial);
      p_reset_priv : assert (priv_q == riscv_pkg::PrivM);
      p_reset_fetch_priv : assert (fetch_priv_q == riscv_pkg::PrivM);
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

      // SD (mstatus top bit) mirrors FS==Dirty, and the exported gate
      // signal is exactly FS==Off.
      p_sd_mirrors_fs : assert (mstatus[XLEN-1] == (mstatus_fs == FsDirty));
      p_fs_off_export : assert (o_mstatus_fs_off == (mstatus_fs == FsOff));

      // mtvec MODE: bit 1 always 0, bit 0 can be 0 (Direct) or 1 (Vectored).
      p_mtvec_aligned : assert (mtvec[1] == 1'b0);
      // The registered misaligned-trap config bit mirrors the register.
      p_mtvec_traps_misaligned_mirror : assert (mtvec_traps_misaligned_q == (|mtvec[XLEN-1:2]));

      // mip's machine bits are read-only and reflect the inputs; the
      // supervisor SEIP/STIP readbacks compose the PLIC S-context line and
      // the Sstc compare with the software-injection registers.
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
      // sepc/stvec keep the same alignment invariants as mepc/mtvec.
      p_sepc_aligned : assert (sepc[0] == 1'b0);
      p_stvec_aligned : assert (stvec[1] == 1'b0);
      // satp invariants: ASID reads zero; the Bare-only check applies only
      // while SatpSv39Supported is 0.
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
      cover_mcountinhibit_set : cover (mcountinhibit_cy && mcountinhibit_ir);
      cover_mcycle_write : cover (f_past_valid && $past(mcycle_write));
      cover_minstret_write : cover (f_past_valid && $past(minstret_write));
      // FS reaches both interesting endpoints (Off makes FP illegal; Dirty
      // drives the SD mirror that the OS checks before saving FP state).
      cover_fs_off : cover (mstatus_fs == FsOff);
      cover_fs_dirty : cover (mstatus_fs == FsDirty);
      cover_fp_flags : cover (i_fp_flags_valid);
      cover_instret : cover (f_past_valid && instret_counter > 64'd0);
    end
  end

  // With PERF_COUNTERS=0, profiling outputs remain zero, including snapshot
  // pulses, and every mperf* read returns zero.
  generate
    if (PERF_COUNTERS == 0) begin : gen_formal_perf_off
      logic perf_csr_read;
      assign perf_csr_read = i_csr_read_enable &&
          (i_csr_address == riscv_pkg::CsrMperfSel ||
           i_csr_address == riscv_pkg::CsrMperfCtl ||
           i_csr_address == riscv_pkg::CsrMperfData ||
           i_csr_address == riscv_pkg::CsrMperfDataH ||
           i_csr_address == riscv_pkg::CsrMperfCount);
      always @(posedge i_clk) begin
        if (f_past_valid && !i_rst) begin
          p_perf_off_no_snapshot : assert (!o_perf_snapshot_capture);
          p_perf_off_select_zero : assert (o_perf_counter_select == '0);
          p_perf_off_bank_zero : assert (!o_perf_cache_previous_select);
          if (perf_csr_read) begin
            p_perf_off_reads_zero : assert (o_csr_read_data_comb == '0);
          end
          // The registered read port one cycle after an enabled mperf* read.
          if ($past(!i_rst) && $past(perf_csr_read)) begin
            p_perf_off_reg_reads_zero : assert (o_csr_read_data == '0);
          end
        end
      end
    end
  endgenerate

`endif  // CSR_COMMIT_LOCAL_PROOF
`endif  // FORMAL

`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (!i_rst) begin
      p_integrated_trap_enables_match_inputs :
      assert (i_trap_save_m == (i_trap_taken && !i_trap_to_d && !i_trap_to_s) &&
              i_trap_save_s == (i_trap_taken && !i_trap_to_d && i_trap_to_s) &&
              i_trap_enter_d == (i_trap_taken && i_trap_to_d));
    end
    if (!i_rst && COMMIT_EXCLUDES_CONTROL_TAKE) begin
      p_integrated_csr_excludes_control_take :
      assert (!(i_csr_write_enable && i_csr_read_enable &&
                (i_trap_taken || i_mret_taken || i_sret_taken || i_dret_taken)));
      // A minstret write stages zero in place of its cycle's retire count,
      // which must be the writing instruction alone.
      p_integrated_minstret_write_retires_alone :
      assert (!minstret_write || (i_instruction_retired_count == 2'd1));
    end
  end
`endif

`ifdef CSR_COMMIT_LOCAL_PROOF
  // Reference for csr_commit_cofactor: f_old_* uses generic take-over-write
  // priority, from the trap inputs, for counters, CSR storage, mstatus, mie,
  // privilege, Debug Mode state, and translation invalidation. f_csr_legal
  // requires the entry enables to match the trap inputs, as trap_unit and
  // cpu_ooo guarantee, and excludes coincident control takes and CSR commits
  // when COMMIT_EXCLUDES_CONTROL_TAKE is set. Under that condition, next state
  // and invalidation must match combinationally and stored values must match
  // after the edge.
  logic f_csr_legal;
  logic f_csr_ref_valid = 1'b0;
  logic f_old_counter_write, f_old_mcycle_write, f_old_minstret_write;
  logic f_old_translation_req;
  assign f_csr_legal =
      (i_trap_save_m == (i_trap_taken && !i_trap_to_d && !i_trap_to_s)) &&
      (i_trap_save_s == (i_trap_taken && !i_trap_to_d && i_trap_to_s)) &&
      (i_trap_enter_d == (i_trap_taken && i_trap_to_d)) &&
      (!COMMIT_EXCLUDES_CONTROL_TAKE ||
       !(i_csr_write_enable && i_csr_read_enable &&
         (i_trap_taken || i_mret_taken || i_sret_taken || i_dret_taken)));
  assign f_old_counter_write = i_csr_write_enable && i_csr_read_enable &&
      csr_write_intent && !(i_trap_taken && !i_trap_to_d);
  assign f_old_mcycle_write = f_old_counter_write && (i_csr_address == riscv_pkg::CsrMcycle);
  assign f_old_minstret_write = f_old_counter_write && (i_csr_address == riscv_pkg::CsrMinstret);
  assign f_old_translation_req = i_csr_write_enable && i_csr_read_enable &&
      ((i_csr_address == riscv_pkg::CsrSatp) ||
       (((i_csr_address == riscv_pkg::CsrMstatus) ||
         (i_csr_address == riscv_pkg::CsrSstatus)) &&
        ((f_old_next_mstatus_sum != mstatus_sum) ||
         (f_old_next_mstatus_mxr != mstatus_mxr) ||
         (f_old_next_mstatus_mprv != mstatus_mprv) ||
         (mstatus_mprv && (f_old_next_mstatus_mpp != mstatus_mpp)))));

  // mstatus, mie, and privilege next state: takes, then a CSR write.
  logic f_old_next_mstatus_mie, f_old_next_mstatus_mpie, f_old_next_mstatus_mprv;
  logic f_old_next_mstatus_sie, f_old_next_mstatus_spie, f_old_next_mstatus_spp;
  logic f_old_next_mstatus_sum, f_old_next_mstatus_mxr;
  logic f_old_next_mstatus_tvm, f_old_next_mstatus_tw, f_old_next_mstatus_tsr;
  logic [1:0] f_old_next_mstatus_mpp, f_old_next_mstatus_fs, f_old_next_priv;
  logic f_old_next_mie_msie, f_old_next_mie_mtie, f_old_next_mie_meie;
  logic f_old_next_mie_ssie, f_old_next_mie_stie, f_old_next_mie_seie;
  always_comb begin
    f_old_next_mstatus_mie = mstatus_mie;
    f_old_next_mstatus_mpie = mstatus_mpie;
    f_old_next_mstatus_mpp = mstatus_mpp;
    f_old_next_mstatus_mprv = mstatus_mprv;
    f_old_next_mstatus_fs = mstatus_fs;
    f_old_next_mstatus_sie = mstatus_sie;
    f_old_next_mstatus_spie = mstatus_spie;
    f_old_next_mstatus_spp = mstatus_spp;
    f_old_next_mstatus_sum = mstatus_sum;
    f_old_next_mstatus_mxr = mstatus_mxr;
    f_old_next_mstatus_tvm = mstatus_tvm;
    f_old_next_mstatus_tw = mstatus_tw;
    f_old_next_mstatus_tsr = mstatus_tsr;
    f_old_next_priv = priv_q;
    f_old_next_mie_msie = mie_msie;
    f_old_next_mie_mtie = mie_mtie;
    f_old_next_mie_meie = mie_meie;
    f_old_next_mie_ssie = mie_ssie;
    f_old_next_mie_stie = mie_stie;
    f_old_next_mie_seie = mie_seie;
    if (i_trap_taken && i_trap_to_d) begin
      f_old_next_priv = riscv_pkg::PrivM;
    end else if (i_trap_taken) begin
      if (i_trap_to_s) begin
        f_old_next_mstatus_spie = mstatus_sie;
        f_old_next_mstatus_sie  = 1'b0;
        f_old_next_mstatus_spp  = (priv_q == riscv_pkg::PrivS);
        f_old_next_priv         = riscv_pkg::PrivS;
      end else begin
        f_old_next_mstatus_mpie = mstatus_mie;
        f_old_next_mstatus_mie  = 1'b0;
        f_old_next_mstatus_mpp  = priv_q;
        f_old_next_priv         = riscv_pkg::PrivM;
      end
    end else if (i_mret_taken) begin
      f_old_next_mstatus_mie  = mstatus_mpie;
      f_old_next_mstatus_mpie = 1'b1;
      f_old_next_priv         = mstatus_mpp;
      if (mstatus_mpp != riscv_pkg::PrivM) f_old_next_mstatus_mprv = 1'b0;
      f_old_next_mstatus_mpp = riscv_pkg::PrivU;
    end else if (i_sret_taken) begin
      f_old_next_mstatus_sie  = mstatus_spie;
      f_old_next_mstatus_spie = 1'b1;
      f_old_next_priv         = mstatus_spp ? riscv_pkg::PrivS : riscv_pkg::PrivU;
      f_old_next_mstatus_spp  = 1'b0;
      f_old_next_mstatus_mprv = 1'b0;
    end else if (i_dret_taken) begin
      f_old_next_priv = dcsr_prv;
      if (dcsr_prv != riscv_pkg::PrivM) f_old_next_mstatus_mprv = 1'b0;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      if (i_csr_address == riscv_pkg::CsrMstatus) begin
        f_old_next_mstatus_sie = csr_new_value[riscv_pkg::MstatusSieBit];
        f_old_next_mstatus_mie = csr_new_value[3];
        f_old_next_mstatus_spie = csr_new_value[riscv_pkg::MstatusSpieBit];
        f_old_next_mstatus_mpie = csr_new_value[7];
        f_old_next_mstatus_spp = csr_new_value[riscv_pkg::MstatusSppBit];
        f_old_next_mstatus_mpp = (csr_new_value[12:11] == 2'b10) ? riscv_pkg::PrivU :
            csr_new_value[12:11];
        f_old_next_mstatus_mprv = csr_new_value[riscv_pkg::MstatusMprvBit];
        f_old_next_mstatus_sum = csr_new_value[riscv_pkg::MstatusSumBit];
        f_old_next_mstatus_mxr = csr_new_value[riscv_pkg::MstatusMxrBit];
        f_old_next_mstatus_tvm = csr_new_value[riscv_pkg::MstatusTvmBit];
        f_old_next_mstatus_tw = csr_new_value[riscv_pkg::MstatusTwBit];
        f_old_next_mstatus_tsr = csr_new_value[riscv_pkg::MstatusTsrBit];
        f_old_next_mstatus_fs = csr_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrSstatus) begin
        f_old_next_mstatus_sie  = csr_new_value[riscv_pkg::MstatusSieBit];
        f_old_next_mstatus_spie = csr_new_value[riscv_pkg::MstatusSpieBit];
        f_old_next_mstatus_spp  = csr_new_value[riscv_pkg::MstatusSppBit];
        f_old_next_mstatus_sum  = csr_new_value[riscv_pkg::MstatusSumBit];
        f_old_next_mstatus_mxr  = csr_new_value[riscv_pkg::MstatusMxrBit];
        f_old_next_mstatus_fs   = csr_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrMie) begin
        f_old_next_mie_ssie = csr_new_value[riscv_pkg::MieSsiBit];
        f_old_next_mie_msie = csr_new_value[3];
        f_old_next_mie_stie = csr_new_value[riscv_pkg::MieStiBit];
        f_old_next_mie_mtie = csr_new_value[7];
        f_old_next_mie_seie = csr_new_value[riscv_pkg::MieSeiBit];
        f_old_next_mie_meie = csr_new_value[11];
      end else if (i_csr_address == riscv_pkg::CsrSie) begin
        if (mideleg_ssi) f_old_next_mie_ssie = csr_new_value[riscv_pkg::MieSsiBit];
        if (mideleg_sti) f_old_next_mie_stie = csr_new_value[riscv_pkg::MieStiBit];
        if (mideleg_sei) f_old_next_mie_seie = csr_new_value[riscv_pkg::MieSeiBit];
      end
    end
    if ((i_csr_write_enable && i_csr_read_enable &&
         (i_csr_address == riscv_pkg::CsrFflags || i_csr_address == riscv_pkg::CsrFrm ||
          i_csr_address == riscv_pkg::CsrFcsr)) ||
        i_fp_dest_write || i_fp_flags_valid) begin
      f_old_next_mstatus_fs = FsDirty;
    end
  end

  // Debug Mode state: entry, DRET, then a CSR write.
  logic f_old_debug_mode_q, f_old_dcsr_ebreakm, f_old_dcsr_ebreaks, f_old_dcsr_ebreaku;
  logic f_old_dcsr_step;
  logic [$bits(dcsr_cause)-1:0] f_old_dcsr_cause;
  logic [$bits(dcsr_prv)-1:0] f_old_dcsr_prv;
  logic [$bits(dpc)-1:0] f_old_dpc, f_old_dscratch0, f_old_dscratch1;
  always_ff @(posedge i_clk) begin
    f_old_debug_mode_q <= debug_mode_q;
    f_old_dcsr_ebreakm <= dcsr_ebreakm;
    f_old_dcsr_ebreaks <= dcsr_ebreaks;
    f_old_dcsr_ebreaku <= dcsr_ebreaku;
    f_old_dcsr_step <= dcsr_step;
    f_old_dcsr_cause <= dcsr_cause;
    f_old_dcsr_prv <= dcsr_prv;
    f_old_dpc <= dpc;
    f_old_dscratch0 <= dscratch0;
    f_old_dscratch1 <= dscratch1;
    if (i_rst) begin
      f_old_debug_mode_q <= 1'b0;
      f_old_dcsr_ebreakm <= 1'b0;
      f_old_dcsr_ebreaks <= 1'b0;
      f_old_dcsr_ebreaku <= 1'b0;
      f_old_dcsr_step    <= 1'b0;
      f_old_dcsr_cause   <= 3'd0;
      f_old_dcsr_prv     <= riscv_pkg::PrivM;
      f_old_dpc          <= '0;
      f_old_dscratch0    <= '0;
      f_old_dscratch1    <= '0;
    end else if (i_trap_taken && i_trap_to_d) begin
      f_old_debug_mode_q <= 1'b1;
      f_old_dpc          <= {i_trap_pc[XLEN-1:1], 1'b0};
      f_old_dcsr_cause   <= i_trap_dbg_cause;
      f_old_dcsr_prv     <= priv_q;
    end else if (i_dret_taken) begin
      f_old_debug_mode_q <= 1'b0;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrDcsr: begin
          f_old_dcsr_ebreakm <= csr_new_value[riscv_pkg::DcsrEbreakMBit];
          f_old_dcsr_ebreaks <= csr_new_value[riscv_pkg::DcsrEbreakSBit];
          f_old_dcsr_ebreaku <= csr_new_value[riscv_pkg::DcsrEbreakUBit];
          f_old_dcsr_step <= csr_new_value[riscv_pkg::DcsrStepBit];
          f_old_dcsr_prv <= (csr_new_value[1:0] == 2'b10) ? riscv_pkg::PrivU : csr_new_value[1:0];
        end
        riscv_pkg::CsrDpc: f_old_dpc <= {csr_new_value[XLEN-1:1], 1'b0};
        riscv_pkg::CsrDscratch0: f_old_dscratch0 <= csr_new_value;
        riscv_pkg::CsrDscratch1: f_old_dscratch1 <= csr_new_value;
        default: ;
      endcase
    end
  end

  logic [$bits(cycle_counter)-1:0] f_old_cycle_counter;
  logic [$bits(instret_counter)-1:0] f_old_instret_counter;
  logic [$bits(instruction_retired_count_q)-1:0] f_old_instruction_retired_count_q;
  logic [$bits(mcause)-1:0] f_old_mcause;
  logic [$bits(mcounteren_q)-1:0] f_old_mcounteren_q;
  logic [$bits(mcountinhibit_cy)-1:0] f_old_mcountinhibit_cy;
  logic [$bits(mcountinhibit_ir)-1:0] f_old_mcountinhibit_ir;
  logic [$bits(medeleg_q)-1:0] f_old_medeleg_q;
  logic [$bits(menvcfg_stce)-1:0] f_old_menvcfg_stce;
  logic [$bits(mepc)-1:0] f_old_mepc;
  logic [$bits(mideleg_sei)-1:0] f_old_mideleg_sei;
  logic [$bits(mideleg_ssi)-1:0] f_old_mideleg_ssi;
  logic [$bits(mideleg_sti)-1:0] f_old_mideleg_sti;
  logic [$bits(mip_seip)-1:0] f_old_mip_seip;
  logic [$bits(mip_ssip)-1:0] f_old_mip_ssip;
  logic [$bits(mip_stip)-1:0] f_old_mip_stip;
  logic [$bits(mscratch)-1:0] f_old_mscratch;
  logic [$bits(mtval)-1:0] f_old_mtval;
  logic [$bits(mtvec)-1:0] f_old_mtvec;
  logic [$bits(mtvec_traps_misaligned_q)-1:0] f_old_mtvec_traps_misaligned_q;
  logic [$bits(perf_cache_previous_select)-1:0] f_old_perf_cache_previous_select;
  logic [$bits(perf_counter_select)-1:0] f_old_perf_counter_select;
  logic [$bits(satp_mode_sv39)-1:0] f_old_satp_mode_sv39;
  logic [$bits(satp_ppn)-1:0] f_old_satp_ppn;
  logic [$bits(scause)-1:0] f_old_scause;
  logic [$bits(scounteren_q)-1:0] f_old_scounteren_q;
  logic [$bits(sepc)-1:0] f_old_sepc;
  logic [$bits(sscratch)-1:0] f_old_sscratch;
  logic [$bits(stimecmp)-1:0] f_old_stimecmp;
  logic [$bits(stval)-1:0] f_old_stval;
  logic [$bits(stvec)-1:0] f_old_stvec;

  always_ff @(posedge i_clk) begin
    f_old_cycle_counter <= cycle_counter;

    if (i_rst) begin
      f_old_cycle_counter <= 64'd0;
    end else if (f_old_mcycle_write) begin
      f_old_cycle_counter <= csr_new_value;
    end else if (!mcountinhibit_cy) begin
      f_old_cycle_counter <= cycle_counter_incremented;
    end
  end

  always_ff @(posedge i_clk) begin
    f_old_instret_counter <= instret_counter;
    f_old_instruction_retired_count_q <= instruction_retired_count_q;

    if (i_rst) begin
      f_old_instruction_retired_count_q <= 2'd0;
      f_old_instret_counter <= 64'd0;
    end else begin
      f_old_instruction_retired_count_q <= (mcountinhibit_ir || f_old_minstret_write) ? 2'd0 :
                                           i_instruction_retired_count;
      f_old_instret_counter <= f_old_minstret_write ? csr_new_value : instret_counter_accumulated;
    end
  end

  always_ff @(posedge i_clk) begin
    f_old_mcause <= mcause;
    f_old_mcounteren_q <= mcounteren_q;
    f_old_mcountinhibit_cy <= mcountinhibit_cy;
    f_old_mcountinhibit_ir <= mcountinhibit_ir;
    f_old_medeleg_q <= medeleg_q;
    f_old_menvcfg_stce <= menvcfg_stce;
    f_old_mepc <= mepc;
    f_old_mideleg_sei <= mideleg_sei;
    f_old_mideleg_ssi <= mideleg_ssi;
    f_old_mideleg_sti <= mideleg_sti;
    f_old_mip_seip <= mip_seip;
    f_old_mip_ssip <= mip_ssip;
    f_old_mip_stip <= mip_stip;
    f_old_mscratch <= mscratch;
    f_old_mtval <= mtval;
    f_old_mtvec <= mtvec;
    f_old_mtvec_traps_misaligned_q <= mtvec_traps_misaligned_q;
    f_old_perf_cache_previous_select <= perf_cache_previous_select;
    f_old_perf_counter_select <= perf_counter_select;
    f_old_satp_mode_sv39 <= satp_mode_sv39;
    f_old_satp_ppn <= satp_ppn;
    f_old_scause <= scause;
    f_old_scounteren_q <= scounteren_q;
    f_old_sepc <= sepc;
    f_old_sscratch <= sscratch;
    f_old_stimecmp <= stimecmp;
    f_old_stval <= stval;
    f_old_stvec <= stvec;

    if (i_rst) begin
      f_old_mtvec                      <= '0;
      f_old_mtvec_traps_misaligned_q   <= 1'b0;
      f_old_mcounteren_q               <= 3'b111;
      f_old_mcountinhibit_cy           <= 1'b0;
      f_old_mcountinhibit_ir           <= 1'b0;
      f_old_mscratch                   <= '0;
      f_old_mepc                       <= '0;
      f_old_mcause                     <= '0;
      f_old_mtval                      <= '0;
      f_old_stvec                      <= '0;
      f_old_scounteren_q               <= 3'b111;
      f_old_sscratch                   <= '0;
      f_old_sepc                       <= '0;
      f_old_scause                     <= '0;
      f_old_stval                      <= '0;
      f_old_medeleg_q                  <= '0;
      f_old_mideleg_ssi                <= 1'b0;
      f_old_mideleg_sti                <= 1'b0;
      f_old_mideleg_sei                <= 1'b0;
      f_old_mip_ssip                   <= 1'b0;
      f_old_mip_stip                   <= 1'b0;
      f_old_mip_seip                   <= 1'b0;
      f_old_satp_mode_sv39             <= 1'b0;
      f_old_satp_ppn                   <= '0;
      f_old_menvcfg_stce               <= 1'b0;
      f_old_stimecmp                   <= 64'hFFFF_FFFF_FFFF_FFFF;
      f_old_perf_counter_select        <= '0;
      f_old_perf_cache_previous_select <= 1'b0;
    end else if (i_trap_taken && !i_trap_to_d) begin
      // Trap entry: save state on the target-mode side only. A Debug Mode
      // entry saves dpc/dcsr instead, outside this model.
      if (i_trap_to_s) begin
        f_old_sepc   <= i_trap_pc;
        f_old_scause <= i_trap_cause;
        f_old_stval  <= i_trap_value;
      end else begin
        f_old_mepc   <= i_trap_pc;
        f_old_mcause <= i_trap_cause;
        f_old_mtval  <= i_trap_value;
      end
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrMtvec: begin
          f_old_mtvec                    <= {mtvec_new_value[XLEN-1:2], 1'b0, mtvec_new_value[0]};
          f_old_mtvec_traps_misaligned_q <= |mtvec_new_value[XLEN-1:2];
        end
        riscv_pkg::CsrMcounteren: f_old_mcounteren_q <= csr_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrMcountinhibit: begin  // WARL: CY and IR only (TM/HPM bits read 0)
          f_old_mcountinhibit_cy <= csr_new_value[0];
          f_old_mcountinhibit_ir <= csr_new_value[2];
        end
        riscv_pkg::CsrMscratch: f_old_mscratch <= csr_new_value;
        riscv_pkg::CsrMepc:
        f_old_mepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C ext
        riscv_pkg::CsrMcause: f_old_mcause <= csr_new_value;
        riscv_pkg::CsrMtval: f_old_mtval <= csr_new_value;
        riscv_pkg::CsrMedeleg:
        f_old_medeleg_q <= csr_new_value[15:0] & riscv_pkg::MedelegMask[15:0];
        riscv_pkg::CsrMideleg: begin
          f_old_mideleg_ssi <= csr_new_value[riscv_pkg::MieSsiBit];
          f_old_mideleg_sti <= csr_new_value[riscv_pkg::MieStiBit];
          f_old_mideleg_sei <= csr_new_value[riscv_pkg::MieSeiBit];
        end
        // mip: the machine bits are read-only (input reflections); the
        // supervisor pending bits are the M-mode software-injection state.
        riscv_pkg::CsrMip: begin
          f_old_mip_ssip <= csr_new_value[riscv_pkg::MieSsiBit];
          f_old_mip_stip <= csr_new_value[riscv_pkg::MieStiBit];
          f_old_mip_seip <= csr_new_value[riscv_pkg::MieSeiBit];
        end
        // sip: SSIP is the only S-writable pending bit, and only where
        // delegated (the RMW base was the masked view, so set/clear forms
        // cannot leak through a non-delegated bit either).
        riscv_pkg::CsrSip: begin
          if (mideleg_ssi) f_old_mip_ssip <= csr_new_value[riscv_pkg::MieSsiBit];
        end
        riscv_pkg::CsrStvec: f_old_stvec <= {csr_new_value[XLEN-1:2], 1'b0, csr_new_value[0]};
        riscv_pkg::CsrScounteren: f_old_scounteren_q <= csr_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrSscratch: f_old_sscratch <= csr_new_value;
        riscv_pkg::CsrSepc: f_old_sepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C
        riscv_pkg::CsrScause: f_old_scause <= csr_new_value;
        riscv_pkg::CsrStval: f_old_stval <= csr_new_value;
        // satp: a write carrying an unsupported MODE leaves the whole
        // register unchanged (privileged-spec rule). ASID is WARL-0; the
        // PPN field stores all written bits.
        riscv_pkg::CsrSatp: begin
          if (csr_new_value[63:60] == SatpModeBare) begin
            f_old_satp_mode_sv39 <= 1'b0;
            f_old_satp_ppn <= csr_new_value[SatpPpnBits-1:0];
          end else if (SatpSv39Supported && (csr_new_value[63:60] == SatpModeSv39)) begin
            f_old_satp_mode_sv39 <= 1'b1;
            f_old_satp_ppn <= csr_new_value[SatpPpnBits-1:0];
          end
        end
        // Sstc: menvcfg implements STCE only (the rest stays WARL-0);
        // stimecmp is the full 64-bit compare value.
        riscv_pkg::CsrMenvcfg: f_old_menvcfg_stce <= csr_new_value[riscv_pkg::MenvcfgStceBit];
        riscv_pkg::CsrStimecmp: f_old_stimecmp <= csr_new_value;
        // Without counters the profiling state keeps its reset value.
        riscv_pkg::CsrMperfSel: if (PerfCountersPresent) f_old_perf_counter_select <= csr_new_value;
        riscv_pkg::CsrMperfCtl:
        if (PerfCountersPresent && csr_write_intent)
          f_old_perf_cache_previous_select <= csr_new_value[1];
        default: ;
      endcase
    end
  end

  always_ff @(posedge i_clk) f_csr_ref_valid <= f_csr_legal;
  always_comb begin
    if (f_csr_legal) begin
      assert (csr_translation_flush_req_d == f_old_translation_req);
      assert ({next_mstatus_mie, next_mstatus_mpie, next_mstatus_mpp, next_mstatus_mprv,
               next_mstatus_fs, next_mstatus_sie, next_mstatus_spie, next_mstatus_spp,
               next_mstatus_sum, next_mstatus_mxr, next_mstatus_tvm, next_mstatus_tw,
               next_mstatus_tsr} ==
              {f_old_next_mstatus_mie, f_old_next_mstatus_mpie, f_old_next_mstatus_mpp,
               f_old_next_mstatus_mprv, f_old_next_mstatus_fs, f_old_next_mstatus_sie,
               f_old_next_mstatus_spie, f_old_next_mstatus_spp, f_old_next_mstatus_sum,
               f_old_next_mstatus_mxr, f_old_next_mstatus_tvm, f_old_next_mstatus_tw,
               f_old_next_mstatus_tsr});
      assert (next_priv == f_old_next_priv);
      assert ({next_mie_msie, next_mie_mtie, next_mie_meie, next_mie_ssie, next_mie_stie,
               next_mie_seie} ==
              {f_old_next_mie_msie, f_old_next_mie_mtie, f_old_next_mie_meie,
               f_old_next_mie_ssie, f_old_next_mie_stie, f_old_next_mie_seie});
    end
    if (f_csr_ref_valid) begin
      assert (debug_mode_q == f_old_debug_mode_q);
      assert ({dcsr_ebreakm, dcsr_ebreaks, dcsr_ebreaku, dcsr_step} ==
              {f_old_dcsr_ebreakm, f_old_dcsr_ebreaks, f_old_dcsr_ebreaku, f_old_dcsr_step});
      assert (dcsr_cause == f_old_dcsr_cause);
      assert (dcsr_prv == f_old_dcsr_prv);
      assert (dpc == f_old_dpc);
      assert (dscratch0 == f_old_dscratch0);
      assert (dscratch1 == f_old_dscratch1);
      assert (cycle_counter == f_old_cycle_counter);
      assert (instret_counter == f_old_instret_counter);
      assert (instruction_retired_count_q == f_old_instruction_retired_count_q);
      assert (mcause == f_old_mcause);
      assert (mcounteren_q == f_old_mcounteren_q);
      assert (mcountinhibit_cy == f_old_mcountinhibit_cy);
      assert (mcountinhibit_ir == f_old_mcountinhibit_ir);
      assert (medeleg_q == f_old_medeleg_q);
      assert (menvcfg_stce == f_old_menvcfg_stce);
      assert (mepc == f_old_mepc);
      assert (mideleg_sei == f_old_mideleg_sei);
      assert (mideleg_ssi == f_old_mideleg_ssi);
      assert (mideleg_sti == f_old_mideleg_sti);
      assert (mip_seip == f_old_mip_seip);
      assert (mip_ssip == f_old_mip_ssip);
      assert (mip_stip == f_old_mip_stip);
      assert (mscratch == f_old_mscratch);
      assert (mtval == f_old_mtval);
      assert (mtvec == f_old_mtvec);
      assert (mtvec_traps_misaligned_q == f_old_mtvec_traps_misaligned_q);
      assert (perf_cache_previous_select == f_old_perf_cache_previous_select);
      assert (perf_counter_select == f_old_perf_counter_select);
      assert (satp_mode_sv39 == f_old_satp_mode_sv39);
      assert (satp_ppn == f_old_satp_ppn);
      assert (scause == f_old_scause);
      assert (scounteren_q == f_old_scounteren_q);
      assert (sepc == f_old_sepc);
      assert (sscratch == f_old_sscratch);
      assert (stimecmp == f_old_stimecmp);
      assert (stval == f_old_stval);
      assert (stvec == f_old_stvec);
    end
  end
`endif

endmodule : csr_file
