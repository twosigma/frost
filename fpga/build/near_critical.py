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

"""Summarize near-critical setup paths by launch and capture clock."""

import argparse
import csv
import re
import sys
from collections import defaultdict
from collections.abc import Iterator
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path

type ClockPair = tuple[str, str]

LIMITS = (Decimal("0"), Decimal("0.4"), Decimal("0.7"), Decimal("1.0"))


def read_margin(value: str, location: str) -> Decimal:
    """Read a finite margin without rounding a threshold boundary."""
    try:
        margin = Decimal(value)
        if margin.is_finite():
            return margin
    except InvalidOperation:
        pass
    raise ValueError(f"{location}: invalid margin {value!r}")


def signed_margin(margin: Decimal | None) -> str:
    """Keep the original precision and show the sign."""
    return f"{margin:+f}" if margin is not None else "n/a"


@dataclass
class PathCounts:
    """Counts and minimum path margin for a report or a single pair."""

    worst: Decimal | None = None
    paths: int = 0
    below: list[int] = field(default_factory=lambda: [0] * len(LIMITS))

    def add(self, margin: Decimal) -> None:
        """Count one path at each threshold it falls below."""
        self.paths += 1
        if self.worst is None or margin < self.worst:
            self.worst = margin
        for index, limit in enumerate(LIMITS):
            self.below[index] += margin < limit

    def columns(self) -> tuple[str | int, ...]:
        """Return the path statistics for one row."""
        return signed_margin(self.worst), self.paths, *self.below


@dataclass(frozen=True)
class ClockInteraction:
    """Pair-level data from Vivado's clock interaction table."""

    constraint: str
    worst: Decimal | None
    endpoints: int | None

    def columns(self) -> tuple[str | int, ...]:
        """Return the relationship and any tool-reported values."""
        endpoints = self.endpoints if self.endpoints is not None else "n/a"
        return self.constraint, signed_margin(self.worst), endpoints


def read_path_csv(path: Path) -> Iterator[tuple[ClockPair, str]]:
    """Read clock and margin fields from a clock-qualified path export."""
    fields = ("start_clock", "end_clock", "slack_ns")
    with path.open(newline="", encoding="utf-8") as source:
        rows = csv.DictReader(source, strict=True)
        if rows.fieldnames is None or any(
            name not in rows.fieldnames for name in fields
        ):
            raise ValueError(f"{path}: expected CSV columns {', '.join(fields)}")
        for row in rows:
            if None in row or any(row[name] is None for name in fields):
                raise ValueError(f"{path}:{rows.line_num}: incomplete path record")
            yield (
                (row["start_clock"].strip(), row["end_clock"].strip()),
                row["slack_ns"],
            )


def read_path_summary(path: Path, pair: ClockPair) -> Iterator[tuple[ClockPair, str]]:
    """Read a Vivado three-column summary collected for one known pair."""
    with path.open(encoding="utf-8") as source:
        header = next((line.strip() for line in source if line.strip()), "")
        if header == "No paths found.":
            return
        if header.split() != [
            "Startpoint",
            "Endpoint",
            "Slack(ns)",
        ] or not re.fullmatch(r"-+", next(source, "").strip()):
            raise ValueError(f"{path}: expected a Vivado path summary table")

        # Long pin names can wrap the three fields onto separate lines.
        fields = (word for line in source for word in line.split())
        for _ in fields:
            endpoint = next(fields, None)
            margin = next(fields, None)
            if endpoint is None or margin is None:
                raise ValueError(f"{path}: incomplete path record")
            yield pair, margin


def read_clock_interactions(path: Path) -> dict[ClockPair, ClockInteraction]:
    """Read the directional pairs in a Vivado setup interaction table."""
    interactions: dict[ClockPair, ClockInteraction] = {}
    expected_header = (
        "From Clock",
        "To Clock",
        "Clock Edges",
        "WNS(ns)",
        "TNS(ns)",
        "Endpoints",
        "Endpoints",
        "Requirement(ns)",
        "Classification",
        "Constraints",
    )
    with path.open(encoding="utf-8") as source:
        for header in source:
            if re.match(r"^\s*From Clock\s+To Clock\s+Clock Edges\s+", header):
                break
        else:
            raise ValueError(f"{path}: expected a Vivado clock interaction table")

        # The divider marks column widths, including fields left blank by Vivado.
        divider = next(source, "")
        columns = [slice(*match.span()) for match in re.finditer(r"-+", divider)]
        if tuple(header[column].strip() for column in columns) != expected_header:
            raise ValueError(f"{path}: invalid clock interaction header")

        for index, line in enumerate(source, start=1):
            if not line.strip():
                break
            launch, capture, _, wns, _, _, total, _, _, label = (
                line[column].strip() for column in columns
            )
            pair = launch, capture
            if not label or not all(pair) or pair in interactions:
                raise ValueError(f"{path}: invalid clock interaction row for {pair}")
            location = f"{path}: interaction row {index}"
            interactions[pair] = ClockInteraction(
                label,
                read_margin(wns, location) if wns else None,
                int(total) if total else None,
            )
    return interactions


def main() -> int:
    """Print the report from path data and optional clock relationship data."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", type=Path, help="clock-qualified setup path CSV")
    parser.add_argument(
        "--clock-interaction", type=Path, help="Vivado setup clock report"
    )
    parser.add_argument(
        "--summary-pair",
        nargs=2,
        metavar=("LAUNCH", "CAPTURE"),
        help="read a three-column Vivado summary collected for this pair",
    )
    args = parser.parse_args()

    by_pair: defaultdict[ClockPair, PathCounts] = defaultdict(PathCounts)
    total = PathCounts()
    try:
        interactions = (
            read_clock_interactions(args.clock_interaction)
            if args.clock_interaction
            else {}
        )
        paths = (
            read_path_summary(args.paths, tuple(args.summary_pair))
            if args.summary_pair
            else read_path_csv(args.paths)
        )
        for index, (pair, value) in enumerate(paths, start=1):
            margin = read_margin(value, f"{args.paths}: path {index}")
            by_pair[pair].add(margin)
            total.add(margin)
    except (OSError, ValueError, csv.Error) as exc:
        parser.error(str(exc))

    print("Near-critical setup paths by clock pair")
    report = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    report.writerow(
        [
            "Launch clock",
            "Capture clock",
            "Worst path (ns)",
            "Paths",
            "<0",
            "<+0.4",
            "<+0.7",
            "<+1.0",
            "Inter-clock constraints",
            "Interaction WNS (ns)",
            "Interaction endpoints",
        ]
    )
    empty = PathCounts().columns()
    for pair in sorted(by_pair.keys() | interactions.keys()):
        launch, capture = pair
        counts = by_pair[pair].columns() if pair in by_pair else empty
        status = "unreported" if all(pair) else "unknown clock"
        interaction = interactions.get(pair)
        metadata = interaction.columns() if interaction else (status, "n/a", "n/a")
        report.writerow(
            [launch or "<unknown>", capture or "<unknown>", *counts, *metadata]
        )
    report.writerow(["All paths", "", *total.columns(), "", "", ""])
    return 0


if __name__ == "__main__":
    sys.exit(main())
