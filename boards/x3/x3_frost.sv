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

// X3 board top level: UltraScale+ clock generation, the DDR4 memory subsystem
// (the ddr_subsys block design, holding the DDR4 controller, a SmartConnect
// and the JTAG DDR loader), the NIC's GTY transceiver (x3_nic_gty) and the
// common FROST subsystem.
module x3_frost #(
    // Two MMCM recipes: the rated clock and the single-core roadmap target.
    // Software and block-design clocks must use the same selected rate.
    parameter int unsigned CPU_BASE_CLK_HZ = 300_000_000,
    // CPU clock divider for functional-validation builds (build.py
    // --cpu-clock-div exports it as FROST_CPU_CLK_DIV and synthesis passes
    // it as a generic): divides CPU_BASE_CLK_HZ. The 300 MHz reference,
    // the DDR4 controller and its clocking are unaffected.
    parameter int unsigned CPU_CLK_DIV = 1,

    // Profiling counters (build.py --perf-counters exports FROST_PERF_COUNTERS
    // and synthesis passes it as a generic): 0 = absent, the 300 MHz production
    // build; 1 for analysis builds such as a divided-clock one.
    parameter int unsigned PERF_COUNTERS = 0,
    // Opt-in roadmap configuration; no rated clock/score is implied. The
    // clock remains an independent choice through CPU_BASE_CLK_HZ.
    parameter bit SINGLE_CORE_PERFORMANCE = 1'b0
) (
    input logic i_sysclk_n,  // Differential system clock negative
    input logic i_sysclk_p,  // Differential system clock positive (300 MHz)

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx,  // UART receive for debug console input

    // Dedicated DDR4 system clock (300 MHz differential, AN27/AN28)
    input logic default_300mhz_clk0_clk_p,
    input logic default_300mhz_clk0_clk_n,

    // DDR4 SDRAM (pins constrained in constr/x3.xdc)
    output logic [16:0] ddr4_sdram_c0_adr,
    output logic        ddr4_sdram_c0_act_n,
    output logic [ 1:0] ddr4_sdram_c0_ba,
    output logic [ 0:0] ddr4_sdram_c0_bg,
    output logic        ddr4_sdram_c0_ck_c,
    output logic        ddr4_sdram_c0_ck_t,
    output logic        ddr4_sdram_c0_cke,
    output logic        ddr4_sdram_c0_cs_n,
    inout  wire  [ 8:0] ddr4_sdram_c0_dm_n,
    inout  wire  [71:0] ddr4_sdram_c0_dq,
    inout  wire  [ 8:0] ddr4_sdram_c0_dqs_c,
    inout  wire  [ 8:0] ddr4_sdram_c0_dqs_t,
    output logic        ddr4_sdram_c0_odt,
    output logic        ddr4_sdram_c0_reset_n,

    // NIC transceiver, quad 231 (pins constrained in constr/x3.xdc): the
    // 161.1328125 MHz Ethernet reference clock (MGTREFCLK0, P9/P8) and GTY
    // channel X0Y28 (TX J7/J6, RX K4/K3), lane 1 of the DSFP28 cage
    // labelled 2.
    input  logic i_nic_refclk_p,
    input  logic i_nic_refclk_n,
    input  logic i_nic_rxp,
    input  logic i_nic_rxn,
    output logic o_nic_txp,
    output logic o_nic_txn
);

  // Clock generation using Xilinx MMCM and clock dividers. The selected VCO
  // is divided by 4 x CPU_CLK_DIV for the CPU clock.
  localparam real CpuClkOutDivide = 4.0 * CPU_CLK_DIV;
  localparam int unsigned CpuClkHz = CPU_BASE_CLK_HZ / CPU_CLK_DIV;
  localparam int CpuMmcmInputDivide = CPU_BASE_CLK_HZ == 322_265_625 ? 8 : 1;
  localparam real CpuMmcmMultiply = CPU_BASE_CLK_HZ == 322_265_625 ? 34.375 : 4.0;
  initial begin
    if (CPU_BASE_CLK_HZ != 300_000_000 && CPU_BASE_CLK_HZ != 322_265_625)
      $fatal(1, "Unsupported X3 CPU MMCM recipe");
  end
  logic main_clock, divided_clock_by_4;
  logic mmcm_locked;
  logic differential_clock_300mhz_buffered, clock_feedback, clock_from_mmcm;

  // Convert differential clock input to single-ended
  IBUFDS differential_input_buffer_300mhz (
      .I (i_sysclk_p),
      .IB(i_sysclk_n),
      .O (differential_clock_300mhz_buffered)
  );

  // Mixed-Mode Clock Manager (MMCM) for PLL-based clock generation.
  // Rated clock: 300 MHz. The roadmap's 322.265625 MHz target uses:
  //   .DIVCLK_DIVIDE   (8),       // Pre-divider: 300MHz / 8 = 37.5MHz
  //   .CLKFBOUT_MULT_F (34.375),  // VCO: 37.5MHz × 34.375 = 1289.0625 MHz
  //   .CLKOUT0_DIVIDE_F(4.0)      // Output: 1289.0625MHz / 4 = 322.265625 MHz
  MMCME2_ADV #(
      .CLKIN1_PERIOD   (3.333),               // Input period: 1/300MHz = 3.333ns
      .DIVCLK_DIVIDE   (CpuMmcmInputDivide),
      // VCO: 1200 MHz at the rated clock; 1289.0625 MHz at the target clock.
      .CLKFBOUT_MULT_F (CpuMmcmMultiply),
      // Output: selected base clock / CPU_CLK_DIV.
      .CLKOUT0_DIVIDE_F(CpuClkOutDivide)
  ) mixed_mode_clock_manager (
      .CLKIN1  (differential_clock_300mhz_buffered),
      .CLKFBIN (clock_feedback),
      .CLKFBOUT(clock_feedback),
      .CLKOUT0 (clock_from_mmcm),
      .RST     (1'b0),                                // Don't reset MMCM
      .PWRDWN  (1'b0),                                // Don't power down
      .CLKIN2  (1'b0),
      .CLKINSEL(1'b1),                                // Select CLKIN1
      .LOCKED  (mmcm_locked)
  );

  // Global clock buffer for the undivided main clock.
  // BUFGCE_DIV is an UltraScale+ primitive.
  BUFGCE_DIV #(
      .BUFGCE_DIVIDE  (1),     // Divide by 1 (no division for main clock)
      // Programmable inversion attributes (all disabled)
      .IS_CE_INVERTED (1'b0),  // Clock enable not inverted
      .IS_CLR_INVERTED(1'b0),  // Clear not inverted
      .IS_I_INVERTED  (1'b0)   // Input not inverted
  ) main_clock_buffer (
      .O(main_clock),
      .CE(1'b1),  // Clock enable always active
      .CLR(1'b0),  // Clear never active
      .I(clock_from_mmcm)
  );

  // Global clock buffer for the divide-by-4 JTAG/UART clock.
  BUFGCE_DIV #(
      .BUFGCE_DIVIDE  (4),     // Divide by 4 for slower clock domain
      .IS_CE_INVERTED (1'b0),
      .IS_CLR_INVERTED(1'b0),
      .IS_I_INVERTED  (1'b0)
  ) divided_clock_buffer (
      .O(divided_clock_by_4),
      .CE(1'b1),  // Clock enable always active
      .CLR(1'b0),  // Clear never active
      .I(clock_from_mmcm)
  );

  // The NIC's 10GBASE-R transceiver. Its reset controller runs on a divided
  // copy of the 300 MHz input taken before the MMCM, and it supplies both MAC
  // clocks (TX and recovered RX USRCLK2, 161.13 MHz), their clock-OK levels,
  // the raw words, the receive signal-OK and the PHY status.
  logic nic_tx_clk, nic_rx_clk, nic_tx_clk_ok, nic_rx_clk_ok, nic_rx_signal_ok, nic_rx_raw_valid;
  logic nic_tx_raw_valid, nic_rx_block_lock;
  logic [63:0] nic_tx_raw_data, nic_rx_raw_data;
  logic [3:1] nic_phy_ctrl;
  logic [4:0] nic_phy_status;
  x3_nic_gty nic_transceiver (
      .i_sysclk_300   (differential_clock_300mhz_buffered),
      .i_refclk_p     (i_nic_refclk_p),
      .i_refclk_n     (i_nic_refclk_n),
      .i_rxp          (i_nic_rxp),
      .i_rxn          (i_nic_rxn),
      .o_txp          (o_nic_txp),
      .o_txn          (o_nic_txn),
      .o_tx_clk       (nic_tx_clk),
      .o_rx_clk       (nic_rx_clk),
      .o_tx_clk_ok    (nic_tx_clk_ok),
      .o_rx_clk_ok    (nic_rx_clk_ok),
      .i_tx_raw_data  (nic_tx_raw_data),
      .i_tx_raw_valid (nic_tx_raw_valid),
      .o_rx_raw_data  (nic_rx_raw_data),
      .o_rx_raw_valid (nic_rx_raw_valid),
      .o_rx_signal_ok (nic_rx_signal_ok),
      .i_phy_ctrl     (nic_phy_ctrl),
      .o_phy_status   (nic_phy_status),
      .i_rx_block_lock(nic_rx_block_lock)
  );

  // DDR AXI between the FROST cache-hierarchy bridge and the DDR4 subsystem
  logic ddr_axi_awvalid, ddr_axi_awready, ddr_axi_wvalid, ddr_axi_wready;
  logic ddr_axi_bvalid, ddr_axi_bready, ddr_axi_arvalid, ddr_axi_arready;
  logic ddr_axi_rvalid, ddr_axi_rready, ddr_axi_wlast, ddr_axi_rlast;
  logic [31:0] ddr_axi_awaddr, ddr_axi_araddr;
  logic [7:0] ddr_axi_awlen, ddr_axi_arlen;
  logic [2:0] ddr_axi_awsize, ddr_axi_arsize;
  logic [1:0] ddr_axi_awburst, ddr_axi_arburst, ddr_axi_bresp, ddr_axi_rresp;
  logic [255:0] ddr_axi_wdata, ddr_axi_rdata;
  logic [31:0] ddr_axi_wstrb;
  logic [4:0] ddr_axi_awid, ddr_axi_arid, ddr_axi_bid, ddr_axi_rid;

  logic mem_ok;
  // mem_ok originates in the DDR controller's ui_clk domain: synchronize it
  // into the core clock domain before folding it into the reset tree (the
  // raw reset fans combinationally into both board clock domains). The
  // crossing is cut by the set_clock_groups -asynchronous in the xdc, which
  // declares the i_sysclk_p and default_300mhz_clk0 (DDR4) clock families
  // asynchronous; the targeted false_path there is documentation only.
  (* ASYNC_REG = "TRUE" *) logic [1:0] mem_ok_synchronizer;
  always_ff @(posedge main_clock) begin
    mem_ok_synchronizer <= {mem_ok_synchronizer[0], mem_ok};
  end
  logic mem_ok_synced;
  assign mem_ok_synced = mem_ok_synchronizer[1];

  logic cpu_side_aresetn;
  assign cpu_side_aresetn = mmcm_locked;

  // Power-up DDR4 initialization. The array is ECC-checked, so a read of a
  // location nothing has written since power-up reports an error against a
  // check code that was never computed. x3_ddr_init writes the region once
  // after calibration, and until it reports done the FROST subsystem and the
  // JTAG image loader are both held in reset, so nothing else can read or
  // write the array first. The SmartConnect's own reset is not gated: the
  // initializer writes through it.
  logic ddr_init_busy, ddr_init_done;
  logic init_awvalid, init_wvalid, init_wlast, init_bready;
  logic [  4:0] init_awid;
  logic [ 29:0] init_awaddr;
  logic [  7:0] init_awlen;
  logic [  2:0] init_awsize;
  logic [  1:0] init_awburst;
  logic [255:0] init_wdata;
  logic [ 31:0] init_wstrb;

  x3_ddr_init #(
      .ADDR_BITS(30),
      .DATA_BITS(256),
      .ID_BITS  (5)
  ) ddr_initializer (
      .i_clk    (main_clock),
      .i_rst_n  (mmcm_locked),
      .i_start  (mem_ok_synced),
      .o_busy   (ddr_init_busy),
      .o_done   (ddr_init_done),
      .o_awvalid(init_awvalid),
      .i_awready(ddr_axi_awready),
      .o_awid   (init_awid),
      .o_awaddr (init_awaddr),
      .o_awlen  (init_awlen),
      .o_awsize (init_awsize),
      .o_awburst(init_awburst),
      .o_wvalid (init_wvalid),
      .i_wready (ddr_axi_wready),
      .o_wdata  (init_wdata),
      .o_wstrb  (init_wstrb),
      .o_wlast  (init_wlast),
      .i_bvalid (ddr_axi_bvalid),
      .o_bready (init_bready),
      .i_bresp  (ddr_axi_bresp)
  );

  // The write channels into the block design belong to the initializer until
  // it is done, and to the cache hierarchy's bridge after. Only the request
  // side is selected: the subsystem is in reset for the whole initializing
  // window, so its own write requests are idle and the controller's ready and
  // response lines can go to both readers unchanged.
  logic s00_awvalid, s00_wvalid, s00_wlast, s00_bready;
  logic [  4:0] s00_awid;
  logic [ 29:0] s00_awaddr;
  logic [  7:0] s00_awlen;
  logic [  2:0] s00_awsize;
  logic [  1:0] s00_awburst;
  logic [255:0] s00_wdata;
  logic [ 31:0] s00_wstrb;
  assign s00_awvalid = ddr_init_busy ? init_awvalid : ddr_axi_awvalid;
  assign s00_awid = ddr_init_busy ? init_awid : ddr_axi_awid;
  assign s00_awaddr = ddr_init_busy ? init_awaddr : ddr_axi_awaddr[29:0];
  assign s00_awlen = ddr_init_busy ? init_awlen : ddr_axi_awlen;
  assign s00_awsize = ddr_init_busy ? init_awsize : ddr_axi_awsize;
  assign s00_awburst = ddr_init_busy ? init_awburst : ddr_axi_awburst;
  assign s00_wvalid = ddr_init_busy ? init_wvalid : ddr_axi_wvalid;
  assign s00_wdata = ddr_init_busy ? init_wdata : ddr_axi_wdata;
  assign s00_wstrb = ddr_init_busy ? init_wstrb : ddr_axi_wstrb;
  assign s00_wlast = ddr_init_busy ? init_wlast : ddr_axi_wlast;
  assign s00_bready = ddr_init_busy ? init_bready : ddr_axi_bready;

  // DDR4 subsystem block design: the controller (reference CONFIG) and a
  // SmartConnect whose S00 is the FROST bridge below and S01 the JTAG
  // DDR-image loader. Addresses are region-relative. The X3 has no push-button
  // reset, so the controller is held in reset until the board MMCM locks.
  ddr_subsys_wrapper ddr_subsystem (
      .cpu_clk(main_clock),
      .jtag_clk(divided_clock_by_4),
      .default_300mhz_clk0_clk_p(default_300mhz_clk0_clk_p),
      .default_300mhz_clk0_clk_n(default_300mhz_clk0_clk_n),
      .sys_reset(~mmcm_locked),
      .cpu_aresetn(cpu_side_aresetn),
      .jtag_aresetn(cpu_side_aresetn & ddr_init_done),
      .mem_ok(mem_ok),
      .S00_AXI_awvalid(s00_awvalid),
      .S00_AXI_awready(ddr_axi_awready),
      .S00_AXI_awid(s00_awid),
      .S00_AXI_awaddr(s00_awaddr),
      .S00_AXI_awlen(s00_awlen),
      .S00_AXI_awsize(s00_awsize),
      .S00_AXI_awburst(s00_awburst),
      .S00_AXI_wvalid(s00_wvalid),
      .S00_AXI_wready(ddr_axi_wready),
      .S00_AXI_wdata(s00_wdata),
      .S00_AXI_wstrb(s00_wstrb),
      .S00_AXI_wlast(s00_wlast),
      .S00_AXI_bvalid(ddr_axi_bvalid),
      .S00_AXI_bready(s00_bready),
      .S00_AXI_bid(ddr_axi_bid),
      .S00_AXI_bresp(ddr_axi_bresp),
      .S00_AXI_arvalid(ddr_axi_arvalid),
      .S00_AXI_arready(ddr_axi_arready),
      .S00_AXI_arid(ddr_axi_arid),
      .S00_AXI_araddr(ddr_axi_araddr[29:0]),
      .S00_AXI_arlen(ddr_axi_arlen),
      .S00_AXI_arsize(ddr_axi_arsize),
      .S00_AXI_arburst(ddr_axi_arburst),
      .S00_AXI_rvalid(ddr_axi_rvalid),
      .S00_AXI_rready(ddr_axi_rready),
      .S00_AXI_rid(ddr_axi_rid),
      .S00_AXI_rdata(ddr_axi_rdata),
      .S00_AXI_rresp(ddr_axi_rresp),
      .S00_AXI_rlast(ddr_axi_rlast),
      .ddr4_sdram_c0_adr(ddr4_sdram_c0_adr),
      .ddr4_sdram_c0_act_n(ddr4_sdram_c0_act_n),
      .ddr4_sdram_c0_ba(ddr4_sdram_c0_ba),
      .ddr4_sdram_c0_bg(ddr4_sdram_c0_bg),
      .ddr4_sdram_c0_ck_c(ddr4_sdram_c0_ck_c),
      .ddr4_sdram_c0_ck_t(ddr4_sdram_c0_ck_t),
      .ddr4_sdram_c0_cke(ddr4_sdram_c0_cke),
      .ddr4_sdram_c0_cs_n(ddr4_sdram_c0_cs_n),
      .ddr4_sdram_c0_dm_n(ddr4_sdram_c0_dm_n),
      .ddr4_sdram_c0_dq(ddr4_sdram_c0_dq),
      .ddr4_sdram_c0_dqs_c(ddr4_sdram_c0_dqs_c),
      .ddr4_sdram_c0_dqs_t(ddr4_sdram_c0_dqs_t),
      .ddr4_sdram_c0_odt(ddr4_sdram_c0_odt),
      .ddr4_sdram_c0_reset_n(ddr4_sdram_c0_reset_n)
  );

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU).
  // Clock: CPU_BASE_CLK_HZ / CPU_CLK_DIV.
  // X3 has no push-button reset, so the subsystem stays in reset until the
  // MMCM locks, DDR4 calibrates, and ECC initialization completes. The
  // cached tier is ready for the first instruction.
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(CpuClkHz),
      // X3's L1 BRAM + L2 URAM hierarchy is backed by the DDR4 controller
      // through the AXI port below.
      .ENABLE_CACHED_TIER(1),
      .USE_BEHAVIORAL_DDR(0),
      .PERF_COUNTERS(PERF_COUNTERS),
      .EARLY_LOAD_WAKEUP(SINGLE_CORE_PERFORMANCE),
      .PREPARE_LOAD_WHILE_BUSY(SINGLE_CORE_PERFORMANCE),
      .DECODED_QUEUE_DEPTH(SINGLE_CORE_PERFORMANCE ? 4 : 0),
      .INT_RS_DEPTH(SINGLE_CORE_PERFORMANCE ? 16 : riscv_pkg::IntRsDepth),
      // The transceiver's TX and RX clocks are independent, so the NIC has no
      // raw loopback; its self-test loopback is the transceiver's PMA
      // loopback (PHY_CTRL PMA_LOOPBACK).
      .RAW_LOOPBACK(0)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(mmcm_locked & mem_ok_synced & ddr_init_done),
      .o_uart_tx,
      .i_uart_rx,
      .o_ddr_axi_awvalid(ddr_axi_awvalid),
      .i_ddr_axi_awready(ddr_axi_awready),
      .o_ddr_axi_awid(ddr_axi_awid),
      .o_ddr_axi_awaddr(ddr_axi_awaddr),
      .o_ddr_axi_awlen(ddr_axi_awlen),
      .o_ddr_axi_awsize(ddr_axi_awsize),
      .o_ddr_axi_awburst(ddr_axi_awburst),
      .o_ddr_axi_wvalid(ddr_axi_wvalid),
      .i_ddr_axi_wready(ddr_axi_wready),
      .o_ddr_axi_wdata(ddr_axi_wdata),
      .o_ddr_axi_wstrb(ddr_axi_wstrb),
      .o_ddr_axi_wlast(ddr_axi_wlast),
      .i_ddr_axi_bvalid(ddr_axi_bvalid),
      .o_ddr_axi_bready(ddr_axi_bready),
      .i_ddr_axi_bid(ddr_axi_bid),
      .i_ddr_axi_bresp(ddr_axi_bresp),
      .o_ddr_axi_arvalid(ddr_axi_arvalid),
      .i_ddr_axi_arready(ddr_axi_arready),
      .o_ddr_axi_arid(ddr_axi_arid),
      .o_ddr_axi_araddr(ddr_axi_araddr),
      .o_ddr_axi_arlen(ddr_axi_arlen),
      .o_ddr_axi_arsize(ddr_axi_arsize),
      .o_ddr_axi_arburst(ddr_axi_arburst),
      .i_ddr_axi_rvalid(ddr_axi_rvalid),
      .o_ddr_axi_rready(ddr_axi_rready),
      .i_ddr_axi_rid(ddr_axi_rid),
      .i_ddr_axi_rdata(ddr_axi_rdata),
      .i_ddr_axi_rresp(ddr_axi_rresp),
      .i_ddr_axi_rlast(ddr_axi_rlast),
      // NIC: the MAC clocks, raw words and PHY lines of the transceiver above;
      // the PCS block lock goes back to its supervisor.
      .i_nic_tx_clk(nic_tx_clk),
      .i_nic_rx_clk(nic_rx_clk),
      .i_nic_tx_clk_ok(nic_tx_clk_ok),
      .i_nic_rx_clk_ok(nic_rx_clk_ok),
      .o_nic_tx_raw_data(nic_tx_raw_data),
      .o_nic_tx_raw_valid(nic_tx_raw_valid),
      .i_nic_rx_raw_data(nic_rx_raw_data),
      .i_nic_rx_raw_valid(nic_rx_raw_valid),
      .i_nic_rx_signal_ok(nic_rx_signal_ok),
      .i_nic_phy_status(nic_phy_status),
      .o_nic_phy_ctrl(nic_phy_ctrl),
      .o_nic_rx_block_lock(nic_rx_block_lock)
  );

endmodule : x3_frost
