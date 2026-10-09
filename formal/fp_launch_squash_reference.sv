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
 * Launch-gated FP shim reference with the real engine. Keep its behavior
 * independent of the production shim.
 *
 * The engine runs one operation at a time, tracked by tag_q. o_fu_busy stays
 * high through the result cycle. The wrapper also blocks FP_RS while the CDB
 * adapter holds a result, so the engine's one-cycle result finds it free.
 *
 * A full flush, or a partial flush covering the operation's ROB tag, kills
 * it; the engine is idle next cycle. A flushed issue never starts. A flush
 * in the result cycle is handled by the adapter, which sees the same flush.
 */
module fp_launch_squash_reference (
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

  assign o_fu_busy = !eng_idle;

  always_comb begin
    o_fu_complete.valid     = eng_done;
    o_fu_complete.tag       = tag_q;
    o_fu_complete.value     = eng_result;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = eng_flags;
  end



endmodule : fp_launch_squash_reference
