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
 * RISC-V Processor Package - Type definitions for RV32IMACB implementation
 *
 * This package contains all shared type definitions, enumerations, constants,
 * and pipeline data structures for the FROST RISC-V processor core.
 *
 * Contents:
 * =========
 *   Section 1: Instruction Opcodes (opc_e)
 *   Section 2: Instruction Operations (instr_op_e)
 *   Section 3: CSR Definitions (addresses, bit positions, cause codes)
 *   Section 4: Control Enumerations (branch_taken_op_e, store_op_e)
 *   Section 5: Instruction Format (instr_t, constants)
 *   Section 6: Pipeline Control (pipeline_ctrl_t)
 *   Section 7: Inter-Stage Data Structures (from_*_to_*_t)
 *   Section 8: Forwarding and Hazard Structures
 *   Section 9: A-Extension Support (reservation_t, amo_interface_t)
 *   Section 10: Trap/Exception Handling
 *   Section 11: Bit Manipulation Helper Functions (clz, ctz, cpop)
 *   Section 12: Tomasulo OOO Execution (Reorder Buffer, RS, LQ, SQ, CDB, RAT)
 *
 * Supported Extensions:
 * =====================
 *   RV32I   - Base integer instruction set
 *   M       - Integer multiply/divide
 *   A       - Atomic memory operations (LR/SC, AMO)
 *   C       - Compressed instructions (16-bit)
 *   B       - Bit manipulation (Zba + Zbb + Zbs)
 *   Zicsr   - CSR access instructions
 *   Zicntr  - Base counters (cycle, time, instret)
 *   Zifencei- Instruction fence
 *   Zicond  - Conditional zero operations
 *   Zbkb    - Bit manipulation for crypto
 *   Zihintpause - Pause hint
 *   F       - Single-precision floating-point
 *   D       - Double-precision floating-point
 *
 * Design Note (Yosys Compatibility):
 * ==================================
 *   This package uses a monolithic design (single large package) for compatibility
 *   with the Yosys synthesis tool. Yosys does not support inter-package references,
 *   so all types must be defined in a single package.
 *
 * Usage:
 * ======
 *   All modules should import this package:
 *     import riscv_pkg::*;
 *   Or reference specific types:
 *     riscv_pkg::instr_t instruction;
 */
