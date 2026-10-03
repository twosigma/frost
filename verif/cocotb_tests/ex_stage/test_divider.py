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

"""Check the iterative divider against integer division, cycle by cycle.

A model of the divider's control runs beside it and every cycle checks o_idle,
o_done and, while done, o_result. A result must appear exactly WIDTH steps
after its start (WIDTH/2 for a W form), stay until accepted, and equal the
RISC-V result, which the scoreboard computes with Python integer division:
quotient and remainder, signed and unsigned, divide by zero, signed overflow,
and W forms, whose operands are the low halves and whose result is
sign-extended. Operands change while an operation runs, and kills, accept
delays, back-to-back starts and a reset in flight are mixed in.
"""

import random
from dataclasses import dataclass
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


@dataclass
class Operation:
    """One divide: operands and op flags."""

    dividend: int
    divisor: int
    signed: bool
    word: bool
    rem: bool


def reference(op: Operation, width: int) -> int:
    """Return the RISC-V result of op at the given width."""
    half = width // 2
    size = half if op.word else width
    a = op.dividend & ((1 << size) - 1)
    b = op.divisor & ((1 << size) - 1)
    if op.signed:
        a = a - (1 << size) if a >> (size - 1) else a
        b = b - (1 << size) if b >> (size - 1) else b
    if b == 0:
        quotient, remainder = -1, a
    else:
        quotient = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            quotient = -quotient
        remainder = a - quotient * b
    result = remainder if op.rem else quotient
    if op.word:
        result &= (1 << half) - 1
        if result >> (half - 1):
            result -= 1 << half
    return result & ((1 << width) - 1)


def directed_operations(width: int, rng: random.Random) -> list[Operation]:
    """Corner operands for every op form, and divisors around each power of two."""
    operations = []
    for word in (False, True):
        size = width // 2 if word else width
        mask = (1 << size) - 1
        top = 1 << (size - 1)
        corners = (0, 1, 2, 3, 7, top - 1, top, top + 1, mask - 1, mask)
        for signed in (False, True):
            for rem in (False, True):
                for a in corners:
                    for b in corners:
                        operations.append(Operation(a, b, signed, word, rem))
        for bit in range(size):
            for delta in (-1, 0, 1):
                b = ((1 << bit) + delta) & mask
                for index, a in enumerate((0, mask, (b - 1) & mask, b, (b + 1) & mask)):
                    signed, rem = bool(index & 1), bool((bit + delta) & 1)
                    operations.append(Operation(a, b, signed, word, rem))
    for op in operations:
        # A W form must ignore the upper halves of its operands.
        if op.word:
            op.dividend |= rng.getrandbits(width // 2) << (width // 2)
            op.divisor |= rng.getrandbits(width // 2) << (width // 2)
    return operations


def random_operation(width: int, rng: random.Random) -> Operation:
    """Draw operands of random magnitude, so quotients of every length appear."""
    return Operation(
        rng.getrandbits(rng.randint(1, width)),
        rng.getrandbits(rng.randint(1, width)),
        rng.random() < 0.5,
        rng.random() < 0.3,
        rng.random() < 0.5,
    )


@cocotb.test()
async def test_divider_against_model(dut: Any) -> None:
    """Every cycle matches the control model, and every result the reference."""
    width = len(dut.i_dividend)
    mask = (1 << width) - 1
    rng = random.Random(0xD1_71_DE + width)
    operations = directed_operations(width, rng)
    # Kills and the reset hit only the random operations, so every directed
    # result is checked.
    first_random = len(operations)
    operations += [random_operation(width, rng) for _ in range(1500)]
    # One operation is reset five steps before its end.
    reset_operation = len(operations) - 700

    # Model state: "idle", "running" (steps_left more RUN cycles) or "done".
    state = "idle"
    steps_left = 0
    expected = 0
    started = completed = abandoned = cycle = 0

    dut.i_rst.value = 1
    dut.i_start.value = 0
    dut.i_kill.value = 0
    dut.i_accept.value = 0
    dut.i_is_signed.value = 0
    dut.i_is_word.value = 0
    dut.i_is_rem.value = 0
    dut.i_dividend.value = 0
    dut.i_divisor.value = 0
    Clock(dut.i_clk, 10, unit="ns").start()
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    while started < len(operations) or state != "idle":
        start = kill = accept = reset = False
        # Random operands while nothing starts: a running operation must
        # ignore its inputs.
        op = random_operation(width, rng)
        if state == "idle":
            if started < len(operations) and rng.random() < 0.8:
                op = operations[started]
                start = True
            else:
                kill = rng.random() < 0.1  # Nothing to kill: no effect
        elif state == "running":
            reset = started - 1 == reset_operation and steps_left == 5
            kill = started > first_random and rng.random() < 0.003
        else:
            accept = rng.random() < 0.6
            kill = started > first_random and rng.random() < 0.05

        dut.i_rst.value = int(reset)
        dut.i_start.value = int(start)
        dut.i_kill.value = int(kill)
        dut.i_accept.value = int(accept)
        dut.i_is_signed.value = int(op.signed)
        dut.i_is_word.value = int(op.word)
        dut.i_is_rem.value = int(op.rem)
        dut.i_dividend.value = op.dividend & mask
        dut.i_divisor.value = op.divisor & mask

        # The model's next state, in the divider's priority order.
        if reset or kill:
            abandoned += int(state != "idle")
            state = "idle"
        elif state == "idle" and start:
            state = "running"
            steps_left = width // 2 if op.word else width
            expected = reference(op, width)
            started += 1
        elif state == "running":
            steps_left -= 1
            if steps_left == 0:
                state = "done"
        elif state == "done" and accept:
            state = "idle"
            completed += 1

        await RisingEdge(dut.i_clk)
        await ReadOnly()
        idle, done = int(dut.o_idle.value), int(dut.o_done.value)
        assert (idle, done) == (int(state == "idle"), int(state == "done")), (
            f"cycle {cycle}: idle/done {idle}/{done}, model {state}"
        )
        if state == "done":
            actual = int(dut.o_result.value)
            assert actual == expected, (
                f"cycle {cycle}: result {actual:#x}, expected {expected:#x}"
            )
        await FallingEdge(dut.i_clk)
        cycle += 1

    assert abandoned > 20 and completed > len(operations) // 2
    dut._log.info(
        "WIDTH=%d: %d results checked, %d operations killed or reset, %d cycles",
        width,
        completed,
        abandoned,
        cycle,
    )
