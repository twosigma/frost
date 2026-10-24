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

"""Test axi_coherent_bridge against a model of cpu_top's coherent ingress.

AxiMaster drives bursts of every type, size, alignment and strobe pattern;
LineIngress applies a write when it accepts it, answers out of order, and
checks the ingress's preconditions on every line request. A byte reference
memory, updated in AW order, checks every lane of every R beat and the
memory the writes leave. Error bursts must send no line request and answer
their code on B or on every R beat.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.axi.axi_models import (
    DECERR,
    FIXED,
    INCR,
    OKAY,
    PAGE_BYTES,
    SLVERR,
    WRAP,
    AxiMaster,
    AxiRead,
    AxiWrite,
    LineIngress,
    apply_write,
    beat_addresses,
    beat_lanes,
    burst_is_legal,
)

REGION_BASE = 0x8000_0000
REGION_BYTES = 0x4000_0000
CLOCK_PERIOD_NS = 10
TIMEOUT_CYCLES = 60_000


class _Bench:
    """The bridge with a master, an ingress model and a reference memory."""

    def __init__(
        self, dut: Any, seed: int, ingress_ready: float, master_ready: float
    ) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.bus = len(dut.i_axi_wdata) // 8
        self.max_size = self.bus.bit_length() - 1
        self.ids = 1 << len(dut.i_axi_awid)
        self.mem: dict[int, int] = {}
        self.ref: dict[int, int] = {}
        self.ingress = LineIngress(
            dut,
            dut.i_clk,
            self.mem,
            (REGION_BASE, REGION_BYTES),
            self.rng,
            ingress_ready,
        )
        self.master = AxiMaster(
            dut, dut.i_clk, "i_axi_", "o_axi_", self.bus, self.rng, master_ready
        )

    def write(
        self,
        addr: int,
        length: int,
        size: int,
        burst: int,
        strobe_bias: float = 0.9,
        wid: int | None = None,
    ) -> AxiWrite:
        """Queue a write of random data; the reference applies it in AW order."""
        rng = self.rng
        beats = []
        for beat_addr in beat_addresses(addr, length, size, burst):
            data = rng.getrandbits(8 * self.bus)
            strb = 0
            for lane in beat_lanes(beat_addr, size, self.bus):
                if rng.random() < strobe_bias:
                    strb |= 1 << lane
            # Strobes outside the beat's lanes must be ignored.
            if rng.random() < 0.2:
                strb |= rng.getrandbits(self.bus)
            beats.append((data, strb & ((1 << self.bus) - 1)))
        clean = [
            (data, strb & _lane_mask(beat_addr, size, self.bus))
            for (data, strb), beat_addr in zip(
                beats, beat_addresses(addr, length, size, burst)
            )
        ]
        if _in_region(addr) and burst_is_legal(addr, length, size, burst, self.bus):
            apply_write(self.ref, addr, length, size, burst, clean, self.bus)
        wid = rng.randrange(self.ids) if wid is None else wid
        return self.master.write(wid, addr, length, size, burst, beats)

    def read(
        self, addr: int, length: int, size: int, burst: int, rid: int | None = None
    ) -> AxiRead:
        """Queue a read burst."""
        rid = self.rng.randrange(self.ids) if rid is None else rid
        return self.master.read(rid, addr, length, size, burst)

    def check_read(self, txn: AxiRead, expect: int = OKAY) -> None:
        """Compare a completed read's lanes with the reference memory."""
        assert len(txn.beats) == txn.length + 1, (
            f"read {txn} returned {len(txn.beats)} beats"
        )
        for (data, resp), beat_addr in zip(
            txn.beats, beat_addresses(txn.addr, txn.length, txn.size, txn.burst)
        ):
            assert resp == expect, f"read at {beat_addr:#x}: resp {resp}, want {expect}"
            if expect != OKAY:
                continue
            word = beat_addr - beat_addr % self.bus
            for lane in beat_lanes(beat_addr, txn.size, self.bus):
                got = (data >> (8 * lane)) & 0xFF
                want = self.ref.get(word + lane, 0)
                assert got == want, (
                    f"read byte {word + lane:#x}: got {got:#04x} want {want:#04x}"
                )

    def random_burst(self, page: int) -> tuple[int, int, int, int]:
        """Return a legal (addr, len, size, burst) inside one page."""
        rng = self.rng
        size = rng.randint(0, self.max_size)
        nbytes = 1 << size
        burst = rng.choice((INCR, INCR, INCR, WRAP, FIXED))
        if burst == WRAP:
            length = rng.choice((1, 3, 7, 15))
            addr = page + rng.randrange(0, PAGE_BYTES, nbytes)
        elif burst == FIXED:
            length = rng.randint(0, 15)
            addr = page + rng.randrange(0, PAGE_BYTES - nbytes + 1)
        else:
            addr = page + rng.randrange(0, PAGE_BYTES)
            start = (addr - page) - (addr - page) % nbytes
            room = (PAGE_BYTES - start) // nbytes
            length = rng.randint(0, min(255, room - 1, rng.choice((3, 15, 63, 255))))
        return addr, length, size, burst

    def check_clean(self) -> None:
        """Fail on any protocol violation either model saw."""
        assert not self.master.violations, self.master.violations[:5]
        assert not self.ingress.violations, self.ingress.violations[:5]

    def check_memory(self) -> None:
        """Check that the ingress's memory equals the reference at every written byte."""
        for addr, want in self.ref.items():
            got = self.mem.get(addr, 0)
            assert got == want, (
                f"memory byte {addr:#x}: got {got:#04x} want {want:#04x}"
            )


