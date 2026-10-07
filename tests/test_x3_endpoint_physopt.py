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

"""Constraint restoration and acceptance checks for routed endpoint phys-opt."""

import os
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "fpga/build/x3_endpoint_physopt.tcl"

MODEL = r"""
set uncertainty 0.0
set groups [dict create]
set ports original
set period 3.103
set endpoints [list {cpu/pc[14]/D} {cpu/rob[12]/CE}]
proc get_clocks {args} {return clock_from_mmcm}
proc get_timing_paths {args} {
    set group [lindex $args [expr {[lsearch -exact $args -group] + 1}]]
    if {$group eq "clock_from_mmcm"} {
        if {$::env(CASE) eq "empty"} {return {}}
        return {path0 path1}
    }
    if {[dict exists $::groups $group]} {return grouped_path}
    return {}
}
proc get_property {property object} {
    if {$property eq "NAME"} {return $object}
    if {$property eq "PERIOD"} {return $::period}
    if {$property eq "WAVEFORM"} {return {0.0 1.5515}}
    if {$property eq "REF_PIN_NAME"} {return [file tail $object]}
    if {$property eq "SLACK"} {
        if {$::env(CASE) eq "positive"} {return 0.001}
        return -0.010
    }
    if {$property eq "ENDPOINT_PIN"} {
        set result {}
        foreach path $object {
            lappend result [lindex $::endpoints [string index $path end]]
        }
        if {[llength $result] == 1} {return [lindex $result 0]}
        return $result
    }
    error "Unexpected property $property"
}
namespace eval frost_x3_local_placement {
    proc port_constraints {} {return $::ports}
    proc exact_objects {command names} {
        if {$::env(CASE) eq "disappear"} {return {}}
        return $names
    }
}
proc group_path {args} {
    set from [lindex $args [expr {[lsearch -exact $args -from] + 1}]]
    set to [lindex [lindex $args [expr {[lsearch -exact $args -to] + 1}]] 0]
    if {$from ne "clock_from_mmcm" || $to ni $::endpoints} {
        error "Group scope changed: $args"
    }
    if {[lsearch -exact $args -default] >= 0} {
        dict for {name scope} $::groups {
            if {$scope eq [list $from $to]} {dict unset ::groups $name}
        }
        puts "RESTORED $to"
    } else {
        set name [lindex $args [expr {[lsearch -exact $args -name] + 1}]]
        dict set ::groups $name [list $from $to]
    }
}
proc set_x3_setup_uncertainty {board value reason} {set ::uncertainty $value}
proc phys_opt_design {args} {
    if {abs($::uncertainty - 0.030) > 1e-9} {error "Wrong optimization margin"}
    set count [expr {$::env(KIND) eq "EndpointClockEnable" ? 1 : 2}]
    if {[dict size $::groups] != $count} {error "Endpoints were not grouped"}
    puts "OPTIMIZED $args"
    if {$::env(CASE) eq "error"} {error "Optimization failed"}
    if {$::env(CASE) eq "ports"} {set ::ports moved}
    if {$::env(CASE) eq "clock"} {set ::period 6.206}
}
source $::env(ENDPOINT_SCRIPT)
set failed [catch {frost_x3_endpoint_physopt::run $::env(KIND) 0.0} result]
puts "RESULT failed=$failed result=$result groups=[dict size $groups] uncertainty=$uncertainty"
"""


