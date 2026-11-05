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

"""Unit tests for the backing BTB: training, lookup positions and reset."""

from typing import Any

import cocotb

from config import MASK_XLEN
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
ENTRIES = 1024
PC_A = 0x80000100
TARGET_A = 0x80001000
TARGET_B = 0x80002000
# Another 4 GiB region from PC_A.
TARGET_FAR = 0x1_8000_1000


def _ways(dut: Any) -> int:
    """Return the configured way count."""
    return int(dut.WAYS.value)


def _sets(dut: Any) -> int:
    """Return the set count."""
    return ENTRIES // _ways(dut)


def _index(dut: Any, pc: int) -> int:
    """Return the set index of a PC."""
    return (pc >> 2) & (_sets(dut) - 1)


def _same_set_pc(dut: Any, pc: int, k: int) -> int:
    """PC k set blocks above pc: the same set with a different tag."""
    return (pc + k * _sets(dut) * 4) & MASK_XLEN


def _target_bits(dut: Any) -> int:
    """Return the stored target width."""
    return len(dut.o_target) // 2


def _clear_inputs(dut: Any) -> None:
    """Drive every input idle."""
    dut.i_reset.value = 0
    dut.i_lookup_index.value = 0
    dut.i_packet_pc.value = 0
    dut.i_packet_compressed.value = 0
    dut.i_update.value = 0
    dut.i_update_pc.value = 0
    dut.i_update_target.value = 0
    dut.i_update_taken.value = 0
    dut.i_update_compressed.value = 0
    dut.i_update_call.value = 0
    dut.i_update_return.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _cycle(dut: Any, count: int = 1) -> None:
    """Advance count clock edges and settle."""
    for _ in range(count):
        await RisingEdge(dut.i_clk)
    await _settle()


async def _reset(dut: Any) -> None:
    """Pulse reset and wait for the sweep to clear every set."""
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _cycle(dut, _sets(dut) + 1)


async def _setup(dut: Any) -> None:
    """Start the clock and reset."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    await _reset(dut)


async def _update(
    dut: Any,
    pc: int,
    target: int,
    *,
    taken: bool = True,
    compressed: bool = False,
    call: bool = False,
    ret: bool = False,
    settle_cycles: int = 3,
) -> None:
    """Apply one training update, then wait until every array holds it."""
    dut.i_update.value = 1
    dut.i_update_pc.value = pc & MASK_XLEN
    dut.i_update_target.value = target & MASK_XLEN
    dut.i_update_taken.value = int(taken)
    dut.i_update_compressed.value = int(compressed)
    dut.i_update_call.value = int(call)
    dut.i_update_return.value = int(ret)
    await _cycle(dut)
    dut.i_update.value = 0
    dut.i_update_call.value = 0
    dut.i_update_return.value = 0
    await _cycle(dut, settle_cycles)


async def _lookup(
    dut: Any, packet_pc: int, *, compressed: bool = False, index_pc: int | None = None
) -> tuple[list[bool], list[bool], list[int]]:
    """Read the set of index_pc (default packet_pc), then serve packet_pc."""
    dut.i_lookup_index.value = _index(dut, packet_pc if index_pc is None else index_pc)
    await _cycle(dut)
    dut.i_packet_pc.value = packet_pc & MASK_XLEN
    dut.i_packet_compressed.value = int(compressed)
    await _settle()
    hit = int(dut.o_hit.value)
    size = int(dut.o_compressed.value)
    bits = _target_bits(dut)
    raw = int(dut.o_target.value)
    targets = [((raw >> (slot * bits)) & ((1 << bits) - 1)) << 1 for slot in range(2)]
    return (
        [bool(hit & 1), bool(hit & 2)],
        [bool(size & 1), bool(size & 2)],
        targets,
    )


def _low(dut: Any, target: int) -> int:
    """Return the target bits the table stores."""
    return target & ((1 << (_target_bits(dut) + 1)) - 1)


@cocotb.test()
async def test_trained_jump_hits_in_slot1(dut: Any) -> None:
    """A trained taken jump hits at its PC with its target and size."""
    await _setup(dut)
    hit, size, target = await _lookup(dut, PC_A)
    assert hit == [False, False]

    await _update(dut, PC_A, TARGET_A)
    hit, size, target = await _lookup(dut, PC_A)
    assert hit[0] and not size[0]
    assert target[0] == _low(dut, TARGET_A)


@cocotb.test()
async def test_slot2_positions_follow_slot1_size(dut: Any) -> None:
    """Slot 2 is the next halfword or word, in the packet's word or the next."""
    await _setup(dut)
    await _update(dut, PC_A + 2, TARGET_A, compressed=True)
    await _update(dut, PC_A + 4, TARGET_B)
    await _update(dut, PC_A + 6, TARGET_A + 0x40, compressed=True)

    # Compressed slot 1 at a word boundary: slot 2 at +2 in the same word.
    hit, size, target = await _lookup(dut, PC_A, compressed=True)
    assert not hit[0] and hit[1] and size[1]
    assert target[1] == _low(dut, TARGET_A)
    # Native slot 1: slot 2 at +4, the next word's lower halfword.
    hit, size, target = await _lookup(dut, PC_A, compressed=False)
    assert hit[1] and not size[1]
    assert target[1] == _low(dut, TARGET_B)
    # Slot 1 in the upper halfword: +2 and +4 land in the next word.
    hit, size, target = await _lookup(dut, PC_A + 2, compressed=True)
    assert hit[0] and size[0] and target[0] == _low(dut, TARGET_A)
    assert hit[1] and target[1] == _low(dut, TARGET_B)
    hit, size, target = await _lookup(dut, PC_A + 2, compressed=False)
    assert hit[1] and size[1] and target[1] == _low(dut, TARGET_A + 0x40)


