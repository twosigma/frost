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

"""RTL-vs-python cross-check for predecode sideband generation.

The DUT is imem_predecode_line: riscv_pkg::imem_make_sideband applied to
every 32-bit word of a cache line, the exact structure the L1I fill path
uses. The golden model is sw/common/generate_imem_predecode_init.py --
the offline generator that produces the Vivado power-up sideband images --
imported directly so the two predecode definitions can never drift apart
silently. Any mismatch here means low-BRAM code (python-generated or
write-time sideband) and DDR code (fill-time sideband) would predecode
differently.
"""

import importlib.util
import random
from pathlib import Path
from types import ModuleType
from typing import Any

import cocotb
from cocotb.triggers import Timer

LINE_BYTES = 32
WORDS_PER_LINE = LINE_BYTES // 4

# Native opcodes with sideband significance (and near-misses that share
# most bits with them), from the generator/riscv_pkg definitions.
OPC_MISC_MEM = 0b0001111
OPC_CSR = 0b1110011
OPC_AMO = 0b0101111
OPC_FMADD = 0b1000011
OPC_FMSUB = 0b1000111
OPC_FNMSUB = 0b1001011
OPC_FNMADD = 0b1001111
OPC_OP_FP = 0b1010011
SPECIAL_OPCODES = (
    OPC_MISC_MEM,
    OPC_CSR,
    OPC_AMO,
    OPC_FMADD,
    OPC_FMSUB,
    OPC_FNMSUB,
    OPC_FNMADD,
    OPC_OP_FP,
)
NEAR_MISS_OPCODES = (
    0b0000011,  # LOAD (one bit from MISC_MEM)
    0b0001011,  # custom-0 (one bit from MISC_MEM/AMO)
    0b0110011,  # OP
    0b1110111,  # one bit from CSR
    0b1010111,  # one bit from OP_FP (V-extension space)
    0b1000001,  # non-11 low bits next to FMADD
)


def _load_generator() -> ModuleType:
    """Import sw/common/generate_imem_predecode_init.py as the golden model."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw"
        / "common"
        / "generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("generate_imem_predecode_init", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GENERATOR = _load_generator()
SIDEBAND_WIDTH = _GENERATOR.SIDEBAND_WIDTH


def _assert_pc_bundle_bits(word: int, sideband: int) -> None:
    """Independently check the four write/init-time PC qualifier fields."""
    lo = word & 0xFFFF
    hi = (word >> 16) & 0xFFFF
    compressed_lo = (lo & 0x3) != 0b11
    compressed_hi = (hi & 0x3) != 0b11
    serialize_lo = _GENERATOR.native_serialize(lo & 0x7F)
    serialize_hi = _GENERATOR.native_serialize(hi & 0x7F)
    allows_lo = (compressed_lo and not _GENERATOR.compressed_control(lo)) or (
        not compressed_lo
        and not _GENERATOR.native_control(lo & 0x7F)
        and not serialize_lo
    )
    allows_hi = (compressed_hi and not _GENERATOR.compressed_control(hi)) or (
        not compressed_hi
        and not _GENERATOR.native_control(hi & 0x7F)
        and not serialize_hi
    )
    start_valid_hi = compressed_hi or not (
        serialize_hi or _GENERATOR.native_fp_compute(hi & 0x7F)
    )
    expected = {
        _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID: (
            compressed_lo and allows_lo and start_valid_hi
        ),
        _GENERATOR.SB_PAIRABLE_NATIVE_LO: not compressed_lo and allows_lo,
        _GENERATOR.SB_PAIRABLE_COMPRESSED_HI: compressed_hi and allows_hi,
        _GENERATOR.SB_PAIRABLE_NATIVE_HI: not compressed_hi and allows_hi,
    }
    for bit, want in expected.items():
        assert bool(sideband & (1 << bit)) is want, (
            f"word 0x{word:08x}: PC sideband bit {bit} "
            f"is {bool(sideband & (1 << bit))}, want {want}"
        )


async def _check_line(dut: Any, words: list[int]) -> None:
    """Drive one line and compare every word's sideband value to the model."""
    assert len(words) == WORDS_PER_LINE
    line = 0
    for i, word in enumerate(words):
        line |= (word & 0xFFFF_FFFF) << (32 * i)
    dut.i_line.value = line
    await Timer(1, unit="ns")
    sideband = int(dut.o_sideband.value)
    for i, word in enumerate(words):
        mask = (1 << SIDEBAND_WIDTH) - 1
        got = (sideband >> (SIDEBAND_WIDTH * i)) & mask
        expected = _GENERATOR.make_sideband(word)
        hex_digits = (SIDEBAND_WIDTH + 3) // 4
        assert got == expected, (
            f"word {i} (0x{word:08x}): "
            f"rtl sideband 0x{got:0{hex_digits}x} "
            f"!= generator 0x{expected:0{hex_digits}x}"
        )
        _assert_pc_bundle_bits(word, got)


