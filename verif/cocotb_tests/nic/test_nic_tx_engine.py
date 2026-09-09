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

"""Unit tests for nic_tx_engine (hw/rtl/peripherals/nic/nic_tx_engine.sv).

Against the DMA model (memory, out-of-order responses) and a beat sink
standing in for the TX FIFO: buffers at any byte offset come out as
contiguous beats with the right final count and last flag, reading
exactly the lines the buffer covers; invalid descriptors complete with
DD|ERR and send nothing; DD follows the last beat; abort completes with
DD|ERR|ABORT and pushes nothing more; the drain reaches idle without a
completion; with the ring empty nothing is read.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.nic.dma_model import (
    ABORT,
    DD,
    EOP,
    ERR,
    KIND_DATA,
    SOP,
    DmaModel,
    Memory,
    desc_status,
    post_desc,
)

RING = 0x8010_0000
SIZE_LOG2 = 4
ENTRIES = 1 << SIZE_LOG2
BUF = 0x8020_0000


class _Sink:
    """Takes beats with random backpressure and reassembles frames."""

    def __init__(self, dut: Any, rng: random.Random, gap: float) -> None:
        self.dut = dut
        self.rng = rng
        self.gap = gap
        self.frames: list[bytes] = []
        self.cut: list[bytes] = []
        self.current = bytearray()
        self.beats = 0
        self.stall = False
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if (
                int(dut.o_fifo_valid.value) == 1
                and not self.stall
                and self.rng.random() >= self.gap
            ):
                code = int(dut.o_fifo_code.value)
                n = (code & 7) + 1
                last = (code >> 3) & 1
                data = int(dut.o_fifo_data.value).to_bytes(8, "little")
                assert last or n == 8, "a nonfinal beat must carry 8 bytes"
                self.current += data[:n]
                self.beats += 1
                dut.i_fifo_ready.value = 1
                await RisingEdge(dut.i_clk)
                await FallingEdge(dut.i_clk)
                dut.i_fifo_ready.value = 0
                if last:
                    self.frames.append(bytes(self.current))
                    self.current = bytearray()
            else:
                dut.i_fifo_ready.value = 0

    def cut_frame(self) -> None:
        self.cut.append(bytes(self.current))
        self.current = bytearray()

    def stop(self) -> None:
        self._task.cancel()


class _Env:
    def __init__(
        self,
        dut: Any,
        seed: int,
        latency: tuple[int, int],
        sink_gap: float,
        status_latency: tuple[int, int] | None = None,
    ) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.mem = Memory()
        self.model = DmaModel(
            dut,
            self.mem,
            seed=seed + 100,
            latency=latency,
            status_latency=status_latency,
        )
        self.sink = _Sink(dut, self.rng, sink_gap)
        self.completions: list[tuple[int, int]] = []
        self._task = cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if int(dut.o_complete.value):
                self.completions.append(
                    (int(dut.o_complete_flags.value), int(dut.o_complete_bytes.value))
                )

    def stop(self) -> None:
        self._task.cancel()
        self.sink.stop()
        self.model.stop()

    def place(
        self, index: int, addr: int, length: int, word1_flags: int = SOP | EOP
    ) -> bytes:
        payload = bytes(self.rng.getrandbits(8) for _ in range(length))
        self.mem.write_bytes(addr, payload)
        post_desc(self.mem, RING, index, addr, (length & 0xFFFF) | word1_flags)
        return payload

    async def doorbell(self, tail: int) -> None:
        await FallingEdge(self.dut.i_clk)
        self.dut.i_tail.value = tail % ENTRIES

    async def wait_completions(self, n: int, limit: int = 40000) -> None:
        for _ in range(limit):
            await FallingEdge(self.dut.i_clk)
            if len(self.completions) >= n:
                return
        raise AssertionError(f"{len(self.completions)} of {n} completions")

    async def wait_idle(self, limit: int = 2000) -> None:
        for _ in range(limit):
            await FallingEdge(self.dut.i_clk)
            if int(self.dut.o_idle.value) == 1:
                return
        raise AssertionError("engine never idle")

    def lines_read(self) -> list[int]:
        return [r["addr"] for r in self.model.log if r["kind"] == KIND_DATA]


async def _setup(
    dut: Any,
    seed: int,
    latency: tuple[int, int] = (2, 14),
    sink_gap: float = 0.2,
    status_latency: tuple[int, int] | None = None,
) -> _Env:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_enable,
        dut.i_base,
        dut.i_size_log2,
        dut.i_tail,
        dut.i_restart,
        dut.i_stop,
        dut.i_abort,
        dut.i_fifo_ready,
        dut.i_req_ready,
        dut.i_resp_valid,
        dut.i_resp_kind,
        dut.i_resp_tag,
        dut.i_resp_error,
        dut.i_resp_rdata,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_base.value = RING
    dut.i_size_log2.value = SIZE_LOG2
    env = _Env(dut, seed, latency, sink_gap, status_latency)
    await FallingEdge(dut.i_clk)
    dut.i_enable.value = 1
    return env


def _expected_lines(addr: int, length: int) -> list[int]:
    first = addr & ~31
    last = (addr + length - 1) & ~31
    return list(range(first, last + 1, 32))


@cocotb.test()
async def test_frames_out(dut: Any) -> None:
    """Buffers at every kind of offset come out byte-exact, reading exactly their lines."""
    env = await _setup(dut, 1)
    lengths = [1, 8, 9, 31, 32, 33, 60, 64, 65, 100, 1518, 1500, 9216, 4000, 7]
    plan = []
    for i, length in enumerate(lengths):
        addr = BUF + i * 0x3000 + env.rng.randrange(64)
        plan.append((addr, length, env.place(i, addr, length)))
    await env.doorbell(len(plan))
    await env.wait_completions(len(plan))
    await env.wait_idle()
    assert env.sink.frames == [p[2] for p in plan]
    for i, (addr, length, _) in enumerate(plan):
        assert (
            desc_status(env.mem, RING, i) == DD
        ), f"desc {i}: {desc_status(env.mem, RING, i):#x}"
    assert env.completions == [(0, p[1]) for p in plan]
    expected = [
        line for addr, length, _ in plan for line in _expected_lines(addr, length)
    ]
    assert sorted(env.lines_read()) == sorted(
        expected
    ), "the lines read are not exactly the buffers' lines"
    assert int(dut.o_head.value) == len(plan)
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_reorder_under_slow_memory(dut: Any) -> None:
    """Widely reordered responses and a stalling sink: data still comes out in order."""
    env = await _setup(dut, 2, latency=(1, 40), sink_gap=0.6)
    plan = []
    for i in range(6):
        addr = BUF + i * 0x3000 + env.rng.randrange(64)
        length = env.rng.choice([200, 1500, 9216, 333])
        plan.append((addr, length, env.place(i, addr, length)))
    await env.doorbell(len(plan))
    await env.wait_completions(len(plan), limit=80000)
    assert env.sink.frames == [p[2] for p in plan]
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_one_status_write_in_flight(dut: Any) -> None:
    """Status responses slower than whole frames: the next status write waits for the previous response."""
    env = await _setup(dut, 7, latency=(1, 4), sink_gap=0.0, status_latency=(150, 150))
    plan = [env.place(i, BUF + i * 0x1000 + 3, 64) for i in range(4)]
    await env.doorbell(4)
    await env.wait_completions(4)
    assert env.sink.frames == plan
    status_cycles = [r["cycle"] for r in env.model.log if r["kind"] == 2]
    assert len(status_cycles) == 4
    assert all(
        b - a >= 150 for a, b in zip(status_cycles, status_cycles[1:])
    ), status_cycles
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_invalid_descriptors(dut: Any) -> None:
    """Length 0, oversize, missing SOP or EOP, outside or straddling the aperture: DD|ERR, nothing sent."""
    env = await _setup(dut, 3)
    env.place(0, BUF + 1, 0)
    env.place(1, BUF + 0x3000, 9217)
    env.place(2, BUF + 0x6000, 100, word1_flags=SOP)
    env.place(3, BUF + 0x9000, 100, word1_flags=EOP)
    post_desc(env.mem, RING, 4, 0x1000_0000, 100 | SOP | EOP)
    post_desc(env.mem, RING, 5, 0xBFFF_FFF0, 100 | SOP | EOP)
    good = env.place(6, BUF + 0xC000 + 17, 77)
    await env.doorbell(7)
    await env.wait_completions(7)
    await env.wait_idle()
    for i in range(6):
        assert (
            desc_status(env.mem, RING, i) == DD | ERR
        ), f"desc {i}: {desc_status(env.mem, RING, i):#x}"
    assert desc_status(env.mem, RING, 6) == DD
    assert env.sink.frames == [good]
    assert [c[0] for c in env.completions] == [2] * 6 + [0]
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_abort_mid_frame(dut: Any) -> None:
    """A MAC-domain reset mid-frame: DD|ERR|ABORT, no more beats, the next frame is whole."""
    env = await _setup(dut, 4, sink_gap=0.3)
    env.place(0, BUF + 5, 6000)
    second = env.place(1, BUF + 0x3000 + 9, 150)
    await env.doorbell(2)
    while env.sink.beats < 100:
        await FallingEdge(dut.i_clk)
    dut.i_abort.value = 1
    beats_at_abort = env.sink.beats
    await env.wait_completions(1)
    assert env.sink.beats <= beats_at_abort + 1
    assert env.completions[0][0] & 0b110 == 0b110
    assert desc_status(env.mem, RING, 0) == DD | ERR | ABORT
    for _ in range(60):
        await FallingEdge(dut.i_clk)
    env.sink.cut_frame()
    dut.i_abort.value = 0
    await env.wait_completions(2)
    assert env.sink.frames == [second]
    assert desc_status(env.mem, RING, 1) == DD
    assert int(dut.o_head.value) == 2
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_withdrawn_status_write_completes_nothing(dut: Any) -> None:
    """A status write the drain withdrew (an error response) frees the slot and.

    reports no completion; the next frame's completion is reported.
    """
    env = await _setup(dut, 8, latency=(1, 4))
    env.model.withdraw_status = True
    env.place(0, BUF + 1, 64)
    await env.doorbell(1)
    for _ in range(4000):
        await FallingEdge(dut.i_clk)
        if any(r.get("withdrawn") for r in env.model.log):
            break
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    assert (
        env.completions == []
    ), f"a withdrawn status write completed: {env.completions}"
    env.model.withdraw_status = False
    second = env.place(1, BUF + 0x3000 + 5, 70)
    await env.doorbell(2)
    await env.wait_completions(1)
    assert env.completions == [(0, 70)]
    assert env.sink.frames[-1] == second
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_stop_drains_without_completion(dut: Any) -> None:
    """The RESET drain mid-frame: idle with every read answered, no DD written."""
    env = await _setup(dut, 5, latency=(10, 30), sink_gap=0.5)
    env.place(0, BUF + 3, 6000)
    await env.doorbell(1)
    while env.sink.beats < 50:
        await FallingEdge(dut.i_clk)
    dut.i_stop.value = 1
    await env.wait_idle(limit=600)
    assert not env.model.pending
    assert env.completions == []
    assert desc_status(env.mem, RING, 0) == 0
    for _ in range(50):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_fifo_valid.value) == 0
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_empty_ring_reads_nothing(dut: Any) -> None:
    """With HEAD == TAIL the engine issues no request at all."""
    env = await _setup(dut, 6)
    for _ in range(300):
        await FallingEdge(dut.i_clk)
    assert env.model.log == []
    assert int(dut.o_idle.value) == 1
    env.stop()
