#!/usr/bin/env python3

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

"""Merge Verilator coverage files and report what the simulations reach.

A simulation built with FROST_COVERAGE=1 writes one coverage file (see
tests/README.md). ``merge`` combines coverage files into one, and ``report``
merges them and writes a report:

    ./scripts/frost.py run python3 tests/coverage_report.py merge tests/coverage --output all.dat
    ./scripts/frost.py run python3 tests/coverage_report.py report tests/coverage

A merge adds up each point's counts across runs, and also across the
instances and the parameter sets of its module, but keeps the counts of
different toplevels apart: a cover point hit only by a unit bench has not
been reached by a whole-SoC run. The report directory holds the merged file
(coverage.dat), its line and branch coverage in lcov format (coverage.info,
with paths relative to the repository root), and summary.md: the totals,
every cover point with its hits in all runs and in whole-SoC runs, and line,
branch, and toggle coverage per module. Toggle totals use the union of the
points collected, with a separate whole-SoC union for builds that collect a
subset. ``--annotate`` also writes annotated copies of the sources with
verilator_coverage.
"""

import argparse
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPORT_DIR = REPO_ROOT / "tests" / "coverage_report"
HEADER = "# SystemC::Coverage-3\n"
# The toplevel of the whole-SoC builds: the programs, the ISA suites, and
# TestRIG. Unit benches have toplevels of their own.
SOC_TOPLEVEL = "frost"

# Verilator point types in report order. Line coverage comes as "line"
# (statement blocks) and "branch" (if, else, and case arms) points, toggle
# coverage as one point per bit and direction, and SystemVerilog cover
# statements as "user" points.
KIND_TITLES = {
    "line": "Line",
    "branch": "Branch",
    "toggle": "Toggle (all runs)",
    "user": "Cover points",
}


@dataclass(frozen=True)
class CoveragePoint:
    """One coverage point: where it is, what it counts, and its hit counts.

    ``soc_count`` is the part of ``count`` that whole-SoC builds hit.
    ``soc_instrumented`` distinguishes an unhit whole-SoC point from one
    that only a unit bench collected.
    """

    kind: str
    module: str
    file: str
    line: int
    column: int
    comment: str
    count: int
    soc_count: int = 0
    soc_instrumented: bool = False


@dataclass
class Tally:
    """Covered and total points of one kind."""

    covered: int = 0
    total: int = 0

    def add(self, count: int) -> None:
        """Count one point with ``count`` hits."""
        self.total += 1
        if count > 0:
            self.covered += 1

    def cell(self) -> str:
        """Return the percentage and counts as one table cell."""
        if self.total == 0:
            return "-"
        return (
            f"{100 * self.covered / self.total:.1f}% ({self.covered:,}/{self.total:,})"
        )


@dataclass
class ModuleSummary:
    """Per-kind tallies of one module and the files its points come from."""

    tallies: dict[str, Tally] = field(default_factory=lambda: defaultdict(Tally))
    soc_toggle: Tally = field(default_factory=Tally)
    files: Counter[str] = field(default_factory=Counter)


def coverage_files(paths: Iterable[Path], exclude: Path | None = None) -> list[Path]:
    """Return the coverage files that paths name: files as given, directories searched.

    Empty files and ``exclude`` (a merge's own output) are left out.
    """
    found: list[Path] = []
    for path in paths:
        if path.is_dir():
            found.extend(sorted(path.rglob("*.dat")))
        elif path.is_file():
            found.append(path)
        else:
            print(f"warning: {path} does not exist", file=sys.stderr)
    skip = exclude.resolve() if exclude is not None else None
    return [
        path
        for path in found
        if path.stat().st_size > 0 and (skip is None or path.resolve() != skip)
    ]


