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

# The optional CPU boundary uses Gray pointers and held-payload handshakes.
# Both directions are bounded below the faster period, including FIFO storage.
# Clock groups must not mask these bounds between the CPU and SoC clocks.
set cpu_boundary_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*gen_memory_cdc*"}]
if {[llength $cpu_boundary_cells]} {
  set boundary_cpu_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/cpu/cluster_memory/memory_fabric/master/ar_valid_q_reg/C"}]
  set boundary_soc_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/soc/rst_core_reg*/C"}]
  if {[llength $boundary_cpu_pins] != 1 || ![llength $boundary_soc_pins]} {
    error "CPU boundary requires one ar_valid_q_reg/C pin and at least one rst_core_reg*/C pin"
  }
  set boundary_cpu_clocks [get_clocks -quiet -of_objects $boundary_cpu_pins]
  set boundary_soc_clocks [get_clocks -quiet -of_objects $boundary_soc_pins]
  if {[llength $boundary_cpu_clocks] != 1 || [llength $boundary_soc_clocks] != 1} {
    error "CPU boundary requires one CPU clock and one SoC clock"
  }
  if {$boundary_cpu_clocks ne $boundary_soc_clocks} {
    set boundary_limit [expr {0.8 * min([get_property PERIOD $boundary_cpu_clocks], [get_property PERIOD $boundary_soc_clocks])}]
    set_max_delay -datapath_only $boundary_limit -from $boundary_cpu_clocks -to $boundary_soc_clocks
    set_max_delay -datapath_only $boundary_limit -from $boundary_soc_clocks -to $boundary_cpu_clocks
    set_false_path -hold -from $boundary_cpu_clocks -to $boundary_soc_clocks
    set_false_path -hold -from $boundary_soc_clocks -to $boundary_cpu_clocks
  }
}

# Debug transport clock and crossings (dtm_core.sv):
# The X3 debug transport always connects through BSCANE2 USER3 (bscan_dtmcs) and
# USER4 (bscan_dmi), even when ASYNC_CPU_CLOCK is 0 and gen_memory_cdc is absent.
# Clock both primitives' INTERNAL_TCK pins at 100.0 ns (a 10 MHz ceiling above
# the JTAG adapter rate) so u_dtm is clocked and both primitives' falling-edge
# TDO endpoints are timed.
#
# Crossing bounds between cpu_dtm_tck (period T_tck) and the core clock driving
# u_dtm (period T_cpu), with T_fast = min(T_cpu, T_tck):
# 1. Toggle synchronizers (req_toggle_q -> req_sync1 -> req_sync2 on T_cpu, and
#    ack_toggle_q -> ack_sync1 -> ack_sync2 on T_tck): bound each toggle-to-
#    first-synchronizer datapath at 0.8 * T_fast so wire delay stays within one
#    faster-domain cycle.
# 2. Held payloads (req_op_q[1:0], req_addr_q[6:0], req_data_q[31:0] from TCK to
#    the core clock, and resp_data_q[31:0], resp_op_q[1:0] from the core clock
#    to TCK): written on the same launch edge t0 as the toggle and held constant
#    until the opposite acknowledge returns. Let e1 = t0 + delta (delta >= 0) be
#    the first destination clock edge with destination period T_dst >= T_fast:
#    - Fast capture: sync1 captures the new toggle at e1, sync2 updates at
#      e2 = e1 + T_dst, and destination logic samples the held payload at
#      e3 = e1 + 2*T_dst = t0 + delta + 2*T_dst >= t0 + 2*T_dst.
#    - Late or metastable capture: sync1 misses e1 (because of toggle delay up
#      to 0.8*T_fast or metastability) and captures the new toggle at
#      e2 = e1 + T_dst, sync2 updates at e3 = e1 + 2*T_dst, and destination
#      logic samples the held payload at e4 = e1 + 3*T_dst = t0 + delta +
#      3*T_dst >= t0 + 3*T_dst.
#    In both cases the held payload has at least 2*T_dst >= 2*T_fast minus
#    inter-clock skew and setup. Bound the held-payload datapaths at 1.5 * T_fast,
#    leaving at least 0.5 * T_fast margin without over-constraining combinational
#    decode in u_debug_module below a single core-clock cycle.
set dtm_tck_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_toggle_q_reg/C"}]
if {[llength $dtm_tck_pins] != 1} {
  error "Debug transport requires one u_dtm/req_toggle_q_reg/C pin (found [llength $dtm_tck_pins])"
}
set dtm_cpu_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_seen_q_reg/C"}]
if {[llength $dtm_cpu_pins] != 1} {
  error "Debug transport requires one u_dtm/req_seen_q_reg/C pin (found [llength $dtm_cpu_pins])"
}
set dtm_cpu_clocks [get_clocks -quiet -of_objects $dtm_cpu_pins]
if {[llength $dtm_cpu_clocks] != 1} {
  error "Debug transport requires one CPU clock on u_dtm/req_seen_q_reg/C (found [llength $dtm_cpu_clocks])"
}

