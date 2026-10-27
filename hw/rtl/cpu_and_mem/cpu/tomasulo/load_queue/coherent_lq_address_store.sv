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

// Address storage includes PMA and cache classification for each slot.
module coherent_lq_address_store #(
    parameter int unsigned ADDR_WIDTH = 3,
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned DEPTH = 1 << ADDR_WIDTH
) (
    input logic i_clk,
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [XLEN-1:0] i_write_data,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [XLEN-1:0] o_read_data,
    output logic [3:0] o_read_class,
    output logic [3:0] o_write_class
);
  function automatic logic [3:0] classify(input logic [XLEN-1:0] addr);
    classify = {riscv_pkg::pma_writethrough_ok(addr),
                riscv_pkg::pma_atomic_ok(addr), riscv_pkg::pma_data_ok(addr),
                (addr >= XLEN'(CACHED_BASE)) &&
                (addr < (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)))};
  endfunction
  (* ram_style = "distributed" *) logic [XLEN+3:0] payload[DEPTH];
  initial for (int i = 0; i < DEPTH; i++) payload[i] = {classify('0), {XLEN{1'b0}}};
  assign o_write_class = classify(i_write_data);
  always_ff @(posedge i_clk)
    if (i_write_enable) payload[i_write_address] <= {o_write_class, i_write_data};
  assign {o_read_class, o_read_data} = payload[i_read_address];
`ifndef SYNTHESIS
  logic [XLEN-1:0] reference[DEPTH];
  initial for (int i = 0; i < DEPTH; i++) reference[i] = '0;
  always_ff @(posedge i_clk)
    if (i_write_enable) reference[i_write_address] <= i_write_data;
`ifdef FORMAL
  always_comb begin
`else
  always @(posedge i_clk) begin
`endif
    assert (o_read_data == reference[i_read_address]);
    assert (o_read_class == classify(o_read_data));
    for (int i = 0; i < DEPTH; i++) begin
      assert (payload[i][XLEN-1:0] == reference[i]);
      assert (payload[i][XLEN+3:XLEN] == classify(payload[i][XLEN-1:0]));
    end
  end
`endif
endmodule
