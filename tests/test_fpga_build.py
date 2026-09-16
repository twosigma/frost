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
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
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


def _write_place_gate(work_dir: Path, wns: float = -0.1, *, bind: bool = False) -> None:
    """Model the native gate producer; hashes are only added for promotions."""
    passed = wns >= -0.2
    (work_dir / "post_place_gate.txt").write_text(
        f"STATUS={'PASS' if passed else 'FAIL'}\n"
        "THRESHOLD_NS=-0.200\nCPU_PERIOD_NS=3.333\n"
        "USER_SETUP_UNCERTAINTY_NS=0.000\n"
        f"STRICT_BELOW_GATE_PATHS={0 if passed else 1}\n"
        f"WORST_SLACK_NS={wns}\n"
    )
    if bind:
        assert fpga_build.bind_x3_place_gate(work_dir, wns)


def _write_qualified_descendant(
    work_dir: Path, stage: str, *, final: bool = False
) -> Path:
    """Create a simulated completed downstream output through the real binder."""
    consumed = fpga_build.capture_x3_input_lineage(
        work_dir, fpga_build.STEP_REQUIRES_CHECKPOINT[stage]
    )
    assert consumed is not None
    source_dir = work_dir / f"fixture_{stage}"
    source_dir.mkdir(exist_ok=True)
    source = source_dir / f"{fpga_build._TCL_REPORT_PREFIX[stage]}.dcp"
    source.write_bytes(f"completed {stage}".encode())
    name = "final.dcp" if final else fpga_build.STEP_PRODUCES_CHECKPOINT[stage]
    output = work_dir / name
    output.write_bytes(source.read_bytes())
    assert fpga_build.bind_x3_output_lineage(work_dir, stage, name, source, consumed)
    return output


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


def _write_stage_utilization(work_dir: Path, stage: str, luts: int) -> None:
    """Write minimal parseable utilization and matching timing fixtures."""
    (work_dir / f"{stage}_util.rpt").write_text(
        f"| CLB LUTs | {luts} | 0 | 0 | 1000 | {luts / 10:.1f} |\n"
    )
    (work_dir / f"{stage}_timing.rpt").write_text(
        "WNS(ns) TNS(ns) Failing Total WHS THS Failing Total\n"
        "------- -------\n"
        "-0.100 -1.000 1 10 0.010 0.000 0 10\n"
        "clock_from_mmcm {0.000 1.667} 3.333 300.000\n"
    )


@pytest.mark.parametrize("override_stage", (None, "post_opt", "post_place"))
@pytest.mark.parametrize("pin_refinement", (False, True))
def test_readme_stage_override_ignores_stale_later_reports(
    tmp_path: Path, override_stage: str | None, pin_refinement: bool
) -> None:
    """Explicit opt/place wins; default collection still prefers final."""
    work_dir = tmp_path / "x3/work"
    work_dir.mkdir(parents=True)
    for stage, luts in (
        ("post_route", 900),
        ("final", 999),
        ("post_opt", 40),
        ("post_place", 42),
    ):
        _write_stage_utilization(work_dir, stage, luts)
    refinement_marker = (
        "Applied two X3 PD target physical pin maps; logical function, "
        "location and fixed flags unchanged"
    )
    (work_dir / "post_place_vivado.log").write_text(
        "# Command line : vivado -tclargs x3 place ExtraNetDelay_high input.dcp 0\n"
        "Set x3 CPU setup clock uncertainty to 0.35 ns (place overconstraint)\n"
        "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
        f'# puts "{refinement_marker}"\n'
        + (f"{refinement_marker}\n" if pin_refinement else "")
    )

    all_util = timing_util_summary.collect_all_board_utilization(
        tmp_path,
        stage_overrides={"x3": override_stage} if override_stage else None,
    )
    util = all_util["x3"]
    assert util["stage"] == (override_stage or "final")
    assert (
        util["luts_used"]
        == {None: 999, "post_opt": 40, "post_place": 42}[override_stage]
    )
    assert util["clock_freq_mhz"] == 300.0
    assert util["timing_met"] is False
    if override_stage == "post_place":
        provenance = (
            "`ExtraNetDelay_high`/0.350"
            " + LOW CELL_BLOAT_FACTOR on `*u_tomasulo/u_int_rs`"
        )
        if pin_refinement:
            provenance += " + PD target pin refinement"
        assert util["report_provenance"] == provenance
        assert provenance in timing_util_summary.format_readme_utilization_section(
            all_util
        )
    else:
        assert "report_provenance" not in util


@pytest.mark.parametrize("stage", ("post_opt", "post_place"))
@pytest.mark.parametrize("missing_report", ("util", "timing"))
def test_readme_missing_selected_report_never_falls_back(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], stage: str, missing_report: str
) -> None:
    """A missing selected report warns instead of borrowing stale final data."""
    work_dir = tmp_path / "x3/work"
    work_dir.mkdir(parents=True)
    _write_stage_utilization(work_dir, "final", 999)
    _write_stage_utilization(work_dir, stage, 42)
    (work_dir / f"{stage}_{missing_report}.rpt").unlink()

    all_util = timing_util_summary.collect_all_board_utilization(
        tmp_path, stage_overrides={"x3": stage}
    )
    warning = capsys.readouterr().out
    assert "Warning: Selected" in warning
    assert f"{stage}_{missing_report}.rpt" in warning
    if missing_report == "util":
        assert "x3" not in all_util
    else:
        assert all_util["x3"] == {
            "luts_used": 42,
            "luts_available": 1000,
            "luts_percent": 4.2,
            "stage": stage,
        }


def test_readme_stage_override_leaves_other_boards_on_default_selection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only the active board's report stage is pinned by a partial build."""
    monkeypatch.setitem(timing_util_summary.BOARD_INFO, "other", {})
    for board in ("x3", "other"):
        work_dir = tmp_path / board / "work"
        work_dir.mkdir(parents=True)
        _write_stage_utilization(work_dir, "final", 999)
        _write_stage_utilization(work_dir, "post_opt", 42)
    all_util = timing_util_summary.collect_all_board_utilization(
        tmp_path, stage_overrides={"x3": "post_opt"}
    )
    assert all_util["x3"]["stage"] == "post_opt"
    assert all_util["other"]["stage"] == "final"


@pytest.mark.parametrize(
    ("step", "report_prefix", "report_available"),
    (
        ("opt", "post_opt", True),
        ("place", "post_place", True),
        ("route", "final", True),
        ("opt", "post_opt", False),
        ("place", "post_place", False),
    ),
)
def test_build_main_refreshes_actual_completed_report_stage(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    step: str,
    report_prefix: str,
    report_available: bool,
) -> None:
    """The real CLI passes its returned report prefix, not a stale-file guess."""
    script_dir = tmp_path / "fpga/build"
    work_dir = script_dir / "x3/work"
    work_dir.mkdir(parents=True)
    (work_dir / fpga_build.STEP_REQUIRES_CHECKPOINT[step]).write_text(
        "checkpoint fixture\n"
    )
    if step == "route":
        (work_dir / "post_place.dcp").write_text("qualified placement\n")
        _write_place_gate(work_dir, bind=True)
    _write_stage_utilization(work_dir, "post_route", 900)
    _write_stage_utilization(work_dir, "final", 999)
    monkeypatch.setattr(fpga_build, "__file__", str(script_dir / "build.py"))
    monkeypatch.setattr(
        sys, "argv", ["build.py", "x3", "--start-at", step, "--stop-after", step]
    )
    monkeypatch.setitem(
        sys.modules, "extract_timing_and_util_summary", timing_util_summary
    )

    def complete_stage(*_args: Any, **_kwargs: Any) -> tuple[bool, float, str]:
        if report_available:
            _write_stage_utilization(work_dir, report_prefix, 42)
        return True, -0.1, report_prefix

    refreshed: list[dict[str, Any]] = []

    def capture_refresh(_script_dir: Path, all_util: dict[str, Any]) -> bool:
        refreshed.append(all_util)
        return True

    monkeypatch.setattr(fpga_build, "run_step", complete_stage)
    monkeypatch.setattr(fpga_build, "run_x3_step_directive_sweep", complete_stage)
    monkeypatch.setattr(fpga_build, "generate_bitstream", lambda *_args: True)
    monkeypatch.setattr(
        timing_util_summary, "update_readme_utilization", capture_refresh
    )

    fpga_build.main()

    if report_available:
        assert len(refreshed) == 1
        assert refreshed[0]["x3"]["stage"] == report_prefix
        assert refreshed[0]["x3"]["luts_used"] == 42
    else:
        # No boards have data: main leaves the existing README untouched.
        assert not refreshed


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

    (work_dir / "post_place_vivado.log").write_text(
        vivado_log
        + "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
    )
    utilization = timing_util_summary.collect_all_board_utilization(tmp_path)
    provenance = utilization["x3"]["report_provenance"]
    assert provenance == (
        "`ExtraNetDelay_high`/0.500 + LOW CELL_BLOAT_FACTOR on `*u_tomasulo/u_int_rs`"
    )
    assert provenance in timing_util_summary.format_readme_utilization_section(
        utilization
    )


def test_x3_place_provenance_records_manual_bloat_targets() -> None:
    """Multiple manual targets remain reproducible in generated provenance."""
    log = (
        "# Command line : vivado -tclargs x3 place ExtraPostPlacementOpt input.dcp 0\n"
        "Set x3 CPU setup clock uncertainty to 0.45 ns (place overconstraint)\n"
        '# puts "Set CELL_BLOAT_FACTOR $cell_bloat on [llength $bloat_cells] cell(s)"\n'
        "Set CELL_BLOAT_FACTOR MEDIUM on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
        "Set CELL_BLOAT_FACTOR MEDIUM on 1 cell(s) matching '*u_tomasulo/u_mem_rs'\n"
        "WARNING: FROST_PLACE_CELL_BLOAT pattern '*missing' matched no cells\n"
    )
    assert timing_util_summary.extract_x3_place_provenance(log) == (
        "`ExtraPostPlacementOpt`/0.450"
        " + MEDIUM CELL_BLOAT_FACTOR on `*u_tomasulo/u_int_rs`"
        " + MEDIUM CELL_BLOAT_FACTOR on `*u_tomasulo/u_mem_rs`"
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
    list, and every guided pair must receive the PC-tail guidance.
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
    # The vetted extra seed sits off the 50 ps grid: on-grid values are
    # already covered by the Cartesian sweep.
    for _, uncertainty in fpga_build.X3_PLACE_EXTRA_SEED_CANDIDATES:
        assert uncertainty not in uncertainties

    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", 0.500)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraNetDelay_high", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraNetDelay_high", 0.425)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraTimingOpt", 0.450)
    assert not fpga_build.x3_place_uses_pc_tail_guidance("ExtraPostPlacementOpt", None)


def test_default_x3_place_sweep_retains_controls_and_adds_low_variants() -> None:
    """Two LOW variants get distinct directories beside all 25 controls."""
    directives = fpga_build.X3_PLACER_SWEEP_DIRECTIVES
    uncertainties = fpga_build.make_x3_place_setup_uncertainties_ns(6)
    candidates = fpga_build.make_x3_place_sweep_candidates(
        directives, uncertainties, {}
    )
    controls = [
        candidate for candidate in candidates if candidate.cell_bloat_factor is None
    ]
    variants = [
        candidate for candidate in candidates if candidate.cell_bloat_factor is not None
    ]
    assert len(candidates) == len({candidate.label for candidate in candidates}) == 27
    assert [
        (candidate.directive, candidate.setup_uncertainty_ns) for candidate in controls
    ] == [
        (directive, uncertainty)
        for directive in directives
        for uncertainty in uncertainties
    ] + [("ExtraPostPlacementOpt", 0.425)]
    assert [candidate.label for candidate in variants] == [
        "ExtraNetDelay_high_u0.350_bloatLOW_intRS",
        "ExtraPostPlacementOpt_u0.450_bloatLOW_intRS",
    ]
    for variant in variants:
        assert variant.cell_bloat_factor == "LOW"
        assert variant.cell_bloat_cells == "*u_tomasulo/u_int_rs"
    assert not fpga_build.x3_place_uses_pc_tail_guidance(
        variants[0].directive, variants[0].setup_uncertainty_ns
    )
    assert fpga_build.x3_place_uses_pc_tail_guidance(
        variants[1].directive, variants[1].setup_uncertainty_ns
    )


