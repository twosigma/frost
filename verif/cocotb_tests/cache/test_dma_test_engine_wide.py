# Copyright (c) 2026 John Goodacre
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

"""Extended DMA MMIO bank: last lines and fail-closed range at each capacity."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


BASE = 0x8000_0000


class MemoryPort:
    def __init__(self, dut: Any, end: int) -> None:
        self.dut = dut
        self.end = end
        self.lines: dict[int, bytearray] = {}
        self.issued: list[int] = []
        self.task = cocotb.start_soon(self.run())

    def line(self, addr: int) -> bytearray:
        return self.lines.setdefault(addr, bytearray(32))

    async def run(self) -> None:
        dut = self.dut
        response = None
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_dma_req_ready.value = 1
            dut.i_dma_resp_valid.value = 0
            if response is not None:
                rid, data = response
                dut.i_dma_resp_valid.value = 1
                dut.i_dma_resp_id.value = rid
                dut.i_dma_resp_rdata.value = data
                response = None
            if int(dut.o_dma_req_valid.value):
                addr = int(dut.o_dma_req_addr.value)
                assert BASE <= addr < self.end
                self.issued.append(addr)
                line = self.line(addr)
                rid = int(dut.o_dma_req_id.value)
                if int(dut.o_dma_req_write.value):
                    data = int(dut.o_dma_req_wdata.value)
                    strobe = int(dut.o_dma_req_wstrb.value)
                    for b in range(32):
                        if (strobe >> b) & 1:
                            line[b] = (data >> (8 * b)) & 0xFF
                    response = (rid, 0)
                else:
                    response = (rid, int.from_bytes(line, "little"))


async def wr32(dut: Any, off: int, value: int) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_wr_offset.value = off
    dut.i_wr_data.value = value
    dut.i_wr_en.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ps")
    dut.i_wr_en.value = 0


async def wr64(dut: Any, off: int, value: int) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_wr_offset.value = off
    dut.i_wr64_data.value = value
    dut.i_wr64_en.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ps")
    dut.i_wr64_en.value = 0


async def rd64(dut: Any, off: int) -> int:
    await FallingEdge(dut.i_clk)
    dut.i_rd_offset.value = off
    await Timer(1, unit="ps")
    return int(dut.o_rd_pair.value)


async def wait_done(dut: Any) -> int:
    for _ in range(500):
        ctrl = await rd64(dut, 0)
        if ctrl & 0x6:
            return ctrl
    raise AssertionError("DMA transfer did not complete")


@cocotb.test()
async def test_wide_copy_status_and_range(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for name in ("i_wr_en", "i_wr_offset", "i_wr_data", "i_wr64_en", "i_wr64_data",
                 "i_rd_offset", "i_dma_req_ready", "i_dma_resp_valid", "i_dma_resp_id",
                 "i_dma_resp_rdata"):
        getattr(dut, name).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    capacity = int(dut.APERTURE_BYTES.value)
    assert capacity in (1 << bits for bits in range(30, 38)), hex(capacity)
    end = BASE + capacity
    src, dst, status = end - 96, end - 64, end - 32
    low_addr = BASE + 0x40
    mem = MemoryPort(dut, end)
    mem.line(src)[:] = bytes(range(32))
    low_sentinel = bytes([0xA5] * 32)
    mem.line(low_addr)[:] = low_sentinel
    assert await rd64(dut, 0x28) == 2
    await wr32(dut, 0x28, 1)
    assert await rd64(dut, 0x28) == 3
    await wr64(dut, 0x40, src)
    await wr64(dut, 0x48, dst)
    await wr64(dut, 0x50, status)
    await wr32(dut, 0x40, 0)  # a legacy lane write cannot tear SRC64
    await wr64(dut, 0x44, 0)  # an unaligned wide-register offset is ignored
    await wr32(dut, 0x10, 32)
    await wr32(dut, 0x14, 0x2)
    await wr32(dut, 0x20, 0x12345678)
    assert await rd64(dut, 0x40) == src
    assert await rd64(dut, 0x48) == dst
    await wr32(dut, 0x00, 1)
    assert (await wait_done(dut)) & 0x2
    assert mem.line(dst) == bytes(range(32))
    assert mem.line(status)[:4] == bytes.fromhex("78563412")
    assert mem.line(low_addr) == low_sentinel
    assert src in mem.issued and dst in mem.issued and status in mem.issued

    async def reject(test_src: int, test_dst: int, test_status: int, length: int) -> None:
        await wr32(dut, 0x04, 1)
        mem.issued.clear()
        await wr64(dut, 0x40, test_src)
        await wr64(dut, 0x48, test_dst)
        await wr64(dut, 0x50, test_status)
        await wr32(dut, 0x10, length)
        await wr32(dut, 0x00, 1)
        assert (await wait_done(dut)) & 0x4
        assert mem.issued == []
        assert mem.line(low_addr) == low_sentinel

    # First raw out-of-range line, and transfers that cross the end by half
    # a line, must complete with ERROR before any coherence request.
    await reject(src, end, status, 32)
    await reject(src + 16, end - 16, status, 32)
    await reject(end, dst, status, 32)
    await reject(end - 16, dst + 16, status, 32)
    await reject(src, dst, end, 32)
    await reject(src, dst, end - 2, 32)
    # The high address shares the low sentinel's bits below the port width.
    await reject(src, (1 << len(dut.o_dma_req_addr)) | low_addr, status, 32)
    # Switching back clears addresses and restores the reset-default ABI.
    await wr32(dut, 0x28, 0)
    assert await rd64(dut, 0x40) == 0
    assert await rd64(dut, 0x28) == 2
    mem.task.cancel()
