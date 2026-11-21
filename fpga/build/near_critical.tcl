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

# Export the path sample and clock interactions for near_critical.py.
if {$argc != 2} {
    error "Usage: near_critical.tcl <checkpoint> <output_prefix>"
}
lassign $argv checkpoint output_prefix
open_checkpoint $checkpoint

set path_limit 600000
set paths [get_timing_paths -setup -sort_by slack -nworst 1 -max_paths $path_limit \
    -slack_lesser_than 1.0 -no_report_unconstrained]
if {[llength $paths] >= $path_limit} {
    error "Near-critical path query reached its $path_limit path limit"
}

report_clock_interaction -setup -significant_digits 3 -file ${output_prefix}_clock_interaction.rpt
set output [open ${output_prefix}_paths.csv w]
try {
    puts $output "slack_ns,start_clock,end_clock,startpoint,endpoint"
    foreach path $paths {
        set row {}
        foreach property {SLACK STARTPOINT_CLOCK ENDPOINT_CLOCK STARTPOINT_PIN ENDPOINT_PIN} {
            set value [get_property $property $path]
            lappend row "\"[string map {\" \"\"} $value]\""
        }
        puts $output [join $row ,]
    }
} finally {
    close $output
}
