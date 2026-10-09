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
  FROST system top level: the CPU and memory subsystem (cpu_and_mem), reset
  synchronization, the UART with its clock-crossing FIFOs, and the two MMIO
  FIFOs. The debug transport arrives on i_jtag_* (generic TAP) or, with
  DEBUG_JTAG_TAP=0, as the board's BSCAN bundle. i_clk runs the CPU and
  memories; i_clk_div4 runs the UART and the BRAM programming port that the
  JTAG loader uses. The two clocks are related, which lets the dual-clock
  FIFOs use binary pointers. The RTL is portable: defining FROST_XILINX_PRIMS
  selects explicit Xilinx primitives in a few modules, and builds without it
  use the portable implementations.
*/
module frost #(
    parameter int unsigned CLK_FREQ_HZ = 322265625,
    // Low-memory size; override in simulation with Verilator -G.
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 18,
    // Simulation mtime multiplier; use 1 for synthesis.
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    // Cached region [CACHED_BASE, CACHED_BASE + CACHED_SIZE_BYTES), backed by
    // write-back caches and DDR. Supports several tagged loads and one store
    // in flight, with variable-latency handshakes.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000,  // 1 GiB
    // 0 omits the hierarchy: cached loads return zero and stores have no effect.
    parameter int unsigned ENABLE_CACHED_TIER = 0,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Simulation-only fast cache maintenance for fence.i: 0 selects the FPGA
    // cycle-accurate path; non-zero selects the sim fast path (see frost_cache).
    // Set to 1 only by the cocotb sim build, never for boards.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // Behavioral main-memory model knobs (simulation only).
    parameter int unsigned DDR_MODEL_BYTES = 64 * 1024 * 1024,
    parameter int unsigned DDR_MODEL_LATENCY = 30,
    // Per-transaction model latency jitter; 0 disables it (DDR_MODEL_REORDER
    // can still vary the latency).
    parameter int unsigned DDR_MODEL_LATENCY_JITTER = 0,
    // Out-of-order completion across ids in the model (0 = in order).
    parameter int unsigned DDR_MODEL_REORDER = 0,
    // 1 = the cached tier ends in the simulation-only behavioral DDR model;
    // 0 = it ends at the o_ddr_axi_*/i_ddr_axi_* ports (hardware boards wire
    // them to their DDR controller subsystem).
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // Simulation-only fetch-latency fuzz (see cpu_and_mem). Hardware keeps 0.
    parameter int unsigned FETCH_VALID_FUZZ = 0,
    // Low 16 bits seed the fuzz LFSR; use a nonzero value.
    parameter int unsigned FETCH_VALID_FUZZ_SEED = 32'h0000_ACE1,
    // Optional on-silicon boot-hang classifier that can emit over UART.
    parameter int unsigned ENABLE_HANG_TRIAGE = 0,
    // Triage pacing (see cpu_and_mem): silicon-scale defaults; sim runs
    // override these to fit the cycle budget.
    parameter int unsigned HANG_TRIAGE_QUIET_CYCLES = 32'd900_000_000,
    parameter int unsigned HANG_TRIAGE_REEMIT_CYCLES = 32'd322_265_625,
    // mperf* CSRs; disabled in production (build.py --perf-counters enables them).
    parameter int unsigned PERF_COUNTERS = 0,
    // RISC-V debug transport: 1 = generic JTAG TAP on the
    // i_jtag_* pins (simulation, portable synthesis); 0 = the DTM's BSCAN
    // bundle comes from the board's BSCANE2 primitives (i_dtm_bscan_*).
    parameter int unsigned DEBUG_JTAG_TAP = 1,
    // Build PHY_CTRL MAC_LOOPBACK (nic_mac_wrap). Requires one shared MAC
    // clock; use 0 with independent transceiver TX and RX clocks.
    parameter int unsigned RAW_LOOPBACK = 1
) (
    input logic i_clk,
    input logic i_clk_div4,
    input logic i_rst_n,

    input logic        i_instr_mem_en,
    input logic [ 3:0] i_instr_mem_we,
    input logic [31:0] i_instr_mem_addr,
    input logic [31:0] i_instr_mem_wrdata,

    output logic o_uart_tx,
    input  logic i_uart_rx,

    // External interrupt input: PLIC source 2, level-triggered.
    // Optional: tie to 0 if not used
    input logic i_external_interrupt = 1'b0,

    // RISC-V debug transport pins (see DEBUG_JTAG_TAP). Boards
    // leave the i_jtag_* pins idle and feed the BSCAN bundle instead.
    input  logic i_jtag_tck = 1'b0,
    input  logic i_jtag_tms = 1'b0,
    input  logic i_jtag_tdi = 1'b0,
    input  logic i_jtag_trst_n = 1'b1,
    output logic o_jtag_tdo,
    input  logic i_dtm_bscan_tck = 1'b0,
    input  logic i_dtm_bscan_tdi = 1'b0,
    input  logic i_dtm_bscan_tlr = 1'b0,
    input  logic i_dtm_bscan_capture = 1'b0,
    input  logic i_dtm_bscan_shift = 1'b0,
    input  logic i_dtm_bscan_update = 1'b0,
    input  logic i_dtm_bscan_sel_dtmcs = 1'b0,
    input  logic i_dtm_bscan_sel_dmi = 1'b0,
    output logic o_dtm_bscan_tdo_dtmcs,
    output logic o_dtm_bscan_tdo_dmi,

    // DDR AXI master for the cache hierarchy: single-beat 256-bit bursts with
    // region-relative addresses. Quiescent when USE_BEHAVIORAL_DDR=1 or the
    // cached tier is disabled; hardware boards wire it to the DDR controller.
    // i_ddr_axi_rst_n (active low, asynchronous) is the reset of the
    // interconnect behind these ports: while it is low the bridge drives every
    // VALID low. Unused with the behavioral memory.
    input  logic         i_ddr_axi_rst_n = 1'b1,
    output logic         o_ddr_axi_awvalid,
    input  logic         i_ddr_axi_awready,
    output logic [  4:0] o_ddr_axi_awid,
    output logic [ 31:0] o_ddr_axi_awaddr,
    output logic [  7:0] o_ddr_axi_awlen,
    output logic [  2:0] o_ddr_axi_awsize,
    output logic [  1:0] o_ddr_axi_awburst,
    output logic         o_ddr_axi_wvalid,
    input  logic         i_ddr_axi_wready,
    output logic [255:0] o_ddr_axi_wdata,
    output logic [ 31:0] o_ddr_axi_wstrb,
    output logic         o_ddr_axi_wlast,
    input  logic         i_ddr_axi_bvalid,
    output logic         o_ddr_axi_bready,
    input  logic [  4:0] i_ddr_axi_bid,
    input  logic [  1:0] i_ddr_axi_bresp,
    output logic         o_ddr_axi_arvalid,
    input  logic         i_ddr_axi_arready,
    output logic [  4:0] o_ddr_axi_arid,
    output logic [ 31:0] o_ddr_axi_araddr,
    output logic [  7:0] o_ddr_axi_arlen,
    output logic [  2:0] o_ddr_axi_arsize,
    output logic [  1:0] o_ddr_axi_arburst,
    input  logic         i_ddr_axi_rvalid,
    output logic         o_ddr_axi_rready,
    input  logic [  4:0] i_ddr_axi_rid,
    input  logic [255:0] i_ddr_axi_rdata,
    input  logic [  1:0] i_ddr_axi_rresp,
    input  logic         i_ddr_axi_rlast,

    // MAC clocks have asynchronous clock-present levels. RAW_LOOPBACK requires
    // the same clock on both ports. PCS block lock is synchronized to i_clk
    // for the board's transceiver supervisor.
    input  logic        i_nic_tx_clk = 1'b0,
    input  logic        i_nic_rx_clk = 1'b0,
    input  logic        i_nic_tx_clk_ok = 1'b1,
    input  logic        i_nic_rx_clk_ok = 1'b1,
    output logic [63:0] o_nic_tx_raw_data,
    output logic        o_nic_tx_raw_valid,
    input  logic [63:0] i_nic_rx_raw_data = '0,
    input  logic        i_nic_rx_raw_valid = 1'b0,
    input  logic        i_nic_rx_signal_ok = 1'b0,
    input  logic [ 4:0] i_nic_phy_status = 5'b01111,
    output logic [ 3:1] o_nic_phy_ctrl,
    output logic        o_nic_rx_block_lock
);

  /*
    Synchronize the active-low reset into an active-high i_clk reset.
    Hold i_rst_n low for at least 20 i_clk cycles (five i_clk_div4 cycles):
    each dc_fifo needs reset applied on its divided-clock side while its
    main-clock side remains held.
  */
  localparam int unsigned NumResetSyncStages = 3;
  (* ASYNC_REG = "TRUE" *)
  logic [NumResetSyncStages-1:0] reset_synchronizer_shift_register;
  (* MAX_FANOUT = 1000 *) logic reset_synchronized;
  always_ff @(posedge i_clk)
    for (int i = 0; i < NumResetSyncStages; ++i)
      reset_synchronizer_shift_register[i] <= (i > 0) ?
                                              reset_synchronizer_shift_register[i-1] :
                                              ~i_rst_n;  // Invert: active-low input to active-high
  always_ff @(posedge i_clk)
    reset_synchronized <= reset_synchronizer_shift_register[NumResetSyncStages-1];

  // Asynchronous assertion drops bridge VALIDs even if i_clk stops.
  // Release is synchronized to i_clk.
  (* ASYNC_REG = "TRUE" *)
  logic [NumResetSyncStages-1:0] ddr_axi_reset_synchronizer_n;
  always_ff @(posedge i_clk or negedge i_ddr_axi_rst_n)
    if (!i_ddr_axi_rst_n) ddr_axi_reset_synchronizer_n <= '0;
    else
      ddr_axi_reset_synchronizer_n <= {ddr_axi_reset_synchronizer_n[NumResetSyncStages-2:0], 1'b1};
  logic ddr_axi_reset;
  assign ddr_axi_reset = !ddr_axi_reset_synchronizer_n[NumResetSyncStages-1];

  // Reset synchronization for divided clock domain (JTAG/UART clock)
  (* ASYNC_REG = "TRUE" *)
  logic [NumResetSyncStages-1:0] reset_div4_synchronizer_shift_register;
  logic reset_div4_synchronized;
  always_ff @(posedge i_clk_div4)
    for (int i = 0; i < NumResetSyncStages; ++i)
      reset_div4_synchronizer_shift_register[i] <= (i > 0) ?
                                                   reset_div4_synchronizer_shift_register[i-1] :
                                                   ~i_rst_n;
  assign reset_div4_synchronized = reset_div4_synchronizer_shift_register[NumResetSyncStages-1];

  // UART TX: cpu_and_mem's registered UART write feeds the transmit FIFO
  // directly, and the transmit status it reads comes back from that FIFO and
  // the transmitter (see the FIFO below).
  logic        uart_write_enable_from_cpu;
  logic [ 7:0] uart_write_data_from_cpu;
  logic [ 7:0] uart_fifo_data;
  logic        uart_fifo_valid;
  logic        uart_fifo_ready;
  logic        uart_fifo_input_ready;
  logic        uart_fifo_almost_full;
  logic        uart_fifo_empty;
  logic        uart_tx_empty;

  // UART RX interface signals - received data from UART to CPU
  logic        uart_rx_data_valid_to_cpu;
  logic [ 7:0] uart_rx_data_to_cpu;
  logic        uart_rx_data_ready_from_cpu;

  // Memory-mapped I/O FIFO interface signals for CPU peripheral communication
  logic        mmio_fifo0_write_enable;
  logic [31:0] mmio_fifo0_write_data;
  logic [31:0] mmio_fifo0_read_data;
  logic        mmio_fifo0_is_empty;
  logic        mmio_fifo0_is_full;
  logic        mmio_fifo0_read_enable;

  logic        mmio_fifo1_write_enable;
  logic [31:0] mmio_fifo1_write_data;
  logic [31:0] mmio_fifo1_read_data;
  logic        mmio_fifo1_is_empty;
  logic        mmio_fifo1_is_full;
  logic        mmio_fifo1_read_enable;

  // The programming port stays in the div4 domain through this connection.
  cpu_and_mem #(
      .MEM_SIZE_BYTES(MEM_SIZE_BYTES),
      .SIM_TIMER_SPEEDUP(SIM_TIMER_SPEEDUP),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .L1_CACHE_BYTES(L1_CACHE_BYTES),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .L2_CACHE_BYTES(L2_CACHE_BYTES),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
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
      .PERF_COUNTERS(PERF_COUNTERS),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .DECODED_QUEUE_DEPTH(DECODED_QUEUE_DEPTH),
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .RAW_LOOPBACK(RAW_LOOPBACK)
  ) cpu_and_memory_subsystem (
      .i_clk,
      .i_clk_div4,
      .i_rst(reset_synchronized),
      .i_ddr_axi_rst(ddr_axi_reset),
      .o_ddr_axi_awvalid,
      .i_ddr_axi_awready,
      .o_ddr_axi_awid,
      .o_ddr_axi_awaddr,
      .o_ddr_axi_awlen,
      .o_ddr_axi_awsize,
      .o_ddr_axi_awburst,
      .o_ddr_axi_wvalid,
      .i_ddr_axi_wready,
      .o_ddr_axi_wdata,
      .o_ddr_axi_wstrb,
      .o_ddr_axi_wlast,
      .i_ddr_axi_bvalid,
      .o_ddr_axi_bready,
      .i_ddr_axi_bid,
      .i_ddr_axi_bresp,
      .o_ddr_axi_arvalid,
      .i_ddr_axi_arready,
      .o_ddr_axi_arid,
      .o_ddr_axi_araddr,
      .o_ddr_axi_arlen,
      .o_ddr_axi_arsize,
      .o_ddr_axi_arburst,
      .i_ddr_axi_rvalid,
      .o_ddr_axi_rready,
      .i_ddr_axi_rid,
      .i_ddr_axi_rdata,
      .i_ddr_axi_rresp,
      .i_ddr_axi_rlast,
      .i_instr_mem_en(i_instr_mem_en),
      .i_instr_mem_we(i_instr_mem_we),
      .i_instr_mem_addr(i_instr_mem_addr),
      .i_instr_mem_wrdata(i_instr_mem_wrdata),
      .o_uart_wr_en(uart_write_enable_from_cpu),
      .o_uart_wr_data(uart_write_data_from_cpu),
      .i_uart_tx_ready(!uart_fifo_almost_full),
      .i_uart_tx_empty(uart_tx_empty),
      // UART RX interface
      .i_uart_rx_data(uart_rx_data_to_cpu),
      .i_uart_rx_valid(uart_rx_data_valid_to_cpu),
      .o_uart_rx_ready(uart_rx_data_ready_from_cpu),
      // MMIO FIFO 0 interface
      .o_fifo0_wr_en(mmio_fifo0_write_enable),
      .o_fifo0_wr_data(mmio_fifo0_write_data),
      .i_fifo0_rd_data(mmio_fifo0_read_data),
      .i_fifo0_empty(mmio_fifo0_is_empty),
      .o_fifo0_rd_en(mmio_fifo0_read_enable),
      // MMIO FIFO 1 interface
      .o_fifo1_wr_en(mmio_fifo1_write_enable),
      .o_fifo1_wr_data(mmio_fifo1_write_data),
      .i_fifo1_rd_data(mmio_fifo1_read_data),
      .i_fifo1_empty(mmio_fifo1_is_empty),
      .o_fifo1_rd_en(mmio_fifo1_read_enable),
      // External interrupt (PLIC source 2)
      .i_external_interrupt(i_external_interrupt),
      // Debug transport
      .i_jtag_tck,
      .i_jtag_tms,
      .i_jtag_tdi,
      .i_jtag_trst_n,
      .o_jtag_tdo,
      .i_dtm_bscan_tck,
      .i_dtm_bscan_tdi,
      .i_dtm_bscan_tlr,
      .i_dtm_bscan_capture,
      .i_dtm_bscan_shift,
      .i_dtm_bscan_update,
      .i_dtm_bscan_sel_dtmcs,
      .i_dtm_bscan_sel_dmi,
      .o_dtm_bscan_tdo_dtmcs,
      .o_dtm_bscan_tdo_dmi,
      // NIC
      .i_nic_tx_clk,
      .i_nic_rx_clk,
      .i_nic_tx_clk_ok,
      .i_nic_rx_clk_ok,
      .o_nic_tx_raw_data,
      .o_nic_tx_raw_valid,
      .i_nic_rx_raw_data,
      .i_nic_rx_raw_valid,
      .i_nic_rx_signal_ok,
      .i_nic_phy_status,
      .o_nic_phy_ctrl,
      .o_nic_rx_block_lock
  );

  // Memory-mapped I/O FIFO 0 - used for general-purpose data buffering
  sync_dist_ram_fifo #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(9)    // 512 entries deep
  ) memory_mapped_io_fifo_0 (
      .i_clk,
      .i_rst(reset_synchronized),
      // Software must avoid overflow; the full flag is not exposed.
      .i_write_enable(mmio_fifo0_write_enable),
      .i_read_enable(mmio_fifo0_read_enable),
      .i_write_data(mmio_fifo0_write_data),
      .o_read_data(mmio_fifo0_read_data),
      .o_empty(mmio_fifo0_is_empty),
      .o_full(mmio_fifo0_is_full)
  );

  // Memory-mapped I/O FIFO 1 - used for general-purpose data buffering
  sync_dist_ram_fifo #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(9)    // 512 entries deep
  ) memory_mapped_io_fifo_1 (
      .i_clk,
      .i_rst(reset_synchronized),
      // Software must avoid overflow; the full flag is not exposed.
      .i_write_enable(mmio_fifo1_write_enable),
      .i_read_enable(mmio_fifo1_read_enable),
      .i_write_data(mmio_fifo1_write_data),
      .o_read_data(mmio_fifo1_read_data),
      .o_empty(mmio_fifo1_is_empty),
      .o_full(mmio_fifo1_is_full)
  );

  /*
    Dual-clock FIFO carrying UART data from the CPU domain to the clk_div4 UART
    domain. It buffers console output so the CPU runs ahead while the
    transmitter drains the FIFO at the baud rate. A write is refused only when
    the FIFO has no room. Software paces itself with the TX status
    (UART_TX_STATUS, the ns16550 LSR THRE bit and THRE interrupt), which is
    the FIFO's almost-full level: it drops while fewer than 64 more bytes
    fit, so a 16550 driver's 16-byte burst per THRE, plus the writes still on
    their way, always fits.
  */
  dc_fifo #(
      .DATA_WIDTH(8),  // 8 bits per UART character
      .DEPTH(16384),
      .ALMOST_FULL_MARGIN(64)
  ) uart_transmit_clock_domain_crossing_fifo (
      .o_clk(i_clk_div4),  // Output: UART clock domain (slow)
      .i_clk(i_clk),  // Input: CPU clock domain (fast)
      .o_rst(reset_div4_synchronized),
      .i_rst(reset_synchronized),
      .i_data(uart_write_data_from_cpu),
      .i_valid(uart_write_enable_from_cpu),
      .o_ready(uart_fifo_input_ready),
      .o_almost_full(uart_fifo_almost_full),
      .o_empty(uart_fifo_empty),
      .o_data(uart_fifo_data),
      .o_valid(uart_fifo_valid),
      .i_ready(uart_fifo_ready)
  );