@pytest.mark.parametrize(
    ("directives", "uncertainties", "variant_labels"),
    (
        (["ExtraNetDelay_high"], [0.350], ["ExtraNetDelay_high_u0.350_bloatLOW_intRS"]),
        (
            ["ExtraPostPlacementOpt"],
            [0.450],
            ["ExtraPostPlacementOpt_u0.450_bloatLOW_intRS"],
        ),
        (["ExtraNetDelay_high"], [0.500], []),
        (["ExtraTimingOpt"], [0.350, 0.450], []),
    ),
)
def test_x3_low_variants_require_their_requested_grid_control(
    directives: list[str], uncertainties: list[float], variant_labels: list[str]
) -> None:
    """Narrowing directives or uncertainty must not add unrelated treatments."""
    candidates = fpga_build.make_x3_place_sweep_candidates(
        directives, uncertainties, {}
    )
    assert [
        candidate.label for candidate in candidates if candidate.cell_bloat_factor
    ] == variant_labels
    assert (
        sum(
            candidate.directive == "ExtraPostPlacementOpt"
            and candidate.setup_uncertainty_ns == 0.425
            for candidate in candidates
        )
        == 1
    )


@pytest.mark.parametrize(
    "manual_environment",
    (
        {"FROST_PLACE_CELL_BLOAT": ""},
        {"FROST_PLACE_CELL_BLOAT": "LOW"},
        {
            "FROST_PLACE_CELL_BLOAT": "MEDIUM",
            "FROST_PLACE_CELL_BLOAT_CELLS": "*u_mem_rs",
        },
        {"FROST_PLACE_CELL_BLOAT_CELLS": ""},
        {"FROST_PLACE_CELL_BLOAT_CELLS": "*u_mem_rs"},
    ),
)
def test_explicit_x3_bloat_environment_preserves_manual_sweep(
    manual_environment: dict[str, str],
) -> None:
    """Even empty or target-only settings retain their previous semantics."""
    inherited = {"FROST_TEST_MARKER": "retained", **manual_environment}
    candidates = fpga_build.make_x3_place_sweep_candidates(
        fpga_build.X3_PLACER_SWEEP_DIRECTIVES,
        fpga_build.make_x3_place_setup_uncertainties_ns(6),
        inherited,
    )
    assert len(candidates) == 25
    assert all(candidate.cell_bloat_factor is None for candidate in candidates)
    for candidate in candidates:
        child_environment = candidate.environment(inherited)
        assert child_environment is not inherited
        for key, value in inherited.items():
            assert child_environment[key] == value
    assert "FROST_PLACE_SETUP_UNCERTAINTY" not in inherited


@pytest.mark.parametrize(
    "contents",
    (
        "",
        "WARNING: FROST_PLACE_CELL_BLOAT pattern '*u_tomasulo/u_int_rs' matched no cells\n",
        "Set CELL_BLOAT_FACTOR LOW on 0 cell(s) matching '*u_tomasulo/u_int_rs'\n",
        "Set CELL_BLOAT_FACTOR LOW on 2 cell(s) matching '*u_tomasulo/u_int_rs'\n",
        "Set CELL_BLOAT_FACTOR MEDIUM on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n",
        "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_mem_rs'\n",
        "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
        "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_mem_rs'\n",
    ),
)
def test_automatic_x3_bloat_match_validation_rejects_wrong_scope(
    tmp_path: Path, contents: str
) -> None:
    """A successful Vivado process alone does not qualify a bloat treatment."""
    log = tmp_path / "vivado.log"
    assert not fpga_build.x3_place_cell_bloat_override_is_valid(
        log, "LOW", "*u_tomasulo/u_int_rs"
    )
    log.write_text(contents)
    assert not fpga_build.x3_place_cell_bloat_override_is_valid(
        log, "LOW", "*u_tomasulo/u_int_rs"
    )
    log.write_text(
        "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
    )
    assert fpga_build.x3_place_cell_bloat_override_is_valid(
        log, "LOW", "*u_tomasulo/u_int_rs"
    )


