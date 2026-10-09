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
 * Integer MUL/DIV shim
 *
 * Translates rs_issue_t from the MUL reservation station into the multiplier
 * and divider ports and packs their results into fu_complete_t for the CDB
 * adapters and arbiter.
 *
 * Signal flow:  MUL_RS -> int_muldiv_shim -> multiplier -> fu_complete_t (slot 1)
 *                                         -> divider    -> fu_complete_t (slot 2)
 *
 * Op decode:
 *   MUL, MULH, MULHSU, MULHU -> full-width multiplier path
 *     (riscv_pkg::MulPipeDepth-cycle latency, pipelined)
 *   MULW -> dedicated unsigned 32-bit multiplier (3 cycles)
 *   DIV, DIVU, REM, REMU and their W forms -> iterative divider, one
 *     operation at a time (result after XLEN + 1 cycles, XLEN/2 + 1 for a W
 *     form)
 * SHORT_WORD_OPS=0 sends MULW through the full-width multiplier.
 *
 * The multiplier path is pipelined. A shift register as deep as the
 * full-width unit tracks its in-flight operations, carrying each one's ROB
 * tag and result select, and a 4-entry result FIFO holds completions waiting
 * for the CDB adapter. Credit-based back-pressure (o_fu_busy) keeps unflushed
 * operations in flight plus FIFO occupancy within the FIFO depth, so the FIFO
 * cannot overflow. A MULW enters the tracker partway down, at the stage that
 * lines up with the word multiplier, and waits while a live operation is
 * about to move into that stage.
 *
 * The divider holds one operation, and then its result until the DIV adapter
 * takes it; o_div_busy is high from the start until then. MUL_RS
 * (DIVIDE_ISSUE_GATE) presents a divide only while the divider is idle, so
 * every divide issue starts unless a flush in the same cycle squashes it, and
 * the multiplies in the station keep issuing while divides wait there.
 */
