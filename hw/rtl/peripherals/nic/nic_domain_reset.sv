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

/*
 * nic_domain_reset: the far side of the NIC's reset handshake, one per MAC
 * clock domain (TX, RX).
 *
 * nic_reset_ctrl sends a request and generation bit. cdc_reset_sync asserts
 * o_domain_rst without a clock edge. Reset stays high through the request
 * and for HOLD_CYCLES clocks after its synchronized release.
 *
 * After HOLD_CYCLES with the request high, report its generation through
 * o_applied_gen and o_applied_valid. Valid stays low from core reset until
 * the first application, so an initial matching generation cannot falsely
 * acknowledge a request. Without a clock, reset stays high and no new
 * generation is acknowledged.
 *
 * The core's own reset (i_core_rst_async) resets this block's bookkeeping
 * and the domain alike, so a CPU reset starts a fresh generation on both
 * sides.
 */
module nic_domain_reset #(
    parameter int unsigned HOLD_CYCLES = 8
) (
    input  logic i_clk,
    input  logic i_core_rst_async,
    input  logic i_req_async,
    input  logic i_gen_async,
    output logic o_domain_rst,
    output logic o_in_reset,
    output logic o_applied_gen,
    output logic o_applied_valid
);
  localparam int unsigned CountBits = $clog2(HOLD_CYCLES + 1);

  logic core_arst, req_arst;
  cdc_reset_sync sync_core (
      .i_clk (i_clk),
      .i_arst(i_core_rst_async),
      .o_rst (core_arst)
  );
  cdc_reset_sync sync_req (
      .i_clk (i_clk),
      .i_arst(i_req_async),
      .o_rst (req_arst)
  );
  logic gen_s;
  cdc_sync sync_gen (
      .i_clk  (i_clk),
      .i_rst  (core_arst),
      .i_async(i_gen_async),
      .o_sync (gen_s)
  );

  // Preload the release hold while req_arst is high. A gap at release could
  // falsely report ready to the core before reset reasserted.
  // These counters reset synchronously and matter only while the clock runs.
  logic [CountBits-1:0] assert_cnt_q, release_cnt_q;
  logic applied_q, applied_valid_q;
  always_ff @(posedge i_clk) begin
    if (core_arst) begin
      assert_cnt_q    <= '0;
      release_cnt_q   <= '0;
      applied_q       <= 1'b0;
      applied_valid_q <= 1'b0;
    end else if (req_arst) begin
      release_cnt_q <= CountBits'(HOLD_CYCLES);
      if (assert_cnt_q != CountBits'(HOLD_CYCLES)) begin
        assert_cnt_q <= assert_cnt_q + 1'b1;
      end else begin
        applied_q       <= gen_s;
        applied_valid_q <= 1'b1;
      end
    end else begin
      assert_cnt_q <= '0;
      if (release_cnt_q != '0) release_cnt_q <= release_cnt_q - 1'b1;
    end
  end

  assign o_domain_rst = core_arst || req_arst || (release_cnt_q != '0);
  // The level reported back crosses into the core domain: it comes from a
  // flop, never from the reset's combinational OR (an absent clock leaves
  // it stale, which the controller's clock-ok input covers).
  logic in_reset_q;
  always_ff @(posedge i_clk) in_reset_q <= o_domain_rst;
  assign o_in_reset    = in_reset_q;
  assign o_applied_gen   = applied_q;
  assign o_applied_valid = applied_valid_q;
endmodule : nic_domain_reset
