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
 * Shared types, constants, helpers, and pipeline payloads for FROST RV64GCB.
 *
 * Contents:
 * =========
 *   Section 1: Instruction Opcodes (opc_e) and the IMEM predecode sideband
 *   Section 2: Instruction Operations (instr_op_e)
 *   Section 3: CSR Definitions (addresses, bit positions, cause codes)
 *   Section 4: Control Enumerations (branch_taken_op_e, store_op_e)
 *   Section 5: Instruction Format (instr_t), XLEN, memory map, PMA, Sv39, constants
 *   Section 6: Pipeline Control (pipeline_ctrl_t)
 *   Section 7: Inter-Stage Data Structures (from_*_to_*_t)
 *   Section 8: Operand and Register File Structures
 *   Section 9: Trap/Exception Handling
 *   Section 10: Bit Manipulation Helper Functions (clz, ctz, cpop), multiplier depth
 *   Section 11: Tomasulo OOO Execution (Reorder Buffer, RS, LQ, SQ, CDB, RAT)
 *
 * Supported Extensions:
 * =====================
 *   RV64I   - Base integer instruction set
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
 * Yosys does not support inter-package references, so these definitions remain
 * in one package.
 */
package riscv_pkg;

  // ===========================================================================
  // Section 1: Instruction Opcodes
  // ===========================================================================
  // Primary opcode field (bits [6:0]) identifies instruction category.
  // These map directly to the RISC-V base instruction encoding.

  typedef enum bit [6:0] {
    OPC_LUI       = 7'b0110111,
    OPC_AUIPC     = 7'b0010111,
    OPC_JAL       = 7'b1101111,
    OPC_JALR      = 7'b1100111,
    OPC_BRANCH    = 7'b1100011,
    OPC_LOAD      = 7'b0000011,
    OPC_STORE     = 7'b0100011,
    OPC_OP_IMM    = 7'b0010011,
    OPC_OP        = 7'b0110011,
    // W-form opcodes
    OPC_OP_IMM_32 = 7'b0011011,  // ADDIW, SLLIW, SRLIW, SRAIW
    OPC_OP_32     = 7'b0111011,  // ADDW, SUBW, SLLW, SRLW, SRAW
    OPC_MISC_MEM  = 7'b0001111,  // FENCE, FENCE.I (Zifencei)
    OPC_CSR       = 7'b1110011,
    OPC_AMO       = 7'b0101111,  // A extension (atomics)
    // F extension (single-precision floating-point)
    OPC_LOAD_FP   = 7'b0000111,  // FLW
    OPC_STORE_FP  = 7'b0100111,  // FSW
    OPC_FMADD     = 7'b1000011,  // FMADD.S
    OPC_FMSUB     = 7'b1000111,  // FMSUB.S
    OPC_FNMSUB    = 7'b1001011,  // FNMSUB.S
    OPC_FNMADD    = 7'b1001111,  // FNMADD.S
    OPC_OP_FP     = 7'b1010011   // FADD.S, FSUB.S, FMUL.S, etc.
  } opc_e;

  // Instruction-memory predecode sideband bits, stored per 32-bit word.
  // The fetch interface returns two words, so its sideband bus is twice this
  // width: {next_word_sideband, current_word_sideband}.
  localparam int unsigned ImemSidebandWidth = 78;
  // {illegal, expanded[31:25], expanded[14:0]}; source fields are stored below.
  localparam int unsigned ImemSbRvcExtraLoLsb = 32;
  localparam int unsigned ImemSbRvcExtraHiLsb = 55;
  localparam int unsigned ImemFetchSidebandWidth = 2 * ImemSidebandWidth;
  localparam int unsigned ImemSbIsCompressedLo = 0;
  localparam int unsigned ImemSbIsCompressedHi = 1;
  // PC/bundle predecode.  The compressed-control and FP-class intermediates
  // are computed inside imem_make_sideband to derive the predicates below
  // but are not stored: no runtime consumer reads them.
  localparam int unsigned ImemSbEvenLocalPairValid = 2;
  localparam int unsigned ImemSbPairableNativeLo = 3;
  localparam int unsigned ImemSbNativeSerializeLo = 4;
  localparam int unsigned ImemSbNativeSerializeHi = 5;
  localparam int unsigned ImemSbPairableCompressedHi = 6;
  localparam int unsigned ImemSbPairableNativeHi = 7;
  localparam int unsigned ImemSbAllowsSlot2AfterLo = 8;
  localparam int unsigned ImemSbAllowsSlot2AfterHi = 9;
  localparam int unsigned ImemSbSlot2StartValidLo = 10;
  localparam int unsigned ImemSbSlot2StartValidHi = 11;
  // The two hot rs1 bits [2:1] for each halfword start. The packet's rs2[1]
  // hot bit comes from Bits24To20 below, avoiding duplicate storage.
  localparam int unsigned ImemSbRvcSourceHotLoLsb = 12;
  localparam int unsigned ImemSbRvcSourceHotHiLsb = 14;
  // The RVC expansion's complete instruction bits [24:20] for each halfword
  // start: rs2 for register formats, immediate bits otherwise. Both slots
  // use them for rs2 instead of decompressing the fetched parcel.
  localparam int unsigned ImemSbRvcBits24To20LoLsb = 16;
  localparam int unsigned ImemSbRvcBits24To20HiLsb = 21;
  // The other three rs1 bits; rs1[2:1] already live in SourceHot.
  localparam int unsigned ImemSbRvcRs1RestLoLsb = 26;
  localparam int unsigned ImemSbRvcRs1RestHiLsb = 29;

  // Predecode sideband generation: one sideband value per 32-bit
  // instruction-memory word, a pure function of that word (no lookahead:
  // each halfword's bits read only that halfword, and the "native" opcode
  // classes read only the halfword's low 7 bits). This is the one RTL
  // definition, used by imem_predecode (init images, programming-port
  // writes, and read-time re-decode) and by the L1I fill path
  // (imem_predecode_line). The offline generator
  // sw/common/generate_imem_predecode_init.py mirrors these functions for
  // the Vivado power-up init files; the imem_predecode_line cocotb bench
  // cross-checks RTL against it. Opcodes are compared as bit
  // literals, not opc_e members: Yosys cannot resolve enum values inside
  // package functions (see get_rs_type below).

  // Compressed control flow: C.J/C.BEQZ/C.BNEZ (quadrant 01; the RV32
  // C.JAL slot is C.ADDIW on RV64, not control flow) and C.JR/C.JALR
  // (quadrant 10 with rs2=0, rs1!=0).
  function automatic logic imem_compressed_control(input logic [15:0] parcel);
    logic [2:0] funct3;
    logic [3:0] funct4;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [1:0] op;
    begin
      funct3 = parcel[15:13];
      funct4 = parcel[15:12];
      rs1 = parcel[11:7];
      rs2 = parcel[6:2];
      op = parcel[1:0];
      imem_compressed_control =
          ((op == 2'b01) &&
           ((funct3 == 3'b101) ||
            (funct3 == 3'b110) || (funct3 == 3'b111))) ||
          ((op == 2'b10) &&
           (rs2 == 5'b00000) &&
           (rs1 != 5'b00000) &&
           ((funct4 == 4'b1000) || (funct4 == 4'b1001)));
    end
  endfunction

  // Native serializing class, which never pairs in a fetch bundle: SYSTEM
  // (OPC_CSR: CSR accesses, ECALL, EBREAK, xRET, WFI, SFENCE.VMA), MISC-MEM,
  // and AMO.
  function automatic logic imem_native_serialize(input logic [6:0] opcode);
    begin
      imem_native_serialize = (opcode == 7'b1110011) ||  // OPC_CSR
      (opcode == 7'b0001111) ||  // OPC_MISC_MEM
      (opcode == 7'b0101111);  // OPC_AMO
    end
  endfunction

  // Native control flow: BRANCH, JAL, JALR.  A control-flow slot-1
  // terminates its bundle (mirrors the compressed-control exclusion).
  function automatic logic imem_native_control(input logic [6:0] opcode);
    begin
      imem_native_control = (opcode == 7'b1100011) ||  // OPC_BRANCH
      (opcode == 7'b1101111) ||  // OPC_JAL
      (opcode == 7'b1100111);  // OPC_JALR
    end
  endfunction

  // Native instructions that use an FP compute unit: OP-FP + the four FMAs.
  function automatic logic imem_native_fp_compute(input logic [6:0] opcode);
    begin
      imem_native_fp_compute = (opcode == 7'b1010011) ||  // OPC_OP_FP
      (opcode == 7'b1000011) ||  // OPC_FMADD
      (opcode == 7'b1000111) ||  // OPC_FMSUB
      (opcode == 7'b1001011) ||  // OPC_FNMSUB
      (opcode == 7'b1001111);  // OPC_FNMADD
    end
  endfunction

  // Return {expanded instruction[21], expanded instruction[19:15]}, i.e.
  // {rs2[1], rs1}, for one RVC parcel. These bits match the literal expansion,
  // including unused fields, illegal encodings and hints. The two wrappers
  // below split rs1 into the stored SourceHot bits (rs1[2:1]) and Rs1Rest
  // bits ({rs1[4:3], rs1[0]}), from which PD builds its early rs1.
  function automatic logic [5:0] imem_rvc_source_fields(input logic [15:0] parcel,
                                                        input logic rd_is_x2);
    logic [ 4:0] rs1;
    logic [ 4:0] rs2;
    logic [ 4:0] rd_full;
    logic [ 4:0] rs2_full;
    logic [ 4:0] rs1_prime;
    logic [ 4:0] rs2_prime;
    logic [ 4:0] shamt;
    logic [11:0] imm_addi4spn;
    logic [11:0] imm_lw_sw;
    logic [11:0] imm_ld_sd;
    logic [11:0] imm_ci;
    logic [11:0] imm_addi16sp;
    logic [19:0] imm_lui;
    logic [11:0] imm_j;
    logic [11:0] imm_lwsp;
    logic [11:0] imm_ldsp;
    begin
      rd_full = parcel[11:7];
      rs2_full = parcel[6:2];
      rs1_prime = {2'b01, parcel[9:7]};
      rs2_prime = {2'b01, parcel[4:2]};
      shamt = parcel[6:2];
      imm_addi4spn = {2'b0, parcel[10:7], parcel[12:11], parcel[5], parcel[6], 2'b00};
      imm_lw_sw = {5'b0, parcel[5], parcel[12:10], parcel[6], 2'b00};
      imm_ld_sd = {4'b0, parcel[6:5], parcel[12:10], 3'b000};
      imm_ci = {{6{parcel[12]}}, parcel[12], parcel[6:2]};
      imm_addi16sp = {
        {2{parcel[12]}}, parcel[12], parcel[4:3], parcel[5], parcel[2], parcel[6], 4'b0000
      };
      imm_lui = {{14{parcel[12]}}, parcel[12], parcel[6:2]};
      imm_j = {
        parcel[12],
        parcel[8],
        parcel[10:9],
        parcel[6],
        parcel[7],
        parcel[2],
        parcel[11],
        parcel[5:3],
        1'b0
      };
      imm_lwsp = {4'b0, parcel[3:2], parcel[12], parcel[6:4], 2'b00};
      imm_ldsp = {3'b0, parcel[4:2], parcel[12], parcel[6:5], 3'b000};

      rs1 = 5'd0;
      rs2 = 5'd0;
      unique case (parcel[1:0])
        2'b00: begin
          unique case (parcel[15:13])
            3'b000: begin  // C.ADDI4SPN
              rs1 = 5'd2;
              rs2 = imm_addi4spn[4:0];
            end
            3'b010, 3'b011: begin  // C.LW / C.LD: C.LD can share C.LW's form
              // because only rs2[1] survives into the hot encoding and bit 1
              // of both the 4- and 8-scaled immediates is zero
              rs1 = rs1_prime;
              rs2 = imm_lw_sw[4:0];
            end
            3'b001: begin  // C.FLD
              rs1 = rs1_prime;
              rs2 = imm_ld_sd[4:0];
            end
            3'b101, 3'b110, 3'b111: begin  // C.FSD / C.SW / C.SD
              rs1 = rs1_prime;
              rs2 = rs2_prime;
            end
            default: begin  // Reserved encoding expands to zero.
              rs1 = 5'd0;
              rs2 = 5'd0;
            end
          endcase
        end
        2'b01: begin
          unique case (parcel[15:13])
            3'b000: begin  // C.ADDI / C.NOP
              rs1 = rd_full;
              rs2 = imm_ci[4:0];
            end
            3'b001: begin  // C.ADDIW (rd is also rs1)
              rs1 = rd_full;
              rs2 = imm_ci[4:0];
            end
            3'b101: begin  // C.J
              rs1 = {5{imm_j[11]}};
              rs2 = {imm_j[4:1], imm_j[11]};
            end
            3'b010: begin  // C.LI
              rs1 = 5'd0;
              rs2 = imm_ci[4:0];
            end
            3'b011: begin
              if (rd_is_x2) begin  // C.ADDI16SP
                rs1 = 5'd2;
                rs2 = imm_addi16sp[4:0];
              end else begin  // C.LUI
                rs1 = imm_lui[7:3];
                rs2 = imm_lui[12:8];
              end
            end
            3'b100: begin
              unique case (parcel[11:10])
                2'b00, 2'b01, 2'b10: begin  // C.SRLI / C.SRAI / C.ANDI
                  rs1 = rs1_prime;
                  rs2 = shamt;
                end
                default: begin  // C.SUB / C.XOR / C.OR / C.AND / C.SUBW / C.ADDW
                  if (!parcel[12] || !parcel[6]) begin
                    rs1 = rs1_prime;
                    rs2 = rs2_prime;
                  end
                  // With parcel[12]=1, [6:5]=00/01 are C.SUBW/C.ADDW with the
                  // same register shape while [6:5]=10/11 stay reserved (zero
                  // expansion).
                end
              endcase
            end
            3'b110, 3'b111: begin  // C.BEQZ / C.BNEZ
              rs1 = rs1_prime;
              rs2 = 5'd0;
            end
            default: begin
              rs1 = 5'd0;
              rs2 = 5'd0;
            end
          endcase
        end
        2'b10: begin
          unique case (parcel[15:13])
            3'b000: begin  // C.SLLI
              rs1 = rd_full;
              rs2 = shamt;
            end
            3'b010, 3'b011: begin  // C.LWSP / C.LDSP: C.LDSP can share
              // C.LWSP's form because bit 1 of both scaled immediates is zero
              rs1 = 5'd2;
              rs2 = imm_lwsp[4:0];
            end
            3'b001: begin  // C.FLDSP
              rs1 = 5'd2;
              rs2 = imm_ldsp[4:0];
            end
            3'b100: begin
              if (!parcel[12]) begin
                if (rs2_full == 5'd0) begin  // C.JR
                  rs1 = rd_full;
                  rs2 = 5'd0;
                end else begin  // C.MV
                  rs1 = 5'd0;
                  rs2 = rs2_full;
                end
              end else if (rs2_full == 5'd0) begin
                if (rd_full == 5'd0) begin  // C.EBREAK
                  rs1 = 5'd0;
                  rs2 = 5'd1;
                end else begin  // C.JALR
                  rs1 = rd_full;
                  rs2 = 5'd0;
                end
              end else begin  // C.ADD
                rs1 = rd_full;
                rs2 = rs2_full;
              end
            end
            3'b101, 3'b110, 3'b111: begin  // C.FSDSP / C.SWSP / C.SDSP
              rs1 = 5'd2;
              rs2 = rs2_full;
            end
            default: begin
              rs1 = 5'd0;
              rs2 = 5'd0;
            end
          endcase
        end
        default: begin
          // Quadrant 3 is native and never consumes the RVC metadata.
          rs1 = 5'd0;
          rs2 = 5'd0;
        end
      endcase
      imem_rvc_source_fields = {rs2[1], rs1};
    end
  endfunction

  function automatic logic [2:0] imem_rvc_source_hot(input logic [15:0] parcel,
                                                     input logic rd_is_x2);
    logic [5:0] fields;
    fields = imem_rvc_source_fields(parcel, rd_is_x2);
    imem_rvc_source_hot = {fields[5], fields[2:1]};
  endfunction

  function automatic logic [2:0] imem_rvc_rs1_rest(input logic [15:0] parcel, input logic rd_is_x2);
    logic [5:0] fields;
    fields = imem_rvc_source_fields(parcel, rd_is_x2);
    imem_rvc_rs1_rest = {fields[4:3], fields[0]};
  endfunction

  // Bits [24:20] of the RVC expansion of one parcel, equal to those of
  // rvc_decompressor's expansion, including reserved encodings; a quadrant-3
  // (native) parcel returns zero.
  function automatic logic [4:0] imem_rvc_bits24_20(input logic [15:0] c, input logic rd_is_x2);
    logic arithmetic_reserved;
    logic ebreak;
    begin
      arithmetic_reserved = c[12] && (&c[11:10]) && c[6];
      ebreak = c[12] && (c[11:7] == 5'd0) && (c[6:2] == 5'd0);
      imem_rvc_bits24_20 = 5'd0;
      unique case (c[1:0])
        2'b00: begin
          unique case (c[15:13])
            3'b000: imem_rvc_bits24_20 = {c[11], c[5], c[6], 2'b00};
            3'b001, 3'b011: imem_rvc_bits24_20 = {c[11:10], 3'b000};
            3'b010: imem_rvc_bits24_20 = {c[11:10], c[6], 2'b00};
            3'b101, 3'b110, 3'b111: imem_rvc_bits24_20 = {2'b01, c[4:2]};
            default: imem_rvc_bits24_20 = 5'd0;
          endcase
        end
        2'b01: begin
          unique case (c[15:13])
            3'b000, 3'b001, 3'b010: imem_rvc_bits24_20 = c[6:2];
            3'b011: imem_rvc_bits24_20 = rd_is_x2 ? {c[6], 4'b0000} : {5{c[12]}};
            3'b100:
            imem_rvc_bits24_20 = arithmetic_reserved ? 5'd0 :
                ((&c[11:10]) ? {2'b01, c[4:2]} : c[6:2]);
            3'b101: imem_rvc_bits24_20 = {c[11], c[5:3], c[12]};
            default: imem_rvc_bits24_20 = 5'd0;
          endcase
        end
        2'b10: begin
          unique case (c[15:13])
            3'b001, 3'b011: imem_rvc_bits24_20 = {c[6:5], 3'b000};
            3'b010: imem_rvc_bits24_20 = {c[6:4], 2'b00};
            3'b100: imem_rvc_bits24_20 = {c[6:3], c[2] || ebreak};
            default: imem_rvc_bits24_20 = c[6:2];
          endcase
        end
        default: imem_rvc_bits24_20 = 5'd0;
      endcase
    end
  endfunction

  // Full RV64C expansion of one parcel, {illegal, instruction[31:0]},
  // computed with the rest of the predecode sideband. The rvc_predecode
  // formal target checks it against rvc_decompressor for every parcel.
  function automatic logic [32:0] imem_rvc_expand(input logic [15:0] i_instr_compressed);
    logic i_rd_is_x2;
    logic [31:0] o_instr_expanded;
    logic o_illegal;
    logic [1:0] quadrant;
    logic [2:0] funct3;
    localparam logic [6:0] OpcLui = 7'b0110111;
    localparam logic [6:0] OpcJal = 7'b1101111;
    localparam logic [6:0] OpcJalr = 7'b1100111;
    localparam logic [6:0] OpcBranch = 7'b1100011;
    localparam logic [6:0] OpcLoad = 7'b0000011;
    localparam logic [6:0] OpcLoadFp = 7'b0000111;
    localparam logic [6:0] OpcStore = 7'b0100011;
    localparam logic [6:0] OpcStoreFp = 7'b0100111;
    localparam logic [6:0] OpcOpImm = 7'b0010011;
    localparam logic [6:0] OpcOp = 7'b0110011;
    localparam logic [6:0] OpcOpImm32 = 7'b0011011;
    localparam logic [6:0] OpcOp32 = 7'b0111011;
    logic [4:0] rd_full, rs1_full, rs2_full;
    logic [4:0] rd_prime, rs1_prime, rs2_prime;
    logic [11:0] imm_addi4spn;
    logic [11:0] imm_lw_sw;
    logic [11:0] imm_ld_sd;
    logic [11:0] imm_ci;
    logic [11:0] imm_addi16sp;
    logic [19:0] imm_lui;
    logic [11:0] imm_j;
    logic [ 8:0] imm_b;
    logic [11:0] imm_lwsp;
    logic [11:0] imm_ldsp;
    logic [ 7:0] imm_swsp;
    logic [11:0] imm_sdsp;
    logic [ 5:0] shamt6;
    begin
      i_rd_is_x2 = (i_instr_compressed[11:7] == 5'd2);
      quadrant = i_instr_compressed[1:0];
      funct3 = i_instr_compressed[15:13];
      rd_full = i_instr_compressed[11:7];
      rs1_full = i_instr_compressed[11:7];
      rs2_full = i_instr_compressed[6:2];
      rd_prime = {2'b01, i_instr_compressed[4:2]};
      rs1_prime = {2'b01, i_instr_compressed[9:7]};
      rs2_prime = {2'b01, i_instr_compressed[4:2]};
      imm_addi4spn = {
        2'b0,
        i_instr_compressed[10:7],
        i_instr_compressed[12:11],
        i_instr_compressed[5],
        i_instr_compressed[6],
        2'b00
      };
      imm_lw_sw = {
        5'b0, i_instr_compressed[5], i_instr_compressed[12:10], i_instr_compressed[6], 2'b00
      };
      imm_ld_sd = {4'b0, i_instr_compressed[6:5], i_instr_compressed[12:10], 3'b000};
      imm_ci = {{6{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};
      imm_addi16sp = {
        {2{i_instr_compressed[12]}},
        i_instr_compressed[12],
        i_instr_compressed[4:3],
        i_instr_compressed[5],
        i_instr_compressed[2],
        i_instr_compressed[6],
        4'b0000
      };
      imm_lui = {{14{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};
      imm_j = {
        i_instr_compressed[12],
        i_instr_compressed[8],
        i_instr_compressed[10:9],
        i_instr_compressed[6],
        i_instr_compressed[7],
        i_instr_compressed[2],
        i_instr_compressed[11],
        i_instr_compressed[5:3],
        1'b0
      };
      imm_b = {
        i_instr_compressed[12],
        i_instr_compressed[6:5],
        i_instr_compressed[2],
        i_instr_compressed[11:10],
        i_instr_compressed[4:3],
        1'b0
      };
      imm_lwsp = {
        4'b0, i_instr_compressed[3:2], i_instr_compressed[12], i_instr_compressed[6:4], 2'b00
      };
      imm_ldsp = {
        3'b0, i_instr_compressed[4:2], i_instr_compressed[12], i_instr_compressed[6:5], 3'b000
      };
      imm_swsp = {i_instr_compressed[8:7], i_instr_compressed[12:9], 2'b00};
      imm_sdsp = {3'b0, i_instr_compressed[9:7], i_instr_compressed[12:10], 3'b000};
      shamt6 = {i_instr_compressed[12], i_instr_compressed[6:2]};
      // Default outputs: zero instruction for reserved encodings.
      o_instr_expanded = 32'b0;
      o_illegal = 1'b0;

      unique case (quadrant)
        // -----------------------------------------------------------------------
        // Quadrant 0 (00)
        // -----------------------------------------------------------------------
        2'b00: begin
          unique case (funct3)
            3'b000: begin  // C.ADDI4SPN
              o_instr_expanded = {imm_addi4spn, 5'd2, 3'b000, rd_prime, OpcOpImm};
              if (imm_addi4spn == 12'b0) o_illegal = 1'b1;
            end
            3'b010: o_instr_expanded = {imm_lw_sw, rs1_prime, 3'b010, rd_prime, OpcLoad};  // C.LW
            3'b001:
            o_instr_expanded = {imm_ld_sd, rs1_prime, 3'b011, rd_prime, OpcLoadFp};  // C.FLD
            3'b011: o_instr_expanded = {imm_ld_sd, rs1_prime, 3'b011, rd_prime, OpcLoad};  // C.LD
            3'b110:
            o_instr_expanded = {
              imm_lw_sw[11:5], rs2_prime, rs1_prime, 3'b010, imm_lw_sw[4:0], OpcStore
            };  // C.SW
            3'b101:
            o_instr_expanded = {
              imm_ld_sd[11:5], rs2_prime, rs1_prime, 3'b011, imm_ld_sd[4:0], OpcStoreFp
            };  // C.FSD
            3'b111:
            o_instr_expanded = {
              imm_ld_sd[11:5], rs2_prime, rs1_prime, 3'b011, imm_ld_sd[4:0], OpcStore
            };  // C.SD
            default: o_illegal = 1'b1;  // Reserved encoding
          endcase
        end

        // -----------------------------------------------------------------------
        // Quadrant 1 (01)
        // -----------------------------------------------------------------------
        2'b01: begin
          unique case (funct3)
            3'b000: o_instr_expanded = {imm_ci, rd_full, 3'b000, rd_full, OpcOpImm};  // C.ADDI/NOP
            3'b001: begin  // C.ADDIW (rd=0 reserved)
              o_instr_expanded = {imm_ci, rd_full, 3'b000, rd_full, OpcOpImm32};
              if (rd_full == 5'd0) o_illegal = 1'b1;
            end
            3'b010: o_instr_expanded = {imm_ci, 5'd0, 3'b000, rd_full, OpcOpImm};  // C.LI
            3'b011: begin
              if (i_rd_is_x2) begin  // C.ADDI16SP
                o_instr_expanded = {imm_addi16sp, 5'd2, 3'b000, 5'd2, OpcOpImm};
                if (imm_addi16sp == 12'b0) o_illegal = 1'b1;
              end else begin  // C.LUI (rd=0 is a HINT: lui x0)
                o_instr_expanded = {imm_lui, rd_full, OpcLui};
                if ({i_instr_compressed[12], i_instr_compressed[6:2]} == 6'b0) o_illegal = 1'b1;
              end
            end
            3'b100: begin
              unique case (i_instr_compressed[11:10])
                2'b00:  // C.SRLI (bit12 = shamt[5])
                o_instr_expanded = {6'b000000, shamt6, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
                2'b01:  // C.SRAI (bit12 = shamt[5])
                o_instr_expanded = {6'b010000, shamt6, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
                2'b10: begin  // C.ANDI
                  o_instr_expanded = {imm_ci, rs1_prime, 3'b111, rs1_prime, OpcOpImm};
                end
                2'b11: begin  // C.SUB/C.XOR/C.OR/C.AND; bit12=1: RV64 C.SUBW/C.ADDW
                  if (i_instr_compressed[12]) begin
                    unique case (i_instr_compressed[6:5])
                      2'b00:
                      o_instr_expanded = {
                        7'b0100000, rs2_prime, rs1_prime, 3'b000, rs1_prime, OpcOp32
                      };  // C.SUBW
                      2'b01:
                      o_instr_expanded = {
                        7'b0000000, rs2_prime, rs1_prime, 3'b000, rs1_prime, OpcOp32
                      };  // C.ADDW
                      default: o_illegal = 1'b1;  // [6:5]=10/11 stay reserved
                    endcase
                  end else begin
                    unique case (i_instr_compressed[6:5])
                      2'b00:
                      o_instr_expanded = {
                        7'b0100000, rs2_prime, rs1_prime, 3'b000, rs1_prime, OpcOp
                      };  // C.SUB
                      2'b01:
                      o_instr_expanded = {
                        7'b0000000, rs2_prime, rs1_prime, 3'b100, rs1_prime, OpcOp
                      };  // C.XOR
                      2'b10:
                      o_instr_expanded = {
                        7'b0000000, rs2_prime, rs1_prime, 3'b110, rs1_prime, OpcOp
                      };  // C.OR
                      2'b11:
                      o_instr_expanded = {
                        7'b0000000, rs2_prime, rs1_prime, 3'b111, rs1_prime, OpcOp
                      };  // C.AND
                    endcase
                  end
                end
              endcase
            end
            3'b101:
            o_instr_expanded = {imm_j[11], imm_j[10:1], imm_j[11], {8{imm_j[11]}}, 5'd0, OpcJal};
            3'b110: begin
              o_instr_expanded = {
                imm_b[8],
                {3{imm_b[8]}},
                imm_b[7:5],
                5'd0,
                rs1_prime,
                3'b000,
                imm_b[4:1],
                imm_b[8],
                OpcBranch
              };  // C.BEQZ
            end
            3'b111: begin
              o_instr_expanded = {
                imm_b[8],
                {3{imm_b[8]}},
                imm_b[7:5],
                5'd0,
                rs1_prime,
                3'b001,
                imm_b[4:1],
                imm_b[8],
                OpcBranch
              };  // C.BNEZ
            end
            default: o_illegal = 1'b1;  // Reserved encoding
          endcase
        end

        // -----------------------------------------------------------------------
        // Quadrant 2 (10)
        // -----------------------------------------------------------------------
        2'b10: begin
          unique case (funct3)
            3'b000:  // C.SLLI (rd=0 is a HINT -> nop; bit12 = shamt[5])
            o_instr_expanded = {6'b000000, shamt6, rd_full, 3'b001, rd_full, OpcOpImm};
            3'b010: begin  // C.LWSP
              o_instr_expanded = {imm_lwsp, 5'd2, 3'b010, rd_full, OpcLoad};
              if (rd_full == 5'd0) o_illegal = 1'b1;
            end
            3'b001: begin  // C.FLDSP
              o_instr_expanded = {imm_ldsp, 5'd2, 3'b011, rd_full, OpcLoadFp};
            end
            3'b011: begin  // C.LDSP (integer, rd=0 reserved)
              o_instr_expanded = {imm_ldsp, 5'd2, 3'b011, rd_full, OpcLoad};
              if (rd_full == 5'd0) o_illegal = 1'b1;
            end
            3'b100: begin
              if (!i_instr_compressed[12]) begin
                if (rs2_full == 5'd0) begin  // C.JR
                  o_instr_expanded = {12'b0, rs1_full, 3'b000, 5'd0, OpcJalr};
                  if (rd_full == 5'd0) o_illegal = 1'b1;
                end else begin  // C.MV (rd=0 is a HINT -> nop, not illegal)
                  o_instr_expanded = {7'b0, rs2_full, 5'd0, 3'b000, rd_full, OpcOp};
                end
              end else begin
                if (rs2_full == 5'd0) begin
                  if (rd_full == 5'd0) begin
                    o_instr_expanded = 32'h0010_0073;  // C.EBREAK
                  end else begin
                    o_instr_expanded = {12'b0, rs1_full, 3'b000, 5'd1, OpcJalr};  // C.JALR
                  end
                end else begin
                  // C.ADD (rd=0 is a HINT -> nop, not illegal)
                  o_instr_expanded = {7'b0, rs2_full, rd_full, 3'b000, rd_full, OpcOp};
                end
              end
            end
            3'b110:
            o_instr_expanded = {
              4'b0, imm_swsp[7:5], rs2_full, 5'd2, 3'b010, imm_swsp[4:0], OpcStore
            };  // C.SWSP
            3'b101:
            o_instr_expanded = {
              imm_sdsp[11:5], rs2_full, 5'd2, 3'b011, imm_sdsp[4:0], OpcStoreFp
            };  // C.FSDSP
            3'b111:  // C.SDSP (integer, 8-scaled)
            o_instr_expanded = {imm_sdsp[11:5], rs2_full, 5'd2, 3'b011, imm_sdsp[4:0], OpcStore};
            default: o_illegal = 1'b1;  // Reserved encoding
          endcase
        end

        // -----------------------------------------------------------------------
        // Quadrant 3 (11): not compressed, passthrough
        // -----------------------------------------------------------------------
        default: o_instr_expanded = {16'b0, i_instr_compressed};
      endcase
      imem_rvc_expand = {o_illegal, o_instr_expanded};
    end
  endfunction

  function automatic logic [ImemSidebandWidth-1:0] imem_make_sideband(input logic [31:0] word);
    logic [ImemSidebandWidth-1:0] sb;
    logic [32:0] expanded_lo, expanded_hi;
    logic compressed_control_lo;
    logic compressed_control_hi;
    logic native_fp_compute_lo;
    logic native_fp_compute_hi;
    logic allows_slot2_after_lo;
    logic allows_slot2_after_hi;
    logic slot2_start_valid_lo;
    logic slot2_start_valid_hi;
    begin
      sb = '0;
      sb[ImemSbIsCompressedLo] = (word[1:0] != 2'b11);
      sb[ImemSbIsCompressedHi] = (word[17:16] != 2'b11);
      compressed_control_lo = imem_compressed_control(word[15:0]);
      compressed_control_hi = imem_compressed_control(word[31:16]);
      sb[ImemSbNativeSerializeLo] = imem_native_serialize(word[6:0]);
      sb[ImemSbNativeSerializeHi] = imem_native_serialize(word[22:16]);
      native_fp_compute_lo = imem_native_fp_compute(word[6:0]);
      native_fp_compute_hi = imem_native_fp_compute(word[22:16]);
      // A slot-1 allows a slot-2 after it when it is not control flow (the
      // bundle would straddle a redirect) and not in the serializing class.
      // A CSR instruction reads the CSR at commit and broadcasts only its
      // write operand on the CDB, so dispatch holds younger instructions
      // until the read value is written back; a slot-2 partner would slip
      // past that hold. Native 32-bit slot-1s pair through the aligner's
      // NEXT_LO / NEXT_HI slot-2 shapes. FP-compute slot-1s pair normally
      // (their results broadcast on the CDB like any FU's).
      allows_slot2_after_lo =
          (sb[ImemSbIsCompressedLo] && !compressed_control_lo) ||
          (!sb[ImemSbIsCompressedLo] && !imem_native_control(word[6:0]) &&
          !sb[ImemSbNativeSerializeLo]);
      allows_slot2_after_hi =
          (sb[ImemSbIsCompressedHi] && !compressed_control_hi) ||
          (!sb[ImemSbIsCompressedHi] && !imem_native_control(word[22:16]) &&
          !sb[ImemSbNativeSerializeHi]);
      slot2_start_valid_lo =
          sb[ImemSbIsCompressedLo] ||
          !(sb[ImemSbNativeSerializeLo] || native_fp_compute_lo);
      slot2_start_valid_hi =
          sb[ImemSbIsCompressedHi] ||
          !(sb[ImemSbNativeSerializeHi] || native_fp_compute_hi);

      sb[ImemSbAllowsSlot2AfterLo] = allows_slot2_after_lo;
      sb[ImemSbAllowsSlot2AfterHi] = allows_slot2_after_hi;
      sb[ImemSbSlot2StartValidLo] = slot2_start_valid_lo;
      sb[ImemSbSlot2StartValidHi] = slot2_start_valid_hi;

      // Word-local PC predicates.  RVC-at-low is the only shape whose
      // prospective slot-2 start is in this same word, so its complete class
      // eligibility can be computed here.  The remaining bits precompute the
      // slot-1 size/allows conjunction for the three cross-word shapes; the
      // next word's start-valid/size still has to be joined in the aligner.
      sb[ImemSbEvenLocalPairValid] =
          sb[ImemSbIsCompressedLo] && allows_slot2_after_lo && slot2_start_valid_hi;
      sb[ImemSbPairableNativeLo] = !sb[ImemSbIsCompressedLo] && allows_slot2_after_lo;
      sb[ImemSbPairableCompressedHi] = sb[ImemSbIsCompressedHi] && allows_slot2_after_hi;
      sb[ImemSbPairableNativeHi] = !sb[ImemSbIsCompressedHi] && allows_slot2_after_hi;
      sb[ImemSbRvcSourceHotLoLsb+:2] = 2'(imem_rvc_source_hot(word[15:0], word[11:7] == 5'd2));
      sb[ImemSbRvcSourceHotHiLsb+:2] = 2'(imem_rvc_source_hot(word[31:16], word[27:23] == 5'd2));
      sb[ImemSbRvcBits24To20LoLsb+:5] = imem_rvc_bits24_20(word[15:0], word[11:7] == 5'd2);
      sb[ImemSbRvcBits24To20HiLsb+:5] = imem_rvc_bits24_20(word[31:16], word[27:23] == 5'd2);
      sb[ImemSbRvcRs1RestLoLsb+:3] = imem_rvc_rs1_rest(word[15:0], word[11:7] == 5'd2);
      sb[ImemSbRvcRs1RestHiLsb+:3] = imem_rvc_rs1_rest(word[31:16], word[27:23] == 5'd2);
      expanded_lo = imem_rvc_expand(word[15:0]);
      expanded_hi = imem_rvc_expand(word[31:16]);
      sb[ImemSbRvcExtraLoLsb+:23] = {expanded_lo[32:25], expanded_lo[14:0]};
      sb[ImemSbRvcExtraHiLsb+:23] = {expanded_hi[32:25], expanded_hi[14:0]};
      imem_make_sideband = sb;
    end
  endfunction

  // ===========================================================================
  // Section 2: Instruction Operations
  // ===========================================================================
  // Every instruction operation, grouped by extension. The decoder passes one
  // of these to the ALU and the other execution units.

  // The ordinals are fixed: new members append at the end, and ordinals 86
  // and 87 stay unused. The guided X3 placement flow
  // (fpga/build/build_step.tcl's PC-tail cost groups) reproduces a
  // timing-closed placement whose decode/compare cones assume exactly these
  // ordinals, so compacting the holes or reordering members invalidates it.
  // The ALU also derives shared shift/rotate controls directly from the op
  // bits (projected_shift_controls), so an enum edit must preserve or
  // revalidate alu.sv's encoding assertions; this dependency affects
  // function, not only placement. The base type is an 8-bit unsigned
  // two-state vector: an unsized enum would carry a 32-bit int through the
  // decode, dispatch, reservation-station, and execution payloads, and the
  // unsigned base keeps ordinals 128 and above nonnegative.
  localparam int unsigned InstrOpWidth = 8;
  typedef enum bit [InstrOpWidth-1:0] {
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
    // 8'd86 and 8'd87 are unused. Do not compact: see the ordinal note above.
    // Zihintpause extension
    PAUSE            = 8'd88,
    // Privileged instructions (trap handling)
    MRET,                      // Return from machine-mode trap
    WFI,                       // Wait for interrupt
    ECALL,                     // Environment call (system call)
    EBREAK,                    // Breakpoint exception
    // A extension (atomics)
    LR_W,                      // Load-reserved word
    SC_W,                      // Store-conditional word
    AMOSWAP_W,                 // Atomic swap
    AMOADD_W,                  // Atomic add
    AMOXOR_W,                  // Atomic XOR
    AMOAND_W,                  // Atomic AND
    AMOOR_W,                   // Atomic OR
    AMOMIN_W,                  // Atomic minimum (signed)
    AMOMAX_W,                  // Atomic maximum (signed)
    AMOMINU_W,                 // Atomic minimum (unsigned)
    AMOMAXU_W,                 // Atomic maximum (unsigned)
    // RV64A doubleword forms.
    LR_D,                      // Load-reserved doubleword
    SC_D,                      // Store-conditional doubleword
    AMOSWAP_D,                 // Atomic swap doubleword
    AMOADD_D,                  // Atomic add doubleword
    AMOXOR_D,                  // Atomic XOR doubleword
    AMOAND_D,                  // Atomic AND doubleword
    AMOOR_D,                   // Atomic OR doubleword
    AMOMIN_D,                  // Atomic minimum doubleword (signed)
    AMOMAX_D,                  // Atomic maximum doubleword (signed)
    AMOMINU_D,                 // Atomic minimum doubleword (unsigned)
    AMOMAXU_D,                 // Atomic maximum doubleword (unsigned)
    // F extension (single-precision floating-point)
    FLW,                       // Load float
    FSW,                       // Store float
    FADD_S,                    // FP add
    FSUB_S,                    // FP subtract
    FMUL_S,                    // FP multiply
    FDIV_S,                    // FP divide
    FSQRT_S,                   // FP square root
    FMADD_S,                   // FP fused multiply-add
    FMSUB_S,                   // FP fused multiply-subtract
    FNMADD_S,                  // FP negated fused multiply-add
    FNMSUB_S,                  // FP negated fused multiply-subtract
    FSGNJ_S,                   // FP sign inject
    FSGNJN_S,                  // FP sign inject negated
    FSGNJX_S,                  // FP sign inject XOR
    FMIN_S,                    // FP minimum
    FMAX_S,                    // FP maximum
    FCVT_W_S,                  // FP to signed int
    FCVT_WU_S,                 // FP to unsigned int
    FCVT_S_W,                  // Signed int to FP
    FCVT_S_WU,                 // Unsigned int to FP
    FMV_X_W,                   // Move FP bits to int reg
    FMV_W_X,                   // Move int bits to FP reg
    FEQ_S,                     // FP equal
    FLT_S,                     // FP less than
    FLE_S,                     // FP less than or equal
    FCLASS_S,                  // FP classify
    // D extension (double-precision floating-point)
    FLD,                       // Load double
    FSD,                       // Store double
    FADD_D,                    // FP add (double)
    FSUB_D,                    // FP subtract (double)
    FMUL_D,                    // FP multiply (double)
    FDIV_D,                    // FP divide (double)
    FSQRT_D,                   // FP square root (double)
    FMADD_D,                   // FP fused multiply-add (double)
    FMSUB_D,                   // FP fused multiply-subtract (double)
    FNMADD_D,                  // FP negated fused multiply-add (double)
    FNMSUB_D,                  // FP negated fused multiply-subtract (double)
    FSGNJ_D,                   // FP sign inject (double)
    FSGNJN_D,                  // FP sign inject negated (double)
    FSGNJX_D,                  // FP sign inject XOR (double)
    FMIN_D,                    // FP minimum (double)
    FMAX_D,                    // FP maximum (double)
    FCVT_W_D,                  // FP to signed int (double)
    FCVT_WU_D,                 // FP to unsigned int (double)
    FCVT_D_W,                  // Signed int to FP (double)
    FCVT_D_WU,                 // Unsigned int to FP (double)
    FCVT_S_D,                  // Convert double to single
    FCVT_D_S,                  // Convert single to double
    FEQ_D,                     // FP equal (double)
    FLT_D,                     // FP less than (double)
    FLE_D,                     // FP less than or equal (double)
    FCLASS_D,                  // FP classify (double)
    // RV64I base.
    LWU,                       // Load word unsigned (zero-extended)
    LD,                        // Load doubleword
    SD,                        // Store doubleword
    ADDIW,                     // Add immediate word (sext32 result)
    SLLIW,                     // Shift left logical immediate word
    SRLIW,                     // Shift right logical immediate word
    SRAIW,                     // Shift right arithmetic immediate word
    ADDW,                      // Add word
    SUBW,                      // Subtract word
    SLLW,                      // Shift left logical word
    SRLW,                      // Shift right logical word
    SRAW,                      // Shift right arithmetic word
    // RV64 B-extension W/UW forms.
    ADD_UW,                    // Zba: add unsigned word (zext32(rs1) + rs2)
    SH1ADD_UW,                 // Zba: shift-add unsigned word
    SH2ADD_UW,                 // Zba: shift-add unsigned word
    SH3ADD_UW,                 // Zba: shift-add unsigned word
    SLLI_UW,                   // Zba: shift-left immediate unsigned word (6-bit shamt)
    ROLW,                      // Zbb: rotate left word (sext32 result)
    RORW,                      // Zbb: rotate right word (sext32 result)
    RORIW,                     // Zbb: rotate right immediate word (5-bit shamt)
    CLZW,                      // Zbb: count leading zeros in word
    CTZW,                      // Zbb: count trailing zeros in word
    CPOPW,                     // Zbb: population count of word
    PACKW,                     // Zbkb: pack halfwords into sext32 word (ZEXT.H alias at 64)
    // RV64 M-extension word forms.
    MULW,                      // Multiply word (sext32 of low-32 product)
    DIVW,                      // Divide word signed (sext32 result)
    DIVUW,                     // Divide word unsigned (sext32 result)
    REMW,                      // Remainder word signed (sext32 result)
    REMUW,                     // Remainder word unsigned (sext32 result)
    // RV64 F/D conversions and moves.
    FCVT_L_S,                  // FP to signed 64-bit int (single)
    FCVT_LU_S,                 // FP to unsigned 64-bit int (single)
    FCVT_S_L,                  // Signed 64-bit int to FP (single)
    FCVT_S_LU,                 // Unsigned 64-bit int to FP (single)
    FCVT_L_D,                  // FP to signed 64-bit int (double)
    FCVT_LU_D,                 // FP to unsigned 64-bit int (double)
    FCVT_D_L,                  // Signed 64-bit int to FP (double)
    FCVT_D_LU,                 // Unsigned 64-bit int to FP (double)
    FMV_X_D,                   // Move double bits to int reg
    FMV_D_X,                   // Move int bits to double reg
    ILLEGAL,                   // Illegal instruction trap marker
    // Supervisor, fetch-fault, and Debug ops, appended after ILLEGAL (8'd206)
    // to keep the fixed ordinals.
    SRET,                      // Return from supervisor-mode trap
    SFENCE_VMA,                // Supervisor fence.vma (operands ignored: flush-all)
    FETCH_FAULT,               // Fetch access-fault pseudo-op: injected
                               // by decode for a fault-tagged fetch bundle; raises the
                               // precise instruction access fault (cause 1) through
                               // the ILLEGAL/ECALL completion path
    FETCH_PAGE_FAULT,          // Fetch page-fault pseudo-op: the
                               // translated-fetch twin of FETCH_FAULT (cause 12)
    DRET                       // Return from Debug Mode: rides the
                               // MRET serial path; illegal outside Debug Mode
  } instr_op_e;

  // Shared ALU barrel-shifter controls, decoded directly from the op bits:
  // {full_left, full_rotate, full_arithmetic, word_left, word_rotate,
  //  word_arithmetic, immediate_amount}. Each bit is exact only for the
  // shift/rotate ops that consume it; alu.sv holds the assertions that pin
  // this to the symbolic enum. The INT station's issue-2 shift-amount
  // capture uses the same immediate_amount bit as the ALU, not the use_imm
  // field.
  function automatic logic [6:0] projected_shift_controls(input instr_op_e op_bits);
    projected_shift_controls[6] = !op_bits[1] && (op_bits[0] ^ (op_bits[4] || op_bits[6]));
    projected_shift_controls[5] = op_bits[6];
    projected_shift_controls[4] = op_bits[1] && (op_bits[0] || op_bits[4]);
    projected_shift_controls[3] = !op_bits[2] && (op_bits[0] ~^ op_bits[1]);
    projected_shift_controls[2] = op_bits[3] && op_bits[4];
    projected_shift_controls[1] = (!op_bits[3] && op_bits[1]) || (op_bits[2] && op_bits[0]);
    projected_shift_controls[0] = (op_bits[3] && op_bits[1]) ||
        (op_bits[7] ? (op_bits[3] && op_bits[2]) : !op_bits[2]);
  endfunction

  // ===========================================================================
  // Section 3: CSR Definitions
  // ===========================================================================
  // Control and Status Register addresses, bit positions, and cause codes.
  // Includes Zicsr instruction encodings and M/S/U-mode trap support.

  // CSR instruction funct3 encoding
  typedef enum bit [2:0] {
    CSR_RW  = 3'b001,  // CSRRW  - read/write
    CSR_RS  = 3'b010,  // CSRRS  - read/set bits
    CSR_RC  = 3'b011,  // CSRRC  - read/clear bits
    CSR_RWI = 3'b101,  // CSRRWI - read/write immediate
    CSR_RSI = 3'b110,  // CSRRSI - read/set bits immediate
    CSR_RCI = 3'b111   // CSRRCI - read/clear bits immediate
  } csr_op_e;

  // Zicntr CSR addresses (read-only user-mode counters, single 64-bit CSRs).
  // The RV32 high halves (*H) are not counters at XLEN=64: the ROB raises
  // illegal-instruction for them at allocation, and no RTL references them.
  localparam bit [11:0] CsrCycle = 12'hC00;  // Cycle counter
  localparam bit [11:0] CsrTime = 12'hC01;  // Timer (mtime)
  localparam bit [11:0] CsrInstret = 12'hC02;  // Instructions retired
  localparam bit [11:0] CsrCycleH = 12'hC80;  // cycleh (RV32 only)
  localparam bit [11:0] CsrTimeH = 12'hC81;  // timeh (RV32 only)
  localparam bit [11:0] CsrInstretH = 12'hC82;  // instreth (RV32 only)

  // Machine-mode counter CSRs (aliases for the same physical counters)
  localparam bit [11:0] CsrMcycle = 12'hB00;  // mcycle
  localparam bit [11:0] CsrMcycleH = 12'hB80;  // mcycleh (RV32 only)
  localparam bit [11:0] CsrMinstret = 12'hB02;  // minstret
  localparam bit [11:0] CsrMinstretH = 12'hB82;  // minstreth (RV32 only)

  // Machine-mode CSR addresses (for trap/interrupt handling)
  localparam bit [11:0] CsrMstatus = 12'h300;  // Machine status register
  localparam bit [11:0] CsrMisa = 12'h301;  // Machine ISA register (read-only)
  localparam bit [11:0] CsrMedeleg = 12'h302;  // Machine exception delegation
  localparam bit [11:0] CsrMideleg = 12'h303;  // Machine interrupt delegation
  localparam bit [11:0] CsrMie = 12'h304;  // Machine interrupt enable
  localparam bit [11:0] CsrMtvec = 12'h305;  // Machine trap vector base
  localparam bit [11:0] CsrMcounteren = 12'h306;  // S/U counter enable (CY/TM/IR)
  // mcountinhibit: CY (bit 0) and IR (bit 2) stop cycle/instret;
  // TM (bit 1) is read-only 0 and the HPM bits are WARL-0. OpenSBI's
  // privileged-version probe needs this CSR to exist (v1.11) before it
  // programs menvcfg (v1.12), which is what turns Sstc on for S-mode.
  localparam bit [11:0] CsrMcountinhibit = 12'h320;
  localparam bit [11:0] CsrMenvcfg = 12'h30A;  // Machine environment configuration
  // menvcfg.STCE (bit 63, Sstc): S-mode stimecmp enable. WARL {0,1}; the
  // only implemented menvcfg field.
  localparam int unsigned MenvcfgStceBit = 63;
  localparam bit [11:0] CsrMscratch = 12'h340;  // Machine scratch register
  localparam bit [11:0] CsrMepc = 12'h341;  // Machine exception PC
  localparam bit [11:0] CsrMcause = 12'h342;  // Machine trap cause
  localparam bit [11:0] CsrMtval = 12'h343;  // Machine trap value
  localparam bit [11:0] CsrMip = 12'h344;  // Machine interrupt pending

  // Supervisor-mode CSR addresses. sstatus/sie/sip are
  // restricted views of the mstatus/mie/mip storage (mideleg gates the
  // sie/sip visibility); the rest are dedicated registers.
  localparam bit [11:0] CsrSstatus = 12'h100;  // Supervisor status (mstatus view)
  localparam bit [11:0] CsrSie = 12'h104;  // Supervisor interrupt enable (mie view)
  localparam bit [11:0] CsrStvec = 12'h105;  // Supervisor trap vector base
  localparam bit [11:0] CsrScounteren = 12'h106;  // U-mode counter enable below S
  localparam bit [11:0] CsrSenvcfg = 12'h10A;  // Supervisor environment configuration
  localparam bit [11:0] CsrSscratch = 12'h140;  // Supervisor scratch register
  localparam bit [11:0] CsrSepc = 12'h141;  // Supervisor exception PC
  localparam bit [11:0] CsrScause = 12'h142;  // Supervisor trap cause
  localparam bit [11:0] CsrStval = 12'h143;  // Supervisor trap value
  localparam bit [11:0] CsrSip = 12'h144;  // Supervisor interrupt pending (mip view)
  localparam bit [11:0] CsrStimecmp = 12'h14D;  // Supervisor timer compare (Sstc)
  localparam bit [11:0] CsrSatp = 12'h180;  // Supervisor address translation and protection
  // Machine information CSRs (read-only)
  localparam bit [11:0] CsrMhartid = 12'hF14;  // Hardware thread ID (always 0 for single-core)
  // Debug-mode CSRs (RISC-V Debug Spec 0.13.2). Accessible only
  // in Debug Mode (the ROB captures illegal-instruction at allocation
  // otherwise). ddata is the custom shadow of the debug module's data0/data1
  // pair (hartinfo dataaccess=0, dataaddr=0x7B4): the abstract GPR-access
  // sequences move values through it with a single csrr/csrw.
  localparam bit [11:0] CsrDcsr = 12'h7B0;
  localparam bit [11:0] CsrDpc = 12'h7B1;
  localparam bit [11:0] CsrDscratch0 = 12'h7B2;
  localparam bit [11:0] CsrDscratch1 = 12'h7B3;
  localparam bit [11:0] CsrDdata = 12'h7B4;
  // dcsr fields. xdebugver=4 (0.13); stepie/stopcount/stoptime hardwired 0;
  // mprven hardwired 1 (MPRV keeps its M-mode meaning in Debug Mode).
  localparam int unsigned DcsrEbreakMBit = 15;
  localparam int unsigned DcsrEbreakSBit = 13;
  localparam int unsigned DcsrEbreakUBit = 12;
  localparam int unsigned DcsrCauseLo = 6;  // [8:6]
  localparam int unsigned DcsrStepBit = 2;
  localparam int unsigned DcsrPrvLo = 0;  // [1:0]
  // dcsr.cause values (spec priority: ebreak > haltreq > step).
  localparam bit [2:0] DcsrCauseEbreak = 3'd1;
  localparam bit [2:0] DcsrCauseHaltreq = 3'd3;
  localparam bit [2:0] DcsrCauseStep = 3'd4;
  // Custom machine CSRs for Tomasulo performance profiling
  localparam bit [11:0] CsrMperfSel = 12'h7C0;  // Profiling counter selector
  // Profiling control: bit 0 captures; bit 1 selects the preceding cache snapshot.
  localparam bit [11:0] CsrMperfCtl = 12'h7C1;
  localparam bit [11:0] CsrMperfData = 12'hFC0;  // Selected counter low 32 bits
  localparam bit [11:0] CsrMperfDataH = 12'hFC1;  // Selected counter high 32 bits
  localparam bit [11:0] CsrMperfCount = 12'hFC2;  // Number of profiling counters

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

  // mstatus bit positions (low word)
  localparam int unsigned MstatusSieBit = 1;  // Supervisor Interrupt Enable
  localparam int unsigned MstatusMieBit = 3;  // Machine Interrupt Enable
  localparam int unsigned MstatusSpieBit = 5;  // Supervisor Previous Interrupt Enable
  localparam int unsigned MstatusMpieBit = 7;  // Machine Previous Interrupt Enable
  localparam int unsigned MstatusSppBit = 8;  // Supervisor Previous Privilege (1 bit: U/S)
  // mstatus.MPP occupies [12:11]; mstatus.MPRV is bit 17.
  localparam int unsigned MstatusMppLo = 11;
  localparam int unsigned MstatusMprvBit = 17;
  // Translation-permission and trap-virtualization fields.
  localparam int unsigned MstatusSumBit = 18;  // permit Supervisor User Memory access
  localparam int unsigned MstatusMxrBit = 19;  // Make eXecutable Readable
  localparam int unsigned MstatusTvmBit = 20;  // Trap Virtual Memory (satp/sfence.vma in S)
  localparam int unsigned MstatusTwBit = 21;  // Timeout Wait (WFI below M)
  localparam int unsigned MstatusTsrBit = 22;  // Trap SRET (sret in S)

  // Privilege modes (RISC-V encoding). FROST implements M, S, and U.
  localparam logic [1:0] PrivU = 2'b00;
  localparam logic [1:0] PrivS = 2'b01;
  localparam logic [1:0] PrivM = 2'b11;

  // mie/mip bit positions
  localparam int unsigned MieSsiBit = 1;  // Supervisor Software Interrupt
  localparam int unsigned MieMsiBit = 3;  // Machine Software Interrupt
  localparam int unsigned MieStiBit = 5;  // Supervisor Timer Interrupt
  localparam int unsigned MieMtiBit = 7;  // Machine Timer Interrupt
  localparam int unsigned MieSeiBit = 9;  // Supervisor External Interrupt
  localparam int unsigned MieMeiBit = 11;  // Machine External Interrupt

  // Exception cause codes (mcause values when the interrupt bit is clear),
  // XLEN-wide.
  localparam bit [XLEN-1:0] ExcInstrAccessFault = XLEN'(1);
  localparam bit [XLEN-1:0] ExcIllegalInstr = XLEN'(2);
  localparam bit [XLEN-1:0] ExcBreakpoint = XLEN'(3);
  localparam bit [XLEN-1:0] ExcLoadAddrMisalign = XLEN'(4);
  localparam bit [XLEN-1:0] ExcLoadAccessFault = XLEN'(5);
  localparam bit [XLEN-1:0] ExcStoreAddrMisalign = XLEN'(6);
  localparam bit [XLEN-1:0] ExcStoreAccessFault = XLEN'(7);
  localparam bit [XLEN-1:0] ExcEcallUmode = XLEN'(8);
  localparam bit [XLEN-1:0] ExcEcallSmode = XLEN'(9);
  localparam bit [XLEN-1:0] ExcEcallMmode = XLEN'(11);
  // Sv39 page faults, all delegable (MedelegMask bits 12, 13, and 15).
  localparam bit [XLEN-1:0] ExcInstrPageFault = XLEN'(12);
  localparam bit [XLEN-1:0] ExcLoadPageFault = XLEN'(13);
  localparam bit [XLEN-1:0] ExcStorePageFault = XLEN'(15);
  // Memory-order replay for DMA coherence: a load that observed memory
  // before an external write to its line and has not retired is restarted at
  // its own PC with no CSR or privilege effect (trap_unit). A custom-use
  // cause number, never architecturally visible.
  localparam bit [XLEN-1:0] ExcMemReplay = XLEN'(24);

  // medeleg implemented-bit mask (WARL): causes 0-9, 12, 13, and 15 are
  // delegable. Cause 11 (ecall from M) is read-only zero per the privileged
  // spec, and FROST raises no architectural cause 10, 14, or 16 and above.
  localparam bit [XLEN-1:0] MedelegMask = XLEN'(64'h0000_B3FF);
  // mideleg implemented-bit mask (WARL): the supervisor interrupt classes
  // (SSI/STI/SEI). The machine classes are read-only zero per the spec.
  localparam bit [XLEN-1:0] MidelegMask =
      XLEN'((64'h1 << MieSsiBit) | (64'h1 << MieStiBit) | (64'h1 << MieSeiBit));

  // Interrupt cause codes (mcause values when the interrupt bit is set).
  // The interrupt bit is bit XLEN-1 of mcause, not bit 31, so these are
  // built XLEN-wide by construction. Never compare them against 32-bit
  // slices of a wider mcause.
  localparam bit [XLEN-1:0] IntSupervisorSoftware = {1'b1, {(XLEN - 4) {1'b0}}, 3'd1};
  localparam bit [XLEN-1:0] IntMachineSoftware = {1'b1, {(XLEN - 4) {1'b0}}, 3'd3};
  localparam bit [XLEN-1:0] IntSupervisorTimer = {1'b1, {(XLEN - 4) {1'b0}}, 3'd5};
  localparam bit [XLEN-1:0] IntMachineTimer = {1'b1, {(XLEN - 4) {1'b0}}, 3'd7};
  localparam bit [XLEN-1:0] IntSupervisorExternal = {1'b1, {(XLEN - 5) {1'b0}}, 4'd9};
  localparam bit [XLEN-1:0] IntMachineExternal = {1'b1, {(XLEN - 5) {1'b0}}, 4'd11};

  // ===========================================================================
  // Section 4: Control Enumerations
  // ===========================================================================
  // Branch operation types and store operation types. These are compact
  // encodings used by branch resolution and store-queue routing.

  // Branch operation type, capped at 3 bits to keep the decode logic small.
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

  // Kept as narrow as the store-size set allows.
  // STN must be 0 so Verilator's 2-state initialization (all zeros) defaults to "no store"
  typedef enum bit [2:0] {
    STN,  // store nothing (default/reset value)
    STB,  // store byte
    STH,  // store half-word
    STW,  // store word
    STD   // store doubleword (RV64 SD)
  } store_op_e;

  // ===========================================================================
  // Section 5: Instruction Format
  // ===========================================================================
  // Packed struct matching the RISC-V R-type instruction format.
  // Other formats (I, S, B, U, J) reuse the same fields differently.

  typedef struct packed {
    logic [6:0] funct7;        // Function code (7-bit) - specifies operation variant
    logic [4:0] source_reg_2;  // Second source register (rs2) - 0-31
    logic [4:0] source_reg_1;  // First source register (rs1) - 0-31
    logic [2:0] funct3;        // Function code (3-bit) - specifies operation type
    logic [4:0] dest_reg;      // Destination register (rd) - 0-31
    logic [6:0] opcode;        // Operation code - identifies instruction category
  } instr_t;

  localparam bit [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0

  // The core is RV64GCB, and this localparam is the one definition of its
  // width: module-level XLEN parameters default to it and exist only so unit
  // benches can elaborate standalone.
  localparam int unsigned XLEN = 64;

  // Physical-map geometry. The entire physical map lives below 4 GiB
  // (256 KiB low BRAM at 0, MMIO in the 01 quadrant at 0x4000_0000, 1 GiB
  // cached DDR at 0x8000_0000). Region decodes therefore key on fixed
  // physical bit positions (bit 31 selects the cached region,
  // addr[31:30]==01 is MMIO), never on XLEN-relative positions like
  // [XLEN-1], which is always zero for a mapped address. Architectural
  // PCs, targets and AGU outputs flow full-width, and out-of-map addresses
  // raise PMA access faults before reaching any memory tier (see
  // pma_fetch_ok/pma_data_ok). Bits [XLEN-1:32] of every launched memory
  // access are therefore zero by the PMA invariant rather than by
  // producer-side masking.
  localparam int unsigned PhysAddrBits = 32;
  localparam int unsigned CachedRegionBit = 31;

  // Debug-module execution slice: the top 1 KiB of the first 96 KiB of low
  // BRAM, between the linker scripts' ROM and RAM regions. Every linker
  // script that uses low BRAM reserves it as the DEBUG region, and only the
  // debug module writes it, through the programming port. The hart executes
  // here in Debug Mode: the park loop, the abstract-command words, the
  // program buffer, and the resume word. Word offsets:
  //   0x00 park (jal x0,0)   0x04 nop (the parked window's word 1)
  //   0x08..0x10 abstract a0..a2   0x14..0x30 progbuf[0..7]
  //   0x34 ebreak (impebreak)   0x38 dret (resume)   0x3C ebreak
  // Fits every MEM_SIZE_BYTES >= 96 KiB; the region keys on fixed physical
  // bit positions like the rest of the map.
  localparam bit [31:0] DebugSliceBase = 32'h0001_7C00;
  localparam int unsigned DebugSliceBytes = 1024;
  localparam bit [31:0] DebugParkAddr = DebugSliceBase + 32'h00;
  localparam bit [31:0] DebugAbstractAddr = DebugSliceBase + 32'h08;
  localparam bit [31:0] DebugProgbufAddr = DebugSliceBase + 32'h14;
  localparam bit [31:0] DebugImpebreakAddr = DebugSliceBase + 32'h34;
  localparam bit [31:0] DebugResumeAddr = DebugSliceBase + 32'h38;
  localparam int unsigned DebugProgbufWords = 8;

  // Data-tier beat width (hw/rtl/README.md, "Data-tier bus contract"), a
  // separate constant from XLEN. Every data-side bus carries the aligned
  // dword at addr[31:3]; byte lane i is byte address {addr[31:3], i}.
  // Sub-beat writes replicate their data across the beat and select lanes
  // with the strobe; reads return the full beat and consumers extract by
  // addr[2:0].
  localparam int unsigned MemDataBits = 64;
  localparam int unsigned MemStrbBits = MemDataBits / 8;

  // Cached-tier load slots: the load queue keeps up to this many cached loads
  // in flight, each tagged with its slot id through the router and the
  // cached_tier_adapter (matches the L1D's miss-status slot count).
  localparam int unsigned CachedLoadSlots = 4;
  localparam int unsigned CachedLoadSlotBits = 2;

  // Entries in the load queue's direct-mapped L0 cache, eight bytes each.
  // frost's L0_CACHE_DEPTH defaults to this and changes the L0's capacity
  // without changing the queue or coherence-table capacity.
  localparam int unsigned LqL0Depth = 128;

  // DMA coherence: lock entries of the cache hierarchy's DMA
  // sequencer (frost_cache_hierarchy NUM_DMA_LOCK), mirrored by the core's
  // lq_coherence_port; a DMA write to a line holds one from admission until
  // the shared level has ordered it.
  localparam int unsigned DmaCoherenceLocks = 3;
  localparam int unsigned DmaCoherenceLockBits = 2;
  // Lowest address bit of a coherence line: two addresses share a line when
  // they agree from this bit up. It is $clog2(LINE_BYTES) for the cache
  // hierarchy's 32-byte line (frost_cache LINE_BYTES). Every core-side
  // comparison against a DMA line (the load queue's invalidate, block, and
  // query hits, lq_coherence_port's line registers, and sc_pending_unit's
  // head-SC query match) must use the same split, so it is defined once here.
  localparam int unsigned DmaCoherenceLineLsb = 5;

  // 8-lane strobe for a sub-beat access at the given offset (see the
  // contract above; DOUBLE covers the whole beat).
  function automatic logic [MemStrbBits-1:0] mem_strobe_for(input logic [1:0] size_bits,
                                                            input logic [2:0] offset);
    unique case (size_bits)
      2'b00:   mem_strobe_for = MemStrbBits'(8'h01) << offset;  // byte
      2'b01:   mem_strobe_for = MemStrbBits'(8'h03) << {offset[2:1], 1'b0};  // half
      2'b10:   mem_strobe_for = offset[2] ? 8'hF0 : 8'h0F;  // word
      default: mem_strobe_for = 8'hFF;  // double
    endcase
  endfunction

  // Physical view of an address: the low 32 bits, zero-extended. Apply only
  // at physical consumers (IF's served-window view of pc_reg and the load
  // queue's store-forwarding check addresses); architectural PCs, targets
  // and AGU outputs flow full-width, and out-of-map addresses raise PMA
  // access faults instead of aliasing (pma_fetch_ok / pma_data_ok below).
  function automatic logic [XLEN-1:0] canonical_paddr(input logic [XLEN-1:0] addr);
    canonical_paddr = XLEN'(addr[PhysAddrBits-1:0]);
  endfunction

  // PMA region checks. The physical map:
  //   [0x0000_0000, 0x0004_0000)  256 KiB BRAM      fetch + data
  //   [0x4000_0000, 0x8000_0000)  device quadrant   data only (no fetch)
  //   [0x8000_0000, 0xC000_0000)  1 GiB cached DDR  fetch + data
  // Everything else, including all of [63:32], is unmapped and faults
  // (instruction/load/store-AMO access fault, causes 1/5/7). An address that
  // fails its pma_*_ok check never reaches a memory tier: fetch delivers a
  // fault-tagged bundle (the FETCH_FAULT pseudo-op raises the precise
  // exception), and a data access faults at the LQ/SQ issue check beside the
  // misalignment test (under Sv39, the data MMU checks the translated
  // address). Consequently every launched memory access has bits
  // [XLEN-1:32] zero, which is the invariant the 32-bit region decodes and
  // the load queue's masked store-forwarding check address rely on.
  function automatic logic pma_fetch_ok(input logic [XLEN-1:0] addr);
    pma_fetch_ok = (addr[XLEN-1:18] == '0) || ((addr[XLEN-1:32] == '0) && (addr[31:30] == 2'b10));
  endfunction

  function automatic logic pma_data_ok(input logic [XLEN-1:0] addr);
    pma_data_ok = pma_fetch_ok(addr) || ((addr[XLEN-1:32] == '0) && (addr[31:30] == 2'b01));
  endfunction

  // Served MMIO window decode: the implemented register window
  // [mmio_base, mmio_base + mmio_size_bytes) plus the PLIC window (a second
  // served range in the device quadrant, addr[31:22] == 10'h110). The
  // data_mem_request_router uses it for its pending device read, and the
  // load queue pre-registers it beside the AMO write address (the router's
  // AMO BRAM-mask safety), so the one decode is shared here instead of being
  // written twice. Narrower than the LQ/SQ device-quadrant is_mmio class.
  function automatic logic mmio_window_hit(input logic [XLEN-1:0] addr,
                                           input logic [XLEN-1:0] mmio_base,
                                           input logic [XLEN-1:0] mmio_size_bytes);
    mmio_window_hit = ((addr >= mmio_base) && (addr < (mmio_base + mmio_size_bytes))) ||
                      (addr[31:22] == 10'h110);
  endfunction

  // pma_fetch_ok of the page after va's, {va[63:12] + 1, 12'h0} (a 52-bit
  // wrapping increment), without the incrementer: the fetchable regions are
  // [0, 2^18) and [2^31, 3*2^30), so the next page's result can differ from
  // va's own only where the increment carries out of the region index bits;
  // the wrap term keeps the all-ones VA's next page at 0. fetch_verdict uses
  // this for Bare word 1.
  function automatic logic pma_fetch_next_page_ok(input logic [XLEN-1:0] va);
    logic z18, z32;
    z18 = (va[XLEN-1:18] == '0);
    z32 = (va[XLEN-1:32] == '0);
    pma_fetch_next_page_ok = (z18 && !(&va[17:12])) || (&va[XLEN-1:12]) ||
        (z32 && (((va[31:30] == 2'b10) && !(&va[29:12])) ||
                 ((va[31:30] == 2'b01) && (&va[29:12]))));
  endfunction

  // VA-only facts for a fetch window {va, aligned-word-after-va}: whether it
  // straddles a 4 KiB page, the Bare PMA faults of its two words (word 1 is
  // the next page's base when straddling), and whether the line after word
  // 0's line stays in-page (1 when word 1 starts the next line, where the
  // fetch provider uses word 1's own fault flag instead). The IMMU evaluates
  // this directly on registered i_pc for its Bare bypass.
  typedef struct packed {
    logic straddle;
    logic bare_fault0;
    logic bare_fault1;
    logic line_after_in_page;
  } fetch_verdict_t;

  function automatic fetch_verdict_t fetch_verdict(input logic [XLEN-1:0] va);
    fetch_verdict_t v;
    v.straddle = &va[11:2];
    v.bare_fault0 = !pma_fetch_ok(va);
    v.bare_fault1 = v.straddle ? !pma_fetch_next_page_ok(va) : v.bare_fault0;
    v.line_after_in_page = (va[11:5] != 7'h7F) || (va[4:2] == 3'b111);
    fetch_verdict = v;
  endfunction

  // ---------------------------------------------------------------------------
  // Sv39 data and instruction translation
  // ---------------------------------------------------------------------------
  // A virtual address is 39 bits: three 9-bit VPN levels over a 4 KiB page
  // offset. Bits [63:39] must equal bit 38 (canonical form); a non-canonical
  // data address raises the access-type page fault without walking.
  localparam int unsigned Sv39VaBits = 39;
  localparam int unsigned Sv39PageOffsetBits = 12;
  localparam int unsigned Sv39VpnFieldBits = 9;
  localparam int unsigned Sv39Levels = 3;
  localparam int unsigned Sv39VpnBits = Sv39Levels * Sv39VpnFieldBits;  // 27

  // PTE layout (RV64): PPN in [53:10], flags in [7:0], bits [63:54] reserved
  // (must be zero, else page fault: Svpbmt/Svnapot are out of scope and
  // their bits fault per spec).
  localparam int unsigned PtePpnBits = 44;
  localparam int unsigned PteFlagV = 0;
  localparam int unsigned PteFlagR = 1;
  localparam int unsigned PteFlagW = 2;
  localparam int unsigned PteFlagX = 3;
  localparam int unsigned PteFlagU = 4;
  localparam int unsigned PteFlagG = 5;
  localparam int unsigned PteFlagA = 6;
  localparam int unsigned PteFlagD = 7;

  function automatic logic sv39_va_canonical(input logic [XLEN-1:0] va);
    sv39_va_canonical = (va[XLEN-1:Sv39VaBits-1] == '0) || (va[XLEN-1:Sv39VaBits-1] == '1);
  endfunction

  // Data-side translation fault classification, carried from the translation
  // stage into the LQ entry (loads/AMOs/LR) or the store fault strobe. The
  // faulting op parks its virtual address for xtval and never launches; the
  // cause is derived from {kind, is_amo/is_store} at completion.
  typedef enum logic [1:0] {
    DFAULT_NONE = 2'd0,
    DFAULT_MISALIGN = 2'd1,  // VA-domain misalignment (checked before translation)
    DFAULT_PAGE = 2'd2,  // page fault: walk-refused, non-canonical, or permission
    DFAULT_ACCESS = 2'd3  // access fault: PTE address or leaf PA outside the PMA map
  } data_fault_kind_e;

  // Page-table walk response (ptw -> requesting MMU). fault_kind NONE means a
  // leaf PTE with A=1 was found: install {ppn, level, flags} for the echoed
  // vpn. PAGE/ACCESS deliver the walk's refusal to the op that asked
  // (matched by the vpn echo: the requester may have been flushed and
  // replaced since it asked). DFAULT_MISALIGN never occurs here.
  typedef struct packed {
    data_fault_kind_e fault_kind;
    logic [Sv39VpnBits-1:0] vpn;  // echo of the request
    logic [PtePpnBits-1:0] ppn;
    logic [1:0] level;  // 0 = 4 KiB leaf, 1 = 2 MiB, 2 = 1 GiB
    logic perm_r;
    logic perm_w;
    logic perm_x;
    logic perm_u;
    logic perm_d;  // D=0 install is legal; a store to it faults at lookup
  } ptw_resp_t;
  // FP register width: 64-bit to support the D extension.
  localparam int unsigned FpWidth = 64;
  localparam int unsigned FpSingleWidth = 32;
  localparam int unsigned FpDoubleWidth = 64;

  // PC increment constants for instruction length handling
  localparam logic [XLEN-1:0] PcIncrementCompressed = 2;  // 16-bit compressed instruction
  localparam logic [XLEN-1:0] PcIncrement32bit = 4;  // 32-bit standard instruction
  localparam int unsigned PcAdvanceSelWidth = 2;
  // Arms of pc_controller's next-PC priority selector. if_stage uses the
  // one-hot winner and sequential-arm mask to classify provider retargets;
  // translation itself starts from the selected, registered PC.
  localparam int unsigned PcNextArms = 14;
  localparam logic [PcAdvanceSelWidth-1:0] PcAdvancePlus2 = 2'd0;
  localparam logic [PcAdvanceSelWidth-1:0] PcAdvancePlus4 = 2'd1;
  localparam logic [PcAdvanceSelWidth-1:0] PcAdvancePlus6 = 2'd2;
  localparam logic [PcAdvanceSelWidth-1:0] PcAdvancePlus8 = 2'd3;

  // XLEN-wide DIV/REM special-case values (overflow and divide-by-zero).
  // The RV64M W forms need no 32-bit variants: int_muldiv_shim shares the
  // XLEN divider with sign/zero-extended operands.
  localparam bit [XLEN-1:0] SignedIntMin = {1'b1, {(XLEN - 1) {1'b0}}};  // -2^(XLEN-1)
  localparam bit [XLEN-1:0] SignedIntMax = {1'b0, {(XLEN - 1) {1'b1}}};  // 2^(XLEN-1) - 1
  localparam bit [XLEN-1:0] UnsignedIntMax = '1;  // All ones
  localparam bit [XLEN-1:0] NegativeOne = '1;  // -1 in two's complement

  // ===========================================================================
  // Section 6: Pipeline Control
  // ===========================================================================
  // Control signals distributed through the pipeline control bundle.
  typedef struct packed {
    logic reset;
    logic stall;  // Freeze pipeline (don't advance)
    logic stall_registered;  // Stall signal from previous cycle
    logic stall_for_trap_check;  // Stall conditions for trap unit (before trap/mret gating)
    logic flush;  // Clear pipeline (insert bubble/NOP)
    // Registered trap/mret signals: they break the timing path from
    // trap/MRET detection through the IF stage.
    logic trap_taken_registered;  // trap_taken from previous cycle
    logic mret_taken_registered;  // mret_taken from previous cycle
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

  // Branch direction predictor (bimodal) index width.  Must match
  // direction_predictor's BIM_BITS.  Also the width of the predict-time index
  // carried with each branch (bp_dir_idx) for commit-time training.
  localparam int unsigned BpDirIdxBits = 10;

  // Clocked signals passed from Instruction Fetch (IF) stage to Pre-Decode (PD) stage.
  // IF assembles an instruction that spans two words in the same cycle. PD
  // builds a compressed slot 1's 32-bit instruction from the predecode
  // sideband's expansion that IF selected (the *_predecoded fields); IF's
  // aligner expands slot 2 (see decomp_illegal).
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    // Raw 16-bit parcel at the instruction's start. PD takes slot 1's size and
    // compressed branch offset from it, and expands it only in simulation, as
    // the reference for its checks.
    logic [15:0] raw_parcel;
    // Selection signals for final instruction mux (computed in IF, used in PD)
    logic sel_nop;
    logic sel_compressed;  // True if raw_parcel is a compressed instruction
    // Effective 32-bit instruction word (aligned or spanning-assembled)
    instr_t effective_instr;
    // Exact {rs2[1], rs1[2:1]} bits for the selected architectural
    // instruction. Compressed values come from the IMEM sideband; native
    // values come from effective_instr.  IF resolves slot 2 beside each fixed
    // aligner candidate before its late position mux, while slot 1 resolves
    // after spanning assembly. PD builds its early source registers from the
    // *_predecoded fields.
    logic [2:0] source_hot_predecoded;
    // The selected instruction's bits [24:20]: the IMEM sideband's RVC
    // expansion, or the native instruction's own bits.
    logic [4:0] bits24_20_predecoded;
    // Remaining rs1 field bits {instruction[19:18], instruction[15]}.
    logic [2:0] rs1_rest_predecoded;
    // Slot 1 only (0 for slot 2): the IMEM sideband's
    // {illegal, expanded[31:25], expanded[14:0]} for the selected parcel.
    logic [22:0] rvc_extra_predecoded;
    // Branch prediction metadata (from BTB)
    logic btb_hit;  // BTB lookup hit
    logic btb_predicted_taken;  // BTB predicts taken
    // Target is meaningful only with btb_predicted_taken. Invalid/NOP packets
    // carry whatever target was selected rather than zero, so late front-end
    // validity controls stay out of this wide datapath.
    logic [XLEN-1:0] btb_predicted_target;
    // RAS (Return Address Stack) prediction metadata
    logic ras_predicted;  // RAS prediction was used
    logic [XLEN-1:0] ras_predicted_target;  // RAS predicted return address
    // RAS entry state for this packet: after any older pipelined operation and
    // before this packet's own operation, for recovery.
    logic [RasPtrBits-1:0] ras_checkpoint_tos;
    logic [RasPtrBits:0] ras_checkpoint_valid_count;
    // Bimodal branch-direction prediction, not gated by btb_hit, carried to
    // PD.  PD uses it to redirect on a BTB miss when the direction predicts
    // taken, whatever the offset sign.  Consumed only in PD (slot-1); not
    // carried past PD.
    logic bp_dir_taken;
    // Predict-time bimodal index this op carried from fetch, handed back at
    // commit to train the entry the prediction read (carried all the way to
    // commit, unlike bp_dir_taken, which PD consumes).
    logic [BpDirIdxBits-1:0] bp_dir_idx;
    // Fetch fault: the bundle's instruction bytes could not be fetched.
    // Either its word's physical address fails pma_fetch_ok (Bare), or under
    // Sv39 the permission check failed, the walk was refused, the VA is
    // non-canonical, or the translated PA is out of the map. The payload
    // bytes are garbage; decode overrides them with the FETCH_FAULT /
    // FETCH_PAGE_FAULT pseudo-op (fetch_fault_page selects the cause:
    // 0 = access fault 1, 1 = page fault 12), and IF/PD suppress prediction
    // use and the PD redirect for the bundle so garbage bytes can never
    // redirect execution. fetch_fault_hi marks a fault on the instruction's
    // second halfword only (a 32-bit instruction straddling a page boundary
    // whose first page is fine): xtval is then the instruction's PC + 2, the
    // faulting portion.
    logic fetch_fault;
    logic fetch_fault_page;
    logic fetch_fault_hi;
    // Slot-2 only: illegal-RVC flag for the expanded effective_instr (the
    // aligner takes each candidate's flag from its sideband; see
    // instruction_aligner). 0 for slot 1, whose illegal flag PD takes from
    // rvc_extra_predecoded.
    logic decomp_illegal;
  } from_if_to_pd_t;

  // Clocked signals passed from Pre-Decode (PD) stage to Instruction Decode (ID) stage
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    instr_t instruction;
    // Bubble marker. When set, id_stage treats that slot's `instruction` as a
    // NOP; frontend_validity_tracker also consumes the slot-1 marker.
    // Carrying flush/pd_redirect/sel_nop here, instead of muxing NOP into the
    // instruction-register D inputs in pd_stage, keeps the deep
    // frontend-stall-fed select off both slots' instruction datapaths.
    logic inject_nop;
    // Original instruction size before RVC decompression.
    logic is_compressed;
    // Source registers from IF's predecoded fields, registered in PD so the
    // ID regfile read and dispatch need not wait for decode.
    logic [4:0] source_reg_1_early;
    logic [4:0] source_reg_2_early;
    // F extension: Early FP source reg 3 for FMA instructions (rs3 = funct7[6:2])
    logic [4:0] fp_source_reg_3_early;
    logic illegal_instruction;  // Illegal compressed instruction (predecoded illegal-RVC flag)
    logic fetch_fault;  // Fetch fault (overrides decode with FETCH_[PAGE_]FAULT)
    logic fetch_fault_page;  // ...page fault (cause 12) rather than access fault (1)
    logic fetch_fault_hi;  // ...on the second halfword only (xtval = PC + 2)
    // Branch prediction metadata (passed through from IF)
    logic btb_hit;
    logic btb_predicted_taken;
    logic [XLEN-1:0] btb_predicted_target;  // Valid only with btb_predicted_taken
    // RAS prediction metadata (passed through from IF)
    logic ras_predicted;
    logic [XLEN-1:0] ras_predicted_target;
    logic [RasPtrBits-1:0] ras_checkpoint_tos;
    logic [RasPtrBits:0] ras_checkpoint_valid_count;
    // Predict-time bimodal index carried to commit for training.
    logic [BpDirIdxBits-1:0] bp_dir_idx;
  } from_pd_to_id_t;

  // Clocked signals passed from Instruction Decode (ID) stage to Execute (EX) stage
  typedef struct packed {
    logic [XLEN-1:0] program_counter;
    // Immediate values decoded from instruction (different formats),
    // sign-extended to XLEN by immediate_decoder.
    logic [XLEN-1:0] immediate_i_type;  // I-type: 12-bit sign-extended
    logic [XLEN-1:0] immediate_s_type;  // S-type: for stores
    logic [XLEN-1:0] immediate_b_type;  // B-type: for branches
    logic [XLEN-1:0] immediate_u_type;  // U-type: upper 20 bits
    logic [XLEN-1:0] immediate_j_type;  // J-type: for jumps
    // Register file read data, read in ID with PD's early source registers.
    logic [XLEN-1:0] source_reg_1_data;
    logic [XLEN-1:0] source_reg_2_data;
    // Pre-computed x0 flags: set when the corresponding source register is
    // x0. They keep the ~|source_reg NOR gate out of the dispatch and
    // register-read paths.
    logic source_reg_1_is_x0;
    logic source_reg_2_is_x0;
    // Instruction type flags
    logic is_load_instruction;
    logic is_load_byte, is_load_halfword, is_load_unsigned;
    instr_op_e instruction_operation;
    branch_taken_op_e branch_operation;
    store_op_e store_operation;
    // Pre-decoded reservation-station route. Stored as raw bits because
    // rs_type_e is declared later in this package.
    logic [2:0] rs_type;
    logic is_int_store;
    logic is_branch_or_jump;
    logic is_fence;
    logic is_fence_i;
    logic is_csr_imm;
    logic has_fp_flags;
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
    logic is_mret;  // Any xRET: MRET, SRET or DRET (the latter two ride the MRET machinery)
    logic is_sret;  // Qualifies is_mret as SRET (sepc/SPP/SPIE side, S-priv gate)
    logic is_dret;  // Qualifies is_mret as DRET (dpc/dcsr side, Debug-Mode gate)
    logic is_sfence_vma;  // Qualifies is_fence_i as SFENCE.VMA (TVM/U-priv gate)
    logic is_wfi;  // WFI instruction
    logic is_ecall;  // ECALL instruction
    logic is_ebreak;  // EBREAK instruction
    logic is_illegal_instruction;  // Illegal instruction (unknown opcode or illegal compressed)
    logic is_fetch_fault;  // Fetch fault pseudo-op (cause 1 or 12 at the FU shim)
    logic is_fetch_fault_page;  // ...FETCH_PAGE_FAULT (cause 12) instead of FETCH_FAULT
    logic is_fetch_fault_hi;  // ...faulting portion is the second halfword (xtval = PC + 2)
    // F extension fields
    logic is_fp_instruction;  // Any FP instruction
    logic is_fp_load;  // FLW or FLD: data goes to the FP regfile
    logic is_fp_store;  // FSW or FSD
    logic is_fp_load_double;  // FLD
    logic is_fp_store_double;  // FSD
    logic is_fp_compute;  // FP compute op (FADD, FSUB, FMUL, FDIV, FSQRT, FMA*, etc.)
    logic is_pipelined_fp_op;  // Multi-cycle FP op: FADD, FSUB, FMUL, FDIV, FSQRT, or an FMA
    logic [2:0] fp_rm;  // Rounding mode from instruction (funct3)
    logic is_fp_to_int;  // FP to integer conversion (result goes to int reg)
    logic is_int_to_fp;  // Integer to FP conversion (uses int rs1)
    // FP source register data (read in ID stage)
    logic [FpWidth-1:0] fp_source_reg_1_data;
    logic [FpWidth-1:0] fp_source_reg_2_data;
    logic [FpWidth-1:0] fp_source_reg_3_data;  // For FMA instructions
    // Pre-computed link address for JAL/JALR (PC+2 or PC+4 based on compression)
    logic [XLEN-1:0] link_address;
    // Original instruction size before RVC decompression.
    logic is_compressed;
    // Branch and JAL targets are computed in ID, which keeps the adders off
    // the execute path. A JALR target needs rs1, so it is computed at
    // execute.
    logic [XLEN-1:0] branch_target_precomputed;  // PC + imm_b (for conditional branches)
    logic [XLEN-1:0] jal_target_precomputed;  // PC + imm_j (for JAL)
    instr_t instruction;
    // Branch prediction metadata (passed through from IF via PD/ID)
    logic btb_hit;
    logic btb_predicted_taken;
    logic [XLEN-1:0] btb_predicted_target;  // Valid only with btb_predicted_taken
    // RAS prediction metadata (passed through from IF via PD/ID)
    logic ras_predicted;
    logic [XLEN-1:0] ras_predicted_target;
    logic [RasPtrBits-1:0] ras_checkpoint_tos;
    logic [RasPtrBits:0] ras_checkpoint_valid_count;
    // Predict-time bimodal index carried to commit for training.
    logic [BpDirIdxBits-1:0] bp_dir_idx;
    // Pre-computed RAS instruction type flags, which keep the register
    // comparisons out of the dispatch path. Computed in ID from registered
    // values; dispatch forwards them into the ROB entry so commit-time
    // recovery can replay the front end's RAS operation after restoring a
    // checkpoint (ex_comb_synthesizer).
    // {is_ras_return, is_ras_call} == 2'b11 is the reserved coroutine (swap)
    // encoding: a plain return needs rd==x0 and a plain call needs rd in
    // {x1,x5}, so the pair is otherwise mutually exclusive.  See
    // instruction_type_decoder.sv.
    logic is_ras_return;  // JALR with rs1=x1, rd=x0, imm=0 (matches ras_detector)
    logic is_ras_call;  // JAL/JALR with rd in {x1,x5}
    logic ras_predicted_target_nonzero;  // ras_predicted_target != 0
    // Expected rs1 of a JALR that follows the RAS prediction: its target is
    // rs1 + imm, so rs1 = ras_predicted_target - imm.
    logic [XLEN-1:0] ras_expected_rs1;
    // BTB check for JAL and branches: their target is PC-relative and known
    // in ID, so ID compares it with btb_predicted_target directly.
    logic btb_correct_non_jalr;  // True if non-JALR target matches BTB prediction
    logic [XLEN-1:0] btb_expected_rs1;  // btb_predicted_target - imm_i (for JALR)
    // The same PC-relative target check against the RAS prediction, so
    // dispatch can forward the bit that matches its selected prediction
    // source (rs_dispatch_t.predicted_target_ok).
    logic ras_correct_non_jalr;
    // PC-relative value for the ops whose execute-time result is a pure
    // function of the PC and the instruction: PC + imm_u for AUIPC, PC + the
    // faulting-halfword offset (the xtval) for the fetch-fault pseudo-ops.
    // Dispatch carries it in the RS immediate, so the stations need no PC.
    logic [XLEN-1:0] pc_relative_precomputed;
    // Pre-decoded operand-classification flags. Dispatch consumes these as
    // registered FF outputs instead of re-decoding `instruction_operation`
    // through case statements, which keeps that decode off the start of the
    // path from the ID/EX register to the RS write port. Set to 0 on
    // flush/reset; an illegal instruction is treated as ILLEGAL (all flags 0)
    // to mirror the override dispatch applies via
    // op = is_illegal ? ILLEGAL : instr_op.
    logic has_int_dest;
    logic has_fp_dest;
    logic uses_int_rs1;
    logic uses_int_rs2;
    logic uses_fp_rs1;
    logic uses_fp_rs2;
    logic uses_fp_rs3;
    // Pre-computed `instruction != NOP` flag, registered in id_stage so the
    // dispatch valid terms (cpu_ooo's id_valid/id_valid_2) test one bit
    // instead of a 32-bit compare.
    logic is_not_nop;
  } from_id_to_ex_t;

  // The narrow control fields of from_id_to_ex_t: every flag, the operation
  // enums, the RS route and the instruction word (same names and types).
  // The decoded-bundle queue keeps a registered copy of exactly what dispatch
  // sees next cycle, built from id_stage's next-edge register values, so
  // dispatch control and rename addressing start at a flop.
  typedef struct packed {
    logic source_reg_1_is_x0;
    logic source_reg_2_is_x0;
    logic is_load_instruction;
    logic is_load_byte;
    logic is_load_halfword;
    logic is_load_unsigned;
    instr_op_e instruction_operation;
    branch_taken_op_e branch_operation;
    store_op_e store_operation;
    logic [2:0] rs_type;
    logic is_int_store;
    logic is_branch_or_jump;
    logic is_fence;
    logic is_fence_i;
    logic is_csr_imm;
    logic has_fp_flags;
    logic is_jump_and_link;
    logic is_jump_and_link_register;
    logic is_multiply;
    logic is_divide;
    logic is_csr_instruction;
    logic is_amo_instruction;
    logic is_lr;
    logic is_sc;
    logic is_mret;
    logic is_sret;
    logic is_dret;
    logic is_sfence_vma;
    logic is_wfi;
    logic is_ecall;
    logic is_ebreak;
    logic is_illegal_instruction;
    logic is_fetch_fault;
    logic is_fetch_fault_page;
    logic is_fetch_fault_hi;
    logic is_fp_instruction;
    logic is_fp_load;
    logic is_fp_store;
    logic is_fp_load_double;
    logic is_fp_store_double;
    logic is_fp_compute;
    logic is_pipelined_fp_op;
    logic is_fp_to_int;
    logic is_int_to_fp;
    logic is_compressed;
    instr_t instruction;
    logic btb_hit;
    logic btb_predicted_taken;
    logic ras_predicted;
    logic is_ras_return;
    logic is_ras_call;
    logic ras_predicted_target_nonzero;
    logic btb_correct_non_jalr;
    logic ras_correct_non_jalr;
    logic has_int_dest;
    logic has_fp_dest;
    logic uses_int_rs1;
    logic uses_int_rs2;
    logic uses_fp_rs1;
    logic uses_fp_rs2;
    logic uses_fp_rs3;
    logic is_not_nop;
  } id_dispatch_ctrl_t;

  // Control-flow feedback consumed by the front-end.
  typedef struct packed {
    logic branch_taken;  // Whether branch or jump should be taken
    logic [XLEN-1:0] branch_target_address;  // Target address for branch/jump
    // BTB update signals (for branch prediction)
    logic btb_update;  // Update BTB entry
    logic [XLEN-1:0] btb_update_pc;  // PC of branch instruction
    logic [XLEN-1:0] btb_update_target;  // Actual branch target
    logic btb_update_taken;  // Actual branch outcome (taken/not-taken)
    logic btb_update_compressed;  // Branch was a compressed (16-bit) instruction
    // RAS misprediction recovery signals
    logic ras_misprediction;  // RAS prediction was wrong, need to restore
    logic [RasPtrBits-1:0] ras_restore_tos;  // TOS to restore on misprediction
    logic [RasPtrBits:0] ras_restore_valid_count;  // Valid count to restore
    // Both bits set == coroutine swap replay (pop then push): replaces the
    // restored top entry and leaves the depth unchanged.  Mirrors the
    // {is_ras_return, is_ras_call} == 2'b11 encoding that carries it here.
    logic ras_pop_after_restore;  // Pop RAS after restoring (for returns that triggered restore)
    logic ras_push_after_restore;  // Push after restoring (for mispredicted calls)
    logic [XLEN-1:0] ras_push_address_after_restore;  // Link address to push after restore
  } from_ex_comb_t;

  // Writeback result bundle.
  typedef struct packed {
    logic regfile_write_enable;
    logic [XLEN-1:0] regfile_write_data;  // Final result to write back
    instr_t instruction;
    // F extension fields
    logic fp_regfile_write_enable;
    logic [4:0] fp_dest_reg;  // FP destination register (for forwarding)
    logic [FpWidth-1:0] fp_regfile_write_data;  // Final FP result to write back
    fp_flags_t fp_flags;  // FP exception flags (to accumulate in fflags)
  } from_ma_to_wb_t;

  // ===========================================================================
  // Section 8: Operand and Register File Structures
  // ===========================================================================
  // Data structures for operand bypassing and register file communication.

  // Integer register file read data for operand selection.
  typedef struct packed {
    logic [XLEN-1:0] source_reg_1_data;
    logic [XLEN-1:0] source_reg_2_data;
  } rf_to_fwd_t;

  // F extension: FP register file read data for operand selection.
  typedef struct packed {
    logic [FpWidth-1:0] fp_source_reg_1_data;
    logic [FpWidth-1:0] fp_source_reg_2_data;
    logic [FpWidth-1:0] fp_source_reg_3_data;
  } fp_rf_to_fwd_t;

  // ===========================================================================
  // Section 9: Trap/Exception Handling
  // ===========================================================================
  // Trap-control structures for M/S/U-mode exception and interrupt handling.
  // Trap and xRET redirect to IF (the trap unit's outputs, registered in
  // ooo_pipeline_control).
  typedef struct packed {
    logic            trap_taken;   // Trap is being taken this cycle
    logic            mret_taken;   // Any xRET (MRET, SRET, DRET) is being taken
    logic [XLEN-1:0] trap_target;  // Trap vector, xRET return PC, Debug Mode address, or replay PC
  } trap_ctrl_t;

  // Interrupt pending signals (from peripherals to CPU)
  typedef struct packed {
    logic meip;  // Machine external interrupt pending
    logic mtip;  // Machine timer interrupt pending
    logic msip;  // Machine software interrupt pending
  } interrupt_t;

  // ===========================================================================
  // Section 10: Bit Manipulation Helper Functions (Zbb Extension)
  // ===========================================================================
  // Bit manipulation helpers structured for FPGA timing:
  //   - CLZ, CTZ, CPOP (Zbb): tree-based parallel counting

  // 8-bit CLZ: returns 0-8 (8 means all zeros).
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

  // 32-bit CLZ using a tree of 8-bit CLZ operations.
  function automatic [31:0] clz32(input logic [31:0] val);
    logic [3:0] clz_byte[4];  // CLZ result for each byte
    logic       nz_byte [4];  // Non-zero flag for each byte

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

  // 8-bit CTZ: returns 0-8 (8 means all zeros).
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

  // 32-bit CTZ using a tree of 8-bit CTZ operations.
  function automatic [31:0] ctz32(input logic [31:0] val);
    logic [3:0] ctz_byte[4];  // CTZ result for each byte
    logic       nz_byte [4];  // Non-zero flag for each byte

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

  // 4-bit popcount (LUT-friendly: 16 input values).
  function automatic [2:0] cpop4(input logic [3:0] val);
    cpop4 = 3'd0;
    for (int i = 0; i < 4; i++) begin
      cpop4 = cpop4 + {2'b0, val[i]};
    end
  endfunction

  // 32-bit CPOP as an addition tree: 8x 4-bit -> 4x 8-bit -> 2x 16-bit ->
  // 1x 32-bit result.
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

  // 64-bit CLZ using a tree of 8-bit CLZ operations. Returns a 7-bit result
  // (0-64).
  function automatic [6:0] clz64(input logic [63:0] val);
    logic [3:0] clz_byte[8];  // CLZ result for each byte
    logic       nz_byte [8];  // Non-zero flag for each byte

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

  // ==========================================================================
  // dsp_tiled_multiplier_unsigned staging formula: the single source for the
  // unit's pipeline depth. The unit derives its internal PipelineStages from
  // this function, and int_muldiv_shim sizes its in-flight tracker from
  // MulPipeDepth below.
  // ==========================================================================
  function automatic int unsigned dsp_tiled_stages(
      input int unsigned a_width, input int unsigned b_width, input int unsigned a_tile_width,
      input int unsigned b_tile_width);
    int unsigned num_terms;
    int unsigned reduce_stages;
    int unsigned staged;
    num_terms = (((a_width + a_tile_width - 1) / a_tile_width) *
                 ((b_width + b_tile_width - 1) / b_tile_width));
    reduce_stages = (num_terms <= 1) ? 0 : $clog2(num_terms);
    staged = reduce_stages + 1;
    // Floor of 3 stages: a single-tile product (FP single precision) takes
    // as long as the double-precision multiply.
    dsp_tiled_stages = (staged < 3) ? 3 : staged;
  endfunction

  // Integer multiplier wrapper latency: sign-magnitude stage + tiled unit +
  // sign-correction stage, at (XLEN+1)-bit operands with the default tiling.
  localparam int unsigned MulAWidth = XLEN + 1;
  localparam int unsigned MulPipeDepth = 1 + dsp_tiled_stages(MulAWidth, MulAWidth, 27, 35) + 1;

  // 64-bit CTZ using tree of 8-bit CTZ operations (mirror of clz64,
  // scanning from LSB byte to MSB byte). Returns 7-bit result (0-64).
  function automatic [6:0] ctz64(input logic [63:0] val);
    logic [3:0] ctz_byte[8];  // CTZ result for each byte
    logic       nz_byte [8];  // Non-zero flag for each byte

    for (int i = 0; i < 8; i++) begin
      ctz_byte[i] = ctz8(val[i*8+:8]);
      nz_byte[i]  = |val[i*8+:8];
    end

    if (nz_byte[0]) ctz64 = {3'd0, ctz_byte[0]};
    else if (nz_byte[1]) ctz64 = {3'd0, ctz_byte[1]} + 7'd8;
    else if (nz_byte[2]) ctz64 = {3'd0, ctz_byte[2]} + 7'd16;
    else if (nz_byte[3]) ctz64 = {3'd0, ctz_byte[3]} + 7'd24;
    else if (nz_byte[4]) ctz64 = {3'd0, ctz_byte[4]} + 7'd32;
    else if (nz_byte[5]) ctz64 = {3'd0, ctz_byte[5]} + 7'd40;
    else if (nz_byte[6]) ctz64 = {3'd0, ctz_byte[6]} + 7'd48;
    else if (nz_byte[7]) ctz64 = {3'd0, ctz_byte[7]} + 7'd56;
    else ctz64 = 7'd64;  // All zeros
  endfunction

  // 64-bit population count as the sum of two 32-bit tree popcounts.
  function automatic [6:0] cpop64(input logic [63:0] val);
    cpop64 = 7'(cpop32(val[31:0])) + 7'(cpop32(val[63:32]));
  endfunction

  // ===========================================================================
  // Section 11: Tomasulo Out-of-Order Execution Structures
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

  // Shared CPU defaults for board builds, simulation and synthesis checks.
  localparam bit EarlyLoadWakeup = 1'b1;
  localparam bit PrepareLoadWhileBusy = 1'b1;
  localparam int unsigned DecodedQueueDepth = 4;  // Two-instruction bundles

  // Reservation Station depths (per RS type). The second integer issue port
  // scans only the lowest eight entries, independently of the total capacity.
  localparam int unsigned IntRsDepth = 16;  // Integer ALU operations
  localparam int unsigned IntRsIssue2Window = 8;
  localparam int unsigned MulRsDepth = 4;  // Multiply/divide operations
  localparam int unsigned MemRsDepth = 8;  // Load/store operations
  localparam int unsigned FpRsDepth = 6;  // FP add/sub/cmp/cvt/classify/sgnj
  localparam int unsigned FmulRsDepth = 4;  // FP multiply/FMA (3 sources)
  localparam int unsigned FdivRsDepth = 2;  // FP divide/sqrt (long latency)

  // Memory queue depths
  localparam int unsigned LqDepth = 8;  // Load queue entries
  localparam int unsigned SqDepth = 8;  // Store queue entries

  // Checkpoint parameters
  localparam int unsigned NumCheckpoints = 8;  // For branch speculation recovery
  localparam int unsigned CheckpointIdWidth = $clog2(NumCheckpoints);  // 3 bits

  // Register file sizes
  localparam int unsigned NumIntRegs = 32;  // x0-x31
  localparam int unsigned NumFpRegs = 32;  // f0-f31
  localparam int unsigned RegAddrWidth = 5;  // $clog2(32)

  // Alias for FP register width (FLEN) - uses FpWidth from Section 5
  localparam int unsigned FLEN = FpWidth;  // 64 bits for D extension

  // CDB parameters
  localparam int unsigned NumFus = 8;  // ALU, MUL, DIV, MEM, FP_ADD, FP_MUL, FP_DIV, ALU2

  // ---------------------------------------------------------------------------
  // Functional Unit Enumeration and RS Assignment
  // ---------------------------------------------------------------------------
  // Identifies the functional unit behind a completion. The CDB arbiter
  // indexes its grants by it and tags each broadcast with it; dispatch
  // routes by rs_type_e instead.

  typedef enum logic [2:0] {
    FU_ALU    = 3'd0,  // Integer ALU pipe 0 (ADD, SUB, AND, OR, XOR, SLT, branches)
    FU_MUL    = 3'd1,  // Integer multiplier
    FU_DIV    = 3'd2,  // Integer divider
    FU_MEM    = 3'd3,  // Load/store unit (both INT and FP)
    FU_FP_ADD = 3'd4,  // FP adder (add/sub/cmp/cvt/classify/sgnj)
    FU_FP_MUL = 3'd5,  // FP multiplier (mul/FMA)
    FU_FP_DIV = 3'd6,  // FP divider/sqrt (long latency)
    FU_ALU2   = 3'd7   // Integer ALU pipe 1 (plain ALU ops only; branches stay on pipe 0)
  } fu_type_e;

  // Reservation station type (for dispatch routing)
  typedef enum logic [2:0] {
    RS_INT  = 3'd0,  // INT_RS: Integer ALU ops, branches, CSR
    RS_MUL  = 3'd1,  // MUL_RS: MUL/DIV
    RS_MEM  = 3'd2,  // MEM_RS: All loads/stores (INT and FP)
    RS_FP   = 3'd3,  // FP_RS: FP add/sub/cmp/cvt/classify/sgnj
    RS_FMUL = 3'd4,  // FMUL_RS: FP mul/FMA (3 sources)
    RS_FDIV = 3'd5,  // FDIV_RS: FP div/sqrt
    RS_NONE = 3'd6   // No RS needed (JAL, WFI, MRET/SRET/DRET, PAUSE; ROB only)
  } rs_type_e;

  // ---------------------------------------------------------------------------
  // Reorder Buffer Interface Structures
  // ---------------------------------------------------------------------------
  // Reorder Buffer exception cause: the low 5 bits of the riscv_pkg Exc*
  // constants (ExcBreakpoint (3) -> 5'd3, ExcStorePageFault (15) -> 5'd15).
  // Five bits hold every synchronous cause FROST raises (at most 15) and the
  // internal replay cause ExcMemReplay (24), which the Reorder Buffer
  // substitutes at the head. The Reorder Buffer tracks only synchronous
  // exceptions. The trap unit handles interrupts separately and builds the
  // full mcause value (interrupt bit clear) when an exception commits.
  localparam int unsigned ExcCauseWidth = 5;

  // Typedef for exception cause to make the encoding explicit
  typedef logic [ExcCauseWidth-1:0] exc_cause_t;

  // Reorder Buffer interface signals (for module ports)
  typedef struct packed {
    logic alloc_valid;  // Request Reorder Buffer allocation
    logic [XLEN-1:0] pc;
    rs_type_e rs_type;
    logic dest_rf;
    logic [RegAddrWidth-1:0] dest_reg;
    logic dest_valid;
    logic is_store;
    logic is_fp_store;
    // Any F/D-extension instruction (FP load/store/compute/FMA, including
    // the x-dest flagless ones: FMV.X/FCLASS). Feeds the ROB's
    // allocation-time mstatus.FS==Off legality check; FP CSR accesses
    // are classified separately from csr_addr at allocation.
    logic is_fp_instruction;
    logic is_branch;
    logic predicted_taken;
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target
    logic [XLEN-1:0] branch_target;  // Architectural taken target when known at dispatch
    logic is_call;
    logic is_return;
    // JAL/JALR: link_addr is the pre-computed PC+2/PC+4 result for rd. The
    // ROB writes it, zero-extended to FLEN, as the entry's value at
    // allocation for both. JAL is marked done=1 at allocation (target
    // known); JALR is done=0 until execute resolves the target.
    logic [XLEN-1:0] link_addr;
    logic is_jal;  // JAL: can mark done=1 at dispatch
    logic is_jalr;  // JALR: must wait for execute to resolve target
    logic is_csr;
    logic is_fence;
    logic is_fence_i;
    logic is_wfi;
    logic is_mret;  // Any xRET (SRET and DRET set this too and ride the MRET machinery)
    // SRET and DRET ride the is_mret machinery and SFENCE.VMA the is_fence_i
    // machinery. Their legality is folded into the ROB exception state at
    // allocation; the per-entry SRET/DRET/SFENCE bits steer the xRET, S-side
    // trap-unit/CSR, and serializer datapaths.
    logic is_sret;
    logic is_dret;
    logic is_sfence_vma;
    logic is_amo;
    logic is_lr;
    logic is_sc;
    logic is_compressed;  // Compressed (16-bit) instruction
    // CSR info (stored in ROB entry for commit-time serialized execution)
    // Write intent per the Zicsr rules: CSRRW/CSRRWI always write; the
    // set/clear forms write only when the rs1/uimm field is nonzero. A
    // write-intending access to a read-only CSR (addr[11:10] == 2'b11) is
    // an illegal instruction, folded into the ROB exception state at
    // allocation.
    logic csr_write_intent;
    logic [11:0] csr_addr;
    logic [2:0] csr_op;  // funct3 for CSR operation
    logic [XLEN-1:0] csr_write_data;  // rs1 value or zero-ext immediate
    // FP flags validity
    logic has_fp_flags;  // Instruction produces FP flags
  } reorder_buffer_alloc_req_t;

  typedef struct packed {
    logic                             alloc_ready;  // Reorder Buffer can accept allocation
    logic [ReorderBufferTagWidth-1:0] alloc_tag;    // Allocated Reorder Buffer entry index
    logic                             full;         // Reorder Buffer is full
  } reorder_buffer_alloc_resp_t;

  // CDB write to Reorder Buffer for ALU, FPU and load results. Branch/jump
  // completion uses reorder_buffer_branch_update_t instead.
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] tag;
    logic [FLEN-1:0]                  value;      // Result value to write to Reorder Buffer entry
    logic                             exception;
    exc_cause_t                       exc_cause;
    fp_flags_t                        fp_flags;
  } reorder_buffer_cdb_write_t;

  // Branch resolution update to Reorder Buffer, separate from the CDB. The
  // branch unit sends it when a branch/jump resolves in execute, and it is
  // what completes conditional branches and JALRs. Conditional branches never
  // write the CDB. A JALR broadcasts its link value on the CDB to wake its
  // dependents; the Reorder Buffer already holds that value from allocation.
  typedef struct packed {
    logic                             valid;         // Branch resolution valid
    logic [ReorderBufferTagWidth-1:0] tag;           // Reorder Buffer entry of the branch
    logic                             taken;         // Actual branch outcome
    logic [XLEN-1:0]                  target;        // Actual branch target
    // Misprediction flag, computed by the branch unit and not recomputed by
    // the Reorder Buffer, so there is one source of truth:
    // - taken != predicted_taken: direction misprediction
    // - taken && predicted_taken && target != predicted_target: target
    //   misprediction (the target compare is meaningful only when both are
    //   taken)
    logic                             mispredicted;
    // Completion: JALR and conditional branches are marked done=1 here
    // (JALR's value already holds link_addr from allocation; conditional
    // branches have no result value). JAL never sends this update
    // (branch_resolution holds valid low for it) because allocation already
    // recorded its outcome and target and marked it done.
  } reorder_buffer_branch_update_t;

  // Reorder Buffer commit signals. Exposes the serializing-instruction flags
  // so outer control logic can react.
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
    logic has_fp_flags;  // FP flags are valid (FP compute op, not FP load)
    // Branch misprediction recovery
    logic misprediction;  // Branch mispredicted (raw, not gated by early recovery)
    logic early_recovered;  // Misprediction already handled by early execute-time recovery
    logic has_checkpoint;
    logic [CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] redirect_pc;  // Correct target on misprediction
    // Branch info (for BTB update and RAS restore at commit)
    logic predicted_taken;  // Front-end predicted this control flow as taken
    logic branch_taken;  // Actual branch outcome
    logic [XLEN-1:0] branch_target;  // Actual branch target
    logic is_branch;  // Conditional branch or jump
    logic is_call;  // Call instruction (for RAS update)
    logic is_return;  // Return instruction (for RAS restore)
    logic is_jal;  // JAL instruction
    logic is_jalr;  // JALR instruction
    // CSR info (for commit-time CSR execution)
    logic [11:0] csr_addr;  // CSR address
    logic [2:0] csr_op;  // CSR operation funct3
    logic [XLEN-1:0] csr_write_data;  // CSR write data (rs1 or zero-ext imm)
    // Serializing instruction flags (for outer control logic)
    logic is_csr;  // CSR instruction (Reorder Buffer executes at commit)
    logic is_fence;  // FENCE (SQ must be drained)
    logic is_fence_i;  // FENCE.I (SQ drained, pipeline flush)
    logic is_wfi;  // WFI (stall until interrupt)
    logic is_mret;  // Any xRET (restore status, redirect to mepc/sepc/dpc)
    // Atomic operation flags (for memory ordering and reservation handling)
    logic is_amo;  // AMO instruction (executed at head with SQ empty)
    logic is_lr;  // LR (load-reserved, sets reservation)
    logic is_sc;  // SC (store-conditional, checks reservation)
    logic is_compressed;  // Compressed (16-bit) instruction (for BTB update)
  } reorder_buffer_commit_t;

  typedef struct packed {
    logic rob_empty;
    logic head_wait_total;
    logic head_wait_int;
    logic head_wait_branch;
    logic head_wait_mul;
    logic head_wait_mem_load;
    logic head_wait_mem_store;
    logic head_wait_mem_amo;
    logic head_wait_fp;
    logic head_wait_fmul;
    logic head_wait_fdiv;
    logic commit_blocked_csr;
    logic commit_blocked_fence;
    logic commit_blocked_wfi;
    logic commit_blocked_mret;
    logic commit_blocked_trap;
    // Fires on cycles where commit_en is high and the entry immediately
    // behind head is also valid+done. Upper bound on the fraction of cycles
    // in which a 2-wide commit would retire a second instruction.
    logic head_and_next_done;
    // Fires whenever the entry immediately behind head is valid+done and no
    // full flush is active, regardless of whether head is committing.
    // Subtracting head_and_next_done gives the cycles in which finished work
    // waits behind a head that is not committing.
    logic head_plus_one_done;
    // Fires when the full 2-wide commit gate would fire: commit_en high,
    // head+1 valid+done, and both head and head+1 pass the hazard
    // exclusions (serial ops, mispredicting/early-recovered branches on
    // head+1, FENCE.I, exceptions, AMO/LR/SC, and
    // head-mispredicting-branches). Tighter upper bound on
    // the actual widen-commit fire rate than head_and_next_done.
    logic commit_2_opportunity;
    // A 2-wide commit fired: commit_2_opportunity ANDed with the widen-commit
    // enable and cpu_ooo's slot-2 accept (i_widen_commit_ok), which is low
    // only while a Debug Mode single step is armed.
    logic commit_2_fire_actual;
    // Widen-commit blocker decomposition. These four events partition the
    // gap between head_and_next_done (commit firing and head+1 ready to
    // retire) and commit_2_opportunity (the 2-wide gate would fire). Each
    // event is gated on commit_en && head_next_valid_done, so their sum equals
    // (head_and_next_done - commit_2_opportunity).
    //
    //   HeadSerial      : head itself is a serial op, has an exception, or
    //                     is a mispredicted branch (head_ok_2wide = 0).
    //   NextSerial      : head is plain, head+1 is serial (CSR / fence /
    //                     fence_i / WFI / xRET / AMO / LR / SC /
    //                     exception), not a branch.
    //   NextBranchMispred : head+1 is a mispredicted branch, including one
    //                       that early recovery already handled.
    //   NextBranchCorrect : head+1 is a correctly-predicted branch that the
    //                       gate still refused. Correct branches can retire
    //                       as head+1, so a persistent nonzero count points
    //                       to a problem in slot-2 branch retirement.
    logic commit_2_blocked_head_serial;
    logic commit_2_blocked_next_serial;
    logic commit_2_blocked_next_branch_mispred;
    logic commit_2_blocked_next_branch_correct;
  } rob_perf_events_t;

  // ---------------------------------------------------------------------------
  // RAT Lookup Structure
  // ---------------------------------------------------------------------------

  // RAT lookup result (returned on source register read)
  typedef struct packed {
    logic                             renamed;  // Source is renamed (wait for Reorder Buffer tag)
    logic [ReorderBufferTagWidth-1:0] tag;      // Meaningful only if renamed; otherwise unspecified
    logic [FLEN-1:0]                  value;    // Value from regfile if not renamed
  } rat_lookup_t;

  // ---------------------------------------------------------------------------
  // Memory Operation Size Encoding
  // ---------------------------------------------------------------------------
  // Size encoding for memory operations.

  typedef enum logic [1:0] {
    MEM_SIZE_BYTE   = 2'b00,  // 8-bit
    MEM_SIZE_HALF   = 2'b01,  // 16-bit
    MEM_SIZE_WORD   = 2'b10,  // 32-bit
    MEM_SIZE_DOUBLE = 2'b11   // 64-bit (FLD/FSD and RV64 LD/SD/LR.D/SC.D/AMO*.D)
  } mem_size_e;

  // ---------------------------------------------------------------------------
  // Reservation Station Interface Structures
  // ---------------------------------------------------------------------------

  // RS dispatch request (from dispatch unit to RS)
  typedef struct packed {
    logic                             valid;                // Dispatch request valid
    rs_type_e                         rs_type;              // Which RS to dispatch to
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
    // Immediate.  Beyond the ordinary I/S/U immediates, dispatch also uses
    // this word for values ID precomputed from the PC so no station payload
    // needs the PC: the PC-relative target of a conditional branch (and of JAL,
    // which never reaches a station), PC + imm_u for AUIPC, the xtval of a
    // fetch-fault pseudo-op, and JALR's link address (its ALU result).
    logic [XLEN-1:0]                  imm;
    logic                             use_imm;
    // JALR's 12-bit I-immediate for the execute-time target add, since imm
    // carries its link address.  Unused by every other op.
    logic [11:0]                      jalr_imm;
    // FP rounding mode
    logic [2:0]                       rm;
    // Branch info (the precomputed target itself travels in imm, above)
    logic                             predicted_taken;
    logic [XLEN-1:0]                  predicted_target;     // BTB/RAS predicted target
    // Direct (non-JALR) branch-class ops: the selected prediction's target
    // equals the precomputed PC-relative target.  ID computes the compare, so
    // the resolving branch checks one bit instead of two XLEN targets; JALR
    // compares its computed target against predicted_target at execute.
    logic                             predicted_target_ok;
    // Original instruction size before RVC decompression (BTB training image
    // of an early-recovered branch).
    logic                             is_compressed;
    // Memory info
    logic                             is_fp_mem;
    logic                             mem_needs_lq;
    logic                             mem_needs_sq;
    mem_size_e                        mem_size;
    logic                             mem_signed;
    // CSR info
    logic [11:0]                      csr_addr;
    logic [4:0]                       csr_imm;
    // Program counter and pre-computed link address (PC+2 or PC+4).  The INT
    // station keeps them, with predicted_target, in its ROB-tag-indexed side
    // RAM instead of the per-entry payload; no station needs the PC for the
    // ALU because dispatch precomputes AUIPC and fetch-fault results into imm.
    logic [XLEN-1:0]                  pc;
    logic [XLEN-1:0]                  link_addr;
    // Early misprediction recovery: checkpoint info and branch type
    logic                             has_checkpoint;
    logic [CheckpointIdWidth-1:0]     checkpoint_id;
    logic                             is_call;
    logic                             is_return;
  } rs_dispatch_t;

  // RS issue signals (from RS to functional unit)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    instr_op_e                        op;
    logic [FLEN-1:0]                  src1_value;
    logic [FLEN-1:0]                  src2_value;
    logic [FLEN-1:0]                  src3_value;           // For FMA
    logic [XLEN-1:0]                  imm;                  // See rs_dispatch_t.imm
    logic                             use_imm;
    logic [11:0]                      jalr_imm;             // JALR's I-immediate
    logic [2:0]                       rm;                   // Rounding mode
    // Branch info.  The precomputed PC-relative target rides imm (see
    // rs_dispatch_t); predicted_target is meaningful only on the INT station's
    // port 0, which reads it from a ROB-tag-indexed side RAM behind its stage2
    // tag (JALR's execute-time target compare).  Direct branches carry the
    // ID-computed one-bit check instead.
    logic                             predicted_taken;
    logic [XLEN-1:0]                  predicted_target;
    logic                             predicted_target_ok;
    logic                             is_compressed;
    // Memory info (for MEM_RS)
    logic                             is_fp_mem;
    logic                             mem_needs_lq;
    logic                             mem_needs_sq;
    mem_size_e                        mem_size;
    logic                             mem_signed;
    // CSR info
    logic [11:0]                      csr_addr;
    logic [4:0]                       csr_imm;
    // Program counter and pre-computed link address (PC+2 or PC+4): valid only
    // on the INT station's port 0 (side RAM read behind the stage2 tag), for
    // early recovery's redirect and BTB image; zero on port 1 and on every
    // other station.  JALR's link result rides imm instead, so the side RAM
    // never feeds a CDB completion path.
    logic [XLEN-1:0]                  pc;
    logic [XLEN-1:0]                  link_addr;
    // Early misprediction recovery: checkpoint info and branch type
    logic                             has_checkpoint;
    logic [CheckpointIdWidth-1:0]     checkpoint_id;
    logic                             is_call;
    logic                             is_return;
    // Pre-decoded branch class, computed at dispatch and carried through the
    // RS payload + stage2 register. branch_resolution consumes these instead
    // of re-decoding instr_op_e in the issue cycle, which keeps that decode
    // off the stage2_op -> branch_mispredicted -> early-mispredict-capture
    // path.
    logic                             is_branch_class;      // BEQ..BGEU | JAL | JALR
    logic                             is_jal;
    logic                             is_jalr;
    branch_taken_op_e                 branch_op;
  } rs_issue_t;

  // ---------------------------------------------------------------------------
  // Load Queue Interface Structures
  // ---------------------------------------------------------------------------

  // LQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic                             is_fp;
    mem_size_e                        size;
    logic                             sign_ext;
    logic                             is_lr;     // Load-reserved
    logic                             is_amo;    // AMO instruction
    instr_op_e                        amo_op;    // AMO operation type
  } lq_alloc_req_t;

  // LQ address update (from address calculation). Under active data
  // translation `address` is the PA and arrives two registered cycles
  // later (the data MMU's capture + registered-resolution pipe; the
  // pre-issue look-ahead shifts with it). A translation-stage fault
  // (fault_kind != DFAULT_NONE) parks the VA in `address` instead: the
  // entry never launches and completes through the misalign bypass with the
  // kind-derived cause and the VA as xtval. With translation inactive,
  // `address` is the raw AGU value in the same cycle and fault_kind is
  // always DFAULT_NONE (the LQ's own staged misalign/PMA checks raise the
  // faults).
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic [XLEN-1:0]                  address;
    logic                             is_mmio;
    data_fault_kind_e                 fault_kind;
    logic [XLEN-1:0]                  amo_rs2;     // AMO rs2 operand value
  } lq_addr_update_t;

  // ---------------------------------------------------------------------------
  // Store Queue Interface Structures
  // ---------------------------------------------------------------------------

  // SQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                             valid;
    logic [ReorderBufferTagWidth-1:0] rob_tag;
    logic                             is_fp;
    mem_size_e                        size;
    logic                             is_sc;       // Store-conditional
    logic                             addr_valid;  // Address already known at dispatch
    logic [XLEN-1:0]                  address;
    logic                             is_mmio;
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

  // ---------------------------------------------------------------------------
  // Dispatch Interface Structures
  // ---------------------------------------------------------------------------

  // Dispatch status (from dispatch to front-end)
  typedef struct packed {
    logic dispatch_valid;
    logic stall;                  // Stall decode (Reorder Buffer/RS/LQ/SQ full)
    logic reorder_buffer_full;
    logic int_rs_full;
    logic mul_rs_full;
    logic mem_rs_full;
    logic fp_rs_full;
    logic fmul_rs_full;
    logic fdiv_rs_full;
    logic lq_full;
    logic sq_full;
    logic checkpoint_full;        // All checkpoints in use (branch)
    // 2-wide width-funnel profiling taps (perf counters only).  The block_*
    // bits fire only when slot-2 alone holds the bundle (slot-1 could fire),
    // attributing those whole-bundle stall cycles to slot-2 causes; several
    // can fire together when more than one room check fails.
    logic slot2_present;          // Real slot-2 instruction at the dispatch input
    logic slot2_fp_serialized;    // Slot-2 targets an FP RS (FP-compute never dispatches as slot-2)
    logic slot2_block_s1_branch;  // Slot-2 refused: slot-1 is a branch/jump (bundle terminates)
    logic slot2_block_rob_full2;  // Slot-2 refused: no ROB room for 2
    logic slot2_block_rs_full2;   // Slot-2 refused: slot-2's RS room check failed
    logic slot2_block_lsq_full2;  // Slot-2 refused: LQ/SQ room check for slot-2 failed
    logic slot2_block_ckpt;       // Slot-2 refused: no checkpoint for a slot-2 branch
  } dispatch_status_t;

  // IF-stage 2-wide delivery events (perf counters only).  deliver1/deliver2
  // pulse exactly once per accepted IF->PD handoff (stall-qualified inside
  // if_stage); the kill_* causes are mutually exclusive and meaningful only
  // on deliver1 && !deliver2 cycles, replaying the stall-captured aligner
  // classification so they describe the bundle PD received. A handoff held
  // one-wide by a pending slot-1 prediction can have no cause set.
  // slot2_pred_taken is an independent event pulse, not a kill cause.
  typedef struct packed {
    logic deliver1;  // IF handed PD a real slot-1 instruction
    logic deliver2;  // ...and a real slot-2 instruction with it
    logic kill_s1_native_ctrl;  // No slot-2: slot-1 is native 32-bit control flow
    logic kill_s1_native_serialize;  // No slot-2: slot-1 is a native serializing-class op
    logic kill_slot1_ctrl;  // No slot-2: slot-1 is compressed control flow
    logic kill_class;  // No slot-2: slot-2 starts a serialize/FP-compute class op
    logic kill_window_limit;  // No slot-2: 32-bit slot-2 at NEXT_HI exceeds the 64-bit window
    logic kill_transient;  // No slot-2: aligner buffer/BRAM transient state
    logic slot2_pred_taken;  // Slot-2 BTB predicted-taken accepted (the 1-bubble redirect)
  } if_width_events_t;

  // ---------------------------------------------------------------------------
  // Instruction Routing Table
  // ---------------------------------------------------------------------------
  // RS assignment for each instruction operation.
  // Guarded from synthesis because Yosys cannot resolve enum values inside
  // package functions.  Modules that need these during synthesis must inline
  // equivalent logic using fully-qualified riscv_pkg:: enum references.
`ifndef SYNTHESIS

  function automatic rs_type_e get_rs_type(instr_op_e op);
    case (op)
      // Integer ALU operations -> INT_RS
      ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LUI, AUIPC, JALR,
      BEQ, BNE, BLT, BGE, BLTU, BGEU,
      // Zba/Zbb/Zbs/Zbkb/Zicond -> INT_RS (all 1-cycle ALU ops)
      SH1ADD, SH2ADD, SH3ADD,
      BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI,
      ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MAX, MAXU, MIN, MINU,
      SEXT_B, SEXT_H, ROL, ROR, RORI, ORC_B, REV8,
      CZERO_EQZ, CZERO_NEZ,
      PACK, PACKH, BREV8,
      // RV64 W-form ALU ops -> INT_RS
      ADDIW, SLLIW, SRLIW, SRAIW, ADDW, SUBW, SLLW, SRLW, SRAW,
      ADD_UW, SH1ADD_UW, SH2ADD_UW, SH3ADD_UW, SLLI_UW,
      ROLW, RORW, RORIW, CLZW, CTZW, CPOPW, PACKW,
      // CSR instructions -> INT_RS (execute at Reorder Buffer head)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // Privileged (exceptions) -> INT_RS
      ECALL, EBREAK, FETCH_FAULT, FETCH_PAGE_FAULT:
      get_rs_type = RS_INT;

      // Multiply/divide -> MUL_RS
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU, MULW, DIVW, DIVUW, REMW, REMUW:
      get_rs_type = RS_MUL;

      // Memory operations -> MEM_RS (both INT and FP)
      LB, LH, LW, LBU, LHU, SB, SH, SW,
      LWU, LD, SD,
      FLW, FSW, FLD, FSD,
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      LR_D, SC_D,
      AMOSWAP_D, AMOADD_D, AMOXOR_D, AMOAND_D, AMOOR_D,
      AMOMIN_D, AMOMAX_D, AMOMINU_D, AMOMAXU_D,
      FENCE, FENCE_I, SFENCE_VMA:
      get_rs_type = RS_MEM;

      // FP add/sub/cmp/cvt/classify/sgnj -> FP_RS
      FADD_S, FSUB_S, FADD_D, FSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      FCVT_W_S, FCVT_WU_S, FCVT_S_W, FCVT_S_WU,
      FCVT_W_D, FCVT_WU_D, FCVT_D_W, FCVT_D_WU,
      FCVT_L_S, FCVT_LU_S, FCVT_S_L, FCVT_S_LU,
      FCVT_L_D, FCVT_LU_D, FCVT_D_L, FCVT_D_LU,
      FCVT_S_D, FCVT_D_S,
      FMV_X_W, FMV_W_X, FMV_X_D, FMV_D_X,
      FCLASS_S, FCLASS_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D:
      get_rs_type = RS_FP;

      // FP multiply/FMA -> FMUL_RS (3 sources for FMA)
      FMUL_S, FMUL_D, FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      get_rs_type = RS_FMUL;

      // FP divide/sqrt -> FDIV_RS (long latency)
      FDIV_S, FSQRT_S, FDIV_D, FSQRT_D: get_rs_type = RS_FDIV;

      // Instructions that don't need RS (dispatch directly to Reorder Buffer).
      // SRET and DRET ride the MRET machinery.
      JAL, WFI, MRET, SRET, DRET, PAUSE: get_rs_type = RS_NONE;

      default: get_rs_type = RS_INT;  // Default fallback
    endcase
  endfunction

  // Instructions with an integer destination (rd).
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
      CZERO_EQZ, CZERO_NEZ, PACK, PACKH, BREV8,
      // RV64 W-form ALU ops
      ADDIW, SLLIW, SRLIW, SRAIW, ADDW, SUBW, SLLW, SRLW, SRAW,
      ADD_UW, SH1ADD_UW, SH2ADD_UW, SH3ADD_UW, SLLI_UW,
      ROLW, RORW, RORIW, CLZW, CTZW, CPOPW, PACKW,
      // M-extension
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU, MULW, DIVW, DIVUW, REMW, REMUW,
      // Integer loads
      LB, LH, LW, LBU, LHU, LWU, LD,
      // Atomics (return old value to rd)
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      LR_D, SC_D,
      AMOSWAP_D, AMOADD_D, AMOXOR_D, AMOAND_D, AMOOR_D,
      AMOMIN_D, AMOMAX_D, AMOMINU_D, AMOMAXU_D,
      // CSR (return old CSR value to rd)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // FP compare -> INT rd
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP classify -> INT rd
      FCLASS_S, FCLASS_D,
      // FP to INT conversion -> INT rd
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D, FCVT_L_S, FCVT_LU_S, FCVT_L_D, FCVT_LU_D,
      // FP to INT bit move -> INT rd
      FMV_X_W, FMV_X_D:
      has_int_dest = 1'b1;

      default: has_int_dest = 1'b0;
    endcase
  endfunction

  // Instructions with an FP destination (fd).
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
      FCVT_S_W, FCVT_S_WU, FCVT_D_W, FCVT_D_WU, FCVT_S_L, FCVT_S_LU, FCVT_D_L, FCVT_D_LU,
      // FP format conversion
      FCVT_S_D, FCVT_D_S,
      // INT to FP bit move -> FP fd
      FMV_W_X, FMV_D_X:
      has_fp_dest = 1'b1;

      default: has_fp_dest = 1'b0;
    endcase
  endfunction

  // Instructions that read FP rs1.
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
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D, FCVT_L_S, FCVT_LU_S, FCVT_L_D, FCVT_LU_D,
      // FP to INT bit move (fs1) -> INT rd
      FMV_X_W, FMV_X_D,
      // FP format conversion
      FCVT_S_D, FCVT_D_S:
      uses_fp_rs1 = 1'b1;

      default: uses_fp_rs1 = 1'b0;
    endcase
  endfunction

  // Instructions that read FP rs2.
  function automatic logic uses_fp_rs2(instr_op_e op);
    case (op)
      // FP compute ops with 2+ sources
      FADD_S, FSUB_S, FMUL_S, FDIV_S,
      FADD_D, FSUB_D, FMUL_D, FDIV_D,
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

  // Instructions that read FP rs3 (FMA only).
  function automatic logic uses_fp_rs3(instr_op_e op);
    case (op)
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      uses_fp_rs3 = 1'b1;

      default: uses_fp_rs3 = 1'b0;
    endcase
  endfunction

  // Instructions that read integer rs1: most do, except pure FP compute
  // (which reads FP rs1), LUI/AUIPC/JAL, the system ops (ECALL/EBREAK/
  // FENCE/FENCE.I/WFI/xRET/SFENCE.VMA/PAUSE), the CSR immediate forms (the
  // rs1 field holds an immediate), and the ILLEGAL/fetch-fault markers.
  function automatic logic uses_int_rs1(instr_op_e op);
    if (uses_fp_rs1(op)) begin
      uses_int_rs1 = 1'b0;
    end else begin
      case (op)
        LUI, AUIPC, JAL,
        ECALL, EBREAK,
        FENCE, FENCE_I,
        WFI, MRET, SRET, DRET, SFENCE_VMA, PAUSE,
        CSRRWI, CSRRSI, CSRRCI,
        ILLEGAL, FETCH_FAULT, FETCH_PAGE_FAULT:
        uses_int_rs1 = 1'b0;
        default: uses_int_rs1 = 1'b1;
      endcase
    end
  endfunction

  // Instructions that read integer rs2: branches, R-type integer ALU,
  // integer stores, AMO/SC. FP stores (FSW/FSD) read FP rs2 for their data
  // instead.
  function automatic logic uses_int_rs2(instr_op_e op);
    if (uses_fp_rs2(op)) begin
      uses_int_rs2 = 1'b0;
    end else begin
      case (op)
        // Conditional branches
        BEQ, BNE, BLT, BGE, BLTU, BGEU,
        // R-type integer ALU (have rs2)
        ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
        // M-extension
        MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU, MULW, DIVW, DIVUW, REMW, REMUW,
        // B-extension with rs2
        SH1ADD, SH2ADD, SH3ADD,
        BSET, BCLR, BINV, BEXT,
        ANDN, ORN, XNOR,
        MAX, MAXU, MIN, MINU,
        ROL, ROR,
        CZERO_EQZ, CZERO_NEZ,
        PACK, PACKH,
        // RV64 W-form R-type ops
        ADDW, SUBW, SLLW, SRLW, SRAW, ADD_UW, SH1ADD_UW, SH2ADD_UW, SH3ADD_UW, ROLW, RORW, PACKW,
        // Integer stores
        SB, SH, SW, SD,
        // Atomics (rs2 is source value for AMO/SC)
        SC_W,
        AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
        AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
        SC_D,
        AMOSWAP_D, AMOADD_D, AMOXOR_D, AMOAND_D, AMOOR_D,
        AMOMIN_D, AMOMAX_D, AMOMINU_D, AMOMAXU_D:
        uses_int_rs2 = 1'b1;
        default: uses_int_rs2 = 1'b0;
      endcase
    end
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
  // Checks only the opcode; the caller must also check rd.
  function automatic logic is_potential_call_op(instr_op_e op);
    is_potential_call_op = (op == JAL) || (op == JALR);
  endfunction

  // Is this a return instruction? (pops from RAS)
  // Checks only the opcode; the caller must also check rs1/rd/imm.
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

`endif  // SYNTHESIS

  // ---------------------------------------------------------------------------
  // cpu_ooo-internal recovery capture structs
  // ---------------------------------------------------------------------------
  // Shared between cpu_ooo and its branch-recovery / commit / from_ex_comb glue
  // submodules. Kept here (rather than a separate cpu_ooo_pkg) because yosys's
  // read_verilog -sv frontend cannot resolve cross-package `riscv_pkg::Member`
  // references inside another package's typedef.

  // Captured at the cycle a mispredicted branch is detected; drives the
  // commit-time recovery redirect, BTB update, and RAS restore.
  typedef struct packed {
    logic [ReorderBufferTagWidth-1:0] tag;
    logic has_checkpoint;
    logic [CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] redirect_pc;
    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_call;
    logic is_return;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } mispredict_commit_capture_t;

  // Captured for a correctly-predicted branch commit; drives the BTB update
  // (no PC redirect) using registered commit data.
  typedef struct packed {
    logic [ReorderBufferTagWidth-1:0] tag;
    logic [CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } correct_branch_commit_capture_t;


  // Reorder-buffer serializing-instruction FSM state, shared by
  // reorder_buffer and its rob_serializer submodule.
  typedef enum logic [2:0] {
    SERIAL_IDLE,                  // No serializing instruction at head
    SERIAL_WAIT_SQ,               // Waiting for SQ to drain (FENCE/FENCE.I)
    SERIAL_CSR_EXEC,              // CSR executing
    SERIAL_MRET_EXEC,             // xRET (MRET, SRET, DRET) executing
    SERIAL_WFI_WAIT,              // WFI waiting for interrupt
    SERIAL_TRAP_WAIT,             // Exception waiting for trap unit
    SERIAL_FENCE_I_SYNC,          // FENCE.I/SFENCE.VMA waiting for cache/TLB sync
    SERIAL_CSR_TRANSLATION_DRAIN  // Translation-class CSR completed its
                                  // handshake and is waiting for committed
                                  // stores to drain before retirement
  } serial_state_e;
endpackage : riscv_pkg
