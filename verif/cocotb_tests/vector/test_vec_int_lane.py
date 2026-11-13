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

"""Check vec_int_lane against a Python model of each operation.

Every cycle presents a random operation, element width, operand pair and
merge mask. Each result is compared three cycles later, so the bench also
checks that the latency is fixed for every operation. Directed operands
(zero, all ones, the signed limits, single bits) are mixed into the random
ones so carries, sign boundaries and full shifts are exercised.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

# Inputs taken on one rising edge appear after the second rising edge that follows.
LATENCY = 2
OPS = {
    "ADD": 0,
    "SUB": 1,
    "RSUB": 2,
    "AND": 3,
    "OR": 4,
    "XOR": 5,
    "ANDN": 6,
    "MINU": 7,
    "MIN": 8,
    "MAXU": 9,
    "MAX": 10,
    "SLL": 11,
    "SRL": 12,
    "SRA": 13,
    "ROL": 14,
    "ROR": 15,
    "MERGE": 16,
    "MV": 17,
    "BREV": 18,
    "BREV8": 19,
    "REV8": 20,
    "CLZ": 21,
    "CTZ": 22,
    "CPOP": 23,
    "MSEQ": 24,
    "MSNE": 25,
    "MSLTU": 26,
    "MSLT": 27,
    "MSLEU": 28,
    "MSLE": 29,
    "MSGTU": 30,
    "MSGT": 31,
}
COMPARES = {"MSEQ", "MSNE", "MSLTU", "MSLT", "MSLEU", "MSLE", "MSGTU", "MSGT"}


def signed(x: int, w: int) -> int:
    """Return x as a signed w-bit value."""
    return x - (1 << w) if x >> (w - 1) else x


def element(op: str, a: int, b: int, m: int, w: int) -> tuple[int, int]:
    """Return (result, mask bit) for one element of width w."""
    mask = (1 << w) - 1
    sh = b & (w - 1)
    sa, sb = signed(a, w), signed(b, w)
    if op in COMPARES:
        flag = {
            "MSEQ": a == b,
            "MSNE": a != b,
            "MSLTU": a < b,
            "MSLT": sa < sb,
            "MSLEU": a <= b,
            "MSLE": sa <= sb,
            "MSGTU": a > b,
            "MSGT": sa > sb,
        }[op]
        return 0, int(flag)
    if op == "ADD":
        r = a + b
    elif op == "SUB":
        r = a - b
    elif op == "RSUB":
        r = b - a
    elif op == "AND":
        r = a & b
    elif op == "OR":
        r = a | b
    elif op == "XOR":
        r = a ^ b
    elif op == "ANDN":
        r = a & ~b
    elif op == "MINU":
        r = min(a, b)
    elif op == "MIN":
        r = a if sa < sb else b
    elif op == "MAXU":
        r = max(a, b)
    elif op == "MAX":
        r = a if sa >= sb else b
    elif op == "SLL":
        r = a << sh
    elif op == "SRL":
        r = a >> sh
    elif op == "SRA":
        r = sa >> sh
    elif op == "ROL":
        r = (a << sh) | (a >> (w - sh)) if sh else a
    elif op == "ROR":
        r = (a >> sh) | (a << (w - sh)) if sh else a
    elif op == "MERGE":
        r = b if m else a
    elif op == "MV":
        r = b
    elif op == "BREV":
        r = int(f"{a:0{w}b}"[::-1], 2)
    elif op == "BREV8":
        r = 0
        for k in range(w // 8):
            byte = (a >> (8 * k)) & 0xFF
            r |= int(f"{byte:08b}"[::-1], 2) << (8 * k)
    elif op == "REV8":
        r = int.from_bytes(a.to_bytes(w // 8, "little"), "big")
    elif op == "CLZ":
        r = w - a.bit_length()
    elif op == "CTZ":
        r = w if a == 0 else (a & -a).bit_length() - 1
    elif op == "CPOP":
        r = bin(a).count("1")
    else:
        raise ValueError(op)
    return r & mask, 0


def lane(op: str, sew: int, a: int, b: int, mask_in: int) -> tuple[int, int]:
    """Return the lane's (result, mask) for one input."""
    w = 8 << sew
    n = 64 // w
    result = 0
    mask_out = 0
    for k in range(n):
        ea = (a >> (w * k)) & ((1 << w) - 1)
        eb = (b >> (w * k)) & ((1 << w) - 1)
        r, f = element(op, ea, eb, (mask_in >> k) & 1, w)
        result |= r << (w * k)
        mask_out |= f << k
    return result, mask_out


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
    if pick < 0.2:
        return rng.choice(SPECIAL)
    if pick < 0.3:
        return 1 << rng.randrange(64)
    if pick < 0.4:
        v = rng.getrandbits(64)
        return v & ~(rng.getrandbits(64))  # many zero bytes
    return rng.getrandbits(64)


@cocotb.test()
async def test_vec_int_lane_random(dut: Any) -> None:
    """Every operation at every element width, then random back-to-back operations."""
    rng = random.Random(2026)
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_op.value = 0
    dut.i_sew.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_mask.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    names = list(OPS)
    sweep = 8 * len(names)  # each operation at each width, twice
    count = 6000
    pending = {}  # input cycle -> expectation
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            if cycle < sweep:
                op, sew = names[cycle % len(names)], (cycle // len(names)) % 4
            else:
                op, sew = rng.choice(names), rng.randrange(4)
            a, b = operand(rng), operand(rng)
            if rng.random() < 0.1:
                b = a  # equal operands for compares and min/max ties
            m = rng.getrandbits(8)
            dut.i_valid.value = 1
            dut.i_op.value = OPS[op]
            dut.i_sew.value = sew
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_mask.value = m
            pending[cycle] = (op, sew, a, b, m) + lane(op, sew, a, b, m)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, sew, a, b, m, r, f = pending.pop(origin)
            assert int(dut.o_valid.value) == 1, (
                f"no result for {op} from cycle {origin}"
            )
            got_r = int(dut.o_result.value)
            got_f = int(dut.o_mask.value)
            assert got_r == r and got_f == f, (
                f"{op} sew={8 << sew} a={a:#018x} b={b:#018x} m={m:#04x}: "
                f"result {got_r:#018x} mask {got_f:#04x}, want {r:#018x} {f:#04x}"
            )
            checked += 1
        elif origin >= 0:
            assert int(dut.o_valid.value) == 0, f"unexpected result at cycle {cycle}"
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} operations checked")
