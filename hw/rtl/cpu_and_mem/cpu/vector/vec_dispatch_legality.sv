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
  Registered vector arithmetic legality for the instruction at the head of
  the decoded queue, under the vtype the tracker holds for it. cpu_ooo holds
  vector arithmetic at dispatch until o_ready is set; dispatch then uses
  o_illegal, a register, in the ROB allocation's legality fault.

  vec_arith_legality runs from registers to one register: the queue's
  registered head shadow (slot 1's instruction) and the tracker's outputs.
  A head that was valid and neither popped nor flushed in the previous cycle
  holds the same instruction, and the tracked vtype changes only on an
  allocation, on a checkpoint restore (which comes with a queue flush) or by
  becoming unknown. So while o_ready is set and the vtype is known, o_illegal
  is the legality of the head under the vtype in effect (the local proof
  below states this under those two conditions; cpu_ooo checks it at every
  vector arithmetic allocation in simulation). Vector arithmetic therefore
  takes one more cycle at the queue head; other instructions do not wait.
*/
module vec_dispatch_legality (
    input  logic        i_clk,
    input  logic        i_rst,
    input  logic        i_head_valid,   // the decoded queue offers a bundle
    input  logic [31:0] i_head_insn,    // slot 1's instruction from the head shadow
    input  logic [ 8:0] i_vtype,        // tracked {vill, vtype}
    input  logic        i_vtype_valid,
    input  logic        i_pop,          // the head bundle allocates this cycle
    input  logic        i_flush,        // the queue is flushed this cycle
    output logic        o_ready,
    output logic        o_illegal
);

  logic illegal;
  vec_arith_legality u_legality (
      .i_vtype  (i_vtype),
      .i_insn   (i_head_insn),
      .o_illegal(illegal)
  );

  always_ff @(posedge i_clk) begin
    o_illegal <= illegal;
    if (i_rst) o_ready <= 1'b0;
    else o_ready <= i_head_valid && i_vtype_valid && !i_pop && !i_flush;
  end

`ifdef VEC_DISPATCH_LEGALITY_LOCAL_PROOF
  // The decoded queue keeps an unpopped, unflushed head, and the tracker
  // keeps a known vtype without an allocation or restore (a restore always
  // comes with the flush). Under those contracts the registered result is
  // the head's legality under the current vtype whenever o_ready is set.
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb begin
    if (!f_past_valid) assume (i_rst);
  end
  always_ff @(posedge i_clk) begin
    if (f_past_valid && !$past(i_rst) && $past(i_head_valid && !i_pop && !i_flush)) begin
      assume (i_head_valid);
      assume (i_head_insn == $past(i_head_insn));
    end
    if (f_past_valid && !$past(
            i_rst
        ) && $past(
            i_vtype_valid && !i_pop && !i_flush
        ) && i_vtype_valid)
      assume (i_vtype == $past(i_vtype));
  end
  always_comb begin
    if (f_past_valid && o_ready && i_vtype_valid) begin
      p_registered_legality_current :
      assert (o_illegal == riscv_pkg::vector_arith_illegal(i_vtype, i_head_insn));
    end
    if (f_past_valid) begin
      cover_ready_illegal : cover (o_ready && i_vtype_valid && o_illegal);
      cover_ready_legal : cover (o_ready && i_vtype_valid && !o_illegal);
    end
  end
`endif

endmodule
