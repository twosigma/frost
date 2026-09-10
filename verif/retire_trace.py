# Copyright 2026 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Canonical FROST retirement trace and Spike differential checker.

FROST emits one record for every architectural retirement lane.  Spike's
``--log-commits`` stream is used as the independent ordering oracle.  The
comparison intentionally starts with retired PC/instruction ordering; optional
register-write annotations are compared when the Spike build provides them.
This avoids pretending that simulator timing or ROB ordering is architectural.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RetireRecord:
    """One architecturally retired instruction."""

    pc: int
    insn: int | None = None
    rf: str = "I"
    rd: int = 0
    rd_valid: bool = False
    value: int = 0
    store: bool = False
    branch: bool = False
    taken: bool = False
    exception: bool = False
    compressed: bool = False
    time: int | None = None
    slot: int | None = None


_FROST_FIELD_RE = re.compile(r"(?P<key>[A-Za-z_]+)=(?P<value>[^\s]+)")
_SPIKE_PC_RE = re.compile(
    r"core\s+\d+:\s+(?:\d+\s+)?(?P<pc>0x[0-9a-fA-F]+)\s+"
    r"\((?P<insn>0x[0-9a-fA-F]+)\)"
)
# A few Spike-derived loggers append writes as x5=0x... / f5=0x....
_WRITE_RE = re.compile(r"\b(?P<rf>[xf])(?P<rd>\d+)=(?P<value>0x[0-9a-fA-F]+)\b")


def _parse_int(value: str) -> int:
    """Parse decimal or hexadecimal text."""
    return int(value, 0)


def parse_frost_trace(path: Path) -> list[RetireRecord]:
    """Parse the key=value trace emitted by the FROST ROB."""
    records: list[RetireRecord] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        fields = {m.group("key"): m.group("value") for m in _FROST_FIELD_RE.finditer(line)}
        if "pc" not in fields or "slot" not in fields:
            raise ValueError(f"{path}:{line_number}: malformed retirement record")
        records.append(
            RetireRecord(
                pc=int(fields["pc"], 16),
                rf=fields.get("rf", "I"),
                rd=int(fields.get("rd", "0")),
                rd_valid=bool(int(fields.get("rd_valid", "0"))),
                value=int(fields.get("val", "0"), 16),
                store=bool(int(fields.get("store", "0"))),
                branch=bool(int(fields.get("branch", "0"))),
                taken=bool(int(fields.get("taken", "0"))),
                exception=bool(int(fields.get("exc", "0"))),
                compressed=bool(int(fields.get("compressed", "0"))),
                time=int(fields["time"]) if "time" in fields else None,
                slot=int(fields["slot"]),
            )
        )
    return records


def parse_spike_log(path: Path) -> list[RetireRecord]:
    """Parse Spike's ``--log-commits`` instruction stream."""
    records: list[RetireRecord] = []
    for line in path.read_text().splitlines():
        match = _SPIKE_PC_RE.search(line)
        if match is None:
            continue
        insn = int(match.group("insn"), 16)
        write = _WRITE_RE.search(line)
        records.append(
            RetireRecord(
                pc=int(match.group("pc"), 16),
                insn=insn,
                rf=write.group("rf").upper() if write else "I",
                rd=int(write.group("rd")) if write else 0,
                rd_valid=write is not None and int(write.group("rd")) != 0,
                value=int(write.group("value"), 16) if write else 0,
                compressed=(insn & 0x3) != 0x3,
            )
        )
    if not records:
        raise ValueError(f"{path}: no Spike commit records found")
    return records


def compare_traces(
    frost: list[RetireRecord],
    spike: list[RetireRecord],
    *,
    max_records: int | None = None,
) -> str | None:
    """Return the first mismatch, or None when the compared traces agree."""
    limit = min(len(frost), len(spike))
    if max_records is not None:
        limit = min(limit, max_records)

    for index in range(limit):
        left = frost[index]
        right = spike[index]
        if left.pc != right.pc:
            return _mismatch(index, left, right, "pc")
        if left.insn is not None and right.insn is not None and left.insn != right.insn:
            return _mismatch(index, left, right, "instruction")
        # Only compare register writes when Spike actually supplied them.
        if right.rd_valid:
            if left.rf != right.rf or not left.rd_valid or left.rd != right.rd:
                return _mismatch(index, left, right, "destination")
            if left.value != right.value:
                return _mismatch(index, left, right, "value")

    if max_records is None and len(frost) != len(spike):
        return f"length mismatch: FROST={len(frost)} Spike={len(spike)}"
    return None


def _mismatch(index: int, frost: RetireRecord, spike: RetireRecord, field: str) -> str:
    """Format a first-difference report with enough context to debug it."""
    return (
        f"retirement mismatch at index {index} ({field})\n"
        f"  FROST: pc=0x{frost.pc:016x} rf={frost.rf} rd={frost.rd} "
        f"valid={int(frost.rd_valid)} value=0x{frost.value:016x}\n"
        f"  Spike: pc=0x{spike.pc:016x} rf={spike.rf} rd={spike.rd} "
        f"valid={int(spike.rd_valid)} value=0x{spike.value:016x}"
    )


def main() -> int:
    """Run the FROST-vs-Spike differential checker."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frost_trace", type=Path)
    parser.add_argument("spike_trace", type=Path)
    parser.add_argument("--max-records", type=int, default=None)
    args = parser.parse_args()

    frost = parse_frost_trace(args.frost_trace)
    spike = parse_spike_log(args.spike_trace)
    mismatch = compare_traces(frost, spike, max_records=args.max_records)
    if mismatch:
        print(mismatch)
        return 1
    print(f"retirement traces match: {len(frost)} records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
