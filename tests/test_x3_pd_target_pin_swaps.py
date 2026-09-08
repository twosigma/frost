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

"""Execute the production pin-refinement Tcl with bounded Vivado models."""

import os
from pathlib import Path
import subprocess

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

TCL_MODEL = r"""

set prefix subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst
set first ${prefix}/u_pd_target_compressed_candidate_i_12
set second ${prefix}/u_pd_target_compressed_candidate_i_2
set model [dict create]
foreach cell [list $first $second] ref {LUT3 LUT4} init {8'hB8 16'hBF80} site {SLICE_X63Y358 SLICE_X67Y361} map {{I0:A5 I1:A6 I2:A4} {I0:A5 I1:A6 I2:A4 I3:A3}} {
    set row [dict create NAME $cell REF_NAME $ref INIT $init LOC $site BEL SLICEL.D6LUT IS_LOC_FIXED 0 IS_BEL_FIXED 0 LOCK_PINS {} map $map]
    dict set model $cell $row
}
set original $model
set mutations {}
set place_count 0
set fail_second_once 0
set occupied_sibling 0
set broken_pin 0
proc get_property {property object} {
    global model
    if {$property eq "REF_PIN_NAME"} {return [file tail $object]}
    return [dict get $model $object $property]
}
proc get_cells {args} {
    global model occupied_sibling
    if {[lsearch -exact $args -of_objects] >= 0} {
        if {$occupied_sibling} {return unexpected_sibling}
        return {}
    }
    set name [lindex $args end]
    if {[dict exists $model $name]} {return $name}
    return {}
}
proc get_pins {args} {
    global model
    set cell [lindex $args [expr {[lsearch -exact $args -of_objects] + 1}]]
    set result {}
    foreach pair [dict get $model $cell map] {lappend result $cell/[lindex [split $pair :] 0]}
    if {[lsearch -exact $args -filter] < 0} {lappend result $cell/O}
    return $result
}
proc get_bel_pins {args} {
    global model broken_pin
    if {$broken_pin} {return {ambiguous0 ambiguous1}}
    set pin [lindex $args end]; set cell [file dirname $pin]; set logical [file tail $pin]
    foreach pair [dict get $model $cell map] {
        lassign [split $pair :] key value
        if {$key eq $logical} {return [dict get $model $cell LOC]/D6LUT/$value}
    }
    error "No mapping for $pin"
}
proc get_nets {args} {return net_[lindex $args end]}
proc get_bels {args} {return [lindex $args end]}
proc unplace_cell {cell} {
    global model mutations
    lappend mutations [list unplace_cell $cell]
    dict set model $cell LOC {}; dict set model $cell BEL {}
}
proc reset_property {property cell} {
    global model mutations
    lappend mutations [list reset_property $property $cell]
    dict set model $cell $property {}
}
proc set_property {property value cell} {
    global model mutations
    lappend mutations [list set_property $property $value $cell]
    dict set model $cell $property $value
}
proc place_cell {pair} {
    global model mutations place_count fail_second_once
    lassign $pair cell site_bel
    lappend mutations [list place_cell $pair]
    incr place_count
    if {$fail_second_once && $place_count == 2} {error "Injected second placement failure"}
    dict set model $cell LOC [file dirname $site_bel]
    dict set model $cell BEL SLICEL.[file tail $site_bel]
    dict set model $cell map [dict get $model $cell LOCK_PINS]
    dict set model $cell IS_LOC_FIXED 1; dict set model $cell IS_BEL_FIXED 1
}

set timing_queries 0
set scenario $::env(HELPER_CASE)
rename get_property base_get_property
proc get_property {property object} {
    global model original first scenario place_count
    if {$property ne "SLACK"} {return [base_get_property $property $object]}
    set applied [expr {[dict get $model $first map] ne [dict get $original $first map]}]
    if {$object eq "max_path"} {
        if {$scenario eq "rollback_timing" && $place_count >= 4} {return -0.735}
        if {$applied && $scenario in {wns_regression strict_regression rollback_timing}} {return -0.800}
        return [expr {$applied ? -0.691 : -0.734}]
    }
    return [expr {$applied && $scenario eq "whs_regression" ? -0.400 : -0.319}]
}
proc get_timing_paths {args} {
    global timing_queries
    incr timing_queries
    return [lindex $args 1]_path
}
rename place_cell base_place_cell
proc place_cell {pair} {
    global scenario place_count model second
    if {$scenario eq "rollback_failure" && $place_count >= 2} {error "Injected rollback failure"}
    base_place_cell $pair
    if {$scenario eq "logic_change" && $place_count == 2} {dict set model $second INIT 16'hFFFF}
}
source $::env(HELPER_SOURCE)
set mode auto
switch -- $scenario {
    positive - wns_regression - whs_regression - rollback_timing - logic_change {}
    strict_positive - strict_regression {set mode strict}
    mismatch - strict_mismatch {dict set model $second LOC SLICE_X1Y1; if {$scenario eq "strict_mismatch"} {set mode strict}}
    missing_cell {dict unset model $second}
    bad_ref {dict set model $second REF_NAME LUT5}
    bad_init {dict set model $second INIT 16'hFFFF}
    bad_bel {dict set model $second BEL SLICEL.C6LUT}
    bad_map {dict set model $second map {I0:A5 I1:A3 I2:A4 I3:A6}}
    loc_fixed {dict set model $second IS_LOC_FIXED 1}
    bel_fixed {dict set model $second IS_BEL_FIXED 1}
    already_locked {dict set model $second LOCK_PINS {I0:A5 I1:A6 I2:A4 I3:A3}}
    sibling_occupied {set occupied_sibling 1}
    nonunique_pin {set broken_pin 1}
    mutation_failure - rollback_failure {set fail_second_once 1}
    audit_failure {set ::env(HELPER_AUDIT) [file join $::env(HELPER_AUDIT) missing audit.txt]}
    unexpected_error {rename get_cells base_get_cells; proc get_cells {args} {error "Unexpected native query error"}}
    default {error "Unknown scenario $scenario"}
}
set prior $model
if {$scenario ne "audit_failure"} {
    set f [open $::env(HELPER_AUDIT) w]; puts $f OLD_PASS; close $f
}
set code [catch {frost_x3_pd_target_pin_swaps::apply $::env(HELPER_AUDIT) $mode} result]
set precondition_skips {mismatch missing_cell bad_ref bad_init bad_bel bad_map loc_fixed bel_fixed already_locked sibling_occupied nonunique_pin}
if {$scenario in {positive strict_positive}} {
    if {$code || $result != 1} {error "Expected application: $result"}
    foreach cell [list $first $second] map {{I0:A5 I1:A4 I2:A6} {I0:A5 I1:A3 I2:A4 I3:A6}} {
        set before [dict get $original $cell]; set after [dict get $model $cell]
        if {[dict get $after map] ne $map || [dict get $after LOCK_PINS] ne $map} {error "Wrong applied map"}
        dict set after map [dict get $before map]; dict set after LOCK_PINS {}
        if {$after ne $before} {error "Unexpected non-map change"}
    }
    if {[llength $mutations] != 12 || $timing_queries != 4} {error "Wrong mutation/timing query count"}
    set f [open $::env(HELPER_AUDIT)]; set report [read $f]; close $f
    if {![string match {*global_timing_before*global_timing_after*} $report]} {error "Missing measured audit"}
} elseif {$scenario in $precondition_skips} {
    if {$code || $result != 0 || [llength $mutations] || $timing_queries || $model ne $prior} {error "Unsafe unmatched skip: $result"}
} elseif {$scenario in {wns_regression whs_regression mutation_failure}} {
    if {$code || $result != 0 || $model ne $original} {error "Verified rollback did not skip safely: $result"}
} else {
    if {!$code} {error "Expected fatal failure, got $result"}
    if {$scenario in {strict_mismatch unexpected_error} && ([llength $mutations] || $timing_queries)} {error "Fatal precondition mutated design"}
    if {$scenario in {strict_regression audit_failure} && $model ne $original} {error "Fatal path failed to restore original state"}
    if {$scenario in {rollback_failure rollback_timing logic_change} && ![string match {*rollback failed*} $result]} {error "Rollback failure was not reported: $result"}
}
if {$scenario ni {positive strict_positive} && [file exists $::env(HELPER_AUDIT)]} {error "Skipped/failed run retained PASS audit"}
puts "PASS $scenario"
"""


