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

"""Exercise the native gate protocol with controlled timing-engine responses."""

import os
from pathlib import Path
import subprocess

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MODEL = r"""
proc current_design {} {return design}
proc get_clocks {name} {
    if {$name ne "clock_from_mmcm"} {error "Unexpected clock selector"}
    return clock_from_mmcm
}
proc get_property {key object} {
    global env
    switch -- $key {
        PART {return $env(PART)}
        PERIOD {return $env(PERIOD)}
        SLACK {return $env(SLACK)}
        STARTPOINT_CLOCK - ENDPOINT_CLOCK - GROUP {return $env(PATH_CLOCK)}
        default {error "Unexpected property $key"}
    }
}
proc get_timing_paths {args} {
    global env
    if {[lrange $args 0 7] ne {-delay_type max -sort_by slack -max_paths 1 -nworst 1}} {
        error "Changed global query scope"
    }
    if {[lsearch -exact $args -slack_lesser_than] >= 0} {
        if {[lrange $args 8 end] ne {-slack_lesser_than -0.200}} {
            error "Changed strict gate"
        }
        if {$env(BELOW)} {return below_path}
        return {}
    }
    if {[lsearch -exact $args -from] >= 0} {
        if {[lrange $args 8 end] ne {-from clock_from_mmcm -to clock_from_mmcm}} {
            error "Changed CPU control scope"
        }
        if {$env(EMPTY_CPU)} {return {}}
        return cpu_path
    }
    if {$env(EMPTY_GLOBAL)} {return {}}
    return global_path
}
proc report_timing {args} {
    global env
    if {[llength $args] != 4 || [lindex $args 0] ne "-of_objects" ||
        [lindex $args 2] ne "-file"} {error "Report must use actual returned object"}
    set f [open [lindex $args 3] w]
    puts $f "| Design State : $env(STATE)"
    puts $f "Path Type: Setup (Max at Slow Process Corner)"
    puts $f "Requirement: $env(PERIOD)ns"
    puts $f "clocked by clock_from_mmcm  period=$env(PERIOD)ns"
    puts $f "clocked by clock_from_mmcm  period=$env(PERIOD)ns"
    puts $f "Clock Uncertainty: 0.054ns ((TSJ^2 + DJ^2)^1/2) / 2 + PE"
    if {$env(UU) ne "implicit"} {puts $f "User Uncertainty (UU): $env(UU)ns"}
    close $f
}
proc set_clock_uncertainty {args} {error "Gate must not change constraints"}
source [lindex $argv 0]
::frost_x3_post_place_gate::write [lindex $argv 1]
"""


def run_gate(tmp_path: Path, **overrides: str) -> subprocess.CompletedProcess[str]:
    """Run the actual gate with deterministic timing responses and stale evidence."""
    model = tmp_path / "model.tcl"
    model.write_text(MODEL)
    # A failed new measurement must never leave a previous passing audit behind.
    (tmp_path / "post_place_gate.txt").write_text("STATUS=PASS\n")
    settings = {
        "PART": "xcux35-vsva1365-3-e",
        "PERIOD": "3.333",
        "SLACK": "-0.200",
        "PATH_CLOCK": "clock_from_mmcm",
        "BELOW": "0",
        "EMPTY_GLOBAL": "0",
        "EMPTY_CPU": "0",
        "STATE": "Fully Placed",
        "UU": "implicit",
        **overrides,
    }
    return subprocess.run(
        [
            "tclsh",
            str(model),
            str(REPO_ROOT / "fpga/build/x3_post_place_gate.tcl"),
            str(tmp_path),
        ],
        env={**os.environ, **settings},
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    ("slack", "below", "status"),
    [
        ("-0.200", "0", "PASS"),
        ("-0.200", "1", "FAIL"),
        ("-0.201", "1", "FAIL"),
        ("0.050", "0", "PASS"),
    ],
)
def test_calculated_threshold_decides_rounded_boundary(
    tmp_path: Path, slack: str, below: str, status: str
) -> None:
    """Calculated-slack search distinguishes results with the same printed slack."""
    result = run_gate(tmp_path, SLACK=slack, BELOW=below)
    assert result.returncode == 0, result.stderr
    fields = dict(
        line.split("=", 1)
        for line in (tmp_path / "post_place_gate.txt").read_text().splitlines()
    )
    assert fields == {
        "STATUS": status,
        "THRESHOLD_NS": "-0.200",
        "CPU_PERIOD_NS": "3.333",
        "USER_SETUP_UNCERTAINTY_NS": "0.000",
        "STRICT_BELOW_GATE_PATHS": below,
        "WORST_SLACK_NS": slack,
    }


@pytest.mark.parametrize(
    "override",
    [
        {"EMPTY_GLOBAL": "1"},
        {"EMPTY_CPU": "1"},
        {"PART": "wrong_part"},
        {"PERIOD": "0.000"},
        {"SLACK": "NaN"},
        {"PATH_CLOCK": "nic_clock_from_mmcm"},
        {"STATE": "Optimized"},
        {"UU": "0.500"},
    ],
)
def test_invalid_or_overconstrained_measurement_removes_stale_pass(
    tmp_path: Path, override: dict[str, str]
) -> None:
    """Missing paths, wrong clocks or added uncertainty cannot reuse an old PASS."""
    result = run_gate(tmp_path, **override)
    assert result.returncode != 0
    assert not (tmp_path / "post_place_gate.txt").exists()


def test_divided_clock_and_explicit_zero_uncertainty(tmp_path: Path) -> None:
    """The native gate records the actual divided clock and accepts explicit UU0."""
    result = run_gate(tmp_path, PERIOD="6.666", SLACK="0.500", UU="0.000")
    assert result.returncode == 0, result.stderr
    assert "CPU_PERIOD_NS=6.666" in (tmp_path / "post_place_gate.txt").read_text()
