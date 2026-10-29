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

# Copyright (c) 2026 John Goodacre.

# VCU118 networking IP: a raw GTY channel on QSFP1 lane 0 in quad 231,
# and the SGMII PCS/PMA for the bank 64 LVDS interface.

proc create_vcu118_gty_ip {{rx_eq_mode LPM}} {
  if {$rx_eq_mode ni {LPM DFE}} {
    error "GTY RX equalization must be LPM or DFE (got '$rx_eq_mode')"
  }
  create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 \
      -module_name vcu118_nic_gty_wiz
  set ip [get_ips vcu118_nic_gty_wiz]

  set_property CONFIG.GT_TYPE GTY $ip
  set_property CONFIG.PRESET GTY-10GBASE-R $ip
  set_property -dict [list \
      CONFIG.CHANNEL_ENABLE {X1Y48} \
      CONFIG.TX_MASTER_CHANNEL {X1Y48} \
      CONFIG.RX_MASTER_CHANNEL {X1Y48} \
  ] $ip
  set_property -dict [list \
      CONFIG.TX_LINE_RATE {10.3125} \
      CONFIG.RX_LINE_RATE {10.3125} \
      CONFIG.TX_PLL_TYPE {QPLL0} \
      CONFIG.RX_PLL_TYPE {QPLL0} \
      CONFIG.TX_REFCLK_FREQUENCY {156.25} \
      CONFIG.RX_REFCLK_FREQUENCY {156.25} \
  ] $ip
  # MGTREFCLK0 of Quad 231 holding X1Y48 (W9/W8).
  set_property -dict [list \
      CONFIG.TX_REFCLK_SOURCE {X1Y48 clk0} \
      CONFIG.RX_REFCLK_SOURCE {X1Y48 clk0} \
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

  foreach {name expected} [list \
      CHANNEL_ENABLE X1Y48 TX_MASTER_CHANNEL X1Y48 RX_MASTER_CHANNEL X1Y48 \
      TX_REFCLK_SOURCE {X1Y48 clk0} RX_REFCLK_SOURCE {X1Y48 clk0} \
      TX_LINE_RATE 10.3125 RX_LINE_RATE 10.3125 TX_PLL_TYPE QPLL0 RX_PLL_TYPE QPLL0 \
      TX_REFCLK_FREQUENCY 156.25 RX_REFCLK_FREQUENCY 156.25 \
      TX_DATA_ENCODING RAW RX_DATA_DECODING RAW \
      TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 32 RX_INT_DATA_WIDTH 32 \
      TX_BUFFER_MODE 1 RX_BUFFER_MODE 1 TX_OUTCLK_SOURCE TXPROGDIVCLK RX_OUTCLK_SOURCE RXOUTCLKPMA \
      RX_EQ_MODE $rx_eq_mode FREERUN_FREQUENCY 150] {
    set actual [get_property CONFIG.$name $ip]
    if {$actual ne $expected} {
      error "GTY wizard CONFIG.$name is '$actual', expected '$expected'"
    }
  }
  puts "GTY transceiver core vcu118_nic_gty_wiz: X1Y48, QPLL0, raw 64/32, RX equalization $rx_eq_mode"

  create_vcu118_pcs_pma_1g_ip
}

proc create_vcu118_pcs_pma_1g_ip {} {
  create_ip -name gig_ethernet_pcs_pma -vendor xilinx.com -library ip -version 17.0 \
      -module_name vcu118_pcs_pma_1g
  set ip [get_ips vcu118_pcs_pma_1g]

  set_property -dict [list \
      CONFIG.Standard {SGMII} \
      CONFIG.Physical_Interface {LVDS} \
      CONFIG.Management_Interface {false} \
      CONFIG.Auto_Negotiation {true} \
      CONFIG.SGMII_PHY_Mode {false} \
      CONFIG.SupportLevel {Include_Shared_Logic_in_Core} \
      CONFIG.LvdsRefClk {625} \
      CONFIG.Tx_In_Upper_Nibble {0} \
      CONFIG.RxNibbleBitslice0Used {false} \
      CONFIG.TxLane0_Placement {DIFF_PAIR_2} \
      CONFIG.RxLane0_Placement {DIFF_PAIR_0} \
  ] $ip

  foreach {name expected} [list \
      Standard SGMII Physical_Interface LVDS Management_Interface false \
      Auto_Negotiation true SGMII_PHY_Mode false \
      SupportLevel Include_Shared_Logic_in_Core LvdsRefClk 625 \
      Tx_In_Upper_Nibble 0 RxNibbleBitslice0Used false \
      TxLane0_Placement DIFF_PAIR_2 RxLane0_Placement DIFF_PAIR_0] {
    set actual [get_property CONFIG.$name $ip]
    if {$actual ne $expected} {
      error "PCS/PMA 1G CONFIG.$name is '$actual', expected '$expected'"
    }
  }
  puts "1G SGMII LVDS PCS/PMA core vcu118_pcs_pma_1g: Bank 64 lower nibble (TX DIFF_PAIR_2, RX DIFF_PAIR_0)"
}
