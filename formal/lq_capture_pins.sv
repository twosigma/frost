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

// Independent inputs cover every capture, in-flight and release selector pin.
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
    input logic i_flushed
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
  logic source, released;
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
  end
endmodule