`ifndef SYNTHESIS
  // Report lost TX bytes. +uart_tx_drop_check=0 disables this for unpaced
  // output captured before the FIFO, such as arch-test signature dumps.
  int unsigned uart_tx_drop_check;
  initial if (!$value$plusargs("uart_tx_drop_check=%d", uart_tx_drop_check)) uart_tx_drop_check = 1;
  always_ff @(posedge i_clk)
    if (uart_tx_drop_check != 0 && !reset_synchronized && uart_write_enable_from_cpu &&
        !uart_fifo_input_ready)
      $error("frost: UART TX byte dropped: the transmit FIFO was full");
`endif

  // UART transmitter - converts valid/ready handshake to serial UART protocol
  uart_tx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ / 4),  // UART runs on divided clock
      .BAUD_RATE(115200)  // Standard baud rate for console communication
  ) uart_transmitter (
      .i_clk  (i_clk_div4),
      .i_rst  (reset_div4_synchronized),
      .i_data (uart_fifo_data),
      .i_valid(uart_fifo_valid),
      .o_ready(uart_fifo_ready),
      .o_uart (o_uart_tx)
  );

  /*
    Transmitter empty (the ns16550 LSR TEMT bit): no byte is in the FIFO, is
    entering it this cycle, waits in its output register, or is being shifted
    out. A THR write is already in cpu_and_mem's o_uart_wr_en, or past it,
    when a later LSR read is performed, because a device load waits for every
    committed store to drain plus an arming cycle (data_mem_request_router).
    (While hang_triage owns the console, cpu_and_mem drops CPU writes, so
    TEMT never sees them.) The transmitter's idle level crosses into i_clk
    through two stages, like the FIFO's read pointer, so both views come from
    the same clk_div4 edge.
  */
  logic       uart_tx_idle_div4;
  logic [1:0] uart_tx_idle_sync;
  assign uart_tx_idle_div4 = uart_fifo_ready && !uart_fifo_valid;
  always_ff @(posedge i_clk) uart_tx_idle_sync <= {uart_tx_idle_sync[0], uart_tx_idle_div4};
  assign uart_tx_empty = uart_fifo_empty && !uart_write_enable_from_cpu && uart_tx_idle_sync[1];

  /*
    UART RX subsystem. uart_rx runs in the clk_div4 domain like TX, so both
    derive the same baud rate. A dual-clock FIFO carries received bytes into
    the CPU domain, where MMIO reads collect them.
  */

  logic [7:0] uart_rx_data_from_receiver;
  logic       uart_rx_valid_from_receiver;
  logic       uart_rx_ready_to_receiver;

  // UART receiver - converts serial UART protocol to valid/ready handshake
  uart_rx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ / 4),  // UART runs on divided clock
      .BAUD_RATE(115200)  // Standard baud rate for console communication
  ) uart_receiver (
      .i_clk  (i_clk_div4),
      .i_rst  (reset_div4_synchronized),
      .i_uart (i_uart_rx),
      .o_data (uart_rx_data_from_receiver),
      .o_valid(uart_rx_valid_from_receiver),
      .i_ready(uart_rx_ready_to_receiver)
  );

  /*
    Buffer received bytes across the UART-to-CPU clock boundary.
  */
  dc_fifo #(
      .DATA_WIDTH(8)  // 8 bits per UART character
  ) uart_receive_clock_domain_crossing_fifo (
      .i_clk(i_clk_div4),  // Input: UART clock domain (slow)
      .o_clk(i_clk),  // Output: CPU clock domain (fast)
      .i_rst(reset_div4_synchronized),
      .o_rst(reset_synchronized),
      .i_data(uart_rx_data_from_receiver),
      .i_valid(uart_rx_valid_from_receiver),
      .o_ready(uart_rx_ready_to_receiver),
      .o_almost_full(),
      .o_empty(),
      .o_data(uart_rx_data_to_cpu),
      .o_valid(uart_rx_data_valid_to_cpu),
      .i_ready(uart_rx_data_ready_from_cpu)
  );

endmodule : frost
