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

// Fill and store choices include word and line invalidations.
module coherent_l0_flags #(
    parameter int unsigned DEPTH = 256,
    parameter int unsigned TAG_WIDTH = 22,
    localparam int unsigned IndexWidth = $clog2(DEPTH)
) (
    input logic i_clk,
    input logic [DEPTH-1:0] i_valid,
    input logic i_fill,
    input logic [IndexWidth-1:0] i_fill_index,
    input logic [TAG_WIDTH-1:0] i_fill_tag,
    input logic i_store_update,
    input logic i_inv,
    input logic [IndexWidth-1:0] i_inv_index,
    input logic [TAG_WIDTH-1:0] i_inv_tag,
    input logic i_inv_tag_match,
    input logic i_inv2,
    input logic [IndexWidth-1:0] i_inv2_index,
    input logic [TAG_WIDTH-1:0] i_inv2_tag,
    input logic i_inv2_tag_match,
    input logic i_line,
    input logic [IndexWidth-3:0] i_line_index,
    output logic [DEPTH-1:0] o_next
);
  logic [DEPTH-1:0] choices[4];
  for (genvar stored = 0; stored < 2; stored++) begin : gen_store_choice
    for (genvar filled = 0; filled < 2; filled++) begin : gen_fill_choice
      localparam bit Store = stored != 0;
      localparam bit Fill = filled != 0;
      (* keep = "true" *) logic [DEPTH-1:0] choice;
      wire write_valid = Store || Fill;
      wire [IndexWidth-1:0] write_index = Store ? i_inv_index : i_fill_index;
      wire [TAG_WIDTH-1:0] write_tag = Store ? i_inv_tag : i_fill_tag;
      wire inv_fill = i_inv && !Store && write_valid &&
          write_index == i_inv_index && write_tag == i_inv_tag;
      wire inv_old = i_inv && !Store && i_valid[i_inv_index] && i_inv_tag_match &&
          !(write_valid && write_index == i_inv_index && write_tag != i_inv_tag);
      wire inv2_fill = i_inv2 && write_valid && write_index == i_inv2_index &&
          write_tag == i_inv2_tag;
      wire inv2_old = i_inv2 && i_valid[i_inv2_index] && i_inv2_tag_match &&
          !(write_valid && write_index == i_inv2_index && write_tag != i_inv2_tag);
      always_comb begin
        choice = i_valid;
        if (write_valid) choice[write_index] = 1'b1;
        if (inv_fill || inv_old) choice[i_inv_index] = 1'b0;
        if (inv2_fill || inv2_old) choice[i_inv2_index] = 1'b0;
        if (i_line)
          for (int k = 0; k < 4; k++) choice[{i_line_index, 2'(k)}] = 1'b0;
      end
      assign choices[2*stored+filled] = choice;
    end
  end
  assign o_next = choices[{i_store_update, i_fill}];
`ifndef SYNTHESIS
  logic [DEPTH-1:0] reference;
  wire write_valid = i_store_update || i_fill;
  wire [IndexWidth-1:0] write_index = i_store_update ? i_inv_index : i_fill_index;
  wire [TAG_WIDTH-1:0] write_tag = i_store_update ? i_inv_tag : i_fill_tag;
  wire inv_fill = i_inv && !i_store_update && write_valid &&
      write_index == i_inv_index && write_tag == i_inv_tag;
  wire inv_old = i_inv && !i_store_update && i_valid[i_inv_index] && i_inv_tag_match &&
      !(write_valid && write_index == i_inv_index && write_tag != i_inv_tag);
  wire inv2_fill = i_inv2 && write_valid && write_index == i_inv2_index &&
      write_tag == i_inv2_tag;
  wire inv2_old = i_inv2 && i_valid[i_inv2_index] && i_inv2_tag_match &&
      !(write_valid && write_index == i_inv2_index && write_tag != i_inv2_tag);
  always_comb begin
    reference = i_valid;
    if (write_valid) reference[write_index] = 1'b1;
    if (inv_fill || inv_old) reference[i_inv_index] = 1'b0;
    if (inv2_fill || inv2_old) reference[i_inv2_index] = 1'b0;
    if (i_line)
      for (int k = 0; k < 4; k++) reference[{i_line_index, 2'(k)}] = 1'b0;
  end
`ifdef FORMAL
  always_comb
`else
  always @(posedge i_clk)
`endif
  begin
    p_valid_exact : assert (o_next == reference);
  end
`endif
endmodule
