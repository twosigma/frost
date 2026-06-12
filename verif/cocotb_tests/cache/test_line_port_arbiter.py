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

"""Unit tests for the 2:1 line-port arbiter (line_port_arbiter_test_harness).

The harness drains the arbiter into the same backside the cache hierarchy
sits on (line_port_axi_bridge -> axi_behavioral_memory); the bench plays the
two upstream L1s itself so contention windows are driven cycle-precisely.
Port 0 has fixed priority (FROST's D-side L1); port 1 is the I-side. Checked:
per-port data integrity, response-pulse isolation and one-pulse-per-
transaction, priority on simultaneous requests, and the single-outstanding
lock (an in-flight transaction is never preempted).
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

# Disjoint per-test, per-port regions: the behavioral memory (1 MiB) persists
# across the in-run resets between cocotb tests, so a fresh zero-default
# reference model is only valid in untouched address space.
SMOKE_BASE = (BASE_ADDR + 0x00000, BASE_ADDR + 0x10000)
SIMUL_BASE = (BASE_ADDR + 0x20000, BASE_ADDR + 0x30000)
LOCK_BASE = (BASE_ADDR + 0x40000, BASE_ADDR + 0x50000)
RANDOM_BASE = (BASE_ADDR + 0x60000, BASE_ADDR + 0x80000)

# Random-test window per port: 1024 lines = 32 KiB.
WINDOW_LINES = 1024

RESP_TIMEOUT_CYCLES = 2_000


def _clear_port_inputs(dut: Any, port: int) -> None:
    getattr(dut, f"i_up{port}_req_valid").value = 0
    getattr(dut, f"i_up{port}_req_write").value = 0
    getattr(dut, f"i_up{port}_req_addr").value = 0
    getattr(dut, f"i_up{port}_req_wdata").value = 0
    getattr(dut, f"i_up{port}_req_wstrb").value = 0


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


async def _line_transaction(
    dut: Any, port: int, *, write: bool, addr: int, wdata: int = 0, wstrb: int = 0
) -> int:
    """Run one line transaction on one upstream port; returns the read data.

    Inputs are driven at falling edges (the cache-bench discipline). Ready is
    sampled in the ReadOnly phase of the same timestep: port 1's ready is
    combinational on port 0's valid, which another coroutine may drive at the
    very same falling edge, so the sample must come after all deltas settle --
    that settled value is exactly what the next rising edge fires on.
    """
    req_valid = getattr(dut, f"i_up{port}_req_valid")
    req_ready = getattr(dut, f"o_up{port}_req_ready")
    resp_valid = getattr(dut, f"o_up{port}_resp_valid")
    resp_rdata = getattr(dut, f"o_up{port}_resp_rdata")

    await FallingEdge(dut.i_clk)
    req_valid.value = 1
    getattr(dut, f"i_up{port}_req_write").value = 1 if write else 0
    getattr(dut, f"i_up{port}_req_addr").value = addr
    getattr(dut, f"i_up{port}_req_wdata").value = wdata
    getattr(dut, f"i_up{port}_req_wstrb").value = wstrb

    # Hold valid until a cycle whose settled ready is high: that edge fires.
    for _ in range(RESP_TIMEOUT_CYCLES):
        await ReadOnly()
        if int(req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"port {port}: request never accepted (addr=0x{addr:08x})")

    await FallingEdge(dut.i_clk)  # now in the cycle after the fire
    req_valid.value = 0

    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(resp_valid.value) == 1:
            return int(resp_rdata.value)
        await FallingEdge(dut.i_clk)
    raise AssertionError(f"port {port}: no response (addr=0x{addr:08x}, write={write})")


async def _count_resp_pulses(dut: Any, port: int, counter: list[int]) -> None:
    """Background monitor: count response pulses seen by one port."""
    resp_valid = getattr(dut, f"o_up{port}_resp_valid")
    while True:
        await FallingEdge(dut.i_clk)
        if int(resp_valid.value) == 1:
            counter[0] += 1


def _line_int(data: bytes) -> int:
    return int.from_bytes(data, "little")


async def _check_read(dut: Any, port: int, model: ReferenceModel, addr: int) -> None:
    got = await _line_transaction(dut, port, write=False, addr=addr)
    expected = model.read_line(addr)
    assert got == expected, (
        f"port {port} read mismatch @0x{addr:08x}: "
        f"got 0x{got:064x} expected 0x{expected:064x}"
    )


@cocotb.test()
async def test_each_port_smoke(dut: Any) -> None:
    """Write+read back on each port alone; the idle port sees no pulses."""
    await _setup(dut)
    counters = ([0], [0])
    monitors = [
        cocotb.start_soon(_count_resp_pulses(dut, port, counters[port]))
        for port in (0, 1)
    ]

    for port in (0, 1):
        model = ReferenceModel()
        addr = SMOKE_BASE[port] + 2 * LINE_BYTES
        wdata = _line_int(bytes((port * 64 + b) & 0xFF for b in range(32)))
        model.write_line(addr, wdata, FULL_STRB)
        await _line_transaction(
            dut, port, write=True, addr=addr, wdata=wdata, wstrb=FULL_STRB
        )
        await _check_read(dut, port, model, addr)

    for monitor in monitors:
        monitor.cancel()
    # Two transactions per port, one response pulse each, none cross-routed.
    assert counters[0][0] == 2, f"port 0 saw {counters[0][0]} pulses, expected 2"
    assert counters[1][0] == 2, f"port 1 saw {counters[1][0]} pulses, expected 2"


@cocotb.test()
async def test_priority_simultaneous(dut: Any) -> None:
    """Both ports request in the same cycle: port 0 completes first."""
    await _setup(dut)
    completion_order: list[int] = []
    models = (ReferenceModel(), ReferenceModel())

    async def _one_port(port: int) -> None:
        addr = SIMUL_BASE[port] + 7 * LINE_BYTES
        wdata = _line_int(bytes((0x11 * (port + 1) + b) & 0xFF for b in range(32)))
        models[port].write_line(addr, wdata, FULL_STRB)
        await _line_transaction(
            dut, port, write=True, addr=addr, wdata=wdata, wstrb=FULL_STRB
        )
        completion_order.append(port)

    # Both coroutines block on the same falling edge, so both valids assert
    # in the same cycle; the arbiter must serve port 0 first.
    tasks = [cocotb.start_soon(_one_port(port)) for port in (0, 1)]
    for task in tasks:
        await task
    assert completion_order == [0, 1], f"completion order {completion_order}"

    for port in (0, 1):
        await _check_read(dut, port, models[port], SIMUL_BASE[port] + 7 * LINE_BYTES)


@cocotb.test()
async def test_in_flight_lock(dut: Any) -> None:
    """Port 0 arriving mid-transaction must wait for port 1's response."""
    await _setup(dut)
    completion_order: list[int] = []
    models = (ReferenceModel(), ReferenceModel())

    async def _one_port(port: int) -> None:
        addr = LOCK_BASE[port] + 3 * LINE_BYTES
        wdata = _line_int(bytes((0x33 * (port + 1) + b) & 0xFF for b in range(32)))
        models[port].write_line(addr, wdata, FULL_STRB)
        await _line_transaction(
            dut, port, write=True, addr=addr, wdata=wdata, wstrb=FULL_STRB
        )
        completion_order.append(port)

    # Port 1 fires first (port 0 idle, downstream ready, so the fire happens
    # on the first edge); two cycles later port 0 shows up and must be held
    # out for the whole MEM_LATENCY flight despite its priority.
    task1 = cocotb.start_soon(_one_port(1))
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    task0 = cocotb.start_soon(_one_port(0))
    await task1
    await task0
    assert completion_order == [1, 0], f"completion order {completion_order}"

    for port in (0, 1):
        await _check_read(dut, port, models[port], LOCK_BASE[port] + 3 * LINE_BYTES)


