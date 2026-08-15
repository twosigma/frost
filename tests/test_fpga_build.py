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


def test_default_x3_sweep_contains_both_guided_pc_tail_candidates() -> None:
    """Both vetted directive/uncertainty pairs stay reproducible."""
    uncertainties = fpga_build.make_x3_place_setup_uncertainties_ns(
        fpga_build.X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT
    )

    assert fpga_build.X3_PC_TAIL_GUIDED_CANDIDATES == (
        ("ExtraNetDelay_high", 0.500),
        ("ExtraPostPlacementOpt", 0.450),
    )
    for directive, uncertainty in fpga_build.X3_PC_TAIL_GUIDED_CANDIDATES:
        assert directive in fpga_build.X3_PLACER_SWEEP_DIRECTIVES
        assert uncertainty in uncertainties
        assert fpga_build.x3_place_uses_pc_tail_guidance(directive, uncertainty)

    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", 0.500)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraNetDelay_high", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraTimingOpt", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", None)


def test_pc_tail_audit_validation_is_fail_closed(tmp_path: Path) -> None:
    """Dynamic endpoint counts are accepted only with complete invariants."""
    audit = tmp_path / "post_place_group_audit.txt"
    valid_audit = (
        "\n".join(
            (
                "DIRECTIVE=ExtraNetDelay_high",
                "PLACE_UNCERTAINTY_NS=0.500",
                "SCORE_UNCERTAINTY_NS=0.500",
                "START_SETS_DISJOINT=1",
                "PRE_STARTS=4",
                "PRE_COMPRESSED_STARTS=4",
                "PRE_ENDS=104",
                "PRE_PC_BITS=32",
                "PRE_STATE_ENDS=93",
                "PRE_STATE_PC_BITS=32",
                "PRE_SEQ_ENDS=63",
                "PRE_SEQ_PC_BITS=63",
                "PRE_PENDING_ENDS=1",
                "PRE_PENDING_CANONICAL=1",
                "PRE_UNION_ENDS=261",
                "POST_STARTS=4",
                "POST_COMPRESSED_STARTS=4",
                "POST_ENDS=183",
                "POST_PC_BITS=32",
                "POST_STATE_ENDS=120",
                "POST_STATE_PC_BITS=32",
                "POST_SEQ_ENDS=66",
                "POST_SEQ_PC_BITS=63",
                "POST_PENDING_ENDS=2",
                "POST_PENDING_CANONICAL=1",
                "POST_UNION_ENDS=371",
                "PRE_START_NAMES_MATCH_POST=1",
                "PRE_COMPRESSED_START_NAMES_MATCH_POST=1",
                "PRE_ENDPOINTS_SUBSET_POST=1",
                "PRE_COMPRESSED_ENDPOINTS_SUBSET_POST=1",
                "SCORE_STARTS=4",
                "SCORE_COMPRESSED_STARTS=4",
                "SCORE_ENDS=183",
                "SCORE_PC_BITS=32",
                "SCORE_STATE_ENDS=120",
                "SCORE_STATE_PC_BITS=32",
                "SCORE_SEQ_ENDS=66",
                "SCORE_SEQ_PC_BITS=63",
                "SCORE_PENDING_ENDS=2",
                "SCORE_PENDING_CANONICAL=1",
                "SCORE_UNION_ENDS=371",
                "SCORE_START_NAMES_MATCH_POST=1",
                "SCORE_COMPRESSED_START_NAMES_MATCH_POST=1",
                "SCORE_ENDPOINT_NAMES_MATCH_POST=1",
                "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1",
                "LINGERING_CUSTOM_PATHS=0",
                "SCORED_GROUPS=clock_from_mmcm",
                "COMPRESSED_SCORED_GROUPS=clock_from_mmcm",
            )
        )
        + "\n"
    )
    audit.write_text(valid_audit)

    assert fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraNetDelay_high", 0.500
    )

    alternate_valid_audit = valid_audit.replace(
        "DIRECTIVE=ExtraNetDelay_high\nPLACE_UNCERTAINTY_NS=0.500",
        "DIRECTIVE=ExtraPostPlacementOpt\nPLACE_UNCERTAINTY_NS=0.450",
    )
    audit.write_text(alternate_valid_audit)
    assert fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraPostPlacementOpt", 0.450
    )
    assert not fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraNetDelay_high", 0.500
    )

    invalid_audits = (
        valid_audit.replace(
            "DIRECTIVE=ExtraNetDelay_high", "DIRECTIVE=ExtraPostPlacementOpt"
        ),
        valid_audit.replace("PLACE_UNCERTAINTY_NS=0.500", "PLACE_UNCERTAINTY_NS=0.450"),
        valid_audit.replace("PLACE_UNCERTAINTY_NS=0.500", "PLACE_UNCERTAINTY_NS=0.5"),
        valid_audit.replace("SCORE_UNCERTAINTY_NS=0.500", "SCORE_UNCERTAINTY_NS=0.450"),
        valid_audit.replace("SCORE_UNCERTAINTY_NS=0.500\n", ""),
        valid_audit.replace("POST_ENDS=183", "POST_ENDS=103"),
        valid_audit.replace("SCORE_ENDS=183", "SCORE_ENDS=103"),
        valid_audit.replace("SCORE_ENDS=183", "SCORE_ENDS=184"),
        valid_audit.replace("POST_STATE_ENDS=120", "POST_STATE_ENDS=92"),
        valid_audit.replace("SCORE_SEQ_ENDS=66", "SCORE_SEQ_ENDS=65"),
        valid_audit.replace("PRE_UNION_ENDS=261", "PRE_UNION_ENDS=260"),
        valid_audit.replace("POST_PENDING_CANONICAL=1", "POST_PENDING_CANONICAL=2"),
        valid_audit.replace("SCORE_COMPRESSED_STARTS=4", "SCORE_COMPRESSED_STARTS=3"),
        valid_audit.replace("SCORE_PC_BITS=32", "SCORE_PC_BITS=31"),
        valid_audit.replace("SCORE_SEQ_PC_BITS=63", "SCORE_SEQ_PC_BITS=62"),
        valid_audit.replace("START_SETS_DISJOINT=1", "START_SETS_DISJOINT=0"),
        valid_audit.replace(
            "PRE_START_NAMES_MATCH_POST=1", "PRE_START_NAMES_MATCH_POST=0"
        ),
        valid_audit.replace(
            "PRE_COMPRESSED_START_NAMES_MATCH_POST=1",
            "PRE_COMPRESSED_START_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "PRE_ENDPOINTS_SUBSET_POST=1", "PRE_ENDPOINTS_SUBSET_POST=0"
        ),
        valid_audit.replace(
            "PRE_COMPRESSED_ENDPOINTS_SUBSET_POST=1",
            "PRE_COMPRESSED_ENDPOINTS_SUBSET_POST=0",
        ),
        valid_audit.replace(
            "SCORE_START_NAMES_MATCH_POST=1",
            "SCORE_START_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "SCORE_COMPRESSED_START_NAMES_MATCH_POST=1",
            "SCORE_COMPRESSED_START_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "SCORE_ENDPOINT_NAMES_MATCH_POST=1",
            "SCORE_ENDPOINT_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1",
            "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "COMPRESSED_SCORED_GROUPS=clock_from_mmcm",
            "COMPRESSED_SCORED_GROUPS=frost_pc_compressed_tail",
        ),
        valid_audit.replace("PRE_PC_BITS=32\n", ""),
        valid_audit + "PRE_ENDS=104\n",
        valid_audit.replace("PRE_SEQ_ENDS=63", "PRE_SEQ_ENDS=not-an-int"),
        valid_audit.replace("LINGERING_CUSTOM_PATHS=0", "LINGERING_CUSTOM_PATHS=1"),
    )
    for invalid_audit in invalid_audits:
        audit.write_text(invalid_audit)
        assert not fpga_build.x3_pc_tail_group_audit_is_valid(
            audit, "ExtraNetDelay_high", 0.500
        )

    audit.write_bytes(b"\xff")
    assert not fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraNetDelay_high", 0.500
    )
    assert not fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraTimingOpt", 0.450
    )


