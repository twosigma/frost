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

"""Check sdp_packed_tag_uram packing, groups, latency, and optional bulk clear.

The geometry comes from the port widths: DATA_WIDTH from i_write_data and
READ_WORDS from i_write_word_mask. A read returns the aligned group of
READ_WORDS entries holding its address; a write updates the masked words of
the group holding its address.
"""

import hashlib
import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLOCK_PERIOD_NS = 10
READ_LATENCY = 3


async def _tick(dut: Any) -> None:
    """Advance one rising edge and sample after nonblocking assignments."""
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


def _read_words(dut: Any) -> int:
    return len(dut.i_write_word_mask)


def _drive_idle(dut: Any) -> None:
    dut.i_write_enable.value = 0
    dut.i_bulk_clear.value = 0
    dut.i_write_address.value = 0
    dut.i_write_word_mask.value = 0
    dut.i_write_data.value = 0
    dut.i_read_enable.value = 0
    dut.i_read_address.value = 0


def _drive_write(dut: Any, address: int, data: int, mask: int | None) -> None:
    """Present one write; mask defaults to address's own word of its group."""
    dut.i_write_enable.value = 1
    dut.i_write_address.value = address
    dut.i_write_word_mask.value = (
        1 << (address % _read_words(dut)) if mask is None else mask
    )
    dut.i_write_data.value = data


async def _write(dut: Any, address: int, data: int, mask: int | None = None) -> None:
    _drive_write(dut, address, data, mask)
    await _tick(dut)
    dut.i_write_enable.value = 0


def _word(dut: Any, group: int, address: int) -> int:
    """Return address's word of a read group's output."""
    width = len(dut.i_write_data)
    return (group >> (width * (address % _read_words(dut)))) & ((1 << width) - 1)


def _output(dut: Any, address: int) -> int:
    return _word(dut, int(dut.o_read_data.value), address)


async def _read_group(dut: Any, address: int) -> int:
    dut.i_read_enable.value = 1
    dut.i_read_address.value = address
    await _tick(dut)
    dut.i_read_enable.value = 0
    for _ in range(READ_LATENCY - 1):
        await _tick(dut)
    return int(dut.o_read_data.value)


async def _read(dut: Any, address: int) -> int:
    return _word(dut, await _read_group(dut, address), address)


def _slots_per_row(data_width: int) -> int:
    granules = (data_width + 8) // 9
    if granules <= 1:
        return 8
    if granules <= 2:
        return 4
    if granules <= 4:
        return 2
    return 1