@pytest.mark.parametrize("bloat_match_valid", (True, False))
def test_x3_place_worker_isolates_and_validates_bloat_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, bloat_match_valid: bool
) -> None:
    """Actual launch/promotion wiring cannot leak LOW or rank a failed match."""
    monkeypatch.delenv("FROST_PLACE_CELL_BLOAT", raising=False)
    monkeypatch.delenv("FROST_PLACE_CELL_BLOAT_CELLS", raising=False)
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    main_work = tmp_path / "x3/work"
    main_work.mkdir(parents=True)
    (main_work / "post_opt.dcp").write_text("input checkpoint\n")
    launches: list[tuple[Path, dict[str, str]]] = []
    audits: list[tuple[str, float]] = []

    def fake_popen(_command: list[str], **kwargs: Any) -> Any:
        work_dir = kwargs["cwd"]
        environment = kwargs["env"]
        launches.append((work_dir, environment))
        (work_dir / "post_place.dcp").write_text(work_dir.name)
        _write_place_gate(work_dir, -0.1 if "bloatLOW" in str(work_dir) else -0.15)
        (work_dir / "post_place_timing.rpt").write_text("timing fixture\n")
        (work_dir / "post_place_congestion.rpt").write_text("no congestion\n")
        (work_dir / "vivado.log").write_text("placement fixture\n")
        if environment.get("FROST_PLACE_CELL_BLOAT") == "LOW" and bloat_match_valid:
            kwargs["stdout"].write(
                "Set CELL_BLOAT_FACTOR LOW on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
            )
        return SimpleNamespace(pid=len(launches), poll=lambda: 0)

    def fake_audit(_path: Path, directive: str, uncertainty: float) -> bool:
        audits.append((directive, uncertainty))
        return True

    monkeypatch.setattr(fpga_build.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(fpga_build, "x3_pc_tail_group_audit_is_valid", fake_audit)
    monkeypatch.setattr(
        fpga_build,
        "extract_timing_from_report",
        lambda path: {"wns_ns": -0.1 if "bloatLOW" in str(path) else -0.15},
    )
    success, wns, prefix = fpga_build.run_x3_step_directive_sweep(
        tmp_path,
        "place",
        ["ExtraNetDelay_high"],
        "placer",
        "unused-vivado",
        keep_temps=True,
        setup_uncertainties_ns=[0.350],
    )
    assert success and prefix == "post_place"
    assert len(launches) == 3
    assert len({work_dir for work_dir, _environment in launches}) == 3
    assert len({id(environment) for _work_dir, environment in launches}) == 3
    for work_dir, environment in launches:
        if "bloatLOW" in work_dir.name:
            assert environment["FROST_PLACE_CELL_BLOAT"] == "LOW"
            assert environment["FROST_PLACE_CELL_BLOAT_CELLS"] == "*u_tomasulo/u_int_rs"
        else:
            assert "FROST_PLACE_CELL_BLOAT" not in environment
            assert "FROST_PLACE_CELL_BLOAT_CELLS" not in environment
    assert audits == [("ExtraPostPlacementOpt", 0.425)]
    assert "FROST_PLACE_CELL_BLOAT" not in fpga_build.os.environ
    assert "FROST_PLACE_CELL_BLOAT_CELLS" not in fpga_build.os.environ
    promoted = (main_work / "post_place.dcp").read_text()
    assert ("bloatLOW" in promoted) is bloat_match_valid
    assert wns == (-0.1 if bloat_match_valid else -0.15)


def test_pc_tail_audit_validation_is_fail_closed(tmp_path: Path) -> None:
    """Replica churn is accepted only with complete canonical invariants."""
    audit = tmp_path / "post_place_group_audit.txt"
    valid_audit = (
        "\n".join(
            (
                "DIRECTIVE=ExtraNetDelay_high",
                "PLACE_UNCERTAINTY_NS=0.500",
                "SCORE_UNCERTAINTY_NS=0.000",
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
        valid_audit.replace("SCORE_UNCERTAINTY_NS=0.000", "SCORE_UNCERTAINTY_NS=0.450"),
        valid_audit.replace("SCORE_UNCERTAINTY_NS=0.000\n", ""),
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
    (seed_work / "post_place_gate_cpu.rpt").write_text("CPU control\n")
    (seed_work / "post_place_group_audit.txt").write_text("audit\n")
    (seed_work / "post_place_pin_swap_audit.txt").write_text("pin audit\n")
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
    assert not (main_work / "post_place_pin_swap_audit.txt").exists()
    assert (main_work / "post_place_pc_compressed_tail_timing.rpt").read_text() == (
        "compressed timing\n"
    )

    assert (main_work / "post_place_gate_cpu.rpt").read_text() == "CPU control\n"


def test_non_guided_winner_clears_stale_guidance_evidence(tmp_path: Path) -> None:
    """Optional audit files may never describe a different promoted DCP."""
    seed_work = tmp_path / "seed"
    main_work = tmp_path / "main"
    seed_work.mkdir()
    main_work.mkdir()
    (seed_work / "post_place.dcp").write_bytes(b"new checkpoint")
    (main_work / "post_place_group_audit.txt").write_text("stale audit\n")
    (main_work / "post_place_pin_swap_audit.txt").write_text("stale pin audit\n")
    (main_work / "post_place_flush_guidance_audit.tcldict").write_text(
        "stale flush audit\n"
    )
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
    assert not (main_work / "post_place_pin_swap_audit.txt").exists()
    assert not (main_work / "post_place_pc_compressed_tail_timing.rpt").exists()

    assert not (main_work / "post_place_flush_guidance_audit.tcldict").exists()


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


def test_post_opt_helper_status_names_applied_skipped_and_missing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A skipped netlist repair must be named, with the check that failed."""
    main_work = tmp_path / "main"
    main_work.mkdir()
    (main_work / fpga_build.POST_OPT_NETLIST_HELPERS["l1_control_repair"]).write_text(
        "status APPLIED before {proof {assignments 8192 ones 1024}} "
        "t_counts {48 42 35 3} t_leaves 128 valid_leaves 31\n"
    )
    (main_work / fpga_build.POST_OPT_NETLIST_HELPERS["x3_nic_placement"]).write_text(
        "status SKIPPED_OR_PREFLIGHT_ERROR mode auto "
        "reason {Unsupported or shared DMA LUT function}\n"
    )

    fpga_build.report_post_opt_helper_status(main_work)

    lines = capsys.readouterr().out.splitlines()
    assert lines == [
        "  l1_control_repair: APPLIED",
        "  x3_nic_placement: SKIPPED: Unsupported or shared DMA LUT function",
    ]

    # An aborted helper left an incomplete status behind; it is not a skip.
    (main_work / fpga_build.POST_OPT_NETLIST_HELPERS["l1_control_repair"]).write_text(
        "status PREFLIGHT\n"
    )
    fpga_build.report_post_opt_helper_status(main_work)
    assert capsys.readouterr().out.splitlines()[0] == (
        "  l1_control_repair: NOT APPLIED (PREFLIGHT)"
    )

    # A helper that never wrote an audit is reported, not silently treated as
    # applied; reporting stays advisory and never raises.
    for audit_name in fpga_build.POST_OPT_NETLIST_HELPERS.values():
        (main_work / audit_name).unlink()
    fpga_build.report_post_opt_helper_status(main_work)
    assert all("NO AUDIT" in line for line in capsys.readouterr().out.splitlines())


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
        '$x3_place_baseline_uncertainty "real post-place scoring',
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

    The low 64 KiB launches through the bounded per-predicate LUTRAM copies. The
    canonical sideband block RAM remains the full-depth equivalence oracle but
    never directly supplies the seven PC predicates. Outside the overlay,
    a repeated request aligns raw payload with predicates redecoded into the
    same scalar-bank output FFs, without a second register or output mux.
    """
    imem = (REPO_ROOT / "hw/rtl/cpu_and_mem/imem_predecode.sv").read_text()
    assert len(re.findall(r"^module ", imem, re.M)) == 2
    assert "module imem_sideband_scalar_bank #(" in imem
    assert "parameter int unsigned PC_METADATA_OVERLAY_ADDR_WIDTH" in imem
    assert "(ADDR_WIDTH > 14) ? 13 : ADDR_WIDTH - 1" in imem
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
    # Cached PC-sideband parity is normalized on the provider's payload edge.
    # Rebuilding it from the registered bank selector reopens the served-window
    # coverage -> PC recurrence by one LUT and a general-routing hop.
    for port, signal, declaration in (
        (
            "o_pc_metadata_by_parity",
            "high_fetch_pc_metadata_by_parity",
            "output logic [7:0] o_pc_metadata_by_parity",
        ),
        (
            "o_pc_pairability_by_parity",
            "high_fetch_pc_pairability_by_parity",
            "output logic [3:0] o_pc_pairability_by_parity",
        ),
        (
            "o_slot2_start_valid_lo_by_parity",
            "high_fetch_slot2_start_valid_lo_by_parity",
            "output logic [1:0] o_slot2_start_valid_lo_by_parity",
        ),
    ):
        assert declaration in fetch_provider
        assert f".{port}({signal})" in provider_block
    assert "pc_metadata_by_parity_q" in fetch_provider
    assert "pc_pairability_by_parity_q" in fetch_provider
    assert "slot2_start_valid_lo_by_parity_q" in fetch_provider
    assert (
        "assign high_fetch_pc_metadata_by_parity = cached_fetch_bank_sel_r ?"
        not in (provider_block)
    )
    assert "cached_fetch_pc_pairability" not in provider_block
    assert ".i_publish_hold(low_bram_pipeline_stall_q)" in provider_block
    assert ".i_response_overlay_hit(bram_fetch_window_overlay_hit)" in provider_block
    assert "low_bram_pipeline_stall_q <= pipeline_stall;" in provider_block
    assert ".i_owner_low(!fetch_pa0[31])" in provider_block
    assert ".i_retarget(fetch_redirect || fetch_high_transition)" in provider_block
    assert ".i_retarget(fetch_cached_retarget)" in provider_block

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
    redirect_block_match = re.search(
        r"fetch_redirect fetch_redirect_inst \((.*?)\n  \);", if_stage, re.S
    )
    assert redirect_block_match is not None
    redirect_block = redirect_block_match.group(1)
    for port, signal in (
        ("i_clk", "i_clk"),
        ("i_reset", "i_pipeline_ctrl.reset"),
        ("i_pc_update_en", "pc_update_en"),
        ("i_npc_cond", "npc_cond[riscv_pkg::PcNextArms-1:1]"),
        ("i_npc_seq", "npc_seq[riscv_pkg::PcNextArms-1:1]"),
        ("i_live_prediction_emits_with_output", "live_prediction_emits_with_output"),
        ("o_fetch_redirect", "o_fetch_redirect"),
    ):
        assert f".{port}({signal})" in redirect_block
    # The local helper proof checks arbitrary raw requests. IF separately
    # checks its registered output against the original actual winner bus.
    assert re.search(
        r"fetch_redirect_reference_q\s*<=\s*!i_pipeline_ctrl.reset\s*&&\s*"
        r"pc_update_en\s*&&\s*\|\(npc_sel\s*&\s*~npc_seq\)\s*&&\s*"
        r"!\(npc_sel\[PredictionNpcArm\]\s*&&\s*"
        r"!live_prediction_emits_with_output\);",
        if_stage,
    )
    assert "assert (o_fetch_redirect == fetch_redirect_reference_q);" in if_stage
    if_stage_files = (
        REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.f"
    ).read_text()
    assert "cpu_and_mem/cpu/if_stage/fetch_redirect.sv" in if_stage_files
    assert "o_fetch_cached_retarget <=" in if_stage
    assert (
        "slot2_prediction_used_for_pc || live_prediction_emits_with_output ||"
        in if_stage
    )
    assert (
        "assign o_fetch_live_claim = i_instr_valid && !sel_nop && "
        "!if_stage_stall_registered;" in if_stage
    )

    cpu_and_mem_files = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.f").read_text()
    assert "cpu_and_mem/low_bram_fetch_presenter.sv" in cpu_and_mem_files


def test_x3_flow_carries_no_timing_exceptions() -> None:
    """The CPU build flow adds no false, multicycle, or max-delay exceptions.

    Existing board, IP, and crossing constraints are separate from this
    build_step.tcl guard. A functional false path through the front end would
    need the released control to be stable across the cycle before every
    sensitive cycle; the
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


def test_x3_nic_fences_are_soft_and_cover_the_nic() -> None:
    """The NIC fences bias placement only and hold every 300 MHz NIC block."""
    xdc = (REPO_ROOT / "boards/x3/constr/x3.xdc").read_text()
    for pblock, region in (
        ("frost_nic_core", "CLOCKREGION_X1Y4:CLOCKREGION_X1Y4"),
        ("frost_nic_mac", "CLOCKREGION_X2Y4:CLOCKREGION_X2Y4"),
    ):
        block = xdc[xdc.index(f"create_pblock {pblock}") :]
        block = block[: block.index("add_cells_to_pblock") + 400]
        assert f"resize_pblock [get_pblocks {pblock}] -add {region}" in block
        assert f"set_property IS_SOFT true [get_pblocks {pblock}]" in block
        assert f"set_property CONTAIN_ROUTING false [get_pblocks {pblock}]" in block
        assert f"set_property EXCLUDE_PLACEMENT false [get_pblocks {pblock}]" in block
    core = xdc[
        xdc.index("create_pblock frost_nic_core") : xdc.index(
            "create_pblock frost_nic_mac"
        )
    ]
    for child in ("u_rx", "u_tx", "u_front", "u_csr", "u_irq", "u_reset"):
        assert (
            f"gen_cached_tier.nic/{child} " in core
            or f"gen_cached_tier.nic/{child}]" in core
        )
    assert "gen_cached_tier.dma_engine" in core
    assert (
        "gen_cached_tier.nic/u_mac" in xdc[xdc.index("create_pblock frost_nic_mac") :]
    )


def test_board_ddr_generation_is_capability_gated() -> None:
    """A future BRAM-only board must not require a DDR block-design script."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    registry = tcl.index("set board_build_configs")
    capability = tcl.index(
        "set board_has_ddr [dict get $board_build_config has_ddr]", registry
    )
    guard = re.search(r"    if \{\$board_has_ddr\} \{\n(.*?)\n    \}", tcl, re.DOTALL)
    assert guard is not None
    assert registry < capability < guard.start()
    guarded_body = guard.group(1)
    for operation in (
        "${board_name}_ddr_bd.tcl",
        "create_${board_name}_ddr_bd",
        "get_files ddr_subsys.bd",
        "make_wrapper",
        "add_files -norecurse $ddr_subsys_wrapper",
    ):
        assert operation in guarded_body
    assert re.search(
        r"x3 \[dict create part_number xcux35-vsva1365-3-e has_ddr 1\]", tcl
    )


def test_step_arm_state_is_declared_before_first_use() -> None:
    """Vivado must not infer an implicit step wire or warn on done-state use."""
    cpu = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text()
    first_uses = {
        "step_armed_q": "csr_debug_mode || step_armed_q",
        "step_armed_fe_q": ".i_keep_nops(step_armed_fe_q)",
        "step_armed_rob_q": "widen_commit_ok && !step_armed_rob_q",
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
    assert "assign id_valid_base_preflush = pd_valid_q &&" in tracker
    assert "i_csr_in_flight" not in tracker
    assert "logic                            csr_in_flight;" not in tracker
    assert "assign id_valid = id_valid_preflush && !dispatch_flush;" in tracker
    assert "assign id_valid_2 = id_valid_2_preflush && !dispatch_flush;" in tracker

    pipeline_control = (
        REPO_ROOT
        / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/pipeline_control/ooo_pipeline_control.sv"
    ).read_text()
    assert (
        "else if (serializing_alloc_fire_comb) id_stall_q <= 1'b1;" in pipeline_control
    )
    assert "p_csr_alloc_is_successful_dispatch" in pipeline_control
    assert "p_csr_in_flight_owns_id_stall" in pipeline_control
    assert "p_id_stall_matches_legacy_owner" in pipeline_control
    assert "p_id_valid_gate_matches_legacy" in pipeline_control

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


def test_route_directives_restrict_the_x3_router_sweep() -> None:
    """--route-directives keeps order, drops duplicates, defaults to the sweep."""
    full = fpga_build.resolve_x3_route_sweep_directives(None)
    assert full == fpga_build.ROUTER_SWEEP_DIRECTIVES
    assert full is not fpga_build.ROUTER_SWEEP_DIRECTIVES
    assert fpga_build.resolve_x3_route_sweep_directives(
        ["RuntimeOptimized", "Explore", "RuntimeOptimized"]
    ) == ["RuntimeOptimized", "Explore"]
    with pytest.raises(ValueError):
        fpga_build.resolve_x3_route_sweep_directives(["NoSuchDirective"])


def test_functional_build_policy_leaves_full_rate_builds_alone() -> None:
    """A divider of 1 returns the caller's settings and the README refresh."""
    policy = fpga_build.resolve_functional_build_policy(
        1, 300_000_000, ["ExtraNetDelay_high"], 6, False, ["Explore"], False
    )
    assert policy.cpu_clock_div == 1
    assert policy.clock_freq == 300_000_000
    assert policy.place_directives == ["ExtraNetDelay_high"]
    assert policy.place_uncertainty_count == 6
    assert policy.include_extra_seeds
    assert policy.quick_route_count is None
    assert policy.route_directives == ["Explore"]
    assert policy.update_readme


def test_functional_build_policy_collapses_the_sweeps_at_half_clock() -> None:
    """--cpu-clock-div 2 builds for 150 MHz with single RuntimeOptimized runs."""
    policy = fpga_build.resolve_functional_build_policy(
        2,
        300_000_000,
        fpga_build.X3_PLACER_SWEEP_DIRECTIVES,
        fpga_build.X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT,
        False,
        fpga_build.ROUTER_SWEEP_DIRECTIVES,
        False,
    )
    assert policy.clock_freq == 150_000_000
    assert policy.place_directives == ["RuntimeOptimized"]
    assert policy.place_uncertainty_count == 1
    assert not policy.include_extra_seeds
    assert policy.quick_route_count == 0
    assert policy.route_directives == ["RuntimeOptimized"]
    assert not policy.update_readme


def test_functional_build_policy_honors_explicit_sweep_overrides() -> None:
    """Explicit placer and router requests survive the divided-clock policy."""
    policy = fpga_build.resolve_functional_build_policy(
        2, 300_000_000, ["ExtraTimingOpt"], 2, True, ["Explore", "Default"], True
    )
    assert policy.place_directives == ["ExtraTimingOpt"]
    assert policy.place_uncertainty_count == 2
    assert policy.route_directives == ["Explore", "Default"]
    assert not policy.include_extra_seeds
    with pytest.raises(ValueError):
        fpga_build.resolve_functional_build_policy(
            5, 300_000_000, ["ExtraTimingOpt"], 1, True, ["Explore"], True
        )


def test_place_sweep_without_extra_seeds_is_exactly_the_grid() -> None:
    """Functional builds get the requested grid: no off-grid seed, no bloat."""
    grid = fpga_build.make_x3_place_sweep_candidates(
        ["RuntimeOptimized"], [0.5], {}, include_extra_seeds=False
    )
    assert [(c.directive, c.setup_uncertainty_ns) for c in grid] == [
        ("RuntimeOptimized", 0.5)
    ]
    assert all(c.cell_bloat_factor is None for c in grid)
    with_seeds = fpga_build.make_x3_place_sweep_candidates(
        ["RuntimeOptimized"], [0.5], {}
    )
    assert len(with_seeds) > len(grid)


def test_cpu_clock_divider_reaches_synthesis_and_the_block_design() -> None:
    """The divider reaches synthesis, the block design, and the board top."""
    script_dir = Path(__file__).resolve().parent.parent / "fpga" / "build"
    step_tcl = (script_dir / "build_step.tcl").read_text()
    assert "getenv_default FROST_CPU_CLK_DIV 1" in step_tcl
    assert "-generic CPU_CLK_DIV=$cpu_clk_div" in step_tcl
    bd_tcl = (script_dir / "x3_ddr_bd.tcl").read_text()
    assert "::env(FROST_CPU_CLK_DIV)" in bd_tcl
    assert "-freq_hz $cpu_clk_hz cpu_clk" in bd_tcl
    assert "[expr {$cpu_clk_hz / 4}] jtag_clk" in bd_tcl
    top = (
        Path(__file__).resolve().parent.parent / "boards" / "x3" / "x3_frost.sv"
    ).read_text()
    assert "parameter int unsigned CPU_CLK_DIV = 1" in top
    assert "localparam real CpuClkOutDivide = 4.0 * CPU_CLK_DIV;" in top
    assert "localparam int unsigned CpuClkHz = 300_000_000 / CPU_CLK_DIV;" in top
    assert ".CLKOUT0_DIVIDE_F(CpuClkOutDivide)" in top
    assert ".CLK_FREQ_HZ(CpuClkHz)," in top


def test_only_post_place_physopt_overconstrains_by_default() -> None:
    """Placement and the post-place sweep add 0.5 ns; post-route stages add none.

    Every promoted report and checkpoint is taken at 0.000 ns regardless.
    """
    script_dir = Path(__file__).resolve().parent.parent / "fpga" / "build"
    step_tcl = (script_dir / "build_step.tcl").read_text()
    assert (
        '    if {$step eq "post_place_physopt"} {\n'
        "        set physopt_uncertainty_default 0.5\n"
        "    } else {\n"
        "        set physopt_uncertainty_default 0.0\n"
        "    }\n"
        "    set physopt_uncertainty [getenv_default "
        "FROST_PHYSOPT_SETUP_UNCERTAINTY $physopt_uncertainty_default]\n"
    ) in step_tcl
    assert 'set_x3_setup_uncertainty $board_name 0.0 "$step report"' in step_tcl
    # Placement keeps its own separate 0.5 ns seed-grid origin.
    assert "set x3_place_seed_baseline_uncertainty 0.5" in step_tcl
    # Routing never keeps an overconstraint.
    assert (
        "set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.0 -setup"
        in step_tcl
    )


# Bounded Vivado model for one phys-opt sweep. It tracks the added setup
# uncertainty in force and answers every slack query with the true 0.000 ns
# slack minus that uncertainty, so a stage sweeping overconstrained measures a
# pessimistic WNS and one sweeping at 0.000 measures the real one. Checkpoints
# remember the uncertainty they were written under, as Vivado's carry theirs.
PHYSOPT_SWEEP_MODEL = r"""
set true_wns [expr {double($::env(MODEL_TRUE_WNS))}]
set uncertainty 0.0
set checkpoint_uncertainty [dict create]

proc record {line} {
    set fh [open $::env(MODEL_TRACE) a]
    puts $fh $line
    close $fh
}

proc model_wns {} {
    global true_wns uncertainty
    return [expr {$true_wns - $uncertainty}]
}

proc write_timing_summary {path} {
    set wns [model_wns]
    if {$wns < 0.0} {
        set tns [expr {$wns * 4.0}]
        set failing 12
    } else {
        set tns 0.0
        set failing 0
    }
    set fh [open $path w]
    puts $fh "| WNS(ns) | TNS(ns) | TNS Failing Endpoints | TNS Total Endpoints |"
    puts $fh "| ------- | ------- | --------------------- | ------------------- |"
    puts $fh "| [format %.3f $wns] | [format %.3f $tns] | $failing | 264000 |"
    close $fh
}

proc unknown {cmd args} {
    global uncertainty checkpoint_uncertainty
    switch -- $cmd {
        get_clocks {return clock_from_mmcm}
        close_design {return {}}
        set_clock_uncertainty {
            set index [lsearch -exact $args -setup]
            set uncertainty [expr {double([lindex $args [expr {$index - 1}]])}]
            record "uncertainty [format %.3f $uncertainty]"
            return {}
        }
        open_checkpoint {
            set path [lindex $args end]
            set uncertainty 0.0
            if {[dict exists $checkpoint_uncertainty $path]} {
                set uncertainty [dict get $checkpoint_uncertainty $path]
            }
            record "open [file tail $path] at [format %.3f $uncertainty]"
            return {}
        }
        write_checkpoint {
            set path [lindex $args end]
            dict set checkpoint_uncertainty $path $uncertainty
            close [open $path w]
            record "checkpoint [file tail $path] at [format %.3f $uncertainty]"
            return {}
        }
        report_timing_summary {
            set path [lindex $args end]
            write_timing_summary $path
            set taken "report [file tail $path] at [format %.3f $uncertainty]"
            record "$taken wns [format %.3f [model_wns]]"
            return {}
        }
        report_utilization - report_high_fanout_nets {
            close [open [lindex $args end] w]
            return {}
        }
        get_timing_paths {
            if {[lsearch -exact $args -slack_lesser_than] >= 0} {return {}}
            return worst_path
        }
        get_property {
            if {[lindex $args 0] eq "SLACK"} {return [model_wns]}
            error "Unexpected property request $args"
        }
        phys_opt_design {
            record "phys_opt_design $args"
            return {}
        }
        default {error "Unexpected command $cmd $args"}
    }
}

set argv [list x3 $::env(MODEL_STEP) Sweep input.dcp 0]
set argc [llength $argv]
source $::env(MODEL_SOURCE)
"""


def _run_physopt_sweep_model(
    tmp_path: Path,
    step: str,
    true_wns: float,
    setup_uncertainty: str | None = None,
) -> tuple[str, list[str], Path]:
    """Sweep one phys-opt stage; return its stdout, trace and main work dir."""
    model = tmp_path / "physopt_model.tcl"
    model.write_text(PHYSOPT_SWEEP_MODEL)
    work_dir = tmp_path / f"work_{step}_Sweep"
    work_dir.mkdir()
    trace = tmp_path / "physopt_trace.txt"
    trace.touch()
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("FROST_")
    }
    env.update(
        MODEL_SOURCE=str(REPO_ROOT / "fpga/build/build_step.tcl"),
        MODEL_TRACE=str(trace),
        MODEL_TRUE_WNS=str(true_wns),
        MODEL_STEP=step,
        # One directive plus the appended retime pass keeps the model short.
        FROST_PHYSOPT_SWEEP_ORDER="Explore",
    )
    if setup_uncertainty is not None:
        env["FROST_PHYSOPT_SETUP_UNCERTAINTY"] = setup_uncertainty
    result = subprocess.run(
        ["tclsh", str(model)],
        cwd=work_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout, trace.read_text().splitlines(), tmp_path / "work"


@pytest.mark.parametrize(
    ("step", "probe_uncertainty", "probe_wns", "promoted"),
    (
        ("post_place_physopt", "0.500", "-0.488", "post_place_physopt"),
        ("post_route_physopt", "0.000", "0.012", "final"),
        ("post_second_route_physopt", "0.000", "0.012", "final"),
    ),
)
def test_physopt_sweep_uncertainty_is_stage_scoped(
    tmp_path: Path,
    step: str,
    probe_uncertainty: str,
    probe_wns: str,
    promoted: str,
) -> None:
    """Post-place probes 0.5 ns pessimistic; post-route decides at 0.000 ns.

    A design 0.012 ns inside closure at 0.000 ns reads -0.488 ns under the
    post-place overconstraint, so only the post-route stages see the real
    slack that ends their sweep early and promotes final.dcp.
    """
    stdout, trace, main_work = _run_physopt_sweep_model(tmp_path, step, 0.012)

    probes = [
        line
        for line in trace
        if line.startswith(("report phys_opt_initial", "report phys_opt_probe"))
    ]
    assert probes
    assert all(f"at {probe_uncertainty} wns {probe_wns}" in line for line in probes)
    assert ("0.500" in "\n".join(trace)) is (probe_uncertainty == "0.500")

    # The promoted report and the checkpoint handed on are always at 0.000.
    assert "report phys_opt_timing.rpt at 0.000 wns 0.012" in trace
    assert "checkpoint phys_opt.dcp at 0.000" in trace

    # The early exit and the final.dcp promotion follow the measured WNS.
    timing_met = probe_uncertainty == "0.000"
    assert (f"Timing met; stopping {step} sweep early" in stdout) is timing_met
    assert (main_work / f"{promoted}.dcp").exists()
    assert (main_work / f"{promoted}_timing.rpt").exists()
    stale = {"post_place_physopt", "post_route_physopt", "final"} - {promoted}
    assert not any((main_work / f"{name}.dcp").exists() for name in stale)


def test_physopt_uncertainty_override_still_reaches_a_post_route_stage(
    tmp_path: Path,
) -> None:
    """FROST_PHYSOPT_SETUP_UNCERTAINTY overrides a stage default of 0.000 ns.

    Overconstrained, post-route phys-opt neither stops early nor promotes
    final.dcp for a design its own promoted report shows closing at 0.000.
    """
    stdout, trace, main_work = _run_physopt_sweep_model(
        tmp_path, "post_route_physopt", 0.012, setup_uncertainty="0.5"
    )

    assert "report phys_opt_initial_timing.rpt at 0.500 wns -0.488" in trace
    assert "report phys_opt_timing.rpt at 0.000 wns 0.012" in trace
    assert "Timing met" not in stdout
    assert (main_work / "post_route_physopt.dcp").exists()
    assert not (main_work / "final.dcp").exists()


def test_perf_counters_generic_reaches_synthesis_and_the_cpu() -> None:
    """--perf-counters reaches synthesis and every level down to cpu_ooo."""
    root = Path(__file__).resolve().parent.parent
    step_tcl = (root / "fpga" / "build" / "build_step.tcl").read_text()
    assert "getenv_default FROST_PERF_COUNTERS 0" in step_tcl
    assert "-generic PERF_COUNTERS=1" in step_tcl
    for rel in (
        "boards/x3/x3_frost.sv",
        "boards/xilinx_frost_subsystem.sv",
        "hw/rtl/frost.sv",
        "hw/rtl/cpu_and_mem/cpu_and_mem.sv",
    ):
        text = (root / rel).read_text()
        assert "parameter int unsigned PERF_COUNTERS = 0" in text, rel
        assert ".PERF_COUNTERS(PERF_COUNTERS)" in text, rel
    cpu = (
        root / "hw" / "rtl" / "cpu_and_mem" / "cpu" / "cpu_ooo" / "cpu_ooo.sv"
    ).read_text()
    assert "parameter int unsigned PERF_COUNTERS = 0" in cpu
    # The CSR file and the tomasulo_wrapper both take the option.
    assert cpu.count(".PERF_COUNTERS(PERF_COUNTERS)") == 2
    assert "if (PERF_COUNTERS != 0) begin : gen_perf_counters" in cpu


@pytest.mark.parametrize(
    "divider,override,expected",
    ((1, None, False), (2, None, True), (1, True, True), (2, False, False)),
)
def test_perf_counters_default_follows_the_clock_divider(
    divider: int, override: bool | None, expected: bool
) -> None:
    """Counters are left out at full rate and included in divided-clock builds."""
    policy = fpga_build.resolve_functional_build_policy(
        divider,
        300_000_000,
        ["RuntimeOptimized"],
        1,
        False,
        ["RuntimeOptimized"],
        False,
        perf_counters=override,
    )
    assert policy.perf_counters is expected


def test_perf_counters_cli_default_overrides_stale_environment(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A full-rate build exports FROST_PERF_COUNTERS=0 despite an inherited 1."""
    monkeypatch.setenv("FROST_PERF_COUNTERS", "1")
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(sys, "argv", ["build.py", "x3", "--stop-after", "place"])
    observed = []

    def compile_firmware(_root: Path, _output: Path, clock: int) -> bool:
        observed.append((clock, fpga_build.os.environ["FROST_PERF_COUNTERS"]))
        return False

    monkeypatch.setattr(fpga_build, "compile_hello_world", compile_firmware)
    with pytest.raises(SystemExit) as stopped:
        fpga_build.main()
    assert stopped.value.code == 1
    assert observed == [(300_000_000, "0")]


def test_read_log_tail_streams_appended_text_and_survives_truncation(
    tmp_path: Path,
) -> None:
    """The single-job stream reads only what Vivado appended since last time."""
    log = tmp_path / "build_step_stdout.log"
    assert fpga_build.read_log_tail(log, 0) == ("", 0)
    log.write_text("route_design\n")
    text, offset = fpga_build.read_log_tail(log, 0)
    assert text == "route_design\n"
    assert offset == len("route_design\n")
    assert fpga_build.read_log_tail(log, offset) == ("", offset)
    with log.open("a") as handle:
        handle.write("Phase 1 Build RT Design\n")
    text, offset = fpga_build.read_log_tail(log, offset)
    assert text == "Phase 1 Build RT Design\n"
    log.write_text("new\n")  # truncated: restart from the beginning at once
    assert fpga_build.read_log_tail(log, offset) == ("new\n", 4)
    log.write_bytes(b"new\nbad \xff byte\n")
    text, _ = fpga_build.read_log_tail(log, 4)
    assert "bad" in text and "byte" in text


def test_debug_ila_reaches_synthesis_and_the_bitstream_step() -> None:
    """--debug-ila defines the mirrors, inserts one ILA, and writes the probes."""
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    assert "proc frost_insert_fetch_ila" in tcl
    assert "lappend current_verilog_defines FROST_DEBUG_FETCH_ILA" in tcl
    assert "frost_insert_fetch_ila main_clock" in tcl
    # Project-mode synthesis cannot implement the core; the opt step does.
    proc_body = tcl.split("proc frost_insert_fetch_ila")[1].split(
        "proc split_env_list"
    )[0]
    assert not any(
        line.strip().startswith("implement_debug_core")
        for line in proc_body.splitlines()
    )
    opt_step = tcl.split('$step eq "opt"')[1].split("write_checkpoint")[0]
    assert "implement_debug_core" in opt_step
    assert "write_debug_probes -force $work_directory/${board_name}_frost.ltx" in tcl
    for path in (
        "hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv",
        "hw/rtl/cpu_and_mem/fetch_provider.sv",
        "hw/rtl/cpu_and_mem/cpu/mmu/immu.sv",
        "hw/rtl/cpu_and_mem/cpu/pd_stage/pd_stage.sv",
        "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv",
    ):
        text = (REPO_ROOT / path).read_text()
        assert "`ifdef FROST_DEBUG_FETCH_ILA" in text
        assert '(* mark_debug = "true" *)' in text
    assert (
        "dbg_ila_if_pd_fetch_fault;"
        in (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv").read_text()
    )


def test_ila_capture_trigger_value_masks_the_page_number() -> None:
    """The PC probe carries 16 bits; the trigger compares the page offset only."""
    spec = importlib.util.spec_from_file_location(
        "frost_capture_fetch_ila_test",
        REPO_ROOT / "fpga" / "debug" / "capture_fetch_ila.py",
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.pc_trigger_value("5e4") == "eq16'hX5E4"
    assert module.pc_trigger_value("000") == "eq16'hX000"
    with pytest.raises(ValueError):
        module.pc_trigger_value("15e4")
    hook = module.arm_hook_tcl(Path("/w/x3_frost.ltx"), "eq16'hX5E4", 3072)
    assert "fetch_ila_procs.tcl" in hook
    assert "frost_ila_attach {/w/x3_frost.ltx}" in hook
    assert (
        "frost_ila_arm $frost_ila {*dbg_ila_if_pd_fetch_fault} {*dbg_ila_if_pd_pc*} {eq16'hX5E4} 3072"
        in hook
    )
    collect = module.collect_hook_tcl(Path("/w/fetch_ila.csv"), 3)
    assert "frost_ila_wait_and_collect $frost_ila {/w/fetch_ila.csv} 3" in collect
    loader = (REPO_ROOT / "fpga/load_software/load_software.tcl").read_text()
    assert "FROST_ILA_ARM_HOOK" in loader
    # The collect hook runs after the load sentinel so the regression's UART
    # capture starts on time, in the same session that armed the core.
    assert loader.index("FROST_LOAD_COMPLETE") < loader.index("FROST_ILA_COLLECT_HOOK")
    procs = (REPO_ROOT / "fpga/debug/fetch_ila_procs.tcl").read_text()
    for proc in ("frost_ila_attach", "frost_ila_arm", "frost_ila_wait_and_collect"):
        assert f"proc {proc} " in procs


class _ScheduledVivado:
    """A process whose first job is slow enough to expose batch barriers."""

    def __init__(self, fleet: "_VivadoFleet", index: int, stdout: Any) -> None:
        self.fleet = fleet
        self.index = index
        self.pid = 10000 + index
        self.stdout = stdout
        self.started = fleet.tick
        self.finish = fleet.tick + (4 if index == 0 else 1)
        if index in fleet.ignore_sigterm:
            self.finish = fleet.tick + 1000
        self.returncode: int | None = None
        self.reaped = False

    def poll(self) -> int | None:
        if self.returncode is None and self.fleet.tick >= self.finish:
            self.returncode = 1 if self.index in self.fleet.exit_failures else 0
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        result = self.poll()
        if result is None:
            raise fpga_build.subprocess.TimeoutExpired("unused-vivado", timeout)
        self.reaped = True
        return result


class _VivadoFleet:
    """Record actual overlap and make simulated jobs finish without sleeping."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, cap: int) -> None:
        self.cap = cap
        self.tick = 0
        self.max_active = 0
        self.attempts: list[Path] = []
        self.processes: list[_ScheduledVivado] = []
        self.launch_failures: set[int] = set()
        self.exit_failures: set[int] = set()
        self.ignore_sigterm: set[int] = set()
        self.signals: list[tuple[int, int]] = []
        self.handles: list[Any] = []
        self.interrupt = False
        monkeypatch.setattr(fpga_build.subprocess, "Popen", self.popen)
        monkeypatch.setattr(fpga_build.time, "sleep", self.sleep)
        monkeypatch.setattr(fpga_build.time, "monotonic", lambda: float(self.tick))
        monkeypatch.setattr(fpga_build.os, "killpg", self.killpg)
        monkeypatch.setattr(
            fpga_build,
            "extract_timing_from_report",
            lambda path: {"wns_ns": float(path.read_text()), "tns_ns": -1.0},
        )

    def popen(self, command: list[str], **kwargs: Any) -> _ScheduledVivado:
        assert kwargs["start_new_session"] is True
        work_dir: Path = kwargs["cwd"]
        index = len(self.attempts)
        self.attempts.append(work_dir)
        self.handles.append(kwargs["stdout"])
        if index in self.launch_failures:
            raise OSError("synthetic launch failure")
        process = _ScheduledVivado(self, index, kwargs["stdout"])
        self.processes.append(process)
        active = sum(p.poll() is None for p in self.processes)
        self.max_active = max(self.max_active, active)
        assert active <= self.cap, "the build exceeded its Vivado job limit"
        step = command[command.index("-tclargs") + 2]
        prefix = "quick_route" if step == "quick_route" else f"post_{step}"
        (work_dir / f"{prefix}.dcp").write_text(work_dir.name)
        wns = round((-0.1 if step == "place" else -1.0) + index / 100.0, 3)
        (work_dir / f"{prefix}_timing.rpt").write_text(str(wns))
        if step == "place":
            _write_place_gate(work_dir, wns)
        (work_dir / "vivado.log").write_text("synthetic Vivado output\n")
        return process

    def sleep(self, _seconds: float) -> None:
        if self.interrupt:
            self.interrupt = False
            raise KeyboardInterrupt
        self.tick += 1
        assert self.tick < 100, "the sweep stopped making progress"

    def killpg(self, pid: int, signum: int) -> None:
        self.signals.append((pid, signum))
        for process in self.processes:
            if process.pid == pid:
                if (
                    process.index in self.ignore_sigterm
                    and signum == fpga_build.signal.SIGTERM
                ):
                    return
                process.returncode = -signum
                return
        raise ProcessLookupError(pid)


def _sweep_input(script_dir: Path, step: str) -> Path:
    """Create the required checkpoint and qualified placement for later stages."""
    work_dir = script_dir / "x3/work"
    work_dir.mkdir(parents=True)
    (work_dir / fpga_build.STEP_REQUIRES_CHECKPOINT[step]).write_text("input\n")
    if fpga_build.STEPS.index(step) > fpga_build.STEPS.index("place"):
        (work_dir / "post_place.dcp").write_text("qualified placement\n")
        _write_place_gate(work_dir, bind=True)
        for previous_stage in fpga_build.STEPS[
            fpga_build.STEPS.index("place") + 1 : fpga_build.STEPS.index(step)
        ]:
            _write_qualified_descendant(work_dir, previous_stage)
    return work_dir


@pytest.mark.parametrize("max_jobs", (None, 1, 2))
@pytest.mark.parametrize("step", ("place", "route", "second_route"))
def test_sweep_limits_overlap_and_replenishes_without_a_batch_barrier(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    max_jobs: int | None,
    step: str,
) -> None:
    """Every candidate competes; a slow first job cannot stall all other slots."""
    cap = 12 if max_jobs is None else max_jobs
    fleet = _VivadoFleet(monkeypatch, cap)
    main_work = _sweep_input(tmp_path, step)
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    if step == "place":
        select_place = fpga_build.select_x3_place_best_run

        def select_with_cap(
            script_dir: Path, runs: list[Any], vivado_path: str, max_jobs: int = 12
        ) -> Any:
            assert max_jobs == cap
            return select_place(script_dir, runs, vivado_path, max_jobs=max_jobs)

        monkeypatch.setattr(fpga_build, "select_x3_place_best_run", select_with_cap)
    directives = [f"Candidate{index}" for index in range(15)]
    options = {} if max_jobs is None else {"max_jobs": max_jobs}
    result = fpga_build.run_x3_step_directive_sweep(
        tmp_path, step, directives, "test", "unused-vivado", keep_temps=True, **options
    )
    assert result == (True, 0.04 if step == "place" else -0.86, f"post_{step}")
    assert [path.name for path in fleet.attempts] == [
        f"work_{step}_{directive}" for directive in directives
    ]
    assert fleet.max_active == cap
    if cap > 1:
        assert fleet.processes[cap].started < fleet.processes[0].finish
    assert (main_work / f"post_{step}.dcp").read_text() == fleet.attempts[-1].name
    if step != "place":
        assert (
            fpga_build.capture_x3_input_lineage(main_work, f"post_{step}.dcp")
            is not None
        )
    assert all(handle.closed for handle in fleet.handles)
    assert all(process.poll() == 0 for process in fleet.processes)


def test_sweep_failures_release_slots_and_preserve_failed_diagnostics(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed launch and a nonzero exit neither deadlock nor win the sweep."""
    fleet = _VivadoFleet(monkeypatch, 2)
    fleet.launch_failures = {1}
    fleet.exit_failures = {4}
    main_work = _sweep_input(tmp_path, "route")
    result = fpga_build.run_x3_step_directive_sweep(
        tmp_path,
        "route",
        [f"Candidate{index}" for index in range(5)],
        "router",
        "unused-vivado",
        max_jobs=2,
    )
    assert result == (True, -0.97, "post_route")
    assert len(fleet.attempts) == 5
    assert (main_work / "post_route.dcp").read_text() == fleet.attempts[3].name
    assert [path.exists() for path in fleet.attempts] == [
        False,
        True,
        False,
        False,
        True,
    ]
    assert all(handle.closed for handle in fleet.handles)


def test_sweep_interrupt_terminates_active_groups_without_launching_queued_jobs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Ctrl-C leaves queued candidates untouched and closes both active logs."""
    fleet = _VivadoFleet(monkeypatch, 2)
    fleet.interrupt = True
    main_work = _sweep_input(tmp_path, "route")
    with pytest.raises(SystemExit) as interrupted:
        fpga_build.run_x3_step_directive_sweep(
            tmp_path,
            "route",
            [f"Candidate{index}" for index in range(5)],
            "router",
            "unused-vivado",
            max_jobs=2,
        )
    assert interrupted.value.code == 130
    assert len(fleet.attempts) == 2
    assert fleet.signals == [
        (process.pid, fpga_build.signal.SIGTERM) for process in fleet.processes
    ]
    assert all(handle.closed for handle in fleet.handles)
    assert all(process.poll() is not None for process in fleet.processes)
    assert not (main_work / "post_route.dcp").exists()
    assert not (tmp_path / "x3/work_route_Candidate2").exists()


def _quick_route_candidates(script_dir: Path, count: int = 15) -> list[Any]:
    """Make complete placement seeds for the real quick-route scheduler."""
    candidates = []
    for index in range(count):
        work_dir = script_dir / f"work_place_Candidate{index}"
        work_dir.mkdir()
        (work_dir / "post_place.dcp").write_text(f"placement {index}\n")
        wns = round(-0.1 + index / 100.0, 3)
        _write_place_gate(work_dir, wns, bind=True)
        candidates.append(
            fpga_build.DirectiveSweepRun(
                directive=f"Candidate{index}",
                label=f"Candidate{index}",
                work_dir=work_dir,
                stdout_path=work_dir / "build_step_stdout.log",
                returncode=0,
                wns=wns,
            )
        )
    return candidates


@pytest.mark.parametrize("max_jobs", (None, 1, 2))
def test_quick_route_probes_share_the_job_cap_and_replenish_free_slots(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, max_jobs: int | None
) -> None:
    """Quick-routing all selected seeds cannot bypass the placement job cap."""
    cap = 12 if max_jobs is None else max_jobs
    fleet = _VivadoFleet(monkeypatch, cap)
    candidates = _quick_route_candidates(tmp_path)
    options = {} if max_jobs is None else {"max_jobs": max_jobs}
    fpga_build.run_x3_place_quick_route_probes(
        tmp_path, candidates, "unused-vivado", **options
    )
    assert fleet.max_active == cap
    assert fleet.attempts == [run.work_dir for run in candidates]
    if cap > 1:
        assert fleet.processes[cap].started < fleet.processes[0].finish
    assert [run.quick_route_returncode for run in candidates] == [0] * len(candidates)
    assert all(run.quick_route_wns is not None for run in candidates)
    assert all(handle.closed for handle in fleet.handles)
    assert [(run.work_dir / "post_place.dcp").read_text() for run in candidates] == [
        f"placement {index}\n" for index in range(len(candidates))
    ]


def test_quick_route_missing_input_and_failures_do_not_consume_slots(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Skipped, unlaunchable, and failed probes leave later seeds runnable."""
    fleet = _VivadoFleet(monkeypatch, 2)
    fleet.launch_failures = {1}
    fleet.exit_failures = {2}
    candidates = _quick_route_candidates(tmp_path, 5)
    (candidates[0].work_dir / "post_place.dcp").unlink()
    fpga_build.run_x3_place_quick_route_probes(
        tmp_path, candidates, "unused-vivado", max_jobs=2
    )
    assert fleet.attempts == [run.work_dir for run in candidates[1:]]
    assert [run.quick_route_returncode for run in candidates] == [-1, 0, -1, 1, 0]
    assert [run.quick_route_wns is not None for run in candidates] == [
        False,
        True,
        False,
        False,
        True,
    ]
    assert all(handle.closed for handle in fleet.handles)


@pytest.mark.parametrize("stubborn_worker", (False, True))
def test_quick_route_interrupt_terminates_active_groups_and_leaves_queue_idle(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, stubborn_worker: bool
) -> None:
    """A quick-route interrupt cannot leave processes or start queued probes."""
    fleet = _VivadoFleet(monkeypatch, 2)
    fleet.interrupt = True
    if stubborn_worker:
        fleet.ignore_sigterm = {0}
    candidates = _quick_route_candidates(tmp_path, 5)
    for index, run in enumerate(candidates):
        run.elapsed_s = 31.0 + index
    placement_metrics = [(run.returncode, run.elapsed_s) for run in candidates]
    with pytest.raises(SystemExit) as interrupted:
        fpga_build.run_x3_place_quick_route_probes(
            tmp_path, candidates, "unused-vivado", max_jobs=2
        )
    assert interrupted.value.code == 130
    assert len(fleet.attempts) == 2
    expected_signals = [
        (process.pid, fpga_build.signal.SIGTERM) for process in fleet.processes
    ]
    if stubborn_worker:
        expected_signals.append((fleet.processes[0].pid, fpga_build.signal.SIGKILL))
    assert fleet.signals == expected_signals
    assert all(handle.closed for handle in fleet.handles)
    assert all(process.poll() is not None for process in fleet.processes)
    assert all(process.reaped for process in fleet.processes)
    assert all(run.quick_route_returncode is None for run in candidates[2:])
    assert [(run.returncode, run.elapsed_s) for run in candidates] == placement_metrics


def test_placement_selection_forwards_job_limit_to_quick_route(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The selection stage preserves the caller's cap while scoring seeds."""
    candidates = _quick_route_candidates(tmp_path, 3)
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    received: list[int] = []

    def score_probes(
        _script_dir: Path, runs: list[Any], _vivado_path: str, max_jobs: int
    ) -> None:
        received.append(max_jobs)
        for index, run in enumerate(runs):
            run.quick_route_returncode = 0
            run.quick_route_wns = float(index)

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", score_probes)
    winner = fpga_build.select_x3_place_best_run(
        tmp_path, candidates, "unused-vivado", max_jobs=1
    )
    assert received == [1]
    assert winner is candidates[0]


@pytest.mark.parametrize("step", ("place", "route", "second_route"))
@pytest.mark.parametrize(
    "options, expected", (([], 12), (["--jobs", "2"], 2), (["-j", "1"], 1))
)
def test_build_cli_forwards_job_limit_to_every_sweep(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    step: str,
    options: list[str],
    expected: int,
) -> None:
    """The default, long flag, and short flag all reach each native sweep."""
    _sweep_input(tmp_path, step)
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(
        sys,
        "argv",
        ["build.py", "x3", "--start-at", step, "--stop-after", step, *options],
    )
    monkeypatch.setitem(
        sys.modules, "extract_timing_and_util_summary", timing_util_summary
    )
    received: list[int] = []

    def finish_sweep(*_args: Any, **kwargs: Any) -> tuple[bool, float, str]:
        received.append(kwargs["max_jobs"])
        return True, -1.0, f"post_{step}"

    monkeypatch.setattr(fpga_build, "run_x3_step_directive_sweep", finish_sweep)
    monkeypatch.setattr(
        timing_util_summary, "update_readme_utilization", lambda *_args: False
    )
    fpga_build.main()
    assert received == [expected]


@pytest.mark.parametrize("jobs", ("0", "-1", "1.5", "unlimited"))
def test_build_cli_rejects_invalid_job_limits_before_starting_work(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], jobs: str
) -> None:
    """A malformed limit must fail argument parsing, before any tool launch."""
    monkeypatch.setattr(sys, "argv", ["build.py", "x3", "--jobs", jobs])
    monkeypatch.setattr(
        fpga_build,
        "compile_hello_world",
        lambda *_args: pytest.fail("invalid --jobs started a software build"),
    )
    with pytest.raises(SystemExit) as rejected:
        fpga_build.main()
    assert rejected.value.code == 2
    assert "--jobs" in capsys.readouterr().err


@pytest.mark.parametrize("max_jobs", (0, -1))
def test_sweep_apis_reject_nonpositive_limits_before_creating_work(
    tmp_path: Path, max_jobs: int
) -> None:
    """Programmatic callers cannot request a queue that will never advance."""
    with pytest.raises(ValueError, match="positive"):
        fpga_build.run_x3_step_directive_sweep(
            tmp_path, "route", ["Explore"], "router", "unused-vivado", max_jobs=max_jobs
        )
    with pytest.raises(ValueError, match="positive"):
        fpga_build.run_x3_place_quick_route_probes(
            tmp_path, [], "unused-vivado", max_jobs=max_jobs
        )
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("passed", (False, True))
def test_native_gate_decides_rounded_boundary(tmp_path: Path, passed: bool) -> None:
    """Identical displayed WNS can represent either native threshold decision."""
    _write_place_gate(tmp_path, -0.2)
    gate = tmp_path / "post_place_gate.txt"
    if not passed:
        gate.write_text(
            gate.read_text()
            .replace("STATUS=PASS", "STATUS=FAIL")
            .replace("STRICT_BELOW_GATE_PATHS=0", "STRICT_BELOW_GATE_PATHS=1")
        )
    assert fpga_build.read_x3_place_gate(gate, -0.2).passed is passed
    assert fpga_build.x3_place_gate_passes(gate, -0.2) is passed


@pytest.mark.parametrize(
    "old,new",
    (
        ("STATUS=PASS", "STATUS=FAIL"),
        ("STATUS=PASS", "STATUS=UNKNOWN"),
        ("THRESHOLD_NS=-0.200", "THRESHOLD_NS=-0.201"),
        ("CPU_PERIOD_NS=3.333", "CPU_PERIOD_NS=6.666"),
        ("CPU_PERIOD_NS=3.333", "CPU_PERIOD_NS=3.334"),
        ("CPU_PERIOD_NS=3.333", "CPU_PERIOD_NS=NaN"),
        ("USER_SETUP_UNCERTAINTY_NS=0.000", "USER_SETUP_UNCERTAINTY_NS=0.500"),
        ("STRICT_BELOW_GATE_PATHS=0", "STRICT_BELOW_GATE_PATHS=2"),
        ("WORST_SLACK_NS=-0.1", "WORST_SLACK_NS=-0.201"),
        ("WORST_SLACK_NS=-0.1", "WORST_SLACK_NS=Infinity"),
        ("WORST_SLACK_NS=-0.1\n", ""),
        ("STATUS=PASS", "STATUS=PASS\nSTATUS=PASS"),
        ("STATUS=PASS", "STATUS=PASS\nEXTRA=1"),
        ("STATUS=PASS", "STATUS PASS"),
    ),
)
def test_native_gate_rejects_invalid_or_wrong_clock_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, old: str, new: str
) -> None:
    """Malformed or incompatible evidence cannot authorize downstream work."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    gate.write_text(gate.read_text().replace(old, new))
    assert not fpga_build.x3_place_gate_passes(gate)


@pytest.mark.parametrize(
    "divider,period,valid",
    (
        (2, "6.666", True),
        (2, "6.667", True),
        (2, "6.668", False),
        (3, "9.999", True),
        (4, "13.332", True),
        (4, "13.334", False),
    ),
)
def test_gate_checks_actual_divided_cpu_period(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    divider: int,
    period: str,
    valid: bool,
) -> None:
    """Allow only the documented one-picosecond divided-clock display range."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", str(divider))
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    gate.write_text(
        gate.read_text().replace("CPU_PERIOD_NS=3.333", f"CPU_PERIOD_NS={period}")
    )
    assert fpga_build.x3_place_gate_passes(gate) is valid


@pytest.mark.parametrize("changed", ("checkpoint", "gate", "binding", "unbound"))
def test_promoted_gate_is_bound_to_exact_checkpoint_and_gate(
    tmp_path: Path,
    changed: str,
) -> None:
    """Changing either artifact or removing its binding requires fresh evidence."""
    checkpoint = tmp_path / "post_place.dcp"
    checkpoint.write_bytes(b"qualified checkpoint")
    _write_place_gate(tmp_path, bind=True)
    assert fpga_build.require_x3_post_place_gate(tmp_path)
    if changed == "checkpoint":
        checkpoint.write_bytes(b"different checkpoint")
    elif changed == "gate":
        with (tmp_path / "post_place_gate.txt").open("a") as stream:
            stream.write("\n")  # Semantically equal still has different provenance.
    elif changed == "binding":
        (tmp_path / "post_place_gate_binding.json").write_text("{}")
    else:
        (tmp_path / "post_place_gate_binding.json").unlink()
    assert not fpga_build.require_x3_post_place_gate(tmp_path)
    if changed == "unbound":
        assert not (tmp_path / "post_place_gate_binding.json").exists()


@pytest.mark.parametrize("stage", ("post_synth", "post_opt", "post_place"))
def test_new_checkpoint_promotion_cannot_retain_old_gate(
    tmp_path: Path,
    stage: str,
) -> None:
    """Promoting a new source or placement invalidates the old qualification."""
    source, dest = tmp_path / "source", tmp_path / "dest"
    source.mkdir()
    dest.mkdir()
    (dest / "post_place.dcp").write_bytes(b"old qualified placement")
    _write_place_gate(dest, bind=True)
    (source / f"{stage}.dcp").write_bytes(b"new checkpoint")
    (source / "stale_post_place_gate.txt").write_text("not this checkpoint")
    fpga_build.copy_results_to_main_work(source, dest, f"{stage}.dcp", stage)
    assert not (dest / "post_place_gate.txt").exists()
    assert not (dest / "post_place_gate_binding.json").exists()


def test_place_ranks_actual_zero_uncertainty_reports_and_defaults_to_no_route(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Placement selection uses measured WNS and performs no default routing."""
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT", raising=False)
    candidates = _quick_route_candidates(tmp_path, 2)
    candidates[1].setup_uncertainty_ns = 0.5
    assert fpga_build.directive_sweep_rank_wns(candidates[1]) == -0.09
    assert fpga_build.placement_seed_wns(candidates[1]) == pytest.approx(-0.59)
    monkeypatch.setattr(
        fpga_build,
        "run_x3_place_quick_route_probes",
        lambda *_a, **_kw: pytest.fail("default placement launched quick routing"),
    )
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[1]
    )


def test_explicit_quick_route_only_receives_native_passing_candidates(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A better displayed score cannot bypass a missing native gate."""
    candidates = _quick_route_candidates(tmp_path, 3)
    # The best displayed score has no valid native decision and cannot compete.
    (candidates[2].work_dir / "post_place_gate.txt").unlink()
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    received = []

    def probes(_script: Path, runs: list[Any], _vivado: str, **_kwargs: Any) -> None:
        received.extend(runs)

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", probes)
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[1]
    )
    assert received == [candidates[1], candidates[0]]


def test_failed_place_preserves_best_checkpoint_but_cannot_launch_route(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failed threshold keeps diagnostics and exits before downstream work."""
    fleet = _VivadoFleet(monkeypatch, 1)
    original_popen = fleet.popen

    def failed_place(command: list[str], **kwargs: Any) -> Any:
        process = original_popen(command, **kwargs)
        work_dir = kwargs["cwd"]
        wns = -0.21 if len(fleet.attempts) == 1 else -0.201
        (work_dir / "post_place_timing.rpt").write_text(str(wns))
        _write_place_gate(work_dir, wns)
        return process

    monkeypatch.setattr(fpga_build.subprocess, "Popen", failed_place)
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    main_work = _sweep_input(tmp_path, "place")
    result = fpga_build.run_x3_step_directive_sweep(
        tmp_path,
        "place",
        ["First", "Better"],
        "placer",
        "unused",
        max_jobs=1,
    )
    assert result == (False, -0.201, "post_place")
    assert len(fleet.attempts) == 2
    assert (main_work / "post_place.dcp").read_text() == "work_place_Better"
    assert (main_work / "post_place_timing.rpt").read_text() == "-0.201"
    assert not (main_work / "post_place_gate_binding.json").exists()
    assert all(path.exists() for path in fleet.attempts)
    assert (
        fpga_build.run_step(tmp_path, "x3", "post_place_physopt", "Sweep", "unused")[0]
        is False
    )
    assert len(fleet.attempts) == 2


@pytest.mark.parametrize("step", ("post_place_physopt", "route", "second_route"))
def test_downstream_resume_rejects_stale_gate_before_native_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    step: str,
) -> None:
    """Every resumed downstream entry point validates the placement binding."""
    work = _sweep_input(tmp_path, step)
    (work / "post_place.dcp").write_bytes(b"overwritten checkpoint")
    monkeypatch.setattr(
        fpga_build.subprocess,
        "run",
        lambda *_a, **_k: pytest.fail("stale gate launched"),
    )
    monkeypatch.setattr(
        fpga_build.subprocess,
        "Popen",
        lambda *_a, **_k: pytest.fail("stale gate launched"),
    )
    if step == "post_place_physopt":
        result = fpga_build.run_step(tmp_path, "x3", step, "Sweep", "unused")
    else:
        result = fpga_build.run_x3_step_directive_sweep(
            tmp_path, step, ["Explore"], "router", "unused"
        )
    assert not result[0]
    assert not fpga_build.generate_bitstream(tmp_path, "x3", "unused")


def test_quick_route_rejects_stale_placement_binding(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A probe cannot consume a changed placement under an old PASS record."""
    candidates = _quick_route_candidates(tmp_path, 1)
    (candidates[0].work_dir / "post_place.dcp").write_bytes(b"changed")
    monkeypatch.setattr(
        fpga_build.subprocess,
        "Popen",
        lambda *_a, **_k: pytest.fail("stale probe launched"),
    )
    fpga_build.run_x3_place_quick_route_probes(tmp_path, candidates, "unused")
    assert candidates[0].quick_route_returncode == -1


def test_default_cpu_cli_overrides_stale_environment_before_software_build(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CLI default full rate controls software and synthesis despite inherited env."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "2")
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(sys, "argv", ["build.py", "x3", "--stop-after", "place"])
    observed = []

    def compile_firmware(_root: Path, _output: Path, clock: int) -> bool:
        observed.append((clock, fpga_build.os.environ["FROST_CPU_CLK_DIV"]))
        return False

    monkeypatch.setattr(fpga_build, "compile_hello_world", compile_firmware)
    with pytest.raises(SystemExit) as stopped:
        fpga_build.main()
    assert stopped.value.code == 1
    assert observed == [(300_000_000, "1")]


def test_place_gate_cannot_qualify_a_fallback_checkpoint(tmp_path: Path) -> None:
    """A stray DCP cannot replace the checkpoint named by a native place gate."""
    source, dest = tmp_path / "source", tmp_path / "dest"
    source.mkdir()
    dest.mkdir()
    (source / "stray.dcp").write_bytes(b"unrelated checkpoint")
    _write_place_gate(source)
    fpga_build.copy_results_to_main_work(
        source, dest, "post_place.dcp", "post_place", source_report_prefix="post_place"
    )
    assert not (dest / "post_place.dcp").exists()
    assert not (dest / "post_place_gate.txt").exists()
    assert not fpga_build.bind_x3_place_gate(dest)


@pytest.mark.parametrize("audits_present", (False, True))
def test_post_opt_helper_audits_follow_promotion_before_worker_cleanup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, audits_present: bool
) -> None:
    """Fresh native opt audits survive cleanup; absent audits cannot retain old ones."""
    work = _sweep_input(tmp_path, "opt")
    audit_names = (
        "l1_control_repair_audit.tcldict",
        "x3_nic_placement_post_opt_audit.tcldict",
    )
    for name in audit_names:
        (work / name).write_text("old audit")

    def complete_opt(_command: list[str], *, cwd: Path) -> Any:
        (cwd / "post_opt.dcp").write_bytes(b"new optimized checkpoint")
        _write_stage_utilization(cwd, "post_opt", 42)
        if audits_present:
            for name in audit_names:
                (cwd / name).write_text(f"fresh {name}")
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", complete_opt)
    assert fpga_build.run_step(tmp_path, "x3", "opt", "Explore", "unused") == (
        True,
        -0.1,
        "post_opt",
    )
    assert not (tmp_path / "x3/work_opt_Explore").exists()
    assert (work / "post_opt.dcp").read_bytes() == b"new optimized checkpoint"
    for name in audit_names:
        if audits_present:
            assert (work / name).read_text() == f"fresh {name}"
        else:
            assert not (work / name).exists()


def test_missing_placement_checkpoint_cannot_defeat_complete_passing_seed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A gate file without its output checkpoint is not a usable sweep result."""
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT", raising=False)
    candidates = _quick_route_candidates(tmp_path, 2)
    (candidates[1].work_dir / "post_place.dcp").unlink()
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[0]
    )
    (candidates[0].work_dir / "post_place.dcp").unlink()
    assert fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused") is None


@pytest.mark.parametrize("extras", [False, True])
def test_retired_toggles_cannot_add_or_modify_placement_candidates(
    extras: bool,
) -> None:
    """Retired requests neither add a second-pass variant nor change manual bloat."""
    inherited = {
        "FROST_PLACE_FLUSH_INCREMENTAL": "1",
        "FROST_X3_PD_TARGET_PIN_SWAPS": "auto",
        "FROST_PLACE_CELL_BLOAT": "LOW",
        "FROST_PLACE_CELL_BLOAT_CELLS": "manual_target",
    }
    candidates = fpga_build.make_x3_place_sweep_candidates(
        ["ExtraNetDelay_high"], [0.300], inherited, include_extra_seeds=extras
    )
    assert [candidate.label for candidate in candidates] == (
        ["ExtraNetDelay_high_u0.300", "ExtraPostPlacementOpt_u0.425"]
        if extras
        else ["ExtraNetDelay_high_u0.300"]
    )
    for candidate in candidates:
        environment = candidate.environment(inherited)
        assert "FROST_PLACE_FLUSH_INCREMENTAL" not in environment
        assert "FROST_X3_PD_TARGET_PIN_SWAPS" not in environment
        assert environment["FROST_PLACE_CELL_BLOAT"] == "LOW"
        assert environment["FROST_PLACE_CELL_BLOAT_CELLS"] == "manual_target"
    assert inherited["FROST_PLACE_FLUSH_INCREMENTAL"] == "1"


def test_retired_flags_do_not_launch_an_extra_worker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only the requested control and retained off-grid candidate launch."""
    monkeypatch.setenv("FROST_PLACE_FLUSH_INCREMENTAL", "1")
    monkeypatch.setenv("FROST_X3_PD_TARGET_PIN_SWAPS", "1")
    monkeypatch.setenv("FROST_PLACE_CELL_BLOAT", "LOW")
    monkeypatch.setenv("FROST_PLACE_CELL_BLOAT_CELLS", "manual_target")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    monkeypatch.setattr(fpga_build, "x3_pc_tail_group_audit_is_valid", lambda *_: True)
    fleet = _VivadoFleet(monkeypatch, 1)
    popen = fleet.popen
    launches = []

    def record(command: list[str], **kwargs: Any) -> Any:
        launches.append((command, kwargs["cwd"], kwargs["env"]))
        return popen(command, **kwargs)

    monkeypatch.setattr(fpga_build.subprocess, "Popen", record)
    main_work = _sweep_input(tmp_path, "place")
    result = fpga_build.run_x3_step_directive_sweep(
        tmp_path,
        "place",
        ["ExtraNetDelay_high"],
        "placer",
        "unused",
        setup_uncertainties_ns=[0.300],
        max_jobs=1,
        keep_temps=True,
    )
    assert result[0]
    assert len(launches) == 2
    for command, _, environment in launches:
        args = command[command.index("-tclargs") + 1 :]
        assert args[0:2] == ["x3", "place"]
        assert args[3] == str(main_work / "post_opt.dcp")
        assert "FROST_PLACE_FLUSH_INCREMENTAL" not in environment
        assert "FROST_X3_PD_TARGET_PIN_SWAPS" not in environment
        assert environment["FROST_PLACE_CELL_BLOAT"] == "LOW"
        assert environment["FROST_PLACE_CELL_BLOAT_CELLS"] == "manual_target"
    assert not (main_work / "post_place_flush_guidance_audit.tcldict").exists()
    assert not (main_work / "post_place_pin_swap_audit.txt").exists()


def test_new_300mhz_gate_cannot_authorize_retained_150mhz_physopt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A valid new placement gate cannot lend its clock qualification to an old child."""
    work = tmp_path / "x3/work"
    work.mkdir(parents=True)
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "2")
    (work / "post_place.dcp").write_bytes(b"150 MHz placement")
    _write_place_gate(work)
    gate = work / "post_place_gate.txt"
    gate.write_text(
        gate.read_text().replace("CPU_PERIOD_NS=3.333", "CPU_PERIOD_NS=6.666")
    )
    assert fpga_build.bind_x3_place_gate(work)
    child = _write_qualified_descendant(work, "post_place_physopt")
    report = work / "post_place_physopt_timing.rpt"
    report.write_text("preserved 150 MHz report")
    old_child, old_report = child.read_bytes(), report.read_bytes()
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    (work / "post_place.dcp").write_bytes(b"new 300 MHz placement")
    _write_place_gate(work, bind=True)
    assert fpga_build.require_x3_post_place_gate(work)
    monkeypatch.setattr(
        fpga_build.subprocess,
        "Popen",
        lambda *_a, **_k: pytest.fail("stale descendant launched"),
    )
    assert not fpga_build.run_x3_step_directive_sweep(
        tmp_path, "route", ["Explore"], "router", "unused"
    )[0]
    assert "Rerun from post_place_physopt" in capsys.readouterr().out
    assert child.read_bytes() == old_child and report.read_bytes() == old_report


@pytest.mark.parametrize(
    "change", ("missing", "child_bytes", "parent_bytes", "wrong_stage", "gate_bytes")
)
def test_downstream_chain_rejects_missing_or_changed_provenance(
    tmp_path: Path, change: str
) -> None:
    """Every consumed chain edge and the placement anchor must still match."""
    work = _sweep_input(tmp_path, "post_route_physopt")
    child = work / "post_route.dcp"
    record_path = child.with_suffix(".lineage.json")
    assert fpga_build.capture_x3_input_lineage(work, child.name) is not None
    if change == "missing":
        record_path.unlink()
    elif change == "child_bytes":
        child.write_bytes(b"replacement route")
    elif change == "parent_bytes":
        (work / "post_place_physopt.dcp").write_bytes(b"replacement parent")
    elif change == "gate_bytes":
        with (work / "post_place_gate.txt").open("a") as stream:
            stream.write("\n")
        assert fpga_build.bind_x3_place_gate(work)
    else:
        record = json.loads(record_path.read_text())
        record["stage"] = "synth"
        record_path.write_text(json.dumps(record))
    assert fpga_build.capture_x3_input_lineage(work, child.name) is None
    assert child.exists()


@pytest.mark.parametrize(
    "stage",
    ("route", "post_route_physopt", "second_route", "post_second_route_physopt"),
)
def test_completed_final_producer_binds_chain_and_bitstream_checks_actual_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, stage: str
) -> None:
    """Each legal final producer qualifies only its exact output for bitstream use."""
    work = _sweep_input(tmp_path, stage)
    calls = []

    def complete(command: list[str], *, cwd: Path) -> Any:
        native_step = command[command.index("-tclargs") + 2]
        calls.append(native_step)
        if native_step == "bitstream":
            assert command[command.index("-tclargs") + 4] == str(work / "final.dcp")
            (cwd / "x3_frost.bit").write_bytes(b"bitstream fixture")
        else:
            prefix = fpga_build._TCL_REPORT_PREFIX[stage]
            (cwd / f"{prefix}.dcp").write_bytes(b"completed final checkpoint")
            _write_stage_utilization(cwd, prefix, 42)
            report = cwd / f"{prefix}_timing.rpt"
            report.write_text(report.read_text().replace("-0.100", "0.050"))
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", complete)
    assert fpga_build.run_step(tmp_path, "x3", stage, "Explore", "unused") == (
        True,
        0.05,
        "final",
    )
    assert fpga_build.capture_x3_input_lineage(work, "final.dcp") is not None
    assert fpga_build.generate_bitstream(tmp_path, "x3", "unused")
    assert calls == [stage, "bitstream"]
    (work / "final.dcp").write_bytes(b"different final checkpoint")
    assert not fpga_build.generate_bitstream(tmp_path, "x3", "unused")
    assert calls == [stage, "bitstream"]


def test_intermediate_physopt_publication_cannot_inherit_prior_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed run retains intermediate DCP/report bytes with no valid lineage."""
    work = _sweep_input(tmp_path, "route")
    _write_qualified_descendant(work, "route", final=True)
    assert fpga_build.capture_x3_input_lineage(work, "final.dcp") is not None
    report = work / "post_place_physopt_timing.rpt"

    def interrupted(_command: list[str], *, cwd: Path) -> Any:
        assert not (work / "post_place_physopt.lineage.json").exists()
        (work / "post_place_physopt.dcp").write_bytes(b"intermediate native checkpoint")
        report.write_bytes(b"intermediate native report")
        assert fpga_build.capture_x3_input_lineage(work, "final.dcp") is None
        return SimpleNamespace(returncode=1)

    monkeypatch.setattr(fpga_build.subprocess, "run", interrupted)
    assert not fpga_build.run_step(
        tmp_path, "x3", "post_place_physopt", "Sweep", "unused"
    )[0]
    assert (
        work / "post_place_physopt.dcp"
    ).read_bytes() == b"intermediate native checkpoint"
    assert report.read_bytes() == b"intermediate native report"
    assert (work / "final.dcp").exists()
    assert fpga_build.capture_x3_input_lineage(work, "post_place_physopt.dcp") is None


@pytest.mark.parametrize(
    "change", ("parent", "missing_worker_output", "promoted_output")
)
def test_downstream_completion_rechecks_prelaunch_parent_and_promoted_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, change: str
) -> None:
    """Clean process exit cannot qualify changed inputs or an unrelated promoted DCP."""
    work = _sweep_input(tmp_path, "route")

    def complete(_command: list[str], *, cwd: Path) -> Any:
        output_name = (
            "stray.dcp" if change == "missing_worker_output" else "post_route.dcp"
        )
        (cwd / output_name).write_bytes(b"completed route")
        _write_stage_utilization(cwd, "post_route", 42)
        if change == "parent":
            consumed = fpga_build.capture_x3_input_lineage(work, "post_place.dcp")
            source = work / "replacement/phys_opt.dcp"
            source.parent.mkdir()
            source.write_bytes(b"new valid parent from same qualified placement")
            (work / "post_place_physopt.dcp").write_bytes(source.read_bytes())
            assert fpga_build.bind_x3_output_lineage(
                work, "post_place_physopt", "post_place_physopt.dcp", source, consumed
            )
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", complete)
    if change == "promoted_output":
        original = fpga_build.copy_results_to_main_work

        def corrupt(*args: Any, **kwargs: Any) -> None:
            original(*args, **kwargs)
            (work / "post_route.dcp").write_bytes(b"wrong promoted bytes")

        monkeypatch.setattr(fpga_build, "copy_results_to_main_work", corrupt)
    assert not fpga_build.run_step(tmp_path, "x3", "route", "Explore", "unused")[0]
    assert (work / "post_route.dcp").exists()
    assert not (work / "post_route.lineage.json").exists()
    assert (tmp_path / "x3/work_route_Explore").exists()


# Trimmed but genuine ``report_design_analysis -congestion`` output kept beside
# this file: two placements that reported windows (X3 Long/Short level 5,
# genesys2 Global level 6) and one that reported none. Only the Host/Command
# header lines were rewritten; the tables are as Vivado wrote them. A veto that
# silently parses nothing is invisible, so the row regex is measured against
# real reports instead of hand-written ones.
CONGESTION_FIXTURES = REPO_ROOT / "tests/fixtures"


@pytest.mark.parametrize(
    ("fixture", "expected_levels", "expected_max"),
    (
        ("x3_post_place_congestion.rpt", [5, 5, 5], 5),
        ("genesys2_post_place_congestion.rpt", [6, 6], 6),
        ("x3_post_place_congestion_clear.rpt", [], 0),
    ),
)
def test_congestion_regex_reads_real_vivado_reports(
    tmp_path: Path, fixture: str, expected_levels: list[int], expected_max: int
) -> None:
    """Real report rows still yield their Level column, and only those rows."""
    report = CONGESTION_FIXTURES / fixture
    text = report.read_text()
    assert [
        int(match.group(1)) for match in fpga_build._CONGESTION_ROW_RE.finditer(text)
    ] == expected_levels
    # Parse the table independently so a regex that drifts into matching the
    # header, a separator or the "no congestion windows" line is caught too.
    table_rows = [
        [cell.strip() for cell in line.strip().strip("|").split("|")]
        for line in text.splitlines()
        if line.startswith("|") and line.rstrip().endswith("|")
    ]
    data_rows = [
        row
        for row in table_rows
        if row[0] in {"North", "South", "East", "West"} and row[2].isdigit()
    ]
    assert [int(row[2]) for row in data_rows] == expected_levels
    assert all(row[1] in {"Global", "Long", "Short"} for row in data_rows)
    copied = tmp_path / "post_place_congestion.rpt"
    copied.write_text(text)
    assert fpga_build.extract_max_congestion_level(copied) == expected_max
    assert fpga_build.extract_max_congestion_level(tmp_path / "absent.rpt") is None


def test_congestion_veto_decides_on_real_report_levels(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Genuine level-5 and level-6 reports are vetoed; the clear seed wins."""
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    monkeypatch.delenv("FROST_PLACE_CONGESTION_VETO_LEVEL", raising=False)
    candidates = _quick_route_candidates(tmp_path, 3)
    for run, fixture in zip(
        candidates,
        (
            "x3_post_place_congestion_clear.rpt",
            "x3_post_place_congestion.rpt",
            "genesys2_post_place_congestion.rpt",
        ),
    ):
        (run.work_dir / "post_place_congestion.rpt").write_text(
            (CONGESTION_FIXTURES / fixture).read_text()
        )
    # The congested seeds hold the better displayed WNS (-0.09 and -0.08).
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[0]
    )
    assert [run.congestion_level for run in candidates] == [0, 5, 6]
    assert [run.congestion_vetoed for run in candidates] == [False, True, True]
    assert (
        "Congestion veto (level >= 5) removed 2/3 place seeds"
        in capsys.readouterr().out
    )
    # Raising the threshold admits the level-5 report and its better WNS.
    monkeypatch.setenv("FROST_PLACE_CONGESTION_VETO_LEVEL", "6")
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[1]
    )
    assert [run.congestion_vetoed for run in candidates] == [False, False, True]
