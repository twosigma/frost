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

// Simulation-only testbench wrapper around CPU module
// Mimics 1-cycle read latency from block RAM instruction memory
module cpu_tb
  import riscv_pkg::*;
#(
    parameter int unsigned XLEN = 32,
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 16
) (
    input logic i_clk,
    input logic i_rst,

    // Instruction memory interface
    output logic [31:0] o_pc,  // Program counter for instruction fetch
    input logic [31:0] instruction_from_testbench,

    // Data memory interface
    output logic [31:0] o_data_mem_addr,
    output logic [31:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    output logic o_data_mem_read_enable,

    // Control signals
    output logic o_rst_done,  // Reset sequence complete

    // Validation signals for testbench
    output logic o_vld,    // Pipeline output valid (instruction completed)
    output logic o_pc_vld, // Program counter valid

    // Branch prediction control (for verification)
    input logic i_disable_branch_prediction
);

  // Internal signals (names match CPU port names for wildcard connection)
  logic [31:0] i_instr;  // Registered instruction fed to CPU (raw 32-bit for C extension)
  logic [31:0] i_data_mem_rd_data;  // Data memory read data to CPU
  logic pipeline_stall_from_cpu;  // Stall signal monitoring (registered, 1-cycle delay)
  logic pipeline_stall_comb;  // Stall signal (combinational, immediate)
  logic reset_to_cpu;  // Reset signal monitoring
  logic o_mmio_read_pulse;  // Unused in testbench; required for CPU .* connection
  logic [31:0] o_mmio_load_addr;  // Unused in testbench; required for CPU .* connection
  logic o_mmio_load_valid;  // Unused in testbench; required for CPU .* connection

  // Interrupt and timer signals for CPU (controllable from testbench)
  // Use reg type to allow testbench to drive values via force/deposit
  interrupt_t i_interrupts_reg;
  logic [63:0] i_mtime_reg;
  interrupt_t i_interrupts;
  logic [63:0] i_mtime;

  // Default values: no interrupts, timer at 0
  // Testbench can override via i_interrupts_reg and i_mtime_reg signals
  initial begin
    i_interrupts_reg = 3'b000;
    i_mtime_reg = 64'd0;
  end

  // Connect to CPU - use reg signals so testbench can modify them
  assign i_interrupts = i_interrupts_reg;
  assign i_mtime = i_mtime_reg;

  // Pipeline stage to mimic block RAM instruction memory latency
  always_ff @(posedge i_clk) begin
    // Stall signal from CPU observed on next rising edge
    pipeline_stall_from_cpu <= device_under_test.pipeline_ctrl.stall;
    // Mimic one cycle read latency of block RAM instruction memory port
    i_instr <= instruction_from_testbench;
  end

  // Memory addressing parameters
  localparam int unsigned MemByteAddrWidth = $clog2(MEM_SIZE_BYTES);
  localparam int unsigned MemWordAddrWidth = MemByteAddrWidth - 2;

  // Data memory (dual-port RAM, only port B used for data access)
  tdp_bram_dc_byte_en #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(MemWordAddrWidth),
      .USE_INIT_FILE(1'b0)  // Don't load from file in testbench
  ) data_memory_for_simulation (
      // Both ports use same clock (single clock domain operation)
      .i_port_a_clk(i_clk),
      .i_port_b_clk(i_clk),
      // Port A unused in testbench
      .i_port_a_byte_address('0),
      .i_port_a_write_data('0),
      .i_port_a_byte_write_enable('0),
      .o_port_a_read_data(  /*not connected*/),
      // Port B: CPU data memory access
      .i_port_b_byte_address(o_data_mem_addr),
      .i_port_b_write_data(o_data_mem_wr_data),
      .i_port_b_byte_write_enable(o_data_mem_per_byte_wr_en),
      .o_port_b_read_data(i_data_mem_rd_data)
  );

  // Connect reset from DUT for monitoring
  assign reset_to_cpu = device_under_test.pipeline_ctrl.reset;

  // Combinational stall signal (no delay) for test framework to check immediately
  // This is needed for AMO instructions which stall mid-pipeline
  assign pipeline_stall_comb = device_under_test.pipeline_ctrl.stall;

  // Device Under Test - instantiate OOO CPU with implicit port connections
  cpu_ooo device_under_test (.*);

endmodule : cpu_tb
