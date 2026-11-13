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

// One channel between the hart and the cluster memory, with STAGES register
// stages. STAGES = 0 is plain wires for every kind.
//   KIND 0 (always): a pipe of valid and payload. The sender's ready is 1 and
//     the receiver takes every packet the pipe presents; a stopped receiver
//     (i_stopped, after a fatal error) may drop it.
//   KIND 1 (credit): the sender's ready is a local credit count. Packets pass
//     the pipe into a receiver-side buffer of CREDITS entries whose head is
//     the receiver's view (the last pipe register when the buffer is empty);
//     each pop returns a credit through STAGES registers. With CREDITS = 1 the
//     packet waits in the last pipe register itself, so the view is a plain
//     register. The sender's handshake happens when the link takes the packet.
//   KIND 2 (mirror): the sender keeps presenting its offer until its own
//     handshake. The receiver sees a STAGES-cycle-old copy tagged with a
//     sequence bit that toggles on each completed sender handshake; the
//     receiver's handshake returns through STAGES registers as the sender's
//     ready, so the sender's handshake follows the receiver's by STAGES
//     cycles. A copy of an offer already consumed is masked by its sequence
//     bit. The sender must not change or withdraw an offer the receiver may
//     already have consumed.
// Payload registers have no reset and load without an enable, except the
// one-credit kind's last register, which holds while the receiver stalls.
module coherence_link #(
    parameter int unsigned WIDTH = 1,
    parameter int unsigned STAGES = 0,
    parameter int unsigned KIND = 0,
    parameter int unsigned CREDITS = 2 * STAGES + 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stopped,
    input logic i_valid,
    output logic o_ready,
    input logic [WIDTH-1:0] i_payload,
    output logic o_valid,
    input logic i_ready,
    output logic [WIDTH-1:0] o_payload
);
`ifndef SYNTHESIS
`ifdef FORMAL
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  if (KIND > 2 || WIDTH < 1 || (KIND == 1 && STAGES != 0 && CREDITS < 1)) begin : gen_invalid
    initial $fatal(1, "coherence_link: invalid parameters");
  end
  if (STAGES == 0) begin : gen_wires
    assign o_valid   = i_valid;
    assign o_ready   = i_ready;
    assign o_payload = i_payload;
  end else if (KIND == 0) begin : gen_always
    logic [STAGES-1:0] valid_q;
    logic [STAGES*WIDTH-1:0] payload_q;
    always_ff @(posedge i_clk) begin
      valid_q[0] <= !i_rst && i_valid;
      payload_q[0+:WIDTH] <= i_payload;
    end
    for (genvar s = 1; s < STAGES; s++) begin : gen_stage
      always_ff @(posedge i_clk) begin
        valid_q[s] <= !i_rst && valid_q[s-1];
        payload_q[s*WIDTH+:WIDTH] <= payload_q[(s-1)*WIDTH+:WIDTH];
      end
    end
    assign o_ready   = 1'b1;
    assign o_valid   = valid_q[STAGES-1];
    assign o_payload = payload_q[(STAGES-1)*WIDTH+:WIDTH];
`ifndef SYNTHESIS
    always_ff @(posedge i_clk)
      if (sim_reset_seen_q && !i_rst && !i_stopped && o_valid)
        p_link_always_taken : assert (i_ready);
`endif
  end else if (KIND == 1 && CREDITS == 1) begin : gen_credit_one
    logic credit_q, push, pop, hold;
    logic [STAGES-1:0] valid_q, return_q;
    logic [STAGES*WIDTH-1:0] payload_q;
    assign o_ready = credit_q;
    assign push = i_valid && credit_q;
    assign o_valid = valid_q[STAGES-1];
    assign o_payload = payload_q[(STAGES-1)*WIDTH+:WIDTH];
    assign pop = o_valid && i_ready;
    assign hold = o_valid && !i_ready;
    always_ff @(posedge i_clk) begin
      return_q[0] <= !i_rst && pop;
      if (i_rst) credit_q <= 1'b1;
      else if (push) credit_q <= 1'b0;
      else if (return_q[STAGES-1]) credit_q <= 1'b1;
    end
    for (genvar s = 1; s < STAGES; s++) begin : gen_return
      always_ff @(posedge i_clk) return_q[s] <= !i_rst && return_q[s-1];
    end
    if (STAGES == 1) begin : gen_one_stage
      always_ff @(posedge i_clk) begin
        valid_q[0] <= !i_rst && (hold || push);
        if (!hold) payload_q[0+:WIDTH] <= i_payload;
      end
    end else begin : gen_stages
      always_ff @(posedge i_clk) begin
        valid_q[0] <= !i_rst && push;
        payload_q[0+:WIDTH] <= i_payload;
        valid_q[STAGES-1] <= !i_rst && (hold || valid_q[STAGES-2]);
        if (!hold) payload_q[(STAGES-1)*WIDTH+:WIDTH] <= payload_q[(STAGES-2)*WIDTH+:WIDTH];
      end
      for (genvar s = 1; s + 1 < STAGES; s++) begin : gen_middle
        always_ff @(posedge i_clk) begin
          valid_q[s] <= !i_rst && valid_q[s-1];
          payload_q[s*WIDTH+:WIDTH] <= payload_q[(s-1)*WIDTH+:WIDTH];
        end
      end
    end