def test_place_guidance_evidence_is_promoted(tmp_path: Path) -> None:
    """The winning guided seed keeps its clean-reopen and cone evidence."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"checkpoint")
    (seed_work / "post_place_group_audit.txt").write_text("audit\n")
    (seed_work / "post_place_pc_tail_timing.rpt").write_text("legacy timing\n")
    (seed_work / "post_place_pc_compressed_tail_timing.rpt").write_text(
        "compressed timing\n"
    )

    fpga_build.copy_results_to_main_work(
        seed_work,
        main_work,
        "post_place.dcp",
        "post_place",
        source_report_prefix="post_place",
    )

    assert (main_work / "post_place_group_audit.txt").read_text() == "audit\n"
    assert (main_work / "post_place_pc_tail_timing.rpt").read_text() == (
        "legacy timing\n"
    )
    assert (main_work / "post_place_pc_compressed_tail_timing.rpt").read_text() == (
        "compressed timing\n"
    )


def test_compressed_cone_report_cannot_alias_legacy_report(tmp_path: Path) -> None:
    """The second cone's suffix must not satisfy the legacy report lookup."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"checkpoint")
    (seed_work / "post_place_pc_compressed_tail_timing.rpt").write_text(
        "compressed only\n"
    )

    fpga_build.copy_results_to_main_work(
        seed_work,
        main_work,
        "post_place.dcp",
        "post_place",
        source_report_prefix="post_place",
    )

    assert not (main_work / "post_place_pc_tail_timing.rpt").exists()
    assert (main_work / "post_place_pc_compressed_tail_timing.rpt").read_text() == (
        "compressed only\n"
    )