def split_record(record: bytes) -> tuple[dict[str, str], int] | None:
    r"""Split one ``C '<keys>' <count>`` record into its keys and its count.

    Each key is ``\x01<name>\x02<value>``. Other lines return None.

    >>> split_record(b"C '\x01t\x02user\x01o\x02cover_x' 3\n")
    ({'t': 'user', 'o': 'cover_x'}, 3)
    """
    if not record.startswith(b"C '"):
        return None
    body, separator, count = record.rstrip(b"\r\n").rpartition(b"' ")
    if not separator or not count.isdigit():
        return None
    keys: dict[str, str] = {}
    for item in body[3:].split(b"\x01"):
        name, _, value = item.partition(b"\x02")
        if name:
            keys[name.decode()] = value.decode(errors="replace")
    return keys, int(count)


def module_name(page: str) -> str:
    """Return the module of a page key, without Verilator's parameter suffix.

    >>> module_name("v_toggle/lq_l0_cache__D80_X40")
    'lq_l0_cache'
    """
    return page.partition("/")[2].partition("__")[0]


def toplevel(hierarchy: str) -> str:
    """Return the toplevel of an instance hierarchy key, its first name.

    >>> toplevel("frost.cpu_and_memory_subsystem.u_*.cover_x")
    'frost'
    """
    return hierarchy.partition(".")[0]


def merge_key(keys: dict[str, str]) -> str:
    """Return the identity a merge sums counts by.

    It is every key in key order, with the instance hierarchy cut to its
    toplevel and the page naming the module without its parameter suffix.
    """
    merged = dict(keys)
    if "h" in merged:
        merged["h"] = toplevel(merged["h"])
    if "page" in merged:
        kind = merged["page"].partition("/")[0]
        merged["page"] = f"{kind}/{module_name(merged['page'])}"
    return "".join(f"\x01{name}\x02{merged[name]}" for name in sorted(merged))


def parse_point(record: bytes) -> CoveragePoint | None:
    r"""Parse one record of a coverage file into a point; other lines return None.

    >>> parse_point(b"C '\x01t\x02user\x01page\x02v_user/lq__D8\x01o\x02c' 3\n").module
    'lq'
    """
    parsed = split_record(record)
    if parsed is None:
        return None
    keys, count = parsed
    return CoveragePoint(
        kind=keys.get("t", ""),
        module=module_name(keys.get("page", "")),
        file=keys.get("f", ""),
        line=int(keys.get("l") or 0),
        column=int(keys.get("n") or 0),
        comment=keys.get("o", ""),
        count=count,
        soc_count=count if toplevel(keys.get("h", "")) == SOC_TOPLEVEL else 0,
        soc_instrumented=toplevel(keys.get("h", "")) == SOC_TOPLEVEL,
    )


def read_points(path: Path) -> list[CoveragePoint]:
    """Return the points of a coverage file, one per source location.

    The points of every toplevel, instance, and parameter set of a module at
    one source location become one point, which counts as covered when any of
    them was.
    """
    counts: dict[tuple[str, str, str, int, int, str], list[int]] = defaultdict(
        lambda: [0, 0]
    )
    soc_keys = set()
    with path.open("rb") as stream:
        for record in stream:
            point = parse_point(record)
            if point is not None:
                key = (
                    point.kind,
                    point.module,
                    point.file,
                    point.line,
                    point.column,
                    point.comment,
                )
                counts[key][0] += point.count
                counts[key][1] += point.soc_count
                if point.soc_instrumented:
                    soc_keys.add(key)
    return [
        CoveragePoint(
            *key, count=count[0], soc_count=count[1], soc_instrumented=key in soc_keys
        )
        for key, count in counts.items()
    ]


def relative_path(path: str, root: Path = REPO_ROOT) -> str:
    """Return path relative to the repository root when it lies inside it.

    >>> relative_path("/workspace/hw/rtl/frost.sv", Path("/workspace"))
    'hw/rtl/frost.sv'
    >>> relative_path("/other/x.sv", Path("/workspace"))
    '/other/x.sv'
    """
    try:
        return Path(path).relative_to(root).as_posix()
    except ValueError:
        return path


