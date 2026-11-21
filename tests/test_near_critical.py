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

"""Exercise the endpoint report with and without clock interaction data."""

import csv
import subprocess
import sys
from pathlib import Path

import pytest

BUILD = Path(__file__).resolve().parents[1] / "fpga/build"
MODEL = Path(__file__).with_name("fixtures") / "near_critical_model.tcl"

type ReportRow = tuple[str, tuple[int, ...], str, str, str]


def _report(paths: Path, *options: str) -> dict[tuple[str, str], ReportRow]:
    result = subprocess.run(
        [sys.executable, str(BUILD / "near_critical.py"), str(paths), *options],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "Near-critical setup paths by clock pair"
    pairs = {}
    for row in csv.reader(lines[2:], delimiter="\t"):
        launch, capture, worst, *counts, constraint, pair_worst, endpoints = row
        pair = launch, capture
        assert pair not in pairs
        pairs[pair] = worst, tuple(map(int, counts)), constraint, pair_worst, endpoints
    return pairs


@pytest.fixture
def checkpoint_exports(tmp_path: Path) -> Path:
    """Run the repository Tcl entry point with modeled Vivado commands."""
    result = subprocess.run(
        ["tclsh", str(MODEL), str(BUILD / "near_critical.tcl"), str(tmp_path)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    return tmp_path


def test_checkpoint_export_preserves_direction_and_clock_metadata(
    checkpoint_exports: Path,
) -> None:
    """Represent every pair and reconcile signed minima, metadata, and path totals."""
    pairs = _report(
        checkpoint_exports / "export_paths.csv",
        "--clock-interaction",
        str(checkpoint_exports / "export_clock_interaction.rpt"),
    )
    assert pairs == {
        ("<unknown>", "cpu"): (
            "-0.015",
            (1, 1, 1, 1, 1),
            "unknown clock",
            "n/a",
            "n/a",
        ),
        ("cpu", "<unknown>"): (
            "+0.000",
            (1, 0, 1, 1, 1),
            "unknown clock",
            "n/a",
            "n/a",
        ),
        ("cpu", "cpu"): (
            "-0.250",
            (2, 1, 2, 2, 2),
            "Partial False Path",
            "-0.250",
            "32",
        ),
        ("cpu", "ddr"): ("n/a", (0, 0, 0, 0, 0), "Asynchronous Groups", "n/a", "9"),
        ("cpu", "freerun"): ("n/a", (0, 0, 0, 0, 0), "False Path", "n/a", "6"),
        ("cpu", "nic[1]"): ("+0.399", (4, 0, 1, 2, 3), "Timed", "+0.399", "11"),
        ("ddr", "cpu"): ("n/a", (0, 0, 0, 0, 0), "Asynchronous Groups", "n/a", "2"),
        ("freerun", "freerun"): ("n/a", (0, 0, 0, 0, 0), "Timed", "+2.100", "7"),
        ('io "ref", gated', "cpu"): (
            "+0.512",
            (1, 0, 0, 1, 1),
            "unreported",
            "n/a",
            "n/a",
        ),
        ("nic[1]", "cpu"): (
            "+0.675",
            (2, 0, 0, 1, 2),
            "Max Delay Datapath Only",
            "+0.675",
            "8",
        ),
        ("All paths", ""): ("-0.250", (11, 2, 5, 8, 10), "", "", ""),
    }


def test_report_reads_wrapped_summary_for_a_known_pair(
    checkpoint_exports: Path,
) -> None:
    """Read the three-column report with combinations of wrapped fields."""
    pairs = _report(checkpoint_exports / "summary.rpt", "--summary-pair", "cpu", "cpu")
    assert pairs == {
        ("cpu", "cpu"): ("-0.005", (4, 1, 1, 2, 3), "unreported", "n/a", "n/a"),
        ("All paths", ""): ("-0.005", (4, 1, 1, 2, 3), "", "", ""),
    }


def test_report_keeps_interactions_when_no_paths_match(
    checkpoint_exports: Path,
) -> None:
    """Keep zero path totals and clock metadata for a header-only dump."""
    paths = checkpoint_exports / "paths.csv"
    paths.write_text("start_clock,end_clock,slack_ns\n", encoding="utf-8")
    pairs = _report(
        paths,
        "--clock-interaction",
        str(checkpoint_exports / "export_clock_interaction.rpt"),
    )
    assert pairs[("All paths", "")] == ("n/a", (0, 0, 0, 0, 0), "", "", "")
    assert pairs[("ddr", "cpu")] == (
        "n/a",
        (0, 0, 0, 0, 0),
        "Asynchronous Groups",
        "n/a",
        "2",
    )
