#!/usr/bin/env python3
# Copyright 2026 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

"""Profile dynamically executed macro-op fusion opportunities.

The FROST retirement trace establishes architectural retirement order while
Spike's commit log supplies instruction encodings.  Combining the two avoids
requiring the RTL retirement record to carry a second copy of the instruction
word just for profiling.

The profiler intentionally models the conservative detector in
``macro_op_fusion.sv``.  It counts only *adjacent, successfully retired*
instruction pairs, so loops are weighted by execution frequency and dead code
is naturally excluded.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import importlib.util
import sys


_TRACE_MODULE_PATH = Path(__file__).resolve().parents[1] / "verif" / "retire_trace.py"
_TRACE_SPEC = importlib.util.spec_from_file_location("frost_retire_trace", _TRACE_MODULE_PATH)
if _TRACE_SPEC is None or _TRACE_SPEC.loader is None:
    raise ImportError(f"unable to load retirement trace parser: {_TRACE_MODULE_PATH}")
_TRACE_MODULE = importlib.util.module_from_spec(_TRACE_SPEC)
sys.modules[_TRACE_SPEC.name] = _TRACE_MODULE
_TRACE_SPEC.loader.exec_module(_TRACE_MODULE)
RetireRecord = _TRACE_MODULE.RetireRecord
parse_frost_trace = _TRACE_MODULE.parse_frost_trace
parse_spike_log = _TRACE_MODULE.parse_spike_log


FUSE_NONE = "NONE"
FUSE_LUI_ADDI = "LUI_ADDI"
FUSE_AUIPC_JALR = "AUIPC_JALR"
FUSE_LUI_JALR = "LUI_JALR"


def opcode(insn: int) -> int:
    return insn & 0x7F


def rd(insn: int) -> int:
    return (insn >> 7) & 0x1F


def rs1(insn: int) -> int:
    return (insn >> 15) & 0x1F


def is_lui(insn: int) -> bool:
    return opcode(insn) == 0x37


def is_auipc(insn: int) -> bool:
    return opcode(insn) == 0x17


def is_addi(insn: int) -> bool:
    return opcode(insn) == 0x13 and ((insn >> 12) & 0x7) == 0


def is_jalr(insn: int) -> bool:
    return opcode(insn) == 0x67 and ((insn >> 12) & 0x7) == 0


def classify_pair(first: int, second: int) -> str:
    """Return the conservative FROST fusion class for an instruction pair."""
    producer_rd = rd(first)
    consumer_rs1 = rs1(second)
    consumer_rd = rd(second)

    if producer_rd == 0 or consumer_rs1 != producer_rd:
        return FUSE_NONE

    if is_lui(first) and is_addi(second) and consumer_rd == producer_rd:
        return FUSE_LUI_ADDI
    if is_auipc(first) and is_jalr(second):
        return FUSE_AUIPC_JALR
    if is_lui(first) and is_jalr(second):
        return FUSE_LUI_JALR
    return FUSE_NONE


@dataclass(frozen=True)
class FusionProfile:
    retired: int
    adjacent_pairs: int
    candidates: int
    candidate_rate: float
    lui_addi: int
    auipc_jalr: int
    lui_jalr: int
    lui_addi_rate: float
    auipc_jalr_rate: float
    lui_jalr_rate: float

    def to_dict(self) -> dict[str, int | float]:
        return asdict(self)


def profile(frost: list[RetireRecord], spike: list[RetireRecord]) -> FusionProfile:
    """Profile adjacent dynamic retirement pairs after validating alignment."""
    if len(frost) != len(spike):
        raise ValueError(
            f"trace length mismatch: FROST={len(frost)} Spike={len(spike)}"
        )

    for index, (frost_rec, spike_rec) in enumerate(zip(frost, spike)):
        if frost_rec.pc != spike_rec.pc:
            raise ValueError(
                f"trace divergence at index {index}: "
                f"FROST PC=0x{frost_rec.pc:x}, Spike PC=0x{spike_rec.pc:x}"
            )
        if spike_rec.insn is None:
            raise ValueError(f"Spike record {index} has no instruction encoding")

    counts = {
        FUSE_LUI_ADDI: 0,
        FUSE_AUIPC_JALR: 0,
        FUSE_LUI_JALR: 0,
    }
    for left, right in zip(spike, spike[1:]):
        kind = classify_pair(left.insn, right.insn)  # type: ignore[arg-type]
        if kind != FUSE_NONE:
            counts[kind] += 1

    retired = len(spike)
    adjacent = max(0, retired - 1)
    candidates = sum(counts.values())
    denominator = adjacent or 1
    return FusionProfile(
        retired=retired,
        adjacent_pairs=adjacent,
        candidates=candidates,
        candidate_rate=candidates / denominator,
        lui_addi=counts[FUSE_LUI_ADDI],
        auipc_jalr=counts[FUSE_AUIPC_JALR],
        lui_jalr=counts[FUSE_LUI_JALR],
        lui_addi_rate=counts[FUSE_LUI_ADDI] / denominator,
        auipc_jalr_rate=counts[FUSE_AUIPC_JALR] / denominator,
        lui_jalr_rate=counts[FUSE_LUI_JALR] / denominator,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frost_trace", type=Path)
    parser.add_argument("spike_trace", type=Path)
    parser.add_argument("--json", dest="json_path", type=Path)
    args = parser.parse_args()

    result = profile(parse_frost_trace(args.frost_trace), parse_spike_log(args.spike_trace))
    print(f"retired instructions : {result.retired}")
    print(f"adjacent pairs       : {result.adjacent_pairs}")
    print(f"fusion candidates    : {result.candidates}")
    print(f"candidate rate       : {result.candidate_rate:.4%}")
    print(f"LUI+ADDI             : {result.lui_addi} ({result.lui_addi_rate:.4%})")
    print(f"AUIPC+JALR           : {result.auipc_jalr} ({result.auipc_jalr_rate:.4%})")
    print(f"LUI+JALR             : {result.lui_jalr} ({result.lui_jalr_rate:.4%})")

    if args.json_path:
        args.json_path.write_text(json.dumps(result.to_dict(), indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
