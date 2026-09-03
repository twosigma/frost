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

"""Unit tests for the tagged N:1 line-port arbiter (line_port_arbiter_test_harness).

The harness drains the arbiter into the same backside the cache hierarchy
sits on (line_port_axi_bridge -> axi_behavioral_memory); the bench plays the
two upstream L1s itself so contention windows are driven cycle-precisely.
Port 0 has fixed priority (FROST's D-side L1); port 1 is the I-side. Checked:
per-port data integrity and id echo, response isolation (one pulse per
transaction, never cross-routed), priority on simultaneous requests, the
absence of a grant lock (a later port-0 request fires while port 1's
transaction is still in flight), several tagged transactions in flight per
port with responses collected by id in whatever order the memory completes
them, and random mixed traffic on both ports.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from cocotb_tests.cache.test_frost_cache import ReferenceModel

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
BASE_ADDR = 0x8000_0000
FULL_STRB = (1 << LINE_BYTES) - 1
UP_ID_BITS = 3
NUM_IDS = 1 << UP_ID_BITS
MEM_LATENCY_CYCLES = 12  # harness default

# Disjoint per-test, per-port regions: the behavioral memory (1 MiB) persists
# across the in-run resets between cocotb tests, so a fresh zero-default
# reference model is only valid in untouched address space.
SMOKE_BASE = (BASE_ADDR + 0x00000, BASE_ADDR + 0x10000)
SIMUL_BASE = (BASE_ADDR + 0x20000, BASE_ADDR + 0x30000)
NOLOCK_BASE = (BASE_ADDR + 0x40000, BASE_ADDR + 0x50000)
RANDOM_BASE = (BASE_ADDR + 0x60000, BASE_ADDR + 0x80000)
BURST_BASE = (BASE_ADDR + 0xA0000, BASE_ADDR + 0xB0000)
RANDOM_OUT_BASE = (BASE_ADDR + 0xC0000, BASE_ADDR + 0xE0000)

# Random-test window per port: 1024 lines = 32 KiB.
WINDOW_LINES = 1024

RESP_TIMEOUT_CYCLES = 2_000


def _clear_port_inputs(dut: Any, port: int) -> None:
    getattr(dut, f"i_up{port}_req_valid").value = 0
    getattr(dut, f"i_up{port}_req_write").value = 0
    getattr(dut, f"i_up{port}_req_addr").value = 0
    getattr(dut, f"i_up{port}_req_wdata").value = 0
    getattr(dut, f"i_up{port}_req_wstrb").value = 0
    getattr(dut, f"i_up{port}_req_id").value = 0


async def _setup(dut: Any) -> None:
    """Start the clock and reset (nothing below the arbiter sweeps)."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_port_inputs(dut, 0)
    _clear_port_inputs(dut, 1)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


class _PortIds:
    """Per-port id allocator: ids cycle so consecutive requests never share one."""

    def __init__(self) -> None:
        self._next = [0, 0]

    def take(self, port: int) -> int:
        value = self._next[port]
        self._next[port] = (value + 1) % NUM_IDS
        return value


_ids = _PortIds()


async def _fire_request(
    dut: Any,
    port: int,
    *,
    write: bool,
    addr: int,
    req_id: int,
    wdata: int = 0,
    wstrb: int = 0,
) -> None:
    """Present one request on a port and return once it has fired.

    Inputs are driven at falling edges (the cache-bench discipline). Ready is
    sampled in the ReadOnly phase of the same timestep: port 1's ready is
    combinational on port 0's valid, which another coroutine may drive at the
    very same falling edge, so the sample must come after all deltas settle.
    That settled value is exactly what the next rising edge fires on. On
    return the bus is in the cycle after the fire with valid dropped.
    """
    req_valid = getattr(dut, f"i_up{port}_req_valid")
    req_ready = getattr(dut, f"o_up{port}_req_ready")

    await FallingEdge(dut.i_clk)
    req_valid.value = 1
    getattr(dut, f"i_up{port}_req_write").value = 1 if write else 0
    getattr(dut, f"i_up{port}_req_addr").value = addr
    getattr(dut, f"i_up{port}_req_wdata").value = wdata
    getattr(dut, f"i_up{port}_req_wstrb").value = wstrb
    getattr(dut, f"i_up{port}_req_id").value = req_id

    for _ in range(RESP_TIMEOUT_CYCLES):
        await ReadOnly()
        if int(req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"port {port}: request never accepted (addr=0x{addr:08x})")

    await FallingEdge(dut.i_clk)  # now in the cycle after the fire
    req_valid.value = 0


