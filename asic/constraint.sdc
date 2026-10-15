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

# Timing constraints for cpu_and_mem in the OpenROAD flow (asic/config.mk).
#
# The core clock is the X3 target, 322.265625 MHz (CLK_FREQ_HZ in
# cpu_and_mem.sv). The program-loading port runs on the core clock divided by
# four. The NIC's MAC clocks are the X3 GTY's TX and RX user clocks, the
# 161.1328125 MHz Ethernet reference rate (boards/x3/constr/x3.xdc). The JTAG
# clock serves the TAP that cpu_and_mem instantiates with its default
# DEBUG_JTAG_TAP=1; 10 MHz is ten times the OpenOCD adapter speed in
# fpga/debug.
create_clock -name core_clk -period 3.103 [get_ports i_clk]
create_clock -name core_clk_div4 -period 12.412 [get_ports i_clk_div4]
create_clock -name nic_tx_clk -period 6.206 [get_ports i_nic_tx_clk]
create_clock -name nic_rx_clk -period 6.206 [get_ports i_nic_rx_clk]
create_clock -name jtag_tck -period 100.0 [get_ports i_jtag_tck]

# The quarter-rate clock is derived from the core clock, as on the X3, so the
# two are related: both rise at time 0, and paths between them are timed. The
# crossings between them rely on that, such as dc_fifo's binary pointers in
# the debug slice writer. The NIC's TX and RX clocks and the JTAG clock are
# asynchronous to the core clocks and to each other; the RTL synchronizes
# those crossings with Gray-coded FIFOs, two-flop synchronizers, and
# handshakes.
set_clock_groups -asynchronous \
  -group [get_clocks {core_clk core_clk_div4}] \
  -group [get_clocks nic_tx_clk] \
  -group [get_clocks nic_rx_clk] \
  -group [get_clocks jtag_tck]

# Board-level I/O takes a fifth of the period on each side of a port. Ports
# take the core clock unless listed here.
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
  set name [get_full_name $port]
  set clock [port_clock $name]
  set period [get_property [get_clocks $clock] period]
  set_input_delay [expr { $period * $io_fraction }] -clock $clock $port
}
foreach port [all_outputs] {
  set name [get_full_name $port]
  set clock [port_clock $name]
  set period [get_property [get_clocks $clock] period]
  set_output_delay [expr { $period * $io_fraction }] -clock $clock $port
}
set_false_path -from [get_ports $async_ports]
