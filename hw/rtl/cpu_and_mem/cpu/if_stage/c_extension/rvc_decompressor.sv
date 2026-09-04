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
  RISC-V Compressed (RVC) instruction decompressor: expands a 16-bit
  compressed instruction into its 32-bit equivalent.

  Bits [1:0] select the quadrant:
  - Quadrant 0 (00): Register-relative (x8-x15) loads/stores, C.ADDI4SPN
  - Quadrant 1 (01): Control flow, arithmetic, immediates
  - Quadrant 2 (10): Register ops, stack-pointer-relative ops
  - Quadrant 3 (11): Not compressed (32-bit instruction)

  Compressed registers (3-bit) map to x8-x15: reg' = {2'b01, 3-bit-value}

  This is the RV64C table. RV64C reinterprets several RV32C slots: C.JAL
  becomes C.ADDIW (rd!=0), C.FLW/C.FSW become C.LD/C.SD, C.FLWSP/C.FSWSP
  become C.LDSP (rd!=0) / C.SDSP, the bit12=1 arithmetic slots are
  C.SUBW/C.ADDW, and the base shifts take 6-bit shamts with bit 12 as
  shamt[5]. C.FLD/C.FSD/C.FLDSP/C.FSDSP keep their RV32C meanings.

  For timing, the expansion is a quadrant/funct3 case tree that computes
  only the selected instruction, rather than a bank of parallel expanders
  feeding a wide OR tree at the output. Expanded instruction bits 8, 9, 15,
  20, 25, and 27, plus the illegal flag, also have exact standalone cofactors.
  Slot 2 consumes those copies so its critical captures do not inherit
  unrelated logic from the full 32-bit case tree.
