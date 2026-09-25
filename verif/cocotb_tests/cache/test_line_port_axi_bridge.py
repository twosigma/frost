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

"""Reset tests for line_port_axi_bridge against an AXI slave that keeps running.

The bridge resets with the CPU, while on hardware the DDR controller and its
interconnect keep running through the image-load reset and the debug
ndmreset. The bench plays that slave in Python: it accepts AW and W
independently and pairs them in arrival order, as an interconnect does, and
it is never reset. Checked: a beat presented before a reset stays presented,
with a stable payload, until the slave accepts it (AXI's VALID-until-READY
rule, which a slave that is not being reset relies on); a reset between the
AW and W handshakes of one write leaves no orphaned beat, so the next write
lands at its own address; the reverse split and a wholly unaccepted write
complete the same way; a read presented across a reset completes and its
response, now stale, never reaches the line port; and every transaction
issued after the reset completes normally.
"""

from collections import deque
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
BASE_ADDR = 0x8000_0000
FULL_STRB = (1 << LINE_BYTES) - 1
RESP_TIMEOUT_CYCLES = 200
RESET_CYCLES = 3


class _AxiSlave:
    """AXI4 slave for single-beat bursts that the bench never resets.

    Handshakes are evaluated mid-cycle, after the bench drives the ready
    lines at the falling edge: a channel fires at the next rising edge when
    its valid and ready are both high then. Accepted AW and W beats queue
    separately and pair in arrival order; each pair is written into a
    byte-addressed memory and answered on B. Reads are answered on R a few
    cycles after AR. Every cycle the slave also checks the master's side of
    the rule: a valid presented without a handshake must stay high, with the
    same payload, in the next cycle.
    """

    def __init__(self, dut: Any) -> None:
        """Start the slave; all ready lines begin high."""
        self._dut = dut
        self.awready = True
        self.wready = True
        self.arready = True
        self.aw: deque[tuple[int, int]] = deque()  # (id, addr)
        self.w: deque[tuple[int, int]] = deque()  # (data, strb)
        self.mem: dict[int, int] = {}  # byte address (AXI side) -> byte
        self.performed: list[tuple[int, int, int]] = []  # (addr, data, strb)
        self._b: deque[int] = deque()  # write ids waiting for B
        self._r: deque[tuple[int, int, int]] = deque()  # (due cycle, id, data)
        self.violations: list[str] = []
        self.cycle = 0
        self._held: dict[str, tuple[int, ...] | None] = {
            "aw": None,
            "w": None,
            "ar": None,
        }
        self._task = cocotb.start_soon(self._run())

    def read_line(self, addr: int) -> int:
        """Return the line at an AXI-side address from the slave's memory."""
        return sum(self.mem.get(addr + b, 0) << (8 * b) for b in range(LINE_BYTES))

    def _check_held(self, channel: str, valid: int, payload: tuple[int, ...]) -> None:
        held = self._held[channel]
        if held is not None and (not valid or payload != held):
            self.violations.append(
                f"cycle {self.cycle}: {channel} dropped or changed before its handshake"
            )

    async def _run(self) -> None:
        dut = self._dut
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            # The ready values driven now decide this cycle's handshakes; a
            # test that changes them later in this timestep takes effect at
            # the next falling edge.
            awready, wready, arready = self.awready, self.wready, self.arready
            dut.i_axi_awready.value = int(awready)
            dut.i_axi_wready.value = int(wready)
            dut.i_axi_arready.value = int(arready)
            b_id = self._b[0] if self._b else None
            dut.i_axi_bvalid.value = int(b_id is not None)
            dut.i_axi_bid.value = b_id or 0
            dut.i_axi_bresp.value = 0
            r = self._r[0] if self._r and self._r[0][0] <= self.cycle else None
            dut.i_axi_rvalid.value = int(r is not None)
            dut.i_axi_rid.value = r[1] if r else 0
            dut.i_axi_rdata.value = r[2] if r else 0
            dut.i_axi_rresp.value = 0
            dut.i_axi_rlast.value = 1
            await ReadOnly()
            awvalid = int(dut.o_axi_awvalid.value)
            wvalid = int(dut.o_axi_wvalid.value)
            arvalid = int(dut.o_axi_arvalid.value)
            aw = (int(dut.o_axi_awid.value), int(dut.o_axi_awaddr.value))
            w = (int(dut.o_axi_wdata.value), int(dut.o_axi_wstrb.value))
            ar = (int(dut.o_axi_arid.value), int(dut.o_axi_araddr.value))
            self._check_held("aw", awvalid, aw)
            self._check_held("w", wvalid, w)
            self._check_held("ar", arvalid, ar)
            self._held["aw"] = aw if awvalid and not awready else None
            self._held["w"] = w if wvalid and not wready else None
            self._held["ar"] = ar if arvalid and not arready else None
            if awvalid and awready:
                self.aw.append(aw)
            if wvalid and wready:
                self.w.append(w)
            if arvalid and arready:
                rid, addr = ar
                self._r.append((self.cycle + 4, rid, self.read_line(addr)))
            if b_id is not None and int(dut.o_axi_bready.value):
                self._b.popleft()
            if r is not None and int(dut.o_axi_rready.value):
                self._r.popleft()
            while self.aw and self.w:
                wid, addr = self.aw.popleft()
                data, strb = self.w.popleft()
                for b in range(LINE_BYTES):
                    if (strb >> b) & 1:
                        self.mem[addr + b] = (data >> (8 * b)) & 0xFF
                self.performed.append((addr, data, strb))
                self._b.append(wid)

    def stop(self) -> None:
        """Stop the slave."""
        self._task.cancel()


