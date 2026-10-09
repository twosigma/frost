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

// Fall-through queue from the held ID register to atomic bundle dispatch.
// i_advance loads a new producer bundle at this edge. consumed_q prevents
// accepting a held bundle twice. Packets carry no register values: dispatch
// reads the register files and rename state once older bundles have
// dispatched, so it sees their renames.
//
// o_shadow registers the consumer's narrow slice of o_packet, including the
// empty bypass. i_shadow is the producer's current slice; i_shadow_next is
// its next-edge value. o_shadow_next lets consumers keep same-edge copies.
module decoded_bundle_queue #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned WIDTH = 32,
    parameter int unsigned SHADOW_WIDTH = 1,
    // Apply the producer stall after selecting the next shadow, for timing.
    // The producer supplies both next values and holds when
    // (i_stall_early || i_stall_late) && !i_stall_flush. All STALL_LATE_COPIES
    // bits must agree. i_shadow_next must remain the selected value for the
    // simulation check. Split inputs are unused when this parameter is clear.
    parameter bit SPLIT_SHADOW_STALL = 1'b0,
    parameter int unsigned STALL_LATE_COPIES = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,
    input logic i_advance,
    input logic i_valid,
    input logic [WIDTH-1:0] i_packet,
    input logic [SHADOW_WIDTH-1:0] i_shadow,
    input logic [SHADOW_WIDTH-1:0] i_shadow_next,
    input logic [SHADOW_WIDTH-1:0] i_shadow_next_go,
    input logic [SHADOW_WIDTH-1:0] i_shadow_next_hold,
    input logic i_stall_early,
    input logic [STALL_LATE_COPIES-1:0] i_stall_late,
    input logic i_stall_flush,
    input logic i_indirect,
    input logic i_pop,
    output logic o_full,
    output logic o_valid,
    output logic [WIDTH-1:0] o_packet,
    output logic [SHADOW_WIDTH-1:0] o_shadow,
    output logic [SHADOW_WIDTH-1:0] o_shadow_next,
    output logic o_indirect_pending
);
  localparam int unsigned PtrBits = $clog2(DEPTH);
  logic [WIDTH-1:0] packet_q[DEPTH];
  // Mirror packet_q[head_q] while nonempty, for timing. Load on pop or empty;
  // the load data is independent of pop.
  localparam int unsigned MirrorGroupBits = 128;
  localparam int unsigned MirrorGroups = (WIDTH + MirrorGroupBits - 1) / MirrorGroupBits;
  logic [WIDTH-1:0] head_packet_q;
  logic [WIDTH-1:0] head_packet_load_data;
  (* max_fanout = 64 *) logic nonempty_q;
  logic nonempty_next;
  logic [SHADOW_WIDTH-1:0] shadow_q[DEPTH];
  logic [SHADOW_WIDTH-1:0] head_shadow_q, head_shadow_next;
  // Cap shadow fanout for replication.
  (* max_fanout = 48 *) logic [SHADOW_WIDTH-1:0] out_shadow_q;
  logic [DEPTH-1:0] indirect_q, live_q;
  logic [PtrBits-1:0] head_q, tail_q;
  logic [PtrBits:0] count_q;
  logic consumed_q;
  // Keep the producer-valid term separate for timing.
  (* keep = "true" *) logic input_valid;
  logic accept, push, pop;

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

  // After a pop, read the next stored row when count > 1; otherwise use the
  // producer packet. An empty queue also loads that packet. The mirror is
  // unused when the queue empties or dispatch consumes the empty bypass.
  assign head_packet_load_data = (count_q > (PtrBits + 1)'(1)) ?
      packet_q[PtrBits'(head_q + 1'b1)] : i_packet;
  // The same selection for the shadow slice, then the output-side bypass
  // select one edge early: nonempty_next is nonempty_q's D.
  assign head_shadow_next = i_pop ?
      ((count_q > (PtrBits + 1)'(1)) ? shadow_q[PtrBits'(head_q + 1'b1)] : i_shadow) :
      ((count_q == '0) ? i_shadow : head_shadow_q);
  assign nonempty_next = !(i_rst || i_flush) &&
      ((count_q + (PtrBits + 1)'(push) - (PtrBits + 1)'(pop)) != '0);
  assign o_shadow = out_shadow_q;
  if (SPLIT_SHADOW_STALL) begin : gen_split_shadow_stall
    // Select both next-shadow candidates before applying the stall, for timing.
    (* keep = "true" *)logic [SHADOW_WIDTH-1:0] shadow_next_go;
    (* keep = "true" *)logic [SHADOW_WIDTH-1:0] shadow_next_hold;
    assign shadow_next_go   = nonempty_next ? head_shadow_next : i_shadow_next_go;
    assign shadow_next_hold = nonempty_next ? head_shadow_next : i_shadow_next_hold;
    for (genvar b = 0; b < SHADOW_WIDTH; b++) begin : gen_shadow_stall_bit
      localparam int unsigned LateCopy = (b * STALL_LATE_COPIES) / SHADOW_WIDTH;
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *)
      LUT5 #(
          .INIT(32'hfff10e00)
      ) u_sel (
          .I0(i_stall_late[LateCopy]),
          .I1(i_stall_early),
          .I2(i_stall_flush),
          .I3(shadow_next_hold[b]),
          .I4(shadow_next_go[b]),
          .O (o_shadow_next[b])
      );
`else
      assign o_shadow_next[b] = ((i_stall_late[LateCopy] || i_stall_early) && !i_stall_flush) ?
          shadow_next_hold[b] : shadow_next_go[b];
`endif
    end
`ifndef SYNTHESIS
    always_comb begin
      if (!$isunknown({o_shadow_next, nonempty_next, head_shadow_next, i_shadow_next})) begin
        p_split_shadow_next_exact :
        assert (o_shadow_next == (nonempty_next ? head_shadow_next : i_shadow_next));
      end
    end
`endif
  end else begin : gen_shadow_next
    assign o_shadow_next = nonempty_next ? head_shadow_next : i_shadow_next;
  end

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
    // Write whenever not full. The tail row is then dead, so a write without
    // push remains unused until a later push overwrites it.
    if (!o_full) begin
      packet_q[tail_q]   <= i_packet;
      shadow_q[tail_q]   <= i_shadow;
      indirect_q[tail_q] <= i_indirect;
    end
    head_shadow_q <= head_shadow_next;
    // Unconditional: after reset/flush the queue is empty and the shadow
    // follows the producer register.
    out_shadow_q  <= o_shadow_next;
  end

  // Use one same-edge nonempty_q copy per mirror group, for fanout. Each copy
  // loads nonempty_next. Payload needs no reset or flush because nonempty_q
  // qualifies every use.
  for (genvar g = 0; g < MirrorGroups; g++) begin : gen_head_mirror
    localparam int unsigned Lo = g * MirrorGroupBits;
    localparam int unsigned Bits = ((WIDTH - Lo) < MirrorGroupBits) ? (WIDTH - Lo) :
        MirrorGroupBits;
    (* dont_touch = "true" *) logic nonempty_copy_q;
    always_ff @(posedge i_clk) begin
      nonempty_copy_q <= nonempty_next;
      if (i_pop || !nonempty_copy_q) head_packet_q[Lo+:Bits] <= head_packet_load_data[Lo+:Bits];
    end
`ifndef SYNTHESIS
    // Both registers take nonempty_next, so they agree from the first edge.
    logic copy_armed_q = 1'b0;
    always_ff @(posedge i_clk) begin
      copy_armed_q <= 1'b1;
      if (copy_armed_q) begin
        p_mirror_nonempty_copy_match : assert (nonempty_copy_q == nonempty_q);
      end
    end
`endif
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
      // The harness ties the shadow to the packet's low bits, so FIFO order
      // must also hold for the registered shadow output.
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
