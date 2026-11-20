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

"""Generate directed WFI traces and check the DUT's wait and retirement."""

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from testrig.mmu import (
    CODE_ENTRY,
    CSRS,
    MRET,
    MTVEC_BASE,
    Instruction,
    Strand,
    _i_type,
    alu_imm,
    csrr,
    load_u64,
    render,
    trace_digest,
)
from testrig.rvfi_dii import MODE_MACHINE, MODE_SUPERVISOR, MODE_USER, WFI_INSN

DUT_TIMEOUT_CYCLES = 4096
# The fixture's mtime starts at zero and advances each cycle. Allow setup to
# finish before STIP pends and leave room for the timer to beat the timeout.
TIMER_COMPARE = 2048
SSIP = 1 << 1
STIP = 1 << 5
PENDING_MASK = {0: 0, SSIP: 1, STIP: 2}  # csr_s_pending order is SEIP, STIP, SSIP.
COUNTERS = (
    "wait_entries",
    "source_wakes",
    "timeout_wakes",
    "retired_after_wake",
    "commit_while_waiting",
    "pending",
)


@dataclass(frozen=True)
class WfiStrand:
    """One WFI and its expected DUT-side observations after reset."""

    name: str
    instructions: list[Instruction]
    target_index: int
    mode: int
    trap: bool
    expect_wait: bool
    pending: int

    @property
    def digest(self) -> str:
        """Identify the instructions independently of trace file order."""
        return trace_digest([inst.word for inst in self.instructions])


def _write_csr(name: str, value: int) -> list[Instruction]:
    addresses = CSRS | {
        "mideleg": 0x303,
        "mie": 0x304,
        "menvcfg": 0x30A,
        "mip": 0x344,
        "stimecmp": 0x14D,
    }
    return [
        *load_u64(5, value),
        Instruction(_i_type(0x73, 1, 0, 5, addresses[name]), f"csrw {name}, x5"),
    ]


def _strand(
    name: str,
    mode: int,
    *,
    expect_wait: bool,
    tw: bool = False,
    source: int = 0,
    enabled: bool = False,
) -> WfiStrand:
    trap = mode == MODE_USER or (mode == MODE_SUPERVISOR and tw)
    # Setting just MPP and TW keeps MIE, MPIE and SIE clear.
    words = _write_csr("mstatus", (mode << 11) | (int(tw) << 21))
    if source:
        # A delegated S interrupt is masked by SIE while executing in S.
        words += _write_csr("mideleg", source)
        words += _write_csr("mie", source if enabled else 0)
        if source == SSIP:
            words += _write_csr("mip", SSIP)
        else:
            words += _write_csr("menvcfg", 1 << 63)  # STCE
            words += _write_csr("stimecmp", TIMER_COMPARE)
    if trap:
        words += _write_csr("mtvec", MTVEC_BASE)
    if mode != MODE_MACHINE:
        words += [*_write_csr("mepc", CODE_ENTRY), MRET]

    target_index = len(words)
    words.append(Instruction(WFI_INSN, "wfi"))
    if trap:
        words += [csrr(10, "mcause"), csrr(11, "mepc"), csrr(12, "mtval")]
    else:
        words += [alu_imm("addi", 10, 0, 19), alu_imm("addi", 11, 10, 23)]
    return WfiStrand(
        name, words, target_index, mode, trap, expect_wait, PENDING_MASK[source]
    )


def write_tests(directory: Path) -> tuple[WfiStrand, ...]:
    """Write one non-shrinkable trace per directed WFI case."""
    strands = (
        _strand("m-timeout", MODE_MACHINE, expect_wait=True),
        _strand("m-tw-timeout", MODE_MACHINE, tw=True, expect_wait=True),
        _strand("s-timeout", MODE_SUPERVISOR, expect_wait=True),
        _strand(
            "s-ssip-enabled",
            MODE_SUPERVISOR,
            source=SSIP,
            enabled=True,
            expect_wait=False,
        ),
        _strand("s-ssip-masked", MODE_SUPERVISOR, source=SSIP, expect_wait=False),
        _strand(
            "s-stip-wake", MODE_SUPERVISOR, source=STIP, enabled=True, expect_wait=True
        ),
        _strand("s-tw-trap", MODE_SUPERVISOR, tw=True, expect_wait=False),
        _strand("u-trap", MODE_USER, expect_wait=False),
        _strand("u-tw-trap", MODE_USER, tw=True, expect_wait=False),
    )
    directory.mkdir(parents=True, exist_ok=True)
    for strand in strands:
        (directory / f"{strand.name}.S").write_text(
            render(
                [Strand(noshrink=True, instructions=strand.instructions)], [strand.name]
            ),
            encoding="utf-8",
        )
    return strands


def verify(strand: WfiStrand, observation: dict[str, Any]) -> list[str]:
    """Check the wait, wake, and RVFI facts for a single WFI trace."""
    if not observation:
        return ["missing DUT observations"]
    observed = observation.get("wfi", {})
    expected = {
        "wait_entries": int(strand.expect_wait),
        "source_wakes": int(strand.expect_wait and strand.pending != 0),
        "timeout_wakes": int(strand.expect_wait and strand.pending == 0),
        "retired_after_wake": int(strand.expect_wait),
        "commit_while_waiting": 0,
        "pending": strand.pending,
    }
    errors = [
        f"{key} expected {value}, got {observed.get(key)}"
        for key, value in expected.items()
        if observed.get(key) != value
    ]
    records = observation["records"]
    if len(records) != len(strand.instructions):
        errors.append(
            f"expected {len(strand.instructions)} RVFI records, got {len(records)}"
        )
        return errors
    index = strand.target_index
    expected_traps = [index] if strand.trap else []
    traps = [i for i, record in enumerate(records) if record[1]]
    if records[index][0] != strand.mode or traps != expected_traps:
        errors.append(
            f"expected WFI mode {strand.mode} and trap indices {expected_traps}, "
            f"got mode {records[index][0]} and trap indices {traps}"
        )
    if strand.trap:
        following = [
            [MODE_MACHINE, 0, 10, 2],
            [MODE_MACHINE, 0, 11, CODE_ENTRY],
            [MODE_MACHINE, 0, 12, WFI_INSN],
        ]
    else:
        following = [[strand.mode, 0, 10, 19], [strand.mode, 0, 11, 42]]
    if records[index + 1 :] != following:
        errors.append(
            f"expected post-WFI RVFI records {following}, got {records[index + 1 :]}"
        )
    return errors
