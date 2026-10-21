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

"""Fail coherent DMA reads, writes and completion-status writes."""

from typing import Any
import cocotb
from cocotb.triggers import Timer


class Bench:
    """Collect accepted requests and delay each line response."""

    def __init__(self, dut: Any) -> None:
        """Initialize the request scoreboard."""
        self.dut = dut
        self.requests: list[tuple[int, int, int]] = []

    async def step(self, **inputs: int) -> None:
        """Clock once and record a coherent request only on its handshake."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        if int(self.dut.o_dma_req_valid.value) and int(self.dut.i_dma_req_ready.value):
            self.requests.append(
                (
                    int(self.dut.o_dma_req_write.value),
                    int(self.dut.o_dma_req_addr.value),
                    int(self.dut.o_dma_req_id.value),
                )
            )
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")

    async def wr(self, offset: int, data: int) -> None:
        """Write one register through the native MMIO interface."""
        await self.step(wr_en=1, wr_offset=offset, wr_data=data)
        await self.step(wr_en=0)


@cocotb.test()
async def bus_errors_abort_without_success_status_or_later_writes(dut: Any) -> None:
    """Check the read, data-write and status-write failure boundaries."""
    for fail_at in range(3):
        b = Bench(dut)
        for signal in dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await b.step(rst=1)
        await b.step()
        await b.step(rst=0, dma_req_ready=1)
        for off, value in (
            (8, 0x80000100),
            (12, 0x80000200),
            (16, 32),
            (20, 6),
            (28, 0x80000300),
            (32, 0x12345678),
            (0, 1),
        ):
            await b.wr(off, value)
        for index in range(fail_at + 1):
            for _ in range(20):
                if len(b.requests) > index:
                    break
                await b.step()
            else:
                raise AssertionError("DMA did not issue its next request")
            for _ in range(5):
                await b.step()
                assert len(b.requests) == index + 1
            ident = b.requests[index][2]
            await b.step(
                dma_resp_valid=1,
                dma_resp_id=ident,
                dma_resp_error=int(index == fail_at),
                dma_resp_rdata=0xA5,
            )
            await b.step(dma_resp_valid=0, dma_resp_error=0)
        for _ in range(15):
            await b.step()
        dut.i_rd_offset.value = 0
        await Timer(1, unit="ns")
        assert int(dut.o_rd_pair.value) & 15 == 12  # ERROR + IRQ, no BUSY or DONE
        assert len(b.requests) == fail_at + 1
        assert b.requests[0][:2] == (0, 0x80000100)
        if fail_at >= 1:
            assert b.requests[1][:2] == (1, 0x80000200)
        if fail_at == 2:
            assert b.requests[2][:2] == (1, 0x80000300)
