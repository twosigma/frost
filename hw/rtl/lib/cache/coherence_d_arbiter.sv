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

// Selection stays fixed throughout a stalled presentation.
module coherence_d_arbiter #(
    parameter int unsigned WIDTH = 344,
    parameter int unsigned PORTS = 2,
    localparam int unsigned PortBits = PORTS > 1 ? $clog2(PORTS) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic [PORTS-1:0] i_valid,
    output logic [PORTS-1:0] o_ready,
    input logic [PORTS-1:0][WIDTH-1:0] i_payload,
    output logic o_valid,
    input logic i_ready,
    output logic [WIDTH-1:0] o_payload
);
  logic selected_q, found;
  logic [PortBits-1:0] selected_port_q, next_q, pick;
  always_comb begin
    found = 1'b0;
    pick  = '0;
    for (int offset = PORTS - 1; offset >= 0; offset--) begin
      if (i_valid[(int'(next_q)+offset)%PORTS]) begin
        found = 1'b1;
        pick  = PortBits'((int'(next_q) + offset) % PORTS);
      end
    end
    o_ready = '0;
    if (!i_rst && selected_q) o_ready[selected_port_q] = i_ready;
  end
  assign o_valid   = !i_rst && selected_q && i_valid[selected_port_q];
  assign o_payload = i_payload[selected_port_q];
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      selected_q <= 1'b0;
      selected_port_q <= '0;
      next_q <= '0;
    end else if (!selected_q) begin
      if (found) begin
        selected_q <= 1'b1;
        selected_port_q <= pick;
      end
    end else if (o_valid && i_ready) begin
      selected_q <= 1'b0;
      next_q <= selected_port_q == PortBits'(PORTS - 1) ? '0 : selected_port_q + 1'b1;
    end
  end
  if (PORTS < 1 || WIDTH < 1) begin : gen_invalid
    initial $fatal(1, "coherence_d_arbiter: invalid parameters");
  end
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      for (int port_idx = 0; port_idx < PORTS; port_idx++) begin
        if ($past(i_valid[port_idx] && !o_ready[port_idx])) begin
          assume (i_valid[port_idx]);
          assume (i_payload[port_idx] == $past(i_payload[port_idx]));
        end
      end
      if ($past(o_valid && !i_ready)) begin
        assert (o_valid);
        assert (o_payload == $past(o_payload));
      end
      if (selected_q) assert (i_valid[selected_port_q]);
      assert (selected_port_q < PORTS);
      assert (next_q < PORTS);
      if ($past(selected_q) && selected_q) assert (selected_port_q == $past(selected_port_q));
      assert ($onehot0(o_ready));
      assert ((|(i_valid & o_ready)) == (o_valid && i_ready));
    end
  end
`endif
endmodule
