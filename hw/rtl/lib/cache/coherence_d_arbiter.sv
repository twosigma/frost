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
    input logic i_ready,
`ifdef COHERENCE_HOME_CONTROL
    input logic i_service_stop,
`endif
    output logic [WIDTH-1:0] o_payload
);
  logic selected_q, found, after_next;
  logic [PortBits-1:0] selected_port_q, next_q, pick, first;
  // One-hot copy of the held selection, zero while none is held, so each
  // port's ready is one term of the downstream ready.
  logic [PORTS-1:0] selected_ports_q;
  logic [WIDTH-1:0] payload_q;
  always_comb begin
    found = 1'b0;
    after_next = 1'b0;
    first = '0;
    pick = '0;
    for (int port_idx = PORTS - 1; port_idx >= 0; port_idx--) begin
      if (i_valid[port_idx]) begin
        found = 1'b1;
        first = PortBits'(port_idx);
        if (port_idx >= int'(next_q)) begin
          after_next = 1'b1;
          pick = PortBits'(port_idx);
        end
      end
    end
    if (!after_next) pick = first;
  end
  assign o_ready   = {PORTS{!i_rst && i_ready}} & selected_ports_q;
  assign o_offer   = selected_q && (HOLD_VALID || i_valid[selected_port_q]);
  assign o_valid   = !i_rst && o_offer;
  assign o_payload = payload_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      selected_q <= 1'b0;
      selected_port_q <= '0;
      selected_ports_q <= '0;
      next_q <= '0;
    end else if (!selected_q) begin
      if (found) begin
        selected_q <= 1'b1;
        selected_port_q <= pick;
        selected_ports_q <= PORTS'(1) << pick;
        payload_q <= i_payload[pick];
      end
    end else if (o_valid && i_ready) begin
      selected_q <= 1'b0;
      selected_ports_q <= '0;
      next_q <= selected_port_q == PortBits'(PORTS - 1) ? '0 : selected_port_q + 1'b1;
    end
  end
  if (PORTS < 1 || WIDTH < 1) begin : gen_invalid
    initial $fatal(1, "coherence_d_arbiter: invalid parameters");
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst && selected_q && i_valid[selected_port_q])
      assert (o_payload == i_payload[selected_port_q]);
    if (!i_rst)
      assert (selected_ports_q == (selected_q ? PORTS'(1) << selected_port_q : PORTS'(0)));
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
    if (next_q < PORTS) assert (pick == f_pick);
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