class _ResponseLog:
    """Record every line-port response pulse as (cycle, id)."""

    def __init__(self, dut: Any) -> None:
        self._dut = dut
        self.cycle = 0
        self.responses: list[tuple[int, int, int]] = []  # (cycle, id, rdata)
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            if int(dut.o_resp_valid.value):
                self.responses.append(
                    (self.cycle, int(dut.o_resp_id.value), int(dut.o_resp_rdata.value))
                )

    async def wait_for(self, req_id: int, after: int) -> int:
        """Wait for a response with req_id later than cycle `after`; return rdata."""
        for _ in range(RESP_TIMEOUT_CYCLES):
            for cycle, rid, rdata in self.responses:
                if rid == req_id and cycle > after:
                    return rdata
            await FallingEdge(self._dut.i_clk)
        raise AssertionError(f"no line-port response for id {req_id}")

    def stop(self) -> None:
        """Stop recording."""
        self._task.cancel()


def _pattern(seed: int) -> int:
    return int.from_bytes(
        bytes([(seed * 29 + b * 7) & 0xFF for b in range(32)]), "little"
    )


async def _start(dut: Any) -> tuple[_AxiSlave, _ResponseLog]:
    """Start the clock and the slave, and reset the bridge for a few cycles."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_req_valid.value = 0
    dut.i_req_write.value = 0
    dut.i_req_addr.value = 0
    dut.i_req_wdata.value = 0
    dut.i_req_wstrb.value = 0
    dut.i_req_id.value = 0
    slave = _AxiSlave(dut)
    log = _ResponseLog(dut)
    await _reset(dut)
    return slave, log


async def _reset(dut: Any) -> None:
    """Hold the bridge's reset for RESET_CYCLES cycles, driven at falling edges."""
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    for _ in range(RESET_CYCLES):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0


async def _fire(
    dut: Any, *, write: bool, addr: int, req_id: int, wdata: int = 0
) -> None:
    """Present one line request and return in the cycle after it fired."""
    await FallingEdge(dut.i_clk)
    dut.i_req_valid.value = 1
    dut.i_req_write.value = int(write)
    dut.i_req_addr.value = addr
    dut.i_req_wdata.value = wdata
    dut.i_req_wstrb.value = FULL_STRB if write else 0
    dut.i_req_id.value = req_id
    await Timer(1, unit="ns")
    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(dut.o_req_ready.value):
            break
        await FallingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    else:
        raise AssertionError(f"request id {req_id} never accepted")
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_req_valid.value = 0


async def _cycles(dut: Any, n: int) -> None:
    for _ in range(n):
        await FallingEdge(dut.i_clk)


