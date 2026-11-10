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

// Independent inputs cover capture, release, staged-copy choices.
module lq_capture_pins (
    input logic [1:0] i_code,
    input logic i_hit,
    input logic i_hold,
    input logic i_fault,
    input logic i_replace,
    input logic i_current,
    input logic i_issue,
    input logic i_take,
    input logic i_clear,
    input logic i_flushed,
    input logic [7:0] i_gather_select,
    input logic [7:0] i_gather_values
);
  logic selected, inflight;
  lq_capture_select capture (
      .i_code,
      .i_hit,
      .i_hold,
      .i_fault,
      .i_replace,
      .o_choice(selected)
  );
  lq_inflight_select mask (
      .i_current,
      .i_issue,
      .i_take,
      .i_clear,
      .i_flushed,
      .o_next(inflight)
  );
  logic source, released, staged_match;
  lq_bypass_source bypass (
      .i_flush_all(i_code[1]),
      .i_response(i_code[0]),
      .i_fault(i_fault),
      .i_forward(i_issue),
      .i_hit(i_hit),
      .o_source(source)
  );
  lq_entry_release release_entry (
      .i_ready(i_current),
      .i_issue_found(i_take),
      .i_issue_match(i_issue),
      .i_bypass_match(i_replace),
      .i_bypass_source(i_hit),
      .o_release(released)
  );
  lq_staged_match_select staged_match_dut (
      .i_held_stored(i_code[0]),
      .i_taken_stored(i_code[1]),
      .i_held_write(i_current),
      .i_taken_write(i_issue),
      .i_updated(i_fault),
      .i_take,
      .o_match(staged_match)
  );
  logic gathered, candidate_stored, candidate_write;
  lq_match_gather gather_dut (
      .i_select(i_gather_select),
      .i_values(i_gather_values),
      .o_match (gathered)
  );
  lq_staged_candidate_select candidate_dut (
      .i_head_data(i_code[0]),
      .i_stored_data(i_code[1]),
      .i_merged_data(i_hit),
      .i_head_stored(i_hold),
      .i_head_update(i_fault),
      .i_update_valid(i_replace),
      .i_head_write(i_current),
      .i_merged_write(i_issue),
      .o_stored_match(candidate_stored),
      .o_write_match(candidate_write)
  );
  logic reference_choice;
  always_comb begin
    case (i_code)
      2'b00:   reference_choice = 1'b0;
      2'b01:   reference_choice = !i_hold && i_hit;
      2'b10:   reference_choice = !i_hold;
      2'b11:   reference_choice = 1'b1;
      default: reference_choice = 1'b0;
    endcase
    assert (source == ((i_code[0] && !i_code[1]) || i_fault || i_issue || i_hit));
    assert (released == (i_current && (i_take ? i_issue : (i_replace && i_hit))));
    assert (selected == (reference_choice || i_fault || i_replace));
    assert (inflight == ((i_take && i_issue) || (!i_take && !i_clear && !i_flushed && i_current)));
    assert (staged_match == (i_take ? (i_issue ? i_fault : i_code[1]) :
        (i_current ? i_fault : i_code[0])));
    assert (gathered == ((|i_gather_select) ? (|(i_gather_select & i_gather_values)) :
        i_gather_values[0]));
    assert (candidate_stored == (i_hold ? i_code[0] :
        i_replace ? (i_fault ? i_code[0] : i_hit) : i_code[1]));
    assert (candidate_write == (i_replace && ((i_hold || i_fault) ? i_current : i_issue)));
  end
endmodule
