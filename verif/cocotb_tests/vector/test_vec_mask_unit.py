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

"""Check vec_mask_unit against a Python model of each mask instruction.

Random instructions of one to eight steps run back to back, so the state that
spans the steps of one instruction restarts on every first step. Each step's
mask result and scalar are compared two cycles after the cycle that takes it.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 2
M64 = (1 << 64) - 1
OPS = {
    "AND": 0,
    "NAND": 1,
    "ANDN": 2,
    "XOR": 3,
    "OR": 4,
    "NOR": 5,
    "ORN": 6,
    "XNOR": 7,
    "CPOP": 8,
    "FIRST": 9,
    "SBF": 10,
    "SIF": 11,
    "SOF": 12,
    "IOTA": 13,
    "ID": 14,
}


def run_instruction(
    op: str, sew: int, steps: list[tuple[int, int, int]]
) -> list[tuple[int, int]]:
    """Return (result, scalar) for each step of one instruction."""
    out = []
    count = 0
    found = False
    index = 0
    base = 0
    n = 64 // (8 << sew)
    w = 8 << sew
    for a, b, act in steps:
        x = a & act
        result = 0
        scalar = 0
        if op in ("AND", "NAND", "ANDN", "XOR", "OR", "NOR", "ORN", "XNOR"):
            result = {
                "AND": a & b,
                "NAND": ~(a & b),
                "ANDN": a & ~b,
                "XOR": a ^ b,
                "OR": a | b,
                "NOR": ~(a | b),
                "ORN": a | ~b,
                "XNOR": ~(a ^ b),
            }[op] & M64
        elif op == "CPOP":
            count += bin(x).count("1")
            scalar = count
        elif op == "FIRST":
            if not found and x:
                found = True
                index = base + (x & -x).bit_length() - 1
            base += 64
            scalar = index if found else M64
        elif op in ("SBF", "SIF", "SOF"):
            if not found:
                if x:
                    low = x & -x
                    below = low - 1
                else:
                    low, below = 0, M64
                result = {"SBF": act & below, "SIF": act & (below | low), "SOF": low}[
                    op
                ]
            found = found or bool(x)
        elif op == "IOTA":
            run = 0
            for k in range(n):
                result |= ((count + run) & ((1 << w) - 1)) << (w * k)
                run += (x >> k) & 1
            count += run
        elif op == "ID":
            for k in range(n):
                result |= ((index + k) & ((1 << w) - 1)) << (w * k)
            index += n
        out.append((result & M64, scalar & M64))
    return out


def mask_word(rng: random.Random) -> int:
    """Return a mask word, often sparse or empty so the first-bit cases occur."""
    pick = rng.random()
    if pick < 0.2:
        return 0
    if pick < 0.5:
        return 1 << rng.randrange(64)
    if pick < 0.6:
        return M64
    return rng.getrandbits(64)


@cocotb.test()
async def test_vec_mask_unit_random(dut: Any) -> None:
    """Random mask instructions back to back."""
    rng = random.Random(2028)
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_first.value = 0
    dut.i_op.value = 0
    dut.i_sew.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_act.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    feed = []  # (first, op, sew, a, b, act, result, scalar)
    names = list(OPS)
    for i in range(1500):
        op = names[i % len(names)] if i < 4 * len(names) else rng.choice(names)
        sew = rng.randrange(4)
        steps = [
            (
                mask_word(rng),
                rng.getrandbits(64),
                rng.choice([M64, rng.getrandbits(64)]),
            )
            for _ in range(rng.randint(1, 8))
        ]
        for j, ((a, b, act), (r, sc)) in enumerate(
            zip(steps, run_instruction(op, sew, steps))
        ):
            feed.append((j == 0, op, sew, a, b, act, r, sc))

    pending = {}
    checked = 0
    for cycle in range(len(feed) + LATENCY + 1):
        if cycle < len(feed):
            first, op, sew, a, b, act, r, sc = feed[cycle]
            dut.i_valid.value = 1
            dut.i_first.value = int(first)
            dut.i_op.value = OPS[op]
            dut.i_sew.value = sew
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_act.value = act
            pending[cycle] = (op, sew, a, act, r, sc)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, sew, a, act, r, sc = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got_r, got_s = int(dut.o_result.value), int(dut.o_scalar.value)
            assert got_r == r, (
                f"{op} sew={8 << sew} a={a:#x} act={act:#x}: result {got_r:#x} want {r:#x}"
            )
            if op in ("CPOP", "FIRST"):
                assert got_s == sc, f"{op}: scalar {got_s:#x} want {sc:#x}"
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == len(feed)
    dut._log.info(f"{checked} steps checked")
