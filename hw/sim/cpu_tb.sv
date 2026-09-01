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
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 16
) (
    input logic i_clk,
    input logic i_rst,

    // Instruction memory interface
    output logic [riscv_pkg::XLEN-1:0] o_pc,  // Program counter for instruction fetch
    input logic [31:0] instruction_from_testbench,

    // Data memory interface (aligned MemDataBits beats with 8-lane strobes;
    // hw/rtl/README.md "Data-tier bus contract")
    output logic [riscv_pkg::XLEN-1:0] o_data_mem_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
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
  logic [7:0] i_instr_pc_metadata;
  logic [15:0] i_instr_pc_metadata_by_provider_parity;
  logic [7:0] i_pc_pairability_by_provider_parity;
  logic [3:0] i_slot2_start_valid_lo_by_provider_parity;
  logic i_instr_pc_metadata_served_high;
  logic [1:0] i_instr_hi_rd_is_x2;  // {next,current} high-parcel predicates
  logic i_instr_bank_sel_r;  // Fetch-word parity (pc_reg[2]) for the window
  logic i_instr_valid;  // Fetch window valid (tie 1: fixed 1-cycle provider)
  logic [29:0] i_served_word_low;
  logic [29:0] i_served_last_word_low;
  logic [29:0] i_served_prev_word_low;
  logic i_served_prev_word_valid_low;
  logic [29:0] i_served_word_high;
  logic [29:0] i_served_last_word_high;
  logic [29:0] i_served_prev_word_high;
  logic i_served_prev_word_valid_high;
  logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data;  // Data memory read data to CPU
  logic pipeline_stall_from_cpu;  // Stall signal monitoring (registered, 1-cycle delay)
  logic pipeline_stall_comb;  // Stall signal (combinational, immediate)
  logic reset_to_cpu;  // Reset signal monitoring

  // Registered 1-cycle fetch state (mimics block-RAM instruction memory latency)
  logic [31:0] tb_cur_word;  // current fetch word presented to the CPU
  logic tb_bank_sel_q;  // parity (PC[2]) of the fetched address
  // Provider-local word tags for the window presented one cycle later.
  logic [29:0] tb_served_word_q;
  logic [29:0] tb_served_last_word_q;
  logic [29:0] tb_served_prev_word_q;
  logic tb_served_prev_word_valid_q;

  // Ports below are unused by this instruction-feed testbench but must exist as
  // local signals so the wildcard (.*) connection to cpu_ooo resolves.
  logic o_mmio_read_pulse;
  logic [riscv_pkg::XLEN-1:0] o_mmio_load_addr;
  logic o_mmio_load_valid;
  logic o_mmio_fifo0_read_pulse;
  logic o_mmio_fifo1_read_pulse;
  logic o_mmio_uart_rx_ready_pulse;
  logic o_pipeline_stall;
  logic o_fetch_replay_consume;
  logic o_fetch_live_claim;
  // FENCE.I cache-sync handshake (no I-cache here; completed immediately below)
  logic o_fence_i_sync_req;
  logic i_fence_i_sync_done;
  logic o_fence_i_flush;
  // Cached (high-address) tier request outputs + response inputs (tied idle:
  // the directed programs touch only the low BRAM range, never CACHED_BASE).
  logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en;
  logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data;
  logic o_data_mem_cached_read_enable;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id;
  logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id;
  logic i_cached_read_valid;
  logic o_cached_read_ready;
  logic i_cached_write_done;
  logic i_cached_write_inflight;
  cache_perf_pkg::cache_perf_events_t i_cache_perf_events;
  // Translated-fetch seam (Phase 3 M2/M5). This bench models the production
  // low-BRAM overlay fast path with a fixed 1-cycle response: the served window
  // is never the high tier, and it echoes the core's own fault verdict for the
  // ask back with the window it serves one cycle later (Bare mode, so the PA
  // is the VA's low bits; the directed programs never fetch out of map, so the
  // verdict is always clean).
  logic [31:0] o_fetch_pa0;
  logic [31:0] o_fetch_pa1;
  logic o_fetch_pa_valid;
  logic o_fetch_fault0;
  logic o_fetch_fault0_page;
  logic o_fetch_fault1;
  logic o_fetch_fault1_page;
  logic o_fetch_line_after_ok;
  logic o_fetch_redirect;
  logic i_instr_fault0;
  logic i_instr_fault0_page;
  logic i_instr_fault1;
  logic i_instr_fault1_page;
  logic i_served_high;
  logic tb_fault0_q, tb_fault0_page_q, tb_fault1_q, tb_fault1_page_q;
  // Page-table walker line port (Phase 3 M4): no page-table memory behind
  // this bench, so the port is absent exactly like cpu_and_mem's no-cached-
  // tier stub (a walk would stall; the directed programs stay in Bare mode).
  logic o_walk_line_req_valid;
  logic i_walk_line_req_ready;
  logic [31:0] o_walk_line_req_addr;
  logic [1:0] o_walk_line_req_id;
  logic i_walk_line_resp_valid;
  logic [1:0] i_walk_line_resp_id;
  logic [255:0] i_walk_line_resp_rdata;
  // Debug module seam (Phase 3 M3): no debugger in this bench; the request
  // inputs idle low and the status outputs are unobserved.
  logic i_dbg_haltreq;
  logic i_dbg_go;
  logic [31:0] i_dbg_go_addr;
  logic [63:0] i_dbg_data;
  logic o_dbg_data_we;
  logic [63:0] o_dbg_data_wdata;
  logic o_debug_mode;
  logic o_dbg_parked;
  logic o_dbg_cmd_err;
  logic o_dbg_go_taken;
  logic o_dbg_bram_store;
  logic [31:0] o_dbg_bram_store_addr;
  logic [7:0] o_dbg_bram_store_strb;
  assign i_dbg_haltreq = 1'b0;
  assign i_dbg_go = 1'b0;
  assign i_dbg_go_addr = '0;
  assign i_dbg_data = '0;
  // Debug taps (read from cocotb via device_under_test.*; also exposed here).
  logic [5:0] o_debug_irq_status;
  logic [riscv_pkg::XLEN-1:0] o_debug_commit_pc;
  logic [riscv_pkg::XLEN-1:0] o_debug_commit_2_pc;
  logic [1:0] o_debug_commit_valid;

  // Interrupt and timer signals for CPU (controllable from testbench)
  // Use reg type to allow testbench to drive values via force/deposit
  interrupt_t i_interrupts_reg;
  logic [63:0] i_mtime_reg;
  interrupt_t i_interrupts;
  logic [63:0] i_mtime;
  // PLIC S-context line (M6): quiet in the direct bench.
  logic i_plic_seip;
  assign i_plic_seip = 1'b0;

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
    tb_served_word_q <= o_pc[31:2];
    tb_served_last_word_q <= o_pc[31:2] + 1'b1;
    tb_served_prev_word_q <= o_pc[31:2] - 1'b1;
    tb_served_prev_word_valid_q <= |o_pc[31:2];
    // Fault verdict of the ask, registered with the window (see above).
    tb_fault0_q <= o_fetch_fault0;
    tb_fault0_page_q <= o_fetch_fault0_page;
    tb_fault1_q <= o_fetch_fault1;
    tb_fault1_page_q <= o_fetch_fault1_page;
  end

  // 64-bit fetch window {next_word, current_word}. The testbench feeds
  // exactly one instruction per cycle, so the "next word" half must never be
  // consumed. With 32b-led bundle formation, a plain NOP there would form a
  // 2-wide bundle behind any pairable 32-bit slot-1 and advance the PC by +8,
  // desynchronizing this bench's one-instruction-per-step model. Drive a
  // SYSTEM encoding instead: its slot-2-start-valid class is 0, so the aligner
  // class-kills slot-2 and the PC steps +4 as this bench expects.
  // The word itself can never execute — the bench serves every architectural
  // PC's instruction through tb_cur_word.
  localparam logic [31:0] TbSlot2Blocker = 32'h0000_0073;  // ecall (SYSTEM)
  assign i_instr = {TbSlot2Blocker, tb_cur_word};
  // Per-word predecode sideband, computed by the same pure function the RTL
  // fetch path uses (riscv_pkg::imem_make_sideband; no lookahead).
  assign i_instr_sideband = {
    riscv_pkg::imem_make_sideband(TbSlot2Blocker), riscv_pkg::imem_make_sideband(tb_cur_word)
  };
  assign i_instr_pc_metadata = {
    i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
    i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
    i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
    i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
    i_instr_sideband[riscv_pkg::ImemSbPairableNativeHi],
    i_instr_sideband[riscv_pkg::ImemSbPairableCompressedHi],
    i_instr_sideband[riscv_pkg::ImemSbIsCompressedHi],
    i_instr_sideband[riscv_pkg::ImemSbIsCompressedLo]
  };
  // This bench models the fixed low-BRAM provider; cached parity lanes are
  // tied off and the active lower half is restored to physical bank order.
  assign i_instr_pc_metadata_by_provider_parity = {
    8'b0, tb_bank_sel_q ? {i_instr_pc_metadata[3:0], i_instr_pc_metadata[7:4]} : i_instr_pc_metadata
  };
  assign i_pc_pairability_by_provider_parity = {
    4'b0,
    tb_bank_sel_q ?
        {
          i_instr_sideband[riscv_pkg::ImemSbPairableNativeLo],
          i_instr_sideband[riscv_pkg::ImemSbEvenLocalPairValid],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ]
        } : {
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ],
          i_instr_sideband[riscv_pkg::ImemSbPairableNativeLo],
          i_instr_sideband[riscv_pkg::ImemSbEvenLocalPairValid]
        }
  };
  assign i_slot2_start_valid_lo_by_provider_parity = {
    2'b0,
    tb_bank_sel_q ?
        {
          i_instr_sideband[riscv_pkg::ImemSbSlot2StartValidLo],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ]
        } : {
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ],
          i_instr_sideband[riscv_pkg::ImemSbSlot2StartValidLo]
        }
  };
  assign i_instr_hi_rd_is_x2 = {TbSlot2Blocker[27:23] == 5'd2, tb_cur_word[27:23] == 5'd2};
  // bank_sel_r == pc_reg[2] => aligned: current word taken from i_instr[31:0].
  assign i_instr_bank_sel_r = tb_bank_sel_q;
  // This fixed one-cycle provider is the low lane. All arithmetic tags are
  // registered with the payload; the unused high lane is internally coherent.
  assign i_served_word_low = tb_served_word_q;
  assign i_served_last_word_low = tb_served_last_word_q;
  assign i_served_prev_word_low = tb_served_prev_word_q;
  assign i_served_prev_word_valid_low = tb_served_prev_word_valid_q;
  assign i_served_word_high = 30'd0;
  assign i_served_last_word_high = 30'd1;
  assign i_served_prev_word_high = '1;
  assign i_served_prev_word_valid_high = 1'b0;
  assign i_instr_fault0 = tb_fault0_q;
  assign i_instr_fault0_page = tb_fault0_page_q;
  assign i_instr_fault1 = tb_fault1_q;
  assign i_instr_fault1_page = tb_fault1_page_q;
  assign i_served_high = 1'b0;
  assign i_instr_pc_metadata_served_high = 1'b0;
  // Fixed 1-cycle provider: the fetch window is always valid.
  assign i_instr_valid = 1'b1;

  // FENCE.I cache-sync handshake completes immediately (no I-cache here; the
  // directed programs never issue FENCE.I, so o_fence_i_sync_req stays low).
  assign i_fence_i_sync_done = o_fence_i_sync_req;

  // Cached (high-address) tier response inputs tied inactive (tier unused).
  assign i_cached_read_data = '0;
  assign i_cached_read_id = '0;
  assign i_cached_read_valid = 1'b0;
  assign i_cached_write_done = 1'b0;
  assign i_cached_write_inflight = 1'b0;
  assign i_cache_perf_events = '0;
  // Walker line port absent (see the declarations above).
  assign i_walk_line_req_ready = 1'b0;
  assign i_walk_line_resp_valid = 1'b0;
  assign i_walk_line_resp_id = '0;
  assign i_walk_line_resp_rdata = '0;

  // Memory addressing parameters
  localparam int unsigned MemByteAddrWidth = $clog2(MEM_SIZE_BYTES);
  localparam int unsigned MemDwordAddrWidth = MemByteAddrWidth - 3;

  // Data memory (dual-port RAM, only port B used for data access): one
  // MemDataBits-wide byte-enabled BRAM, mirroring the production dmem tier.
  tdp_bram_dc_byte_en #(
      .DATA_WIDTH(riscv_pkg::MemDataBits),
      .ADDR_WIDTH(MemDwordAddrWidth),
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
      .i_port_b_byte_address(riscv_pkg::MemDataBits'(o_data_mem_addr)),
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
