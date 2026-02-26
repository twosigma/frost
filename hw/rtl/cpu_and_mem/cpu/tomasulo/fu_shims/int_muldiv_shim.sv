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
 * Integer MUL/DIV Shim
 *
 * Translates rs_issue_t from the MUL reservation station into the
 * multiplier and divider native port interfaces, instantiates both FUs,
 * and packs results into fu_complete_t for CDB adapters / arbiter.
 *
 * Signal flow:  MUL_RS -> int_muldiv_shim -> multiplier -> fu_complete_t (slot 1)
 *                                         -> divider    -> fu_complete_t (slot 2)
 *
 * Op decode:
 *   MUL, MULH, MULHSU, MULHU -> multiplier path (4-cycle latency)
 *   DIV, DIVU, REM, REMU     -> divider path    (17-cycle latency)
 *
 * Each path supports one in-flight operation. Flush tracking suppresses
 * results from operations that were in-flight when a flush occurred.
 * The FUs have no flush input, so they run to completion; the shim gates
 * the output valid.
 */
module int_muldiv_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From MUL reservation station (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completions to CDB adapters
    output riscv_pkg::fu_complete_t o_mul_fu_complete,  // -> adapter -> arbiter slot 1
    output riscv_pkg::fu_complete_t o_div_fu_complete,  // -> adapter -> arbiter slot 2

    // Back-pressure: either FU in-flight prevents new issue
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial) — suppress in-flight results younger than tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);

  // ---------------------------------------------------------------------------
  // Op decode (combinational)
  // ---------------------------------------------------------------------------
  logic is_mul;
  logic is_div;

  always_comb begin
    case (i_rs_issue.op)
      riscv_pkg::MUL, riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU: begin
        is_mul = 1'b1;
        is_div = 1'b0;
      end
      riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU: begin
        is_mul = 1'b0;
        is_div = 1'b1;
      end
      default: begin
        is_mul = 1'b0;
        is_div = 1'b0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Age comparison for partial flush
  // ---------------------------------------------------------------------------
  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;

  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age;
    logic [TagW:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // In-flight + flush tracking
  // ---------------------------------------------------------------------------
  logic mul_in_flight;
  logic mul_flushed;
  logic div_in_flight;
  logic div_flushed;

  // Forward declarations for valid signals from FUs
  logic multiplier_valid_input;
  logic multiplier_valid_output;
  logic divider_valid_input;
  logic divider_valid_output;

  // Flush conditions: full flush or partial flush hitting the in-flight/launching tag.
  // "inflight" checks the latched tag; "launching" checks the RS issue tag for
  // the same-cycle launch+flush race (in_flight is still 0 on launch cycle).
  logic mul_flush_inflight;
  logic mul_flush_launching;
  logic div_flush_inflight;
  logic div_flush_launching;

  assign mul_flush_inflight = mul_in_flight & (i_flush | (i_flush_en & is_younger(
      mul_tag_reg, i_flush_tag, i_rob_head_tag
  )));
  assign mul_flush_launching = multiplier_valid_input & (i_flush | (i_flush_en & is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  )));
  assign div_flush_inflight = div_in_flight & (i_flush | (i_flush_en & is_younger(
      div_tag_reg, i_flush_tag, i_rob_head_tag
  )));
  assign div_flush_launching = divider_valid_input & (i_flush | (i_flush_en & is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  )));

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      mul_in_flight <= 1'b0;
      mul_flushed   <= 1'b0;
    end else if (multiplier_valid_output) begin
      mul_in_flight <= 1'b0;
      mul_flushed   <= 1'b0;
    end else begin
      if (multiplier_valid_input) mul_in_flight <= 1'b1;
      if (mul_flush_inflight || mul_flush_launching) mul_flushed <= 1'b1;
    end
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      div_in_flight <= 1'b0;
      div_flushed   <= 1'b0;
    end else if (divider_valid_output) begin
      div_in_flight <= 1'b0;
      div_flushed   <= 1'b0;
    end else begin
      if (divider_valid_input) div_in_flight <= 1'b1;
      if (div_flush_inflight || div_flush_launching) div_flushed <= 1'b1;
    end
  end

  assign o_fu_busy = mul_in_flight | div_in_flight;

  // ---------------------------------------------------------------------------
  // Multiplier path
  // ---------------------------------------------------------------------------
  // Sign-extend operands to 33 bits based on op
  logic signed [32:0] mul_operand_a;
  logic signed [32:0] mul_operand_b;

  always_comb begin
    case (i_rs_issue.op)
      riscv_pkg::MULH: begin
        // Sign-extend both
        mul_operand_a = {i_rs_issue.src1_value[31], i_rs_issue.src1_value[31:0]};
        mul_operand_b = {i_rs_issue.src2_value[31], i_rs_issue.src2_value[31:0]};
      end
      riscv_pkg::MULHSU: begin
        // Sign-extend rs1, zero-extend rs2
        mul_operand_a = {i_rs_issue.src1_value[31], i_rs_issue.src1_value[31:0]};
        mul_operand_b = {1'b0, i_rs_issue.src2_value[31:0]};
      end
      default: begin
        // MUL, MULHU: zero-extend both
        mul_operand_a = {1'b0, i_rs_issue.src1_value[31:0]};
        mul_operand_b = {1'b0, i_rs_issue.src2_value[31:0]};
      end
    endcase
  end

  assign multiplier_valid_input = is_mul & i_rs_issue.valid & ~mul_in_flight;

  logic [63:0] mul_product;
  logic        mul_completing_next_cycle;  // unused

  multiplier u_multiplier (
      .i_clk                  (i_clk),
      .i_rst                  (~i_rst_n),                  // active-high reset
      .i_operand_a            (mul_operand_a),
      .i_operand_b            (mul_operand_b),
      .i_valid_input          (multiplier_valid_input),
      .o_product_result       (mul_product),
      .o_valid_output         (multiplier_valid_output),
      .o_completing_next_cycle(mul_completing_next_cycle)
  );

  // Latch ROB tag + op on fire
  logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] mul_tag_reg;
  riscv_pkg::instr_op_e                                        mul_op_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      mul_tag_reg <= '0;
      mul_op_reg  <= riscv_pkg::instr_op_e'('0);
    end else if (multiplier_valid_input) begin
      mul_tag_reg <= i_rs_issue.rob_tag;
      mul_op_reg  <= i_rs_issue.op;
    end
  end

  // Result selection: MUL -> low 32, MULH/MULHSU/MULHU -> high 32
  logic [31:0] mul_result_32;
  always_comb begin
    case (mul_op_reg)
      riscv_pkg::MUL: mul_result_32 = mul_product[31:0];
      default:        mul_result_32 = mul_product[63:32];
    endcase
  end

  // Pack MUL output
  always_comb begin
    o_mul_fu_complete.valid     = multiplier_valid_output & ~mul_flushed;
    o_mul_fu_complete.tag       = mul_tag_reg;
    o_mul_fu_complete.value     = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, mul_result_32};
    o_mul_fu_complete.exception = 1'b0;
    o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
  end

  // ---------------------------------------------------------------------------
  // Divider path
  // ---------------------------------------------------------------------------
  logic div_is_signed;
  assign div_is_signed = (i_rs_issue.op == riscv_pkg::DIV) || (i_rs_issue.op == riscv_pkg::REM);

  assign divider_valid_input = is_div & i_rs_issue.valid & ~div_in_flight;

  logic [31:0] div_quotient;
  logic [31:0] div_remainder;

  divider #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_divider (
      .i_clk                (i_clk),
      .i_rst                (~i_rst_n),                                    // active-high reset
      .i_valid_input        (divider_valid_input),
      .i_is_signed_operation(div_is_signed),
      .i_dividend           (i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]),
      .i_divisor            (i_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .o_valid_output       (divider_valid_output),
      .o_quotient           (div_quotient),
      .o_remainder          (div_remainder)
  );

  // Latch ROB tag + op on fire
  logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] div_tag_reg;
  riscv_pkg::instr_op_e                                        div_op_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      div_tag_reg <= '0;
      div_op_reg  <= riscv_pkg::instr_op_e'('0);
    end else if (divider_valid_input) begin
      div_tag_reg <= i_rs_issue.rob_tag;
      div_op_reg  <= i_rs_issue.op;
    end
  end

  // Result selection: DIV/DIVU -> quotient, REM/REMU -> remainder
  logic [31:0] div_result_32;
  always_comb begin
    case (div_op_reg)
      riscv_pkg::REM, riscv_pkg::REMU: div_result_32 = div_remainder;
      default:                         div_result_32 = div_quotient;
    endcase
  end

  // Pack DIV output
  always_comb begin
    o_div_fu_complete.valid     = divider_valid_output & ~div_flushed;
    o_div_fu_complete.tag       = div_tag_reg;
    o_div_fu_complete.value     = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, div_result_32};
    o_div_fu_complete.exception = 1'b0;
    o_div_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_div_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
  end

endmodule : int_muldiv_shim
