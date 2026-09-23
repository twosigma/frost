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

module if_direction_payload_equiv (
    input logic i_clk,
    i_flush,
    i_stall,
    i_stall_registered,
    i_saved_valid,
    input logic i_sel_nop,
    i_pending,
    i_predecessor,
    i_saved_dir,
    i_live_dir
);
  logic nop_saved;
  logic initialized = 1'b0;
  logic replay, effective_nop, original_live, candidate_live;
  logic original_sc, candidate_sc;
  logic original_out, candidate_out;
  always @(posedge i_clk) begin
    initialized <= 1'b1;
    if (i_flush) nop_saved <= 1'b1;
    else if (i_stall && !i_stall_registered) nop_saved <= i_sel_nop;
    if (!initialized) assume (i_flush);
    if (initialized && !effective_nop) assert (original_out == candidate_out);
  end
  assign replay = i_stall_registered && !i_flush && i_saved_valid && !nop_saved;
  assign effective_nop = replay ? nop_saved : i_sel_nop;
  assign original_live = (i_pending && !effective_nop && i_predecessor) ? i_saved_dir : i_live_dir;
  assign candidate_live = (i_pending && i_predecessor) ? i_saved_dir : i_live_dir;
  stall_capture_reg #(
      .WIDTH(1)
  ) original_capture (
      .i_clk,
      .i_reset(1'b0),
      .i_flush,
      .i_stall,
      .i_stall_registered,
      .i_data (original_live),
      .o_data (original_sc)
  );
  stall_capture_reg #(
      .WIDTH(1)
  ) candidate_capture (
      .i_clk,
      .i_reset(1'b0),
      .i_flush,
      .i_stall,
      .i_stall_registered,
      .i_data (candidate_live),
      .o_data (candidate_sc)
  );
  assign original_out  = replay ? original_sc : original_live;
  assign candidate_out = replay ? candidate_sc : candidate_live;
endmodule
