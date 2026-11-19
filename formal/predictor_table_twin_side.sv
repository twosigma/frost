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

module predictor_table_twin_side (
    input logic i_clk,
    input predictor_table_twin_pkg::inputs_t i,
    output predictor_table_twin_pkg::outputs_t o,
    output predictor_table_twin_pkg::state_t state
);

`ifdef PREDICTOR_TWIN_DIRECTION
  logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] fold;
  for (genvar t = 0; t < riscv_pkg::TageTables; t++) begin : gen_fold
    assign fold[t] = predictor_twin_fold_pkg::history_index(i.lookup_hist, t);
  end
`ifdef PREDICTOR_TWIN_REFERENCE
  tage_predictor dut (
`else
  tage_predictor #(.USE_EXTERNAL_FOLD_INDEX(1'b1)) dut (
      .i_lookup_fold_index(fold),
`endif
      .o_lookup_word(o.lookup_word), .o_lookup_word_next(o.lookup_word_next),
      .i_train_alt_taken(i.train_alt_taken), .i_train_taken(i.train_taken),
`else
  ittage_predictor dut (
      .o_hit(o.hit), .o_target(o.target), .i_train_target(i.train_target),
`endif
      .i_clk, .i_lookup_word(i.lookup_word), .i_lookup_hist(i.lookup_hist),
      .i_lookup_capture(i.lookup_capture), .i_train_valid(i.train_valid),
      .i_train_lookup(i.train_lookup), .i_train_bank(i.train_bank),
      .i_train_mispredicted(i.train_mispredicted), .o_lookup_hist(o.lookup_hist),
      .o_bank0(o.bank0), .o_bank1(o.bank1)
  );

  // Each physical read copy receives its own free row on every cycle. Observe
  // both sets of pins, even where the two copies share an enable or write data.
  for (genvar b = 0; b < 2; b++) begin : gen_bank
    for (genvar t = 0; t < predictor_table_twin_pkg::Tables; t++) begin : gen_table
      assign dut.gen_bank[b].gen_table[t].u_lookup_copy.twin_read = i.read_rows[t][b][0];
      assign o.write_enable[t][b][0] = dut.gen_bank[b].gen_table[t].u_lookup_copy.i_write_enable;
      assign o.read_index[t][b][0] = dut.gen_bank[b].gen_table[t].u_lookup_copy.i_read_address;
      assign o.write_index[t][b][0] = dut.gen_bank[b].gen_table[t].u_lookup_copy.i_write_address;
      assign o.write_data[t][b][0] = dut.gen_bank[b].gen_table[t].u_lookup_copy.i_write_data;
      assign dut.gen_bank[b].gen_table[t].u_train_copy.twin_read = i.read_rows[t][b][1];
      assign o.write_enable[t][b][1] = dut.gen_bank[b].gen_table[t].u_train_copy.i_write_enable;
      assign o.read_index[t][b][1] = dut.gen_bank[b].gen_table[t].u_train_copy.i_read_address;
      assign o.write_index[t][b][1] = dut.gen_bank[b].gen_table[t].u_train_copy.i_write_address;
      assign o.write_data[t][b][1] = dut.gen_bank[b].gen_table[t].u_train_copy.i_write_data;
    end
  end
  assign state.capture = dut.capture_q;
  assign state.fresh = dut.lookup_fresh_q;
  assign state.held = dut.lookup_held_q;
  assign state.current_rows = dut.cur;
  assign state.train_valid = dut.train_valid_q;
  assign state.write_bank = dut.write_bank;
  assign state.mispredicted = dut.train_mispredicted_q;
  assign state.train_lookup = dut.train_lookup_q;
  assign state.provider = dut.provider;
  assign state.above = dut.above;
  assign state.owned = dut.owned;
`ifdef PREDICTOR_TWIN_DIRECTION
  assign state.taken = dut.train_taken_q;
  assign state.useful_update = dut.useful_update;
  assign state.useful_value = dut.useful_value;
`else
  assign state.target = dut.train_target_q;
`ifdef PREDICTOR_TWIN_REFERENCE
  for (genvar t = 0; t < predictor_table_twin_pkg::Tables; t++) begin : gen_correct
    assign state.correct[t] = dut.gen_write[t].correct;
  end
`else
  assign state.correct = dut.correct_q;
`endif
`endif
endmodule
