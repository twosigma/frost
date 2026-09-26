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

"""Fast checks of the CPU reference harness: encoders and models."""

import importlib
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

sys.path.insert(0, str(REPO_ROOT / "sw" / "apps"))
try:
    from riscv_toolchain import default_riscv_prefix
finally:
    sys.path.pop(0)

instruction_encode = importlib.import_module("encoders.instruction_encode")
op_tables = importlib.import_module("encoders.op_tables")
fp_model = importlib.import_module("models.fp_model")
test_state = importlib.import_module("cocotb_tests.test_state")
validation = importlib.import_module("utils.validation")
config = importlib.import_module("config")

# (assembly, op_tables table, mnemonic, encoder arguments, word). The words come
# from GNU as; test_expected_words_match_the_assembler re-assembles them.
ASSEMBLER_MARCH = "rv64gc_zba_zbb_zbs_zbkb"
ENCODINGS: tuple[tuple[str, str, str, tuple[int, ...], int], ...] = (
    ("slli x1, x2, 40", "I_ALU", "slli", (1, 2, 40), 0x02811093),
    ("slli x1, x2, 8", "I_ALU", "slli", (1, 2, 8), 0x00811093),
    ("srli x3, x4, 63", "I_ALU", "srli", (3, 4, 63), 0x03F25193),
    ("srai x5, x6, 33", "I_ALU", "srai", (5, 6, 33), 0x42135293),
    ("bseti x7, x8, 40", "I_ALU", "bseti", (7, 8, 40), 0x2A841393),
    ("bclri x9, x10, 45", "I_ALU", "bclri", (9, 10, 45), 0x4AD51493),
    ("binvi x11, x12, 50", "I_ALU", "binvi", (11, 12, 50), 0x6B261593),
    ("bexti x13, x14, 60", "I_ALU", "bexti", (13, 14, 60), 0x4BC75693),
    ("rori x15, x16, 35", "I_ALU", "rori", (15, 16, 35), 0x62385793),
    ("rev8 x5, x6", "I_UNARY", "rev8", (5, 6), 0x6B835293),
    ("zext.h x5, x6", "I_UNARY", "zext.h", (5, 6), 0x080342BB),
    ("orc.b x7, x8", "I_UNARY", "orc.b", (7, 8), 0x28745393),
    ("brev8 x9, x10", "I_UNARY", "brev8", (9, 10), 0x68755493),
    ("clz x1, x2", "I_UNARY", "clz", (1, 2), 0x60011093),
    ("ctz x1, x2", "I_UNARY", "ctz", (1, 2), 0x60111093),
    ("cpop x1, x2", "I_UNARY", "cpop", (1, 2), 0x60211093),
    ("sext.b x1, x2", "I_UNARY", "sext.b", (1, 2), 0x60411093),
    ("sext.h x1, x2", "I_UNARY", "sext.h", (1, 2), 0x60511093),
    ("pack x1, x2, x3", "R_ALU", "pack", (1, 2, 3), 0x083140B3),
    ("packh x1, x2, x3", "R_ALU", "packh", (1, 2, 3), 0x083170B3),
    ("csrrs x5, instret, x0", "CSRS", "csrrs", (5, 0xC02, 0), 0xC02022F3),
    ("csrrc x5, instret, x0", "CSRS", "csrrc", (5, 0xC02, 0), 0xC02032F3),
    ("csrrsi x5, instret, 0", "CSRS", "csrrsi", (5, 0xC02, 0), 0xC02062F3),
    ("csrrci x5, instret, 0", "CSRS", "csrrci", (5, 0xC02, 0), 0xC02072F3),
)


def _encoder(table: str, mnemonic: str) -> Any:
    """Return the encoder of an op_tables entry, with or without an evaluator."""
    entry = getattr(op_tables, table)[mnemonic]
    return entry[0] if isinstance(entry, tuple) else entry


@pytest.mark.parametrize(
    ("assembly", "table", "mnemonic", "args", "word"),
    ENCODINGS,
    ids=[encoding[0] for encoding in ENCODINGS],
)
def test_encoder_matches_the_assembler(
    assembly: str, table: str, mnemonic: str, args: tuple[int, ...], word: int
) -> None:
    """Shift amounts use 6 bits, and rev8 and zext.h use their RV64 encodings."""
    assert _encoder(table, mnemonic)(*args) == word, assembly


def test_expected_words_match_the_assembler(tmp_path: Path) -> None:
    """The expected words are what GNU as emits for the same assembly."""
    prefix = default_riscv_prefix(REPO_ROOT)
    assembler = shutil.which(f"{prefix}as")
    objcopy = shutil.which(f"{prefix}objcopy")
    if assembler is None or objcopy is None:
        pytest.skip(f"{prefix}as and {prefix}objcopy are not installed")
    source = tmp_path / "encodings.S"
    source.write_text(
        ".option norvc\n" + "".join(f"{encoding[0]}\n" for encoding in ENCODINGS)
    )
    obj = tmp_path / "encodings.o"
    text = tmp_path / "encodings.bin"
    subprocess.run(
        [assembler, f"-march={ASSEMBLER_MARCH}", "-o", str(obj), str(source)],
        check=True,
    )
    subprocess.run(
        [objcopy, "-O", "binary", "--only-section=.text", str(obj), str(text)],
        check=True,
    )
    data = text.read_bytes()
    words = [int.from_bytes(data[i : i + 4], "little") for i in range(0, len(data), 4)]

    assert words == [encoding[4] for encoding in ENCODINGS]


