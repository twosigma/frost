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
  FROST system top level: CPU, dual-port memory, UART, MMIO FIFOs, and the
  RISC-V debug module's JTAG transport (Phase 3 M3: i_jtag_* for the generic
  TAP, or the BSCAN bundle when DEBUG_JTAG_TAP=0). i_clk runs the CPU and
  runtime memory ports; i_clk_div4 runs JTAG image loading,
  programming, and UART. The related clocks permit binary-pointer dual-clock
  FIFOs. RTL is portable unless FROST_XILINX_PRIMS selects explicit primitives
  in cpu_and_mem's MMIO capture, data_mem_request_router, load_queue, and
  sdp_ram_byte_en; Yosys and Verilator use the portable implementations.
*/
module frost #(
    parameter int unsigned CLK_FREQ_HZ = 300000000,
    // Low-memory size; override in simulation with Verilator -G.
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 18,
    // Simulation mtime multiplier; use 1 for synthesis.
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    // Cached memory tier: the high-address region [CACHED_BASE,
    // CACHED_BASE+CACHED_SIZE_BYTES) is served by a write-back cache hierarchy
    // (L1 BRAM on both boards; +L2 URAM on X3) over main memory. Low-BRAM data
    // stays 1-cycle; instruction windows wholly in the pinned 16 KiB metadata
    // overlay do too, while later code windows repeat once. Every MMIO handoff
    // adds one mandatory router stage,
    // may then wait for committed-store drain, and returns one cycle after
    // terminal accept. Cached accesses complete by handshake (variable
    // latency): several tagged loads in flight at the LQ, one store at the SQ.
    // Software sees one flat 1 GiB region; the hierarchy shape is opaque.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000,  // 1 GiB
    // 0 disables the tier (cached-region accesses complete with zero data);
    // only the default is 0. Both current boards pass 1 against a real DDR
    // controller (via boards/xilinx_frost_subsystem.sv; see
    // boards/x3/x3_frost.sv and boards/genesys2/genesys2_frost.sv), and
    // simulation enables it via -G (see tests/Makefile).
    parameter int unsigned ENABLE_CACHED_TIER = 0,
    // 1 splices the URAM L2 between L1 and main memory (X3 shape); 0 is the
    // L1-only shape (Genesys2 -- Kintex-7 has no UltraRAM).
    parameter int unsigned CACHED_HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Simulation-only fast cache maintenance for fence.i: 0 = FPGA (cycle-
    // accurate maintenance FSM, unchanged); non-zero = sim fast path (see
    // frost_cache). Set to 1 only by the cocotb sim build, never for boards.
    parameter int unsigned SIM_FAST_MAINT = 0,
    // Behavioral main-memory model knobs (simulation only).
    parameter int unsigned DDR_MODEL_BYTES = 64 * 1024 * 1024,
    parameter int unsigned DDR_MODEL_LATENCY = 30,
    // Per-transaction jitter on the model's latency (0 = off, cycle-exact).
    // Enable in directed/random sims (-G override) to expose completion-
    // timing races that a fixed latency structurally hides.
    parameter int unsigned DDR_MODEL_LATENCY_JITTER = 0,
    // Out-of-order completion across ids in the model (0 = in order).
    parameter int unsigned DDR_MODEL_REORDER = 0,
    // 1 = the cached tier ends in the simulation-only behavioral DDR model;
    // 0 = it ends at the o_ddr_axi_*/i_ddr_axi_* ports (hardware boards wire
    // them to their DDR controller subsystem).
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // Simulation-only fetch-latency fuzz (see cpu_and_mem). Hardware keeps 0.
    parameter int unsigned FETCH_VALID_FUZZ = 0,
    // LFSR reset value for the fuzz gap pattern: each seed explores a
    // different fetch-timing interleaving (must be nonzero).
    parameter int unsigned FETCH_VALID_FUZZ_SEED = 32'h0000_ACE1,
    // Optional on-silicon boot-hang classifier that can emit over UART.
    parameter int unsigned ENABLE_HANG_TRIAGE = 0,
    // Triage pacing (see cpu_and_mem): silicon-scale defaults; sim runs
    // override these to fit the cycle budget.
    parameter int unsigned HANG_TRIAGE_QUIET_CYCLES = 32'd400_000_000,
    parameter int unsigned HANG_TRIAGE_REEMIT_CYCLES = 32'd134_000_000,
    // RISC-V debug transport (Phase 3 M3): 1 = generic JTAG TAP on the
    // i_jtag_* pins (simulation, portable synthesis); 0 = the DTM's BSCAN
    // bundle comes from the board's BSCANE2 primitives (i_dtm_bscan_*).
    parameter int unsigned DEBUG_JTAG_TAP = 1
) (
    input logic i_clk,
    input logic i_clk_div4,
    input logic i_rst_n,

    input  logic        i_instr_mem_en,
    input  logic [ 3:0] i_instr_mem_we,
    input  logic [31:0] i_instr_mem_addr,
    input  logic [31:0] i_instr_mem_wrdata,
    output logic [31:0] o_instr_mem_rddata,

    output logic o_uart_tx,
    input  logic i_uart_rx,

    // External interrupt input (directly triggers MEIP when high)
    // Optional: tie to 0 if not used
    input logic i_external_interrupt = 1'b0,

    // RISC-V debug transport pins (Phase 3 M3, see DEBUG_JTAG_TAP). Boards
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

    // DDR AXI master (cache-hierarchy bridge; single-beat 256-bit bursts,
    // REGION-RELATIVE addresses). Quiescent when USE_BEHAVIORAL_DDR=1 or the
    // cached tier is disabled; hardware boards wire it to the DDR controller.
    output logic         o_ddr_axi_awvalid,
    input  logic         i_ddr_axi_awready,
    output logic [  3:0] o_ddr_axi_awid,
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
    input  logic [  3:0] i_ddr_axi_bid,
    input  logic [  1:0] i_ddr_axi_bresp,
    output logic         o_ddr_axi_arvalid,
    input  logic         i_ddr_axi_arready,
    output logic [  3:0] o_ddr_axi_arid,
    output logic [ 31:0] o_ddr_axi_araddr,
    output logic [  7:0] o_ddr_axi_arlen,
    output logic [  2:0] o_ddr_axi_arsize,
    output logic [  1:0] o_ddr_axi_arburst,
    input  logic         i_ddr_axi_rvalid,
    output logic         o_ddr_axi_rready,
    input  logic [  3:0] i_ddr_axi_rid,
    input  logic [255:0] i_ddr_axi_rdata,
    input  logic [  1:0] i_ddr_axi_rresp,
    input  logic         i_ddr_axi_rlast
);

  /*
    Reset synchronization chain for main clock domain.
    Converts asynchronous reset input (active-low) to synchronous reset (active-high).
    Uses multiple flip-flop stages to safely cross from async reset to sync domain.
    Potential TODO: have reset asserted async but deasserted sync for faster reset entry
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

  /*
    UART write delay chain - adds pipeline stages to relax timing constraints.
    This intentionally trades latency for better placement/routing since UART is not timing-critical.
    The delay allows the synthesizer to place logic further apart, improving timing closure.
  */
  logic       uart_write_enable_from_cpu;
  logic [7:0] uart_write_data_from_cpu;
  localparam int unsigned NumUartDelayStages = 10;
  // Use SRL primitives for area-efficient delay chain (UART is not timing-critical)
  (* srl_style = "srl" *)logic [NumUartDelayStages-1:0]      uart_write_enable_delay_chain;
  (* srl_style = "srl" *)logic [NumUartDelayStages-1:0][7:0] uart_write_data_delay_chain;
  always_ff @(posedge i_clk)
    for (int stage = 0; stage < NumUartDelayStages; ++stage) begin
      uart_write_enable_delay_chain[stage] <= (stage > 0) ?
                                              uart_write_enable_delay_chain[stage-1] :
                                              uart_write_enable_from_cpu;
      uart_write_data_delay_chain[stage] <= (stage > 0) ?
                                            uart_write_data_delay_chain[stage-1] :
                                            uart_write_data_from_cpu;
    end

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

  // CPU and memory subsystem - contains processor core and dual instruction/data RAMs
  // Instruction memory programming interface is directly on div4 clock domain (no CDC needed)
  cpu_and_mem #(
      .MEM_SIZE_BYTES(MEM_SIZE_BYTES),
      .SIM_TIMER_SPEEDUP(SIM_TIMER_SPEEDUP),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .CACHED_HAS_L2(CACHED_HAS_L2),
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
      .DEBUG_JTAG_TAP(DEBUG_JTAG_TAP)
  ) cpu_and_memory_subsystem (
      .i_clk,
      .i_clk_div4,
      .i_rst(reset_synchronized),
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
      .o_instr_mem_rddata,
      .o_uart_wr_en(uart_write_enable_from_cpu),
      .o_uart_wr_data(uart_write_data_from_cpu),
      .i_uart_tx_ready(uart_fifo_input_ready),
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
      // External interrupt (directly triggers machine external interrupt)
      .i_external_interrupt(i_external_interrupt),
      // Debug transport (Phase 3 M3)
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
      .o_dtm_bscan_tdo_dmi
  );

  // Memory-mapped I/O FIFO 0 - used for general-purpose data buffering
  sync_dist_ram_fifo #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(9)    // 512 entries deep
  ) memory_mapped_io_fifo_0 (
      .i_clk,
      .i_rst(reset_synchronized),
      // Purposely ignore full signal for better timing (assume software manages overflow)
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
      // Purposely ignore full signal for better timing (assume software manages overflow)
      .i_write_enable(mmio_fifo1_write_enable),
      .i_read_enable(mmio_fifo1_read_enable),
      .i_write_data(mmio_fifo1_write_data),
      .o_read_data(mmio_fifo1_read_data),
      .o_empty(mmio_fifo1_is_empty),
      .o_full(mmio_fifo1_is_full)
  );

  // Interface signals for UART transmitter module
  logic [7:0] uart_fifo_data;
  logic       uart_fifo_valid;
  logic       uart_fifo_ready;
  logic       uart_fifo_input_ready;

  /*
    Dual-clock FIFO for UART data - crosses from CPU clock domain to UART clock domain (clk_div4)
    Buffers print data from CPU before transmission over slower UART serial interface.
    This enables the fast CPU to continue execution while UART sends data at baud rate.
  */
  dc_fifo #(
      .DATA_WIDTH(8),  // 8 bits per UART character
      .DEPTH(16384),
      .READY_MARGIN(64)
  ) uart_transmit_clock_domain_crossing_fifo (
      .o_clk(i_clk_div4),  // Output: UART clock domain (slow)
      .i_clk(i_clk),  // Input: CPU clock domain (fast)
      .o_rst(reset_div4_synchronized),
      .i_rst(reset_synchronized),
      .i_data(uart_write_data_delay_chain[NumUartDelayStages-1]),
      .i_valid(uart_write_enable_delay_chain[NumUartDelayStages-1]),
      .o_ready(uart_fifo_input_ready),
      .o_data(uart_fifo_data),
      .o_valid(uart_fifo_valid),
      .i_ready(uart_fifo_ready)
  );

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
    UART RX subsystem - receives serial data and crosses to CPU clock domain.
    The uart_rx module runs in the clk_div4 domain (same as TX for consistent baud rate).
    A dual-clock FIFO transfers received bytes to the CPU clock domain for MMIO reads.
  */

  // Interface signals for UART receiver module
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
    Dual-clock FIFO for UART RX data - crosses from UART clock domain to CPU clock domain.
    Buffers received data from slow UART serial interface before CPU reads it via MMIO.
    This allows the UART to continue receiving while CPU processes previous data.
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
      .o_data(uart_rx_data_to_cpu),
      .o_valid(uart_rx_data_valid_to_cpu),
      .i_ready(uart_rx_data_ready_from_cpu)
  );

endmodule : frost
