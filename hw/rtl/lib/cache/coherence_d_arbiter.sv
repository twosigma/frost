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

// Selection and payload stay fixed throughout a stalled presentation.
module coherence_d_arbiter #(
    parameter int unsigned WIDTH = 344,
    parameter int unsigned PORTS = 2,
    parameter bit HOLD_VALID = 0,
    localparam int unsigned PortBits = PORTS > 1 ? $clog2(PORTS) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic [PORTS-1:0] i_valid,
    output logic [PORTS-1:0] o_ready,
    input logic [PORTS-1:0][WIDTH-1:0] i_payload,
    output logic o_valid,
    // o_valid without the reset term, for a consumer that applies the same
    // reset itself.
    output logic o_offer,
    // The held one-hot selection, which o_ready qualifies with reset and
    // i_ready, for a consumer that applies i_ready itself.
    output logic [PORTS-1:0] o_selected,
    input logic i_ready,
`ifdef COHERENCE_HOME_CONTROL
    input logic i_service_stop,
`endif
    output logic [WIDTH-1:0] o_payload
);
  localparam int unsigned GroupBits = 4;
  localparam int unsigned Groups = (PORTS + GroupBits - 1) / GroupBits;
  logic selected_q, found, after_next;
  logic [PortBits-1:0] next_q, pick;
  // The selected port is a register of the selection, not a state machine.
  (* fsm_encoding = "none" *) logic [PortBits-1:0] selected_port_q;
  // One-hot copy of the held selection, zero while none is held, so each
  // port's ready is one term of the downstream ready.
  logic [PORTS-1:0] selected_ports_q;
  // later_q[port] holds port >= next_q.
  logic [PORTS-1:0] later_q, later, later_first, valid_first, pick_ports;
  logic [Groups-1:0] later_groups, valid_groups;
  logic [WIDTH-1:0] payload_q, pick_payload;
  // The pick is the first valid port at or after next_q, else the first
  // valid port. Each port's priority comes from four-port group summaries
  // and its own group's lower ports; the pick and its payload are one-hot.
  assign later = i_valid & later_q;
  for (genvar group_index = 0; group_index < Groups; group_index++) begin : gen_group
    localparam int unsigned Base  = group_index * GroupBits;
    localparam int unsigned Width = PORTS - Base < GroupBits ? PORTS - Base : GroupBits;
    assign later_groups[group_index] = |later[Base+:Width];
    assign valid_groups[group_index] = |i_valid[Base+:Width];
  end
  for (genvar port_idx = 0; port_idx < PORTS; port_idx++) begin : gen_first
    localparam int unsigned Group  = port_idx / GroupBits;
    localparam int unsigned Offset = port_idx % GroupBits;
    logic later_below, valid_below;
    always_comb begin
      later_below = 1'b0;
      valid_below = 1'b0;
      for (int group_index = 0; group_index < int'(Group); group_index++) begin
        later_below |= later_groups[group_index];
        valid_below |= valid_groups[group_index];
      end
      for (int lower = 0; lower < int'(Offset); lower++) begin
        later_below |= later[Group*GroupBits+lower];
        valid_below |= i_valid[Group*GroupBits+lower];
      end
    end
    assign later_first[port_idx] = later[port_idx] && !later_below;
    assign valid_first[port_idx] = i_valid[port_idx] && !valid_below;
  end
  assign after_next = |later_groups;
  assign found = |valid_groups;
  assign pick_ports = after_next ? later_first : valid_first;
  always_comb begin
    pick = '0;
    pick_payload = '0;
    for (int port_idx = 0; port_idx < PORTS; port_idx++) begin
      if (pick_ports[port_idx]) pick |= PortBits'(port_idx);
      pick_payload |= {WIDTH{pick_ports[port_idx]}} & i_payload[port_idx];
    end
  end
  assign o_ready = {PORTS{!i_rst && i_ready}} & selected_ports_q;
  assign o_selected = selected_ports_q;
  assign o_offer = selected_q && (HOLD_VALID || i_valid[selected_port_q]);
  assign o_valid = !i_rst && o_offer;
  assign o_payload = payload_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      selected_q <= 1'b0;
      selected_port_q <= '0;
      selected_ports_q <= '0;
      next_q <= '0;
      later_q <= '1;
    end else if (!selected_q) begin
      if (found) begin
        selected_q <= 1'b1;
        selected_port_q <= pick;
        selected_ports_q <= pick_ports;
        payload_q <= pick_payload;
      end
    end else if (o_valid && i_ready) begin
      selected_q <= 1'b0;
      selected_ports_q <= '0;
      next_q <= selected_port_q == PortBits'(PORTS - 1) ? '0 : selected_port_q + 1'b1;
      for (int port_idx = 0; port_idx < PORTS; port_idx++)
      later_q[port_idx] <= selected_port_q == PortBits'(PORTS - 1) ||
          port_idx > int'(selected_port_q);
    end
  end
  if (PORTS < 1 || WIDTH < 1) begin : gen_invalid
    initial $fatal(1, "coherence_d_arbiter: invalid parameters");
  end
`ifndef SYNTHESIS
  // Registers power up arbitrary and the reset can reach this module a few
  // cycles after the first edge, so the simulation checks begin at the first
  // reset.
`ifdef FORMAL
  // Formal tasks start from a reset or from an induction state; the checks
  // apply in both.
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst && selected_q && i_valid[selected_port_q])
      assert (o_payload == i_payload[selected_port_q]);
    if (sim_reset_seen_q && !i_rst) begin
      assert (selected_ports_q == (selected_q ? PORTS'(1) << selected_port_q : PORTS'(0)));
      for (int port_idx = 0; port_idx < PORTS; port_idx++)
      assert (later_q[port_idx] == (port_idx >= int'(next_q)));
      if (found)
        assert (pick_ports == PORTS'(1) << pick && pick_payload == i_payload[pick]);
        else assert (pick_ports == '0);
    end
  end
`endif
`ifdef COHERENCE_HOME_CONTROL
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      assert (int'(selected_port_q) < PORTS && int'(next_q) < PORTS);
      if (!i_service_stop && selected_q) assert (i_valid[selected_port_q]);
    end
  end
`endif
`ifdef FORMAL
`ifndef COHERENCE_HOME_CONTROL
  logic f_past_valid = 1'b0;
  logic [PortBits-1:0] f_pick;
  always_comb begin
    f_pick = '0;
    for (int offset = PORTS - 1; offset >= 0; offset--)
    if (i_valid[(int'(next_q)+offset)%PORTS]) f_pick = PortBits'((int'(next_q) + offset) % PORTS);
    if (!i_rst && next_q < PORTS) assert (pick == f_pick);
  end
  for (genvar port_idx = 0; port_idx < PORTS; port_idx++) begin : gen_hold_contract
    wire [WIDTH-1:0] payload = i_payload[port_idx];
    wire stalled = i_valid[port_idx] && !o_ready[port_idx];
    always_ff @(posedge i_clk) begin
      if (f_past_valid && !i_rst && !$past(i_rst) && $past(stalled)) begin
`ifdef COHERENCE_ARBITER_COMPOSED
        assert (i_valid[port_idx]);
        assert (payload == $past(payload));
`else
        assume (i_valid[port_idx]);
        assume (payload == $past(payload));
`endif
      end
    end
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_valid && !i_ready)) begin
        assert (o_valid);
        assert (o_payload == $past(o_payload));
      end
      if (selected_q) begin
        assert (i_valid[selected_port_q]);
        assert (o_payload == i_payload[selected_port_q]);
      end
      assert (selected_port_q < PORTS);
      assert (next_q < PORTS);
      if ($past(selected_q) && selected_q) assert (selected_port_q == $past(selected_port_q));
      assert ($onehot0(o_ready));
      assert ((|(i_valid & o_ready)) == (o_valid && i_ready));
    end
  end
`endif
`endif
endmodule
