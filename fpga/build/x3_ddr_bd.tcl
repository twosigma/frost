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

# X3 (X3522PV, UltraScale+) DDR4 subsystem block design.
#
# DDR4 uses the card's MT40A1G16RC-062E memory, a dedicated 300 MHz AN27/AN28
# clock, 72 physical bits, and 512-bit AXI. The proven 72-bit ECC configuration
# requires S_AXI_CTRL, exposed only to JTAG at region offset 0x4000_0000.
# ui_clk_sync_rst drives inverted c0_ddr4_aresetn; calibration drives mem_ok.
# The external CPU bridge is 256-bit at core clock; JTAG loads DDR images.
# boards/x3/constr/x3.xdc constrains matching external interface names.
#
# build_step.tcl creates the design; x3_frost.sv instantiates its wrapper.

proc create_x3_ddr_bd {} {
  create_bd_design "ddr_subsys"

  # CPU and JTAG/div4 clocks; DDR4 has a dedicated 300 MHz input below.
  set cpu_clk [create_bd_port -dir I -type clk -freq_hz 300000000 cpu_clk]
  set jtag_clk [create_bd_port -dir I -type clk -freq_hz 75000000 jtag_clk]

  # Resets/status.
  set sys_reset [create_bd_port -dir I -type rst sys_reset]
  set_property CONFIG.POLARITY ACTIVE_HIGH $sys_reset
  set cpu_aresetn [create_bd_port -dir I -type rst cpu_aresetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $cpu_aresetn
  set jtag_aresetn [create_bd_port -dir I -type rst jtag_aresetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $jtag_aresetn
  create_bd_port -dir O mem_ok

  # External single-beat 256-bit CPU bridge.
  set s00 [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S00_AXI]
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {30} \
    CONFIG.DATA_WIDTH {256} \
    CONFIG.ID_WIDTH {0} \
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

  # Dedicated 300 MHz differential DDR clock on constrained AN27/AN28.
  set sys_clk [create_bd_intf_port -mode Slave \
      -vlnv xilinx.com:interface:diff_clock_rtl:1.0 default_300mhz_clk0]
  set_property CONFIG.FREQ_HZ {300000000} $sys_clk

  # DDR4 controller.
  set ddr4 [create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_0]
  set_property -dict [list \
    CONFIG.ADDN_UI_CLKOUT1_FREQ_HZ {None} \
    CONFIG.C0.DDR4_AxiAddressWidth {33} \
    CONFIG.C0.DDR4_AxiDataWidth {512} \
    CONFIG.C0.DDR4_AxiIDWidth {4} \
    CONFIG.C0.DDR4_CasLatency {19} \
    CONFIG.C0.DDR4_CasWriteLatency {14} \
    CONFIG.C0.DDR4_DataMask {NO_DM_NO_DBI} \
    CONFIG.C0.DDR4_DataWidth {72} \
    CONFIG.C0.DDR4_EN_PARITY {false} \
    CONFIG.C0.DDR4_InputClockPeriod {3334} \
    CONFIG.C0.DDR4_MemoryPart {MT40A1G16RC-062E} \
    CONFIG.C0.DDR4_MemoryType {Components} \
    CONFIG.C0.DDR4_TimePeriod {750} \
    CONFIG.C0_CLOCK_BOARD_INTERFACE {Custom} \
    CONFIG.C0_DDR4_BOARD_INTERFACE {Custom} \
  ] $ddr4

  # Full AXI4 JTAG master for burst loading.
  set jtag_ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_ddr]
  set_property CONFIG.PROTOCOL {0} $jtag_ddr

  # ui_clk_sync_rst (active-high) -> c0_ddr4_aresetn (active-low).
  set rst_inv [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 \
      rst_inv]
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $rst_inv

  # AXI aggregation with clock and width conversion.
  set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ddr_smc]
  set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_CLKS {3} \
  ] $smc

  # Interface connections.
  connect_bd_intf_net [get_bd_intf_ports S00_AXI] [get_bd_intf_pins ddr_smc/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins jtag_axi_ddr/M_AXI] [get_bd_intf_pins ddr_smc/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins ddr_smc/M00_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]
  # Mandatory ECC management is JTAG-only at region offset 0x4000_0000.
  connect_bd_intf_net [get_bd_intf_pins ddr_smc/M01_AXI] \
      [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]
  connect_bd_intf_net [get_bd_intf_ports default_300mhz_clk0] [get_bd_intf_pins ddr4_0/C0_SYS_CLK]

  # Port names match boards/x3/constr/x3.xdc.
  set ddr4_sdram [create_bd_intf_port -mode Master \
      -vlnv xilinx.com:interface:ddr4_rtl:1.0 ddr4_sdram_c0]
  connect_bd_intf_net [get_bd_intf_pins ddr4_0/C0_DDR4] $ddr4_sdram

  # Clocks.
  connect_bd_net [get_bd_ports cpu_clk] [get_bd_pins ddr_smc/aclk]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] [get_bd_pins ddr_smc/aclk1]
  connect_bd_net [get_bd_ports jtag_clk] [get_bd_pins ddr_smc/aclk2] \
      [get_bd_pins jtag_axi_ddr/aclk]

  # Reset and calibration sequencing.
  connect_bd_net [get_bd_ports sys_reset] [get_bd_pins ddr4_0/sys_rst]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_inv/Op1]
  connect_bd_net [get_bd_pins rst_inv/Res] [get_bd_pins ddr4_0/c0_ddr4_aresetn]
  connect_bd_net [get_bd_pins ddr4_0/c0_init_calib_complete] [get_bd_ports mem_ok]
  connect_bd_net [get_bd_ports cpu_aresetn] [get_bd_pins ddr_smc/aresetn]
  connect_bd_net [get_bd_ports jtag_aresetn] [get_bd_pins jtag_axi_ddr/aresetn]

  # Address map: the first 1 GiB of DDR at region offset 0 for both masters.
  assign_bd_address -offset 0x00000000 -range 0x40000000 \
      -target_address_space [get_bd_addr_spaces S00_AXI] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] -force
  assign_bd_address -offset 0x00000000 -range 0x40000000 \
      -target_address_space [get_bd_addr_spaces jtag_axi_ddr/Data] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] -force
  assign_bd_address -offset 0x40000000 -range 0x00008000 \
      -target_address_space [get_bd_addr_spaces jtag_axi_ddr/Data] \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP_CTRL/C0_REG] -force

  validate_bd_design
  save_bd_design
}
