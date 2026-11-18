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

"""A partial vector load in Debug Mode must dirty the architectural VS field."""

from typing import Any

import cocotb

from cocotb_tests.debug.jtag_dtm import (
    CMDERR_EXCEPTION,
    DebugModule,
    Dtm,
    JtagDriver,
)
from cocotb_tests.debug.test_debug import _reset
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
)


# The partial load writes v8 before its page fault, which re-parks the hart in
# Debug Mode without an M/S trap. The head unit reports the register write
# itself, so mstatus.VS must read Dirty afterwards.
@cocotb.test()
@takes_last_edge
async def test_partial_load_dirties_vs(dut: Any) -> None:
    """A valid first page writes v8 before an invalid second page re-parks."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=4)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=1), cocotb.log)
    await dm.activate()
    await dm.halt()
    root, l1, l0, frame, dump = (
        0x83500000,
        0x83501000,
        0x83502000,
        0x83503000,
        0x83504000,
    )
    for address, value in (
        (root, ((l1 >> 12) << 10) | 1),
        (l1 + 16, ((l0 >> 12) << 10) | 1),
        (l0, ((frame >> 12) << 10) | 0xC7),
        (l0 + 8, 0),
        (frame + 4088, 0x8877665544332211),
        (dump, 0),
        (dump + 8, 0),
    ):
        await dm.write_mem(address, 8, value)
    await dm.write_csr(0x300, (await dm.read_csr(0x300)) | (3 << 9))
    # vsetivli x0,4,e32,m1,tu,mu; vle32.v v8,(s0)
    await dm.exec_progbuf([0xC1027057])
    await dm.write_gpr(dm.S0, dump)
    vle32 = (1 << 25) | (dm.S0 << 15) | (6 << 12) | (8 << 7) | 0x07
    await dm.exec_progbuf([vle32])
    await dm.write_csr(0x180, (8 << 60) | (root >> 12))
    await dm.exec_progbuf([0x12000073])  # sfence.vma
    await dm.write_gpr(dm.S0, 0x00400FF8)
    saved = await dm.read_csr(0x300)
    clean = (saved & ~((3 << 11) | (3 << 9))) | (1 << 11) | (1 << 17) | (2 << 9)
    await dm.write_csr(0x300, clean)
    await dm.exec_progbuf([vle32], expect=CMDERR_EXCEPTION)
    await dm.clear_cmderr()
    status = await dm.read_csr(0x300)
    vstart = await dm.read_csr(0x008)
    # Record VS before the dump store or any explicit vector CSR write.
    await dm.write_csr(0x300, status & ~(1 << 17))
    await dm.write_csr(0x180, 0)
    await dm.write_gpr(dm.S0, dump)
    vs1r = (1 << 25) | (8 << 20) | (dm.S0 << 15) | (8 << 7) | 0x27
    await dm.exec_progbuf([vs1r])
    low = await dm.read_mem(dump, 8)
    high = await dm.read_mem(dump + 8, 8)
    assert low == 0x8877665544332211 and high == 0, (hex(low), hex(high))
    cocotb.log.info(
        "Debug partial load wrote v8: VS=%d vstart=%d", (status >> 9) & 3, vstart
    )
    assert (status >> 9) & 3 == 3, (
        "partial load changed v8 but left mstatus.VS non-Dirty"
    )

    # A strided load: element 0 at 0x400ff8 is performed at the head, element
    # 1 at 0x401000 faults. VS must read Dirty again.
    await dm.write_mem(frame + 4088, 8, 0x0123456789ABCDEF)
    await dm.write_csr(0x180, (8 << 60) | (root >> 12))
    await dm.exec_progbuf([0x12000073])  # sfence.vma
    await dm.write_gpr(dm.S0, 0x00400FF8)
    await dm.write_gpr(dm.S1, 8)
    saved = await dm.read_csr(0x300)
    clean = (saved & ~((3 << 11) | (3 << 9))) | (1 << 11) | (1 << 17) | (2 << 9)
    await dm.write_csr(0x300, clean)
    # vlse32.v v8, (s0), s1
    vlse32 = (
        (2 << 26)
        | (1 << 25)
        | (dm.S1 << 20)
        | (dm.S0 << 15)
        | (6 << 12)
        | (8 << 7)
        | 0x07
    )
    await dm.exec_progbuf([vlse32], expect=CMDERR_EXCEPTION)
    await dm.clear_cmderr()
    status = await dm.read_csr(0x300)
    await dm.write_csr(0x300, status & ~(1 << 17))
    await dm.write_csr(0x180, 0)
    await dm.write_gpr(dm.S0, dump)
    await dm.exec_progbuf([vs1r])
    low = await dm.read_mem(dump, 8)
    high = await dm.read_mem(dump + 8, 8)
    # Element 0 is the frame's word; element 1 keeps the earlier load's value.
    assert low == 0x8877665589ABCDEF and high == 0, (hex(low), hex(high))
    cocotb.log.info("Debug strided partial load: VS=%d", (status >> 9) & 3)
    assert (status >> 9) & 3 == 3, (
        "strided partial load changed v8 but left VS non-Dirty"
    )
