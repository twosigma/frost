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

// Two ordered accepted stores. Readiness reserves room for the next cycle's
// registered write pulse, including the write arriving in this cycle.
module coherence_store_buffer #(
    parameter int unsigned WIDTH = 8
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_push,
    input logic [WIDTH-1:0] i_payload,
    input logic i_pop,
    output logic o_ready,
    output logic o_done,
    output logic o_head_valid,
    output logic o_tail_valid,
    output logic [WIDTH-1:0] o_head,
    output logic [WIDTH-1:0] o_tail
);
  assign o_ready = !o_tail_valid && !(o_head_valid && i_push);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_head_valid <= 1'b0;
      o_tail_valid <= 1'b0;
      o_done <= 1'b0;
      o_head <= '0;
      o_tail <= '0;
    end else begin
      o_done <= i_push;
      if (i_pop) begin
        o_head_valid <= o_tail_valid || i_push;
        o_tail_valid <= o_tail_valid && i_push;
        if (o_tail_valid) o_head <= o_tail;
        else if (i_push) o_head <= i_payload;
        if (i_push && o_tail_valid) o_tail <= i_payload;
      end else if (i_push) begin
        o_head_valid <= 1'b1;
        if (o_head_valid) begin
          o_tail_valid <= 1'b1;
          o_tail <= i_payload;
        end else o_head <= i_payload;
      end
    end
  end
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [1:0] f_count_q;
  logic [WIDTH-1:0] f_first_q, f_second_q;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) begin
      f_count_q  <= '0;
      f_first_q  <= '0;
      f_second_q <= '0;
    end else begin
      // The launch promises room one edge before the payload arrives.
      if (i_push) assume (f_past_valid && !$past(i_rst) && $past(o_ready));
      if (i_pop) assume (o_head_valid);
      f_count_q <= f_count_q + 2'(i_push) - 2'(i_pop);
      if (i_pop) f_first_q <= f_second_q;
      if (i_push) begin
        if (f_count_q == 0 || (f_count_q == 1 && i_pop)) f_first_q <= i_payload;
        else f_second_q <= i_payload;
      end
      assert (!o_tail_valid || o_head_valid);
      assert (f_count_q == 2'(o_head_valid) + 2'(o_tail_valid));
      assert (f_count_q <= 2);
      assert (!i_push || !o_tail_valid);
      if (o_head_valid) assert (o_head == f_first_q);
      if (o_tail_valid) assert (o_tail == f_second_q);
      if (f_past_valid && !$past(i_rst)) begin
        assert (o_done == $past(i_push));
        if ($past(o_head_valid && !i_pop)) begin
          assert (o_head_valid);
          assert (o_head == $past(o_head));
        end
        if ($past(i_pop && o_tail_valid)) begin
          assert (o_head_valid);
          assert (o_head == $past(o_tail));
        end
      end
      cover (o_tail_valid);
      cover (i_pop && i_push && o_head_valid);
      cover (o_head_valid && $past(i_pop && o_tail_valid));
      cover (!o_head_valid && $past(i_pop));
    end
  end
`endif
endmodule
