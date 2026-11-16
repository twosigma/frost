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

"""Source-width rules for masks, vector operands and widening accumulators."""

import os
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def operand_widths(dut: Any) -> None:
    """Check legal mask aliases and reject sources read at different EEWs."""
    cases = []
    for subop, name in ((1, "vmsbf"), (2, "vmsof"), (3, "vmsif"), (16, "viota")):
        for vt in (0, 8, 16, 24):
            cases.append((name + " mask source v0", vt, 0x14, 0, 0, subop, 2, 8, False))
    cases.extend(
        (
            ("OPIVV vs1 mask alias", 16, 0, 0, 8, 0, 0, 16, True),
            ("OPMVV vs1 mask alias", 16, 0x25, 0, 8, 0, 2, 16, True),
            ("OPMVV reduction seed alias", 16, 0, 0, 8, 0, 2, 16, True),
            ("scalar x0 is not v0", 16, 0, 0, 8, 0, 4, 16, False),
            ("unmasked OPMVV v0", 16, 0x25, 1, 8, 0, 2, 16, False),
            ("single-width accumulator alias", 16, 0x2D, 1, 16, 8, 2, 16, False),
            ("widening add upper overlap", 16, 0x30, 1, 17, 8, 2, 16, False),
        )
    )
    for funct6 in (0x3C, 0x3D, 0x3F):
        cases.append(
            ("wide integer accumulator vs2", 16, funct6, 1, 17, 8, 2, 16, True)
        )
        cases.append(
            ("wide integer accumulator vs1", 16, funct6, 1, 8, 17, 2, 16, True)
        )
        cases.append(("wide integer disjoint", 16, funct6, 1, 8, 24, 2, 16, False))
    for funct6 in (0x3C, 0x3D, 0x3E, 0x3F):
        cases.append(
            ("wide integer scalar accumulator", 16, funct6, 1, 17, 8, 6, 16, True)
        )
    if os.getenv("FROST_VECTOR_TEST_FP"):
        cases.extend(
            (
                ("OPFVV vs1 mask alias", 16, 0, 0, 8, 0, 1, 16, True),
                ("FP reduction seed alias", 16, 3, 0, 8, 0, 1, 16, True),
                ("scalar f0 is not v0", 16, 0, 0, 8, 0, 5, 16, False),
                ("FP widening add upper overlap", 16, 0x30, 1, 17, 8, 1, 16, False),
            )
        )
        for funct6 in (0x3C, 0x3D, 0x3E, 0x3F):
            cases.append(("wide FP accumulator vs2", 16, funct6, 1, 17, 8, 1, 16, True))
            cases.append(("wide FP accumulator vs1", 16, funct6, 1, 8, 17, 1, 16, True))
            cases.append(
                ("wide FP scalar accumulator", 16, funct6, 1, 17, 8, 5, 16, True)
            )
            cases.append(("wide FP disjoint", 16, funct6, 1, 8, 24, 1, 16, False))
    for name, vt, f6, vm, vs2, vs1, f3, vd, illegal in cases:
        dut.i_insn.value = (
            (f6 << 26)
            | (vm << 25)
            | (vs2 << 20)
            | (vs1 << 15)
            | (f3 << 12)
            | (vd << 7)
            | 0x57
        )
        dut.i_vtype.value = vt
        await Timer(1, unit="ns")
        got = int(dut.o_illegal.value)
        assert got == illegal, (name, vt, hex(int(dut.i_insn.value)), got, illegal)
    dut._log.info("Checked %d operand-width cases", len(cases))
