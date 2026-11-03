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

// Independent pin inputs cover completion, response and allocation choices.
module lq_result_pins (
    input logic [3:0] i_choices,
    input logic i_hit,
    input logic i_response,
    input logic i_completed,
    input logic i_first_room,
    input logic i_second_room,
    input logic i_alloc,
    input logic i_alloc_2,
    input logic [1:0] i_eligible,
    input logic i_accept
);
  logic completed, response_completed, valid;
  lq_result_valid_select select_dut (
      .i_choices,
      .i_hit,
      .i_response,
      .o_completed(completed)
  );
  lq_result_valid_allocate allocate_dut (
      .i_completed,
      .i_first_room,
      .i_second_room,
      .i_alloc,
      .i_alloc_2,
      .o_valid(valid)
  );
  lq_result_valid_response response_dut (
      .i_local(i_completed),
      .i_eligible,
      .i_response,
      .i_accept,
      .o_completed(response_completed)
  );
  always_comb begin
    assert (completed == (i_response ? (i_hit ? i_choices[3] : i_choices[2]) :
        (i_hit ? i_choices[1] : i_choices[0])));
    assert (response_completed == (i_completed ||
        (i_accept && (i_response ? i_eligible[1] : i_eligible[0]))));
    assert (valid == (i_completed &&
        !(i_first_room && (i_alloc || i_alloc_2)) &&
        !(i_second_room && i_alloc && i_alloc_2)));
  end
endmodule