class _ResponseCollector:
    """Background monitor: gathers every response on a port keyed by id.

    Also counts pulses so a test can prove one response per transaction and
    no cross-routing. Responses are one-cycle pulses; rdata is sampled in the
    same cycle.
    """

    def __init__(self, dut: Any, port: int) -> None:
        self._dut = dut
        self._port = port
        self.pulses = 0
        self.pending: dict[int, list[int]] = {}
        self.order: list[int] = []
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        resp_valid = getattr(self._dut, f"o_up{self._port}_resp_valid")
        resp_id = getattr(self._dut, f"o_up{self._port}_resp_id")
        resp_rdata = getattr(self._dut, f"o_up{self._port}_resp_rdata")
        while True:
            await FallingEdge(self._dut.i_clk)
            if int(resp_valid.value) == 1:
                self.pulses += 1
                rid = int(resp_id.value)
                self.pending.setdefault(rid, []).append(int(resp_rdata.value))
                self.order.append(rid)

    async def wait_for(self, req_id: int) -> int:
        """Block until a response with req_id has been collected; return its data."""
        for _ in range(RESP_TIMEOUT_CYCLES):
            if self.pending.get(req_id):
                return self.pending[req_id].pop(0)
            await FallingEdge(self._dut.i_clk)
        raise AssertionError(f"port {self._port}: no response for id {req_id}")

    def stop(self) -> None:
        self._task.cancel()


async def _line_transaction(
    dut: Any,
    port: int,
    collector: _ResponseCollector,
    *,
    write: bool,
    addr: int,
    wdata: int = 0,
    wstrb: int = 0,
) -> int:
    """Run one tagged line transaction to completion; returns the read data."""
    req_id = _ids.take(port)
    await _fire_request(
        dut, port, write=write, addr=addr, req_id=req_id, wdata=wdata, wstrb=wstrb
    )
    return await collector.wait_for(req_id)


def _line_int(data: bytes) -> int:
    return int.from_bytes(data, "little")


async def _check_read(
    dut: Any, port: int, collector: _ResponseCollector, model: ReferenceModel, addr: int
) -> None:
    got = await _line_transaction(dut, port, collector, write=False, addr=addr)
    expected = model.read_line(addr)
    assert got == expected, (
        f"port {port} read mismatch @0x{addr:08x}: "
        f"got 0x{got:064x} expected 0x{expected:064x}"
    )


@cocotb.test()
async def test_each_port_smoke(dut: Any) -> None:
    """Write+read back on each port alone; the idle port sees no pulses."""
    await _setup(dut)
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]

    for port in (0, 1):
        model = ReferenceModel()
        addr = SMOKE_BASE[port] + 2 * LINE_BYTES
        wdata = _line_int(bytes((port * 64 + b) & 0xFF for b in range(32)))
        model.write_line(addr, wdata, FULL_STRB)
        await _line_transaction(
            dut,
            port,
            collectors[port],
            write=True,
            addr=addr,
            wdata=wdata,
            wstrb=FULL_STRB,
        )
        await _check_read(dut, port, collectors[port], model, addr)

    for collector in collectors:
        collector.stop()
    # Two transactions per port, one response pulse each, none cross-routed.
    assert (
        collectors[0].pulses == 2
    ), f"port 0 saw {collectors[0].pulses} pulses, expected 2"
    assert (
        collectors[1].pulses == 2
    ), f"port 1 saw {collectors[1].pulses} pulses, expected 2"


