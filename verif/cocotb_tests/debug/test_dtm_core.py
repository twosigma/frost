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

"""Unit tests for dtm_core (hw/rtl/cpu_and_mem/debug/dtm_core.sv).

The bench drives the BSCAN-style bundle one TCK edge at a time, so a test
can place an update on any edge, and answers the core-side requests from a
debug-module model with a chosen latency and status. The model counts every
request, so a request issued twice is caught.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ABITS = 7
DMI_WIDTH = ABITS + 34
DTMCS_DMIRESET = 1 << 16
DTMCS_DMIHARDRESET = 1 << 17
OP_NOP, OP_READ, OP_WRITE = 0, 1, 2
STATUS_OK, STATUS_FAILED, STATUS_BUSY = 0, 2, 3
CLK_NS = 10
TCK_HALF_NS = 30


def _dmistat(dtmcs: int) -> int:
    return (dtmcs >> 10) & 3


class DebugModuleModel:
    """Counts every request pulse and answers them in order after ``latency`` cycles."""

    def __init__(self, dut: Any) -> None:
        """Start answering ``dut``'s core-side requests."""
        self.dut = dut
        self.regs: dict[int, int] = {}
        self.requests: list[tuple[int, int, int]] = []  # (op, addr, data)
        self.latency = 2
        self.resp_op = STATUS_OK
        self.read_override: int | None = None  # data for the next response
        self._answers: list[tuple[int, int, int]] = []  # (due cycle, data, status)
        self._cycle = 0
        dut.i_dmi_resp_valid.value = 0
        dut.i_dmi_resp_data.value = 0
        dut.i_dmi_resp_op.value = 0
        cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            self._cycle += 1
            dut.i_dmi_resp_valid.value = 0
            if self._answers and self._answers[0][0] <= self._cycle:
                _, rdata, status = self._answers.pop(0)
                dut.i_dmi_resp_valid.value = 1
                dut.i_dmi_resp_data.value = rdata
                dut.i_dmi_resp_op.value = status
            if int(dut.o_dmi_req_valid.value):
                op = int(dut.o_dmi_req_op.value)
                addr = int(dut.o_dmi_req_addr.value)
                data = int(dut.o_dmi_req_data.value)
                self.requests.append((op, addr, data))
                if op == OP_WRITE:
                    self.regs[addr] = data
                rdata = self.regs.get(addr, 0) if op == OP_READ else 0
                if self.read_override is not None:
                    rdata, self.read_override = self.read_override, None
                due = max(
                    self._cycle + self.latency,
                    self._answers[-1][0] + 1 if self._answers else 0,
                )
                self._answers.append((due, rdata, self.resp_op))


class Bscan:
    """One TCK edge at a time on the BSCAN-style bundle."""

    def __init__(self, dut: Any) -> None:
        """Drive every bundle input low."""
        self.dut = dut
        for sig in (
            dut.i_tck,
            dut.i_tlr,
            dut.i_capture,
            dut.i_shift,
            dut.i_update,
            dut.i_sel_dtmcs,
            dut.i_sel_dmi,
            dut.i_tdi,
        ):
            sig.value = 0

    async def edge(
        self,
        *,
        dtmcs: bool = False,
        dmi: bool = False,
        capture: bool = False,
        shift: bool = False,
        update: bool = False,
        tdi: int = 0,
        tlr: bool = False,
    ) -> int:
        """Drive the levels, then one TCK rising edge; return TDO before it."""
        dut = self.dut
        dut.i_sel_dtmcs.value = int(dtmcs)
        dut.i_sel_dmi.value = int(dmi)
        dut.i_capture.value = int(capture)
        dut.i_shift.value = int(shift)
        dut.i_update.value = int(update)
        dut.i_tdi.value = tdi
        dut.i_tlr.value = int(tlr)
        await Timer(TCK_HALF_NS, unit="ns")
        tdo = int(dut.o_tdo_dmi.value if dmi else dut.o_tdo_dtmcs.value)
        dut.i_tck.value = 1
        await Timer(TCK_HALF_NS, unit="ns")
        dut.i_tck.value = 0
        return tdo

    async def idle(self, edges: int) -> None:
        """Run-Test/Idle: edges with every level low."""
        for _ in range(edges):
            await self.edge()

    async def capture_shift(self, value: int, width: int, dmi: bool) -> int:
        """Capture, then shift ``value`` in LSB first; return the captured value."""
        sel = {"dmi": dmi, "dtmcs": not dmi}
        await self.edge(capture=True, **sel)
        captured = 0
        for i in range(width):
            bit = await self.edge(shift=True, tdi=(value >> i) & 1, **sel)
            captured |= bit << i
        return captured

    async def update(self, dmi: bool) -> None:
        """One Update-DR edge on the selected register."""
        await self.edge(update=True, dmi=dmi, dtmcs=not dmi)

    async def dtmcs(self, value: int = 0) -> int:
        """Scan dtmcs and return the captured value."""
        captured = await self.capture_shift(value, 32, dmi=False)
        await self.update(dmi=False)
        await self.idle(2)
        return captured

    async def dmi(self, op: int, addr: int = 0, data: int = 0) -> tuple[int, int]:
        """Scan dmi; return the captured (status, data)."""
        value = (addr << 34) | ((data & 0xFFFFFFFF) << 2) | op
        captured = await self.capture_shift(value, DMI_WIDTH, dmi=True)
        await self.update(dmi=True)
        await self.idle(2)
        return captured & 3, (captured >> 2) & 0xFFFFFFFF

    async def result(self, limit: int = 40) -> tuple[int, int]:
        """Nop scans until the status is not busy (clearing sticky busy)."""
        for _ in range(limit):
            status, data = await self.dmi(OP_NOP)
            if status != STATUS_BUSY:
                return status, data
            await self.dtmcs(DTMCS_DMIRESET)
            await self.idle(8)
        raise AssertionError("the DTM stayed busy")


