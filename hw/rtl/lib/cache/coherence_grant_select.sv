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

// Endpoint zero has reserved credit. Nonzero endpoints share free credit.
module coherence_grant_select #(
    parameter int unsigned SLOTS = 8,
    localparam int unsigned IndexBits = $clog2(SLOTS)
) (
    input logic [SLOTS-1:0] i_offer,
    input logic i_zero_credit,
    input logic i_other_credit,
    output logic o_valid,
    output logic [IndexBits-1:0] o_index,
    output logic [SLOTS-1:0] o_onehot
);
  logic zero_selected;
  (* keep = "true" *) logic [SLOTS-1:1] other_first;
  logic [IndexBits-1:0] other_index;
  assign zero_selected = i_offer[0] && i_zero_credit;
  for (genvar slot = 1; slot < SLOTS; slot++) begin : gen_other
    if (slot == 1) assign other_first[slot] = i_offer[slot];
    else assign other_first[slot] = i_offer[slot] && !(|i_offer[slot-1:1]);
  end
  always_comb begin
    other_index = '0;
    for (int slot = 1; slot < SLOTS; slot++)
    other_index |= IndexBits'(slot) & {IndexBits{other_first[slot]}};
  end
  assign o_valid = zero_selected || (i_other_credit && |i_offer[SLOTS-1:1]);
  assign o_index = !zero_selected && i_other_credit ? other_index : '0;
  assign o_onehot[0] = zero_selected;
  assign o_onehot[SLOTS-1:1] = other_first & {(SLOTS - 1) {i_other_credit && !zero_selected}};

`ifndef SYNTHESIS
  logic ref_valid;
  logic [IndexBits-1:0] ref_index;
  logic [SLOTS-1:0] ref_onehot;
  always_comb begin
    ref_valid  = 1'b0;
    ref_index  = '0;
    ref_onehot = '0;
    for (int slot = SLOTS - 1; slot >= 0; slot--)
    if (i_offer[slot] && (slot == 0 ? i_zero_credit : i_other_credit)) begin
      ref_valid = 1'b1;
      ref_index = IndexBits'(slot);
    end
    if (ref_valid) ref_onehot[ref_index] = 1'b1;
    p_grant_valid_exact : assert (o_valid == ref_valid);
    p_grant_index_exact : assert (o_index == ref_index);
    p_grant_onehot_exact : assert (o_onehot == ref_onehot);
  end
`endif
endmodule
