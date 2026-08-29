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

import pytest

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


def test_hello_world_compile_clears_retired_init_images(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Reused app and board output directories cannot retain old replicas."""
    app_dir = tmp_path / "sw/apps/hello_world"
    output_dir = tmp_path / "board-work/hello_world"
    app_dir.mkdir(parents=True)
    output_dir.mkdir(parents=True)

    retired_names = (
        "sw_imem_even_pc_compressed.mem",
        "sw_imem_odd_pc_compressed.mem",
        "sw_imem_even_compressed_hi.mem",
        "sw_imem_odd_compressed_hi.mem",
        "sw_imem_odd_slot2_start_valid_lo.mem",
    )
    for name in retired_names:
        (output_dir / name).write_text("stale\n")

    def fake_run(command: list[str], **_kwargs: Any) -> Any:
        for assignment in command[2:]:
            _name, output_path = assignment.split("=", maxsplit=1)
            Path(output_path).write_text("generated\n")
        return fpga_build.subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(fpga_build.subprocess, "run", fake_run)

    assert fpga_build.compile_hello_world(tmp_path, output_dir, 300_000_000)
    new_init_names = (
        "sw_imem_even_pc_metadata_bit2.mem",
        "sw_imem_odd_pc_metadata_bit2.mem",
        "sw_imem_even_pc_metadata_bit3.mem",
        "sw_imem_odd_pc_metadata_bit3.mem",
        "sw_imem_even_even_local_pair_valid.mem",
        "sw_imem_odd_even_local_pair_valid.mem",
        "sw_imem_even_pairable_native_lo.mem",
        "sw_imem_odd_pairable_native_lo.mem",
        "sw_imem_even_slot2_start_valid_lo.mem",
    )
    new_init_variables = (
        "IMEM_EVEN_PC_METADATA_BIT2_FILE",
        "IMEM_ODD_PC_METADATA_BIT2_FILE",
        "IMEM_EVEN_PC_METADATA_BIT3_FILE",
        "IMEM_ODD_PC_METADATA_BIT3_FILE",
        "IMEM_EVEN_EVEN_LOCAL_PAIR_VALID_FILE",
        "IMEM_ODD_EVEN_LOCAL_PAIR_VALID_FILE",
        "IMEM_EVEN_PAIRABLE_NATIVE_LO_FILE",
        "IMEM_ODD_PAIRABLE_NATIVE_LO_FILE",
        "IMEM_EVEN_SLOT2_START_VALID_LO_FILE",
    )
    for name in new_init_names:
        assert (output_dir / name).is_file()
    for name in retired_names:
        assert not (output_dir / name).exists()

    common_mk = (REPO_ROOT / "sw/common/common.mk").read_text()
    clean_rule = common_mk[common_mk.index("clean:") :]
    for name in retired_names:
        assert name in clean_rule
    for variable, name in zip(new_init_variables, new_init_names, strict=True):
        assert f"{variable} := {name}" in common_mk
        assert f"$({variable})" in clean_rule

    generator = (REPO_ROOT / "sw/common/generate_imem_predecode_init.py").read_text()
    for option in (
        "--even-pc-metadata-bit2",
        "--odd-pc-metadata-bit2",
        "--even-pc-metadata-bit3",
        "--odd-pc-metadata-bit3",
        "--even-even-local-pair-valid",
        "--odd-even-local-pair-valid",
        "--even-pairable-native-lo",
        "--odd-pairable-native-lo",
        "--even-slot2-start-valid-lo",
    ):
        assert option in generator
    for retired_option in (
        "--even-compressed-hi",
        "--odd-compressed-hi",
        "--odd-slot2-start-valid-lo",
    ):
        assert retired_option not in generator

    build_tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    for name in new_init_names:
        assert f"read_mem [file join $software_mem_directory {name}]" in build_tcl
    assert (
        "read_mem [file join $software_mem_directory "
        "sw_imem_even_slot2_start_valid_lo.mem]" in build_tcl
    )
    for retired_name in retired_names[2:]:
        assert (
            f"read_mem [file join $software_mem_directory {retired_name}]"
            not in build_tcl
        )


def test_default_x3_sweep_contains_every_guided_pc_tail_candidate() -> None:
    """Every vetted directive/uncertainty pair stays reproducible.

    The two grid pairs must sit on the default 50 ps sweep grid; the off-grid
    0.425 seed must instead be delivered by the always-appended extra-seed
    list, and every guided pair must actually receive the PC-tail guidance.
    """
    uncertainties = fpga_build.make_x3_place_setup_uncertainties_ns(
        fpga_build.X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT
    )

    assert fpga_build.X3_PC_TAIL_GUIDED_CANDIDATES == (
        ("ExtraNetDelay_high", 0.500),
        ("ExtraPostPlacementOpt", 0.450),
        ("ExtraPostPlacementOpt", 0.425),
    )
    assert fpga_build.X3_PLACE_EXTRA_SEED_CANDIDATES == (
        ("ExtraPostPlacementOpt", 0.425),
    )
    for directive, uncertainty in fpga_build.X3_PC_TAIL_GUIDED_CANDIDATES:
        assert directive in fpga_build.X3_PLACER_SWEEP_DIRECTIVES
        assert (
            uncertainty in uncertainties
            or (directive, uncertainty) in fpga_build.X3_PLACE_EXTRA_SEED_CANDIDATES
        )
        assert fpga_build.x3_place_uses_pc_tail_guidance(directive, uncertainty)
    # The vetted extra seed is off the 50 ps grid by design: on-grid values
    # are already covered by the Cartesian sweep.
    for _, uncertainty in fpga_build.X3_PLACE_EXTRA_SEED_CANDIDATES:
        assert uncertainty not in uncertainties

    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", 0.500)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraNetDelay_high", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraNetDelay_high", 0.425)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraTimingOpt", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", None)


def test_pc_tail_audit_validation_is_fail_closed(tmp_path: Path) -> None:
    """Replica churn is accepted only with complete canonical invariants."""
    audit = tmp_path / "post_place_group_audit.txt"
    valid_audit = (
        "\n".join(
            (
                "DIRECTIVE=ExtraNetDelay_high",
                "PLACE_UNCERTAINTY_NS=0.500",
                "SCORE_UNCERTAINTY_NS=0.500",
                "START_SETS_DISJOINT=1",
                "PRE_STARTS=3",
                "PRE_COMPRESSED_STARTS=12",
                "PRE_ENDS=104",
                "PRE_PC_BITS=64",
                "PRE_STATE_ENDS=93",
                "PRE_STATE_PC_BITS=64",
                "PRE_SEQ_ENDS=63",
                "PRE_SEQ_PC_BITS=63",
                "PRE_PENDING_ENDS=1",
                "PRE_PENDING_CANONICAL=1",
                "PRE_UNION_ENDS=261",
                "POST_STARTS=3",
                "POST_COMPRESSED_STARTS=12",
                "POST_ENDS=183",
                "POST_PC_BITS=64",
                "POST_STATE_ENDS=92",
                "POST_STATE_PC_BITS=64",
                "POST_SEQ_ENDS=66",
                "POST_SEQ_PC_BITS=63",
                "POST_PENDING_ENDS=2",
                "POST_PENDING_CANONICAL=1",
                "POST_UNION_ENDS=343",
                "PRE_START_NAMES_MATCH_POST=1",
                "PRE_COMPRESSED_START_NAMES_MATCH_POST=1",
                "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_STATE_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1",
                "SCORE_STARTS=3",
                "SCORE_COMPRESSED_STARTS=12",
                "SCORE_ENDS=183",
                "SCORE_PC_BITS=64",
                "SCORE_STATE_ENDS=92",
                "SCORE_STATE_PC_BITS=64",
                "SCORE_SEQ_ENDS=66",
                "SCORE_SEQ_PC_BITS=63",
                "SCORE_PENDING_ENDS=2",
                "SCORE_PENDING_CANONICAL=1",
                "SCORE_UNION_ENDS=343",
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

    # Placement deleted one noncanonical state-PC replica (93 -> 92). Exact
    # canonical identity and bit coverage still make this a valid audit (the
    # PC families cover the full 64-bit architectural width since Phase 3 M2).
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
        valid_audit.replace("POST_ENDS=183", "POST_ENDS=31"),
        valid_audit.replace("SCORE_ENDS=183", "SCORE_ENDS=103"),
        valid_audit.replace("SCORE_ENDS=183", "SCORE_ENDS=184"),
        valid_audit.replace("POST_STATE_ENDS=92", "POST_STATE_ENDS=31"),
        valid_audit.replace("SCORE_SEQ_ENDS=66", "SCORE_SEQ_ENDS=65"),
        valid_audit.replace("PRE_UNION_ENDS=261", "PRE_UNION_ENDS=260"),
        valid_audit.replace("POST_PENDING_CANONICAL=1", "POST_PENDING_CANONICAL=2"),
        valid_audit.replace("SCORE_COMPRESSED_STARTS=12", "SCORE_COMPRESSED_STARTS=11"),
        valid_audit.replace("SCORE_PC_BITS=64", "SCORE_PC_BITS=63"),
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
            "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1",
            "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "PRE_STATE_CANONICAL_NAMES_MATCH_POST=1",
            "PRE_STATE_CANONICAL_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1",
            "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1",
            "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=0",
        ),
        valid_audit.replace(
            "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1",
            "PRE_ENDPOINTS_SUBSET_POST=1",
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
        valid_audit.replace("PRE_PC_BITS=64\n", ""),
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


def test_pc_metadata_cone_report_cannot_alias_legacy_report(tmp_path: Path) -> None:
    """The metadata cone's historical suffix cannot alias the legacy report."""
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


def test_post_opt_promotion_clears_stale_audits(tmp_path: Path) -> None:
    """Every post-opt diagnostic must describe the newly promoted DCP."""
    step_work = tmp_path / "step"
    main_work = tmp_path / "main"
    step_work.mkdir()
    main_work.mkdir()
    (step_work / "post_opt.dcp").write_bytes(b"new checkpoint")

    stale_generic_audits = (
        "audit_post_opt_check_timing.rpt",
        "audit_post_opt_exception_coverage.rpt",
        "audit_post_opt_notes.txt",
    )
    for name in stale_generic_audits:
        (main_work / name).write_text("stale generic audit\n")
    stale_fence_diagnostic = "post_opt_fence_coverage_exceptions.rpt"
    (main_work / stale_fence_diagnostic).write_text("retired exception evidence\n")
    (main_work / "audit_post_place_check_timing.rpt").write_text("unrelated audit\n")

    fpga_build.copy_results_to_main_work(
        step_work,
        main_work,
        "post_opt.dcp",
        "post_opt",
        source_report_prefix="post_opt",
    )

    assert (main_work / "post_opt.dcp").read_bytes() == b"new checkpoint"
    for name in stale_generic_audits:
        assert not (main_work / name).exists()
    assert not (main_work / stale_fence_diagnostic).exists()
    assert (main_work / "audit_post_place_check_timing.rpt").read_text() == (
        "unrelated audit\n"
    )


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
    assert "legacy and PC-metadata/pairability tail launch sets overlap" in tcl
    assert "PC-metadata/pairability tail endpoint families overlap" in tcl
    assert "validate_x3_pc_tail_start_connectivity" in tcl
    assert "launch has no timing path to its endpoint family" in tcl
    assert "u_(even|odd)_pc_metadata_bank/memory_reg_0_[01]" in tcl
    assert "u_(even|odd)_compressed_hi_bank/compressed_hi_read_q_reg/C" not in tcl
    assert "u_(even|odd)_pc_metadata_bit2_bank/bit2_read_q_reg/C" in tcl
    assert "u_(even|odd)_pc_metadata_bit3_bank/bit3_read_q_reg/C" in tcl
    assert (
        "u_(even|odd)_even_local_pair_valid_bank/" "even_local_pair_valid_read_q_reg/C"
    ) in tcl
    assert (
        "u_(even|odd)_pairable_native_lo_bank/" "pairable_native_lo_read_q_reg/C"
    ) in tcl
    assert "memory_even_slot2_start_valid_lo_reg_bram_0" in tcl
    assert "memory_odd_slot2_start_valid_lo_reg_bram_0" not in tcl
    assert "u_odd_pc_metadata_bank/memory_reg_0_3" in tcl
    assert "u_odd_slot2_start_valid_lo_bank/" not in tcl
    assert ")/CLKBWRCLK$}" in tcl
    assert "even_slot2_start_valid_lo_read_q_reg/C" not in tcl
    assert "odd_slot2_start_valid_lo_read_q_reg/C" not in tcl
    assert "sw_imem_even_pc_metadata_bit3.mem" in tcl
    assert "sw_imem_odd_pc_metadata_bit3.mem" in tcl
    assert "sw_imem_even_even_local_pair_valid.mem" in tcl
    assert "sw_imem_odd_even_local_pair_valid.mem" in tcl
    assert "sw_imem_even_pairable_native_lo.mem" in tcl
    assert "sw_imem_odd_pairable_native_lo.mem" in tcl
    assert "sw_imem_even_compressed_hi.mem" not in tcl
    assert "sw_imem_odd_compressed_hi.mem" not in tcl
    assert "sw_imem_odd_slot2_start_valid_lo.mem" not in tcl
    assert ("metadata:even:0 metadata:even:1 metadata:even:2 metadata:even:3") in tcl
    assert ("metadata:odd:0 metadata:odd:1 metadata:odd:2 metadata:odd:3") in tcl
    assert "even-local:even even-local:odd" in tcl
    assert "native-lo:even native-lo:odd" in tcl
    assert (
        "hybrid PC-metadata and pairability"
        in (REPO_ROOT / "fpga/build/build.py").read_text()
    )
    assert "does not have exactly one canonical non-replica endpoint" in tcl
    assert "expected at least one endpoint and exactly one canonical endpoint" in tcl
    assert "is not clocked exactly by clock_from_mmcm" in tcl
    assert "-filter {IS_CLOCK == 1}" in tcl
    assert "PRE_ENDS=112" not in tcl
    assert "PC-metadata tail start names differ" in tcl[place:remove_legacy_group]
    assert (
        "selected PC-tail canonical endpoint names differ"
        in tcl[place:remove_legacy_group]
    )
    assert (
        "state PC-tail canonical endpoint names differ"
        in tcl[place:remove_legacy_group]
    )
    assert (
        "sequential PC-tail canonical endpoint names differ"
        in tcl[place:remove_legacy_group]
    )
    assert (
        "pending PC-tail canonical endpoint names differ"
        in tcl[place:remove_legacy_group]
    )
    assert "require_x3_pc_tail_name_subset" not in tcl
    assert "start names differ from the post-place scope" in tcl
    assert "endpoint names differ from the post-place scope" in tcl
    assert '"PRE_PC_BITS=$x3_pc_tail_pre_bit_count"' in tcl
    assert '"PRE_STATE_PC_BITS=$x3_pc_tail_pre_state_bit_count"' in tcl
    assert '"PRE_SEQ_PC_BITS=$x3_pc_tail_pre_seq_bit_count"' in tcl
    assert '"PRE_PENDING_CANONICAL=$x3_pc_tail_pre_pending_canonical"' in tcl
    assert '"PRE_START_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_COMPRESSED_START_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_STATE_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1"' in tcl
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
    assert "noncanonical X3 PC-metadata tail scoring groups" in tcl[reopen:]
    assert "post_place_pc_compressed_tail_timing.rpt" in tcl[canonical_checkpoint:]


def test_x3_opt_does_not_except_fence_deassertion() -> None:
    """FENCE deassertion remains timed through the served-window comparators."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    assert "fence_i_committed_reg" not in tcl
    assert "apply_x3_fence_coverage_exception" not in tcl


def test_odd_pc_metadata_lane3_carries_slot2_without_changing_public_bit3() -> None:
    """Odd BRAM lane 3 is live Slot2 while scalar bit 3 keeps public metadata."""
    imem = (REPO_ROOT / "hw/rtl/cpu_and_mem/imem_predecode.sv").read_text()
    assert "memory_odd_slot2_start_valid_lo" not in imem
    assert "INIT_FILE_ODD_SLOT2_START_VALID_LO" not in imem
    assert "assign odd_slot2_start_valid_lo = odd_pc_metadata_bram[3];" in imem
    assert "module imem_odd_slot2_start_valid_lo_bank" not in imem
    assert ") u_odd_slot2_start_valid_lo_bank (" not in imem
    assert (
        ".i_write_data({\n"
        "        write_sideband[riscv_pkg::ImemSbSlot2StartValidLo],\n"
        "        write_sideband[riscv_pkg::ImemSbPairableCompressedHi],\n"
        "        write_sideband[1:0]\n"
        "      })" in imem
    )
    assert (
        "odd_pc_metadata_bit3, odd_pc_metadata_bit2, odd_pc_metadata_bram[1:0]" in imem
    )
    assert (
        "assert (odd_pc_metadata_bram[3] == "
        "odd_sideband[riscv_pkg::ImemSbSlot2StartValidLo]);" in imem
    )

    generator = (REPO_ROOT / "sw/common/generate_imem_predecode_init.py").read_text()
    assert "def make_pc_metadata_bank_replica(" in generator
    assert (
        "make_pc_metadata_bank_replica(word, sideband, is_odd_bank=True)" in generator
    )
    assert "--odd-slot2-start-valid-lo" not in generator

    cpu_and_mem = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.sv").read_text()
    assert "bram_fetch_odd_slot2_start_valid_lo_read_available" not in cpu_and_mem
    assert "bram_fetch_compressed_hi_read_available" not in cpu_and_mem
    assert "bram_fetch_pa_valid_q <= fetch_pa_ok;" in cpu_and_mem


def test_compressed_hi_uses_bram_backed_timing_lanes() -> None:
    """Both parity size lanes use the canonical registered BRAM outputs."""
    imem = (REPO_ROOT / "hw/rtl/cpu_and_mem/imem_predecode.sv").read_text()
    assert "module imem_compressed_hi_bank" not in imem
    assert ") u_even_compressed_hi_bank (" not in imem
    assert ") u_odd_compressed_hi_bank (" not in imem
    assert "even_pc_metadata_bit2, even_pc_metadata_bram[1:0]" in imem
    assert "odd_pc_metadata_bit2, odd_pc_metadata_bram[1:0]" in imem
    assert "even_sideband_with_fast_metadata[1:0] = even_compressed[1:0];" in imem
    assert "odd_sideband_with_fast_metadata[1:0] = odd_compressed[1:0];" in imem
    assert "pc_metadata_compare_valid_q <= i_port_b_enable;" in imem

    generator = (REPO_ROOT / "sw/common/generate_imem_predecode_init.py").read_text()
    assert "def make_compressed_hi_replica(" not in generator
    assert "--even-compressed-hi" not in generator
    assert "--odd-compressed-hi" not in generator


def test_x3_flow_carries_no_timing_exceptions() -> None:
    """Every X3 path is timed: no false, multicycle, or max-delay exceptions.

    A functional false path through the front end would need the released
    control to be stable across the cycle before every sensitive cycle; the
    prediction-release companion can arm a pending episode in the very next
    cycle, so no such cut is sound. The one that was tried was worth 12 ps of
    post-opt WNS and was retired.
    """
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    for exception in ("set_false_path", "set_multicycle_path", "set_max_delay"):
        assert exception not in tcl
    assert "prediction_release" not in tcl


def test_mispredict_dispatch_recovery_has_one_structural_gate() -> None:
    """Preflush candidates reach dispatch only through its direct flush gate."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    assert "apply_x3_mispredict_dispatch_false_path" not in tcl
    assert "mispredict-dispatch exception" not in tcl

    tracker = (
        REPO_ROOT
        / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/frontend_control/frontend_validity_tracker.sv"
    ).read_text()
    assert "output logic o_id_valid_preflush" in tracker
    assert "output logic o_id_valid_2_preflush" in tracker
    assert "assign id_valid_base_preflush = pd_valid_q && !csr_in_flight" in tracker
    assert "assign id_valid = id_valid_preflush && !dispatch_flush;" in tracker
    assert "assign id_valid_2 = id_valid_2_preflush && !dispatch_flush;" in tracker

    cpu = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text()
    assert ".o_id_valid_preflush(id_valid_preflush)" in cpu
    assert ".o_id_valid_2_preflush(id_valid_2_preflush)" in cpu
    assert ".i_valid(id_valid_preflush)" in cpu
    assert ".i_valid_2(id_valid_2_preflush)" in cpu
    assert ".i_flush(dispatch_flush)" in cpu
    assert "p_commit_recovery_dispatch_gate_is_direct" in cpu
    assert "p_commit_recovery_release_cannot_dispatch" in cpu

    dispatch = (
        REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv"
    ).read_text()
    assert "assign dispatch_valid = i_valid && !i_flush;" in dispatch
    assert "assign dispatch_valid_2 = i_valid_2 && !i_flush" in dispatch
    assert "p_flush_blocks_dispatch_side_effects" in dispatch


def test_store_queue_drain_fire_selects_parallel_priority_scans_late() -> None:
    """The address/tier fire result reaches only the final cursor mux."""
    sq = (
        REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv"
    ).read_text()
    assert "drain_mask_base[i] = sq_valid[i] && !sq_sent[i];" in sq
    assert "drain_mask_post_fire[i] =" in sq
    assert "drain_complete_fire_next ? drain_post_fire_idx_d : drain_base_idx_d" in sq
    assert "p_parallel_drain_scans_match_legacy" in sq