@cocotb.test()
async def test_random_interleaved_traffic(dut: Any) -> None:
    """Two masters hammer the arbiter concurrently with random traffic.

    Each port works a disjoint window against its own reference model
    (cross-routed data or responses surface as mismatches/timeouts), with
    exactly one response pulse per transaction enforced by the monitors.
    """
    await _setup(dut)
    rng = random.Random(random.getrandbits(32))
    counters = ([0], [0])
    monitors = [
        cocotb.start_soon(_count_resp_pulses(dut, port, counters[port]))
        for port in (0, 1)
    ]
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
                    dut, port, write=True, addr=addr, wdata=wdata, wstrb=wstrb
                )
            else:
                await _check_read(dut, port, models[port], addr)
            for _ in range(local_rng.randrange(4)):
                await FallingEdge(dut.i_clk)

    tasks = [cocotb.start_soon(_master(port)) for port in (0, 1)]
    for task in tasks:
        await task

    # Final sweep: everything each model knows about must read back exactly.
    for port in (0, 1):
        for line in range(0, WINDOW_LINES, 13):
            await _check_read(
                dut, port, models[port], RANDOM_BASE[port] + line * LINE_BYTES
            )

    for monitor in monitors:
        monitor.cancel()
    expected = transactions_per_port + len(range(0, WINDOW_LINES, 13))
    for port in (0, 1):
        assert counters[port][0] == expected, (
            f"port {port} saw {counters[port][0]} response pulses, "
            f"expected {expected}"
        )