@cocotb.test()
async def test_priority_simultaneous(dut: Any) -> None:
    """Both ports request in the same cycle: port 0 fires first."""
    await _setup(dut)
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]
    fire_order: list[int] = []
    models = (ReferenceModel(), ReferenceModel())

    async def _one_port(port: int) -> None:
        addr = SIMUL_BASE[port] + 7 * LINE_BYTES
        wdata = _line_int(bytes((0x11 * (port + 1) + b) & 0xFF for b in range(32)))
        models[port].write_line(addr, wdata, FULL_STRB)
        req_id = _ids.take(port)
        await _fire_request(
            dut,
            port,
            write=True,
            addr=addr,
            req_id=req_id,
            wdata=wdata,
            wstrb=FULL_STRB,
        )
        fire_order.append(port)
        await collectors[port].wait_for(req_id)

    # Both coroutines block on the same falling edge, so both valids assert
    # in the same cycle; the arbiter must fire port 0 first. Completion
    # order is the memory model's business: with MEM_REORDER it may differ.
    tasks = [cocotb.start_soon(_one_port(port)) for port in (0, 1)]
    for task in tasks:
        await task
    assert fire_order == [0, 1], f"fire order {fire_order}"

    for port in (0, 1):
        await _check_read(
            dut, port, collectors[port], models[port], SIMUL_BASE[port] + 7 * LINE_BYTES
        )
    for collector in collectors:
        collector.stop()


@cocotb.test()
async def test_no_grant_lock(dut: Any) -> None:
    """Port 0 arriving mid-flight fires at once instead of waiting for port 1's response."""
    await _setup(dut)
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]
    models = (ReferenceModel(), ReferenceModel())
    cycle = [0]

    async def _count_cycles() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            cycle[0] += 1

    counter = cocotb.start_soon(_count_cycles())
    fired_at: dict[int, int] = {}

    async def _one_port(port: int) -> None:
        addr = NOLOCK_BASE[port] + 3 * LINE_BYTES
        req_id = _ids.take(port)
        await _fire_request(dut, port, write=False, addr=addr, req_id=req_id)
        fired_at[port] = cycle[0]
        got = await collectors[port].wait_for(req_id)
        assert got == models[port].read_line(addr)

    # Port 1 fires first (port 0 idle, downstream ready); two cycles later
    # port 0 shows up. Without a grant lock it fires within a couple of
    # cycles, long before port 1's memory round trip completes.
    task1 = cocotb.start_soon(_one_port(1))
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    task0 = cocotb.start_soon(_one_port(0))
    await task1
    await task0
    counter.cancel()
    gap = fired_at[0] - fired_at[1]
    assert (
        0 < gap < MEM_LATENCY_CYCLES
    ), f"port 0 fired {gap} cycles after port 1 (lock?)"
    for collector in collectors:
        collector.stop()


@cocotb.test()
async def test_multiple_outstanding_per_port(dut: Any) -> None:
    """One port keeps several tagged reads in flight; responses are matched by id."""
    await _setup(dut)
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]
    model = ReferenceModel()
    lines = [1, 5, 9, 13, 17, 21]
    for line in lines:
        addr = BURST_BASE[0] + line * LINE_BYTES
        wdata = _line_int(bytes((line * 7 + b) & 0xFF for b in range(32)))
        model.write_line(addr, wdata, FULL_STRB)
        await _line_transaction(
            dut, 0, collectors[0], write=True, addr=addr, wdata=wdata, wstrb=FULL_STRB
        )

    # Fire every read back to back, then collect by id in any order.
    ids = []
    for line in lines:
        req_id = _ids.take(0)
        ids.append((req_id, line))
        await _fire_request(
            dut, 0, write=False, addr=BURST_BASE[0] + line * LINE_BYTES, req_id=req_id
        )
    for req_id, line in ids:
        got = await collectors[0].wait_for(req_id)
        expected = model.read_line(BURST_BASE[0] + line * LINE_BYTES)
        assert (
            got == expected
        ), f"id {req_id} line {line}: got 0x{got:064x} expected 0x{expected:064x}"

    dut._log.info(f"burst completion order by id: {collectors[0].order[-len(lines):]}")
    assert collectors[1].pulses == 0, "port 1 saw a cross-routed response"
    for collector in collectors:
        collector.stop()


