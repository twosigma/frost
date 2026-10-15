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

# Worst setup and hold slack of the paths each clock captures, after the final
# report's parasitic extraction (POST_FINAL_REPORT_TCL). asic/orfs.py reads
# the table this writes.
proc frost_worst_slack { clock path_delay } {
  set paths [find_timing_paths -path_delay $path_delay -to $clock \
    -group_path_count 1 -endpoint_path_count 1 -sort_by_slack]
  if { [llength $paths] == 0 } {
    return "none"
  }
  return [sta::format_time [[lindex $paths 0] slack] 4]
}

set frost_report [open $::env(REPORTS_DIR)/6_clock_slack.rpt w]
puts $frost_report [format "%-16s %10s %12s %12s" Clock Period/ns Setup/ns Hold/ns]
foreach clock [all_clocks] {
  puts $frost_report [format "%-16s %10s %12s %12s" [get_name $clock] \
    [get_property $clock period] \
    [frost_worst_slack $clock max] [frost_worst_slack $clock min]]
}
close $frost_report
