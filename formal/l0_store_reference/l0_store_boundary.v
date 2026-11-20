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

// The original write port and load-cache strobe from 7f9ab5f96. The
// witness register records the permission of the sampled beat address.
module l0_store_boundary #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b1
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic [63:0] mem_write_addr_next,
    input logic [63:0] mem_write_data_next,
    input logic [7:0] mem_write_byte_en_next,
    input riscv_pkg::mem_size_e mem_write_size_next,
    input logic mem_write_is_mmio_next,
    input logic mem_write_is_cached_next,
    input logic drain_zero_cached,
    input logic drain_is_cmo,
    input logic [7:0] sq_is_sc,
    input logic [2:0] drain_idx_q,
    input logic mem_write_completes_next,
    input logic cmo_inval_pulse_q,
    input logic launch_without_store_ready,
    input logic precise_launch_qualified,
    input logic cached_launch_qualified,
    input logic precommit_shared_ready,
    input logic i_coherent_store_ready,
    input logic complete_without_store_ready,
    input logic precise_complete_qualified,
    output logic o_sq_mem_write_en,
    output logic [63:0] o_sq_mem_write_addr,
    output logic [63:0] o_sq_mem_write_data,
    output logic [7:0] o_sq_mem_write_byte_en,
    output logic o_sq_mem_write_buffered,
    output logic [1:0] o_sq_mem_write_size,
    output logic o_sq_mem_write_is_mmio,
    output logic o_sq_mem_write_is_cached,
    output logic sq_cache_store_writethrough,
    output logic [2:0] held_entry,
    output logic held_completes,
    output logic fire,
    output logic complete,
    output logic o_port_valid,
    output logic [63:0] o_port_addr,
    output logic o_port_block,
    output logic [63:0] o_port_data,
    output logic [7:0] o_port_strb
);
  wire sq_cache_invalidate_valid, sq_cache_invalidate_block;
  wire [63:0] sq_cache_invalidate_addr;
  wire [ 7:0] address_decoded_store_strb;
  load_queue #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .MEM_RESPONSE_ERRORS(1'b1)
  ) u_address_decoded_lq (
      .i_cache_invalidate_valid(sq_cache_invalidate_valid),
      .i_cache_invalidate_addr(sq_cache_invalidate_addr),
      .i_cache_invalidate_block(sq_cache_invalidate_block),
      .i_cache_store_data(o_sq_mem_write_data),
      .i_cache_store_strb(o_sq_mem_write_byte_en),
      .o_port_valid,
      .o_port_addr,
      .o_port_block,
      .o_port_data,
      .o_port_strb(address_decoded_store_strb)
  );
  store_queue u_sq (
      .o_mem_write_en            (o_sq_mem_write_en),
      .o_mem_write_addr          (o_sq_mem_write_addr),
      .o_mem_write_data          (o_sq_mem_write_data),
      .o_mem_write_byte_en       (o_sq_mem_write_byte_en),
      .o_mem_write_buffered      (o_sq_mem_write_buffered),
      .o_mem_write_size          (o_sq_mem_write_size),
      .o_mem_write_is_mmio       (o_sq_mem_write_is_mmio),
      .o_mem_write_is_cached     (o_sq_mem_write_is_cached),
      .o_cache_invalidate_valid  (sq_cache_invalidate_valid),
      .o_cache_invalidate_addr   (sq_cache_invalidate_addr),
      .o_cache_invalidate_block  (sq_cache_invalidate_block),
      .o_cache_store_writethrough(sq_cache_store_writethrough),
      .*
  );
  assign o_port_strb = (sq_cache_store_writethrough == riscv_pkg::pma_writethrough_ok(
      o_port_addr
  )) ? address_decoded_store_strb : 8'b0;
