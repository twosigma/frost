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

"""Retired instruction evidence, separate from the aggregate calibration contract.

Observe the production core, not the TestRIG instruction-injection platform.
Decoded packets are saved by allocation tag and checked against retirement.
An architectural shadow register file follows *both* retirement slots from
the beginning of the run, resolving addresses before applying each writeback.
Only the calibration window is written. No RTL cycle durations are replay inputs.
"""

from __future__ import annotations

import gzip
import hashlib
import json
import struct
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import Any

from cocotb_tests.cpu_structs import (
    COMMIT_FIELDS,
    ID_TO_EX_FIELDS,
    PD_TO_ID_FIELDS,
    ROB_ALLOC_REQ_FIELDS,
    ROB_TAG_WIDTH,
)

SCHEMA = "frost-instructions-v1"
MASK64 = (1 << 64) - 1


def fields(layout: list[tuple[str, int]], value: int) -> dict[str, int]:
    """Unpack an MSB-first RTL packet, using the shared checked layouts."""
    result = {}
    for name, width in reversed(layout):
        result[name] = value & ((1 << width) - 1)
        value >>= width
    return result


def elf_segments(path: Path) -> list[tuple[int, bytes]]:
    """Read executable bytes from the ELF64 little-endian PT_LOAD segments."""
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("instruction capture requires a little-endian ELF64 binary")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    segments = []
    for index in range(count):
        typ, flags, pos, va, _, length, _, _ = struct.unpack_from(
            "<IIQQQQQQ", data, offset + size * index
        )
        if typ == 1 and flags & 1:
            segments.append((va, data[pos : pos + length]))
    if not segments:
        raise ValueError("ELF has no executable load segment")
    return segments


