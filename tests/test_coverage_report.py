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

"""Fast tests of the coverage merge and report (tests/coverage_report.py)."""

import shutil
from pathlib import Path

import pytest

import coverage_report

ROOT = coverage_report.REPO_ROOT


def _record(
    kind: str,
    module: str,
    comment: str,
    count: int,
    *,
    source: str = "hw/rtl/lib/cache/frost_cache.sv",
    line: int = 10,
    column: int = 3,
    top: str = "frost",
) -> str:
    """Return one coverage record in Verilator's format, from toplevel ``top``."""
    keys = {
        "f": str(ROOT / source),
        "l": str(line),
        "n": str(column),
        "t": kind,
        "page": f"v_{kind}/{module}",
        "o": comment,
        "h": f"{top}.u_{module}.u_*",
    }
    body = "".join(f"\x01{name}\x02{value}" for name, value in keys.items())
    return f"C '{body}' {count}\n"


def _write(path: Path, *records: str) -> Path:
    """Write a coverage file holding records."""
    path.write_text("# SystemC::Coverage-3\n" + "".join(records), encoding="utf-8")
    return path


def test_parse_point_reads_every_key() -> None:
    """The parser keeps each field and drops the parameter suffix of a module."""
    record = _record("user", "frost_cache__N4_W2", "cover_x", 7, line=42, column=5)
    point = coverage_report.parse_point(record.encode())
    assert point == coverage_report.CoveragePoint(
        kind="user",
        module="frost_cache",
        file=str(ROOT / "hw/rtl/lib/cache/frost_cache.sv"),
        line=42,
        column=5,
        comment="cover_x",
        count=7,
        soc_count=7,
    )
    bench = _record("user", "frost_cache", "cover_x", 7, top="frost_cache_test_harness")
    bench_point = coverage_report.parse_point(bench.encode())
    assert bench_point is not None and bench_point.soc_count == 0
    assert coverage_report.parse_point(b"# SystemC::Coverage-3\n") is None


def test_specializations_of_a_module_share_a_point(tmp_path: Path) -> None:
    """A location counts once, hit if any specialization of its module hit it."""
    data = _write(
        tmp_path / "a.dat",
        _record("line", "sdp_dist_ram__A3", "block", 0),
        _record("line", "sdp_dist_ram__A7", "block", 4),
        _record("line", "sdp_dist_ram__A7", "block", 0, line=11),
    )
    points = sorted(coverage_report.read_points(data), key=lambda point: point.line)
    assert [(point.line, point.count) for point in points] == [(10, 4), (11, 0)]


def test_merge_adds_runs_instances_and_parameter_sets(tmp_path: Path) -> None:
    """A merge sums a location's counts by toplevel, whatever its instances or parameters."""
    first = _write(
        tmp_path / "bench.dat",
        _record(
            "user", "frost_cache__N4", "cover_a", 2, top="frost_cache_test_harness"
        ),
        _record(
            "user", "frost_cache__N2", "cover_a", 1, top="frost_cache_test_harness"
        ),
        _record("line", "frost_cache", "block", 0, line=11),
    )
    second = _write(
        tmp_path / "soc.dat",
        _record("user", "frost_cache__N8", "cover_a", 3),
        _record("line", "frost_cache", "block", 0, line=11),
    )
    output = tmp_path / "merged.dat"
    assert coverage_report.merge([first, second], output) == [first, second]
    text = output.read_text(encoding="utf-8")
    assert text.startswith("# SystemC::Coverage-3\n")
    records = sorted(line for line in text.splitlines() if line.startswith("C '"))
    # The bench's two parameter sets become one record, apart from the SoC's.
    assert len(records) == 3
    assert all(".u_" not in record for record in records)
    assert "\x01h\x02frost_cache_test_harness\x01" in "".join(records)
    points = {point.comment: point for point in coverage_report.read_points(output)}
    assert (points["cover_a"].count, points["cover_a"].soc_count) == (6, 3)
    assert points["cover_a"].module == "frost_cache"
    assert points["block"].count == 0


