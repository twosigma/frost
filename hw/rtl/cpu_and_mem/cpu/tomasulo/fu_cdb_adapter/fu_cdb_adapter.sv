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
 * One-entry buffer between an FU and the CDB arbiter. Idle inputs pass through
 * with zero latency unless REGISTER_OUTPUT is set for timing. An ungranted
 * result is held until granted; o_result_pending provides back-pressure.
 * REGISTER_OUTPUT captures inputs before presenting them, adding one cycle.
 *
 * With ALLOW_GRANT_REFILL, a grant can replace a held result with a new input.
 * A pending adapter ignores new inputs without a grant. A grant without a
 * refill returns it to idle.
 *
 * i_flush clears pending state at the next edge; the arbiter must suppress
 * broadcasts during that cycle. i_flush_en suppresses held and incoming
 * results younger than i_flush_tag, measured from i_rob_head_tag. A squashed
 * input cannot refill the buffer, and a squashed held result returns it to idle.
 */

module fu_cdb_adapter #(
    parameter bit ALLOW_GRANT_REFILL = 1'b1,
    // Set to 0 only if valid inputs cannot arrive while pending. This uses
    // i_fu_result.valid as the payload write enable; ALLOW_GRANT_REFILL still
    // controls result_pending.
    parameter bit ALLOW_GRANT_REFILL_PAYLOAD_WRITE = 1'b1,
    parameter bit REGISTER_OUTPUT = 1'b0,
    // Requires a grant for every valid output unless i_flush discards it,
    // with REGISTER_OUTPUT=0 and ALLOW_GRANT_REFILL=0. Pending stays zero.
    // The wrapper uses this for the two highest-priority CDB sources.
    parameter bit ALWAYS_GRANTED = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // FU result input (level signal: valid while result available)
    input riscv_pkg::fu_complete_t i_fu_result,

    // CDB arbiter interface
    output riscv_pkg::fu_complete_t o_fu_complete,
    input  logic                    i_grant,

    // Unqualified held_result.value: the wrapper's pending ALU fallback and
    // captured pass-through value for restore after the CDB register.
    // See the CDB arbiter README, "Live ALU values".
    output logic [riscv_pkg::FLEN-1:0] o_held_value,

    // A result is held here (back-pressure for the producer)
    output logic o_result_pending,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial): discards held and passed-through results younger than tag
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
  // Filter incoming results even while pending: a squashed refill could
  // otherwise survive the flush and broadcast to a reused ROB tag.
  assign partial_flush_input = i_flush_en & i_fu_result.valid & is_younger(
      i_fu_result.tag, i_flush_tag, i_rob_head_tag
  );

  // ---------------------------------------------------------------------------
  // Output logic (combinational)
  // ---------------------------------------------------------------------------
  // Partial flush kills only valid; consumers must ignore invalid payloads.
  // Full-flush output suppression is the CDB arbiter's responsibility.
  always_comb begin
    if (result_pending) begin
      o_fu_complete       = held_result;
      o_fu_complete.valid = !partial_flush_held;
    end else if (!REGISTER_OUTPUT) begin
      o_fu_complete       = i_fu_result;
      o_fu_complete.valid = i_fu_result.valid && !partial_flush_input;
    end else begin
      o_fu_complete = '0;
    end
  end

  assign o_result_pending = result_pending;
  assign o_held_value     = held_result.value;

  // ---------------------------------------------------------------------------
  // Register logic
  // ---------------------------------------------------------------------------
  // ALWAYS_GRANTED removes pending state and its payload mux.
  generate
    if (ALWAYS_GRANTED) begin : gen_always_granted
      assign result_pending = 1'b0;
