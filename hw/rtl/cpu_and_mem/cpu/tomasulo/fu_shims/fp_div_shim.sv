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
 * FP Divide/Sqrt Shim (CDB Slot 6, FDIV_RS)
 *
 * Translates rs_issue_t from FDIV_RS into fpu_div_sqrt_unit native ports.
 *
 * Subunit:
 *   - fpu_div_sqrt_unit: FDIV_S/D, FSQRT_S/D (~32 cycles)
 *
 * Single long-latency FU. In-flight + flushed tracking pattern.
 */
module fp_div_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FDIV_RS (issue output)
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
  logic use_div, use_sqrt;
  logic op_is_double;

  always_comb begin
    use_div      = 1'b0;
    use_sqrt     = 1'b0;
    op_is_double = 1'b0;

    case (i_rs_issue.op)
      riscv_pkg::FDIV_S: use_div = 1'b1;
      riscv_pkg::FDIV_D: begin
        use_div = 1'b1;
        op_is_double = 1'b1;
      end
      riscv_pkg::FSQRT_S: use_sqrt = 1'b1;
      riscv_pkg::FSQRT_D: begin
        use_sqrt = 1'b1;
        op_is_double = 1'b1;
      end
      default: ;
    endcase
  end

  // Operand extraction
  wire [31:0] src1_s = i_rs_issue.src1_value[31:0];
  wire [31:0] src2_s = i_rs_issue.src2_value[31:0];
  wire [63:0] src1_d = i_rs_issue.src1_value;
  wire [63:0] src2_d = i_rs_issue.src2_value;

  // ===========================================================================
  // In-flight + flush tracking
  // ===========================================================================
  logic in_flight, flushed;
  logic fire, completing;

  logic div_valid_out, sqrt_valid_out;
  assign completing = div_valid_out | sqrt_valid_out;
  assign fire = i_rs_issue.valid & ~in_flight & (use_div | use_sqrt);

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
  logic use_sqrt_reg, op_double_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tag_reg       <= '0;
      use_sqrt_reg  <= 1'b0;
      op_double_reg <= 1'b0;
    end else if (fire) begin
      tag_reg       <= i_rs_issue.rob_tag;
      use_sqrt_reg  <= use_sqrt;
      op_double_reg <= op_is_double;
    end
  end

  // ===========================================================================
  // Subunit: Divider/Sqrt (FDIV/FSQRT S/D)
  // ===========================================================================
  logic [FLEN-1:0] divider_result;
  riscv_pkg::fp_flags_t divider_flags;
  logic [FLEN-1:0] sqrt_result;
  riscv_pkg::fp_flags_t sqrt_flags;
  logic fu_busy;

  fpu_div_sqrt_unit u_div_sqrt (
      .i_clk           (i_clk),
      .i_rst           (~i_rst_n),
      .i_valid         (fire),
      .i_use_divider   (use_div),
      .i_use_sqrt      (use_sqrt),
      .i_op_is_double  (op_is_double),
      .i_operand_a_s   (src1_s),
      .i_operand_b_s   (src2_s),
      .i_operand_a_d   (src1_d),
      .i_operand_b_d   (src2_d),
      .i_rounding_mode (i_rs_issue.rm),
      .i_dest_reg      (5'b0),
      .o_divider_result(divider_result),
      .o_divider_valid (div_valid_out),
      .o_divider_flags (divider_flags),
      .o_sqrt_result   (sqrt_result),
      .o_sqrt_valid    (sqrt_valid_out),
      .o_sqrt_flags    (sqrt_flags),
      .o_busy          (fu_busy),
      .o_dest_reg      (),
      .o_dest_reg_valid(),
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
      if (use_sqrt_reg) begin
        if (op_double_reg) o_fu_complete.value = sqrt_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, sqrt_result[31:0]};
        o_fu_complete.fp_flags = sqrt_flags;
      end else begin
        if (op_double_reg) o_fu_complete.value = divider_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, divider_result[31:0]};
        o_fu_complete.fp_flags = divider_flags;
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
      cover_fire_div : cover (fire && use_div);
      cover_fire_sqrt : cover (fire && use_sqrt);
      cover_complete : cover (o_fu_complete.valid);
      cover_flush_inflight : cover (flush_inflight);
    end
  end

`endif  // FORMAL

endmodule : fp_div_shim
