#    Copyright 2026 Two Sigma Open Source, LLC
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

# X3 (X3522PV, UltraScale+) GTY transceiver for the NIC: one 10GBASE-R channel
# as a raw 64-bit PMA, the PCS being the soft one in hw/rtl/net10g.
#
# Channel GTYE4_CHANNEL_X0Y28 (quad 231, lane 0: TX J7/J6, RX K4/K3, the DSFP28
# cage labelled 2, lane 1), QPLL0 from the quad's MGTREFCLK0 (P9/P8, the
# card's 161.1328125 MHz Ethernet clock), 10.3125 Gb/s, raw encoding with a
# 64-bit user word over a 32-bit internal width (USRCLK 322.27 MHz, USRCLK2
# 161.13 MHz per direction). The TX buffer is on with TXOUTCLK from the TX
# programmable divider; the RX buffer is on with the recovered clock
# (RXOUTCLKPMA) as the RX user clock, which needs no clock correction
# (UG578 Table 4-38). The reset controller, user clocking and width sizing
# helpers and the QPLL are inside the core; the refclk buffer and the
# free-running clock (150 MHz) come from boards/x3/x3_nic_gty.sv. The core's
# own XDC places the channel.
#
# rx_eq_mode selects the receive equalizer: LPM (the default, for an optical
# module on a short host channel) or DFE. The synth step passes
# FROST_GTY_RX_EQ when it is set.
#
# build_step.tcl creates the core before generating and synthesizing its IP;
# x3_nic_gty.sv instantiates it.

proc create_x3_gty_ip {{rx_eq_mode LPM}} {
  if {$rx_eq_mode ni {LPM DFE}} {
    error "GTY RX equalization must be LPM or DFE (got '$rx_eq_mode')"
  }
  create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 \
      -module_name x3_nic_gty_wiz
  set ip [get_ips x3_nic_gty_wiz]

  # The 10GBASE-R preset first, then the raw overrides: the preset's own
  # encoding is the transceiver's asynchronous gearbox.
  set_property CONFIG.GT_TYPE GTY $ip
  set_property CONFIG.PRESET GTY-10GBASE-R $ip
  set_property -dict [list \
      CONFIG.CHANNEL_ENABLE {X0Y28} \
      CONFIG.TX_MASTER_CHANNEL {X0Y28} \
      CONFIG.RX_MASTER_CHANNEL {X0Y28} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_LINE_RATE {10.3125} \
      CONFIG.RX_LINE_RATE {10.3125} \
      CONFIG.TX_PLL_TYPE {QPLL0} \
      CONFIG.RX_PLL_TYPE {QPLL0} \
      CONFIG.TX_REFCLK_FREQUENCY {161.1328125} \
      CONFIG.RX_REFCLK_FREQUENCY {161.1328125} \
  ] $ip
  # MGTREFCLK0 of the quad holding X0Y28 (quad 231).
  set_property -dict [list \
      CONFIG.TX_REFCLK_SOURCE {X0Y28 clk0} \
      CONFIG.RX_REFCLK_SOURCE {X0Y28 clk0} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_DATA_ENCODING {RAW} \
      CONFIG.RX_DATA_DECODING {RAW} \
      CONFIG.TX_USER_DATA_WIDTH {64} \
      CONFIG.RX_USER_DATA_WIDTH {64} \
      CONFIG.TX_INT_DATA_WIDTH {32} \
      CONFIG.RX_INT_DATA_WIDTH {32} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_BUFFER_MODE {1} \
      CONFIG.RX_BUFFER_MODE {1} \
      CONFIG.TX_OUTCLK_SOURCE {TXPROGDIVCLK} \
      CONFIG.RX_OUTCLK_SOURCE {RXOUTCLKPMA} \
      CONFIG.RX_EQ_MODE $rx_eq_mode \
  ] $ip
  # Helpers in the core. Optional ports: the loopback select and the RX PCS
  # reset for the wrapper's supervisor, both polarity inputs (tied to their
  # default), the QPLL0 lock and the raw RX reset done.
  set_property -dict [list \
      CONFIG.LOCATE_COMMON {CORE} \
      CONFIG.LOCATE_RESET_CONTROLLER {CORE} \
      CONFIG.LOCATE_TX_USER_CLOCKING {CORE} \
      CONFIG.LOCATE_RX_USER_CLOCKING {CORE} \
      CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} \
      CONFIG.LOCATE_TX_BUFFER_BYPASS_CONTROLLER {CORE} \
      CONFIG.LOCATE_RX_BUFFER_BYPASS_CONTROLLER {CORE} \
      CONFIG.FREERUN_FREQUENCY {150} \
      CONFIG.ENABLE_OPTIONAL_PORTS {loopback_in rxpcsreset_in rxpolarity_in txpolarity_in qpll0lock_out rxresetdone_out} \
  ] $ip

  # Fail here, not in synthesis, if the wizard refused a value (it keeps the
  # previous legal one and only warns).
  foreach {name expected} [list \
      CHANNEL_ENABLE X0Y28 TX_MASTER_CHANNEL X0Y28 RX_MASTER_CHANNEL X0Y28 \
      TX_REFCLK_SOURCE {X0Y28 clk0} RX_REFCLK_SOURCE {X0Y28 clk0} \
      TX_LINE_RATE 10.3125 RX_LINE_RATE 10.3125 TX_PLL_TYPE QPLL0 RX_PLL_TYPE QPLL0 \
      TX_REFCLK_FREQUENCY 161.1328125 RX_REFCLK_FREQUENCY 161.1328125 \
      TX_DATA_ENCODING RAW RX_DATA_DECODING RAW \
      TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 32 RX_INT_DATA_WIDTH 32 \
      TX_BUFFER_MODE 1 RX_BUFFER_MODE 1 TX_OUTCLK_SOURCE TXPROGDIVCLK RX_OUTCLK_SOURCE RXOUTCLKPMA \
      RX_EQ_MODE $rx_eq_mode FREERUN_FREQUENCY 150] {
    set actual [get_property CONFIG.$name $ip]
    if {$actual ne $expected} {
      error "GTY wizard CONFIG.$name is '$actual', expected '$expected'"
    }
  }
  puts "GTY transceiver core x3_nic_gty_wiz: X0Y28, QPLL0, raw 64/32, RX equalization $rx_eq_mode"
}