@cocotb.test()
async def test_random_interleaved_traffic(dut: Any) -> None:
    """Two masters hammer the arbiter concurrently with random traffic.

    Each port works a disjoint window against its own reference model
    (cross-routed data or responses surface as mismatches/timeouts), with
    exactly one response pulse per transaction enforced by the collectors.
    """
    await _setup(dut)
    rng = random.Random(random.getrandbits(32))
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]
    transactions_per_port = 200
    models = (ReferenceModel(), ReferenceModel())

    async def _master(port: int) -> None:
        # Port-local RNG so the two coroutines don't share draw order.
        local_rng = random.Random(rng.getrandbits(32))
        for _ in range(transactions_per_port):
            line = local_rng.randrange(WINDOW_LINES)
            addr = RANDOM_BASE[port] + line * LINE_BYTES
            if local_rng.random() < 0.5:
                wdata = local_rng.getrandbits(256)
                style = local_rng.random()
                if style < 0.5:
                    wstrb = FULL_STRB
                elif style < 0.8:
                    wstrb = 0xF << (4 * local_rng.randrange(8))
                else:
                    wstrb = local_rng.getrandbits(32) or 1
                models[port].write_line(addr, wdata, wstrb)
                await _line_transaction(
                    dut,
                    port,
                    collectors[port],
                    write=True,
                    addr=addr,
                    wdata=wdata,
                    wstrb=wstrb,
                )
            else:
                await _check_read(dut, port, collectors[port], models[port], addr)
            for _ in range(local_rng.randrange(4)):
                await FallingEdge(dut.i_clk)

    tasks = [cocotb.start_soon(_master(port)) for port in (0, 1)]
    for task in tasks:
        await task

    # Final sweep: everything each model knows about must read back exactly.
    for port in (0, 1):
        for line in range(0, WINDOW_LINES, 13):
            await _check_read(
                dut,
                port,
                collectors[port],
                models[port],
                RANDOM_BASE[port] + line * LINE_BYTES,
            )

    expected = transactions_per_port + len(range(0, WINDOW_LINES, 13))
    for port in (0, 1):
        assert (
            collectors[port].pulses == expected
        ), f"port {port} saw {collectors[port].pulses} response pulses, expected {expected}"
    for collector in collectors:
        collector.stop()


@cocotb.test()
async def test_random_outstanding_traffic(dut: Any) -> None:
    """Both ports keep bursts of tagged transactions in flight concurrently.

    Every burst touches distinct lines (a master never has two transactions
    to one line in flight), mixes reads and writes, and collects responses
    by id in memory-completion order; every read is checked against the
    port's reference model.
    """
    await _setup(dut)
    rng = random.Random(random.getrandbits(32))
    collectors = [_ResponseCollector(dut, port) for port in (0, 1)]
    models = (ReferenceModel(), ReferenceModel())
    bursts_per_port = 60

    async def _master(port: int) -> None:
        local_rng = random.Random(rng.getrandbits(32))
        for _ in range(bursts_per_port):
            burst = local_rng.randrange(1, NUM_IDS + 1)
            lines = local_rng.sample(range(WINDOW_LINES), burst)
            issued: list[tuple[int, int | None]] = []
            for line in lines:
                addr = RANDOM_OUT_BASE[port] + line * LINE_BYTES
                req_id = _ids.take(port)
                if local_rng.random() < 0.4:
                    wdata = local_rng.getrandbits(256)
                    wstrb = (
                        FULL_STRB
                        if local_rng.random() < 0.6
                        else (local_rng.getrandbits(32) or 1)
                    )
                    models[port].write_line(addr, wdata, wstrb)
                    await _fire_request(
                        dut,
                        port,
                        write=True,
                        addr=addr,
                        req_id=req_id,
                        wdata=wdata,
                        wstrb=wstrb,
                    )
                    issued.append((req_id, None))
                else:
                    await _fire_request(
                        dut, port, write=False, addr=addr, req_id=req_id
                    )
                    issued.append((req_id, addr))
            for req_id, read_addr in issued:
                got = await collectors[port].wait_for(req_id)
                if read_addr is not None:
                    expected = models[port].read_line(read_addr)
                    assert got == expected, (
                        f"port {port} id {req_id} @0x{read_addr:08x}: "
                        f"got 0x{got:064x} expected 0x{expected:064x}"
                    )
            for _ in range(local_rng.randrange(3)):
                await FallingEdge(dut.i_clk)

    tasks = [cocotb.start_soon(_master(port)) for port in (0, 1)]
    for task in tasks:
        await task
    for collector in collectors:
        collector.stop()
