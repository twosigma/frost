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

"""Exercise the VCU118 peripherals through the CPU AXI port."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, with_timeout

from cocotb_tests.axi.test_soc_axil import Bench


@cocotb.test()
async def peripherals(dut: Any) -> None:
    """Check independent NIC windows, SPI wire order and executable SRAM writes."""
    b = Bench(dut)
    await b.reset()
    Clock(dut.i_clk_div4, 40, unit="ns").start()
    for _ in range(20):
        await b.step(rst=1)
    for _ in range(20):
        await b.step(rst=0, ddr_status=3)
    for base, value in ((0x40030000, 0x11223344), (0x40022000, 0x55667788)):
        assert await b.read(base) == 0x4E494301
        await b.write(base + 12, value)
    assert await b.read(0x4003000C) == 0x11223344
    assert await b.read(0x4002200C) == 0x55667788

    boot = 0x40023000
    assert await b.read(boot) == 0x801
    assert await b.read(boot + 4) == 0x46520300
    await b.write(boot, 0x600)
    assert not int(dut.o_spi_cs_n.value)
    assert await b.read(boot) == 0x600

    async def peer(bits: int, response: int) -> int:
        transmitted = 0
        for index in range(bits):
            dut.i_spi_miso.value = (response >> (bits - index - 1)) & 1
            await RisingEdge(dut.o_spi_sck)
            transmitted = (transmitted << 1) | int(dut.o_spi_mosi.value)
            await FallingEdge(dut.o_spi_sck)
        return transmitted

    for offset, bits, tx, rx, expected in (
        (8, 8, 0x9F, 0xA5, 0xA5),
        (12, 32, 0x12345678, 0x89ABCDEF, 0xEFCDAB89),
    ):
        task = cocotb.start_soon(peer(bits, rx))
        await b.write(boot + offset, tx)
        for _ in range(200):
            if not (await b.read(boot + 4)) & 1:
                break
        else:
            raise AssertionError("SPI transfer did not finish")
        assert await with_timeout(task, 1, "us") == tx
        assert await b.read(boot + offset) == expected
    await b.write(boot, 0x601)
    assert int(dut.o_spi_cs_n.value)

    await b.write(boot + 16, 0x4000)
    for word in (0x00000013, 0xABCDEF01, 0x76543210):
        await b.write(boot + 20, word)
        for _ in range(100):
            if not (await b.read(boot + 4)) & 2:
                break
        else:
            raise AssertionError("SRAM programming did not finish")
    assert await b.read(boot + 16) == 0x400C
    for address, word in ((0x4000, 0x13), (0x4004, 0xABCDEF01), (0x4008, 0x76543210)):
        assert await b.read(address) == word