@cocotb.test()
async def test_packed_tag_uram(dut: Any) -> None:
    """Check packed tags against a model across writes and delayed reads."""
    _drive_idle(dut)
    dut.i_clk.value = 0
    await Timer(1, unit="ps")
    if os.environ.get("FROST_RANDOM_START_SEED"):
        branch = (
            "gen_clearable_storage"
            if os.environ["PACKED_TAG_TEST_BULK_CLEAR"] == "1"
            else "gen_hardware_storage"
        )
        memory = getattr(dut.gen_bank[0], branch).memory
        rows = [int(word.value) for word in memory]
        # The bulk-clear model can clear on the first evaluation edge before
        # bench inputs settle. Check startup entropy on the hardware model.
        if os.environ["PACKED_TAG_TEST_BULK_CLEAR"] != "1":
            assert len(set(rows)) > 1, "power-up rows share one random word"
            assert len({word >> 32 for word in rows}) > 1, (
                "wide rows lack random high bits"
            )
        digest = hashlib.sha256(repr(rows).encode()).hexdigest()
        dut._log.info("Power-up memory digest: %s", digest)
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    await _tick(dut)

    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    words = _read_words(dut)
    data_mask = (1 << data_width) - 1
    logical_depth = 1 << address_width
    slots_per_row = max(_slots_per_row(data_width), words)
    test_bulk_clear = os.environ["PACKED_TAG_TEST_BULK_CLEAR"] == "1"

    if test_bulk_clear:
        dut.i_bulk_clear.value = 1
        await _tick(dut)
        dut.i_bulk_clear.value = 0

    # Populate three complete rows. Reading these addresses later exercises
    # every lane and both sides of two physical-row boundaries.
    values = {
        address: ((address + 1) * 0x13579) & data_mask
        for address in range(min(logical_depth, 3 * slots_per_row))
    }
    for address, value in values.items():
        await _write(dut, address, value)
    for address, value in values.items():
        assert await _read(dut, address) == value

    # Overwriting one logical entry must not disturb any sibling sharing its
    # 72-bit row.
    sibling_row_base = slots_per_row
    overwritten_address = sibling_row_base + slots_per_row // 2
    replacement = 0x2AA55 & data_mask
    await _write(dut, overwritten_address, replacement)
    values[overwritten_address] = replacement
    for lane in range(slots_per_row):
        address = sibling_row_base + lane
        assert await _read(dut, address) == values[address]

    # Establish a known output, then check the exact request-to-data latency:
    # the target appears three clocks after the request, and the output holds
    # the marker until then.
    marker_address = 0
    target_address = slots_per_row + 1
    marker = values[marker_address]
    target = values[target_address]
    assert await _read(dut, marker_address) == marker
    dut.i_read_enable.value = 1
    dut.i_read_address.value = target_address
    await _tick(dut)
    dut.i_read_enable.value = 0
    assert _output(dut, marker_address) == marker
    await _tick(dut)
    assert _output(dut, marker_address) == marker
    await _tick(dut)
    assert _output(dut, target_address) == target

    # Back-to-back requests may select different lanes and rows. A gap has no
    # response and therefore holds the preceding output rather than replaying
    # stale row data through the final group-select register.
    addresses = (0, slots_per_row - 1, 2 * slots_per_row)
    dut.i_read_enable.value = 1
    dut.i_read_address.value = addresses[0]
    await _tick(dut)
    dut.i_read_address.value = addresses[1]
    await _tick(dut)
    dut.i_read_enable.value = 0
    await _tick(dut)
    assert _output(dut, addresses[0]) == values[addresses[0]]
    dut.i_read_enable.value = 1
    dut.i_read_address.value = addresses[2]
    await _tick(dut)
    dut.i_read_enable.value = 0
    assert _output(dut, addresses[1]) == values[addresses[1]]
    await _tick(dut)
    assert _output(dut, addresses[1]) == values[addresses[1]]
    await _tick(dut)
    assert _output(dut, addresses[2]) == values[addresses[2]]

    # A same-address read/write collision is read-first: the outstanding read
    # returns the old tag while a later request sees the new tag.
    collision_address = 2 * slots_per_row - 1
    old_value = values[collision_address]
    new_value = (old_value ^ data_mask) & data_mask
    dut.i_read_enable.value = 1
    dut.i_read_address.value = collision_address
    _drive_write(dut, collision_address, new_value, None)
    await _tick(dut)
    dut.i_read_enable.value = 0
    dut.i_write_enable.value = 0
    for _ in range(READ_LATENCY - 1):
        await _tick(dut)
    assert _output(dut, collision_address) == old_value
    assert await _read(dut, collision_address) == new_value
    values[collision_address] = new_value

    if words > 1:
        # A read returns every word of its group, whichever word it names.
        group_base = 2 * words
        group = await _read_group(dut, group_base + words - 1)
        for word in range(words):
            assert _word(dut, group, group_base + word) == values[group_base + word]
        # A masked write updates exactly the masked words, with one value.
        fill = 0x1D2B3 & data_mask
        mask = 0b101 & ((1 << words) - 1)
        await _write(dut, group_base + 1, fill, mask)
        for word in range(words):
            if (mask >> word) & 1:
                values[group_base + word] = fill
        for word in range(words):
            address = group_base + word
            assert await _read(dut, address) == values[address]
        # Every word at once, as the cache's reset sweep clears a set.
        await _write(dut, group_base, 0, (1 << words) - 1)
        for word in range(words):
            values[group_base + word] = 0
            assert await _read(dut, group_base + word) == 0
        # The neighbouring groups are untouched.
        for address in (group_base - 1, group_base + words):
            if address in values:
                assert await _read(dut, address) == values[address]

    if test_bulk_clear:
        # Clear wins over a simultaneous write and clears every physical row.
        dut.i_bulk_clear.value = 1
        _drive_write(dut, collision_address, data_mask, (1 << words) - 1)
        await _tick(dut)
        dut.i_bulk_clear.value = 0
        dut.i_write_enable.value = 0
        for address in values:
            assert await _read(dut, address) == 0
