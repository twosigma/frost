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
 * nic_core_reset_ctrl: the core-domain RESET sequence of the NIC engine.
 *
 * RESET (CSR or subsystem reset) stops DMA issue, waits for i_dma_idle,
 * pulses o_core_rst for CoreRstCycles clocks, and emits a single-cycle
 * o_mac_restart pulse on the first cycle of o_core_rst so an attached MAC
 * block starts a fresh reset generation in its clock domains. o_busy covers
 * this sequence without waiting for a MAC clock, so RESET completes even
 * while a transceiver is absent or held in reset.
 */
module nic_core_reset_ctrl (
    input  logic i_clk,
    input  logic i_rst,
    input  logic i_reset_req,      // CSR RESET write (level or pulse)
    input  logic i_dma_idle,       // the DMA front-end owes no response
    output logic o_stop_dma,       // stop issuing, drain
    output logic o_core_rst,       // reset the core-domain NIC state
    output logic o_core_rst_next,  // o_core_rst's value after the next clock edge
    output logic o_busy,           // RESET in progress (the CSR RESET readback)
    output logic o_mac_restart     // one-cycle pulse launching MAC-domain resets
);
  localparam int unsigned CoreRstCycles = 4;

  typedef enum logic [1:0] {
    S_IDLE,
    S_DRAIN,
    S_RESET
  } state_e;
  state_e state_q;
  logic [2:0] rst_cnt_q;
  logic req_pending_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q       <= S_DRAIN;  // subsystem reset runs the same drain and reset sequence
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
  // Predict o_core_rst so nic_engine can register its reset without a cycle delay.
  assign o_core_rst_next = !i_rst &&
      ((state_q == S_DRAIN && i_dma_idle) ||
       (state_q == S_RESET && rst_cnt_q != 3'(CoreRstCycles - 1)));
  assign o_mac_restart = (state_q == S_RESET) && (rst_cnt_q == '0);

`ifndef SYNTHESIS
`ifndef FORMAL
  logic core_rst_next_q;
  bit   reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    core_rst_next_q <= o_core_rst_next;
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !$isunknown({core_rst_next_q, o_core_rst})) begin
      assert (o_core_rst == core_rst_next_q)
      else $error("o_core_rst_next did not predict o_core_rst");
    end
  end
`endif
`endif
endmodule : nic_core_reset_ctrl
