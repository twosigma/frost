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

// Independent pin inputs cover complete groups and tails padded with zeros.
module lq_age_groups (
    input logic [2:0] i_younger,
    input logic [2:0] i_selected,
    input logic i_ready,
    input logic i_valid,
    input logic i_issued,
    input logic i_data_valid,
    input logic i_in_flight
);
  logic full_group, pair_group, single_group;
  coherent_lq_age_group full_dut (
      .i_younger,
      .i_selected,
      .o_older(full_group)
  );
  coherent_lq_age_group pair_dut (
      .i_younger({1'b0, i_younger[1:0]}),
      .i_selected({1'b0, i_selected[1:0]}),
      .o_older(pair_group)
  );
  coherent_lq_age_group single_dut (
      .i_younger({2'b0, i_younger[0]}),
      .i_selected({2'b0, i_selected[0]}),
      .o_older(single_group)
  );
  logic entry_eligible;
  coherent_lq_entry_eligible eligibility_dut (
      .i_ready,
      .i_valid,
      .i_issued,
      .i_data_valid,
      .i_in_flight,
      .o_eligible(entry_eligible)
  );
  always_comb begin
    assert (entry_eligible == (i_ready && i_valid && !(i_issued || i_data_valid || i_in_flight)));
    assert (full_group == ((i_younger[0] && i_selected[0]) ||
        (i_younger[1] && i_selected[1]) || (i_younger[2] && i_selected[2])));
    assert (pair_group == ((i_younger[0] && i_selected[0]) || (i_younger[1] && i_selected[1])));
    assert (single_group == (i_younger[0] && i_selected[0]));
  end
endmodule
