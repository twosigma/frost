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

"""Check vec_mul_lane against a Python model of each operation.

Every cycle presents a random operation, element width and operand triple;
each result is compared six cycles after the cycle that takes its input,
which also checks the fixed latency. Directed operands (zero, one, all ones,
the signed limits) are mixed in so the sign and overflow cases of every
element width are reached. The wide products are checked at SEW 8, 16 and 32
for the three signedness forms.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 6
OPS = {"MUL": 0, "MULH": 1, "MULHU": 2, "MULHSU": 3, "MACC": 4, "NMSAC": 5}


def signed(x: int, w: int) -> int:
    """Return x as a signed w-bit value."""
    return x - (1 << w) if x >> (w - 1) else x


def lane(op: str, sew: int, x: int, y: int, z: int) -> tuple[int, int]:
    """Return the lane's (result, wide) for one input."""
    w = 8 << sew
    n = 64 // w
    mask = (1 << w) - 1
    xs = op in ("MULH", "MULHSU")
    ys = op == "MULH"
    result = 0
    wide = 0
    for k in range(n):
        ex = (x >> (w * k)) & mask
        ey = (y >> (w * k)) & mask
        ez = (z >> (w * k)) & mask
        px = signed(ex, w) if xs else ex
        py = signed(ey, w) if ys else ey
        prod = (px * py) & ((1 << (2 * w)) - 1)
        if op == "MUL":
            r = prod & mask
        elif op in ("MULH", "MULHU", "MULHSU"):
            r = prod >> w
        elif op == "MACC":
            r = (ez + prod) & mask
        else:
            r = (ez - prod) & mask
        result |= r << (w * k)
        if w < 64:
            wide |= prod << (2 * w * k)
    return result, wide


SPECIAL = [
    0,
    1,
    0xFF,
    0x80,
    0x7F,
    0x8000,
    0x7FFF,
    0x80000000,
    0x7FFFFFFF,
    1 << 63,
    (1 << 63) - 1,
    (1 << 64) - 1,
]


def operand(rng: random.Random) -> int:
    """Return a random or directed 64-bit operand."""
    pick = rng.random()
    if pick < 0.25:
        return rng.choice(SPECIAL)
    if pick < 0.35:
        return int.from_bytes(
            bytes(rng.choice([0x00, 0xFF, 0x80, 0x7F]) for _ in range(8)), "little"
        )
    return rng.getrandbits(64)


@cocotb.test()
async def test_vec_mul_lane_random(dut: Any) -> None:
    """Every operation at every element width, then random back-to-back operations."""
    rng = random.Random(2027)
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_op.value = 0
    dut.i_sew.value = 0
    dut.i_x.value = 0
    dut.i_y.value = 0
    dut.i_z.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    names = list(OPS)
    sweep = 8 * len(names)
    count = 5000
    pending = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            if cycle < sweep:
                op, sew = names[cycle % len(names)], (cycle // len(names)) % 4
            else:
                op, sew = rng.choice(names), rng.randrange(4)
            x, y, z = operand(rng), operand(rng), operand(rng)
            dut.i_valid.value = 1
            dut.i_op.value = OPS[op]
            dut.i_sew.value = sew
            dut.i_x.value = x
            dut.i_y.value = y
            dut.i_z.value = z
            pending[cycle] = (op, sew, x, y, z) + lane(op, sew, x, y, z)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, sew, x, y, z, r, wide = pending.pop(origin)
            assert int(dut.o_valid.value) == 1, (
                f"no result for {op} from cycle {origin}"
            )
            got_r = int(dut.o_result.value)
            assert got_r == r, (
                f"{op} sew={8 << sew} x={x:#018x} y={y:#018x} z={z:#018x}: "
                f"result {got_r:#018x}, want {r:#018x}"
            )
            if op in ("MULH", "MULHU", "MULHSU") and sew < 3:
                got_w = int(dut.o_wide.value)
                assert got_w == wide, (
                    f"{op} sew={8 << sew}: wide {got_w:#034x}, want {wide:#034x}"
                )
            checked += 1
        elif origin >= 0:
            assert int(dut.o_valid.value) == 0, f"unexpected result at cycle {cycle}"
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} operations checked")
