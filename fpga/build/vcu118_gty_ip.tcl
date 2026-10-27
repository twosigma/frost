#    Copyright 2026 John Goodacre
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# VCU118 (XCVU9P, UltraScale+) GTY transceiver configuration.
# Provides CPU clock generation from Quad 231 (QSFP1) CPLL in SLR1.

proc create_vcu118_gty_ip {{rx_eq_mode LPM}} {
  create_vcu118_cpu_clock_gty_ip
}

proc create_vcu118_cpu_clock_gty_ip {} {
  create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 \
      -module_name vcu118_cpu_clock_gty_wiz
  set ip [get_ips vcu118_cpu_clock_gty_wiz]
  set_property CONFIG.GT_TYPE GTY $ip
  set_property -dict [list \
      CONFIG.CHANNEL_ENABLE {X1Y48} \
      CONFIG.TX_MASTER_CHANNEL {X1Y48} \
      CONFIG.RX_MASTER_CHANNEL {X1Y48} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_LINE_RATE {5.000} \
      CONFIG.RX_LINE_RATE {5.000} \
      CONFIG.TX_PLL_TYPE {CPLL} \
      CONFIG.RX_PLL_TYPE {CPLL} \
      CONFIG.TX_REFCLK_FREQUENCY {156.25} \
      CONFIG.RX_REFCLK_FREQUENCY {156.25} \
      CONFIG.TX_REFCLK_SOURCE {X1Y48 clk0} \
      CONFIG.RX_REFCLK_SOURCE {X1Y48 clk0} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_DATA_ENCODING {RAW} \
      CONFIG.RX_DATA_DECODING {RAW} \
      CONFIG.TX_USER_DATA_WIDTH {20} \
      CONFIG.RX_USER_DATA_WIDTH {20} \
      CONFIG.TX_INT_DATA_WIDTH {20} \
      CONFIG.RX_INT_DATA_WIDTH {20} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_BUFFER_MODE {1} \
      CONFIG.RX_BUFFER_MODE {1} \
      CONFIG.TX_OUTCLK_SOURCE {TXPROGDIVCLK} \
      CONFIG.RX_OUTCLK_SOURCE {RXOUTCLKPMA} \
  ] $ip
  set_property -dict [list \
      CONFIG.LOCATE_COMMON {CORE} \
      CONFIG.LOCATE_RESET_CONTROLLER {CORE} \
      CONFIG.LOCATE_TX_USER_CLOCKING {EXAMPLE_DESIGN} \
      CONFIG.LOCATE_RX_USER_CLOCKING {EXAMPLE_DESIGN} \
      CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} \
      CONFIG.FREERUN_FREQUENCY {150} \
      CONFIG.ENABLE_OPTIONAL_PORTS {txelecidle_in cplllock_out} \
  ] $ip

  foreach {name expected} [list \
      CHANNEL_ENABLE X1Y48 TX_MASTER_CHANNEL X1Y48 RX_MASTER_CHANNEL X1Y48 \
      TX_REFCLK_SOURCE {X1Y48 clk0} RX_REFCLK_SOURCE {X1Y48 clk0} \
      TX_LINE_RATE 5.000 RX_LINE_RATE 5.000 TX_PLL_TYPE CPLL RX_PLL_TYPE CPLL \
      TX_REFCLK_FREQUENCY 156.25 RX_REFCLK_FREQUENCY 156.25 \
      TX_DATA_ENCODING RAW RX_DATA_DECODING RAW \
      TX_USER_DATA_WIDTH 20 RX_USER_DATA_WIDTH 20 TX_INT_DATA_WIDTH 20 RX_INT_DATA_WIDTH 20 \
      TX_BUFFER_MODE 1 RX_BUFFER_MODE 1 TX_OUTCLK_SOURCE TXPROGDIVCLK RX_OUTCLK_SOURCE RXOUTCLKPMA \
      LOCATE_TX_USER_CLOCKING EXAMPLE_DESIGN LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN \
      FREERUN_FREQUENCY 150] {
    set actual [get_property CONFIG.$name $ip]
    if {$actual ne $expected} {
      error "GTY wizard CONFIG.$name is '$actual', expected '$expected'"
    }
  }
  puts "GTY transceiver core vcu118_cpu_clock_gty_wiz: X1Y48, CPLL, raw 20/20, TXOUTCLK 250.000 MHz"
}