async def _setup(dut: Any) -> tuple[Bscan, DebugModuleModel]:
    Clock(dut.i_clk, CLK_NS, unit="ns").start()
    jtag = Bscan(dut)
    model = DebugModuleModel(dut)
    await jtag.idle(4)
    return jtag, model


async def _wait_answered(jtag: Bscan, model: DebugModuleModel, count: int) -> None:
    """Idle until the model has answered ``count`` requests and the ack is in."""
    for _ in range(400):
        await jtag.idle(1)
        if len(model.requests) >= count and not int(jtag.dut.busy.value):
            return
    raise AssertionError(
        f"{len(model.requests)} requests, busy {int(jtag.dut.busy.value)}"
    )


@cocotb.test()
async def test_read_write_roundtrip(dut: Any) -> None:
    """A write and a read each reach the module once and return their data."""
    jtag, model = await _setup(dut)
    await jtag.dmi(OP_WRITE, 0x04, 0x1234_5678)
    assert await jtag.result() == (STATUS_OK, 0)
    await jtag.dmi(OP_READ, 0x04)
    assert await jtag.result() == (STATUS_OK, 0x1234_5678)
    assert model.requests == [(OP_WRITE, 0x04, 0x1234_5678), (OP_READ, 0x04, 0)]


@cocotb.test()
async def test_hardreset_abandons_request_in_flight(dut: Any) -> None:
    """Dmihardreset abandons a slow request: it runs once and its data is dropped.

    The DTM stays busy until the abandoned response arrives, then serves the
    next request normally.
    """
    jtag, model = await _setup(dut)
    await jtag.dmi(OP_WRITE, 0x05, 0x1111_1111)
    assert await jtag.result() == (STATUS_OK, 0)
    await jtag.dmi(OP_READ, 0x05)
    assert await jtag.result() == (STATUS_OK, 0x1111_1111)
    requests_before = len(model.requests)

    model.latency = 600
    model.read_override = 0xDEAD_BEEF
    await jtag.dmi(OP_WRITE, 0x06, 0x2222_2222)
    await jtag.dtmcs(DTMCS_DMIHARDRESET)
    await _wait_answered(jtag, model, requests_before + 1)
    await jtag.idle(40)
    assert len(model.requests) == requests_before + 1, (
        f"the abandoned request was issued again: {model.requests[requests_before:]}"
    )
    assert model.regs[0x06] == 0x2222_2222
    status, data = await jtag.dmi(OP_NOP)
    assert status == STATUS_OK and data == 0x1111_1111, (
        f"the abandoned response was kept: status {status} data {data:#x}"
    )

    model.latency = 2
    await jtag.dmi(OP_READ, 0x06)
    assert await jtag.result() == (STATUS_OK, 0x2222_2222)
    assert len(model.requests) == requests_before + 2


