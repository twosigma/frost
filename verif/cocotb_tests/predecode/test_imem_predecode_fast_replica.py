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

"""Programming/fetch checks for imem_predecode's narrow timing replicas.

The seven-bit RAM64M8-shaped replica carries raw high-parcel ``C[15]``,
``C[13]``, and ``C[12]``, the ``rd == x2`` predicate, both compressed-size
flags, and the high-parcel allows-slot-2 predicate. The two replicated high
parcel fields reconstruct both compressed and native pairability. A one-bit
replica carries low-parcel slot-2-start validity. This bench writes both
interleaved banks through the programming port, then checks complete data,
predicate, and sideband windows through both PC[2] swap cases.
"""

import importlib.util
from pathlib import Path
from types import ModuleType
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

PORT_A_PERIOD_NS = 14
PORT_B_PERIOD_NS = 10
WORD_COUNT = 16
FAST_RAW_MASK = (1 << 31) | (1 << 29) | (1 << 28)


def _load_generator() -> ModuleType:
    """Import the offline predecode generator as the sideband golden model."""
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
SIDEBAND_MASK = (1 << SIDEBAND_WIDTH) - 1
FAST_SIDEBAND_MASK = (
    0b11
    | (1 << _GENERATOR.SB_ALLOWS_SLOT2_AFTER_HI)
    | (1 << _GENERATOR.SB_PAIRABLE_COMPRESSED_HI)
    | (1 << _GENERATOR.SB_PAIRABLE_NATIVE_HI)
    | (1 << _GENERATOR.SB_SLOT2_START_VALID_LO)
)


def _with_hi_opcode(word: int, opcode: int) -> int:
    """Replace the high parcel's native opcode, including its size quadrant."""
    return (word & ~(0x7F << 16)) | ((opcode & 0x7F) << 16)


def _with_lo_opcode(word: int, opcode: int) -> int:
    """Replace the low parcel's native opcode, including its size quadrant."""
    return (word & ~0x7F) | (opcode & 0x7F)


def _with_hi_size_allows_row(word: int, *, compressed: bool, allows: bool) -> int:
    """Set one row of the high-size/high-allows reconstruction truth table."""
    if not compressed:
        opcode = 0b011_0011 if allows else _GENERATOR.OPC_CSR
        return _with_hi_opcode(word, opcode)

    # C.ADDI (funct3=000) is non-control; C.J (funct3=101) is control.
    funct3 = 0b000 if allows else 0b101
    hi = (word >> 16) & 0xFFFF
    hi = (hi & ~((0x7 << 13) | 0x3)) | (funct3 << 13) | 0b01
    return (word & 0xFFFF) | (hi << 16)


def _expected_compressed_control(parcel: int) -> bool:
    """Independently classify compressed control-flow instructions."""
    funct3 = (parcel >> 13) & 0x7
    funct4 = (parcel >> 12) & 0xF
    rs1 = (parcel >> 7) & 0x1F
    rs2 = (parcel >> 2) & 0x1F
    op = parcel & 0x3
    return (op == 0b01 and funct3 in {0b001, 0b101, 0b110, 0b111}) or (
        op == 0b10 and rs2 == 0 and rs1 != 0 and funct4 in {0b1000, 0b1001}
    )


def _expected_allows_slot2_after_hi(word: int) -> int:
    """Independently model the timing-facing high allows-slot-2 lane."""
    hi = (word >> 16) & 0xFFFF
    opcode = hi & 0x7F
    compressed = (hi & 0x3) != 0b11
    if compressed:
        return int(not _expected_compressed_control(hi))

    native_control = opcode in {
        _GENERATOR.OPC_BRANCH,
        _GENERATOR.OPC_JAL,
        _GENERATOR.OPC_JALR,
    }
    native_serialize = opcode in {
        _GENERATOR.OPC_CSR,
        _GENERATOR.OPC_MISC_MEM,
        _GENERATOR.OPC_AMO,
    }
    return int(not native_control and not native_serialize)


def _expected_pairable_compressed_hi(word: int) -> int:
    """Reconstruct compressed-high pairability from size and allows."""
    compressed = ((word >> 16) & 0x3) != 0b11
    return int(compressed and _expected_allows_slot2_after_hi(word))


def _expected_pairable_native_hi(word: int) -> int:
    """Reconstruct native-high pairability from size and allows."""
    compressed = ((word >> 16) & 0x3) != 0b11
    return int(not compressed and _expected_allows_slot2_after_hi(word))


