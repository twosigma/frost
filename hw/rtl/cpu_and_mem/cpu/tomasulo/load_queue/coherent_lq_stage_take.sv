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

// Completion selects capture permission after candidate and age selection.
module coherent_lq_stage_take #(
    parameter int unsigned DEPTH = 8
) (
    input logic i_clk,
    input logic [3:0] i_pending,
    input logic i_clear,
    input logic i_gate,
    input logic i_update,
    input logic [DEPTH-1:0] i_staged_younger,
    input logic [DEPTH-1:0] i_head_stored,
    input logic [DEPTH-1:0] i_head_update,
    input logic [DEPTH-1:0] i_stored_scan,
    input logic [DEPTH-1:0] i_merged_scan,
    input logic i_head_stored_found,
    input logic i_head_update_found,
    output logic [3:0] o_take
);
  for (genvar copy_index = 0; copy_index < 4; copy_index++) begin : gen_copy
    logic [1:0] choices;
    for (genvar cleared = 0; cleared < 2; cleared++) begin : gen_clear_choice
      logic [DEPTH-1:0] permitted;
      logic stored_head, update_head, stored_scan, merged_scan;
      logic without_update, with_update;
      (* keep = "true" *) logic take;
      assign permitted = {DEPTH{!i_pending[copy_index] || 1'(cleared)}} |
          (i_staged_younger & {DEPTH{i_pending[0]}});
      assign stored_head = |(permitted & i_head_stored);
      assign update_head = |(permitted & i_head_update);
      assign stored_scan = |(permitted & i_stored_scan);
      assign merged_scan = |(permitted & i_merged_scan);
      assign without_update = i_head_stored_found ? stored_head : stored_scan;
      assign with_update = i_head_stored_found ? stored_head :
          i_head_update_found ? update_head : merged_scan;
      assign take = i_gate && (i_update ? with_update : without_update);
      assign choices[cleared] = take;
    end
    assign o_take[copy_index] = i_clear ? choices[1] : choices[0];
`ifndef SYNTHESIS
    wire [DEPTH-1:0] permitted = {DEPTH{!i_pending[copy_index] || i_clear}} |
        (i_staged_younger & {DEPTH{i_pending[0]}});
    wire stored_head = |(permitted & i_head_stored);
    wire update_head = |(permitted & i_head_update);
    wire stored_scan = |(permitted & i_stored_scan);
    wire merged_scan = |(permitted & i_merged_scan);
    wire without_update = i_head_stored_found ? stored_head : stored_scan;
    wire with_update = i_head_stored_found ? stored_head :
        i_head_update_found ? update_head : merged_scan;
    wire reference_take = i_gate && (i_update ? with_update : without_update);
`ifdef FORMAL
    always_comb begin
`else
    always @(posedge i_clk) begin
`endif
      assert (o_take[copy_index] == reference_take);
    end
`endif
  end
endmodule
