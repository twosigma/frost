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

# Full-rate X3 placement controls. The first pass produces a fresh reference;
# the second derives local floorplan constraints and re-places those cells.
# All physical changes precede place_design. Verification is read-only.
namespace eval frost_x3_place {
    variable script_directory [file dirname [file normalize [info script]]]

    proc verify_roots {} {
        foreach name {gen_gty_cpu_clock.cpu_clock_source/o_clk gen_gty_cpu_clock.cpu_clock_source/o_clk_div4} {
            set net [get_nets -quiet $name]
            if {[llength $net] != 1 || [get_property USER_CLOCK_ROOT $net] ne "X1Y9" ||
                [get_property CLOCK_ROOT $net] ne "X1Y9"} {
                error "Placement did not preserve the X3 CPU clock root: $name"
            }
        }
    }

    proc prepare {mode work_directory} {
        variable script_directory
        if {$mode eq "reference"} {
            set clocks [get_nets {main_clock divided_clock_by_4}]
            if {[llength $clocks] != 2} {error "Expected both X3 CPU clock nets"}
            set_property USER_CLOCK_ROOT X1Y9 $clocks
            return
        }
        if {$mode ne "guided"} {error "Unknown X3 placement mode: $mode"}
        verify_roots
        source [file join $script_directory x3_local_placement.tcl]
        set guidance [::frost_x3_local_placement::refine $work_directory]
        ::frost_x3_local_placement::constrain_guidance $guidance
    }

    proc verify {work_directory} {
        variable script_directory
        verify_roots
        source [file join $script_directory x3_local_placement.tcl]
        ::frost_x3_local_placement::verify $work_directory
        puts "FROST_X3_PLACE verified local floorplan and CPU clock roots"
    }
}
