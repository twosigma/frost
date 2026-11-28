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

"""Versioned instruction evidence. Aggregate event traces are never instructions."""

from __future__ import annotations

import gzip
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA = "frost-instructions-v1"
PD_TIERS = {"none", "pd_direction", "pd_backing", "pd_ittage"}


def integer(value: Any, name: str, maximum: int = (1 << 64) - 1) -> int:
    """Reject lossy coercions and out-of-range encodings."""
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(f"invalid {name}: {value!r}")
    return value


@dataclass(frozen=True)
class Prediction:
    """Recorded F0 and PD decisions; execution recovery follows their error."""

    f0_taken: bool
    f0_target: int
    pd_tier: str
    pd_taken: bool
    pd_target: int
    execute_redirect: bool


@dataclass(frozen=True)
class Instruction:
    """One dynamic architectural instruction and its resolved dependency graph."""

    index: int
    pc: int
    raw: bytes
    instruction: int
    kind: str
    sources: tuple[int, ...]
    destination: int | None
    address: int | None
    memory_bytes: int
    taken: bool
    next_pc: int
    prediction: Prediction | None
    depends_on: tuple[int, ...]

    @property
    def length(self) -> int:
        """Number of bytes, including compressed encodings."""
        return len(self.raw)

    @property
    def serializing(self) -> bool:
        """The predecode sideband's native serialize predicate."""
        opcode = self.instruction & 127
        return opcode in {15, 47} or (
            opcode == 115 and (self.instruction >> 12) & 7 != 4
        )

    @property
    def allows_pair(self) -> bool:
        """Slot 1 control flow and serializing instructions end a bundle."""
        return self.kind != "branch" and not self.serializing


@dataclass
class InstructionStream:
    """Validated input plus its provenance and termination record."""

    metadata: dict[str, Any]
    instructions: list[Instruction]
    summary: dict[str, Any]
    sha256: str


def read_stream(
    path: Path, manifest: dict[str, Any] | None = None
) -> InstructionStream:
    """Read a sealed stream and, when supplied, require the same capture identity."""
    opener = gzip.open if path.suffix == ".gz" else open
    last_writer: dict[int, int] = {}
    program: list[Instruction] = []
    footer = None
    with opener(path, "rt", encoding="utf-8") as file:
        metadata = json.loads(file.readline())
        if metadata.get("schema") != SCHEMA:
            raise ValueError(
                "expected frost-instructions-v1, not aggregate calibration events"
            )
        for name in ("sw.elf_sha256", "sw.bin_sha256"):
            if not re.fullmatch(
                r"[0-9a-f]{64}", metadata.get("artifacts", {}).get(name, "")
            ):
                raise ValueError(f"missing binary identity: {name}")
        for line in file:
            row = json.loads(line)
            if footer is not None:
                raise ValueError("records after instruction stream footer")
            if row.get("end") is True:
                footer = row
                continue
            index = integer(row["id"], "id")
            if index != len(program):
                raise ValueError("instruction IDs must be consecutive from zero")
            pc = integer(row["pc"], "pc")
            if pc & 1 or program and program[-1].next_pc != pc:
                raise ValueError(
                    f"discontinuous instruction stream at {index}: {pc:#x}"
                )
            raw = bytes.fromhex(row["bytes"])
            if len(raw) not in (2, 4) or row["length"] != len(raw):
                raise ValueError("invalid instruction length")
            if (raw[0] & 3 == 3) != (len(raw) == 4):
                raise ValueError("instruction encoding and length disagree")
            insn = integer(row["instruction"], "expanded instruction", (1 << 32) - 1)
            if len(raw) == 4 and insn != int.from_bytes(raw, "little"):
                raise ValueError("native and expanded instruction disagree")
            kind = row["kind"]
            if kind not in {"alu", "load", "store", "branch"}:
                raise ValueError(f"unsupported instruction kind: {kind}")
            sources = tuple(integer(r, "source register", 31) for r in row["sources"])
            destination = row["destination"]
            if destination is not None:
                integer(destination, "destination register", 31)
            address = row["address"]
            size = row["memory_bytes"]
            if kind in {"load", "store"}:
                integer(address, "data address")
                if type(size) is not int or size not in {1, 2, 4, 8}:
                    raise ValueError("invalid memory size")
            elif address is not None or size != 0:
                raise ValueError("non-memory instruction has a data address")
            taken = row["taken"]
            if type(taken) is not bool:
                raise ValueError("branch outcome must be boolean")
            next_pc = integer(row["next_pc"], "next_pc")
            prediction = None
            if kind == "branch":
                prediction = Prediction(**row["prediction"])
                if prediction.pd_tier not in PD_TIERS:
                    raise ValueError("unknown prediction tier")
                for name in ("f0_taken", "pd_taken", "execute_redirect"):
                    if type(getattr(prediction, name)) is not bool:
                        raise ValueError("prediction decision must be boolean")
                integer(prediction.f0_target, "F0 target")
                integer(prediction.pd_target, "PD target")
                predicted_pc = (
                    prediction.pd_target if prediction.pd_taken else pc + len(raw)
                )
                if prediction.execute_redirect != (predicted_pc != next_pc):
                    raise ValueError("execution redirect disagrees with prediction")
                if prediction.pd_tier == "none" and (
                    prediction.f0_taken != prediction.pd_taken
                    or prediction.f0_taken
                    and prediction.f0_target != prediction.pd_target
                ):
                    raise ValueError("prediction changed without a PD redirect")
            elif taken or row["prediction"] is not None:
                raise ValueError("non-branch has branch evidence")
            if not taken and next_pc != pc + len(raw):
                raise ValueError("fall-through differs from instruction length")
            deps = tuple(
                sorted({last_writer[r] for r in sources if r in last_writer and r != 0})
            )
            program.append(
                Instruction(
                    index,
                    pc,
                    raw,
                    insn,
                    kind,
                    sources,
                    destination,
                    address,
                    size,
                    taken,
                    next_pc,
                    prediction,
                    deps,
                )
            )
            if destination:
                last_writer[destination] = index
    if footer is None or footer.get("instructions") != len(program) or not program:
        raise ValueError("missing or inconsistent instruction stream footer")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if manifest is not None:
        evidence = manifest["instruction_stream"]
        if evidence["sha256"] != digest or evidence["instructions"] != len(program):
            raise ValueError("instruction stream differs from capture manifest")
        for name, value in metadata["artifacts"].items():
            if manifest["artifacts"].get(name) != value:
                raise ValueError(
                    f"instruction binary differs from aggregate capture: {name}"
                )
        if (
            metadata["rtl_commit"] != manifest["git_commit"]
            or metadata["benchmark"] != manifest["benchmark"]
            or metadata["memory_tier"] != manifest["memory_configuration"]["tier"]
            or metadata["run_number"] != manifest["run_number"]
        ):
            raise ValueError("instruction run identity differs from aggregate capture")
        for name in ("start_pc", "stop_pc"):
            if metadata[name] != int(manifest["timed_region"][name], 0):
                raise ValueError("instruction window differs from aggregate capture")
    return InstructionStream(metadata, program, footer, digest)
