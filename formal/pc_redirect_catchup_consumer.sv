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

module pc_redirect_catchup_consumer (
    input logic i_clk,
    i_reset,
    i_pc_update_en,
    input logic [riscv_pkg::PcNextArms-1:1] i_npc_cond,
    i_npc_seq,
    input logic i_live_prediction_emits_with_output
);
  logic old_redirect, new_redirect;
  logic [riscv_pkg::PcNextArms-1:1] condensed;
  always_comb begin
    condensed = i_npc_cond;
    condensed[11] = 1'b0;
    assume (i_npc_seq[11]);
    assume (i_npc_seq[13]);
    assume (!(i_npc_cond[11] && i_npc_cond[12]));
  end
  fetch_redirect old_impl (
      .i_clk,
      .i_reset,
      .i_pc_update_en,
      .i_npc_cond,
      .i_npc_seq,
      .i_live_prediction_emits_with_output,
      .o_fetch_redirect(old_redirect)
  );
  fetch_redirect new_impl (
      .i_clk,
      .i_reset,
      .i_pc_update_en,
      .i_npc_cond(condensed),
      .i_npc_seq,
      .i_live_prediction_emits_with_output,
      .o_fetch_redirect(new_redirect)
  );
  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) past_valid <= 1'b1;
  always_comb if (past_valid) assert (old_redirect == new_redirect);
endmodule
