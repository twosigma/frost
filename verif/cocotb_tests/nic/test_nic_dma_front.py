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

"""Unit tests for nic_dma_front (hw/rtl/peripherals/nic/nic_dma_front.sv).

A Python model of the coherent DMA port: it may refuse a request whose
line it "holds locked", answers after a random latency and out of order,
and echoes a function of the address as read data. Checked: every
response reaches its owner with its kind and tag and the right data (id
conservation and steering); a side never holds more than its cap so the
other side always finds an entry; RX priority with the grant-counted
bound (TX is served within the bound under continuous RX traffic); a
refused RX request lets a TX request to another line through the next
cycle; an address outside the aperture is refused locally with an error
response and no port request; the RESET drain withdraws registered
requests and reports idle once the fired ones returned.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

BASE = 0x8000_0000
LINE = 32


def _rdata(addr: int) -> int:
    return (addr * 0x9E3779B1) & ((1 << 256) - 1)


class _PortModel:
    """The DMA port slave: locks, latency, out-of-order responses."""

    def __init__(
        self,
        dut: Any,
        latency: tuple[int, int] = (2, 12),
        reorder: bool = True,
        seed: int = 0,
        ready_every: int = 1,
    ) -> None:
        self._dut = dut
        self.locked: set[int] = set()
        self.latency = latency
        self.reorder = reorder
        self.ready_every = (
            ready_every  # ready only on cycles that are multiples of this
        )
        self.rng = random.Random(seed)
        self.accepted: list[dict[str, int]] = []
        self.hold = False  # withhold every response
        self._pending: list[list[int]] = []  # [cycles_left, id, addr]
        self.cycle = 0
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        dut.i_dma_req_ready.value = 0
        dut.i_dma_resp_valid.value = 0
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            # Responses.
            dut.i_dma_resp_valid.value = 0
            if not self.hold:
                ready_ones = [p for p in self._pending if p[0] <= 0]
                if ready_ones:
                    p = self.rng.choice(ready_ones) if self.reorder else ready_ones[0]
                    self._pending.remove(p)
                    dut.i_dma_resp_valid.value = 1
                    dut.i_dma_resp_id.value = p[1]
                    dut.i_dma_resp_rdata.value = _rdata(p[2])
            for p in self._pending:
                p[0] -= 1
            # Requests: decide ready on the presented request once the bench's
            # falling-edge writes (i_stop) have settled.
            await Timer(1, unit="ps")
            if int(dut.o_dma_req_valid.value) == 1:
                addr = int(dut.o_dma_req_addr.value)
                if addr // LINE in self.locked or self.cycle % self.ready_every:
                    dut.i_dma_req_ready.value = 0
                    continue
                dut.i_dma_req_ready.value = 1
                req = {
                    "id": int(dut.o_dma_req_id.value),
                    "write": int(dut.o_dma_req_write.value),
                    "addr": addr,
                    "wstrb": int(dut.o_dma_req_wstrb.value),
                    "cycle": self.cycle,
                }
                self.accepted.append(req)
                self._pending.append([self.rng.randint(*self.latency), req["id"], addr])
            else:
                dut.i_dma_req_ready.value = 0
            # ready was set for this cycle's request; it fires at the next rising edge.
            # (The request register is stable until the fire.)

    def stop(self) -> None:
        self._task.cancel()


class _ReqBus:
    """Shadow of the packed per-side request inputs.

    Both engines write their own side here and push the whole vectors, so
    concurrent drivers never read a stale packed value back from the simulator.
    """

    def __init__(self, dut: Any) -> None:
        self.dut = dut
        self.valid = [0, 0]
        self.write = [0, 0]
        self.addr = [0, 0]
        self.kind = [0, 0]
        self.tag = [0, 0]

    def push(self) -> None:
        d = self.dut
        d.i_req_valid.value = self.valid[0] | (self.valid[1] << 1)
        d.i_req_write.value = self.write[0] | (self.write[1] << 1)
        d.i_req_addr.value = self.addr[0] | (self.addr[1] << 32)
        d.i_req_kind.value = self.kind[0] | (self.kind[1] << 2)
        d.i_req_tag.value = self.tag[0] | (self.tag[1] << 4)


class _Engine:
    """Drives one engine port and collects its responses."""

    def __init__(self, dut: Any, side: int, bus: _ReqBus) -> None:
        self.dut = dut
        self.side = side
        self.bus = bus
        self.responses: list[dict[str, int]] = []
        self._task = cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if int(dut.o_resp_valid.value) >> self.side & 1:
                self.responses.append(
                    {
                        "kind": (int(dut.o_resp_kind.value) >> (2 * self.side)) & 3,
                        "tag": (int(dut.o_resp_tag.value) >> (4 * self.side)) & 0xF,
                        "error": (int(dut.o_resp_error.value) >> self.side) & 1,
                        "rdata": int(dut.o_resp_rdata.value),
                    }
                )

    async def request(
        self, addr: int, kind: int, tag: int, write: bool = False, limit: int = 4000
    ) -> int:
        """Present one request until accepted; return the cycles it waited."""
        dut = self.dut
        s = self.side
        bus = self.bus
        for n in range(limit):
            await FallingEdge(dut.i_clk)
            bus.valid[s] = 1
            bus.write[s] = 1 if write else 0
            bus.addr[s] = addr
            bus.kind[s] = kind
            bus.tag[s] = tag
            bus.push()
            await Timer(2, unit="ps")
            if (int(dut.o_req_ready.value) >> s) & 1:
                await RisingEdge(dut.i_clk)
                await Timer(1, unit="ps")
                bus.valid[s] = 0
                bus.push()
                return n
        raise AssertionError(f"side {s}: request never accepted")

    def stop(self) -> None:
        self._task.cancel()


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_stop,
        dut.i_req_valid,
        dut.i_req_write,
        dut.i_req_addr,
        dut.i_req_wdata,
        dut.i_req_wstrb,
        dut.i_req_kind,
        dut.i_req_tag,
        dut.i_dma_req_ready,
        dut.i_dma_resp_valid,
        dut.i_dma_resp_id,
        dut.i_dma_resp_rdata,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _idle(dut: Any, limit: int = 2000) -> None:
    for _ in range(limit):
        await FallingEdge(dut.i_clk)
        if int(dut.o_idle.value) == 1:
            return
    raise AssertionError("front-end never idle")


@cocotb.test()
async def test_steering_and_data(dut: Any) -> None:
    """Mixed RX/TX reads and writes: every response to its owner with kind, tag and data."""
    await _setup(dut)
    port = _PortModel(dut, seed=1)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    rng = random.Random(2)
    plan = []
    for i in range(60):
        side = rng.randrange(2)
        addr = BASE + 0x100 * i
        kind = rng.randrange(4)
        tag = rng.randrange(16)
        plan.append((side, addr, kind, tag))

    async def drive(engine: _Engine, items: list[tuple[int, int, int]]) -> None:
        for addr, kind, tag in items:
            await engine.request(addr, kind, tag, write=(kind == 0))

    a = cocotb.start_soon(drive(rx, [(p[1], p[2], p[3]) for p in plan if p[0] == 0]))
    b = cocotb.start_soon(drive(tx, [(p[1], p[2], p[3]) for p in plan if p[0] == 1]))
    await a
    await b
    await _idle(dut)
    for side, engine in ((0, rx), (1, tx)):
        expected = [(p[2], p[3], _rdata(p[1])) for p in plan if p[0] == side]
        got = [(r["kind"], r["tag"], r["rdata"]) for r in engine.responses]
        assert sorted(got) == sorted(expected), f"side {side}: responses differ"
        assert all(r["error"] == 0 for r in engine.responses)
    assert len(port.accepted) == 60
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_side_cap_leaves_an_entry(dut: Any) -> None:
    """With responses withheld, RX holds three entries and TX still gets the fourth."""
    await _setup(dut)
    port = _PortModel(dut, seed=3)
    port.hold = True
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    for i in range(3):
        await rx.request(BASE + 0x40 * i, 0, i, write=True)
    await FallingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert (int(dut.o_req_ready.value) & 1) == 0, "RX accepted beyond its cap"
    n = await tx.request(BASE + 0x1000, 3, 7)
    assert n < 10, "TX could not get the remaining entry"
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    assert len(port.accepted) == 4
    port.hold = False
    await _idle(dut)
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_tx_served_within_bound_under_rx_stream(dut: Any) -> None:
    """TX fires within STARVATION_LIMIT RX grants against a port ready every other cycle.

    Such a port locks onto the RX stream (RX has priority whenever both are
    presented, and each side presents every other cycle), so only the grant
    bound serves TX.
    """
    await _setup(dut)
    port = _PortModel(dut, latency=(1, 3), reorder=False, seed=4, ready_every=2)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    stop = [False]

    async def rx_stream() -> None:
        i = 0
        while not stop[0]:
            await rx.request(BASE + 0x40 * (i % 64), 0, i % 16, write=True)
            i += 1

    task = cocotb.start_soon(rx_stream())
    for _ in range(80):
        await FallingEdge(dut.i_clk)
    limit = int(dut.STARVATION_LIMIT.value)
    before = len(port.accepted)
    await tx.request(BASE + 0x8000, 3, 5)
    for _ in range(40 * limit):
        await FallingEdge(dut.i_clk)
        if any(r["addr"] == BASE + 0x8000 for r in port.accepted):
            break
    else:
        raise AssertionError("TX starved behind the RX stream")
    fired_at = next(
        i for i, r in enumerate(port.accepted) if r["addr"] == BASE + 0x8000
    )
    rx_grants = fired_at - before
    assert rx_grants <= limit + 2, f"TX fired behind {rx_grants} RX grants"
    stop[0] = True
    await task
    await _idle(dut)
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_refused_rx_does_not_block_tx(dut: Any) -> None:
    """RX presenting a locked line: TX's request to another line goes through."""
    await _setup(dut)
    port = _PortModel(dut, seed=5)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    locked = BASE + 0x2000
    port.locked.add(locked // LINE)
    rx_task = cocotb.start_soon(rx.request(locked, 0, 1, write=True, limit=400))
    for _ in range(6):
        await FallingEdge(dut.i_clk)
    await tx.request(BASE + 0x3000, 3, 2, limit=40)
    for _ in range(6):
        await FallingEdge(dut.i_clk)
    assert (
        len([r for r in port.accepted if r["addr"] == BASE + 0x3000]) == 1
    ), "TX not served past the refused RX"
    port.locked.clear()
    await rx_task
    await _idle(dut)
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_refused_tx_under_saturated_priority_does_not_block_rx(dut: Any) -> None:
    """TX's priority saturates against a stream of RX grants while its own line.

    is locked; every refused TX presentation must hand the next turn to RX.
    """
    await _setup(dut)
    port = _PortModel(dut, latency=(1, 3), reorder=False, seed=8)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    locked = BASE + 0x9000
    port.locked.add(locked // LINE)
    tx_task = cocotb.start_soon(tx.request(locked, 3, 1, limit=4000))
    stop = [False]

    async def rx_stream() -> None:
        i = 0
        while not stop[0]:
            await rx.request(BASE + 0x40 * (i % 64), 0, i % 16, write=True)
            i += 1

    task = cocotb.start_soon(rx_stream())
    limit = int(dut.STARVATION_LIMIT.value)
    # Let TX's grant count saturate, then watch RX keep flowing.
    for _ in range(4 * limit + 20):
        await FallingEdge(dut.i_clk)
    before = len(port.accepted)
    for _ in range(100):
        await FallingEdge(dut.i_clk)
    rx_grants = len(port.accepted) - before
    assert (
        rx_grants >= 20
    ), f"RX blocked behind a refused TX request: {rx_grants} grants in 100 cycles"
    port.locked.clear()
    await tx_task
    stop[0] = True
    await task
    await _idle(dut)
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_aperture_refusal_is_local(dut: Any) -> None:
    """An address outside cached DDR yields an error response and no port request."""
    await _setup(dut)
    port = _PortModel(dut, seed=6)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    await rx.request(0x0001_0000, 2, 9)
    await tx.request(0xC000_0000, 3, 4)
    await rx.request(BASE + 0x100, 2, 1)
    await _idle(dut)
    assert len(port.accepted) == 1
    err = [r for r in rx.responses if r["error"]]
    assert len(err) == 1 and err[0]["kind"] == 2 and err[0]["tag"] == 9
    err_tx = [r for r in tx.responses if r["error"]]
    assert len(err_tx) == 1 and err_tx[0]["kind"] == 3 and err_tx[0]["tag"] == 4
    ok = [r for r in rx.responses if not r["error"]]
    assert len(ok) == 1 and ok[0]["rdata"] == _rdata(BASE + 0x100)
    port.stop()
    rx.stop()
    tx.stop()


@cocotb.test()
async def test_stop_withdraws_and_drains(dut: Any) -> None:
    """i_stop withdraws registered requests (answered with an error) and idle follows the fired ones' responses."""
    await _setup(dut)
    port = _PortModel(dut, latency=(20, 30), seed=7)
    bus = _ReqBus(dut)
    rx, tx = _Engine(dut, 0, bus), _Engine(dut, 1, bus)
    await rx.request(BASE + 0x100, 0, 1, write=True)
    await tx.request(BASE + 0x200, 3, 2)
    # Lock the next line so the third request sits registered, unfired.
    port.locked.add((BASE + 0x300) // LINE)
    reg = cocotb.start_soon(rx.request(BASE + 0x300, 0, 3, write=True, limit=400))
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    accepted_before = len(port.accepted)
    dut.i_stop.value = 1
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_dma_req_valid.value) == 0, "a request presented under stop"
    port.locked.clear()
    await _idle(dut)
    assert len(port.accepted) == accepted_before, "a withdrawn request fired"
    # The withdrawn request is answered with an error, the fired ones normally.
    assert len(tx.responses) == 1 and tx.responses[0]["error"] == 0
    assert sorted((r["tag"], r["error"]) for r in rx.responses) == [(1, 0), (3, 1)]
    dut.i_stop.value = 0
    reg.cancel()
    port.stop()
    rx.stop()
    tx.stop()