@pytest.mark.parametrize(
    "scenario",
    (
        "positive",
        "strict_positive",
        "mismatch",
        "strict_mismatch",
        "missing_cell",
        "bad_ref",
        "bad_init",
        "bad_bel",
        "bad_map",
        "loc_fixed",
        "bel_fixed",
        "already_locked",
        "sibling_occupied",
        "nonunique_pin",
        "wns_regression",
        "whs_regression",
        "strict_regression",
        "mutation_failure",
        "rollback_failure",
        "rollback_timing",
        "logic_change",
        "audit_failure",
        "unexpected_error",
    ),
)
def test_pin_refinement_modes_and_failure_boundaries(
    tmp_path: Path, scenario: str
) -> None:
    """Only matched, measured non-regressing changes may keep a PASS audit."""
    script = tmp_path / "model.tcl"
    script.write_text(TCL_MODEL)
    env = dict(
        os.environ,
        HELPER_SOURCE=str(REPO_ROOT / "fpga/build/x3_pd_target_pin_swaps.tcl"),
        HELPER_CASE=scenario,
        HELPER_AUDIT=str(tmp_path / "audit.txt"),
    )
    result = subprocess.run(
        ["tclsh", str(script)],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"PASS {scenario}" in result.stdout


HOOK_MODEL = r"""
proc trace {cmd args} {
    set f [open $::env(HOOK_TRACE) a]; puts $f [list $cmd {*}$args]; close $f
}
rename source original_source
proc source {path} {
    if {[file tail $path] eq "x3_pd_target_pin_swaps.tcl"} {
        trace source_helper
        namespace eval frost_x3_pd_target_pin_swaps {
            proc apply {audit mode} {trace apply_helper $audit $mode; return 0}
        }
        return
    }
    uplevel 1 [list original_source $path]
}
proc unknown {cmd args} {
    trace $cmd {*}$args
    switch -- $cmd {
        get_clocks {return clock_from_mmcm}
        get_cells {return subsystem/u_tomasulo/u_int_rs}
        get_timing_paths {return {}}
        open_checkpoint - set_property - set_clock_uncertainty - place_design -
        write_checkpoint - report_timing_summary - report_utilization -
        report_high_fanout_nets - report_design_analysis {return {}}
        default {error "Unexpected command $cmd $args"}
    }
}
set argv [list x3 place ExtraNetDelay_high fresh_post_opt.dcp 0]
set argc [llength $argv]
source $::env(HOOK_SOURCE)
"""


@pytest.mark.parametrize("mode", (None, "", "auto", "0", "1", "invalid"))
def test_auto_hook_runs_after_scoring_and_clears_stale_audit(
    tmp_path: Path, mode: str | None
) -> None:
    """Default auto and strict use the final scoring state; disabled clears stale PASS."""
    script = tmp_path / "hook.tcl"
    script.write_text(HOOK_MODEL)
    trace = tmp_path / "trace.txt"
    trace.touch()
    audit = tmp_path / "post_place_pin_swap_audit.txt"
    audit.write_text("OLD_PASS\n")
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("FROST_")
    }
    env.update(
        HOOK_TRACE=str(trace),
        HOOK_SOURCE=str(REPO_ROOT / "fpga/build/build_step.tcl"),
        FROST_PLACE_SETUP_UNCERTAINTY="0.350",
        FROST_PLACE_CELL_BLOAT="LOW",
    )
    if mode is not None:
        env["FROST_X3_PD_TARGET_PIN_SWAPS"] = mode
    result = subprocess.run(
        ["tclsh", str(script)],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    commands = trace.read_text().splitlines()
    if mode == "invalid":
        assert result.returncode != 0
        assert not commands
        return
    assert result.returncode == 0, result.stdout + result.stderr
    assert not audit.exists()
    helper_calls = [entry for entry in commands if entry.startswith("apply_helper ")]
    if mode == "0":
        assert not helper_calls
    else:
        expected_mode = "strict" if mode == "1" else "auto"
        assert helper_calls == [f"apply_helper {audit} {expected_mode}"]
        apply_index = commands.index(helper_calls[0])
        score_index = next(
            index
            for index, command in enumerate(commands)
            if command.startswith("set_clock_uncertainty ") and "0.5 -setup" in command
        )
        checkpoint_index = next(
            index
            for index, command in enumerate(commands)
            if command.startswith("write_checkpoint ")
        )
        assert score_index < apply_index < checkpoint_index


def test_guided_hook_follows_complete_reopen_audit() -> None:
    """Qualified seeds finish canonical group checks before measuring refinement timing."""
    source = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    start = source.index('} elseif {$step eq "place"} {')
    end = source.index('} elseif {$step eq "quick_route"} {', start)
    place = source[start:end]
    assert place.index("close $x3_pc_tail_audit") < place.index(
        "frost_x3_pd_target_pin_swaps::apply"
    )
    assert place.index("frost_x3_pd_target_pin_swaps::apply") < place.rindex(
        "write_checkpoint -force"
    )


@pytest.mark.parametrize(
    ("board", "mode", "expected"),
    (
        ("x3", None, "auto"),
        ("other", None, "0"),
        ("other", "0", "0"),
        ("other", "auto", None),
        ("other", "1", None),
    ),
)
def test_pin_refinement_board_default_is_compatible(
    tmp_path: Path, board: str, mode: str | None, expected: str | None
) -> None:
    """Adding a board must not require an opt-out from an X3-only default."""
    source = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    start = source.index("    set default_pin_swaps ")
    end = source.index("    open_checkpoint $checkpoint_path", start)
    preflight = source[start:end]
    script = tmp_path / "board.tcl"
    script.write_text(
        "proc getenv_default {name fallback} {\n"
        '  if {[info exists ::env($name)] && $::env($name) ne ""} {return $::env($name)}\n'
        "  return $fallback\n}\n"
        f"set board_name {board}\nset work_directory [pwd]\n"
        + preflight
        + '\nputs "MODE=$x3_pd_target_pin_swaps"\n'
    )
    env = dict(os.environ)
    env.pop("FROST_X3_PD_TARGET_PIN_SWAPS", None)
    if mode is not None:
        env["FROST_X3_PD_TARGET_PIN_SWAPS"] = mode
    result = subprocess.run(
        ["tclsh", str(script)],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if expected is None:
        assert result.returncode != 0
    else:
        assert result.returncode == 0, result.stdout + result.stderr
        assert f"MODE={expected}" in result.stdout