`ifndef SYNTHESIS
    // One packet at most is in the link: a held credit, a packet in the pipe
    // or the view, or a pop returning.
    always_ff @(posedge i_clk)
      if (sim_reset_seen_q && !i_rst)
        p_link_one_credit :
        assert (int'(credit_q) + $countones(valid_q) + $countones(return_q) == 1);
`endif
  end else if (KIND == 1) begin : gen_credit
    localparam int unsigned CountBits = $clog2(CREDITS + 1);
    localparam int unsigned IndexBits = CREDITS > 1 ? $clog2(CREDITS) : 1;
    logic [CountBits-1:0] credits_q, count_q;
    logic [STAGES-1:0] valid_q, return_q;
    logic [ STAGES*WIDTH-1:0] payload_q;
    logic [CREDITS*WIDTH-1:0] buffer_q;
    logic [IndexBits-1:0] head_q, tail_q;
    logic push, arrive, pop, store, unload;
    logic [WIDTH-1:0] head_payload;
    always_comb begin
      head_payload = '0;
      for (int index = 0; index < int'(CREDITS); index++)
      if (head_q == IndexBits'(index)) head_payload = buffer_q[index*WIDTH+:WIDTH];
    end
    assign o_ready = credits_q != 0;
    assign push = i_valid && o_ready;
    assign arrive = valid_q[STAGES-1];
    assign o_valid = count_q != 0 || arrive;
    assign o_payload = count_q != 0 ? head_payload : payload_q[(STAGES-1)*WIDTH+:WIDTH];
    assign pop = o_valid && i_ready;
    // An arrival is stored unless an empty buffer passes it straight through.
    assign store = arrive && !(count_q == 0 && pop);
    assign unload = pop && count_q != 0;
    always_ff @(posedge i_clk) begin
      valid_q[0] <= !i_rst && push;
      payload_q[0+:WIDTH] <= i_payload;
      return_q[0] <= !i_rst && pop;
      for (int index = 0; index < int'(CREDITS); index++)
      if (store && tail_q == IndexBits'(index))
        buffer_q[index*WIDTH+:WIDTH] <= payload_q[(STAGES-1)*WIDTH+:WIDTH];
      if (i_rst) begin
        credits_q <= CountBits'(CREDITS);
        head_q <= '0;
        tail_q <= '0;
        count_q <= '0;
      end else begin
        credits_q <= credits_q - CountBits'(push) + CountBits'(return_q[STAGES-1]);
        if (store) tail_q <= tail_q == IndexBits'(CREDITS - 1) ? '0 : tail_q + 1'b1;
        if (unload) head_q <= head_q == IndexBits'(CREDITS - 1) ? '0 : head_q + 1'b1;
        count_q <= count_q + CountBits'(store) - CountBits'(unload);
      end
    end
    for (genvar s = 1; s < STAGES; s++) begin : gen_stage
      always_ff @(posedge i_clk) begin
        valid_q[s] <= !i_rst && valid_q[s-1];
        payload_q[s*WIDTH+:WIDTH] <= payload_q[(s-1)*WIDTH+:WIDTH];
        return_q[s] <= !i_rst && return_q[s-1];
      end
    end
`ifndef SYNTHESIS
    // Credits held, packets in flight, buffered and credits returning add up
    // to CREDITS, so no store meets a full buffer.
    always_ff @(posedge i_clk)
      if (sim_reset_seen_q && !i_rst) begin
        p_link_credit_sum :
        assert (int'(credits_q) + $countones(
            valid_q
        ) + int'(count_q) + $countones(
            return_q
        ) == int'(CREDITS));
        if (store) p_link_credit_room : assert (int'(count_q) < int'(CREDITS) || unload);
      end
`endif
  end else begin : gen_mirror
    logic seq_q, consumed_q, pop;
    logic [STAGES-1:0] valid_q, seq_stage_q, return_q;
    logic [STAGES*WIDTH-1:0] payload_q;
    always_ff @(posedge i_clk) begin
      valid_q[0]          <= !i_rst && i_valid;
      seq_stage_q[0]      <= seq_q;
      payload_q[0+:WIDTH] <= i_payload;
      return_q[0]         <= !i_rst && pop;
      if (i_rst) begin
        seq_q <= 1'b0;
        consumed_q <= 1'b1;
      end else begin
        if (i_valid && o_ready) seq_q <= !seq_q;
        if (pop) consumed_q <= seq_stage_q[STAGES-1];
      end
    end
    for (genvar s = 1; s < STAGES; s++) begin : gen_stage
      always_ff @(posedge i_clk) begin
        valid_q[s]                <= !i_rst && valid_q[s-1];
        seq_stage_q[s]            <= seq_stage_q[s-1];
        payload_q[s*WIDTH+:WIDTH] <= payload_q[(s-1)*WIDTH+:WIDTH];
        return_q[s]               <= !i_rst && return_q[s-1];
      end
    end
    assign o_valid = valid_q[STAGES-1] && seq_stage_q[STAGES-1] != consumed_q;
    assign o_payload = payload_q[(STAGES-1)*WIDTH+:WIDTH];
    assign pop = o_valid && i_ready;
    assign o_ready = return_q[STAGES-1];
`ifndef SYNTHESIS
    // When the consumption returns, the sender still presents the offer the
    // receiver consumed.
    logic [STAGES*WIDTH-1:0] consumed_payload_q;
    always_ff @(posedge i_clk) begin
      consumed_payload_q[0+:WIDTH] <= payload_q[(STAGES-1)*WIDTH+:WIDTH];
      for (int s = 1; s < STAGES; s++)
      consumed_payload_q[s*WIDTH+:WIDTH] <= consumed_payload_q[(s-1)*WIDTH+:WIDTH];
    end
    always_ff @(posedge i_clk)
      if (sim_reset_seen_q && !i_rst && o_ready) begin
        p_link_mirror_held : assert (i_valid);
        p_link_mirror_same : assert (i_payload == consumed_payload_q[(STAGES-1)*WIDTH+:WIDTH]);
      end
`endif
  end
`ifdef COHERENCE_LINK_PROOF
  // Stand-alone proof (formal/coherence_link.sby): the sender holds every
  // offer until its handshake; an always-kind receiver takes every packet.
  logic f_past_valid = 1'b0;
  logic f_past_offer = 1'b0;
  logic [WIDTH-1:0] f_past_payload;
  always_ff @(posedge i_clk) begin
    f_past_valid   <= 1'b1;
    f_past_offer   <= !i_rst && i_valid && !o_ready;
    f_past_payload <= i_payload;
  end
  always_comb begin
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && f_past_offer) begin
      assume (i_valid);
      assume (i_payload == f_past_payload);
    end
    if (KIND == 0 && STAGES != 0 && o_valid) assume (i_ready);
  end
  if (STAGES == 0) begin : gen_zero_proof
    // Zero stages: the link is wires.
    always_comb begin
      p_zero_valid : assert (o_valid == i_valid);
      p_zero_ready : assert (o_ready == i_ready);
      p_zero_payload : assert (o_payload == i_payload);
    end
  end else begin : gen_order_proof
    // Conservation and order: the k-th packet the receiver takes is the k-th
    // packet the sender handed over, with its payload, for an arbitrary k. For
    // the mirror kind, the k-th sender handshake carries the k-th consumed
    // payload.
    localparam int unsigned CountBits = 6;
    (* anyconst *) logic [CountBits-1:0] f_index;
    logic [CountBits-1:0] f_sent_q, f_taken_q, f_done_q;
    logic [WIDTH-1:0] f_payload_q;
    logic f_have_q;
    logic [STAGES-1:0] f_handshake_q;
    wire f_take = o_valid && i_ready;
    wire f_done = i_valid && o_ready;
    wire f_send = KIND == 2 ? f_take : f_done;
    wire [WIDTH-1:0] f_send_payload = KIND == 2 ? o_payload : i_payload;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        f_sent_q  <= '0;
        f_taken_q <= '0;
        f_done_q  <= '0;
        f_have_q  <= 1'b0;
      end else begin
        if (f_send) f_sent_q <= f_sent_q + 1'b1;
        if (f_take) f_taken_q <= f_taken_q + 1'b1;
        if (f_done) f_done_q <= f_done_q + 1'b1;
        if (f_send && f_sent_q == f_index) begin
          f_have_q <= 1'b1;
          f_payload_q <= f_send_payload;
        end
      end
      f_handshake_q[0] <= !i_rst && (KIND == 2 ? f_take : f_done);
      for (int s = 1; s < STAGES; s++) f_handshake_q[s] <= !i_rst && f_handshake_q[s-1];
    end
    always_comb
      if (f_past_valid && !i_rst) begin
        if (KIND != 2 && f_take && f_taken_q == f_index) begin
          p_order_have : assert (f_have_q);
          p_order_payload : assert (o_payload == f_payload_q);
        end
        if (KIND == 0) p_always_latency : assert (o_valid == f_handshake_q[STAGES-1]);
        if (KIND == 2) begin
          // The sender's handshake follows the receiver's by exactly STAGES
          // cycles, on the payload consumed, and no copy is consumed twice.
          p_mirror_latency : assert (o_ready == f_handshake_q[STAGES-1]);
          p_mirror_count :
          assert (f_taken_q == CountBits'(f_done_q + CountBits'($countones(f_handshake_q))));
          if (f_done && f_done_q == f_index) begin
            p_mirror_have : assert (f_have_q);
            p_mirror_payload : assert (i_payload == f_payload_q);
          end
        end
      end
    always_comb cover (f_past_valid && !i_rst && f_take && f_taken_q == 3);
  end
`endif
endmodule