async def _check_words(dut: Any, words: list[int]) -> None:
    """Check an arbitrary word list, zero-padded to whole lines."""
    padded = words + [0] * (-len(words) % WORDS_PER_LINE)
    for base in range(0, len(padded), WORDS_PER_LINE):
        await _check_line(dut, padded[base : base + WORDS_PER_LINE])


def _rvc_quadrant_01(funct3: int, middle: int) -> int:
    """Build a quadrant-01 parcel from funct3 and the middle payload bits."""
    return ((funct3 & 0x7) << 13) | ((middle & 0x7FF) << 2) | 0b01


def _rvc_quadrant_10(funct4: int, rs1: int, rs2: int) -> int:
    """Build a quadrant-10 parcel from explicit funct4/rs1/rs2 fields."""
    return ((funct4 & 0xF) << 12) | ((rs1 & 0x1F) << 7) | ((rs2 & 0x1F) << 2) | 0b10


@cocotb.test()
async def test_directed_encodings(dut: Any) -> None:
    """Every sideband-relevant encoding class, in both halfword positions."""
    parcels: list[int] = [
        0x0000,  # all zeros (illegal, but compressed quadrant 00)
        0xFFFF,  # quadrant 11 (looks like a 32-bit instruction start)
        # Quadrant-01 control flow: C.JAL, C.J, C.BEQZ, C.BNEZ.
        _rvc_quadrant_01(0b001, 0x2A5),
        _rvc_quadrant_01(0b101, 0x0FF),
        _rvc_quadrant_01(0b110, 0x31C),
        _rvc_quadrant_01(0b111, 0x123),
        # Quadrant-01 non-control neighbours: C.ADDI, C.LI, C.LUI, srl-group.
        _rvc_quadrant_01(0b000, 0x2A5),
        _rvc_quadrant_01(0b010, 0x0FF),
        _rvc_quadrant_01(0b011, 0x31C),
        _rvc_quadrant_01(0b100, 0x123),
        # Quadrant-10 control flow: C.JR / C.JALR (rs2=0, rs1!=0)...
        _rvc_quadrant_10(0b1000, 1, 0),  # c.jr ra (ret)
        _rvc_quadrant_10(0b1001, 5, 0),  # c.jalr t0
        # ...and the non-control lookalikes on every adjacent field value.
        _rvc_quadrant_10(0b1000, 0, 0),  # rs1=0: reserved, not control
        _rvc_quadrant_10(0b1001, 0, 0),  # c.ebreak: not control
        _rvc_quadrant_10(0b1000, 1, 2),  # c.mv: rs2!=0
        _rvc_quadrant_10(0b1001, 1, 2),  # c.add: rs2!=0
        _rvc_quadrant_10(0b0000, 1, 0),  # c.slli shape
        _rvc_quadrant_10(0b1010, 1, 0),  # c.swsp shape
    ]

    words: list[int] = []
    # Each parcel in the lo and hi halfword, paired with a benign other half.
    for parcel in parcels:
        words.append((0x4501 << 16) | parcel)  # hi = c.li a0 (non-control)
        words.append((parcel << 16) | 0x4501)
    # Each special/near-miss opcode as a native instruction in the lo
    # position (word[6:0]) and in the hi position (word[22:16]).
    for opcode in (*SPECIAL_OPCODES, *NEAR_MISS_OPCODES):
        words.append(0x0000_0000 | opcode | (0x1234 << 16))
        words.append((opcode << 16) | 0x4501)
        words.append((opcode << 16) | (0x1FF << 23) | 0x4501)  # bits 31:23 set
    # Boundary words.
    words.extend([0x0000_0000, 0xFFFF_FFFF, 0xAAAA_AAAA, 0x5555_5555])

    await _check_words(dut, words)


@cocotb.test()
async def test_random_lines(dut: Any) -> None:
    """Fully random 256-bit lines."""
    rng = random.Random(random.getrandbits(32))
    for _ in range(1000):
        await _check_line(dut, [rng.getrandbits(32) for _ in range(WORDS_PER_LINE)])


@cocotb.test()
async def test_biased_random_lines(dut: Any) -> None:
    """Random words biased toward the encodings the predicates decode."""
    rng = random.Random(random.getrandbits(32))

    def _biased_word() -> int:
        word = rng.getrandbits(32)
        # Force each halfword's quadrant uniformly so compressed/native
        # split is dense, and frequently plant a significant opcode.
        word = (word & ~0x3) | rng.randrange(4)
        word = (word & ~(0x3 << 16)) | (rng.randrange(4) << 16)
        if rng.random() < 0.5:
            opcode = rng.choice(SPECIAL_OPCODES + NEAR_MISS_OPCODES)
            if rng.random() < 0.5:
                word = (word & ~0x7F) | opcode
            else:
                word = (word & ~(0x7F << 16)) | (opcode << 16)
        return word

    for _ in range(1000):
        await _check_line(dut, [_biased_word() for _ in range(WORDS_PER_LINE)])