def cover_names(points: Iterable[CoveragePoint]) -> str:
    """Return cover points as a comma-separated list of ``module.name``."""
    return ", ".join(f"`{point.module}.{point.comment}`" for point in points)


def summary_markdown(points: Sequence[CoveragePoint], inputs: Sequence[str]) -> str:
    """Return the Markdown summary of merged coverage points and their input files."""
    totals: dict[str, Tally] = defaultdict(Tally)
    soc_toggle = Tally()
    modules: dict[str, ModuleSummary] = defaultdict(ModuleSummary)
    for point in points:
        totals[point.kind].add(point.count)
        summary = modules[point.module]
        summary.tallies[point.kind].add(point.count)
        if point.kind == "toggle" and point.soc_instrumented:
            soc_toggle.add(point.soc_count)
            summary.soc_toggle.add(point.soc_count)
        summary.files[relative_path(point.file)] += 1

    lines = [
        "## Coverage",
        "",
        f"Merged from {len(inputs):,} coverage file{'' if len(inputs) == 1 else 's'}.",
        "",
        "<details><summary>Coverage files</summary>",
        "",
        *(f"- `{name}`" for name in inputs),
        "",
        "</details>",
        "",
        "Each toggle point is one source bit and transition direction. Toggle",
        "figures count their union across runs, instances, and parameter sets.",
        "Whole-SoC toggle figures use only the",
        "points collected by whole-SoC builds. An omitted point is outside that",
        "denominator; a collected point with zero hits is uncovered. These",
        "figures do not imply that every signal was instrumented.",
        "",
        "| Coverage | Covered | Points | Percent |",
        "| --- | ---: | ---: | ---: |",
    ]
    for kind, title in KIND_TITLES.items():
        tally = totals.get(kind, Tally())
        percent = f"{100 * tally.covered / tally.total:.1f}%" if tally.total else "-"
        lines.append(f"| {title} | {tally.covered:,} | {tally.total:,} | {percent} |")
        if kind == "toggle":
            percent = (
                f"{100 * soc_toggle.covered / soc_toggle.total:.1f}%"
                if soc_toggle.total
                else "-"
            )
            lines.append(
                f"| Toggle (whole-SoC) | {soc_toggle.covered:,} | "
                f"{soc_toggle.total:,} | {percent} |"
            )

    covers = sorted(
        (point for point in points if point.kind == "user"),
        key=lambda point: (point.module, point.file, point.line, point.comment),
    )
    missed = [point for point in covers if point.count == 0]
    bench_only = [point for point in covers if point.count and not point.soc_count]
    lines += ["", "### Cover points", ""]
    if not covers:
        lines.append("No cover points.")
    else:
        if missed:
            lines += [f"Not hit by any run: {cover_names(missed)}.", ""]
        else:
            lines += ["Every cover point was hit.", ""]
        if bench_only:
            lines += [
                "Hit only by unit benches, not by a whole-SoC run: "
                f"{cover_names(bench_only)}.",
                "",
            ]
        lines += [
            "| Module | Cover point | Hits | Whole-SoC hits | Source |",
            "| --- | --- | ---: | ---: | --- |",
        ]
        for point in covers:
            lines.append(
                f"| `{point.module}` | `{point.comment}` | {point.count:,} | "
                f"{point.soc_count:,} | `{relative_path(point.file)}:{point.line}` |"
            )

    lines += [
        "",
        "### Modules",
        "",
        "| Module | Source | Line | Branch | Toggle (all runs) | Toggle (whole-SoC) |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
    ]
    rows = []
    for name, summary in modules.items():
        source = summary.files.most_common(1)[0][0] if summary.files else ""
        rows.append((source, name, summary))
    for source, name, summary in sorted(rows):
        cells = " | ".join(
            summary.tallies[kind].cell() if kind in summary.tallies else "-"
            for kind in ("line", "branch", "toggle")
        )
        lines.append(
            f"| `{name}` | `{source}` | {cells} | {summary.soc_toggle.cell()} |"
        )
    return "\n".join(lines) + "\n"


