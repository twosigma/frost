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

// All valid bits, index bits and same-cycle permission inputs are arbitrary.
module lq_l0_lookup_equiv #(
    parameter int unsigned DEPTH = 256,
    localparam int unsigned IndexWidth = $clog2(DEPTH)
) (
    input logic [DEPTH-1:0] i_valid,
    input logic [IndexWidth-1:0] i_index,
    input logic i_mmio,
    input logic i_invalidated,
    input logic i_line_invalidated
);
  logic permitted;
  lq_l0_lookup_permission #(
      .DEPTH(DEPTH)
  ) dut (
      .i_valid,
      .i_index,
      .i_mmio,
      .i_invalidated,
      .i_line_invalidated,
      .o_permitted(permitted)
  );
  always_comb begin
    assert (permitted == (i_valid[i_index] && !i_mmio && !i_invalidated && !i_line_invalidated));
  end
endmodule
