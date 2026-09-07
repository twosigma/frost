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

"""Print a fetch-seam ILA capture (capture_fetch_ila.py collect) as a cycle table.

Vivado's CSV names each column by the probed net's hierarchical path with a
bit range; this tool shortens them to the mirror name (``if_pc_reg``,
``fp_served``, ...), prints hex for buses, and shows the samples around the
trigger. ``--only`` keeps the listed columns (prefix match), ``--changes``
prints a row only when one of the shown columns changed.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"dbg_ila_([a-z0-9_]+?)(?:\[(\d+):(\d+)\])?$")


def short_name(column: str) -> str:
    """Return the mirror name of a Vivado CSV column, or the column itself."""
    match = NAME_RE.search(column)
    return match.group(1) if match else column


def load_capture(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    """Read the ILA CSV: (short column names in file order, rows by short name)."""
    with path.open(newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader)
        # Vivado emits a radix row right after the header.
        rows = list(reader)
    names = [short_name(column) for column in header]
    if rows and all(
        cell.upper() in {"HEX", "UNSIGNED", "SIGNED", "BINARY", "OCTAL", "ASCII", ""}
        for cell in rows[0][:3]
    ):
        rows = rows[1:]
    return names, [dict(zip(names, row, strict=False)) for row in rows]


def format_cell(name: str, value: str) -> str:
    """Hex for wide values, the raw digit for single bits."""
    value = value.strip()
    if len(value) <= 1:
        return value
    try:
        return f"{int(value, 16):x}" if not value.isdigit() or len(value) > 3 else value
    except ValueError:
        return value


def main() -> int:
    """Print the capture around the trigger."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", type=Path)
    parser.add_argument(
        "--before", type=int, default=64, help="rows before the trigger"
    )
    parser.add_argument("--after", type=int, default=32, help="rows after the trigger")
    parser.add_argument(
        "--only", nargs="*", default=None, help="column prefixes to keep"
    )
    parser.add_argument(
        "--changes", action="store_true", help="print rows on change only"
    )
    parser.add_argument("--list", action="store_true", help="list the columns and exit")
    args = parser.parse_args()

    names, rows = load_capture(args.csv)
    if args.list:
        for name in names:
            print(name)
        return 0
    trigger_column = next((n for n in names if n.upper() == "TRIGGER"), None)
    sample_column = next(
        (n for n in names if n.lower().startswith("sample in buffer")), names[0]
    )
    trigger_index = next(
        (
            i
            for i, row in enumerate(rows)
            if trigger_column and row.get(trigger_column, "0").strip() == "1"
        ),
        None,
    )
    if trigger_index is None:
        print("no trigger row found; printing the first rows", file=sys.stderr)
        trigger_index = 0
    shown = [
        n
        for n in names
        if n not in {trigger_column, sample_column}
        and not n.lower().startswith("sample in")
    ]
    if args.only:
        shown = [n for n in shown if any(n.startswith(prefix) for prefix in args.only)]
    start = max(0, trigger_index - args.before)
    end = min(len(rows), trigger_index + args.after + 1)
    widths = {n: max(len(n), 4) for n in shown}
    print(" ".join(["  rel", *(n.rjust(widths[n]) for n in shown)]))
    previous: dict[str, str] | None = None
    for index in range(start, end):
        row = rows[index]
        cells = {n: format_cell(n, row.get(n, "")) for n in shown}
        if (
            args.changes
            and previous is not None
            and previous == cells
            and index != trigger_index
        ):
            continue
        marker = "T" if index == trigger_index else " "
        print(
            " ".join(
                [
                    f"{marker}{index - trigger_index:+5d}",
                    *(cells[n].rjust(widths[n]) for n in shown),
                ]
            )
        )
        previous = cells
    return 0


if __name__ == "__main__":
    sys.exit(main())
