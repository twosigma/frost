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
    // Local service ownership or a home transaction awaiting U.
    input logic i_home_live,
    input logic i_own_fault,
    output logic o_active,
    output logic o_retired,
    // The active context qualifies the tag.
    output logic [TAG_BITS-1:0] o_tag
);
  // The guard's inputs arrive at the end of the ROB head's commit, trap and
  // xRET logic, so they are registered as they arrive and the guard forms
  // its state from them on the next cycle. In closed form, an idle guard arms
  // on an arm request whose tag is the valid ROB head with no winning entry;
  // an active guard retires on its commit and releases once retired or
  // faulted with the home idle. Applied to the registered previous state and
  // inputs, that gives o_active and o_retired the values a next-state register
  // would hold, on every cycle.
  logic active_q, retired_q;
  logic home_live_q, own_fault_q, commit_hit_q, arm_match_q, entry_wins_q;
  logic arm_now_q;
  assign arm_now_q = arm_match_q && !entry_wins_q;
  assign o_active  = active_q ? (home_live_q || (!retired_q && !own_fault_q)) : arm_now_q;
  assign o_retired = active_q ? (retired_q || commit_hit_q) : (retired_q && !arm_now_q);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      active_q <= 1'b0;
      retired_q <= 1'b0;
      arm_match_q <= 1'b0;
      o_tag <= '0;
    end else begin
      active_q <= o_active;
      retired_q <= o_retired;
      arm_match_q <= i_arm_valid && i_head_valid && i_arm_tag == i_head_tag;
      if (!o_active) o_tag <= i_arm_tag;
    end
    // Read only through active_q and arm_match_q, which reset clears.
    home_live_q  <= i_home_live;
    own_fault_q  <= i_own_fault;
    commit_hit_q <= i_commit_valid && i_commit_tag == o_tag;
    entry_wins_q <= i_entry_wins;
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
