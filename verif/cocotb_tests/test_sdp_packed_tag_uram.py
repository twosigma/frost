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

"""Direct tests for the width-generic packed tag UltraRAM wrapper.

The registry runs this bench at the two integration-relevant widths: 13-bit
entries packed four per row through both storage branches (including the exact
production address geometry), and 22-bit entries packed two per row through
the ordinary portable hardware branch.
"""

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


def _drive_idle(dut: Any) -> None:
    dut.i_write_enable.value = 0
    dut.i_bulk_clear.value = 0
    dut.i_write_address.value = 0
    dut.i_write_data.value = 0
    dut.i_read_enable.value = 0
    dut.i_read_address.value = 0


async def _write(dut: Any, address: int, data: int) -> None:
    dut.i_write_enable.value = 1
    dut.i_write_address.value = address
    dut.i_write_data.value = data
    await _tick(dut)
    dut.i_write_enable.value = 0


async def _read(dut: Any, address: int) -> int:
    dut.i_read_enable.value = 1
    dut.i_read_address.value = address
    await _tick(dut)
    dut.i_read_enable.value = 0
    for _ in range(READ_LATENCY - 1):
        await _tick(dut)
    return int(dut.o_read_data.value)


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
    """Cover packing, timing, collisions, gaps, and optional bulk clear."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _drive_idle(dut)
    await _tick(dut)

    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    data_mask = (1 << data_width) - 1
    logical_depth = 1 << address_width
    slots_per_row = _slots_per_row(data_width)
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
    assert int(dut.o_read_data.value) == marker
    await _tick(dut)
    assert int(dut.o_read_data.value) == marker
    await _tick(dut)
    assert int(dut.o_read_data.value) == target

    # Back-to-back requests may select different lanes and rows. A gap has no
    # response and therefore holds the preceding output rather than replaying
    # stale row data through the final lane-select register.
    addresses = (0, slots_per_row - 1, 2 * slots_per_row)
    dut.i_read_enable.value = 1
    dut.i_read_address.value = addresses[0]
    await _tick(dut)
    dut.i_read_address.value = addresses[1]
    await _tick(dut)
    dut.i_read_enable.value = 0
    await _tick(dut)
    assert int(dut.o_read_data.value) == values[addresses[0]]
    dut.i_read_enable.value = 1
    dut.i_read_address.value = addresses[2]
    await _tick(dut)
    dut.i_read_enable.value = 0
    assert int(dut.o_read_data.value) == values[addresses[1]]
    await _tick(dut)
    assert int(dut.o_read_data.value) == values[addresses[1]]
    await _tick(dut)
    assert int(dut.o_read_data.value) == values[addresses[2]]

    # A same-address read/write collision is read-first: the outstanding read
    # returns the old tag while a later request sees the new tag.
    collision_address = 2 * slots_per_row - 1
    old_value = values[collision_address]
    new_value = (old_value ^ data_mask) & data_mask
    dut.i_read_enable.value = 1
    dut.i_read_address.value = collision_address
    dut.i_write_enable.value = 1
    dut.i_write_address.value = collision_address
    dut.i_write_data.value = new_value
    await _tick(dut)
    dut.i_read_enable.value = 0
    dut.i_write_enable.value = 0
    for _ in range(READ_LATENCY - 1):
        await _tick(dut)
    assert int(dut.o_read_data.value) == old_value
    assert await _read(dut, collision_address) == new_value

    if test_bulk_clear:
        # Clear wins over a simultaneous write and clears every physical row.
        dut.i_bulk_clear.value = 1
        dut.i_write_enable.value = 1
        dut.i_write_address.value = collision_address
        dut.i_write_data.value = data_mask
        await _tick(dut)
        dut.i_bulk_clear.value = 0
        dut.i_write_enable.value = 0
        for address in values:
            assert await _read(dut, address) == 0
