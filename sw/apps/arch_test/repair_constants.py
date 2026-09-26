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

"""Repair the malformed data constants in the pinned riscv-arch-test F/D tests.

In 99 of the F and D sources, most `NAN_BOXED(value,width,FLEN)` data entries
run the intended hex value together with its own decimal digits, less the
first: 0x7f7fffff (2139095039) appears as 0x7f7fffff139095039. The assembler
truncates such a value to the field width with a warning, so the test loads
other operands than its comments name, and some special cases never run.

A value wider than its field is split into the hex prefix that fits the field
and a suffix that must be a leading part of the prefix's decimal digits, less
the first (one entry carries only the first suffix digit). Exactly one split
satisfies that for every entry in the pinned suite; the script stops with an
error on a value that has none or several. Values that fit are left alone.

Both builds use the repaired copy: the arch_test Makefile for FROST and
generate_references.py for the Spike reference.

    ./repair_constants.py <test.S> <repaired.S>
"""

import re
import sys
from pathlib import Path

_NAN_BOXED = re.compile(r"NAN_BOXED\(0x([0-9a-fA-F]+),(\d+),FLEN\)")


def _repair_value(digits: str, width: int) -> str:
    """Return the intended hex digits of one oversized NAN_BOXED value."""
    splits = []
    for cut in range(1, len(digits)):
        head, tail = digits[:cut], digits[cut:]
        value = int(head, 16)
        if value < (1 << width) and str(value)[1:].startswith(tail):
            splits.append(head)
    if len(splits) != 1:
        raise ValueError(
            f"0x{digits} ({width}-bit field): {len(splits)} candidate values"
        )
    return splits[0]


def repair(text: str) -> tuple[str, int]:
    """Repair every oversized NAN_BOXED value in `text`; return it and the count."""
    count = 0

    def fix(match: re.Match[str]) -> str:
        nonlocal count
        digits, width = match.group(1), int(match.group(2))
        if int(digits, 16) < (1 << width):
            return match.group(0)
        count += 1
        return f"NAN_BOXED(0x{_repair_value(digits, width)},{width},FLEN)"

    return _NAN_BOXED.sub(fix, text), count


def main() -> int:
    """Write a repaired copy of one test source."""
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    source, destination = Path(sys.argv[1]), Path(sys.argv[2])
    text, _ = repair(source.read_text())
    destination.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
