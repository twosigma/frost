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

module predictor_table_twin (
    input logic i_clk,
    input predictor_table_twin_pkg::inputs_t i
);
  predictor_table_twin_pkg::outputs_t ref_out, new_out;
  predictor_table_twin_pkg::state_t ref_state, new_state;
  table_reference reference (
      .i_clk,
      .i,
      .o(ref_out),
      .state(ref_state)
  );
  table_candidate candidate (
      .i_clk,
      .i,
      .o(new_out),
      .state(new_state)
  );

  logic started = 1'b0;
  always @(posedge i_clk) begin
    started <= 1'b1;
    // Relate the two arbitrary initial register files once. The read rows and
    // every fetch and training input stay free on every cycle.
    if (!started) assume (ref_state == new_state);
    p_register_relation : assert (ref_state == new_state);
    p_bank0 : assert (ref_out.bank0 == new_out.bank0);
    p_bank1 : assert (ref_out.bank1 == new_out.bank1);
    p_history : assert (ref_out.lookup_hist == new_out.lookup_hist);
`ifdef PREDICTOR_TWIN_DIRECTION
    p_word : assert (ref_out.lookup_word == new_out.lookup_word);
    p_next_word : assert (ref_out.lookup_word_next == new_out.lookup_word_next);
`else
    p_hit : assert (ref_out.hit == new_out.hit);
    p_target : assert (ref_out.target == new_out.target);
`endif
    p_read_addresses : assert (ref_out.read_index == new_out.read_index);
    p_write_addresses : assert (ref_out.write_index == new_out.write_index);
    p_write_enables : assert (ref_out.write_enable == new_out.write_enable);
    p_write_data : assert (ref_out.write_data == new_out.write_data);
    c_provider : cover ((|ref_state.provider) && ref_state.train_valid && (|ref_out.write_enable));
    c_allocation : cover (!(|ref_state.provider) && (|ref_out.write_enable));
  end
endmodule

(* blackbox *) module table_reference (
    input logic i_clk,
    input predictor_table_twin_pkg::inputs_t i,
    output predictor_table_twin_pkg::outputs_t o,
    output predictor_table_twin_pkg::state_t state
);
endmodule

(* blackbox *) module table_candidate (
    input logic i_clk,
    input predictor_table_twin_pkg::inputs_t i,
    output predictor_table_twin_pkg::outputs_t o,
    output predictor_table_twin_pkg::state_t state
);
endmodule
