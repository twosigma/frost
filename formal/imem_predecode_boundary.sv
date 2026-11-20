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

// Expose the live read port and the registered parity. The single proof clock
// checks each register's next value from arbitrary paired state.
module imem_predecode_boundary (
    input logic i_clk,
    input logic i_port_a_rst,
    input logic i_port_a_enable,
    input logic [31:0] i_port_a_byte_address,
    input logic [31:0] i_port_a_write_data,
    input logic i_port_a_write_enable,
    input logic i_port_b_rst,
    input logic i_port_b_enable,
    input logic [31:0] i_port_b_byte_address,
    input logic [31:0] i_port_b_next_byte_address,
    output logic [63:0] o_port_b_read_data,
    output logic o_port_b_bank_sel_r,
    output logic [63:0] o_fetch_data_from_parity
);
  // Four addresses per parity exercise noncontiguous pairs and address bits.
  logic [63:0] words_by_parity;
`ifdef IMEM_PREDECODE_CANDIDATE
  imem_predecode #(
      .ENABLE_FETCH_METADATA(1'b0),
`else
  imem_predecode_reference #(
`endif
      .ADDR_WIDTH(3),
      .USE_INIT_FILE(1'b0)
  ) u_imem (
      .i_port_a_clk(i_clk),
      .i_port_a_rst,
      .i_port_a_enable,
      .i_port_a_byte_address,
      .i_port_a_write_data,
      .i_port_a_write_enable,
      .o_port_a_read_data(),
      .i_port_b_clk(i_clk),
      .i_port_b_rst,
      .i_port_b_enable,
      .i_port_b_byte_address,
      .i_port_b_next_byte_address,
      .o_port_b_read_data,
      .o_port_b_read_data_by_parity(words_by_parity),
`ifdef IMEM_PREDECODE_CANDIDATE
      .o_port_b_sideband(),
      .o_port_b_pc_metadata(),
      .o_port_b_pc_metadata_by_parity(),
      .o_port_b_pc_pairability_by_parity(),
      .o_port_b_slot2_start_valid_lo_by_parity(),
      .o_port_b_window_overlay_hit(),
      .o_port_b_response_ready(),
`endif
      .o_port_b_bank_sel_r
  );

`ifdef IMEM_PREDECODE_CANDIDATE
  // Check an independent parity mux alongside the direct comparison of the
  // actual fetch output. Both forms use the production RAM wrapper.
  for (genvar bit_index = 0; bit_index < 64; bit_index++) begin : gen_fetch_bit
    MUXF7 u_read_mux (
        .I0(words_by_parity[bit_index]),
        .I1(words_by_parity[(bit_index+32)%64]),
        .S (o_port_b_bank_sel_r),
        .O (o_fetch_data_from_parity[bit_index])
    );
  end
`else
  assign o_fetch_data_from_parity = o_port_b_read_data;
`endif
endmodule
