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

// Checks that the MUL shim may leave its result tag unqualified on invalid
// cycles. Two fu_cdb_adapters set up like the wrapper's MUL adapter see the
// same inputs, except that old_adapter gets the tag zeroed while the result
// is invalid (the reference) and raw_adapter gets it unqualified. Their
// pending bits, valid outputs, valid payloads, and arbiter inputs must match.
// The .sby reads the adapter without -formal, so its own assertions and
// assumptions are left out. Only the first cycle's reset is assumed.
module mul_completion_tag (
    input logic i_clk
);
  (* anyseq *) logic rst_n, grant, flush, flush_en;
  (* anyseq *)riscv_pkg::fu_complete_t raw;
  (* anyseq *)riscv_pkg::fu_complete_t injected;
  (* anyseq *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag, head_tag;
  riscv_pkg::fu_complete_t zeroed_tag, old_out, raw_out;
  riscv_pkg::fu_complete_t old_arb_input, raw_arb_input;
  logic old_pending, raw_pending;

  always_comb begin
    zeroed_tag = raw;
    zeroed_tag.tag = raw.valid ? raw.tag : '0;
    // The wrapper's arbiter input (the adapter output, else the test-injection
    // port) must match too, even with no valid result: it takes the adapter
    // payload only when valid.
    old_arb_input = old_out.valid ? old_out : injected;
    raw_arb_input = raw_out.valid ? raw_out : injected;
  end

  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
  ) old_adapter (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_fu_result(zeroed_tag),
      .o_fu_complete(old_out),
      .i_grant(grant),
      .o_held_value(),
      .o_result_pending(old_pending),
      .i_flush(flush),
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_rob_head_tag(head_tag)
  );
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
  ) raw_adapter (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_fu_result(raw),
      .o_fu_complete(raw_out),
      .i_grant(grant),
      .o_held_value(),
      .o_result_pending(raw_pending),
      .i_flush(flush),
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_rob_head_tag(head_tag)
  );

  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid)
      assume (!rst_n);
      else begin
        assert (old_pending == raw_pending);
        assert (old_out.valid == raw_out.valid);
        assert (!old_out.valid || old_out == raw_out);
        assert (old_arb_input == raw_arb_input);
        cover (raw.valid && raw_out.valid && !raw_pending && grant);
        cover (raw_pending && raw_out.valid && grant);
        cover (raw.valid && !raw_pending && flush_en && !raw_out.valid);
        cover (raw_pending && flush_en && !raw_out.valid);
        cover (raw_pending && flush);
        cover (!raw.valid && !raw_pending && flush_en && raw.tag != 0 &&
             old_out.tag != raw_out.tag);
      end
  end
endmodule
