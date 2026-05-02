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
 *   MUL, MULH, MULHSU, MULHU -> multiplier path (4-cycle latency, pipelined)
 *   DIV, DIVU, REM, REMU     -> divider path    (17-cycle latency, pipelined)
 *
 * MUL path is fully pipelined: a 4-entry shift register tracks in-flight
 * multiplies (matching the multiplier's pipeline depth), and a 4-entry
 * result FIFO buffers completed results waiting for the CDB adapter.
 * Credit-based back-pressure prevents FIFO overflow.
 *
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

    // Back-pressure: MUL or DIV FIFO full prevents new issue
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial) — suppress in-flight results younger than tag
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
  logic is_mul_low;  // 1 for MUL (low 32 bits), 0 for MULH/MULHSU/MULHU (high 32)

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
  assign is_mul_low = (i_rs_issue.op == riscv_pkg::MUL);

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
  // MUL path — 4-stage pipeline + 4-entry result FIFO
  // ---------------------------------------------------------------------------
  // Forward declarations for valid signals from FUs
  logic multiplier_valid_input;
  logic multiplier_valid_output;
  logic divider_valid_input;
  logic divider_valid_output;

  // Credit-based busy (defined later, used here)
  logic mul_busy;
  logic div_busy;

  assign multiplier_valid_input = is_mul & i_rs_issue.valid & ~mul_busy;

  // Multiplier operand mux (same as before; only signed-extension varies).
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

  // ---------------------------------------------------------------------------
  // MUL inflight shift register (4 entries, matching multiplier latency)
  // ---------------------------------------------------------------------------
  localparam int unsigned MulPipeDepth = 4;

  // Individual flat arrays avoid less portable unpacked-array-of-packed-struct storage.
  logic            mul_trk_valid  [MulPipeDepth];
  logic [TagW-1:0] mul_trk_tag    [MulPipeDepth];
  logic            mul_trk_is_low [MulPipeDepth];  // 1 = MUL (low 32 bits), 0 = high
  logic            mul_trk_flushed[MulPipeDepth];

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
      if (multiplier_valid_input) begin
        mul_trk_valid[0] <= 1'b1;
        if (i_flush_en && is_younger(i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag))
          mul_trk_flushed[0] <= 1'b1;
        else mul_trk_flushed[0] <= 1'b0;
      end else begin
        mul_trk_valid[0]   <= 1'b0;
        mul_trk_flushed[0] <= 1'b0;
      end
    end
  end

  // --- Data: tag + is_low shift register (no reset) ---
  always_ff @(posedge i_clk) begin
    for (int i = MulPipeDepth - 1; i >= 1; i--) begin
      mul_trk_tag[i]    <= mul_trk_tag[i-1];
      mul_trk_is_low[i] <= mul_trk_is_low[i-1];
    end
    if (multiplier_valid_input) begin
      mul_trk_tag[0]    <= i_rs_issue.rob_tag;
      mul_trk_is_low[0] <= is_mul_low;
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
  // No combinational "same-cycle partial flush of the tail" gate here. A
  // young result pushed during a flush cycle is marked flushed in the FIFO
  // at the same cycle's always_ff (push branch below), so it never gets
  // presented to the adapter at T+1. At T the adapter filters via its own
  // partial_flush_input (direct i_flush_en), covering the flush cycle
  // itself. This keeps is_younger out of mul_fifo_count.CE's cone.
  logic mul_completing;
  assign mul_completing = mul_trk_valid[MulPipeDepth-1] && !mul_trk_flushed[MulPipeDepth-1];

  // Result selection from tracker tail (MUL low vs MULH/MULHSU/MULHU high)
  logic [31:0] mul_result_32;
  assign mul_result_32 = mul_trk_is_low[MulPipeDepth-1] ? mul_product[31:0] : mul_product[63:32];
  assign mul_fifo_value_wr_data = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, mul_result_32};

  // Same-cycle flush of a young entry being pushed — compute once and reuse
  // for the push-branch of fifo_flushed[wr_ptr].D.
  logic mul_push_entry_flush_young;
  assign mul_push_entry_flush_young = i_flush_en && is_younger(
      mul_trk_tag[MulPipeDepth-1], i_flush_tag, i_rob_head_tag
  );

  // FIFO pop: adapter consumed, or head is already marked flushed (auto-drain).
  // Uses only the registered mul_fifo_flushed bit — no combinational
  // is_younger / flush_tag dependency in the pop → count.CE cone.
  logic mul_fifo_pop;
  logic mul_fifo_head_flushed;
  assign mul_fifo_head_flushed = mul_fifo_valid[mul_fifo_rd_ptr] &&
                                 mul_fifo_flushed[mul_fifo_rd_ptr];
  assign mul_fifo_pop = (mul_fifo_count != '0) && (i_mul_accepted || mul_fifo_head_flushed);

  // FIFO push: multiplier completes with non-flushed entry.
  //
  // We deliberately keep this gating as minimal as the divider side (no
  // dependence on i_mul_accepted) so that the flush net does not fan into
  // the mul_fifo_* register cone. A same-cycle bypass that avoided the
  // 1-cycle FIFO turnaround was tried, but it created an 18-level
  // combinational path from the mispredict_recovery_pending flop through
  // the wrapper's mul_result_accepted (which depends on speculative_flush_all)
  // back into mul_fifo_push, producing −0.7 ns of extra WNS on top of the
  // shared flush→FIFO cone. Accept the 1-cycle turnaround on Bench 3 rather
  // than pay that timing cost.
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

      // Push. Newly-pushed entry inherits the tracker-tail's flushed bit and
      // picks up same-cycle partial-flush against its tag — so we don't need
      // a separate combinational suppression on the push / completion path.
      if (mul_fifo_push) begin
        mul_fifo_tag[mul_fifo_wr_ptr] <= mul_trk_tag[MulPipeDepth-1];
        mul_fifo_valid[mul_fifo_wr_ptr] <= 1'b1;
        mul_fifo_flushed[mul_fifo_wr_ptr] <=
            mul_trk_flushed[MulPipeDepth-1] || mul_push_entry_flush_young;
        mul_fifo_wr_ptr <= mul_fifo_wr_ptr + 1;
      end

      // Pop — advance rd_ptr only. mul_fifo_valid / mul_fifo_flushed stay
      // set; they are only consulted gated by mul_fifo_count (authoritative
      // occupancy) and get overwritten on the next push to this slot, so
      // clearing them here would only drag i_mul_accepted (which depends on
      // the cross-FU arbiter grant cone) into the fifo register next-state.
      if (mul_fifo_pop) begin
        mul_fifo_rd_ptr <= mul_fifo_rd_ptr + 1;
      end

      // Update count
      case ({
        mul_fifo_push, mul_fifo_pop
      })
        2'b10:   mul_fifo_count <= mul_fifo_count + 1;
        2'b01:   mul_fifo_count <= mul_fifo_count - 1;
        default: mul_fifo_count <= mul_fifo_count;  // 2'b00 or 2'b11
      endcase
    end
  end

  // FIFO head output drives o_mul_fu_complete. Uses only the registered
  // mul_fifo_flushed bit — no combinational is_younger in the output cone.
  // During the flush cycle itself the adapter's own partial_flush_input
  // filter (direct i_flush_en) catches younger results; by the next cycle,
  // the always_ff marking pass has set the flushed bit on any young entry.
  always_comb begin
    if (mul_fifo_count != '0 && !mul_fifo_flushed[mul_fifo_rd_ptr]) begin
      o_mul_fu_complete.valid     = 1'b1;
      o_mul_fu_complete.tag       = mul_fifo_tag[mul_fifo_rd_ptr];
      o_mul_fu_complete.value     = mul_fifo_value_rd;
      o_mul_fu_complete.exception = 1'b0;
      o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end else begin
      o_mul_fu_complete.valid     = 1'b0;
      o_mul_fu_complete.tag       = '0;
      o_mul_fu_complete.value     = '0;
      o_mul_fu_complete.exception = 1'b0;
      o_mul_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_mul_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end
  end

  // MUL busy (credit-based to prevent FIFO overflow)
  logic [5:0] mul_total_occupancy;
  assign mul_total_occupancy = 6'(mul_fifo_count) + 6'(mul_inflight_count);
  assign mul_busy = mul_total_occupancy >= 6'(MulFifoDepth);

  // ---------------------------------------------------------------------------
  // Divider path — pipelined with shift register + result FIFO
  // ---------------------------------------------------------------------------
  logic div_is_signed;
  assign div_is_signed = (i_rs_issue.op == riscv_pkg::DIV) || (i_rs_issue.op == riscv_pkg::REM);

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

  // Individual flat arrays avoid less portable unpacked-array-of-packed-struct storage.
  logic            div_trk_valid  [DivPipeDepth];
  logic [TagW-1:0] div_trk_tag    [DivPipeDepth];
  logic            div_trk_is_rem [DivPipeDepth];  // 1 = REM/REMU, 0 = DIV/DIVU
  logic            div_trk_flushed[DivPipeDepth];

  always_ff @(posedge i_clk) begin
    // --- Control: valid + flushed (with reset) ---
    if (!i_rst_n) begin
      for (int i = 0; i < DivPipeDepth; i++) begin
        div_trk_valid[i]   <= 1'b0;
        div_trk_flushed[i] <= 1'b0;
      end
    end else if (i_flush) begin
      for (int i = 0; i < DivPipeDepth; i++) begin
        div_trk_valid[i] <= 1'b0;
      end
    end else begin
      // Shift control stages
      for (int i = DivPipeDepth - 1; i >= 1; i--) begin
        div_trk_valid[i] <= div_trk_valid[i-1];
        if (div_trk_valid[i-1] && i_flush_en && is_younger(
                div_trk_tag[i-1], i_flush_tag, i_rob_head_tag
            ))
          div_trk_flushed[i] <= 1'b1;
        else div_trk_flushed[i] <= div_trk_flushed[i-1];
      end
      // Stage 0 control
      if (divider_valid_input) begin
        div_trk_valid[0] <= 1'b1;
        if (i_flush_en && is_younger(i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag))
          div_trk_flushed[0] <= 1'b1;
        else div_trk_flushed[0] <= 1'b0;
      end else begin
        div_trk_valid[0]   <= 1'b0;
        div_trk_flushed[0] <= 1'b0;
      end
    end
  end

  // --- Data: tag + is_rem shift register (no reset) ---
  always_ff @(posedge i_clk) begin
    for (int i = DivPipeDepth - 1; i >= 1; i--) begin
      div_trk_tag[i]    <= div_trk_tag[i-1];
      div_trk_is_rem[i] <= div_trk_is_rem[i-1];
    end
    if (divider_valid_input) begin
      div_trk_tag[0]    <= i_rs_issue.rob_tag;
      div_trk_is_rem[0] <= (i_rs_issue.op == riscv_pkg::REM) ||
                           (i_rs_issue.op == riscv_pkg::REMU);
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
  // DIV result FIFO (4 entries, FF control with LUTRAM payload)
  // ---------------------------------------------------------------------------
  localparam int unsigned FifoDepth = 4;

  // Individual flat arrays for FIFO data; no struct arrays in the storage path.
  logic [               TagW-1:0] div_fifo_tag           [FifoDepth];
  logic [    riscv_pkg::FLEN-1:0] div_fifo_value_rd;
  logic [    riscv_pkg::FLEN-1:0] div_fifo_value_wr_data;
  logic [          FifoDepth-1:0] div_fifo_valid;
  logic [          FifoDepth-1:0] div_fifo_flushed;
  logic [$clog2(FifoDepth+1)-1:0] fifo_count;
  logic                           fifo_push;

  // Write pointer and read pointer
  logic [  $clog2(FifoDepth)-1:0] fifo_wr_ptr;
  logic [  $clog2(FifoDepth)-1:0] fifo_rd_ptr;

  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(FifoDepth)),
      .DATA_WIDTH(riscv_pkg::FLEN)
  ) u_div_fifo_value (
      .i_clk,
      .i_write_enable (fifo_push),
      .i_write_address(fifo_wr_ptr),
      .i_write_data   (div_fifo_value_wr_data),
      .i_read_address (fifo_rd_ptr),
      .o_read_data    (div_fifo_value_rd)
  );

  // Divider completion: build fu_complete_t from tracker tail + divider outputs.
  // Same strategy as mul_completing above — no combinational tail partial flush.
  logic div_completing;
  assign div_completing = div_trk_valid[DivPipeDepth-1] && !div_trk_flushed[DivPipeDepth-1];

  // Result selection from tracker tail
  logic [31:0] div_result_32;
  assign div_result_32 = div_trk_is_rem[DivPipeDepth-1] ? div_remainder : div_quotient;
  assign div_fifo_value_wr_data = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, div_result_32};

  // Same-cycle flush of a young entry being pushed to the div FIFO.
  logic div_push_entry_flush_young;
  assign div_push_entry_flush_young = i_flush_en && is_younger(
      div_trk_tag[DivPipeDepth-1], i_flush_tag, i_rob_head_tag
  );

  // FIFO pop: adapter consumed, or head is already marked flushed (auto-drain).
  logic fifo_pop;
  logic fifo_head_flushed;
  assign fifo_head_flushed = div_fifo_valid[fifo_rd_ptr] && div_fifo_flushed[fifo_rd_ptr];
  assign fifo_pop = (fifo_count != '0) && (i_div_accepted || fifo_head_flushed);

  // FIFO push: divider completes with non-flushed entry
  assign fifo_push = div_completing;

  always_ff @(posedge i_clk) begin
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

      // Push. Newly-pushed entry inherits the tracker-tail's flushed bit and
      // picks up same-cycle partial-flush against its tag.
      if (fifo_push) begin
        div_fifo_tag[fifo_wr_ptr] <= div_trk_tag[DivPipeDepth-1];
        div_fifo_valid[fifo_wr_ptr] <= 1'b1;
        div_fifo_flushed[fifo_wr_ptr] <=
            div_trk_flushed[DivPipeDepth-1] || div_push_entry_flush_young;
        fifo_wr_ptr <= fifo_wr_ptr + 1;
      end

      // Pop — advance rd_ptr only. div_fifo_valid / div_fifo_flushed stay
      // set; they are only consulted gated by fifo_count (authoritative
      // occupancy) and get overwritten on the next push to this slot, so
      // clearing them here would only drag i_div_accepted (which depends on
      // the cross-FU arbiter grant cone) into the fifo register next-state.
      if (fifo_pop) begin
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

  // FIFO head output drives o_div_fu_complete (registered flushed bit only).
  always_comb begin
    if (fifo_count != '0 && !div_fifo_flushed[fifo_rd_ptr]) begin
      o_div_fu_complete.valid     = 1'b1;
      o_div_fu_complete.tag       = div_fifo_tag[fifo_rd_ptr];
      o_div_fu_complete.value     = div_fifo_value_rd;
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
  // Busy signal: credit-based to prevent FIFO overflow (MUL or DIV)
  // ---------------------------------------------------------------------------
  logic [5:0] div_total_occupancy;
  assign div_total_occupancy = 6'(fifo_count) + 6'(div_inflight_count);
  assign div_busy = div_total_occupancy >= 6'(FifoDepth);
  assign o_fu_busy = mul_busy | div_busy;

endmodule : int_muldiv_shim
