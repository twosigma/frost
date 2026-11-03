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

"""Cycle-accurate direct multiply completions under mixed issues and flushes."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

from models import alu_model
from .test_int_muldiv_shim import SHORT_WORD_OPS, _op, setup


@cocotb.test()
async def test_direct_completion_schedule(dut: Any) -> None:
    """Match raw shim results across tag reuse; adapters filter same-cycle flushes."""
    iface = await setup(dut)
    iface.drive_mul_accepted()
    rng = random.Random(0xD1EC7)
    names = ("MUL", "MULH", "MULHSU", "MULHU", "MULW", "CLMUL", "CLMULH", "CLMULR")
    corners = (
        0,
        1,
        (1 << 64) - 1,
        1 << 63,
        0x80000000,
        0xFFFFFFFF,
        (1 << 27) - 1,
        1 << 35,
        (1 << 54) - 1,
    )
    expected: dict[int, tuple[int, int]] = {}
    issued = completed = killed = collisions = 0
    for cycle in range(4096 + 8):
        result = iface.read_mul_fu_complete()
        want = expected.pop(cycle, None)
        assert result["valid"] == (want is not None), (cycle, result, want)
        if want is not None:
            assert (result["tag"], result["value"]) == want, (cycle, result, want)
            assert not result["exception"] and result["fp_flags"] == 0
            completed += 1
        iface.clear_issue()
        iface.clear_flush()
        iface.clear_partial_flush()
        full = cycle < 4096 and rng.randrange(43) == 0
        partial = cycle < 4096 and rng.randrange(11) == 0
        head, flush_tag = rng.randrange(32), rng.randrange(32)

        def squashed(tag: int) -> bool:
            return full or (partial and ((tag - head) & 63) > ((flush_tag - head) & 63))

        if full:
            iface.drive_flush()
        if partial:
            iface.drive_partial_flush(flush_tag, head)
        survivors = {
            due: entry for due, entry in expected.items() if not squashed(entry[0])
        }
        killed += len(expected) - len(survivors)
        expected = survivors
        if cycle < 4096:
            name = names[cycle % len(names)] if cycle < 512 else rng.choice(names)
            a, b = (
                rng.choice(corners) if rng.randrange(2) else rng.getrandbits(64)
                for _ in range(2)
            )
            tag = rng.randrange(32)
            iface.drive_issue(False, tag, _op(name), a, b)
            await Timer(1, unit="ns")
            if not iface.read_busy():
                iface.drive_issue(True, tag, _op(name), a, b)
                issued += 1
                if squashed(tag):
                    killed += 1
                else:
                    due = cycle + (
                        6
                        if name in names[:4] or (name == "MULW" and not SHORT_WORD_OPS)
                        else 3
                    )
                    assert due not in expected, (cycle, due, expected)
                    expected[due] = (tag, getattr(alu_model, name.lower())(a, b))
            else:
                collisions += 1
        await iface.step()
    assert not expected
    assert issued == completed + killed, (issued, completed, killed)
    assert completed > 1000 and killed > 100 and collisions > 100
    dut._log.info(
        "direct MUL: issued=%d completed=%d squashed=%d busy=%d",
        issued,
        completed,
        killed,
        collisions,
    )
