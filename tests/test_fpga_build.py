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

"""Fast tests for the native FPGA build orchestration."""

import importlib.util
from pathlib import Path
import sys
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]


def _load_fpga_build() -> Any:
    """Load the standalone build script without adding it to mypy's graph."""
    module_path = REPO_ROOT / "fpga/build/build.py"
    spec = importlib.util.spec_from_file_location("frost_fpga_build_test", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


fpga_build: Any = _load_fpga_build()


def test_default_x3_sweep_contains_the_guided_pc_tail_candidate() -> None:
    """The established ExtraNetDelay-high/0.500 placement stays reproducible."""
    uncertainties = fpga_build.make_x3_place_setup_uncertainties_ns(
        fpga_build.X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT
    )

    assert fpga_build.X3_PC_TAIL_GUIDED_DIRECTIVE in (
        fpga_build.X3_PLACER_SWEEP_DIRECTIVES
    )
    assert uncertainties[0] == fpga_build.X3_PC_TAIL_GUIDED_UNCERTAINTY_NS
    assert fpga_build.x3_place_uses_pc_tail_guidance(
        fpga_build.X3_PC_TAIL_GUIDED_DIRECTIVE, uncertainties[0]
    )
    assert not fpga_build.x3_place_uses_pc_tail_guidance(
        "ExtraPostPlacementOpt", uncertainties[0]
    )
    assert not fpga_build.x3_place_uses_pc_tail_guidance(
        fpga_build.X3_PC_TAIL_GUIDED_DIRECTIVE, uncertainties[1]
    )


def test_pc_tail_audit_validation_is_fail_closed(tmp_path: Path) -> None:
    """Only a complete canonical clean-reopen audit is accepted."""
    audit = tmp_path / "post_place_group_audit.txt"
    audit.write_text(
        "\n".join(
            (
                "DIRECTIVE=ExtraNetDelay_high",
                "PLACE_UNCERTAINTY_NS=0.500",
                "PRE_STARTS=4",
                "PRE_ENDS=112",
                "SCORE_STARTS=4",
                "SCORE_ENDS=183",
                "LINGERING_CUSTOM_PATHS=0",
                "SCORED_GROUPS=clock_from_mmcm",
            )
        )
        + "\n"
    )

    assert fpga_build.x3_pc_tail_group_audit_is_valid(audit)

    audit.write_text(
        audit.read_text().replace(
            "LINGERING_CUSTOM_PATHS=0", "LINGERING_CUSTOM_PATHS=1"
        )
    )
    assert not fpga_build.x3_pc_tail_group_audit_is_valid(audit)


def test_place_guidance_evidence_is_promoted(tmp_path: Path) -> None:
    """The winning guided seed keeps its clean-reopen and cone evidence."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"checkpoint")
    (seed_work / "post_place_group_audit.txt").write_text("audit\n")
    (seed_work / "post_place_pc_tail_timing.rpt").write_text("timing\n")

    fpga_build.copy_results_to_main_work(
        seed_work,
        main_work,
        "post_place.dcp",
        "post_place",
        source_report_prefix="post_place",
    )

    assert (main_work / "post_place_group_audit.txt").read_text() == "audit\n"
    assert (main_work / "post_place_pc_tail_timing.rpt").read_text() == "timing\n"


def test_non_guided_winner_clears_stale_guidance_evidence(tmp_path: Path) -> None:
    """Optional audit files may never describe a different promoted DCP."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"new checkpoint")
    (main_work / "post_place_group_audit.txt").write_text("stale audit\n")
    (main_work / "post_place_pc_tail_timing.rpt").write_text("stale timing\n")

    fpga_build.copy_results_to_main_work(
        seed_work,
        main_work,
        "post_place.dcp",
        "post_place",
        source_report_prefix="post_place",
    )

    assert not (main_work / "post_place_group_audit.txt").exists()
    assert not (main_work / "post_place_pc_tail_timing.rpt").exists()


def test_pc_tail_group_is_removed_before_scoring_reports() -> None:
    """The tracked Tcl flow preserves the accepted guidance/audit ordering."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    trigger = tcl.index("set use_x3_pc_tail_group")
    place = tcl.index("place_design -directive $directive", trigger)
    add_group = tcl.index("group_path -name frost_pc_tail", trigger)
    remove_group = tcl.index("group_path -default", place)
    temporary_checkpoint = tcl.index(
        "write_checkpoint -force $work_directory/post_place.dcp", remove_group
    )
    close_design = tcl.index("close_design", temporary_checkpoint)
    reopen = tcl.index("open_checkpoint $work_directory/post_place.dcp", close_design)
    canonical_checkpoint = tcl.index(
        "write_checkpoint -force $work_directory/post_place.dcp", reopen
    )
    timing_summary = tcl.index("report_timing_summary", canonical_checkpoint)

    trigger_text = tcl[trigger:place]
    assert '$board_name eq "x3"' in trigger_text
    assert '$directive eq "ExtraNetDelay_high"' in trigger_text
    assert "abs(double($x3_place_uncertainty)" in trigger_text
    assert "starts=4 ends=112" in trigger_text
    assert add_group < place < remove_group < temporary_checkpoint
    assert temporary_checkpoint < close_design < reopen < canonical_checkpoint
    assert canonical_checkpoint < timing_summary
    assert "temporary frost_pc_tail still owns timing paths" in tcl[reopen:]
    assert "noncanonical X3 PC-tail scoring groups" in tcl[reopen:]
