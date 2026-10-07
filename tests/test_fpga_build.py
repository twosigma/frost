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

"""Tests for the native FPGA build: build.py, build_step.tcl, and what they rely on."""

import importlib.util
import json
import os
from decimal import Decimal
from pathlib import Path
import re
import subprocess
import sys
import zipfile
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


def _write_probe_outputs(work_dir: Path, prefix: str, wns: float = -0.1) -> None:
    """Write usable timing, a native complete-route status, and a clean tool log."""
    _write_stage_utilization(work_dir, prefix, 42)
    timing = work_dir / f"{prefix}_timing.rpt"
    timing.write_text(timing.read_text().replace("-0.100", f"{wns:.3f}"))
    (work_dir / f"{prefix}_status.rpt").write_text(
        (REPO_ROOT / "tests/fixtures/x3_quick_route_status_complete.rpt").read_text()
    )
    (work_dir / f"{prefix}_vivado.log").write_text(
        "route_design completed successfully\n"
    )


def _write_test_selection(work_dir: Path, wns: float) -> None:
    """Certify this test checkpoint as a selected, successfully probed placement."""
    checkpoint = work_dir / "post_place.dcp"
    _write_probe_outputs(work_dir, "post_place_quick_route")
    (work_dir / "post_place_selection.json").write_text(
        json.dumps(
            {
                "schema": "x3_place_selection_v1",
                "selected": "fixture",
                "quick_route_count": fpga_build.x3_quick_route_count(),
                "candidates": [
                    {
                        "label": "fixture",
                        "placed_wns_ns": wns,
                        "checkpoint_sha256": fpga_build.file_sha256(checkpoint)
                        if checkpoint.exists()
                        else None,
                        "quick_route_returncode": 0,
                        "quick_route_wns_ns": -0.1,
                        "quick_route_congestion_warning": False,
                    }
                ],
            }
        )
    )


def _write_place_gate(
    work_dir: Path, wns: float = -0.1, *, bind: bool = False, probe_input: bool = False
) -> None:
    """Write post_place_gate.txt as x3_post_place_gate.tcl does; bind it if asked."""
    passed = wns >= -0.2
    (work_dir / "post_place_gate.txt").write_text(
        f"STATUS={'PASS' if passed else 'FAIL'}\n"
        "THRESHOLD_NS=-0.200\nCPU_PERIOD_NS=3.103\n"
        "USER_SETUP_UNCERTAINTY_NS=0.000\n"
        f"STRICT_BELOW_GATE_PATHS={0 if passed else 1}\n"
        f"WORST_SLACK_NS={wns}\n"
    )
    congestion = work_dir / "post_place_congestion.rpt"
    if not congestion.exists():
        congestion.write_text(
            (
                REPO_ROOT / "tests/fixtures/x3_post_place_congestion_clear.rpt"
            ).read_text()
        )
    if not probe_input:
        _write_test_selection(work_dir, wns)
    if bind:
        assert fpga_build.bind_x3_place_gate(work_dir, wns, probe_input=probe_input)


def _write_qualified_descendant(
    work_dir: Path, stage: str, *, final: bool = False
) -> Path:
    """Write a finished output of stage and record it with bind_x3_output_lineage()."""
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
        "clock_from_mmcm {0.000 1.667} 3.103 322.266\n"
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
    assert util["clock_freq_mhz"] == 322.266
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
    (work_dir / fpga_build.X3_NETLIST_CONFIG_NAME).write_text(
        json.dumps(
            {
                "schema": "x3_netlist_config_v3",
                "cpu_base_clock_hz": 322265625,
                "cpu_clock_div": 1,
            }
        )
    )
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
    monkeypatch.setattr(fpga_build, "run_x3_default_place", complete_stage)
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
        lambda _report: {"clock_freq_mhz": 322.266},
    )

    utilization = timing_util_summary.collect_all_board_utilization(tmp_path)
    provenance = utilization["x3"]["report_provenance"]
    assert provenance == "`ExtraNetDelay_high`/0.500"

    section = timing_util_summary.format_readme_utilization_section(utilization)
    assert (
        "**Alveo X3522PV** (Virtex UltraScale+ @ 322 MHz; "
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
    """Provenance lists every manual cell-bloat pattern that matched cells."""
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


def test_hello_world_compile_replaces_obsolete_init_images(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """compile_hello_world deletes obsolete init images and writes the scalar-replica ones.

    common.mk, the init generator, and build_step.tcl agree on the replica list.
    """
    app_dir = tmp_path / "sw/apps/hello_world"
    output_dir = tmp_path / "board-work/hello_world"
    app_dir.mkdir(parents=True)
    output_dir.mkdir(parents=True)

    obsolete_names = fpga_build.IMEM_OBSOLETE_INIT_IMAGE_NAMES
    assert "sw_imem_even_pc_metadata.mem" in obsolete_names
    assert "sw_imem_odd_pc_metadata_bit3.mem" in obsolete_names
    for name in obsolete_names:
        (output_dir / name).write_text("stale\n")

    def fake_run(command: list[str], **_kwargs: Any) -> Any:
        for assignment in command[2:]:
            _name, output_path = assignment.split("=", maxsplit=1)
            Path(output_path).write_text("generated\n")
        return fpga_build.subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(fpga_build.subprocess, "run", fake_run)

    assert fpga_build.compile_hello_world(tmp_path, output_dir, 322_265_625)
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
    for name in obsolete_names:
        assert not (output_dir / name).exists()

    common_mk = (REPO_ROOT / "sw/common/common.mk").read_text()
    clean_rule = common_mk[common_mk.index("clean:") :]
    for name in obsolete_names:
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
    for obsolete_name in obsolete_names:
        assert obsolete_name not in build_tcl


def test_default_x3_sweep_contains_every_guided_pc_tail_candidate() -> None:
    """The default sweep has every PC-tail-guided directive/uncertainty pair.

    Two pairs are on the default 50 ps grid. The off-grid 0.425 seed comes from
    the extra-seed list, which every full-rate sweep appends. Every pair gets
    the PC-tail guidance.
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
    # The extra seed is off the 50 ps grid; the grid already covers on-grid
    # values.
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
    """A narrowed grid gets a LOW variant only beside its control.

    It still gets the off-grid seed, exactly once.
    """
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
    """Setting either bloat variable, even to empty, drops the LOW variants.

    Every candidate then inherits the caller's settings unchanged.
    """
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
    """A LOW variant counts only if its one bloat line sets LOW on one int-RS cell."""
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


@pytest.mark.parametrize(
    ("memory_factor", "memory_count", "extra", "valid"),
    (
        ("MEDIUM", 1, "", True),
        ("MEDIUM", 0, "", False),
        ("MEDIUM", 2, "", False),
        ("LOW", 1, "", False),
        (None, 1, "", False),
        (
            "MEDIUM",
            1,
            "Set CELL_BLOAT_FACTOR MEDIUM on 1 cell(s) matching '*u_tomasulo/u_rob'\n",
            False,
        ),
    ),
)
def test_x3_bloat_requires_each_requested_hierarchy_exactly_once(
    tmp_path: Path,
    memory_factor: str | None,
    memory_count: int,
    extra: str,
    valid: bool,
) -> None:
    """A two-station recipe cannot silently spread only one or extra hierarchies."""
    log = tmp_path / "vivado.log"
    log.write_text(
        "Set CELL_BLOAT_FACTOR MEDIUM on 1 cell(s) matching '*u_tomasulo/u_int_rs'\n"
        + (
            f"Set CELL_BLOAT_FACTOR {memory_factor} on {memory_count} cell(s) "
            "matching '*u_tomasulo/u_mem_rs'\n"
            if memory_factor is not None
            else ""
        )
        + extra
    )
    assert (
        fpga_build.x3_place_cell_bloat_override_is_valid(
            log, "MEDIUM", "*u_tomasulo/u_int_rs *u_tomasulo/u_mem_rs"
        )
        is valid
    )


@pytest.mark.parametrize(
    ("matches", "expected_matches", "valid"),
    (
        ((1, 2172), (1, None), True),
        ((1, 1), (1, None), True),
        ((1, 0), (1, None), False),
        ((2, 2172), (1, None), False),
        ((1, 2172), None, False),
        ((1, 2172), (1,), False),
    ),
)
def test_leaf_group_bloat_keeps_hierarchy_scope_strict(
    tmp_path: Path,
    matches: tuple[int, int],
    expected_matches: tuple[int | None, ...] | None,
    valid: bool,
) -> None:
    """Only an explicitly declared group may match multiple primitive cells."""
    patterns = ("*u_tomasulo/u_int_rs", "*u_tomasulo/u_mem_rs/rs_src2_value*")
    log = tmp_path / "vivado.log"
    log.write_text(
        "".join(
            f"Set CELL_BLOAT_FACTOR MEDIUM on {count} cell(s) matching '{pattern}'\n"
            for count, pattern in zip(matches, patterns)
        )
    )
    assert (
        fpga_build.x3_place_cell_bloat_override_is_valid(
            log, "MEDIUM", " ".join(patterns), expected_matches
        )
        is valid
    )


@pytest.mark.parametrize("bloat_match_valid", (True, False))
def test_x3_place_worker_isolates_and_validates_bloat_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, bloat_match_valid: bool
) -> None:
    """Only the LOW variant's worker gets the bloat variables.

    The variant is promoted only if its bloat matched.
    """
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
    """The PC-tail audit passes only for its own guided seed, with every check met.

    Exactly the expected fields must appear, once each and well formed. Replica
    counts may change, and placement may merge a canonical endpoint into its
    replicas, but the pre-place scope must have every canonical endpoint.
    """
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
                "POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=1",
                "POST_STATE_CANONICAL_NAMES_WITHIN_PRE=1",
                "POST_SEQ_CANONICAL_NAMES_WITHIN_PRE=1",
                "POST_PENDING_CANONICAL_NAMES_WITHIN_PRE=1",
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

    # Placement removed one noncanonical state-PC replica (93 -> 92). The audit
    # still passes: no canonical name is new, and the selected and state PC
    # families still cover all 64 bits.
    assert fpga_build.x3_pc_tail_group_audit_is_valid(
        audit, "ExtraNetDelay_high", 0.500
    )

    # Equivalent-driver rewiring merged the canonical pending-valid register
    # into its replica: every scope still has a pending-valid endpoint.
    merged_pending_audit = valid_audit.replace(
        "POST_PENDING_CANONICAL=1", "POST_PENDING_CANONICAL=0"
    ).replace("SCORE_PENDING_CANONICAL=1", "SCORE_PENDING_CANONICAL=0")
    audit.write_text(merged_pending_audit)
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
        valid_audit.replace("PRE_PENDING_CANONICAL=1", "PRE_PENDING_CANONICAL=0"),
        valid_audit.replace("POST_PENDING_CANONICAL=1", "POST_PENDING_CANONICAL=0"),
        valid_audit.replace("SCORE_PENDING_CANONICAL=1", "SCORE_PENDING_CANONICAL=0"),
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
            "POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=1",
            "POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=0",
        ),
        valid_audit.replace(
            "POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=1",
            "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1",
        ),
        valid_audit.replace(
            "POST_STATE_CANONICAL_NAMES_WITHIN_PRE=1",
            "POST_STATE_CANONICAL_NAMES_WITHIN_PRE=0",
        ),
        valid_audit.replace(
            "POST_STATE_CANONICAL_NAMES_WITHIN_PRE=1",
            "PRE_STATE_CANONICAL_NAMES_MATCH_POST=1",
        ),
        valid_audit.replace(
            "POST_SEQ_CANONICAL_NAMES_WITHIN_PRE=1",
            "POST_SEQ_CANONICAL_NAMES_WITHIN_PRE=0",
        ),
        valid_audit.replace(
            "POST_SEQ_CANONICAL_NAMES_WITHIN_PRE=1",
            "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1",
        ),
        valid_audit.replace(
            "POST_PENDING_CANONICAL_NAMES_WITHIN_PRE=1",
            "POST_PENDING_CANONICAL_NAMES_WITHIN_PRE=0",
        ),
        valid_audit.replace(
            "POST_PENDING_CANONICAL_NAMES_WITHIN_PRE=1",
            "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1",
        ),
        valid_audit.replace(
            "POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=1",
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
    """Promoting a guided placement keeps its group audit and PC-tail report.

    The gate reports come with it; a pin-swap audit does not.
    """
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
    """Promoting an unguided placement deletes guidance audits left by an older one."""
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


def test_pc_tail_groups_are_removed_before_scoring_reports() -> None:
    """The PC-tail path group is validated and used only for placement.

    It is removed before the post-place checkpoint is written, reopened, and
    scored.
    """
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
    assert 'validate_x3_pc_compressed_tail_scope "pre-place"]' in trigger_text
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
    assert "has more than one canonical non-replica endpoint" in tcl
    assert "if {$require_canonical && $canonical_count != 1}" in tcl
    assert "is not clocked exactly by clock_from_mmcm" in tcl
    assert "-filter {IS_CLOCK == 1}" in tcl
    assert "PRE_ENDS=112" not in tcl
    assert "PC-metadata tail start names differ" in tcl[place:remove_compressed_group]
    # After placement a bit may have lost its canonical endpoint to
    # equivalent-driver rewiring, but no canonical name may be new.
    post_place_checks = tcl[place:remove_compressed_group]
    assert 'validate_x3_pc_compressed_tail_scope "post-place" 0]' in post_place_checks
    for family in ("selected", "state", "sequential", "pending"):
        assert (
            f'require_x3_pc_tail_canonical_names_within "{family} PC-tail"'
            in post_place_checks
        )
    assert "canonical endpoint names differ" not in tcl
    assert "is not a pre-place canonical endpoint" in tcl
    assert "FROST_PC_TAIL_MERGED_CANONICAL" in tcl
    assert 'validate_x3_pc_compressed_tail_scope "clean-reopen" 0]' in tcl[reopen:]
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
    assert '"POST_SELECTED_CANONICAL_NAMES_WITHIN_PRE=1"' in tcl
    assert "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST" not in tcl
    assert '"POST_STATE_CANONICAL_NAMES_WITHIN_PRE=1"' in tcl
    assert "PRE_STATE_CANONICAL_NAMES_MATCH_POST" not in tcl
    assert '"POST_SEQ_CANONICAL_NAMES_WITHIN_PRE=1"' in tcl
    assert "PRE_SEQ_CANONICAL_NAMES_MATCH_POST" not in tcl
    assert '"POST_PENDING_CANONICAL_NAMES_WITHIN_PRE=1"' in tcl
    assert "PRE_PENDING_CANONICAL_NAMES_MATCH_POST" not in tcl
    assert '"SCORE_PC_BITS=$x3_pc_tail_score_bit_count"' in tcl
    assert '"SCORE_START_NAMES_MATCH_POST=1"' not in tcl
    assert '"SCORED_GROUPS=' not in tcl
    assert '"SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1"' in tcl
    assert '"DIRECTIVE=$directive"' in tcl
    assert '"PLACE_UNCERTAINTY_NS=[format %.3f $x3_place_uncertainty]"' in tcl
    assert '"SCORE_UNCERTAINTY_NS=[format %.3f $x3_place_baseline_uncertainty]"' in tcl
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
    """IF's PC predicates come from a LUTRAM overlay, with a redecoded fallback.

    In the low 64 KiB, each of the seven predicates launches from its own LUTRAM
    copy in each parity bank. The full-depth sideband block RAM is the
    simulation reference for the copies and never feeds those predicates
    directly. Outside the overlay, a repeated request loads the predicate
    redecoded from the fetched word into the same output flop, with no second
    register or output mux. The test also checks the low-BRAM fetch presenter
    in each fetch build and IF's registered fetch redirect.
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
    assert "localparam int unsigned FastLaneWidth = 4;" in imem
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
    assert "FAST_REPLICA_WIDTH = 4" in generator
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
        assert (
            len(
                re.findall(
                    r"low_bram_fetch_presenter(?:\s*#\s*\(.*?\))?\s+u_low_bram_fetch_presenter",
                    block,
                    re.DOTALL,
                )
            )
            == 1
        )
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
    # The provider selects the cached PC sideband by parity before its payload
    # register. Selecting it afterwards, from the registered bank select, would
    # lengthen the served-window coverage -> PC path by a LUT and a routing hop.
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

    assert (
        len(
            re.findall(
                r"low_bram_fetch_presenter(?:\s*#\s*\(.*?\))?\s+u_low_bram_fetch_presenter",
                cpu_and_mem,
                re.DOTALL,
            )
        )
        == 3
    )
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
        ("o_fetch_pa_valid", "i_pa_valid", "presented_pa_valid_q"),
    ):
        assert (
            f"assign {output_name} = repeat_presented ? {held_name} : {live_name};"
            in presenter
        )
    # Only PA bits [15:0] take the separate address retarget; the VA, PA[31:16],
    # and the other outputs keep the full retarget.
    assert "parameter bit SEPARATE_ADDRESS_RETARGET = 1'b0" in presenter
    assert ".SEPARATE_ADDRESS_RETARGET(1'b1)" in provider_block
    assert ".i_address_retarget(fetch_redirect)" in provider_block
    for pa in ("pa0", "pa1"):
        assert (
            f"repeat_presented ? presented_{pa}_q[31:16] : i_{pa}[31:16]" in presenter
        )
        assert f"repeat_address ? presented_{pa}_q[15:0] : i_{pa}[15:0]" in presenter
    assert "presented_pc_q          <= o_fetch_address;" in presenter
    assert "i_response_ready && !i_retarget" not in presenter

    if_stage = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv").read_text()
    redirect_block_match = re.search(
        r"fetch_redirect fetch_redirect_inst \((.*?)\n  \);", if_stage, re.S
    )
    assert redirect_block_match is not None
    # Producer and consumer proofs justify omitting the sequential catch-up arm.
    assert "npc_cond_for_redirect = npc_cond[riscv_pkg::PcNextArms-1:1];" in if_stage
    assert "npc_cond_for_redirect[11] = 1'b0;" in if_stage
    redirect_block = redirect_block_match.group(1)
    for port, signal in (
        ("i_clk", "i_clk"),
        ("i_reset", "i_pipeline_ctrl.reset"),
        ("i_pc_update_en", "pc_update_en"),
        ("i_npc_cond", "npc_cond_for_redirect"),
        ("i_npc_seq", "npc_seq[riscv_pkg::PcNextArms-1:1]"),
        ("i_live_prediction_emits_with_output", "live_prediction_emits_with_output"),
        ("o_fetch_redirect", "o_fetch_redirect"),
    ):
        assert f".{port}({signal})" in redirect_block
    # fetch_redirect's formal proof covers arbitrary inputs. IF also checks its
    # registered output in simulation against the direct equation on npc_sel.
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
    """build_step.tcl adds no false-path, multicycle, or max-delay exceptions.

    Board, IP, and clock-crossing constraints live elsewhere and are not checked
    here. A false path through the front end's buffer-release control would need
    that control to be stable during the cycle before every cycle that depends on
    it, but a pending prediction can start in the cycle right after a buffer
    release, so no such exception is safe.
    """
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    for exception in ("set_false_path", "set_multicycle_path", "set_max_delay"):
        assert exception not in tcl
    assert "prediction_release" not in tcl


def test_x3_constraints_define_no_fetch_cluster_pblock() -> None:
    """x3.xdc defines no frost_fetch_cluster pblock."""
    xdc = (REPO_ROOT / "boards/x3/constr/x3.xdc").read_text()
    assert "frost_fetch_cluster" not in xdc


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
        r"x3 \[dict create part_number xcux35-vsva1365-3-e has_ddr 1 has_gty 1\]", tcl
    )


