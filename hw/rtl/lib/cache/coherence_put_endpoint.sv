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

`include "coherence_types.svh"

module coherence_put_endpoint #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned HART = 0,
    parameter int unsigned SLOT = 0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_epoch,
    input logic i_freeze_valid,
    output logic o_freeze_ready,
    input logic [ADDR_WIDTH+259:0] i_freeze,
    output logic o_w_valid,
    input logic i_w_ready,
    output logic [ADDR_WIDTH+259:0] o_w,
    input logic i_absorb_valid,
    output logic o_absorb_ready,
    input logic [5:0] i_absorb_tid,
    input logic [ADDR_WIDTH-1:0] i_absorb_addr,
    input logic i_absorb_epoch,
    output logic o_absorbed,
    input logic i_wa_valid,
    output logic o_wa_ready,
    input logic [ADDR_WIDTH+10:0] i_wa,
    output logic o_cancel_valid,
    output logic o_live,
    output logic o_fatal
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  typedef enum logic [1:0] {
    Idle,
    Present,
    Accepted,
    Fatal
  } phase_t;
  phase_t phase_q;
  coh_w_t freeze_in, frozen_q;
  coh_wa_t ack_in;
  logic absorbed_q;
  logic [5:0] absorb_tid_q;
  assign freeze_in = i_freeze;
  assign ack_in = i_wa;
  assign o_live = phase_q != Idle;
  assign o_fatal = phase_q == Fatal;
  assign o_absorbed = absorbed_q;
  assign o_freeze_ready = !i_rst && phase_q == Idle && freeze_in.hart == 1'(HART) &&
      freeze_in.put_id == 1'(SLOT) && freeze_in.epoch == i_epoch && freeze_in.addr[4:0] == 0;
  assign o_w_valid = !i_rst && phase_q == Present;
  assign o_w = frozen_q;
  // Ordinary W acceptance wins a simultaneous claim for the frozen slot.
  assign o_absorb_ready = !i_rst && phase_q == Present && !absorbed_q && !i_w_ready &&
      i_absorb_addr == frozen_q.addr && i_absorb_epoch == frozen_q.epoch;
  assign o_wa_ready = !i_rst && ack_in.hart == 1'(HART) && ack_in.put_id == 1'(SLOT) &&
      ack_in.epoch == frozen_q.epoch && ack_in.addr == frozen_q.addr &&
      ((phase_q == Accepted && !ack_in.absorbed) ||
       (phase_q == Present && absorbed_q && ack_in.absorbed && ack_in.tid == absorb_tid_q));
  assign o_cancel_valid = i_wa_valid && o_wa_ready && ack_in.absorbed && !ack_in.error;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      frozen_q <= '0;
      absorbed_q <= 1'b0;
      absorb_tid_q <= '0;
    end else begin
      if (i_freeze_valid && o_freeze_ready) begin
        frozen_q <= freeze_in;
        absorbed_q <= 1'b0;
        phase_q <= Present;
      end
      if (o_w_valid && i_w_ready && !absorbed_q) phase_q <= Accepted;
      if (i_absorb_valid && o_absorb_ready) begin
        absorbed_q   <= 1'b1;
        absorb_tid_q <= i_absorb_tid;
      end
      if (i_wa_valid && o_wa_ready) begin
        if (ack_in.error) phase_q <= Fatal;
        else begin
          phase_q <= Idle;
          absorbed_q <= 1'b0;
        end
      end
    end
  end
  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || HART > 1 || SLOT > 1) begin : gen_invalid_config
    initial $fatal(1, "coherence_put_endpoint: invalid parameters");
  end
`ifndef SYNTHESIS
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst && o_w_valid && absorbed_q) assert (!i_w_ready);
  end
`endif
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    // The home masks an absorbed W until the keyed cancellation handshake.
    if (!i_rst && o_w_valid && absorbed_q) assume (!i_w_ready);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(i_freeze_valid && o_freeze_ready)) assert (frozen_q == $past(i_freeze));
      if ($past(o_w_valid && !i_w_ready && !(i_wa_valid && o_wa_ready))) begin
        assert (o_w_valid);
        assert (o_w == $past(o_w));
      end
      if ($past(o_live) && o_live) assert (o_w == $past(o_w));
      if ($past(o_live) && !o_live) assert ($past(i_wa_valid && o_wa_ready && !ack_in.error));
      if ($past(o_fatal)) assert (o_fatal);
      if (o_cancel_valid) assert (absorbed_q && phase_q == Present);
      cover (o_cancel_valid);
      cover (i_wa_valid && o_wa_ready && !ack_in.absorbed && !ack_in.error);
    end
  end
`endif
endmodule
