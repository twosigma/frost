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

#    Copyright (c) 2026 John Goodacre.
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

"""Unit tests for the indirect target predictor (ittage_predictor)."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLOCK_PERIOD_NS = 10
HIST_BITS = 64
INDEX_BITS = 7
TAG_BITS = 11
TABLE_HIST = (8, 24, 64)
TARGET_BITS = 31  # target bits [PhysAddrBits-1:1] for PhysAddrBits = 32
WORD_BITS = 19  # word-address bits [20:2]
WORD_MASK = (1 << WORD_BITS) - 1
INDEX_MASK = (1 << INDEX_BITS) - 1
TAG_MASK = (1 << TAG_BITS) - 1
HIST_MASK = (1 << HIST_BITS) - 1
LOOKUP_BITS = 3 * INDEX_BITS + 3 * TAG_BITS + 3

PC_A = 0x80000100  # even word: bank 0
PC_B = 0x80000344  # odd word: bank 1


def _fold(hist: int, width: int) -> int:
    """XOR-fold the history into width bits (bit b lands on b % width)."""
    folded = 0
    for b in range(HIST_BITS):
        if (hist >> b) & 1:
            folded ^= 1 << (b % width)
    return folded


def _word(pc: int) -> int:
    return (pc >> 2) & WORD_MASK


def _keys(word: int, hist: int) -> list[tuple[int, int]]:
    """Return (index, tag) per table for one word's lookup."""
    keys = []
    for bits in TABLE_HIST:
        h = hist & ((1 << bits) - 1)
        index = (
            (word >> 1) ^ (word >> (1 + INDEX_BITS)) ^ _fold(h, INDEX_BITS)
        ) & INDEX_MASK
        tag = (word ^ _fold(h, TAG_BITS) ^ (_fold(h, TAG_BITS - 1) << 1)) & TAG_MASK
        keys.append((index, tag))
    return keys


def _pack_lookup(keys: list[tuple[int, int]], hits: tuple[int, int, int]) -> int:
    """Pack itt_lookup_t: {index[2:0], tag[2:0], hit[2:0]}, element 2 highest."""
    value = 0
    for t in (2, 1, 0):
        value = (value << INDEX_BITS) | keys[t][0]
    for t in (2, 1, 0):
        value = (value << TAG_BITS) | keys[t][1]
    for t in (2, 1, 0):
        value = (value << 1) | hits[t]
    return value


def _unpack_hits(lookup: int) -> tuple[int, int, int]:
    return (lookup & 1, (lookup >> 1) & 1, (lookup >> 2) & 1)


async def _settle() -> None:
    await Timer(1, unit="ns")


async def _cycle(dut: Any) -> None:
    await RisingEdge(dut.i_clk)
    await _settle()


def _clear_rows(dut: Any, word: int, hist: int) -> None:
    """Invalidate the rows a lookup of word reads (the tables have no reset)."""
    bank = word & 1
    for t, (index, _tag) in enumerate(_keys(word, hist)):
        storage = dut.gen_bank[bank].gen_table[t]
        for copy in (storage.u_lookup_copy, storage.u_train_copy):
            copy.ram[index].value = 0


async def _start(dut: Any) -> None:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_lookup_word.value = 0
    dut.i_lookup_hist.value = 0
    dut.i_lookup_capture.value = 0
    dut.i_train_valid.value = 0
    dut.i_train_lookup.value = 0
    dut.i_train_bank.value = 0
    dut.i_train_target.value = 0
    dut.i_train_mispredicted.value = 0
    for _ in range(3):
        await _cycle(dut)


async def _lookup(dut: Any, pc: int, hist: int) -> tuple[int, int, int]:
    """Look up pc's word; return (hit, target, saved lookup) of its bank."""
    word = _word(pc)
    dut.i_lookup_word.value = word
    dut.i_lookup_hist.value = hist
    dut.i_lookup_capture.value = 1
    await _cycle(dut)
    dut.i_lookup_capture.value = 0
    await _settle()
    bank = word & 1
    hit = (int(dut.o_hit.value) >> bank) & 1
    target = (int(dut.o_target.value) >> (bank * TARGET_BITS)) & (
        (1 << TARGET_BITS) - 1
    )
    lookup = int(dut.o_bank1.value if bank else dut.o_bank0.value)
    return hit, target, lookup


async def _train(
    dut: Any, pc: int, lookup: int, target: int, mispredicted: int
) -> None:
    dut.i_train_valid.value = 1
    dut.i_train_lookup.value = lookup
    dut.i_train_bank.value = _word(pc) & 1
    dut.i_train_target.value = target
    dut.i_train_mispredicted.value = mispredicted
    await _cycle(dut)
    dut.i_train_valid.value = 0
    await _cycle(dut)
    await _cycle(dut)


