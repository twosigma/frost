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
    if {$property eq "ENDPOINT_PIN"} {
        return [lindex $::endpoints [string index $object end]]
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
    if {[dict size $::groups] != 2} {error "Endpoints were not grouped"}
    puts "OPTIMIZED $args"
    if {$::env(CASE) eq "error"} {error "Optimization failed"}
    if {$::env(CASE) eq "ports"} {set ::ports moved}
}
source $::env(ENDPOINT_SCRIPT)
set failed [catch {frost_x3_endpoint_physopt::run $::env(KIND) 0.0} result]
puts "RESULT failed=$failed result=$result groups=[dict size $groups] uncertainty=$uncertainty"
"""


def run_tcl(tmp_path: Path, script: str, **env: str) -> str:
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


@pytest.mark.parametrize("kind", ("EndpointAggressive", "EndpointTargeted"))
@pytest.mark.parametrize("case", ("success", "error", "ports", "empty"))
def test_endpoint_pass_restores_constraints(
    tmp_path: Path, kind: str, case: str
) -> None:
    output = run_tcl(tmp_path, MODEL, CASE=case, KIND=kind)
    assert "groups=0 uncertainty=0.0" in output
    assert f"failed={int(case in ('error', 'ports'))}" in output
    if case == "empty":
        assert "OPTIMIZED" not in output
        assert "result=0" in output
    else:
        assert "RESTORED cpu/pc[14]/D" in output
        assert "RESTORED cpu/rob[12]/CE" in output
        assert "OPTIMIZED" in output
    if case == "error":
        assert "Optimization failed" in output
    if case == "ports":
        assert "changed board port constraints" in output


def test_disappearing_endpoint_still_restores_uncertainty(tmp_path: Path) -> None:
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
