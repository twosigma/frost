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

module coherent_rs_capacity #(
    parameter int unsigned DEPTH = 16
) (
    input logic [$clog2(DEPTH+1)-1:0] i_count,
    input logic [1:0] i_issue,
    input logic [1:0] i_dispatch,
    input logic i_flush,
    input logic [$clog2(DEPTH+1)-1:0] i_flush_count,
    output logic [$clog2(DEPTH+1)-1:0] o_count_next,
    output logic o_full,
    output logic o_full_for_2
);
  localparam int unsigned CountWidth = $clog2(DEPTH + 1);
  logic [1:0] choice[4];
  logic [CountWidth-1:0] count_choice[4];
  for (genvar issue_case = 0; issue_case < 4; issue_case++) begin : gen_issue_case
    localparam int Issues = (issue_case & 1) + ((issue_case >> 1) & 1);
    logic [CountWidth-1:0] count_zero, count_one, count_two;
    assign count_zero = i_count - CountWidth'(Issues);
    assign count_one  = i_count + CountWidth'(1 - Issues);
    assign count_two  = i_count + CountWidth'(2 - Issues);
    (* keep = "true" *) logic [1:0] result;
    (* keep = "true" *) logic [CountWidth-1:0] next_count;
    always_comb begin
      case (i_dispatch)
        2'b11: result = {count_two >= CountWidth'(DEPTH - 1), count_two == CountWidth'(DEPTH)};
        2'b10, 2'b01:
        result = {count_one >= CountWidth'(DEPTH - 1), count_one == CountWidth'(DEPTH)};
        default: result = {count_zero >= CountWidth'(DEPTH - 1), count_zero == CountWidth'(DEPTH)};
      endcase
    end
    always_comb begin
      case (i_dispatch)
        2'b11: next_count = count_two;
        2'b10, 2'b01: next_count = count_one;
        default: next_count = count_zero;
      endcase
    end
    assign count_choice[issue_case] = next_count;
    assign choice[issue_case] = result;
  end
  always_comb begin
    {o_full_for_2, o_full} = choice[i_issue];
    o_count_next = count_choice[i_issue];
    if (i_flush) begin
      o_count_next = i_flush_count;
      o_full = i_flush_count == CountWidth'(DEPTH);
      o_full_for_2 = i_flush_count >= CountWidth'(DEPTH - 1);
    end
  end
`ifdef FORMAL
  logic [CountWidth-1:0] reference_count;
  always_comb begin
    reference_count = i_count - CountWidth'(i_issue[0]) - CountWidth'(i_issue[1]);
    case (i_dispatch)
      2'b11: reference_count = reference_count + CountWidth'(2);
      2'b10, 2'b01: reference_count = reference_count + CountWidth'(1);
      default: ;
    endcase
    if (i_flush) reference_count = i_flush_count;
    p_capacity_count_exact : assert (o_count_next == reference_count);
    p_capacity_full_exact : assert (o_full == (reference_count == CountWidth'(DEPTH)));
    p_capacity_two_exact : assert (o_full_for_2 == (reference_count >= CountWidth'(DEPTH - 1)));
  end
`endif
endmodule
