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
 * FP Multiply Shim (CDB Slot 5, FMUL_RS)
 *
 * Translates rs_issue_t from FMUL_RS into FPU subunit native ports.
 *
 * Subunits:
 *   - fpu_mult_unit: FMUL_S/D (~9 cycles)
 *   - fpu_fma_unit:  FMADD/FMSUB/FNMADD/FNMSUB S/D (~10 cycles)
 *
 * FMA operand mapping: a=src1, b=src2, c=src3
 *   FMADD:  negate_product=0, negate_c=0  → a*b + c
 *   FMSUB:  negate_product=0, negate_c=1  → a*b - c
 *   FNMSUB: negate_product=1, negate_c=0  → -(a*b) + c = c - a*b
 *   FNMADD: negate_product=1, negate_c=1  → -(a*b) - c
 */
module fp_mul_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FMUL_RS (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // Back-pressure
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial)
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);

  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;

  // ===========================================================================
  // Age comparison for partial flush
  // ===========================================================================
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

  // ===========================================================================
  // Op decode
  // ===========================================================================
  logic use_mult, use_fma;
  logic op_is_double;
  logic negate_product, negate_c;

  always_comb begin
    use_mult       = 1'b0;
    use_fma        = 1'b0;
    op_is_double   = 1'b0;
    negate_product = 1'b0;
    negate_c       = 1'b0;

    case (i_rs_issue.op)
      riscv_pkg::FMUL_S: use_mult = 1'b1;
      riscv_pkg::FMUL_D: begin
        use_mult = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FMADD_S: use_fma = 1'b1;
      riscv_pkg::FMADD_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FMSUB_S: begin
        use_fma  = 1'b1;
        negate_c = 1'b1;
      end
      riscv_pkg::FMSUB_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_c = 1'b1;
      end

      riscv_pkg::FNMSUB_S: begin
        use_fma = 1'b1;
        negate_product = 1'b1;
      end
      riscv_pkg::FNMSUB_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_product = 1'b1;
      end

      riscv_pkg::FNMADD_S: begin
        use_fma = 1'b1;
        negate_product = 1'b1;
        negate_c = 1'b1;
      end
      riscv_pkg::FNMADD_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_product = 1'b1;
        negate_c = 1'b1;
      end

      default: ;
    endcase
  end

  // Operand extraction
  wire [31:0] src1_s = i_rs_issue.src1_value[31:0];
  wire [31:0] src2_s = i_rs_issue.src2_value[31:0];
  wire [31:0] src3_s = i_rs_issue.src3_value[31:0];
  wire [63:0] src1_d = i_rs_issue.src1_value;
  wire [63:0] src2_d = i_rs_issue.src2_value;
  wire [63:0] src3_d = i_rs_issue.src3_value;

  // ===========================================================================
  // In-flight + flush tracking
  // ===========================================================================
  logic in_flight, flushed;
  logic fire, completing;

  logic mult_valid_out, fma_valid_out;
  assign completing = mult_valid_out | fma_valid_out;
  assign fire = i_rs_issue.valid & ~in_flight & (use_mult | use_fma);

  logic flush_inflight, flush_launching;
  assign flush_inflight = in_flight & (i_flush | (i_flush_en & is_younger(
      tag_reg, i_flush_tag, i_rob_head_tag
  )));
  assign flush_launching = fire & (i_flush | (i_flush_en & is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  )));

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      in_flight <= 1'b0;
      flushed   <= 1'b0;
    end else if (completing) begin
      in_flight <= 1'b0;
      flushed   <= 1'b0;
    end else begin
      if (fire) in_flight <= 1'b1;
      if (flush_inflight || flush_launching) flushed <= 1'b1;
    end
  end

  assign o_fu_busy = in_flight;

  // Latch ROB tag + op on fire
  logic [TagW-1:0] tag_reg;
  logic use_mult_reg, op_double_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tag_reg       <= '0;
      use_mult_reg  <= 1'b0;
      op_double_reg <= 1'b0;
    end else if (fire) begin
      tag_reg       <= i_rs_issue.rob_tag;
      use_mult_reg  <= use_mult;
      op_double_reg <= op_is_double;
    end
  end

  // ===========================================================================
  // Subunit: Multiplier (FMUL S/D)
  // ===========================================================================
  logic [FLEN-1:0] mult_result;
  riscv_pkg::fp_flags_t mult_flags;
  logic mult_busy;

  fpu_mult_unit u_mult (
      .i_clk          (i_clk),
      .i_rst          (~i_rst_n),
      .i_valid        (fire & use_mult),
      .i_use_unit     (use_mult),
      .i_op_is_double (op_is_double),
      .i_operand_a_s  (src1_s),
      .i_operand_b_s  (src2_s),
      .i_operand_a_d  (src1_d),
      .i_operand_b_d  (src2_d),
      .i_rounding_mode(i_rs_issue.rm),
      .i_dest_reg     (5'b0),
      .o_result       (mult_result),
      .o_valid        (mult_valid_out),
      .o_flags        (mult_flags),
      .o_busy         (mult_busy),
      .o_dest_reg     (),
      .o_start        ()
  );

  // ===========================================================================
  // Subunit: FMA (FMADD/FMSUB/FNMADD/FNMSUB S/D)
  // ===========================================================================
  logic [FLEN-1:0] fma_result;
  riscv_pkg::fp_flags_t fma_flags;
  logic fma_busy;

  fpu_fma_unit u_fma (
      .i_clk           (i_clk),
      .i_rst           (~i_rst_n),
      .i_valid         (fire & use_fma),
      .i_use_unit      (use_fma),
      .i_op_is_double  (op_is_double),
      .i_operand_a_s   (src1_s),
      .i_operand_b_s   (src2_s),
      .i_operand_c_s   (src3_s),
      .i_operand_a_d   (src1_d),
      .i_operand_b_d   (src2_d),
      .i_operand_c_d   (src3_d),
      .i_negate_product(negate_product),
      .i_negate_c      (negate_c),
      .i_rounding_mode (i_rs_issue.rm),
      .i_dest_reg      (5'b0),
      .o_result        (fma_result),
      .o_valid         (fma_valid_out),
      .o_flags         (fma_flags),
      .o_busy          (fma_busy),
      .o_dest_reg      (),
      .o_start         ()
  );

  // ===========================================================================
  // Result mux + NaN-boxing
  // ===========================================================================
  always_comb begin
    o_fu_complete.valid     = completing & ~flushed;
    o_fu_complete.tag       = tag_reg;
    o_fu_complete.value     = '0;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);

    if (completing) begin
      if (use_mult_reg) begin
        if (op_double_reg) o_fu_complete.value = mult_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, mult_result[31:0]};
        o_fu_complete.fp_flags = mult_flags;
      end else begin
        if (op_double_reg) o_fu_complete.value = fma_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, fma_result[31:0]};
        o_fu_complete.fp_flags = fma_flags;
      end
    end
  end

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  always_comb begin
    if (i_rst_n) begin
      p_busy_implies_inflight : assert (!o_fu_busy || in_flight);
    end
  end

  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_valid_has_tag : assert (o_fu_complete.tag == tag_reg);
    end
  end

  always_comb begin
    if (i_rst_n && flushed) begin
      p_no_output_when_flushed : assert (!o_fu_complete.valid);
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_fire_mult : cover (fire && use_mult);
      cover_fire_fma : cover (fire && use_fma);
      cover_complete : cover (o_fu_complete.valid);
      cover_flush_inflight : cover (flush_inflight);
    end
  end

`endif  // FORMAL

endmodule : fp_mul_shim
