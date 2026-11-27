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

// Simulation-only wrapper around cpu_ooo for the cocotb directed tests. The
// instruction feed is registered one cycle to mimic the read latency of the
// block-RAM instruction memory.
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
  logic i_instr_bank_sel_r;  // Fetch-word parity (pc_reg[2]) for the window
  logic i_instr_valid;  // Fetch window valid (tie 1: fixed 1-cycle provider)
  logic [riscv_pkg::XLEN-3:0] i_served_word_low;
  logic [riscv_pkg::XLEN-3:0] i_served_last_word_low;
  logic [riscv_pkg::XLEN-3:0] i_served_prev_word_low;
  logic i_served_prev_word_valid_low;
  logic [riscv_pkg::XLEN-3:0] i_served_word_high;
  logic [riscv_pkg::XLEN-3:0] i_served_last_word_high;
  logic [riscv_pkg::XLEN-3:0] i_served_prev_word_high;
  logic i_served_prev_word_valid_high;
  logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data;  // Data memory read data to CPU
  logic pipeline_stall_from_cpu;  // Stall signal monitoring (registered, 1-cycle delay)
  logic pipeline_stall_comb;  // Stall signal (combinational, immediate)
  logic reset_to_cpu;  // Reset signal monitoring

  // Independent black-box 64-bit fetch provider: pairs two sequential 32-bit
  // testbench words into one 64-bit window and holds an unclaimed window
  // (driving i_instr_valid high until o_fetch_live_claim or a redirect)
  // without reading any internal if_stage backpressure signals.
  typedef enum logic [1:0] {
    TB_IDLE     = 2'd0,
    TB_HAVE_LO  = 2'd1,
    TB_HOLD_WIN = 2'd2
  } tb_fetch_state_e;

  logic [riscv_pkg::XLEN-1:0] cpu_o_pc;
  tb_fetch_state_e tb_state_q;
  tb_fetch_state_e tb_eff_state;
  logic [riscv_pkg::XLEN-1:0] tb_req_pc_q;
  logic [riscv_pkg::XLEN-1:0] tb_next_pc_q;
  logic tb_use_next_pc_q;
  logic [riscv_pkg::XLEN-1:0] tb_idle_pc;
  logic [31:0] tb_buf_lo_q;
  logic [31:0] tb_buf_hi_q;
  logic [31:0] tb_hi_word;
  logic tb_bank_sel_q;  // parity (PC[2]) of the fetched address
  logic tb_retarget;
  riscv_pkg::fetch_verdict_t tb_idle_verdict;

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
  // Cached tier is inactive; directed programs use only low BRAM.
  logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en;
  logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data;
  logic o_data_mem_cached_read_enable;
  logic o_data_mem_cached_read_sel;
  logic o_data_mem_cached_read_if_sel;
  logic o_data_mem_cached_read_if_clear;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id;
  logic o_data_mem_cached_read_no_merge;
  logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id;
  logic i_cached_read_valid;
  logic o_cached_read_ready;
  logic i_cached_write_done;
  logic i_cached_write_inflight;
  cache_perf_pkg::cache_perf_events_t i_cache_perf_events;
  // Low-BRAM fetch: register the core's faults with the window. Directed
  // programs use in-range Bare-mode addresses, so those faults stay clear.
  logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa0;
  logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa1;
  logic o_fetch_pa_valid;
  logic o_fetch_fault0;
  logic o_fetch_fault0_page;
  logic o_fetch_fault1;
  logic o_fetch_fault1_page;
  logic o_fetch_line_after_ok;
  logic o_fetch_redirect;  // low-presenter stale-request retarget
  logic o_fetch_cached_retarget;  // cached-provider architectural/epoch retarget
  logic i_instr_fault0;
  logic i_instr_fault0_page;
  logic i_instr_fault1;
  logic i_instr_fault1_page;
  logic i_served_high;
  logic tb_fault0_q, tb_fault0_page_q, tb_fault1_q, tb_fault1_page_q;
  // No page-table memory: a walk would stall. Programs must stay in Bare mode.
  logic o_walk_line_req_valid;
  logic i_walk_line_req_ready;
  logic [riscv_pkg::PhysAddrBits-1:0] o_walk_line_req_addr;
  logic [1:0] o_walk_line_req_id;
  logic i_walk_line_resp_valid;
  logic [1:0] i_walk_line_resp_id;
  logic [255:0] i_walk_line_resp_rdata;
  // Debug module ports: no debugger in this bench, so the request inputs idle
  // low and the status outputs are unobserved.
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

  // No DMA agent; coherence requests idle and responses are unobserved.
  logic i_coh_admit_valid;
  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_admit_slot;
  logic [riscv_pkg::XLEN-1:0] i_coh_admit_addr;
  logic o_coh_admit_ready;
  logic o_coh_admit_clean;
  logic i_coh_inval_valid;
  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_inval_slot;
  logic o_coh_inval_done;
  logic i_coh_release_valid;
  logic [riscv_pkg::DmaCoherenceLockBits-1:0] i_coh_release_slot;
  assign i_coh_admit_valid = 1'b0;
  assign i_coh_admit_slot = '0;
  assign i_coh_admit_addr = '0;
  assign i_coh_inval_valid = 1'b0;
  assign i_coh_inval_slot = '0;
  assign i_coh_release_valid = 1'b0;
  assign i_coh_release_slot = '0;
  // Debug taps (read from cocotb via device_under_test.*; also exposed here).
  logic [5:0] o_debug_irq_status;
  logic [riscv_pkg::XLEN-1:0] o_debug_commit_pc;
  logic [riscv_pkg::XLEN-1:0] o_debug_commit_2_pc;
  logic [1:0] o_debug_commit_valid;

  // Interrupt and timer inputs to the CPU. A test forces or deposits onto the
  // _reg copies, which nothing drives after the initial block below. The
  // continuous assigns carry them to the CPU-facing names.
  interrupt_t i_interrupts_reg;
  logic [63:0] i_mtime_reg;
  interrupt_t i_interrupts;
  logic [63:0] i_mtime;
  // Supervisor external-interrupt line: held low in this bench.
  logic i_seip_line;
  assign i_seip_line = 1'b0;

  initial begin
    i_interrupts_reg = 3'b000;
    i_mtime_reg = 64'd0;
  end

  assign i_interrupts = i_interrupts_reg;
  assign i_mtime = i_mtime_reg;

  // Track window pairing and hold unclaimed windows using only cpu_ooo's
  // public fetch interface (o_pc, o_fetch_redirect, o_fetch_live_claim) and
  // pipeline_ctrl.{reset,flush,stall}.
  logic tb_flush;
  assign tb_flush = i_rst || device_under_test.pipeline_ctrl.reset ||
                    device_under_test.pipeline_ctrl.flush;
  assign tb_retarget = o_fetch_redirect;
  assign tb_eff_state = tb_retarget ? TB_IDLE : tb_state_q;
  assign tb_idle_pc = (!tb_retarget && tb_use_next_pc_q) ? tb_next_pc_q : cpu_o_pc;
  assign tb_idle_verdict = riscv_pkg::fetch_verdict(tb_idle_pc);

  // Expose the exact PC of the word currently being fed by the testbench.
  assign o_pc = (tb_eff_state == TB_HAVE_LO) ?
      {tb_req_pc_q[riscv_pkg::XLEN-1:2] + (riscv_pkg::XLEN - 2)'(1), 2'b00} :
      (tb_eff_state == TB_HOLD_WIN) ? tb_req_pc_q : tb_idle_pc;

  always_ff @(posedge i_clk) begin
    pipeline_stall_from_cpu <= device_under_test.pipeline_ctrl.stall;
    if (tb_flush) begin
      tb_state_q       <= TB_IDLE;
      tb_use_next_pc_q <= 1'b0;
    end else begin
      unique case (tb_eff_state)
        TB_IDLE: begin
          if (tb_retarget) begin
            tb_use_next_pc_q <= 1'b0;
          end
          if (!device_under_test.pipeline_ctrl.stall) begin
            tb_buf_lo_q <= instruction_from_testbench;
            tb_req_pc_q <= tb_idle_pc;
            tb_bank_sel_q <= tb_idle_pc[2];
            tb_fault0_q <= (tb_idle_pc == cpu_o_pc) ? o_fetch_fault0 : tb_idle_verdict.bare_fault0;
            tb_fault0_page_q <= (tb_idle_pc == cpu_o_pc) ? o_fetch_fault0_page : 1'b0;
            tb_fault1_q <= (tb_idle_pc == cpu_o_pc) ? o_fetch_fault1 : tb_idle_verdict.bare_fault1;
            tb_fault1_page_q <= (tb_idle_pc == cpu_o_pc) ? o_fetch_fault1_page : 1'b0;
            tb_state_q <= TB_HAVE_LO;
          end else begin
            tb_state_q <= TB_IDLE;
          end
        end
        TB_HAVE_LO: begin
          if (!device_under_test.pipeline_ctrl.stall) begin
            if (o_fetch_live_claim) begin
              tb_state_q <= TB_IDLE;
              tb_next_pc_q <= {tb_req_pc_q[riscv_pkg::XLEN-1:2] + (riscv_pkg::XLEN - 2)'(2), 2'b00};
              tb_use_next_pc_q <= 1'b1;
            end else begin
              tb_buf_hi_q <= instruction_from_testbench;
              tb_state_q  <= TB_HOLD_WIN;
            end
          end
        end
        TB_HOLD_WIN: begin
          if (o_fetch_live_claim) begin
            tb_state_q <= TB_IDLE;
            tb_next_pc_q <= {tb_req_pc_q[riscv_pkg::XLEN-1:2] + (riscv_pkg::XLEN - 2)'(2), 2'b00};
            tb_use_next_pc_q <= 1'b1;
          end
        end
        default: begin
          tb_state_q       <= TB_IDLE;
          tb_use_next_pc_q <= 1'b0;
        end
      endcase
    end
  end

  assign tb_hi_word = (tb_eff_state == TB_HOLD_WIN) ? tb_buf_hi_q : instruction_from_testbench;
  assign i_instr = {tb_hi_word, tb_buf_lo_q};
  // The same window in physical bank order, {odd, even}, as the low BRAM
  // presents it: the current word sits in the bank its address parity names.
  logic [63:0] i_instr_low_by_parity;
  logic [63:0] i_instr_high;
  logic i_instr_window_high;
  assign i_instr_low_by_parity = tb_bank_sel_q ? {tb_buf_lo_q, tb_hi_word} :
                                                 {tb_hi_word, tb_buf_lo_q};
  assign i_instr_high = '0;
  assign i_instr_window_high = 1'b0;
  // Per-word predecode sideband, computed by the same pure function the RTL
  // fetch path uses (riscv_pkg::imem_make_sideband; no lookahead).
  assign i_instr_sideband = {
    riscv_pkg::imem_make_sideband(tb_hi_word), riscv_pkg::imem_make_sideband(tb_buf_lo_q)
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
  // bank_sel_r == pc_reg[2] => aligned: current word taken from i_instr[31:0].
  assign i_instr_bank_sel_r = tb_bank_sel_q;
  // This fixed one-cycle provider is the low lane. All arithmetic tags derive
  // from the registered window PC; the unused high lane is internally coherent.
  assign i_served_word_low = tb_req_pc_q[riscv_pkg::XLEN-1:2];
  assign i_served_last_word_low = tb_req_pc_q[riscv_pkg::XLEN-1:2] + (riscv_pkg::XLEN - 2)'(1);
  assign i_served_prev_word_low = tb_req_pc_q[riscv_pkg::XLEN-1:2] - (riscv_pkg::XLEN - 2)'(1);
  assign i_served_prev_word_valid_low = |tb_req_pc_q[riscv_pkg::XLEN-1:2];
  assign i_served_word_high = '0;
  assign i_served_last_word_high = 'd1;
  assign i_served_prev_word_high = '1;
  assign i_served_prev_word_valid_high = 1'b0;
  assign i_instr_fault0 = tb_fault0_q;
  assign i_instr_fault0_page = tb_fault0_page_q;
  assign i_instr_fault1 = tb_fault1_q;
  assign i_instr_fault1_page = tb_fault1_page_q;
  assign i_served_high = 1'b0;
  assign i_instr_pc_metadata_served_high = 1'b0;
  // Present the paired 64-bit window on the cycle its second word arrives and
  // keep i_instr_valid asserted while holding an unclaimed window.
  assign i_instr_valid = (tb_eff_state == TB_HOLD_WIN) ||
      ((tb_eff_state == TB_HAVE_LO) && !device_under_test.pipeline_ctrl.stall);

  // No I-cache: complete FENCE.I synchronization immediately.
  assign i_fence_i_sync_done = o_fence_i_sync_req;

  // Cached (high-address) tier response inputs tied inactive (tier unused).
  assign i_cached_read_data = '0;
  assign i_cached_read_id = '0;
  assign i_cached_read_valid = 1'b0;
  assign i_cached_write_done = 1'b0;
  assign i_cached_write_inflight = 1'b0;
  assign i_cache_perf_events = '0;
  // Walker line port has no slave (see the declarations above).
  assign i_walk_line_req_ready = 1'b0;
  assign i_walk_line_resp_valid = 1'b0;
  assign i_walk_line_resp_id = '0;
  assign i_walk_line_resp_rdata = '0;

  // Memory addressing parameters
  localparam int unsigned MemByteAddrWidth  = $clog2(MEM_SIZE_BYTES);
  localparam int unsigned MemDwordAddrWidth = MemByteAddrWidth - 3;

  // Data memory (dual-port RAM, only port B used for data access): one
  // MemDataBits-wide byte-enabled BRAM, mirroring the production dmem tier.
  tdp_bram_dc_byte_en #(
      .DATA_WIDTH(riscv_pkg::MemDataBits),
      .ADDR_WIDTH(MemDwordAddrWidth),
      .USE_INIT_FILE(1'b0)  // Don't load from file in testbench
  ) data_memory_for_simulation (
      .i_port_a_clk(i_clk),
      .i_port_b_clk(i_clk),
      // Port A unused in testbench
      .i_port_a_byte_address('0),
      .i_port_a_write_data('0),
      .i_port_a_byte_write_enable('0),
      .o_port_a_read_data(  /*not connected*/),
      // Port B: CPU data memory access, written with the BRAM-only byte enables
      // (MMIO and cached-tier stores masked off), as in frost_rvfi_platform.
      .i_port_b_byte_address(riscv_pkg::MemDataBits'(o_data_mem_addr)),
      .i_port_b_write_data(o_data_mem_wr_data),
      .i_port_b_byte_write_enable(o_data_mem_bram_byte_wr_en),
      .o_port_b_read_data(i_data_mem_rd_data)
  );

  assign reset_to_cpu = device_under_test.pipeline_ctrl.reset;

  // Unregistered stall so the test framework pauses feeding new words whenever
  // the core stalls or this provider is holding an unclaimed 64-bit window.
  assign pipeline_stall_comb = device_under_test.pipeline_ctrl.stall ||
                               (tb_eff_state == TB_HOLD_WIN);

  // The instruction fixture serves private uncached memory at fixed latency.
  // Coherent cache ports, MSI ingress and variable-latency completions are idle.
  cpu_ooo device_under_test (
      .o_pc(cpu_o_pc),
      .i_coherent_store_pending(1'b0),
      .i_coherent_store_ready(1'b1),
      .i_coherent_twin_push(1'b0),
      .i_coherent_twin_push_addr('0),
      .i_coherent_sc_pending(1'b0),
      .i_coherent_atomic_live(1'b0),
      .i_coherent_block_valid('0),
      .i_coherent_block_addr('0),
      .i_coherent_cut_hold(1'b0),
      .o_coherent_sc_valid(),
      .i_coherent_sc_ready(1'b0),
      .o_coherent_sc_addr(),
      .o_coherent_sc_size(),
      .o_coherent_sc_tag(),
      .i_coherent_sc_result_valid(1'b0),
      .o_coherent_sc_result_ready(),
      .i_coherent_sc_success(1'b0),
      .i_coherent_sc_error(1'b0),
      .i_coherent_sc_write_done(1'b0),
      .i_coherent_sc_write_tag('0),
      .o_coherent_reservation_valid(),
      .o_coherent_reservation_addr(),
      .o_coherent_reservation_size(),
      .o_coherent_read_kind(),
      .o_coherent_read_size(),
      .o_coherent_read_tag(),
      .o_coherent_write_atomic(),
      .o_coherent_write_sc(),
      .o_coherent_write_zero(),
      .o_cmo_valid(),
      .o_cmo_kind(),
      .o_cmo_addr(),
      .i_cmo_ready(1'b0),
      .i_cmo_done(1'b0),
      .o_coherent_write_more(),
      .o_coherent_next_same(),
      .o_coherent_write_tag(),
      .o_coherent_atomic_protected(),
      .o_coherent_sc_commit(),
      .i_boot_addr('0),
      .i_fatal_stop(1'b0),
      .i_msi_valid(1'b0),
      .i_msi_level(1'b0),
      .i_msi_id('0),
      .i_walk_line_resp_error(1'b0),
      .i_cached_read_error(1'b0),
      .i_uncached_read_request_ready(1'b1),
      .o_uncached_addr(),
      .o_uncached_read_enable(),
      .o_uncached_read_size(),
      .i_uncached_read_valid(1'b0),
      .o_uncached_read_ready(),
      .i_uncached_read_data('0),
      .i_uncached_read_status(2'b00),
      .o_uncached_write_byte_en(),
      .o_uncached_write_size(),
      .o_uncached_write_buffered(),
      .i_uncached_write_done(1'b0),
      .i_uncached_write_status(2'b00),
      .i_uncached_write_inflight(1'b0),
      // The misaligned-access engine is not built here (MISALIGNED_HW=0); its
      // line requests and fatal report stay idle.
      .o_ma_line_req_valid(),
      .i_ma_line_req_ready(1'b0),
      .o_ma_line_req_write(),
      .o_ma_line_req_addr(),
      .o_ma_line_req_data(),
      .o_ma_line_req_mask(),
      .o_ma_line_req_id(),
      .i_ma_line_resp_valid(1'b0),
      .i_ma_line_resp_id('0),
      .i_ma_line_resp_data('0),
      .i_ma_line_resp_error(1'b0),
      .o_ma_fatal(),
      .o_ma_fatal_addr(),
      .*
  );

endmodule : cpu_tb
