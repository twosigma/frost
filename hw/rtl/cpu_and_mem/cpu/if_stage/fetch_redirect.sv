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

// The same registered low-provider retarget pulse formerly computed in IF.
// Complete the priority classification for neither prediction, slot 1, and
// slot 2 in parallel. Late prediction permission then selects only among three
// scalar values. Reset remains outside the kept values; there is no new cycle.
// Arm zero is reset and is supplied separately. Every remaining condition and
// sequence flag is generic, including simultaneous requests and no winner.
module fetch_redirect (
    input logic i_clk,
    input logic i_reset,
    input logic i_pc_update_en,
    input logic [riscv_pkg::PcNextArms-1:1] i_npc_cond,
    input logic [riscv_pkg::PcNextArms-1:1] i_npc_seq,
    input logic i_live_prediction_emits_with_output,
    output logic o_fetch_redirect
);
  localparam int unsigned Arms = riscv_pkg::PcNextArms;
  localparam int unsigned Slot2Arm = 7;
  localparam int unsigned Slot1Arm = 8;
  logic [Arms-1:1] cond_neither, cond_slot1, cond_slot2;
  logic [Arms-1:1] sel_neither, sel_slot1, sel_slot2;
  (* keep = "true" *)logic redirect_neither;
  (* keep = "true" *)logic redirect_slot1;
  (* keep = "true" *)logic redirect_slot2;
  logic redirect_d;

  always_comb begin
    cond_neither = i_npc_cond;
    cond_neither[Slot2Arm] = 1'b0;
    cond_neither[Slot1Arm] = 1'b0;
    cond_slot1 = cond_neither;
    cond_slot1[Slot1Arm] = 1'b1;
    cond_slot2 = cond_neither;
    cond_slot2[Slot2Arm] = 1'b1;
    for (int unsigned k = 1; k < Arms; k++) begin
      sel_neither[k] = cond_neither[k] && !(|(cond_neither & ((1 << (k - 1)) - 1)));
      sel_slot1[k]   = cond_slot1[k] && !(|(cond_slot1 & ((1 << (k - 1)) - 1)));
      sel_slot2[k]   = cond_slot2[k] && !(|(cond_slot2 & ((1 << (k - 1)) - 1)));
    end
    redirect_neither = i_pc_update_en && |(sel_neither & ~i_npc_seq);
    redirect_slot1 = i_pc_update_en && |(sel_slot1 & ~i_npc_seq) &&
        !(sel_slot1[Slot1Arm] && !i_live_prediction_emits_with_output);
    redirect_slot2 = i_pc_update_en && |(sel_slot2 & ~i_npc_seq);
  end

  assign redirect_d = !i_reset && (i_npc_cond[Slot2Arm] ? redirect_slot2 :
      (i_npc_cond[Slot1Arm] ? redirect_slot1 : redirect_neither));
  always_ff @(posedge i_clk) begin
    o_fetch_redirect <= redirect_d;
  end

`ifdef FORMAL
  // Independent original selector and IF output equation. No assumptions on
  // inputs, sequence classifications, initial output state, or relationships
  // among simultaneous requests are needed. The reset arm is explicit above.
  logic [Arms-1:0] original_cond;
  logic [Arms-1:0] original_sel;
  logic original_d;
  logic f_past_valid = 1'b0;
  always_comb begin
    original_cond = {i_npc_cond, i_reset};
    for (int unsigned k = 0; k < Arms; k++) begin
      original_sel[k] = original_cond[k] && !(|(original_cond & ((1 << k) - 1)));
    end
    original_d = !i_reset && i_pc_update_en && |(original_sel & ~{i_npc_seq, 1'b0}) &&
        !(original_sel[Slot1Arm] && !i_live_prediction_emits_with_output);
    p_redirect_original_next_equation : assert (redirect_d == original_d);
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (f_past_valid) begin
      p_redirect_original_registered_waveform : assert (o_fetch_redirect == $past(original_d));
      cover (!i_reset && i_npc_cond[Slot2Arm] && i_npc_cond[Slot1Arm] &&
             original_sel[Slot2Arm] && redirect_d);
      cover (!i_reset && original_sel[Slot1Arm] &&
             !i_live_prediction_emits_with_output && !redirect_d);
      cover (!i_reset && i_npc_cond[Slot2Arm] && original_sel[1] && redirect_d);
    end
  end
`endif
endmodule
