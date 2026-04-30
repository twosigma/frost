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
 * FU CDB Adapter
 *
 * One-deep holding register that sits between a functional unit and the CDB
 * arbiter. When the FU produces a result and the arbiter cannot grant it the
 * same cycle, the adapter latches the result and re-presents it on subsequent
 * cycles until granted. This provides:
 *
 *   - Back-pressure signaling (`o_result_pending`) so the RS can stall new
 *     issues while a result is waiting for CDB access.
 *   - Optional zero-latency pass-through when the arbiter grants on the same
 *     cycle the FU result arrives. Set REGISTER_OUTPUT for long-latency or
 *     non-critical FUs when the pass-through valid cone hurts timing.
 *   - Pipeline flush support: `i_flush` (full) discards any held result on
 *     the next edge. `i_flush_en` (partial) discards held results whose tag
 *     is younger than `i_flush_tag` (relative to `i_rob_head_tag`). Same-cycle
 *     pass-through of a younger partial-flush result is still suppressed here;
 *     speculative full-flush CDB suppression is handled once at the arbiter.
 *
 * State machine (1 bit: result_pending):
 *
 *   IDLE + no input        -> output invalid, ready for new result
 *   IDLE + input valid     -> combinational pass-through to arbiter
 *     granted same cycle   -> stay IDLE (zero latency)
 *     not granted          -> latch into register, go PENDING
 *   PENDING                -> output from register, waiting for grant
 *     granted + new input  -> latch new input, stay PENDING (back-to-back)
 *     granted + no input   -> clear register, go IDLE
 *     flush / partial flush of held tag -> clear register, go IDLE
 */

