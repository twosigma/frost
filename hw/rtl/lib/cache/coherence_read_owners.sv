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

// Endpoint ownership excludes stores from the read-slot mask.
module coherence_read_owners #(
    parameter int unsigned SLOTS = 4
) (
    input logic i_clk,
    input logic [SLOTS-1:0] i_live,
    input logic [SLOTS-1:0] i_store,
    input logic [SLOTS-1:0] i_installed,
    input logic i_zero_sc,
    input logic [3*SLOTS-1:0] i_read_slot,
    output logic [7:0] o_owned
);
  (* keep = "true" *) logic [7:0][SLOTS-1:0] owner_terms;
  (* keep = "true" *) logic [7:0] owned;
  for (genvar slot = 0; slot < 8; slot++) begin : gen_slot
    for (genvar ep = 0; ep < SLOTS; ep++) begin : gen_endpoint
      if (ep == 0) begin : gen_zero
        assign owner_terms[slot][ep] = i_live[ep] && !i_store[ep] && !i_zero_sc &&
            i_read_slot[3*ep+:3] == 3'(slot);
      end else begin : gen_nonzero
        assign owner_terms[slot][ep] = i_live[ep] && !i_store[ep] && !i_installed[ep] &&
            i_read_slot[3*ep+:3] == 3'(slot);
      end
    end
    assign owned[slot] = |owner_terms[slot];
  end
  assign o_owned = owned;
`ifndef SYNTHESIS
  logic [7:0] reference_owned;
  always_comb begin
    reference_owned = '0;
    if (i_live[0] && !i_store[0] && !i_zero_sc) reference_owned[i_read_slot[0+:3]] = 1'b1;
    for (int ep = 1; ep < SLOTS; ep++)
    if (i_live[ep] && !i_store[ep] && !i_installed[ep])
      reference_owned[i_read_slot[3*ep+:3]] = 1'b1;
  end
`ifdef FORMAL
  always_comb begin
    p_read_owner_exact : assert (o_owned == reference_owned);
  end
`else
  always @(posedge i_clk)
    if (!$isunknown({i_live, i_store, i_installed, i_zero_sc, i_read_slot}))
      p_read_owner_exact : assert (o_owned == reference_owned);
`endif
`endif
endmodule
