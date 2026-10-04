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

# Set a LUT input assignment before place_design. The late BRAM data uses A6;
# the early registered select moves to A3. No commands edit the design after
# place_design returns; the remainder audits placement and writes reports.
rename place_design frost_original_place_design
proc place_design {args} {
    set_property USER_CLOCK_ROOT X1Y9 [get_nets {main_clock divided_clock_by_4}]
    read_checkpoint -incremental $::env(FROST_EXPERIMENT_REFERENCE) -directive RuntimeOptimized -force_incr
    set target [get_cells -quiet -hier -filter {NAME == "subsystem/frost_processor/cpu_and_memory_subsystem/instruction_memory/bits24_20_predecoded_2_saved[2]_i_5"}]
    if {[llength $target] != 1 || [get_property REF_NAME $target] ne "LUT5"} {
        error "Expected one LUT5 sideband read mux"
    }
    set init [get_property INIT $target]
    set mapping {I0:A2 I1:A6 I2:A4 I3:A5 I4:A3}
    unplace_cell $target
    set_property LOC SLICE_X22Y497 $target
    set_property BEL A6LUT $target
    set_property LOCK_PINS $mapping $target
    puts "FROST_MUX_PINS preplace target=$target LOC=SLICE_X22Y497 BEL=A6LUT mapping=$mapping INIT=$init"
    set result [uplevel 1 [list frost_original_place_design {*}$args]]
    set actual {}
    foreach pin [lsort [get_pins -of_objects $target -filter {DIRECTION == IN}]] {
        set physical [get_bel_pins -of_objects $pin]
        if {[llength $physical] != 1} {error "Missing physical LUT input: $pin"}
        lappend actual "[get_property REF_PIN_NAME $pin]:[file tail $physical]"
    }
    puts "FROST_MUX_PINS final LOC=[get_property LOC $target] BEL=[get_property BEL $target] mapping=$actual INIT=[get_property INIT $target]"
    if {[lsort $actual] ne [lsort $mapping] || [get_property INIT $target] ne $init ||
        [get_property LOC $target] ne "SLICE_X22Y497"} {
        error "Placement did not preserve the requested mux input assignment"
    }
    report_incremental_reuse -file incremental_reuse.rpt
    return $result
}
source [file join [file dirname [info script]] build_step.tcl]
