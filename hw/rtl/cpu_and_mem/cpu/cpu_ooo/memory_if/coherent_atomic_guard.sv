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

// Selected atomic ownership covers request presentation, retirement and release.
module coherent_atomic_guard #(
    parameter int unsigned TAG_BITS = 5
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_arm_valid,
    input logic [TAG_BITS-1:0] i_arm_tag,
    input logic i_head_valid,
    input logic [TAG_BITS-1:0] i_head_tag,
    input logic i_entry_wins,
    input logic i_commit_valid,
    input logic [TAG_BITS-1:0] i_commit_tag,
    input logic i_home_live,
    input logic i_own_fault,
    output logic o_active,
    output logic o_retired,
    // The active context qualifies the tag.
    output logic [TAG_BITS-1:0] o_tag
);
  logic [1:0] context_choice[2];
  logic [1:0] selected_context;
  for (genvar arm_case = 0; arm_case < 2; arm_case++) begin : gen_arm_case
    localparam bit CanArm = arm_case != 0;
    (* keep = "true" *) logic [1:0] result;
    logic active, retired;
    always_comb begin
      active  = o_active;
      retired = o_retired;
      if (!o_active && CanArm && i_head_valid && i_arm_tag == i_head_tag) begin
        active  = 1'b1;
        retired = 1'b0;
      end
      if (o_active && i_commit_valid && i_commit_tag == o_tag) retired = 1'b1;
      if (o_active && o_retired && !i_home_live) active = 1'b0;
      if (o_active && i_own_fault && !i_home_live) active = 1'b0;
    end
    assign result = {active, retired};
    assign context_choice[arm_case] = result;
  end
  always_comb begin
    selected_context = context_choice[0];
    if (i_arm_valid && !i_entry_wins) selected_context = context_choice[1];
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_active <= 1'b0;
      o_retired <= 1'b0;
      o_tag <= '0;
    end else begin
      if (!o_active) o_tag <= i_arm_tag;
      {o_active, o_retired} <= selected_context;
    end
  end
`ifndef SYNTHESIS
  logic reference_active, reference_retired;
  logic [TAG_BITS-1:0] reference_tag;
  logic reference_seen = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reference_active <= 1'b0;
      reference_retired <= 1'b0;
      reference_tag <= '0;
      reference_seen <= 1'b1;
    end else begin
      if (!reference_active && i_arm_valid && i_head_valid &&
          i_arm_tag == i_head_tag && !i_entry_wins) begin
        reference_active <= 1'b1;
        reference_retired <= 1'b0;
        reference_tag <= i_arm_tag;
      end
      if (reference_active && i_commit_valid && i_commit_tag == reference_tag)
        reference_retired <= 1'b1;
      if (reference_active && reference_retired && !i_home_live) reference_active <= 1'b0;
      if (reference_active && i_own_fault && !i_home_live) reference_active <= 1'b0;
    end
    if (reference_seen) begin
      assert (o_active == reference_active);
      assert (o_retired == reference_retired);
      if (o_active) assert (o_tag == reference_tag);
    end
  end
`endif
`ifdef FORMAL
  wire  arm = !o_active && i_arm_valid && i_head_valid && i_arm_tag == i_head_tag && !i_entry_wins;
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(arm)) begin
        assert (o_active && !o_retired);
        assert (o_tag == $past(i_arm_tag));
      end
      if ($past(o_active)) begin
        assert (o_tag == $past(o_tag));
        if ($past(i_home_live)) assert (o_active);
        if (!$past(o_retired || i_own_fault)) assert (o_active);
      end
      if (o_active && !$past(o_active)) assert ($past(arm));
      if ($past(o_active) && !o_active) assert ($past(!i_home_live && (o_retired || i_own_fault)));
      if ($past(o_active && !o_retired) && o_retired)
        assert ($past(i_commit_valid && i_commit_tag == o_tag));
      if ($past(!o_active && i_entry_wins)) assert (!o_active);
      cover (o_active && o_retired && i_home_live);
      cover ($past(o_active && o_retired) && !o_active);
    end
  end
`endif
endmodule
