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

// Independent reference for every ready/later combination.
module coherence_home_forward_pins #(
    parameter int unsigned FILLS = 8
) (
    input logic [FILLS-1:0] i_ready,
    input logic [FILLS-1:0] i_later
);
  logic [FILLS-1:0] selected, reference_pick;
  coherence_home_forward_turn_select #(
      .FILLS(FILLS)
  ) dut (
      .i_ready,
      .i_later,
      .o_pick(selected)
  );
  always_comb begin
    reference_pick = '0;
    for (int fill = FILLS - 1; fill >= 0; fill--) begin
      if ((|(i_ready & i_later)) ? (i_ready[fill] && i_later[fill]) : i_ready[fill])
        reference_pick = FILLS'(1) << fill;
    end
    assert (selected == reference_pick);
  end
endmodule
