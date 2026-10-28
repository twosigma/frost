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

module debug_fetch_barrier (
    input logic i_clk,
    input logic i_rst,
    input logic i_req_valid,
    input logic [31:0] i_req_addr,
    input logic i_go_taken,
    output logic o_invalidate,
    output logic o_go_valid,
    output logic [31:0] o_go_addr
);
  logic request_seen_q, released_q;

  // The registered invalidate is sampled before go reaches the CPU.
  // A held request has one invalidate and at most one acknowledged go.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      request_seen_q <= 1'b0;
      released_q <= 1'b0;
      o_invalidate <= 1'b0;
      o_go_addr <= '0;
    end else begin
      o_invalidate <= 1'b0;
      if (!i_req_valid) begin
        request_seen_q <= 1'b0;
        released_q <= 1'b0;
      end else begin
        if (!request_seen_q) begin
          request_seen_q <= 1'b1;
          o_go_addr <= i_req_addr;
          o_invalidate <= 1'b1;
        end
        if (o_invalidate) released_q <= 1'b1;
        if (i_go_taken) released_q <= 1'b0;
      end
    end
  end

  // Withdrawal cancels a pending go even before the next clock edge.
  assign o_go_valid = released_q && i_req_valid;

`ifdef FORMAL
  logic [1:0] f_past_valid = '0;
  logic f_request_seen, f_invalidated, f_completed;
  logic [31:0] f_addr;
  always_ff @(posedge i_clk) begin
    f_past_valid <= {f_past_valid[0], 1'b1};
    if (!f_past_valid[0]) assume (i_rst);
    assume (!i_go_taken || o_go_valid);

    if (i_rst || !i_req_valid) begin
      f_request_seen <= 1'b0;
      f_invalidated <= 1'b0;
      f_completed <= 1'b0;
    end else begin
      if (!f_request_seen) f_addr <= i_req_addr;
      f_request_seen <= 1'b1;
      if (o_invalidate) f_invalidated <= 1'b1;
      if (i_go_taken) f_completed <= 1'b1;
    end

    if (f_past_valid[0] && !i_rst) begin
      assert (!o_go_valid || (f_invalidated && !f_completed && o_go_addr == f_addr));
      assert (!o_go_valid || i_req_valid);
      if (f_request_seen && i_req_valid) assert (!o_invalidate || !f_invalidated);
      if (f_completed && i_req_valid) assert (!o_go_valid && !o_invalidate);
      if ($past(i_rst)) assert (!o_go_valid && !o_invalidate);
      if (f_past_valid[1] && i_req_valid && !f_completed && $past(
              i_req_valid && !i_rst
          ) && $past(
              i_req_valid && !i_rst, 2
          ))
        assert (o_go_valid);
      cover (o_go_valid && $past(o_go_valid) && i_go_taken);
      cover (o_invalidate && !i_req_valid);
      cover (f_completed && !i_req_valid);
    end
  end
`endif
endmodule
