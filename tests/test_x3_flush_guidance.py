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

"""Run the shipped flush-guidance Tcl with the finite netlist test API."""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fpga/build/x3_flush_guidance.tcl"
# Finite in-memory stand-ins for the native netlist commands the script calls.
API = r"""
source [lindex $argv 0]
set audit [lindex $argv 1]
namespace eval sim {variable cells {}; variable pins {}; variable nets {}; variable edits 0}
proc sim::add_cell {name ref {init {1'b0}}} {
    variable cells
    dict set cells $name [dict create NAME $name REF_NAME $ref INIT $init IS_PRIMITIVE 1 \
        PARENT {} LOC {} BEL {} DONT_TOUCH {} KEEP {} IS_LOC_FIXED 0 IS_BEL_FIXED 0 \
        LOCK_PINS {} RLOC {} HU_SET {} U_SET {}]
}
proc sim::add_pin {name direction} {
    variable pins
    if {![dict exists $pins $name]} {dict set pins $name [dict create NAME $name \
        REF_PIN_NAME [file tail $name] DIRECTION $direction net {}]}
}
proc sim::wire {source sink} {
    variable pins; variable nets
    add_pin $source OUT; add_pin $sink IN
    set net [dict get $pins $source net]
    if {$net eq {}} {set net "${source}_net"; dict set nets $net 1; dict set pins $source net $net}
    dict set pins $sink net $net
}
proc sim::argument {args key {default {}}} {
    set i [lsearch -exact $args $key]
    if {$i < 0} {return $default}; return [lindex $args [expr {$i+1}]]
}
proc sim::filter {objects expression} {
    if {$expression eq {}} {return $objects}
    if {![regexp {^(NAME|REF_PIN_NAME|DIRECTION) == "?(.*?)"?$} $expression -> key value]} {error "Unsupported mock filter: $expression"}
    set value [string map [list \\" \" \\\\ \\] $value]
    set result {}; foreach o $objects {if {[get_property $key $o] eq $value} {lappend result $o}}
    return $result
}
proc get_cells {args} {
    set from [sim::argument $args -of_objects]
    if {$from ne {}} {
        set result {}; foreach p $from {lappend result [file dirname $p]}; return [lsort -unique $result]
    }
    return [sim::filter [dict keys $::sim::cells] [sim::argument $args -filter]]
}
proc get_pins {args} {
    set result {}
    foreach o [sim::argument $args -of_objects] {
        dict for {p state} $::sim::pins {
            if {([dict exists $::sim::cells $o] && [file dirname $p] eq $o) ||
                ([dict exists $::sim::nets $o] && [dict get $state net] eq $o)} {lappend result $p}
        }
    }
    return [sim::filter [lsort -unique $result] [sim::argument $args -filter]]
}
proc get_nets {args} {
    set from [sim::argument $args -of_objects]
    if {$from eq {}} {return [sim::filter [dict keys $::sim::nets] [sim::argument $args -filter]]}
    set result {}
    foreach p $from {set n [dict get $::sim::pins $p net]; if {$n ne {}} {lappend result $n}}
    return [lsort -unique $result]
}
proc get_ports {args} {return {}}
proc list_property {o} {
    if {[dict exists $::sim::cells $o]} {return [dict keys [dict get $::sim::cells $o]]}
    if {[dict exists $::sim::pins $o]} {return [dict keys [dict get $::sim::pins $o]]}
    return {NAME DONT_TOUCH KEEP}
}
proc get_property {key objects} {
    set result {}
    foreach o $objects {
        if {[dict exists $::sim::cells $o $key]} {lappend result [dict get $::sim::cells $o $key]
        } elseif {[dict exists $::sim::pins $o $key]} {lappend result [dict get $::sim::pins $o $key]
        } elseif {$key eq "NAME"} {lappend result $o
        } else {lappend result {}}
    }
    if {[llength $result] == 1} {return [lindex $result 0]}; return $result
}
proc set_property {key value o} {incr ::sim::edits; dict set ::sim::cells $o $key $value}
proc create_cell {args} {
    incr ::sim::edits
    set ref [sim::argument $args -reference]; set name [lindex $args end]
    if {[dict exists $::sim::cells $name]} {error "Duplicate mock cell"}
    sim::add_cell $name $ref
    regexp {LUT([1-6])} $ref -> width
    for {set i 0} {$i < $width} {incr i} {sim::add_pin "$name/I$i" IN}
    sim::add_pin "$name/O" OUT
}
proc create_net {name} {incr ::sim::edits; dict set ::sim::nets $name 1}
proc connect_net {args} {
    incr ::sim::edits
    if {[info exists ::inject_connect_failure]} {error "Injected connection failure"}
    set n [sim::argument $args -net]
    foreach p [sim::argument $args -objects] {dict set ::sim::pins $p net $n}
}
proc disconnect_net {args} {
    incr ::sim::edits
    foreach p [sim::argument $args -pinlist] {dict set ::sim::pins $p net {}}
}
proc remove_cell {name} {
    incr ::sim::edits; dict unset ::sim::cells $name
    foreach p [dict keys $::sim::pins] {if {[file dirname $p] eq $name} {dict unset ::sim::pins $p}}
}
proc sim::consumer {pin} {
    set name [file dirname $pin]; set port [file tail $pin]
    if {![dict exists $::sim::cells $name]} {
        if {$port in {CE D}} {add_cell $name FDRE} else {add_cell $name LUT6 {64'hAAAAAAAAAAAAAAAA}}
    }
    add_pin $pin IN
}
"""
FLUSH = r"""
namespace eval sim {variable netprops {}; variable clock_name clock_from_mmcm; variable period 3.333}
rename get_property sim::base_get_property
proc get_property {key objects} {
    if {$objects eq "clock_from_mmcm" || $objects eq "wrong_clock"} {
        if {$key eq "NAME"} {return $::sim::clock_name}
        if {$key eq "PERIOD"} {return $::sim::period}
    }
    if {[dict exists $::sim::netprops $objects $key]} {return [dict get $::sim::netprops $objects $key]}
    return [sim::base_get_property $key $objects]
}
rename list_property sim::base_list_property
proc list_property {o} {
    if {[dict exists $::sim::netprops $o]} {return [concat {NAME} [dict keys [dict get $::sim::netprops $o]]]}
    return [sim::base_list_property $o]
}
rename set_property sim::unused_set_property
proc set_property {key value object} {
    if {![dict exists $::sim::netprops $object] || $key ni {MAX_FANOUT_MODE FORCE_MAX_FANOUT}} {error "Unexpected property write"}
    incr ::sim::edits
    if {![info exists ::bad_readback]} {dict set ::sim::netprops $object $key $value}
}
proc get_clocks {args} {return $::sim::clock_name}
set driver $::frost_x3_flush_guidance::driver_name
set net $::frost_x3_flush_guidance::net_name
sim::add_cell $driver FDRE
# KEEP=yes is a real source attribute; it must remain intact.
dict set ::sim::cells $driver KEEP yes
dict set ::sim::cells $driver IS_C_INVERTED 0
foreach {port name ref pin} {C cpu_clock BUFGCE O CE enable VCC P D request LUT3 O R reset FDRE Q} {
    sim::add_cell $name $ref
    sim::wire "$name/$pin" "$driver/$port"
}
for {set i 0} {$i < 4} {incr i} {
    set name "consumer_$i"; sim::add_cell $name LUT1
    sim::wire "$driver/Q" "$name/I0"
}
set temporary [dict get $::sim::pins "$driver/Q" net]
dict unset ::sim::nets $temporary; dict set ::sim::nets $net 1
dict for {p data} $::sim::pins {
    if {[dict get $data net] eq $temporary} {dict set ::sim::pins $p net $net}
}
dict set ::sim::netprops $net [dict create MAX_FANOUT_MODE {} FORCE_MAX_FANOUT {} DONT_TOUCH {} KEEP {}]
proc sim::replica {name sinks} {
    set original $::driver
    set config [dict get $::sim::cells $original]
    dict set config NAME $name; dict set config LOC SLICE_X1Y2; dict set config BEL SLICEL.AFF
    dict set ::sim::cells $name $config
    foreach port {C CE D R} {
        set input [dict get $::sim::pins "$original/$port"]
        dict set input NAME "$name/$port"; dict set ::sim::pins "$name/$port" $input
    }
    foreach sink $sinks {sim::wire "$name/Q" $sink}
}
set ::sim::edits 0
"""


