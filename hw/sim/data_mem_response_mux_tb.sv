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

// Bench for data_mem_response_mux. Two data_mem_request_router instances run
// side by side. The reference gets the plain selection (MMIO data while MMIO
// is valid, otherwise BRAM data) and the cached data on separate inputs; the
// candidate gets the mux's merged payload on both. Every other input is
// shared, and the test compares every router output on every cycle. The
// standalone 32- and 64-bit instances take their cached select from
// i_helper_cached_read_ready.
module data_mem_response_mux_tb #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush_all,
    input logic i_sq_mem_write_en,
    input logic [XLEN-1:0] i_sq_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_sq_mem_write_data,
    input logic [riscv_pkg::MemStrbBits-1:0] i_sq_mem_write_byte_en,
    input logic i_sq_mem_write_is_mmio,
    input logic i_sq_mem_write_is_cached,
    input logic i_amo_mem_write_en,
    input logic [XLEN-1:0] i_amo_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_amo_mem_write_data,
    input logic i_amo_mem_write_is_dword,
    input logic i_lq_mem_read_en,
    input logic [XLEN-1:0] i_lq_mem_read_addr,
    input logic i_lq_mem_addr_valid,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_lq_mem_read_id,
    input logic i_sq_committed_empty,
    input logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    input logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id,
    input logic i_cached_read_valid,
    output logic o_cached_read_ready,
    output logic o_ref_cached_read_ready,
    output logic o_cached_read_held,
    output logic o_ref_cached_read_held,
    input logic i_cached_write_done,
    input logic i_cached_write_inflight,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_ref_data_mem_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [riscv_pkg::MemDataBits-1:0] o_ref_data_mem_wr_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_ref_data_mem_per_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_ref_data_mem_bram_byte_wr_en,
    output logic o_data_mem_bram_write_any,
    output logic o_ref_data_mem_bram_write_any,
    output logic o_data_mem_read_enable,
    output logic o_ref_data_mem_read_enable,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_ref_data_mem_cached_byte_wr_en,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic [riscv_pkg::MemDataBits-1:0] o_ref_data_mem_cached_wr_data,
    output logic o_data_mem_cached_read_enable,
    output logic o_ref_data_mem_cached_read_enable,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_ref_data_mem_cached_read_id,
    output logic o_mmio_read_pulse,
    output logic o_ref_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic [XLEN-1:0] o_ref_mmio_load_addr,
    output logic o_mmio_load_valid,
    output logic o_ref_mmio_load_valid,
    output logic o_mmio_fifo0_read_pulse,
    output logic o_ref_mmio_fifo0_read_pulse,
    output logic o_mmio_fifo1_read_pulse,
    output logic o_ref_mmio_fifo1_read_pulse,
    output logic o_mmio_uart_rx_ready_pulse,
    output logic o_ref_mmio_uart_rx_ready_pulse,
    output logic o_sq_mem_write_done,
    output logic o_ref_sq_mem_write_done,
    output logic o_amo_mem_write_done,
    output logic o_ref_amo_mem_write_done,
    output logic o_lq_mem_request_valid,
    output logic o_ref_lq_mem_request_valid,
    output logic o_device_request_pending,
    output logic o_ref_device_request_pending,
    output logic [riscv_pkg::MemDataBits-1:0] o_lq_mem_read_data,
    output logic [riscv_pkg::MemDataBits-1:0] o_ref_lq_mem_read_data,
    output logic o_lq_mem_read_valid,
    output logic o_ref_lq_mem_read_valid,
    output logic o_lq_mem_read_is_cached,
    output logic o_ref_lq_mem_read_is_cached,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_lq_mem_read_id,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_ref_lq_mem_read_id,
    input logic [riscv_pkg::MemDataBits-1:0] i_mmio_read_data,
    input logic i_mmio_read_valid,
    input logic i_helper_cached_read_ready,
    output logic [31:0] o_standalone32,
    output logic [63:0] o_standalone64,
    output logic [riscv_pkg::MemDataBits-1:0] o_selected_read_data
);

  logic [riscv_pkg::MemDataBits-1:0] reference_fast_data;
  always_comb begin
    reference_fast_data = i_data_mem_rd_data;
    if (i_mmio_read_valid) reference_fast_data = i_mmio_read_data;
  end

  data_mem_response_mux #(
      .DATA_WIDTH(riscv_pkg::MemDataBits)
  ) u_mux (
      .i_bram_read_data(i_data_mem_rd_data),
      .i_mmio_read_data(i_mmio_read_data),
      .i_cached_read_data(i_cached_read_data),
      .i_mmio_read_valid(i_mmio_read_valid),
      .i_cached_read_ready(o_cached_read_ready),
      .o_read_data(o_selected_read_data)
  );

  data_mem_response_mux #(
      .DATA_WIDTH(32)
  ) u_standalone32 (
      .i_bram_read_data(i_data_mem_rd_data[31:0]),
      .i_mmio_read_data(i_mmio_read_data[31:0]),
      .i_cached_read_data(i_cached_read_data[31:0]),
      .i_mmio_read_valid(i_mmio_read_valid),
      .i_cached_read_ready(i_helper_cached_read_ready),
      .o_read_data(o_standalone32)
  );

  data_mem_response_mux #(
      .DATA_WIDTH(64)
  ) u_standalone64 (
      .i_bram_read_data(i_data_mem_rd_data),
      .i_mmio_read_data(i_mmio_read_data),
      .i_cached_read_data(i_cached_read_data),
      .i_mmio_read_valid(i_mmio_read_valid),
      .i_cached_read_ready(i_helper_cached_read_ready),
      .o_read_data(o_standalone64)
  );

  // AMO write tier flag. In the core the load queue registers it beside the
  // AMO write address from the same source, so on every cycle it equals the
  // decode of that address; the bench derives it from the driven address
  // with the router's default cached window instead of asking the test to
  // keep a second input consistent.
  logic amo_mem_write_is_cached;
  assign amo_mem_write_is_cached = (i_amo_mem_write_addr >= XLEN'(32'h8000_0000)) &&
      (i_amo_mem_write_addr < (XLEN'(32'h8000_0000) + XLEN'(32'h4000_0000)));

  data_mem_request_router #(
      .XLEN(XLEN)
  ) u_reference (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_flush_all(i_flush_all),
      .i_sq_mem_write_en(i_sq_mem_write_en),
      .i_sq_mem_write_addr(i_sq_mem_write_addr),
      .i_sq_mem_write_data(i_sq_mem_write_data),
      .i_sq_mem_write_byte_en(i_sq_mem_write_byte_en),
      .i_sq_mem_write_is_mmio(i_sq_mem_write_is_mmio),
      .i_sq_mem_write_is_cached(i_sq_mem_write_is_cached),
      .i_amo_mem_write_en(i_amo_mem_write_en),
      .i_amo_mem_write_addr(i_amo_mem_write_addr),
      .i_amo_mem_write_data(i_amo_mem_write_data),
      .i_amo_mem_write_is_dword(i_amo_mem_write_is_dword),
      .i_amo_mem_write_is_cached(amo_mem_write_is_cached),
      .i_lq_mem_read_en(i_lq_mem_read_en),
      .i_lq_mem_read_addr(i_lq_mem_read_addr),
      .i_lq_mem_addr_valid(i_lq_mem_addr_valid),
      .i_lq_mem_read_id(i_lq_mem_read_id),
      .i_sq_committed_empty(i_sq_committed_empty),
      .i_data_mem_rd_data(reference_fast_data),
      .i_cached_read_data(i_cached_read_data),
      .i_cached_read_id(i_cached_read_id),
      .i_cached_read_valid(i_cached_read_valid),
      .o_cached_read_ready(o_ref_cached_read_ready),
      .o_cached_read_held(o_ref_cached_read_held),
      .i_cached_write_done(i_cached_write_done),
      .i_cached_write_inflight(i_cached_write_inflight),
      .o_data_mem_addr(o_ref_data_mem_addr),
      .o_data_mem_wr_data(o_ref_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(o_ref_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(o_ref_data_mem_bram_byte_wr_en),
      .o_data_mem_bram_write_any(o_ref_data_mem_bram_write_any),
      .o_data_mem_read_enable(o_ref_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(o_ref_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(o_ref_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(o_ref_data_mem_cached_read_enable),
      .o_data_mem_cached_read_id(o_ref_data_mem_cached_read_id),
      .o_mmio_read_pulse(o_ref_mmio_read_pulse),
      .o_mmio_load_addr(o_ref_mmio_load_addr),
      .o_mmio_load_valid(o_ref_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(o_ref_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(o_ref_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(o_ref_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(o_ref_sq_mem_write_done),
      .o_amo_mem_write_done(o_ref_amo_mem_write_done),
      .o_lq_mem_request_valid(o_ref_lq_mem_request_valid),
      .o_device_request_pending(o_ref_device_request_pending),
      .o_lq_mem_read_data(o_ref_lq_mem_read_data),
      .o_lq_mem_read_valid(o_ref_lq_mem_read_valid),
      .o_lq_mem_read_is_cached(o_ref_lq_mem_read_is_cached),
      .o_lq_mem_read_id(o_ref_lq_mem_read_id)
  );

  data_mem_request_router #(
      .XLEN(XLEN)
  ) u_candidate (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_flush_all(i_flush_all),
      .i_sq_mem_write_en(i_sq_mem_write_en),
      .i_sq_mem_write_addr(i_sq_mem_write_addr),
      .i_sq_mem_write_data(i_sq_mem_write_data),
      .i_sq_mem_write_byte_en(i_sq_mem_write_byte_en),
      .i_sq_mem_write_is_mmio(i_sq_mem_write_is_mmio),
      .i_sq_mem_write_is_cached(i_sq_mem_write_is_cached),
      .i_amo_mem_write_en(i_amo_mem_write_en),
      .i_amo_mem_write_addr(i_amo_mem_write_addr),
      .i_amo_mem_write_data(i_amo_mem_write_data),
      .i_amo_mem_write_is_dword(i_amo_mem_write_is_dword),
      .i_amo_mem_write_is_cached(amo_mem_write_is_cached),
      .i_lq_mem_read_en(i_lq_mem_read_en),
      .i_lq_mem_read_addr(i_lq_mem_read_addr),
      .i_lq_mem_addr_valid(i_lq_mem_addr_valid),
      .i_lq_mem_read_id(i_lq_mem_read_id),
      .i_sq_committed_empty(i_sq_committed_empty),
      .i_data_mem_rd_data(o_selected_read_data),
      .i_cached_read_data(o_selected_read_data),
      .i_cached_read_id(i_cached_read_id),
      .i_cached_read_valid(i_cached_read_valid),
      .o_cached_read_ready(o_cached_read_ready),
      .o_cached_read_held(o_cached_read_held),
      .i_cached_write_done(i_cached_write_done),
      .i_cached_write_inflight(i_cached_write_inflight),
      .o_data_mem_addr(o_data_mem_addr),
      .o_data_mem_wr_data(o_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(o_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(o_data_mem_bram_byte_wr_en),
      .o_data_mem_bram_write_any(o_data_mem_bram_write_any),
      .o_data_mem_read_enable(o_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(o_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(o_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(o_data_mem_cached_read_enable),
      .o_data_mem_cached_read_id(o_data_mem_cached_read_id),
      .o_mmio_read_pulse(o_mmio_read_pulse),
      .o_mmio_load_addr(o_mmio_load_addr),
      .o_mmio_load_valid(o_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(o_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(o_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(o_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(o_sq_mem_write_done),
      .o_amo_mem_write_done(o_amo_mem_write_done),
      .o_lq_mem_request_valid(o_lq_mem_request_valid),
      .o_device_request_pending(o_device_request_pending),
      .o_lq_mem_read_data(o_lq_mem_read_data),
      .o_lq_mem_read_valid(o_lq_mem_read_valid),
      .o_lq_mem_read_is_cached(o_lq_mem_read_is_cached),
      .o_lq_mem_read_id(o_lq_mem_read_id)
  );

endmodule : data_mem_response_mux_tb
