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
import re
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


def _load_timing_util_summary() -> Any:
    """Load the README report formatter as a standalone module."""
    module_path = REPO_ROOT / "fpga/build/extract_timing_and_util_summary.py"
    spec = importlib.util.spec_from_file_location("frost_timing_util_test", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


timing_util_summary: Any = _load_timing_util_summary()


def test_x3_place_recipe_survives_readme_refresh(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Generated utilization prose must retain the promoted placement recipe."""
    vivado_log = """\
# Command line       : vivado -mode batch -source build_step.tcl -nojournal -tclargs x3 place ExtraNetDelay_high input.dcp 0
Set x3 CPU setup clock uncertainty to 0.5 ns (place overconstraint)
"""
    work_dir = tmp_path / "x3/work"
    work_dir.mkdir(parents=True)
    (work_dir / "post_place_util.rpt").write_text("synthetic report\n")
    (work_dir / "post_place_vivado.log").write_text(vivado_log)
    monkeypatch.setattr(
        timing_util_summary,
        "extract_utilization",
        lambda _report: {"clock_freq_mhz": 300.0},
    )

    utilization = timing_util_summary.collect_all_board_utilization(tmp_path)
    provenance = utilization["x3"]["report_provenance"]
    assert provenance == "`ExtraNetDelay_high`/0.500"

    section = timing_util_summary.format_readme_utilization_section(utilization)
    assert (
        "**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz; "
        "`ExtraNetDelay_high`/0.500 post-place report)" in section
    )


def test_hello_world_compile_clears_retired_init_images(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Reused app and board output directories cannot retain old replicas."""
    app_dir = tmp_path / "sw/apps/hello_world"
    output_dir = tmp_path / "board-work/hello_world"
    app_dir.mkdir(parents=True)
    output_dir.mkdir(parents=True)

    retired_names = fpga_build.IMEM_RETIRED_INIT_IMAGE_NAMES
    assert "sw_imem_even_pc_metadata.mem" in retired_names
    assert "sw_imem_odd_pc_metadata_bit3.mem" in retired_names
    for name in retired_names:
        (output_dir / name).write_text("stale\n")

    def fake_run(command: list[str], **_kwargs: Any) -> Any:
        for assignment in command[2:]:
            _name, output_path = assignment.split("=", maxsplit=1)
            Path(output_path).write_text("generated\n")
        return fpga_build.subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(fpga_build.subprocess, "run", fake_run)

    assert fpga_build.compile_hello_world(tmp_path, output_dir, 300_000_000)
    scalar_replicas = fpga_build.IMEM_SCALAR_REPLICA_NAMES
    assert scalar_replicas == (
        "is_compressed_lo",
        "is_compressed_hi",
        "even_local_pair_valid",
        "pairable_native_lo",
        "pairable_compressed_hi",
        "pairable_native_hi",
        "slot2_start_valid_lo",
    )
    assert fpga_build.X3_PC_TAIL_SCALAR_LAUNCH_COUNT == 2 * len(scalar_replicas)
    new_init_names = tuple(
        f"sw_imem_{parity}_{name}.mem"
        for name in scalar_replicas
        for parity in ("even", "odd")
    )
    new_init_variables = tuple(
        f"IMEM_{parity.upper()}_{name.upper()}_FILE"
        for name in scalar_replicas
        for parity in ("even", "odd")
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
        assert (
            f"$({variable})"
            in common_mk[common_mk.index("IMEM_SCALAR_INIT_FILES :=") :]
        )
    assert "$(IMEM_SCALAR_INIT_FILES)" in clean_rule

    generator = (REPO_ROOT / "sw/common/generate_imem_predecode_init.py").read_text()
    generator_replicas = re.findall(r'\("([a-z0-9_]+)", SB_[A-Z0-9_]+\)', generator)
    assert tuple(generator_replicas) == scalar_replicas
    for name in scalar_replicas:
        option = name.replace("_", "-")
        assert f"--even-{option}" in common_mk
        assert f"--odd-{option}" in common_mk
    for retired_option in (
        "--even-compressed-hi",
        "--odd-compressed-hi",
        "--even-pc-metadata",
        "--odd-pc-metadata",
        "--even-pc-metadata-bit2",
        "--odd-pc-metadata-bit3",
    ):
        assert retired_option not in generator
        assert retired_option not in common_mk

    build_tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    tcl_replica_list = re.search(r"foreach scalar_replica \[list ([^\]]+)\]", build_tcl)
    assert tcl_replica_list is not None
    assert (
        tuple(tcl_replica_list.group(1).replace("\\", " ").split()) == scalar_replicas
    )
    assert (
        "read_mem [file join $software_mem_directory "
        "sw_imem_even_${scalar_replica}.mem]" in build_tcl
    )
    assert (
        "read_mem [file join $software_mem_directory "
        "sw_imem_odd_${scalar_replica}.mem]" in build_tcl
    )
    for retired_name in retired_names:
        assert retired_name not in build_tcl


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
                "PRE_COMPRESSED_STARTS=14",
                "PRE_ENDS=104",
                "PRE_PC_BITS=64",
                "PRE_STATE_ENDS=93",
                "PRE_STATE_PC_BITS=64",
                "PRE_SEQ_ENDS=63",
                "PRE_SEQ_PC_BITS=63",
                "PRE_PENDING_ENDS=1",
                "PRE_PENDING_CANONICAL=1",
                "PRE_UNION_ENDS=261",
                "POST_COMPRESSED_STARTS=14",
                "POST_ENDS=183",
                "POST_PC_BITS=64",
                "POST_STATE_ENDS=92",
                "POST_STATE_PC_BITS=64",
                "POST_SEQ_ENDS=66",
                "POST_SEQ_PC_BITS=63",
                "POST_PENDING_ENDS=2",
                "POST_PENDING_CANONICAL=1",
                "POST_UNION_ENDS=343",
                "PRE_COMPRESSED_START_NAMES_MATCH_POST=1",
                "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_STATE_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1",
                "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1",
                "SCORE_COMPRESSED_STARTS=14",
                "SCORE_ENDS=183",
                "SCORE_PC_BITS=64",
                "SCORE_STATE_ENDS=92",
                "SCORE_STATE_PC_BITS=64",
                "SCORE_SEQ_ENDS=66",
                "SCORE_SEQ_PC_BITS=63",
                "SCORE_PENDING_ENDS=2",
                "SCORE_PENDING_CANONICAL=1",
                "SCORE_UNION_ENDS=343",
                "SCORE_COMPRESSED_START_NAMES_MATCH_POST=1",
                "SCORE_ENDPOINT_NAMES_MATCH_POST=1",
                "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1",
                "LINGERING_CUSTOM_PATHS=0",
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
        valid_audit.replace("SCORE_COMPRESSED_STARTS=14", "SCORE_COMPRESSED_STARTS=13"),
        valid_audit.replace("PRE_COMPRESSED_STARTS=14", "PRE_COMPRESSED_STARTS=15"),
        valid_audit.replace("SCORE_PC_BITS=64", "SCORE_PC_BITS=63"),
        valid_audit.replace("SCORE_SEQ_PC_BITS=63", "SCORE_SEQ_PC_BITS=62"),
        valid_audit + "START_SETS_DISJOINT=1\n",
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
    assert (main_work / "post_place_pc_compressed_tail_timing.rpt").read_text() == (
        "compressed timing\n"
    )


def test_non_guided_winner_clears_stale_guidance_evidence(tmp_path: Path) -> None:
    """Optional audit files may never describe a different promoted DCP."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"new checkpoint")
    (main_work / "post_place_group_audit.txt").write_text("stale audit\n")
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
    """The tracked placement group is fail-closed and removed before scoring."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    trigger = tcl.index("set use_x3_pc_tail_group")
    place = tcl.index("place_design -directive $directive", trigger)
    add_compressed_group = tcl.index(
        "group_path -name frost_pc_compressed_tail", trigger
    )
    assert "group_path -name frost_pc_tail " not in tcl
    remove_compressed_group = tcl.index(
        "group_path -default -from $x3_pc_compressed_tail_starts_after", place
    )
    assert "x3_pc_tail_starts_after" not in tcl
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
    assert "PC-metadata tail endpoint families overlap" in tcl
    assert "validate_x3_pc_tail_start_connectivity" in tcl
    assert "launch has no timing path to its endpoint family" in tcl
    # Every guided launch is a pinned scalar-overlay output FF: no block-RAM
    # clock pin may be a launch, and every predicate/parity key is enumerated.
    assert (
        "u_(even|odd)_(is_compressed_lo|is_compressed_hi|even_local_pair_valid|"
        "pairable_native_lo|pairable_compressed_hi|pairable_native_hi|"
        "slot2_start_valid_lo)_bank/read_q_reg/C$"
    ) in tcl
    assert "CLKBWRCLK" not in tcl
    assert "pc_metadata_bank" not in tcl
    assert "slot2_start_valid_lo_reg_bram" not in tcl
    assert "memory_odd_sideband_reg" not in tcl
    assert '"$predicate:$parity"' in tcl
    assert "legacy" not in tcl[trigger:]
    assert "does not have exactly one canonical non-replica endpoint" in tcl
    assert "expected at least one endpoint and exactly one canonical endpoint" in tcl
    assert "is not clocked exactly by clock_from_mmcm" in tcl
    assert "-filter {IS_CLOCK == 1}" in tcl
    assert "PRE_ENDS=112" not in tcl
    assert "PC-metadata tail start names differ" in tcl[place:remove_compressed_group]
    assert (
        "selected PC-tail canonical endpoint names differ"
        in tcl[place:remove_compressed_group]
    )
    assert (
        "state PC-tail canonical endpoint names differ"
        in tcl[place:remove_compressed_group]
    )
    assert (
        "sequential PC-tail canonical endpoint names differ"
        in tcl[place:remove_compressed_group]
    )
    assert (
        "pending PC-tail canonical endpoint names differ"
        in tcl[place:remove_compressed_group]
    )
    assert "require_x3_pc_tail_name_subset" not in tcl
    assert "start names differ from the post-place scope" in tcl
    assert "endpoint names differ from the post-place scope" in tcl
    assert '"PRE_PC_BITS=$x3_pc_tail_pre_bit_count"' in tcl
    assert '"PRE_STATE_PC_BITS=$x3_pc_tail_pre_state_bit_count"' in tcl
    assert '"PRE_SEQ_PC_BITS=$x3_pc_tail_pre_seq_bit_count"' in tcl
    assert '"PRE_PENDING_CANONICAL=$x3_pc_tail_pre_pending_canonical"' in tcl
    assert "PRE_STARTS=" not in tcl
    assert "START_SETS_DISJOINT" not in tcl
    assert '"PRE_START_NAMES_MATCH_POST=1"' not in tcl
    assert '"PRE_COMPRESSED_START_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_STATE_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1"' in tcl
    assert '"SCORE_PC_BITS=$x3_pc_tail_score_bit_count"' in tcl
    assert '"SCORE_START_NAMES_MATCH_POST=1"' not in tcl
    assert '"SCORED_GROUPS=' not in tcl
    assert '"SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1"' in tcl
    assert '"DIRECTIVE=$directive"' in tcl
    assert '"PLACE_UNCERTAINTY_NS=[format %.3f $x3_place_uncertainty]"' in tcl
    assert (
        '"SCORE_UNCERTAINTY_NS=[format %.3f ' '$x3_place_baseline_uncertainty]"' in tcl
    )
    assert add_compressed_group < place
    assert place < remove_compressed_group < temporary_checkpoint
    assert remove_compressed_group < restore_scoring_uncertainty
    assert restore_scoring_uncertainty < temporary_checkpoint
    assert temporary_checkpoint < close_design < reopen < canonical_checkpoint
    assert reopen < restore_reopen_uncertainty < canonical_checkpoint
    assert canonical_checkpoint < timing_summary
    assert "set x3_pc_tail_group_name frost_pc_compressed_tail" in tcl[reopen:]
    assert "temporary $x3_pc_tail_group_name still owns timing paths" in tcl[reopen:]
    assert "noncanonical X3 PC-tail scoring groups" not in tcl
    assert "noncanonical X3 PC-metadata tail scoring groups" in tcl[reopen:]
    assert "post_place_pc_tail_timing.rpt" not in tcl
    assert "post_place_pc_compressed_tail_timing.rpt" in tcl[canonical_checkpoint:]


def test_x3_opt_does_not_except_fence_deassertion() -> None:
    """FENCE deassertion remains timed through the served-window comparators."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    assert "fence_i_committed_reg" not in tcl
    assert "apply_x3_fence_coverage_exception" not in tcl


def test_predecode_metadata_uses_pinned_scalar_overlay() -> None:
    """IF PC metadata uses a bounded overlay and folded slow fallback.

    The low 16 KiB launches through the small per-predicate LUTRAM copies. The
    canonical sideband block RAM remains the full-depth equivalence oracle but
    never directly supplies the seven PC predicates. Outside the overlay,
    a repeated request aligns raw payload with predicates redecoded into the
    same scalar-bank output FFs, without a second register or output mux.
    """
    imem = (REPO_ROOT / "hw/rtl/cpu_and_mem/imem_predecode.sv").read_text()
    assert len(re.findall(r"^module ", imem, re.M)) == 2
    assert "module imem_sideband_scalar_bank #(" in imem
    assert "parameter int unsigned PC_METADATA_OVERLAY_ADDR_WIDTH" in imem
    assert "(ADDR_WIDTH > 12) ? 11 : ADDR_WIDTH - 1" in imem
    assert '(* keep = "true" *) logic read_q;' in imem
    assert "input logic i_read_overlay_hit" in imem
    assert "input logic i_slow_read_data" in imem
    assert re.search(
        r"read_q\s*<=\s*i_read_overlay_hit\s*\?\s*"
        r"memory_read_data\[0\]\s*:\s*i_slow_read_data;",
        imem,
    )
    for predicate in fpga_build.IMEM_SCALAR_REPLICA_NAMES:
        sideband_name = "ImemSb" + "".join(
            word.capitalize() for word in predicate.split("_")
        )
        for parity in ("even", "odd"):
            assert f") u_{parity}_{predicate}_bank (" in imem
            assert f".o_read_data({parity}_{predicate})" in imem
            assert ".i_read_overlay_hit(pc_metadata_overlay_window_hit)" in imem
            assert re.search(
                rf"\.i_slow_read_data\(\s*"
                rf"{parity}_sideband_redecoded\[riscv_pkg::{sideband_name}\]\s*\)",
                imem,
            )
            assert re.search(
                rf"INIT_FILE_{parity.upper()}_{predicate.upper()} =\s*"
                rf'"sw_imem_{parity}_{predicate}\.mem"',
                imem,
            )
    assert len(
        re.findall(
            r"^\s*(?:\(\* dont_touch = \"yes\" \*\) )?imem_sideband_scalar_bank #\(",
            imem,
            re.M,
        )
    ) == (fpga_build.X3_PC_TAIL_SCALAR_LAUNCH_COUNT)
    assert (
        imem.count(".STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH)")
        == fpga_build.X3_PC_TAIL_SCALAR_LAUNCH_COUNT
    )
    assert (
        imem.count(".i_read_overlay_hit(pc_metadata_overlay_window_hit)")
        == fpga_build.X3_PC_TAIL_SCALAR_LAUNCH_COUNT
    )
    assert imem.count(".i_slow_read_data(") == fpga_build.X3_PC_TAIL_SCALAR_LAUNCH_COUNT
    assert "pc_metadata_overlay_window_hit_q <= pc_metadata_overlay_window_hit;" in imem
    assert "pc_metadata_response_ready_q <=" in imem
    assert "i_port_b_byte_address == pc_metadata_response_address_q" in imem
    assert "i_port_b_next_byte_address == pc_metadata_response_next_address_q" in imem
    assert "pc_metadata_response_history_valid_q <= 1'b0;" in imem
    for parity in ("even", "odd"):
        assert re.search(
            rf"riscv_pkg::imem_make_sideband\(\s*"
            rf"{parity}_read_data_with_fast_rvc_fields\s*\)",
            imem,
        )
    assert "_slow_q" not in imem
    assert "pc_metadata_overlay_window_hit_q ?" not in imem
    for retired in (
        "imem_pc_metadata_bank",
        "pc_metadata_bit2",
        "pc_metadata_bit3",
        "memory_even_slot2_start_valid_lo",
        "memory_odd_slot2_start_valid_lo",
        "INIT_FILE_EVEN_PC_METADATA",
        "INIT_FILE_ODD_PC_METADATA",
    ):
        assert retired not in imem
    assert "logic [FastLaneWidth-1:0] memory_even_compressed[HalfDepth];" in imem
    assert "localparam int unsigned FastLaneWidth = 5;" in imem
    assert "even_sideband_with_fast_metadata[1:0] = even_pc_metadata[1:0];" in imem
    assert "odd_sideband_with_fast_metadata[1:0] = odd_pc_metadata[1:0];" in imem
    overwritten_predicates = {
        "ImemSbEvenLocalPairValid": "even_local_pair_valid",
        "ImemSbPairableNativeLo": "pairable_native_lo",
        "ImemSbPairableCompressedHi": "pc_metadata[2]",
        "ImemSbPairableNativeHi": "pc_metadata[3]",
        "ImemSbSlot2StartValidLo": "slot2_start_valid_lo",
    }
    for parity in ("even", "odd"):
        for sideband_name, source_name in overwritten_predicates.items():
            assert re.search(
                rf"{parity}_sideband_with_fast_metadata"
                rf"\[riscv_pkg::{sideband_name}\]\s*=\s*"
                rf"{parity}_{re.escape(source_name)};",
                imem,
            )
    assert "pc_metadata_compare_valid_q <= i_port_b_enable;" in imem
    for predicate in (
        "even_local_pair_valid",
        "pairable_native_lo",
        "slot2_start_valid_lo",
    ):
        for parity in ("even", "odd"):
            assert f"p_{parity}_{predicate}_matches_bram" in imem
    assert "p_even_pc_metadata_matches_canonical" in imem
    assert "p_odd_pc_metadata_matches_canonical" in imem
    assert "matches_bram :\n      assert (even_pc_metadata" not in imem

    generator = (REPO_ROOT / "sw/common/generate_imem_predecode_init.py").read_text()
    assert "def make_sideband_bit_replica(" in generator
    assert "FAST_REPLICA_WIDTH = 5" in generator
    assert "make_pc_metadata_bank_replica" not in generator
    assert "make_compressed_hi_replica" not in generator

    cpu_and_mem = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.sv").read_text()
    fetch_provider = (REPO_ROOT / "hw/rtl/cpu_and_mem/fetch_provider.sv").read_text()
    assert "bram_fetch_odd_slot2_start_valid_lo_read_available" not in cpu_and_mem
    assert "bram_fetch_compressed_hi_read_available" not in cpu_and_mem

    # All three low-BRAM build shapes use the common request presenter. Check
    # each generate arm separately so an accidental duplicate in one arm cannot
    # compensate for a missing instance in another.
    fuzz_start = cpu_and_mem.index("if (FETCH_VALID_FUZZ != 0) begin : gen_fetch_fuzz")
    provider_start = cpu_and_mem.index(
        "end else if (ENABLE_CACHED_TIER != 0) begin : gen_fetch_provider",
        fuzz_start,
    )
    direct_start = cpu_and_mem.index(
        "end else begin : gen_fetch_direct", provider_start
    )
    fetch_assertions_start = cpu_and_mem.index("`ifndef SYNTHESIS", direct_start)
    fuzz_block = cpu_and_mem[fuzz_start:provider_start]
    provider_block = cpu_and_mem[provider_start:direct_start]
    direct_block = cpu_and_mem[direct_start:fetch_assertions_start]
    for block in (fuzz_block, provider_block, direct_block):
        assert block.count("low_bram_fetch_presenter u_low_bram_fetch_presenter") == 1
        assert block.count(".i_response_ready(bram_fetch_response_ready)") == 1
        assert block.count(".i_response_claim(fetch_live_claim)") == 1
        assert block.count(".o_response_valid(low_bram_response_valid)") == 1

    assert "assign fuzz_publish_hold = !fuzz_ok || pipeline_stall_q;" in fuzz_block
    assert "assign instruction_valid = low_bram_response_valid;" in fuzz_block
    assert ".i_response_overlay_hit(1'b0)" in fuzz_block
    assert ".i_publish_hold(fuzz_publish_hold)" in fuzz_block
    assert ".i_owner_low(1'b1)" in fuzz_block
    assert ".i_retarget(fetch_redirect)" in fuzz_block
    assert "pipeline_stall_q <= pipeline_stall;" in fuzz_block
    for retired_fuzz_state in (
        "fuzz_launch_live",
        "fuzz_slow_published_q",
        "fuzz_live_matches_served",
        "fuzz_pins_match_served",
    ):
        assert retired_fuzz_state not in fuzz_block

    assert re.search(
        r"fetch_high_valid_q \? cached_fetch_valid_local_q\s*:\s*"
        r"low_bram_response_valid",
        provider_block,
    )
    assert "output logic o_instr_valid_next" in fetch_provider
    assert (
        "assign o_instr_valid_next = window_ready && (fetch_addr == ask_d) && "
        "!i_pipeline_stall;" in fetch_provider
    )
    assert "cached_fetch_valid_local_q <= cached_fetch_valid_next;" in provider_block
    assert ".o_instr_valid_next(cached_fetch_valid_next)" in provider_block
    assert "cached_fetch_valid_local_q == cached_fetch_valid" in provider_block
    assert ".i_publish_hold(low_bram_pipeline_stall_q)" in provider_block
    assert ".i_response_overlay_hit(bram_fetch_window_overlay_hit)" in provider_block
    assert "low_bram_pipeline_stall_q <= pipeline_stall;" in provider_block
    assert ".i_owner_low(!fetch_pa0[31])" in provider_block
    assert ".i_retarget(fetch_redirect || fetch_high_transition)" in provider_block

    assert "assign instruction_valid = low_bram_response_valid;" in direct_block
    assert ".i_publish_hold(low_bram_pipeline_stall_q)" in direct_block
    assert ".i_response_overlay_hit(bram_fetch_window_overlay_hit)" in direct_block
    assert "low_bram_pipeline_stall_q <= pipeline_stall;" in direct_block
    assert ".i_owner_low(1'b1)" in direct_block
    assert ".i_retarget(fetch_redirect)" in direct_block

    assert cpu_and_mem.count("low_bram_fetch_presenter u_low_bram_fetch_presenter") == 3
    assert cpu_and_mem.count(".i_response_ready(bram_fetch_response_ready)") == 3
    assert ".o_port_b_response_ready(bram_fetch_response_ready)" in cpu_and_mem
    assert ".o_port_b_window_overlay_hit(bram_fetch_window_overlay_hit)" in cpu_and_mem

    presenter = (
        REPO_ROOT / "hw/rtl/cpu_and_mem/low_bram_fetch_presenter.sv"
    ).read_text()
    assert "input logic i_response_claim" in presenter
    assert "presented_owner_low_q && presented_pa_valid_q" in presenter
    assert re.search(
        r"assign repeat_presented\s*=\s*presented_owner_low_q\s*&&\s*"
        r"presented_pa_valid_q\s*&&\s*!i_retarget\s*&&\s*"
        r"\(!i_response_ready\s*\|\|\s*"
        r"\(i_publish_hold\s*&&\s*!i_response_overlay_hit\)\);",
        presenter,
        re.S,
    )
    assert re.search(
        r"assign o_response_valid\s*=\s*i_response_overlay_hit\s*\|\|\s*"
        r"\(presented_owner_low_q\s*&&\s*presented_pa_valid_q\s*&&\s*"
        r"i_response_ready\s*&&\s*!i_publish_hold\s*&&\s*"
        r"!slow_response_published_q\);",
        presenter,
        re.S,
    )
    assert "if (i_retarget) begin" in presenter
    assert "else if (!i_publish_hold) begin" in presenter
    assert "slow_response_published_q <= live_matches_presented;" in presenter
    assert re.search(
        r"o_response_valid\s*&&\s*i_response_claim\s*&&\s*"
        r"!i_response_overlay_hit\s*&&\s*live_matches_presented;",
        presenter,
    )
    assert "pins_match_presented" not in presenter
    assert "(i_pa0 == presented_pa0_q) && (i_pa1 == presented_pa1_q)" in presenter
    assert re.search(r"\bresponse_published_q\b", presenter) is None
    for output_name, live_name, held_name in (
        ("o_fetch_address", "i_pc", "presented_pc_q"),
        ("o_fetch_pa0", "i_pa0", "presented_pa0_q"),
        ("o_fetch_pa1", "i_pa1", "presented_pa1_q"),
        ("o_fetch_pa_valid", "i_pa_valid", "presented_pa_valid_q"),
    ):
        assert (
            f"assign {output_name} = repeat_presented ? {held_name} : {live_name};"
            in presenter
        )
    assert "presented_pc_q          <= o_fetch_address;" in presenter
    assert "i_response_ready && !i_retarget" not in presenter

    if_stage = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv").read_text()
    assert "o_fetch_redirect <= pc_update_en && |(npc_sel & ~npc_seq);" in if_stage
    assert (
        "assign o_fetch_live_claim = i_instr_valid && !sel_nop && "
        "!if_stage_stall_registered;" in if_stage
    )

    cpu_and_mem_files = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.f").read_text()
    assert "cpu_and_mem/low_bram_fetch_presenter.sv" in cpu_and_mem_files


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


def test_x3_fetch_cluster_pblock_stays_retired() -> None:
    """The stale fetch attraction halo must not silently return."""
    xdc = (REPO_ROOT / "boards/x3/constr/x3.xdc").read_text()
    assert "frost_fetch_cluster" not in xdc


def test_step_arm_state_is_declared_before_first_use() -> None:
    """Vivado must not infer an implicit step wire or warn on done-state use."""
    cpu = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text()
    first_uses = {
        "step_armed_q": ".i_keep_nops(step_armed_q)",
        "step_done_q": "step_done_set || step_done_q",
        "step_done_set": "step_done_set || step_done_q",
    }
    for signal, first_use in first_uses.items():
        declarations = list(re.finditer(rf"\blogic\s+{signal}\s*;", cpu))
        assert len(declarations) == 1
        assert declarations[0].end() < cpu.index(first_use)


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
