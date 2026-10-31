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

module debug_dirty_next (
    input logic [15:0] i_dirty,
    input logic i_reseed,
    input logic [15:0] i_seed,
    input logic i_clear_valid,
    input logic [3:0] i_clear_index,
    input logic i_ready,
    input logic [15:0] i_set,
    output logic [15:0] o_dirty
);
  logic [15:0] choice[2];
  for (genvar ready_case = 0; ready_case < 2; ready_case++) begin : gen_ready_case
    localparam bit Ready = ready_case != 0;
    (* keep = "true" *) logic [15:0] result;
    always_comb begin
      result = i_dirty;
      if (i_reseed) result = i_seed;
      if (Ready && i_clear_valid) result[i_clear_index] = 1'b0;
      result = result | i_set;
    end
    assign choice[ready_case] = result;
  end
  always_comb begin
    o_dirty = choice[0];
    if (i_ready) o_dirty = choice[1];
  end
`ifdef FORMAL
  logic [15:0] reference_dirty;
  always_comb begin
    reference_dirty = i_dirty;
    if (i_reseed) reference_dirty = i_seed;
    if (i_clear_valid && i_ready) reference_dirty[i_clear_index] = 1'b0;
    reference_dirty = reference_dirty | i_set;
    p_dirty_next_exact : assert (o_dirty == reference_dirty);
  end
`endif
endmodule