def _lane_mask(addr: int, size: int, bus: int) -> int:
    mask = 0
    for lane in beat_lanes(addr, size, bus):
        mask |= 1 << lane
    return mask


def _in_region(addr: int) -> bool:
    return REGION_BASE <= addr < REGION_BASE + REGION_BYTES


async def _start(
    dut: Any, seed: int, ingress_ready: float = 0.7, master_ready: float = 0.8
) -> _Bench:
    """Start the clock and models and release reset."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_rst.value = 1
    bench = _Bench(dut, seed, ingress_ready, master_ready)
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    return bench


async def _wait(dut: Any, txns: list[Any], limit: int = TIMEOUT_CYCLES) -> None:
    """Wait until every transaction has completed."""
    for _ in range(limit):
        if all(txn.done.is_set() for txn in txns):
            return
        await RisingEdge(dut.i_clk)
    pending = [txn for txn in txns if not txn.done.is_set()]
    raise AssertionError(
        f"{len(pending)} transactions did not complete, first {pending[0]}"
    )


@cocotb.test()
async def test_line_transfers(dut: Any) -> None:
    """Whole-bus single-beat bursts, as the NIC and the DMA engine issue them."""
    bench = await _start(dut, seed=1)
    page = REGION_BASE + 0x10000
    size = bench.max_size
    writes = []
    for _ in range(80):
        addr = page + bench.rng.randrange(0, 4 * PAGE_BYTES, bench.bus)
        writes.append(bench.write(addr, 0, size, INCR))
    await _wait(dut, writes)
    assert all(txn.resp == OKAY for txn in writes)
    reads = []
    for line in range(0, 4 * PAGE_BYTES, 128):
        reads.append(bench.read(page + line, 0, size, INCR))
    await _wait(dut, reads)
    for txn in reads:
        bench.check_read(txn)
    bench.check_memory()
    bench.check_clean()


@cocotb.test()
async def test_random_bursts(dut: Any) -> None:
    """INCR, WRAP and FIXED bursts of every size, overlapping, then read back."""
    bench = await _start(dut, seed=2)
    pages = [REGION_BASE + 0x40000 + n * PAGE_BYTES for n in range(3)]
    for round_ in range(3):
        writes = [
            bench.write(*bench.random_burst(bench.rng.choice(pages))) for _ in range(40)
        ]
        await _wait(dut, writes)
        assert all(txn.resp == OKAY for txn in writes), "a legal write was refused"
        reads = [
            bench.read(*bench.random_burst(bench.rng.choice(pages))) for _ in range(40)
        ]
        await _wait(dut, reads)
        for txn in reads:
            bench.check_read(txn)
        dut._log.info(f"round {round_}: {len(bench.ingress.log)} line requests so far")
    bench.check_memory()
    bench.check_clean()


@cocotb.test()
async def test_error_bursts(dut: Any) -> None:
    """Illegal and out-of-region bursts answer their code and send no line request."""
    bench = await _start(dut, seed=3)
    page = REGION_BASE + 0x80000
    bus, top = bench.bus, bench.max_size
    illegal = [
        (page + PAGE_BYTES - bus, 1, top, INCR, SLVERR),  # crosses 4 KiB
        (page + 2, 3, 2, WRAP, SLVERR),  # unaligned WRAP
        (page, 2, 0, WRAP, SLVERR),  # three beats
        (page, 0, 0, 3, SLVERR),  # reserved burst type
        (page, 16, 0, FIXED, SLVERR),  # FIXED over 16 beats
        (REGION_BASE - PAGE_BYTES, 3, top, INCR, DECERR),
        (REGION_BASE + REGION_BYTES, 0, 0, INCR, DECERR),
        ((1 << 40) | page, 0, top, INCR, DECERR),
    ]
    if top < 7:
        illegal.append((page, 0, top + 1, INCR, SLVERR))  # wider than the bus
    writes, reads, codes = [], [], []
    for addr, length, size, burst, code in illegal:
        writes.append(bench.write(addr, length, size, burst))
        reads.append(bench.read(addr, length, size, burst))
        codes.append(code)
    await _wait(dut, writes + reads)
    assert not bench.ingress.log, f"an error burst sent {bench.ingress.log[:3]}"
    for txn, read, code in zip(writes, reads, codes):
        assert txn.resp == code, f"write {txn.addr:#x}: resp {txn.resp}, want {code}"
        bench.check_read(read, expect=code)
        assert all(data == 0 for data, _ in read.beats), "an error beat carried data"
    # Legal traffic still flows afterwards.
    ok = bench.write(page, 0, top, INCR)
    await _wait(dut, [ok])
    assert ok.resp == OKAY
    bench.check_clean()


@cocotb.test()
async def test_ingress_errors(dut: Any) -> None:
    """A failed line answers SLVERR on its B or on exactly its R beats."""
    bench = await _start(dut, seed=4)
    page = REGION_BASE + 0xC0000
    bad = page + 2 * 32
    bench.ingress.error_lines.add(bad)
    top = bench.max_size
    beats = 8 * 32 // bench.bus  # eight lines
    write = bench.write(page, beats - 1, top, INCR, strobe_bias=1.0)
    clean = bench.write(page + PAGE_BYTES, beats - 1, top, INCR, strobe_bias=1.0)
    await _wait(dut, [write, clean])
    assert write.resp == SLVERR and clean.resp == OKAY
    read = bench.read(page, beats - 1, top, INCR)
    await _wait(dut, [read])
    for (_, resp), beat_addr in zip(
        read.beats, beat_addresses(page, beats - 1, top, INCR)
    ):
        want = SLVERR if beat_addr - beat_addr % 32 == bad else OKAY
        assert resp == want, f"beat at {beat_addr:#x}: resp {resp}, want {want}"
    bench.check_clean()


@cocotb.test()
async def test_order_under_backpressure(dut: Any) -> None:
    """B returns in AW order and R in AR order, whatever the ids and stalls."""
    bench = await _start(dut, seed=5, ingress_ready=0.5, master_ready=0.15)
    pages = [REGION_BASE + 0x100000 + n * PAGE_BYTES for n in range(4)]
    writes = [
        bench.write(*bench.random_burst(bench.rng.choice(pages))) for _ in range(30)
    ]
    reads = [
        bench.read(*bench.random_burst(bench.rng.choice(pages))) for _ in range(30)
    ]
    await _wait(dut, writes + reads)
    done_writes = [txn for kind, txn in bench.master.completions if kind == "w"]
    done_reads = [txn for kind, txn in bench.master.completions if kind == "r"]
    assert [id(txn) for txn in done_writes] == [id(txn) for txn in writes], (
        "B did not return in AW order"
    )
    assert [id(txn) for txn in done_reads] == [id(txn) for txn in reads], (
        "R did not return in AR order"
    )
    # Line writes left in AW and beat order.
    write_lines = [entry for entry in bench.ingress.log if entry[1]]
    assert write_lines, "no line writes"
    bench.check_clean()


@cocotb.test()
async def test_reads_progress_under_writes(dut: Any) -> None:
    """A read gets the line port within the starvation bound under a write flood."""
    bench = await _start(dut, seed=6, ingress_ready=0.6, master_ready=1.0)
    page = REGION_BASE + 0x200000
    top = bench.max_size
    flood = [bench.write(page + (n % 64) * bench.bus, 0, top, INCR) for n in range(200)]
    for _ in range(30):
        await RisingEdge(dut.i_clk)
    read = bench.read(page + PAGE_BYTES, 0, top, INCR)
    start = len(bench.ingress.log)
    await _wait(dut, [read])
    reads_at = [n for n, entry in enumerate(bench.ingress.log[start:]) if not entry[1]]
    assert reads_at and reads_at[0] <= 8 + 6, (
        f"the read waited for {reads_at} write grants"
    )
    await _wait(dut, flood)
    bench.check_clean()


@cocotb.test()
async def test_reset_mid_traffic(dut: Any) -> None:
    """Reset drops everything in flight; traffic afterwards completes normally."""
    bench = await _start(dut, seed=7)
    page = REGION_BASE + 0x300000
    for _ in range(20):
        bench.write(*bench.random_burst(page))
        bench.read(*bench.random_burst(page))
    for _ in range(60):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    bench.master._task.cancel()
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    master = AxiMaster(dut, dut.i_clk, "i_axi_", "o_axi_", bench.bus, bench.rng, 0.8)
    bench.master = master
    # The reference no longer predicts the region: write it whole, then read it.
    top = bench.max_size
    bench.ref.clear()
    writes = [
        bench.write(page + n * bench.bus, 0, top, INCR, strobe_bias=1.0)
        for n in range(32)
    ]
    await _wait(dut, writes)
    reads = [bench.read(page + n * bench.bus, 0, top, INCR) for n in range(32)]
    await _wait(dut, reads)
    for txn in reads:
        bench.check_read(txn)
    bench.check_clean()
