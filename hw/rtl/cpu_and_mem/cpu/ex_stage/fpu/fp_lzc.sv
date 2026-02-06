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

/*
  Parameterized leading zero counter.

  Pure combinational module. Counts leading zeros in i_value,
  starting from bit [WIDTH-1] down to bit [0].
*/
module fp_lzc #(
    parameter int unsigned WIDTH = 48
) (
    input  logic [          WIDTH-1:0] i_value,
    output logic [$clog2(WIDTH+1)-1:0] o_lzc,
    output logic                       o_is_zero
);

  logic lzc_found;

  always_comb begin
    o_lzc = '0;
    o_is_zero = (i_value == '0);
    lzc_found = 1'b0;
    if (!o_is_zero) begin
      for (int i = WIDTH - 1; i >= 0; i--) begin
        if (!lzc_found) begin
          if (i_value[i]) begin
            lzc_found = 1'b1;
          end else begin
            o_lzc = o_lzc + 1;
          end
        end
      end
    end
  end

endmodule : fp_lzc