*/
module rvc_decompressor (
    input  logic [15:0] i_instr_compressed,
    // Exact predecode of i_instr_compressed[11:7] == x2. Fixed high-half
    // slot-2 candidates receive this from the instruction-memory fast replica;
    // registered/local candidates compute the same predicate directly.
    input  logic        i_rd_is_x2,
    output logic [31:0] o_instr_expanded,
    output logic        o_instr_expanded_bit8_fast,
    output logic        o_instr_expanded_bit15_fast,
    // Pair ordering is {expanded[20], expanded[9]}.
    output logic [ 1:0] o_instr_expanded_bits20_9_fast,
    // Pair ordering is {expanded[27], expanded[25]}.
    output logic [ 1:0] o_instr_expanded_bits27_25_fast,
    output logic        o_is_compressed,
    output logic        o_illegal,
    output logic        o_illegal_fast
);

  // Extract common fields from compressed instruction
  logic [1:0] quadrant;
  logic [2:0] funct3;

  assign quadrant = i_instr_compressed[1:0];
  assign funct3 = i_instr_compressed[15:13];

  // Instruction is compressed if bits [1:0] != 2'b11
  assign o_is_compressed = (quadrant != 2'b11);

  // Standard RISC-V opcodes for expansion
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

  // ===========================================================================
  // Pre-compute register fields (used across multiple instructions)
  // ===========================================================================
  logic [4:0] rd_full, rs1_full, rs2_full;  // Full 5-bit register specifiers
  logic [4:0] rd_prime, rs1_prime, rs2_prime;  // Compressed reg -> x8-x15

  assign rd_full   = i_instr_compressed[11:7];
  assign rs1_full  = i_instr_compressed[11:7];  // Same bits for C2 quadrant
  assign rs2_full  = i_instr_compressed[6:2];
  assign rd_prime  = {2'b01, i_instr_compressed[4:2]};  // x8-x15
  assign rs1_prime = {2'b01, i_instr_compressed[9:7]};  // x8-x15
  assign rs2_prime = {2'b01, i_instr_compressed[4:2]};  // x8-x15

  // ===========================================================================
  // Pre-compute all immediates in parallel
  // ===========================================================================

  // C.ADDI4SPN: nzuimm[5:4|9:6|2|3] from bits [12:5], scaled by 4
  logic [11:0] imm_addi4spn;
  assign imm_addi4spn = {
    2'b0,
    i_instr_compressed[10:7],
    i_instr_compressed[12:11],
    i_instr_compressed[5],
    i_instr_compressed[6],
    2'b00
  };

  // C.LW/C.SW: uimm[5:3|2|6] from bits [12:10,6,5], scaled by 4
  logic [11:0] imm_lw_sw;
  assign imm_lw_sw = {
    5'b0, i_instr_compressed[5], i_instr_compressed[12:10], i_instr_compressed[6], 2'b00
  };

  // C.FLD/C.FSD and C.LD/C.SD: uimm[5:3|7:6] from bits [12:10,6:5], scaled by 8
  logic [11:0] imm_ld_sd;
  assign imm_ld_sd = {4'b0, i_instr_compressed[6:5], i_instr_compressed[12:10], 3'b000};

  // C.ADDI/C.LI/C.ANDI: 6-bit sign-extended immediate
  logic [11:0] imm_ci;
  assign imm_ci = {{6{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};

  // C.ADDI16SP: nzimm[9|4|6|8:7|5] from bits [12,6:2], scaled by 16
  logic [11:0] imm_addi16sp;
  assign imm_addi16sp = {
    {2{i_instr_compressed[12]}},
    i_instr_compressed[12],
    i_instr_compressed[4:3],
    i_instr_compressed[5],
    i_instr_compressed[2],
    i_instr_compressed[6],
    4'b0000
  };

  // C.LUI: 6-bit immediate for upper bits (sign-extended)
  logic [19:0] imm_lui;
  assign imm_lui = {{14{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};

  // C.J: 12-bit jump offset (RV64C has no C.JAL; that slot is C.ADDIW)
  logic [11:0] imm_j;
  assign imm_j = {
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

  // C.BEQZ/C.BNEZ: 9-bit branch offset
  logic [8:0] imm_b;
  assign imm_b = {
    i_instr_compressed[12],
    i_instr_compressed[6:5],
    i_instr_compressed[2],
    i_instr_compressed[11:10],
    i_instr_compressed[4:3],
    1'b0
  };

  // C.LWSP: uimm[5|4:2|7:6] from bits [12,6:2], scaled by 4
  logic [11:0] imm_lwsp;
  assign imm_lwsp = {
    4'b0, i_instr_compressed[3:2], i_instr_compressed[12], i_instr_compressed[6:4], 2'b00
  };

  // C.FLDSP/C.LDSP: uimm[5:3|8:6] from bits [4:2,12,6:5], scaled by 8
  logic [11:0] imm_ldsp;
  assign imm_ldsp = {
    3'b0, i_instr_compressed[4:2], i_instr_compressed[12], i_instr_compressed[6:5], 3'b000
  };

  // C.SWSP: uimm[5:2|7:6] from bits [12:7], scaled by 4
  logic [7:0] imm_swsp;
  assign imm_swsp = {i_instr_compressed[8:7], i_instr_compressed[12:9], 2'b00};

  // C.FSDSP/C.SDSP: uimm[5:3|8:6] from bits [9:7,12:10], scaled by 8
  logic [11:0] imm_sdsp;
  assign imm_sdsp = {3'b0, i_instr_compressed[9:7], i_instr_compressed[12:10], 3'b000};

  // Shift amount: 6-bit, with shamt[5] carried in bit 12
  logic [5:0] shamt6;
  assign shamt6 = {i_instr_compressed[12], i_instr_compressed[6:2]};

  // Exact bit slice of o_instr_expanded[8] for fully known synthesizable 0/1
  // inputs, expressed independently of the full-width expansion below. This
  // output deliberately defines behavior for every binary
  // {parcel, i_rd_is_x2} combination, including an inconsistent external
  // rd==x2 predicate. In the C.ADDI16SP/C.LUI slot, C.ADDI16SP writes x2 and
  // therefore contributes a one while C.LUI contributes rd_full[1].
  //
  // The slot-2 path consumes this shallow result beside the other 31 bits. It
  // removes a false dependency through the synthesized wide case/mux network
  // without changing the decompressor interface's functional domain.
  always_comb begin
    unique case (quadrant)
      2'b00: begin
        // C.ADDI4SPN and the three load forms write rd'; stores and the
        // reserved funct3=100 slot have instruction bit 8 clear.
        o_instr_expanded_bit8_fast = !funct3[2] && i_instr_compressed[3];
      end
      2'b01: begin
        unique case (funct3)
          3'b000, 3'b001, 3'b010: o_instr_expanded_bit8_fast = i_instr_compressed[8];
          3'b011: o_instr_expanded_bit8_fast = i_rd_is_x2 || i_instr_compressed[8];
          3'b100:
          // With bit 12 set, arithmetic sub-ops [6:5]=10/11 are reserved and
          // retain the expansion's all-zero default. Every legal member of
          // this group writes rs1', whose bit 1 is parcel bit 8.
          o_instr_expanded_bit8_fast = i_instr_compressed[8] &&
              !(i_instr_compressed[12] && (&i_instr_compressed[11:10]) &&
                i_instr_compressed[6]);
          3'b101: o_instr_expanded_bit8_fast = 1'b0;
          default: o_instr_expanded_bit8_fast = i_instr_compressed[3];
        endcase
      end
      2'b10: begin
        if (!funct3[2]) begin
          o_instr_expanded_bit8_fast = i_instr_compressed[8];
        end else if (funct3 == 3'b100) begin
          // C.MV/C.ADD retain rd_full[1]. C.JR/C.JALR/C.EBREAK all
          // have rs2==0 and write an rd whose bit 1 is clear.
          o_instr_expanded_bit8_fast = i_instr_compressed[8] && (|i_instr_compressed[6:2]);
        end else begin
          o_instr_expanded_bit8_fast = 1'b0;
        end
      end
      default: o_instr_expanded_bit8_fast = i_instr_compressed[8];
    endcase
  end

  // Exact standalone cofactors of o_instr_expanded[20] and [9]. These are the
  // final residual slot-2 rs2[0] and non-source payload endpoints after the
  // source-hot and earlier bit-specific bypasses. Pairing the two outputs is
  // only an interface convenience; each case bit remains an independent
  // one-bit function for synthesis.
  always_comb begin
    unique case (quadrant)
      2'b00: begin
        unique case (funct3)
          3'b000, 3'b001, 3'b010, 3'b011:
          o_instr_expanded_bits20_9_fast = {1'b0, i_instr_compressed[4]};
          3'b101, 3'b111: o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], 1'b0};
          3'b110: o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], i_instr_compressed[6]};
          default: o_instr_expanded_bits20_9_fast = 2'b00;
        endcase
      end
      2'b01: begin
        unique case (funct3)
          3'b000, 3'b001, 3'b010:
          o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], i_instr_compressed[9]};
          3'b011:
          o_instr_expanded_bits20_9_fast = {
            !i_rd_is_x2 && i_instr_compressed[12], !i_rd_is_x2 && i_instr_compressed[9]
          };
          3'b100:
          o_instr_expanded_bits20_9_fast =
              (i_instr_compressed[12] && (&i_instr_compressed[11:10]) &&
               i_instr_compressed[6]) ? 2'b00 :
              {i_instr_compressed[2], i_instr_compressed[9]};
          3'b101: o_instr_expanded_bits20_9_fast = {i_instr_compressed[12], 1'b0};
          default: o_instr_expanded_bits20_9_fast = {1'b0, i_instr_compressed[4]};
        endcase
      end
      2'b10: begin
        unique case (funct3)
          3'b000: o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], i_instr_compressed[9]};
          3'b001, 3'b010, 3'b011: o_instr_expanded_bits20_9_fast = {1'b0, i_instr_compressed[9]};
          3'b100:
          o_instr_expanded_bits20_9_fast = {
            i_instr_compressed[2] ||
                (i_instr_compressed[12] && (rs2_full == 5'd0) && (rd_full == 5'd0)),
            i_instr_compressed[9] && (rs2_full != 5'd0)
          };
          3'b110: o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], i_instr_compressed[9]};
          default: o_instr_expanded_bits20_9_fast = {i_instr_compressed[2], 1'b0};
        endcase
      end
      default: o_instr_expanded_bits20_9_fast = {1'b0, i_instr_compressed[9]};
    endcase
  end

  // Exact standalone cofactor of o_instr_expanded[15]. This is rs1[0] for
  // instruction formats that consume rs1, and is the remaining slot-2 source
  // bit not carried by the instruction-memory source-hot sideband. As above,
  // define every binary {parcel, i_rd_is_x2} combination so the splice is
  // equivalent to the full decompressor without an environmental assumption.
  always_comb begin
    unique case (quadrant)
      2'b00:   o_instr_expanded_bit15_fast = (|funct3[1:0]) && i_instr_compressed[7];
      2'b01: begin
        unique case (funct3)
          3'b000, 3'b001, 3'b110, 3'b111: o_instr_expanded_bit15_fast = i_instr_compressed[7];
          3'b010: o_instr_expanded_bit15_fast = 1'b0;
          3'b011: o_instr_expanded_bit15_fast = !i_rd_is_x2 && i_instr_compressed[5];
          3'b100:
          o_instr_expanded_bit15_fast = i_instr_compressed[7] &&
              !(i_instr_compressed[12] && (&i_instr_compressed[11:10]) &&
                i_instr_compressed[6]);
          default: o_instr_expanded_bit15_fast = i_instr_compressed[12];
        endcase
      end
      2'b10: begin
        unique case (funct3)
          3'b000: o_instr_expanded_bit15_fast = i_instr_compressed[7];
          3'b100:
          o_instr_expanded_bit15_fast = i_instr_compressed[7] &&
              (i_instr_compressed[12] || !(|i_instr_compressed[6:2]));
          default: o_instr_expanded_bit15_fast = 1'b0;
        endcase
      end
      default: o_instr_expanded_bit15_fast = i_instr_compressed[15];
    endcase
  end

  // Exact standalone cofactor of o_illegal. Keeping the legality decoder out
  // of the instruction-expansion case tree avoids dragging the wide expansion
  // cone into slot 2's illegal-instruction capture. This deliberately matches
  // the canonical output for every binary input, including an i_rd_is_x2 value
  // inconsistent with the parcel's rd field.
  always_comb begin
    o_illegal_fast = 1'b0;
    unique case (quadrant)
      2'b00: begin
        unique case (funct3)
          3'b000:  o_illegal_fast = !(|i_instr_compressed[12:5]);
          3'b100:  o_illegal_fast = 1'b1;
          default: o_illegal_fast = 1'b0;
        endcase
      end
      2'b01: begin
        unique case (funct3)
          3'b001: o_illegal_fast = !(|i_instr_compressed[11:7]);
          3'b011: o_illegal_fast = !(|{i_instr_compressed[12], i_instr_compressed[6:2]});
          3'b100:
          o_illegal_fast = i_instr_compressed[12] && (&i_instr_compressed[11:10]) &&
              i_instr_compressed[6];
          default: o_illegal_fast = 1'b0;
        endcase
      end
      2'b10: begin
        unique case (funct3)
          3'b010, 3'b011: o_illegal_fast = !(|i_instr_compressed[11:7]);
          3'b100:
          o_illegal_fast = !i_instr_compressed[12] && !(|i_instr_compressed[11:7]) &&
              !(|i_instr_compressed[6:2]);
          default: o_illegal_fast = 1'b0;
        endcase
      end
      default: o_illegal_fast = 1'b0;
    endcase
  end

  // Exact standalone cofactors of o_instr_expanded[27] and [25]. Those are
  // packed into PD's registered non-source payload at indices 17 and 15. The
  // shallow pair bypasses the full decompressor mux tree while retaining its
  // behavior for reserved and externally inconsistent predicate inputs.
  always_comb begin
    unique case (quadrant)
      2'b00: begin
        unique case (funct3)
          3'b000: o_instr_expanded_bits27_25_fast = {i_instr_compressed[8], i_instr_compressed[12]};
          3'b001, 3'b011, 3'b101, 3'b111:
          o_instr_expanded_bits27_25_fast = {i_instr_compressed[6], i_instr_compressed[12]};
          3'b010, 3'b110: o_instr_expanded_bits27_25_fast = {1'b0, i_instr_compressed[12]};
          default: o_instr_expanded_bits27_25_fast = 2'b00;
        endcase
      end
      2'b01: begin
        unique case (funct3)
          3'b000, 3'b001, 3'b010: o_instr_expanded_bits27_25_fast = {2{i_instr_compressed[12]}};
          3'b011:
          o_instr_expanded_bits27_25_fast = i_rd_is_x2 ?
              {i_instr_compressed[3], i_instr_compressed[2]} :
              {2{i_instr_compressed[12]}};
          3'b100:
          o_instr_expanded_bits27_25_fast = {
            i_instr_compressed[12] && i_instr_compressed[11] && !i_instr_compressed[10],
            i_instr_compressed[12] && !(i_instr_compressed[11] && i_instr_compressed[10])
          };
          default: o_instr_expanded_bits27_25_fast = {i_instr_compressed[6], i_instr_compressed[2]};
        endcase
      end
      2'b10: begin
        unique case (funct3)
          3'b000: o_instr_expanded_bits27_25_fast = {1'b0, i_instr_compressed[12]};
          3'b001, 3'b010, 3'b011:
          o_instr_expanded_bits27_25_fast = {i_instr_compressed[3], i_instr_compressed[12]};
          3'b100: o_instr_expanded_bits27_25_fast = 2'b00;
          default:
          o_instr_expanded_bits27_25_fast = {i_instr_compressed[8], i_instr_compressed[12]};
        endcase
      end
      default: o_instr_expanded_bits27_25_fast = 2'b00;
    endcase
  end

  // ===========================================================================
  // Instruction Expansion (compute only selected instruction)
  // ===========================================================================
  always_comb begin
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
          3'b001: o_instr_expanded = {imm_ld_sd, rs1_prime, 3'b011, rd_prime, OpcLoadFp};  // C.FLD
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
  end

endmodule : rvc_decompressor
