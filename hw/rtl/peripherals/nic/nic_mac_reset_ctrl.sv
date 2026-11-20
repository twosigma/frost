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
 * nic_mac_reset_ctrl: per-domain generation handshake for a MAC block's
 * TX and RX clock domains (index 0 = TX, 1 = RX).
 *
 * On i_restart or loss of i_clk_ok[d], raise o_req[d] with a toggled
 * generation bit o_gen[d]. Wait for that generation to be applied by the
 * far-side nic_domain_reset, lower o_req[d], then wait for reset release.
 * With no clock, hold o_req[d] until the domain can acknowledge it.
 * o_ready[d] requires a valid matching generation, reset released, and a
 * present clock. Until then, o_core_rst_dom[d] holds the core FIFO half
 * and core-side CDC state for domain d in reset.
 *
 * The far side's levels are synchronized here; the request and generation
 * levels toward it are registers.
 */
module nic_mac_reset_ctrl (
    input  logic       i_clk,
    input  logic       i_rst,
    input  logic       i_restart,        // pulse from nic_core_reset_ctrl
    input  logic [1:0] i_clk_ok,         // core-domain levels (synchronized by caller)
    input  logic [1:0] i_in_reset,       // from nic_domain_reset, raw
    input  logic [1:0] i_applied_gen,    // from nic_domain_reset, raw
    input  logic [1:0] i_applied_valid,  // from nic_domain_reset, raw
    output logic [1:0] o_req,            // request levels toward nic_domain_reset
    output logic [1:0] o_gen,            // generation bits accompanying them
    output logic [1:0] o_core_rst_dom,   // hold this domain's core-side FIFO half
    output logic [1:0] o_ready
);
  for (genvar d = 0; d < 2; d++) begin : gen_domain
    logic in_reset_s, applied_s, applied_valid_s;
    cdc_sync #(
        .WIDTH(3),
        .RESET_VALUE(3'b001)
    ) sync_far (
        .i_clk  (i_clk),
        .i_rst  (i_rst),
        .i_async({i_applied_valid[d], i_applied_gen[d], i_in_reset[d]}),
        .o_sync ({applied_valid_s, applied_s, in_reset_s})
    );
    typedef enum logic [1:0] {
      D_IDLE,
      D_REQUEST,
      D_RELEASE
    } dstate_e;
    dstate_e dstate_q;
    logic gen_q, req_q, clk_ok_q;
    logic clk_lost;
    assign clk_lost = clk_ok_q && !i_clk_ok[d];
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        dstate_q <= D_IDLE;
        gen_q    <= 1'b0;
        req_q    <= 1'b0;
        clk_ok_q <= 1'b0;
      end else begin
        clk_ok_q <= i_clk_ok[d];
        unique case (dstate_q)
          D_IDLE: begin
            if (i_restart || clk_lost) begin
              gen_q    <= ~gen_q;
              req_q    <= 1'b1;
              dstate_q <= D_REQUEST;
            end
          end
          D_REQUEST: begin
            // The far side applies the reset when its clock runs; with the
            // clock absent the request stays up.
            if (i_clk_ok[d] && applied_valid_s && (applied_s == gen_q)) begin
              req_q    <= 1'b0;
              dstate_q <= D_RELEASE;
            end
          end
          D_RELEASE: begin
            if (!in_reset_s) dstate_q <= D_IDLE;
            // A restart or a clock loss during release starts a fresh generation.
            if (i_restart || clk_lost) begin
              gen_q    <= ~gen_q;
              req_q    <= 1'b1;
              dstate_q <= D_REQUEST;
            end
          end
          default: dstate_q <= D_IDLE;
        endcase
        // A restart arriving while a request is already up keeps that
        // request: the domain is in reset for it anyway.
      end
    end
    assign o_req[d] = req_q;
    assign o_gen[d] = gen_q;
    assign o_ready[d] = (dstate_q == D_IDLE) && applied_valid_s && (applied_s == gen_q) &&
        !in_reset_s && i_clk_ok[d];
    assign o_core_rst_dom[d] = !o_ready[d];
  end
endmodule : nic_mac_reset_ctrl
