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
  Floating-point sign injection operations (FSGNJ, FSGNJN, FSGNJX).
  These operations manipulate the sign bit of the first operand based on
  the second operand's sign bit.

  FSGNJ.{S,D}:  result = {fs2[sign], fs1[mag]}      - Copy fs2's sign to fs1
  FSGNJN.{S,D}: result = {~fs2[sign], fs1[mag]}     - Copy negated fs2's sign to fs1
  FSGNJX.{S,D}: result = {fs1[sign] ^ fs2[sign], fs1[mag]} - XOR signs

  Note: These operations are also used for:
    - FMV.S (move): FSGNJ.S with rs1 = rs2 (assembler pseudo-instruction)
    - FNEG.S (negate): FSGNJN.S with rs1 = rs2
    - FABS.S (absolute): FSGNJX.S with rs1 = rs2

  Latency: 2 cycles (registered output to break timing path through FP forwarding)
*/
module fp_sign_inject #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                                i_clk,
    input  logic                                i_rst,
    input  logic                                i_valid,      // Start operation
    input  logic                 [FP_WIDTH-1:0] i_operand_a,  // fs1
    input  logic                 [FP_WIDTH-1:0] i_operand_b,  // fs2
    input  riscv_pkg::instr_op_e                i_operation,
    output logic                 [FP_WIDTH-1:0] o_result,
    output logic                                o_valid,      // Result ready
    output logic                                o_busy        // Operation in progress
);

  // Combinational result computation
  logic sign_a, sign_b;
  logic [FP_WIDTH-2:0] magnitude_a;
  logic result_sign;
  logic [FP_WIDTH-1:0] result_comb;
  logic is_sign_inject_op;

  assign sign_a = i_operand_a[FP_WIDTH-1];
  assign sign_b = i_operand_b[FP_WIDTH-1];
  assign magnitude_a = i_operand_a[FP_WIDTH-2:0];

  always_comb begin
    result_sign = sign_a;  // Default
    is_sign_inject_op = 1'b1;

    unique case (i_operation)
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJ_D:   result_sign = sign_b;  // Copy fs2's sign
      riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJN_D: result_sign = ~sign_b;  // Copy negated fs2's sign
      riscv_pkg::FSGNJX_S, riscv_pkg::FSGNJX_D: result_sign = sign_a ^ sign_b;  // XOR signs
      default: begin
        result_sign = sign_a;
        is_sign_inject_op = 1'b0;
      end
    endcase
  end

  assign result_comb = {result_sign, magnitude_a};

  // Pipeline register - adds 1 cycle latency
  logic started;
  logic [FP_WIDTH-1:0] result_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      started <= 1'b0;
      result_reg <= '0;
    end else if (i_valid && is_sign_inject_op && !started) begin
      // Capture result on start
      started <= 1'b1;
      result_reg <= result_comb;
    end else if (started) begin
      // Output cycle - clear started
      started <= 1'b0;
    end
  end

  // Output valid one cycle after start
  // Busy only on the starting cycle (i_valid=1), not on output cycle (started=1)
  assign o_valid  = started;
  assign o_result = result_reg;
  assign o_busy   = i_valid;

endmodule : fp_sign_inject