def test_summary_lists_totals_cover_points_and_modules() -> None:
    """The summary counts each kind, names every unhit cover point, and lists modules."""
    points = [
        coverage_report.CoveragePoint(*fields)
        for fields in (
            ("line", "load_queue", "/x/load_queue.sv", 1, 1, "block", 3),
            ("line", "load_queue", "/x/load_queue.sv", 2, 1, "block", 0),
            ("toggle", "load_queue", "/x/load_queue.sv", 3, 1, "a:0->1", 1),
            ("user", "load_queue", "/x/load_queue.sv", 9, 3, "cover_hit", 12, 10),
            ("user", "load_queue", "/x/load_queue.sv", 8, 3, "cover_missed", 0),
            ("user", "load_queue", "/x/load_queue.sv", 7, 3, "cover_bench", 4, 0),
            ("branch", "dispatch", "/x/dispatch.sv", 5, 1, "if", 1),
        )
    ]
    text = coverage_report.summary_markdown(points, ["a.dat", "b.dat"])
    assert "Merged from 2 coverage files." in text
    assert "- `b.dat`" in text
    assert "| Line | 1 | 2 | 50.0% |" in text
    assert "| Cover points | 2 | 3 | 66.7% |" in text
    assert "Not hit by any run: `load_queue.cover_missed`." in text
    assert (
        "Hit only by unit benches, not by a whole-SoC run: `load_queue.cover_bench`."
        in text
    )
    assert "| `load_queue` | `cover_hit` | 12 | 10 | `/x/load_queue.sv:9` |" in text
    assert (
        "| `load_queue` | `/x/load_queue.sv` | 50.0% (1/2) | - | 100.0% (1/1) |" in text
    )
    assert "| `dispatch` | `/x/dispatch.sv` | - | 100.0% (1/1) | - |" in text


def test_coverage_files_search_directories_and_skip_empty_files(tmp_path: Path) -> None:
    """Directories are searched, empty files skipped, and the merge output left out."""
    nested = tmp_path / "job" / "nested"
    nested.mkdir(parents=True)
    first = _write(tmp_path / "job" / "a.dat", _record("line", "m", "block", 1))
    second = _write(nested / "b.dat", _record("line", "m", "block", 1))
    (tmp_path / "job" / "empty.dat").touch()
    output = _write(tmp_path / "job" / "merged.dat", _record("line", "m", "block", 1))
    found = coverage_report.coverage_files([tmp_path / "job"], exclude=output)
    assert found == [first, second]


@pytest.mark.skipif(
    shutil.which("verilator_coverage") is None,
    reason="verilator_coverage is in the frost image",
)
def test_report_merges_runs_and_writes_lcov(tmp_path: Path) -> None:
    """Two runs merge into one report whose lcov file has only line and branch data."""
    runs = tmp_path / "runs"
    runs.mkdir()
    _write(
        runs / "a.dat",
        _record("line", "lq", "block", 2),
        _record("user", "lq", "cover_a", 0, line=20),
        _record("toggle", "lq", "sig:0->1", 1, line=30),
    )
    _write(
        runs / "b.dat",
        _record("line", "lq", "block", 3),
        _record("user", "lq", "cover_a", 5, line=20),
        _record("branch", "lq", "if", 1, line=40, column=1),
        _record("branch", "lq", "else", 0, line=40, column=2),
    )
    report = tmp_path / "report"
    assert coverage_report.report([runs], report) == 0
    text = (report / "summary.md").read_text(encoding="utf-8")
    assert "Every cover point was hit." in text
    assert "| `lq` | `cover_a` | 5 |" in text
    info = (report / "coverage.info").read_text(encoding="utf-8")
    assert "SF:hw/rtl/lib/cache/frost_cache.sv\n" in info
    assert "DA:10,5" in info
    # A branch hit once counts as hit.
    assert "BRF:2\nBRH:1\n" in info
    # The toggle and cover points stay out of the lcov branch records.
    assert "DA:30" not in info and "DA:20" not in info
    assert not list(report.glob("*.lines.dat"))


def test_report_without_coverage_files_fails(tmp_path: Path) -> None:
    """A report with nothing to merge is an error, not an empty success."""
    (tmp_path / "runs").mkdir()
    assert coverage_report.report([tmp_path / "runs"], tmp_path / "report") == 1
