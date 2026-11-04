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
        elif replacement:
            frontier, confirmed, next_sector = sector, False, sector + 1
        elif valid and adjacent and (confirmed or miss):
            frontier = sector
            if not confirmed or next_sector <= frontier:
                next_sector = frontier + 1
            confirmed = True
        dut.i_clk.value = 1
        await Timer(1, unit="ns")
        dut.i_clk.value = 0
        await Timer(1, unit="ns")
