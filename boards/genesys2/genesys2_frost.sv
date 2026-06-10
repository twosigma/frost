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
// Handles Kintex-7 specific clock generation and instantiates common subsystem
module genesys2_frost (
    input logic i_sysclk_n,  // Differential system clock negative
    input logic i_sysclk_p,  // Differential system clock positive (200 MHz)

    input logic i_pb_resetn,  // Push-button reset (active-low)

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx,  // UART receive for debug console input

    output logic o_fan_pwm  // Fan PWM control output
);

  // Clock generation using Xilinx MMCM primitive
  logic main_clock, divided_clock_by_4;
  logic mmcm_locked;
  logic differential_clock_200mhz_buffered, clock_feedback, clock_from_mmcm, clock_div4_from_mmcm;

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
      .CLKOUT1_DIVIDE  (24)
  ) mixed_mode_clock_manager (
      .CLKIN1  (differential_clock_200mhz_buffered),
      .CLKFBIN (clock_feedback),
      .CLKFBOUT(clock_feedback),
      .CLKOUT0 (clock_from_mmcm),
      .CLKOUT1 (clock_div4_from_mmcm),
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

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
  // Clock: 200MHz * 4 / 6 = 133.33 MHz
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(133333333),
      // Genesys2 = Kintex-7: no UltraRAM, so omit the URAM tier.
      .ENABLE_URAM_TIER(0)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(i_pb_resetn & mmcm_locked),
      .o_uart_tx,
      .i_uart_rx
  );

  // Disable fan PWM - not needed for this small design (prevents loud fan noise)
  assign o_fan_pwm = 1'b0;

endmodule : genesys2_frost