module int_muldiv_shim #(
    parameter bit SHORT_WORD_OPS = 1'b1
) (
    input logic i_clk,
    input logic i_rst_n,

    // From MUL reservation station (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completions to CDB adapters
    output riscv_pkg::fu_complete_t o_mul_fu_complete,  // -> adapter -> arbiter slot 1
    output riscv_pkg::fu_complete_t o_div_fu_complete,  // -> adapter -> arbiter slot 2

    // Back-pressure: MUL path credits exhausted, MUL_RS must not issue
    output logic o_fu_busy,

    // The divider holds an operation or an untaken result, so MUL_RS must not
    // present a divide
    output logic o_div_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial): suppress in-flight results younger than the tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // MUL / DIV result consumed by downstream adapter
    input logic i_mul_accepted,
    input logic i_div_accepted
);

  // ---------------------------------------------------------------------------
  // Op decode (combinational)
  // ---------------------------------------------------------------------------
  logic is_mul;
  logic is_div;
  // The result select also names the source unit: with SHORT_WORD_OPS set, a
  // MUL_SEL_SEXT_W entry takes its product from the word multiplier.
  typedef enum logic [1:0] {
    MUL_SEL_LOW,    // MUL: low XLEN bits of the product
    MUL_SEL_HIGH,   // MULH/MULHSU/MULHU: high XLEN bits
    MUL_SEL_SEXT_W  // MULW: sext32 of the low 32 product bits (RV64 only)
  } mul_result_sel_e;
  mul_result_sel_e mul_result_sel;
  logic mul_is_short_word;
  assign mul_is_short_word = SHORT_WORD_OPS && i_rs_issue.op == riscv_pkg::MULW;

  always_comb begin
    mul_result_sel = MUL_SEL_LOW;
    case (i_rs_issue.op)
      riscv_pkg::MUL, riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU, riscv_pkg::MULW: begin
        is_mul = 1'b1;
        is_div = 1'b0;
      end
      riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU,
      riscv_pkg::DIVW, riscv_pkg::DIVUW, riscv_pkg::REMW, riscv_pkg::REMUW: begin
        is_mul = 1'b0;
        is_div = 1'b1;
      end
      default: begin
        is_mul = 1'b0;
        is_div = 1'b0;
      end
    endcase
    case (i_rs_issue.op)
      riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU: mul_result_sel = MUL_SEL_HIGH;
      riscv_pkg::MULW: mul_result_sel = MUL_SEL_SEXT_W;
      default: mul_result_sel = MUL_SEL_LOW;
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
  // MUL path: MulPipeDepth-stage pipeline plus a 4-entry result FIFO
  // ---------------------------------------------------------------------------
  // Forward declarations for valid signals from the multipliers
  logic multiplier_valid_input;
  logic multiplier_valid_output;

  // Credit-based busy (defined later, used here)
  logic mul_busy;

  assign multiplier_valid_input = is_mul & i_rs_issue.valid & ~mul_busy;

  // Multiplier operand mux, (XLEN+1)-bit: only the sign extension varies.
  // In the full-width fallback MULW takes the zero-extended default. Its low
  // 32 product bits depend only on the operands' low words.
  localparam int unsigned MulXlen = riscv_pkg::XLEN;
  logic signed [MulXlen:0] mul_operand_a;
  logic signed [MulXlen:0] mul_operand_b;

  always_comb begin
    case (i_rs_issue.op)
      riscv_pkg::MULH: begin
        mul_operand_a = {i_rs_issue.src1_value[MulXlen-1], i_rs_issue.src1_value[MulXlen-1:0]};
        mul_operand_b = {i_rs_issue.src2_value[MulXlen-1], i_rs_issue.src2_value[MulXlen-1:0]};
      end
      riscv_pkg::MULHSU: begin
        mul_operand_a = {i_rs_issue.src1_value[MulXlen-1], i_rs_issue.src1_value[MulXlen-1:0]};
        mul_operand_b = {1'b0, i_rs_issue.src2_value[MulXlen-1:0]};
      end
      default: begin
        mul_operand_a = {1'b0, i_rs_issue.src1_value[MulXlen-1:0]};
        mul_operand_b = {1'b0, i_rs_issue.src2_value[MulXlen-1:0]};
      end
    endcase
  end

  logic [2*MulXlen-1:0] mul_product;
  logic                 mul_completing_next_cycle;  // unused

  multiplier u_multiplier (
      .i_clk                  (i_clk),
      .i_rst                  (~i_rst_n),
      .i_operand_a            (mul_operand_a),
      .i_operand_b            (mul_operand_b),
      .i_valid_input          (multiplier_valid_input && !mul_is_short_word),
      .o_product_result       (mul_product),
      .o_valid_output         (multiplier_valid_output),
      .o_completing_next_cycle(mul_completing_next_cycle)
  );

  // ---------------------------------------------------------------------------
  // MUL in-flight shift register. Its depth is riscv_pkg::MulPipeDepth, which
  // multiplier.sv checks against its own latency.
  // ---------------------------------------------------------------------------
  localparam int unsigned MulPipeDepth  = riscv_pkg::MulPipeDepth;
  localparam int unsigned WordMulDepth  = riscv_pkg::dsp_tiled_stages(32, 32, 27, 35);
  localparam int unsigned WordMulInsert = MulPipeDepth - WordMulDepth;
  logic [63:0] word_mul_product;
  logic word_mul_valid;
  if (SHORT_WORD_OPS) begin : gen_word_multiplier
    // The word multiply needs two of its three stages, so it registers its
    // operands in the spare one: the DSPs start from their input registers
    // rather than from the station's issue operand select, at unchanged latency.
    dsp_tiled_multiplier_unsigned #(
        .A_WIDTH(32),
        .B_WIDTH(32),
        .INPUT_REGISTER(1'b1)
    ) u_word_multiplier (
        .i_clk,
        .i_rst(~i_rst_n),
        .i_valid_input(multiplier_valid_input && mul_is_short_word),
        .i_operand_a(i_rs_issue.src1_value[31:0]),
        .i_operand_b(i_rs_issue.src2_value[31:0]),
        .o_product_result(word_mul_product),
        .o_valid_output(word_mul_valid),
        .o_completing_next_cycle()
    );
  end else begin : gen_no_word_multiplier
    assign word_mul_product = '0;
    assign word_mul_valid   = 1'b0;
  end

  // Individual flat arrays avoid less portable unpacked-array-of-packed-struct storage.
  logic                       mul_trk_valid  [MulPipeDepth];
  logic            [TagW-1:0] mul_trk_tag    [MulPipeDepth];
  mul_result_sel_e            mul_trk_rsel   [MulPipeDepth];  // low / high / sext-low32
  logic                       mul_trk_flushed[MulPipeDepth];

  always_ff @(posedge i_clk) begin
    // --- Control: valid + flushed (with reset) ---
    if (!i_rst_n) begin
      for (int i = 0; i < MulPipeDepth; i++) begin
        mul_trk_valid[i]   <= 1'b0;
        mul_trk_flushed[i] <= 1'b0;
      end
    end else if (i_flush) begin
      for (int i = 0; i < MulPipeDepth; i++) begin
        mul_trk_valid[i] <= 1'b0;
      end
    end else begin
      // Shift control stages
      for (int i = MulPipeDepth - 1; i >= 1; i--) begin
        mul_trk_valid[i] <= mul_trk_valid[i-1];
        if (mul_trk_valid[i-1] && i_flush_en && is_younger(
                mul_trk_tag[i-1], i_flush_tag, i_rob_head_tag
            ))
          mul_trk_flushed[i] <= 1'b1;
        else mul_trk_flushed[i] <= mul_trk_flushed[i-1];
      end
      // Stage 0 control
      if (multiplier_valid_input && !mul_is_short_word) begin
        mul_trk_valid[0] <= 1'b1;
        if (i_flush_en && is_younger(i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag))
          mul_trk_flushed[0] <= 1'b1;
        else mul_trk_flushed[0] <= 1'b0;
      end else begin
        mul_trk_valid[0]   <= 1'b0;
        mul_trk_flushed[0] <= 1'b0;
      end
      // The word multiplier shares the tail and FIFO. A word operation enters
      // at WordMulInsert so it reaches the tail with its product; mul_busy
      // holds it off while a live entry is about to shift into that stage.
      if (multiplier_valid_input && mul_is_short_word) begin
        mul_trk_valid[WordMulInsert] <= 1'b1;
        mul_trk_flushed[WordMulInsert] <= i_flush_en && is_younger(
            i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
        );
      end
    end
  end

  // --- Data: tag + result-select shift register (no reset) ---
  always_ff @(posedge i_clk) begin
    for (int i = MulPipeDepth - 1; i >= 1; i--) begin
      mul_trk_tag[i]  <= mul_trk_tag[i-1];
      mul_trk_rsel[i] <= mul_trk_rsel[i-1];
    end
    if (multiplier_valid_input && !mul_is_short_word) begin
      mul_trk_tag[0]  <= i_rs_issue.rob_tag;
      mul_trk_rsel[0] <= mul_result_sel;
    end
    if (multiplier_valid_input && mul_is_short_word) begin
      mul_trk_tag[WordMulInsert]  <= i_rs_issue.rob_tag;
      mul_trk_rsel[WordMulInsert] <= MUL_SEL_SEXT_W;
    end
  end

  // Count valid && !flushed entries in shift register
  logic [$clog2(MulPipeDepth+1)-1:0] mul_inflight_count;
  always_comb begin
    mul_inflight_count = '0;
    for (int i = 0; i < MulPipeDepth; i++) begin
      if (mul_trk_valid[i] && !mul_trk_flushed[i]) mul_inflight_count = mul_inflight_count + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // MUL result FIFO (4 entries, FF control with LUTRAM payload)
  // ---------------------------------------------------------------------------
  localparam int unsigned MulFifoDepth = 4;

  logic [                  TagW-1:0] mul_fifo_tag           [MulFifoDepth];
  logic [       riscv_pkg::FLEN-1:0] mul_fifo_value_rd;
  logic [       riscv_pkg::FLEN-1:0] mul_fifo_value_wr_data;
  logic [          MulFifoDepth-1:0] mul_fifo_valid;
  logic [          MulFifoDepth-1:0] mul_fifo_flushed;
  logic [$clog2(MulFifoDepth+1)-1:0] mul_fifo_count;
  logic                              mul_fifo_push;

  logic [  $clog2(MulFifoDepth)-1:0] mul_fifo_wr_ptr;
  logic [  $clog2(MulFifoDepth)-1:0] mul_fifo_rd_ptr;

  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(MulFifoDepth)),
      .DATA_WIDTH(riscv_pkg::FLEN)
  ) u_mul_fifo_value (
      .i_clk,
      .i_write_enable (mul_fifo_push),
      .i_write_address(mul_fifo_wr_ptr),
      .i_write_data   (mul_fifo_value_wr_data),
      .i_read_address (mul_fifo_rd_ptr),
      .o_read_data    (mul_fifo_value_rd)
  );

  // Multiplier completion: build result from tracker tail + multiplier output.
  //
  // mul_completing has no same-cycle partial-flush term, which keeps
  // is_younger out of the mul_fifo_count enable. A younger result pushed in a
  // flush cycle is marked flushed as it is written (push branch below), so it
  // is never presented. The FIFO head presented during the flush cycle itself
  // is filtered by the adapter's partial_flush_input, which sees the same
  // live i_flush_en.
  logic mul_completing;
  assign mul_completing = mul_trk_valid[MulPipeDepth-1] && !mul_trk_flushed[MulPipeDepth-1];

  // Result selection from the tracker tail: MUL takes the low product word,
  // MULH/MULHSU/MULHU the high word, MULW the sext32 of the low word.
  logic [MulXlen-1:0] mul_result_xlen;
  always_comb begin
    case (mul_trk_rsel[MulPipeDepth-1])
      MUL_SEL_HIGH: mul_result_xlen = mul_product[2*MulXlen-1:MulXlen];
      MUL_SEL_SEXT_W:
      mul_result_xlen = SHORT_WORD_OPS ?
          {{(MulXlen - 32) {word_mul_product[31]}}, word_mul_product[31:0]} :
          {{(MulXlen - 32) {mul_product[31]}}, mul_product[31:0]};
      default: mul_result_xlen = mul_product[MulXlen-1:0];
    endcase
  end
  assign mul_fifo_value_wr_data = riscv_pkg::FLEN'(mul_result_xlen);

  // Same-cycle flush of a young entry being pushed, factored out for the push
  // branch of mul_fifo_flushed[wr_ptr].D.
  logic mul_push_entry_flush_young;
  assign mul_push_entry_flush_young = i_flush_en && is_younger(
      mul_trk_tag[MulPipeDepth-1], i_flush_tag, i_rob_head_tag
  );

  // FIFO pop: adapter consumed, or head is already marked flushed (auto-drain).
  // Uses only the registered mul_fifo_flushed bit, so the pop → count.CE cone
  // holds no combinational is_younger / flush_tag dependency.
  logic mul_fifo_pop;
  logic mul_fifo_head_flushed;
  assign mul_fifo_head_flushed = mul_fifo_valid[mul_fifo_rd_ptr] &&
                                 mul_fifo_flushed[mul_fifo_rd_ptr];
  assign mul_fifo_pop = (mul_fifo_count != '0) && (i_mul_accepted || mul_fifo_head_flushed);

  // FIFO push: multiplier completes with a non-flushed entry.
  //
  // The push does not depend on i_mul_accepted, so the accept handshake
  // reaches only the FIFO's read pointer and count, not the entry writes.
  // There is deliberately no same-cycle bypass around the FIFO, which would
  // feed the wrapper's accept logic back into mul_fifo_push; every result
  // spends at least one cycle in the FIFO.
  assign mul_fifo_push = mul_completing;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      for (int i = 0; i < MulFifoDepth; i++) begin
        mul_fifo_valid[i]   <= 1'b0;
        mul_fifo_flushed[i] <= 1'b0;
      end
      mul_fifo_wr_ptr <= '0;
      mul_fifo_rd_ptr <= '0;
      mul_fifo_count  <= '0;
    end else if (i_flush) begin
      for (int i = 0; i < MulFifoDepth; i++) begin
        mul_fifo_valid[i]   <= 1'b0;
        mul_fifo_flushed[i] <= 1'b0;
      end
      mul_fifo_wr_ptr <= '0;
      mul_fifo_rd_ptr <= '0;
      mul_fifo_count  <= '0;
    end else begin
      // Partial flush: mark younger FIFO entries as flushed
      if (i_flush_en) begin
        for (int i = 0; i < MulFifoDepth; i++) begin
          if (mul_fifo_valid[i] && !mul_fifo_flushed[i] && is_younger(
                  mul_fifo_tag[i], i_flush_tag, i_rob_head_tag
              )) begin
            mul_fifo_flushed[i] <= 1'b1;
          end
        end
      end

      // Push. The new entry inherits the tracker tail's flushed bit and picks
      // up a same-cycle partial flush against its own tag, so the push and
      // completion path needs no separate combinational suppression.
      if (mul_fifo_push) begin
        mul_fifo_tag[mul_fifo_wr_ptr] <= mul_trk_tag[MulPipeDepth-1];
        mul_fifo_valid[mul_fifo_wr_ptr] <= 1'b1;
        mul_fifo_flushed[mul_fifo_wr_ptr] <=
            mul_trk_flushed[MulPipeDepth-1] || mul_push_entry_flush_young;
        mul_fifo_wr_ptr <= mul_fifo_wr_ptr + 1;
      end

      // Pop advances rd_ptr only. mul_fifo_valid and mul_fifo_flushed stay
      // set: every read of them is gated by mul_fifo_count, which is the
      // occupancy of record, and the next push to this slot overwrites them.
      // Clearing them here would only drag i_mul_accepted into the FIFO
      // registers' next-state.
      if (mul_fifo_pop) begin
        mul_fifo_rd_ptr <= mul_fifo_rd_ptr + 1;
      end

      case ({
        mul_fifo_push, mul_fifo_pop
      })
        2'b10:   mul_fifo_count <= mul_fifo_count + 1;
        2'b01:   mul_fifo_count <= mul_fifo_count - 1;
        default: mul_fifo_count <= mul_fifo_count;  // 2'b00 or 2'b11
      endcase
    end
  end

  // FIFO head output drives o_mul_fu_complete. It reads only the registered
  // mul_fifo_flushed bit, so no combinational is_younger enters the output
  // cone. During the flush cycle the adapter's own partial_flush_input filter
  // (direct i_flush_en) catches younger results. By the next cycle the
  // always_ff marking pass has set the flushed bit on any young entry.
  // The tag is not qualified with valid: the adapter uses it only with valid,
  // and its partial-flush compare must not wait for the head-valid logic. The
  // tag is unspecified while valid is low.
  always_comb begin
    o_mul_fu_complete.tag = mul_fifo_tag[mul_fifo_rd_ptr];
    if (mul_fifo_count != '0 && !mul_fifo_flushed[mul_fifo_rd_ptr]) begin
      o_mul_fu_complete.valid     = 1'b1;
      o_mul_fu_complete.value     = mul_fifo_value_rd;
      o_mul_fu_complete.exception = 1'b0;
      o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end else begin
      o_mul_fu_complete.valid     = 1'b0;
      o_mul_fu_complete.value     = '0;
      o_mul_fu_complete.exception = 1'b0;
      o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end
  end

  // MUL busy (credit-based to prevent FIFO overflow)
  logic [5:0] mul_total_occupancy;
  assign mul_total_occupancy = 6'(mul_fifo_count) + 6'(mul_inflight_count);
  // op comes from the RS's registered stage2 packet independently of ready
  // and valid. Qualifying only this W operation creates no ready/valid loop
  // and never stalls an unrelated full-width multiply for a slot collision.
  assign mul_busy = (mul_total_occupancy >= 6'(MulFifoDepth)) ||
      (mul_is_short_word && mul_trk_valid[WordMulInsert-1] &&
       !mul_trk_flushed[WordMulInsert-1]);

  // ---------------------------------------------------------------------------
  // Divider path: one iterative divider, one operation at a time
  // ---------------------------------------------------------------------------
  logic div_is_signed, div_is_w, div_is_rem;
  assign div_is_signed = (i_rs_issue.op == riscv_pkg::DIV) || (i_rs_issue.op == riscv_pkg::REM) ||
      (i_rs_issue.op == riscv_pkg::DIVW) || (i_rs_issue.op == riscv_pkg::REMW);
  assign div_is_w = (i_rs_issue.op == riscv_pkg::DIVW) || (i_rs_issue.op == riscv_pkg::DIVUW) ||
      (i_rs_issue.op == riscv_pkg::REMW) || (i_rs_issue.op == riscv_pkg::REMUW);
  assign div_is_rem = (i_rs_issue.op == riscv_pkg::REM) || (i_rs_issue.op == riscv_pkg::REMU) ||
      (i_rs_issue.op == riscv_pkg::REMW) || (i_rs_issue.op == riscv_pkg::REMUW);

  logic div_idle, div_done;
  logic [riscv_pkg::XLEN-1:0] div_result;
  logic [TagW-1:0] div_tag_q;

  // The RS still presents an instruction that a flush squashes in the same
  // cycle, so a divide issue covered by that flush does not start.
  logic div_start;
  assign div_start = is_div && i_rs_issue.valid && !(i_flush || (i_flush_en && is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  )));

  // A full flush, or a partial flush that covers the operation, kills it, and
  // the divider is idle on the next cycle. A result presented in the flush
  // cycle itself is also dropped by the adapter, which sees the same flush.
  logic div_kill;
  assign div_kill = !div_idle && (i_flush || (i_flush_en && is_younger(
      div_tag_q, i_flush_tag, i_rob_head_tag
  )));

  // Loads while the divider is idle, as the divider's operand registers do,
  // so the start condition stays off its enable.
  always_ff @(posedge i_clk) begin
    if (div_idle) div_tag_q <= i_rs_issue.rob_tag;
  end

  divider #(
      .WIDTH(riscv_pkg::XLEN)
  ) u_divider (
      .i_clk      (i_clk),
      .i_rst      (~i_rst_n),
      .i_start    (div_start),
      .i_kill     (div_kill),
      .i_accept   (i_div_accepted),
      .i_is_signed(div_is_signed),
      .i_is_word  (div_is_w),
      .i_is_rem   (div_is_rem),
      .i_dividend (i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]),
      .i_divisor  (i_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .o_idle     (div_idle),
      .o_done     (div_done),
      .o_result   (div_result)
  );

  // The divider holds its result until the adapter takes it (i_div_accepted).
  // Tag and value are not qualified with valid: the DIV adapter registers its
  // output and captures its input only with valid.
  always_comb begin
    o_div_fu_complete.valid     = div_done;
    o_div_fu_complete.tag       = div_tag_q;
    o_div_fu_complete.value     = riscv_pkg::FLEN'(div_result);
    o_div_fu_complete.exception = 1'b0;
    o_div_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_div_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
  end

  // A divide never raises o_fu_busy: MUL_RS keeps divides back while
  // o_div_busy is high, so the multiplier never waits for the divider.
  assign o_div_busy = !div_idle;
  assign o_fu_busy  = mul_busy;

`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation checks: the MUL tracker tail must line up with its unit's
  // output valid, and a divide may only be presented while the divider is
  // idle. The RS retires its entry on the issue cycle, so a divide presented
  // while the divider is busy would be lost.
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      if (mul_completing && !(SHORT_WORD_OPS &&
          mul_trk_rsel[MulPipeDepth-1] == MUL_SEL_SEXT_W ?
          word_mul_valid : multiplier_valid_output))
        $error("int_muldiv_shim: MUL tracker/data pipeline mismatch");
      if (is_div && i_rs_issue.valid && !div_idle)
        $error(
            "int_muldiv_shim: divide issue of tag %0d while the divider is busy", i_rs_issue.rob_tag
        );
    end
  end
`endif
`endif

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  // Valid histories of the two multipliers, which flushes do not affect. The
  // per-stage assertions below tie each live tracker entry to the unit
  // holding its operation, which makes tail/data alignment inductive.
  logic [MulPipeDepth-1:0] f_full_mul;
  logic [WordMulDepth-1:0] f_word_mul;
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_full_mul <= '0;
      f_word_mul <= '0;
    end else begin
      f_full_mul <= {f_full_mul[MulPipeDepth-2:0], multiplier_valid_input && !mul_is_short_word};
      f_word_mul <= {f_word_mul[WordMulDepth-2:0], multiplier_valid_input && mul_is_short_word};
    end
  end
  for (genvar stage = 0; stage < MulPipeDepth; stage++) begin : gen_f_mul_owner
    always @(posedge i_clk) begin
      if (f_past_valid && i_rst_n && mul_trk_valid[stage] && !mul_trk_flushed[stage]) begin
        if (SHORT_WORD_OPS && mul_trk_rsel[stage] == MUL_SEL_SEXT_W) begin
          if (stage >= WordMulInsert)
            assert (f_word_mul[stage-WordMulInsert]);
            else assert (1'b0);
        end else assert (f_full_mul[stage]);
      end
    end
  end

  // The issue contract MUL_RS's divide gate provides: a divide is presented
  // only while the divider is idle.
  always_comb begin
    if (f_past_valid && i_rst_n) assume (!(is_div && i_rs_issue.valid) || div_idle);
  end

  // Divider flushed-tag discipline: once a flush squashes the watched divide,
  // held or issuing, its tag does not appear on a valid DIV completion again
  // until a new divide starts with the same tag value (a reallocated ROB
  // entry). The proof tracks one arbitrary (anyconst) tag.
  (* anyconst *) logic [TagW-1:0] f_watch_tag;
  logic f_watch_squashed_now, f_watch_dead_q;
  assign f_watch_squashed_now = ((!div_idle && div_tag_q == f_watch_tag) ||
      (is_div && i_rs_issue.valid && i_rs_issue.rob_tag == f_watch_tag)) &&
      (i_flush || (i_flush_en && is_younger(
      f_watch_tag, i_flush_tag, i_rob_head_tag
  )));
  logic [TagW-1:0] f_started_tag;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_watch_dead_q <= 1'b0;
    else if (f_watch_squashed_now) f_watch_dead_q <= 1'b1;
    else if (div_start && i_rs_issue.rob_tag == f_watch_tag) f_watch_dead_q <= 1'b0;
    if (div_start && div_idle) f_started_tag <= i_rs_issue.rob_tag;
  end

  always @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid)
      assume (!i_rst_n);
      else assume (i_rst_n);
    if (f_past_valid && i_rst_n) begin
`ifndef F_MULDIV_ALIGNMENT
      // The MUL credit bound is inductive at shallow depth. Keep its SMT task
      // separate from physical FU alignment: unrolling the multiplier adds no
      // information to a completion-credit proof.
      assert (mul_total_occupancy <= 6'(MulFifoDepth));
      if (multiplier_valid_input && mul_is_short_word)
        assert (!mul_trk_valid[WordMulInsert-1] || mul_trk_flushed[WordMulInsert-1]);
      // Divider: busy until its result is taken, a completion carries the tag
      // of the divide that started last, and a squashed divide never completes.
      assert (o_div_busy == !div_idle);
      assert (!o_div_fu_complete.valid || o_div_busy);
      if ($past(i_rst_n) && $past(div_kill)) assert (div_idle);
      if (!div_idle) assert (div_tag_q == f_started_tag);
      if (f_watch_dead_q && !div_idle) assert (div_tag_q != f_watch_tag);
      if (f_watch_dead_q && o_div_fu_complete.valid) assert (o_div_fu_complete.tag != f_watch_tag);
`else
      // This task keeps the real multiplier valid pipelines. With the
      // per-stage assertions above and the physical histories, it proves that
      // each surviving completion selects its result from the right width's
      // unit.
      assert (f_full_mul[MulPipeDepth-1] == multiplier_valid_output);
      assert (f_word_mul[WordMulDepth-1] == word_mul_valid);
      if (mul_completing)
        assert (SHORT_WORD_OPS && mul_trk_rsel[MulPipeDepth-1] == MUL_SEL_SEXT_W ?
            word_mul_valid : multiplier_valid_output);
`endif
      cover (mul_completing && mul_trk_rsel[MulPipeDepth-1] == MUL_SEL_SEXT_W);
      cover (mul_is_short_word && mul_busy && mul_total_occupancy < 4);
      cover (o_div_fu_complete.valid && !i_div_accepted);
      cover (div_kill && !o_div_fu_complete.valid);
      cover (multiplier_valid_input && o_div_busy);
    end
  end
`endif

endmodule : int_muldiv_shim
