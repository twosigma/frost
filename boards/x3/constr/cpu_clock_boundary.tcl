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
  set boundary_cpu_clocks [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ "*/cpu/cluster_memory/memory_fabric/master/ar_valid_q_reg/C"}]]
  set boundary_soc_clocks [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ "*/soc/rst_core_reg*/C"}]]
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
  # DMI holds each payload until the synchronized response completes.
  # The transport clock uses the same constraint as the ASIC flow.
  set boundary_tck_pins [get_pins -quiet -hierarchical -filter {NAME =~ "*/u_dtm/req_toggle_q_reg/C"}]
  if {[llength $boundary_tck_pins]} {
    set boundary_dtm_clocks [get_clocks -quiet -of_objects $boundary_tck_pins]
    if {![llength $boundary_dtm_clocks]} {
      set boundary_tck_nets [get_nets -segments -of_objects $boundary_tck_pins]
      set boundary_tck_sources [get_pins -quiet -leaf -of_objects $boundary_tck_nets -filter {DIRECTION == OUT}]
      if {![llength $boundary_tck_sources]} {
        set boundary_tck_sources [get_ports -quiet -of_objects $boundary_tck_nets -filter {DIRECTION == IN}]
      }
      if {[llength $boundary_tck_sources] != 1} {
        error "CPU boundary requires one debug transport clock source"
      }
      create_clock -name cpu_dtm_tck -period 100.0 $boundary_tck_sources
      set boundary_dtm_clocks [get_clocks -of_objects $boundary_tck_pins]
    }
    if {[llength $boundary_dtm_clocks] != 1} {
      error "CPU boundary requires one debug transport clock"
    }
    if {$boundary_cpu_clocks ne $boundary_dtm_clocks} {
      set boundary_dtm_limit [expr {0.8 * min([get_property PERIOD $boundary_cpu_clocks], [get_property PERIOD $boundary_dtm_clocks])}]
      set_max_delay -datapath_only $boundary_dtm_limit -from $boundary_dtm_clocks -to $boundary_cpu_clocks
      set_max_delay -datapath_only $boundary_dtm_limit -from $boundary_cpu_clocks -to $boundary_dtm_clocks
      set_false_path -hold -from $boundary_dtm_clocks -to $boundary_cpu_clocks
      set_false_path -hold -from $boundary_cpu_clocks -to $boundary_dtm_clocks
    }
  }
}