def test_non_guided_winner_clears_stale_guidance_evidence(tmp_path: Path) -> None:
    """Optional audit files may never describe a different promoted DCP."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"new checkpoint")
    (main_work / "post_place_group_audit.txt").write_text("stale audit\n")
    (main_work / "post_place_pc_tail_timing.rpt").write_text("stale timing\n")
    (main_work / "post_place_pc_compressed_tail_timing.rpt").write_text(
        "stale compressed timing\n"
    )

    fpga_build.copy_results_to_main_work(
        seed_work,
        main_work,
        "post_place.dcp",
        "post_place",
        source_report_prefix="post_place",
    )

    assert not (main_work / "post_place_group_audit.txt").exists()
    assert not (main_work / "post_place_pc_tail_timing.rpt").exists()
    assert not (main_work / "post_place_pc_compressed_tail_timing.rpt").exists()


def test_pc_tail_groups_are_removed_before_scoring_reports() -> None:
    """Both tracked placement groups are fail-closed and removed before scoring."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    trigger = tcl.index("set use_x3_pc_tail_group")
    place = tcl.index("place_design -directive $directive", trigger)
    add_legacy_group = tcl.index("group_path -name frost_pc_tail", trigger)
    add_compressed_group = tcl.index(
        "group_path -name frost_pc_compressed_tail", trigger
    )
    remove_legacy_group = tcl.index(
        "group_path -default -from $x3_pc_tail_starts_after", place
    )
    remove_compressed_group = tcl.index(
        "group_path -default -from $x3_pc_compressed_tail_starts_after", place
    )
    restore_scoring_uncertainty = tcl.index(
        "set_x3_setup_uncertainty $board_name "
        '$x3_place_baseline_uncertainty "full place overconstraint',
        remove_compressed_group,
    )
    temporary_checkpoint = tcl.index(
        "write_checkpoint -force $work_directory/post_place.dcp",
        restore_scoring_uncertainty,
    )
    close_design = tcl.index("close_design", temporary_checkpoint)
    reopen = tcl.index("open_checkpoint $work_directory/post_place.dcp", close_design)
    restore_reopen_uncertainty = tcl.index(
        "set_x3_setup_uncertainty $board_name "
        '$x3_place_baseline_uncertainty "clean-reopen place scoring',
        reopen,
    )
    canonical_checkpoint = tcl.index(
        "write_checkpoint -force $work_directory/post_place.dcp", reopen
    )
    timing_summary = tcl.index("report_timing_summary", canonical_checkpoint)

    trigger_text = tcl[trigger:place]
    assert '$board_name eq "x3"' in trigger_text
    assert '$directive eq "ExtraNetDelay_high"' in trigger_text
    assert '$directive eq "ExtraPostPlacementOpt"' in trigger_text
    assert "abs(double($x3_place_uncertainty)" in trigger_text
    assert "abs(double($x3_place_uncertainty) - 0.450)" in trigger_text
    assert 'validate_x3_pc_compressed_tail_scope "pre-place"' in trigger_text
    assert "broad endpoint family is not the selected/state disjoint union" in tcl
    assert "broad endpoint namespace contains an unexpected family" in tcl
    assert "pending_prediction_valid_reg(_rep.*)?/D" in tcl
    assert "legacy and compressed PC-tail launch sets overlap" in tcl
    assert "compressed PC-tail endpoint families overlap" in tcl
    assert "does not have exactly one canonical non-replica endpoint" in tcl
    assert "expected at least one endpoint and exactly one canonical endpoint" in tcl
    assert "is not clocked exactly by clock_from_mmcm" in tcl
    assert "-filter {IS_CLOCK == 1}" in tcl
    assert "PRE_ENDS=112" not in tcl
    assert "compressed PC-tail start names differ" in tcl[place:remove_legacy_group]
    assert "require_x3_pc_tail_name_subset" in tcl[place:remove_legacy_group]
    assert "start names differ from the post-place scope" in tcl
    assert "endpoint names differ from the post-place scope" in tcl
    assert '"PRE_PC_BITS=$x3_pc_tail_pre_bit_count"' in tcl
    assert '"PRE_STATE_PC_BITS=$x3_pc_tail_pre_state_bit_count"' in tcl
    assert '"PRE_SEQ_PC_BITS=$x3_pc_tail_pre_seq_bit_count"' in tcl
    assert '"PRE_PENDING_CANONICAL=$x3_pc_tail_pre_pending_canonical"' in tcl
    assert '"PRE_START_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_COMPRESSED_START_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_ENDPOINTS_SUBSET_POST=1"' in tcl
    assert '"PRE_COMPRESSED_ENDPOINTS_SUBSET_POST=1"' in tcl
    assert '"SCORE_PC_BITS=$x3_pc_tail_score_bit_count"' in tcl
    assert '"SCORE_START_NAMES_MATCH_POST=1"' in tcl
    assert '"SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1"' in tcl
    assert '"DIRECTIVE=$directive"' in tcl
    assert '"PLACE_UNCERTAINTY_NS=[format %.3f $x3_place_uncertainty]"' in tcl
    assert (
        '"SCORE_UNCERTAINTY_NS=[format %.3f ' '$x3_place_baseline_uncertainty]"' in tcl
    )
    assert add_legacy_group < place
    assert add_compressed_group < place
    assert place < remove_legacy_group < temporary_checkpoint
    assert place < remove_compressed_group < temporary_checkpoint
    assert remove_compressed_group < restore_scoring_uncertainty
    assert restore_scoring_uncertainty < temporary_checkpoint
    assert temporary_checkpoint < close_design < reopen < canonical_checkpoint
    assert reopen < restore_reopen_uncertainty < canonical_checkpoint
    assert canonical_checkpoint < timing_summary
    assert "frost_pc_tail frost_pc_compressed_tail" in tcl[reopen:]
    assert "temporary $x3_pc_tail_group_name still owns timing paths" in tcl[reopen:]
    assert "noncanonical X3 PC-tail scoring groups" in tcl[reopen:]
    assert "noncanonical X3 compressed PC-tail scoring groups" in tcl[reopen:]
    assert "post_place_pc_compressed_tail_timing.rpt" in tcl[canonical_checkpoint:]