`ifndef SYNTHESIS
      initial begin
        assert (!REGISTER_OUTPUT && !ALLOW_GRANT_REFILL);
      end
      always_ff @(posedge i_clk) begin
        if (i_rst_n && o_fu_complete.valid && !i_flush) begin
          p_valid_result_is_granted : assert (i_grant);
        end
      end
`endif
    end else begin : gen_pending_state
      always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
          result_pending <= 1'b0;
        end else if (i_flush || partial_flush_held) begin
          result_pending <= 1'b0;
        end else if (result_pending && i_grant) begin
          // Refills must obey the same partial-flush filter as idle captures.
          result_pending <= ALLOW_GRANT_REFILL && i_fu_result.valid && !partial_flush_input;
        end else if (!result_pending && i_fu_result.valid && !partial_flush_input) begin
          result_pending <= REGISTER_OUTPUT || !i_grant;
        end
      end
    end
  endgenerate

  // held_result needs no reset: result_pending gates its use in o_fu_complete.
  // Capturing idle inputs during grant/flush is safe; a later pending capture
  // overwrites stale data. The wrapper's o_held_value uses require every idle
  // input to be captured, including inputs granted in the same cycle.
  generate
    if (ALLOW_GRANT_REFILL_PAYLOAD_WRITE) begin : gen_grant_refill_payload_write
      // Capture an idle input or a granted refill.
      always_ff @(posedge i_clk) begin
        if ((ALLOW_GRANT_REFILL && result_pending && i_grant && i_fu_result.valid) ||
            (!result_pending && i_fu_result.valid)) begin
          held_result <= i_fu_result;
        end
      end
    end else begin : gen_unqualified_payload_write
      // Requires i_fu_result.valid -> !result_pending, so this is equivalent
      // to the idle-capture arm above.
      always_ff @(posedge i_clk) begin
        if (i_fu_result.valid) begin
          held_result <= i_fu_result;
        end
      end
    end
  endgenerate

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

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

  // A grant requires a held result or a valid input.
  always_comb begin
    a_no_grant_while_idle : assume (!i_grant || result_pending || i_fu_result.valid);

    if (!ALLOW_GRANT_REFILL_PAYLOAD_WRITE) begin
      // The caller must establish this invariant. In tomasulo_wrapper, each
      // pending ALU adapter blocks its RS issue-ready input.
      a_no_input_while_pending : assume (!(result_pending && i_fu_result.valid));
    end
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

  // In this mode, every valid input is captured and must arrive while idle.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && !ALLOW_GRANT_REFILL_PAYLOAD_WRITE && $past(
            i_rst_n
        ) && $past(
            i_fu_result.valid
        )) begin
      p_simplified_payload_capture : assert (held_result == $past(i_fu_result));
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
      cover_idle : cover (!result_pending && !i_fu_result.valid);

      cover_passthrough_granted : cover (!result_pending && i_fu_result.valid && i_grant);

      cover_passthrough_not_granted : cover (!result_pending && i_fu_result.valid && !i_grant);

      cover_grant_clears : cover (result_pending && i_grant && !i_fu_result.valid);

      cover_back_to_back : cover (result_pending && i_grant && i_fu_result.valid);

      cover_flush_pending : cover (result_pending && i_flush);

      cover_partial_flush_pending : cover (partial_flush_held);

      cover_partial_flush_passthrough : cover (partial_flush_input);
    end
  end

  // -------------------------------------------------------------------------
  // A tag squashed in held state or an incoming refill must not reappear on a
  // valid output until a new input presents it under ROB tag reuse. See the
  // tomasulo README, "CDB priority and tag reuse".
  // -------------------------------------------------------------------------
  (* anyconst *) logic [TagW-1:0] f_watch_tag;

  logic f_watch_squashed_now;
  assign f_watch_squashed_now = (i_flush_en && is_younger(
      f_watch_tag, i_flush_tag, i_rob_head_tag
  ) && ((result_pending && held_result.tag == f_watch_tag) ||
        (i_fu_result.valid && i_fu_result.tag == f_watch_tag))) ||
      (i_flush && ((result_pending && held_result.tag == f_watch_tag) ||
                   (i_fu_result.valid && i_fu_result.tag == f_watch_tag)));

  logic f_watch_refire;
  assign f_watch_refire = i_fu_result.valid && (i_fu_result.tag == f_watch_tag);

  logic f_watch_dead_q;
  initial f_watch_dead_q = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_watch_dead_q <= 1'b0;
    else if (f_watch_squashed_now) f_watch_dead_q <= 1'b1;
    else if (f_watch_refire) f_watch_dead_q <= 1'b0;
  end

  always_comb begin
    if (i_rst_n && f_watch_dead_q && !f_watch_refire && o_fu_complete.valid) begin
      p_no_stale_output : assert (o_fu_complete.tag != f_watch_tag);
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_watch_squashed_held : cover (f_watch_squashed_now && result_pending);
      cover_watch_squashed_refill :
      cover (f_watch_squashed_now && result_pending && i_grant && i_fu_result.valid);
    end
  end

  // Cover the adapter staying pending for two or more cycles (contention),
  // counting grant-refill cycles.
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