endmodule
module store_queue #(
    parameter bit CACHE_NORMAL_MEMORY = 1,
    parameter bit PRECISE_UNCACHED = 1
) (
    input  logic                                              i_clk,
    input  logic                                              i_rst_n,
    input  logic                                              i_flush_all,
    input  logic                 [                      63:0] mem_write_addr_next,
    input  logic                 [                      63:0] mem_write_data_next,
    input  logic                 [                       7:0] mem_write_byte_en_next,
    input  riscv_pkg::mem_size_e                              mem_write_size_next,
    input  logic                                              mem_write_is_mmio_next,
    input  logic                                              mem_write_is_cached_next,
    input  logic                                              drain_zero_cached,
    input  logic                                              drain_is_cmo,
    input  logic                 [                       7:0] sq_is_sc,
    input  logic                 [                       2:0] drain_idx_q,
    input  logic                                              mem_write_completes_next,
    input  logic                                              cmo_inval_pulse_q,
    input  logic                                              launch_without_store_ready,
    input  logic                                              precise_launch_qualified,
    input  logic                                              cached_launch_qualified,
    input  logic                                              precommit_shared_ready,
    input  logic                                              i_coherent_store_ready,
    input  logic                                              complete_without_store_ready,
    input  logic                                              precise_complete_qualified,
    output logic                 [                       2:0] held_entry,
    output logic                                              held_completes,
    output logic                                              fire,
    output logic                                              o_mem_write_en,
    output logic                 [       riscv_pkg::XLEN-1:0] o_mem_write_addr,
    output logic                 [riscv_pkg::MemDataBits-1:0] o_mem_write_data,
    output logic                 [riscv_pkg::MemStrbBits-1:0] o_mem_write_byte_en,
    output riscv_pkg::mem_size_e                              o_mem_write_size,
    output logic                                              o_mem_write_buffered,
    output logic                                              o_mem_write_is_mmio,
    output logic                                              o_mem_write_is_cached,
    output logic                                              o_cache_invalidate_valid,
    output logic                 [       riscv_pkg::XLEN-1:0] o_cache_invalidate_addr,
    output logic                                              o_cache_invalidate_block,
    output logic                                              o_cache_store_writethrough,
    output logic                                              complete
);
  localparam int unsigned IdxWidth = 3;
  wire mem_write_fire_next, drain_complete_fire_next;
  assign mem_write_fire_next = launch_without_store_ready ||
      (precommit_shared_ready && precise_launch_qualified) ||
      (cached_launch_qualified && i_coherent_store_ready);
  assign drain_complete_fire_next = complete_without_store_ready ||
      (precommit_shared_ready && precise_complete_qualified) ||
      (cached_launch_qualified && i_coherent_store_ready);
  wire                 address_writethrough = riscv_pkg::pma_writethrough_ok(mem_write_addr_next);
  logic [IdxWidth-1:0] mem_write_entry_idx_stg;
  logic                mem_write_completes_stg;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      o_mem_write_en <= 1'b0;
    end else begin
      o_mem_write_en <= mem_write_fire_next;
    end
    o_mem_write_addr <= mem_write_addr_next;
    o_cache_store_writethrough <= address_writethrough;
    o_mem_write_data <= mem_write_data_next;
    o_mem_write_byte_en <= mem_write_byte_en_next;
    o_mem_write_size <= mem_write_size_next;
    o_mem_write_is_mmio <= mem_write_is_mmio_next;
    o_mem_write_buffered <= PRECISE_UNCACHED && CACHE_NORMAL_MEMORY &&
        !sq_is_sc[drain_idx_q] && !mem_write_is_mmio_next &&
        address_writethrough;
    o_mem_write_is_cached <= mem_write_is_cached_next;
    o_cache_invalidate_block <= drain_zero_cached || drain_is_cmo;
    if (mem_write_fire_next) begin
      mem_write_entry_idx_stg <= drain_idx_q;
      mem_write_completes_stg <= mem_write_completes_next;
    end
  end
  assign o_cache_invalidate_valid = o_mem_write_en || cmo_inval_pulse_q;
  assign o_cache_invalidate_addr = o_mem_write_addr;

  assign held_entry = mem_write_entry_idx_stg;
  assign held_completes = mem_write_completes_stg;
  assign fire = mem_write_fire_next;
  assign complete = drain_complete_fire_next;
endmodule
module load_queue #(
    parameter bit CACHE_NORMAL_MEMORY = 0,
    parameter bit STORE_STRB_PMA_CHECKED = 0,
    parameter bit MEM_RESPONSE_ERRORS = 0
) (
    input logic i_cache_invalidate_valid,
    input logic [63:0] i_cache_invalidate_addr,
    input logic i_cache_invalidate_block,
    input logic [63:0] i_cache_store_data,
    input logic [7:0] i_cache_store_strb,
    output logic o_port_valid,
    output logic [63:0] o_port_addr,
    output logic o_port_block,
    output logic [63:0] o_port_data,
    output logic [7:0] o_port_strb
);
  l0_store_observation observe (
      .i_invalidate_valid(i_cache_invalidate_valid),
      .i_invalidate_addr(i_cache_invalidate_addr),
      .i_invalidate_block(i_cache_invalidate_block),
      .i_store_data(i_cache_store_data),
      .i_store_strb((CACHE_NORMAL_MEMORY && riscv_pkg::pma_writethrough_ok(
          i_cache_invalidate_addr
      )) ? i_cache_store_strb : 8'b0),
      .o_port_valid,
      .o_port_addr,
      .o_port_block,
      .o_port_data,
      .o_port_strb
  );
endmodule
module l0_store_observation (
    input logic i_invalidate_valid,
    input logic [63:0] i_invalidate_addr,
    input logic i_invalidate_block,
    input logic [63:0] i_store_data,
    input logic [7:0] i_store_strb,
    output logic o_port_valid,
    output logic [63:0] o_port_addr,
    output logic o_port_block,
    output logic [63:0] o_port_data,
    output logic [7:0] o_port_strb
);
  assign o_port_valid = i_invalidate_valid;
  assign o_port_addr  = i_invalidate_addr;
  assign o_port_block = i_invalidate_block;
  assign o_port_data  = i_store_data;
  assign o_port_strb  = i_store_strb;
endmodule
