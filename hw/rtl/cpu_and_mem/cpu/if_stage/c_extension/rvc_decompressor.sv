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
  RISC-V Compressed (RVC) instruction decompressor.
  Expands 16-bit compressed instructions into their 32-bit equivalents.

  The C extension uses three quadrants based on bits [1:0]:
  - Quadrant 0 (00): Stack-relative loads/stores, wide immediates
  - Quadrant 1 (01): Control flow, arithmetic, immediates
  - Quadrant 2 (10): Register ops, stack-pointer-relative ops
  - Quadrant 3 (11): Not compressed (32-bit instruction)

  Compressed registers (3-bit) map to x8-x15: reg' = {2'b01, 3-bit-value}

  Timing optimization: Computes only the selected expansion via a
  quadrant/funct3 case tree to reduce parallel logic and wide OR trees.
*/
module rvc_decompressor (
    input  logic [15:0] i_instr_compressed,
    output logic [31:0] o_instr_expanded,
    output logic        o_is_compressed,
    output logic        o_illegal
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
  // Pre-compute ALL immediates in parallel
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

  // C.FLD/C.FSD: uimm[5:3|7:6] from bits [12:10,6:5], scaled by 8
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

  // C.J/C.JAL: 12-bit jump offset
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

  // C.FLDSP: uimm[5:3|8:6] from bits [4:2,12,6:5], scaled by 8
  logic [11:0] imm_ldsp;
  assign imm_ldsp = {
    3'b0, i_instr_compressed[4:2], i_instr_compressed[12], i_instr_compressed[6:5], 3'b000
  };

  // C.SWSP: uimm[5:2|7:6] from bits [12:7], scaled by 4
  logic [7:0] imm_swsp;
  assign imm_swsp = {i_instr_compressed[8:7], i_instr_compressed[12:9], 2'b00};

  // C.FSDSP: uimm[5:3|8:6] from bits [9:7,12:10], scaled by 8
  logic [11:0] imm_sdsp;
  assign imm_sdsp = {3'b0, i_instr_compressed[9:7], i_instr_compressed[12:10], 3'b000};

  // Shift amount (5-bit for RV32)
  logic [4:0] shamt;
  assign shamt = i_instr_compressed[6:2];

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
          3'b011: o_instr_expanded = {imm_lw_sw, rs1_prime, 3'b010, rd_prime, OpcLoadFp};  // C.FLW
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
            imm_lw_sw[11:5], rs2_prime, rs1_prime, 3'b010, imm_lw_sw[4:0], OpcStoreFp
          };  // C.FSW
          default: o_illegal = 1'b1;  // Reserved encoding
        endcase
      end

      // -----------------------------------------------------------------------
      // Quadrant 1 (01)
      // -----------------------------------------------------------------------
      2'b01: begin
        unique case (funct3)
          3'b000: o_instr_expanded = {imm_ci, rd_full, 3'b000, rd_full, OpcOpImm};  // C.ADDI/NOP
          3'b001:
          o_instr_expanded = {imm_j[11], imm_j[10:1], imm_j[11], {8{imm_j[11]}}, 5'd1, OpcJal};
          3'b010: o_instr_expanded = {imm_ci, 5'd0, 3'b000, rd_full, OpcOpImm};  // C.LI
          3'b011: begin
            if (rd_full == 5'd2) begin  // C.ADDI16SP
              o_instr_expanded = {imm_addi16sp, 5'd2, 3'b000, 5'd2, OpcOpImm};
              if (imm_addi16sp == 12'b0) o_illegal = 1'b1;
            end else if (rd_full != 5'd0) begin  // C.LUI
              o_instr_expanded = {imm_lui, rd_full, OpcLui};
              if ({i_instr_compressed[12], i_instr_compressed[6:2]} == 6'b0) o_illegal = 1'b1;
            end else begin
              o_illegal = 1'b1;  // rd=0 is illegal
            end
          end
          3'b100: begin
            unique case (i_instr_compressed[11:10])
              2'b00: begin  // C.SRLI
                o_instr_expanded = {7'b0000000, shamt, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
                if (i_instr_compressed[12]) o_illegal = 1'b1;
              end
              2'b01: begin  // C.SRAI
                o_instr_expanded = {7'b0100000, shamt, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
                if (i_instr_compressed[12]) o_illegal = 1'b1;
              end
              2'b10: begin  // C.ANDI
                o_instr_expanded = {imm_ci, rs1_prime, 3'b111, rs1_prime, OpcOpImm};
              end
              2'b11: begin  // C.SUB/C.XOR/C.OR/C.AND (or reserved when bit12=1)
                if (i_instr_compressed[12]) begin
                  o_illegal = 1'b1;  // RV64-only op encodings
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
          3'b000: begin  // C.SLLI
            o_instr_expanded = {7'b0000000, shamt, rd_full, 3'b001, rd_full, OpcOpImm};
            if (i_instr_compressed[12] || (rd_full == 5'd0)) o_illegal = 1'b1;
          end
          3'b010: begin  // C.LWSP
            o_instr_expanded = {imm_lwsp, 5'd2, 3'b010, rd_full, OpcLoad};
            if (rd_full == 5'd0) o_illegal = 1'b1;
          end
          3'b001: begin  // C.FLDSP
            o_instr_expanded = {imm_ldsp, 5'd2, 3'b011, rd_full, OpcLoadFp};
          end
          3'b011: begin  // C.FLWSP
            o_instr_expanded = {imm_lwsp, 5'd2, 3'b010, rd_full, OpcLoadFp};
          end
          3'b100: begin
            if (!i_instr_compressed[12]) begin
              if (rs2_full == 5'd0) begin  // C.JR
                o_instr_expanded = {12'b0, rs1_full, 3'b000, 5'd0, OpcJalr};
                if (rd_full == 5'd0) o_illegal = 1'b1;
              end else begin  // C.MV
                o_instr_expanded = {7'b0, rs2_full, 5'd0, 3'b000, rd_full, OpcOp};
                if (rd_full == 5'd0) o_illegal = 1'b1;
              end
            end else begin
              if (rs2_full == 5'd0) begin
                if (rd_full == 5'd0) begin
                  o_instr_expanded = 32'h0010_0073;  // C.EBREAK
                end else begin
                  o_instr_expanded = {12'b0, rs1_full, 3'b000, 5'd1, OpcJalr};  // C.JALR
                end
              end else begin
                o_instr_expanded = {7'b0, rs2_full, rd_full, 3'b000, rd_full, OpcOp};  // C.ADD
                if (rd_full == 5'd0) o_illegal = 1'b1;
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
          3'b111:
          o_instr_expanded = {
            4'b0, imm_swsp[7:5], rs2_full, 5'd2, 3'b010, imm_swsp[4:0], OpcStoreFp
          };  // C.FSWSP
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
