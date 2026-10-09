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
 * One-entry request repeater for the low instruction BRAM, whose fetches
 * outside the predecode overlay take a second cycle (imem_predecode). The
 * state is the request presented on the last edge. While its response is not
 * ready, or is ready but publication is held, the presenter repeats that
 * exact VA/PA/fault bundle on the memory pins, so the response stays
 * presented until it can publish; otherwise the live request goes out.
 * Overlay responses are ready every cycle and keep the live-PC path.
 *
 * A registered front-end retarget cancels a stale repeat on the same edge that
 * the architectural fetch PC moves. An unresolved physical pair is never
 * repeated: the live physical result must be sampled until it becomes visible.
 * SEPARATE_ADDRESS_RETARGET lets the cached integration leave the transition to
 * the high provider out of the retarget for PA bits [15:0] only. The VA,
 * PA[31:16], PA validity, fault flags, and response controls keep the full
 * retarget, and the caller must mask low responses while the high provider
 * handles the request.
 */
module low_bram_fetch_presenter #(
    parameter bit SEPARATE_ADDRESS_RETARGET = 1'b0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_response_ready,
    input logic i_response_overlay_hit,
    // IF accepted this live response, or captured it on the first backend-
    // stall cycle for exactly one later replay. This only updates slow-response
    // duplicate suppression; it never enters the request-address mux.
    input logic i_response_claim,
    input logic i_publish_hold,
    input logic i_owner_low,
    // IF's registered pulse invalidates the pending request when the PC moves.
    input logic i_retarget,
    // Retarget for PA bits [15:0] only, used when SEPARATE_ADDRESS_RETARGET is
    // set. The caller masks low responses while crossing into the high
    // provider. The upper PA bits keep i_retarget, so the overlay check and
    // the address history see a crossing request as high, never as low.
    input logic i_address_retarget,
    input logic [31:0] i_pc,
    input logic [31:0] i_pa0,
    input logic [31:0] i_pa1,
    input logic i_pa_valid,
    input logic i_fault0,
    input logic i_fault0_page,
    input logic i_fault1,
    input logic i_fault1_page,
    output logic [31:0] o_fetch_address,
    output logic [31:0] o_fetch_pa0,
    output logic [31:0] o_fetch_pa1,
    output logic o_fetch_pa_valid,
    output logic o_fetch_fault0,
    output logic o_fetch_fault0_page,
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_response_valid
);

  logic presented_owner_low_q;
  logic [31:0] presented_pc_q;
  logic [31:0] presented_pa0_q, presented_pa1_q;
  logic presented_pa_valid_q;
  logic presented_fault0_q, presented_fault0_page_q;
  logic presented_fault1_q, presented_fault1_page_q;
  logic slow_response_published_q;
  logic repeat_presented;
  logic repeat_address;
  logic live_matches_presented;

  assign live_matches_presented =
      (i_owner_low == presented_owner_low_q) && (i_pc == presented_pc_q) &&
      (i_pa0 == presented_pa0_q) && (i_pa1 == presented_pa1_q) &&
      (i_pa_valid == presented_pa_valid_q) && (i_fault0 == presented_fault0_q) &&
      (i_fault0_page == presented_fault0_page_q) && (i_fault1 == presented_fault1_q) &&
      (i_fault1_page == presented_fault1_page_q);

  // A request already launched while the preceding response publishes is the
  // next owed fetch. If its response is unready, repeat it exactly; skipping
  // that one-cycle lead can leave a high-half native instruction without its
  // following word.
  //
  // Publication hold has priority: synchronous BRAM data plus the held request
  // form a coherent one-entry response buffer through sustained stall and the
  // registered release-lag cycle.
  assign repeat_presented = presented_owner_low_q && presented_pa_valid_q &&
      !i_retarget && (!i_response_ready || (i_publish_hold && !i_response_overlay_hit));

  assign repeat_address = SEPARATE_ADDRESS_RETARGET ?
      (presented_owner_low_q && presented_pa_valid_q && !i_address_retarget &&
       (!i_response_ready || (i_publish_hold && !i_response_overlay_hit))) : repeat_presented;

  assign o_fetch_address = repeat_presented ? presented_pc_q : i_pc;
  assign o_fetch_pa0 = {
    repeat_presented ? presented_pa0_q[31:16] : i_pa0[31:16],
    repeat_address ? presented_pa0_q[15:0] : i_pa0[15:0]
  };
  assign o_fetch_pa1 = {
    repeat_presented ? presented_pa1_q[31:16] : i_pa1[31:16],
    repeat_address ? presented_pa1_q[15:0] : i_pa1[15:0]
  };
  assign o_fetch_pa_valid = repeat_presented ? presented_pa_valid_q : i_pa_valid;
  assign o_fetch_fault0 = repeat_presented ? presented_fault0_q : i_fault0;
  assign o_fetch_fault0_page = repeat_presented ? presented_fault0_page_q : i_fault0_page;
  assign o_fetch_fault1 = repeat_presented ? presented_fault1_q : i_fault1;
  assign o_fetch_fault1_page = repeat_presented ? presented_fault1_page_q : i_fault1_page;

  // Capture the request on the same edge as imem_predecode's ready register.
  // IF discards stale redirect responses as NOP bubbles, so retarget need only
  // launch the live target. A slow request repeated through publication stays
  // ready for a residual cycle; suppress that duplicate.
  //
  // Overlay hits prove the request was in range and stay valid every cycle.
  // IF captures them across stalls, so publication hold and duplicate
  // suppression apply only to slow responses.
  assign o_response_valid = i_response_overlay_hit ||
      (presented_owner_low_q && presented_pa_valid_q && i_response_ready &&
       !i_publish_hold && !slow_response_published_q);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      presented_owner_low_q     <= 1'b0;
      presented_pc_q            <= '0;
      presented_pa0_q           <= '0;
      presented_pa1_q           <= 32'd4;
      presented_pa_valid_q      <= 1'b0;
      presented_fault0_q        <= 1'b0;
      presented_fault0_page_q   <= 1'b0;
      presented_fault1_q        <= 1'b0;
      presented_fault1_page_q   <= 1'b0;
      slow_response_published_q <= 1'b0;
    end else begin
      presented_owner_low_q   <= repeat_presented ? presented_owner_low_q : i_owner_low;
      presented_pc_q          <= o_fetch_address;
      presented_pa0_q         <= o_fetch_pa0;
      presented_pa1_q         <= o_fetch_pa1;
      presented_pa_valid_q    <= o_fetch_pa_valid;
      presented_fault0_q      <= o_fetch_fault0;
      presented_fault0_page_q <= o_fetch_fault0_page;
      presented_fault1_q      <= o_fetch_fault1;
      presented_fault1_page_q <= o_fetch_fault1_page;
      // Publication state describes whether IF already saw the held response.
      // Preserve it while publication is held: a response valid on the first
      // (raw) stall cycle was captured by IF and must not publish again on
      // release, whereas a response that first becomes ready under the hold
      // still needs its one publication after release.
      if (i_retarget) begin
        slow_response_published_q <= 1'b0;
      end else if (!i_publish_hold) begin
        // Suppress a claimed slow response until the live request changes;
        // IF may take several cycles to move the PC. First publication implies
        // ready and unheld, so the pins carry the live request and this direct
        // comparison is valid. A response squashed by IF remains eligible.
        if (slow_response_published_q) begin
          slow_response_published_q <= live_matches_presented;
        end else begin
          slow_response_published_q <=
              o_response_valid && i_response_claim && !i_response_overlay_hit &&
              live_matches_presented;
        end
      end
    end
  end

endmodule : low_bram_fetch_presenter
