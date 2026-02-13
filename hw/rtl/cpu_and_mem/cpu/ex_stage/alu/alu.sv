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
 * Arithmetic Logic Unit (ALU) - Core execution unit for RISC-V processor.
 * Implements all RV32IMAB arithmetic, logical, and shift operations including the
 * base integer ISA, M-extension for multiply/divide, A-extension atomic operations,
 * and B-extension (Zba, Zbb, Zbs), plus Zicond and Zbkb. B = Zba + Zbb + Zbs.
 * The ALU handles immediate and register-based operations, computes branch addresses
 * for JAL/JALR, and generates upper immediate values for LUI/AUIPC. It instantiates
 * separate multiplier and divider units for M-extension operations which require
 * multiple cycles. The module manages stall signals for multi-cycle operations and
 * controls the register file write enable based on instruction validity and operation
 * completion. Special cases for divide-by-zero and signed overflow are handled
 * according to RISC-V specifications.
 *
 * Bit Manipulation Functions:
 * ===========================
 *   CLZ, CTZ, CPOP helper functions are defined in riscv_pkg.sv (Section 11).
 *   These use tree-based parallel structures for optimal timing.
 */
module alu #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,
    input riscv_pkg::instr_t i_instruction,
    input riscv_pkg::instr_op_e i_instruction_operation,
    input logic [XLEN-1:0] i_operand_a,  // First operand (typically rs1 value)
    input logic [XLEN-1:0] i_operand_b,  // Second operand (typically rs2 value or immediate)
    input logic [XLEN-1:0] i_program_counter,
    input logic [31:0] i_immediate_u_type,  // Upper immediate for LUI/AUIPC
    input logic [31:0] i_immediate_i_type,  // I-type immediate
    input logic i_is_multiply_operation,
    input logic i_is_divide_operation,
    input logic [XLEN-1:0] i_link_address,  // Pre-computed link address (PC+2 or PC+4)
    // CSR interface (Zicsr extension)
    input logic [XLEN-1:0] i_csr_read_data,  // CSR read value from CSR file
    output logic [XLEN-1:0] o_result,
    output logic o_write_enable,  // Whether to write result to register file
    output logic o_stall_for_multiply_divide,  // Pipeline stall needed for multi-cycle ops
    // TIMING OPTIMIZATION: Signal from multiplier indicating completion next cycle.
    // Used by hazard unit to break critical path (register this to predict unstall).
    output logic o_multiply_completing_next_cycle
);

  // Multiplier signals (M extension)
  logic signed [XLEN:0] multiplier_input_a, multiplier_input_b;  // 33-bit signed inputs
  logic [2*XLEN-1:0] multiplier_result;  // 64-bit product
  logic multiplier_valid_input, multiplier_valid_output;
  logic multiplier_valid_input_registered;  // Tracks if multiply is in progress

  // Divider/remainder signals (M extension)
  logic [XLEN-1:0] divider_quotient_result, divider_remainder_result;
  logic divider_is_signed_operation;  // Signed vs unsigned division
  logic divider_valid_input, divider_valid_output;
  logic divider_valid_input_registered;  // Tracks if divide is in progress
  logic [XLEN-1:0] operand_b;
  logic [XLEN:0] difference;
  logic sltu;

  // Multiplier unit - 4-cycle tiled DSP pipeline (33x33 signed -> 64-bit)
  multiplier multiplier_inst (
      .i_clk,
      .i_rst,
      .i_operand_a(multiplier_input_a),
      .i_operand_b(multiplier_input_b),
      .i_valid_input(multiplier_valid_input),
      .o_product_result(multiplier_result),
      .o_valid_output(multiplier_valid_output),
      .o_completing_next_cycle(o_multiply_completing_next_cycle)
  );
  // Track multiply operation state: set when operation starts, clear when done
  always_ff @(posedge i_clk)
    if (i_rst) multiplier_valid_input_registered <= 1'b0;
    else if (multiplier_valid_input) multiplier_valid_input_registered <= 1'b1;
    else if (multiplier_valid_output) multiplier_valid_input_registered <= 1'b0;

  // Divider unit - computes quotient and remainder over multiple cycles
  divider divider_inst (
      .i_clk,
      .i_rst,
      .i_valid_input(divider_valid_input),
      .i_is_signed_operation(divider_is_signed_operation),
      .i_dividend(i_operand_a),
      .i_divisor(i_operand_b),
      .o_valid_output(divider_valid_output),
      .o_quotient(divider_quotient_result),
      .o_remainder(divider_remainder_result)
  );
  // Track divide operation state: set when operation starts, clear when done
  always_ff @(posedge i_clk)
    if (i_rst) divider_valid_input_registered <= 1'b0;
    else if (divider_valid_input) divider_valid_input_registered <= 1'b1;
    else if (divider_valid_output) divider_valid_input_registered <= 1'b0;

  function automatic logic op_is_imm_not_reg(input logic [6:0] opcode);
    logic [6:0] unique_opcode_bits;
    unique_opcode_bits = riscv_pkg::OPC_OP_IMM ^ riscv_pkg::OPC_OP;
    op_is_imm_not_reg = (unique_opcode_bits & opcode) ==
                        (unique_opcode_bits & riscv_pkg::OPC_OP_IMM);
  endfunction

  assign operand_b = op_is_imm_not_reg(
      i_instruction.opcode
  ) ? XLEN'(signed'(i_immediate_i_type)) : i_operand_b;
  assign difference = {i_operand_a[XLEN-1], i_operand_a} - {operand_b[XLEN-1], operand_b};
  assign sltu = i_operand_a[XLEN-1] && !(operand_b[XLEN-1]) ? '0 :
                operand_b[XLEN-1] && !(i_operand_a[XLEN-1]) ? '1 :
                difference[XLEN];

  // Main ALU operation selection and result computation (combinational logic)
  always_comb begin
    o_result = '0;
    o_write_enable = 1'b1;  // Most operations write to register file
    multiplier_valid_input = 1'b0;
    multiplier_input_a = {1'b0, i_operand_a};  // Default: zero-extend to 33 bits (unsigned)
    multiplier_input_b = {1'b0, i_operand_b};  // Default: zero-extend to 33 bits (unsigned)
    divider_valid_input = 1'b0;
    divider_is_signed_operation = 1'b1;  // Default: signed division
    unique case (i_instruction_operation)
      // Base ISA R-type (register-register) arithmetic and logical operations
      riscv_pkg::ADD: o_result = i_operand_a + operand_b;
      riscv_pkg::SUB: o_result = difference[XLEN-1:0];
      riscv_pkg::AND: o_result = i_operand_a & operand_b;
      riscv_pkg::OR: o_result = i_operand_a | operand_b;
      riscv_pkg::XOR: o_result = i_operand_a ^ operand_b;
      riscv_pkg::SLL: o_result = i_operand_a << i_operand_b[4:0];  // Shift left logical
      riscv_pkg::SRL: o_result = i_operand_a >> i_operand_b[4:0];  // Shift right logical
      riscv_pkg::SRA:
      o_result = $signed(i_operand_a) >>> i_operand_b[4:0];  // Shift right arithmetic (sign-extend)
      riscv_pkg::SLT: o_result = 32'(difference[XLEN]);  // Set if less than (signed)
      riscv_pkg::SLTU: o_result = 32'(sltu);  // Set if less than (unsigned)
      // Base ISA I-type (immediate) operations
      riscv_pkg::ADDI: o_result = i_operand_a + operand_b;
      riscv_pkg::ANDI: o_result = i_operand_a & operand_b;
      riscv_pkg::ORI: o_result = i_operand_a | operand_b;
      riscv_pkg::XORI: o_result = i_operand_a ^ operand_b;
      riscv_pkg::SLTI: o_result = 32'(difference[XLEN]);  // Set if less than (signed)
      riscv_pkg::SLTIU: o_result = 32'(sltu);  // Set if less than (unsigned)
      // Shift immediate operations - shift amount is in rs2 field of instruction
      riscv_pkg::SLLI: o_result = i_operand_a << i_instruction.source_reg_2;
      riscv_pkg::SRLI: o_result = i_operand_a >> i_instruction.source_reg_2;
      riscv_pkg::SRAI: o_result = $signed(i_operand_a) >>> i_instruction.source_reg_2;
      // Base ISA U-type (upper immediate) operations
      // Load upper immediate
      riscv_pkg::LUI: o_result = XLEN'(signed'(i_immediate_u_type));
      // Add upper immediate to PC
      riscv_pkg::AUIPC: o_result = i_program_counter + XLEN'(signed'(i_immediate_u_type));
      // Jump operations - save return address for function calls
      // Use pre-computed link address from IF stage (PC+2 for compressed, PC+4 for 32-bit)
      riscv_pkg::JAL: o_result = i_link_address;
      riscv_pkg::JALR: o_result = i_link_address;
      // M-extension multiply operations (1-cycle registered, requires stall)
      riscv_pkg::MUL: begin
        // Start multiply if not already in progress; use lower 32 bits of result
        multiplier_valid_input = ~multiplier_valid_input_registered;
        o_result = multiplier_result[31:0];  // Lower word of product (from registered output)
        o_write_enable = multiplier_valid_output;  // Only write when result is ready
      end
      riscv_pkg::MULH: begin
        // Multiply high (signed x signed) - returns upper 32 bits
        multiplier_valid_input = ~multiplier_valid_input_registered;
        multiplier_input_a = {i_operand_a[XLEN-1], i_operand_a};  // Sign-extend both operands
        multiplier_input_b = {i_operand_b[XLEN-1], i_operand_b};
        o_result = multiplier_result[2*XLEN-1:XLEN];  // Upper word of product
        o_write_enable = multiplier_valid_output;
      end
      riscv_pkg::MULHSU: begin
        // Multiply high (signed x unsigned) - returns upper 32 bits
        multiplier_valid_input = ~multiplier_valid_input_registered;
        multiplier_input_a = {i_operand_a[XLEN-1], i_operand_a};  // Sign-extend first operand only
        // multiplier_input_b already zero-extended by default
        o_result = multiplier_result[2*XLEN-1:XLEN];
        o_write_enable = multiplier_valid_output;
      end
      riscv_pkg::MULHU: begin
        // Multiply high (unsigned x unsigned) - returns upper 32 bits
        multiplier_valid_input = ~multiplier_valid_input_registered;
        // Both operands already zero-extended by default
        o_result = multiplier_result[2*XLEN-1:XLEN];
        o_write_enable = multiplier_valid_output;
      end
      // M-extension signed division (multi-cycle, requires stalling)
      riscv_pkg::DIV: begin
        divider_valid_input = ~divider_valid_input_registered;
        divider_is_signed_operation = 1'b1;
        // Handle special cases per RISC-V spec
        if (i_operand_b == 0) o_result = riscv_pkg::NegativeOne;  // Divide by zero: return -1
        // Overflow: most negative number divided by -1
        else if ((i_operand_a == riscv_pkg::SignedInt32Min) &&
                 (i_operand_b == riscv_pkg::NegativeOne))
          o_result = riscv_pkg::SignedInt32Min;  // Return most negative number
        else o_result = divider_quotient_result;
        o_write_enable = divider_valid_output;
      end
      // M-extension unsigned division
      riscv_pkg::DIVU: begin
        divider_valid_input = ~divider_valid_input_registered;
        divider_is_signed_operation = 1'b0;
        if (i_operand_b == 0)
          o_result = riscv_pkg::UnsignedInt32Max;  // Divide by zero: return max unsigned
        else o_result = divider_quotient_result;
        o_write_enable = divider_valid_output;
      end
      // M-extension signed remainder (modulo)
      riscv_pkg::REM: begin
        divider_valid_input = ~divider_valid_input_registered;
        divider_is_signed_operation = 1'b1;
        if (i_operand_b == 0)
          o_result = i_operand_a;  // Remainder of divide by zero: return dividend
        else if ((i_operand_a == riscv_pkg::SignedInt32Min) &&
                 (i_operand_b == riscv_pkg::NegativeOne))
          o_result = 32'h0000_0000;  // Overflow case: remainder is 0
        else o_result = divider_remainder_result;
        o_write_enable = divider_valid_output;
      end
      // M-extension unsigned remainder
      riscv_pkg::REMU: begin
        divider_valid_input = ~divider_valid_input_registered;
        divider_is_signed_operation = 1'b0;
        if (i_operand_b == 0)
          o_result = i_operand_a;  // Remainder of divide by zero: return dividend
        else o_result = divider_remainder_result;
        o_write_enable = divider_valid_output;
      end
      // Zicsr extension - CSR read/modify/write operations
      // All CSR instructions return the old CSR value to rd
      // Write operations are handled in the CSR file (read-only CSRs ignore writes)
      riscv_pkg::CSRRW,
      riscv_pkg::CSRRS,
      riscv_pkg::CSRRC,
      riscv_pkg::CSRRWI,
      riscv_pkg::CSRRSI,
      riscv_pkg::CSRRCI: begin
        o_result = i_csr_read_data;
        o_write_enable = 1'b1;
      end
      // Zba extension - address generation (shift-and-add)
      riscv_pkg::SH1ADD: o_result = (i_operand_a << 1) + i_operand_b;
      riscv_pkg::SH2ADD: o_result = (i_operand_a << 2) + i_operand_b;
      riscv_pkg::SH3ADD: o_result = (i_operand_a << 3) + i_operand_b;
      // Zbs extension - single-bit operations (register form)
      riscv_pkg::BSET: o_result = i_operand_a | (32'd1 << i_operand_b[4:0]);
      riscv_pkg::BCLR: o_result = i_operand_a & ~(32'd1 << i_operand_b[4:0]);
      riscv_pkg::BINV: o_result = i_operand_a ^ (32'd1 << i_operand_b[4:0]);
      riscv_pkg::BEXT: o_result = {31'd0, 1'((i_operand_a >> i_operand_b[4:0]) & 32'd1)};
      // Zbs extension - single-bit operations (immediate form, shamt in source_reg_2 field)
      riscv_pkg::BSETI: o_result = i_operand_a | (32'd1 << i_instruction.source_reg_2);
      riscv_pkg::BCLRI: o_result = i_operand_a & ~(32'd1 << i_instruction.source_reg_2);
      riscv_pkg::BINVI: o_result = i_operand_a ^ (32'd1 << i_instruction.source_reg_2);
      riscv_pkg::BEXTI: o_result = {31'd0, 1'((i_operand_a >> i_instruction.source_reg_2) & 32'd1)};
      // Zbb extension - logical with complement
      riscv_pkg::ANDN: o_result = i_operand_a & ~i_operand_b;
      riscv_pkg::ORN: o_result = i_operand_a | ~i_operand_b;
      riscv_pkg::XNOR: o_result = ~(i_operand_a ^ i_operand_b);
      // Zbb extension - min/max comparisons
      riscv_pkg::MAX:
      o_result = ($signed(i_operand_a) > $signed(i_operand_b)) ? i_operand_a : i_operand_b;
      riscv_pkg::MAXU: o_result = (i_operand_a > i_operand_b) ? i_operand_a : i_operand_b;
      riscv_pkg::MIN:
      o_result = ($signed(i_operand_a) < $signed(i_operand_b)) ? i_operand_a : i_operand_b;
      riscv_pkg::MINU: o_result = (i_operand_a < i_operand_b) ? i_operand_a : i_operand_b;
      // Zbb extension - rotations using funnel shifter (single barrel shifter, no OR)
      // ROR: {a,a} >> shamt gives lower 32 bits as rotated result
      riscv_pkg::ROR: o_result = XLEN'({i_operand_a, i_operand_a} >> i_operand_b[4:0]);
      // ROL: equivalent to ROR by (32 - shamt)
      riscv_pkg::ROL:
      o_result = XLEN'({i_operand_a, i_operand_a} >> (6'd32 - {1'b0, i_operand_b[4:0]}));
      // RORI: rotate right immediate using funnel shifter
      riscv_pkg::RORI: o_result = XLEN'({i_operand_a, i_operand_a} >> i_instruction.source_reg_2);
      // Zbb extension - count operations (functions defined in riscv_pkg)
      riscv_pkg::CLZ: o_result = riscv_pkg::clz32(i_operand_a);
      riscv_pkg::CTZ: o_result = riscv_pkg::ctz32(i_operand_a);
      riscv_pkg::CPOP: o_result = riscv_pkg::cpop32(i_operand_a);
      // Zbb extension - sign extension
      riscv_pkg::SEXT_B: o_result = {{24{i_operand_a[7]}}, i_operand_a[7:0]};
      riscv_pkg::SEXT_H: o_result = {{16{i_operand_a[15]}}, i_operand_a[15:0]};
      // Zbb extension - byte operations
      riscv_pkg::ORC_B:
      o_result = {
        {8{|i_operand_a[31:24]}},
        {8{|i_operand_a[23:16]}},
        {8{|i_operand_a[15:8]}},
        {8{|i_operand_a[7:0]}}
      };
      riscv_pkg::REV8:
      o_result = {i_operand_a[7:0], i_operand_a[15:8], i_operand_a[23:16], i_operand_a[31:24]};
      // Zicond extension - conditional zero
      riscv_pkg::CZERO_EQZ: o_result = (i_operand_b == 0) ? 32'd0 : i_operand_a;
      riscv_pkg::CZERO_NEZ: o_result = (i_operand_b != 0) ? 32'd0 : i_operand_a;
      // Zbkb extension - bit manipulation for crypto
      // PACK: pack low halfwords from rs1 and rs2 (zext.h is pack with rs2=0)
      riscv_pkg::PACK: o_result = {i_operand_b[15:0], i_operand_a[15:0]};
      // PACKH: pack low bytes from rs1 and rs2
      riscv_pkg::PACKH: o_result = {16'd0, i_operand_b[7:0], i_operand_a[7:0]};
      // Zbkb extension - bit permutation operations (use helper functions from riscv_pkg)
      riscv_pkg::BREV8: o_result = riscv_pkg::brev8(i_operand_a);  // Bit-reverse each byte
      riscv_pkg::ZIP: o_result = riscv_pkg::zip32(i_operand_a);  // Bit interleave (RV32)
      riscv_pkg::UNZIP: o_result = riscv_pkg::unzip32(i_operand_a);  // Bit deinterleave (RV32)
      // Zihintpause - PAUSE is a hint, treated as NOP (no register write)
      riscv_pkg::PAUSE: o_write_enable = 1'b0;
      // Default: invalid instruction - don't write to register file
      default: o_write_enable = 1'b0;
    endcase
  end

  // Stall pipeline if multiply or divide operation is in progress but not yet complete
  assign o_stall_for_multiply_divide = (i_is_multiply_operation & ~multiplier_valid_output) |
                                       (i_is_divide_operation & ~divider_valid_output);

endmodule : alu
