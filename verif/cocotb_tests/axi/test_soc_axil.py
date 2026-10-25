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

"""Exercise the SoC's AXI4-Lite device windows through its public AXI port."""

from typing import Any

import cocotb
from cocotb.triggers import Timer, with_timeout

from cocotb_tests.test_real_program import fail_on_nic_access


class Bench:
    """Drive one CPU-side AXI transaction at a time."""

    def __init__(self, dut: Any) -> None:
        """Bind the public SoC interface."""
        self.dut = dut
        self.bus_bytes = len(dut.i_axi_wstrb)

    async def step(self, **inputs: int) -> dict[str, int]:
        """Sample before a rising edge and then advance the SoC."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        names = (
            "awready",
            "wready",
            "bvalid",
            "bresp",
            "bid",
            "arready",
            "rvalid",
            "rresp",
            "rid",
            "rdata",
            "rlast",
        )
        result = {name: int(getattr(self.dut, "o_axi_" + name).value) for name in names}
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return result

    async def reset(self) -> None:
        """Reset both the subsystem and CPU-facing AXI bus."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        for _ in range(5):
            await self.step(rst=1, ddr_axi_rst=1)
        for _ in range(4):
            await self.step(
                rst=0, ddr_axi_rst=0, axi_awburst=1, axi_arburst=1, axi_wlast=1
            )

    async def address(self, channel: str, addr: int, size: int) -> None:
        """Send one address and wait for its handshake."""
        for _ in range(50):
            s = await self.step(
                **{
                    f"axi_{channel}valid": 1,
                    f"axi_{channel}addr": addr,
                    f"axi_{channel}size": size,
                }
            )
            if s[f"{channel}ready"]:
                getattr(self.dut, f"i_axi_{channel}valid").value = 0
                return
        raise AssertionError("CPU AXI address timed out")

    async def write(
        self,
        addr: int,
        data: int,
        size: int = 2,
        strb: int | None = None,
        reset_delay: int | None = None,
        status: int = 0,
    ) -> None:
        """Complete a write, holding B and optionally resetting its slave."""
        await self.address("aw", addr, size)
        lane = addr & (self.bus_bytes - 1)
        data <<= lane * 8
        strobe = (((1 << (1 << size)) - 1) if strb is None else strb) << lane
        for _ in range(50):
            s = await self.step(axi_wvalid=1, axi_wdata=data, axi_wstrb=strobe)
            if s["wready"]:
                self.dut.i_axi_wvalid.value = 0
                break
        else:
            raise AssertionError("CPU AXI W timed out")
        await self.response("b", status, reset_delay)

    async def read(
        self,
        addr: int,
        size: int = 2,
        status: int = 0,
        reset_delay: int | None = None,
    ) -> int:
        """Read a register pair and hold the response under CPU backpressure."""
        await self.address("ar", addr, size)
        s = await self.response("r", status, reset_delay)
        return (s["rdata"] >> (8 * (addr & (self.bus_bytes - 1)))) & (
            (1 << (8 << size)) - 1
        )

    async def response(
        self, channel: str, status: int, reset_delay: int | None
    ) -> dict[str, int]:
        """Hold a response through backpressure and an optional reset pulse."""
        cycle = 0

        async def step(**inputs: int) -> dict[str, int]:
            nonlocal cycle
            inputs["rst"] = int(
                reset_delay is not None and reset_delay <= cycle < reset_delay + 4
            )
            cycle += 1
            return await self.step(**inputs)

        for _ in range(100):
            sample = await step()
            if sample[channel + "valid"]:
                assert sample[channel + "resp"] == status
                if channel == "r":
                    assert sample["rlast"]
                for _ in range(4):
                    held = await step()
                    assert held[channel + "valid"]
                    assert held[channel + "resp"] == sample[channel + "resp"]
                    if channel == "r":
                        assert held["rdata"] == sample["rdata"] and held["rlast"]
                await step(**{f"axi_{channel}ready": 1})
                await step(**{f"axi_{channel}ready": 0})
                while reset_delay is not None and cycle < reset_delay + 4:
                    await step()
                await self.step(rst=0)
                return sample
        raise AssertionError(f"CPU AXI {channel.upper()} timed out")


@cocotb.test()
async def device_windows(dut: Any) -> None:
    """Check lane mapping, wide-register suppression, errors and reset recovery."""
    b = Bench(dut)
    await b.reset()
    nic, dma = 0x40030000, 0x40020000
    assert await b.read(nic) == 0x4E494301
    await b.write(nic + 0xC, 0x12345678)
    assert await b.read(nic + 0xC) == 0x12345678
    await b.write(dma + 8, 0x80100000)
    await b.write(dma + 8, 0x80200000_80300000, 3)
    assert await b.read(dma + 8, 3) == 0x80200000_80100000
    for base, mode, offsets in (
        (nic, 0x6C, (0x70, 0x78)),
        (dma, 0x28, (0x40, 0x48, 0x50)),
    ):
        await b.write(base + mode, 1)
        for off in offsets:
            await b.write(base + off, 0x80400000, 3)
            assert await b.read(base + off, 3) == 0x80400000
            for mask in (0, 1, 15, 16, 128, 240, 254):
                await b.write(base + off, 0x12345678, 3, strb=mask)
                assert await b.read(base + off, 3) == 0x80400000
            await b.write(base + off + 4, 0x87654321)
            assert await b.read(base + off, 3) == 0x80400000
    # Wide Device requests fail at the CPU-facing slave without side effects.
    await b.write(nic + 0x70, 0xFFFFFFFF, 4, status=3)
    assert await b.read(nic + 0x70, 3) == 0x80400000
    await b.read(nic, 4, status=3)
    assert await b.read(0x40001008) != 0
    # Subsystem reset can cancel a slave while the CPU-facing AXI stays up.
    for addr in (dma + 0x18, nic + 0x44):
        for delay in range(7):
            await b.write(addr, 1, reset_delay=delay)
            for _ in range(5):
                await b.step(rst=0)
            assert await b.read(addr) == 0
            await b.write(addr, 1)
            assert await b.read(addr) == 1
            value = await b.read(addr, reset_delay=delay)
            assert value in (0, 1)
            if delay < 4:
                assert value == 0
            for _ in range(5):
                await b.step(rst=0)
            assert await b.read(addr) == 0
            assert await b.read(nic) == 0x4E494301


@cocotb.test()
async def nic_access_guard(dut: Any) -> None:
    """Detect NIC loads and stores when the MAC clocks are absent."""
    b = Bench(dut)
    await b.reset()

    async def expect_access() -> None:
        try:
            await fail_on_nic_access(dut)
        except AssertionError as exc:
            assert "accessed the NIC's registers" in str(exc)
        else:
            raise AssertionError("NIC access did not fail the guard")

    for write in (False, True):
        await b.read(0x40001008)
        guard = cocotb.start_soon(expect_access())
        try:
            if write:
                await b.write(0x4003000C, 1)
            else:
                await b.read(0x40030000)
            await with_timeout(guard, 100, "ns")
        finally:
            guard.cancel()