set dtm_bscan_cells [get_cells -quiet -hierarchical -filter {REF_NAME == BSCANE2 && (NAME =~ "*/bscan_dtmcs" || NAME =~ "*/bscan_dmi" || NAME == "bscan_dtmcs" || NAME == "bscan_dmi")}]
if {[llength $dtm_bscan_cells] != 2} {
  error "Debug transport requires two BSCANE2 cells bscan_dtmcs and bscan_dmi (found [llength $dtm_bscan_cells])"
}
set dtm_bscan_tck_pins [get_pins -quiet -of_objects $dtm_bscan_cells -filter {REF_PIN_NAME == INTERNAL_TCK}]
if {[llength $dtm_bscan_tck_pins] != 2} {
  error "Debug transport requires two BSCANE2 INTERNAL_TCK pins (found [llength $dtm_bscan_tck_pins])"
}
if {![llength [get_clocks -quiet -of_objects $dtm_bscan_tck_pins]]} {
  create_clock -name cpu_dtm_tck -period 100.0 $dtm_bscan_tck_pins
}
set dtm_clocks [get_clocks -quiet -of_objects $dtm_tck_pins]
set dtm_bscan_clocks [get_clocks -quiet -of_objects $dtm_bscan_tck_pins]
if {[llength $dtm_clocks] != 1 || [llength $dtm_bscan_clocks] != 1 || $dtm_clocks ne $dtm_bscan_clocks} {
  error "Debug transport requires one shared clock on BSCANE2 INTERNAL_TCK and u_dtm/req_toggle_q_reg/C"
}

set dtm_req_toggle_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_toggle_q_reg"}]
set dtm_req_sync1_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_sync1_reg/D"}]
set dtm_ack_toggle_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/ack_toggle_q_reg"}]
set dtm_ack_sync1_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/u_dtm/ack_sync1_reg/D"}]
if {[llength $dtm_req_toggle_cells] != 1 || [llength $dtm_req_sync1_pins] != 1 ||
    [llength $dtm_ack_toggle_cells] != 1 || [llength $dtm_ack_sync1_pins] != 1} {
  error "Debug transport requires one toggle flop and one sync1/D pin in each direction"
}

set dtm_req_op_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_op_q_reg*"}]
set dtm_req_addr_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_addr_q_reg*"}]
set dtm_req_data_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_data_q_reg*"}]
set dtm_req_payload_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_op_q_reg*" || NAME =~ "*/u_dtm/req_addr_q_reg*" || NAME =~ "*/u_dtm/req_data_q_reg*"}]
if {[llength $dtm_req_op_cells] != 2 || [llength $dtm_req_addr_cells] != 7 ||
    [llength $dtm_req_data_cells] != 32 || [llength $dtm_req_payload_cells] != 41} {
  error "Debug transport requires 2 req_op_q, 7 req_addr_q, and 32 req_data_q payload cells"
}

set dtm_resp_data_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/resp_data_q_reg*"}]
set dtm_resp_op_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/resp_op_q_reg*"}]
set dtm_resp_payload_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*/u_dtm/resp_data_q_reg*" || NAME =~ "*/u_dtm/resp_op_q_reg*"}]
if {[llength $dtm_resp_data_cells] != 32 || [llength $dtm_resp_op_cells] > 2 ||
    [llength $dtm_resp_payload_cells] != [expr {32 + [llength $dtm_resp_op_cells]}]} {
  error "Debug transport requires 32 resp_data_q cells and at most 2 resp_op_q cells"
}

if {$dtm_cpu_clocks ne $dtm_clocks} {
  set dtm_min_period [expr {min([get_property PERIOD $dtm_cpu_clocks], [get_property PERIOD $dtm_clocks])}]
  set dtm_sync_limit [expr {0.8 * $dtm_min_period}]
  set dtm_payload_limit [expr {1.5 * $dtm_min_period}]
  set_max_delay -datapath_only $dtm_sync_limit -from $dtm_req_toggle_cells -to $dtm_req_sync1_pins
  set_max_delay -datapath_only $dtm_sync_limit -from $dtm_ack_toggle_cells -to $dtm_ack_sync1_pins
  set_max_delay -datapath_only $dtm_payload_limit -from $dtm_req_payload_cells -to $dtm_cpu_clocks
  set_max_delay -datapath_only $dtm_payload_limit -from $dtm_resp_payload_cells -to $dtm_clocks
  set_false_path -hold -from $dtm_clocks -to $dtm_cpu_clocks
  set_false_path -hold -from $dtm_cpu_clocks -to $dtm_clocks
}
