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

module backing_btb_precompare_twin (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    input backing_btb_twin_pkg::pc_t i_lookup_pc,
    input backing_btb_twin_pkg::pc_t i_win_pc
);
  backing_btb_twin_pkg::predictions_t ref_out, new_out;
  backing_btb_twin_pkg::ram_pins_t ref_ram, new_ram;
  backing_btb_twin_pkg::state_t ref_state, new_state;
  logic ref_aligned, ref_shifted, new_aligned, new_shifted;
  logic [3:0] ref_win_hit, new_win_hit;
  logic [3:0] ref_win_compressed, new_win_compressed;
  logic [3:0] ref_win_return, new_win_return;
  backing_btb_twin_pkg::target_t [3:0] ref_win_target, new_win_target;

  backing_precompare_reference reference (
      .i_clk,
      .i,
      .i_lookup_pc,
      .i_win_pc,
      .o(ref_out),
      .ram(ref_ram),
      .state(ref_state),
      .held_aligned_answer(ref_aligned),
      .held_shifted_answer(ref_shifted),
      .o_win_hit(ref_win_hit),
      .o_win_compressed(ref_win_compressed),
      .o_win_return(ref_win_return),
      .o_win_target(ref_win_target)
  );
  backing_precompare_candidate candidate (
      .i_clk,
      .i,
      .i_lookup_pc,
      .i_win_pc,
      .o(new_out),
      .ram(new_ram),
      .state(new_state),
      .held_aligned_answer(new_aligned),
      .held_shifted_answer(new_shifted),
      .o_win_hit(new_win_hit),
      .o_win_compressed(new_win_compressed),
      .o_win_return(new_win_return),
      .o_win_target(new_win_target)
  );

  logic started = 1'b0;
  backing_btb_twin_pkg::pc_t prev_lookup_pc_q;
  logic prev_redirect_q;
  always @(posedge i_clk) begin
    started <= 1'b1;
    prev_lookup_pc_q <= i_lookup_pc;
    prev_redirect_q <= i.redirect;

    if (!started) assume (ref_state == new_state);
    assume (i.lookup_index == i_lookup_pc[backing_btb_twin_pkg::IndexBits+1:2]);
    if (started) assume (i_win_pc == prev_lookup_pc_q);

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
      p_win_hit : assert (ref_win_hit == new_win_hit);
      p_win_size : assert (ref_win_compressed == new_win_compressed);
      p_win_return : assert (ref_win_return == new_win_return);
      p_win_target : assert (ref_win_target == new_win_target);
      c_win_hit_img0 : cover (|ref_win_hit[1:0]);
      c_win_hit_img1 : cover (|ref_win_hit[3:2]);
      c_win_last_set :
      cover ((&prev_lookup_pc_q[backing_btb_twin_pkg::IndexBits+1:2]) &&
             (|ref_win_hit[1:0]) && !(|ref_win_hit[3:2]));
      c_win_redirect_clear : cover (prev_redirect_q && (ref_win_hit == '0) && (new_win_hit == '0));
    end
  end
endmodule

(* blackbox *) module backing_precompare_reference (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    input backing_btb_twin_pkg::pc_t i_lookup_pc,
    input backing_btb_twin_pkg::pc_t i_win_pc,
    output backing_btb_twin_pkg::predictions_t o,
    output backing_btb_twin_pkg::ram_pins_t ram,
    output backing_btb_twin_pkg::state_t state,
    output logic held_aligned_answer,
    output logic held_shifted_answer,
    output logic [3:0] o_win_hit,
    output logic [3:0] o_win_compressed,
    output logic [3:0] o_win_return,
    output backing_btb_twin_pkg::target_t [3:0] o_win_target
);
endmodule

(* blackbox *) module backing_precompare_candidate (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    input backing_btb_twin_pkg::pc_t i_lookup_pc,
    input backing_btb_twin_pkg::pc_t i_win_pc,
    output backing_btb_twin_pkg::predictions_t o,
    output backing_btb_twin_pkg::ram_pins_t ram,
    output backing_btb_twin_pkg::state_t state,
    output logic held_aligned_answer,
    output logic held_shifted_answer,
    output logic [3:0] o_win_hit,
    output logic [3:0] o_win_compressed,
    output logic [3:0] o_win_return,
    output backing_btb_twin_pkg::target_t [3:0] o_win_target
);
endmodule
