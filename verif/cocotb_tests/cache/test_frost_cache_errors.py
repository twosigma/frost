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

"""Cache response errors: recoverable reads and fatal buffered-write failures."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


class Bench:
    """Drive the public interfaces and track external transactions."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut
        self.down: list[tuple[int, ...]] = []
        self.up: list[tuple[int, ...]] = []
        for name in (
            "i_clk",
            "i_rst",
            "i_up_req_valid",
            "i_up_req_write",
            "i_up_req_addr",
            "i_up_req_wdata",
            "i_up_req_wstrb",
            "i_up_req_id",
            "i_up_req_maintenance",
            "i_up_req_probe",
            "i_up_req_probe_inval",
            "i_probe_release_valid",
            "i_probe_release_id",
            "i_writeback_all",
            "i_invalidate_all",
            "i_down_req_ready",
            "i_down_resp_valid",
            "i_down_resp_id",
            "i_down_resp_rdata",
            "i_down_resp_error",
        ):
            getattr(dut, name).value = 0

    async def step(self, count: int = 1) -> None:
        """Advance one clock edge and sample the interface."""
        d = self.dut
        for _ in range(count):
            await Timer(5, unit="ns")
            if d.o_down_req_valid.value and d.i_down_req_ready.value:
                self.down.append(
                    tuple(
                        int(getattr(d, "o_down_req_" + n).value)
                        for n in ("write", "addr", "id", "wdata", "wstrb")
                    )
                )
            if d.o_up_resp_valid.value:
                self.up.append(
                    tuple(
                        int(getattr(d, "o_up_resp_" + n).value)
                        for n in ("id", "rdata", "error")
                    )
                )
            d.i_clk.value = 1
            await Timer(5, unit="ns")
            d.i_clk.value = 0

    async def reset(self) -> None:
        """Reset the device and initialize its inputs."""
        self.dut.i_rst.value = 1
        await self.step(3)
        self.dut.i_rst.value = 0
        self.dut.i_down_req_ready.value = 1
        await self.step(12)
        self.down.clear()
        self.up.clear()

    async def request(
        self,
        address: int,
        ident: int,
        *,
        write: bool = False,
        data: int = 0,
        strobes: int = 0,
    ) -> None:
        """Check request."""
        d = self.dut
        d.i_up_req_valid.value = 1
        d.i_up_req_write.value = int(write)
        d.i_up_req_addr.value = address
        d.i_up_req_id.value = ident
        d.i_up_req_wdata.value = data
        d.i_up_req_wstrb.value = strobes
        for _ in range(80):
            await Timer(1, unit="ns")
            ready = bool(d.o_up_req_ready.value)
            await self.step()
            if ready:
                d.i_up_req_valid.value = 0
                return
        raise AssertionError("Cache did not accept request")

    async def wait_down(self, count: int) -> Any:
        """Check wait down."""
        for _ in range(100):
            if len(self.down) >= count:
                return self.down[count - 1]
            await self.step()
        raise AssertionError("No downstream request")

    async def response(self, ident: int, *, error: bool = False, data: int = 0) -> None:
        """Check response."""
        d = self.dut
        d.i_down_resp_valid.value = 1
        d.i_down_resp_id.value = ident
        d.i_down_resp_error.value = int(error)
        d.i_down_resp_rdata.value = data
        await self.step()
        d.i_down_resp_valid.value = 0
        d.i_down_resp_error.value = 0


@cocotb.test()
async def test_failed_read_answers_waiters_and_does_not_install(dut: Any) -> None:
    """Check failed read answers waiters and does not install."""
    b = Bench(dut)
    await b.reset()
    await b.request(0x1000, 1)
    first = await b.wait_down(1)
    await b.request(0x1000, 2)
    await b.step(12)
    assert not b.up
    assert len(b.down) == 1
    await b.response(first[2], error=True, data=(1 << 256) - 1)
    await b.step(24)
    assert sorted((r[0], r[2]) for r in b.up) == [(1, 1), (2, 1)]
    assert not dut.o_fatal_error.value
    await b.request(0x1000, 3)
    second = await b.wait_down(2)
    await b.response(second[2], data=0x12345678)
    await b.step(24)
    assert b.up[-1] == (3, 0x12345678, 0)
    await b.request(0x1000, 4)
    await b.step(24)
    assert b.up[-1] == (4, 0x12345678, 0)
    assert len(b.down) == 2


@cocotb.test()
async def test_failed_write_allocate_is_fatal(dut: Any) -> None:
    """Check failed write allocate is fatal."""
    b = Bench(dut)
    await b.reset()
    await b.request(0x1800, 1, write=True, data=0x12345678, strobes=15)
    fill = await b.wait_down(1)
    await b.step(12)
    assert b.up == [(1, b.up[0][1], 0)]  # Buffered store already acknowledged.
    await b.response(fill[2], error=True, data=0)
    await b.step(12)
    assert dut.o_fatal_error.value
    assert int(dut.o_fatal_addr.value) == 0x1800
    assert not dut.o_up_req_ready.value
    assert len(b.up) == 1 and len(b.down) == 1
    assert int(dut.mshr_valid.value) != 0


@cocotb.test()
async def test_failed_writeback_retains_dirty_slot(dut: Any) -> None:
    """Check failed writeback retains dirty slot."""
    b = Bench(dut)
    await b.reset()
    data = int.from_bytes(bytes(range(32)), "little")
    await b.request(0x2000, 1, write=True, data=data, strobes=0xFFFFFFFF)
    await b.step(30)
    assert len(b.up) == 1 and not b.down
    dut.i_writeback_all.value = 1
    write = await b.wait_down(1)
    assert write[0] == 1 and write[1] == 0x2000 and write[3] == data
    await b.response(write[2], error=True)
    await b.step(30)
    assert dut.o_fatal_error.value
    assert int(dut.o_fatal_addr.value) == 0x2000
    assert dut.o_maint_busy.value
    assert int(dut.wb_valid.value) != 0
    assert len(b.down) == 1, "Failed writes must not be automatically retried"


@cocotb.test()
async def test_mixed_out_of_order_read_responses(dut: Any) -> None:
    """Check mixed out of order read responses."""
    b = Bench(dut)
    await b.reset()
    await b.request(0x1000, 1)
    a = await b.wait_down(1)
    await b.request(0x1040, 2)
    c = await b.wait_down(2)
    await b.response(c[2], error=True)
    await b.response(a[2], data=0xABCDEF)
    await b.step(32)
    by_id = {r[0]: r for r in b.up}
    assert len(b.up) == 2 and by_id[2][2] == 1
    assert by_id[1] == (1, 0xABCDEF, 0)
    assert not dut.o_fatal_error.value
