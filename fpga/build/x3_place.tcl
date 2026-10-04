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

# Full-rate X3 placement controls. Both passes start from the current build's
# post-opt checkpoint; the second reuses only the first pass's placement.
# All physical changes happen before place_design. Verification is read-only.
namespace eval frost_x3_place {
    variable mux_name {subsystem/frost_processor/cpu_and_memory_subsystem/instruction_memory/bits24_20_predecoded_2_saved[2]_i_5}
    variable mux_site SLICE_X22Y497
    variable mux_bel A6LUT
    variable mux_init 32'hAAAACFC0
    variable mux_pins {I0:A2 I1:A6 I2:A4 I3:A5 I4:A3}

    proc mux {} {
        variable mux_name
        variable mux_init
        set cell [get_cells -quiet -hier -filter "NAME == \"$mux_name\""]
        if {[llength $cell] != 1 || [get_property REF_NAME $cell] ne "LUT5" ||
            [get_property INIT $cell] ne $mux_init} {
            error "X3 instruction sideband mux no longer matches the placement constraint: $mux_name"
        }
        return $cell
    }

    proc prepare {mode reference} {
        variable mux_site
        variable mux_bel
        variable mux_pins
        if {$mode ni {reference incremental}} {
            error "Unknown X3 placement mode: $mode"
        }
        set clocks [get_nets {main_clock divided_clock_by_4}]
        if {[llength $clocks] != 2} {error "Expected both X3 CPU clock nets"}
        set_property USER_CLOCK_ROOT X1Y9 $clocks
        if {$mode eq "reference"} {return}
        if {![file isfile $reference]} {error "Missing current-build placement reference: $reference"}
        read_checkpoint -incremental $reference -directive RuntimeOptimized -force_incr
        set cell [mux]
        # I1 is the late BRAM data and I4 is the earlier registered select.
        # Swap their physical inputs so the BRAM data uses the fast A6 arc.
        # LOCK_PINS preserves the logical LUT function and its connectivity.
        unplace_cell $cell
        set_property LOC $mux_site $cell
        set_property BEL $mux_bel $cell
        set_property LOCK_PINS $mux_pins $cell
        puts "FROST_X3_PLACE preplace target=$cell LOC=$mux_site BEL=$mux_bel mapping=$mux_pins INIT=[get_property INIT $cell]"
    }

    proc verify {} {
        variable mux_site
        variable mux_bel
        variable mux_pins
        set cell [mux]
        set actual {}
        foreach pin [lsort [get_pins -of_objects $cell -filter {DIRECTION == IN}]] {
            set physical [get_bel_pins -of_objects $pin]
            if {[llength $physical] != 1} {error "Missing physical LUT input: $pin"}
            lappend actual "[get_property REF_PIN_NAME $pin]:[file tail $physical]"
        }
        set bel [get_property BEL $cell]
        if {[lsort $actual] ne [lsort $mux_pins] ||
            [get_property LOC $cell] ne $mux_site ||
            [lindex [split $bel .] end] ne $mux_bel} {
            error "Placement did not preserve the X3 sideband mux input assignment"
        }
        foreach name {gen_gty_cpu_clock.cpu_clock_source/o_clk gen_gty_cpu_clock.cpu_clock_source/o_clk_div4} {
            set net [get_nets -quiet $name]
            if {[llength $net] != 1 || [get_property USER_CLOCK_ROOT $net] ne "X1Y9" ||
                [get_property CLOCK_ROOT $net] ne "X1Y9"} {
                error "Placement did not preserve the X3 CPU clock root: $name"
            }
        }
        puts "FROST_X3_PLACE verified target=$cell LOC=$mux_site BEL=$bel mapping=$actual INIT=[get_property INIT $cell] CLOCK_ROOT=X1Y9"
    }
}
