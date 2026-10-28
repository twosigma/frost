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

import os

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Immediate
from cocotb.triggers import FallingEdge, ReadWrite, Timer, with_timeout

from cocotb_tests.test_real_program import fail_on_nic_access


class Bench:
    """Drive one CPU-side AXI transaction at a time."""

    def __init__(self, dut: Any) -> None:
        """Bind the public SoC interface."""
        self.dut = dut
        self.bus_bytes = len(dut.i_axi_wstrb)
        self.cpu_period = int(os.environ.get("FROST_SOC_AXIL_CPU_PERIOD_PS", "0"))
        self.clock = dut.i_cpu_clk if self.cpu_period else dut.i_clk
        self.period = self.cpu_period or 10000

    async def step(self, **inputs: int) -> dict[str, int]:
        """Sample the CPU-facing bus before advancing its clock."""
        self.clock.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(self.period // 2, unit="ps")
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
        self.clock.value = 1
        await Timer(self.period - self.period // 2, unit="ps")
        return result

    async def reset(self) -> None:
        """Reset both the subsystem and CPU-facing AXI bus."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = Immediate(0)
        await ReadWrite()
        if self.cpu_period:
            Clock(self.dut.i_clk, 3000, unit="ps").start()
            await Timer(700, unit="ps")
        for _ in range(20 if self.cpu_period else 5):
            await self.step(rst=1, ddr_axi_rst=1, power_on_rst=1)
        for _ in range(30 if self.cpu_period else 4):
            await self.step(
                rst=0,
                ddr_axi_rst=0,
                power_on_rst=0,
                axi_awburst=1,
                axi_arburst=1,
                axi_wlast=1,
                axi_awid=(1 << len(self.dut.i_axi_awid)) - 1,
                axi_arid=1,
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
        reset_after_response: bool = False,
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
        await self.response("b", status, reset_delay, reset_after_response)

    async def read(
        self,
        addr: int,
        size: int = 2,
        status: int = 0,
        reset_delay: int | None = None,
        reset_after_response: bool = False,
    ) -> int:
        """Read a register pair and hold the response under CPU backpressure."""
        await self.address("ar", addr, size)
        s = await self.response("r", status, reset_delay, reset_after_response)
        return (s["rdata"] >> (8 * (addr & (self.bus_bytes - 1)))) & (
            (1 << (8 << size)) - 1
        )

    def set_fabric_reset(self, value: int) -> None:
        """Drive fabric reset and the common-clock subsystem reset."""
        self.dut.i_ddr_axi_rst.value = value
        if not self.cpu_period:
            self.dut.i_rst.value = value

    async def expected_reset_read(self, value: int) -> int:
        """Predict data from register response acceptance or reset cancellation."""
        for _ in range(100):
            await FallingEdge(self.dut.i_clk)
            await Timer(1, unit="ps")
            reset = int(self.dut.rst_core.value)
            accepted = int(self.dut.reg_axil_rvalid.value) & int(
                self.dut.reg_axil_rready.value
            )
            if int(self.dut.local_state_q.value) == 5 and (reset or accepted):
                return 0 if reset else value
        raise AssertionError("Register read did not complete in the SoC domain")

    async def pulse_reset(self, delay: int, wait_for_register: bool) -> None:
        """Reset the register path at a selected SoC clock edge."""
        if wait_for_register:
            for _ in range(100):
                await FallingEdge(self.dut.i_clk)
                if int(self.dut.local_state_q.value) == 5:
                    break
            else:
                raise AssertionError("Register request did not reach AXI4-Lite")
        for _ in range(delay + 1):
            await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 1
        for _ in range(4):
            await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0

    async def response(
        self,
        channel: str,
        status: int,
        reset_delay: int | None,
        reset_after_response: bool,
    ) -> dict[str, int]:
        """Hold a response through backpressure and an optional reset pulse."""
        cycle = 0
        reset_start = reset_delay
        reset_task = (
            cocotb.start_soon(self.pulse_reset(reset_delay, True))
            if self.cpu_period and reset_delay is not None
            else None
        )
        address_channel = "aw" if channel == "b" else "ar"
        expected_id = int(getattr(self.dut, f"i_axi_{address_channel}id").value)

        async def step(**inputs: int) -> dict[str, int]:
            nonlocal cycle
            if not self.cpu_period:
                inputs["rst"] = int(
                    reset_start is not None and reset_start <= cycle < reset_start + 4
                )
            cycle += 1
            return await self.step(**inputs)

        for _ in range(100):
            sample = await step()
            if sample[channel + "valid"]:
                assert sample[channel + "resp"] == status
                assert sample[channel + "id"] == expected_id
                if channel == "r":
                    assert sample["rlast"]
                if reset_after_response:
                    if self.cpu_period:
                        reset_task = cocotb.start_soon(self.pulse_reset(1, False))
                    else:
                        reset_start = cycle + 1
                for _ in range(4):
                    held = await step()
                    assert held[channel + "valid"]
                    assert held[channel + "resp"] == sample[channel + "resp"]
                    assert held[channel + "id"] == expected_id
                    if channel == "r":
                        assert held["rdata"] == sample["rdata"] and held["rlast"]
                accepted = await step(**{f"axi_{channel}ready": 1})
                assert accepted[channel + "valid"]
                assert accepted[channel + "resp"] == status
                assert accepted[channel + "id"] == expected_id
                if channel == "r":
                    assert accepted["rdata"] == sample["rdata"] and accepted["rlast"]
                await step(**{f"axi_{channel}ready": 0})
                if reset_task is not None:
                    for _ in range(100):
                        if reset_task.done():
                            await reset_task
                            break
                        await step()
                    else:
                        raise AssertionError("Register reset did not complete")
                else:
                    while reset_start is not None and cycle < reset_start + 4:
                        await step()
                for _ in range(30 if self.cpu_period else 1):
                    await self.step(rst=0)
                return accepted
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
        reset_read_values = set()
        for delay in range(7):
            await b.write(addr, 1, reset_delay=delay)
            for _ in range(5):
                await b.step(rst=0)
            assert await b.read(addr) == 0
            await b.write(addr, 1)
            assert await b.read(addr) == 1
            expected = (
                cocotb.start_soon(b.expected_reset_read(1)) if b.cpu_period else None
            )
            value = await b.read(addr, reset_delay=delay)
            reset_read_values.add(value)
            assert value == (
                await expected if expected is not None else int(delay >= 4)
            )
            for _ in range(5):
                await b.step(rst=0)
            assert await b.read(addr) == 0
            assert await b.read(nic) == 0x4E494301
        assert reset_read_values == {0, 1}
        await b.write(addr, 1, reset_after_response=True)
        for _ in range(5):
            await b.step(rst=0)
        assert await b.read(addr) == 0
        await b.write(addr, 1)
        assert await b.read(addr, reset_after_response=True) == 1
        for _ in range(5):
            await b.step(rst=0)
        assert await b.read(addr) == 0


@cocotb.test()
async def fabric_reset(dut: Any) -> None:
    """Discard partial register transactions and held responses on fabric reset."""
    b = Bench(dut)
    await b.reset()
    for addr in (0x40020018, 0x40030044):
        for write in (False, True):
            for phase in ("address", "register", "response"):
                await b.write(addr, 1)

                async def reset_at_register() -> None:
                    for _ in range(100):
                        await FallingEdge(dut.i_clk)
                        await Timer(1, unit="ps")
                        valid = dut.reg_axil_awvalid if write else dut.reg_axil_arvalid
                        if int(valid.value):
                            b.set_fabric_reset(1)
                            return
                    raise AssertionError(
                        "Register request did not reach the reset point"
                    )

                reset_task = (
                    cocotb.start_soon(reset_at_register())
                    if phase == "register"
                    else None
                )
                await b.address("aw" if write else "ar", addr, 2)
                if write and phase != "address":
                    lane = addr & (b.bus_bytes - 1)
                    for _ in range(100):
                        sample = await b.step(
                            axi_wvalid=1,
                            axi_wdata=2 << (8 * lane),
                            axi_wstrb=15 << lane,
                        )
                        if sample["wready"]:
                            dut.i_axi_wvalid.value = 0
                            break
                    else:
                        raise AssertionError("Register W did not reach the reset point")
                if phase == "register":
                    assert reset_task is not None
                    for _ in range(100):
                        if reset_task.done():
                            await reset_task
                            break
                        await b.step()
                    else:
                        raise AssertionError("Register reset point timed out")
                elif phase == "response":
                    for _ in range(100):
                        sample = await b.step()
                        if sample["bvalid" if write else "rvalid"]:
                            break
                    else:
                        raise AssertionError(
                            "Register response did not reach the reset point"
                        )
                b.set_fabric_reset(1)
                for _ in range(20):
                    await b.step()
                b.set_fabric_reset(0)
                for _ in range(40):
                    sample = await b.step(axi_bready=1, axi_rready=1)
                    assert not sample["bvalid"] and not sample["rvalid"]
                await b.step(axi_bready=0, axi_rready=0)
                await b.write(addr, 3)
                assert await b.read(addr) == 3
                assert await b.read(0x40030000) == 0x4E494301


@cocotb.test()
async def nic_access_guard(dut: Any) -> None:
    """Detect NIC loads and stores when the MAC clocks are absent."""
    b = Bench(dut)
    await b.reset()

    async def expect_access() -> None:
        try:
            await fail_on_nic_access(dut.nic_access_q)
        except AssertionError as exc:
            assert "accessed the NIC's registers" in str(exc)
        else:
            raise AssertionError("NIC access did not fail the guard")

    for _ in range(5):
        await b.step(axi_araddr=0x40030000, axi_awaddr=0x4003000C)
        assert not dut.nic_access_q.value

    for write, size in ((False, 2), (True, 0), (True, 2), (True, 3)):
        await b.read(0x40001008)
        guard = cocotb.start_soon(expect_access())
        try:
            if write:
                await b.write(0x40030070, 1, size)
            else:
                await b.read(0x40030000)
            await with_timeout(guard, 100, "ns")
        finally:
            guard.cancel()
