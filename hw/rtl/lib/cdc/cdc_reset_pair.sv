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

// Both domains remain in reset until each has clocked its release chain.
// The peer-release synchronizers prevent traffic while a stopped peer has
// not clocked its synchronous state through reset. Assertion is asynchronous.
module cdc_reset_pair (
    input  logic i_arst,
    input  logic i_a_clk,
    input  logic i_b_clk,
    output logic o_a_rst,
    output logic o_b_rst
);
  logic a_reset, b_reset;
  logic b_reset_a, a_reset_b;
  cdc_reset_sync reset_a (
      .i_clk (i_a_clk),
      .i_arst(i_arst),
      .o_rst (a_reset)
  );
  cdc_reset_sync reset_b (
      .i_clk (i_b_clk),
      .i_arst(i_arst),
      .o_rst (b_reset)
  );
  // Asynchronous assertion also covers a peer without any reset-time edges.
  cdc_reset_sync peer_b (
      .i_clk (i_a_clk),
      .i_arst(b_reset),
      .o_rst (b_reset_a)
  );
  cdc_reset_sync peer_a (
      .i_clk (i_b_clk),
      .i_arst(a_reset),
      .o_rst (a_reset_b)
  );
  assign o_a_rst = a_reset || b_reset_a;
  assign o_b_rst = b_reset || a_reset_b;
endmodule : cdc_reset_pair