def _expected_slot2_start_valid_lo(word: int) -> int:
    """Independently model the dedicated bit-10 timing replica."""
    lo = word & 0xFFFF
    opcode = lo & 0x7F
    compressed = (lo & 0x3) != 0b11
    native_serialize = opcode in {
        _GENERATOR.OPC_CSR,
        _GENERATOR.OPC_MISC_MEM,
        _GENERATOR.OPC_AMO,
    }
    native_fp_compute = opcode in {
        _GENERATOR.OPC_OP_FP,
        _GENERATOR.OPC_FMADD,
        _GENERATOR.OPC_FMSUB,
        _GENERATOR.OPC_FNMSUB,
        _GENERATOR.OPC_FNMADD,
    }
    return int(compressed or not (native_serialize or native_fp_compute))


def _expected_fast_replica(word: int) -> int:
    """Independently pack the seven LUTRAM lanes used by RTL and init files."""
    compressed = int((word & 0x3) != 0b11) | (int(((word >> 16) & 0x3) != 0b11) << 1)
    return (
        (_expected_allows_slot2_after_hi(word) << 6)
        | (((word >> 28) & 0b11) << 4)
        | (((word >> 31) & 1) << 3)
        | (int(((word >> 23) & 0x1F) == 2) << 2)
        | compressed
    )


def _check_offline_init_replica(words: list[int]) -> None:
    """Check exact even/odd init-bank splitting and every generated LUTRAM bit."""
    even_words, odd_words = _GENERATOR.split_words(dict(enumerate(words)), len(words))
    assert even_words == words[::2]
    assert odd_words == words[1::2]
    for bank_words in (even_words, odd_words):
        for word in bank_words:
            assert _GENERATOR.make_fast_replica(word) == _expected_fast_replica(word)
            assert _GENERATOR.make_slot2_start_valid_lo_replica(
                word
            ) == _expected_slot2_start_valid_lo(word)


def _make_word(
    payload: int,
    *,
    fast_raw_bits: int,
    hi_rd: int,
    compressed_lo: bool,
    compressed_hi: bool,
) -> int:
    """Set all replica inputs without making the rest of the word trivial."""
    word = payload & ~FAST_RAW_MASK & 0xFFFF_FFFF
    word |= ((fast_raw_bits >> 2) & 1) << 31  # C[15]
    word |= ((fast_raw_bits >> 1) & 1) << 29  # C[13]
    word |= (fast_raw_bits & 1) << 28  # C[12]
    word = (word & ~(0x1F << 23)) | ((hi_rd & 0x1F) << 23)
    word = (word & ~0x3) | (0b01 if compressed_lo else 0b11)
    word = (word & ~(0x3 << 16)) | ((0b01 if compressed_hi else 0b11) << 16)
    return word


async def _write_word(dut: Any, word_index: int, word: int) -> None:
    """Program one word and check programming-port write-first behavior."""
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 1
    dut.i_port_a_byte_address.value = 4 * word_index
    dut.i_port_a_write_data.value = word
    dut.i_port_a_write_enable.value = 1
    await RisingEdge(dut.i_port_a_clk)
    await ReadOnly()
    assert int(dut.o_port_a_read_data.value) == word
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 0
    dut.i_port_a_write_enable.value = 0


async def _read_word(dut: Any, word_index: int, expected: int) -> None:
    """Read one word through port A to independently check its selected bank."""
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 1
    dut.i_port_a_byte_address.value = 4 * word_index
    dut.i_port_a_write_enable.value = 0
    await RisingEdge(dut.i_port_a_clk)
    await ReadOnly()
    assert int(dut.o_port_a_read_data.value) == expected
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 0


def _check_sideband_word(got: int, expected_word: int, label: str) -> None:
    """Check full predecode plus every field supplied by the fast mirror."""
    expected = _GENERATOR.make_sideband(expected_word)
    assert got == expected, f"{label} sideband 0x{got:03x}, want 0x{expected:03x}"

    expected_compressed = int((expected_word & 0x3) != 0b11) | (
        int(((expected_word >> 16) & 0x3) != 0b11) << 1
    )
    assert got & 0x3 == expected_compressed, (
        f"{label} compressed mirror 0b{got & 0x3:02b}, "
        f"want 0b{expected_compressed:02b}"
    )
    assert got & FAST_SIDEBAND_MASK == expected & FAST_SIDEBAND_MASK, (
        f"{label} fast-sideband mirror 0x{got & FAST_SIDEBAND_MASK:03x}, "
        f"want 0x{expected & FAST_SIDEBAND_MASK:03x}"
    )
    fast_replica = _GENERATOR.make_fast_replica(expected_word, expected)
    allows_slot2_after_hi = _expected_allows_slot2_after_hi(expected_word)
    pairable_compressed_hi = _expected_pairable_compressed_hi(expected_word)
    pairable_native_hi = _expected_pairable_native_hi(expected_word)
    slot2_start_valid_lo = _expected_slot2_start_valid_lo(expected_word)
    assert (
        (expected >> _GENERATOR.SB_ALLOWS_SLOT2_AFTER_HI) & 1
    ) == allows_slot2_after_hi
    assert (
        (expected >> _GENERATOR.SB_PAIRABLE_COMPRESSED_HI) & 1
    ) == pairable_compressed_hi
    assert (expected >> _GENERATOR.SB_PAIRABLE_NATIVE_HI) & 1 == pairable_native_hi
    assert (expected >> _GENERATOR.SB_SLOT2_START_VALID_LO) & 1 == slot2_start_valid_lo
    assert fast_replica == _expected_fast_replica(expected_word)
    assert (
        _GENERATOR.make_slot2_start_valid_lo_replica(expected_word, expected)
        == slot2_start_valid_lo
    )


