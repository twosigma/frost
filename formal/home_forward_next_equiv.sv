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

// The forward turn's next state from coherence_home_forward_next equals the
// form it replaces, for any register state and inputs: the fills that may
// forward are the registered ones, those installing from a completed read,
// and, when this cycle's memory response is valid and good, its candidate
// fill; acceptance takes the turn after the accepted fill. The reference
// turn is the first ready fill in later, else the first ready fill.
module home_forward_next_equiv #(
    parameter int unsigned FILLS = 8
) (
    input logic run,
    input logic [FILLS-1:0] forward_q,
    input logic [FILLS-1:0] install_done,
    input logic [FILLS-1:0] install_candidate,
    input logic response_valid,
    input logic response_error,
    input logic [FILLS-1:0] later,
    input logic [FILLS-1:0] pick,
    input logic accept
);
  function automatic logic [FILLS-1:0] turn(input logic [FILLS-1:0] ready,
                                            input logic [FILLS-1:0] later_mask);
    turn = '0;
    for (int fill = FILLS - 1; fill >= 0; fill--)
    if (|(ready & later_mask) ? ready[fill] && later_mask[fill] : ready[fill])
      turn = FILLS'(1) << fill;
  endfunction
  function automatic logic [FILLS-1:0] after(input logic [FILLS-1:0] picked);
    for (int fill = 0; fill < FILLS; fill++)
    after[fill] = picked[FILLS-1] || (picked & ((FILLS'(1) << fill) - FILLS'(1))) != 0;
  endfunction

  // The replaced form: one ready set, with the response folded in.
  logic [FILLS-1:0] install_set, ready_next, reference_next;
  assign install_set = install_done |
      ((response_valid && !response_error) ? install_candidate : '0);
  assign ready_next = forward_q | (run ? install_set : '0);
  assign reference_next = accept ? turn(ready_next & ~pick, after(pick)) : turn(ready_next, later);

  logic [FILLS-1:0] next;
  coherence_home_forward_next #(
      .FILLS(FILLS)
  ) dut (
      .i_ready_early(forward_q | (run ? install_done : '0)),
      .i_ready_response(run ? install_candidate : '0),
      .i_response_good(run && response_valid && !response_error),
      .i_later(later),
      .i_pick(pick),
      .i_after_pick(after(pick)),
      .i_accept(accept),
      .o_pick_next(next)
  );

  always_comb begin
    // The home's pick is one-hot or zero.
    if ($onehot0(pick)) p_next_equal : assert (next == reference_next);
  end
endmodule
