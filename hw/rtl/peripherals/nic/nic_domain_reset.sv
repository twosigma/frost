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
 * The core-side controller (nic_reset_ctrl) raises a request level with a
 * generation bit. This block asserts the domain's synchronous reset
 * (o_domain_rst, for the MAC and this domain's halves of the packet FIFOs)
 * without waiting for a clock edge (cdc_reset_sync), keeps it while the
 * request is high and for HOLD_CYCLES after it drops, and reports two
 * levels back: o_in_reset, and o_applied_gen with o_applied_valid, which
 * take the request's generation once the reset has been held for
 * HOLD_CYCLES of this clock with the request high (o_applied_valid stays 0
 * from the core's reset until the first application, so a generation
 * that merely equals the reset value is never mistaken for an
 * acknowledgement). A generation is therefore acknowledged only after this
 * domain's clock has actually applied the reset, and a stale
 * acknowledgement from an earlier generation cannot satisfy a new request.
 * With no clock the reset is held and nothing is acknowledged, which is
 * what the controller expects.
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

  // The release hold is preloaded while the request is up, so the cycle in
  // which req_arst falls already finds it loaded: no gap in o_domain_rst
  // between the request's release and the hold (a gap would let the core
  // side see the domain out of reset for one cycle and report ready while
  // the reset came back). These registers reset synchronously on the
  // core's reset; they only matter while this clock runs.
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

  assign o_domain_rst  = core_arst || req_arst || (release_cnt_q != '0);
  assign o_in_reset    = o_domain_rst;
  assign o_applied_gen   = applied_q;
  assign o_applied_valid = applied_valid_q;
endmodule : nic_domain_reset
