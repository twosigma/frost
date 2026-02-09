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
 * Exception Detector
 *
 * Detects synchronous exceptions in the Execute stage and generates
 * the appropriate exception cause and trap value (mtval) signals.
 *
 * Detected Exceptions:
 *   - ECALL: Environment call (system call)
 *   - EBREAK: Breakpoint
 *   - Load address misaligned: LH at odd address, LW not 4-byte aligned
 *   - Store address misaligned: SH at odd address, SW not 4-byte aligned
 *
 * Timing:
 *   - exception_valid is computed as flat OR (single LUT level)
 *   - cause/tval use priority mux (only when exception_valid matters)
 *   - Uses pre-computed data_memory_address_low to avoid CARRY8 chain
 *
 * Related Modules:
 *   - ex_stage.sv: Instantiates this module
 *   - trap_unit.sv: Receives exception signals for trap handling
 */
module exception_detector #(
    parameter int unsigned XLEN = 32
) (
    // Instruction type signals
    input logic i_is_ecall,
    input logic i_is_ebreak,
    input logic i_is_illegal_instruction,
    input logic i_is_load_instruction,
    input logic i_is_load_halfword,
    input logic i_is_load_byte,
    input logic i_is_fp_load,
    input logic i_is_fp_load_double,
    input logic i_is_fp_store_double,
    input riscv_pkg::store_op_e i_store_operation,

    // Address signals
    input logic [XLEN-1:0] i_program_counter,
    input logic [XLEN-1:0] i_data_memory_address,
    input logic [1:0] i_data_memory_address_low,  // Pre-computed low bits for timing

    // Exception outputs
    output logic o_exception_valid,
    output logic [XLEN-1:0] o_exception_cause,
    output logic [XLEN-1:0] o_exception_tval
);

  // Individual exception detection signals
  logic exception_ecall;
  logic exception_ebreak;
  logic exception_illegal;
  /* verilator lint_off UNOPTFLAT */
  logic exception_load_misalign;
  logic exception_store_misalign;
  /* verilator lint_on UNOPTFLAT */

  assign exception_ecall = i_is_ecall;
  assign exception_ebreak = i_is_ebreak;
  assign exception_illegal = i_is_illegal_instruction;

  // Load misalignment: halfword access at odd address, or word access not 4-byte aligned
  // TIMING OPTIMIZATION: Use data_memory_address_low (computed without CARRY8 chain)
  // for misalignment detection. This breaks the critical path:
  //   rs1 → forwarding → CARRY8 → misalign → trap → stall → cache WE
  // by computing address[1:0] in parallel with the CARRY8 chain.
  assign exception_load_misalign =
      (i_is_load_instruction && (
          (i_is_load_halfword && i_data_memory_address_low[0]) ||
          (!i_is_load_halfword && !i_is_load_byte &&
           i_data_memory_address_low != 2'b00)
      )) ||
      (i_is_fp_load && !i_is_fp_load_double &&
       (i_data_memory_address_low != 2'b00)) ||
      (i_is_fp_load_double && (i_data_memory_address[2:0] != 3'b000));

  // Store misalignment: halfword store at odd address, or word store not 4-byte aligned
  assign exception_store_misalign = ((i_store_operation != riscv_pkg::STN) && (
      (i_store_operation == riscv_pkg::STH &&
       i_data_memory_address_low[0]) ||
      (i_store_operation == riscv_pkg::STW &&
       i_data_memory_address_low != 2'b00)
  )) ||
      (i_is_fp_store_double && (i_data_memory_address[2:0] != 3'b000));

  // TIMING OPTIMIZATION: Compute exception_valid as flat OR instead of priority mux.
  // Priority is only needed for cause/tval selection, not for the valid signal.
  // This breaks the serial chain: ecall → ebreak → load_misalign → store_misalign
  // into a parallel structure that computes all in one LUT level.
  assign o_exception_valid = exception_ecall | exception_ebreak | exception_illegal |
                             exception_load_misalign | exception_store_misalign;

  // Priority mux for cause and tval (only used when exception_valid is true)
  /* verilator lint_off UNOPTFLAT */
  logic [XLEN-1:0] exception_tval_comb;
  /* verilator lint_on UNOPTFLAT */

  always_comb begin
    o_exception_cause   = '0;
    exception_tval_comb = '0;

    if (exception_illegal) begin
      o_exception_cause   = riscv_pkg::ExcIllegalInstr;
      exception_tval_comb = '0;
    end else if (exception_ecall) begin
      o_exception_cause   = riscv_pkg::ExcEcallMmode;
      exception_tval_comb = '0;
    end else if (exception_ebreak) begin
      o_exception_cause   = riscv_pkg::ExcBreakpoint;
      exception_tval_comb = i_program_counter;
    end else if (exception_load_misalign) begin
      o_exception_cause   = riscv_pkg::ExcLoadAddrMisalign;
      exception_tval_comb = i_data_memory_address;
    end else if (exception_store_misalign) begin
      o_exception_cause   = riscv_pkg::ExcStoreAddrMisalign;
      exception_tval_comb = i_data_memory_address;
    end
  end

  assign o_exception_tval = exception_tval_comb;

endmodule : exception_detector
