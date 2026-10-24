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
  CPU, memory, debug, and peripheral integration. Low-BRAM programming uses
  port A on i_clk_div4; runtime fetch and data access use port B on i_clk.
  The cached tier connects to DDR through the cache hierarchy and AXI bridge.
*/
// Simulation-only TestRIG platform. The instruction stream is injected by
// retirement position, so this fixture intentionally retains the pipeline's
// fixed-latency test interface. Device accesses use shadow RAM and the
// NIC and DMA engine AXI4-Lite ports are idle. Production builds use platform_top;
// cpu_top's public AXI protocol is checked by the standalone integration bench.
module frost_rvfi_platform #(
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 17,
    // Simulation mtime multiplier; use 1 for synthesis.
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    // Cached address range; requests complete with variable latency.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit EARLY_LOAD_WAKEUP = riscv_pkg::EarlyLoadWakeup,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter int unsigned INT_RS_DEPTH = riscv_pkg::IntRsDepth,
    parameter int unsigned DECODED_QUEUE_DEPTH = riscv_pkg::DecodedQueueDepth,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Ways per set of the L1D, L1I, and L2 (see frost_hart_cache and
    // frost_cluster_cache).
    parameter int unsigned L1D_WAYS = 4,
    parameter int unsigned L1I_WAYS = 4,
    parameter int unsigned L2_WAYS = 4,
    // L1D miss-status slots, and L2 miss-status and writeback slots (see
    // frost_hart_cache and frost_cluster_cache).
    parameter int unsigned L1D_NUM_MSHR = 8,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    // Read waiter seats per L2 miss slot (see frost_cluster_cache). A
    // stream prefetch holds its slot's primary seat, so the L1D's reads of
    // both halves of the line need two.
    parameter int unsigned L2_NUM_WAITERS = 2,
    // The L2 stream prefetcher (see frost_cluster_cache): 0 turns it off.
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
    // Simulation only: add LFSR-gated gaps to low-BRAM fetch responses.
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
    parameter int unsigned POWER_ON_RESET_ENABLE = 1,
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
    input logic i_power_on_rst,

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

  // Registered core reset combines external reset and ndmreset, for fanout.
  // Debug logic uses external reset alone so it survives debugger-requested
  // resets. Cache tags are swept on core reset.
  logic dbg_ndmreset;
  // The NIC registers the same next value to keep its local reset in step.
  logic rst_core_next;
  assign rst_core_next = i_rst || dbg_ndmreset;
  // Limit reset fanout per replica.
  (* max_fanout = 256 *) logic rst_core;
  always_ff @(posedge i_clk) rst_core <= rst_core_next;

  // Memory addressing parameters
  localparam int unsigned MemByteAddrWidth = $clog2(MEM_SIZE_BYTES);
  // Each instruction word holds four bytes.
  localparam int unsigned MemWordAddrWidth = MemByteAddrWidth - 2;
  // The instruction copy holds only the low BRAM's code region, the part
  // instruction fetch can reach (riscv_pkg::pma_fetch_ok): 128 KiB, or all of
  // a smaller low BRAM.
  localparam int unsigned ImemByteAddrWidth =
      (MemByteAddrWidth < riscv_pkg::LowBramCodeAddrBits) ?
      MemByteAddrWidth : riscv_pkg::LowBramCodeAddrBits;
  localparam int unsigned ImemWordAddrWidth = ImemByteAddrWidth - 2;
  // Data-memory rows are MemDataBits dwords (hw/rtl/README.md, "Data-tier bus contract").
  localparam int unsigned MemDwordAddrWidth = MemByteAddrWidth - 3;

  // Memory-mapped I/O addresses for peripherals. Keep them in step with every
  // copy listed in hw/rtl/README.md, "Memory Map". The request router derives
  // the UART RX and FIFO addresses as fixed offsets from the MMIO_ADDR
  // parameter passed to cpu_ooo.
  localparam int unsigned MmioAddr = 32'h4000_0000;
  // ns16550 @ +0x1000, CLINT @ +0x10000, DMA test engine @ +0x20000, NIC @
  // +0x30000 (a 4 KiB window).
  localparam int unsigned MmioSizeBytes = 32'h3_1000;
  localparam int unsigned UartMmioAddr = 32'h4000_0000;  // UART TX (write-only)
  localparam int unsigned UartRxDataMmioAddr = 32'h4000_0004;  // UART RX data (read consumes byte)
  localparam int unsigned UartRxStatusMmioAddr = 32'h4000_0024;  // RX status (bit0: data available)
  localparam int unsigned UartTxStatusMmioAddr = 32'h4000_0028;  // TX status (bit0: TX ready)
  localparam int unsigned Fifo0MmioAddr = 32'h4000_0008;
  localparam int unsigned Fifo1MmioAddr = 32'h4000_000C;
  localparam logic [riscv_pkg::PhysAddrBits-1:0] Fifo0PhysAddr =
      riscv_pkg::PhysAddrBits'(Fifo0MmioAddr);
  localparam logic [riscv_pkg::PhysAddrBits-1:0] Fifo1PhysAddr =
      riscv_pkg::PhysAddrBits'(Fifo1MmioAddr);
  // Timer registers (CLINT-compatible layout)
  localparam int unsigned MtimeLowMmioAddr = 32'h4000_0010;  // mtime[31:0]
  localparam int unsigned MtimeHighMmioAddr = 32'h4000_0014;  // mtime[63:32]
  localparam int unsigned MtimecmpLowMmioAddr = 32'h4000_0018;  // mtimecmp[31:0]
  localparam int unsigned MtimecmpHighMmioAddr = 32'h4000_001C;  // mtimecmp[63:32]
  // Software interrupt register
  localparam int unsigned MsipMmioAddr = 32'h4000_0020;

  // ns16550a UART face for Linux (word-stride; DTB reg-shift=2, reg-io-width=4).
  // Aliases the native UART TX/RX. DLAB (LCR[7]) remaps offsets 0/4 to DLL/DLM.
  localparam int unsigned Ns16550ThrRbr = 32'h4000_1000;  // THR(w)/RBR(r) | DLL when DLAB
  localparam int unsigned Ns16550IerDlm = 32'h4000_1004;  // IER | DLM when DLAB
  localparam int unsigned Ns16550IirFcr = 32'h4000_1008;  // IIR(r) / FCR(w)
  localparam int unsigned Ns16550Lcr = 32'h4000_100C;
  localparam int unsigned Ns16550Mcr = 32'h4000_1010;
  localparam int unsigned Ns16550Lsr = 32'h4000_1014;  // read-only line status
  localparam int unsigned Ns16550Msr = 32'h4000_1018;  // read-only modem status
  localparam int unsigned Ns16550Scr = 32'h4000_101C;  // scratch

  // SiFive CLINT alias for Linux (compatible "sifive,clint0") @ 0x4001_0000.
  // These alias the native FROST timer block's msip/mtimecmp/mtime registers;
  // the kernel reaches the timer through the CLINT layout via the DTB.
  localparam int unsigned ClintMsip = 32'h4001_0000;  // hart-0 software interrupt
  localparam int unsigned ClintMtimecmpLo = 32'h4001_4000;  // mtimecmp[31:0]
  localparam int unsigned ClintMtimecmpHi = 32'h4001_4004;  // mtimecmp[63:32]
  localparam int unsigned ClintMtimeLo = 32'h4001_BFF8;  // mtime[31:0]
  localparam int unsigned ClintMtimeHi = 32'h4001_BFFC;  // mtime[63:32]

  // DMA test engine @ 0x4002_0000, a 256-byte window of
  // 32-bit registers (dma_test_engine.sv). It reaches the cache hierarchy's
  // coherent DMA port through the line-port arbiter it shares with the NIC;
  // its completion interrupt is APLIC source 3.
  localparam int unsigned DmaEngineBase = 32'h4002_0000;
  // NIC @ 0x4003_0000, a 4 KiB window of 32-bit registers
  // (hw/rtl/peripherals/nic/nic_pkg.sv). It shares the coherent DMA port with
  // the test engine through a line-port arbiter; its interrupt is APLIC
  // source 4.
  localparam int unsigned NicBase = 32'h4003_0000;
  // Memory error unit @ 0x4002_1000, a 256-byte window of 32-bit registers
  // (memory_error_unit.sv): counts of DDR ECC errors and of the DDR bridge's
  // AXI error responses; its interrupt is APLIC source 5.
  localparam int unsigned MemErrBase = 32'h4002_1000;

  // mtimecmp resets to all-ones so no timer interrupt fires until software
  // programs it.
  localparam logic [63:0] MtimecmpDefault = 64'hFFFF_FFFF_FFFF_FFFF;

  // APLIC @ 0x4400_0000, a 4 MiB device-quadrant window
  // (addr[31:22] == 10'h110) of 32-bit registers. Sources: 1 = ns16550 irq,
  // 2 = i_external_interrupt, 3 = the DMA test engine's completion, 4 = the
  // NIC, 5 = the memory error unit. The machine domain is at +0x0000,
  // the supervisor domain at +0x8000, with one IDC per domain for hart 0.
  // A 32-bit claimi read consumes its interrupt on mmio_read_capture.
  localparam logic [9:0] AplicWindowSel = 10'h110;

  // The data PMA accepts device accesses only in riscv_pkg's device-window
  // pages, so they must be exactly the MMIO and APLIC windows decoded here: a
  // page only the PMA had would reach no register, and one it lacked would
  // fault. The pages must also keep the layout their decodes assume: both
  // windows inside the device quadrant, which the load and store queues order
  // as devices; the MMIO window inside one aligned 64-page block
  // (riscv_pkg::pma_device_page_ok); and each window nonempty with an
  // unmapped page on both sides (the store-issue page split in
  // tomasulo_wrapper).
  initial begin
    if ((MmioAddr != {riscv_pkg::MmioFirstPage, 12'h000}) ||
        ((MmioAddr + MmioSizeBytes) != {riscv_pkg::MmioLastPage + 20'd1, 12'h000}) ||
        ({AplicWindowSel, 22'h00_0000} != {riscv_pkg::AplicFirstPage, 12'h000}) ||
        ({AplicWindowSel, 22'h3F_FFFF} != {riscv_pkg::AplicLastPage, 12'hFFF}))
      $fatal(1, "cpu_and_mem: MMIO or APLIC window differs from the riscv_pkg device-window pages");
    if ((riscv_pkg::MmioFirstPage[19:18] != 2'b01) || (riscv_pkg::AplicFirstPage[19:18] != 2'b01) ||
        (riscv_pkg::MmioLastPage[19:6] != riscv_pkg::MmioFirstPage[19:6]) ||
        (riscv_pkg::MmioFirstPage > riscv_pkg::MmioLastPage) ||
        (riscv_pkg::MmioLastPage == 20'h7_FFFF) || (riscv_pkg::AplicLastPage == 20'h7_FFFF) ||
        ((riscv_pkg::MmioLastPage + 20'd1 >= riscv_pkg::AplicFirstPage) &&
         (riscv_pkg::AplicLastPage + 20'd1 >= riscv_pkg::MmioFirstPage)))
      $fatal(1, "cpu_and_mem: riscv_pkg device-window pages break the layout their decodes assume");
  end

  // CPU interface signals
  logic [riscv_pkg::XLEN-1:0] program_counter;
  logic commit_vld;  // instruction-retire pulse (hang-triage tap)
  // CPU-side UART write, muxed against the hang-triage byte stream further down.
  logic cpu_uart_wr_en;
  logic [7:0] cpu_uart_wr_data;
  logic [31:0] fetch_address;  // Low BRAM's physical address pins.
  logic [riscv_pkg::XLEN-1:0] fetch_request_pc;  // Full response identity.
  logic [63:0] instruction;  // 64-bit fetch: {next_word, current_word}
  // instruction's sources kept apart for IF's current-word and spanning-half
  // selects: the low BRAM's words in physical bank order ({odd, even}), the
  // cached provider's {next, current} window, and the instruction mux's
  // provider select (1: the cached window).
  logic [63:0] bram_fetch_instr_by_parity;
  logic [63:0] instruction_high;
  logic instruction_window_high;
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] instruction_sideband;
  // Dedicated PC-metadata copy for the IF PC-advance selector. Each word is
  // {pairable_native_hi, pairable_compressed_hi, compressed_hi, compressed_lo}.
  logic [7:0] instruction_pc_metadata;
  logic instruction_bank_sel_r;  // Fetch-word parity (for spanning select)
  logic instruction_valid;  // Fetch window valid
  // Provider-local served-window word tags. IF compares both providers in
  // parallel and selects only the one-bit coverage results.
  logic [riscv_pkg::XLEN-3:0] instruction_served_word_low, instruction_served_last_word_low;
  logic [riscv_pkg::XLEN-3:0] instruction_served_prev_word_low;
  logic instruction_served_prev_word_valid_low;
  logic [riscv_pkg::XLEN-3:0] instruction_served_word_high, instruction_served_last_word_high;
  logic [riscv_pkg::XLEN-3:0] instruction_served_prev_word_high;
  logic instruction_served_prev_word_valid_high;
  // Physical fetch results include both word addresses, validity, faults,
  // prefetch permission, and provider retarget pulses. Bare mode uses the VA
  // directly; Sv39 requires a matching resolved VA tag. Served faults and the
  // provider bit return to the core. Window tags use the virtual PC; only
  // memories use physical addresses.
  logic [riscv_pkg::PhysAddrBits-1:0] fetch_pa0, fetch_pa1;
  logic fetch_pa0_is_cached;
  assign fetch_pa0_is_cached = riscv_pkg::pma_cached_ok(riscv_pkg::XLEN'(fetch_pa0));
  logic fetch_pa_valid;
  logic fetch_fault0, fetch_fault0_page, fetch_fault1, fetch_fault1_page;
  logic fetch_line_after_ok, fetch_redirect, fetch_cached_retarget;
  logic instruction_fault0, instruction_fault0_page, instruction_fault1, instruction_fault1_page;
  logic instruction_served_high;
  logic instruction_pc_metadata_served_high;
  // The request's physical word pair (imem port B addresses) with its
  // validity and fault flags, per fetch mode.
  logic [31:0] fetch_pa_word0, fetch_pa_word1;
  logic fetch_pa_ok;
  logic fetch_word0_fault, fetch_word0_fault_page, fetch_word1_fault, fetch_word1_fault_page;
  // Low-BRAM tags (fetch_address delayed one cycle to match the 1-cycle imem
  // read latency). S+1/S-1 and predecessor validity register on the same edge,
  // as do the request's fault flags.
  logic [riscv_pkg::XLEN-3:0] bram_fetch_served_word_q;
  logic [riscv_pkg::XLEN-3:0] bram_fetch_served_last_word_q;
  logic [riscv_pkg::XLEN-3:0] bram_fetch_served_prev_word_q;
  logic bram_fetch_served_prev_word_valid_q;
  logic
      bram_fetch_fault0_q, bram_fetch_fault0_page_q, bram_fetch_fault1_q, bram_fetch_fault1_page_q;
  logic fetch_replay_consume;  // registered: the CPU consumed the stall-replay bundle last cycle
  logic fetch_live_claim;  // IF consumed/captured the provider's live response this cycle
  logic pipeline_stall;  // front-end stall; holds slow publication, not overlay bypass
  logic fence_i_sync_req;  // ROB serializer holding commit for a fence.i cache sync
  logic fence_i_sync_done;  // hierarchy finished L1D writeback-all + L1I invalidate-all
  // Registered FENCE-class pipeline flush (native FENCE.I/SFENCE.VMA or a
  // translation-class CSR); invalidates the fetch provider before refetch.
  logic fence_i_flush;

  // Low instruction BRAM window (imem_predecode port B outputs). In hardware
  // cached-tier builds, imem port B stays on the direct presenter path, not
  // behind the L1I fetch_provider, and the fetch generate below muxes these
  // registered outputs against the high DDR provider outputs.
  logic [63:0] bram_fetch_instr;
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] bram_fetch_sideband;
  logic [7:0] bram_fetch_pc_metadata;
  logic [7:0] bram_fetch_pc_metadata_by_parity;
  logic [3:0] bram_fetch_pc_pairability_by_parity;
  logic [1:0] bram_fetch_slot2_start_valid_lo_by_parity;
  logic bram_fetch_window_overlay_hit;
  logic bram_fetch_response_ready;
  // Metadata copies in physical {odd, even} order, for timing. The cached
  // provider normalizes this order when it captures the payload.
  logic [7:0] high_fetch_pc_metadata_by_parity;
  logic [3:0] high_fetch_pc_pairability_by_parity;
  logic [1:0] high_fetch_slot2_start_valid_lo_by_parity;
  logic [15:0] fetch_pc_metadata_by_provider_parity;
  logic [7:0] fetch_pc_pairability_by_provider_parity;
  logic [3:0] fetch_slot2_start_valid_lo_by_provider_parity;
  logic bram_fetch_bank_sel_r;
  (* keep = "true", max_fanout = 16 *) logic bram_fetch_bank_sel_cpu_r;

  assign fetch_pc_metadata_by_provider_parity = {
    high_fetch_pc_metadata_by_parity, bram_fetch_pc_metadata_by_parity
  };
  assign fetch_pc_pairability_by_provider_parity = {
    high_fetch_pc_pairability_by_parity, bram_fetch_pc_pairability_by_parity
  };
  assign fetch_slot2_start_valid_lo_by_provider_parity = {
    high_fetch_slot2_start_valid_lo_by_parity, bram_fetch_slot2_start_valid_lo_by_parity
  };

  // Instruction-side line port into the cache hierarchy: driven by the fetch
  // provider when the cached tier is enabled (and the fetch fuzz is off), tied
  // off otherwise.
  // Line-protocol id widths: the L1 upstream ports carry LineIdBits, and the
  // L2's downstream ids, {type, slot}, are the board's AXI ids, DdrAxiIdBits
  // wide. The L1s, the walker, fetch, and the DMA port use L1LineBytes lines.
  localparam int unsigned LineIdBits = 4;
  localparam int unsigned DdrAxiIdBits = 5;
  localparam int unsigned L1LineBytes = 32;
  // The behavioral DDR model keeps at least its default eight transactions
  // per channel in flight, and every fill or writeback the L2 can issue.
  localparam int unsigned L2MaxSlots = (L2_NUM_MSHR > L2_NUM_WB) ? L2_NUM_MSHR : L2_NUM_WB;
  localparam int unsigned DdrModelSlots = (L2MaxSlots > 8) ? L2MaxSlots : 8;

  // DMA coherence handshake between the hierarchy's sequencer and the core.
  logic coh_admit_valid, coh_admit_ready, coh_inval_valid, coh_inval_done, coh_release_valid;
  logic [riscv_pkg::DmaCoherenceLockBits-1:0] coh_admit_slot, coh_inval_slot, coh_release_slot;
  logic [riscv_pkg::PhysAddrBits-1:0] coh_admit_addr;

  logic iup_req_valid, iup_req_ready, iup_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] iup_req_addr;
  logic [L1LineBytes*8-1:0] iup_req_wdata;
  logic [L1LineBytes-1:0] iup_req_wstrb;
  logic [LineIdBits-1:0] iup_req_id;
  logic iup_resp_valid;
  logic [LineIdBits-1:0] iup_resp_id;
  logic [L1LineBytes*8-1:0] iup_resp_rdata;

  // Page-table walker line port: core-side ptw master to the
  // hierarchy's wup port, whose local ids are LineIdBits-1 bits per the id
  // tree. The walker's own ids are 2 bits, zero-extended, so responses come
  // back with the upper bits clear.
  logic walk_line_req_valid, walk_line_req_ready;
  logic [riscv_pkg::PhysAddrBits-1:0] walk_line_req_addr;
  logic [LineIdBits-2:0] walk_line_req_id;
  logic walk_line_resp_valid;
  logic [LineIdBits-2:0] walk_line_resp_id;
  logic [1:0] ptw_line_req_id;
  assign walk_line_req_id = (LineIdBits - 1)'(ptw_line_req_id);
  logic [L1LineBytes*8-1:0] walk_line_resp_rdata;
  logic [riscv_pkg::PhysAddrBits-1:0] data_memory_address;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_write_data, data_memory_write_data_registered;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_response_data;  // Complete router payload
  logic [riscv_pkg::MemDataBits-1:0] mmio_read_data_comb;
  logic [riscv_pkg::MemDataBits-1:0] mmio_read_data_reg;
  logic mmio_read_data_valid;
  logic [31:0] mmio_load_addr;
  // The router holds this size with the MMIO address until capture.
  riscv_pkg::mem_size_e mmio_load_size;
  logic mmio_load_valid;
  logic mmio_read_capture;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_read_data;  // From RAM only
  // Delayed for read-data alignment.
  logic [riscv_pkg::PhysAddrBits-1:0] data_memory_address_registered;
  logic [riscv_pkg::MemStrbBits-1:0] data_memory_byte_write_enable;
  // BRAM strobes exclude MMIO and cached writes using registered SQ and
  // AMO tier flags. They drive the BRAM WEA pins directly.
  logic [riscv_pkg::MemStrbBits-1:0] data_memory_bram_byte_write_enable;
  logic data_memory_read_enable;
  // Cached tier (high-address region). The router drives these tier-routed
  // requests (already qualified by is_cached); the cached_tier_adapter
  // completes them with handshake pulses.
  logic [riscv_pkg::MemStrbBits-1:0] data_memory_cached_byte_write_enable;
  logic data_memory_cached_read_enable;
  logic data_memory_cached_read_sel;
  logic data_memory_cached_read_if_sel;
  logic data_memory_cached_read_if_clear;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] data_memory_cached_read_id;
  logic data_memory_cached_read_no_merge;
  logic [riscv_pkg::MemDataBits-1:0] data_memory_cached_read_data;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] data_memory_cached_resp_id;
  logic data_memory_cached_read_valid;
  logic data_memory_cached_read_ready;
  logic data_memory_cached_write_done;
  logic data_memory_cached_write_inflight;
  // Source-registered cache events cross into cpu_ooo as one packed observer
  // bundle. The hierarchy supplies the per-level fields; the fetch provider
  // adds the front-end-progress qualifier for the L1I miss-stall counter.
  cache_perf_pkg::cache_hierarchy_perf_events_t cache_hierarchy_perf_events;
  cache_perf_pkg::cache_perf_events_t cache_perf_events;
  logic l1i_fetch_miss_stall;
  assign cache_perf_events.hierarchy = cache_hierarchy_perf_events;
  assign cache_perf_events.l1i_fetch_miss_stall = l1i_fetch_miss_stall;
  // Cached write data is the draining SQ store or, on an AMO launch, the
  // AMO's new value. It bypasses the BRAM write-data mux for timing.
  logic [riscv_pkg::MemDataBits-1:0] data_memory_cached_write_data;
  logic                              mmio_read_pulse;
  logic                              mmio_fifo0_read_pulse;
  logic                              mmio_fifo1_read_pulse;
  logic                              mmio_uart_rx_ready_pulse;

  // Timer registers (CLINT-style)
  logic [                      63:0] mtime;  // Machine time counter
  logic [                      63:0] mtimecmp;  // Machine timer compare register
  logic                              msip;  // Machine software interrupt pending

  // ns16550a UART face register file (8-bit). DLAB = ns_lcr[7].
  logic [7:0] ns_dll, ns_dlm, ns_ier, ns_fcr, ns_lcr, ns_mcr, ns_scr;
  logic       ns_rx_irq_pending;
  logic       ns_tx_irq_pending;
  logic       ns_irq_pending;
  logic [7:0] ns_iir;
  assign ns_rx_irq_pending = ns_ier[0] && i_uart_rx_valid;
  assign ns_tx_irq_pending = ns_ier[1] && i_uart_tx_ready;
  assign ns_irq_pending = ns_rx_irq_pending || ns_tx_irq_pending;
  always_comb begin
    if (ns_rx_irq_pending) ns_iir = 8'hC4;  // FIFO enabled, received data available.
    else if (ns_tx_irq_pending) ns_iir = 8'hC2;  // FIFO enabled, THR empty.
    else ns_iir = 8'hC1;  // FIFO enabled, no interrupt pending.
  end

  logic [0:0] aplic_meip, aplic_seip;

  // Interrupt signals to CPU
  riscv_pkg::interrupt_t interrupts;
  // Register the APLIC machine-domain level for timing. A one-cycle delay is safe
  // for level interrupts; UART status and IIR reads still use live conditions.
  logic meip_registered;
  always_ff @(posedge i_clk) begin
    if (rst_core) meip_registered <= 1'b0;
    else meip_registered <= aplic_meip[0];  // APLIC machine-domain line
  end
  assign interrupts.meip = meip_registered;

  logic [riscv_pkg::MemStrbBits-1:0] data_memory_byte_write_enable_registered;

  // ---------------------------------------------------------------------------
  // APLIC. Only 32-bit accesses reach its registers. The byte enables
  // select the write lane; claimi consumes only the addressed read word.
  // ---------------------------------------------------------------------------
  // Capture window selects on the same edge as the MMIO write address.
  logic aplic_sel_q, memerr_sel_q;
  always_ff @(posedge i_clk) begin
    aplic_sel_q <= riscv_pkg::pma_device_quadrant(
        riscv_pkg::XLEN'(data_memory_address)
    ) && (data_memory_address[31:22] == AplicWindowSel);
    memerr_sel_q <= riscv_pkg::pma_device_quadrant(
        riscv_pkg::XLEN'(data_memory_address)
    ) && (data_memory_address[31:8] == MemErrBase[31:8]);
  end
  logic aplic_wr_en, aplic_wr_hi;
  assign aplic_wr_hi = |data_memory_byte_write_enable_registered[7:4];
  assign aplic_wr_en = aplic_sel_q &&
      ((data_memory_byte_write_enable_registered == 8'h0F) ||
       (data_memory_byte_write_enable_registered == 8'hF0));
  logic [63:0] aplic_rd_pair;
  logic dma_engine_irq, nic_irq;
  // Memory error unit register bus (same shape) and interrupt. The DDR
  // bridge's error pulses come from the cached tier below, or stay low
  // without it.
  logic memerr_wr_en, memerr_wr_hi, memerr_irq;
  logic [63:0] memerr_rd_pair;
  logic ddr_rd_err_valid, ddr_wr_err_valid;
  logic [1:0] ddr_rd_err_resp, ddr_wr_err_resp;
  logic [DdrAxiIdBits-1:0] ddr_rd_err_id, ddr_wr_err_id;
  assign memerr_wr_hi = |data_memory_byte_write_enable_registered[7:4];
  assign memerr_wr_en = |data_memory_byte_write_enable_registered && memerr_sel_q;
  memory_error_unit #(
      .ID_BITS(DdrAxiIdBits)
  ) memory_errors (
      .i_clk(i_clk),
      .i_rst(rst_core),
      .i_wr_en(memerr_wr_en),
      .i_wr_offset({data_memory_address_registered[7:3], memerr_wr_hi ? 3'b100 : 3'b000}),
      .i_wr_data(memerr_wr_hi ? data_memory_write_data_registered[63:32] :
                                data_memory_write_data_registered[31:0]),
      .i_rd_offset({mmio_load_addr[7:3], 3'b000}),
      .o_rd_pair(memerr_rd_pair),
      .o_irq(memerr_irq),
      .i_ecc_present(i_ecc_present),
      .i_ecc_poll(i_ecc_poll),
      .i_ce_valid(i_ecc_ce_valid),
      .i_ce_count(i_ecc_ce_count),
      .i_ce_addr_valid(i_ecc_ce_addr_valid),
      .i_ce_addr(i_ecc_ce_addr),
      .i_ue_valid(i_ecc_ue_valid),
      .i_ue_addr_valid(i_ecc_ue_addr_valid),
      .i_ue_addr(i_ecc_ue_addr),
      .i_rd_err_valid(ddr_rd_err_valid),
      .i_rd_err_resp(ddr_rd_err_resp),
      .i_rd_err_id(ddr_rd_err_id),
      .i_wr_err_valid(ddr_wr_err_valid),
      .i_wr_err_resp(ddr_wr_err_resp),
      .i_wr_err_id(ddr_wr_err_id)
  );
  aplic #(
      .NUM_SOURCES(5),
      .NUM_HARTS(1),
      .IPRIOLEN(3)
  ) aplic_inst (
      .i_clk(i_clk),
      .i_rst(rst_core),
      // Source ID 1 = ns16550, ID 2 = the board pin, ID 3 = the DMA test
      // engine, ID 4 = the NIC, ID 5 = the memory error unit. The === clamp
      // keeps an un-driven i_external_interrupt in simulation from
      // propagating X into the APLIC and mip.
      .i_src({
        memerr_irq, nic_irq, dma_engine_irq, (i_external_interrupt === 1'b1), ns_irq_pending
      }),
      .i_wr_en(aplic_wr_en),
      .i_wr_offset({data_memory_address_registered[21:3], aplic_wr_hi ? 3'b100 : 3'b000}),
      .i_wr_data(aplic_wr_hi ? data_memory_write_data_registered[63:32] :
                              data_memory_write_data_registered[31:0]),
      .i_rd_offset(mmio_load_addr[21:0]),
      .o_rd_pair(aplic_rd_pair),
      .i_rd_capture(mmio_read_capture && (mmio_load_addr[31:22] == AplicWindowSel) &&
                    (mmio_load_size == riscv_pkg::MEM_SIZE_WORD)),
      .o_meip(aplic_meip),
      .o_seip(aplic_seip),
      .o_msi_valid(),
      .i_msi_ready(1'b0),
      .o_msi_addr(),
      .o_msi_data()
  );
  assign interrupts.msip = msip;

  // Register the timer compare for timing; MTIP is delayed one cycle.
  logic mtip_comparison;
  logic mtip_registered;
  assign mtip_comparison = (mtime >= mtimecmp);
  always_ff @(posedge i_clk) begin
    if (rst_core) mtip_registered <= 1'b0;
    else mtip_registered <= mtip_comparison;
  end
  assign interrupts.mtip = mtip_registered;

  // mtimecmp MMIO write pulse: a kernel/handler timer re-arm. Used by the hang
  // triage as a "timer tick serviced" event tap.
  logic mtimecmp_write_pulse;
  assign mtimecmp_write_pulse = |data_memory_byte_write_enable_registered &&
      ((data_memory_address_registered == riscv_pkg::PhysAddrBits'(MtimecmpLowMmioAddr)) ||
       (data_memory_address_registered == riscv_pkg::PhysAddrBits'(MtimecmpHighMmioAddr)) ||
       (data_memory_address_registered == riscv_pkg::PhysAddrBits'(ClintMtimecmpLo)) ||
       (data_memory_address_registered == riscv_pkg::PhysAddrBits'(ClintMtimecmpHi)));
  logic [5:0] cpu_debug_irq_status;
  logic [31:0] cpu_debug_commit_pc;
  logic [31:0] cpu_debug_commit_2_pc;
  logic [1:0] cpu_debug_commit_valid;

  // RISC-V OOO CPU core: Tomasulo out-of-order, RV64GCB, M/S/U privilege.
  // Keep the complete virtual PC as the fetch-window identity. Physical
  // addresses use the configured width; the core's PMA checks reject values
  // above that width before any request reaches this boundary.
  logic [riscv_pkg::XLEN-1:0] cpu_pc_xlen;
  logic [riscv_pkg::XLEN-1:0] cpu_data_mem_addr_xlen;
  logic [riscv_pkg::XLEN-1:0] cpu_mmio_load_addr_xlen;
  logic [riscv_pkg::XLEN-1:0] cpu_debug_commit_pc_xlen;
  logic [riscv_pkg::XLEN-1:0] cpu_debug_commit_2_pc_xlen;
  assign program_counter = cpu_pc_xlen;
  assign data_memory_address = cpu_data_mem_addr_xlen[riscv_pkg::PhysAddrBits-1:0];
  assign mmio_load_addr = cpu_mmio_load_addr_xlen[31:0];
  assign cpu_debug_commit_pc = cpu_debug_commit_pc_xlen[31:0];
  assign cpu_debug_commit_2_pc = cpu_debug_commit_2_pc_xlen[31:0];

  // Hart interface (cpu_ooo <-> debug module).
  logic dbg_haltreq, dbg_go, dbg_data_we, dbg_debug_mode, dbg_parked, dbg_cmd_err, dbg_go_taken;
  logic [31:0] dbg_go_addr;
  logic [63:0] dbg_data, dbg_data_wdata;
  logic dbg_bram_store;
  logic [31:0] dbg_bram_store_addr;
  logic [7:0] dbg_bram_store_strb;

  cpu_ooo #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth),
      .MMIO_ADDR(MmioAddr),
      .CACHED_BASE(64'(CACHED_BASE)),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES),
      .PERF_COUNTERS(PERF_COUNTERS),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .EARLY_LOAD_WAKEUP(EARLY_LOAD_WAKEUP),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .INT_RS_DEPTH(INT_RS_DEPTH),
      .DECODED_QUEUE_DEPTH(DECODED_QUEUE_DEPTH)
  ) cpu_inst (
      .o_uncached_read_enable(),
      .o_uncached_read_size(mmio_load_size),
      .o_uncached_read_ready(),
      .o_uncached_write_byte_en(),
      .o_uncached_write_size(),
      .o_uncached_write_buffered(),
      .i_clk,
      .i_rst(rst_core),
      .o_pc(cpu_pc_xlen),
      .i_instr(instruction),
      .i_instr_low_by_parity(bram_fetch_instr_by_parity),
      .i_instr_high(instruction_high),
      .i_instr_window_high(instruction_window_high),
      .i_instr_sideband(instruction_sideband),
      .i_instr_pc_metadata(instruction_pc_metadata),
      .i_instr_pc_metadata_by_provider_parity(fetch_pc_metadata_by_provider_parity),
      .i_pc_pairability_by_provider_parity(fetch_pc_pairability_by_provider_parity),
      .i_slot2_start_valid_lo_by_provider_parity(
          fetch_slot2_start_valid_lo_by_provider_parity
      ),
      .i_instr_pc_metadata_served_high(instruction_pc_metadata_served_high),
      .i_instr_bank_sel_r(instruction_bank_sel_r),
      .i_served_word_low(instruction_served_word_low),
      .i_served_last_word_low(instruction_served_last_word_low),
      .i_served_prev_word_low(instruction_served_prev_word_low),
      .i_served_prev_word_valid_low(instruction_served_prev_word_valid_low),
      .i_served_word_high(instruction_served_word_high),
      .i_served_last_word_high(instruction_served_last_word_high),
      .i_served_prev_word_high(instruction_served_prev_word_high),
      .i_served_prev_word_valid_high(instruction_served_prev_word_valid_high),
      .i_instr_valid(instruction_valid),
      .i_instr_fault0(instruction_fault0),
      .i_instr_fault0_page(instruction_fault0_page),
      .i_instr_fault1(instruction_fault1),
      .i_instr_fault1_page(instruction_fault1_page),
      .i_served_high(instruction_served_high),
      .o_fetch_replay_consume(fetch_replay_consume),
      .o_fetch_live_claim(fetch_live_claim),
      .o_fetch_pa0(fetch_pa0),
      .o_fetch_pa1(fetch_pa1),
      .o_fetch_pa_valid(fetch_pa_valid),
      .o_fetch_fault0(fetch_fault0),
      .o_fetch_fault0_page(fetch_fault0_page),
      .o_fetch_fault1(fetch_fault1),
      .o_fetch_fault1_page(fetch_fault1_page),
      .o_fetch_line_after_ok(fetch_line_after_ok),
      .o_fetch_redirect(fetch_redirect),
      .o_fetch_cached_retarget(fetch_cached_retarget),
      .o_pipeline_stall(pipeline_stall),
      .o_fence_i_sync_req(fence_i_sync_req),
      .i_fence_i_sync_done(fence_i_sync_done),
      .o_walk_line_req_valid(walk_line_req_valid),
      .i_walk_line_req_ready(walk_line_req_ready),
      .o_walk_line_req_addr(walk_line_req_addr),
      .o_walk_line_req_id(ptw_line_req_id),
      .i_walk_line_resp_valid(walk_line_resp_valid),
      .i_walk_line_resp_id(walk_line_resp_id[1:0]),
      .i_walk_line_resp_rdata(walk_line_resp_rdata),
      .o_fence_i_flush(fence_i_flush),
      .o_data_mem_addr(cpu_data_mem_addr_xlen),
      .o_data_mem_wr_data(data_memory_write_data),
      .o_data_mem_per_byte_wr_en(data_memory_byte_write_enable),
      .o_data_mem_bram_byte_wr_en(data_memory_bram_byte_write_enable),
      .o_data_mem_read_enable(data_memory_read_enable),
      // Cached tier ports (high-address region).
      .o_data_mem_cached_byte_wr_en(data_memory_cached_byte_write_enable),
      .o_data_mem_cached_wr_data(data_memory_cached_write_data),
      .o_data_mem_cached_read_enable(data_memory_cached_read_enable),
      .o_data_mem_cached_read_sel(data_memory_cached_read_sel),
      .o_data_mem_cached_read_if_sel(data_memory_cached_read_if_sel),
      .o_data_mem_cached_read_if_clear(data_memory_cached_read_if_clear),
      .o_data_mem_cached_read_id(data_memory_cached_read_id),
      .o_data_mem_cached_read_no_merge(data_memory_cached_read_no_merge),
      .i_cached_read_data(data_memory_response_data),
      .i_cached_read_id(data_memory_cached_resp_id),
      .i_cached_read_valid(data_memory_cached_read_valid),
      .o_cached_read_ready(data_memory_cached_read_ready),
      .i_cached_write_done(data_memory_cached_write_done),
      .i_cached_write_inflight(data_memory_cached_write_inflight),
      // DMA coherence handshake
      .i_coh_admit_valid(coh_admit_valid),
      .i_coh_admit_slot(coh_admit_slot),
      .i_coh_admit_addr(riscv_pkg::XLEN'(coh_admit_addr)),
      .o_coh_admit_ready(coh_admit_ready),
      .i_coh_inval_valid(coh_inval_valid),
      .i_coh_inval_slot(coh_inval_slot),
      .o_coh_inval_done(coh_inval_done),
      .i_coh_release_valid(coh_release_valid),
      .i_coh_release_slot(coh_release_slot),
      .i_cache_perf_events(cache_perf_events),
      .o_mmio_read_pulse(mmio_read_pulse),
      .o_mmio_load_addr(cpu_mmio_load_addr_xlen),
      .o_mmio_load_valid(mmio_load_valid),
      .o_mmio_fifo0_read_pulse(mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(mmio_uart_rx_ready_pulse),
      .i_data_mem_rd_data(data_memory_response_data),
      .o_rst_done(/*not connected*/),
      .o_vld   (commit_vld),
      .o_pc_vld(/*not connected*/),
      // Interrupt and timer interface
`ifdef FROST_RVFI_DII
      // TestRIG (hw/sim/frost_rvfi_dii.sv) takes no interrupts.
      .i_interrupts('0),
      .i_seip_line(1'b0),
`else
      .i_interrupts(interrupts),
      .i_seip_line(aplic_seip[0]),
`endif
      .i_mtime(mtime),
      .o_debug_irq_status(cpu_debug_irq_status),
      .o_debug_commit_pc(cpu_debug_commit_pc_xlen),
      .o_debug_commit_2_pc(cpu_debug_commit_2_pc_xlen),
      .o_debug_commit_valid(cpu_debug_commit_valid),
      // Branch prediction enabled by default in production. TestRIG
      // instruction injection requires fetch to stay on the sequential path
      // between redirects (hw/sim/frost_rvfi_dii.sv).
`ifdef FROST_RVFI_DII
      .i_disable_branch_prediction(1'b1),
`else
      .i_disable_branch_prediction(1'b0),
`endif
      // Debug module interface
      .i_dbg_haltreq(dbg_haltreq),
      .i_dbg_go(dbg_go),
      .i_dbg_go_addr(dbg_go_addr),
      .i_dbg_data(dbg_data),
      .o_dbg_data_we(dbg_data_we),
      .o_dbg_data_wdata(dbg_data_wdata),
      .o_debug_mode(dbg_debug_mode),
      .o_dbg_parked(dbg_parked),
      .o_dbg_cmd_err(dbg_cmd_err),
      .o_dbg_go_taken(dbg_go_taken),
      .o_dbg_bram_store(dbg_bram_store),
      .o_dbg_bram_store_addr(dbg_bram_store_addr),
      .o_dbg_bram_store_strb(dbg_bram_store_strb)
  );

  // Both low-BRAM copies receive programming writes on port A (div4 clock).
  // Port B serves instruction fetch or data access on the main clock.

  // ===========================================================================
  // Fetch providers: fuzzed low BRAM, low BRAM plus L1I, or low BRAM alone.
  // The metadata overlay responds in one cycle. Other low-BRAM windows wait
  // an extra cycle for registered PC predicates.
  // ===========================================================================
  // Each response must match the owed address: o_pc from the last served
  // cycle, retargeted by redirects during invalid cycles. Providers hold one
  // owed request. The low presenter uses a registered retarget pulse.
  // A leading slot-1 prediction still owes its branch response; slot 2 and
  // non-leading slot 1 have emitted theirs and can retarget. The cached
  // provider also detects unaccepted PC movement and handles recovery,
  // emitted predictions, resteer, and epoch changes. TestRIG builds
  // (FROST_RVFI_DII, simulation only) leave out the cached provider: every
  // window comes from the injected instruction stream through the low-BRAM
  // presenter, and the cached tier still serves data.
`ifdef FROST_RVFI_DII
  localparam bit EnableCachedFetchProvider = 1'b0;
`else
  localparam bit EnableCachedFetchProvider = ENABLE_CACHED_TIER != 0;
`endif
  if (FETCH_VALID_FUZZ != 0) begin : gen_fetch_fuzz
    logic [15:0] lfsr_q;
    logic [ 2:0] gap_cnt_q;  // forced multi-cycle gaps
    logic        pipeline_stall_q;  // registered stall (mirror real-provider lag)

    logic        lfsr_feedback;
    logic        fuzz_ok;
    logic        fuzz_publish_hold;
    logic        low_bram_response_valid;
    assign lfsr_feedback = lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10];
    assign fuzz_ok = (gap_cnt_q == '0) && (lfsr_q[1:0] != 2'b00);

    // A fuzz gap holds the complete request on the memory pins. Disable
    // overlay bypass so overlay hits also see gaps. Registered stall preserves
    // IF's first-stall-cycle capture.
    assign fuzz_publish_hold = !fuzz_ok || pipeline_stall_q;
    assign instruction_valid = low_bram_response_valid;
    assign instruction_served_word_low = bram_fetch_served_word_q;
    assign instruction_served_last_word_low = bram_fetch_served_last_word_q;
    assign instruction_served_prev_word_low = bram_fetch_served_prev_word_q;
    assign instruction_served_prev_word_valid_low = bram_fetch_served_prev_word_valid_q;
    assign instruction_served_word_high = '0;
    assign instruction_served_last_word_high = (riscv_pkg::XLEN - 2)'(1);
    assign instruction_served_prev_word_high = '1;
    assign instruction_served_prev_word_valid_high = 1'b0;
    assign instruction_fault0 = bram_fetch_fault0_q;
    assign instruction_fault0_page = bram_fetch_fault0_page_q;
    assign instruction_fault1 = bram_fetch_fault1_q;
    assign instruction_fault1_page = bram_fetch_fault1_page_q;
    assign instruction_served_high = 1'b0;
    assign instruction_pc_metadata_served_high = 1'b0;

    low_bram_fetch_presenter u_low_bram_fetch_presenter (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_response_ready(bram_fetch_response_ready),
        .i_response_overlay_hit(1'b0),
        .i_response_claim(fetch_live_claim),
        .i_publish_hold(fuzz_publish_hold),
        .i_owner_low(1'b1),
        .i_retarget(fetch_redirect),
        .i_address_retarget(fetch_redirect),
        .i_pc(program_counter),
        .i_pa0(fetch_pa0[31:0]),
        .i_pa1(fetch_pa1[31:0]),
        .i_pa_valid(fetch_pa_valid),
        .i_fault0(fetch_fault0),
        .i_fault0_page(fetch_fault0_page),
        .i_fault1(fetch_fault1),
        .i_fault1_page(fetch_fault1_page),
        .o_fetch_address(fetch_address),
        .o_fetch_pc(fetch_request_pc),
        .o_fetch_pa0(fetch_pa_word0),
        .o_fetch_pa1(fetch_pa_word1),
        .o_fetch_pa_valid(fetch_pa_ok),
        .o_fetch_fault0(fetch_word0_fault),
        .o_fetch_fault0_page(fetch_word0_fault_page),
        .o_fetch_fault1(fetch_word1_fault),
        .o_fetch_fault1_page(fetch_word1_fault_page),
        .o_response_valid(low_bram_response_valid)
    );
    assign instruction = bram_fetch_instr;
    assign instruction_high = '0;
    assign instruction_window_high = 1'b0;
    assign instruction_sideband = bram_fetch_sideband;
    assign instruction_pc_metadata = bram_fetch_pc_metadata;
    assign high_fetch_pc_metadata_by_parity = '0;
    assign high_fetch_pc_pairability_by_parity = '0;
    assign high_fetch_slot2_start_valid_lo_by_parity = '0;
    assign instruction_bank_sel_r = bram_fetch_bank_sel_cpu_r;

    // No instruction-side cache traffic in fuzz mode (low-BRAM programs).
    assign iup_req_valid = 1'b0;
    assign iup_req_write = 1'b0;
    assign iup_req_addr = '0;
    assign iup_req_wdata = '0;
    assign iup_req_wstrb = '0;
    assign iup_req_id = '0;
    assign l1i_fetch_miss_stall = 1'b0;

    always_ff @(posedge i_clk) begin
      if (rst_core) begin
        lfsr_q           <= 16'(FETCH_VALID_FUZZ_SEED);
        gap_cnt_q        <= '0;
        pipeline_stall_q <= 1'b0;
      end else begin
        pipeline_stall_q <= pipeline_stall;
        lfsr_q <= {lfsr_q[14:0], lfsr_feedback};
        if (gap_cnt_q != '0) gap_cnt_q <= gap_cnt_q - 1'b1;
        else if (lfsr_q[7:3] == 5'b00000) gap_cnt_q <= {1'b1, lfsr_q[9:8]};
      end
    end
  end else if (EnableCachedFetchProvider) begin : gen_fetch_provider
    // Register the provider select to match the memory read latency.
    // Low overlay hits respond in one cycle; other low windows repeat once.
    // High windows wait for L1I.
    (* keep = "true", max_fanout = 16 *) logic fetch_high_valid_q;
    (* keep = "true", max_fanout = 16 *) logic fetch_high_instr_q;
    (* keep = "true", max_fanout = 16 *) logic fetch_high_sideband_q;
    (* keep = "true", max_fanout = 16 *) logic fetch_high_pc_metadata_q;
    logic fetch_high_transition;
    logic [63:0] cached_fetch_instr;
    logic [riscv_pkg::ImemFetchSidebandWidth-1:0] cached_fetch_sideband;
    logic [7:0] cached_fetch_pc_metadata;
    logic cached_fetch_bank_sel_r;
    logic [riscv_pkg::XLEN-3:0] cached_fetch_served_word;
    logic [riscv_pkg::XLEN-3:0] cached_fetch_served_last_word;
    logic [riscv_pkg::XLEN-3:0] cached_fetch_served_prev_word;
    logic cached_fetch_served_prev_word_valid;
    logic cached_fetch_fault0, cached_fetch_fault0_page;
    logic cached_fetch_fault1, cached_fetch_fault1_page;
    logic cached_fetch_valid;
    logic cached_fetch_valid_next;
    // Local copy of fetch_provider's publish-valid register, for timing.
    // It captures the same value on the same edge.
    (* keep = "true", max_fanout = 16 *)logic cached_fetch_valid_local_q;
    logic low_bram_response_valid;
    logic low_bram_pipeline_stall_q;

    always_ff @(posedge i_clk) begin
      if (rst_core) low_bram_pipeline_stall_q <= 1'b0;
      else low_bram_pipeline_stall_q <= pipeline_stall;
    end

    always_ff @(posedge i_clk) begin
      if (rst_core || fence_i_flush) cached_fetch_valid_local_q <= 1'b0;
      else cached_fetch_valid_local_q <= cached_fetch_valid_next;
    end

    // The low address pins (PA bits [15:0], retargeted only by
    // i_address_retarget) may finish a held low request on a low-to-high
    // crossing. The upper PA bits take the full retarget and mark that read
    // high, so it can neither hit the low overlay nor match a later low
    // response identity.
    low_bram_fetch_presenter #(
        .SEPARATE_ADDRESS_RETARGET(1'b1)
    ) u_low_bram_fetch_presenter (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_response_ready(bram_fetch_response_ready),
        .i_response_overlay_hit(bram_fetch_window_overlay_hit),
        .i_response_claim(fetch_live_claim),
        .i_publish_hold(low_bram_pipeline_stall_q),
        .i_owner_low(!fetch_pa0_is_cached),
        .i_retarget(fetch_redirect || fetch_high_transition),
        .i_address_retarget(fetch_redirect),
        .i_pc(program_counter),
        .i_pa0(fetch_pa0[31:0]),
        .i_pa1(fetch_pa1[31:0]),
        .i_pa_valid(fetch_pa_valid),
        .i_fault0(fetch_fault0),
        .i_fault0_page(fetch_fault0_page),
        .i_fault1(fetch_fault1),
        .i_fault1_page(fetch_fault1_page),
        .o_fetch_address(fetch_address),
        .o_fetch_pc(fetch_request_pc),
        .o_fetch_pa0(fetch_pa_word0),
        .o_fetch_pa1(fetch_pa_word1),
        .o_fetch_pa_valid(fetch_pa_ok),
        .o_fetch_fault0(fetch_word0_fault),
        .o_fetch_fault0_page(fetch_word0_fault_page),
        .o_fetch_fault1(fetch_word1_fault),
        .o_fetch_fault1_page(fetch_word1_fault_page),
        .o_response_valid(low_bram_response_valid)
    );
    assign cached_fetch_pc_metadata = {
      cached_fetch_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
      cached_fetch_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
      cached_fetch_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
      cached_fetch_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
      cached_fetch_sideband[riscv_pkg::ImemSbPairableNativeHi],
      cached_fetch_sideband[riscv_pkg::ImemSbPairableCompressedHi],
      cached_fetch_sideband[riscv_pkg::ImemSbIsCompressedHi],
      cached_fetch_sideband[riscv_pkg::ImemSbIsCompressedLo]
    };
    always_ff @(posedge i_clk) begin
      if (rst_core) begin
        fetch_high_valid_q       <= 1'b0;
        fetch_high_instr_q       <= 1'b0;
        fetch_high_sideband_q    <= 1'b0;
        fetch_high_pc_metadata_q <= 1'b0;
      end else begin
        // The tier is a property of the physical address.
        fetch_high_valid_q       <= fetch_pa0_is_cached;
        fetch_high_instr_q       <= fetch_pa0_is_cached;
        fetch_high_sideband_q    <= fetch_pa0_is_cached;
        fetch_high_pc_metadata_q <= fetch_pa0_is_cached;
      end
    end

    // Suppress one delivery cycle on a tier crossing until the registered
    // select matches the full-width cached-region decode. Otherwise a stale low-BRAM response could
    // advance IF while the high provider still owes the target. Metadata and
    // payload selects switch together; served tags remain provider-local.
    assign fetch_high_transition = fetch_high_valid_q ^ fetch_pa0_is_cached;
    assign instruction_valid = fetch_high_transition ? 1'b0 :
                               (fetch_high_valid_q ? cached_fetch_valid_local_q :
                                low_bram_response_valid);
    assign instruction_fault0 = fetch_high_valid_q ? cached_fetch_fault0 : bram_fetch_fault0_q;
    assign instruction_fault0_page = fetch_high_valid_q ? cached_fetch_fault0_page :
                                                          bram_fetch_fault0_page_q;
    assign instruction_fault1 = fetch_high_valid_q ? cached_fetch_fault1 : bram_fetch_fault1_q;
    assign instruction_fault1_page = fetch_high_valid_q ? cached_fetch_fault1_page :
                                                          bram_fetch_fault1_page_q;
    assign instruction_served_high = fetch_high_valid_q;
    assign instruction_pc_metadata_served_high = fetch_high_pc_metadata_q;
    assign instruction = fetch_high_instr_q ? cached_fetch_instr : bram_fetch_instr;
    assign instruction_high = cached_fetch_instr;
    assign instruction_window_high = fetch_high_instr_q;
    assign instruction_sideband = fetch_high_sideband_q ? cached_fetch_sideband :
                                  bram_fetch_sideband;
    assign instruction_pc_metadata = fetch_high_pc_metadata_q ?
        cached_fetch_pc_metadata : bram_fetch_pc_metadata;
    assign instruction_bank_sel_r = fetch_high_valid_q ? cached_fetch_bank_sel_r :
                                                         bram_fetch_bank_sel_cpu_r;
    assign instruction_served_word_low = bram_fetch_served_word_q;
    assign instruction_served_last_word_low = bram_fetch_served_last_word_q;
    assign instruction_served_prev_word_low = bram_fetch_served_prev_word_q;
    assign instruction_served_prev_word_valid_low = bram_fetch_served_prev_word_valid_q;
    assign instruction_served_word_high = cached_fetch_served_word;
    assign instruction_served_last_word_high = cached_fetch_served_last_word;
    assign instruction_served_prev_word_high = cached_fetch_served_prev_word;
    assign instruction_served_prev_word_valid_high = cached_fetch_served_prev_word_valid;

`ifndef SYNTHESIS
    // Timing replicas that select payload-derived metadata must remain
    // cycle-identical to the served-provider selector.
    always_ff @(posedge i_clk) begin
      if (!rst_core) begin
        p_cached_fetch_valid_timing_twin_exact :
        assert (cached_fetch_valid_local_q == cached_fetch_valid);
        p_fetch_high_pc_metadata_select_aligned :
        assert (fetch_high_pc_metadata_q == fetch_high_valid_q);
      end
    end
`endif

    // Cached-code fetch buffer: two window slots and a victim store before
    // L1I. The low-BRAM path is independent.
    fetch_provider #(
        .LINE_BYTES  (L1LineBytes),
        .LINE_ID_BITS(LineIdBits)
    ) u_fetch_provider (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_pc(program_counter),
        .i_pa0(fetch_pa0),
        .i_pa1(fetch_pa1),
        .i_pa_valid(fetch_pa_valid),
        .i_fault0(fetch_fault0),
        .i_fault0_page(fetch_fault0_page),
        .i_fault1(fetch_fault1),
        .i_fault1_page(fetch_fault1_page),
        .i_line_after_ok(fetch_line_after_ok),
        .i_retarget(fetch_cached_retarget),
        .i_fetch_replay_consume(fetch_replay_consume),
        .i_pipeline_stall(pipeline_stall),
        .o_instr(cached_fetch_instr),
        .o_instr_sideband(cached_fetch_sideband),
        .o_pc_metadata_by_parity(high_fetch_pc_metadata_by_parity),
        .o_pc_pairability_by_parity(high_fetch_pc_pairability_by_parity),
        .o_slot2_start_valid_lo_by_parity(high_fetch_slot2_start_valid_lo_by_parity),
        .o_instr_bank_sel_r(cached_fetch_bank_sel_r),
        .o_served_word(cached_fetch_served_word),
        .o_served_last_word(cached_fetch_served_last_word),
        .o_served_prev_word(cached_fetch_served_prev_word),
        .o_served_prev_word_valid(cached_fetch_served_prev_word_valid),
        .o_served_fault0(cached_fetch_fault0),
        .o_served_fault0_page(cached_fetch_fault0_page),
        .o_served_fault1(cached_fetch_fault1),
        .o_served_fault1_page(cached_fetch_fault1_page),
        .o_instr_valid(cached_fetch_valid),
        .o_instr_valid_next(cached_fetch_valid_next),
        .i_l1i_miss_outstanding(|cache_hierarchy_perf_events.l1i.miss_outstanding),
        .o_perf_miss_stall(l1i_fetch_miss_stall),
        .o_line_req_valid(iup_req_valid),
        .i_line_req_ready(iup_req_ready),
        .o_line_req_write(iup_req_write),
        .o_line_req_addr(iup_req_addr),
        .o_line_req_wdata(iup_req_wdata),
        .o_line_req_wstrb(iup_req_wstrb),
        .o_line_req_id(iup_req_id),
        .i_line_resp_valid(iup_resp_valid),
        .i_line_resp_id(iup_resp_id),
        .i_line_resp_rdata(iup_resp_rdata),
        // FENCE-class retirement: drop both buffer lines, the victim store,
        // and any landing fill the same cycle the pipeline flushes, before
        // refetch arrives.
        .i_invalidate(fence_i_flush)
    );
  end else begin : gen_fetch_direct
    logic low_bram_response_valid;
    logic low_bram_pipeline_stall_q;
    assign instruction_valid = low_bram_response_valid;

    always_ff @(posedge i_clk) begin
      if (rst_core) low_bram_pipeline_stall_q <= 1'b0;
      else low_bram_pipeline_stall_q <= pipeline_stall;
    end
    assign instruction_served_word_low = bram_fetch_served_word_q;
    assign instruction_served_last_word_low = bram_fetch_served_last_word_q;
    assign instruction_served_prev_word_low = bram_fetch_served_prev_word_q;
    assign instruction_served_prev_word_valid_low = bram_fetch_served_prev_word_valid_q;
    assign instruction_served_word_high = '0;
    assign instruction_served_last_word_high = (riscv_pkg::XLEN - 2)'(1);
    assign instruction_served_prev_word_high = '1;
    assign instruction_served_prev_word_valid_high = 1'b0;
    assign instruction_fault0 = bram_fetch_fault0_q;
    assign instruction_fault0_page = bram_fetch_fault0_page_q;
    assign instruction_fault1 = bram_fetch_fault1_q;
    assign instruction_fault1_page = bram_fetch_fault1_page_q;
    assign instruction_served_high = 1'b0;
    assign instruction_pc_metadata_served_high = 1'b0;
    low_bram_fetch_presenter u_low_bram_fetch_presenter (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_response_ready(bram_fetch_response_ready),
        .i_response_overlay_hit(bram_fetch_window_overlay_hit),
        .i_response_claim(fetch_live_claim),
        .i_publish_hold(low_bram_pipeline_stall_q),
        .i_owner_low(1'b1),
        .i_retarget(fetch_redirect),
        .i_address_retarget(fetch_redirect),
        .i_pc(program_counter),
        .i_pa0(fetch_pa0[31:0]),
        .i_pa1(fetch_pa1[31:0]),
        .i_pa_valid(fetch_pa_valid),
        .i_fault0(fetch_fault0),
        .i_fault0_page(fetch_fault0_page),
        .i_fault1(fetch_fault1),
        .i_fault1_page(fetch_fault1_page),
        .o_fetch_address(fetch_address),
        .o_fetch_pc(fetch_request_pc),
        .o_fetch_pa0(fetch_pa_word0),
        .o_fetch_pa1(fetch_pa_word1),
        .o_fetch_pa_valid(fetch_pa_ok),
        .o_fetch_fault0(fetch_word0_fault),
        .o_fetch_fault0_page(fetch_word0_fault_page),
        .o_fetch_fault1(fetch_word1_fault),
        .o_fetch_fault1_page(fetch_word1_fault_page),
        .o_response_valid(low_bram_response_valid)
    );
    assign instruction = bram_fetch_instr;
    assign instruction_high = '0;
    assign instruction_window_high = 1'b0;
    assign instruction_sideband = bram_fetch_sideband;
    assign instruction_pc_metadata = bram_fetch_pc_metadata;
    assign high_fetch_pc_metadata_by_parity = '0;
    assign high_fetch_pc_pairability_by_parity = '0;
    assign high_fetch_slot2_start_valid_lo_by_parity = '0;
    assign instruction_bank_sel_r = bram_fetch_bank_sel_cpu_r;
    assign iup_req_valid = 1'b0;
    assign iup_req_write = 1'b0;
    assign iup_req_addr = '0;
    assign iup_req_wdata = '0;
    assign iup_req_wstrb = '0;
    assign iup_req_id = '0;
    assign l1i_fetch_miss_stall = 1'b0;
  end

`ifndef SYNTHESIS
  // The dedicated low-BRAM copy and the cached-sideband fallback must present
  // the same selected size/pairability window. Only published windows are
  // checked; stale payloads are ignored while a variable-latency provider is
  // invalid.
  logic [7:0] instruction_pc_metadata_canonical;
  logic [7:0] bram_pc_metadata_by_parity_canonical;
  logic [3:0] bram_pc_pairability_by_parity_canonical;
  logic [1:0] bram_slot2_start_valid_lo_by_parity_canonical;
  always_comb begin
    instruction_pc_metadata_canonical = {
      instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
      instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
      instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
      instruction_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
      instruction_sideband[riscv_pkg::ImemSbPairableNativeHi],
      instruction_sideband[riscv_pkg::ImemSbPairableCompressedHi],
      instruction_sideband[riscv_pkg::ImemSbIsCompressedHi],
      instruction_sideband[riscv_pkg::ImemSbIsCompressedLo]
    };
    bram_pc_metadata_by_parity_canonical = bram_fetch_bank_sel_r ?
        {bram_fetch_pc_metadata[3:0], bram_fetch_pc_metadata[7:4]} :
        bram_fetch_pc_metadata;
    bram_slot2_start_valid_lo_by_parity_canonical = bram_fetch_bank_sel_r ?
        {
          bram_fetch_sideband[riscv_pkg::ImemSbSlot2StartValidLo],
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ]
        } : {
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ],
          bram_fetch_sideband[riscv_pkg::ImemSbSlot2StartValidLo]
        };
    bram_pc_pairability_by_parity_canonical = bram_fetch_bank_sel_r ?
        {
          bram_fetch_sideband[riscv_pkg::ImemSbPairableNativeLo],
          bram_fetch_sideband[riscv_pkg::ImemSbEvenLocalPairValid],
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ]
        } : {
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          bram_fetch_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ],
          bram_fetch_sideband[riscv_pkg::ImemSbPairableNativeLo],
          bram_fetch_sideband[riscv_pkg::ImemSbEvenLocalPairValid]
        };
  end
  always_ff @(posedge i_clk) begin
    if (!rst_core && instruction_valid && !$isunknown(
            {instruction_pc_metadata, instruction_pc_metadata_canonical}
        )) begin
      p_selected_pc_metadata_matches_canonical :
      assert (instruction_pc_metadata == instruction_pc_metadata_canonical);
    end
    if (!rst_core && instruction_valid && !instruction_served_high && !$isunknown(
            {
              bram_fetch_pc_metadata_by_parity,
              bram_pc_metadata_by_parity_canonical,
              bram_fetch_pc_pairability_by_parity,
              bram_pc_pairability_by_parity_canonical,
              bram_fetch_slot2_start_valid_lo_by_parity,
              bram_slot2_start_valid_lo_by_parity_canonical
            }
        )) begin
      p_bram_pc_metadata_parity_copy_matches_positional :
      assert (bram_fetch_pc_metadata_by_parity == bram_pc_metadata_by_parity_canonical);
      p_bram_pc_pairability_parity_copy_matches_positional :
      assert (bram_fetch_pc_pairability_by_parity == bram_pc_pairability_by_parity_canonical);
      p_bram_slot2_start_valid_lo_parity_copy_matches_positional :
      assert (
        bram_fetch_slot2_start_valid_lo_by_parity ==
        bram_slot2_start_valid_lo_by_parity_canonical
      );
    end
  end
`endif

`ifndef SYNTHESIS
  // Every generate mode keeps both provider-local tag sets internally
  // consistent, including modulo wrap of the 30-bit word index.
  logic served_contract_check_valid_q;
  always_ff @(posedge i_clk) begin
    if (rst_core) served_contract_check_valid_q <= 1'b0;
    else served_contract_check_valid_q <= 1'b1;
  end

  always_comb begin
    if (served_contract_check_valid_q && !$isunknown(
            {instruction_served_word_low,
             instruction_served_last_word_low,
             instruction_served_prev_word_low,
             instruction_served_prev_word_valid_low,
             instruction_served_word_high,
             instruction_served_last_word_high,
             instruction_served_prev_word_high,
             instruction_served_prev_word_valid_high}
        )) begin
      p_low_served_last_word_contract :
      assert (instruction_served_last_word_low == (instruction_served_word_low + 1'b1));
      p_low_served_prev_word_contract :
      assert (instruction_served_prev_word_low == (instruction_served_word_low - 1'b1));
      p_low_served_prev_valid_contract :
      assert (instruction_served_prev_word_valid_low == (|instruction_served_word_low));
      p_high_served_last_word_contract :
      assert (instruction_served_last_word_high == (instruction_served_word_high + 1'b1));
      p_high_served_prev_word_contract :
      assert (instruction_served_prev_word_high == (instruction_served_word_high - 1'b1));
      p_high_served_prev_valid_contract :
      assert (instruction_served_prev_word_valid_high == (|instruction_served_word_high));
    end
  end
`endif

  // ===========================================================================
  // RISC-V debug: the slice writer programs low BRAM and mirrors Debug-Mode
  // stores into the instruction copy. See hw/rtl/README.md, "Debug".
  // ===========================================================================
  logic dtm_tck, dtm_tdi, dtm_tlr, dtm_capture, dtm_shift, dtm_update;
  logic dtm_sel_dtmcs, dtm_sel_dmi, dtm_tdo_dtmcs, dtm_tdo_dmi;
  logic power_on_rst_core, power_on_rst_tck, power_on_rst_div4;
  if (POWER_ON_RESET_ENABLE != 0) begin : gen_power_on_reset
    // The core clock runs throughout power-on reset. System reset is separate.
    cdc_sync u_power_on_core (
        .i_clk  (i_clk),
        .i_rst  (1'b0),
        .i_async(i_power_on_rst),
        .o_sync (power_on_rst_core)
    );
    cdc_reset_sync u_power_on_div4 (
        .i_clk (i_clk_div4),
        .i_arst(i_power_on_rst),
        .o_rst (power_on_rst_div4)
    );
    cdc_reset_sync u_power_on_tck (
        .i_clk (dtm_tck),
        .i_arst(i_power_on_rst),
        .o_rst (power_on_rst_tck)
    );
  end else begin : gen_no_power_on_reset
    assign power_on_rst_core = 1'b0;
    assign power_on_rst_tck  = 1'b0;
    assign power_on_rst_div4 = 1'b0;
  end
  if (DEBUG_JTAG_TAP != 0) begin : gen_jtag_tap
    jtag_tap u_jtag_tap (
        .i_tck(i_jtag_tck),
        .i_tms(i_jtag_tms),
        .i_tdi(i_jtag_tdi),
        .i_trst_n(i_jtag_trst_n && !power_on_rst_tck),
        .o_tdo(o_jtag_tdo),
        .o_tlr(dtm_tlr),
        .o_capture(dtm_capture),
        .o_shift(dtm_shift),
        .o_update(dtm_update),
        .o_sel_dtmcs(dtm_sel_dtmcs),
        .o_sel_dmi(dtm_sel_dmi),
        .i_tdo_dtmcs(dtm_tdo_dtmcs),
        .i_tdo_dmi(dtm_tdo_dmi)
    );
    assign dtm_tck = i_jtag_tck;
    assign dtm_tdi = i_jtag_tdi;
    assign o_dtm_bscan_tdo_dtmcs = 1'b0;
    assign o_dtm_bscan_tdo_dmi = 1'b0;
  end else begin : gen_bscan_dtm
    assign dtm_tck = i_dtm_bscan_tck;
    assign dtm_tdi = i_dtm_bscan_tdi;
    assign dtm_tlr = i_dtm_bscan_tlr;
    assign dtm_capture = i_dtm_bscan_capture;
    assign dtm_shift = i_dtm_bscan_shift;
    assign dtm_update = i_dtm_bscan_update;
    assign dtm_sel_dtmcs = i_dtm_bscan_sel_dtmcs;
    assign dtm_sel_dmi = i_dtm_bscan_sel_dmi;
    assign o_dtm_bscan_tdo_dtmcs = dtm_tdo_dtmcs;
    assign o_dtm_bscan_tdo_dmi = dtm_tdo_dmi;
    assign o_jtag_tdo = 1'b0;
  end

  logic dmi_req_valid, dmi_resp_valid;
  logic [1:0] dmi_req_op, dmi_resp_op;
  logic [6:0] dmi_req_addr;
  logic [31:0] dmi_req_data, dmi_resp_data;
  dtm_core u_dtm (
      .i_power_on_rst(power_on_rst_core),
      .i_tck_power_on_rst(power_on_rst_tck),
      .i_tck(dtm_tck),
      .i_tlr(dtm_tlr),
      .i_capture(dtm_capture),
      .i_shift(dtm_shift),
      .i_update(dtm_update),
      .i_sel_dtmcs(dtm_sel_dtmcs),
      .i_sel_dmi(dtm_sel_dmi),
      .i_tdi(dtm_tdi),
      .o_tdo_dtmcs(dtm_tdo_dtmcs),
      .o_tdo_dmi(dtm_tdo_dmi),
      .i_clk(i_clk),
      .o_dmi_req_valid(dmi_req_valid),
      .o_dmi_req_op(dmi_req_op),
      .o_dmi_req_addr(dmi_req_addr),
      .o_dmi_req_data(dmi_req_data),
      .i_dmi_resp_valid(dmi_resp_valid),
      .i_dmi_resp_data(dmi_resp_data),
      .i_dmi_resp_op(dmi_resp_op)
  );

  // Slice writer requests: the Debug-Mode store mirror has priority over the
  // debug module's own word writes. The mirror cannot wait (a refused push is
  // a sticky command error); the module's writes can. A dword store mirrors
  // both words: word 0 this cycle, word 1 from a one-deep hold on the next.
  logic slice_req_valid, slice_req_mirror, slice_req_ready, slice_all_done;
  logic [MemByteAddrWidth-1:2] slice_req_word_addr;
  logic [31:0] slice_req_data;
  logic dm_slice_req_valid;
  logic [MemByteAddrWidth-1:2] dm_slice_word_addr;
  logic [31:0] dm_slice_data;
  logic mirror_hold_valid_q;
  logic [MemByteAddrWidth-1:2] mirror_hold_addr_q;
  logic mirror_now_valid, mirror_lo, mirror_hi, mirror_overflow;
  logic [MemByteAddrWidth-1:2] mirror_now_addr;
  // dbg_bram_store is the OR of dbg_bram_store_strb (cpu_ooo), so either
  // half's strobes imply it.
  assign mirror_lo = dbg_debug_mode && (|dbg_bram_store_strb[3:0]);
  assign mirror_hi = dbg_debug_mode && (|dbg_bram_store_strb[7:4]);
  // Mirror the held word 1 first, else the new store's word 0 or lone word 1.
  // mirror_lo || mirror_hi equals dbg_debug_mode && dbg_bram_store.
  assign mirror_now_valid = mirror_hold_valid_q || (dbg_debug_mode && dbg_bram_store);
  assign mirror_now_addr = mirror_hold_valid_q ? mirror_hold_addr_q :
      mirror_lo ? {dbg_bram_store_addr[MemByteAddrWidth-1:3], 1'b0} :
                  {dbg_bram_store_addr[MemByteAddrWidth-1:3], 1'b1};
  // Overflow: the writer refused this cycle's push, or a new store arrived
  // while the hold was still occupied (a dword store needs both the slot and
  // the hold).
  assign mirror_overflow = (mirror_now_valid && !slice_req_ready) ||
      (mirror_hold_valid_q && (mirror_lo || mirror_hi)) ||
      (mirror_lo && mirror_hi && !slice_req_ready);
  // Register overflow for timing. The debug module checks it one cycle
  // after re-parking and retains it as a sticky error.
  logic mirror_overflow_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) mirror_overflow_q <= 1'b0;
    else mirror_overflow_q <= mirror_overflow;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mirror_hold_valid_q <= 1'b0;
      mirror_hold_addr_q  <= '0;
    end else if (mirror_hold_valid_q) begin
      if (slice_req_ready) mirror_hold_valid_q <= 1'b0;
    end else if (mirror_lo && mirror_hi && slice_req_ready) begin
      mirror_hold_valid_q <= 1'b1;
      mirror_hold_addr_q  <= {dbg_bram_store_addr[MemByteAddrWidth-1:3], 1'b1};
    end
  end
  assign slice_req_valid = mirror_now_valid || dm_slice_req_valid;
  assign slice_req_mirror = mirror_now_valid;
  assign slice_req_word_addr = mirror_now_valid ? mirror_now_addr : dm_slice_word_addr;
  assign slice_req_data = dm_slice_data;

  debug_module #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth)
  ) u_debug_module (
      .i_power_on_rst(power_on_rst_core),
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_dmi_req_valid(dmi_req_valid),
      .i_dmi_req_op(dmi_req_op),
      .i_dmi_req_addr(dmi_req_addr),
      .i_dmi_req_data(dmi_req_data),
      .o_dmi_resp_valid(dmi_resp_valid),
      .o_dmi_resp_data(dmi_resp_data),
      .o_dmi_resp_op(dmi_resp_op),
      .o_haltreq(dbg_haltreq),
      .o_go(dbg_go),
      .o_go_addr(dbg_go_addr),
      .o_data(dbg_data),
      .i_data_we(dbg_data_we),
      .i_data_wdata(dbg_data_wdata),
      .i_debug_mode(dbg_debug_mode),
      .i_parked(dbg_parked),
      .i_cmd_err(dbg_cmd_err),
      .i_go_taken(dbg_go_taken),
      .i_core_in_reset(rst_core),
      .o_ndmreset(dbg_ndmreset),
      .o_slice_req_valid(dm_slice_req_valid),
      .o_slice_word_addr(dm_slice_word_addr),
      .o_slice_data(dm_slice_data),
      .i_slice_req_ready(slice_req_ready && !mirror_now_valid),
      .i_slice_all_done(slice_all_done),
      .i_slice_overflow(mirror_overflow_q)
  );

  // div4-domain reset for the writer's engine (the external reset, resynced).
  (* ASYNC_REG = "TRUE" *) logic [1:0] rst_div4_sync;
  always_ff @(posedge i_clk_div4) rst_div4_sync <= {rst_div4_sync[0], i_rst};
  logic rst_div4;
  assign rst_div4 = rst_div4_sync[1];

  // Programming-port face: the loader owns the port whenever it is enabled;
  // the slice writer drives it otherwise.
  logic [31:0] slice_port_a_addr, slice_port_a_data;
  logic slice_imem_we, slice_dmem_we;
  logic [63:0] dmem_port_a_rd_data;
  debug_slice_writer #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth)
  ) u_slice_writer (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_req_valid(slice_req_valid),
      .i_req_mirror(slice_req_mirror),
      .i_req_word_addr(slice_req_word_addr),
      .i_req_data(slice_req_data),
      .o_req_ready(slice_req_ready),
      .o_all_done(slice_all_done),
      .i_clk_div4(i_clk_div4),
      .i_rst_div4(rst_div4),
      .i_port_busy(i_instr_mem_en),
      .o_port_a_byte_addr(slice_port_a_addr),
      .o_port_a_data(slice_port_a_data),
      .o_imem_we(slice_imem_we),
      .o_dmem_we(slice_dmem_we),
      .i_dmem_rd_data(dmem_port_a_rd_data)
  );
  logic [31:0] prog_port_addr, prog_port_data;
  logic prog_port_in_imem;
  logic prog_port_imem_we;
  logic [3:0] prog_port_dmem_we;
  assign prog_port_addr = i_instr_mem_en ? i_instr_mem_addr : slice_port_a_addr;
  assign prog_port_data = i_instr_mem_en ? i_instr_mem_wrdata : slice_port_a_data;
  // Writes above the code region update only the data copy, without aliasing
  // onto code. The instruction copy covers the first 2**ImemByteAddrWidth
  // bytes of the data copy.
  if (ImemByteAddrWidth < MemByteAddrWidth) begin : gen_prog_port_code_region
    assign prog_port_in_imem = (prog_port_addr[MemByteAddrWidth-1:ImemByteAddrWidth] == '0);
  end else begin : gen_prog_port_whole_bram
    assign prog_port_in_imem = 1'b1;
  end
  assign prog_port_imem_we = prog_port_in_imem &&
      (i_instr_mem_en ? (|i_instr_mem_we) : slice_imem_we);
  assign prog_port_dmem_we = i_instr_mem_en ? i_instr_mem_we : {4{slice_dmem_we}};

`ifdef FROST_RVFI_DII
  // TestRIG RVFI-DII harness (simulation only, hw/sim/frost_rvfi_dii.sv): it
  // serves instruction fetch from the injected stream in place of the
  // instruction memory, records each retired or trapped instruction, and
  // stands in for the devices. It reads the core's retirement, redirect, and
  // memory-write signals hierarchically.
  logic [riscv_pkg::MemDataBits-1:0] rvfi_dii_device_read_data;
  frost_rvfi_dii u_rvfi_dii (
      .i_clk,
      .i_rst(rst_core),
      .i_fetch_address(fetch_address),
      .i_fetch_parity(fetch_pa_word0[2]),
      .o_fetch_data(bram_fetch_instr),
      .o_fetch_data_by_parity(bram_fetch_instr_by_parity),
      .o_fetch_sideband(bram_fetch_sideband),
      .o_fetch_pc_metadata(bram_fetch_pc_metadata),
      .o_fetch_pc_metadata_by_parity(bram_fetch_pc_metadata_by_parity),
      .o_fetch_pc_pairability_by_parity(bram_fetch_pc_pairability_by_parity),
      .o_fetch_slot2_start_valid_lo_by_parity(bram_fetch_slot2_start_valid_lo_by_parity),
      .o_fetch_bank_sel_r(bram_fetch_bank_sel_r),
      .i_npc_sel(cpu_inst.if_stage_inst.pc_controller_inst.npc_sel),
      .i_pc_update_en(cpu_inst.if_stage_inst.pc_controller_inst.pc_update_en),
      .i_trap_redirect_pc(cpu_inst.if_stage_inst.pc_controller_inst.npc_val[1]),
      .i_fence_redirect_pc(cpu_inst.if_stage_inst.pc_controller_inst.npc_val[2]),
      .i_branch_redirect_pc(cpu_inst.if_stage_inst.pc_controller_inst.npc_val[3]),
      .i_pd_redirect_pc(cpu_inst.if_stage_inst.pc_controller_inst.npc_val[4]),
      .i_pd_branch_pc(cpu_inst.from_pd_to_id.program_counter),
      .i_early_mispredict_active(cpu_inst.early_mispredict_active),
      .i_early_mispredict_tag(cpu_inst.early_mispredict_tag),
      .i_rob_head_ptr(cpu_inst.u_tomasulo.u_rob.head_ptr),
      .i_commit(cpu_inst.rob_commit_comb),
      .i_commit_valid(cpu_inst.rob_commit_valid_raw),
      .i_commit_2(cpu_inst.rob_commit_comb_2),
      .i_commit_2_valid(cpu_inst.rob_commit_2_valid_raw),
      .i_xret_taken(cpu_inst.xret_taken),
      .i_xret_pc(cpu_inst.rob_trap_pc),
      .i_xret_target(cpu_inst.mret_start_is_dret ? cpu_inst.csr_dpc :
                     cpu_inst.mret_start_is_sret ? cpu_inst.csr_sepc : cpu_inst.csr_mepc),
      .i_trap_taken(cpu_inst.trap_taken),
      .i_trap_no_csr(cpu_inst.trap_no_csr),
      .i_trap_to_d(cpu_inst.trap_to_d),
      .i_trap_cause(cpu_inst.trap_cause_internal),
      .i_trap_pc(cpu_inst.trap_pc_internal),
      .i_trap_target(cpu_inst.trap_entry_target),
      .i_priv(cpu_inst.csr_priv),
      .i_csr_wb_pending(cpu_inst.commit_actions_inst.csr_wb_pending),
      .i_csr_wb_data(cpu_inst.commit_actions_inst.csr_read_data),
      .i_sq_commit_valid(cpu_inst.u_tomasulo.sq_commit_valid),
      .i_sq_commit_valid_2(cpu_inst.u_tomasulo.sq_commit_valid_2),
      .i_sq_write_en(cpu_inst.sq_mem_write_en),
      .i_sq_write_addr(cpu_inst.sq_mem_write_addr),
      .i_sq_write_data(cpu_inst.sq_mem_write_data),
      .i_sq_write_strb(cpu_inst.sq_mem_write_byte_en),
      .i_amo_write_en(cpu_inst.amo_mem_write_en),
      .i_amo_write_addr(cpu_inst.amo_mem_write_addr),
      .i_amo_write_data(cpu_inst.amo_mem_write_data),
      .i_amo_write_is_dword(cpu_inst.amo_mem_write_is_dword),
      .i_dev_read_addr(mmio_load_addr),
      .i_dev_read_capture(mmio_read_capture),
      .o_dev_read_data(rvfi_dii_device_read_data),
      .i_dev_write_en(|data_memory_byte_write_enable && riscv_pkg::pma_device_quadrant(
          riscv_pkg::XLEN'(data_memory_address)
      )),
      .i_dev_write_addr(32'(data_memory_address)),
      .i_dev_write_data(data_memory_write_data),
      .i_dev_write_strb(data_memory_byte_write_enable)
  );
  // Every injected window is ready in one cycle.
  assign bram_fetch_window_overlay_hit = 1'b1;
  assign bram_fetch_response_ready = 1'b1;
  // Each TestRIG test starts from zeroed memory: clear the low BRAM data copy
  // in reset (the DDR model and the harness RAM clear themselves).
  always @(posedge i_clk) begin
    if (rst_core) begin
      for (int i = 0; i < 2 ** MemDwordAddrWidth; i++) data_memory.memory[i] = '0;
    end
  end
`else
  // Instruction memory: code-region words with write-time predecode bits.
  // Fetches above this region carry an access fault, so aliased data cannot
  // execute. Port A programs on div4; port B fetches on the main clock.
  imem_predecode #(
      .ADDR_WIDTH(ImemWordAddrWidth),
      .USE_INIT_FILE(1'b1),
      .INIT_FILE("sw.mem"),
      .INIT_ADDR_WIDTH(MemWordAddrWidth)
  ) instruction_memory (
      .i_port_a_rst(power_on_rst_div4),
      .i_port_b_rst(rst_core),
      .i_port_a_clk(i_clk_div4),
      .i_port_a_enable(1'b1),
      // Port A: Instruction programming (div4 clock, write only)
      .i_port_a_byte_address(prog_port_addr),
      .i_port_a_write_data(prog_port_data),
      .i_port_a_write_enable(prog_port_imem_we),
      .o_port_a_read_data(  /* unused - write only */),
      // Port B: Instruction fetch (main clock, read only), at the request's
      // physical word pair (derived directly from the VA in Bare mode).
      .i_port_b_clk(i_clk),
      .i_port_b_enable(1'b1),
      .i_port_b_byte_address(fetch_pa_word0),
      .i_port_b_next_byte_address(fetch_pa_word1),
      .o_port_b_read_data(bram_fetch_instr),
      .o_port_b_read_data_by_parity(bram_fetch_instr_by_parity),
      .o_port_b_sideband(bram_fetch_sideband),
      .o_port_b_pc_metadata(bram_fetch_pc_metadata),
      .o_port_b_pc_metadata_by_parity(bram_fetch_pc_metadata_by_parity),
      .o_port_b_pc_pairability_by_parity(bram_fetch_pc_pairability_by_parity),
      .o_port_b_slot2_start_valid_lo_by_parity(bram_fetch_slot2_start_valid_lo_by_parity),
      .o_port_b_window_overlay_hit(bram_fetch_window_overlay_hit),
      .o_port_b_response_ready(bram_fetch_response_ready),
      .o_port_b_bank_sel_r(bram_fetch_bank_sel_r)
  );
`endif

  // Local copy of imem_predecode.bank_sel_r, for fanout. Virtual served tags
  // and fault flags register beside it; validity remains with the presenter.
  always_ff @(posedge i_clk) begin
    // Parity must match the physical word read. Visible Sv39 results share
    // VA and PA bit 2 (page offset); fetch_pa_ok blocks unresolved results.
    bram_fetch_bank_sel_cpu_r <= fetch_pa_word0[2];
    bram_fetch_served_word_q <= fetch_request_pc[riscv_pkg::XLEN-1:2];
    bram_fetch_served_last_word_q <= fetch_request_pc[riscv_pkg::XLEN-1:2] + 1'b1;
    bram_fetch_served_prev_word_q <= fetch_request_pc[riscv_pkg::XLEN-1:2] - 1'b1;
    bram_fetch_served_prev_word_valid_q <= |fetch_request_pc[riscv_pkg::XLEN-1:2];
`ifdef FROST_RVFI_DII
    // TestRIG: injected instructions need no memory, and the reference model
    // checks only translation for them, so drop instruction access faults
    // and keep page faults. This also drops the access fault of an
    // instruction page-table walk that reads outside DDR, which the default
    // TestRIG templates never produce.
    bram_fetch_fault0_q <= fetch_word0_fault && fetch_word0_fault_page;
    bram_fetch_fault0_page_q <= fetch_word0_fault_page;
    bram_fetch_fault1_q <= fetch_word1_fault && fetch_word1_fault_page;
    bram_fetch_fault1_page_q <= fetch_word1_fault_page;
`else
    bram_fetch_fault0_q <= fetch_word0_fault;
    bram_fetch_fault0_page_q <= fetch_word0_fault_page;
    bram_fetch_fault1_q <= fetch_word1_fault;
    bram_fetch_fault1_page_q <= fetch_word1_fault_page;
`endif
  end

`ifndef SYNTHESIS
  logic bram_fetch_bank_sel_compare_valid;
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      bram_fetch_bank_sel_compare_valid <= 1'b0;
    end else begin
      if (bram_fetch_bank_sel_compare_valid) begin
        assert (bram_fetch_bank_sel_cpu_r == bram_fetch_bank_sel_r)
        else $error("BRAM fetch bank-select CPU copy diverged from imem_predecode");
      end
      bram_fetch_bank_sel_compare_valid <= 1'b1;
    end
  end
`endif

  // Memory 1: Data memory. One MemDataBits-wide byte-enabled BRAM carrying
  // the aligned-dword bus view (hw/rtl/README.md, "Data-tier bus contract").
  // Rows are dwords, so the row address width drops by one. Init comes from
  // sw64.mem (64-bit $readmemh tokens paired from sw.mem by the build; sw.mem
  // itself stays the 32-bit-word format every loader and imem consumes).
  // Port A: programming writes (div4 clock, fanned out from the instruction
  // port) and the debug slice writer's mirror reads
  // Port B: Data access (main clock, loads/stores from CPU)

  // Port A keeps a 32-bit programming face: the word write is steered into
  // the addressed half of the dword row (addr[2] selects the strobe nibble),
  // so the JTAG loader and the slice writer write plain 32-bit words.
  logic [riscv_pkg::MemStrbBits-1:0] instr_mem_dword_we;
  assign instr_mem_dword_we =
      prog_port_addr[2] ? {prog_port_dmem_we, 4'b0000} : {4'b0000, prog_port_dmem_we};

  tdp_bram_dc_byte_en #(
      .DATA_WIDTH(riscv_pkg::MemDataBits),
      .ADDR_WIDTH(MemDwordAddrWidth),
      .USE_INIT_FILE(1'b1),
      .INIT_FILE("sw64.mem")  // Software initialization file (dword tokens)
  ) data_memory (
      .i_port_a_clk(i_clk_div4),
      .i_port_b_clk(i_clk),
      // Port A: programming writes (div4 clock)
      .i_port_a_byte_address(riscv_pkg::MemDataBits'(prog_port_addr)),
      .i_port_a_write_data({2{prog_port_data}}),
      .i_port_a_byte_write_enable(instr_mem_dword_we),
      // Read side: the debug slice writer's mirror reads the row it copies
      // into the instruction copy.
      .o_port_a_read_data(dmem_port_a_rd_data),
      // Port B: Data memory for loads and stores
      .i_port_b_byte_address(riscv_pkg::MemDataBits'(data_memory_address)),
      .i_port_b_write_data(data_memory_write_data),
      .i_port_b_byte_write_enable(data_memory_bram_byte_write_enable),
      .o_port_b_read_data(data_memory_read_data)
  );

  // Cached requests pass through the hierarchy and AXI bridge. The
  // behavioral DDR model initializes from sw_ddr.mem and retains data across
  // CPU resets. Hardware exports AXI to the board's DDR controller.
  if (ENABLE_CACHED_TIER != 0) begin : gen_cached_tier
    // The hierarchy's DMA port: the NIC (port 0) and the DMA test engine
    // (port 1) are AXI4 masters on dma_interconnect, whose master enters the
    // port through dma_bridge, as in soc_top. The bridge's 3-bit line ids
    // fill the low bits of the port's LineIdBits-bit ids, so bit 3 stays
    // clear, which the hierarchy's stream prefetcher needs.
    localparam int unsigned DmaPorts = 2;
    localparam int unsigned DmaAxiAddrBits = 64;
    localparam int unsigned DmaAxiDataBits = 8 * L1LineBytes;
    localparam int unsigned DmaUpIdBits = 3;
    localparam int unsigned DmaDownIdBits = DmaUpIdBits + 1;
    localparam int unsigned DmaLineIdBits = 3;
    logic dma_req_valid, dma_req_ready, dma_req_write;
    logic [riscv_pkg::PhysAddrBits-1:0] dma_req_addr;
    logic [L1LineBytes*8-1:0] dma_req_wdata;
    logic [L1LineBytes-1:0] dma_req_wstrb;
    logic [LineIdBits-1:0] dma_req_id;
    logic [DmaLineIdBits-1:0] dma_line_req_id;
    logic dma_resp_valid, dma_resp_error;
    logic [LineIdBits-1:0] dma_resp_id;
    logic [L1LineBytes*8-1:0] dma_resp_rdata;
    /* verilator lint_off UNUSEDSIGNAL */  // the bridge's ids fill the low bits
    logic dma_resp_id_high_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign dma_req_id = LineIdBits'(dma_line_req_id);
    assign dma_resp_id_high_unused = |dma_resp_id[LineIdBits-1:DmaLineIdBits];

    logic [DmaPorts-1:0] up_awvalid, up_awready, up_awlock, up_wvalid, up_wready, up_wlast;
    logic [DmaPorts-1:0] up_bvalid, up_bready, up_arvalid, up_arready, up_arlock;
    logic [DmaPorts-1:0] up_rvalid, up_rready, up_rlast;
    logic [DmaPorts-1:0][DmaUpIdBits-1:0] up_awid, up_bid, up_arid, up_rid;
    logic [DmaPorts-1:0][DmaAxiAddrBits-1:0] up_awaddr, up_araddr;
    logic [DmaPorts-1:0][7:0] up_awlen, up_arlen;
    logic [DmaPorts-1:0][2:0] up_awsize, up_arsize, up_awprot, up_arprot;
    logic [DmaPorts-1:0][1:0] up_awburst, up_arburst, up_bresp, up_rresp;
    logic [DmaPorts-1:0][3:0] up_awcache, up_arcache, up_awqos, up_arqos;
    logic [DmaPorts-1:0][DmaAxiDataBits-1:0] up_wdata, up_rdata;
    logic [DmaPorts-1:0][DmaAxiDataBits/8-1:0] up_wstrb;
    logic dn_awvalid, dn_awready, dn_awlock, dn_wvalid, dn_wready, dn_wlast;
    logic dn_bvalid, dn_bready, dn_arvalid, dn_arready, dn_arlock, dn_rvalid, dn_rready, dn_rlast;
    logic [DmaDownIdBits-1:0] dn_awid, dn_bid, dn_arid, dn_rid;
    logic [DmaAxiAddrBits-1:0] dn_awaddr, dn_araddr;
    logic [7:0] dn_awlen, dn_arlen;
    logic [2:0] dn_awsize, dn_arsize, dn_awprot, dn_arprot;
    logic [1:0] dn_awburst, dn_arburst, dn_bresp, dn_rresp;
    logic [3:0] dn_awcache, dn_arcache, dn_awqos, dn_arqos;
    logic [DmaAxiDataBits-1:0] dn_wdata, dn_rdata;
    logic [DmaAxiDataBits/8-1:0] dn_wstrb;

    logic line_req_valid, line_req_ready, line_req_write;
    logic [riscv_pkg::PhysAddrBits-1:0] line_req_addr;
    logic [L1LineBytes*8-1:0] line_req_wdata;
    logic [L1LineBytes-1:0] line_req_wstrb;
    logic [LineIdBits-1:0] line_req_id;
    logic line_resp_valid;
    logic [LineIdBits-1:0] line_resp_id;
    logic [L1LineBytes*8-1:0] line_resp_rdata;

    cached_tier_adapter #(
        .XLEN(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L1LineBytes),
        .LINE_ID_BITS(LineIdBits),
        .SPLIT_READ_REQ(1'b1)
    ) cached_adapter (
        .o_read_error(),

        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_read_req(data_memory_cached_read_enable),
        .i_read_req_sel(data_memory_cached_read_sel),
        .i_read_req_if_sel(data_memory_cached_read_if_sel),
        .i_read_req_if_clear(data_memory_cached_read_if_clear),
        .i_read_id(data_memory_cached_read_id),
        .i_read_no_merge(data_memory_cached_read_no_merge),
        .i_req_addr(data_memory_address),
        .i_write_byte_en(data_memory_cached_byte_write_enable),
        .i_write_data(data_memory_cached_write_data),
        .o_read_data(data_memory_cached_read_data),
        .o_read_id(data_memory_cached_resp_id),
        .o_read_valid(data_memory_cached_read_valid),
        .i_read_ready(data_memory_cached_read_ready),
        .o_write_done(data_memory_cached_write_done),
        .o_write_inflight(data_memory_cached_write_inflight),
        .o_line_req_valid(line_req_valid),
        .i_line_req_ready(line_req_ready),
        .o_line_req_write(line_req_write),
        .o_line_req_addr(line_req_addr),
        .o_line_req_wdata(line_req_wdata),
        .o_line_req_wstrb(line_req_wstrb),
        .o_line_req_id(line_req_id),
        .i_line_resp_valid(line_resp_valid),
        .i_line_resp_id(line_resp_id),
        .i_line_resp_rdata(line_resp_rdata)
    );

    logic down_req_valid, down_req_ready, down_req_write;
    logic [riscv_pkg::PhysAddrBits-1:0] down_req_addr;
    logic [L2_LINE_BYTES*8-1:0] down_req_wdata;
    logic [L2_LINE_BYTES-1:0] down_req_wstrb;
    logic [DdrAxiIdBits-1:0] down_req_id;
    logic down_resp_valid;
    logic [DdrAxiIdBits-1:0] down_resp_id;
    logic [L2_LINE_BYTES*8-1:0] down_resp_rdata;

    frost_cache_hierarchy #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .L1_LINE_BYTES(L1LineBytes),
        .L2_LINE_BYTES(L2_LINE_BYTES),
        .UP_ID_BITS(LineIdBits),
        .L1_CACHE_BYTES(L1_CACHE_BYTES),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L2_CACHE_BYTES(L2_CACHE_BYTES),
        .L1D_WAYS(L1D_WAYS),
        .L1I_WAYS(L1I_WAYS),
        .L2_WAYS(L2_WAYS),
        .L1D_NUM_MSHR(L1D_NUM_MSHR),
        .L2_NUM_MSHR(L2_NUM_MSHR),
        .L2_NUM_WAITERS(L2_NUM_WAITERS),
        .L2_PREFETCH(L2_PREFETCH),
        .L2_PREFETCH_DISTANCE(L2_PREFETCH_DISTANCE),
        .L2_PREFETCH_INFLIGHT(L2_PREFETCH_INFLIGHT),
        .L2_NUM_WB(L2_NUM_WB),
        .L2_DOWN_ID_BITS(DdrAxiIdBits),
        .SIM_FAST_MAINT(SIM_FAST_MAINT),
        .NUM_DMA_LOCK(riscv_pkg::DmaCoherenceLocks)
    ) cache_hierarchy (
        .o_up_resp_error(),
        .o_iup_resp_error(),
        .o_wup_resp_error(),
        .o_dma_resp_error(dma_resp_error),
        .o_fatal_error(),
        .o_fatal_addr(),

        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_up_req_valid(line_req_valid),
        .o_up_req_ready(line_req_ready),
        .i_up_req_write(line_req_write),
        .i_up_req_addr(line_req_addr),
        .i_up_req_wdata(line_req_wdata),
        .i_up_req_wstrb(line_req_wstrb),
        .i_up_req_id(line_req_id),
        .o_up_resp_valid(line_resp_valid),
        .o_up_resp_id(line_resp_id),
        .o_up_resp_rdata(line_resp_rdata),
        .i_iup_req_valid(iup_req_valid),
        .o_iup_req_ready(iup_req_ready),
        .i_iup_req_write(iup_req_write),
        .i_iup_req_addr(iup_req_addr),
        .i_iup_req_wdata(iup_req_wdata),
        .i_iup_req_wstrb(iup_req_wstrb),
        .i_iup_req_id(iup_req_id),
        .o_iup_resp_valid(iup_resp_valid),
        .o_iup_resp_id(iup_resp_id),
        .o_iup_resp_rdata(iup_resp_rdata),
        // Page-table walker port: the core's ptw line master (read-only).
        .i_wup_req_valid(walk_line_req_valid),
        .o_wup_req_ready(walk_line_req_ready),
        .i_wup_req_write(1'b0),
        .i_wup_req_addr(walk_line_req_addr),
        .i_wup_req_wdata('0),
        .i_wup_req_wstrb('0),
        .i_wup_req_id(walk_line_req_id),
        .o_wup_resp_valid(walk_line_resp_valid),
        .o_wup_resp_id(walk_line_resp_id),
        .o_wup_resp_rdata(walk_line_resp_rdata),
        // DMA port: the NIC and the DMA test engine through dma_bridge below.
        // The coherence handshake runs to the core's lq_coherence_port.
        .i_dma_req_valid(dma_req_valid),
        .o_dma_req_ready(dma_req_ready),
        .i_dma_req_write(dma_req_write),
        .i_dma_req_addr(dma_req_addr),
        .i_dma_req_wdata(dma_req_wdata),
        .i_dma_req_wstrb(dma_req_wstrb),
        .i_dma_req_id(dma_req_id),
        .o_dma_resp_valid(dma_resp_valid),
        .o_dma_resp_id(dma_resp_id),
        .o_dma_resp_rdata(dma_resp_rdata),
        .o_coh_admit_valid(coh_admit_valid),
        .o_coh_admit_slot(coh_admit_slot),
        .o_coh_admit_addr(coh_admit_addr),
        .i_coh_admit_ready(coh_admit_ready),
        .o_coh_inval_valid(coh_inval_valid),
        .o_coh_inval_slot(coh_inval_slot),
        .i_coh_inval_done(coh_inval_done),
        .o_coh_release_valid(coh_release_valid),
        .o_coh_release_slot(coh_release_slot),
        .i_fence_sync(fence_i_sync_req),
        .o_fence_done(fence_i_sync_done),
        .o_perf_events(cache_hierarchy_perf_events),
        .o_down_req_valid(down_req_valid),
        .i_down_req_ready(down_req_ready),
        .o_down_req_write(down_req_write),
        .o_down_req_addr(down_req_addr),
        .o_down_req_wdata(down_req_wdata),
        .o_down_req_wstrb(down_req_wstrb),
        .o_down_req_id(down_req_id),
        .i_down_resp_valid(down_resp_valid),
        .i_down_resp_id(down_resp_id),
        .i_down_resp_rdata(down_resp_rdata)
    );

    nic_top #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L1LineBytes),
        .APERTURE_BASE(64'(CACHED_BASE)),
        .APERTURE_BYTES(CACHED_SIZE_BYTES),
        .TICK_DEFAULT(CLK_FREQ_HZ / 1_000_000),
        .RAW_LOOPBACK(RAW_LOOPBACK),
        .DMA_AXI_ADDR_BITS(DmaAxiAddrBits),
        .DMA_AXI_ID_BITS(DmaUpIdBits)
    ) nic (
        .i_clk(i_clk),
        .i_rst(rst_core_next),  // registered inside nic_top; see its header
        // Device accesses use the TestRIG shadow RAM.
        .i_reg_axil_awvalid('0),
        .o_reg_axil_awready(),
        .i_reg_axil_awaddr('0),
        .i_reg_axil_awprot('0),
        .i_reg_axil_wvalid('0),
        .o_reg_axil_wready(),
        .i_reg_axil_wdata('0),
        .i_reg_axil_wstrb('0),
        .o_reg_axil_bvalid(),
        .i_reg_axil_bready('0),
        .o_reg_axil_bresp(),
        .i_reg_axil_arvalid('0),
        .o_reg_axil_arready(),
        .i_reg_axil_araddr('0),
        .i_reg_axil_arprot('0),
        .o_reg_axil_rvalid(),
        .i_reg_axil_rready('0),
        .o_reg_axil_rdata(),
        .o_reg_axil_rresp(),
        .o_irq(nic_irq),
        .o_dma_axi_awvalid(up_awvalid[0]),
        .o_dma_axi_awid(up_awid[0]),
        .o_dma_axi_awaddr(up_awaddr[0]),
        .o_dma_axi_awlen(up_awlen[0]),
        .o_dma_axi_awsize(up_awsize[0]),
        .o_dma_axi_awburst(up_awburst[0]),
        .o_dma_axi_awlock(up_awlock[0]),
        .o_dma_axi_awcache(up_awcache[0]),
        .o_dma_axi_awprot(up_awprot[0]),
        .o_dma_axi_awqos(up_awqos[0]),
        .o_dma_axi_wvalid(up_wvalid[0]),
        .o_dma_axi_wdata(up_wdata[0]),
        .o_dma_axi_wstrb(up_wstrb[0]),
        .o_dma_axi_wlast(up_wlast[0]),
        .o_dma_axi_bready(up_bready[0]),
        .o_dma_axi_arvalid(up_arvalid[0]),
        .o_dma_axi_arid(up_arid[0]),
        .o_dma_axi_araddr(up_araddr[0]),
        .o_dma_axi_arlen(up_arlen[0]),
        .o_dma_axi_arsize(up_arsize[0]),
        .o_dma_axi_arburst(up_arburst[0]),
        .o_dma_axi_arlock(up_arlock[0]),
        .o_dma_axi_arcache(up_arcache[0]),
        .o_dma_axi_arprot(up_arprot[0]),
        .o_dma_axi_arqos(up_arqos[0]),
        .o_dma_axi_rready(up_rready[0]),
        .i_dma_axi_awready(up_awready[0]),
        .i_dma_axi_wready(up_wready[0]),
        .i_dma_axi_bvalid(up_bvalid[0]),
        .i_dma_axi_bid(up_bid[0]),
        .i_dma_axi_bresp(up_bresp[0]),
        .i_dma_axi_arready(up_arready[0]),
        .i_dma_axi_rvalid(up_rvalid[0]),
        .i_dma_axi_rid(up_rid[0]),
        .i_dma_axi_rdata(up_rdata[0]),
        .i_dma_axi_rresp(up_rresp[0]),
        .i_dma_axi_rlast(up_rlast[0]),
        .i_tx_clk(i_nic_tx_clk),
        .i_rx_clk(i_nic_rx_clk),
        .i_tx_clk_ok(i_nic_tx_clk_ok),
        .i_rx_clk_ok(i_nic_rx_clk_ok),
        .o_tx_raw_data(o_nic_tx_raw_data),
        .o_tx_raw_valid(o_nic_tx_raw_valid),
        .i_rx_raw_data(i_nic_rx_raw_data),
        .i_rx_raw_valid(i_nic_rx_raw_valid),
        .i_rx_signal_ok(i_nic_rx_signal_ok),
        .i_phy_status(i_nic_phy_status),
        .o_phy_ctrl(o_nic_phy_ctrl),
        .o_rx_block_lock(o_nic_rx_block_lock)
    );

    dma_test_engine_axi #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L1LineBytes),
        .ID_BITS(2),
        .APERTURE_BASE(64'(CACHED_BASE)),
        .APERTURE_BYTES(CACHED_SIZE_BYTES),
        .DMA_AXI_ADDR_BITS(DmaAxiAddrBits),
        .DMA_AXI_ID_BITS(DmaUpIdBits)
    ) dma_engine (
        .i_clk(i_clk),
        .i_rst(rst_core),
        // Device accesses use the TestRIG shadow RAM.
        .i_reg_axil_awvalid('0),
        .o_reg_axil_awready(),
        .i_reg_axil_awaddr('0),
        .i_reg_axil_awprot('0),
        .i_reg_axil_wvalid('0),
        .o_reg_axil_wready(),
        .i_reg_axil_wdata('0),
        .i_reg_axil_wstrb('0),
        .o_reg_axil_bvalid(),
        .i_reg_axil_bready('0),
        .o_reg_axil_bresp(),
        .i_reg_axil_arvalid('0),
        .o_reg_axil_arready(),
        .i_reg_axil_araddr('0),
        .i_reg_axil_arprot('0),
        .o_reg_axil_rvalid(),
        .i_reg_axil_rready('0),
        .o_reg_axil_rdata(),
        .o_reg_axil_rresp(),
        .o_irq(dma_engine_irq),
        .o_dma_axi_awvalid(up_awvalid[1]),
        .o_dma_axi_awid(up_awid[1]),
        .o_dma_axi_awaddr(up_awaddr[1]),
        .o_dma_axi_awlen(up_awlen[1]),
        .o_dma_axi_awsize(up_awsize[1]),
        .o_dma_axi_awburst(up_awburst[1]),
        .o_dma_axi_awlock(up_awlock[1]),
        .o_dma_axi_awcache(up_awcache[1]),
        .o_dma_axi_awprot(up_awprot[1]),
        .o_dma_axi_awqos(up_awqos[1]),
        .o_dma_axi_wvalid(up_wvalid[1]),
        .o_dma_axi_wdata(up_wdata[1]),
        .o_dma_axi_wstrb(up_wstrb[1]),
        .o_dma_axi_wlast(up_wlast[1]),
        .o_dma_axi_bready(up_bready[1]),
        .o_dma_axi_arvalid(up_arvalid[1]),
        .o_dma_axi_arid(up_arid[1]),
        .o_dma_axi_araddr(up_araddr[1]),
        .o_dma_axi_arlen(up_arlen[1]),
        .o_dma_axi_arsize(up_arsize[1]),
        .o_dma_axi_arburst(up_arburst[1]),
        .o_dma_axi_arlock(up_arlock[1]),
        .o_dma_axi_arcache(up_arcache[1]),
        .o_dma_axi_arprot(up_arprot[1]),
        .o_dma_axi_arqos(up_arqos[1]),
        .o_dma_axi_rready(up_rready[1]),
        .i_dma_axi_awready(up_awready[1]),
        .i_dma_axi_wready(up_wready[1]),
        .i_dma_axi_bvalid(up_bvalid[1]),
        .i_dma_axi_bid(up_bid[1]),
        .i_dma_axi_bresp(up_bresp[1]),
        .i_dma_axi_arready(up_arready[1]),
        .i_dma_axi_rvalid(up_rvalid[1]),
        .i_dma_axi_rid(up_rid[1]),
        .i_dma_axi_rdata(up_rdata[1]),
        .i_dma_axi_rresp(up_rresp[1]),
        .i_dma_axi_rlast(up_rlast[1])
    );

    axi_mux #(
        .NUM_PORTS(DmaPorts),
        .ADDR_WIDTH(DmaAxiAddrBits),
        .DATA_WIDTH(DmaAxiDataBits),
        .UP_ID_WIDTH(DmaUpIdBits),
        .W_DEPTH(4)
    ) dma_interconnect (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_up_awvalid(up_awvalid),
        .i_up_awid(up_awid),
        .i_up_awaddr(up_awaddr),
        .i_up_awlen(up_awlen),
        .i_up_awsize(up_awsize),
        .i_up_awburst(up_awburst),
        .i_up_awlock(up_awlock),
        .i_up_awcache(up_awcache),
        .i_up_awprot(up_awprot),
        .i_up_awqos(up_awqos),
        .i_up_wvalid(up_wvalid),
        .i_up_wdata(up_wdata),
        .i_up_wstrb(up_wstrb),
        .i_up_wlast(up_wlast),
        .i_up_bready(up_bready),
        .i_up_arvalid(up_arvalid),
        .i_up_arid(up_arid),
        .i_up_araddr(up_araddr),
        .i_up_arlen(up_arlen),
        .i_up_arsize(up_arsize),
        .i_up_arburst(up_arburst),
        .i_up_arlock(up_arlock),
        .i_up_arcache(up_arcache),
        .i_up_arprot(up_arprot),
        .i_up_arqos(up_arqos),
        .i_up_rready(up_rready),
        .o_up_awready(up_awready),
        .o_up_wready(up_wready),
        .o_up_bvalid(up_bvalid),
        .o_up_bid(up_bid),
        .o_up_bresp(up_bresp),
        .o_up_arready(up_arready),
        .o_up_rvalid(up_rvalid),
        .o_up_rid(up_rid),
        .o_up_rdata(up_rdata),
        .o_up_rresp(up_rresp),
        .o_up_rlast(up_rlast),
        .o_dn_awvalid(dn_awvalid),
        .o_dn_awid(dn_awid),
        .o_dn_awaddr(dn_awaddr),
        .o_dn_awlen(dn_awlen),
        .o_dn_awsize(dn_awsize),
        .o_dn_awburst(dn_awburst),
        .o_dn_awlock(dn_awlock),
        .o_dn_awcache(dn_awcache),
        .o_dn_awprot(dn_awprot),
        .o_dn_awqos(dn_awqos),
        .o_dn_wvalid(dn_wvalid),
        .o_dn_wdata(dn_wdata),
        .o_dn_wstrb(dn_wstrb),
        .o_dn_wlast(dn_wlast),
        .o_dn_bready(dn_bready),
        .o_dn_arvalid(dn_arvalid),
        .o_dn_arid(dn_arid),
        .o_dn_araddr(dn_araddr),
        .o_dn_arlen(dn_arlen),
        .o_dn_arsize(dn_arsize),
        .o_dn_arburst(dn_arburst),
        .o_dn_arlock(dn_arlock),
        .o_dn_arcache(dn_arcache),
        .o_dn_arprot(dn_arprot),
        .o_dn_arqos(dn_arqos),
        .o_dn_rready(dn_rready),
        .i_dn_awready(dn_awready),
        .i_dn_wready(dn_wready),
        .i_dn_bvalid(dn_bvalid),
        .i_dn_bid(dn_bid),
        .i_dn_bresp(dn_bresp),
        .i_dn_arready(dn_arready),
        .i_dn_rvalid(dn_rvalid),
        .i_dn_rid(dn_rid),
        .i_dn_rdata(dn_rdata),
        .i_dn_rresp(dn_rresp),
        .i_dn_rlast(dn_rlast)
    );

    axi_coherent_bridge #(
        .ADDR_WIDTH(DmaAxiAddrBits),
        .DATA_WIDTH(DmaAxiDataBits),
        .ID_WIDTH(DmaDownIdBits),
        .LINE_ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_ID_BITS(DmaLineIdBits),
        .REGION_BASE(64'(CACHED_BASE)),
        .REGION_BYTES(CACHED_SIZE_BYTES)
    ) dma_bridge (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_axi_awvalid(dn_awvalid),
        .i_axi_awid(dn_awid),
        .i_axi_awaddr(dn_awaddr),
        .i_axi_awlen(dn_awlen),
        .i_axi_awsize(dn_awsize),
        .i_axi_awburst(dn_awburst),
        .i_axi_awlock(dn_awlock),
        .i_axi_awcache(dn_awcache),
        .i_axi_awprot(dn_awprot),
        .i_axi_awqos(dn_awqos),
        .i_axi_wvalid(dn_wvalid),
        .i_axi_wdata(dn_wdata),
        .i_axi_wstrb(dn_wstrb),
        .i_axi_wlast(dn_wlast),
        .i_axi_bready(dn_bready),
        .i_axi_arvalid(dn_arvalid),
        .i_axi_arid(dn_arid),
        .i_axi_araddr(dn_araddr),
        .i_axi_arlen(dn_arlen),
        .i_axi_arsize(dn_arsize),
        .i_axi_arburst(dn_arburst),
        .i_axi_arlock(dn_arlock),
        .i_axi_arcache(dn_arcache),
        .i_axi_arprot(dn_arprot),
        .i_axi_arqos(dn_arqos),
        .i_axi_rready(dn_rready),
        .o_axi_awready(dn_awready),
        .o_axi_wready(dn_wready),
        .o_axi_bvalid(dn_bvalid),
        .o_axi_bid(dn_bid),
        .o_axi_bresp(dn_bresp),
        .o_axi_arready(dn_arready),
        .o_axi_rvalid(dn_rvalid),
        .o_axi_rid(dn_rid),
        .o_axi_rdata(dn_rdata),
        .o_axi_rresp(dn_rresp),
        .o_axi_rlast(dn_rlast),
        .o_line_req_valid(dma_req_valid),
        .i_line_req_ready(dma_req_ready),
        .o_line_req_write(dma_req_write),
        .o_line_req_addr(dma_req_addr),
        .o_line_req_wdata(dma_req_wdata),
        .o_line_req_wstrb(dma_req_wstrb),
        .o_line_req_id(dma_line_req_id),
        .i_line_resp_valid(dma_resp_valid),
        .i_line_resp_id(dma_resp_id[DmaLineIdBits-1:0]),
        .i_line_resp_rdata(dma_resp_rdata),
        .i_line_resp_error(dma_resp_error)
    );

`ifndef SYNTHESIS
    // Protocol checks on the two masters' ports and the bridge's.
    for (genvar g = 0; g < DmaPorts; g++) begin : gen_dma_port_check
      axi_checker #(
          .ADDR_WIDTH(DmaAxiAddrBits),
          .DATA_WIDTH(DmaAxiDataBits),
          .ID_WIDTH(DmaUpIdBits),
          .PORT(g)
      ) u_check (
          .i_clk(i_clk),
          .i_rst(rst_core),
          .i_awvalid(up_awvalid[g]),
          .i_awready(up_awready[g]),
          .i_awid(up_awid[g]),
          .i_awaddr(up_awaddr[g]),
          .i_awlen(up_awlen[g]),
          .i_awsize(up_awsize[g]),
          .i_awburst(up_awburst[g]),
          .i_awlock(up_awlock[g]),
          .i_wvalid(up_wvalid[g]),
          .i_wready(up_wready[g]),
          .i_wdata(up_wdata[g]),
          .i_wstrb(up_wstrb[g]),
          .i_wlast(up_wlast[g]),
          .i_bvalid(up_bvalid[g]),
          .i_bready(up_bready[g]),
          .i_bid(up_bid[g]),
          .i_bresp(up_bresp[g]),
          .i_arvalid(up_arvalid[g]),
          .i_arready(up_arready[g]),
          .i_arid(up_arid[g]),
          .i_araddr(up_araddr[g]),
          .i_arlen(up_arlen[g]),
          .i_arsize(up_arsize[g]),
          .i_arburst(up_arburst[g]),
          .i_arlock(up_arlock[g]),
          .i_rvalid(up_rvalid[g]),
          .i_rready(up_rready[g]),
          .i_rid(up_rid[g]),
          .i_rdata(up_rdata[g]),
          .i_rresp(up_rresp[g]),
          .i_rlast(up_rlast[g])
      );
    end
    axi_checker #(
        .ADDR_WIDTH(DmaAxiAddrBits),
        .DATA_WIDTH(DmaAxiDataBits),
        .ID_WIDTH(DmaDownIdBits),
        .PORT(DmaPorts)
    ) u_dma_bridge_check (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_awvalid(dn_awvalid),
        .i_awready(dn_awready),
        .i_awid(dn_awid),
        .i_awaddr(dn_awaddr),
        .i_awlen(dn_awlen),
        .i_awsize(dn_awsize),
        .i_awburst(dn_awburst),
        .i_awlock(dn_awlock),
        .i_wvalid(dn_wvalid),
        .i_wready(dn_wready),
        .i_wdata(dn_wdata),
        .i_wstrb(dn_wstrb),
        .i_wlast(dn_wlast),
        .i_bvalid(dn_bvalid),
        .i_bready(dn_bready),
        .i_bid(dn_bid),
        .i_bresp(dn_bresp),
        .i_arvalid(dn_arvalid),
        .i_arready(dn_arready),
        .i_arid(dn_arid),
        .i_araddr(dn_araddr),
        .i_arlen(dn_arlen),
        .i_arsize(dn_arsize),
        .i_arburst(dn_arburst),
        .i_arlock(dn_arlock),
        .i_rvalid(dn_rvalid),
        .i_rready(dn_rready),
        .i_rid(dn_rid),
        .i_rdata(dn_rdata),
        .i_rresp(dn_rresp),
        .i_rlast(dn_rlast)
    );
`endif

    logic axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
    logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast, axi_wlast;
    logic [riscv_pkg::DdrAxiAddrBits-1:0] axi_awaddr, axi_araddr;
    logic [7:0] axi_awlen, axi_arlen;
    logic [2:0] axi_awsize, axi_arsize;
    logic [1:0] axi_awburst, axi_arburst, axi_bresp, axi_rresp;
    logic [L2_LINE_BYTES*8-1:0] axi_wdata, axi_rdata;
    logic [L2_LINE_BYTES-1:0] axi_wstrb;
    logic [DdrAxiIdBits-1:0] axi_awid, axi_arid, axi_bid, axi_rid;

    // The AXI slave's reset: the behavioral memory resets with the CPU, the
    // board's interconnect with its own reset.
    logic ddr_axi_rst;
    assign ddr_axi_rst = (USE_BEHAVIORAL_DDR != 0) ? rst_core : i_ddr_axi_rst;

    line_port_axi_bridge #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .AXI_ADDR_WIDTH(riscv_pkg::DdrAxiAddrBits),
        .LINE_BYTES(L2_LINE_BYTES),
        .ID_BITS(DdrAxiIdBits),
        .AXI_ID_BITS(DdrAxiIdBits),
        .BASE_ADDR(riscv_pkg::PhysAddrBits'(CACHED_BASE))
    ) ddr_bridge (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_axi_rst(ddr_axi_rst),
        .i_req_valid(down_req_valid),
        .o_req_ready(down_req_ready),
        .i_req_write(down_req_write),
        .i_req_addr(down_req_addr),
        .i_req_wdata(down_req_wdata),
        .i_req_wstrb(down_req_wstrb),
        .i_req_id(down_req_id),
        .o_resp_valid(down_resp_valid),
        .o_resp_id(down_resp_id),
        .o_resp_rdata(down_resp_rdata),
        .o_resp_error(),
        .o_axi_awvalid(axi_awvalid),
        .i_axi_awready(axi_awready),
        .o_axi_awid(axi_awid),
        .o_axi_awaddr(axi_awaddr),
        .o_axi_awlen(axi_awlen),
        .o_axi_awsize(axi_awsize),
        .o_axi_awburst(axi_awburst),
        .o_axi_wvalid(axi_wvalid),
        .i_axi_wready(axi_wready),
        .o_axi_wdata(axi_wdata),
        .o_axi_wstrb(axi_wstrb),
        .o_axi_wlast(axi_wlast),
        .i_axi_bvalid(axi_bvalid),
        .o_axi_bready(axi_bready),
        .i_axi_bid(axi_bid),
        .i_axi_bresp(axi_bresp),
        .o_axi_arvalid(axi_arvalid),
        .i_axi_arready(axi_arready),
        .o_axi_arid(axi_arid),
        .o_axi_araddr(axi_araddr),
        .o_axi_arlen(axi_arlen),
        .o_axi_arsize(axi_arsize),
        .o_axi_arburst(axi_arburst),
        .i_axi_rvalid(axi_rvalid),
        .o_axi_rready(axi_rready),
        .i_axi_rid(axi_rid),
        .i_axi_rdata(axi_rdata),
        .i_axi_rresp(axi_rresp),
        .i_axi_rlast(axi_rlast),
        .o_rd_err_valid(ddr_rd_err_valid),
        .o_rd_err_resp(ddr_rd_err_resp),
        .o_rd_err_id(ddr_rd_err_id),
        .o_wr_err_valid(ddr_wr_err_valid),
        .o_wr_err_resp(ddr_wr_err_resp),
        .o_wr_err_id(ddr_wr_err_id)
    );

    if (USE_BEHAVIORAL_DDR != 0) begin : gen_behavioral_ddr
      // Simulation-only main memory; hardware sets USE_BEHAVIORAL_DDR=0 and
      // takes the bridge's AXI out through the o_ddr_axi_* ports instead.
      axi_behavioral_memory #(
          .LINE_BYTES(L2_LINE_BYTES),
          .AXI_ADDR_WIDTH(riscv_pkg::DdrAxiAddrBits),
          .MEM_BYTES(DDR_MODEL_BYTES),
          .NUM_SLOTS(DdrModelSlots),
          .ID_BITS(DdrAxiIdBits),
          .LATENCY(DDR_MODEL_LATENCY),
          .LATENCY_JITTER(DDR_MODEL_LATENCY_JITTER),
          .REORDER(DDR_MODEL_REORDER),
          .USE_INIT_FILE(1'b1),
          .INIT_FILE("sw_ddr.mem")
      ) ddr_model (
          .i_clk(i_clk),
          .i_rst(rst_core),
          .i_axi_awvalid(axi_awvalid),
          .o_axi_awready(axi_awready),
          .i_axi_awid(axi_awid),
          .i_axi_awaddr(axi_awaddr),
          .i_axi_awlen(axi_awlen),
          .i_axi_wvalid(axi_wvalid),
          .o_axi_wready(axi_wready),
          .i_axi_wdata(axi_wdata),
          .i_axi_wstrb(axi_wstrb),
          .o_axi_bvalid(axi_bvalid),
          .i_axi_bready(axi_bready),
          .o_axi_bid(axi_bid),
          .o_axi_bresp(axi_bresp),
          .i_axi_arvalid(axi_arvalid),
          .o_axi_arready(axi_arready),
          .i_axi_arid(axi_arid),
          .i_axi_araddr(axi_araddr),
          .i_axi_arlen(axi_arlen),
          .o_axi_rvalid(axi_rvalid),
          .i_axi_rready(axi_rready),
          .o_axi_rid(axi_rid),
          .o_axi_rdata(axi_rdata),
          .o_axi_rresp(axi_rresp),
          .o_axi_rlast(axi_rlast)
      );
      assign o_ddr_axi_awvalid = 1'b0;
      assign o_ddr_axi_awid    = '0;
      assign o_ddr_axi_awaddr  = '0;
      assign o_ddr_axi_awlen   = '0;
      assign o_ddr_axi_awsize  = '0;
      assign o_ddr_axi_awburst = '0;
      assign o_ddr_axi_wvalid  = 1'b0;
      assign o_ddr_axi_wdata   = '0;
      assign o_ddr_axi_wstrb   = '0;
      assign o_ddr_axi_wlast   = 1'b0;
      assign o_ddr_axi_bready  = 1'b0;
      assign o_ddr_axi_arvalid = 1'b0;
      assign o_ddr_axi_arid    = '0;
      assign o_ddr_axi_araddr  = '0;
      assign o_ddr_axi_arlen   = '0;
      assign o_ddr_axi_arsize  = '0;
      assign o_ddr_axi_arburst = '0;
      assign o_ddr_axi_rready  = 1'b0;
    end else begin : gen_ddr_axi_export
      // Hardware: the bridge's AXI master goes out to the board's DDR
      // controller subsystem.
      assign o_ddr_axi_awvalid = axi_awvalid;
      assign axi_awready = i_ddr_axi_awready;
      assign o_ddr_axi_awid = axi_awid;
      assign o_ddr_axi_awaddr = axi_awaddr;
      assign o_ddr_axi_awlen = axi_awlen;
      assign o_ddr_axi_awsize = axi_awsize;
      assign o_ddr_axi_awburst = axi_awburst;
      assign o_ddr_axi_wvalid = axi_wvalid;
      assign axi_wready = i_ddr_axi_wready;
      assign o_ddr_axi_wdata = axi_wdata;
      assign o_ddr_axi_wstrb = axi_wstrb;
      assign o_ddr_axi_wlast = axi_wlast;
      assign axi_bvalid = i_ddr_axi_bvalid;
      assign o_ddr_axi_bready = axi_bready;
      assign axi_bid = i_ddr_axi_bid;
      assign axi_bresp = i_ddr_axi_bresp;
      assign o_ddr_axi_arvalid = axi_arvalid;
      assign axi_arready = i_ddr_axi_arready;
      assign o_ddr_axi_arid = axi_arid;
      assign o_ddr_axi_araddr = axi_araddr;
      assign o_ddr_axi_arlen = axi_arlen;
      assign o_ddr_axi_arsize = axi_arsize;
      assign o_ddr_axi_arburst = axi_arburst;
      assign axi_rvalid = i_ddr_axi_rvalid;
      assign o_ddr_axi_rready = axi_rready;
      assign axi_rid = i_ddr_axi_rid;
      assign axi_rdata = i_ddr_axi_rdata;
      assign axi_rresp = i_ddr_axi_rresp;
      assign axi_rlast = i_ddr_axi_rlast;
    end
  end else begin : gen_no_cached_tier
    // No cached tier: no DMA agent, so the coherence handshake stays idle.
    assign coh_admit_valid = 1'b0;
    assign coh_admit_slot = '0;
    assign coh_admit_addr = '0;
    assign coh_inval_valid = 1'b0;
    assign coh_inval_slot = '0;
    assign coh_release_valid = 1'b0;
    assign coh_release_slot = '0;
    // No cached tier: the DMA test engine has no memory to move, so its
    // window reads as zero and it never interrupts; likewise the NIC.
    assign dma_engine_irq = 1'b0;
    assign nic_irq = 1'b0;
    // No DDR bridge, so no AXI error responses.
    assign ddr_rd_err_valid = 1'b0;
    assign ddr_rd_err_resp = '0;
    assign ddr_rd_err_id = '0;
    assign ddr_wr_err_valid = 1'b0;
    assign ddr_wr_err_resp = '0;
    assign ddr_wr_err_id = '0;
    assign o_nic_tx_raw_data = '0;
    assign o_nic_tx_raw_valid = 1'b0;
    assign o_nic_phy_ctrl = '0;
    assign o_nic_rx_block_lock = 1'b0;
    // Absent caches report zero performance events.
    assign cache_hierarchy_perf_events = '0;
    // No hierarchy: the instruction-side line port has no slave.
    assign iup_req_ready = 1'b0;
    assign iup_resp_valid = 1'b0;
    // Likewise the walker port: a config with no cached tier has no memory
    // for page tables, so a walk (software enabling Sv39 anyway) stalls.
    assign walk_line_req_ready = 1'b0;
    assign walk_line_resp_valid = 1'b0;
    assign walk_line_resp_id = '0;
    assign walk_line_resp_rdata = '0;
    assign iup_resp_id = '0;
    assign iup_resp_rdata = '0;
    // No caches to sync: fence.i completes immediately.
    assign fence_i_sync_done = fence_i_sync_req;
    // With the tier disabled, cached reads return zero and writes complete
    // without storing data. One pending bit per load slot prevents lost
    // responses on consecutive launches. Return the lowest slot first when
    // the router is ready.
    logic [riscv_pkg::CachedLoadSlots-1:0] stub_read_pending_q;
    /* verilator lint_off UNUSEDSIGNAL */  // the stub shares no line requests
    logic stub_read_no_merge_unused;
    logic [2:0] stub_read_split_unused;  // and takes the request unsplit
    /* verilator lint_on UNUSEDSIGNAL */
    assign stub_read_no_merge_unused = data_memory_cached_read_no_merge;
    assign stub_read_split_unused = {
      data_memory_cached_read_sel, data_memory_cached_read_if_sel, data_memory_cached_read_if_clear
    };
    always_comb begin
      data_memory_cached_resp_id = '0;
      for (int s = int'(riscv_pkg::CachedLoadSlots) - 1; s >= 0; s--) begin
        if (stub_read_pending_q[s]) data_memory_cached_resp_id = riscv_pkg::CachedLoadSlotBits'(s);
      end
    end
    assign data_memory_cached_read_valid = |stub_read_pending_q;
    always_ff @(posedge i_clk) begin
      if (rst_core) begin
        stub_read_pending_q <= '0;
        data_memory_cached_write_done <= 1'b0;
      end else begin
        if (data_memory_cached_read_valid && data_memory_cached_read_ready)
          stub_read_pending_q[data_memory_cached_resp_id] <= 1'b0;
        if (data_memory_cached_read_enable) stub_read_pending_q[data_memory_cached_read_id] <= 1'b1;
        data_memory_cached_write_done <= |data_memory_cached_byte_write_enable;
      end
    end
    assign data_memory_cached_read_data = '0;
    assign data_memory_cached_write_inflight = 1'b0;
    assign o_ddr_axi_awvalid = 1'b0;
    assign o_ddr_axi_awid    = '0;
    assign o_ddr_axi_awaddr = '0;
    assign o_ddr_axi_awlen = '0;
    assign o_ddr_axi_awsize = '0;
    assign o_ddr_axi_awburst = '0;
    assign o_ddr_axi_wvalid = 1'b0;
    assign o_ddr_axi_wdata = '0;
    assign o_ddr_axi_wstrb = '0;
    assign o_ddr_axi_wlast = 1'b0;
    assign o_ddr_axi_bready = 1'b0;
    assign o_ddr_axi_arvalid = 1'b0;
    assign o_ddr_axi_arid    = '0;
    assign o_ddr_axi_araddr = '0;
    assign o_ddr_axi_arlen = '0;
    assign o_ddr_axi_arsize = '0;
    assign o_ddr_axi_arburst = '0;
    assign o_ddr_axi_rready = 1'b0;
  end

  // Pipeline registers for memory access signals (accounts for RAM read latency)
  logic data_memory_read_enable_registered;
  always_ff @(posedge i_clk) begin
    data_memory_address_registered <= data_memory_address;
    data_memory_read_enable_registered <= rst_core ? 1'b0 : data_memory_read_enable;
`ifdef FROST_RVFI_DII
    // TestRIG: device-quadrant stores go to frost_rvfi_dii's RAM, not to the
    // devices.
    data_memory_byte_write_enable_registered <= '0;
`else
    data_memory_byte_write_enable_registered <= rst_core ? '0 : data_memory_byte_write_enable;
`endif
    data_memory_write_data_registered <= data_memory_write_data;
  end

  // cpu_ooo already qualifies this pulse against the same MMIO bounds.
  assign mmio_read_capture = mmio_read_pulse;

  // Capture the performed MMIO read on mmio_read_pulse. Each case selects
  // an aligned dword {word at +4, word at +0}; addr[2] selects a 32-bit result
  // downstream. CLINT 64-bit reads are atomic in one beat.
  //
  // Destructive reads decode the exact word address: UART and FIFO pops in
  // the router, RBR pops and APLIC claims here. Merely including a neighbor in
  // the other lane does not consume it. See hw/rtl/README.md,
  // "Data-tier bus contract".
  always_comb begin
    logic [31:0] ns_thr_rbr_word;
    logic [31:0] ns_ier_dlm_word;
    ns_thr_rbr_word = ns_lcr[7] ? {24'b0, ns_dll} : {24'b0, i_uart_rx_data};
    ns_ier_dlm_word = ns_lcr[7] ? {24'b0, ns_dlm} : {24'b0, ns_ier};

    mmio_read_data_comb = '0;
    unique case ({
      mmio_load_addr[31:3], 3'b000
    })
      // {UART RX data (read consumes byte, via the router's word pulse),
      //  UART TX (write-only, reads 0)}
      {UartMmioAddr[31:3], 3'b000} : mmio_read_data_comb = {{24'b0, i_uart_rx_data}, 32'b0};
      // {FIFO1, FIFO0}
      {Fifo0MmioAddr[31:3], 3'b000} : mmio_read_data_comb = {i_fifo1_rd_data, i_fifo0_rd_data};
      {MtimeLowMmioAddr[31:3], 3'b000} : mmio_read_data_comb = mtime;
      {MtimecmpLowMmioAddr[31:3], 3'b000} : mmio_read_data_comb = mtimecmp;
      // {UART RX status (bit 0: data available), msip}
      {
        MsipMmioAddr[31:3], 3'b000
      } :
      mmio_read_data_comb = {{31'b0, i_uart_rx_valid}, {31'b0, msip}};
      // {-, UART TX status (bit 0: TX ready, the transmit FIFO not almost full)}
      {
        UartTxStatusMmioAddr[31:3], 3'b000
      } :
      mmio_read_data_comb = {32'b0, {31'b0, i_uart_tx_ready}};
      // ns16550a UART face (aliases native UART TX/RX). DLAB selects DLL/DLM.
      {Ns16550ThrRbr[31:3], 3'b000} : mmio_read_data_comb = {ns_ier_dlm_word, ns_thr_rbr_word};
      {Ns16550IirFcr[31:3], 3'b000} : mmio_read_data_comb = {{24'b0, ns_lcr}, {24'b0, ns_iir}};
      // LSR: TEMT from transmitter-empty (bit 6), THRE from TX-ready (bit 5),
      // DR from RX-valid (bit 0).
      {
        Ns16550Mcr[31:3], 3'b000
      } :
      mmio_read_data_comb = {
        {24'b0, 1'b0, i_uart_tx_empty, i_uart_tx_ready, 4'b0, i_uart_rx_valid}, {24'b0, ns_mcr}
      };
      {
        Ns16550Msr[31:3], 3'b000
      } :
      mmio_read_data_comb = {{24'b0, ns_scr}, {24'b0, 8'hB0}};  // scratch | DCD|DSR|CTS
      // SiFive CLINT alias (same registers as the native timer block).
      {ClintMsip[31:3], 3'b000} : mmio_read_data_comb = {32'b0, {31'b0, msip}};
      {ClintMtimecmpLo[31:3], 3'b000} : mmio_read_data_comb = mtimecmp;
      {ClintMtimeLo[31:3], 3'b000} : mmio_read_data_comb = mtime;
      default: ;
    endcase
    // APLIC window: range-decoded outside the exact-address case; the
    // APLIC returns a register pair only for a 32-bit load.
    if (mmio_load_addr[31:22] == AplicWindowSel)
      mmio_read_data_comb = (mmio_load_size == riscv_pkg::MEM_SIZE_WORD) ? aplic_rd_pair : 64'b0;
    // Memory error unit window: likewise.
    if (mmio_load_addr[31:8] == MemErrBase[31:8]) mmio_read_data_comb = memerr_rd_pair;
  end

  // Register MMIO read data so the CPU sees a stable response after the
  // side-effect pulse fires.
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      mmio_read_data_valid <= 1'b0;
    end else begin
      if (mmio_read_capture) begin
        mmio_read_data_valid <= 1'b1;
      end else if (mmio_read_data_valid && !mmio_load_valid) begin
        mmio_read_data_valid <= 1'b0;
      end
    end
  end

`ifdef FROST_XILINX_PRIMS
  // Explicit flops prevent Vivado from mapping zero read cases to reset pins.
  for (
      genvar g_mmio_read_data = 0; g_mmio_read_data < $bits(mmio_read_data_reg); g_mmio_read_data++
  ) begin : gen_mmio_read_data_ff
    FDRE #(
        .INIT(1'b0)
    ) mmio_read_data_ff (
        .C (i_clk),
        .CE(mmio_read_capture),
        .D (mmio_read_data_comb[g_mmio_read_data]),
        .Q (mmio_read_data_reg[g_mmio_read_data]),
        .R (1'b0)
    );
  end
`elsif FROST_RVFI_DII
  // TestRIG: device-quadrant loads read frost_rvfi_dii's RAM.
  always_ff @(posedge i_clk) begin
    if (mmio_read_capture) begin
      mmio_read_data_reg <= rvfi_dii_device_read_data;
    end
  end
`else
  always_ff @(posedge i_clk) begin
    if (mmio_read_capture) begin
      mmio_read_data_reg <= mmio_read_data_comb;
    end
  end
`endif

  // Both CPU data inputs receive this selected payload. The router retains
  // its valid, ready, and ID decisions; its payload mux selects equal inputs.
  // cached-read-ready is the inverse of its registered fast-response valid.
  data_mem_response_mux #(
      .DATA_WIDTH(riscv_pkg::MemDataBits)
  ) data_mem_response_mux_inst (
      .i_bram_read_data(data_memory_read_data),
      .i_mmio_read_data(mmio_read_data_reg),
      .i_cached_read_data(data_memory_cached_read_data),
      .i_mmio_read_valid(mmio_read_data_valid),
      .i_cached_read_ready(data_memory_cached_read_ready),
      .o_read_data(data_memory_response_data)
  );

  // UART write: the native TX at 0x4000_0000, or the ns16550 THR at
  // 0x4000_1000 when DLAB is clear. Both funnel into the same TX byte stream.
  logic cpu_uart_wr_en_next;
  assign cpu_uart_wr_en_next = |data_memory_byte_write_enable_registered &&
      ((data_memory_address_registered == riscv_pkg::PhysAddrBits'(UartMmioAddr)) ||
       (data_memory_address_registered == riscv_pkg::PhysAddrBits'(Ns16550ThrRbr) && !ns_lcr[7]));
  always_ff @(posedge i_clk) begin
    cpu_uart_wr_data <= data_memory_write_data_registered[7:0];  // UART uses only lower byte
    cpu_uart_wr_en   <= cpu_uart_wr_en_next;
  end

  generate
    if (ENABLE_HANG_TRIAGE != 0) begin : gen_hang_triage
      // On-silicon hang triage: classify a silent boot hang over UART. It is
      // opt-in because it periodically takes over the console.
      logic        triage_active;
      logic        triage_wr_en;
      logic [ 7:0] triage_wr_data;
      logic [31:0] triage_mtime_lo;
      logic [31:0] triage_mtime_hi;
      logic [31:0] triage_mtimecmp_lo;
      logic [31:0] triage_mtimecmp_hi;
      logic [31:0] triage_mtimecmp_delta_lo;
      logic [31:0] triage_irq_status;
      always_ff @(posedge i_clk) begin
        if (rst_core) begin
          triage_mtime_lo          <= 32'd0;
          triage_mtime_hi          <= 32'd0;
          triage_mtimecmp_lo       <= 32'd0;
          triage_mtimecmp_hi       <= 32'd0;
          triage_mtimecmp_delta_lo <= 32'd0;
          triage_irq_status        <= 32'd0;
        end else begin
          triage_mtime_lo <= mtime[31:0];
          triage_mtime_hi <= mtime[63:32];
          triage_mtimecmp_lo <= mtimecmp[31:0];
          triage_mtimecmp_hi <= mtimecmp[63:32];
          triage_mtimecmp_delta_lo <= mtimecmp[31:0] - mtime[31:0];
          triage_irq_status <= {
            22'd0,
            cpu_debug_irq_status[5],
            cpu_debug_irq_status[4],
            cpu_debug_irq_status[3:2],
            cpu_debug_irq_status[1],
            cpu_debug_irq_status[0],
            interrupts.meip,
            interrupts.msip,
            interrupts.mtip,
            mtip_comparison
          };
        end
      end
      hang_triage #(
          .QUIET_CYCLES (32'(HANG_TRIAGE_QUIET_CYCLES)),
          .REEMIT_CYCLES(32'(HANG_TRIAGE_REEMIT_CYCLES))
      ) u_hang_triage (
          .i_clk              (i_clk),
          .i_rst              (rst_core),
          .i_commit           (commit_vld),
          .i_timer_event      (mtimecmp_write_pulse),
          .i_cread_req        (data_memory_cached_read_enable),
          .i_cread_resp       (data_memory_cached_read_valid),
          .i_cwrite_req       (|data_memory_cached_byte_write_enable),
          .i_cwrite_done      (data_memory_cached_write_done),
          .i_pc               (program_counter[31:0]),
          .i_commit0_valid    (cpu_debug_commit_valid[0]),
          .i_commit0_pc       (cpu_debug_commit_pc),
          .i_commit1_valid    (cpu_debug_commit_valid[1]),
          .i_commit1_pc       (cpu_debug_commit_2_pc),
          .i_mtime_lo         (triage_mtime_lo),
          .i_mtime_hi         (triage_mtime_hi),
          .i_mtimecmp_lo      (triage_mtimecmp_lo),
          .i_mtimecmp_hi      (triage_mtimecmp_hi),
          .i_mtimecmp_delta_lo(triage_mtimecmp_delta_lo),
          .i_irq_status       (triage_irq_status),
          // The byte entering cpu_uart_wr_en at the next edge: the takeover
          // never shares an edge with one, so the mux below never drops it.
          .i_uart_busy        (cpu_uart_wr_en_next),
          .i_uart_ready       (i_uart_tx_ready),
          .o_active           (triage_active),
          .o_wr_en            (triage_wr_en),
          .o_wr_data          (triage_wr_data)
      );
      assign o_uart_wr_en   = triage_active ? triage_wr_en : cpu_uart_wr_en;
      assign o_uart_wr_data = triage_active ? triage_wr_data : cpu_uart_wr_data;
    end else begin : gen_no_hang_triage
      assign o_uart_wr_en   = cpu_uart_wr_en;
      assign o_uart_wr_data = cpu_uart_wr_data;
    end
  endgenerate

  // ns16550a register-file writes. DLAB (LCR[7]) routes offsets 0/4 to the
  // baud divisor (DLL/DLM); the THR write itself transmits via o_uart_wr_en.
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      ns_dll <= 8'h01;
      ns_dlm <= 8'h00;
      ns_ier <= 8'h00;
      ns_fcr <= 8'h00;
      ns_lcr <= 8'h00;
      ns_mcr <= 8'h00;
      ns_scr <= 8'h00;
    end else if (|data_memory_byte_write_enable_registered) begin
      unique case (data_memory_address_registered)
        riscv_pkg::PhysAddrBits'(Ns16550ThrRbr):
        if (ns_lcr[7]) ns_dll <= data_memory_write_data_registered[7:0];
        riscv_pkg::PhysAddrBits'(Ns16550IerDlm):
        if (ns_lcr[7]) ns_dlm <= data_memory_write_data_registered[7:0];
        else ns_ier <= data_memory_write_data_registered[7:0];
        riscv_pkg::PhysAddrBits'(Ns16550IirFcr): ns_fcr <= data_memory_write_data_registered[7:0];
        riscv_pkg::PhysAddrBits'(Ns16550Lcr): ns_lcr <= data_memory_write_data_registered[7:0];
        riscv_pkg::PhysAddrBits'(Ns16550Mcr): ns_mcr <= data_memory_write_data_registered[7:0];
        riscv_pkg::PhysAddrBits'(Ns16550Scr): ns_scr <= data_memory_write_data_registered[7:0];
        default: ;
      endcase
    end
  end

  // FIFO writes. FIFO registers are 32-bit-access-max (hw/rtl/README.md,
  // "Data-tier bus contract"): the addressed word is identical in both lanes
  // for sub-dword stores (replication).
  assign o_fifo0_wr_data = data_memory_write_data_registered[31:0];
  assign o_fifo0_wr_en   = |data_memory_byte_write_enable_registered &&
                            data_memory_address_registered == Fifo0PhysAddr;
  assign o_fifo1_wr_data = data_memory_write_data_registered[31:0];
  assign o_fifo1_wr_en   = |data_memory_byte_write_enable_registered &&
                            data_memory_address_registered == Fifo1PhysAddr;

  // Linux reads received bytes through the ns16550 RBR alias. That read must
  // consume the shared UART RX FIFO as the native FROST RX-data address does,
  // but only when DLAB is clear; with DLAB set, offset 0 is DLL.
  logic ns16550_rbr_read_pulse;
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      ns16550_rbr_read_pulse <= 1'b0;
    end else begin
      ns16550_rbr_read_pulse <= mmio_read_pulse && (mmio_load_addr == Ns16550ThrRbr) && !ns_lcr[7];
    end
  end

  // FIFO/UART consume pulses fire one cycle after the MMIO read request is
  // accepted. The response data itself was already captured above.
  assign o_fifo0_rd_en   = mmio_fifo0_read_pulse;
  assign o_fifo1_rd_en   = mmio_fifo1_read_pulse;
  assign o_uart_rx_ready = mmio_uart_rx_ready_pulse || ns16550_rbr_read_pulse;

  // mtime increments each cycle except during a write. Suppress the full
  // increment even for a partial write, or the unwritten half would change.
  // Dword decoding lets a 64-bit store update both halves atomically.
  logic write_hits_mtime;
  assign write_hits_mtime =
      ({data_memory_address_registered[riscv_pkg::PhysAddrBits-1:3], 3'b000} ==
       riscv_pkg::PhysAddrBits'(MtimeLowMmioAddr & 32'hffff_fff8)) ||
      ({data_memory_address_registered[riscv_pkg::PhysAddrBits-1:3], 3'b000} ==
       riscv_pkg::PhysAddrBits'(ClintMtimeLo & 32'hffff_fff8));
  logic writing_mtime_low, writing_mtime_high;
  assign writing_mtime_low  = write_hits_mtime && |data_memory_byte_write_enable_registered[3:0];
  assign writing_mtime_high = write_hits_mtime && |data_memory_byte_write_enable_registered[7:4];

  // 32-bit writes replicate their word across the beat and strobe one lane;
  // 64-bit writes strobe both lanes and update atomically. See
  // hw/rtl/README.md, "Data-tier bus contract".
  logic write_hits_mtimecmp;
  assign write_hits_mtimecmp =
      ({data_memory_address_registered[riscv_pkg::PhysAddrBits-1:3], 3'b000} ==
       riscv_pkg::PhysAddrBits'(MtimecmpLowMmioAddr & 32'hffff_fff8)) ||
      ({data_memory_address_registered[riscv_pkg::PhysAddrBits-1:3], 3'b000} ==
       riscv_pkg::PhysAddrBits'(ClintMtimecmpLo & 32'hffff_fff8));

  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      mtime <= 64'd0;
      mtimecmp <= MtimecmpDefault;
      msip <= 1'b0;
    end else begin
      if (writing_mtime_low || writing_mtime_high) begin
        if (writing_mtime_low) mtime[31:0] <= data_memory_write_data_registered[31:0];
        if (writing_mtime_high) mtime[63:32] <= data_memory_write_data_registered[63:32];
      end else begin
        mtime <= mtime + 64'(SIM_TIMER_SPEEDUP);
      end

      if (write_hits_mtimecmp) begin
        if (|data_memory_byte_write_enable_registered[3:0])
          mtimecmp[31:0] <= data_memory_write_data_registered[31:0];
        if (|data_memory_byte_write_enable_registered[7:4])
          mtimecmp[63:32] <= data_memory_write_data_registered[63:32];
      end

      // msip drives the software interrupt; only bit 0 is writable. It stays
      // word-decoded: the CLINT alias is 32-bit-access for msip, and Linux
      // writes it with sw.
      if (|data_memory_byte_write_enable_registered &&
          ((data_memory_address_registered == riscv_pkg::PhysAddrBits'(MsipMmioAddr)) ||
           (data_memory_address_registered == riscv_pkg::PhysAddrBits'(ClintMsip)))) begin
        msip <= data_memory_write_data_registered[0];
      end
    end
  end

endmodule : frost_rvfi_platform
