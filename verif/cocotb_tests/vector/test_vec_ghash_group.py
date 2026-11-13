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

"""Check vec_ghash_group against two GHASH models.

The first model follows the Zvkg specification's algorithm (bytes bit-reversed,
shift left, reduce with 0x87); the second is the GCM specification's
right-shift algorithm on the unreversed block. They are compared with each
other on random values before the bench starts. Random operands then run
through vghsh and vgmul back to back; each result is compared four cycles
after the cycle that takes the input.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 4
M128 = (1 << 128) - 1


def brev8(x: int) -> int:
    """Reverse the bits of every byte of a 128-bit value."""
    out = 0
    for i in range(16):
        b = (x >> (8 * i)) & 0xFF
        out |= int(f"{b:08b}"[::-1], 2) << (8 * i)
    return out


def zvkg(y: int, h: int, x: int, gmul: bool) -> int:
    """Return vghsh or vgmul as the Zvkg specification's algorithm computes it."""
    s = brev8(y if gmul else y ^ x)
    hh = brev8(h)
    z = 0
    for bit in range(128):
        if (s >> bit) & 1:
            z ^= hh
        reduce = hh >> 127
        hh = (hh << 1) & M128
        if reduce:
            hh ^= 0x87
    return brev8(z)


def gcm_mult(x: bytes, y: bytes) -> bytes:
    """Return the GCM specification's product of two 16-byte blocks."""
    xi = int.from_bytes(x, "big")
    v = int.from_bytes(y, "big")
    z = 0
    r = 0xE1 << 120
    for i in range(127, -1, -1):
        if (xi >> i) & 1:
            z ^= v
        v = (v >> 1) ^ r if v & 1 else v >> 1
    return z.to_bytes(16, "big")


def check_models(rng: random.Random) -> None:
    """Check that the two models agree; element groups hold bytes in memory order."""
    for _ in range(200):
        y, h = rng.getrandbits(128), rng.getrandbits(128)
        a = zvkg(y, h, 0, True)
        b = int.from_bytes(
            gcm_mult(y.to_bytes(16, "little"), h.to_bytes(16, "little")), "little"
        )
        assert a == b, f"models disagree: {a:#x} {b:#x}"


@cocotb.test()
async def test_vec_ghash_group_random(dut: Any) -> None:
    """Vghsh and vgmul on random values, back to back."""
    rng = random.Random(2034)
    check_models(rng)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_gmul", "i_vd", "i_vs2", "i_vs1"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 3000
    pending: dict[int, tuple[int, int, int, int, int]] = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            gmul = rng.getrandbits(1)
            y, h, x = (rng.getrandbits(128) for _ in range(3))
            if rng.random() < 0.05:
                h = rng.choice([0, 1, M128])
            dut.i_valid.value = 1
            dut.i_gmul.value = gmul
            dut.i_vd.value = y
            dut.i_vs2.value = h
            dut.i_vs1.value = x
            pending[cycle] = (gmul, y, h, x, zvkg(y, h, x, bool(gmul)))
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            gmul, y, h, x, want = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got = int(dut.o_result.value)
            assert got == want, (
                f"gmul={gmul} y={y:#x} h={h:#x} x={x:#x}: {got:#x} want {want:#x}"
            )
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} GHASH operations checked")
