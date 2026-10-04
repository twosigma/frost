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

# Experimental full placement: apply the clock root before place_design.
# The production script still scores with zero added uncertainty and no phys_opt.
rename place_design frost_original_place_design
proc place_design {args} {
    set root $::env(FROST_EXPERIMENT_CLOCK_ROOT)
    set clocks [get_nets {main_clock divided_clock_by_4}]
    if {[llength $clocks] != 2} { error "Expected both CPU clock nets" }
    set_property USER_CLOCK_ROOT $root $clocks
    puts "FROST_EXPERIMENT requested root $root for $clocks"
    set result [uplevel 1 [list frost_original_place_design {*}$args]]
    foreach net $clocks {
        puts "FROST_EXPERIMENT clock $net USER_CLOCK_ROOT=[get_property USER_CLOCK_ROOT $net] CLOCK_ROOT=[get_property CLOCK_ROOT $net]"
    }
    return $result
}
source [file join [file dirname [info script]] build_step.tcl]
