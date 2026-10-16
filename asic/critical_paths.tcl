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

# Setup timing of one stage's database, for asic/orfs.py paths. ORFS's
# `make run` runs this with FROST_PATHS_STAGE set to the database's name:
# 3_place, 4_cts, 5_1_grt, or 6_final. The parasitics and clocks match the
# stage's own report: placement estimates and ideal clocks after placement,
# propagated clocks after clock tree synthesis, global routes after global
# routing, and the extracted SPEF at the end.
#
# REPORTS_DIR receives:
#   <stage>_paths.tsv           the worst path to every constrained endpoint
#   <stage>_register_paths.tsv  the worst path between registers for each
#                               pair of launching and capturing core clocks
#   <stage>_worst_paths.json    the worst core clock paths, every pin with
#                               its arrival time, in OpenSTA's JSON format
#   <stage>_worst_paths.rpt     the worst paths of each clock, for reading
#
# Both tables have one path per line, with times in ns: the capturing and
# launching clocks, the slack, the arrival times at the startpoint and the
# endpoint, the required time, the clock skew, the cells after the
# startpoint and how many of them are buffers or inverters, and the
# startpoint and endpoint (a register's instance, or a port).

source $::env(SCRIPTS_DIR)/load.tcl

set frost_stage $::env(FROST_PATHS_STAGE)
load_design $frost_stage.odb $frost_stage.sdc
switch -- $frost_stage {
  3_place {
    estimate_parasitics -placement
  }
  4_cts {
    set_propagated_clock [all_clocks]
    estimate_parasitics -placement
  }
  5_1_grt {
    set_propagated_clock [all_clocks]
    estimate_parasitics -global_routing
  }
  6_final {
    set_propagated_clock [all_clocks]
    read_spef $::env(RESULTS_DIR)/6_final.spef
  }
  default {
    error "FROST_PATHS_STAGE must be 3_place, 4_cts, 5_1_grt, or 6_final"
  }
}

# Times in ns, with the digits to keep a slack of a few femtoseconds negative.
proc frost_ns { seconds } {
  return [format %.10g [expr { $seconds * 1e9 }]]
}

# The clock of a path's launching edge. OpenSTA's tag for the path names it
# after the tag index, the scene, and the transition: "12 default ^max
# core_clk ^ ...". Paths from unclocked inputs have no clock edge there.
proc frost_launch_clock { path } {
  set tag [$path tag]
  if { [regexp {^\S+ \S+ \S+ (\S+) [\^v] } $tag -> clock] } {
    return $clock
  }
  return "-"
}

# A path's startpoint or endpoint: the register's instance, or the port.
proc frost_point { pin } {
  set name [get_full_name $pin]
  if { [$pin is_top_level_port] } {
    return $name
  }
  return [file dirname $name]
}

proc frost_columns { } {
  return [join {capture launch slack launched arrival required skew cells \
    buffers startpoint endpoint} "\t"]
}

proc frost_row { path_end } {
  set path [$path_end path]
  set start_path [$path start_path]
  set start_pin [$start_path pin]
  set capture [$path_end target_clk]
  if { $capture eq "NULL" } {
    set capture "-"
  } else {
    set capture [get_name $capture]
  }
  # Count the cells between the startpoint and the endpoint; the pins run
  # from the endpoint back through the clock tree.
  set cells 0
  set buffers 0
  foreach pin [$path pins] {
    if { $pin eq $start_pin } {
      break
    }
    if { [$pin is_driver] && ![$pin is_top_level_port] } {
      incr cells
      if { [regexp {^(BUF|CLKBUF|INV)_} [get_name [[$pin instance] cell]]] } {
        incr buffers
      }
    }
  }
  # The pins' arrival times leave out the launching edge's time, which the
  # path end's data arrival time includes.
  set arrival [$path_end data_arrival_time]
  set launched [expr { $arrival - ([$path arrival] - [$start_path arrival]) }]
  return [join [list $capture [frost_launch_clock $path] \
    [frost_ns [$path_end slack]] [frost_ns $launched] [frost_ns $arrival] \
    [frost_ns [$path_end data_required_time]] [frost_ns [$path_end clk_skew]] \
    $cells $buffers [frost_point $start_pin] [frost_point [$path_end pin]]] "\t"]
}

set frost_out [open $::env(REPORTS_DIR)/${frost_stage}_paths.tsv w]
puts $frost_out [frost_columns]
foreach path_end [find_timing_paths -path_delay max -group_path_count 100000000 \
  -endpoint_path_count 1] {
  puts $frost_out [frost_row $path_end]
}
close $frost_out

# The requirements of these paths scale with the core period, unlike those
# of paths from and to ports, which also carry the I/O delays. An endpoint
# can have both, and paths from both core clocks, so each pair of clocks is
# searched on its own.
set frost_out [open $::env(REPORTS_DIR)/${frost_stage}_register_paths.tsv w]
puts $frost_out [frost_columns]
foreach launch {core_clk core_clk_div4} {
  foreach capture {core_clk core_clk_div4} {
    foreach path_end [find_timing_paths -path_delay max \
      -from [all_registers -clock [get_clocks $launch]] \
      -to [all_registers -clock [get_clocks $capture] -data_pins] \
      -group_path_count 1 -endpoint_path_count 1 -sort_by_slack] {
      puts $frost_out [frost_row $path_end]
    }
  }
}
close $frost_out

report_checks -path_delay max -path_group core_clk -group_path_count 100 \
  -endpoint_path_count 1 -format json > $::env(REPORTS_DIR)/${frost_stage}_worst_paths.json
report_checks -path_delay max -group_path_count 5 -endpoint_path_count 1 \
  -fields {fanout capacitance slew} -digits 3 \
  > $::env(REPORTS_DIR)/${frost_stage}_worst_paths.rpt
