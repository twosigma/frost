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

// Select any wake, even when other live instructions have the same numeric
// tag. Follow its physical FIFO position through arbitrary recovery and stalls.
module fp_forward_fifo_formal (
    input logic clk
);
  localparam int TagWidth = riscv_pkg::ReorderBufferTagWidth;
  typedef logic [TagWidth-1:0] tag_t;
  (* anyseq *) logic launch, accept, choose, full, partial;
  (* anyseq *) tag_t issue_tag, boundary, head;
  (* anyseq *) logic [$clog2(riscv_pkg::FLEN)-1:0] reset_choice;
  logic [$clog2(riscv_pkg::FLEN)-1:0] bit_index;
  logic rst_n = 1'b0;
  always @(posedge clk) begin
    rst_n <= 1'b1;
    if (!rst_n) bit_index <= reset_choice;
  end

  logic busy, wake;
  tag_t wake_tag;
  logic [riscv_pkg::FLEN-1:0] forward_word;
  riscv_pkg::fu_complete_t result;
  riscv_pkg::rs_issue_t issue;
  always_comb begin
    issue = '0;
    issue.valid = launch && !busy;
    issue.rob_tag = issue_tag;
    issue.op = riscv_pkg::FMADD_D;
  end
  fp_shim #(
      .PIPELINE(1),
      .LAUNCH_SQUASH(1)
  ) dut (
      .i_clk(clk),
      .i_rst_n(rst_n),
      .i_rs_issue(issue),
      .o_fu_complete(),
      .o_fu_busy(),
      .o_pipe_complete(result),
      .i_pipe_accepted(accept),
      .o_pipe_busy(busy),
      .o_fwd_wake_valid(wake),
      .o_fwd_wake_tag(wake_tag),
      .o_fwd_value(forward_word),
      .i_flush(full),
      .i_flush_en(partial),
      .i_flush_tag(boundary),
      .i_rob_head_tag(head)
  );

  function automatic logic killed(input tag_t tag);
    killed = full || (partial && tag_t'(tag - head) > tag_t'(boundary - head));
  endfunction
  // Track one selected instance by position, independently of the result's
  // reported tag, valid and payload. A free bit index proves every word bit.
  logic tail_q, queued_q, word_q;
  tag_t tag_q;
  localparam int Depth = 16;
  localparam int PtrWidth = $clog2(Depth);
  localparam int PipeDepth = riscv_pkg::FpPipeDepth;
  logic [$clog2(Depth)-1:0] slot_q;
  logic [$clog2(Depth):0] ahead_q;
  wire pick = choose && wake && !killed(wake_tag) && !tail_q && !queued_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      tail_q   <= 1'b0;
      queued_q <= 1'b0;
    end else begin
      tail_q <= pick;
      if (pick) tag_q <= wake_tag;
      if (killed(tag_q)) queued_q <= 1'b0;
      else if (tail_q) begin
        queued_q <= 1'b1;
        word_q   <= forward_word[bit_index];
        slot_q   <= dut.g_pipe.fifo_wr_ptr;
        ahead_q  <= dut.g_pipe.fifo_count - dut.g_pipe.fifo_pop;
      end else if (queued_q && dut.g_pipe.fifo_pop) begin
        if (ahead_q == 0) queued_q <= 1'b0;
        else ahead_q <= ahead_q - 1'b1;
      end
    end
  end

  wire [PtrWidth-1:0] distance = slot_q - dut.g_pipe.fifo_rd_ptr;
  wire [6:0] occupancy = 7'(dut.g_pipe.fifo_count) + 7'($countones(dut.g_pipe.trk_valid));
  always @(posedge clk)
    if (rst_n) begin
      p_credit : assert (occupancy <= Depth && busy == (occupancy == Depth));
      p_pointers :
      assert (dut.g_pipe.fifo_wr_ptr - dut.g_pipe.fifo_rd_ptr == PtrWidth'(dut.g_pipe.fifo_count));
      if (tail_q)
        p_tail_progress : assert (dut.g_pipe.fifo_push && dut.g_pipe.trk_tag[PipeDepth-1] == tag_q);
      if (queued_q) begin
        p_fifo_position : assert (ahead_q < dut.g_pipe.fifo_count && distance == ahead_q);
        // Every acceptance removes one older entry, even if its tag differs.
        if (accept) p_fifo_service : assert (dut.g_pipe.fifo_pop);
        p_fifo_owned :
        assert (dut.g_pipe.fifo_tag[slot_q] == tag_q && !dut.g_pipe.fifo_flushed[slot_q]);
        p_fifo_keeps_word : assert (dut.g_pipe.u_fifo_payload.ram[slot_q][bit_index] == word_q);
        if (ahead_q == 0 && !killed(tag_q))
          p_head_delivers_offer :
          assert (result.valid && result.tag == tag_q &&
            result.value[bit_index] == word_q && dut.g_pipe.fifo_pop == accept);
      end
    end
endmodule
