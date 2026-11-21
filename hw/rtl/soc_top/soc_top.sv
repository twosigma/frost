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
  FROST SoC: board memory, debug transport/module, and peripherals. Low-BRAM programming uses
  port A on i_clk_div4; runtime fetch and data access use port B on i_clk.
  The cached tier connects to DDR through the cache hierarchy and AXI bridge.
*/
module soc_top #(
    parameter bit ASYNC_CPU_CLOCK = 1'b0,
    parameter int unsigned NUM_HARTS = 1,
    parameter int unsigned AXI_ID_BITS = 6,
    parameter int unsigned AXI_USER_BITS = 1,
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 17,
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned L2_LINE_BYTES = 64,
    // Size the behavioral DDR's queues for the CPU's configured cache slots.
    parameter int unsigned L2_NUM_MSHR = 8,
    parameter int unsigned L2_NUM_WB = 2,
    parameter int unsigned DDR_MODEL_BYTES = 64 * 1024 * 1024,
    parameter int unsigned DDR_MODEL_LATENCY = 80,
    parameter int unsigned DDR_MODEL_LATENCY_JITTER = 0,
    parameter int unsigned DDR_MODEL_REORDER = 0,
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // Simulation-only gaps in uncached instruction AXI response latency.
    parameter int unsigned FETCH_VALID_FUZZ = 0,
    parameter int unsigned FETCH_VALID_FUZZ_SEED = 32'h0000_ACE1,
    parameter int unsigned ENABLE_HANG_TRIAGE = 0,
    parameter int unsigned HANG_TRIAGE_QUIET_CYCLES = 32'd900_000_000,
    parameter int unsigned HANG_TRIAGE_REEMIT_CYCLES = 32'd322_265_625,
    parameter int unsigned DEBUG_JTAG_TAP = 1,
    parameter int unsigned POWER_ON_RESET_ENABLE = 1,
    parameter int unsigned CLK_FREQ_HZ = 322265625,
    parameter int unsigned RAW_LOOPBACK = 1,
    parameter int unsigned ENABLE_1G_ETH = 0,
    // External AXI4 DMA slave ports into dma_interconnect, each behind an
    // axi_register_slice; 0 omits them.
    parameter int unsigned EXT_DMA_PORTS = 0,
    parameter int unsigned EXT_DMA_ID_BITS = 3,
    // 1 exports the primary NIC engine's core-clock AXI4-Stream and MAC
    // sideband ports and omits the internal nic_mac_10g; 0 keeps it.
    parameter int unsigned EXTERNAL_MAC = 0,
    // 1 exposes a 16 KiB external AXI4-Lite master window at
    // 0x4002_4000-0x4002_7FFF behind an axil_register_slice; 0 omits it.
    parameter int unsigned EXT_AXIL_WINDOW = 0,
    localparam int unsigned ExtDmaPortCount = (EXT_DMA_PORTS > 0) ? EXT_DMA_PORTS : 1
) (
    input logic i_clk,
    input logic i_cpu_clk = 1'b0,
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
    // these ports; the behavioral memory uses the fabric reset.
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
    input logic i_nic_tx_clk,
    input logic i_nic_rx_clk,
    input logic i_nic_tx_clk_ok,
    input logic i_nic_rx_clk_ok,
    output logic [63:0] o_nic_tx_raw_data,
    output logic o_nic_tx_raw_valid,
    input logic [63:0] i_nic_rx_raw_data,
    input logic i_nic_rx_raw_valid,
    input logic i_nic_rx_signal_ok,
    input logic [4:0] i_nic_phy_status,
    output logic [3:1] o_nic_phy_ctrl,
    output logic o_nic_rx_block_lock,
    // Optional 1G GMII NIC (ENABLE_1G_ETH=1, VCU118 only).
    input logic i_nic_1g_tx_clk = 1'b0,
    input logic i_nic_1g_rx_clk = 1'b0,
    input logic i_nic_1g_tx_clk_ok = 1'b1,
    input logic i_nic_1g_rx_clk_ok = 1'b1,
    output logic [63:0] o_nic_1g_tx_raw_data,
    output logic o_nic_1g_tx_raw_valid,
    input logic [63:0] i_nic_1g_rx_raw_data = '0,
    input logic i_nic_1g_rx_raw_valid = 1'b0,
    input logic i_nic_1g_rx_signal_ok = 1'b0,
    input logic [4:0] i_nic_1g_phy_status = 5'b01111,
    input logic [32:0] i_nic_1g_phy_diag = '0,
    output logic o_nic_1g_phy_diag_ack,
    output logic [3:1] o_nic_1g_phy_ctrl,
    output logic o_nic_1g_rx_block_lock,
    // Optional VCU118 SPI flash & boot status (ENABLE_1G_ETH=1).
    output logic o_spi_cs_n,
    output logic o_spi_sck,
    output logic o_spi_mosi,
    input logic i_spi_miso = 1'b0,
    input logic [1:0] i_ddr_status = 2'b11,
    // Core-domain synchronous active-high reset for external board blocks
    // sharing i_clk.
    output logic o_soc_rst,
    // Optional external AXI4 DMA slave ports (EXT_DMA_PORTS > 0). Flat
    // per-port vectors: port p occupies [p*W +: W]. Each port enters
    // dma_interconnect through an axi_register_slice on i_clk / o_soc_rst.
    input logic [ExtDmaPortCount-1:0] i_ext_dma_awvalid = '0,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_awready,
    input logic [ExtDmaPortCount*EXT_DMA_ID_BITS-1:0] i_ext_dma_awid = '0,
    input logic [ExtDmaPortCount*64-1:0] i_ext_dma_awaddr = '0,
    input logic [ExtDmaPortCount*8-1:0] i_ext_dma_awlen = '0,
    input logic [ExtDmaPortCount*3-1:0] i_ext_dma_awsize = '0,
    input logic [ExtDmaPortCount*2-1:0] i_ext_dma_awburst = '0,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_awlock = '0,
    input logic [ExtDmaPortCount*4-1:0] i_ext_dma_awcache = '0,
    input logic [ExtDmaPortCount*3-1:0] i_ext_dma_awprot = '0,
    input logic [ExtDmaPortCount*4-1:0] i_ext_dma_awqos = '0,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_wvalid = '0,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_wready,
    input logic [ExtDmaPortCount*256-1:0] i_ext_dma_wdata = '0,
    input logic [ExtDmaPortCount*32-1:0] i_ext_dma_wstrb = '0,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_wlast = '0,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_bvalid,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_bready = '0,
    output logic [ExtDmaPortCount*EXT_DMA_ID_BITS-1:0] o_ext_dma_bid,
    output logic [ExtDmaPortCount*2-1:0] o_ext_dma_bresp,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_arvalid = '0,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_arready,
    input logic [ExtDmaPortCount*EXT_DMA_ID_BITS-1:0] i_ext_dma_arid = '0,
    input logic [ExtDmaPortCount*64-1:0] i_ext_dma_araddr = '0,
    input logic [ExtDmaPortCount*8-1:0] i_ext_dma_arlen = '0,
    input logic [ExtDmaPortCount*3-1:0] i_ext_dma_arsize = '0,
    input logic [ExtDmaPortCount*2-1:0] i_ext_dma_arburst = '0,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_arlock = '0,
    input logic [ExtDmaPortCount*4-1:0] i_ext_dma_arcache = '0,
    input logic [ExtDmaPortCount*3-1:0] i_ext_dma_arprot = '0,
    input logic [ExtDmaPortCount*4-1:0] i_ext_dma_arqos = '0,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_rvalid,
    input logic [ExtDmaPortCount-1:0] i_ext_dma_rready = '0,
    output logic [ExtDmaPortCount*EXT_DMA_ID_BITS-1:0] o_ext_dma_rid,
    output logic [ExtDmaPortCount*256-1:0] o_ext_dma_rdata,
    output logic [ExtDmaPortCount*2-1:0] o_ext_dma_rresp,
    output logic [ExtDmaPortCount-1:0] o_ext_dma_rlast,
    // Optional external MAC boundary (EXTERNAL_MAC != 0): core-clock 64-bit
    // AXI4-Stream TX/RX and MAC sideband ports directly from nic_engine.
    output logic o_ext_mac_tx_tvalid,
    input logic i_ext_mac_tx_tready = 1'b0,
    output logic [63:0] o_ext_mac_tx_tdata,
    output logic [7:0] o_ext_mac_tx_tkeep,
    output logic o_ext_mac_tx_tlast,
    output logic o_ext_mac_tx_tuser,
    output logic [14:0] o_ext_mac_tx_csum,
    input logic i_ext_mac_rx_tvalid = 1'b0,
    output logic o_ext_mac_rx_tready,
    input logic [63:0] i_ext_mac_rx_tdata = '0,
    input logic [7:0] i_ext_mac_rx_tkeep = '0,
    input logic i_ext_mac_rx_tlast = 1'b0,
    output logic o_ext_mac_rst,
    output logic o_ext_mac_soft_rst,
    output logic o_ext_mac_restart,
    input logic [1:0] i_ext_mac_ready = '0,
    input logic [7:0] i_ext_mac_link = '0,
    input logic i_ext_mac_raw_loopback_en = 1'b0,
    output logic o_ext_mac_loopback,
    output logic [47:0] o_ext_mac_station_addr,
    output logic [1:0] o_ext_mac_pause_ctrl,
    output logic [13:0] o_ext_mac_pause_high_water,
    output logic [13:0] o_ext_mac_pause_low_water,
    output logic [15:0] o_ext_mac_pause_interval,
    output logic [13:0] o_ext_mac_rx_fifo_limit,
    output logic o_ext_mac_rx_fifo_limit_wr,
    input logic i_ext_mac_rx_fifo_limit_busy = 1'b0,
    output logic o_ext_mac_rx_desc_starved,
    input logic [21*64-1:0] i_ext_mac_totals = '0,
    // Optional external AXI4-Lite master window at 0x4002_4000-0x4002_7FFF
    // (16 KiB, EXT_AXIL_WINDOW != 0), behind an axil_register_slice.
    output logic o_ext_axil_awvalid,
    input logic i_ext_axil_awready = 1'b0,
    output logic [13:0] o_ext_axil_awaddr,
    output logic [2:0] o_ext_axil_awprot,
    output logic o_ext_axil_wvalid,
    input logic i_ext_axil_wready = 1'b0,
    output logic [63:0] o_ext_axil_wdata,
    output logic [7:0] o_ext_axil_wstrb,
    input logic i_ext_axil_bvalid = 1'b0,
    output logic o_ext_axil_bready,
    input logic [1:0] i_ext_axil_bresp = '0,
    output logic o_ext_axil_arvalid,
    input logic i_ext_axil_arready = 1'b0,
    output logic [13:0] o_ext_axil_araddr,
    output logic [2:0] o_ext_axil_arprot,
    input logic i_ext_axil_rvalid = 1'b0,
    output logic o_ext_axil_rready,
    input logic [63:0] i_ext_axil_rdata = '0,
    input logic [1:0] i_ext_axil_rresp = '0,
    output logic o_cpu_rst,
    output logic o_cpu_axi_rst,
    output riscv_pkg::interrupt_t o_cpu_interrupts,
    output logic [NUM_HARTS-1:0] o_cpu_msi_valid,
    output logic [NUM_HARTS-1:0] o_cpu_msi_level,
    output logic [10:0] o_cpu_msi_id,
    output logic o_cpu_seip,
    output logic [63:0] o_cpu_mtime,
    output logic o_imem_sync_done,
    output logic o_dbg_haltreq,
    output logic o_dbg_go,
    output logic [31:0] o_dbg_go_addr,
    output logic [63:0] o_dbg_data,
    input logic i_dbg_data_we,
    input logic [63:0] i_dbg_data_wdata,
    input logic i_debug_mode,
    input logic i_dbg_parked,
    input logic i_dbg_cmd_err,
    input logic i_dbg_go_taken,
    // The hart's fatal stop, for the debug module's unavailable report.
    input logic i_dbg_fatal_stop = 1'b0,
    input logic i_commit_valid,
    input logic [5:0] i_debug_irq_status,
    input logic [63:0] i_debug_commit_pc,
    input logic [63:0] i_debug_commit_2_pc,
    input logic [1:0] i_debug_commit_valid,
    output logic o_coherent_req_valid,
    input logic i_coherent_req_ready,
    output logic o_coherent_req_write,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_coherent_req_addr,
    output logic [255:0] o_coherent_req_wdata,
    output logic [31:0] o_coherent_req_wstrb,
    output logic [3:0] o_coherent_req_id,
    output logic o_coherent_req_non_alloc,
    input logic i_coherent_resp_valid,
    input logic [3:0] i_coherent_resp_id,
    input logic [255:0] i_coherent_resp_rdata,
    input logic i_coherent_resp_error,
    input logic i_axi_awvalid,
    output logic o_axi_awready,
    input logic [AXI_ID_BITS-1:0] i_axi_awid,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_axi_awaddr,
    input logic [7:0] i_axi_awlen,
    input logic [2:0] i_axi_awsize,
    input logic [1:0] i_axi_awburst,
    input logic i_axi_awlock,
    input logic [3:0] i_axi_awcache,
    input logic [2:0] i_axi_awprot,
    input logic [3:0] i_axi_awqos,
    input logic [3:0] i_axi_awregion,
    input logic [AXI_USER_BITS-1:0] i_axi_awuser,
    input logic i_axi_wvalid,
    output logic o_axi_wready,
    input logic [L2_LINE_BYTES*8-1:0] i_axi_wdata,
    input logic [L2_LINE_BYTES-1:0] i_axi_wstrb,
    input logic i_axi_wlast,
    input logic [AXI_USER_BITS-1:0] i_axi_wuser,
    output logic o_axi_bvalid,
    input logic i_axi_bready,
    output logic [AXI_ID_BITS-1:0] o_axi_bid,
    output logic [1:0] o_axi_bresp,
    output logic [AXI_USER_BITS-1:0] o_axi_buser,
    input logic i_axi_arvalid,
    output logic o_axi_arready,
    input logic [AXI_ID_BITS-1:0] i_axi_arid,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_axi_araddr,
    input logic [7:0] i_axi_arlen,
    input logic [2:0] i_axi_arsize,
    input logic [1:0] i_axi_arburst,
    input logic i_axi_arlock,
    input logic [3:0] i_axi_arcache,
    input logic [2:0] i_axi_arprot,
    input logic [3:0] i_axi_arqos,
    input logic [3:0] i_axi_arregion,
    input logic [AXI_USER_BITS-1:0] i_axi_aruser,
    output logic o_axi_rvalid,
    input logic i_axi_rready,
    output logic [AXI_ID_BITS-1:0] o_axi_rid,
    output logic [L2_LINE_BYTES*8-1:0] o_axi_rdata,
    output logic [1:0] o_axi_rresp,
    output logic o_axi_rlast,
    output logic [AXI_USER_BITS-1:0] o_axi_ruser
);
  logic local_fire, local_ok, local_bram, local_device, local_instruction;
  // Registered core reset covers external reset, fabric loss, ndmreset and SYSRESET.
  // Debug logic uses external reset alone so it survives both core-reset
  // requests. Cache tags are swept on core reset; dirty lines are discarded.
  wire  core_clk = ASYNC_CPU_CLOCK ? i_cpu_clk : i_clk;
  logic dbg_ndmreset;
  // System-reset request from the SYSRESET register (sysreset_q below).
  logic sysreset_q;
  (* max_fanout = 256 *)logic soc_cpu_rst;
  logic soc_axi_rst;
  logic debug_cpu_rst, debug_soc_rst;
  logic reset_request_soc;
  // Each domain's reset is built here from the requests that cover it.
  wire  fabric_reset_request = (USE_BEHAVIORAL_DDR != 0) ? i_rst : i_ddr_axi_rst;
  if (ASYNC_CPU_CLOCK) begin : gen_clock_resets
    logic core_reset_cpu;
    cdc_reset_pair fabric_reset (
        .i_arst (fabric_reset_request),
        .i_a_clk(i_clk),
        .i_b_clk(core_clk),
        .o_a_rst(soc_axi_rst),
        .o_b_rst(o_cpu_axi_rst)
    );
    cdc_reset_pair core_reset (
        .i_arst (i_rst || dbg_ndmreset || sysreset_q || fabric_reset_request),
        .i_a_clk(i_clk),
        .i_b_clk(core_clk),
        .o_a_rst(reset_request_soc),
        .o_b_rst(core_reset_cpu)
    );
    cdc_reset_pair debug_reset (
        .i_arst (i_rst),
        .i_a_clk(i_clk),
        .i_b_clk(core_clk),
        .o_a_rst(debug_soc_rst),
        .o_b_rst(debug_cpu_rst)
    );
    assign o_cpu_rst = core_reset_cpu || o_cpu_axi_rst;
  end else begin : gen_common_clock_resets
    assign soc_axi_rst = fabric_reset_request;
    assign o_cpu_axi_rst = soc_axi_rst;
    assign o_cpu_rst = soc_cpu_rst;
    assign reset_request_soc = i_rst || dbg_ndmreset || sysreset_q || fabric_reset_request;
    assign debug_cpu_rst = i_rst;
    assign debug_soc_rst = i_rst;
  end
  // The NIC registers the same next value to keep its local reset in step.
  logic rst_core_next;
  assign rst_core_next = reset_request_soc;
  // Limit reset fanout per replica.
  (* max_fanout = 256 *) logic rst_core;
  always_ff @(posedge i_clk) rst_core <= rst_core_next;
  assign o_soc_rst = rst_core;

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
  // copy listed in hw/rtl/README.md, "Memory Map". This SoC decodes the UART
  // RX and FIFO side effects from accepted local AXI accesses; the CPU tile
  // only classifies the configured Device regions.
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
  // Both NICs build their RX ingress FIFO 8192 words deep (68 bits, about 16 BRAM36 each); the
  // RX_FIFO_LIMIT register picks the occupancy it reports full at.
  localparam int unsigned NicRxFifoDepth = 8192;
  // NIC @ 0x4003_0000, a 4 KiB window of 32-bit registers
  // (hw/rtl/peripherals/nic/nic_pkg.sv). It shares the coherent DMA port with
  // the test engine through a line-port arbiter; its interrupt is APLIC
  // source 4.
  localparam int unsigned NicBase = 32'h4003_0000;
  // Secondary 1G SGMII NIC @ 0x4002_2000 (when ENABLE_1G_ETH != 0), a 4 KiB
  // window of 32-bit registers sharing the coherent DMA port; its interrupt
  // shares APLIC source 2.
  localparam int unsigned Nic1gBase = 32'h4002_2000;
  // VCU118 boot/SPI flash controller @ 0x4002_3000 (when ENABLE_1G_ETH != 0).
  localparam int unsigned BootSpiCtrlAddr = 32'h4002_3000;
  localparam int unsigned BootSysStatusAddr = 32'h4002_3004;
  localparam int unsigned BootSpiXferByteAddr = 32'h4002_3008;
  localparam int unsigned BootSpiXferWordAddr = 32'h4002_300C;
  localparam int unsigned BootSramAddrReg = 32'h4002_3010;
  // System reset register @ 0x4002_F000 (a 4 KiB page). A 16-bit store of
  // SysResetKey, the sifive_test FINISHER_RESET code, resets the core domain
  // like the debug module's ndmreset: the CPU restarts at the boot address
  // while BRAM and DDR storage survive; dirty cache lines are discarded.
  localparam int unsigned SysResetAddr = 32'h4002_F000;
  localparam logic [15:0] SysResetKey = 16'h7777;
  localparam int unsigned BootSramDataReg = 32'h4002_3014;
  // Memory error unit @ 0x4002_1000, a 256-byte window of 32-bit registers
  // (memory_error_unit.sv): counts of DDR ECC errors and of the DDR bridge's
  // AXI error responses; its interrupt is APLIC source 5.
  localparam int unsigned MemErrBase = 32'h4002_1000;
  // Optional external AXI4-Lite device window @ 0x4002_4000-0x4002_7FFF
  // (16 KiB, active when EXT_AXIL_WINDOW != 0).
  localparam int unsigned ExtAxilBase = 32'h4002_4000;

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
  localparam logic [10:0] ImsicWindowSel = 11'h240;
  localparam logic [31:0] ImsicMBase = 32'h4800_0000;
  localparam logic [31:0] ImsicSBase = 32'h4810_0000;

  // The data PMA accepts device accesses only in riscv_pkg's device-window
  // pages, so they must match the MMIO, APLIC and IMSIC windows decoded here: a
  // page only the PMA had would reach no register, and one it lacked would
  // fault. The pages must also keep the layout their decodes assume: all
  // windows inside the device quadrant, which the load and store queues order
  // as devices; the MMIO window inside one aligned 64-page block
  // (riscv_pkg::pma_device_page_ok); and each window nonempty with an
  // unmapped page on both sides (the store-issue page split in
  // tomasulo_wrapper).
  initial begin
    if ((MmioAddr != {riscv_pkg::MmioFirstPage, 12'h000}) ||
        ((MmioAddr + MmioSizeBytes) != {riscv_pkg::MmioLastPage + 20'd1, 12'h000}) ||
        ({AplicWindowSel, 22'h00_0000} != {riscv_pkg::AplicFirstPage, 12'h000}) ||
        ({AplicWindowSel, 22'h3F_FFFF} != {riscv_pkg::AplicLastPage, 12'hFFF}) ||
        ({ImsicWindowSel, 21'b0} != {riscv_pkg::ImsicFirstPage, 12'b0}) ||
        ({ImsicWindowSel, 21'h1F_FFFF} != {riscv_pkg::ImsicLastPage, 12'hFFF}))
      $fatal(
          1, "soc_top: MMIO, APLIC or IMSIC window differs from the riscv_pkg device-window pages"
      );
    if ((riscv_pkg::MmioFirstPage[19:18] != 2'b01) || (riscv_pkg::AplicFirstPage[19:18] != 2'b01) ||
        (riscv_pkg::MmioLastPage[19:6] != riscv_pkg::MmioFirstPage[19:6]) ||
        (riscv_pkg::MmioFirstPage > riscv_pkg::MmioLastPage) ||
        (riscv_pkg::MmioLastPage == 20'h7_FFFF) || (riscv_pkg::AplicLastPage == 20'h7_FFFF) ||
        ((riscv_pkg::MmioLastPage + 20'd1 >= riscv_pkg::AplicFirstPage) &&
         (riscv_pkg::AplicLastPage + 20'd1 >= riscv_pkg::MmioFirstPage)))
      $fatal(1, "soc_top: riscv_pkg device-window pages break the layout their decodes assume");
    if (NUM_HARTS < 1 || NUM_HARTS > 256 ||
        (riscv_pkg::ImsicFirstPage[19:18] != 2'b01) ||
        (riscv_pkg::ImsicLastPage[19:9] != riscv_pkg::ImsicFirstPage[19:9]) ||
        (riscv_pkg::ImsicFirstPage > riscv_pkg::ImsicLastPage) ||
        (riscv_pkg::ImsicLastPage == 20'h7_FFFF) ||
        (riscv_pkg::AplicLastPage + 20'd1 >= riscv_pkg::ImsicFirstPage) ||
        (riscv_pkg::MmioLastPage + 20'd1 >= riscv_pkg::ImsicFirstPage))
      $fatal(1, "soc_top: IMSIC pages break the device-window layout");
    if (EXT_DMA_PORTS > 0 && ENABLE_CACHED_TIER == 0)
      $fatal(1, "soc_top: EXT_DMA_PORTS requires ENABLE_CACHED_TIER != 0");
    if (EXT_DMA_PORTS > 0 && EXT_DMA_ID_BITS == 0)
      $fatal(1, "soc_top: EXT_DMA_ID_BITS must be nonzero");
    if (EXTERNAL_MAC != 0 && ENABLE_CACHED_TIER == 0)
      $fatal(1, "soc_top: EXTERNAL_MAC requires ENABLE_CACHED_TIER != 0");
  end

  // Peripheral-local views of the single accepted AXI access and passive
  // CPU observations. No pipeline or cache state lives in this module.
  logic [riscv_pkg::XLEN-1:0] program_counter;
  logic commit_vld;
  logic cpu_uart_wr_en;
  logic [7:0] cpu_uart_wr_data;
  logic [31:0] fetch_pa_word0, fetch_pa_word1;
  logic [63:0] bram_fetch_instr;
  localparam int unsigned LineIdBits = 4;
  localparam int unsigned DdrAxiIdBits = 5;
  localparam int unsigned L1LineBytes = 32;
  localparam int unsigned L2MaxSlots = (L2_NUM_MSHR > L2_NUM_WB) ? L2_NUM_MSHR : L2_NUM_WB;
  localparam int unsigned DdrModelSlots = (L2MaxSlots > 8) ? L2MaxSlots : 8;
  logic [riscv_pkg::PhysAddrBits-1:0] data_memory_address, data_memory_address_registered;
  logic [63:0] data_memory_write_data, data_memory_write_data_registered;
  logic [63:0] data_memory_read_data, mmio_read_data_comb, mmio_read_data_reg;
  logic mmio_read_data_valid;
  logic [31:0] mmio_load_addr;
  logic mmio_load_valid, mmio_read_capture;
  logic [7:0] data_memory_byte_write_enable, data_memory_bram_byte_write_enable;
  logic data_memory_read_enable;
  logic [7:0] data_memory_cached_byte_write_enable;
  logic
      data_memory_cached_read_enable, data_memory_cached_read_valid, data_memory_cached_write_done;
  logic mmio_read_pulse, mmio_fifo0_read_pulse, mmio_fifo1_read_pulse, mmio_uart_rx_ready_pulse;

  // Timer registers (CLINT-style)
  logic [63:0] mtime;  // Machine time counter
  logic [63:0] mtimecmp;  // Machine timer compare register
  logic        msip;  // Machine software interrupt pending

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

  logic [NUM_HARTS-1:0] aplic_meip, aplic_seip;

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
  logic aplic_sel_q, imsic_sel_q, memerr_sel_q;
  always_ff @(posedge i_clk) begin
    imsic_sel_q <= riscv_pkg::pma_device_quadrant(
        riscv_pkg::XLEN'(data_memory_address)
    ) && (data_memory_address[31:21] == ImsicWindowSel);
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
  localparam int unsigned BaseAxilPorts = (ENABLE_1G_ETH != 0) ? 3 : 2;
  localparam int unsigned ExtAxilPort = BaseAxilPorts;
  localparam int unsigned AxilPorts = BaseAxilPorts + ((EXT_AXIL_WINDOW != 0) ? 1 : 0);
  localparam int unsigned RegAxilAddrBits = (EXT_AXIL_WINDOW != 0) ? 14 : 12;
  logic dma_engine_irq, nic_irq, nic_1g_irq;
  logic [AxilPorts-1:0] reg_axil_awvalid, reg_axil_awready, reg_axil_wvalid, reg_axil_wready;
  logic [AxilPorts-1:0] reg_axil_bvalid, reg_axil_bready, reg_axil_arvalid, reg_axil_arready;
  logic [AxilPorts-1:0] reg_axil_rvalid, reg_axil_rready;
  logic [AxilPorts*2-1:0] reg_axil_bresp, reg_axil_rresp;
  logic [AxilPorts*64-1:0] reg_axil_rdata;
  logic [RegAxilAddrBits-1:0] reg_axil_addr_q;
  logic [2:0] reg_axil_prot_q;
  logic [63:0] reg_axil_wdata_q;
  logic [7:0] reg_axil_wstrb_q;
  logic [$clog2(AxilPorts)-1:0] reg_axil_port_q;
  logic local_axil, reg_axil_done, reg_axil_read_capture;

`ifndef SYNTHESIS
  // Observe NIC-window accesses in both cached-tier configurations.
  logic nic_access_armed_q = 1'b0;
  logic nic_access_q;
  always_ff @(posedge i_clk) begin
    if (soc_axi_rst) nic_access_armed_q <= 1'b1;
    nic_access_q <= nic_access_armed_q && !soc_axi_rst && local_fire &&
        riscv_pkg::pma_device_quadrant(
        riscv_pkg::XLEN'(data_memory_address)
    ) && (data_memory_address[31:12] == NicBase[31:12]);
  end
`endif
  logic mmio_response_capture;
  logic [63:0] mmio_response_data;
  logic [31:0] boot_spi_ctrl_word, boot_sys_status_word;
  logic [31:0] boot_spi_rx_byte_word, boot_spi_rx_word_le;
  logic [31:0] boot_sram_addr_word, boot_sram_data_word;
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
  logic aplic_msi_valid, aplic_msi_ready;
  logic [55:0] aplic_msi_addr;
  logic [31:0] aplic_msi_data;
  logic imsic_cpu_write, imsic_write;
  logic [31:0] imsic_write_addr, imsic_write_data;
  assign imsic_cpu_write = imsic_sel_q &&
      ((data_memory_byte_write_enable_registered == 8'h0F) ||
       (data_memory_byte_write_enable_registered == 8'hF0));
  // CPU IPI stores win the single port. Invalid high APLIC addresses are
  // consumed and dropped before narrowing, never aliased into a valid page.
  logic msi_ready;
  logic local_valid, local_ready, local_write, local_error;
  logic [AXI_USER_BITS-1:0] local_req_user;
  logic local_debug_q, local_mirror_aborted_q;
  logic [riscv_pkg::PhysAddrBits-1:0] local_addr;
  logic [2:0] local_state_q;
  // Svpbmt: an access to the uncached alias of DDR (riscv_pkg "Svpbmt"). It
  // reaches the coherent DMA port as one single-beat transfer of the real DDR
  // address (state 6 below), never a local memory or register.
  wire local_pbmt_alias = riscv_pkg::pma_pbmt_alias_ok(riscv_pkg::XLEN'(local_addr));
  logic local_alias;
  logic alias_done;  // the alias transfer answered or its registered abort fired
  logic [1:0] alias_status;
  logic [63:0] alias_rdata;  // the addressed dword of an alias read
  wire local_imsic_pending = local_state_q == 4 && local_write && !local_pbmt_alias &&
      local_addr[31:21] == ImsicWindowSel;
  assign aplic_msi_ready = !imsic_cpu_write &&
      (!ASYNC_CPU_CLOCK || (!local_imsic_pending && msi_ready));
  // The CPU-clock FIFO takes soc_cpu_rst, which does not reset the writers here.
  assign imsic_write = (!ASYNC_CPU_CLOCK || !soc_cpu_rst) &&
      (imsic_cpu_write ||
       (aplic_msi_valid && aplic_msi_ready && (aplic_msi_addr[55:32] == '0)));
  assign imsic_write_addr = imsic_cpu_write ?
      {data_memory_address_registered[31:3],
       data_memory_byte_write_enable_registered[4] ? 3'b100 : 3'b000} : aplic_msi_addr[31:0];
  assign imsic_write_data = imsic_cpu_write ?
      (data_memory_byte_write_enable_registered[4] ? data_memory_write_data_registered[63:32] :
       data_memory_write_data_registered[31:0]) : aplic_msi_data;
  logic imsic_decode_write;
  logic [63:0] imsic_decode_payload;
  if (ASYNC_CPU_CLOCK) begin : gen_msi_cdc
    async_fifo #(
        .DATA_WIDTH(64),
        .DEPTH(8),
        .READY_MARGIN(0)
    ) messages (
        .i_limit('0),
        .o_occupancy(),
        .i_clk(i_clk),
        .i_rst(soc_cpu_rst),
        .i_data({imsic_write_addr, imsic_write_data}),
        .i_valid(imsic_write),
        .o_ready(msi_ready),
        .o_clk(core_clk),
        .o_rst(o_cpu_rst),
        .o_data(imsic_decode_payload),
        .o_valid(imsic_decode_write),
        .i_ready(1'b1)
    );
`ifndef SYNTHESIS
    bit reset_seen_q = 1'b0;
    always_ff @(posedge i_clk) begin
      if (soc_cpu_rst) reset_seen_q <= 1'b1;
      if (reset_seen_q && !soc_cpu_rst) assert (!imsic_write || msi_ready);
    end
`endif
  end else begin : gen_msi_direct
    assign msi_ready = 1'b1;
    assign imsic_decode_write = imsic_write;
    assign imsic_decode_payload = {imsic_write_addr, imsic_write_data};
  end
  imsic_decode #(
      .NUM_HARTS(NUM_HARTS),
      .NUM_IDS(63),
      .M_BASE_ADDR(ImsicMBase),
      .S_BASE_ADDR(ImsicSBase)
  ) imsic_store_decode (
      .i_clk(core_clk),
      .i_rst(o_cpu_rst),
      .i_wr_en(imsic_decode_write),
      .i_wr_addr(imsic_decode_payload[63:32]),
      .i_wr_data(imsic_decode_payload[31:0]),
      .o_msi_valid(o_cpu_msi_valid),
      .o_msi_level(o_cpu_msi_level),
      .o_msi_id(o_cpu_msi_id)
  );

  // The local request's size (registered below) qualifies the APLIC read.
  logic [2:0] local_size;
  aplic #(
      .NUM_SOURCES(5),
      .NUM_HARTS(NUM_HARTS),
      .IPRIOLEN(3),
      .MSI_ENABLE(1'b1),
      .MMSIADDRCFG_RESET(ImsicMBase >> 12),
      .MMSIADDRCFGH_RESET(32'h8000_0000 | (32'($clog2(NUM_HARTS)) << 12)),
      .SMSIADDRCFG_RESET(ImsicSBase >> 12),
      .SMSIADDRCFGH_RESET(32'b0)
  ) aplic_inst (
      .i_clk(i_clk),
      .i_rst(rst_core),
      // Source ID 1 = ns16550, ID 2 = the board pin, ID 3 = the DMA test
      // engine, ID 4 = the NIC, ID 5 = the memory error unit. The === clamp
      // keeps an un-driven i_external_interrupt in simulation from
      // propagating X into the APLIC and mip.
      .i_src({
        memerr_irq,
        nic_irq,
        dma_engine_irq,
        (i_external_interrupt === 1'b1) || nic_1g_irq,
        ns_irq_pending
      }),
      .i_wr_en(aplic_wr_en),
      .i_wr_offset({data_memory_address_registered[21:3], aplic_wr_hi ? 3'b100 : 3'b000}),
      .i_wr_data(aplic_wr_hi ? data_memory_write_data_registered[63:32] :
                              data_memory_write_data_registered[31:0]),
      .i_rd_offset(mmio_load_addr[21:0]),
      .o_rd_pair(aplic_rd_pair),
      .i_rd_capture(mmio_read_capture && (mmio_load_addr[31:22] == AplicWindowSel) &&
                    (local_size == 3'd2)),
      .o_meip(aplic_meip),
      .o_seip(aplic_seip),
      .o_msi_valid(aplic_msi_valid),
      .i_msi_ready(aplic_msi_ready),
      .o_msi_addr(aplic_msi_addr),
      .o_msi_data(aplic_msi_data)
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
  logic [ 5:0] cpu_debug_irq_status;
  logic [31:0] cpu_debug_commit_pc;
  logic [31:0] cpu_debug_commit_2_pc;
  logic [ 1:0] cpu_debug_commit_valid;


  logic dbg_haltreq, dbg_go, dbg_data_we, dbg_debug_mode, dbg_parked, dbg_cmd_err, dbg_go_taken;
  logic [31:0] dbg_go_addr;
  logic [63:0] dbg_data, dbg_data_wdata;
  logic dbg_bram_store;
  logic [31:0] dbg_bram_store_addr;
  logic [7:0] dbg_bram_store_strb;
  // A fabric reset discards transport ownership, so reset CPU owners too.
  if (ASYNC_CPU_CLOCK) begin : gen_soc_cpu_reset_async
    assign soc_cpu_rst = rst_core || soc_axi_rst;
  end else begin : gen_soc_cpu_reset_common
    // Assert with the DMA bridge and keep the ingress in reset for the
    // following edge, even when the core request lasts only one cycle.
    always_ff @(posedge i_clk) soc_cpu_rst <= rst_core_next || rst_core;
  end
  if (ASYNC_CPU_CLOCK) begin : gen_cpu_controls
    cdc_sync #(
        .WIDTH(4)
    ) interrupt_sync (
        .i_clk  (core_clk),
        .i_rst  (o_cpu_rst),
        .i_async({aplic_seip[0], interrupts}),
        .o_sync ({o_cpu_seip, o_cpu_interrupts})
    );
    cdc_mailbox #(
        .WIDTH(64)
    ) timer_snapshot (
        .i_src_clk  (i_clk),
        .i_src_rst  (soc_cpu_rst),
        .i_src_data (mtime),
        .i_src_valid(1'b1),
        .o_src_ready(),
        .o_src_idle (),
        .i_dst_clk  (core_clk),
        .i_dst_rst  (o_cpu_rst),
        .o_dst_data (o_cpu_mtime),
        .o_dst_valid(),
        .i_dst_ready(1'b1)
    );
  end else begin : gen_common_clock_controls
    assign o_cpu_interrupts = interrupts;
    assign o_cpu_seip = aplic_seip[0];
    assign o_cpu_mtime = mtime;
  end
  assign o_dbg_haltreq = dbg_haltreq;
  assign o_dbg_go = dbg_go;
  assign o_dbg_go_addr = dbg_go_addr;
  assign o_dbg_data = dbg_data;
  assign dbg_data_we = i_dbg_data_we;
  assign dbg_data_wdata = i_dbg_data_wdata;
  assign dbg_debug_mode = i_debug_mode;
  assign dbg_parked = i_dbg_parked;
  assign dbg_cmd_err = i_dbg_cmd_err;
  assign dbg_go_taken = i_dbg_go_taken;
  if (ASYNC_CPU_CLOCK) begin : gen_diagnostic_cdc
    logic activity_q, snapshot_ready, snapshot_valid;
    logic [63:0] pc_q, pc2_q;
    logic [  1:0] valid_q;
    logic [136:0] snapshot;
    always_ff @(posedge core_clk) begin
      if (o_cpu_rst) begin
        activity_q <= 1'b0;
        valid_q <= '0;
        pc_q <= '0;
        pc2_q <= '0;
      end else begin
        activity_q <= (activity_q && !snapshot_ready) || i_commit_valid;
        if (i_debug_commit_valid[0]) pc_q <= i_debug_commit_pc;
        if (i_debug_commit_valid[1]) pc2_q <= i_debug_commit_2_pc;
        valid_q <= (valid_q & {2{!snapshot_ready}}) | i_debug_commit_valid;
      end
    end
    cdc_mailbox #(
        .WIDTH(137)
    ) observations (
        .i_src_clk  (core_clk),
        .i_src_rst  (o_cpu_rst),
        .i_src_data ({activity_q, i_debug_irq_status, valid_q, pc_q, pc2_q}),
        .i_src_valid(1'b1),
        .o_src_ready(snapshot_ready),
        .o_src_idle (),
        .i_dst_clk  (i_clk),
        .i_dst_rst  (soc_cpu_rst),
        .o_dst_data (snapshot),
        .o_dst_valid(snapshot_valid),
        .i_dst_ready(1'b1)
    );
    assign commit_vld = snapshot_valid && snapshot[136];
    assign cpu_debug_irq_status = snapshot[135:130];
    assign cpu_debug_commit_valid = snapshot[129:128] & {2{snapshot_valid}};
    assign cpu_debug_commit_pc = snapshot[95:64];
    assign cpu_debug_commit_2_pc = snapshot[31:0];
    assign program_counter = snapshot[127:64];
  end else begin : gen_diagnostic_direct
    assign commit_vld = i_commit_valid;
    assign cpu_debug_irq_status = i_debug_irq_status;
    assign cpu_debug_commit_pc = i_debug_commit_pc[31:0];
    assign cpu_debug_commit_2_pc = i_debug_commit_2_pc[31:0];
    assign cpu_debug_commit_valid = i_debug_commit_valid;
    assign program_counter = i_debug_commit_pc;
  end
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
        .i_clk  (core_clk),
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
      .i_clk(core_clk),
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
  wire use_incoming_payload = local_state_q == 0;
  wire store_debug_mode = ASYNC_CPU_CLOCK ?
      (use_incoming_payload ? local_req_user[0] : local_debug_q) : dbg_debug_mode;
  // dbg_bram_store is the OR of dbg_bram_store_strb (cpu_ooo), so either
  // half's strobes imply it.
  assign mirror_lo = store_debug_mode && (|dbg_bram_store_strb[3:0]);
  assign mirror_hi = store_debug_mode && (|dbg_bram_store_strb[7:4]);
  // Mirror the held word 1 first, else the new store's word 0 or lone word 1.
  // mirror_lo || mirror_hi equals store_debug_mode && dbg_bram_store.
  assign mirror_now_valid = mirror_hold_valid_q || (store_debug_mode && dbg_bram_store);
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
    if (debug_soc_rst) mirror_overflow_q <= 1'b0;
    else mirror_overflow_q <= mirror_overflow;
  end
  if (1'b1) begin : gen_coherent_mirror_hold
    debug_store_mirror_hold #(
        .ADDR_WIDTH(MemWordAddrWidth)
    ) mirror_hold (
        .i_clk,
        .i_rst  (debug_soc_rst),
        .i_push (mirror_lo && mirror_hi && slice_req_ready),
        .i_pop  (slice_req_ready),
        .i_addr ({dbg_bram_store_addr[MemByteAddrWidth-1:3], 1'b1}),
        .o_valid(mirror_hold_valid_q),
        .o_addr (mirror_hold_addr_q)
    );
  end
  logic dm_request_ready, dm_all_done;
  logic dm_soc_valid;
  logic [MemByteAddrWidth-1:2] dm_soc_addr;
  logic [31:0] dm_soc_data;
  if (ASYNC_CPU_CLOCK) begin : gen_debug_slice_cdc
    logic waiting_q, request_valid;
    logic [MemByteAddrWidth+29:0] request_data;
    cdc_mailbox #(
        .WIDTH(MemByteAddrWidth + 30)
    ) requests (
        .i_src_clk  (core_clk),
        .i_src_rst  (debug_cpu_rst),
        .i_src_data ({dm_slice_word_addr, dm_slice_data}),
        .i_src_valid(dm_slice_req_valid),
        .o_src_ready(dm_request_ready),
        .o_src_idle (dm_all_done),
        .i_dst_clk  (i_clk),
        .i_dst_rst  (debug_soc_rst),
        .o_dst_data (request_data),
        .o_dst_valid(request_valid),
        .i_dst_ready(waiting_q && slice_all_done)
    );
    always_ff @(posedge i_clk) begin
      if (debug_soc_rst) waiting_q <= 1'b0;
      else if (waiting_q && slice_all_done) waiting_q <= 1'b0;
      else if (dm_soc_valid && slice_req_ready && !mirror_now_valid) waiting_q <= 1'b1;
    end
    assign dm_soc_valid = request_valid && !waiting_q;
    assign {dm_soc_addr, dm_soc_data} = request_data;
  end else begin : gen_debug_slice_direct
    assign dm_request_ready = slice_req_ready && !mirror_now_valid;
    assign dm_all_done = slice_all_done;
    assign dm_soc_valid = dm_slice_req_valid;
    assign dm_soc_addr = dm_slice_word_addr;
    assign dm_soc_data = dm_slice_data;
  end
  logic boot_sram_wr_req_q;
  logic [MemByteAddrWidth-1:2] boot_sram_word_addr_q;
  logic [31:0] boot_sram_wdata_q;
  wire boot_sram_slice_valid = (ENABLE_1G_ETH != 0) &&
      boot_sram_wr_req_q && !mirror_now_valid && !dm_soc_valid;
  assign slice_req_valid = mirror_now_valid || dm_soc_valid || boot_sram_slice_valid;
  // In the asynchronous configuration each Debug-Mode store response waits
  // for its mirror. The synchronous configuration waits at fence completion.
  // Program-buffer writes also complete before the debug module issues GO.
  // Registered for timing. A store requests its mirror on its write edge,
  // before its response, and a fence starts only after the responses of
  // older stores, so the registered value already includes their mirrors.
  logic imem_sync_done_q;
  always_ff @(posedge core_clk)
    imem_sync_done_q <= ASYNC_CPU_CLOCK ? dm_all_done : slice_all_done && !slice_req_valid;
  assign o_imem_sync_done = imem_sync_done_q;
  assign slice_req_mirror = mirror_now_valid;
  assign slice_req_word_addr = mirror_now_valid ? mirror_now_addr :
      (ENABLE_1G_ETH == 0 || dm_soc_valid) ? dm_soc_addr : boot_sram_word_addr_q;
  assign slice_req_data = (ENABLE_1G_ETH == 0 || dm_soc_valid) ? dm_soc_data : boot_sram_wdata_q;

  debug_module #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth)
  ) u_debug_module (
      .i_power_on_rst(power_on_rst_core),
      .i_clk(core_clk),
      .i_rst(debug_cpu_rst),
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
      // The debug module reports the core's reset as status.
      .i_core_in_reset(ASYNC_CPU_CLOCK ? o_cpu_rst : rst_core),
      .i_hart_fatal_stop(i_dbg_fatal_stop),
      .o_ndmreset(dbg_ndmreset),
      .o_slice_req_valid(dm_slice_req_valid),
      .o_slice_word_addr(dm_slice_word_addr),
      .o_slice_data(dm_slice_data),
      .i_slice_req_ready(dm_request_ready),
      .i_slice_all_done(dm_all_done),
      .i_slice_overflow(ASYNC_CPU_CLOCK ? 1'b0 : mirror_overflow_q)
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
      .i_rst(debug_soc_rst),
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

  // Instruction memory: code-region words for the local AXI responder.
  // Fetches above this region carry an access fault, so aliased data cannot
  // execute. Port A programs on div4; port B fetches on the main clock.
  imem_predecode #(
      .ADDR_WIDTH(ImemWordAddrWidth),
      .ENABLE_FETCH_METADATA(1'b0),
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
      // Port B: Instruction fetch (main clock, read only), at the local
      // request's physical word pair.
      .i_port_b_clk(i_clk),
      .i_port_b_enable(1'b1),
      .i_port_b_byte_address(fetch_pa_word0),
      .i_port_b_next_byte_address(fetch_pa_word1),
      .o_port_b_read_data(bram_fetch_instr),
      .o_port_b_read_data_by_parity(),
      .o_port_b_sideband(),
      .o_port_b_pc_metadata(),
      .o_port_b_pc_metadata_by_parity(),
      .o_port_b_pc_pairability_by_parity(),
      .o_port_b_slot2_start_valid_lo_by_parity(),
      .o_port_b_window_overlay_hit(),
      .o_port_b_response_ready(),
      .o_port_b_bank_sel_r()
  );


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


  logic local_req_write, local_req_error;
  // debug_soc_rst drops the mirror's slice writes, so a store stops waiting for them.
  wire debug_store_room = !ASYNC_CPU_CLOCK || !store_debug_mode || debug_soc_rst ||
      (slice_req_ready && !mirror_hold_valid_q);
  wire debug_store_done = !ASYNC_CPU_CLOCK || !local_debug_q || !local_write ||
      debug_soc_rst || local_mirror_aborted_q || (slice_all_done && !mirror_hold_valid_q);
  logic [riscv_pkg::PhysAddrBits-1:0] local_req_addr;
  logic [2:0] local_req_size, local_req_prot;
  logic [63:0] local_req_wdata;
  logic [ 7:0] local_req_wstrb;
  logic [ 2:0] local_prot;
  logic [63:0] local_wdata;
  logic [ 7:0] local_wstrb;
  logic local_resp_valid, local_resp_ready;
  logic [L2_LINE_BYTES*8-1:0] local_resp_data;
  logic [1:0] local_resp_status;
  logic fast_bram_q;
  wire fast_bram_request = !local_req_error && !local_req_prot[2] &&
      local_req_size <= 3 && 64'(local_req_addr) < 64'(MEM_SIZE_BYTES);
  wire fast_bram_fire = local_valid && local_ready && fast_bram_request;
  logic [1:0] local_dword_q;
  wire local_line = local_size == 5 && local_instruction && !local_error;


  logic local_read_instruction_q, local_read_device_q;
  logic [15:0] fetch_fuzz_lfsr_q;
  always_ff @(posedge i_clk) begin
    if (soc_axi_rst) fetch_fuzz_lfsr_q <= 16'(FETCH_VALID_FUZZ_SEED);
    else
      fetch_fuzz_lfsr_q <= {
        fetch_fuzz_lfsr_q[14:0],
        (fetch_fuzz_lfsr_q[15] ^ fetch_fuzz_lfsr_q[13]) ^
               (fetch_fuzz_lfsr_q[12] ^ fetch_fuzz_lfsr_q[10])
      };
  end
  // The local bus's memories and devices are not reset by soc_axi_rst.
  assign local_ready = local_state_q == 0 && !soc_axi_rst && debug_store_room;
  // MMIO captures the chosen request before decoding or executing it. Narrow
  // BRAM requests can access the synchronous RAM on acceptance; their response
  // still waits for that read/write edge. Both paths retain the payload.
  assign local_fire = local_state_q == 4 && !soc_axi_rst && debug_store_room &&
      (!ASYNC_CPU_CLOCK || !local_imsic_pending || soc_cpu_rst || msi_ready);
  assign local_bram = 64'(local_addr) < 64'(MEM_SIZE_BYTES);
  // The alias window is served by the DMA transfer of state 6.
  assign local_device = riscv_pkg::pma_device_ok(riscv_pkg::XLEN'(local_addr)) && !local_pbmt_alias;
  assign local_alias = (ENABLE_CACHED_TIER != 0) && local_pbmt_alias;
  assign local_instruction = local_prot[2];
  assign local_ok = !local_error &&
      (local_instruction ? !local_write && 64'(local_addr) < (64'd1 << ImemByteAddrWidth) :
       local_bram || local_device || local_alias);
  wire [riscv_pkg::PhysAddrBits-1:0] local_lane_addr = local_line ?
      {local_addr[riscv_pkg::PhysAddrBits-1:5], local_dword_q, 3'b0} : local_addr;
  // A fast BRAM access is accepted only in state 0 and a staged access runs
  // only in state 4, so the state alone selects the payload; the enables
  // still decide whether anything is read or written.
  assign data_memory_address = use_incoming_payload ? local_req_addr : local_lane_addr;
  // Register files take replicated word writes; AXI permits the
  // unused lanes to be arbitrary, so reconstruct that view at this boundary.
  assign data_memory_write_data = use_incoming_payload ? local_req_wdata[63:0] :
      (local_device && local_size <= 2) ?
      {2{local_addr[2] ? local_wdata[63:32] : local_wdata[31:0]}} : local_wdata;
  wire local_register_store = local_fire && local_write && local_ok && !local_axil && !local_alias;
  assign data_memory_byte_write_enable = fast_bram_fire && local_req_write ?
      local_req_wstrb[7:0] : local_register_store ? local_wstrb : '0;
  wire fast_bram_store = fast_bram_fire && local_req_write;
  wire staged_bram_store = local_fire && local_write && local_ok && local_bram;
  assign data_memory_bram_byte_write_enable =
      ({8{fast_bram_store}} & local_req_wstrb) | ({8{staged_bram_store}} & local_wstrb);
  assign data_memory_read_enable = local_fire && !local_write && local_ok && !local_instruction &&
      !local_alias;
  // Instruction reads always use the registered local request. The fast
  // acceptance path serves data only; its arbitration leaves the
  // instruction RAM address to the registered instruction request.
  // Once the first dword is in the synchronous RAM output, request its
  // successor while capturing the current one. A line then delivers one
  // dword per clock; only the final response waits for optional fetch fuzz.
  // Rejected requests discard their data, so PMA decoding need not gate
  // this read-only lookahead address. Execution/status still use local_ok.
  wire [1:0] instruction_read_dword = local_dword_q + 2'(local_line && local_state_q == 1);
  wire [31:0] instruction_read_addr = local_line ?
      {local_addr[31:5], instruction_read_dword, 3'b000} : local_addr[31:0];
  assign fetch_pa_word0 = {instruction_read_addr[31:3], 3'b000};
  assign fetch_pa_word1 = {instruction_read_addr[31:3], 3'b100};
  assign mmio_load_addr = local_addr[31:0];
  assign mmio_load_valid = local_state_q != 0;
  assign mmio_read_pulse = local_fire && !local_write && local_device && local_ok && !local_axil;
  // Reduce each strobe candidate before selecting its launch, keeping the
  // late AXI arbitration off a byte-mux/reduction chain into the CDC FIFO.
  assign dbg_bram_store = (fast_bram_store && (|local_req_wstrb)) ||
      (staged_bram_store && (|local_wstrb));
  assign dbg_bram_store_addr = use_incoming_payload ? local_req_addr[31:0] : local_addr[31:0];
  assign dbg_bram_store_strb = data_memory_bram_byte_write_enable;

`ifndef SYNTHESIS
`ifdef FORMAL
  wire bram_check_armed = 1'b1;
`else
  // These checks use AXI-domain state; wait for that domain's first reset.
  logic bram_axi_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (soc_axi_rst) bram_axi_reset_seen_q <= 1'b1;
  wire bram_check_armed = bram_axi_reset_seen_q;
`endif
  always @(posedge i_clk) begin
    if (bram_check_armed && !soc_axi_rst) begin
      assert (data_memory_bram_byte_write_enable ==
          ((fast_bram_fire || local_bram) ? data_memory_byte_write_enable : 8'b0));
      assert (dbg_bram_store == (|data_memory_bram_byte_write_enable));
      if (dbg_bram_store) assert (dbg_bram_store_addr == data_memory_address[31:0]);
      if (local_fire && local_instruction)
        assert (fetch_pa_word0 == {data_memory_address[31:3], 3'b000} &&
                fetch_pa_word1 == {data_memory_address[31:3], 3'b100});
    end
  end
`endif
  wire [63:0] local_read_word = local_read_instruction_q ? bram_fetch_instr :
      local_read_device_q ? mmio_read_data_reg : data_memory_read_data;
  always_ff @(posedge i_clk) begin
    if (soc_axi_rst) begin
      local_state_q <= 0;
      local_resp_valid <= 1'b0;
      mmio_fifo0_read_pulse <= 1'b0;
      mmio_fifo1_read_pulse <= 1'b0;
      mmio_uart_rx_ready_pulse <= 1'b0;
    end else begin
      mmio_fifo0_read_pulse <= mmio_read_pulse && mmio_load_addr == Fifo0MmioAddr;
      mmio_fifo1_read_pulse <= mmio_read_pulse && mmio_load_addr == Fifo1MmioAddr;
      mmio_uart_rx_ready_pulse <= mmio_read_pulse && mmio_load_addr == UartRxDataMmioAddr;
      if (local_valid && local_ready) begin
        local_state_q <= fast_bram_request ? 1 : 4;
        fast_bram_q   <= fast_bram_request;
        if (fast_bram_request) begin
          local_read_instruction_q <= 1'b0;
          local_read_device_q <= 1'b0;
          local_resp_status <= 2'b00;
        end
        local_dword_q <= 0;
        local_resp_data <= 0;
        local_write <= local_req_write;
        local_debug_q <= local_req_user[0];
        local_mirror_aborted_q <= ASYNC_CPU_CLOCK && debug_soc_rst;
        local_error <= local_req_error;
        local_addr <= local_req_addr;
        local_size <= local_req_size;
        local_prot <= local_req_prot;
        local_wdata <= local_req_wdata;
        local_wstrb <= local_req_wstrb;
      end else if (local_fire) begin
        local_state_q <= local_axil ? 5 : (local_alias && local_ok) ? 6 : 1;
        local_read_instruction_q <= local_instruction;
        // An alias read returns through the MMIO read register.
        local_read_device_q <= local_device || local_alias;
        local_resp_status <= local_ok ? 2'b00 : 2'b11;
      end else if (alias_done) begin
        local_state_q <= 1;
        local_resp_status <= alias_status;
      end else if (reg_axil_done) begin
        local_state_q <= 1;
        local_resp_status <= rst_core ? 2'b00 : local_write ?
            reg_axil_bresp[reg_axil_port_q*2+:2] : reg_axil_rresp[reg_axil_port_q*2+:2];
      end else if (local_state_q == 1 && debug_store_done) begin
        local_state_q <= fast_bram_q ? 3 : 2;
        if (fast_bram_q) local_resp_valid <= 1'b1;
        if (local_line) begin
          local_resp_data[local_dword_q*64+:64] <= local_read_word;
          if (local_ok && local_dword_q != 2'd3) begin
            local_dword_q <= local_dword_q + 1'b1;
            local_state_q <= 1;
          end
        end else local_resp_data <= (L2_LINE_BYTES * 8)'(local_read_word);
      end else if (local_state_q == 2 && debug_store_done &&
                   (FETCH_VALID_FUZZ == 0 || !local_read_instruction_q ||
                    fetch_fuzz_lfsr_q[1:0] == 0)) begin
        // All register writes and destructive-read pulses have landed before
        // completion. Backpressure holds the response, never repeats access.
        local_state_q <= 3;
        local_resp_valid <= 1'b1;
      end else if (local_resp_valid && local_resp_ready) begin
        local_resp_valid <= 1'b0;
        local_state_q <= 0;
      end
      // External reset cancels the slice writer. A discarded mirror is an
      // error, even when the data copy has already accepted the store.
      if (ASYNC_CPU_CLOCK && local_debug_q && local_write &&
          (local_state_q == 1 || local_state_q == 2 || local_state_q == 4)) begin
        if (debug_soc_rst) local_mirror_aborted_q <= 1'b1;
        if (debug_soc_rst || local_mirror_aborted_q) local_resp_status <= 2'b10;
      end
    end
  end
  // Port 0 is the NIC; port 1 is the DMA test engine; port 2 (when
  // ENABLE_1G_ETH != 0) is the 1G SGMII NIC; ExtAxilPort (when
  // EXT_AXIL_WINDOW != 0) is the external 16 KiB window at 0x4002_4000.
  // Only their windows enter state 5. Request payloads and each channel VALID
  // hold until the corresponding handshake, and completion waits for B or R.
  // Request presentation shares rst_core with the register slaves. The
  // local transaction state takes fabric reset and can abort on core reset.
  wire local_axil_cached = (ENABLE_CACHED_TIER != 0) &&
      ((local_addr[31:12] == NicBase[31:12]) ||
       (local_addr[31:8] == DmaEngineBase[31:8]) ||
       ((ENABLE_1G_ETH != 0) && (local_addr[31:12] == Nic1gBase[31:12])));
  wire local_axil_ext = (EXT_AXIL_WINDOW != 0) && (local_addr[31:14] == ExtAxilBase[31:14]);
  assign local_axil = !rst_core && local_ok && local_device && !local_instruction &&
      (local_axil_cached || local_axil_ext);
  wire [$clog2(
AxilPorts
)-1:0] local_axil_port = local_axil_ext ? $clog2(
      AxilPorts
  )'(ExtAxilPort) : (local_addr[31:12] == NicBase[31:12]) ?
      '0 : ((ENABLE_1G_ETH != 0) && (local_addr[31:12] == Nic1gBase[31:12])) ? $clog2(
      AxilPorts
  )'(2) : $clog2(
      AxilPorts
  )'(1);
  // The register slaves are in reset with rst_core, so a reply is not waited for.
  assign reg_axil_bready = (local_state_q == 5 && local_write && !rst_core &&
      !soc_axi_rst) ? (AxilPorts'(1) << reg_axil_port_q) : '0;
  assign reg_axil_rready = (local_state_q == 5 && !local_write && !rst_core &&
      !soc_axi_rst) ? (AxilPorts'(1) << reg_axil_port_q) : '0;
  assign reg_axil_done = local_state_q == 5 && !soc_axi_rst &&
      (rst_core || (|(reg_axil_bvalid & reg_axil_bready)) ||
       (|(reg_axil_rvalid & reg_axil_rready)));
  assign reg_axil_read_capture = reg_axil_done && !local_write;
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      reg_axil_awvalid <= '0;
      reg_axil_wvalid  <= '0;
      reg_axil_arvalid <= '0;
      reg_axil_port_q  <= '0;
    end else begin
      reg_axil_awvalid <= reg_axil_awvalid & ~reg_axil_awready;
      reg_axil_wvalid  <= reg_axil_wvalid & ~reg_axil_wready;
      reg_axil_arvalid <= reg_axil_arvalid & ~reg_axil_arready;
      if (local_fire && local_axil) begin
        reg_axil_addr_q  <= local_addr[RegAxilAddrBits-1:0];
        reg_axil_prot_q  <= local_prot;
        reg_axil_wdata_q <= data_memory_write_data;
        reg_axil_wstrb_q <= local_wstrb;
        reg_axil_port_q  <= local_axil_port;
        if (local_write) begin
          reg_axil_awvalid <= AxilPorts'(1) << local_axil_port;
          reg_axil_wvalid  <= AxilPorts'(1) << local_axil_port;
        end else begin
          reg_axil_arvalid <= AxilPorts'(1) << local_axil_port;
        end
      end
    end
  end

  if (ENABLE_CACHED_TIER != 0) begin : gen_cached_tier
    // DMA: the NIC (port 0) and the DMA test engine (port 1) are AXI4 masters
    // on dma_interconnect, whose one master enters the hierarchy's coherent
    // DMA port through dma_bridge (hw/rtl/lib/axi/README.md). The bus is 256
    // bits, one beat per line. The bridge's three-bit line ids are
    // zero-extended at the ingress. The bridge uses the CPU clock
    // when ASYNC_CPU_CLOCK is set. Paired resets cover both DMA domains.
    // The common-clock profile resets all four blocks with rst_core.
    // AliasPort carries the hart's Svpbmt NC and IO accesses to DDR; any
    // external DMA ports follow it, each behind an axi_register_slice.
    localparam int unsigned BaseDmaPorts = (ENABLE_1G_ETH != 0) ? 4 : 3;
    localparam int unsigned AliasPort = BaseDmaPorts - 1;
    localparam int unsigned DmaPorts = BaseDmaPorts + EXT_DMA_PORTS;
    localparam int unsigned DmaAxiAddrBits = 64;
    localparam int unsigned DmaAxiDataBits = 8 * L1LineBytes;
    localparam int unsigned DmaStrbBits = DmaAxiDataBits / 8;
    // The NIC's ids are 3 bits; the engine's 2-bit ids are zero-extended.
    // Widen if external DMA ports carry wider IDs.
    localparam int unsigned DmaUpIdBits =
        (EXT_DMA_PORTS > 0 && EXT_DMA_ID_BITS > 3) ? EXT_DMA_ID_BITS : 3;
    localparam int unsigned DmaDownIdBits = DmaUpIdBits + $clog2(DmaPorts);
    // Eight read and eight write line IDs, the coherent line ID's full width.
    localparam int unsigned DmaLineIdBits = 4;

    logic [DmaPorts-1:0] up_awvalid, up_awready, up_awlock, up_wvalid, up_wready, up_wlast;
    logic [DmaPorts-1:0] up_bvalid, up_bready, up_arvalid, up_arready, up_arlock;
    logic [DmaPorts-1:0] up_rvalid, up_rready, up_rlast;
    // Fields wider than a bit are flat vectors, port p's field at
    // [p*width+:width]. Yosys's read_verilog can misread an element select of
    // a multidimensional packed array declared in a generate block: assigning
    // an element can stop with an error, and with a named element type it can
    // take a single index as a bit select.
    logic [DmaPorts*DmaUpIdBits-1:0] up_awid, up_bid, up_arid, up_rid;
    logic [DmaPorts*DmaAxiAddrBits-1:0] up_awaddr, up_araddr;
    logic [DmaPorts*8-1:0] up_awlen, up_arlen;
    logic [DmaPorts*3-1:0] up_awsize, up_arsize, up_awprot, up_arprot;
    logic [DmaPorts*2-1:0] up_awburst, up_arburst, up_bresp, up_rresp;
    logic [DmaPorts*4-1:0] up_awcache, up_arcache, up_awqos, up_arqos;
    logic [DmaPorts*DmaAxiDataBits-1:0] up_wdata, up_rdata;
    logic [DmaPorts*DmaStrbBits-1:0] up_wstrb;

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

    localparam int unsigned NicLimitBits = $clog2(NicRxFifoDepth) + 1;
    // Matches nic_pkg::NumMacTotals * 64 (kept flat for Yosys read_verilog).
    localparam int unsigned NicMacTotalsBits = 21 * 64;

    logic nic_mac_tx_tvalid, nic_mac_tx_tready, nic_mac_tx_tlast, nic_mac_tx_tuser;
    logic [63:0] nic_mac_tx_tdata;
    logic [ 7:0] nic_mac_tx_tkeep;
    logic [14:0] nic_mac_tx_csum;
    logic nic_mac_rx_tvalid, nic_mac_rx_tready, nic_mac_rx_tlast;
    logic [63:0] nic_mac_rx_tdata;
    logic [ 7:0] nic_mac_rx_tkeep;
    logic nic_mac_rst, nic_mac_soft_rst, nic_mac_restart;
    logic [1:0] nic_mac_ready;
    logic [7:0] nic_mac_link;
    logic nic_mac_raw_loopback_en, nic_mac_loopback;
    logic [47:0] nic_mac_station_addr;
    logic [ 1:0] nic_mac_pause_ctrl;
    logic [NicLimitBits-1:0] nic_mac_pause_high_water, nic_mac_pause_low_water;
    logic [15:0] nic_mac_pause_interval;
    logic [NicLimitBits-1:0] nic_mac_rx_fifo_limit;
    logic nic_mac_rx_fifo_limit_wr, nic_mac_rx_fifo_limit_busy;
    logic nic_mac_rx_desc_starved;
    logic [NicMacTotalsBits-1:0] nic_mac_totals;

    nic_engine #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L1LineBytes),
        .APERTURE_BASE(64'(CACHED_BASE)),
        .APERTURE_BYTES(CACHED_SIZE_BYTES),
        .TICK_DEFAULT(CLK_FREQ_HZ / 1_000_000),
        .RX_FIFO_DEPTH(NicRxFifoDepth),
        .DMA_AXI_ADDR_BITS(DmaAxiAddrBits),
        .DMA_AXI_ID_BITS(DmaUpIdBits),
        .ENABLE_PHY_DIAG(1'b0)
    ) nic (
        .i_clk(i_clk),
        .i_rst(rst_core_next),  // registered inside nic_engine; see its header
        .i_reg_axil_awvalid(reg_axil_awvalid[0]),
        .o_reg_axil_awready(reg_axil_awready[0]),
        .i_reg_axil_awaddr(reg_axil_addr_q[11:0]),
        .i_reg_axil_awprot(reg_axil_prot_q),
        .i_reg_axil_wvalid(reg_axil_wvalid[0]),
        .o_reg_axil_wready(reg_axil_wready[0]),
        .i_reg_axil_wdata(reg_axil_wdata_q),
        .i_reg_axil_wstrb(reg_axil_wstrb_q),
        .o_reg_axil_bvalid(reg_axil_bvalid[0]),
        .i_reg_axil_bready(reg_axil_bready[0]),
        .o_reg_axil_bresp(reg_axil_bresp[0*2+:2]),
        .i_reg_axil_arvalid(reg_axil_arvalid[0]),
        .o_reg_axil_arready(reg_axil_arready[0]),
        .i_reg_axil_araddr(reg_axil_addr_q[11:0]),
        .i_reg_axil_arprot(reg_axil_prot_q),
        .o_reg_axil_rvalid(reg_axil_rvalid[0]),
        .i_reg_axil_rready(reg_axil_rready[0]),
        .o_reg_axil_rdata(reg_axil_rdata[0*64+:64]),
        .o_reg_axil_rresp(reg_axil_rresp[0*2+:2]),
        .o_irq(nic_irq),
        .o_dma_axi_awvalid(up_awvalid[0]),
        .o_dma_axi_awid(up_awid[0*DmaUpIdBits+:DmaUpIdBits]),
        .o_dma_axi_awaddr(up_awaddr[0*DmaAxiAddrBits+:DmaAxiAddrBits]),
        .o_dma_axi_awlen(up_awlen[0*8+:8]),
        .o_dma_axi_awsize(up_awsize[0*3+:3]),
        .o_dma_axi_awburst(up_awburst[0*2+:2]),
        .o_dma_axi_awlock(up_awlock[0]),
        .o_dma_axi_awcache(up_awcache[0*4+:4]),
        .o_dma_axi_awprot(up_awprot[0*3+:3]),
        .o_dma_axi_awqos(up_awqos[0*4+:4]),
        .o_dma_axi_wvalid(up_wvalid[0]),
        .o_dma_axi_wdata(up_wdata[0*DmaAxiDataBits+:DmaAxiDataBits]),
        .o_dma_axi_wstrb(up_wstrb[0*DmaStrbBits+:DmaStrbBits]),
        .o_dma_axi_wlast(up_wlast[0]),
        .o_dma_axi_bready(up_bready[0]),
        .o_dma_axi_arvalid(up_arvalid[0]),
        .o_dma_axi_arid(up_arid[0*DmaUpIdBits+:DmaUpIdBits]),
        .o_dma_axi_araddr(up_araddr[0*DmaAxiAddrBits+:DmaAxiAddrBits]),
        .o_dma_axi_arlen(up_arlen[0*8+:8]),
        .o_dma_axi_arsize(up_arsize[0*3+:3]),
        .o_dma_axi_arburst(up_arburst[0*2+:2]),
        .o_dma_axi_arlock(up_arlock[0]),
        .o_dma_axi_arcache(up_arcache[0*4+:4]),
        .o_dma_axi_arprot(up_arprot[0*3+:3]),
        .o_dma_axi_arqos(up_arqos[0*4+:4]),
        .o_dma_axi_rready(up_rready[0]),
        .i_dma_axi_awready(up_awready[0]),
        .i_dma_axi_wready(up_wready[0]),
        .i_dma_axi_bvalid(up_bvalid[0]),
        .i_dma_axi_bid(up_bid[0*DmaUpIdBits+:DmaUpIdBits]),
        .i_dma_axi_bresp(up_bresp[0*2+:2]),
        .i_dma_axi_arready(up_arready[0]),
        .i_dma_axi_rvalid(up_rvalid[0]),
        .i_dma_axi_rid(up_rid[0*DmaUpIdBits+:DmaUpIdBits]),
        .i_dma_axi_rdata(up_rdata[0*DmaAxiDataBits+:DmaAxiDataBits]),
        .i_dma_axi_rresp(up_rresp[0*2+:2]),
        .i_dma_axi_rlast(up_rlast[0]),
        .o_mac_tx_tvalid(nic_mac_tx_tvalid),
        .i_mac_tx_tready(nic_mac_tx_tready),
        .o_mac_tx_tdata(nic_mac_tx_tdata),
        .o_mac_tx_tkeep(nic_mac_tx_tkeep),
        .o_mac_tx_tlast(nic_mac_tx_tlast),
        .o_mac_tx_tuser(nic_mac_tx_tuser),
        .o_mac_tx_csum(nic_mac_tx_csum),
        .i_mac_rx_tvalid(nic_mac_rx_tvalid),
        .o_mac_rx_tready(nic_mac_rx_tready),
        .i_mac_rx_tdata(nic_mac_rx_tdata),
        .i_mac_rx_tkeep(nic_mac_rx_tkeep),
        .i_mac_rx_tlast(nic_mac_rx_tlast),
        .o_mac_rst(nic_mac_rst),
        .o_mac_soft_rst(nic_mac_soft_rst),
        .o_mac_restart(nic_mac_restart),
        .i_mac_ready(nic_mac_ready),
        .i_mac_link(nic_mac_link),
        .i_mac_raw_loopback_en(nic_mac_raw_loopback_en),
        .o_mac_loopback(nic_mac_loopback),
        .o_mac_station_addr(nic_mac_station_addr),
        .o_mac_pause_ctrl(nic_mac_pause_ctrl),
        .o_mac_pause_high_water(nic_mac_pause_high_water),
        .o_mac_pause_low_water(nic_mac_pause_low_water),
        .o_mac_pause_interval(nic_mac_pause_interval),
        .o_mac_rx_fifo_limit(nic_mac_rx_fifo_limit),
        .o_mac_rx_fifo_limit_wr(nic_mac_rx_fifo_limit_wr),
        .i_mac_rx_fifo_limit_busy(nic_mac_rx_fifo_limit_busy),
        .o_mac_rx_desc_starved(nic_mac_rx_desc_starved),
        .i_mac_totals(nic_mac_totals),
        .i_phy_status(i_nic_phy_status),
        .i_phy_diag('0),
        .o_phy_diag_ack(),
        .o_phy_ctrl(o_nic_phy_ctrl)
    );

    if (EXTERNAL_MAC == 0) begin : gen_nic_mac_10g
      nic_mac_10g #(
          .RX_FIFO_DEPTH(NicRxFifoDepth),
          .RAW_LOOPBACK (RAW_LOOPBACK)
      ) nic_mac (
          .i_clk(i_clk),
          .i_rst(nic_mac_rst),
          .i_soft_rst(nic_mac_soft_rst),
          .i_restart(nic_mac_restart),
          .o_ready(nic_mac_ready),
          .o_link(nic_mac_link),
          .o_raw_loopback_en(nic_mac_raw_loopback_en),
          .i_mac_loopback(nic_mac_loopback),
          .i_station_mac(nic_mac_station_addr),
          .i_pause_ctrl(nic_mac_pause_ctrl),
          .i_pause_high_water(nic_mac_pause_high_water),
          .i_pause_low_water(nic_mac_pause_low_water),
          .i_pause_interval(nic_mac_pause_interval),
          .i_rx_fifo_limit(nic_mac_rx_fifo_limit),
          .i_rx_fifo_limit_wr(nic_mac_rx_fifo_limit_wr),
          .o_rx_fifo_limit_busy(nic_mac_rx_fifo_limit_busy),
          .i_rx_desc_starved(nic_mac_rx_desc_starved),
          .o_totals(nic_mac_totals),
          .s_axis_tx_tvalid(nic_mac_tx_tvalid),
          .s_axis_tx_tready(nic_mac_tx_tready),
          .s_axis_tx_tdata(nic_mac_tx_tdata),
          .s_axis_tx_tkeep(nic_mac_tx_tkeep),
          .s_axis_tx_tlast(nic_mac_tx_tlast),
          .s_axis_tx_tuser(nic_mac_tx_tuser),
          .i_tx_csum(nic_mac_tx_csum),
          .m_axis_rx_tvalid(nic_mac_rx_tvalid),
          .m_axis_rx_tready(nic_mac_rx_tready),
          .m_axis_rx_tdata(nic_mac_rx_tdata),
          .m_axis_rx_tkeep(nic_mac_rx_tkeep),
          .m_axis_rx_tlast(nic_mac_rx_tlast),
          .i_tx_clk(i_nic_tx_clk),
          .i_rx_clk(i_nic_rx_clk),
          .i_tx_clk_ok(i_nic_tx_clk_ok),
          .i_rx_clk_ok(i_nic_rx_clk_ok),
          .o_tx_raw_data(o_nic_tx_raw_data),
          .o_tx_raw_valid(o_nic_tx_raw_valid),
          .i_rx_raw_data(i_nic_rx_raw_data),
          .i_rx_raw_valid(i_nic_rx_raw_valid),
          .i_rx_signal_ok(i_nic_rx_signal_ok),
          .o_rx_block_lock(o_nic_rx_block_lock)
      );
      assign o_ext_mac_tx_tvalid = 1'b0;
      assign o_ext_mac_tx_tdata = '0;
      assign o_ext_mac_tx_tkeep = '0;
      assign o_ext_mac_tx_tlast = 1'b0;
      assign o_ext_mac_tx_tuser = 1'b0;
      assign o_ext_mac_tx_csum = '0;
      assign o_ext_mac_rx_tready = 1'b0;
      assign o_ext_mac_rst = 1'b0;
      assign o_ext_mac_soft_rst = 1'b0;
      assign o_ext_mac_restart = 1'b0;
      assign o_ext_mac_loopback = 1'b0;
      assign o_ext_mac_station_addr = '0;
      assign o_ext_mac_pause_ctrl = '0;
      assign o_ext_mac_pause_high_water = '0;
      assign o_ext_mac_pause_low_water = '0;
      assign o_ext_mac_pause_interval = '0;
      assign o_ext_mac_rx_fifo_limit = '0;
      assign o_ext_mac_rx_fifo_limit_wr = 1'b0;
      assign o_ext_mac_rx_desc_starved = 1'b0;
    end else begin : gen_ext_mac
      assign o_ext_mac_tx_tvalid = nic_mac_tx_tvalid;
      assign nic_mac_tx_tready = i_ext_mac_tx_tready;
      assign o_ext_mac_tx_tdata = nic_mac_tx_tdata;
      assign o_ext_mac_tx_tkeep = nic_mac_tx_tkeep;
      assign o_ext_mac_tx_tlast = nic_mac_tx_tlast;
      assign o_ext_mac_tx_tuser = nic_mac_tx_tuser;
      assign o_ext_mac_tx_csum = nic_mac_tx_csum;
      assign nic_mac_rx_tvalid = i_ext_mac_rx_tvalid;
      assign o_ext_mac_rx_tready = nic_mac_rx_tready;
      assign nic_mac_rx_tdata = i_ext_mac_rx_tdata;
      assign nic_mac_rx_tkeep = i_ext_mac_rx_tkeep;
      assign nic_mac_rx_tlast = i_ext_mac_rx_tlast;
      assign o_ext_mac_rst = nic_mac_rst;
      assign o_ext_mac_soft_rst = nic_mac_soft_rst;
      assign o_ext_mac_restart = nic_mac_restart;
      assign nic_mac_ready = i_ext_mac_ready;
      assign nic_mac_link = i_ext_mac_link;
      assign nic_mac_raw_loopback_en = i_ext_mac_raw_loopback_en;
      assign o_ext_mac_loopback = nic_mac_loopback;
      assign o_ext_mac_station_addr = nic_mac_station_addr;
      assign o_ext_mac_pause_ctrl = nic_mac_pause_ctrl;
      assign o_ext_mac_pause_high_water = nic_mac_pause_high_water;
      assign o_ext_mac_pause_low_water = nic_mac_pause_low_water;
      assign o_ext_mac_pause_interval = nic_mac_pause_interval;
      assign o_ext_mac_rx_fifo_limit = nic_mac_rx_fifo_limit;
      assign o_ext_mac_rx_fifo_limit_wr = nic_mac_rx_fifo_limit_wr;
      assign nic_mac_rx_fifo_limit_busy = i_ext_mac_rx_fifo_limit_busy;
      assign o_ext_mac_rx_desc_starved = nic_mac_rx_desc_starved;
      assign nic_mac_totals = i_ext_mac_totals;
      assign o_nic_tx_raw_data = '0;
      assign o_nic_tx_raw_valid = 1'b0;
      assign o_nic_rx_block_lock = i_ext_mac_link[0];
    end

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
        .i_reg_axil_awvalid(reg_axil_awvalid[1]),
        .o_reg_axil_awready(reg_axil_awready[1]),
        .i_reg_axil_awaddr(reg_axil_addr_q[7:0]),
        .i_reg_axil_awprot(reg_axil_prot_q),
        .i_reg_axil_wvalid(reg_axil_wvalid[1]),
        .o_reg_axil_wready(reg_axil_wready[1]),
        .i_reg_axil_wdata(reg_axil_wdata_q),
        .i_reg_axil_wstrb(reg_axil_wstrb_q),
        .o_reg_axil_bvalid(reg_axil_bvalid[1]),
        .i_reg_axil_bready(reg_axil_bready[1]),
        .o_reg_axil_bresp(reg_axil_bresp[1*2+:2]),
        .i_reg_axil_arvalid(reg_axil_arvalid[1]),
        .o_reg_axil_arready(reg_axil_arready[1]),
        .i_reg_axil_araddr(reg_axil_addr_q[7:0]),
        .i_reg_axil_arprot(reg_axil_prot_q),
        .o_reg_axil_rvalid(reg_axil_rvalid[1]),
        .i_reg_axil_rready(reg_axil_rready[1]),
        .o_reg_axil_rdata(reg_axil_rdata[1*64+:64]),
        .o_reg_axil_rresp(reg_axil_rresp[1*2+:2]),
        .o_irq(dma_engine_irq),
        .o_dma_axi_awvalid(up_awvalid[1]),
        .o_dma_axi_awid(up_awid[1*DmaUpIdBits+:DmaUpIdBits]),
        .o_dma_axi_awaddr(up_awaddr[1*DmaAxiAddrBits+:DmaAxiAddrBits]),
        .o_dma_axi_awlen(up_awlen[1*8+:8]),
        .o_dma_axi_awsize(up_awsize[1*3+:3]),
        .o_dma_axi_awburst(up_awburst[1*2+:2]),
        .o_dma_axi_awlock(up_awlock[1]),
        .o_dma_axi_awcache(up_awcache[1*4+:4]),
        .o_dma_axi_awprot(up_awprot[1*3+:3]),
        .o_dma_axi_awqos(up_awqos[1*4+:4]),
        .o_dma_axi_wvalid(up_wvalid[1]),
        .o_dma_axi_wdata(up_wdata[1*DmaAxiDataBits+:DmaAxiDataBits]),
        .o_dma_axi_wstrb(up_wstrb[1*DmaStrbBits+:DmaStrbBits]),
        .o_dma_axi_wlast(up_wlast[1]),
        .o_dma_axi_bready(up_bready[1]),
        .o_dma_axi_arvalid(up_arvalid[1]),
        .o_dma_axi_arid(up_arid[1*DmaUpIdBits+:DmaUpIdBits]),
        .o_dma_axi_araddr(up_araddr[1*DmaAxiAddrBits+:DmaAxiAddrBits]),
        .o_dma_axi_arlen(up_arlen[1*8+:8]),
        .o_dma_axi_arsize(up_arsize[1*3+:3]),
        .o_dma_axi_arburst(up_arburst[1*2+:2]),
        .o_dma_axi_arlock(up_arlock[1]),
        .o_dma_axi_arcache(up_arcache[1*4+:4]),
        .o_dma_axi_arprot(up_arprot[1*3+:3]),
        .o_dma_axi_arqos(up_arqos[1*4+:4]),
        .o_dma_axi_rready(up_rready[1]),
        .i_dma_axi_awready(up_awready[1]),
        .i_dma_axi_wready(up_wready[1]),
        .i_dma_axi_bvalid(up_bvalid[1]),
        .i_dma_axi_bid(up_bid[1*DmaUpIdBits+:DmaUpIdBits]),
        .i_dma_axi_bresp(up_bresp[1*2+:2]),
        .i_dma_axi_arready(up_arready[1]),
        .i_dma_axi_rvalid(up_rvalid[1]),
        .i_dma_axi_rid(up_rid[1*DmaUpIdBits+:DmaUpIdBits]),
        .i_dma_axi_rdata(up_rdata[1*DmaAxiDataBits+:DmaAxiDataBits]),
        .i_dma_axi_rresp(up_rresp[1*2+:2]),
        .i_dma_axi_rlast(up_rlast[1])
    );

    if (ENABLE_1G_ETH != 0) begin : gen_nic_1g
      logic nic_1g_tx_tvalid, nic_1g_tx_tready, nic_1g_tx_tlast, nic_1g_tx_tuser;
      logic [63:0] nic_1g_tx_tdata;
      logic [ 7:0] nic_1g_tx_tkeep;
      logic [14:0] nic_1g_tx_csum;
      logic nic_1g_rx_tvalid, nic_1g_rx_tready, nic_1g_rx_tlast;
      logic [63:0] nic_1g_rx_tdata;
      logic [ 7:0] nic_1g_rx_tkeep;
      logic nic_1g_mac_rst, nic_1g_mac_soft_rst, nic_1g_mac_restart;
      logic [1:0] nic_1g_mac_ready;
      logic [7:0] nic_1g_mac_link;
      logic nic_1g_mac_raw_loopback_en, nic_1g_mac_loopback;
      logic [47:0] nic_1g_mac_station_addr;
      logic [ 1:0] nic_1g_mac_pause_ctrl;
      logic [NicLimitBits-1:0] nic_1g_mac_pause_high_water, nic_1g_mac_pause_low_water;
      logic [15:0] nic_1g_mac_pause_interval;
      logic [NicLimitBits-1:0] nic_1g_mac_rx_fifo_limit;
      logic nic_1g_mac_rx_fifo_limit_wr, nic_1g_mac_rx_fifo_limit_busy;
      logic nic_1g_mac_rx_desc_starved;
      logic [NicMacTotalsBits-1:0] nic_1g_mac_totals;
      logic [7:0] nic_1g_gmii_txd;
      logic nic_1g_gmii_tx_en, nic_1g_gmii_tx_er, nic_1g_gmii_tx_clk_en;
      /* verilator lint_off UNUSEDSIGNAL */
      wire nic_1g_rx_raw_unused = |i_nic_1g_rx_raw_data[63:26];
      /* verilator lint_on UNUSEDSIGNAL */

      nic_engine #(
          .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
          .LINE_BYTES(L1LineBytes),
          .APERTURE_BASE(64'(CACHED_BASE)),
          .APERTURE_BYTES(CACHED_SIZE_BYTES),
          .TICK_DEFAULT(CLK_FREQ_HZ / 1_000_000),
          .RX_FIFO_DEPTH(NicRxFifoDepth),
          .DMA_AXI_ADDR_BITS(DmaAxiAddrBits),
          .DMA_AXI_ID_BITS(DmaUpIdBits),
          .ENABLE_PHY_DIAG(1'b1)
      ) nic_1g (
          .i_clk(i_clk),
          .i_rst(rst_core_next),
          .i_reg_axil_awvalid(reg_axil_awvalid[2]),
          .o_reg_axil_awready(reg_axil_awready[2]),
          .i_reg_axil_awaddr(reg_axil_addr_q[11:0]),
          .i_reg_axil_awprot(reg_axil_prot_q),
          .i_reg_axil_wvalid(reg_axil_wvalid[2]),
          .o_reg_axil_wready(reg_axil_wready[2]),
          .i_reg_axil_wdata(reg_axil_wdata_q),
          .i_reg_axil_wstrb(reg_axil_wstrb_q),
          .o_reg_axil_bvalid(reg_axil_bvalid[2]),
          .i_reg_axil_bready(reg_axil_bready[2]),
          .o_reg_axil_bresp(reg_axil_bresp[2*2+:2]),
          .i_reg_axil_arvalid(reg_axil_arvalid[2]),
          .o_reg_axil_arready(reg_axil_arready[2]),
          .i_reg_axil_araddr(reg_axil_addr_q[11:0]),
          .i_reg_axil_arprot(reg_axil_prot_q),
          .o_reg_axil_rvalid(reg_axil_rvalid[2]),
          .i_reg_axil_rready(reg_axil_rready[2]),
          .o_reg_axil_rdata(reg_axil_rdata[2*64+:64]),
          .o_reg_axil_rresp(reg_axil_rresp[2*2+:2]),
          .o_irq(nic_1g_irq),
          .o_dma_axi_awvalid(up_awvalid[2]),
          .o_dma_axi_awid(up_awid[2*DmaUpIdBits+:DmaUpIdBits]),
          .o_dma_axi_awaddr(up_awaddr[2*DmaAxiAddrBits+:DmaAxiAddrBits]),
          .o_dma_axi_awlen(up_awlen[2*8+:8]),
          .o_dma_axi_awsize(up_awsize[2*3+:3]),
          .o_dma_axi_awburst(up_awburst[2*2+:2]),
          .o_dma_axi_awlock(up_awlock[2]),
          .o_dma_axi_awcache(up_awcache[2*4+:4]),
          .o_dma_axi_awprot(up_awprot[2*3+:3]),
          .o_dma_axi_awqos(up_awqos[2*4+:4]),
          .o_dma_axi_wvalid(up_wvalid[2]),
          .o_dma_axi_wdata(up_wdata[2*DmaAxiDataBits+:DmaAxiDataBits]),
          .o_dma_axi_wstrb(up_wstrb[2*DmaStrbBits+:DmaStrbBits]),
          .o_dma_axi_wlast(up_wlast[2]),
          .o_dma_axi_bready(up_bready[2]),
          .o_dma_axi_arvalid(up_arvalid[2]),
          .o_dma_axi_arid(up_arid[2*DmaUpIdBits+:DmaUpIdBits]),
          .o_dma_axi_araddr(up_araddr[2*DmaAxiAddrBits+:DmaAxiAddrBits]),
          .o_dma_axi_arlen(up_arlen[2*8+:8]),
          .o_dma_axi_arsize(up_arsize[2*3+:3]),
          .o_dma_axi_arburst(up_arburst[2*2+:2]),
          .o_dma_axi_arlock(up_arlock[2]),
          .o_dma_axi_arcache(up_arcache[2*4+:4]),
          .o_dma_axi_arprot(up_arprot[2*3+:3]),
          .o_dma_axi_arqos(up_arqos[2*4+:4]),
          .o_dma_axi_rready(up_rready[2]),
          .i_dma_axi_awready(up_awready[2]),
          .i_dma_axi_wready(up_wready[2]),
          .i_dma_axi_bvalid(up_bvalid[2]),
          .i_dma_axi_bid(up_bid[2*DmaUpIdBits+:DmaUpIdBits]),
          .i_dma_axi_bresp(up_bresp[2*2+:2]),
          .i_dma_axi_arready(up_arready[2]),
          .i_dma_axi_rvalid(up_rvalid[2]),
          .i_dma_axi_rid(up_rid[2*DmaUpIdBits+:DmaUpIdBits]),
          .i_dma_axi_rdata(up_rdata[2*DmaAxiDataBits+:DmaAxiDataBits]),
          .i_dma_axi_rresp(up_rresp[2*2+:2]),
          .i_dma_axi_rlast(up_rlast[2]),
          .o_mac_tx_tvalid(nic_1g_tx_tvalid),
          .i_mac_tx_tready(nic_1g_tx_tready),
          .o_mac_tx_tdata(nic_1g_tx_tdata),
          .o_mac_tx_tkeep(nic_1g_tx_tkeep),
          .o_mac_tx_tlast(nic_1g_tx_tlast),
          .o_mac_tx_tuser(nic_1g_tx_tuser),
          .o_mac_tx_csum(nic_1g_tx_csum),
          .i_mac_rx_tvalid(nic_1g_rx_tvalid),
          .o_mac_rx_tready(nic_1g_rx_tready),
          .i_mac_rx_tdata(nic_1g_rx_tdata),
          .i_mac_rx_tkeep(nic_1g_rx_tkeep),
          .i_mac_rx_tlast(nic_1g_rx_tlast),
          .o_mac_rst(nic_1g_mac_rst),
          .o_mac_soft_rst(nic_1g_mac_soft_rst),
          .o_mac_restart(nic_1g_mac_restart),
          .i_mac_ready(nic_1g_mac_ready),
          .i_mac_link(nic_1g_mac_link),
          .i_mac_raw_loopback_en(nic_1g_mac_raw_loopback_en),
          .o_mac_loopback(nic_1g_mac_loopback),
          .o_mac_station_addr(nic_1g_mac_station_addr),
          .o_mac_pause_ctrl(nic_1g_mac_pause_ctrl),
          .o_mac_pause_high_water(nic_1g_mac_pause_high_water),
          .o_mac_pause_low_water(nic_1g_mac_pause_low_water),
          .o_mac_pause_interval(nic_1g_mac_pause_interval),
          .o_mac_rx_fifo_limit(nic_1g_mac_rx_fifo_limit),
          .o_mac_rx_fifo_limit_wr(nic_1g_mac_rx_fifo_limit_wr),
          .i_mac_rx_fifo_limit_busy(nic_1g_mac_rx_fifo_limit_busy),
          .o_mac_rx_desc_starved(nic_1g_mac_rx_desc_starved),
          .i_mac_totals(nic_1g_mac_totals),
          .i_phy_status(i_nic_1g_phy_status),
          .i_phy_diag(i_nic_1g_phy_diag),
          .o_phy_diag_ack(o_nic_1g_phy_diag_ack),
          .o_phy_ctrl(o_nic_1g_phy_ctrl)
      );

      nic_mac_1g #(
          .RX_FIFO_DEPTH(NicRxFifoDepth),
          .RAW_LOOPBACK (1)
      ) nic_1g_mac (
          .i_clk(i_clk),
          .i_rst(nic_1g_mac_rst),
          .i_soft_rst(nic_1g_mac_soft_rst),
          .i_restart(nic_1g_mac_restart),
          .o_ready(nic_1g_mac_ready),
          .o_link(nic_1g_mac_link),
          .o_raw_loopback_en(nic_1g_mac_raw_loopback_en),
          .i_mac_loopback(nic_1g_mac_loopback),
          .i_station_mac(nic_1g_mac_station_addr),
          .i_pause_ctrl(nic_1g_mac_pause_ctrl),
          .i_pause_high_water(nic_1g_mac_pause_high_water),
          .i_pause_low_water(nic_1g_mac_pause_low_water),
          .i_pause_interval(nic_1g_mac_pause_interval),
          .i_rx_fifo_limit(nic_1g_mac_rx_fifo_limit),
          .i_rx_fifo_limit_wr(nic_1g_mac_rx_fifo_limit_wr),
          .o_rx_fifo_limit_busy(nic_1g_mac_rx_fifo_limit_busy),
          .i_rx_desc_starved(nic_1g_mac_rx_desc_starved),
          .o_totals(nic_1g_mac_totals),
          .s_axis_tx_tvalid(nic_1g_tx_tvalid),
          .s_axis_tx_tready(nic_1g_tx_tready),
          .s_axis_tx_tdata(nic_1g_tx_tdata),
          .s_axis_tx_tkeep(nic_1g_tx_tkeep),
          .s_axis_tx_tlast(nic_1g_tx_tlast),
          .s_axis_tx_tuser(nic_1g_tx_tuser),
          .i_tx_csum(nic_1g_tx_csum),
          .m_axis_rx_tvalid(nic_1g_rx_tvalid),
          .m_axis_rx_tready(nic_1g_rx_tready),
          .m_axis_rx_tdata(nic_1g_rx_tdata),
          .m_axis_rx_tkeep(nic_1g_rx_tkeep),
          .m_axis_rx_tlast(nic_1g_rx_tlast),
          .i_tx_clk(i_nic_1g_tx_clk),
          .i_rx_clk(i_nic_1g_rx_clk),
          .i_tx_clk_ok(i_nic_1g_tx_clk_ok),
          .i_rx_clk_ok(i_nic_1g_rx_clk_ok),
          .o_gmii_txd(nic_1g_gmii_txd),
          .o_gmii_tx_en(nic_1g_gmii_tx_en),
          .o_gmii_tx_er(nic_1g_gmii_tx_er),
          .o_gmii_tx_clk_en(nic_1g_gmii_tx_clk_en),
          .i_gmii_rxd(i_nic_1g_rx_raw_data[7:0]),
          .i_gmii_rx_dv(i_nic_1g_rx_raw_data[8]),
          .i_gmii_rx_er(i_nic_1g_rx_raw_data[9]),
          .i_gmii_rx_clk_en(i_nic_1g_rx_raw_valid),
          .i_pcs_status(i_nic_1g_rx_raw_data[25:10]),
          .i_rx_signal_ok(i_nic_1g_rx_signal_ok),
          .o_rx_block_lock(o_nic_1g_rx_block_lock)
      );
      assign o_nic_1g_tx_raw_data  = {54'b0, nic_1g_gmii_tx_er, nic_1g_gmii_tx_en, nic_1g_gmii_txd};
      assign o_nic_1g_tx_raw_valid = nic_1g_gmii_tx_clk_en;
    end else begin : gen_no_nic_1g
      assign nic_1g_irq = 1'b0;
      assign o_nic_1g_tx_raw_data = '0;
      assign o_nic_1g_tx_raw_valid = 1'b0;
      assign o_nic_1g_phy_diag_ack = 1'b0;
      assign o_nic_1g_phy_ctrl = '0;
      assign o_nic_1g_rx_block_lock = 1'b0;
    end

    // Svpbmt NC and IO accesses to DDR (the local bus's state 6). The hart
    // sends them to the uncached alias (riscv_pkg "Svpbmt"); this master
    // turns each into one single-beat AXI transfer of its size at the real
    // DDR address, into the coherent DMA port beside the NIC. The home
    // orders it with every cached copy: a read collects dirty L1D data, a
    // write invalidates the L1D copies and merges its bytes, and the B or R
    // comes back only after that. AxCACHE 0000 (Device Non-bufferable) asks
    // for streaming placement (way 0) in the L2; the hart's L0 and L1D never
    // hold the bytes through the alias. The local bus has one access in
    // flight, so the master has one transfer and needs one ID. rst_core
    // resets the DMA interconnect; a registered abort ends the local wait
    // with OKAY and zero data.
    localparam int unsigned AliasLaneLsb = 3;
    localparam int unsigned AliasLaneMsb = $clog2(DmaAxiDataBits / 8) - 1;
    logic alias_aw_q, alias_w_q, alias_ar_q;
    wire alias_start = local_fire && local_alias && local_ok;
    wire [riscv_pkg::XLEN-1:0] alias_real_addr = riscv_pkg::pbmt_alias_real(
        riscv_pkg::XLEN'(local_addr)
    );
    wire alias_wait = local_state_q == 6;
    logic alias_aborted_q;
    always_ff @(posedge i_clk) begin
      if (soc_axi_rst) alias_aborted_q <= 1'b0;
      else if (rst_core) alias_aborted_q <= 1'b1;
      else if (!alias_wait) alias_aborted_q <= 1'b0;
    end
    always_ff @(posedge i_clk) begin
      if (rst_core) begin
        alias_aw_q <= 1'b0;
        alias_w_q  <= 1'b0;
        alias_ar_q <= 1'b0;
      end else if (alias_start) begin
        alias_aw_q <= local_write;
        alias_w_q  <= local_write;
        alias_ar_q <= !local_write;
      end else begin
        if (up_awready[AliasPort]) alias_aw_q <= 1'b0;
        if (up_wready[AliasPort]) alias_w_q <= 1'b0;
        if (up_arready[AliasPort]) alias_ar_q <= 1'b0;
      end
    end
    assign up_awvalid[AliasPort] = alias_aw_q;
    assign up_awid[AliasPort*DmaUpIdBits+:DmaUpIdBits] = '0;
    assign up_awaddr[AliasPort*DmaAxiAddrBits+:DmaAxiAddrBits] = DmaAxiAddrBits'(alias_real_addr);
    assign up_awlen[AliasPort*8+:8] = 8'd0;
    assign up_awsize[AliasPort*3+:3] = local_size;
    assign up_awburst[AliasPort*2+:2] = 2'b01;
    assign up_awlock[AliasPort] = 1'b0;
    assign up_awcache[AliasPort*4+:4] = 4'b0000;
    assign up_awprot[AliasPort*3+:3] = local_prot;
    assign up_awqos[AliasPort*4+:4] = 4'd0;
    assign up_wvalid[AliasPort] = alias_w_q;
    assign up_wdata[AliasPort*DmaAxiDataBits+:DmaAxiDataBits] =
        {(DmaAxiDataBits / 64) {local_wdata}};
    assign up_wstrb[AliasPort*DmaStrbBits+:DmaStrbBits] = (DmaAxiDataBits / 8)'(local_wstrb) <<
        {local_addr[AliasLaneMsb:AliasLaneLsb], 3'b000};
    assign up_wlast[AliasPort] = 1'b1;
    assign up_bready[AliasPort] = alias_wait && local_write && !alias_aw_q && !alias_w_q;
    assign up_arvalid[AliasPort] = alias_ar_q;
    assign up_arid[AliasPort*DmaUpIdBits+:DmaUpIdBits] = '0;
    assign up_araddr[AliasPort*DmaAxiAddrBits+:DmaAxiAddrBits] = DmaAxiAddrBits'(alias_real_addr);
    assign up_arlen[AliasPort*8+:8] = 8'd0;
    assign up_arsize[AliasPort*3+:3] = local_size;
    assign up_arburst[AliasPort*2+:2] = 2'b01;
    assign up_arlock[AliasPort] = 1'b0;
    assign up_arcache[AliasPort*4+:4] = 4'b0000;
    assign up_arprot[AliasPort*3+:3] = local_prot;
    assign up_arqos[AliasPort*4+:4] = 4'd0;
    assign up_rready[AliasPort] = alias_wait && !local_write && !alias_ar_q;
    wire alias_b_fire = up_bvalid[AliasPort] && up_bready[AliasPort];
    wire alias_r_fire = up_rvalid[AliasPort] && up_rready[AliasPort];
    assign alias_done = alias_wait && (alias_aborted_q || alias_b_fire || alias_r_fire);
    assign alias_status = alias_aborted_q ? 2'b00 : alias_b_fire ? up_bresp[AliasPort*2+:2] :
        up_rresp[AliasPort*2+:2];
    assign alias_rdata = alias_aborted_q ? 64'd0 :
        64'(up_rdata[AliasPort*DmaAxiDataBits+:DmaAxiDataBits] >>
            {local_addr[AliasLaneMsb:AliasLaneLsb], 6'b000000});

    if (EXT_DMA_PORTS > 0) begin : gen_ext_dma
      for (genvar p = 0; p < EXT_DMA_PORTS; p++) begin : gen_port
        localparam int unsigned PortIdx = BaseDmaPorts + p;
        logic [EXT_DMA_ID_BITS-1:0] slice_awid, slice_bid, slice_arid, slice_rid;
        axi_register_slice #(
            .ADDR_WIDTH(DmaAxiAddrBits),
            .DATA_WIDTH(DmaAxiDataBits),
            .ID_WIDTH  (EXT_DMA_ID_BITS)
        ) u_slice (
            .i_clk(i_clk),
            .i_rst(rst_core),
            .i_s_awvalid(i_ext_dma_awvalid[p]),
            .o_s_awready(o_ext_dma_awready[p]),
            .i_s_awid(i_ext_dma_awid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_s_awaddr(i_ext_dma_awaddr[p*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .i_s_awlen(i_ext_dma_awlen[p*8+:8]),
            .i_s_awsize(i_ext_dma_awsize[p*3+:3]),
            .i_s_awburst(i_ext_dma_awburst[p*2+:2]),
            .i_s_awlock(i_ext_dma_awlock[p]),
            .i_s_awcache(i_ext_dma_awcache[p*4+:4]),
            .i_s_awprot(i_ext_dma_awprot[p*3+:3]),
            .i_s_awqos(i_ext_dma_awqos[p*4+:4]),
            .i_s_wvalid(i_ext_dma_wvalid[p]),
            .o_s_wready(o_ext_dma_wready[p]),
            .i_s_wdata(i_ext_dma_wdata[p*DmaAxiDataBits+:DmaAxiDataBits]),
            .i_s_wstrb(i_ext_dma_wstrb[p*DmaStrbBits+:DmaStrbBits]),
            .i_s_wlast(i_ext_dma_wlast[p]),
            .o_s_bvalid(o_ext_dma_bvalid[p]),
            .i_s_bready(i_ext_dma_bready[p]),
            .o_s_bid(o_ext_dma_bid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .o_s_bresp(o_ext_dma_bresp[p*2+:2]),
            .i_s_arvalid(i_ext_dma_arvalid[p]),
            .o_s_arready(o_ext_dma_arready[p]),
            .i_s_arid(i_ext_dma_arid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_s_araddr(i_ext_dma_araddr[p*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .i_s_arlen(i_ext_dma_arlen[p*8+:8]),
            .i_s_arsize(i_ext_dma_arsize[p*3+:3]),
            .i_s_arburst(i_ext_dma_arburst[p*2+:2]),
            .i_s_arlock(i_ext_dma_arlock[p]),
            .i_s_arcache(i_ext_dma_arcache[p*4+:4]),
            .i_s_arprot(i_ext_dma_arprot[p*3+:3]),
            .i_s_arqos(i_ext_dma_arqos[p*4+:4]),
            .o_s_rvalid(o_ext_dma_rvalid[p]),
            .i_s_rready(i_ext_dma_rready[p]),
            .o_s_rid(o_ext_dma_rid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .o_s_rdata(o_ext_dma_rdata[p*DmaAxiDataBits+:DmaAxiDataBits]),
            .o_s_rresp(o_ext_dma_rresp[p*2+:2]),
            .o_s_rlast(o_ext_dma_rlast[p]),
            .o_m_awvalid(up_awvalid[PortIdx]),
            .i_m_awready(up_awready[PortIdx]),
            .o_m_awid(slice_awid),
            .o_m_awaddr(up_awaddr[PortIdx*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .o_m_awlen(up_awlen[PortIdx*8+:8]),
            .o_m_awsize(up_awsize[PortIdx*3+:3]),
            .o_m_awburst(up_awburst[PortIdx*2+:2]),
            .o_m_awlock(up_awlock[PortIdx]),
            .o_m_awcache(up_awcache[PortIdx*4+:4]),
            .o_m_awprot(up_awprot[PortIdx*3+:3]),
            .o_m_awqos(up_awqos[PortIdx*4+:4]),
            .o_m_wvalid(up_wvalid[PortIdx]),
            .i_m_wready(up_wready[PortIdx]),
            .o_m_wdata(up_wdata[PortIdx*DmaAxiDataBits+:DmaAxiDataBits]),
            .o_m_wstrb(up_wstrb[PortIdx*DmaStrbBits+:DmaStrbBits]),
            .o_m_wlast(up_wlast[PortIdx]),
            .i_m_bvalid(up_bvalid[PortIdx]),
            .o_m_bready(up_bready[PortIdx]),
            .i_m_bid(slice_bid),
            .i_m_bresp(up_bresp[PortIdx*2+:2]),
            .o_m_arvalid(up_arvalid[PortIdx]),
            .i_m_arready(up_arready[PortIdx]),
            .o_m_arid(slice_arid),
            .o_m_araddr(up_araddr[PortIdx*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .o_m_arlen(up_arlen[PortIdx*8+:8]),
            .o_m_arsize(up_arsize[PortIdx*3+:3]),
            .o_m_arburst(up_arburst[PortIdx*2+:2]),
            .o_m_arlock(up_arlock[PortIdx]),
            .o_m_arcache(up_arcache[PortIdx*4+:4]),
            .o_m_arprot(up_arprot[PortIdx*3+:3]),
            .o_m_arqos(up_arqos[PortIdx*4+:4]),
            .i_m_rvalid(up_rvalid[PortIdx]),
            .o_m_rready(up_rready[PortIdx]),
            .i_m_rid(slice_rid),
            .i_m_rdata(up_rdata[PortIdx*DmaAxiDataBits+:DmaAxiDataBits]),
            .i_m_rresp(up_rresp[PortIdx*2+:2]),
            .i_m_rlast(up_rlast[PortIdx])
        );
        assign up_awid[PortIdx*DmaUpIdBits+:DmaUpIdBits] = DmaUpIdBits'(slice_awid);
        assign up_arid[PortIdx*DmaUpIdBits+:DmaUpIdBits] = DmaUpIdBits'(slice_arid);
        assign slice_bid = up_bid[PortIdx*DmaUpIdBits+:EXT_DMA_ID_BITS];
        assign slice_rid = up_rid[PortIdx*DmaUpIdBits+:EXT_DMA_ID_BITS];
`ifndef SYNTHESIS
        axi_checker #(
            .ADDR_WIDTH(DmaAxiAddrBits),
            .DATA_WIDTH(DmaAxiDataBits),
            .ID_WIDTH(EXT_DMA_ID_BITS),
            .PORT(DmaPorts + 1 + p)
        ) u_ext_check (
            .i_clk(i_clk),
            .i_rst(rst_core),
            .i_awvalid(i_ext_dma_awvalid[p]),
            .i_awready(o_ext_dma_awready[p]),
            .i_awid(i_ext_dma_awid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_awaddr(i_ext_dma_awaddr[p*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .i_awlen(i_ext_dma_awlen[p*8+:8]),
            .i_awsize(i_ext_dma_awsize[p*3+:3]),
            .i_awburst(i_ext_dma_awburst[p*2+:2]),
            .i_awlock(i_ext_dma_awlock[p]),
            .i_wvalid(i_ext_dma_wvalid[p]),
            .i_wready(o_ext_dma_wready[p]),
            .i_wdata(i_ext_dma_wdata[p*DmaAxiDataBits+:DmaAxiDataBits]),
            .i_wstrb(i_ext_dma_wstrb[p*DmaStrbBits+:DmaStrbBits]),
            .i_wlast(i_ext_dma_wlast[p]),
            .i_bvalid(o_ext_dma_bvalid[p]),
            .i_bready(i_ext_dma_bready[p]),
            .i_bid(o_ext_dma_bid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_bresp(o_ext_dma_bresp[p*2+:2]),
            .i_arvalid(i_ext_dma_arvalid[p]),
            .i_arready(o_ext_dma_arready[p]),
            .i_arid(i_ext_dma_arid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_araddr(i_ext_dma_araddr[p*DmaAxiAddrBits+:DmaAxiAddrBits]),
            .i_arlen(i_ext_dma_arlen[p*8+:8]),
            .i_arsize(i_ext_dma_arsize[p*3+:3]),
            .i_arburst(i_ext_dma_arburst[p*2+:2]),
            .i_arlock(i_ext_dma_arlock[p]),
            .i_rvalid(o_ext_dma_rvalid[p]),
            .i_rready(i_ext_dma_rready[p]),
            .i_rid(o_ext_dma_rid[p*EXT_DMA_ID_BITS+:EXT_DMA_ID_BITS]),
            .i_rdata(o_ext_dma_rdata[p*DmaAxiDataBits+:DmaAxiDataBits]),
            .i_rresp(o_ext_dma_rresp[p*2+:2]),
            .i_rlast(o_ext_dma_rlast[p])
        );
`endif
      end
    end else begin : gen_no_ext_dma
      assign o_ext_dma_awready = '0;
      assign o_ext_dma_wready  = '0;
      assign o_ext_dma_bvalid  = '0;
      assign o_ext_dma_bid     = '0;
      assign o_ext_dma_bresp   = '0;
      assign o_ext_dma_arready = '0;
      assign o_ext_dma_rvalid  = '0;
      assign o_ext_dma_rid     = '0;
      assign o_ext_dma_rdata   = '0;
      assign o_ext_dma_rresp   = '0;
      assign o_ext_dma_rlast   = '0;
    end

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

    logic cdc_dn_awvalid;
    logic cdc_dn_awready;
    logic [DmaDownIdBits-1:0] cdc_dn_awid;
    logic [DmaAxiAddrBits-1:0] cdc_dn_awaddr;
    logic [8-1:0] cdc_dn_awlen;
    logic [3-1:0] cdc_dn_awsize;
    logic [2-1:0] cdc_dn_awburst;
    logic cdc_dn_awlock;
    logic [4-1:0] cdc_dn_awcache;
    logic [3-1:0] cdc_dn_awprot;
    logic [4-1:0] cdc_dn_awqos;
    logic [4-1:0] cdc_dn_awregion;
    logic cdc_dn_awuser;
    logic cdc_dn_wvalid;
    logic cdc_dn_wready;
    logic [DmaAxiDataBits-1:0] cdc_dn_wdata;
    logic [DmaAxiDataBits/8-1:0] cdc_dn_wstrb;
    logic cdc_dn_wlast;
    logic cdc_dn_wuser;
    logic cdc_dn_bvalid;
    logic cdc_dn_bready;
    logic [DmaDownIdBits-1:0] cdc_dn_bid;
    logic [2-1:0] cdc_dn_bresp;
    logic cdc_dn_buser;
    logic cdc_dn_arvalid;
    logic cdc_dn_arready;
    logic [DmaDownIdBits-1:0] cdc_dn_arid;
    logic [DmaAxiAddrBits-1:0] cdc_dn_araddr;
    logic [8-1:0] cdc_dn_arlen;
    logic [3-1:0] cdc_dn_arsize;
    logic [2-1:0] cdc_dn_arburst;
    logic cdc_dn_arlock;
    logic [4-1:0] cdc_dn_arcache;
    logic [3-1:0] cdc_dn_arprot;
    logic [4-1:0] cdc_dn_arqos;
    logic [4-1:0] cdc_dn_arregion;
    logic cdc_dn_aruser;
    logic cdc_dn_rvalid;
    logic cdc_dn_rready;
    logic [DmaDownIdBits-1:0] cdc_dn_rid;
    logic [DmaAxiDataBits-1:0] cdc_dn_rdata;
    logic [2-1:0] cdc_dn_rresp;
    logic cdc_dn_rlast;
    logic cdc_dn_ruser;
    if (ASYNC_CPU_CLOCK) begin : gen_dma_cdc
      axi_cdc #(
          .ADDR_WIDTH(DmaAxiAddrBits),
          .DATA_WIDTH(DmaAxiDataBits),
          .ID_WIDTH  (DmaDownIdBits),
          .USER_WIDTH(1)
      ) dma_cdc (
          .i_src_clk(i_clk),
          .i_src_rst(rst_core),
          .i_dst_clk(core_clk),
          .i_dst_rst(o_cpu_rst),
          .i_src_awvalid(dn_awvalid),
          .o_dst_awvalid(cdc_dn_awvalid),
          .o_src_awready(dn_awready),
          .i_dst_awready(cdc_dn_awready),
          .i_src_awid(dn_awid),
          .o_dst_awid(cdc_dn_awid),
          .i_src_awaddr(dn_awaddr),
          .o_dst_awaddr(cdc_dn_awaddr),
          .i_src_awlen(dn_awlen),
          .o_dst_awlen(cdc_dn_awlen),
          .i_src_awsize(dn_awsize),
          .o_dst_awsize(cdc_dn_awsize),
          .i_src_awburst(dn_awburst),
          .o_dst_awburst(cdc_dn_awburst),
          .i_src_awlock(dn_awlock),
          .o_dst_awlock(cdc_dn_awlock),
          .i_src_awcache(dn_awcache),
          .o_dst_awcache(cdc_dn_awcache),
          .i_src_awprot(dn_awprot),
          .o_dst_awprot(cdc_dn_awprot),
          .i_src_awqos(dn_awqos),
          .o_dst_awqos(cdc_dn_awqos),
          .i_src_awregion('0),
          .o_dst_awregion(cdc_dn_awregion),
          .i_src_awuser('0),
          .o_dst_awuser(cdc_dn_awuser),
          .i_src_wvalid(dn_wvalid),
          .o_dst_wvalid(cdc_dn_wvalid),
          .o_src_wready(dn_wready),
          .i_dst_wready(cdc_dn_wready),
          .i_src_wdata(dn_wdata),
          .o_dst_wdata(cdc_dn_wdata),
          .i_src_wstrb(dn_wstrb),
          .o_dst_wstrb(cdc_dn_wstrb),
          .i_src_wlast(dn_wlast),
          .o_dst_wlast(cdc_dn_wlast),
          .i_src_wuser('0),
          .o_dst_wuser(cdc_dn_wuser),
          .o_src_bvalid(dn_bvalid),
          .i_dst_bvalid(cdc_dn_bvalid),
          .i_src_bready(dn_bready),
          .o_dst_bready(cdc_dn_bready),
          .o_src_bid(dn_bid),
          .i_dst_bid(cdc_dn_bid),
          .o_src_bresp(dn_bresp),
          .i_dst_bresp(cdc_dn_bresp),
          .o_src_buser(),
          .i_dst_buser(cdc_dn_buser),
          .i_src_arvalid(dn_arvalid),
          .o_dst_arvalid(cdc_dn_arvalid),
          .o_src_arready(dn_arready),
          .i_dst_arready(cdc_dn_arready),
          .i_src_arid(dn_arid),
          .o_dst_arid(cdc_dn_arid),
          .i_src_araddr(dn_araddr),
          .o_dst_araddr(cdc_dn_araddr),
          .i_src_arlen(dn_arlen),
          .o_dst_arlen(cdc_dn_arlen),
          .i_src_arsize(dn_arsize),
          .o_dst_arsize(cdc_dn_arsize),
          .i_src_arburst(dn_arburst),
          .o_dst_arburst(cdc_dn_arburst),
          .i_src_arlock(dn_arlock),
          .o_dst_arlock(cdc_dn_arlock),
          .i_src_arcache(dn_arcache),
          .o_dst_arcache(cdc_dn_arcache),
          .i_src_arprot(dn_arprot),
          .o_dst_arprot(cdc_dn_arprot),
          .i_src_arqos(dn_arqos),
          .o_dst_arqos(cdc_dn_arqos),
          .i_src_arregion('0),
          .o_dst_arregion(cdc_dn_arregion),
          .i_src_aruser('0),
          .o_dst_aruser(cdc_dn_aruser),
          .o_src_rvalid(dn_rvalid),
          .i_dst_rvalid(cdc_dn_rvalid),
          .i_src_rready(dn_rready),
          .o_dst_rready(cdc_dn_rready),
          .o_src_rid(dn_rid),
          .i_dst_rid(cdc_dn_rid),
          .o_src_rdata(dn_rdata),
          .i_dst_rdata(cdc_dn_rdata),
          .o_src_rresp(dn_rresp),
          .i_dst_rresp(cdc_dn_rresp),
          .o_src_rlast(dn_rlast),
          .i_dst_rlast(cdc_dn_rlast),
          .o_src_ruser(),
          .i_dst_ruser(cdc_dn_ruser)
      );
    end else begin : gen_dma_cdc_bypass
      assign cdc_dn_awvalid = dn_awvalid;
      assign dn_awready = cdc_dn_awready;
      assign cdc_dn_awid = dn_awid;
      assign cdc_dn_awaddr = dn_awaddr;
      assign cdc_dn_awlen = dn_awlen;
      assign cdc_dn_awsize = dn_awsize;
      assign cdc_dn_awburst = dn_awburst;
      assign cdc_dn_awlock = dn_awlock;
      assign cdc_dn_awcache = dn_awcache;
      assign cdc_dn_awprot = dn_awprot;
      assign cdc_dn_awqos = dn_awqos;
      assign cdc_dn_awregion = '0;
      assign cdc_dn_awuser = '0;
      assign cdc_dn_wvalid = dn_wvalid;
      assign dn_wready = cdc_dn_wready;
      assign cdc_dn_wdata = dn_wdata;
      assign cdc_dn_wstrb = dn_wstrb;
      assign cdc_dn_wlast = dn_wlast;
      assign cdc_dn_wuser = '0;
      assign dn_bvalid = cdc_dn_bvalid;
      assign cdc_dn_bready = dn_bready;
      assign dn_bid = cdc_dn_bid;
      assign dn_bresp = cdc_dn_bresp;
      assign cdc_dn_arvalid = dn_arvalid;
      assign dn_arready = cdc_dn_arready;
      assign cdc_dn_arid = dn_arid;
      assign cdc_dn_araddr = dn_araddr;
      assign cdc_dn_arlen = dn_arlen;
      assign cdc_dn_arsize = dn_arsize;
      assign cdc_dn_arburst = dn_arburst;
      assign cdc_dn_arlock = dn_arlock;
      assign cdc_dn_arcache = dn_arcache;
      assign cdc_dn_arprot = dn_arprot;
      assign cdc_dn_arqos = dn_arqos;
      assign cdc_dn_arregion = '0;
      assign cdc_dn_aruser = '0;
      assign dn_rvalid = cdc_dn_rvalid;
      assign cdc_dn_rready = dn_rready;
      assign dn_rid = cdc_dn_rid;
      assign dn_rdata = cdc_dn_rdata;
      assign dn_rresp = cdc_dn_rresp;
      assign dn_rlast = cdc_dn_rlast;
    end
    logic [DmaLineIdBits-1:0] dma_line_req_id;
    axi_coherent_bridge #(
        .ADDR_WIDTH(DmaAxiAddrBits),
        .DATA_WIDTH(DmaAxiDataBits),
        .ID_WIDTH(DmaDownIdBits),
        .LINE_ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_ID_BITS(DmaLineIdBits),
        .WRITE_BURSTS(8),
        .READ_BURSTS(8),
        .REGION_BASE(64'(CACHED_BASE)),
        .REGION_BYTES(CACHED_SIZE_BYTES)
    ) dma_bridge (
        .i_clk(core_clk),
        .i_rst(ASYNC_CPU_CLOCK ? o_cpu_rst : rst_core),
        .i_axi_awvalid(cdc_dn_awvalid),
        .i_axi_awid(cdc_dn_awid),
        .i_axi_awaddr(cdc_dn_awaddr),
        .i_axi_awlen(cdc_dn_awlen),
        .i_axi_awsize(cdc_dn_awsize),
        .i_axi_awburst(cdc_dn_awburst),
        .i_axi_awlock(cdc_dn_awlock),
        .i_axi_awcache(cdc_dn_awcache),
        .i_axi_awprot(cdc_dn_awprot),
        .i_axi_awqos(cdc_dn_awqos),
        .i_axi_wvalid(cdc_dn_wvalid),
        .i_axi_wdata(cdc_dn_wdata),
        .i_axi_wstrb(cdc_dn_wstrb),
        .i_axi_wlast(cdc_dn_wlast),
        .i_axi_bready(cdc_dn_bready),
        .i_axi_arvalid(cdc_dn_arvalid),
        .i_axi_arid(cdc_dn_arid),
        .i_axi_araddr(cdc_dn_araddr),
        .i_axi_arlen(cdc_dn_arlen),
        .i_axi_arsize(cdc_dn_arsize),
        .i_axi_arburst(cdc_dn_arburst),
        .i_axi_arlock(cdc_dn_arlock),
        .i_axi_arcache(cdc_dn_arcache),
        .i_axi_arprot(cdc_dn_arprot),
        .i_axi_arqos(cdc_dn_arqos),
        .i_axi_rready(cdc_dn_rready),
        .o_axi_awready(cdc_dn_awready),
        .o_axi_wready(cdc_dn_wready),
        .o_axi_bvalid(cdc_dn_bvalid),
        .o_axi_bid(cdc_dn_bid),
        .o_axi_bresp(cdc_dn_bresp),
        .o_axi_arready(cdc_dn_arready),
        .o_axi_rvalid(cdc_dn_rvalid),
        .o_axi_rid(cdc_dn_rid),
        .o_axi_rdata(cdc_dn_rdata),
        .o_axi_rresp(cdc_dn_rresp),
        .o_axi_rlast(cdc_dn_rlast),
        .o_line_req_valid(o_coherent_req_valid),
        .i_line_req_ready(i_coherent_req_ready),
        .o_line_req_write(o_coherent_req_write),
        .o_line_req_addr(o_coherent_req_addr),
        .o_line_req_wdata(o_coherent_req_wdata),
        .o_line_req_wstrb(o_coherent_req_wstrb),
        .o_line_req_id(dma_line_req_id),
        .o_line_req_non_alloc(o_coherent_req_non_alloc),
        .i_line_resp_valid(i_coherent_resp_valid),
        .i_line_resp_id(i_coherent_resp_id[DmaLineIdBits-1:0]),
        .i_line_resp_rdata(i_coherent_resp_rdata),
        .i_line_resp_error(i_coherent_resp_error)
    );
    assign o_coherent_req_id = LineIdBits'(dma_line_req_id);
    if (LineIdBits > DmaLineIdBits) begin : gen_resp_id_high
      /* verilator lint_off UNUSEDSIGNAL */  // the bridge's ids fill the low bits
      logic dma_resp_id_high_unused;
      /* verilator lint_on UNUSEDSIGNAL */
      assign dma_resp_id_high_unused = |i_coherent_resp_id[LineIdBits-1:DmaLineIdBits];
    end

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
          .i_awid(up_awid[g*DmaUpIdBits+:DmaUpIdBits]),
          .i_awaddr(up_awaddr[g*DmaAxiAddrBits+:DmaAxiAddrBits]),
          .i_awlen(up_awlen[g*8+:8]),
          .i_awsize(up_awsize[g*3+:3]),
          .i_awburst(up_awburst[g*2+:2]),
          .i_awlock(up_awlock[g]),
          .i_wvalid(up_wvalid[g]),
          .i_wready(up_wready[g]),
          .i_wdata(up_wdata[g*DmaAxiDataBits+:DmaAxiDataBits]),
          .i_wstrb(up_wstrb[g*DmaStrbBits+:DmaStrbBits]),
          .i_wlast(up_wlast[g]),
          .i_bvalid(up_bvalid[g]),
          .i_bready(up_bready[g]),
          .i_bid(up_bid[g*DmaUpIdBits+:DmaUpIdBits]),
          .i_bresp(up_bresp[g*2+:2]),
          .i_arvalid(up_arvalid[g]),
          .i_arready(up_arready[g]),
          .i_arid(up_arid[g*DmaUpIdBits+:DmaUpIdBits]),
          .i_araddr(up_araddr[g*DmaAxiAddrBits+:DmaAxiAddrBits]),
          .i_arlen(up_arlen[g*8+:8]),
          .i_arsize(up_arsize[g*3+:3]),
          .i_arburst(up_arburst[g*2+:2]),
          .i_arlock(up_arlock[g]),
          .i_rvalid(up_rvalid[g]),
          .i_rready(up_rready[g]),
          .i_rid(up_rid[g*DmaUpIdBits+:DmaUpIdBits]),
          .i_rdata(up_rdata[g*DmaAxiDataBits+:DmaAxiDataBits]),
          .i_rresp(up_rresp[g*2+:2]),
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
  end else begin : gen_no_dma
    // No DMA port: local_alias is never set, so state 6 is never entered.
    assign alias_done   = 1'b0;
    assign alias_status = 2'b11;
    assign alias_rdata  = '0;
    for (genvar a = 0; a < BaseAxilPorts; a++) begin : gen_no_dma_axil
      assign reg_axil_awready[a] = 1'b0;
      assign reg_axil_wready[a] = 1'b0;
      assign reg_axil_bvalid[a] = 1'b0;
      assign reg_axil_bresp[a*2+:2] = 2'b00;
      assign reg_axil_arready[a] = 1'b0;
      assign reg_axil_rvalid[a] = 1'b0;
      assign reg_axil_rresp[a*2+:2] = 2'b00;
      assign reg_axil_rdata[a*64+:64] = 64'b0;
    end
    assign o_coherent_req_valid = 1'b0;
    assign o_coherent_req_write = 1'b0;
    assign o_coherent_req_addr = '0;
    assign o_coherent_req_wdata = '0;
    assign o_coherent_req_wstrb = '0;
    assign o_coherent_req_id = '0;
    assign o_coherent_req_non_alloc = 1'b0;
    assign dma_engine_irq = 1'b0;
    assign nic_irq = 1'b0;
    assign nic_1g_irq = 1'b0;
    assign o_nic_tx_raw_data = '0;
    assign o_nic_tx_raw_valid = 1'b0;
    assign o_nic_phy_ctrl = '0;
    assign o_nic_rx_block_lock = 1'b0;
    assign o_nic_1g_tx_raw_data = '0;
    assign o_nic_1g_tx_raw_valid = 1'b0;
    assign o_nic_1g_phy_diag_ack = 1'b0;
    assign o_nic_1g_phy_ctrl = '0;
    assign o_nic_1g_rx_block_lock = 1'b0;
    assign o_ext_dma_awready = '0;
    assign o_ext_dma_wready = '0;
    assign o_ext_dma_bvalid = '0;
    assign o_ext_dma_bid = '0;
    assign o_ext_dma_bresp = '0;
    assign o_ext_dma_arready = '0;
    assign o_ext_dma_rvalid = '0;
    assign o_ext_dma_rid = '0;
    assign o_ext_dma_rdata = '0;
    assign o_ext_dma_rresp = '0;
    assign o_ext_dma_rlast = '0;
    assign o_ext_mac_tx_tvalid = 1'b0;
    assign o_ext_mac_tx_tdata = '0;
    assign o_ext_mac_tx_tkeep = '0;
    assign o_ext_mac_tx_tlast = 1'b0;
    assign o_ext_mac_tx_tuser = 1'b0;
    assign o_ext_mac_tx_csum = '0;
    assign o_ext_mac_rx_tready = 1'b0;
    assign o_ext_mac_rst = 1'b0;
    assign o_ext_mac_soft_rst = 1'b0;
    assign o_ext_mac_restart = 1'b0;
    assign o_ext_mac_loopback = 1'b0;
    assign o_ext_mac_station_addr = '0;
    assign o_ext_mac_pause_ctrl = '0;
    assign o_ext_mac_pause_high_water = '0;
    assign o_ext_mac_pause_low_water = '0;
    assign o_ext_mac_pause_interval = '0;
    assign o_ext_mac_rx_fifo_limit = '0;
    assign o_ext_mac_rx_fifo_limit_wr = 1'b0;
    assign o_ext_mac_rx_desc_starved = 1'b0;
  end

  if (EXT_AXIL_WINDOW != 0) begin : gen_ext_axil
    axil_register_slice #(
        .ADDR_WIDTH(14),
        .DATA_WIDTH(64)
    ) u_ext_axil_slice (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_s_awvalid(reg_axil_awvalid[ExtAxilPort]),
        .o_s_awready(reg_axil_awready[ExtAxilPort]),
        .i_s_awaddr(14'(reg_axil_addr_q)),
        .i_s_awprot(reg_axil_prot_q),
        .i_s_wvalid(reg_axil_wvalid[ExtAxilPort]),
        .o_s_wready(reg_axil_wready[ExtAxilPort]),
        .i_s_wdata(reg_axil_wdata_q),
        .i_s_wstrb(reg_axil_wstrb_q),
        .o_s_bvalid(reg_axil_bvalid[ExtAxilPort]),
        .i_s_bready(reg_axil_bready[ExtAxilPort]),
        .o_s_bresp(reg_axil_bresp[ExtAxilPort*2+:2]),
        .i_s_arvalid(reg_axil_arvalid[ExtAxilPort]),
        .o_s_arready(reg_axil_arready[ExtAxilPort]),
        .i_s_araddr(14'(reg_axil_addr_q)),
        .i_s_arprot(reg_axil_prot_q),
        .o_s_rvalid(reg_axil_rvalid[ExtAxilPort]),
        .i_s_rready(reg_axil_rready[ExtAxilPort]),
        .o_s_rdata(reg_axil_rdata[ExtAxilPort*64+:64]),
        .o_s_rresp(reg_axil_rresp[ExtAxilPort*2+:2]),
        .o_m_awvalid(o_ext_axil_awvalid),
        .i_m_awready(i_ext_axil_awready),
        .o_m_awaddr(o_ext_axil_awaddr),
        .o_m_awprot(o_ext_axil_awprot),
        .o_m_wvalid(o_ext_axil_wvalid),
        .i_m_wready(i_ext_axil_wready),
        .o_m_wdata(o_ext_axil_wdata),
        .o_m_wstrb(o_ext_axil_wstrb),
        .i_m_bvalid(i_ext_axil_bvalid),
        .o_m_bready(o_ext_axil_bready),
        .i_m_bresp(i_ext_axil_bresp),
        .o_m_arvalid(o_ext_axil_arvalid),
        .i_m_arready(i_ext_axil_arready),
        .o_m_araddr(o_ext_axil_araddr),
        .o_m_arprot(o_ext_axil_arprot),
        .i_m_rvalid(i_ext_axil_rvalid),
        .o_m_rready(o_ext_axil_rready),
        .i_m_rdata(i_ext_axil_rdata),
        .i_m_rresp(i_ext_axil_rresp)
    );
`ifndef SYNTHESIS
    axil_checker #(
        .ADDR_BITS(14)
    ) u_ext_axil_check (
        .i_clk(i_clk),
        .i_rst(rst_core),
        .i_awvalid(o_ext_axil_awvalid),
        .i_awready(i_ext_axil_awready),
        .i_awaddr(o_ext_axil_awaddr),
        .i_awprot(o_ext_axil_awprot),
        .i_wvalid(o_ext_axil_wvalid),
        .i_wready(i_ext_axil_wready),
        .i_wdata(o_ext_axil_wdata),
        .i_wstrb(o_ext_axil_wstrb),
        .i_bvalid(i_ext_axil_bvalid),
        .i_bready(o_ext_axil_bready),
        .i_bresp(i_ext_axil_bresp),
        .i_arvalid(o_ext_axil_arvalid),
        .i_arready(i_ext_axil_arready),
        .i_araddr(o_ext_axil_araddr),
        .i_arprot(o_ext_axil_arprot),
        .i_rvalid(i_ext_axil_rvalid),
        .i_rready(o_ext_axil_rready),
        .i_rdata(i_ext_axil_rdata),
        .i_rresp(i_ext_axil_rresp)
    );
`endif
  end else begin : gen_no_ext_axil
    assign o_ext_axil_awvalid = 1'b0;
    assign o_ext_axil_awaddr  = '0;
    assign o_ext_axil_awprot  = '0;
    assign o_ext_axil_wvalid  = 1'b0;
    assign o_ext_axil_wdata   = '0;
    assign o_ext_axil_wstrb   = '0;
    assign o_ext_axil_bready  = 1'b0;
    assign o_ext_axil_arvalid = 1'b0;
    assign o_ext_axil_araddr  = '0;
    assign o_ext_axil_arprot  = '0;
    assign o_ext_axil_rready  = 1'b0;
  end
  logic axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
  logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast, axi_wlast;
  logic [riscv_pkg::DdrAxiAddrBits-1:0] axi_awaddr, axi_araddr;
  logic [7:0] axi_awlen, axi_arlen;
  logic [2:0] axi_awsize, axi_arsize;
  logic [1:0] axi_awburst, axi_arburst, axi_bresp, axi_rresp;
  logic [L2_LINE_BYTES*8-1:0] axi_wdata, axi_rdata;
  logic [L2_LINE_BYTES-1:0] axi_wstrb;
  logic [DdrAxiIdBits-1:0] axi_awid, axi_arid, axi_bid, axi_rid;


  logic mem_awvalid;
  logic mem_awready;
  logic [AXI_ID_BITS-1:0] mem_awid;
  logic [riscv_pkg::PhysAddrBits-1:0] mem_awaddr;
  logic [8-1:0] mem_awlen;
  logic [3-1:0] mem_awsize;
  logic [2-1:0] mem_awburst;
  logic mem_awlock;
  logic [4-1:0] mem_awcache;
  logic [3-1:0] mem_awprot;
  logic [4-1:0] mem_awqos;
  logic [4-1:0] mem_awregion;
  logic [AXI_USER_BITS-1:0] mem_awuser;
  logic mem_wvalid;
  logic mem_wready;
  logic [L2_LINE_BYTES*8-1:0] mem_wdata;
  logic [L2_LINE_BYTES*8/8-1:0] mem_wstrb;
  logic mem_wlast;
  logic [AXI_USER_BITS-1:0] mem_wuser;
  logic mem_bvalid;
  logic mem_bready;
  logic [AXI_ID_BITS-1:0] mem_bid;
  logic [2-1:0] mem_bresp;
  logic [AXI_USER_BITS-1:0] mem_buser;
  logic mem_arvalid;
  logic mem_arready;
  logic [AXI_ID_BITS-1:0] mem_arid;
  logic [riscv_pkg::PhysAddrBits-1:0] mem_araddr;
  logic [8-1:0] mem_arlen;
  logic [3-1:0] mem_arsize;
  logic [2-1:0] mem_arburst;
  logic mem_arlock;
  logic [4-1:0] mem_arcache;
  logic [3-1:0] mem_arprot;
  logic [4-1:0] mem_arqos;
  logic [4-1:0] mem_arregion;
  logic [AXI_USER_BITS-1:0] mem_aruser;
  logic mem_rvalid;
  logic mem_rready;
  logic [AXI_ID_BITS-1:0] mem_rid;
  logic [L2_LINE_BYTES*8-1:0] mem_rdata;
  logic [2-1:0] mem_rresp;
  logic mem_rlast;
  logic [AXI_USER_BITS-1:0] mem_ruser;
  logic aw_debug_hold_q, aw_debug_q;
  wire [AXI_USER_BITS-1:0] aw_debug_user =
      AXI_USER_BITS'(aw_debug_hold_q ? aw_debug_q : i_debug_mode);
  if (ASYNC_CPU_CLOCK) begin : gen_debug_write_tag
    always_ff @(posedge core_clk) begin
      if (o_cpu_axi_rst) aw_debug_hold_q <= 1'b0;
      else begin
        aw_debug_hold_q <= i_axi_awvalid && !o_axi_awready;
        if (!aw_debug_hold_q) aw_debug_q <= i_debug_mode;
      end
    end
  end else begin : gen_debug_write_tag_unused
    assign aw_debug_hold_q = 1'b0;
    assign aw_debug_q = 1'b0;
  end
  if (ASYNC_CPU_CLOCK) begin : gen_memory_cdc
    axi_cdc #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .DATA_WIDTH(L2_LINE_BYTES * 8),
        .ID_WIDTH  (AXI_ID_BITS),
        .USER_WIDTH(AXI_USER_BITS)
    ) memory_cdc (
        .i_src_clk(core_clk),
        .i_src_rst(o_cpu_axi_rst),
        .i_dst_clk(i_clk),
        .i_dst_rst(soc_axi_rst),
        .i_src_awvalid(i_axi_awvalid),
        .o_dst_awvalid(mem_awvalid),
        .o_src_awready(o_axi_awready),
        .i_dst_awready(mem_awready),
        .i_src_awid(i_axi_awid),
        .o_dst_awid(mem_awid),
        .i_src_awaddr(i_axi_awaddr),
        .o_dst_awaddr(mem_awaddr),
        .i_src_awlen(i_axi_awlen),
        .o_dst_awlen(mem_awlen),
        .i_src_awsize(i_axi_awsize),
        .o_dst_awsize(mem_awsize),
        .i_src_awburst(i_axi_awburst),
        .o_dst_awburst(mem_awburst),
        .i_src_awlock(i_axi_awlock),
        .o_dst_awlock(mem_awlock),
        .i_src_awcache(i_axi_awcache),
        .o_dst_awcache(mem_awcache),
        .i_src_awprot(i_axi_awprot),
        .o_dst_awprot(mem_awprot),
        .i_src_awqos(i_axi_awqos),
        .o_dst_awqos(mem_awqos),
        .i_src_awregion(i_axi_awregion),
        .o_dst_awregion(mem_awregion),
        .i_src_awuser(aw_debug_user),
        .o_dst_awuser(mem_awuser),
        .i_src_wvalid(i_axi_wvalid),
        .o_dst_wvalid(mem_wvalid),
        .o_src_wready(o_axi_wready),
        .i_dst_wready(mem_wready),
        .i_src_wdata(i_axi_wdata),
        .o_dst_wdata(mem_wdata),
        .i_src_wstrb(i_axi_wstrb),
        .o_dst_wstrb(mem_wstrb),
        .i_src_wlast(i_axi_wlast),
        .o_dst_wlast(mem_wlast),
        .i_src_wuser(i_axi_wuser),
        .o_dst_wuser(mem_wuser),
        .o_src_bvalid(o_axi_bvalid),
        .i_dst_bvalid(mem_bvalid),
        .i_src_bready(i_axi_bready),
        .o_dst_bready(mem_bready),
        .o_src_bid(o_axi_bid),
        .i_dst_bid(mem_bid),
        .o_src_bresp(o_axi_bresp),
        .i_dst_bresp(mem_bresp),
        .o_src_buser(o_axi_buser),
        .i_dst_buser(mem_buser),
        .i_src_arvalid(i_axi_arvalid),
        .o_dst_arvalid(mem_arvalid),
        .o_src_arready(o_axi_arready),
        .i_dst_arready(mem_arready),
        .i_src_arid(i_axi_arid),
        .o_dst_arid(mem_arid),
        .i_src_araddr(i_axi_araddr),
        .o_dst_araddr(mem_araddr),
        .i_src_arlen(i_axi_arlen),
        .o_dst_arlen(mem_arlen),
        .i_src_arsize(i_axi_arsize),
        .o_dst_arsize(mem_arsize),
        .i_src_arburst(i_axi_arburst),
        .o_dst_arburst(mem_arburst),
        .i_src_arlock(i_axi_arlock),
        .o_dst_arlock(mem_arlock),
        .i_src_arcache(i_axi_arcache),
        .o_dst_arcache(mem_arcache),
        .i_src_arprot(i_axi_arprot),
        .o_dst_arprot(mem_arprot),
        .i_src_arqos(i_axi_arqos),
        .o_dst_arqos(mem_arqos),
        .i_src_arregion(i_axi_arregion),
        .o_dst_arregion(mem_arregion),
        .i_src_aruser(i_axi_aruser),
        .o_dst_aruser(mem_aruser),
        .o_src_rvalid(o_axi_rvalid),
        .i_dst_rvalid(mem_rvalid),
        .i_src_rready(i_axi_rready),
        .o_dst_rready(mem_rready),
        .o_src_rid(o_axi_rid),
        .i_dst_rid(mem_rid),
        .o_src_rdata(o_axi_rdata),
        .i_dst_rdata(mem_rdata),
        .o_src_rresp(o_axi_rresp),
        .i_dst_rresp(mem_rresp),
        .o_src_rlast(o_axi_rlast),
        .i_dst_rlast(mem_rlast),
        .o_src_ruser(o_axi_ruser),
        .i_dst_ruser(mem_ruser)
    );
  end else begin : gen_memory_cdc_bypass
    assign mem_awvalid = '0;
    assign o_axi_awready = mem_awready;
    assign mem_awid = '0;
    assign mem_awaddr = '0;
    assign mem_awlen = '0;
    assign mem_awsize = '0;
    assign mem_awburst = '0;
    assign mem_awlock = '0;
    assign mem_awcache = '0;
    assign mem_awprot = '0;
    assign mem_awqos = '0;
    assign mem_awregion = '0;
    assign mem_awuser = '0;
    assign mem_wvalid = '0;
    assign o_axi_wready = mem_wready;
    assign mem_wdata = '0;
    assign mem_wstrb = '0;
    assign mem_wlast = '0;
    assign mem_wuser = '0;
    assign o_axi_bvalid = mem_bvalid;
    assign mem_bready = '0;
    assign o_axi_bid = mem_bid;
    assign o_axi_bresp = mem_bresp;
    assign o_axi_buser = mem_buser;
    assign mem_arvalid = '0;
    assign o_axi_arready = mem_arready;
    assign mem_arid = '0;
    assign mem_araddr = '0;
    assign mem_arlen = '0;
    assign mem_arsize = '0;
    assign mem_arburst = '0;
    assign mem_arlock = '0;
    assign mem_arcache = '0;
    assign mem_arprot = '0;
    assign mem_arqos = '0;
    assign mem_arregion = '0;
    assign mem_aruser = '0;
    assign o_axi_rvalid = mem_rvalid;
    assign mem_rready = '0;
    assign o_axi_rid = mem_rid;
    assign o_axi_rdata = mem_rdata;
    assign o_axi_rresp = mem_rresp;
    assign o_axi_rlast = mem_rlast;
    assign o_axi_ruser = mem_ruser;
  end
  soc_axi_slave #(
      .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
      .DATA_BYTES(L2_LINE_BYTES),
      .ID_BITS(AXI_ID_BITS),
      .USER_BITS(AXI_USER_BITS),
      .DDR_BASE(64'(CACHED_BASE)),
      .DDR_BYTES(CACHED_SIZE_BYTES),
      .LOCAL_USER_ENABLE(ASYNC_CPU_CLOCK)
  ) bus_slave (
      .i_clk,
      .i_axi_rst(soc_axi_rst),
      .o_local_valid(local_valid),
      .i_local_ready(local_ready),
      .o_local_write(local_req_write),
      .o_local_addr(local_req_addr),
      .o_local_size(local_req_size),
      .o_local_prot(local_req_prot),
      .o_local_wdata(local_req_wdata),
      .o_local_wstrb(local_req_wstrb),
      .o_local_error(local_req_error),
      .o_local_user(local_req_user),
      .i_local_resp_valid(local_resp_valid),
      .o_local_resp_ready(local_resp_ready),
      .i_local_resp_rdata(local_resp_data),
      .i_local_resp_status(local_resp_status),
      .i_axi_awvalid(ASYNC_CPU_CLOCK ? mem_awvalid : i_axi_awvalid),
      .o_axi_awready(mem_awready),
      .i_axi_awid(ASYNC_CPU_CLOCK ? mem_awid : i_axi_awid),
      .i_axi_awaddr(ASYNC_CPU_CLOCK ? mem_awaddr : i_axi_awaddr),
      .i_axi_awlen(ASYNC_CPU_CLOCK ? mem_awlen : i_axi_awlen),
      .i_axi_awsize(ASYNC_CPU_CLOCK ? mem_awsize : i_axi_awsize),
      .i_axi_awburst(ASYNC_CPU_CLOCK ? mem_awburst : i_axi_awburst),
      .i_axi_awlock(ASYNC_CPU_CLOCK ? mem_awlock : i_axi_awlock),
      .i_axi_awcache(ASYNC_CPU_CLOCK ? mem_awcache : i_axi_awcache),
      .i_axi_awprot(ASYNC_CPU_CLOCK ? mem_awprot : i_axi_awprot),
      .i_axi_awqos(ASYNC_CPU_CLOCK ? mem_awqos : i_axi_awqos),
      .i_axi_awregion(ASYNC_CPU_CLOCK ? mem_awregion : i_axi_awregion),
      .i_axi_awuser(ASYNC_CPU_CLOCK ? mem_awuser : i_axi_awuser),
      .i_axi_wvalid(ASYNC_CPU_CLOCK ? mem_wvalid : i_axi_wvalid),
      .o_axi_wready(mem_wready),
      .i_axi_wdata(ASYNC_CPU_CLOCK ? mem_wdata : i_axi_wdata),
      .i_axi_wstrb(ASYNC_CPU_CLOCK ? mem_wstrb : i_axi_wstrb),
      .i_axi_wlast(ASYNC_CPU_CLOCK ? mem_wlast : i_axi_wlast),
      .i_axi_wuser(ASYNC_CPU_CLOCK ? mem_wuser : i_axi_wuser),
      .o_axi_bvalid(mem_bvalid),
      .i_axi_bready(ASYNC_CPU_CLOCK ? mem_bready : i_axi_bready),
      .o_axi_bid(mem_bid),
      .o_axi_bresp(mem_bresp),
      .o_axi_buser(mem_buser),
      .i_axi_arvalid(ASYNC_CPU_CLOCK ? mem_arvalid : i_axi_arvalid),
      .o_axi_arready(mem_arready),
      .i_axi_arid(ASYNC_CPU_CLOCK ? mem_arid : i_axi_arid),
      .i_axi_araddr(ASYNC_CPU_CLOCK ? mem_araddr : i_axi_araddr),
      .i_axi_arlen(ASYNC_CPU_CLOCK ? mem_arlen : i_axi_arlen),
      .i_axi_arsize(ASYNC_CPU_CLOCK ? mem_arsize : i_axi_arsize),
      .i_axi_arburst(ASYNC_CPU_CLOCK ? mem_arburst : i_axi_arburst),
      .i_axi_arlock(ASYNC_CPU_CLOCK ? mem_arlock : i_axi_arlock),
      .i_axi_arcache(ASYNC_CPU_CLOCK ? mem_arcache : i_axi_arcache),
      .i_axi_arprot(ASYNC_CPU_CLOCK ? mem_arprot : i_axi_arprot),
      .i_axi_arqos(ASYNC_CPU_CLOCK ? mem_arqos : i_axi_arqos),
      .i_axi_arregion(ASYNC_CPU_CLOCK ? mem_arregion : i_axi_arregion),
      .i_axi_aruser(ASYNC_CPU_CLOCK ? mem_aruser : i_axi_aruser),
      .o_axi_rvalid(mem_rvalid),
      .i_axi_rready(ASYNC_CPU_CLOCK ? mem_rready : i_axi_rready),
      .o_axi_rid(mem_rid),
      .o_axi_rdata(mem_rdata),
      .o_axi_rresp(mem_rresp),
      .o_axi_rlast(mem_rlast),
      .o_axi_ruser(mem_ruser),
      .o_ddr_axi_awvalid(axi_awvalid),
      .i_ddr_axi_awready(axi_awready),
      .o_ddr_axi_awid(axi_awid),
      .o_ddr_axi_awaddr(axi_awaddr),
      .o_ddr_axi_awlen(axi_awlen),
      .o_ddr_axi_awsize(axi_awsize),
      .o_ddr_axi_awburst(axi_awburst),
      .o_ddr_axi_wvalid(axi_wvalid),
      .i_ddr_axi_wready(axi_wready),
      .o_ddr_axi_wdata(axi_wdata),
      .o_ddr_axi_wstrb(axi_wstrb),
      .o_ddr_axi_wlast(axi_wlast),
      .i_ddr_axi_bvalid(axi_bvalid),
      .o_ddr_axi_bready(axi_bready),
      .i_ddr_axi_bid(axi_bid),
      .i_ddr_axi_bresp(axi_bresp),
      .o_ddr_axi_arvalid(axi_arvalid),
      .i_ddr_axi_arready(axi_arready),
      .o_ddr_axi_arid(axi_arid),
      .o_ddr_axi_araddr(axi_araddr),
      .o_ddr_axi_arlen(axi_arlen),
      .o_ddr_axi_arsize(axi_arsize),
      .o_ddr_axi_arburst(axi_arburst),
      .i_ddr_axi_rvalid(axi_rvalid),
      .o_ddr_axi_rready(axi_rready),
      .i_ddr_axi_rid(axi_rid),
      .i_ddr_axi_rdata(axi_rdata),
      .i_ddr_axi_rresp(axi_rresp),
      .i_ddr_axi_rlast(axi_rlast)
  );

  assign ddr_rd_err_valid = axi_rvalid && axi_rready && axi_rresp[1];
  assign ddr_wr_err_valid = axi_bvalid && axi_bready && axi_bresp[1];
  assign ddr_rd_err_resp = axi_rresp;
  assign ddr_wr_err_resp = axi_bresp;
  assign ddr_rd_err_id = axi_rid;
  assign ddr_wr_err_id = axi_bid;
  // Hang-triage memory taps now observe actual external transactions.
  assign data_memory_cached_read_enable = axi_arvalid && axi_arready;
  assign data_memory_cached_read_valid = axi_rvalid && axi_rready;
  assign data_memory_cached_byte_write_enable = {8{axi_wvalid && axi_wready}};
  assign data_memory_cached_write_done = axi_bvalid && axi_bready;
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
        .i_rst(soc_axi_rst),
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
  // Pipeline registers for memory access signals (accounts for RAM read latency)
  logic data_memory_read_enable_registered;
  always_ff @(posedge i_clk) begin
    data_memory_address_registered <= data_memory_address;
    data_memory_read_enable_registered <= rst_core ? 1'b0 : data_memory_read_enable;
    data_memory_byte_write_enable_registered <= rst_core ? '0 : data_memory_byte_write_enable;

    data_memory_write_data_registered <= data_memory_write_data;
  end

  // The local access logic already qualifies this pulse against MMIO bounds.
  assign mmio_read_capture = mmio_read_pulse;
  wire alias_read_capture = alias_done && !local_write;
  assign mmio_response_capture = mmio_read_capture || reg_axil_read_capture || alias_read_capture;
  assign mmio_response_data = reg_axil_read_capture ?
      (rst_core ? 64'b0 : reg_axil_rdata[reg_axil_port_q*64+:64]) :
      alias_read_capture ? alias_rdata : mmio_read_data_comb;

  // Capture the performed MMIO read on mmio_read_pulse. Each case selects
  // an aligned dword {word at +4, word at +0}; addr[2] selects a 32-bit result
  // downstream. CLINT 64-bit reads are atomic in one beat.
  //
  // Destructive reads decode the exact word address for UART/FIFO/RBR pops
  // and APLIC claims in this SoC. Merely including a neighbor in the other
  // lane does not consume it. See hw/rtl/README.md,
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
      // {UART RX data (read consumes byte, via the SoC's one-shot pulse),
      //  UART TX (write-only, reads 0)}
      {UartMmioAddr[31:3], 3'b000} : mmio_read_data_comb = {{24'b0, i_uart_rx_data}, 32'b0};
      // {FIFO1, FIFO0}
      {
        Fifo0MmioAddr[31:3], 3'b000
      } :
      mmio_read_data_comb = {
        i_fifo1_empty ? 32'b0 : i_fifo1_rd_data, i_fifo0_empty ? 32'b0 : i_fifo0_rd_data
      };
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
      // VCU118 SPI flash & boot SRAM controller (0 when ENABLE_1G_ETH == 0).
      {
        BootSpiCtrlAddr[31:3], 3'b000
      } :
      mmio_read_data_comb = {boot_sys_status_word, boot_spi_ctrl_word};
      {
        BootSpiXferByteAddr[31:3], 3'b000
      } :
      mmio_read_data_comb = {boot_spi_rx_word_le, boot_spi_rx_byte_word};
      {
        BootSramAddrReg[31:3], 3'b000
      } :
      mmio_read_data_comb = {boot_sram_data_word, boot_sram_addr_word};
      default: ;
    endcase
    // APLIC window: range-decoded outside the exact-address case; the
    // APLIC returns a register pair only for a 32-bit load.
    if (mmio_load_addr[31:22] == AplicWindowSel)
      mmio_read_data_comb = (local_size == 3'd2) ? aplic_rd_pair : 64'b0;
    // Memory error unit window: likewise.
    if (mmio_load_addr[31:8] == MemErrBase[31:8]) mmio_read_data_comb = memerr_rd_pair;
  end

  // Register MMIO read data so the CPU sees a stable response after the
  // side-effect pulse fires.
  always_ff @(posedge i_clk) begin
    if (rst_core) begin
      mmio_read_data_valid <= 1'b0;
    end else begin
      if (mmio_response_capture) begin
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
        .CE(mmio_response_capture),
        .D (mmio_response_data[g_mmio_read_data]),
        .Q (mmio_read_data_reg[g_mmio_read_data]),
        .R (1'b0)
    );
  end
`else
  always_ff @(posedge i_clk) begin
    if (mmio_response_capture) begin
      mmio_read_data_reg <= mmio_response_data;
    end
  end
`endif

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

  if (ENABLE_1G_ETH != 0) begin : gen_boot_spi
    (* ASYNC_REG = "TRUE" *) logic [1:0] spi_miso_sync_q;
    always_ff @(posedge i_clk) begin
      if (rst_core) spi_miso_sync_q <= 2'b11;
      else spi_miso_sync_q <= {spi_miso_sync_q[0], i_spi_miso};
    end

    logic        spi_cs_n_q;
    logic [ 7:0] spi_clk_div_q;
    logic [ 7:0] spi_clk_cnt_q;
    logic        spi_sck_q;
    logic        spi_busy_q;
    logic [ 5:0] spi_bits_rem_q;
    logic [31:0] spi_tx_shreg_q;
    logic [31:0] spi_rx_shreg_q;

    assign o_spi_cs_n = spi_cs_n_q;
    assign o_spi_sck  = spi_sck_q;
    assign o_spi_mosi = spi_tx_shreg_q[31];

    wire boot_reg_wr = |data_memory_byte_write_enable_registered;

    always_ff @(posedge i_clk) begin
      if (rst_core) begin
        spi_cs_n_q            <= 1'b1;
        spi_clk_div_q         <= 8'd8;
        spi_clk_cnt_q         <= '0;
        spi_sck_q             <= 1'b0;
        spi_busy_q            <= 1'b0;
        spi_bits_rem_q        <= '0;
        spi_tx_shreg_q        <= 32'hFFFF_FFFF;
        spi_rx_shreg_q        <= '0;
        boot_sram_wr_req_q    <= 1'b0;
        boot_sram_word_addr_q <= '0;
        boot_sram_wdata_q     <= '0;
      end else begin
        if (boot_sram_slice_valid && slice_req_ready) begin
          boot_sram_wr_req_q    <= 1'b0;
          boot_sram_word_addr_q <= boot_sram_word_addr_q + 1'b1;
        end

        if (spi_busy_q) begin
          if (spi_clk_cnt_q >= (spi_clk_div_q - 8'd1)) begin
            spi_clk_cnt_q <= '0;
            if (!spi_sck_q) begin
              spi_sck_q      <= 1'b1;
              spi_rx_shreg_q <= {spi_rx_shreg_q[30:0], spi_miso_sync_q[1]};
            end else begin
              spi_sck_q <= 1'b0;
              if (spi_bits_rem_q == 6'd1) begin
                spi_busy_q     <= 1'b0;
                spi_bits_rem_q <= '0;
              end else begin
                spi_bits_rem_q <= spi_bits_rem_q - 6'd1;
                spi_tx_shreg_q <= {spi_tx_shreg_q[30:0], 1'b1};
              end
            end
          end else begin
            spi_clk_cnt_q <= spi_clk_cnt_q + 8'd1;
          end
        end

        if (boot_reg_wr) begin
          unique case (data_memory_address_registered)
            riscv_pkg::PhysAddrBits'(BootSpiCtrlAddr): begin
              spi_cs_n_q <= data_memory_write_data_registered[0];
              if (data_memory_write_data_registered[15:8] != 8'd0)
                spi_clk_div_q <= data_memory_write_data_registered[15:8];
            end
            riscv_pkg::PhysAddrBits'(BootSpiXferByteAddr): begin
              if (!spi_busy_q) begin
                spi_tx_shreg_q <= {data_memory_write_data_registered[7:0], 24'hFF_FFFF};
                spi_bits_rem_q <= 6'd8;
                spi_clk_cnt_q  <= '0;
                spi_sck_q      <= 1'b0;
                spi_busy_q     <= 1'b1;
              end
            end
            riscv_pkg::PhysAddrBits'(BootSpiXferWordAddr): begin
              if (!spi_busy_q) begin
                spi_tx_shreg_q <= data_memory_write_data_registered[31:0];
                spi_bits_rem_q <= 6'd32;
                spi_clk_cnt_q  <= '0;
                spi_sck_q      <= 1'b0;
                spi_busy_q     <= 1'b1;
              end
            end
            riscv_pkg::PhysAddrBits'(BootSramAddrReg): begin
              boot_sram_word_addr_q <= data_memory_write_data_registered[MemByteAddrWidth-1:2];
            end
            riscv_pkg::PhysAddrBits'(BootSramDataReg): begin
              boot_sram_wdata_q  <= data_memory_write_data_registered[31:0];
              boot_sram_wr_req_q <= 1'b1;
            end
            default: ;
          endcase
        end
      end
    end

    wire sram_wr_busy = boot_sram_wr_req_q || !slice_req_ready || !slice_all_done;
    assign boot_spi_ctrl_word = {16'b0, spi_clk_div_q, 7'b0, spi_cs_n_q};
    assign boot_sys_status_word = {
      16'h4652, 6'b0, i_ddr_status[1:0], 6'b0, sram_wr_busy, spi_busy_q
    };
    assign boot_spi_rx_byte_word = {24'b0, spi_rx_shreg_q[7:0]};
    assign boot_spi_rx_word_le = {
      spi_rx_shreg_q[7:0], spi_rx_shreg_q[15:8], spi_rx_shreg_q[23:16], spi_rx_shreg_q[31:24]
    };
    assign boot_sram_addr_word = 32'({boot_sram_word_addr_q, 2'b00});
    assign boot_sram_data_word = boot_sram_wdata_q;
  end else begin : gen_no_boot_spi
    /* verilator lint_off UNUSEDSIGNAL */
    wire boot_spi_unused = i_spi_miso ^ (|i_ddr_status);
    /* verilator lint_on UNUSEDSIGNAL */
    assign o_spi_cs_n            = 1'b1;
    assign o_spi_sck             = 1'b0;
    assign o_spi_mosi            = 1'b0;
    assign boot_sram_wr_req_q    = 1'b0;
    assign boot_sram_word_addr_q = '0;
    assign boot_sram_wdata_q     = '0;
    assign boot_spi_ctrl_word    = '0;
    assign boot_sys_status_word  = '0;
    assign boot_spi_rx_byte_word = '0;
    assign boot_spi_rx_word_le   = '0;
    assign boot_sram_addr_word   = '0;
    assign boot_sram_data_word   = '0;
  end

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

  // SYSRESET: a store of SysResetKey to SysResetAddr raises sysreset_q for
  // SysResetCycles clocks. Only the external reset can cancel it, because the
  // core reset it causes must not cancel its own pulse; the stretch lets the
  // asynchronous reset chains of both clock domains observe it.
  localparam int unsigned SysResetCycles = 64;
  logic [$clog2(SysResetCycles)-1:0] sysreset_cnt_q;
  wire sysreset_write =
      (data_memory_address_registered == riscv_pkg::PhysAddrBits'(SysResetAddr)) &&
      (data_memory_byte_write_enable_registered[1:0] == 2'b11) &&
      (data_memory_write_data_registered[15:0] == SysResetKey);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sysreset_q <= 1'b0;
      sysreset_cnt_q <= '0;
    end else if (sysreset_write) begin
      sysreset_q <= 1'b1;
      sysreset_cnt_q <= $bits(sysreset_cnt_q)'(SysResetCycles - 1);
    end else if (sysreset_q) begin
      sysreset_cnt_q <= sysreset_cnt_q - 1'b1;
      if (sysreset_cnt_q == '0) sysreset_q <= 1'b0;
    end
  end

endmodule : soc_top