def test_board_gty_generation_is_capability_gated() -> None:
    """The NIC transceiver core is created only for boards that declare one.

    It is created before the synth step generates and synthesizes the IP
    cores, so it goes through the same generate_target and synth_ip calls.
    """
    tcl = (REPO_ROOT / "fpga/build/build_step.tcl").read_text()
    registry = tcl.index("set board_build_configs")
    capability = tcl.index(
        "set board_has_gty [dict get $board_build_config has_gty]", registry
    )
    guard = re.search(r"    if \{\$board_has_gty\} \{\n(.*?)\n    \}", tcl, re.DOTALL)
    assert guard is not None
    assert registry < capability < guard.start()
    guarded_body = guard.group(1)
    for operation in (
        "${board_name}_gty_ip.tcl",
        "create_${board_name}_gty_ip",
        "[getenv_default FROST_GTY_RX_EQ LPM]",
    ):
        assert operation in guarded_body
    generate = tcl.index("generate_target all [get_ips]")
    assert guard.end() < generate < tcl.index("synth_ip [get_ips]")

    gty = (REPO_ROOT / "fpga/build/x3_gty_ip.tcl").read_text()
    assert "proc create_x3_gty_ip {{rx_eq_mode LPM}}" in gty
    for setting in (
        "CONFIG.CHANNEL_ENABLE {X0Y28}",
        "CONFIG.TX_REFCLK_SOURCE {X0Y28 clk0}",
        "CONFIG.RX_REFCLK_SOURCE {X0Y28 clk0}",
        "CONFIG.TX_REFCLK_FREQUENCY {161.1328125}",
        "CONFIG.TX_DATA_ENCODING {RAW}",
        "CONFIG.RX_BUFFER_MODE {1}",
        "CONFIG.RX_OUTCLK_SOURCE {RXOUTCLKPMA}",
        "CONFIG.FREERUN_FREQUENCY {150}",
    ):
        assert setting in gty

    # The CPU clock's core: a CPLL-only channel (no COMMON, so the NIC core
    # keeps the quad's QPLL0) whose TXOUTCLK is 322.265625 MHz.
    assert "proc create_x3_cpu_clock_gty_ip {}" in gty
    assert gty.index("proc create_x3_cpu_clock_gty_ip") > gty.index(
        "  create_x3_cpu_clock_gty_ip\n"
    )
    for setting in (
        "CONFIG.CHANNEL_ENABLE {X0Y29}",
        "CONFIG.TX_REFCLK_SOURCE {X0Y29 clk0}",
        "CONFIG.TX_PLL_TYPE {CPLL}",
        "CONFIG.RX_PLL_TYPE {CPLL}",
        "CONFIG.TX_LINE_RATE {6.4453125}",
        "CONFIG.TX_INT_DATA_WIDTH {20}",
        "CONFIG.TX_OUTCLK_SOURCE {TXPROGDIVCLK}",
        "CONFIG.LOCATE_TX_USER_CLOCKING {EXAMPLE_DESIGN}",
    ):
        assert setting in gty

    files = (REPO_ROOT / "boards/x3/x3_frost.f").read_text()
    assert files.index("boards/x3/x3_nic_gty.sv") < files.index("boards/x3/x3_frost.sv")
    assert files.index("boards/x3/x3_cpu_clock_gty.sv") < files.index(
        "boards/x3/x3_frost.sv"
    )
    top = (REPO_ROOT / "boards/x3/x3_frost.sv").read_text()
    assert ".RAW_LOOPBACK(0)" in top
    assert "CLKOUT1" not in top
    xdc = (REPO_ROOT / "boards/x3/constr/x3.xdc").read_text()
    assert (
        "create_clock -period 6.206 -name nic_gty_refclk [get_ports i_nic_refclk_p]"
        in xdc
    )