def run_tcl(tmp_path: Path, script: str, **env: str) -> str:
    """Exercise the production Tcl under a small Vivado API stand-in."""
    model = tmp_path / "model.tcl"
    model.write_text(script)
    result = subprocess.run(
        ["tclsh", str(model)],
        env={**os.environ, "ENDPOINT_SCRIPT": str(SCRIPT), **env},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


@pytest.mark.parametrize(
    "kind", ("EndpointAggressive", "EndpointTargeted", "EndpointClockEnable")
)
@pytest.mark.parametrize("case", ("success", "error", "ports", "empty", "clock"))
def test_endpoint_pass_restores_constraints(
    tmp_path: Path, kind: str, case: str
) -> None:
    """Passes remove temporary groups and margins, including on failure."""
    output = run_tcl(tmp_path, MODEL, CASE=case, KIND=kind)
    assert "groups=0 uncertainty=0.0" in output
    assert f"failed={int(case in ('error', 'ports', 'clock'))}" in output
    if case == "empty":
        assert "OPTIMIZED" not in output
        assert "result=0" in output
    else:
        assert ("RESTORED cpu/pc[14]/D" in output) == (kind != "EndpointClockEnable")
        assert "RESTORED cpu/rob[12]/CE" in output
        assert "OPTIMIZED" in output
    if case == "error":
        assert "Optimization failed" in output
    if case == "ports":
        assert "changed board port constraints" in output
    if case == "clock":
        assert "changed clock periods or waveforms" in output
    if kind == "EndpointClockEnable" and case != "empty":
        assert "OPTIMIZED -clock_opt" in output


def test_clock_enable_pass_skips_passing_endpoints(tmp_path: Path) -> None:
    """The clock-enable pass targets only failing clock-enable paths."""
    output = run_tcl(tmp_path, MODEL, CASE="positive", KIND="EndpointClockEnable")
    assert "OPTIMIZED" not in output
    assert "RESULT failed=0 result=0 groups=0 uncertainty=0.0" in output


def test_disappearing_endpoint_still_restores_uncertainty(tmp_path: Path) -> None:
    """A failed group cleanup still restores the measurement uncertainty."""
    output = run_tcl(tmp_path, MODEL, CASE="disappear", KIND="EndpointAggressive")
    assert "failed=1 result=Endpoint disappeared" in output
    assert "uncertainty=0.0" in output
    # Cleanup could not complete. The caller must discard this in-memory
    # candidate and reopen the saved best checkpoint before continuing.
    assert "groups=2" in output


@pytest.mark.parametrize(
    ("change", "expected"),
    (
        ({}, True),
        ({"whs": "-0.001", "ths": "-0.003", "hf": "1"}, False),
        ({"hf": "1"}, False),
        ({"wpws": "-0.001", "tpws": "-0.001", "pf": "1"}, False),
        ({"pf": "1"}, False),
        ({"errors": "1"}, False),
        ({"routed": "99"}, False),
        ({"routable": "0", "routed": "0"}, False),
    ),
)
def test_endpoint_candidate_requires_legal_routing_and_hold(
    tmp_path: Path, change: dict[str, str], expected: bool
) -> None:
    """Reject illegal routing and even rounded-to-zero hold or pulse failures."""
    values = {
        "whs": "0.003",
        "ths": "0.000",
        "hf": "0",
        "wpws": "0.000",
        "tpws": "0.000",
        "pf": "0",
        "errors": "0",
        "routable": "100",
        "routed": "100",
        **change,
    }
    timing = tmp_path / "timing.rpt"
    timing.write_text(
        "WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints "
        "WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints "
        "WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints\n"
        "------- ------- --------------------- -------------------\n"
        "-0.032 -0.835 95 412755 {whs} {ths} {hf} 411792 "
        "{wpws} {tpws} {pf} 131842\n".format(**values)
    )
    route = tmp_path / "route.rpt"
    route.write_text(
        "# of nets with routing errors..... : {errors}\n"
        "# of routable nets................ : {routable}\n"
        "# of fully routed nets............ : {routed}\n".format(**values)
    )
    output = run_tcl(
        tmp_path,
        "source $::env(ENDPOINT_SCRIPT)\n"
        "puts [frost_x3_endpoint_physopt::candidate_is_legal "
        "$::env(TIMING) $::env(ROUTE)]\n",
        TIMING=str(timing),
        ROUTE=str(route),
    )
    assert output.splitlines()[-1] == str(int(expected))


def test_incomplete_candidate_reports_stop_instead_of_passing(tmp_path: Path) -> None:
    """Truncated evidence cannot qualify a physical optimization candidate."""
    timing = tmp_path / "timing.rpt"
    timing.write_text("WNS(ns) TNS(ns)\n------- -------\n0.100 0.000\n")
    output = run_tcl(
        tmp_path,
        "source $::env(ENDPOINT_SCRIPT)\n"
        "puts [catch {frost_x3_endpoint_physopt::candidate_is_legal "
        "$::env(TIMING) unused.rpt} reason]\nputs $reason\n",
        TIMING=str(timing),
    )
    assert output.splitlines()[0] == "1"
    assert "Missing whole-design" in output


def test_pin_candidates_follow_failing_paths_and_respect_existing_constraints(
    tmp_path: Path,
) -> None:
    """Select critical pins while excluding locks, shared LUTs, and passing paths."""
    model = r"""
source $::env(ENDPOINT_SCRIPT)
proc get_pins {args} {return [lindex $args end]}
proc get_cells {args} {
    set object [lindex $args end]
    if {[string match */A5LUT $object]} {
        if {$object eq "SLICE_X2Y2/A5LUT"} {return occupied_companion}
        return {}
    }
    return [file dirname $object]
}
proc get_bels {args} {return [lindex $args end]}
proc get_property {property cell} {
    switch -- $property {
        REF_NAME {return LUT3}
        LOCK_PINS {
            if {$cell eq "cpu/locked"} {return I0:A2}
            return ""
        }
        BEL {return A6LUT}
        LOC {
            if {$cell eq "cpu/shared"} {return SLICE_X2Y2}
            return SLICE_X1Y1
        }
        REF_PIN_NAME {return [file tail $cell]}
    }
    error "Unexpected property $property"
}
namespace eval frost_x3_local_placement {
    proc pin_map {cell} {
        if {$cell eq "cpu/fast"} {return {I0 A6 I1 A2}}
        return {I0 A2 I1 A6}
    }
}
set report {
Slack (VIOLATED) : -0.012ns
    SLICE_X1Y1 r cpu/slow/I0
    SLICE_X1Y1 r cpu/locked/I0
    SLICE_X2Y2 r cpu/shared/I0
    SLICE_X1Y1 f cpu/fast/I0
    SLICE_X1Y1 r cpu/near_endpoint/I0
Slack (VIOLATED) : -0.008ns
    SLICE_X1Y1 r cpu/slow/I0
Slack (MET) : 0.010ns
    SLICE_X1Y1 r cpu/passing/I0
}
puts [frost_x3_endpoint_physopt::pin_candidates $report]
"""
    output = run_tcl(tmp_path, model)
    assert output.strip() == "cpu/near_endpoint/I0 cpu/slow/I0"


@pytest.mark.parametrize(
    ("candidate", "expected"),
    (
        ("{-0.011 -0.100}", True),
        ("{-0.012 -0.030}", True),
        ("{-0.012 -0.043}", False),
        ("{-0.013 0.000}", False),
        ("{}", False),
    ),
)
def test_pin_search_requires_global_timing_improvement(
    tmp_path: Path, candidate: str, expected: bool
) -> None:
    """A local improvement must also satisfy the global WNS/TNS ordering."""
    output = run_tcl(
        tmp_path,
        "source $::env(ENDPOINT_SCRIPT)\n"
        f"puts [frost_x3_endpoint_physopt::score_improves {candidate} {{-0.012 -0.043}}]\n",
    )
    assert output.strip() == str(int(expected))


@pytest.mark.parametrize("failure", ("routing", "logic", "worse"))
def test_pin_search_restores_checkpoint_after_each_rejected_trial(
    tmp_path: Path, failure: str
) -> None:
    """Every error or timing regression rolls back the full routed design."""
    # The router is represented by state transitions. A failed second trial
    # must restore the first accepted result, including its physical state,
    # before the next candidate can run.
    model = r"""
source $::env(ENDPOINT_SCRIPT)
set state initial
set trial 0
set saved [dict create]
proc get_timing_paths {args} {return {path0 path1}}
proc report_timing {args} {return report}
proc get_pins {args} {return [lindex $args end]}
proc write_checkpoint {args} {
    dict set ::saved [lindex $args end] $::state
}
proc close_design {} {set ::state closed}
proc open_checkpoint {path} {set ::state [dict get $::saved $path]}
namespace eval frost_x3_endpoint_physopt {
    proc pin_candidates {report} {return {cpu/a/I0 cpu/b/I0}}
    proc remap_routed_pin {pin target} {
        incr ::trial
        if {$::trial == 1} {
            if {$::state ne "initial"} {error "Wrong initial state"}
            set ::state better
            return 1
        }
        if {$::state ne "better"} {
            puts "ROLLBACK_FAILED $::trial $::state"
            error "Previous rejected trial leaked into next candidate"
        }
        set ::state $::env(FAILURE)
        if {$::state eq "logic"} {error "Changed logical connectivity"}
        return 1
    }
    proc routed_score {prefix} {
        switch -- $::state {
            initial {return {-0.032 -0.151}}
            better {return {-0.019 -0.119}}
            routing {return {}}
            worse {return {-0.040 -0.050}}
        }
        error "Illegal state $::state"
    }
}
puts "RESULT [frost_x3_endpoint_physopt::refine_pins $::env(WORK)] state=$state trials=$trial"
"""
    output = run_tcl(tmp_path, model, WORK=str(tmp_path), FAILURE=failure)
    assert "ROLLBACK_FAILED" not in output
    assert "RESULT 1 state=better trials=6" in output
    assert output.count("accepted_pin=") == 1


@pytest.mark.parametrize("case", ("success", "error", "ports", "clock", "hold"))
def test_individual_clock_trials_preserve_constraints_and_reject_illegal_results(
    tmp_path: Path, case: str
) -> None:
    """Each endpoint is an isolated trial with cleanup and full-state rollback."""
    model = (
        MODEL.split("source $::env(ENDPOINT_SCRIPT)")[0]
        + r"""
set tns -0.151
set checkpoints [dict create]
rename get_timing_paths model_get_timing_paths
proc get_timing_paths {args} {
    if {[lsearch -exact $args -to] >= 0} {return path0}
    return [model_get_timing_paths {*}$args]
}
proc write_checkpoint {args} {
    dict set ::checkpoints [lindex $args end] \
        [list $::ports $::period $::uncertainty $::groups $::tns]
}
proc close_design {} {set ::ports closed}
proc open_checkpoint {path} {
    lassign [dict get $::checkpoints $path] \
        ::ports ::period ::uncertainty ::groups ::tns
}
proc phys_opt_design {args} {
    if {[dict size $::groups] != 1 || abs($::uncertainty - 0.030) > 1e-9} {
        error "Clock optimization did not isolate exactly one endpoint"
    }
    puts "OPTIMIZED $args"
    set ::tns -0.100
    if {$::env(CASE) eq "error"} {error "Clock optimizer failed"}
    if {$::env(CASE) eq "ports"} {set ::ports moved}
    if {$::env(CASE) eq "clock"} {set ::period 6.206}
}
source $::env(ENDPOINT_SCRIPT)
namespace eval frost_x3_endpoint_physopt {
    proc routed_score {prefix} {
        if {$::env(CASE) eq "hold" && $::tns == -0.100} {return {}}
        return [list -0.032 $::tns]
    }
}
set result [frost_x3_endpoint_physopt::refine_clocks $::env(WORK) 0.0]
puts "RESULT accepted=$result ports=$ports period=$period uncertainty=$uncertainty groups=[dict size $groups] tns=$tns"
"""
    )
    output = run_tcl(tmp_path, model, WORK=str(tmp_path), CASE=case)
    assert output.count("OPTIMIZED -clock_opt") == 2
    assert "ports=original period=3.103 uncertainty=0.0 groups=0" in output
    assert f"RESULT accepted={int(case == 'success')}" in output
    assert output.strip().endswith(f"tns={-0.100 if case == 'success' else -0.151:.3f}")


@pytest.mark.parametrize("changed", ("none", "format", "physical"))
def test_pin_trials_guard_buffered_clock_routes_and_restore_existing_flags(
    tmp_path: Path, changed: str
) -> None:
    """Clock definitions alone must not omit the net after a global buffer."""
    model = r"""
source $::env(ENDPOINT_SCRIPT)
set routes [dict create source SOURCE buffered DISTRIBUTION ground GROUND]
set fixed_routes [dict create source "" buffered DISTRIBUTION ground ""]
set fixed [dict create source 0 buffered 1 ground 0]
proc get_pins {args} {return {clock_pin tied_pin}}
proc get_nets {args} {
    if {[lsearch -exact $args -top_net_of_hierarchical_group] >= 0} {
        return [lindex $args end]
    }
    if {[lsearch -exact $args -of_objects] >= 0} {
        if {[lindex $args end] eq "clock"} {return source}
        return {buffered buffered ground}
    }
    return [lindex $args end]
}
proc get_clocks {args} {
    if {[lsearch -exact $args -of_objects] >= 0 && [lindex $args end] eq "ground"} {
        return {}
    }
    return clock
}
proc get_property {property object} {
    switch -- $property {
        NAME {return $object}
        TYPE {
            if {$object eq "ground"} {return GROUND}
            return GLOBAL_CLOCK
        }
        ROUTE {return [dict get $::routes $object]}
        FIXED_ROUTE {return [dict get $::fixed_routes $object]}
        IS_ROUTE_FIXED {return [dict get $::fixed $object]}
    }
    error "Unexpected property $property"
}
proc get_nodes {args} {
    set object [lindex $args end]
    if {[dict get $::routes $object] eq "REROUTED"} {return moved_node}
    if {[dict get $::routes $object] eq "REORDERED"} {return {leaf root}}
    return {root leaf}
}
proc get_pips {args} {return root_to_leaf}
proc set_property {property value object} {
    set object [lindex $object 0]
    switch -- $property {
        IS_ROUTE_FIXED {dict set ::fixed $object [string is true -strict $value]}
        FIXED_ROUTE {dict set ::fixed_routes $object $value}
        default {error "Unexpected property $property"}
    }
}
proc reset_property {property object} {set_property $property "" $object}
namespace eval frost_x3_local_placement {
    proc exact_objects {command names} {return $names}
}
set before [frost_x3_endpoint_physopt::clock_routes]
puts "GUARDED [dict keys $before]"
dict for {name saved} $before {set_property IS_ROUTE_FIXED true $name}
if {$::env(CHANGED) eq "physical"} {dict set routes buffered REROUTED}
if {$::env(CHANGED) eq "format"} {dict set routes buffered REORDERED}
set failed [catch {frost_x3_endpoint_physopt::restore_clock_routes $before} result]
puts "RESULT failed=$failed result=$result"
if {!$failed} {
    set after [frost_x3_endpoint_physopt::clock_routes]
    set restored 1
    dict for {name saved} $before {
        if {[lrange [dict get $after $name] 1 end] ne [lrange $saved 1 end]} {set restored 0}
    }
    puts "RESTORED $restored"
}
"""
    output = run_tcl(tmp_path, model, CHANGED=changed)
    assert "GUARDED buffered source" in output
    assert f"RESULT failed={int(changed == 'physical')}" in output
    if changed == "physical":
        assert "changed clock routing: buffered" in output
    else:
        assert "RESTORED 1" in output
