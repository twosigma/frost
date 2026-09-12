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

"""Execute the shipped L1 transform against a finite in-memory netlist API.

These checks cover the actual Tcl proof, edits, ownership and failure policy.
They do not emulate Vivado placement or establish timing improvement.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fpga/build/l1_control_repair.tcl"

MOCK = r"""
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
set r [::frost_l1_control_repair::recipe]
set symbols [dict get $r boundary]
dict for {role source} $symbols {
    set name [file dirname $source]
    if {![dict exists $::sim::cells $name]} {sim::add_cell $name LUT1 {2'h2}}
    sim::add_pin $source OUT
}
dict for {role spec} [dict get $r old] {
    set name [dict get $spec cell]
    sim::add_cell $name LUT[dict get $spec width] [dict get $spec init]
    sim::add_pin "$name/O" OUT; dict set symbols $role "$name/O"
}
dict for {role spec} [dict get $r old] {
    set i 0; foreach symbol [dict get $spec inputs] {
        sim::wire [dict get $symbols $symbol] "[dict get $spec cell]/I$i"; incr i
    }
}
set t [dict get $r t_cell]; sim::add_cell $t LUT4 {16'h0045}; sim::add_pin "$t/O" OUT
set i 0
foreach source [dict get $r t_inputs] {
    if {$source eq "@current_reset_driver"} {set source fresh_reset_replica/Q}
    if {![dict exists $::sim::cells [file dirname $source]]} {sim::add_cell [file dirname $source] LUT1 {2'h2}}
    sim::wire $source "$t/I$i"; incr i
}
dict for {role leaves} [dict get $r outputs] {
    foreach p $leaves {sim::consumer $p; sim::wire "[dict get $r old $role cell]/O" $p}
}
foreach group [dict get $r partitions] {
    foreach p $group {
        set name [file dirname $p]
        if {![dict exists $::sim::cells $name]} {sim::add_cell $name FDRE}
        dict set ::sim::cells $name REF_NAME FDRE
        sim::wire "$t/O" $p
    }
}
# Give every preserved FF its independent D, direct C and R input. They are
# not transformed, and the final snapshot must retain their exact identities.
foreach name [dict keys $::sim::cells] {
    if {[dict get $::sim::cells $name REF_NAME] ne "FDRE"} {continue}
    foreach port {D C R} {
        if {![dict exists $::sim::pins "$name/$port"]} {
            set source "mock_${port}/Q"
            if {![dict exists $::sim::cells "mock_$port"]} {sim::add_cell "mock_$port" FDRE}
            sim::wire $source "$name/$port"
        }
    }
}
set ::sim::edits 0
"""


def run_tcl(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    """Run the production Tcl with the finite mock, never a native tool."""
    harness = tmp_path / "netlist.tcl"
    harness.write_text(MOCK + "\n" + body)
    return subprocess.run(
        ["tclsh", str(harness), str(SCRIPT), str(tmp_path / "audit.txt")],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_transform_actual_tcl(tmp_path: Path) -> None:
    """Preserve the full logical graph and reject repeated application."""
    result = run_tcl(
        tmp_path,
        r"""
if {[::frost_l1_control_repair::apply $audit strict] != 1} {error "Expected application"}
set f [open $audit]; set data [read $f]; close $f
if {[dict get $data proof ones] != 588 || [dict get $data valid_leaves] != 31} {error "Incorrect final function/ownership"}
# A second invocation encounters the changed graph and must skip without edits.
set before $::sim::edits
if {[::frost_l1_control_repair::apply $audit auto] != 0 || $before != $::sim::edits} {error "Repeated application mutated netlist"}
""",
    )
    assert result.returncode == 0, result.stderr
    assert "PROOF=8192" in result.stdout


@pytest.mark.parametrize(
    "mutation",
    ["init", "source", "extra_load", "protection", "lut_group", "soft_group_zero"],
)
def test_preflight_rejects_before_mutation(tmp_path: Path, mutation: str) -> None:
    """Reject altered source, function, ownership or protection before editing."""
    edits = {
        "init": "dict set ::sim::cells [dict get $r old VALID cell] INIT {32'h01000100}",
        "source": 'sim::wire fresh_reset_replica/Q "[dict get $r old READY cell]/I3"',
        "extra_load": 'sim::consumer extra/I0; sim::wire "$t/O" extra/I0',
        "protection": "dict set ::sim::cells [dict get $r old VALID cell] DONT_TOUCH 1",
        "lut_group": "dict set ::sim::cells [dict get $r old VALID cell] LUTNM paired",
        "soft_group_zero": "dict set ::sim::cells [dict get $r old VALID cell] SOFT_HLUTNM 0",
    }
    result = run_tcl(
        tmp_path,
        edits[mutation]
        + r"""
if {[::frost_l1_control_repair::apply $audit auto] != 0 || $::sim::edits != 0} {error "Mismatch edited the design"}
""",
    )
    assert result.returncode == 0, result.stderr
    assert "SKIPPED" in result.stdout


def test_partial_edit_is_fatal(tmp_path: Path) -> None:
    """Keep automatic mode fatal once any mutation has started."""
    result = run_tcl(
        tmp_path,
        r"""
set ::inject_connect_failure 1
set failed [catch {::frost_l1_control_repair::apply $audit auto} message]
set f [open $audit]; set data [read $f]; close $f
if {!$failed || [dict get $data status] ne "FAILED_AFTER_EDIT" || $::sim::edits == 0} {error "Partial failure was hidden"}
""",
    )
    assert result.returncode == 0, result.stderr


def test_proof_detects_changed_truth_table(tmp_path: Path) -> None:
    """Find a counterexample when the replacement truth table changes."""
    result = run_tcl(
        tmp_path,
        r"""
set old [dict get $r old]; set new [dict get $r new]
dict set new FINAL init {64'h2020AAA000000001}
if {![catch {::frost_l1_control_repair::prove $old $new [dict get $r boundary]} message] ||
    ![string match {*counterexample*} $message]} {error "Proof failed to detect mutation"}
""",
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("port", "key", "value", "reject"),
    [
        ("I1", "CASE_VALUE", "0", True),
        ("I1", "CASE_VALUE", "1", True),
        ("I1", "CASE_VALUE", "", False),
        ("I1", "IS_CASE_ANALYSIS", "false", False),
        ("I1", "IS_CASE_ANALYSIS", "0", False),
        ("I1", "IS_CASE_ANALYSIS", "true", True),
        ("O", "IS_TIMING_DISABLED", "false", False),
        ("O", "IS_TIMING_DISABLED", "true", True),
    ],
)
def test_replacement_pin_controls(
    tmp_path: Path, port: str, key: str, value: str, reject: bool
) -> None:
    """Distinguish literal case zero from inactive Boolean pin controls."""
    result = run_tcl(
        tmp_path,
        f'dict set ::sim::pins "[dict get $r old VALID cell]/{port}" {key} {{{value}}}\n'
        "set failed [catch {::frost_l1_control_repair::preflight $r} message]\n"
        f'if {{$failed != {int(reject)} || $::sim::edits != 0}} {{error "Incorrect pin-control guard: $message"}}\n',
    )
    assert result.returncode == 0, result.stderr