def test_step_arm_state_is_declared_before_first_use() -> None:
    """cpu_ooo declares each debug-step signal once, before its first use.

    An earlier use would make Vivado infer an implicit net or warn.
    """
    cpu = (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text()
    first_uses = {
        "step_armed_q": "csr_debug_mode || step_armed_q",
        "step_armed_rob_q": "widen_commit_ok && !step_armed_rob_q",
        "step_done_q": "step_done_set || step_done_q",
        "step_done_set": "step_done_set || step_done_q",
    }
    for signal, first_use in first_uses.items():
        declarations = list(re.finditer(rf"\blogic\s+{signal}\s*;", cpu))
        assert len(declarations) == 1
        assert declarations[0].end() < cpu.index(first_use)


def test_mispredict_dispatch_recovery_has_one_structural_gate() -> None:
    """Dispatch takes the preflush candidates and applies the flush itself.

    No timing exception covers that path.
    """
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
    assert ".o_id_valid_preflush(direct_id_valid_preflush)" in cpu
    assert "assign id_valid_preflush = direct_id_valid_preflush;" in cpu
    assert ".o_id_valid_2_preflush(direct_id_valid_2_preflush)" in cpu
    assert "assign id_valid_2_preflush = direct_id_valid_2_preflush;" in cpu
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


def test_route_directives_override_the_x3_router_sweep() -> None:
    """Default to four candidates while allowing any legal explicit override."""
    full = fpga_build.resolve_x3_route_sweep_directives(None)
    assert full == [
        "Explore",
        "AggressiveExplore",
        "NoTimingRelaxation",
        "AlternateCLBRouting",
    ]
    assert full is not fpga_build.ROUTER_SWEEP_DIRECTIVES
    excluded = [
        "RuntimeOptimized",
        "Default",
        "AdvancedSkewModeling",
        "MoreGlobalIterations",
        "HigherDelayCost",
    ]
    assert fpga_build.resolve_x3_route_sweep_directives(
        [*excluded, "Explore", "RuntimeOptimized"]
    ) == [*excluded, "Explore"]
    with pytest.raises(ValueError):
        fpga_build.resolve_x3_route_sweep_directives(["NoSuchDirective"])


def test_functional_build_policy_leaves_full_rate_builds_alone() -> None:
    """A divider of 1 returns the caller's settings and the README refresh."""
    policy = fpga_build.resolve_functional_build_policy(
        1, 322_265_625, ["ExtraNetDelay_high"], 6, False, ["Explore"], False
    )
    assert policy.cpu_clock_div == 1
    assert policy.clock_freq == 322_265_625
    assert policy.place_directives == ["ExtraNetDelay_high"]
    assert policy.place_uncertainty_count == 6
    assert policy.include_extra_seeds
    assert policy.quick_route_count is None
    assert policy.route_directives == ["Explore"]
    assert policy.update_readme


def test_functional_build_policy_collapses_the_sweeps_at_half_clock() -> None:
    """--cpu-clock-div 2 builds for 161 MHz with single RuntimeOptimized runs."""
    policy = fpga_build.resolve_functional_build_policy(
        2,
        322_265_625,
        fpga_build.X3_PLACER_SWEEP_DIRECTIVES,
        fpga_build.X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT,
        False,
        fpga_build.ROUTER_SWEEP_DIRECTIVES,
        False,
    )
    assert policy.clock_freq == 161_132_812
    assert policy.place_directives == ["RuntimeOptimized"]
    assert policy.place_uncertainty_count == 1
    assert not policy.include_extra_seeds
    assert policy.quick_route_count == 0
    assert policy.route_directives == ["RuntimeOptimized"]
    assert not policy.update_readme


def test_functional_build_policy_honors_explicit_sweep_overrides() -> None:
    """Explicit placer and router requests survive the divided-clock policy."""
    policy = fpga_build.resolve_functional_build_policy(
        2, 322_265_625, ["ExtraTimingOpt"], 2, True, ["Explore", "Default"], True
    )
    assert policy.place_directives == ["ExtraTimingOpt"]
    assert policy.place_uncertainty_count == 2
    assert policy.route_directives == ["Explore", "Default"]
    assert not policy.include_extra_seeds
    with pytest.raises(ValueError):
        fpga_build.resolve_functional_build_policy(
            5, 322_265_625, ["ExtraTimingOpt"], 1, True, ["Explore"], True
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
    assert "localparam int unsigned CpuClkHz = 322_265_625 / CPU_CLK_DIV;" in top
    assert ".CLKOUT0_DIVIDE_F(CpuClkOutDivide)" in top
    assert ".CLK_FREQ_HZ(CpuClkHz)," in top


@pytest.mark.parametrize("divider", (1, 2, 3, 4))
def test_x3_place_gate_requires_the_mmcm_cpu_period(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, divider: int
) -> None:
    """At each divider, the gate rejects the 300 MHz reference period times the divider.

    Only the MMCM-derived CPU period passes. The build policy's clock and README
    refresh follow the divider.
    """
    monkeypatch.setenv("FROST_CPU_CLK_DIV", str(divider))
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    text = gate.read_text()
    gate.write_text(
        text.replace("CPU_PERIOD_NS=3.103", f"CPU_PERIOD_NS={3.333 * divider:.3f}")
    )
    assert not fpga_build.x3_place_gate_passes(gate)
    target_period = 3.333 * 8 * 4 * divider / 34.375
    gate.write_text(
        text.replace("CPU_PERIOD_NS=3.103", f"CPU_PERIOD_NS={target_period:.3f}")
    )
    assert fpga_build.x3_place_gate_passes(gate)
    policy = fpga_build.resolve_functional_build_policy(
        divider, 322_265_625, ["ExtraNetDelay_high"], 6, False, ["Explore"], False
    )
    assert policy.clock_freq == 322_265_625 // divider
    assert policy.update_readme is (divider == 1)


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


# A Vivado stand-in for one phys-opt sweep. It tracks the added setup
# uncertainty in force and answers every slack query with the slack at zero
# added uncertainty minus that uncertainty, so a stage sweeping overconstrained
# measures a pessimistic WNS and one sweeping at 0.000 measures the real one.
# Checkpoints remember the uncertainty they were written under, as Vivado's do.
PHYSOPT_SWEEP_MODEL = r"""
set true_wns [expr {double($::env(MODEL_TRUE_WNS))}]
set uncertainty 0.0
set checkpoint_uncertainty [dict create]
set checkpoint_state [dict create]
set write_incremental 1
set incremental_active [expr {[info exists ::env(MODEL_INCREMENTAL)] && $::env(MODEL_INCREMENTAL)}]
set initial_incremental $incremental_active
set progress_remaining 0
if {[info exists ::env(MODEL_PROGRESS)]} {set progress_remaining $::env(MODEL_PROGRESS)}
set optimizations 0
set tns_adjustment 0.0
set preservation_active 0
set placement_changed 0
set macro_bels_changed 0
set endpoint_attempts 0

# Exercise the downstream handoff independently of the native lock API, which
# has its own restoration tests. A bad release must stop before optimization.
rename source model_source
proc source {path} {
    if {[file tail $path] eq "x3_endpoint_physopt.tcl" &&
        [info exists ::env(MODEL_ENDPOINT_RESULT)]} {
        namespace eval frost_x3_endpoint_physopt {
            proc run {kind uncertainty {work_directory ""}} {
                record "endpoint_pass $kind"
                if {$kind ne "EndpointAggressive" || $::endpoint_attempts > 0} {return 0}
                incr ::endpoint_attempts
                set ::true_wns 0.010
                if {$::env(MODEL_ENDPOINT_RESULT) eq "error"} {
                    error "Endpoint disappeared during optimization"
                }
                return 1
            }
            proc candidate_is_legal {timing route} {
                return [expr {$::env(MODEL_ENDPOINT_RESULT) eq "legal"}]
            }
        }
        return
    }
    if {[file tail $path] ne "x3_local_placement.tcl" ||
        ![info exists ::env(MODEL_PRESERVATION)]} {
        return [uplevel 1 [list model_source $path]]
    }
    namespace eval frost_x3_local_placement {
        proc recover_unfixed_ports {checkpoint_path} {return 0}
        proc saved_constraints {} {
            if {$::preservation_active} {return saved}
            return {}
        }
        proc release {} {
            set ::preservation_active 0
            record release_preservation
            if {[info exists ::env(MODEL_BAD_RELEASE)]} {
                switch -- $::env(MODEL_BAD_RELEASE) {
                    timing {set ::true_wns [expr {$::true_wns - 0.1}]}
                    placement {set ::placement_changed 1}
                    macro_bel {set ::macro_bels_changed 1}
                }
            }
            return 1
        }
    }
}

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
    global tns_adjustment
    set wns [model_wns]
    if {$wns < 0.0} {
        set tns [expr {$wns * 4.0 + $tns_adjustment}]
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
    global checkpoint_state write_incremental incremental_active initial_incremental
    global true_wns progress_remaining optimizations tns_adjustment
    switch -- $cmd {
        current_design {return design}
        list_property {return {}}
        get_clocks {return clock_from_mmcm}
        get_ports {return {}}
        get_cells {return primitive}
        get_bels {
            if {$::macro_bels_changed} {return {SITE/OUTINV OTHER_SITE/OUTBUF}}
            return {SITE/OUTINV SITE/OUTBUF}
        }
        close_design {return {}}
        report_incremental_reuse {
            if {$incremental_active} {return {| Incremental Directive | RuntimeOptimized |}}
            return {}
        }
        get_param {
            if {[lindex $args 0] ne "checkpoint.writeIncrFile"} {error "Unexpected parameter $args"}
            return $write_incremental
        }
        set_param {
            if {[lindex $args 0] ne "checkpoint.writeIncrFile"} {error "Unexpected parameter $args"}
            set write_incremental [lindex $args 1]
            record "write_incremental $write_incremental"
            return {}
        }
        set_clock_uncertainty {
            set index [lsearch -exact $args -setup]
            set uncertainty [expr {double([lindex $args [expr {$index - 1}]])}]
            record "uncertainty [format %.3f $uncertainty]"
            return {}
        }
        open_checkpoint {
            set path [lindex $args end]
            set ::preservation_active [expr {[info exists ::env(MODEL_PRESERVATION)] &&
                [file tail $path] eq "input.dcp"}]
            set uncertainty 0.0
            if {[dict exists $checkpoint_uncertainty $path]} {
                set uncertainty [dict get $checkpoint_uncertainty $path]
            }
            set incremental_active $initial_incremental
            if {[dict exists $checkpoint_state $path]} {
                lassign [dict get $checkpoint_state $path] true_wns tns_adjustment incremental_active
            }
            if {[file tail $path] eq "timing_input.dcp" && [info exists ::env(MODEL_BAD_CONVERSION)]} {
                if {$::env(MODEL_BAD_CONVERSION) eq "history"} {set incremental_active 1}
                if {$::env(MODEL_BAD_CONVERSION) eq "timing"} {set true_wns [expr {$true_wns - 0.1}]}
            }
            record "open [file tail $path] at [format %.3f $uncertainty]"
            return {}
        }
        write_checkpoint {
            set path [lindex $args end]
            dict set checkpoint_uncertainty $path $uncertainty
            dict set checkpoint_state $path [list $true_wns $tns_adjustment [expr {$incremental_active && $write_incremental}]]
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
        report_utilization - report_high_fanout_nets - report_design_analysis - report_route_status {
            close [open [lindex $args end] w]
            return {}
        }
        get_timing_paths {
            if {[lsearch -exact $args -slack_lesser_than] >= 0} {return {}}
            return worst_path
        }
        get_property {
            if {[lindex $args 0] eq "SLACK"} {return [model_wns]}
            if {[lindex $args 0] eq "LOC" && $::placement_changed} {return changed_location}
            if {[lindex $args 0] eq "PRIMITIVE_LEVEL"} {
                return [expr {[info exists ::env(MODEL_MACRO_ALIAS)] ? "MACRO" : "LEAF"}]
            }
            if {[lindex $args 0] eq "BEL" && [info exists ::env(MODEL_MACRO_ALIAS)]} {
                return [expr {$::preservation_active ? "OUTINV" : "OUTBUF"}]
            }
            if {[lindex $args 0] in {NAME LOC BEL REF_NAME}} {return [lindex $args 0]}
            error "Unexpected property request $args"
        }
        phys_opt_design {
            record "phys_opt_design $args"
            if {$incremental_active && [model_wns] >= -0.546} {
                record "setup_skipped"
                return {}
            }
            if {$progress_remaining > 0} {
                incr progress_remaining -1
                incr optimizations
                if {$optimizations <= 2} {set true_wns [expr {$true_wns + 0.015}]}
                set tns_adjustment [expr {$tns_adjustment + 0.005}]
                record "setup_optimized $optimizations"
            }
            return {}
        }
        route_design {
            if {$incremental_active} {error "Router inherited the incremental timing target"}
            record "route_design $args"
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
    launch_token: str | None = None,
    *,
    incremental: bool = False,
    progress: int = 0,
    bad_conversion: str | None = None,
    preservation: bool = False,
    bad_release: str | None = None,
    macro_alias: bool = False,
    endpoint_result: str | None = None,
) -> tuple[str, list[str], Path]:
    """Sweep one phys-opt stage; return its stdout, trace and main work dir."""
    model = tmp_path / "physopt_model.tcl"
    model.write_text(PHYSOPT_SWEEP_MODEL)
    work_dir = tmp_path / f"work_{step}_Sweep"
    work_dir.mkdir()
    if launch_token is not None:
        (work_dir / "phys_opt_launch.json").write_text(
            json.dumps({"run_id": launch_token})
        )
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
        MODEL_INCREMENTAL=str(int(incremental)),
        MODEL_PROGRESS=str(progress),
        # One directive plus the appended retime pass keeps the model short.
        FROST_PHYSOPT_SWEEP_ORDER="Explore",
    )
    if setup_uncertainty is not None:
        env["FROST_PHYSOPT_SETUP_UNCERTAINTY"] = setup_uncertainty
    if bad_conversion is not None:
        env["MODEL_BAD_CONVERSION"] = bad_conversion
    if preservation:
        env["MODEL_PRESERVATION"] = "1"
    if bad_release is not None:
        env["MODEL_BAD_RELEASE"] = bad_release
    if macro_alias:
        env["MODEL_MACRO_ALIAS"] = "1"
    if endpoint_result is not None:
        env["MODEL_ENDPOINT_RESULT"] = endpoint_result
        env["FROST_PHYSOPT_SWEEP_ORDER"] = ""
    result = subprocess.run(
        ["tclsh", str(model)],
        cwd=work_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if bad_release is not None:
        assert result.returncode != 0
        assert "Removing temporary placement constraints changed" in result.stderr
    elif bad_conversion is not None:
        assert result.returncode != 0
        assert "Incremental timing target survived" in result.stderr or (
            "Removing incremental history changed" in result.stderr
        )
    else:
        assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout, trace.read_text().splitlines(), tmp_path / "work"


@pytest.mark.parametrize("endpoint_result", ("legal", "illegal", "error"))
def test_endpoint_fallback_waits_for_plateau_and_checks_legality(
    tmp_path: Path, endpoint_result: str
) -> None:
    """A promising setup result cannot bypass hold/routing acceptance."""
    stdout, trace, _ = _run_physopt_sweep_model(
        tmp_path,
        "post_second_route_physopt",
        -0.046,
        progress=2,
        endpoint_result=endpoint_result,
    )
    first_endpoint = trace.index("endpoint_pass EndpointAggressive")
    # The improving ordinary sweep finishes, then a full sweep stalls before
    # endpoint optimization is tried. No fallback runs during that first sweep.
    assert (
        sum(line.startswith("phys_opt_design") for line in trace[:first_endpoint]) == 20
    )
    if endpoint_result == "legal":
        assert "Timing met; stopping" in stdout
        assert "report phys_opt_timing.rpt at 0.000 wns 0.010" in trace
    else:
        assert "Timing met; stopping" not in stdout
        assert "report phys_opt_timing.rpt at 0.000 wns -0.016" in trace
        assert "endpoint_pass EndpointClockEnable" in trace
        assert "endpoint_pass EndpointClockIndividual" in trace
        assert "endpoint_pass EndpointPinRefine" in trace
        if endpoint_result == "error":
            assert "Rejecting failed EndpointAggressive" in stdout
        else:
            assert "Reverting non-improving" in stdout


@pytest.mark.parametrize("step", ("post_place_physopt", "route"))
@pytest.mark.parametrize("macro_alias", (False, True))
def test_downstream_releases_temporary_placement_before_optimization(
    tmp_path: Path, step: str, macro_alias: bool
) -> None:
    """Release preservation before physopt or route, allowing macro aliases."""
    stdout, trace, _ = _run_physopt_sweep_model(
        tmp_path, step, -0.193, preservation=True, macro_alias=macro_alias
    )
    assert "placement_preservation=off" in stdout
    optimization = next(
        i
        for i, line in enumerate(trace)
        if line.startswith(("phys_opt_design ", "route_design "))
    )
    assert trace.index("release_preservation") < optimization


@pytest.mark.parametrize("bad_release", ("timing", "placement", "macro_bel"))
def test_downstream_rejects_placement_release_changes(
    tmp_path: Path, bad_release: str
) -> None:
    """Reject a handoff that changes placement or timing before optimizing."""
    _, trace, _ = _run_physopt_sweep_model(
        tmp_path,
        "post_place_physopt",
        -0.193,
        preservation=True,
        bad_release=bad_release,
        macro_alias=bad_release == "macro_bel",
    )
    assert "release_preservation" in trace
    assert not any(line.startswith("phys_opt_design ") for line in trace)


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


@pytest.mark.parametrize(
    "step", ("post_place_physopt", "post_route_physopt", "post_second_route_physopt")
)
def test_physopt_continues_past_inherited_target_and_repeats_for_tns(
    tmp_path: Path, step: str
) -> None:
    """A stale negative target must not masquerade as sweep convergence."""
    stdout, trace, _ = _run_physopt_sweep_model(
        tmp_path, step, -0.046, incremental=True, progress=4
    )
    assert "setup_skipped" not in trace
    assert sum(line.startswith("setup_optimized") for line in trace) == 4
    assert sum(line.startswith("phys_opt_design") for line in trace) == 6
    assert "TNS tie-break" in stdout
    assert f"No WNS/TNS improvement during {step} sweep iteration 3" in stdout
    assert "FROST_TIMING_FLOW incremental=off" in stdout
    assert [line for line in trace if line.startswith("write_incremental")] == [
        "write_incremental 0",
        "write_incremental 1",
    ]


@pytest.mark.parametrize("step", ("quick_route", "route", "second_route"))
@pytest.mark.parametrize("incremental", (False, True))
def test_routing_resumes_with_the_normal_timing_target(
    tmp_path: Path, step: str, incremental: bool
) -> None:
    """Routing drops an inherited target and accepts ordinary checkpoints."""
    stdout, trace, _ = _run_physopt_sweep_model(
        tmp_path, step, -0.046, incremental=incremental
    )
    assert sum(line.startswith("route_design") for line in trace) == 1
    assert ("FROST_TIMING_FLOW incremental=off" in stdout) is incremental
    assert (tmp_path / f"work_{step}_Sweep/timing_input.dcp").exists() is incremental


@pytest.mark.parametrize("bad_conversion", ("history", "timing"))
def test_failed_incremental_conversion_stops_before_optimization(
    tmp_path: Path, bad_conversion: str
) -> None:
    """Reject conversion if it retains the target or changes input timing."""
    _, trace, _ = _run_physopt_sweep_model(
        tmp_path,
        "post_place_physopt",
        -0.046,
        incremental=True,
        bad_conversion=bad_conversion,
    )
    assert not any(line.startswith("phys_opt_design") for line in trace)


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
    (
        (1, None, False),
        (2, None, False),
        (1, True, True),
        (2, True, True),
        (2, False, False),
    ),
)
def test_perf_counters_are_left_out_unless_requested(
    divider: int, override: bool | None, expected: bool
) -> None:
    """Counters are in only with --perf-counters, whatever the clock divider."""
    policy = fpga_build.resolve_functional_build_policy(
        divider,
        322_265_625,
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
    assert observed == [(322_265_625, "0")]


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
    """Fake Vivado process; the first job runs longest, exposing any batch barrier."""

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
        original_extract = fpga_build.extract_timing_from_report

        def extract(path: Path) -> Any:
            try:
                return {"wns_ns": float(path.read_text()), "tns_ns": -1.0}
            except ValueError:
                return original_extract(path)

        monkeypatch.setattr(fpga_build, "extract_timing_from_report", extract)

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
        elif step == "quick_route":
            _write_probe_outputs(work_dir, "quick_route", wns)
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
    (work_dir / fpga_build.X3_NETLIST_CONFIG_NAME).write_text(
        json.dumps(
            {
                "schema": "x3_netlist_config_v3",
                "cpu_base_clock_hz": 322265625,
                "cpu_clock_div": 1,
            }
        )
    )
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
        _write_place_gate(work_dir, wns, bind=True, probe_input=True)
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
        [
            "build.py",
            "x3",
            "--start-at",
            step,
            "--stop-after",
            step,
            *options,
            *(["--num-uncertainties", "1"] if step == "place" else []),
        ],
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


def test_build_help_quotes_the_defaults_the_build_uses(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The help's job limit, post-place gate, veto level and probe count follow the code."""
    monkeypatch.setattr(fpga_build, "DEFAULT_MAX_JOBS", 7)
    monkeypatch.setattr(fpga_build, "X3_POST_PLACE_GATE_NS", Decimal("-0.321"))
    monkeypatch.setattr(fpga_build, "X3_PLACE_CONGESTION_VETO_LEVEL_DEFAULT", 4)
    monkeypatch.setattr(fpga_build, "X3_PLACE_QUICK_ROUTE_COUNT_DEFAULT", 2)
    monkeypatch.setattr(sys, "argv", ["build.py", "--help"])
    with pytest.raises(SystemExit):
        fpga_build.main()
    text = capsys.readouterr().out
    assert "processes per build (default 7)." in text
    assert "-0.321 ns" in text and "-0.200" not in text
    assert "FROST_PLACE_CONGESTION_VETO_LEVEL (default 4)" in text
    assert "(default 2) quick-routes" in text


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
    """At a displayed WNS of -0.200, the gate file's native STATUS decides."""
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
        ("CPU_PERIOD_NS=3.103", "CPU_PERIOD_NS=6.205"),
        ("CPU_PERIOD_NS=3.103", "CPU_PERIOD_NS=3.104"),
        ("CPU_PERIOD_NS=3.103", "CPU_PERIOD_NS=NaN"),
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
    """A malformed gate file fails, as does one for another clock or threshold.

    A gate taken with added uncertainty fails too, and none of these files can be
    bound to the placement.
    """
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    gate.write_text(gate.read_text().replace(old, new))
    assert not fpga_build.x3_place_gate_passes(gate)
    (tmp_path / "post_place.dcp").write_bytes(b"placement checkpoint")
    assert not fpga_build.bind_x3_place_gate(tmp_path)
    assert not (tmp_path / "post_place_gate_binding.json").exists()


@pytest.mark.parametrize(
    "divider,period,valid",
    (
        (2, "6.205", True),
        (2, "6.206", True),
        (2, "6.207", False),
        (3, "9.308", True),
        (4, "12.411", True),
        (4, "12.413", False),
    ),
)
def test_gate_checks_actual_divided_cpu_period(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    divider: int,
    period: str,
    valid: bool,
) -> None:
    """A divided clock's reported CPU period may be off by at most 1 ps."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", str(divider))
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    gate.write_text(
        gate.read_text().replace("CPU_PERIOD_NS=3.103", f"CPU_PERIOD_NS={period}")
    )
    assert fpga_build.x3_place_gate_passes(gate) is valid


@pytest.mark.parametrize("changed", ("checkpoint", "gate", "binding", "unbound"))
@pytest.mark.parametrize("wns", (-0.1, -0.199))
def test_promoted_gate_is_bound_to_exact_checkpoint_and_gate(
    tmp_path: Path,
    changed: str,
    wns: float,
) -> None:
    """Changing the checkpoint, gate file, or binding invalidates the gate.

    So does deleting the binding.
    """
    checkpoint = tmp_path / "post_place.dcp"
    checkpoint.write_bytes(b"qualified checkpoint")
    _write_place_gate(tmp_path, wns, bind=True)
    assert fpga_build.require_x3_post_place_gate(tmp_path)
    if changed == "checkpoint":
        checkpoint.write_bytes(b"different checkpoint")
    elif changed == "gate":
        with (tmp_path / "post_place_gate.txt").open("a") as stream:
            stream.write("\n")  # Same values, different bytes.
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
    """Promoting a new synth, opt, or place checkpoint deletes the old place gate."""
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


@pytest.mark.parametrize(
    ("warnings", "routed_wns", "routed_tns", "expected"),
    (
        ((False, False), (-0.1, -0.3), (-4.0, -2.0), 0),
        ((True, False), (-0.1, -0.3), (-4.0, -2.0), 1),
        ((False, True), (-0.3, -0.1), (-4.0, -2.0), 0),
        ((True, True), (-0.1, -0.3), (-4.0, -2.0), 0),
        ((True, True), (-0.1, -0.1), (-4.0, -2.0), 1),
    ),
)
def test_place_defaults_to_route_probes_and_ranks_warning_wns_tns(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    warnings: tuple[bool, bool],
    routed_wns: tuple[float, float],
    routed_tns: tuple[float, float],
    expected: int,
) -> None:
    """Warnings lower rank without preventing an all-warning slate from winning."""
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT", raising=False)
    candidates = _quick_route_candidates(tmp_path, 2)
    candidates[1].setup_uncertainty_ns = 0.5
    assert fpga_build.directive_sweep_rank_wns(candidates[1]) == -0.09
    assert fpga_build.placement_seed_wns(candidates[1]) == pytest.approx(-0.59)
    received = []

    def probes(_script: Path, runs: list[Any], _vivado: str, **_kwargs: Any) -> None:
        received.extend(runs)
        for run in runs:
            index = candidates.index(run)
            run.quick_route_returncode = 0
            run.quick_route_warning = warnings[index]
            run.quick_route_wns = routed_wns[index]
            run.quick_route_tns = routed_tns[index]

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", probes)
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[expected]
    )
    assert received == [candidates[1], candidates[0]]


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
        for run in runs:
            run.quick_route_returncode = 0
            run.quick_route_wns = run.wns

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", probes)
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[1]
    )
    assert received == [candidates[1], candidates[0]]


@pytest.mark.parametrize("sweep", (False, True))
def test_below_threshold_place_cannot_promote_or_start_physopt(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    sweep: bool,
) -> None:
    """Neither a sweep nor a single worker may qualify a failing placement."""
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
    calls = []

    def complete(command: list[str], *, cwd: Path) -> Any:
        step = command[command.index("-tclargs") + 2]
        calls.append(step)
        prefix = fpga_build._TCL_REPORT_PREFIX[step]
        wns = -0.201 if step == "place" else -0.1
        (cwd / f"{prefix}.dcp").write_text(cwd.name)
        (cwd / f"{prefix}_timing.rpt").write_text(str(wns))
        if step == "place":
            _write_place_gate(cwd, wns)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", complete)
    main_work = _sweep_input(tmp_path, "place")
    if sweep:
        result = fpga_build.run_x3_step_directive_sweep(
            tmp_path,
            "place",
            ["First", "Better"],
            "placer",
            "unused",
            max_jobs=1,
        )
    else:
        result = fpga_build.run_step(tmp_path, "x3", "place", "Better", "unused")
    assert not result[0]
    assert len(fleet.attempts) == (2 if sweep else 0)
    assert not (main_work / "post_place_gate_binding.json").exists()
    assert "Error:" in capsys.readouterr().out
    assert not fpga_build.run_step(
        tmp_path, "x3", "post_place_physopt", "Sweep", "unused"
    )[0]
    assert calls == ([] if sweep else ["place"])
    assert (
        fpga_build.capture_x3_input_lineage(main_work, "post_place_physopt.dcp") is None
    )


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


@pytest.mark.parametrize("divider", (1, 2, 3, 4))
def test_cpu_cli_controls_clock_before_software_build(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    divider: int,
) -> None:
    """Default and divided clocks reach software and RTL despite inherited env."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "2")
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    arguments = ["build.py", "x3", "--stop-after", "place"]
    if divider != 1:
        arguments += ["--cpu-clock-div", str(divider)]
    monkeypatch.setattr(sys, "argv", arguments)
    observed = []

    def compile_firmware(_root: Path, _output: Path, clock: int) -> bool:
        observed.append((clock, fpga_build.os.environ["FROST_CPU_CLK_DIV"]))
        return False

    monkeypatch.setattr(fpga_build, "compile_hello_world", compile_firmware)
    with pytest.raises(SystemExit) as stopped:
        fpga_build.main()
    assert stopped.value.code == 1
    assert observed == [(322_265_625 // divider, str(divider))]


@pytest.mark.parametrize("source", ("flag", "environment"))
def test_cpu_base_clock_selector_is_rejected_before_building(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    source: str,
) -> None:
    """Reject --cpu-base-clock-hz and FROST_CPU_BASE_CLK_HZ before building."""
    arguments = ["build.py", "x3"]
    if source == "flag":
        arguments += ["--cpu-base-clock-hz", "300000000"]
    else:
        monkeypatch.setenv("FROST_CPU_BASE_CLK_HZ", "300000000")
    monkeypatch.setattr(sys, "argv", arguments)
    monkeypatch.setattr(
        fpga_build,
        "compile_hello_world",
        lambda *_: pytest.fail("rejected clock selector launched a build"),
    )
    with pytest.raises(SystemExit) as stopped:
        fpga_build.main()
    assert stopped.value.code == 2
    message = capsys.readouterr().err
    assert (
        "--cpu-base-clock-hz" in message
        if source == "flag"
        else "no longer supported" in message
    )


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


def test_promoted_opt_checkpoint_survives_worker_cleanup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The optimized checkpoint reaches main work before the worker is removed."""
    work = _sweep_input(tmp_path, "opt")

    def complete_opt(_command: list[str], *, cwd: Path) -> Any:
        (cwd / "post_opt.dcp").write_bytes(b"new optimized checkpoint")
        _write_stage_utilization(cwd, "post_opt", 42)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", complete_opt)
    assert fpga_build.run_step(tmp_path, "x3", "opt", "Explore", "unused") == (
        True,
        -0.1,
        "post_opt",
    )
    assert not (tmp_path / "x3/work_opt_Explore").exists()
    assert (work / "post_opt.dcp").read_bytes() == b"new optimized checkpoint"


@pytest.mark.parametrize("bloat_scope", ("default", "integer", "hierarchies", "leaf"))
@pytest.mark.parametrize(
    "failure",
    (
        None,
        "reference_checkpoint",
        "verification",
        "gate_changed",
        "checkpoint_changed",
        "target_missed",
        "post_opt_changed",
        "reference_changed",
        "reference_bloat",
        "guided_bloat",
    ),
)
def test_guided_candidate_uses_fresh_reference_without_qualifying_itself(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure: str | None,
    bloat_scope: str,
) -> None:
    """Measuring and verifying local guidance never bypasses shared selection."""
    work = _sweep_input(tmp_path, "place")
    (work / "post_opt.dcp").write_bytes(b"current post-opt")
    _write_stage_utilization(work, "post_opt", 42)
    timing = work / "post_opt_timing.rpt"
    timing.write_text(timing.read_text().replace("-0.100", "0.009"))
    (work / "post_place_reference.dcp").write_bytes(b"stale reference")
    (work / "post_place.dcp").write_bytes(b"stale placement")
    _write_place_gate(work, bind=True)
    stages = []
    bloat_cells = "*u_tomasulo/u_int_rs"
    options: dict[str, Any] = {}
    if bloat_scope == "default":
        bloat_cells += " *u_tomasulo/u_mem_rs/rs_src2_value*"
    elif bloat_scope == "hierarchies":
        bloat_cells += " *u_tomasulo/u_mem_rs"
        options["cell_bloat_cells"] = bloat_cells
    elif bloat_scope == "leaf":
        bloat_cells += " *u_tomasulo/u_mem_rs/rs_src2_value*"
        options["cell_bloat_cells"] = bloat_cells
        options["cell_bloat_matches"] = (1, None)
    else:
        options["cell_bloat_cells"] = bloat_cells

    def run(command: list[str], *, cwd: Path, env: dict[str, str]) -> Any:
        assert cwd == work
        assert env["FROST_PLACE_SETUP_UNCERTAINTY"] == "0.325"
        assert env["FROST_PLACE_CELL_BLOAT"] == "MEDIUM"
        assert env["FROST_PLACE_CELL_BLOAT_CELLS"] == bloat_cells
        args = command[command.index("-tclargs") + 1 :]
        stage = args[6] if args[1] == "place" else args[1]
        stages.append(stage)
        if args[1] == "place":
            (work / command[command.index("-log") + 1]).write_text(
                "missing requested bloat\n"
                if failure == f"{stage}_bloat"
                else "".join(
                    f"Set CELL_BLOAT_FACTOR MEDIUM on "
                    f"{(2184 if stage == 'reference' else 2172) if pattern.endswith('value*') else 1} "
                    f"cell(s) matching '{pattern}'\n"
                    for pattern in bloat_cells.split()
                )
            )
        assert not (work / "post_place_gate_binding.json").exists()
        if stage == "verify_place":
            assert Path(args[3]) == work / "post_place.dcp"
            assert not (work / "post_place_gate.txt").exists()
            if failure == "verification":
                return SimpleNamespace(returncode=1)
            if failure == "checkpoint_changed":
                (work / "post_place.dcp").write_bytes(b"changed during verification")
            slack = -0.201 if failure == "target_missed" else -0.189
            _write_place_gate(work, -0.180 if failure == "gate_changed" else slack)
        else:
            assert not (work / "post_place.dcp").exists()
            if stage == "reference":
                assert Path(args[3]) == work / "post_opt.dcp"
                assert Path(args[3]).read_bytes() == b"current post-opt"
                assert args[2] == "ExtraNetDelay_high"
                assert not (work / "post_place_reference.dcp").exists()
            else:
                assert stage == "guided"
                assert Path(args[3]) == work / "post_place_reference.dcp"
                assert args[2] == "Quick"
                assert (work / "post_place_reference.dcp").read_bytes() == b"reference"
                (work / "post_place_guidance.tcldict").write_text(
                    "fresh measured guidance"
                )
                if failure == "reference_changed":
                    (work / "post_place_reference.dcp").write_bytes(
                        b"changed reference"
                    )
            slack = (
                -0.222
                if stage == "reference"
                else -0.201
                if failure == "target_missed"
                else -0.189
            )
            _write_stage_utilization(work, "post_place", 42)
            path = work / "post_place_timing.rpt"
            path.write_text(path.read_text().replace("-0.100", f"{slack:.3f}"))
            _write_place_gate(work, slack)
            if failure != "reference_checkpoint" or stage != "reference":
                (work / "post_place.dcp").write_bytes(stage.encode())
            if failure == "post_opt_changed" and stage == "reference":
                (work / "post_opt.dcp").write_bytes(b"changed mid-run")
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", run)
    success, wns, prefix = fpga_build.run_x3_guided_place_candidate(
        tmp_path, "unused", **options
    )
    assert stages == (
        ["reference"]
        if failure in {"reference_checkpoint", "post_opt_changed", "reference_bloat"}
        else ["reference", "guided"]
        if failure == "guided_bloat"
        else ["reference", "guided", "verify_place"]
    )
    assert success is (failure in {None, "target_missed"})
    if success:
        assert (wns, prefix) == (
            -0.201 if failure == "target_missed" else -0.189,
            "post_place",
        )
        assert not fpga_build.require_x3_post_place_gate(work)
        record = json.loads((work / "post_place_recipe.json").read_text())
        assert record["cell_bloat_cells"] == bloat_cells
        assert record["cell_bloat_matches"] == list(
            (1, None)
            if bloat_scope == "default"
            else options.get("cell_bloat_matches", (1,) * len(bloat_cells.split()))
        )
        assert record["post_opt_sha256"] == fpga_build.file_sha256(
            work / "post_opt.dcp"
        )
        assert record["reference_sha256"] == fpga_build.file_sha256(
            work / "post_place_reference.dcp"
        )
    else:
        assert not (work / "post_place_recipe.json").exists()
    assert not (work / "post_place_gate_binding.json").exists()
    assert list((tmp_path / "x3").iterdir()) == [work]


def test_default_place_stops_on_failing_post_opt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Never place an unclosed post-opt netlist or retain an older qualification."""
    work = _sweep_input(tmp_path, "place")
    _write_stage_utilization(work, "post_opt", 42)
    (work / "post_place.dcp").write_bytes(b"old placement")
    _write_place_gate(work, bind=True)
    monkeypatch.setattr(
        fpga_build.subprocess,
        "run",
        lambda *_a, **_kw: pytest.fail("placed unclosed post-opt"),
    )
    assert not fpga_build.run_x3_default_place(tmp_path, "unused")[0]
    assert not (work / "post_place_gate_binding.json").exists()


@pytest.mark.parametrize("stage", ("post_synth", "post_opt", "post_place"))
def test_replaced_placement_removes_default_recipe_records(
    tmp_path: Path, stage: str
) -> None:
    """New checkpoints cannot inherit a prior default placement's verification files."""
    source = tmp_path / "source"
    source.mkdir()
    main = tmp_path / "work"
    main.mkdir()
    (source / f"{stage}.dcp").write_bytes(b"replacement")
    stale_names = (
        "post_place_reference.dcp",
        "post_place_reference_gate.txt",
        "post_place_recipe.json",
        "post_place_incremental_reuse.rpt",
        "post_place_verification_timing.rpt",
        "post_place_route_status.rpt",
    )
    for name in stale_names:
        (main / name).write_text("obsolete")
    fpga_build.copy_results_to_main_work(source, main, f"{stage}.dcp", stage)
    assert not any((main / name).exists() for name in stale_names)
    assert (main / f"{stage}.dcp").read_bytes() == b"replacement"


@pytest.mark.parametrize(
    ("options", "bloat", "expected"),
    (
        ([], None, "default"),
        (["--num-uncertainties", "1"], None, "sweep"),
        (["--directives", "ExtraNetDelay_high"], None, "sweep"),
        ([], "", "sweep"),
        (["--cpu-clock-div", "2"], None, "sweep"),
    ),
)
def test_cli_selects_default_place_without_explicit_sweep_controls(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    options: list[str],
    bloat: str | None,
    expected: str,
) -> None:
    """Ordinary builds use the recipe; explicit controls and divided clocks keep sweeps."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PERF_COUNTERS", "0")
    work = _sweep_input(tmp_path, "place")
    if "--cpu-clock-div" in options:
        path = work / fpga_build.X3_NETLIST_CONFIG_NAME
        config = json.loads(path.read_text())
        config["cpu_clock_div"] = 2
        path.write_text(json.dumps(config))
    monkeypatch.delenv("FROST_PLACE_CELL_BLOAT_CELLS", raising=False)
    monkeypatch.delenv("FROST_PLACE_CELL_BLOAT", raising=False)
    if bloat is not None:
        monkeypatch.setenv("FROST_PLACE_CELL_BLOAT", bloat)
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(
        sys,
        "argv",
        ["build.py", "x3", "--start-at", "place", "--stop-after", "place", *options],
    )
    calls = []

    def finish_default(*_args: Any, **_kwargs: Any) -> tuple[bool, float, str]:
        calls.append("default")
        return True, -0.189, "post_place"

    def finish_sweep(*_args: Any, **_kwargs: Any) -> tuple[bool, float, str]:
        calls.append("sweep")
        return True, -0.1, "post_place"

    monkeypatch.setattr(fpga_build, "run_x3_default_place", finish_default)
    monkeypatch.setattr(fpga_build, "run_x3_step_directive_sweep", finish_sweep)
    monkeypatch.setitem(
        sys.modules, "extract_timing_and_util_summary", timing_util_summary
    )
    monkeypatch.setattr(
        timing_util_summary, "collect_all_board_utilization", lambda *_a, **_kw: {}
    )
    fpga_build.main()
    assert calls == [expected]


def test_missing_placement_checkpoint_cannot_defeat_complete_passing_seed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A gate file without its output checkpoint is not a usable sweep result."""
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    candidates = _quick_route_candidates(tmp_path, 2)
    (candidates[1].work_dir / "post_place.dcp").unlink()
    assert (
        fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
        is candidates[0]
    )
    (candidates[0].work_dir / "post_place.dcp").unlink()
    assert fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused") is None


@pytest.mark.parametrize("extras", [False, True])
def test_unused_placement_switches_cannot_add_or_modify_candidates(
    extras: bool,
) -> None:
    """The unused flush-guidance and pin-swap switches affect no candidate.

    They add none, are dropped from each candidate's environment, and leave
    manual bloat alone.
    """
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


def test_unused_placement_switches_do_not_launch_an_extra_worker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """With the unused switches set, only the requested seed and off-grid seed run.

    Neither worker inherits the switches.
    """
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


def test_new_placement_gate_cannot_requalify_the_previous_physopt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A new placement's gate cannot requalify a phys-opt checkpoint of the old one."""
    work = tmp_path / "x3/work"
    work.mkdir(parents=True)
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "2")
    (work / "post_place.dcp").write_bytes(b"161 MHz placement")
    _write_place_gate(work)
    gate = work / "post_place_gate.txt"
    gate.write_text(
        gate.read_text().replace("CPU_PERIOD_NS=3.103", "CPU_PERIOD_NS=6.205")
    )
    assert fpga_build.bind_x3_place_gate(work)
    child = _write_qualified_descendant(work, "post_place_physopt")
    report = work / "post_place_physopt_timing.rpt"
    report.write_text("preserved 161 MHz report")
    old_child, old_report = child.read_bytes(), report.read_bytes()
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    (work / "post_place.dcp").write_bytes(b"new 322 MHz placement")
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
    """Changing any checkpoint, lineage record, or place gate in the chain breaks it.

    The disqualified checkpoint is kept.
    """
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
@pytest.mark.parametrize("custom_directory", (False, True))
def test_completed_final_producer_binds_chain_and_bitstream_checks_actual_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, stage: str, custom_directory: bool
) -> None:
    """A stage that writes final.dcp records its lineage.

    The bitstream step then refuses a final.dcp that has changed since.
    """
    work = _sweep_input(tmp_path, stage)
    script_dir = tmp_path / "scripts" if custom_directory else tmp_path
    options = {"build_dir": work.parent} if custom_directory else {}
    calls = []

    def complete(command: list[str], *, cwd: Path) -> Any:
        assert command[command.index("-source") + 1] == str(
            script_dir / "build_step.tcl"
        )
        assert cwd == work or cwd.parent == work.parent
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
    assert fpga_build.run_step(
        script_dir, "x3", stage, "Explore", "unused", **options
    ) == (
        True,
        0.05,
        "final",
    )
    assert fpga_build.capture_x3_input_lineage(work, "final.dcp") is not None
    assert fpga_build.generate_bitstream(script_dir, "x3", "unused", **options)
    assert calls == [stage, "bitstream"]
    (work / "final.dcp").write_bytes(b"different final checkpoint")
    assert not fpga_build.generate_bitstream(script_dir, "x3", "unused", **options)
    assert calls == [stage, "bitstream"]


def test_bitstream_resume_cli_preserves_lineage_checks(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bitstream-only recovery uses the qualified final and rejects a stale one."""
    stage = "post_second_route_physopt"
    work = _sweep_input(tmp_path, stage)
    final = _write_qualified_descendant(work, stage, final=True)
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(sys, "argv", ["build.py", "x3", "--start-at", "bitstream"])
    calls = []

    def bitgen(command: list[str], *, cwd: Path) -> Any:
        assert cwd == work
        assert command[command.index("-tclargs") + 2] == "bitstream"
        assert command[command.index("-tclargs") + 4] == str(final)
        calls.append(command)
        (cwd / "x3_frost.bit").write_bytes(b"bitstream fixture")
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(fpga_build.subprocess, "run", bitgen)
    fpga_build.main()
    assert len(calls) == 1
    final.write_bytes(b"changed checkpoint")
    with pytest.raises(SystemExit) as error:
        fpga_build.main()
    assert error.value.code == 1
    assert len(calls) == 1


def test_intermediate_physopt_publication_cannot_inherit_prior_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed phys-opt run leaves its partial output without lineage.

    The final.dcp built on the previous output is disqualified too.
    """
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


# Trimmed but genuine ``report_design_analysis -congestion`` output in
# tests/fixtures: two placements that reported windows (X3 Long/Short level 5,
# genesys2 Global level 6) and one that reported none. Only the Host/Command
# header lines were rewritten; the tables are as Vivado wrote them. A veto that
# silently parses nothing is invisible, so the row regex is checked against
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


@pytest.mark.parametrize("wns", (-0.3, -0.2, -0.1))
def test_completed_placement_still_reports_a_timing_rejection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    wns: float,
) -> None:
    """Vivado's zero exit code must not label a timing-rejected placement OK."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    candidates = _quick_route_candidates(tmp_path, 2)
    passing, rejected = candidates
    rejected.wns = wns
    _write_place_gate(rejected.work_dir, wns)
    if wns == -0.1:
        (rejected.work_dir / "post_place_gate.txt").unlink()
    selected = fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
    assert selected is passing
    assert passing.timing_gate_passed is True
    assert rejected.timing_gate_passed is False
    fpga_build.print_x3_directive_sweep_matrix(candidates, selected, "Placement")
    row = next(
        line for line in capsys.readouterr().out.splitlines() if rejected.label in line
    )
    assert "TIMEVETO" in row


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


@pytest.mark.parametrize(
    ("period", "valid"),
    (
        ("3.103", True),
        # A clock object carrying more precision than the report prints.
        ("3.10272", True),
        ("3.1027", True),
        # A different printed period is rejected.
        ("3.104", False),
        ("3.102", False),
    ),
)
def test_full_rate_gate_period_allows_only_display_rounding(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, period: str, valid: bool
) -> None:
    """A 322 MHz build cannot fail on digits Vivado never printed."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    _write_place_gate(tmp_path)
    gate = tmp_path / "post_place_gate.txt"
    gate.write_text(
        gate.read_text().replace("CPU_PERIOD_NS=3.103", f"CPU_PERIOD_NS={period}")
    )
    assert fpga_build.x3_place_gate_passes(gate) is valid


@pytest.mark.parametrize(
    ("native", "reported", "valid"),
    (
        (-0.1, -0.1, True),
        # The native SLACK property and the timing summary round the same
        # path differently in the last printed digit.
        (-0.1004, -0.1, True),
        (-0.0996, -0.1, True),
        (-0.101, -0.1, False),
        (-0.1, -0.15, False),
    ),
)
def test_gate_and_timing_report_agree_within_display_rounding(
    tmp_path: Path, native: float, reported: float, valid: bool
) -> None:
    """Gate and timing-report WNS may differ by display rounding, and no more."""
    _write_place_gate(tmp_path, native)
    gate = tmp_path / "post_place_gate.txt"
    assert fpga_build.x3_place_gate_passes(gate, reported) is valid
    assert fpga_build.x3_place_gate_passes(gate) is True


def test_missing_lineage_sidecar_names_the_file_and_the_recovery(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A checkpoint copied in without its sidecar fails readably, not by errno."""
    work = _sweep_input(tmp_path, "post_route_physopt")
    sidecar = work / "post_route.lineage.json"
    assert fpga_build.capture_x3_input_lineage(work, "post_route.dcp") is not None
    sidecar.unlink()
    assert fpga_build.capture_x3_input_lineage(work, "post_route.dcp") is None
    message = capsys.readouterr().out
    assert "post_route.dcp has no post_route.lineage.json" in message
    assert "Rerun from post_place_physopt" in message
    assert "*.lineage.json" in message
    # The placement's own binding sidecar reports itself by name too.
    (work / "post_place_gate_binding.json").unlink()
    assert not fpga_build.require_x3_post_place_gate(work)
    assert "post_place_gate_binding.json is missing" in capsys.readouterr().out


@pytest.mark.parametrize("perf_counters", ("0", "1"))
@pytest.mark.parametrize("divider", ("1", "2"))
def test_post_synth_promotion_stamps_the_netlist_perf_counters(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    perf_counters: str,
    divider: str,
) -> None:
    """Synthesis options are recorded once with their checkpoint."""
    monkeypatch.setenv("FROST_PERF_COUNTERS", perf_counters)
    monkeypatch.setenv("FROST_CPU_CLK_DIV", divider)
    source, dest = tmp_path / "source", tmp_path / "dest"
    source.mkdir()
    dest.mkdir()
    (source / "post_synth.dcp").write_bytes(b"synthesized netlist")
    fpga_build.copy_results_to_main_work(source, dest, "post_synth.dcp", "post_synth")
    stamp = dest / fpga_build.X3_NETLIST_CONFIG_NAME
    assert json.loads(stamp.read_text()) == {
        "schema": "x3_netlist_config_v3",
        "perf_counters": int(perf_counters),
        "cpu_base_clock_hz": 322265625,
        "cpu_clock_div": int(divider),
    }
    # Later stages inherit the netlist, so they must not restamp it: a resumed
    # run's environment says nothing about the checkpoint it was handed.
    monkeypatch.setenv("FROST_PERF_COUNTERS", "1" if perf_counters == "0" else "0")
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "123")
    (source / "post_opt.dcp").write_bytes(b"optimized netlist")
    fpga_build.copy_results_to_main_work(source, dest, "post_opt.dcp", "post_opt")
    assert json.loads(stamp.read_text())["perf_counters"] == int(perf_counters)
    assert json.loads(stamp.read_text())["cpu_base_clock_hz"] == 322265625
    assert json.loads(stamp.read_text())["cpu_clock_div"] == int(divider)


def test_failed_synthesis_leaves_the_previous_netlist_stamp(tmp_path: Path) -> None:
    """Without a promoted checkpoint, no netlist config is written."""
    source, dest = tmp_path / "source", tmp_path / "dest"
    source.mkdir()
    dest.mkdir()
    fpga_build.copy_results_to_main_work(source, dest, "post_synth.dcp", "post_synth")
    assert not (dest / fpga_build.X3_NETLIST_CONFIG_NAME).exists()


def _live_physopt_fixture(tmp_path: Path) -> tuple[Path, Path]:
    """Model a running producer with a complete sweep and no stage sidecar."""
    source = _sweep_input(tmp_path, "post_place_physopt")
    worker = source.parent / "work_post_place_physopt_Sweep"
    worker.mkdir()
    consumed = fpga_build.capture_x3_input_lineage(source, "post_place.dcp")
    token = "a" * 32
    (worker / "phys_opt_launch.json").write_text(
        json.dumps(
            {
                "schema": "x3_physopt_launch_v1",
                "run_id": token,
                "parent": consumed.parent,
                "placement": consumed.placement,
            }
        )
    )
    with zipfile.ZipFile(worker / "phys_opt.dcp", "w") as archive:
        archive.writestr("netlist", "first completed sweep")
    (worker / "phys_opt_iteration.json").write_text(
        json.dumps(
            {
                "schema": "x3_physopt_iteration_v1",
                "run_id": token,
                "sweep": 1,
                "checkpoint_sha256": fpga_build.file_sha256(worker / "phys_opt.dcp"),
            }
        )
    )
    _write_stage_utilization(worker, "phys_opt", 42)
    stamp = source / fpga_build.X3_NETLIST_CONFIG_NAME
    config = json.loads(stamp.read_text())
    config["perf_counters"] = 0
    stamp.write_text(json.dumps(config))
    return source, worker


def test_physopt_tcl_publishes_completed_sweep_identity(tmp_path: Path) -> None:
    """The real Tcl producer binds its launch token to the exact finished DCP."""
    token = "b" * 32
    _run_physopt_sweep_model(tmp_path, "post_place_physopt", 0.012, launch_token=token)
    worker = tmp_path / "work_post_place_physopt_Sweep"
    record = json.loads((worker / "phys_opt_iteration.json").read_text())
    assert record == {
        "schema": "x3_physopt_iteration_v1",
        "run_id": token,
        "sweep": 1,
        "checkpoint_sha256": fpga_build.file_sha256(worker / "phys_opt.dcp"),
    }
    assert not (worker / "phys_opt_iteration.json.tmp").exists()
    assert not (tmp_path / "work/post_place_physopt.dcp.tmp").exists()


def test_live_physopt_snapshot_survives_source_replacement(tmp_path: Path) -> None:
    """A completed sweep can be snapshotted while its stage still runs.

    The snapshot leaves the source untouched, and later source changes do not
    affect it.
    """
    source, worker = _live_physopt_fixture(tmp_path)
    before = {p: p.read_bytes() for p in source.parent.rglob("*") if p.is_file()}
    fork = tmp_path / "early_route"
    assert fpga_build.snapshot_x3_physopt(source, fork)
    assert all(p.read_bytes() == contents for p, contents in before.items())
    assert not (source / "post_place_physopt.lineage.json").exists()
    consumed = fpga_build.capture_x3_input_lineage(
        fork / "work", "post_place_physopt.dcp"
    )
    assert consumed is not None
    assert json.loads((fork / "work/physopt_snapshot.json").read_text())["sweep"] == 1
    assert (fork / "work/netlist_config.json").read_bytes() == (
        source / "netlist_config.json"
    ).read_bytes()
    (worker / "phys_opt.dcp").write_bytes(b"next sweep being written")
    (source / "post_place.dcp").write_bytes(b"a later placement")
    assert (
        fpga_build.capture_x3_input_lineage(fork / "work", "post_place_physopt.dcp")
        == consumed
    )


@pytest.mark.parametrize(
    "change",
    (
        "missing_launch",
        "missing_iteration",
        "wrong_token",
        "wrong_parent",
        "wrong_clock",
        "changed_checkpoint",
        "broken_zip",
        "existing_destination",
    ),
)
def test_physopt_snapshot_rejects_unqualified_or_incomplete_input(
    tmp_path: Path,
    change: str,
) -> None:
    """A snapshot needs a completed sweep of the current placement and clock.

    Without one, or with a destination that exists, it fails and creates
    nothing.
    """
    source, worker = _live_physopt_fixture(tmp_path)
    fork = tmp_path / "early_route"
    if change == "missing_launch":
        (worker / "phys_opt_launch.json").unlink()
    elif change == "missing_iteration":
        (worker / "phys_opt_iteration.json").unlink()
    elif change == "wrong_token":
        path = worker / "phys_opt_iteration.json"
        path.write_text(path.read_text().replace("a" * 32, "b" * 32))
    elif change == "wrong_parent":
        (source / "post_place.dcp").write_bytes(b"new placement")
        _write_place_gate(source, bind=True)
    elif change == "wrong_clock":
        gate = source / "post_place_gate.txt"
        gate.write_text(gate.read_text().replace("3.103", "6.205"))
    elif change in ("changed_checkpoint", "broken_zip"):
        (worker / "phys_opt.dcp").write_bytes(b"incomplete ZIP data")
        if change == "broken_zip":
            path = worker / "phys_opt_iteration.json"
            record = json.loads(path.read_text())
            record["checkpoint_sha256"] = fpga_build.file_sha256(
                worker / "phys_opt.dcp"
            )
            path.write_text(json.dumps(record))
    else:
        fork.mkdir()
        (fork / "keep.txt").write_text("existing user output")
    assert not fpga_build.snapshot_x3_physopt(source, fork)
    if change == "existing_destination":
        assert (fork / "keep.txt").read_text() == "existing user output"
    else:
        assert not fork.exists()
    assert not (source / "post_place_physopt.lineage.json").exists()


@pytest.mark.parametrize("change", ("checkpoint", "iteration", "placement"))
def test_physopt_snapshot_detects_publication_during_copy(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    change: str,
) -> None:
    """A sweep, iteration record, or placement published mid-copy fails the snapshot."""
    source, worker = _live_physopt_fixture(tmp_path)
    fork = tmp_path / "early_route"
    original = fpga_build.shutil.copy2

    def copy_then_publish(src: Path, dst: Path) -> Any:
        result = original(src, dst)
        if src == worker / "phys_opt.dcp":
            if change == "checkpoint":
                src.write_bytes(b"new sweep")
            elif change == "iteration":
                path = worker / "phys_opt_iteration.json"
                path.write_text(path.read_text() + "\n")
            else:
                (source / "post_place.dcp").write_bytes(b"new placement")
                _write_place_gate(source, bind=True)
        return result

    monkeypatch.setattr(fpga_build.shutil, "copy2", copy_then_publish)
    assert not fpga_build.snapshot_x3_physopt(source, fork)
    assert not fork.exists()


def test_completed_physopt_stage_can_be_snapshotted_without_launch_manifest(
    tmp_path: Path,
) -> None:
    """A completed stage with valid lineage can be snapshotted with no launch record."""
    source, worker = _live_physopt_fixture(tmp_path)
    consumed = fpga_build.capture_x3_input_lineage(source, "post_place.dcp")
    (source / "post_place_physopt.dcp").write_bytes(
        (worker / "phys_opt.dcp").read_bytes()
    )
    assert fpga_build.bind_x3_output_lineage(
        source,
        "post_place_physopt",
        "post_place_physopt.dcp",
        worker / "phys_opt.dcp",
        consumed,
    )
    (worker / "phys_opt_launch.json").unlink()
    fork = tmp_path / "early_route"
    assert fpga_build.snapshot_x3_physopt(source, fork)
    assert (
        fpga_build.capture_x3_input_lineage(fork / "work", "post_place_physopt.dcp")
        is not None
    )


def test_route_sweep_uses_only_custom_build_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A route sweep given build_dir runs its workers and writes its outputs there."""
    source, _worker = _live_physopt_fixture(tmp_path)
    fork = tmp_path / "early_route"
    assert fpga_build.snapshot_x3_physopt(source, fork)
    fleet = _VivadoFleet(monkeypatch, 2)
    result = fpga_build.run_x3_step_directive_sweep(
        tmp_path,
        "route",
        ["Explore", "Default"],
        "router",
        "unused",
        build_dir=fork,
        max_jobs=2,
        keep_temps=True,
    )
    assert result[0]
    assert all(path.parent == fork for path in fleet.attempts)
    assert (
        fpga_build.capture_x3_input_lineage(fork / "work", "post_route.dcp") is not None
    )
    assert not (source / "post_route.dcp").exists()


def test_snapshot_cli_isolates_route_bitstream_and_readme(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """--snapshot-physopt-from with --build-dir routes and writes the bitstream there.

    It builds no software and leaves the README alone.
    """
    source, _worker = _live_physopt_fixture(tmp_path)
    fork = tmp_path / "early_route"
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "build.py",
            "x3",
            "--start-at",
            "route",
            "--stop-after",
            "route",
            "--snapshot-physopt-from",
            str(source),
            "--build-dir",
            str(fork),
        ],
    )
    calls = []

    def route(*_args: Any, **kwargs: Any) -> tuple[bool, float, str]:
        assert kwargs["build_dir"] == fork
        assert (
            fpga_build.capture_x3_input_lineage(fork / "work", "post_place_physopt.dcp")
            is not None
        )
        calls.append("route")
        return True, 0.05, "final"

    def bitstream(*_args: Any, **kwargs: Any) -> bool:
        assert kwargs["build_dir"] == fork
        calls.append("bitstream")
        return True

    monkeypatch.setattr(fpga_build, "run_x3_step_directive_sweep", route)
    monkeypatch.setattr(fpga_build, "generate_bitstream", bitstream)
    monkeypatch.setattr(
        fpga_build,
        "compile_hello_world",
        lambda *_: pytest.fail("unexpected software rebuild"),
    )
    monkeypatch.setitem(
        sys.modules, "extract_timing_and_util_summary", timing_util_summary
    )
    monkeypatch.setattr(
        timing_util_summary,
        "update_readme_utilization",
        lambda *_: pytest.fail("reference README changed"),
    )
    fpga_build.main()
    assert calls == ["route", "bitstream"]


def test_physopt_launch_allows_fork_only_after_this_runs_completed_sweep(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Each phys-opt launch writes a new launch record before Vivado starts.

    A snapshot then needs a sweep that this run completed.
    """
    source, worker = _live_physopt_fixture(tmp_path)
    consumed = fpga_build.capture_x3_input_lineage(source, "post_place.dcp")
    fork = tmp_path / "early_route"

    def running(_command: list[str], *, cwd: Path) -> Any:
        assert cwd == worker
        launch = json.loads((cwd / "phys_opt_launch.json").read_text())
        assert launch["run_id"] != "a" * 32
        assert launch["parent"] == consumed.parent
        assert launch["placement"] == consumed.placement
        assert not (cwd / "phys_opt_iteration.json").exists()
        assert not fpga_build.snapshot_x3_physopt(source, fork)
        (cwd / "phys_opt_iteration.json").write_text(
            json.dumps(
                {
                    "schema": "x3_physopt_iteration_v1",
                    "run_id": launch["run_id"],
                    "sweep": 1,
                    "checkpoint_sha256": fpga_build.file_sha256(cwd / "phys_opt.dcp"),
                }
            )
        )
        assert fpga_build.snapshot_x3_physopt(source, fork)
        # A failure after this sweep leaves the fork valid, and the main
        # directory's unfinished stage without lineage.
        return SimpleNamespace(returncode=1)

    monkeypatch.setattr(fpga_build.subprocess, "run", running)
    assert not fpga_build.run_step(
        tmp_path, "x3", "post_place_physopt", "Sweep", "unused"
    )[0]
    assert not (source / "post_place_physopt.lineage.json").exists()
    assert (
        fpga_build.capture_x3_input_lineage(fork / "work", "post_place_physopt.dcp")
        is not None
    )


def test_single_core_performance_flag_is_not_an_option(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """--single-core-performance is not an option."""
    monkeypatch.setattr(
        sys,
        "argv",
        ["build.py", "x3", "--stop-after", "synth", "--single-core-performance"],
    )
    with pytest.raises(SystemExit) as stopped:
        fpga_build.main()
    assert stopped.value.code == 2
    assert (
        "unrecognized arguments: --single-core-performance" in capsys.readouterr().err
    )


@pytest.mark.parametrize(
    "overrides, publish",
    [
        ({}, True),
        ({"schema": "x3_netlist_config_v2", "single_core_performance": 0}, False),
        ({"schema": "x3_netlist_config_v2", "single_core_performance": 1}, False),
        ({"cpu_base_clock_hz": 300000000}, False),
        ({"cpu_clock_div": 2}, False),
        ({"schema": "x3_netlist_config_v1"}, False),
        (None, False),
    ],
)
def test_resumed_build_uses_recorded_configuration_for_readme(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    overrides: dict | None,
    publish: bool,
) -> None:
    """The README refresh uses the netlist config recorded at synthesis.

    An older schema skips the refresh; a missing config or another clock stops
    the build.
    """
    work = _sweep_input(tmp_path, "place")
    if overrides is not None:
        config = {
            "schema": "x3_netlist_config_v3",
            "cpu_base_clock_hz": 322265625,
            "cpu_clock_div": 1,
            **overrides,
        }
        (work / fpga_build.X3_NETLIST_CONFIG_NAME).write_text(json.dumps(config))
    else:
        (work / fpga_build.X3_NETLIST_CONFIG_NAME).unlink()
    monkeypatch.setattr(fpga_build, "__file__", str(tmp_path / "build.py"))
    monkeypatch.setattr(
        sys,
        "argv",
        ["build.py", "x3", "--start-at", "place", "--stop-after", "place"],
    )
    monkeypatch.setattr(
        fpga_build,
        "run_x3_step_directive_sweep",
        lambda *_args, **_kwargs: (True, -1.0, "post_place"),
    )
    monkeypatch.setattr(
        fpga_build,
        "run_x3_default_place",
        lambda *_args, **_kwargs: (True, -1.0, "post_place"),
    )
    monkeypatch.setitem(
        sys.modules, "extract_timing_and_util_summary", timing_util_summary
    )
    calls = []
    monkeypatch.setattr(
        timing_util_summary,
        "collect_all_board_utilization",
        lambda *_args, **_kwargs: {"x3": {}},
    )
    monkeypatch.setattr(
        timing_util_summary,
        "update_readme_utilization",
        lambda *_args: calls.append("publish"),
    )
    incompatible_clock = overrides is None or any(
        key in overrides for key in ("cpu_base_clock_hz", "cpu_clock_div")
    )
    if incompatible_clock:
        with pytest.raises(SystemExit) as stopped:
            fpga_build.main()
        assert stopped.value.code == 1
    else:
        fpga_build.main()
    assert bool(calls) is publish


@pytest.mark.parametrize("evidence", ("congested", "missing", "malformed"))
def test_no_placement_falls_back_past_congestion_requirement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, evidence: str
) -> None:
    """Even the only timing-passing seed must have acceptable congestion evidence."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    candidates = _quick_route_candidates(tmp_path, 1)
    report = candidates[0].work_dir / "post_place_congestion.rpt"
    if evidence == "congested":
        report.write_text(
            (CONGESTION_FIXTURES / "x3_post_place_congestion.rpt").read_text()
        )
    elif evidence == "missing":
        report.unlink()
    else:
        report.write_text("not a Vivado congestion report\n")
    monkeypatch.setattr(
        fpga_build,
        "run_x3_place_quick_route_probes",
        lambda *_a, **_kw: pytest.fail("unqualified placement reached routing"),
    )
    assert fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused") is None
    assert candidates[0].congestion_vetoed
    assert not fpga_build.bind_x3_place_gate(candidates[0].work_dir)
    assert not fpga_build.require_x3_post_place_gate(candidates[0].work_dir)


@pytest.mark.parametrize("wns", (-0.201, -0.200, -0.199))
def test_full_rate_qualification_requires_strict_timing_margin(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, wns: float
) -> None:
    """A rounded boundary or failing slack cannot receive a full-rate binding."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    (tmp_path / "post_place.dcp").write_bytes(b"placement")
    _write_place_gate(tmp_path, wns)
    assert fpga_build.bind_x3_place_gate(tmp_path) is (wns > -0.2)
    assert fpga_build.require_x3_post_place_gate(tmp_path) is (wns > -0.2)


@pytest.mark.parametrize("change", ("bytes", "missing", "legacy_binding"))
def test_resume_requires_bound_congestion_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, change: str
) -> None:
    """Resume must reject changed congestion reports and timing-only bindings."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    candidate = _quick_route_candidates(tmp_path, 1)[0]
    work = candidate.work_dir
    _write_place_gate(work, candidate.wns, bind=True)
    assert fpga_build.require_x3_post_place_gate(work)
    report = work / "post_place_congestion.rpt"
    if change == "bytes":
        report.write_text(report.read_text() + "\n")
    elif change == "missing":
        report.unlink()
    else:
        binding = work / "post_place_gate_binding.json"
        record = json.loads(binding.read_text())
        record["schema"] = "x3_post_place_gate_binding_v1"
        record.pop("congestion_sha256")
        record.pop("congestion_veto_level")
        binding.write_text(json.dumps(record))
    assert not fpga_build.require_x3_post_place_gate(work)


@pytest.mark.parametrize("result", ("pass", "error", "no_timing", "congestion"))
def test_single_survivor_must_complete_the_default_route_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, result: str
) -> None:
    """A lone candidate gets the same probe requirement as a larger slate."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT", raising=False)
    candidates = _quick_route_candidates(tmp_path, 1)
    received = []

    def probe(_script: Path, runs: list[Any], _vivado: str, **_kw: Any) -> None:
        received.extend(runs)
        runs[0].quick_route_returncode = 1 if result == "error" else 0
        runs[0].quick_route_wns = None if result == "no_timing" else -0.15
        runs[0].quick_route_warning = result == "congestion"

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", probe)
    winner = fpga_build.select_x3_place_best_run(tmp_path, candidates, "unused")
    assert received == candidates
    assert winner is (candidates[0] if result in {"pass", "congestion"} else None)


@pytest.mark.parametrize(
    ("guided_congestion", "guided_route", "probe_warnings", "expected"),
    (
        (5, -0.05, (False, False), "Ordinary"),
        (0, -0.3, (False, False), "Ordinary"),
        (0, -0.05, (False, False), "LocalGuidance"),
        (0, -0.05, (True, False), "Ordinary"),
        (0, -0.05, (True, True), "LocalGuidance"),
        (0, -0.3, (True, True), "Ordinary"),
    ),
)
def test_default_guidance_competes_under_the_shared_congestion_and_route_rules(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    guided_congestion: int,
    guided_route: float,
    probe_warnings: tuple[bool, bool],
    expected: str,
) -> None:
    """The normal entry point cannot privilege the guided candidate's placed WNS."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT", raising=False)
    _VivadoFleet(monkeypatch, 2)
    work = _sweep_input(tmp_path, "place")

    def guidance(*_args: Any, **_kwargs: Any) -> tuple[bool, float, str]:
        (work / "post_place.dcp").write_bytes(b"guided placement")
        (work / "post_place_timing.rpt").write_text("-0.05")
        (work / "post_place_vivado.log").write_text("guided Vivado log")
        (work / "post_place_recipe.json").write_text(
            json.dumps(
                {"post_opt_sha256": fpga_build.file_sha256(work / "post_opt.dcp")}
            )
        )
        (work / "post_place_reference.dcp").write_bytes(b"fresh reference")
        _write_place_gate(work, -0.05)
        if guided_congestion:
            (work / "post_place_congestion.rpt").write_text(
                (CONGESTION_FIXTURES / "x3_post_place_congestion.rpt").read_text()
            )
        return True, -0.05, "post_place"

    monkeypatch.setattr(fpga_build, "run_x3_guided_place_candidate", guidance)
    monkeypatch.setattr(
        fpga_build,
        "make_x3_place_sweep_candidates",
        lambda *_a, **_kw: [fpga_build.DirectiveSweepCandidate("Ordinary", 0.3)],
    )
    probed = []

    def probe(_script: Path, runs: list[Any], _vivado: str, *, max_jobs: int) -> None:
        assert max_jobs == 2
        for run in runs:
            probed.append(run.label)
            run.quick_route_returncode = 0
            run.quick_route_wns = guided_route if run.label == "LocalGuidance" else -0.1
            run.quick_route_warning = probe_warnings[
                0 if run.label == "LocalGuidance" else 1
            ]
            _write_probe_outputs(run.work_dir, "quick_route", run.quick_route_wns)
            if run.quick_route_warning:
                with (run.work_dir / "quick_route_vivado.log").open("a") as stream:
                    stream.write(fpga_build._ROUTER_CONGESTION_WARNING + "\n")

    monkeypatch.setattr(fpga_build, "run_x3_place_quick_route_probes", probe)
    success, wns, prefix = fpga_build.run_x3_default_place(
        tmp_path, "unused", max_jobs=2, keep_temps=True
    )
    assert success and prefix == "post_place"
    assert fpga_build.require_x3_post_place_gate(work)
    selection = json.loads((work / "post_place_selection.json").read_text())
    assert selection["selected"].startswith(expected)
    assert all(run["timing_gate_passed"] is True for run in selection["candidates"])
    assert ("LocalGuidance" in probed) is (guided_congestion < 5)
    assert (work / "post_place_recipe.json").exists() is (expected == "LocalGuidance")
    assert wns == (-0.05 if expected == "LocalGuidance" else -0.1)


@pytest.mark.parametrize(
    "damage",
    (
        None,
        "missing_log",
        "empty_log",
        "warning",
        "missing_status",
        "incomplete",
        "conflict",
        "ambiguous",
        "missing_timing",
        "checkpoint",
        "stale",
    ),
)
def test_route_probe_requires_complete_fresh_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, damage: str | None
) -> None:
    """Successful process exit cannot substitute for actual complete routing."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    fleet = _VivadoFleet(monkeypatch, 1)
    candidate = _quick_route_candidates(tmp_path, 1)[0]
    work = candidate.work_dir
    _write_probe_outputs(work, "quick_route")

    def probe(command: list[str], **kwargs: Any) -> Any:
        for name in ("timing.rpt", "status.rpt", "vivado.log"):
            assert not (work / f"quick_route_{name}").exists()
        process = fleet.popen(command, **kwargs)
        log = work / "quick_route_vivado.log"
        status = work / "quick_route_status.rpt"
        timing = work / "quick_route_timing.rpt"
        if damage in {"missing_log", "stale"}:
            log.unlink()
        elif damage == "empty_log":
            log.write_text("")
        elif damage == "warning":
            log.write_text(fpga_build._ROUTER_CONGESTION_WARNING)
        elif damage == "missing_status":
            status.unlink()
        elif damage == "incomplete":
            status.write_text(
                status.read_text().replace(
                    "# of fully routed nets............. :      274811",
                    "# of fully routed nets............. :      274810",
                )
            )
        elif damage == "conflict":
            status.write_text(
                status.read_text().replace(
                    "# of nets with routing errors.......... :           0",
                    "# of nets with routing errors.......... :           1",
                )
            )
        elif damage == "ambiguous":
            status.write_text(status.read_text() * 2)
        elif damage == "missing_timing":
            timing.unlink()
        elif damage == "checkpoint":
            (work / "post_place.dcp").write_bytes(b"changed during probe")
        return process

    monkeypatch.setattr(fpga_build.subprocess, "Popen", probe)
    fpga_build.run_x3_place_quick_route_probes(tmp_path, [candidate], "unused")
    accepted = damage in {None, "warning"}
    assert candidate.quick_route_returncode == (0 if accepted else -1)
    assert (candidate.quick_route_wns is not None) is accepted
    assert candidate.quick_route_warning is (damage == "warning")
    # Even a completed probe is only an input to selection, not a winner.
    assert not fpga_build.require_x3_post_place_gate(work)


@pytest.mark.parametrize(
    ("recorded_warning", "log_warning", "accepted"),
    (
        (False, False, True),
        (True, True, True),
        (False, True, False),
        (True, False, False),
        (None, False, False),
        (0, False, False),
    ),
)
def test_selected_probe_warning_must_match_its_log(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    recorded_warning: bool | int | None,
    log_warning: bool,
    accepted: bool,
) -> None:
    """A warning is allowed on resume, but the selected evidence must record it."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    (tmp_path / "post_place.dcp").write_bytes(b"selected placement")
    _write_place_gate(tmp_path)
    selection_path = tmp_path / "post_place_selection.json"
    selection = json.loads(selection_path.read_text())
    selection["candidates"][0]["quick_route_congestion_warning"] = recorded_warning
    selection_path.write_text(json.dumps(selection))
    if log_warning:
        with (tmp_path / "post_place_quick_route_vivado.log").open("a") as stream:
            stream.write(fpga_build._ROUTER_CONGESTION_WARNING + "\n")
    assert fpga_build.bind_x3_place_gate(tmp_path) is accepted
    assert fpga_build.require_x3_post_place_gate(tmp_path) is accepted


@pytest.mark.parametrize(
    "name",
    (
        "post_place_selection.json",
        "post_place_quick_route_timing.rpt",
        "post_place_quick_route_status.rpt",
        "post_place_quick_route_vivado.log",
    ),
)
@pytest.mark.parametrize("missing", (False, True))
def test_selected_placement_requires_unchanged_probe_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, name: str, missing: bool
) -> None:
    """Lost or replaced selection/probe bytes invalidate downstream resume."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "3")
    (tmp_path / "post_place.dcp").write_bytes(b"selected placement")
    _write_place_gate(tmp_path, bind=True)
    assert fpga_build.require_x3_post_place_gate(tmp_path)
    path = tmp_path / name
    if missing:
        path.unlink()
    else:
        path.write_text(path.read_text() + "\n")
    assert not fpga_build.require_x3_post_place_gate(tmp_path)


def test_disabled_probes_need_explicit_override_on_resume(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A prior probe waiver cannot silently become the default next time."""
    monkeypatch.setenv("FROST_CPU_CLK_DIV", "1")
    monkeypatch.setenv("FROST_PLACE_QUICK_ROUTE_COUNT", "0")
    (tmp_path / "post_place.dcp").write_bytes(b"unprobed placement")
    _write_place_gate(tmp_path, bind=True)
    assert fpga_build.require_x3_post_place_gate(tmp_path)
    monkeypatch.delenv("FROST_PLACE_QUICK_ROUTE_COUNT")
    assert not fpga_build.require_x3_post_place_gate(tmp_path)


