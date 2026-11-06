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
    input logic [SLOTS-1:0] i_failure,
    input logic [SLOTS-1:0] i_owner_store,
    input logic [SLOTS-1:0] i_grant_failure,
    input logic [SLOTS-1:0] i_grant_error,
    input logic i_zero_credit,
    input logic i_other_credit,
    output logic o_valid,
    output logic [IndexBits-1:0] o_index,
    output logic [SLOTS-1:0] o_onehot,
    output logic o_failure,
    output logic o_owner_store,
    output logic o_grant_failure,
    output logic o_grant_error
);
  (* keep = "true" *) logic [SLOTS-1:0] offered, failure;
  (* keep = "true" *) logic zero_selected, other_allowed, other_failure;
  (* keep = "true" *) logic [SLOTS-1:1] other_first;
  logic [IndexBits-1:0] other_index;
  (* keep = "true" *) logic other_selected;
  (* keep = "true" *) logic [2:0] other_fields;
  assign offered = i_offer;
  assign failure = i_failure;
  assign zero_selected = offered[0] && i_zero_credit;
  assign other_allowed = i_other_credit && !zero_selected;
  for (genvar slot = 1; slot < SLOTS; slot++) begin : gen_other
    if (slot == 1) assign other_first[slot] = offered[slot];
    else assign other_first[slot] = offered[slot] && !(|offered[slot-1:1]);
  end
  always_comb begin
    other_index = '0;
    for (int slot = 1; slot < SLOTS; slot++)
    other_index |= IndexBits'(slot) & {IndexBits{other_first[slot]}};
  end
  // Packet attributes share the unqualified nonzero priority decision.
  // An idle decision selects endpoint zero.
  assign other_selected = other_allowed && |offered[SLOTS-1:1];
  always_comb begin
    other_fields = '0;
    for (int slot = 1; slot < SLOTS; slot++)
    other_fields |= {i_owner_store[slot], i_grant_failure[slot], i_grant_error[slot]} &
          {3{other_first[slot]}};
  end
  assign {o_owner_store, o_grant_failure, o_grant_error} = other_selected ?
      other_fields : {i_owner_store[0], i_grant_failure[0], i_grant_error[0]};
  assign o_valid = zero_selected || (i_other_credit && |offered[SLOTS-1:1]);
  assign o_index = other_allowed ? other_index : '0;
  assign o_onehot[0] = zero_selected;
  assign o_onehot[SLOTS-1:1] = other_first & {(SLOTS - 1) {other_allowed}};
  assign other_failure = |(other_first & failure[SLOTS-1:1]);
  assign o_failure = (zero_selected && failure[0]) || (other_allowed && other_failure);

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
    p_grant_fields_exact :
    assert ({o_owner_store, o_grant_failure, o_grant_error} ==
        {i_owner_store[ref_index], i_grant_failure[ref_index], i_grant_error[ref_index]});
    p_grant_valid_exact : assert (o_valid == ref_valid);
    p_grant_index_exact : assert (o_index == ref_index);
    p_grant_onehot_exact : assert (o_onehot == ref_onehot);
    p_grant_failure_exact : assert (o_failure == (ref_valid && |(ref_onehot & i_failure)));
  end
`endif
endmodule
