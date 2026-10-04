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

# Reopen a placement checkpoint and score its stored constraints unchanged.
# Usage: vivado -mode batch -source verify_place.tcl -tclargs DCP OUTPUT_DIR
set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
file mkdir $output_dir
set_param general.maxThreads 8
open_checkpoint $checkpoint
source [file join [file dirname [info script]] x3_post_place_gate.tcl]
set passed [frost_x3_post_place_gate::write $output_dir]
report_timing_summary -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 1 -file [file join $output_dir worst_paths.rpt]
set old_endpoint [get_pins -quiet -hier -filter {NAME == "subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[instruction][source_reg_2][2]/D"}]
if {[llength $old_endpoint] == 1} {
    report_timing -to $old_endpoint -delay_type max -max_paths 5 -nworst 5 -file [file join $output_dir sideband_path.rpt]
}
report_route_status -file [file join $output_dir route_status.rpt]
write_xdc -force [file join $output_dir stored_constraints.xdc]
set f [open [file join $output_dir verification.txt] w]
puts $f "CHECKPOINT=$checkpoint"
puts $f "GATE_PASS=$passed"
puts $f "CPU_PERIOD_NS=[get_property PERIOD [get_clocks clock_from_mmcm]]"
foreach name {gen_gty_cpu_clock.cpu_clock_source/o_clk gen_gty_cpu_clock.cpu_clock_source/o_clk_div4} {
    set net [get_nets -quiet $name]
    if {[llength $net] != 1} {error "Missing CPU clock net: $name"}
    puts $f "CLOCK=$name USER_CLOCK_ROOT=[get_property USER_CLOCK_ROOT $net] CLOCK_ROOT=[get_property CLOCK_ROOT $net]"
}
set target [get_cells -quiet -hier -filter {NAME == "subsystem/frost_processor/cpu_and_memory_subsystem/instruction_memory/bits24_20_predecoded_2_saved[2]_i_5"}]
if {[llength $target] == 1} {
    puts $f "SIDEBAND_MUX=$target LOC=[get_property LOC $target] BEL=[get_property BEL $target]"
}
close $f
exit