async def _fetch_window(dut: Any, words: list[int], current_index: int) -> None:
    """Fetch one adjacent pair and check data, mirrored bits, and parity steer."""
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 1
    dut.i_port_b_byte_address.value = 4 * current_index
    await RisingEdge(dut.i_port_b_clk)
    await ReadOnly()

    current = words[current_index]
    next_word = words[(current_index + 1) % len(words)]
    got_data = int(dut.o_port_b_read_data.value)
    expected_data = (next_word << 32) | current
    assert got_data == expected_data, (
        f"window {current_index}: data 0x{got_data:016x}, "
        f"want 0x{expected_data:016x}"
    )
    got_hi_rd_is_x2 = int(dut.o_port_b_hi_rd_is_x2.value)
    expected_hi_rd_is_x2 = int(((current >> 23) & 0x1F) == 2) | (
        int(((next_word >> 23) & 0x1F) == 2) << 1
    )
    assert got_hi_rd_is_x2 == expected_hi_rd_is_x2, (
        f"window {current_index}: hi-rd-x2 0b{got_hi_rd_is_x2:02b}, "
        f"want 0b{expected_hi_rd_is_x2:02b}"
    )

    got_sideband = int(dut.o_port_b_sideband.value)
    _check_sideband_word(
        got_sideband & SIDEBAND_MASK, current, f"window {current_index} current"
    )
    _check_sideband_word(
        (got_sideband >> SIDEBAND_WIDTH) & SIDEBAND_MASK,
        next_word,
        f"window {current_index} next",
    )
    assert int(dut.o_port_b_bank_sel_r.value) == (current_index & 1)
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0


