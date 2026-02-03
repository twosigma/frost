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
// Handles UltraScale+ specific clock generation and instantiates common subsystem
module x3_frost (
    input logic i_sysclk_n,  // Differential system clock negative
    input logic i_sysclk_p,  // Differential system clock positive (300 MHz)

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx   // UART receive for debug console input
);

  // Clock generation using Xilinx MMCM and clock dividers
  logic main_clock, divided_clock_by_4;
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
      .LOCKED  (  /*not connected*/)
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

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
  // Clock: 300 MHz (reduced from 322.265625 MHz for timing closure)
  // X3 has no push-button reset, so always keep reset deasserted
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(300000000)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(1'b1),  // No external reset on X3
      .o_uart_tx,
      .i_uart_rx
  );

endmodule : x3_frost
