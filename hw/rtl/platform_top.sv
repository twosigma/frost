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

/*
  FROST platform composition: cpu_top + soc_top. The reusable CPU connects
  through one AXI4 master, explicit core controls, and the optional FROST
  coherent-agent port. The SoC owns board memory, peripheral and debug CDC.
*/
module platform_top #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b1,
    parameter logic [63:0] BOOT_ADDR = 64'd0,
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 17,
    // Simulation mtime multiplier; use 1 for synthesis.
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    // Cached address range; requests complete with variable latency.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned L0_CACHE_DEPTH = CACHE_NORMAL_MEMORY ?
        riscv_pkg::NormalLqL0Depth : riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Ways per set of the L1D, L1I, and L2 (see frost_cache_hierarchy).
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned L2_WAYS = 4,
    // L1D miss-status slots, and L2 miss-status and writeback slots (see
    // frost_cache_hierarchy).
    parameter int unsigned L1D_NUM_MSHR = 8,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    // Read waiter seats per L2 miss slot (see frost_cache_hierarchy). A
    // stream prefetch holds its slot's primary seat, so the L1D's reads of
    // both halves of the line need two.
    parameter int unsigned L2_NUM_WAITERS = 2,
    // The L2 stream prefetcher (see frost_cache_hierarchy): 0 turns it off.
    parameter int unsigned L2_PREFETCH = 1,
    parameter int unsigned L2_PREFETCH_DISTANCE = 8,
    parameter int unsigned L2_PREFETCH_INFLIGHT = 4,
    // L2 line size: 64 bytes, as on the X3, or 32, the L1s' line size, which
    // leaves out the line-size adapter. Every DDR AXI transfer carries one L2
    // line in a single beat.
    parameter int unsigned L2_LINE_BYTES = 64,
    // Simulation-only fast cache maintenance for fence.i (see frost_cache).
    // 0 = FPGA (cycle-accurate maintenance FSM); non-zero = sim fast path.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // Behavioral main-memory model (simulation only; hardware integration
    // replaces it with the DDR controller behind the same AXI port).
    parameter int unsigned DDR_MODEL_BYTES = 64 * 1024 * 1024,
    parameter int unsigned DDR_MODEL_LATENCY = 30,
    // Per-transaction latency jitter; 0 disables it (DDR_MODEL_REORDER can
    // still vary the latency).
    // See axi_behavioral_memory.LATENCY_JITTER.
    parameter int unsigned DDR_MODEL_LATENCY_JITTER = 0,
    // 1 = the model completes transactions of different ids out of order
    // (see axi_behavioral_memory.REORDER); 0 = in issue order per channel.
    parameter int unsigned DDR_MODEL_REORDER = 0,
    // 1 = cached tier ends in the behavioral DDR model; 0 = it ends at the
    // o_ddr_axi_*/i_ddr_axi_* ports (hardware DDR controller).
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // Simulation only: delay local instruction AXI completions with an LFSR.
    parameter int unsigned FETCH_VALID_FUZZ = 0,
    // Low 16 bits seed the fuzz LFSR; use a nonzero value.
    parameter int unsigned FETCH_VALID_FUZZ_SEED = 32'h0000_ACE1,
    // On-silicon boot-hang classifier that can take over the console UART.
    // Keep it default-off for normal interactive software and Linux bring-up.
    parameter int unsigned ENABLE_HANG_TRIAGE = 0,
    // Triage intervals in core cycles (about 2.8 s and 1 s at 322 MHz).
    parameter int unsigned HANG_TRIAGE_QUIET_CYCLES = 32'd900_000_000,
    parameter int unsigned HANG_TRIAGE_REEMIT_CYCLES = 32'd322_265_625,
    // RISC-V debug transport: 1 = the generic 5-bit-IR JTAG TAP
    // inside this module drives the DTM from the i_jtag_* pins (simulation,
    // portable synthesis); 0 = the DTM's BSCAN-style bundle comes from the
    // board's BSCANE2 primitives on the FPGA's own TAP (boards/) and the
    // i_jtag_* pins are ignored.
    parameter int unsigned DEBUG_JTAG_TAP = 1,
    // CPU profiling counters (see cpu_ooo); disabled in production.
    parameter int unsigned PERF_COUNTERS = 0,
    // Core clock frequency; sets the NIC's default TICK (cycles per
    // microsecond).
    parameter int unsigned CLK_FREQ_HZ = 322265625,
    // The NIC's raw TX-to-RX loopback (see frost.sv): 1 for one MAC clock
    // shared by both directions, 0 for independent TX and RX clocks.
    parameter int unsigned RAW_LOOPBACK = 1
) (
    input logic i_clk,
    input logic i_clk_div4,  // Divided clock for the low-BRAM programming port
    input logic i_rst,

    // Low-BRAM programming interface (div4 clock domain); writes go to both the
    // instruction and data copies
    input logic        i_instr_mem_en,
    input logic [ 3:0] i_instr_mem_we,
    input logic [31:0] i_instr_mem_addr,
    input logic [31:0] i_instr_mem_wrdata,

    output logic       o_uart_wr_en,
    output logic [7:0] o_uart_wr_data,
    // TX status from frost.sv: room for a burst (the transmit FIFO is not
    // almost full), and transmitter empty (nothing queued or being sent).
    input  logic       i_uart_tx_ready,
    input  logic       i_uart_tx_empty,

    // UART RX interface - received data from UART
    input  logic [7:0] i_uart_rx_data,
    input  logic       i_uart_rx_valid,
    output logic       o_uart_rx_ready,

    // FIFO interfaces
    output logic        o_fifo0_wr_en,
    output logic [31:0] o_fifo0_wr_data,
    input  logic [31:0] i_fifo0_rd_data,
    input  logic        i_fifo0_empty,
    output logic        o_fifo0_rd_en,

    output logic        o_fifo1_wr_en,
    output logic [31:0] o_fifo1_wr_data,
    input  logic [31:0] i_fifo1_rd_data,
    input  logic        i_fifo1_empty,
    output logic        o_fifo1_rd_en,

    // External interrupt input: APLIC source 2 (the ns16550 IRQ is source 1).
    // The APLIC's machine-domain line is registered one cycle before driving MEIP.
    input logic        i_external_interrupt,
    // DDR ECC reports from the board's reader (boards/x3/x3_ecc_reader.sv on
    // the X3) for the memory error unit; a board without one ties them low.
    input logic        i_ecc_present,
    input logic        i_ecc_poll,
    input logic        i_ecc_ce_valid,
    input logic [ 7:0] i_ecc_ce_count,
    input logic        i_ecc_ce_addr_valid,
    input logic [63:0] i_ecc_ce_addr,
    input logic        i_ecc_ue_valid,
    input logic        i_ecc_ue_addr_valid,
    input logic [63:0] i_ecc_ue_addr,

    // RISC-V debug transport pins (see DEBUG_JTAG_TAP).
    input  logic i_jtag_tck,
    input  logic i_jtag_tms,
    input  logic i_jtag_tdi,
    input  logic i_jtag_trst_n,
    output logic o_jtag_tdo,
    input  logic i_dtm_bscan_tck,
    input  logic i_dtm_bscan_tdi,
    input  logic i_dtm_bscan_tlr,
    input  logic i_dtm_bscan_capture,
    input  logic i_dtm_bscan_shift,
    input  logic i_dtm_bscan_update,
    input  logic i_dtm_bscan_sel_dtmcs,
    input  logic i_dtm_bscan_sel_dmi,
    output logic o_dtm_bscan_tdo_dtmcs,
    output logic o_dtm_bscan_tdo_dmi,

    // DDR AXI master (cache-hierarchy bridge): single-beat transfers of one
    // L2 line each, 512 bits wide with 64-byte lines. Quiescent when
    // USE_BEHAVIORAL_DDR=1 or the cached tier is disabled. Transaction ids
    // are the L2's downstream ids (DdrAxiIdBits wide, board-fixed).
    // i_ddr_axi_rst (i_clk domain) is the reset of the interconnect behind
    // these ports; the behavioral memory uses the CPU reset instead.
    input  logic                                 i_ddr_axi_rst,
    output logic                                 o_ddr_axi_awvalid,
    input  logic                                 i_ddr_axi_awready,
    output logic [                          4:0] o_ddr_axi_awid,
    output logic [riscv_pkg::DdrAxiAddrBits-1:0] o_ddr_axi_awaddr,
    output logic [                          7:0] o_ddr_axi_awlen,
    output logic [                          2:0] o_ddr_axi_awsize,
    output logic [                          1:0] o_ddr_axi_awburst,
    output logic                                 o_ddr_axi_wvalid,
    input  logic                                 i_ddr_axi_wready,
    output logic [          L2_LINE_BYTES*8-1:0] o_ddr_axi_wdata,
    output logic [            L2_LINE_BYTES-1:0] o_ddr_axi_wstrb,
    output logic                                 o_ddr_axi_wlast,
    input  logic                                 i_ddr_axi_bvalid,
    output logic                                 o_ddr_axi_bready,
    input  logic [                          4:0] i_ddr_axi_bid,
    input  logic [                          1:0] i_ddr_axi_bresp,
    output logic                                 o_ddr_axi_arvalid,
    input  logic                                 i_ddr_axi_arready,
    output logic [                          4:0] o_ddr_axi_arid,
    output logic [riscv_pkg::DdrAxiAddrBits-1:0] o_ddr_axi_araddr,
    output logic [                          7:0] o_ddr_axi_arlen,
    output logic [                          2:0] o_ddr_axi_arsize,
    output logic [                          1:0] o_ddr_axi_arburst,
    input  logic                                 i_ddr_axi_rvalid,
    output logic                                 o_ddr_axi_rready,
    input  logic [                          4:0] i_ddr_axi_rid,
    input  logic [          L2_LINE_BYTES*8-1:0] i_ddr_axi_rdata,
    input  logic [                          1:0] i_ddr_axi_rresp,
    input  logic                                 i_ddr_axi_rlast,

    // NIC (hw/rtl/peripherals/nic): the MAC clocks and their
    // presence levels, the raw PMA interface, the board's PHY lines and the
    // PCS block lock (synchronized to i_clk). The NIC lives with the cached
    // tier (its DMA port); without the tier its window reads zero.
    input  logic        i_nic_tx_clk,
    input  logic        i_nic_rx_clk,
    input  logic        i_nic_tx_clk_ok,
    input  logic        i_nic_rx_clk_ok,
    output logic [63:0] o_nic_tx_raw_data,
    output logic        o_nic_tx_raw_valid,
    input  logic [63:0] i_nic_rx_raw_data,
    input  logic        i_nic_rx_raw_valid,
    input  logic        i_nic_rx_signal_ok,
    input  logic [ 4:0] i_nic_phy_status,
    output logic [ 3:1] o_nic_phy_ctrl,
    output logic        o_nic_rx_block_lock
);

  logic cpu_rst;
  logic cpu_axi_rst;
  riscv_pkg::interrupt_t cpu_interrupts;
  logic cpu_msi_valid, cpu_msi_level;
  logic [10:0] cpu_msi_id;
  logic cpu_seip;
  logic [63:0] cpu_mtime;
  logic dbg_haltreq;
  logic dbg_go;
  logic [31:0] dbg_go_addr;
  logic [63:0] dbg_data;
  logic dbg_data_we;
  logic [63:0] dbg_data_wdata;
  logic debug_mode;
  logic dbg_parked;
  logic dbg_cmd_err;
  logic dbg_go_taken;
  logic commit_valid;
  logic [5:0] debug_irq_status;
  logic [riscv_pkg::XLEN-1:0] debug_commit_pc;
  logic [riscv_pkg::XLEN-1:0] debug_commit_2_pc;
  logic [1:0] debug_commit_valid;
  logic fatal_error;
  logic [riscv_pkg::PhysAddrBits-1:0] fatal_addr;
  logic coherent_req_valid;
  logic coherent_req_ready;
  logic coherent_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] coherent_req_addr;
  logic [255:0] coherent_req_wdata;
  logic [31:0] coherent_req_wstrb;
  logic [3:0] coherent_req_id;
  logic coherent_resp_valid;
  logic [3:0] coherent_resp_id;
  logic [255:0] coherent_resp_rdata;
  logic coherent_resp_error;
  logic axi_awvalid;
  logic axi_awready;
  logic [6-1:0] axi_awid;
  logic [riscv_pkg::PhysAddrBits-1:0] axi_awaddr;
  logic [7:0] axi_awlen;
  logic [2:0] axi_awsize;
  logic [1:0] axi_awburst;
  logic axi_awlock;
  logic [3:0] axi_awcache;
  logic [2:0] axi_awprot;
  logic [3:0] axi_awqos;
  logic [3:0] axi_awregion;
  logic [1-1:0] axi_awuser;
  logic axi_wvalid;
  logic axi_wready;
  logic [L2_LINE_BYTES*8-1:0] axi_wdata;
  logic [L2_LINE_BYTES-1:0] axi_wstrb;
  logic axi_wlast;
  logic [1-1:0] axi_wuser;
  logic axi_bvalid;
  logic axi_bready;
  logic [6-1:0] axi_bid;
  logic [1:0] axi_bresp;
  logic [1-1:0] axi_buser;
  logic axi_arvalid;
  logic axi_arready;
  logic [6-1:0] axi_arid;
  logic [riscv_pkg::PhysAddrBits-1:0] axi_araddr;
  logic [7:0] axi_arlen;
  logic [2:0] axi_arsize;
  logic [1:0] axi_arburst;
  logic axi_arlock;
  logic [3:0] axi_arcache;
  logic [2:0] axi_arprot;
  logic [3:0] axi_arqos;
  logic [3:0] axi_arregion;
  logic [1-1:0] axi_aruser;
  logic axi_rvalid;
  logic axi_rready;
  logic [6-1:0] axi_rid;
  logic [L2_LINE_BYTES*8-1:0] axi_rdata;
  logic [1:0] axi_rresp;
  logic axi_rlast;
  logic [1-1:0] axi_ruser;

  initial begin
    if (!riscv_pkg::PmaUsesFrostMap || 64'(CACHED_BASE) != riscv_pkg::DdrBase ||
        CACHED_SIZE_BYTES != riscv_pkg::DdrCapacityBytes)
      $fatal(
          1,
          "platform_top: FROST SoC requires its default map; integrate cpu_top directly for another map"
      );
  end

  cpu_top #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .DECODED_QUEUE_DEPTH(DECODED_QUEUE_DEPTH),
      .L1_CACHE_BYTES(L1_CACHE_BYTES),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .L2_CACHE_BYTES(L2_CACHE_BYTES),
      .L1D_WAYS(L1D_WAYS),
      .L1I_WAYS(L1I_WAYS),
      .L2_WAYS(L2_WAYS),
      .L1D_NUM_MSHR(L1D_NUM_MSHR),
      .L2_NUM_MSHR(L2_NUM_MSHR),
      .L2_NUM_WB(L2_NUM_WB),
      .L2_NUM_WAITERS(L2_NUM_WAITERS),
      .L2_PREFETCH(L2_PREFETCH),
      .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
      .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
      .L2_LINE_BYTES(L2_LINE_BYTES),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .PERF_COUNTERS(PERF_COUNTERS),
      .ENABLE_COHERENCE(ENABLE_CACHED_TIER != 0)
  ) cpu (
      .i_clk(i_clk),
      .i_rst(cpu_rst),
      .i_axi_rst(cpu_axi_rst),
      .i_boot_addr(BOOT_ADDR),
      .i_interrupts(cpu_interrupts),
      .i_seip(cpu_seip),
      .i_msi_valid(cpu_msi_valid),
      .i_msi_level(cpu_msi_level),
      .i_msi_id(cpu_msi_id),
      .i_mtime(cpu_mtime),
      .i_disable_branch_prediction(1'b0),
      .i_dbg_haltreq(dbg_haltreq),
      .i_dbg_go(dbg_go),
      .i_dbg_go_addr(dbg_go_addr),
      .i_dbg_data(dbg_data),
      .o_dbg_data_we(dbg_data_we),
      .o_dbg_data_wdata(dbg_data_wdata),
      .o_debug_mode(debug_mode),
      .o_dbg_parked(dbg_parked),
      .o_dbg_cmd_err(dbg_cmd_err),
      .o_dbg_go_taken(dbg_go_taken),
      .o_rst_done(),
      .o_commit_valid(commit_valid),
      .o_debug_irq_status(debug_irq_status),
      .o_debug_commit_pc(debug_commit_pc),
      .o_debug_commit_2_pc(debug_commit_2_pc),
      .o_debug_commit_valid(debug_commit_valid),
      .o_fatal_error(fatal_error),
      .o_fatal_addr(fatal_addr),
      .o_axi_idle(),
      .i_coherent_req_valid(coherent_req_valid),
      .o_coherent_req_ready(coherent_req_ready),
      .i_coherent_req_write(coherent_req_write),
      .i_coherent_req_addr(coherent_req_addr),
      .i_coherent_req_wdata(coherent_req_wdata),
      .i_coherent_req_wstrb(coherent_req_wstrb),
      .i_coherent_req_id(coherent_req_id),
      .o_coherent_resp_valid(coherent_resp_valid),
      .o_coherent_resp_id(coherent_resp_id),
      .o_coherent_resp_rdata(coherent_resp_rdata),
      .o_coherent_resp_error(coherent_resp_error),
      .o_axi_awvalid(axi_awvalid),
      .i_axi_awready(axi_awready),
      .o_axi_awid(axi_awid),
      .o_axi_awaddr(axi_awaddr),
      .o_axi_awlen(axi_awlen),
      .o_axi_awsize(axi_awsize),
      .o_axi_awburst(axi_awburst),
      .o_axi_awlock(axi_awlock),
      .o_axi_awcache(axi_awcache),
      .o_axi_awprot(axi_awprot),
      .o_axi_awqos(axi_awqos),
      .o_axi_awregion(axi_awregion),
      .o_axi_awuser(axi_awuser),
      .o_axi_wvalid(axi_wvalid),
      .i_axi_wready(axi_wready),
      .o_axi_wdata(axi_wdata),
      .o_axi_wstrb(axi_wstrb),
      .o_axi_wlast(axi_wlast),
      .o_axi_wuser(axi_wuser),
      .i_axi_bvalid(axi_bvalid),
      .o_axi_bready(axi_bready),
      .i_axi_bid(axi_bid),
      .i_axi_bresp(axi_bresp),
      .i_axi_buser(axi_buser),
      .o_axi_arvalid(axi_arvalid),
      .i_axi_arready(axi_arready),
      .o_axi_arid(axi_arid),
      .o_axi_araddr(axi_araddr),
      .o_axi_arlen(axi_arlen),
      .o_axi_arsize(axi_arsize),
      .o_axi_arburst(axi_arburst),
      .o_axi_arlock(axi_arlock),
      .o_axi_arcache(axi_arcache),
      .o_axi_arprot(axi_arprot),
      .o_axi_arqos(axi_arqos),
      .o_axi_arregion(axi_arregion),
      .o_axi_aruser(axi_aruser),
      .i_axi_rvalid(axi_rvalid),
      .o_axi_rready(axi_rready),
      .i_axi_rid(axi_rid),
      .i_axi_rdata(axi_rdata),
      .i_axi_rresp(axi_rresp),
      .i_axi_rlast(axi_rlast),
      .i_axi_ruser(axi_ruser)
  );

  soc_top #(
      .MEM_SIZE_BYTES(MEM_SIZE_BYTES),
      .SIM_TIMER_SPEEDUP(SIM_TIMER_SPEEDUP),
      .CACHED_BASE(64'(CACHED_BASE)),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .L2_LINE_BYTES(L2_LINE_BYTES),
      .L2_NUM_MSHR(L2_NUM_MSHR),
      .L2_NUM_WB(L2_NUM_WB),
      .DDR_MODEL_BYTES(DDR_MODEL_BYTES),
      .DDR_MODEL_LATENCY(DDR_MODEL_LATENCY),
      .DDR_MODEL_LATENCY_JITTER(DDR_MODEL_LATENCY_JITTER),
      .DDR_MODEL_REORDER(DDR_MODEL_REORDER),
      .USE_BEHAVIORAL_DDR(USE_BEHAVIORAL_DDR),
      .FETCH_VALID_FUZZ(FETCH_VALID_FUZZ),
      .FETCH_VALID_FUZZ_SEED(FETCH_VALID_FUZZ_SEED),
      .ENABLE_HANG_TRIAGE(ENABLE_HANG_TRIAGE),
      .HANG_TRIAGE_QUIET_CYCLES(HANG_TRIAGE_QUIET_CYCLES),
      .HANG_TRIAGE_REEMIT_CYCLES(HANG_TRIAGE_REEMIT_CYCLES),
      .DEBUG_JTAG_TAP(DEBUG_JTAG_TAP),
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .RAW_LOOPBACK(RAW_LOOPBACK)
  ) soc (
      .i_clk(i_clk),
      .i_clk_div4(i_clk_div4),
      .i_rst(i_rst),
      .i_instr_mem_en(i_instr_mem_en),
      .i_instr_mem_we(i_instr_mem_we),
      .i_instr_mem_addr(i_instr_mem_addr),
      .i_instr_mem_wrdata(i_instr_mem_wrdata),
      .o_uart_wr_en(o_uart_wr_en),
      .o_uart_wr_data(o_uart_wr_data),
      .i_uart_tx_ready(i_uart_tx_ready),
      .i_uart_tx_empty(i_uart_tx_empty),
      .i_uart_rx_data(i_uart_rx_data),
      .i_uart_rx_valid(i_uart_rx_valid),
      .o_uart_rx_ready(o_uart_rx_ready),
      .o_fifo0_wr_en(o_fifo0_wr_en),
      .o_fifo0_wr_data(o_fifo0_wr_data),
      .i_fifo0_rd_data(i_fifo0_rd_data),
      .i_fifo0_empty(i_fifo0_empty),
      .o_fifo0_rd_en(o_fifo0_rd_en),
      .o_fifo1_wr_en(o_fifo1_wr_en),
      .o_fifo1_wr_data(o_fifo1_wr_data),
      .i_fifo1_rd_data(i_fifo1_rd_data),
      .i_fifo1_empty(i_fifo1_empty),
      .o_fifo1_rd_en(o_fifo1_rd_en),
      .i_external_interrupt(i_external_interrupt),
      .i_ecc_present(i_ecc_present),
      .i_ecc_poll(i_ecc_poll),
      .i_ecc_ce_valid(i_ecc_ce_valid),
      .i_ecc_ce_count(i_ecc_ce_count),
      .i_ecc_ce_addr_valid(i_ecc_ce_addr_valid),
      .i_ecc_ce_addr(i_ecc_ce_addr),
      .i_ecc_ue_valid(i_ecc_ue_valid),
      .i_ecc_ue_addr_valid(i_ecc_ue_addr_valid),
      .i_ecc_ue_addr(i_ecc_ue_addr),
      .i_jtag_tck(i_jtag_tck),
      .i_jtag_tms(i_jtag_tms),
      .i_jtag_tdi(i_jtag_tdi),
      .i_jtag_trst_n(i_jtag_trst_n),
      .o_jtag_tdo(o_jtag_tdo),
      .i_dtm_bscan_tck(i_dtm_bscan_tck),
      .i_dtm_bscan_tdi(i_dtm_bscan_tdi),
      .i_dtm_bscan_tlr(i_dtm_bscan_tlr),
      .i_dtm_bscan_capture(i_dtm_bscan_capture),
      .i_dtm_bscan_shift(i_dtm_bscan_shift),
      .i_dtm_bscan_update(i_dtm_bscan_update),
      .i_dtm_bscan_sel_dtmcs(i_dtm_bscan_sel_dtmcs),
      .i_dtm_bscan_sel_dmi(i_dtm_bscan_sel_dmi),
      .o_dtm_bscan_tdo_dtmcs(o_dtm_bscan_tdo_dtmcs),
      .o_dtm_bscan_tdo_dmi(o_dtm_bscan_tdo_dmi),
      .i_ddr_axi_rst(i_ddr_axi_rst),
      .o_ddr_axi_awvalid(o_ddr_axi_awvalid),
      .i_ddr_axi_awready(i_ddr_axi_awready),
      .o_ddr_axi_awid(o_ddr_axi_awid),
      .o_ddr_axi_awaddr(o_ddr_axi_awaddr),
      .o_ddr_axi_awlen(o_ddr_axi_awlen),
      .o_ddr_axi_awsize(o_ddr_axi_awsize),
      .o_ddr_axi_awburst(o_ddr_axi_awburst),
      .o_ddr_axi_wvalid(o_ddr_axi_wvalid),
      .i_ddr_axi_wready(i_ddr_axi_wready),
      .o_ddr_axi_wdata(o_ddr_axi_wdata),
      .o_ddr_axi_wstrb(o_ddr_axi_wstrb),
      .o_ddr_axi_wlast(o_ddr_axi_wlast),
      .i_ddr_axi_bvalid(i_ddr_axi_bvalid),
      .o_ddr_axi_bready(o_ddr_axi_bready),
      .i_ddr_axi_bid(i_ddr_axi_bid),
      .i_ddr_axi_bresp(i_ddr_axi_bresp),
      .o_ddr_axi_arvalid(o_ddr_axi_arvalid),
      .i_ddr_axi_arready(i_ddr_axi_arready),
      .o_ddr_axi_arid(o_ddr_axi_arid),
      .o_ddr_axi_araddr(o_ddr_axi_araddr),
      .o_ddr_axi_arlen(o_ddr_axi_arlen),
      .o_ddr_axi_arsize(o_ddr_axi_arsize),
      .o_ddr_axi_arburst(o_ddr_axi_arburst),
      .i_ddr_axi_rvalid(i_ddr_axi_rvalid),
      .o_ddr_axi_rready(o_ddr_axi_rready),
      .i_ddr_axi_rid(i_ddr_axi_rid),
      .i_ddr_axi_rdata(i_ddr_axi_rdata),
      .i_ddr_axi_rresp(i_ddr_axi_rresp),
      .i_ddr_axi_rlast(i_ddr_axi_rlast),
      .i_nic_tx_clk(i_nic_tx_clk),
      .i_nic_rx_clk(i_nic_rx_clk),
      .i_nic_tx_clk_ok(i_nic_tx_clk_ok),
      .i_nic_rx_clk_ok(i_nic_rx_clk_ok),
      .o_nic_tx_raw_data(o_nic_tx_raw_data),
      .o_nic_tx_raw_valid(o_nic_tx_raw_valid),
      .i_nic_rx_raw_data(i_nic_rx_raw_data),
      .i_nic_rx_raw_valid(i_nic_rx_raw_valid),
      .i_nic_rx_signal_ok(i_nic_rx_signal_ok),
      .i_nic_phy_status(i_nic_phy_status),
      .o_nic_phy_ctrl(o_nic_phy_ctrl),
      .o_nic_rx_block_lock(o_nic_rx_block_lock),
      .o_cpu_rst(cpu_rst),
      .o_cpu_axi_rst(cpu_axi_rst),
      .o_cpu_interrupts(cpu_interrupts),
      .o_cpu_seip(cpu_seip),
      .o_cpu_msi_valid(cpu_msi_valid),
      .o_cpu_msi_level(cpu_msi_level),
      .o_cpu_msi_id(cpu_msi_id),
      .o_cpu_mtime(cpu_mtime),
      .o_dbg_haltreq(dbg_haltreq),
      .o_dbg_go(dbg_go),
      .o_dbg_go_addr(dbg_go_addr),
      .o_dbg_data(dbg_data),
      .i_dbg_data_we(dbg_data_we),
      .i_dbg_data_wdata(dbg_data_wdata),
      .i_debug_mode(debug_mode),
      .i_dbg_parked(dbg_parked),
      .i_dbg_cmd_err(dbg_cmd_err),
      .i_dbg_go_taken(dbg_go_taken),
      .i_commit_valid(commit_valid),
      .i_debug_irq_status(debug_irq_status),
      .i_debug_commit_pc(debug_commit_pc),
      .i_debug_commit_2_pc(debug_commit_2_pc),
      .i_debug_commit_valid(debug_commit_valid),
      .o_coherent_req_valid(coherent_req_valid),
      .i_coherent_req_ready(coherent_req_ready),
      .o_coherent_req_write(coherent_req_write),
      .o_coherent_req_addr(coherent_req_addr),
      .o_coherent_req_wdata(coherent_req_wdata),
      .o_coherent_req_wstrb(coherent_req_wstrb),
      .o_coherent_req_id(coherent_req_id),
      .i_coherent_resp_valid(coherent_resp_valid),
      .i_coherent_resp_id(coherent_resp_id),
      .i_coherent_resp_rdata(coherent_resp_rdata),
      .i_coherent_resp_error(coherent_resp_error),
      .i_axi_awvalid(axi_awvalid),
      .o_axi_awready(axi_awready),
      .i_axi_awid(axi_awid),
      .i_axi_awaddr(axi_awaddr),
      .i_axi_awlen(axi_awlen),
      .i_axi_awsize(axi_awsize),
      .i_axi_awburst(axi_awburst),
      .i_axi_awlock(axi_awlock),
      .i_axi_awcache(axi_awcache),
      .i_axi_awprot(axi_awprot),
      .i_axi_awqos(axi_awqos),
      .i_axi_awregion(axi_awregion),
      .i_axi_awuser(axi_awuser),
      .i_axi_wvalid(axi_wvalid),
      .o_axi_wready(axi_wready),
      .i_axi_wdata(axi_wdata),
      .i_axi_wstrb(axi_wstrb),
      .i_axi_wlast(axi_wlast),
      .i_axi_wuser(axi_wuser),
      .o_axi_bvalid(axi_bvalid),
      .i_axi_bready(axi_bready),
      .o_axi_bid(axi_bid),
      .o_axi_bresp(axi_bresp),
      .o_axi_buser(axi_buser),
      .i_axi_arvalid(axi_arvalid),
      .o_axi_arready(axi_arready),
      .i_axi_arid(axi_arid),
      .i_axi_araddr(axi_araddr),
      .i_axi_arlen(axi_arlen),
      .i_axi_arsize(axi_arsize),
      .i_axi_arburst(axi_arburst),
      .i_axi_arlock(axi_arlock),
      .i_axi_arcache(axi_arcache),
      .i_axi_arprot(axi_arprot),
      .i_axi_arqos(axi_arqos),
      .i_axi_arregion(axi_arregion),
      .i_axi_aruser(axi_aruser),
      .o_axi_rvalid(axi_rvalid),
      .i_axi_rready(axi_rready),
      .o_axi_rid(axi_rid),
      .o_axi_rdata(axi_rdata),
      .o_axi_rresp(axi_rresp),
      .o_axi_rlast(axi_rlast),
      .o_axi_ruser(axi_ruser)
  );
endmodule : platform_top
