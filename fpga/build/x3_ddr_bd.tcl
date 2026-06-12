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

# Copyright 2026 Two Sigma Open Source, LLC
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# X3 (X3522PV, UltraScale+) DDR4 subsystem block design.
#
# Transplanted from the hardware-verified vivado-risc-v x3522pv design
# (board/x3522pv/riscv-2025.2.tcl): the ddr4 controller IP with the identical
# CONFIG.C0.* property set (MT40A1G16RC-062E components, 300 MHz input on its
# own AN27/AN28 clock pair, 72-bit physical / 512-bit AXI; the 72-bit width
# implies ECC, whose mandatory S_AXI_CTRL management port is reachable from
# the JTAG-AXI master at region offset 0x4000_0000) -- and the same reset
# wiring (sys_rst in; ui_clk_sync_rst inverted into c0_ddr4_aresetn;
# c0_init_calib_complete out as mem_ok). Differences from the reference: the
# CPU-side AXI slave is external (FROST's cache-hierarchy bridge, 256-bit @
# the core clock) and a JTAG-AXI master is added for DDR-image loading.
# The DDR4 pin constraints live in boards/x3/constr/x3.xdc (copied verbatim
# from the reference top.xdc; the external interface names match).
#
# The block design is created inside the synthesis project by build_step.tcl
# (x3 only); x3_frost.sv instantiates the generated wrapper.

proc create_x3_ddr_bd {} {
  create_bd_design "ddr_subsys"

  # Clocks: FROST core clock (S00 side) and the JTAG/div4 clock (S01 side).
  # The DDR4 IP gets its own dedicated 300 MHz differential input below.
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

  # External AXI slave: the FROST cache-hierarchy bridge (single-beat 256-bit).
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

  # Dedicated DDR4 system clock: 300 MHz differential on AN27/AN28 (the pins
  # are constrained in boards/x3/constr/x3.xdc with the reference's names).
  set sys_clk [create_bd_intf_port -mode Slave \
      -vlnv xilinx.com:interface:diff_clock_rtl:1.0 default_300mhz_clk0]
  set_property CONFIG.FREQ_HZ {300000000} $sys_clk

  # DDR4 controller, configured identically to the verified reference design.
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

  # JTAG-AXI master for DDR-image loading (full AXI4 so the loader can burst).
  set jtag_ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_ddr]
  set_property CONFIG.PROTOCOL {0} $jtag_ddr

  # ui_clk_sync_rst (active-high) -> c0_ddr4_aresetn (active-low), as in the
  # reference design.
  set rst_inv [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 \
      rst_inv]
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $rst_inv

  # AXI aggregation + clock/width conversion in front of the DDR4 controller.
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
  # The ECC management port (mandatory with the 72-bit configuration): reached
  # only by the JTAG master, at region offset 0x4000_0000.
  connect_bd_intf_net [get_bd_intf_pins ddr_smc/M01_AXI] \
      [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]
  connect_bd_intf_net [get_bd_intf_ports default_300mhz_clk0] [get_bd_intf_pins ddr4_0/C0_SYS_CLK]

  # DDR4 pins out to the top level (names match the reference xdc).
  set ddr4_sdram [create_bd_intf_port -mode Master \
      -vlnv xilinx.com:interface:ddr4_rtl:1.0 ddr4_sdram_c0]
  connect_bd_intf_net [get_bd_intf_pins ddr4_0/C0_DDR4] $ddr4_sdram

  # Clocks.
  connect_bd_net [get_bd_ports cpu_clk] [get_bd_pins ddr_smc/aclk]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] [get_bd_pins ddr_smc/aclk1]
  connect_bd_net [get_bd_ports jtag_clk] [get_bd_pins ddr_smc/aclk2] \
      [get_bd_pins jtag_axi_ddr/aclk]

  # Reset / calibration sequencing (mirrors the reference wiring).
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
