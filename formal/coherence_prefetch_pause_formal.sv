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

module coherence_prefetch_pause_formal (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic i_accept,
    input logic i_response,
    input logic [2:0] i_request_id,
    input logic [2:0] i_response_id
);
  logic pause;
  logic [6:0] state;
  logic [2:0] recent_age;
  coherence_prefetch_pause dut (
      .i_clk,
      .i_rst,
      .i_dma_valid(i_valid),
      .i_dma_accept(i_accept),
      .i_dma_response(i_response),
      .o_pause(pause),
      .o_formal_state(state)
  );
  logic [7:0] live_q;
  logic [6:0] recent_q;
  logic past_valid = 1'b0;
  logic seen_q;
  always_comb begin
    recent_age = '0;
    for (int age = 6; age >= 0; age--) if (recent_q[age]) recent_age = 3'(7 - age);
  end
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_rst);
    if (i_rst) begin
      live_q   <= '0;
      recent_q <= '0;
      seen_q   <= 1'b0;
    end else begin
      assume (!i_accept || i_valid);
      assume (!i_response || live_q[i_response_id]);
      assume (!i_accept || !live_q[i_request_id] || (i_response && i_request_id == i_response_id));
      if (i_response) live_q[i_response_id] <= 1'b0;
      if (i_accept) live_q[i_request_id] <= 1'b1;
      recent_q <= {recent_q[5:0], i_valid || (|live_q)};
      if (|live_q) seen_q <= 1'b1;
      assert (state[6:3] == $countones(live_q));
      assert (state[2:0] == recent_age);
      assert (pause == (i_valid || (|live_q) || (|recent_q)));
      cover (&live_q);
      cover (i_accept && i_response && i_request_id == i_response_id);
      cover (seen_q && !pause);
    end
  end
endmodule
