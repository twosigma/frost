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

"""Test axi_mux with three masters in front of an AXI4 slave memory.

Each master works in its own pages, so a byte reference per master checks
every read. The slave reorders responses across ids, the masters share id
values, and W data often comes late, so B and R must route by port and W
must follow the AW grants.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.axi.axi_models import (
    FIXED,
    INCR,
    OKAY,
    PAGE_BYTES,
    WRAP,
    AxiMaster,
    AxiSlaveMemory,
    apply_write,
    beat_addresses,
    beat_lanes,
)

PORTS = 3
CLOCK_PERIOD_NS = 10
TIMEOUT_CYCLES = 60_000


class _Bench:
    """Three masters, the mux, and a slave memory."""

    def __init__(self, dut: Any, seed: int, gap_bias: float, ready_bias: float) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.bus = len(dut.o_dn_wdata) // 8
        self.max_size = self.bus.bit_length() - 1
        self.ids = 1 << len(dut.i_up0_awid)
        self.mem: dict[int, int] = {}
        self.slave = AxiSlaveMemory(
            dut,
            dut.i_clk,
            "i_dn_",
            "o_dn_",
            self.bus,
            self.mem,
            self.rng,
            ready_bias=0.7,
        )
        self.masters = [
            AxiMaster(
                dut,
                dut.i_clk,
                f"i_up{p}_",
                f"o_up{p}_",
                self.bus,
                self.rng,
                ready_bias=ready_bias,
                gap_bias=gap_bias,
            )
            for p in range(PORTS)
        ]
        self.refs: list[dict[int, int]] = [{} for _ in range(PORTS)]

    def page(self, port: int, n: int) -> int:
        """Return a page that only `port` uses."""
        return 0x1000_0000 + (port * 16 + n) * PAGE_BYTES

    def random_burst(self, page: int) -> tuple[int, int, int, int]:
        """Return a legal (addr, len, size, burst) inside one page."""
        rng = self.rng
        size = rng.randint(0, self.max_size)
        nbytes = 1 << size
        burst = rng.choice((INCR, INCR, WRAP, FIXED))
        if burst == WRAP:
            return (
                page + rng.randrange(0, PAGE_BYTES, nbytes),
                rng.choice((1, 3, 7, 15)),
                size,
                WRAP,
            )
        if burst == FIXED:
            return (
                page + rng.randrange(0, PAGE_BYTES - nbytes + 1),
                rng.randint(0, 15),
                size,
                FIXED,
            )
        addr = page + rng.randrange(0, PAGE_BYTES)
        start = (addr - page) - (addr - page) % nbytes
        room = (PAGE_BYTES - start) // nbytes
        return addr, rng.randint(0, min(31, room - 1)), size, INCR

    def write(self, port: int, burst: tuple[int, int, int, int]) -> Any:
        """Queue a write on a port; its reference applies it in queue order."""
        addr, length, size, kind = burst
        beats = []
        for beat_addr in beat_addresses(addr, length, size, kind):
            mask = 0
            for lane in beat_lanes(beat_addr, size, self.bus):
                if self.rng.random() < 0.9:
                    mask |= 1 << lane
            beats.append((self.rng.getrandbits(8 * self.bus), mask))
        apply_write(self.refs[port], addr, length, size, kind, beats, self.bus)
        return self.masters[port].write(
            self.rng.randrange(self.ids), addr, length, size, kind, beats
        )

    def read(self, port: int, burst: tuple[int, int, int, int]) -> Any:
        """Queue a read on a port."""
        return self.masters[port].read(self.rng.randrange(self.ids), *burst)

    def check_read(self, port: int, txn: Any) -> None:
        """Compare a read's lanes with its port's reference."""
        assert len(txn.beats) == txn.length + 1
        for (data, resp), beat_addr in zip(
            txn.beats, beat_addresses(txn.addr, txn.length, txn.size, txn.burst)
        ):
            assert resp == OKAY
            word = beat_addr - beat_addr % self.bus
            for lane in beat_lanes(beat_addr, txn.size, self.bus):
                want = self.refs[port].get(word + lane, 0)
                got = (data >> (8 * lane)) & 0xFF
                assert got == want, (
                    f"port {port} byte {word + lane:#x}: got {got:#x} want {want:#x}"
                )

    def check_clean(self) -> None:
        """Fail on any protocol violation the models saw."""
        for port, master in enumerate(self.masters):
            assert not master.violations, (port, master.violations[:5])
        assert not self.slave.violations, self.slave.violations[:5]


async def _start(
    dut: Any, seed: int, gap_bias: float = 0.3, ready_bias: float = 0.8
) -> _Bench:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_rst.value = 1
    bench = _Bench(dut, seed, gap_bias, ready_bias)
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    return bench


async def _wait(dut: Any, txns: list[Any], limit: int = TIMEOUT_CYCLES) -> None:
    for _ in range(limit):
        if all(txn.done.is_set() for txn in txns):
            return
        await RisingEdge(dut.i_clk)
    raise AssertionError(
        f"{sum(not t.done.is_set() for t in txns)} transactions did not complete"
    )


async def _traffic(bench: _Bench, rounds: int, per_port: int) -> None:
    for _ in range(rounds):
        writes = [
            (
                port,
                bench.write(
                    port, bench.random_burst(bench.page(port, bench.rng.randrange(4)))
                ),
            )
            for port in range(PORTS)
            for _ in range(per_port)
        ]
        await _wait(bench.dut, [txn for _, txn in writes])
        assert all(txn.resp == OKAY for _, txn in writes)
        reads = [
            (
                port,
                bench.read(
                    port, bench.random_burst(bench.page(port, bench.rng.randrange(4)))
                ),
            )
            for port in range(PORTS)
            for _ in range(per_port)
        ]
        await _wait(bench.dut, [txn for _, txn in reads])
        for port, txn in reads:
            bench.check_read(port, txn)


@cocotb.test()
async def test_slave_w_before_aw(dut: Any) -> None:
    """The slave completes writes whose data is presented before the address."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_rst.value = 1
    # Connect the models directly through harness inputs, with the mux in
    # reset: its downstream W channel waits for AW before presenting data.
    bus = len(dut.i_up0_wdata) // 8
    mem: dict[int, int] = {}
    ref: dict[int, int] = {}
    slave = AxiSlaveMemory(
        dut,
        dut.i_clk,
        "i_dn_",
        "i_up0_",
        bus,
        mem,
        random.Random(14),
        ready_bias=1.0,
    )
    master = AxiMaster(
        dut,
        dut.i_clk,
        "i_up0_",
        "i_dn_",
        bus,
        random.Random(15),
        ready_bias=1.0,
        gap_bias=0.0,
    )
    for length in (0, 3):
        addr = 0x1000 + length * bus
        size = bus.bit_length() - 1
        beats = [(0x12345678 + n, (1 << bus) - 1) for n in range(length + 1)]
        txn = master.write(length, addr, length, size, INCR, beats)
        delayed_aw = master._aw_queue.popleft()
        await RisingEdge(dut.i_clk)
        await RisingEdge(dut.i_clk)
        assert int(dut.i_up0_wvalid.value)
        assert not int(dut.i_up0_awvalid.value)
        for _ in range(8):
            await RisingEdge(dut.i_clk)
        master._aw_queue.append(delayed_aw)
        await _wait(dut, [txn], limit=100)
        assert txn.resp == OKAY
        apply_write(ref, addr, length, size, INCR, beats, bus)
        assert mem == ref
    assert len(master.completions) == 2
    assert not master.violations, master.violations
    assert not slave.violations, slave.violations


@cocotb.test()
async def test_three_masters(dut: Any) -> None:
    """Concurrent bursts from three ports land and return to the right port."""
    bench = await _start(dut, seed=11)
    await _traffic(bench, rounds=3, per_port=20)
    bench.check_clean()


@cocotb.test()
async def test_late_write_data(dut: Any) -> None:
    """W data that trails its AW never takes the W channel out of AW order."""
    bench = await _start(dut, seed=12, gap_bias=0.8, ready_bias=0.5)
    await _traffic(bench, rounds=2, per_port=15)
    bench.check_clean()


@cocotb.test()
async def test_reset_mid_traffic(dut: Any) -> None:
    """Reset abandons transfers in flight; new traffic afterwards completes."""
    bench = await _start(dut, seed=13)
    for port in range(PORTS):
        for _ in range(10):
            bench.write(port, bench.random_burst(bench.page(port, 0)))
    for _ in range(40):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    for master in bench.masters:
        master._task.cancel()
    bench.slave._task.cancel()
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    fresh = _Bench(dut, 14, 0.3, 0.8)
    await _traffic(fresh, rounds=1, per_port=10)
    fresh.check_clean()