def verilator_coverage(arguments: Sequence[str]) -> None:
    """Run verilator_coverage, raising CalledProcessError if it fails."""
    tool = shutil.which("verilator_coverage")
    if tool is None:
        raise FileNotFoundError(
            "verilator_coverage is not on PATH (it is in the frost image)"
        )
    subprocess.run([tool, *arguments], check=True)


def merge(inputs: Sequence[Path], output: Path) -> list[Path]:
    """Merge the coverage files that inputs name into output; return them."""
    files = coverage_files(inputs, exclude=output)
    if not files:
        return files
    counts: dict[str, int] = defaultdict(int)
    for path in files:
        with path.open("rb") as stream:
            for record in stream:
                parsed = split_record(record)
                if parsed is not None:
                    counts[merge_key(parsed[0])] += parsed[1]
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as stream:
        stream.write(HEADER)
        for key in sorted(counts):
            stream.write(f"C '{key}' {counts[key]}\n")
    return files


def write_lcov(merged: Path, info: Path) -> None:
    """Write merged line and branch coverage as lcov with repository-relative paths.

    verilator_coverage writes toggle and cover points as lcov branches, so the
    lcov file is written from a copy that holds only line and branch points
    (its --filter-type takes a single type pattern).
    """
    line_and_branch = info.with_suffix(".lines.dat")
    with merged.open("rb") as source, line_and_branch.open("wb") as copy:
        for record in source:
            point = parse_point(record)
            if point is None or point.kind in ("line", "branch"):
                copy.write(record)
    try:
        # Without --annotate-min 1, --write-info counts a branch as hit only
        # after ten hits (its default threshold).
        verilator_coverage(
            ["--annotate-min", "1", "--write-info", str(info), str(line_and_branch)]
        )
    finally:
        line_and_branch.unlink()
    text = info.read_text(encoding="utf-8")
    info.write_text(
        "".join(
            f"SF:{relative_path(line[3:].rstrip(chr(10)))}\n"
            if line.startswith("SF:")
            else line
            for line in text.splitlines(keepends=True)
        ),
        encoding="utf-8",
    )


def report(inputs: Sequence[Path], output_dir: Path, *, annotate: bool = False) -> int:
    """Merge inputs into output_dir and write the report; return an exit status."""
    output_dir.mkdir(parents=True, exist_ok=True)
    merged = output_dir / "coverage.dat"
    files = merge(inputs, merged)
    if not files:
        print("No coverage files found", file=sys.stderr)
        return 1
    write_lcov(merged, output_dir / "coverage.info")
    if annotate:
        verilator_coverage(
            [
                "--annotate",
                str(output_dir / "annotated"),
                "--annotate-min",
                "1",
                str(merged),
            ]
        )
    text = summary_markdown(read_points(merged), sorted(path.name for path in files))
    (output_dir / "summary.md").write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    merge_parser = commands.add_parser("merge", help="merge coverage files into one")
    merge_parser.add_argument(
        "inputs", nargs="+", type=Path, help="files or directories"
    )
    merge_parser.add_argument("--output", type=Path, required=True)

    report_parser = commands.add_parser("report", help="merge and summarize")
    report_parser.add_argument(
        "inputs", nargs="+", type=Path, help="files or directories"
    )
    report_parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_REPORT_DIR,
        help="report directory (default tests/coverage_report)",
    )
    report_parser.add_argument(
        "--annotate", action="store_true", help="also write annotated sources"
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the merge or report command."""
    arguments = parse_arguments(argv)
    if arguments.command == "merge":
        files = merge(arguments.inputs, arguments.output)
        print(f"Merged {len(files)} coverage files into {arguments.output}")
        return 0
    return report(arguments.inputs, arguments.output_dir, annotate=arguments.annotate)


if __name__ == "__main__":
    sys.exit(main())
