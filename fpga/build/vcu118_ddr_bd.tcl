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

# VCU118 (XCVU9P, UltraScale+) DDR4 subsystem block design.
# Connects the 512-bit AXI master to the onboard Micron MT40A256M16GE-083E
# component memory via AXI SmartConnect.

proc create_vcu118_ddr_bd {} {
  create_bd_design "ddr_subsys"

  if {[info exists ::env(FROST_CPU_CLK_DIV)] && $::env(FROST_CPU_CLK_DIV) ni {"" 1}} {
    error "VCU118 uses a fixed CPU clock; FROST_CPU_CLK_DIV must be 1"
  }
  set cpu_clk_hz 200000000
  set cpu_clk [create_bd_port -dir I -type clk -freq_hz $cpu_clk_hz cpu_clk]
  set jtag_clk [create_bd_port -dir I -type clk -freq_hz [expr {$cpu_clk_hz / 4}] jtag_clk]

  set sys_reset [create_bd_port -dir I -type rst sys_reset]
  set_property CONFIG.POLARITY ACTIVE_HIGH $sys_reset
  set cpu_aresetn [create_bd_port -dir I -type rst cpu_aresetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $cpu_aresetn
  set jtag_aresetn [create_bd_port -dir I -type rst jtag_aresetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $jtag_aresetn
  create_bd_port -dir O mem_ok

  # 512-bit CPU bridge port
  set s00 [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S00_AXI]
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {31} \
    CONFIG.DATA_WIDTH {512} \
    CONFIG.ID_WIDTH {5} \
    CONFIG.HAS_BURST {1} \
    CONFIG.HAS_CACHE {0} \
    CONFIG.HAS_LOCK {0} \
    CONFIG.HAS_PROT {0} \
    CONFIG.HAS_QOS {0} \
    CONFIG.HAS_REGION {0} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.MAX_BURST_LENGTH {1} \
  ] $s00

  set_property CONFIG.ASSOCIATED_BUSIF {S00_AXI} [get_bd_ports cpu_clk]

  # Dedicated DDR reference clock (Bank 71: E12/D12 in SLR2)
  set sys_clk [create_bd_intf_port -mode Slave \
      -vlnv xilinx.com:interface:diff_clock_rtl:1.0 default_250mhz_clk]
  set_property CONFIG.FREQ_HZ {250000000} $sys_clk

  # DDR4 Controller targeting VCU118 Component Memory
  set ddr4 [create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_0]
  set_property -dict [list \
    CONFIG.C0_CLOCK_BOARD_INTERFACE {Custom} \
    CONFIG.C0_DDR4_BOARD_INTERFACE {Custom} \
    CONFIG.C0.DDR4_MemoryPart {MT40A256M16GE-083E} \
    CONFIG.C0.DDR4_MemoryType {Components} \
    CONFIG.C0.DDR4_DataWidth {72} \
    CONFIG.C0.DDR4_AxiDataWidth {512} \
    CONFIG.C0.DDR4_AxiAddressWidth {31} \
    CONFIG.C0.DDR4_AxiIDWidth {5} \
    CONFIG.C0.DDR4_TimePeriod {833} \
    CONFIG.C0.DDR4_InputClockPeriod {4000} \
  ] $ddr4

  # JTAG AXI master for loading
  set jtag_ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_ddr]
  set_property CONFIG.PROTOCOL {0} $jtag_ddr

  # Reset inverter
  set rst_inv [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 rst_inv]
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $rst_inv

  # SmartConnect
  set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ddr_smc]
  set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_CLKS {3} \
  ] $smc

  connect_bd_intf_net [get_bd_intf_ports S00_AXI] [get_bd_intf_pins ddr_smc/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins jtag_axi_ddr/M_AXI] [get_bd_intf_pins ddr_smc/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins ddr_smc/M00_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]
  connect_bd_intf_net [get_bd_intf_pins ddr_smc/M01_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]
  connect_bd_intf_net [get_bd_intf_ports default_250mhz_clk] [get_bd_intf_pins ddr4_0/C0_SYS_CLK]

  set ddr4_sdram [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 ddr4_sdram_c0]
  connect_bd_intf_net [get_bd_intf_pins ddr4_0/C0_DDR4] $ddr4_sdram

  connect_bd_net [get_bd_ports cpu_clk] [get_bd_pins ddr_smc/aclk]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] [get_bd_pins ddr_smc/aclk1]
  connect_bd_net [get_bd_ports jtag_clk] [get_bd_pins ddr_smc/aclk2] [get_bd_pins jtag_axi_ddr/aclk]

  connect_bd_net [get_bd_ports sys_reset] [get_bd_pins ddr4_0/sys_rst]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_inv/Op1]
  connect_bd_net [get_bd_pins rst_inv/Res] [get_bd_pins ddr4_0/c0_ddr4_aresetn]
  connect_bd_net [get_bd_pins ddr4_0/c0_init_calib_complete] [get_bd_ports mem_ok]
  connect_bd_net [get_bd_ports cpu_aresetn] [get_bd_pins ddr_smc/aresetn]
  connect_bd_net [get_bd_ports jtag_aresetn] [get_bd_pins jtag_axi_ddr/aresetn]

  assign_bd_address -offset 0x00000000 -range 0x80000000 \
      -target_address_space [get_bd_addr_spaces S00_AXI] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] -force
  assign_bd_address -offset 0x00000000 -range 0x80000000 \
      -target_address_space [get_bd_addr_spaces jtag_axi_ddr/Data] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] -force
  assign_bd_address -offset 0x80000000 -range 0x00008000 \
      -target_address_space [get_bd_addr_spaces jtag_axi_ddr/Data] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP_CTRL/C0_REG] -force
  exclude_bd_addr_seg -target_address_space [get_bd_addr_spaces S00_AXI] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP_CTRL/C0_REG]

  validate_bd_design
  save_bd_design
}
