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

"""Unit tests for nic_rx_engine (hw/rtl/peripherals/nic/nic_rx_engine.sv).

The engine runs against the DMA model of dma_model.py (a memory with
out-of-order responses) and a beat source standing in for the RX FIFO.
Checked: frames land byte-exact at any buffer offset with nothing written
outside the buffers and the status words; the status word carries DD, the
received length and TRUNC/ERR as specified; the filter (station, group,
promiscuous) consumes rejected frames without a descriptor; bad
descriptors complete with DD|ERR and the ring keeps moving; a frame is
held while the ring is empty; a descriptor posted after its line was
prefetched is re-read after the doorbell; the status write is issued only
after the data writes are answered and one is in flight at a time; abort
completes with DD|ERR|ABORT; the drain reaches idle with no completion; a
disable lets the frame in progress finish.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from cocotb_tests.nic.dma_model import (
    ABORT,
    DD,
    ERR,
    KIND_DESC,
    TRUNC,
    DmaModel,
    Memory,
    desc_addr,
    desc_status,
    post_desc,
)

RING = 0x8010_0000
SIZE_LOG2 = 3
ENTRIES = 1 << SIZE_LOG2
BUF = 0x8020_0000
STATION = bytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
OTHER = bytes([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
BROADCAST = bytes([0xFF] * 6)
MULTICAST = bytes([0x01, 0x00, 0x5E, 0x01, 0x02, 0x03])


class _Env:
    def __init__(
        self,
        dut: Any,
        seed: int,
        latency: tuple[int, int] = (2, 14),
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
        self.completions: list[tuple[int, int]] = []  # (flags, bytes)
        self.pre: set[int] = set()  # memory bytes present before the frames
        self.filtered = 0
        self.beats_taken = 0
        self.abort_source = False
        self._task = cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if int(dut.o_complete.value):
                self.completions.append(
                    (int(dut.o_complete_flags.value), int(dut.o_complete_bytes.value))
                )
            if int(dut.o_filtered.value):
                self.filtered += 1

    def stop(self) -> None:
        self._task.cancel()
        self.model.stop()

    async def push_frame(self, payload: bytes, gap: float = 0.1) -> bool:
        """Offer the frame beat by beat; False if the push was abandoned."""
        dut = self.dut
        pos = 0
        while pos < len(payload):
            n = min(8, len(payload) - pos)
            while self.rng.random() < gap:
                await FallingEdge(dut.i_clk)
            await FallingEdge(dut.i_clk)
            chunk = payload[pos : pos + n] + bytes(8 - n)
            dut.i_fifo_data.value = int.from_bytes(chunk, "little")
            dut.i_fifo_code.value = ((1 if pos + n == len(payload) else 0) << 3) | (
                n - 1
            )
            dut.i_fifo_valid.value = 1
            for _ in range(5000):
                await Timer(1, unit="ps")
                if int(dut.o_fifo_ready.value) == 1:
                    break
                if self.abort_source:
                    dut.i_fifo_valid.value = 0
                    return False
                await FallingEdge(dut.i_clk)
            else:
                raise AssertionError("beat never taken")
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ps")
            dut.i_fifo_valid.value = 0
            self.beats_taken += 1
            pos += n
        return True

    async def wait_completions(self, n: int, limit: int = 20000) -> None:
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

    def frame(self, length: int, da: bytes = STATION) -> bytes:
        body = bytes(self.rng.getrandbits(8) for _ in range(length - 6))
        return da + body

    def post(self, index: int, buf_addr: int, buf_len: int) -> None:
        post_desc(self.mem, RING, index, buf_addr, buf_len)

    async def doorbell(self, tail: int) -> None:
        await FallingEdge(self.dut.i_clk)
        self.dut.i_tail.value = tail % ENTRIES

    def check_written(self, expected_ranges: list[tuple[int, int]]) -> None:
        """Every byte the engine wrote lies in a buffer range or a status word."""
        allowed: set[int] = set()
        for a, n in expected_ranges:
            allowed.update(range(a, a + n))
        for i in range(ENTRIES):
            allowed.update(range(desc_addr(RING, i) + 8, desc_addr(RING, i) + 12))
        stray = sorted(
            a for a in self.mem.bytes if a not in allowed and a not in self.pre
        )
        assert (
            not stray
        ), f"bytes written outside the buffers: {[hex(a) for a in stray[:8]]}"


async def _setup(
    dut: Any,
    seed: int,
    promisc: int = 1,
    latency: tuple[int, int] = (2, 14),
    status_latency: tuple[int, int] | None = None,
) -> _Env:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_enable,
        dut.i_base,
        dut.i_size_log2,
        dut.i_tail,
        dut.i_restart,
        dut.i_promisc,
        dut.i_mac,
        dut.i_stop,
        dut.i_abort,
        dut.i_fifo_valid,
        dut.i_fifo_data,
        dut.i_fifo_code,
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
    dut.i_promisc.value = promisc
    dut.i_mac.value = int.from_bytes(STATION, "little")
    env = _Env(dut, seed, latency, status_latency)
    env.pre = set(env.mem.bytes)
    await FallingEdge(dut.i_clk)
    dut.i_enable.value = 1
    return env


@cocotb.test()
async def test_frames_into_buffers(dut: Any) -> None:
    """Seven frames at random offsets: byte-exact data, status words, nothing stray."""
    env = await _setup(dut, 1)
    frames = []
    ranges = []
    for i in range(ENTRIES - 1):
        addr = BUF + i * 0x3000 + env.rng.randrange(64)
        length = env.rng.choice([60, 61, 64, 65, 100, 1518, 1500, 9000]) if i else 60
        env.post(i, addr, 9216)
        frames.append((addr, env.frame(length)))
        ranges.append((addr, length))
    env.pre = set(env.mem.bytes)
    await env.doorbell(ENTRIES - 1)
    for _, f in frames:
        assert await env.push_frame(f)
    await env.wait_completions(ENTRIES - 1)
    await env.wait_idle()
    for i, (addr, f) in enumerate(frames):
        assert desc_status(env.mem, RING, i) == DD | len(
            f
        ), f"desc {i} status {desc_status(env.mem, RING, i):#x}"
        assert env.mem.read_bytes(addr, len(f)) == f, f"frame {i} data differs"
    assert [c for c in env.completions] == [(0, len(f)) for _, f in frames]
    env.check_written(ranges)
    assert int(dut.o_head.value) == ENTRIES - 1
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_status_after_data_slow_memory(dut: Any) -> None:
    """Long response latencies: status writes wait for the data and follow ring order."""
    env = await _setup(dut, 2, latency=(10, 60))
    frames = []
    for i in range(ENTRIES - 1):
        addr = BUF + i * 0x1000 + env.rng.randrange(64)
        env.post(i, addr, 2048)
        frames.append((addr, env.frame(env.rng.randrange(60, 200))))
    env.pre = set(env.mem.bytes)
    await env.doorbell(ENTRIES - 1)
    for _, f in frames:
        assert await env.push_frame(f, gap=0.0)
    await env.wait_completions(ENTRIES - 1)
    for i, (addr, f) in enumerate(frames):
        assert desc_status(env.mem, RING, i) == DD | len(f)
        assert env.mem.read_bytes(addr, len(f)) == f
    status_cycles = [r["cycle"] for r in env.model.log if r["kind"] == 2]
    assert status_cycles == sorted(status_cycles) and len(status_cycles) == ENTRIES - 1
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_one_status_write_in_flight(dut: Any) -> None:
    """Status responses slower than whole frames: the next status write waits for the previous response."""
    env = await _setup(dut, 12, latency=(1, 4), status_latency=(150, 150))
    frames = []
    for i in range(4):
        addr = BUF + i * 0x1000 + env.rng.randrange(64)
        env.post(i, addr, 2048)
        frames.append((addr, env.frame(64)))
    env.pre = set(env.mem.bytes)
    await env.doorbell(4)
    for _, f in frames:
        assert await env.push_frame(f, gap=0.0)
    await env.wait_completions(4)
    status_cycles = [r["cycle"] for r in env.model.log if r["kind"] == 2]
    assert len(status_cycles) == 4
    assert all(
        b - a >= 150 for a, b in zip(status_cycles, status_cycles[1:])
    ), status_cycles
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_filter(dut: Any) -> None:
    """Station, broadcast and multicast frames are taken; another unicast is consumed without a descriptor."""
    env = await _setup(dut, 3, promisc=0)
    for i in range(3):
        env.post(i, BUF + i * 0x1000 + 2, 2048)
    env.pre = set(env.mem.bytes)
    await env.doorbell(3)
    plan = [STATION, OTHER, BROADCAST, OTHER, MULTICAST]
    frames = [env.frame(64 + 7 * k, da) for k, da in enumerate(plan)]
    for f in frames:
        assert await env.push_frame(f)
    await env.wait_completions(3)
    await env.wait_idle()
    taken = [f for f in frames if f[:6] != OTHER]
    for i, f in enumerate(taken):
        assert desc_status(env.mem, RING, i) == DD | len(f)
        assert env.mem.read_bytes(BUF + i * 0x1000 + 2, len(f)) == f
    assert env.filtered == 2
    assert int(dut.o_head.value) == 3
    env.check_written([(BUF + i * 0x1000 + 2, len(f)) for i, f in enumerate(taken)])
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_truncation_and_bad_descriptors(dut: Any) -> None:
    """A short buffer truncates; length 0 and buffers outside the aperture complete with ERR; the ring moves on."""
    env = await _setup(dut, 4)
    cases = [
        (BUF + 5, 100, 300, DD | TRUNC | 300),
        (BUF + 0x1000, 0, 80, DD | ERR | 80),
        (0x1000_0000, 100, 90, DD | ERR | 90),
        (0xBFFF_FFF0, 100, 70, DD | ERR | 70),
        (BUF + 0x2000 + 31, 2048, 200, DD | 200),
    ]
    frames = []
    for i, (addr, buf_len, length, _) in enumerate(cases):
        env.post(i, addr, buf_len)
        frames.append(env.frame(length))
    env.pre = set(env.mem.bytes)
    await env.doorbell(len(cases))
    for f in frames:
        assert await env.push_frame(f)
    await env.wait_completions(len(cases))
    await env.wait_idle()
    for i, (addr, buf_len, length, status) in enumerate(cases):
        assert (
            desc_status(env.mem, RING, i) == status
        ), f"desc {i}: {desc_status(env.mem, RING, i):#x} != {status:#x}"
    assert env.mem.read_bytes(BUF + 5, 100) == frames[0][:100]
    assert env.mem.read_bytes(BUF + 0x2000 + 31, 200) == frames[4]
    env.check_written([(BUF + 5, 100), (BUF + 0x2000 + 31, 200)])
    flags = [c[0] for c in env.completions]
    assert flags == [1, 2, 2, 2, 0], flags  # TRUNC, ERR, ERR, ERR, clean
    assert int(dut.o_head.value) == len(cases)
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_ring_empty_holds_frame(dut: Any) -> None:
    """With no descriptor posted the frame waits in the FIFO; posting one releases it."""
    env = await _setup(dut, 5)
    f = env.frame(200)
    push = cocotb.start_soon(env.push_frame(f))
    for _ in range(300):
        await FallingEdge(dut.i_clk)
        assert int(dut.o_fifo_ready.value) == 0
    assert env.beats_taken == 0
    assert not [r for r in env.model.log], "a request was issued with nothing posted"
    env.post(0, BUF + 9, 2048)
    env.pre = set(env.mem.bytes)
    await env.doorbell(1)
    assert await push
    await env.wait_completions(1)
    assert desc_status(env.mem, RING, 0) == DD | 200
    assert env.mem.read_bytes(BUF + 9, 200) == f
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_doorbell_rereads_posted_descriptor(dut: Any) -> None:
    """Descriptor 1 shares its line with 0; posted after that line was prefetched, it is re-read."""
    env = await _setup(dut, 6)
    stale = BUF + 0x3000
    real = BUF + 0x4000 + 3
    env.post(0, BUF + 1, 2048)
    env.post(1, stale, 2048)  # the image the prefetch of line 0 will see
    await env.doorbell(1)
    for _ in range(200):
        await FallingEdge(dut.i_clk)
        if any(r["kind"] == KIND_DESC for r in env.model.log) and not env.model.pending:
            break
    assert len([r for r in env.model.log if r["kind"] == KIND_DESC]) == 1
    env.post(1, real, 2048)
    env.pre = set(env.mem.bytes)
    await env.doorbell(2)
    f0, f1 = env.frame(80), env.frame(90)
    assert await env.push_frame(f0)
    assert await env.push_frame(f1)
    await env.wait_completions(2)
    assert (
        env.mem.read_bytes(real, 90) == f1
    ), "frame 1 did not land at the posted buffer"
    assert desc_status(env.mem, RING, 1) == DD | 90
    env.check_written([(BUF + 1, 80), (real, 90)])
    assert (
        len([r for r in env.model.log if r["kind"] == KIND_DESC]) >= 2
    ), "the line was not re-read after the doorbell"
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_abort_mid_frame(dut: Any) -> None:
    """A MAC-domain reset mid-frame completes the descriptor with DD|ERR|ABORT; the next frame is clean."""
    env = await _setup(dut, 7)
    env.post(0, BUF + 7, 4096)
    env.post(1, BUF + 0x1000 + 7, 4096)
    env.pre = set(env.mem.bytes)
    await env.doorbell(2)
    f0 = env.frame(3000)
    push = cocotb.start_soon(env.push_frame(f0, gap=0.3))
    while env.beats_taken < 100:
        await FallingEdge(dut.i_clk)
    env.abort_source = True
    dut.i_abort.value = 1
    taken_at_abort = env.beats_taken
    assert await push is False
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    assert env.beats_taken <= taken_at_abort + 1
    await env.wait_completions(1)
    assert env.completions[0][0] & 0b110 == 0b110, f"flags {env.completions[0][0]:#b}"
    assert desc_status(env.mem, RING, 0) & (DD | ERR | ABORT) == DD | ERR | ABORT
    for _ in range(60):
        await FallingEdge(dut.i_clk)
    env.abort_source = False
    dut.i_abort.value = 0
    await FallingEdge(dut.i_clk)
    f1 = env.frame(120)
    assert await env.push_frame(f1)
    await env.wait_completions(2)
    assert desc_status(env.mem, RING, 1) == DD | 120
    assert env.mem.read_bytes(BUF + 0x1000 + 7, 120) == f1
    assert env.completions[1] == (0, 120)
    assert int(dut.o_head.value) == 2
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_stop_drains_without_completion(dut: Any) -> None:
    """The RESET drain mid-frame reaches idle with every response in and no DD written."""
    env = await _setup(dut, 8)
    env.post(0, BUF + 3, 4096)
    env.post(1, BUF + 0x1000, 4096)
    env.pre = set(env.mem.bytes)
    await env.doorbell(2)
    push = cocotb.start_soon(env.push_frame(env.frame(3000), gap=0.2))
    while env.beats_taken < 80:
        await FallingEdge(dut.i_clk)
    env.abort_source = True
    dut.i_stop.value = 1
    assert await push is False
    await env.wait_idle(limit=400)
    assert not env.model.pending
    assert env.completions == []
    assert desc_status(env.mem, RING, 0) == 0
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_disable_finishes_frame(dut: Any) -> None:
    """Clearing the enable mid-frame lets that frame complete and admits no other."""
    env = await _setup(dut, 9)
    env.post(0, BUF + 1, 4096)
    env.post(1, BUF + 0x1000 + 1, 4096)
    env.pre = set(env.mem.bytes)
    await env.doorbell(2)
    f0 = env.frame(1000)
    push = cocotb.start_soon(env.push_frame(f0, gap=0.2))
    while env.beats_taken < 40:
        await FallingEdge(dut.i_clk)
    dut.i_enable.value = 0
    assert await push
    await env.wait_completions(1)
    assert desc_status(env.mem, RING, 0) == DD | 1000
    assert env.mem.read_bytes(BUF + 1, 1000) == f0
    await env.wait_idle()
    f1 = env.frame(100)
    push = cocotb.start_soon(env.push_frame(f1))
    for _ in range(200):
        await FallingEdge(dut.i_clk)
    assert env.beats_taken == 125, "a frame was admitted while disabled"
    dut.i_enable.value = 1
    assert await push
    await env.wait_completions(2)
    assert desc_status(env.mem, RING, 1) == DD | 100
    assert not env.model.violations, env.model.violations
    env.stop()
