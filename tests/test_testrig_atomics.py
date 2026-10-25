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

"""Unit tests for the TestRIG A-extension test generator.

verif/testrig/atomics.py writes the tests that tests/test_testrig.py
--atomics replays on FROST and the Sail model. These check its encodings, its
memory map, and the rule that keeps FROST and Sail comparable: nothing that
can trap or flush falls between an LR and the SC that closes it.
"""

import importlib
import random
import re
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))
atomics = importlib.import_module("testrig.atomics")

# Words from the GNU assembler, and for branches and jumps from objdump's
# disassembly of the encoder's output.
GOLDEN = [
    (atomics.lr(5, 20, 4), 0x100A22AF),
    (atomics.lr(13, 26, 8, aq=1, rl=1), 0x160D36AF),
    (atomics.sc(2, 12, 29, 4, rl=1), 0x1ACEA12F),
    (atomics.sc(11, 15, 25, 8, aq=1), 0x1CFCB5AF),
    (atomics.amo("amoadd", 6, 7, 20, 4), 0x007A232F),
    (atomics.amo("amomaxu", 15, 17, 25, 8, aq=1, rl=1), 0xE71CB7AF),
    (atomics.amo("amoswap", 1, 2, 21, 4, aq=1), 0x0C2AA0AF),
    (atomics.load("ld", 5, 20, 64), 0x040A3283),
    (atomics.store("sd", 6, 21, 8), 0x006AB423),
    (atomics.store("sh", 7, 25, 2), 0x007C9123),
    (atomics.load("lbu", 8, 27, 71), 0x047DC403),
    (atomics.branch("beq", 1, 2, -64), 0xFC2080E3),
    (atomics.branch("bgeu", 3, 4, 62), 0x0241FF63),
    (atomics.jal(0, -2), 0xFFFFF06F),
    (atomics.jal(1, 2048), 0x001000EF),
    (atomics.jalr(1, 5, -64), 0xFC0280E7),
    (atomics.csr_read(9, "mcause"), 0x342024F3),
    (atomics.alu_imm("srai", 10, 11, 63), 0x43F5D513),
    (atomics.alu_imm("sraiw", 12, 13, 31), 0x41F6D61B),
    (atomics.lui(20, 0x80200), 0x80200A37),
    (atomics.FENCE, 0x0FF0000F),
    (atomics.FENCE_I, 0x0000100F),
    (atomics.SFENCE_VMA, 0x12000073),
    (atomics.ECALL, 0x00000073),
]

ATOMIC = re.compile(r"^(lr|sc|amo\w+)\.([wd])(?:\.\w+)? x\d+, (?:x\d+, )?\(x(\d+)\)$")
OFFSET = re.compile(r"^(\w+) x\d+, (-?\d+)\(x(\d+)\)$")
# Mnemonics that cannot trap or flush.
SAFE = set(atomics.ALU_IMM) | set(atomics.ALU_REG) | set(atomics.BRANCHES)
SAFE |= {"lui", "jal", "jalr", "fence"}


@pytest.mark.parametrize(("instruction", "word"), GOLDEN)
def test_encoding(instruction: Any, word: int) -> None:
    """Each encoder matches the assembler."""
    assert instruction.word == word, instruction.text


def test_regions_follow_the_memory_map() -> None:
    """The fixed addresses fall where the tests expect them."""
    regions = atomics.load_regions()

    def allowed(address: int, size: int) -> set[str]:
        kinds = ("load", "store", "amo", "lr", "sc")
        return {k for k in kinds if atomics.allows(regions, address, size, k)}

    every = {"load", "store", "amo", "lr", "sc"}
    assert allowed(atomics.DDR, 8) == every
    assert allowed(atomics.BRAM, 8) == every
    assert allowed(0, 8) == every
    assert allowed(atomics.DEVICE, 8) == {"load", "store"}
    assert allowed(atomics.QUADRANT, 8) == {"store"}
    assert allowed(atomics.UNMAPPED, 8) == set()
    assert allowed(atomics.DDR + 4, 8) == set()
    assert allowed(atomics.DDR + 4, 4) == every