class InstructionTrace:
    """Capture a complete window, with binary and predictor provenance."""

    def __init__(
        self, dut: Any, path: Path, program: Path, identity: dict[str, Any]
    ) -> None:
        """Bind a small, explicit set of signals; fail on absent visibility."""
        from cocotb_tests.calibration_trace import CORE_PATH, _signal

        self.path = path
        self.identity = identity
        self.segments = elf_segments(program / "sw.elf")
        self.identity["artifacts"] = {
            f"{name}_sha256": hashlib.sha256((program / name).read_bytes()).hexdigest()
            for name in ("sw.elf", "sw.bin")
        }
        self.handles: dict[str, Any] = {}
        names = [
            "flush_pipeline",
            "pd_redirect",
            "pd_redirect_slot2",
            "pd_redirect_taken",
            "pd_redirect_target",
            "from_pd_to_id",
            "from_pd_to_id_2",
            "pd_stage_inst.pd_itt_redirect_r",
            "pd_stage_inst.pd_itt_redirect_2_r",
            "pd_stage_inst.pd_backing_redirect_r",
            "pd_stage_inst.pd_backing_redirect_2_r",
        ]
        for suffix in ("", "_2"):
            names += [
                f"from_id_to_ex{suffix}",
                f"rob_alloc_req{suffix}",
                f"rob_alloc_resp{suffix}",
                f"rob_commit_comb{suffix}",
            ]
        for name in names:
            handle = _signal(dut, f"{CORE_PATH}.{name}")
            if handle is None:
                raise AssertionError(f"instruction capture needs {CORE_PATH}.{name}")
            self.handles[name] = handle
        for name, layout in (
            ("rob_commit_comb", COMMIT_FIELDS),
            ("from_id_to_ex", ID_TO_EX_FIELDS),
            ("rob_alloc_req", ROB_ALLOC_REQ_FIELDS),
            ("from_pd_to_id", PD_TO_ID_FIELDS),
        ):
            for suffix in ("", "_2"):
                if len(self.handles[name + suffix]) != sum(w for _, w in layout):
                    raise AssertionError(
                        f"instruction capture: layout mismatch: {name}{suffix}"
                    )
        self.registers = {0: 0}
        self.allocated: dict[int, dict[str, Any]] = {}
        self.pending_pd: dict[int, deque[dict[str, Any]]] = defaultdict(deque)
        self.count = 0
        self.tiers: Counter[str] = Counter()
        self.file: Any = None
        self.closed = False

    def read(self, name: str) -> int:
        """Require a resolvable value; zero is meaningful."""
        return int(self.handles[name].value)

    def sample(self, active: bool) -> None:
        """Follow retirement before tag reuse, then PD redirects and allocation."""
        if self.closed:
            return
        if active and self.file is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.file = gzip.open(self.path, "wt", encoding="utf-8", compresslevel=6)
            self.write({"schema": SCHEMA, **self.identity})
        for suffix in ("", "_2"):
            commit = fields(COMMIT_FIELDS, self.read(f"rob_commit_comb{suffix}"))
            if commit["valid"]:
                self.retire(commit, active)
        if self.read("flush_pipeline"):
            # This flush kills ID and the decoded queue. Older ROB entries
            # survive partial recovery; their tag annotations remain intact.
            self.pending_pd.clear()
        elif self.read("pd_redirect"):
            suffix = "_2" if self.read("pd_redirect_slot2") else ""
            pd_packet = fields(PD_TO_ID_FIELDS, self.read(f"from_pd_to_id{suffix}"))
            slot_suffix = "_2_r" if suffix else "_r"
            tier = "pd_direction"
            if self.read(f"pd_stage_inst.pd_itt_redirect{slot_suffix}"):
                tier = "pd_ittage"
            elif self.read(f"pd_stage_inst.pd_backing_redirect{slot_suffix}"):
                tier = "pd_backing"
            self.pending_pd[pd_packet["program_counter"]].append(
                {
                    "f0_taken": bool(pd_packet["btb_predicted_taken"]),
                    "f0_target": pd_packet["btb_predicted_target"],
                    "pd_tier": tier,
                    "pd_taken": bool(self.read("pd_redirect_taken")),
                    "pd_target": self.read("pd_redirect_target"),
                }
            )
        for suffix in ("", "_2"):
            request = fields(ROB_ALLOC_REQ_FIELDS, self.read(f"rob_alloc_req{suffix}"))
            response = self.read(f"rob_alloc_resp{suffix}")
            if not request["alloc_valid"] or not (response >> (ROB_TAG_WIDTH + 1)):
                continue
            tag = (response >> 1) & ((1 << ROB_TAG_WIDTH) - 1)
            packet: dict[str, Any] = fields(
                ID_TO_EX_FIELDS, self.read(f"from_id_to_ex{suffix}")
            )
            pc = packet["program_counter"]
            prediction = {
                "f0_taken": bool(packet["btb_predicted_taken"]),
                "f0_target": packet["btb_predicted_target"],
                "pd_tier": "none",
                "pd_taken": bool(packet["btb_predicted_taken"]),
                "pd_target": packet["btb_predicted_target"],
            }
            if packet["is_branch_or_jump"] and self.pending_pd[pc]:
                prediction = self.pending_pd[pc].popleft()
                if prediction["pd_taken"] != bool(packet["btb_predicted_taken"]) or (
                    prediction["pd_taken"]
                    and prediction["pd_target"] != packet["btb_predicted_target"]
                ):
                    raise AssertionError(
                        "instruction capture: PD annotation differs from allocated prediction"
                    )
            packet["prediction"] = prediction
            self.allocated[tag] = packet

    def retire(self, commit: dict[str, int], active: bool) -> None:
        """Resolve operands from the architectural state immediately before commit."""
        packet = self.allocated.pop(commit["tag"], None)
        if packet is None or packet["program_counter"] != commit["pc"]:
            raise AssertionError(
                "instruction capture: retirement has no matching allocation"
            )
        if active:
            if (
                commit["exception"]
                or packet["is_fp_instruction"]
                or packet["is_amo_instruction"]
            ):
                raise AssertionError(
                    "instruction capture supports nontrapping integer instructions"
                )
            insn = packet["instruction"]
            raw = packet["insn_bits"]
            length = 2 if packet["is_compressed"] else 4
            raw &= (1 << (8 * length)) - 1
            encoded = raw.to_bytes(length, "little")
            pc = commit["pc"]
            if not any(
                base <= pc and data[pc - base : pc - base + length] == encoded
                for base, data in self.segments
            ):
                raise AssertionError(f"instruction capture: binary mismatch at {pc:#x}")
            sources = []
            for used, shift in (("uses_int_rs1", 15), ("uses_int_rs2", 20)):
                reg = (insn >> shift) & 31
                if packet[used] and reg not in sources:
                    sources.append(reg)
            destination = (insn >> 7) & 31 if packet["has_int_dest"] else None
            if destination and (
                not commit["dest_valid"]
                or commit["dest_rf"]
                or commit["dest_reg"] != destination
            ):
                raise AssertionError(
                    "instruction capture: destination differs at retirement"
                )
            kind = "alu"
            address = None
            if packet["is_load_instruction"] or packet["is_int_store"]:
                kind = "load" if packet["is_load_instruction"] else "store"
                base_reg = (insn >> 15) & 31
                if base_reg not in self.registers:
                    raise AssertionError(
                        f"instruction capture: unknown address register x{base_reg}"
                    )
                immediate = packet[
                    "immediate_i_type" if kind == "load" else "immediate_s_type"
                ]
                address = (self.registers[base_reg] + immediate) & MASK64
            elif packet["is_branch_or_jump"]:
                kind = "branch"
            prediction = packet["prediction"] if kind == "branch" else None
            taken = bool(commit["branch_taken"]) if kind == "branch" else False
            next_pc = commit["branch_target"] if taken else pc + length
            if prediction is not None:
                predicted_pc = (
                    prediction["pd_target"] if prediction["pd_taken"] else pc + length
                )
                prediction["execute_redirect"] = predicted_pc != next_pc
                self.tiers[
                    "execute"
                    if prediction["execute_redirect"]
                    else prediction["pd_tier"]
                    if prediction["pd_tier"] != "none"
                    else "f0"
                    if prediction["f0_taken"]
                    else "sequential"
                ] += 1
            self.write(
                {
                    "id": self.count,
                    "pc": pc,
                    "bytes": encoded.hex(),
                    "length": length,
                    "instruction": insn,
                    "kind": kind,
                    "sources": sources,
                    "destination": destination,
                    "address": address,
                    "memory_bytes": (1 << ((insn >> 12) & 3))
                    if address is not None
                    else 0,
                    "taken": taken,
                    "next_pc": next_pc,
                    "prediction": prediction,
                }
            )
            self.count += 1
        if commit["dest_valid"] and not commit["dest_rf"] and commit["dest_reg"]:
            self.registers[commit["dest_reg"]] = commit["value"] & MASK64

    def write(self, record: dict[str, Any]) -> None:
        """Keep repetitive records compact before compression too."""
        self.file.write(json.dumps(record, separators=(",", ":")) + "\n")

    def finish(self, expected_count: int) -> dict[str, Any]:
        """Seal the stream and return the manifest's identity checks."""
        if self.count != expected_count or self.file is None:
            raise AssertionError(
                "instruction capture and aggregate retirement count differ"
            )
        self.write(
            {
                "end": True,
                "instructions": self.count,
                "prediction_tiers": dict(self.tiers),
            }
        )
        self.file.close()
        self.closed = True
        return {
            "schema": SCHEMA,
            "path": str(self.path),
            "instructions": self.count,
            "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
            "compressed_bytes": self.path.stat().st_size,
            "prediction_tiers": dict(self.tiers),
        }
