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
  Instruction decoder for RISC-V RV32IMAFB + Zicsr + Machine-mode privileged.
  B extension = Zba + Zbb + Zbs (full bit manipulation).
  F extension = Single-precision floating-point.
  This combinational module decodes 32-bit RISC-V instructions into control signals
  for the execute stage. It extracts the opcode and function fields to determine the
  specific operation, then generates appropriate control signals for the ALU, FPU,
  branch unit, and memory interface. The decoder supports the base integer instruction
  set (RV32I), M-extension for integer multiply and divide, A-extension for atomics
  (LR.W, SC.W, AMO), F-extension for single-precision floating-point, B-extension
  (Zba, Zbb, Zbs), plus Zicond, Zbkb, Zicsr for CSR access, and privileged instructions
  (MRET, WFI, ECALL, EBREAK) for trap/interrupt handling.
  Output signals indicate the operation type, branch condition, and store size for
  proper execution in later pipeline stages.
 */
module instr_decoder (
    input  riscv_pkg::instr_t    i_instr,
    output riscv_pkg::instr_op_e o_instr_op,
    output riscv_pkg::store_op_e o_store_op,
    output riscv_pkg::branch_taken_op_e o_branch_taken_op
);

  always_comb begin
    // default values
    o_instr_op = riscv_pkg::ADDI;
    o_branch_taken_op = riscv_pkg::NULL;
    o_store_op = riscv_pkg::STN;

    unique case (i_instr.opcode)
      // Register-register operations (R-type format)
      riscv_pkg::OPC_OP:
      unique case ({
        i_instr.funct7, i_instr.funct3
      })
        // Base RV32I arithmetic and logical operations
        10'b0000000_000: o_instr_op = riscv_pkg::ADD;
        10'b0100000_000: o_instr_op = riscv_pkg::SUB;
        10'b0000000_111: o_instr_op = riscv_pkg::AND;
        10'b0000000_110: o_instr_op = riscv_pkg::OR;
        10'b0000000_100: o_instr_op = riscv_pkg::XOR;
        10'b0000000_001: o_instr_op = riscv_pkg::SLL;
        10'b0000000_101: o_instr_op = riscv_pkg::SRL;
        10'b0100000_101: o_instr_op = riscv_pkg::SRA;
        10'b0000000_010: o_instr_op = riscv_pkg::SLT;
        10'b0000000_011: o_instr_op = riscv_pkg::SLTU;
        // RV32M multiply and divide operations
        10'b0000001_000: o_instr_op = riscv_pkg::MUL;
        10'b0000001_001: o_instr_op = riscv_pkg::MULH;
        10'b0000001_010: o_instr_op = riscv_pkg::MULHSU;
        10'b0000001_011: o_instr_op = riscv_pkg::MULHU;
        10'b0000001_100: o_instr_op = riscv_pkg::DIV;
        10'b0000001_101: o_instr_op = riscv_pkg::DIVU;
        10'b0000001_110: o_instr_op = riscv_pkg::REM;
        10'b0000001_111: o_instr_op = riscv_pkg::REMU;
        // Zba extension (address generation)
        10'b0010000_010: o_instr_op = riscv_pkg::SH1ADD;
        10'b0010000_100: o_instr_op = riscv_pkg::SH2ADD;
        10'b0010000_110: o_instr_op = riscv_pkg::SH3ADD;
        // Zbs extension (single-bit operations, register form)
        10'b0010100_001: o_instr_op = riscv_pkg::BSET;
        10'b0100100_001: o_instr_op = riscv_pkg::BCLR;
        10'b0110100_001: o_instr_op = riscv_pkg::BINV;
        10'b0100100_101: o_instr_op = riscv_pkg::BEXT;
        // Zbb extension (basic bit manipulation, register form)
        10'b0100000_111: o_instr_op = riscv_pkg::ANDN;
        10'b0100000_110: o_instr_op = riscv_pkg::ORN;
        10'b0100000_100: o_instr_op = riscv_pkg::XNOR;
        10'b0000101_110: o_instr_op = riscv_pkg::MAX;
        10'b0000101_111: o_instr_op = riscv_pkg::MAXU;
        10'b0000101_100: o_instr_op = riscv_pkg::MIN;
        10'b0000101_101: o_instr_op = riscv_pkg::MINU;
        10'b0110000_001: o_instr_op = riscv_pkg::ROL;
        10'b0110000_101: o_instr_op = riscv_pkg::ROR;
        // Zbkb extension (bit manipulation for crypto)
        10'b0000100_100:
        o_instr_op = riscv_pkg::PACK;  // Pack halfwords (zext.h is pack with rs2=0)
        10'b0000100_111: o_instr_op = riscv_pkg::PACKH;  // Pack bytes
        // Zicond extension (conditional operations)
        10'b0000111_101: o_instr_op = riscv_pkg::CZERO_EQZ;
        10'b0000111_111: o_instr_op = riscv_pkg::CZERO_NEZ;
        default: ;
      endcase

      // =========================================================================
      // Register-immediate operations (I-type format)
      // Decoding: opcode -> funct3 -> funct7 -> rs2 (for some Zbb/Zbkb)
      // =========================================================================
      riscv_pkg::OPC_OP_IMM:
      unique case (i_instr.funct3)
        // --- Simple I-type (no funct7 disambiguation) ---
        3'b000: o_instr_op = riscv_pkg::ADDI;  // Add immediate
        3'b111: o_instr_op = riscv_pkg::ANDI;  // AND immediate
        3'b110: o_instr_op = riscv_pkg::ORI;  // OR immediate
        3'b100: o_instr_op = riscv_pkg::XORI;  // XOR immediate
        3'b010: o_instr_op = riscv_pkg::SLTI;  // Set less than immediate (signed)
        3'b011: o_instr_op = riscv_pkg::SLTIU;  // Set less than immediate (unsigned)

        // --- funct3=001: Shift-left family (uses funct7) ---
        3'b001:
        unique case (i_instr.funct7)
          7'b0000000: o_instr_op = riscv_pkg::SLLI;  // Base: Shift left logical
          7'b0010100: o_instr_op = riscv_pkg::BSETI;  // Zbs: Set single bit
          7'b0100100: o_instr_op = riscv_pkg::BCLRI;  // Zbs: Clear single bit
          7'b0110100: o_instr_op = riscv_pkg::BINVI;  // Zbs: Invert single bit
          7'b0110000:
          unique case (i_instr.source_reg_2)  // Zbb unary ops (use rs2 field)
            5'b00000: o_instr_op = riscv_pkg::CLZ;  // Count leading zeros
            5'b00001: o_instr_op = riscv_pkg::CTZ;  // Count trailing zeros
            5'b00010: o_instr_op = riscv_pkg::CPOP;  // Population count
            5'b00100: o_instr_op = riscv_pkg::SEXT_B;  // Sign-extend byte
            5'b00101: o_instr_op = riscv_pkg::SEXT_H;  // Sign-extend halfword
            default:  ;
          endcase
          7'b0000100:
          if (i_instr.source_reg_2 == 5'b01111)
            o_instr_op = riscv_pkg::ZIP;  // Zbkb: Bit interleave
          default: ;
        endcase

        // --- funct3=101: Shift-right family (uses funct7) ---
        3'b101:
        unique case (i_instr.funct7)
          7'b0000000: o_instr_op = riscv_pkg::SRLI;  // Base: Shift right logical
          7'b0100000: o_instr_op = riscv_pkg::SRAI;  // Base: Shift right arithmetic
          7'b0100100: o_instr_op = riscv_pkg::BEXTI;  // Zbs: Extract single bit
          7'b0110000: o_instr_op = riscv_pkg::RORI;  // Zbb: Rotate right
          7'b0010100: o_instr_op = riscv_pkg::ORC_B;  // Zbb: OR-combine bytes
          7'b0110100:
          unique case (i_instr.source_reg_2)  // Zbb/Zbkb byte ops
            5'b11000: o_instr_op = riscv_pkg::REV8;  // Zbb: Byte-reverse
            5'b00111: o_instr_op = riscv_pkg::BREV8;  // Zbkb: Bit-reverse bytes
            default:  ;
          endcase
          7'b0000100:
          if (i_instr.source_reg_2 == 5'b01111)
            o_instr_op = riscv_pkg::UNZIP;  // Zbkb: Bit deinterleave
          default: ;
        endcase

        default: ;
      endcase

      // Load upper immediate (U-type)
      riscv_pkg::OPC_LUI: o_instr_op = riscv_pkg::LUI;

      // Add upper immediate to PC (U-type)
      riscv_pkg::OPC_AUIPC: o_instr_op = riscv_pkg::AUIPC;

      // Jump and link (J-type) - unconditional jump, save return address
      riscv_pkg::OPC_JAL: begin
        o_instr_op = riscv_pkg::JAL;
        o_branch_taken_op = riscv_pkg::JUMP;
      end

      // Jump and link register (I-type) - jump to register value + offset
      riscv_pkg::OPC_JALR:
      if (i_instr.funct3 == 3'b000) begin
        o_instr_op = riscv_pkg::JALR;
        o_branch_taken_op = riscv_pkg::JUMP;
      end

      // Branch instructions (B-type) - conditional branches
      riscv_pkg::OPC_BRANCH:
      unique case (i_instr.funct3)
        3'b000: begin  // Branch if equal
          o_instr_op = riscv_pkg::BEQ;
          o_branch_taken_op = riscv_pkg::BREQ;
        end
        3'b001: begin  // Branch if not equal
          o_instr_op = riscv_pkg::BNE;
          o_branch_taken_op = riscv_pkg::BRNE;
        end
        3'b100: begin  // Branch if less than (signed)
          o_instr_op = riscv_pkg::BLT;
          o_branch_taken_op = riscv_pkg::BRLT;
        end
        3'b101: begin  // Branch if greater or equal (signed)
          o_instr_op = riscv_pkg::BGE;
          o_branch_taken_op = riscv_pkg::BRGE;
        end
        3'b110: begin  // Branch if less than (unsigned)
          o_instr_op = riscv_pkg::BLTU;
          o_branch_taken_op = riscv_pkg::BRLTU;
        end
        3'b111: begin  // Branch if greater or equal (unsigned)
          o_instr_op = riscv_pkg::BGEU;
          o_branch_taken_op = riscv_pkg::BRGEU;
        end
        default: ;
      endcase

      // Load instructions (I-type) - read from memory to register
      riscv_pkg::OPC_LOAD:
      unique case (i_instr.funct3)
        3'b000:  o_instr_op = riscv_pkg::LB;  // Load byte (sign-extended)
        3'b001:  o_instr_op = riscv_pkg::LH;  // Load halfword (sign-extended)
        3'b010:  o_instr_op = riscv_pkg::LW;  // Load word
        3'b100:  o_instr_op = riscv_pkg::LBU;  // Load byte unsigned (zero-extended)
        3'b101:  o_instr_op = riscv_pkg::LHU;  // Load halfword unsigned (zero-extended)
        default: ;
      endcase

      // Store instructions (S-type) - write from register to memory
      riscv_pkg::OPC_STORE:
      unique case (i_instr.funct3)
        3'b000: begin  // Store byte (8 bits)
          o_instr_op = riscv_pkg::SB;
          o_store_op = riscv_pkg::STB;
        end
        3'b001: begin  // Store halfword (16 bits)
          o_instr_op = riscv_pkg::SH;
          o_store_op = riscv_pkg::STH;
        end
        3'b010: begin  // Store word (32 bits)
          o_instr_op = riscv_pkg::SW;
          o_store_op = riscv_pkg::STW;
        end
        default: ;
      endcase

      // Memory ordering instructions (Zifencei extension)
      // FENCE.I is effectively a NOP in this design since there is no instruction cache.
      // The unified memory ensures instruction coherency without explicit fencing.
      riscv_pkg::OPC_MISC_MEM:
      unique case (i_instr.funct3)
        3'b000:
        // PAUSE is encoded as FENCE with pred=W (0001), succ=0, all other fields 0
        // Full encoding: 0x0100000F, funct7=0b0000001
        if (i_instr.funct7 == 7'b0000001 && i_instr.source_reg_2 == 5'b0 &&
            i_instr.source_reg_1 == 5'b0 && i_instr.dest_reg == 5'b0)
          o_instr_op = riscv_pkg::PAUSE;  // Zihintpause: hint to pause
        else o_instr_op = riscv_pkg::FENCE;  // FENCE (memory ordering)
        3'b001: o_instr_op = riscv_pkg::FENCE_I;  // FENCE.I (instruction fetch ordering)
        default: ;
      endcase

      // CSR and SYSTEM instructions (Zicsr extension + privileged)
      // funct3=0 is PRIV (privileged system instructions), others are CSR operations
      riscv_pkg::OPC_CSR:
      unique case (i_instr.funct3)
        3'b000:  // PRIV - privileged system instructions
        unique case ({
          i_instr.funct7, i_instr.source_reg_2
        })
          // ECALL: environment call (system call) - encoding 0x00000073
          12'b0000000_00000: o_instr_op = riscv_pkg::ECALL;
          // EBREAK: breakpoint exception - encoding 0x00100073
          12'b0000000_00001: o_instr_op = riscv_pkg::EBREAK;
          // MRET: return from machine-mode trap - encoding 0x30200073
          12'b0011000_00010: o_instr_op = riscv_pkg::MRET;
          // WFI: wait for interrupt - encoding 0x10500073
          12'b0001000_00101: o_instr_op = riscv_pkg::WFI;
          default: ;
        endcase
        riscv_pkg::CSR_RW: o_instr_op = riscv_pkg::CSRRW;  // Atomic read/write
        riscv_pkg::CSR_RS: o_instr_op = riscv_pkg::CSRRS;  // Atomic read and set bits
        riscv_pkg::CSR_RC: o_instr_op = riscv_pkg::CSRRC;  // Atomic read and clear bits
        riscv_pkg::CSR_RWI: o_instr_op = riscv_pkg::CSRRWI;  // Atomic read/write immediate
        riscv_pkg::CSR_RSI: o_instr_op = riscv_pkg::CSRRSI;  // Atomic read and set bits immediate
        riscv_pkg::CSR_RCI: o_instr_op = riscv_pkg::CSRRCI;  // Atomic read and clear bits immediate
        default: ;
      endcase

      // A extension (atomics) - all use funct3=010 for word operations
      // funct5 is in funct7[6:2] (instruction bits 31:27)
      riscv_pkg::OPC_AMO:
      if (i_instr.funct3 == 3'b010)  // .W (word) operations only
        unique case (i_instr.funct7[6:2])  // funct5
          5'b00010: o_instr_op = riscv_pkg::LR_W;  // Load-reserved
          5'b00011: o_instr_op = riscv_pkg::SC_W;  // Store-conditional
          5'b00001: o_instr_op = riscv_pkg::AMOSWAP_W;  // Atomic swap
          5'b00000: o_instr_op = riscv_pkg::AMOADD_W;  // Atomic add
          5'b00100: o_instr_op = riscv_pkg::AMOXOR_W;  // Atomic XOR
          5'b01100: o_instr_op = riscv_pkg::AMOAND_W;  // Atomic AND
          5'b01000: o_instr_op = riscv_pkg::AMOOR_W;  // Atomic OR
          5'b10000: o_instr_op = riscv_pkg::AMOMIN_W;  // Atomic minimum (signed)
          5'b10100: o_instr_op = riscv_pkg::AMOMAX_W;  // Atomic maximum (signed)
          5'b11000: o_instr_op = riscv_pkg::AMOMINU_W;  // Atomic minimum (unsigned)
          5'b11100: o_instr_op = riscv_pkg::AMOMAXU_W;  // Atomic maximum (unsigned)
          default:  ;
        endcase

      // =========================================================================
      // F extension (single-precision floating-point)
      // =========================================================================

      // FLW/FLD - Load floating-point word/double (I-type format)
      // Uses integer rs1 for address, writes to FP rd
      riscv_pkg::OPC_LOAD_FP:
      if (i_instr.funct3 == 3'b010) begin  // width=W (32-bit)
        o_instr_op = riscv_pkg::FLW;
      end else if (i_instr.funct3 == 3'b011) begin  // width=D (64-bit)
        o_instr_op = riscv_pkg::FLD;
      end

      // FSW/FSD - Store floating-point word/double (S-type format)
      // Uses integer rs1 for address, FP rs2 for data
      riscv_pkg::OPC_STORE_FP:
      if (i_instr.funct3 == 3'b010) begin  // width=W (32-bit)
        o_instr_op = riscv_pkg::FSW;
        o_store_op = riscv_pkg::STW;  // 32-bit store
      end else if (i_instr.funct3 == 3'b011) begin  // width=D (64-bit)
        o_instr_op = riscv_pkg::FSD;
        o_store_op = riscv_pkg::STN;  // Handled by FP64 store unit
      end

      // Fused multiply-add variants (R4-type format)
      // rs3 is in funct7[6:2], fmt is in funct7[1:0] (00=S, 01=D)
      riscv_pkg::OPC_FMADD:
      if (i_instr.funct7[1:0] == 2'b00)  // fmt=S
        o_instr_op = riscv_pkg::FMADD_S;  // rd = (rs1 * rs2) + rs3
      else if (i_instr.funct7[1:0] == 2'b01)  // fmt=D
        o_instr_op = riscv_pkg::FMADD_D;

      riscv_pkg::OPC_FMSUB:
      if (i_instr.funct7[1:0] == 2'b00)  // fmt=S
        o_instr_op = riscv_pkg::FMSUB_S;  // rd = (rs1 * rs2) - rs3
      else if (i_instr.funct7[1:0] == 2'b01)  // fmt=D
        o_instr_op = riscv_pkg::FMSUB_D;

      riscv_pkg::OPC_FNMSUB:
      if (i_instr.funct7[1:0] == 2'b00)  // fmt=S
        o_instr_op = riscv_pkg::FNMSUB_S;  // rd = -(rs1 * rs2) + rs3
      else if (i_instr.funct7[1:0] == 2'b01)  // fmt=D
        o_instr_op = riscv_pkg::FNMSUB_D;

      riscv_pkg::OPC_FNMADD:
      if (i_instr.funct7[1:0] == 2'b00)  // fmt=S
        o_instr_op = riscv_pkg::FNMADD_S;  // rd = -(rs1 * rs2) - rs3
      else if (i_instr.funct7[1:0] == 2'b01)  // fmt=D
        o_instr_op = riscv_pkg::FNMADD_D;

      // FP arithmetic operations (R-type format)
      // funct7 determines the operation, funct3 is rounding mode (or sub-operation)
      riscv_pkg::OPC_OP_FP:
      unique case (i_instr.funct7)
        // Basic arithmetic (rd = fs1 op fs2)
        7'b0000000: o_instr_op = riscv_pkg::FADD_S;  // Floating-point add
        7'b0000001: o_instr_op = riscv_pkg::FADD_D;  // Floating-point add (double)
        7'b0000100: o_instr_op = riscv_pkg::FSUB_S;  // Floating-point subtract
        7'b0000101: o_instr_op = riscv_pkg::FSUB_D;  // Floating-point subtract (double)
        7'b0001000: o_instr_op = riscv_pkg::FMUL_S;  // Floating-point multiply
        7'b0001001: o_instr_op = riscv_pkg::FMUL_D;  // Floating-point multiply (double)
        7'b0001100: o_instr_op = riscv_pkg::FDIV_S;  // Floating-point divide
        7'b0001101: o_instr_op = riscv_pkg::FDIV_D;  // Floating-point divide (double)

        // Square root (rd = sqrt(fs1), rs2 must be 0)
        7'b0101100: if (i_instr.source_reg_2 == 5'b00000) o_instr_op = riscv_pkg::FSQRT_S;
        7'b0101101: if (i_instr.source_reg_2 == 5'b00000) o_instr_op = riscv_pkg::FSQRT_D;

        // Sign injection (rd = sign-manipulated fs1 using fs2's sign)
        7'b0010000:
        unique case (i_instr.funct3)
          3'b000:  o_instr_op = riscv_pkg::FSGNJ_S;  // Copy fs2's sign to fs1
          3'b001:  o_instr_op = riscv_pkg::FSGNJN_S;  // Copy negated fs2's sign to fs1
          3'b010:  o_instr_op = riscv_pkg::FSGNJX_S;  // XOR fs1's sign with fs2's sign
          default: ;
        endcase
        7'b0010001:
        unique case (i_instr.funct3)
          3'b000:  o_instr_op = riscv_pkg::FSGNJ_D;
          3'b001:  o_instr_op = riscv_pkg::FSGNJN_D;
          3'b010:  o_instr_op = riscv_pkg::FSGNJX_D;
          default: ;
        endcase

        // Min/Max (rd = min/max(fs1, fs2))
        7'b0010100:
        unique case (i_instr.funct3)
          3'b000:  o_instr_op = riscv_pkg::FMIN_S;  // Floating-point minimum
          3'b001:  o_instr_op = riscv_pkg::FMAX_S;  // Floating-point maximum
          default: ;
        endcase
        7'b0010101:
        unique case (i_instr.funct3)
          3'b000:  o_instr_op = riscv_pkg::FMIN_D;
          3'b001:  o_instr_op = riscv_pkg::FMAX_D;
          default: ;
        endcase

        // Convert FP to signed/unsigned integer (rd = int(fs1), rs2 selects signed/unsigned)
        7'b1100000:
        unique case (i_instr.source_reg_2)
          5'b00000: o_instr_op = riscv_pkg::FCVT_W_S;  // Convert to signed 32-bit
          5'b00001: o_instr_op = riscv_pkg::FCVT_WU_S;  // Convert to unsigned 32-bit
          default:  ;
        endcase
        7'b1100001:
        unique case (i_instr.source_reg_2)
          5'b00000: o_instr_op = riscv_pkg::FCVT_W_D;
          5'b00001: o_instr_op = riscv_pkg::FCVT_WU_D;
          default:  ;
        endcase

        // Convert signed/unsigned integer to FP (fd = float(rs1), rs2 selects signed/unsigned)
        7'b1101000:
        unique case (i_instr.source_reg_2)
          5'b00000: o_instr_op = riscv_pkg::FCVT_S_W;  // Convert from signed 32-bit
          5'b00001: o_instr_op = riscv_pkg::FCVT_S_WU;  // Convert from unsigned 32-bit
          default:  ;
        endcase
        7'b1101001:
        unique case (i_instr.source_reg_2)
          5'b00000: o_instr_op = riscv_pkg::FCVT_D_W;
          5'b00001: o_instr_op = riscv_pkg::FCVT_D_WU;
          default:  ;
        endcase

        // Convert between single and double precision
        7'b0100000: if (i_instr.source_reg_2 == 5'b00001) o_instr_op = riscv_pkg::FCVT_S_D;
        7'b0100001: if (i_instr.source_reg_2 == 5'b00000) o_instr_op = riscv_pkg::FCVT_D_S;

        // Move FP bits to integer register, or classify (rd = bits(fs1) or class(fs1))
        7'b1110000:
        if (i_instr.source_reg_2 == 5'b00000)
          unique case (i_instr.funct3)
            3'b000:  o_instr_op = riscv_pkg::FMV_X_W;  // Move FP bits to integer
            3'b001:  o_instr_op = riscv_pkg::FCLASS_S;  // Classify FP value
            default: ;
          endcase
        7'b1110001:
        if (i_instr.source_reg_2 == 5'b00000)
          unique case (i_instr.funct3)
            3'b001:  o_instr_op = riscv_pkg::FCLASS_D;
            default: ;
          endcase

        // Move integer bits to FP register (fd = bits(rs1))
        7'b1111000:
        if (i_instr.source_reg_2 == 5'b00000 && i_instr.funct3 == 3'b000)
          o_instr_op = riscv_pkg::FMV_W_X;

        // Comparison (rd = compare(fs1, fs2), result is 0 or 1 in integer register)
        7'b1010000:
        unique case (i_instr.funct3)
          3'b010:  o_instr_op = riscv_pkg::FEQ_S;  // Floating-point equal
          3'b001:  o_instr_op = riscv_pkg::FLT_S;  // Floating-point less than
          3'b000:  o_instr_op = riscv_pkg::FLE_S;  // Floating-point less than or equal
          default: ;
        endcase
        7'b1010001:
        unique case (i_instr.funct3)
          3'b010:  o_instr_op = riscv_pkg::FEQ_D;
          3'b001:  o_instr_op = riscv_pkg::FLT_D;
          3'b000:  o_instr_op = riscv_pkg::FLE_D;
          default: ;
        endcase

        default: ;
      endcase

      default: o_instr_op = riscv_pkg::ADDI;  // Unknown opcodes decode as NOP (ADDI x0, x0, 0)
    endcase
  end

endmodule : instr_decoder
