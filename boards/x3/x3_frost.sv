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

// Top-level module for X3 FPGA board (UltraScale+) integration
// Handles UltraScale+ specific clock generation, the DDR4 memory subsystem
// (ddr_subsys block design: DDR4 controller + SmartConnect + JTAG DDR
// loader), and instantiates the common FROST subsystem.
module x3_frost (
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
    output logic        ddr4_sdram_c0_reset_n
);

  // Clock generation using Xilinx MMCM and clock dividers
  logic main_clock, divided_clock_by_4;
  logic mmcm_locked;
  logic differential_clock_300mhz_buffered, clock_feedback, clock_from_mmcm;

  // Convert differential clock input to single-ended
  IBUFDS differential_input_buffer_300mhz (
      .I (i_sysclk_p),
      .IB(i_sysclk_n),
      .O (differential_clock_300mhz_buffered)
  );

  // Mixed-Mode Clock Manager (MMCM) for PLL-based clock generation
  // NOTE: Currently targeting 300 MHz for timing closure. May revisit 322 MHz in the future.
  // Original 322.265625 MHz configuration (preserved for reference):
  //   .DIVCLK_DIVIDE   (8),       // Pre-divider: 300MHz / 8 = 37.5MHz
  //   .CLKFBOUT_MULT_F (34.375),  // VCO: 37.5MHz × 34.375 = 1289.0625 MHz
  //   .CLKOUT0_DIVIDE_F(4.0)      // Output: 1289.0625MHz / 4 = 322.265625 MHz
  MMCME2_ADV #(
      .CLKIN1_PERIOD   (3.333),  // Input period: 1/300MHz = 3.333ns
      .DIVCLK_DIVIDE   (1),      // Pre-divider: 300MHz / 1 = 300MHz
      // VCO frequency: 300MHz × 4 = 1200 MHz
      .CLKFBOUT_MULT_F (4.0),
      // Output clock: 1200MHz / 4 = 300 MHz for FROST CPU
      .CLKOUT0_DIVIDE_F(4.0)
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

  // Global clock buffer with optional divide (divide by 1 = no division)
  // BUFGCE_DIV is UltraScale+ specific
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

  // Global clock buffer with divide-by-4 for JTAG/UART operations
  // BUFGCE_DIV is UltraScale+ specific
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

  logic mem_ok;
  // mem_ok originates in the DDR controller's ui_clk domain: synchronize it
  // into the core clock domain before folding it into the reset tree (the
  // raw reset fans combinationally into both board clock domains). The
  // crossing into this synchronizer is cut with a false_path in the xdc.
  (* ASYNC_REG = "TRUE" *) logic [1:0] mem_ok_synchronizer;
  always_ff @(posedge main_clock) begin
    mem_ok_synchronizer <= {mem_ok_synchronizer[0], mem_ok};
  end
  logic mem_ok_synced;
  assign mem_ok_synced = mem_ok_synchronizer[1];

  logic cpu_side_aresetn;
  assign cpu_side_aresetn = mmcm_locked;

  // DDR4 subsystem (block design): controller (reference CONFIG) +
  // SmartConnect (S00 = the FROST bridge below, S01 = the JTAG DDR-image
  // loader). Addresses are region-relative. The X3 has no push-button;
  // the controller is held in reset until the board MMCM locks.
  ddr_subsys_wrapper ddr_subsystem (
      .cpu_clk(main_clock),
      .jtag_clk(divided_clock_by_4),
      .default_300mhz_clk0_clk_p(default_300mhz_clk0_clk_p),
      .default_300mhz_clk0_clk_n(default_300mhz_clk0_clk_n),
      .sys_reset(~mmcm_locked),
      .cpu_aresetn(cpu_side_aresetn),
      .jtag_aresetn(cpu_side_aresetn),
      .mem_ok(mem_ok),
      .S00_AXI_awvalid(ddr_axi_awvalid),
      .S00_AXI_awready(ddr_axi_awready),
      .S00_AXI_awaddr(ddr_axi_awaddr[29:0]),
      .S00_AXI_awlen(ddr_axi_awlen),
      .S00_AXI_awsize(ddr_axi_awsize),
      .S00_AXI_awburst(ddr_axi_awburst),
      .S00_AXI_wvalid(ddr_axi_wvalid),
      .S00_AXI_wready(ddr_axi_wready),
      .S00_AXI_wdata(ddr_axi_wdata),
      .S00_AXI_wstrb(ddr_axi_wstrb),
      .S00_AXI_wlast(ddr_axi_wlast),
      .S00_AXI_bvalid(ddr_axi_bvalid),
      .S00_AXI_bready(ddr_axi_bready),
      .S00_AXI_bresp(ddr_axi_bresp),
      .S00_AXI_arvalid(ddr_axi_arvalid),
      .S00_AXI_arready(ddr_axi_arready),
      .S00_AXI_araddr(ddr_axi_araddr[29:0]),
      .S00_AXI_arlen(ddr_axi_arlen),
      .S00_AXI_arsize(ddr_axi_arsize),
      .S00_AXI_arburst(ddr_axi_arburst),
      .S00_AXI_rvalid(ddr_axi_rvalid),
      .S00_AXI_rready(ddr_axi_rready),
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

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
  // Clock: 300 MHz (reduced from 322.265625 MHz for timing closure)
  // X3 has no push-button reset; hold the subsystem in reset until the MMCM
  // is locked AND the DDR4 controller is calibrated (mem_ok), so the cached
  // tier is usable from the first instruction.
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(300000000),
      // X3 = UltraScale+: L1 BRAM + L2 URAM hierarchy shape, backed by the
      // DDR4 controller through the AXI port below.
      .ENABLE_CACHED_TIER(1),
      .CACHED_HAS_L2(1),
      .USE_BEHAVIORAL_DDR(0)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(mmcm_locked & mem_ok_synced),
      .o_uart_tx,
      .i_uart_rx,
      .o_ddr_axi_awvalid(ddr_axi_awvalid),
      .i_ddr_axi_awready(ddr_axi_awready),
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
      .i_ddr_axi_bresp(ddr_axi_bresp),
      .o_ddr_axi_arvalid(ddr_axi_arvalid),
      .i_ddr_axi_arready(ddr_axi_arready),
      .o_ddr_axi_araddr(ddr_axi_araddr),
      .o_ddr_axi_arlen(ddr_axi_arlen),
      .o_ddr_axi_arsize(ddr_axi_arsize),
      .o_ddr_axi_arburst(ddr_axi_arburst),
      .i_ddr_axi_rvalid(ddr_axi_rvalid),
      .o_ddr_axi_rready(ddr_axi_rready),
      .i_ddr_axi_rdata(ddr_axi_rdata),
      .i_ddr_axi_rresp(ddr_axi_rresp),
      .i_ddr_axi_rlast(ddr_axi_rlast)
  );

endmodule : x3_frost
