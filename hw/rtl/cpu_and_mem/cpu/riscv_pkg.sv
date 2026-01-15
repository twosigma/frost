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
    OPC_AMO      = 7'b0101111   // A extension (atomics)
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
    AMOMAXU_W   // Atomic maximum (unsigned)
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
    logic stall;                      // Freeze pipeline (don't advance)
    logic stall_registered;           // Stall signal from previous cycle
    logic stall_for_load_use_hazard;  // Stall due to load-use dependency
    logic stall_for_trap_check;       // Stall conditions for trap unit (before trap/mret gating)
    logic flush;                      // Clear pipeline (insert bubble/NOP)
    logic amo_wb_write_enable;        // Force regfile write for AMO result
    // Registered trap/mret signals for timing optimization
    // These break the path from EX stage exception detection through IF stage
    logic trap_taken_registered;      // trap_taken from previous cycle
    logic mret_taken_registered;      // mret_taken from previous cycle
    // TIMING OPTIMIZATION: Raw hazard detection without multiply precedence check.
    // Used by AMO unit to break the path: multiply_completing → stall_for_mul_div
    // → stall_for_load_use_hazard → stall_excluding_amo
    logic load_use_hazard_detected;   // Raw load-use hazard (no multiply precedence)
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
  } from_ex_comb_t;

  // Clocked signals passed from Execute (EX) stage to Memory Access (MA) stage
  typedef struct packed {
    logic [XLEN-1:0] alu_result;
    logic            regfile_write_enable;
    logic [XLEN-1:0] data_memory_address;
    instr_t          instruction;
    logic            is_load_instruction;
    logic            is_load_byte;
    logic            is_load_halfword;
    logic            is_load_unsigned;
    // A extension (atomics)
    logic            is_amo_instruction;
    logic            is_lr;
    logic            is_sc;
    logic            sc_success;             // SC.W succeeded (0 goes to rd on success, 1 on fail)
    instr_op_e       instruction_operation;  // Needed for AMO operation type
    logic [XLEN-1:0] rs2_value;              // Needed for SC and AMO operations
  } from_ex_to_ma_t;

  // Combinational signals passed from Memory Access (MA)
  typedef struct packed {
    logic [XLEN-1:0] data_memory_read_data;    // Raw data from memory
    logic [XLEN-1:0] data_loaded_from_memory;  // Processed load data (sign-extended, etc.)
  } from_ma_comb_t;

  // Clocked signals passed from Memory Access (MA) stage to Writeback (WB) stage
  typedef struct packed {
    logic regfile_write_enable;
    logic [XLEN-1:0] regfile_write_data;  // Final result to write back
    instr_t instruction;
  } from_ma_to_wb_t;

  // Signals from L0 Cache
  typedef struct packed {
    logic cache_hit_on_load;
    logic [XLEN-1:0] data_loaded_from_cache;
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
  } fwd_to_ex_t;

  // Register file read data to Forwarding unit
  typedef struct packed {
    logic [XLEN-1:0] source_reg_1_data;
    logic [XLEN-1:0] source_reg_2_data;
  } rf_to_fwd_t;

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

endpackage : riscv_pkg