@cocotb.test()
async def test_reset_between_aw_and_w_keeps_writes_paired(dut: Any) -> None:
    """A reset after AW is accepted but before W leaves no orphaned address.

    The slave takes AW and holds off W, the bridge resets, then W is
    accepted. The held W must pair with its own AW, and the next write must
    land at its own address and complete; the first write's response is
    stale after the reset and must not reach the line port.
    """
    slave, log = await _start(dut)
    first = (BASE_ADDR + 0x100, _pattern(1))
    second = (BASE_ADDR + 0x200, _pattern(2))

    slave.wready = False
    await _fire(dut, write=True, addr=first[0], req_id=1, wdata=first[1])
    await _cycles(dut, 3)
    assert len(slave.aw) == 1 and not slave.w, "AW was not accepted ahead of W"
    await _reset(dut)
    reset_end = log.cycle
    await _cycles(dut, 2)
    slave.wready = True

    await _fire(dut, write=True, addr=second[0], req_id=2, wdata=second[1])
    await log.wait_for(2, after=reset_end)
    await _cycles(dut, 8)

    assert not slave.violations, "; ".join(slave.violations)
    assert slave.performed == [
        (first[0] - BASE_ADDR, first[1], FULL_STRB),
        (second[0] - BASE_ADDR, second[1], FULL_STRB),
    ], f"writes paired wrongly: {[(hex(a), hex(d)) for a, d, _ in slave.performed]}"
    assert slave.read_line(second[0] - BASE_ADDR) == second[1]
    assert all(rid != 1 for cycle, rid, _ in log.responses if cycle > reset_end), (
        "the stale response of the write interrupted by the reset reached the line port"
    )
    slave.stop()
    log.stop()


@cocotb.test()
async def test_reset_between_w_and_aw_keeps_writes_paired(dut: Any) -> None:
    """The reverse split: W accepted, AW held across the reset, pairs correctly."""
    slave, log = await _start(dut)
    first = (BASE_ADDR + 0x300, _pattern(3))
    second = (BASE_ADDR + 0x400, _pattern(4))

    slave.awready = False
    await _fire(dut, write=True, addr=first[0], req_id=3, wdata=first[1])
    await _cycles(dut, 3)
    assert len(slave.w) == 1 and not slave.aw, "W was not accepted ahead of AW"
    await _reset(dut)
    reset_end = log.cycle
    await _cycles(dut, 2)
    slave.awready = True

    await _fire(dut, write=True, addr=second[0], req_id=4, wdata=second[1])
    await log.wait_for(4, after=reset_end)
    await _cycles(dut, 8)

    assert not slave.violations, "; ".join(slave.violations)
    assert slave.performed == [
        (first[0] - BASE_ADDR, first[1], FULL_STRB),
        (second[0] - BASE_ADDR, second[1], FULL_STRB),
    ], f"writes paired wrongly: {[(hex(a), hex(d)) for a, d, _ in slave.performed]}"
    slave.stop()
    log.stop()


@cocotb.test()
async def test_unaccepted_write_and_read_complete_across_reset(dut: Any) -> None:
    """A write and a read the slave has not accepted stay presented through reset.

    Both complete once the slave accepts them, their responses are dropped as
    stale, and transactions issued after the reset complete with their own
    data.
    """
    slave, log = await _start(dut)
    wr = (BASE_ADDR + 0x500, _pattern(5))
    rd = BASE_ADDR + 0x500

    slave.awready = False
    slave.wready = False
    slave.arready = False
    await _fire(dut, write=True, addr=wr[0], req_id=5, wdata=wr[1])
    await _fire(dut, write=False, addr=rd, req_id=6)
    await _cycles(dut, 2)
    await _reset(dut)
    reset_end = log.cycle
    await _cycles(dut, 2)
    slave.awready = True
    slave.wready = True
    await _cycles(dut, 2)
    slave.arready = True
    await _cycles(dut, 12)

    assert not slave.violations, "; ".join(slave.violations)
    assert slave.performed == [(wr[0] - BASE_ADDR, wr[1], FULL_STRB)], (
        "the write held across the reset did not complete once"
    )
    assert all(cycle <= reset_end for cycle, _, _ in log.responses), (
        "a stale response reached the line port after the reset"
    )

    # New transactions after the reset complete normally.
    after = (BASE_ADDR + 0x600, _pattern(6))
    await _fire(dut, write=True, addr=after[0], req_id=7, wdata=after[1])
    await log.wait_for(7, after=reset_end)
    await _fire(dut, write=False, addr=after[0], req_id=8)
    assert await log.wait_for(8, after=reset_end) == after[1]
    await _fire(dut, write=False, addr=wr[0], req_id=9)
    assert await log.wait_for(9, after=reset_end) == wr[1]
    assert not slave.violations, "; ".join(slave.violations)
    slave.stop()
    log.stop()
