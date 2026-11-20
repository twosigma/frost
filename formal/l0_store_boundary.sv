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

// Observe the SQ write stage through the production wrapper and LQ port bindings.
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
  wire [ 7:0] effective_store_strb;
  `include "tomasulo_wrapper.sv"
  // The state cut frees address and permission independently. Their D
  // inputs are compared unconditionally and establish this relation on
  // every rising edge, including reset and flush.
  assign o_port_strb = (sq_cache_store_writethrough == riscv_pkg::pma_writethrough_ok(
      o_port_addr
  )) ? effective_store_strb : 8'b0;
endmodule

`include "store_queue.sv"

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
  `include "load_queue.sv"
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
