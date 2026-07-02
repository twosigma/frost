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
    output logic [3:0] o_data_mem_bram_byte_wr_en,
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
  // 64-bit fetch window {next_word, current_word} (the CPU fetches a word pair).
  logic [63:0] i_instr;
  // Per-32-bit-word predecode sideband (ImemSidebandWidth bits each half).
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband;
  logic i_instr_bank_sel_r;  // Fetch-word parity (pc_reg[2]) for the window
  logic i_instr_valid;  // Fetch window valid (tie 1: fixed 1-cycle provider)
  logic [31:0] i_served_addr;  // Served fetch-window tag (address fetched last cycle)
  logic [31:0] i_data_mem_rd_data;  // Data memory read data to CPU
  logic pipeline_stall_from_cpu;  // Stall signal monitoring (registered, 1-cycle delay)
  logic pipeline_stall_comb;  // Stall signal (combinational, immediate)
  logic reset_to_cpu;  // Reset signal monitoring

  // Registered 1-cycle fetch state (mimics block-RAM instruction memory latency)
  logic [31:0] tb_cur_word;  // current fetch word presented to the CPU
  logic tb_bank_sel_q;  // parity (PC[2]) of the fetched address
  logic [31:0] tb_served_addr_q;  // address whose window is presented (o_pc, 1 cycle back)
  localparam logic [31:0] TbNop = 32'h0000_0013;  // addi x0,x0,0

  // Ports below are unused by this instruction-feed testbench but must exist as
  // local signals so the wildcard (.*) connection to cpu_ooo resolves.
  logic o_mmio_read_pulse;
  logic [31:0] o_mmio_load_addr;
  logic o_mmio_load_valid;
  logic o_mmio_fifo0_read_pulse;
  logic o_mmio_fifo1_read_pulse;
  logic o_mmio_uart_rx_ready_pulse;
  logic o_pipeline_stall;
  logic o_fetch_replay_consume;
  // FENCE.I cache-sync handshake (no I-cache here; completed immediately below)
  logic o_fence_i_sync_req;
  logic i_fence_i_sync_done;
  logic o_fence_i_flush;
  // Cached (high-address) tier request outputs + response inputs (tied idle:
  // the directed programs touch only the low BRAM range, never CACHED_BASE).
  logic [3:0] o_data_mem_cached_byte_wr_en;
  logic [31:0] o_data_mem_cached_wr_data;
  logic o_data_mem_cached_read_enable;
  logic [31:0] i_cached_read_data;
  logic i_cached_read_valid;
  logic i_cached_write_done;
  logic i_cached_write_inflight;
  // Debug taps (read from cocotb via device_under_test.*; also exposed here).
  logic [5:0] o_debug_irq_status;
  logic [31:0] o_debug_commit_pc;
  logic [31:0] o_debug_commit_2_pc;
  logic [1:0] o_debug_commit_valid;

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
    // Mimic one cycle read latency of block RAM instruction memory port: the
    // word for the address requested on o_pc this cycle is presented next cycle.
    tb_cur_word <= instruction_from_testbench;
    tb_bank_sel_q <= o_pc[2];  // parity of the fetched address
    tb_served_addr_q <= o_pc;  // served-window tag: the address fetched last cycle
  end

  // 64-bit fetch window {next_word, current_word}. The testbench feeds only
  // 32-bit, 4-byte-aligned instructions (no compressed, no halfword spanning),
  // so the "next word" half is never consumed (spanning only fires at pc[1]);
  // drive a NOP there.
  assign i_instr = {TbNop, tb_cur_word};
  // Per-word predecode sideband, computed by the same pure function the RTL
  // fetch path uses (riscv_pkg::imem_make_sideband; no lookahead).
  assign i_instr_sideband = {
    riscv_pkg::imem_make_sideband(TbNop), riscv_pkg::imem_make_sideband(tb_cur_word)
  };
  // bank_sel_r == pc_reg[2] => aligned: current word taken from i_instr[31:0].
  assign i_instr_bank_sel_r = tb_bank_sel_q;
  // Served-window tag: this fixed 1-cycle provider always presents the window
  // for last cycle's o_pc, so the tag is exactly that registered address (the
  // if_stage served-window guard sees a window that always covers pc_reg).
  assign i_served_addr = tb_served_addr_q;
  // Fixed 1-cycle provider: the fetch window is always valid.
  assign i_instr_valid = 1'b1;

  // FENCE.I cache-sync handshake completes immediately (no I-cache here; the
  // directed programs never issue FENCE.I, so o_fence_i_sync_req stays low).
  assign i_fence_i_sync_done = o_fence_i_sync_req;

  // Cached (high-address) tier response inputs tied inactive (tier unused).
  assign i_cached_read_data = '0;
  assign i_cached_read_valid = 1'b0;
  assign i_cached_write_done = 1'b0;
  assign i_cached_write_inflight = 1'b0;

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
      // Port B: CPU data memory access. Use the BRAM-specific byte-write-enable
      // so the testbench mirrors the production MMIO-pre-mask behavior.
      .i_port_b_byte_address(o_data_mem_addr),
      .i_port_b_write_data(o_data_mem_wr_data),
      .i_port_b_byte_write_enable(o_data_mem_bram_byte_wr_en),
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
