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
    output logic [TAG_BITS-1:0] o_tag
);
  wire arm = !o_active && i_arm_valid && i_head_valid && i_arm_tag == i_head_tag && !i_entry_wins;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_active <= 1'b0;
      o_retired <= 1'b0;
      o_tag <= '0;
    end else begin
      if (arm) begin
        o_active <= 1'b1;
        o_retired <= 1'b0;
        o_tag <= i_arm_tag;
      end
      if (o_active && i_commit_valid && i_commit_tag == o_tag) o_retired <= 1'b1;
      if (o_active && o_retired && !i_home_live) o_active <= 1'b0;
      if (o_active && i_own_fault && !i_home_live) o_active <= 1'b0;
    end
  end
`ifdef FORMAL
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
