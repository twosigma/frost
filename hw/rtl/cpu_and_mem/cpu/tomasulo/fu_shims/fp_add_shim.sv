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
 * FP Add Shim (CDB Slot 4, FP_RS)
 *
 * Translates rs_issue_t from FP_RS into FPU subunit native ports, instantiates
 * five subunit types, and packs results into fu_complete_t for CDB adapter.
 *
 * Subunits:
 *   - fpu_adder_unit:       FADD_S/D, FSUB_S/D (~10 cycles)
 *   - fpu_compare_unit:     FEQ/FLT/FLE/FMIN/FMAX S/D (2 cycles)
 *   - fpu_classify_unit:    FCLASS_S/D (2 cycles)
 *   - fpu_sign_inject_unit: FSGNJ/FSGNJN/FSGNJX S/D (2 cycles)
 *   - fpu_convert_unit:     FCVT_*, FMV_* (5 cycles)
 *
 * Only one subunit fires at a time. Shared in_flight + flushed tracking.
 * Results are NaN-boxed (32-bit FP → 64-bit) or zero-extended (int results).
 */
module fp_add_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FP_RS (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // Back-pressure: FU in-flight prevents new issue
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial) — suppress in-flight results younger than tag
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
  // Op decode: select exactly one subunit
  // ===========================================================================
  logic use_adder, use_compare, use_classify, use_sgnj, use_convert;
  logic op_is_double, op_is_subtract;

  always_comb begin
    use_adder   = 1'b0;
    use_compare = 1'b0;
    use_classify = 1'b0;
    use_sgnj    = 1'b0;
    use_convert = 1'b0;
    op_is_double = 1'b0;
    op_is_subtract = 1'b0;

    case (i_rs_issue.op)
      riscv_pkg::FADD_S: begin
        use_adder = 1'b1;
      end
      riscv_pkg::FSUB_S: begin
        use_adder = 1'b1;
        op_is_subtract = 1'b1;
      end
      riscv_pkg::FADD_D: begin
        use_adder = 1'b1;
        op_is_double = 1'b1;
      end
      riscv_pkg::FSUB_D: begin
        use_adder = 1'b1;
        op_is_double = 1'b1;
        op_is_subtract = 1'b1;
      end

      riscv_pkg::FEQ_S, riscv_pkg::FLT_S, riscv_pkg::FLE_S, riscv_pkg::FMIN_S, riscv_pkg::FMAX_S:
      use_compare = 1'b1;
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FMIN_D, riscv_pkg::FMAX_D: begin
        use_compare  = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FCLASS_S: use_classify = 1'b1;
      riscv_pkg::FCLASS_D: begin
        use_classify = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S: use_sgnj = 1'b1;
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D: begin
        use_sgnj = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S,
      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_W_X:
      use_convert = 1'b1;
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S: begin
        use_convert  = 1'b1;
        op_is_double = 1'b1;
      end

      default: ;
    endcase
  end

  // ===========================================================================
  // Operand extraction
  // ===========================================================================
  wire [31:0] src1_s = i_rs_issue.src1_value[31:0];
  wire [31:0] src2_s = i_rs_issue.src2_value[31:0];
  wire [63:0] src1_d = i_rs_issue.src1_value;
  wire [63:0] src2_d = i_rs_issue.src2_value;

  // ===========================================================================
  // In-flight + flush tracking
  // ===========================================================================
  logic in_flight, flushed;
  logic fire;  // a subunit is being launched this cycle
  logic completing;  // any subunit is producing a valid output

  // Forward declare subunit valid outputs
  logic adder_valid_out, compare_valid_out, classify_valid_out;
  logic sgnj_valid_out, convert_valid_out;

  assign completing = adder_valid_out | compare_valid_out | classify_valid_out
                    | sgnj_valid_out | convert_valid_out;

  assign fire = i_rs_issue.valid & ~in_flight
                & (use_adder | use_compare | use_classify | use_sgnj | use_convert);

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
  riscv_pkg::instr_op_e op_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tag_reg <= '0;
      op_reg  <= riscv_pkg::instr_op_e'('0);
    end else if (fire) begin
      tag_reg <= i_rs_issue.rob_tag;
      op_reg  <= i_rs_issue.op;
    end
  end

  // ===========================================================================
  // Subunit: Adder (FADD/FSUB S/D)
  // ===========================================================================
  logic [FLEN-1:0] adder_result;
  riscv_pkg::fp_flags_t adder_flags;
  logic adder_busy;

  fpu_adder_unit u_adder (
      .i_clk          (i_clk),
      .i_rst          (~i_rst_n),
      .i_valid        (fire & use_adder),
      .i_use_unit     (use_adder),
      .i_op_is_double (op_is_double),
      .i_operand_a_s  (src1_s),
      .i_operand_b_s  (src2_s),
      .i_operand_a_d  (src1_d),
      .i_operand_b_d  (src2_d),
      .i_is_subtract  (op_is_subtract),
      .i_rounding_mode(i_rs_issue.rm),
      .i_dest_reg     (5'b0),
      .o_result       (adder_result),
      .o_valid        (adder_valid_out),
      .o_flags        (adder_flags),
      .o_busy         (adder_busy),
      .o_dest_reg     (),
      .o_start        ()
  );

  // ===========================================================================
  // Subunit: Compare (FEQ/FLT/FLE/FMIN/FMAX S/D)
  // ===========================================================================
  logic [FLEN-1:0] compare_result;
  logic compare_is_compare;
  riscv_pkg::fp_flags_t compare_flags;
  logic compare_busy;

  fpu_compare_unit u_compare (
      .i_clk         (i_clk),
      .i_rst         (~i_rst_n),
      .i_valid       (fire & use_compare),
      .i_use_unit    (use_compare),
      .i_op_is_double(op_is_double),
      .i_operand_a_s (src1_s),
      .i_operand_b_s (src2_s),
      .i_operand_a_d (src1_d),
      .i_operand_b_d (src2_d),
      .i_operation   (i_rs_issue.op),
      .i_dest_reg    (5'b0),
      .o_result      (compare_result),
      .o_is_compare  (compare_is_compare),
      .o_valid       (compare_valid_out),
      .o_flags       (compare_flags),
      .o_busy        (compare_busy),
      .o_dest_reg    (),
      .o_start       ()
  );

  // ===========================================================================
  // Subunit: Classify (FCLASS S/D)
  // ===========================================================================
  logic [31:0] classify_result;
  logic classify_busy;

  fpu_classify_unit u_classify (
      .i_clk         (i_clk),
      .i_rst         (~i_rst_n),
      .i_valid       (fire & use_classify),
      .i_use_unit    (use_classify),
      .i_op_is_double(op_is_double),
      .i_operand_a_s (src1_s),
      .i_operand_a_d (src1_d),
      .i_dest_reg    (5'b0),
      .o_result      (classify_result),
      .o_valid       (classify_valid_out),
      .o_busy        (classify_busy),
      .o_dest_reg    (),
      .o_start       ()
  );

  // ===========================================================================
  // Subunit: Sign Inject (FSGNJ/FSGNJN/FSGNJX S/D)
  // ===========================================================================
  logic [FLEN-1:0] sgnj_result;
  riscv_pkg::fp_flags_t sgnj_flags;
  logic sgnj_busy;

  fpu_sign_inject_unit u_sgnj (
      .i_clk         (i_clk),
      .i_rst         (~i_rst_n),
      .i_valid       (fire & use_sgnj),
      .i_use_unit    (use_sgnj),
      .i_op_is_double(op_is_double),
      .i_operand_a_s (src1_s),
      .i_operand_b_s (src2_s),
      .i_operand_a_d (src1_d),
      .i_operand_b_d (src2_d),
      .i_operation   (i_rs_issue.op),
      .i_dest_reg    (5'b0),
      .o_result      (sgnj_result),
      .o_valid       (sgnj_valid_out),
      .o_flags       (sgnj_flags),
      .o_busy        (sgnj_busy),
      .o_dest_reg    (),
      .o_start       ()
  );

  // ===========================================================================
  // Subunit: Convert (FCVT_*, FMV_*)
  // ===========================================================================
  logic [FLEN-1:0] convert_fp_result;
  logic [XLEN-1:0] convert_int_result;
  logic convert_is_fp_to_int;
  riscv_pkg::fp_flags_t convert_flags;
  logic convert_busy;

  // Determine which convert sub-path to activate
  logic cvt_use_s, cvt_use_d, cvt_use_sd;
  always_comb begin
    cvt_use_s  = 1'b0;
    cvt_use_d  = 1'b0;
    cvt_use_sd = 1'b0;
    case (i_rs_issue.op)
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S,
      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_W_X:
      cvt_use_s = 1'b1;
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU:
      cvt_use_d = 1'b1;
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S: cvt_use_sd = 1'b1;
      default: ;
    endcase
  end

  fpu_convert_unit u_convert (
      .i_clk           (i_clk),
      .i_rst           (~i_rst_n),
      .i_valid         (fire & use_convert),
      .i_use_convert_s (cvt_use_s),
      .i_use_convert_d (cvt_use_d),
      .i_use_convert_sd(cvt_use_sd),
      .i_operand_a_s   (src1_s),
      .i_operand_a_d   (src1_d),
      .i_int_operand   (i_rs_issue.src1_value[XLEN-1:0]),
      .i_operation     (i_rs_issue.op),
      .i_rounding_mode (i_rs_issue.rm),
      .i_dest_reg      (5'b0),
      .o_fp_result     (convert_fp_result),
      .o_int_result    (convert_int_result),
      .o_is_fp_to_int  (convert_is_fp_to_int),
      .o_valid         (convert_valid_out),
      .o_flags         (convert_flags),
      .o_busy          (convert_busy),
      .o_dest_reg      (),
      .o_start         ()
  );

  // ===========================================================================
  // Result mux + NaN-boxing
  // ===========================================================================
  // Latch which subunit was fired (for result mux on completion)
  logic [4:0] unit_sel_reg;  // [0]=adder,[1]=compare,[2]=classify,[3]=sgnj,[4]=convert
  logic op_double_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      unit_sel_reg  <= '0;
      op_double_reg <= 1'b0;
    end else if (fire) begin
      unit_sel_reg  <= {use_convert, use_sgnj, use_classify, use_compare, use_adder};
      op_double_reg <= op_is_double;
    end
  end

  // Latch compare_is_compare + convert_is_fp_to_int for output packing
  logic compare_is_compare_reg;
  logic convert_is_fp_to_int_reg;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      compare_is_compare_reg   <= 1'b0;
      convert_is_fp_to_int_reg <= 1'b0;
    end else if (completing) begin
      compare_is_compare_reg   <= compare_is_compare;
      convert_is_fp_to_int_reg <= convert_is_fp_to_int;
    end
  end

  always_comb begin
    o_fu_complete.valid     = completing & ~flushed;
    o_fu_complete.tag       = tag_reg;
    o_fu_complete.value     = '0;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);

    if (completing) begin
      if (unit_sel_reg[0]) begin
        // Adder: FADD/FSUB
        if (op_double_reg) o_fu_complete.value = adder_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, adder_result[31:0]};  // NaN-box
        o_fu_complete.fp_flags = adder_flags;
      end else if (unit_sel_reg[1]) begin
        // Compare: FEQ/FLT/FLE produce integer 0/1, FMIN/FMAX produce FP
        if (compare_is_compare) begin
          // Integer result: zero-extend to FLEN
          o_fu_complete.value = {{(FLEN - XLEN) {1'b0}}, compare_result[XLEN-1:0]};
        end else begin
          // FMIN/FMAX: FP result
          if (op_double_reg) o_fu_complete.value = compare_result;
          else o_fu_complete.value = {32'hFFFF_FFFF, compare_result[31:0]};
        end
        o_fu_complete.fp_flags = compare_flags;
      end else if (unit_sel_reg[2]) begin
        // Classify: integer result (10-bit), zero-extend to FLEN
        o_fu_complete.value = {{(FLEN - 32) {1'b0}}, classify_result};
      end else if (unit_sel_reg[3]) begin
        // Sign inject: FP result
        if (op_double_reg) o_fu_complete.value = sgnj_result;
        else o_fu_complete.value = {32'hFFFF_FFFF, sgnj_result[31:0]};
        o_fu_complete.fp_flags = sgnj_flags;
      end else if (unit_sel_reg[4]) begin
        // Convert
        if (convert_is_fp_to_int) begin
          // FP->INT: zero-extend int result to FLEN
          o_fu_complete.value = {{(FLEN - XLEN) {1'b0}}, convert_int_result};
        end else begin
          // INT->FP or FP->FP: NaN-box if single
          if (op_double_reg) o_fu_complete.value = convert_fp_result;
          else o_fu_complete.value = {32'hFFFF_FFFF, convert_fp_result[31:0]};
        end
        o_fu_complete.fp_flags = convert_flags;
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

  // Busy implies in-flight
  always_comb begin
    if (i_rst_n) begin
      p_busy_implies_inflight : assert (!o_fu_busy || in_flight);
    end
  end

  // Valid output requires matching latched tag
  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_valid_has_tag : assert (o_fu_complete.tag == tag_reg);
    end
  end

  // No output when flushed
  always_comb begin
    if (i_rst_n && flushed) begin
      p_no_output_when_flushed : assert (!o_fu_complete.valid);
    end
  end

  // Cover: fire and complete
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_fire_adder : cover (fire && use_adder);
      cover_fire_compare : cover (fire && use_compare);
      cover_fire_classify : cover (fire && use_classify);
      cover_fire_sgnj : cover (fire && use_sgnj);
      cover_fire_convert : cover (fire && use_convert);
      cover_complete : cover (o_fu_complete.valid);
      cover_flush_inflight : cover (flush_inflight);
    end
  end

`endif  // FORMAL

endmodule : fp_add_shim
