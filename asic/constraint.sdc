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

# Timing constraints for platform_top in the OpenROAD flow (asic/config.mk).
#
# The core clock is the X3 target, 322.265625 MHz (CLK_FREQ_HZ in
# platform_top.sv), unless the environment variable FROST_CORE_CLOCK_PERIOD
# gives another period in ns; asic/README.md describes finding the fmax with
# it. ORFS reads the default for ABC from the first clk_period assignment, so
# that assignment keeps a plain number. The program-loading port runs on the
# core clock divided by four. The NIC's MAC clocks are the X3 GTY's TX and RX
# user clocks, the 161.1328125 MHz Ethernet reference rate
# (boards/x3/constr/x3.xdc). The JTAG clock serves the TAP that platform_top
# instantiates with its default DEBUG_JTAG_TAP=1; 10 MHz is ten times the
# OpenOCD adapter speed in fpga/debug.
set clk_period 3.103
# OpenSTA keeps times in single precision and writes the constraints for later
# stages with four decimals. Below 100 ns with at most four decimals, both
# core clock periods survive that exactly, and the div4 period stays four
# core periods.
if { [info exists ::env(FROST_CORE_CLOCK_PERIOD)] && $::env(FROST_CORE_CLOCK_PERIOD) ne "" } {
  set clk_period $::env(FROST_CORE_CLOCK_PERIOD)
  if { ![regexp {^(0|[1-9][0-9]?)(\.[0-9]{1,4})?$} $clk_period] || $clk_period == 0 } {
    error "FROST_CORE_CLOCK_PERIOD must be a positive number of ns below 100 with\
      at most four decimals, not '$clk_period'"
  }
}
create_clock -name core_clk -period $clk_period [get_ports i_clk]
create_clock -name core_clk_div4 -period [expr { 4 * $clk_period }] [get_ports i_clk_div4]
create_clock -name nic_tx_clk -period 6.206 [get_ports i_nic_tx_clk]
create_clock -name nic_rx_clk -period 6.206 [get_ports i_nic_rx_clk]
create_clock -name jtag_tck -period 100.0 [get_ports i_jtag_tck]

# Board-level I/O takes a fifth of the period on each side of a port, timed
# against the clock as it arrives inside the chip, as if a PLL aligned the
# board's clock with a point inside it, or the logic beyond the ports shared
# the clock tree. Each clock has an I/O copy, generated at the clock pin of
# one register at its interface, and the port delays count from the copy:
# after clock tree synthesis its edges arrive with the tree's delay to that
# pin, and before it, while the clocks are ideal, with the master's edges.
# The registers are the DDR bridge's AXI read request register, the data
# memory's program-loading port, the NIC's transmit and receive gearboxes,
# and the JTAG TAP. A pattern leaves out the suffix that synthesis adds to a
# register's name, and must match one pin. set_input_delay -reference_pin
# would say the same, but OpenROAD in the ORFS image crashes on any input
# delay that uses it. Clock tree synthesis would take a copy for a second
# clock on its master's net, so it takes the clock ports' nets as its roots
# from CTS_ARGS in config.mk, which lists each clock's port.
set io_references {
  core_clk i_clk {cpu.memory_fabric.master.ar_valid_q$*/CK}
  core_clk_div4 i_clk_div4 {soc.data_memory.u_sram.gen_row[0].u_macro/clk0}
  nic_tx_clk i_nic_tx_clk {soc.gen_cached_tier.nic.u_mac.u_mac.tx_gearbox.reservoir[0]$*/CK}
  nic_rx_clk i_nic_rx_clk {soc.gen_cached_tier.nic.u_mac.u_mac.rx_gearbox.reservoir[0]$*/CK}
  jtag_tck i_jtag_tck {soc.gen_jtag_tap.u_jtag_tap.bypass_shift$*/CK}
}
foreach {clock source pattern} $io_references {
  set pins [get_pins -quiet $pattern]
  if { [llength $pins] != 1 } {
    error "constraint.sdc: the I/O reference for $clock, $pattern, matches\
      [llength $pins] pins"
  }
  create_generated_clock -name ${clock}_io -source [get_ports $source] -divide_by 1 $pins
}

# The quarter-rate clock is derived from the core clock, as on the X3, so the
# two are related: both rise at time 0, and paths between them are timed. The
# crossings between them rely on that, such as dc_fifo's binary pointers in
# the debug slice writer. The NIC's TX and RX clocks and the JTAG clock are
# asynchronous to the core clocks and to each other; the RTL synchronizes
# those crossings with Gray-coded FIFOs, two-flop synchronizers, and
# handshakes. Each I/O copy goes with its master.
set_clock_groups -asynchronous \
  -group [get_clocks {core_clk core_clk_div4 core_clk_io core_clk_div4_io}] \
  -group [get_clocks {nic_tx_clk nic_tx_clk_io}] \
  -group [get_clocks {nic_rx_clk nic_rx_clk_io}] \
  -group [get_clocks {jtag_tck jtag_tck_io}]

# Ports take the core clock unless listed here.
set io_fraction 0.2
set port_clocks {
  i_instr_mem_* core_clk_div4
  i_nic_rx_raw_* nic_rx_clk
  i_nic_rx_signal_ok nic_rx_clk
  o_nic_tx_raw_* nic_tx_clk
  i_jtag_tms jtag_tck
  i_jtag_tdi jtag_tck
  o_jtag_tdo jtag_tck
}
# Asynchronous levels, synchronized inside the design.
set async_ports {i_jtag_trst_n i_nic_tx_clk_ok i_nic_rx_clk_ok i_nic_phy_status*}

proc port_clock { port_name } {
  foreach {pattern clock} $::port_clocks {
    if { [string match $pattern $port_name] } {
      return $clock
    }
  }
  return core_clk
}

foreach port [all_inputs -no_clocks] {
  set clock [port_clock [get_full_name $port]]
  set period [get_property [get_clocks $clock] period]
  set_input_delay [expr { $period * $io_fraction }] -clock ${clock}_io $port
}
foreach port [all_outputs] {
  set clock [port_clock [get_full_name $port]]
  set period [get_property [get_clocks $clock] period]
  set_output_delay [expr { $period * $io_fraction }] -clock ${clock}_io $port
}
set_false_path -from [get_ports $async_ports]