module fu_cdb_adapter #(
    parameter bit ALLOW_GRANT_REFILL = 1'b1,
    parameter bit REGISTER_OUTPUT = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // FU result input (level signal: valid while result available)
    input riscv_pkg::fu_complete_t i_fu_result,

    // CDB arbiter interface
    output riscv_pkg::fu_complete_t o_fu_complete,
    input  logic                    i_grant,

    // Back-pressure to RS
    output logic o_result_pending,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial) — discard held/pass-through results younger than tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);

  // ---------------------------------------------------------------------------
  // Age comparison for partial flush
  // ---------------------------------------------------------------------------
  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;

  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age;
    logic [TagW:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------
  logic                    result_pending;
  riscv_pkg::fu_complete_t held_result;

  // ---------------------------------------------------------------------------
  // Partial flush detection (combinational)
  // ---------------------------------------------------------------------------
  logic                    partial_flush_held;
  logic                    partial_flush_input;

  assign partial_flush_held = i_flush_en & result_pending & is_younger(
      held_result.tag, i_flush_tag, i_rob_head_tag
  );
  assign partial_flush_input = i_flush_en & ~result_pending & i_fu_result.valid & is_younger(
      i_fu_result.tag, i_flush_tag, i_rob_head_tag
  );

  // ---------------------------------------------------------------------------
  // Output logic (combinational)
  // ---------------------------------------------------------------------------
  // Same-cycle partial flush of a younger pass-through result must still be
  // suppressed locally. Full-flush kill is centralized at the CDB arbiter so
  // this one-deep adapter doesn't have to carry that signal through its
  // output/held-result control cone.
  always_comb begin
    if (result_pending && !partial_flush_held) begin
      o_fu_complete = held_result;
    end else if (!REGISTER_OUTPUT && !result_pending && !partial_flush_input) begin
      o_fu_complete = i_fu_result;
    end else begin
      o_fu_complete = '0;
    end
  end

  assign o_result_pending = result_pending;

  // ---------------------------------------------------------------------------
  // Register logic
  // ---------------------------------------------------------------------------
  // Control: result_pending (with reset)
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      result_pending <= 1'b0;
    end else if (i_flush || partial_flush_held) begin
      result_pending <= 1'b0;
    end else if (result_pending && i_grant) begin
      result_pending <= ALLOW_GRANT_REFILL && i_fu_result.valid;
    end else if (!result_pending && i_fu_result.valid && !partial_flush_input) begin
      result_pending <= REGISTER_OUTPUT || !i_grant;
    end
  end

  // Data: held_result (no reset - gated by result_pending)
  // Writing the pass-through payload even on same-cycle grant/flush is safe:
  // result_pending is the only visibility bit, so any stale idle payload stays
  // dormant until the next pending capture overwrites it. This keeps grant and
  // full-flush off the wide held_result control cone.
  always_ff @(posedge i_clk) begin
    if ((ALLOW_GRANT_REFILL && result_pending && i_grant && i_fu_result.valid) ||
        (!result_pending && i_fu_result.valid)) begin
      held_result <= i_fu_result;
    end
  end

  // ===========================================================================
  // Debug traces (simulation only)
  // ===========================================================================
  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  // Standard formal preamble
  initial assume (!i_rst_n);
  initial assume (!result_pending);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // Grant is only meaningful when there's a result to grant
  // (either held in register or being passed through combinationally)
  always_comb begin
    a_no_grant_while_idle : assume (!i_grant || result_pending || i_fu_result.valid);
  end

  // Partial flush and full flush should not coincide
  always_comb begin
    a_no_partial_and_full_flush : assume (!(i_flush && i_flush_en));
  end

  // -------------------------------------------------------------------------
  // Safety assertions
  // -------------------------------------------------------------------------

  // When idle and no input: output is invalid
  always_comb begin
    if (!result_pending && !i_fu_result.valid) begin
      p_idle_no_input_no_valid : assert (!o_fu_complete.valid);
    end
  end

  // When pending and not partially flushed: output is always valid
  always_comb begin
    if (i_rst_n && result_pending && !partial_flush_held) begin
      p_pending_valid : assert (o_fu_complete.valid);
    end
  end

  // When idle with valid input and not partially flushed: pass-through mode
  // presents output immediately; registered-output mode captures first.
  always_comb begin
    if (!REGISTER_OUTPUT && !result_pending && i_fu_result.valid && !partial_flush_input) begin
      p_passthrough_valid : assert (o_fu_complete.valid);
    end
    if (REGISTER_OUTPUT && !result_pending) begin
      p_registered_idle_output_invalid : assert (!o_fu_complete.valid);
    end
  end

  // o_result_pending mirrors internal state
  always_comb begin
    p_pending_equals_output : assert (o_result_pending == result_pending);
  end

  // Tag stable while pending (no grant, no flush, no partial flush)
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && $past(
            result_pending
        ) && result_pending && !partial_flush_held && !$past(
            i_grant
        ) && !$past(
            i_flush
        ) && !$past(
            partial_flush_held
        )) begin
      p_tag_stable : assert (o_fu_complete.tag == $past(o_fu_complete.tag));
    end
  end

  // Value stable while pending (no grant, no flush, no partial flush)
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && $past(
            result_pending
        ) && result_pending && !partial_flush_held && !$past(
            i_grant
        ) && !$past(
            i_flush
        ) && !$past(
            partial_flush_held
        )) begin
      p_value_stable : assert (o_fu_complete.value == $past(o_fu_complete.value));
    end
  end

  // Exception fields stable while pending (no grant, no flush, no partial flush)
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && $past(
            result_pending
        ) && result_pending && !partial_flush_held && !$past(
            i_grant
        ) && !$past(
            i_flush
        ) && !$past(
            partial_flush_held
        )) begin
      p_exc_stable :
      assert (o_fu_complete.exception == $past(
          o_fu_complete.exception
      ) && o_fu_complete.exc_cause == $past(
          o_fu_complete.exc_cause
      ) && o_fu_complete.fp_flags == $past(
          o_fu_complete.fp_flags
      ));
    end
  end

  // Pass-through: tag matches input (when not partially flushed)
  always_comb begin
    if (!REGISTER_OUTPUT && !result_pending && i_fu_result.valid && !partial_flush_input) begin
      p_passthrough_tag : assert (o_fu_complete.tag == i_fu_result.tag);
    end
  end

  // Pass-through: value matches input (when not partially flushed)
  always_comb begin
    if (!REGISTER_OUTPUT && !result_pending && i_fu_result.valid && !partial_flush_input) begin
      p_passthrough_value : assert (o_fu_complete.value == i_fu_result.value);
    end
  end

  // Latch correctness: after captured idle input, next-cycle output matches.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && !$past(
            result_pending
        ) && $past(
            i_fu_result.valid
        ) && (REGISTER_OUTPUT || !$past(
            i_grant
        )) && !$past(
            i_flush
        ) && !$past(
            partial_flush_input
        ) && !partial_flush_held) begin
      p_latch_correct : assert (o_fu_complete == $past(i_fu_result));
    end
  end

  // Grant clears pending (when no new input, no flush)
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            result_pending
        ) && $past(
            i_grant
        ) && !$past(
            i_fu_result.valid
        ) && !$past(
            i_flush
        ) && !$past(
            partial_flush_held
        )) begin
      p_grant_clears : assert (!result_pending);
    end
  end

  // Flush clears pending
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_flush)) begin
      p_flush_clears : assert (!result_pending);
    end
  end

  // Partial flush of held result clears pending
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(partial_flush_held) && !$past(i_flush)) begin
      p_partial_flush_clears : assert (!result_pending);
    end
  end

  // Reset idle
  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst_n) begin
      p_reset_idle : assert (!result_pending);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Module in idle state
      cover_idle : cover (!result_pending && !i_fu_result.valid);

      // Pass-through result granted same cycle (zero latency)
      cover_passthrough_granted : cover (!result_pending && i_fu_result.valid && i_grant);

      // Pass-through fails, enters pending
      cover_passthrough_not_granted : cover (!result_pending && i_fu_result.valid && !i_grant);

      // Grant clears pending state
      cover_grant_clears : cover (result_pending && i_grant && !i_fu_result.valid);

      // Back-to-back: grant + new input while pending
      cover_back_to_back : cover (result_pending && i_grant && i_fu_result.valid);

      // Flush clears a pending result
      cover_flush_pending : cover (result_pending && i_flush);

      // Partial flush clears a pending result (younger tag)
      cover_partial_flush_pending : cover (partial_flush_held);

      // Partial flush suppresses pass-through (younger tag)
      cover_partial_flush_passthrough : cover (partial_flush_input);
    end
  end

  // Multi-cycle pending: result pending for 2+ cycles (contention scenario)
  reg [1:0] f_pending_count;
  initial f_pending_count = 2'd0;
  always @(posedge i_clk) begin
    if (!i_rst_n || !result_pending) f_pending_count <= 2'd0;
    else if (f_pending_count < 2'd3) f_pending_count <= f_pending_count + 2'd1;
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_multi_cycle_pending : cover (f_pending_count >= 2'd2 && result_pending);
    end
  end

`endif  // FORMAL

endmodule
