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
#
# Physical pin and timing constraints for FROST on AMD/Xilinx VCU118 Evaluation Board
# Target Part: xcvu9p-flga2104-2L-e

# -----------------------------------------------------------------------------
# 1. System Clocks & Reset
# -----------------------------------------------------------------------------
# SYSCLK1_300: 300 MHz differential clock (SI5335A) on G31/F31 in Bank 65 (SLR2)
set_property PACKAGE_PIN G31 [get_ports sysclk1_300_p]
set_property PACKAGE_PIN F31 [get_ports sysclk1_300_n]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sysclk1_300_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sysclk1_300_n]

create_clock -period 3.333 -name sysclk1_300 [get_ports sysclk1_300_p]

# Center the CPU clock distribution buffer in SLR2 to minimize clock skew
set_property USER_CLOCK_ROOT X2Y12 [get_nets -quiet {main_clock divided_clock_by_4}]

# CPU Reset Pushbutton (SW6, active-high, Bank 65 in SLR2)
set_property PACKAGE_PIN L19 [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS12 [get_ports cpu_reset]

# -----------------------------------------------------------------------------
# 2. USB-UART Console (Silicon Labs CP2105 on Bank 64 in SLR2)
# -----------------------------------------------------------------------------
# FPGA TX connects to CP2105 RXD (BB21)
# FPGA RX connects to CP2105 TXD (AW25)
set_property PACKAGE_PIN BB21 [get_ports o_uart_tx]
set_property IOSTANDARD LVCMOS18 [get_ports o_uart_tx]

set_property PACKAGE_PIN AW25 [get_ports i_uart_rx]
set_property IOSTANDARD LVCMOS18 [get_ports i_uart_rx]

# -----------------------------------------------------------------------------
# 3. Status LEDs (GPIO_LED_0 .. GPIO_LED_3 on Bank 68/67 in SLR2)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN AT32 [get_ports {gpio_led[0]}]
set_property PACKAGE_PIN AV34 [get_ports {gpio_led[1]}]
set_property PACKAGE_PIN AY30 [get_ports {gpio_led[2]}]
set_property PACKAGE_PIN BB32 [get_ports {gpio_led[3]}]
set_property IOSTANDARD LVCMOS12 [get_ports {gpio_led[*]}]

# -----------------------------------------------------------------------------
# 4. DDR4 Channel 0 Component Memory (Banks 71-73 in SLR2, 72-bit native ECC)
# -----------------------------------------------------------------------------
# 250 MHz Differential Reference Clock (Bank 71 in SLR2)
set_property PACKAGE_PIN E12 [get_ports default_250mhz_clk_clk_p]
set_property PACKAGE_PIN D12 [get_ports default_250mhz_clk_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports default_250mhz_clk_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports default_250mhz_clk_clk_n]

# Control & Address
set_property PACKAGE_PIN E13 [get_ports ddr4_sdram_c0_act_n]
set_property PACKAGE_PIN D14 [get_ports {ddr4_sdram_c0_adr[0]}]
set_property PACKAGE_PIN B15 [get_ports {ddr4_sdram_c0_adr[1]}]
set_property PACKAGE_PIN B16 [get_ports {ddr4_sdram_c0_adr[2]}]
set_property PACKAGE_PIN C14 [get_ports {ddr4_sdram_c0_adr[3]}]
set_property PACKAGE_PIN C15 [get_ports {ddr4_sdram_c0_adr[4]}]
set_property PACKAGE_PIN A13 [get_ports {ddr4_sdram_c0_adr[5]}]
set_property PACKAGE_PIN A14 [get_ports {ddr4_sdram_c0_adr[6]}]
set_property PACKAGE_PIN A15 [get_ports {ddr4_sdram_c0_adr[7]}]
set_property PACKAGE_PIN A16 [get_ports {ddr4_sdram_c0_adr[8]}]
set_property PACKAGE_PIN B12 [get_ports {ddr4_sdram_c0_adr[9]}]
set_property PACKAGE_PIN C12 [get_ports {ddr4_sdram_c0_adr[10]}]
set_property PACKAGE_PIN B13 [get_ports {ddr4_sdram_c0_adr[11]}]
set_property PACKAGE_PIN C13 [get_ports {ddr4_sdram_c0_adr[12]}]
set_property PACKAGE_PIN D15 [get_ports {ddr4_sdram_c0_adr[13]}]
set_property PACKAGE_PIN H14 [get_ports {ddr4_sdram_c0_adr[14]}]
set_property PACKAGE_PIN H15 [get_ports {ddr4_sdram_c0_adr[15]}]
set_property PACKAGE_PIN F15 [get_ports {ddr4_sdram_c0_adr[16]}]
set_property PACKAGE_PIN G15 [get_ports {ddr4_sdram_c0_ba[0]}]
set_property PACKAGE_PIN G13 [get_ports {ddr4_sdram_c0_ba[1]}]
set_property PACKAGE_PIN H13 [get_ports {ddr4_sdram_c0_bg[0]}]
set_property PACKAGE_PIN F14 [get_ports {ddr4_sdram_c0_ck_t}]
set_property PACKAGE_PIN E14 [get_ports {ddr4_sdram_c0_ck_c}]
set_property PACKAGE_PIN A10 [get_ports {ddr4_sdram_c0_cke}]
set_property PACKAGE_PIN F13 [get_ports {ddr4_sdram_c0_cs_n}]
set_property PACKAGE_PIN C8  [get_ports {ddr4_sdram_c0_odt}]
set_property PACKAGE_PIN N20 [get_ports ddr4_sdram_c0_reset_n]

# Data Mask (DM/DBI)
set_property PACKAGE_PIN G11 [get_ports {ddr4_sdram_c0_dm_n[0]}]
set_property PACKAGE_PIN R18 [get_ports {ddr4_sdram_c0_dm_n[1]}]
set_property PACKAGE_PIN K17 [get_ports {ddr4_sdram_c0_dm_n[2]}]
set_property PACKAGE_PIN G18 [get_ports {ddr4_sdram_c0_dm_n[3]}]
set_property PACKAGE_PIN B18 [get_ports {ddr4_sdram_c0_dm_n[4]}]
set_property PACKAGE_PIN P20 [get_ports {ddr4_sdram_c0_dm_n[5]}]
set_property PACKAGE_PIN L23 [get_ports {ddr4_sdram_c0_dm_n[6]}]
set_property PACKAGE_PIN G22 [get_ports {ddr4_sdram_c0_dm_n[7]}]
set_property PACKAGE_PIN E24 [get_ports {ddr4_sdram_c0_dm_n[8]}]

# Differential Strobes (DQS)
set_property PACKAGE_PIN D11 [get_ports {ddr4_sdram_c0_dqs_t[0]}]
set_property PACKAGE_PIN D10 [get_ports {ddr4_sdram_c0_dqs_c[0]}]
set_property PACKAGE_PIN P17 [get_ports {ddr4_sdram_c0_dqs_t[1]}]
set_property PACKAGE_PIN P16 [get_ports {ddr4_sdram_c0_dqs_c[1]}]
set_property PACKAGE_PIN K19 [get_ports {ddr4_sdram_c0_dqs_t[2]}]
set_property PACKAGE_PIN J19 [get_ports {ddr4_sdram_c0_dqs_c[2]}]
set_property PACKAGE_PIN F16 [get_ports {ddr4_sdram_c0_dqs_t[3]}]
set_property PACKAGE_PIN E16 [get_ports {ddr4_sdram_c0_dqs_c[3]}]
set_property PACKAGE_PIN A19 [get_ports {ddr4_sdram_c0_dqs_t[4]}]
set_property PACKAGE_PIN A18 [get_ports {ddr4_sdram_c0_dqs_c[4]}]
set_property PACKAGE_PIN N22 [get_ports {ddr4_sdram_c0_dqs_t[5]}]
set_property PACKAGE_PIN M22 [get_ports {ddr4_sdram_c0_dqs_c[5]}]
set_property PACKAGE_PIN M20 [get_ports {ddr4_sdram_c0_dqs_t[6]}]
set_property PACKAGE_PIN L20 [get_ports {ddr4_sdram_c0_dqs_c[6]}]
set_property PACKAGE_PIN H24 [get_ports {ddr4_sdram_c0_dqs_t[7]}]
set_property PACKAGE_PIN G23 [get_ports {ddr4_sdram_c0_dqs_c[7]}]
set_property PACKAGE_PIN D22 [get_ports {ddr4_sdram_c0_dqs_t[8]}]
set_property PACKAGE_PIN C22 [get_ports {ddr4_sdram_c0_dqs_c[8]}]

# Data Bits (DQ[71:0])
set_property PACKAGE_PIN F11  [get_ports {ddr4_sdram_c0_dq[0]}]
set_property PACKAGE_PIN E11  [get_ports {ddr4_sdram_c0_dq[1]}]
set_property PACKAGE_PIN F10  [get_ports {ddr4_sdram_c0_dq[2]}]
set_property PACKAGE_PIN F9   [get_ports {ddr4_sdram_c0_dq[3]}]
set_property PACKAGE_PIN H12  [get_ports {ddr4_sdram_c0_dq[4]}]
set_property PACKAGE_PIN G12  [get_ports {ddr4_sdram_c0_dq[5]}]
set_property PACKAGE_PIN E9   [get_ports {ddr4_sdram_c0_dq[6]}]
set_property PACKAGE_PIN D9   [get_ports {ddr4_sdram_c0_dq[7]}]
set_property PACKAGE_PIN R19  [get_ports {ddr4_sdram_c0_dq[8]}]
set_property PACKAGE_PIN P19  [get_ports {ddr4_sdram_c0_dq[9]}]
set_property PACKAGE_PIN M18  [get_ports {ddr4_sdram_c0_dq[10]}]
set_property PACKAGE_PIN M17  [get_ports {ddr4_sdram_c0_dq[11]}]
set_property PACKAGE_PIN N19  [get_ports {ddr4_sdram_c0_dq[12]}]
set_property PACKAGE_PIN N18  [get_ports {ddr4_sdram_c0_dq[13]}]
set_property PACKAGE_PIN N17  [get_ports {ddr4_sdram_c0_dq[14]}]
set_property PACKAGE_PIN M16  [get_ports {ddr4_sdram_c0_dq[15]}]
set_property PACKAGE_PIN L16  [get_ports {ddr4_sdram_c0_dq[16]}]
set_property PACKAGE_PIN K16  [get_ports {ddr4_sdram_c0_dq[17]}]
set_property PACKAGE_PIN L18  [get_ports {ddr4_sdram_c0_dq[18]}]
set_property PACKAGE_PIN K18  [get_ports {ddr4_sdram_c0_dq[19]}]
set_property PACKAGE_PIN J17  [get_ports {ddr4_sdram_c0_dq[20]}]
set_property PACKAGE_PIN H17  [get_ports {ddr4_sdram_c0_dq[21]}]
set_property PACKAGE_PIN H19  [get_ports {ddr4_sdram_c0_dq[22]}]
set_property PACKAGE_PIN H18  [get_ports {ddr4_sdram_c0_dq[23]}]
set_property PACKAGE_PIN F19  [get_ports {ddr4_sdram_c0_dq[24]}]
set_property PACKAGE_PIN F18  [get_ports {ddr4_sdram_c0_dq[25]}]
set_property PACKAGE_PIN E19  [get_ports {ddr4_sdram_c0_dq[26]}]
set_property PACKAGE_PIN E18  [get_ports {ddr4_sdram_c0_dq[27]}]
set_property PACKAGE_PIN G20  [get_ports {ddr4_sdram_c0_dq[28]}]
set_property PACKAGE_PIN F20  [get_ports {ddr4_sdram_c0_dq[29]}]
set_property PACKAGE_PIN E17  [get_ports {ddr4_sdram_c0_dq[30]}]
set_property PACKAGE_PIN D16  [get_ports {ddr4_sdram_c0_dq[31]}]
set_property PACKAGE_PIN D17  [get_ports {ddr4_sdram_c0_dq[32]}]
set_property PACKAGE_PIN C17  [get_ports {ddr4_sdram_c0_dq[33]}]
set_property PACKAGE_PIN C19  [get_ports {ddr4_sdram_c0_dq[34]}]
set_property PACKAGE_PIN C18  [get_ports {ddr4_sdram_c0_dq[35]}]
set_property PACKAGE_PIN D20  [get_ports {ddr4_sdram_c0_dq[36]}]
set_property PACKAGE_PIN D19  [get_ports {ddr4_sdram_c0_dq[37]}]
set_property PACKAGE_PIN C20  [get_ports {ddr4_sdram_c0_dq[38]}]
set_property PACKAGE_PIN B20  [get_ports {ddr4_sdram_c0_dq[39]}]
set_property PACKAGE_PIN N23  [get_ports {ddr4_sdram_c0_dq[40]}]
set_property PACKAGE_PIN M23  [get_ports {ddr4_sdram_c0_dq[41]}]
set_property PACKAGE_PIN R21  [get_ports {ddr4_sdram_c0_dq[42]}]
set_property PACKAGE_PIN P21  [get_ports {ddr4_sdram_c0_dq[43]}]
set_property PACKAGE_PIN R22  [get_ports {ddr4_sdram_c0_dq[44]}]
set_property PACKAGE_PIN P22  [get_ports {ddr4_sdram_c0_dq[45]}]
set_property PACKAGE_PIN T23  [get_ports {ddr4_sdram_c0_dq[46]}]
set_property PACKAGE_PIN R23  [get_ports {ddr4_sdram_c0_dq[47]}]
set_property PACKAGE_PIN K24  [get_ports {ddr4_sdram_c0_dq[48]}]
set_property PACKAGE_PIN J24  [get_ports {ddr4_sdram_c0_dq[49]}]
set_property PACKAGE_PIN M21  [get_ports {ddr4_sdram_c0_dq[50]}]
set_property PACKAGE_PIN L21  [get_ports {ddr4_sdram_c0_dq[51]}]
set_property PACKAGE_PIN K21  [get_ports {ddr4_sdram_c0_dq[52]}]
set_property PACKAGE_PIN J21  [get_ports {ddr4_sdram_c0_dq[53]}]
set_property PACKAGE_PIN K22  [get_ports {ddr4_sdram_c0_dq[54]}]
set_property PACKAGE_PIN J22  [get_ports {ddr4_sdram_c0_dq[55]}]
set_property PACKAGE_PIN H23  [get_ports {ddr4_sdram_c0_dq[56]}]
set_property PACKAGE_PIN H22  [get_ports {ddr4_sdram_c0_dq[57]}]
set_property PACKAGE_PIN E23  [get_ports {ddr4_sdram_c0_dq[58]}]
set_property PACKAGE_PIN E22  [get_ports {ddr4_sdram_c0_dq[59]}]
set_property PACKAGE_PIN F21  [get_ports {ddr4_sdram_c0_dq[60]}]
set_property PACKAGE_PIN E21  [get_ports {ddr4_sdram_c0_dq[61]}]
set_property PACKAGE_PIN F24  [get_ports {ddr4_sdram_c0_dq[62]}]
set_property PACKAGE_PIN F23  [get_ports {ddr4_sdram_c0_dq[63]}]
set_property PACKAGE_PIN A24  [get_ports {ddr4_sdram_c0_dq[64]}]
set_property PACKAGE_PIN A23  [get_ports {ddr4_sdram_c0_dq[65]}]
set_property PACKAGE_PIN C24  [get_ports {ddr4_sdram_c0_dq[66]}]
set_property PACKAGE_PIN C23  [get_ports {ddr4_sdram_c0_dq[67]}]
set_property PACKAGE_PIN B23  [get_ports {ddr4_sdram_c0_dq[68]}]
set_property PACKAGE_PIN B22  [get_ports {ddr4_sdram_c0_dq[69]}]
set_property PACKAGE_PIN B21  [get_ports {ddr4_sdram_c0_dq[70]}]
set_property PACKAGE_PIN A21  [get_ports {ddr4_sdram_c0_dq[71]}]

# -----------------------------------------------------------------------------
# 5. 10G QSFP1 Lane 0 GTY Transceiver (Quad 231, X1Y48) & Cage Control (Bank 64)
# -----------------------------------------------------------------------------
# 156.25 MHz Si570 (U38) MGTREFCLK0 of Quad 231
set_property PACKAGE_PIN W9  [get_ports i_qsfp1_refclk_p]
set_property PACKAGE_PIN W8  [get_ports i_qsfp1_refclk_n]
create_clock -period 6.400 -name qsfp1_gty_refclk [get_ports i_qsfp1_refclk_p]

# QSFP1 Channel 0 (GTYE4_CHANNEL_X1Y48)
set_property PACKAGE_PIN V7  [get_ports o_qsfp1_tx_p]
set_property PACKAGE_PIN V6  [get_ports o_qsfp1_tx_n]
set_property PACKAGE_PIN Y2  [get_ports i_qsfp1_rx_p]
set_property PACKAGE_PIN Y1  [get_ports i_qsfp1_rx_n]

# QSFP1 Sideband Control Signals (Bank 64, 1.8V LVCMOS18)
set_property PACKAGE_PIN AM21 [get_ports o_qsfp1_modsell]
set_property PACKAGE_PIN BA22 [get_ports o_qsfp1_resetl]
set_property PACKAGE_PIN AN21 [get_ports o_qsfp1_lpmode]
set_property PACKAGE_PIN AL21 [get_ports i_qsfp1_modprsl]
set_property IOSTANDARD LVCMOS18 [get_ports {o_qsfp1_modsell o_qsfp1_resetl o_qsfp1_lpmode i_qsfp1_modprsl}]
set_property PULLUP true [get_ports i_qsfp1_modprsl]

# -----------------------------------------------------------------------------
# 6. 1G RJ-45 SGMII-over-LVDS & TI DP83867ISRGZ PHY Management (Bank 64)
# -----------------------------------------------------------------------------
# 625 MHz Differential SGMII Clock from TI DP83867 (U3)
set_property PACKAGE_PIN AT22 [get_ports i_sgmii_clk_p]
set_property PACKAGE_PIN AU22 [get_ports i_sgmii_clk_n]
set_property IOSTANDARD LVDS [get_ports {i_sgmii_clk_p i_sgmii_clk_n}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {i_sgmii_clk_p i_sgmii_clk_n}]
if {[llength [get_clocks -quiet -of_objects [get_ports i_sgmii_clk_p]]] == 0} {
    create_clock -period 1.600 -name sgmii_clk625 [get_ports i_sgmii_clk_p]
}

# SGMII Differential RX (DIFF_PAIR_0 in Bank 64 Lower Nibble)
set_property PACKAGE_PIN AU24 [get_ports i_sgmii_rx_p]
set_property PACKAGE_PIN AV24 [get_ports i_sgmii_rx_n]
set_property IOSTANDARD LVDS [get_ports {i_sgmii_rx_p i_sgmii_rx_n}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {i_sgmii_rx_p i_sgmii_rx_n}]

# SGMII Differential TX (DIFF_PAIR_2 in Bank 64 Lower Nibble)
set_property PACKAGE_PIN AU21 [get_ports o_sgmii_tx_p]
set_property PACKAGE_PIN AV21 [get_ports o_sgmii_tx_n]
set_property IOSTANDARD LVDS [get_ports {o_sgmii_tx_p o_sgmii_tx_n}]

# TI DP83867 Hardware Reset & Clause-22 MDIO (Bank 64, 1.8V LVCMOS18)
set_property PACKAGE_PIN BA21 [get_ports o_phy_rst_n]
set_property PACKAGE_PIN AV23 [get_ports o_phy_mdc]
set_property PACKAGE_PIN AR23 [get_ports io_phy_mdio]
set_property IOSTANDARD LVCMOS18 [get_ports {o_phy_rst_n o_phy_mdc io_phy_mdio}]
set_property PULLUP true [get_ports io_phy_mdio]

# -----------------------------------------------------------------------------
# 7. Bitstream Configuration Properties
# -----------------------------------------------------------------------------
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# -----------------------------------------------------------------------------
# 8. Timing Optimizations (BRAM Cascade Height)
# -----------------------------------------------------------------------------
# Limit BRAM cascade depth to 1 to avoid multi-cycle deep RAMB36E2 cascades
# in the low-BRAM tier that constrain core clock paths.
set_property CASCADE_HEIGHT 1 [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]

# -----------------------------------------------------------------------------
# 9. Asynchronous Clock Domain Crossings
# -----------------------------------------------------------------------------
# Cut paths between independent clock trees (CPU/div4 MMCM, 150 MHz freerun,
# DDR4 250 MHz, 10G QSFP1 GTY 156.25 MHz, and 1G SGMII 625 MHz)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks -of_objects [get_pins -quiet u_clock_gen/u_mmcm/CLKOUT*]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_pins -quiet u_clock_gen/u_bufg_freerun_150/O]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports default_250mhz_clk_clk_p]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports i_qsfp1_refclk_p]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports i_sgmii_clk_p]]

# Explicit CDC synchronizer and reset-synchronizer false paths (covers TXUSRCLK2 <-> RXUSRCLK2 as well)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ "*mem_ok_synchronizer_reg[0]/D"}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ "*/stage_q_reg[0]*/D"}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ "*/chain_q_reg*/PRE"}]

# -----------------------------------------------------------------------------
# 10. Floorplanning: Pure Single-SLR Assignment (100% in SLR2)
# -----------------------------------------------------------------------------
# Confine the entire FROST system (CPU core, caches, BRAM, UART, MMCM, DDR4
# memory subsystem, and initialization engine) to SLR2.
# SLR2 has 394k LUTs. The full design requires ~175k LUTs (~44% of SLR2).
# Co-locating all components in SLR2 routes all paths via local intra-die
# interconnect, maintaining maximum timing margin and Fmax.
if {[get_pblocks -quiet pblock_slr2] eq ""} {
    create_pblock pblock_slr2
}
resize_pblock pblock_slr2 -add {SLR2}
add_cells_to_pblock [get_pblocks pblock_slr2] [get_cells -quiet {u_frost_subsystem u_clock_gen gen_real_ddr.ddr_subsystem u_ddr_init}]
