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

# Standalone fetch ILA capture (build.py --debug-ila) for a program that is
# already running: arm, wait for the trigger, and write the CSV in one
# Hardware Manager session, which frost_hw_session closes even when a step
# fails. To capture a program the software loader starts, use the loader hooks
# (capture_fetch_ila.py hook) instead, because the loader's device refresh
# resets the ILA. See capture_fetch_ila.py for the arguments.
#
# Usage: vivado -mode batch -source capture_fetch_ila.tcl -tclargs \
#            <hw_target> <ltx_file> <csv_file> <fault_probe_glob> \
#            <pc_probe_glob> <pc_value> <trigger_position> <wait_minutes> \
#            [remote_host]

if {$argc < 8} {
    puts "Error: hw_target, ltx, csv, fault probe, pc probe, pc value, trigger position, wait minutes required"
    exit 1
}
set hw_target [lindex $argv 0]
set ltx_file [lindex $argv 1]
set csv_file [lindex $argv 2]
set fault_probe_glob [lindex $argv 3]
set pc_probe_glob [lindex $argv 4]
set pc_value [lindex $argv 5]
set trigger_position [lindex $argv 6]
set wait_minutes [lindex $argv 7]

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir fetch_ila_procs.tcl]
source [file join $script_dir .. common hw_session.tcl]

frost_hw_session [lindex $argv 8] "" $hw_target {
    current_hw_device [lindex [get_hw_devices] 0]
    set ila [frost_ila_attach $ltx_file]
    frost_ila_arm $ila $fault_probe_glob $pc_probe_glob $pc_value $trigger_position
    frost_ila_wait_and_collect $ila $csv_file $wait_minutes
}
