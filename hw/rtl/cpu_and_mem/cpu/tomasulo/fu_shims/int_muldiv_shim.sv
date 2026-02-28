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
 *   DIV, DIVU, REM, REMU     -> divider path    (17-cycle latency, pipelined)
 *
 * MUL path supports one in-flight operation with flush tracking.
 * DIV path is fully pipelined: a 17-entry shift register tracks in-flight
 * divides, and a 4-entry result FIFO buffers completed results waiting for
 * the CDB adapter. Credit-based back-pressure prevents FIFO overflow.
 */
module int_muldiv_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From MUL reservation station (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completions to CDB adapters
    output riscv_pkg::fu_complete_t o_mul_fu_complete,  // -> adapter -> arbiter slot 1
    output riscv_pkg::fu_complete_t o_div_fu_complete,  // -> adapter -> arbiter slot 2

    // Back-pressure: MUL in-flight or DIV pipeline full prevents new issue
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial) — suppress in-flight results younger than tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // DIV result consumed by downstream adapter
    input logic i_div_accepted
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
  // MUL in-flight + flush tracking (single in-flight, unchanged)
  // ---------------------------------------------------------------------------
  logic mul_in_flight;
  logic mul_flushed;

  // Forward declarations for valid signals from FUs
  logic multiplier_valid_input;
  logic multiplier_valid_output;
  logic divider_valid_input;
  logic divider_valid_output;

  logic mul_flush_inflight;
  logic mul_flush_launching;

  assign mul_flush_inflight = mul_in_flight & (i_flush | (i_flush_en & is_younger(
      mul_tag_reg, i_flush_tag, i_rob_head_tag
  )));
  assign mul_flush_launching = multiplier_valid_input & (i_flush | (i_flush_en & is_younger(
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

  // ---------------------------------------------------------------------------
  // Multiplier path (unchanged)
  // ---------------------------------------------------------------------------
  logic signed [32:0] mul_operand_a;
  logic signed [32:0] mul_operand_b;

  always_comb begin
    case (i_rs_issue.op)
      riscv_pkg::MULH: begin
        mul_operand_a = {i_rs_issue.src1_value[31], i_rs_issue.src1_value[31:0]};
        mul_operand_b = {i_rs_issue.src2_value[31], i_rs_issue.src2_value[31:0]};
      end
      riscv_pkg::MULHSU: begin
        mul_operand_a = {i_rs_issue.src1_value[31], i_rs_issue.src1_value[31:0]};
        mul_operand_b = {1'b0, i_rs_issue.src2_value[31:0]};
      end
      default: begin
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
      .i_rst                  (~i_rst_n),
      .i_operand_a            (mul_operand_a),
      .i_operand_b            (mul_operand_b),
      .i_valid_input          (multiplier_valid_input),
      .o_product_result       (mul_product),
      .o_valid_output         (multiplier_valid_output),
      .o_completing_next_cycle(mul_completing_next_cycle)
  );

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

  logic [31:0] mul_result_32;
  always_comb begin
    case (mul_op_reg)
      riscv_pkg::MUL: mul_result_32 = mul_product[31:0];
      default:        mul_result_32 = mul_product[63:32];
    endcase
  end

  always_comb begin
    o_mul_fu_complete.valid     = multiplier_valid_output & ~mul_flushed;
    o_mul_fu_complete.tag       = mul_tag_reg;
    o_mul_fu_complete.value     = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, mul_result_32};
    o_mul_fu_complete.exception = 1'b0;
    o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
  end

  // ---------------------------------------------------------------------------
  // Divider path — pipelined with shift register + result FIFO
  // ---------------------------------------------------------------------------
  logic div_is_signed;
  assign div_is_signed = (i_rs_issue.op == riscv_pkg::DIV) || (i_rs_issue.op == riscv_pkg::REM);

  // Credit-based busy prevents FIFO overflow (defined later, used here)
  logic div_busy;
  assign divider_valid_input = is_div & i_rs_issue.valid & ~div_busy;

  logic [31:0] div_quotient;
  logic [31:0] div_remainder;

  divider #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_divider (
      .i_clk                (i_clk),
      .i_rst                (~i_rst_n),
      .i_valid_input        (divider_valid_input),
      .i_is_signed_operation(div_is_signed),
      .i_dividend           (i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]),
      .i_divisor            (i_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .o_valid_output       (divider_valid_output),
      .o_quotient           (div_quotient),
      .o_remainder          (div_remainder)
  );

  // ---------------------------------------------------------------------------
  // DIV inflight shift register (17 entries, matching divider pipeline depth)
  // ---------------------------------------------------------------------------
  localparam int unsigned DivPipeDepth = riscv_pkg::XLEN / 2 + 1;  // 17

  // Individual flat arrays (avoid unpacked-array-of-packed-struct for Icarus).
  logic            div_trk_valid  [DivPipeDepth];
  logic [TagW-1:0] div_trk_tag    [DivPipeDepth];
  logic            div_trk_is_rem [DivPipeDepth];  // 1 = REM/REMU, 0 = DIV/DIVU
  logic            div_trk_flushed[DivPipeDepth];

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int i = 0; i < DivPipeDepth; i++) begin
        div_trk_valid[i]   <= 1'b0;
        div_trk_tag[i]     <= '0;
        div_trk_is_rem[i]  <= 1'b0;
        div_trk_flushed[i] <= 1'b0;
      end
    end else if (i_flush) begin
      for (int i = 0; i < DivPipeDepth; i++) begin
        div_trk_valid[i] <= 1'b0;
      end
    end else begin
      // Shift stages [0..DivPipeDepth-2] -> [1..DivPipeDepth-1]
      for (int i = DivPipeDepth - 1; i >= 1; i--) begin
        div_trk_valid[i]  <= div_trk_valid[i-1];
        div_trk_tag[i]    <= div_trk_tag[i-1];
        div_trk_is_rem[i] <= div_trk_is_rem[i-1];
        // Propagate flushed, or mark flushed via partial flush
        if (div_trk_valid[i-1] && i_flush_en && is_younger(
                div_trk_tag[i-1], i_flush_tag, i_rob_head_tag
            )) begin
          div_trk_flushed[i] <= 1'b1;
        end else begin
          div_trk_flushed[i] <= div_trk_flushed[i-1];
        end
      end
      // Stage 0: load from issue or invalidate
      if (divider_valid_input) begin
        div_trk_valid[0] <= 1'b1;
        div_trk_tag[0] <= i_rs_issue.rob_tag;
        div_trk_is_rem[0] <= (i_rs_issue.op == riscv_pkg::REM) ||
                             (i_rs_issue.op == riscv_pkg::REMU);
        // Check same-cycle launch+flush race
        if (i_flush_en && is_younger(i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag)) begin
          div_trk_flushed[0] <= 1'b1;
        end else begin
          div_trk_flushed[0] <= 1'b0;
        end
      end else begin
        div_trk_valid[0]   <= 1'b0;
        div_trk_tag[0]     <= '0;
        div_trk_is_rem[0]  <= 1'b0;
        div_trk_flushed[0] <= 1'b0;
      end
      // Partial flush sweep on entries already in the register (not shifting)
      // The shift above already handles partial flush for shifted entries.
      // But we also need to mark entries that are currently valid and younger.
      // Since we shift first and then check, the partial flush on the shifted
      // value is handled inline above. For the tail entry (DivPipeDepth-1),
      // it was already shifted from DivPipeDepth-2, so it's covered.
    end
  end

  // Count valid && !flushed entries in shift register
  logic [$clog2(DivPipeDepth+1)-1:0] div_inflight_count;
  always_comb begin
    div_inflight_count = '0;
    for (int i = 0; i < DivPipeDepth; i++) begin
      if (div_trk_valid[i] && !div_trk_flushed[i]) div_inflight_count = div_inflight_count + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // DIV result FIFO (4 entries, register-based)
  // ---------------------------------------------------------------------------
  localparam int unsigned FifoDepth = 4;

  // Individual flat arrays for FIFO data (Icarus compat — no struct arrays).
  logic [               TagW-1:0] div_fifo_tag              [FifoDepth];
  logic [    riscv_pkg::FLEN-1:0] div_fifo_value            [FifoDepth];
  logic [          FifoDepth-1:0] div_fifo_valid;
  logic [          FifoDepth-1:0] div_fifo_flushed;
  logic [$clog2(FifoDepth+1)-1:0] fifo_count;

  // Write pointer and read pointer
  logic [  $clog2(FifoDepth)-1:0] fifo_wr_ptr;
  logic [  $clog2(FifoDepth)-1:0] fifo_rd_ptr;

  // Divider completion: build fu_complete_t from tracker tail + divider outputs.
  // Gate on same-cycle partial flush of the tail to prevent a younger entry
  // from leaking into the FIFO before the always_ff marks it flushed.
  logic                           div_tail_partial_flushing;
  assign div_tail_partial_flushing = div_trk_valid[DivPipeDepth-1] && i_flush_en && is_younger(
      div_trk_tag[DivPipeDepth-1], i_flush_tag, i_rob_head_tag
  );

  logic div_completing;
  assign div_completing = div_trk_valid[DivPipeDepth-1] &&
                          !div_trk_flushed[DivPipeDepth-1] &&
                          !div_tail_partial_flushing;

  // Result selection from tracker tail
  logic [31:0] div_result_32;
  assign div_result_32 = div_trk_is_rem[DivPipeDepth-1] ? div_remainder : div_quotient;

  // Same-cycle partial flush of FIFO head: suppress output and trigger
  // auto-drain before the always_ff marks it flushed, preventing the adapter
  // from latching a younger result that should be squashed.
  logic fifo_head_partial_flushing;
  assign fifo_head_partial_flushing = (fifo_count != '0) &&
      !div_fifo_flushed[fifo_rd_ptr] && i_flush_en &&
      is_younger(
      div_fifo_tag[fifo_rd_ptr], i_flush_tag, i_rob_head_tag
  );

  // FIFO pop: adapter consumed, or head is flushed (auto-drain)
  logic fifo_pop;
  logic fifo_head_flushed;
  assign fifo_head_flushed = div_fifo_valid[fifo_rd_ptr] &&
      (div_fifo_flushed[fifo_rd_ptr] || fifo_head_partial_flushing);
  assign fifo_pop = (fifo_count != '0) && (i_div_accepted || fifo_head_flushed);

  // FIFO push: divider completes with non-flushed entry
  logic fifo_push;
  assign fifo_push = div_completing;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int i = 0; i < FifoDepth; i++) begin
        div_fifo_valid[i]   <= 1'b0;
        div_fifo_flushed[i] <= 1'b0;
      end
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count  <= '0;
    end else if (i_flush) begin
      for (int i = 0; i < FifoDepth; i++) begin
        div_fifo_valid[i]   <= 1'b0;
        div_fifo_flushed[i] <= 1'b0;
      end
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count  <= '0;
    end else begin
      // Partial flush: mark younger FIFO entries as flushed
      if (i_flush_en) begin
        for (int i = 0; i < FifoDepth; i++) begin
          if (div_fifo_valid[i] && !div_fifo_flushed[i] && is_younger(
                  div_fifo_tag[i], i_flush_tag, i_rob_head_tag
              )) begin
            div_fifo_flushed[i] <= 1'b1;
          end
        end
      end

      // Push
      if (fifo_push) begin
        div_fifo_tag[fifo_wr_ptr] <= div_trk_tag[DivPipeDepth-1];
        div_fifo_value[fifo_wr_ptr] <= {
          {(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, div_result_32
        };
        div_fifo_valid[fifo_wr_ptr] <= 1'b1;
        div_fifo_flushed[fifo_wr_ptr] <= 1'b0;
        fifo_wr_ptr <= fifo_wr_ptr + 1;
      end

      // Pop
      if (fifo_pop) begin
        div_fifo_valid[fifo_rd_ptr] <= 1'b0;
        div_fifo_flushed[fifo_rd_ptr] <= 1'b0;
        fifo_rd_ptr <= fifo_rd_ptr + 1;
      end

      // Update count
      case ({
        fifo_push, fifo_pop
      })
        2'b10:   fifo_count <= fifo_count + 1;
        2'b01:   fifo_count <= fifo_count - 1;
        default: fifo_count <= fifo_count;  // 2'b00 or 2'b11
      endcase
    end
  end

  // FIFO head output drives o_div_fu_complete
  always_comb begin
    if (fifo_count != '0 && !div_fifo_flushed[fifo_rd_ptr] && !fifo_head_partial_flushing) begin
      o_div_fu_complete.valid     = 1'b1;
      o_div_fu_complete.tag       = div_fifo_tag[fifo_rd_ptr];
      o_div_fu_complete.value     = div_fifo_value[fifo_rd_ptr];
      o_div_fu_complete.exception = 1'b0;
      o_div_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_div_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end else begin
      o_div_fu_complete.valid     = 1'b0;
      o_div_fu_complete.tag       = '0;
      o_div_fu_complete.value     = '0;
      o_div_fu_complete.exception = 1'b0;
      o_div_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_div_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end
  end

  // ---------------------------------------------------------------------------
  // Busy signal: credit-based to prevent FIFO overflow
  // ---------------------------------------------------------------------------
  logic [5:0] div_total_occupancy;
  assign div_total_occupancy = 6'(fifo_count) + 6'(div_inflight_count);
  assign div_busy = div_total_occupancy >= 6'(FifoDepth);
  assign o_fu_busy = mul_in_flight | div_busy;

endmodule : int_muldiv_shim
