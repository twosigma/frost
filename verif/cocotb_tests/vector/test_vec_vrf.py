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

"""Check vec_vrf against a Python model of a byte-enabled register file.

The bench first writes every entry in full, then drives every write port and
read port every cycle with random addresses, data and byte enables, often
aimed at a few entries so ports collide. A read returns the entry as it was
before the writes on the same edge; when two ports write the same byte on one
edge, the higher-numbered port wins. Runs at the parameters the build sets.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


def pack(values: list[int], width: int) -> int:
    """Pack values, element 0 lowest."""
    return sum(v << (width * i) for i, v in enumerate(values))


@cocotb.test()
async def test_vec_vrf_random(dut: Any) -> None:
    """Random concurrent reads and byte-enabled writes."""
    nw = len(dut.i_we)
    width = len(dut.i_wdata) // nw
    nr = len(dut.o_rdata) // width
    depth = 1 << (len(dut.i_waddr) // nw)
    nbytes = width // 8
    abits = (depth - 1).bit_length()
    rng = random.Random(2035)
    Clock(dut.i_clk, 2, unit="ns").start()
    model = [0] * depth

    async def edge(writes: list[tuple[int, int, int, int]], reads: list[int]) -> None:
        dut.i_we.value = pack([w[0] for w in writes], 1)
        dut.i_waddr.value = pack([w[1] for w in writes], abits)
        dut.i_wdata.value = pack([w[2] for w in writes], width)
        dut.i_wbe.value = pack([w[3] for w in writes], nbytes)
        dut.i_raddr.value = pack(reads, abits)
        await RisingEdge(dut.i_clk)

    for a in range(depth):  # fill every entry through port 0
        data = rng.getrandbits(width)
        writes = [(1, a, data, (1 << nbytes) - 1)] + [(0, 0, 0, 0)] * (nw - 1)
        await FallingEdge(dut.i_clk)
        await edge(writes, [0] * nr)
        model[a] = data

    checked = 0
    for _ in range(3000):
        await FallingEdge(dut.i_clk)
        hot = [rng.randrange(depth) for _ in range(2)]
        writes = []
        for _w in range(nw):
            we = int(rng.random() < 0.7)
            addr = rng.choice(hot) if rng.random() < 0.5 else rng.randrange(depth)
            writes.append((we, addr, rng.getrandbits(width), rng.getrandbits(nbytes)))
        reads = [
            rng.choice(hot) if rng.random() < 0.5 else rng.randrange(depth)
            for _ in range(nr)
        ]
        expect = pack([model[a] for a in reads], width)  # before this edge's writes
        await edge(writes, reads)
        await ReadOnly()
        got = int(dut.o_rdata.value)
        assert got == expect, f"read {got:#x} want {expect:#x}"
        checked += 1
        for we, addr, data, be in writes:  # ascending port order: higher wins
            if we:
                for b in range(nbytes):
                    if (be >> b) & 1:
                        mask = 0xFF << (8 * b)
                        model[addr] = (model[addr] & ~mask) | (data & mask)
    dut._log.info(
        f"{checked} read cycles checked at depth {depth}, width {width}, {nr}R{nw}W"
    )
