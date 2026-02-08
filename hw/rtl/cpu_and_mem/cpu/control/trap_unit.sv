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
 * Trap Unit - Machine-mode exception and interrupt handling
 *
 * This module implements the RISC-V privileged architecture trap mechanism,
 * supporting both synchronous exceptions and asynchronous interrupts.
 *
 * Responsibilities:
 * =================
 *   - Exception detection from EX stage (ECALL, EBREAK, misaligned access)
 *   - Interrupt prioritization and masking
 *   - Trap entry: save state, redirect to mtvec
 *   - Trap exit (MRET): restore state, return to mepc
 *   - WFI: stall until interrupt pending
 *
 * Trap Priority (highest to lowest):
 * ==================================
 *   1. External interrupt (MEIP && MEIE && MIE)
 *   2. Software interrupt (MSIP && MSIE && MIE)
 *   3. Timer interrupt   (MTIP && MTIE && MIE)
 *   4. Synchronous exceptions (ECALL, EBREAK, etc.)
 *
 * Trap Entry Sequence:
 * ====================
 *   1. Save PC to mepc (PC of interrupted/faulting instruction)
 *   2. Save cause to mcause (interrupt bit + cause code)
 *   3. Save trap value to mtval (faulting address or instruction)
 *   4. Clear mstatus.MIE, save to mstatus.MPIE
 *   5. Jump to mtvec (direct or vectored mode)
 *   6. Flush pipeline (2 cycles)
 *
 * Trap Exit Sequence (MRET):
 * ==========================
 *   1. Restore mstatus.MIE from mstatus.MPIE
 *   2. Set mstatus.MPIE to 1
 *   3. Jump to mepc (return address)
 *   4. Flush pipeline (2 cycles)
 *
 * mtvec Modes:
 * ============
 *   MODE=0 (Direct):   All traps → mtvec.BASE
 *   MODE=1 (Vectored): Interrupts → mtvec.BASE + 4*cause_code
 *                      Exceptions → mtvec.BASE
 *
 * WFI Behavior:
 * =============
 *   - Stall pipeline until any interrupt is pending
 *   - Resume at next instruction if interrupt not taken
 *   - Take trap if interrupt is both pending and enabled
 *
 * Related Modules:
 *   - csr_file.sv: Provides mstatus/mie/mtvec/mepc, receives trap updates
 *   - ex_stage.sv: Detects exceptions, provides exception_valid/cause/tval
 *   - hazard_resolution_unit.sv: Uses trap_taken for pipeline flush
 *   - pc_controller.sv: Uses trap_target for PC redirect
 */
