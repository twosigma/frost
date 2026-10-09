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
 * nic_reset_ctrl: the core-side reset controller of the NIC.
 *
 * RESET (CSR or core reset) stops the engines, waits for i_dma_idle, pulses
 * o_core_rst, and starts a reset generation in each MAC domain. o_busy covers
 * this sequence without waiting for a MAC clock, so RESET can finish while
 * the transceiver is absent or in reset.
 *
 * Per domain, raise the request with a toggled generation. Wait for that
 * generation to be applied, lower the request, then wait for reset release.
 * With no clock, hold the request until the domain can acknowledge it.
 * o_ready[d] requires a valid matching generation, reset released, and a
 * present clock. Until then, o_core_rst_dom holds the core FIFO half and
 * MAC-facing engine state in reset, and the CSR block refuses enables.
 * Clock loss starts a new generation so stale state cannot resume.
 *
 * The far side's levels are synchronized here; the request and generation
 * levels toward it are registers.
 */
module nic_reset_ctrl (
    input logic i_clk,
    input logic i_rst,

    input  logic i_reset_req,      // CSR RESET write (level or pulse)
    input  logic i_dma_idle,       // the DMA front-end owes no response
    output logic o_stop_dma,       // stop issuing, drain
    output logic o_core_rst,       // reset the core-domain NIC state (engines, caches, irq, rings)
    output logic o_core_rst_next,  // o_core_rst's value after the next clock edge
    output logic o_busy,           // RESET in progress (the CSR RESET readback)

    // Per domain (index 0 = TX, 1 = RX).
    input  logic [1:0] i_clk_ok,         // core-domain levels (synchronized by the caller)
    input  logic [1:0] i_in_reset,       // from nic_domain_reset, raw
    input  logic [1:0] i_applied_gen,    // from nic_domain_reset, raw
    input  logic [1:0] i_applied_valid,  // from nic_domain_reset, raw
    output logic [1:0] o_req,            // request levels toward nic_domain_reset
    output logic [1:0] o_gen,            // generation bits accompanying them
    output logic [1:0] o_core_rst_dom,   // hold this domain's core-side FIFO half and engine state
    output logic [1:0] o_ready
);
  localparam int unsigned CoreRstCycles = 4;

  // ---- RESET sequence --------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_DRAIN,
    S_RESET
  } state_e;
  state_e state_q;
  logic [2:0] rst_cnt_q;
  logic req_pending_q;
  logic start_domains;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q       <= S_DRAIN;  // the core's reset is a RESET too
      rst_cnt_q     <= '0;
      req_pending_q <= 1'b0;
    end else begin
      if (i_reset_req) req_pending_q <= 1'b1;
      unique case (state_q)
        S_IDLE: begin
          if (req_pending_q || i_reset_req) begin
            state_q       <= S_DRAIN;
            req_pending_q <= 1'b0;
          end
        end
        S_DRAIN: begin
          req_pending_q <= 1'b0;
          if (i_dma_idle) begin
            state_q   <= S_RESET;
            rst_cnt_q <= '0;
          end
        end
        S_RESET: begin
          rst_cnt_q <= rst_cnt_q + 1'b1;
          if (rst_cnt_q == 3'(CoreRstCycles - 1)) state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
  assign o_stop_dma = (state_q != S_IDLE);
  assign o_core_rst = (state_q == S_RESET);
  assign o_busy = (state_q != S_IDLE);
  // Predict o_core_rst so nic_top can register its reset without a cycle delay.
  assign o_core_rst_next = !i_rst &&
      ((state_q == S_DRAIN && i_dma_idle) ||
       (state_q == S_RESET && rst_cnt_q != 3'(CoreRstCycles - 1)));
`ifndef SYNTHESIS
  logic core_rst_next_q;
  always_ff @(posedge i_clk) begin
    core_rst_next_q <= o_core_rst_next;
    if (!$isunknown({core_rst_next_q, o_core_rst})) begin
      assert (o_core_rst == core_rst_next_q)
      else $error("o_core_rst_next did not predict o_core_rst");
    end
  end
`endif
  assign start_domains = (state_q == S_RESET) && (rst_cnt_q == '0);

  // ---- per-domain generation handshake ----------------------------------------
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
            if (start_domains || clk_lost) begin
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
            // A new RESET or a clock loss during the release restarts.
            if (start_domains || clk_lost) begin
              gen_q    <= ~gen_q;
              req_q    <= 1'b1;
              dstate_q <= D_REQUEST;
            end
          end
          default: dstate_q <= D_IDLE;
        endcase
        // A RESET arriving while a request is already up keeps that
        // request: the domain is in reset for it anyway.
      end
    end
    assign o_req[d] = req_q;
    assign o_gen[d] = gen_q;
    assign o_ready[d] = (dstate_q == D_IDLE) && applied_valid_s && (applied_s == gen_q) &&
        !in_reset_s && i_clk_ok[d];
    assign o_core_rst_dom[d] = !o_ready[d];
  end
endmodule : nic_reset_ctrl
