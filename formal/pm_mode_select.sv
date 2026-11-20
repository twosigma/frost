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

// Ssnpm pointer masking applied to operand terms and after the trap unit's
// register. For every base, 64-bit immediate, mode (the never-produced 01
// included) and other input:
//   - coherent_store_pm_select's store PMA verdict and untranslated
//     completion at issue equal those of the transformed base: the store
//     map on the transformed base page adjusted by the signed immediate's
//     page step, and the completion regions on the transformed base plus
//     the immediate. Instances cover
//     both settings of MEM_RESPONSE_ERRORS and CACHE_NORMAL_MEMORY, the
//     configured cached DDR range, a smaller range, and a range above bit
//     46, which keeps the completion test on the transformed sum.
//   - The trap value the trap unit latches before the transform, with the
//     transform's mode, gives the value with the transform applied first:
//     the misaligned engine's final value, or the selection by cause written
//     out below with the transform inside each data-fault case.
//     riscv_pkg::exception_tval under the access's mode equals that
//     selection.
// Combinational, so one BMC step covers every input.
module pm_mode_select (
    input logic                  [63:0] base,
    input logic                  [63:0] imm,
    input riscv_pkg::pm_mode_t          mode,
    input logic                         page_carry,
    input logic                         atomic,
    input logic                         cmo,
    input logic                         issue_without_pma,
    input riscv_pkg::exc_cause_t        cause,
    input logic                  [63:0] pc,
    input logic                  [63:0] value,
    input logic                         bus_fault,
    input logic                  [63:0] bus_fault_va,
    input logic                  [31:0] insn,
    input logic                         virt,
    input logic                         ma_pending,
    input logic                  [63:0] ma_tval
);
  localparam int unsigned XLEN = riscv_pkg::XLEN;

  // Store verdicts with the transform applied first.
  logic [XLEN-1:0] base_t, sum_t;
  logic ref_pma_ok;
  assign base_t = riscv_pkg::pm_base_transform(base, mode);
  assign sum_t  = base_t + imm;
  // The offset subtracts one page for a negative immediate and adds one
  // for the carry out of bit 11. Check the resulting page directly.
  logic [XLEN-13:0] ref_page;
  logic [ XLEN-1:0] ref_addr;
  assign ref_page = base_t[XLEN-1:12] - (XLEN - 12)'(imm[11]) + (XLEN - 12)'(page_carry);
  assign ref_addr = {ref_page, sum_t[11:0]};
  assign ref_pma_ok = atomic ? riscv_pkg::pma_atomic_ok(
      ref_addr
  ) : riscv_pkg::pma_data_ok(
      ref_addr
  );

  // {MEM_RESPONSE_ERRORS, CACHE_NORMAL_MEMORY, cached base, cached size}.
  localparam int Cases = 6;
  localparam logic [Cases-1:0] CaseErrors = 6'b11_1010;
  localparam logic [Cases-1:0] CaseNormal = 6'b11_1100;
  localparam logic [Cases*64-1:0] CaseCachedBase = {
    64'h0,
    64'h4000_0000,
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase)
  };
  localparam logic [Cases*64-1:0] CaseCachedSize = {
    64'h4_0000_0000_0000,
    64'h10_0000,
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes)
  };

  for (genvar c = 0; c < Cases; c++) begin : gen_case
    localparam bit Errors = CaseErrors[c];
    localparam bit Normal = CaseNormal[c];
    localparam longint unsigned CachedBase = CaseCachedBase[c*64+:64];
    localparam longint unsigned CachedSize = CaseCachedSize[c*64+:64];
    logic pma_ok, complete, ref_complete;
    coherent_store_pm_select #(
        .MEM_RESPONSE_ERRORS(Errors),
        .CACHE_NORMAL_MEMORY(Normal),
        .CACHED_BASE(CachedBase),
        .CACHED_SIZE_BYTES(CachedSize)
    ) dut (
        .i_base(base),
        .i_imm(imm),
        .i_effective_addr(sum_t),
        .i_pm_mode(mode),
        .i_page_carry(page_carry),
        .i_atomic(atomic),
        .i_cmo(cmo),
        .i_issue_without_pma(issue_without_pma),
        .o_pma_ok(pma_ok),
        .o_complete(complete)
    );
    // The wrapper's completion with the transformed sum.
    assign ref_complete = issue_without_pma &&
        (!Errors || cmo || (Normal && riscv_pkg::pma_writethrough_ok(
        sum_t
    )) || ((sum_t >= XLEN'(CachedBase)) && (sum_t < XLEN'(CachedBase) + XLEN'(CachedSize)))) &&
        ref_pma_ok;
    // Unlabeled: a label would repeat in every gen_case scope.
    always_comb begin
      assert (pma_ok == ref_pma_ok);
      assert (complete == ref_complete);
    end
  end

  // The trap value: cpu_ooo's selection by cause with the transform first.
  logic [XLEN-1:0] main_tval;
  always_comb begin
    unique case (cause)
      // Breakpoint: tval = the breakpoint instruction's own (virtual) address.
      riscv_pkg::ExcBreakpoint[$bits(cause)-1:0]: main_tval = pc;
      // Instruction access/page faults: tval = the virtual
      // address of the faulting portion of the instruction (the PC, or PC + 2
      // for a page-straddling instruction whose second halfword faulted),
      // parked in the value slot by the INT ALU shim.
      riscv_pkg::ExcInstrAccessFault[$bits(
          cause
      )-1:0], riscv_pkg::ExcInstrPageFault[$bits(
          cause
      )-1:0]:
      main_tval = value;
      // Misaligned and data page faults: tval = the faulting data virtual
      // address, parked in the entry's value slot by the LQ bypass or the
      // store fault strobe. Under Ssnpm pointer masking it is the
      // transformed address (riscv_pkg "Pointer masking"); the mode and
      // translation state are those the access used: both change only at
      // serializing points, and none lies between an access and its trap.
      riscv_pkg::ExcLoadAddrMisalign[$bits(
          cause
      )-1:0], riscv_pkg::ExcStoreAddrMisalign[$bits(
          cause
      )-1:0], riscv_pkg::ExcLoadPageFault[$bits(
          cause
      )-1:0], riscv_pkg::ExcStorePageFault[$bits(
          cause
      )-1:0]:
      main_tval = riscv_pkg::pm_tval(value, mode, virt);
      // The bus-fault table stores the issue VA after the base transform.
      // Apply the same architectural tval conversion to the selected VA.
      riscv_pkg::ExcLoadAccessFault[$bits(
          cause
      )-1:0], riscv_pkg::ExcStoreAccessFault[$bits(
          cause
      )-1:0]:
      main_tval = riscv_pkg::pm_tval(bus_fault ? bus_fault_va : value, mode, virt);
      riscv_pkg::ExcIllegalInstr[$bits(cause)-1:0]: main_tval = XLEN'(insn);
      default: main_tval = '0;
    endcase
  end

  logic [XLEN-1:0] latched_tval, ref_tval;
  riscv_pkg::pm_mode_t latched_pm_mode;
  assign latched_tval = ma_pending ? ma_tval : riscv_pkg::exception_tval(
      cause, pc, value, bus_fault, bus_fault_va, insn, riscv_pkg::EnvcfgPmmOff, virt
  );
  assign latched_pm_mode = ma_pending ? riscv_pkg::EnvcfgPmmOff : riscv_pkg::exception_tval_pm_mode(
      cause, mode
  );
  assign ref_tval = ma_pending ? ma_tval : main_tval;
  always_comb begin
    p_exception_tval_selection :
    assert (riscv_pkg::exception_tval(
        cause, pc, value, bus_fault, bus_fault_va, insn, mode, virt
    ) == main_tval);
    p_trap_value : assert (riscv_pkg::pm_tval(latched_tval, latched_pm_mode, virt) == ref_tval);
  end
endmodule
