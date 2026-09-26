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

"""Unit tests for the L0 load cache (lq_l0_cache).

A Python model of the direct-mapped array checks every lookup: capacity,
replacement, fill data, MMIO misses, the two per-address invalidation ports,
the DMA line port, same-cycle hit suppression, and flush.
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


@cocotb.test()
async def test_capacity_and_coherence(dut: Any) -> None:
    """Fill and read back every index, clear each DMA line, then run random traffic."""
    depth = int(os.environ["FROST_TEST_L0_DEPTH"])
    rng = random.Random(0xCA_C4E)
    Clock(dut.i_clk, 10, unit="ns").start()
    entries: dict[int, tuple[int, int]] = {}
    dut.i_rst_n.value = 0
    for name in (
        "i_lookup_addr",
        "i_fill_valid",
        "i_fill_addr",
        "i_fill_data",
        "i_invalidate_valid",
        "i_invalidate_addr",
        "i_invalidate2_valid",
        "i_invalidate2_addr",
        "i_lookup_invalidate_valid",
        "i_lookup_invalidate_addr",
        "i_invalidate_line_valid",
        "i_invalidate_line_addr",
        "i_flush_all",
    ):
        getattr(dut, name).value = 0
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    async def cycle(
        lookup: int,
        fill: tuple[int, int] | None = None,
        invalidates: tuple[int | None, int | None] = (None, None),
        suppress: int | None = None,
        line: int | None = None,
        flush: bool = False,
    ) -> None:
        dut.i_lookup_addr.value = lookup
        dut.i_fill_valid.value = fill is not None
        dut.i_fill_addr.value = fill[0] if fill else 0
        dut.i_fill_data.value = fill[1] if fill else 0
        for prefix, address in zip(("i_invalidate", "i_invalidate2"), invalidates):
            getattr(dut, prefix + "_valid").value = address is not None
            getattr(dut, prefix + "_addr").value = address or 0
        dut.i_lookup_invalidate_valid.value = suppress is not None
        dut.i_lookup_invalidate_addr.value = suppress or 0
        dut.i_invalidate_line_valid.value = line is not None
        dut.i_invalidate_line_addr.value = line or 0
        dut.i_flush_all.value = flush
        await Timer(1, unit="ns")
        saved = entries.get((lookup // 8) % depth)
        hit = (lookup >> 30) != 1 and saved is not None and saved[0] == lookup // 8
        hit = hit and (suppress is None or suppress // 8 != lookup // 8)
        hit = hit and (
            line is None or (line // 32) % (depth // 4) != (lookup // 32) % (depth // 4)
        )
        assert bool(dut.o_lookup_hit.value) == hit, f"lookup {lookup:#x}, saved={saved}"
        if hit:
            assert saved is not None
            assert int(dut.o_lookup_data.value) == saved[1]
        await RisingEdge(dut.i_clk)
        if flush:
            entries.clear()
        else:
            if fill:
                entries[(fill[0] // 8) % depth] = (fill[0] // 8, fill[1])
            for address in invalidates:
                if address is not None:
                    index = (address // 8) % depth
                    if index in entries and entries[index][0] == address // 8:
                        del entries[index]
            if line is not None:
                for index in list(entries):
                    if index // 4 == (line // 32) % (depth // 4):
                        del entries[index]
        await FallingEdge(dut.i_clk)

    # No two indexes may alias. At 256 entries this checks that address bit 10,
    # the top index bit, keeps the two halves apart.
    for index in range(depth):
        await cycle(
            0x8000_0000 + index * 8, (0x8000_0000 + index * 8, rng.getrandbits(64))
        )
    for index in range(depth):
        await cycle(0x8000_0000 + index * 8)
    # A DMA line invalidation clears all four dwords of the line, including the
    # top index group, and wins over a same-cycle fill into the line.
    for index in range(0, depth, 4):
        address = 0x8000_0000 + index * 8
        await cycle(address, (address + 24, rng.getrandbits(64)), line=address)
        for lane in range(4):
            await cycle(address + lane * 8)
    addresses = [
        base + index * 8
        for base in (0, 0x4000_0000, 0x8000_0000)
        for index in range(depth * 2)
    ]
    for _ in range(2500):
        address = rng.choice(addresses)
        other = rng.choice((address, address ^ (depth * 8), rng.choice(addresses)))
        fill = (address, rng.getrandbits(64)) if rng.randrange(3) else None
        inv1 = other if rng.randrange(4) == 0 else None
        inv2 = address if rng.randrange(5) == 0 else None
        line = other if rng.randrange(6) == 0 else None
        await cycle(
            rng.choice((address, other)),
            fill,
            (inv1, inv2),
            inv1,
            line,
            flush=rng.randrange(100) == 0,
        )
        await cycle(address)
