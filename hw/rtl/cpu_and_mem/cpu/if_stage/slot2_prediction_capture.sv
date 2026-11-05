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

// A validated slot-2 candidate shares the packet's first-stall capture edge.
// Replay selects that packet; redirect cancellation invalidates both owners.
// The request omits live stall for the PC mux. Consumption includes it.
module slot2_prediction_capture #(
    parameter int unsigned WIDTH = 1
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_kill,
    input logic i_stall,
    input logic i_stall_registered,
    input logic i_replay,
    input logic i_disable,
    input logic i_candidate,
    input logic [WIDTH-1:0] i_payload,
    output logic o_request,
    output logic o_consumed,
    output logic [WIDTH-1:0] o_payload
);
  logic valid_q;
  always_ff @(posedge i_clk) begin
    if (i_reset || i_kill) valid_q <= 1'b0;
    else if (i_stall && !i_stall_registered) valid_q <= i_candidate;
    else if (!i_stall) valid_q <= 1'b0;

    if (i_stall && !i_stall_registered) o_payload <= i_payload;
  end

  assign o_request  = valid_q && i_replay && !i_reset && !i_kill && !i_disable;
  assign o_consumed = o_request && !i_stall;

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_reset);
    if (past_valid) begin
      if ($past(i_reset || i_kill))
        assert (!valid_q);
        else if ($past(i_stall && !i_stall_registered)) begin
          assert (valid_q == $past(i_candidate));
        end else if ($past(!i_stall))
          assert (!valid_q);
          else assert (valid_q == $past(valid_q));

      if ($past(i_stall && !i_stall_registered))
        assert (o_payload == $past(i_payload));
        else assert (o_payload == $past(o_payload));

      assert (!o_request || (valid_q && i_replay && !i_reset && !i_kill && !i_disable));
      assert (!o_consumed || (o_request && !i_stall));
      cover (o_consumed && $past(i_stall && i_stall_registered));
      cover (valid_q && i_kill && i_replay && !o_request);
    end
  end
`endif
endmodule
