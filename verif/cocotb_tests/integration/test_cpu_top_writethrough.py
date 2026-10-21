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

"""Architectural checks for private Normal memory with read caching."""

from typing import Any
import cocotb
from cocotb_tests.integration.test_cpu_top import (
    System,
    addi,
    load,
    store,
    trap_program,
)


def atomic(funct5: int, rd: int, address_reg: int, value_reg: int = 0) -> int:
    """Encode a doubleword AMO, LR or SC."""
    return (
        (funct5 << 27)
        | (value_reg << 20)
        | (address_reg << 15)
        | (3 << 12)
        | (rd << 7)
        | 0x2F
    )


@cocotb.test()
async def normal_load_error_is_precise_and_does_not_fill_l0(dut: Any) -> None:
    """Report a widened Normal-read fault against the requesting load."""
    s = System(dut)
    pc = trap_program(s, [0x00005237, load(5, 4, 3, 4)]) + 4
    s.error_reads.add(0x5000)
    await s.reset()
    await s.until_write(0x40000020)
    values = {a: v for _, a, v in s.effects}
    assert values[0x40000010] == 5 and values[0x40000018] == pc
    assert not int(dut.o_fatal_error.value)
    assert 0x40000008 not in values


@cocotb.test()
async def normal_sc_and_amo_b_errors_remain_precise(dut: Any) -> None:
    """SC and AMO stay in the ROB until B even in the write-through region."""
    for kind in (3, 0):
        s = System(dut)
        body = [0x00005237, addi(6, 0, 1)]
        if kind == 3:
            body += [atomic(2, 5, 4)]
        body += [atomic(kind, 7, 4, 6)]
        pc = trap_program(s, body) + 4 * (len(body) - 1)
        s.error_writes.add(0x5000)
        await s.reset()
        await s.until_write(0x40000020)
        values = {a: v for _, a, v in s.effects}
        assert values[0x40000010] == 7 and values[0x40000018] == pc
        assert not int(dut.o_fatal_error.value)
        assert 0x40000008 not in values
        assert sum(a == 0x5000 for _, a, _ in s.effects) == 1


@cocotb.test()
async def retired_normal_store_failure_stops_at_fence(dut: Any) -> None:
    """Make a late Normal-store failure fatal without releasing FENCE."""
    s = System(dut)
    s.allow_fatal = True
    s.program(
        [
            0x400000B7,
            0x00005237,
            addi(6, 0, 0x5A),
            store(6, 4, 3, 0),
            0x0FF0000F,
            store(6, 1, 8, 0),
            0x0000006F,
        ]
    )
    s.error_writes.add(0x5003)
    await s.reset()
    for _ in range(4000):
        await s.step()
        if int(dut.o_fatal_error.value):
            break
    assert int(dut.o_fatal_error.value)
    assert int(dut.o_fatal_addr.value) == 0x5003
    for _ in range(200):
        await s.step()
    assert sum(a == 0x5003 for _, a, _ in s.effects) == 1
    assert all(a != 0x40000008 for _, a, _ in s.effects)


@cocotb.test()
async def fence_i_observes_modified_normal_instruction(dut: Any) -> None:
    """Warm a line, rewrite its instruction, fence.i and execute the new code."""
    s = System(dut)
    # Function at 0x1200 returns x7=1. Replace its first ADDI with x7=2.
    s.program([addi(7, 0, 1), 0x00008067], 0x1200)
    s.memory.update(
        {0x5000 + n: b for n, b in enumerate(addi(7, 0, 2).to_bytes(4, "little"))}
    )
    s.program(
        [
            0x40000437,
            0x00001237,
            addi(4, 4, 0x200),
            (4 << 15) | (1 << 7) | 0x67,
            store(7, 8, 0x10, 3),
            0x000052B7,
            load(6, 5, 0, 2),
            store(6, 4, 0, 2),
            0x0000100F,
            (4 << 15) | (1 << 7) | 0x67,
            store(7, 8, 0x18, 3),
            addi(6, 0, 1),
            store(6, 8, 8, 0),
            0x0000006F,
        ]
    )
    await s.reset()
    assert await s.until_write(0x40000008) == 1
    values = {a: v for _, a, v in s.effects}
    assert values[0x40000010] == 1 and values[0x40000018] == 2
    assert sum(kind == "read" and a == 0x1200 for _, kind, a, *_ in s.transactions) >= 2


@cocotb.test()
async def late_normal_write_error_stops_an_unfenced_alu_loop(dut: Any) -> None:
    """Fatal control stops both retirement lanes without relying on a fence."""
    s = System(dut)
    s.allow_fatal = True
    s.program(
        [
            0x00005237,
            addi(6, 0, 0x5A),
            store(6, 4, 3, 0),
            addi(7, 0, 0),
            addi(7, 7, 1),
            addi(8, 8, 1),
            0xFF9FF06F,  # JAL x0,-8: repeat the independent ALU operations.
        ]
    )
    s.error_writes.add(0x5003)
    await s.reset()
    for _ in range(4000):
        await s.step()
        if int(dut.o_fatal_error.value):
            break
    assert int(dut.o_fatal_error.value)
    assert int(dut.o_fatal_addr.value) == 0x5003
    for cycle in range(200):
        await s.step()
        assert int(dut.o_fatal_error.value)
        if cycle > 3:
            assert not int(dut.o_commit_valid.value)
            assert not int(dut.o_debug_commit_valid.value)
    assert sum(a == 0x5003 for _, a, _ in s.effects) == 1
