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

"""Test the diagnostic pin-swap helper and the place step's single placement."""

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
    """Only a matched swap that leaves global WNS and WHS no worse keeps a PASS audit.

    Auto mode skips a recipe mismatch, or a regression or failed swap that it
    rolled back exactly. Strict-mode mismatches and regressions, failed
    rollbacks, audit-write failures, and unexpected errors in the recipe check
    are fatal, and only a PASS leaves an audit file.
    """
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
rename proc original_proc
original_proc proc {name arguments body} {
    if {$name eq "validate_x3_pc_compressed_tail_scope"} {
        set body {
            trace validate_scope
            set r [dict create compressed_starts start compressed_start_names start]
            foreach family {selected state seq pending union} {
                dict set r ${family}_ends end_$family
                dict set r ${family}_end_names end_$family
                dict set r ${family}_canonical_end_names end_$family
                dict set r ${family}_bits 32
            }
            dict set r pending_canonical 1
            return $r
        }
    }
    uplevel 1 [list original_proc $name $arguments $body]
}
rename source original_source
proc source {path} {
    if {[file tail $path] eq "x3_flush_guidance.tcl"} {
        namespace eval frost_x3_flush_guidance {
            proc prepare {audit} {trace prepare_flush $audit}
            proc verify {audit} {
                trace verify_flush $audit
                if {[info exists ::env(HOOK_FAIL_VERIFY)]} {error "Injected invalid replica"}
            }
        }
        return
    }
    if {[file tail $path] eq "x3_pd_target_pin_swaps.tcl"} {
        trace source_helper
        namespace eval frost_x3_pd_target_pin_swaps {
            proc apply {audit mode} {trace apply_helper $audit $mode; return 0}
        }
        return
    }
    if {[file tail $path] eq "x3_post_place_gate.tcl"} {
        trace source_gate
        namespace eval frost_x3_post_place_gate {
            proc write {work_directory} {
                trace write_gate $work_directory
                puts HOOK_GATE_WRITTEN
                return 1
            }
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
        get_timing_paths {
            if {"-from" in $args && "-to" in $args} {return path}
            return {}
        }
        get_path_groups {return {}}
        get_property {
            if {[lindex $args 0] eq "GROUP"} {return clock_from_mmcm}
            error "Unexpected property request $args"
        }
        group_path - report_timing {return {}}
        open_checkpoint - close_design - read_checkpoint - set_param -
        set_property - set_clock_uncertainty - place_design -
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
@pytest.mark.parametrize("guided", [False, True])
def test_production_places_once_and_never_invokes_retired_hooks(
    tmp_path: Path, mode: str | None, guided: bool
) -> None:
    """The place step places once and runs no diagnostic helper.

    Placement controls come first; zero-uncertainty scoring, checkpoints,
    timing reports, and the gate follow in that order, and nothing after
    placement edits cells, nets, or properties. A guided seed adds its
    temporary path group before placement, removes it after, and reopens the
    design once. Stale helper audits are deleted, and
    FROST_X3_PD_TARGET_PIN_SWAPS has no effect.
    """
    script = tmp_path / "hook.tcl"
    script.write_text(HOOK_MODEL)
    trace = tmp_path / "trace.txt"
    trace.touch()
    stale = [
        tmp_path / "post_place_pin_swap_audit.txt",
        tmp_path / "post_place_flush_guidance_audit.tcldict",
    ]
    for path in stale:
        path.write_text("OLD_PASS\n")
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("FROST_")
    }
    env.update(
        HOOK_TRACE=str(trace),
        HOOK_SOURCE=str(REPO_ROOT / "fpga/build/build_step.tcl"),
        FROST_PLACE_SETUP_UNCERTAINTY="0.500" if guided else "0.350",
        FROST_PLACE_CELL_BLOAT="LOW",
        FROST_PLACE_FLUSH_INCREMENTAL="1",
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
    assert result.returncode == 0, result.stdout + result.stderr
    commands = trace.read_text().splitlines()
    assert not any(path.exists() for path in stale)
    placements = [
        i for i, command in enumerate(commands) if command.startswith("place_design")
    ]
    assert len(placements) == 1
    place = placements[0]
    assert commands[place] == "place_design -directive ExtraNetDelay_high"
    bloat = next(
        i
        for i, command in enumerate(commands)
        if command.startswith("set_property CELL_BLOAT_FACTOR")
    )
    assert bloat < place
    assert not any(
        command.startswith(
            ("apply_helper", "prepare_flush", "verify_flush", "read_checkpoint")
        )
        for command in commands
    )
    assert not any(
        command.startswith(
            (
                "set_property",
                "unplace_cell",
                "place_cell",
                "connect_net",
                "disconnect_net",
                "create_cell",
            )
        )
        for command in commands[place + 1 :]
    )
    score = next(
        i
        for i, command in enumerate(commands)
        if command.startswith("set_clock_uncertainty ") and "0.0 -setup" in command
    )
    checkpoints = [
        i
        for i, command in enumerate(commands)
        if command.startswith("write_checkpoint ")
    ]
    timing = next(
        i
        for i, command in enumerate(commands)
        if command.startswith("report_timing_summary ")
    )
    reports = [i for i, command in enumerate(commands) if command.startswith("report_")]
    gate = commands.index(f"write_gate {tmp_path}")
    assert (
        place
        < score
        < min(checkpoints)
        <= max(checkpoints)
        < timing
        <= max(reports)
        < gate
    )
    assert sum(command.startswith("write_gate ") for command in commands) == 1
    assert result.stdout.index("HOOK_GATE_WRITTEN") < result.stdout.index(
        "** DONE — place_design complete"
    )
    groups = [
        i for i, command in enumerate(commands) if command.startswith("group_path")
    ]
    if guided:
        assert len(groups) == 2 and groups[0] < place < groups[1] < score
        assert commands.count("close_design") == 1
        assert (
            len(
                [
                    command
                    for command in commands
                    if command.startswith("open_checkpoint")
                ]
            )
            == 2
        )
        assert (tmp_path / "post_place_group_audit.txt").is_file()
    else:
        assert not groups
        assert commands.count("close_design") == 0


def test_place_arm_has_no_second_placement_or_post_place_edit_commands() -> None:
    """The production arm cannot dispatch diagnostic ECO helpers."""
    source = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    start = source.index('} elseif {$step eq "place"} {')
    end = source.index('} elseif {$step eq "quick_route"} {', start)
    body = source[start:end]
    assert body.count("place_design -directive $directive") == 1
    assert "read_checkpoint" not in body
    assert "x3_pd_target_pin_swaps.tcl" not in body
    assert "x3_flush_guidance.tcl" not in body
    after = body.split("place_design -directive $directive", 1)[1]
    for command in (
        "place_cell",
        "unplace_cell",
        "connect_net",
        "disconnect_net",
        "create_cell",
        "remove_cell",
        "phys_opt_design",
    ):
        assert command not in after
