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
 * FP shim (CDB slot 4, FP_RS)
 *
 * Starts each FP_RS issue on fp_engine, which runs every FP compute operation
 * one at a time, and packs the engine's result into fu_complete_t for the CDB
 * adapter. One tag register tracks the operation in the engine. o_fu_busy is
 * high whenever the engine is not idle, its result cycle included, and the
 * wrapper also stops FP_RS while the adapter holds a result, so the engine's
 * one-cycle result always finds the adapter free.
 *
 * A full flush, or a partial flush that covers the operation (the ROB-age
 * compare the rest of the back end uses), kills it in the engine, which is
 * idle again on the next cycle. An issue the same flush covers never starts.
 * A flush in the result cycle itself is left to the adapter, which sees the
 * same flush.
 */
module fp_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FP_RS (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // The engine holds an operation
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial): kill an operation younger than the tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);

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

  logic eng_idle, eng_done;
  logic [riscv_pkg::FLEN-1:0] eng_result;
  riscv_pkg::fp_flags_t eng_flags;
  logic [TagW-1:0] tag_q;

  logic launch_flushed, start, kill;
  assign launch_flushed = i_flush || (i_flush_en && is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  ));
  assign start = i_rs_issue.valid && eng_idle && !launch_flushed;
  assign kill = !eng_idle && (i_flush || (i_flush_en && is_younger(
      tag_q, i_flush_tag, i_rob_head_tag
  )));

  always_ff @(posedge i_clk) begin
    if (start) tag_q <= i_rs_issue.rob_tag;
  end

`ifdef FORMAL
  // The shim proof covers tag and flush control. The engine becomes a model
  // that completes an arbitrary number of cycles after its start (its real
  // latency depends on the operation and the operands) and returns to idle on
  // a kill, which keeps completions reachable at small bounded depths.
  (* anyseq *) logic f_eng_finish;
  (* anyseq *) logic [riscv_pkg::FLEN-1:0] f_eng_result;
  (* anyseq *) logic [4:0] f_eng_flags;
  logic f_eng_busy, f_eng_done;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (kill) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (start) begin
      f_eng_busy <= 1'b1;
    end else if (f_eng_done) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (f_eng_busy && f_eng_finish) begin
      f_eng_done <= 1'b1;
    end
  end
  assign eng_idle   = !f_eng_busy;
  assign eng_done   = f_eng_done;
  assign eng_result = f_eng_result;
  assign eng_flags  = riscv_pkg::fp_flags_t'(f_eng_flags);
`else
  fp_engine u_engine (
      .i_clk   (i_clk),
      .i_rst_n (i_rst_n),
      .i_start (start),
      .i_op    (i_rs_issue.op),
      .i_rm    (i_rs_issue.rm),
      .i_src1  (i_rs_issue.src1_value),
      .i_src2  (i_rs_issue.src2_value),
      .i_src3  (i_rs_issue.src3_value),
      .i_kill  (kill),
      .o_idle  (eng_idle),
      .o_done  (eng_done),
      .o_result(eng_result),
      .o_flags (eng_flags)
  );
`endif

  assign o_fu_busy = !eng_idle;

  always_comb begin
    o_fu_complete.valid     = eng_done;
    o_fu_complete.tag       = tag_q;
    o_fu_complete.value     = eng_result;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = eng_flags;
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The RS retires its entry on the issue cycle, so an issue the engine cannot
  // take would be lost. FP_RS's ready input includes !o_fu_busy, and the RS
  // presents an issue only with ready high, so a hit here is a real hazard.
  always @(posedge i_clk) begin
    if (i_rst_n && i_rs_issue.valid && !eng_idle) begin
      $error("fp_shim: issue of tag %0d while the engine is busy", i_rs_issue.rob_tag);
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

  // The issue contract: FP_RS presents an issue only while the shim is not
  // busy (its ready input includes !o_fu_busy).
  always_comb begin
    if (i_rst_n) assume (!i_rs_issue.valid || !o_fu_busy);
  end

  // Busy exactly while the engine holds an operation, result cycle included,
  // and a result only while busy.
  always_comb begin
    if (i_rst_n) begin
      p_busy_is_engine : assert (o_fu_busy == f_eng_busy);
      p_complete_only_when_busy : assert (!o_fu_complete.valid || o_fu_busy);
    end
  end

  // A kill leaves the engine idle on the next cycle, so FP_RS may issue again.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n) && $past(kill)) begin
      p_kill_frees_engine : assert (!o_fu_busy);
    end
  end

  // ---------------------------------------------------------------------------
  // Flushed-tag discipline: once a flush squashes the watched operation, its
  // tag does not appear on o_fu_complete again until a new operation starts
  // with the same tag value (a reallocated ROB entry). The ROB and RS cannot
  // tell a late result for a squashed operation from one for a reallocated
  // tag (tomasulo README, "CDB priority and tag reuse"). The proof tracks one
  // arbitrary (anyconst) tag.
  // ---------------------------------------------------------------------------
  (* anyconst *) logic [TagW-1:0] f_watch_tag;

  logic f_watch_held;  // the watched tag is the operation in the engine
  assign f_watch_held = o_fu_busy && (tag_q == f_watch_tag);

  logic f_watch_issue;
  assign f_watch_issue = i_rs_issue.valid && (i_rs_issue.rob_tag == f_watch_tag);

  logic f_watch_squashed_now;
  assign f_watch_squashed_now = (f_watch_held || f_watch_issue) &&
      (i_flush || (i_flush_en && is_younger(
      f_watch_tag, i_flush_tag, i_rob_head_tag
  )));

  logic f_watch_dead_q;
  initial f_watch_dead_q = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_watch_dead_q <= 1'b0;
    else if (f_watch_squashed_now) f_watch_dead_q <= 1'b1;
    else if (start && (i_rs_issue.rob_tag == f_watch_tag)) f_watch_dead_q <= 1'b0;
  end

  // After the squash, the squashed operation never completes (until the tag
  // is reused by a new start).
  always_comb begin
    if (i_rst_n && f_watch_dead_q && o_fu_complete.valid) begin
      p_no_stale_complete : assert (o_fu_complete.tag != f_watch_tag);
    end
  end

  // A completion carries the tag of the operation that started last.
  logic [TagW-1:0] f_started_tag;
  always @(posedge i_clk) begin
    if (start) f_started_tag <= i_rs_issue.rob_tag;
  end
  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_complete_tag : assert (o_fu_complete.tag == f_started_tag);
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_complete : cover (o_fu_complete.valid);
      cover_kill : cover (kill);
      cover_launch_flushed : cover (i_rs_issue.valid && launch_flushed);
      cover_watch_dead_then_reused :
      cover (f_watch_dead_q && start && (i_rs_issue.rob_tag == f_watch_tag));
    end
  end

`endif  // FORMAL

endmodule : fp_shim
