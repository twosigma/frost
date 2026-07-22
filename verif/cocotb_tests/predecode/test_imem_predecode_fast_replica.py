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

"""Programming/fetch checks for imem_predecode's six-bit fast replica.

The timing replica carries raw high-parcel ``C[15]``, ``C[13]``, and
``C[12]``, the ``rd == x2`` predicate, and both compressed-size flags. This bench writes both
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
    word = (word & ~(0x3 << 16)) | (
        (0b01 if compressed_hi else 0b11) << 16
    )
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
    """Check full predecode plus the two fields supplied by the fast mirror."""
    expected = _GENERATOR.make_sideband(expected_word)
    assert got == expected, f"{label} sideband 0x{got:03x}, want 0x{expected:03x}"

    expected_compressed = (
        int((expected_word & 0x3) != 0b11)
        | (int(((expected_word >> 16) & 0x3) != 0b11) << 1)
    )
    assert got & 0x3 == expected_compressed, (
        f"{label} compressed mirror 0b{got & 0x3:02b}, "
        f"want 0b{expected_compressed:02b}"
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
    expected_hi_rd_is_x2 = (
        int(((current >> 23) & 0x1F) == 2)
        | (int(((next_word >> 23) & 0x1F) == 2) << 1)
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
    """Cover every replicated C-bit triple and both overwrite directions per bank."""
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
        0: _make_word(
            0x0BAD_C0DE,
            fast_raw_bits=0b111,
            hi_rd=2,
            compressed_lo=True,
            compressed_hi=False,
        ),
        1: _make_word(
            0x1234_5678,
            fast_raw_bits=0b000,
            hi_rd=31,
            compressed_lo=False,
            compressed_hi=True,
        ),
        14: _make_word(
            0x89AB_CDEF,
            fast_raw_bits=0b000,
            hi_rd=0,
            compressed_lo=True,
            compressed_hi=True,
        ),
        15: _make_word(
            0x55AA_33CC,
            fast_raw_bits=0b111,
            hi_rd=2,
            compressed_lo=False,
            compressed_hi=False,
        ),
    }
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