@cocotb.test()
async def test_allocate_then_predict(dut: Any) -> None:
    """A mispredicted JALR with no match allocates in table 1; the next lookup hits it."""
    await _start(dut)
    for pc, hist in ((PC_A, 0x1234), (PC_B, 0xBEEF_0042)):
        _clear_rows(dut, _word(pc), hist)
        hit, _target, lookup = await _lookup(dut, pc, hist)
        assert hit == 0, f"{pc:#x}: hit before training"
        assert lookup == _pack_lookup(_keys(_word(pc), hist), (0, 0, 0)), (
            "saved lookup keys"
        )
        await _train(dut, pc, lookup, 0x1234_5678, 1)
        hit, target, lookup = await _lookup(dut, pc, hist)
        assert hit == 1 and target == 0x1234_5678, (
            f"{pc:#x}: hit={hit} target={target:#x}"
        )
        assert _unpack_hits(lookup) == (1, 0, 0), (
            f"provider tables {_unpack_hits(lookup)}"
        )


@cocotb.test()
async def test_confidence_then_replace(dut: Any) -> None:
    """Correct targets raise confidence; wrong ones lower it, then replace the target."""
    await _start(dut)
    hist = 0x00F0_0F00_0000_00AA
    _clear_rows(dut, _word(PC_A), hist)
    _hit, _t, lookup = await _lookup(dut, PC_A, hist)
    await _train(dut, PC_A, lookup, 0x0000_1000, 1)
    _hit, _t, lookup = await _lookup(dut, PC_A, hist)
    for _ in range(2):  # confidence 0 -> 2 (correct, not mispredicted)
        await _train(dut, PC_A, lookup, 0x0000_1000, 0)
    for _ in range(2):  # wrong target, mispredicted, confidence 2 -> 0; allocates above
        await _train(dut, PC_A, lookup, 0x0000_2000, 1)
        hit, target, _l = await _lookup(dut, PC_A, hist)
        assert hit and target in (0x0000_1000, 0x0000_2000)
    # Table 1 still holds the first target until its confidence is gone.
    storage = dut.gen_bank[_word(PC_A) & 1].gen_table[0]
    index = _keys(_word(PC_A), hist)[0][0]
    row = int(storage.u_lookup_copy.ram[index].value)
    t1_target = (row >> 3) & ((1 << TARGET_BITS) - 1)
    t1_conf = (row >> 1) & 3
    assert t1_target == 0x0000_1000 and t1_conf == 0, (
        f"T1 target={t1_target:#x} conf={t1_conf}"
    )
    await _train(dut, PC_A, lookup, 0x0000_2000, 1)
    row = int(storage.u_lookup_copy.ram[index].value)
    assert (row >> 3) & ((1 << TARGET_BITS) - 1) == 0x0000_2000, (
        "T1 target replaced at conf 0"
    )


@cocotb.test()
async def test_allocates_above_provider(dut: Any) -> None:
    """A mispredicted JALR whose provider is table 1 allocates in table 2, which then provides."""
    await _start(dut)
    hist = 0x0000_0000_00AB_CD12
    _clear_rows(dut, _word(PC_B), hist)
    _hit, _t, lookup = await _lookup(dut, PC_B, hist)
    await _train(dut, PC_B, lookup, 0x0000_3000, 1)
    hit, target, lookup = await _lookup(dut, PC_B, hist)
    assert hit and target == 0x0000_3000 and _unpack_hits(lookup) == (1, 0, 0)
    await _train(dut, PC_B, lookup, 0x0000_4000, 1)
    hit, target, lookup = await _lookup(dut, PC_B, hist)
    assert hit and _unpack_hits(lookup)[1] == 1, f"tables {_unpack_hits(lookup)}"
    assert target == 0x0000_4000, f"table 2 provides {target:#x}"


@cocotb.test()
async def test_lookup_only_provider_releases_a_stale_target(dut: Any) -> None:
    """Training a lookup-only provider preserves the training row and releases its target."""
    await _start(dut)
    hist = 0x1234_5678_9ABC_DEF0
    word = _word(PC_A)
    _clear_rows(dut, word, hist)
    index, tag = _keys(word, hist)[2]
    storage = dut.gen_bank[word & 1].gen_table[2]
    prefix = (1 << TAG_BITS) | tag
    stale_target, actual_target = 0x1200, 0x3400
    storage.u_lookup_copy.ram[index].value = (
        (prefix << TARGET_BITS) | stale_target
    ) << 3
    other_entry = ((((prefix ^ 1) << TARGET_BITS) | 0x5600) << 3) | 3
    storage.u_train_copy.ram[index].value = other_entry
    hit, target, lookup = await _lookup(dut, PC_A, hist)
    assert hit and target == stale_target and _unpack_hits(lookup) == (0, 0, 1)
    await _train(dut, PC_A, lookup, actual_target, 1)
    hit, _, lookup = await _lookup(dut, PC_A, hist)
    assert not hit, "the training row belongs to another tag"
    assert int(storage.u_train_copy.ram[index].value) == other_entry
    assert int(storage.u_lookup_copy.ram[index].value) == other_entry
    await _train(dut, PC_A, lookup, actual_target, 1)
    hit, target, _ = await _lookup(dut, PC_A, hist)
    assert hit and target == actual_target