@cocotb.test()
async def test_halfword_tags_do_not_alias(dut: Any) -> None:
    """An entry at one halfword of a word never hits at the other."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    hit, _, _ = await _lookup(dut, PC_A + 2, compressed=True)
    assert not hit[0]
    hit, _, _ = await _lookup(dut, PC_A)
    assert hit[0]


@cocotb.test()
async def test_ways_fill_then_replace_the_older_way(dut: Any) -> None:
    """A set holds one jump per way; the next miss replaces the oldest write."""
    await _setup(dut)
    ways = _ways(dut)
    pcs = [_same_set_pc(dut, PC_A, k) for k in range(ways + 1)]
    for k in range(ways):
        await _update(dut, pcs[k], TARGET_A + 0x10 * k)
    for k in range(ways):
        hit, _, target = await _lookup(dut, pcs[k])
        assert hit[0] and target[0] == _low(dut, TARGET_A + 0x10 * k), k
    await _update(dut, pcs[ways], TARGET_B)
    hit, _, target = await _lookup(dut, pcs[ways])
    assert hit[0] and target[0] == _low(dut, TARGET_B)
    hit, _, _ = await _lookup(dut, pcs[0])
    assert not hit[0], "the first-written way is the victim"
    for k in range(1, ways):
        hit, _, _ = await _lookup(dut, pcs[k])
        assert hit[0], k


@cocotb.test()
async def test_back_to_back_updates_to_one_set(dut: Any) -> None:
    """Consecutive updates to one set see each other and fill both ways."""
    await _setup(dut)
    other = _same_set_pc(dut, PC_A, 1)
    dut.i_update.value = 1
    dut.i_update_taken.value = 1
    dut.i_update_pc.value = PC_A
    dut.i_update_target.value = TARGET_A
    await _cycle(dut)
    dut.i_update_pc.value = other
    dut.i_update_target.value = TARGET_B
    await _cycle(dut)
    dut.i_update_pc.value = PC_A
    dut.i_update_target.value = TARGET_B + 0x20
    await _cycle(dut)
    dut.i_update.value = 0
    await _cycle(dut, 3)
    hit, _, target = await _lookup(dut, PC_A)
    assert hit[0] and target[0] == _low(dut, TARGET_B + 0x20)
    hit, _, target = await _lookup(dut, other)
    assert hit[0] and target[0] == _low(dut, TARGET_B)


@cocotb.test()
async def test_retraining_replaces_a_stale_target(dut: Any) -> None:
    """A retrained jump returns its newest target, never the older one."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    await _update(dut, PC_A, TARGET_B)
    hit, _, target = await _lookup(dut, PC_A)
    assert hit[0] and target[0] == _low(dut, TARGET_B)


@cocotb.test()
async def test_cross_region_target_invalidates(dut: Any) -> None:
    """A target in another 4 GiB region invalidates a hit and never allocates."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    await _update(dut, PC_A, TARGET_FAR)
    hit, _, _ = await _lookup(dut, PC_A)
    assert not hit[0]
    await _update(dut, PC_A + 8, TARGET_FAR)
    hit, _, _ = await _lookup(dut, PC_A + 8)
    assert not hit[0]


@cocotb.test()
async def test_not_taken_counter_and_typed_entries_do_not_hit(dut: Any) -> None:
    """Only entries predicting taken that are neither calls nor returns hit."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    await _update(dut, PC_A, TARGET_A, taken=False)
    hit, _, _ = await _lookup(dut, PC_A)
    assert not hit[0]
    await _update(dut, PC_A, TARGET_A)
    hit, _, _ = await _lookup(dut, PC_A)
    assert hit[0]
    await _update(dut, PC_A + 8, TARGET_A, call=True)
    await _update(dut, PC_A + 12, TARGET_A, ret=True)
    hit, _, _ = await _lookup(dut, PC_A + 8)
    assert not hit[0]
    hit, _, _ = await _lookup(dut, PC_A + 12)
    assert not hit[0]


@cocotb.test()
async def test_packet_outside_the_read_set_misses(dut: Any) -> None:
    """A packet whose set was not read gets no hit, and a wrapped next set misses."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    hit, _, _ = await _lookup(dut, PC_A, index_pc=PC_A + 4)
    assert hit == [False, False]
    # The word after the last set of a block is set 0 of the next block,
    # whose tag differs from the packet's.
    last = (PC_A | ((_sets(dut) - 1) << 2)) & MASK_XLEN
    await _update(dut, last + 4, TARGET_B)
    hit, _, _ = await _lookup(dut, last)
    assert not hit[1]
    hit, _, target = await _lookup(dut, last + 4)
    assert hit[0] and target[0] == _low(dut, TARGET_B)


@cocotb.test()
async def test_reset_clears_entries_and_drops_updates_while_clearing(dut: Any) -> None:
    """Reset clears trained sets; updates during the clearing sweep are dropped."""
    await _setup(dut)
    await _update(dut, PC_A, TARGET_A)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _update(dut, PC_A + 16, TARGET_B)
    await _cycle(dut, _sets(dut))
    hit, _, _ = await _lookup(dut, PC_A)
    assert not hit[0]
    hit, _, _ = await _lookup(dut, PC_A + 16)
    assert not hit[0]
    await _update(dut, PC_A + 16, TARGET_B)
    hit, _, target = await _lookup(dut, PC_A + 16)
    assert hit[0] and target[0] == _low(dut, TARGET_B)
