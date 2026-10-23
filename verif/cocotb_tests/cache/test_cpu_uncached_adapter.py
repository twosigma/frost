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

"""Narrow accesses must survive queuing without becoming cache-line accesses."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


class Bench:
    """Sample the adapter's public request and completion interfaces."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut
        self.held: tuple[int, ...] | None = None
        self.resp_valid = 0
        self.resp_status = 0

    async def step(self, **inputs: int) -> dict[str, int]:
        """Advance one clock edge and sample the interface."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        # The fabric decodes an OKAY data response before its response mux.
        self.resp_valid = inputs.get("resp_valid", self.resp_valid)
        self.resp_status = inputs.get("resp_status", self.resp_status)
        self.dut.i_resp_ok.value = int(bool(self.resp_valid) and self.resp_status == 0)
        await Timer(5, unit="ns")
        names = (
            "read_ready",
            "read_valid",
            "read_data",
            "read_status",
            "write_ready",
            "write_done",
            "write_status",
            "write_inflight",
            "idle",
            "req_valid",
            "req_write",
            "req_addr",
            "req_size",
            "req_cache",
            "req_prot",
            "req_wdata",
            "req_wstrb",
        )
        s = {n: int(getattr(self.dut, "o_" + n).value) for n in names}
        request = tuple(
            s["req_" + n]
            for n in ("write", "addr", "size", "cache", "prot", "wdata", "wstrb")
        )
        if self.held is not None and not int(self.dut.i_rst.value):
            assert s["req_valid"] and request == self.held
        self.held = (
            request if s["req_valid"] and not int(self.dut.i_req_ready.value) else None
        )
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return s

    async def reset(self) -> None:
        """Reset the device and initialize its inputs."""
        await self.step(
            rst=1,
            read_enable=0,
            read_addr=0,
            read_size=0,
            read_device=0,
            read_resp_ready=0,
            write_enable=0,
            write_addr=0,
            write_size=0,
            write_device=0,
            write_data=0,
            write_strb=0,
            req_ready=0,
            resp_valid=0,
            resp_rdata=0,
            resp_status=0,
        )
        await self.step(rst=0)


@cocotb.test()
async def all_narrow_sizes_and_lanes(dut: Any) -> None:
    """Preserve each naturally aligned byte/half/word/dword transaction."""
    b = Bench(dut)
    await b.reset()
    for size in range(4):
        for offset in range(0, 64, 1 << size):
            addr = 0x12_4000_0040 + offset
            strb = ((1 << (1 << size)) - 1) << (offset & 7)
            data = 0xA2B3_C4D5_E6F7_0819
            s = await b.step(
                write_enable=1,
                write_addr=addr,
                write_size=size,
                write_device=1,
                write_data=data,
                write_strb=strb,
            )
            assert s["write_ready"]
            s = await b.step(write_enable=0)
            assert s["req_valid"] and s["req_write"]
            assert (s["req_addr"], s["req_size"], s["req_cache"]) == (addr, size, 0)
            assert s["req_wstrb"] == ((1 << (1 << size)) - 1) << offset
            assert (s["req_wdata"] >> (8 * (offset & ~7))) & ((1 << 64) - 1) == data
            for _ in range(3):
                assert not (await b.step())["write_done"]
            await b.step(req_ready=1)
            for _ in range(3):
                s = await b.step(req_ready=0)
                assert (
                    not s["req_valid"] and s["write_inflight"] and not s["write_done"]
                )
            await b.step(resp_valid=1)
            assert (await b.step(resp_valid=0))["write_done"]
            await b.step(read_enable=1, read_addr=addr, read_size=size, read_device=1)
            s = await b.step(read_enable=0, req_ready=1)
            assert s["req_valid"] and not s["req_write"]
            assert (s["req_addr"], s["req_size"], s["req_cache"]) == (addr, size, 0)
            await b.step(req_ready=0)
            response = sum((0x100 + lane) << (64 * lane) for lane in range(8))
            await b.step(resp_valid=1, resp_rdata=response)
            s = await b.step(resp_valid=0)
            assert s["read_valid"] and s["read_data"] == 0x100 + (offset // 8)
            await b.step(read_resp_ready=1)
            await b.step(read_resp_ready=0)
    assert (await b.step())["idle"]


@cocotb.test()
async def two_stores_wait_for_real_completion_and_propagate_errors(dut: Any) -> None:
    """Backpressured stores retain order, with one completion per B response."""
    b = Bench(dut)
    await b.reset()
    await b.step(
        write_enable=1,
        write_addr=0x4000_0000,
        write_size=2,
        write_device=1,
        write_data=0x33,
        write_strb=0xF,
    )
    await b.step(write_addr=0x10008, write_size=3, write_device=0, write_strb=0xFF)
    for _ in range(5):
        s = await b.step(write_enable=0)
        assert not s["write_ready"] and not s["write_done"]
        assert s["req_addr"] == 0x4000_0000 and s["req_cache"] == 0
    await b.step(req_ready=1)
    for _ in range(20):
        s = await b.step(req_ready=0)
        assert s["write_inflight"] and not s["req_valid"] and not s["write_done"]
    await b.step(resp_valid=1, resp_status=2)
    s = await b.step(resp_valid=0, req_ready=1)
    assert s["write_done"] and s["write_status"] == 2
    assert s["req_valid"] and s["req_addr"] == 0x10008 and s["req_cache"] == 2
    await b.step(req_ready=0)
    await b.step(resp_valid=1, resp_status=3)
    s = await b.step(resp_valid=0)
    assert s["write_done"] and s["write_status"] == 3
    assert not s["write_inflight"]
    assert (await b.step())["idle"]


@cocotb.test()
async def side_effect_read_issues_once_and_holds_its_result(dut: Any) -> None:
    """One request handoff produces one read despite long request/response stalls."""
    b = Bench(dut)
    await b.reset()
    for offset in range(0, 64, 8):
        s = await b.step(read_addr=0x10000 + offset, read_size=3, read_device=0)
        assert s["idle"] and s["read_ready"] and not s["req_valid"]
    await b.step(read_enable=1, read_addr=0x4000_0004, read_size=2, read_device=1)
    for _ in range(12):
        s = await b.step(read_enable=0, read_addr=0x10038, read_size=0, read_device=0)
        assert s["req_valid"] and not s["read_valid"] and not s["read_ready"]
        assert (s["req_addr"], s["req_size"], s["req_cache"]) == (0x4000_0004, 2, 0)
    await b.step(req_ready=1)
    for n in range(30):
        assert not (await b.step(req_ready=0, read_addr=0x10000 + 8 * (n % 8)))[
            "req_valid"
        ]
    await b.step(resp_valid=1, resp_rdata=0xDEADBEEF << 32, resp_status=3)
    for _ in range(15):
        s = await b.step(resp_valid=0)
        assert s["read_valid"] and s["read_status"] == 3
        assert s["read_data"] == 0xDEADBEEF << 32
        assert not s["req_valid"] and not s["read_ready"]
    await b.step(read_resp_ready=1)
    assert (await b.step())["idle"]


@cocotb.test()
async def stalled_read_does_not_change_when_store_arrives(dut: Any) -> None:
    """Check that a queued store cannot replace an already presented request."""
    b = Bench(dut)
    await b.reset()
    await b.step(read_enable=1, read_addr=0x10000, read_size=3)
    await b.step(read_enable=0)
    await b.step(
        write_enable=1,
        write_addr=0x4000_0000,
        write_size=2,
        write_device=1,
        write_strb=15,
    )
    s = await b.step(write_enable=0, req_ready=1)
    assert not s["req_write"] and s["req_addr"] == 0x10000
    await b.step(req_ready=0)
    await b.step(resp_valid=1, resp_rdata=0x99)
    s = await b.step(resp_valid=0, req_ready=1)
    assert s["req_write"] and s["req_addr"] == 0x4000_0000
    assert s["read_valid"] and s["read_data"] == 0x99
    await b.step(req_ready=0, read_resp_ready=1)
    await b.step(resp_valid=1)
    await b.step(resp_valid=0)
    assert (await b.step())["idle"]
