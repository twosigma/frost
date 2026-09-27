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

// Compare the wrapper's local MUL grant with the actual arbiter grant.
// The reference includes arbitrary competing and injected completions; all
// flush controls, tags, and input payloads are free. Only an initial reset
// is assumed. The adapters must match on every completion bit (even invalid
// payloads) and pending state, and neither adapter may ever hold a result.
// The MUL wrapper leaves the unqualified o_held_value output unused.
module mul_adapter_grant (
    input logic i_clk
);
  (* anyseq *) logic rst_n, flush, flush_en;
  (* anyseq *) riscv_pkg::fu_complete_t
      incoming, injected, alu, mem, div_req, fp_add, fp_mul, fp_div, alu2;
  (* anyseq *) logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag, head_tag;
  riscv_pkg::fu_complete_t reference_out, direct_out, arb_mul;
  logic reference_pending, direct_pending;
  logic [riscv_pkg::NumFus-1:0] grants;
  assign arb_mul = reference_out.valid ? reference_out : injected;

  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
  ) reference_adapter (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_fu_result(incoming),
      .o_fu_complete(reference_out),
      .i_grant(grants[riscv_pkg::FU_MUL]),
      .o_held_value(),
      .o_result_pending(reference_pending),
      .i_flush(flush),
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_rob_head_tag(head_tag)
  );
  fu_cdb_adapter #(
      .ALLOW_GRANT_REFILL(1'b0)
  ) direct_adapter (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_fu_result(incoming),
      .o_fu_complete(direct_out),
      .i_grant(direct_out.valid),
      .o_held_value(),
      .o_result_pending(direct_pending),
      .i_flush(flush),
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_rob_head_tag(head_tag)
  );
  cdb_arbiter arbiter (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_fu_complete_0(alu),
      .i_fu_complete_1(arb_mul),
      .i_fu_complete_2(div_req),
      .i_fu_complete_3(mem),
      .i_fu_complete_4(fp_add),
      .i_fu_complete_5(fp_mul),
      .i_fu_complete_6(fp_div),
      .i_fu_complete_7(alu2),
      .i_alu_value_is_live(1'b0),
      .i_alu_live_value('0),
      .i_alu_tree_fallback_value(alu.value),
      .i_alu2_value_is_live(1'b0),
      .i_alu2_live_value('0),
      .i_alu2_tree_fallback_value(alu2.value),
      .i_kill(flush),
      .o_cdb(),
      .o_cdb_2(),
      .o_grant(grants),
      .o_grant_raw(),
      .o_lane0_tree_fallback_value(),
      .o_lane1_tree_fallback_value(),
      .o_lane0_select_alu_live(),
      .o_lane0_select_alu2_live(),
      .o_lane1_select_alu_live(),
      .o_lane1_select_alu2_live()
  );

  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) begin
      assume (!rst_n);
    end else begin
      assert (reference_pending == direct_pending);
      assert (!reference_pending && !direct_pending);
      assert (reference_out == direct_out);
      cover (incoming.valid && reference_out.valid && !flush);
      cover (incoming.valid && flush_en && !reference_out.valid);
      cover (incoming.valid && flush);
      cover (!reference_out.valid && injected.valid && grants[riscv_pkg::FU_MUL]);
    end
  end
endmodule
