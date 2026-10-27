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

module coherent_atomic_select_formal #(
    parameter int unsigned TAG_BITS = 5
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_sc_valid,
    input logic [TAG_BITS-1:0] i_sc_tag,
    input logic i_amo_valid,
    input logic [TAG_BITS-1:0] i_amo_tag,
    input logic i_head_valid,
    input logic [TAG_BITS-1:0] i_head_tag,
    input logic i_entry_wins,
    input logic i_commit_valid,
    input logic [TAG_BITS-1:0] i_commit_tag,
    input logic i_home_live,
    input logic i_own_fault
);
  logic arm_valid;
  logic [TAG_BITS-1:0] arm_tag;
  coherent_atomic_select #(
      .TAG_BITS(TAG_BITS)
  ) select_arm (
      .i_sc_valid,
      .i_sc_tag,
      .i_amo_valid,
      .i_amo_tag,
      .i_head_tag,
      .o_arm_valid(arm_valid),
      .o_arm_tag  (arm_tag)
  );
  logic [1:0] active, retired;
  logic [TAG_BITS-1:0] tag[2];
  for (genvar selection = 0; selection < 2; selection++) begin : gen_guard
    coherent_atomic_guard #(
        .TAG_BITS(TAG_BITS)
    ) guard (
        .i_clk,
        .i_rst,
        .i_arm_valid(selection == 0 ? (i_sc_valid || i_amo_valid) : arm_valid),
        .i_arm_tag(selection == 0 ? (i_sc_valid ? i_sc_tag : i_amo_tag) : arm_tag),
        .i_head_valid,
        .i_head_tag,
        .i_entry_wins,
        .i_commit_valid,
        .i_commit_tag,
        .i_home_live,
        .i_own_fault,
        .o_active(active[selection]),
        .o_retired(retired[selection]),
        .o_tag(tag[selection])
    );
  end
  logic past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_rst);
    if (past_valid) begin
      p_active_exact : assert (active[0] == active[1]);
      p_retired_exact : assert (retired[0] == retired[1]);
      if (active[0]) p_active_tag_exact : assert (tag[0] == tag[1]);
    end
  end
endmodule
