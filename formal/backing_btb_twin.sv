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

module backing_btb_twin (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i
);
  backing_btb_twin_pkg::predictions_t ref_out, new_out;
  backing_btb_twin_pkg::ram_pins_t ref_ram, new_ram;
  backing_btb_twin_pkg::state_t ref_state, new_state;
  logic ref_aligned, ref_shifted, new_aligned, new_shifted;
  backing_reference reference (
      .i_clk,
      .i,
      .o(ref_out),
      .ram(ref_ram),
      .state(ref_state),
      .held_aligned_answer(ref_aligned),
      .held_shifted_answer(ref_shifted)
  );
  backing_candidate candidate (
      .i_clk,
      .i,
      .o(new_out),
      .ram(new_ram),
      .state(new_state),
      .held_aligned_answer(new_aligned),
      .held_shifted_answer(new_shifted)
  );
  logic started = 1'b0;
  always @(posedge i_clk) begin
    started <= 1'b1;
    if (!started) assume (ref_state == new_state);
    p_registers : assert (ref_state == new_state);
    p_hit : assert (ref_out.hit == new_out.hit);
    p_size : assert (ref_out.compressed == new_out.compressed);
    p_return : assert (ref_out.is_return == new_out.is_return);
    p_target : assert (ref_out.target == new_out.target);
    p_return_by_size : assert (ref_out.slot2_return_by_size == new_out.slot2_return_by_size);
    p_target_by_size : assert (ref_out.slot2_target_by_size == new_out.slot2_target_by_size);
    p_ram_enables : assert (ref_ram.write_enable == new_ram.write_enable);
    p_ram_clear : assert (ref_ram.bulk_clear == new_ram.bulk_clear);
    p_ram_read_address : assert (ref_ram.read_index == new_ram.read_index);
    p_ram_write_address : assert (ref_ram.write_index == new_ram.write_index);
    p_ram_write_data : assert (ref_ram.write_data == new_ram.write_data);
    p_held_select : assert ({ref_aligned, ref_shifted} == {new_aligned, new_shifted});
    if (started) begin
      c_held_hit : cover (ref_aligned && (|ref_out.hit));
      c_shifted_hit : cover (ref_shifted && (|ref_out.hit));
      c_discard_read : cover ($past(ref_state.held_valid && i.redirect) && !ref_state.held_valid);
    end
  end
endmodule

(* blackbox *) module backing_reference (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    output backing_btb_twin_pkg::predictions_t o,
    output backing_btb_twin_pkg::ram_pins_t ram,
    output backing_btb_twin_pkg::state_t state,
    output logic held_aligned_answer,
    held_shifted_answer
);
endmodule

(* blackbox *) module backing_candidate (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    output backing_btb_twin_pkg::predictions_t o,
    output backing_btb_twin_pkg::ram_pins_t ram,
    output backing_btb_twin_pkg::state_t state,
    output logic held_aligned_answer,
    held_shifted_answer
);
endmodule
