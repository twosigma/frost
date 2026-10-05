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

"""Failure boundaries for local physical guidance and temporary placement locks."""

import os
from pathlib import Path
import subprocess

import pytest


MODEL = r"""
set model {}
foreach name {u/critical u/protected} fixed {0 1} {
    dict set model $name [dict create NAME $name REF_NAME LUT3 INIT 8'hA8 \
        LOC SLICE_X12Y40 BEL SLICEL.B6LUT IS_LOC_FIXED $fixed IS_BEL_FIXED $fixed \
        DONT_TOUCH $fixed LOCK_PINS {} pins {I0 A2 I1 A5 I2 A6}]
}
set design {}
set pblocks {}
set nets [dict create net_protected [dict create NAME net_protected DONT_TOUCH 1 IS_ROUTE_FIXED 1] \
    net_movable [dict create NAME net_movable DONT_TOUCH 0 IS_ROUTE_FIXED 0]]
set scenario $::env(LOCAL_CASE)
set fail_place 0
set corrupt_logic 0
proc current_design {} {return design}
proc list_property {object} {return [dict keys $::design]}
proc create_property {args} {return [lindex $args end-1]}
proc get_property {property objects} {
    if {$objects eq "design"} {return [dict get $::design $property]}
    if {$property eq "REF_PIN_NAME"} {return [file tail $objects]}
    set result {}
    foreach object $objects {
        if {[dict exists $::pblocks $object]} {
            lappend result [dict get $::pblocks $object $property]
        } elseif {[dict exists $::nets $object]} {
            lappend result [dict get $::nets $object $property]
        } else {lappend result [dict get $::model $object $property]}
    }
    if {[llength $result] == 1} {return [lindex $result 0]}
    return $result
}
proc set_property {property value objects} {
    if {$objects eq "design"} {dict set ::design $property $value; return}
    foreach object $objects {
        if {[dict exists $::pblocks $object]} {
            dict set ::pblocks $object $property $value
        } elseif {[dict exists $::nets $object]} {
            dict set ::nets $object $property $value
        } else {dict set ::model $object $property $value}
    }
}
proc reset_property {property object} {
    if {$object eq "design"} {dict unset ::design $property; return}
    dict set ::model $object $property {}
}
proc get_cells {args} {
    if {$args eq {-hier}} {return [dict keys $::model]}
    if {[lsearch -exact $args -filter] < 0} {
        set result {}
        foreach name [lindex $args end] {if {[dict exists $::model $name]} {lappend result $name}}
        return $result
    }
    set filter [lindex $args end]
    if {[regexp {^NAME == "(.*)"$} $filter -> name]} {
        if {[dict exists $::model $name]} {return $name}
        return {}
    }
    set result {}
    dict for {name state} $::model {
        if {$filter eq {IS_PRIMITIVE && LOC == ""}} {
            if {[dict get $state LOC] eq ""} {lappend result $name}
        } elseif {[regexp {^(\w+) == 1$} $filter -> property]} {
            if {[dict get $state $property]} {lappend result $name}
        } else {error "Unexpected cell query $args"}
    }
    return $result
}
proc get_pins {args} {
    set c [lindex $args [expr {[lsearch -exact $args -of_objects] + 1}]]
    set result {}
    foreach logical [dict keys [dict get $::model $c pins]] {lappend result $c/$logical}
    if {[lsearch -exact $args -filter] < 0} {lappend result $c/O}
    return $result
}
proc get_bel_pins {args} {
    set pin [lindex $args end]
    set c [file dirname $pin]
    return SLICE_X12Y40/B6LUT/[dict get $::model $c pins [file tail $pin]]
}
proc get_nets {args} {
    if {$args eq {-hier}} {return [dict keys $::nets]}
    if {[lsearch -exact $args -of_objects] >= 0} {return net_[lindex $args end]}
    if {[lsearch -exact $args -filter] < 0} {
        set result {}
        foreach name [lindex $args end] {if {[dict exists $::nets $name]} {lappend result $name}}
        return $result
    }
    set filter [lindex $args end]
    if {[regexp {^NAME == "(.*)"$} $filter -> name]} {
        if {[dict exists $::nets $name]} {return $name}
        return {}
    }
    if {![regexp {^(DONT_TOUCH|IS_ROUTE_FIXED) == 1$} $filter -> property]} {error "Unexpected net query $args"}
    set result {}
    dict for {name state} $::nets {
        if {[dict get $state $property]} {lappend result $name}
    }
    return $result
}
proc lock_design {args} {
    if {$args ni {{-unlock -level logical} {-level placement}}} {error "Unexpected lock command $args"}
    set fixed [expr {$args eq {-level placement}}]
    foreach property {IS_LOC_FIXED IS_BEL_FIXED DONT_TOUCH} {
        set_property $property $fixed [dict keys $::model]
    }
    foreach property {DONT_TOUCH IS_ROUTE_FIXED} {
        set_property $property $fixed [dict keys $::nets]
    }
}
proc get_pblocks {args} {
    set name [lindex $args end]
    if {[dict exists $::pblocks $name]} {return $name}
    return {}
}
proc create_pblock {name} {dict set ::pblocks $name [dict create NAME $name]; return $name}
proc resize_pblock {pb add range} {dict set ::pblocks $pb range $range}
proc add_cells_to_pblock {pb cells} {dict set ::pblocks $pb cells $cells}
proc delete_pblocks {pb} {dict unset ::pblocks $pb}
proc unplace_cell {c} {
    dict set ::model $c LOC {}
    dict set ::model $c BEL {}
    dict set ::model $c IS_LOC_FIXED 0
    dict set ::model $c IS_BEL_FIXED 0
}
proc place_cell {pair} {
    lassign $pair c site_bel
    if {$::fail_place} {set ::fail_place 0; error "Injected placement failure"}
    dict set ::model $c LOC [file dirname $site_bel]
    dict set ::model $c BEL SLICEL.[file tail $site_bel]
    dict set ::model $c IS_LOC_FIXED 1
    dict set ::model $c IS_BEL_FIXED 1
    set pins {}
    foreach pair [dict get $::model $c LOCK_PINS] {
        lassign [split $pair :] logical physical
        dict set pins $logical $physical
    }
    dict set ::model $c pins $pins
    if {$::corrupt_logic} {dict set ::model $c INIT 8'hFF}
}
# The production coordinator sources this file from inside its own namespace.
namespace eval ::placement_caller {source $::env(LOCAL_SOURCE)}
namespace import ::frost_x3_local_placement::*
set ns ::frost_x3_local_placement
set original [${ns}::snapshot u/critical]
switch -- $scenario {
    restore - failed_place - prior_pin_lock {
        if {$scenario eq "prior_pin_lock"} {
            dict set model u/critical LOCK_PINS {I0:A2 I1:A5 I2:A6}
            set original [${ns}::snapshot u/critical]
        }
        set fail_place [expr {$scenario eq "failed_place"}]
        set code [catch {${ns}::remap $original SLICE_X12Y40/B6LUT {I0 A6 I1 A5 I2 A2}} result]
        if {$code != ($scenario eq "failed_place")} {error "Unexpected remap result: $result"}
        ${ns}::restore $original
        if {[${ns}::snapshot u/critical] ne $original} {error "Rollback changed the cell"}
    }
    logic_change {
        set corrupt_logic 1
        if {![catch {${ns}::remap $original SLICE_X12Y40/B6LUT {I0 A6 I1 A5 I2 A2}} result] ||
            ![string match {*changed logic or connectivity*} $result]} {error "Logical corruption was accepted"}
    }
    companion_unplaced {
        set baseline [${ns}::unplaced]
        unplace_cell u/protected
        if {![catch {${ns}::require_placed $baseline} result] ||
            ![string match {*companion cell*} $result]} {error "Incomplete placement was scored"}
    }
    release - constrain_guidance {
        set flags [${ns}::constraint_flags]
        ${ns}::remember_constraints
        if {$scenario eq "constrain_guidance"} {
            ${ns}::remap $original SLICE_X12Y40/B6LUT {I0 A6 I1 A5 I2 A2}
            set chosen [${ns}::snapshot u/critical]
            ${ns}::constrain_guidance [dict create u/critical $chosen]
            if {[${ns}::unplaced] ne {u/critical}} {error "Guided cell was placed before place_design"}
            set saved [${ns}::saved_constraints]
            set pb [dict get $saved pblocks]
            if {[llength $pb] != 1 || [dict get $pblocks $pb IS_SOFT] ||
                [dict get $pblocks $pb range] ne "SLICE_X12Y40:SLICE_X12Y40" ||
                [dict get $pblocks $pb cells] ne "u/critical"} {error "Incorrect site constraint"}
            if {[get_property BEL u/critical] ne "B6LUT" ||
                [get_property LOCK_PINS u/critical] ne [dict get $chosen LOCK_PINS]} {error "Lost BEL or pin constraints"}
            # Simulate the final placer consuming the hard site/BEL constraints.
            place_cell [list u/critical SLICE_X12Y40/B6LUT]
            if {[${ns}::pin_map u/critical] ne [dict get $chosen pins]} {error "Final pins changed"}
        } else {
            foreach property {IS_LOC_FIXED IS_BEL_FIXED DONT_TOUCH} {
                set_property $property 1 {u/critical u/protected}
            }
            set_property DONT_TOUCH 1 net_movable
        }
        if {![${ns}::release] || [${ns}::constraint_flags] ne $flags} {error "Original constraints were not restored"}
        if {[dict size $pblocks]} {error "Temporary pblocks survived release"}
        if {[${ns}::protected_nets] ne {net_protected}} {error "Original net constraints were not restored"}
        if {[${ns}::constrained_nets IS_ROUTE_FIXED] ne {net_protected}} {error "Original fixed route was not restored"}
        if {[${ns}::release]} {error "Preservation was released twice"}
    }
    missing_protected_cell {
        ${ns}::remember_constraints
        dict unset model u/protected
        if {![catch {${ns}::release} result]} {error "Missing protected cell was ignored"}
    }
    missing_restoration_metadata {
        if {![catch {${ns}::verify .} result] ||
            ![string match {*Missing placement constraint restoration metadata*} $result]} {
            error "Placement without a restoration record was accepted"
        }
    }
    timing_guard {
        foreach before {{-0.2 -0.1} {-0.2 -0.1} {-0.2 -0.1}} \
                after {{-0.19 -0.1} {-0.21 -0.09} {-0.19 -0.11}} expected {1 0 0} {
            if {[${ns}::no_worse $before $after] != $expected} {error "Setup/hold tradeoff was accepted"}
        }
    }
    default {error "Unknown scenario $scenario"}
}
puts "PASS $scenario"
"""


@pytest.mark.parametrize(
    "scenario",
    (
        "restore",
        "failed_place",
        "prior_pin_lock",
        "logic_change",
        "companion_unplaced",
        "release",
        "constrain_guidance",
        "missing_protected_cell",
        "missing_restoration_metadata",
        "timing_guard",
    ),
)
def test_guidance_failure_boundaries(tmp_path: Path, scenario: str) -> None:
    """Roll back rejected guidance and restore prior constraints exactly."""
    script = tmp_path / "model.tcl"
    script.write_text(MODEL)
    source = Path(__file__).resolve().parents[1] / "fpga/build/x3_local_placement.tcl"
    result = subprocess.run(
        ["tclsh", str(script)],
        env=dict(os.environ, LOCAL_SOURCE=str(source), LOCAL_CASE=scenario),
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"PASS {scenario}" in result.stdout
