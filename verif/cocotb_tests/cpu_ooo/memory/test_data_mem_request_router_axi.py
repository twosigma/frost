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

"""Test the router with variable-latency, error-capable uncached memory."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cpu_ooo.memory.test_data_mem_request_router import _clear_inputs


class Bench:
    """Observe request acceptance immediately before its rising clock edge."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut

    async def step(self, **inputs: int) -> dict[str, int]:
        """Advance one clock edge and sample the interface."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        names = (
            "uncached_read_enable",
            "uncached_read_size",
            "uncached_read_ready",
            "uncached_write_byte_en",
            "sq_mem_write_done",
            "sq_mem_write_error",
            "amo_mem_write_done",
            "amo_mem_write_error",
            "lq_mem_read_valid",
            "lq_mem_read_data",
            "lq_mem_read_error",
            "lq_mem_read_is_cached",
            "lq_mem_read_id",
            "lq_mem_request_valid",
            "device_request_pending",
            "mmio_read_pulse",
            "cached_read_ready",
            "cached_read_held",
            "data_mem_addr",
        )
        s = {n: int(getattr(self.dut, "o_" + n).value) for n in names}
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return s

    async def reset(self) -> None:
        """Reset the device and initialize its inputs."""
        _clear_inputs(self.dut)
        await self.step(
            rst=1,
            lq_mem_read_size=0,
            uncached_read_request_ready=1,
            uncached_read_valid=0,
            uncached_read_data=0,
            uncached_read_status=0,
            uncached_write_done=0,
            uncached_write_status=0,
            uncached_write_inflight=0,
        )
        await self.step(rst=0)


@cocotb.test()
async def device_read_waits_for_drain_admission_and_response(dut: Any) -> None:
    """Check that a side-effecting read is armed once, then waits for its actual response."""
    b = Bench(dut)
    await b.reset()
    s = await b.step(
        lq_mem_read_en=1,
        lq_mem_addr_valid=1,
        lq_mem_read_addr=0x4000_0004,
        lq_mem_read_size=2,
        sq_committed_empty=0,
    )
    assert not s["uncached_read_enable"]
    for _ in range(6):
        s = await b.step(lq_mem_read_en=0, lq_mem_read_addr=0x100, lq_mem_read_size=0)
        assert s["device_request_pending"] and not s["uncached_read_enable"]
    for _ in range(4):
        s = await b.step(sq_committed_empty=1, uncached_read_request_ready=0)
        assert not s["uncached_read_enable"] and not s["mmio_read_pulse"]
    s = await b.step(uncached_read_request_ready=1)
    assert s["uncached_read_enable"] and s["mmio_read_pulse"]
    assert s["data_mem_addr"] == 0x4000_0004 and s["uncached_read_size"] == 2
    for _ in range(20):
        s = await b.step()
        assert not s["uncached_read_enable"] and not s["mmio_read_pulse"]
        assert not s["lq_mem_read_valid"], "fixed-cycle response escaped in AXI mode"
    s = await b.step(
        uncached_read_valid=1,
        uncached_read_data=0x1234_0000_0000,
        uncached_read_status=3,
        cached_read_valid=1,
        cached_read_data=0x9999,
        cached_read_id=5,
    )
    assert s["lq_mem_read_valid"] and s["lq_mem_read_error"]
    assert s["lq_mem_read_data"] == 0x1234_0000_0000 and not s["lq_mem_read_is_cached"]
    assert (
        s["uncached_read_ready"]
        and not s["cached_read_ready"]
        and s["cached_read_held"]
    )
    s = await b.step(uncached_read_valid=0)
    assert s["lq_mem_read_is_cached"] and s["lq_mem_read_id"] == 5
    assert s["lq_mem_read_data"] == 0x9999 and not s["lq_mem_read_error"]


@cocotb.test()
async def flush_cancels_unaccepted_device_read(dut: Any) -> None:
    """Cancel the held request before the peripheral sees a transaction."""
    b = Bench(dut)
    await b.reset()
    await b.step(
        lq_mem_read_en=1,
        lq_mem_read_addr=0x4000_0008,
        lq_mem_read_size=2,
        uncached_read_request_ready=0,
    )
    await b.step(lq_mem_read_en=0)
    await b.step()
    s = await b.step(flush_all=1, uncached_read_request_ready=1)
    assert not s["uncached_read_enable"] and not s["mmio_read_pulse"]
    for _ in range(6):
        s = await b.step(flush_all=0)
        assert not s["lq_mem_request_valid"] and not s["uncached_read_enable"]
        assert not s["lq_mem_read_valid"]


@cocotb.test()
async def uncached_store_waits_for_b_and_returns_error(dut: Any) -> None:
    """SQ completion and fence-drain progress wait for the real write reply."""
    b = Bench(dut)
    await b.reset()
    s = await b.step(
        sq_mem_write_en=1,
        sq_mem_write_addr=0x4000_0000,
        sq_mem_write_is_mmio=1,
        sq_mem_write_byte_en=15,
    )
    assert s["uncached_write_byte_en"] == 15 and not s["sq_mem_write_done"]
    for _ in range(20):
        s = await b.step(sq_mem_write_en=0, uncached_write_inflight=1)
        assert not s["sq_mem_write_done"] and not s["uncached_write_byte_en"]
    s = await b.step(
        uncached_write_done=1, uncached_write_status=2, uncached_write_inflight=0
    )
    assert s["sq_mem_write_done"] and s["sq_mem_write_error"]
    assert not s["amo_mem_write_done"] and not s["amo_mem_write_error"]
    s = await b.step(uncached_write_done=0)
    assert not s["sq_mem_write_done"] and not s["sq_mem_write_error"]


@cocotb.test()
async def uncached_amo_write_is_not_reissued_while_waiting(dut: Any) -> None:
    """Check that the LQ's level request turns into exactly one narrow write handoff."""
    b = Bench(dut)
    await b.reset()
    s = await b.step(
        amo_mem_write_en=1,
        amo_mem_write_addr=0x104,
        amo_mem_write_data=0xAA,
        amo_mem_write_is_dword=0,
    )
    assert s["uncached_write_byte_en"] == 0xF0
    for _ in range(20):
        s = await b.step(uncached_write_inflight=1)
        assert not s["uncached_write_byte_en"] and not s["amo_mem_write_done"]
    s = await b.step(
        uncached_write_done=1, uncached_write_status=3, uncached_write_inflight=0
    )
    assert s["amo_mem_write_done"] and s["amo_mem_write_error"]
    assert not s["sq_mem_write_done"] and not s["sq_mem_write_error"]
    s = await b.step(amo_mem_write_en=0, uncached_write_done=0)
    assert not s["uncached_write_byte_en"] and not s["amo_mem_write_done"]