def run_flush(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    """Execute actual prepare/verify without opening a native design."""
    harness = tmp_path / "flush.tcl"
    harness.write_text(API + FLUSH + body)
    return subprocess.run(
        ["tclsh", str(harness), str(SCRIPT), str(tmp_path / "audit.txt")],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


@pytest.mark.parametrize("replicate", [False, True])
def test_current_partition_not_historical_count(
    tmp_path: Path, replicate: bool
) -> None:
    """Accept any equivalent complete partition, including one unchanged driver."""
    result = run_flush(
        tmp_path,
        r"""
set before [::frost_x3_flush_guidance::prepare $audit]
if {$::sim::edits != 2} {error "Expected exactly two net-property writes"}
"""
        + (
            "sim::replica renamed_by_placer {consumer_1/I0 consumer_3/I0}\n"
            if replicate
            else ""
        )
        + r"""
set result [::frost_x3_flush_guidance::verify $audit]
if {[dict get $result sinks] != 4 || $::sim::edits != 2} {error "Verify changed the netlist or lost a sink"}
"""
        + f'if {{[dict get $result drivers] != {2 if replicate else 1}}} {{error "Incorrect observed driver count"}}\n',
    )
    assert result.returncode == 0, result.stderr
    assert "VERIFIED" in result.stdout


@pytest.mark.parametrize(
    "change",
    [
        "dict set ::sim::cells $driver DONT_TOUCH true",
        "dict set ::sim::cells $driver LUTNM 0",
        "dict set ::sim::cells $driver REF_NAME FDSE",
        "dict set ::sim::netprops $net MAX_FANOUT_MODE SLR",
        "dict set ::sim::netprops $net FORCE_MAX_FANOUT 32",
        "set ::sim::clock_name wrong_clock",
        "set ::sim::period 6.666",
    ],
)
def test_invalid_preflight_has_no_writes(tmp_path: Path, change: str) -> None:
    """Reject conflicting or unsupported current designs before changing properties."""
    result = run_flush(
        tmp_path,
        change
        + r"""
if {![catch {::frost_x3_flush_guidance::prepare $audit} message] || $::sim::edits != 0} {error "Preflight did not reject before writes"}
""",
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("change", ["data", "init", "missing", "extra"])
def test_changed_replica_or_partition_fails(tmp_path: Path, change: str) -> None:
    """Detect changed register functions and missing or unexpected sink owners."""
    mutation = {
        "data": "sim::wire reset/Q renamed_by_placer/D",
        "init": "dict set ::sim::cells renamed_by_placer INIT {1'b1}",
        "missing": "dict unset ::sim::pins consumer_1/I0",
        "extra": "sim::add_cell extra LUT1; sim::wire renamed_by_placer/Q extra/I0",
    }[change]
    result = run_flush(
        tmp_path,
        r"""
::frost_x3_flush_guidance::prepare $audit
sim::replica renamed_by_placer {consumer_1/I0 consumer_3/I0}
"""
        + mutation
        + r"""
if {![catch {::frost_x3_flush_guidance::verify $audit} message]} {error "Changed replica/partition passed"}
set f [open $audit]; set data [read $f]; close $f
if {[dict get $data status] ne "FAILED_AFTER_PLACE" || $::sim::edits != 2} {error "Wrong failure state or verify wrote native properties"}
""",
    )
    assert result.returncode == 0, result.stderr


def test_partial_property_failure_is_not_prepared(tmp_path: Path) -> None:
    """A failed readback cannot produce a prepared or verified state."""
    result = run_flush(
        tmp_path,
        r"""
set ::bad_readback 1
if {![catch {::frost_x3_flush_guidance::prepare $audit} message] || $::sim::edits != 1} {error "Expected one failed property update"}
if {![catch {::frost_x3_flush_guidance::verify $audit} message]} {error "Failed preparation reached verification"}
""",
    )
    assert result.returncode == 0, result.stderr
