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
 * One-entry request repeater for the low instruction BRAM's variable-latency
 * metadata fallback. The state is the request actually presented on the last
 * edge. An unready out-of-overlay response repeats that exact VA/PA/fault
 * bundle unless the preceding response published and advanced the live PC; in
 * that case the new live request becomes the owed request immediately. A
 * response that becomes ready while publication is held remains presented
 * until it can actually publish. Ready overlay responses leave the original
 * live-PC fast path intact.
 *
 * A registered front-end retarget cancels a stale repeat on the same edge that
 * the architectural fetch PC moves. An unresolved physical pair is never
 * repeated: the live physical result must be sampled until it becomes visible.
 */
module low_bram_fetch_presenter (
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
    input logic i_retarget,
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

  assign o_fetch_address = repeat_presented ? presented_pc_q : i_pc;
  assign o_fetch_pa0 = repeat_presented ? presented_pa0_q : i_pa0;
  assign o_fetch_pa1 = repeat_presented ? presented_pa1_q : i_pa1;
  assign o_fetch_pa_valid = repeat_presented ? presented_pa_valid_q : i_pa_valid;
  assign o_fetch_fault0 = repeat_presented ? presented_fault0_q : i_fault0;
  assign o_fetch_fault0_page = repeat_presented ? presented_fault0_page_q : i_fault0_page;
  assign o_fetch_fault1 = repeat_presented ? presented_fault1_q : i_fault1;
  assign o_fetch_fault1_page = repeat_presented ? presented_fault1_page_q : i_fault1_page;

  // These registers and imem_predecode's response-ready register capture the
  // same presented request on the same edge. IF's existing control-flow
  // holdoff consumes any stale redirect response as its ordinary NOP bubble;
  // retarget only has to launch the live target instead of repeating it.
  // When a repeated slow request is still on the synchronous BRAM pins at its
  // publication edge, it remains response-ready for one residual cycle.
  // Suppress that duplicate while the pins chase the newly advanced live PC.
  // Overlay hits are deliberately exempt: their response is ready every cycle
  // and forms the original no-bubble default-program path.
  // Overlay hits retain the original always-valid low-BRAM contract through
  // backend stalls: IF's saved-response machinery owns that cadence, and the
  // live pins must remain free to preserve the default CoreMark schedule.
  // The registered overlay-hit response already proves that the preceding
  // memory request was in the timed low range. Keep it completely outside the
  // slow presenter's owner/PA-valid cone; otherwise these new state flops sit
  // at the head of the fast fetch-valid -> PC recurrence. Publication
  // holding and duplicate suppression apply only to the slow fallback
  // response that this presenter buffers.
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
        // A claimed slow identity stays suppressed until the live request
        // actually changes. A single-cycle pulse is insufficient: IF can take
        // more than one cycle to move its live PC, in which case releasing the
        // gate would publish the same instruction twice. At first publication,
        // response-valid implies ready and unheld, so repeat_presented is false
        // and the address pins carry this exact live identity. Reuse the direct
        // live comparison instead of rebuilding it through the output muxes.
        // A valid response that IF squashes is not a publication and remains
        // eligible if the same request identity is presented again.
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