@cocotb.test()
async def test_programmed_fast_replica_and_parity_swap(dut: Any) -> None:
    """Cover every replica field, bank-swap direction, and overwrite transition."""
    words = [0] * WORD_COUNT
    for fast_raw_bits in range(8):
        even_index = 2 * fast_raw_bits
        odd_index = even_index + 1
        odd_fast_raw_bits = fast_raw_bits ^ 0b111
        words[even_index] = _make_word(
            0x1357_9BDF ^ (even_index * 0x0101_0101),
            fast_raw_bits=fast_raw_bits,
            hi_rd=2 if fast_raw_bits & 1 else 3,
            compressed_lo=bool(fast_raw_bits & 1),
            compressed_hi=bool(fast_raw_bits & 2),
        )
        words[odd_index] = _make_word(
            0x2468_ACE0 ^ (odd_index * 0x0101_0101),
            fast_raw_bits=odd_fast_raw_bits,
            hi_rd=2 if odd_fast_raw_bits & 2 else 18,
            compressed_lo=bool(odd_fast_raw_bits & 2),
            compressed_hi=bool(odd_fast_raw_bits & 4),
        )

    # Exercise both values of every predicate replica in each physical bank,
    # including compressed, ordinary native, serialize, and FP-compute cases.
    high_size_allows_rows = [
        (False, False),
        (False, True),
        (True, False),
        (True, True),
    ]
    low_opcodes = [0b000_0001, 0b011_0011, _GENERATOR.OPC_CSR, _GENERATOR.OPC_OP_FP]
    for case_index in range(8):
        compressed_hi, allows_hi = high_size_allows_rows[
            case_index % len(high_size_allows_rows)
        ]
        low_opcode = low_opcodes[case_index % len(low_opcodes)]
        for word_index in (2 * case_index, 2 * case_index + 1):
            words[word_index] = _with_hi_size_allows_row(
                words[word_index], compressed=compressed_hi, allows=allows_hi
            )
            words[word_index] = _with_lo_opcode(words[word_index], low_opcode)
    for bank_parity in (0, 1):
        observed_size_allows_rows = {
            (
                int(((word >> 16) & 0x3) != 0b11),
                _expected_allows_slot2_after_hi(word),
            )
            for word in words[bank_parity::2]
        }
        assert observed_size_allows_rows == {(0, 0), (0, 1), (1, 0), (1, 1)}
        mirrored_allows_values = {
            _expected_allows_slot2_after_hi(word) for word in words[bank_parity::2]
        }
        assert mirrored_allows_values == {0, 1}
        rebuilt_compressed_values = {
            _expected_pairable_compressed_hi(word) for word in words[bank_parity::2]
        }
        assert rebuilt_compressed_values == {0, 1}
        rebuilt_native_values = {
            _expected_pairable_native_hi(word) for word in words[bank_parity::2]
        }
        assert rebuilt_native_values == {0, 1}
        start_valid_values = {
            _expected_slot2_start_valid_lo(word) for word in words[bank_parity::2]
        }
        assert start_valid_values == {0, 1}
    _check_offline_init_replica(words)

    dut.i_port_a_enable.value = 0
    dut.i_port_a_byte_address.value = 0
    dut.i_port_a_write_data.value = 0
    dut.i_port_a_write_enable.value = 0
    dut.i_port_b_enable.value = 0
    dut.i_port_b_byte_address.value = 0
    cocotb.start_soon(Clock(dut.i_port_a_clk, PORT_A_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.i_port_b_clk, PORT_B_PERIOD_NS, unit="ns").start())

    for word_index, word in enumerate(words):
        await _write_word(dut, word_index, word)

    dut.i_port_a_enable.value = 0
    dut.i_port_a_write_enable.value = 0
    for word_index, word in enumerate(words):
        await _read_word(dut, word_index, word)

    dut.i_port_a_enable.value = 0
    for current_index in range(len(words)):
        await _fetch_window(dut, words, current_index)

    # Exercise 000 -> 111 and 111 -> 000 in both physical banks. Distinctive
    # replacement payloads make the complete fetched-word comparison catch any
    # stale BRAM field as well as a stale replica lane.
    overwrites = {
        0: _with_hi_opcode(
            _make_word(
                0x0BAD_C0DE,
                fast_raw_bits=0b111,
                hi_rd=2,
                compressed_lo=True,
                compressed_hi=False,
            ),
            0b001_0011,
        ),
        1: _with_hi_opcode(
            _make_word(
                0x1234_5678,
                fast_raw_bits=0b000,
                hi_rd=31,
                compressed_lo=False,
                compressed_hi=True,
            ),
            0b001_0011,
        ),
        14: _with_hi_opcode(
            _make_word(
                0x89AB_CDEF,
                fast_raw_bits=0b000,
                hi_rd=0,
                compressed_lo=True,
                compressed_hi=True,
            ),
            0b111_0011,
        ),
        15: _with_hi_opcode(
            _make_word(
                0x55AA_33CC,
                fast_raw_bits=0b111,
                hi_rd=2,
                compressed_lo=False,
                compressed_hi=False,
            ),
            0b000_0001,
        ),
    }
    # Flip the high-allows and low-start-valid replicas on every overwrite so
    # stale values are observable in both banks and both sides of the swap mux.
    for word_index, word in tuple(overwrites.items()):
        old_allows = _expected_allows_slot2_after_hi(words[word_index])
        replacement_hi_opcode = _GENERATOR.OPC_CSR if old_allows else 0b011_0011
        word = _with_hi_opcode(word, replacement_hi_opcode)
        old_start_valid = _expected_slot2_start_valid_lo(words[word_index])
        replacement_opcode = _GENERATOR.OPC_OP_FP if old_start_valid else 0b011_0011
        overwrites[word_index] = _with_lo_opcode(word, replacement_opcode)
    for word_index, word in overwrites.items():
        assert _expected_allows_slot2_after_hi(word) != _expected_allows_slot2_after_hi(
            words[word_index]
        )
        assert _expected_slot2_start_valid_lo(word) != _expected_slot2_start_valid_lo(
            words[word_index]
        )
    _check_offline_init_replica(list(overwrites.values()))
    for word_index, word in overwrites.items():
        await _write_word(dut, word_index, word)
        words[word_index] = word

    for word_index, word in overwrites.items():
        await _read_word(dut, word_index, word)

    for current_index in range(len(words)):
        await _fetch_window(dut, words, current_index)

    # Consecutive starts alternate PC[2], so every phase exercises both bank
    # swap directions, including the final-word -> word-zero address wrap.
    dut.i_port_b_enable.value = 0
