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

"""Check the L0 load cache against a direct-mapped Python model."""

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
        "i_fill_write",
        "i_fill_addr",
        "i_fill_data",
        "i_invalidate_valid",
        "i_invalidate_addr",
        "i_store_data",
        "i_store_strb",
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
        store: tuple[int, int, int] | None = None,
    ) -> None:
        if store is not None:
            invalidates = (store[0], invalidates[1])
            suppress = store[0]
        dut.i_store_data.value = store[1] if store else 0
        dut.i_store_strb.value = store[2] if store else 0
        prior = entries.get((store[0] // 8) % depth) if store else None
        update_store = (
            store is not None
            and store[2] != 0
            and (store[2] == 255 or (prior is not None and prior[0] == store[0] // 8))
        )
        dut.i_lookup_addr.value = lookup
        dut.i_fill_valid.value = fill is not None
        dut.i_fill_write.value = fill is not None
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
            if update_store:
                assert store is not None
                mask = sum(
                    255 << (8 * lane) for lane in range(8) if store[2] & (1 << lane)
                )
                previous = (
                    prior[1] if prior is not None and prior[0] == store[0] // 8 else 0
                )
                entries[(store[0] // 8) % depth] = (
                    store[0] // 8,
                    (previous & ~mask) | (store[1] & mask),
                )
            elif fill:
                entries[(fill[0] // 8) % depth] = (fill[0] // 8, fill[1])
            for port, address in enumerate(invalidates):
                if port == 0 and update_store:
                    continue
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
    # Full stores allocate without a read. Every partial byte mask preserves
    # the other lanes, and a store owns the write port over a coincident fill.
    address = 0x80001000
    await cycle(address, store=(address, 0x0123456789ABCDEF, 255))
    for mask in range(1, 256):
        await cycle(
            address,
            (address ^ (depth * 8), rng.getrandbits(64)),
            store=(address, rng.getrandbits(64), mask),
        )
        await cycle(address)

    # Cold partial writes must not allocate unknown bytes. AMO and DMA
    # invalidations still win over a store's cache update.
    await cycle(address, flush=True)
    await cycle(address, store=(address, 17, 1))
    await cycle(address)
    await cycle(address, invalidates=(None, address), store=(address, 22, 255))
    await cycle(address)
    await cycle(address, line=address, store=(address, 33, 255))
    await cycle(address)
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
            store=(other, rng.getrandbits(64), rng.randrange(256))
            if rng.randrange(2)
            else None,
        )
        await cycle(address)


@cocotb.test()
async def test_fill_collision_priorities(dut: Any) -> None:
    """Concurrent invalidations and store updates preserve the visible dword data."""
    depth = int(os.environ["FROST_TEST_L0_DEPTH"])

    async def step(**values: int) -> None:
        dut.i_clk.value = 0
        for name, value in values.items():
            getattr(dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        dut.i_clk.value = 1
        await Timer(5, unit="ns")

    await step(
        rst_n=0,
        lookup_addr=0,
        fill_valid=0,
        fill_write=0,
        fill_addr=0,
        fill_data=0,
        invalidate_valid=0,
        invalidate_addr=0,
        store_data=0,
        store_strb=0,
        invalidate2_valid=0,
        invalidate2_addr=0,
        lookup_invalidate_valid=0,
        lookup_invalidate_addr=0,
        invalidate_line_valid=0,
        invalidate_line_addr=0,
        flush_all=0,
    )
    await step(rst_n=1)
    address = 0x80002000
    for lane in range(4):
        await step(
            fill_valid=1, fill_write=1, fill_addr=address + 8 * lane, fill_data=lane + 1
        )
    # An alias has a different tag but the same four DMA invalidation indexes.
    await step(
        fill_addr=address + 24,
        fill_data=0xDEAD,
        invalidate_line_valid=1,
        invalidate_line_addr=address ^ (depth * 8),
    )
    for lane in range(4):
        await step(
            fill_valid=0,
            fill_write=0,
            invalidate_line_valid=0,
            lookup_addr=address + 8 * lane,
        )
        assert not int(dut.o_lookup_hit.value), "DMA alias left a dword valid"
    await step(
        fill_valid=1,
        fill_write=1,
        fill_addr=address,
        fill_data=0xBAD,
        invalidate2_valid=1,
        invalidate2_addr=address,
        lookup_addr=address,
    )
    await step(fill_valid=0, fill_write=0, invalidate2_valid=0)
    assert not int(dut.o_lookup_hit.value), "AMO invalidation lost to the fill"
    original = 0x0123456789ABCDEF
    await step(fill_valid=1, fill_write=1, fill_addr=address, fill_data=original)
    await step(fill_addr=address + 8, fill_data=0x11223344)
    await step(
        fill_data=0xDEADBEEF,
        invalidate_valid=1,
        invalidate_addr=address,
        store_data=0xFEDCBA9876543210,
        store_strb=0xA5,
    )
    await step(fill_valid=0, fill_write=0, invalidate_valid=0, store_strb=0)
    assert int(dut.o_lookup_hit.value)
    mask = 0xFF00FF0000FF00FF
    assert int(dut.o_lookup_data.value) == (original & ~mask) | (
        0xFEDCBA9876543210 & mask
    )
    await step(lookup_addr=address + 8)
    assert int(dut.o_lookup_hit.value)
    assert int(dut.o_lookup_data.value) == 0x11223344, "displaced fill changed data"
