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

module backing_btb_twin_side (
    input logic i_clk,
    input backing_btb_twin_pkg::inputs_t i,
    output backing_btb_twin_pkg::predictions_t o,
    output backing_btb_twin_pkg::ram_pins_t ram,
    output backing_btb_twin_pkg::state_t state,
    output logic held_aligned_answer,
    held_shifted_answer
);
  backing_btb dut (
      .i_clk,
      .i_reset(i.reset),
      .i_redirect(i.redirect),
      .i_lookup_index(i.lookup_index),
      .i_packet_pc(i.packet_pc),
      .i_packet_compressed(i.packet_compressed),
      .o_hit(o.hit),
      .o_compressed(o.compressed),
      .o_return(o.is_return),
      .o_target(o.target),
      .o_slot2_return_by_size(o.slot2_return_by_size),
      .o_slot2_target_by_size(o.slot2_target_by_size),
      .i_update(i.update),
      .i_update_pc(i.update_pc),
      .i_update_target(i.update_target),
      .i_update_compressed(i.update_compressed),
      .i_update_return(i.update_return),
      .i_refresh(i.refresh),
      .i_refresh_pc(i.refresh_pc)
  );

  assign held_aligned_answer = dut.held_select;
  assign held_shifted_answer = dut.shift_answer && dut.shift_select;
  assign dut.u_update_ram.twin_read = i.read_rows.update_row;
  assign ram.write_data.update_row = dut.u_update_ram.i_write_data;
  assign ram.write_enable[0] = dut.u_update_ram.i_write_enable;
  assign ram.read_index[0] = dut.u_update_ram.i_read_address;
  assign ram.write_index[0] = dut.u_update_ram.i_write_address;
  assign ram.bulk_clear[0] = dut.u_update_ram.i_bulk_clear;
  for (genvar n = 0; n < 2; n++) begin : gen_image
    assign dut.gen_image[n].u_tag_ram.twin_read = i.read_rows.tags[n];
    assign dut.gen_image[n].u_payload_ram.twin_read = i.read_rows.payloads[n];
    assign ram.write_data.tags[n] = dut.gen_image[n].u_tag_ram.i_write_data;
    assign ram.write_data.payloads[n] = dut.gen_image[n].u_payload_ram.i_write_data;
    assign ram.write_enable[1+n] = dut.gen_image[n].u_tag_ram.i_write_enable;
    assign ram.write_enable[3+n] = dut.gen_image[n].u_payload_ram.i_write_enable;
    assign ram.read_index[1+n] = dut.gen_image[n].u_tag_ram.i_read_address;
    assign ram.read_index[3+n] = dut.gen_image[n].u_payload_ram.i_read_address;
    assign ram.write_index[1+n] = dut.gen_image[n].u_tag_ram.i_write_address;
    assign ram.write_index[3+n] = dut.gen_image[n].u_payload_ram.i_write_address;
    assign ram.bulk_clear[1+n] = dut.gen_image[n].u_payload_ram.i_bulk_clear;
  end

  assign state.a = {
    dut.a_valid,
    dut.a_refresh,
    dut.a_index,
    dut.a_upper,
    dut.a_halfword,
    dut.a_target,
    dut.a_region_ok,
    dut.a_compressed,
    dut.a_return
  };
  assign state.b = {
    dut.b_valid,
    dut.b_refresh,
    dut.b_index,
    dut.b_upper,
    dut.b_halfword,
    dut.b_target,
    dut.b_region_ok,
    dut.b_compressed,
    dut.b_return
  };
  assign state.c = {
    dut.c_valid,
    dut.c_refresh,
    dut.c_index,
    dut.c_upper,
    dut.c_halfword,
    dut.c_target,
    dut.c_region_ok,
    dut.c_compressed,
    dut.c_return
  };
  assign state.sweep_active = dut.sweep_active;
  assign state.sweep_index = dut.sweep_index;
  for (genvar n = 0; n < 2; n++) begin : gen_state_image_wr
    assign state.image_write_en[n]  = dut.gen_image[n].u_tag_ram.i_write_enable;
    assign state.image_write_idx[n] = dut.gen_image[n].u_tag_ram.i_write_address;
  end
  assign state.c_set = dut.c_set;
  assign state.c_hit = dut.c_hit;
  assign state.c_way = dut.c_way;
  assign state.forward_set = dut.forward_set_q;
  assign state.b_forward = dut.b_forward_q;
  assign state.request_valid = dut.request_valid_q;
  assign state.request_index = dut.request_index_q;
  assign state.tags = dut.tags_q;
  assign state.held_valid = dut.held_valid_q;

  // Only the held registers' enable changed. Their data is observable while valid.
  assign state.held_index = dut.held_valid_q ? dut.held_index_q : '0;
  assign state.held_tags = dut.held_valid_q ? dut.held_tags_q : '0;
  assign state.held_payloads = dut.held_valid_q ? dut.held_payload_q : '0;
endmodule
