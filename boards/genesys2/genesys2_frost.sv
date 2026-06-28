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

// Top-level module for Genesys2 FPGA board integration
// Handles Kintex-7 specific clock generation, the DDR3 memory subsystem
// (ddr_subsys block design: MIG + SmartConnect + JTAG DDR loader), and
// instantiates the common FROST subsystem.
module genesys2_frost (
    input logic i_sysclk_n,  // Differential system clock negative
    input logic i_sysclk_p,  // Differential system clock positive (200 MHz)

    input logic i_pb_resetn,  // Push-button reset (active-low)

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx,  // UART receive for debug console input

    output logic o_fan_pwm,  // Fan PWM control output

    // DDR3 SDRAM (pin LOCs/IOSTANDARDs come from the MIG's mig_a.prj)
    output logic [14:0] ddr3_addr,
    output logic [ 2:0] ddr3_ba,
    output logic        ddr3_cas_n,
    output logic [ 0:0] ddr3_ck_n,
    output logic [ 0:0] ddr3_ck_p,
    output logic [ 0:0] ddr3_cke,
    output logic [ 0:0] ddr3_cs_n,
    output logic [ 3:0] ddr3_dm,
    inout  wire  [31:0] ddr3_dq,
    inout  wire  [ 3:0] ddr3_dqs_n,
    inout  wire  [ 3:0] ddr3_dqs_p,
    output logic [ 0:0] ddr3_odt,
    output logic        ddr3_ras_n,
    output logic        ddr3_reset_n,
    output logic        ddr3_we_n
);

  // Clock generation using Xilinx MMCM primitive
  logic main_clock, divided_clock_by_4, clock_200mhz;
  logic mmcm_locked;
  logic differential_clock_200mhz_buffered, clock_feedback;
  logic clock_from_mmcm, clock_div4_from_mmcm, clock_200_from_mmcm;

  // Convert differential clock input to single-ended
  IBUFDS differential_input_buffer_200mhz (
      .I (i_sysclk_p),
      .IB(i_sysclk_n),
      .O (differential_clock_200mhz_buffered)
  );

  // Mixed-Mode Clock Manager (MMCM) for PLL-based clock generation
  MMCME2_ADV #(
      .CLKIN1_PERIOD   (5.000),  // Input period: 1/200MHz = 5ns
      .DIVCLK_DIVIDE   (1),      // Pre-divider: 200MHz / 1 = 200MHz
      // VCO (Voltage Controlled Oscillator) frequency: 200MHz × 4 = 800 MHz
      .CLKFBOUT_MULT_F (4.0),
      // Output clock 0: 800MHz / 6 = 133.33 MHz for FROST CPU
      .CLKOUT0_DIVIDE_F(6.0),
      // Output clock 1: 800MHz / 24 = 33.33 MHz (div4 for JTAG/UART)
      .CLKOUT1_DIVIDE  (24),
      // Output clock 2: 800MHz / 4 = 200 MHz for the MIG system clock
      // ("No Buffer" + "Use System Clock" in mig_a.prj)
      .CLKOUT2_DIVIDE  (4)
  ) mixed_mode_clock_manager (
      .CLKIN1  (differential_clock_200mhz_buffered),
      .CLKFBIN (clock_feedback),
      .CLKFBOUT(clock_feedback),
      .CLKOUT0 (clock_from_mmcm),
      .CLKOUT1 (clock_div4_from_mmcm),
      .CLKOUT2 (clock_200_from_mmcm),
      .RST     (1'b0),                                // Don't reset MMCM
      .PWRDWN  (1'b0),                                // Don't power down
      .CLKIN2  (1'b0),
      .CLKINSEL(1'b1),                                // Select CLKIN1
      .LOCKED  (mmcm_locked)
  );

  // Global clock buffer for low-skew distribution
  BUFG global_clock_buffer (
      .I(clock_from_mmcm),
      .O(main_clock)
  );

  // Global clock buffer for divided clock (JTAG/UART)
  BUFG divided_clock_buffer (
      .I(clock_div4_from_mmcm),
      .O(divided_clock_by_4)
  );

  // Global clock buffer for the MIG 200 MHz system clock
  BUFG mig_system_clock_buffer (
      .I(clock_200_from_mmcm),
      .O(clock_200mhz)
  );

  // DDR AXI between the FROST cache-hierarchy bridge and the DDR3 subsystem
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
  assign cpu_side_aresetn = i_pb_resetn & mmcm_locked;

  // DDR3 subsystem (block design): MIG (mig_a.prj config) + SmartConnect
  // (S00 = the FROST bridge below, S01 = the JTAG DDR-image loader) +
  // mem_reset_control calibration sequencing. Addresses are region-relative.
  ddr_subsys_wrapper ddr_subsystem (
      .cpu_clk(main_clock),
      .jtag_clk(divided_clock_by_4),
      .clk_200m(clock_200mhz),
      .sys_reset(~i_pb_resetn),
      .pll_locked(mmcm_locked),
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
      .DDR3_addr(ddr3_addr),
      .DDR3_ba(ddr3_ba),
      .DDR3_cas_n(ddr3_cas_n),
      .DDR3_ck_n(ddr3_ck_n),
      .DDR3_ck_p(ddr3_ck_p),
      .DDR3_cke(ddr3_cke),
      .DDR3_cs_n(ddr3_cs_n),
      .DDR3_dm(ddr3_dm),
      .DDR3_dq(ddr3_dq),
      .DDR3_dqs_n(ddr3_dqs_n),
      .DDR3_dqs_p(ddr3_dqs_p),
      .DDR3_odt(ddr3_odt),
      .DDR3_ras_n(ddr3_ras_n),
      .DDR3_reset_n(ddr3_reset_n),
      .DDR3_we_n(ddr3_we_n)
  );

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
  // Clock: 200MHz * 4 / 6 = 133.33 MHz
  // The CPU is additionally held in reset until the DDR3 controller is out of
  // reset and calibrated (mem_ok), so the cached tier is usable from the
  // first instruction.
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(133333333),
      // Genesys2 = Kintex-7: no UltraRAM, so the L1-only hierarchy shape,
      // backed by the DDR3 controller through the AXI port below.
      .ENABLE_CACHED_TIER(1),
      .CACHED_HAS_L2(0),
      .USE_BEHAVIORAL_DDR(0),
      // Bump L1I 16 KiB -> 128 KiB: hold the kernel tick/softirq/scheduler
      // working set to defeat the periodic-tick catch-up livelock (no L2 here).
      .L1I_CACHE_BYTES(128 * 1024)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(i_pb_resetn & mmcm_locked & mem_ok_synced),
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

  // Disable fan PWM - not needed for this small design (prevents loud fan noise)
  assign o_fan_pwm = 1'b0;

endmodule : genesys2_frost
