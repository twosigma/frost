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
// ID's output register is the producer; i_advance means it loads a new bundle
// at this edge. The queue accepts each producer image once (consumed_q), even
// while an unrelated front-end stall holds it for several cycles. Packets
// carry no register values: the consumer reads the register files and rename
// state when it dispatches, so renaming sees every older instruction.
//
// o_shadow is a register holding exactly the narrow slice of o_packet the
// consumer sees, bypass included (in cpu_ooo, the bundle's narrow control
// fields, including the register fields that address the RAT and register
// files). It needs the producer register's current value (i_shadow) and its
// next-edge value (i_shadow_next).
module decoded_bundle_queue #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned WIDTH = 32,
    parameter int unsigned SHADOW_WIDTH = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,
    input logic i_advance,
    input logic i_valid,
    input logic [WIDTH-1:0] i_packet,
    input logic [SHADOW_WIDTH-1:0] i_shadow,
    input logic [SHADOW_WIDTH-1:0] i_shadow_next,
    input logic i_indirect,
    input logic i_pop,
    output logic o_full,
    output logic o_valid,
    output logic [WIDTH-1:0] o_packet,
    output logic [SHADOW_WIDTH-1:0] o_shadow,
    output logic o_indirect_pending
);
  localparam int unsigned PtrBits = $clog2(DEPTH);
  logic [WIDTH-1:0] packet_q[DEPTH];
  // Mirror of packet_q[head_q] whenever the queue is nonempty. TIMING:
  // dispatch sees this flop (or the producer's register on the empty bypass)
  // behind one 2:1 mux with a registered select, not a LUTRAM read addressed
  // by head_q. The mirror's D mux is selected by the pop, whose other inputs
  // are registered state and the producer register.
  logic [WIDTH-1:0] head_packet_q;
  logic [WIDTH-1:0] head_packet_if_pop, head_packet_if_hold;
  (* max_fanout = 64 *) logic nonempty_q;
  logic nonempty_next;
  // TIMING: out_shadow_q (o_shadow) goes further than the packet mirror: the
  // consumer's highest-fanout bits start at a flop with no select LUT.
  logic [SHADOW_WIDTH-1:0] shadow_q[DEPTH];
  logic [SHADOW_WIDTH-1:0] head_shadow_q, head_shadow_next, out_shadow_q;
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
  assign o_valid = nonempty_q || input_valid;
  assign o_packet = nonempty_q ? head_packet_q : i_packet;
  assign o_indirect_pending = |(indirect_q & live_q);
  // Full uses registered occupancy only: no dispatch-to-fetch ready path.
  assign accept = input_valid && !o_full && !i_flush;
  assign push = accept && ((count_q != '0) || !i_pop);
  assign pop = i_pop && (count_q != '0);

  // After a pop the next entry is live in the RAM, or it is this cycle's
  // push (count 1), or the queue empties (count 0: the pop consumed the
  // bypassed input, which is not stored, so the mirror is unused). Without
  // a pop, an empty queue can only receive this cycle's push at the head.
  assign head_packet_if_pop = (count_q > (PtrBits + 1)'(1)) ? packet_q[PtrBits'(head_q + 1'b1)] :
      i_packet;
  assign head_packet_if_hold = (count_q == '0) ? i_packet : head_packet_q;
  // The same selection for the shadow slice, then the output-side bypass
  // select one edge early: nonempty_next is nonempty_q's D.
  assign head_shadow_next = i_pop ?
      ((count_q > (PtrBits + 1)'(1)) ? shadow_q[PtrBits'(head_q + 1'b1)] : i_shadow) :
      ((count_q == '0) ? i_shadow : head_shadow_q);
  assign nonempty_next = !(i_rst || i_flush) &&
      ((count_q + (PtrBits + 1)'(push) - (PtrBits + 1)'(pop)) != '0);
  assign o_shadow = out_shadow_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      nonempty_q <= 1'b0;
      live_q <= '0;
      consumed_q <= 1'b0;
    end else begin
      nonempty_q <= nonempty_next;
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
      shadow_q[tail_q]   <= i_shadow;
      indirect_q[tail_q] <= i_indirect;
    end
    // Payload only: nonempty_q qualifies every use, so reset/flush need not.
    head_packet_q <= i_pop ? head_packet_if_pop : head_packet_if_hold;
    head_shadow_q <= head_shadow_next;
    // Unconditional: after reset/flush the queue is empty and the shadow
    // follows the producer register.
    out_shadow_q  <= nonempty_next ? head_shadow_next : i_shadow_next;
  end

`ifndef SYNTHESIS
  // Shadow contract: i_shadow is the producer register whose previous-edge
  // D was i_shadow_next. Given that, o_shadow is exactly o_packet's slice.
  logic shadow_armed_q = 1'b0;
  logic [SHADOW_WIDTH-1:0] shadow_next_q;
  always_ff @(posedge i_clk) begin
    shadow_next_q <= i_shadow_next;
    if (i_rst) shadow_armed_q <= 1'b1;
  end
`ifdef FORMAL
  always_comb begin
    if (shadow_armed_q) begin
      assume (i_shadow == shadow_next_q);
      assert (o_shadow == (nonempty_q ? head_shadow_q : i_shadow));
      // Inductive strengthening: state-only forms of the above, and the
      // harness's shadow/packet tie for every stored copy.
      assert (out_shadow_q == (nonempty_q ? head_shadow_q : shadow_next_q));
      assert (nonempty_q == (count_q != '0));
      if (nonempty_q) begin
        assert (head_shadow_q == shadow_q[head_q]);
        assert (head_shadow_q == head_packet_q[SHADOW_WIDTH-1:0]);
      end
      for (int k = 0; k < DEPTH; k++) begin
        if (live_q[k]) assert (shadow_q[k] == packet_q[k][SHADOW_WIDTH-1:0]);
      end
    end
  end
`else
  // Sampled on the edge: every operand is its pre-edge value.
  always_ff @(posedge i_clk) begin
    if (shadow_armed_q) begin
      assert (i_shadow == shadow_next_q);
      assert (o_shadow == (nonempty_q ? head_shadow_q : i_shadow));
    end
  end
`endif

  always_ff @(posedge i_clk) begin
    if (!i_rst && !i_flush) begin
      assert (count_q <= (PtrBits + 1)'(DEPTH));
      assert (count_q == $countones(live_q));
      assert (nonempty_q == (count_q != '0));
      if (count_q != '0) assert (head_packet_q == packet_q[head_q]);
      if (count_q != '0) assert (head_shadow_q == shadow_q[head_q]);
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
  always_comb assume (i_shadow == i_packet[SHADOW_WIDTH-1:0]);
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
      // The harness ties the shadow to the packet's low bits, so the proven
      // FIFO order carries over to the registered shadow output.
      if (o_valid && shadow_armed_q) assert (o_shadow == o_packet[SHADOW_WIDTH-1:0]);
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