@pytest.mark.parametrize(
    ("name", "value"),
    (
        ("FROST_PLACE_QUICK_ROUTE_COUNT", "-1"),
        ("FROST_PLACE_QUICK_ROUTE_COUNT", "bad"),
        ("FROST_PLACE_CONGESTION_VETO_LEVEL", "4"),
        ("FROST_PLACE_CONGESTION_VETO_LEVEL", "bad"),
    ),
)
def test_invalid_selection_settings_fail_before_build(
    monkeypatch: pytest.MonkeyPatch, name: str, value: str
) -> None:
    """Configuration errors must not cost a native implementation run."""
    monkeypatch.setenv(name, value)
    monkeypatch.setattr(sys, "argv", ["build.py", "x3"])
    monkeypatch.setattr(
        fpga_build, "compile_hello_world", lambda *_a: pytest.fail("build started")
    )
    with pytest.raises(SystemExit) as error:
        fpga_build.main()
    assert error.value.code == 2


def test_placement_sweep_rejects_changed_post_opt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Candidates cannot compete after the shared input changes mid-sweep."""
    fleet = _VivadoFleet(monkeypatch, 1)
    work = _sweep_input(tmp_path, "place")

    def place(command: list[str], **kwargs: Any) -> Any:
        process = fleet.popen(command, **kwargs)
        (work / "post_opt.dcp").write_bytes(b"replacement netlist")
        return process

    monkeypatch.setattr(fpga_build.subprocess, "Popen", place)
    assert not fpga_build.run_x3_step_directive_sweep(
        tmp_path, "place", ["Explore"], "placer", "unused", max_jobs=1
    )[0]
    assert not (work / "post_place_gate_binding.json").exists()
