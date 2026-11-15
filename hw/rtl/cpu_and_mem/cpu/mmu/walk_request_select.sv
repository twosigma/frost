/*
 *    Copyright (c) 2026 John Goodacre.
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
 * walk_request_select: the data and instruction MMUs share one walk port (the
 * L2 TLB, else the walker). The L2 TLB reads its block RAM at the offered VPN
 * in the cycle a request fires, so the VPN select is taken from registered
 * state only:
 *
 * - i_d_hold is registered in the data MMU: its S1 holds an op that has not
 *   had a walk accepted. The data request can only be valid while it is set.
 * - While i_d_hold is set the port offers the data side (its VPN, its valid)
 *   and refuses the instruction side, even in a cycle where the data op does
 *   not ask for a walk (a TLB hit, a fault, a kill).
 * - An instruction request refused that way, in a cycle where the port was
 *   ready and the data side did not ask, takes priority from the next cycle
 *   until it is accepted or withdrawn. So such a refusal delays an
 *   instruction walk by one cycle at most, and only in a cycle where the
 *   previous select would have accepted it. Otherwise the data side keeps
 *   priority, as before.
 *
 * The owner register routes the walk response to the side that asked.
 */
module walk_request_select #(
    localparam int unsigned VpnBits = riscv_pkg::Sv39VpnBits
) (
    input logic i_clk,
    input logic i_rst,
    // The translation changed: requests withdraw and the walk is discarded.
    input logic i_invalidate,

    input  logic               i_d_hold,
    input  logic               i_d_valid,
    output logic               o_d_ready,
    input  logic [VpnBits-1:0] i_d_vpn,

    input  logic               i_i_valid,
    output logic               o_i_ready,
    input  logic [VpnBits-1:0] i_i_vpn,

    output logic               o_valid,
    input  logic               i_ready,
    output logic [VpnBits-1:0] o_vpn,
    // The walk last accepted belongs to the instruction side.
    output logic               o_owner_i
);

  logic i_priority_q;
  logic d_select;
  assign d_select = i_d_hold && !i_priority_q;
  assign o_vpn = d_select ? i_d_vpn : i_i_vpn;
  assign o_valid = d_select ? i_d_valid : i_i_valid;
  assign o_d_ready = i_ready && d_select;
  assign o_i_ready = i_ready && !d_select;

  // Refused by the registered select alone: the port was ready and the data
  // side, though selected, did not ask.
  logic i_refused_by_select;
  assign i_refused_by_select = i_i_valid && i_ready && d_select && !i_d_valid;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate) begin
      i_priority_q <= 1'b0;
      o_owner_i <= 1'b0;
    end else begin
      i_priority_q <= i_i_valid && !o_i_ready && (i_priority_q || i_refused_by_select);
      if (o_valid && i_ready) o_owner_i <= !d_select;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The data MMU asks only while its S1 holds an op without an accepted walk.
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_d_valid) assert (i_d_hold);
  end
`endif
`endif

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb begin
    if (!f_past_valid) assume (i_rst);
    // The data MMU's contract.
    if (i_d_valid) assume (i_d_hold);
  end

  logic d_accept, i_accept;
  assign d_accept = i_d_valid && o_d_ready;
  assign i_accept = i_i_valid && o_i_ready;
  // The arbiter this select replaces: data first, from the request valids.
  logic ref_d_accept, ref_i_accept;
  assign ref_d_accept = i_d_valid && i_ready;
  assign ref_i_accept = i_i_valid && i_ready && !i_d_valid;

  always_comb begin
    if (!i_rst) begin
      // The port fires for exactly one side, with that side's VPN.
      p_fire : assert ((o_valid && i_ready) == (d_accept || i_accept));
      p_one_side : assert (!(d_accept && i_accept));
      if (d_accept) p_d_vpn : assert (o_vpn == i_d_vpn);
      if (i_accept) p_i_vpn : assert (o_vpn == i_i_vpn);
      // Data priority is kept outside the one cycle an instruction request
      // has priority after a select refusal.
      if (!i_priority_q) p_d_first : assert (d_accept == ref_d_accept);
      // Every acceptance the select makes, the replaced arbiter makes too,
      // except the instruction request it moved by one cycle.
      if (i_accept && !i_priority_q) p_i_same : assert (ref_i_accept);
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // A select refusal delays an instruction request one cycle at most: it
      // is accepted in the next cycle the port is ready.
      if ($past(i_refused_by_select && !i_invalidate) && i_i_valid && i_ready)
        p_i_next : assert (i_accept);
      // Priority is held only for a refused request still waiting.
      if (i_priority_q) p_priority_live : assert ($past(i_i_valid && !i_accept));
      // The owner names the side accepted last.
      if ($past(!i_invalidate && (d_accept || i_accept)))
        p_owner : assert (o_owner_i == $past(i_accept));
    end
  end

  // While an instruction request waits, priority reaches it and it fires
  // once the port is ready, however the data side behaves.
  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      if (i_priority_q && i_i_valid && i_ready) p_priority_fires : assert (i_accept);
      c_refused : cover (i_refused_by_select);
      c_priority_accept : cover (i_priority_q && i_accept);
      c_priority_held : cover (i_priority_q && $past(i_priority_q) && i_accept);
      c_d_accept : cover (d_accept && $past(i_accept));
    end
  end
`endif

endmodule : walk_request_select
