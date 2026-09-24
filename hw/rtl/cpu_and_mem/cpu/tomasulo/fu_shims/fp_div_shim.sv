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
 * One fp_div_sqrt_iter handles FDIV.S, FDIV.D, FSQRT.S and FSQRT.D, one
 * operation at a time: 36 cycles at single precision, 65 at double. The shim
 * holds the ROB tag of the operation in the unit and the result the unit
 * produced, and presents that result until the CDB adapter takes it.
 *
 * Credit gate: o_fu_busy is high whenever the unit holds an operation or the
 * result register is occupied, so an operation is only accepted when both are
 * free, and a finished result always has somewhere to go.
 *
 * Flush: a full flush, or a partial flush whose tag comparison says the
 * operation is younger than the boundary, kills the operation in the unit
 * (i_kill) and clears a held result. A held result the partial flush kills is
 * also suppressed combinationally on the flush cycle, because the clear only
 * lands at the end of it. On the full-flush cycle the held result may still
 * be presented, and the adapter must discard it. The wrapper feeds this shim
 * a flush registered one cycle late, so the FP_DIV adapter never passes a
 * result straight through and holds its full flush one extra cycle (fu_shims
 * README, "Flushes").
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
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // Result consumed by downstream adapter
    input logic i_div_accepted
);

  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned FlagsW = 5;  // fp_flags_t width

  function automatic logic [31:0] unbox32(input logic [FLEN-1:0] value);
    unbox32 = (&value[FLEN-1:32]) ? value[31:0] : riscv_pkg::FpCanonicalNan;
  endfunction

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

  // Operand extraction. Single-precision operands are unboxed into the low
  // half; the unit reads its operands at the width the op selects.
  wire [31:0] src1_s = unbox32(i_rs_issue.src1_value);
  wire [31:0] src2_s = unbox32(i_rs_issue.src2_value);

  logic [63:0] unit_operand_a, unit_operand_b;
  assign unit_operand_a = op_is_double ? i_rs_issue.src1_value : {32'b0, src1_s};
  assign unit_operand_b = op_is_double ? i_rs_issue.src2_value : {32'b0, src2_s};

  // ===========================================================================
  // Occupancy: one operation in the unit, one result waiting for the adapter
  // ===========================================================================
  logic in_flight;
  logic [TagW-1:0] tag_reg;
  logic op_double_reg;

  logic res_valid;
  logic [TagW-1:0] res_tag;
  logic [FLEN-1:0] res_value;
  logic [FlagsW-1:0] res_flags;

  logic div_busy;
  assign div_busy  = in_flight | res_valid;
  assign o_fu_busy = div_busy;

  logic fire;
  assign fire = i_rs_issue.valid & (use_div | use_sqrt) & ~div_busy;

  // ===========================================================================
  // Flush terms
  // ===========================================================================
  logic flush_launching, flush_inflight;
  logic res_partial_flushing, flush_result;

  assign flush_launching = fire & (i_flush | (i_flush_en & is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  )));
  assign flush_inflight = in_flight & (i_flush | (i_flush_en & is_younger(
      tag_reg, i_flush_tag, i_rob_head_tag
  )));
  assign res_partial_flushing = res_valid & i_flush_en & is_younger(
      res_tag, i_flush_tag, i_rob_head_tag
  );
  assign flush_result = res_valid & (i_flush | res_partial_flushing);

  // An operation the flush already covers never starts.
  logic start;
  assign start = fire & ~flush_launching;

  // ===========================================================================
  // Divide/square-root unit
  // ===========================================================================
  logic unit_ready;
  logic unit_valid;
  logic [63:0] unit_result;
  riscv_pkg::fp_flags_t unit_flags;

`ifdef FORMAL
  // The shim proof covers tag, flush and credit control. The arithmetic unit
  // becomes a model that completes at an arbitrary cycle while an operation is
  // in flight, which covers every latency the real unit can produce and keeps
  // completions reachable at small bounded depths.
  (* anyseq *) logic f_unit_done;
  (* anyseq *) logic [63:0] f_unit_result;
  (* anyseq *) logic [FlagsW-1:0] f_unit_flags;

  logic f_unit_busy;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) f_unit_busy <= 1'b0;
    else if (start) f_unit_busy <= 1'b1;
    else if (unit_valid || flush_inflight) f_unit_busy <= 1'b0;
  end

  assign unit_ready  = ~f_unit_busy;
  assign unit_valid  = f_unit_busy & f_unit_done;
  assign unit_result = f_unit_result;
  assign unit_flags  = riscv_pkg::fp_flags_t'(f_unit_flags);
`else
  fp_div_sqrt_iter u_div_sqrt (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(start),
      .i_is_sqrt(use_sqrt),
      .i_is_double(op_is_double),
      .i_operand_a(unit_operand_a),
      .i_operand_b(unit_operand_b),
      .i_rounding_mode(i_rs_issue.rm),
      .i_kill(flush_inflight),
      .o_ready(unit_ready),
      .o_valid(unit_valid),
      .o_result(unit_result),
      .o_flags(unit_flags)
  );
`endif

  // A completion the flush kills on the same cycle is dropped, not captured.
  logic capture;
  assign capture = unit_valid & ~flush_inflight;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      in_flight <= 1'b0;
    end else if (start) begin
      in_flight <= 1'b1;
    end else if (unit_valid || flush_inflight) begin
      in_flight <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (start) begin
      tag_reg       <= i_rs_issue.rob_tag;
      op_double_reg <= op_is_double;
    end
  end

  // ===========================================================================
  // Result register
  // ===========================================================================
  // Nothing new can start while this is occupied, so a capture never collides
  // with a pop.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      res_valid <= 1'b0;
    end else if (capture) begin
      res_valid <= 1'b1;
    end else if (res_valid && (i_div_accepted || flush_result)) begin
      res_valid <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (capture) begin
      res_tag   <= tag_reg;
      res_value <= op_double_reg ? unit_result : {32'hFFFF_FFFF, unit_result[31:0]};
      res_flags <= unit_flags;
    end
  end

  // ===========================================================================
  // Result register drives o_fu_complete
  // ===========================================================================
  always_comb begin
    if (res_valid && !res_partial_flushing) begin
      o_fu_complete.valid     = 1'b1;
      o_fu_complete.tag       = res_tag;
      o_fu_complete.value     = res_value;
      o_fu_complete.exception = 1'b0;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'(res_flags);
    end else begin
      o_fu_complete.valid     = 1'b0;
      o_fu_complete.tag       = '0;
      o_fu_complete.value     = '0;
      o_fu_complete.exception = 1'b0;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // An issue the shim cannot take would be lost: the RS retires its entry on
  // the issue cycle. The wrapper's registered FDIV ready gate rules this out
  // (it requires an idle shim and no issue on the previous cycle), so a hit
  // here is a real hazard, not a back-pressure event.
  always @(posedge i_clk) begin
    if (i_rst_n && i_rs_issue.valid && (use_div || use_sqrt) && div_busy) begin
      $error("fp_div_shim: issue of tag %0d dropped while busy", i_rs_issue.rob_tag);
    end
  end

  // The occupancy mirror must track the unit's own idle state.
  always @(posedge i_clk) begin
    if (i_rst_n && (unit_ready == in_flight)) begin
      $error("fp_div_shim: unit ready %0b disagrees with in_flight %0b", unit_ready, in_flight);
    end
  end
`endif
`endif

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
    if (i_rst_n && o_fu_complete.valid) begin
      p_valid_has_tag : assert (o_fu_complete.tag == res_tag);
    end
  end

  // The credit gate is the whole occupancy model: busy exactly when the unit
  // holds an operation or a result is waiting.
  always_comb begin
    if (i_rst_n) begin
      p_busy_is_occupancy : assert (o_fu_busy == (in_flight | res_valid));
      p_no_output_when_idle : assert (!o_fu_complete.valid || res_valid);
    end
  end

  // A result is never captured on top of one still waiting for the adapter.
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_no_capture_over_result : assert (!(capture && res_valid));
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_fire_div_s : cover (fire && use_div && !op_is_double);
      cover_fire_sqrt_s : cover (fire && use_sqrt && !op_is_double);
      cover_complete : cover (o_fu_complete.valid);
    end
  end

  // ---------------------------------------------------------------------------
  // Flushed-tag discipline: once a flush squashes an in-flight op, its tag does
  // not appear on o_fu_complete again until a new op fires with the same tag
  // value. That new fire means the ROB entry was reallocated and re-dispatched
  // here, so the tag stands for live work again. The ROB and RS rely on every
  // producer following this rule, because they cannot tell a late result for
  // a squashed op from the result of a reallocated tag (tomasulo README, "CDB
  // priority and tag reuse"). The proof tracks one arbitrary (anyconst) tag
  // through the unit and the result register.
  // ---------------------------------------------------------------------------
  (* anyconst *) logic [TagW-1:0] f_watch_tag;

  logic f_watch_inflight;
  always_comb begin
    f_watch_inflight = (in_flight && tag_reg == f_watch_tag) ||
        (res_valid && res_tag == f_watch_tag);
  end

  logic f_watch_fire;
  assign f_watch_fire = fire && (i_rs_issue.rob_tag == f_watch_tag);

  // Flush that squashes the watched tag this cycle, either where it sits in the
  // shim or on the cycle it fires. The age compare mirrors the kill terms the
  // datapath itself uses.
  logic f_watch_squashed_now;
  assign f_watch_squashed_now =
      (i_flush && (f_watch_inflight || f_watch_fire)) ||
      (i_flush_en && (f_watch_inflight || f_watch_fire) &&
       is_younger(
      f_watch_tag, i_flush_tag, i_rob_head_tag
  ));

  // Armed from the cycle after the squash until a new op reuses the tag.
  // A fire on the squash cycle itself is squashed too (fire-cycle marking),
  // so the squash term wins over the disarm.
  logic f_watch_dead_q;
  initial f_watch_dead_q = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_watch_dead_q <= 1'b0;
    else if (f_watch_squashed_now) f_watch_dead_q <= 1'b1;
    else if (f_watch_fire) f_watch_dead_q <= 1'b0;
  end

  // Same cycle: the live kill term (res_partial_flushing) suppresses a
  // partially-flushed result. The full-flush squash cycle is exempt at this
  // boundary: the shim may present the result that cycle, and the adapter
  // must discard it (see the module header).
  always_comb begin
    if (i_rst_n && !i_flush && f_watch_squashed_now && o_fu_complete.valid) begin
      p_no_complete_on_squash_cycle : assert (o_fu_complete.tag != f_watch_tag);
    end
  end

  // After the squash, the squashed op must never complete (until tag reuse).
  always_comb begin
    if (i_rst_n && f_watch_dead_q && !f_watch_fire && o_fu_complete.valid) begin
      p_no_stale_complete : assert (o_fu_complete.tag != f_watch_tag);
    end
  end

  // Reachability: the interesting arcs are exercisable.
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_watch_squashed : cover (f_watch_squashed_now);
      cover_watch_dead_then_reused : cover (f_watch_dead_q && f_watch_fire);
    end
  end

`endif  // FORMAL


endmodule : fp_div_shim
