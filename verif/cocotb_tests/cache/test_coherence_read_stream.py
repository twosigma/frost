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

"""Compare hint sequences with a sector-list model under colliding events."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def bounded_stream_reference(dut: Any) -> None:
    """Exercise confirmation, replacement, consume/advance collisions and page ends."""
    rng = random.Random(93)
    frontier: int | None = None
    confirmed = False
    pair_seen = False
    next_sector = 0
    dut.i_clk.value = 0
    for cycle in range(2400):
        reset = cycle == 0 or cycle % 311 == 0
        cancel = cycle % 97 == 0
        valid = bool(rng.randrange(4))
        miss = bool(rng.randrange(3))
        consume = bool(rng.randrange(2))
        if frontier is None or rng.randrange(9) == 0:
            address = rng.choice([0x123456780000, 0x80000000]) + rng.choice(
                [0, 32, 4032, 4064]
            )
        else:
            address = frontier * 32 + rng.choice([0, 0, 32, 32, 32, -32, 64, 4096])
        dut.i_rst.value = int(reset)
        dut.i_cancel.value = int(cancel)
        dut.i_demand_valid.value = int(valid)
        dut.i_demand_miss.value = int(miss)
        dut.i_demand_addr.value = address
        dut.i_consume.value = int(consume)
        await Timer(1, unit="ns")
        sector = address // 32
        adjacent = (
            frontier is not None
            and sector == frontier + 1
            and sector // 128 == frontier // 128
        )
        repeated = frontier is not None and sector == frontier
        replacement = valid and miss and not repeated and not adjacent
        if cycle:
            expected = (
                confirmed
                and frontier is not None
                and next_sector // 128 == frontier // 128
                and 0 < next_sector - frontier <= 8
            )
            assert bool(dut.o_valid.value) == expected, cycle
            assert bool(dut.o_replace.value) == replacement, cycle
            if expected:
                assert int(dut.o_addr.value) == next_sector * 32, cycle
            if consume and expected:
                next_sector += 1
        if reset or cancel:
            frontier, confirmed, next_sector = None, False, 0
            pair_seen = False
        elif replacement:
            frontier, confirmed, next_sector = sector, False, sector + 1
            pair_seen = False
        elif valid and adjacent and (confirmed or miss):
            frontier = sector
            if not confirmed or next_sector <= frontier:
                next_sector = frontier + 1
            confirmed = confirmed or pair_seen
            pair_seen = True
        dut.i_clk.value = 1
        await Timer(1, unit="ns")
        dut.i_clk.value = 0
        await Timer(1, unit="ns")


@cocotb.test()
async def isolated_record_pairs_and_confirmation(dut: Any) -> None:
    """Reject isolated pairs at either alignment and confirm on the third miss."""
    dut.i_clk.value = 0

    async def step(address: int, miss: bool = True, cancel: bool = False) -> None:
        dut.i_rst.value = 0
        dut.i_cancel.value = int(cancel)
        dut.i_demand_valid.value = 1
        dut.i_demand_miss.value = int(miss)
        dut.i_demand_addr.value = address
        dut.i_consume.value = 0
        await Timer(1, unit="ns")
        dut.i_clk.value = 1
        await Timer(1, unit="ns")
        dut.i_clk.value = 0
        await Timer(1, unit="ns")

    for alignment in (0, 32):
        await step(0, cancel=True)
        for offset in (0x100, 0x700, 0x300, 0xB00):
            base = 0x123456780000 + offset + alignment
            await step(base)
            await step(base + 32, miss=False)
            assert int(dut.o_frontier.value) == base
            await step(base + 32)
            for address, miss in (
                (base + 32, True),
                (base + 40, False),
                (base + 64, False),
            ):
                await step(address, miss=miss)
                assert int(dut.o_frontier.value) == base + 32
                assert not int(dut.o_confirmed.value) and not int(dut.o_valid.value)
        await step(base + 64)
        assert int(dut.o_confirmed.value) and int(dut.o_addr.value) == base + 96
        await step(base + 96, miss=False)
        assert int(dut.o_confirmed.value) and int(dut.o_frontier.value) == base + 96
        await step(base + 128, cancel=True)
        for index in range(3):
            await step(base + 160 + 32 * index)
            assert bool(dut.o_confirmed.value) == (index == 2)
