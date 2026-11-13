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

"""Check vec_red_unit against a Python model of each reduction.

Random reductions of one to eight steps run back to back; each step's running
value is compared five cycles after the cycle that takes it. Inactive elements
must act as the operation's identity, and the scalar operand enters only on an
instruction's first step.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 5
OPS = {
    "SUM": 0,
    "AND": 1,
    "OR": 2,
    "XOR": 3,
    "MINU": 4,
    "MIN": 5,
    "MAXU": 6,
    "MAX": 7,
    "WSUMU": 8,
    "WSUM": 9,
}


def signed(x: int, w: int) -> int:
    """Return x as a signed w-bit value."""
    return x - (1 << w) if x >> (w - 1) else x


def reduce_steps(
    op: str, sew: int, init: int, steps: list[tuple[int, int]]
) -> list[int]:
    """Return the running value after each step."""
    w = 8 << sew
    n = 64 // w
    widen = op in ("WSUMU", "WSUM")
    aw = 2 * w if widen else w
    sgn = op in ("MIN", "MAX", "WSUM")
    acc = signed(init & ((1 << aw) - 1), aw) if sgn else init & ((1 << aw) - 1)
    out = []
    for word, act in steps:
        for k in range(n):
            if not (act >> k) & 1:
                continue
            e = (word >> (w * k)) & ((1 << w) - 1)
            if sgn:
                e = signed(e, w)
            if op in ("SUM", "WSUMU", "WSUM"):
                acc = acc + e
            elif op == "AND":
                acc &= e
            elif op == "OR":
                acc |= e
            elif op == "XOR":
                acc ^= e
            elif op in ("MINU", "MIN"):
                acc = min(acc, e)
            else:
                acc = max(acc, e)
        out.append(acc & ((1 << aw) - 1))
    return out


def word_value(rng: random.Random) -> int:
    """Return an element word with frequent extreme values."""
    if rng.random() < 0.3:
        return int.from_bytes(
            bytes(rng.choice([0, 0xFF, 0x80, 0x7F]) for _ in range(8)), "little"
        )
    return rng.getrandbits(64)


@cocotb.test()
async def test_vec_red_unit_random(dut: Any) -> None:
    """Random reductions back to back."""
    rng = random.Random(2029)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_first", "i_op", "i_sew", "i_word", "i_act", "i_init"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    feed = []
    names = list(OPS)
    for i in range(1500):
        op = names[i % len(names)] if i < 4 * len(names) else rng.choice(names)
        sew = rng.randrange(3) if op in ("WSUMU", "WSUM") else rng.randrange(4)
        init = word_value(rng)
        steps = [
            (word_value(rng), rng.choice([0xFF, rng.getrandbits(8), 0]))
            for _ in range(rng.randint(1, 8))
        ]
        for j, ((word, act), acc) in enumerate(
            zip(steps, reduce_steps(op, sew, init, steps))
        ):
            feed.append((j == 0, op, sew, word, act, init, acc))

    pending = {}
    checked = 0
    for cycle in range(len(feed) + LATENCY + 1):
        if cycle < len(feed):
            first, op, sew, word, act, init, acc = feed[cycle]
            dut.i_valid.value = 1
            dut.i_first.value = int(first)
            dut.i_op.value = OPS[op]
            dut.i_sew.value = sew
            dut.i_word.value = word
            dut.i_act.value = act
            dut.i_init.value = init
            pending[cycle] = (op, sew, word, act, init, acc)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, sew, word, act, init, acc = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got = int(dut.o_acc.value)
            assert got == acc, (
                f"{op} sew={8 << sew} word={word:#x} act={act:#x} init={init:#x}: {got:#x} want {acc:#x}"
            )
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == len(feed)
    dut._log.info(f"{checked} steps checked")