package riscv_pkg;

  // ===========================================================================
  // Section 1: Instruction Opcodes
  // ===========================================================================
  // Primary opcode field (bits [6:0]) identifies instruction category.
  // These map directly to the RISC-V base instruction encoding.

  typedef enum bit [6:0] {
    OPC_LUI      = 7'b0110111,
    OPC_AUIPC    = 7'b0010111,
    OPC_JAL      = 7'b1101111,
    OPC_JALR     = 7'b1100111,
    OPC_BRANCH   = 7'b1100011,
    OPC_LOAD     = 7'b0000011,
    OPC_STORE    = 7'b0100011,
    OPC_OP_IMM   = 7'b0010011,
    OPC_OP       = 7'b0110011,
    OPC_MISC_MEM = 7'b0001111,  // FENCE, FENCE.I (Zifencei)
    OPC_CSR      = 7'b1110011,
    OPC_AMO      = 7'b0101111,  // A extension (atomics)
    // F extension (single-precision floating-point)
    OPC_LOAD_FP  = 7'b0000111,  // FLW
    OPC_STORE_FP = 7'b0100111,  // FSW
    OPC_FMADD    = 7'b1000011,  // FMADD.S
    OPC_FMSUB    = 7'b1000111,  // FMSUB.S
    OPC_FNMSUB   = 7'b1001011,  // FNMSUB.S
    OPC_FNMADD   = 7'b1001111,  // FNMADD.S
    OPC_OP_FP    = 7'b1010011   // FADD.S, FSUB.S, FMUL.S, etc.
  } opc_e;

  // ===========================================================================
  // Section 2: Instruction Operations
  // ===========================================================================
  // Full enumeration of all instruction operations. Used by instruction decoder
  // to communicate the operation to the ALU and other execution units.
  // Organized by extension/category.

  typedef enum {
    // base-ISA integer ops
    ADD,
    SUB,
    AND,
    OR,
    XOR,
    SLL,
    SRL,
    SRA,
    SLT,
    SLTU,
    ADDI,
    ANDI,
    ORI,
    XORI,
    SLTI,
    SLTIU,
    SLLI,
    SRLI,
    SRAI,
    // base-ISA upper-imm/jumps
    LUI,
    AUIPC,
    JAL,
    JALR,
    // base-ISA branches
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,
    // base-ISA loads/stores
    LB,
    LH,
    LW,
    LBU,
    LHU,
    SB,
    SH,
    SW,
    // M-extension for multiply/divide
    MUL,
    MULH,
    MULHSU,
    MULHU,
    DIV,
    DIVU,
    REM,
    REMU,
    // Zifencei extension
    FENCE,
    FENCE_I,
    // Zicsr extension
    CSRRW,
    CSRRS,
    CSRRC,
    CSRRWI,
    CSRRSI,
    CSRRCI,
    // Zba extension (address generation)
    SH1ADD,
    SH2ADD,
    SH3ADD,
    // Zbs extension (single-bit operations)
    BSET,
    BCLR,
    BINV,
    BEXT,
    BSETI,
    BCLRI,
    BINVI,
    BEXTI,
    // Zbb extension (basic bit manipulation)
    ANDN,
    ORN,
    XNOR,
    CLZ,
    CTZ,
    CPOP,
    MAX,
    MAXU,
    MIN,
    MINU,
    SEXT_B,
    SEXT_H,
    ROL,
    ROR,
    RORI,
    ORC_B,
    REV8,
    // Zicond extension (conditional operations)
    CZERO_EQZ,
    CZERO_NEZ,
    // Zbkb extension (bit manipulation for crypto)
    PACK,
    PACKH,
    BREV8,
    ZIP,
    UNZIP,
    // Zihintpause extension
    PAUSE,
    // Privileged instructions (trap handling)
    MRET,       // Return from machine-mode trap
    WFI,        // Wait for interrupt
    ECALL,      // Environment call (system call)
    EBREAK,     // Breakpoint exception
    // A extension (atomics)
    LR_W,       // Load-reserved word
    SC_W,       // Store-conditional word
    AMOSWAP_W,  // Atomic swap
    AMOADD_W,   // Atomic add
    AMOXOR_W,   // Atomic XOR
    AMOAND_W,   // Atomic AND
    AMOOR_W,    // Atomic OR
    AMOMIN_W,   // Atomic minimum (signed)
    AMOMAX_W,   // Atomic maximum (signed)
    AMOMINU_W,  // Atomic minimum (unsigned)
    AMOMAXU_W,  // Atomic maximum (unsigned)
    // F extension (single-precision floating-point)
    FLW,        // Load float
    FSW,        // Store float
    FADD_S,     // FP add
    FSUB_S,     // FP subtract
    FMUL_S,     // FP multiply
    FDIV_S,     // FP divide
    FSQRT_S,    // FP square root
    FMADD_S,    // FP fused multiply-add
    FMSUB_S,    // FP fused multiply-subtract
    FNMADD_S,   // FP negated fused multiply-add
    FNMSUB_S,   // FP negated fused multiply-subtract
    FSGNJ_S,    // FP sign inject
    FSGNJN_S,   // FP sign inject negated
    FSGNJX_S,   // FP sign inject XOR
    FMIN_S,     // FP minimum
    FMAX_S,     // FP maximum
    FCVT_W_S,   // FP to signed int
    FCVT_WU_S,  // FP to unsigned int
    FCVT_S_W,   // Signed int to FP
    FCVT_S_WU,  // Unsigned int to FP
    FMV_X_W,    // Move FP bits to int reg
    FMV_W_X,    // Move int bits to FP reg
    FEQ_S,      // FP equal
    FLT_S,      // FP less than
    FLE_S,      // FP less than or equal
    FCLASS_S,   // FP classify
    // D extension (double-precision floating-point)
    FLD,        // Load double
    FSD,        // Store double
    FADD_D,     // FP add (double)
    FSUB_D,     // FP subtract (double)
    FMUL_D,     // FP multiply (double)
    FDIV_D,     // FP divide (double)
    FSQRT_D,    // FP square root (double)
    FMADD_D,    // FP fused multiply-add (double)
    FMSUB_D,    // FP fused multiply-subtract (double)
    FNMADD_D,   // FP negated fused multiply-add (double)
    FNMSUB_D,   // FP negated fused multiply-subtract (double)
    FSGNJ_D,    // FP sign inject (double)
    FSGNJN_D,   // FP sign inject negated (double)
    FSGNJX_D,   // FP sign inject XOR (double)
    FMIN_D,     // FP minimum (double)
    FMAX_D,     // FP maximum (double)
    FCVT_W_D,   // FP to signed int (double)
    FCVT_WU_D,  // FP to unsigned int (double)
    FCVT_D_W,   // Signed int to FP (double)
    FCVT_D_WU,  // Unsigned int to FP (double)
    FCVT_S_D,   // Convert double to single
    FCVT_D_S,   // Convert single to double
    FEQ_D,      // FP equal (double)
    FLT_D,      // FP less than (double)
    FLE_D,      // FP less than or equal (double)
    FCLASS_D    // FP classify (double)
  } instr_op_e;

  // ===========================================================================
  // Section 3: CSR Definitions
  // ===========================================================================
  // Control and Status Register addresses, bit positions, and cause codes.
  // Includes Zicsr instruction encodings and M-mode trap support.

  // CSR instruction funct3 encoding
  typedef enum bit [2:0] {
    CSR_RW  = 3'b001,  // CSRRW  - read/write
    CSR_RS  = 3'b010,  // CSRRS  - read/set bits
    CSR_RC  = 3'b011,  // CSRRC  - read/clear bits
    CSR_RWI = 3'b101,  // CSRRWI - read/write immediate
    CSR_RSI = 3'b110,  // CSRRSI - read/set bits immediate
    CSR_RCI = 3'b111   // CSRRCI - read/clear bits immediate
  } csr_op_e;

  // Zicntr CSR addresses (read-only user-mode counters)
  localparam bit [11:0] CsrCycle = 12'hC00;  // Cycle counter (low 32 bits)
  localparam bit [11:0] CsrTime = 12'hC01;  // Timer (low 32 bits)
  localparam bit [11:0] CsrInstret = 12'hC02;  // Instructions retired (low 32 bits)
  localparam bit [11:0] CsrCycleH = 12'hC80;  // Cycle counter (high 32 bits)
  localparam bit [11:0] CsrTimeH = 12'hC81;  // Timer (high 32 bits)
  localparam bit [11:0] CsrInstretH = 12'hC82;  // Instructions retired (high 32 bits)

  // Machine-mode CSR addresses (for trap/interrupt handling)
  localparam bit [11:0] CsrMstatus = 12'h300;  // Machine status register
  localparam bit [11:0] CsrMisa = 12'h301;  // Machine ISA register (read-only)
  localparam bit [11:0] CsrMie = 12'h304;  // Machine interrupt enable
  localparam bit [11:0] CsrMtvec = 12'h305;  // Machine trap vector base
  localparam bit [11:0] CsrMscratch = 12'h340;  // Machine scratch register
  localparam bit [11:0] CsrMepc = 12'h341;  // Machine exception PC
  localparam bit [11:0] CsrMcause = 12'h342;  // Machine trap cause
  localparam bit [11:0] CsrMtval = 12'h343;  // Machine trap value
  localparam bit [11:0] CsrMip = 12'h344;  // Machine interrupt pending
  // Machine information CSRs (read-only)
  localparam bit [11:0] CsrMhartid = 12'hF14;  // Hardware thread ID (always 0 for single-core)

  // F extension: Floating-point CSRs
  localparam bit [11:0] CsrFflags = 12'h001;  // FP exception flags (NV, DZ, OF, UF, NX)
  localparam bit [11:0] CsrFrm = 12'h002;  // FP rounding mode
  localparam bit [11:0] CsrFcsr = 12'h003;  // FP control/status (frm[7:5] + fflags[4:0])

  // F extension: Rounding modes
  typedef enum bit [2:0] {
    FRM_RNE = 3'b000,  // Round to Nearest, ties to Even
    FRM_RTZ = 3'b001,  // Round towards Zero
    FRM_RDN = 3'b010,  // Round Down (towards -inf)
    FRM_RUP = 3'b011,  // Round Up (towards +inf)
    FRM_RMM = 3'b100,  // Round to Nearest, ties to Max Magnitude
    FRM_DYN = 3'b111   // Dynamic (use frm CSR)
  } fp_rounding_mode_e;

  // F extension: Exception flags (sticky, accumulated in fflags CSR)
  typedef struct packed {
    logic nv;  // [4] Invalid operation (e.g., sqrt(-1), 0/0, inf-inf)
    logic dz;  // [3] Divide by zero
    logic of;  // [2] Overflow (result too large for format)
    logic uf;  // [1] Underflow (tiny non-zero result)
    logic nx;  // [0] Inexact (rounding occurred)
  } fp_flags_t;

  // IEEE 754 single-precision special value constants
  localparam bit [31:0] FpPosZero = 32'h0000_0000;  // +0.0
  localparam bit [31:0] FpNegZero = 32'h8000_0000;  // -0.0
  localparam bit [31:0] FpPosInf = 32'h7F80_0000;  // +infinity
  localparam bit [31:0] FpNegInf = 32'hFF80_0000;  // -infinity
  localparam bit [31:0] FpCanonicalNan = 32'h7FC0_0000;  // Canonical quiet NaN (single)
  localparam bit [63:0] FpCanonicalNan64 = 64'h7FF8_0000_0000_0000;  // Canonical quiet NaN (double)

  // IEEE 754 rounding decision: returns 1 if the mantissa should be incremented.
  function automatic logic fp_compute_round_up(input logic [2:0] rounding_mode, input logic guard,
                                               input logic round_bit, input logic sticky,
                                               input logic lsb, input logic sign);
    case (rounding_mode)
      3'b000:  fp_compute_round_up = guard & (round_bit | sticky | lsb);  // RNE
      3'b001:  fp_compute_round_up = 1'b0;  // RTZ
      3'b010:  fp_compute_round_up = sign & (guard | round_bit | sticky);  // RDN
      3'b011:  fp_compute_round_up = ~sign & (guard | round_bit | sticky);  // RUP
      3'b100:  fp_compute_round_up = guard;  // RMM
      default: fp_compute_round_up = guard & (round_bit | sticky | lsb);
    endcase
  endfunction

  // mstatus bit positions (RV32)
  localparam int unsigned MstatusMieBit = 3;  // Machine Interrupt Enable
  localparam int unsigned MstatusMpieBit = 7;  // Machine Previous Interrupt Enable

  // mie/mip bit positions
  localparam int unsigned MieMsiBit = 3;  // Machine Software Interrupt
  localparam int unsigned MieMtiBit = 7;  // Machine Timer Interrupt
  localparam int unsigned MieMeiBit = 11;  // Machine External Interrupt

  // Exception cause codes (mcause values when interrupt bit = 0)
  // Note: ExcInstrAddrMisalign and ExcIllegalInstr are defined for completeness
  // per RISC-V spec but not currently used (C extension handles alignment,
  // illegal instructions currently decode as NOPs)
  localparam bit [31:0] ExcInstrAddrMisalign = 32'd0;  // Reserved for future use
  localparam bit [31:0] ExcIllegalInstr = 32'd2;  // Reserved for future use
  localparam bit [31:0] ExcBreakpoint = 32'd3;
  localparam bit [31:0] ExcLoadAddrMisalign = 32'd4;
  localparam bit [31:0] ExcStoreAddrMisalign = 32'd6;
  localparam bit [31:0] ExcEcallMmode = 32'd11;

  // Interrupt cause codes (mcause values when interrupt bit = 1)
  localparam bit [31:0] IntMachineSoftware = 32'h8000_0003;
  localparam bit [31:0] IntMachineTimer = 32'h8000_0007;
  localparam bit [31:0] IntMachineExternal = 32'h8000_000B;

  // ===========================================================================
  // Section 4: Control Enumerations
  // ===========================================================================
  // Branch operation types and store operation types. These are compact
  // encodings used by the branch_jump_unit and store_unit respectively.

  // Branch operation type (purposely cap at 3 bits for minimum logic)
  typedef enum bit [2:0] {
    BREQ,
    BRNE,
    BRLT,
    BRGE,
    BRLTU,
    BRGEU,
    JUMP,
    NULL
  } branch_taken_op_e;

  // purposely cap at 2 bits for minimum logic
  // STN must be 0 so Verilator's 2-state initialization (all zeros) defaults to "no store"
  typedef enum bit [1:0] {
    STN,  // store nothing (default/reset value)
    STB,  // store byte
    STH,  // store half-word
    STW   // store word
  } store_op_e;

  // ===========================================================================
  // Section 5: Instruction Format
  // ===========================================================================
  // Packed struct matching the RISC-V R-type instruction format.
  // Other formats (I, S, B, U, J) reuse the same fields differently.

  // RISC-V instruction format broken into fields for easy decoding
  typedef struct packed {
    logic [6:0] funct7;        // Function code (7-bit) - specifies operation variant
    logic [4:0] source_reg_2;  // Second source register (rs2) - 0-31
    logic [4:0] source_reg_1;  // First source register (rs1) - 0-31
    logic [2:0] funct3;        // Function code (3-bit) - specifies operation type
    logic [4:0] dest_reg;      // Destination register (rd) - 0-31
    logic [6:0] opcode;        // Operation code - identifies instruction category
  } instr_t;

  localparam bit [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0
  localparam bit [15:0] NopLowBits = 16'h0013;  // Low 16 bits of NOP instruction

  localparam int unsigned XLEN = 32;
  // FP register width: 64-bit to support D extension (RV32D).
  localparam int unsigned FpWidth = 64;
  localparam int unsigned FpSingleWidth = 32;
  localparam int unsigned FpDoubleWidth = 64;

  // PC increment constants for instruction length handling
  localparam int unsigned PcIncrementCompressed = 2;  // 16-bit compressed instruction
  localparam int unsigned PcIncrement32bit = 4;  // 32-bit standard instruction

  // Magic number constants for RISC-V 32-bit operations
  // Used in ALU for special case handling (e.g., division overflow)
  localparam bit [31:0] SignedInt32Min = 32'h8000_0000;  // -2^31 (most negative)
  localparam bit [31:0] SignedInt32Max = 32'h7FFF_FFFF;  // 2^31 - 1 (most positive)
  localparam bit [31:0] UnsignedInt32Max = 32'hFFFF_FFFF;  // All ones (also -1 signed)
  localparam bit [31:0] NegativeOne = 32'hFFFF_FFFF;  // -1 in two's complement

  // ===========================================================================
  // Section 6: Pipeline Control
  // ===========================================================================
  // Global control signals distributed to all pipeline stages.
  // Generated by hazard_resolution_unit.sv.

  // Control signals distributed to all pipeline stages
  typedef struct packed {
    logic reset;
    logic stall;  // Freeze pipeline (don't advance)
    logic stall_registered;  // Stall signal from previous cycle
    logic stall_for_load_use_hazard;  // Stall due to load-use dependency
    logic stall_for_fp_load_ma_hazard;  // Stall: FP load in MA feeds multi-cycle FP op
    logic stall_for_trap_check;  // Stall conditions for trap unit (before trap/mret gating)
    logic flush;  // Clear pipeline (insert bubble/NOP)
    logic amo_wb_write_enable;  // Force regfile write for AMO result
    // Registered trap/mret signals for timing optimization
    // These break the path from EX stage exception detection through IF stage
    logic trap_taken_registered;  // trap_taken from previous cycle
    logic mret_taken_registered;  // mret_taken from previous cycle
    // TIMING OPTIMIZATION: Raw hazard detection without multiply precedence check.
    // Used by AMO unit to break the path: multiply_completing → stall_for_mul_div
    // → stall_for_load_use_hazard → stall_excluding_amo
    logic load_use_hazard_detected;  // Raw load-use hazard (no multiply precedence)
    // F extension: FPU in-flight hazard stall (RAW hazard with pipelined FPU ops)
    logic stall_for_fpu_inflight_hazard;
    // NOTE: stall_excluding_amo is passed as a separate output port from hazard_resolution_unit
    // (not through this struct) to avoid false combinational loop detection in some simulators.
  } pipeline_ctrl_t;

  // ===========================================================================
  // Section 7: Inter-Stage Data Structures
  // ===========================================================================
  // Packed structs for passing data between pipeline stages.
  // Named as from_<source>_to_<dest>_t (e.g., from_if_to_pd_t).
  // These are registered at stage boundaries (pipeline registers).

  // RAS (Return Address Stack) constants
  localparam int unsigned RasDepth = 8;
  localparam int unsigned RasPtrBits = $clog2(RasDepth);

  // Clocked signals passed from Instruction Fetch (IF) stage to Pre-Decode (PD) stage
  // IF outputs raw/partially processed data; PD performs decompression for better timing
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    // Raw 16-bit parcel for decompression (compressed instructions)
    logic [15:0] raw_parcel;
    // Selection signals for final instruction mux (computed in IF, used in PD)
    logic sel_nop;
    logic sel_spanning;
    logic sel_compressed;  // True if raw_parcel is a compressed instruction
    // Pre-assembled spanning instruction (32-bit from spanning buffer)
    instr_t spanning_instr;
    // Effective 32-bit instruction word (for aligned 32-bit case)
    instr_t effective_instr;
    // Pre-computed link address for JAL/JALR (PC+2 or PC+4 based on compression)
    logic [XLEN-1:0] link_address;
    // Branch prediction metadata (from BTB)
    logic btb_hit;  // BTB lookup hit
    logic btb_predicted_taken;  // BTB predicts taken
    logic [XLEN-1:0] btb_predicted_target;  // BTB predicted target address
    // RAS (Return Address Stack) prediction metadata
    logic ras_predicted;  // RAS prediction was used
    logic [XLEN-1:0] ras_predicted_target;  // RAS predicted return address
    logic [RasPtrBits-1:0] ras_checkpoint_tos;  // TOS at prediction time (for recovery)
    logic [RasPtrBits:0] ras_checkpoint_valid_count;  // Valid count at prediction (for recovery)
  } from_if_to_pd_t;

  // Clocked signals passed from Pre-Decode (PD) stage to Instruction Decode (ID) stage
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    instr_t instruction;
    // Pre-computed link address for JAL/JALR (PC+2 or PC+4 based on compression)
    logic [XLEN-1:0] link_address;
    // Early source registers for forwarding/hazard detection timing optimization
    // These are extracted in parallel with decompression for better timing
    logic [4:0] source_reg_1_early;
    logic [4:0] source_reg_2_early;
    // F extension: Early FP source reg 3 for FMA instructions (rs3 = funct7[6:2])
    logic [4:0] fp_source_reg_3_early;
    // Branch prediction metadata (passed through from IF)
    logic btb_hit;
    logic btb_predicted_taken;
    logic [XLEN-1:0] btb_predicted_target;
    // RAS prediction metadata (passed through from IF)
    logic ras_predicted;
    logic [XLEN-1:0] ras_predicted_target;
    logic [RasPtrBits-1:0] ras_checkpoint_tos;
    logic [RasPtrBits:0] ras_checkpoint_valid_count;
  } from_pd_to_id_t;

  // Clocked signals passed from Instruction Decode (ID) stage to Execute (EX) stage
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    // Immediate values decoded from instruction (different formats)
    logic [31:0] immediate_i_type;  // I-type: 12-bit sign-extended
    logic [31:0] immediate_s_type;  // S-type: for stores
    logic [31:0] immediate_b_type;  // B-type: for branches
    logic [31:0] immediate_u_type;  // U-type: upper 20 bits
    logic [31:0] immediate_j_type;  // J-type: for jumps
    // Register file read data (read in ID stage using early source regs from PD)
    // This moves the regfile read out of the EX stage critical path
    logic [XLEN-1:0] source_reg_1_data;
    logic [XLEN-1:0] source_reg_2_data;
    // TIMING OPTIMIZATION: Pre-computed x0 check flags.
    // These move the ~|source_reg NOR gate out of the forwarding critical path.
    // If true, the corresponding source register is x0 (hardwired zero).
    logic source_reg_1_is_x0;
    logic source_reg_2_is_x0;
    // Instruction type flags
    logic is_load_instruction;
    logic is_load_byte, is_load_halfword, is_load_unsigned;
    instr_op_e instruction_operation;
    branch_taken_op_e branch_operation;
    store_op_e store_operation;
    logic is_jump_and_link;  // JAL instruction
    logic is_jump_and_link_register;  // JALR instruction
    logic is_multiply, is_divide;
    // CSR instruction fields (Zicsr)
    logic is_csr_instruction;
    logic [11:0] csr_address;
    logic [4:0] csr_imm;  // Zero-extended immediate for CSRRWI/CSRRSI/CSRRCI
    // A extension (atomics)
    logic is_amo_instruction;  // Any AMO operation (LR, SC, or AMO*)
    logic is_lr;  // Load-reserved
    logic is_sc;  // Store-conditional
    // Privileged instructions (trap handling)
    logic is_mret;  // MRET instruction
    logic is_wfi;  // WFI instruction
    logic is_ecall;  // ECALL instruction
    logic is_ebreak;  // EBREAK instruction
    // F extension fields
    logic is_fp_instruction;  // Any FP instruction
    logic is_fp_load;  // FLW - data goes to FP regfile
    logic is_fp_store;  // FSW
    logic is_fp_load_double;  // FLD
    logic is_fp_store_double;  // FSD
    logic is_fp_compute;  // FP compute op (FADD, FSUB, FMUL, FDIV, FSQRT, FMA*, etc.)
    logic is_pipelined_fp_op;  // Multi-cycle FP op that tracks inflight dest (for hazard detection)
    logic [2:0] fp_rm;  // Rounding mode from instruction (funct3)
    logic is_fp_to_int;  // FP to integer conversion (result goes to int reg)
    logic is_int_to_fp;  // Integer to FP conversion (uses int rs1)
    // FP source register data (read in ID stage)
    logic [FpWidth-1:0] fp_source_reg_1_data;
    logic [FpWidth-1:0] fp_source_reg_2_data;
    logic [FpWidth-1:0] fp_source_reg_3_data;  // For FMA instructions
    // Pre-computed link address for JAL/JALR (PC+2 or PC+4 based on compression)
    logic [XLEN-1:0] link_address;
    // Pre-computed branch/jump targets (pipeline balancing - computed in ID stage)
    // These remove adders from EX stage critical path. Only JALR target needs
    // forwarded rs1, so it's still computed in EX stage.
    logic [XLEN-1:0] branch_target_precomputed;  // PC + imm_b (for conditional branches)
    logic [XLEN-1:0] jal_target_precomputed;  // PC + imm_j (for JAL)
    instr_t instruction;
    // Branch prediction metadata (passed through from IF via PD/ID)
    logic btb_hit;
    logic btb_predicted_taken;
    logic [XLEN-1:0] btb_predicted_target;
    // RAS prediction metadata (passed through from IF via PD/ID)
    logic ras_predicted;
    logic [XLEN-1:0] ras_predicted_target;
    logic [RasPtrBits-1:0] ras_checkpoint_tos;
    logic [RasPtrBits:0] ras_checkpoint_valid_count;
    // TIMING OPTIMIZATION: Pre-computed RAS instruction type detection.
    // These flags move comparisons out of the EX stage critical path.
    // Computed in ID stage from registered values, used by EX for ras_correct.
    logic is_ras_return;  // JALR with rs1 in {x1,x5}, rd=x0, imm=0
    logic is_ras_call;  // JAL/JALR with rd in {x1,x5}
    logic ras_predicted_target_nonzero;  // ras_predicted_target != 0
    // TIMING OPTIMIZATION: Pre-computed expected rs1 for RAS target verification.
    // For JALR: actual_target = rs1 + imm, so rs1 = predicted_target - imm.
    // By pre-computing this in ID stage, we remove the JALR adder (CARRY8 chain)
    // from the EX stage ras_correct critical path. EX only needs to compare
    // forwarded_rs1 with this pre-computed value.
    logic [XLEN-1:0] ras_expected_rs1;
    // TIMING OPTIMIZATION: Pre-computed BTB verification for non-JALR instructions.
    // For JAL and branches, the target is PC-relative and computed in ID stage.
    // We can compare it with btb_predicted_target in ID stage (no forwarding needed).
    // For JALR, we use btb_expected_rs1 (same algebraic transformation as RAS).
    logic btb_correct_non_jalr;  // True if non-JALR target matches BTB prediction
    logic [XLEN-1:0] btb_expected_rs1;  // btb_predicted_target - imm_i (for JALR)
  } from_id_to_ex_t;

  // Combinational outputs from Execute stage
  typedef struct packed {
    logic regfile_write_enable;
    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] data_memory_address;
    logic [XLEN-1:0] data_memory_write_data;
    logic [(XLEN/8)-1:0] data_memory_byte_write_enable;
    logic branch_taken;  // Whether branch or jump should be taken
    logic [XLEN-1:0] branch_target_address;  // Target address for branch/jump
    logic stall_for_multiply_divide;
    // TIMING OPTIMIZATION: Signal from multiplier indicating completion next cycle.
    // Hazard unit registers this to predict unstall without depending on multiplier_valid_output.
    logic multiply_completing_next_cycle;
    // A extension: SC.W success flag (0=success, 1=fail as value for rd)
    logic sc_success;
    // A extension: stall for AMO read-modify-write operations
    logic stall_for_amo;
    // Exception signals
    logic exception_valid;  // Exception detected in EX stage
    logic [XLEN-1:0] exception_cause;  // Exception cause code
    logic [XLEN-1:0] exception_tval;  // Trap value (faulting address/instruction)
    // BTB update signals (for branch prediction)
    logic btb_update;  // Update BTB entry
    logic [XLEN-1:0] btb_update_pc;  // PC of branch instruction
    logic [XLEN-1:0] btb_update_target;  // Actual branch target
    logic btb_update_taken;  // Actual branch outcome (taken/not-taken)
    // RAS misprediction recovery signals
    logic ras_misprediction;  // RAS prediction was wrong, need to restore
    logic [RasPtrBits-1:0] ras_restore_tos;  // TOS to restore on misprediction
    logic [RasPtrBits:0] ras_restore_valid_count;  // Valid count to restore
    logic ras_pop_after_restore;  // Pop RAS after restoring (for returns that triggered restore)
    // F extension fields
    logic stall_for_fpu;  // Stall for multi-cycle FP operation
    logic fpu_completing_next_cycle;  // FPU result will be valid next cycle
    logic [FpWidth-1:0] fp_result;  // FP computation result
    fp_flags_t fp_flags;  // FP exception flags from this operation
    logic fp_regfile_write_enable;  // Write to FP register file
    logic [4:0] fp_dest_reg;  // FP destination register (for forwarding)
    // FPU in-flight destination registers (for RAW hazard detection)
    logic [4:0] fpu_inflight_dest_1;  // 3-cycle ops: 2 cycles remaining
    logic [4:0] fpu_inflight_dest_2;  // 3-cycle ops: 1 cycle remaining
    logic [4:0] fpu_inflight_dest_3;  // FMA: 3 cycles remaining
    logic [4:0] fpu_inflight_dest_4;  // FMA: 2 cycles remaining
    logic [4:0] fpu_inflight_dest_5;  // FMA: 1 cycle remaining
    logic [4:0] fpu_inflight_dest_6;  // Sequential (div/sqrt)
  } from_ex_comb_t;

  // Clocked signals passed from Execute (EX) stage to Memory Access (MA) stage
  typedef struct packed {
    logic [XLEN-1:0] alu_result;
    logic regfile_write_enable;
    logic [XLEN-1:0] data_memory_address;
    instr_t instruction;
    logic is_load_instruction;
    logic is_load_byte;
    logic is_load_halfword;
    logic is_load_unsigned;
    // A extension (atomics)
    logic is_amo_instruction;
    logic is_lr;
    logic is_sc;
    logic sc_success;  // SC.W succeeded (0 goes to rd on success, 1 on fail)
    instr_op_e instruction_operation;  // Needed for AMO operation type
    logic [XLEN-1:0] rs2_value;  // Needed for SC and AMO operations
    // F extension fields
    logic is_fp_instruction;
    logic is_fp_load;  // FLW - data goes to FP regfile
    logic is_fp_store;  // FSW
    logic is_fp_load_double;  // FLD
    logic is_fp_store_double;  // FSD
    logic is_fp_to_int;  // FP-to-int (FMV.X.W, FCVT.W.S, etc.) - result goes to int regfile
    logic fp_regfile_write_enable;
    logic [4:0] fp_dest_reg;  // FP destination register (for forwarding)
    logic [FpWidth-1:0] fp_result;  // Result from FPU
    logic [FpWidth-1:0] fp_store_data;  // FP store data (for FSW/FSD)
    fp_flags_t fp_flags;  // FP exception flags
  } from_ex_to_ma_t;

  // Combinational signals passed from Memory Access (MA)
  typedef struct packed {
    logic [XLEN-1:0] data_memory_read_data;  // Raw data from memory
    logic [XLEN-1:0] data_loaded_from_memory;  // Processed load data (sign-extended, etc.)
    // F extension: Direct BRAM output for FP load forwarding.
    // data_memory_read_data uses registered path during stall which has race condition
    // with BRAM timing. This direct signal bypasses that for combinational forwarding.
    logic [XLEN-1:0] data_memory_read_data_direct;
    // FP load forwarding (FLW/FLD) - boxed to FpWidth for FLW.
    logic [FpWidth-1:0] fp_load_data;
    logic [FpWidth-1:0] fp_load_data_direct;
    logic fp_load_data_valid;
  } from_ma_comb_t;

  // Clocked signals passed from Memory Access (MA) stage to Writeback (WB) stage
  typedef struct packed {
    logic               regfile_write_enable;
    logic [XLEN-1:0]    regfile_write_data;       // Final result to write back
    instr_t             instruction;
    // F extension fields
    logic               fp_regfile_write_enable;
    logic [4:0]         fp_dest_reg;              // FP destination register (for forwarding)
    logic [FpWidth-1:0] fp_regfile_write_data;    // Final FP result to write back
    fp_flags_t          fp_flags;                 // FP exception flags (to accumulate in fflags)
  } from_ma_to_wb_t;

  // Signals from L0 Cache
  typedef struct packed {
    logic cache_hit_on_load;
    logic [XLEN-1:0] data_loaded_from_cache;
    // Registered cache hit/data for forwarding (breaks EX->cache->forwarding path).
    logic cache_hit_on_load_reg;
    logic [XLEN-1:0] data_loaded_from_cache_reg;
    logic cache_reset_in_progress;
  } from_cache_t;

  // ===========================================================================
  // Section 8: Forwarding and Hazard Structures
  // ===========================================================================
  // Data structures for operand forwarding and register file communication.

  // Forwarded register values to Execute stage (after hazard resolution)
  typedef struct packed {
    logic [XLEN-1:0] source_reg_1_value;
    logic [XLEN-1:0] source_reg_2_value;
    // Capture bypass for int->fp conversions (FCVT.S.W/WU, FMV.W.X).
    // When a load-use stall is asserted, provide the MA load data directly
    // so the FPU captures the correct rs1 value at the stall edge.
    logic            capture_bypass_int_valid;
    logic [XLEN-1:0] capture_bypass_int_data;
  } fwd_to_ex_t;

  // Register file read data to Forwarding unit
  typedef struct packed {
    logic [XLEN-1:0] source_reg_1_data;
    logic [XLEN-1:0] source_reg_2_data;
  } rf_to_fwd_t;

  // F extension: Forwarded FP register values to Execute stage
  typedef struct packed {
    logic [FpWidth-1:0] fp_source_reg_1_value;
    logic [FpWidth-1:0] fp_source_reg_2_value;
    logic [FpWidth-1:0] fp_source_reg_3_value;        // For FMA instructions
    // Combinational bypass for pipelined FPU operand capture timing:
    // The registered forwarding signals update at the same posedge when the
    // pipelined FPU captures operands. These combinational signals provide
    // the correct forwarding decision for capture.
    // MA bypass (one cycle ahead): producer in EX → consumer in ID
    logic               capture_bypass_rs1;
    logic               capture_bypass_rs2;
    logic               capture_bypass_rs3;
    logic [FpWidth-1:0] capture_bypass_data;          // EX result to forward at capture
    // WB bypass (two cycles ahead): producer in MA → consumer in ID
    logic               capture_bypass_rs1_from_wb;
    logic               capture_bypass_rs2_from_wb;
    logic               capture_bypass_rs3_from_wb;
    logic [FpWidth-1:0] capture_bypass_data_wb;       // MA result to forward at capture
    // Flag indicating the INCOMING instruction (in ID, entering EX) is a
    // pipelined FPU operation. The bypass should only apply to these ops.
    logic               capture_bypass_is_pipelined;
  } fp_fwd_to_ex_t;

  // F extension: FP register file read data to Forwarding unit
  typedef struct packed {
    logic [FpWidth-1:0] fp_source_reg_1_data;
    logic [FpWidth-1:0] fp_source_reg_2_data;
    logic [FpWidth-1:0] fp_source_reg_3_data;
  } fp_rf_to_fwd_t;

  // ===========================================================================
  // Section 9: A-Extension Support
  // ===========================================================================
  // Structures for atomic memory operations (LR/SC reservation tracking).

  // A extension: LR/SC reservation state
  // Used for load-reserved/store-conditional synchronization
  typedef struct packed {
    logic            valid;              // Reservation is active
    logic [XLEN-1:0] address;            // Reserved address (word-aligned)
    // Forwarding: LR in MA stage (reservation will be set next cycle)
    logic            lr_in_flight;       // LR is in MA stage, about to set reservation
    logic [XLEN-1:0] lr_in_flight_addr;  // Address LR is reserving
  } reservation_t;

  // A extension: AMO interface for cache coherence
  // Groups AMO write signals passed from CPU to L0 cache
  typedef struct packed {
    logic            write_enable;   // Enable memory write for AMO
    logic [XLEN-1:0] write_data;     // Data to write to memory
    logic [XLEN-1:0] write_address;  // Address for memory write
  } amo_interface_t;

  // ===========================================================================
  // Section 10: Trap/Exception Handling
  // ===========================================================================
  // Structures for trap control.
  // Used by trap_unit.sv for M-mode exception/interrupt handling.
  // Note: Exception signals (valid, cause, tval) are defined inline in from_ex_comb_t
  // rather than as a separate struct, since the PC comes from from_id_to_ex.

  // Trap control signals (from trap unit to pipeline)
  typedef struct packed {
    logic            trap_taken;   // Trap is being taken this cycle
    logic            mret_taken;   // MRET is being executed
    logic [XLEN-1:0] trap_target;  // Target PC for trap (mtvec or mepc)
  } trap_ctrl_t;

  // Interrupt pending signals (from peripherals to CPU)
  typedef struct packed {
    logic meip;  // Machine external interrupt pending
    logic mtip;  // Machine timer interrupt pending
    logic msip;  // Machine software interrupt pending
  } interrupt_t;

  // ===========================================================================
  // Section 11: Bit Manipulation Helper Functions (Zbb + Zbkb Extensions)
  // ===========================================================================
  // These functions implement bit manipulation operations using structures
  // optimized for FPGA timing. Includes:
  //   - CLZ, CTZ, CPOP (Zbb): Tree-based parallel counting
  //   - BREV8, ZIP, UNZIP (Zbkb): Byte/bit permutation operations

  // 8-bit CLZ helper - returns count 0-8 (8 means all zeros)
  // Scans from MSB (bit 7) to LSB (bit 0), counting leading zeros
  function automatic [3:0] clz8(input logic [7:0] val);
    if (val[7]) clz8 = 4'd0;
    else if (val[6]) clz8 = 4'd1;
    else if (val[5]) clz8 = 4'd2;
    else if (val[4]) clz8 = 4'd3;
    else if (val[3]) clz8 = 4'd4;
    else if (val[2]) clz8 = 4'd5;
    else if (val[1]) clz8 = 4'd6;
    else if (val[0]) clz8 = 4'd7;
    else clz8 = 4'd8;
  endfunction

  // 32-bit CLZ using tree of 8-bit CLZ operations
  // Scans from MSB byte (byte 3) to LSB byte (byte 0)
  function automatic [31:0] clz32(input logic [31:0] val);
    logic [3:0] clz_byte[4];  // CLZ result for each byte
    logic       nz_byte [4];  // Non-zero flag for each byte

    // Compute 8-bit CLZ and non-zero flags for each byte
    for (int i = 0; i < 4; i++) begin
      clz_byte[i] = clz8(val[i*8+:8]);
      nz_byte[i]  = |val[i*8+:8];
    end

    // Priority scan from MSB byte (3) to LSB byte (0)
    // Add byte offset (0, 8, 16, 24) based on which byte has first set bit
    if (nz_byte[3]) clz32 = {28'd0, clz_byte[3]};
    else if (nz_byte[2]) clz32 = {28'd0, clz_byte[2]} + 32'd8;
    else if (nz_byte[1]) clz32 = {28'd0, clz_byte[1]} + 32'd16;
    else if (nz_byte[0]) clz32 = {28'd0, clz_byte[0]} + 32'd24;
    else clz32 = 32'd32;  // All zeros
  endfunction

  // 8-bit CTZ helper - returns count 0-8 (8 means all zeros)
  // Scans from LSB (bit 0) to MSB (bit 7), counting trailing zeros
  function automatic [3:0] ctz8(input logic [7:0] val);
    if (val[0]) ctz8 = 4'd0;
    else if (val[1]) ctz8 = 4'd1;
    else if (val[2]) ctz8 = 4'd2;
    else if (val[3]) ctz8 = 4'd3;
    else if (val[4]) ctz8 = 4'd4;
    else if (val[5]) ctz8 = 4'd5;
    else if (val[6]) ctz8 = 4'd6;
    else if (val[7]) ctz8 = 4'd7;
    else ctz8 = 4'd8;
  endfunction

  // 32-bit CTZ using tree of 8-bit CTZ operations
  // Scans from LSB byte (byte 0) to MSB byte (byte 3)
  function automatic [31:0] ctz32(input logic [31:0] val);
    logic [3:0] ctz_byte[4];  // CTZ result for each byte
    logic       nz_byte [4];  // Non-zero flag for each byte

    // Compute 8-bit CTZ and non-zero flags for each byte
    for (int i = 0; i < 4; i++) begin
      ctz_byte[i] = ctz8(val[i*8+:8]);
      nz_byte[i]  = |val[i*8+:8];
    end

    // Priority scan from LSB byte (0) to MSB byte (3)
    // Add byte offset (0, 8, 16, 24) based on which byte has first set bit
    if (nz_byte[0]) ctz32 = {28'd0, ctz_byte[0]};
    else if (nz_byte[1]) ctz32 = {28'd0, ctz_byte[1]} + 32'd8;
    else if (nz_byte[2]) ctz32 = {28'd0, ctz_byte[2]} + 32'd16;
    else if (nz_byte[3]) ctz32 = {28'd0, ctz_byte[3]} + 32'd24;
    else ctz32 = 32'd32;  // All zeros
  endfunction

  // 4-bit popcount helper (LUT-friendly, 16 possible values)
  // Counts number of set bits using loop-based accumulation
  function automatic [2:0] cpop4(input logic [3:0] val);
    cpop4 = 3'd0;
    for (int i = 0; i < 4; i++) begin
      cpop4 = cpop4 + {2'b0, val[i]};
    end
  endfunction

  // 32-bit CPOP using tree of additions for optimal FPGA timing
  // Tree structure: 8x 4-bit -> 4x 8-bit -> 2x 16-bit -> 1x 32-bit result
  function automatic [31:0] cpop32(input logic [31:0] val);
    logic [2:0] pop4 [8];  // 8 groups of 4-bit popcounts
    logic [3:0] pop8 [4];  // 4 groups of 8-bit popcounts
    logic [4:0] pop16[2];  // 2 groups of 16-bit popcounts

    // Level 1: 8 parallel 4-bit popcounts
    for (int i = 0; i < 8; i++) begin
      pop4[i] = cpop4(val[i*4+:4]);
    end

    // Level 2: Combine pairs into 8-bit counts
    for (int i = 0; i < 4; i++) begin
      pop8[i] = {1'b0, pop4[2*i]} + {1'b0, pop4[2*i+1]};
    end

    // Level 3: Combine pairs into 16-bit counts
    for (int i = 0; i < 2; i++) begin
      pop16[i] = {1'b0, pop8[2*i]} + {1'b0, pop8[2*i+1]};
    end

    // Level 4: Final sum
    cpop32 = {26'd0, pop16[0]} + {26'd0, pop16[1]};
  endfunction

  // 64-bit CLZ using tree of 8-bit CLZ operations
  // Scans from MSB byte (byte 7) to LSB byte (byte 0)
  // Returns 7-bit result (0-64), optimized for FPGA timing
  function automatic [6:0] clz64(input logic [63:0] val);
    logic [3:0] clz_byte[8];  // CLZ result for each byte
    logic       nz_byte [8];  // Non-zero flag for each byte

    // Compute 8-bit CLZ and non-zero flags for each byte in parallel
    for (int i = 0; i < 8; i++) begin
      clz_byte[i] = clz8(val[i*8+:8]);
      nz_byte[i]  = |val[i*8+:8];
    end

    // Priority scan from MSB byte (7) to LSB byte (0)
    // Add byte offset (0, 8, 16, ..., 56) based on which byte has first set bit
    if (nz_byte[7]) clz64 = {3'd0, clz_byte[7]};
    else if (nz_byte[6]) clz64 = {3'd0, clz_byte[6]} + 7'd8;
    else if (nz_byte[5]) clz64 = {3'd0, clz_byte[5]} + 7'd16;
    else if (nz_byte[4]) clz64 = {3'd0, clz_byte[4]} + 7'd24;
    else if (nz_byte[3]) clz64 = {3'd0, clz_byte[3]} + 7'd32;
    else if (nz_byte[2]) clz64 = {3'd0, clz_byte[2]} + 7'd40;
    else if (nz_byte[1]) clz64 = {3'd0, clz_byte[1]} + 7'd48;
    else if (nz_byte[0]) clz64 = {3'd0, clz_byte[0]} + 7'd56;
    else clz64 = 7'd64;  // All zeros
  endfunction

  // 49-bit CLZ for FMA unit - pads to 64 bits and uses tree-based clz64
  // Input is 49-bit sum from FMA add stage, output is leading zero count (0-48)
  // Note: Caller should handle all-zeros case separately for correct behavior
  function automatic [5:0] clz49(input logic [48:0] val);
    logic [6:0] clz_result;
    clz_result = clz64({15'b0, val});
    // Subtract padding offset (15 bits). For non-zero input, clz_result is 15-63,
    // mapping to 0-48 after subtraction. Truncate to 6 bits (result fits in 0-48).
    clz49 = 6'(clz_result - 7'd15);
  endfunction

  // BREV8: Bit-reverse each byte independently (Zbkb extension)
  // Each byte has its bits reversed: bit 0 <-> bit 7, bit 1 <-> bit 6, etc.
  function automatic [31:0] brev8(input logic [31:0] val);
    for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        brev8[byte_idx*8+bit_idx] = val[byte_idx*8+(7-bit_idx)];
      end
    end
  endfunction

  // ZIP: Bit interleave (Zbkb extension, RV32 only)
  // Interleaves bits from lower and upper halves of the word.
  // Even result bits come from lower half, odd result bits from upper half.
  // zip({H, L}) = {H[15],L[15], H[14],L[14], ..., H[0],L[0]}
  function automatic [31:0] zip32(input logic [31:0] val);
    for (int i = 0; i < 16; i++) begin
      zip32[2*i]   = val[i];  // Even bits from lower half
      zip32[2*i+1] = val[16+i];  // Odd bits from upper half
    end
  endfunction

  // UNZIP: Bit deinterleave (Zbkb extension, RV32 only)
  // Inverse of ZIP: collects even bits to lower half, odd bits to upper half.
  // unzip(val) = {odd_bits, even_bits}
  function automatic [31:0] unzip32(input logic [31:0] val);
    for (int i = 0; i < 16; i++) begin
      unzip32[i]    = val[2*i];  // Even bits to lower half
      unzip32[16+i] = val[2*i+1];  // Odd bits to upper half
    end
  endfunction

  // ===========================================================================
  // Section 12: Tomasulo Out-of-Order Execution Structures
  // ===========================================================================
  // Parameters, types, and data structures for the Tomasulo OOO execution engine.
  // Includes Reorder Buffer, Reservation Stations, Load/Store Queues, CDB, RAT.

  // ---------------------------------------------------------------------------
  // Tomasulo Core Parameters
  // ---------------------------------------------------------------------------
  // Configurable depths for all major structures. Power-of-2 sizes simplify
  // circular buffer pointer arithmetic.

  // Reorder Buffer parameters
  localparam int unsigned ReorderBufferDepth = 32;  // Number of Reorder Buffer entries (power of 2)
  localparam int unsigned ReorderBufferTagWidth = $clog2(
      ReorderBufferDepth
  );  // 5 bits for 32-entry Reorder Buffer

  // Reservation Station depths (per RS type)
  localparam int unsigned IntRsDepth = 8;  // Integer ALU operations
  localparam int unsigned MulRsDepth = 4;  // Multiply/divide operations
  localparam int unsigned MemRsDepth = 8;  // Load/store operations
  localparam int unsigned FpRsDepth = 6;  // FP add/sub/cmp/cvt/classify/sgnj
  localparam int unsigned FmulRsDepth = 4;  // FP multiply/FMA (3 sources)
  localparam int unsigned FdivRsDepth = 2;  // FP divide/sqrt (long latency)

  // Memory queue depths
  localparam int unsigned LqDepth = 8;  // Load queue entries
  localparam int unsigned SqDepth = 8;  // Store queue entries

  // Checkpoint parameters
  localparam int unsigned NumCheckpoints = 4;  // For branch speculation recovery
  localparam int unsigned CheckpointIdWidth = $clog2(NumCheckpoints);  // 2 bits

  // Register file sizes
  localparam int unsigned NumIntRegs = 32;  // x0-x31
  localparam int unsigned NumFpRegs = 32;  // f0-f31
  localparam int unsigned RegAddrWidth = 5;  // $clog2(32)

  // Alias for FP register width (FLEN) - uses FpWidth from Section 5
  localparam int unsigned FLEN = FpWidth;  // 64 bits for D extension

  // CDB parameters
  localparam int unsigned NumCdbLanes = 1;  // Single CDB (future expansion)
  localparam int unsigned NumFus = 7;  // ALU, MUL, DIV, MEM, FP_ADD, FP_MUL, FP_DIV

  // ---------------------------------------------------------------------------
  // Functional Unit Enumeration and RS Assignment
  // ---------------------------------------------------------------------------
  // Identifies which functional unit an instruction uses. Used for RS routing
  // at dispatch and CDB arbitration at completion.

  // Functional unit identifier (for RS routing and CDB arbitration)
  typedef enum logic [2:0] {
    FU_ALU    = 3'd0,  // Integer ALU (ADD, SUB, AND, OR, XOR, SLT, branches)
    FU_MUL    = 3'd1,  // Integer multiplier
    FU_DIV    = 3'd2,  // Integer divider
    FU_MEM    = 3'd3,  // Load/store unit (both INT and FP)
    FU_FP_ADD = 3'd4,  // FP adder (add/sub/cmp/cvt/classify/sgnj)
    FU_FP_MUL = 3'd5,  // FP multiplier (mul/FMA)
    FU_FP_DIV = 3'd6   // FP divider/sqrt (long latency)
  } fu_type_e;

  // Reservation station type (for dispatch routing)
  typedef enum logic [2:0] {
    RS_INT  = 3'd0,  // INT_RS: Integer ALU ops, branches, CSR
    RS_MUL  = 3'd1,  // MUL_RS: MUL/DIV
    RS_MEM  = 3'd2,  // MEM_RS: All loads/stores (INT and FP)
    RS_FP   = 3'd3,  // FP_RS: FP add/sub/cmp/cvt/classify/sgnj
    RS_FMUL = 3'd4,  // FMUL_RS: FP mul/FMA (3 sources)
    RS_FDIV = 3'd5,  // FDIV_RS: FP div/sqrt
    RS_NONE = 3'd6   // No RS needed (e.g., WFI, FENCE dispatches to Reorder Buffer only)
  } rs_type_e;

  // ---------------------------------------------------------------------------
  // Reorder Buffer Entry Structure
  // ---------------------------------------------------------------------------
  // Unified Reorder Buffer entry supporting both integer and floating-point instructions.
  // ~120 bits per entry.

  // Exception cause codes specific to Tomasulo (extends riscv_pkg causes)
  // Width: 5 bits covers synchronous exception causes 0-31 (RISC-V max is 11 for ecall M-mode)
  // NOTE: Interrupts are handled separately by the trap unit, not stored in Reorder Buffer.
  // The Reorder Buffer only tracks synchronous exceptions from instruction execution.
  //
  // Mapping from riscv_pkg 32-bit constants to Reorder Buffer 5-bit cause:
  //   exc_cause = riscv_pkg::Exc*[4:0]  (low 5 bits)
  //   Examples: ExcBreakpoint (3) -> 5'd3, ExcLoadAddrMisalign (4) -> 5'd4
  // The mcause CSR's interrupt bit (bit 31) is never set for Reorder Buffer-tracked exceptions.
  // When committing an exception, the trap unit constructs the full mcause value.
  localparam int unsigned ExcCauseWidth = 5;

  // Typedef for exception cause to make the encoding explicit
  typedef logic [ExcCauseWidth-1:0] exc_cause_t;

  // Reorder Buffer entry structure
  typedef struct packed {
    // Core fields
    logic       valid;      // Entry is allocated
    logic       done;       // Execution complete
    logic       exception;  // Exception occurred
    exc_cause_t exc_cause;  // Exception cause code

    // Instruction identification
    logic [XLEN-1:0] pc;  // Instruction PC (for mepc)

    // Destination register
    logic dest_rf;  // 0=INT (x-reg), 1=FP (f-reg)
    logic [RegAddrWidth-1:0] dest_reg;  // Architectural destination (rd)
    logic dest_valid;  // Has destination register (not stores/branches w/o link)

    // Result value (FLEN-wide to support FP double)
    // For JAL: set to zero-extended link_addr at dispatch with done=1 (target known)
    // For JALR: set to zero-extended link_addr at dispatch with done=0, marked done=1 via reorder_buffer_branch_update_t
    // For other instructions: set by CDB broadcast (reorder_buffer_cdb_write_t) when execution completes
    // NOTE: When storing XLEN values, zero-extend to FLEN: value = {{FLEN-XLEN{1'b0}}, xlen_result}
    logic [FLEN-1:0] value;  // Result value

    // Store tracking
    logic is_store;     // Is store instruction
    logic is_fp_store;  // Is FP store (FSW/FSD)

    // Branch tracking (for speculation recovery)
    // NOTE: is_branch should be set for conditional branches AND JAL/JALR
    // so checkpoint allocation and misprediction recovery apply uniformly
    logic            is_branch;         // Is branch/jump instruction (BEQ/BNE/.../JAL/JALR)
    logic            branch_taken;      // Actual branch outcome
    logic [XLEN-1:0] branch_target;     // Actual branch target
    logic            predicted_taken;   // BTB prediction (for misprediction detection)
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target
    logic            mispredicted;      // Branch unit determined misprediction (authoritative)
    logic            is_call;           // Is call (for RAS recovery)
    logic            is_return;         // Is return (for RAS recovery)
    logic            is_jal;            // JAL instruction (can mark done=1 at dispatch)
    logic            is_jalr;           // JALR instruction (must wait for execute)

    // Checkpoint index (for branches that allocated a checkpoint)
    logic                         has_checkpoint;  // This branch has a checkpoint
    logic [CheckpointIdWidth-1:0] checkpoint_id;   // Checkpoint index

    // FP exception flags (accumulated at commit)
    fp_flags_t fp_flags;  // NV, DZ, OF, UF, NX

    // Serializing instruction flags
    logic is_csr;      // CSR instruction (execute at commit)
    logic is_fence;    // FENCE (drain SQ at commit)
    logic is_fence_i;  // FENCE.I (drain SQ, flush pipeline)
    logic is_wfi;      // WFI (stall at head until interrupt)
    logic is_mret;     // MRET (restore mstatus, redirect to mepc)
    logic is_amo;      // AMO (execute at head with SQ empty)
    logic is_lr;       // LR (sets reservation)
    logic is_sc;       // SC (checks reservation at head)
  } reorder_buffer_entry_t;

  // Reorder Buffer interface signals (for module ports)
  typedef struct packed {
    logic                    alloc_valid;       // Request Reorder Buffer allocation
    logic [XLEN-1:0]         pc;
    logic                    dest_rf;
    logic [RegAddrWidth-1:0] dest_reg;
    logic                    dest_valid;
    logic                    is_store;
    logic                    is_fp_store;
    logic                    is_branch;
    logic                    predicted_taken;
    logic [XLEN-1:0]         predicted_target;  // BTB/RAS predicted target
    logic                    is_call;
    logic                    is_return;
    // JAL/JALR: link_addr is the pre-computed PC+2/PC+4 result for rd
    // - JAL: dispatch sets value={{FLEN-XLEN{1'b0}}, link_addr}, done=1 (target known)
    // - JALR: dispatch sets value={{FLEN-XLEN{1'b0}}, link_addr}, done=0 (target resolved in execute)
    // NOTE: link_addr is XLEN (32-bit), must be zero-extended to FLEN (64-bit) when assigning to value
    logic [XLEN-1:0]         link_addr;
    logic                    is_jal;            // JAL: can mark done=1 at dispatch
    logic                    is_jalr;           // JALR: must wait for execute to resolve target
    logic                    is_csr;
    logic                    is_fence;
    logic                    is_fence_i;
    logic                    is_wfi;
    logic                    is_mret;
    logic                    is_amo;
    logic                    is_lr;
    logic                    is_sc;
  } reorder_buffer_alloc_req_t;

  typedef struct packed {
    logic                             alloc_ready;  // Reorder Buffer can accept allocation
    logic [ReorderBufferTagWidth-1:0] alloc_tag;    // Allocated Reorder Buffer entry index
    logic                             full;         // Reorder Buffer is full
  } reorder_buffer_alloc_resp_t;

  // CDB write to Reorder Buffer (for ALU, FPU, load results - NOT for branches/jumps)
  // NOTE: Branch/jump completion uses reorder_buffer_branch_update_t, not this interface.
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] tag;
    logic [FLEN-1:0]                  value;      // Result value to write to Reorder Buffer entry
    logic                             exception;
    exc_cause_t                       exc_cause;
    fp_flags_t                        fp_flags;
  } reorder_buffer_cdb_write_t;

  // Branch resolution update to Reorder Buffer (separate from CDB)
  // Sent by branch unit when a branch/jump resolves in execute stage.
  // This is the ONLY path for branch/jump completion - do NOT use reorder_buffer_cdb_write_t for branches.
  typedef struct packed {
    logic                             valid;         // Branch resolution valid
    logic [ReorderBufferTagWidth-1:0] tag;           // Reorder Buffer entry of the branch
    logic                             taken;         // Actual branch outcome
    logic [XLEN-1:0]                  target;        // Actual branch target
    // Misprediction flag (AUTHORITATIVE - computed by branch unit, not recomputed by Reorder Buffer):
    // - If taken != predicted_taken: direction misprediction
    // - If taken && predicted_taken && target != predicted_target: target misprediction
    // - Target comparison only meaningful when both taken and predicted_taken are true
    // The branch unit is the single source of truth for misprediction to avoid divergence.
    logic                             mispredicted;
    // Completion behavior:
    // - JAL: entry was already marked done=1 at dispatch (this update only records branch info)
    // - JALR: marks entry done=1 (value already contains link_addr from dispatch)
    // - Conditional branches: marks entry done=1 (no result value needed)
  } reorder_buffer_branch_update_t;

  // Reorder Buffer commit signals
  // NOTE: Exposes all serializing instruction flags so outer control logic can react
  typedef struct packed {
    logic valid;  // Commit this cycle
    logic [ReorderBufferTagWidth-1:0] tag;  // Reorder Buffer entry being committed
    logic dest_rf;  // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] dest_reg;
    logic dest_valid;  // Has destination register to write
    logic [FLEN-1:0] value;
    logic is_store;
    logic is_fp_store;
    logic exception;
    logic [XLEN-1:0] pc;  // For mepc
    exc_cause_t exc_cause;
    fp_flags_t fp_flags;  // FP flags to accumulate
    // Branch misprediction recovery
    logic misprediction;  // Branch mispredicted
    logic has_checkpoint;
    logic [CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] redirect_pc;  // Correct target on misprediction
    // Serializing instruction flags (for outer control logic)
    logic is_csr;  // CSR instruction (Reorder Buffer executes at commit)
    logic is_fence;  // FENCE (SQ must be drained)
    logic is_fence_i;  // FENCE.I (SQ drained, pipeline flush)
    logic is_wfi;  // WFI (stall until interrupt)
    logic is_mret;  // MRET (restore mstatus, redirect to mepc)
    // Atomic operation flags (for memory ordering and reservation handling)
    logic is_amo;  // AMO instruction (executed at head with SQ empty)
    logic is_lr;  // LR (load-reserved, sets reservation)
    logic is_sc;  // SC (store-conditional, checks reservation)
  } reorder_buffer_commit_t;

  // ---------------------------------------------------------------------------
  // RAT Entry and Checkpoint Structures
  // ---------------------------------------------------------------------------
  // Separate INT and FP RATs, each with checkpoint storage for speculation.

  // RAT entry (per architectural register)
  typedef struct packed {
    logic                             valid;  // Register is renamed (has in-flight producer)
    logic [ReorderBufferTagWidth-1:0] tag;    // Reorder Buffer tag of producer
  } rat_entry_t;

  // RAT lookup result (returned on source register read)
  typedef struct packed {
    logic                             renamed;  // Source is renamed (wait for Reorder Buffer tag)
    logic [ReorderBufferTagWidth-1:0] tag;      // Reorder Buffer tag if renamed
    logic [FLEN-1:0]                  value;    // Value from regfile if not renamed
  } rat_lookup_t;

  // Full RAT state (for checkpointing)
  // Note: x0 entry is included for simplicity but always returns 0/not-renamed
  typedef struct packed {rat_entry_t [NumIntRegs-1:0] entries;} int_rat_state_t;

  typedef struct packed {rat_entry_t [NumFpRegs-1:0] entries;} fp_rat_state_t;

  // Checkpoint structure (stores RAT state for branch recovery)
  typedef struct packed {
    logic                             valid;            // Checkpoint is active
    logic [ReorderBufferTagWidth-1:0] branch_tag;       // Reorder Buffer tag of associated branch
    int_rat_state_t                   int_rat;          // INT RAT snapshot
    fp_rat_state_t                    fp_rat;           // FP RAT snapshot
    // RAS state for recovery
    logic [RasPtrBits-1:0]            ras_tos;          // RAS top-of-stack pointer
    logic [RasPtrBits:0]              ras_valid_count;  // RAS valid entry count
  } checkpoint_t;

  // ---------------------------------------------------------------------------
  // Memory Operation Size Encoding
  // ---------------------------------------------------------------------------
  // Size encoding for memory operations.

  typedef enum logic [1:0] {
    MEM_SIZE_BYTE   = 2'b00,  // 8-bit
    MEM_SIZE_HALF   = 2'b01,  // 16-bit
    MEM_SIZE_WORD   = 2'b10,  // 32-bit
    MEM_SIZE_DOUBLE = 2'b11   // 64-bit (FLD/FSD only)
  } mem_size_e;

  // ---------------------------------------------------------------------------
  // Reservation Station Entry Structure
  // ---------------------------------------------------------------------------
  // Generic RS entry supporting up to 3 source operands (for FMA).
  // All values are FLEN-wide to support FP double precision.

  // RS entry structure (generic, used by all RS types)
  typedef struct packed {
    logic                             valid;    // Entry is allocated
    logic [ReorderBufferTagWidth-1:0] rob_tag;  // Destination Reorder Buffer entry
    instr_op_e                        op;       // Operation to perform

    // Source operand 1
    logic                             src1_ready;  // Operand 1 is available
    logic [ReorderBufferTagWidth-1:0] src1_tag;    // Reorder Buffer tag if not ready
    logic [FLEN-1:0]                  src1_value;  // Value if ready

    // Source operand 2
    logic                             src2_ready;  // Operand 2 is available
    logic [ReorderBufferTagWidth-1:0] src2_tag;    // Reorder Buffer tag if not ready
    logic [FLEN-1:0]                  src2_value;  // Value if ready

    // Source operand 3 (for FMA: rs3/fs3)
    logic                             src3_ready;  // Operand 3 is available
    logic [ReorderBufferTagWidth-1:0] src3_tag;    // Reorder Buffer tag if not ready
    logic [FLEN-1:0]                  src3_value;  // Value if ready

    // Immediate value (for immediate instructions)
    logic [XLEN-1:0] imm;      // Immediate value
    logic            use_imm;  // Use imm instead of src2

    // FP rounding mode (resolved from instruction rm or fcsr.frm at dispatch)
    logic [2:0] rm;  // Rounding mode (FRM_RNE, etc.)

    // For branches: pre-computed target from ID stage and BTB/RAS prediction
    logic [XLEN-1:0] branch_target;     // Pre-computed PC + imm (for branches/JAL)
    logic            predicted_taken;   // BTB predicted taken
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target

    // For memory operations: additional info
    logic      is_fp_mem;   // FP load/store (for LQ/SQ routing)
    mem_size_e mem_size;    // Memory operation size
    logic      mem_signed;  // Sign-extend on load

    // For CSR: address and immediate
    logic [11:0] csr_addr;  // CSR address
    logic [4:0]  csr_imm;   // Zero-extended CSR immediate
  } rs_entry_t;

  // RS dispatch request (from dispatch unit to RS)
  typedef struct packed {
    logic                             valid;             // Dispatch request valid
    rs_type_e                         rs_type;           // Which RS to dispatch to
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    instr_op_e                        op;
    // Source 1
    logic                             src1_ready;
    logic [ReorderBufferTagWidth-1:0] src1_tag;
    logic [FLEN-1:0]                  src1_value;
    // Source 2
    logic                             src2_ready;
    logic [ReorderBufferTagWidth-1:0] src2_tag;
    logic [FLEN-1:0]                  src2_value;
    // Source 3 (FMA only)
    logic                             src3_ready;
    logic [ReorderBufferTagWidth-1:0] src3_tag;
    logic [FLEN-1:0]                  src3_value;
    // Immediate
    logic [XLEN-1:0]                  imm;
    logic                             use_imm;
    // FP rounding mode
    logic [2:0]                       rm;
    // Branch info
    logic [XLEN-1:0]                  branch_target;
    logic                             predicted_taken;
    logic [XLEN-1:0]                  predicted_target;  // BTB/RAS predicted target
    // Memory info
    logic                             is_fp_mem;
    mem_size_e                        mem_size;
    logic                             mem_signed;
    // CSR info
    logic [11:0]                      csr_addr;
    logic [4:0]                       csr_imm;
  } rs_dispatch_t;

  // RS issue signals (from RS to functional unit)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    instr_op_e                        op;
    logic [FLEN-1:0]                  src1_value;
    logic [FLEN-1:0]                  src2_value;
    logic [FLEN-1:0]                  src3_value;        // For FMA
    logic [XLEN-1:0]                  imm;
    logic                             use_imm;
    logic [2:0]                       rm;                // Rounding mode
    logic [XLEN-1:0]                  branch_target;     // Pre-computed target
    logic                             predicted_taken;
    logic [XLEN-1:0]                  predicted_target;  // BTB/RAS predicted target
    // Memory info (for MEM_RS)
    logic                             is_fp_mem;
    mem_size_e                        mem_size;
    logic                             mem_signed;
    // CSR info
    logic [11:0]                      csr_addr;
    logic [4:0]                       csr_imm;
  } rs_issue_t;

  // ---------------------------------------------------------------------------
  // Load Queue Entry Structure
  // ---------------------------------------------------------------------------
  // Supports INT and FP loads, including 2-phase FLD (64-bit double on 32-bit bus).

  // Load queue entry
  typedef struct packed {
    logic valid;  // Entry allocated
    logic [ReorderBufferTagWidth-1:0] rob_tag;  // Associated Reorder Buffer entry
    logic is_fp;  // FP load (FLW/FLD)
    logic addr_valid;  // Address has been calculated
    logic [XLEN-1:0] address;  // Load address
    mem_size_e size;  // Memory operation size (FLD uses MEM_SIZE_DOUBLE)
    logic sign_ext;  // Sign extend result (INT only)
    logic is_mmio;  // MMIO address (non-speculative only)
    logic fp64_phase;  // FLD phase: 0=low word, 1=high word
    logic issued;  // Sent to memory
    logic data_valid;  // Data received
    logic [FLEN-1:0] data;  // Loaded data (FLEN for FLD)
    logic forwarded;  // Data from store queue forward
  } lq_entry_t;

  // LQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic                             is_fp;
    mem_size_e                        size;
    logic                             sign_ext;
  } lq_alloc_req_t;

  // LQ address update (from address calculation)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic [XLEN-1:0]                  address;
    logic                             is_mmio;
  } lq_addr_update_t;

  // ---------------------------------------------------------------------------
  // Store Queue Entry Structure
  // ---------------------------------------------------------------------------
  // Supports INT and FP stores, including 2-phase FSD.

  // Store queue entry
  typedef struct packed {
    logic valid;  // Entry allocated
    logic [ReorderBufferTagWidth-1:0] rob_tag;  // Associated Reorder Buffer entry
    logic is_fp;  // FP store (FSW/FSD)
    logic addr_valid;  // Address has been calculated
    logic [XLEN-1:0] address;  // Store address
    logic data_valid;  // Data is available
    logic [FLEN-1:0] data;  // Store data (FLEN for FSD)
    mem_size_e size;  // Memory operation size (FSD uses MEM_SIZE_DOUBLE)
    logic is_mmio;  // MMIO address (bypass cache)
    logic fp64_phase;  // FSD phase: 0=low word, 1=high word
    logic committed;  // Reorder Buffer has committed this store
    logic sent;  // Written to memory
  } sq_entry_t;

  // SQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic                             is_fp;
    mem_size_e                        size;
  } sq_alloc_req_t;

  // SQ address update (from address calculation)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic [XLEN-1:0]                  address;
    logic                             is_mmio;
  } sq_addr_update_t;

  // SQ data update (from RS operand becoming ready)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic [FLEN-1:0]                  data;
  } sq_data_update_t;

  // Store-to-load forwarding check result
  typedef struct packed {
    logic            match;        // Address match found
    logic            can_forward;  // Size compatible, can forward
    logic [FLEN-1:0] data;         // Forwarded data
  } sq_forward_result_t;

  // ---------------------------------------------------------------------------
  // CDB (Common Data Bus) Structures
  // ---------------------------------------------------------------------------
  // FLEN-wide CDB to support FP double precision results.

  // CDB broadcast (from functional unit to RS/Reorder Buffer/RAT)
  typedef struct packed {
    logic                             valid;      // Broadcast valid
    logic [ReorderBufferTagWidth-1:0] tag;        // Reorder Buffer tag of producing instruction
    logic [FLEN-1:0]                  value;      // Result value (FLEN for FP double)
    logic                             exception;  // Exception occurred
    exc_cause_t                       exc_cause;  // Exception cause
    fp_flags_t                        fp_flags;   // FP exception flags
    fu_type_e                         fu_type;    // Which FU produced this result
  } cdb_broadcast_t;

  // FU completion request (from FU to CDB arbiter)
  typedef struct packed {
    logic                             valid;      // FU has result ready
    logic [ReorderBufferTagWidth-1:0] tag;
    logic [FLEN-1:0]                  value;
    logic                             exception;
    exc_cause_t                       exc_cause;
    fp_flags_t                        fp_flags;
  } fu_complete_t;

  // CDB arbiter grant (to FU)
  typedef struct packed {
    logic granted;  // FU can broadcast this cycle
  } cdb_grant_t;

  // ---------------------------------------------------------------------------
  // Dispatch Interface Structures
  // ---------------------------------------------------------------------------
  // Signals between decode stage and dispatch unit.

  // Decoded instruction info (from ID stage to dispatch)
  typedef struct packed {
    logic            valid;  // Valid instruction
    logic [XLEN-1:0] pc;
    instr_op_e       op;

    // Destination register
    logic                    has_dest;  // Has destination register
    logic                    dest_rf;   // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] dest_reg;

    // Source registers
    logic                    uses_rs1;
    logic                    rs1_rf;    // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] rs1_addr;
    logic                    uses_rs2;
    logic                    rs2_rf;    // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] rs2_addr;
    logic                    uses_rs3;  // For FMA
    logic [RegAddrWidth-1:0] rs3_addr;  // Always FP

    // Immediate
    logic [XLEN-1:0] imm;
    logic            use_imm;

    // FP rounding mode (from instruction or DYN)
    logic [2:0] rm;
    logic       rm_is_dyn;  // Use fcsr.frm instead

    // Instruction classification
    rs_type_e rs_type;      // Which RS to use
    logic     is_branch;
    logic     is_call;
    logic     is_return;
    logic     is_store;
    logic     is_fp_store;
    logic     is_load;
    logic     is_fp_load;
    logic     is_csr;
    logic     is_fence;
    logic     is_fence_i;
    logic     is_wfi;
    logic     is_amo;
    logic     is_lr;
    logic     is_sc;

    // Memory operation info
    mem_size_e mem_size;
    logic      mem_signed;

    // Branch prediction info (passed through from IF)
    logic            predicted_taken;
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target
    logic [XLEN-1:0] branch_target;     // Pre-computed PC + imm

    // JAL/JALR link address (pre-computed PC+2 or PC+4 from IF)
    logic [XLEN-1:0] link_addr;
    logic            is_jal;     // JAL instruction
    logic            is_jalr;    // JALR instruction
    logic            is_mret;    // MRET instruction

    // CSR info
    logic [11:0] csr_addr;
    logic [4:0]  csr_imm;
  } decoded_instr_t;

  // Dispatch status (from dispatch to front-end)
  typedef struct packed {
    logic stall;                // Stall decode (Reorder Buffer/RS/LQ/SQ full)
    logic reorder_buffer_full;
    logic rs_full;              // Target RS is full
    logic lq_full;
    logic sq_full;
    logic checkpoint_full;      // All checkpoints in use (branch)
  } dispatch_status_t;

  // ---------------------------------------------------------------------------
  // Instruction Routing Table
  // ---------------------------------------------------------------------------
  // Helper function to determine RS assignment from instruction operation.

  function automatic rs_type_e get_rs_type(instr_op_e op);
    case (op)
      // Integer ALU operations -> INT_RS
      ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LUI, AUIPC, JAL, JALR,
      BEQ, BNE, BLT, BGE, BLTU, BGEU,
      // Zba/Zbb/Zbs/Zbkb/Zicond -> INT_RS (all 1-cycle ALU ops)
      SH1ADD, SH2ADD, SH3ADD,
      BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI,
      ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MAX, MAXU, MIN, MINU,
      SEXT_B, SEXT_H, ROL, ROR, RORI, ORC_B, REV8,
      CZERO_EQZ, CZERO_NEZ,
      PACK, PACKH, BREV8, ZIP, UNZIP,
      // CSR instructions -> INT_RS (execute at Reorder Buffer head)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // Privileged (exceptions) -> INT_RS
      ECALL, EBREAK:
      get_rs_type = RS_INT;

      // Multiply/divide -> MUL_RS
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU: get_rs_type = RS_MUL;

      // Memory operations -> MEM_RS (both INT and FP)
      LB, LH, LW, LBU, LHU, SB, SH, SW,
      FLW, FSW, FLD, FSD,
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      FENCE, FENCE_I:
      get_rs_type = RS_MEM;

      // FP add/sub/cmp/cvt/classify/sgnj -> FP_RS
      FADD_S, FSUB_S, FADD_D, FSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      FCVT_W_S, FCVT_WU_S, FCVT_S_W, FCVT_S_WU,
      FCVT_W_D, FCVT_WU_D, FCVT_D_W, FCVT_D_WU,
      FCVT_S_D, FCVT_D_S,
      FMV_X_W, FMV_W_X,
      FCLASS_S, FCLASS_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D:
      get_rs_type = RS_FP;

      // FP multiply/FMA -> FMUL_RS (3 sources for FMA)
      FMUL_S, FMUL_D, FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      get_rs_type = RS_FMUL;

      // FP divide/sqrt -> FDIV_RS (long latency)
      FDIV_S, FSQRT_S, FDIV_D, FSQRT_D: get_rs_type = RS_FDIV;

      // Instructions that don't need RS (dispatch directly to Reorder Buffer)
      WFI, MRET, PAUSE: get_rs_type = RS_NONE;

      default: get_rs_type = RS_INT;  // Default fallback
    endcase
  endfunction

  // Helper function to determine if instruction has integer destination
  function automatic logic has_int_dest(instr_op_e op);
    case (op)
      // Integer ALU ops with rd
      ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LUI, AUIPC, JAL, JALR,
      // B-extension
      SH1ADD, SH2ADD, SH3ADD,
      BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI,
      ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MAX, MAXU, MIN, MINU,
      SEXT_B, SEXT_H, ROL, ROR, RORI, ORC_B, REV8,
      CZERO_EQZ, CZERO_NEZ, PACK, PACKH, BREV8, ZIP, UNZIP,
      // M-extension
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU,
      // Integer loads
      LB, LH, LW, LBU, LHU,
      // Atomics (return old value to rd)
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      // CSR (return old CSR value to rd)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // FP compare -> INT rd
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP classify -> INT rd
      FCLASS_S, FCLASS_D,
      // FP to INT conversion -> INT rd
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D,
      // FP to INT bit move -> INT rd
      FMV_X_W:
      has_int_dest = 1'b1;

      default: has_int_dest = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction has FP destination
  function automatic logic has_fp_dest(instr_op_e op);
    case (op)
      // FP loads
      FLW, FLD,
      // FP compute ops
      FADD_S, FSUB_S, FMUL_S, FDIV_S, FSQRT_S,
      FADD_D, FSUB_D, FMUL_D, FDIV_D, FSQRT_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // INT to FP conversion -> FP fd
      FCVT_S_W, FCVT_S_WU, FCVT_D_W, FCVT_D_WU,
      // FP format conversion
      FCVT_S_D, FCVT_D_S,
      // INT to FP bit move -> FP fd
      FMV_W_X:
      has_fp_dest = 1'b1;

      default: has_fp_dest = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs1
  function automatic logic uses_fp_rs1(instr_op_e op);
    case (op)
      // FP compute ops (fs1)
      FADD_S, FSUB_S, FMUL_S, FDIV_S, FSQRT_S,
      FADD_D, FSUB_D, FMUL_D, FDIV_D, FSQRT_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // FP compare (fs1, fs2) -> INT rd
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP classify (fs1) -> INT rd
      FCLASS_S, FCLASS_D,
      // FP to INT conversion (fs1) -> INT rd
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D,
      // FP to INT bit move (fs1) -> INT rd
      FMV_X_W,
      // FP format conversion
      FCVT_S_D, FCVT_D_S:
      uses_fp_rs1 = 1'b1;

      default: uses_fp_rs1 = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs2
  function automatic logic uses_fp_rs2(instr_op_e op);
    case (op)
      // FP compute ops with 2+ sources
      FADD_S, FSUB_S, FMUL_S,
      FADD_D, FSUB_D, FMUL_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // FP compare (fs1, fs2)
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP stores (base=INT rs1, data=FP rs2)
      FSW, FSD:
      uses_fp_rs2 = 1'b1;

      default: uses_fp_rs2 = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs3 (FMA only)
  function automatic logic uses_fp_rs3(instr_op_e op);
    case (op)
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      uses_fp_rs3 = 1'b1;

      default: uses_fp_rs3 = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Control Flow Classification Helpers
  // ---------------------------------------------------------------------------
  // Unified classification functions to prevent flag drift between is_branch,
  // is_jal, is_jalr, is_call, is_return.

  // Is this a branch or jump instruction? (needs checkpoint, can mispredict)
  function automatic logic is_branch_or_jump_op(instr_op_e op);
    case (op)
      BEQ, BNE, BLT, BGE, BLTU, BGEU,  // Conditional branches
      JAL, JALR:  // Unconditional jumps
      is_branch_or_jump_op = 1'b1;
      default: is_branch_or_jump_op = 1'b0;
    endcase
  endfunction

  // Is this a JAL instruction? (target known at decode, can mark done=1 at dispatch)
  function automatic logic is_jal_op(instr_op_e op);
    is_jal_op = (op == JAL);
  endfunction

  // Is this a JALR instruction? (target depends on rs1, resolved in execute)
  function automatic logic is_jalr_op(instr_op_e op);
    is_jalr_op = (op == JALR);
  endfunction

  // Is this a call instruction? (pushes to RAS)
  // Note: This function only checks the opcode; caller must also check rd
  function automatic logic is_potential_call_op(instr_op_e op);
    is_potential_call_op = (op == JAL) || (op == JALR);
  endfunction

  // Is this a return instruction? (pops from RAS)
  // Note: This function only checks the opcode; caller must also check rs1/rd/imm
  function automatic logic is_potential_return_op(instr_op_e op);
    is_potential_return_op = (op == JALR);
  endfunction

  // Is this a conditional branch? (not JAL/JALR)
  function automatic logic is_conditional_branch_op(instr_op_e op);
    case (op)
      BEQ, BNE, BLT, BGE, BLTU, BGEU: is_conditional_branch_op = 1'b1;
      default: is_conditional_branch_op = 1'b0;
    endcase
  endfunction

endpackage : riscv_pkg
