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

"""Reserved overlap of the implicit one-bit mask and SEW data sources."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from ..tomasulo.fu_shims.fp_shim_interface import _parse_instr_op_enum


@cocotb.test()
async def mask_source_widths(dut: Any) -> None:
    """Reject v0 data aliases while allowing mask destinations and scalar zero."""
    if hasattr(dut, "i_op"):
        dut.i_op.value = _parse_instr_op_enum()["VARITH"]
        dut.i_is_illegal.value = 0
        dut.i_is_fetch_fault.value = 0
    cases = (
        ("masked vs2 alias", 0x02, 0, 0, 8, 0, 16, True),
        ("masked vs1 alias", 0x02, 0, 8, 0, 0, 16, True),
        ("both aliases", 0x02, 0, 0, 0, 0, 16, True),
        ("compare data alias", 0x18, 0, 0, 8, 0, 16, True),
        ("scalar data alias", 0x00, 0, 0, 10, 4, 16, True),
        ("merge data alias", 0x17, 0, 0, 8, 0, 16, True),
        ("masked disjoint", 0x02, 0, 8, 8, 0, 16, False),
        ("unmasked vs2 zero", 0x02, 1, 0, 8, 0, 16, False),
        ("unmasked vs1 zero", 0x02, 1, 8, 0, 0, 16, False),
        ("scalar zero is not v0", 0x00, 0, 8, 0, 4, 16, False),
        ("immediate zero is not v0", 0x00, 0, 8, 0, 3, 16, False),
        ("compare destination v0", 0x18, 0, 8, 8, 0, 0, False),
    )
    for name, f6, vm, vs2, vs1, f3, vd, illegal in cases:
        dut.i_insn.value = (
            (f6 << 26)
            | (vm << 25)
            | (vs2 << 20)
            | (vs1 << 15)
            | (f3 << 12)
            | (vd << 7)
            | 0x57
        )
        await Timer(1, unit="ns")
        got = int(dut.o_illegal.value)
        # The first four entries cover all integer LMUL register-group sizes.
        # All cases use aligned groups and SEW8 when the table includes SEW.
        assert got & 15 == (15 if illegal else 0), (name, got, illegal)
