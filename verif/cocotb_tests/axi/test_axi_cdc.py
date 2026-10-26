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

"""AXI channel conservation, full payloads, stalls, and reset cancellation."""

import random
from collections import deque

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, with_timeout

FIELDS = {
    "aw": "id addr len size burst lock cache prot qos region user".split(),
    "w": "data strb last user".split(),
    "b": "id resp user".split(),
    "ar": "id addr len size burst lock cache prot qos region user".split(),
    "r": "id data resp last user".split(),
}


async def _reset(dut: Any) -> None:
    dut.i_src_rst.value = 1
    dut.i_dst_rst.value = 1
    for channel in FIELDS:
        src, dst = ("src", "dst") if channel in ("aw", "w", "ar") else ("dst", "src")
        getattr(dut, f"i_{src}_{channel}valid").value = 0
        getattr(dut, f"i_{dst}_{channel}ready").value = 0
    await Timer(250, unit="ns")
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 0
    await FallingEdge(dut.i_dst_clk)
    dut.i_dst_rst.value = 0


async def _channel_test(dut: Any, channel: str, count: int, seed: int) -> None:
    rng = random.Random(seed)
    src, dst = ("src", "dst") if channel in ("aw", "w", "ar") else ("dst", "src")
    src_clk, dst_clk = (getattr(dut, f"i_{side}_clk") for side in (src, dst))
    src_valid = getattr(dut, f"i_{src}_{channel}valid")
    src_ready = getattr(dut, f"o_{src}_{channel}ready")
    dst_valid = getattr(dut, f"o_{dst}_{channel}valid")
    dst_ready = getattr(dut, f"i_{dst}_{channel}ready")
    src_fields = [getattr(dut, f"i_{src}_{channel}{f}") for f in FIELDS[channel]]
    dst_fields = [getattr(dut, f"o_{dst}_{channel}{f}") for f in FIELDS[channel]]
    expected: deque[tuple[int, ...]] = deque()

    async def send() -> None:
        for _ in range(count):
            data = tuple(rng.getrandbits(len(signal)) for signal in src_fields)
            await FallingEdge(src_clk)
            src_valid.value = 1
            for signal, value in zip(src_fields, data, strict=True):
                signal.value = value
            while True:
                await RisingEdge(src_clk)
                if int(src_ready.value):
                    expected.append(data)
                    break
            await FallingEdge(src_clk)
            src_valid.value = 0

    async def receive() -> None:
        held = None
        received = 0
        cycles = 0
        while received < count:
            await FallingEdge(dst_clk)
            # Long stalls fill the RAM and its output skid.
            ready = cycles % 97 >= 31 and rng.randrange(3) != 0
            cycles += 1
            dst_ready.value = ready
            await RisingEdge(dst_clk)
            valid = int(dst_valid.value)
            data = tuple(int(signal.value) for signal in dst_fields)
            if held is not None:
                assert valid and data == held
            held = data if valid and not ready else None
            if valid and ready:
                assert expected and expected.popleft() == data, channel
                received += 1

    sender = cocotb.start_soon(send())
    await with_timeout(receive(), 200, "us")
    await sender
    assert not expected


@cocotb.test()
async def independent_channels(dut: Any) -> None:
    """All five channels preserve their payloads at three clock ratios."""
    for index, (src_period, dst_period) in enumerate(((10, 10), (6, 17), (17, 6))):
        dut.i_src_clk.value = 0
        dut.i_dst_clk.value = 0
        a = Clock(dut.i_src_clk, src_period, unit="ns").start()
        await Timer(3, unit="ns")
        b = Clock(dut.i_dst_clk, dst_period, unit="ns").start()
        await _reset(dut)
        tasks = [
            cocotb.start_soon(_channel_test(dut, ch, 300, index * 17 + number))
            for number, ch in enumerate(FIELDS)
        ]
        for task in tasks:
            await task
        # Reset cancels queued words before traffic in the next epoch.
        for channel in FIELDS:
            src, dst = (
                ("src", "dst") if channel in ("aw", "w", "ar") else ("dst", "src")
            )
            getattr(dut, f"i_{dst}_{channel}ready").value = 0
            getattr(dut, f"i_{src}_{channel}valid").value = 1
        await Timer(200, unit="ns")
        await _reset(dut)
        tasks = [
            cocotb.start_soon(_channel_test(dut, ch, 50, index * 31 + number))
            for number, ch in enumerate(FIELDS)
        ]
        for task in tasks:
            await task
        a.cancel()
        b.cancel()


@cocotb.test()
async def empty_read_latency(dut: Any) -> None:
    """Line and narrow reads expose request and response transport delays."""
    from cocotb.utils import get_sim_time

    for cpu_period in (3000, 1300, 7000):
        soc_period = 3000
        dut.i_src_clk.value = 0
        dut.i_dst_clk.value = 0
        soc_clock = Clock(dut.i_dst_clk, soc_period, unit="ps").start()
        await Timer(700, unit="ps")
        cpu_clock = Clock(dut.i_src_clk, cpu_period, unit="ps").start()
        for kind, address, size in (
            ("line", 0x80000000, (len(dut.i_src_wdata) // 8).bit_length() - 1),
            ("uncached", 0x40000000, 3),
        ):
            await _reset(dut)
            dut.i_dst_arready.value = 1
            dut.i_src_rready.value = 1
            await FallingEdge(dut.i_src_clk)
            dut.i_src_araddr.value = address
            dut.i_src_arsize.value = size
            dut.i_src_arlen.value = 0
            dut.i_src_arvalid.value = 1
            await RisingEdge(dut.i_src_clk)
            assert int(dut.o_src_arready.value)
            request_start = get_sim_time(unit="ps")
            await FallingEdge(dut.i_src_clk)
            dut.i_src_arvalid.value = 0
            while True:
                await RisingEdge(dut.i_dst_clk)
                if int(dut.o_dst_arvalid.value):
                    break
            request_end = get_sim_time(unit="ps")
            assert int(dut.o_dst_araddr.value) == address
            await FallingEdge(dut.i_dst_clk)
            dut.i_dst_rdata.value = address
            dut.i_dst_rvalid.value = 1
            dut.i_dst_rlast.value = 1
            await RisingEdge(dut.i_dst_clk)
            assert int(dut.o_dst_rready.value)
            response_start = get_sim_time(unit="ps")
            await FallingEdge(dut.i_dst_clk)
            dut.i_dst_rvalid.value = 0
            while True:
                await RisingEdge(dut.i_src_clk)
                if int(dut.o_src_rvalid.value):
                    break
            response_end = get_sim_time(unit="ps")
            assert int(dut.o_src_rdata.value) == address
            outward = request_end - request_start
            inward = response_end - response_start
            assert 4 * soc_period <= outward <= 5 * soc_period
            assert 4 * cpu_period <= inward <= 5 * cpu_period
            dut._log.info(
                "CDC_LATENCY kind=%s cpu_ps=%s soc_ps=%s request_ps=%s response_ps=%s "
                "soc_cycles=%.6f cpu_cycles=%.6f",
                kind,
                cpu_period,
                soc_period,
                outward,
                inward,
                outward / soc_period,
                inward / cpu_period,
            )
        soc_clock.cancel()
        cpu_clock.cancel()
