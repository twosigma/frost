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
  CSR (Control and Status Register) File for RISC-V Zicsr + Zicntr + Machine/User-mode +
  F extensions, plus custom machine CSRs for Tomasulo performance profiling.

  This module implements:

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
  any privilege (enforced at the reorder-buffer head).
  U-mode access to the 0xCxx counter CSRs is gated by mcounteren; the
  illegal-instruction check itself lives at the reorder-buffer head (the
  ROB folds it into its privilege-fault term using o_mcounteren), so this
  module only stores the register and exports its value.

  Machine-mode CSRs (for trap/interrupt handling; M and U privilege modes):
    - mstatus (0x300): Machine status (MIE, MPIE bits; MPP WARL field {M, U};
      MPRV bit, inert; FS [14:13] writable with hardware Dirty-setting and SD
      mirroring FS==Dirty at the top bit — D15; resets to FS=Initial)
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

    // Trap entry signals (from trap unit)
    input logic            i_trap_taken,  // Trap is being taken
    input logic [XLEN-1:0] i_trap_pc,     // PC to save to mepc
    input logic [XLEN-1:0] i_trap_cause,  // Cause to save to mcause
    input logic [XLEN-1:0] i_trap_value,  // Value to save to mtval

    // MRET signal (from trap unit)
    input logic i_mret_taken,  // MRET is being executed

    // CSR outputs for trap/interrupt handling
    output logic [XLEN-1:0] o_mstatus,
    output logic [XLEN-1:0] o_mie,
    output logic [XLEN-1:0] o_mtvec,
    output logic [XLEN-1:0] o_mepc,

    // Direct output of mstatus MIE bit for timing and simpler consumers.
    output logic o_mstatus_mie_direct,

    // Current privilege mode (PrivM/PrivU): consumed by trap_unit (interrupt
    // enable while in U) and the commit-time ECALL cause select. Changes only
    // on trap entry and MRET.
    output logic [1:0] o_priv,

    // mcounteren counter-enable bits ([0]=CY/cycle, [1]=TM/time,
    // [2]=IR/instret): consumed by the reorder buffer's U-mode counter-CSR
    // illegal-instruction gate. Changes only on a committed CSR write.
    output logic [2:0] o_mcounteren,

    // D15: mstatus.FS == Off. Consumed by the reorder buffer's FP-op
    // illegal-instruction gate at commit. Changes only on a committed CSR
    // write (Dirty-setting only moves it further from Off).
    output logic o_mstatus_fs_off,

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
  logic [1:0] mstatus_mpp;  // Previous Privilege [12:11]; WARL {PrivM,PrivU}
  logic       mstatus_mprv;  // Modify PRiV (bit 17); stored but inert (no PMP/MMU)
  // FS [14:13] (D15): FP context status. Writable 2-bit field; hardware
  // sets Dirty on any FP architectural-state write (FP regfile dest,
  // FP-flag accrual, fflags/frm/fcsr CSR write); FP instructions raise
  // illegal-instruction when Off (the reorder buffer's head gate consumes
  // o_mstatus_fs_off). Resets to Initial so FP works without OS setup.
  logic [1:0] mstatus_fs;
  localparam logic [1:0] FsOff = 2'b00;
  localparam logic [1:0] FsInitial = 2'b01;
  localparam logic [1:0] FsDirty = 2'b11;
  logic fs_dirty;
  assign fs_dirty = (mstatus_fs == FsDirty);
  logic [     1:0] priv_q;  // Current privilege mode (resets to PrivM)
  logic [XLEN-1:0] mstatus;  // Constructed from the fields above
  logic [    31:0] mstatus_low;
  // Low-word field map (bit 31 stays 0 here; SD is applied per-XLEN below).
  assign mstatus_low = {
    1'b0,
    13'b0,
    mstatus_mprv,
    2'b0,
    mstatus_fs,
    mstatus_mpp,
    3'b0,
    mstatus_mpie,
    3'b0,
    mstatus_mie,
    3'b0
  };
  generate
    if (XLEN == 64) begin : gen_mstatus64
      // RV64 layout: SD (FS==Dirty mirror, D15) at 63, UXL hardwired to
      // 2 (UXLEN=64) at [33:32]; the low word keeps the RV32 field map
      // with bit 31 reserved-0.
      assign mstatus = {fs_dirty, 29'b0, 2'd2, mstatus_low};
    end else begin : gen_mstatus32
      // RV32 layout: SD (FS==Dirty mirror) at 31.
      assign mstatus = {fs_dirty, mstatus_low[30:0]};
    end
  endgenerate
  assign o_priv = priv_q;
  assign o_mstatus_fs_off = (mstatus_fs == FsOff);

  // mie CSR: store each interrupt enable as separate register
  logic mie_msie;  // Machine Software Interrupt Enable (bit 3)
  logic mie_mtie;  // Machine Timer Interrupt Enable (bit 7)
  logic mie_meie;  // Machine External Interrupt Enable (bit 11)
  logic [XLEN-1:0] mie;  // Constructed from individual enables
  assign mie = XLEN'({20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0});

  // Next-state signals for mstatus bits (computed combinationally)
  logic next_mstatus_mie;
  logic next_mstatus_mpie;
  logic [1:0] next_mstatus_mpp;
  logic next_mstatus_mprv;
  logic [1:0] next_mstatus_fs;
  logic [1:0] next_priv;
  // Next-state signals for mie bits
  logic next_mie_msie;
  logic next_mie_mtie;
  logic next_mie_meie;

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

  // mip is read-only and directly reflects interrupt inputs
  logic [XLEN-1:0] mip;
  assign mip = XLEN'({
    20'b0, i_interrupts.meip, 3'b0, i_interrupts.mtip, 3'b0, i_interrupts.msip, 3'b0
  });

  // misa is read-only: IMAFDC + B + U (= GCB with User mode) at either
  // width. Bit 0 (A), Bit 1 (B), Bit 2 (C), Bit 3 (D), Bit 5 (F),
  // Bit 8 (I), Bit 12 (M), Bit 20 (U) = 0x0010_112F; MXL sits in the top
  // two bits (1 = 32-bit at [31:30], 2 = 64-bit at [63:62]).
  localparam logic [XLEN-1:0] MisaValue =
      (XLEN == 64) ? XLEN'(64'h8000_0000_0010_112F) : XLEN'(32'h4010_112F);

  // Output CSRs for trap unit
  assign o_mstatus = mstatus;
  assign o_mie = mie;
  assign o_mtvec = mtvec;
  assign o_mepc = mepc;

  // Direct output of mstatus_mie register bypasses full-word CSR concatenation.
  assign o_mstatus_mie_direct = mstatus_mie;

  // ==========================================================================
  // CSR Write Data Calculation
  // ==========================================================================

  logic [XLEN-1:0] csr_current_value;
  logic [XLEN-1:0] csr_new_value;

  // Get current value of addressed CSR (for read-modify-write operations)
  always_comb begin
    csr_current_value = '0;
    unique case (i_csr_address)
      // F extension CSRs
      riscv_pkg::CsrFflags:     csr_current_value = XLEN'({27'b0, fflags});
      riscv_pkg::CsrFrm:        csr_current_value = XLEN'({29'b0, frm});
      riscv_pkg::CsrFcsr:       csr_current_value = fcsr;
      // Machine-mode CSRs
      riscv_pkg::CsrMstatus:    csr_current_value = mstatus;
      riscv_pkg::CsrMie:        csr_current_value = mie;
      riscv_pkg::CsrMtvec:      csr_current_value = mtvec;
      riscv_pkg::CsrMcounteren: csr_current_value = XLEN'({29'b0, mcounteren_q});
      riscv_pkg::CsrMscratch:   csr_current_value = mscratch;
      riscv_pkg::CsrMepc:       csr_current_value = mepc;
      riscv_pkg::CsrMcause:     csr_current_value = mcause;
      riscv_pkg::CsrMtval:      csr_current_value = mtval;
      riscv_pkg::CsrMperfSel:   csr_current_value = perf_counter_select;
      default:                  csr_current_value = '0;
    endcase
  end

  // Calculate new value based on CSR operation
  always_comb begin
    csr_new_value = csr_current_value;
    unique case (i_csr_op)
      riscv_pkg::CSR_RW, riscv_pkg::CSR_RWI: csr_new_value = i_csr_write_data;
      riscv_pkg::CSR_RS, riscv_pkg::CSR_RSI: csr_new_value = csr_current_value | i_csr_write_data;
      riscv_pkg::CSR_RC, riscv_pkg::CSR_RCI: csr_new_value = csr_current_value & ~i_csr_write_data;
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
    next_priv = priv_q;
    next_mie_msie = mie_msie;
    next_mie_mtie = mie_mtie;
    next_mie_meie = mie_meie;

    if (i_trap_taken) begin
      // Trap entry: save MIE->MPIE, clear MIE, save priv->MPP, enter M-mode.
      // FS is untouched: the trap-time image is exactly what the OS reads
      // to decide whether FP state needs saving (D15 / Linux fstate_save).
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
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      if (i_csr_address == riscv_pkg::CsrMstatus) begin
        next_mstatus_mie = csr_new_value[3];
        next_mstatus_mpie = csr_new_value[7];
        // MPP is WARL: FROST implements only M and U, so fold S/reserved -> U.
        next_mstatus_mpp  = (csr_new_value[12:11] == riscv_pkg::PrivM) ?
            riscv_pkg::PrivM : riscv_pkg::PrivU;
        next_mstatus_mprv = csr_new_value[17];
        // FS is WARL with all four values storable (Off/Initial/Clean/Dirty).
        next_mstatus_fs = csr_new_value[14:13];
      end else if (i_csr_address == riscv_pkg::CsrMie) begin
        next_mie_msie = csr_new_value[3];
        next_mie_mtie = csr_new_value[7];
        next_mie_meie = csr_new_value[11];
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
      priv_q <= riscv_pkg::PrivM;
      mie_msie <= 1'b0;
      mie_mtie <= 1'b0;
      mie_meie <= 1'b0;
    end else begin
      mstatus_mie <= next_mstatus_mie;
      mstatus_mpie <= next_mstatus_mpie;
      mstatus_mpp <= next_mstatus_mpp;
      mstatus_mprv <= next_mstatus_mprv;
      mstatus_fs <= next_mstatus_fs;
      priv_q <= next_priv;
      mie_msie <= next_mie_msie;
      mie_mtie <= next_mie_mtie;
      mie_meie <= next_mie_meie;
    end
  end

  // ==========================================================================
  // Other Machine-Mode CSR Updates
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mtvec                      <= '0;
      mcounteren_q               <= 3'b111;
      mscratch                   <= '0;
      mepc                       <= '0;
      mcause                     <= '0;
      mtval                      <= '0;
      perf_counter_select        <= '0;
      perf_cache_previous_select <= 1'b0;
    end else if (i_trap_taken) begin
      // Trap entry: save state
      mepc   <= i_trap_pc;
      mcause <= i_trap_cause;
      mtval  <= i_trap_value;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrMtvec: mtvec <= {csr_new_value[XLEN-1:2], 1'b0, csr_new_value[0]};
        riscv_pkg::CsrMcounteren: mcounteren_q <= csr_new_value[2:0];  // WARL: CY/TM/IR only
        riscv_pkg::CsrMscratch: mscratch <= csr_new_value;
        riscv_pkg::CsrMepc: mepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C ext
        riscv_pkg::CsrMcause: mcause <= csr_new_value;
        riscv_pkg::CsrMtval: mtval <= csr_new_value;
        riscv_pkg::CsrMperfSel: perf_counter_select <= csr_new_value;
        riscv_pkg::CsrMperfCtl: perf_cache_previous_select <= csr_new_value[1];
        default: ;
      endcase
    end
  end

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
        // Zicntr counters (read-only, user-mode and machine-mode aliases).
        // At XLEN=64 they are single 64-bit CSRs; the high-half addresses
        // raise illegal-instruction at the ROB head before any read, so
        // their arms exist only at XLEN=32.
        riscv_pkg::CsrCycle, riscv_pkg::CsrMcycle:
        csr_read_data_comb = XLEN'(cycle_counter[XLEN-1:0]);
        riscv_pkg::CsrTime: csr_read_data_comb = XLEN'(i_mtime[XLEN-1:0]);
        riscv_pkg::CsrInstret, riscv_pkg::CsrMinstret:
        csr_read_data_comb = XLEN'(instret_counter[XLEN-1:0]);
        riscv_pkg::CsrCycleH, riscv_pkg::CsrMcycleH:
        if (XLEN == 32) csr_read_data_comb = XLEN'(cycle_counter[63:32]);
        riscv_pkg::CsrTimeH: if (XLEN == 32) csr_read_data_comb = XLEN'(i_mtime[63:32]);
        riscv_pkg::CsrInstretH, riscv_pkg::CsrMinstretH:
        if (XLEN == 32) csr_read_data_comb = XLEN'(instret_counter[63:32]);
        // Machine-mode CSRs
        riscv_pkg::CsrMstatus: csr_read_data_comb = mstatus;
        riscv_pkg::CsrMisa: csr_read_data_comb = MisaValue;
        riscv_pkg::CsrMie: csr_read_data_comb = mie;
        riscv_pkg::CsrMtvec: csr_read_data_comb = mtvec;
        riscv_pkg::CsrMcounteren: csr_read_data_comb = XLEN'({29'b0, mcounteren_q});
        riscv_pkg::CsrMscratch: csr_read_data_comb = mscratch;
        riscv_pkg::CsrMepc: csr_read_data_comb = mepc;
        riscv_pkg::CsrMcause: csr_read_data_comb = mcause;
        riscv_pkg::CsrMtval: csr_read_data_comb = mtval;
        riscv_pkg::CsrMip: csr_read_data_comb = mip;
        riscv_pkg::CsrMperfSel: csr_read_data_comb = perf_counter_select;
        riscv_pkg::CsrMperfCtl: csr_read_data_comb = '0;
        riscv_pkg::CsrMperfData: csr_read_data_comb = i_perf_counter_data[31:0];
        riscv_pkg::CsrMperfDataH: csr_read_data_comb = i_perf_counter_data[63:32];
        riscv_pkg::CsrMperfCount: csr_read_data_comb = i_perf_counter_count;
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
    assume (!(i_trap_taken && i_csr_write_enable));
    assume (!(i_mret_taken && i_csr_write_enable));
    // PCs are at least 2-byte aligned (compressed extension minimum)
    assume (i_trap_pc[0] == 1'b0);
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // Trap saves state: after trap entry, mepc/mcause/mtval are saved.
      if ($past(i_trap_taken)) begin
        p_trap_saves_mepc : assert (mepc == $past(i_trap_pc));
        p_trap_saves_mcause : assert (mcause == $past(i_trap_cause));
        p_trap_saves_mtval : assert (mtval == $past(i_trap_value));
      end

      // Trap clears MIE: after trap, MIE is cleared and MPIE saves old MIE.
      if ($past(i_trap_taken)) begin
        p_trap_clears_mie : assert (!mstatus_mie);
        p_trap_saves_mpie : assert (mstatus_mpie == $past(mstatus_mie));
      end

      // MRET restores MIE: after MRET, MIE = old MPIE, MPIE = 1.
      if ($past(i_mret_taken)) begin
        p_mret_restores_mie : assert (mstatus_mie == $past(mstatus_mpie));
        p_mret_sets_mpie : assert (mstatus_mpie);
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
    end

    if (!i_rst) begin
      // mepc alignment: bit 0 always clear (2-byte aligned for C extension).
      p_mepc_aligned : assert (mepc[0] == 1'b0);

      // mtvec MODE: bit 1 always 0, bit 0 can be 0 (Direct) or 1 (Vectored).
      p_mtvec_aligned : assert (mtvec[1] == 1'b0);

      // mip is read-only and reflects inputs.
      p_mip_reflects_inputs :
      assert (mip == {20'b0, i_interrupts.meip, 3'b0,
          i_interrupts.mtip, 3'b0, i_interrupts.msip, 3'b0});
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_trap_entry : cover (f_past_valid && $past(i_trap_taken));
      cover_mret : cover (f_past_valid && $past(i_mret_taken));
      cover_csr_write : cover (i_csr_write_enable && i_csr_read_enable);
      cover_mcounteren_cleared : cover (mcounteren_q == 3'b000);
      cover_fp_flags : cover (i_fp_flags_valid);
      cover_instret : cover (f_past_valid && instret_counter > 64'd0);
    end
  end

`endif  // FORMAL

endmodule : csr_file