@cocotb.test()
async def test_hardreset_on_the_response_edge(dut: Any) -> None:
    """A dmihardreset update on the very edge the response arrives drops that response.

    It must leave no abandon mark behind, so the next response is kept.
    """
    jtag, model = await _setup(dut)
    await jtag.dmi(OP_WRITE, 0x07, 0x3333_3333)
    assert await jtag.result() == (STATUS_OK, 0)
    requests_before = len(model.requests)

    # A slow request, then dtmcs shifted with dmihardreset but not updated.
    model.latency = 450
    model.read_override = 0xDEAD_BEEF
    await jtag.dmi(OP_READ, 0x07)
    await jtag.capture_shift(DTMCS_DMIHARDRESET, 32, dmi=False)
    assert int(dut.busy.value) == 1, "the response arrived before the update was placed"
    for _ in range(400):
        await Timer(TCK_HALF_NS // 2, unit="ns")
        if int(dut.resp_arrived.value):
            break
        await jtag.edge()
    else:
        raise AssertionError("the response never arrived")
    await jtag.update(dmi=False)
    assert int(dut.busy.value) == 0, "dmihardreset left the DTM busy"
    await jtag.idle(4)
    assert len(model.requests) == requests_before + 1
    status, data = await jtag.dmi(OP_NOP)
    assert status == STATUS_OK and data != 0xDEAD_BEEF

    model.latency = 2
    await jtag.dmi(OP_READ, 0x07)
    assert await jtag.result() == (STATUS_OK, 0x3333_3333)
    assert len(model.requests) == requests_before + 2


@cocotb.test()
async def test_dmistat_reports_the_sticky_status(dut: Any) -> None:
    """dtmcs.dmistat is 0 while a request is merely in flight, and shows sticky errors.

    A capture while busy sets sticky busy (3), a failed response sets sticky
    failed (2), and dmireset clears either.
    """
    jtag, model = await _setup(dut)
    dtmcs = await jtag.dtmcs()
    assert dtmcs & 0xF == 1 and (dtmcs >> 4) & 0x3F == ABITS and (dtmcs >> 12) & 7 == 3

    model.latency = 600
    await jtag.dmi(OP_READ, 0x04)
    assert int(dut.busy.value) == 1
    assert _dmistat(await jtag.dtmcs()) == 0, "dmistat reported an in-flight request"
    status, _ = await jtag.dmi(OP_NOP)
    assert status == STATUS_BUSY
    assert _dmistat(await jtag.dtmcs()) == STATUS_BUSY
    await _wait_answered(jtag, model, 1)
    assert _dmistat(await jtag.dtmcs(DTMCS_DMIRESET)) == STATUS_BUSY
    assert _dmistat(await jtag.dtmcs()) == 0

    model.latency = 2
    model.resp_op = STATUS_FAILED
    await jtag.dmi(OP_READ, 0x04)
    await _wait_answered(jtag, model, 2)
    assert _dmistat(await jtag.dtmcs()) == STATUS_FAILED
    status, _ = await jtag.dmi(OP_NOP)
    assert status == STATUS_FAILED
    model.resp_op = STATUS_OK
    await jtag.dtmcs(DTMCS_DMIRESET)
    assert _dmistat(await jtag.dtmcs()) == 0
    await jtag.dmi(OP_READ, 0x04)
    assert await jtag.result() == (STATUS_OK, 0)
    await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_failed_response_replaces_sticky_busy(dut: Any) -> None:
    """A failed response that arrives while sticky busy is set replaces busy with failed.

    Busy recovery (dmireset, then a retry) would otherwise clear the status and
    the failure would never be reported.
    """
    jtag, model = await _setup(dut)
    model.latency = 600
    model.resp_op = STATUS_FAILED
    await jtag.dmi(OP_READ, 0x04)
    status, _ = await jtag.dmi(OP_NOP)
    assert status == STATUS_BUSY
    await _wait_answered(jtag, model, 1)
    assert _dmistat(await jtag.dtmcs()) == STATUS_FAILED, (
        "the failure stayed hidden behind busy"
    )
    status, _ = await jtag.dmi(OP_NOP)
    assert status == STATUS_FAILED

    model.latency = 2
    model.resp_op = STATUS_OK
    await jtag.dtmcs(DTMCS_DMIRESET)
    await jtag.dmi(OP_READ, 0x04)
    assert await jtag.result() == (STATUS_OK, 0)
