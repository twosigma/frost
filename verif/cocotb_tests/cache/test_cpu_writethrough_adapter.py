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

"""Check the read-cache/write-through policy at the CPU request boundary."""

from typing import Any
import cocotb
from cocotb_tests.cache.test_cpu_uncached_adapter import Bench


@cocotb.test()
async def normal_reads_widen_but_devices_and_debug_stay_narrow(dut: Any) -> None:
    """Only cacheable Normal data may be fetched as an aligned dword."""
    b = Bench(dut)
    await b.reset()
    dut.i_write_buffered.value = 0
    for device, address, expected_cache in (
        (0, 0x5000, 14),
        (1, 0x40000000, 0),
        (0, 0x17000, 2),
    ):
        for size in range(4):
            for offset in range(0, 64, 1 << size):
                addr = address + offset
                await b.step(
                    read_enable=1, read_addr=addr, read_size=size, read_device=device
                )
                s = await b.step(read_enable=0)
                expected_addr = addr & ~7 if expected_cache == 14 else addr
                expected_size = 3 if expected_cache == 14 else size
                assert (s["req_addr"], s["req_size"], s["req_cache"]) == (
                    expected_addr,
                    expected_size,
                    expected_cache,
                )
                for _ in range(3):
                    assert not (await b.step())["read_valid"]
                await b.step(req_ready=1)
                response = sum((0x100 + lane) << (64 * lane) for lane in range(8))
                await b.step(req_ready=0, resp_valid=1, resp_rdata=response)
                s = await b.step(resp_valid=0)
                assert s["read_valid"] and s["read_data"] == 0x100 + offset // 8
                await b.step(read_resp_ready=1)
                await b.step(read_resp_ready=0)


@cocotb.test()
async def buffered_store_waits_for_b_and_latches_late_failure(dut: Any) -> None:
    """Already retired Normal stores keep ownership until B, including errors."""
    b = Bench(dut)
    await b.reset()
    await b.step(
        write_enable=1,
        write_buffered=1,
        write_addr=0x5023,
        write_size=0,
        write_device=0,
        write_data=0xA5 << 24,
        write_strb=8,
    )
    s = await b.step(write_enable=0)
    assert (s["req_addr"], s["req_size"], s["req_cache"], s["req_wstrb"]) == (
        0x5023,
        0,
        6,
        1 << 35,
    )
    # A failed retired store must also block its already queued successor.
    await b.step(
        write_enable=1,
        write_addr=0x5030,
        write_size=3,
        write_data=0xBB,
        write_strb=255,
    )
    await b.step(write_enable=0)
    for _ in range(10):
        assert not (await b.step())["write_done"]
    await b.step(req_ready=1)
    for _ in range(30):
        s = await b.step(req_ready=0)
        assert s["write_inflight"] and not s["write_done"]
        assert not int(dut.o_fatal_error.value)
    await b.step(resp_valid=1, resp_status=2)
    for _ in range(8):
        s = await b.step(resp_valid=0)
        assert int(dut.o_fatal_error.value)
        assert int(dut.o_fatal_addr.value) == 0x5023
        assert s["write_inflight"] and not s["write_done"] and not s["req_valid"]
    await b.reset()
    assert not int(dut.o_fatal_error.value)


@cocotb.test()
async def same_normal_address_precise_atomic_errors_are_not_fatal(dut: Any) -> None:
    """Keep a store-conditional or AMO precise when its B error arrives."""
    b = Bench(dut)
    for status in (0, 2, 3):
        await b.reset()
        await b.step(
            write_enable=1,
            write_buffered=0,
            write_addr=0x5020,
            write_size=3,
            write_device=0,
            write_data=123,
            write_strb=255,
        )
        await b.step(write_enable=0, req_ready=1)
        for _ in range(12):
            assert not (await b.step(req_ready=0))["write_done"]
        await b.step(resp_valid=1, resp_status=status)
        s = await b.step(resp_valid=0)
        assert s["write_done"] and s["write_status"] == status
        assert not int(dut.o_fatal_error.value)
        assert not (await b.step())["write_done"]


@cocotb.test()
async def queued_writes_turn_over_without_losing_owners(dut: Any) -> None:
    """Pop, enqueue and present the next owner on one successful B response."""
    b = Bench(dut)
    for accept_next in (0, 1):
        await b.reset()
        await b.step(
            write_enable=1,
            write_buffered=1,
            write_addr=0x5000,
            write_size=3,
            write_device=0,
            write_data=0xAA,
            write_strb=255,
        )
        await b.step(write_addr=0x5008, write_data=0xBB)
        first = await b.step(write_enable=0, req_ready=1)
        assert first["req_valid"] and first["req_addr"] == 0x5000
        for _ in range(4):
            s = await b.step(req_ready=0)
            assert not s["req_valid"] and not s["write_done"]

        # Returning A frees a slot for C while B is presented to the fabric.
        s = await b.step(
            resp_valid=1,
            resp_status=0,
            req_ready=accept_next,
            write_enable=1,
            write_addr=0x5010,
            write_data=0xCC,
        )
        assert s["write_ready"] and not s["write_done"]
        assert s["req_valid"] and s["req_write"] and s["req_addr"] == 0x5008
        assert s["req_wstrb"] == 255 << 8
        assert s["req_wdata"] & ((1 << 64) - 1) == 0xBB
        s = await b.step(resp_valid=0, write_enable=0, req_ready=0)
        assert s["write_done"] and s["write_status"] == 0
        for _ in range(4):
            s = await b.step()
            assert not s["write_done"]
            assert bool(s["req_valid"]) == (not accept_next)
            if not accept_next:
                assert s["req_addr"] == 0x5008
        if not accept_next:
            assert (await b.step(req_ready=1))["req_valid"]
            await b.step(req_ready=0)

        # Returning B must select C, including the data written on A's pop.
        s = await b.step(resp_valid=1, req_ready=1)
        assert s["req_valid"] and s["req_addr"] == 0x5010
        assert s["req_wstrb"] == 255 << 16
        assert s["req_wdata"] & ((1 << 64) - 1) == 0xCC
        assert not s["write_done"]
        assert (await b.step(resp_valid=0, req_ready=0))["write_done"]
        for _ in range(4):
            s = await b.step()
            assert not s["req_valid"] and not s["write_done"]
        assert not (await b.step(resp_valid=1))["req_valid"]
        s = await b.step(resp_valid=0)
        assert s["write_done"] and s["idle"] and not s["write_inflight"]
        assert not (await b.step())["write_done"]
