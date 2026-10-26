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

// One held payload crosses under a request/acknowledgement toggle handshake.
// Both resets must overlap without traffic. The payload path must settle
// within one period of the faster clock, before the synchronized request.
module cdc_mailbox #(
    parameter int unsigned WIDTH = 64
) (
    input logic i_src_clk,
    input logic i_src_rst,
    input logic [WIDTH-1:0] i_src_data,
    input logic i_src_valid,
    output logic o_src_ready,
    output logic o_src_idle,
    input logic i_dst_clk,
    input logic i_dst_rst,
    output logic [WIDTH-1:0] o_dst_data,
    output logic o_dst_valid,
    input logic i_dst_ready
);
  logic [WIDTH-1:0] payload_q;
  logic request_q, acknowledge_q, request_s, acknowledge_s;
  cdc_sync sync_request (
      .i_clk  (i_dst_clk),
      .i_rst  (i_dst_rst),
      .i_async(request_q),
      .o_sync (request_s)
  );
  cdc_sync sync_acknowledge (
      .i_clk  (i_src_clk),
      .i_rst  (i_src_rst),
      .i_async(acknowledge_q),
      .o_sync (acknowledge_s)
  );
  assign o_src_idle  = request_q == acknowledge_s;
  assign o_src_ready = !i_src_rst && o_src_idle;
  always_ff @(posedge i_src_clk) begin
    if (i_src_rst) request_q <= 1'b0;
    else if (i_src_valid && o_src_ready) begin
      payload_q <= i_src_data;
      request_q <= !request_q;
    end
  end
  logic valid_q;
  assign o_dst_valid = valid_q && !i_dst_rst;
  always_ff @(posedge i_dst_clk) begin
    if (i_dst_rst) begin
      acknowledge_q <= 1'b0;
      valid_q <= 1'b0;
      o_dst_data <= '0;
    end else if (o_dst_valid && i_dst_ready) begin
      acknowledge_q <= request_s;
      valid_q <= 1'b0;
    end else if (!valid_q && request_s != acknowledge_q) begin
      o_dst_data <= payload_q;
      valid_q <= 1'b1;
    end
  end
endmodule : cdc_mailbox
