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

// Fall-through queue between the held ID register and atomic bundle dispatch.
// i_advance replaces the producer's register at this edge. A held image may be
// accepted once, even while an unrelated frontend stall prevents replacement.
// The consumer re-reads architectural operands and rename state at dispatch;
// queued payloads contain decode/prediction metadata, not renamed operands.
module decoded_bundle_queue #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,
    input logic i_advance,
    input logic i_valid,
    input logic [WIDTH-1:0] i_packet,
    input logic i_indirect,
    input logic i_pop,
    output logic o_full,
    output logic o_valid,
    output logic [WIDTH-1:0] o_packet,
    output logic o_indirect_pending
);
  localparam int unsigned PtrBits = $clog2(DEPTH);
  logic [WIDTH-1:0] packet_q[DEPTH];
  logic [DEPTH-1:0] indirect_q, live_q;
  logic [PtrBits-1:0] head_q, tail_q;
  logic [PtrBits:0] count_q;
  logic consumed_q;
  logic input_valid, accept, push, pop;

  initial begin
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "decoded_bundle_queue DEPTH must be a power of two >= 2");
  end

  assign o_full = count_q == (PtrBits + 1)'(DEPTH);
  assign input_valid = i_valid && !consumed_q;
  assign o_valid = (count_q != '0) || input_valid;
  assign o_packet = (count_q != '0) ? packet_q[head_q] : i_packet;
  assign o_indirect_pending = |(indirect_q & live_q);
  // Full uses registered occupancy only: no dispatch-to-fetch ready path.
  assign accept = input_valid && !o_full && !i_flush;
  assign push = accept && ((count_q != '0) || !i_pop);
  assign pop = i_pop && (count_q != '0);

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      live_q <= '0;
      consumed_q <= 1'b0;
    end else begin
      if (i_advance) consumed_q <= 1'b0;
      else if (accept) consumed_q <= 1'b1;
      case ({
        push, pop
      })
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: ;
      endcase
      if (pop) begin
        head_q <= head_q + 1'b1;
        live_q[head_q] <= 1'b0;
      end
      if (push) begin
        tail_q <= tail_q + 1'b1;
        live_q[tail_q] <= 1'b1;
      end
    end
    if (push) begin
      packet_q[tail_q]   <= i_packet;
      indirect_q[tail_q] <= i_indirect;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst && !i_flush) begin
      assert (count_q <= (PtrBits + 1)'(DEPTH));
      assert (count_q == $countones(live_q));
      // Integration contracts: consume only a candidate and never overwrite
      // an unaccepted producer image. Flush/reset independently kill both.
`ifdef FORMAL
      assume (!i_pop || o_valid);
      assume (!i_advance || !input_valid || accept);
`else
      assert (!i_pop || o_valid);
      assert (!i_advance || !input_valid || accept);
`endif
    end
  end
`endif

`ifdef FORMAL
  // Independent linear FIFO, including zero-cycle empty bypass. Comparing
  // every live position makes ordering inductive across pointer wraparound.
  logic [WIDTH-1:0] f_packets[DEPTH];
  logic [DEPTH-1:0] f_indirect;
  logic [PtrBits:0] f_count;
  logic f_consumed;
  logic f_accept;
  assign f_accept = i_valid && !f_consumed && (f_count < DEPTH);
  initial begin
    f_count = '0;
    f_consumed = 1'b0;
  end
  always_comb if ($initstate) assume (i_rst);
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      f_count <= '0;
      f_consumed <= 1'b0;
      f_indirect <= '0;
    end else begin
      assert (count_q == f_count);
      assert (consumed_q == f_consumed);
      assert (o_valid == ((f_count != 0) || (i_valid && !f_consumed)));
      if (o_valid) assert (o_packet == ((f_count != 0) ? f_packets[0] : i_packet));
      assert (o_indirect_pending == |f_indirect);
      for (int k = 0; k < DEPTH; k++) begin
        if (k < f_count) begin
          assert (packet_q[PtrBits'(head_q+k)] == f_packets[k]);
          assert (live_q[PtrBits'(head_q+k)]);
          assert (indirect_q[PtrBits'(head_q+k)] == f_indirect[k]);
        end else assert (!f_indirect[k]);
      end
      assert (tail_q == PtrBits'(head_q + count_q));
      if (i_advance) f_consumed <= 1'b0;
      else if (f_accept) f_consumed <= 1'b1;
      if (i_pop && f_count != 0) begin
        for (int k = 0; k < DEPTH - 1; k++) begin
          f_packets[k]  <= f_packets[k+1];
          f_indirect[k] <= f_indirect[k+1];
        end
        f_indirect[DEPTH-1] <= 1'b0;
      end
      if (f_accept && (f_count != 0 || !i_pop)) begin
        f_packets[f_count-((i_pop && f_count != 0) ? 1 : 0)]  <= i_packet;
        f_indirect[f_count-((i_pop && f_count != 0) ? 1 : 0)] <= i_indirect;
      end
      case ({
        f_accept, i_pop
      })
        2'b10:   f_count <= f_count + 1'b1;
        2'b01:   f_count <= f_count - 1'b1;
        default: ;
      endcase
      cover (o_full);
      cover (count_q == DEPTH - 1 && push && pop);
      cover (i_pop && count_q == 0);
      cover (head_q > tail_q && count_q != 0);
    end
    cover (!i_rst && i_flush && count_q != 0);
  end
`endif
endmodule