# NaN-boxed single-precision values: -1.0, 2.0, 3.0, canonical NaN, -inf, 3e9.
BOXED_NEG_ONE = 0xFFFF_FFFF_BF80_0000
BOXED_TWO = 0xFFFF_FFFF_4000_0000
BOXED_THREE = 0xFFFF_FFFF_4040_0000
BOXED_NAN = 0xFFFF_FFFF_7FC0_0000
BOXED_NEG_INF = 0xFFFF_FFFF_FF80_0000
BOXED_3E9 = 0xFFFF_FFFF_4F32_D05E
# Double-precision values: -2.0, 2^31, 2^32 - 1.
DOUBLE_NEG_TWO = 0xC000_0000_0000_0000
DOUBLE_2_POW_31 = 0x41E0_0000_0000_0000
DOUBLE_2_POW_32_MINUS_1 = 0x41EF_FFFF_FFE0_0000


FP_INTEGER_CASES: tuple[tuple[str, str, int, int], ...] = (
    # FMV.X.W moves the raw low word, sign-extended, whatever the boxing.
    ("FP_MV_F2I", "fmv.x.w", 0x0000_0000_3F80_0000, 0x0000_0000_3F80_0000),
    ("FP_MV_F2I", "fmv.x.w", BOXED_NEG_ONE, 0xFFFF_FFFF_BF80_0000),
    ("FP_MV_F2I", "fmv.x.w", 0x1234_5678_BF80_0000, 0xFFFF_FFFF_BF80_0000),
    # W-form results are sign-extended from bit 31, unsigned ones included.
    ("FP_CVT_F2I", "fcvt.w.s", BOXED_NEG_ONE, 0xFFFF_FFFF_FFFF_FFFF),
    ("FP_CVT_F2I", "fcvt.w.s", BOXED_NAN, 0x0000_0000_7FFF_FFFF),
    ("FP_CVT_F2I", "fcvt.w.s", BOXED_NEG_INF, 0xFFFF_FFFF_8000_0000),
    ("FP_CVT_F2I", "fcvt.wu.s", BOXED_3E9, 0xFFFF_FFFF_B2D0_5E00),
    ("FP_CVT_F2I", "fcvt.wu.s", BOXED_NAN, 0xFFFF_FFFF_FFFF_FFFF),
    ("FP_CVT_F2I", "fcvt.w.d", DOUBLE_NEG_TWO, 0xFFFF_FFFF_FFFF_FFFE),
    ("FP_CVT_F2I", "fcvt.wu.d", DOUBLE_2_POW_31, 0xFFFF_FFFF_8000_0000),
    ("FP_CVT_F2I", "fcvt.wu.d", DOUBLE_2_POW_32_MINUS_1, 0xFFFF_FFFF_FFFF_FFFF),
    # W-form conversions to FP read only the low word of the integer operand.
    ("FP_CVT_I2F", "fcvt.s.w", 0xFFFF_FFFF_FFFF_FFFF, BOXED_NEG_ONE),
    ("FP_CVT_I2F", "fcvt.s.w", 0x0000_0001_0000_0002, BOXED_TWO),
    ("FP_CVT_I2F", "fcvt.s.wu", 0xFFFF_FFFF_0000_0003, BOXED_THREE),
    ("FP_CVT_I2F", "fcvt.d.w", 0xFFFF_FFFF_FFFF_FFFE, DOUBLE_NEG_TWO),
    ("FP_CVT_I2F", "fcvt.d.wu", 0x0000_0001_FFFF_FFFF, DOUBLE_2_POW_32_MINUS_1),
)


@pytest.mark.parametrize(
    ("table", "mnemonic", "operand", "expected"),
    FP_INTEGER_CASES,
    ids=[f"{case[1]}-{case[2]:#018x}" for case in FP_INTEGER_CASES],
)
def test_fp_integer_moves_and_conversions_follow_rv64(
    table: str, mnemonic: str, operand: int, expected: int
) -> None:
    """Integer results fill all 64 bits of rd; integer operands use the low word."""
    _, evaluator = getattr(op_tables, table)[mnemonic]
    assert evaluator(operand) == expected


class _WordMemory:
    """MemoryReader over a dict of aligned words."""

    def __init__(self, words: dict[int, int]) -> None:
        self.words = words
        self.read_address = 0

    def read_word(self, address: int) -> int:
        return self.words[address]

    def read_byte(self, address: int) -> int:
        return (self.words[address & ~0x3] >> (8 * (address & 0x3))) & 0xFF


def test_flw_nan_boxes_the_loaded_word() -> None:
    """FLW writes the word NaN-boxed; it is not the sign-extended LW value."""
    memory = _WordMemory({0x100: 0x3F80_0000})

    assert fp_model.flw(memory, 0x100) == 0xFFFF_FFFF_3F80_0000
    assert op_tables.FP_LOADS["flw"][1](memory, 0x100) == 0xFFFF_FFFF_3F80_0000


class _ListLog:
    """Stand-in for cocotb.log, which exists only inside a simulation."""

    def __init__(self) -> None:
        self.lines: list[str] = []

    def info(self, message: str) -> None:
        self.lines.append(message)


@pytest.mark.parametrize(
    ("expected", "difference"), ((None, None), ("5", None), (3, 2), (4.5, 0.5))
)
def test_assert_equals_reports_every_mismatch(
    monkeypatch: pytest.MonkeyPatch, expected: object, difference: object
) -> None:
    """A number compared with a non-number raises ValidationError, not TypeError."""
    monkeypatch.setattr(validation.cocotb, "log", _ListLog(), raising=False)
    monkeypatch.setattr(validation.cocotb, "RANDOM_SEED", 1, raising=False)

    with pytest.raises(validation.ValidationError) as failure:
        validation.assert_equals(5, expected)

    assert failure.value.context["difference"] == difference
