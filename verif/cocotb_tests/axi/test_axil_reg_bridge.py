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

"""AXI4-Lite register mapping, channel skew, response stalls and reset."""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from cocotb_tests.axi.axil_model import AxilMaster


@cocotb.test()
async def register_transactions(dut: Any) -> None:
    """Check register effects and completions across channel timing and reset."""
    master = AxilMaster(dut)
    master.idle()
    dut.i_rst.value = 1
    dut.i_rd_pair.value = 0
    Clock(dut.i_clk, 10, unit="ns").start()
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    writes: list[tuple[int, int, int]] = []
    rng = random.Random(814)

    async def registers() -> None:
        while True:
            await RisingEdge(dut.i_clk)
            if not int(dut.i_rst.value):
                if int(dut.o_wr_en.value):
                    writes.append(
                        (32, int(dut.o_wr_offset.value), int(dut.o_wr_data.value))
                    )
                if int(dut.o_wr64_en.value):
                    writes.append(
                        (64, int(dut.o_wr_offset.value), int(dut.o_wr64_data.value))
                    )
            await Timer(1, unit="ps")
            offset = int(dut.o_rd_offset.value)
            dut.i_rd_pair.value = ((offset + 4) << 32) | offset

    monitor = cocotb.start_soon(registers())
    cases = [
        (off, strb)
        for off in (0, 4, 0x70, 0x74, 0x78, 0x7C, 0xFF8)
        for strb in range(256)
    ]
    cases += [(rng.randrange(4096), rng.randrange(256)) for _ in range(400)]
    for addr, strb in cases:
        data = rng.getrandbits(64)
        expected = []
        if addr in (0x70, 0x78) and strb == 255:
            expected = [(64, addr, data)]
        elif addr & ~7 not in (0x70, 0x78) and strb:
            hi = bool(strb & 0xF0)
            expected = [
                (
                    32,
                    (addr & ~7) | (4 if hi else 0),
                    (data >> (32 if hi else 0)) & 0xFFFFFFFF,
                )
            ]
        writes.clear()
        await master.write(
            addr,
            data,
            strb,
            aw_delay=rng.randrange(5),
            w_delay=rng.randrange(5),
            response_delay=rng.randrange(5),
        )
        assert writes == expected, (hex(addr), hex(strb), writes, expected)

    for addr in range(4096):
        result = await master.read(addr, response_delay=addr % 4)
        aligned = addr & ~7
        assert result == ((aligned + 4) << 32) | aligned

    # Both directions offered together serialize without losing either.
    write = cocotb.start_soon(
        master.write(0x20, 0x12345678, 15, w_delay=6, response_delay=5)
    )
    read = cocotb.start_soon(master.read(0x28, response_delay=5))
    await write
    assert await read == (0x2C << 32) | 0x28

    # Reset abandons each kind of partially accepted or held transaction.
    for channel in ("aw", "w", "b", "r"):
        await FallingEdge(dut.i_clk)
        master.idle()
        writes.clear()
        if channel in ("aw", "b"):
            dut.i_axil_awvalid.value = 1
            dut.i_axil_awaddr.value = 0x20
        if channel in ("w", "b"):
            dut.i_axil_wvalid.value = 1
            dut.i_axil_wdata.value = 0xDEADBEEF
            dut.i_axil_wstrb.value = 15
        if channel == "r":
            dut.i_axil_arvalid.value = 1
        for _ in range(8):
            await RisingEdge(dut.i_clk)
            aw = int(dut.i_axil_awvalid.value) and int(dut.o_axil_awready.value)
            w = int(dut.i_axil_wvalid.value) and int(dut.o_axil_wready.value)
            ar = int(dut.i_axil_arvalid.value) and int(dut.o_axil_arready.value)
            await FallingEdge(dut.i_clk)
            if aw:
                dut.i_axil_awvalid.value = 0
            if w:
                dut.i_axil_wvalid.value = 0
            if ar:
                dut.i_axil_arvalid.value = 0
        assert len(writes) == (1 if channel == "b" else 0)
        dut.i_rst.value = 1
        master.idle()
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 0
        for _ in range(3):
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ps")
            assert not int(dut.o_axil_bvalid.value)
            assert not int(dut.o_axil_rvalid.value)
        await master.write(0x24, 0x1122334455667788, 240)
    monitor.cancel()