@pytest.mark.parametrize(
    ("base", "size"),
    ((0x4000_0000, 0x31000), (0x4400_0000, 0x400000), (0x4800_0000, 0x200000)),
)
def test_device_windows(base: int, size: int) -> None:
    """Every MMIO, APLIC and IMSIC page admits only simple aligned accesses."""
    regions = atomics.load_regions()
    kinds = ("load", "store", "amo", "lr", "sc")
    for page in range(base, base + size, 4096):
        for width in (1, 2, 4, 8):
            for address in (page, page + 4096 - width):
                allowed = {
                    k for k in kinds if atomics.allows(regions, address, width, k)
                }
                assert allowed == {"load", "store"}, (hex(address), width)
                assert not atomics.allows(regions, address + (1 << 32), width, "load")

    for address in (base - 8, base + size):
        allowed = {k for k in kinds if atomics.allows(regions, address, 8, k)}
        expected = {"store"} if address >= 0x4000_0000 else set()
        assert allowed == expected, hex(address)


def _access(text: str, bases: dict[int, int]) -> tuple[int, int, str] | None:
    """Return a memory access's address, size, and kind, from its text."""
    match = ATOMIC.match(text)
    if match:
        name, width, base = match.groups()
        kind = name if name in ("lr", "sc") else "amo"
        return bases.get(int(base), 0), 8 if width == "d" else 4, kind
    match = OFFSET.match(text)
    if match and match.group(1) != "jalr":
        name, offset, base = match.groups()
        if name in atomics.LOADS:
            size, kind = atomics.LOADS[name][1], "load"
        else:
            size, kind = atomics.STORES[name][1], "store"
        return bases.get(int(base), 0) + int(offset), size, kind
    return None


@pytest.mark.parametrize("seed", range(8))
def test_windows_hold_no_trap_or_flush(seed: int) -> None:
    """Between an LR and its SC nothing can trap or flush, and any other LR faults."""
    regions = atomics.load_regions()
    generator = atomics.Generator(random.Random(seed), regions)
    windows = 0
    for _ in range(25):
        strands = generator.test(200)
        bases = generator.bases
        for strand in strands:
            texts = [inst.text for inst in strand.instructions]
            if strand.noshrink and texts[0].startswith("lr."):
                windows += 1
                assert texts[-1].startswith("sc.")
                assert not any(text.startswith("sc.") for text in texts[:-1])
                for text in texts:
                    access = _access(text, bases)
                    if access is None:
                        assert text.split()[0] in SAFE, text
                    else:
                        assert atomics.allows(regions, *access), text
            else:
                for text in texts:
                    access = _access(text, bases)
                    if access is not None and access[2] == "lr":
                        assert not atomics.allows(regions, *access), text
    assert windows > 100


def test_seed_repeats(tmp_path: Path) -> None:
    """The same seed writes the same tests."""
    first = atomics.write_tests(tmp_path / "a", 3, 1234, 150)
    second = atomics.write_tests(tmp_path / "b", 3, 1234, 150)
    for one, two in zip(first, second, strict=True):
        assert one.read_text() == two.read_text()


def test_trace_file_format(tmp_path: Path) -> None:
    """Strands open with .noshrink or .shrink, then one instruction per line."""
    (path,) = atomics.write_tests(tmp_path, 1, 7, 120)
    lines = [x for x in path.read_text().splitlines() if not x.startswith("#")]
    assert lines[0] == ".noshrink"
    words = 0
    for line in lines:
        if line in (".noshrink", ".shrink"):
            continue
        assert re.match(r"^\.4byte 0x[0-9a-f]{8} # \S", line), line
        words += 1
    assert words >= 120