module trap_unit #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Pipeline control
    input logic i_pipeline_stall,

    // CSR values from csr_file
    input logic [XLEN-1:0] i_mstatus,
    input logic [XLEN-1:0] i_mie,
    input logic [XLEN-1:0] i_mtvec,
    input logic [XLEN-1:0] i_mepc,

    // Direct MIE bit input (bypasses bit extraction which Icarus has issues with)
    input logic i_mstatus_mie_direct,

    // Interrupt pending inputs
    input riscv_pkg::interrupt_t i_interrupts,

    // Exception inputs from EX stage
    input logic i_exception_valid,
    input logic [XLEN-1:0] i_exception_cause,
    input logic [XLEN-1:0] i_exception_tval,
    input logic [XLEN-1:0] i_exception_pc,

    // MRET instruction in EX stage
    input logic i_mret_in_ex,

    // WFI instruction in EX stage
    input logic i_wfi_in_ex,

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

  // Use direct mstatus_mie input to avoid Icarus issues with bit extraction
  logic mstatus_mie;
  assign mstatus_mie = i_mstatus_mie_direct;

  // Extract individual interrupt enable bits from mie
  logic mie_meie, mie_mtie, mie_msie;
  assign mie_meie = i_mie[riscv_pkg::MieMeiBit];
  assign mie_mtie = i_mie[riscv_pkg::MieMtiBit];
  assign mie_msie = i_mie[riscv_pkg::MieMsiBit];

  // Register trap_taken for one cycle to prevent it from re-asserting immediately
  // after CSR update (breaks combinational loop with mstatus_mie)
  logic trap_taken_prev;
  always_ff @(posedge i_clk) begin
    if (i_rst) trap_taken_prev <= 1'b0;
    else trap_taken_prev <= o_trap_taken;
  end

  // Interrupt pending and enabled (gate by !trap_taken_prev to prevent re-entry)
  logic meip_enabled, mtip_enabled, msip_enabled;
  assign meip_enabled = i_interrupts.meip && mie_meie && mstatus_mie && !trap_taken_prev;
  assign mtip_enabled = i_interrupts.mtip && mie_mtie && mstatus_mie && !trap_taken_prev;
  assign msip_enabled = i_interrupts.msip && mie_msie && mstatus_mie && !trap_taken_prev;

  // TIMING OPTIMIZATION: Register interrupt_pending to break critical path.
  // The combinational path from msip -> interrupt_pending -> take_trap -> stall -> cache
  // was the WNS path. Registering interrupt_pending adds 1-cycle latency to interrupt
  // detection, which is acceptable since interrupts are asynchronous events.
  // Note: mtip is already registered in cpu_and_mem.sv for similar timing reasons.
  logic interrupt_pending_comb;
  logic interrupt_pending;
  assign interrupt_pending_comb = meip_enabled || mtip_enabled || msip_enabled;

  always_ff @(posedge i_clk) begin
    if (i_rst) interrupt_pending <= 1'b0;
    else interrupt_pending <= interrupt_pending_comb;
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
    end else if (i_wfi_in_ex && !i_pipeline_stall) begin
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
    interrupt_cause <= interrupt_cause_comb;
  end

  // Trap taken: either interrupt or exception, and pipeline not stalled
  // (except for WFI stall, which should be broken by interrupt)
  logic take_trap;
  assign take_trap = (interrupt_pending || i_exception_valid) && !i_pipeline_stall;

  // MRET execution (trap has priority: if interrupt/exception fires same cycle, trap wins)
  logic take_mret;
  assign take_mret = i_mret_in_ex && !i_pipeline_stall && !take_trap;

  // Output trap signals
  assign o_trap_taken = take_trap;
  assign o_mret_taken = take_mret;

  // Trap target: mtvec for trap entry, mepc for MRET
  // mtvec MODE (bits [1:0]): 0 = Direct (all traps go to BASE)
  //                          1 = Vectored (interrupts go to BASE + 4*cause)
  always_comb begin
    if (take_mret) begin
      o_trap_target = i_mepc;
    end else if (take_trap) begin
      // Check mtvec mode
      if (i_mtvec[1:0] == 2'b01 && interrupt_pending) begin
        // Vectored mode for interrupts: BASE + 4*cause_code
        // Use pre-computed small offset (6 bits) for faster timing than
        // extracting from full interrupt_cause which synthesis can't optimize
        o_trap_target = {i_mtvec[XLEN-1:2], 2'b00} + {26'b0, vectored_offset};
      end else begin
        // Direct mode: all traps go to BASE (aligned to 4 bytes)
        o_trap_target = {i_mtvec[XLEN-1:2], 2'b00};
      end
    end else begin
      o_trap_target = '0;
    end
  end

  // Trap entry information for CSR file
  // Interrupts have priority over synchronous exceptions
  always_comb begin
    if (interrupt_pending) begin
      o_trap_cause = interrupt_cause;
      o_trap_value = '0;  // Interrupts have mtval = 0
      // For interrupts, save PC of next instruction (the one that will be interrupted)
      o_trap_pc = i_exception_pc;
    end else begin
      o_trap_cause = i_exception_cause;
      o_trap_value = i_exception_tval;
      o_trap_pc = i_exception_pc;
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
    assume (!(i_mret_in_ex && i_exception_valid));
    assume (!(i_wfi_in_ex && i_mret_in_ex));
    assume (!(i_wfi_in_ex && i_exception_valid));
    // Note: MRET + interrupt_pending is NOT assumed away. The RTL handles it
    // by giving trap priority (!take_trap gate on take_mret), and the
    // p_trap_mret_mutex assertion proves this without over-constraining.
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // Trap/MRET mutex: cannot both fire simultaneously.
      p_trap_mret_mutex : assert (!(o_trap_taken && o_mret_taken));

      // Trap needs source: trap_taken requires interrupt or exception.
      p_trap_needs_source : assert (!o_trap_taken || (interrupt_pending || i_exception_valid));

      // Trap not during stall: traps only fire when pipeline not stalled.
      p_trap_not_stalled : assert (!o_trap_taken || !i_pipeline_stall);

      // MRET not during stall.
      p_mret_not_stalled : assert (!o_mret_taken || !i_pipeline_stall);

      // MRET target is mepc: when MRET fires, target must be mepc.
      p_mret_target : assert (!o_mret_taken || (o_trap_target == i_mepc));

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
      cover (interrupt_pending && interrupt_cause == riscv_pkg::IntMachineExternal);
      cover_exception : cover (o_trap_taken && i_exception_valid && !interrupt_pending);
    end
  end

`endif  // FORMAL

endmodule : trap_unit
